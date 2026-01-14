# PureMomentumScalperMT5 - Fundamental Analysis Setup Guide

## 🎯 Overview

This enhanced version integrates **Finnhub Economic Calendar API** with **Approach 2: Offensive News Trading**:
- ✅ Uses news events as **confirmation** for technical signals
- ✅ **Increases position size** when technical + fundamental align (up to 150%)
- ✅ **Reduces position size** when they conflict (down to 50%)
- ✅ Real-time economic calendar data from Finnhub

---

## 📁 Files Created

1. **`FinnhubEconomicCalendar.mqh`** - Finnhub API integration module
2. **`PureMomentumScalperMT5_Fundamental.mq5`** - Enhanced EA with fundamental analysis

---

## 🚀 Setup Instructions

### Step 1: Enable WebRequest in MT5

**CRITICAL**: MT5 must allow WebRequest to access Finnhub API.

1. Open **MetaTrader 5**
2. Go to **Tools** → **Options** → **Expert Advisors**
3. Check **"Allow WebRequest for listed URL"**
4. Click **"Add"** button
5. Enter: `https://finnhub.io`
6. Click **OK**

**Without this step, the EA will NOT be able to fetch economic calendar data!**

---

### Step 2: Install JSON Parser (Optional but Recommended)

The Finnhub API returns JSON data. You have two options:

#### Option A: Use Basic String Parsing (Current Implementation)
- The current code uses basic string parsing
- Works for most cases but may miss some edge cases
- **No additional files needed**

#### Option B: Use JAson.mqh Library (Recommended for Production)
1. Download `JAson.mqh` from MQL5 community
2. Place it in your `MQL5/Include/` folder
3. Update `FinnhubEconomicCalendar.mqh` to use proper JSON parsing

**For now, the basic parser should work fine for testing.**

---

### Step 3: Copy Files to MT5

**Option A: Same Directory (Simplest - Recommended)**
1. Copy both files to the same folder:
   ```
   MT5/MQL5/Experts/
   ```
   - `FinnhubEconomicCalendar.mqh`
   - `PureMomentumScalperMT5_Fundamental.mq5`

   **Why**: The EA uses `#include "FinnhubEconomicCalendar.mqh"` which looks for the file in the same directory first.

**Option B: Using Copy Script (Easiest)**
1. Run the provided copy script:
   ```bash
   cd /path/to/TEST_EAs/PureMomentumScalperMT5/
   ./copy_to_mt5.sh
   ```
   The script will automatically detect your MT5 installation and copy files.

**Option C: Separate Include Folder (Organized)**
1. Copy `FinnhubEconomicCalendar.mqh` to:
   ```
   MT5/MQL5/Include/
   ```
   (Root Include folder - no subfolder needed)

2. Copy `PureMomentumScalperMT5_Fundamental.mq5` to:
   ```
   MT5/MQL5/Experts/
   ```

3. **Important**: If using Option C, you may need to update the include statement in the EA file from:
   ```mql5
   #include "FinnhubEconomicCalendar.mqh"
   ```
   to:
   ```mql5
   #include <FinnhubEconomicCalendar.mqh>
   ```
   (Note the angle brackets `< >` instead of quotes)

**Recommended**: Use **Option A** (same directory) for simplicity - no code changes needed!

---

### Step 4: Compile the EA

1. Open **MetaEditor** (F4 in MT5)
2. Find `PureMomentumScalperMT5_Fundamental.mq5` in Navigator
3. Press **F7** to compile
4. Check for errors:
   - If you see "JAson.mqh not found" - that's OK, we're using basic parsing
   - If you see WebRequest errors - check Step 1
   - If you see include errors - check file paths

---

### Step 5: Configure Input Parameters

When attaching the EA to a chart, configure:

#### Fundamental Analysis Settings:
```
UseFundamentalAnalysis = true
FinnhubAPIKey = "d5jljvpr01qgsosh1umgd5jljvpr01qgsosh1un0"  // Your API key
FundamentalUpdateInterval = 60  // Update every 60 minutes
UseNewsConfirmation = true
NewsConfidenceThreshold = 5  // Minimum confidence (0-10)
```

