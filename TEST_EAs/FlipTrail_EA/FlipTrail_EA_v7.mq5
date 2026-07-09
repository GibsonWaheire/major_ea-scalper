//+------------------------------------------------------------------+
//|  FlipTrail_EA_v7.mq5  v7.00                                      |
//|  Gold Scalper — Pyramid Entry + 3-Tier Partial TP               |
//|                                                                   |
//|  PHASE 1 (NONE):                                                 |
//|    Wait for bar signal on SignalTF. Open 1 base trade.           |
//|                                                                   |
//|  PHASE 2 (ACTIVE):                                               |
//|    Pyramid adds: every InpPyramidStep% favorable move adds 1     |
//|    trade (up to InpPyramidMax). Stops adding if basket losing.  |
//|                                                                   |
//|    Exit priority (per tick):                                      |
//|      1. Emergency basket loss (InpMaxLossPct).                   |
//|      2. TP Tiers (from signal price):                            |
//|           TP1 (+InpTP1Pct%):  close InpTP1ClosePct% of pos.     |
//|           BE  (+TP1+BEOffset%): move remaining SL to breakeven.  |
//|           TP2 (+InpTP2Pct%):  close InpTP2ClosePct% of remain,  |
//|                                trail rest at InpTrailPoints pts. |
//|      3. Timed profit: basket in profit after X mins → close all. |
//|      4. Timed loss: basket losing X% after Y mins → close all.  |
//|      5. Peak pullback: close profitable, hold rest for DynSL.   |
//|      6. Hard SL: backstop at InpHardSLPct% from signal.         |
//|      7. Time gate: close ALL after InpBurstMaxSec seconds.       |
//+------------------------------------------------------------------+
#property copyright "FlipTrail EA v7"
#property link      ""
#property version   "7.00"
#property description "FlipTrail v7.00: Pyramid entry + 3-tier partial TP (TP1 33% / BE / TP2 50% + trail)"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

enum BasketPhase { PHASE_NONE=0, PHASE_ACTIVE=1 };

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Basket ==="
input ENUM_TIMEFRAMES InpSignalTF          = PERIOD_M5;  // SignalTF: M5 bar signal (H1 trend gate applied)
input double          InpRiskPct           = 5.0;        // RiskPct: % equity risk for base trade
input double          InpMinLot            = 0.01;       // MinLot
input double          InpMaxLot            = 50.0;       // MaxLot
input long            InpMagicNumber       = 117000;     // MagicNumber (v7)
input int             InpMaxSlippagePoints = 30;         // MaxSlippagePoints
input int             InpMaxSpreadPoints   = 0;          // MaxSpreadPoints (0=off, entry only)

input group "=== Trend Gate ==="
input ENUM_TIMEFRAMES InpTrendTF           = PERIOD_H1;  // TrendTF: HTF for trend confirmation
input int             InpTrendEMA          = 50;         // TrendEMA: EMA period on TrendTF (H1 EMA50)

input group "=== Pyramid Entry ==="
input int    InpPyramidMax     = 5;      // PyramidMax: max adds after base trade (total = 1 + max)
input double InpPyramidStep    = 0.015;  // PyramidStep: % move from last add to trigger next (XAU ~45pts)
input double InpPyramidRiskPct = 3.0;   // PyramidRiskPct: % equity risk per pyramid add

input group "=== TP Tiers ==="
input double InpTP1Pct        = 0.100;  // TP1Pct: % from signal → close first batch (XAU ~$4.00 at $4000)
input double InpTP1ClosePct   = 33.0;   // TP1ClosePct: % of open positions to close at TP1
input double InpBEOffsetPct   = 0.025;  // BEOffsetPct: extra % beyond TP1 to move SL to breakeven
input double InpTP2Pct        = 0.250;  // TP2Pct: % from signal → close second batch + trail (XAU ~$10.00, matches HardSL 1:1)
input double InpTP2ClosePct   = 50.0;   // TP2ClosePct: % of remaining positions to close at TP2
input int    InpTrailPoints   = 200;    // TrailPoints: trail remaining after TP2 (XAU: 200pts = $2.00)

input group "=== Basket Protection ==="
input double InpFlashTPPct         = 0.5;   // FlashTPPct: close ALL if basket profit >= X% equity (0=off)
input double InpHardSLPct          = 0.25;  // HardSLPct: basket SL% from signal (0 = DynSL floor only)
input double InpPeakKeepPct        = 50.0;  // PeakKeepPct: close profitable if pullback to X% of peak (50=needs real reversal)
input int    InpBurstMaxSec        = 0;     // TimeGateSec: close ALL after X seconds (0=off)
input double InpMaxLossPct         = 3.0;   // MaxLossPct: emergency close if basket loses X% equity (0=off); $3000 acct = $90
input int    InpBasketMaxLossMins  = 3;     // BasketMaxLossMins: close if still losing after X mins (0=off)
input double InpBasketLossPct      = 10.0;  // BasketLossPct: min basket loss% of equity for timed loss
input int    InpBasketMaxProfitMins= 15;    // BasketMaxProfitMins: close if in net profit after X mins (0=off)

