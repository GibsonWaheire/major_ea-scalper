//+------------------------------------------------------------------+
//|  FlipTrail_EA_v5.mq5  v5.00                                      |
//|  HFT Basket Scalper — 24/5, No Session Restriction               |
//|                                                                   |
//|  MECHANICS                                                        |
//|  ─────────                                                        |
//|  Entry : M1 bar body direction → blast N trades as one basket    |
//|  Session: 24/5 — runs every bar, no time filter                  |
//|  Exit  : Bulk-close entire basket when targets are met           |
//|                                                                   |
//|  BASKET CLOSE CONDITIONS (checked every tick)                    |
//|  ──────────────────────────────────────────────                  |
//|  1. >= InpMinQualifiedPct% of trades have moved                  |
//|     >= InpMinChangePct% from entry in trade direction             |
//|  2. Total basket floating P&L >= InpMinBasketProfit (0=off)      |
//|  Both must be true simultaneously to trigger basket close.       |
//|                                                                   |
//|  NO SL. NO TP. NO TRAILING. NO PROTECTION.                      |
//|  GAMBLER GAMBIT — flipper by name, flipper by nature.            |
//|  Designed for hedging accounts. 24/5, high volatility.           |
//+------------------------------------------------------------------+
#property copyright "FlipTrail EA v5"
#property link      ""
#property version   "5.00"
#property description "FlipTrail v5.00: HFT basket scalper — 24/5 no session filter, bulk close on price target, no SL"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Basket ==="
input int    InpBasketSize        = 5;      // BasketSize: trades to open per signal (1–10)
input double InpRiskPct           = 10.0;   // RiskPct: % of equity risked per trade — scales lots automatically
input double InpMinLot            = 0.01;   // MinLot: broker floor (rarely hit at 10% risk)
input double InpMaxLot            = 100.0;  // MaxLot: ceiling — uncapped for full gambler mode
input long   InpMagicNumber       = 112235; // MagicNumber (v5 = 112235)
input int    InpMaxSlippagePoints = 30;     // MaxSlippagePoints
input int    InpMaxSpreadPoints   = 50;     // MaxSpreadPoints: skip if spread > this (50 = safe for XAUUSD)

input group "=== Dynamic SL ==="
input int    InpSLHistoryTrades   = 20;     // SLHistoryTrades: look back N closed trades for avg change
input double InpSLFloorPct        = 0.12;   // SLFloorPct: minimum SL threshold % (0.12% = slight breathing room)

input group "=== Basket Close Conditions ==="
input double InpMinChangePct      = 0.02;   // MinChangePct: min % price move from entry per trade to qualify
input double InpMinQualifiedPct   = 50.0;   // MinQualifiedPct: close basket when X% of trades are qualified
input double InpMinBasketProfit   = 0.0;    // MinBasketProfit: min total basket $ P&L to close (0=off)
//  Example at InpMinChangePct=0.02: XAUUSD @ 3900 → trade must move 0.78 pts ($0.78 per 0.01 lot)
//  Basket of 5 trades: closes when 3+ trades (60%) each moved 0.02%+ AND total P&L positive.

input group "=== Candle Body Filter ==="
input int    InpMinBodyPct        = 30;     // MinBodyPct: min body as % of bar range (0=off)

//──────────────────────────────────────────────────────────────────────────────
// STATE
//──────────────────────────────────────────────────────────────────────────────
CTrade        g_trade;
CPositionInfo g_pos;
CSymbolInfo   g_sym;

datetime        g_lastBarTime    = 0;
bool            g_isNetting      = false;
ENUM_ORDER_TYPE g_basketDir      = ORDER_TYPE_BUY;
bool            g_basketOpen     = false;
double          g_basketAvgEntry = 0.0;   // average entry price of current basket

// Dynamic SL history (circular buffer of last N basket % changes)
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
   {
      for (int attempt = 0; attempt < 3; attempt++)
      {
         if (g_trade.PositionClose(tickets[j], InpMaxSlippagePoints)) break;
         Sleep(50);
      }
   }

   PrintFormat("[Basket] CloseAll [%s] | %d positions closed", reason, total);
   g_basketOpen = false;
}

//──────────────────────────────────────────────────────────────────────────────
// GetDynamicThreshold
// Returns avg abs % change of last N baskets, floored at InpSLFloorPct.
//──────────────────────────────────────────────────────────────────────────────
double GetDynamicThreshold()
{
   if (g_historyCount == 0) return InpSLFloorPct;
   double sum = 0.0;
   for (int i = 0; i < g_historyCount; i++) sum += g_changeHistory[i];
   double avg = sum / g_historyCount;
   return MathMax(avg, InpSLFloorPct);
}

