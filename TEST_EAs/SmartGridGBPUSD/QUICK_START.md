# Quick Start Guide - Smart Grid EA for GBPUSD

## Installation (5 Minutes)

1. **Copy EA to MT5**
   - Navigate to: `MetaTrader 5/MQL5/Experts/`
   - Copy `SmartGridGBPUSD.mq5` to this folder

2. **Compile**
   - Open MetaEditor (F4 in MT5)
   - Open `SmartGridGBPUSD.mq5`
   - Click "Compile" (F7)
   - Check for errors (should be none)

3. **Attach to Chart**
   - Open GBPUSD chart (any timeframe, H1 recommended)
   - Drag EA from Navigator to chart
   - Configure parameters (see below)
   - Enable "AutoTrading" button

## Recommended Initial Settings

### For Prop Firm Challenges (Conservative)
```
LotSize = 0.01
ATR_Multiplier = 2.0
MaxGridLevels = 5
GlobalStopLoss = 5.0
TakeProfitPips = 50
StopLossPips = 100
UseNewsFilter = true
NewsBlockMinutes = 30
UseBasketTrailing = true
TrailingStartPips = 30
TrailingStepPips = 10
```

### For Live Trading (Moderate)
```
LotSize = 0.02
ATR_Multiplier = 1.5
MaxGridLevels = 8
GlobalStopLoss = 7.0
TakeProfitPips = 50
StopLossPips = 100
UseNewsFilter = true
NewsBlockMinutes = 30
UseBasketTrailing = true
TrailingStartPips = 20
TrailingStepPips = 10
```

## First Steps

1. **Test on Demo First**
   - Always test on demo account for at least 1 week
   - Monitor how EA behaves during different market conditions
   - Adjust parameters based on results

2. **Update News Times**
   - Check your broker's economic calendar
   - Update `NewsTimes` parameter with actual high-impact news times
   - Format: `"08:30,12:30,13:30,14:00,15:30"` (GMT)

3. **Monitor Key Metrics**
   - Watch total positions (should stay under MaxGridLevels)
   - Monitor basket profit
   - Check drawdown percentage
   - Review EA logs in Experts tab

## Common Issues & Solutions

### EA Not Trading
- ✅ Check if news filter is active (check logs)
- ✅ Verify ATR is calculating (check Data Window)
- ✅ Ensure MaxGridLevels not reached
- ✅ Check if EA disabled (drawdown stop)

### Too Many Trades
- ⬆️ Increase `ATR_Multiplier` (e.g., 2.0 or 2.5)
- ⬆️ Reduce `MaxGridLevels`
- ⬆️ Increase `NewsBlockMinutes`

### Too Few Trades
- ⬇️ Decrease `ATR_Multiplier` (e.g., 1.2 or 1.0)
- ⬇️ Increase `MaxGridLevels`
- ⬇️ Check if news filter too restrictive

### Positions Not Closing
- ✅ Verify basket profit above `TrailingStartPips`
- ✅ Check if `TrailingStepPips` too large
- ✅ Ensure positions have correct MagicNumber

## Important Reminders

⚠️ **Prop Firm Rules**
- Verify your firm allows grid trading
- Some firms ban grid/martingale strategies
- Always check firm-specific rules before using

⚠️ **Risk Management**
- Never risk more than you can afford
- Start with minimum lot size
- Use demo account first
- Monitor drawdown closely

⚠️ **News Events**
- GBPUSD is highly volatile during news
- Update news times regularly
- Consider extending block window during major events

## Testing Checklist

Before going live, verify:
- [ ] EA compiles without errors
- [ ] EA opens positions correctly
- [ ] News filter blocks trading as expected
- [ ] Drawdown protection triggers correctly
- [ ] Basket trailing works properly
- [ ] Positions close correctly
- [ ] Daily reset works (test by changing system date)
- [ ] No errors in log files

## Support

If you encounter issues:
1. Check the Experts log in MT5
2. Verify all parameters are set correctly
3. Test on demo account first
4. Review README.md for detailed documentation

---

**Remember**: This EA is a tool, not a guarantee. Always practice proper risk management!

