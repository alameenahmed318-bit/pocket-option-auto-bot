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
SYMBOL = os.getenv("DERIV_SYMBOL", "AUTO").strip()
STAKE = float(os.getenv("STAKE_USD", "1"))
DURATION = int(os.getenv("DURATION_SECONDS", "60"))
MAX_TRADES = int(os.getenv("MAX_TRADES", "20"))
COOLDOWN = int(os.getenv("COOLDOWN_SECONDS", "30"))
MAX_DAILY_LOSS = float(os.getenv("MAX_DAILY_LOSS_USD", "15"))
DRY_RUN = os.getenv("DRY_RUN", "true").lower() == "true"
EARLY_PROFIT_SECONDS = int(os.getenv("EARLY_PROFIT_SECONDS", "5"))
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
    r = requests.get(url, headers=auth_headers(), timeout=20)

    if r.ok:
        body = r.json()
        data = body.get("data", [])
        accounts = [data] if isinstance(data, dict) else data if isinstance(data, list) else []
        demos = [a for a in accounts if str(a.get("account_type", "")).lower() == "demo"]
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
    log(f"CONNECTED account_balance={balance_msg["balance"]}")
    return client

def get_available_symbols(client):
    # Deriv returns the currently active underlying markets. Asking for CALL/PUT
    # support keeps the list compatible with this bot's digital-option strategy.
    rid = client.send({
        "active_symbols": "brief",
        "contract_type": ["CALL", "PUT"],
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

    # If a specific symbol was requested, keep it only when it is currently open.
    if SYMBOL and SYMBOL.upper() != "AUTO":
        names = [s for s in names if s == SYMBOL]

    # Stable order and no duplicates.
    names = list(dict.fromkeys(names))
    print(f"OPEN CALL/PUT SYMBOLS ({len(names)}): {', '.join(names[:80])}")
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

def signal(prices):
    fast, slow = ema(prices, 9), ema(prices, 21)
    momentum = rsi(prices, 14)
    if fast is None or slow is None or momentum is None:
        return None, fast, slow, momentum
    if fast > slow and 45 <= momentum <= 75:
        return "CALL", fast, slow, momentum
    if fast < slow and 25 <= momentum <= 55:
        return "PUT", fast, slow, momentum
    return None, fast, slow, momentum

def main():
    log(f"DERIV DEMO BOT | symbols={SYMBOL} | stake={STAKE} | duration={DURATION}s | DRY_RUN={DRY_RUN}")

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
            print("NO OPEN CALL/PUT SYMBOLS: nothing to trade right now.")
            return

        # Keep a small independent tick history for every open symbol.
        histories = {symbol: deque(maxlen=120) for symbol in symbols}
        subscribed = 0
        for symbol in symbols:
            try:
                client.send({"ticks": symbol, "subscribe": 1})
                subscribed += 1
            except Exception as exc:
                print(f"Could not subscribe to {symbol}: {exc}")

        print(f"SUBSCRIBED TO {subscribed} SYMBOLS. Scanning all available markets.")

        # Warm up each symbol independently. One slow/quiet market must not block
        # the other open markets from becoming tradable.
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
                # Do not wait for every market. Start scanning immediately.
                print(f"READY {symbol} ({len(histories[symbol])} ticks) | ACTIVE READY MARKETS={len(ready_now)}")

        ready = [s for s, h in histories.items() if len(h) >= 40]
        print(f"READY SYMBOLS ({len(ready)}): {', '.join(ready[:80])}")
        if not ready:
            print("BOT STOPPED: no active symbol supplied enough live ticks. No Demo contract was purchased.")
            return

        print(f"CONTINUOUS MODE: scanning {len(ready)} ready open supported symbols until {MAX_TRADES} trades or the risk limit.")

        # Prevent repeated signals on the same symbol/direction until a new
        # tick arrives after the cooldown, and report non-signals for visibility.
        last_signal_key = None
        while trades < MAX_TRADES and day_pnl > -MAX_DAILY_LOSS:
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

            if time.time() - last_trade < COOLDOWN:
                continue

            action, fast, slow, momentum = signal(list(histories[symbol]))
            if not action:
                continue

            log(f"SIGNAL {symbol} {action} EMA9={fast:.6f} EMA21={slow:.6f} RSI14={momentum:.2f}")

            rid = client.send({
                "proposal": 1,
                "amount": STAKE,
                "basis": "stake",
                "contract_type": action,
                "currency": "USD",
                "duration": DURATION,
                "duration_unit": "s",
                "underlying_symbol": symbol,
            })
            try:
                proposal = client.recv_for(rid, "proposal", timeout=15)["proposal"]
            except Exception as exc:
                print(f"PROPOSAL FAILED {symbol} {action}: {exc}")
                continue

            log(f"PROPOSAL {symbol} {action} id={proposal.get("id")} ask={proposal["ask_price"]} payout={proposal.get("payout")}")
            last_trade = time.time()

            if DRY_RUN:
                trades += 1
                print(f"DRY_RUN=true: proposal only; simulated test {trades}/{MAX_TRADES}.")
                continue

            rid = client.send({
                "buy": proposal["id"],
                "price": float(proposal["ask_price"]),
            })
            try:
                bought = client.recv_for(rid, "buy", timeout=15)["buy"]
            except Exception as exc:
                print(f"BUY FAILED {symbol} {action}: {exc}")
                continue

            contract_id = bought["contract_id"]
            buy_time = time.time()
            buy_price = float(bought.get("buy_price", proposal.get("ask_price", STAKE)) or STAKE)
            trades += 1
            log(f"DEMO TRADE PURCHASED {trades}/{MAX_TRADES}: {symbol} {action} contract={contract_id} buy_price={buy_price} account={account_id}")

            client.send({
                "proposal_open_contract": 1,
                "contract_id": contract_id,
                "subscribe": 1,
            })

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
                    try:
                        srid = client.send({"statement": 1, "description": 1, "limit": 20, "action_type": "sell"})
                        stmt = client.recv_for(srid, "statement", timeout=10).get("statement", {})
                        log(f"STATEMENT_AFTER_CLOSE account={account_id} entries={len(stmt.get("transactions", [])) if isinstance(stmt, dict) else 0}")
                    except Exception as exc:
                        log(f"STATEMENT CHECK FAILED after close: {exc}")
                    break

                elapsed = time.time() - buy_time
                profit = float(c.get("profit", 0) or 0)
                if elapsed >= EARLY_PROFIT_SECONDS and profit > 0:
                    print(f"EARLY TAKE PROFIT: +{profit:.2f} after {elapsed:.1f}s. Selling Demo contract now.")
                    sell_rid = client.send({"sell": contract_id, "price": 0})
                    try:
                        sold = client.recv_for(sell_rid, "sell", timeout=10)["sell"]
                        sold_for = float(sold.get("sold_for", buy_price) or buy_price)
                        pnl = sold_for - buy_price
                        day_pnl += pnl
                        log(f"EARLY CLOSED {symbol} pnl={pnl:.2f} sold_for={sold_for:.2f} day_pnl={day_pnl:.2f} contract={contract_id}")
                        try:
                            srid = client.send({"statement": 1, "description": 1, "limit": 20, "action_type": "sell"})
                            stmt = client.recv_for(srid, "statement", timeout=10).get("statement", {})
                            log(f"STATEMENT_AFTER_EARLY_CLOSE account={account_id} entries={len(stmt.get("transactions", [])) if isinstance(stmt, dict) else 0}")
                        except Exception as exc:
                            log(f"STATEMENT CHECK FAILED after early close: {exc}")
                    except Exception as exc:
                        print(f"EARLY SELL FAILED: {exc}. Waiting for normal expiry.")
                    break

        log(f"BOT STOPPED trades={trades} day_pnl={day_pnl:.2f} | risk_limit={MAX_DAILY_LOSS:.2f}")
    finally:
        if client:
            client.close()

if __name__ == "__main__":
    main()
