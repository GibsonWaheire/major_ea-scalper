//+------------------------------------------------------------------+
//| VelocityBankScalper v2.0                                         |
//| Multi-pair JPY scalper | Confluence entry | Smart exits           |
//| Modules: Velocity + MTF Trend + RSI + Session + ATR + Correlation|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, VelocityBankScalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "2.00"
#property description "VelocityBankScalper v2.0 — MTF confluence scalper"
#property description "JPY pairs | Dynamic lots | Smart exits | Session-aware"

#include <Trade/Trade.mqh>
CTrade trade;

//=============================================================================
// SECTION A — INPUTS
//=============================================================================

input group "===== Symbols ====="
input string InpSymbols         = "USDJPY,GBPJPY,CADJPY,EURJPY,AUDJPY,NZDJPY";

input group "===== Lot & Risk ====="
input double InpRiskPct         = 0.5;    // % of balance risked per trade
input double InpMinLot          = 0.10;   // Minimum lot size
input double InpMaxLot          = 5.00;   // Maximum lot size
input double InpAtrRiskMult     = 1.5;    // SL width = ATR * this multiplier

input group "===== Trend Filter ====="
input bool   UseH1Filter        = true;   // Require H1 EMA50 bias alignment
input bool   UseM5Filter        = true;   // Require M5 EMA8/21 cross alignment
input int    InpH1EmaPeriod     = 50;     // H1 EMA period for bias
input int    InpM5FastEma       = 8;      // M5 fast EMA
input int    InpM5SlowEma       = 21;     // M5 slow EMA
input int    InpM1FastEma       = 8;      // M1 micro-trend EMA

input group "===== Momentum (RSI) ====="
input int    InpRsiPeriod       = 14;
input double InpRsiBullLow      = 40.0;   // BUY: RSI must be above this
input double InpRsiBullHigh     = 65.0;   // BUY: RSI must be below this
input double InpRsiBearLow      = 35.0;   // SELL: RSI must be above this
input double InpRsiBearHigh     = 60.0;   // SELL: RSI must be below this

input group "===== Tick Velocity ====="
input int    InpVelLookback     = 10;     // Snapshot depth for velocity
input double InpVelStrong       = 2.0;    // pts/snap -> STRONG
input double InpVelMedium       = 1.0;    // pts/snap -> MEDIUM
input double InpVelWeak         = 0.1;    // pts/snap -> WEAK

input group "===== Confluence ====="
input int    InpMinConfluence   = 3;      // Signals needed out of 5 to enter

input group "===== Session (GMT) ====="
input bool   TradeAsian         = false;  // 00:00-07:00 GMT
input bool   TradeLondon        = true;   // 07:00-17:00 GMT
input bool   TradeNY            = true;   // 13:00-21:00 GMT
input int    InpGmtOffset       = 0;      // Broker server GMT offset (hours)

input group "===== Volatility (ATR) ====="
input int    InpAtrPeriod       = 14;
input double InpAtrMin          = 3.0;    // Minimum ATR in points to trade
input double InpAtrMax          = 60.0;   // Maximum ATR in points (avoid spikes)
input double InpSpreadAtrPct    = 200.0;  // Max spread as % of ATR (200 = 2x ATR)

input group "===== Exit ====="
input double InpProfitATR       = 0.35;   // Profit target = ATR * this (in $)
input double InpPartialUSD      = 0.15;   // Partial close (50%) trigger in $
input double InpTrailAtr        = 0.50;   // Trailing stop distance in ATR units
input int    InpMaxHoldMin      = 10;     // Max hold time (minutes) before time-exit
input double InpEmergStopPts    = 120.0;  // Hard emergency stop in points
input int    InpCooldownSec     = 1;      // Min seconds between entries per symbol

input group "===== Correlation ====="
input int    InpMaxSameDir      = 3;      // Max same-direction positions across all JPY

input group "===== Safety ====="
input double InpMaxDrawdownPct  = 25.0;   // Account equity DD% -> stop all
input double InpMaxDailyLossPct = 5.0;    // Daily loss % of balance -> stop
input int    InpMaxEmergStreak  = 5;      // Consecutive emergency closes -> pause

input group "===== News Guard ====="
input bool   UseNewsGuard       = true;   // Pause near high-impact GMT times
input int    InpNewsBefore      = 5;      // Minutes before news to pause
input int    InpNewsAfter       = 10;     // Minutes after news to resume

input group "===== Performance Adaptation ====="
input int    InpAdaptWindow     = 50;     // Rolling trade window for win-rate adapt

input group "===== Debug ====="
input bool   InpLogging         = true;
input int    InpLogLevel        = 1;      // 0=errors 1=trades 2=verbose

//=============================================================================
// SECTION B — STRUCTS & DEFINES
//=============================================================================

#define MAGIC    20260605
#define BUFLEN   60
#define MAXSYM   16

enum EVel  { VEL_FLAT=0, VEL_WEAK=1, VEL_MEDIUM=2, VEL_STRONG=3 };
enum ESess { SESS_DEAD=0, SESS_ASIAN=1, SESS_LONDON=2, SESS_NY=3, SESS_OVERLAP=4 };

