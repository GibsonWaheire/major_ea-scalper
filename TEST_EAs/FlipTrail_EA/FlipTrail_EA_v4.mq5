//+------------------------------------------------------------------+
//|  FlipTrail_EA_v4.mq5  v4.00                                      |
//|  HFT Basket Scalper — Multi-Session · Variable Lots · Variable N  |
//|                                                                   |
//|  MECHANICS                                                        |
//|  ─────────                                                        |
//|  Entry : M1 bar body direction → blast N trades as one basket    |
//|  Session: Asian + London + NY (each independently toggled)       |
//|  Exit  : Bulk-close entire basket when targets are met           |
//|                                                                   |
//|  BASKET CLOSE CONDITIONS (checked every tick)                    |
//|  ──────────────────────────────────────────────                  |
//|  1. >= InpMinQualifiedPct% of trades moved >= InpMinChangePct%   |
//|     from entry in trade direction                                 |
//|  2. Total basket floating P&L >= InpMinBasketProfit (0=off)      |
//|  Both must be true simultaneously to trigger basket close.       |
//|                                                                   |
//|  V4 vs V2 CHANGES                                                |
//|  ─────────────────                                               |
//|  1. Sessions: Asian + London + NY (each independently toggled)   |
//|  2. Basket SIZE varies every signal (1–10, never same as prior)  |
//|  3. Lot MULTIPLIER varies every basket (20-step cycle, never     |
//|     same consecutive) — only broker max-lot applies, no user cap |
//|  4. Time-based exit for BLUES (profit side only):               |
//|     If basket is in profit and held >= InpMaxHoldSecs → close   |
//|     Then pause InpPauseSecs before next signal. DynSL untouched. |
//+------------------------------------------------------------------+
#property copyright "FlipTrail EA v4"
#property link      ""
#property version   "4.30"
#property description "FlipTrail v4.30: Trailing loss SL | Profit side unchanged | Engulf+M5 | Partials"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Basket ==="
input double InpRiskPct           = 10.0;   // RiskPct: % equity risked per trade (base lot calc)
input double InpMinLot            = 0.01;   // MinLot: broker floor
input long   InpMagicNumber       = 112244; // MagicNumber (v4 = 112244)
input int    InpMaxSlippagePoints = 30;     // MaxSlippagePoints
input int    InpMaxSpreadPoints   = 50;     // MaxSpreadPoints: skip if spread > this

input group "=== Dynamic SL (reference for trailing) ==="
input int    InpSLHistoryTrades   = 20;     // SLHistoryTrades: look back N closed baskets for % avg
input double InpSLFloorPct        = 0.1;   // SLFloorPct: minimum % threshold reference

input group "=== Trailing Loss SL (loss side only) ==="
input int    InpTrailArmSecs      = 10;    // TrailArmSecs: seconds loss must hold before SL arms
input double InpTrailLossCapPct   = 50.0;  // TrailLossCapPct: arm when loss >= X% of avg recent basket profit
input double InpTrailFactor       = 0.30;  // TrailFactor: how fast SL trails recovery (0.30 = 30% of each move)

input group "=== Basket Close Conditions ==="
input double InpMinChangePct      = 0.15;  // MinChangePct: min % price move per trade to qualify (must be > P3ChangePct to let all partials fire first)
input double InpMinQualifiedPct   = 50.0;  // MinQualifiedPct: % of basket trades that must qualify
input double InpMinBasketProfit   = 0.0;   // MinBasketProfit: min basket $ P&L to close (0=off)

input group "=== Candle Body Filter ==="
input int    InpMinBodyPct        = 30;    // MinBodyPct: min body % of bar range (0=off)

input group "=== Entry Precision ==="
input bool   InpUseEngulfing      = true;  // UseEngulfing: M1 bar body must be larger than prior bar body
input bool   InpUseM5Align        = true;  // UseM5Align: M1 direction must match M5 bar direction

input group "=== Partial Close (high lot only) ==="
input double InpPartialLotMin     = 0.5;   // PartialLotMin: partials only activate when lot >= this
input double InpP1ChangePct       = 0.02;  // P1ChangePct: % move to trigger 1st partial (30% of each pos)
input double InpP2ChangePct       = 0.05;  // P2ChangePct: % move to trigger 2nd partial (25% of remaining)
input double InpP3ChangePct       = 0.10;  // P3ChangePct: % move to trigger 3rd partial (10% of remaining)
// After all 3 partials the remaining volume follows the normal profit/DynSL exit.

