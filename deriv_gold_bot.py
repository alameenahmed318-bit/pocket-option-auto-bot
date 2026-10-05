#!/usr/bin/env python3
import json, os, time
from collections import deque
from datetime import datetime, timezone

import requests
import websocket

API_BASE = "https://api.derivws.com"
TOKEN = os.getenv("DERIV_TOKEN", "").strip()
APP_ID = os.getenv("DERIV_APP_ID", "").strip()
ACCOUNT_ID_OVERRIDE = os.getenv("DERIV_ACCOUNT_ID", "").strip()

if not TOKEN or not APP_ID:
    raise SystemExit("Missing DERIV_TOKEN or DERIV_APP_ID GitHub secret.")

STAKE = float(os.getenv("STAKE_USD", "1"))
DURATION_SECONDS = int(os.getenv("DURATION_SECONDS", "60"))
MAX_TRADES = int(os.getenv("MAX_TRADES", "0"))
COOLDOWN_SECONDS = float(os.getenv("COOLDOWN_SECONDS", "3"))
MAX_DAILY_LOSS = float(os.getenv("MAX_DAILY_LOSS_USD", "15"))
DRY_RUN = os.getenv("DRY_RUN", "false").lower() == "true"
GOLD_SYMBOL_OVERRIDE = os.getenv("DERIV_GOLD_SYMBOL", "AUTO").strip()

FAST_EMA = 8
SLOW_EMA = 21
RSI_PERIOD = 14
MIN_EMA_GAP = float(os.getenv("MIN_EMA_GAP", "0.00008"))
MIN_MOMENTUM = float(os.getenv("MIN_MOMENTUM", "0.00010"))
LOG_FILE = "deriv_gold_trades.log"


def log(message):
    line = f"[{datetime.now(timezone.utc).isoformat()}] {message}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def headers():
    return {
        "Authorization": f"Bearer {TOKEN}",
        "Deriv-App-ID": APP_ID,
        "Content-Type": "application/json",
        "Accept": "application/json",
    }


def get_demo_account():
    r = requests.get(f"{API_BASE}/trading/v1/options/accounts", headers=headers(), timeout=20)
    if not r.ok:
        raise RuntimeError(f"Options account lookup failed HTTP {r.status_code}: {r.text}")
    body = r.json()
    data = body.get("data", [])
    accounts = [data] if isinstance(data, dict) else data if isinstance(data, list) else []
    demos = [a for a in accounts if str(a.get("account_type", "")).lower() == "demo"]

    if ACCOUNT_ID_OVERRIDE:
        matches = [a for a in demos if str(a.get("account_id", "")).strip() == ACCOUNT_ID_OVERRIDE]
        if not matches:
            raise RuntimeError("DERIV_ACCOUNT_ID is not an active DEMO Options account for this token.")
        account = matches[0]
    else:
        active = [a for a in demos if str(a.get("status", "")).lower() == "active"]
        if not active:
            raise RuntimeError("No active DEMO Options account was returned by Deriv.")
        account = active[0]

    account_id = str(account.get("account_id", "")).strip()
    if not account_id or str(account.get("account_type", "")).lower() != "demo":
        raise RuntimeError("SAFETY STOP: selected account is not DEMO.")
    log(f"DEMO ACCOUNT READY | balance={account.get('balance')} {account.get('currency', '')}")
    return account_id


