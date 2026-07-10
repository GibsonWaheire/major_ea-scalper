//+------------------------------------------------------------------+
//|  BasketHedger_v1.mq5  — Self-Protecting Basket Hedger (Gold)   |
//|                                                                   |
//|  FLOW:                                                            |
//|  1. Signal fires → validate → open trade (0.05 lot, 1000pt SL) |
//|  2. Tick loop — count winners / losers / net P&L                |
//|                                                                   |
//|  SCENARIO A  (3 trades, 2W/1L):                                 |
//|    net >= Target_net → Close ALL (lock profit)                  |
//|                                                                   |
//|  SCENARIO B  (4 trades, 3W/1L):                                 |
//|    Close 2 OLDEST winners (scale out cash)                      |
//|    Recalculate loser SL → ATR(14) × 1.5 (risk cap)             |
//|    → Enter Scenario C                                            |
//|                                                                   |
//|  SCENARIO C  (residual: 1W + 1L):                               |
//|    Dynamic barrier: loser SL refreshed each tick (ATR×1.5)      |
//|    Winner profit >= $3 → trailing SL at 0.5 ATR                 |
//|    Timeout (default 15 min) → Close ALL at market               |
//|    Net >= target at any point → Close ALL                        |
//|                                                                   |
//|  UNIVERSAL: net >= Target_net at any state → harvest            |
//|                                                                   |
//|  Target_net = (trades × commission) + (vol × spread$) + $5      |
//|  SL_loser   = price ± ATR(14) × 1.5                            |
//+------------------------------------------------------------------+
#property copyright "BasketHedger v1"
#property link      ""
#property version   "1.00"
#property description "Self-protecting basket hedger for XAUUSD"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//──────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────

input group "=== Entry ==="
input double InpLot            = 0.05;  // Lot per trade
input int    InpSLPoints       = 1000;  // Initial SL in points (spike protection)
input int    InpMaxBasket      = 4;     // Max trades in basket
input long   InpMagic          = 991001;
input int    InpSlippage       = 50;
input int    InpMinGapSec      = 10;    // Min seconds between new opens

input group "=== Signal — Stochastic ==="
input int    InpStochK         = 5;
input int    InpStochD         = 3;
input int    InpStochSlowing   = 3;
input double InpStochBuyLvl    = 60.0;  // K > this → BUY signal
input double InpStochSellLvl   = 40.0;  // K < this → SELL signal

input group "=== Exit & Profit ==="
input double InpMinProfit      = 5.0;   // Minimum net above friction ($)
input double InpCommPerTrade   = 0.50;  // Round-trip commission per trade ($)
input double InpWinnerTrailMin = 3.0;   // Winner profit floor before trailing ($)
input int    InpScenarioCMins  = 15;    // Scenario C timeout (minutes)

input group "=== ATR Dynamic SL ==="
input int    InpATRPeriod      = 14;
input double InpATRMult        = 1.5;   // Loser SL = price ± ATR × this
input double InpTrailATRMult   = 0.5;   // Winner trail = price ± ATR × this

input group "=== Risk Guards ==="
input double InpMaxSpreadPts   = 30.0;  // Block entries if spread > this (pts)
input double InpEmergencySpread= 80.0;  // Move all SLs to BE if spread > this
input int    InpRolloverHHMM   = 2350;  // Rollover block start (server HHMM)
input int    InpRolloverEndHHMM= 30;    // Rollover block end   (server HHMM)

input group "=== All-Losers Guard ==="
input double InpMaxAllLoss     = 20.0;  // Close all if basket net <= -this ($) when all losing
input int    InpAllLoserMins   = 3;     // Close all after this many minutes if all losing
input double InpStochExtreme   = 15.0;  // Stoch K below/above this = overshoot (hold briefly)
input double InpMaxAddLoss     = 10.0;  // Block adding new trade if basket already losing > this ($)
input int    InpStackGapSec    = 60;    // Min seconds between stacked trade opens (slows rapid stacking)

input group "=== Hedge Recovery ==="
input double InpHedgeMaxMult   = 3.0;   // Max hedge lot = basket volume × this (caps risk)

//──────────────────────────────────────────────────────────────────
// ENUMS & GLOBALS
//──────────────────────────────────────────────────────────────────

