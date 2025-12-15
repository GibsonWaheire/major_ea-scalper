# NAS100 Hybrid Sniper Flipper - Moderate Risk Version

## Overview

This Expert Advisor (EA) is designed specifically for trading NAS100 (USTEC/US100) during the New York session, using a hybrid sniper entry strategy that combines institutional zone analysis with momentum confirmation.

## Key Features

### 1. Symbol Restriction
- **Trades ONLY**: NAS100 (USTEC or US100 depending on broker)
- Automatically detects and uses the correct symbol

### 2. Trading Time Window
- **Active Hours**: 15:30 - 18:00 Kenya Time (UTC+3)
- **End of Session**: At 18:00, all open trades are closed immediately
- **No Trading**: Outside the specified window

### 3. Trend Filter (Mandatory)
The EA will ONLY trade when ALL trend filters agree:

**For BUY:**
- EMA20 > EMA50
- M5 BOS (Break of Structure) is bullish
- Momentum direction is up

**For SELL:**
- EMA20 < EMA50
- M5 BOS is bearish
- Momentum direction is down

**If filters disagree → NO TRADES**

### 4. Hybrid Sniper Entry Logic

A trade is opened ONLY when BOTH conditions are met:

#### A. Pullback into Institutional Zone (any of):
- M5 Order Block
- M1/M5 FVG (Fair Value Gap)
- 50% retrace of last impulse
- Previous structure retest
- Imbalance fill

#### B. Momentum Confirmation (any of):
- Strong engulfing candle
- Minor structure break in trend direction
- Tick momentum spike
- RSI > 50 (for BUY) or RSI < 50 (for SELL)

### 5. Position Sizing

- **First Entry**: 0.50 lots (fixed)
- **Recovery Entry**: 0.65 lots (ONLY one allowed per sniper setup)
- **Recovery Entry Conditions**:
  - Deeper pullback into next institutional zone
  - Trend filter still valid
- **Rule**: Never more than one active sniper setup at a time

### 6. Stop Loss (Virtual Only)

- **Range**: 150-250 NAS100 points (configurable via input)
- **Type**: Virtual stop loss (NOT sent to broker)
- **Action**: If virtual SL is hit:
  - Close ALL open trades immediately
  - Stop trading for the day

### 7. Take Profit System

#### A. Per-Trade TP (Dynamic 5%)
- **Target**: 5% of Account Equity at entry time
- **Action**: When floating profit ≥ Target:
  - Close ALL open trades immediately
  - Reset and immediately scan for next sniper entry (if still within NY session)

#### B. Daily Profit Cap (30%-50%)
- **User Input**: 0.30, 0.40, or 0.50 (30%, 40%, or 50%)
- **Calculation**: StartOfDayEquity × (1 + DailyProfitPercent)
- **Action**: When equity reaches DailyTarget:
  - Stop trading for the day
  - Do NOT open more trades

### 8. Daily Loss Protection

- **Threshold**: -15% from start of day equity
- **Calculation**: StartOfDayEquity × 0.85
- **Action**: If equity falls below threshold:
  - Close all trades
  - Stop trading for the day

### 9. Daily Reset

At the beginning of each new trading day:
- Reset StartOfDayEquity
- Reset daily counters
- EA ready for next NY session

### 10. News Handling

- **Completely ignores all news**
- Does NOT block trades around CPI, FOMC, NFP, etc.
- Trades based purely on technical analysis

### 11. Multi-Trade Behavior

- EA may take multiple trades per day
- **Rule**: NEVER more than one active sniper setup at a time
- After each 5% TP cycle → immediately begin scanning for new sniper entry

### 12. End-of-Session Behavior

At 18:00 Kenya Time:
- Close all open trades
- Stop trading for the day

### 13. Notifications

- Push notifications enabled by default
- Notifies on:
  - Sniper entry opened
  - Recovery entry opened
  - Virtual SL hit
  - Daily profit cap reached
  - Daily loss limit reached
  - End of session

## Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| SymbolName | "USTEC" | Trading symbol (USTEC/US100) |
| MagicNumber | 20241201 | Unique magic number for trade identification |
| FirstEntryLots | 0.50 | Lot size for first entry |
| RecoveryEntryLots | 0.65 | Lot size for recovery entry (only one) |
| VirtualSLPoints | 200 | Virtual stop loss in NAS100 points (150-250) |
| DailyProfitPercent | 0.40 | Daily profit cap (0.30, 0.40, or 0.50) |
| EnableNotifications | true | Enable push notifications |
| RSI_Period | 14 | RSI indicator period |
| EMA_Fast_Period | 20 | Fast EMA period |
| EMA_Slow_Period | 50 | Slow EMA period |

## Installation

1. Copy `NAS100HybridSniperFlipper.mq5` to your MetaTrader 5 `Experts` folder
2. Restart MetaTrader 5 or refresh the Navigator window
3. Drag the EA onto a NAS100 chart
4. Configure input parameters as needed
5. Enable AutoTrading

## Important Notes

1. **Symbol**: Ensure your broker uses USTEC or US100 for NAS100. Adjust the `SymbolName` input if needed.

2. **Time Zone**: The EA uses UTC time and converts to Kenya Time (UTC+3). Ensure your broker server time is set correctly.

3. **Virtual Stop Loss**: The stop loss is managed internally and NOT sent to the broker. This allows for more flexible risk management.

4. **One Setup at a Time**: The EA ensures only one active sniper setup exists at any time. After closing a setup (via TP or SL), it immediately scans for the next opportunity.

5. **Daily Limits**: The EA has built-in daily profit caps and loss protection. Once triggered, trading stops for the day.

6. **Recovery Entry**: Only ONE recovery entry is allowed per sniper setup. It requires a deeper pullback and valid trend filter.

## Risk Warning

- Trading involves substantial risk of loss
- Past performance does not guarantee future results
- Always test on a demo account before live trading
- Use proper risk management
- Never risk more than you can afford to lose

## Version

**Version 1.00** - Initial release

## Support

For issues or questions, please refer to the code comments or contact support.

---

**Disclaimer**: This EA is provided as-is. Use at your own risk. Always test thoroughly before live trading.