struct IndicatorHandles
{
   int h1_ema50;
   int m5_ema_fast;
   int m5_ema_slow;
   int m1_ema_fast;
   int m5_rsi;
   int m5_atr;
};

struct SessionStats
{
   int    trades;
   int    wins;
   double totalPnl;
   // rolling window (last InpAdaptWindow)
   int    wBuf[50];   // 0=loss, 1=win
   int    wIdx;
   int    wCount;
};

struct SymState
{
   // Identity
   string sym;
   string base;
   double pt;
   int    digits;
   bool   valid;

   // Tick velocity ring-buffer
   double   mid[BUFLEN];
   int      filled;
   datetime lastEntry;

   // Indicator handles
   IndicatorHandles ind;

   // Cached indicator values (updated each OnTick)
   double h1Ema50;
   double m5EmaFast;
   double m5EmaSlow;
   double m1EmaFast;
   double m5Rsi;
   double m5Atr;      // in points

   // Performance adaptation
   SessionStats stats[5];  // indexed by ESess
   double lotMultiplier;   // adapts 0.5–1.3 based on recent win rate

   // State
   int  emergStreak;
   bool paused;
};

SymState g_sym[MAXSYM];
int      g_symCount   = 0;

double   g_startBal   = 0.0;
double   g_dayStartBal= 0.0;
bool     g_stopped    = false;
datetime g_lastDay    = 0;

// High-impact GMT news minutes (hour*60+min)
int g_newsTimes[] = {
   510,   // 08:30
   540,   // 09:00
   810,   // 13:30
   840,   // 14:00
   900,   // 15:00
   960,   // 16:00
   1080   // 18:00
};

//=============================================================================
// SECTION C — INIT / DEINIT
//=============================================================================

int OnInit()
{
   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(50);

   g_symCount    = 0;
   g_startBal    = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayStartBal = g_startBal;
   g_stopped     = false;

   string parts[];
   int n = StringSplit(InpSymbols, ',', parts);

   for(int i = 0; i < n && g_symCount < MAXSYM; i++)
   {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      if(StringLen(parts[i]) == 0) continue;

      string resolved = FindSymbol(parts[i]);
      if(resolved == "")
      {
         Print("WARNING: '", parts[i], "' not found — skipped.");
         continue;
      }

      SymbolSelect(resolved, true);

      int si = g_symCount;  // index alias — avoids illegal &ref-to-array-element
      g_sym[si].base    = parts[i];
      g_sym[si].sym     = resolved;
      g_sym[si].pt      = SymbolInfoDouble(resolved, SYMBOL_POINT);
      g_sym[si].digits  = (int)SymbolInfoInteger(resolved, SYMBOL_DIGITS);
      g_sym[si].valid   = true;
      g_sym[si].filled  = 0;
      g_sym[si].lastEntry = 0;
      g_sym[si].lotMultiplier = 1.0;
      g_sym[si].emergStreak   = 0;
      g_sym[si].paused        = false;
      ArrayInitialize(g_sym[si].mid, 0.0);

      // Init indicator handles
      if(!InitHandles(g_sym[si]))
      {
         Print("WARNING: indicator handles failed for ", resolved, " — skipped.");
         g_sym[si].valid = false;
         g_symCount++;
         continue;
      }

      // Init session stats
      for(int j = 0; j < 5; j++)
      {
         g_sym[si].stats[j].trades = 0;
         g_sym[si].stats[j].wins   = 0;
         g_sym[si].stats[j].totalPnl = 0;
         g_sym[si].stats[j].wIdx   = 0;
         g_sym[si].stats[j].wCount = 0;
         ArrayInitialize(g_sym[si].stats[j].wBuf, 0);
      }

      SetFilling(resolved);

      Print("Loaded: ", parts[i], " -> ", resolved,
            "  pt=", g_sym[si].pt, "  digits=", g_sym[si].digits);
      g_symCount++;
   }

   if(g_symCount == 0)
   {
      Alert("VelocityBankScalper v2: No valid symbols. Check InpSymbols.");
      return INIT_FAILED;
   }

   EventSetTimer(60); // 1-min timer for performance adaptation

   PrintParams();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   for(int i = 0; i < g_symCount; i++)
      ReleaseHandles(g_sym[i]);
   EventKillTimer();
   Comment("");
}

void OnTimer()
{
   // Refresh day start balance
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   MqlDateTime dl;
   TimeToStruct(g_lastDay, dl);
   if(dt.day != dl.day)
   {
      g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
      g_lastDay     = now;
   }
}

//=============================================================================
// SECTION D — INDICATOR HANDLE MANAGER
//=============================================================================

