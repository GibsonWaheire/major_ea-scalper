# Hybrid Trend Pullback - USDJPY Versions Summary

## ✅ Both Versions Created & Ready!

### 📦 Version 1: Core Folder Structure
**File**: `HybridTrendPullback_USDJPY.mq5`

**What It Is:**
- Uses modular core folder structure
- Includes all the important tools from core/
- Uses `params_usdjpy.mqh` for USDJPY-optimized defaults
- Better organized, easier to maintain

**Location in MT5:**
- EA: `MT5/MQL5/Experts/HybridTrendPullback_USDJPY.mq5`
- Core: `MT5/MQL5/Include/HybridTrendPullbackMT5/core/*.mqh`

**Status**: ✅ Copied to MT5, ready to compile

---

### 📦 Version 2: Standalone
**File**: `HybridTrendPullback_USDJPY_Standalone.mq5`

**What It Is:**
- All code in one file (no dependencies)
- Includes all core functionality inline
- No folder structure needed
- Easy to share and use

**Location in MT5:**
- EA: `MT5/MQL5/Experts/HybridTrendPullback_USDJPY_Standalone.mq5`

**Status**: ✅ Copied to MT5, ready to compile

---

## 🎯 What's Different?

### Both Versions Have:
✅ Same USDJPY-optimized parameters  
✅ Same trading logic  
✅ Same risk management  
✅ Same entry/exit rules  

### Only Difference:
- **Version 1**: Modular (uses core folder)
- **Version 2**: Standalone (one file)

---

## 🚀 How to Activate

### Quick Steps:
1. **Open MetaEditor** (F4 in MT5)
2. **Find the EA** in Navigator → Experts
3. **Compile** (F7)
4. **Attach to USDJPY M5 chart**
5. **Enable AutoTrading**

### Which to Use?

**Use Version 1 if:**
- You want to modify parameters easily
- You prefer organized code structure
- You might create variants

**Use Version 2 if:**
- You want simplicity
- You don't want to manage folders
- You want quick setup

---

## 📊 Core Folder Contents

The core folder contains these important tools:

1. **params_usdjpy.mqh** - USDJPY-optimized input parameters
2. **state.mqh** - State tracking (bias, bars, flags)
3. **utils.mqh** - Utility functions (pip conversion, normalization)
4. **trend_bias.mqh** - HTF trend detection logic
5. **entry_signal.mqh** - Complete entry signal building
6. **vol_filter.mqh** - Volatility and liquidity filtering
7. **risk.mqh** - Risk calculation and position sizing
8. **trade_mgmt.mqh** - Break-even and trailing stop management
9. **session.mqh** - Session filtering (London/NY)

**All these tools are:**
- ✅ Included in Version 1 (via core folder)
- ✅ Included in Version 2 (inline code)

---

## ✅ Current Status

- ✅ Version 1 created and copied
- ✅ Version 2 created and copied  
- ✅ Core folder copied to MT5
- ✅ USDJPY parameters optimized
- ✅ Both ready to compile

**Next Step**: Open MetaEditor and compile!

---

## 🔧 If You Need to Re-copy

### Version 1 Setup:
```bash
# Copy core folder
cp -r HybridTrendPullbackMT5/core "MT5/MQL5/Include/HybridTrendPullbackMT5/"

# Copy main EA
cp HybridTrendPullbackMT5/HybridTrendPullback_USDJPY.mq5 "MT5/MQL5/Experts/"
```

### Version 2 Setup:
```bash
# Just copy the one file
cp HybridTrendPullbackMT5/HybridTrendPullback_USDJPY_Standalone.mq5 "MT5/MQL5/Experts/"
```

---

**Both versions are ready! Choose the one that works best for you! 🚀**
