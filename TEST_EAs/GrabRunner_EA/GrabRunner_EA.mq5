//+------------------------------------------------------------------+
//|  GrabRunner_EA.mq5  v1.00                                          |
//|  Smash-and-grab momentum rider for XAUUSD (and similar)           |
//|                                                                    |
//|  PHILOSOPHY                                                        |
//|  ──────────                                                        |
//|  Fire into the START of a fast move, ride it with a big TP and a   |
//|  loose backup trail, and get out. Aggression is intentional. The  |
//|  blow-up risk is an accepted premium, NOT a bug to be eliminated.  |
//|  The job of this code is simply: don't strangle the grab, and      |
//|  don't donate to the broker on dead chop between real shots.       |
//|                                                                    |
//|  ENTRY  (both conditions required, evaluated on each new bar)      |
//|  ─────                                                             |
//|   1) BURST    : the last closed bar's range > ATR × BurstFactor    |
//|                 (volatility just expanded — a move is starting)    |
//|   2) BREAKOUT : that bar closed beyond the high/low of the prior  |
//|                 N bars (price has actually committed direction)    |
//|   + a body filter so wicky fake bars don't trigger.                |
//|                                                                    |
//|  EXIT                                                              |
//|  ────                                                              |
//|   • Hard TP = ATR × TPMult  (the grab target — deliberately big)   |
//|   • Loose backup trail: does NOTHING until profit reaches          |
//|     TrailStartPct of the way to TP (lets the spike breathe),       |
//|     then trails at a wide ATR gap, tightening only once near TP.   |
//|   • Initial risk SL = ATR × SLMult (defines lot size via risk %).  |
//|                                                                    |
//|  ANTI-LEAK                                                         |
//|  ─────────                                                         |
//|   • Spread filter ON  — won't enter into a blown-out spread.       |
//|   • Post-loss cooldown — waits N bars after a stop-out so a        |
//|     choppy session can't whipsaw your stake into spread 5× in a    |
//|     row. (This is the leak you CANNOT fix from inputs alone.)      |
//|                                                                    |
//|  NOTE: Breakeven and peak-lock are intentionally OFF by default.   |
//|  They strangle the grab. Re-enable only if you know why you want   |
//|  them.                                                             |
//+------------------------------------------------------------------+
#property copyright "GrabRunner EA"
#property link      ""
#property version   "1.00"
#property description "GrabRunner v1.00: burst+breakout entry, big TP + loose backup trail, spread filter + post-loss cooldown. Aggressive grab style."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Risk / Sizing ==="
input double InpRiskPct           = 2.0;    // RiskPct: % of equity risked on the SL (crank this if you want)
input double InpMinLot            = 0.01;   // MinLot: floor lot size
input double InpMaxLot            = 5.00;   // MaxLot: ceiling lot size
input long   InpMagicNumber       = 778899; // MagicNumber
input int    InpMaxSlippagePoints = 30;     // MaxSlippagePoints

input group "=== Signal Timeframe ==="
input ENUM_TIMEFRAMES InpTF       = PERIOD_M1; // Timeframe for entry signals

input group "=== ATR / Stops / Target ==="
input int    InpATRPeriod         = 14;     // ATRPeriod
input double InpSLMult            = 1.5;    // SLMult: risk SL = ATR × this
input double InpTPMult            = 5.0;    // TPMult: grab target = ATR × this (R:R = TPMult/SLMult)
input int    InpSLFloorPoints     = 50;     // SLFloorPoints: minimum SL distance

input group "=== Loose Backup Trail ==="
input int    InpTrailStartPct     = 50;     // TrailStartPct: don't trail until profit reaches this % of TP distance
input double InpTrailMult         = 2.5;    // TrailMult: trail gap = ATR × this (keep LOOSE)
input int    InpTrailTightPct     = 80;     // TrailTightPct: once this % to TP, tighten the trail
input double InpTrailTightFactor  = 0.5;    // TrailTightFactor: trail gap multiplier once tightening (0.5 = half)

input group "=== Entry: Burst + Breakout ==="
input double InpBurstFactor       = 1.2;    // BurstFactor: signal bar range must exceed ATR × this
input int    InpBreakoutBars      = 10;     // BreakoutBars: bar must close beyond high/low of this many prior bars
input int    InpMinBodyPct        = 50;     // MinBodyPct: signal bar body as % of its range (anti-wick)