bool InitHandles(SymState &s)
{
   s.ind.h1_ema50    = iMA(s.sym, PERIOD_H1, InpH1EmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   s.ind.m5_ema_fast = iMA(s.sym, PERIOD_M5, InpM5FastEma,   0, MODE_EMA, PRICE_CLOSE);
   s.ind.m5_ema_slow = iMA(s.sym, PERIOD_M5, InpM5SlowEma,   0, MODE_EMA, PRICE_CLOSE);
   s.ind.m1_ema_fast = iMA(s.sym, PERIOD_M1, InpM1FastEma,   0, MODE_EMA, PRICE_CLOSE);
   s.ind.m5_rsi      = iRSI(s.sym, PERIOD_M5, InpRsiPeriod, PRICE_CLOSE);
   s.ind.m5_atr      = iATR(s.sym, PERIOD_M5, InpAtrPeriod);

   if(s.ind.h1_ema50    == INVALID_HANDLE) return false;
   if(s.ind.m5_ema_fast == INVALID_HANDLE) return false;
   if(s.ind.m5_ema_slow == INVALID_HANDLE) return false;
   if(s.ind.m1_ema_fast == INVALID_HANDLE) return false;
   if(s.ind.m5_rsi      == INVALID_HANDLE) return false;
   if(s.ind.m5_atr      == INVALID_HANDLE) return false;
   return true;
}

void ReleaseHandles(SymState &s)
{
   if(s.ind.h1_ema50    != INVALID_HANDLE) IndicatorRelease(s.ind.h1_ema50);
   if(s.ind.m5_ema_fast != INVALID_HANDLE) IndicatorRelease(s.ind.m5_ema_fast);
   if(s.ind.m5_ema_slow != INVALID_HANDLE) IndicatorRelease(s.ind.m5_ema_slow);
   if(s.ind.m1_ema_fast != INVALID_HANDLE) IndicatorRelease(s.ind.m1_ema_fast);
   if(s.ind.m5_rsi      != INVALID_HANDLE) IndicatorRelease(s.ind.m5_rsi);
   if(s.ind.m5_atr      != INVALID_HANDLE) IndicatorRelease(s.ind.m5_atr);
}

bool RefreshIndicators(SymState &s)
{
   double buf[2];

   if(CopyBuffer(s.ind.h1_ema50, 0, 0, 2, buf) < 2)    return false;
   s.h1Ema50 = buf[0];

   if(CopyBuffer(s.ind.m5_ema_fast, 0, 0, 2, buf) < 2)  return false;
   s.m5EmaFast = buf[0];

   if(CopyBuffer(s.ind.m5_ema_slow, 0, 0, 2, buf) < 2)  return false;
   s.m5EmaSlow = buf[0];

   if(CopyBuffer(s.ind.m1_ema_fast, 0, 0, 2, buf) < 2)  return false;
   s.m1EmaFast = buf[0];

   if(CopyBuffer(s.ind.m5_rsi, 0, 0, 2, buf) < 2)       return false;
   s.m5Rsi = buf[0];

   if(CopyBuffer(s.ind.m5_atr, 0, 0, 2, buf) < 2)       return false;
   s.m5Atr = buf[0] / s.pt;  // convert price to points

   return true;
}

//=============================================================================
// SECTION E — MAIN TICK
//=============================================================================

void OnTick()
{
   bool inTester = (bool)MQLInfoInteger(MQL_TESTER);

   // Refresh per-symbol indicators + velocity snapshots
   for(int i = 0; i < g_symCount; i++)
   {
      if(!g_sym[i].valid) continue;
      PushSnapshot(g_sym[i]);
      RefreshIndicators(g_sym[i]);
   }

   if(g_stopped) { ShowPanel(); return; }
   if(CheckAccountGuard()) { ShowPanel(); return; }

   ManageExits(inTester);

   if(!InNewsWindow())
   {
      for(int i = 0; i < g_symCount; i++)
      {
         if(g_sym[i].valid && !g_sym[i].paused)
            TryEntry(g_sym[i], inTester);
      }
   }

   ShowPanel();
}

//=============================================================================
// SECTION F — TICK VELOCITY ENGINE
//=============================================================================

void PushSnapshot(SymState &s)
{
   MqlTick tk;
   if(!SymbolInfoTick(s.sym, tk)) return;
   double mid = (tk.bid + tk.ask) * 0.5;
   // Only record when price actually changed — prevents chart-symbol ticks
   // from flooding non-chart symbols' buffers with stale prices (dir=0 bug).
   if(s.filled > 0 && mid == s.mid[0]) return;
   for(int i = BUFLEN - 1; i > 0; i--)
      s.mid[i] = s.mid[i-1];
   s.mid[0] = mid;
   if(s.filled < BUFLEN) s.filled++;
}

EVel CalcVel(SymState &s, double &ptsPerSnap, int &dir)
{
   ptsPerSnap = 0.0;
   dir        = 0;
   if(s.filled < InpVelLookback) return VEL_FLAT;

   double oldest = s.mid[InpVelLookback - 1];
   double newest = s.mid[0];
   double chg    = newest - oldest;

   ptsPerSnap = MathAbs(chg) / s.pt / InpVelLookback;
   // Require >= 1 point net movement before assigning direction.
   dir = (chg > s.pt) ? 1 : (chg < -s.pt ? -1 : 0);

   if(ptsPerSnap >= InpVelStrong) return VEL_STRONG;
   if(ptsPerSnap >= InpVelMedium) return VEL_MEDIUM;
   if(ptsPerSnap >= InpVelWeak)   return VEL_WEAK;
   return VEL_FLAT;
}

// Check last N snapshots all same direction (momentum consistency)
bool VelConsistent(SymState &s, int reqDir, int lookN = 3)
{
   if(s.filled < lookN + 1) return false;
   for(int i = 0; i < lookN; i++)
   {
      double d = s.mid[i] - s.mid[i+1];
      int    di = (d > 0) ? 1 : (d < 0 ? -1 : 0);
      if(di != reqDir) return false;
   }
   return true;
}

//=============================================================================
// SECTION G — TREND FILTER (MTF)
//=============================================================================

// Returns +1 bull, -1 bear, 0 neutral for H1 bias
int H1Bias(SymState &s)
{
   if(!UseH1Filter) return 0; // neutral = don't filter
   MqlTick tk;
   if(!SymbolInfoTick(s.sym, tk)) return 0;
   double mid = (tk.bid + tk.ask) * 0.5;
   if(mid > s.h1Ema50 * 1.0001) return  1;
   if(mid < s.h1Ema50 * 0.9999) return -1;
   return 0;
}

// Returns +1 bull, -1 bear, 0 neutral for M5 EMA cross
int M5Trend(SymState &s)
{
   if(!UseM5Filter) return 0;
   if(s.m5EmaFast > s.m5EmaSlow * 1.00005) return  1;
   if(s.m5EmaFast < s.m5EmaSlow * 0.99995) return -1;
   return 0;
}

// Returns +1 bull, -1 bear for M1 micro-trend
int M1MicroTrend(SymState &s)
{
   MqlTick tk;
   if(!SymbolInfoTick(s.sym, tk)) return 0;
   double mid = (tk.bid + tk.ask) * 0.5;
   if(mid > s.m1EmaFast) return  1;
   if(mid < s.m1EmaFast) return -1;
   return 0;
}

//=============================================================================
// SECTION H — RSI MOMENTUM FILTER
//=============================================================================

bool RsiAllows(SymState &s, int dir)
{
   if(dir ==  1) return (s.m5Rsi >= InpRsiBullLow && s.m5Rsi <= InpRsiBullHigh);
   if(dir == -1) return (s.m5Rsi >= InpRsiBearLow && s.m5Rsi <= InpRsiBearHigh);
   return false;
}

//=============================================================================
// SECTION I — SESSION FILTER
//=============================================================================

ESess CurrentSession()
{
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now - InpGmtOffset * 3600, dt);
   int gmt = dt.hour * 60 + dt.min;

   bool london = (gmt >= 420 && gmt < 1020);  // 07:00-17:00
   bool ny     = (gmt >= 780 && gmt < 1260);  // 13:00-21:00
   bool asian  = (gmt >= 0   && gmt < 420);   // 00:00-07:00

   if(london && ny)  return SESS_OVERLAP;
   if(london)        return SESS_LONDON;
   if(ny)            return SESS_NY;
   if(asian)         return SESS_ASIAN;
   return SESS_DEAD;
}

