import os
import time
from datetime import datetime, timezone
from dotenv import load_dotenv

load_dotenv()

DEMO_ONLY = os.getenv("DEMO_ONLY", "true").lower() == "true"
SSID = os.getenv("POCKET_OPTION_SSID", "").strip()
EMAIL = os.getenv("POCKET_OPTION_EMAIL", "").strip()
PASSWORD = os.getenv("POCKET_OPTION_PASSWORD", "").strip()
ALLOW_EMAIL_LOGIN = os.getenv("ALLOW_EMAIL_LOGIN", "true").lower() == "true"
SESSION_FILE = os.getenv("POCKET_OPTION_SESSION_FILE", os.path.join(os.getenv("RAILWAY_VOLUME_MOUNT_PATH", "/data"), "pocket_demo_ssid.txt"))

def load_cached_ssid():
    try:
        with open(SESSION_FILE, "r", encoding="utf-8") as f:
            value = f.read().strip()
        return value if value.startswith("42[") else ""
    except (FileNotFoundError, OSError):
        return ""

def save_cached_ssid(value):
    if not value or not value.startswith("42["):
        return
    directory = os.path.dirname(SESSION_FILE)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = SESSION_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(value)
    os.replace(tmp, SESSION_FILE)

ASSET = os.getenv("PO_ASSET", "EURUSD_otc")
STAKE = float(os.getenv("STAKE", "1"))
DURATION = int(os.getenv("TRADE_DURATION", "60"))
CANDLE_PERIOD = int(os.getenv("CANDLE_PERIOD", "60"))
MAX_TRADES = int(os.getenv("MAX_TRADES_PER_RUN", "3"))
MAX_DAILY_LOSS = float(os.getenv("MAX_DAILY_LOSS", "3"))
COOLDOWN = int(os.getenv("COOLDOWN_SECONDS", "90"))

if not DEMO_ONLY:
    raise RuntimeError("Safety stop: DEMO_ONLY must be true.")

if SSID and not SSID.startswith("42["):
    raise RuntimeError(
        "POCKET_OPTION_SSID must be the full Pocket Option session string starting with 42[."
    )

if not SSID and (not EMAIL or not PASSWORD):
    raise RuntimeError(
        "Missing Pocket Option Demo authentication. Provide POCKET_OPTION_SSID or POCKET_OPTION_EMAIL + POCKET_OPTION_PASSWORD as GitHub Secrets."
    )

if STAKE <= 0 or DURATION < 5 or MAX_TRADES < 1 or MAX_DAILY_LOSS <= 0:
    raise RuntimeError("Invalid trading configuration.")

from BinaryOptionsToolsV2.pocketoption import PocketOption


def ema(values, period):
    if len(values) < period:
        return None
    k = 2 / (period + 1)
    value = sum(values[:period]) / period
    for price in values[period:]:
        value = price * k + value * (1 - k)
    return value


def rsi(values, period=14):
    if len(values) < period + 1:
        return None
    gains, losses = [], []
    for a, b in zip(values[-(period + 1):-1], values[-period:]):
        change = b - a
        gains.append(max(change, 0))
        losses.append(max(-change, 0))
    avg_gain = sum(gains) / period
    avg_loss = sum(losses) / period
    if avg_loss == 0:
        return 100.0
    rs = avg_gain / avg_loss
    return 100 - (100 / (1 + rs))


def get_close(candle):
    if hasattr(candle, "close"):
        return float(candle.close)
    if isinstance(candle, dict):
        return float(candle.get("close", candle.get("close_price")))
    return float(candle["close"])


print("DEMO ONLY: true")

# Authentication order: explicit SSID, cached Railway session, then optional one-time login.
if SSID:
    print("AUTH: using Pocket Option Demo SSID (value hidden).")
