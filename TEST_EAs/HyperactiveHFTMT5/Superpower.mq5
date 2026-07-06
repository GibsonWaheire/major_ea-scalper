//+------------------------------------------------------------------+
//|  Flipper.mq5  v1.00                                              |
//|  Max-lot basket scalper | FlipTrail candle entry | Fast profit   |
//|                                                                   |
//|  PHILOSOPHY                                                       |
//|  ──────────                                                       |
//|  Big lot. Small move. Quick profit. Compound. Repeat.            |
//|                                                                   |
//|  Entry  : M1 candle body direction (FlipTrail logic — untouched) |
//|  Open   : N trades simultaneously at maximum margin allocation   |
//|  Exit   : The instant basket profit >= target → close ALL        |
//|  Loss   : Hold. Price breathes back. No SL. No circuit breaker.  |
//|  Compound: Each win → bigger account → bigger lots next basket   |
//+------------------------------------------------------------------+
#property copyright "Flipper EA"
#property link      ""
#property version   "1.00"
#property description "Flipper v1.00: max-lot basket on M1 candle signal, instant close on profit target. No SL."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//──────────────────────────────────────────────────────────────────────────────
// INPUTS
//──────────────────────────────────────────────────────────────────────────────
input group "=== Basket ==="
input int    InpNumTrades        = 5;      // Trades to open per basket signal
input double InpMarginUsePct     = 80.0;   // % of free margin to use for basket
input double InpMinLot           = 0.01;   // Minimum lot per trade
input double InpMaxLotPerTrade   = 10.0;   // Maximum lot cap per trade

input group "=== Profit Exit ==="
input double InpProfitTargetPct  = 2.0;    // Close ALL when basket profit >= X% of balance

input group "=== Entry Signal (FlipTrail candle logic) ==="
input int    InpMinBodyPct       = 30;     // Min candle body as % of range (0 = off)

input group "=== Execution ==="
input long   InpMagicNumber      = 999001; // Magic Number
input int    InpMaxSlippage      = 30;     // Max slippage points
input int    InpRetries          = 3;      // Order retry attempts

//──────────────────────────────────────────────────────────────────────────────
// STATE
//──────────────────────────────────────────────────────────────────────────────
CTrade        g_trade;
CPositionInfo g_pos;
CSymbolInfo   g_sym;

datetime g_lastBarTime = 0;
bool     g_inBasket    = false;

//──────────────────────────────────────────────────────────────────────────────
// HELPERS
//──────────────────────────────────────────────────────────────────────────────
int CountBasket()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i))                  continue;
      if(g_pos.Magic()  != (ulong)InpMagicNumber)  continue;
      if(g_pos.Symbol() != _Symbol)                continue;
      n++;
   }
   return n;
}

double BasketProfit()
{
   double p = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i))                  continue;
      if(g_pos.Magic()  != (ulong)InpMagicNumber)  continue;
      if(g_pos.Symbol() != _Symbol)                continue;
      p += g_pos.Profit() + g_pos.Swap() + g_pos.Commission();
   }
   return p;
}

bool CloseAllBasket(double profit)
{
   ulong tickets[];
   int   total = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i))                  continue;
      if(g_pos.Magic()  != (ulong)InpMagicNumber)  continue;
      if(g_pos.Symbol() != _Symbol)                continue;
      ArrayResize(tickets, total+1);
      tickets[total++] = g_pos.Ticket();
   }

   int closed = 0;
   for(int j = 0; j < total; j++)
   {
      for(int attempt = 0; attempt < InpRetries; attempt++)
      {
         if(g_trade.PositionClose(tickets[j], InpMaxSlippage)) { closed++; break; }
         Sleep(50);
      }
   }

   PrintFormat("[Flipper] BASKET CLOSED | Profit=$%.2f | %d/%d trades closed",
               profit, closed, total);
   return (closed == total);
}

double NormLot(double lot)
{
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, MathMax(minVol, InpMinLot));
   lot = MathMin(lot, MathMin(maxVol, InpMaxLotPerTrade));
   return NormalizeDouble(lot, 2);
}

double CalcLotPerTrade()
{
   g_sym.RefreshRates();
   double ask = g_sym.Ask();

   double marginPerLot = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, ask, marginPerLot) || marginPerLot <= 0)
      return InpMinLot;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double usable     = freeMargin * InpMarginUsePct / 100.0;
   double totalLots  = usable / marginPerLot;

   // Only RETAIL_HEDGING supports multiple positions on same symbol.
   // RETAIL_NETTING and EXCHANGE both collapse to 1 position → use full lot.
   bool isHedging = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

   double lotPerTrade = isHedging ? totalLots / (double)InpNumTrades : totalLots;

   return NormLot(lotPerTrade);
}