input group "=== Post-TP1 Re-entry ==="
input int    InpTP1TimerSecs    = 30;    // TP1TimerSecs: seconds after TP1 to close most profitable (0=off)
input double InpTP1TimerMinPct  = 0.03;  // TP1TimerMinPct: min profit% above signal to qualify
input int    InpLimitOffsetPts  = 10;    // LimitOffsetPts: points offset for re-entry limit order
input int    InpLimitExpirySecs = 60;    // LimitExpirySecs: cancel limit if unfilled after X seconds

input group "=== Dynamic SL ==="
input int    InpSLHistoryTrades = 20;    // SLHistoryTrades: circular buffer size
input double InpSLFloorPct      = 0.18;  // SLFloorPct: DynSL minimum %

input group "=== Entry Filter ==="
input bool   InpUseEntryFilter  = false; // UseEntryFilter: gate entries on EMA+RSI (false=every bar)
input int    InpEMAFast         = 5;     // EMA fast period (SignalTF)
input int    InpEMASlow         = 13;    // EMA slow period (SignalTF)
input int    InpRSIPeriod       = 7;     // RSI period (SignalTF)
input double InpRSIBuyMax       = 75.0;  // RSI max allowed for BUY entry
input double InpRSISellMin      = 25.0;  // RSI min allowed for SELL entry
input int    InpMinBodyPct      = 0;     // Min candle body% of range (0=off)

input group "=== Progressive Trail ==="
input double InpProgTrailStartPct = 0.05;  // ProgTrailStartPct: start trailing when profit% reaches this (0=off, match TP1)
input double InpProgLockPct       = 50.0;  // ProgLockPct: % of peak profit to lock in via SL (50 = lock half the peak)

input group "=== Volatile Spike Exit ==="
input int    InpSpikeMaxSecs      = 120;    // SpikeMaxSecs: window after open to watch for spike (0=off)
input double InpSpikeMinProfitPct = 0.08;  // SpikeMinProfitPct: min profit% to qualify (above TP1)
input double InpSpikeMoveSpeed    = 0.001; // SpikeMoveSpeed: min %/sec to flag as spike (0.08% in <80s)
input double InpSpikeRangeMult    = 2.0;   // SpikeRangeMult: current bar range must be > N× avg bars (2=extreme only)
input int    InpSpikeAvgBars      = 5;     // SpikeAvgBars: bars to average for range comparison

input group "=== Consecutive Loss Pause ==="
input int    InpMaxConsecLoss   = 0;     // MaxConsecLoss: pause after N losses (0=off)
input int    InpPauseBars       = 5;     // PauseBars: SignalTF bars to wait before resuming

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
double          g_signalPrice       = 0.0;
double          g_peakSignalMovePct = 0.0;
datetime        g_basketOpenTime    = 0;
bool            g_timeGateFired     = false;

// Pyramid state
int    g_pyramidCount = 0;    // number of pyramid adds fired so far
double g_lastAddPrice = 0.0;  // fill price of the most recent opened trade

// TP tier state
bool     g_tp1Done          = false;
bool     g_beDone           = false;
bool     g_tp2Done          = false;
double   g_trailPeak        = 0.0;    // peak price for trailing SL calculation
datetime g_tp1Time          = 0;      // timestamp when TP1 fired
ulong    g_tp1PendingTicket = 0;      // pending re-entry limit order after TP1

// Dynamic SL history
double g_changeHistory[];
int    g_historyIndex = 0;
int    g_historyCount = 0;

// Volatile spike exit
bool g_spikeDone = false;

// Consecutive loss pause
int g_consecLoss    = 0;
int g_pauseBarCount = 0;

// Indicator handles
int g_hEMAFast   = INVALID_HANDLE;
int g_hEMASlow   = INVALID_HANDLE;
int g_hRSI       = INVALID_HANDLE;
int g_hTrendEMA  = INVALID_HANDLE;

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

// Base trade lot — sized on InpRiskPct vs DynSL threshold
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

// Pyramid add lot — sized on InpPyramidRiskPct vs InpHardSLPct
double CalcPyramidLot()
{
   double threshold = (InpHardSLPct > 0) ? InpHardSLPct : GetDynamicThreshold();
   g_sym.RefreshRates();
   double price = (g_sym.Ask() + g_sym.Bid()) / 2.0;
   if (price <= 0) return NormalizeLot(InpMinLot);

   int slPts = (int)MathRound(threshold / 100.0 * price / _Point);
   if (slPts <= 0) return NormalizeLot(InpMinLot);

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpPyramidRiskPct / 100.0;
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tickVal <= 0 || tickSize <= 0) return NormalizeLot(InpMinLot);

   double slMoney = (slPts * _Point / tickSize) * tickVal;
   if (slMoney <= 0) return NormalizeLot(InpMinLot);

   return NormalizeLot(riskMoney / slMoney);
}

// EMA alignment — used for dashboard display only (NOT for exit logic)
bool CheckEMAAligned(ENUM_ORDER_TYPE dir)
{
   if (g_hEMAFast == INVALID_HANDLE || g_hEMASlow == INVALID_HANDLE) return true;
   double ef[1], es[1];
   if (CopyBuffer(g_hEMAFast, 0, 0, 1, ef) < 1) return true;
   if (CopyBuffer(g_hEMASlow, 0, 0, 1, es) < 1) return true;
   return (dir == ORDER_TYPE_BUY) ? (ef[0] > es[0]) : (ef[0] < es[0]);
}

