//+------------------------------------------------------------------+
//|  FlipTrail_EA_v2.mq5  v2.60                                      |
//|  HFT Basket Scalper — New York Session Only                      |
//|                                                                   |
//|  MECHANICS                                                        |
//|  ─────────                                                        |
//|  Entry : M1 bar body direction → blast N trades as one basket    |
//|  Session: NY only (default 13:00–22:00 server time)              |
//|  Exit  : Bulk-close entire basket when targets are met           |
//|                                                                   |
//|  BASKET CLOSE CONDITIONS (checked every tick)                    |
//|  ──────────────────────────────────────────────                  |
//|  1. >= InpMinQualifiedPct% of trades have moved                  |
//|     >= InpMinChangePct% from entry in trade direction             |
//|  2. Total basket floating P&L >= InpMinBasketProfit (0=off)      |
//|  Both must be true simultaneously to trigger basket close.       |
//|                                                                   |
//|  v2.50 ADDITIONS (faster profit exit + progressive SL):         |
//|  1. REVERSAL PARTIAL: track peak avg move %; if price pulls      |
//|     back InpReversalPullbackPct% from peak while in profit       |
//|     → close N best + tighten SL on remaining.                   |
//|  2. TIME PARTIAL: if basket open >= InpTimeExitBars M1 bars      |
//|     AND avg move >= InpTimeExitMinPct% → close N best.          |
//|  3. PROGRESSIVE SL LOCK: after each partial close SL moves      |
//|     to entry + InpBELockPct% (TP1) or InpSL2LockPct% (rev).    |
//|                                                                   |
//|  v2.60 ADDITIONS (entry quality + fast profits + protection):   |\n//|  1. CONFIRM CANDLES: require N consecutive same-direction M1    |\n//|     candles before entry — rejects chop, enters on momentum.   |\n//|  2. FLASH TP: instant full-basket close on first tick avg move  |\n//|     >= InpFlashTPPct% — millisecond profit capture.            |\n//|  3. REPEATING PARTIALS: partial closes repeat every new bar     |\n//|     (per-bar gate replaces one-time flags).                    |\n//|  4. DAILY CIRCUIT BREAKERS: session equity snapshot + daily    |\n//|     loss % limit + optional basket cap per session.            |\n//|                                                                   |\n//|  v2.30 FIXES (the 20% account-wipe problem):                    |
//|  1. BASKET RISK: RiskPct% = total budget for whole basket.      |
//|     Divided by BasketSize per trade → max exposure = RiskPct%.  |
//|  2. HARD SL at broker on every order (InpSLFloorPct% from       |
//|     entry). Protects against gaps and disconnections.           |
//|  3. R:R fix: InpMinChangePct default raised to 0.13% to sit    |
//|     above SLFloorPct (0.12%). Positive expected value.         |
//|  4. CONSECUTIVE LOSS PAUSE: after N SL hits in a row, skip     |
//|     X bars before re-entering. Prevents spiral losses.         |
//+------------------------------------------------------------------+
#property copyright "FlipTrail EA v2"
#property link      ""
#property version   "2.60"
#property description "FlipTrail v2.60: multi-candle confirm + flash TP + daily circuit breakers + repeating partials"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Basket ==="
input int    InpBasketSize        = 5;      // BasketSize: trades to open per signal (1–10)
input double InpRiskPct           = 10.0;   // RiskPct: % of equity for the WHOLE basket (divided per trade — not multiplied)
input double InpMinLot            = 0.01;   // MinLot: broker floor
input double InpMaxLot            = 5.0;    // MaxLot: ceiling per trade
input long   InpMagicNumber       = 112234; // MagicNumber (v2 = 112234)
input int    InpMaxSlippagePoints = 30;     // MaxSlippagePoints
input int    InpMaxSpreadPoints   = 0;      // MaxSpreadPoints: skip if spread > this (0=off — required for Deriv synthetics)

