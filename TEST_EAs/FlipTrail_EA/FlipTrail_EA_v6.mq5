//+------------------------------------------------------------------+
//|  FlipTrail_EA_v6.mq5  v6.35                                      |
//|  Margin Scalper — Hold-through-trend, EMA-gated TP close         |
//|                                                                   |
//|  PHASE 1 (SEED):                                                 |
//|    Open InpSeedCount trades on SignalTF bar (optional filter).   |
//|    Store g_signalPrice = avg fill. Immediately fire burst.       |
//|                                                                   |
//|  PHASE 2 (BURST):                                                |
//|    Per-tick exit priority:                                        |
//|      1. Emergency basket loss (InpMaxLossPct).                   |
//|      2. TP milestone hit (burstRound*BurstTPPct from signal):    |
//|         — EMA still aligned → HOLD, advance round (no spread).  |
//|         — EMA reversing → CLOSE, take profit.                   |
//|      3. Timed profit: basket in profit after X mins → close.     |
//|      4. Timed loss: basket losing X% after Y mins → close.      |
//|      5. Peak pullback: close profitable, hold rest for DynSL.   |
//|      6. DynSL: hard backstop at InpBurstSLPct%.                 |
//+------------------------------------------------------------------+
#property copyright "FlipTrail EA v6"
#property link      ""
#property version   "6.35"
#property description "FlipTrail v6.35: EMA-gated TP hold, loosen entry, on-chart dashboard"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

enum BasketPhase { PHASE_NONE=0, PHASE_SEED=1, PHASE_BURST=2 };

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Basket ==="
input ENUM_TIMEFRAMES InpSignalTF = PERIOD_M5; // SignalTF: bar timeframe for entry signal + indicators (M1=noisy, M5/M15 recommended)
input double InpRiskPct           = 20.0;  // RiskPct: % equity per seed trade
input double InpMinLot            = 0.01;  // MinLot
input double InpMaxLot            = 50.0;  // MaxLot
input long   InpMagicNumber       = 116300;// MagicNumber (v6.3)
input int    InpMaxSlippagePoints = 30;    // MaxSlippagePoints
input int    InpMaxSpreadPoints   = 0;     // MaxSpreadPoints (0=off, seed only)

input group "=== Seed Phase ==="
input int    InpSeedCount         = 2;     // SeedCount: trades to confirm trend
input double InpSeedTPPct         = 0.01;  // SeedTPPct: % move from signal to trigger burst

input group "=== Burst Phase ==="
input int    InpBurstCount        = 10;    // BurstCount: trades per burst round
input double InpBurstTPPct        = 0.02;  // BurstTPPct: TP milestone per round from signal (min 0.02% before any close)
input double InpBurstRiskPct      = 5.0;   // BurstRiskPct: % equity risk per burst trade
input double InpBurstSLPct        = 0.15;  // BurstSLPct: hard backstop SL% from signal (wider = more breathing room; 0=DynSL floor only)
input double InpPeakKeepPct       = 80.0;  // PeakKeepPct: close all if pullback to X% of peak
input int    InpBurstMaxSec       = 0;     // BurstMaxSec: time gate seconds — close ALL (0=off)
input double InpMaxLossPct        = 0;     // MaxLossPct: emergency close if basket loses X% equity (0=off)
input int    InpMaxBursts         = 20;    // MaxBursts: max trend-continuation burst rounds
input int    InpBasketMaxLossMins  = 3;    // BasketMaxLossMins: close basket if still losing after X minutes (0=off)
input double InpBasketLossPct      = 10.0; // BasketLossPct: min basket loss% of equity to trigger timed loss close
input int    InpBasketMaxProfitMins= 5;    // BasketMaxProfitMins: close basket if in net profit after X minutes (0=off)

input group "=== Dynamic SL ==="
input int    InpSLHistoryTrades   = 20;    // SLHistoryTrades: circular buffer size
input double InpSLFloorPct        = 0.12;  // SLFloorPct: DynSL minimum %

input group "=== Entry Filter ==="
input bool   InpUseEntryFilter    = false; // UseEntryFilter: gate entries on EMA+RSI (false=trade every bar signal)
input int    InpEMAFast           = 5;     // EMA fast period (SignalTF)
input int    InpEMASlow           = 13;    // EMA slow period (SignalTF)
input int    InpRSIPeriod         = 7;     // RSI period (SignalTF)
input double InpRSIBuyMax         = 75.0;  // RSI max allowed for BUY
input double InpRSISellMin        = 25.0;  // RSI min allowed for SELL
input int    InpMinBodyPct        = 0;     // Min candle body% of range (0=off)


