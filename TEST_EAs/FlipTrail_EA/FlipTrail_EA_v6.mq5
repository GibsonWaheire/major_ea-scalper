//+------------------------------------------------------------------+
//|  FlipTrail_EA_v6.mq5  v6.10                                      |
//|  Strategic HFT Basket Scalper — Profit-Gated Session             |
//|                                                                   |
//|  SESSION LOGIC                                                    |
//|  ─────────────                                                    |
//|  Basket opens on every qualified M1 bar signal.                  |
//|  Basket only closes in PROFIT (or on hard SL).                   |
//|  After InpProfitableBasketTarget profitable closes → STOP.       |
//|  Example: 3 profitable baskets in a row → done for the day.      |
//|                                                                   |
//|  BASKET CLOSE RULES                                              |
//|  ──────────────────                                               |
//|  EXIT (profit): total basket P&L > 0 AND % move >= InpMinMovePct |
//|    Phase 1 — close InpPartial1Count trades at InpTarget1Pct%     |
//|    Phase 2 — move rest to breakeven SL, close at InpTarget2Pct%  |
//|  EXIT (loss):  basket avg entry moved against by InpHardSLPct%   |
//|    Hard SL → closes all, does NOT count as profitable basket     |
//|                                                                   |
//|  ENTRY FILTERS (all subsequent baskets after first)              |
//|  ─────────────────────────────────────────────────               |
//|  EMA(5) vs EMA(13) on M1 — micro-trend alignment               |
//|  RSI(7) on M1         — momentum guard (avoid chasing)          |
//|  Candle body %         — avoids doji/indecision bars            |
//|                                                                   |
//|  FIRST BASKET: fires immediately on EA start, no filter.         |
//|  Removes emotion — skin in the game from tick 1.                |
//+------------------------------------------------------------------+
#property copyright "FlipTrail EA v6"
#property link      ""
#property version   "6.10"
#property description "FlipTrail v6.10: profit-gated basket close, N-profitable-basket session stop"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Basket ==="
input int    InpBasketSize           = 5;       // BasketSize: trades per basket (1–10)
input double InpRiskPct              = 5.0;     // RiskPct: % equity per trade
input double InpMinLot               = 0.01;    // MinLot
input double InpMaxLot               = 50.0;    // MaxLot
input long   InpMagicNumber          = 112236;  // MagicNumber (v6)
input int    InpMaxSlippagePoints    = 30;      // MaxSlippagePoints
input int    InpMaxSpreadPoints      = 50;      // MaxSpreadPoints

input group "=== Entry Filters ==="
input bool   InpImmediateFirst       = true;    // ImmediateFirst: fire basket on EA start, no filter
input int    InpEMAFast              = 5;       // EMA Fast period (M1)
input int    InpEMASlow              = 13;      // EMA Slow period (M1)
input int    InpRSIPeriod            = 7;       // RSI period (M1)
input double InpRSIBuyMax            = 65.0;   // RSI max allowed for BUY entry
input double InpRSISellMin           = 35.0;   // RSI min allowed for SELL entry
input int    InpMinBodyPct           = 30;     // MinBodyPct: min candle body % of range (0=off)

input group "=== Basket Exit ==="
input double InpMinMovePct           = 0.03;   // MinMovePct: basket avg entry must move this % for profit close
input double InpTarget1Pct           = 0.03;   // Target1Pct: % move to trigger partial close
input int    InpPartial1Count        = 3;      // Partial1Count: trades to close at Target1 (of BasketSize)
input double InpTarget2Pct           = 0.07;   // Target2Pct: % move to close remaining trades
input double InpHardSLPct            = 0.15;   // HardSLPct: % against avg entry to hard-stop basket (loss)

input group "=== Session Stop ==="
input int    InpProfitableBasketTarget = 3;    // ProfitableBasketTarget: stop after N profitable basket closes
input double InpSessionProfitPct     = 1.0;   // SessionProfitPct: also stop when session equity up X%
input double InpSessionLossPct       = 5.0;   // SessionLossPct: emergency stop when session equity down X%

input group "=== Dynamic Lot Sizing ==="
input int    InpSLHistoryTrades      = 20;    // SLHistoryTrades: look back N closed baskets
input double InpSLFloorPct           = 0.12;  // SLFloorPct: minimum SL % for lot calculation

//──────────────────────────────────────────────────────────────────────────────
// STATE
//──────────────────────────────────────────────────────────────────────────────
CTrade        g_trade;
CPositionInfo g_pos;
CSymbolInfo   g_sym;

