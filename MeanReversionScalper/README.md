# Mean Reversion Scalper EA

A professional MT4 Expert Advisor that scalps using mean-reversion strategy on M1/M5 timeframes with dual trading modes.

## Features

### Trading Modes

**Mode A - Basket Take-Profit:**
- Closes all EA trades when total floating profit reaches:
  - Configurable % of balance (default: 0.2%)
  - OR fixed currency amount
- Time-based basket exit (optional)
- Tracks basket performance

**Mode B - Per-Trade Micro TP:**
- Individual take-profit per trade (default: 3 pips)
- Break-even functionality (moves SL to entry after X pips profit)
- Trailing stop with configurable start and step
- Stop-loss protection

### Mean Reversion Entry Logic

- Calculates moving average over configurable period (default: 20)
- Uses standard deviation multiplier (default: 2.0)
- Enters when price deviates significantly from mean:
  - **BUY**: Price below mean - expects reversion up
  - **SELL**: Price above mean - expects reversion down
- Minimum deviation filter to avoid weak signals

### Risk Management

- **Equity Drawdown Guard**: Stops trading if drawdown exceeds threshold (default: 20%)
- **Spread Filter**: Only trades when spread is acceptable (default: 5 pips max)
- **Session Filter**: Optional trading hours restriction
- **News Filter**: Optional news avoidance (placeholder for calendar integration)

### Order Management

- **Retry Logic**: Automatic retries on failed orders (max 3 attempts)
- **Symbol-Safe**: Proper symbol handling for all order operations
- **Slippage Control**: Configurable maximum slippage
- **Magic Number**: Isolated trade identification

### Display

- **On-Chart Panel**: Real-time statistics display
- Shows:
  - Current mode
  - Open trades count
  - Total trades
  - Basket profit (Mode A) or Micro TP status (Mode B)
  - Account balance/equity
  - Drawdown percentage
  - Current spread

## Input Parameters

### Trading Mode
- `TradingMode`: Select MODE_BASKET or MODE_MICRO_TP

### Mean Reversion Entry
- `EntryTimeframe`: M1 or M5
- `MeanReversionPeriod`: Period for MA calculation (default: 20)
- `DeviationMultiplier`: StdDev multiplier (default: 2.0)
- `MinDeviationPips`: Minimum deviation to enter (default: 5.0)
- `MaxConcurrentTrades`: Maximum trades per symbol (default: 5)

### Position Sizing
- `LotSize`: Fixed lot size (default: 0.01)
- `RiskPercent`: Risk % per trade (if using risk-based)

### Basket Take-Profit (Mode A)
- `BasketProfitPercent`: Close at % of balance (default: 0.2%)
- `BasketProfitFixed`: OR fixed amount (0 = use %)
- `BasketTimeLimitMinutes`: Close after X minutes (default: 60)
- `UseBasketTimeLimit`: Enable time-based exit

### Per-Trade Micro TP (Mode B)
- `MicroTPPips`: Take-profit in pips (default: 3.0)
- `BreakEvenPips`: Move to BE after X pips (default: 2.0)
- `TrailingStartPips`: Start trailing after X pips (default: 1.5)
- `TrailingStepPips`: Trailing step (default: 0.5)
- `StopLossPips`: Stop loss (default: 10.0)

### Risk Management
- `MaxDrawdownPercent`: Maximum drawdown % (default: 20.0)
- `MaxSpreadPips`: Maximum spread filter (default: 5.0)
- `UseDrawdownGuard`: Enable drawdown protection

### Session Filters
- `UseSessionFilter`: Enable session filter
- `SessionStartHour`: Trading start hour (server time)
- `SessionEndHour`: Trading end hour (server time)

### News Filter
- `UseNewsFilter`: Enable news filter
- `NewsFilterMinutes`: Avoid trading X minutes before/after news

### Order Management
- `MagicNumber`: Magic number (default: 202503)
- `MaxRetries`: Maximum order retries (default: 3)
- `RetryDelayMS`: Delay between retries in ms (default: 100)
- `SlippagePips`: Maximum slippage (default: 3)

### Display
- `ShowPanel`: Show on-chart panel
- `PanelCorner`: Panel position corner
- `PanelX`: Panel X position
- `PanelY`: Panel Y position

## Usage

1. Attach EA to M1 or M5 chart
2. Configure trading mode (BASKET or MICRO_TP)
3. Set mean reversion parameters
4. Configure risk management settings
5. Enable/disable filters as needed
6. Monitor via on-chart panel

## Code Quality

- Clean MQL4 code with proper error handling
- Retry logic for order operations
- Symbol-safe order handling
- Proper array management
- Memory-efficient trade tracking

## Version

v1.00 - Initial release

