#!/bin/bash

# Script to copy NAS100HybridSniperFlipper.mq5 to MetaTrader 5 Experts folder
# Usage: ./copy_nas100_sniper_to_mt5.sh

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Source file
SOURCE_FILE="NAS100HybridSniperFlipper/NAS100HybridSniperFlipper.mq5"

# Common MetaTrader 5 destination paths (macOS)
MT5_PATHS=(
    "$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
    "$HOME/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
    "$HOME/Library/Application Support/MetaQuotes/Terminal/*/MQL5/Experts"
)

echo "=========================================="
echo "NAS100 Hybrid Sniper Flipper - MetaTrader 5 Copy Script"
echo "=========================================="
echo ""

# Check if source file exists
if [ ! -f "$SOURCE_FILE" ]; then
    echo -e "${RED}ERROR: Source file not found: $SOURCE_FILE${NC}"
    echo "Please make sure you're running this script from the project root directory."
    exit 1
fi

# Find MetaTrader 5 directory
MT5_EXPERTS_DIR=""
for path in "${MT5_PATHS[@]}"; do
    # Handle wildcards
    for expanded_path in $path; do
        if [ -d "$expanded_path" ]; then
            MT5_EXPERTS_DIR="$expanded_path"
            break 2
        fi
    done
done

# If not found, try to find it
if [ -z "$MT5_EXPERTS_DIR" ]; then
    echo -e "${YELLOW}MetaTrader 5 Experts directory not found in common locations.${NC}"
    echo "Searching for MetaTrader 5 installation..."
    
    # Try to find MT5 directory
    MT5_EXPERTS_DIR=$(find "$HOME" -type d -path "*/MetaTrader 5/MQL5/Experts" 2>/dev/null | head -1)
    
    if [ -z "$MT5_EXPERTS_DIR" ]; then
        echo -e "${RED}ERROR: MetaTrader 5 Experts directory not found!${NC}"
        echo ""
        echo "Please manually copy the file:"
        echo "  From: $(pwd)/$SOURCE_FILE"
        echo "  To:   [Your MT5 Installation]/MQL5/Experts/NAS100HybridSniperFlipper.mq5"
        echo ""
        echo "Common locations:"
        for path in "${MT5_PATHS[@]}"; do
            echo "  - $path"
        done
        exit 1
    fi
fi

DEST_FILE="$MT5_EXPERTS_DIR/NAS100HybridSniperFlipper.mq5"

echo "Found MetaTrader 5 directory:"
echo "  $MT5_EXPERTS_DIR"
echo ""

# Create backup of existing file if it exists
if [ -f "$DEST_FILE" ]; then
    BACKUP_FILE="${DEST_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${YELLOW}Backing up existing file to: $BACKUP_FILE${NC}"
    cp "$DEST_FILE" "$BACKUP_FILE"
fi

# Copy the file
echo "Copying $SOURCE_FILE to MetaTrader 5..."
cp "$SOURCE_FILE" "$DEST_FILE"

# Check if copy was successful
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Successfully copied to MetaTrader 5!${NC}"
    echo ""
    echo "File location: $DEST_FILE"
    echo ""
    echo "Next steps:"
    echo "1. Open MetaTrader 5"
    echo "2. Press F4 to open MetaEditor"
    echo "3. Find 'NAS100HybridSniperFlipper.mq5' in the Navigator (under Experts)"
    echo "4. Press F7 to compile"
    echo "5. Drag the EA onto a NAS100 chart to use it"
    echo ""
    echo -e "${GREEN}Done!${NC}"
else
    echo -e "${RED}ERROR: Failed to copy file!${NC}"
    exit 1
fi




