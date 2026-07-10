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
input int    InpBuys          = 1;      // Initial buy positions (momentum sets real ratio fast)
input int    InpSells         = 2;      // Initial sell positions — 1:2=3 (odd) is a good start
input double InpLot           = 0.05;   // Lot size per position
input long   InpMagic         = 990013;
input int    InpSlippage      = 50;

input group "=== Entry Stagger ==="
input int    InpOpenGapSec    = 5;      // Seconds between each open (different entry prices)

input group "=== Harvest Thresholds ==="
input double InpBigHarvest    = 10.0;   // Session P&L >= this → close ALL, bank, restart
input double InpSmallHarvest  = 2.0;    // Session P&L >= this → strategic partial close
                                         // Session P&L = all locked closes + all floating

input group "=== Basket Management ==="
input int    InpMinKeep       = 3;      // Min positions to keep alive in basket (must be odd)
input int    InpMinKeepClose  = 1;      // Min to keep during group close (1 = winner anchor stays)
input int    InpCloseGapSec   = 5;      // Cooldown seconds between group closes
input int    InpMaxBasket     = 5;      // Hard cap: max total positions in basket (keep odd e.g. 5)
input bool   InpScaleUp       = true;   // Grow basket target after big harvests
input int    InpScaleAfter    = 3;      // Big harvests between each scale step
input int    InpMaxPerSide    = 3;      // Max positions per side (scale cap, 3+2=5 total)

input group "=== Restart ==="
input int    InpRestartDelay  = 10;     // Seconds after big harvest before reopening

input group "=== Risk Guards ==="
input double InpMaxSpreadPips   = 20.0;  // Max spread in pips — pause opens/trims above this
input double InpDailyLossPct    = 50.0;  // Max daily equity loss as % of day-start balance — halt for day
input double InpTrailFactor     = 0.5;   // Trailing harvest: threshold = max(InpSmallHarvest, peak * factor)

input group "=== Stuck Loser Recovery ==="
input double InpStuckThreshold = 3.0;   // USD loss before a position is classified stuck
input double InpDilutionPct    = 30.0;  // % improvement from worst P&L before opening recovery trade
input int    InpRecoveryGapSec = 10;    // Seconds between recovery trade #1 and hedge
input double InpBreakevenTol   = 0.50;  // Close all if recovery group net >= -this value

input group "=== Stuck Loop Escape ==="
input int    InpStuckLoopSec = 180;   // Seconds no group close (3+ trades) → find any net+ group, remaining stay open

input group "=== Direction Skew ==="
input int    InpSkewCheckSec = 30;      // Window (seconds) for both signals
input double InpTickBias     = 1.3;     // Tick ratio needed for momentum signal (30% more = 1.3)
input int    InpSkewStrong   = 3;       // Positions on high-conviction side
input int    InpSkewWeak     = 2;       // Positions on low-conviction side — 3:2=5 (odd)
input int    InpSkewFlat     = 0;       // Positions on losing side (both signals agree)

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

int      g_upTicks       = 0;     // Up-ticks in current window
int      g_downTicks     = 0;     // Down-ticks in current window
double   g_lastBid       = 0;     // Previous bid for tick direction
datetime g_lastSkewCheck = 0;     // Time of last skew evaluation

double   g_peakSessionPnL  = 0;      // Highest session P&L seen this session (trailing harvest)
double   g_dayStartBalance = 0;      // Account balance at start of current day
datetime g_currentDay      = 0;      // Current trading day (for daily loss reset)
bool     g_haltedForDay    = false;  // True when daily loss limit hit — halt until next day
datetime g_lastClose       = 0;      // Time of last group close (cooldown control)

bool     g_recoveryMode  = false;   // True when a stuck loser is being managed
ulong    g_stuckTicket   = 0;       // Ticket of the stuck loser
double   g_stuckPeakLoss = 0;       // Most negative P&L seen on stuck (dilution reference)
int      g_recoveryPhase = 0;       // 0=watching, 1=same-dir open, 2=hedge open
datetime g_recoveryOpen  = 0;       // Time last recovery trade was opened
datetime g_lastStuckScan = 0;       // Throttle stuck scan to once per minute

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

