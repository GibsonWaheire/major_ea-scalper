//+------------------------------------------------------------------+
//|  HedgeScalper_v3.mq5  v3.00                                      |
//|                                                                   |
//|  BASKET STATES                                                   |
//|  ─────────────                                                   |
//|  BALANCED    2B + 2S   default / return state                   |
//|  LEAN BUY    3B + 1S   buys pulling ahead                       |
//|  LEAN SELL   1B + 3S   sells pulling ahead                      |
//|  SPRINT BUY  4B + sells  short timed burst on momentum          |
//|  SPRINT SELL 4S + buys   short timed burst on momentum          |
//|                                                                   |
//|  CORE ACTIONS (equity must be flat or improving for each)       |
//|  ────────────                                                    |
//|  STARTUP    : read EMA direction → open lean or balanced basket |
//|  LEAN SHIFT : winning side leads by threshold → shift ratio     |
//|  HARVEST    : best winner >= target USD → close it → reopen     |
//|  PAIR CLOSE : best winner + worst loser net positive → close    |
//|               both → reopen to maintain state count             |
//|  SPRINT     : strong momentum → add to 4 on that side → timer  |
//|               exit → trim back to pre-sprint count              |
//|  REVERSE    : opposite side takes lead → shift back to balanced |
//|                                                                   |
//|  SL: 200 pts per trade. Silent backstop only. Strategy ignores  |
//|  it in all decision logic — it just sits there quietly.         |
//+------------------------------------------------------------------+
#property copyright "HedgeScalper v3"
#property link      ""
#property version   "3.00"
#property description "Dynamic basket hedge — BALANCED/LEAN/SPRINT, equity-driven"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//──────────────────────────────────────────────────────────────────
enum BasketState
{
   BS_STARTUP     = 0,
   BS_BALANCED    = 1,   // 2B + 2S
   BS_LEAN_BUY    = 2,   // 3B + 1S
   BS_LEAN_SELL   = 3,   // 1B + 3S
   BS_SPRINT_BUY  = 4,   // 4B + existing sells (timed)
   BS_SPRINT_SELL = 5    // 4S + existing buys  (timed)
};

//──────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────

input group "=== Core ==="
input double          InpLot           = 0.05;   // Fixed lot — same for every position
input long            InpMagic         = 778800;
input int             InpSlippage      = 30;
input int             InpSLPoints      = 200;    // SL per trade (silent backstop, not used in logic)

input group "=== Startup Direction Read ==="
input int             InpEMAPeriod     = 20;     // EMA to read initial market direction
input ENUM_TIMEFRAMES InpEMATF         = PERIOD_M5;
input double          InpEMANeutralPts = 30;     // Price within ±X pts of EMA = neutral → BALANCED

input group "=== Lean Shift Trigger ==="
input double          InpLeanThresh    = 0.50;   // USD: winning side leads by this → go lean
input double          InpLeanMaxLoss   = 1.50;   // Max USD loss on opposite side to allow lean shift
input int             InpLeanCooldown  = 15;     // Seconds between lean state changes

input group "=== Single Harvest ==="
input double          InpHarvestUSD    = 0.80;   // Close best winner when its P&L >= this USD
input int             InpHarvestCool   = 8;      // Seconds between harvests

input group "=== Pair Close ==="
input double          InpPairThresh    = 0.30;   // Net USD needed from pair (winner + loser combined) to close
input int             InpPairCool      = 10;     // Seconds between pair closes

input group "=== Sprint ==="
input int             InpSprintSecs    = 45;     // Max sprint duration (seconds)
input double          InpSprintTarget  = 1.50;   // Close sprint positions when their combined P&L >= this USD
input int             InpSprintPts     = 80;     // Points momentum in window needed to trigger sprint
input int             InpSprintWindow  = 15;     // Seconds to measure momentum for sprint trigger
input int             InpSprintCool    = 120;    // Seconds between sprints