datetime g_lastBarTime = 0;
bool     g_isNetting   = false;

// Basket state
ENUM_ORDER_TYPE g_basketDir      = ORDER_TYPE_BUY;
bool            g_basketOpen     = false;
double          g_basketAvgEntry = 0.0;
bool            g_partial1Done   = false;

// Session state
bool   g_sessionStopped          = false;
int    g_profitableBasketCount   = 0;   // only counts baskets closed WITH profit
double g_sessionStartEquity      = 0.0;
bool   g_immediateFirstDone      = false;

// Indicators
int g_hEMAFast = INVALID_HANDLE;
int g_hEMASlow = INVALID_HANDLE;
int g_hRSI     = INVALID_HANDLE;

// Dynamic lot sizing history
double g_changeHistory[];
int    g_historyIndex = 0;
int    g_historyCount = 0;

//──────────────────────────────────────────────────────────────────────────────
// UTILITY
//──────────────────────────────────────────────────────────────────────────────
int CountOurPositions()
{
   int n = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;
      n++;
   }
   return n;
}

double NormalizeLot(double lot)
{
   double step = g_sym.LotsStep();
   double minL = g_sym.LotsMin();
   double maxL = g_sym.LotsMax();
   if (step <= 0.0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, minL);
   lot = MathMin(lot, MathMin(maxL, InpMaxLot));
   return NormalizeDouble(lot, 2);
}

void PrintResult(const string ctx)
{
   PrintFormat("%s | rc=%u (%s) | deal=%llu | order=%llu",
               ctx, g_trade.ResultRetcode(),
               g_trade.ResultRetcodeDescription(),
               g_trade.ResultDeal(), g_trade.ResultOrder());
}

void CloseAllOurPositions(const string reason)
{
   ulong tickets[];
   int   total = 0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;
      ArrayResize(tickets, total + 1);
      tickets[total++] = g_pos.Ticket();
   }

   for (int j = 0; j < total; j++)
      for (int attempt = 0; attempt < 3; attempt++)
      {
         if (g_trade.PositionClose(tickets[j], InpMaxSlippagePoints)) break;
         Sleep(50);
      }

   PrintFormat("[Basket] CloseAll [%s] | %d positions", reason, total);
   g_basketOpen   = false;
   g_partial1Done = false;
}

// Close the N most-profitable positions (lock in gains at T1)
void CloseNBest(int n, const string reason)
{
   ulong  tickets[];
   double profits[];
   int    total = 0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;
      ArrayResize(tickets, total + 1);
      ArrayResize(profits, total + 1);
      tickets[total] = g_pos.Ticket();
      profits[total] = g_pos.Profit();
      total++;
   }

   // Sort descending — close best first
   for (int a = 0; a < total - 1; a++)
      for (int b = a + 1; b < total; b++)
         if (profits[a] < profits[b])
         {
            double tp = profits[a]; profits[a] = profits[b]; profits[b] = tp;
            ulong  tt = tickets[a]; tickets[a] = tickets[b]; tickets[b] = tt;
         }

   int closeCount = MathMin(n, total);
   for (int j = 0; j < closeCount; j++)
      for (int attempt = 0; attempt < 3; attempt++)
      {
         if (g_trade.PositionClose(tickets[j], InpMaxSlippagePoints)) break;
         Sleep(50);
      }

   PrintFormat("[Basket] CloseNBest=%d [%s] | %d remaining", closeCount, reason, total - closeCount);
}

// Move remaining open positions SL to their entry price (breakeven)
void SetRemainingToBreakeven()
{
   int moved = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;

      double sl = g_pos.PriceOpen();
      if (MathAbs(sl - g_pos.StopLoss()) < _Point) continue;

      if (g_trade.PositionModify(g_pos.Ticket(), sl, g_pos.TakeProfit()))
         moved++;
   }
   if (moved > 0)
      PrintFormat("[Basket] %d positions → breakeven SL", moved);
}

double GetDynamicThreshold()
{
   if (g_historyCount == 0) return InpSLFloorPct;
   double sum = 0.0;
   for (int i = 0; i < g_historyCount; i++) sum += g_changeHistory[i];
   return MathMax(sum / g_historyCount, InpSLFloorPct);
}

