//+------------------------------------------------------------------+
//|  HedgeScalper_v2.mq5  v2.20                                      |
//|                                                                   |
//|  STRATEGY: Imbalanced Hedge + Perpetual Rolling Recovery         |
//|                                                                   |
//|  TWO-MODE OPERATION                                              |
//|  ─────────────────                                               |
//|  PROTECT MODE (primary goal)                                     |
//|    Net P&L must clear ALL real trading costs (spread + comms)   |
//|    before a roll is allowed. This prevents "fake profit" where  |
//|    fees eat the gain and equity quietly bleeds.                 |
//|    In protect mode: stack to max, roll conservatively, chip     |
//|    cage slowly.                                                  |
//|                                                                   |
//|  PROFIT MODE (secondary goal — unlocked once equity secured)    |
//|    Once net P&L > fees + InpProfitBufferPct%, equity is         |
//|    genuinely protected. Now:                                     |
//|      • Roll up to 2 winners at once (faster harvest)            |
//|      • Shorter roll cooldown                                     |
//|      • Cage recovery gets a double chip (larger partial close)  |
//|      • Keep stacking to stay at InpMaxWinners                   |
//|                                                                   |
//|  PHASES                                                          |
//|  ──────                                                          |
//|  1. FREEZE  : 1 Buy + 1 Sell same lot. Net = 0.                |
//|  2. STACK   : Trend detected → add fixed-lot winners (max 5).  |
//|  3. ROLL    : Basket net P&L clears cost → close best winner   |
//|               → open fresh replacement → keep basket at 5.     |
//|  4. RECOVER : Recovery budget chips cage lots (partial close).  |
//|               If cage turns profitable → close it free.        |
//|               Cage gone → restart from freeze.                 |
//|                                                                   |
//|  COST MODEL                                                      |
//|  ──────────                                                      |
//|  rollCost = spreadCostUSD(lot) + InpCommPerLot × lot × 2       |
//|  rollTrigger = rollCost + equity × InpRollThresholdPct / 100   |
//|  profitLine  = rollCost + equity × InpProfitBufferPct  / 100   |
//|  Emergency SL: total P&L < -InpEmergPct% equity → close all.  |
//+------------------------------------------------------------------+
#property copyright "HedgeScalper v2"
#property link      ""
#property version   "2.20"
#property description "Hedge scalper — cost-aware protect mode + profit mode acceleration"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────
enum HedgePhase { PH_IDLE=0, PH_FROZEN=1, PH_RUNNING=2, PH_RECOVER=3 };

//──────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────

input group "=== Lot & Identity ==="
input double          InpLot              = 0.03;   // Fixed lot for ALL positions (same size always)
input long            InpMagic            = 889900;
input int             InpSlippage         = 30;

input group "=== Hard SL per Trade (News Backstop) ==="
input int             InpATRPeriod        = 14;
input ENUM_TIMEFRAMES InpATRTF            = PERIOD_M5;
input double          InpSLMult           = 3.5;    // SL = ATR × this

input group "=== Broker Cost Model ==="
// Set InpCommPerLot to your broker's commission per lot PER SIDE.
// e.g. $3.50/lot per side = $7.00 round trip → set 3.50.
// Zero commission brokers: set 0.
input double          InpCommPerLot       = 3.50;   // Commission per lot per side (USD)

input group "=== Phase 1 — Trend Detection ==="
input double          InpTrendPts         = 50.0;   // Points drift to call a trend
input int             InpMaxFrozenSecs    = 90;     // Close & retry if no trend after N secs

input group "=== Phase 2 — Stacking ==="
input int             InpMaxWinners       = 5;      // Max positions on winning side (fixed)
input int             InpStackCooldown    = 5;      // Seconds between stack adds

input group "=== PROTECT MODE — Roll Trigger ==="
// A roll is allowed only when net P&L >= real cost of the roll + this buffer.
// This ensures equity is genuinely improved, not eaten by fees.
input double          InpRollThresholdPct = 0.02;   // Extra equity % buffer above fees to trigger roll
input int             InpRollCooldown     = 10;     // Seconds between rolls in protect mode

input group "=== PROFIT MODE — Unlocked When Equity Is Secured ==="
// Profit mode activates when: net P&L > fees + InpProfitBufferPct% equity.
// Once active: faster rolls, close up to 2 winners at once, bigger cage chips.
input double          InpProfitBufferPct  = 0.10;   // % equity cushion above fees to enter profit mode
input int             InpProfitRollCooldown = 5;    // Faster roll cooldown in profit mode
input int             InpProfitMaxClose   = 2;      // Winners to close per roll in profit mode (1-3)

