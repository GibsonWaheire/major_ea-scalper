# Hybrid Trend Pullback - USDJPY Optimization Summary

## 🎯 Why This EA Was Selected

After scanning all your EAs, **HybridTrendPullbackMT5** was identified as the best candidate for USDJPY profitability because:

1. ✅ **Trend-Following Strategy** (not scalping) - Holds trades longer for meaningful moves
2. ✅ **Pullback Entries** - Enters on retracements, not breakouts (better risk/reward)
3. ✅ **HTF Bias** - Uses H1 trend filter to only trade with the trend
4. ✅ **Proper Risk Management** - ATR-based stops, break-even, trailing stops
5. ✅ **Session Filtering** - Trades during London/NY sessions (best liquidity for USDJPY)
6. ✅ **Well-Structured Code** - Modular, maintainable, easy to optimize

## 📊 Key Optimizations for USDJPY

### 1. Spread Settings
- **Original (Gold)**: 25.0 pips max spread
- **USDJPY Optimized**: 3.0 pips max spread
- **Reason**: USDJPY typically has 1-2 pips spread, 3 pips is a safe filter

### 2. ATR Multipliers
- **Pullback Tolerance**: 0.50 (50% of ATR) - tighter for USDJPY
- **Momentum Body**: 0.20 (20% of ATR) - adjusted for USDJPY volatility
- **Momentum Range**: 0.50 (50% of ATR) - ensures meaningful candles
- **Min ATR to Spread**: 2.5x (vs 3.0x for Gold) - USDJPY needs less volatility

### 3. EMA Periods
- **Fast EMA**: 21 (vs 50 for Gold) - faster response for USDJPY
- **Slow EMA**: 50 (vs 200 for Gold) - optimized for USDJPY trends
- **Entry EMA**: 21 - good for M5 pullback detection

### 4. Risk/Reward Ratios
- **Stop Loss**: 1.5x ATR (vs 1.8x for Gold) - tighter stops for USDJPY
- **Take Profit**: 3.0x ATR (vs 2.4x for Gold) - **1:2 Risk/Reward ratio**
- **Risk Per Trade**: 0.5% (conservative, can increase to 1% if comfortable)

### 5. Break-Even & Trailing
- **Break-Even**: Moves to BE at 1:1 RR with 5 pip buffer
- **Trailing Start**: Begins at 1.5:1 RR
- **Trailing Step**: 10 pips (vs 25 for Gold) - tighter for USDJPY
- **Trailing Distance**: 60% of ATR

### 6. Volatility Filter
- **Max ATR % of Price**: 0.20% (vs 0.30% for Gold) - prevents trading in extreme volatility
- **Min ATR to Spread**: 2.5x - ensures sufficient movement

## 🎯 Strategy Overview

### Entry Logic
1. **HTF Trend Bias** (H1):
   - Fast EMA (21) > Slow EMA (50) = Bullish bias → Only BUY
   - Fast EMA (21) < Slow EMA (50) = Bearish bias → Only SELL
   - Waits 2 bars after trend flip to avoid false signals

2. **Pullback Entry** (M5):
   - Price pulls back to Entry EMA (21) ± 50% of ATR
   - Momentum candle required (body ≥ 20% ATR, range ≥ 50% ATR)
   - Candle direction must match trend bias

3. **Volatility Check**:
   - ATR must be ≥ 2.5x current spread
   - ATR must be ≤ 0.20% of price (prevents extreme volatility)

### Exit Logic
1. **Take Profit**: 3.0x ATR (1:2 Risk/Reward)
2. **Stop Loss**: 1.5x ATR (beyond pullback zone)
3. **Break-Even**: Moves SL to entry + 5 pips when trade reaches 1:1 RR
4. **Trailing Stop**: Activates at 1.5:1 RR, trails by 10 pips or 60% ATR (whichever is larger)

### Risk Management
- **Risk Per Trade**: 0.5% of account balance
- **Position Sizing**: Automatically calculated based on SL distance
- **One Position Only**: Prevents overexposure
- **Session Filter**: Only trades London (7-17 GMT) and NY (13-22 GMT) sessions

## 📈 Expected Performance Characteristics

### Strengths
- ✅ **Trend-Following**: Catches sustained moves in USDJPY
- ✅ **Pullback Entries**: Better entry prices, lower risk
- ✅ **HTF Bias**: Only trades with the trend (higher win rate)
- ✅ **Conservative Risk**: 0.5% per trade, 1:2 RR minimum

### Considerations
- ⚠️ **Lower Trade Frequency**: Quality over quantity (fewer but better trades)
- ⚠️ **Requires Trend**: May not trade in ranging markets
- ⚠️ **Patience Required**: May wait days for good setups

## 🔧 Recommended Settings

### Conservative (Recommended Start)
- Risk Per Trade: 0.5%
- Max Spread: 3.0 pips
- All other settings: Default

### Moderate
- Risk Per Trade: 1.0%
- Max Spread: 3.5 pips
- TP ATR Multiplier: 3.5 (1:2.3 RR)

### Aggressive
- Risk Per Trade: 1.5%
- Max Spread: 4.0 pips
- TP ATR Multiplier: 4.0 (1:2.7 RR)
- Disable "One Position Only" (allows multiple positions)

## 📊 Backtesting Recommendations

1. **Time Period**: Test on at least 6-12 months of data
2. **Timeframe**: Use M5 chart (entry timeframe)
3. **Spread**: Set to realistic broker spread (1.5-2.0 pips for USDJPY)
4. **Model**: Use "Every tick" for best accuracy
5. **Optimization**: Test different EMA periods and ATR multipliers

## ⚠️ Important Notes

1. **Not a Scalper**: This EA holds trades for hours/days, not seconds
2. **Trend Required**: Needs clear trend on H1 - may not trade in ranging markets
3. **Patience**: May go days without trades (this is normal and good)
4. **Demo First**: Always test on demo account before live trading
5. **Monitor**: Check H1 chart regularly to understand current trend bias

## 🚀 Installation

1. File is already copied to MT5 Experts folder
2. Open MetaEditor (F4)
3. Find `HybridTrendPullback_USDJPY_Optimized.mq5`
4. Compile (F7)
5. Attach to USDJPY M5 chart
6. Enable AutoTrading

## 📝 Next Steps

1. **Backtest**: Run backtest on USDJPY M5 for 6-12 months
2. **Forward Test**: Run on demo account for 2-4 weeks
3. **Monitor**: Watch how it trades, understand the logic
4. **Optimize**: If needed, adjust EMA periods or ATR multipliers based on results
5. **Go Live**: Only after consistent demo performance

---

**Remember**: This EA is designed for profitability, not high frequency. Quality trades with proper risk management will compound over time.
