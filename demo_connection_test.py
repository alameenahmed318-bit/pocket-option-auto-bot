import os
import time

from dotenv import load_dotenv

load_dotenv()

DEMO_ONLY = os.getenv("DEMO_ONLY", "true").lower() == "true"
EMAIL = os.getenv("POCKET_OPTION_EMAIL", "")
PASSWORD = os.getenv("POCKET_OPTION_PASSWORD", "")
BACKEND = os.getenv("PO_LOGIN_BACKEND", "auto").lower()
CAPSOLVER_KEY = os.getenv("CAPSOLVER_API_KEY", "")

if not DEMO_ONLY:
    raise RuntimeError("Safety stop: DEMO_ONLY must be true.")

if not EMAIL or not PASSWORD:
    raise RuntimeError(
        "Missing POCKET_OPTION_EMAIL or POCKET_OPTION_PASSWORD in Railway Variables."
    )

from BinaryOptionsToolsV2.pocketoption.tools.login import LoginError, login
from BinaryOptionsToolsV2.pocketoption import PocketOption

kwargs = {
    "demo": True,
    "backend": BACKEND,
    "headless": True,
    "timeout": 60,
}

if BACKEND == "capsolver":
    if not CAPSOLVER_KEY:
        raise RuntimeError(
            "PO_LOGIN_BACKEND=capsolver requires CAPSOLVER_API_KEY in Railway Variables."
        )
    kwargs["api_key"] = CAPSOLVER_KEY

print(f"LOGIN: starting automatic Demo login using backend={BACKEND}")

try:
    ssid = login(EMAIL, PASSWORD, **kwargs)
except LoginError as exc:
    raise RuntimeError(f"Automatic Demo login failed: {exc}") from exc

print("LOGIN: OK")
print("SESSION: obtained automatically; not printed for security.")

api = PocketOption(ssid, is_demo=True)
api.connect()

time.sleep(3)

try:
    balance = api.get_balance()
    print("DEMO CONNECTION: OK")
    print(f"Demo balance: {balance}")
    print("NO TRADE WAS PLACED.")
finally:
    try:
        api.disconnect()
    except Exception:
        pass