bool SessionAllows(ESess sess)
{
   switch(sess)
   {
      case SESS_OVERLAP: return (TradeLondon || TradeNY);
      case SESS_LONDON:  return TradeLondon;
      case SESS_NY:      return TradeNY;
      case SESS_ASIAN:   return TradeAsian;
      default:           return false;
   }
}

double SessionLotMult(ESess sess)
{
   switch(sess)
   {
      case SESS_OVERLAP: return 2.0;
      case SESS_LONDON:
      case SESS_NY:      return 1.0;
      case SESS_ASIAN:   return 0.5;
      default:           return 0.0;
   }
}

//=============================================================================
// SECTION J — VOLATILITY (ATR) FILTER
//=============================================================================

bool AtrAllows(SymState &s)
{
   if(s.m5Atr <= 0.0) return true; // not yet available
   return (s.m5Atr >= InpAtrMin && s.m5Atr <= InpAtrMax);
}

bool SpreadAllows(SymState &s)
{
   if(s.m5Atr <= 0.0) return true;
   MqlTick tk;
   if(!SymbolInfoTick(s.sym, tk)) return false;
   double spreadPts = (tk.ask - tk.bid) / s.pt;
   // Floor at 30 pts so normal broker spreads (15-30 pts) always pass even
   // in low-ATR conditions where ATR * pct would be only 1-3 pts.
   double maxSpread = MathMax(30.0, s.m5Atr * InpSpreadAtrPct / 100.0);
   return (spreadPts <= maxSpread);
}

//=============================================================================
// SECTION K — CONFLUENCE SCORER
//=============================================================================

int ConfluenceScore(SymState &s, int dir, bool inTester)
{
   // In tester, ATR-direction is the primary signal — bypass filters
   if(inTester) return InpMinConfluence;

   int score = 0;

   // Signal 1: Tick velocity direction
   double vel; int velDir;
   EVel tier = CalcVel(s, vel, velDir);
   if(tier >= VEL_WEAK && velDir == dir) score++;

   // Signal 2: Velocity consistency (last 3 snaps same dir)
   if(VelConsistent(s, dir, 3)) score++;

   // Signal 3: M5 EMA cross alignment
   int m5t = M5Trend(s);
   if(m5t == dir || m5t == 0) score++;

   // Signal 4: H1 bias alignment
   int h1b = H1Bias(s);
   if(h1b == dir || h1b == 0) score++;

   // Signal 5: RSI momentum zone
   if(RsiAllows(s, dir)) score++;

   return score;
}