input group "=== Anti-Leak ==="
input int    InpMaxSpreadPoints   = 50;     // MaxSpreadPoints: skip entry if spread above this — *** TUNE TO YOUR BROKER ***
input int    InpCooldownBars      = 3;      // CooldownBars: bars to wait after a stop-out before re-entering (0 = off)

input group "=== Optional Safeties (off by default) ==="
input int    InpBEPoints          = 0;      // BEPoints: profit pts to lock breakeven (0 = OFF — recommended off for grab)
input int    InpBEBuffer          = 10;     // BEBuffer: SL → entry + this when BE triggers
input int    InpMaxHoldMinutes    = 0;      // MaxHoldMinutes: force-close after this many minutes (0 = off; fits "1hr and out")

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

int      g_atrHandle      = INVALID_HANDLE;
bool     g_isNetting      = false;

int      g_effectiveSLMin = 0;
datetime g_lastBarTime    = 0;

// Per-trade state
bool     g_beSet          = false;
double   g_entryPrice     = 0.0;
double   g_tpPoints       = 0.0;   // TP distance from entry, in points (for trail ratio)
datetime g_entryTime      = 0;

// Cooldown
int      g_cooldownLeft   = 0;     // bars remaining before re-entry allowed

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
   lot = MathMin(lot, MathMin(maxL, InpMaxLot));
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

int CurrentSpreadPoints()
{
   g_sym.RefreshRates();
   return (int)MathRound((g_sym.Ask() - g_sym.Bid()) / _Point);
}

int SafeDist(int basePts, double ask, double bid)
{
   int sp = (int)MathRound((ask - bid) / _Point);
   int sl = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return MathMax(basePts, sp + sl + 5);
}

double GetATRValue()
{
   if (g_atrHandle == INVALID_HANDLE) return InpSLFloorPoints * _Point;
   double atr[];
   ArraySetAsSeries(atr, true);
   if (CopyBuffer(g_atrHandle, 0, 1, 1, atr) <= 0) return InpSLFloorPoints * _Point;
   return atr[0];
}

int GetSLPoints()
{
   double atr = GetATRValue();
   int pts = (int)MathRound(atr * InpSLMult / _Point);
   return MathMax(pts, InpSLFloorPoints);
}

double HighestHigh(int count, int startShift)
{
   double h[];
   ArraySetAsSeries(h, true);
   if (CopyHigh(_Symbol, InpTF, startShift, count, h) <= 0) return 0.0;
   int idx = ArrayMaximum(h, 0, count);
   if (idx < 0) return 0.0;
   return h[idx];
}

double LowestLow(int count, int startShift)
{
   double l[];
   ArraySetAsSeries(l, true);
   if (CopyLow(_Symbol, InpTF, startShift, count, l) <= 0) return 0.0;
   int idx = ArrayMinimum(l, 0, count);
   if (idx < 0) return 0.0;
   return l[idx];
}

//──────────────────────────────────────────────────────────────────────────────
// CalcLotByRisk — sizes lot so the SL costs exactly InpRiskPct% of equity
//──────────────────────────────────────────────────────────────────────────────
double CalcLotByRisk(int slPts)
{
   if (slPts <= 0) return NormalizeLot(InpMinLot);

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPct / 100.0;
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tickVal <= 0 || tickSize <= 0) return NormalizeLot(InpMinLot);

   double slMoney = (slPts * _Point / tickSize) * tickVal;
   if (slMoney <= 0) return NormalizeLot(InpMinLot);

   double lot = riskMoney / slMoney;
   return NormalizeLot(lot);
}

