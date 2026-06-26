//+------------------------------------------------------------------+
//|  H1confirmFlipTrail.mq5  v3.10                                   |
//|  Pullback-confirmation entry + dynamic lot sizing                 |
//|                                                                   |
//|  WHAT CHANGED FROM v3                                            |
//|  ──────────────────────                                          |
//|  Entry signal redesigned (TrySeedEntry):                         |
//|  OLD: single M1 candle body filter (noisy on M1)                 |
//|  NEW: pullback-confirmation pattern —                            |
//|       2+ opposite candles (pullback) then 2 same-direction       |
//|       candles (reversal + confirmation) in H1 trend direction    |
//|                                                                   |
//|  Dynamic lot sizing (ScorePullbackSetup → CalcDynamicLot):       |
//|  Score 0-100 based on pullback depth, candle count,              |
//|  reversal candle body%, confirmation candle body%                |
//|  Lot = InpMinLot + (InpMaxLot - InpMinLot) × score/100          |
//|                                                                   |
//|  SAME AS v3                                                      |
//|  Retest-limit flip, peak lock, H1 filter, progressive trail     |
//+------------------------------------------------------------------+
#property copyright "FlipTrail EA"
#property link      ""
#property version   "3.10"
#property description "H1confirmFlipTrail v3.10: pullback entry + dynamic lot + retest-limit flip"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Trade ==="
input double InpMinLot             = 0.02;  // MinLot: lot size for lowest-confidence setup
input double InpMaxLot             = 0.30;  // MaxLot: lot size for highest-confidence setup
input int    InpSLPoints           = 50;    // SLPoints: minimum SL floor
input long   InpMagicNumber        = 112234;// MagicNumber
input int    InpMaxSlippagePoints  = 30;    // MaxSlippagePoints
input int    InpMaxSpreadPoints    = 0;     // MaxSpreadPoints (0 = off)

input group "=== ATR Stop Loss ==="
input int    InpATRPeriod          = 14;    // ATRPeriod
input double InpATRMultiplier      = 1.5;   // ATRMultiplier: SL = ATR × this

input group "=== Breakeven ==="
input int    InpBEPoints           = 50;    // BEPoints: profit pts to lock BE (0 = off)
input int    InpBEBuffer           = 10;    // BEBuffer: SL moves to entry + this

input group "=== Pullback Entry ==="
input int    InpMinPullbackBars    = 2;     // MinPullbackBars: min opposite candles before reversal
// Dynamic lot scoring:
// Pullback depth vs ATR  → 0-30 pts
// Pullback candle count  → 0-25 pts
// Reversal candle body%  → 0-25 pts
// Confirm  candle body%  → 0-20 pts
// Total 0-100 → MinLot..MaxLot

input group "=== H1 Trend Filter ==="
input bool   InpH1FilterEnabled    = true;  // H1FilterEnabled
input int    InpH1EMAPeriod        = 20;    // H1EMAPeriod

input group "=== Peak Profit Lock ==="
input int    InpPeakLockPct        = 50;    // PeakLockPct: lock % of peak profit (0 = off)

input group "=== Retest Limit ==="
input int    InpRetestBufferPts    = 10;    // RetestBufferPts: pts offset from close price for limit
input int    InpRetestExpiryBars   = 20;    // RetestExpiryBars: M1 bars before auto-cancel (0 = GTC)

input group "=== Flip Guard ==="
input int    InpMaxSLFlips         = 50;    // MaxSLFlips cap
input int    InpCooldownSeconds    = 0;     // CooldownSeconds after SL flip (0 = off)

input group "=== Trading Hours ==="
input bool   InpEnableTradingHours = false;
input int    InpTradingStartHour   = 8;
input int    InpTradingEndHour     = 20;

//──────────────────────────────────────────────────────────────────────────────
// OBJECTS & STATE
//──────────────────────────────────────────────────────────────────────────────
CTrade        g_trade;
CPositionInfo g_pos;
CSymbolInfo   g_sym;

int      g_atrHandle         = INVALID_HANDLE;
int      g_emaHandle         = INVALID_HANDLE;
bool     g_isNetting         = false;

int      g_effectiveSLMin    = 0;
int      g_trailGap          = 0;
int      g_trailGapInitial   = 0;
datetime g_lastBarTime       = 0;
ulong    g_flipTicket        = 0;
int      g_retestBarsElapsed = 0;
int      g_slFlipCount       = 0;
bool     g_standingDown      = false;
ulong    g_lastDeal          = 0;
bool     g_closingForCap     = false;