enum BASKET_STATE
{
   STATE_IDLE,        // No open positions — waiting for signal
   STATE_ACTIVE,      // Building basket (1–4 trades)
   STATE_SCENARIO_C   // Residual phase: 1 winner + 1 loser
};

CTrade        g_trade;
CPositionInfo g_pos;

int           g_stochHandle    = INVALID_HANDLE;
int           g_atrHandle      = INVALID_HANDLE;

BASKET_STATE  g_state          = STATE_IDLE;
datetime      g_lastOpen       = 0;
datetime      g_scenarioCStart = 0;
double        g_sessionPnL     = 0;
int           g_harvests       = 0;
bool          g_scenBDone      = false; // Prevent re-triggering Scenario B
datetime      g_allLoserStart  = 0;    // When all-losers situation began
bool          g_hedgeOpen      = false; // Recovery hedge is active

//──────────────────────────────────────────────────────────────────
// BASIC HELPERS
//──────────────────────────────────────────────────────────────────

double NormLot()
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return MathMax(mn, MathMin(mx, MathRound(InpLot / st) * st));
}

double GetATR()
{
   if(g_atrHandle == INVALID_HANDLE) return 0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 1, buf) <= 0) return 0;
   return buf[0];
}

double GetSpreadPoints()
{
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
           SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
}

bool SpreadOK()
{
   return GetSpreadPoints() <= InpMaxSpreadPts;
}

bool IsRollover()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hhmm = dt.hour * 100 + dt.min;
   if(InpRolloverHHMM > InpRolloverEndHHMM)   // window crosses midnight
      return (hhmm >= InpRolloverHHMM || hhmm <= InpRolloverEndHHMM);
   return (hhmm >= InpRolloverHHMM && hhmm <= InpRolloverEndHHMM);
}

// Returns dominant direction in basket (whichever side has more positions)
ENUM_POSITION_TYPE BasketMajorDir()
{
   int buys = 0, sells = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic)
      {
         if(g_pos.PositionType() == POSITION_TYPE_BUY) buys++;
         else sells++;
      }
   return (buys >= sells) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
}

//──────────────────────────────────────────────────────────────────
// BASKET MEASUREMENT
//──────────────────────────────────────────────────────────────────

int BasketTotal()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic)
         n++;
   return n;
}

int CountWinners()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic &&
         g_pos.Profit() + g_pos.Swap() > 0)
         n++;
   return n;
}

int CountLosers()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic &&
         g_pos.Profit() + g_pos.Swap() <= 0)
         n++;
   return n;
}

double TotalPnL()
{
   double t = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic)
         t += g_pos.Profit() + g_pos.Swap();
   return t;
}

double TotalVolume()
{
   double v = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic)
         v += g_pos.Volume();
   return v;
}

//──────────────────────────────────────────────────────────────────
// TARGET NET CALCULATION
// Target = (trades × commission) + (basket_vol × spread_cost) + $5
//──────────────────────────────────────────────────────────────────

double GetTargetNet(int trades)
{
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double spreadPts = GetSpreadPoints();
   double vol       = TotalVolume();

   double spreadCost = 0;
   if(tickSize > 0)
      spreadCost = vol * (spreadPts * _Point / tickSize) * tickVal;

   return (trades * InpCommPerTrade) + spreadCost + InpMinProfit;
}

//──────────────────────────────────────────────────────────────────
// TICKET FINDERS
//──────────────────────────────────────────────────────────────────

// Returns tickets of the 2 oldest winners by open time
bool GetOldestWinners(ulong &t1, ulong &t2)
{
   ulong    tix[10];
   datetime tms[10];
   int      cnt = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic &&
         g_pos.Profit() + g_pos.Swap() > 0 && cnt < 10)
      {
         tix[cnt] = g_pos.Ticket();
         tms[cnt] = g_pos.Time();
         cnt++;
      }
   }
   if(cnt < 2) return false;

   // Pick earliest open time
   int i1 = 0;
   for(int i = 1; i < cnt; i++)
      if(tms[i] < tms[i1]) i1 = i;

   int i2 = (i1 == 0) ? 1 : 0;
   for(int i = 0; i < cnt; i++)
      if(i != i1 && tms[i] < tms[i2]) i2 = i;

   t1 = tix[i1];
   t2 = tix[i2];
   return true;
}

