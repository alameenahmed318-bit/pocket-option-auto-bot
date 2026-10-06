#!/usr/bin/env python3
import os,time,math
from datetime import datetime,timezone
import MetaTrader5 as mt5
import pandas as pd
LOGIN=int(os.getenv("MT5_LOGIN","32432112")); SERVER=os.getenv("MT5_SERVER","Deriv-Demo"); PASSWORD=os.getenv("MT5_PASSWORD",""); MT5_PATH=os.getenv("MT5_PATH","")
LOT=float(os.getenv("LOT","0.01")); SCAN=float(os.getenv("SCAN_SECONDS","2")); TARGET=float(os.getenv("PROFIT_TARGET","0.10")); MAXLOSS=float(os.getenv("MAX_LOSS","10"))
TRAIL=float(os.getenv("TRAIL_START","0.10")); GIVEBACK=float(os.getenv("TRAIL_GIVEBACK","0.05")); COOLDOWN=float(os.getenv("COOLDOWN_SECONDS","3")); MAXPOS=int(os.getenv("MAX_POSITIONS","1")); DRY=os.getenv("DRY_RUN","false").lower()=="true"; MAGIC=int(os.getenv("MT5_MAGIC","32432112"))
LOG="deriv_mt5_gold.log"
def log(x):
 s=f"[{datetime.now(timezone.utc).isoformat()}] {x}"; print(s,flush=True)
 with open(LOG,"a",encoding="utf-8") as f:f.write(s+"\n")
def stop(x): log("ERROR | "+x); raise SystemExit(1)
if not PASSWORD: stop("MT5_PASSWORD secret is missing.")
if not MT5_PATH: stop("MT5_PATH environment variable is missing.")
if not os.path.exists(MT5_PATH): stop(f"MT5 terminal not found: {MT5_PATH}")
mt5_ok=False
for attempt in range(1,9):
    try: mt5.shutdown()
    except Exception: pass
    log(f"MT5 initialize attempt {attempt}/8 | portable=True")
    if mt5.initialize(path=MT5_PATH,login=LOGIN,password=PASSWORD,server=SERVER,timeout=180000,portable=True):
        mt5_ok=True
        break
    err=mt5.last_error()
    log(f"MT5 initialize failed {attempt}/8 | err={err}")
    try: mt5.shutdown()
    except Exception: pass
    time.sleep(10)
if not mt5_ok: stop(f"MT5 initialize failed after 8 attempts: {mt5.last_error()}")
a=mt5.account_info()
if a is None: stop(f"account_info failed: {mt5.last_error()}")
log(f"CONNECTED | login={a.login} | server={a.server} | balance={a.balance:.2f} | equity={a.equity:.2f} | currency={a.currency}")
if int(a.login)!=LOGIN: stop(f"Wrong login returned: {a.login}")
ss=mt5.symbols_get() or []
cand=[s.name for s in ss if "XAU" in s.name.upper() or "GOLD" in s.name.upper()]
if not cand: stop("No XAU/GOLD symbol found on Deriv-Demo.")
symbol=sorted(set(cand),key=lambda x:(0 if x.upper()=="XAUUSD" else 1,len(x)))[0]
if not mt5.symbol_select(symbol,True): stop(f"Cannot select {symbol}: {mt5.last_error()}")
si=mt5.symbol_info(symbol); step=float(si.volume_step or .01); lot=max(float(si.volume_min or step),min(float(si.volume_max or LOT),LOT)); lot=round(math.floor(lot/step+1e-9)*step,8)
log(f"GOLD SYMBOL | {symbol} | lot={lot} | digits={si.digits} | min={si.volume_min} | step={si.volume_step}")
def data():
 r=mt5.copy_rates_from_pos(symbol,mt5.TIMEFRAME_M1,0,150)
 if r is None or len(r)<60:return None
 d=pd.DataFrame(r); d["e9"]=d.close.ewm(span=9,adjust=False).mean(); d["e21"]=d.close.ewm(span=21,adjust=False).mean()
 ch=d.close.diff(); g=ch.clip(lower=0).ewm(alpha=1/14,adjust=False).mean(); l=(-ch.clip(upper=0)).ewm(alpha=1/14,adjust=False).mean(); d["rsi"]=100-(100/(1+g/l.replace(0,float("nan")))); return d
