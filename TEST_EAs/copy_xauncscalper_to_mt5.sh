#!/bin/bash

# Script to copy XauNewCandleScalper.mq5 to MetaTrader 5 Experts folder
# Usage: ./copy_xauncscalper_to_mt5.sh

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SOURCE_FILE="XauNewCandleScalper.mq5"

MT5_PATHS=(
    "$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
    "$HOME/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
    "$HOME/Library/Application Support/MetaQuotes/Terminal/*/MQL5/Experts"
)

echo "=========================================="
echo "XauNewCandleScalper - MT5 Copy Script"
echo "=========================================="
echo ""

if [ ! -f "$SOURCE_FILE" ]; then
    echo -e "${RED}ERROR: Source file not found: $SOURCE_FILE${NC}"
    echo "Run this script from inside the TEST_EAs directory."
    exit 1
fi

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
    echo -e "${YELLOW}Searching for MetaTrader 5 installation...${NC}"
    MT5_EXPERTS_DIR=$(find "$HOME" -type d -path "*/MetaTrader 5/MQL5/Experts" 2>/dev/null | head -1)

    if [ -z "$MT5_EXPERTS_DIR" ]; then
        echo -e "${RED}ERROR: MetaTrader 5 Experts directory not found!${NC}"
        echo ""
        echo "Please manually copy the file:"
        echo "  From: $(pwd)/$SOURCE_FILE"
        echo "  To:   [Your MT5 Installation]/MQL5/Experts/XauNewCandleScalper.mq5"
        exit 1
    fi
fi

DEST_FILE="$MT5_EXPERTS_DIR/XauNewCandleScalper.mq5"

echo "Found MT5 Experts directory:"
echo "  $MT5_EXPERTS_DIR"
echo ""

if [ -f "$DEST_FILE" ]; then
    BACKUP_FILE="${DEST_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${YELLOW}Backing up existing file to: $BACKUP_FILE${NC}"
    cp "$DEST_FILE" "$BACKUP_FILE"
fi

cp "$SOURCE_FILE" "$DEST_FILE"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Successfully copied XauNewCandleScalper.mq5 to MT5!${NC}"
    echo ""
    echo "File location: $DEST_FILE"
    echo ""
    echo "Next steps:"
    echo "1. Open MetaTrader 5"
    echo "2. Press F4 to open MetaEditor"
    echo "3. Find 'XauNewCandleScalper' under Experts in the Navigator"
    echo "4. Press F7 to compile (0 errors expected)"
    echo "5. Drag onto a XAUUSD chart and configure inputs"
    echo ""
    echo -e "${GREEN}Done!${NC}"
else
    echo -e "${RED}ERROR: Failed to copy file!${NC}"
    exit 1
fi