// Per-trade state
bool     g_beSet             = false;
double   g_entryPrice        = 0.0;
datetime g_lastSLFlipTime    = 0;
double   g_peakProfitPts     = 0.0;

//──────────────────────────────────────────────────────────────────────────────
// UTILITY
//──────────────────────────────────────────────────────────────────────────────
bool SelectOurPosition()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;
      return true;
   }
   return false;
}

bool PendingOrderExists(ulong ticket)
{
   if (ticket == 0) return false;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
      if (OrderGetTicket(i) == ticket) return true;
   return false;
}

double NormalizeLot(double lot)
{
   double step = g_sym.LotsStep();
   double minL = g_sym.LotsMin();
   double maxL = g_sym.LotsMax();
   if (step <= 0.0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, minL);
   lot = MathMin(lot, maxL);
   return NormalizeDouble(lot, 2);
}

bool IsInTradingHours()
{
   if (!InpEnableTradingHours) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if (InpTradingStartHour <= InpTradingEndHour)
      return (h >= InpTradingStartHour && h < InpTradingEndHour);
   return (h >= InpTradingStartHour || h < InpTradingEndHour);
}

void PrintResult(const string ctx)
{
   PrintFormat("%s | rc=%u (%s) | deal=%llu | order=%llu",
               ctx, g_trade.ResultRetcode(),
               g_trade.ResultRetcodeDescription(),
               g_trade.ResultDeal(), g_trade.ResultOrder());
}

int SafeDist(int basePts, double ask, double bid)
{
   int sp = (int)MathRound((ask - bid) / _Point);
   int sl = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return MathMax(basePts, sp + sl + 5);
}

int GetATRPoints()
{
   if (g_atrHandle == INVALID_HANDLE) return InpSLPoints;
   double atr[];
   ArraySetAsSeries(atr, true);
   if (CopyBuffer(g_atrHandle, 0, 1, 1, atr) <= 0) return InpSLPoints;
   int pts = (int)MathRound(atr[0] * InpATRMultiplier / _Point);
   return MathMax(pts, InpSLPoints);
}

//──────────────────────────────────────────────────────────────────────────────
// GetH1Bias — silent H1 direction check (no log output)
// Returns  1 = bullish (price > EMA)
//         -1 = bearish (price < EMA)
//          0 = filter off or data unavailable
//──────────────────────────────────────────────────────────────────────────────
int GetH1Bias()
{
   if (!InpH1FilterEnabled)           return 0;
   if (g_emaHandle == INVALID_HANDLE) return 0;

   double ema[];
   ArraySetAsSeries(ema, true);
   if (CopyBuffer(g_emaHandle, 0, 0, 1, ema) <= 0) return 0;

   double h1Close = iClose(_Symbol, PERIOD_H1, 0);
   if (h1Close == 0) return 0;

   return (h1Close > ema[0]) ? 1 : -1;
}

//──────────────────────────────────────────────────────────────────────────────
// H1TrendAgreesWithFlip — used by retest limit management (logs when blocked)
//──────────────────────────────────────────────────────────────────────────────
bool H1TrendAgreesWithFlip(ENUM_ORDER_TYPE dir)
{
   if (!InpH1FilterEnabled)           return true;
   if (g_emaHandle == INVALID_HANDLE) return true;

   double ema[];
   ArraySetAsSeries(ema, true);
   if (CopyBuffer(g_emaHandle, 0, 0, 1, ema) <= 0) return true;

   double h1Close = iClose(_Symbol, PERIOD_H1, 0);
   if (h1Close == 0) return true;

   bool agrees = (dir == ORDER_TYPE_BUY) ? (h1Close > ema[0])
                                         : (h1Close < ema[0]);
   if (!agrees)
      PrintFormat("H1 filter: %s blocked (H1=%.5f EMA%d=%.5f)",
                  (dir==ORDER_TYPE_BUY?"BUY":"SELL"), h1Close, InpH1EMAPeriod, ema[0]);
   return agrees;
}

