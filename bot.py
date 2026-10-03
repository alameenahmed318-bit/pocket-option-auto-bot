import os
import time
import logging
from dotenv import load_dotenv

load_dotenv()
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [PO-DEMO] %(levelname)s %(message)s",
)

# Safety: this build is permanently paper/demo-data only.
DEMO_ONLY = os.getenv("DEMO_ONLY", "true").lower() == "true"
if not DEMO_ONLY:
    raise RuntimeError("Safety lock: DEMO_ONLY must remain true.")

ASSET = os.getenv("ASSET", "EURUSD_otc")
PERIOD = int(os.getenv("PERIOD", "300"))          # M5
EXPIRATION = int(os.getenv("EXPIRATION", "60"))   # simulated seconds
STAKE = float(os.getenv("STAKE", "1"))
MAX_TRADES = int(os.getenv("MAX_TRADES_PER_RUN", "5"))


def closes_from(candles):
    out = []
    for c in candles or []:
        try:
            out.append(float(c.get("close")))
        except (TypeError, ValueError, AttributeError):
            pass
    return out


def ema(values, n):
    if not values:
        return 0.0
    k = 2 / (n + 1)
    e = values[0]
    for v in values[1:]:
        e = v * k + e * (1 - k)
    return e


def rsi(values, n=14):
    if len(values) <= n:
        return 50.0
    gains = losses = 0.0
    for a, b in zip(values[-n - 1:-1], values[-n:]):
        d = b - a
        gains += max(d, 0)
        losses += max(-d, 0)
    if losses == 0:
        return 100.0
    avg_gain = gains / n
    avg_loss = losses / n
    return 100 - (100 / (1 + avg_gain / avg_loss))


def signal(values):
    if len(values) < 30:
        return None
    fast = ema(values[-30:], 9)
    slow = ema(values[-30:], 21)
    rr = rsi(values)
    if fast > slow and values[-1] > values[-2] and 52 <= rr <= 72:
        return "CALL"
    if fast < slow and values[-1] < values[-2] and 28 <= rr <= 48:
        return "PUT"
    return None


def simulated_result(direction, entry, expiry_price):
    if direction == "CALL":
        return "WIN" if expiry_price > entry else "LOSS" if expiry_price < entry else "DRAW"
    return "WIN" if expiry_price < entry else "LOSS" if expiry_price > entry else "DRAW"


def main():
    ssid = os.getenv("PO_SSID", "").strip()
    if not ssid:
        raise RuntimeError("Missing PO_SSID secret.")

    from pocketoptionapi import PocketOption

    api = PocketOption(ssid)
    ok, err = api.connect()
    if not ok:
        raise RuntimeError(f"WebSocket connection failed: {err}")

    deadline = time.time() + 30
    while time.time() < deadline and not (
        api.check_connect() and api.is_time_synced()
    ):
        time.sleep(0.25)

    if not api.check_connect():
        raise RuntimeError("WebSocket did not become ready.")

    logging.info(
        "CONNECTED | DEMO DATA / PAPER ONLY | asset=%s | M5 | simulated_expiry=%ss",
        ASSET, EXPIRATION
    )
    api.subscribe(ASSET, period=PERIOD)

    balance = api.get_balance()
    payout = api.get_payout(ASSET)
    logging.info("ACCOUNT | balance=%s | payout=%s%%", balance, payout)

    wins = losses = draws = signals = 0

    for n in range(1, MAX_TRADES + 1):
        # Current market snapshot used for the signal.
        candles = api.get_historical_candles(
            ASSET, period=PERIOD, offset=9000, count_request=80
        )
        closes = closes_from(candles)

        if len(closes) < 30:
            logging.warning("WAIT | insufficient candles=%d", len(closes))
            time.sleep(5)
            continue

        direction = signal(closes)
        entry = closes[-1]
        logging.info(
            "SIGNAL %d/%d | %s | entry=%.6f",
            n, MAX_TRADES, direction or "NONE", entry
        )

        if not direction:
            time.sleep(2)
            continue

        signals += 1

        # We do NOT call buy() or any order endpoint.
        # For the paper result, use the latest available candle after the
        # simulated expiry window. This is an approximate backtest-style
        # outcome, not a broker settlement.
        future = api.get_historical_candles(
            ASSET, period=PERIOD, offset=9000 - max(1, EXPIRATION // PERIOD),
            count_request=80
        )
        future_closes = closes_from(future)
        expiry_price = future_closes[-1] if future_closes else entry

        result = simulated_result(direction, entry, expiry_price)
        if result == "WIN":
            wins += 1
        elif result == "LOSS":
            losses += 1
        else:
            draws += 1

        logging.info(
            "PAPER_RESULT | direction=%s | entry=%.6f | expiry=%.6f | result=%s | stake=%.2f | NO_ORDER_SENT",
            direction, entry, expiry_price, result, STAKE
        )
        time.sleep(2)

    total = wins + losses + draws
    win_rate = (wins / (wins + losses) * 100) if (wins + losses) else 0.0

    logging.info(
        "RUN COMPLETE | signals=%d | wins=%d | losses=%d | draws=%d | win_rate=%.1f%% | NO REAL/DEMO ORDER EXECUTED",
        signals, wins, losses, draws, win_rate
    )

    api.disconnect_websocket()


if __name__ == "__main__":
    main()
