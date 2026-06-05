# VelocityBankScalper v2.0 — Build Plan
**Target**: High-frequency JPY scalper | 200–500 trades/day | 55–65% win rate | Net profitable

---

## WHY v1.10 FAILED
| Issue | Root Cause |
|---|---|
| Random entries | No trend filter — traded against trend constantly |
| 29% win rate | No confluence — single velocity signal, no confirmation |
| 4–44 min holds | Exit logic too loose — waited for big profits on tiny lots |
| Equity curve down | No edge — pure noise trading |

---

## ARCHITECTURE OVERVIEW

```
OnTick()
  |
  +-- [M1] PushSnapshot()          -- update tick ring-buffer all symbols
  |
  +-- [M1] ScanEntries()           -- per symbol entry pipeline:
  |         |
  |         +-- SessionFilter()    -- is it a tradeable session?
  |         +-- VolatilityCheck()  -- ATR in sweet spot?
  |         +-- TrendFilter()      -- M5 EMA8/21 + H1 EMA50 aligned?
  |         +-- MomentumFilter()   -- RSI 40-60 + candle momentum?
  |         +-- ConfluenceScore()  -- need 3 of 5 signals
  |         +-- CorrelationCheck() -- too many same-dir JPY open?
  |         +-- LotSize()          -- dynamic: % risk * ATR-adjust * streak
  |         +-- PlaceOrder()
  |
  +-- [M1] ManageExits()           -- per open position:
  |         |
  |         +-- EmergencyClose()   -- hard adverse pts limit
  |         +-- BreakEven()        -- move SL to entry once +1 spread profit
  |         +-- TrailingStop()     -- trail by 0.5 ATR once +2 ATR profit
  |         +-- PartialClose()     -- close 50% at 50% of target
  |         +-- TimeExit()         -- max hold time exceeded & < BE
  |         +-- VelocityReversal() -- momentum flipped against trade
  |         +-- ProfitTarget()     -- adaptive $ target based on ATR + vel tier
  |
  +-- [M1] RiskGuard()             -- account-level safety
  |         |
  |         +-- DrawdownCheck()    -- equity DD% limit
  |         +-- DailyLossLimit()   -- max $ loss per day
  |         +-- NewsGuard()        -- pause near high-impact time slots
  |
  +-- [M1] ShowPanel()             -- per-symbol dashboard
  |
  +-- [M1] PerformanceAdapt()      -- rolling win-rate per session/symbol
```

---

## MODULE SPECIFICATIONS

### MODULE 1 — Tick Velocity Engine (keep from v1.10, tune)
- Ring buffer: 60 snapshots per symbol
- Velocity = |price_change| / point / lookback
- Thresholds: STRONG=2.0 | MEDIUM=1.0 | WEAK=0.3 (lowered from v1.10)
- Direction: +1 up / -1 down / 0 flat
- **New**: secondary confirmation — last 3 snapshots all same direction

### MODULE 2 — Multi-Timeframe Trend Filter
```
H1  EMA50  -->  Bias  (bull = price > EMA50, bear = price < EMA50)
M5  EMA8   -->  Short-term trend direction
M5  EMA21  -->  Short-term trend confirmation (EMA8 > EMA21 = bull)
M1  EMA8   -->  Micro-trend (entry timing)

ENTRY ALLOWED only when:
  - H1 bias == entry direction  (or H1 filter disabled)
  - M5 EMA8/21 cross == entry direction
```
- Inputs: `UseH1Filter`, `UseM5Filter` (can disable for ranging markets)
- Uses `iMA()` handle system — handles initialized in `OnInit()`

### MODULE 3 — Momentum Filter (RSI)
- RSI(14) on M5 per symbol
- **BUY allowed**: RSI between 40–65 (momentum up, not overbought)
- **SELL allowed**: RSI between 35–60 (momentum down, not oversold)
- Filters out exhausted moves / reversal traps
- Inputs: `RsiLow=40`, `RsiHigh=65`

### MODULE 4 — Session Filter
```
Session         GMT range     Lot multiplier    Active
-----------------------------------------------------
Asian           00:00-07:00   0.5x              optional
London Open     07:00-09:00   1.5x              yes
London Core     09:00-12:00   1.0x              yes
NY Open         13:00-15:00   1.5x              yes
NY/London OL    13:00-16:00   2.0x              yes (best)
NY Afternoon    15:00-17:00   1.0x              yes
Dead Zone       20:00-23:59   0.0x              no
```
- Inputs: `TradeAsian`, `TradeLondon`, `TradeNY`, `TradeDeadZone`
- GMT offset auto-detected from broker server time

