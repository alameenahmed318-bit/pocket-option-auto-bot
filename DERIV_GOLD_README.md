# Deriv Gold Demo Bot

Gold-only Deriv Options bot rebuilt from the earlier Deriv demo workflow.

- DEMO Options account only
- Gold/XAU symbol discovered automatically
- CALL/PUT contracts
- 60-second duration
- $1 demo stake
- EMA + RSI + short momentum entry
- Automatic reconnect
- $15 daily-loss stop per runner session
- GitHub Actions runner with crash recovery
- No live-account mode is implemented

Required GitHub secrets:
- DERIV_TOKEN
- DERIV_APP_ID
- DERIV_ACCOUNT_ID (optional; if set, it must be a DEMO Options account)
