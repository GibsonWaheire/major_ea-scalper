# Hybrid Trend Pullback - USDJPY Optimized Versions

## 📋 Two Versions Available

### ✅ Version 1: `HybridTrendPullback_USDJPY.mq5`
**Uses Core Folder Structure**
- **Location**: `MT5/MQL5/Experts/HybridTrendPullback_USDJPY.mq5`
- **Dependencies**: Requires core folder in `MT5/MQL5/Include/HybridTrendPullbackMT5/core/`
- **Params File**: Uses `params_usdjpy.mqh` (USDJPY-optimized defaults)
- **Best For**: Modular development, easy parameter tweaking

### ✅ Version 2: `HybridTrendPullback_USDJPY_Standalone.mq5`
**Standalone - No Dependencies**
- **Location**: `MT5/MQL5/Experts/HybridTrendPullback_USDJPY_Standalone.mq5`
- **Dependencies**: None - all code in one file
- **Best For**: Quick setup, sharing, simplicity

---

## 🎯 USDJPY Optimizations Applied

Both versions have these optimizations:

### Spread Settings
- **Max Spread**: 3.0 pips (vs 25 for Gold)
- **Reason**: USDJPY typically has 1-2 pips spread

### EMA Periods
- **Fast EMA**: 21 (vs 50 for Gold)
- **Slow EMA**: 50 (vs 200 for Gold)
- **Reason**: Faster response for USDJPY trends

### Risk/Reward
- **Stop Loss**: 1.5x ATR
- **Take Profit**: 3.0x ATR
- **Risk/Reward**: 1:2 minimum
- **Risk Per Trade**: 0.5% (conservative)

### Break-Even & Trailing
- **Break-Even**: Moves to BE at 1:1 RR with 5 pip buffer
- **Trailing Start**: 1.5:1 RR
- **Trailing Step**: 10 pips (vs 25 for Gold)

### Volatility Filter
- **Min ATR to Spread**: 2.5x (vs 3.0x for Gold)
- **Max ATR % of Price**: 0.20% (vs 0.30% for Gold)

---

## 🚀 Quick Start

### For Version 1 (Core Folder):
1. Ensure core folder is in: `MT5/MQL5/Include/HybridTrendPullbackMT5/core/`
2. Open MetaEditor (F4)
3. Find `HybridTrendPullback_USDJPY.mq5` in Experts
4. Compile (F7)
5. Attach to USDJPY M5 chart

### For Version 2 (Standalone):
1. Open MetaEditor (F4)
2. Find `HybridTrendPullback_USDJPY_Standalone.mq5` in Experts
3. Compile (F7)
4. Attach to USDJPY M5 chart

---

## ⚙️ Default Parameters (Both Versions)

- **Symbol**: USDJPY
- **Entry Timeframe**: M5
- **Trend Timeframe**: H1
- **Fast EMA**: 21
- **Slow EMA**: 50
- **Risk Per Trade**: 0.5%
- **Max Spread**: 3.0 pips
- **Stop Loss**: 1.5x ATR
- **Take Profit**: 3.0x ATR (1:2 RR)
- **Break-Even**: Enabled at 1:1 RR
- **Trailing Stop**: Enabled at 1.5:1 RR

---

## 📊 Strategy Overview

1. **HTF Trend Filter** (H1): Only trades with trend (EMA 21 > EMA 50 = BUY, EMA 21 < EMA 50 = SELL)
2. **Pullback Entry** (M5): Waits for price to pull back to EMA 21 ± 50% ATR
3. **Momentum Confirmation**: Requires strong momentum candle
4. **Volatility Check**: Ensures sufficient liquidity
5. **Risk Management**: ATR-based stops, break-even, trailing stops

---

## ⚠️ Important Notes

- **Not a Scalper**: Holds trades for hours/days
- **Trend Required**: Needs clear H1 trend - may not trade in ranging markets
- **Patience**: May go days without trades (this is normal)
- **Demo First**: Always test on demo before live

---

## 🔍 Troubleshooting

**Version 1 won't compile?**
- Check that core folder exists in `MT5/MQL5/Include/HybridTrendPullbackMT5/core/`
- Verify all .mqh files are present
- Check that `params_usdjpy.mqh` is in the core folder

**Version 2 won't compile?**
- Check for syntax errors in MetaEditor
- Ensure you're using MT5 (not MT4)
- Check that all MT5 functions are used (CopyOpen, CopyClose, etc.)

**EA not trading?**
- Check H1 chart for clear trend bias
- Verify session filter (London/NY hours)
- Check spread (must be ≤ 3.0 pips)
- Ensure sufficient volatility (ATR check)

---

Both versions are now ready to use! Choose the one that fits your workflow.
