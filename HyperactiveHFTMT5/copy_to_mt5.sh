#!/bin/bash

# Script to copy EA to MetaTrader 5 Experts folder

SOURCE_FILE="HyperactiveHFTMT5_MSS_OB_FVG.mq5"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_PATH="$SCRIPT_DIR/$SOURCE_FILE"

# Try to find MT5 Experts folder
MT5_EXPERTS=""

# Method 1: Standard macOS location
if [ -d "$HOME/Library/Application Support/MetaQuotes/Terminal" ]; then
    for terminal_dir in "$HOME/Library/Application Support/MetaQuotes/Terminal"/*; do
        if [ -d "$terminal_dir/MQL5/Experts" ]; then
            MT5_EXPERTS="$terminal_dir/MQL5/Experts"
            break
        fi
    done
fi

# Method 2: Check common alternative locations
if [ -z "$MT5_EXPERTS" ]; then
    # Check if user has MT5 installed in Applications
    if [ -d "/Applications/MetaTrader 5.app" ]; then
        # MT5 data folder is usually in Library
        for terminal_dir in "$HOME/Library/Application Support/MetaQuotes/Terminal"/*; do
            if [ -d "$terminal_dir/MQL5/Experts" ]; then
                MT5_EXPERTS="$terminal_dir/MQL5/Experts"
                break
            fi
        done
    fi
fi

if [ -z "$MT5_EXPERTS" ]; then
    echo "ERROR: Could not find MetaTrader 5 Experts folder automatically."
    echo ""
    echo "Please find your MT5 data folder manually:"
    echo "1. Open MetaTrader 5"
    echo "2. Press Ctrl+Shift+D (or File -> Open Data Folder)"
    echo "3. Navigate to: MQL5/Experts/"
    echo "4. Copy the file manually:"
    echo "   cp \"$SOURCE_PATH\" \"[YOUR_MT5_DATA_FOLDER]/MQL5/Experts/\""
    echo ""
    echo "Or run this command with your MT5 path:"
    echo "   cp \"$SOURCE_PATH\" \"[PATH_TO_MT5_DATA]/MQL5/Experts/\""
    exit 1
fi

# Copy the file
if [ ! -f "$SOURCE_PATH" ]; then
    echo "ERROR: Source file not found: $SOURCE_PATH"
    exit 1
fi

echo "Found MT5 Experts folder: $MT5_EXPERTS"
echo "Copying $SOURCE_FILE..."
cp "$SOURCE_PATH" "$MT5_EXPERTS/"
if [ $? -eq 0 ]; then
    echo "SUCCESS: EA copied to $MT5_EXPERTS"
    echo ""
    echo "Next steps:"
    echo "1. Open MetaEditor in MT5"
    echo "2. Open the file: $MT5_EXPERTS/$SOURCE_FILE"
    echo "3. Press F7 to compile"
else
    echo "ERROR: Failed to copy file"
    exit 1
fi


