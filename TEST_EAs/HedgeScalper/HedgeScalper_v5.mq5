//+------------------------------------------------------------------+
//|  HedgeScalper_v5.mq5  v5.00  — Cumulative Sequence Harvester   |
//|                                                                   |
//|  ONE METRIC: Session P&L = locked closed P&L + floating P&L    |
//|                                                                   |
//|  Positions open STAGGERED (InpOpenGapSec apart) so each trade  |
//|  enters at a different price — not zero-sum.                    |
//|                                                                   |
//|  TWO HARVEST MODES                                              |
//|  Big  (sessionPnL >= InpBigHarvest)                            |
//|    → close ALL positions, bank full session, restart fresh      |
//|                                                                   |
//|  Small (sessionPnL >= InpSmallHarvest)                         |
//|    → strategic partial close:                                   |
//|       sort positions best-to-worst P&L                          |
//|       walk down the list, add to close set while net > 0       |
//|       this naturally absorbs losers when winners cover them     |
//|       keep InpMinKeep positions running for next harvest        |
//|    → MaintainBasket() refills gradually (staggered gaps)       |
//|                                                                   |
//|  No SL. No emergency. Just accumulative harvesting.            |
//+------------------------------------------------------------------+
#property copyright "HedgeScalper v5"
#property link      ""
#property version   "5.00"
#property description "Cumulative sequence harvester — session P&L trigger, strategic partial close"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//──────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────

input group "=== Basket ==="
input int    InpBuys          = 2;      // Initial buy positions
input int    InpSells         = 2;      // Initial sell positions
input double InpLot           = 0.05;   // Lot size per position
input long   InpMagic         = 990013;
input int    InpSlippage      = 30;

input group "=== Entry Stagger ==="
input int    InpOpenGapSec    = 5;      // Seconds between each open (different entry prices)

input group "=== Harvest Thresholds ==="
input double InpBigHarvest    = 10.0;   // Session P&L >= this → close ALL, bank, restart
input double InpSmallHarvest  = 2.0;    // Session P&L >= this → strategic partial close
                                         // Session P&L = all locked closes + all floating

input group "=== Basket Management ==="
input int    InpMinKeep       = 2;      // Min positions to keep after partial close
input bool   InpScaleUp       = true;   // Grow basket target after big harvests
input int    InpScaleAfter    = 3;      // Big harvests between each scale step
input int    InpMaxPerSide    = 5;      // Max positions per side (scale cap)

input group "=== Restart ==="
input int    InpRestartDelay  = 10;     // Seconds after big harvest before reopening

//──────────────────────────────────────────────────────────────────
// STRUCTS
//──────────────────────────────────────────────────────────────────

struct PosRecord
{
   ulong              ticket;
   double             pnl;
   ENUM_POSITION_TYPE type;
};

//──────────────────────────────────────────────────────────────────
// GLOBALS
//──────────────────────────────────────────────────────────────────

CTrade        g_trade;
CPositionInfo g_pos;

bool     g_active         = false;
double   g_sessionClosed  = 0.0;   // Locked P&L from closes this session
int      g_bigHarvests    = 0;     // Lifetime big harvest count
int      g_tradeEvents    = 0;     // Opens + closes this session
int      g_curBuys        = 0;     // Current basket buy target (scales up)
int      g_curSells       = 0;     // Current basket sell target
datetime g_lastOpen       = 0;     // Time of last position open (stagger control)
datetime g_lastBigHarvest = 0;     // Time of last big harvest (restart delay)
int      g_lastScaleAt    = 0;     // g_bigHarvests value at last scale event
bool     g_lastWasBuy     = false; // Alternating direction tracker for minimum fills

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

double TotalFloatingPnL()
{
   double t = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol && g_pos.Magic()==(ulong)InpMagic)
         t += g_pos.Profit() + g_pos.Swap();
   return t;
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
   bool   ok  = g_trade.Buy(NormLot(), _Symbol, ask, 0, 0, "HS5:"+lbl);
   if(ok) { g_lastOpen = TimeCurrent(); g_lastWasBuy = true; g_tradeEvents++; }
   return ok;
}

bool OpenSell(string lbl)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool   ok  = g_trade.Sell(NormLot(), _Symbol, bid, 0, 0, "HS5:"+lbl);
   if(ok) { g_lastOpen = TimeCurrent(); g_lastWasBuy = false; g_tradeEvents++; }
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