//──────────────────────────────────────────────────────────────────────────────
// ScorePullbackSetup
// Detects: 2+ opposite candles (pullback) → 2 same-direction candles
// (reversal + confirmation) consistent with `dir`.
//
// Returns score 0-100 on valid setup, -1 if pattern not found.
//
// Scoring:
//   Pullback depth vs ATR (0-30): deeper = trend is pausing, not reversing
//   Pullback candle count (0-25): cleaner pullback = more reliable signal
//   Reversal candle body%  (0-25): first recovery candle strength
//   Confirm  candle body%  (0-20): second candle confirms buyers/sellers back
//──────────────────────────────────────────────────────────────────────────────
int ScorePullbackSetup(ENUM_ORDER_TYPE dir)
{
   bool isBuy = (dir == ORDER_TYPE_BUY);

   // ── Confirmation candles: [1]=confirm, [2]=reversal ──────────────────────
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double o1 = iOpen (_Symbol, PERIOD_M1, 1);
   double h1 = iHigh (_Symbol, PERIOD_M1, 1);
   double l1 = iLow  (_Symbol, PERIOD_M1, 1);

   double c2 = iClose(_Symbol, PERIOD_M1, 2);
   double o2 = iOpen (_Symbol, PERIOD_M1, 2);
   double h2 = iHigh (_Symbol, PERIOD_M1, 2);
   double l2 = iLow  (_Symbol, PERIOD_M1, 2);

   // Both candles must be in the entry direction
   bool c1inDir = isBuy ? (c1 > o1) : (c1 < o1);
   bool c2inDir = isBuy ? (c2 > o2) : (c2 < o2);
   if (!c1inDir || !c2inDir) return -1;

   // Doji filter: both candles need at least 20% body (not noise)
   double range1 = h1 - l1;
   double range2 = h2 - l2;
   double body1  = MathAbs(c1 - o1);
   double body2  = MathAbs(c2 - o2);
   if (range1 > 0 && body1 / range1 < 0.20) return -1;
   if (range2 > 0 && body2 / range2 < 0.20) return -1;

   // ── Pullback: count consecutive opposite candles before candle[2] ────────
   int    pullbackCount = 0;
   double pbHigh = 0.0, pbLow = DBL_MAX;

   for (int i = 3; i <= 3 + 6; i++)   // look back up to 6 pullback candles
   {
      double ci = iClose(_Symbol, PERIOD_M1, i);
      double oi = iOpen (_Symbol, PERIOD_M1, i);
      bool   ciOpposite = isBuy ? (ci < oi) : (ci > oi);
      if (!ciOpposite) break;          // pullback ended — stop counting

      pullbackCount++;
      pbHigh = MathMax(pbHigh, iHigh(_Symbol, PERIOD_M1, i));
      pbLow  = MathMin(pbLow,  iLow (_Symbol, PERIOD_M1, i));
   }

   if (pullbackCount < InpMinPullbackBars) return -1;  // not enough pullback

   // ── Score ────────────────────────────────────────────────────────────────
   int score = 0;

   // 1. Pullback depth relative to ATR (0-30 pts)
   double atrPrice   = GetATRPoints() * _Point;
   double pbDepth    = pbHigh - pbLow;
   if (atrPrice > 0)
   {
      double ratio = pbDepth / atrPrice;
      if      (ratio >= 1.0) score += 30;
      else if (ratio >= 0.5) score += 20;
      else if (ratio >= 0.3) score += 10;
   }

   // 2. Pullback candle count (0-25 pts)
   if      (pullbackCount >= 4) score += 25;
   else if (pullbackCount == 3) score += 20;
   else                         score += 10;  // == 2

   // 3. Reversal candle body% [2] (0-25 pts)
   double bodyPct2 = (range2 > 0) ? body2 / range2 * 100.0 : 0;
   if      (bodyPct2 >= 70) score += 25;
   else if (bodyPct2 >= 50) score += 15;
   else                     score += 5;

   // 4. Confirmation candle body% [1] (0-20 pts)
   double bodyPct1 = (range1 > 0) ? body1 / range1 * 100.0 : 0;
   if      (bodyPct1 >= 70) score += 20;
   else if (bodyPct1 >= 50) score += 12;
   else                     score += 4;

   return score;  // 0-100
}

//──────────────────────────────────────────────────────────────────────────────
// CalcDynamicLot — maps score 0-100 to MinLot..MaxLot
//──────────────────────────────────────────────────────────────────────────────
double CalcDynamicLot(int score)
{
   double pct = MathMax(0, MathMin(score, 100)) / 100.0;
   return NormalizeLot(InpMinLot + (InpMaxLot - InpMinLot) * pct);
}

