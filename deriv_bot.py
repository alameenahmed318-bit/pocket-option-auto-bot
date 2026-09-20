#!/usr/bin/env python3
import json, os, time
from datetime import datetime, timezone
from collections import deque
import requests
import websocket

API_BASE = "https://api.derivws.com"
DEMO_ONLY = os.getenv("DEMO_ONLY", "true").lower() == "true"
TOKEN = os.getenv("DERIV_TOKEN", "").strip()
APP_ID = os.getenv("DERIV_APP_ID", "").strip()
ACCOUNT_ID_OVERRIDE = os.getenv("DERIV_ACCOUNT_ID", "").strip()
SYMBOL = os.getenv("DERIV_SYMBOL", "AUTO").strip()
STAKE = float(os.getenv("STAKE_USD", "1"))
DURATION = int(os.getenv("DURATION_SECONDS", "60"))
MAX_TRADES = int(os.getenv("MAX_TRADES", "100"))
COOLDOWN = float(os.getenv("COOLDOWN_SECONDS", "30"))
MAX_DAILY_LOSS = float(os.getenv("MAX_DAILY_LOSS_USD", "15"))
DRY_RUN = os.getenv("DRY_RUN", "true").lower() == "true"
ACCU_GROWTH_RATE = float(os.getenv("ACCU_GROWTH_RATE", "0.03"))
CLOSE_AFTER_SECONDS = float(os.getenv("CLOSE_AFTER_SECONDS", "3"))
STABLE_MARKETS_LIMIT = int(os.getenv("STABLE_MARKETS_LIMIT", "5"))
LOG_FILE = os.getenv("DERIV_LOG_FILE", "deriv_trades.log")


def log(message):
    line = f"[{datetime.now(timezone.utc).isoformat()}] {message}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass

if not DEMO_ONLY:
    raise SystemExit("Safety stop: DEMO_ONLY must remain true.")
if not TOKEN or not APP_ID:
    raise SystemExit("Missing DERIV_TOKEN or DERIV_APP_ID.")

def auth_headers():
    return {
        "Authorization": f"Bearer {TOKEN}",
        "Deriv-App-ID": APP_ID,
        "Content-Type": "application/json",
        "Accept": "application/json",
    }

def get_demo_account_id():
    url = f"{API_BASE}/trading/v1/options/accounts"
    last_exc = None
    r = None
    for attempt in range(1, 6):
        try:
            r = requests.get(url, headers=auth_headers(), timeout=20)
            if r.ok or r.status_code not in (429, 500, 502, 503, 504):
                break
            log(f"ACCOUNT LOOKUP HTTP {r.status_code}; retry {attempt}/5")
        except requests.RequestException as exc:
            last_exc = exc
            log(f"ACCOUNT LOOKUP NETWORK ERROR attempt {attempt}/5: {exc}")
        if attempt < 5:
            time.sleep(min(2 ** (attempt - 1), 10))

    if r is None:
        raise RuntimeError(f"Deriv account lookup failed after 5 attempts: {last_exc}")

    if r.ok:
        body = r.json()
        data = body.get("data", [])
        accounts = [data] if isinstance(data, dict) else data if isinstance(data, list) else []
        demos = [a for a in accounts if str(a.get("account_type", "")).lower() == "demo"]
        if ACCOUNT_ID_OVERRIDE:
            matches = [a for a in demos if str(a.get("account_id", "")).strip() == ACCOUNT_ID_OVERRIDE]
            if not matches:
                raise RuntimeError("DERIV_ACCOUNT_ID was not found among this token's Demo Options accounts.")
            account = matches[0]
            if str(account.get("status", "")).lower() != "active":
                raise RuntimeError(f"DERIV_ACCOUNT_ID={ACCOUNT_ID_OVERRIDE} is not active.")
            log(f"Using FIXED Demo Options account: {ACCOUNT_ID_OVERRIDE} | balance={account.get('balance')} {account.get('currency', '')}")
            return ACCOUNT_ID_OVERRIDE
        if demos:
            active = [a for a in demos if str(a.get("status", "")).lower() == "active"]
            account = active[0] if active else demos[0]
            account_id = str(account.get("account_id", "")).strip()
            if account_id:
                log(f"Using Demo Options account: {account_id} | balance={account.get('balance')} {account.get('currency', '')}")
                return account_id
        raise RuntimeError(f"No active Demo Options account was returned: {body}")

    if r.status_code == 404:
        create = requests.post(
            url,
            headers=auth_headers(),
            json={"currency": "USD", "group": "row", "account_type": "demo"},
            timeout=20,
        )
        if not create.ok:
            if create.status_code == 403 and "scope" in create.text.lower():
                raise RuntimeError(
                    "Deriv token is missing the account_manage scope. "
                    "Create a new Deriv PAT with BOTH trade and account_manage scopes, "
                    "then replace the GitHub Secret DERIV_TOKEN."
                )
            raise RuntimeError(f"Deriv Demo Options account creation failed with HTTP {create.status_code}: {create.text}")
        body = create.json()
        data = body.get("data", [])
        accounts = [data] if isinstance(data, dict) else data if isinstance(data, list) else []
        demos = [a for a in accounts if str(a.get("account_type", "")).lower() == "demo"]
        if not demos:
            raise RuntimeError(f"No Demo Options account was returned: {body}")
        account = demos[0]
        account_id = str(account.get("account_id", "")).strip()
        if not account_id:
            raise RuntimeError(f"Demo account response has no account_id: {account}")
        log(f"Using Demo Options account: {account_id} | balance={account.get('balance')} {account.get('currency', '')}")
        return account_id

    if r.status_code == 403 and "scope" in r.text.lower():
        raise RuntimeError(
            "Deriv token is missing the trade scope. "
            "Create a new Deriv PAT with the trade scope and update DERIV_TOKEN."
        )

    raise RuntimeError(f"Deriv Demo Options account lookup failed with HTTP {r.status_code}: {r.text}")