input group "=== Equity Gate ==="
input double          InpEmergPct      = 5.0;    // Close ALL if net P&L <= -X% equity
input double          InpGatePct       = 1.5;    // Pause opening new positions if net P&L <= -X% equity

input group "=== Restart ==="
input bool            InpRestart       = true;
input int             InpRestartDelay  = 20;

//──────────────────────────────────────────────────────────────────
// GLOBALS
//──────────────────────────────────────────────────────────────────

CTrade        g_trade;
CPositionInfo g_pos;

BasketState   g_state          = BS_STARTUP;
int           g_emaH           = INVALID_HANDLE;
double        g_emaBuf[];

datetime      g_lastHarvest    = 0;
datetime      g_lastPair       = 0;
datetime      g_lastSprint     = 0;
datetime      g_lastLean       = 0;
datetime      g_lastOpen       = 0;
datetime      g_lastClose      = 0;
datetime      g_sprintStart    = 0;

// Pre-sprint counts to restore after sprint
int           g_preSprintBuys  = 0;
int           g_preSprintSells = 0;

// Momentum tracking
double        g_momRefPrice    = 0;
datetime      g_momRefTime     = 0;

//──────────────────────────────────────────────────────────────────
// POSITION HELPERS
//──────────────────────────────────────────────────────────────────

int CountSide(ENUM_POSITION_TYPE type)
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic && g_pos.PositionType()==type) n++;
   return n;
}

int CountBuys()  { return CountSide(POSITION_TYPE_BUY);  }
int CountSells() { return CountSide(POSITION_TYPE_SELL); }

int TotalCount()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol && g_pos.Magic()==(ulong)InpMagic) n++;
   return n;
}

double SidePnL(ENUM_POSITION_TYPE type)
{
   double t = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic && g_pos.PositionType()==type)
         t += g_pos.Profit() + g_pos.Swap();
   return t;
}

double TotalPnL()
{
   double t = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol && g_pos.Magic()==(ulong)InpMagic)
         t += g_pos.Profit() + g_pos.Swap();
   return t;
}

// Best (highest P&L) ticket on a side
ulong BestTicket(ENUM_POSITION_TYPE type, double &pnl)
{
   ulong tkt=0; double best=-DBL_MAX;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic && g_pos.PositionType()==type)
      {
         double p = g_pos.Profit()+g_pos.Swap();
         if(p > best){ best=p; tkt=g_pos.Ticket(); }
      }
   pnl = best; return tkt;
}

// Worst (lowest P&L) ticket on a side
ulong WorstTicket(ENUM_POSITION_TYPE type, double &pnl)
{
   ulong tkt=0; double worst=DBL_MAX;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic && g_pos.PositionType()==type)
      {
         double p = g_pos.Profit()+g_pos.Swap();
         if(p < worst){ worst=p; tkt=g_pos.Ticket(); }
      }
   pnl = worst; return tkt;
}

// Close excess positions of one type (close worst ones first to minimise loss)
void TrimSide(ENUM_POSITION_TYPE type, int target)
{
   int cur = CountSide(type);
   while(cur > target)
   {
      double pnl; ulong tkt = WorstTicket(type, pnl);
      if(tkt == 0) break;
      if(g_trade.PositionClose(tkt)) cur--;
      else break;
   }
}

double NormLot()
{
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   return MathMax(mn, MathMin(mx, MathRound(InpLot/st)*st));
}

bool OpenBuy(string lbl)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl  = NormalizeDouble(ask - InpSLPoints*_Point, _Digits);
   bool ok    = g_trade.Buy(NormLot(), _Symbol, ask, sl, 0, "HS:"+lbl);
   if(ok) g_lastOpen = TimeCurrent();
   else Print("OpenBuy failed: ", g_trade.ResultRetcode(), " [", lbl, "]");
   return ok;
}

