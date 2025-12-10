# Hyperactive HFT MT5 Scalper

## Overview

**Hyperactive HFT MT5 Scalper** is an ultra-fast high-frequency trading Expert Advisor designed for MT5. It uses momentum breakout entry signals and implements dynamic profit/loss management with strict time-based exits.

## Key Features

### Trading Strategy
- **One Trade at a Time**: Ensures only one position is open at any given moment
- **Momentum Breakout Entry**: Detects strong price movements in the direction of momentum
- **Fast Execution**: Optimized for quick order placement and closure
- **Multi-Instrument Support**: Can trade any symbol (configured via input parameter)

### Profit Management
- **Dynamic Profit Exit**: Closes immediately when profit target is reached
- **Flexible Hold Time**: Profitable trades can be held up to 20 seconds (configurable)
- **Immediate Exit Option**: Can exit as soon as profit target is met (configurable)

### Loss Protection
- **Maximum Loss Limit**: Hard stop at 100 points (configurable)
- **Time-Based Loss Exit**: Automatically closes losing trades after 10 seconds (configurable)
- **Stop Loss Support**: Optional hard stop loss with configurable points

### Lot Sizing
- **Fixed Mode**: Use a fixed lot size for all trades
- **Dynamic Mode**: Automatically calculate lot size based on account balance
- **Safety Limits**: Maximum and minimum lot size protection

### Risk Management
- **Drawdown Protection**: Stops trading if drawdown exceeds threshold
- **Daily Profit Target**: Optional daily profit limit
- **Spread Filter**: Blocks trading when spread is too high
- **Tick Speed Filter**: Ensures sufficient market activity before trading

## Input Parameters

### Core Trading Settings
- **MagicNumber**: Unique identifier for EA trades (default: 202510)
- **TradeSymbol**: Symbol to trade (empty = current chart symbol)
- **UseFixedLot**: Enable fixed lot sizing (true) or dynamic (false)
- **FixedLotSize**: Fixed lot size when UseFixedLot = true (default: 0.05)
- **DynamicLotBase**: Base lot for dynamic sizing (default: 0.01)
- **DynamicLotMultiplier**: Multiplier for dynamic lot calculation (default: 1.2)
- **MaxLotSize**: Maximum lot size safety limit (default: 1.00)
- **MinLotSize**: Minimum lot size safety limit (default: 0.01)

### Momentum Breakout Entry
- **MomentumPeriod**: Period for momentum calculation in ticks (default: 10)
- **BreakoutThreshold**: Minimum price movement for breakout (default: 0.0002)
- **MinTickSpeed**: Minimum ticks per second for entry (default: 3)
- **UseTickSpeedFilter**: Enable tick speed filter (default: true)

### Profit Exit Settings
- **MinProfitPoints**: Minimum profit in points to exit (default: 1.0)
- **MaxProfitHoldSeconds**: Maximum seconds to hold profitable trade (default: 20)
- **ExitImmediatelyOnProfit**: Exit immediately when profit target reached (default: true)

### Loss Protection Settings
- **MaxLossPoints**: Maximum loss in points before closing (default: 100.0)
- **MaxLossHoldSeconds**: Close losing trade after N seconds (default: 10)
- **UseTimeBasedLossExit**: Enable time-based loss exit (default: true)

### Stop Loss Settings
- **UseStopLoss**: Enable hard stop loss (default: true)
- **StopLossPoints**: Stop loss in points (default: 100.0)
- **UseTrailingStop**: Enable trailing stop loss (default: false)
- **TrailingStartPoints**: Start trailing after X points profit (default: 20.0)
- **TrailingStepPoints**: Trailing step in points (default: 5.0)

### Spread & Execution
- **MaxSpreadPoints**: Maximum spread in points (default: 50.0)
- **MaxSlippagePoints**: Maximum slippage in points (default: 10)
- **OrderRetries**: Number of order retries (default: 3)

