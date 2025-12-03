# Daily Hold Scalper - MT5 Expert Advisor

**Version:** 1.00  
**Platform:** MetaTrader 5  
**Type:** Daily Hold Strategy with Market Analysis

## 🎯 Strategy Overview

This EA takes trades immediately based on market analysis and holds them for the entire trading day. It's designed to take a maximum of 5 trades per day with 10-minute intervals between trades, using 10% risk per trade and a maximum daily drawdown of 40%.

## ✨ Key Features

### Trading Logic
- **Immediate Entry**: Takes trades immediately when market analysis signals are detected
- **Market Analysis**: Uses EMA crossovers, RSI momentum, and ATR volatility filters
- **Multi-Symbol Support**: Can trade multiple major pairs simultaneously (USDGBP, USDJPY, GBPUSD, EURUSD, USDCHF)
- **10-Minute Intervals**: Waits 10 minutes between new trades
- **Daily Hold**: All trades are held for the entire trading day

### Risk Management
- **10% Risk Per Trade**: Each trade risks 10% of account balance
- **40% Maximum Daily Drawdown**: If drawdown reaches 40%, all trades are closed immediately
- **No Stop Loss**: Trades have no stop loss (as per requirements)
- **Automatic Take Profit**: TP levels are set automatically for each trade (50% profit target)
- **Partial Closes**: When EA is active, can perform partial closes at 30% profit

### Trade Management
- **Maximum 5 Trades Per Day**: Strict limit on daily trades
- **Automatic TP**: Take profit levels are set on orders so trades can close even when EA is inactive
- **Partial Close Feature**: Closes 50% of position at 30% profit (when EA is active)
- **Daily Reset**: All tracking resets at the start of each new trading day

## 📊 Market Analysis

The EA uses a combination of technical indicators to determine trade direction:

1. **EMA Crossover**: Fast EMA (9) vs Slow EMA (21) for trend direction
2. **RSI Momentum**: RSI (14) for momentum confirmation
3. **ATR Volatility**: ATR (14) to ensure sufficient volatility
4. **Spread Filter**: Only trades when spread is within acceptable limits

### Entry Signals

**BUY Signal:**
- Fast EMA > Slow EMA (bullish trend)
- RSI > 50 and < 70 (bullish momentum, not overbought)
- ATR indicates sufficient volatility

**SELL Signal:**
- Fast EMA < Slow EMA (bearish trend)
- RSI < 50 and > 30 (bearish momentum, not oversold)
- ATR indicates sufficient volatility

## ⚙️ Input Parameters

### Trading Settings
- `TradeSymbols`: Comma-separated list of symbols to trade (default: "USDGBP,USDJPY,GBPUSD,EURUSD,USDCHF")
- `MagicNumber`: Unique identifier for EA trades (default: 202505)
- `MaxTradesPerDay`: Maximum trades per day (default: 5)
- `MinutesBetweenTrades`: Minutes to wait between trades (default: 10)
- `TradeEnabled`: Enable/disable trading (default: true)

### Risk Management
- `RiskPerTradePercent`: Risk percentage per trade (default: 10.0%)
- `MaxDailyDrawdownPercent`: Maximum daily drawdown before closing all trades (default: 40.0%)
- `NoStopLoss`: No stop loss on trades (default: true)

### Profit Management
- `TakeProfitPercent`: Take profit at this profit percentage (default: 50.0%)
- `PartialClosePercent`: Partial close at this profit percentage (default: 30.0%)
- `PartialCloseRatio`: Percentage of position to close at partial close level (default: 0.5 = 50%)
- `UsePartialCloses`: Enable partial closes (default: true)

### Market Analysis
- `EMA_Fast_Period`: Fast EMA period (default: 9)
- `EMA_Slow_Period`: Slow EMA period (default: 21)
- `RSI_Period`: RSI period (default: 14)
- `RSI_Oversold`: RSI oversold level (default: 30.0)
- `RSI_Overbought`: RSI overbought level (default: 70.0)
- `ATR_Period`: ATR period (default: 14)
- `MinATRMultiplier`: Minimum ATR multiplier for signal (default: 1.5)
- `MaxSpreadPips`: Maximum spread filter in pips (default: 5.0)

