//+------------------------------------------------------------------+
//|  FlipTrail_EA_v3.mq5  v3.22                                      |
//|  ATR trail + fixed TP — good R:R scalper                         |
//|                                                                    |
//|  MECHANICS (identical to v11.04)                                 |
//|  ─────────                                                        |
//|  Entry: new bar candle body direction (optional body % filter)   |
//|  Exit:  ATR trailing SL — moves with price every tick            |
//|  No pending stop orders — except confirmed limit re-entries      |
//|                                                                   |
//|  PROGRESSIVE TRAIL TIGHTENING (identical to v11.04)             |
//|  ──────────────────────────────                                  |
//|  < 1× ATR gap in profit  → trail = 100% of ATR gap (full)       |
//|  ≥ 1× ATR gap in profit  → trail = 50% of ATR gap               |
//|  ≥ 2× ATR gap in profit  → trail = 25% of ATR gap               |
//|  ≥ 3× ATR gap in profit  → trail = 15% of ATR gap (very tight)  |
//|                                                                   |
//|  V3.20 FEATURES                                                  |
//|  ──────────────                                                   |
//|  1. Daily drawdown kill switch — halts all trading for the day   |
//|  2. Session filter ON by default (08:00–20:00)                   |
//|  3. Dynamic lot reduction — tiers from intraday peak equity      |
//|  4. Limit re-entry — after same-direction trail SL hit,          |
//|     places a BUY/SELL LIMIT at pullback bar low/high + buffer    |
//|     Limit entries get InpLimitLotMultiplier × normal lot         |
//|     Limit auto-cancels if unfilled after N bars or on new signal |
//|  5. Min bars between trades — enforced gap after any close       |
//|  6. Chop pause — alternating losses → MinLot until N wins        |
//|  7. ATR min filter, tick volume filter, spread filter, body filter|
//|  EXIT MECHANICS UNCHANGED from v11.04                            |
//+------------------------------------------------------------------+
#property copyright "FlipTrail EA v3"
#property link      ""
#property version   "3.22"
#property description "FlipTrail v3.22: full protection suite — DD kill, session, dynamic lots, limit reentry, chop pause"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Trade ==="
input double InpRiskPct           = 1.0;   // RiskPct: % of equity to risk per trade
input double InpMinLot            = 0.01;  // MinLot: floor lot (also used in chop pause & deep DD)
input double InpMaxLot            = 1.00;  // MaxLot: ceiling lot
input int    InpSLPoints          = 50;    // SLPoints: minimum SL floor
input long   InpMagicNumber       = 112235;// MagicNumber (v1=112233 v2=112234 v3=112235)
input int    InpMaxSlippagePoints = 30;    // MaxSlippagePoints
input int    InpMaxSpreadPoints   = 0;     // MaxSpreadPoints: 0=off. Tip: set 30–50 for XAUUSD

input group "=== ATR Stop Loss & Take Profit ==="
input int    InpATRPeriod         = 14;    // ATRPeriod
input double InpATRMultiplier     = 1.5;   // ATRMultiplier: SL = ATR × this
input double InpTPMultiplier      = 2.0;   // TPMultiplier: TP = ATR × this (0 = trail only)

input group "=== Breakeven ==="
input int    InpBEPoints          = 50;    // BEPoints: profit pts to lock BE (0=off)
input int    InpBEBuffer          = 10;    // BEBuffer: SL moves to entry + this

input group "=== Candle Body Filter ==="
input int    InpMinBodyPct        = 30;    // MinBodyPct: min body as % of range (0=off)

input group "=== Peak Profit Lock ==="
input int    InpPeakLockPct       = 60;    // PeakLockPct: % of peak profit locked as SL floor (0=off)

input group "=== Candle Step Lock ==="
input int    InpCandleStepBars    = 3;     // CandleStepBars: consecutive favorable closes to step SL (0=off)
input int    InpCandleStepLockPct = 40;    // CandleStepLockPct: % of profit to lock on each step

input group "=== Session Filter ==="
input bool   InpEnableTradingHours = true; // EnableTradingHours: ON by default for active sessions
input int    InpTradingStartHour   = 8;    // StartHour server time (London open = 8)
input int    InpTradingEndHour     = 20;   // EndHour server time (NY close = 20)

input group "=== ATR Minimum Filter ==="
input int    InpATRMinPoints      = 0;     // ATRMinPoints: min raw ATR pts to allow entry (0=off)

