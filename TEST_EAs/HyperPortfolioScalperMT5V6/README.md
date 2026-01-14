# Hyper Portfolio Scalper MT5 V6

Multi-symbol portfolio scalping Expert Advisor for MetaTrader 5 that trades 11 symbols simultaneously with independent entry logic per symbol.

## Overview

This EA implements a sophisticated multi-symbol scalping strategy that:
- Trades 11 symbols independently (EURUSD, GBPUSD, USDJPY, USDCAD, AUDUSD, NZDUSD, USDCHF, XAUUSD, NAS100, US30, GER40)
- Uses tick-based entry signals with multiple filters
- Manages positions independently per symbol with advanced exit logic
- Supports both fixed and risk-based lot sizing
- Automatically normalizes point sizes based on symbol type

## Trading Symbols

The EA trades the following symbols simultaneously:
- **Forex**: EURUSD, GBPUSD, USDJPY, USDCAD, AUDUSD, NZDUSD, USDCHF
- **Metals**: XAUUSD
- **Indices**: NAS100, US30, GER40

## Key Features

### 1. Multi-Symbol Engine
- Each symbol operates independently with its own:
  - Magic number (BaseMagicNumber + symbol index)
  - Tick buffers and trend analysis
  - ATR volatility tracking
  - Spread monitoring
  - Position management

### 2. Entry Logic (All Filters Must Pass)

#### A. Micro Trend Filter
- Analyzes last 30 ticks per symbol
- Calculates upward vs downward movement
- **TrendBias = BUY** if upward movement > threshold
- **TrendBias = SELL** if downward movement > threshold
- No trade if trend is neutral

#### B. ATR Volatility Filter
- Uses ATR(14) on M1 timeframe
- Blocks trades if ATR is too low (dead market)
- Blocks trades if ATR is extremely high (news spike)
- Configurable min/max multipliers

#### C. Spread Filter
- Current spread must be ≤ average spread × 1.3 (configurable)
- Range of last 10 ticks must be ≥ spread × 1.5 (configurable)
- Ensures sufficient price movement relative to spread

#### D. Tick Activity Filter
- Counts ticks in the last 1 second
- Requires minimum 5 ticks per second (configurable)
- Ensures active market conditions

#### E. Session Filter (Optional)
- Only trades during London + New York sessions
- Default: 8:00 - 22:00 GMT
- Can be disabled via input parameter

### 3. Order Settings

#### Auto Point Normalization
The EA automatically adjusts point sizes based on symbol type:
- **Forex**: 0.0001 (or 0.00001 for 5-digit brokers)
- **Metals**: 0.01
- **Indices**: 1.0

### 4. Exit Rules

All symbols use the same exit logic, auto-adjusted by point size:

- **Stop Loss**: 25 points (configurable)
- **Take Profit**: 15 points (configurable)
- **Break-Even**: Moves SL to entry after +7 points profit (configurable)
- **Trailing Stop**: Activates after +10 points profit (configurable)
  - Trailing step: 2 points (configurable)
- **Time-Based Exit**: Force closes after 20 seconds (configurable)
- **Immediate Profit Exit**: Closes immediately if profit > 0 (optional)

### 5. Lot Sizing

Two modes available:

#### Fixed Mode
- Uses `FixedLotSize` exactly for all trades
- Simple and predictable

#### Risk Mode (Recommended)
- Calculates lot size based on account risk percentage
- Formula: `Lot = (AccountRisk% × Equity) / (SL distance in money)`
- Automatically respects broker min/max/step requirements
- Adapts to account size and risk tolerance

### 6. Trade Management

For each open position, the EA:
- Monitors TP/SL hits (handled by broker)
- Applies break-even rule automatically
- Activates trailing stop when conditions are met
- Closes positions after max hold time
- Closes positions if spread widens beyond safety limit (2× average)
- Closes positions immediately if profit > 0 (if enabled)

## Input Parameters