//=============================================================================
// SECTION L — CORRELATION MANAGER
//=============================================================================

int CountSameDir(int dir)
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!t || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MAGIC) continue;
      ENUM_POSITION_TYPE pt2 =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(dir ==  1 && pt2 == POSITION_TYPE_BUY)  n++;
      if(dir == -1 && pt2 == POSITION_TYPE_SELL) n++;
   }
   return n;
}

//=============================================================================
// SECTION M — DYNAMIC LOT SIZING
//=============================================================================

double CalcLot(SymState &s, double askPx, ESess sess)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double free    = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   // ATR-based risk: risk InpRiskPct% of balance with SL = ATR * mult
   double atrPrice = s.m5Atr * s.pt;
   if(atrPrice <= 0.0) atrPrice = 20.0 * s.pt; // fallback 20 pts

   double slDist   = atrPrice * InpAtrRiskMult;
   double riskAmt  = balance * InpRiskPct / 100.0;

   // Tick value per lot
   double tickVal  = SymbolInfoDouble(s.sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSz   = SymbolInfoDouble(s.sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0.0 || tickSz <= 0.0) return InpMinLot;

   double lotRisk  = riskAmt / (slDist / tickSz * tickVal);

   // Session multiplier
   double sessMult = SessionLotMult(sess);

   // Adaptation multiplier (per-symbol rolling win rate)
   double adaptMult = s.lotMultiplier;

   double lot = lotRisk * sessMult * adaptMult;
   lot = MathMax(InpMinLot, MathMin(InpMaxLot, lot));

   // Also cap by margin: don't use > 70% of free margin on one trade
   double mgnPer = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, s.sym, lot, askPx, mgnPer) && mgnPer > 0.0)
   {
      double mgnMax = free * 0.70;
      if(mgnPer > mgnMax)
         lot = MathMax(InpMinLot, lot * (mgnMax / mgnPer));
   }

   // Round to broker step
   double step = SymbolInfoDouble(s.sym, SYMBOL_VOLUME_STEP);
   if(step > 0.0) lot = MathFloor(lot / step) * step;

   return MathMax(InpMinLot, lot);
}

//=============================================================================
// SECTION N — NEWS GUARD
//=============================================================================

bool InNewsWindow()
{
   if(!UseNewsGuard) return false;

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now - InpGmtOffset * 3600, dt);
   int gmtMin = dt.hour * 60 + dt.min;

   int newsCount = ArraySize(g_newsTimes);
   for(int i = 0; i < newsCount; i++)
   {
      int diff = gmtMin - g_newsTimes[i];
      if(diff >= -InpNewsBefore && diff <= InpNewsAfter)
         return true;
   }
   return false;
}

//=============================================================================
// SECTION O — ENTRY ENGINE
//=============================================================================

void TryEntry(SymState &s, bool inTester)
{
   if(!s.valid) return;
   if(s.filled < InpVelLookback) return;

   datetime now = TimeCurrent();
   if(!inTester && (int)(now - s.lastEntry) < InpCooldownSec) return;

   // Session check
   ESess sess = CurrentSession();
   if(!SessionAllows(sess)) return;

   // Spread + ATR check
   if(!AtrAllows(s))   return;
   if(!SpreadAllows(s)) return;

   MqlTick tk;
   if(!SymbolInfoTick(s.sym, tk)) return;

   // Determine direction
   int dir = 0;
   if(inTester)
   {
      // In tester: use M5 EMA cross direction as primary signal
      int m5t = M5Trend(s);
      int h1b = H1Bias(s);
      if(m5t != 0) dir = m5t;
      else if(h1b != 0) dir = h1b;
      else
      {
         // Fallback: last tick velocity
         double vel; int velDir;
         CalcVel(s, vel, velDir);
         dir = velDir;
      }
   }
   else
   {
      // Live: use tick velocity direction
      double vel; int velDir;
      EVel tier = CalcVel(s, vel, velDir);
      if(tier < VEL_WEAK) return;
      dir = velDir;
   }

   if(dir == 0) return;

   // Trend alignment check (live only — EMA may lag in tester)
   if(!inTester)
   {
      int h1b = H1Bias(s);
      int m5t = M5Trend(s);
      if(UseH1Filter && h1b != 0 && h1b != dir) return;
      if(UseM5Filter && m5t != 0 && m5t != dir) return;
   }

   // M1 micro-trend (additional timing filter)
   if(!inTester)
   {
      int m1t = M1MicroTrend(s);
      if(m1t != 0 && m1t != dir) return;
   }

   // RSI check (live only)
   if(!inTester && !RsiAllows(s, dir)) return;

   // Confluence score
   int score = ConfluenceScore(s, dir, inTester);
   if(score < InpMinConfluence) return;

   // Correlation check
   if(CountSameDir(dir) >= InpMaxSameDir) return;

   // Lot sizing
   double lot = CalcLot(s, tk.ask, sess);

   // Place order
   SetFilling(s.sym);
   double price = (dir == 1) ? tk.ask : tk.bid;
   string cmt   = "VBS2_" + s.base + "_" + (dir == 1 ? "B" : "S");

   bool ok = (dir == 1)
      ? trade.Buy(lot,  s.sym, price, 0, 0, cmt)
      : trade.Sell(lot, s.sym, price, 0, 0, cmt);

   if(ok)
   {
      s.lastEntry = now;
      if(InpLogging && InpLogLevel >= 1)
         Print("OPEN ", s.sym, " ", (dir==1?"BUY":"SELL"),
               " lot=", DoubleToString(lot,2),
               " px=",  DoubleToString(price,s.digits),
               " score=", score,
               " sess=", SessStr(sess),
               " rsi=", DoubleToString(s.m5Rsi,1));
   }
   else if(InpLogging)
      Print("OPEN FAIL ", s.sym, ": ", trade.ResultRetcodeDescription());
}