input group "=== Time-Based Blue Exit ==="
input int    InpMaxHoldSecs       = 30;    // MaxHoldSecs: close basket if in profit after this many seconds (0=off)
input int    InpPauseSecs         = 90;    // PauseSecs: pause before next signal after a timed blue exit

input group "=== Sessions (server time) ==="
input bool   InpUseAsian          = true;  // UseAsian: trade Asian session
input int    InpAsianStart        = 0;     // AsianStart: server hour (default 00:00)
input int    InpAsianEnd          = 9;     // AsianEnd:   server hour (default 09:00)
input bool   InpUseLondon         = true;  // UseLondon: trade London session
input int    InpLondonStart       = 7;     // LondonStart: server hour (default 07:00)
input int    InpLondonEnd         = 13;    // LondonEnd:   server hour (default 13:00)
input bool   InpUseNY             = true;  // UseNY: trade New York session
input int    InpNYStart           = 13;    // NYStart: server hour (default 13:00)
input int    InpNYEnd             = 22;    // NYEnd:   server hour (default 22:00)

//──────────────────────────────────────────────────────────────────────────────
// LOT VARIATION TABLE
// 20-step cycle applied as a multiplier to the dynamic base lot.
// Range: 0.4x – 3.0x. No user cap — broker max-lot is the only hard ceiling.
// The cycle advances each basket and never repeats the same multiplier back-to-back.
//──────────────────────────────────────────────────────────────────────────────
double LOT_VARIANTS[20] = {1.0,  1.5,  0.6,  2.0,  0.75,
                            2.5,  0.45, 1.8,  1.2,  0.55,
                            3.0,  0.8,  1.4,  0.5,  2.2,
                            0.9,  1.7,  0.4,  2.8,  1.1};

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
double          g_basketAvgEntry = 0.0;

// Basket size variation
int g_lastBasketSize = 0;   // tracks previous size to prevent repeats

// Lot multiplier variation
int    g_lotVarIdx   = 0;   // current index into LOT_VARIANTS
double g_lastLotMult = -1.0;// last multiplier used (init to impossible value)

// Dynamic SL history (circular buffer of last N basket % changes)
double g_changeHistory[];
int    g_historyIndex = 0;
int    g_historyCount = 0;

// Time-based exit tracking
datetime g_basketOpenTime = 0;   // when current basket was opened
datetime g_pauseUntil     = 0;   // block new signals until this time

// Partial close state — reset each basket open
bool g_partial1Done    = false;
bool g_partial2Done    = false;
bool g_partial3Done    = false;
bool g_basketIsHighLot = false; // set once at open — survives volume reduction after partials

// Trailing loss SL state — loss side only, profit side untouched
bool     g_slArmed        = false;   // has the trailing SL been armed?
double   g_slPriceLevel   = 0.0;    // price level that triggers close if breached
double   g_slBestRecovery = 0.0;    // best recovery price seen since arming (for trailing)
datetime g_slBreachTime   = 0;      // when loss first exceeded cap (for time gate)

// Basket $ profit history — feeds the loss cap calculation
double g_profitHistory[];
int    g_profitHistIdx   = 0;
int    g_profitHistCount = 0;
double g_profitAccum     = 0.0;    // accumulates deal profits during basket lifecycle

//──────────────────────────────────────────────────────────────────────────────
// GetNextBasketSize
// Returns a pseudo-random basket size 1–10 that is never the same as the
// previous basket. On netting accounts, always returns 1.
//──────────────────────────────────────────────────────────────────────────────
int GetNextBasketSize()
{
   if (g_isNetting) return 1;

   int sz;
   int attempts = 0;
   do
   {
      sz = 1 + (int)(MathRand() % 10);
      attempts++;
   } while (sz == g_lastBasketSize && attempts < 50);

   g_lastBasketSize = sz;
   return sz;
}

//──────────────────────────────────────────────────────────────────────────────
// GetNextLotMultiplier
// Advances through LOT_VARIANTS[], skipping the current entry if it would
// produce the same multiplier as the previous basket. Never repeats.
//──────────────────────────────────────────────────────────────────────────────
double GetNextLotMultiplier()
{
   int    total    = 20;
   double mult;
   int    attempts = 0;

   do
   {
      mult = LOT_VARIANTS[g_lotVarIdx % total];
      g_lotVarIdx++;
      attempts++;
   } while (MathAbs(mult - g_lastLotMult) < 0.001 && attempts < total);

   g_lastLotMult = mult;
   return mult;
}

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
   double minL = MathMax(g_sym.LotsMin(), InpMinLot);
   double maxL = g_sym.LotsMax();   // broker ceiling only — no user cap in v4
   if (step <= 0.0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, minL);
   lot = MathMin(lot, maxL);
   return NormalizeDouble(lot, 2);
}