//──────────────────────────────────────────────────────────────────────────────
// UpdateTrailGap — progressive tightening
//──────────────────────────────────────────────────────────────────────────────
void UpdateTrailGap()
{
   if (!SelectOurPosition()) return;
   if (g_trailGapInitial <= 0) return;

   ENUM_POSITION_TYPE posType = g_pos.PositionType();
   g_sym.RefreshRates();
   double ask = g_sym.Ask();
   double bid = g_sym.Bid();

   double profitPts = (posType == POSITION_TYPE_BUY)
                      ? (bid - g_entryPrice) / _Point
                      : (g_entryPrice - ask) / _Point;

   if (profitPts <= 0) { g_trailGap = g_trailGapInitial; return; }

   double ratio = profitPts / (double)g_trailGapInitial;
   int    newGap;

   if      (ratio >= 3.0) newGap = (int)MathRound(g_trailGapInitial * 0.15);
   else if (ratio >= 2.0) newGap = (int)MathRound(g_trailGapInitial * 0.25);
   else if (ratio >= 1.0) newGap = (int)MathRound(g_trailGapInitial * 0.50);
   else                   newGap = g_trailGapInitial;

   newGap = MathMax(newGap, g_effectiveSLMin);

   if (newGap < g_trailGap)
   {
      PrintFormat("Trail tightened: profit=%.0fpts (%.1f×ATR) → gap %d→%dpts",
                  profitPts, ratio, g_trailGap, newGap);
      g_trailGap = newGap;
   }
}

//──────────────────────────────────────────────────────────────────────────────
// CancelRetestLimit
//──────────────────────────────────────────────────────────────────────────────
void CancelRetestLimit()
{
   if (g_flipTicket == 0) return;
   if (!PendingOrderExists(g_flipTicket)) { g_flipTicket = 0; return; }
   if (g_trade.OrderDelete(g_flipTicket))
   {
      PrintFormat("RetestLimit %llu cancelled", g_flipTicket);
      g_flipTicket        = 0;
      g_retestBarsElapsed = 0;
   }
   else
      PrintResult(StringFormat("CancelRetestLimit %llu FAILED", g_flipTicket));
}

//──────────────────────────────────────────────────────────────────────────────
// PlaceRetestLimit
//──────────────────────────────────────────────────────────────────────────────
void PlaceRetestLimit(double closePrice, ENUM_POSITION_TYPE closedPosType)
{
   if (PendingOrderExists(g_flipTicket)) return;

   g_sym.RefreshRates();
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int spread     = (int)MathRound((g_sym.Ask() - g_sym.Bid()) / _Point);
   int minDist    = MathMax(stopsLevel + spread + 2, 1);
   int bufferPts  = MathMax(InpRetestBufferPts, minDist);

   int    atrPts = GetATRPoints();
   double lot    = NormalizeLot(g_isNetting ? InpMinLot * 2.0 : InpMinLot);
   bool   ok     = false;

   if (closedPosType == POSITION_TYPE_BUY)
   {
      double limitPrice = NormalizeDouble(closePrice + bufferPts * _Point, _Digits);
      double limitSL    = NormalizeDouble(limitPrice + atrPts * _Point, _Digits);
      ok = g_trade.SellLimit(lot, limitPrice, _Symbol, limitSL, 0,
                              ORDER_TIME_GTC, 0, "RetestLimit");
      PrintResult(StringFormat("PlaceRetestLimit SELL_LIMIT @ %.5f SL=%.5f", limitPrice, limitSL));
   }
   else
   {
      double limitPrice = NormalizeDouble(closePrice - bufferPts * _Point, _Digits);
      double limitSL    = NormalizeDouble(limitPrice - atrPts * _Point, _Digits);
      ok = g_trade.BuyLimit(lot, limitPrice, _Symbol, limitSL, 0,
                             ORDER_TIME_GTC, 0, "RetestLimit");
      PrintResult(StringFormat("PlaceRetestLimit BUY_LIMIT @ %.5f SL=%.5f", limitPrice, limitSL));
   }

   if (ok || g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
   {
      g_flipTicket        = g_trade.ResultOrder();
      g_retestBarsElapsed = 0;
      PrintFormat("RetestLimit placed: ticket=%llu (lot=%.2f buffer=%dpts ATR_SL=%dpts)",
                  g_flipTicket, lot, bufferPts, atrPts);
   }
   else
      PrintFormat("RetestLimit FAILED — TrySeedEntry will handle re-entry");
}

//──────────────────────────────────────────────────────────────────────────────
// ManageRetestOrder
//──────────────────────────────────────────────────────────────────────────────
void ManageRetestOrder(bool newBar)
{
   if (g_flipTicket == 0) return;

   if (!PendingOrderExists(g_flipTicket))
   {
      g_flipTicket        = 0;
      g_retestBarsElapsed = 0;
      return;
   }

   if (newBar) g_retestBarsElapsed++;

   if (InpRetestExpiryBars > 0 && g_retestBarsElapsed >= InpRetestExpiryBars)
   {
      PrintFormat("RetestLimit expired after %d bars — cancelling, seed entry takes over",
                  g_retestBarsElapsed);
      CancelRetestLimit();
      return;
   }

   if (!InpH1FilterEnabled) return;

   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (OrderGetTicket(i) != g_flipTicket) continue;

      ENUM_ORDER_TYPE otype   = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      ENUM_ORDER_TYPE flipDir = (otype == ORDER_TYPE_SELL_LIMIT)
                                 ? ORDER_TYPE_SELL
                                 : ORDER_TYPE_BUY;

      if (!H1TrendAgreesWithFlip(flipDir))
      {
         PrintFormat("RetestLimit: H1 flipped against %s — cancelling",
                     (flipDir==ORDER_TYPE_SELL ? "SELL" : "BUY"));
         CancelRetestLimit();
      }
      break;
   }
}