def sig(d):
 a,b=d.iloc[-2],d.iloc[-3]
 if any(pd.isna(a[x]) for x in ("e9","e21","rsi")):return None
 if b.e9<=b.e21<a.e9 and a.close>a.open and 52<=a.rsi<=75:return "BUY"
 if b.e9>=b.e21>a.e9 and a.close<a.open and 25<=a.rsi<=48:return "SELL"
 return None
def positions():return list(mt5.positions_get(symbol=symbol) or [])
def close(p):
 t=mt5.symbol_info_tick(symbol)
 if t is None:return False
 typ=mt5.ORDER_TYPE_SELL if p.type==mt5.POSITION_TYPE_BUY else mt5.ORDER_TYPE_BUY; price=t.bid if p.type==mt5.POSITION_TYPE_BUY else t.ask
 if DRY:log(f"DRY_RUN CLOSE | ticket={p.ticket} | profit={p.profit:.2f}");return True
 r=mt5.order_send({"action":mt5.TRADE_ACTION_DEAL,"symbol":symbol,"volume":p.volume,"type":typ,"position":p.ticket,"price":price,"deviation":30,"magic":MAGIC,"comment":"GOLD_PROTECT","type_time":mt5.ORDER_TIME_GTC,"type_filling":mt5.ORDER_FILLING_IOC})
 ok=r and r.retcode==mt5.TRADE_RETCODE_DONE; log(f"CLOSED | ticket={p.ticket} | profit={p.profit:.2f}" if ok else f"CLOSE_FAILED | ticket={p.ticket} | retcode={None if r is None else r.retcode} | comment={None if r is None else r.comment} | err={mt5.last_error()}"); return bool(ok)
def open_trade(side):
 t=mt5.symbol_info_tick(symbol)
 if t is None:return False
 typ=mt5.ORDER_TYPE_BUY if side=="BUY" else mt5.ORDER_TYPE_SELL; price=t.ask if side=="BUY" else t.bid
 if DRY:log(f"DRY_RUN OPEN | {side} | {symbol} | lot={lot} | price={price}");return True
 r=mt5.order_send({"action":mt5.TRADE_ACTION_DEAL,"symbol":symbol,"volume":lot,"type":typ,"price":price,"deviation":30,"magic":MAGIC,"comment":"DERIV_GOLD_FAST","type_time":mt5.ORDER_TIME_GTC,"type_filling":mt5.ORDER_FILLING_IOC})
 ok=r and r.retcode==mt5.TRADE_RETCODE_DONE; log(f"OPENED | {side} | {symbol} | lot={lot}" if ok else f"ORDER_REJECTED | side={side} | retcode={None if r is None else r.retcode} | comment={None if r is None else r.comment} | err={mt5.last_error()}"); return bool(ok)
peak={};lastbar=None;lasttrade=0
log(f"GOLD BOT READY | M1 | scan={SCAN}s | lot={lot} | target={TARGET} | max_loss={MAXLOSS} | trail={TRAIL} | giveback={GIVEBACK} | dry_run={DRY}")
while True:
 d=data()
 if d is None:time.sleep(SCAN);continue
 for p in positions():
  peak[p.ticket]=max(peak.get(p.ticket,p.profit),p.profit)
  if p.profit>=TARGET or p.profit<=-MAXLOSS or (peak[p.ticket]>=TRAIL and p.profit<=peak[p.ticket]-GIVEBACK):close(p);peak.pop(p.ticket,None)
 if len(positions())<MAXPOS and time.time()-lasttrade>=COOLDOWN:
  bt=int(d.iloc[-2].time)
  if bt!=lastbar:
   lastbar=bt;side=sig(d)
   if side and open_trade(side):lasttrade=time.time()
 time.sleep(SCAN)
