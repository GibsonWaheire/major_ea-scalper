//+------------------------------------------------------------------+
//|  HedgeScalper_v6.mq5  v6.10  — Loser-First Net Harvester       |
//|                                                                   |
//|  ARCHITECTURE — two-tier close priority:                        |
//|                                                                   |
//|  TIER 1 — ClearLosers() (every tick, highest priority)         |
//|    Target SMALLEST loser first (easiest to net out).            |
//|    Pair with minimum winners to net ≥ 0.  Close immediately.   |
//|    If winners cover ≥ 30% but not 100%:                        |
//|      → Partial close loser by half lot (lock half the loss)     |
//|      → Reduced loser coverable on next tick.                    |
//|                                                                   |
//|  TIER 2 — HarvestWinners() (only when no losers remain)        |
//|    All positions profitable? Close groups meeting ATR threshold. |
//|    Direction rule: mixed (buy+sell) OR 3+ same direction.       |
//|                                                                   |
//|  OPEN GUARD — MaintainBasket()                                  |
//|    Counter opens (defensive) fire freely.                       |
//|    3rd+ directional trade requires skew score == 2              |
//|    (tick momentum AND floating P&L both agree).                 |
//|    Direction X has losers? Open opposite Y instead.            |
//|    Both sides losing? Hold.                                     |
//|                                                                   |
//|  Safety SL on every position: spike/news protection only.      |
//|  ATR-scaled harvest threshold: adjusts to market volatility.   |
//+------------------------------------------------------------------+
#property copyright "HedgeScalper v6"
#property link      ""
#property version   "6.20"
#property description "Loser-first net harvester — stochastic 4th/5th trade trigger"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//──────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────

input group "=== Basket ==="
input int    InpBuys         = 1;      // Initial buy count
input int    InpSells        = 2;      // Initial sell count — 1:2=3 odd start
input double InpLot          = 0.05;   // Lot size per position
input long   InpMagic        = 990013;
input int    InpSlippage     = 50;

input group "=== Entry Stagger ==="
input int    InpOpenGapSec   = 5;      // Seconds between each open (different entry prices)

input group "=== Harvest Thresholds ==="
input double InpBigHarvest   = 10.0;   // Session P&L >= this → close ALL, restart
input double InpSmallHarvest = 2.0;    // Base harvest floor (lot-scaled + ATR-scaled)

input group "=== Basket Management ==="
input int    InpMinKeep      = 3;      // Minimum positions in basket
input int    InpCloseGapSec  = 3;      // Cooldown between closes
input int    InpMaxBasket    = 5;      // Hard cap total positions
input bool   InpScaleUp      = true;   // Grow basket target after big harvests
input int    InpScaleAfter   = 3;      // Big harvests between each scale step
input int    InpMaxPerSide   = 3;      // Max positions per side

input group "=== Partial Close ==="
input double InpPartialCover = 0.30;   // Winners must cover ≥ this % of loser to trigger partial close

input group "=== Restart ==="
input int    InpRestartDelay = 10;     // Seconds after big harvest before reopening

input group "=== Risk Guards ==="
input double InpMaxSpreadPips = 20.0;  // Max spread in pips — pause opens above this
input double InpDailyLossPct  = 50.0;  // Max daily equity loss % — halt for day
input double InpTrailFactor   = 0.5;   // Trailing harvest: threshold = max(base, peak * factor)
input int    InpSLPoints      = 2000;  // Hard SL in points per position — spike protection only
                                        // XAU: 2000pt = $20 price move. Set 0 to disable.

input group "=== ATR Dynamic Threshold ==="
input int    InpATRPeriod     = 14;    // ATR lookback (M1 candles)
input double InpATRMultiplier = 0.3;   // threshold += ATR × tickVal/tickSz × lots × this

input group "=== Direction Skew ==="
input int    InpSkewCheckSec  = 30;    // Window seconds for tick momentum signal
input double InpTickBias      = 1.3;   // Tick ratio needed for momentum signal
input int    InpSkewStrong    = 3;     // Positions on high-conviction side
input int    InpSkewWeak      = 2;     // Positions on low-conviction side
input int    InpSkewFlat      = 0;     // Positions on losing side (both signals agree)

