// // DynamicXauBasketMT5.mq5
// Momentum Breakout EA - Dynamic lot (min to max), 1-20 trades per basket, bulk close
#property copyright "Dynamic XAU Momentum Breakout EA"
#property link      "local"
#property version   "3.10"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

// --- Inputs ---
input string    TradeSymbol           = "XAUUSD";
input int       MagicNumber           = 905533;
input double    BaseLot               = 0.03;   // Lot for first trade (min)
input double    LotStep               = 0.01;      // Add per trade (0 = flat BaseLot for all)
input double    MaxLot                = 0.10;   // Cap (not too much)
input int       MinTotalTrades        = 1;      // Min trades per basket
input int       MaxTotalTrades        = 10;     // Max trades per basket (1-20 dynamic)
input int       ATRPeriod             = 14;
input ENUM_TIMEFRAMES MomentumTF     = PERIOD_M1; // Momentum timeframe (M1 for scalping)
input ENUM_TIMEFRAMES ATRTimeframe   = PERIOD_M1;
input double    MomentumThresholdATR  = 0.15;   // Minimum momentum to trigger breakout entry (ATR fraction)
input int       MomentumLookback      = 2;      // Number of candles to look back for momentum
input bool      RequireVolumeConfirmation = false; // Require volume confirmation for breakout
input int       DeviationPoints        = 30;     // Slippage guard
input double    SpreadLimitPoints     = 300;    // Skip trading if spread too wide
input int       MinSecondsBetweenEntries = 5;   // Min seconds between opening new trades
input bool      OneEntryPerBar       = true;   // Max one entry per M1 bar
input bool      UseLimitOrders       = true;   // Use limit orders instead of market
input int       MarketOrdersAtExecution = 2;    // Market orders to open immediately on signal
input int       LimitOrderCount      = 5;      // Number of limit orders per basket
input int       MinPendingHoldSeconds = 3;     // Min seconds before cancelling pendings on direction change
input int       PendingOrderTimeoutSeconds = 60; // Cancel pendings if not filled after this many seconds

// --- Margin Protection Settings ---
input double    MarginTriggerLevel    = 120.0;  // Margin % to Trigger Close & Reverse

// --- Basket Profit Settings ---
input bool      UseBasketProfit       = true;   // Close all trades when basket profit target reached
input double    BasketProfitATRMultiplier = 2.5; // Basket profit target as multiple of ATR
input double    BasketProfitPercent   = 2.0;    // Alternative: Basket profit as % of account balance
input bool      UsePercentForBasket   = false;  // If true use %, if false use ATR multiplier
input bool      IncludeAllTrades      = true;   // Include all trades (even pre-existing) in basket profit
input bool      CloseEarlyWhenProfitable = true; // Close basket early when profitable (even below target)
input double    EarlyCloseProfitATR   = 1.5;    // Close basket early at this ATR multiplier (if profitable)
input double    EarlyCloseProfitPercent = 1.0;  // Alternative: Close early at this % profit
input bool      UsePercentForEarlyClose = false; // If true use % for early close, if false use ATR
input bool      CloseAtAnyProfit        = true;  // Close basket as soon as profit > 0
input double    MinProfitToClose       = 0.01;   // Minimum profit (currency) to trigger close
input bool      UseTimeBasedClose      = true;  // Require min hold time before closing profit
input int       MinHoldSeconds         = 1;     // Min seconds to hold before close (1-5 sec window)
input int       MaxHoldSeconds         = 5;     // Max seconds for close window
input int       CloseMode              = 2;     // 0=basket only, 1=individual only, 2=both

// --- Exit Settings ---
input bool      UseBreakEven          = false;  // Move stop loss to break-even (disables wide SL)
input double    BreakEvenTriggerATR   = 0.5;    // Move to BE when profit reaches this ATR
input bool      UseTrailingStop       = false;  // Use trailing stop (disables wide SL)
input double    TrailingStopATR        = 1.0;    // Trailing stop distance in ATR
input double    TrailingStepATR       = 0.3;    // Trailing step in ATR

