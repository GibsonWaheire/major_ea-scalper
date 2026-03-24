// DailyHoldScalper.mq5
// Momentum Basket EA — No Stop Loss, Risk-Based Lots, Aggressive Basket Building
//
// v4.00 overhaul:
//   - Risk-based lot sizing: equity × RiskPercent% ÷ (ATR reference distance)
//     Lots scale automatically with account size and market volatility
//   - Stronger momentum filter: velocity + candle body strength + close location
//   - H1 bias filter: optional — only enter in H1 candle direction
//   - Martingale averaging: optional lot multiplier for deeper basket trades
//   - Rate limiter actually wired up (was declared but ignored in v3)
//   - No stop loss on any trade — margin protection is the safety net
//   - Symbol auto-detected from chart when TradeSymbol left blank
//   - Removed dead inputs (UseBreakEven, UseTrailingStop, RequireVolumeConfirmation,
//     OneEntryPerBar, LotStep, CloseMode — none of these did anything)

#property copyright "DailyHoldScalper"
#property link      "local"
#property version   "4.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

// ─── Core ────────────────────────────────────────────────────────────────────
input string          TradeSymbol              = "";       // Blank = use chart symbol
input int             MagicNumber              = 905533;
input int             MaxTotalTrades           = 15;      // Max positions in basket
input int             DeviationPoints          = 30;
input double          SpreadLimitPoints        = 300;

// ─── Lot Sizing (Risk-Based) ──────────────────────────────────────────────────
// Lot is sized so that a 1×ATR move against you costs RiskPercent% of equity.
// This makes lots dynamic: small account or volatile market = smaller lot.
input double          RiskPercent              = 3.0;     // % of equity risked per trade (1 ATR reference)
input double          MaxLotCap                = 1.0;     // Hard cap per single trade

// ─── Martingale Averaging ────────────────────────────────────────────────────
// When the basket is already open, each new averaging trade multiplies the lot
// by MartingaleMult to accelerate recovery. Disable for flat sizing.
input bool            UseMartingale            = false;
input double          MartingaleMult           = 1.5;     // Lot multiplier per extra trade

// ─── ATR & Momentum ──────────────────────────────────────────────────────────
input int             ATRPeriod                = 14;
input ENUM_TIMEFRAMES ATRTimeframe             = PERIOD_M1;
input ENUM_TIMEFRAMES MomentumTF               = PERIOD_M1;
input double          MomentumThresholdATR     = 0.15;    // Min velocity as ATR fraction
input double          BodyStrengthATR          = 0.20;    // Min candle body as ATR fraction
input double          CloseLocationPct         = 0.30;    // Close must be in top/bottom X% of range
input int             MinSecondsBetweenEntries = 5;       // Entry rate limiter

// ─── H1 Bias Filter ──────────────────────────────────────────────────────────
// When enabled, only opens trades in the direction of the completed H1 candle.
// Reduces counter-trend basket exposure.
input bool            UseH1Filter              = true;

// ─── Entry ───────────────────────────────────────────────────────────────────
input bool            UseLimitOrders           = true;
input int             MarketOrdersAtExecution  = 2;
input int             LimitOrderCount          = 5;

// ─── Basket Profit Exit ───────────────────────────────────────────────────────
input bool            UseBasketProfit          = true;
input double          BasketProfitATRMult      = 2.5;     // Close basket at N×ATR profit
input bool            CloseAtAnyProfit         = true;    // Close as soon as basket is profitable
input double          MinProfitToClose         = 0.01;    // Minimum $ profit to trigger close

// ─── Margin Protection ───────────────────────────────────────────────────────
// No SL on trades — margin level is the only hard risk gate.
// When margin drops below MarginTriggerLevel%, all positions are closed and
// a reversal is attempted if H1 confirms the new direction.
input double          MarginTriggerLevel       = 100.0;   // Close all if margin% falls below this

// ─── Globals ─────────────────────────────────────────────────────────────────
CTrade        trade;
CPositionInfo pos;
int           atrHandle    = -1;
datetime      lastEntryTime = 0;
string        gSymbol      = "";
double        gATR         = 0.0;

