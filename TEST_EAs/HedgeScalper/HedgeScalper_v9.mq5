//+------------------------------------------------------------------+
//|  HedgeScalper_v8.mq5  v8.00  — Directional Stack Scalper       |
//|                                                                   |
//|  PHASE 1 — STACK:                                               |
//|    Stochastic signal → stack up to 4 positions in that dir     |
//|    All running same direction → accumulate together             |
//|    e.g. 4 sells all going → total $30-40 built up              |
//|                                                                   |
//|  PHASE 2 — TRANSITION HEDGE:                                    |
//|    Signal flips → open opposite direction (new signal dir)     |
//|    Opposite positions profit from the move                      |
//|    Their profit covers the original stack losses                |
//|    Net basket >= 0 → close ALL → bank net profit               |
//|                                                                   |
//|  PHASE 3 — HARVEST / LOSS CUT:                                 |
//|    Basket net >= InpHarvestTarget → close all, restart         |
//|    Equity drop >= InpMaxDrop ($20) → close all, restart       |
//|                                                                   |
//|  KEY DIFFERENCE FROM v6:                                        |
//|    Not a permanent hedge. Starts PURELY DIRECTIONAL.           |
//|    Hedge only exists during signal transitions.                 |
//|    Once net positive → exit clean, restart fresh.              |
//+------------------------------------------------------------------+
#property copyright "HedgeScalper v8"
#property link      ""
#property version   "8.00"
#property description "Directional stack scalper — holds to $30 harvest, no micro exits"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//──────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────

input group "=== Stack ==="
input double InpLot          = 0.05;   // Lot per position
input int    InpMaxStack     = 4;      // Max positions per direction
input long   InpMagic        = 990014;
input int    InpSlippage     = 50;

input group "=== Timing ==="
input int    InpOpenGapSec   = 5;      // Min seconds between opens
input int    InpRestartDelay = 5;      // Seconds after harvest before restart

input group "=== Exit ==="
input double InpHarvestTarget = 30.0; // Close all when basket net >= this ($)
input double InpMaxDrop       = 20.0; // Close all when basket equity drops this much ($)

input group "=== Risk ==="
input double InpMaxSpreadPips = 20.0;
input int    InpSLPoints      = 2000;  // Spike-protection SL per position (pts). 0=off.

input group "=== Stochastic Signal ==="
input int    InpStochK        = 5;
input int    InpStochD        = 3;
input int    InpStochSlowing  = 3;
input double InpStochBuyLvl   = 60.0; // K > this → BUY signal
input double InpStochSellLvl  = 40.0; // K < this → SELL signal

//──────────────────────────────────────────────────────────────────
// GLOBALS
//──────────────────────────────────────────────────────────────────

CTrade        g_trade;
CPositionInfo g_pos;

int      g_stochHandle       = INVALID_HANDLE;

bool     g_active            = false;  // basket is open
bool     g_transition        = false;  // signal has flipped, opening opposite
ENUM_POSITION_TYPE g_stackDir = POSITION_TYPE_BUY; // original stack direction

datetime g_lastOpen          = 0;
datetime g_lastHarvest       = 0;
double   g_basketEquityStart = 0;      // equity at basket open (for drop guard)
double   g_sessionLocked     = 0;      // sum of all harvested P&L
int      g_harvests          = 0;
int      g_tradeEvents       = 0;

//──────────────────────────────────────────────────────────────────
// HELPERS
//──────────────────────────────────────────────────────────────────

double NormLot()
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return MathMax(mn, MathMin(mx, MathRound(InpLot/st)*st));
}

bool SpreadOK()
{
   double pipPt = (_Digits % 2 == 1) ? _Point * 10.0 : _Point;
   return ((SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
            SymbolInfoDouble(_Symbol, SYMBOL_BID)) / pipPt <= InpMaxSpreadPips);
}

int CountSide(ENUM_POSITION_TYPE type)
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic && g_pos.PositionType()==type)
         n++;
   return n;
}

int TotalCount()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol && g_pos.Magic()==(ulong)InpMagic)
         n++;
   return n;
}

double TotalPnL()
{
   double t = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol && g_pos.Magic()==(ulong)InpMagic)
         t += g_pos.Profit() + g_pos.Swap();
   return t;
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

bool OpenBuy(string lbl)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl  = (InpSLPoints > 0) ? NormalizeDouble(ask - InpSLPoints*_Point, _Digits) : 0;
   bool   ok  = g_trade.Buy(NormLot(), _Symbol, ask, sl, 0, "HS8:"+lbl);
   if(ok) { g_lastOpen = TimeCurrent(); g_tradeEvents++; }
   return ok;
}

bool OpenSell(string lbl)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = (InpSLPoints > 0) ? NormalizeDouble(bid + InpSLPoints*_Point, _Digits) : 0;
   bool   ok  = g_trade.Sell(NormLot(), _Symbol, bid, sl, 0, "HS8:"+lbl);
   if(ok) { g_lastOpen = TimeCurrent(); g_tradeEvents++; }
   return ok;
}