input group "=== Dynamic SL ==="
input int    InpSLHistoryTrades   = 20;     // SLHistoryTrades: look back N closed trades for avg change
input double InpSLFloorPct        = 0.12;   // SLFloorPct: minimum SL threshold % (0.12% = slight breathing room)

input group "=== Basket Close Conditions ==="
input double InpMinChangePct      = 0.13;   // MinChangePct: min % price move from entry per trade to qualify (keep ≥ SLFloorPct for positive R:R)
input double InpMinQualifiedPct   = 50.0;   // MinQualifiedPct: close basket when X% of trades are qualified
input double InpMinBasketProfit   = 0.0;    // MinBasketProfit: min total basket $ P&L to close (0=off)
input double InpFlashTPPct        = 0.07;   // FlashTPPct: instant close ALL when avg move hits this % on ANY tick (0=off). Set < MinChangePct for a fast scalp exit before full TP.
//  R:R: InpMinChangePct (TP) vs InpSLFloorPct (SL). Default 0.13/0.12 ≈ 1.08:1.
//  At 80% win rate: E[V] = 0.8×0.13% − 0.2×0.12% = +0.08% per basket (was −0.008% in v2.20).

input group "=== Candle Body Filter ==="
input int    InpMinBodyPct        = 30;     // MinBodyPct: min body as % of bar range (0=off)
input int    InpConfirmCandles    = 2;      // ConfirmCandles: require N consecutive same-direction M1 candles before entry (1=any single candle, 2=momentum confirmed)

input group "=== New York Session ==="
input int    InpNYStartHour       = 13;     // NYStartHour: server time (13 = NY open / London overlap)
input int    InpNYEndHour         = 22;     // NYEndHour: server time (22 = NY close)
//  High volatility window: 13:00–16:00 (NY open overlap) and 14:30–16:00 (US data releases).
//  EA runs the full window. Adjust hours to focus on specific spikes.

input group "=== Consecutive Loss Pause ==="
input int    InpMaxConsecLosses   = 2;      // MaxConsecLosses: SL hits in a row before pause (0=off)
input int    InpPauseBars         = 10;     // PauseBars: M1 bars to skip after consecutive losses hit

input group "=== Daily Circuit Breakers ==="
input double InpMaxDailyLossPct   = 5.0;   // MaxDailyLossPct: halt for the day if equity drops this % from NY-session-open equity (0=off)
input int    InpMaxDailyBaskets   = 0;     // MaxDailyBaskets: max baskets per NY session (0=off)

input group "=== Partial Close — Profit ==="
input double InpPartialTPPct      = 0.08;   // PartialTPPct: avg basket move % to trigger partial profit close
input int    InpPartialTPCount    = 2;      // PartialTPCount: how many trades to close at partial TP

input group "=== Reversal Partial Close ==="
input double InpReversalPullbackPct = 0.04; // ReversalPullbackPct: % pullback from peak avg move to trigger partial (0=off)
input int    InpReversalCount       = 2;    // ReversalCount: trades to close on reversal signal

input group "=== Time-Based Partial Close ==="
input int    InpTimeExitBars      = 8;      // TimeExitBars: M1 bars open before time exit check (0=off)
input double InpTimeExitMinPct    = 0.05;   // TimeExitMinPct: min avg move % required for time exit
input int    InpTimeExitCount     = 2;      // TimeExitCount: trades to close on time exit

input group "=== Progressive SL Lock After Partial ==="
input double InpBELockPct         = 0.02;   // BELockPct: SL lock % above entry after TP1 or time exit (0=exact BE)
input double InpSL2LockPct        = 0.04;   // SL2LockPct: SL lock % above entry after reversal partial (tighter)

input group "=== Partial Close — Loss Management ==="
input double InpLossWatchPct      = 0.08;   // LossWatchPct: adverse avg move % to start watching
input int    InpLossPartialCount  = 2;      // LossPartialCount: worst trades to cut when no reversal
input int    InpDojiBodyPct       = 25;     // DojiBodyPct: max body % of range to qualify as doji (reversal hold)

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