double CalcDynamicLot()
{
   double threshold = GetDynamicThreshold();
   g_sym.RefreshRates();
   double price = (g_sym.Ask() + g_sym.Bid()) / 2.0;
   if (price <= 0) return NormalizeLot(InpMinLot);

   int slPts = (int)MathRound(threshold / 100.0 * price / _Point);
   if (slPts <= 0) return NormalizeLot(InpMinLot);

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPct / 100.0;
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tickVal <= 0 || tickSize <= 0) return NormalizeLot(InpMinLot);

   double slMoney = (slPts * _Point / tickSize) * tickVal;
   if (slMoney <= 0) return NormalizeLot(InpMinLot);

   return NormalizeLot(MathMax(MathMin(riskMoney / slMoney, InpMaxLot), InpMinLot));
}

// Called after every profitable basket close and every tick
// Returns true = session still active, false = session done
bool CheckSessionStop()
{
   if (g_sessionStopped) return false;

   // N profitable baskets achieved → done
   if (g_profitableBasketCount >= InpProfitableBasketTarget)
   {
      PrintFormat("[Session] TARGET REACHED — %d profitable baskets closed. Done for this session.",
                  g_profitableBasketCount);
      CloseAllOurPositions("SessionTarget");
      g_sessionStopped = true;
      return false;
   }

   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double changePct  = (equity - g_sessionStartEquity) / g_sessionStartEquity * 100.0;

   // Equity profit target
   if (changePct >= InpSessionProfitPct)
   {
      PrintFormat("[Session] EQUITY TARGET +%.2f%% hit (%.2f → %.2f) — done.",
                  changePct, g_sessionStartEquity, equity);
      CloseAllOurPositions("SessionEquityProfit");
      g_sessionStopped = true;
      return false;
   }

   // Emergency equity loss limit
   if (changePct <= -InpSessionLossPct)
   {
      PrintFormat("[Session] LOSS LIMIT %.2f%% hit (%.2f → %.2f) — emergency stop.",
                  changePct, g_sessionStartEquity, equity);
      CloseAllOurPositions("SessionLossLimit");
      g_sessionStopped = true;
      return false;
   }

   return true;
}

bool CheckIndicatorFilter(ENUM_ORDER_TYPE dir)
{
   if (g_hEMAFast == INVALID_HANDLE || g_hEMASlow == INVALID_HANDLE || g_hRSI == INVALID_HANDLE)
      return true;

   double emaFast[1], emaSlow[1], rsiVal[1];
   if (CopyBuffer(g_hEMAFast, 0, 1, 1, emaFast) < 1) return false;
   if (CopyBuffer(g_hEMASlow, 0, 1, 1, emaSlow) < 1) return false;
   if (CopyBuffer(g_hRSI,     0, 1, 1, rsiVal)  < 1) return false;

   bool emaOK = (dir == ORDER_TYPE_BUY) ? (emaFast[0] > emaSlow[0])
                                        : (emaFast[0] < emaSlow[0]);
   bool rsiOK = (dir == ORDER_TYPE_BUY) ? (rsiVal[0] < InpRSIBuyMax)
                                        : (rsiVal[0] > InpRSISellMin);

   if (!emaOK)
      PrintFormat("Filter[EMA%d/EMA%d]: %.4f %s %.4f — skip %s",
                  InpEMAFast, InpEMASlow, emaFast[0],
                  (dir==ORDER_TYPE_BUY?"<":">"), emaSlow[0],
                  (dir==ORDER_TYPE_BUY?"BUY":"SELL"));
   if (!rsiOK)
      PrintFormat("Filter[RSI7=%.1f]: %s threshold — skip %s",
                  rsiVal[0],
                  (dir==ORDER_TYPE_BUY?"above buy-max":"below sell-min"),
                  (dir==ORDER_TYPE_BUY?"BUY":"SELL"));

   return emaOK && rsiOK;
}