bool OpenSell(string lbl)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = NormalizeDouble(bid + InpSLPoints*_Point, _Digits);
   bool ok    = g_trade.Sell(NormLot(), _Symbol, bid, sl, 0, "HS:"+lbl);
   if(ok) g_lastOpen = TimeCurrent();
   else Print("OpenSell failed: ", g_trade.ResultRetcode(), " [", lbl, "]");
   return ok;
}

void CloseAll(string reason)
{
   Print("CloseAll: ", reason);
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol && g_pos.Magic()==(ulong)InpMagic)
         g_trade.PositionClose(g_pos.Ticket());
}

//──────────────────────────────────────────────────────────────────
// DIRECTION & MOMENTUM
//──────────────────────────────────────────────────────────────────

// 1=bullish, -1=bearish, 0=neutral
int GetEMADirection()
{
   if(CopyBuffer(g_emaH, 0, 0, 3, g_emaBuf) < 3) return 0;
   double ema  = g_emaBuf[1];
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double diff = (bid - ema) / _Point;
   if(diff >  InpEMANeutralPts) return  1;
   if(diff < -InpEMANeutralPts) return -1;
   return 0;
}

// Returns recent price drift in points (+ve = up, -ve = down)
double GetMomentum()
{
   double now = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_momRefPrice == 0)
   {
      g_momRefPrice = now;
      g_momRefTime  = TimeCurrent();
      return 0;
   }
   double drift = (now - g_momRefPrice) / _Point;
   if(TimeCurrent() - g_momRefTime >= (datetime)InpSprintWindow)
   {
      g_momRefPrice = now;
      g_momRefTime  = TimeCurrent();
   }
   return drift;
}

//──────────────────────────────────────────────────────────────────
// COMMON ACTIONS (used across multiple states)
//──────────────────────────────────────────────────────────────────

// Single harvest: close best winner on winSide, replace with fresh one
bool TryHarvest(ENUM_POSITION_TYPE winSide, bool gateOpen)
{
   if(TimeCurrent() - g_lastHarvest < (datetime)InpHarvestCool) return false;
   double bPnL; ulong bTkt = BestTicket(winSide, bPnL);
   if(bTkt == 0 || bPnL < InpHarvestUSD) return false;
   if(!g_trade.PositionClose(bTkt)) return false;
   g_lastHarvest = TimeCurrent();
   Print("HARVEST: ", EnumToString(winSide), " P&L=", DoubleToString(bPnL,2));
   if(gateOpen)
   {
      if(winSide == POSITION_TYPE_BUY)  OpenBuy("harv_r");
      else                               OpenSell("harv_r");
   }
   return true;
}

// Pair close: close best winner + worst loser if their combined net is positive
bool TryPairClose(ENUM_POSITION_TYPE winSide, ENUM_POSITION_TYPE loseSide, bool gateOpen)
{
   if(TimeCurrent() - g_lastPair < (datetime)InpPairCool) return false;
   double bPnL, wPnL;
   ulong  bTkt = BestTicket(winSide,  bPnL);
   ulong  wTkt = WorstTicket(loseSide, wPnL);
   if(bTkt==0 || wTkt==0) return false;
   if(bPnL + wPnL < InpPairThresh) return false;
   g_trade.PositionClose(bTkt);
   g_trade.PositionClose(wTkt);
   g_lastPair = TimeCurrent();
   Print("PAIR CLOSE: net=", DoubleToString(bPnL+wPnL,2),
         "  win=", DoubleToString(bPnL,2), " lose=", DoubleToString(wPnL,2));
   return true;
}

//──────────────────────────────────────────────────────────────────
// STATE HANDLERS
//──────────────────────────────────────────────────────────────────