// --- Globals ---
CTrade          trade;
CPositionInfo  pos;
int             atrHandle     = -1;
bool            eaInitialized = false;
double          lastPrice     = 0.0;  // Track last price for momentum calculation
datetime        lastEntryTime = 0;    // Entry cooldown
datetime        lastEntryBar  = 0;    // One entry per bar


// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------
bool EnsureSymbolReady(const string symbol)
{
   if(!SymbolSelect(symbol, true))
   {
      Print("Failed to select symbol ", symbol);
      return false;
   }
   if(SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("Symbol trading disabled: ", symbol);
      return false;
   }
   return true;
}

void CloseAllExistingTrades(const string symbol)
{
   int closed = 0;
   int deleted = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      ulong ticket = pos.Ticket();
      if(trade.PositionClose(ticket, DeviationPoints)) closed++;
   }
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0 || !OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(trade.OrderDelete(oticket)) deleted++;
   }
   if(closed > 0 || deleted > 0)
      Print("Cleaned up ", closed, " positions and ", deleted, " orders on start.");
}

double GetATR()
{
   if(atrHandle < 0) return 0.0;
   double buffer[2];
   if(CopyBuffer(atrHandle, 0, 0, 2, buffer) < 1) return 0.0;
   return buffer[0];
}

int DetectMomentumBreakout(const string symbol, double atr)
{
   if(atr <= 0) return 0;
   double close[];
   ArraySetAsSeries(close, true);
   int lookback = MomentumLookback + 1;
   if(CopyClose(symbol, MomentumTF, 0, lookback, close) < lookback) return 0;
   double momentum = close[0] - close[MomentumLookback];
   double momentumThreshold = atr * MomentumThresholdATR;
   if(MathAbs(momentum) < momentumThreshold) return 0;
   return (momentum > 0) ? 1 : -1;
}

double NormalizeVolume(const string symbol, double lots)
{
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   lots = MathMax(minLot, MathMin(maxLot, lots));
   if(step > 0) lots = MathFloor(lots / step) * step;
   return NormalizeDouble(lots, 2);
}

double GetDynamicLot(const string symbol, int currentTrades)
{
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double lot = (LotStep == 0) ? BaseLot : (BaseLot + (currentTrades * LotStep));
   lot = MathMin(MaxLot, MathMax(minLot, lot));
   return NormalizeVolume(symbol, lot);
}

int PositionsCount(const string symbol)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      if(!IncludeAllTrades && pos.Magic() != MagicNumber) continue;
      count++;
   }
   return count;
}

int PendingOrdersCount(const string symbol)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0 || !OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(!IncludeAllTrades && OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      count++;
   }
   return count;
}

int GetPendingOrdersDirection(const string symbol)
{
   int buys = 0, sells = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0 || !OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(otype == ORDER_TYPE_BUY_LIMIT) buys++;
      else if(otype == ORDER_TYPE_SELL_LIMIT) sells++;
   }
   if(buys == 0 && sells == 0) return 0;
   return (buys >= sells) ? 1 : -1;
}

datetime GetOldestPendingOrderTime(const string symbol)
{
   datetime oldest = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0 || !OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      datetime t = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(oldest == 0 || t < oldest) oldest = t;
   }
   return oldest;
}

void DeletePendingOrdersOnly(const string symbol)
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0 || !OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      trade.OrderDelete(oticket);
   }
}

int GetBasketDirection(const string symbol)
{
   int buys = 0, sells = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      if(pos.PositionType() == POSITION_TYPE_BUY) buys++; else sells++;
   }
   if(buys == 0 && sells == 0) return 0;
   return (buys >= sells) ? 1 : -1;
}

double BasketProfit(const string symbol)
{
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      if(!IncludeAllTrades && pos.Magic() != MagicNumber) continue;
      profit += pos.Profit() + pos.Swap() + pos.Commission();
   }
   return profit;
}

double BasketLots(const string symbol)
{
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      if(!IncludeAllTrades && pos.Magic() != MagicNumber) continue;
      lots += pos.Volume();
   }
   return lots;
}