input group "=== Tick Volume Filter ==="
input int    InpVolumePeriod      = 0;     // VolumePeriod: bars for avg volume (0=off)
input double InpVolumeMultiplier  = 1.2;   // VolumeMultiplier: signal bar volume >= avg × this

input group "=== Daily Loss & Profit Limits ==="
input double InpDailyDrawdownPct     = 15.0;  // DailyLossLimitPct: halt trading if daily loss >= X% (0=off)
input double InpDailyProfitTargetPct = 20.0;  // DailyProfitTargetPct: halt trading if daily gain >= X% (0=off)
//  Both measured from equity at day start. Reset automatically at midnight.
//  When triggered: cancels pending orders, closes open position, stops all new entries for the day.

input group "=== Dynamic Lot Reduction ==="
input double InpDDReducePct       = 3.0;   // DDReducePct: intraday peak drawdown → half lot (0=off)
input double InpDDMinLotPct       = 6.0;   // DDMinLotPct: intraday peak drawdown → MinLot
//  Tracks intraday equity peak. At InpDDReducePct drawdown → 50% lot. At InpDDMinLotPct → MinLot.
//  Resets each new day. Protects intraday profits without stopping trading.

input group "=== Limit Re-entry After Trail SL ==="
input int    InpLimitBuffer          = 10;   // LimitBuffer: pts above pullback low (BUY) / below high (SELL)
input double InpLimitLotMultiplier   = 1.5;  // LimitLotMultiplier: lot × this for limit re-entries (>= 1.0)
input int    InpLimitExpireBars      = 3;    // LimitExpireBars: cancel unfilled limit after N bars (0=never)
//  After trail SL hit: if next signal is SAME direction, places a limit at the pullback bar extreme.
//  This captures a better-priced re-entry at a technically significant level.
//  If next signal is OPPOSITE direction: cancels any pending limit, trades normally.
//  Limit lot is CalcLotByRisk × InpLimitLotMultiplier (confirmed entries deserve more size).

input group "=== Min Bars Between Trades ==="
input int    InpMinBarsBetween    = 2;     // MinBarsBetween: minimum M1 bar gap after any trade close (0=off)

input group "=== Chop Pause ==="
input int    InpChopLossTrigger   = 2;     // ChopLossTrigger: alternating direction losses to trigger (0=off)
input int    InpChopRecoverTrades = 2;     // ChopRecoverTrades: profitable trades to resume normal lot
//  In chop pause: ALL entries use MinLot until N profitable trades confirm direction.

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

// Per-trade state (exit mechanics)
bool     g_beSet            = false;
double   g_entryPrice       = 0.0;
double   g_peakProfitPts    = 0.0;
int      g_candleFavorCount = 0;

// Daily drawdown & dynamic lot
double   g_dayStartEquity  = 0.0;
double   g_dayPeakEquity   = 0.0;
datetime g_dayStartDate    = 0;
bool     g_dailyDDHit      = false;
bool     g_dailyProfitHit  = false;

// Limit re-entry state
bool            g_awaitingLimitReentry = false;
ENUM_ORDER_TYPE g_trailHitDir          = ORDER_TYPE_BUY;
ulong           g_pendingLimitTicket   = 0;
ENUM_ORDER_TYPE g_limitDir             = ORDER_TYPE_BUY;
int             g_limitBarsOpen        = 0;

// Min bars between trades
int      g_minBarsCountdown = 0;

// Chop pause state
bool            g_chopPauseMode    = false;
int             g_chopLossCount    = 0;
int             g_chopRecoverCount = 0;
bool            g_hasLastLossDir   = false;
ENUM_ORDER_TYPE g_lastLossDir      = ORDER_TYPE_BUY;

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
   lot = MathMax(lot, InpMinLot);
   lot = MathMin(lot, InpMaxLot);
   return NormalizeLot(lot);
}

//──────────────────────────────────────────────────────────────────────────────
// GetDDLotMultiplier
// Returns: 1.0 = full lot | 0.5 = half lot | 0.0 = use MinLot
//──────────────────────────────────────────────────────────────────────────────
double GetDDLotMultiplier()
{
   if (InpDDReducePct <= 0 || g_dayPeakEquity <= 0) return 1.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct  = (g_dayPeakEquity - equity) / g_dayPeakEquity * 100.0;
   if (ddPct >= InpDDMinLotPct)  return 0.0;
   if (ddPct >= InpDDReducePct)  return 0.5;
   return 1.0;
}