// EMA + RSI filter — gates base entries when InpUseEntryFilter = true
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
      PrintFormat("Filter[RSI%d=%.1f]: %s — skip",
                  InpRSIPeriod, rsiVal[0],
                  (dir==ORDER_TYPE_BUY?"above buy-max":"below sell-min"));

   return emaOK && rsiOK;
}

void UpdateDashboard()
{
   string phase = (g_phase == PHASE_NONE ? "IDLE" : "ACTIVE");
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
      if (g_basketOpenTime > 0)
         elapsed = (int)(TimeCurrent() - g_basketOpenTime);
   }

   double dynSL    = GetDynamicThreshold();
   if (InpHardSLPct > 0) dynSL = MathMin(dynSL, InpHardSLPct);
   bool   emaAlign = CheckEMAAligned(g_basketDir);

   string tp1s  = g_tp1Done ? "+" : "o";
   string bes   = g_beDone  ? "+" : "o";
   string tp2s  = g_tp2Done ? "+" : "o";
   string trails = (g_tp2Done && positions > 0) ? "*" : "o";

   string nextAction = "waiting for signal";
   if (g_phase == PHASE_ACTIVE)
   {
      if (!g_tp1Done)      nextAction = StringFormat("TP1  +%.3f%%", InpTP1Pct);
      else if (!g_beDone)  nextAction = StringFormat("BE   +%.3f%%", InpTP1Pct + InpBEOffsetPct);
      else if (!g_tp2Done) nextAction = StringFormat("TP2  +%.3f%%", InpTP2Pct);
      else                 nextAction = StringFormat("TRAIL %d pts", InpTrailPoints);
   }

   Comment(StringFormat(
      "== FlipTrail v7.00 ==================\n"
      " Phase   : %-6s  %s\n"
      " Pos     : %d open   Pyramid: %d / %d adds\n"
      " Signal  : %.5f\n"
      " Move    : %+.3f%%   Peak: +%.3f%%\n"
      " Tiers   : TP1[%s] BE[%s] TP2[%s] Trail[%s]\n"
      " Next    : %s\n"
      " Hard SL : -%.3f%%\n"
      " Basket  : %+.2f  (%+.2f%%)\n"
      " Elapsed : %ds\n"
      " EMA     : %s (display only)\n"
      " TF      : %s   EMA%d/%d  RSI%d\n"
      "=====================================",
      phase, (g_phase != PHASE_NONE ? dir : ""),
      positions, g_pyramidCount, InpPyramidMax,
      g_signalPrice,
      signalMove, g_peakSignalMovePct,
      tp1s, bes, tp2s, trails,
      nextAction,
      dynSL,
      totalPnL, pnlPct,
      elapsed,
      emaAlign ? "aligned" : "reversing",
      EnumToString(InpSignalTF), InpEMAFast, InpEMASlow, InpRSIPeriod
   ));
}

//──────────────────────────────────────────────────────────────────────────────
// STATE MANAGEMENT
//──────────────────────────────────────────────────────────────────────────────
void CancelPendingReentry()
{
   if (g_tp1PendingTicket == 0) return;
   if (OrderSelect(g_tp1PendingTicket))
      g_trade.OrderDelete(g_tp1PendingTicket);
   g_tp1PendingTicket = 0;
}

void ResetSignal()
{
   CancelPendingReentry();
   g_phase             = PHASE_NONE;
   g_signalPrice       = 0.0;
   g_peakSignalMovePct = 0.0;
   g_basketOpenTime    = 0;
   g_timeGateFired     = false;
   g_pyramidCount      = 0;
   g_lastAddPrice      = 0.0;
   g_tp1Done           = false;
   g_beDone            = false;
   g_tp2Done           = false;
   g_trailPeak         = 0.0;
   g_tp1Time           = 0;
   g_tp1PendingTicket  = 0;
   g_spikeDone         = false;
}

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

   PrintFormat("[v7.00] CloseAll [%s] | %d positions", reason, total);
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
      PrintFormat("[v7.00] CloseProfitable [%s] | closed=%d of %d", reason, closed, total);
}

// Close the N most profitable positions. Returns count closed.
int CloseByCount(int countToClose, const string reason)
{
   ulong  tickets[];
   double profits[];
   int    total = 0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;
      ArrayResize(tickets, total + 1);
      ArrayResize(profits, total + 1);
      tickets[total] = g_pos.Ticket();
      profits[total] = g_pos.Profit();
      total++;
   }

   if (total == 0) return 0;
   countToClose = MathMin(countToClose, total);

   // Sort descending by profit — close most profitable first
   for (int a = 0; a < total - 1; a++)
      for (int b = a + 1; b < total; b++)
         if (profits[b] > profits[a])
         {
            double tp = profits[a]; profits[a] = profits[b]; profits[b] = tp;
            ulong  tt = tickets[a]; tickets[a] = tickets[b]; tickets[b] = tt;
         }

   int closed = 0;
   for (int j = 0; j < countToClose; j++)
      for (int attempt = 0; attempt < 3; attempt++)
      {
         if (g_trade.PositionClose(tickets[j], InpMaxSlippagePoints)) { closed++; break; }
         Sleep(50);
      }

   PrintFormat("[%s] closed %d of %d (by profit rank)", reason, closed, total);
   return closed;
}

