#!/usr/bin/env python3
import json, os, time
from collections import deque
import requests
import websocket

API_BASE = "https://api.derivws.com"
DEMO_ONLY = os.getenv("DEMO_ONLY", "true").lower() == "true"
TOKEN = os.getenv("DERIV_TOKEN", "").strip()
APP_ID = os.getenv("DERIV_APP_ID", "").strip()
ACCOUNT_ID = os.getenv("DERIV_ACCOUNT_ID", "").strip()
SYMBOL = os.getenv("DERIV_SYMBOL", "frxEURUSD").strip()
STAKE = float(os.getenv("STAKE_USD", "1"))
DURATION = int(os.getenv("DURATION_SECONDS", "60"))
MAX_TRADES = int(os.getenv("MAX_TRADES", "3"))
COOLDOWN = int(os.getenv("COOLDOWN_SECONDS", "90"))
MAX_DAILY_LOSS = float(os.getenv("MAX_DAILY_LOSS_USD", "3"))
DRY_RUN = os.getenv("DRY_RUN", "true").lower() == "true"

if not DEMO_ONLY:
    raise SystemExit("Safety stop: DEMO_ONLY must remain true.")
if not TOKEN or not APP_ID or not ACCOUNT_ID:
    raise SystemExit("Missing DERIV_TOKEN, DERIV_APP_ID, or DERIV_ACCOUNT_ID.")

def get_ws_url():
    r = requests.post(
        f"{API_BASE}/trading/v1/options/accounts/{ACCOUNT_ID}/otp",
        headers={"Authorization": f"Bearer {TOKEN}", "Deriv-App-ID": APP_ID},
        timeout=20,
    )
    r.raise_for_status()
    url = r.json().get("data", {}).get("url")
    if not url:
        raise RuntimeError(f"No WebSocket URL returned: {r.text}")
    return url

class Client:
    def __init__(self, url):
        self.ws = websocket.create_connection(url, timeout=20)
        self.req_id = 0

    def send(self, payload):
        self.req_id += 1
        payload = dict(payload, req_id=self.req_id)
        self.ws.send(json.dumps(payload))
        return self.req_id

    def recv_for(self, req_id, msg_type=None, timeout=20):
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.ws.settimeout(max(1, deadline - time.time()))
            msg = json.loads(self.ws.recv())
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
    if fast > slow and 50 <= momentum <= 70:
        return "CALL", fast, slow, momentum
    if fast < slow and 30 <= momentum <= 50:
        return "PUT", fast, slow, momentum
    return None, fast, slow, momentum

def main():
    print(f"DERIV DEMO BOT | {SYMBOL} | stake={STAKE} | duration={DURATION}s | DRY_RUN={DRY_RUN}")
    client = Client(get_ws_url())
    prices = deque(maxlen=120)
    trades = 0
    day_pnl = 0.0
    last_trade = 0.0

    try:
        rid = client.send({"balance": 1})
        print("Connected:", client.recv_for(rid, "balance")["balance"])

        client.send({"ticks": SYMBOL, "subscribe": 1})
        deadline = time.time() + 120
        while time.time() < deadline and len(prices) < 40:
            msg = json.loads(client.ws.recv())
            if msg.get("msg_type") == "tick":
                quote = msg.get("tick", {}).get("quote")
                if quote is not None:
                    prices.append(float(quote))

        if len(prices) < 40:
            raise RuntimeError("Not enough tick data to start.")

        while trades < MAX_TRADES and day_pnl > -MAX_DAILY_LOSS:
            msg = json.loads(client.ws.recv())
            if msg.get("msg_type") != "tick":
                continue
            quote = msg.get("tick", {}).get("quote")
            if quote is None:
                continue
            prices.append(float(quote))

            action, fast, slow, momentum = signal(list(prices))
            if not action or time.time() - last_trade < COOLDOWN:
                continue

            print(f"SIGNAL {action} EMA9={fast:.6f} EMA21={slow:.6f} RSI14={momentum:.2f}")

            rid = client.send({
                "proposal": 1,
                "amount": STAKE,
                "basis": "stake",
                "contract_type": action,
                "currency": "USD",
                "duration": DURATION,
                "duration_unit": "s",
                "underlying_symbol": SYMBOL,
            })
            proposal = client.recv_for(rid, "proposal")["proposal"]
            print(f"PROPOSAL {action} ask={proposal['ask_price']} payout={proposal.get('payout')}")

            last_trade = time.time()
            if DRY_RUN:
                print("DRY_RUN=true: proposal only; no contract purchased.")
                continue

            rid = client.send({"buy": proposal["id"], "price": float(proposal["ask_price"])})
            bought = client.recv_for(rid, "buy")["buy"]
            contract_id = bought["contract_id"]
            trades += 1
            print(f"DEMO TRADE PURCHASED {trades}/{MAX_TRADES}: {action} contract={contract_id}")

            client.send({
                "proposal_open_contract": 1,
                "contract_id": contract_id,
                "subscribe": 1,
            })
            while True:
                update = json.loads(client.ws.recv())
                if update.get("msg_type") != "proposal_open_contract":
                    continue
                c = update.get("proposal_open_contract", {})
                if str(c.get("contract_id")) != str(contract_id):
                    continue
                if c.get("is_sold"):
                    pnl = float(c.get("profit", 0) or 0)
                    day_pnl += pnl
                    print(f"CLOSED pnl={pnl:.2f} day_pnl={day_pnl:.2f}")
                    break

        print(f"BOT STOPPED trades={trades} day_pnl={day_pnl:.2f}")
    finally:
        client.close()

if __name__ == "__main__":
    main()