//=============================================================================
// SECTION P — EXIT ENGINE
//=============================================================================

void ManageExits(bool inTester)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!ticket || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MAGIC) continue;

      string posSym = PositionGetString(POSITION_SYMBOL);

      // Find SymState for this position
      int spIdx = -1;
      for(int j = 0; j < g_symCount; j++)
         if(g_sym[j].sym == posSym) { spIdx = j; break; }
      if(spIdx < 0) continue;

      MqlTick tk;
      if(!SymbolInfoTick(posSym, tk)) continue;

      double lots   = PositionGetDouble(POSITION_VOLUME);
      double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSl  = PositionGetDouble(POSITION_SL);
      double gross  = PositionGetDouble(POSITION_PROFIT)
                    + PositionGetDouble(POSITION_SWAP);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      ENUM_POSITION_TYPE ptype =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double commCost  = 3.50 * lots; // approximate round-turn
      double netProfit = gross - commCost;
      double atr       = g_sym[spIdx].m5Atr * g_sym[spIdx].pt;
      double ptsLoss   = (ptype == POSITION_TYPE_BUY)
         ? (openPx - tk.bid) / g_sym[spIdx].pt
         : (tk.ask - openPx) / g_sym[spIdx].pt;

      //--- 1. EMERGENCY CLOSE
      if(ptsLoss >= InpEmergStopPts)
      {
         if(ClosePos(ticket, posSym))
         {
            g_sym[spIdx].emergStreak++;
            RecordTrade(g_sym[spIdx], false, gross);
            if(InpLogging)
               Print("EMERGENCY ", posSym, " #", ticket,
                     " loss=$", DoubleToString(gross,2),
                     " streak=", g_sym[spIdx].emergStreak);
            if(g_sym[spIdx].emergStreak >= InpMaxEmergStreak)
            {
               g_sym[spIdx].paused = true;
               Print("PAUSED ", posSym, " — ", InpMaxEmergStreak,
                     " emergency stops. Re-attach to resume.");
            }
         }
         continue;
      }

      //--- 2. BREAK-EVEN SL — move SL to entry once 1x spread profit
      if(!inTester && netProfit > 0.0)
      {
         double spread  = (tk.ask - tk.bid);
         double newSl   = (ptype == POSITION_TYPE_BUY)
            ? openPx + spread * 0.5
            : openPx - spread * 0.5;
         bool   slNeeds = (ptype == POSITION_TYPE_BUY)
            ? (curSl < newSl - g_sym[spIdx].pt)
            : (curSl > newSl + g_sym[spIdx].pt || curSl == 0.0);
         if(slNeeds)
            trade.PositionModify(ticket, newSl, 0);
      }

      //--- 3. TIME EXIT — held too long and still not profitable
      int heldSec = (int)(TimeCurrent() - openTime);
      if(heldSec > InpMaxHoldMin * 60 && netProfit < 0.0)
      {
         if(ClosePos(ticket, posSym))
         {
            RecordTrade(g_sym[spIdx], false, gross);
            if(InpLogging && InpLogLevel >= 1)
               Print("TIMEOUT ", posSym, " #", ticket,
                     " held=", heldSec, "s net=$", DoubleToString(netProfit,2));
         }
         continue;
      }

      // Below exits require profit
      if(netProfit <= 0.0) continue;

      //--- 4. PARTIAL CLOSE — close 50% once InpPartialUSD reached
      if(netProfit >= InpPartialUSD && lots > InpMinLot * 1.5)
      {
         double halfLot = MathMax(InpMinLot,
                           MathFloor(lots * 0.5 / SymbolInfoDouble(posSym, SYMBOL_VOLUME_STEP))
                           * SymbolInfoDouble(posSym, SYMBOL_VOLUME_STEP));
         if(halfLot < lots)
         {
            SetFilling(posSym);
            trade.PositionClosePartial(ticket, halfLot);
            if(InpLogging && InpLogLevel >= 2)
               Print("PARTIAL ", posSym, " #", ticket,
                     " closed=", DoubleToString(halfLot,2),
                     " net=$", DoubleToString(netProfit,2));
            continue;
         }
      }

      //--- 5. TRAILING STOP — once profit >= 2 ATR, trail by 0.5 ATR
      if(!inTester && atr > 0.0 && netProfit >= atr * 2.0 * lots
            * SymbolInfoDouble(posSym, SYMBOL_TRADE_TICK_VALUE)
            / SymbolInfoDouble(posSym, SYMBOL_TRADE_TICK_SIZE))
      {
         double trailDist = atr * InpTrailAtr;
         double trailSl   = (ptype == POSITION_TYPE_BUY)
            ? tk.bid - trailDist
            : tk.ask + trailDist;
         bool trailNeeds  = (ptype == POSITION_TYPE_BUY)
            ? (trailSl > curSl + g_sym[spIdx].pt)
            : (curSl == 0.0 || trailSl < curSl - g_sym[spIdx].pt);
         if(trailNeeds)
            trade.PositionModify(ticket, trailSl, 0);
      }

      //--- 6. VELOCITY REVERSAL — momentum flipped (STRONG positions)
      double vel; int dir;
      EVel tier = CalcVel(g_sym[spIdx], vel, dir);
      bool velRev = false;
      if(tier >= VEL_STRONG)
         velRev = (ptype == POSITION_TYPE_BUY  && dir == -1)
               || (ptype == POSITION_TYPE_SELL && dir ==  1);

      //--- 7. ADAPTIVE PROFIT TARGET
      // Target = ATR * InpProfitATR converted to dollar
      double targetUSD = InpPartialUSD * 3.0; // baseline fallback
      if(atr > 0.0)
      {
         double tv   = SymbolInfoDouble(posSym, SYMBOL_TRADE_TICK_VALUE);
         double ts   = SymbolInfoDouble(posSym, SYMBOL_TRADE_TICK_SIZE);
         if(tv > 0.0 && ts > 0.0)
            targetUSD = atr * InpProfitATR * lots * tv / ts;
      }

      bool doClose = velRev || (netProfit >= targetUSD);

      if(doClose)
      {
         if(ClosePos(ticket, posSym))
         {
            g_sym[spIdx].emergStreak = 0;
            RecordTrade(g_sym[spIdx], true, gross);
            if(InpLogging && InpLogLevel >= 1)
               Print("PROFIT ", posSym, " #", ticket,
                     " net=$", DoubleToString(netProfit,2),
                     " target=$", DoubleToString(targetUSD,2),
                     " vel=", VelStr(tier),
                     (velRev ? " [reversal]" : " [target]"));
         }
      }
   }
}

