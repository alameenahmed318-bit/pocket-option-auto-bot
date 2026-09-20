# Deriv MT5 R75 EA

EA for a Deriv CFDs Standard MT5 account.

Settings:
- Volatility 75 Index
- 2 maximum positions
- default lot 0.01 (MT5 uses lots; $1 is not an MT5 "stake")
- profit target $0.02
- close after 2 seconds if target was not reached
- 30-second cooldown
- EMA 9/21 + RSI 14 entry filter
- no grid, martingale, or averaging

Important: set TradeSymbol to the exact Volatility 75 symbol name shown in your Deriv MT5 terminal. Test on Demo first. Never put an MT5 password in GitHub source.