def get_ws_url(account_id):
    r = requests.post(
        f"{API_BASE}/trading/v1/options/accounts/{account_id}/otp",
        headers=auth_headers(),
        timeout=20,
    )
    if not r.ok:
        raise RuntimeError(f"Deriv OTP request failed with HTTP {r.status_code}: {r.text}")
    url = r.json().get("data", {}).get("url")
    if not url:
        raise RuntimeError(f"No WebSocket URL returned: {r.text}")
    return url

class Client:
    def __init__(self, url):
        self.ws = websocket.create_connection(url, timeout=30, enable_multithread=True)
        self.req_id = 0

    def send(self, payload):
        self.req_id += 1
        payload = dict(payload, req_id=self.req_id)
        self.ws.send(json.dumps(payload))
        return self.req_id

    def recv_json(self, timeout=30):
        self.ws.settimeout(timeout)
        try:
            return json.loads(self.ws.recv())
        except websocket.WebSocketTimeoutException:
            return None
        except websocket.WebSocketConnectionClosedException:
            raise ConnectionError("WebSocket connection to Deriv was closed.")

    def recv_for(self, req_id, msg_type=None, timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline:
            remaining = max(1, deadline - time.time())
            msg = self.recv_json(timeout=remaining)
            if msg is None:
                continue
            if msg.get("error"):
                raise RuntimeError(msg["error"].get("message", str(msg["error"])))
            if msg.get("req_id") == req_id and (msg_type is None or msg.get("msg_type") == msg_type):
                return msg
        raise TimeoutError(f"Timed out waiting for req_id={req_id}")

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass

def connect(account_id):
    client = Client(get_ws_url(account_id))
    rid = client.send({"balance": 1})
    balance_msg = client.recv_for(rid, "balance")
    log(f"CONNECTED account_balance={balance_msg['balance']}")
    return client

def get_available_symbols(client):
    rid = client.send({
        "active_symbols": "brief",
        "contract_type": ["ACCU"],
    })
    msg = client.recv_for(rid, "active_symbols", timeout=30)
    symbols = msg.get("active_symbols", [])

    names = []
    for item in symbols:
        symbol = item.get("underlying_symbol") or item.get("symbol")
        if not symbol:
            continue
        if item.get("is_trading_suspended") == 1:
            continue
        if item.get("exchange_is_open") == 0:
            continue
        names.append(symbol)

    if SYMBOL and SYMBOL.upper() != "AUTO":
        names = [s for s in names if s == SYMBOL]

    names = list(dict.fromkeys(names))
    print(f"OPEN ACCUMULATOR SYMBOLS ({len(names)}): {', '.join(names[:80])}")
    return names

def ema(values, n):
    if len(values) < n:
        return None
    k = 2 / (n + 1)
    value = sum(values[:n]) / n
    for p in values[n:]:
        value = p * k + value * (1 - k)
    return value

def rsi(values, n=14):
    if len(values) < n + 1:
        return None
    gains, losses = [], []
    for a, b in zip(values[-n-1:-1], values[-n:]):
        d = b - a
        gains.append(max(d, 0))
        losses.append(max(-d, 0))
    ag, al = sum(gains) / n, sum(losses) / n
    return 100.0 if al == 0 else 100 - (100 / (1 + ag / al))

def stability_score(prices):
    if len(prices) < 40:
        return None
    base = prices[-1] or 1.0
    returns = [(b - a) / base for a, b in zip(prices[-30:-1], prices[-29:])]
    mean_abs = sum(abs(x) for x in returns) / len(returns)
    return mean_abs

def signal(prices):
    fast, slow = ema(prices, 9), ema(prices, 21)
    momentum = rsi(prices, 14)
    vol = stability_score(prices)
    if fast is None or slow is None or momentum is None or vol is None or not prices:
        return False, fast, slow, momentum, vol
    spot = float(prices[-1])
    spread = abs(fast - slow) / spot if spot else 999.0
    stable = spread <= 0.003 and 35 <= momentum <= 65 and vol <= 0.0008
    return stable, fast, slow, momentum, vol

def main():
    log(f"DERIV ACCUMULATOR DEMO BOT | symbols={SYMBOL} | stake={STAKE} | growth={ACCU_GROWTH_RATE:.2%} | close_after={CLOSE_AFTER_SECONDS}s | cooldown={COOLDOWN}s | stable_top={STABLE_MARKETS_LIMIT} | DRY_RUN={DRY_RUN}")

    account_id = get_demo_account_id()
    client = None
    trades = 0
    day_pnl = 0.0
    last_trade = 0.0

    try:
        for attempt in range(1, 4):
            try:
                client = connect(account_id)
                break
            except (ConnectionError, websocket.WebSocketException) as exc:
                print(f"Connection attempt {attempt}/3 failed: {exc}")
                if client:
                    client.close()
                if attempt < 3:
                    time.sleep(5)
        else:
            raise RuntimeError("Could not establish a stable Deriv WebSocket connection.")

        symbols = get_available_symbols(client)
        if not symbols:
            print("NO OPEN ACCUMULATOR SYMBOLS: nothing to trade right now.")
            return

        histories = {symbol: deque(maxlen=120) for symbol in symbols}
        subscribed = 0
        for symbol in symbols:
            try:
                client.send({"ticks": symbol, "subscribe": 1})
                subscribed += 1
            except Exception as exc:
                print(f"Could not subscribe to {symbol}: {exc}")

        print(f"SUBSCRIBED TO {subscribed} SYMBOLS. Scanning all available markets.")

        warmup_deadline = time.time() + 120
        while time.time() < warmup_deadline and any(len(v) < 40 for v in histories.values()):
            try:
                msg = client.recv_json(timeout=30)
            except ConnectionError:
                print("WebSocket closed during market scan; reconnecting...")
                client.close()
                client = connect(account_id)
                symbols = get_available_symbols(client)
                histories = {symbol: deque(maxlen=120) for symbol in symbols}
                for symbol in symbols:
                    client.send({"ticks": symbol, "subscribe": 1})
                continue

            if not msg or msg.get("msg_type") != "tick":
                continue
            tick = msg.get("tick", {})
            symbol = tick.get("symbol")
            quote = tick.get("quote")
            if symbol in histories and quote is not None:
                histories[symbol].append(float(quote))

            ready_now = [s for s, h in histories.items() if len(h) >= 40]
            if ready_now:
                print(f"READY {symbol} ({len(histories[symbol])} ticks) | ACTIVE READY MARKETS={len(ready_now)}")

        ready = [s for s, h in histories.items() if len(h) >= 40]
        print(f"READY SYMBOLS ({len(ready)}): {', '.join(ready[:80])}")
        if not ready:
            print("BOT STOPPED: no active symbol supplied enough live ticks. No Demo contract was purchased.")
            return

        ranked = sorted(
            ready,
            key=lambda s: stability_score(list(histories[s])) if stability_score(list(histories[s])) is not None else 999.0
        )
        selected = ranked[:max(1, min(STABLE_MARKETS_LIMIT, len(ranked)))]
        log(f"STABLE MARKET SELECTION: {', '.join(selected)} | selected_by_lowest_recent_tick_volatility")

        while (MAX_TRADES <= 0 or trades < MAX_TRADES) and day_pnl > -MAX_DAILY_LOSS:
            try:
                msg = client.recv_json(timeout=30)
            except ConnectionError:
                print("WebSocket closed. Reconnecting to continue Demo test...")
                client.close()
                client = connect(account_id)
                symbols = get_available_symbols(client)
                histories = {symbol: deque(maxlen=120) for symbol in symbols}
                for symbol in symbols:
                    client.send({"ticks": symbol, "subscribe": 1})
                continue

            if not msg or msg.get("msg_type") != "tick":
                continue

            tick = msg.get("tick", {})
            symbol = tick.get("symbol")
            quote = tick.get("quote")
            if symbol not in histories or quote is None:
                continue
            histories[symbol].append(float(quote))

            if symbol not in selected:
                continue
            if time.time() - last_trade < COOLDOWN:
                continue

            stable, fast, slow, momentum, vol = signal(list(histories[symbol]))
            if not stable:
                continue

            log("ACCU SIGNAL {} growth={:.2%} EMA9={:.6f} EMA21={:.6f} RSI14={:.2f} tick_vol={:.6f}".format(
                symbol, ACCU_GROWTH_RATE, fast, slow, momentum, vol))

            rid = client.send({
                "proposal": 1,
                "amount": STAKE,
                "basis": "stake",
                "contract_type": "ACCU",
                "currency": "USD",
                "underlying_symbol": symbol,
                "growth_rate": ACCU_GROWTH_RATE,
            })
            try:
                proposal = client.recv_for(rid, "proposal", timeout=15)["proposal"]
            except Exception as exc:
                print(f"ACCU PROPOSAL FAILED {symbol}: {exc}")
                continue

            log("ACCU PROPOSAL {} growth={:.2%} id={} ask={} payout={}".format(
                symbol, ACCU_GROWTH_RATE, proposal.get("id"), proposal["ask_price"], proposal.get("payout")))
            last_trade = time.time()

            if DRY_RUN:
                trades += 1
                print(f"DRY_RUN=true: Accumulator proposal only; simulated test {trades}/{MAX_TRADES}.")
                continue

            rid = client.send({
                "buy": proposal["id"],
                "price": float(proposal["ask_price"]),
            })
            try:
                bought = client.recv_for(rid, "buy", timeout=15)["buy"]
            except Exception as exc:
                print(f"ACCU BUY FAILED {symbol}: {exc}")
                continue

            contract_id = bought["contract_id"]
            buy_time = time.time()
            buy_price = float(bought.get("buy_price", proposal.get("ask_price", STAKE)) or STAKE)
            trades += 1
            log("DEMO ACCUMULATOR PURCHASED {}/{}: {} growth={:.2%} contract={} buy_price={} account={}".format(
                trades, MAX_TRADES, symbol, ACCU_GROWTH_RATE, contract_id, buy_price, account_id))

            client.send({
                "proposal_open_contract": 1,
                "contract_id": contract_id,
                "subscribe": 1,
            })

            profitable_hold_logged = False
            while True:
                try:
                    update = client.recv_json(timeout=30)
                except ConnectionError:
                    print("WebSocket closed while monitoring contract. Reconnecting...")
                    client.close()
                    client = connect(account_id)
                    continue
                if not update or update.get("msg_type") != "proposal_open_contract":
                    continue
                c = update.get("proposal_open_contract", {})
                if str(c.get("contract_id")) != str(contract_id):
                    continue

                if c.get("is_sold"):
                    pnl = float(c.get("profit", 0) or 0)
                    day_pnl += pnl
                    log(f"CLOSED {symbol} pnl={pnl:.2f} day_pnl={day_pnl:.2f} contract={contract_id}")
                    break

                elapsed = time.time() - buy_time
                if elapsed >= CLOSE_AFTER_SECONDS:
                    profit = float(c.get("profit", 0) or 0)

                    # After the minimum hold time, keep a trade that is showing profit.
                    # Close only when it is no longer profitable.
                    if profit > 0:
                        if not profitable_hold_logged:
                            log("PROFIT HOLD {} profit={:+.2f} after {:.2f}s | keeping contract open.".format(
                                symbol, profit, elapsed))
                            profitable_hold_logged = True
                        continue

                    print("CLOSE TIMER: {:.2f}s reached; profit={:+.2f}; selling Accumulator.".format(
                        elapsed, profit))
                    sell_rid = client.send({"sell": contract_id, "price": 0})
                    try:
                        sold = client.recv_for(sell_rid, "sell", timeout=10)["sell"]
                        sold_for = float(sold.get("sold_for", buy_price) or buy_price)
                        pnl = sold_for - buy_price
                        day_pnl += pnl
                        log("ACCU CLOSED AFTER {:.2f}s {} pnl={:.2f} sold_for={:.2f} day_pnl={:.2f} contract={}".format(
                            elapsed, symbol, pnl, sold_for, day_pnl, contract_id))
                        break
                    except Exception as exc:
                        print("ACCU SELL FAILED: {}. Waiting for a later tick before retrying.".format(exc))
                        # Keep monitoring the same contract; do not start another
                        # trade while this contract is still open.
                        continue

        log(f"BOT STOPPED trades={trades} day_pnl={day_pnl:.2f} | risk_limit={MAX_DAILY_LOSS:.2f}")
    finally:
        if client:
            client.close()

if __name__ == "__main__":
    main()