input group "=== 4th/5th Trade — Stochastic ==="
input int    InpStochK        = 5;     // Stochastic %K period
input int    InpStochD        = 3;     // Stochastic %D period
input int    InpStochSlowing  = 3;     // Stochastic slowing
input double InpStochBuyLvl   = 60.0;  // Stoch K above this → add BUY
input double InpStochSellLvl  = 40.0;  // Stoch K below this → add SELL

//──────────────────────────────────────────────────────────────────
// STRUCTS
//──────────────────────────────────────────────────────────────────

struct PosRecord
{
   ulong              ticket;
   double             pnl;
   double             volume;
   ENUM_POSITION_TYPE type;
};

//──────────────────────────────────────────────────────────────────
// GLOBALS
//──────────────────────────────────────────────────────────────────

CTrade        g_trade;
CPositionInfo g_pos;

bool     g_active         = false;
double   g_sessionClosed  = 0.0;
int      g_bigHarvests    = 0;
int      g_tradeEvents    = 0;
int      g_curBuys        = 0;
int      g_curSells       = 0;
datetime g_lastOpen       = 0;
datetime g_lastBigHarvest = 0;
int      g_lastScaleAt    = 0;
bool     g_lastWasBuy     = false;

int      g_upTicks        = 0;
int      g_downTicks      = 0;
double   g_lastBid        = 0;
datetime g_lastSkewCheck  = 0;
int      g_skewScore      = 0;   // 0=neutral 1=weak 2=strong — used to gate 3rd trade

double   g_peakSessionPnL  = 0;
double   g_dayStartBalance = 0;
datetime g_currentDay      = 0;
bool     g_haltedForDay    = false;
datetime g_lastClose       = 0;

int      g_atrHandle       = INVALID_HANDLE;
int      g_stochHandle     = INVALID_HANDLE;

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

bool SpreadOK()
{
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pipPt = (_Digits % 2 == 1) ? _Point * 10.0 : _Point;
   return ((ask - bid) / pipPt <= InpMaxSpreadPips);
}

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

double NormPartialLot(double vol)
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return MathMax(mn, MathMin(mx, MathFloor(vol/st)*st));
}

bool OpenBuy(string lbl)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl  = (InpSLPoints > 0) ? NormalizeDouble(ask - InpSLPoints * _Point, _Digits) : 0;
   bool   ok  = g_trade.Buy(NormLot(), _Symbol, ask, sl, 0, "HS6:"+lbl);
   if(ok) { g_lastOpen = TimeCurrent(); g_lastWasBuy = true;  g_tradeEvents++; }
   return ok;
}

bool OpenSell(string lbl)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = (InpSLPoints > 0) ? NormalizeDouble(bid + InpSLPoints * _Point, _Digits) : 0;
   bool   ok  = g_trade.Sell(NormLot(), _Symbol, bid, sl, 0, "HS6:"+lbl);
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
// POSITION ARRAY — build and sort descending by P&L (best → worst)
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
      arr[n].volume = g_pos.Volume();
      arr[n].type   = g_pos.PositionType();
      n++;
   }
   ArrayResize(arr, n);
   // Bubble sort descending by P&L (best → worst)
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
   g_curBuys        = InpBuys;
   g_curSells       = InpSells;
   g_upTicks        = 0;
   g_downTicks      = 0;
   g_lastSkewCheck  = 0;
   g_lastClose      = 0;
   g_peakSessionPnL = 0;
   g_skewScore      = 0;

   if(InpScaleUp && g_bigHarvests % InpScaleAfter == 0 && g_bigHarvests != g_lastScaleAt)
   {
      g_lastScaleAt = g_bigHarvests;
      if(g_curBuys  < InpMaxPerSide) g_curBuys++;
      if(g_curSells < InpMaxPerSide) g_curSells++;
      Print("SCALE UP → next basket: ", g_curBuys, "B + ", g_curSells, "S");
   }
}