// ─── Helpers ─────────────────────────────────────────────────────────────────

bool EnsureSymbolReady(const string sym)
{
   if(!SymbolSelect(sym, true))                                                { Print("Symbol select failed: ", sym); return false; }
   if(SymbolInfoInteger(sym, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED) { Print("Trading disabled: ",    sym); return false; }
   return true;
}

void CloseAllExistingTrades(const string sym)
{
   int closed = 0, deleted = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol() != sym) continue;
      if(trade.PositionClose(pos.Ticket(), DeviationPoints)) closed++;
   }
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t) || OrderGetString(ORDER_SYMBOL) != sym) continue;
      if(trade.OrderDelete(t)) deleted++;
   }
   if(closed > 0 || deleted > 0)
      Print("Startup cleanup: ", closed, " positions, ", deleted, " orders.");
}

bool SpreadOK(const string sym)
{
   double spread = (SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID))
                   / SymbolInfoDouble(sym, SYMBOL_POINT);
   return spread <= SpreadLimitPoints;
}

double GetATR()
{
   double buf[2];
   if(atrHandle < 0 || CopyBuffer(atrHandle, 0, 0, 2, buf) < 1) return 0.0;
   return buf[0];
}

// ─── Momentum Detection ──────────────────────────────────────────────────────
// Three-layer check:
//   1. Velocity: close[0] - close[1] must exceed ATR threshold
//   2. Body strength: candle body must be meaningfully large vs ATR
//   3. Close location: close must be in the top/bottom portion of the candle range

int DetectMomentum(const string sym, double atr)
{
   if(atr <= 0) return 0;

   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(sym, MomentumTF, 0, 3, close) < 3) return 0;

   double velocity = close[0] - close[1];
   if(MathAbs(velocity) < atr * MomentumThresholdATR) return 0;
   int dir = (velocity > 0) ? 1 : -1;

   double open[], high[], low[];
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low,  true);
   if(CopyOpen(sym, MomentumTF, 0, 1, open) < 1) return 0;
   if(CopyHigh(sym, MomentumTF, 0, 1, high) < 1) return 0;
   if(CopyLow (sym, MomentumTF, 0, 1, low)  < 1) return 0;

   double body  = MathAbs(close[0] - open[0]);
   double range = high[0] - low[0];
   if(body  < atr * BodyStrengthATR) return 0;
   if(range <= 0) return 0;

   double closePct = (close[0] - low[0]) / range;
   if(dir > 0 && closePct < (1.0 - CloseLocationPct)) return 0;
   if(dir < 0 && closePct > CloseLocationPct)          return 0;

   return dir;
}

// Returns direction of the last completed H1 candle (index [1]).
int GetH1Direction(const string sym)
{
   double h1c[], h1o[];
   ArraySetAsSeries(h1c, true);
   ArraySetAsSeries(h1o, true);
   if(CopyClose(sym, PERIOD_H1, 0, 2, h1c) < 2) return 0;
   if(CopyOpen( sym, PERIOD_H1, 0, 2, h1o) < 2) return 0;
   if(h1c[1] > h1o[1]) return  1;
   if(h1c[1] < h1o[1]) return -1;
   return 0;
}

// ─── Volume Helpers ──────────────────────────────────────────────────────────

double NormalizeVolume(const string sym, double lots)
{
   double minL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   lots = MathMax(minL, MathMin(maxL, lots));
   if(step > 0) lots = MathFloor(lots/step) * step;
   return NormalizeDouble(lots, 2);
}

// Base lot from risk %: sizes so 1 ATR move costs RiskPercent% of equity.
double CalcBaseLot(const string sym, double atr)
{
   if(atr <= 0) return SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmt   = equity * (RiskPercent / 100.0);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0) return SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double lot = riskAmt / ((atr / tickSize) * tickValue);
   return NormalizeVolume(sym, MathMin(MaxLotCap, lot));
}

