import os, time, logging
from dotenv import load_dotenv

load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s [PO-DEMO] %(levelname)s %(message)s")

DEMO_ONLY = os.getenv("DEMO_ONLY", "true").lower() == "true"
ASSET = os.getenv("ASSET", "EURUSD_otc")
PERIOD = int(os.getenv("PERIOD", "300"))
EXPIRATION = int(os.getenv("EXPIRATION", "60"))
STAKE = float(os.getenv("STAKE", "1"))
PAYOUT_MIN = float(os.getenv("PAYOUT_MIN", "70"))
SCAN_SECONDS = int(os.getenv("SCAN_SECONDS", "5"))
MAX_TRADES = int(os.getenv("MAX_TRADES_PER_RUN", "5"))
MAX_LOSS = float(os.getenv("MAX_DAILY_LOSS", "5"))
PO_SSID = os.getenv("PO_SSID", "").strip()

def validate():
    if not DEMO_ONLY:
        raise RuntimeError("LIVE trading is disabled. DEMO_ONLY must remain true.")
    if not PO_SSID:
        raise RuntimeError("Missing PO_SSID GitHub Actions secret.")
    if STAKE <= 0 or MAX_TRADES < 1 or MAX_LOSS <= 0:
        raise RuntimeError("Invalid risk configuration.")

def closes_from(candles):
    out = []
    for c in candles or []:
        v = c.get("close", c.get("closePrice", c.get("value"))) if isinstance(c, dict) else getattr(c, "close", None)
        try:
            out.append(float(v))
        except (TypeError, ValueError):
            pass
    return out

def ema(values, n):
    k = 2 / (n + 1)
    e = values[0]
    for v in values[1:]:
        e = v * k + e * (1 - k)
    return e

def rsi(values, n=14):
    if len(values) <= n:
        return 50.0
    gains, losses = [], []
    for a, b in zip(values[-n-1:-1], values[-n:]):
        d = b - a
        gains.append(max(d, 0))
        losses.append(max(-d, 0))
    ag, al = sum(gains) / n, sum(losses) / n
    if al == 0:
        return 100.0
    return 100 - (100 / (1 + ag / al))

def signal(closes):
    if len(closes) < 30:
        return None
    fast, slow = ema(closes[-30:], 9), ema(closes[-30:], 21)
    rr, last, prev = rsi(closes, 14), closes[-1], closes[-2]
    if fast > slow and last > prev and 52 <= rr <= 72:
        return "call"
    if fast < slow and last < prev and 28 <= rr <= 48:
        return "put"
    return None

def main():
    validate()
    from pocketoptionapi import PocketOption

    api = PocketOption(PO_SSID)
    ok, err = api.connect()
    if not ok:
        raise RuntimeError(f"WebSocket connection failed: {err}")

    deadline = time.time() + 30
    while time.time() < deadline and not (api.check_connect() and api.is_time_synced()):
        time.sleep(0.25)
    if not api.check_connect():
        raise RuntimeError("WebSocket did not become ready.")

    logging.info("DEMO connected | balance=%s | asset=%s | period=%ss | expiry=%ss",
                 api.get_balance(), ASSET, PERIOD, EXPIRATION)
    api.subscribe(ASSET, period=PERIOD)

    trades, pnl, last_bar = 0, 0.0, None

    while trades < MAX_TRADES:
        payout = api.get_payout(ASSET)
        if payout is not None and payout < PAYOUT_MIN:
            logging.info("WAIT | payout=%.1f%% below %.1f%%", payout, PAYOUT_MIN)
            time.sleep(SCAN_SECONDS)
            continue

        candles = api.get_historical_candles(ASSET, period=PERIOD, offset=9000, count_request=1)
        closes = closes_from(candles)
        if len(closes) < 30:
            logging.info("WAIT | candles=%d", len(closes))
            time.sleep(SCAN_SECONDS)
            continue

        bar_key = len(candles)
        sig = signal(closes)
        logging.info("SCAN | signal=%s | ema9=%.6f ema21=%.6f rsi=%.1f payout=%s",
                     sig, ema(closes[-30:], 9), ema(closes[-30:], 21), rsi(closes), payout)

        if not sig or bar_key == last_bar:
            time.sleep(SCAN_SECONDS)
            continue

        order, sent = api.buy(STAKE, ASSET, sig, EXPIRATION)
        if not sent:
            logging.error("ORDER FAILED | direction=%s", sig)
            time.sleep(SCAN_SECONDS)
            continue

        trades += 1
        last_bar = bar_key
        oid = order.get("id") or order.get("id_number") or order.get("requestId")
        logging.info("OPENED DEMO | direction=%s | stake=%.2f | expiry=%ss | id=%s",
                     sig, STAKE, EXPIRATION, oid)

        time.sleep(EXPIRATION + 3)
        result = api.check_win(oid) if oid is not None else None
        logging.info("RESULT | %s", result)

        if isinstance(result, dict):
            for key in ("profit", "profit_amount", "amount"):
                if key in result:
                    try:
                        pnl += float(result[key])
                    except (TypeError, ValueError):
                        pass
                    break

        if pnl <= -MAX_LOSS:
            logging.warning("STOP | demo loss limit reached: %.2f", pnl)
            break

    logging.info("RUN COMPLETE | trades=%d | tracked_pnl=%.2f", trades, pnl)
    try:
        api.disconnect_websocket()
    except Exception:
        pass

if __name__ == "__main__":
    main()
