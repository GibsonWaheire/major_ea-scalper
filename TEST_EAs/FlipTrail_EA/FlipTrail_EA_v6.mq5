//+------------------------------------------------------------------+
//|  FlipTrail_EA_v6.mq5  v6.30                                      |
//|  Margin Scalper — Seed Confirmation + Burst Mode                 |
//|                                                                   |
//|  PHASE 1 (SEED):                                                 |
//|    Open InpSeedCount trades on M1 bar signal (EMA/RSI filtered). |
//|    Store g_signalPrice = avg fill (stable trend reference).      |
//|    Wait per-tick for seedMovePct >= InpSeedTPPct (0.01%).        |
//|    Confirmed → open burst. DynSL aborts seed if reversal early.  |
//|                                                                   |
//|  PHASE 2 (BURST):                                                |
//|    Open InpBurstCount extra trades at confirmed direction.       |
//|    Per-tick exit priority:                                        |
//|      1. Emergency: basket loss >= InpMaxLossPct% equity.         |
//|      2. Individual TP: each position closed at InpBurstTPPct%.   |
//|      3. Trend continuation: all IndivTP + signal still running   |
//|         → new burst round (up to InpMaxBursts).                 |
//|      4. Peak pullback: signalMove < peak * InpPeakKeepPct/100.  |
//|      5. DynSL: signalMove <= -DynSLThreshold.                   |
//|      6. Time gate: elapsed >= InpBurstMaxSec → close profitable. |
//+------------------------------------------------------------------+
#property copyright "FlipTrail EA v6"
#property link      ""
#property version   "6.30"
#property description "FlipTrail v6.30: Seed-confirmed burst margin scalper, per-tick individual TP"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

enum BasketPhase { PHASE_NONE=0, PHASE_SEED=1, PHASE_BURST=2 };

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Basket ==="
input double InpRiskPct           = 10.0;  // RiskPct: % equity per trade
input double InpMinLot            = 0.01;  // MinLot
input double InpMaxLot            = 50.0;  // MaxLot
input long   InpMagicNumber       = 116300;// MagicNumber (v6.3)
input int    InpMaxSlippagePoints = 30;    // MaxSlippagePoints
input int    InpMaxSpreadPoints   = 50;    // MaxSpreadPoints (0=off, seed only)

input group "=== Seed Phase ==="
input int    InpSeedCount         = 2;     // SeedCount: trades to confirm trend
input double InpSeedTPPct         = 0.01;  // SeedTPPct: % move from signal to trigger burst

input group "=== Burst Phase ==="
input int    InpBurstCount        = 8;     // BurstCount: extra trades after seed confirms
input double InpBurstTPPct        = 0.02;  // BurstTPPct: per-position individual TP%
input double InpPeakKeepPct       = 80.0;  // PeakKeepPct: close all if pullback to X% of peak
input int    InpBurstMaxSec       = 3;     // BurstMaxSec: time gate seconds (close profitable)
input double InpMaxLossPct        = 0.10;  // MaxLossPct: emergency close if basket loses X% equity
input int    InpMaxBursts         = 3;     // MaxBursts: max trend-continuation burst rounds

input group "=== Dynamic SL ==="
input int    InpSLHistoryTrades   = 20;    // SLHistoryTrades: circular buffer size
input double InpSLFloorPct        = 0.12;  // SLFloorPct: DynSL minimum %

input group "=== Entry Filter ==="
input int    InpEMAFast           = 5;     // EMA fast period (M1)
input int    InpEMASlow           = 13;    // EMA slow period (M1)
input int    InpRSIPeriod         = 7;     // RSI period (M1)
input double InpRSIBuyMax         = 65.0;  // RSI max allowed for BUY
input double InpRSISellMin        = 35.0;  // RSI min allowed for SELL
input int    InpMinBodyPct        = 30;    // Min candle body% of range (0=off)

input group "=== NY Session ==="
input bool   InpNYFilter          = false; // NYFilter: restrict entries to NY session
input int    InpNYStartHour       = 13;    // NYStartHour (UTC)
input int    InpNYEndHour         = 21;    // NYEndHour (UTC)

input group "=== Consecutive Loss Pause ==="
input int    InpMaxConsecLoss     = 3;     // MaxConsecLoss: pause after N losses
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