//──────────────────────────────────────────────────────────────────────────────
// CheckEntrySignal
// Returns ORDER_TYPE_BUY / ORDER_TYPE_SELL if a burst+breakout fires on the
// last closed bar, otherwise -1.
//──────────────────────────────────────────────────────────────────────────────
int CheckEntrySignal()
{
   double c  = iClose(_Symbol, InpTF, 1);
   double o  = iOpen (_Symbol, InpTF, 1);
   double hi = iHigh (_Symbol, InpTF, 1);
   double lo = iLow  (_Symbol, InpTF, 1);

   double range = hi - lo;
   if (range <= 0) return -1;

   // --- Body filter: reject wicky fake bars ---
   if (InpMinBodyPct > 0)
   {
      double body = MathAbs(c - o);
      if ((body / range) * 100.0 < (double)InpMinBodyPct) return -1;
   }

   // --- Burst: signal bar range must exceed ATR × BurstFactor ---
   double atr = GetATRValue();
   if (atr <= 0) return -1;
   if (range < atr * InpBurstFactor) return -1;

   // --- Breakout: bar must close beyond the prior N bars' high / low ---
   // prior N bars = the N bars BEFORE the signal bar, i.e. startShift = 2
   double priorHigh = HighestHigh(InpBreakoutBars, 2);
   double priorLow  = LowestLow (InpBreakoutBars, 2);
   if (priorHigh <= 0 || priorLow <= 0) return -1;

   bool bullish = (c > o) && (c > priorHigh);
   bool bearish = (c < o) && (c < priorLow);

   if (bullish) return ORDER_TYPE_BUY;
   if (bearish) return ORDER_TYPE_SELL;
   return -1;
}

