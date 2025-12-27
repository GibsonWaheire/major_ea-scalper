# Smart Grid EA for GBPUSD

## Overview

The **Smart Grid EA** is a professional-grade Expert Advisor designed specifically for GBPUSD trading with prop-firm compliance in mind. It uses ATR-based dynamic spacing, includes a news filter, and implements strict risk management without Martingale (no lot size doubling).

## Key Features

### ✅ Prop-Firm Safe
- **No Martingale**: Fixed lot sizes only (no exponential risk)
- **ATR-Based Dynamic Spacing**: Grid adapts to market volatility
- **News Filter**: Automatically stops trading 30 minutes before high-impact news
- **Global Drawdown Protection**: Hard stop at 5% drawdown (configurable)
- **Basket Trailing Take Profit**: Locks in profits as the grid moves in your favor

### 📊 Core Modules

#### Module 1: ATR-Based Dynamic Spacing
Instead of fixed pip gaps, the EA uses Average True Range (ATR) to dynamically adjust grid spacing:
- **Volatile markets**: Grid widens automatically
- **Quiet markets**: Grid tightens for better entry points
- **Formula**: `GridGap = ATR(14, H1) × ATR_Multiplier`

#### Module 2: News Filter
Prevents trading during high-impact news events:
- Blocks trading 30 minutes before scheduled news
- Blocks trading 1 hour after news (configurable)
- Manual time list for major GBP/USD news events
- Fully customizable news times

#### Module 3: Global Drawdown Protection
Hard stop mechanism to protect your account:
- Monitors total account drawdown percentage
- Closes all positions if drawdown exceeds threshold
- Disables EA for the day after trigger
- Resets automatically at midnight GMT

#### Module 4: Grid Trading Logic
Professional grid trading without Martingale:
- Fixed lot sizes (no doubling)
- Maximum grid level limit
- Bidirectional or unidirectional grid options
- Dynamic entry based on ATR spacing

#### Module 5: Basket Trailing Take Profit
Advanced profit management:
- Trails the entire basket profit
- Locks in profits as market moves favorably
- Configurable trailing start and step
- Prevents giving back profits during reversals

## Input Parameters

### Grid Settings
- **LotSize** (0.01): Fixed lot size per position (No Martingale)
- **ATR_Multiplier** (1.5): Multiplier for ATR-based spacing
- **ATR_Period** (14): Period for ATR calculation
- **ATR_Timeframe** (H1): Timeframe for ATR
- **MaxGridLevels** (10): Maximum number of grid positions
- **GridStartSide** (0): 0=Both, 1=Buy only, 2=Sell only

### Risk Management
- **GlobalStopLoss** (5.0%): Maximum drawdown before hard stop
- **TakeProfitPips** (50): Take profit per position in pips
- **StopLossPips** (100): Stop loss per position in pips

### News Filter
- **UseNewsFilter** (true): Enable/disable news filter
- **NewsBlockMinutes** (30): Minutes before news to block trading
- **NewsTimes** ("08:30,12:30,13:30,14:00,15:30"): High-impact news times (GMT)

### Basket Trailing
- **UseBasketTrailing** (true): Enable basket trailing take profit
- **TrailingStartPips** (20): Start trailing after X pips profit
- **TrailingStepPips** (10): Trailing step in pips

### Execution Settings
- **MagicNumber** (999999): Unique identifier for EA trades
- **Slippage** (30): Maximum slippage in points

## Installation

1. Copy `SmartGridGBPUSD.mq5` to your MetaTrader 5 `MQL5/Experts/` directory
2. Compile the EA in MetaEditor
3. Attach to GBPUSD chart (any timeframe, but H1 recommended for ATR)
4. Configure parameters according to your risk tolerance
5. Enable AutoTrading

## Recommended Settings

### Conservative (Prop Firm Challenge)
```
LotSize = 0.01
ATR_Multiplier = 2.0
MaxGridLevels = 5
GlobalStopLoss = 5.0
UseNewsFilter = true
UseBasketTrailing = true
TrailingStartPips = 30
```

### Moderate
```
LotSize = 0.02
ATR_Multiplier = 1.5
MaxGridLevels = 8
GlobalStopLoss = 7.0
UseNewsFilter = true
UseBasketTrailing = true
TrailingStartPips = 20
```

