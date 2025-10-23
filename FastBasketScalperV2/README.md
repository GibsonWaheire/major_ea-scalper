# FastBasketScalperV2 EA

**Type:** Automated Trading Bot (Candle Position Strategy)
**Platform:** MetaTrader 4
**Version:** 2.00

## Strategy

This V2 uses **Candle Close Position** logic for entries:
- **BUY**: When candle closes in upper 70% (strong bullish)
- **SELL**: When candle closes in lower 30% (strong bearish)
- Requires candles with strong body (50%+ of total range)
- Portfolio-based exits (closes ALL trades at % profit target)

## Key Features

- Candle position-based entries (not random)
- Portfolio profit targets: 1%, 2%, 5%
- Dynamic lot sizing based on balance
- 25% drawdown protection
- Optimized for US30, US100, DSX indices

## Installation

1. Copy `.mq4` file to `MT4/MQL4/Experts/`
2. Restart MT4 or refresh Navigator
3. Drag EA onto chart (M1 recommended)
4. Configure parameters
5. Enable AutoTrading

## Adjustable Parameters

- **BuyCloseThreshold**: 70% (BUY if close above this)
- **SellCloseThreshold**: 30% (SELL if close below this)
- **MinCandleBodyPercent**: 50% (minimum body strength)
- **PortfolioProfitTarget**: 2% (main exit)
- **QuickExitPercent**: 1% (fast exit)

## Security

This code has been obfuscated. Compile to .ex4 for additional protection.

## Support

For questions or issues, contact the developer.


