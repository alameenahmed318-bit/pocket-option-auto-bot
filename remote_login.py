#!/usr/bin/env python3
import base64
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

SESSION_FILE = os.getenv("POCKET_OPTION_SESSION_FILE", "/data/pocket_demo_ssid.txt")
PORT = int(os.getenv("PORT", "8080"))
VNC_PASSWORD = os.getenv("REMOTE_LOGIN_PASSWORD", "").strip()
STATUS_FILE = Path("/tmp/pocket_status.json")

def status(message, ready=False):
    STATUS_FILE.write_text(json.dumps({"message": message, "ready": ready}), encoding="utf-8")

def launch():
    status("Opening Pocket Option login browser...", False)
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False, args=["--window-size=390,844","--disable-dev-shm-usage"])
        context = browser.new_context(viewport={"width": 390, "height": 844}, screen={"width": 390, "height": 844}, is_mobile=True)
        page = context.new_page()
        page.goto("https://pocketoption.com/en/login/", wait_until="domcontentloaded", timeout=120000)
        status("Log in manually in the remote browser. Complete CAPTCHA yourself if it appears.", True)
        while True:
            cookies = context.cookies()
            po = next((c for c in cookies if c.get("name") == "po_session"), None)
            if po and po.get("value"):
                value = po["value"]
                Path(SESSION_FILE).parent.mkdir(parents=True, exist_ok=True)
                ssid = f'42["auth",{{"session":"{value}","isDemo":1,"uid":0,"platform":2}}]'
                Path(SESSION_FILE).write_text(ssid, encoding="utf-8")
                status("Demo session saved. You can close this page.", True)
                break
            time.sleep(2)
        while True:
            time.sleep(30)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok"); return
        if self.path == "/":
            auth = self.headers.get("Authorization", "")
            expected = "Basic " + base64.b64encode(("admin:" + VNC_PASSWORD).encode()).decode()
            if not VNC_PASSWORD or auth != expected:
                self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="Pocket Option Demo Login"'); self.end_headers(); return
            body = b"""<!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Demo Login</title></head>
<body style="font-family:sans-serif"><h2>Pocket Option Demo Login</h2>
<p>Use the remote browser below. Enter your credentials yourself and complete any CAPTCHA.</p>
<iframe src="/vnc/vnc.html?autoconnect=1&resize=scale" style="width:100%;height:80vh;border:1px solid #aaa"></iframe></body></html>"""
            self.send_response(200); self.send_header("Content-Type","text/html"); self.end_headers(); self.wfile.write(body); return
        self.send_response(404); self.end_headers()
    def log_message(self, *_): pass

status("Starting...", False)
threading.Thread(target=launch, daemon=True).start()
HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