//──────────────────────────────────────────────────────────────────
// TIER 1 — CLEAR LOSERS (smallest loser first + partial close)
//──────────────────────────────────────────────────────────────────
//
//  Targets the SMALLEST loser first (easiest to net out quickly).
//  Pairs with minimum winners to net ≥ 0. No threshold. No direction rule.
//
//  If winners can't fully cover the smallest loser BUT cover ≥ InpPartialCover
//  of its absolute loss → partial close the loser by half lot.
//  Example:
//    Loser: 0.5 lot @ -$100   Winners: +$50
//    Winners cover 50% ≥ 30% threshold → partial close 0.25 lot
//    Locked: -$50.  Remaining: 0.25 lot @ ~-$50
//    Next tick: ClearLosers pairs remaining (-$50) with winner (+$50) → net $0
//
void ClearLosers()
{
   if(TimeCurrent() - g_lastClose < (datetime)InpCloseGapSec) return;

   PosRecord arr[];
   int n = BuildSortedPositions(arr);
   if(n < 2) return;

   // Find SMALLEST loser (minimum absolute P&L among losers)
   int    smallestIdx = -1;
   double smallestAbs = DBL_MAX;
   for(int i = 0; i < n; i++)
   {
      if(arr[i].pnl >= 0) continue;
      double absLoss = MathAbs(arr[i].pnl);
      if(absLoss < smallestAbs) { smallestAbs = absLoss; smallestIdx = i; }
   }
   if(smallestIdx < 0) return; // no losers — pass to Tier 2

   // Sum all available winners
   double winnerSum = 0;
   for(int i = 0; i < n; i++)
      if(i != smallestIdx && arr[i].pnl > 0)
         winnerSum += arr[i].pnl;

   // ── Case 1: Winners can fully cover the loser → normal net close ──
   if(winnerSum + arr[smallestIdx].pnl >= 0)
   {
      PosRecord closeGroup[];
      ArrayResize(closeGroup, n);
      int    groupSize  = 0;
      double runningNet = arr[smallestIdx].pnl;
      closeGroup[groupSize++] = arr[smallestIdx];

      for(int i = 0; i < n; i++)
      {
         if(i == smallestIdx)    continue;
         if(arr[i].pnl <= 0)    continue;
         runningNet += arr[i].pnl;
         closeGroup[groupSize++] = arr[i];
         if(runningNet >= 0) break;
      }

      if(runningNet < 0) return;

      int closed = 0;
      for(int i = 0; i < groupSize; i++)
         if(g_trade.PositionClose(closeGroup[i].ticket))
            closed++;

      if(closed > 0)
      {
         g_tradeEvents   += closed;
         g_sessionClosed += runningNet;
         g_lastClose      = TimeCurrent();
         g_lastSkewCheck  = 0;
         Print("ClearLosers: ", closed, " pos  loser=",
               DoubleToString(arr[smallestIdx].pnl, 2),
               "  net=", DoubleToString(runningNet, 2),
               "  remaining=", n - closed);
      }
      return;
   }

   // ── Case 2: Winners cover ≥ InpPartialCover of the loser
   //    → Partial close loser by half lot to make it coverable next tick ──
   if(winnerSum <= 0) return; // no winners at all — nothing we can do yet
   double coverRatio = winnerSum / smallestAbs;
   if(coverRatio < InpPartialCover) return; // winners too small even for partial

   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Need at least 2× volMin to be able to halve it
   if(arr[smallestIdx].volume < 2.0 * volMin) return;

   double halfLot = NormPartialLot(arr[smallestIdx].volume / 2.0);
   if(halfLot < volMin) return;

   if(g_trade.PositionClosePartial(arr[smallestIdx].ticket, halfLot))
   {
      g_tradeEvents++;
      g_lastClose = TimeCurrent();
      Print("PartialClose: ticket=", arr[smallestIdx].ticket,
            "  closedLot=", DoubleToString(halfLot, 2),
            "  loserPnL=", DoubleToString(arr[smallestIdx].pnl, 2),
            "  winners=", DoubleToString(winnerSum, 2),
            "  cover=", DoubleToString(coverRatio * 100, 0), "%",
            "  → reduced loser coverable next tick");
   }
}