// True when current spread is within acceptable range
bool SpreadOK()
{
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pipPt   = (_Digits % 2 == 1) ? _Point * 10.0 : _Point;
   double spread  = (ask - bid) / pipPt;
   return (spread <= InpMaxSpreadPips);
}

// True once both sides have live positions — required before going flat (4:0)
bool IsBasketBuilt()
{
   return (CountSide(POSITION_TYPE_BUY)  >= 1 &&
           CountSide(POSITION_TYPE_SELL) >= 1 &&
           TotalCount() >= InpMinKeep);
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
   if(TotalCount() >= InpMaxBasket) { g_active = true; return; } // existing trades fill the cap
   OpenBuy("init");
   g_active = true;
   Print("Basket started — target ", g_curBuys, "B + ", g_curSells,
         "S  stagger=", InpOpenGapSec, "s  bigHarvests=", g_bigHarvests);
}

// Fills basket one position per gap. Largest deficit side goes first.
// Also keeps basket alive above InpMinKeep with alternating opens.
void MaintainBasket()
{
   if(!SpreadOK()) return;  // spread too wide — pause all opens
   if(TimeCurrent() - g_lastOpen < (datetime)InpOpenGapSec) return;

   int buys  = CountSide(POSITION_TYPE_BUY);
   int sells = CountSide(POSITION_TYPE_SELL);
   int total = buys + sells;

   // Hard cap — never open if already at InpMaxBasket
   if(total >= InpMaxBasket) return;

   int buyDef  = g_curBuys  - buys;
   int sellDef = g_curSells - sells;

   if(buyDef > 0 && buyDef >= sellDef) { OpenBuy("fill");  return; }
   if(sellDef > 0)                     { OpenSell("fill"); return; }

   // Below minimum — keep basket alive with alternating direction
   if(total < InpMinKeep)
   {
      if(!g_lastWasBuy) OpenBuy("min");
      else              OpenSell("min");
      return;
   }

   // Odd enforcer: if total is even with no pending fills, open 1 more on majority side
   if(total > 0 && total % 2 == 0)
   {
      if(buys >= sells) OpenBuy("odd-fix");
      else              OpenSell("odd-fix");
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

   // Reset skew + trailing harvest peak — fresh start after harvest
   g_curBuys        = InpBuys;
   g_curSells       = InpSells;
   g_upTicks        = 0;
   g_downTicks      = 0;
   g_lastSkewCheck  = 0;
   g_lastClose      = 0;
   g_peakSessionPnL = 0;
   g_recoveryMode   = false;
   g_stuckTicket    = 0;
   g_recoveryPhase  = 0;
   g_stuckPeakLoss  = 0;

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

// Group close: walk positions best → worst, include any position (winner OR loser)
// as long as running net stays positive.
//
// DIRECTION RULE (per user requirement):
//   Normal case  → close set MUST contain both buys AND sells (net cross-direction close)
//   Exception A  → 3+ positions all same direction may be closed together
//
// RECOVERY MODE: still runs, but the stuck ticket is excluded from candidates.
//   The stuck trade is left alone to recover. All other trades (including
//   recovery trades) continue to group-close normally to counter the stuck side.
//   ManageRecovery() handles the stuck+recovery-group breakeven separately.
//
// This prevents closing individual profitable trades in isolation.
void DoStrategicClose(double minLock)
{
   PosRecord arr[];
   int n = BuildSortedPositions(arr); // sorted best → worst (descending P&L)

   // In recovery mode: only exclude stuck ticket if it's still LOSING.
   // If it has recovered to profit, let it participate in group close normally.
   if(g_recoveryMode && g_stuckTicket > 0 &&
      g_pos.SelectByTicket(g_stuckTicket) && g_pos.Profit() + g_pos.Swap() < 0)
   {
      PosRecord filtered[];
      ArrayResize(filtered, n);
      int fn = 0;
      for(int i = 0; i < n; i++)
         if(arr[i].ticket != g_stuckTicket)
            filtered[fn++] = arr[i];
      ArrayResize(arr, fn);
      for(int i = 0; i < fn; i++) arr[i] = filtered[i];
      n = fn;
   }

   if(n < 2) return;

   int canClose = n - InpMinKeepClose;
   if(canClose <= 0) return;

   // Enforce odd remaining: adjust canClose so (n - canClose) is odd
   if((n - canClose) % 2 == 0)
   {
      canClose--;
      if(canClose <= 0) return;
   }

   // Phase 1 — build close group: walk all, include if running net stays positive
   PosRecord closeSet[];
   ArrayResize(closeSet, canClose);
   int    setSize    = 0;
   double runningNet = 0;

   for(int i = 0; i < n && setSize < canClose; i++)
   {
      double candidate = runningNet + arr[i].pnl;
      if(candidate > 0) // winner absorbs any losers — running net must stay positive
      {
         closeSet[setSize++] = arr[i];
         runningNet = candidate;
      }
   }

   // Only close if the COMBINED net is meaningful — never for peanuts
   if(setSize == 0 || runningNet < minLock) return;

   // Phase 2 — parity fix (remaining must be odd)
   if((n - setSize) % 2 == 0 && setSize > 1)
   {
      setSize--;
      runningNet -= closeSet[setSize].pnl;
   }

   if(setSize == 0 || runningNet <= 0) return;

   // Phase 3 — DIRECTION RULE: require mixed directions unless 3+ same-direction
   int buysInSet  = 0;
   int sellsInSet = 0;
   for(int i = 0; i < setSize; i++)
   {
      if(closeSet[i].type == POSITION_TYPE_BUY) buysInSet++;
      else                                        sellsInSet++;
   }

   bool mixedDirections = (buysInSet > 0 && sellsInSet > 0);
   bool sameDir3Plus    = (!mixedDirections && setSize >= 3);

   if(!mixedDirections && !sameDir3Plus)
   {
      // Would close only 1-2 profitable trades in one direction — not allowed
      return;
   }

   // Phase 4 — execute closes
   int closed = 0;
   for(int i = 0; i < setSize; i++)
      if(g_trade.PositionClose(closeSet[i].ticket))
         closed++;

   g_tradeEvents   += closed;
   g_sessionClosed += runningNet;
   g_lastClose      = TimeCurrent();  // start cooldown
   g_lastSkewCheck  = 0;              // force immediate direction re-eval next tick

   Print("Group close: ", closed, " pos  buys=", buysInSet, " sells=", sellsInSet,
         "  locked=+", DoubleToString(runningNet, 2),
         "  sessionLocked=+", DoubleToString(g_sessionClosed, 2),
         "  remaining=", n - closed);
}

//──────────────────────────────────────────────────────────────────
// STUCK LOSER RECOVERY
//──────────────────────────────────────────────────────────────────


// Sum P&L of stuck position + all recovery trades (tagged HS5:rec)
double RecoveryGroupNet()
{
   double t = 0;
   if(g_stuckTicket > 0 && g_pos.SelectByTicket(g_stuckTicket))
      t += g_pos.Profit() + g_pos.Swap();
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
         g_pos.Magic()==(ulong)InpMagic &&
         StringFind(g_pos.Comment(), "HS5:rec") >= 0)
         t += g_pos.Profit() + g_pos.Swap();
   return t;
}

// Scan for a stuck loser once per minute — activates recovery mode
void ScanForStuckLoser()
{
   if(g_recoveryMode) return;
   if(TimeCurrent() - g_lastStuckScan < 60) return;
   g_lastStuckScan = TimeCurrent();

   ulong  worstTicket  = 0;
   double worstPnL     = 0;
   double totalWinPnL  = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol()!=_Symbol || g_pos.Magic()!=(ulong)InpMagic) continue;
      if(StringFind(g_pos.Comment(), "HS5:rec") >= 0) continue; // skip recovery trades

      double pnl = g_pos.Profit() + g_pos.Swap();
      if(pnl > 0) totalWinPnL += pnl;
      if(pnl < worstPnL) { worstPnL = pnl; worstTicket = g_pos.Ticket(); }
   }

   // Stuck when: worst loser exceeds threshold AND total winners can't absorb it
   if(worstTicket > 0 && worstPnL < -InpStuckThreshold && totalWinPnL < MathAbs(worstPnL))
   {
      if(!g_pos.SelectByTicket(worstTicket)) return;
      g_stuckTicket   = worstTicket;
      g_stuckPeakLoss = worstPnL;
      g_recoveryMode  = true;
      g_recoveryPhase = 0;
      g_recoveryOpen  = 0;
      Print("Recovery mode ON: stuck #", g_stuckTicket,
            "  P&L=", DoubleToString(worstPnL, 2),
            "  totalWins=", DoubleToString(totalWinPnL, 2));
   }
}