input group "=== Cage Recovery ==="
input double          InpRecFraction      = 0.25;   // Fraction of each roll profit → recovery budget
input int             InpRecCooldown      = 12;     // Secs between cage partial closes (protect mode)
input double          InpMinPartialLot    = 0.01;   // Min lot for partial cage close

input group "=== Emergency Exit ==="
input double          InpEmergPct         = 4.0;    // Close ALL if net P&L <= -X% equity
input bool            InpRestart          = true;
input int             InpRestartDelay     = 30;

//──────────────────────────────────────────────────────────────────
// GLOBALS
//──────────────────────────────────────────────────────────────────

CTrade        g_trade;
CPositionInfo g_pos;

int           g_atrH          = INVALID_HANDLE;
double        g_atrBuf[];

HedgePhase    g_phase         = PH_IDLE;
bool          g_profitMode    = false;

ENUM_POSITION_TYPE g_winSide  = POSITION_TYPE_BUY;
ENUM_POSITION_TYPE g_cageSide = POSITION_TYPE_SELL;

ulong         g_cageTkt       = 0;
double        g_lockedProfit  = 0.0;   // All-time profit banked from rolls
double        g_recBudget     = 0.0;   // Available cage recovery cash
int           g_stackCount    = 0;
int           g_rollCount     = 0;
double        g_priceFreeze   = 0.0;

datetime      g_frozenAt      = 0;
datetime      g_lastStack     = 0;
datetime      g_lastRoll      = 0;
datetime      g_lastRec       = 0;
datetime      g_lastClose     = 0;

//──────────────────────────────────────────────────────────────────
// COST HELPERS
//──────────────────────────────────────────────────────────────────

// Real USD cost of opening one position at current spread + commission
double TradeCostUSD(double lot)
{
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread   = ask - bid;
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double spreadUSD = (tickSz > 0) ? (spread / tickSz) * tickVal * lot : 0;
   double commUSD   = InpCommPerLot * lot * 2.0; // both sides (open + close)
   return spreadUSD + commUSD;
}

// Cost of one roll cycle (close winner + open replacement)
double RollCostUSD() { return TradeCostUSD(InpLot); }

//──────────────────────────────────────────────────────────────────
// POSITION HELPERS
//──────────────────────────────────────────────────────────────────

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

int CountWinners()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol && g_pos.Magic()==(ulong)InpMagic &&
         g_pos.PositionType()==g_winSide)
         n++;
   return n;
}

double WinnersPnL()
{
   double t = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol && g_pos.Magic()==(ulong)InpMagic &&
         g_pos.PositionType()==g_winSide)
         t += g_pos.Profit() + g_pos.Swap();
   return t;
}

// Return ticket + P&L of the Nth most profitable winner (rank 0 = best)
ulong WinnerByRank(int rank, double &pnl)
{
   // Collect all winner tickets + P&L
   ulong  tkts[20];  double pnls[20]; int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol && g_pos.Magic()==(ulong)InpMagic &&
         g_pos.PositionType()==g_winSide && n < 20)
      {
         tkts[n]  = g_pos.Ticket();
         pnls[n]  = g_pos.Profit() + g_pos.Swap();
         n++;
      }
   // Simple sort descending by P&L
   for(int a = 0; a < n-1; a++)
      for(int b = a+1; b < n; b++)
         if(pnls[b] > pnls[a])
         {
            double tp = pnls[a]; pnls[a] = pnls[b]; pnls[b] = tp;
            ulong  tt = tkts[a]; tkts[a] = tkts[b]; tkts[b] = tt;
         }
   if(rank < n) { pnl = pnls[rank]; return tkts[rank]; }
   pnl = 0; return 0;
}

double CageLots()
{
   if(g_cageTkt == 0 || !g_pos.SelectByTicket(g_cageTkt)) return 0;
   return g_pos.Volume();
}

double CagePnL()
{
   if(g_cageTkt == 0 || !g_pos.SelectByTicket(g_cageTkt)) return 0;
   return g_pos.Profit() + g_pos.Swap();
}

void CloseAll(string reason)
{
   Print("CloseAll [", reason, "]");
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol && g_pos.Magic()==(ulong)InpMagic)
         g_trade.PositionClose(g_pos.Ticket());
}

bool OpenOrder(ENUM_ORDER_TYPE type, double lot, double atr, string label)
{
   int    digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double dist = atr * InpSLMult;
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stp  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(mn, MathMin(mx, MathRound(lot/stp)*stp));

   if(type == ORDER_TYPE_BUY)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      return g_trade.Buy(lot, _Symbol, ask, NormalizeDouble(ask-dist,digs), 0, "HS:"+label);
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return g_trade.Sell(lot, _Symbol, bid, NormalizeDouble(bid+dist,digs), 0, "HS:"+label);
   }
}