input group "=== Consecutive Loss Pause ==="
input int    InpMaxConsecLoss     = 0;     // MaxConsecLoss: pause after N losses (0=off)
input int    InpPauseBars         = 5;     // PauseBars: M1 bars to wait before resuming

//──────────────────────────────────────────────────────────────────────────────
// GLOBALS
//──────────────────────────────────────────────────────────────────────────────
CTrade        g_trade;
CPositionInfo g_pos;
CSymbolInfo   g_sym;

bool     g_isNetting   = false;
datetime g_lastBarTime = 0;

// Phase state
BasketPhase     g_phase             = PHASE_NONE;
ENUM_ORDER_TYPE g_basketDir         = ORDER_TYPE_BUY;
double          g_signalPrice       = 0.0;   // avg fill of seed trades — stable trend reference
double          g_peakSignalMovePct = 0.0;   // peak % move from signal price during burst
datetime        g_burstOpenTime     = 0;
int             g_burstRound        = 0;
bool            g_timeGateFired     = false;

// Dynamic SL history
double g_changeHistory[];
int    g_historyIndex = 0;
int    g_historyCount = 0;

// Consecutive loss pause
int g_consecLoss    = 0;
int g_pauseBarCount = 0;

// Indicators
int g_hEMAFast = INVALID_HANDLE;
int g_hEMASlow = INVALID_HANDLE;
int g_hRSI     = INVALID_HANDLE;

//──────────────────────────────────────────────────────────────────────────────
// UTILITY
//──────────────────────────────────────────────────────────────────────────────
int CountOurPositions()
{
   int n = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;
      n++;
   }
   return n;
}

double NormalizeLot(double lot)
{
   double step = g_sym.LotsStep();
   double minL = g_sym.LotsMin();
   double maxL = g_sym.LotsMax();
   if (step <= 0.0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, MathMax(minL, InpMinLot));
   lot = MathMin(lot, MathMin(maxL, InpMaxLot));
   return NormalizeDouble(lot, 2);
}

void PrintResult(const string ctx)
{
   PrintFormat("%s | rc=%u (%s) | deal=%llu | order=%llu",
               ctx, g_trade.ResultRetcode(),
               g_trade.ResultRetcodeDescription(),
               g_trade.ResultDeal(), g_trade.ResultOrder());
}

double GetDynamicThreshold()
{
   if (g_historyCount == 0) return InpSLFloorPct;
   double sum = 0.0;
   for (int i = 0; i < g_historyCount; i++) sum += g_changeHistory[i];
   return MathMax(sum / g_historyCount, InpSLFloorPct);
}

double CalcDynamicLot()
{
   double threshold = GetDynamicThreshold();
   g_sym.RefreshRates();
   double price = (g_sym.Ask() + g_sym.Bid()) / 2.0;
   if (price <= 0) return NormalizeLot(InpMinLot);

   int slPts = (int)MathRound(threshold / 100.0 * price / _Point);
   if (slPts <= 0) return NormalizeLot(InpMinLot);

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPct / 100.0;
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tickVal <= 0 || tickSize <= 0) return NormalizeLot(InpMinLot);

   double slMoney = (slPts * _Point / tickSize) * tickVal;
   if (slMoney <= 0) return NormalizeLot(InpMinLot);

   return NormalizeLot(riskMoney / slMoney);
}

// Lot sizing for burst trades — uses InpBurstRiskPct and InpBurstSLPct independently
// from seed lot sizing so one DynSL event can never blow more than BurstRiskPct*BurstCount
double CalcBurstLot()
{
   double threshold = (InpBurstSLPct > 0) ? InpBurstSLPct : GetDynamicThreshold();
   g_sym.RefreshRates();
   double price = (g_sym.Ask() + g_sym.Bid()) / 2.0;
   if (price <= 0) return NormalizeLot(InpMinLot);

   int slPts = (int)MathRound(threshold / 100.0 * price / _Point);
   if (slPts <= 0) return NormalizeLot(InpMinLot);

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpBurstRiskPct / 100.0;
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tickVal <= 0 || tickSize <= 0) return NormalizeLot(InpMinLot);

   double slMoney = (slPts * _Point / tickSize) * tickVal;
   if (slMoney <= 0) return NormalizeLot(InpMinLot);

   return NormalizeLot(riskMoney / slMoney);
}

