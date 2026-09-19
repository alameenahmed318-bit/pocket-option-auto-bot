import os
from playwright.sync_api import sync_playwright

DEMO_ONLY = os.getenv("DEMO_ONLY", "true").lower() == "true"

if not DEMO_ONLY:
    raise RuntimeError("Safety stop: DEMO_ONLY must remain true.")

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    page.goto("https://pocketoption.com/", wait_until="domcontentloaded", timeout=60000)
    print("BROWSER: OK")
    print(f"PAGE TITLE: {page.title()}")
    print("DEMO ONLY: TRUE")
    print("NO TRADE WAS PLACED.")
    browser.close()
