# TickPulse Scalper — MQL5 → MQL4 Conversion Progress

## Files Created This Session

| File | Status | Notes |
|---|---|---|
| `XauNewCandleScalper.mq5` | ✅ Complete | MT5 version — RSI + candle colour, dynamic trailing SL |
| `XauNewCandleScalper.mq4` | ✅ Complete v1.1 | MT4 port — relaxed RSI 45/55, doji filter, UseRSIFilter toggle |
| `copy_xauncscalper_to_mt5.sh` | ✅ Ready | Auto-copies to Wine MT5 Experts folder |
| `copy_xauncscalper_to_mt4.sh` | ✅ Ready | Auto-copies to Wine MT4 Experts folder |
| `TickPulseScalper_MT4_Framework.mq4` | ✅ Framework | Full MQL5→MQL4 conversion scaffold — see below |

---

## TickPulse Framework — What's Built

`TickPulseScalper_MT4_Framework.mq4` is the master conversion template.
It compiles clean in MT4 MetaEditor (`#property strict`).

### Sections inside the framework file

| Section | What it contains |
|---|---|
| **1** | Global memory layout — ring buffers, state machine, indicator cache |
| **2** | All `extern` input parameters |
| **3** | `OnInit` — caches `g_point`, `g_digits`, validates inputs |
| **4** | `OnDeinit` |
| **5** | `OnTick` — zero-lag critical path, calls all modules |
| **6** | **Tick-Pulse Engine** — `OnNewBar()`, `IsPulseArmed()`, `GetSignal()` |
| **7** | **Indicator Cache** — `RefreshIndicatorCache()` — all MQL5 handles → MQL4 inline |
| **8** | **Trading Engine** — `ExecuteTrade()`, `SendOrderWithRetry()` with ERR 146 + 135 |
| **9** | **Tight-Trace Trailing** — `TightTraceTrail()` — 1-2 pt trail, lock-in floor |
| **10** | Tick ring buffer — `PushTickToRing()`, `GetTickVelocity()` |
| **11** | Utilities — `IsNewBar()`, `HasOpenOrder()`, `IsTradingAllowed()` |
| **12** | Full MQL5→MQL4 cheat sheet (comments) |

---

## Strategy Logic

### Tick-Pulse Entry
1. On new bar open → capture `iOpen` → arm pulse state
2. Every tick: if price moves ±`InpPulseTrigger` points from open within `InpPulseMaxTicks` → fire
3. Direction confirmed by RSI + Bollinger Bands + ATR filter (all cached, zero OnTick lag)
4. Prevents re-entry for remainder of that candle (`g_pulse_state = 2`)

### Tight-Trace Trailing Stop
- Activates after `InpTrailActivate` points profit (default: 10 pts)
- Moves every `InpTrailStep` points (default: 1 pt — designed for XAUUSD HF)
- Lock-in floor: SL never falls below `entry + InpTrailLock` for buys
- Runs on **every tick** — first call in `OnTick()`

### Error Handling
| Error | Code | Fix Applied |
|---|---|---|
| Trade Context Busy | 146 | `Sleep(200ms)` + retry up to `InpMaxRetries` (default 3) |
| Off Quotes | 135 | `RefreshRates()` + fresh Ask/Bid on each retry loop |
| Invalid Stops | 130 | Log and abort — SL too close to market |

---

## Next Steps — Incremental Porting Plan

### Phase 2 (Next session — start here)
Paste your MQL5 global variable block into **Section 1** of the framework.

Rules:
- All arrays must be **file-scope** (global), never declared inside `OnTick()`
- Use `#define MY_BUF_SIZE 1000` for fixed sizes
- 32-bit MT4 stack = ~1MB. Each `double[10000]` = 80KB

### Phase 3 — Indicator Conversion Pattern
```mql4
// MQL5 (3 lines):
int h = iRSI(_Symbol, PERIOD_CURRENT, 14, PRICE_CLOSE);
double buf[1]; CopyBuffer(h, 0, 1, 1, buf);
double rsi = buf[0];

// MQL4 (1 line):
double rsi = iRSI(Symbol(), PERIOD_CURRENT, 14, PRICE_CLOSE, 1);
```

Common indicator conversions:
```mql4
// ATR
iATR(Symbol(), PERIOD_CURRENT, period, shift)

// Bollinger Bands (MODE_UPPER, MODE_LOWER, MODE_MAIN)
iBands(Symbol(), PERIOD_CURRENT, period, deviation, 0, PRICE_CLOSE, MODE_UPPER, shift)

// Moving Average
iMA(Symbol(), PERIOD_CURRENT, period, 0, MODE_EMA, PRICE_CLOSE, shift)

// Custom indicator
iCustom(Symbol(), PERIOD_CURRENT, "MyIndicatorName", param1, param2, buffer_index, shift)
```

### Phase 4 — CTrade → OrderSend Conversion
```mql4
// MQL5:
trade.Buy(lots, _Symbol, ask, sl, tp, "comment");

// MQL4:
OrderSend(Symbol(), OP_BUY, lots, ask, 30, sl, tp, "comment", magic, 0, clrBlue);
```

### Phase 5 — Split 13,000 lines into .mqh includes
```mql4
// Main .mq4 file stays lean:
#include "TickPulse_Indicators.mqh"
#include "TickPulse_TradeEngine.mqh"
#include "TickPulse_RiskManager.mqh"
#include "TickPulse_Patterns.mqh"
#include "TickPulse_Utils.mqh"
```

---

## MT4 Memory Rules (32-bit)

1. **Never** `ArrayResize()` inside `OnTick()` — use pre-allocated fixed arrays
2. **Never** declare `double bigArray[50000]` inside a function — declare at file scope
3. Keep `OnTick()` to pure logic reads — all heavy calc in `OnNewBar()`
4. Avoid `string` operations inside `OnTick()` — use integer state codes
5. Max safe global array: `double arr[100000]` = 800KB (under 1MB stack limit)

---

## MT4 Paths (this machine)

| Platform | Experts folder |
|---|---|
| MT4 (Wine) | `~/Library/Application Support/net.metaquotes.wine.metatrader4/drive_c/Program Files (x86)/MetaTrader 4/MQL4/Experts/` |
| MT5 (Wine) | `~/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/` |

---

## Backtesting Fix (Bars in test = 0)

MT4 Strategy Tester needs historical data:
1. **Tools → History Center** → XAUUSD → M1 → **Download**
2. Tester settings: Model = **Every tick**, Date range = last 3–6 months
3. Recompile EA first (**F7**) before running test