//──────────────────────────────────────────────────────────────────────────────
// GetEntryLot
// Central lot calculation applying chop pause and DD multiplier
//──────────────────────────────────────────────────────────────────────────────
double GetEntryLot(int slPts, bool isLimitReentry)
{
   double ddMult = GetDDLotMultiplier();

   double baseLot;
   if (isLimitReentry)
      baseLot = CalcLotByRisk(slPts) * MathMax(InpLimitLotMultiplier, 1.0);
   else if (g_chopPauseMode && InpChopLossTrigger > 0)
      baseLot = InpMinLot;
   else
      baseLot = CalcLotByRisk(slPts);

   if (ddMult <= 0.0)
      return NormalizeLot(InpMinLot);

   double lot = baseLot * ddMult;
   lot = MathMax(lot, InpMinLot);
   lot = MathMin(lot, InpMaxLot);
   return NormalizeLot(lot);
}

//──────────────────────────────────────────────────────────────────────────────
// CancelPendingLimit
//──────────────────────────────────────────────────────────────────────────────
void CancelPendingLimit()
{
   if (g_pendingLimitTicket == 0) return;
   bool exists = false;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
      if (OrderGetTicket(i) == g_pendingLimitTicket) { exists = true; break; }
   if (exists)
   {
      if (g_trade.OrderDelete(g_pendingLimitTicket))
         PrintFormat("Limit %llu cancelled", g_pendingLimitTicket);
      else
         PrintResult(StringFormat("Limit cancel FAILED ticket=%llu", g_pendingLimitTicket));
   }
   g_pendingLimitTicket = 0;
   g_limitBarsOpen      = 0;
}