//──────────────────────────────────────────────────────────────────
// TIER 2 — HARVEST WINNERS
//──────────────────────────────────────────────────────────────────
//
//  Only runs when NO losers remain in the basket.
//  Finds a net-positive group meeting the ATR-scaled threshold.
//  Direction rule: must be mixed (buy+sell) OR 3+ same direction.
//
void HarvestWinners(double threshold)
{
   if(TimeCurrent() - g_lastClose < (datetime)InpCloseGapSec) return;

   PosRecord arr[];
   int n = BuildSortedPositions(arr);
   if(n < 2) return;

   // Abort if ANY loser exists — Tier 1 must run first
   for(int i = 0; i < n; i++)
      if(arr[i].pnl < 0) return;

   // Can close all but 1 anchor
   int canClose = n - 1;
   if(canClose <= 0) return;

   // Odd remaining: (n - canClose) must be odd
   if((n - canClose) % 2 == 0) { canClose--; if(canClose <= 0) return; }

   // Build close group
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

   if(setSize == 0 || runningNet < threshold) return;

   // Parity fix
   if((n - setSize) % 2 == 0 && setSize > 1)
   {
      setSize--;
      runningNet -= closeSet[setSize].pnl;
   }
   if(setSize == 0 || runningNet <= 0) return;

   // Direction rule: mixed OR 3+ same direction
   int buysInSet = 0, sellsInSet = 0;
   for(int i = 0; i < setSize; i++)
   {
      if(closeSet[i].type == POSITION_TYPE_BUY) buysInSet++;
      else                                        sellsInSet++;
   }
   bool mixed        = (buysInSet > 0 && sellsInSet > 0);
   bool sameDir3Plus = (!mixed && setSize >= 3);
   if(!mixed && !sameDir3Plus) return;

   int closed = 0;
   for(int i = 0; i < setSize; i++)
      if(g_trade.PositionClose(closeSet[i].ticket))
         closed++;

   g_tradeEvents   += closed;
   g_sessionClosed += runningNet;
   g_lastClose      = TimeCurrent();
   g_lastSkewCheck  = 0;

   Print("HarvestWinners: ", closed, " pos  buys=", buysInSet, " sells=", sellsInSet,
         "  net=+", DoubleToString(runningNet, 2),
         "  sessionLocked=+", DoubleToString(g_sessionClosed, 2),
         "  remaining=", n - closed);
}

//──────────────────────────────────────────────────────────────────
// BASKET OPEN
//──────────────────────────────────────────────────────────────────

void OpenBasket()
{
   if(TotalCount() >= InpMaxBasket) { g_active = true; return; }
   OpenBuy("init");
   g_active = true;
   Print("Basket started — target ", g_curBuys, "B + ", g_curSells, "S");
}