// Move SL to entry price (breakeven) for all remaining positions.
// Only moves SL in the favorable direction — never worsens it.
void SetBreakeven()
{
   int moved = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;

      double openPrice = NormalizeDouble(g_pos.PriceOpen(), _Digits);
      double curSL     = g_pos.StopLoss();
      bool   needsMove = false;

      if (g_pos.PositionType() == POSITION_TYPE_BUY)
         needsMove = (curSL < openPrice - _Point);   // SL below entry → move up to entry
      else
         needsMove = (curSL == 0.0 || curSL > openPrice + _Point); // SL above entry → move down

      if (needsMove)
      {
         g_trade.PositionModify(g_pos.Ticket(), openPrice, g_pos.TakeProfit());
         moved++;
      }
   }
   PrintFormat("[BE] Breakeven SL set on %d positions", moved);
}

// Update trailing SL on all remaining positions after TP2.
// Tracks peak price and moves SL up (buy) / down (sell) only when improved.
void UpdateTrailing()
{
   g_sym.RefreshRates();

   // Keep track of the best price reached
   if (g_basketDir == ORDER_TYPE_BUY)
   {
      if (g_sym.Bid() > g_trailPeak) g_trailPeak = g_sym.Bid();
   }
   else
   {
      if (g_trailPeak == 0.0 || g_sym.Ask() < g_trailPeak) g_trailPeak = g_sym.Ask();
   }

   double trailSL = (g_basketDir == ORDER_TYPE_BUY)
                    ? NormalizeDouble(g_trailPeak - InpTrailPoints * _Point, _Digits)
                    : NormalizeDouble(g_trailPeak + InpTrailPoints * _Point, _Digits);

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;

      double curSL    = g_pos.StopLoss();
      bool   improved = (g_basketDir == ORDER_TYPE_BUY)
                        ? (trailSL > curSL + _Point)
                        : (curSL == 0.0 || trailSL < curSL - _Point);

      if (improved)
         g_trade.PositionModify(g_pos.Ticket(), trailSL, g_pos.TakeProfit());
   }
}