// Lot for a specific trade in the basket.
// If martingale is on, multiply base lot by MartingaleMult^tradeIndex.
double GetBasketLot(const string sym, double atr, int tradeIndex)
{
   double base = CalcBaseLot(sym, atr);
   if(!UseMartingale || tradeIndex <= 0) return base;
   double mult = MathPow(MartingaleMult, tradeIndex);
   return NormalizeVolume(sym, MathMin(MaxLotCap, base * mult));
}

// ─── Position / Order Counts ─────────────────────────────────────────────────

int PositionsCount(const string sym)
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() == sym && pos.Magic() == MagicNumber) n++;
   }
   return n;
}

int PendingOrdersCount(const string sym)
{
   int n = 0;
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) == sym && OrderGetInteger(ORDER_MAGIC) == MagicNumber) n++;
   }
   return n;
}

int GetBasketDirection(const string sym)
{
   int buys = 0, sells = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
      if(pos.PositionType() == POSITION_TYPE_BUY) buys++; else sells++;
   }
   if(buys == 0 && sells == 0) return 0;
   return (buys >= sells) ? 1 : -1;
}

double BasketProfit(const string sym)
{
   double p = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
      p += pos.Profit() + pos.Swap() + pos.Commission();
   }
   return p;
}

double BasketLots(const string sym)
{
   double lots = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
      lots += pos.Volume();
   }
   return lots;
}

void DeletePendingOrders(const string sym)
{
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL)==sym && OrderGetInteger(ORDER_MAGIC)==MagicNumber)
         trade.OrderDelete(t);
   }
}

bool CloseBasket(const string sym)
{
   trade.SetAsyncMode(true);
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
      trade.PositionClose(pos.Ticket(), DeviationPoints);
   }
   DeletePendingOrders(sym);
   trade.SetAsyncMode(false);
   return true;
}

// ─── Profit Target ───────────────────────────────────────────────────────────

double CalcProfitTarget(const string sym, double atr, double totalLots)
{
   if(!UseBasketProfit || atr <= 0 || totalLots <= 0) return 0.0;
   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) return 0.0;
   return MathMax((atr * BasketProfitATRMult) * (tv/ts) * totalLots, 1.0);
}

void ManageExits(const string sym, double atr)
{
   double profit = BasketProfit(sym);
   double target = CalcProfitTarget(sym, atr, BasketLots(sym));
   if(target > 0 && profit >= target)                 { CloseBasket(sym); return; }
   if(CloseAtAnyProfit && profit >= MinProfitToClose) { CloseBasket(sym); return; }
}

// ─── Entry ───────────────────────────────────────────────────────────────────

bool OpenMarket(const string sym, int dir, double atr)
{
   int total = PositionsCount(sym) + PendingOrdersCount(sym);
   if(total >= MaxTotalTrades) return false;
   double lot = GetBasketLot(sym, atr, total);
   if(lot <= 0) return false;
   trade.SetExpertMagicNumber(MagicNumber);
   // No SL, no TP — basket is closed as a unit on profit target
   bool ok = (dir > 0) ? trade.Buy(lot, sym, 0, 0, 0) : trade.Sell(lot, sym, 0, 0, 0);
   return ok;
}

bool PlaceLimitOrders(const string sym, int dir, double atr)
{
   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double offsets[] = {0.2, 0.4, 0.6, 0.8, 1.0};
   int placed = 0;
   trade.SetExpertMagicNumber(MagicNumber);

   for(int i = 0; i < LimitOrderCount; i++)
   {
      int cur = PositionsCount(sym) + PendingOrdersCount(sym);
      if(cur >= MaxTotalTrades) break;
      double lot    = GetBasketLot(sym, atr, cur);
      double offset = atr * offsets[MathMin(i, 4)];
      double price  = (dir > 0) ? NormalizeDouble(bid-offset, digits)
                                 : NormalizeDouble(ask+offset, digits);
      bool ok = (dir > 0) ? trade.BuyLimit(lot, price, sym, 0)
                           : trade.SellLimit(lot, price, sym, 0);
      if(ok) placed++;
   }
   return (placed > 0);
}

