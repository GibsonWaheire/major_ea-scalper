#!/bin/bash

# Script to copy XauNewCandleScalper.mq4 to MetaTrader 4 Experts folder
# Usage: ./copy_xauncscalper_to_mt4.sh

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SOURCE_FILE="XauNewCandleScalper.mq4"

MT4_PATHS=(
    "$HOME/Library/Application Support/net.metaquotes.wine.metatrader4/drive_c/Program Files/MetaTrader 4/MQL4/Experts"
    "$HOME/.wine/drive_c/Program Files/MetaTrader 4/MQL4/Experts"
    "$HOME/Library/Application Support/MetaQuotes/Terminal/*/MQL4/Experts"
)

echo "=========================================="
echo "XauNewCandleScalper (MT4) - Copy Script"
echo "=========================================="
echo ""

if [ ! -f "$SOURCE_FILE" ]; then
    echo -e "${RED}ERROR: Source file not found: $SOURCE_FILE${NC}"
    echo "Run this script from inside the TEST_EAs directory."
    exit 1
fi

MT4_EXPERTS_DIR=""
for path in "${MT4_PATHS[@]}"; do
    for expanded_path in $path; do
        if [ -d "$expanded_path" ]; then
            MT4_EXPERTS_DIR="$expanded_path"
            break 2
        fi
    done
done

if [ -z "$MT4_EXPERTS_DIR" ]; then
    echo -e "${YELLOW}Searching for MetaTrader 4 installation...${NC}"
    MT4_EXPERTS_DIR=$(find "$HOME" -type d -path "*/MetaTrader 4/MQL4/Experts" 2>/dev/null | head -1)

    if [ -z "$MT4_EXPERTS_DIR" ]; then
        echo -e "${RED}ERROR: MetaTrader 4 Experts directory not found!${NC}"
        echo ""
        echo "Please manually copy the file:"
        echo "  From: $(pwd)/$SOURCE_FILE"
        echo "  To:   [Your MT4 Installation]/MQL4/Experts/XauNewCandleScalper.mq4"
        exit 1
    fi
fi

DEST_FILE="$MT4_EXPERTS_DIR/XauNewCandleScalper.mq4"

echo "Found MT4 Experts directory:"
echo "  $MT4_EXPERTS_DIR"
echo ""

if [ -f "$DEST_FILE" ]; then
    BACKUP_FILE="${DEST_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${YELLOW}Backing up existing file to: $BACKUP_FILE${NC}"
    cp "$DEST_FILE" "$BACKUP_FILE"
fi

cp "$SOURCE_FILE" "$DEST_FILE"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Successfully copied XauNewCandleScalper.mq4 to MT4!${NC}"
    echo ""
    echo "File location: $DEST_FILE"
    echo ""
    echo "Next steps:"
    echo "1. Open MetaTrader 4"
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