bool IsNYSession()
{
   if (!InpNYFilter) return true;
   int h = (int)((TimeCurrent() % 86400) / 3600);
   return (h >= InpNYStartHour && h < InpNYEndHour);
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

   PrintFormat("[v6.3] CloseAll [%s] | %d positions", reason, total);
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
      PrintFormat("[v6.3] CloseProfitable [%s] | closed=%d of %d", reason, closed, total);
}

// Close all positions that individually hit InpBurstTPPct%
// Returns number of positions closed
int CloseIndividualTP()
{
   g_sym.RefreshRates();
   double ask = g_sym.Ask();
   double bid = g_sym.Bid();

   ulong tickets[];
   int   total = 0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;

      double entryPrice = g_pos.PriceOpen();
      if (entryPrice <= 0) continue;

      double changePct = (g_pos.PositionType() == POSITION_TYPE_BUY)
                         ? (bid - entryPrice) / entryPrice * 100.0
                         : (entryPrice - ask) / entryPrice * 100.0;

      if (changePct >= InpBurstTPPct)
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
         ok = g_trade.Buy(lot, _Symbol, ask, 0, 0, "FTV63");
      else
         ok = g_trade.Sell(lot, _Symbol, bid, 0, 0, "FTV63");

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
   double lot      = CalcDynamicLot();
   double entrySum = 0.0;
   int    opened   = OpenTrades(InpBurstCount, g_basketDir, lot, entrySum);

   g_phase         = PHASE_BURST;
   g_burstOpenTime = TimeCurrent();
   g_burstRound++;
   g_timeGateFired = false;

   PrintFormat("[Burst OPEN] round=%d/%d | %d/%d trades | lot=%.2f | signalPrice=%.5f | "
               "IndivTP=%.3f%% | PeakKeep=%.0f%% | TimeGate=%ds",
               g_burstRound, InpMaxBursts, opened, InpBurstCount, lot,
               g_signalPrice, InpBurstTPPct, InpPeakKeepPct, InpBurstMaxSec);
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

   // Emergency loss in seed phase
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
         PrintFormat("[Seed] Emergency loss %.3f%% >= %.3f%% — abort seeds", lossPct, InpMaxLossPct);
         CloseAllOurPositions("SeedEmergencyLoss");
         RecordHistory(seedMovePct);
         g_consecLoss++;
         ResetSignal();
         return;
      }
   }

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

   // ── 2. Individual TP per position ─────────────────────────────────────────
   int indivClosed = CloseIndividualTP();
   if (indivClosed > 0)
   {
      int remaining = CountOurPositions();
      PrintFormat("[Exit] IndivTP closed=%d | remaining=%d | signalMove=%.3f%%",
                  indivClosed, remaining, signalMovePct);

      if (remaining == 0)
      {
         RecordHistory(signalMovePct);
         g_consecLoss = 0;

         // Trend continuation — re-open burst if signal still positive
         if (g_burstRound < InpMaxBursts && signalMovePct >= InpSeedTPPct)
         {
            PrintFormat("[Burst] Trend continuation round %d/%d | signalMove=%.3f%%",
                        g_burstRound + 1, InpMaxBursts, signalMovePct);
            OpenBurst();
         }
         else
         {
            PrintFormat("[Burst] Done | round=%d/%d | signalMove=%.3f%%",
                        g_burstRound, InpMaxBursts, signalMovePct);
            ResetSignal();
         }
         return;
      }
   }

   // ── 3. Peak pullback ──────────────────────────────────────────────────────
   if (InpPeakKeepPct > 0 && g_peakSignalMovePct > InpSeedTPPct)
   {
      double keepThreshold = g_peakSignalMovePct * InpPeakKeepPct / 100.0;
      if (signalMovePct < keepThreshold)
      {
         PrintFormat("[Exit] PeakPullback: signalMove=%.3f%% < keepAt=%.3f%% (peak=%.3f%% * %.0f%%)",
                     signalMovePct, keepThreshold, g_peakSignalMovePct, InpPeakKeepPct);
         CloseAllOurPositions("PeakPullback");
         RecordHistory(signalMovePct);
         if (signalMovePct <= 0) g_consecLoss++;
         ResetSignal();
         return;
      }
   }

   // ── 4. DynSL from signal price ────────────────────────────────────────────
   double dynSL = GetDynamicThreshold();
   if (signalMovePct <= -dynSL)
   {
      PrintFormat("[Exit] DynSL: signalMove=%.3f%% <= -%.3f%%", signalMovePct, dynSL);
      CloseAllOurPositions("DynSL");
      RecordHistory(signalMovePct);
      g_consecLoss++;
      ResetSignal();
      return;
   }

   // ── 5. Time gate — close profitable, hold rest ────────────────────────────
   if (!g_timeGateFired && InpBurstMaxSec > 0)
   {
      int elapsed = (int)(TimeCurrent() - g_burstOpenTime);
      if (elapsed >= InpBurstMaxSec)
      {
         g_timeGateFired = true;
         PrintFormat("[Exit] TimeGate %ds elapsed — closing profitable (signalMove=%.3f%%)",
                     elapsed, signalMovePct);
         CloseAllProfitable("TimeGate");
         // Hold remaining positions — other exit conditions continue next tick
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
   if (!IsNYSession())             return;

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

   double c  = iClose(_Symbol, PERIOD_M1, 1);
   double o  = iOpen (_Symbol, PERIOD_M1, 1);
   double hi = iHigh (_Symbol, PERIOD_M1, 1);
   double lo = iLow  (_Symbol, PERIOD_M1, 1);
   if (c == o) return;

   ENUM_ORDER_TYPE dir = (c > o) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if (InpMinBodyPct > 0)
   {
      double range = hi - lo;
      double body  = MathAbs(c - o);
      if (range > 0 && (body / range) * 100.0 < (double)InpMinBodyPct) return;
   }

   if (!CheckIndicatorFilter(dir)) return;

   // Open seed trades
   double lot      = CalcDynamicLot();
   double entrySum = 0.0;
   int    opened   = OpenTrades(InpSeedCount, dir, lot, entrySum);

   if (opened > 0)
   {
      g_basketDir         = dir;
      g_phase             = PHASE_SEED;
      g_signalPrice       = entrySum / opened;
      g_peakSignalMovePct = 0.0;
      g_burstRound        = 0;
      g_timeGateFired     = false;

      PrintFormat("[Seed OPEN] %s | %d/%d trades | lot=%.2f | signalPrice=%.5f | "
                  "waiting %.3f%% → burst of %d | DynSL=%.3f%%",
                  (dir==ORDER_TYPE_BUY?"BUY":"SELL"),
                  opened, InpSeedCount, lot, g_signalPrice,
                  InpSeedTPPct, InpBurstCount, GetDynamicThreshold());
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

   g_hEMAFast = iMA(_Symbol, PERIOD_M1, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMASlow = iMA(_Symbol, PERIOD_M1, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hRSI     = iRSI(_Symbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);

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

   PrintFormat("FlipTrail v6.30 | %s | Risk=%.1f%% | "
               "Seed=%d @ %.3f%% → Burst=%d trades | "
               "IndivTP=%.3f%% | PeakKeep=%.0f%% | TimeGate=%ds | "
               "MaxBursts=%d | EmergLoss=%.2f%% | DynSL floor=%.2f%% | "
               "EMA%d/EMA%d RSI(%d) | Magic=%lld",
               _Symbol, InpRiskPct,
               InpSeedCount, InpSeedTPPct, InpBurstCount,
               InpBurstTPPct, InpPeakKeepPct, InpBurstMaxSec,
               InpMaxBursts, InpMaxLossPct, InpSLFloorPct,
               InpEMAFast, InpEMASlow, InpRSIPeriod,
               InpMagicNumber);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if (g_hEMAFast != INVALID_HANDLE) IndicatorRelease(g_hEMAFast);
   if (g_hEMASlow != INVALID_HANDLE) IndicatorRelease(g_hEMASlow);
   if (g_hRSI     != INVALID_HANDLE) IndicatorRelease(g_hRSI);

   PrintFormat("FlipTrail v6.30 deinit | phase=%d | burstRound=%d | consecLoss=%d | reason=%d",
               (int)g_phase, g_burstRound, g_consecLoss, reason);
}

void OnTick()
{
   datetime bt     = iTime(_Symbol, PERIOD_M1, 0);
   bool     newBar = (bt != 0 && bt != g_lastBarTime);
   if (newBar) g_lastBarTime = bt;

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