bool GetLoserTicket(ulong &ticket)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic &&
         g_pos.Profit() + g_pos.Swap() <= 0)
      {
         ticket = g_pos.Ticket();
         return true;
      }
   return false;
}

bool GetWinnerTicket(ulong &ticket)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic &&
         g_pos.Profit() + g_pos.Swap() > 0)
      {
         ticket = g_pos.Ticket();
         return true;
      }
   return false;
}

// Dollar value per point per 1.0 lot for this symbol
double PointValuePerLot()
{
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) return 0;
   return tickVal * _Point / tickSize;
}

// Apply ATR-based SL to ALL losing positions (used after hedge opens)
void SetAllLoserSLs()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic &&
         g_pos.Profit() + g_pos.Swap() <= 0)
         SetATRLoserSL(g_pos.Ticket());
}

// Open a recovery hedge opposite to basketDir.
// Lot is sized to recover currentLoss over 1 ATR distance,
// capped at InpHedgeMaxMult × basket volume.
void OpenHedge(ENUM_POSITION_TYPE basketDir, double currentLoss)
{
   double basketVol = TotalVolume();
   double atr       = GetATR();
   double pv        = PointValuePerLot(); // $ per point per lot

   // Base: match basket volume (neutralises further bleeding)
   double hedgeLot = basketVol;

   // Add extra to recover the existing loss over 1 ATR move
   if(atr > 0 && pv > 0)
   {
      double atrPts  = atr / _Point;
      double extraLot = MathAbs(currentLoss) / (atrPts * pv);
      hedgeLot += extraLot;
   }

   // Cap at max multiplier
   hedgeLot = MathMin(hedgeLot, basketVol * InpHedgeMaxMult);

   // Normalise to broker volume rules
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   hedgeLot  = MathMax(mn, MathMin(mx, MathRound(hedgeLot / st) * st));

   ENUM_POSITION_TYPE hedgeDir = (basketDir == POSITION_TYPE_BUY) ?
                                  POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   bool ok;
   if(hedgeDir == POSITION_TYPE_BUY)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - InpSLPoints * _Point, _Digits);
      ok = g_trade.Buy(hedgeLot, _Symbol, ask, sl, 0, "BH1:hedge");
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + InpSLPoints * _Point, _Digits);
      ok = g_trade.Sell(hedgeLot, _Symbol, bid, sl, 0, "BH1:hedge");
   }

   if(ok)
   {
      g_hedgeOpen = true;
      g_lastOpen  = TimeCurrent();
      Print("HEDGE OPENED: ", hedgeDir == POSITION_TYPE_BUY ? "BUY" : "SELL",
            "  lot=", DoubleToString(hedgeLot, 2),
            "  basketVol=", DoubleToString(basketVol, 2),
            "  loss=", DoubleToString(currentLoss, 2),
            "  ATR=", DoubleToString(atr, _Digits));
   }
}

//──────────────────────────────────────────────────────────────────
// SL MANAGEMENT
//──────────────────────────────────────────────────────────────────

// Set ATR-based SL on loser: price ± ATR(14) × 1.5
// Only tightens (never widens) an existing SL
void SetATRLoserSL(ulong ticket)
{
   double atr = GetATR();
   if(atr <= 0 || !g_pos.SelectByTicket(ticket)) return;

   ENUM_POSITION_TYPE type = g_pos.PositionType();
   double             curSL = g_pos.StopLoss();
   double             newSL;

   if(type == POSITION_TYPE_BUY)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      newSL = NormalizeDouble(bid - atr * InpATRMult, _Digits);
      // Only move SL up (tighter for a buy loser)
      if(curSL > 0 && newSL < curSL) return;
   }
   else
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      newSL = NormalizeDouble(ask + atr * InpATRMult, _Digits);
      // Only move SL down (tighter for a sell loser)
      if(curSL > 0 && newSL > curSL) return;
   }

   if(MathAbs(newSL - curSL) > _Point)
   {
      g_trade.PositionModify(ticket, newSL, g_pos.TakeProfit());
      Print("ATR Loser SL → ", DoubleToString(newSL, _Digits),
            "  ATR=", DoubleToString(atr, _Digits));
   }
}

