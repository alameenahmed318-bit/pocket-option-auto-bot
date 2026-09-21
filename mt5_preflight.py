import os, sys
import MetaTrader5 as mt5

LOGIN = int(os.environ.get("MT5_REAL_LOGIN", "0"))
PASSWORD = os.environ.get("MT5_REAL_PASSWORD", "")
SERVER = os.environ.get("MT5_REAL_SERVER", "").strip()
FOREX = ["EURUSD","GBPUSD","USDJPY","AUDUSD","USDCAD","USDCHF","NZDUSD","EURGBP","EURJPY","GBPJPY"]

def fail(msg):
    print("FAIL:", msg)
    print("NO ORDER / NO BUY / NO SELL WAS PERFORMED.")
    sys.exit(1)

print("DERIV MT5 REAL CFD PREFLIGHT — FOREX ONLY — NO TRADING")
if not LOGIN or not PASSWORD or not SERVER:
    fail("Missing MT5_REAL_LOGIN, MT5_REAL_PASSWORD, or MT5_REAL_SERVER GitHub Secret.")

if not mt5.initialize():
    fail("MT5 terminal initialization failed: " + str(mt5.last_error()))

try:
    if not mt5.login(LOGIN, password=PASSWORD, server=SERVER):
        fail("MT5 login failed: " + str(mt5.last_error()))

    info = mt5.account_info()
    if info is None:
        fail("Could not read account information: " + str(mt5.last_error()))

    print("MT5_LOGIN_OK=true")
    print("ACCOUNT_LOGIN=", info.login)
    print("ACCOUNT_SERVER=", info.server)
    print("ACCOUNT_CURRENCY=", info.currency)
    print("ACCOUNT_BALANCE=", info.balance)
    print("ACCOUNT_EQUITY=", info.equity)
    print("ACCOUNT_TRADE_ALLOWED=", info.trade_allowed)

    symbols = mt5.symbols_get()
    if symbols is None:
        fail("Could not read symbols: " + str(mt5.last_error()))

    wanted = {x.upper() for x in FOREX}
    found = {}
    for s in symbols:
        key = s.name.upper().replace(".", "").replace("_", "")
        if key in wanted:
            found[key] = s.name

    print("FOREX_SYMBOLS_FOUND=", len(found))
    for key, name in sorted(found.items()):
        visible = mt5.symbol_select(name, True)
        tick = mt5.symbol_info_tick(name)
        print(f"FOREX {name}: visible={visible} tick={'OK' if tick else 'NO'}")

    if not found:
        fail("No requested Forex symbols were found.")

    print("PREFLIGHT=PASS")
    print("REAL MT5 CFD/Standard connection verified.")
    print("FOREX market access checked.")
    print("NO ORDER / NO BUY / NO SELL WAS PERFORMED.")
finally:
    mt5.shutdown()
