//+------------------------------------------------------------------+
//|  FlipTrail_Deriv.mq5  v1.20                                      |
//|  HFT Basket Scalper — Deriv Synthetic Indices                    |
//|                                                                   |
//|  BUILT FOR: Volatility 10/25/50/75/100 Index (Deriv/MT5)        |
//|                                                                   |
//|  KEY DIFFERENCES FROM FlipTrail_EA_v2:                          |
//|  ──────────────────────────────────────                          |
//|  1. 24/7 — no session filter (synthetics never close)            |
//|  2. WIDER SL: SLFloorPct default 0.5% (v2 was 0.12%)           |
//|     Synthetics breathe more — too tight = constant SL hits      |
//|  3. DISTRIBUTED TP — 3 levels instead of bulk close:            |
//|     T1: +InpT1Pct% → close T1Count trades → rest to BE         |
//|     T2: +InpT2Pct% → close T2Count more  → trail remaining     |
//|     T3: trailing stop OR +InpT3Pct% → close all remaining      |
//|  4. NO BROKER SL on open (Deriv rejects tight stops).           |
//|     Soft DynSL monitors every tick instead.                     |
//|  5. BASKET RISK: 5% total / basket size (same model as v2.30+) |
//|                                                                   |
//|  ENTRY: M1 bar body direction (same as v2)                      |
//|  SIGNAL: bullish close → BUY basket / bearish → SELL basket     |
//+------------------------------------------------------------------+
#property copyright "FlipTrail Deriv"
#property link      ""
#property version   "1.20"
#property description "FlipTrail Deriv v1.20: faster exits — no totalProfit gate, progressive SL lock, 100-lot support"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Basket ==="
input int    InpBasketSize        = 5;      // BasketSize: trades per basket (1–10)
input double InpBasketRiskPct     = 5.0;    // BasketRiskPct: total % of equity for whole basket
input double InpMinLot            = 0.01;   // MinLot
input double InpMaxLot            = 100.0;  // MaxLot: ceiling per trade (Deriv synthetics support up to 100)
input long   InpMagicNumber       = 112240; // MagicNumber (Deriv build)
input int    InpMaxSlippagePoints = 30;     // MaxSlippagePoints

input group "=== Stop Loss ==="
input double InpSLFloorPct        = 0.50;  // SLFloorPct: soft DynSL floor % (wider for synthetics)
//  V10: 0.3–0.5%   V25: 0.5–0.8%   V50: 0.8–1.2%   V75: 1.0–1.5%   V100: 1.5–2.0%
input int    InpSLHistoryTrades   = 20;    // SLHistoryTrades: look back N closed baskets

input group "=== Distributed TP ==="
input double InpT1Pct             = 0.30;  // T1Pct: % move to close first batch
input int    InpT1Count           = 2;     // T1Count: trades to close at T1 → rest go to breakeven
input double InpT2Pct             = 0.60;  // T2Pct: % move to close second batch
input int    InpT2Count           = 2;     // T2Count: trades to close at T2 → rest trail
input double InpT3Pct             = 1.00;  // T3Pct: % move to close all remaining (hard target)
input double InpTrailPct          = 0.20;  // TrailPct: % pullback from peak to trigger trail close
input double InpBELockPct         = 0.02;  // BELockPct: SL lock % above entry after T1 (0=exact BE)
//  Example at defaults (basket of 5):
//  T1: +0.30% → close 2, move 3 to BE
//  T2: +0.60% → close 2 more, trail 1 with 0.20% pullback stop
//  T3: +1.00% OR trail hit → close last trade

input group "=== Loss Management ==="
input double InpLossWatchPct      = 0.30;  // LossWatchPct: adverse % to check candle for reversal
input int    InpLossPartialCount  = 2;     // LossPartialCount: worst trades to cut if no reversal
input int    InpDojiBodyPct       = 25;    // DojiBodyPct: max body % of range = doji (hold signal)

input group "=== Entry Filter ==="
input int              InpMinBodyPct  = 30;          // MinBodyPct: min candle body % of range (0=off)
input bool             InpHTFFilter   = true;         // HTFFilter: require HTF bar agrees with M1 signal
input ENUM_TIMEFRAMES  InpHTFPeriod   = PERIOD_M5;   // HTFPeriod: higher timeframe for trend alignment

