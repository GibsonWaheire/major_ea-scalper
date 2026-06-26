//+------------------------------------------------------------------+
//|  H1confirmFlipTrail.mq5  v3                                      |
//|  Retest-limit flip architecture                                   |
//|                                                                   |
//|  WHAT CHANGED FROM v2                                            |
//|  ──────────────────────                                          |
//|  Flip mechanism redesigned:                                      |
//|  OLD: SELL_STOP placed alongside running trade, fires on SL hit  |
//|  NEW: No pending order while trade runs.                         |
//|       After SL hit → SELL_LIMIT (or BUY_LIMIT) placed at         |
//|       close price ± InpRetestBufferPts.                          |
//|       Fires only if price retests that level — cleaner entry.    |
//|       Limit has ATR SL embedded → no naked positions ever.       |
//|       If limit expires (InpRetestExpiryBars) or H1 flips         |
//|       against it → cancelled → TrySeedEntry takes over.         |
//|                                                                   |
//|  SAME AS v2                                                      |
//|  SL=0 bug fix, peak profit lock, H1 EMA filter, progressive     |
//|  trail 100%→50%→25%→15%, breakeven, body filter                 |
//+------------------------------------------------------------------+
#property copyright "FlipTrail EA"
#property link      ""
#property version   "3.00"
#property description "H1confirmFlipTrail v3: retest-limit flip + peak lock + H1 filter"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Trade ==="
input double InpLotSize            = 0.1;   // LotSize
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

input group "=== Candle Body Filter ==="
input int    InpMinBodyPct         = 30;    // MinBodyPct: min body % of range (0 = off)

input group "=== H1 Trend Filter ==="
input bool   InpH1FilterEnabled    = true;  // H1FilterEnabled
input int    InpH1EMAPeriod        = 20;    // H1EMAPeriod

input group "=== Peak Profit Lock ==="
input int    InpPeakLockPct        = 50;    // PeakLockPct: lock % of peak profit (0 = off)
// Example: peak=+8000pts, lock=50% → SL floor = entry+4000pts