### Aggressive (Not Recommended for Prop Firms)
```
LotSize = 0.05
ATR_Multiplier = 1.2
MaxGridLevels = 10
GlobalStopLoss = 10.0
UseNewsFilter = true
UseBasketTrailing = true
TrailingStartPips = 15
```

## How It Works

### Grid Entry Logic
1. EA calculates current ATR value
2. Determines dynamic gap: `ATR × Multiplier`
3. Monitors price movement from last grid level
4. Opens new position when price moves beyond dynamic gap
5. Uses fixed lot size (no Martingale)

### News Filter Logic
1. Checks current GMT time
2. Compares against configured news times
3. Blocks trading 30 minutes before and 1 hour after news
4. Logs blocking status every 5 minutes

### Drawdown Protection
1. Continuously monitors: `(Balance - Equity) / Balance × 100`
2. If drawdown ≥ GlobalStopLoss:
   - Closes all positions immediately
   - Disables EA for remainder of day
   - Resets at midnight GMT

### Basket Trailing
1. Tracks total profit of all open positions
2. When profit ≥ TrailingStartPips:
   - Records highest profit level
   - If profit drops by TrailingStepPips:
     - Closes all positions
     - Locks in profits

## Prop Firm Compliance

### ✅ Compliant Features
- **No Martingale**: Fixed lot sizes prevent exponential risk
- **News Filter**: Prevents trading during restricted times
- **Drawdown Protection**: Enforces daily drawdown limits
- **Risk Management**: Configurable stop loss per position

### ⚠️ Important Notes
- Always verify your prop firm's specific rules
- Some firms may restrict grid trading entirely
- Test thoroughly on demo before live trading
- Monitor news calendar and update `NewsTimes` as needed
- Adjust `GlobalStopLoss` to match your firm's requirements

## Customization

### Adding News Times
Edit the `NewsTimes` parameter:
```
NewsTimes = "08:30,12:30,13:30,14:00,15:30,16:00"
```
Format: `HH:MM` in GMT, comma-separated

### Adjusting ATR Sensitivity
- **Higher Multiplier** (2.0+): Wider grid, fewer trades, safer
- **Lower Multiplier** (1.0-1.5): Tighter grid, more trades, riskier

### Grid Direction
- **0 (Both)**: Opens both buy and sell positions
- **1 (Buy Only)**: Only opens buy positions (bullish bias)
- **2 (Sell Only)**: Only opens sell positions (bearish bias)

## Monitoring

### Key Metrics to Watch
- **Total Positions**: Should not exceed MaxGridLevels
- **Basket Profit**: Total profit of all open positions
- **Drawdown %**: Current account drawdown percentage
- **ATR Value**: Current ATR reading (check in Data Window)

### Log Messages
The EA logs important events:
- Grid position openings
- News filter activations
- Drawdown protection triggers
- Basket trailing activations
- Position closures

## Troubleshooting

### EA Not Opening Positions
1. Check if news filter is blocking trades
2. Verify ATR is calculating correctly
3. Ensure MaxGridLevels not reached
4. Check if EA is disabled (drawdown stop)

### Positions Not Closing
1. Verify basket profit is above trailing start
2. Check if trailing step is too large
3. Ensure positions have correct MagicNumber

### News Filter Too Restrictive
1. Reduce `NewsBlockMinutes`
2. Remove unnecessary times from `NewsTimes`
3. Disable filter temporarily: `UseNewsFilter = false`

## Risk Warnings

⚠️ **Trading involves substantial risk of loss**

- Grid trading can accumulate large drawdowns
- GBPUSD is highly volatile, especially during news
- Always use proper risk management
- Never risk more than you can afford to lose
- Test extensively on demo account first

## Version History

### v1.00 (Initial Release)
- ATR-based dynamic spacing
- News filter implementation
- Global drawdown protection
- Basket trailing take profit
- Fixed lot sizes (no Martingale)

## Support

For issues or questions:
1. Check the log files in MetaTrader 5
2. Verify all parameters are set correctly
3. Test on demo account first
4. Review prop firm rules for compliance

## License

This EA is provided as-is for educational and trading purposes. Use at your own risk.

---

**Remember**: No EA can guarantee profits. Always practice proper risk management and trade responsibly.