// Consecutive loss pause
int g_consecLosses  = 0;
int g_pauseBarsLeft = 0;

// Daily circuit breakers — reset at each NY session open
double   g_sessionStartEquity = 0.0;  // equity snapshot when NY session opened today
int      g_sessionBaskets     = 0;    // baskets opened this NY session
datetime g_sessionDate        = 0;    // date of the current session snapshot

// Per-bar partial gate — one partial close per M1 bar prevents same-tick re-fire
// Remaining positions are re-evaluated every new bar using the same rules
datetime g_lastPartialBar  = 0;     // bar time of last partial close
bool     g_lossPartialDone = false; // loss cut (one-time per basket)

// Peak tracking — highest avg move % seen during this basket
double g_peakMovePct   = 0.0;

// Time tracking — M1 bars elapsed since basket opened
int    g_basketBarCount = 0;

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

bool IsNYSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if (InpNYStartHour <= InpNYEndHour)
      return (h >= InpNYStartHour && h < InpNYEndHour);
   return (h >= InpNYStartHour || h < InpNYEndHour);
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
   g_basketOpen       = false;
   g_lastPartialBar   = 0;
   g_lossPartialDone  = false;
   g_peakMovePct      = 0.0;
   g_basketBarCount   = 0;
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

   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   int    numTrades   = g_isNetting ? 1 : MathMax(1, MathMin(InpBasketSize, 10));
   double riskMoney   = (equity * InpRiskPct / 100.0) / numTrades; // basket risk split equally per trade
   double tickVal     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
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
// Fires InpBasketSize trades at market with a hard broker-level SL on each.
// SL price = entry ± InpSLFloorPct%. Protects against gaps and disconnections.
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

      // Hard SL at broker level: SL distance = InpSLFloorPct% of price.
      // If broker rejects (10016 invalid stops — common on Deriv synthetics with
      // large minimum stop levels), retry without SL. Soft DynSL in CheckBasketClose
      // handles the exit in that case.
      double slDist  = ask * InpSLFloorPct / 100.0;
      double slPrice;
      if (dir == ORDER_TYPE_BUY)
      {
         slPrice = NormalizeDouble(ask - slDist, _Digits);
         ok = g_trade.Buy(lot, _Symbol, ask, slPrice, 0, "FTV2-HFT");
      }
      else
      {
         slDist  = bid * InpSLFloorPct / 100.0;
         slPrice = NormalizeDouble(bid + slDist, _Digits);
         ok = g_trade.Sell(lot, _Symbol, bid, slPrice, 0, "FTV2-HFT");
      }

      // Retry without SL if broker rejects the stop level
      if (g_trade.ResultRetcode() == TRADE_RETCODE_INVALID_STOPS)
      {
         PrintFormat("[SL Fallback] Broker rejected hard SL=%.5f — retrying without SL (soft DynSL active)", slPrice);
         slPrice = 0.0;
         if (dir == ORDER_TYPE_BUY)
            ok = g_trade.Buy(lot, _Symbol, ask, 0, 0, "FTV2-HFT");
         else
            ok = g_trade.Sell(lot, _Symbol, bid, 0, 0, "FTV2-HFT");
      }

      uint rc = g_trade.ResultRetcode();
      PrintResult(StringFormat("[%s] HFT %s t=%d/%d lot=%.2f SL=%.5f",
                  _Symbol, (dir==ORDER_TYPE_BUY?"BUY":"SELL"), t+1, tradesTarget, lot, slPrice));

      if (rc == TRADE_RETCODE_DONE)
      {
         opened++;
         entrySum += g_trade.ResultPrice(); // actual fill price — not re-read ask/bid which may have moved
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
      g_basketAvgEntry = entrySum / opened;
      g_peakMovePct      = 0.0;
      g_basketBarCount   = 0;
      g_lastPartialBar   = 0;
      g_lossPartialDone  = false;
      g_sessionBaskets++;
      double thresh    = GetDynamicThreshold();
      PrintFormat("[Basket OPEN] %s | %d/%d trades | %.2f lot each | DynSL=%.2f%% (floor=%.1f%%) | target: %.2f%% on %.0f%%+ trades | session basket %d/%d",
                  (dir==ORDER_TYPE_BUY?"BUY":"SELL"), opened, tradesTarget, lot,
                  thresh, InpSLFloorPct, InpMinChangePct, InpMinQualifiedPct,
                  g_sessionBaskets, InpMaxDailyBaskets > 0 ? InpMaxDailyBaskets : 9999);
   }
}

