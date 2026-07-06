//+------------------------------------------------------------------+
//|  FlipTrail_EA.mq5  v11.04                                         |
//|  ATR trail + fixed TP — good R:R scalper                         |
//|                                                                    |
//|  MECHANICS                                                        |
//|  ─────────                                                        |
//|  Entry: new bar candle body direction (optional body % filter)   |
//|  Exit:  ATR trailing SL — moves with price every tick            |
//|  When SL is hit → position closes, EA waits for next bar signal  |
//|  No pending stop orders placed at any time                       |
//|                                                                   |
//|  PROGRESSIVE TRAIL TIGHTENING                                    |
//|  ──────────────────────────────                                  |
//|  < 1× ATR gap in profit  → trail = 100% of ATR gap (full)       |
//|  ≥ 1× ATR gap in profit  → trail = 50% of ATR gap               |
//|  ≥ 2× ATR gap in profit  → trail = 25% of ATR gap               |
//|  ≥ 3× ATR gap in profit  → trail = 15% of ATR gap (very tight)  |
//+------------------------------------------------------------------+
#property copyright "FlipTrail EA"
#property link      ""
#property version   "11.04"
#property description "FlipTrail v11.04: ATR SL + fixed TP (ATR × multiplier) for positive R:R scalping"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Trade ==="
input double InpRiskPct           = 1.0;   // RiskPct: % of equity to risk per trade (e.g. 1.0 = 1%)
input double InpMinLot            = 0.01;  // MinLot: floor lot size
input double InpMaxLot            = 1.00;  // MaxLot: ceiling lot size
input int    InpSLPoints          = 50;    // SLPoints: minimum SL floor
input long   InpMagicNumber       = 112233;// MagicNumber
input int    InpMaxSlippagePoints = 30;    // MaxSlippagePoints
input int    InpMaxSpreadPoints   = 0;     // MaxSpreadPoints (0 = off)

input group "=== ATR Stop Loss & Take Profit ==="
input int    InpATRPeriod         = 14;    // ATRPeriod
input double InpATRMultiplier     = 1.5;   // ATRMultiplier: SL = ATR × this
input double InpTPMultiplier      = 2.0;   // TPMultiplier: TP = ATR × this (0 = trail only, no TP)
//  R:R = TPMultiplier / ATRMultiplier. Default 2.0/1.5 = 1.33 R:R.
//  Recommended: TPMultiplier >= 2× ATRMultiplier for positive expectancy.

input group "=== Breakeven ==="
input int    InpBEPoints          = 50;    // BEPoints: profit pts to lock BE (0 = off)
input int    InpBEBuffer          = 10;    // BEBuffer: SL moves to entry + this

input group "=== Candle Body Filter ==="
input int    InpMinBodyPct        = 30;    // MinBodyPct: min body as % of range (0 = off)

input group "=== Peak Profit Lock ==="
input int    InpPeakLockPct        = 60;  // PeakLockPct: % of peak profit to protect as SL — 0=off
//  Example: peak=+8000pts, lock=60% → SL moves to entry+4800pts. Trade cannot close at negative.

input group "=== Candle Step Lock ==="
input int    InpCandleStepBars     = 3;   // CandleStepBars: consecutive favorable bar closes to trigger SL step (0=off)
input int    InpCandleStepLockPct  = 40;  // CandleStepLockPct: % of current profit to lock on each step
//  Every N consecutive favorable closes → SL = entry + currentProfit×lock%. Resets on unfavorable bar.

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
int      g_trailGap        = 0;
int      g_trailGapInitial = 0;
datetime g_lastBarTime     = 0;

// Per-trade state
bool     g_beSet           = false;
double   g_entryPrice      = 0.0;
double   g_peakProfitPts   = 0.0;
int      g_candleFavorCount = 0;

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