void SetFilling()
{
   // RETURN is most universally accepted across brokers
   g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//──────────────────────────────────────────────────────────────────────────────
// GetSignal — FlipTrail candle body logic (source: FlipTrail_EA, read only)
// Returns 1 = BUY, -1 = SELL, 0 = no signal
//──────────────────────────────────────────────────────────────────────────────
int GetSignal()
{
   double c  = iClose(_Symbol, PERIOD_M1, 1);
   double o  = iOpen (_Symbol, PERIOD_M1, 1);
   double hi = iHigh (_Symbol, PERIOD_M1, 1);
   double lo = iLow  (_Symbol, PERIOD_M1, 1);

   if(c == o) return 0;  // doji — no signal

   if(InpMinBodyPct > 0)
   {
      double range = hi - lo;
      double body  = MathAbs(c - o);
      if(range > 0 && (body / range) * 100.0 < (double)InpMinBodyPct) return 0;
   }

   return (c > o) ? 1 : -1;
}

//──────────────────────────────────────────────────────────────────────────────
// OpenBasket — fires N trades simultaneously in direction
//──────────────────────────────────────────────────────────────────────────────
void OpenBasket(int dir)
{
   if(CountBasket() > 0) return;

   SetFilling();
   double lot = CalcLotPerTrade();

   if(lot < InpMinLot)
   {
      Print("[Flipper] Not enough margin to open basket");
      return;
   }

   bool isHedging    = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   int  tradesTarget = isHedging ? InpNumTrades : 1;

   int opened = 0;
   for(int i = 0; i < tradesTarget; i++)
   {
      g_sym.RefreshRates();
      double ask = g_sym.Ask();
      double bid = g_sym.Bid();
      bool   ok  = false;

      int beforeCount = CountBasket();
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
      ok = (dir == 1)
         ? g_trade.Buy (lot, _Symbol, ask, 0, 0, "Flipper")
         : g_trade.Sell(lot, _Symbol, bid, 0, 0, "Flipper");
      Sleep(100);
      // Confirm by actual position count — broker may return non-DONE even on success
      if(!ok && CountBasket() > beforeCount) ok = true;
      if(!ok)
      {
         uint rc = g_trade.ResultRetcode();
         PrintFormat("[Flipper] Trade %d failed rc=%u", i+1, rc);
         if(rc == 10006) break; // broker won't allow more positions — stop trying
      }

      if(ok) opened++;
   }

   if(opened > 0)
   {
      g_inBasket = true;
      double target = AccountInfoDouble(ACCOUNT_BALANCE) * InpProfitTargetPct / 100.0;
      PrintFormat("[Flipper] BASKET OPEN | Dir=%s | %d/%d trades | Lot=%.2f | Target=$%.2f | %s",
                  dir==1?"BUY":"SELL", opened, tradesTarget, lot, target,
                  isHedging?"HEDGING(multi)":"SINGLE-POS(1 big lot)");
   }
}

//──────────────────────────────────────────────────────────────────────────────
// MonitorBasket — called every tick, closes instantly on target
//──────────────────────────────────────────────────────────────────────────────
void MonitorBasket()
{
   if(!g_inBasket) return;

   int n = CountBasket();
   if(n == 0) { g_inBasket = false; return; }

   double profit  = BasketProfit();
   double target  = AccountInfoDouble(ACCOUNT_BALANCE) * InpProfitTargetPct / 100.0;

   if(profit >= target)
   {
      PrintFormat("[Flipper] TARGET HIT | $%.2f >= $%.2f | Closing %d trades NOW",
                  profit, target, n);
      if(CloseAllBasket(profit))
         g_inBasket = false;
   }
}

//==============================================================================
// MT5 HANDLERS
//==============================================================================

int OnInit()
{
   if(!g_sym.Name(_Symbol)) { Print("INIT FAILED: SymbolInfo"); return INIT_FAILED; }
   g_sym.RefreshRates();

   g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   g_trade.SetDeviationInPoints(InpMaxSlippage);
   g_trade.SetAsyncMode(false);
   SetFilling();

   // Recover if basket already open
   if(CountBasket() > 0)
   {
      g_inBasket = true;
      Print("[Flipper] Recovered open basket on init");
   }

   int marginMode = (int)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   string modeStr = (marginMode==0)?"RETAIL_NETTING":(marginMode==1)?"EXCHANGE":"RETAIL_HEDGING";
   PrintFormat("[Flipper] AccountMarginMode=%d (%s)", marginMode, modeStr);
   PrintFormat("[Flipper] v1.00 READY | %s | Trades=%d | MarginUse=%.0f%% | Target=%.1f%% of balance | Body>=%d%%",
               _Symbol, InpNumTrades, InpMarginUsePct, InpProfitTargetPct, InpMinBodyPct);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("[Flipper] Deinit | reason=%d | Open positions remaining: %d", reason, CountBasket());
}

void OnTick()
{
   // Monitor profit every tick — this is the priority
   MonitorBasket();

   // Entry: new bar only, no basket open
   datetime bt     = iTime(_Symbol, PERIOD_M1, 0);
   bool     newBar = (bt != 0 && bt != g_lastBarTime);
   if(newBar) g_lastBarTime = bt;

   if(newBar && !g_inBasket && CountBasket() == 0)
   {
      int sig = GetSignal();
      if(sig != 0)
      {
         PrintFormat("[Flipper] Signal: %s on M1 candle", sig==1?"BUY":"SELL");
         OpenBasket(sig);
      }
   }
}