def get_ws_url(account_id):
    r = requests.post(
        f"{API_BASE}/trading/v1/options/accounts/{account_id}/otp",
        headers=headers(),
        timeout=20,
    )
    if not r.ok:
        raise RuntimeError(f"Deriv OTP failed HTTP {r.status_code}: {r.text}")
    url = r.json().get("data", {}).get("url")
    if not url or "/demo?" not in url:
        raise RuntimeError("SAFETY STOP: Deriv did not return a DEMO WebSocket URL.")
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
        except websocket.WebSocketConnectionClosedException as exc:
            raise ConnectionError("Deriv WebSocket closed.") from exc

    def recv_for(self, req_id, msg_type=None, timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self.recv_json(max(1, deadline - time.time()))
            if msg is None:
                continue
            if msg.get("error"):
                err = msg["error"]
                raise RuntimeError(err.get("message", str(err)))
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
    rid = client.send({"balance": 1, "subscribe": 1})
    msg = client.recv_for(rid, "balance", 20)
    log(f"CONNECTED DEMO | balance={msg.get('balance')}")
    return client


def get_gold_symbol(client):
    rid = client.send({"active_symbols": "brief", "contract_type": ["CALL", "PUT"]})
    msg = client.recv_for(rid, "active_symbols", 30)
    candidates = []

    for item in msg.get("active_symbols", []):
        symbol = str(item.get("underlying_symbol", "")).strip()
        name = str(item.get("underlying_symbol_name", "")).strip()
        market = str(item.get("market", "")).strip().lower()
        text = f"{symbol} {name} {market}".lower()

        if not symbol or item.get("is_trading_suspended") == 1 or item.get("exchange_is_open") == 0:
            continue

        if GOLD_SYMBOL_OVERRIDE.upper() != "AUTO" and symbol == GOLD_SYMBOL_OVERRIDE:
            return symbol

        if "gold" in text or "xau" in text:
            candidates.append((symbol, name, market))

    if not candidates:
        raise RuntimeError("No active Gold/XAU CALL/PUT symbol was returned by Deriv.")

    candidates.sort(key=lambda x: (0 if "xau" in x[0].lower() else 1, x[0]))
    symbol, name, market = candidates[0]
    log(f"GOLD SYMBOL SELECTED | {symbol} | {name} | market={market}")
    return symbol


def ema(values, period):
    if len(values) < period:
        return None
    k = 2.0 / (period + 1.0)
    value = sum(values[:period]) / period
    for price in values[period:]:
        value = price * k + value * (1.0 - k)
    return value


def rsi(values, period=14):
    if len(values) < period + 1:
        return None
    gains, losses = [], []
    for a, b in zip(values[-period-1:-1], values[-period:]):
        d = b - a
        gains.append(max(d, 0.0))
        losses.append(max(-d, 0.0))
    avg_gain = sum(gains) / period
    avg_loss = sum(losses) / period
    if avg_loss == 0:
        return 100.0
    return 100.0 - (100.0 / (1.0 + avg_gain / avg_loss))


def get_signal(prices):
    if len(prices) < SLOW_EMA + RSI_PERIOD:
        return None

    fast = ema(prices, FAST_EMA)
    slow = ema(prices, SLOW_EMA)
    momentum = prices[-1] - prices[-4]
    rsi_value = rsi(prices, RSI_PERIOD)
    spot = prices[-1]

    if fast is None or slow is None or rsi_value is None or spot == 0:
        return None

    gap = abs(fast - slow) / abs(spot)
    momentum_pct = abs(momentum) / abs(spot)

    if fast > slow and momentum > 0 and gap >= MIN_EMA_GAP and momentum_pct >= MIN_MOMENTUM and 52 <= rsi_value <= 78:
        return "CALL", fast, slow, rsi_value, gap, momentum_pct
    if fast < slow and momentum < 0 and gap >= MIN_EMA_GAP and momentum_pct >= MIN_MOMENTUM and 22 <= rsi_value <= 48:
        return "PUT", fast, slow, rsi_value, gap, momentum_pct
    return None


def request_proposal(client, symbol, direction):
    rid = client.send({
        "proposal": 1,
        "amount": STAKE,
        "basis": "stake",
        "contract_type": direction,
        "currency": "USD",
        "duration": DURATION_SECONDS,
        "duration_unit": "s",
        "underlying_symbol": symbol,
        "subscribe": 1,
    })
    msg = client.recv_for(rid, "proposal", 20)
    proposal = msg.get("proposal", {})
    if not proposal.get("id") or proposal.get("ask_price") is None:
        raise RuntimeError(f"Invalid proposal response: {msg}")
    return proposal


def buy_and_monitor(client, proposal, symbol, direction):
    ask = float(proposal["ask_price"])
    rid = client.send({"buy": proposal["id"], "price": ask})
    msg = client.recv_for(rid, "buy", 20)
    bought = msg.get("buy", {})
    contract_id = bought.get("contract_id")
    if not contract_id:
        raise RuntimeError(f"Buy response contained no contract_id: {msg}")

    log(f"DEMO TRADE OPEN | {symbol} | {direction} | stake={ask:.2f} | duration={DURATION_SECONDS}s | contract={contract_id}")

    client.send({"proposal_open_contract": 1, "contract_id": contract_id, "subscribe": 1})
    deadline = time.time() + DURATION_SECONDS + 20

    while time.time() < deadline:
        msg = client.recv_json(20)
        if not msg or msg.get("msg_type") != "proposal_open_contract":
            continue
        contract = msg.get("proposal_open_contract", {})
        if str(contract.get("contract_id")) != str(contract_id):
            continue
        profit = float(contract.get("profit", 0) or 0)
        if contract.get("is_sold"):
            log(f"DEMO TRADE CLOSED | {symbol} | {direction} | profit={profit:+.2f} | contract={contract_id}")
            return profit

    log(f"CONTRACT MONITOR TIMEOUT | contract={contract_id} | Deriv will settle it.")
    return 0.0


def main():
    log(f"DERIV GOLD DEMO BOT START | stake={STAKE:.2f} | duration={DURATION_SECONDS}s | cooldown={COOLDOWN_SECONDS}s | max_daily_loss={MAX_DAILY_LOSS:.2f} | dry_run={DRY_RUN}")

    account_id = get_demo_account()
    client = None
    prices = deque(maxlen=180)
    trades = 0
    day_pnl = 0.0
    last_trade = 0.0

    try:
        client = connect(account_id)
        symbol = get_gold_symbol(client)
        client.send({"ticks": symbol, "subscribe": 1})

        warmup_deadline = time.time() + 120
        while len(prices) < 60 and time.time() < warmup_deadline:
            msg = client.recv_json(30)
            if not msg or msg.get("msg_type") != "tick":
                continue
            tick = msg.get("tick", {})
            if tick.get("symbol") == symbol and tick.get("quote") is not None:
                prices.append(float(tick["quote"]))

        if len(prices) < 60:
            raise RuntimeError(f"Gold warmup failed: only {len(prices)} ticks received.")

        log(f"GOLD DATA READY | {symbol} | ticks={len(prices)}")

        while (MAX_TRADES <= 0 or trades < MAX_TRADES) and day_pnl > -MAX_DAILY_LOSS:
            try:
                msg = client.recv_json(30)
            except ConnectionError:
                log("WEBSOCKET CLOSED | reconnecting...")
                client.close()
                client = connect(account_id)
                symbol = get_gold_symbol(client)
                client.send({"ticks": symbol, "subscribe": 1})
                continue

            if not msg or msg.get("msg_type") != "tick":
                continue

            tick = msg.get("tick", {})
            if tick.get("symbol") != symbol or tick.get("quote") is None:
                continue

            prices.append(float(tick["quote"]))

            if time.time() - last_trade < COOLDOWN_SECONDS:
                continue

            decision = get_signal(list(prices))
            if not decision:
                continue

            direction, fast, slow, rsi_value, gap, momentum_pct = decision
            log(f"GOLD SIGNAL | {symbol} | {direction} | EMA{FAST_EMA}={fast:.5f} EMA{SLOW_EMA}={slow:.5f} RSI={rsi_value:.2f} gap={gap:.6f} momentum={momentum_pct:.6f}")

            try:
                proposal = request_proposal(client, symbol, direction)
            except Exception as exc:
                log(f"PROPOSAL FAILED | {direction} | {exc}")
                continue

            log(f"PROPOSAL READY | {direction} | ask={float(proposal['ask_price']):.2f} | payout={proposal.get('payout')}")
            last_trade = time.time()

            if DRY_RUN:
                trades += 1
                log(f"DRY_RUN=true | no purchase | simulated={trades}")
                continue

            try:
                pnl = buy_and_monitor(client, proposal, symbol, direction)
                trades += 1
                day_pnl += pnl
                log(f"TRADE #{trades} | day_pnl={day_pnl:+.2f}")
            except Exception as exc:
                log(f"TRADE ERROR | {exc}")
                time.sleep(2)

        log(f"BOT STOPPED | trades={trades} | day_pnl={day_pnl:+.2f}")

    finally:
        if client:
            client.close()


if __name__ == "__main__":
    main()