// Trail winner SL at 0.5 ATR — only moves in the profitable direction
void TrailWinnerSL(ulong ticket)
{
   double atr = GetATR();
   if(atr <= 0 || !g_pos.SelectByTicket(ticket)) return;

   ENUM_POSITION_TYPE type  = g_pos.PositionType();
   double             curSL = g_pos.StopLoss();
   double             newSL;

   if(type == POSITION_TYPE_BUY)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      newSL = NormalizeDouble(bid - atr * InpTrailATRMult, _Digits);
      if(newSL > curSL + _Point)
      {
         g_trade.PositionModify(ticket, newSL, g_pos.TakeProfit());
         Print("Trail winner SL → ", DoubleToString(newSL, _Digits));
      }
   }
   else
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      newSL = NormalizeDouble(ask + atr * InpTrailATRMult, _Digits);
      if(curSL <= 0 || newSL < curSL - _Point)
      {
         g_trade.PositionModify(ticket, newSL, g_pos.TakeProfit());
         Print("Trail winner SL → ", DoubleToString(newSL, _Digits));
      }
   }
}

// Emergency: move all position SLs to break-even
void MoveAllToBreakEven()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i) || g_pos.Symbol()!=_Symbol ||
         g_pos.Magic()!=(ulong)InpMagic) continue;

      double op    = g_pos.PriceOpen();
      double curSL = g_pos.StopLoss();

      if(g_pos.PositionType() == POSITION_TYPE_BUY  && curSL < op - _Point)
         g_trade.PositionModify(g_pos.Ticket(), op, g_pos.TakeProfit());
      else if(g_pos.PositionType() == POSITION_TYPE_SELL &&
              (curSL == 0 || curSL > op + _Point))
         g_trade.PositionModify(g_pos.Ticket(), op, g_pos.TakeProfit());
   }
}

//──────────────────────────────────────────────────────────────────
// BASKET OPEN / CLOSE
//──────────────────────────────────────────────────────────────────

bool OpenBuy(string lbl)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl  = NormalizeDouble(ask - InpSLPoints * _Point, _Digits);
   bool ok = g_trade.Buy(NormLot(), _Symbol, ask, sl, 0, "BH1:" + lbl);
   if(ok) g_lastOpen = TimeCurrent();
   return ok;
}

bool OpenSell(string lbl)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = NormalizeDouble(bid + InpSLPoints * _Point, _Digits);
   bool ok = g_trade.Sell(NormLot(), _Symbol, bid, sl, 0, "BH1:" + lbl);
   if(ok) g_lastOpen = TimeCurrent();
   return ok;
}

void CloseAll(string reason)
{
   double net = TotalPnL();
   Print("CloseAll [", reason, "]  net=", DoubleToString(net, 2),
         "  session=", DoubleToString(g_sessionPnL + net, 2));
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic)
         g_trade.PositionClose(g_pos.Ticket());
   g_sessionPnL     += net;
   g_harvests++;
   g_state           = STATE_IDLE;
   g_scenBDone       = false;
   g_hedgeOpen       = false;
   g_allLoserStart   = 0;
   g_scenarioCStart  = 0;
}

//──────────────────────────────────────────────────────────────────
// SIGNAL
//──────────────────────────────────────────────────────────────────

int GetSignal(double &kOut)
{
   kOut = 50.0;
   if(g_stochHandle == INVALID_HANDLE) return 0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_stochHandle, 0, 0, 1, buf) <= 0) return 0;
   kOut = buf[0];
   if(kOut > InpStochBuyLvl)  return  1;
   if(kOut < InpStochSellLvl) return -1;
   return 0;
}

//──────────────────────────────────────────────────────────────────
// PANEL
//──────────────────────────────────────────────────────────────────