// Live EMA alignment check (bar 0 = current, for real-time TP hold decisions)
bool CheckEMAAligned(ENUM_ORDER_TYPE dir)
{
   if (g_hEMAFast == INVALID_HANDLE || g_hEMASlow == INVALID_HANDLE) return true;
   double ef[1], es[1];
   if (CopyBuffer(g_hEMAFast, 0, 0, 1, ef) < 1) return true;
   if (CopyBuffer(g_hEMASlow, 0, 0, 1, es) < 1) return true;
   return (dir == ORDER_TYPE_BUY) ? (ef[0] > es[0]) : (ef[0] < es[0]);
}

void UpdateDashboard()
{
   string phase = (g_phase == PHASE_NONE ? "IDLE" : g_phase == PHASE_SEED ? "SEED" : "BURST");
   string dir   = (g_basketDir == ORDER_TYPE_BUY ? "▲ BUY" : "▼ SELL");

   double totalPnL = 0;
   int    positions = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;
      totalPnL += g_pos.Profit() + g_pos.Swap();
      positions++;
   }

   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double pnlPct     = (equity > 0) ? (totalPnL / equity * 100.0) : 0.0;
   double signalMove = 0.0;
   int    elapsed    = 0;

   if (g_phase != PHASE_NONE && g_signalPrice > 0)
   {
      g_sym.RefreshRates();
      double cur = (g_basketDir == ORDER_TYPE_BUY) ? g_sym.Bid() : g_sym.Ask();
      signalMove = (g_basketDir == ORDER_TYPE_BUY)
                   ? (cur - g_signalPrice) / g_signalPrice * 100.0
                   : (g_signalPrice - cur) / g_signalPrice * 100.0;
      if (g_burstOpenTime > 0)
         elapsed = (int)(TimeCurrent() - g_burstOpenTime);
   }

   double tpNext = (double)g_burstRound * InpBurstTPPct;
   double dynSL  = GetDynamicThreshold();
   if (InpBurstSLPct > 0) dynSL = MathMin(dynSL, InpBurstSLPct);
   bool emaAlign = CheckEMAAligned(g_basketDir);

   Comment(StringFormat(
      "══ FlipTrail v6.35 ══════════════════\n"
      " Phase   : %-6s  %s\n"
      " Pos     : %d open   Round: %d / %d\n"
      " Signal  : %.5f\n"
      " Move    : %+.3f%%   Peak: +%.3f%%\n"
      " Next TP : +%.3f%%   SL: -%.3f%%\n"
      " Basket  : %+.2f  (%+.2f%%)\n"
      " Elapsed : %ds\n"
      " EMA     : %s\n"
      " TF      : %s   EMA%d/%d  RSI%d\n"
      "═════════════════════════════════════",
      phase, (g_phase != PHASE_NONE ? dir : ""),
      positions, g_burstRound, InpMaxBursts,
      g_signalPrice,
      signalMove, g_peakSignalMovePct,
      tpNext, dynSL,
      totalPnL, pnlPct,
      elapsed,
      emaAlign ? "aligned ✓" : "reversing ✗",
      EnumToString(InpSignalTF), InpEMAFast, InpEMASlow, InpRSIPeriod
   ));
}

bool CheckIndicatorFilter(ENUM_ORDER_TYPE dir)
{
   if (g_hEMAFast == INVALID_HANDLE || g_hEMASlow == INVALID_HANDLE || g_hRSI == INVALID_HANDLE)
      return true;

   double emaFast[1], emaSlow[1], rsiVal[1];
   if (CopyBuffer(g_hEMAFast, 0, 1, 1, emaFast) < 1) return false;
   if (CopyBuffer(g_hEMASlow, 0, 1, 1, emaSlow) < 1) return false;
   if (CopyBuffer(g_hRSI,     0, 1, 1, rsiVal)  < 1) return false;

   bool emaOK = (dir == ORDER_TYPE_BUY) ? (emaFast[0] > emaSlow[0])
                                        : (emaFast[0] < emaSlow[0]);
   bool rsiOK = (dir == ORDER_TYPE_BUY) ? (rsiVal[0] < InpRSIBuyMax)
                                        : (rsiVal[0] > InpRSISellMin);

   if (!emaOK)
      PrintFormat("Filter[EMA%d/EMA%d]: %.4f %s %.4f — skip",
                  InpEMAFast, InpEMASlow, emaFast[0],
                  (dir==ORDER_TYPE_BUY?"<":">"), emaSlow[0]);
   if (!rsiOK)
      PrintFormat("Filter[RSI7=%.1f]: %s — skip",
                  rsiVal[0], (dir==ORDER_TYPE_BUY?"above buy-max":"below sell-min"));

   return emaOK && rsiOK;
}