### MODULE 5 — Volatility Regime (ATR Filter)
- ATR(14) on M5 per symbol — updated every new M5 bar
- **Too quiet** (ATR < `AtrMin` pts): skip entries, spreads dominate
- **Too volatile** (ATR > `AtrMax` pts): skip entries, risk of spike loss
- Sweet spot for JPY pairs: ATR 5–45 pts
- Spread quality: reject if spread > `SpreadAtrPct`% of ATR

### MODULE 6 — Confluence Scoring
```
Score += 1  if tick velocity direction == entry direction
Score += 1  if M5 EMA8 > EMA21 (bull) or < (bear)
Score += 1  if H1 bias matches direction
Score += 1  if RSI in momentum zone
Score += 1  if last 3 M1 candles close in entry direction

ENTRY fires if Score >= InpMinConfluence (default 3)
```
- Inputs: `InpMinConfluence` = 2, 3, or 4 (tune aggressiveness)

### MODULE 7 — Correlation Manager
- All JPY pairs correlated (when USD strengthens, all JPY pairs move similar)
- Track: count of open BUY vs SELL across all JPY symbols
- Rule: max `InpMaxSameDir` (default 3) open positions same direction
- Rationale: prevents 6x leveraged bet on same underlying move

### MODULE 8 — Dynamic Lot Sizing
```
BaseLot = AccountBalance * InpRiskPct / 100
          / (ATR * InpAtrRiskMultiplier / SymbolPoint)
          / ContractSize

Adjustments:
  * SessionMultiplier   (per MODULE 4)
  * CorrelationFactor   (if >2 same-dir open: * 0.6)
  * StreakFactor        (3 losses: *0.7 | 5 losses: *0.5 | 3 wins: *1.2)
  * Max cap: InpMaxLot

Minimum: InpMinLot (0.10)
```

### MODULE 9 — Advanced Exit Engine
Priority order (checked per position per tick):

1. **Emergency close**: adverse points >= `InpEmergStopPts` → close immediately
2. **News guard close**: if news window opens while in trade → close if losing
3. **Break-even SL**: once profit >= 1x spread → set SL = open price + 0.5 spread
4. **Time exit**: held > `InpMaxHoldMin` minutes AND profit < break-even → close
5. **Partial close** (50%): once netProfit >= `InpPartialUSD` → close half, trail rest
6. **Trailing stop**: once in profit >= 2x ATR → trail SL by `InpTrailATR` * ATR
7. **Velocity reversal**: STRONG momentum flipped direction → close
8. **Profit target**: netProfit >= adaptive target (ATR-based, velocity-tiered)

Adaptive profit target:
```
target = ATR * InpProfitATR * LotSize * ContractSize * PointValue
       = roughly 0.3–1.5 ATR in dollar terms
```

### MODULE 10 — News / High-Impact Guard
- Hardcoded high-risk minute slots (GMT): 08:30, 09:00, 13:30, 14:00, 15:00, 18:00
- Window: no new entries from T-5min to T+10min around each slot
- If position open during news trigger AND losing: close immediately
- Inputs: `UseNewsGuard`, `NewsWindowMin`

### MODULE 11 — Performance Adaptation
```
struct SessionStats {
   int    trades;
   int    wins;
   double winRate;   // rolling 50-trade window
};
```
- Track per symbol × per session (Asian/London/NY)
- If winRate < 40% over last 50 trades in that session: halve lot size
- If winRate > 65%: allow 1.3x lot (up to MaxLot)
- Reset every `InpAdaptWindow` (default 50) trades

### MODULE 12 — Backtest Calibration Mode
- `MQL_TESTER` detected → bypass cooldown, bypass velocity filter
- Use ATR-direction as entry signal instead of tick velocity
- CopyTicks() used in live for real velocity; iMA/iRSI for backtest signals
- Log reason codes for every entry/exit to Journal

---

## INPUT PARAMETER GROUPS (planned)