void HandleStartup()
{
   int dir = GetEMADirection();
   if(dir > 0)      // Bullish → LEAN BUY (3B + 1S)
   {
      OpenBuy("init"); OpenBuy("init"); OpenBuy("init");
      OpenSell("init");
      g_state = BS_LEAN_BUY;
      Print("Startup BULLISH → LEAN_BUY 3B+1S");
   }
   else if(dir < 0) // Bearish → LEAN SELL (1B + 3S)
   {
      OpenBuy("init");
      OpenSell("init"); OpenSell("init"); OpenSell("init");
      g_state = BS_LEAN_SELL;
      Print("Startup BEARISH → LEAN_SELL 1B+3S");
   }
   else             // Neutral → BALANCED (2B + 2S)
   {
      OpenBuy("init"); OpenBuy("init");
      OpenSell("init"); OpenSell("init");
      g_state = BS_BALANCED;
      Print("Startup NEUTRAL → BALANCED 2B+2S");
   }
}

//──────────────────────────────────────────────────────────────────
void HandleBalanced(double equity, double netPnL, double momentum)
{
   int    buys     = CountBuys();
   int    sells    = CountSells();
   double buyPnL   = SidePnL(POSITION_TYPE_BUY);
   double sellPnL  = SidePnL(POSITION_TYPE_SELL);
   bool   gateOpen = (netPnL > -(equity * InpGatePct / 100.0));

   // ── Trim excess (shouldn't happen, safety net) ─────────────────
   if(buys  > 2) TrimSide(POSITION_TYPE_BUY,  2);
   if(sells > 2) TrimSide(POSITION_TYPE_SELL, 2);

   // ── Reopen if SL hit (only when gate open) ─────────────────────
   if(gateOpen && buys  < 2 && TimeCurrent()-g_lastOpen >= 2) OpenBuy("bal_r");
   if(gateOpen && sells < 2 && TimeCurrent()-g_lastOpen >= 2) OpenSell("bal_r");

   // ── Pair close ─────────────────────────────────────────────────
   if(buyPnL >= sellPnL) // buys ahead or equal → pair close buy+sell
      TryPairClose(POSITION_TYPE_BUY, POSITION_TYPE_SELL, gateOpen);
   else
      TryPairClose(POSITION_TYPE_SELL, POSITION_TYPE_BUY, gateOpen);

   // ── Lean shift (only if cooldown elapsed) ──────────────────────
   if(TimeCurrent() - g_lastLean >= (datetime)InpLeanCooldown)
   {
      double wPnL;
      if(buyPnL - sellPnL >= InpLeanThresh)
      {
         // Close worst sell, open 1 more buy → 3B+1S
         WorstTicket(POSITION_TYPE_SELL, wPnL);
         if(wPnL >= -InpLeanMaxLoss && gateOpen)
         {
            ulong wTkt = WorstTicket(POSITION_TYPE_SELL, wPnL);
            if(g_trade.PositionClose(wTkt))
            {
               OpenBuy("lean");
               g_state   = BS_LEAN_BUY;
               g_lastLean = TimeCurrent();
               Print("BALANCED → LEAN_BUY  lead=", DoubleToString(buyPnL-sellPnL,2));
               return;
            }
         }
      }
      else if(sellPnL - buyPnL >= InpLeanThresh)
      {
         WorstTicket(POSITION_TYPE_BUY, wPnL);
         if(wPnL >= -InpLeanMaxLoss && gateOpen)
         {
            ulong wTkt = WorstTicket(POSITION_TYPE_BUY, wPnL);
            if(g_trade.PositionClose(wTkt))
            {
               OpenSell("lean");
               g_state   = BS_LEAN_SELL;
               g_lastLean = TimeCurrent();
               Print("BALANCED → LEAN_SELL  lead=", DoubleToString(sellPnL-buyPnL,2));
               return;
            }
         }
      }
   }

   // ── Sprint check ───────────────────────────────────────────────
   if(TimeCurrent() - g_lastSprint >= (datetime)InpSprintCool && gateOpen)
   {
      if(momentum >= InpSprintPts)
      {
         g_preSprintBuys  = CountBuys();   // 2
         g_preSprintSells = CountSells();  // 2
         OpenBuy("spr"); OpenBuy("spr");   // +2 → 4B+2S
         g_sprintStart = TimeCurrent();
         g_state       = BS_SPRINT_BUY;
         Print("BALANCED → SPRINT_BUY  momentum=", DoubleToString(momentum,0), "pts");
         return;
      }
      if(momentum <= -InpSprintPts)
      {
         g_preSprintBuys  = CountBuys();
         g_preSprintSells = CountSells();
         OpenSell("spr"); OpenSell("spr");
         g_sprintStart = TimeCurrent();
         g_state       = BS_SPRINT_SELL;
         Print("BALANCED → SPRINT_SELL  momentum=", DoubleToString(momentum,0), "pts");
         return;
      }
   }
}