//──────────────────────────────────────────────────────────────────────────────
// STATE MANAGEMENT
//──────────────────────────────────────────────────────────────────────────────
void ResetSignal()
{
   g_phase             = PHASE_NONE;
   g_signalPrice       = 0.0;
   g_peakSignalMovePct = 0.0;
   g_burstOpenTime     = 0;
   g_burstRound        = 0;
   g_timeGateFired     = false;
}

// Record % change from signal price into DynSL history buffer
void RecordHistory(double signalMovePct)
{
   double absChange = MathAbs(signalMovePct);
   if (absChange < 0.0001) absChange = InpSLFloorPct;
   g_changeHistory[g_historyIndex % InpSLHistoryTrades] = absChange;
   g_historyIndex++;
   g_historyCount = MathMin(g_historyCount + 1, InpSLHistoryTrades);
}

//──────────────────────────────────────────────────────────────────────────────
// TRADE ACTIONS
//──────────────────────────────────────────────────────────────────────────────
void CloseAllOurPositions(const string reason)
{
   ulong tickets[];
   int   total = 0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;
      ArrayResize(tickets, total + 1);
      tickets[total++] = g_pos.Ticket();
   }

   for (int j = 0; j < total; j++)
      for (int attempt = 0; attempt < 3; attempt++)
      {
         if (g_trade.PositionClose(tickets[j], InpMaxSlippagePoints)) break;
         Sleep(50);
      }

   PrintFormat("[v6.35] CloseAll [%s] | %d positions", reason, total);
}

void CloseAllProfitable(const string reason)
{
   ulong tickets[];
   int   total = 0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;
      if (g_pos.Profit() <= 0.0)                    continue;
      ArrayResize(tickets, total + 1);
      tickets[total++] = g_pos.Ticket();
   }

   int closed = 0;
   for (int j = 0; j < total; j++)
      for (int attempt = 0; attempt < 3; attempt++)
      {
         if (g_trade.PositionClose(tickets[j], InpMaxSlippagePoints)) { closed++; break; }
         Sleep(50);
      }

   if (closed > 0)
      PrintFormat("[v6.35] CloseProfitable [%s] | closed=%d of %d", reason, closed, total);
}

// Close all positions that individually hit the round-based signal-price TP threshold.
// Threshold = burstRound * InpBurstTPPct from g_signalPrice, so seed + burst trades
// all reach the same target simultaneously, enabling trend-continuation to fire.
// Returns number of positions closed
int CloseIndividualTP()
{
   g_sym.RefreshRates();
   double ask = g_sym.Ask();
   double bid = g_sym.Bid();

   if (g_signalPrice <= 0) return 0;

   // Each burst round advances the TP milestone by one InpBurstTPPct step from signal price
   double tpThreshold = (double)g_burstRound * InpBurstTPPct;

   ulong tickets[];
   int   total = 0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;

      // Measure move from signal price (same reference for seed + burst trades)
      double changePct = (g_pos.PositionType() == POSITION_TYPE_BUY)
                         ? (bid - g_signalPrice) / g_signalPrice * 100.0
                         : (g_signalPrice - ask) / g_signalPrice * 100.0;

      if (changePct >= tpThreshold)
      {
         ArrayResize(tickets, total + 1);
         tickets[total++] = g_pos.Ticket();
      }
   }

   int closed = 0;
   for (int j = 0; j < total; j++)
      for (int attempt = 0; attempt < 3; attempt++)
      {
         if (g_trade.PositionClose(tickets[j], InpMaxSlippagePoints)) { closed++; break; }
         Sleep(50);
      }

   return closed;
}

