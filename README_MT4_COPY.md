# How to Copy QuickScalperProV5 to MetaTrader 4

## Quick Start

### Method 1: Using the Script (Recommended)

1. **Open Terminal** (Applications > Utilities > Terminal)

2. **Navigate to the project directory:**
   ```bash
   cd ~/Desktop/sites/mt4-mt5-ea-collection
   ```

3. **Run the copy script:**
   ```bash
   ./copy_to_mt4.sh
   ```

4. **The script will:**
   - Check if the source file exists
   - Check if MetaTrader 4 is installed
   - Create a backup of existing file (if any)
   - Copy the EA to MetaTrader 4 Experts folder
   - Show you next steps

### Method 2: Manual Copy

1. **Open Finder** and navigate to:
   ```
   ~/Desktop/sites/mt4-mt5-ea-collection/QuickScalperProV5/
   ```

2. **Copy the file:** `QuickScalperProV5.mq4`

3. **Navigate to MetaTrader 4 Experts folder:**
   ```
   ~/Library/Application Support/net.metaquotes.wine.metatrader4/drive_c/Program Files (x86)/MetaTrader 4/MQL4/Experts/
   ```

4. **Paste the file** into the Experts folder

## After Copying

### Compile the EA in MetaEditor

1. **Open MetaTrader 4**

2. **Open MetaEditor:**
   - Press `F4` OR
   - Go to: Tools → MetaQuotes Language Editor

3. **Find the EA:**
   - In the Navigator panel (left side), expand "MQL4"
   - Expand "Experts"
   - Find `QuickScalperProV5.mq4`

4. **Compile:**
   - Press `F7` OR
   - Right-click the file → Compile OR
   - Click the Compile button in the toolbar

5. **Check for errors:**
   - Look at the Toolbox panel (bottom)
   - If there are errors, they will be shown in red
   - If compilation is successful, you'll see "0 errors, 0 warnings"

### Attach EA to Chart

1. **In MetaEditor Navigator:**
   - Find `QuickScalperProV5.mq4` under Experts
   - Drag it onto a chart in MetaTrader 4

2. **OR in MetaTrader 4:**
   - Go to: Navigator → Expert Advisors
   - Find `QuickScalperProV5`
   - Drag it onto a chart

3. **Configure settings:**
   - The EA settings window will open
   - Adjust parameters as needed
   - Click "OK" to start

## Troubleshooting

### Script says "Source file not found"
- Make sure you're in the project root directory
- Check that the file exists: `ls QuickScalperProV5/QuickScalperProV5.mq4`

### Script says "MetaTrader 4 Experts directory not found"
- Make sure MetaTrader 4 is installed
- The path might be different for your installation
- Check: `~/Library/Application Support/net.metaquotes.wine.metatrader4/`

### Compilation Errors
- Make sure you're using MetaTrader 4 (not MT5)
- Check that all required files are present
- Look at the error messages in the Toolbox panel

### EA doesn't appear in Navigator
- Make sure the file is in the correct folder: `MQL4/Experts/`
- Restart MetaEditor (close and reopen)
- Make sure the file extension is `.mq4` (not `.mq5`)

## Features of QuickScalperProV5

- **Strict 3-Trade Basket Limit**: Maximum 3 active trades per basket
- **Broker-Safe Mode**: Prevents hyper-activity violations
- **Adaptive Profit Engine**: Dynamic profit targets
- **Pattern Recovery**: Smart recovery after losses
- **Exposure Governor**: Risk management
- **Guardrails**: Daily loss/profit limits

## File Locations

- **Source:** `~/Desktop/sites/mt4-mt5-ea-collection/QuickScalperProV5/QuickScalperProV5.mq4`
- **Destination:** `~/Library/Application Support/net.metaquotes.wine.metatrader4/drive_c/Program Files (x86)/MetaTrader 4/MQL4/Experts/QuickScalperProV5.mq4`




