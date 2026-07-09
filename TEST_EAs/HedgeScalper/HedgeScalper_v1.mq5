//+------------------------------------------------------------------+
//|  HedgeScalper_v1.mq5  v1.00                                      |
//|                                                                   |
//|  PHILOSOPHY                                                       |
//|  ──────────                                                       |
//|  Opens a symmetrical hedge — N buys AND N sells simultaneously.  |
//|  Every tick it evaluates which side has the floating P&L edge.   |
//|                                                                   |
//|  LOSING side  → trim the worst position (stops the bleed).       |
//|                 One position at a time, with a cooldown timer.   |
//|                 Only trims when the losing side is actually in    |
//|                 the red AND the gap to the winner exceeds the     |
//|                 advantage threshold.                              |
//|                                                                   |
//|  WINNING side → pyramid: add smaller positions as it runs.       |
//|                 Triggered when winner P&L clears X% of equity.  |
//|                                                                   |
//|  RE-HEDGE     → once the losing side is fully trimmed, open one  |
//|                 small position on the now-flat side as insurance  |
//|                 against a sudden reversal erasing open profits.   |
//|                                                                   |
//|  HARD SL      → every trade has an ATR-based broker SL.          |
//|                 Not the primary exit — just the news backstop.   |
//|                                                                   |
//|  BASKET EXIT  → when net (buy+sell) P&L hits target % → close   |
//|                 all and restart. Emergency SL does the same.     |
//|                                                                   |
//|  RESULT       → balance is protected because closing the losing  |
//|                 side stops it dragging further, while the winning |
//|                 side continues to compound. The re-hedge ensures  |
//|                 a reversal doesn't wipe what was gained.         |
//+------------------------------------------------------------------+
#property copyright "HedgeScalper v1"
#property link      ""
#property version   "1.00"
#property description "HedgeScalper v1: trim losers, ride winners, re-hedge gains, protect equity"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────

input group "=== Initial Basket ==="
input int             InpBasketSize       = 3;       // Positions per side at open (3 buys + 3 sells)
input double          InpBaseLot          = 0.03;    // Lot size per initial position
input int             InpMaxPerSide       = 8;       // Hard cap: max positions on one side
input long            InpMagicNumber      = 556677;  // EA magic number
input int             InpMaxSlippage      = 30;      // Max slippage in points

input group "=== ATR (Spacing & Stop Loss) ==="
input int             InpATRPeriod        = 14;      // ATR period
input ENUM_TIMEFRAMES InpATRTF            = PERIOD_M5; // ATR timeframe
input double          InpSLMultiplier     = 3.5;     // SL distance = ATR × this (backstop per trade)

input group "=== Advantage Detection ==="
input double          InpAdvantagePct     = 0.20;    // Winning side must lead by >= X% equity to act
input int             InpTrimCooldown     = 15;      // Seconds between trim actions

input group "=== Pyramid (Add to Winner) ==="
input bool            InpUsePyramid       = true;    // Pyramid into the winning side
input int             InpMaxPyramidAdds   = 4;       // Max extra positions added to winner this basket
input double          InpPyramidLotRatio  = 0.75;    // Pyramid lot = BaseLot × ratio (smaller adds)
input double          InpPyramidTrigPct   = 0.30;    // Trigger: winning side P&L >= X% equity before adding
input int             InpPyramidCooldown  = 30;      // Seconds between pyramid adds

input group "=== Re-Hedge (Protect Gains) ==="
input bool            InpUseReHedge       = true;    // Re-open small opposite after losing side is cleared
input double          InpReHedgeLotRatio  = 0.40;    // Re-hedge lot = BaseLot × ratio
input int             InpReHedgeCooldown  = 60;      // Seconds after losing side cleared before re-hedging

input group "=== Basket Exit ==="
input double          InpBasketTPPct      = 2.50;    // Close ALL: net P&L >= +X% equity → take profit
input double          InpEmergencyLossPct = 3.50;    // Close ALL: net P&L <= -X% equity → emergency stop
input bool            InpRestart          = true;    // Auto-restart a new basket after close
input int             InpRestartDelay     = 45;      // Seconds to wait before opening next basket

