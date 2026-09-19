import asyncio
import os

from pocket_trader import PocketOptionClient, Regions

DEMO_ONLY = os.getenv("DEMO_ONLY", "true").lower() == "true"
PO_SESSION = os.getenv("PO_SESSION", "")
PO_UID = os.getenv("PO_UID", "")

if not DEMO_ONLY:
    raise RuntimeError("Safety stop: DEMO_ONLY must remain true.")

if not PO_SESSION or not PO_UID:
    raise RuntimeError(
        "Missing PO_SESSION or PO_UID. Add the Pocket Option Demo session ID "
        "and UID as Railway variables. Never commit them to GitHub."
    )

async def main():
    client = PocketOptionClient()
    await client.connect(Regions.DEMO)

    await client.emit.auth({
        "session": PO_SESSION,
        "isDemo": 1,
        "uid": int(PO_UID),
        "platform": 2,
        "isFastHistory": True,
        "isOptimized": True,
    })

    print("API: CONNECTED TO DEMO")
    print("AUTH: SENT")
    balance = client.get_balance()
    print(f"DEMO BALANCE: {balance}")
    print("NO TRADE WAS PLACED.")

    await client.disconnect()

if __name__ == "__main__":
    asyncio.run(main())