// Opens the first position only. MaintainBasket() fills the rest
// with InpOpenGapSec gaps — each at a different price level.
void OpenBasket()
{
   OpenBuy("init");
   g_active = true;
   Print("Basket started — target ", g_curBuys, "B + ", g_curSells,
         "S  stagger=", InpOpenGapSec, "s  bigHarvests=", g_bigHarvests);
}

// Fills basket one position per gap. Largest deficit side goes first.
// Also keeps basket alive above InpMinKeep with alternating opens.
void MaintainBasket()
{
   if(TimeCurrent() - g_lastOpen < (datetime)InpOpenGapSec) return;

   int buys  = CountSide(POSITION_TYPE_BUY);
   int sells = CountSide(POSITION_TYPE_SELL);
   int total = buys + sells;

   int buyDef  = g_curBuys  - buys;
   int sellDef = g_curSells - sells;

   if(buyDef > 0 && buyDef >= sellDef) { OpenBuy("fill");  return; }
   if(sellDef > 0)                     { OpenSell("fill"); return; }

   // Below minimum — keep basket alive with alternating direction
   if(total < InpMinKeep)
   {
      if(!g_lastWasBuy) OpenBuy("min");
      else              OpenSell("min");
   }
}

//──────────────────────────────────────────────────────────────────
// POSITION ARRAY — build and sort descending by P&L
//──────────────────────────────────────────────────────────────────

int BuildSortedPositions(PosRecord &arr[])
{
   int n = 0;
   ArrayResize(arr, PositionsTotal());
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol()!=_Symbol || g_pos.Magic()!=(ulong)InpMagic) continue;
      arr[n].ticket = g_pos.Ticket();
      arr[n].pnl    = g_pos.Profit() + g_pos.Swap();
      arr[n].type   = g_pos.PositionType();
      n++;
   }
   ArrayResize(arr, n);
   for(int i = 0; i < n-1; i++)
      for(int j = 0; j < n-i-1; j++)
         if(arr[j].pnl < arr[j+1].pnl)
         {
            PosRecord tmp = arr[j]; arr[j] = arr[j+1]; arr[j+1] = tmp;
         }
   return n;
}

//──────────────────────────────────────────────────────────────────
// BIG HARVEST — close all, bank session, restart
//──────────────────────────────────────────────────────────────────

void DoBigHarvest(double sessionPnL)
{
   Print(">>> BIG HARVEST #", g_bigHarvests+1,
         "  sessionPnL=+", DoubleToString(sessionPnL, 2),
         "  events=", g_tradeEvents);
   CloseAll("BigHarvest");
   g_bigHarvests++;
   g_sessionClosed  = 0.0;
   g_tradeEvents    = 0;
   g_active         = false;
   g_lastBigHarvest = TimeCurrent();

   if(InpScaleUp && g_bigHarvests % InpScaleAfter == 0 && g_bigHarvests != g_lastScaleAt)
   {
      g_lastScaleAt = g_bigHarvests;
      if(g_curBuys  < InpMaxPerSide) g_curBuys++;
      if(g_curSells < InpMaxPerSide) g_curSells++;
      Print("SCALE UP → next basket: ", g_curBuys, "B + ", g_curSells, "S");
   }
}

//──────────────────────────────────────────────────────────────────
// STRATEGIC PARTIAL CLOSE
//──────────────────────────────────────────────────────────────────
//
//  Sort all positions by P&L descending.
//  Walk the list: add position to close set while running net > 0.
//  Cap at (total - InpMinKeep) positions so runners stay open.
//
//  Example — positions sorted: [+$5, +$2, -$1, -$6]
//  InpMinKeep=2 → can close up to 2:
//    +$5 → net=$5 ✓
//    +$2 → net=$7 ✓  (close 2, lock $7, leave -$1 and -$6 running)
//
//  Example — [+$5, -$1, -$4, -$8], InpMinKeep=2 → can close up to 2:
//    +$5 → net=$5 ✓
//    -$1 → net=$4 ✓  (loser absorbed by winner, close both, lock $4)
//
//  Result: net profit locked, losing positions only closed when
//  winners cover them, basket shrinks minimally.
//──────────────────────────────────────────────────────────────────