// Open N trades in direction, accumulate fills into entrySum
// Returns number successfully opened
int OpenTrades(int count, ENUM_ORDER_TYPE dir, double lot, double &entrySum)
{
   int opened = 0;
   for (int t = 0; t < count; t++)
   {
      g_sym.RefreshRates();
      double ask = g_sym.Ask();
      double bid = g_sym.Bid();
      bool   ok  = false;

      if (dir == ORDER_TYPE_BUY)
         ok = g_trade.Buy(lot, _Symbol, ask, 0, 0, "FTV631");
      else
         ok = g_trade.Sell(lot, _Symbol, bid, 0, 0, "FTV631");

      uint rc = g_trade.ResultRetcode();
      PrintResult(StringFormat("[%s] v6.3 %s t=%d/%d lot=%.2f",
                  _Symbol, (dir==ORDER_TYPE_BUY?"BUY":"SELL"), t+1, count, lot));

      if (rc == TRADE_RETCODE_DONE)
      {
         opened++;
         entrySum += g_trade.ResultPrice();
      }
      else if (rc == TRADE_RETCODE_REQUOTE      ||
               rc == TRADE_RETCODE_PRICE_CHANGED ||
               rc == TRADE_RETCODE_PRICE_OFF)
      {
         Sleep(100);
         t--;
         if (t < -1) break;
      }
      else break;
   }
   return opened;
}

void OpenBurst()
{
   double lot      = CalcBurstLot();
   double entrySum = 0.0;
   int    opened   = OpenTrades(InpBurstCount, g_basketDir, lot, entrySum);

   g_phase         = PHASE_BURST;
   g_burstOpenTime = TimeCurrent();
   g_burstRound++;
   g_timeGateFired = false;

   double tpTarget = (double)g_burstRound * InpBurstTPPct;
   PrintFormat("[Burst OPEN] round=%d/%d | %d/%d trades | lot=%.2f | signalPrice=%.5f | "
               "IndivTP=%.3f%% (round%d*%.3f%%) | BurstSL=%.3f%% | PeakKeep=%.0f%% | TimeGate=%ds",
               g_burstRound, InpMaxBursts, opened, InpBurstCount, lot,
               g_signalPrice, tpTarget, g_burstRound, InpBurstTPPct,
               InpBurstSLPct, InpPeakKeepPct, InpBurstMaxSec);
}

//──────────────────────────────────────────────────────────────────────────────
// SEED PHASE — per-tick: wait for signal confirmation
//──────────────────────────────────────────────────────────────────────────────
void CheckSeedPhase()
{
   int total = CountOurPositions();
   if (total == 0) { ResetSignal(); return; }

   g_sym.RefreshRates();
   double currentPrice = (g_basketDir == ORDER_TYPE_BUY) ? g_sym.Bid() : g_sym.Ask();
   if (g_signalPrice <= 0) { CloseAllOurPositions("NoSignalPrice"); ResetSignal(); return; }

   double seedMovePct = (g_basketDir == ORDER_TYPE_BUY)
                        ? (currentPrice - g_signalPrice) / g_signalPrice * 100.0
                        : (g_signalPrice - currentPrice) / g_signalPrice * 100.0;

   // DynSL abort
   double dynSL = GetDynamicThreshold();
   if (seedMovePct <= -dynSL)
   {
      PrintFormat("[Seed] DynSL: move=%.3f%% <= -%.3f%% — abort", seedMovePct, dynSL);
      CloseAllOurPositions("SeedDynSL");
      RecordHistory(seedMovePct);
      g_consecLoss++;
      ResetSignal();
      return;
   }

   // Signal confirmed → open burst
   if (seedMovePct >= InpSeedTPPct)
   {
      PrintFormat("[Seed] CONFIRMED: move=%.3f%% >= %.3f%% → opening burst round 1",
                  seedMovePct, InpSeedTPPct);
      OpenBurst();
   }
}