//──────────────────────────────────────────────────────────────────────────────
// ManageTrailingStop
//──────────────────────────────────────────────────────────────────────────────
void ManageTrailingStop()
{
   if (!SelectOurPosition()) return;

   ENUM_POSITION_TYPE posType   = g_pos.PositionType();
   double             currentSL = g_pos.StopLoss();
   ulong              ticket    = g_pos.Ticket();

   g_sym.RefreshRates();
   double ask   = g_sym.Ask();
   double bid   = g_sym.Bid();
   int    slPts = SafeDist(g_trailGap, ask, bid);
   double newSL;
   bool   shouldMove;

   if (posType == POSITION_TYPE_BUY)
   {
      newSL      = NormalizeDouble(bid - slPts * _Point, _Digits);
      shouldMove = (currentSL == 0 || newSL > currentSL + _Point * 0.5);
   }
   else
   {
      newSL      = NormalizeDouble(ask + slPts * _Point, _Digits);
      shouldMove = (currentSL == 0 || newSL < currentSL - _Point * 0.5);
   }

   if (!shouldMove) return;

   int freeze = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if (freeze > 0)
   {
      double d = (posType == POSITION_TYPE_BUY) ? (bid - currentSL) : (currentSL - ask);
      if (currentSL > 0 && d < freeze * _Point) return;
   }

   if (!g_trade.PositionModify(ticket, newSL, 0))
   {
      uint rc = g_trade.ResultRetcode();
      if (rc != TRADE_RETCODE_DONE) PrintResult("Trail SL FAILED");
   }
}

//──────────────────────────────────────────────────────────────────────────────
// ManagePeakLockSL
//──────────────────────────────────────────────────────────────────────────────
void ManagePeakLockSL()
{
   if (InpPeakLockPct <= 0)  return;
   if (!SelectOurPosition()) return;

   double currentSL = g_pos.StopLoss();
   if (currentSL == 0)       return;

   ENUM_POSITION_TYPE posType = g_pos.PositionType();
   g_sym.RefreshRates();
   double ask = g_sym.Ask();
   double bid = g_sym.Bid();

   double profitPts = (posType == POSITION_TYPE_BUY)
                      ? (bid - g_entryPrice) / _Point
                      : (g_entryPrice - ask) / _Point;

   if (profitPts > g_peakProfitPts) g_peakProfitPts = profitPts;

   if (g_peakProfitPts <= (double)InpBEPoints) return;

   double lockPts = g_peakProfitPts * InpPeakLockPct / 100.0;
   double newSL;
   bool   shouldMove;

   if (posType == POSITION_TYPE_BUY)
   {
      newSL      = NormalizeDouble(g_entryPrice + lockPts * _Point, _Digits);
      shouldMove = (newSL > currentSL + _Point * 0.5);
   }
   else
   {
      newSL      = NormalizeDouble(g_entryPrice - lockPts * _Point, _Digits);
      shouldMove = (newSL < currentSL - _Point * 0.5);
   }

   if (!shouldMove) return;

   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if (posType == POSITION_TYPE_BUY  && (bid - newSL) / _Point < stopsLevel + 5) return;
   if (posType == POSITION_TYPE_SELL && (newSL - ask)  / _Point < stopsLevel + 5) return;

   if (g_trade.PositionModify(g_pos.Ticket(), newSL, 0))
      PrintFormat("PeakLock: SL → %.5f | peak=%.0fpts × %d%% = %.0fpts locked",
                  newSL, g_peakProfitPts, InpPeakLockPct, lockPts);
   else
      PrintResult("PeakLock: SL modify FAILED");
}