//──────────────────────────────────────────────────────────────────
void HandleLeanBuy(double equity, double netPnL, double momentum)
{
   int    buys     = CountBuys();
   int    sells    = CountSells();
   double buyPnL   = SidePnL(POSITION_TYPE_BUY);
   double sellPnL  = SidePnL(POSITION_TYPE_SELL);
   bool   gateOpen = (netPnL > -(equity * InpGatePct / 100.0));

   // ── Trim excess ────────────────────────────────────────────────
   if(buys  > 3) TrimSide(POSITION_TYPE_BUY,  3);
   if(sells > 1) TrimSide(POSITION_TYPE_SELL, 1);

   // ── Reopen if SL hit ───────────────────────────────────────────
   if(gateOpen && buys  < 3 && TimeCurrent()-g_lastOpen >= 2) OpenBuy("lb_r");
   if(gateOpen && sells < 1 && TimeCurrent()-g_lastOpen >= 2) OpenSell("lb_r");

   // ── Single harvest (winner closed, replaced fresh same side) ───
   TryHarvest(POSITION_TYPE_BUY, gateOpen);

   // ── Pair close (best buy + worst sell → if net positive) ───────
   if(TryPairClose(POSITION_TYPE_BUY, POSITION_TYPE_SELL, gateOpen))
   {
      // After pair close: now 2B+0S → reopen to 3B+1S
      if(gateOpen) { OpenBuy("pc_r"); OpenSell("pc_r"); }
   }

   // ── Reverse: sells pulling ahead → back to BALANCED ────────────
   if(TimeCurrent() - g_lastLean >= (datetime)InpLeanCooldown &&
      sellPnL - buyPnL >= InpLeanThresh)
   {
      double wPnL; ulong wTkt = WorstTicket(POSITION_TYPE_BUY, wPnL);
      if(wPnL >= -InpLeanMaxLoss && g_trade.PositionClose(wTkt))
      {
         if(gateOpen) OpenSell("rev");
         g_state   = BS_BALANCED;
         g_lastLean = TimeCurrent();
         Print("LEAN_BUY → BALANCED (sells gaining)");
         return;
      }
   }

   // ── Sprint ─────────────────────────────────────────────────────
   if(TimeCurrent() - g_lastSprint >= (datetime)InpSprintCool &&
      gateOpen && momentum >= InpSprintPts)
   {
      g_preSprintBuys  = CountBuys();   // 3
      g_preSprintSells = CountSells();  // 1
      OpenBuy("spr");                    // +1 → 4B+1S
      g_sprintStart = TimeCurrent();
      g_state       = BS_SPRINT_BUY;
      Print("LEAN_BUY → SPRINT_BUY  momentum=", DoubleToString(momentum,0), "pts");
   }
}