// Main recovery manager — called every tick when g_recoveryMode is true
void ManageRecovery()
{
   // ── Check if stuck position still exists ────────────────────────
   if(!g_pos.SelectByTicket(g_stuckTicket))
   {
      Print("Recovery: stuck #", g_stuckTicket, " closed (external) — exiting recovery, normal flow resumes");
      g_recoveryMode  = false;
      g_stuckTicket   = 0;
      g_recoveryPhase = 0;
      g_stuckPeakLoss = 0;
      g_lastSkewCheck = 0;
      return;
   }

   double stuckPnL              = g_pos.Profit() + g_pos.Swap();
   ENUM_POSITION_TYPE stuckType = g_pos.PositionType();

   // Track worst (peak loss deepens)
   if(stuckPnL < g_stuckPeakLoss) g_stuckPeakLoss = stuckPnL;

   // ── Breakeven check (once recovery trades are open) ─────────────
   if(g_recoveryPhase >= 1)
   {
      double groupNet = RecoveryGroupNet();
      if(groupNet >= -InpBreakevenTol)
      {
         Print("Recovery: breakeven  net=", DoubleToString(groupNet, 2), " → closing all");
         g_trade.PositionClose(g_stuckTicket);
         for(int i = PositionsTotal()-1; i >= 0; i--)
            if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
               g_pos.Magic()==(ulong)InpMagic &&
               StringFind(g_pos.Comment(), "HS5:rec") >= 0)
               g_trade.PositionClose(g_pos.Ticket());
         g_recoveryMode  = false;
         g_stuckTicket   = 0;
         g_recoveryPhase = 0;
         g_stuckPeakLoss = 0;
         return;
      }
      // Recovery trades that turn profitable are handled by normal DoStrategicClose —
      // no explicit action needed here, normal group close picks them up.
   }

   // ── Phase 0: watch for dilution ──────────────────────────────────
   if(g_recoveryPhase == 0)
   {
      // Stuck trade recovered to profit on its own — release it back to normal group close
      if(stuckPnL > 0)
      {
         Print("Recovery: stuck #", g_stuckTicket, " recovered to profit (", DoubleToString(stuckPnL, 2),
               ") — exiting recovery, normal group close takes over");
         g_recoveryMode  = false;
         g_stuckTicket   = 0;
         g_stuckPeakLoss = 0;
         g_recoveryPhase = 0;
         g_lastSkewCheck = 0; // force direction re-eval
         return;
      }

      if(g_stuckPeakLoss >= 0) return; // no peak recorded yet
      double improvement = (stuckPnL - g_stuckPeakLoss) / MathAbs(g_stuckPeakLoss);
      if(improvement >= InpDilutionPct / 100.0 && SpreadOK() && TotalCount() < InpMaxBasket)
      {
         // Price moving in stuck loser's favour → open same-direction trade
         bool ok = (stuckType==POSITION_TYPE_BUY) ? OpenBuy("rec") : OpenSell("rec");
         if(ok)
         {
            g_recoveryPhase = 1;
            g_recoveryOpen  = TimeCurrent();
            Print("Recovery: dilution ", DoubleToString(improvement*100.0, 0),
                  "% → opened same-dir trade  phase=1");
         }
      }
      return;
   }

   // ── Phase 1: same-dir open — wait then open hedge ────────────────
   if(g_recoveryPhase == 1 &&
      TimeCurrent() - g_recoveryOpen >= (datetime)InpRecoveryGapSec &&
      SpreadOK() && TotalCount() < InpMaxBasket)
   {
      bool ok = (stuckType==POSITION_TYPE_BUY) ? OpenSell("rec-hedge") : OpenBuy("rec-hedge");
      if(ok)
      {
         g_recoveryPhase = 2;
         Print("Recovery: hedge trade opened  phase=2  groupNet=",
               DoubleToString(RecoveryGroupNet(), 2));
      }
   }
}