bool IsInSession(bool useIt, int startH, int endH, int h)
{
   if (!useIt) return false;
   if (startH <= endH)
      return (h >= startH && h < endH);
   return (h >= startH || h < endH); // handles midnight crossover
}

bool IsActiveSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   return IsInSession(InpUseAsian,  InpAsianStart,  InpAsianEnd,  h) ||
          IsInSession(InpUseLondon, InpLondonStart, InpLondonEnd, h) ||
          IsInSession(InpUseNY,     InpNYStart,     InpNYEnd,     h);
}

string ActiveSessionName()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if (IsInSession(InpUseAsian,  InpAsianStart,  InpAsianEnd,  h)) return "Asian";
   if (IsInSession(InpUseLondon, InpLondonStart, InpLondonEnd, h)) return "London";
   if (IsInSession(InpUseNY,     InpNYStart,     InpNYEnd,     h)) return "NY";
   return "?";
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
// PartialCloseBasket
// Closes pct% (0.0–1.0) of each position's current volume.
// Skips positions already too small to reduce further.
//──────────────────────────────────────────────────────────────────────────────
void PartialCloseBasket(double pct, const string label)
{
   double minVol  = g_sym.LotsMin();
   double volStep = g_sym.LotsStep();
   if (volStep <= 0) volStep = 0.01;

   int closed = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;

      double curVol    = g_pos.Volume();
      double closeVol  = NormalizeDouble(MathFloor(curVol * pct / volStep) * volStep, 2);
      if (closeVol < minVol) continue; // nothing left to close partially

      ulong ticket = g_pos.Ticket();
      for (int attempt = 0; attempt < 3; attempt++)
      {
         if (g_trade.PositionClosePartial(ticket, closeVol, InpMaxSlippagePoints)) { closed++; break; }
         Sleep(50);
      }
   }
   PrintFormat("[Partial %s] closed %.0f%% of each pos | %d positions reduced",
               label, pct * 100.0, closed);
}

//──────────────────────────────────────────────────────────────────────────────
// GetAvgRecentProfit
// Returns average $ profit of last N winning baskets.
// Used to set the loss cap: "don't lose more than X% of what you typically make."
// Falls back to 0 if no history yet (loss cap disabled until first wins recorded).
//──────────────────────────────────────────────────────────────────────────────
double GetAvgRecentProfit()
{
   if (g_profitHistCount == 0) return 0.0;
   double sum  = 0.0;
   int    wins = 0;
   for (int i = 0; i < g_profitHistCount; i++)
   {
      if (g_profitHistory[i] > 0) { sum += g_profitHistory[i]; wins++; }
   }
   if (wins == 0) return 0.0;
   return sum / wins;
}

//──────────────────────────────────────────────────────────────────────────────
// GetDynamicThreshold — avg abs % change of last N baskets, floored at SLFloorPct
//──────────────────────────────────────────────────────────────────────────────
double GetDynamicThreshold()
{
   if (g_historyCount == 0) return InpSLFloorPct;
   double sum = 0.0;
   for (int i = 0; i < g_historyCount; i++) sum += g_changeHistory[i];
   return MathMax(sum / g_historyCount, InpSLFloorPct);
}

//──────────────────────────────────────────────────────────────────────────────
// CalcBaseLot — risk-based lot using dynamic threshold as SL distance
//──────────────────────────────────────────────────────────────────────────────
double CalcBaseLot()
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

   double lot = (riskMoney / slMoney);
   lot = MathMax(lot, InpMinLot);
   return NormalizeLot(lot);
}