//──────────────────────────────────────────────────────────────────────────────
// CloseNBest — close N most profitable positions (lock in gains)
//──────────────────────────────────────────────────────────────────────────────
void CloseNBest(int n)
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

   // Sort descending — best P&L first
   for (int a = 0; a < total - 1; a++)
      for (int b = a + 1; b < total; b++)
         if (profits[b] > profits[a])
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
   PrintFormat("[CloseNBest] %d positions closed", closeCount);
}

//──────────────────────────────────────────────────────────────────────────────
// CloseNWorst — close N least profitable positions (cut dead weight)
//──────────────────────────────────────────────────────────────────────────────
void CloseNWorst(int n)
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

   // Sort ascending — worst P&L first
   for (int a = 0; a < total - 1; a++)
      for (int b = a + 1; b < total; b++)
         if (profits[b] < profits[a])
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
   PrintFormat("[CloseNWorst] %d positions cut", closeCount);
}

//──────────────────────────────────────────────────────────────────────────────
// SetRemainingToLock
// Move SL on all open positions to entry ± lockPct% in profit direction.
// lockPct=0 → exact breakeven. lockPct=0.02 → 0.02% profit buffer locked in.
// Only moves SL in the improving direction — never pulls back a tighter SL.
//──────────────────────────────────────────────────────────────────────────────
void SetRemainingToLock(double lockPct)
{
   int moved = 0;

   // Broker minimum stop distance — SL must be at least this many points from current price
   long   stopLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stopLevelDist = stopLevelPts * _Point;

   g_sym.RefreshRates();

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!g_pos.SelectByIndex(i))                 continue;
      if (g_pos.Magic()  != (ulong)InpMagicNumber) continue;
      if (g_pos.Symbol() != _Symbol)               continue;

      double entry    = g_pos.PriceOpen();
      double lockDist = entry * lockPct / 100.0;
      double newSL;

      if (g_pos.PositionType() == POSITION_TYPE_BUY)
      {
         newSL = NormalizeDouble(entry + lockDist, _Digits);
         // Enforce broker minimum stop distance from current bid
         double minAllowed = g_sym.Bid() - stopLevelDist;
         if (newSL > minAllowed)
         {
            PrintFormat("[LockSL] BUY ticket=%llu newSL=%.5f violates stop level (min=%.5f) — clamping",
                        g_pos.Ticket(), newSL, minAllowed);
            newSL = NormalizeDouble(minAllowed, _Digits);
         }
         // Only move SL if it improves (moves up) — never pull back a tighter SL
         if (g_pos.StopLoss() >= newSL - _Point) continue;
      }
      else
      {
         newSL = NormalizeDouble(entry - lockDist, _Digits);
         // Enforce broker minimum stop distance from current ask
         double minAllowed = g_sym.Ask() + stopLevelDist;
         if (newSL < minAllowed)
         {
            PrintFormat("[LockSL] SELL ticket=%llu newSL=%.5f violates stop level (min=%.5f) — clamping",
                        g_pos.Ticket(), newSL, minAllowed);
            newSL = NormalizeDouble(minAllowed, _Digits);
         }
         // Only move SL if it improves (moves down) — never pull back a tighter SL
         if (g_pos.StopLoss() > 0 && g_pos.StopLoss() <= newSL + _Point) continue;
      }

      if (g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit()))
         moved++;
      else
         PrintFormat("[LockSL] FAILED ticket=%llu newSL=%.5f rc=%u (%s)",
                     g_pos.Ticket(), newSL, g_trade.ResultRetcode(),
                     g_trade.ResultRetcodeDescription());
   }
   if (moved > 0)
      PrintFormat("[LockSL] %d positions SL locked at entry+%.2f%%", moved, lockPct);
}