//──────────────────────────────────────────────────────────────────
// PANEL
//──────────────────────────────────────────────────────────────────

void DrawPanel(double sessionPnL, double floating, double equity,
               double dailyPnL, double smallHarvestNow)
{
   int buys   = CountSide(POSITION_TYPE_BUY);
   int sells  = CountSide(POSITION_TYPE_SELL);
   int total  = buys + sells;
   int target = g_curBuys + g_curSells;

   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pipPt  = (_Digits % 2 == 1) ? _Point * 10.0 : _Point;
   double spread = (ask - bid) / pipPt;

   string status;
   if(g_haltedForDay)
      status = "!!! HALTED — daily loss limit !!!";
   else if(sessionPnL >= InpBigHarvest)
      status = ">>> BIG HARVEST FIRING <<<";
   else if(sessionPnL >= smallHarvestNow)
      status = ">> GROUP CLOSE FIRING <<";
   else if(!SpreadOK())
      status = StringFormat("SPREAD BLOCK (%.1f pips)", spread);
   else
      status = StringFormat("need +%.2f for group close", smallHarvestNow - sessionPnL);

   string buildNote = (total < target)
      ? StringFormat(" [building %d/%d]", total, target) : "";

   Comment(StringFormat(
      "═══ HedgeScalper v5.00 ═══\n"
      "Symbol       : %s   Spread: %.1f pip%s\n"
      "Basket       : %s%s   bigH: %d\n"
      "Target       : %dB + %dS  (max basket: %d)\n"
      "────────────────────────────\n"
      "Session P&L  : %+.2f  ← THE number\n"
      "  locked     : %+.2f  (closed trades)\n"
      "  floating   : %+.2f  (open trades)\n"
      "  peak       : %+.2f  (trailing ref)\n"
      "────────────────────────────\n"
      "Buys         : %d pos  %+.2f\n"
      "Sells        : %d pos  %+.2f\n"
      "────────────────────────────\n"
      "Status       : %s\n"
      "Events       : %d  this session\n"
      "────────────────────────────\n"
      "Daily P&L    : %+.2f  limit: -%.0f%% (%.2f)\n"
      "GroupClose   : +%.2f (trail factor %.0f%%)\n"
      "BigH target  : +%.2f\n"
      "Recovery     : %s\n"
      "Equity       : %.2f",
      _Symbol, spread, SpreadOK() ? "" : " !!",
      g_active ? "RUNNING" : "IDLE", buildNote, g_bigHarvests,
      g_curBuys, g_curSells, InpMaxBasket,
      sessionPnL, g_sessionClosed, floating, g_peakSessionPnL,
      buys,  SidePnL(POSITION_TYPE_BUY),
      sells, SidePnL(POSITION_TYPE_SELL),
      status, g_tradeEvents,
      dailyPnL, InpDailyLossPct, g_dayStartBalance * InpDailyLossPct / 100.0,
      smallHarvestNow, InpTrailFactor * 100,
      InpBigHarvest,
      g_recoveryMode
         ? StringFormat("ACTIVE phase=%d  stuck=%.2f  peak=%.2f  grpNet=%.2f",
                        g_recoveryPhase,
                        g_stuckTicket>0 && g_pos.SelectByTicket(g_stuckTicket)
                           ? g_pos.Profit()+g_pos.Swap() : 0,
                        g_stuckPeakLoss, RecoveryGroupNet())
         : "OFF",
      equity
   ));
}