### Risk Management
- **MaxDrawdownPercent**: Maximum drawdown % before stopping (default: 30.0)
- **UseDrawdownProtection**: Enable drawdown protection (default: true)
- **DailyProfitTarget**: Daily profit target in currency (0 = disabled)

### Session Filter
- **UseSessionFilter**: Enable session filter (default: false)
- **SessionStartHour**: Session start hour GMT (default: 8)
- **SessionEndHour**: Session end hour GMT (default: 20)

## How It Works

### Entry Logic
1. **Momentum Detection**: Tracks price movement over the last N ticks
2. **Breakout Detection**: Identifies strong price movements exceeding threshold
3. **Direction Confirmation**: Requires at least 2 consecutive ticks in momentum direction
4. **Filter Checks**: Validates spread, tick speed, and session (if enabled)

### Exit Logic
1. **Immediate Profit Exit**: Closes when profit >= MinProfitPoints (if enabled)
2. **Maximum Loss**: Closes when loss >= MaxLossPoints
3. **Time-Based Loss Exit**: Closes losing trades after MaxLossHoldSeconds (10 seconds)
4. **Maximum Profit Hold**: Closes profitable trades after MaxProfitHoldSeconds (20 seconds)
5. **Trailing Stop**: Optional trailing stop for profitable trades

### Lot Sizing
- **Fixed Mode**: Uses FixedLotSize for all trades
- **Dynamic Mode**: Calculates lot = DynamicLotBase * (Balance / 1000) * DynamicLotMultiplier
- Both modes respect MinLotSize and MaxLotSize limits

## Usage Instructions

1. **Installation**: Copy `HyperactiveHFTMT5.mq5` to `MQL5/Experts/`
2. **Compilation**: Compile in MetaEditor (F7)
3. **Attach to Chart**: Drag EA onto chart or attach via Navigator
4. **Configure Parameters**: Adjust inputs according to your risk tolerance
5. **Enable AutoTrading**: Ensure AutoTrading is enabled in MT5

## Important Notes

### High Risk EA
This EA is designed for high-frequency trading and carries significant risk:
- Fast execution means rapid trade opening/closing
- Small profit targets with quick exits
- Time-based loss exits can close trades quickly
- **Use on demo account first to understand behavior**

### Symbol Configuration
- Set `TradeSymbol` to empty string ("") to trade current chart symbol
- Set `TradeSymbol` to specific symbol (e.g., "EURUSD", "XAUUSD") to trade that symbol
- EA will validate symbol availability on initialization

### Breakout Threshold
- Adjust `BreakoutThreshold` based on symbol characteristics
- For XAUUSD: Try 0.0002 to 0.0005
- For EURUSD: Try 0.0001 to 0.0002
- For indices: Adjust based on typical price movements

### Lot Sizing Recommendations
- **Fixed Mode**: Start with 0.01-0.05 for testing
- **Dynamic Mode**: Adjust DynamicLotBase and DynamicLotMultiplier based on account size
- Always respect broker's minimum/maximum lot requirements

## Risk Warnings

⚠️ **HIGH RISK TRADING**
- This EA executes trades very quickly
- Losses can accumulate rapidly if market conditions are unfavorable
- Always use proper risk management settings
- Test thoroughly on demo account before live trading
- Never risk more than you can afford to lose

## Performance Tips

1. **VPS Recommended**: Use a VPS for consistent execution and low latency
2. **Low Spread Symbols**: Works best on symbols with tight spreads
3. **Active Market Hours**: More effective during high-volume trading sessions
4. **Monitor Drawdown**: Keep an eye on drawdown protection settings
5. **Adjust Parameters**: Fine-tune based on your broker's execution speed

## Version History

### Version 1.00 (2025-01-XX)
- Initial release
- Momentum breakout entry system
- Dynamic profit/loss exit management
- Fixed and dynamic lot sizing
- Time-based exit controls
- Multi-instrument support

## Support

For issues, questions, or feature requests, please refer to the main repository documentation.

---

**Disclaimer**: This EA is provided as-is for educational and research purposes. Trading involves substantial risk of loss. Past performance does not guarantee future results.