// ─── Lifecycle ───────────────────────────────────────────────────────────────

int OnInit()
{
   gSymbol = (TradeSymbol == "") ? Symbol() : TradeSymbol;
   if(!EnsureSymbolReady(gSymbol)) return INIT_FAILED;
   CloseAllExistingTrades(gSymbol);
   atrHandle = iATR(gSymbol, ATRTimeframe, ATRPeriod);
   if(atrHandle < 0) { Print("ATR handle failed."); return INIT_FAILED; }
   Print("DailyHoldScalper v4.00 | Symbol: ", gSymbol, " | Risk: ", RiskPercent, "% per trade");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(atrHandle);
}

void OnTick()
{
   // ── Margin protection — always first ──────────────────────────────────────
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(marginLevel > 0 && marginLevel < MarginTriggerLevel)
   {
      int closedDir = GetBasketDirection(gSymbol);
      CloseBasket(gSymbol);
      Print("Margin protection triggered: ", marginLevel, "% → closing all.");

      // Attempt H1-confirmed reversal
      if(closedDir != 0)
      {
         int h1dir = GetH1Direction(gSymbol);
         int revDir = -closedDir;
         if(h1dir != 0 && h1dir != revDir)
         {
            Print("SAR blocked — H1 does not confirm reversal direction.");
            return;
         }
         double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
         double atr        = GetATR();
         double lot        = (atr > 0) ? CalcBaseLot(gSymbol, atr)
                                       : SymbolInfoDouble(gSymbol, SYMBOL_VOLUME_MIN);
         double price      = (revDir > 0) ? SymbolInfoDouble(gSymbol, SYMBOL_ASK)
                                          : SymbolInfoDouble(gSymbol, SYMBOL_BID);
         double marginReq  = 0;
         if(!OrderCalcMargin((revDir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                              gSymbol, lot, price, marginReq))
            marginReq = SymbolInfoDouble(gSymbol, SYMBOL_MARGIN_INITIAL) * lot;
         if(freeMargin >= marginReq)
         {
            trade.SetExpertMagicNumber(MagicNumber);
            bool ok = (revDir > 0) ? trade.Buy(lot, gSymbol, 0, 0, 0)
                                   : trade.Sell(lot, gSymbol, 0, 0, 0);
            if(ok) Print("SAR reversal opened: ", (revDir > 0 ? "BUY" : "SELL"));
         }
         else
            Print("SAR failed — insufficient free margin.");
      }
      return;
   }

   if(!EnsureSymbolReady(gSymbol) || !SpreadOK(gSymbol)) return;

   double atr = GetATR();
   if(atr <= 0) return;
   gATR = atr;

   // ── Manage exits ──────────────────────────────────────────────────────────
   ManageExits(gSymbol, atr);

   // ── Rate limiter ──────────────────────────────────────────────────────────
   if(TimeCurrent() - lastEntryTime < MinSecondsBetweenEntries) return;

   // ── Entry signal ──────────────────────────────────────────────────────────
   int dir = DetectMomentum(gSymbol, atr);
   if(dir == 0) return;

   // H1 bias filter — skip entries that fight the H1 trend
   if(UseH1Filter)
   {
      int h1 = GetH1Direction(gSymbol);
      if(h1 != 0 && h1 != dir) return;
   }

   // Don't fight existing basket direction
   int basketDir = GetBasketDirection(gSymbol);
   if(basketDir != 0 && dir != basketDir) return;

   // ── Open trades ───────────────────────────────────────────────────────────
   if(UseLimitOrders)
   {
      if(PendingOrdersCount(gSymbol) > 0) return;
      for(int m = 0; m < MarketOrdersAtExecution; m++) OpenMarket(gSymbol, dir, atr);
      PlaceLimitOrders(gSymbol, dir, atr);
   }
   else
   {
      OpenMarket(gSymbol, dir, atr);
   }
   lastEntryTime = TimeCurrent();
}