```
===== Symbols =====
InpSymbols          = "USDJPY,GBPJPY,CADJPY,EURJPY,AUDJPY,NZDJPY"

===== Lot & Risk =====
InpRiskPct          = 0.5      // % of balance per trade
InpMinLot           = 0.10
InpMaxLot           = 5.00
InpAtrRiskMultiplier= 1.5      // SL width in ATR multiples

===== Trend Filter =====
UseH1Filter         = true
UseM5Filter         = true
InpH1EmaPeriod      = 50
InpM5FastEma        = 8
InpM5SlowEma        = 21

===== Momentum =====
InpRsiPeriod        = 14
InpRsiBullLow       = 40
InpRsiBullHigh      = 65
InpRsiBearLow       = 35
InpRsiBearHigh      = 60

===== Velocity =====
InpVelLookback      = 10
InpVelStrong        = 2.0
InpVelMedium        = 1.0
InpVelWeak          = 0.3

===== Confluence =====
InpMinConfluence    = 3        // signals needed out of 5

===== Session =====
TradeAsian          = false
TradeLondon         = true
TradeNY             = true
InpGmtOffset        = 0        // broker GMT offset (auto-detect attempt)

===== Volatility =====
InpAtrPeriod        = 14
InpAtrMin           = 3.0      // pts
InpAtrMax           = 50.0     // pts
InpSpreadAtrPct     = 20.0     // max spread as % of ATR

===== Exit =====
InpProfitATR        = 0.4      // target = 0.4 * ATR in dollar terms
InpPartialUSD       = 0.20     // partial close trigger
InpTrailATR         = 0.5      // trail distance in ATR multiples
InpMaxHoldMin       = 8        // time exit (minutes)
InpEmergStopPts     = 120.0

===== Correlation =====
InpMaxSameDir       = 3

===== Safety =====
InpMaxDrawdownPct   = 25.0
InpMaxDailyLossPct  = 5.0
InpMaxEmergStreak   = 5

===== Adaptation =====
InpAdaptWindow      = 50
UseNewsGuard        = true
NewsWindowMin       = 5

===== Debug =====
InpLogging          = true
InpLogLevel         = 1        // 0=errors only, 1=trades, 2=verbose
```

---

## FILE STRUCTURE
```
VelocityBankScalper_v2.mq5        -- main EA file
  OnInit()                         -- init handles, parse symbols
  OnDeinit()                       -- release handles
  OnTick()                         -- main loop
  OnTimer()                        -- performance stats update (1min)

  -- Modules (all in same file, separated by sections) --
  Section A: Structs & Globals
  Section B: Indicator Handle Manager
  Section C: Tick Velocity Engine
  Section D: Trend + Momentum Filters
  Section E: Session + Volatility Filter
  Section F: Confluence Scorer
  Section G: Lot Size Calculator
  Section H: Entry Engine
  Section I: Exit Engine (BE, trail, partial, time, target)
  Section J: Correlation Manager
  Section K: Risk Guard (DD, daily loss, news)
  Section L: Performance Adapter
  Section M: Display Panel
  Section N: Helpers & Utilities
```

---

## BUILD ORDER
1. Section A — Structs (SymState v2, SessionStats, IndicatorHandles)
2. Section B — Handle manager (iMA, iRSI, iATR init/release per symbol)
3. Section C — Tick velocity (port from v1.10, tune thresholds)
4. Section D — Trend filter (H1 EMA50, M5 EMA8/21, M1 EMA8)
5. Section E — Session + ATR volatility
6. Section F — Confluence scorer
7. Section G — Dynamic lot sizing
8. Section H — Entry engine (replaces TryEntry)
9. Section I — Exit engine (replaces ManageExits)
10. Section J — Correlation manager
11. Section K — Risk guard (extend from v1.10)
12. Section L — Performance adapter
13. Section M — Panel (extend from v1.10)
14. Section N — Helpers
15. OnInit / OnTick / OnDeinit wiring
16. Backtest calibration mode
17. Testing & parameter tuning

---

## SUCCESS CRITERIA (backtest targets)
- Win rate: >= 52%
- Profit factor: >= 1.4
- Max drawdown: < 15%
- Trades per day: >= 100 (M1 backtest)
- Average trade duration: < 5 minutes

---

## KNOWN RISKS / MITIGATIONS
| Risk | Mitigation |
|---|---|
| Over-optimisation / curve fitting | Test on out-of-sample period (different year) |
| JPY correlation blowup | Correlation manager caps same-dir positions |
| News spike loss | News guard + emergency stop |
| Spread widening | ATR-normalised spread filter |
| Backtest vs live gap | MQL_TESTER mode uses ATR signal, not tick velocity |
| iMA handle init failure | Fallback to simple price comparison if handle invalid |