// Open a single trade with broker-side SL. Returns fill price, or 0.0 on failure.
// slPrice = 0 means no SL (avoid if possible — use InpHardSLPct)
double OpenOneTrade(ENUM_ORDER_TYPE dir, double lot, const string tag, double slPrice = 0.0)
{
   g_sym.RefreshRates();

   bool ok = (dir == ORDER_TYPE_BUY)
             ? g_trade.Buy (lot, _Symbol, g_sym.Ask(), slPrice, 0, tag)
             : g_trade.Sell(lot, _Symbol, g_sym.Bid(), slPrice, 0, tag);

   PrintResult(StringFormat("[%s] v7 %s lot=%.2f sl=%.5f", _Symbol, tag, lot, slPrice));

   if (g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
      return g_trade.ResultPrice();

   return 0.0;
}

//──────────────────────────────────────────────────────────────────────────────
// BASE ENTRY — fires on each new SignalTF bar
//──────────────────────────────────────────────────────────────────────────────
void TryBaseEntry()
{
   if (g_phase != PHASE_NONE)   return;
   if (CountOurPositions() > 0) return;

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

   // Spread check
   if (InpMaxSpreadPoints > 0)
   {
      g_sym.RefreshRates();
      int sp = (int)MathRound((g_sym.Ask() - g_sym.Bid()) / _Point);
      if (sp > InpMaxSpreadPoints)
      {
         PrintFormat("Spread %d > %d — skip entry", sp, InpMaxSpreadPoints);
         return;
      }
   }

   // Bar close direction signal
   double c  = iClose(_Symbol, InpSignalTF, 1);
   double o  = iOpen (_Symbol, InpSignalTF, 1);
   double hi = iHigh (_Symbol, InpSignalTF, 1);
   double lo = iLow  (_Symbol, InpSignalTF, 1);
   if (c == o) return;

   ENUM_ORDER_TYPE dir = (c > o) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   // H1 trend gate — only trade with the HTF trend
   if (g_hTrendEMA != INVALID_HANDLE)
   {
      double trendBuf[1];
      if (CopyBuffer(g_hTrendEMA, 0, 1, 1, trendBuf) == 1)
      {
         g_sym.RefreshRates();
         double midPrice = (g_sym.Ask() + g_sym.Bid()) / 2.0;
         bool trendOK = (dir == ORDER_TYPE_BUY) ? (midPrice > trendBuf[0])
                                                 : (midPrice < trendBuf[0]);
         if (!trendOK) return;
      }
   }

   // Min candle body filter
   if (InpMinBodyPct > 0)
   {
      double range = hi - lo;
      double body  = MathAbs(c - o);
      if (range > 0 && (body / range) * 100.0 < (double)InpMinBodyPct) return;
   }

   // EMA + RSI entry gate (optional)
   if (InpUseEntryFilter && !CheckIndicatorFilter(dir)) return;

   // Compute broker-side SL price from entry price
   g_sym.RefreshRates();
   double refPrice = (dir == ORDER_TYPE_BUY) ? g_sym.Ask() : g_sym.Bid();
   double slOffset = (InpHardSLPct > 0) ? InpHardSLPct : InpSLFloorPct;
   double baseSL   = (dir == ORDER_TYPE_BUY)
                     ? NormalizeDouble(refPrice * (1.0 - slOffset / 100.0), _Digits)
                     : NormalizeDouble(refPrice * (1.0 + slOffset / 100.0), _Digits);

   // Open base trade with broker-side SL
   double lot  = CalcDynamicLot();
   double fill = OpenOneTrade(dir, lot, "FTV700-base", baseSL);

   if (fill > 0.0)
   {
      g_basketDir         = dir;
      g_phase             = PHASE_ACTIVE;
      g_signalPrice       = fill;
      g_lastAddPrice      = fill;
      g_peakSignalMovePct = 0.0;
      g_basketOpenTime    = TimeCurrent();
      g_pyramidCount      = 0;
      g_tp1Done           = false;
      g_beDone            = false;
      g_tp2Done           = false;
      g_trailPeak         = 0.0;
      g_timeGateFired     = false;

      PrintFormat("[BASE OPEN] %s | lot=%.2f | signal=%.5f | "
                  "pyramid: up to %d adds @ %.3f%% steps | "
                  "TP1=+%.3f%% BE=+%.3f%% TP2=+%.3f%% Trail=%dpts | HardSL=%.3f%%",
                  (dir==ORDER_TYPE_BUY?"BUY":"SELL"), lot, fill,
                  InpPyramidMax, InpPyramidStep,
                  InpTP1Pct, InpTP1Pct + InpBEOffsetPct, InpTP2Pct, InpTrailPoints,
                  InpHardSLPct);
   }
}

//──────────────────────────────────────────────────────────────────────────────
// PYRAMID — add one trade per InpPyramidStep% favorable move
//──────────────────────────────────────────────────────────────────────────────
void TryPyramidAdd()
{
   if (g_pyramidCount >= InpPyramidMax) return;
   if (g_signalPrice  <= 0.0)           return;

   g_sym.RefreshRates();
   double currentPrice = (g_basketDir == ORDER_TYPE_BUY) ? g_sym.Ask() : g_sym.Bid();

   // Step measured from last add, expressed as % of signal price for consistency
   double moveFromLast = (g_basketDir == ORDER_TYPE_BUY)
                         ? (currentPrice - g_lastAddPrice) / g_signalPrice * 100.0
                         : (g_lastAddPrice - currentPrice) / g_signalPrice * 100.0;

   if (moveFromLast < InpPyramidStep) return;

   // Do not add to a losing basket — only pyramid into winners
   double totalPnL = 0.0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;
      totalPnL += g_pos.Profit() + g_pos.Swap();
   }
   if (totalPnL < 0.0) return;

   // SL anchored to signal price — same reference as code-based HardSL
   double slOffset = (InpHardSLPct > 0) ? InpHardSLPct : InpSLFloorPct;
   double addSL    = (g_basketDir == ORDER_TYPE_BUY)
                     ? NormalizeDouble(g_signalPrice * (1.0 - slOffset / 100.0), _Digits)
                     : NormalizeDouble(g_signalPrice * (1.0 + slOffset / 100.0), _Digits);

   double lot  = CalcPyramidLot();
   double fill = OpenOneTrade(g_basketDir, lot, "FTV700-add", addSL);

   if (fill > 0.0)
   {
      g_pyramidCount++;
      g_lastAddPrice = fill;
      PrintFormat("[PYRAMID ADD %d/%d] %s | lot=%.2f | fill=%.5f | moveFromLast=%.3f%%",
                  g_pyramidCount, InpPyramidMax,
                  (g_basketDir==ORDER_TYPE_BUY?"BUY":"SELL"),
                  lot, fill, moveFromLast);
   }
}

// Progressive trail — anchored to signal price, starts as soon as profit% >= threshold.
// Locks in InpProgLockPct% of the peak move every tick. Runs independently of TP tiers.
// SL only ever moves in the favorable direction — never worsens.
void UpdateProgressiveTrail()
{
   if (InpProgTrailStartPct <= 0)                               return;
   if (g_signalPrice <= 0)                                      return;
   if (g_peakSignalMovePct < InpProgTrailStartPct)              return; // not enough profit yet

   // SL = signal price + (peak move × lock%) — anchored to signal, not current price
   double lockMovePct = g_peakSignalMovePct * InpProgLockPct / 100.0;
   double newSL = (g_basketDir == ORDER_TYPE_BUY)
                  ? NormalizeDouble(g_signalPrice * (1.0 + lockMovePct / 100.0), _Digits)
                  : NormalizeDouble(g_signalPrice * (1.0 - lockMovePct / 100.0), _Digits);

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;

      double curSL    = g_pos.StopLoss();
      bool   improved = (g_basketDir == ORDER_TYPE_BUY)
                        ? (newSL > curSL + _Point)
                        : (curSL == 0.0 || newSL < curSL - _Point);

      if (improved)
      {
         g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit());
         PrintFormat("[ProgTrail] ticket=%llu | peak=+%.3f%% | lock=%.0f%% | newSL=%.5f (was %.5f)",
                     g_pos.Ticket(), g_peakSignalMovePct, InpProgLockPct, newSL, curSL);
      }
   }
}

