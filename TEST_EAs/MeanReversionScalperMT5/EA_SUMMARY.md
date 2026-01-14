# Mean Reversion Scalper EA - Summary & MT5 Conversion Plan

## EA Overview

The **Mean Reversion Scalper EA v2.00** is a sophisticated MT4 Expert Advisor that implements a mean-reversion trading strategy with dual trading modes and advanced position sizing capabilities.

## Core Strategy: Mean Reversion

The EA identifies when price deviates significantly from its moving average and enters trades expecting price to revert back to the mean.

### Entry Logic
- **Indicator**: Simple Moving Average (SMA) over configurable period (default: 20)
- **Deviation Measure**: Standard deviation multiplier (default: 2.0x)
- **Entry Signals**:
  - **BUY**: When price falls below `MA - (StdDev × Multiplier)` → expects upward reversion
  - **SELL**: When price rises above `MA + (StdDev × Multiplier)` → expects downward reversion
- **Timeframe**: M1 or M5 (configurable)
- **Minimum Deviation Filter**: Avoids weak signals (default: 5 pips minimum)

### Signal Enhancement Features
1. **Fast Testing Mode**: Relaxed signal checks for demo/testing
   - Reduced deviation thresholds
   - Can evaluate forming candle (not just closed)
   
2. **Quick Entry Booster**: Secondary, faster signal sweep
   - Lower deviation multiplier (60% of active multiplier)
   - Separate minimum deviation floor
   - Can use live candle evaluation

## Trading Modes

### Mode A: Basket Take-Profit (MODE_BASKET)
- Opens multiple trades simultaneously
- Closes **all trades** when total floating profit reaches:
  - Configurable % of balance (default: 0.2%)
  - OR fixed currency amount
- Optional time-based exit (close basket after X minutes)
- Tracks basket performance for martingale logic

### Mode B: Per-Trade Micro TP (MODE_MICRO_TP)
- Each trade has individual management:
  - **Micro Take-Profit**: Small TP (default: 3 pips)
  - **Break-Even**: Moves SL to entry after X pips profit (default: 2 pips)
  - **Trailing Stop**: Starts after X pips (default: 1.5), steps by X pips (default: 0.5)
  - **Stop Loss**: Protection (default: 10 pips)

## Position Sizing (5 Modes)

1. **LOT_FIXED (0)**: Always use fixed lot size
2. **LOT_RISK_PERCENT (1)**: Risk-based sizing (requires SL)
   - Calculates lot size based on account balance × risk %
3. **LOT_MARTINGALE (2)**: Multiply lot after losing basket
   - Resets to base lot after win
   - Multiplies by factor (default: 1.5x) after loss
4. **LOT_GRID_STEP (3)**: Increase lot per additional same-direction trade
   - Base lot + (number of same-direction trades × step)
5. **LOT_EQUITY_SCALE (4)**: Scale with account equity
   - Formula: (Equity / EquityPerLot) × BaseLot

## Risk Management

1. **Drawdown Protection**: Stops trading if equity drawdown exceeds threshold (default: 20%)
2. **Spread Filter**: Only trades when spread ≤ max (default: 5 pips)
3. **Session Filter**: Optional trading hours restriction
4. **News Filter**: Placeholder for calendar integration
5. **Max Concurrent Trades**: Limits open positions per symbol (default: 5)

## Order Management

- **Retry Logic**: Automatic retries on failed orders (max 3 attempts, 100ms delay)
- **Slippage Control**: Configurable maximum slippage (default: 3 pips)
- **Magic Number**: Isolated trade identification (default: 202503)
- **Symbol-Safe**: Proper symbol handling for all operations

## Display Features

- **On-Chart Panel**: Real-time statistics display
  - Current trading mode
  - Open trades count
  - Total trades executed
  - Basket P/L (Mode A) or Micro TP status (Mode B)
  - Account balance/equity
  - Drawdown percentage
  - Current spread

## Key Technical Details

### Trade Tracking
- Maintains array of up to 100 open trades
- Tracks: ticket, entry price, lot size, open time, order type, highest profit, break-even status

### Basket Management (Mode A)
- Tracks basket start time
- Monitors highest basket profit
- Calculates total floating profit
- Records basket result for martingale logic

### Micro TP Management (Mode B)
- Per-trade profit tracking
- Break-even flag management
- Trailing stop updates
- Individual TP/SL management

## MT5 Conversion Considerations

### Key Differences to Address:

1. **Order Functions**:
   - MT4: `OrderSend()`, `OrderClose()`, `OrderModify()`, `OrderSelect()`
   - MT5: `PositionOpen()`, `PositionClose()`, `PositionModify()`, `PositionSelect()`, `OrderSend()`

2. **Trade Information**:
   - MT4: `OrderProfit()`, `OrderSwap()`, `OrderCommission()`
   - MT5: `PositionGetDouble(POSITION_PROFIT)`, `PositionGetDouble(POSITION_SWAP)`, `PositionGetDouble(POSITION_COMMISSION)`

3. **Market Information**:
   - MT4: `MarketInfo()`, `Bid`, `Ask`
   - MT5: `SymbolInfoDouble()`, `SymbolInfoInteger()`, `SymbolInfoTick()`

4. **Indicator Functions**:
   - MT4: `iMA()`, `iClose()`
   - MT5: `iMA()` (handle creation), `CopyClose()`, `CopyBuffer()`

5. **Account Functions**:
   - MT4: `AccountBalance()`, `AccountEquity()`
   - MT5: `AccountInfoDouble(ACCOUNT_BALANCE)`, `AccountInfoDouble(ACCOUNT_EQUITY)`

6. **Pip Calculation**:
   - MT4: Manual calculation with `MODE_POINT`, `MODE_DIGITS`
   - MT5: Use `SymbolInfoDouble(SYMBOL_POINT)` and `SymbolInfoInteger(SYMBOL_DIGITS)`

7. **Order Types**:
   - MT4: `OP_BUY`, `OP_SELL`
   - MT5: `ORDER_TYPE_BUY`, `ORDER_TYPE_SELL` (for orders), `POSITION_TYPE_BUY`, `POSITION_TYPE_SELL` (for positions)

8. **Time Functions**:
   - MT4: `TimeCurrent()`, `Hour()`
   - MT5: `TimeCurrent()`, `TimeToStruct()`, `TimeHour()`

9. **Object Management**:
   - MT4: `ObjectsDeleteAll()`, `Comment()`
   - MT5: `ObjectsDeleteAll()`, `Comment()` (similar)

10. **Error Handling**:
    - MT4: `GetLastError()`
    - MT5: `GetLastError()`, `ResetLastError()`

### Additional MT5 Features to Consider:

- Use `MqlTradeRequest` and `MqlTradeResult` structures for order operations
- Implement proper position enumeration using `PositionGetTicket()`
- Use `CopyBuffer()` for indicator data instead of direct indicator calls
- Consider using `OnTradeTransaction()` event handler for trade updates
- Implement proper symbol selection with `SymbolSelect()`

## File Structure

```
MeanReversionScalperMT5/
├── MeanReversionScalper_v2.mq5 (converted EA)
├── EA_SUMMARY.md (this file)
└── README.md (user documentation)
```

## Version History

- **v2.00**: Current MT4 version with dynamic lot sizing
- **v1.10**: Previous version (referenced in code comments)