//──────────────────────────────────────────────────────────────────────────────
// OpenBasket
//──────────────────────────────────────────────────────────────────────────────
void OpenBasket(ENUM_ORDER_TYPE dir, bool skipIndicators)
{
   if (g_sessionStopped)        return;
   if (g_basketOpen)            return;
   if (CountOurPositions() > 0) return;

   if (InpMaxSpreadPoints > 0)
   {
      g_sym.RefreshRates();
      int sp = (int)MathRound((g_sym.Ask() - g_sym.Bid()) / _Point);
      if (sp > InpMaxSpreadPoints)
      {
         PrintFormat("Spread %d > %d — basket skipped", sp, InpMaxSpreadPoints);
         return;
      }
   }

   if (!skipIndicators && !CheckIndicatorFilter(dir)) return;

   int    tradesTarget = g_isNetting ? 1 : MathMax(1, MathMin(InpBasketSize, 10));
   double lot          = CalcDynamicLot();
   int    opened       = 0;
   double entrySum     = 0.0;

   for (int t = 0; t < tradesTarget; t++)
   {
      g_sym.RefreshRates();
      double ask = g_sym.Ask();
      double bid = g_sym.Bid();
      bool   ok  = false;

      if (dir == ORDER_TYPE_BUY)
         ok = g_trade.Buy(lot, _Symbol, ask, 0, 0, "FTV6");
      else
         ok = g_trade.Sell(lot, _Symbol, bid, 0, 0, "FTV6");

      uint rc = g_trade.ResultRetcode();
      PrintResult(StringFormat("[%s] v6 %s t=%d/%d lot=%.2f",
                  _Symbol, (dir==ORDER_TYPE_BUY?"BUY":"SELL"), t+1, tradesTarget, lot));

      if (rc == TRADE_RETCODE_DONE)
      {
         opened++;
         entrySum += (dir == ORDER_TYPE_BUY) ? ask : bid;
      }
      else if (rc == TRADE_RETCODE_REQUOTE      ||
               rc == TRADE_RETCODE_PRICE_CHANGED ||
               rc == TRADE_RETCODE_PRICE_OFF)
      {
         Sleep(100);
         t--;
         if (t < -1) break;
      }
      else break;
   }

   if (opened > 0)
   {
      g_basketDir      = dir;
      g_basketOpen     = true;
      g_partial1Done   = false;
      g_basketAvgEntry = entrySum / opened;

      PrintFormat("[Basket OPEN] %s | %d/%d trades | %.2f lot | AvgEntry=%.5f | "
                  "HardSL=%.2f%% | ProfitClose: T1=%.2f%%(x%d) T2=%.2f%% | "
                  "Session: %d/%d profitable closes | %s",
                  (dir==ORDER_TYPE_BUY?"BUY":"SELL"),
                  opened, tradesTarget, lot, g_basketAvgEntry,
                  InpHardSLPct, InpTarget1Pct, InpPartial1Count, InpTarget2Pct,
                  g_profitableBasketCount, InpProfitableBasketTarget,
                  skipIndicators ? "IMMEDIATE (no filter)" : "FILTERED");
   }
}