### Trading Settings
- `BaseMagicNumber`: Base magic number (each symbol gets baseMagic + index)
- `TradeEnabled`: Enable/disable trading

### Lot Sizing
- `LotMode`: FIXED or RISK
- `FixedLotSize`: Fixed lot size (if LotMode = FIXED)
- `RiskPercent`: Risk % per trade (if LotMode = RISK)

### Entry Filters
- `TrendThreshold`: Trend bias threshold in points
- `ATRMinMultiplier`: Minimum ATR multiplier (block dead market)
- `ATRMaxMultiplier`: Maximum ATR multiplier (block news spike)
- `SpreadMultiplier`: Spread must be ≤ avgSpread × this value
- `TickRangeMultiplier`: Last 10 ticks range must be ≥ spread × this value
- `MinTicksPerSecond`: Minimum ticks per second required
- `UseSessionFilter`: Enable London + New York session filter

### Exit Settings
- `StopLossPoints`: Stop loss in points
- `TakeProfitPoints`: Take profit in points
- `BreakEvenPoints`: Move to BE after +X points profit
- `TrailingStartPoints`: Start trailing after +X points profit
- `TrailingStepPoints`: Trailing step in points
- `MaxHoldSeconds`: Force close after X seconds
- `CloseOnAnyProfit`: Close immediately if profit > 0

### Risk Management
- `MaxSpreadWidenMultiplier`: Close if spread widens beyond avgSpread × this value

## Installation

1. Copy `HyperPortfolioScalperMT5V6.mq5` to `MQL5/Experts/`
2. Compile in MetaEditor (F7)
3. Attach to any chart in MT5 (the EA will trade all symbols regardless of chart symbol)
4. Configure input parameters
5. Enable AutoTrading

## Important Notes

### Symbol Requirements
- All symbols must be available in Market Watch
- Ensure symbols are spelled correctly (case-sensitive)
- Some brokers may use different symbol names (e.g., NAS100 vs NASDAQ, US30 vs DOW)

### Performance Considerations
- The EA processes all symbols on every tick
- Designed for efficient execution with minimal blocking
- Skips symbols with no ticks (weekends, closed markets)
- Uses MT5's built-in position management for TP/SL

### Risk Warnings
- This EA trades multiple symbols simultaneously
- High-frequency trading may result in many trades
- Use appropriate risk settings
- Test thoroughly on demo account before live trading
- Monitor spread conditions, especially during news events

## Technical Details

### Magic Numbers
Each symbol gets a unique magic number:
- EURUSD: BaseMagicNumber + 0
- GBPUSD: BaseMagicNumber + 1
- USDJPY: BaseMagicNumber + 2
- ... and so on

### Tick Processing
- Uses MT5's microsecond timestamp support for accurate tick tracking
- Maintains circular buffers for efficient memory usage
- Processes ticks independently per symbol

### Position Management
- Only 1 trade per symbol at a time
- Multiple trades across different symbols allowed (portfolio trading)
- Each position managed independently with its own SL/TP/BE/trailing

## Troubleshooting

### EA Not Trading
1. Check that AutoTrading is enabled in MT5
2. Verify all symbols are in Market Watch
3. Check that filters are not too restrictive
4. Ensure session filter allows trading (if enabled)
5. Check account balance and margin requirements

### Positions Not Closing
1. Verify TP/SL levels are set correctly
2. Check broker's minimum stop level requirements
3. Ensure spread hasn't widened beyond limits
4. Check that time-based exit is working (max hold seconds)

### Lot Size Issues
1. Verify broker's min/max lot size settings
2. Check account balance for risk-based lot sizing
3. Ensure lot step is correct for your broker

## Version History

### V6.00
- Initial release
- Multi-symbol portfolio trading
- Complete filter system implementation
- Advanced exit management
- Risk-based lot sizing

## Support

For issues or questions, please refer to the code comments or contact support.

---

**Disclaimer**: This EA is for educational and research purposes. Trading involves risk. Past performance does not guarantee future results. Always test thoroughly on demo accounts before live trading.