//──────────────────────────────────────────────────────────────────
// MAINTAIN BASKET — loser-direction guard + 3rd trade conviction gate
//──────────────────────────────────────────────────────────────────
//
//  Counter opens (defensive) fire freely — no conviction needed.
//  The 3rd+ directional trade requires g_skewScore == 2:
//    both tick momentum AND floating P&L must agree on direction.
//  Score 1 = weak signal = stay at 2 positions, wait.
//
void MaintainBasket()
{
   if(!SpreadOK()) return;
   if(TimeCurrent() - g_lastOpen < (datetime)InpOpenGapSec) return;

   int buys  = CountSide(POSITION_TYPE_BUY);
   int sells = CountSide(POSITION_TYPE_SELL);
   int total = buys + sells;

   if(total >= InpMaxBasket) return;

   // ── Below minimum: fill unconditionally — no guards, no score gate ──
   // A 2-position basket is not a real hedge. Must always reach InpMinKeep.
   if(total < InpMinKeep)
   {
      int buyDef  = g_curBuys  - buys;
      int sellDef = g_curSells - sells;
      if(buyDef > 0 && buyDef >= sellDef) { OpenBuy("fill-min");  return; }
      if(sellDef > 0)                     { OpenSell("fill-min"); return; }
      // Both sides filled to target or tied — alternate to reach minimum
      if(!g_lastWasBuy) OpenBuy("min");
      else              OpenSell("min");
      return;
   }

   // ── At or above minimum: Stochastic decides 4th/5th trade ──────────
   // Read stochastic K line (fast line, buffer 0)
   double stochK = 50.0; // neutral default — hold if indicator unavailable
   if(g_stochHandle != INVALID_HANDLE)
   {
      double kBuf[];
      ArraySetAsSeries(kBuf, true);
      if(CopyBuffer(g_stochHandle, 0, 0, 1, kBuf) > 0)
         stochK = kBuf[0];
   }

   // Stoch > InpStochBuyLvl (60) → momentum up → add buy
   // Stoch < InpStochSellLvl (40) → momentum down → add sell
   // Neutral zone (40–60) → hold at minimum basket
   if(stochK > InpStochBuyLvl && buys < InpMaxPerSide)
   {
      OpenBuy("stoch");
      return;
   }
   if(stochK < InpStochSellLvl && sells < InpMaxPerSide)
   {
      OpenSell("stoch");
      return;
   }
}

//──────────────────────────────────────────────────────────────────
// TRIM SURPLUS — hard cap enforcement
//──────────────────────────────────────────────────────────────────

void TrimSurplus()
{
   int total = TotalCount();
   if(total <= InpMaxBasket) return;

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
            "  closed worst=", DoubleToString(worstPnL, 2));
   }
}

//──────────────────────────────────────────────────────────────────
// EVALUATE SKEW — two-signal direction conviction
//──────────────────────────────────────────────────────────────────
//
//  Sets g_skewScore: 0=neutral, 1=weak (one signal agrees),
//  2=strong (both tick momentum AND P&L agree).
//  MaintainBasket() gates 3rd+ trade on score == 2.
//
void EvaluateSkew()
{
   if(!g_active) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_lastBid > 0)
   {
      if(bid > g_lastBid) g_upTicks++;
      if(bid < g_lastBid) g_downTicks++;
   }
   g_lastBid = bid;

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

   bool   canGoFlat  = IsBasketBuilt();
   double sessionPnL = g_sessionClosed + TotalFloatingPnL();
   int    prevBuys   = g_curBuys, prevSells = g_curSells;

   if(buyScore > sellScore)
   {
      g_skewScore = buyScore;
      g_curBuys  = MathMin(InpSkewStrong, InpMaxPerSide);
      g_curSells = (buyScore == 2 && canGoFlat) ? InpSkewFlat : InpSkewWeak;
   }
   else if(sellScore > buyScore)
   {
      g_skewScore = sellScore;
      g_curSells = MathMin(InpSkewStrong, InpMaxPerSide);
      g_curBuys  = (sellScore == 2 && canGoFlat) ? InpSkewFlat : InpSkewWeak;
   }
   else
   {
      g_skewScore = 0;
      if(sessionPnL > 0) { g_curBuys = InpBuys; g_curSells = InpSells; }
   }

   // Cap to InpMaxBasket
   while(g_curBuys + g_curSells > InpMaxBasket)
   {
      if(g_curSells > 0 && g_curSells <= g_curBuys) g_curSells--;
      else if(g_curBuys > 0)                         g_curBuys--;
      else break;
   }

   // Enforce odd total
   if((g_curBuys + g_curSells) % 2 == 0 && (g_curBuys + g_curSells) < InpMaxBasket)
   {
      if(g_curBuys >= g_curSells) g_curBuys++;
      else                         g_curSells++;
   }

   Print("Skew | ticks=", g_upTicks, "↑/", g_downTicks, "↓",
         "  buyPnL=", DoubleToString(buyPnL, 2),
         "  sellPnL=", DoubleToString(sellPnL, 2),
         "  scores=", buyScore, "B/", sellScore, "S",
         "  skewScore=", g_skewScore,
         (g_skewScore == 2 ? " [STRONG — 3rd trade unlocked]" : " [WEAK — hold at 2]"),
         "  → ", g_curBuys, "B:", g_curSells, "S",
         (g_curBuys!=prevBuys || g_curSells!=prevSells) ? " [CHANGED]" : "");

   g_upTicks   = 0;
   g_downTicks = 0;
}