input group "=== Entry Gate ==="
input ENUM_TIMEFRAMES InpSignalTF         = PERIOD_M1; // Timeframe to read bar direction
input bool            InpRequireSignal    = false;   // Wait for strong directional bar to open basket
input double          InpMinBodyPct       = 40.0;    // Min body % of candle range to qualify as signal

//──────────────────────────────────────────────────────────────────
// GLOBALS
//──────────────────────────────────────────────────────────────────

CTrade        g_trade;
CPositionInfo g_pos;

int      g_atr          = INVALID_HANDLE;
double   g_atrBuf[];

bool     g_active       = false;    // Is a basket currently live?
int      g_pyramidCount = 0;        // Pyramid adds placed this basket
bool     g_reHedgeDone  = false;    // Re-hedge placed this basket?

datetime g_lastBarTime       = 0;
datetime g_lastTrimTime      = 0;
datetime g_lastPyramidTime   = 0;
datetime g_lastCloseTime     = 0;
datetime g_losingSideClearedAt = 0; // When the losing side first hit 0 positions

//──────────────────────────────────────────────────────────────────
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpMaxSlippage);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_atr = iATR(_Symbol, InpATRTF, InpATRPeriod);
   if(g_atr == INVALID_HANDLE) { Print("ATR init failed: ", GetLastError()); return INIT_FAILED; }
   ArraySetAsSeries(g_atrBuf, true);

   Print("HedgeScalper v1.00 initialized — ", _Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atr != INVALID_HANDLE) IndicatorRelease(g_atr);
   Comment("");
}

//──────────────────────────────────────────────────────────────────
// UTILITY FUNCTIONS
//──────────────────────────────────────────────────────────────────

double GetATR()
{
   if(CopyBuffer(g_atr, 0, 0, 3, g_atrBuf) < 3) return 0;
   return g_atrBuf[1]; // last closed bar
}

//── Count positions on one side (filtered by magic + symbol)
int CountSide(ENUM_POSITION_TYPE type)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) &&
         g_pos.Symbol()  == _Symbol &&
         g_pos.Magic()   == (ulong)InpMagicNumber &&
         g_pos.PositionType() == type)
         n++;
   return n;
}

//── Floating P&L for one side (profit + swap)
double SidePnL(ENUM_POSITION_TYPE type)
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) &&
         g_pos.Symbol()  == _Symbol &&
         g_pos.Magic()   == (ulong)InpMagicNumber &&
         g_pos.PositionType() == type)
         total += g_pos.Profit() + g_pos.Swap();
   return total;
}

//── Ticket of the most negative (worst) position on a side
ulong WorstTicket(ENUM_POSITION_TYPE type)
{
   ulong  ticket = 0;
   double worst  = DBL_MAX;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) &&
         g_pos.Symbol()  == _Symbol &&
         g_pos.Magic()   == (ulong)InpMagicNumber &&
         g_pos.PositionType() == type)
      {
         double pnl = g_pos.Profit() + g_pos.Swap();
         if(pnl < worst) { worst = pnl; ticket = g_pos.Ticket(); }
      }
   return ticket;
}

//── Close every position this EA owns
void CloseAll(string reason)
{
   Print("CloseAll [", reason, "]");
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) &&
         g_pos.Symbol() == _Symbol &&
         g_pos.Magic()  == (ulong)InpMagicNumber)
         g_trade.PositionClose(g_pos.Ticket());
}