bool OpenInDir(ENUM_POSITION_TYPE dir, string lbl)
{
   return (dir == POSITION_TYPE_BUY) ? OpenBuy(lbl) : OpenSell(lbl);
}

void CloseAll(string reason)
{
   double net = TotalPnL();
   Print("CloseAll [", reason, "]  net=", DoubleToString(net, 2),
         "  session=", DoubleToString(g_sessionLocked + net, 2));
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol && g_pos.Magic()==(ulong)InpMagic)
         g_trade.PositionClose(g_pos.Ticket());
   g_sessionLocked     += net;
   g_harvests++;
   g_active             = false;
   g_transition         = false;
   g_lastHarvest        = TimeCurrent();
   g_tradeEvents        = 0;
   g_basketEquityStart  = 0;
}

//──────────────────────────────────────────────────────────────────
// SIGNAL — Stochastic K
//──────────────────────────────────────────────────────────────────

// Returns 1=BUY, -1=SELL, 0=NEUTRAL
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

void DrawPanel(double floating, double equity, double stochK, int signal,
               double basketDrop)
{
   int buys  = CountSide(POSITION_TYPE_BUY);
   int sells = CountSide(POSITION_TYPE_SELL);
   int stackCnt = (g_stackDir == POSITION_TYPE_BUY) ? buys : sells;
   int transCnt = (g_stackDir == POSITION_TYPE_BUY) ? sells : buys;

   string phaseTxt;
   if(!g_active)           phaseTxt = "IDLE — waiting for signal";
   else if(g_transition)   phaseTxt = "TRANSITION HEDGE — netting out";
   else                    phaseTxt = "STACKING — building position";

   string dirTxt    = (g_stackDir == POSITION_TYPE_BUY) ? "BUY" : "SELL";
   string signalTxt = (signal == 1) ? "↑ BUY" : (signal == -1) ? "↓ SELL" : "— neutral";

   Comment(StringFormat(
      "═══ HedgeScalper v8.00 ═══\n"
      "Phase       : %s\n"
      "Stack dir   : %s  (%d pos)\n"
      "Trans dir   : %s  (%d pos)\n"
      "Stoch K     : %.1f  [%s]\n"
      "────────────────────────────\n"
      "Basket net  : %+.2f\n"
      "  Buys (%d) : %+.2f\n"
      "  Sells(%d) : %+.2f\n"
      "────────────────────────────\n"
      "Equity drop : -%.2f  limit: -%.2f\n"
      "Harvest tgt : +%.2f\n"
      "────────────────────────────\n"
      "Session P&L : %+.2f\n"
      "Harvests    : %d  Events: %d\n"
      "Equity      : %.2f",
      phaseTxt,
      dirTxt, stackCnt,
      (g_stackDir == POSITION_TYPE_BUY) ? "SELL" : "BUY", transCnt,
      stochK, signalTxt,
      floating,
      buys,  SidePnL(POSITION_TYPE_BUY),
      sells, SidePnL(POSITION_TYPE_SELL),
      basketDrop, InpMaxDrop,
      InpHarvestTarget,
      g_sessionLocked + floating,
      g_harvests, g_tradeEvents,
      equity
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

   g_stochHandle = iStochastic(_Symbol, PERIOD_M1, InpStochK, InpStochD, InpStochSlowing,
                                MODE_SMA, STO_LOWHIGH);
   if(g_stochHandle == INVALID_HANDLE)
      Print("Warning: Stochastic handle failed");

   if(TotalCount() > 0)
   {
      g_active            = true;
      g_basketEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
      Print("Resumed: ", TotalCount(), " existing positions");
   }

   Print("HedgeScalper v8.00 — ", _Symbol,
         "  lot=", InpLot,
         "  maxStack=", InpMaxStack,
         "  harvest=+", InpHarvestTarget,
         "  maxDrop=-", InpMaxDrop);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_stochHandle != INVALID_HANDLE) IndicatorRelease(g_stochHandle);
   Comment("");
}

void OnTick()
{
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double floating = TotalPnL();
   int    total    = TotalCount();

   double stochK = 50.0;
   int    signal = GetSignal(stochK);

   double basketDrop = (g_basketEquityStart > 0) ? g_basketEquityStart - equity : 0;

   DrawPanel(floating, equity, stochK, signal, basketDrop);

   // ── IDLE: wait for signal, start fresh basket ────────────────
   if(!g_active)
   {
      if(TimeCurrent() - g_lastHarvest < (datetime)InpRestartDelay) return;
      if(!SpreadOK()) return;
      if(signal == 0) return; // wait for direction

      g_stackDir          = (signal == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      g_transition        = false;
      g_basketEquityStart = equity;

      if(OpenInDir(g_stackDir, "stack"))
      {
         g_active = true;
         Print("NEW BASKET: ", g_stackDir == POSITION_TYPE_BUY ? "BUY" : "SELL",
               "  K=", DoubleToString(stochK, 1),
               "  equity=", DoubleToString(equity, 2));
      }
      return;
   }

   // ── All positions closed externally ─────────────────────────
   if(total == 0)
   {
      g_active     = false;
      g_transition = false;
      Print("All positions gone — resetting");
      return;
   }

   // ── EQUITY GUARD — absolute priority ────────────────────────
   // Basket has lost too much — exit immediately, cut the loss
   if(basketDrop >= InpMaxDrop)
   {
      Print("EQUITY GUARD: drop=-", DoubleToString(basketDrop, 2),
            " >= -", InpMaxDrop, "  closing all");
      CloseAll("EquityGuard");
      return;
   }

   // ── HARVEST — basket reached profit target ───────────────────
   if(floating >= InpHarvestTarget)
   {
      Print("HARVEST: net=+", DoubleToString(floating, 2),
            " >= +", InpHarvestTarget);
      CloseAll("Harvest");
      return;
   }

   // ── TRANSITION NET EXIT ──────────────────────────────────────
   // In transition with both sides open: wait for full harvest target
   // No micro exits — hold until the basket earns InpHarvestTarget
   if(g_transition)
   {
      int buys  = CountSide(POSITION_TYPE_BUY);
      int sells = CountSide(POSITION_TYPE_SELL);
      if(buys > 0 && sells > 0 && floating >= InpHarvestTarget)
      {
         Print("TRANSITION NET EXIT: net=", DoubleToString(floating, 2),
               "  buys=", buys, "  sells=", sells);
         CloseAll("TransitionExit");
         return;
      }
   }

   // ── SIGNAL PROCESSING ────────────────────────────────────────
   if(TimeCurrent() - g_lastOpen < (datetime)InpOpenGapSec) return;
   if(!SpreadOK()) return;

   ENUM_POSITION_TYPE transDir = (g_stackDir == POSITION_TYPE_BUY) ?
                                  POSITION_TYPE_SELL : POSITION_TYPE_BUY;

   if(!g_transition)
   {
      // ── STACKING PHASE ───────────────────────────────────────
      if(signal == 1 && g_stackDir == POSITION_TYPE_BUY)
      {
         // Signal agrees — add more buys
         if(CountSide(POSITION_TYPE_BUY) < InpMaxStack)
         {
            OpenBuy("stack");
            Print("STACK BUY #", CountSide(POSITION_TYPE_BUY),
                  "  K=", DoubleToString(stochK, 1));
         }
      }
      else if(signal == -1 && g_stackDir == POSITION_TYPE_SELL)
      {
         // Signal agrees — add more sells
         if(CountSide(POSITION_TYPE_SELL) < InpMaxStack)
         {
            OpenSell("stack");
            Print("STACK SELL #", CountSide(POSITION_TYPE_SELL),
                  "  K=", DoubleToString(stochK, 1));
         }
      }
      else if(signal != 0)
      {
         // Signal flipped → switch to transition phase
         // g_stackDir stays as the original (losing) direction
         // We start opening in the NEW signal direction to cover losses
         g_transition = true;
         Print("SIGNAL FLIP → TRANSITION  old=",
               g_stackDir == POSITION_TYPE_BUY ? "BUY" : "SELL",
               "  new=", signal == 1 ? "BUY" : "SELL",
               "  K=", DoubleToString(stochK, 1),
               "  stackPnL=", DoubleToString(
               SidePnL(g_stackDir), 2));

         // Open first counter position immediately
         if(CountSide(transDir) < InpMaxStack)
            OpenInDir(transDir, "trans");
      }
      // signal == 0: neutral, hold stack, wait
   }
   else
   {
      // ── TRANSITION PHASE ─────────────────────────────────────
      // Keep opening in counter direction as long as signal holds
      // Counter positions profit → cover original stack losses → net exit

      ENUM_POSITION_TYPE curSignalDir = (signal == 1) ? POSITION_TYPE_BUY :
                                        (signal == -1) ? POSITION_TYPE_SELL :
                                        (ENUM_POSITION_TYPE)-1;

      if(signal == 0)
      {
         // Signal went neutral during transition — hold, wait for net to resolve
         return;
      }

      if(curSignalDir == transDir)
      {
         // Signal still pointing at counter direction — keep adding
         if(CountSide(transDir) < InpMaxStack)
         {
            OpenInDir(transDir, "trans");
            Print("TRANSITION+: ", transDir == POSITION_TYPE_BUY ? "BUY" : "SELL",
                  " #", CountSide(transDir),
                  "  K=", DoubleToString(stochK, 1),
                  "  basketNet=", DoubleToString(floating, 2));
         }
      }
      else
      {
         // Signal flipped BACK to original stack direction
         // Original stack may be recovering — re-enter stacking phase
         // Update stack direction to match current signal
         g_stackDir   = curSignalDir;
         g_transition = false;
         Print("SIGNAL FLIP BACK → STACKING: ",
               g_stackDir == POSITION_TYPE_BUY ? "BUY" : "SELL",
               "  K=", DoubleToString(stochK, 1));
         if(CountSide(g_stackDir) < InpMaxStack)
            OpenInDir(g_stackDir, "stack");
      }
   }
}
//+------------------------------------------------------------------+
