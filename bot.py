import os
import time
import logging
from dotenv import load_dotenv

load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s [PO-PAPER] %(levelname)s %(message)s")

DEMO_ONLY = os.getenv("DEMO_ONLY", "true").lower() == "true"
ASSET = os.getenv("ASSET", "EURUSD_otc")
PERIOD = int(os.getenv("PERIOD", "300"))
EXPIRATION = int(os.getenv("EXPIRATION", "60"))
STAKE = float(os.getenv("STAKE", "1"))
MAX_TRADES = int(os.getenv("MAX_TRADES_PER_RUN", "5"))

def closes_from(candles):
    out = []
    for c in candles or []:
        try: out.append(float(c.get("close")))
        except (TypeError, ValueError, AttributeError): pass
    return out

def ema(values, n):
    k = 2 / (n + 1); e = values[0]
    for v in values[1:]: e = v * k + e * (1 - k)
    return e

def rsi(values, n=14):
    if len(values) <= n: return 50.0
    gains = losses = 0.0
    for a, b in zip(values[-n-1:-1], values[-n:]):
        d = b - a; gains += max(d, 0); losses += max(-d, 0)
    if losses == 0: return 100.0
    return 100 - (100 / (1 + (gains/n) / (losses/n)))

def signal(values):
    if len(values) < 30: return None
    fast, slow, rr = ema(values[-30:], 9), ema(values[-30:], 21), rsi(values)
    if fast > slow and values[-1] > values[-2] and 52 <= rr <= 72: return "CALL"
    if fast < slow and values[-1] < values[-2] and 28 <= rr <= 48: return "PUT"
    return None

def main():
    if not DEMO_ONLY: raise RuntimeError("Safety lock: DEMO_ONLY must remain true.")
    ssid = os.getenv("PO_SSID", "").strip()
    if not ssid: raise RuntimeError("Missing PO_SSID secret.")

    from pocketoptionapi import PocketOption
    api = PocketOption(ssid)
    ok, err = api.connect()
    if not ok: raise RuntimeError(f"WebSocket connection failed: {err}")

    deadline = time.time() + 30
    while time.time() < deadline and not (api.check_connect() and api.is_time_synced()):
        time.sleep(0.25)
    if not api.check_connect(): raise RuntimeError("WebSocket did not become ready.")

    logging.info("CONNECTED | DEMO DATA / PAPER ONLY | asset=%s | M5 | expiry=%ss", ASSET, EXPIRATION)
    api.subscribe(ASSET, period=PERIOD)
    logging.info("ACCOUNT | demo_balance=%s | payout=%s%%", api.get_balance(), api.get_payout(ASSET))

    signals = 0
    for _ in range(MAX_TRADES):
        candles = api.get_historical_candles(ASSET, period=PERIOD, offset=9000, count_request=40)
        closes = closes_from(candles)
        if len(closes) < 30:
            logging.warning("WAIT | insufficient candles=%d", len(closes)); time.sleep(5); continue
        direction = signal(closes)
        logging.info("SIGNAL | %s | entry=%.6f", direction or "NONE", closes[-1])
        if direction:
            signals += 1
            logging.info("PAPER | would_open=%s | stake=%.2f | expiry=%ss | NO_ORDER_SENT",
                         direction, STAKE, EXPIRATION)
        time.sleep(2)

    logging.info("RUN COMPLETE | paper_signals=%d | NO REAL/DEMO ORDER EXECUTED", signals)
    api.disconnect_websocket()

if __name__ == "__main__": main()