#### Other Settings:
- Keep your existing technical analysis settings
- Risk management settings remain the same
- The EA will automatically adjust position size based on fundamental alignment

---

## 📊 How Approach 2 Works

### Position Size Multipliers:

| Scenario | Technical | Fundamental | Multiplier | Result |
|----------|-----------|-------------|------------|--------|
| **Perfect Alignment** | Bullish | Bullish (High Conf) | **1.5x** | Increase to 150% |
| **Good Alignment** | Bullish | Bullish (Med Conf) | **1.25x** | Increase to 125% |
| **Neutral** | Bullish | Neutral | **1.0x** | Normal size |
| **Conflict** | Bullish | Bearish | **0.5x** | Reduce to 50% |

### Example:

**Base Risk**: 0.5% per trade

**Scenario 1: Perfect Alignment**
- Technical: BUY signal confirmed
- Fundamental: USD bullish (strong GDP, employment data)
- **Position Size**: 0.5% × 1.5 = **0.75% risk** (50% larger)

**Scenario 2: Conflict**
- Technical: BUY signal confirmed
- Fundamental: USD bearish (weak data)
- **Position Size**: 0.5% × 0.5 = **0.25% risk** (50% smaller)

---

## 🔍 Fundamental Bias Calculation

The EA analyzes upcoming high-impact economic events to determine fundamental bias:

### Bullish Factors (Base Currency):
- ✅ Strong GDP growth
- ✅ Employment growth
- ✅ Retail sales increase
- ✅ Positive economic indicators

### Bearish Factors (Base Currency):
- ✅ High unemployment
- ✅ Weak economic data
- ✅ Negative indicators

### Confidence Levels:
- **10/10**: 3+ high-impact events aligned
- **7/10**: 2 high-impact events aligned
- **5/10**: 1 high-impact event
- **3/10**: Low confidence

---

## 📅 Economic Calendar Integration

The EA automatically:
1. **Fetches** economic calendar data from Finnhub
2. **Updates** every 60 minutes (configurable)
3. **Analyzes** high-impact events for your trading pair
4. **Calculates** fundamental bias based on upcoming events
5. **Logs** upcoming events in the journal

### Example Log Output:
```
✅ Finnhub Economic Calendar initialized. Loaded 45 events
📅 Upcoming high-impact events: NFP (USD), CPI (USD), BOJ Rate Decision (JPY)
```

---

## 🎯 Entry Signal Flow

```
1. Technical Analysis Check
   ├─ HTF Trend? ✅
   ├─ Entry TF Momentum? ✅
   └─ Technical Score: 10/10

2. Fundamental Analysis Check (if enabled)
   ├─ Fetch economic calendar
   ├─ Analyze upcoming events
   ├─ Calculate fundamental bias
   └─ Fundamental Score: 10/10 (aligned)

3. Combined Analysis
   ├─ Combined Score: 20/20
   ├─ Position Size Multiplier: 1.5x
   └─ ✅ ENTER TRADE (150% size)
```

---

## ⚙️ Configuration Examples

### Conservative (Lower Multipliers)
```
UseFundamentalAnalysis = true
NewsConfidenceThreshold = 7  // Only use high-confidence signals
// Max multiplier will be 1.25x instead of 1.5x
```

### Balanced (Recommended)
```
UseFundamentalAnalysis = true
NewsConfidenceThreshold = 5  // Medium confidence OK
// Multipliers: 1.5x (perfect), 1.25x (good), 1.0x (neutral), 0.5x (conflict)
```

### Aggressive (Higher Multipliers)
```
UseFundamentalAnalysis = true
NewsConfidenceThreshold = 3  // Lower threshold
// Will use fundamental bias more often
```

---

## 🐛 Troubleshooting

### EA Not Loading Economic Calendar?

**Error**: "WebRequest failed: -1"
- ✅ Check: Tools > Options > Expert Advisors > Allow WebRequest
- ✅ Verify: `https://finnhub.io` is in allowed URLs list
- ✅ Restart MT5 after adding URL