//=============================================================================
// SECTION Q — ACCOUNT RISK GUARD
//=============================================================================

bool CheckAccountGuard()
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   // Overall drawdown from session start
   double dd = (g_startBal > 0.0)
      ? (g_startBal - equity) / g_startBal * 100.0 : 0.0;
   if(dd >= InpMaxDrawdownPct)
   {
      g_stopped = true;
      Print("MAX DRAWDOWN (", DoubleToString(dd,1), "%) — stopped. Close all.");
      CloseAllMagic();
      return true;
   }

   // Daily loss limit
   double dayDD = (g_dayStartBal > 0.0)
      ? (g_dayStartBal - equity) / g_dayStartBal * 100.0 : 0.0;
   if(dayDD >= InpMaxDailyLossPct)
   {
      g_stopped = true;
      Print("DAILY LOSS LIMIT (", DoubleToString(dayDD,1), "%) — stopped.");
      CloseAllMagic();
      return true;
   }
   return false;
}

void CloseAllMagic()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!t || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MAGIC)
      {
         SetFilling(PositionGetString(POSITION_SYMBOL));
         trade.PositionClose(t, 50);
      }
   }
}

//=============================================================================
// SECTION R — PERFORMANCE ADAPTATION
//=============================================================================

void RecordTrade(SymState &s, bool win, double pnl)
{
   ESess sess = CurrentSession();
   int si = (int)sess;

   s.stats[si].trades++;
   s.stats[si].totalPnl += pnl;
   if(win) s.stats[si].wins++;

   // Rolling window
   int wi = s.stats[si].wIdx % InpAdaptWindow;
   if(wi < 50)
      s.stats[si].wBuf[wi] = win ? 1 : 0;
   s.stats[si].wIdx++;
   if(s.stats[si].wCount < InpAdaptWindow) s.stats[si].wCount++;

   // Recalculate rolling win rate
   if(s.stats[si].wCount >= 10)
   {
      int wSum = 0;
      int cnt  = MathMin(s.stats[si].wCount, 50);
      for(int k = 0; k < cnt; k++) wSum += s.stats[si].wBuf[k];
      double wr = (double)wSum / cnt;

      if(wr < 0.40)      s.lotMultiplier = 0.60;
      else if(wr < 0.50) s.lotMultiplier = 0.80;
      else if(wr < 0.60) s.lotMultiplier = 1.00;
      else if(wr < 0.70) s.lotMultiplier = 1.15;
      else               s.lotMultiplier = 1.30;

      if(InpLogging && InpLogLevel >= 2)
         Print("ADAPT ", s.sym, " sess=", SessStr(sess),
               " wr=", DoubleToString(wr*100,1), "%",
               " lotMult=", DoubleToString(s.lotMultiplier,2));
   }
}

//=============================================================================
// SECTION S — DISPLAY PANEL
//=============================================================================

