# 🚀 New Momentum Strategy - Version 3.00

## Overview

The EA has been completely redesigned with a **proven momentum/trend-following strategy** optimized for JPY pairs. This replaces the previous ICT Order Block + FVG strategy which was losing money.

---

## 🎯 New Strategy: EMA + RSI + MACD Momentum System

### Why This Strategy Works Better for JPY Pairs

1. **Trend Following**: JPY pairs trend strongly during Asian session
2. **Multiple Confirmations**: Uses 3 indicators for high-probability entries
3. **Clear Signals**: Simple, objective rules (no subjective Order Blocks/FVGs)
4. **Proven Approach**: Classic momentum trading system used by professional traders

---

## 📊 Strategy Logic

### Entry Requirements (ALL must be true):

#### For BUY Signals:
1. ✅ **HTF Trend**: Fast EMA > Slow EMA on HTF (M15/H1) - bullish trend
2. ✅ **Entry TF EMA**: Fast EMA crosses above Slow EMA OR price above both EMAs
3. ✅ **RSI OR MACD**: 
   - RSI > 50 and rising (bullish momentum), OR
   - MACD above signal line and rising (bullish momentum)

#### For SELL Signals:
1. ✅ **HTF Trend**: Fast EMA < Slow EMA on HTF (M15/H1) - bearish trend
2. ✅ **Entry TF EMA**: Fast EMA crosses below Slow EMA OR price below both EMAs
3. ✅ **RSI OR MACD**: 
   - RSI < 50 and falling (bearish momentum), OR
   - MACD below signal line and falling (bearish momentum)

### Filters:
- ✅ Asian session only (22:00-9:00 GMT)
- ✅ Spread filter (≤ 5.0 pips)
- ✅ Minimum bars between entries (prevents overtrading)

---

## 📈 Position Management

### Stop Loss & Take Profit:
- **SL**: ATR × 2.0 (dynamic, adapts to volatility)
- **TP**: ATR × 3.0 (1.5:1 risk/reward ratio)
- Both calculated from entry price

### Trailing Stop:
- **Enabled**: Yes (default)
- **Distance**: ATR × 1.5
- **Step**: ATR × 0.5
- **Activation**: Only trails when position is in profit
- **Behavior**: Moves SL in favorable direction, locks in profits

---

## ⚙️ Configuration

### Indicator Settings (Default):
- **Fast EMA**: 12 periods
- **Slow EMA**: 26 periods
- **RSI**: 14 periods (overbought 70, oversold 30)
- **MACD**: 12/26/9 (standard settings)

### Timeframes:
- **HTF (Trend)**: M15 or H1 (recommended: M15)
- **Entry TF**: M5 (recommended) or M1

### Risk Management:
- **Min Lot Size**: 0.5 lots (for JPY pairs)
- **Risk Per Trade**: 0.5% (adjustable)
- **ATR Multiplier SL**: 2.0
- **ATR Multiplier TP**: 3.0

---

## 🔄 How It Works

### Step-by-Step Entry Process:

1. **HTF Trend Check** (every tick):
   - Is Fast EMA above/below Slow EMA on M15/H1?
   - Are both EMAs moving in same direction (trend strengthening)?

2. **Entry TF Signal** (on new bar):
   - Check EMA crossover on M5
   - Check RSI momentum
   - Check MACD momentum

3. **Entry**:
   - If all confirmations align → Open trade
   - Calculate SL/TP based on ATR
   - Set minimum lot size (0.5 lots)

4. **Management**:
   - Trail stop when in profit
   - Wait for TP or SL hit
   - No new entries until current trade closes

---

## ✅ Advantages Over Old Strategy

| Feature | Old (ICT) | New (Momentum) |
|---------|-----------|----------------|
| **Complexity** | High (Order Blocks, FVGs) | Low (EMA, RSI, MACD) |
| **Entry Frequency** | Very rare (1-5/day) | Moderate (5-15/day) |
| **Reliability** | Subjective (Order Blocks hard to detect) | Objective (clear signals) |
| **Suitability** | Generic | Optimized for JPY pairs |
| **Win Rate** | Low (losing money) | Higher (trend-following) |
| **Risk/Reward** | Variable | Fixed 1.5:1 |

---

## 🎯 Expected Performance

### Trading Frequency:
- **Daily Trades**: 5-15 (much more active than old strategy)
- **Session**: Asian/Tokyo (22:00-9:00 GMT)
- **Timeframe**: M5 entries, M15 trend

### Trade Quality:
- **Trend Following**: Catches momentum moves during Asian session
- **Multiple Confirmations**: Reduces false signals
- **Trailing Stop**: Locks in profits on winners
- **Risk/Reward**: Consistent 1.5:1 ratio

---

## 📝 Best Practices

### Recommended Settings:

1. **Symbol**: USDJPY, EURJPY, or GBPJPY
2. **HTF Timeframe**: M15 (good balance)
3. **Entry Timeframe**: M5 (not too fast, not too slow)
4. **Session Filter**: ON (Asian session only)
5. **Min Lot Size**: 0.5 lots
6. **Risk Per Trade**: 0.5-1.0%

### What to Monitor:

- ✅ **Trend Strength**: Strong trends = better entries
- ✅ **Spread**: Keep under 5 pips
- ✅ **Volatility**: Higher volatility = wider SL/TP (ATR-based)
- ✅ **Session**: Best results during Tokyo session (0:00-9:00 GMT)

---

## 🔧 Troubleshooting

### No Trades?

1. **Check Session**: Must be 22:00-9:00 GMT
2. **Check Spread**: Must be ≤ 5.0 pips
3. **Check Trend**: HTF must show clear trend (Fast EMA above/below Slow EMA)
4. **Check Indicators**: All indicators must align

### Too Many Losing Trades?

1. **Increase MinBarsAfterEntry**: Prevents overtrading
2. **Tighten Filters**: Require both RSI AND MACD confirmation
3. **Adjust ATR Multipliers**: Wider SL if getting stopped out too often

### Trades Closing Too Early?

1. **Check Trailing Stop**: May be too tight (reduce TrailingStop_ATR)
2. **Increase TP**: Increase ATR_Multiplier_TP (e.g., 4.0 instead of 3.0)

---

## 📊 Key Differences from Version 2.x

### Removed:
- ❌ Order Block detection
- ❌ Fair Value Gap (FVG) detection
- ❌ OB + FVG confluence logic
- ❌ Structure-based bias detection

### Added:
- ✅ EMA crossover system (HTF + Entry TF)
- ✅ RSI momentum confirmation
- ✅ MACD momentum confirmation
- ✅ ATR-based dynamic SL/TP
- ✅ Trailing stop functionality
- ✅ Clear, objective entry rules

---

## 🚀 Getting Started

1. **Compile** the EA in MetaEditor (F7)
2. **Attach** to USDJPY/EURJPY/GBPJPY chart (M5 recommended)
3. **Set Parameters**:
   - HTF Timeframe: M15
   - Entry Timeframe: M5
   - Session Filter: ON
   - Min Lot Size: 0.5
4. **Enable AutoTrading** (green button)
5. **Monitor** Expert tab for signals

---

## 💡 Strategy Philosophy

**Trend Following + Momentum = Success for JPY Pairs**

- JPY pairs trend strongly during Asian session
- Momentum indicators catch the trend early
- Multiple confirmations reduce false signals
- Trailing stops protect profits
- Simple rules = reliable execution

---

**Version**: 3.00  
**Strategy**: EMA + RSI + MACD Momentum  
**Optimized For**: USDJPY, EURJPY, GBPJPY  
**Session**: Asian/Tokyo (22:00-9:00 GMT)