input group "=== Consecutive Loss Pause ==="
input int    InpMaxConsecLosses   = 2;     // MaxConsecLosses: SL hits before pause (0=off)
input int    InpPauseBars         = 5;     // PauseBars: M1 bars to skip after consecutive losses

//──────────────────────────────────────────────────────────────────────────────
// STATE
//──────────────────────────────────────────────────────────────────────────────
CTrade        g_trade;
CPositionInfo g_pos;
CSymbolInfo   g_sym;

datetime        g_lastBarTime    = 0;
bool            g_isNetting      = false;
ENUM_ORDER_TYPE g_basketDir      = ORDER_TYPE_BUY;
bool            g_basketOpen     = false;
double          g_basketAvgEntry = 0.0;

// Dynamic SL history
double g_changeHistory[];
int    g_historyIndex = 0;
int    g_historyCount = 0;

// Consecutive loss pause
int g_consecLosses  = 0;
int g_pauseBarsLeft = 0;

// TP phase flags — reset each basket
bool   g_t1Done          = false;
bool   g_t2Done          = false;
bool   g_lossPartialDone = false;
double g_peakMovePct     = 0.0; // highest avgMovePct seen after T2 (for trailing)

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
   lot = MathMax(lot, minL);
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

void ResetBasketFlags()
{
   g_basketOpen     = false;
   g_basketAvgEntry = 0.0;
   g_t1Done         = false;
   g_t2Done         = false;
   g_lossPartialDone= false;
   g_peakMovePct    = 0.0;
}

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

   PrintFormat("[Basket] CloseAll [%s] | %d positions", reason, total);
   ResetBasketFlags();
}

void CloseNBest(int n)
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

   for (int a = 0; a < total - 1; a++)
      for (int b = a + 1; b < total; b++)
         if (profits[b] > profits[a])
         {
            double tp = profits[a]; profits[a] = profits[b]; profits[b] = tp;
            ulong  tt = tickets[a]; tickets[a] = tickets[b]; tickets[b] = tt;
         }

   int closeCount = MathMin(n, total);
   for (int j = 0; j < closeCount; j++)
      for (int attempt = 0; attempt < 3; attempt++)
      {
         if (g_trade.PositionClose(tickets[j], InpMaxSlippagePoints)) break;
         Sleep(50);
      }
   PrintFormat("[CloseNBest] %d closed | %d remaining", closeCount, total - closeCount);
}

void CloseNWorst(int n)
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

   for (int a = 0; a < total - 1; a++)
      for (int b = a + 1; b < total; b++)
         if (profits[b] < profits[a])
         {
            double tp = profits[a]; profits[a] = profits[b]; profits[b] = tp;
            ulong  tt = tickets[a]; tickets[a] = tickets[b]; tickets[b] = tt;
         }

   int closeCount = MathMin(n, total);
   for (int j = 0; j < closeCount; j++)
      for (int attempt = 0; attempt < 3; attempt++)
      {
         if (g_trade.PositionClose(tickets[j], InpMaxSlippagePoints)) break;
         Sleep(50);
      }
   PrintFormat("[CloseNWorst] %d cut | %d remaining", closeCount, total - closeCount);
}

void SetRemainingToLock(double lockPct)
{
   int moved = 0;

   long   stopLevelPts  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stopLevelDist = stopLevelPts * _Point;
   g_sym.RefreshRates();

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;

      double entry    = g_pos.PriceOpen();
      double lockDist = entry * lockPct / 100.0;
      double newSL;

      if (g_pos.PositionType() == POSITION_TYPE_BUY)
      {
         newSL = NormalizeDouble(entry + lockDist, _Digits);
         double minAllowed = g_sym.Bid() - stopLevelDist;
         if (newSL > minAllowed)
         {
            PrintFormat("[LockSL] BUY ticket=%llu newSL=%.5f violates stop level — clamping to %.5f",
                        g_pos.Ticket(), newSL, minAllowed);
            newSL = NormalizeDouble(minAllowed, _Digits);
         }
         if (g_pos.StopLoss() >= newSL - _Point) continue; // already at or better
      }
      else
      {
         newSL = NormalizeDouble(entry - lockDist, _Digits);
         double minAllowed = g_sym.Ask() + stopLevelDist;
         if (newSL < minAllowed)
         {
            PrintFormat("[LockSL] SELL ticket=%llu newSL=%.5f violates stop level — clamping to %.5f",
                        g_pos.Ticket(), newSL, minAllowed);
            newSL = NormalizeDouble(minAllowed, _Digits);
         }
         if (g_pos.StopLoss() > 0 && g_pos.StopLoss() <= newSL + _Point) continue; // already tighter
      }

      if (g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit()))
         moved++;
      else
         PrintFormat("[LockSL] FAILED ticket=%llu newSL=%.5f rc=%u (%s)",
                     g_pos.Ticket(), newSL, g_trade.ResultRetcode(),
                     g_trade.ResultRetcodeDescription());
   }
   if (moved > 0)
      PrintFormat("[LockSL] %d positions SL locked at entry+%.2f%%", moved, lockPct);
}