double GetATR()
{
   if(CopyBuffer(g_atrH, 0, 0, 3, g_atrBuf) < 3) return 0;
   return g_atrBuf[1];
}

void SetCageTicket()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(g_pos.SelectByIndex(i) && g_pos.Symbol()==_Symbol && g_pos.Magic()==(ulong)InpMagic &&
         g_pos.PositionType()==g_cageSide)
      { g_cageTkt = g_pos.Ticket(); break; }
}

void ResetCycle()
{
   g_phase       = PH_IDLE;
   g_cageTkt     = 0;
   g_stackCount  = 0;
   g_rollCount   = 0;
   g_priceFreeze = 0;
   g_frozenAt    = 0;
   g_lastStack   = 0;
   g_lastRoll    = 0;
   g_lastRec     = 0;
   g_profitMode  = false;
   // budget + locked profit carry over to assist next cage
}

//──────────────────────────────────────────────────────────────────
// PANEL
//──────────────────────────────────────────────────────────────────
void DrawPanel(double equity, double netPnL, double rollCost, double rollTrigger, double profitLine)
{
   string modeStr = g_profitMode
      ? ">> PROFIT MODE (equity secured)"
      : "   PROTECT MODE (covering costs)";

   string phStr;
   switch(g_phase)
   {
      case PH_IDLE:
         phStr = StringFormat("IDLE — next in %ds", MathMax(0, InpRestartDelay-(int)(TimeCurrent()-g_lastClose)));
         break;
      case PH_FROZEN:
      {
         double d = (SymbolInfoDouble(_Symbol,SYMBOL_BID) - g_priceFreeze) / _Point;
         phStr = StringFormat("FROZEN  drift %+.0fpts  (need ±%.0f)", d, InpTrendPts);
         break;
      }
      case PH_RUNNING:
         phStr = StringFormat("RUNNING  %d winners  %d rolls", CountWinners(), g_rollCount);
         break;
      case PH_RECOVER:
         phStr = StringFormat("RECOVER  cage %.4f lots  P&L %.2f", CageLots(), CagePnL());
         break;
   }

   Comment(StringFormat(
      "═══ HedgeScalper v2.20 ═══\n"
      "Symbol   : %s\n"
      "Mode     : %s\n"
      "Phase    : %s\n"
      "─────────────────────────\n"
      "Net P&L  : %+.2f  (%+.3f%%)\n"
      "Roll cost: %.2f  trigger: %.2f  profit@: %.2f\n"
      "─────────────────────────\n"
      "Winners  : %d / %d   P&L %+.2f\n"
      "Cage     : %s  %.4f lots  %+.2f\n"
      "─────────────────────────\n"
      "Banked   : %.2f   Budget: %.2f\n"
      "Emerg SL : -%.2f",
      _Symbol, modeStr, phStr,
      netPnL, (equity>0 ? netPnL/equity*100.0 : 0),
      rollCost, rollTrigger, profitLine,
      CountWinners(), InpMaxWinners, WinnersPnL(),
      g_cageTkt>0 ? EnumToString(g_cageSide) : "NONE", CageLots(), CagePnL(),
      g_lockedProfit, g_recBudget,
      equity * InpEmergPct / 100.0
   ));
}

//──────────────────────────────────────────────────────────────────
// PHASE HANDLERS
//──────────────────────────────────────────────────────────────────

void HandleIdle(double atr)
{
   if(!InpRestart && g_lastClose > 0) return;
   if(TimeCurrent() - g_lastClose < (datetime)InpRestartDelay) return;

   bool bOk = OpenOrder(ORDER_TYPE_BUY,  InpLot, atr, "freeze");
   bool sOk = OpenOrder(ORDER_TYPE_SELL, InpLot, atr, "freeze");

   if(bOk && sOk)
   {
      g_priceFreeze = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      g_frozenAt    = TimeCurrent();
      g_phase       = PH_FROZEN;
      Print("FREEZE: ", InpLot, "B + ", InpLot, "S  price=", g_priceFreeze);
   }
   else { CloseAll("Freeze open failed"); }
}

