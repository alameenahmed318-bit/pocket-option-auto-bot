# Pocket Option Auto Bot

Demo-first automation scaffold for Pocket Option.

## Safety defaults
- DEMO_ONLY=true
- Fixed stake; no Martingale
- Maximum trades per run/day
- Daily loss limit
- Live trading is blocked by default
- Credentials are read from environment variables / GitHub Actions Secrets and are never committed

## Important
This project is intended for demo/testing. Pocket Option automation libraries commonly use unofficial interfaces that can change without notice. Do not commit passwords, SSIDs, cookies, tokens, or session data.

## GitHub Actions
This is a scheduled scaffold, not a low-latency 24/7 execution environment.
