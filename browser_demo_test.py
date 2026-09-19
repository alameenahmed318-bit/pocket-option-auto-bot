import os
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeoutError

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

    # Pocket Option can keep network requests open for a long time. Do not
    # make the test depend on the full page reaching DOMContentLoaded.
    try:
        page.goto("https://pocketoption.com/", wait_until="commit", timeout=30000)
    except PlaywrightTimeoutError:
        print("PAGE NAVIGATION: TIMEOUT AFTER COMMIT WAIT")
        print("CONTINUING WITH PARTIALLY LOADED PAGE")

    try:
        page.wait_for_timeout(5000)
        print("BROWSER: OK")
        print(f"PAGE URL: {page.url}")
        print(f"PAGE TITLE: {page.title()}")

        email = page.locator('input[type="email"], input[name*="email" i]').first
        password = page.locator('input[type="password"]').first

        if email.count() == 0 or password.count() == 0:
            print("LOGIN FORM: NOT FOUND")
            print("DEMO ONLY: TRUE")
            print("NO TRADE WAS PLACED.")
            raise SystemExit(2)

        email.fill(PO_EMAIL)
        password.fill(PO_PASSWORD)

        print("LOGIN FORM: FOUND")
        print("CREDENTIALS: LOADED FROM ENVIRONMENT")
        print("ATTEMPTING LOGIN: TRUE")

        # Submit login only. No trading controls are clicked or invoked.
        submit = page.locator('button[type="submit"], input[type="submit"]').first
        if submit.count() == 0:
            print("LOGIN BUTTON: NOT FOUND")
            print("NO TRADE WAS PLACED.")
            raise SystemExit(3)

        submit.click()

        page.wait_for_timeout(5000)
        print(f"POST-LOGIN URL: {page.url}")
        print(f"POST-LOGIN TITLE: {page.title()}")

        # We only report whether the page moved away from the public login
        # screen. CAPTCHA/2FA or a failed login is not bypassed.
        current_url = page.url.lower()
        login_markers = ("login", "sign-in", "signin")
        if not any(marker in current_url for marker in login_markers):
            print("LOGIN RESULT: PAGE LEFT LOGIN SCREEN")
        else:
            print("LOGIN RESULT: STILL ON LOGIN SCREEN")

        print("DEMO ONLY: TRUE")
        print("NO TRADE WAS PLACED.")
    finally:
        browser.close()
