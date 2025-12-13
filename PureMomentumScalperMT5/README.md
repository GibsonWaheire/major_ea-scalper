# Pure Momentum Scalper - ICT Strategy for USDJPY

## 📋 Overview

This Expert Advisor implements a sophisticated ICT (Inner Circle Trader) strategy specifically optimized for **USDJPY**. It uses Higher Timeframe (HTF) bias, Order Blocks, and Fair Value Gaps (FVG) to identify high-probability trading opportunities.

### Key Features

- **HTF Bias Detection**: Only trades with the trend (M15 or H1)
- **Order Block + FVG Confluence**: Entry only when price retraces into Order Block overlapping with FVG
- **Liquidity-Based TP**: Targets previous highs/lows (institutional levels)
- **Session Filter**: Trades only during London (8-16 GMT) and NY (13-21 GMT) sessions
- **Spread Filter**: Blocks trades when spread exceeds 3.0 pips (USDJPY optimized)
- **Longer Holds**: Removed early exits - trades hold until TP is hit

---

## 🚀 Installation

### Step 1: Copy EA to MetaTrader 5

**Option A: Using the Copy Script (Recommended)**
```bash
cd /path/to/mt4-mt5-ea-collection
./copy_puremomentum_ict_to_mt5.sh
```

**Option B: Manual Copy**
1. Locate your MT5 installation folder:
   - **Windows**: `C:\Program Files\MetaTrader 5\MQL5\Experts\`
   - **macOS**: `~/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/`
2. Copy `PureMomentumScalperMT5.mq5` to the `Experts` folder

### Step 2: Compile in MetaEditor

1. Open **MetaTrader 5**
2. Press **F4** to open **MetaEditor**
3. In the **Navigator** panel (left side), find `PureMomentumScalperMT5.mq5` under **Experts**
4. Press **F7** to compile
5. Ensure you see **"0 errors, 0 warnings"** in the **Toolbox** panel

### Step 3: Attach to Chart

1. Open a **USDJPY** chart
2. Recommended timeframes: **M1** or **M5** (for entries)
3. Drag `PureMomentumScalperMT5` from the **Navigator** onto the chart
4. Configure settings (see Configuration below)
5. Enable **AutoTrading** (green button in toolbar)
6. Click **OK**

---

## ⚙️ Configuration

### ICT Strategy Settings

| Parameter | Default | Description |
|-----------|---------|-------------|
| **HTF_Timeframe** | M15 | Higher timeframe for bias detection (M15 or H1 recommended) |
| **EntryTimeframe** | M1 | Entry timeframe (M1 or M5 recommended) |
| **UseSessionFilter** | true | Trade only during London + NY sessions |
| **MaxSpreadPips** | 3.0 | Maximum spread filter (USDJPY optimized) |
| **MinRiskReward** | 2.0 | Minimum Risk/Reward ratio (1:2 minimum) |
| **UseLiquidityTP** | true | Use liquidity targets (previous highs/lows) |
| **UsePyramid** | false | Enable pyramid system (disabled for longer holds) |
| **LookbackBars** | 50 | Bars to look back for structure analysis |

### Risk Management

| Parameter | Default | Description |
|-----------|---------|-------------|
| **MagicNumber** | 202501 | Unique identifier for EA trades |
| **RiskPercent** | 0.5 | Risk % per trade (0.5% = conservative) |
| **MinLotSize** | 0.05 | Minimum lot size override |

### Pyramid Settings (if enabled)

| Parameter | Default | Description |
|-----------|---------|-------------|
| **P1** | 10 | Add position at 10 pips profit |
| **P2** | 20 | Add position at 20 pips profit |
| **P3** | 30 | Add position at 30 pips profit |
| **P4** | 40 | Add position at 40 pips profit |

---

## 📊 How It Works

### 1. HTF Bias Detection

The EA analyzes the **Higher Timeframe** (M15 or H1) to determine market bias:

- **Bullish Bias**: Price makes Higher High (HH) + Higher Low (HL)
- **Bearish Bias**: Price makes Lower High (LH) + Lower Low (LL)
- **No Bias**: No trade (EA waits for structure)

**Rule**: ❌ No bias = ❌ No trade

### 2. Order Block Detection

An **Order Block** is the last opposite candle before an impulsive move:

- **Bullish OB**: Last bearish candle before bullish impulse
- **Bearish OB**: Last bullish candle before bearish impulse

**Validation Requirements**:
- ✅ Impulse must break structure (BOS)
- ✅ Impulse must create a Fair Value Gap (FVG)
- ✅ OB must not be mitigated yet

### 3. Fair Value Gap (FVG) Detection

Uses **3-candle pattern** (ICT standard):

- **Bullish FVG**: Candle 1 high < Candle 3 low
- **Bearish FVG**: Candle 1 low > Candle 3 high

### 4. Entry Signal

Entry triggers when **ALL** conditions are met:

1. ✅ HTF bias confirmed (bullish or bearish)
2. ✅ Valid Order Block detected
3. ✅ FVG created by impulse
4. ✅ Price retraces into OB (50-100% of OB range)
5. ✅ OB overlaps with FVG zone
6. ✅ OB not mitigated
7. ✅ Session filter passed (London/NY only)
8. ✅ Spread filter passed (≤ 3.0 pips)

### 5. Stop Loss Placement

**SL = OB extreme ± ATR(1) × 0.2 + 3 pip buffer**

- **Buy trades**: SL below OB low
- **Sell trades**: SL above OB high

### 6. Take Profit Targets

**Primary**: Liquidity targets (previous highs/lows)
- Finds nearest resistance (for buys) or support (for sells)
- Ensures minimum 1:2 Risk/Reward ratio

**Fallback**: Fixed RR if liquidity target doesn't meet minimum RR

---

## 🎯 When to Exit

### Automatic Exits

The EA will **automatically exit** when:

1. **Take Profit Hit**: Price reaches liquidity target or fixed RR target
2. **Stop Loss Hit**: Price breaks through OB extreme (invalidates setup)

### Manual Exit Signals

Consider **manually closing** trades if:

#### ✅ **Good Exit Signals** (Take Profit):

- **Liquidity Hit**: Price reaches previous high/low (equal highs/lows)
- **RR Target Met**: Trade reaches minimum 1:2 RR (or your target)
- **Structure Break**: Price breaks opposite structure (reversal signal)

#### ⚠️ **Warning Signals** (Consider Partial Close):

- **OB Mitigation**: Order Block gets fully mitigated (price closes through OB)
- **FVG Fill**: Fair Value Gap gets completely filled
- **Opposite Bias**: HTF structure changes (HH+HL becomes LH+LL or vice versa)
- **Session End**: Approaching end of trading session (London/NY close)

#### ❌ **Emergency Exit Signals** (Close Immediately):

- **News Event**: High-impact USD or JPY news approaching
- **Spread Spike**: Spread widens significantly (> 5 pips)
- **Opposite Structure**: HTF clearly reverses (new opposite bias forms)

### Exit Strategy Recommendations

1. **Conservative**: Close at TP1 (1:1 RR), let runner go to liquidity
2. **Moderate**: Close 50% at 1:1 RR, let 50% run to liquidity
3. **Aggressive**: Hold full position to liquidity target (previous high/low)

---

## 📈 Important Information

### Best Trading Conditions

✅ **Optimal Setup**:
- London session (8-16 GMT) or NY session (13-21 GMT)
- Low spread (< 2.5 pips)
- Clear HTF structure (strong bias)
- Fresh Order Block (not old/mitigated)
- FVG clearly visible

❌ **Avoid Trading**:
- Asian session (low liquidity, ranging)
- High-impact news (USD/JPY releases)
- Wide spreads (> 3 pips)
- Unclear HTF structure
- Old/mitigated Order Blocks

### Performance Tips

1. **Monitor HTF Structure**: Check M15/H1 chart regularly for bias changes
2. **Watch for OB Mitigation**: If OB gets mitigated, consider closing
3. **Respect Liquidity Levels**: Previous highs/lows are key targets
4. **Session Awareness**: Best results during London/NY overlap (13-16 GMT)
5. **Spread Monitoring**: Avoid trading during news spikes

### Risk Management

- **Risk per Trade**: Start with 0.5% (conservative)
- **Maximum Risk**: Never risk more than 2% total account per day
- **Position Sizing**: EA calculates lot size based on SL distance
- **Pyramid System**: Disabled by default (recommended for longer holds)

### Troubleshooting

**EA Not Trading?**
- Check HTF bias (must have clear structure)
- Verify session filter (must be London/NY hours)
- Check spread (must be ≤ MaxSpreadPips)
- Ensure valid OB + FVG confluence exists

**Trades Closing Too Early?**
- Early exits are disabled - trades hold to TP
- If trade closes, it hit SL or TP automatically
- Check broker settings (no forced close rules)

**No Entry Signals?**
- Normal - EA waits for high-probability setups only
- Check HTF chart for clear bias
- Wait for price to retrace into OB + FVG zone

---

## 🔍 Strategy Logic Flow

```
1. Check Session Filter → If not London/NY, wait
2. Check Spread → If > MaxSpreadPips, wait
3. Detect HTF Bias → If no bias, wait
4. Detect Order Block → If no valid OB, wait
5. Detect FVG → If no FVG, wait
6. Check OB + FVG Confluence → If no overlap, wait
7. Check Price Retracement → If not in OB zone, wait
8. Check OB Mitigation → If mitigated, wait
9. ✅ ENTER TRADE
10. Place SL beyond OB extreme
11. Set TP at liquidity or fixed RR
12. Hold until TP or SL hit
```

---

## 📝 Example Trade Setup

### Bullish Setup Example:

1. **HTF (M15)**: Price makes HH + HL → **Bullish Bias** ✅
2. **Order Block**: Last bearish candle before bullish impulse detected
3. **FVG**: Bullish FVG created (C1 high < C3 low)
4. **Confluence**: OB overlaps with FVG zone
5. **Retracement**: Price pulls back into OB + FVG zone
6. **Entry**: BUY order placed
7. **SL**: Below OB low + buffer
8. **TP**: Previous high (liquidity) or 1:2 RR minimum

### Bearish Setup Example:

1. **HTF (M15)**: Price makes LH + LL → **Bearish Bias** ✅
2. **Order Block**: Last bullish candle before bearish impulse detected
3. **FVG**: Bearish FVG created (C1 low > C3 high)
4. **Confluence**: OB overlaps with FVG zone
5. **Retracement**: Price pulls back into OB + FVG zone
6. **Entry**: SELL order placed
7. **SL**: Above OB high + buffer
8. **TP**: Previous low (liquidity) or 1:2 RR minimum

---

## 🛠️ Support & Updates

For issues, questions, or feature requests, please refer to the main repository documentation.

**Version**: 2.00  
**Last Updated**: December 2025  
**Optimized For**: USDJPY (M1/M5 entries, M15/H1 bias)

---

## ⚠️ Disclaimer

This EA is for educational purposes. Trading forex involves substantial risk. Always test on a demo account first and never risk more than you can afford to lose. Past performance does not guarantee future results.

---

## 📚 Additional Resources

- **ICT Concepts**: Learn about Order Blocks, FVG, and HTF structure
- **USDJPY Characteristics**: Understand why this pair works well with ICT
- **Risk Management**: Always follow proper position sizing rules

**Happy Trading! 🚀**