//──────────────────────────────────────────────────────────────────────────────
// OpenBasket
// 1. Picks a new basket size (1–10, not same as last)
// 2. Picks a new lot multiplier (from cycle, not same as last)
// 3. Opens all trades with the varied lot — no user cap, broker max only
//──────────────────────────────────────────────────────────────────────────────
void OpenBasket(ENUM_ORDER_TYPE dir)
{
   if (InpMaxSpreadPoints > 0)
   {
      g_sym.RefreshRates();
      int sp = (int)MathRound((g_sym.Ask() - g_sym.Bid()) / _Point);
      if (sp > InpMaxSpreadPoints)
      {
         PrintFormat("Spread %d > %d pts — basket skipped", sp, InpMaxSpreadPoints);
         return;
      }
   }

   int    basketSize = GetNextBasketSize();
   double lotMult    = GetNextLotMultiplier();
   double baseLot    = CalcBaseLot();
   double lot        = NormalizeLot(baseLot * lotMult);

   int    opened   = 0;
   double entrySum = 0.0;

   for (int t = 0; t < basketSize; t++)
   {
      g_sym.RefreshRates();
      double ask = g_sym.Ask();
      double bid = g_sym.Bid();
      bool   ok  = false;

      if (dir == ORDER_TYPE_BUY)
         ok = g_trade.Buy(lot, _Symbol, ask, 0, 0, "FTV4");
      else
         ok = g_trade.Sell(lot, _Symbol, bid, 0, 0, "FTV4");

      uint rc = g_trade.ResultRetcode();
      PrintResult(StringFormat("[%s] v4 %s t=%d/%d lot=%.2f (base=%.2f x%.2f)",
                  _Symbol, (dir == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  t + 1, basketSize, lot, baseLot, lotMult));

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
      else break; // hard error
   }

   if (opened > 0)
   {
      g_basketDir      = dir;
      g_basketOpen     = true;
      g_basketAvgEntry = entrySum / opened;
      g_basketOpenTime    = TimeCurrent();
      g_partial1Done      = false;
      g_partial2Done      = false;
      g_partial3Done      = false;
      g_basketIsHighLot   = (lot >= InpPartialLotMin);
      g_slArmed           = false;
      g_slPriceLevel      = 0.0;
      g_slBestRecovery    = 0.0;
      g_slBreachTime      = 0;
      g_profitAccum       = 0.0;
      PrintFormat("[Basket OPEN v4] %s | size=%d/%d | lot=%.2f (base=%.2f mult=%.2fx) | DynSL=%.2f%%",
                  (dir == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  opened, basketSize, lot, baseLot, lotMult,
                  GetDynamicThreshold());
   }
}

//──────────────────────────────────────────────────────────────────────────────
// CheckBasketClose — called every tick
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

   // Partial closes — only when basket lot >= InpPartialLotMin and avg entry known
   if (InpPartialLotMin > 0 && g_basketAvgEntry > 0)
   {
      g_sym.RefreshRates();
      double curPrice  = (g_basketDir == ORDER_TYPE_BUY) ? bid : ask;
      double movePct   = (g_basketDir == ORDER_TYPE_BUY)
                         ? (curPrice - g_basketAvgEntry) / g_basketAvgEntry * 100.0
                         : (g_basketAvgEntry - curPrice) / g_basketAvgEntry * 100.0;

      if (g_basketIsHighLot && movePct > 0)
      {
         if (!g_partial1Done && movePct >= InpP1ChangePct)
         {
            g_partial1Done = true;
            PartialCloseBasket(0.30, "P1-30%");
         }
         else if (g_partial1Done && !g_partial2Done && movePct >= InpP2ChangePct)
         {
            g_partial2Done = true;
            PartialCloseBasket(0.25, "P2-25%");
         }
         else if (g_partial2Done && !g_partial3Done && movePct >= InpP3ChangePct)
         {
            g_partial3Done = true;
            PartialCloseBasket(0.10, "P3-10%");
         }
      }
   }

   // Profit exit
   if (qualifiedRatio >= InpMinQualifiedPct && profitOK)
   {
      PrintFormat("[Basket Target] %d/%d qualified (%.0f%% >= %.0f%%) | P&L=%.2f — closing",
                  qualified, total, qualifiedRatio, InpMinQualifiedPct, totalProfit);
      CloseAllOurPositions("Target");
      return;
   }

   // Time-based blue exit — only fires when basket is in profit (blues)
   if (InpMaxHoldSecs > 0 && g_basketOpenTime > 0 && totalProfit > 0)
   {
      int heldSecs = (int)(TimeCurrent() - g_basketOpenTime);
      if (heldSecs >= InpMaxHoldSecs)
      {
         PrintFormat("[Basket TimeExit] held %ds >= %ds | P&L=%.2f (blues) — closing & pausing %ds",
                     heldSecs, InpMaxHoldSecs, totalProfit, InpPauseSecs);
         CloseAllOurPositions("TimeExit");
         g_pauseUntil     = TimeCurrent() + InpPauseSecs;
         g_basketOpenTime = 0;
         return;
      }
   }

   // ── TRAILING LOSS SL ── loss side only, profit side completely untouched ──
   if (totalProfit < 0 && g_basketAvgEntry > 0)
   {
      double currentPrice  = (g_basketDir == ORDER_TYPE_BUY) ? bid : ask;
      double avgProfit     = GetAvgRecentProfit();
      double lossCap       = (avgProfit > 0) ? avgProfit * InpTrailLossCapPct / 100.0 : 0.0;

      bool capBreached = (lossCap > 0 && MathAbs(totalProfit) >= lossCap);

      if (capBreached)
      {
         // Start time gate if not already started
         if (g_slBreachTime == 0) g_slBreachTime = TimeCurrent();

         int heldSecs = (int)(TimeCurrent() - g_slBreachTime);

         // Arm SL once time gate passes
         if (!g_slArmed && heldSecs >= InpTrailArmSecs)
         {
            g_slArmed        = true;
            g_slPriceLevel   = currentPrice;   // hard SL set at current price
            g_slBestRecovery = currentPrice;
            PrintFormat("[TrailSL ARMED] SL=%.5f | loss=%.2f | cap=%.2f | held=%ds",
                        g_slPriceLevel, totalProfit, lossCap, heldSecs);
         }
      }
      else
      {
         // Loss recovered above cap — reset time gate (but keep SL armed if already armed)
         if (!g_slArmed) g_slBreachTime = 0;
      }

      // SL management once armed
      if (g_slArmed)
      {
         bool priceImproved = (g_basketDir == ORDER_TYPE_BUY)
                              ? currentPrice > g_slBestRecovery
                              : currentPrice < g_slBestRecovery;

         if (priceImproved)
         {
            // Trail SL by InpTrailFactor of improvement — slowly follow recovery
            double improvement = MathAbs(currentPrice - g_slBestRecovery);
            double trail       = improvement * InpTrailFactor;

            if (g_basketDir == ORDER_TYPE_BUY)
               g_slPriceLevel += trail;
            else
               g_slPriceLevel -= trail;

            g_slBestRecovery = currentPrice;
            PrintFormat("[TrailSL TRAIL] SL → %.5f | recovery=%.5f | trailed=%.5f",
                        g_slPriceLevel, currentPrice, trail);
         }

         // SL triggered — price moved against us past armed level
         bool slHit = (g_basketDir == ORDER_TYPE_BUY)
                      ? bid <= g_slPriceLevel
                      : ask >= g_slPriceLevel;

         if (slHit)
         {
            PrintFormat("[TrailSL HIT] price=%.5f | SL=%.5f | loss=%.2f — closing",
                        currentPrice, g_slPriceLevel, totalProfit);
            CloseAllOurPositions("TrailSL");
            return;
         }
      }
   }
   else if (totalProfit >= 0 && g_slArmed)
   {
      // Basket fully recovered to profit — disarm SL, let profit exits handle it
      g_slArmed        = false;
      g_slPriceLevel   = 0.0;
      g_slBestRecovery = 0.0;
      g_slBreachTime   = 0;
      PrintFormat("[TrailSL DISARMED] basket recovered to profit — profit exits active");
   }
}

//──────────────────────────────────────────────────────────────────────────────
// TrySeedEntry — fires on each new M1 bar
//──────────────────────────────────────────────────────────────────────────────
void TrySeedEntry()
{
   if (!IsActiveSession())           return;
   if (g_basketOpen)                 return;
   if (CountOurPositions() > 0)      return;
   if (TimeCurrent() < g_pauseUntil)
   {
      // still in post-TimeExit pause — skip silently
      return;
   }

   double c  = iClose(_Symbol, PERIOD_M1, 1);
   double o  = iOpen (_Symbol, PERIOD_M1, 1);
   double hi = iHigh (_Symbol, PERIOD_M1, 1);
   double lo = iLow  (_Symbol, PERIOD_M1, 1);

   if (c == o) return; // doji — skip

   ENUM_ORDER_TYPE dir = (c > o) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if (InpMinBodyPct > 0)
   {
      double range = hi - lo;
      double body  = MathAbs(c - o);
      if (range > 0 && (body / range) * 100.0 < (double)InpMinBodyPct)
      {
         PrintFormat("Skip[Body]: %.0f%% < %d%%", (body / range) * 100.0, InpMinBodyPct);
         return;
      }
   }

   // Engulfing filter — current bar body must be larger than previous bar body
   if (InpUseEngulfing)
   {
      double prevO    = iOpen (_Symbol, PERIOD_M1, 2);
      double prevC    = iClose(_Symbol, PERIOD_M1, 2);
      double curBody  = MathAbs(c - o);
      double prevBody = MathAbs(prevC - prevO);
      if (curBody <= prevBody)
      {
         PrintFormat("Skip[Engulf]: body=%.5f <= prev=%.5f", curBody, prevBody);
         return;
      }
   }

   // M5 alignment — M1 direction must match current M5 bar direction
   if (InpUseM5Align)
   {
      double m5o = iOpen (_Symbol, PERIOD_M5, 1);
      double m5c = iClose(_Symbol, PERIOD_M5, 1);
      if (m5c == m5o)
      {
         PrintFormat("Skip[M5]: doji on M5");
         return;
      }
      bool m5Bull = (m5c > m5o);
      bool m1Bull = (dir == ORDER_TYPE_BUY);
      if (m5Bull != m1Bull)
      {
         PrintFormat("Skip[M5]: M1=%s conflicts M5=%s", m1Bull?"BUY":"SELL", m5Bull?"BUY":"SELL");
         return;
      }
   }

   PrintFormat("[%s] Signal %s (O=%.5f C=%.5f)",
               ActiveSessionName(), (dir == ORDER_TYPE_BUY ? "BUY" : "SELL"), o, c);
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
   if (g_isNetting)
      Print("WARNING: Netting account — basket size forced to 1.");

   ArrayResize(g_changeHistory, InpSLHistoryTrades);
   ArrayInitialize(g_changeHistory, 0.0);
   g_historyIndex = 0;
   g_historyCount = 0;

   ArrayResize(g_profitHistory, InpSLHistoryTrades);
   ArrayInitialize(g_profitHistory, 0.0);
   g_profitHistIdx   = 0;
   g_profitHistCount = 0;

   MathSrand((uint)TimeCurrent()); // seed RNG for basket size selection

   string sessInfo = "";
   if (InpUseAsian)  sessInfo += StringFormat("Asian(%d:00-%d:00) ", InpAsianStart,  InpAsianEnd);
   if (InpUseLondon) sessInfo += StringFormat("London(%d:00-%d:00) ", InpLondonStart, InpLondonEnd);
   if (InpUseNY)     sessInfo += StringFormat("NY(%d:00-%d:00)",      InpNYStart,     InpNYEnd);
   if (sessInfo == "") sessInfo = "NONE — EA will not trade!";

   PrintFormat("FlipTrail v4.30 | %s | Risk=%.1f%% | Sessions: %s | "
               "Basket: 1-10 (variable, no repeat) | "
               "Lots: base x [0.4..3.0] cycle (no cap, no repeat) | "
               "TrailSL: arm after %ds + loss >= %.0f%% avg profit | trail=%.0f%% | "
               "TimeExit blues: %ds hold → %ds pause | Magic=%lld",
               _Symbol, InpRiskPct, sessInfo,
               InpTrailArmSecs, InpTrailLossCapPct, InpTrailFactor * 100.0,
               InpMaxHoldSecs, InpPauseSecs, InpMagicNumber);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FlipTrail v4.30 deinit (reason=%d).", reason);
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
      // Accumulate deal profit across all closing deals (includes partials + final)
      g_profitAccum += HistoryDealGetDouble(deal, DEAL_PROFIT);

      if (CountOurPositions() == 0)
      {
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

            // Record $ profit for trailing SL loss cap calculation
            g_profitHistory[g_profitHistIdx % InpSLHistoryTrades] = g_profitAccum;
            g_profitHistIdx++;
            g_profitHistCount = MathMin(g_profitHistCount + 1, InpSLHistoryTrades);

            PrintFormat("Basket closed | change=%.3f%% | P&L=%.2f | AvgWin=%.2f | history=%d",
                        changePct, g_profitAccum, GetAvgRecentProfit(), g_profitHistCount);
         }

         g_basketOpen     = false;
         g_basketAvgEntry = 0.0;
         g_profitAccum    = 0.0;
         PrintFormat("Ready for next signal");
      }
   }
}