//──────────────────────────────────────────────────────────────────────────────
// GetDynamicThreshold
//──────────────────────────────────────────────────────────────────────────────
double GetDynamicThreshold()
{
   if (g_historyCount == 0) return InpSLFloorPct;
   double sum = 0.0;
   for (int i = 0; i < g_historyCount; i++) sum += g_changeHistory[i];
   return MathMax(sum / g_historyCount, InpSLFloorPct);
}

//──────────────────────────────────────────────────────────────────────────────
// CalcPerTradeLot
// Basket risk model: InpBasketRiskPct% split across all trades.
// Uses SLFloorPct as the SL distance for lot calculation.
//──────────────────────────────────────────────────────────────────────────────
double CalcPerTradeLot(int numTrades)
{
   if (numTrades <= 0) numTrades = 1;
   double threshold = GetDynamicThreshold();
   g_sym.RefreshRates();
   double price = (g_sym.Ask() + g_sym.Bid()) / 2.0;
   if (price <= 0) return NormalizeLot(InpMinLot);

   int slPts = (int)MathRound(threshold / 100.0 * price / _Point);
   if (slPts <= 0) return NormalizeLot(InpMinLot);

   double equity       = AccountInfoDouble(ACCOUNT_EQUITY);
   double perTradeRisk = (equity * InpBasketRiskPct / 100.0) / numTrades;
   double tickVal      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tickVal <= 0 || tickSize <= 0) return NormalizeLot(InpMinLot);

   double slMoney = (slPts * _Point / tickSize) * tickVal;
   if (slMoney <= 0) return NormalizeLot(InpMinLot);

   return NormalizeLot(MathMax(MathMin((perTradeRisk / slMoney), InpMaxLot), InpMinLot));
}

