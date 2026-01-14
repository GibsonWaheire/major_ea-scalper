#!/bin/bash

# Script to copy VPS_only_MT4_EA_Hyper.mq4 to MetaTrader 4 Experts folder
# Usage: ./copy_hyperactive_v2_to_mt4.sh

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Source file
SOURCE_FILE="HyperactivePulseScalper/VPS_only_MT4_EA_Hyper.mq4"

# Common MetaTrader 4 destination paths (macOS)
MT4_PATHS=(
    "$HOME/Library/Application Support/net.metaquotes.wine.metatrader4/drive_c/Program Files (x86)/MetaTrader 4/MQL4/Experts"
    "$HOME/.wine/drive_c/Program Files (x86)/MetaTrader 4/MQL4/Experts"
    "$HOME/Library/Application Support/MetaQuotes/Terminal/*/MQL4/Experts"
)

echo "=========================================="
echo "VPS_only_MT4_EA_Hyper - MetaTrader 4 Copy Script"
echo "=========================================="
echo ""

# Check if source file exists
if [ ! -f "$SOURCE_FILE" ]; then
    echo -e "${RED}ERROR: Source file not found: $SOURCE_FILE${NC}"
    echo "Please make sure you're running this script from the project root directory."
    exit 1
fi

# Find MetaTrader 4 directory
MT4_EXPERTS_DIR=""
for path in "${MT4_PATHS[@]}"; do
    # Handle wildcards
    for expanded_path in $path; do
        if [ -d "$expanded_path" ]; then
            MT4_EXPERTS_DIR="$expanded_path"
            break 2
        fi
    done
done

# If not found, try to find it
if [ -z "$MT4_EXPERTS_DIR" ]; then
    echo -e "${YELLOW}MetaTrader 4 Experts directory not found in common locations.${NC}"
    echo "Searching for MetaTrader 4 installation..."
    
    # Try to find MT4 directory
    MT4_EXPERTS_DIR=$(find "$HOME" -type d -path "*/MetaTrader 4/MQL4/Experts" 2>/dev/null | head -1)
    
    if [ -z "$MT4_EXPERTS_DIR" ]; then
        echo -e "${RED}ERROR: MetaTrader 4 Experts directory not found!${NC}"
        echo ""
        echo "Please manually copy the file:"
        echo "  From: $(pwd)/$SOURCE_FILE"
        echo "  To:   [Your MT4 Installation]/MQL4/Experts/VPS_only_MT4_EA_Hyper.mq4"
        echo ""
        echo "Common locations:"
        for path in "${MT4_PATHS[@]}"; do
            echo "  - $path"
        done
        exit 1
    fi
fi

DEST_FILE="$MT4_EXPERTS_DIR/VPS_only_MT4_EA_Hyper.mq4"

echo "Found MetaTrader 4 directory:"
echo "  $MT4_EXPERTS_DIR"
echo ""

# Create backup of existing file if it exists
if [ -f "$DEST_FILE" ]; then
    BACKUP_FILE="${DEST_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${YELLOW}Backing up existing file to: $BACKUP_FILE${NC}"
    cp "$DEST_FILE" "$BACKUP_FILE"
fi

# Copy the file
echo "Copying $SOURCE_FILE to MetaTrader 4..."
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
    echo "3. Find 'VPS_only_MT4_EA_Hyper.mq4' in the Navigator (under Experts)"
    echo "4. Press F7 to compile"
    echo "5. Drag the EA onto a chart to use it"
    echo ""
    echo -e "${GREEN}Done!${NC}"
else
    echo -e "${RED}ERROR: Failed to copy file!${NC}"
    exit 1
fi