//──────────────────────────────────────────────────────────────────────────────
// BURST PHASE — per-tick exit logic
//──────────────────────────────────────────────────────────────────────────────
void CheckExit()
{
   int total = CountOurPositions();
   if (total == 0) { ResetSignal(); return; }

   g_sym.RefreshRates();
   double currentPrice = (g_basketDir == ORDER_TYPE_BUY) ? g_sym.Bid() : g_sym.Ask();
   if (g_signalPrice <= 0) { CloseAllOurPositions("NoSignalPrice"); ResetSignal(); return; }

   double signalMovePct = (g_basketDir == ORDER_TYPE_BUY)
                          ? (currentPrice - g_signalPrice) / g_signalPrice * 100.0
                          : (g_signalPrice - currentPrice) / g_signalPrice * 100.0;

   // Update peak from signal price
   if (signalMovePct > g_peakSignalMovePct)
      g_peakSignalMovePct = signalMovePct;

   // ── 1. Emergency loss ─────────────────────────────────────────────────────
   if (InpMaxLossPct > 0)
   {
      double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
      double totalPnL = 0.0;
      for (int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if (!g_pos.SelectByIndex(i))                 continue;
         if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
         if (g_pos.Symbol() != _Symbol)               continue;
         totalPnL += g_pos.Profit() + g_pos.Swap();
      }
      double lossPct = (equity > 0) ? (-totalPnL / equity * 100.0) : 0.0;
      if (lossPct >= InpMaxLossPct)
      {
         PrintFormat("[Exit] EMERGENCY LOSS %.3f%% >= %.3f%% | P&L=%.2f",
                     lossPct, InpMaxLossPct, totalPnL);
         CloseAllOurPositions("EmergencyLoss");
         RecordHistory(signalMovePct);
         g_consecLoss++;
         ResetSignal();
         return;
      }
   }

   // ── 2. TP milestone — hold if EMA aligned, close if reversing ───────────
   double tpThreshold = (double)g_burstRound * InpBurstTPPct;
   if (tpThreshold > 0 && signalMovePct >= tpThreshold)
   {
      bool emaAligned = CheckEMAAligned(g_basketDir);

      if (emaAligned && g_burstRound < InpMaxBursts)
      {
         // EMA still with us — advance TP target, hold positions (no spread cost)
         g_burstRound++;
         g_burstOpenTime = TimeCurrent();     // reset timed exits for new round
         g_peakSignalMovePct = signalMovePct; // reset peak reference
         PrintFormat("[TP->Hold] %.3f%% hit | EMA aligned | holding | next TP=%.3f%% round %d/%d",
                     tpThreshold, (double)g_burstRound * InpBurstTPPct,
                     g_burstRound, InpMaxBursts);
      }
      else
      {
         // EMA reversing or max rounds — take the profit now
         int closed = CloseIndividualTP();
         if (closed > 0)
         {
            RecordHistory(signalMovePct);
            g_consecLoss = 0;
            PrintFormat("[Exit] IndivTP closed=%d | signalMove=%.3f%% | EMA %s | round %d/%d",
                        closed, signalMovePct,
                        emaAligned ? "maxRounds" : "reversing",
                        g_burstRound, InpMaxBursts);
            if (CountOurPositions() == 0) { ResetSignal(); return; }
         }
      }
   }

   // ── 3. Timed basket profit — lock in gains after X minutes if in net profit ──
   if (InpBasketMaxProfitMins > 0)
   {
      int elapsed = (int)(TimeCurrent() - g_burstOpenTime);
      if (elapsed >= InpBasketMaxProfitMins * 60)
      {
         double totalPnL = 0.0;
         for (int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if (!g_pos.SelectByIndex(i))                 continue;
            if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
            if (g_pos.Symbol() != _Symbol)               continue;
            totalPnL += g_pos.Profit() + g_pos.Swap();
         }
         if (totalPnL > 0 && signalMovePct >= InpBurstTPPct)
         {
            PrintFormat("[Exit] BasketTimedProfit: %ds elapsed | profit=%.2f | move=%.3f%% — closing all",
                        elapsed, totalPnL, signalMovePct);
            CloseAllOurPositions("BasketTimedProfit");
            RecordHistory(signalMovePct);
            g_consecLoss = 0;
            ResetSignal();
            return;
         }
      }
   }

   // ── 4. Timed basket loss — give trades breathing room, then cut if still losing ──
   if (InpBasketMaxLossMins > 0 && InpBasketLossPct > 0)
   {
      int elapsed = (int)(TimeCurrent() - g_burstOpenTime);
      if (elapsed >= InpBasketMaxLossMins * 60)
      {
         double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
         double totalPnL = 0.0;
         for (int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if (!g_pos.SelectByIndex(i))                 continue;
            if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
            if (g_pos.Symbol() != _Symbol)               continue;
            totalPnL += g_pos.Profit() + g_pos.Swap();
         }
         double lossPct = (equity > 0 && totalPnL < 0) ? (-totalPnL / equity * 100.0) : 0.0;
         if (lossPct >= InpBasketLossPct)
         {
            PrintFormat("[Exit] BasketTimedLoss: %ds elapsed | basket loss=%.2f%% >= %.2f%% — closing all",
                        elapsed, lossPct, InpBasketLossPct);
            CloseAllOurPositions("BasketTimedLoss");
            RecordHistory(signalMovePct);
            g_consecLoss++;
            ResetSignal();
            return;
         }
      }
   }

   // ── 5. Peak pullback — lock in gains, hold losers for DynSL ─────────────
   // Never close a losing position here — only lock in gains on the winners.
   // Remaining losers stay open until DynSL fires at -InpSLFloorPct%.
   if (InpPeakKeepPct > 0 && g_peakSignalMovePct > InpSeedTPPct)
   {
      double keepThreshold = g_peakSignalMovePct * InpPeakKeepPct / 100.0;
      if (signalMovePct < keepThreshold)
      {
         PrintFormat("[Exit] PeakPullback: signalMove=%.3f%% < keepAt=%.3f%% (peak=%.3f%% * %.0f%%) — closing profitable only, losers held for DynSL",
                     signalMovePct, keepThreshold, g_peakSignalMovePct, InpPeakKeepPct);
         CloseAllProfitable("PeakPullback");
         if (CountOurPositions() == 0)
         {
            RecordHistory(signalMovePct);
            g_consecLoss = 0;
            ResetSignal();
         }
         return;
      }
   }

   // ── 6. DynSL from signal price — capped at InpBurstSLPct for burst ──────
   double dynSL = GetDynamicThreshold();
   if (InpBurstSLPct > 0) dynSL = MathMin(dynSL, InpBurstSLPct);
   if (signalMovePct <= -dynSL)
   {
      PrintFormat("[Exit] DynSL: signalMove=%.3f%% <= -%.3f%% (burstSL cap=%.3f%%)",
                  signalMovePct, dynSL, InpBurstSLPct);
      CloseAllOurPositions("DynSL");
      RecordHistory(signalMovePct);
      g_consecLoss++;
      ResetSignal();
      return;
   }

   // ── 7. Time gate — close ALL and reset (fast exit when TP hasn't fired) ──
   if (!g_timeGateFired && InpBurstMaxSec > 0)
   {
      int elapsed = (int)(TimeCurrent() - g_burstOpenTime);
      if (elapsed >= InpBurstMaxSec)
      {
         g_timeGateFired = true;
         PrintFormat("[Exit] TimeGate %ds elapsed — closing ALL (signalMove=%.3f%%)",
                     elapsed, signalMovePct);
         CloseAllOurPositions("TimeGate");
         RecordHistory(signalMovePct);
         ResetSignal();
         return;
      }
   }
}