//──────────────────────────────────────────────────────────────────────────────
// CalcDynamicLot
// Risk-based lot using dynamic threshold as SL distance in price terms.
//──────────────────────────────────────────────────────────────────────────────
double CalcDynamicLot()
{
   double threshold = GetDynamicThreshold(); // % of price
   g_sym.RefreshRates();
   double price   = (g_sym.Ask() + g_sym.Bid()) / 2.0;
   if (price <= 0) return NormalizeLot(InpMinLot);

   int    slPts   = (int)MathRound(threshold / 100.0 * price / _Point);
   if (slPts <= 0) return NormalizeLot(InpMinLot);

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPct / 100.0;
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tickVal <= 0 || tickSize <= 0) return NormalizeLot(InpMinLot);

   double slMoney = (slPts * _Point / tickSize) * tickVal;
   if (slMoney <= 0) return NormalizeLot(InpMinLot);

   double lot = riskMoney / slMoney;
   lot = MathMax(lot, InpMinLot);
   lot = MathMin(lot, InpMaxLot);
   return NormalizeLot(lot);
}

//──────────────────────────────────────────────────────────────────────────────
// OpenBasket
// Fires InpBasketSize trades at market with no SL and no TP.
// On netting accounts: opens 1 large trade (basket behavior not possible).
//──────────────────────────────────────────────────────────────────────────────
void OpenBasket(ENUM_ORDER_TYPE dir)
{
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
         ok = g_trade.Buy(lot, _Symbol, ask, 0, 0, "FTV5-HFT");
      else
         ok = g_trade.Sell(lot, _Symbol, bid, 0, 0, "FTV5-HFT");

      uint rc = g_trade.ResultRetcode();
      PrintResult(StringFormat("[%s] HFT %s t=%d/%d lot=%.2f",
                  _Symbol, (dir==ORDER_TYPE_BUY?"BUY":"SELL"), t+1, tradesTarget, lot));

      if (rc == TRADE_RETCODE_DONE)
      {
         opened++;
         entrySum += (dir == ORDER_TYPE_BUY) ? g_sym.Ask() : g_sym.Bid();
      }
      else if (rc == TRADE_RETCODE_REQUOTE      ||
               rc == TRADE_RETCODE_PRICE_CHANGED ||
               rc == TRADE_RETCODE_PRICE_OFF)
      {
         Sleep(100);
         t--;
         if (t < -1) break; // one retry per slot
      }
      else break; // hard error — stop opening
   }

   if (opened > 0)
   {
      g_basketDir      = dir;
      g_basketOpen     = true;
      g_basketAvgEntry = (opened > 0) ? entrySum / opened : 0.0;
      double thresh    = GetDynamicThreshold();
      PrintFormat("[Basket OPEN] %s | %d/%d trades | %.2f lot each | DynSL=%.2f%% (floor=%.1f%%) | target: %.2f%% on %.0f%%+ trades",
                  (dir==ORDER_TYPE_BUY?"BUY":"SELL"), opened, tradesTarget, lot,
                  thresh, InpSLFloorPct, InpMinChangePct, InpMinQualifiedPct);
   }
}

//──────────────────────────────────────────────────────────────────────────────
// CheckBasketClose — called every tick
// Scans all basket positions for price change vs entry.
// Closes everything when InpMinQualifiedPct% of trades hit InpMinChangePct% move.
//──────────────────────────────────────────────────────────────────────────────
void CheckBasketClose()
{
   int total = CountOurPositions();
   if (total == 0) { g_basketOpen = false; return; }

   g_sym.RefreshRates();
   double ask = g_sym.Ask();
   double bid = g_sym.Bid();

   int    qualified   = 0;
   double totalProfit = 0.0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;

      double entryPrice = g_pos.PriceOpen();
      if (entryPrice <= 0) continue;

      double changePct;
      if (g_pos.PositionType() == POSITION_TYPE_BUY)
         changePct = (bid - entryPrice) / entryPrice * 100.0;
      else
         changePct = (entryPrice - ask) / entryPrice * 100.0;

      if (changePct >= InpMinChangePct) qualified++;
      totalProfit += g_pos.Profit();
   }

   double qualifiedRatio = (double)qualified / total * 100.0;
   bool   profitOK       = (InpMinBasketProfit <= 0.0 || totalProfit >= InpMinBasketProfit);

   // Profit exit — unchanged
   if (qualifiedRatio >= InpMinQualifiedPct && profitOK)
   {
      PrintFormat("[Basket Target] %d/%d qualified (%.0f%% >= %.0f%%) | P&L=%.2f — closing basket",
                  qualified, total, qualifiedRatio, InpMinQualifiedPct, totalProfit);
      CloseAllOurPositions("Target");
      return;
   }

   // Dynamic SL — close if basket moves against us by threshold%
   if (g_basketAvgEntry > 0)
   {
      double dynamicThresh = GetDynamicThreshold();
      double currentPrice  = (g_basketDir == ORDER_TYPE_BUY) ? bid : ask;
      double changePct     = (g_basketDir == ORDER_TYPE_BUY)
                             ? (currentPrice - g_basketAvgEntry) / g_basketAvgEntry * 100.0
                             : (g_basketAvgEntry - currentPrice) / g_basketAvgEntry * 100.0;

      if (changePct <= -dynamicThresh)
      {
         PrintFormat("[Basket DynSL] change=%.3f%% <= -%.3f%% | P&L=%.2f | history=%d trades — SL hit",
                     changePct, dynamicThresh, totalProfit, g_historyCount);
         CloseAllOurPositions("DynSL");
      }
   }
}