//──────────────────────────────────────────────────────────────────
// TRIM SURPLUS — close one excess position per tick on the weak side
//──────────────────────────────────────────────────────────────────

void TrimSurplus()
{
   int buys  = CountSide(POSITION_TYPE_BUY);
   int sells = CountSide(POSITION_TYPE_SELL);
   int total = buys + sells;

   // ── Hard cap: basket over InpMaxBasket — close worst P&L position immediately ──
   if(total > InpMaxBasket)
   {
      ulong  worstTicket = 0;
      double worstPnL    = DBL_MAX;
      for(int i = PositionsTotal()-1; i >= 0; i--)
         if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol && g_pos.Magic()==(ulong)InpMagic)
         {
            double pnl = g_pos.Profit() + g_pos.Swap();
            if(pnl < worstPnL) { worstPnL = pnl; worstTicket = g_pos.Ticket(); }
         }
      if(worstTicket > 0)
      {
         g_trade.PositionClose(worstTicket);
         Print("Cap trim: total=", total, " > max=", InpMaxBasket,
               "  closed worst P&L=", DoubleToString(worstPnL, 2));
      }
      return;
   }

   // ── Side surplus — only when basket profitable AND spread normal ──
   double sessionPnL = g_sessionClosed + TotalFloatingPnL();
   if(sessionPnL <= 0 || !SpreadOK()) return;
   if(buys > g_curBuys)
   {
      for(int i = PositionsTotal()-1; i >= 0; i--)
         if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
            g_pos.Magic()==(ulong)InpMagic &&
            g_pos.PositionType()==POSITION_TYPE_BUY)
         {
            g_trade.PositionClose(g_pos.Ticket());
            break; // one per tick — stagger removals
         }
      return;
   }

   if(sells > g_curSells)
   {
      for(int i = PositionsTotal()-1; i >= 0; i--)
         if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol &&
            g_pos.Magic()==(ulong)InpMagic &&
            g_pos.PositionType()==POSITION_TYPE_SELL)
         {
            g_trade.PositionClose(g_pos.Ticket());
            break;
         }
   }
}

