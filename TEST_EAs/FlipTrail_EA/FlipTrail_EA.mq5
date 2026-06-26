//+------------------------------------------------------------------+
//|  FlipTrail_EA.mq5  v11                                            |
//|  Progressive trail + instant flip stop order                     |
//|                                                                    |
//|  MECHANICS                                                        |
//|  ─────────                                                        |
//|  Position opens with ATR-based SL, no TP.                       |
//|  A SELL STOP / BUY STOP (flip order) is placed AT the SL level. |
//|  Both trail together — SL moves, flip order follows immediately. |
//|  When SL level is hit:                                           |
//|    • Position closes (SL)                                        |
//|    • Flip stop fires → reverse position opens instantly          |
//|    • New flip stop placed at new SL level                        |
//|                                                                   |
//|  PROGRESSIVE TRAIL TIGHTENING                                    |
//|  ──────────────────────────────                                  |
//|  < 1× ATR gap in profit  → trail = 100% of ATR gap (full)       |
//|  ≥ 1× ATR gap in profit  → trail = 50% of ATR gap               |
//|  ≥ 2× ATR gap in profit  → trail = 25% of ATR gap               |
//|  ≥ 3× ATR gap in profit  → trail = 15% of ATR gap (very tight)  |
//|  Captures far more of the move on strong gold momentum           |
//+------------------------------------------------------------------+
#property copyright "FlipTrail EA"
#property link      ""
#property version   "11.00"
#property description "Progressive trail + flip stop order. SL and flip order always in sync."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Trade ==="
input double InpLotSize           = 0.1;   // LotSize
input int    InpSLPoints          = 50;    // SLPoints: minimum SL floor
input long   InpMagicNumber       = 112233;// MagicNumber
input int    InpMaxSlippagePoints = 30;    // MaxSlippagePoints
input int    InpMaxSpreadPoints   = 0;     // MaxSpreadPoints (0 = off)

input group "=== ATR Stop Loss ==="
input int    InpATRPeriod         = 14;    // ATRPeriod
input double InpATRMultiplier     = 1.5;   // ATRMultiplier: SL = ATR × this

input group "=== Breakeven ==="
input int    InpBEPoints          = 50;    // BEPoints: profit pts to lock BE (0 = off)
input int    InpBEBuffer          = 10;    // BEBuffer: SL moves to entry + this

input group "=== Candle Body Filter ==="
input int    InpMinBodyPct        = 30;    // MinBodyPct: min body as % of range (0 = off)

input group "=== Flip Guard ==="
input int    InpMaxSLFlips        = 50;    // MaxSLFlips cap
input int    InpCooldownSeconds   = 0;     // CooldownSeconds after SL flip (0 = off)

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

int      g_atrHandle       = INVALID_HANDLE;
bool     g_isNetting       = false;

int      g_effectiveSLMin  = 0;
int      g_trailGap        = 0;     // Current trail gap (tightens progressively)
int      g_trailGapInitial = 0;     // ATR SL at entry (reference for ratio)
datetime g_lastBarTime     = 0;
ulong    g_flipTicket      = 0;     // Flip stop order — always at SL level
int      g_slFlipCount     = 0;
bool     g_standingDown    = false;
ulong    g_lastDeal        = 0;
bool     g_closingForCap   = false;

// Per-trade state
bool     g_beSet           = false;
double   g_entryPrice      = 0.0;
datetime g_lastSLFlipTime  = 0;

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
// UpdateTrailGap
// Tightens g_trailGap as profit grows relative to initial ATR SL.
// All ratios — no fixed points.
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

   double ratio  = profitPts / (double)g_trailGapInitial;
   int    newGap;

   if      (ratio >= 3.0) newGap = (int)MathRound(g_trailGapInitial * 0.15);
   else if (ratio >= 2.0) newGap = (int)MathRound(g_trailGapInitial * 0.25);
   else if (ratio >= 1.0) newGap = (int)MathRound(g_trailGapInitial * 0.50);
   else                   newGap = g_trailGapInitial;

   newGap = MathMax(newGap, g_effectiveSLMin);

   if (newGap < g_trailGap)   // Only ever tighten, never widen
   {
      PrintFormat("Trail tightened: profit=%.0fpts (%.1f×ATR) → gap %d→%dpts",
                  profitPts, ratio, g_trailGap, newGap);
      g_trailGap = newGap;
   }
}

//──────────────────────────────────────────────────────────────────────────────
// CancelFlipOrder
//──────────────────────────────────────────────────────────────────────────────
void CancelFlipOrder()
{
   if (g_flipTicket == 0) return;
   if (!PendingOrderExists(g_flipTicket)) { g_flipTicket = 0; return; }
   if (g_trade.OrderDelete(g_flipTicket))
   {
      PrintFormat("FlipStop %llu cancelled", g_flipTicket);
      g_flipTicket = 0;
   }
   else
      PrintResult(StringFormat("CancelFlipStop %llu FAILED", g_flipTicket));
}