//──────────────────────────────────────────────────────────────────────────────
// CheckBasketClose — called every tick
// Priority order:
//   1. Dynamic SL (loss protection)         — close all
//   2. Peak update
//   3. Reversal partial (peak pullback)     — close N best + tighten SL
//   4. Time-based partial                   — close N best + lock SL
//   5. Profit partial TP1                   — close N best + lock SL
//   6. Loss management (doji hold / cut)    — cut N worst
//   7. Full profit exit                     — close all
//──────────────────────────────────────────────────────────────────────────────
void CheckBasketClose()
{
   int total = CountOurPositions();
   if (total == 0) { g_basketOpen = false; g_lastPartialBar = 0; g_lossPartialDone = false; return; }

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

   // Basket avg move from avg entry price
   double avgMovePct = 0.0;
   if (g_basketAvgEntry > 0)
   {
      double currentPrice = (g_basketDir == ORDER_TYPE_BUY) ? bid : ask;
      avgMovePct = (g_basketDir == ORDER_TYPE_BUY)
                   ? (currentPrice - g_basketAvgEntry) / g_basketAvgEntry * 100.0
                   : (g_basketAvgEntry - currentPrice) / g_basketAvgEntry * 100.0;
   }

   // ── 0. FLASH TP — instant full-basket close on first tick price crosses threshold ──
   // Fires before every other check so tiny favourable moves are captured immediately.
   if (InpFlashTPPct > 0 && g_basketAvgEntry > 0 && avgMovePct >= InpFlashTPPct)
   {
      PrintFormat("[Flash TP] move=+%.4f%% >= +%.4f%% | P&L=%.2f — instant basket close",
                  avgMovePct, InpFlashTPPct, totalProfit);
      CloseAllOurPositions("FlashTP");
      return;
   }

   // ── 1. DYNAMIC SL — soft backup (broker hard SL is primary) ──────────────
   if (g_basketAvgEntry > 0 && avgMovePct <= -GetDynamicThreshold())
   {
      PrintFormat("[Basket DynSL] move=%.3f%% <= -%.3f%% | P&L=%.2f — SL hit",
                  avgMovePct, GetDynamicThreshold(), totalProfit);
      CloseAllOurPositions("DynSL");
      return;
   }

   // ── 2. PEAK TRACKING ─────────────────────────────────────────────────────
   if (avgMovePct > g_peakMovePct)
      g_peakMovePct = avgMovePct;

   // ── 3. REVERSAL PARTIAL — peak pullback detection ─────────────────────────
   // Fires when: (a) not yet done, (b) peak reached meaningful profit,
   // (c) price has pulled back >= ReversalPullbackPct% from that peak,
   // (d) still above zero (don't cut a basket that's already gone negative).
   if (InpReversalPullbackPct > 0 &&
       g_lastPartialBar != g_lastBarTime &&   // one partial per bar
       g_peakMovePct >= InpPartialTPPct &&
       (g_peakMovePct - avgMovePct) >= InpReversalPullbackPct &&
       avgMovePct > 0 &&        // price is still above avg entry — don't cut a losing basket
       total > InpReversalCount)
   {
      PrintFormat("[Reversal Partial] peak=+%.3f%% pulled back to +%.3f%% (Δ=%.3f%% >= %.3f%%) | P&L=%.2f — closing %d best + tighten SL to +%.2f%%",
                  g_peakMovePct, avgMovePct, g_peakMovePct - avgMovePct,
                  InpReversalPullbackPct, totalProfit, InpReversalCount, InpSL2LockPct);
      CloseNBest(InpReversalCount);
      SetRemainingToLock(InpSL2LockPct);
      g_peakMovePct    = avgMovePct;   // reset peak — next reversal needs a fresh high
      g_lastPartialBar = g_lastBarTime;
      return;
   }

   // ── 4. TIME-BASED PARTIAL ─────────────────────────────────────────────────
   // Fires when basket has lingered >= InpTimeExitBars and is in profit.
   if (InpTimeExitBars > 0 &&
       g_lastPartialBar != g_lastBarTime &&   // one partial per bar
       g_basketBarCount >= InpTimeExitBars &&
       avgMovePct >= InpTimeExitMinPct &&  // price move % is the gate — not broker floating P&L (spread distorts it)
       total > InpTimeExitCount)
   {
      PrintFormat("[Time Partial] %d bars open | move=+%.3f%% >= +%.3f%% | P&L=%.2f — closing %d best + lock SL to +%.2f%%",
                  g_basketBarCount, avgMovePct, InpTimeExitMinPct,
                  totalProfit, InpTimeExitCount, InpBELockPct);
      CloseNBest(InpTimeExitCount);
      SetRemainingToLock(InpBELockPct);
      g_lastPartialBar = g_lastBarTime;
      return;
   }

   // ── 5. PARTIAL CLOSE — PROFIT (TP1) ───────────────────────────────────────
   // When basket has moved +InpPartialTPPct% in our favour: close best N trades,
   // lock remaining SL at entry + InpBELockPct%. Fires once per basket.
   if (g_lastPartialBar != g_lastBarTime &&
       avgMovePct >= InpPartialTPPct &&
       total > InpPartialTPCount)
   {
      PrintFormat("[Partial TP1] move=+%.3f%% >= +%.3f%% | P&L=%.2f — closing %d best, rest → lock SL +%.2f%%",
                  avgMovePct, InpPartialTPPct, totalProfit, InpPartialTPCount, InpBELockPct);
      CloseNBest(InpPartialTPCount);
      SetRemainingToLock(InpBELockPct);
      g_lastPartialBar = g_lastBarTime;
      return;
   }

   // ── 6. LOSS MANAGEMENT — doji hold / no-reversal cut ─────────────────────
   // Fires once per basket when basket is down InpLossWatchPct%.
   // Reads the last closed M1 bar to determine market intent.
   if (!g_lossPartialDone && avgMovePct <= -InpLossWatchPct && totalProfit < 0)
   {
      double c     = iClose(_Symbol, PERIOD_M1, 1);
      double o     = iOpen (_Symbol, PERIOD_M1, 1);
      double hi    = iHigh (_Symbol, PERIOD_M1, 1);
      double lo    = iLow  (_Symbol, PERIOD_M1, 1);
      double range = hi - lo;
      double body  = MathAbs(c - o);

      bool isDoji      = (range > 0 && (body / range) * 100.0 < (double)InpDojiBodyPct);
      bool isAgainstUs = (g_basketDir == ORDER_TYPE_BUY) ? (c < o) : (c > o);

      if (isDoji)
      {
         // Indecision candle — possible reversal, hold the basket
         PrintFormat("[Loss Hold] Doji (body=%.0f%% < %d%%) — holding, watching for reversal | move=%.3f%% | P&L=%.2f",
                     (range > 0 ? body / range * 100.0 : 0.0), InpDojiBodyPct, avgMovePct, totalProfit);
         // Note: g_lossPartialDone stays false so we re-check next bar
      }
      else if (isAgainstUs)
      {
         // Strong candle going further against us — cut worst trades now
         PrintFormat("[Loss Cut] Strong candle against basket (body=%.0f%%) | move=%.3f%% | P&L=%.2f — cutting %d worst",
                     (range > 0 ? body / range * 100.0 : 0.0), avgMovePct, totalProfit, InpLossPartialCount);
         CloseNWorst(InpLossPartialCount);
         g_lossPartialDone = true;
         return;
      }
   }

   // ── 7. FULL PROFIT EXIT ───────────────────────────────────────────────────
   double qualifiedRatio = (double)qualified / total * 100.0;
   bool   profitOK       = (InpMinBasketProfit <= 0.0 || totalProfit >= InpMinBasketProfit);

   if (qualifiedRatio >= InpMinQualifiedPct && profitOK)
   {
      PrintFormat("[Basket Target] %d/%d qualified (%.0f%% >= %.0f%%) | P&L=%.2f — closing basket",
                  qualified, total, qualifiedRatio, InpMinQualifiedPct, totalProfit);
      CloseAllOurPositions("Target");
      return;
   }
}

