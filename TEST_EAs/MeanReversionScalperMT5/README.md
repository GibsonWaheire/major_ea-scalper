# Mean Reversion Scalper EA - MT5 Version

**Status**: 🚧 Conversion in Progress

This directory contains the MT5 conversion of the Mean Reversion Scalper EA v2.00.

## Overview

A professional MT5 Expert Advisor that scalps using mean-reversion strategy on M1/M5 timeframes with dual trading modes and advanced position sizing.

## Features

### Trading Modes

**Mode A - Basket Take-Profit:**
- Opens multiple trades simultaneously
- Closes all EA trades when total floating profit reaches:
  - Configurable % of balance (default: 0.2%)
  - OR fixed currency amount
- Optional time-based basket exit
- Tracks basket performance for martingale logic

**Mode B - Per-Trade Micro TP:**
- Individual take-profit per trade (default: 3 pips)
- Break-even functionality (moves SL to entry after X pips profit)
- Trailing stop with configurable start and step
- Stop-loss protection (default: 10 pips)

### Mean Reversion Entry Logic

- Calculates Simple Moving Average (SMA) over configurable period (default: 20)
- Uses standard deviation multiplier (default: 2.0x)
- Enters when price deviates significantly from mean:
  - **BUY**: Price below mean - expects reversion up
  - **SELL**: Price above mean - expects reversion down
- Minimum deviation filter to avoid weak signals (default: 5 pips)

### Advanced Position Sizing (5 Modes)

1. **Fixed**: Always use fixed lot size
2. **Risk-Based**: Calculate lot size based on account balance × risk %
3. **Martingale**: Multiply lot after losing basket (default: 1.5x)
4. **Grid Step**: Increase lot per additional same-direction trade
5. **Equity Scale**: Scale with account equity

### Risk Management

- **Equity Drawdown Guard**: Stops trading if drawdown exceeds threshold (default: 20%)
- **Spread Filter**: Only trades when spread is acceptable (default: 5 pips max)
- **Session Filter**: Optional trading hours restriction
- **News Filter**: Optional news avoidance (placeholder for calendar integration)
- **Max Concurrent Trades**: Limits open positions per symbol (default: 5)

### Signal Enhancement

- **Fast Testing Mode**: Relaxed signal checks for demo/testing
- **Quick Entry Booster**: Secondary, faster signal sweep with lower thresholds

### Order Management

- **Retry Logic**: Automatic retries on failed orders (max 3 attempts)
- **Slippage Control**: Configurable maximum slippage
- **Magic Number**: Isolated trade identification
- **Symbol-Safe**: Proper symbol handling for all operations

### Display

- **On-Chart Panel**: Real-time statistics display
  - Current mode
  - Open trades count
  - Total trades
  - Basket P/L (Mode A) or Micro TP status (Mode B)
  - Account balance/equity
  - Drawdown percentage
  - Current spread

## MT5 Conversion Status

✅ **Conversion Complete!**

This EA has been fully converted from MT4 to MT5. All conversion areas completed:

- ✅ Directory structure created
- ✅ Order functions conversion (OrderSend → CTrade.Buy/Sell)
- ✅ Trade information access (OrderProfit → PositionGetDouble)
- ✅ Market information (MarketInfo → SymbolInfo)
- ✅ Indicator functions (iMA → CopyBuffer with handle)
- ✅ Account functions (AccountBalance → AccountInfoDouble)
- ✅ Position enumeration and management (PositionSelectByTicket)
- ✅ Event handlers (OnTradeTransaction)
- ✅ CTrade class integration
- ✅ Proper position ticket retrieval

## Original MT4 Version

See `../MeanReversionScalper/` for the original MT4 version.

## Documentation

- `EA_SUMMARY.md`: Detailed technical summary and conversion notes
- `README.md`: This file

## Usage (Once Converted)

1. Copy `MeanReversionScalper_v2.mq5` to `MQL5/Experts/`
2. Compile in MetaEditor
3. Attach EA to M1 or M5 chart
4. Configure trading mode (BASKET or MICRO_TP)
5. Set mean reversion parameters
6. Configure risk management settings
7. Enable/disable filters as needed
8. Monitor via on-chart panel

## Input Parameters

See `EA_SUMMARY.md` for complete parameter list.

## Notes

- This EA requires proper symbol configuration
- Test thoroughly in demo before live trading
- Monitor spread conditions, especially for scalping
- Consider broker-specific requirements (ECN/STP)