void DoStrategicClose()
{
   PosRecord arr[];
   int n = BuildSortedPositions(arr);
   if(n == 0) return;

   int maxClose = n - InpMinKeep;
   if(maxClose <= 0) return;

   ulong  tickets[];
   int    count      = 0;
   double runningNet = 0;
   ArrayResize(tickets, maxClose);

   for(int i = 0; i < maxClose; i++)
   {
      double candidate = runningNet + arr[i].pnl;
      if(candidate > 0)
      {
         tickets[count++] = arr[i].ticket;
         runningNet = candidate;
      }
      // position would drag net <= 0 — leave it running
   }

   if(count == 0 || runningNet <= 0) return;

   int closed = 0;
   for(int i = 0; i < count; i++)
      if(g_trade.PositionClose(tickets[i]))
         closed++;

   g_tradeEvents   += closed;
   g_sessionClosed += runningNet;

   Print("Partial close: ", closed, " pos  locked=+", DoubleToString(runningNet, 2),
         "  sessionLocked=+", DoubleToString(g_sessionClosed, 2));
}

//──────────────────────────────────────────────────────────────────
// PANEL
//──────────────────────────────────────────────────────────────────

void DrawPanel(double sessionPnL, double floating, double equity)
{
   int buys  = CountSide(POSITION_TYPE_BUY);
   int sells = CountSide(POSITION_TYPE_SELL);
   int total = buys + sells;
   int target = g_curBuys + g_curSells;

   string status;
   if(sessionPnL >= InpBigHarvest)
      status = ">>> BIG HARVEST FIRING <<<";
   else if(sessionPnL >= InpSmallHarvest)
      status = ">> PARTIAL CLOSE FIRING <<";
   else
      status = StringFormat("need +%.2f for partial", InpSmallHarvest - sessionPnL);

   string buildNote = (total < target)
      ? StringFormat(" [building %d/%d]", total, target) : "";

   Comment(StringFormat(
      "═══ HedgeScalper v5.00 ═══\n"
      "Symbol       : %s\n"
      "Basket       : %s%s   bigH: %d\n"
      "Target       : %dB + %dS  (max %d/side)\n"
      "────────────────────────────\n"
      "Session P&L  : %+.2f  ← THE number\n"
      "  locked     : %+.2f  (closed trades)\n"
      "  floating   : %+.2f  (open trades)\n"
      "────────────────────────────\n"
      "Buys         : %d pos  %+.2f\n"
      "Sells        : %d pos  %+.2f\n"
      "────────────────────────────\n"
      "Status       : %s\n"
      "Events       : %d  this session\n"
      "────────────────────────────\n"
      "Stagger      : %ds   MinKeep: %d\n"
      "BigH target  : +%.2f     SmH: +%.2f\n"
      "Equity       : %.2f",
      _Symbol,
      g_active ? "RUNNING" : "IDLE", buildNote, g_bigHarvests,
      g_curBuys, g_curSells, InpMaxPerSide,
      sessionPnL,
      g_sessionClosed,
      floating,
      buys,  SidePnL(POSITION_TYPE_BUY),
      sells, SidePnL(POSITION_TYPE_SELL),
      status, g_tradeEvents,
      InpOpenGapSec, InpMinKeep,
      InpBigHarvest, InpSmallHarvest,
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

   g_curBuys  = InpBuys;
   g_curSells = InpSells;

   // Detect existing positions from a previous session
   if(TotalCount() > 0)
   {
      g_active = true;
      Print("Resumed: found ", TotalCount(), " existing positions");
   }

   Print("HedgeScalper v5.00 — ", _Symbol,
         "  lot=", InpLot,
         "  stagger=", InpOpenGapSec, "s",
         "  bigH=+", InpBigHarvest, "  smallH=+", InpSmallHarvest,
         "  minKeep=", InpMinKeep);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { Comment(""); }

void OnTick()
{
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double floating   = TotalFloatingPnL();
   double sessionPnL = g_sessionClosed + floating;

   DrawPanel(sessionPnL, floating, equity);

   // ── Not active: open basket after restart delay ─────────────────
   if(!g_active)
   {
      if(TimeCurrent() - g_lastBigHarvest >= (datetime)InpRestartDelay)
         OpenBasket();
      return;
   }

   // ── External close: all positions gone without big harvest ──────
   if(TotalCount() == 0)
   {
      Print("All positions gone externally — treating as session reset");
      g_sessionClosed = 0;
      g_tradeEvents   = 0;
      g_active        = false;
      g_lastBigHarvest = TimeCurrent();
      return;
   }

   // ── Big harvest ─────────────────────────────────────────────────
   if(sessionPnL >= InpBigHarvest)
   {
      DoBigHarvest(sessionPnL);
      return;
   }

   // ── Strategic partial close ─────────────────────────────────────
   if(sessionPnL >= InpSmallHarvest)
      DoStrategicClose();

   // ── Maintain basket (staggered fills, one per gap) ──────────────
   MaintainBasket();
}
//+------------------------------------------------------------------+
