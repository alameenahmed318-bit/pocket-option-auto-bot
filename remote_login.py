#!/usr/bin/env python3
import base64,json,os,threading,time
from collections import deque
from http.server import BaseHTTPRequestHandler,HTTPServer
from pathlib import Path

PORT=int(os.getenv("BOT_HTTP_PORT","8081"))
PASSWORD=os.getenv("REMOTE_LOGIN_PASSWORD","").strip()
DEMO_ONLY=os.getenv("DEMO_ONLY","true").lower()=="true"
STAKE=float(os.getenv("STAKE","1"))
DURATION=int(os.getenv("TRADE_DURATION","60"))
MAX_TRADES=int(os.getenv("MAX_TRADES_PER_RUN","3"))
COOLDOWN=int(os.getenv("COOLDOWN_SECONDS","90"))
STATUS=Path("/tmp/pocket_status.json")

if not DEMO_ONLY: raise RuntimeError("Safety stop: DEMO_ONLY must remain true.")

def status(message):
    STATUS.write_text(json.dumps({"message":message,"ready":True}),encoding="utf-8")

def ema(v,n):
    if len(v)<n:return None
    k=2/(n+1); x=sum(v[:n])/n
    for p in v[n:]: x=p*k+x*(1-k)
    return x

def rsi(v,n=14):
    if len(v)<n+1:return None
    g=[];l=[]
    for a,b in zip(v[-n-1:-1],v[-n:]):
        d=b-a;g.append(max(d,0));l.append(max(-d,0))
    ag=sum(g)/n;al=sum(l)/n
    return 100 if al==0 else 100-(100/(1+ag/al))

def auth_frame(s):
    s=s.lower()
    return any(x in s for x in ("session","ssid","password","authorization",'"auth"'))

def closes(obj):
    out=[]
    if isinstance(obj,dict):
        for k in ("close","close_price","c"):
            if isinstance(obj.get(k),(int,float)): out.append(float(obj[k]));break
        for v in obj.values(): out.extend(closes(v))
    elif isinstance(obj,list):
        for v in obj: out.extend(closes(v))
    return out

def launch():
    status("Open Pocket Option, log in yourself, complete CAPTCHA yourself, and select Demo.")
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        browser=p.chromium.launch(headless=False,args=[
            "--window-size=392,844","--disable-dev-shm-usage","--disable-gpu",
            "--disable-software-rasterizer","--no-sandbox","--no-first-run"])
        ctx=browser.new_context(viewport={"width":392,"height":844},
                                screen={"width":392,"height":844},is_mobile=True)
        page=ctx.new_page()
        prices=deque(maxlen=120)

        def websocket(ws):
            def frame(data):
                if not isinstance(data,str) or not data.strip() or auth_frame(data): return
                raw=data[1:] if data[:1].isdigit() else data
                try: obj=json.loads(raw)
                except Exception:return
                for x in closes(obj):
                    if not prices or x!=prices[-1]: prices.append(x)
            ws.on("framereceived",frame)

        page.on("websocket",websocket)
        page.goto("https://pocketoption.com/en/login/",wait_until="domcontentloaded",timeout=120000)
        try: page.evaluate("document.documentElement.style.zoom='0.82';document.body.style.zoom='0.82';")
        except Exception: pass
        status("Waiting for your manual login. Keep the Demo trading terminal open after login.")

        while "/login" in page.url.lower():
            time.sleep(2)

        status("Logged in. Browser-only Demo bot is collecting market data.")
        page.wait_for_timeout(8000)
        trades=0
        last_trade=0

        while trades<MAX_TRADES:
            f=ema(list(prices),9);s=ema(list(prices),21);r=rsi(list(prices),14)
            if f is None or s is None or r is None:
                status("Waiting for market candles: %d/30. Keep the Demo terminal open."%len(prices))
                time.sleep(3);continue
            action="CALL" if f>s and 50<=r<=70 else "PUT" if f<s and 30<=r<=50 else None
            print("SIGNAL EMA9=%.6f EMA21=%.6f RSI14=%.2f action=%s"%(f,s,r,action))
            if action and time.time()-last_trade>=COOLDOWN:
                sel=".btn-call" if action=="CALL" else ".btn-put"
                btn=page.locator(sel).first
                if btn.count()==0:
                    status("Signal found but %s is not visible. Keep the Demo terminal open."%sel)
                    time.sleep(3);continue
                try:
                    btn.click(timeout=5000)
                    trades+=1;last_trade=time.time()
                    print("DEMO TRADE CLICKED: %s trade=%d/%d stake=$%.2f expiry=%ds"%(action,trades,MAX_TRADES,STAKE,DURATION))
                    status("Demo %s clicked. Trade %d/%d. No SSID is exported."%(action,trades,MAX_TRADES))
                    time.sleep(DURATION+2)
                except Exception as e:
                    print("UI TRADE ERROR:",e);time.sleep(3)
            else: time.sleep(3)

        status("Demo bot stopped after %d/%d trades."%(trades,MAX_TRADES))
        while True: time.sleep(30)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path=="/health":
            self.send_response(200);self.end_headers();self.wfile.write(b"ok");return
        self.send_response(404);self.end_headers()
    def log_message(self,*args):pass

threading.Thread(target=launch,daemon=True).start()
HTTPServer(("127.0.0.1",PORT),Handler).serve_forever()