//──────────────────────────────────────────────────────────────────────────────
// SEED ENTRY — fires on each new M1 bar
//──────────────────────────────────────────────────────────────────────────────
void TrySeedEntry()
{
   if (g_phase != PHASE_NONE)     return;
   if (CountOurPositions() > 0)   return;

   // Consecutive loss pause
   if (InpMaxConsecLoss > 0 && g_consecLoss >= InpMaxConsecLoss)
   {
      g_pauseBarCount++;
      if (g_pauseBarCount < InpPauseBars)
      {
         PrintFormat("[Pause] consecLoss=%d — waiting bar %d/%d",
                     g_consecLoss, g_pauseBarCount, InpPauseBars);
         return;
      }
      g_consecLoss    = 0;
      g_pauseBarCount = 0;
      PrintFormat("[Pause] Resuming after %d bars", InpPauseBars);
   }

   // Spread check (seed only — burst fires immediately on confirmation)
   if (InpMaxSpreadPoints > 0)
   {
      g_sym.RefreshRates();
      int sp = (int)MathRound((g_sym.Ask() - g_sym.Bid()) / _Point);
      if (sp > InpMaxSpreadPoints)
      {
         PrintFormat("Spread %d > %d — skip seed", sp, InpMaxSpreadPoints);
         return;
      }
   }

   double c  = iClose(_Symbol, InpSignalTF, 1);
   double o  = iOpen (_Symbol, InpSignalTF, 1);
   double hi = iHigh (_Symbol, InpSignalTF, 1);
   double lo = iLow  (_Symbol, InpSignalTF, 1);
   if (c == o) return;

   ENUM_ORDER_TYPE dir = (c > o) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if (InpMinBodyPct > 0)
   {
      double range = hi - lo;
      double body  = MathAbs(c - o);
      if (range > 0 && (body / range) * 100.0 < (double)InpMinBodyPct) return;
   }

   if (InpUseEntryFilter && !CheckIndicatorFilter(dir)) return;

   // Open seed trades
   double lot      = CalcDynamicLot();
   double entrySum = 0.0;
   int    opened   = OpenTrades(InpSeedCount, dir, lot, entrySum);

   if (opened > 0)
   {
      g_basketDir         = dir;
      g_phase             = PHASE_SEED;   // set before OpenBurst so g_signalPrice is ready
      g_signalPrice       = entrySum / opened;
      g_peakSignalMovePct = 0.0;
      g_burstRound        = 0;
      g_timeGateFired     = false;

      PrintFormat("[Seed OPEN] %s | %d/%d trades | lot=%.2f | signalPrice=%.5f | "
                  "firing burst immediately (EMA/RSI is confirmation) | seedSL=%.3f%%",
                  (dir==ORDER_TYPE_BUY?"BUY":"SELL"),
                  opened, InpSeedCount, lot, g_signalPrice,
                  GetDynamicThreshold());

      // Burst fires on the same tick — no per-tick wait that DynSL can abort
      OpenBurst();
   }
}

