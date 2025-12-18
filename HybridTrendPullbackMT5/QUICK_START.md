# Quick Start Guide - Hybrid Trend Pullback USDJPY

## ✅ Both Versions Are Ready!

### 📁 Files Created:

1. **`HybridTrendPullback_USDJPY.mq5`** - Uses core folder (modular)
2. **`HybridTrendPullback_USDJPY_Standalone.mq5`** - Standalone (one file)

### 📍 Current Status:

✅ Both EAs copied to MT5 Experts folder  
✅ Core folder copied to MT5 Include folder  
✅ USDJPY-optimized parameters applied  
✅ Ready to compile!

---

## 🚀 How to Activate

### Step 1: Open MetaEditor
- Press **F4** in MetaTrader 5
- Or go to **Tools → MetaQuotes Language Editor**

### Step 2: Choose Your Version

**Option A: Core Folder Version (Recommended)**
- In Navigator, find: `Experts → HybridTrendPullback_USDJPY.mq5`
- Double-click to open

**Option B: Standalone Version (Easier)**
- In Navigator, find: `Experts → HybridTrendPullback_USDJPY_Standalone.mq5`
- Double-click to open

### Step 3: Compile
- Press **F7** or click **Compile** button
- Check the **Toolbox** panel at bottom
- Should show: **"0 error(s), 0 warning(s)"**

### Step 4: Attach to Chart
1. Open a **USDJPY** chart
2. Set timeframe to **M5** (recommended)
3. Drag the EA from Navigator onto the chart
4. Configure settings (or use defaults)
5. Enable **AutoTrading** (green button in toolbar)
6. Click **OK**

---

## ⚙️ Default Settings (Both Versions)

All parameters are pre-optimized for USDJPY:

- **Symbol**: USDJPY
- **Entry TF**: M5
- **Trend TF**: H1
- **Fast EMA**: 21
- **Slow EMA**: 50
- **Risk**: 0.5% per trade
- **Max Spread**: 3.0 pips
- **SL**: 1.5x ATR
- **TP**: 3.0x ATR (1:2 RR)
- **Break-Even**: Enabled
- **Trailing**: Enabled

---

## 🔍 If Compilation Fails

### For Core Folder Version:
1. Check that core folder exists:
   ```
   MT5/MQL5/Include/HybridTrendPullbackMT5/core/
   ```
2. Verify these files are present:
   - `params_usdjpy.mqh` ✅
   - `state.mqh` ✅
   - `utils.mqh` ✅
   - `trend_bias.mqh` ✅
   - `entry_signal.mqh` ✅
   - `vol_filter.mqh` ✅
   - `risk.mqh` ✅ (or `Risk.mqh`)
   - `trade_mgmt.mqh` ✅
   - `session.mqh` ✅

3. If `risk.mqh` is missing but `Risk.mqh` exists:
   - The EA looks for `risk.mqh` (lowercase)
   - You may need to rename or create a symlink

### For Standalone Version:
- Should compile without issues
- If errors occur, check MetaEditor error messages
- Common issues: MT4 functions used instead of MT5

---

## 📊 What to Expect

### Trading Behavior:
- **Frequency**: Low (quality over quantity)
- **Hold Time**: Hours to days
- **Entries**: Only during London/NY sessions
- **Trend Required**: Needs clear H1 trend

### When It Trades:
1. H1 shows clear trend (EMA 21 vs EMA 50)
2. M5 price pulls back to EMA 21
3. Strong momentum candle appears
4. Volatility is sufficient
5. Spread is acceptable (≤ 3 pips)

### When It Doesn't Trade:
- No clear H1 trend (ranging market)
- Outside London/NY sessions
- Spread too wide (> 3 pips)
- Insufficient volatility
- Already in a position (if one-position-only enabled)

---

## 🎯 Next Steps

1. **Compile** both versions
2. **Test on Demo** first (2-4 weeks recommended)
3. **Monitor** H1 chart to understand trend bias
4. **Backtest** if possible (6-12 months data)
5. **Go Live** only after consistent demo performance

---

## 📝 File Locations

**In Your Project:**
- `/HybridTrendPullbackMT5/HybridTrendPullback_USDJPY.mq5`
- `/HybridTrendPullbackMT5/HybridTrendPullback_USDJPY_Standalone.mq5`
- `/HybridTrendPullbackMT5/core/` (all .mqh files)

**In MT5:**
- Experts: `MT5/MQL5/Experts/HybridTrendPullback_USDJPY*.mq5`
- Include: `MT5/MQL5/Include/HybridTrendPullbackMT5/core/*.mqh`

---

**Both versions are ready to use! Choose the one that works best for you.**
