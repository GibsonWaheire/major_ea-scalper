//+------------------------------------------------------------------+
//|  HedgeScalper_v4.mq5  v4.00  — Pure Math Basket Hedge           |
//|                                                                   |
//|  CONCEPT                                                         |
//|  No indicators. No candle signals. Pure math.                   |
//|                                                                   |
//|  Run N buys + N sells simultaneously at all times.              |
//|  The hedge means one side covers the other.                     |
//|  The ONLY metric that matters: BASKET TOTAL P&L.               |
//|                                                                   |
//|  TRIGGER                                                         |
//|  When basket net P&L >= broker_cost + profit_target:           |
//|    → Close all profitable positions (winners)                   |
//|    → Replace them instantly in the same direction               |
//|    → Losing positions stay open as the running hedge            |
//|    → Basket continues uninterrupted                             |
//|                                                                   |
//|  BROKER COST MODEL (the only enemy)                             |
//|  trigger = spread_cost_all_positions                            |
//|           + commission_all_positions                            |
//|           + InpProfitTarget                                     |
//|  Every harvest is mathematically guaranteed profitable.         |
//|                                                                   |
//|  SCALE UP                                                        |
//|  After InpScaleAfterCycles successful harvests, basket grows    |
//|  by 1 buy + 1 sell. Compounds profits automatically.           |
//|                                                                   |
//|  SL: InpSLPoints per trade. Silent backstop only.              |
//|  Refilled instantly if hit.                                     |
//+------------------------------------------------------------------+
#property copyright "HedgeScalper v4"
#property link      ""
#property version   "4.00"
#property description "Pure math basket hedge — basket P&L trigger, broker-cost aware, no indicators"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//──────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────

input group "=== Basket Setup ==="
input int    InpBuys          = 2;      // Initial buy positions
input int    InpSells         = 2;      // Initial sell positions
input double InpLot           = 0.05;   // Fixed lot — same for every position
input long   InpMagic         = 990011;
input int    InpSlippage      = 30;
input int    InpSLPoints      = 200;    // SL per trade (silent backstop — not in logic)

input group "=== Broker Cost (The Only Enemy) ==="
input double InpCommPerLot    = 3.50;   // Your broker commission per lot per side (USD)
                                         // Zero commission brokers: set 0

input group "=== Profit Target ==="
input double InpProfitTarget  = 3.00;   // Harvest when basket net P&L > broker_cost + this (USD)

input group "=== Scale Up (Compound) ==="
input bool   InpScaleUp       = true;   // Grow basket after successful harvests
input int    InpScaleAfter    = 5;      // Add 1B+1S after every N harvests
input int    InpMaxBasketSize = 5;      // Max positions per side (cap at this)

input group "=== Emergency ==="
input double InpEmergencyLoss = 25.0;   // Close ALL if basket P&L <= -X USD
input int    InpRestartDelay  = 15;     // Seconds before reopening after emergency

//──────────────────────────────────────────────────────────────────
// GLOBALS
//──────────────────────────────────────────────────────────────────

CTrade        g_trade;
CPositionInfo g_pos;

bool     g_active       = false;
int      g_harvestCount = 0;      // Total successful harvests
int      g_curBuys      = 0;      // Current basket buy target (grows with scale)
int      g_curSells     = 0;      // Current basket sell target
datetime g_lastClose    = 0;
datetime g_lastOpen     = 0;

//──────────────────────────────────────────────────────────────────
// POSITION HELPERS
//──────────────────────────────────────────────────────────────────

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

//──────────────────────────────────────────────────────────────────
// BROKER COST
//──────────────────────────────────────────────────────────────────

// Spread cost in USD to open one position at current spread
double SpreadCostUSD(double lot)
{
   double spread  = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSz <= 0) return 0;
   return (spread / tickSz) * tickVal * lot;
}

// Total round-trip broker cost for ALL currently open positions
// (spread to open + spread to close + commission both sides)
double TotalBrokerCost()
{
   int    n    = TotalCount();
   double sprd = SpreadCostUSD(InpLot) * 2.0;          // open + close spread
   double comm = InpCommPerLot * InpLot * 2.0;          // open + close commission
   return (sprd + comm) * n;
}

//──────────────────────────────────────────────────────────────────
// ORDER HELPERS
//──────────────────────────────────────────────────────────────────

double NormLot()
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return MathMax(mn, MathMin(mx, MathRound(InpLot/st)*st));
}

bool OpenBuy(string lbl)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl  = NormalizeDouble(ask - InpSLPoints * _Point, _Digits);
   bool   ok  = g_trade.Buy(NormLot(), _Symbol, ask, sl, 0, "HS:"+lbl);
   if(ok) g_lastOpen = TimeCurrent();
   return ok;
}

bool OpenSell(string lbl)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = NormalizeDouble(bid + InpSLPoints * _Point, _Digits);
   bool   ok  = g_trade.Sell(NormLot(), _Symbol, bid, sl, 0, "HS:"+lbl);
   if(ok) g_lastOpen = TimeCurrent();
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
// BASKET OPEN & MAINTAIN
//──────────────────────────────────────────────────────────────────

void OpenBasket()
{
   g_curBuys  = InpBuys;
   g_curSells = InpSells;
   for(int i = 0; i < g_curBuys;  i++) OpenBuy("basket");
   for(int i = 0; i < g_curSells; i++) OpenSell("basket");
   g_active = true;
   Print("Basket opened: ", g_curBuys, "B + ", g_curSells, "S");
}