else:
    cached = load_cached_ssid()
    if cached:
        SSID = cached
        print("AUTH: using cached Demo session from persistent storage (value hidden).")
    elif not ALLOW_EMAIL_LOGIN:
        raise RuntimeError("No Demo session available. GitHub Actions no longer attempts browser login. Run on Railway with a persistent volume, or provide POCKET_OPTION_SSID as a secret.")
    else:
        if not EMAIL or not PASSWORD:
            raise RuntimeError("No Demo session available. Configure Demo email/password for the one-time Railway bootstrap, or provide POCKET_OPTION_SSID.")
        print("AUTH: bootstrapping Demo email/password login on the hosting service. Session value remains hidden.")
        try:
            from BinaryOptionsToolsV2.pocketoption.tools.login import login
            SSID = login(EMAIL, PASSWORD, demo=True, backend="playwright", headless=True, timeout=60)
            print("AUTH: email/password login succeeded; generated Demo session.")
        except Exception as exc:
            raise RuntimeError(f"Demo email/password login failed without bypassing site security: {exc}") from exc

save_cached_ssid(SSID)

api = PocketOption(SSID)

try:
    print("POCKET OPTION: connecting...")
    time.sleep(2)

    if not api.is_demo():
        raise RuntimeError("Safety stop: supplied session is NOT a Demo account.")

    balance = api.balance()
    print(f"DEMO BALANCE: ${float(balance):.2f}")
    print(
        f"BOT CONFIG: asset={ASSET}, stake=${STAKE:.2f}, "
        f"duration={DURATION}s, max_trades={MAX_TRADES}"
    )

    daily_pnl = 0.0
    trades = 0

    while trades < MAX_TRADES and daily_pnl > -MAX_DAILY_LOSS:
        try:
            candles = api.get_candles(ASSET, CANDLE_PERIOD, 60)
            closes = [get_close(c) for c in candles]
        except Exception as exc:
            print(f"MARKET DATA ERROR: {exc}")
            time.sleep(COOLDOWN)
            continue

        if len(closes) < 30:
            print(f"WAITING: not enough candles ({len(closes)}/30).")
            time.sleep(COOLDOWN)
            continue

        fast = ema(closes, 9)
        slow = ema(closes, 21)
        current_rsi = rsi(closes, 14)

        if fast > slow and 50 <= current_rsi <= 70:
            action = "BUY/CALL"
        elif fast < slow and 30 <= current_rsi <= 50:
            action = "SELL/PUT"
        else:
            action = None

        now = datetime.now(timezone.utc).strftime("%H:%M:%S UTC")
        print(
            f"{now} SIGNAL: EMA9={fast:.6f}, EMA21={slow:.6f}, "
            f"RSI14={current_rsi:.2f}, action={action}"
        )

        if not action:
            time.sleep(COOLDOWN)
            continue

        try:
            if action == "BUY/CALL":
                trade_id, deal = api.buy(ASSET, STAKE, DURATION)
            else:
                trade_id, deal = api.sell(ASSET, STAKE, DURATION)

            trades += 1
            print(
                f"TRADE OPENED: id={trade_id}, action={action}, "
                f"stake=${STAKE:.2f}, duration={DURATION}s"
            )

            result = api.check_win(trade_id)
            profit = float(result.get("profit", 0) or 0)
            daily_pnl += profit

            print(
                f"TRADE CLOSED: id={trade_id}, "
                f"result={result.get('result')}, profit=${profit:.2f}"
            )
            print(f"SESSION P/L: ${daily_pnl:.2f}; trades={trades}/{MAX_TRADES}")

            if daily_pnl <= -MAX_DAILY_LOSS:
                print("AUTO-STOP: daily loss limit reached.")
                break

        except Exception as exc:
            print(f"TRADE ERROR: {exc}")
            time.sleep(COOLDOWN)
            continue

        time.sleep(COOLDOWN)

    print("BOT STOPPED: safety limits reached or no valid signal.")
    print("DEMO ONLY: no real-money trade was permitted.")

finally:
    try:
        api.shutdown()
    except Exception:
        pass