//──────────────────────────────────────────────────────────────────────────────
// ManageBreakeven
//──────────────────────────────────────────────────────────────────────────────
void ManageBreakeven()
{
   if (g_beSet)              return;
   if (InpBEPoints <= 0)     return;
   if (!SelectOurPosition()) return;

   ENUM_POSITION_TYPE posType = g_pos.PositionType();
   g_sym.RefreshRates();
   double ask = g_sym.Ask();
   double bid = g_sym.Bid();

   double profitPts = (posType == POSITION_TYPE_BUY)
                      ? (bid - g_entryPrice) / _Point
                      : (g_entryPrice - ask) / _Point;

   if (profitPts < (double)InpBEPoints) return;

   double beSL, currentSL = g_pos.StopLoss();

   if (posType == POSITION_TYPE_BUY)
   {
      beSL = NormalizeDouble(g_entryPrice + InpBEBuffer * _Point, _Digits);
      if (beSL <= currentSL) { g_beSet = true; return; }
   }
   else
   {
      beSL = NormalizeDouble(g_entryPrice - InpBEBuffer * _Point, _Digits);
      if (beSL >= currentSL) { g_beSet = true; return; }
   }

   if (g_trade.PositionModify(g_pos.Ticket(), beSL, 0))
   {
      g_beSet = true;
      PrintFormat("BE locked: SL → %.5f (profit=%.0fpts)", beSL, profitPts);
   }
   else PrintResult("BE modify FAILED");
}

//──────────────────────────────────────────────────────────────────────────────
// ResetTradeState
//──────────────────────────────────────────────────────────────────────────────
void ResetTradeState()
{
   g_beSet           = false;
   g_peakProfitPts   = 0.0;
   g_trailGapInitial = GetATRPoints();
   g_trailGap        = g_trailGapInitial;
   Sleep(100);
   if (SelectOurPosition())
      g_entryPrice = g_pos.PriceOpen();
   PrintFormat("Trade state reset: entry=%.5f trailGap=%dpts", g_entryPrice, g_trailGap);
}

//──────────────────────────────────────────────────────────────────────────────
// OpenPosition
// lot: pass CalcDynamicLot() result for seed entries; 0 = use InpMinLot
//──────────────────────────────────────────────────────────────────────────────
bool OpenPosition(ENUM_ORDER_TYPE direction, bool isSeed, double lot = 0.0)
{
   if (SelectOurPosition()) { Print("OpenPosition: already open — skip"); return false; }

   if (InpMaxSpreadPoints > 0)
   {
      g_sym.RefreshRates();
      int sp = (int)MathRound((g_sym.Ask() - g_sym.Bid()) / _Point);
      if (sp > InpMaxSpreadPoints)
      {
         PrintFormat("Spread %d > %d — skip", sp, InpMaxSpreadPoints);
         return false;
      }
   }

   int atrPts = GetATRPoints();
   if (lot <= 0) lot = NormalizeLot(InpMinLot);

   for (int attempt = 1; attempt <= 3; attempt++)
   {
      g_sym.RefreshRates();
      double ask   = g_sym.Ask();
      double bid   = g_sym.Bid();
      int    slPts = SafeDist(atrPts, ask, bid);
      double sl;

      if (direction == ORDER_TYPE_BUY)
      {
         sl = NormalizeDouble(ask - slPts * _Point, _Digits);
         g_trade.Buy(lot, _Symbol, ask, sl, 0, "H1FlipTrail");
      }
      else
      {
         sl = NormalizeDouble(bid + slPts * _Point, _Digits);
         g_trade.Sell(lot, _Symbol, bid, sl, 0, "H1FlipTrail");
      }

      uint rc = g_trade.ResultRetcode();
      PrintResult(StringFormat("[%s] OpenPos %s%s attempt=%d lot=%.2f SL=%dpts",
                  _Symbol, (direction==ORDER_TYPE_BUY?"BUY":"SELL"),
                  (isSeed?"[SEED]":""), attempt, lot, slPts));

      if (rc == TRADE_RETCODE_DONE)
      {
         if (isSeed) g_slFlipCount = 0;
         g_standingDown    = false;
         g_peakProfitPts   = 0.0;
         g_trailGapInitial = atrPts;
         g_trailGap        = atrPts;
         g_beSet           = false;
         Sleep(100);
         if (SelectOurPosition())
            g_entryPrice = g_pos.PriceOpen();
         return true;
      }

      if (rc == TRADE_RETCODE_REQUOTE      ||
          rc == TRADE_RETCODE_PRICE_CHANGED ||
          rc == TRADE_RETCODE_PRICE_OFF     ||
          rc == TRADE_RETCODE_INVALID_STOPS)
      { PrintFormat("Retryable rc=%u — retry %d/3", rc, attempt); Sleep(200); continue; }

      break;
   }

   Print("OpenPosition FAILED after 3 attempts");
   return false;
}