// Instantly refill any positions lost to SL — basket never goes empty
void MaintainBasket()
{
   int buys  = CountSide(POSITION_TYPE_BUY);
   int sells = CountSide(POSITION_TYPE_SELL);
   // Refill with 1 second gap per open to avoid flooding
   if(buys  < g_curBuys  && TimeCurrent()-g_lastOpen >= 1) OpenBuy("refill");
   if(sells < g_curSells && TimeCurrent()-g_lastOpen >= 1) OpenSell("refill");
}

//──────────────────────────────────────────────────────────────────
// THE CORE HARVEST
//──────────────────────────────────────────────────────────────────

void HarvestAndReplace()
{
   int closedBuys = 0, closedSells = 0;

   // Close every position that is currently in profit
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol()!=_Symbol || g_pos.Magic()!=(ulong)InpMagic) continue;
      double pnl = g_pos.Profit() + g_pos.Swap();
      if(pnl > 0)
      {
         if(g_pos.PositionType()==POSITION_TYPE_BUY)  closedBuys++;
         else                                           closedSells++;
         g_trade.PositionClose(g_pos.Ticket());
      }
   }

   if(closedBuys + closedSells == 0) return; // nothing to harvest

   // Replace instantly — same direction, same lot
   for(int i = 0; i < closedBuys;  i++) OpenBuy("replace");
   for(int i = 0; i < closedSells; i++) OpenSell("replace");

   g_harvestCount++;
   Print("HARVEST #", g_harvestCount,
         "  closed ", closedBuys, "B + ", closedSells, "S → replaced",
         "  total harvests=", g_harvestCount);

   // Scale up basket after N harvests
   if(InpScaleUp && g_harvestCount > 0 && g_harvestCount % InpScaleAfter == 0)
   {
      if(g_curBuys  < InpMaxBasketSize) { g_curBuys++;  OpenBuy("scale");  }
      if(g_curSells < InpMaxBasketSize) { g_curSells++; OpenSell("scale"); }
      Print("SCALE UP → basket now ", g_curBuys, "B + ", g_curSells, "S");
   }
}

//──────────────────────────────────────────────────────────────────
// PANEL
//──────────────────────────────────────────────────────────────────

void DrawPanel(double netPnL, double brokerCost, double trigger, double equity)
{
   double gap     = trigger - netPnL;
   string status  = (netPnL >= trigger) ? ">>> HARVEST FIRING <<<" :
                    StringFormat("need +%.2f more", gap);

   Comment(StringFormat(
      "═══ HedgeScalper v4.00 ═══\n"
      "Symbol   : %s\n"
      "Basket   : %s   harvests: %d\n"
      "Size     : %dB + %dS  (max %d)\n"
      "─────────────────────────\n"
      "Net P&L  : %+.2f\n"
      "─────────────────────────\n"
      "Broker   : %.2f  (spread+comm)\n"
      "Target   : +%.2f\n"
      "Trigger  : %.2f  —  %s\n"
      "─────────────────────────\n"
      "Buys     : %d pos   %+.2f\n"
      "Sells    : %d pos   %+.2f\n"
      "─────────────────────────\n"
      "Emerg SL : -%.2f\n"
      "Equity   : %.2f",
      _Symbol,
      g_active ? "RUNNING" : "IDLE", g_harvestCount,
      g_curBuys, g_curSells, InpMaxBasketSize,
      netPnL,
      brokerCost, InpProfitTarget, trigger, status,
      CountSide(POSITION_TYPE_BUY),  SidePnL(POSITION_TYPE_BUY),
      CountSide(POSITION_TYPE_SELL), SidePnL(POSITION_TYPE_SELL),
      InpEmergencyLoss, equity
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
   Print("HedgeScalper v4.00 — ", _Symbol,
         "  lot=", InpLot,
         "  SL=", InpSLPoints, "pts (silent)",
         "  comm/lot=", InpCommPerLot);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { Comment(""); }

void OnTick()
{
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double netPnL     = TotalPnL();
   double brokerCost = TotalBrokerCost();
   double trigger    = brokerCost + InpProfitTarget;   // the ONLY number that matters

   DrawPanel(netPnL, brokerCost, trigger, equity);

   // ── Emergency ──────────────────────────────────────────────────
   if(g_active && netPnL <= -InpEmergencyLoss)
   {
      CloseAll(StringFormat("Emergency: %.2f <= -%.2f", netPnL, InpEmergencyLoss));
      g_active        = false;
      g_harvestCount  = 0;
      g_curBuys       = InpBuys;
      g_curSells      = InpSells;
      g_lastClose     = TimeCurrent();
      return;
   }

   // ── All positions gone externally ──────────────────────────────
   if(g_active && TotalCount() == 0)
   {
      Print("Basket cleared externally — restarting");
      g_active    = false;
      g_lastClose = TimeCurrent();
   }

   // ── Start basket ───────────────────────────────────────────────
   if(!g_active)
   {
      if(TimeCurrent() - g_lastClose < (datetime)InpRestartDelay) return;
      OpenBasket();
      return;
   }

   // ── Maintain basket (instant refill of any SL hits) ────────────
   MaintainBasket();

   // ── THE ONLY TRIGGER: basket net >= broker cost + target ───────
   if(netPnL >= trigger)
      HarvestAndReplace();
}
//+------------------------------------------------------------------+