//──────────────────────────────────────────────────────────────────────────────
// TrySeedEntry — fires on each new M1 bar
// Only opens when: NY session active + no basket currently open
//──────────────────────────────────────────────────────────────────────────────
void TrySeedEntry()
{
   if (!IsNYSession())          return;
   if (g_basketOpen)            return;
   if (CountOurPositions() > 0) return;
   if (g_pauseBarsLeft > 0)     { g_pauseBarsLeft--; return; }

   // ── Daily circuit breakers ────────────────────────────────────────────────
   // Snapshot equity once per session-day (first bar inside the NY window)
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime today = (datetime)StringToTime(StringFormat("%04d.%02d.%02d 00:00",
                                           dt.year, dt.mon, dt.day));
   if (g_sessionDate != today)
   {
      g_sessionDate         = today;
      g_sessionStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      g_sessionBaskets      = 0;
      PrintFormat("[Session Reset] NY equity snapshot = %.2f", g_sessionStartEquity);
   }

   // Daily loss limit — halt if equity has dropped >= InpMaxDailyLossPct% this session
   if (InpMaxDailyLossPct > 0 && g_sessionStartEquity > 0)
   {
      double lostPct = (g_sessionStartEquity - AccountInfoDouble(ACCOUNT_EQUITY))
                       / g_sessionStartEquity * 100.0;
      if (lostPct >= InpMaxDailyLossPct)
      {
         // log once per bar (not every tick) by relying on caller being newBar-gated
         PrintFormat("[DailyStop] %.2f%% session loss >= %.2f%% limit — no new baskets today",
                     lostPct, InpMaxDailyLossPct);
         return;
      }
   }

   // Session basket cap
   if (InpMaxDailyBaskets > 0 && g_sessionBaskets >= InpMaxDailyBaskets)
   {
      PrintFormat("[BasketCap] %d/%d baskets used this session — skipping",
                  g_sessionBaskets, InpMaxDailyBaskets);
      return;
   }
   // ─────────────────────────────────────────────────────────────────────────

   // ── Candle confirmation ──────────────────────────────────────────────────
   // Require InpConfirmCandles consecutive same-direction M1 candles.
   // Candle[1] is the signal bar; candle[2..N] must agree.
   // This is the primary chop filter — in alternating markets every second
   // candle flips, so requiring 2+ aligned candles rejects most noise entries.
   int confirmNeeded = MathMax(1, InpConfirmCandles);
   double c  = iClose(_Symbol, PERIOD_M1, 1);
   double o  = iOpen (_Symbol, PERIOD_M1, 1);
   double hi = iHigh (_Symbol, PERIOD_M1, 1);
   double lo = iLow  (_Symbol, PERIOD_M1, 1);

   if (c == o) return; // doji — no direction

   ENUM_ORDER_TYPE dir = (c > o) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   // Check candles[2..confirmNeeded] all agree with candle[1]
   for (int k = 2; k <= confirmNeeded; k++)
   {
      double ck = iClose(_Symbol, PERIOD_M1, k);
      double ok = iOpen (_Symbol, PERIOD_M1, k);
      if (ck == ok) { PrintFormat("Skip[Confirm]: candle[%d] is doji", k); return; }
      bool kBull = (ck > ok);
      bool dirBull = (dir == ORDER_TYPE_BUY);
      if (kBull != dirBull)
      {
         PrintFormat("Skip[Confirm]: candle[%d] disagrees — need %d consecutive %s",
                     k, confirmNeeded, dirBull ? "BUY" : "SELL");
         return;
      }
   }

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
   g_historyIndex    = 0;
   g_historyCount    = 0;
   g_consecLosses        = 0;
   g_pauseBarsLeft       = 0;
   g_sessionStartEquity  = 0.0;
   g_sessionBaskets      = 0;
   g_sessionDate         = 0;
   g_lastPartialBar  = 0;
   g_lossPartialDone = false;
   g_peakMovePct     = 0.0;
   g_basketBarCount  = 0;

   int numTrades = g_isNetting ? 1 : MathMin(InpBasketSize, 10);
   PrintFormat("FlipTrail v2.60 | %s | Basket=%d | BasketRisk=%.1f%% (%.2f%% per trade) | "
               "HardSL=%.2f%% (broker) | FullExit: %.2f%% on %.0f%%+ trades | "
               "PartialTP1: +%.2f%% close %d best → lock SL +%.2f%% | "
               "Reversal: %.2f%% pullback from peak → close %d best → lock SL +%.2f%% | "
               "Time: %d bars + %.2f%% → close %d best → lock SL +%.2f%% | "
               "LossWatch: -%.2f%% → doji=hold / strong=cut %d worst | DojiBody<%d%% | "
               "DynSL floor=%.2f%% | ConsecPause: %d losses → %d bars | "
               "NY %d:00–%d:00 | Magic=%lld",
               _Symbol, numTrades,
               InpRiskPct, InpRiskPct / numTrades,
               InpSLFloorPct,
               InpMinChangePct, InpMinQualifiedPct,
               InpPartialTPPct, InpPartialTPCount, InpBELockPct,
               InpReversalPullbackPct, InpReversalCount, InpSL2LockPct,
               InpTimeExitBars, InpTimeExitMinPct, InpTimeExitCount, InpBELockPct,
               InpLossWatchPct, InpLossPartialCount, InpDojiBodyPct,
               InpSLFloorPct,
               InpMaxConsecLosses, InpPauseBars,
               InpNYStartHour, InpNYEndHour, InpMagicNumber);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FlipTrail v2.60 deinit (reason=%d).", reason);
}