input group "=== Retest Limit ==="
input int    InpRetestBufferPts    = 10;    // RetestBufferPts: pts above/below close price for limit
input int    InpRetestExpiryBars   = 20;    // RetestExpiryBars: M1 bars before auto-cancel (0 = GTC)
// After SL close: SELL_LIMIT placed at closePrice+buffer (BUY close) or BUY_LIMIT at closePrice-buffer (SELL close)
// If price retests → limit fires → new position WITH SL embedded
// If price never retests → expires after N bars → TrySeedEntry takes over

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
ulong    g_flipTicket        = 0;      // Retest limit order ticket
int      g_retestBarsElapsed = 0;      // M1 bars since retest limit was placed
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
   lot = MathMax(lot, MathMax(minL, 0.02));
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
// H1TrendAgreesWithFlip
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
// Called from OTT after a position closes by SL.
// closedPosType = the type of the position that just closed.
// closePrice    = the deal fill price (where SL was hit).
//
// BUY closed  → SELL_LIMIT at closePrice + buffer  (above current price)
//               fires if price bounces back up
// SELL closed → BUY_LIMIT  at closePrice - buffer  (below current price)
//               fires if price bounces back down
//
// Both orders have ATR-based SL embedded at placement.
//──────────────────────────────────────────────────────────────────────────────
void PlaceRetestLimit(double closePrice, ENUM_POSITION_TYPE closedPosType)
{
   if (PendingOrderExists(g_flipTicket)) return; // Already have one

   g_sym.RefreshRates();
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int spread     = (int)MathRound((g_sym.Ask() - g_sym.Bid()) / _Point);
   int minDist    = MathMax(stopsLevel + spread + 2, 1);
   int bufferPts  = MathMax(InpRetestBufferPts, minDist);

   int    atrPts  = GetATRPoints();
   double lot     = NormalizeLot(g_isNetting ? InpLotSize * 2.0 : InpLotSize);
   bool   ok      = false;

   if (closedPosType == POSITION_TYPE_BUY)
   {
      // BUY closed → place SELL_LIMIT above close price
      double limitPrice = NormalizeDouble(closePrice + bufferPts * _Point, _Digits);
      double limitSL    = NormalizeDouble(limitPrice + atrPts * _Point, _Digits);
      ok = g_trade.SellLimit(lot, limitPrice, _Symbol, limitSL, 0,
                              ORDER_TIME_GTC, 0, "RetestLimit");
      PrintResult(StringFormat("PlaceRetestLimit SELL_LIMIT @ %.5f SL=%.5f", limitPrice, limitSL));
   }
   else
   {
      // SELL closed → place BUY_LIMIT below close price
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
// Runs only when there is NO open position.
// Watches the pending retest limit order:
//   - Count bars elapsed since placement
//   - Cancel if expired (InpRetestExpiryBars)
//   - Cancel if H1 has flipped against the limit direction
// When cancelled: g_flipTicket = 0 → TrySeedEntry unblocked
//──────────────────────────────────────────────────────────────────────────────
void ManageRetestOrder(bool newBar)
{
   if (g_flipTicket == 0) return;

   // Clean up stale ticket
   if (!PendingOrderExists(g_flipTicket))
   {
      g_flipTicket        = 0;
      g_retestBarsElapsed = 0;
      return;
   }

   // Count elapsed M1 bars
   if (newBar) g_retestBarsElapsed++;

   // Expiry check
   if (InpRetestExpiryBars > 0 && g_retestBarsElapsed >= InpRetestExpiryBars)
   {
      PrintFormat("RetestLimit expired after %d bars — cancelling, seed entry takes over",
                  g_retestBarsElapsed);
      CancelRetestLimit();
      return;
   }

   // H1 filter check — cancel if H1 no longer agrees with limit direction
   if (!InpH1FilterEnabled) return;

   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (OrderGetTicket(i) != g_flipTicket) continue;

      ENUM_ORDER_TYPE otype  = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
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
// FIX: shouldMove uses (currentSL==0 OR better than current).
// Handles flip-opened positions that start with SL=0 as a safety net,
// though with retest limits the SL is embedded at order placement.
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
// ResetTradeState — called after retest limit fires
//──────────────────────────────────────────────────────────────────────────────
void ResetTradeState()
{
   g_beSet             = false;
   g_peakProfitPts     = 0.0;
   g_trailGapInitial   = GetATRPoints();
   g_trailGap          = g_trailGapInitial;
   Sleep(100);
   if (SelectOurPosition())
      g_entryPrice = g_pos.PriceOpen();
   PrintFormat("Trade state reset: entry=%.5f trailGap=%dpts", g_entryPrice, g_trailGap);
}

//──────────────────────────────────────────────────────────────────────────────
// OpenPosition — seed entry only
//──────────────────────────────────────────────────────────────────────────────
bool OpenPosition(ENUM_ORDER_TYPE direction, bool isSeed)
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

   int    atrPts = GetATRPoints();
   double lot    = NormalizeLot(InpLotSize);

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
      PrintResult(StringFormat("[%s] OpenPos %s%s attempt=%d SL=%dpts",
                  _Symbol, (direction==ORDER_TYPE_BUY?"BUY":"SELL"),
                  (isSeed?"[SEED]":""), attempt, slPts));

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
// Blocked while a retest limit order is pending (g_flipTicket != 0).
//──────────────────────────────────────────────────────────────────────────────
void TrySeedEntry()
{
   if (SelectOurPosition()) return;
   if (g_standingDown)      return;
   if (!IsInTradingHours()) return;

   // Block seed entry while retest limit is waiting to fill
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

   double c  = iClose(_Symbol, PERIOD_M1, 1);
   double o  = iOpen (_Symbol, PERIOD_M1, 1);
   double hi = iHigh (_Symbol, PERIOD_M1, 1);
   double lo = iLow  (_Symbol, PERIOD_M1, 1);

   if (InpMinBodyPct > 0)
   {
      double range = hi - lo;
      double body  = MathAbs(c - o);
      if (range > 0 && (body / range) * 100.0 < (double)InpMinBodyPct)
      {
         PrintFormat("Skip: body=%.0f%% < %d%%", (body/range)*100.0, InpMinBodyPct);
         return;
      }
   }

   ENUM_ORDER_TYPE dir = (c > o) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if (!H1TrendAgreesWithFlip(dir))
   {
      PrintFormat("Seed %s skipped — H1 disagrees", (dir==ORDER_TYPE_BUY?"BUY":"SELL"));
      return;
   }

   if (c > o)
      { PrintFormat("Seed BUY  (O=%.5f C=%.5f)", o, c); OpenPosition(ORDER_TYPE_BUY,  true); }
   else
      { PrintFormat("Seed SELL (O=%.5f C=%.5f)", o, c); OpenPosition(ORDER_TYPE_SELL, true); }
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

   double lot = NormalizeLot(InpLotSize);
   if (lot < g_sym.LotsMin())
   {
      PrintFormat("INIT FAILED: lot %.2f < min %.2f", lot, g_sym.LotsMin());
      return INIT_FAILED;
   }

   PrintFormat("H1confirmFlipTrail v3.00 | %s | ATR(%d)×%.1f(floor=%dpts) | "
               "Trail:100%%→50%%→25%%→15%% | BE@%dpts+%d | Body>=%d%% | "
               "H1EMA%d=%s | PeakLock=%d%% | Retest: buffer=%dpts expiry=%dbars | "
               "Lot=%.2f MaxFlips=%d | Fill=%s | Magic=%lld",
               _Symbol, InpATRPeriod, InpATRMultiplier, g_effectiveSLMin,
               InpBEPoints, InpBEBuffer, InpMinBodyPct,
               InpH1EMAPeriod, InpH1FilterEnabled ? "ON" : "OFF",
               InpPeakLockPct, InpRetestBufferPts, InpRetestExpiryBars,
               lot, InpMaxSLFlips, EnumToString(filling), InpMagicNumber);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if (g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if (g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
   CancelRetestLimit();
   PrintFormat("H1confirmFlipTrail v3.00 deinit (reason=%d).", reason);
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
      // ── Active trade: trail SL, BE, peak lock ──────────────────────────
      // No pending flip order while position is alive.
      UpdateTrailGap();
      ManageBreakeven();
      ManageTrailingStop();
      ManagePeakLockSL();
   }
   else
   {
      // ── No position: manage retest limit then try seed ──────────────────
      // ManageRetestOrder watches expiry and H1 flip, runs on new bar.
      // TrySeedEntry is blocked while g_flipTicket is pending.
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

   // Position closed by SL
   bool isSLClose = (reason == DEAL_REASON_SL &&
                     (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT));

   // Retest limit order filled — new position opened
   bool isFlipFire = (g_flipTicket != 0 && dealOrder == g_flipTicket &&
                      (entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT));

   if (!isSLClose && !isFlipFire) return;

   if (isSLClose)
   {
      g_slFlipCount++;
      g_lastSLFlipTime = TimeCurrent();
      g_flipTicket     = 0;   // No flip stop was running, but clear just in case
      PrintFormat("SL close #%d (cap=%d)", g_slFlipCount, InpMaxSLFlips);

      if (g_slFlipCount >= InpMaxSLFlips)
      {
         PrintFormat("SL cap reached — standing down");
         g_standingDown = true;
         CancelRetestLimit();
         return;
      }

      // Determine what type of position just closed so we know which limit to place
      // dealType == DEAL_TYPE_SELL (exit deal sells to close a BUY position)
      // dealType == DEAL_TYPE_BUY  (exit deal buys  to close a SELL position)
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
      Sleep(200);    // Give broker time to fully register the new position
      ResetTradeState();
   }
}