void DrawPanel(int total, int w, int l, double net, double target,
               double stochK, int signal)
{
   string stateTxt;
   switch(g_state)
   {
      case STATE_IDLE:       stateTxt = "IDLE — waiting for signal";     break;
      case STATE_ACTIVE:     stateTxt = "ACTIVE — building basket";      break;
      case STATE_SCENARIO_C: stateTxt = "SCENARIO C — residual protect"; break;
   }

   string sigTxt = (signal == 1) ? "↑ BUY" : (signal == -1) ? "↓ SELL" : "— neutral";

   string timeTxt = "";
   if(g_state == STATE_SCENARIO_C && g_scenarioCStart > 0)
   {
      int rem = InpScenarioCMins * 60 - (int)(TimeCurrent() - g_scenarioCStart);
      timeTxt = StringFormat("  ScenC timeout: %ds", MathMax(0, rem));
   }
   if(g_allLoserStart > 0)
   {
      int rem = InpAllLoserMins * 60 - (int)(TimeCurrent() - g_allLoserStart);
      timeTxt += StringFormat("  [ALL-LOSS exit: %ds / -$%.0f]", MathMax(0, rem), InpMaxAllLoss);
   }

   Comment(StringFormat(
      "═══ BasketHedger v1.00 ═══\n"
      "State      : %s\n"
      "Basket     : %d trades  W:%d  L:%d\n"
      "Stoch K    : %.1f  [%s]\n"
      "Spread     : %.1f pts  %s\n"
      "────────────────────────\n"
      "Net P&L    : %+.2f\n"
      "Target     : %+.2f\n"
      "────────────────────────\n"
      "Session    : %+.2f  Cycles: %d\n"
      "Equity     : %.2f%s",
      stateTxt,
      total, w, l,
      stochK, sigTxt,
      GetSpreadPoints(), IsRollover() ? "[ROLLOVER]" : "",
      net,
      target,
      g_sessionPnL + net, g_harvests,
      AccountInfoDouble(ACCOUNT_EQUITY),
      timeTxt
   ));
}

//──────────────────────────────────────────────────────────────────
// INIT / DEINIT / TICK
//──────────────────────────────────────────────────────────────────

int OnInit()
{
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_stochHandle = iStochastic(_Symbol, PERIOD_M1, InpStochK, InpStochD,
                                InpStochSlowing, MODE_SMA, STO_LOWHIGH);
   g_atrHandle   = iATR(_Symbol, PERIOD_M1, InpATRPeriod);

   if(g_stochHandle == INVALID_HANDLE) Print("Warning: Stochastic handle failed");
   if(g_atrHandle   == INVALID_HANDLE) Print("Warning: ATR handle failed");

   if(BasketTotal() > 0)
   {
      g_state = STATE_ACTIVE;
      Print("Resumed with ", BasketTotal(), " existing positions");
   }

   Print("BasketHedger v1.00 — ", _Symbol,
         "  lot=", InpLot,
         "  minProfit=$", InpMinProfit,
         "  ScenC=", InpScenarioCMins, "min",
         "  ATR=", InpATRPeriod, "×", InpATRMult);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_stochHandle != INVALID_HANDLE) IndicatorRelease(g_stochHandle);
   if(g_atrHandle   != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   Comment("");
}

