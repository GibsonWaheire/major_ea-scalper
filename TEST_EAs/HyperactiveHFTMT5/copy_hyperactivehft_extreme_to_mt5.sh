#!/bin/bash
# Script to copy HyperactiveHFT_Extreme EA to MT5 Experts directory

SOURCE_FILE="TEST_EAs/HyperactiveHFTMT5/HyperactiveHFT_Extreme.mq5"
EA_NAME="HyperactiveHFT_Extreme.mq5"

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$PROJECT_ROOT"

echo "Searching for MT5 Experts directory..."

# Check common MT5 paths
MT5_WINE_PATH="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
MT5_BASE="$HOME/Library/Application Support/MetaQuotes/Terminal"

# Check Wine path first (macOS)
if [ -d "$MT5_WINE_PATH" ]; then
  echo "Found MT5 Wine Experts directory: $MT5_WINE_PATH"
  if [ -w "$MT5_WINE_PATH" ]; then
    echo "Copying $EA_NAME to $MT5_WINE_PATH..."
    cp "$SOURCE_FILE" "$MT5_WINE_PATH/$EA_NAME"
    if [ $? -eq 0 ]; then
      echo "✓ Successfully copied to $MT5_WINE_PATH"
    else
      echo "✗ Failed to copy"
    fi
  else
    echo "  (No write permission, skipping)"
  fi
fi

# Check standard MT5 path
if [ -d "$MT5_BASE" ]; then
  echo "Found MT5 Terminal directory: $MT5_BASE"
  # Find all Experts directories
  find "$MT5_BASE" -type d -name "Experts" 2>/dev/null | while read experts_dir; do
    echo "Found Experts directory: $experts_dir"
    if [ -w "$experts_dir" ]; then
      echo "Copying $EA_NAME to $experts_dir..."
      cp "$SOURCE_FILE" "$experts_dir/$EA_NAME"
      if [ $? -eq 0 ]; then
        echo "✓ Successfully copied to $experts_dir"
      else
        echo "✗ Failed to copy"
      fi
    else
      echo "  (No write permission, skipping)"
    fi
  done
fi

# If neither found
if [ ! -d "$MT5_WINE_PATH" ] && [ ! -d "$MT5_BASE" ]; then
  echo "MT5 Experts directory not found in common locations."
  echo ""
  echo "Please provide your MT5 Experts directory path."
  echo "Common locations:"
  echo "  ~/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/"
  echo "  ~/Library/Application Support/MetaQuotes/Terminal/[TERMINAL_ID]/MQL5/Experts/"
fi






