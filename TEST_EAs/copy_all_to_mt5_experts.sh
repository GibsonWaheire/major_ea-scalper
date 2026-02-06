#!/bin/bash

# Script to copy ALL MT5 EAs from TEST_EAs to MetaTrader 5 Experts folder
# EAs will appear individually in MT5 Experts list (not as folders)

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Source directory (TEST_EAs)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR"

# Common MetaTrader 5 destination paths (macOS)
MT5_PATHS=(
    "$HOME/Library/Application Support/MetaQuotes/Terminal/*/MQL5/Experts"
    "$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
    "$HOME/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
)

echo "=========================================="
echo "Copy ALL TEST_EAs to MT5 Experts (flat)"
echo "=========================================="
echo ""
echo "Source: $SOURCE_DIR"
echo ""

# Find MetaTrader 5 directory
MT5_EXPERTS_DIR=""
for path in "${MT5_PATHS[@]}"; do
    for expanded_path in $path; do
        if [ -d "$expanded_path" ]; then
            MT5_EXPERTS_DIR="$expanded_path"
            break 2
        fi
    done
done

if [ -z "$MT5_EXPERTS_DIR" ]; then
    echo -e "${YELLOW}MetaTrader 5 Experts directory not found in common locations.${NC}"
    MT5_EXPERTS_DIR=$(find "$HOME/Library" "$HOME/.wine" 2>/dev/null -type d -path "*/MQL5/Experts" 2>/dev/null | head -1)
fi

if [ -z "$MT5_EXPERTS_DIR" ]; then
    echo -e "${RED}ERROR: MetaTrader 5 Experts directory not found!${NC}"
    echo ""
    echo "Please find your MT5 data folder:"
    echo "1. Open MetaTrader 5"
    echo "2. File -> Open Data Folder"
    echo "3. Navigate to MQL5/Experts/"
    exit 1
fi

echo "Destination: $MT5_EXPERTS_DIR"
echo ""

# Find all .mq5 files recursively and copy (flatten to Experts root)
COPIED=0
SKIPPED=0
for file in $(find "$SOURCE_DIR" -type f -name "*.mq5" ! -path "*.backup*" 2>/dev/null); do
    filename=$(basename "$file")
    relpath="${file#$SOURCE_DIR/}"
    if cp "$file" "$MT5_EXPERTS_DIR/$filename" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $relpath"
        ((COPIED++))
    else
        echo -e "${RED}✗${NC} Failed: $relpath"
        ((SKIPPED++))
    fi
done

echo ""
echo -e "${GREEN}Done!${NC} Copied $COPIED EA(s) to MT5 Experts."
if [ $SKIPPED -gt 0 ]; then
    echo -e "${YELLOW}Skipped/Failed: $SKIPPED${NC}"
fi
echo ""
echo "Next steps:"
echo "1. Open MetaTrader 5"
echo "2. Press F4 to open MetaEditor"
echo "3. Refresh Navigator (F5) to see all EAs"
echo "4. Compile each EA (F7) as needed"