double NormalizeLot(double lot)
{
   double step = g_sym.LotsStep();
   double minL = g_sym.LotsMin();
   double maxL = g_sym.LotsMax();
   if (step <= 0.0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, MathMax(minL, InpMinLot));
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
// CalcLotByRisk
// Sizes lot so that the ATR SL costs exactly InpRiskPct% of current equity.
// Clamped to [InpMinLot, InpMaxLot].
//──────────────────────────────────────────────────────────────────────────────
double CalcLotByRisk(int slPts)
{
   if (slPts <= 0) return NormalizeLot(InpMinLot);

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPct / 100.0;
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tickVal <= 0 || tickSize <= 0) return NormalizeLot(InpMinLot);

   // slPts × _Point = SL distance in price; convert to ticks then to money per lot
   double slMoney   = (slPts * _Point / tickSize) * tickVal;
   if (slMoney <= 0) return NormalizeLot(InpMinLot);

   double lot = riskMoney / slMoney;
   lot = MathMax(lot, InpMinLot);
   lot = MathMin(lot, InpMaxLot);
   return NormalizeLot(lot);
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
// ManagePeakLockSL
// Tracks the highest profit seen since entry (g_peakProfitPts) and locks
// InpPeakLockPct% of it as a hard SL floor. Works for ALL positions (seed and
// flip) once a SL is set. Runs every tick — whichever is higher (BUY) or
// lower (SELL) between this and the ATR trail wins.
//
// Example: peak=+8000pts, lock=40% → SL snaps to entry+3200pts.
// The trade CAN NEVER close at negative once the peak lock is active.
//──────────────────────────────────────────────────────────────────────────────
void ManagePeakLockSL()
{
   if (InpPeakLockPct <= 0)  return;
   if (!SelectOurPosition()) return;

   double currentSL = g_pos.StopLoss();
   if (currentSL == 0)       return; // No SL yet — FlipRiderMode handles that phase

   ENUM_POSITION_TYPE posType = g_pos.PositionType();
   g_sym.RefreshRates();
   double ask = g_sym.Ask();
   double bid = g_sym.Bid();

   double profitPts = (posType == POSITION_TYPE_BUY)
                      ? (bid - g_entryPrice) / _Point
                      : (g_entryPrice - ask) / _Point;

   // Always keep track of the best profit seen
   if (profitPts > g_peakProfitPts)
      g_peakProfitPts = profitPts;

   // Only engage lock once peak is above breakeven
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

   // Respect broker freeze/stops level
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if (posType == POSITION_TYPE_BUY  && (bid - newSL)  / _Point < stopsLevel + 5) return;
   if (posType == POSITION_TYPE_SELL && (newSL  - ask)  / _Point < stopsLevel + 5) return;

   if (g_trade.PositionModify(g_pos.Ticket(), newSL, 0))
      PrintFormat("PeakLock: SL → %.5f | peak=%.0fpts × %d%% = %.0fpts locked",
                  newSL, g_peakProfitPts, InpPeakLockPct, lockPts);
   else
      PrintResult("PeakLock: SL modify FAILED");
}

//──────────────────────────────────────────────────────────────────────────────
// ManageCandleStepLock
// Called on every NEW BAR only.
// Counts consecutive bar closes in the favorable direction. Once N consecutive
// closes are reached, locks InpCandleStepLockPct% of current profit as SL.
// Counter resets on any unfavorable bar close. SL only ever moves in favor.
//──────────────────────────────────────────────────────────────────────────────
void ManageCandleStepLock()
{
   if (InpCandleStepBars <= 0)   return;
   if (!SelectOurPosition())     return;

   double currentSL = g_pos.StopLoss();
   if (currentSL == 0)           return; // No SL yet — FlipRiderMode handles first

   ENUM_POSITION_TYPE posType = g_pos.PositionType();
   g_sym.RefreshRates();
   double ask = g_sym.Ask();
   double bid = g_sym.Bid();

   // Check if the last completed bar closed in the favorable direction
   double barClose = iClose(_Symbol, PERIOD_M1, 1);
   double barOpen  = iOpen (_Symbol, PERIOD_M1, 1);
   bool   favorable = (posType == POSITION_TYPE_BUY)  ? (barClose > barOpen)
                                                       : (barClose < barOpen);

   if (!favorable)
   {
      g_candleFavorCount = 0;  // Reset streak on any unfavorable close
      return;
   }

   g_candleFavorCount++;

   if (g_candleFavorCount < InpCandleStepBars) return; // Not enough yet

   // N consecutive favorable bars hit — lock profit
   double profitPts = (posType == POSITION_TYPE_BUY)
                      ? (bid - g_entryPrice) / _Point
                      : (g_entryPrice - ask) / _Point;

   if (profitPts <= (double)InpBEPoints) { g_candleFavorCount = 0; return; }

   double lockPts = profitPts * InpCandleStepLockPct / 100.0;
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

   g_candleFavorCount = 0; // Reset after each step regardless of move

   if (!shouldMove) return;

   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if (posType == POSITION_TYPE_BUY  && (bid - newSL) / _Point < stopsLevel + 5) return;
   if (posType == POSITION_TYPE_SELL && (newSL - ask) / _Point < stopsLevel + 5) return;

   if (g_trade.PositionModify(g_pos.Ticket(), newSL, 0))
      PrintFormat("CandleStep: SL → %.5f | %d bars × %d%% of %.0fpts = %.0fpts locked",
                  newSL, InpCandleStepBars, InpCandleStepLockPct, profitPts, lockPts);
   else
      PrintResult("CandleStep: SL modify FAILED");
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

   if (currentSL == 0) return; // No SL yet — skip trailing until SL confirmed

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
// OpenPosition
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

   for (int attempt = 1; attempt <= 3; attempt++)
   {
      g_sym.RefreshRates();
      double ask   = g_sym.Ask();
      double bid   = g_sym.Bid();
      int    slPts = SafeDist(atrPts, ask, bid);
      int    tpPts = (InpTPMultiplier > 0) ? (int)MathRound(atrPts * InpTPMultiplier) : 0;
      double lot   = CalcLotByRisk(slPts);
      double sl, tp;

      if (direction == ORDER_TYPE_BUY)
      {
         sl = NormalizeDouble(ask - slPts * _Point, _Digits);
         tp = (tpPts > 0) ? NormalizeDouble(ask + tpPts * _Point, _Digits) : 0;
         g_trade.Buy(lot, _Symbol, ask, sl, tp, "FlipTrail");
      }
      else
      {
         sl = NormalizeDouble(bid + slPts * _Point, _Digits);
         tp = (tpPts > 0) ? NormalizeDouble(bid - tpPts * _Point, _Digits) : 0;
         g_trade.Sell(lot, _Symbol, bid, sl, tp, "FlipTrail");
      }

      uint rc = g_trade.ResultRetcode();
      PrintResult(StringFormat("[%s] OpenPos %s%s attempt=%d lot=%.2f SL=%dpts TP=%dpts (%.1f%%risk)",
                  _Symbol, (direction==ORDER_TYPE_BUY?"BUY":"SELL"),
                  (isSeed?"[SEED]":""), attempt, lot, slPts, tpPts, InpRiskPct));

      if (rc == TRADE_RETCODE_DONE)
      {
         g_peakProfitPts    = 0.0;
         g_candleFavorCount = 0;
         g_trailGapInitial  = atrPts;
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
   ulong ticket = g_pos.Ticket();
   bool  ok     = g_trade.PositionClose(ticket, InpMaxSlippagePoints);
   PrintResult(StringFormat("ClosePos [%s] ticket=%llu", reason, ticket));
   return ok;
}

//──────────────────────────────────────────────────────────────────────────────
// TrySeedEntry — body filter applied
//──────────────────────────────────────────────────────────────────────────────
void TrySeedEntry()
{
   if (SelectOurPosition()) return;
   if (!IsInTradingHours()) return;

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

   if (NormalizeLot(InpMinLot) < g_sym.LotsMin())
   {
      PrintFormat("INIT FAILED: MinLot %.2f < broker min %.2f", InpMinLot, g_sym.LotsMin());
      return INIT_FAILED;
   }

   PrintFormat("FlipTrail v11.04 | %s | SL=ATR(%d)×%.1f TP=ATR×%.1f (R:R=%.2f) | "
               "Trail: 100%%→50%%→25%%→15%% at 0/1/2/3× ATR | "
               "BE@%dpts+%d | Body>=%d%% | Risk=%.1f%% Lot:%.2f→%.2f | Fill=%s | Magic=%lld",
               _Symbol,
               InpATRPeriod, InpATRMultiplier, InpTPMultiplier,
               (InpATRMultiplier > 0 ? InpTPMultiplier / InpATRMultiplier : 0),
               InpBEPoints, InpBEBuffer,
               InpMinBodyPct,
               InpRiskPct, InpMinLot, InpMaxLot,
               EnumToString(filling), InpMagicNumber);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if (g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   PrintFormat("FlipTrail v11.04 deinit (reason=%d).", reason);
}

void OnTick()
{
   datetime bt     = iTime(_Symbol, PERIOD_M1, 0);
   bool     newBar = (bt != 0 && bt != g_lastBarTime);
   if (newBar) g_lastBarTime = bt;

   if (newBar && !SelectOurPosition()) TrySeedEntry();

   if (SelectOurPosition())
   {
      UpdateTrailGap();
      ManageBreakeven();
      ManageTrailingStop();
      ManagePeakLockSL();
      if (newBar) ManageCandleStepLock();
   }
}

//──────────────────────────────────────────────────────────────────────────────
// OnTradeTransaction — logs SL closes only
//──────────────────────────────────────────────────────────────────────────────
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

   ENUM_DEAL_ENTRY  entry  = (ENUM_DEAL_ENTRY) HistoryDealGetInteger(deal, DEAL_ENTRY);
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);

   if (reason == DEAL_REASON_SL && (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT))
   {
      g_beSet          = false;
      g_peakProfitPts  = 0.0;
      g_candleFavorCount = 0;
      PrintFormat("SL hit — state reset, waiting for next bar signal");
   }
}
