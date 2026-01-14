#!/bin/bash
# Copy PureMomentumScalperMT5 with Fundamental Analysis to MT5
# This script copies the EA and include file to your MT5 installation

# Default MT5 paths (adjust if your installation is different)
MT5_EXPERTS=""
MT5_INCLUDE=""

# Detect OS and set default paths
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    MT5_EXPERTS="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
    MT5_INCLUDE="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Include"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    MT5_EXPERTS="$HOME/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
    MT5_INCLUDE="$HOME/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Include"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
    # Windows
    MT5_EXPERTS="C:/Program Files/MetaTrader 5/MQL5/Experts"
    MT5_INCLUDE="C:/Program Files/MetaTrader 5/MQL5/Include"
fi

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "=========================================="
echo "PureMomentumScalperMT5 - Copy to MT5"
echo "=========================================="
echo ""

# Check if files exist
if [ ! -f "$SCRIPT_DIR/FinnhubEconomicCalendar.mqh" ]; then
    echo "❌ ERROR: FinnhubEconomicCalendar.mqh not found in $SCRIPT_DIR"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/PureMomentumScalperMT5_Fundamental.mq5" ]; then
    echo "❌ ERROR: PureMomentumScalperMT5_Fundamental.mq5 not found in $SCRIPT_DIR"
    exit 1
fi

# Check if MT5 directories exist
if [ ! -d "$MT5_EXPERTS" ]; then
    echo "⚠️  WARNING: MT5 Experts folder not found at: $MT5_EXPERTS"
    echo "Please enter your MT5 Experts folder path:"
    read -r MT5_EXPERTS
fi

if [ ! -d "$MT5_INCLUDE" ]; then
    echo "⚠️  WARNING: MT5 Include folder not found at: $MT5_INCLUDE"
    echo "Please enter your MT5 Include folder path:"
    read -r MT5_INCLUDE
fi

echo "📁 Copying files..."
echo ""

# Option A: Copy both to Experts folder (simplest)
echo "Using Option A: Copy both files to Experts folder"
echo ""

# Create Experts directory if it doesn't exist
mkdir -p "$MT5_EXPERTS"

# Copy EA file
echo "📄 Copying PureMomentumScalperMT5_Fundamental.mq5..."
cp "$SCRIPT_DIR/PureMomentumScalperMT5_Fundamental.mq5" "$MT5_EXPERTS/"
if [ $? -eq 0 ]; then
    echo "   ✅ Copied to: $MT5_EXPERTS/"
else
    echo "   ❌ Failed to copy EA file"
    exit 1
fi

# Copy include file to same directory
echo "📄 Copying FinnhubEconomicCalendar.mqh..."
cp "$SCRIPT_DIR/FinnhubEconomicCalendar.mqh" "$MT5_EXPERTS/"
if [ $? -eq 0 ]; then
    echo "   ✅ Copied to: $MT5_EXPERTS/"
else
    echo "   ❌ Failed to copy include file"
    exit 1
fi

echo ""
echo "=========================================="
echo "✅ Files copied successfully!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Open MetaTrader 5"
echo "2. Press F4 to open MetaEditor"
echo "3. Find 'PureMomentumScalperMT5_Fundamental.mq5' in Navigator"
echo "4. Press F7 to compile"
echo "5. Check for errors in Toolbox panel"
echo ""
echo "If you see include errors:"
echo "- Make sure both files are in the same folder (Experts)"
echo "- Or update the #include path in the EA file"
echo ""