//── Open one market order with ATR-based hard SL
bool OpenOrder(ENUM_ORDER_TYPE type, double lot, double atr, string label = "")
{
   double slDist  = atr * InpSLMultiplier;
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double price, sl;

   if(type == ORDER_TYPE_BUY)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl    = NormalizeDouble(price - slDist, digits);
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl    = NormalizeDouble(price + slDist, digits);
   }

   // Normalise lot to broker step
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(minLot, MathMin(maxLot, MathRound(lot / lotStep) * lotStep));

   bool ok = (type == ORDER_TYPE_BUY)
      ? g_trade.Buy(lot,  _Symbol, price, sl, 0, "HS:" + label)
      : g_trade.Sell(lot, _Symbol, price, sl, 0, "HS:" + label);

   if(!ok)
      Print("OpenOrder failed [", EnumToString(type), "]: rc=", g_trade.ResultRetcode(),
            " ", g_trade.ResultRetcodeDescription());
   return ok;
}

//── Bar body direction (used when InpRequireSignal = true)
int GetBarSignal()
{
   double o = iOpen (_Symbol, InpSignalTF, 1);
   double c = iClose(_Symbol, InpSignalTF, 1);
   double h = iHigh (_Symbol, InpSignalTF, 1);
   double l = iLow  (_Symbol, InpSignalTF, 1);
   double range = h - l;
   if(range <= 0) return 0;
   double body = MathAbs(c - o);
   if(body / range * 100.0 < InpMinBodyPct) return 0;
   return (c > o) ? 1 : -1;
}

//── Open the initial symmetrical basket
void OpenBasket(double atr)
{
   for(int i = 0; i < InpBasketSize; i++)
      OpenOrder(ORDER_TYPE_BUY,  InpBaseLot, atr, "init");
   for(int i = 0; i < InpBasketSize; i++)
      OpenOrder(ORDER_TYPE_SELL, InpBaseLot, atr, "init");

   g_active             = true;
   g_pyramidCount       = 0;
   g_reHedgeDone        = false;
   g_lastTrimTime       = 0;
   g_lastPyramidTime    = 0;
   g_losingSideClearedAt = 0;

   Print("Basket opened: ", InpBasketSize, " buys + ", InpBasketSize, " sells");
}

//── On-chart status panel
void DrawPanel(int buyCount, int sellCount,
               double buyPnL, double sellPnL,
               double equity, bool buyWin, bool sellWin)
{
   double net  = buyPnL + sellPnL;
   double netPct = (equity > 0) ? net / equity * 100.0 : 0;

   string sideStr;
   if(buyWin)        sideStr = ">>> BUY side leading";
   else if(sellWin)  sideStr = "<<< SELL side leading";
   else              sideStr = "-- Balanced / evaluating";

   string panel = StringFormat(
      "═══ HedgeScalper v1.00 ═══\n"
      "Symbol   : %s\n"
      "Basket   : %s\n"
      "Status   : %s\n"
      "─────────────────────────\n"
      "Buys     : %d pos   P&L %+.2f\n"
      "Sells    : %d pos   P&L %+.2f\n"
      "─────────────────────────\n"
      "Net P&L  : %+.2f  (%+.2f%%)\n"
      "TP target: +%.2f%%   SL gate: -%.2f%%\n"
      "─────────────────────────\n"
      "Pyramids : %d / %d added\n"
      "Re-hedge : %s",
      _Symbol,
      g_active ? "ACTIVE" : "WAITING",
      sideStr,
      buyCount, buyPnL,
      sellCount, sellPnL,
      net, netPct,
      InpBasketTPPct, InpEmergencyLossPct,
      g_pyramidCount, InpMaxPyramidAdds,
      g_reHedgeDone ? "placed" : "pending"
   );
   Comment(panel);
}