//──────────────────────────────────────────────────────────────────────────────
// CheckBasketClose — every tick
//
// KEY RULE: basket only closes in profit (P&L > 0 AND move >= InpMinMovePct)
//           EXCEPTION: hard SL always fires regardless of profit
//──────────────────────────────────────────────────────────────────────────────
void CheckBasketClose()
{
   int total = CountOurPositions();
   if (total == 0) { g_basketOpen = false; g_partial1Done = false; return; }

   g_sym.RefreshRates();
   double ask = g_sym.Ask();
   double bid = g_sym.Bid();

   double totalProfit = 0.0;
   int    atTarget1   = 0;
   int    atTarget2   = 0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;

      double entryPrice = g_pos.PriceOpen();
      if (entryPrice <= 0) continue;

      double changePct = (g_pos.PositionType() == POSITION_TYPE_BUY)
                         ? (bid - entryPrice) / entryPrice * 100.0
                         : (entryPrice - ask) / entryPrice * 100.0;

      if (changePct >= InpTarget1Pct) atTarget1++;
      if (changePct >= InpTarget2Pct) atTarget2++;
      totalProfit += g_pos.Profit();
   }

   // ── HARD SL — fires regardless of profit (loss protection) ───────────────
   if (g_basketAvgEntry > 0 && InpHardSLPct > 0)
   {
      double currentPrice = (g_basketDir == ORDER_TYPE_BUY) ? bid : ask;
      double movePct      = (g_basketDir == ORDER_TYPE_BUY)
                            ? (currentPrice - g_basketAvgEntry) / g_basketAvgEntry * 100.0
                            : (g_basketAvgEntry - currentPrice) / g_basketAvgEntry * 100.0;

      if (movePct <= -InpHardSLPct)
      {
         PrintFormat("[Basket HardSL] moved %.3f%% vs threshold -%.3f%% | P&L=%.2f — STOP LOSS",
                     movePct, InpHardSLPct, totalProfit);
         CloseAllOurPositions("HardSL");
         // Hard SL is a loss — do NOT increment g_profitableBasketCount
         return;
      }
   }

   // ── PROFIT GATE — only proceed if basket is in profit ────────────────────
   // basket avg must have moved at least InpMinMovePct% AND total P&L > 0
   if (g_basketAvgEntry > 0)
   {
      double currentPrice = (g_basketDir == ORDER_TYPE_BUY) ? bid : ask;
      double avgMovePct   = (g_basketDir == ORDER_TYPE_BUY)
                            ? (currentPrice - g_basketAvgEntry) / g_basketAvgEntry * 100.0
                            : (g_basketAvgEntry - currentPrice) / g_basketAvgEntry * 100.0;

      bool basketProfitable = (totalProfit > 0.0 && avgMovePct >= InpMinMovePct);

      if (!basketProfitable)
         return; // NOT in profit — hold, do not close
   }

   // ── PHASE 2: All remaining hit Target2 → close all ───────────────────────
   if (g_partial1Done)
   {
      if (atTarget2 >= total)
      {
         PrintFormat("[Basket T2] All %d remaining hit %.2f%% | P&L=%.2f — PROFIT CLOSE",
                     total, InpTarget2Pct, totalProfit);
         CloseAllOurPositions("Target2");
      }
      return;
   }

   // ── PHASE 1: Partial close — N trades hit Target1 ────────────────────────
   int closeN = MathMin(InpPartial1Count, total);

   if (total > closeN && atTarget1 >= closeN)
   {
      PrintFormat("[Basket T1] %d/%d at %.2f%% | P&L=%.2f — closing %d, keeping %d at breakeven",
                  atTarget1, total, InpTarget1Pct, totalProfit, closeN, total - closeN);
      CloseNBest(closeN, "Target1-Partial");
      SetRemainingToBreakeven();
      g_partial1Done = true;
      return;
   }

   // If basket size == close count, close all at T1
   if (atTarget1 >= total)
   {
      PrintFormat("[Basket T1-All] All %d hit %.2f%% | P&L=%.2f — PROFIT CLOSE",
                  total, InpTarget1Pct, totalProfit);
      CloseAllOurPositions("Target1-All");
   }
}

//──────────────────────────────────────────────────────────────────────────────
// TrySeedEntry — fires on each new M1 bar
//──────────────────────────────────────────────────────────────────────────────
void TrySeedEntry()
{
   if (g_basketOpen)     return;
   if (g_sessionStopped) return;
   if (CountOurPositions() > 0) return;

   double c  = iClose(_Symbol, PERIOD_M1, 1);
   double o  = iOpen (_Symbol, PERIOD_M1, 1);
   double hi = iHigh (_Symbol, PERIOD_M1, 1);
   double lo = iLow  (_Symbol, PERIOD_M1, 1);

   if (c == o) return;

   ENUM_ORDER_TYPE dir = (c > o) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if (InpMinBodyPct > 0)
   {
      double range = hi - lo;
      double body  = MathAbs(c - o);
      if (range > 0 && (body / range) * 100.0 < (double)InpMinBodyPct)
      {
         PrintFormat("Skip[Body]: %.0f%% < %d%%", (body/range)*100.0, InpMinBodyPct);
         return;
      }
   }

   PrintFormat("Signal %s (O=%.5f C=%.5f) → EMA+RSI filter",
               (dir==ORDER_TYPE_BUY?"BUY":"SELL"), o, c);
   OpenBasket(dir, false);
}