double CalculateBasketProfitTarget(const string symbol, double atr, double totalLots)
{
   if(!UseBasketProfit) return 0.0;
   double target = 0.0;
   if(UsePercentForBasket)
      target = AccountInfoDouble(ACCOUNT_BALANCE) * (BasketProfitPercent / 100.0);
   else if(atr > 0 && totalLots > 0)
   {
      double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize > 0) target = (atr * BasketProfitATRMultiplier) * (tickValue / tickSize) * totalLots;
   }
   return MathMax(target, 1.0);
}

datetime BasketOldestOpen(const string symbol)
{
   datetime oldest = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      datetime opentime = pos.Time();
      if(oldest == 0 || opentime < oldest) oldest = opentime;
   }
   return oldest;
}

bool CloseBasket(const string symbol)
{
   trade.SetAsyncMode(true);
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      trade.PositionClose(pos.Ticket(), DeviationPoints);
   }
   DeletePendingOrdersOnly(symbol);
   trade.SetAsyncMode(false);
   return true;
}


bool OpenMarket(const string symbol, int direction, double atr)
{
   int totalTrades = PositionsCount(symbol) + PendingOrdersCount(symbol);
   if(totalTrades >= MathMax(MinTotalTrades, MathMin(10, MaxTotalTrades))) return false;
   
   double lot = GetDynamicLot(symbol, totalTrades);
   if(lot <= 0) return false;
   
   trade.SetExpertMagicNumber(MagicNumber);
   
   bool result = (direction > 0) ? trade.Buy(lot, symbol, 0, 0, 0) : trade.Sell(lot, symbol, 0, 0, 0);
   return result;
}

bool PlaceLimitOrders(const string symbol, int direction, double atr)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   double offsets[] = {0.2, 0.4, 0.6, 0.8, 1.0};
   int placed = 0;
   
   for(int i = 0; i < LimitOrderCount; i++)
   {
      double lot = GetDynamicLot(symbol, PositionsCount(symbol) + PendingOrdersCount(symbol) + i);
      double offset = atr * offsets[i];
      double limitPrice = (direction > 0) ? NormalizeDouble(bid - offset, digits) : NormalizeDouble(ask + offset, digits);
      
      if(direction > 0) { if(trade.BuyLimit(lot, limitPrice, symbol, 0)) placed++; }
      else { if(trade.SellLimit(lot, limitPrice, symbol, 0)) placed++; }
   }
   return (placed > 0);
}

bool SpreadOK(const string symbol)
{
   double spread = (SymbolInfoDouble(symbol, SYMBOL_ASK) - SymbolInfoDouble(symbol, SYMBOL_BID)) / SymbolInfoDouble(symbol, SYMBOL_POINT);
   return spread <= SpreadLimitPoints;
}

void ManageExits(const string symbol, double atr)
{
   if(atr <= 0) return;
   double basketProfit = BasketProfit(symbol);
   double totalLots = BasketLots(symbol);
   double profitTarget = CalculateBasketProfitTarget(symbol, atr, totalLots);
   
   if(basketProfit >= profitTarget && basketProfit > 0) { CloseBasket(symbol); return; }
   if(CloseAtAnyProfit && basketProfit >= MinProfitToClose) { CloseBasket(symbol); return; }
}