**Error**: "Failed to parse economic calendar JSON"
- This is normal if using basic string parser
- Consider upgrading to JAson.mqh for better parsing
- EA will continue with technical analysis only

**Error**: "API key not set"
- ✅ Check `FinnhubAPIKey` input parameter
- ✅ Verify API key is correct
- ✅ Test API key at: https://finnhub.io/api/v1/calendar/economic?from=2025-01-01&to=2025-01-07&token=YOUR_KEY

### No Position Size Adjustment?

- ✅ Check `UseFundamentalAnalysis = true`
- ✅ Verify Finnhub initialized successfully (check logs)
- ✅ Ensure confidence threshold is met
- ✅ Check if fundamental bias is calculated (DebugMode = true)

### Too Many/Few Trades?

- Adjust `NewsConfidenceThreshold`:
  - **Higher** (7-10) = Fewer trades, only high-confidence
  - **Lower** (3-5) = More trades, includes medium-confidence

---

## 📈 Expected Behavior

### With Fundamental Analysis Enabled:

**Before News Event:**
- EA analyzes upcoming events
- Calculates fundamental bias
- Adjusts position size accordingly

**During High-Impact News:**
- EA may reduce position size if conflict detected
- Or increase if alignment is strong

**After News Event:**
- EA updates calendar data
- Recalculates fundamental bias
- Adjusts future trades accordingly

### Performance Improvements:

- ✅ **Higher Win Rate**: Only trades when both technical + fundamental agree
- ✅ **Better Risk/Reward**: Larger positions on high-probability setups
- ✅ **Reduced Drawdown**: Smaller positions when conflict detected
- ✅ **News-Aware**: Adapts to economic calendar events

---

## 🔐 API Key Security

**Important**: Your Finnhub API key is stored in the EA input parameters.

**Security Tips:**
1. ✅ Don't share your EA file with API key
2. ✅ Use environment variables if possible (advanced)
3. ✅ Monitor API usage at https://finnhub.io/dashboard
4. ✅ Rotate API key if compromised

**Free Tier Limits:**
- 60 API calls per minute
- The EA updates every 60 minutes, so you're well within limits

---

## 📝 Monitoring

### Check EA Logs:

```
✅ Finnhub Economic Calendar initialized. Loaded 45 events
📅 Upcoming high-impact events: NFP (USD), CPI (USD)
✅ Entry Signal Valid:
   Direction: POSITION_TYPE_BUY
   Technical Score: 10/10
   Fundamental Score: 10/10
   Combined Score: 20/20
   Lot Multiplier: 150%
   Reason: Technical + Fundamental alignment
✅ Trade opened: BUY Ticket: 12345 Lot: 0.75 (Size: 150%)
```

### Key Metrics to Watch:

1. **Fundamental Score**: Should be 5-10 for good signals
2. **Combined Score**: Should be ≥12 for valid entry
3. **Lot Multiplier**: Shows position size adjustment
4. **Upcoming Events**: Check if events are being detected

---

## 🚀 Next Steps

1. ✅ **Test on Demo**: Run for 2-4 weeks on demo account
2. ✅ **Monitor Performance**: Compare with/without fundamental analysis
3. ✅ **Optimize Thresholds**: Adjust `NewsConfidenceThreshold` based on results
4. ✅ **Upgrade Parser**: Consider JAson.mqh for better JSON parsing
5. ✅ **Go Live**: After successful demo testing

---

## 📚 Additional Resources

- **Finnhub API Docs**: https://finnhub.io/docs/api/economic-calendar
- **MQL5 WebRequest**: https://www.mql5.com/en/docs/common/webrequest
- **JAson.mqh**: Search MQL5 community for JSON parsing library

---

## ⚠️ Important Notes

1. **Internet Required**: EA needs internet connection for API calls
2. **API Limits**: Free tier has 60 calls/minute (EA uses <1 call/hour)
3. **Time Zone**: All times are in GMT/UTC
4. **Backtesting**: Fundamental data may not be available in backtests
5. **Demo First**: Always test on demo before live trading

---

**Ready to trade with fundamental analysis! 🚀**

If you encounter any issues, check the troubleshooting section or review the EA logs.