//──────────────────────────────────────────────────────────────────────────────
// OpenBasket — opens InpBasketSize trades without broker SL
// Deriv synthetics reject tight broker SL (invalid stops).
// Soft DynSL in CheckBasketClose handles exit protection.
//──────────────────────────────────────────────────────────────────────────────
void OpenBasket(ENUM_ORDER_TYPE dir)
{
   if (g_basketOpen)            return;
   if (CountOurPositions() > 0) return;

   int    numTrades = g_isNetting ? 1 : MathMax(1, MathMin(InpBasketSize, 10));
   double lot       = CalcPerTradeLot(numTrades);
   int    opened    = 0;
   double entrySum  = 0.0;

   for (int t = 0; t < numTrades; t++)
   {
      g_sym.RefreshRates();
      double ask = g_sym.Ask();
      double bid = g_sym.Bid();
      bool   ok  = false;

      if (dir == ORDER_TYPE_BUY)
         ok = g_trade.Buy(lot, _Symbol, ask, 0, 0, "FTD-HFT");
      else
         ok = g_trade.Sell(lot, _Symbol, bid, 0, 0, "FTD-HFT");

      uint rc = g_trade.ResultRetcode();
      PrintResult(StringFormat("[%s] Deriv %s t=%d/%d lot=%.2f",
                  _Symbol, (dir==ORDER_TYPE_BUY?"BUY":"SELL"), t+1, numTrades, lot));

      if (rc == TRADE_RETCODE_DONE)
      {
         opened++;
         entrySum += g_trade.ResultPrice(); // actual fill price — not re-read ask/bid which may have moved
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

   if (opened > 0)
   {
      g_basketDir      = dir;
      g_basketOpen     = true;
      g_basketAvgEntry = entrySum / opened;
      g_t1Done         = false;
      g_t2Done         = false;
      g_lossPartialDone= false;
      g_peakMovePct    = 0.0;

      PrintFormat("[Basket OPEN] %s | %d/%d trades | %.2f lot each | AvgEntry=%.5f | "
                  "SoftSL=%.2f%% | T1=+%.2f%%(%d) T2=+%.2f%%(%d) T3=+%.2f%% Trail=%.2f%%",
                  (dir==ORDER_TYPE_BUY?"BUY":"SELL"),
                  opened, numTrades, lot, g_basketAvgEntry,
                  GetDynamicThreshold(),
                  InpT1Pct, InpT1Count, InpT2Pct, InpT2Count, InpT3Pct, InpTrailPct);
   }
}

//──────────────────────────────────────────────────────────────────────────────
// CheckBasketClose — every tick
//
// EXIT SEQUENCE:
//   Soft SL  → avgMove <= -DynThreshold%           → close all (loss)
//   Loss cut → avgMove <= -LossWatchPct%            → check doji or cut worst
//   T1       → avgMove >= T1Pct%  + profit > 0     → close T1Count best → BE
//   T2       → avgMove >= T2Pct%  + profit > 0     → close T2Count best → start trail
//   T3/Trail → avgMove >= T3Pct%  OR               → close all remaining
//              peak - current >= TrailPct%
//──────────────────────────────────────────────────────────────────────────────
void CheckBasketClose()
{
   int total = CountOurPositions();
   if (total == 0) { ResetBasketFlags(); return; }

   g_sym.RefreshRates();
   double ask = g_sym.Ask();
   double bid = g_sym.Bid();
   double totalProfit = 0.0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;
      totalProfit += g_pos.Profit();
   }

   double avgMovePct = 0.0;
   if (g_basketAvgEntry > 0)
   {
      double cur = (g_basketDir == ORDER_TYPE_BUY) ? bid : ask;
      avgMovePct = (g_basketDir == ORDER_TYPE_BUY)
                   ? (cur - g_basketAvgEntry) / g_basketAvgEntry * 100.0
                   : (g_basketAvgEntry - cur) / g_basketAvgEntry * 100.0;
   }

   // ── SOFT DYNAMIC SL ───────────────────────────────────────────────────────
   if (g_basketAvgEntry > 0 && avgMovePct <= -GetDynamicThreshold())
   {
      PrintFormat("[DynSL] move=%.3f%% <= -%.3f%% | P&L=%.2f — closing all",
                  avgMovePct, GetDynamicThreshold(), totalProfit);
      CloseAllOurPositions("DynSL");
      return;
   }

   // ── LOSS MANAGEMENT — doji hold / cut worst ───────────────────────────────
   if (!g_lossPartialDone && avgMovePct <= -InpLossWatchPct && totalProfit < 0)
   {
      double c     = iClose(_Symbol, PERIOD_M1, 1);
      double o     = iOpen (_Symbol, PERIOD_M1, 1);
      double hi    = iHigh (_Symbol, PERIOD_M1, 1);
      double lo    = iLow  (_Symbol, PERIOD_M1, 1);
      double range = hi - lo;
      double body  = MathAbs(c - o);
      bool isDoji      = (range > 0 && (body / range) * 100.0 < (double)InpDojiBodyPct);
      bool isAgainstUs = (g_basketDir == ORDER_TYPE_BUY) ? (c < o) : (c > o);

      if (isDoji)
      {
         PrintFormat("[Loss Hold] Doji (body=%.0f%%) — holding for reversal | move=%.3f%% | P&L=%.2f",
                     (range > 0 ? body / range * 100.0 : 0.0), avgMovePct, totalProfit);
      }
      else if (isAgainstUs)
      {
         PrintFormat("[Loss Cut] Strong candle against us (body=%.0f%%) | move=%.3f%% — cutting %d worst",
                     (range > 0 ? body / range * 100.0 : 0.0), avgMovePct, InpLossPartialCount);
         CloseNWorst(InpLossPartialCount);
         g_lossPartialDone = true;
         return;
      }
   }

   // ── T1 — first partial profit close ──────────────────────────────────────
   if (!g_t1Done && avgMovePct >= InpT1Pct && total > InpT1Count)
   {
      PrintFormat("[T1] move=+%.3f%% >= +%.2f%% | P&L=%.2f — closing %d best → lock SL +%.2f%%",
                  avgMovePct, InpT1Pct, totalProfit, InpT1Count, InpBELockPct);
      CloseNBest(InpT1Count);
      SetRemainingToLock(InpBELockPct);
      g_t1Done = true;
      return;
   }

   // ── T2 — second partial profit close, start trailing ─────────────────────
   if (g_t1Done && !g_t2Done && avgMovePct >= InpT2Pct && total > InpT2Count)
   {
      PrintFormat("[T2] move=+%.3f%% >= +%.2f%% | P&L=%.2f — closing %d more → trail remaining at %.2f%%",
                  avgMovePct, InpT2Pct, totalProfit, InpT2Count, InpTrailPct);
      CloseNBest(InpT2Count);
      g_t2Done      = true;
      g_peakMovePct = avgMovePct;
      return;
   }

   // ── T3 / TRAIL — close all remaining ─────────────────────────────────────
   if (g_t2Done && total > 0)
   {
      // Update peak
      if (avgMovePct > g_peakMovePct) g_peakMovePct = avgMovePct;

      bool t3Hit    = (avgMovePct >= InpT3Pct); // price % is the gate — not broker P&L (spread distorts it)
      bool trailHit = (g_peakMovePct > InpT2Pct && (g_peakMovePct - avgMovePct) >= InpTrailPct);

      if (t3Hit)
      {
         PrintFormat("[T3] move=+%.3f%% >= +%.2f%% | P&L=%.2f — closing all remaining",
                     avgMovePct, InpT3Pct, totalProfit);
         CloseAllOurPositions("T3");
         return;
      }
      if (trailHit)
      {
         PrintFormat("[Trail] peak=%.3f%% pullback=%.3f%% >= %.2f%% | P&L=%.2f — closing all remaining",
                     g_peakMovePct, g_peakMovePct - avgMovePct, InpTrailPct, totalProfit);
         CloseAllOurPositions("Trail");
         return;
      }
   }

   // ── T1 FULL CLOSE (if basket size == T1Count, no T2/T3 needed) ───────────
   if (!g_t1Done && avgMovePct >= InpT1Pct && total <= InpT1Count)
   {
      PrintFormat("[T1-All] move=+%.3f%% | P&L=%.2f — closing all (basket size <= T1Count)",
                  avgMovePct, totalProfit);
      CloseAllOurPositions("T1-All");
      return;
   }
}

//──────────────────────────────────────────────────────────────────────────────
// TrySeedEntry — fires on every new M1 bar (24/7)
//──────────────────────────────────────────────────────────────────────────────
void TrySeedEntry()
{
   if (g_basketOpen)            return;
   if (CountOurPositions() > 0) return;
   if (g_pauseBarsLeft > 0)     { g_pauseBarsLeft--; return; }

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
      if (range > 0 && (body / range) * 100.0 < (double)InpMinBodyPct)
      {
         PrintFormat("Skip[Body]: %.0f%% < %d%%", (body/range)*100.0, InpMinBodyPct);
         return;
      }
   }

   // ── HTF TREND FILTER — M5 (or configured TF) last bar must agree ─────────
   if (InpHTFFilter)
   {
      double htfC = iClose(_Symbol, InpHTFPeriod, 1);
      double htfO = iOpen (_Symbol, InpHTFPeriod, 1);
      if (htfC == htfO) return; // doji on HTF — no clear trend, skip
      ENUM_ORDER_TYPE htfDir = (htfC > htfO) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if (htfDir != dir)
      {
         PrintFormat("Skip[HTF %s]: M1=%s but HTF bar is %s — counter-trend, skipping",
                     EnumToString(InpHTFPeriod),
                     (dir==ORDER_TYPE_BUY?"BUY":"SELL"),
                     (htfDir==ORDER_TYPE_BUY?"BUY":"SELL"));
         return;
      }
   }

   PrintFormat("Signal %s (O=%.5f C=%.5f) HTF agrees → basket",
               (dir==ORDER_TYPE_BUY?"BUY":"SELL"), o, c);
   OpenBasket(dir);
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

   ArrayResize(g_changeHistory, InpSLHistoryTrades);
   ArrayInitialize(g_changeHistory, 0.0);
   g_historyIndex = 0;
   g_historyCount = 0;
   g_consecLosses  = 0;
   g_pauseBarsLeft = 0;
   ResetBasketFlags();

   int numTrades = g_isNetting ? 1 : MathMin(InpBasketSize, 10);
   PrintFormat("FlipTrail Deriv v1.20 | %s | Basket=%d | BasketRisk=%.1f%% (%.2f%% per trade) | "
               "SoftSL floor=%.2f%% | "
               "T1=+%.2f%%(%d trades) T2=+%.2f%%(%d trades) T3=+%.2f%% Trail=%.2f%% | "
               "LossWatch=%.2f%% Doji<%d%% CutWorst=%d | "
               "ConsecPause: %d losses → %d bars | HTF=%s(%s) | 24/7 | Magic=%lld",
               _Symbol, numTrades,
               InpBasketRiskPct, InpBasketRiskPct / numTrades,
               InpSLFloorPct,
               InpT1Pct, InpT1Count, InpT2Pct, InpT2Count, InpT3Pct, InpTrailPct,
               InpLossWatchPct, InpDojiBodyPct, InpLossPartialCount,
               InpMaxConsecLosses, InpPauseBars,
               InpHTFFilter ? EnumToString(InpHTFPeriod) : "OFF",
               InpHTFFilter ? "ON" : "OFF",
               InpMagicNumber);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FlipTrail Deriv v1.20 deinit (reason=%d).", reason);
}