int OnInit()
{
   if(!EnsureSymbolReady(TradeSymbol)) return INIT_FAILED;
   CloseAllExistingTrades(TradeSymbol);
   atrHandle = iATR(TradeSymbol, ATRTimeframe, ATRPeriod);
   eaInitialized = true;
   Print("EA Initialized with Margin-Based SAR System.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { IndicatorRelease(atrHandle); }

void OnTick()
{
   // Global Margin Protection - Execute FIRST before any other logic
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(marginLevel > 0 && marginLevel < MarginTriggerLevel)
   {
      // Determine basket direction BEFORE closing
      int closedBasketDirection = GetBasketDirection(TradeSymbol);
      
      // Close all positions and pending orders
      CloseBasket(TradeSymbol);
      DeletePendingOrdersOnly(TradeSymbol);
      
      Print("Margin SAR Triggered: Margin Level = ", marginLevel, "%");
      
      // SAR Logic with H1 Filter
      if(closedBasketDirection != 0)
      {
         // Get H1 candle data
         double h1Close[], h1Open[];
         ArraySetAsSeries(h1Close, true);
         ArraySetAsSeries(h1Open, true);
         
         if(CopyClose(TradeSymbol, PERIOD_H1, 0, 1, h1Close) >= 1 && 
            CopyOpen(TradeSymbol, PERIOD_H1, 0, 1, h1Open) >= 1)
         {
            bool h1Bearish = h1Close[0] < h1Open[0];
            bool h1Bullish = h1Close[0] > h1Open[0];
            
            int reverseDirection = 0;
            bool filterPassed = false;
            
            // If closed basket was BUY, only reverse to SELL if H1 is Bearish
            if(closedBasketDirection > 0 && h1Bearish)
            {
               reverseDirection = -1;
               filterPassed = true;
            }
            // If closed basket was SELL, only reverse to BUY if H1 is Bullish
            else if(closedBasketDirection < 0 && h1Bullish)
            {
               reverseDirection = 1;
               filterPassed = true;
            }
            
            if(filterPassed && reverseDirection != 0)
            {
               // Check margin availability before opening reverse trade
               double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
               double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
               double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
               
               // Calculate required margin for BaseLot using OrderCalcMargin
               double marginRequired = 0;
               ENUM_ORDER_TYPE orderType = (reverseDirection > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
               if(!OrderCalcMargin(orderType, TradeSymbol, BaseLot, 
                                  (reverseDirection > 0) ? ask : bid, marginRequired))
               {
                  marginRequired = SymbolInfoDouble(TradeSymbol, SYMBOL_MARGIN_INITIAL) * BaseLot;
               }
               
               // Add spread buffer (spread cost)
               double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
               double spread = (ask - bid) / point;
               double tickValue = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_VALUE);
               double tickSize = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_SIZE);
               if(tickSize > 0 && tickValue > 0)
                  marginRequired += (spread * point) * (tickValue / tickSize) * BaseLot;
               
               if(freeMargin >= marginRequired)
               {
                  trade.SetExpertMagicNumber(MagicNumber);
                  bool opened = (reverseDirection > 0) ? 
                     trade.Buy(BaseLot, TradeSymbol, 0, 0, 0) : 
                     trade.Sell(BaseLot, TradeSymbol, 0, 0, 0);
                  
                  if(opened)
                     Print("SAR Reverse Trade Opened: Direction = ", (reverseDirection > 0 ? "BUY" : "SELL"), 
                           ", H1 Filter = ", (h1Bullish ? "Bullish" : "Bearish"));
               }
               else
               {
                  Print("SAR Failed: Insufficient Free Margin. Required: ", marginRequired, ", Available: ", freeMargin);
               }
            }
            else
            {
               Print("SAR Filter Blocked: Closed Basket Direction = ", (closedBasketDirection > 0 ? "BUY" : "SELL"),
                     ", H1 Candle = ", (h1Bullish ? "Bullish" : h1Bearish ? "Bearish" : "Neutral"));
            }
         }
      }
      
      // Return early after margin SAR - don't proceed with normal entry logic
      return;
   }
   
   if(!EnsureSymbolReady(TradeSymbol) || !SpreadOK(TradeSymbol)) return;
   double atr = GetATR();
   if(atr <= 0) return;

   ManageExits(TradeSymbol, atr);
   
   int entryDirection = DetectMomentumBreakout(TradeSymbol, atr);
   if(entryDirection != 0)
   {
      int basketDir = GetBasketDirection(TradeSymbol);
      if(basketDir != 0 && entryDirection != basketDir) return;

      if(UseLimitOrders)
      {
         if(PendingOrdersCount(TradeSymbol) > 0) return;
         for(int m=0; m<MarketOrdersAtExecution; m++) OpenMarket(TradeSymbol, entryDirection, atr);
         PlaceLimitOrders(TradeSymbol, entryDirection, atr);
      }
      else
      {
         OpenMarket(TradeSymbol, entryDirection, atr);
      }
      lastEntryTime = TimeCurrent();
   }
}