void ShowPanel()
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd      = (g_startBal > 0.0)
      ? MathMax(0.0,(g_startBal - equity)/g_startBal*100.0) : 0.0;
   double dayDD   = (g_dayStartBal > 0.0)
      ? MathMax(0.0,(g_dayStartBal - equity)/g_dayStartBal*100.0) : 0.0;

   double floating = 0.0;
   int    open     = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!t || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MAGIC)
      {
         floating += PositionGetDouble(POSITION_PROFIT)
                   + PositionGetDouble(POSITION_SWAP);
         open++;
      }
   }

   ESess sess = CurrentSession();
   bool  news = InNewsWindow();

   string panel = "\n=== VelocityBankScalper v2.0 ===\n";
   panel += "Session : " + SessStr(sess)
         + (news ? "  [NEWS PAUSE]" : "") + "\n";
   panel += "Trades  : " + IntegerToString(open) + " open\n";
   panel += "Floating: $" + DoubleToString(floating,2) + "\n";
   panel += "Balance : $" + DoubleToString(balance,2)  + "\n";
   panel += "Equity  : $" + DoubleToString(equity,2)   + "\n";
   panel += "DD(sess): " + DoubleToString(dd,1)  + "%  "
         + "Day: " + DoubleToString(dayDD,1) + "%\n\n";

   panel += "--- Symbols ---\n";
   for(int i = 0; i < g_symCount; i++)
   {
      if(!g_sym[i].valid) continue;
      double vel; int dir;
      EVel tier = CalcVel(g_sym[i], vel, dir);
      string dirStr = (dir==1)?"^":(dir==-1)?"v":"-";

      MqlTick tk;
      SymbolInfoTick(g_sym[i].sym, tk);
      double spread = (tk.ask-tk.bid)/g_sym[i].pt;

      int symOpen = 0;
      for(int j = PositionsTotal()-1; j >= 0; j--)
      {
         ulong t = PositionGetTicket(j);
         if(!t || !PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC)==MAGIC &&
            PositionGetString(POSITION_SYMBOL)==g_sym[i].sym) symOpen++;
      }

      panel += g_sym[i].base
            + (g_sym[i].paused ? "[PAUSED]" : "")
            + ": " + VelStr(tier) + dirStr
            + " vel=" + DoubleToString(vel,1)
            + " rsi=" + DoubleToString(g_sym[i].m5Rsi,1)
            + " atr=" + DoubleToString(g_sym[i].m5Atr,1)
            + " spd=" + DoubleToString(spread,1)
            + " pos=" + IntegerToString(symOpen)
            + " mult=" + DoubleToString(g_sym[i].lotMultiplier,2)
            + "\n";
   }

   panel += "\n" + (g_stopped ? ">>> STOPPED <<<" : "ACTIVE");
   Comment(panel);
}

//=============================================================================
// SECTION T — HELPERS & UTILITIES
//=============================================================================

bool ClosePos(ulong ticket, string sym)
{
   SetFilling(sym);
   return trade.PositionClose(ticket, 50);
}

int CountAllPos()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!t || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MAGIC) n++;
   }
   return n;
}

void SetFilling(string sym)
{
   uint mode = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((mode & 1) != 0)      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((mode & 2) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                      trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

string FindSymbol(string base)
{
   if(SymbolSelect(base, true)) return base;
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
   {
      string s = SymbolName(i, false);
      if(StringFind(s, base) == 0 &&
         StringLen(s) > StringLen(base) &&
         StringLen(s) <= StringLen(base) + 6)
         return s;
   }
   return "";
}

string VelStr(EVel v)
{
   switch(v)
   {
      case VEL_STRONG: return "STR";
      case VEL_MEDIUM: return "MED";
      case VEL_WEAK:   return "WEK";
      default:         return "FLT";
   }
}

string SessStr(ESess s)
{
   switch(s)
   {
      case SESS_OVERLAP: return "OVR";
      case SESS_LONDON:  return "LON";
      case SESS_NY:      return "NY ";
      case SESS_ASIAN:   return "ASI";
      default:           return "DED";
   }
}

void PrintParams()
{
   Print("==============================================");
   Print("VelocityBankScalper v2.0  STARTED");
   Print("Symbols     : ", InpSymbols);
   Print("Active      : ", g_symCount);
   Print("Risk/trade  : ", InpRiskPct, "%  MinLot:", InpMinLot,
         "  MaxLot:", InpMaxLot);
   Print("Trend filter: H1=", UseH1Filter ? "ON" : "OFF",
         "  M5=", UseM5Filter ? "ON" : "OFF");
   Print("Confluence  : ", InpMinConfluence, "/5 signals required");
   Print("Sessions    : London=", TradeLondon ? "ON":"OFF",
         "  NY=", TradeNY ? "ON":"OFF",
         "  Asian=", TradeAsian ? "ON":"OFF");
   Print("ATR range   : ", InpAtrMin, "-", InpAtrMax, " pts");
   Print("Exit target : ", InpProfitATR, "x ATR");
   Print("Max hold    : ", InpMaxHoldMin, " min");
   Print("News guard  : ", UseNewsGuard ? "ON":"OFF");
   Print("==============================================");
}