//──────────────────────────────────────────────────────────────────────────────
// CloseOurPosition
//──────────────────────────────────────────────────────────────────────────────
bool CloseOurPosition(const string reason)
{
   if (!SelectOurPosition()) return true;
   ulong ticket    = g_pos.Ticket();
   g_closingForCap = true;
   bool ok         = g_trade.PositionClose(ticket, InpMaxSlippagePoints);
   PrintResult(StringFormat("ClosePos [%s] ticket=%llu", reason, ticket));
   if (!ok) g_closingForCap = false;
   return ok;
}

//──────────────────────────────────────────────────────────────────────────────
// TrySeedEntry
// Pattern: InpMinPullbackBars+ opposite candles → 2 in-direction candles
// H1 bias gates which direction we look for.
// Score 0-100 → dynamic lot MinLot..MaxLot.
// Blocked while a retest limit is pending.
//──────────────────────────────────────────────────────────────────────────────
void TrySeedEntry()
{
   if (SelectOurPosition()) return;
   if (g_standingDown)      return;
   if (!IsInTradingHours()) return;

   if (g_flipTicket != 0 && PendingOrderExists(g_flipTicket)) return;

   if (InpCooldownSeconds > 0 && g_lastSLFlipTime > 0)
   {
      int elapsed = (int)(TimeCurrent() - g_lastSLFlipTime);
      if (elapsed < InpCooldownSeconds)
      {
         PrintFormat("Cooldown: %ds remaining", InpCooldownSeconds - elapsed);
         return;
      }
   }

   int            h1Bias = GetH1Bias();
   ENUM_ORDER_TYPE dir   = ORDER_TYPE_BUY;
   int             score = -1;

   if (h1Bias == 1)       // H1 bullish → look for BUY pullback
   {
      score = ScorePullbackSetup(ORDER_TYPE_BUY);
      dir   = ORDER_TYPE_BUY;
   }
   else if (h1Bias == -1) // H1 bearish → look for SELL pullback
   {
      score = ScorePullbackSetup(ORDER_TYPE_SELL);
      dir   = ORDER_TYPE_SELL;
   }
   else                   // H1 filter off → try both, take higher score
   {
      int scoreBuy  = ScorePullbackSetup(ORDER_TYPE_BUY);
      int scoreSell = ScorePullbackSetup(ORDER_TYPE_SELL);

      if (scoreBuy >= 0 && scoreBuy >= scoreSell)
         { dir = ORDER_TYPE_BUY;  score = scoreBuy; }
      else if (scoreSell >= 0)
         { dir = ORDER_TYPE_SELL; score = scoreSell; }
   }

   if (score < 0) return;  // no valid pullback pattern on this bar

   double lot = CalcDynamicLot(score);
   PrintFormat("Pullback %s: score=%d/100 → lot=%.2f",
               (dir==ORDER_TYPE_BUY ? "BUY" : "SELL"), score, lot);

   OpenPosition(dir, true, lot);
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

   g_isNetting = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) ==
                  ACCOUNT_MARGIN_MODE_RETAIL_NETTING);
   PrintFormat("Account type: %s", g_isNetting ? "NETTING" : "HEDGING");

   g_atrHandle = iATR(_Symbol, PERIOD_M1, InpATRPeriod);
   if (g_atrHandle == INVALID_HANDLE) Print("WARNING: ATR handle failed — using SL floor");

   if (InpH1FilterEnabled)
   {
      g_emaHandle = iMA(_Symbol, PERIOD_H1, InpH1EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if (g_emaHandle == INVALID_HANDLE)
         Print("WARNING: H1 EMA handle failed — filter disabled");
      else
         PrintFormat("H1 EMA(%d) filter: ON", InpH1EMAPeriod);
   }
   else
      Print("H1 filter: OFF");

   int stopsLevel    = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_effectiveSLMin  = MathMax(InpSLPoints, (stopsLevel > 0 ? stopsLevel + 5 : 0));
   g_trailGap        = g_effectiveSLMin;
   g_trailGapInitial = g_effectiveSLMin;

   double minLot = NormalizeLot(InpMinLot);
   if (minLot < g_sym.LotsMin())
   {
      PrintFormat("INIT FAILED: MinLot %.2f < broker min %.2f", minLot, g_sym.LotsMin());
      return INIT_FAILED;
   }

   PrintFormat("H1confirmFlipTrail v3.10 | %s | ATR(%d)×%.1f(floor=%dpts) | "
               "Trail:100%%→50%%→25%%→15%% | BE@%dpts+%d | "
               "H1EMA%d=%s | PeakLock=%d%% | "
               "Entry: pullback≥%dbar+2confirm | Lot:%.2f→%.2f | "
               "Retest: buf=%dpts exp=%dbars | MaxFlips=%d | Fill=%s | Magic=%lld",
               _Symbol, InpATRPeriod, InpATRMultiplier, g_effectiveSLMin,
               InpBEPoints, InpBEBuffer,
               InpH1EMAPeriod, InpH1FilterEnabled ? "ON" : "OFF",
               InpPeakLockPct,
               InpMinPullbackBars, InpMinLot, InpMaxLot,
               InpRetestBufferPts, InpRetestExpiryBars,
               InpMaxSLFlips, EnumToString(filling), InpMagicNumber);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if (g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if (g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
   CancelRetestLimit();
   PrintFormat("H1confirmFlipTrail v3.10 deinit (reason=%d).", reason);
}

void OnTick()
{
   if (g_standingDown && SelectOurPosition())
   { Print("Standdown cleanup"); CloseOurPosition("Standdown"); return; }

   datetime bt     = iTime(_Symbol, PERIOD_M1, 0);
   bool     newBar = (bt != 0 && bt != g_lastBarTime);
   if (newBar) g_lastBarTime = bt;

   if (SelectOurPosition())
   {
      UpdateTrailGap();
      ManageBreakeven();
      ManageTrailingStop();
      ManagePeakLockSL();
   }
   else
   {
      if (newBar)
      {
         ManageRetestOrder(true);
         TrySeedEntry();
      }
      else
      {
         ManageRetestOrder(false);
      }
   }
}

//──────────────────────────────────────────────────────────────────────────────
// OnTradeTransaction
//──────────────────────────────────────────────────────────────────────────────
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     request,
                        const MqlTradeResult&      result)
{
   if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal = trans.deal;
   if (deal == 0 || deal == g_lastDeal) return;

   if (!HistoryDealSelect(deal))
   {
      HistorySelect(TimeCurrent() - 60, TimeCurrent());
      if (!HistoryDealSelect(deal)) { PrintFormat("OTT: deal %llu not found", deal); return; }
   }

   if (HistoryDealGetString (deal, DEAL_SYMBOL) != _Symbol)              return;
   if (HistoryDealGetInteger(deal, DEAL_MAGIC)  != (long)InpMagicNumber) return;

   ENUM_DEAL_ENTRY  entry     = (ENUM_DEAL_ENTRY) HistoryDealGetInteger(deal, DEAL_ENTRY);
   ENUM_DEAL_REASON reason    = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);
   ENUM_DEAL_TYPE   dealType  = (ENUM_DEAL_TYPE)  HistoryDealGetInteger(deal, DEAL_TYPE);
   ulong            dealOrder = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);

   PrintFormat("OTT: deal=%llu entry=%s reason=%s type=%s order=%llu",
               deal, EnumToString(entry), EnumToString(reason),
               EnumToString(dealType), dealOrder);

   if (g_closingForCap) { g_closingForCap = false; Print("OTT: controlled close"); return; }

   g_lastDeal = deal;

   bool isSLClose = (reason == DEAL_REASON_SL &&
                     (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT));

   bool isFlipFire = (g_flipTicket != 0 && dealOrder == g_flipTicket &&
                      (entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT));

   if (!isSLClose && !isFlipFire) return;

   if (isSLClose)
   {
      g_slFlipCount++;
      g_lastSLFlipTime = TimeCurrent();
      g_flipTicket     = 0;
      PrintFormat("SL close #%d (cap=%d)", g_slFlipCount, InpMaxSLFlips);

      if (g_slFlipCount >= InpMaxSLFlips)
      {
         PrintFormat("SL cap reached — standing down");
         g_standingDown = true;
         CancelRetestLimit();
         return;
      }

      ENUM_POSITION_TYPE closedPosType = (dealType == DEAL_TYPE_SELL)
                                          ? POSITION_TYPE_BUY
                                          : POSITION_TYPE_SELL;

      ENUM_ORDER_TYPE flipDir = (closedPosType == POSITION_TYPE_BUY)
                                 ? ORDER_TYPE_SELL
                                 : ORDER_TYPE_BUY;

      if (H1TrendAgreesWithFlip(flipDir))
      {
         double closePrice = HistoryDealGetDouble(deal, DEAL_PRICE);
         PlaceRetestLimit(closePrice, closedPosType);
      }
      else
         PrintFormat("RetestLimit skipped: H1 disagrees with %s — waiting for seed",
                     (flipDir==ORDER_TYPE_SELL?"SELL":"BUY"));
   }

   if (isFlipFire)
   {
      g_flipTicket        = 0;
      g_retestBarsElapsed = 0;
      PrintFormat("RetestLimit fired — new position opened with SL embedded");
      Sleep(200);
      ResetTradeState();
   }
}