// Close only pyramid add positions (tag contains "add"), keep base trade.
void ClosePyramidAdds(const string reason)
{
   ulong tickets[];
   int   total = 0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;
      if (StringFind(g_pos.Comment(), "add") < 0)  continue; // pyramid adds only
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

   PrintFormat("[%s] Spike: closed %d pyramid add(s) — base trade holding", reason, closed);
}

// Returns true only when BOTH move speed AND bar range confirm a genuine spike.
// Both conditions must be true — AND logic keeps false positives very low.
bool IsVolatileSpike(double signalMovePct, int elapsed)
{
   if (elapsed <= 0) return false;

   // ── Condition 1: move speed (%/second) ────────────────────────────────────
   double speed = signalMovePct / (double)elapsed;
   if (speed < InpSpikeMoveSpeed) return false;  // move wasn't fast enough → hold

   // ── Condition 2: current bar range > N× average range ─────────────────────
   double curRange = iHigh(_Symbol, InpSignalTF, 0) - iLow(_Symbol, InpSignalTF, 0);
   if (curRange <= 0) return false;

   double avgRange = 0.0;
   for (int i = 1; i <= InpSpikeAvgBars; i++)
      avgRange += iHigh(_Symbol, InpSignalTF, i) - iLow(_Symbol, InpSignalTF, i);
   avgRange /= (double)InpSpikeAvgBars;

   if (avgRange <= 0) return false;
   if (curRange <= avgRange * InpSpikeRangeMult) return false; // normal range → hold

   return true; // both conditions met → genuine spike
}