//──────────────────────────────────────────────────────────────────
// EVALUATE SKEW — two-signal conviction (tick momentum + P&L float)
//──────────────────────────────────────────────────────────────────
//
//  Every tick: count up/down ticks for momentum signal.
//  Every InpSkewCheckSec: score both signals and set targets.
//
//  buyScore  = (upTicks > downTicks * InpTickBias) + (buyPnL > sellPnL)
//  sellScore = (downTicks > upTicks * InpTickBias) + (sellPnL > buyPnL)
//
//  Score 2 (both agree) → strong:flat  e.g. 3:0
//  Score 1 (one agrees) → strong:weak  e.g. 3:1
//  Tied/neutral          → rebalance back to InpBuys:InpSells
//──────────────────────────────────────────────────────────────────

void EvaluateSkew()
{
   if(!g_active) return;

   // ── Count tick direction every tick ─────────────────────────────
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_lastBid > 0)
   {
      if(bid > g_lastBid) g_upTicks++;
      if(bid < g_lastBid) g_downTicks++;
   }
   g_lastBid = bid;

   // ── Only re-evaluate targets when window expires ─────────────────
   if(TimeCurrent() - g_lastSkewCheck < (datetime)InpSkewCheckSec) return;
   g_lastSkewCheck = TimeCurrent();

   double buyPnL   = SidePnL(POSITION_TYPE_BUY);
   double sellPnL  = SidePnL(POSITION_TYPE_SELL);
   bool   tickBuy  = (g_upTicks   > g_downTicks * InpTickBias);
   bool   tickSell = (g_downTicks > g_upTicks   * InpTickBias);
   bool   pnlBuy   = (buyPnL  > sellPnL);
   bool   pnlSell  = (sellPnL > buyPnL);

   int buyScore  = (tickBuy  ? 1 : 0) + (pnlBuy  ? 1 : 0);
   int sellScore = (tickSell ? 1 : 0) + (pnlSell ? 1 : 0);

   int    prevBuys    = g_curBuys, prevSells = g_curSells;
   bool   canGoFlat   = IsBasketBuilt(); // only flatten one side once hedge is established
   double sessionPnL  = g_sessionClosed + TotalFloatingPnL();

   if(buyScore > sellScore)
   {
      g_curBuys  = MathMin(InpSkewStrong, InpMaxPerSide);
      g_curSells = (buyScore == 2 && canGoFlat) ? InpSkewFlat : InpSkewWeak;
   }
   else if(sellScore > buyScore)
   {
      g_curSells = MathMin(InpSkewStrong, InpMaxPerSide);
      g_curBuys  = (sellScore == 2 && canGoFlat) ? InpSkewFlat : InpSkewWeak;
   }
   else // tied or neutral
   {
      // Only rebalance to InpBuys:InpSells when basket is profitable.
      // If underwater, hold the current skew — never flatten when losing.
      if(sessionPnL > 0)
      {
         g_curBuys  = InpBuys;
         g_curSells = InpSells;
      }
      // else: hold g_curBuys / g_curSells unchanged
   }

   // ── Cap total to InpMaxBasket ────────────────────────────────────
   while(g_curBuys + g_curSells > InpMaxBasket)
   {
      // reduce the weaker (smaller) side first
      if(g_curSells > 0 && g_curSells <= g_curBuys) g_curSells--;
      else if(g_curBuys > 0)                         g_curBuys--;
      else break;
   }

   // ── Enforce odd total (even count = no directional edge) ─────────
   if((g_curBuys + g_curSells) % 2 == 0 && (g_curBuys + g_curSells) < InpMaxBasket)
   {
      // add 1 to the stronger side
      if(g_curBuys >= g_curSells) g_curBuys++;
      else                         g_curSells++;
   }

   Print("Skew | ticks=", g_upTicks, "↑/", g_downTicks, "↓",
         "  buyPnL=",  DoubleToString(buyPnL,  2),
         "  sellPnL=", DoubleToString(sellPnL, 2),
         "  scores=", buyScore, "B/", sellScore, "S",
         "  → ", g_curBuys, "B:", g_curSells, "S",
         (g_curBuys!=prevBuys || g_curSells!=prevSells) ? " [CHANGED]" : "");

   g_upTicks   = 0; // reset window
   g_downTicks = 0;
}

