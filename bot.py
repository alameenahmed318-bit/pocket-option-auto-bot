import os
import time
from dotenv import load_dotenv

load_dotenv()

DEMO_ONLY = os.getenv("DEMO_ONLY", "true").lower() == "true"
STAKE = float(os.getenv("STAKE", "1"))
MAX_TRADES_PER_RUN = int(os.getenv("MAX_TRADES_PER_RUN", "3"))
MAX_DAILY_LOSS = float(os.getenv("MAX_DAILY_LOSS", "3"))
PO_SESSION = os.getenv("PO_SESSION", "")
PO_UID = os.getenv("PO_UID", "")

def validate_config():
    if not DEMO_ONLY:
        raise RuntimeError("Live execution is blocked. DEMO_ONLY must remain true.")
    if STAKE <= 0 or MAX_TRADES_PER_RUN < 1 or MAX_DAILY_LOSS <= 0:
        raise ValueError("Invalid risk configuration.")
    if not PO_SESSION or not PO_UID:
        raise RuntimeError("Pocket Option session is not configured. Add PO_SESSION and PO_UID as GitHub Actions secrets.")

def main():
    validate_config()
    from pocketoptionapi.stable_api import PocketOption
    api = PocketOption(True)
    api.connect()
    time.sleep(3)
    balance = api.GetBalance()
    print(f"Connected to Pocket Option DEMO. Balance: {balance}")
    print(f"Risk: stake=${STAKE:.2f}, max trades/run={MAX_TRADES_PER_RUN}, daily loss=${MAX_DAILY_LOSS:.2f}")
    print("Trading is not enabled yet; connection must be verified first.")

if __name__ == "__main__":
    main()