//──────────────────────────────────────────────────────────────────
void HandleLeanSell(double equity, double netPnL, double momentum)
{
   int    buys     = CountBuys();
   int    sells    = CountSells();
   double buyPnL   = SidePnL(POSITION_TYPE_BUY);
   double sellPnL  = SidePnL(POSITION_TYPE_SELL);
   bool   gateOpen = (netPnL > -(equity * InpGatePct / 100.0));

   if(buys  > 1) TrimSide(POSITION_TYPE_BUY,  1);
   if(sells > 3) TrimSide(POSITION_TYPE_SELL, 3);

   if(gateOpen && buys  < 1 && TimeCurrent()-g_lastOpen >= 2) OpenBuy("ls_r");
   if(gateOpen && sells < 3 && TimeCurrent()-g_lastOpen >= 2) OpenSell("ls_r");

   TryHarvest(POSITION_TYPE_SELL, gateOpen);

   if(TryPairClose(POSITION_TYPE_SELL, POSITION_TYPE_BUY, gateOpen))
   {
      if(gateOpen) { OpenSell("pc_r"); OpenBuy("pc_r"); }
   }

   if(TimeCurrent() - g_lastLean >= (datetime)InpLeanCooldown &&
      buyPnL - sellPnL >= InpLeanThresh)
   {
      double wPnL; ulong wTkt = WorstTicket(POSITION_TYPE_SELL, wPnL);
      if(wPnL >= -InpLeanMaxLoss && g_trade.PositionClose(wTkt))
      {
         if(gateOpen) OpenBuy("rev");
         g_state   = BS_BALANCED;
         g_lastLean = TimeCurrent();
         Print("LEAN_SELL → BALANCED (buys gaining)");
         return;
      }
   }

   if(TimeCurrent() - g_lastSprint >= (datetime)InpSprintCool &&
      gateOpen && momentum <= -InpSprintPts)
   {
      g_preSprintBuys  = CountBuys();
      g_preSprintSells = CountSells();
      OpenSell("spr");
      g_sprintStart = TimeCurrent();
      g_state       = BS_SPRINT_SELL;
      Print("LEAN_SELL → SPRINT_SELL  momentum=", DoubleToString(momentum,0), "pts");
   }
}

//──────────────────────────────────────────────────────────────────
void HandleSprint(bool isBuySprint)
{
   ENUM_POSITION_TYPE sprintSide = isBuySprint ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   int  sprintCount = isBuySprint ? CountBuys() : CountSells();
   int  targetCount = 4;

   // Measure sprint P&L (only the extra positions added above pre-sprint count)
   // Simple approach: total side P&L (good enough for sprint decisions)
   double sprintPnL = SidePnL(sprintSide);

   bool timerDone  = (TimeCurrent() - g_sprintStart >= (datetime)InpSprintSecs);
   bool targetHit  = (sprintPnL >= InpSprintTarget);

   // ── Exit sprint ────────────────────────────────────────────────
   if(timerDone || targetHit)
   {
      // Trim back to pre-sprint count (close best-performing extra ones to lock profit)
      int preCount = isBuySprint ? g_preSprintBuys : g_preSprintSells;
      while((isBuySprint ? CountBuys() : CountSells()) > preCount)
      {
         double bPnL; ulong bTkt = BestTicket(sprintSide, bPnL);
         if(bTkt == 0 || !g_trade.PositionClose(bTkt)) break;
      }
      g_lastSprint = TimeCurrent();

      // Return to pre-sprint state
      if(g_preSprintBuys >= 3 || g_preSprintSells >= 3)
         g_state = isBuySprint ? BS_LEAN_BUY : BS_LEAN_SELL;
      else
         g_state = BS_BALANCED;

      Print("SPRINT EXIT (", timerDone?"timeout":"target", ")",
            "  P&L=", DoubleToString(sprintPnL,2),
            "  → ", g_state==BS_LEAN_BUY?"LEAN_BUY" : g_state==BS_LEAN_SELL?"LEAN_SELL":"BALANCED");
      return;
   }

   // Keep sprint at 4 on the sprint side (in case SL hit one)
   // Only refill if we're not close to exit
   if(sprintCount < targetCount && TimeCurrent()-g_lastOpen >= 2)
   {
      if(isBuySprint) OpenBuy("spr_r");
      else             OpenSell("spr_r");
   }
}