//──────────────────────────────────────────────────────────────────
// STUCK LOOP ESCAPE
//──────────────────────────────────────────────────────────────────
//
//  Fires when 3+ trades are open and no group close has happened
//  for InpStuckLoopSec seconds — meaning the basket is circling
//  with winners that can't push through the normal threshold.
//
//  Action at InpStuckLoopSec:
//    Find any net-positive group (direction rule OFF, threshold = $0.01)
//    Close it, lock whatever small profit exists.
//    Remaining losers stay open — rejoin normal group close flow.
//
void StuckLoopClose()
{
   if(TotalCount() < 3) return; // basket still building — not stuck yet

   // Reference: last close time, or last open if no close has happened yet
   datetime ref     = (g_lastClose > 0) ? g_lastClose : g_lastOpen;
   datetime elapsed = TimeCurrent() - ref;
   if(elapsed < (datetime)InpStuckLoopSec) return;

   PosRecord arr[];
   int n = BuildSortedPositions(arr); // sorted best → worst
   if(n < 2) return;

   // ── Find any net-positive group — direction rule OFF, threshold = $0.01 ──
   // This is the same logic as DoStrategicClose but with no direction restriction
   // and minimum threshold. Take whatever nets positive, lock it.
   int    canClose   = n - InpMinKeepClose;
   if(canClose <= 0) return;
   if((n - canClose) % 2 == 0) { canClose--; if(canClose <= 0) return; }

   PosRecord closeSet[];
   ArrayResize(closeSet, canClose);
   int    setSize    = 0;
   double runningNet = 0;

   for(int i = 0; i < n && setSize < canClose; i++)
   {
      double candidate = runningNet + arr[i].pnl;
      if(candidate > 0)
      {
         closeSet[setSize++] = arr[i];
         runningNet = candidate;
      }
   }

   // ── No net-positive group found — wait, let normal flow continue ──
   if(setSize == 0 || runningNet <= 0)
   {
      Print("StuckLoop: no net+ group found — waiting for reversal");
      return;
   }

   // Parity fix (remaining must be odd)
   if((n - setSize) % 2 == 0 && setSize > 1)
   {
      setSize--;
      runningNet -= closeSet[setSize].pnl;
   }
   if(setSize == 0 || runningNet <= 0) return;

   // ── Close the net-positive group ─────────────────────────────────
   int closed = 0;
   for(int i = 0; i < setSize; i++)
      if(g_trade.PositionClose(closeSet[i].ticket))
         closed++;

   g_tradeEvents   += closed;
   g_sessionClosed += runningNet;
   g_lastClose      = TimeCurrent();
   g_lastSkewCheck  = 0;

   Print("StuckLoop close: ", closed, " pos  locked=+", DoubleToString(runningNet, 2),
         "  remaining=", n - closed);

   // Exit recovery mode — stuck loop handled it, remaining positions rejoin normal flow
   if(g_recoveryMode)
   {
      g_recoveryMode  = false;
      g_stuckTicket   = 0;
      g_recoveryPhase = 0;
      g_stuckPeakLoss = 0;
   }
}


