import os
import time
import logging
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [PO-MONITOR] %(levelname)s %(message)s",
)

# This build is intentionally non-executing: it never sends broker orders.
DEMO_ONLY = True

ASSET = os.getenv("ASSET", "EURUSD_otc")
PERIOD = int(os.getenv("PERIOD", "60"))
SCAN_SECONDS = float(os.getenv("SCAN_SECONDS", "5"))
MAX_RUNTIME_SECONDS = int(os.getenv("MAX_RUNTIME_SECONDS", "540"))


def closes_from(candles):
    out = []
    for candle in candles or []:
        try:
            out.append(float(candle.get("close")))
        except (TypeError, ValueError, AttributeError):
            continue
    return out


def ema(values, n):
    if not values:
        return 0.0
    k = 2 / (n + 1)
    value = values[0]
    for item in values[1:]:
        value = item * k + value * (1 - k)
    return value


def rsi(values, n=14):
    if len(values) <= n:
        return 50.0
    gains = losses = 0.0
    for a, b in zip(values[-n - 1:-1], values[-n:]):
        delta = b - a
        gains += max(delta, 0.0)
        losses += max(-delta, 0.0)
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
        "CONNECTED | LIVE MARKET MONITOR | asset=%s | period=%ss | scan=%ss",
        ASSET,
        PERIOD,
        SCAN_SECONDS,
    )

    api.subscribe(ASSET, period=PERIOD)

    balance = api.get_balance()
    payout = api.get_payout(ASSET)
    logging.info("ACCOUNT | balance=%s | payout=%s%%", balance, payout)

    started = time.time()
    last_signal = None

    try:
        while time.time() - started < MAX_RUNTIME_SECONDS:
            candles = api.get_historical_candles(
                ASSET,
                period=PERIOD,
                offset=0,
                count_request=80,
            )
            closes = closes_from(candles)

            if len(closes) < 30:
                logging.info("WAIT | insufficient candles=%d", len(closes))
                time.sleep(SCAN_SECONDS)
                continue

            direction = signal(closes)
            entry = closes[-1]

            if direction != last_signal:
                logging.info(
                    "SIGNAL_CHANGE | signal=%s | price=%.6f | rsi=%.2f",
                    direction or "NONE",
                    entry,
                    rsi(closes),
                )
                last_signal = direction

            if direction:
                # Execution is deliberately blocked in this build.
                logging.info(
                    "TRADE_READY | direction=%s | entry=%.6f | EXECUTION_BLOCKED",
                    direction,
                    entry,
                )

            time.sleep(SCAN_SECONDS)

    finally:
        api.disconnect_websocket()
        logging.info("STOPPED | market monitor disconnected")


if __name__ == "__main__":
    main()