void OnTick()
{
   datetime bt     = iTime(_Symbol, PERIOD_M1, 0);
   bool     newBar = (bt != 0 && bt != g_lastBarTime);
   if (newBar) g_lastBarTime = bt;

   CheckBasketClose();

   if (newBar) TrySeedEntry();
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     request,
                        const MqlTradeResult&      result)
{
   if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal = trans.deal;
   if (deal == 0) return;

   if (!HistoryDealSelect(deal))
   {
      HistorySelect(TimeCurrent() - 60, TimeCurrent());
      if (!HistoryDealSelect(deal)) return;
   }

   if (HistoryDealGetString (deal, DEAL_SYMBOL) != _Symbol)              return;
   if (HistoryDealGetInteger(deal, DEAL_MAGIC)  != (long)InpMagicNumber) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
   if (entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;

   if (CountOurPositions() == 0)
   {
      if (g_basketAvgEntry > 0)
      {
         double closePrice = HistoryDealGetDouble(deal, DEAL_PRICE);
         double changePct  = (g_basketDir == ORDER_TYPE_BUY)
                             ? (closePrice - g_basketAvgEntry) / g_basketAvgEntry * 100.0
                             : (g_basketAvgEntry - closePrice) / g_basketAvgEntry * 100.0;
         double absChange  = MathAbs(changePct);
         bool   wasProfit  = (changePct > 0);

         g_changeHistory[g_historyIndex % InpSLHistoryTrades] = absChange;
         g_historyIndex++;
         g_historyCount = MathMin(g_historyCount + 1, InpSLHistoryTrades);

         if (wasProfit)
         {
            g_consecLosses = 0;
            PrintFormat("Basket closed | change=%.3f%% [PROFIT] | DynSL avg=%.3f%%",
                        changePct, GetDynamicThreshold());
         }
         else
         {
            g_consecLosses++;
            if (InpMaxConsecLosses > 0 && g_consecLosses >= InpMaxConsecLosses)
            {
               g_pauseBarsLeft = InpPauseBars;
               g_consecLosses  = 0;
               PrintFormat("Basket closed | change=%.3f%% [LOSS] | %d consec → pausing %d bars",
                           changePct, InpMaxConsecLosses, InpPauseBars);
            }
            else
               PrintFormat("Basket closed | change=%.3f%% [LOSS] | consec=%d/%d",
                           changePct, g_consecLosses, InpMaxConsecLosses);
         }
      }

      ResetBasketFlags();
      PrintFormat("Ready for next signal");
   }
}