//──────────────────────────────────────────────────────────────────
// MAIN TICK
//──────────────────────────────────────────────────────────────────
void OnTick()
{
   double atr    = GetATR();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(atr <= 0 || equity <= 0) return;

   // Current state snapshot
   int    buyCount  = CountSide(POSITION_TYPE_BUY);
   int    sellCount = CountSide(POSITION_TYPE_SELL);
   int    total     = buyCount + sellCount;
   double buyPnL    = (buyCount  > 0) ? SidePnL(POSITION_TYPE_BUY)  : 0.0;
   double sellPnL   = (sellCount > 0) ? SidePnL(POSITION_TYPE_SELL) : 0.0;
   double netPnL    = buyPnL + sellPnL;

   // Advantage calculation
   double diff      = buyPnL - sellPnL;        // + = buys ahead, - = sells ahead
   double threshold = equity * InpAdvantagePct / 100.0;
   bool   buyWin    = (diff >  threshold);
   bool   sellWin   = (diff < -threshold);

   DrawPanel(buyCount, sellCount, buyPnL, sellPnL, equity, buyWin, sellWin);

   //────────────────────────────────────────────────────────────────
   // A. BASKET EXIT CHECKS  (priority: run every tick while active)
   //────────────────────────────────────────────────────────────────
   if(g_active && total > 0)
   {
      double tpUSD = equity * InpBasketTPPct     / 100.0;
      double slUSD = equity * InpEmergencyLossPct / 100.0 * -1.0;

      if(netPnL >= tpUSD)
      {
         CloseAll(StringFormat("Basket TP: %.2f >= %.2f", netPnL, tpUSD));
         g_active        = false;
         g_lastCloseTime = TimeCurrent();
         return;
      }
      if(netPnL <= slUSD)
      {
         CloseAll(StringFormat("Emergency SL: %.2f <= %.2f", netPnL, slUSD));
         g_active        = false;
         g_lastCloseTime = TimeCurrent();
         return;
      }
   }

   //────────────────────────────────────────────────────────────────
   // B. DETECT EXTERNAL CLOSE (SL hits, manual close)
   //────────────────────────────────────────────────────────────────
   if(g_active && total == 0)
   {
      Print("Basket cleared externally (SL or manual)");
      g_active        = false;
      g_lastCloseTime = TimeCurrent();
   }

   //────────────────────────────────────────────────────────────────
   // C. OPEN NEW BASKET
   //────────────────────────────────────────────────────────────────
   if(!g_active)
   {
      // Single-run mode: don't restart if disabled
      if(!InpRestart && g_lastCloseTime > 0) return;

      // Wait restart delay
      if(TimeCurrent() - g_lastCloseTime < (datetime)InpRestartDelay) return;

      // Bar gate — only once per new bar
      datetime barTime = iTime(_Symbol, InpSignalTF, 0);
      if(barTime == g_lastBarTime) return;
      g_lastBarTime = barTime;

      // Optional directional signal check
      if(InpRequireSignal && GetBarSignal() == 0) return;

      OpenBasket(atr);
      return;
   }

   //────────────────────────────────────────────────────────────────
   // D. ACTIVE BASKET MANAGEMENT
   //────────────────────────────────────────────────────────────────
   if(!g_active || total == 0) return;

   //── D1. TRIM: close the worst position on the losing side ────────
   //    Conditions to trim:
   //      • One side clearly leads (advantage > threshold)
   //      • Losing side is actually IN THE RED (not just less positive)
   //      • Cooldown elapsed since last trim
   if(TimeCurrent() - g_lastTrimTime >= (datetime)InpTrimCooldown)
   {
      if(buyWin && sellCount > 0 && sellPnL < 0.0)
      {
         // Buys are ahead and sells are bleeding — close the worst sell
         ulong t = WorstTicket(POSITION_TYPE_SELL);
         if(t > 0)
         {
            Print("TRIM SELL ticket=", t,
                  " | buy lead=+", DoubleToString(diff, 2),
                  " | sell P&L=", DoubleToString(sellPnL, 2));
            if(g_trade.PositionClose(t))
               g_lastTrimTime = TimeCurrent();
         }
      }
      else if(sellWin && buyCount > 0 && buyPnL < 0.0)
      {
         // Sells are ahead and buys are bleeding — close the worst buy
         ulong t = WorstTicket(POSITION_TYPE_BUY);
         if(t > 0)
         {
            Print("TRIM BUY ticket=", t,
                  " | sell lead=+", DoubleToString(-diff, 2),
                  " | buy P&L=", DoubleToString(buyPnL, 2));
            if(g_trade.PositionClose(t))
               g_lastTrimTime = TimeCurrent();
         }
      }
   }

   // Re-read counts after potential trim (positions may have changed)
   buyCount  = CountSide(POSITION_TYPE_BUY);
   sellCount = CountSide(POSITION_TYPE_SELL);

   //── D2. PYRAMID: add smaller lots to the winning side ───────────
   //    Conditions:
   //      • Pyramid enabled
   //      • Max adds not reached
   //      • Winning side P&L >= pyramid trigger % of equity
   //      • Cooldown elapsed
   //      • Max per side not breached
   if(InpUsePyramid &&
      g_pyramidCount < InpMaxPyramidAdds &&
      TimeCurrent() - g_lastPyramidTime >= (datetime)InpPyramidCooldown)
   {
      double pyLot = InpBaseLot * InpPyramidLotRatio;
      double pyMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double pyTrig = equity * InpPyramidTrigPct / 100.0;

      if(pyLot < pyMin) pyLot = pyMin;

      if(buyWin && buyCount < InpMaxPerSide && buyPnL >= pyTrig)
      {
         Print("PYRAMID BUY #", g_pyramidCount + 1,
               " | buyPnL=", DoubleToString(buyPnL, 2),
               " trigger=", DoubleToString(pyTrig, 2));
         if(OpenOrder(ORDER_TYPE_BUY, pyLot, atr, "pyr"))
         {
            g_pyramidCount++;
            g_lastPyramidTime = TimeCurrent();
         }
      }
      else if(sellWin && sellCount < InpMaxPerSide && sellPnL >= pyTrig)
      {
         Print("PYRAMID SELL #", g_pyramidCount + 1,
               " | sellPnL=", DoubleToString(sellPnL, 2),
               " trigger=", DoubleToString(pyTrig, 2));
         if(OpenOrder(ORDER_TYPE_SELL, pyLot, atr, "pyr"))
         {
            g_pyramidCount++;
            g_lastPyramidTime = TimeCurrent();
         }
      }
   }

   // Re-read counts after potential pyramid add
   buyCount  = CountSide(POSITION_TYPE_BUY);
   sellCount = CountSide(POSITION_TYPE_SELL);

   //── D3. RE-HEDGE: protect winning side once losing side is cleared
   //    Conditions:
   //      • Re-hedge enabled and not already done this basket
   //      • Losing side is fully trimmed (count == 0)
   //      • Winning side still has positions
   //      • Cooldown elapsed since losing side cleared
   if(InpUseReHedge && !g_reHedgeDone)
   {
      bool buysOnly  = (buyWin  && sellCount == 0 && buyCount  > 0);
      bool sellsOnly = (sellWin && buyCount  == 0 && sellCount > 0);

      // Record when losing side first became 0
      if((buysOnly || sellsOnly) && g_losingSideClearedAt == 0)
         g_losingSideClearedAt = TimeCurrent();

      // Reset clock if advantage is gone or both sides still have positions
      if(!buysOnly && !sellsOnly)
         g_losingSideClearedAt = 0;

      // Open re-hedge after cooldown
      if(g_losingSideClearedAt > 0 &&
         TimeCurrent() - g_losingSideClearedAt >= (datetime)InpReHedgeCooldown)
      {
         double rhLot = InpBaseLot * InpReHedgeLotRatio;
         double rhMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(rhLot < rhMin) rhLot = rhMin;

         if(buysOnly)
         {
            Print("RE-HEDGE: small SELL to insure buy gains | buyPnL=", DoubleToString(buyPnL, 2));
            if(OpenOrder(ORDER_TYPE_SELL, rhLot, atr, "reh"))
               g_reHedgeDone = true;
         }
         else if(sellsOnly)
         {
            Print("RE-HEDGE: small BUY to insure sell gains | sellPnL=", DoubleToString(sellPnL, 2));
            if(OpenOrder(ORDER_TYPE_BUY, rhLot, atr, "reh"))
               g_reHedgeDone = true;
         }
      }
   }
}
//+------------------------------------------------------------------+
