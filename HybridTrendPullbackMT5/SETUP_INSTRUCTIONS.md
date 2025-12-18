# Hybrid Trend Pullback - USDJPY Setup Instructions

## 📦 Two Versions Available

### Version 1: `HybridTrendPullback_USDJPY.mq5` (Uses Core Folder)
- **File**: `HybridTrendPullback_USDJPY.mq5`
- **Structure**: Modular, uses core folder
- **Pros**: Better organized, easier to maintain
- **Requires**: Core folder with all .mqh files

### Version 2: `HybridTrendPullback_USDJPY_Standalone.mq5` (Standalone)
- **File**: `HybridTrendPullback_USDJPY_Standalone.mq5`
- **Structure**: All code in one file
- **Pros**: No dependencies, easy to copy
- **Requires**: Nothing - just the single file

---

## 🚀 Setup Option 1: Core Folder Version

### Step 1: Copy Core Folder to MT5 Include Directory

**On macOS:**
```bash
# Create the include directory structure
mkdir -p "/Users/apple/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Include/HybridTrendPullbackMT5/core"

# Copy all core files
cp HybridTrendPullbackMT5/core/*.mqh "/Users/apple/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Include/HybridTrendPullbackMT5/core/"
```

**Or manually:**
1. Navigate to: `MT5/MQL5/Include/`
2. Create folder: `HybridTrendPullbackMT5/`
3. Inside that, create folder: `core/`
4. Copy ALL `.mqh` files from `core/` folder into `MT5/MQL5/Include/HybridTrendPullbackMT5/core/`

### Step 2: Copy USDJPY-Optimized Params File

Copy `core/params_usdjpy.mqh` to the core folder in MT5.

### Step 3: Copy Main EA File

Copy `HybridTrendPullback_USDJPY.mq5` to `MT5/MQL5/Experts/`

### Step 4: Compile

1. Open MetaEditor (F4)
2. Find `HybridTrendPullback_USDJPY.mq5` in Experts
3. Press F7 to compile
4. Should compile successfully with core folder support

---

## 🚀 Setup Option 2: Standalone Version (Easier)

### Step 1: Copy Single File

Copy `HybridTrendPullback_USDJPY_Standalone.mq5` to `MT5/MQL5/Experts/`

### Step 2: Compile

1. Open MetaEditor (F4)
2. Find `HybridTrendPullback_USDJPY_Standalone.mq5` in Experts
3. Press F7 to compile
4. Should compile successfully (no dependencies)

---

## 📁 Required File Structure for Option 1

```
MT5/MQL5/
├── Experts/
│   └── HybridTrendPullback_USDJPY.mq5
└── Include/
    └── HybridTrendPullbackMT5/
        └── core/
            ├── params_usdjpy.mqh  (USDJPY optimized params)
            ├── params.mqh         (original - can keep both)
            ├── state.mqh
            ├── utils.mqh
            ├── trend_bias.mqh
            ├── entry_signal.mqh
            ├── vol_filter.mqh
            ├── risk.mqh
            ├── trade_mgmt.mqh
            └── session.mqh
```

---

## 📁 Required File Structure for Option 2

```
MT5/MQL5/
└── Experts/
    └── HybridTrendPullback_USDJPY_Standalone.mq5
```

---

## ✅ Which Version Should You Use?

### Use **Option 1 (Core Folder)** if:
- You want to modify parameters easily
- You prefer modular code structure
- You might want to create other variants
- You're comfortable with folder structures

### Use **Option 2 (Standalone)** if:
- You want simplicity (one file)
- You don't want to manage folders
- You just want to test/use it quickly
- You're sharing with others who might not have the core folder

---

## 🔧 Quick Setup Script (Option 1)

Run this from the project root:

```bash
cd /Users/apple/Desktop/sites/mt4-mt5-ea-collection

# Create directory structure
MT5_INCLUDE="/Users/apple/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Include/HybridTrendPullbackMT5/core"
MT5_EXPERTS="/Users/apple/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts"

mkdir -p "$MT5_INCLUDE"
mkdir -p "$MT5_EXPERTS"

# Copy core files
cp HybridTrendPullbackMT5/core/*.mqh "$MT5_INCLUDE/"
cp HybridTrendPullbackMT5/core/params_usdjpy.mqh "$MT5_INCLUDE/"

# Copy main EA
cp HybridTrendPullbackMT5/HybridTrendPullback_USDJPY.mq5 "$MT5_EXPERTS/"

echo "✓ Option 1 (Core Folder) setup complete!"
```

---

## 🔧 Quick Setup Script (Option 2)

```bash
cd /Users/apple/Desktop/sites/mt4-mt5-ea-collection

MT5_EXPERTS="/Users/apple/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts"

# Copy standalone EA
cp HybridTrendPullbackMT5/HybridTrendPullback_USDJPY_Standalone.mq5 "$MT5_EXPERTS/"

echo "✓ Option 2 (Standalone) setup complete!"
```

---

## 🎯 Next Steps After Setup

1. **Compile**: Press F7 in MetaEditor
2. **Attach to Chart**: Drag EA onto USDJPY M5 chart
3. **Configure**: Adjust parameters if needed
4. **Enable AutoTrading**: Click the green button
5. **Monitor**: Watch the EA trade

---

## ⚠️ Important Notes

- **Option 1** requires the core folder to be in the correct location
- **Option 2** is completely standalone - no dependencies
- Both versions have the same USDJPY-optimized parameters
- Both versions use the same trading logic
- Choose based on your preference for organization vs simplicity