//──────────────────────────────────────────────────────────────────────────────
// TryImmediateFirstTrade — fires once on tick 1 of EA run
//──────────────────────────────────────────────────────────────────────────────
void TryImmediateFirstTrade()
{
   if (g_immediateFirstDone) return;
   g_immediateFirstDone = true;

   if (!InpImmediateFirst) return;
   if (CountOurPositions() > 0 || g_basketOpen) return;

   double c = iClose(_Symbol, PERIOD_M1, 1);
   double o = iOpen (_Symbol, PERIOD_M1, 1);
   if (c == o) return;

   ENUM_ORDER_TYPE dir = (c > o) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   PrintFormat("[ImmediateFirst] EA started — firing %s basket NOW (emotion removed, no filter)",
               (dir==ORDER_TYPE_BUY?"BUY":"SELL"));
   OpenBasket(dir, true);
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

   g_hEMAFast = iMA(_Symbol, PERIOD_M1, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMASlow = iMA(_Symbol, PERIOD_M1, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hRSI     = iRSI(_Symbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);

   if (g_hEMAFast == INVALID_HANDLE || g_hEMASlow == INVALID_HANDLE || g_hRSI == INVALID_HANDLE)
   {
      Print("INIT FAILED: indicator handles");
      return INIT_FAILED;
   }

   g_sessionStartEquity    = AccountInfoDouble(ACCOUNT_EQUITY);
   g_sessionStopped        = false;
   g_profitableBasketCount = 0;
   g_immediateFirstDone    = false;

   ArrayResize(g_changeHistory, InpSLHistoryTrades);
   ArrayInitialize(g_changeHistory, 0.0);
   g_historyIndex = 0;
   g_historyCount = 0;

   PrintFormat("FlipTrail v6.10 | %s | Basket=%d | Risk=%.1f%% | "
               "EMA%d/EMA%d + RSI(%d) | "
               "Profit close: T1=%.2f%%(x%d) → T2=%.2f%% | HardSL=%.2f%% | MinMove=%.2f%% | "
               "Session stops after: %d profitable baskets OR +%.1f%% equity OR -%.1f%% equity | "
               "ImmediateFirst=%s | Magic=%lld",
               _Symbol,
               g_isNetting ? 1 : MathMin(InpBasketSize, 10),
               InpRiskPct,
               InpEMAFast, InpEMASlow, InpRSIPeriod,
               InpTarget1Pct, InpPartial1Count, InpTarget2Pct, InpHardSLPct, InpMinMovePct,
               InpProfitableBasketTarget, InpSessionProfitPct, InpSessionLossPct,
               InpImmediateFirst ? "ON" : "OFF",
               InpMagicNumber);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if (g_hEMAFast != INVALID_HANDLE) IndicatorRelease(g_hEMAFast);
   if (g_hEMASlow != INVALID_HANDLE) IndicatorRelease(g_hEMASlow);
   if (g_hRSI     != INVALID_HANDLE) IndicatorRelease(g_hRSI);

   PrintFormat("FlipTrail v6.10 deinit | %d profitable baskets this session | reason=%d",
               g_profitableBasketCount, reason);
}

void OnTick()
{
   if (!g_immediateFirstDone)
      TryImmediateFirstTrade();

   if (!g_sessionStopped)
      CheckSessionStop();

   datetime bt     = iTime(_Symbol, PERIOD_M1, 0);
   bool     newBar = (bt != 0 && bt != g_lastBarTime);
   if (newBar) g_lastBarTime = bt;

   CheckBasketClose();

   if (newBar && !g_sessionStopped)
      TrySeedEntry();
}

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

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
   if (entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;

   if (CountOurPositions() == 0)
   {
      // Determine if basket closed profitably
      bool wasProfit = false;
      if (g_basketAvgEntry > 0)
      {
         double closePrice = HistoryDealGetDouble(deal, DEAL_PRICE);
         double changePct  = (g_basketDir == ORDER_TYPE_BUY)
                             ? (closePrice - g_basketAvgEntry) / g_basketAvgEntry * 100.0
                             : (g_basketAvgEntry - closePrice) / g_basketAvgEntry * 100.0;
         double absChange  = MathAbs(changePct);

         // Record in dynamic SL history
         g_changeHistory[g_historyIndex % InpSLHistoryTrades] = absChange;
         g_historyIndex++;
         g_historyCount = MathMin(g_historyCount + 1, InpSLHistoryTrades);

         wasProfit = (changePct > 0);

         PrintFormat("Basket closed | change=%.3f%% [%s] | DynSL avg=%.3f%% | profitable baskets: %d → %d",
                     changePct,
                     wasProfit ? "PROFIT" : "LOSS (HardSL)",
                     GetDynamicThreshold(),
                     g_profitableBasketCount,
                     wasProfit ? g_profitableBasketCount + 1 : g_profitableBasketCount);
      }

      if (wasProfit)
      {
         g_profitableBasketCount++;
         // Check if we've hit our target of N profitable baskets
         CheckSessionStop();
      }

      g_basketOpen     = false;
      g_partial1Done   = false;
      g_basketAvgEntry = 0.0;

      if (!g_sessionStopped)
         PrintFormat("Ready for next signal | %d/%d profitable baskets done",
                     g_profitableBasketCount, InpProfitableBasketTarget);
   }
}