//──────────────────────────────────────────────────────────────────
// PANEL
//──────────────────────────────────────────────────────────────────

void DrawPanel(double sessionPnL, double floating, double equity,
               double dailyPnL, double threshold)
{
   int buys  = CountSide(POSITION_TYPE_BUY);
   int sells = CountSide(POSITION_TYPE_SELL);

   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pipPt  = (_Digits % 2 == 1) ? _Point * 10.0 : _Point;
   double spread = (ask - bid) / pipPt;

   double buyPnL      = SidePnL(POSITION_TYPE_BUY);
   double sellPnL     = SidePnL(POSITION_TYPE_SELL);
   bool   buysLosing  = (buys  > 0 && buyPnL  < 0);
   bool   sellsLosing = (sells > 0 && sellPnL < 0);

   string mode;
   if(buysLosing && sellsLosing) mode = "BOTH LOSING — holding";
   else if(buysLosing)           mode = "Buys losing — clearing / opening sells";
   else if(sellsLosing)          mode = "Sells losing — clearing / opening buys";
   else                          mode = "No losers — harvest mode";

   double stochKPanel = 50.0;
   if(g_stochHandle != INVALID_HANDLE)
   {
      double kBuf2[];
      ArraySetAsSeries(kBuf2, true);
      if(CopyBuffer(g_stochHandle, 0, 0, 1, kBuf2) > 0) stochKPanel = kBuf2[0];
   }
   string stochTxt = StringFormat("K=%.1f  %s", stochKPanel,
                     stochKPanel > InpStochBuyLvl  ? "↑ BUY signal"  :
                     stochKPanel < InpStochSellLvl ? "↓ SELL signal" : "— neutral (hold)");

   string status;
   if(g_haltedForDay)                   status = "!!! HALTED — daily loss limit !!!";
   else if(sessionPnL >= InpBigHarvest) status = ">>> BIG HARVEST FIRING <<<";
   else if(!SpreadOK())                 status = StringFormat("SPREAD BLOCK (%.1f pips)", spread);
   else                                 status = mode;

   Comment(StringFormat(
      "═══ HedgeScalper v6.20 ═══\n"
      "Symbol      : %s   Spread: %.1f pip%s\n"
      "Basket      : %s   bigH: %d\n"
      "Target      : %dB + %dS  (max: %d)\n"
      "Stoch(5,3,3): %s\n"
      "────────────────────────────\n"
      "Session P&L : %+.2f\n"
      "  locked    : %+.2f  (closed)\n"
      "  floating  : %+.2f  (open)\n"
      "  peak      : %+.2f\n"
      "────────────────────────────\n"
      "Buys        : %d pos  %+.2f  %s\n"
      "Sells       : %d pos  %+.2f  %s\n"
      "────────────────────────────\n"
      "Status      : %s\n"
      "Events      : %d\n"
      "────────────────────────────\n"
      "Daily P&L   : %+.2f  limit: -%.0f%%\n"
      "Harvest thr : +%.2f  BigH: +%.2f\n"
      "SL pts      : %d\n"
      "Equity      : %.2f",
      _Symbol, spread, SpreadOK() ? "" : " !!",
      g_active ? "RUNNING" : "IDLE", g_bigHarvests,
      g_curBuys, g_curSells, InpMaxBasket,
      stochTxt,
      sessionPnL, g_sessionClosed, floating, g_peakSessionPnL,
      buys,  buyPnL,  buysLosing  ? "◄ LOSING" : "OK",
      sells, sellPnL, sellsLosing ? "◄ LOSING" : "OK",
      status, g_tradeEvents,
      dailyPnL, InpDailyLossPct,
      threshold, InpBigHarvest,
      InpSLPoints,
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

   g_curBuys         = InpBuys;
   g_curSells        = InpSells;
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_currentDay      = (datetime)(TimeCurrent() - TimeCurrent() % 86400);

   if(InpATRMultiplier > 0)
   {
      g_atrHandle = iATR(_Symbol, PERIOD_M1, InpATRPeriod);
      if(g_atrHandle == INVALID_HANDLE)
         Print("Warning: ATR handle failed — using fixed threshold only");
   }

   g_stochHandle = iStochastic(_Symbol, PERIOD_M1, InpStochK, InpStochD, InpStochSlowing,
                                MODE_SMA, STO_LOWHIGH);
   if(g_stochHandle == INVALID_HANDLE)
      Print("Warning: Stochastic handle failed");

   if(TotalCount() > 0)
   {
      g_active = true;
      Print("Resumed: found ", TotalCount(), " existing positions");
   }

   Print("HedgeScalper v6.10 — ", _Symbol,
         "  lot=", InpLot,
         "  SL=", InpSLPoints, "pt",
         "  bigH=+", InpBigHarvest,
         "  smallH=+", InpSmallHarvest,
         "  ATRx=", InpATRMultiplier,
         "  partialCover=", InpPartialCover*100, "%");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atrHandle   != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_stochHandle != INVALID_HANDLE) IndicatorRelease(g_stochHandle);
   Comment("");
}

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
   double dailyPnL           = equity - g_dayStartBalance;
   double dailyLossThreshold = g_dayStartBalance * InpDailyLossPct / 100.0;
   if(!g_haltedForDay && dailyPnL <= -dailyLossThreshold)
   {
      Print("Daily loss limit hit (", DoubleToString(dailyPnL, 2), ") — halting");
      CloseAll("DailyLossLimit");
      g_active       = false;
      g_haltedForDay = true;
   }

   // ── ATR-dynamic harvest threshold ────────────────────────────────
   double lotScale = MathMax(1.0, NormLot() / 0.05);
   if(sessionPnL > g_peakSessionPnL) g_peakSessionPnL = sessionPnL;

   double atrThreshold = 0;
   if(InpATRMultiplier > 0 && g_atrHandle != INVALID_HANDLE)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_atrHandle, 0, 0, 1, atrBuf) > 0)
      {
         double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         double tickSz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         if(tickSz > 0)
            atrThreshold = atrBuf[0] / tickSz * tickVal * NormLot() * InpATRMultiplier;
      }
   }

   double harvestThreshold = MathMax(InpSmallHarvest * lotScale,
                             MathMax(atrThreshold,
                                     g_peakSessionPnL * InpTrailFactor));

   DrawPanel(sessionPnL, floating, equity, dailyPnL, harvestThreshold);

   if(g_haltedForDay) return;

   // ── Not active: open basket after restart delay ──────────────────
   if(!g_active)
   {
      if(TimeCurrent() - g_lastBigHarvest >= (datetime)InpRestartDelay)
         OpenBasket();
      return;
   }

   // ── All positions gone externally — reset ────────────────────────
   if(TotalCount() == 0)
   {
      Print("All positions gone — resetting session");
      g_sessionClosed  = 0;
      g_tradeEvents    = 0;
      g_peakSessionPnL = 0;
      g_active         = false;
      g_lastBigHarvest = TimeCurrent();
      return;
   }

   // ── Big harvest ──────────────────────────────────────────────────
   if(sessionPnL >= InpBigHarvest)
   {
      DoBigHarvest(sessionPnL);
      return;
   }

   // ── TIER 1: Clear losers — highest priority ──────────────────────
   // Smallest loser first. Normal net close OR partial close fallback.
   ClearLosers();

   // ── TIER 2: Harvest winners — only when basket is all-positive ───
   HarvestWinners(harvestThreshold);

   // ── Direction skew — updates g_skewScore for 3rd trade gate ─────
   EvaluateSkew();

   // ── Hard cap ─────────────────────────────────────────────────────
   TrimSurplus();

   // ── Fill basket — defensive counters free, 3rd needs score==2 ───
   MaintainBasket();
}
//+------------------------------------------------------------------+