//──────────────────────────────────────────────────────────────────────────────
// EXIT — per-tick, full exit priority stack
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

   // Track peak move from signal price
   if (signalMovePct > g_peakSignalMovePct)
      g_peakSignalMovePct = signalMovePct;

   // ── 0. Progressive trail — runs every tick, independently of TP tiers ─────
   UpdateProgressiveTrail();

   // ── 1. Emergency basket loss ───────────────────────────────────────────────
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

   // ── 1.5 Flash TP — close ALL when basket profit hits X% equity ───────────
   if (InpFlashTPPct > 0)
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
      double profitPct = (equity > 0) ? (totalPnL / equity * 100.0) : 0.0;
      if (profitPct >= InpFlashTPPct)
      {
         PrintFormat("[Exit] FlashTP: basket profit=%.2f (%.3f%% equity) >= %.3f%% — closing ALL",
                     totalPnL, profitPct, InpFlashTPPct);
         CloseAllOurPositions("FlashTP");
         RecordHistory(signalMovePct);
         g_consecLoss = 0;
         ResetSignal();
         return;
      }
   }

   // ── 2. TP Tier system ─────────────────────────────────────────────────────

   // TP1: close InpTP1ClosePct% of positions (most profitable first)
   // Then immediately move remaining SL to breakeven — no delay, no gap risk
   if (!g_tp1Done && signalMovePct >= InpTP1Pct)
   {
      int curCount = CountOurPositions();
      int toClose  = (int)MathMax(1, MathRound(curCount * InpTP1ClosePct / 100.0));
      int closed   = CloseByCount(toClose, "TP1");
      if (closed > 0)
      {
         g_tp1Done    = true;
         g_tp1Time    = TimeCurrent();
         RecordHistory(signalMovePct);
         g_consecLoss = 0;
         PrintFormat("[TP1] +%.3f%% | closed %d of %d (%.0f%%) | %d remain",
                     signalMovePct, closed, curCount, InpTP1ClosePct, CountOurPositions());

         // Immediately set breakeven on all remaining — no gap exposure after TP1
         if (CountOurPositions() > 0)
         {
            SetBreakeven();
            g_beDone = true;
         }
      }
      if (CountOurPositions() == 0) { ResetSignal(); return; }
   }

   // BE fallback: catches edge case where TP1 fired but BE didn't set (e.g. all closed)
   if (g_tp1Done && !g_beDone && signalMovePct >= (InpTP1Pct + InpBEOffsetPct))
   {
      SetBreakeven();
      g_beDone = true;
   }

   // TP2: close InpTP2ClosePct% of remaining, start trailing the rest
   if (g_tp1Done && !g_tp2Done && signalMovePct >= InpTP2Pct)
   {
      int curCount = CountOurPositions();
      int toClose  = (int)MathMax(1, MathRound(curCount * InpTP2ClosePct / 100.0));
      int closed   = CloseByCount(toClose, "TP2");
      if (closed > 0)
      {
         g_tp2Done   = true;
         g_sym.RefreshRates();
         g_trailPeak = (g_basketDir == ORDER_TYPE_BUY) ? g_sym.Bid() : g_sym.Ask();
         RecordHistory(signalMovePct);
         PrintFormat("[TP2] +%.3f%% | closed %d of %d (%.0f%%) | %d remain — trailing %d pts",
                     signalMovePct, closed, curCount, InpTP2ClosePct,
                     CountOurPositions(), InpTrailPoints);
      }
      if (CountOurPositions() == 0) { ResetSignal(); return; }
   }

   // Trail: update SL every tick for remaining positions after TP2
   if (g_tp2Done && CountOurPositions() > 0)
      UpdateTrailing();

   // ── 2.3 Post-TP1 re-entry timer ───────────────────────────────────────────
   // After TP1: every InpTP1TimerSecs seconds, close 1 most profitable position
   // and place a same-direction limit order InpLimitOffsetPts pts away to re-enter.
   if (g_tp1Done && !g_tp2Done && InpTP1TimerSecs > 0 && g_tp1Time > 0)
   {
      // Clear ticket if order filled or expired (no longer pending)
      if (g_tp1PendingTicket > 0 && !OrderSelect(g_tp1PendingTicket))
         g_tp1PendingTicket = 0;

      if (g_tp1PendingTicket == 0)
      {
         int tp1Elapsed = (int)(TimeCurrent() - g_tp1Time);
         if (tp1Elapsed >= InpTP1TimerSecs && signalMovePct >= InpTP1TimerMinPct)
         {
            int remaining = CountOurPositions();
            if (remaining > 0)
            {
               int closed = CloseByCount(1, "PostTP1");
               if (closed > 0)
               {
                  g_sym.RefreshRates();
                  double refPrice   = (g_basketDir == ORDER_TYPE_BUY) ? g_sym.Bid() : g_sym.Ask();
                  double limitPrice = (g_basketDir == ORDER_TYPE_BUY)
                                      ? NormalizeDouble(refPrice - InpLimitOffsetPts * _Point, _Digits)
                                      : NormalizeDouble(refPrice + InpLimitOffsetPts * _Point, _Digits);
                  double slOffset   = (InpHardSLPct > 0) ? InpHardSLPct : InpSLFloorPct;
                  double limitSL    = (g_basketDir == ORDER_TYPE_BUY)
                                      ? NormalizeDouble(g_signalPrice * (1.0 - slOffset / 100.0), _Digits)
                                      : NormalizeDouble(g_signalPrice * (1.0 + slOffset / 100.0), _Digits);
                  double lot        = CalcPyramidLot();
                  datetime expiry   = (datetime)(TimeCurrent() + InpLimitExpirySecs);

                  bool placed = (g_basketDir == ORDER_TYPE_BUY)
                                ? g_trade.BuyLimit(lot, limitPrice, _Symbol, limitSL, 0, ORDER_TIME_SPECIFIED, expiry, "FTV700-reentry")
                                : g_trade.SellLimit(lot, limitPrice, _Symbol, limitSL, 0, ORDER_TIME_SPECIFIED, expiry, "FTV700-reentry");

                  if (placed && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
                  {
                     g_tp1PendingTicket = g_trade.ResultOrder();
                     PrintFormat("[PostTP1] closed 1 pos at +%.3f%% | %s LIMIT %.5f (%d pts) | ticket=%llu | expires %ds",
                                 signalMovePct,
                                 (g_basketDir==ORDER_TYPE_BUY?"BUY":"SELL"),
                                 limitPrice, InpLimitOffsetPts,
                                 g_tp1PendingTicket, InpLimitExpirySecs);
                  }
                  else
                     PrintFormat("[PostTP1] closed 1 pos | limit FAILED rc=%u", g_trade.ResultRetcode());

                  g_tp1Time = TimeCurrent(); // reset so next cycle waits full InpTP1TimerSecs
               }
            }
         }
      }
   }

   // ── 2.5 Volatile Spike Exit ───────────────────────────────────────────────
   // Fires only within the spike window, only when BOTH speed + range confirm
   // a genuine spike. Closes pyramid adds only — base trade continues.
   if (!g_spikeDone && InpSpikeMaxSecs > 0 && InpSpikeMinProfitPct > 0 && !g_tp2Done)
   {
      int elapsed = (int)(TimeCurrent() - g_basketOpenTime);
      if (elapsed <= InpSpikeMaxSecs && signalMovePct >= InpSpikeMinProfitPct)
      {
         if (IsVolatileSpike(signalMovePct, elapsed))
         {
            g_spikeDone = true;
            PrintFormat("[SpikeExit] elapsed=%ds | speed=%.5f%%/s | move=%.3f%% | "
                        "range=%.5f > %.1f×avg — closing pyramid adds, base holds",
                        elapsed, signalMovePct / (double)elapsed,
                        signalMovePct,
                        iHigh(_Symbol,InpSignalTF,0)-iLow(_Symbol,InpSignalTF,0),
                        InpSpikeRangeMult);
            ClosePyramidAdds("SpikeExit");
         }
      }
   }

   // ── 3. Timed basket profit ────────────────────────────────────────────────
   if (InpBasketMaxProfitMins > 0)
   {
      int elapsed = (int)(TimeCurrent() - g_basketOpenTime);
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
         if (totalPnL > 0 && signalMovePct >= InpTP1Pct)
         {
            PrintFormat("[Exit] BasketTimedProfit: %ds | profit=%.2f | move=%.3f%% — closing all",
                        elapsed, totalPnL, signalMovePct);
            CloseAllOurPositions("BasketTimedProfit");
            RecordHistory(signalMovePct);
            g_consecLoss = 0;
            ResetSignal();
            return;
         }
      }
   }

   // ── 4. Timed basket loss ──────────────────────────────────────────────────
   if (InpBasketMaxLossMins > 0 && InpBasketLossPct > 0)
   {
      int elapsed = (int)(TimeCurrent() - g_basketOpenTime);
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
            PrintFormat("[Exit] BasketTimedLoss: %ds | loss=%.2f%% >= %.2f%% — closing all",
                        elapsed, lossPct, InpBasketLossPct);
            CloseAllOurPositions("BasketTimedLoss");
            RecordHistory(signalMovePct);
            g_consecLoss++;
            ResetSignal();
            return;
         }
      }
   }

   // ── 5. Peak pullback — close profitable, hold losers for Hard SL ─────────
   if (InpPeakKeepPct > 0 && g_peakSignalMovePct > InpTP1Pct)
   {
      double keepThreshold = g_peakSignalMovePct * InpPeakKeepPct / 100.0;
      if (signalMovePct < keepThreshold)
      {
         PrintFormat("[Exit] PeakPullback: move=%.3f%% < keepAt=%.3f%% "
                     "(peak=%.3f%% * %.0f%%) — closing profitable only",
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

   // ── 6. Hard SL from signal price (DynSL capped at InpHardSLPct) ──────────
   double dynSL = GetDynamicThreshold();
   if (InpHardSLPct > 0) dynSL = MathMin(dynSL, InpHardSLPct);
   if (signalMovePct <= -dynSL)
   {
      PrintFormat("[Exit] HardSL: signalMove=%.3f%% <= -%.3f%% (hardSL=%.3f%%)",
                  signalMovePct, dynSL, InpHardSLPct);
      CloseAllOurPositions("HardSL");
      RecordHistory(signalMovePct);
      g_consecLoss++;
      ResetSignal();
      return;
   }

   // ── 7. Time gate — close ALL after InpBurstMaxSec seconds ────────────────
   if (!g_timeGateFired && InpBurstMaxSec > 0)
   {
      int elapsed = (int)(TimeCurrent() - g_basketOpenTime);
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

   g_hEMAFast  = iMA(_Symbol, InpSignalTF, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMASlow  = iMA(_Symbol, InpSignalTF, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hRSI      = iRSI(_Symbol, InpSignalTF, InpRSIPeriod, PRICE_CLOSE);
   g_hTrendEMA = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);

   if (g_hEMAFast == INVALID_HANDLE || g_hEMASlow == INVALID_HANDLE ||
       g_hRSI == INVALID_HANDLE || g_hTrendEMA == INVALID_HANDLE)
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

   PrintFormat("FlipTrail v7.00 | %s | TF=%s | "
               "BaseRisk=%.1f%% PyramidRisk=%.1f%% | "
               "Pyramid: max %d adds @ %.3f%% steps | "
               "TP1=+%.3f%%(close %.0f%%) BE=+%.3f%% TP2=+%.3f%%(close %.0f%%) Trail=%dpts | "
               "HardSL=%.3f%% PeakKeep=%.0f%% TimeGate=%ds | "
               "TimedProfit=%dmin TimedLoss=%dmin@%.1f%% | "
               "DynSLfloor=%.2f%% EMA%d/EMA%d RSI(%d) | Magic=%lld",
               _Symbol, EnumToString(InpSignalTF),
               InpRiskPct, InpPyramidRiskPct,
               InpPyramidMax, InpPyramidStep,
               InpTP1Pct, InpTP1ClosePct, InpTP1Pct + InpBEOffsetPct,
               InpTP2Pct, InpTP2ClosePct, InpTrailPoints,
               InpHardSLPct, InpPeakKeepPct, InpBurstMaxSec,
               InpBasketMaxProfitMins, InpBasketMaxLossMins, InpBasketLossPct,
               InpSLFloorPct, InpEMAFast, InpEMASlow, InpRSIPeriod,
               InpMagicNumber);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   if (g_hEMAFast  != INVALID_HANDLE) IndicatorRelease(g_hEMAFast);
   if (g_hEMASlow  != INVALID_HANDLE) IndicatorRelease(g_hEMASlow);
   if (g_hRSI      != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   if (g_hTrendEMA != INVALID_HANDLE) IndicatorRelease(g_hTrendEMA);

   PrintFormat("FlipTrail v7.00 deinit | phase=%d | pyramidCount=%d | consecLoss=%d | reason=%d",
               (int)g_phase, g_pyramidCount, g_consecLoss, reason);
}

void OnTick()
{
   datetime bt     = iTime(_Symbol, InpSignalTF, 0);
   bool     newBar = (bt != 0 && bt != g_lastBarTime);
   if (newBar) g_lastBarTime = bt;

   UpdateDashboard();

   switch (g_phase)
   {
      case PHASE_ACTIVE:
         CheckExit();                          // exits evaluated first
         if (g_phase == PHASE_ACTIVE)
            TryPyramidAdd();                   // add only if still active after exits
         break;
      case PHASE_NONE:
      default:
         if (newBar) TryBaseEntry();
         break;
   }
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     request,
                        const MqlTradeResult&      result)
{
   // State managed entirely in OnTick — no action needed here
}