//──────────────────────────────────────────────────────────────────────────────
// PlaceFlipOrder
// SELL STOP (BUY pos) / BUY STOP (SELL pos) placed exactly at SL level.
// On netting accounts: 2× lot so net position flips (closes old + opens new).
// On hedging accounts: 1× lot (opens reverse alongside closing old via SL).
//──────────────────────────────────────────────────────────────────────────────
void PlaceFlipOrder()
{
   if (!SelectOurPosition())              return;
   if (PendingOrderExists(g_flipTicket))  return;

   double slLevel = g_pos.StopLoss();
   if (slLevel == 0) return;

   // Netting needs 2× lot: closes existing 1× + opens reverse 1×
   double lot = NormalizeLot(g_isNetting ? InpLotSize * 2.0 : InpLotSize);
   bool   ok  = false;

   if (g_pos.PositionType() == POSITION_TYPE_BUY)
      ok = g_trade.SellStop(lot, slLevel, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "FlipStop");
   else
      ok = g_trade.BuyStop(lot, slLevel, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "FlipStop");

   PrintResult("PlaceFlipOrder");
   if (ok || g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
   {
      g_flipTicket = g_trade.ResultOrder();
      PrintFormat("FlipStop placed: ticket=%llu at %.5f (lot=%.2f)",
                  g_flipTicket, slLevel, lot);
   }
}

//──────────────────────────────────────────────────────────────────────────────
// ManageFlipOrder
// Keeps flip stop order at current SL level. Moves with every trail update.
//──────────────────────────────────────────────────────────────────────────────
void ManageFlipOrder()
{
   if (!SelectOurPosition()) { CancelFlipOrder(); return; }

   if (!PendingOrderExists(g_flipTicket))
   {
      g_flipTicket = 0;
      PlaceFlipOrder();
      return;
   }

   double slLevel = g_pos.StopLoss();
   if (slLevel == 0) return;

   // Find current flip order price
   double flipPrice = 0;
   for (int i = OrdersTotal()-1; i >= 0; i--)
   {
      if (OrderGetTicket(i) == g_flipTicket)
      {
         flipPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         break;
      }
   }
   if (flipPrice == 0) return;

   // Update only if SL has moved by at least 1pt
   if (MathAbs(flipPrice - slLevel) / _Point < 1.0) return;

   if (g_trade.OrderModify(g_flipTicket, slLevel, 0, 0, ORDER_TIME_GTC, 0))
      PrintFormat("FlipStop → %.5f (tracking SL)", slLevel);
   else
   {
      PrintResult("FlipStop modify FAILED — replacing");
      CancelFlipOrder();
      PlaceFlipOrder();
   }
}

//──────────────────────────────────────────────────────────────────────────────
// ManageTrailingStop — trails SL, flip order follows in ManageFlipOrder
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
      shouldMove = (newSL > currentSL + _Point * 0.5);
   }
   else
   {
      newSL      = NormalizeDouble(ask + slPts * _Point, _Digits);
      shouldMove = (newSL < currentSL - _Point * 0.5);
   }

   if (!shouldMove) return;

   int freeze = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if (freeze > 0)
   {
      double d = (posType == POSITION_TYPE_BUY) ? (bid - currentSL) : (currentSL - ask);
      if (d < freeze * _Point) return;
   }

   if (!g_trade.PositionModify(ticket, newSL, 0))
   {
      uint rc = g_trade.ResultRetcode();
      if (rc != TRADE_RETCODE_DONE) PrintResult("Trail SL FAILED");
   }
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
// ResetTradeState — called when a new position is detected after a flip
//──────────────────────────────────────────────────────────────────────────────
void ResetTradeState()
{
   g_beSet          = false;
   g_trailGapInitial = GetATRPoints();
   g_trailGap       = g_trailGapInitial;
   Sleep(100);
   if (SelectOurPosition())
      g_entryPrice = g_pos.PriceOpen();
   PrintFormat("Trade state reset: entry=%.5f trailGap=%dpts", g_entryPrice, g_trailGap);
}

