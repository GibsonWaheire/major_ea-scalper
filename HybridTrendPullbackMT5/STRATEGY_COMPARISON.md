# Strategy Comparison: Original vs Standalone

## ✅ Strategy Logic is PRESERVED

The standalone version maintains **100% of the original trading strategy**. Only technical implementation details changed (MT4→MT5 function conversions).

---

## 📊 Original Strategy (From Core Files)

### 1. **Trend Bias Detection** (H1 Timeframe)
- Uses Fast EMA (21) vs Slow EMA (50) on H1
- **Bullish**: Fast EMA > Slow EMA
- **Bearish**: Fast EMA < Slow EMA
- Waits `InpMinBarsAfterFlip` bars after trend flip to avoid whipsaws

### 2. **Entry Signal** (M5 Timeframe)
- **Pullback Check**: Price must be within `pullbackAtrMult * ATR` of Entry EMA
- **Momentum Check**: Candle body ≥ `momentumAtrMult * ATR` AND range ≥ `momentumRangeAtrMult * ATR`
- **Direction Check**: Candle must align with trend (bullish candle for BUY, bearish for SELL)
- **All three must be true** to enter

### 3. **Risk Management**
- Stop Loss: `slAtrMult * ATR` (1.5x for USDJPY)
- Take Profit: `tpAtrMult * ATR` (3.0x for USDJPY = 1:2 RR)
- Volume: Fixed fractional risk (`riskPct` per trade)

### 4. **Position Management**
- Break-even: Moves SL to entry + buffer when RR ≥ `beRR`
- Trailing Stop: Activates when RR ≥ `trailStartRR`, trails by `trailStepPips` or `trailAtrMult * ATR`

### 5. **Filters**
- Volatility: ATR must be ≥ `minAtrToSpread * spread` AND ≤ `maxAtrPctOfPrice * price`
- Spread: Must be ≤ `maxSpreadPips`
- Session: Only trades during London/NY sessions

---

## 🔄 What Changed (Technical Only)

### ❌ Original Core Files Had Issues:
The original `core/entry_signal.mqh` uses **MT4 functions** that don't exist in MT5:
```mql5
double open  = iOpen(cfg.symbol, cfg.tf, 1);   // ❌ MT4 function
double close = iClose(cfg.symbol, cfg.tf, 1);  // ❌ MT4 function
double high  = iHigh(cfg.symbol, cfg.tf, 1);    // ❌ MT4 function
double low   = iLow(cfg.symbol, cfg.tf, 1);     // ❌ MT4 function
```

### ✅ Standalone Version Uses Correct MT5 Functions:
```mql5
double open[1], close[1], high[1], low[1];
CopyOpen(symbol, tf, shift, 1, open);   // ✅ MT5 function
CopyClose(symbol, tf, shift, 1, close); // ✅ MT5 function
CopyHigh(symbol, tf, shift, 1, high);   // ✅ MT5 function
CopyLow(symbol, tf, shift, 1, low);     // ✅ MT5 function
```

**This is the ONLY change** - the logic is identical, just using correct MT5 API.

---

## ✅ Strategy Logic Comparison

| Component | Original Core | Standalone | Match? |
|-----------|--------------|-----------|--------|
| Trend Detection | Fast EMA > Slow EMA (H1) | Fast EMA > Slow EMA (H1) | ✅ 100% |
| Pullback Entry | Price within ATR% of EMA | Price within ATR% of EMA | ✅ 100% |
| Momentum Filter | Body & Range vs ATR | Body & Range vs ATR | ✅ 100% |
| Direction Filter | Candle aligns with trend | Candle aligns with trend | ✅ 100% |
| Stop Loss | `slAtrMult * ATR` | `slAtrMult * ATR` | ✅ 100% |
| Take Profit | `tpAtrMult * ATR` | `tpAtrMult * ATR` | ✅ 100% |
| Break-Even | Moves at `beRR` | Moves at `beRR` | ✅ 100% |
| Trailing Stop | Trails at `trailStartRR` | Trails at `trailStartRR` | ✅ 100% |
| Volatility Filter | ATR vs spread & price | ATR vs spread & price | ✅ 100% |
| Session Filter | London/NY hours | London/NY hours | ✅ 100% |

---

## 🎯 Conclusion

**The strategy has NOT diverged.** The standalone version:
- ✅ Uses the **exact same entry logic**
- ✅ Uses the **exact same exit logic**
- ✅ Uses the **exact same filters**
- ✅ Uses the **exact same risk management**

**Only difference**: MT4 function calls → MT5 function calls (required for compilation)

The profitability potential is **identical** to the original. The standalone version is actually **more correct** because it uses proper MT5 functions instead of non-existent MT4 functions.

---

## ⚠️ Note About Original Core Files

The original `core/entry_signal.mqh` and `core/trend_bias.mqh` files contain MT4 functions (`iOpen`, `iClose`, `iHigh`, `iLow`) which **will not compile in MT5**. The standalone version fixes this while preserving all strategy logic.