//──────────────────────────────────────────────────────────────────────────────
// TrySeedEntry — fires on each new M1 bar
// No session restriction — runs 24/5
//──────────────────────────────────────────────────────────────────────────────
void TrySeedEntry()
{
   if (g_basketOpen)            return;
   if (CountOurPositions() > 0) return;

   double c  = iClose(_Symbol, PERIOD_M1, 1);
   double o  = iOpen (_Symbol, PERIOD_M1, 1);
   double hi = iHigh (_Symbol, PERIOD_M1, 1);
   double lo = iLow  (_Symbol, PERIOD_M1, 1);

   if (c == o) return; // doji — no direction

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

   PrintFormat("HFT Signal %s (O=%.5f C=%.5f) → blast basket of %d",
               (dir==ORDER_TYPE_BUY?"BUY":"SELL"), o, c,
               g_isNetting ? 1 : MathMin(InpBasketSize, 10));
   OpenBasket(dir);
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

   if (g_isNetting)
      Print("WARNING: Netting account — basket opens as 1 trade. Use hedging for full basket behavior.");

   ArrayResize(g_changeHistory, InpSLHistoryTrades);
   ArrayInitialize(g_changeHistory, 0.0);
   g_historyIndex = 0;
   g_historyCount = 0;

   PrintFormat("FlipTrail v5.00 HFT | %s | Basket=%d | Risk=%.1f%% lot min=%.2f max=%.2f | "
               "Profit exit: %.2f%% on %.0f%%+ trades | "
               "DynSL: avg of last %d trades, floor=%.1f%% | "
               "24/5 — NO session filter | Magic=%lld",
               _Symbol,
               g_isNetting ? 1 : MathMin(InpBasketSize, 10),
               InpRiskPct, InpMinLot, InpMaxLot,
               InpMinChangePct, InpMinQualifiedPct,
               InpSLHistoryTrades, InpSLFloorPct,
               InpMagicNumber);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FlipTrail v5.00 deinit (reason=%d).", reason);
}

void OnTick()
{
   datetime bt     = iTime(_Symbol, PERIOD_M1, 0);
   bool     newBar = (bt != 0 && bt != g_lastBarTime);
   if (newBar) g_lastBarTime = bt;

   CheckBasketClose(); // every tick — instant exit when target hit

   if (newBar) TrySeedEntry();
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
   if (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
   {
      if (CountOurPositions() == 0)
      {
         // Record basket % change in history for dynamic SL calibration
         if (g_basketAvgEntry > 0)
         {
            double closePrice = HistoryDealGetDouble(deal, DEAL_PRICE);
            double changePct  = (g_basketDir == ORDER_TYPE_BUY)
                                ? (closePrice - g_basketAvgEntry) / g_basketAvgEntry * 100.0
                                : (g_basketAvgEntry - closePrice) / g_basketAvgEntry * 100.0;
            double absChange  = MathAbs(changePct);

            g_changeHistory[g_historyIndex % InpSLHistoryTrades] = absChange;
            g_historyIndex++;
            g_historyCount = MathMin(g_historyCount + 1, InpSLHistoryTrades);

            PrintFormat("Basket closed | change=%.3f%% | DynSL history updated: avg=%.3f%% (%d trades)",
                        changePct, GetDynamicThreshold(), g_historyCount);
         }

         g_basketOpen     = false;
         g_basketAvgEntry = 0.0;
         PrintFormat("Ready for next signal");
      }
   }
}