//──────────────────────────────────────────────────────────────────────────────
// OpenPosition — seed entry only (flips handled by stop order)
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
         g_trade.Buy(lot, _Symbol, ask, sl, 0, "FlipTrail");
      }
      else
      {
         sl = NormalizeDouble(bid + slPts * _Point, _Digits);
         g_trade.Sell(lot, _Symbol, bid, sl, 0, "FlipTrail");
      }

      uint rc = g_trade.ResultRetcode();
      PrintResult(StringFormat("[%s] OpenPos %s%s attempt=%d SL=%dpts",
                  _Symbol, (direction==ORDER_TYPE_BUY?"BUY":"SELL"),
                  (isSeed?"[SEED]":""), attempt, slPts));

      if (rc == TRADE_RETCODE_DONE)
      {
         if (isSeed) { g_slFlipCount = 0; g_standingDown = false; }
         g_trailGapInitial = atrPts;
         g_trailGap        = atrPts;
         g_beSet           = false;
         Sleep(100);
         if (SelectOurPosition())
            g_entryPrice = g_pos.PriceOpen();
         PlaceFlipOrder();   // Flip stop immediately at SL level
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
   CancelFlipOrder();
   ulong ticket    = g_pos.Ticket();
   g_closingForCap = true;
   bool ok         = g_trade.PositionClose(ticket, InpMaxSlippagePoints);
   PrintResult(StringFormat("ClosePos [%s] ticket=%llu", reason, ticket));
   if (!ok) g_closingForCap = false;
   return ok;
}

//──────────────────────────────────────────────────────────────────────────────
// TrySeedEntry — body filter applied
//──────────────────────────────────────────────────────────────────────────────
void TrySeedEntry()
{
   if (SelectOurPosition()) return;
   if (g_standingDown)      return;
   if (!IsInTradingHours()) return;

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

   int stopsLevel   = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_effectiveSLMin = MathMax(InpSLPoints, (stopsLevel > 0 ? stopsLevel + 5 : 0));
   g_trailGap       = g_effectiveSLMin;
   g_trailGapInitial = g_effectiveSLMin;

   double lot = NormalizeLot(InpLotSize);
   if (lot < g_sym.LotsMin())
   {
      PrintFormat("INIT FAILED: lot %.2f < min %.2f", lot, g_sym.LotsMin());
      return INIT_FAILED;
   }

   PrintFormat("FlipTrail v11.00 | %s | SL=ATR(%d)×%.1f(floor=%dpts) | "
               "Trail: 100%%→50%%→25%%→15%% at 0/1/2/3× ATR profit | "
               "BE@%dpts+%d | Body>=%d%% | FlipStop=%s | "
               "Lot=%.2f MaxSLFlips=%d | Fill=%s | Magic=%lld",
               _Symbol,
               InpATRPeriod, InpATRMultiplier, g_effectiveSLMin,
               InpBEPoints, InpBEBuffer,
               InpMinBodyPct,
               g_isNetting ? "2×lot(netting)" : "1×lot(hedging)",
               lot, InpMaxSLFlips, EnumToString(filling), InpMagicNumber);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if (g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   PrintFormat("FlipTrail v11.00 deinit (reason=%d).", reason);
}

void OnTick()
{
   if (g_standingDown && SelectOurPosition())
   { Print("Standdown cleanup"); CloseOurPosition("Standdown"); return; }

   datetime bt     = iTime(_Symbol, PERIOD_M1, 0);
   bool     newBar = (bt != 0 && bt != g_lastBarTime);
   if (newBar) g_lastBarTime = bt;

   if (newBar && !SelectOurPosition()) TrySeedEntry();

   if (SelectOurPosition())
   {
      UpdateTrailGap();      // Tighten trail as profit grows (ratio-based)
      ManageBreakeven();     // Lock profit at entry+buffer
      ManageTrailingStop();  // Move SL
      ManageFlipOrder();     // Keep flip stop in sync with SL
   }
}

//──────────────────────────────────────────────────────────────────────────────
// OnTradeTransaction
//
// Two events to handle:
// 1. Position closed (SL hit or flip stop fired on netting INOUT)
//    → increment flip count, update cooldown, check cap
// 2. Flip stop order fired → new position open (DEAL_ENTRY_IN or INOUT)
//    → reset per-trade state, place new flip stop on new position
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

   // ── Position closed (SL hit) ─────────────────────────────────────────────
   bool isSLClose = (reason == DEAL_REASON_SL &&
                     (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT));

   // ── Flip stop order fired (new position opened) ──────────────────────────
   bool isFlipFire = (g_flipTicket != 0 && dealOrder == g_flipTicket &&
                      (entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT));

   if (!isSLClose && !isFlipFire) return;

   if (isSLClose)
   {
      g_slFlipCount++;
      g_lastSLFlipTime = TimeCurrent();
      g_flipTicket     = 0;   // Old flip order fired or is now invalid
      PrintFormat("SL flip #%d (cap=%d)", g_slFlipCount, InpMaxSLFlips);

      if (g_slFlipCount >= InpMaxSLFlips)
      {
         PrintFormat("SL cap reached — standing down");
         g_standingDown = true;
         CancelFlipOrder();
         return;
      }
   }

   if (isFlipFire)
   {
      // New position opened by flip stop — reset state and arm new flip stop
      g_flipTicket = 0;
      PrintFormat("FlipStop fired — new position opened");
      ResetTradeState();
      Sleep(200);            // Give broker time to fully register the new position
      PlaceFlipOrder();      // Arm new flip stop on the reverse position
   }
}
