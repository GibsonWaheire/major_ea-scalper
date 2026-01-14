#!/bin/bash

# Script to copy QuickScalperProV5.mq4 to MetaTrader 4 Experts folder
# Usage: ./copy_to_mt4.sh

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Source file
SOURCE_FILE="QuickScalperProV5/QuickScalperProV5.mq4"

# MetaTrader 4 destination
MT4_EXPERTS_DIR="$HOME/Library/Application Support/net.metaquotes.wine.metatrader4/drive_c/Program Files (x86)/MetaTrader 4/MQL4/Experts"
DEST_FILE="$MT4_EXPERTS_DIR/QuickScalperProV5.mq4"

echo "=========================================="
echo "QuickScalperProV5 - MetaTrader Copy Script"
echo "=========================================="
echo ""

# Check if source file exists
if [ ! -f "$SOURCE_FILE" ]; then
    echo -e "${RED}ERROR: Source file not found: $SOURCE_FILE${NC}"
    echo "Please make sure you're running this script from the project root directory."
    exit 1
fi

# Check if MetaTrader directory exists
if [ ! -d "$MT4_EXPERTS_DIR" ]; then
    echo -e "${RED}ERROR: MetaTrader 4 Experts directory not found!${NC}"
    echo "Expected location: $MT4_EXPERTS_DIR"
    echo ""
    echo "Please check:"
    echo "1. MetaTrader 4 is installed"
    echo "2. The path is correct for your installation"
    exit 1
fi

# Create backup of existing file if it exists
if [ -f "$DEST_FILE" ]; then
    BACKUP_FILE="${DEST_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${YELLOW}Backing up existing file to: $BACKUP_FILE${NC}"
    cp "$DEST_FILE" "$BACKUP_FILE"
fi

# Copy the file
echo "Copying $SOURCE_FILE to MetaTrader..."
cp "$SOURCE_FILE" "$DEST_FILE"

# Check if copy was successful
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Successfully copied to MetaTrader 4!${NC}"
    echo ""
    echo "File location: $DEST_FILE"
    echo ""
    echo "Next steps:"
    echo "1. Open MetaTrader 4"
    echo "2. Press F4 to open MetaEditor"
    echo "3. Find 'QuickScalperProV5.mq4' in the Navigator (under Experts)"
    echo "4. Press F7 to compile"
    echo "5. Drag the EA onto a chart to use it"
    echo ""
    echo -e "${GREEN}Done!${NC}"
else
    echo -e "${RED}ERROR: Failed to copy file!${NC}"
    exit 1
fi




