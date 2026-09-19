import os
import sys
import time

from dotenv import load_dotenv

load_dotenv()

DEMO_ONLY = os.getenv("DEMO_ONLY", "true").lower() == "true"
SSID = os.getenv("PO_SESSION", "")

if not DEMO_ONLY:
    raise RuntimeError("Safety stop: DEMO_ONLY must be true.")

if not SSID:
    raise RuntimeError(
        "No Demo SSID found. Add PO_SESSION with the complete Demo auth string."
    )

from pocketoptionapi.stable_api import PocketOption

api = PocketOption(True)
ok, message = api.connect()

if not ok:
    raise RuntimeError(f"Demo connection failed: {message}")

time.sleep(3)

try:
    balance = api.GetBalance()
    print("DEMO CONNECTION: OK")
    print(f"Demo balance: {balance}")
    print("NO TRADE WAS PLACED.")
finally:
    try:
        api.close()
    except Exception:
        pass