//==============================================================================
// MT5 HANDLERS
//==============================================================================
int OnInit()
{
   if (!g_sym.Name(_Symbol)) { Print("INIT FAILED: SymbolInfo"); return INIT_FAILED; }
   g_sym.RefreshRates();

   int fillingMask = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_RETURN;
   if ((fillingMask & 2) != 0) filling = ORDER_FILLING_IOC;
   if ((fillingMask & 1) != 0) filling = ORDER_FILLING_FOK;

   g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   g_trade.SetDeviationInPoints(InpMaxSlippagePoints);
   g_trade.SetTypeFilling(filling);
   g_trade.SetAsyncMode(false);

   g_isNetting = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_NETTING);
   PrintFormat("Account: %s", g_isNetting ? "NETTING" : "HEDGING");

   g_hEMAFast = iMA(_Symbol, InpSignalTF, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMASlow = iMA(_Symbol, InpSignalTF, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hRSI     = iRSI(_Symbol, InpSignalTF, InpRSIPeriod, PRICE_CLOSE);

   if (g_hEMAFast == INVALID_HANDLE || g_hEMASlow == INVALID_HANDLE || g_hRSI == INVALID_HANDLE)
   {
      Print("INIT FAILED: indicator handles");
      return INIT_FAILED;
   }

   ResetSignal();
   g_consecLoss    = 0;
   g_pauseBarCount = 0;

   ArrayResize(g_changeHistory, InpSLHistoryTrades);
   ArrayInitialize(g_changeHistory, 0.0);
   g_historyIndex = 0;
   g_historyCount = 0;

   PrintFormat("FlipTrail v6.35 | %s | TF=%s | SeedRisk=%.1f%% BurstRisk=%.1f%% | "
               "Seed=%d → ImmediateBurst=%d trades | "
               "IndivTP=%.3f%%/round | BurstSL=%.3f%% | PeakKeep=%.0f%% | MaxBursts=%d | "
               "TimedProfit=%dmin | TimedLoss=%dmin@%.1f%% | DynSLfloor=%.2f%% | "
               "EMA%d/EMA%d RSI(%d) | Magic=%lld",
               _Symbol, EnumToString(InpSignalTF), InpRiskPct, InpBurstRiskPct,
               InpSeedCount, InpBurstCount,
               InpBurstTPPct, InpBurstSLPct, InpPeakKeepPct, InpMaxBursts,
               InpBasketMaxProfitMins, InpBasketMaxLossMins, InpBasketLossPct,
               InpSLFloorPct, InpEMAFast, InpEMASlow, InpRSIPeriod,
               InpMagicNumber);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   if (g_hEMAFast != INVALID_HANDLE) IndicatorRelease(g_hEMAFast);
   if (g_hEMASlow != INVALID_HANDLE) IndicatorRelease(g_hEMASlow);
   if (g_hRSI     != INVALID_HANDLE) IndicatorRelease(g_hRSI);

   PrintFormat("FlipTrail v6.35 deinit | phase=%d | burstRound=%d | consecLoss=%d | reason=%d",
               (int)g_phase, g_burstRound, g_consecLoss, reason);
}

void OnTick()
{
   datetime bt     = iTime(_Symbol, InpSignalTF, 0);
   bool     newBar = (bt != 0 && bt != g_lastBarTime);
   if (newBar) g_lastBarTime = bt;

   UpdateDashboard();

   switch (g_phase)
   {
      case PHASE_SEED:
         CheckSeedPhase();
         break;
      case PHASE_BURST:
         CheckExit();
         break;
      case PHASE_NONE:
      default:
         if (newBar) TrySeedEntry();
         break;
   }
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     request,
                        const MqlTradeResult&      result)
{
   // State managed entirely in OnTick — no action needed here
}
