import os
from playwright.sync_api import sync_playwright

DEMO_ONLY = os.getenv("DEMO_ONLY", "true").lower() == "true"
PO_EMAIL = os.getenv("POCKET_OPTION_EMAIL", "")
PO_PASSWORD = os.getenv("POCKET_OPTION_PASSWORD", "")

if not DEMO_ONLY:
    raise RuntimeError("Safety stop: DEMO_ONLY must remain true.")
if not PO_EMAIL or not PO_PASSWORD:
    raise RuntimeError("Missing Pocket Option credentials in environment variables.")

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    page.goto("https://pocketoption.com/", wait_until="domcontentloaded", timeout=60000)

    print("BROWSER: OK")
    print(f"PAGE TITLE: {page.title()}")

    email = page.locator('input[type="email"], input[name*="email" i]').first
    password = page.locator('input[type="password"]').first

    if await email.count() == 0 or await password.count() == 0:
        print("LOGIN FORM: NOT FOUND")
        print("DEMO ONLY: TRUE")
        print("NO TRADE WAS PLACED.")
        browser.close()
        raise SystemExit(2)

    email.fill(PO_EMAIL)
    password.fill(PO_PASSWORD)

    print("LOGIN FORM: FOUND")
    print("CREDENTIALS: LOADED FROM ENVIRONMENT")
    print("DEMO ONLY: TRUE")
    print("NO TRADE WAS PLACED.")

    # Do not submit the form. This test only verifies that Railway can
    # load the page and inject configured credentials without trading.

    browser.close()