//──────────────────────────────────────────────────────────────────
// INIT / DEINIT / TICK
//──────────────────────────────────────────────────────────────────

int OnInit()
{
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_curBuys        = InpBuys;
   g_curSells       = InpSells;
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_currentDay      = (datetime)(TimeCurrent() - TimeCurrent() % 86400);

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
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double floating   = TotalFloatingPnL();
   double sessionPnL = g_sessionClosed + floating;

   // ── Daily reset & loss limit ─────────────────────────────────────
   datetime today = (datetime)(TimeCurrent() - TimeCurrent() % 86400);
   if(today != g_currentDay)
   {
      g_currentDay      = today;
      g_dayStartBalance = balance;
      g_haltedForDay    = false;
      g_peakSessionPnL  = 0;
      Print("New day — balance reset: ", DoubleToString(balance, 2));
   }
   double dailyPnL = equity - g_dayStartBalance;
   double dailyLossThreshold = g_dayStartBalance * InpDailyLossPct / 100.0;
   if(!g_haltedForDay && dailyPnL <= -dailyLossThreshold)
   {
      Print("!!! Daily loss limit hit (", DoubleToString(dailyPnL, 2),
            ") — halting for the day");
      CloseAll("DailyLossLimit");
      g_active       = false;
      g_haltedForDay = true;
   }

   // ── Trailing harvest threshold ───────────────────────────────────
   // Auto-scale minimum lock by lot size: $2 base at 0.05 lot → $40 at 1.0 lot
   double lotScale        = MathMax(1.0, NormLot() / 0.05);
   if(sessionPnL > g_peakSessionPnL) g_peakSessionPnL = sessionPnL;
   double smallHarvestNow = MathMax(InpSmallHarvest * lotScale,
                                    g_peakSessionPnL * InpTrailFactor);

   DrawPanel(sessionPnL, floating, equity, dailyPnL, smallHarvestNow);

   // ── Halted for the day — nothing more ───────────────────────────
   if(g_haltedForDay) return;

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
      g_sessionClosed  = 0;
      g_tradeEvents    = 0;
      g_peakSessionPnL = 0;
      g_active         = false;
      g_lastBigHarvest = TimeCurrent();
      return;
   }

   // ── Big harvest ─────────────────────────────────────────────────
   if(sessionPnL >= InpBigHarvest)
   {
      DoBigHarvest(sessionPnL);
      return;
   }

   // ── Group close — cooldown-gated, no basket-level P&L requirement ──
   // DoStrategicClose self-limits: exits when no profitable group exists
   if(TimeCurrent() - g_lastClose >= (datetime)InpCloseGapSec)
      DoStrategicClose(smallHarvestNow);

   // ── Stuck loop escape — fires when basket spins with no close ────
   StuckLoopClose();

   // ── Two-signal skew: tick momentum + floating P&L ───────────────
   EvaluateSkew();

   // ── Stuck loser recovery ─────────────────────────────────────────
   if(g_recoveryMode)
      ManageRecovery();
   else
      ScanForStuckLoser();

   // ── Trim surplus — hard cap ALWAYS fires, side-surplus checked inside ──
   TrimSurplus();

   // ── Maintain basket (staggered fills, one per gap) ───────────────
   MaintainBasket();
}
//+------------------------------------------------------------------+