//──────────────────────────────────────────────────────────────────────────────
// OpenPosition
//──────────────────────────────────────────────────────────────────────────────
bool OpenPosition(ENUM_ORDER_TYPE direction)
{
   if (SelectOurPosition()) { Print("OpenPosition: already open — skip"); return false; }

   // Spread leak guard
   if (InpMaxSpreadPoints > 0)
   {
      int sp = CurrentSpreadPoints();
      if (sp > InpMaxSpreadPoints)
      {
         PrintFormat("Skip entry: spread %d > %d (broker blowout / chop) — saved you a leak",
                     sp, InpMaxSpreadPoints);
         return false;
      }
   }

   int slPtsBase = GetSLPoints();
   int tpPtsBase = (InpTPMult > 0) ? (int)MathRound(GetATRValue() * InpTPMult / _Point) : 0;

   for (int attempt = 1; attempt <= 3; attempt++)
   {
      g_sym.RefreshRates();
      double ask   = g_sym.Ask();
      double bid   = g_sym.Bid();
      int    slPts = SafeDist(slPtsBase, ask, bid);
      int    tpPts = (tpPtsBase > 0) ? MathMax(tpPtsBase, slPts + 1) : 0;
      double lot   = CalcLotByRisk(slPts);
      double sl, tp;

      if (direction == ORDER_TYPE_BUY)
      {
         sl = NormalizeDouble(ask - slPts * _Point, _Digits);
         tp = (tpPts > 0) ? NormalizeDouble(ask + tpPts * _Point, _Digits) : 0;
         g_trade.Buy(lot, _Symbol, ask, sl, tp, "GrabRunner");
      }
      else
      {
         sl = NormalizeDouble(bid + slPts * _Point, _Digits);
         tp = (tpPts > 0) ? NormalizeDouble(bid - tpPts * _Point, _Digits) : 0;
         g_trade.Sell(lot, _Symbol, bid, sl, tp, "GrabRunner");
      }

      uint rc = g_trade.ResultRetcode();
      PrintResult(StringFormat("[%s] OpenPos %s attempt=%d lot=%.2f SL=%dpts TP=%dpts (R:R=%.2f, %.1f%%risk)",
                  _Symbol, (direction==ORDER_TYPE_BUY?"BUY":"SELL"),
                  attempt, lot, slPts, tpPts,
                  (slPts>0 ? (double)tpPts/(double)slPts : 0), InpRiskPct));

      if (rc == TRADE_RETCODE_DONE)
      {
         g_beSet      = false;
         Sleep(100);
         if (SelectOurPosition())
         {
            g_entryPrice = g_pos.PriceOpen();
            g_entryTime  = (datetime)g_pos.Time();
            double tpPrice = g_pos.TakeProfit();
            g_tpPoints   = (tpPrice > 0) ? MathAbs(tpPrice - g_entryPrice) / _Point : 0.0;
         }
         return true;
      }

      if (rc == TRADE_RETCODE_REQUOTE       ||
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
// ManageBreakeven (optional, off by default)
//──────────────────────────────────────────────────────────────────────────────
void ManageBreakeven()
{
   if (g_beSet)          return;
   if (InpBEPoints <= 0) return;
   if (!SelectOurPosition()) return;

   ENUM_POSITION_TYPE pt = g_pos.PositionType();
   g_sym.RefreshRates();
   double ask = g_sym.Ask();
   double bid = g_sym.Bid();

   double profitPts = (pt == POSITION_TYPE_BUY)
                      ? (bid - g_entryPrice) / _Point
                      : (g_entryPrice - ask) / _Point;
   if (profitPts < (double)InpBEPoints) return;

   double curSL = g_pos.StopLoss();
   double beSL;

   if (pt == POSITION_TYPE_BUY)
   {
      beSL = NormalizeDouble(g_entryPrice + InpBEBuffer * _Point, _Digits);
      if (beSL <= curSL) { g_beSet = true; return; }
   }
   else
   {
      beSL = NormalizeDouble(g_entryPrice - InpBEBuffer * _Point, _Digits);
      if (beSL >= curSL) { g_beSet = true; return; }
   }

   if (g_trade.PositionModify(g_pos.Ticket(), beSL, g_pos.TakeProfit()))
   {
      g_beSet = true;
      PrintFormat("BE locked: SL → %.5f (profit=%.0fpts)", beSL, profitPts);
   }
   else PrintResult("BE modify FAILED");
}

//──────────────────────────────────────────────────────────────────────────────
// ManageLooseTrail
// Does NOTHING until profit reaches TrailStartPct of the way to TP — lets the
// grab breathe. Then trails at a wide ATR gap, tightening once near the target.
//──────────────────────────────────────────────────────────────────────────────
void ManageLooseTrail()
{
   if (!SelectOurPosition()) return;

   ENUM_POSITION_TYPE pt = g_pos.PositionType();
   double curSL = g_pos.StopLoss();
   double curTP = g_pos.TakeProfit();
   ulong  ticket = g_pos.Ticket();

   g_sym.RefreshRates();
   double ask = g_sym.Ask();
   double bid = g_sym.Bid();

   double profitPts = (pt == POSITION_TYPE_BUY)
                      ? (bid - g_entryPrice) / _Point
                      : (g_entryPrice - ask) / _Point;
   if (profitPts <= 0) return;

   // Only engage the trail once we're TrailStartPct of the way to TP
   if (g_tpPoints > 0)
   {
      double ratio = profitPts / g_tpPoints;
      if (ratio < InpTrailStartPct / 100.0) return; // breathe — no trail yet
   }

   // Gap based on ATR; loose, tightening near target
   double gapPts = GetATRValue() * InpTrailMult / _Point;
   if (g_tpPoints > 0)
   {
      double ratio = profitPts / g_tpPoints;
      if (ratio >= InpTrailTightPct / 100.0)
         gapPts *= InpTrailTightFactor;
   }
   int slPts = SafeDist((int)MathRound(gapPts), ask, bid);

   double newSL;
   bool   shouldMove;
   if (pt == POSITION_TYPE_BUY)
   {
      newSL      = NormalizeDouble(bid - slPts * _Point, _Digits);
      shouldMove = (curSL == 0) ? true : (newSL > curSL + _Point * 0.5);
   }
   else
   {
      newSL      = NormalizeDouble(ask + slPts * _Point, _Digits);
      shouldMove = (curSL == 0) ? true : (newSL < curSL - _Point * 0.5);
   }
   if (!shouldMove) return;

   // Respect broker freeze level
   int freeze = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if (freeze > 0)
   {
      double d = (pt == POSITION_TYPE_BUY) ? (bid - newSL) : (newSL - ask);
      if (d < freeze * _Point) return;
   }

   if (!g_trade.PositionModify(ticket, newSL, curTP))
   {
      if (g_trade.ResultRetcode() != TRADE_RETCODE_DONE)
         PrintResult("Trail SL FAILED");
   }
}

//──────────────────────────────────────────────────────────────────────────────
// ManageTimeExit (optional, off by default) — fits the "1 hour and out" idea
//──────────────────────────────────────────────────────────────────────────────
void ManageTimeExit()
{
   if (InpMaxHoldMinutes <= 0) return;
   if (!SelectOurPosition())   return;
   if (g_entryTime == 0)       return;

   int heldMin = (int)((TimeCurrent() - g_entryTime) / 60);
   if (heldMin >= InpMaxHoldMinutes)
   {
      PrintFormat("Time exit: held %d min >= %d — grabbing whatever's there", heldMin, InpMaxHoldMinutes);
      CloseOurPosition("time-exit");
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

   g_isNetting = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) ==
                  ACCOUNT_MARGIN_MODE_RETAIL_NETTING);
   PrintFormat("Account type: %s", g_isNetting ? "NETTING" : "HEDGING");

   g_atrHandle = iATR(_Symbol, InpTF, InpATRPeriod);
   if (g_atrHandle == INVALID_HANDLE) Print("WARNING: ATR handle failed — using SL floor");

   int stopsLevel   = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_effectiveSLMin = MathMax(InpSLFloorPoints, (stopsLevel > 0 ? stopsLevel + 5 : 0));

   if (NormalizeLot(InpMinLot) < g_sym.LotsMin())
   {
      PrintFormat("INIT FAILED: MinLot %.2f < broker min %.2f", InpMinLot, g_sym.LotsMin());
      return INIT_FAILED;
   }

   PrintFormat("GrabRunner v1.00 | %s %s | Entry: range>ATR×%.1f + break of %d bars, body>=%d%% | "
               "SL=ATR×%.1f TP=ATR×%.1f (R:R=%.2f) | Trail: idle<%d%%→loose ATR×%.1f→tight×%.2f@%d%% | "
               "Spread<=%dpts CURRENT=%dpts | Cooldown=%dbars | BE=%s | TimeExit=%s | Risk=%.1f%% | Magic=%lld",
               _Symbol, EnumToString(InpTF),
               InpBurstFactor, InpBreakoutBars, InpMinBodyPct,
               InpSLMult, InpTPMult, (InpSLMult>0 ? InpTPMult/InpSLMult : 0),
               InpTrailStartPct, InpTrailMult, InpTrailTightFactor, InpTrailTightPct,
               InpMaxSpreadPoints, CurrentSpreadPoints(),
               InpCooldownBars,
               (InpBEPoints>0 ? "ON" : "off"),
               (InpMaxHoldMinutes>0 ? "ON" : "off"),
               InpRiskPct, InpMagicNumber);

   PrintFormat(">>> CALIBRATE: current spread is %d points. If MaxSpreadPoints (%d) is far above or below this, tune it.",
               CurrentSpreadPoints(), InpMaxSpreadPoints);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if (g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   PrintFormat("GrabRunner v1.00 deinit (reason=%d).", reason);
}

void OnTick()
{
   datetime bt     = iTime(_Symbol, InpTF, 0);
   bool     newBar = (bt != 0 && bt != g_lastBarTime);
   if (newBar)
   {
      g_lastBarTime = bt;
      if (g_cooldownLeft > 0) g_cooldownLeft--; // tick down cooldown per bar
   }

   // --- Entry: new bar, flat, in hours, not in cooldown ---
   if (newBar && !SelectOurPosition())
   {
      if (g_cooldownLeft > 0)
      {
         // silent; just waiting out the chop
      }
      else if (IsInTradingHours())
      {
         int sig = CheckEntrySignal();
         if (sig == ORDER_TYPE_BUY)
         {
            Print("Signal: BURST+BREAKOUT BUY");
            OpenPosition(ORDER_TYPE_BUY);
         }
         else if (sig == ORDER_TYPE_SELL)
         {
            Print("Signal: BURST+BREAKOUT SELL");
            OpenPosition(ORDER_TYPE_SELL);
         }
      }
   }

   // --- Manage open position ---
   if (SelectOurPosition())
   {
      ManageBreakeven();    // off by default
      ManageLooseTrail();   // the real backup
      ManageTimeExit();     // off by default
   }
}

//──────────────────────────────────────────────────────────────────────────────
// OnTradeTransaction — start cooldown after a stop-out, reset per-trade state
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

   if (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
   {
      // Reset per-trade state on any close
      g_beSet     = false;
      g_tpPoints  = 0.0;
      g_entryTime = 0;

      // Only the SL-driven (loss) close triggers the cooldown
      if (reason == DEAL_REASON_SL)
      {
         g_cooldownLeft = InpCooldownBars;
         PrintFormat("Stop-out — cooldown %d bars (no whipsaw re-entry into chop)", InpCooldownBars);
      }
      else if (reason == DEAL_REASON_TP)
      {
         PrintFormat("TP hit — grab complete");
      }
   }
}