//──────────────────────────────────────────────────────────────────
// PANEL
//──────────────────────────────────────────────────────────────────
void DrawPanel(double equity, double netPnL, double momentum)
{
   string stateStr;
   switch(g_state)
   {
      case BS_STARTUP:     stateStr = "STARTUP";         break;
      case BS_BALANCED:    stateStr = "BALANCED 2B+2S";  break;
      case BS_LEAN_BUY:    stateStr = "LEAN BUY 3B+1S";  break;
      case BS_LEAN_SELL:   stateStr = "LEAN SELL 1B+3S"; break;
      case BS_SPRINT_BUY:  stateStr = StringFormat("SPRINT BUY 4B  %ds left",
                              InpSprintSecs-(int)(TimeCurrent()-g_sprintStart)); break;
      case BS_SPRINT_SELL: stateStr = StringFormat("SPRINT SELL 4S  %ds left",
                              InpSprintSecs-(int)(TimeCurrent()-g_sprintStart)); break;
      default: stateStr = "?";
   }
   bool gate = (netPnL <= -(equity * InpGatePct / 100.0));

   Comment(StringFormat(
      "═══ HedgeScalper v3.00 ═══\n"
      "Symbol  : %s\n"
      "State   : %s\n"
      "Gate    : %s\n"
      "──────────────────────────\n"
      "Equity  : %.2f\n"
      "Net P&L : %+.2f  (%+.2f%%)\n"
      "Buys    : %d pos  P&L %+.2f\n"
      "Sells   : %d pos  P&L %+.2f\n"
      "──────────────────────────\n"
      "Momentum: %+.0f pts  (sprint ±%d)\n"
      "Emerg SL: -%s%%  = -%.2f",
      _Symbol, stateStr,
      gate ? "PAUSED (equity recovering)" : "OPEN",
      equity,
      netPnL, equity>0 ? netPnL/equity*100.0 : 0,
      CountBuys(),  SidePnL(POSITION_TYPE_BUY),
      CountSells(), SidePnL(POSITION_TYPE_SELL),
      momentum, InpSprintPts,
      DoubleToString(InpEmergPct,1), equity*InpEmergPct/100.0
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

   g_emaH = iMA(_Symbol, InpEMATF, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaH == INVALID_HANDLE) { Print("EMA init failed"); return INIT_FAILED; }
   ArraySetAsSeries(g_emaBuf, true);

   Print("HedgeScalper v3.00 — lot=", InpLot, "  SL=", InpSLPoints, "pts (silent)");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_emaH != INVALID_HANDLE) IndicatorRelease(g_emaH);
   Comment("");
}

void OnTick()
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double netPnL  = TotalPnL();
   double momentum = GetMomentum();
   if(equity <= 0) return;

   DrawPanel(equity, netPnL, momentum);

   // ── Emergency SL (silent, always on) ───────────────────────────
   if(TotalCount() > 0 && netPnL <= -(equity * InpEmergPct / 100.0))
   {
      CloseAll(StringFormat("Emergency: %.2f <= -%.1f%%", netPnL, InpEmergPct));
      g_state      = BS_STARTUP;
      g_lastClose  = TimeCurrent();
      return;
   }

   // ── All positions gone → restart ───────────────────────────────
   if(g_state != BS_STARTUP && TotalCount() == 0)
   {
      Print("All positions cleared — restarting");
      g_state     = BS_STARTUP;
      g_lastClose = TimeCurrent();
   }

   // ── Startup restart delay ───────────────────────────────────────
   if(g_state == BS_STARTUP)
   {
      if(!InpRestart && g_lastClose > 0) return;
      if(TimeCurrent() - g_lastClose < (datetime)InpRestartDelay) return;
      HandleStartup();
      return;
   }

   // ── State machine ───────────────────────────────────────────────
   switch(g_state)
   {
      case BS_BALANCED:    HandleBalanced(equity, netPnL, momentum);  break;
      case BS_LEAN_BUY:    HandleLeanBuy(equity, netPnL, momentum);   break;
      case BS_LEAN_SELL:   HandleLeanSell(equity, netPnL, momentum);  break;
      case BS_SPRINT_BUY:  HandleSprint(true);                         break;
      case BS_SPRINT_SELL: HandleSprint(false);                        break;
   }
}
//+------------------------------------------------------------------+