void OnTick()
{
   int    total  = BasketTotal();
   int    wins   = CountWinners();
   int    losses = CountLosers();
   double net    = TotalPnL();
   double target = GetTargetNet(total);

   double stochK = 50.0;
   int    signal = GetSignal(stochK);

   DrawPanel(total, wins, losses, net, target, stochK, signal);

   //── EMERGENCY SPREAD GUARD ──────────────────────────────────
   if(GetSpreadPoints() >= InpEmergencySpread && total > 0)
   {
      Print("EMERGENCY SPREAD: ", DoubleToString(GetSpreadPoints(), 1),
            " pts — moving all SLs to BE");
      MoveAllToBreakEven();
      return;
   }

   //── IDLE: wait for signal, open first trade ─────────────────
   if(g_state == STATE_IDLE)
   {
      if(total > 0) { g_state = STATE_ACTIVE; return; } // resuming
      if(!SpreadOK() || IsRollover() || signal == 0) return;

      bool ok = (signal == 1) ? OpenBuy("init") : OpenSell("init");
      if(ok)
      {
         g_state     = STATE_ACTIVE;
         g_scenBDone = false;
         Print("BASKET OPEN: ", signal == 1 ? "BUY" : "SELL",
               "  K=", DoubleToString(stochK, 1));
      }
      return;
   }

   //── POSITIONS CLOSED EXTERNALLY ─────────────────────────────
   if(total == 0)
   {
      g_sessionPnL    += net;
      g_harvests++;
      g_state          = STATE_IDLE;
      g_scenBDone      = false;
      g_scenarioCStart = 0;
      Print("All positions gone externally — session=",
            DoubleToString(g_sessionPnL, 2));
      return;
   }

   //── UNIVERSAL HARVEST — works in any state ──────────────────
   if(net >= target && target > 0)
   {
      Print("HARVEST: net=", DoubleToString(net, 2),
            " >= target=", DoubleToString(target, 2));
      CloseAll("Harvest");
      return;
   }

   //── HEDGE TRIGGER ────────────────────────────────────────────
   // Only fires when loss is meaningful (not just spread cost on fresh trade).
   // A fresh trade starts at ~-$1.50 (spread). Require -InpMaxAddLoss minimum.
   if(wins == 0 && losses == total && total > 0 && !g_hedgeOpen &&
      net <= -InpMaxAddLoss)
   {
      ENUM_POSITION_TYPE majorDir = BasketMajorDir();
      bool signalFlipped = (majorDir == POSITION_TYPE_BUY  && signal == -1) ||
                           (majorDir == POSITION_TYPE_SELL && signal ==  1);

      if(signalFlipped && SpreadOK())
      {
         Print("SIGNAL FLIP vs ALL-LOSERS: opening recovery hedge");
         OpenHedge(majorDir, net);
         // Do NOT tighten loser SLs here — losers are deep underwater.
         // ATR×1.5 from current price would be ~15pts = instant SL hit.
         // Keep original 1000pt SLs; hedge needs room to recover them.
         g_allLoserStart  = 0;
         g_state          = STATE_SCENARIO_C;
         g_scenarioCStart = TimeCurrent();
         return;
      }
   }

   //── ALL-LOSERS GUARD ─────────────────────────────────────────
   // Only fires when loss is meaningful AND hedge is not active.
   // Minimum -InpMaxAddLoss prevents firing on fresh trades (spread cost only).
   if(wins == 0 && losses == total && total > 0 && !g_hedgeOpen &&
      net <= -InpMaxAddLoss)
   {
      if(g_allLoserStart == 0) g_allLoserStart = TimeCurrent();

      ENUM_POSITION_TYPE majorDir = BasketMajorDir();
      bool overshoot = (majorDir == POSITION_TYPE_BUY  && stochK < InpStochExtreme) ||
                       (majorDir == POSITION_TYPE_SELL && stochK > 100.0 - InpStochExtreme);

      if(overshoot)
      {
         // Price overshot — give it time but enforce hard cap
         int elapsed = (int)(TimeCurrent() - g_allLoserStart);
         if(net <= -InpMaxAllLoss)
         {
            Print("ALL-LOSERS MAX_LOSS: net=", DoubleToString(net, 2),
                  " <= -", InpMaxAllLoss, "  K=", DoubleToString(stochK, 1));
            CloseAll("AllLosers_MaxLoss");
            return;
         }
         if(elapsed >= InpAllLoserMins * 60)
         {
            Print("ALL-LOSERS TIMEOUT: ", elapsed / 60, "min  net=",
                  DoubleToString(net, 2), "  K=", DoubleToString(stochK, 1));
            CloseAll("AllLosers_Timeout");
            return;
         }
         // Still within tolerance — hold, do not add more trades
         return;
      }
      else
      {
         // Stoch not extreme — real directional move, exit immediately
         Print("ALL-LOSERS REAL_TREND: K=", DoubleToString(stochK, 1),
               "  net=", DoubleToString(net, 2));
         CloseAll("AllLosers_RealTrend");
         return;
      }
   }
   else
   {
      g_allLoserStart = 0; // Reset when basket has at least one winner
   }

   //═══════════════════════════════════════════════════════════
   // STATE: SCENARIO C  (residual: 1W + 1L)
   //═══════════════════════════════════════════════════════════
   if(g_state == STATE_SCENARIO_C)
   {
      // Hedge SL hit — no winners left, close all remaining losers
      if(wins == 0)
      {
         Print("SCENARIO C: hedge/winner gone — closing all losers");
         CloseAll("ScenC_WinnersGone");
         return;
      }
      // All loser SLs hit naturally — let winner(s) keep running,
      // universal harvest will close when net >= target.
      // Only close if 1 trade left and it's a winner (can't improve further).
      if(losses == 0 && total == 1)
      {
         Print("SCENARIO C: single winner remains — harvesting");
         CloseAll("ScenC_SingleWinner");
         return;
      }

      // Timeout check
      if(g_scenarioCStart > 0)
      {
         int elapsed = (int)(TimeCurrent() - g_scenarioCStart);
         if(elapsed >= InpScenarioCMins * 60)
         {
            Print("SCENARIO C TIMEOUT: ", elapsed / 60, "min  net=",
                  DoubleToString(net, 2));
            CloseAll("ScenC_Timeout");
            return;
         }
      }

      // Refresh ATR-based SL only when 1 loser (post-Scenario-B).
      // When hedge is active (multiple losers), keep original 1000pt SLs —
      // losers are deep underwater and need room for the hedge to recover them.
      // Tightening to ATR×1.5 (~15pts) would cause instant SL hits.
      if(losses == 1)
         SetAllLoserSLs();

      // Trail the winner (hedge or Scenario B residual winner)
      // Only activates when profit is substantial enough
      ulong winTicket2;
      if(GetWinnerTicket(winTicket2))
      {
         if(g_pos.SelectByTicket(winTicket2))
         {
            double winProfit = g_pos.Profit() + g_pos.Swap();
            if(winProfit >= InpWinnerTrailMin)
               TrailWinnerSL(winTicket2);
         }
      }

      return;
   }

   //═══════════════════════════════════════════════════════════
   // STATE: ACTIVE  (building basket)
   //═══════════════════════════════════════════════════════════

   //── SCENARIO B: 4 trades, exactly 3W / 1L ──────────────────
   if(total == 4 && wins == 3 && losses == 1 && !g_scenBDone)
   {
      Print("SCENARIO B: 3W/1L — scale out 2 oldest winners");
      ulong t1, t2;
      if(GetOldestWinners(t1, t2))
      {
         // Lock partial profit
         g_trade.PositionClose(t1);
         g_trade.PositionClose(t2);

         // Tighten loser SL immediately after scale-out
         ulong lossTicket;
         if(GetLoserTicket(lossTicket))
         {
            SetATRLoserSL(lossTicket);
            Print("SCENARIO B: loser SL tightened to ATR×",
                  DoubleToString(InpATRMult, 1));
         }

         g_scenBDone      = true;
         g_state          = STATE_SCENARIO_C;
         g_scenarioCStart = TimeCurrent();
         Print("→ SCENARIO C entered  timeout=", InpScenarioCMins, "min");
      }
      return;
   }

   //── SCENARIO A: 3 trades, exactly 2W / 1L ──────────────────
   // (Universal harvest above handles the close — this just logs)
   if(total == 3 && wins == 2 && losses == 1)
   {
      // If net not yet at target, hold and let universal harvest catch it
      // Nothing more to do here — no partial close in Scenario A
   }

   //── ADD TRADE: keep building basket up to max ───────────────
   if(total < InpMaxBasket && !g_scenBDone)
   {
      // Use stack gap (slower) for 2nd trade onwards, min gap for first
      int gapRequired = (total == 0) ? InpMinGapSec : InpStackGapSec;
      if(TimeCurrent() - g_lastOpen < (datetime)gapRequired) return;
      if(!SpreadOK() || IsRollover() || signal == 0) return;

      // Block add if basket already losing more than pre-open threshold
      // Prevents bypassing the $20 all-losers gate via rapid stacking
      if(total > 0 && net <= -InpMaxAddLoss)
      {
         Print("STACK BLOCKED: basket net=", DoubleToString(net, 2),
               " <= -", InpMaxAddLoss, " (pre-open loss gate)");
         return;
      }

      bool ok = (signal == 1) ? OpenBuy("add") : OpenSell("add");
      if(ok)
         Print("BASKET ADD #", total + 1, ": ",
               signal == 1 ? "BUY" : "SELL",
               "  K=", DoubleToString(stochK, 1),
               "  W=", wins, " L=", losses,
               "  net=", DoubleToString(net, 2));
   }
}
//+------------------------------------------------------------------+