//──────────────────────────────────────────────────────────────────
void HandleFrozen()
{
   if(TotalCount() == 0) { ResetCycle(); return; }

   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double drift = (bid - g_priceFreeze) / _Point;

   if(drift >= InpTrendPts)
   {
      g_winSide = POSITION_TYPE_BUY; g_cageSide = POSITION_TYPE_SELL;
      SetCageTicket(); g_phase = PH_RUNNING;
      Print("Trend UP +", drift, "pts — cage=SELL ticket=", g_cageTkt);
      return;
   }
   if(drift <= -InpTrendPts)
   {
      g_winSide = POSITION_TYPE_SELL; g_cageSide = POSITION_TYPE_BUY;
      SetCageTicket(); g_phase = PH_RUNNING;
      Print("Trend DOWN ", drift, "pts — cage=BUY ticket=", g_cageTkt);
      return;
   }
   if(TimeCurrent() - g_frozenAt > (datetime)InpMaxFrozenSecs)
   {
      Print("Freeze timeout — restarting");
      CloseAll("Freeze timeout"); ResetCycle(); g_lastClose = TimeCurrent();
   }
}

//──────────────────────────────────────────────────────────────────
void HandleRunning(double atr, double equity, double netPnL, double rollCost, double rollTrigger, double profitLine)
{
   int  winners  = CountWinners();
   bool cageAlive = (g_cageTkt > 0 && g_pos.SelectByTicket(g_cageTkt) && CageLots() > 0);

   if(TotalCount() == 0)                 { ResetCycle(); g_lastClose = TimeCurrent(); return; }
   if(winners == 0 && cageAlive)         { g_phase = PH_RECOVER; return; }

   // ── A. MODE EVALUATION ───────────────────────────────────────────
   g_profitMode = (netPnL >= profitLine);

   int    rollCooldown = g_profitMode ? InpProfitRollCooldown : InpRollCooldown;
   int    closePerRoll = g_profitMode ? InpProfitMaxClose     : 1;

   // ── B. STACK: fill to max winners ────────────────────────────────
   if(winners < InpMaxWinners && TimeCurrent() - g_lastStack >= (datetime)InpStackCooldown)
   {
      ENUM_ORDER_TYPE ot = (g_winSide==POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(OpenOrder(ot, InpLot, atr, "stack"))
      {
         g_stackCount++;
         g_lastStack = TimeCurrent();
         Print("STACK #", g_stackCount, "  winners=", winners+1, "/", InpMaxWinners,
               "  mode=", g_profitMode?"PROFIT":"PROTECT");
      }
      return; // stack first priority
   }

   // ── C. ROLL: equity-driven harvest (cost-aware) ──────────────────
   //  Protect mode : roll when net P&L clears real cost + small buffer
   //  Profit mode  : roll more frequently, close up to N winners
   if(winners >= InpMaxWinners &&
      netPnL  >= rollTrigger &&
      TimeCurrent() - g_lastRoll >= (datetime)rollCooldown)
   {
      int  closed  = 0;
      bool rollOk  = false;

      for(int r = 0; r < closePerRoll; r++)
      {
         double bPnL  = 0;
         ulong  bTkt  = WinnerByRank(0, bPnL); // always take current best
         if(bTkt == 0 || bPnL <= 0) break;     // only close genuinely profitable ones

         if(g_trade.PositionClose(bTkt))
         {
            double recovery = bPnL * InpRecFraction;
            g_lockedProfit += bPnL;
            g_recBudget    += recovery;
            closed++;
            rollOk = true;
            Print("ROLL #", g_rollCount+1, "  closed winner=", DoubleToString(bPnL,2),
                  "  recovery+=", DoubleToString(recovery,2),
                  "  budget=", DoubleToString(g_recBudget,2),
                  "  mode=", g_profitMode?"PROFIT":"PROTECT");
         }
      }

      if(rollOk)
      {
         g_rollCount++;
         g_lastRoll = TimeCurrent();

         // Open replacements to restore winner count
         winners = CountWinners();
         int toOpen = InpMaxWinners - winners;
         ENUM_ORDER_TYPE ot = (g_winSide==POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         for(int o = 0; o < toOpen; o++)
            OpenOrder(ot, InpLot, atr, "roll");
      }
   }

   // ── D. CAGE: free close if it turned profitable (reversal) ───────
   if(cageAlive && CagePnL() >= 0)
   {
      Print("Cage turned profitable (", DoubleToString(CagePnL(),2), ") — closing free!");
      g_trade.PositionClose(g_cageTkt);
      g_cageTkt = 0;
      cageAlive = false;
   }

   // ── E. CAGE: partial chip with recovery budget ───────────────────
   if(cageAlive && g_recBudget > 0 &&
      TimeCurrent() - g_lastRec >= (datetime)(g_profitMode ? InpRecCooldown/2 : InpRecCooldown))
   {
      double cLots = CageLots();
      double cPnL  = CagePnL();
      if(cLots > 0 && cPnL < 0)
      {
         double lossPerLot = MathAbs(cPnL) / cLots;
         if(lossPerLot > 0)
         {
            // In profit mode: chip double the normal amount
            double budgetToUse = g_profitMode ? g_recBudget * 0.5 : g_recBudget * 0.25;
            double afford      = budgetToUse / lossPerLot;
            double stp         = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double mn          = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            double closeLots   = MathMax(mn, MathMin(MathRound(afford/stp)*stp, cLots));
            double cost        = closeLots * lossPerLot;

            Print("CHIP CAGE: ", closeLots, " lots  cost~", DoubleToString(cost,2),
                  "  remaining~", DoubleToString(cLots-closeLots,4),
                  "  mode=", g_profitMode?"PROFIT":"PROTECT");

            if(g_trade.PositionClosePartial(g_cageTkt, closeLots))
            {
               g_recBudget = MathMax(0.0, g_recBudget - cost);
               g_lastRec   = TimeCurrent();
               if(CageLots() <= 0)
               {
                  Print("Cage fully chipped — restarting");
                  ResetCycle(); g_lastClose = TimeCurrent();
               }
            }
         }
      }
   }
}

//──────────────────────────────────────────────────────────────────
void HandleRecover()
{
   // Winners all stopped out — only cage remains, chip with budget + wait for reversal
   bool cageAlive = (g_cageTkt > 0 && g_pos.SelectByTicket(g_cageTkt) && CageLots() > 0);
   if(!cageAlive) { ResetCycle(); g_lastClose = TimeCurrent(); return; }

   if(CagePnL() >= 0)
   {
      Print("Cage recovered to profit — closing free!");
      g_trade.PositionClose(g_cageTkt);
      ResetCycle(); g_lastClose = TimeCurrent();
      return;
   }

   if(g_recBudget > 0 && TimeCurrent() - g_lastRec >= (datetime)InpRecCooldown)
   {
      double cLots     = CageLots();
      double lppL      = MathAbs(CagePnL()) / cLots;
      if(lppL > 0)
      {
         double afford  = (g_recBudget * 0.25) / lppL;
         double stp     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double mn      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double cl      = MathMax(mn, MathMin(MathRound(afford/stp)*stp, cLots));
         double cost    = cl * lppL;
         if(g_trade.PositionClosePartial(g_cageTkt, cl))
         {
            g_recBudget = MathMax(0.0, g_recBudget - cost);
            g_lastRec   = TimeCurrent();
            if(CageLots() <= 0) { ResetCycle(); g_lastClose = TimeCurrent(); }
         }
      }
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
   g_atrH = iATR(_Symbol, InpATRTF, InpATRPeriod);
   if(g_atrH == INVALID_HANDLE) { Print("ATR init failed"); return INIT_FAILED; }
   ArraySetAsSeries(g_atrBuf, true);
   Print("HedgeScalper v2.20 — ", _Symbol,
         "  comm/lot=", InpCommPerLot, "  lot=", InpLot);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atrH != INVALID_HANDLE) IndicatorRelease(g_atrH);
   Comment("");
}

void OnTick()
{
   double atr    = GetATR();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(atr <= 0 || equity <= 0) return;

   double netPnL     = TotalPnL();
   double rollCost   = RollCostUSD();
   double rollTrigger = rollCost + equity * InpRollThresholdPct  / 100.0;
   double profitLine  = rollCost + equity * InpProfitBufferPct   / 100.0;

   DrawPanel(equity, netPnL, rollCost, rollTrigger, profitLine);

   // Emergency SL — every tick
   if(g_phase != PH_IDLE && TotalCount() > 0)
   {
      double emgSL = -(equity * InpEmergPct / 100.0);
      if(netPnL <= emgSL)
      {
         CloseAll(StringFormat("Emergency SL: %.2f <= %.2f", netPnL, emgSL));
         ResetCycle(); g_lastClose = TimeCurrent();
         return;
      }
   }

   // All positions gone externally (SL / manual)
   if(g_phase != PH_IDLE && TotalCount() == 0)
   {
      Print("All positions cleared externally");
      ResetCycle(); g_lastClose = TimeCurrent();
      return;
   }

   switch(g_phase)
   {
      case PH_IDLE:    HandleIdle(atr);                                             break;
      case PH_FROZEN:  HandleFrozen();                                              break;
      case PH_RUNNING: HandleRunning(atr, equity, netPnL, rollCost, rollTrigger, profitLine); break;
      case PH_RECOVER: HandleRecover();                                             break;
   }
}
//+------------------------------------------------------------------+