//──────────────────────────────────────────────────────────────────────────────
// CheckDayReset — call on every tick
//──────────────────────────────────────────────────────────────────────────────
void CheckDayReset()
{
   datetime todayStart = (datetime)((TimeCurrent() / 86400) * 86400);

   if (todayStart != g_dayStartDate)
   {
      g_dayStartDate   = todayStart;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dayPeakEquity  = g_dayStartEquity;
      g_dailyDDHit      = false;
      g_dailyProfitHit  = false;
      PrintFormat("New day: equity=%.2f | DD & profit limits reset", g_dayStartEquity);
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if (equity > g_dayPeakEquity) g_dayPeakEquity = equity;

   if (!g_dailyDDHit && InpDailyDrawdownPct > 0 && g_dayStartEquity > 0)
   {
      double ddPct = (g_dayStartEquity - equity) / g_dayStartEquity * 100.0;
      if (ddPct >= InpDailyDrawdownPct)
      {
         g_dailyDDHit = true;
         CancelPendingLimit();
         CloseOurPosition("DailyDD");
         PrintFormat("!!! DAILY LOSS LIMIT HIT: -%.2f%% today (%.2f→%.2f) — no more trades today",
                     ddPct, g_dayStartEquity, equity);
      }
   }

   if (!g_dailyProfitHit && InpDailyProfitTargetPct > 0 && g_dayStartEquity > 0)
   {
      double gainPct = (equity - g_dayStartEquity) / g_dayStartEquity * 100.0;
      if (gainPct >= InpDailyProfitTargetPct)
      {
         g_dailyProfitHit = true;
         CancelPendingLimit();
         CloseOurPosition("DailyProfit");
         PrintFormat("!!! DAILY PROFIT TARGET HIT: +%.2f%% today (%.2f→%.2f) — locking gains, done for the day",
                     gainPct, g_dayStartEquity, equity);
      }
   }
}

//──────────────────────────────────────────────────────────────────────────────
// PlaceLimitReentry
// Places a BUY/SELL LIMIT at the pullback bar extreme + buffer.
// Called when trail SL hit and next signal matches same direction.
//──────────────────────────────────────────────────────────────────────────────
void PlaceLimitReentry(ENUM_ORDER_TYPE dir)
{
   if (InpMaxSpreadPoints > 0)
   {
      g_sym.RefreshRates();
      int sp = (int)MathRound((g_sym.Ask() - g_sym.Bid()) / _Point);
      if (sp > InpMaxSpreadPoints) { PrintFormat("Limit skip: spread %d > %d", sp, InpMaxSpreadPoints); return; }
   }

   double pullbackLow  = iLow (_Symbol, PERIOD_M1, 1);
   double pullbackHigh = iHigh(_Symbol, PERIOD_M1, 1);

   int    atrPts  = GetATRPoints();
   g_sym.RefreshRates();
   double ask     = g_sym.Ask();
   double bid     = g_sym.Bid();
   int    slPts   = SafeDist(atrPts, ask, bid);
   int    tpPts   = (InpTPMultiplier > 0) ? (int)MathRound(atrPts * InpTPMultiplier) : 0;
   double lot     = GetEntryLot(slPts, true);

   double limitPrice, sl, tp;

   if (dir == ORDER_TYPE_BUY)
   {
      limitPrice = NormalizeDouble(pullbackLow + InpLimitBuffer * _Point, _Digits);
      sl         = NormalizeDouble(limitPrice  - slPts * _Point, _Digits);
      tp         = (tpPts > 0) ? NormalizeDouble(limitPrice + tpPts * _Point, _Digits) : 0;
      g_trade.BuyLimit(lot, limitPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "FTV3-Limit");
   }
   else
   {
      limitPrice = NormalizeDouble(pullbackHigh - InpLimitBuffer * _Point, _Digits);
      sl         = NormalizeDouble(limitPrice   + slPts * _Point, _Digits);
      tp         = (tpPts > 0) ? NormalizeDouble(limitPrice - tpPts * _Point, _Digits) : 0;
      g_trade.SellLimit(lot, limitPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "FTV3-Limit");
   }

   uint rc = g_trade.ResultRetcode();
   PrintResult(StringFormat("[%s] LimitReentry %s @ %.5f SL=%dpts TP=%dpts lot=%.2f [×%.1f]",
               _Symbol, (dir==ORDER_TYPE_BUY?"BUY":"SELL"), limitPrice, slPts, tpPts,
               lot, InpLimitLotMultiplier));

   if (rc == TRADE_RETCODE_DONE)
   {
      g_pendingLimitTicket = g_trade.ResultOrder();
      g_limitDir           = dir;
      g_limitBarsOpen      = 0;
      PrintFormat("Limit placed: ticket=%llu @ %.5f | expires in %d bars",
                  g_pendingLimitTicket, limitPrice,
                  InpLimitExpireBars > 0 ? InpLimitExpireBars : 999);
   }
}

//──────────────────────────────────────────────────────────────────────────────
// PlaceStopReentry
// Places a BUY/SELL STOP at the bar extreme + buffer to catch trend continuation.
// Called when trail SL hit and next signal matches same direction.
//──────────────────────────────────────────────────────────────────────────────
void PlaceStopReentry(ENUM_ORDER_TYPE dir)
{
   if (InpMaxSpreadPoints > 0)
   {
      g_sym.RefreshRates();
      int sp = (int)MathRound((g_sym.Ask() - g_sym.Bid()) / _Point);
      if (sp > InpMaxSpreadPoints) { PrintFormat("Stop skip: spread %d > %d", sp, InpMaxSpreadPoints); return; }
   }

   double barLow  = iLow (_Symbol, PERIOD_M1, 1);
   double barHigh = iHigh(_Symbol, PERIOD_M1, 1);

   int    atrPts  = GetATRPoints();
   g_sym.RefreshRates();
   double ask     = g_sym.Ask();
   double bid     = g_sym.Bid();
   int    slPts   = SafeDist(atrPts, ask, bid);
   int    tpPts   = (InpTPMultiplier > 0) ? (int)MathRound(atrPts * InpTPMultiplier) : 0;
   double lot     = GetEntryLot(slPts, true);

   double stopPrice, sl, tp;

   if (dir == ORDER_TYPE_BUY)
   {
      stopPrice = NormalizeDouble(barHigh + InpLimitBuffer * _Point, _Digits);
      sl        = NormalizeDouble(stopPrice - slPts * _Point, _Digits);
      tp        = (tpPts > 0) ? NormalizeDouble(stopPrice + tpPts * _Point, _Digits) : 0;
      g_trade.BuyStop(lot, stopPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "FTV3-Stop");
   }
   else
   {
      stopPrice = NormalizeDouble(barLow - InpLimitBuffer * _Point, _Digits);
      sl        = NormalizeDouble(stopPrice + slPts * _Point, _Digits);
      tp        = (tpPts > 0) ? NormalizeDouble(stopPrice - tpPts * _Point, _Digits) : 0;
      g_trade.SellStop(lot, stopPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "FTV3-Stop");
   }

   uint rc = g_trade.ResultRetcode();
   PrintResult(StringFormat("[%s] StopReentry %s @ %.5f SL=%dpts TP=%dpts lot=%.2f [×%.1f]",
               _Symbol, (dir==ORDER_TYPE_BUY?"BUY":"SELL"), stopPrice, slPts, tpPts,
               lot, InpLimitLotMultiplier));

   if (rc == TRADE_RETCODE_DONE)
   {
      g_pendingLimitTicket = g_trade.ResultOrder();
      g_limitDir           = dir;
      g_limitBarsOpen      = 0;
      PrintFormat("Stop placed: ticket=%llu @ %.5f | expires in %d bars",
                  g_pendingLimitTicket, stopPrice,
                  InpLimitExpireBars > 0 ? InpLimitExpireBars : 999);
   }
}

//──────────────────────────────────────────────────────────────────────────────
// UpdateTrailGap
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
   if (newGap < g_trailGap)
   {
      PrintFormat("Trail tightened: profit=%.0fpts (%.1f×ATR) → gap %d→%dpts",
                  profitPts, ratio, g_trailGap, newGap);
      g_trailGap = newGap;
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
   if (currentSL == 0) return;

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
   double newSL; bool shouldMove;

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
   if (posType == POSITION_TYPE_BUY  && (bid - newSL)  / _Point < stopsLevel + 5) return;
   if (posType == POSITION_TYPE_SELL && (newSL  - ask)  / _Point < stopsLevel + 5) return;

   if (g_trade.PositionModify(g_pos.Ticket(), newSL, 0))
      PrintFormat("PeakLock: SL → %.5f | peak=%.0fpts × %d%% = %.0fpts locked",
                  newSL, g_peakProfitPts, InpPeakLockPct, lockPts);
   else PrintResult("PeakLock: SL modify FAILED");
}

//──────────────────────────────────────────────────────────────────────────────
// ManageCandleStepLock
//──────────────────────────────────────────────────────────────────────────────
void ManageCandleStepLock()
{
   if (InpCandleStepBars <= 0)   return;
   if (!SelectOurPosition())     return;

   double currentSL = g_pos.StopLoss();
   if (currentSL == 0) return;

   ENUM_POSITION_TYPE posType = g_pos.PositionType();
   g_sym.RefreshRates();
   double ask = g_sym.Ask();
   double bid = g_sym.Bid();

   double barClose  = iClose(_Symbol, PERIOD_M1, 1);
   double barOpen   = iOpen (_Symbol, PERIOD_M1, 1);
   bool   favorable = (posType == POSITION_TYPE_BUY) ? (barClose > barOpen)
                                                      : (barClose < barOpen);
   if (!favorable) { g_candleFavorCount = 0; return; }

   g_candleFavorCount++;
   if (g_candleFavorCount < InpCandleStepBars) return;

   double profitPts = (posType == POSITION_TYPE_BUY)
                      ? (bid - g_entryPrice) / _Point
                      : (g_entryPrice - ask) / _Point;
   if (profitPts <= (double)InpBEPoints) { g_candleFavorCount = 0; return; }

   double lockPts = profitPts * InpCandleStepLockPct / 100.0;
   double newSL; bool shouldMove;

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
   g_candleFavorCount = 0;
   if (!shouldMove) return;

   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if (posType == POSITION_TYPE_BUY  && (bid - newSL) / _Point < stopsLevel + 5) return;
   if (posType == POSITION_TYPE_SELL && (newSL - ask) / _Point < stopsLevel + 5) return;

   if (g_trade.PositionModify(g_pos.Ticket(), newSL, 0))
      PrintFormat("CandleStep: SL → %.5f | %d bars × %d%% of %.0fpts = %.0fpts locked",
                  newSL, InpCandleStepBars, InpCandleStepLockPct, profitPts, lockPts);
   else PrintResult("CandleStep: SL modify FAILED");
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
   if (currentSL == 0) return;

   g_sym.RefreshRates();
   double ask   = g_sym.Ask();
   double bid   = g_sym.Bid();
   int    slPts = SafeDist(g_trailGap, ask, bid);
   double newSL; bool shouldMove;

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
// OpenPosition (market order)
//──────────────────────────────────────────────────────────────────────────────
bool OpenPosition(ENUM_ORDER_TYPE direction, bool isSeed)
{
   if (SelectOurPosition()) { Print("OpenPosition: already open — skip"); return false; }

   if (InpMaxSpreadPoints > 0)
   {
      g_sym.RefreshRates();
      int sp = (int)MathRound((g_sym.Ask() - g_sym.Bid()) / _Point);
      if (sp > InpMaxSpreadPoints) { PrintFormat("Spread %d > %d — skip", sp, InpMaxSpreadPoints); return false; }
   }

   int atrPts = GetATRPoints();

   for (int attempt = 1; attempt <= 3; attempt++)
   {
      g_sym.RefreshRates();
      double ask   = g_sym.Ask();
      double bid   = g_sym.Bid();
      int    slPts = SafeDist(atrPts, ask, bid);
      int    tpPts = (InpTPMultiplier > 0) ? (int)MathRound(atrPts * InpTPMultiplier) : 0;
      double lot   = GetEntryLot(slPts, false);
      double sl, tp;

      if (direction == ORDER_TYPE_BUY)
      {
         sl = NormalizeDouble(ask - slPts * _Point, _Digits);
         tp = (tpPts > 0) ? NormalizeDouble(ask + tpPts * _Point, _Digits) : 0;
         g_trade.Buy(lot, _Symbol, ask, sl, tp, "FlipTrailV3");
      }
      else
      {
         sl = NormalizeDouble(bid + slPts * _Point, _Digits);
         tp = (tpPts > 0) ? NormalizeDouble(bid - tpPts * _Point, _Digits) : 0;
         g_trade.Sell(lot, _Symbol, bid, sl, tp, "FlipTrailV3");
      }

      uint rc = g_trade.ResultRetcode();
      PrintResult(StringFormat("[%s] OpenPos %s%s attempt=%d lot=%.2f SL=%dpts TP=%dpts",
                  _Symbol, (direction==ORDER_TYPE_BUY?"BUY":"SELL"),
                  (g_chopPauseMode?"[CHOP]":""), attempt, lot, slPts, tpPts));

      if (rc == TRADE_RETCODE_DONE)
      {
         g_peakProfitPts    = 0.0;
         g_candleFavorCount = 0;
         g_trailGapInitial  = atrPts;
         g_trailGap         = atrPts;
         g_beSet            = false;
         if (InpMinBarsBetween > 0) g_minBarsCountdown = InpMinBarsBetween;
         Sleep(100);
         if (SelectOurPosition()) g_entryPrice = g_pos.PriceOpen();
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
// TrySeedEntry
// Gate order:
//  1. Daily DD hit?          → stop
//  2. Already have position? → stop
//  3. Trading hours?         → stop
//  4. Min bars countdown?    → stop
//  5. Read bar, doji check
//  6. Body filter
//  7. ATR min filter
//  8. Tick volume filter
//  9. Pending limit handling (cancel if opposite, skip if same)
// 10. Awaiting limit reentry (place limit if same direction, clear if opposite)
// 11. Open market position
//──────────────────────────────────────────────────────────────────────────────
void TrySeedEntry()
{
   if (g_dailyDDHit)        return;
   if (g_dailyProfitHit)    return;
   if (SelectOurPosition()) return;
   if (!IsInTradingHours()) return;
   if (g_minBarsCountdown > 0) return;

   double c  = iClose(_Symbol, PERIOD_M1, 1);
   double o  = iOpen (_Symbol, PERIOD_M1, 1);
   double hi = iHigh (_Symbol, PERIOD_M1, 1);
   double lo = iLow  (_Symbol, PERIOD_M1, 1);

   if (c == o) return;
   ENUM_ORDER_TYPE dir = (c > o) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   // Body filter
   if (InpMinBodyPct > 0)
   {
      double range = hi - lo;
      double body  = MathAbs(c - o);
      if (range > 0 && (body / range) * 100.0 < (double)InpMinBodyPct)
      { PrintFormat("Skip[Body]: body=%.0f%% < %d%%", (body/range)*100.0, InpMinBodyPct); return; }
   }

   // ATR min filter
   if (InpATRMinPoints > 0 && g_atrHandle != INVALID_HANDLE)
   {
      double atr[]; ArraySetAsSeries(atr, true);
      if (CopyBuffer(g_atrHandle, 0, 1, 1, atr) > 0)
      {
         int rawAtrPts = (int)MathRound(atr[0] / _Point);
         if (rawAtrPts < InpATRMinPoints)
         { PrintFormat("Skip[ATR]: %dpts < min %dpts", rawAtrPts, InpATRMinPoints); return; }
      }
   }

   // Tick volume filter
   if (InpVolumePeriod > 0)
   {
      long sigVol = iVolume(_Symbol, PERIOD_M1, 1);
      long volSum = 0; int count = 0;
      for (int v = 2; v <= InpVolumePeriod + 1; v++)
      { long vol = iVolume(_Symbol, PERIOD_M1, v); if (vol > 0) { volSum += vol; count++; } }
      if (count > 0)
      {
         double avgVol = (double)volSum / count;
         if (avgVol > 0 && sigVol < (long)(avgVol * InpVolumeMultiplier))
         { PrintFormat("Skip[Vol]: %lld < avg=%.0f×%.1f", sigVol, avgVol, InpVolumeMultiplier); return; }
      }
   }

   // Pending limit order handling
   if (g_pendingLimitTicket > 0)
   {
      if (dir != g_limitDir)
      {
         // Opposite signal → cancel limit, trade normally below
         PrintFormat("Pending limit cancelled: new %s signal opposes %s limit",
                     (dir==ORDER_TYPE_BUY?"BUY":"SELL"), (g_limitDir==ORDER_TYPE_BUY?"BUY":"SELL"));
         CancelPendingLimit();
         g_awaitingLimitReentry = false;
      }
      else
      {
         // Same direction → limit is already working, don't double up
         return;
      }
   }

   // Pending reentry after trail SL hit — Option C: STOP on continuation, LIMIT on reversal
   if (g_awaitingLimitReentry)
   {
      if (dir == g_trailHitDir)
         PlaceStopReentry(dir);    // Same dir: price continuing → STOP above bar high to catch breakout
      else
         PlaceLimitReentry(dir);   // Opposite dir: reversal → LIMIT above bar high to catch bounce entry
      g_awaitingLimitReentry = false;
      return;
   }

   // Normal market entry
   PrintFormat("Seed %s (O=%.5f C=%.5f)%s",
               (dir==ORDER_TYPE_BUY?"BUY":"SELL"), o, c,
               g_chopPauseMode ? " [CHOP-MinLot]" : "");
   OpenPosition(dir, true);
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

   g_atrHandle = iATR(_Symbol, PERIOD_M1, InpATRPeriod);
   if (g_atrHandle == INVALID_HANDLE) Print("WARNING: ATR handle failed — using SL floor");

   int stopsLevel    = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_effectiveSLMin  = MathMax(InpSLPoints, (stopsLevel > 0 ? stopsLevel + 5 : 0));
   g_trailGap        = g_effectiveSLMin;
   g_trailGapInitial = g_effectiveSLMin;

   if (NormalizeLot(InpMinLot) < g_sym.LotsMin())
   {
      PrintFormat("INIT FAILED: MinLot %.2f < broker min %.2f", InpMinLot, g_sym.LotsMin());
      return INIT_FAILED;
   }

   // Init daily tracking
   g_dayStartDate   = (datetime)((TimeCurrent() / 86400) * 86400);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayPeakEquity  = g_dayStartEquity;

   PrintFormat("FlipTrail v3.22 | %s | SL=ATR(%d)×%.1f TP=ATR×%.1f | "
               "Session=%s %d:00-%d:00 | Loss=-%.1f%% Profit=+%.1f%% | "
               "DDLot: %.1f%%→half %.1f%%→min | "
               "Limit: buf=%dpts ×%.1fx expire=%dbars | "
               "MinBars=%d | Chop: trig=%d recover=%d | "
               "Risk=%.1f%% Lot:%.2f→%.2f | Magic=%lld",
               _Symbol, InpATRPeriod, InpATRMultiplier, InpTPMultiplier,
               InpEnableTradingHours?"ON":"OFF", InpTradingStartHour, InpTradingEndHour,
               InpDailyDrawdownPct, InpDailyProfitTargetPct,
               InpDDReducePct, InpDDMinLotPct,
               InpLimitBuffer, InpLimitLotMultiplier, InpLimitExpireBars,
               InpMinBarsBetween,
               InpChopLossTrigger, InpChopRecoverTrades,
               InpRiskPct, InpMinLot, InpMaxLot, InpMagicNumber);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if (g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   PrintFormat("FlipTrail v3.22 deinit (reason=%d).", reason);
}

void OnTick()
{
   CheckDayReset();

   datetime bt     = iTime(_Symbol, PERIOD_M1, 0);
   bool     newBar = (bt != 0 && bt != g_lastBarTime);
   if (newBar) g_lastBarTime = bt;

   if (newBar)
   {
      // Countdown timers
      if (g_minBarsCountdown > 0) g_minBarsCountdown--;

      // Limit order expiry check
      if (g_pendingLimitTicket > 0)
      {
         g_limitBarsOpen++;
         if (InpLimitExpireBars > 0 && g_limitBarsOpen >= InpLimitExpireBars)
         {
            PrintFormat("Limit expired after %d bars — cancelling", g_limitBarsOpen);
            CancelPendingLimit();
            g_awaitingLimitReentry = false;
         }
      }
   }

   if (newBar && !SelectOurPosition() && g_pendingLimitTicket == 0) TrySeedEntry();

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
// OnTradeTransaction
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

   // ── Limit fill detection ─────────────────────────────────────────────────
   if (entry == DEAL_ENTRY_IN && g_pendingLimitTicket > 0)
   {
      ulong dealOrder = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
      if (dealOrder == g_pendingLimitTicket)
      {
         g_entryPrice         = HistoryDealGetDouble(deal, DEAL_PRICE);
         g_peakProfitPts      = 0.0;
         g_candleFavorCount   = 0;
         g_trailGapInitial    = GetATRPoints();
         g_trailGap           = g_trailGapInitial;
         g_beSet              = false;
         g_pendingLimitTicket = 0;
         g_limitBarsOpen      = 0;
         if (InpMinBarsBetween > 0) g_minBarsCountdown = InpMinBarsBetween;
         PrintFormat("Limit FILLED at %.5f [%s] → managing normally",
                     g_entryPrice, (g_limitDir==ORDER_TYPE_BUY?"BUY":"SELL"));
         return;
      }
   }

   if (entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;

   // ── Shared for exit deals ─────────────────────────────────────────────────
   double netPnL = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION)
                 + HistoryDealGetDouble(deal, DEAL_SWAP);

   ENUM_DEAL_TYPE  dt        = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal, DEAL_TYPE);
   ENUM_ORDER_TYPE closedDir = (dt == DEAL_TYPE_SELL) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   // ── V1 SL reset + limit re-entry flag ────────────────────────────────────
   if (reason == DEAL_REASON_SL)
   {
      g_beSet            = false;
      g_peakProfitPts    = 0.0;
      g_candleFavorCount = 0;

      // Flag for limit re-entry: next same-direction signal → place limit
      g_trailHitDir          = closedDir;
      g_awaitingLimitReentry = true;
      g_minBarsCountdown     = 0; // Allow next bar to place the limit immediately

      PrintFormat("Trail SL hit [%s] — awaiting limit re-entry | state reset",
                  (closedDir==ORDER_TYPE_BUY?"BUY":"SELL"));
   }
   else
   {
      // TP or manual close: standard reset, no limit reentry
      g_beSet            = false;
      g_peakProfitPts    = 0.0;
      g_candleFavorCount = 0;
      g_awaitingLimitReentry = false;
      if (InpMinBarsBetween > 0) g_minBarsCountdown = InpMinBarsBetween;
   }

   // ── Chop pause tracking ───────────────────────────────────────────────────
   if (InpChopLossTrigger > 0)
   {
      if (netPnL < 0.0)
      {
         if (g_hasLastLossDir && closedDir != g_lastLossDir)
         {
            g_chopLossCount++;
            PrintFormat("ChopDetect: alternating loss #%d (%s→%s)",
                        g_chopLossCount,
                        (g_lastLossDir==ORDER_TYPE_BUY?"BUY":"SELL"),
                        (closedDir    ==ORDER_TYPE_BUY?"BUY":"SELL"));
            if (!g_chopPauseMode && g_chopLossCount >= InpChopLossTrigger)
            {
               g_chopPauseMode    = true;
               g_chopRecoverCount = 0;
               PrintFormat("ChopPause ON: %d alternating losses — entries at MinLot until %d wins",
                           g_chopLossCount, InpChopRecoverTrades);
            }
         }
         else { g_chopLossCount = 1; }
         g_hasLastLossDir = true;
         g_lastLossDir    = closedDir;
      }
      else if (netPnL > 0.0)
      {
         g_chopLossCount  = 0;
         g_hasLastLossDir = false;
         if (g_chopPauseMode)
         {
            g_chopRecoverCount++;
            PrintFormat("ChopPause: +%.2f | recovery=%d/%d", netPnL, g_chopRecoverCount, InpChopRecoverTrades);
            if (g_chopRecoverCount >= InpChopRecoverTrades)
            {
               g_chopPauseMode    = false;
               g_chopRecoverCount = 0;
               PrintFormat("ChopPause OFF: %d wins — normal lot restored", InpChopRecoverTrades);
            }
         }
      }
   }
}