void OnTick()
{
   datetime bt     = iTime(_Symbol, PERIOD_M1, 0);
   bool     newBar = (bt != 0 && bt != g_lastBarTime);
   if (newBar) g_lastBarTime = bt;

   // Increment bar counter while a basket is active
   if (newBar && g_basketOpen)
      g_basketBarCount++;

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

            // Consecutive loss pause tracking
            if (changePct < 0)
            {
               g_consecLosses++;
               if (InpMaxConsecLosses > 0 && g_consecLosses >= InpMaxConsecLosses)
               {
                  g_pauseBarsLeft = InpPauseBars;
                  g_consecLosses  = 0;
                  PrintFormat("Basket closed | change=%.3f%% [LOSS] | %d consec losses — pausing %d bars | DynSL avg=%.3f%%",
                              changePct, InpMaxConsecLosses, InpPauseBars, GetDynamicThreshold());
               }
               else
                  PrintFormat("Basket closed | change=%.3f%% [LOSS] | consec=%d/%d | DynSL avg=%.3f%%",
                              changePct, g_consecLosses, InpMaxConsecLosses, GetDynamicThreshold());
            }
            else
            {
               g_consecLosses = 0;
               PrintFormat("Basket closed | change=%.3f%% [PROFIT] | consec reset | DynSL avg=%.3f%% (%d trades)",
                           changePct, GetDynamicThreshold(), g_historyCount);
            }
         }

         g_basketOpen     = false;
         g_basketAvgEntry = 0.0;
         g_peakMovePct    = 0.0;
         g_basketBarCount = 0;
         g_lastPartialBar = 0;
         PrintFormat("Ready for next NY signal");
      }
   }
}