### Display Settings
- `ShowInfoPanel`: Show info panel on chart (default: true)
- `PanelColor`: Panel background color
- `PanelX`: Panel X position
- `PanelY`: Panel Y position

## 🛡️ Safety Features

### Daily Drawdown Protection
- Monitors equity vs. daily start equity
- Automatically closes ALL trades when drawdown reaches 40%
- Prevents further trading for the day after drawdown limit

### Trade Limits
- Maximum 5 trades per day (hard limit)
- 10-minute cooldown between trades
- Prevents overtrading

### Automatic Take Profit
- TP levels are set on each order
- Trades can close automatically even when EA is inactive
- TP is calculated based on 50% profit target

## 📈 How It Works

1. **Daily Reset**: At the start of each trading day, the EA resets all counters and tracking
2. **Market Analysis**: Continuously analyzes all configured symbols for trading opportunities
3. **Trade Entry**: When a signal is detected and conditions are met:
   - Calculates lot size based on 10% risk
   - Opens trade with automatic TP level
   - Records trade in daily tracking
4. **Trade Management**: 
   - Monitors all open positions
   - Performs partial closes at 30% profit (if enabled)
   - Updates TP levels as needed
   - Closes at 50% profit target
5. **Drawdown Protection**: 
   - Continuously monitors daily drawdown
   - Closes all trades immediately if 40% drawdown is reached
6. **Daily Limit**: Stops taking new trades after 5 trades per day

## ⚠️ Important Notes

1. **No Stop Loss**: This EA does not use stop losses. Trades can move against you significantly before closing at TP or drawdown limit.

2. **High Risk**: 10% risk per trade and 40% max drawdown means this EA can experience significant drawdowns. Use only with funds you can afford to risk.

3. **Daily Hold**: All trades are held for the entire day. They will only close at:
   - Take profit level (50% profit)
   - Partial close level (30% profit, 50% of position)
   - Daily drawdown limit (40% - closes all trades)

4. **EA Inactivity**: Take profit levels are set automatically, so trades can close even if the EA is not running. However, partial closes and drawdown monitoring require the EA to be active.

5. **Multi-Symbol**: The EA can trade multiple symbols simultaneously. Make sure all symbols are available in your broker and have sufficient liquidity.

## 🔧 Installation

1. Copy `DailyHoldScalper.mq5` to your MetaTrader 5 `Experts` folder
2. Restart MetaTrader 5 or refresh the Navigator
3. Drag the EA onto a chart (any chart - it trades multiple symbols)
4. Configure input parameters as needed
5. Enable AutoTrading
6. The EA will start trading when conditions are met

## 📝 Recommendations

- **Account Size**: Recommended minimum $1,000 account due to 10% risk per trade
- **Broker**: Use a reliable broker with tight spreads and good execution
- **VPS**: Consider using a VPS for 24/7 operation
- **Testing**: Test thoroughly on demo account before live trading
- **Monitoring**: Monitor the EA daily, especially during volatile market conditions

## 🐛 Troubleshooting

**EA not taking trades:**
- Check if `TradeEnabled` is true
- Verify symbols are correct and available
- Check if max trades per day reached
- Verify 10-minute interval has passed
- Check spread filter (may be too restrictive)

**Trades not closing:**
- TP levels are set automatically - check if TP was reached
- For partial closes, EA must be active
- Check if drawdown limit was reached (closes all trades)

**Position tickets not found:**
- This is normal in MT5 - positions may take a moment to appear
- EA will retry on next tick

## 📞 Support

For issues or questions, please refer to the code comments or contact support.

---

**Disclaimer**: Trading involves substantial risk of loss. This EA is provided as-is without warranty. Use at your own risk.




