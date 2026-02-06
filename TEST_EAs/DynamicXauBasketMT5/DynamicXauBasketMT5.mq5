// DynamicXauBasketMT5.mq5
// Momentum Breakout EA - Multi-instrument (XAUUSD, EURUSD, US30, AUDUSD, USDJPY, etc.)
#property copyright "Dynamic XAU Momentum Breakout EA"
#property link      "local"
#property version   "3.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

// --- Inputs ---
input string   TradeSymbol           = "XAUUSD";  // XAUUSD, EURUSD, US30, AUDUSD, USDJPY, etc.
input int      MagicNumber           = 905533;
input double   BaseLot               = 0.01;   // Lot for first trade (min)
input double   LotStep               = 0;      // Add per trade (0 = flat BaseLot for all)
input double   MaxLot                = 0.03;   // Cap (not too much)
input int      MinTotalTrades        = 1;      // Min trades per basket
input int      MaxTotalTrades        = 10;     // Max trades per basket (1-20 dynamic)
input int      ATRPeriod             = 14;
input ENUM_TIMEFRAMES MomentumTF     = PERIOD_M1; // Momentum timeframe (M1 for scalping)
input ENUM_TIMEFRAMES ATRTimeframe   = PERIOD_M1;
input double   MomentumThresholdATR  = 0.15;   // Minimum momentum to trigger breakout entry (ATR fraction)
input int      MomentumLookback      = 2;      // Number of candles to look back for momentum
input bool     RequireVolumeConfirmation = false; // Require volume confirmation for breakout
input int      DeviationPoints       = 30;     // Slippage guard
input double   SpreadLimitPoints     = 100;    // Skip trading if spread too wide (30 forex, 50 XAU, 100 indices)
input int      MinSecondsBetweenEntries = 5;   // Min seconds between opening new trades
input bool     OneEntryPerBar       = true;   // Max one entry per M1 bar
input bool     UseLimitOrders       = true;   // Use limit orders instead of market
input int      MarketOrdersAtExecution = 2;    // Market orders to open immediately on signal
input int      LimitOrderCount      = 5;      // Number of limit orders per basket
input int      MinPendingHoldSeconds = 3;     // Min seconds before cancelling pendings on direction change
input int      PendingOrderTimeoutSeconds = 60; // Cancel pendings if not filled after this many seconds

// --- Stop Loss Settings ---
input bool     UseStopLoss           = true;   // Enable stop loss
input double   StopLossATRMultiplierXAU   = 3.0;   // ATR multiplier (XAUUSD)
input double   StopLossATRMultiplierOther = 3.0;   // ATR multiplier (other)
input double   StopLossMinPointsXAU       = 1500;  // Floor: min SL points (XAUUSD/GOLD)
input double   StopLossMinPointsOther    = 150;   // Floor for forex (EURUSD, USDJPY, AUDUSD)
input double   StopLossMinPointsIndex    = 200;   // Floor for indices (US30, etc.)
input double   StopLossMaxPointsXAU       = 6000; // Cap: max SL points (XAUUSD/GOLD)
input double   StopLossMaxPointsOther    = 600;   // Cap for forex
input double   StopLossMaxPointsIndex    = 2000; // Cap for indices
input double   StopLossATRMultiplierIndex = 3.0;  // ATR multiplier for indices

// --- Basket Profit Settings ---
input bool     UseBasketProfit       = true;   // Close all trades when basket profit target reached
input double   BasketProfitATRMultiplier = 2.5; // Basket profit target as multiple of ATR
input double   BasketProfitPercent   = 2.0;    // Alternative: Basket profit as % of account balance
input bool     UsePercentForBasket   = false;  // If true use %, if false use ATR multiplier
input bool     IncludeAllTrades      = true;   // Include all trades (even pre-existing) in basket profit
input bool     CloseEarlyWhenProfitable = true; // Close basket early when profitable (even below target)
input double   EarlyCloseProfitATR   = 1.5;    // Close basket early at this ATR multiplier (if profitable)
input double   EarlyCloseProfitPercent = 1.0;  // Alternative: Close early at this % profit
input bool     UsePercentForEarlyClose = false; // If true use % for early close, if false use ATR
input bool     CloseAtAnyProfit        = true;  // Close basket as soon as profit > 0
input double   MinProfitToClose       = 0.01;   // Minimum profit (currency) to trigger close
input bool     UseTimeBasedClose      = true;  // Require min hold time before closing profit
input int      MinHoldSeconds         = 1;     // Min seconds to hold before close (1-5 sec window)
input int      MaxHoldSeconds         = 5;     // Max seconds for close window
input int      CloseMode             = 2;     // 0=basket only, 1=individual only, 2=both

// --- Exit Settings ---
input bool     UseBreakEven          = false;  // Move stop loss to break-even (disables wide SL)
input double   BreakEvenTriggerATR   = 0.5;    // Move to BE when profit reaches this ATR
input bool     UseTrailingStop       = false;  // Use trailing stop (disables wide SL)
input double   TrailingStopATR        = 1.0;    // Trailing stop distance in ATR
input double   TrailingStepATR       = 0.3;    // Trailing step in ATR

// --- Globals ---
CTrade         trade;
CPositionInfo  pos;
int            atrHandle     = -1;
bool           eaInitialized = false;
double         lastPrice     = 0.0;  // Track last price for momentum calculation
datetime       lastEntryTime = 0;    // Entry cooldown
datetime       lastEntryBar  = 0;    // One entry per bar

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

// Symbol type helpers for multi-instrument support (XAUUSD, GOLD, EURUSD, US30, AUDUSD, USDJPY, etc.)
bool IsGoldSymbol(const string symbol)
{
   return (StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0);
}
bool IsIndexSymbol(const string symbol)
{
   return (StringFind(symbol, "US30") >= 0 || StringFind(symbol, "DJ30") >= 0 ||
           StringFind(symbol, "USTEC") >= 0 || StringFind(symbol, "NAS") >= 0 ||
           StringFind(symbol, "US500") >= 0 || StringFind(symbol, "SPX") >= 0);
}

// Close all existing trades (any magic number) when EA is activated
void CloseAllExistingTrades(const string symbol)
{
   int closed = 0;
   int deleted = 0;
   
   // Close all market positions
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      
      ulong ticket = pos.Ticket();
      if(trade.PositionClose(ticket, DeviationPoints))
      {
         closed++;
         Print("Closed existing position: ", ticket);
      }
   }
   
   // Delete all pending orders
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      
      ulong ticket = OrderGetInteger(ORDER_TICKET);
      if(trade.OrderDelete(ticket))
      {
         deleted++;
         Print("Deleted existing order: ", ticket);
      }
   }
   
   if(closed > 0 || deleted > 0)
      Print("Closed ", closed, " positions and deleted ", deleted, " orders on EA activation");
}

double GetATR()
{
   if(atrHandle < 0)
      return 0.0;
   double buffer[2];
   if(CopyBuffer(atrHandle, 0, 0, 2, buffer) < 1)
      return 0.0;
   return buffer[0];
}

// Detect Momentum Breakout - Simple and effective for scalping
int DetectMomentumBreakout(const string symbol, double atr)
{
   if(atr <= 0)
      return 0;
   
   double close[];
   long volume[];
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(volume, true);
   
   int lookback = MomentumLookback + 1;
   if(CopyClose(symbol, MomentumTF, 0, lookback, close) < lookback)
      return 0;
   
   if(RequireVolumeConfirmation)
   {
      if(CopyTickVolume(symbol, MomentumTF, 0, lookback, volume) < lookback)
         return 0;
   }
   
   // Calculate momentum over lookback period
   double momentum = close[0] - close[MomentumLookback];
   double momentumThreshold = atr * MomentumThresholdATR;
   
   // Check if momentum exceeds threshold
   if(MathAbs(momentum) < momentumThreshold)
      return 0;
   
   // Volume confirmation (if enabled)
   if(RequireVolumeConfirmation && lookback > 1)
   {
      long currentVolume = volume[0];
      long avgVolume = 0;
      for(int i = 1; i < lookback; i++)
         avgVolume += volume[i];
      avgVolume = avgVolume / (lookback - 1);
      
      // Require current volume to be above average
      if(currentVolume < avgVolume * 0.8)
         return 0;
   }
   
   // Return direction: 1 = BUY, -1 = SELL
   return (momentum > 0) ? 1 : -1;
}

// GetEMA and GetRSI removed - not used in order block strategy

double NormalizeVolume(const string symbol, double lots)
{
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   lots = MathMax(minLot, MathMin(maxLot, lots));
   if(step > 0)
      lots = MathFloor(lots / step) * step;
   lots = MathMax(minLot, lots);  // Re-apply min after rounding
   return NormalizeDouble(lots, 2);
}

double GetDynamicLot(const string symbol, int currentTrades)
{
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double lot = (LotStep == 0) ? BaseLot : (BaseLot + (currentTrades * LotStep));
   lot = MathMin(MaxLot, MathMax(minLot, lot));
   return NormalizeVolume(symbol, lot);
}

// Count all positions (including pre-existing if IncludeAllTrades is true)
int PositionsCount(const string symbol)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      
      // Include all trades if enabled, otherwise only EA trades
      if(!IncludeAllTrades && pos.Magic() != MagicNumber)
         continue;
      
      count++;
   }
   return count;
}

// Count all pending orders (including pre-existing if IncludeAllTrades is true)
int PendingOrdersCount(const string symbol)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      
      // Include all orders if enabled, otherwise only EA orders
      if(!IncludeAllTrades && OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;
      
      count++;
   }
   return count;
}

// Returns: 1 = any BUY limit, -1 = any SELL limit, 0 = none or mixed
int GetPendingOrdersDirection(const string symbol)
{
   int buys = 0, sells = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(!IncludeAllTrades && OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
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
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(!IncludeAllTrades && OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      datetime t = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(oldest == 0 || t < oldest)
         oldest = t;
   }
   return oldest;
}

void DeletePendingOrdersOnly(const string symbol)
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(!IncludeAllTrades && OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      ulong ticket = OrderGetInteger(ORDER_TICKET);
      if(trade.OrderDelete(ticket))
         Print("Deleted pending order ", ticket, " (direction change)");
   }
}

// Returns: 1 = all BUY, -1 = all SELL, 0 = no positions
int GetBasketDirection(const string symbol)
{
   int buys = 0, sells = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      if(!IncludeAllTrades && pos.Magic() != MagicNumber) continue;
      if(pos.PositionType() == POSITION_TYPE_BUY) buys++; else sells++;
   }
   if(buys == 0 && sells == 0) return 0;
   return (buys >= sells) ? 1 : -1;
}

// Calculate total profit for all trades (basket)
double BasketProfit(const string symbol)
{
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      
      // Include all trades if enabled, otherwise only EA trades
      if(!IncludeAllTrades && pos.Magic() != MagicNumber)
         continue;
      
      profit += pos.Profit();
      profit += pos.Swap();
      profit += pos.Commission();
   }
   return profit;
}

// Calculate total lots for all trades (basket)
double BasketLots(const string symbol)
{
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      
      // Include all trades if enabled, otherwise only EA trades
      if(!IncludeAllTrades && pos.Magic() != MagicNumber)
         continue;
      
      lots += pos.Volume();
   }
   return lots;
}

// Calculate dynamic basket profit target
double CalculateBasketProfitTarget(const string symbol, double atr, double totalLots)
{
   if(!UseBasketProfit)
      return 0.0;
   
   double target = 0.0;
   
   if(UsePercentForBasket)
   {
      // Use percentage of account balance
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      target = balance * (BasketProfitPercent / 100.0);
   }
   else
   {
      // Use ATR-based calculation
      if(atr > 0 && totalLots > 0)
      {
         double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
         double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
         if(tickSize > 0)
         {
            double valuePerPoint = tickValue / tickSize;
            double atrTarget = atr * BasketProfitATRMultiplier;
            target = atrTarget * valuePerPoint * totalLots;
         }
      }
   }
   
   return MathMax(target, 1.0); // Minimum target of $1
}

datetime BasketOldestOpen(const string symbol)
{
   datetime oldest = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      if(!IncludeAllTrades && pos.Magic() != MagicNumber) continue;
      datetime opentime = pos.Time();
      if(oldest == 0 || opentime < oldest)
         oldest = opentime;
   }
   return oldest;
}

// Velocity: current bar range / ATR (0-1). High = fast market.
double GetVelocity(const string symbol, double atr)
{
   if(atr <= 0) return 0;
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   if(CopyHigh(symbol, MomentumTF, 0, 1, high) < 1 || CopyLow(symbol, MomentumTF, 0, 1, low) < 1)
      return 0;
   double range = high[0] - low[0];
   return MathMin(1.0, range / atr);
}

// Removed - not used in new strategy

// Close all trades in basket (including pre-existing if IncludeAllTrades is true)
// Uses async mode for near-simultaneous bulk close
bool CloseBasket(const string symbol)
{
   // Collect position tickets first (positions may disappear during async close)
   ulong posTickets[];
   int nPos = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      if(!IncludeAllTrades && pos.Magic() != MagicNumber) continue;
      ArrayResize(posTickets, nPos + 1);
      posTickets[nPos++] = pos.Ticket();
   }
   
   // Collect order tickets
   ulong ordTickets[];
   int nOrd = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(!IncludeAllTrades && OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      ArrayResize(ordTickets, nOrd + 1);
      ordTickets[nOrd++] = OrderGetInteger(ORDER_TICKET);
   }
   
   // Bulk close: async mode for near-simultaneous execution
   trade.SetAsyncMode(true);
   for(int i = 0; i < nPos; i++)
      trade.PositionClose(posTickets[i], DeviationPoints);
   for(int i = 0; i < nOrd; i++)
      trade.OrderDelete(ordTickets[i]);
   trade.SetAsyncMode(false);
   
   if(nPos > 0 || nOrd > 0)
   {
      Print("Basket closed: ", nPos, " positions and ", nOrd, " orders closed/deleted for ", symbol);
      Print("All trades closed - profit booked.");
   }
   
   return true;
}

// Returns SL distance in price (floor + ATR + cap)
double GetStopLossDistance(const string symbol, double atr)
{
   if(!UseStopLoss)
      return 0;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double mult, minPt, maxPt;
   if(IsGoldSymbol(symbol))
      { mult = StopLossATRMultiplierXAU; minPt = StopLossMinPointsXAU; maxPt = StopLossMaxPointsXAU; }
   else if(IsIndexSymbol(symbol))
      { mult = StopLossATRMultiplierIndex; minPt = StopLossMinPointsIndex; maxPt = StopLossMaxPointsIndex; }
   else
      { mult = StopLossATRMultiplierOther; minPt = StopLossMinPointsOther; maxPt = StopLossMaxPointsOther; }
   double atrDist = (atr > 0) ? atr * mult : 0;
   double minDist = minPt * point;
   double maxDist = maxPt * point;
   double dist = MathMax(minDist, MathMin(atrDist > 0 ? atrDist : minDist, maxDist));
   return dist;
}

double GetStopLossPrice(const string symbol, int direction, double atr)
{
   if(!UseStopLoss)
      return 0;
   double dist = GetStopLossDistance(symbol, atr);
   if(dist <= 0)
      return 0;
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(direction > 0) // BUY
      return NormalizeDouble(ask - dist, digits);
   return NormalizeDouble(bid + dist, digits);
}

bool OpenMarket(const string symbol, int direction, double atr)
{
   // Check total trades limit (dynamic 1-10)
   int totalTrades = PositionsCount(symbol) + PendingOrdersCount(symbol);
   int maxTrades = MathMax(MinTotalTrades, MathMin(10, MaxTotalTrades));
   if(totalTrades >= maxTrades)
   {
      Print("Maximum trades limit reached: ", totalTrades, "/", maxTrades);
      return false;
   }
   
   double lot = GetDynamicLot(symbol, totalTrades);
   if(lot <= 0)
   {
      Print("Lot calculation failed, aborting entry");
      return false;
   }
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   
   double stopLoss = GetStopLossPrice(symbol, direction, atr);
   // NO TAKE PROFIT - Let trades run until basket profit target is reached
   double takeProfit = 0; // No individual TP - basket management only
   bool result = false;
   
   if(direction > 0)
      result = trade.Buy(lot, symbol, 0, stopLoss, 0, "Momentum BUY");
   else
      result = trade.Sell(lot, symbol, 0, stopLoss, 0, "Momentum SELL");
   
   if(result)
   {
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      double slDist = GetStopLossDistance(symbol, atr);
      double slPoints = (point > 0) ? slDist / point : 0;
      Print("Opened trade: ", (direction > 0 ? "BUY" : "SELL"), 
            " | Lot: ", DoubleToString(lot, 2),
            " | SL: ", DoubleToString(stopLoss, 5), " (", DoubleToString(slPoints, 1), " pts)",
            " | TP: NONE (Basket management only)");
   }
   else
      Print("Failed to open trade. Error: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   return result;
}

bool PlaceLimitOrders(const string symbol, int direction, double atr)
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stopLossDist = GetStopLossDistance(symbol, atr);
   
   double offsets[] = {0.2, 0.4, 0.6, 0.8, 1.0};
   double minOffset = MathMax(atr * 0.2, (double)stopsLevel * point);
   int placed = 0;
   int n = MathMin(5, LimitOrderCount);
   
   for(int i = 0; i < n; i++)
   {
      double lot = GetDynamicLot(symbol, PositionsCount(symbol) + PendingOrdersCount(symbol) + i);
      double offset = MathMax(atr * offsets[i], minOffset);
      double limitPrice = 0;
      double sl = 0;
      
      if(direction > 0)  // BUY LIMIT
      {
         limitPrice = NormalizeDouble(bid - offset, digits);
         sl = NormalizeDouble(limitPrice - stopLossDist, digits);
         if(trade.BuyLimit(lot, limitPrice, symbol, sl, 0, ORDER_TIME_GTC, 0, "Limit BUY"))
            placed++;
         else
            Print("BuyLimit failed: ", trade.ResultRetcode(), " at ", limitPrice);
      }
      else  // SELL LIMIT
      {
         limitPrice = NormalizeDouble(ask + offset, digits);
         sl = NormalizeDouble(limitPrice + stopLossDist, digits);
         if(trade.SellLimit(lot, limitPrice, symbol, sl, 0, ORDER_TIME_GTC, 0, "Limit SELL"))
            placed++;
         else
            Print("SellLimit failed: ", trade.ResultRetcode(), " at ", limitPrice);
      }
   }
   if(placed > 0)
      Print("Placed ", placed, "/", n, " limit orders (", (direction > 0 ? "BUY" : "SELL"), ")");
   return (placed == n);
}

bool SpreadOK(const string symbol)
{
   double spread = (SymbolInfoDouble(symbol, SYMBOL_ASK) - SymbolInfoDouble(symbol, SYMBOL_BID)) / SymbolInfoDouble(symbol, SYMBOL_POINT);
   return spread <= SpreadLimitPoints;
}

// Basket Exit Management - Close individual or basket when profitable
void ManageExits(const string symbol, double atr)
{
   if(atr <= 0) return;
   
   // Calculate basket profit and target
   double basketProfit = BasketProfit(symbol);
   double totalLots = BasketLots(symbol);
   double profitTarget = CalculateBasketProfitTarget(symbol, atr, totalLots);
   datetime basketOldest = BasketOldestOpen(symbol);
   int basketAgeSec = (int)(TimeCurrent() - basketOldest);
   int holdSeconds = UseTimeBasedClose ? MinHoldSeconds : 0;
   
   // Spread-aware profit floor: only close if profit >= 1.2x spread cost (avoids losing to spread on XAUUSD)
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double spreadPts = (point > 0) ? (ask - bid) / point : 0;
   double spreadCost = 0;
   if(point > 0 && tickSize > 0 && totalLots > 0)
      spreadCost = (spreadPts * point) * (totalLots / tickSize) * tickValue;
   double profitFloor = MathMax(MinProfitToClose, 1.2 * spreadCost);
   
   // CloseMode 1 or 2: Close individual positions when profitable (1 sec hold)
   int individualClosed = 0;
   if(CloseMode == 1 || CloseMode == 2)
   {
      for(int i = PositionsTotal() - 1; i >= 0; --i)
      {
         if(!pos.SelectByIndex(i)) continue;
         if(pos.Symbol() != symbol) continue;
         if(!IncludeAllTrades && pos.Magic() != MagicNumber) continue;
         
         double posProfit = pos.Profit() + pos.Swap() + pos.Commission();
         int posAgeSec = (int)(TimeCurrent() - pos.Time());
         double posSpreadCost = (point > 0 && tickSize > 0) ? (spreadPts * point) * (pos.Volume() / tickSize) * tickValue : 0;
         double posProfitFloor = MathMax(MinProfitToClose, 1.2 * posSpreadCost);
         if(posProfit >= posProfitFloor && posAgeSec >= holdSeconds)
         {
            ulong ticket = pos.Ticket();
            if(trade.PositionClose(ticket, DeviationPoints))
            {
               individualClosed++;
               Print("Individual close: ticket ", ticket, " profit ", DoubleToString(posProfit, 2));
            }
         }
      }
      if(individualClosed > 0 && CloseMode == 2)
         return;  // For CLOSE_BOTH, skip basket close this tick after individual closes
   }
   
   // CloseMode 0 or 2: Close basket when profitable (1 sec hold), profit >= profit floor (1.2x spread cost)
   if((CloseMode == 0 || CloseMode == 2) && CloseAtAnyProfit && basketProfit >= profitFloor && basketProfit > 0)
   {
      bool canClose = (holdSeconds == 0 || basketAgeSec >= holdSeconds);
      if(canClose)
      {
         Print("Basket profitable - closing all. Profit: ", DoubleToString(basketProfit, 2));
         CloseBasket(symbol);
         return;
      }
   }
   
   // Check if basket profit target is reached (full target)
   if(UseBasketProfit && profitTarget > 0 && basketProfit >= profitTarget && basketProfit > 0)
   {
      Print("Basket profit target reached! Closing all trades.");
      Print("Basket Profit: ", DoubleToString(basketProfit, 2), 
            " | Target: ", DoubleToString(profitTarget, 2),
            " | Total Lots: ", DoubleToString(totalLots, 2));
      
      CloseBasket(symbol);
      return;
   }
   
   // Early close when profitable (even if below full target)
   if(CloseEarlyWhenProfitable && basketProfit > 0)
   {
      double earlyCloseTarget = 0.0;
      
      if(UsePercentForEarlyClose)
      {
         // Use percentage of account balance
         double balance = AccountInfoDouble(ACCOUNT_BALANCE);
         earlyCloseTarget = balance * (EarlyCloseProfitPercent / 100.0);
      }
      else
      {
         // Use ATR-based calculation
         if(atr > 0 && totalLots > 0)
         {
            double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
            double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
            if(tickSize > 0)
            {
               double valuePerPoint = tickValue / tickSize;
               double atrTarget = atr * EarlyCloseProfitATR;
               earlyCloseTarget = atrTarget * valuePerPoint * totalLots;
            }
         }
      }
      
      // Close basket if early profit target reached
      if(earlyCloseTarget > 0 && basketProfit >= earlyCloseTarget)
      {
         Print("Early basket close triggered! Basket is profitable.");
         Print("Basket Profit: ", DoubleToString(basketProfit, 2), 
               " | Early Close Target: ", DoubleToString(earlyCloseTarget, 2),
               " | Full Target: ", DoubleToString(profitTarget, 2),
               " | Total Lots: ", DoubleToString(totalLots, 2));
         
         CloseBasket(symbol);
         return;
      }
   }
   
   // Break-even protection and stop loss management
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double stopLossDist = GetStopLossDistance(symbol, atr);
   double breakEvenTrigger = atr * BreakEvenTriggerATR;
   
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      
      // Include all trades if enabled
      if(!IncludeAllTrades && pos.Magic() != MagicNumber)
         continue;
      
      ulong ticket = pos.Ticket();
      double currentSL = pos.StopLoss();
      double currentTP = pos.TakeProfit();
      double openPrice = pos.PriceOpen();
      double positionProfit = pos.Profit() + pos.Swap() + pos.Commission();
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)pos.PositionType();
      
      // Add stop loss if missing
      if(UseStopLoss && currentSL == 0 && stopLossDist > 0)
      {
         double newSL = 0;
         
         if(ptype == POSITION_TYPE_BUY)
            newSL = ask - stopLossDist;
         else if(ptype == POSITION_TYPE_SELL)
            newSL = bid + stopLossDist;
         
         if(newSL > 0)
         {
            newSL = NormalizeDouble(newSL, digits);
            trade.PositionModify(ticket, newSL, currentTP);
         }
         continue;
      }
      
      // Break-even protection - move SL to entry when profitable
      if(UseBreakEven && currentSL > 0 && positionProfit > 0)
      {
         double priceDistance = 0;
         bool shouldMoveToBE = false;
         
         if(ptype == POSITION_TYPE_BUY)
         {
            priceDistance = bid - openPrice;
            // Move to BE if profit distance >= trigger and SL is below entry
            if(priceDistance >= breakEvenTrigger && currentSL < openPrice)
               shouldMoveToBE = true;
         }
         else if(ptype == POSITION_TYPE_SELL)
         {
            priceDistance = openPrice - ask;
            // Move to BE if profit distance >= trigger and SL is above entry
            if(priceDistance >= breakEvenTrigger && currentSL > openPrice)
               shouldMoveToBE = true;
         }
         
         if(shouldMoveToBE)
         {
            double newSL = NormalizeDouble(openPrice, digits);
            // Add small buffer to avoid immediate stop
            if(ptype == POSITION_TYPE_BUY)
               newSL = NormalizeDouble(openPrice - (point * 5), digits); // 5 points below entry
            else
               newSL = NormalizeDouble(openPrice + (point * 5), digits); // 5 points above entry
               
            if(newSL != currentSL)
            {
               if(trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("Break-even set for position ", ticket, " at ", DoubleToString(newSL, digits));
               }
            }
         }
      }
   }
   
   // Trailing stop - protect profits as they grow
   if(UseTrailingStop)
   {
      double trailingDistance = atr * TrailingStopATR;
      double trailingStep = atr * TrailingStepATR;
      
      for(int i = PositionsTotal() - 1; i >= 0; --i)
      {
         if(!pos.SelectByIndex(i)) continue;
         if(pos.Symbol() != symbol) continue;
         
         // Include all trades if enabled
         if(!IncludeAllTrades && pos.Magic() != MagicNumber)
            continue;
         
         ulong ticket = pos.Ticket();
         double currentSL = pos.StopLoss();
         double currentTP = pos.TakeProfit();
         double openPrice = pos.PriceOpen();
         double positionProfit = pos.Profit() + pos.Swap() + pos.Commission();
         ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)pos.PositionType();
         
         // Only trail if position is profitable and has stop loss
         if(currentSL > 0 && positionProfit > 0)
         {
            double newSL = currentSL;
            bool modifyNeeded = false;
            
            if(ptype == POSITION_TYPE_BUY)
            {
               double idealSL = bid - trailingDistance;
               // Only move SL up, never down
               if(idealSL > currentSL + trailingStep && idealSL > openPrice)
               {
                  newSL = NormalizeDouble(idealSL, digits);
                  modifyNeeded = true;
               }
            }
            else if(ptype == POSITION_TYPE_SELL)
            {
               double idealSL = ask + trailingDistance;
               // Only move SL down, never up
               if((idealSL < currentSL - trailingStep || currentSL == 0) && idealSL < openPrice)
               {
                  newSL = NormalizeDouble(idealSL, digits);
                  modifyNeeded = true;
               }
            }
            
            if(modifyNeeded && newSL != currentSL)
            {
               if(trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("Trailing stop updated for position ", ticket, 
                        " | Old SL: ", DoubleToString(currentSL, digits),
                        " | New SL: ", DoubleToString(newSL, digits));
               }
            }
         }
      }
   }
}

// ---------------------------------------------------------------------------
// Core logic
// ---------------------------------------------------------------------------
int OnInit()
{
   if(!EnsureSymbolReady(TradeSymbol))
      return INIT_FAILED;
   
   // Close all existing trades when EA is activated
   CloseAllExistingTrades(TradeSymbol);
   
   // Initialize ATR
   atrHandle = iATR(TradeSymbol, ATRTimeframe, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ATR handle failed");
      return INIT_FAILED;
   }
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   
   double firstLot = GetDynamicLot(TradeSymbol, 0);
   double minLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   if(BaseLot < minLot)
      Print("WARNING: BaseLot ", BaseLot, " < broker min ", minLot, ". Using ", minLot);
   int maxTrades = MathMax(MinTotalTrades, MathMin(20, MaxTotalTrades));
   
   Print("========================================");
   Print("Momentum Breakout EA initialized");
   Print("========================================");
   Print("Symbol: ", TradeSymbol);
   Print("Dynamic Lot: Base=", BaseLot, " Step=", LotStep, " Max=", MaxLot, " (first=", DoubleToString(firstLot, 2), ")");
   Print("Trades per basket: ", MinTotalTrades, "-", maxTrades);
   string tfStr = (MomentumTF == PERIOD_M1) ? "M1 (Scalping)" : 
                  (MomentumTF == PERIOD_M5) ? "M5" :
                  (MomentumTF == PERIOD_M15) ? "M15" : "Custom";
   Print("Momentum Timeframe: ", tfStr);
   Print("Momentum Threshold: ", MomentumThresholdATR, "x ATR");
   Print("Momentum Lookback: ", MomentumLookback, " candles");
   Print("Volume Confirmation: ", (RequireVolumeConfirmation ? "ENABLED" : "DISABLED"));
   Print("Entry cooldown: ", MinSecondsBetweenEntries, " sec | One per bar: ", (OneEntryPerBar ? "YES" : "NO"));
   Print("Same-direction rule: ENABLED (no mixed BUY/SELL basket)");
   if(UseLimitOrders)
   {
      long stopsLevel = SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_STOPS_LEVEL);
      Print("Entry: ", MarketOrdersAtExecution, " market + ", LimitOrderCount, " limit | Min distance: ", stopsLevel, " pts");
      Print("Cancel pendings: direction change after ", MinPendingHoldSeconds, " sec | timeout ", PendingOrderTimeoutSeconds, " sec");
      double atrInit = GetATR();
      if(atrInit > 0)
      {
         double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
         double minOffset = MathMax(atrInit * 0.2, (double)stopsLevel * point);
         Print("First limit offset: ", DoubleToString(minOffset, 5), " (price)");
      }
   }
   Print("Stop Loss: ", (UseStopLoss ? "ENABLED" : "DISABLED"));
   if(UseStopLoss)
   {
      Print("  - Gold (XAU/GOLD): ATR x ", StopLossATRMultiplierXAU, " | floor ", StopLossMinPointsXAU, " pts | cap ", StopLossMaxPointsXAU, " pts");
      Print("  - Forex (EURUSD, USDJPY, AUDUSD): ATR x ", StopLossATRMultiplierOther, " | floor ", StopLossMinPointsOther, " pts | cap ", StopLossMaxPointsOther, " pts");
      Print("  - Indices (US30): ATR x ", StopLossATRMultiplierIndex, " | floor ", StopLossMinPointsIndex, " pts | cap ", StopLossMaxPointsIndex, " pts");
   }
   Print("Trailing Stop: ", (UseTrailingStop ? "ENABLED" : "DISABLED"));
   if(UseTrailingStop)
   {
      Print("  - Trailing distance: ", TrailingStopATR, " ATR");
      Print("  - Trailing step: ", TrailingStepATR, " ATR");
   }
   Print("Strategy: MOMENTUM BREAKOUT - NO INDIVIDUAL TAKE PROFIT - Basket Management Only");
   Print("Basket Profit Management: ", (UseBasketProfit ? "ENABLED" : "DISABLED"));
   if(UseBasketProfit)
   {
      if(UsePercentForBasket)
         Print("  - Profit Target: ", BasketProfitPercent, "% of account balance");
      else
         Print("  - Profit Target: ", BasketProfitATRMultiplier, "x ATR");
      Print("  - Include All Trades: ", (IncludeAllTrades ? "YES" : "NO (EA trades only)"));
      if(CloseEarlyWhenProfitable)
      {
         if(UsePercentForEarlyClose)
            Print("  - Early Close: ", EarlyCloseProfitPercent, "% profit");
         else
            Print("  - Early Close: ", EarlyCloseProfitATR, "x ATR profit");
      }
      if(CloseAtAnyProfit)
         Print("  - Close At Any Profit: ", MinProfitToClose, " (min currency)");
      if(UseTimeBasedClose)
         Print("  - Time-based hold: ", MinHoldSeconds, "-", MaxHoldSeconds, " sec");
      Print("  - CloseMode: ", CloseMode, " (0=basket 1=individual 2=both)");
   }
   Print("Break-Even Protection: ", (UseBreakEven ? "ENABLED" : "DISABLED"));
   if(UseBreakEven)
      Print("  - Break-Even Trigger: ", BreakEvenTriggerATR, "x ATR profit");
   Print("Trailing Stop: ", (UseTrailingStop ? "ENABLED" : "DISABLED"));
   if(UseTrailingStop)
   {
      Print("  - Trailing distance: ", TrailingStopATR, " ATR");
      Print("  - Trailing step: ", TrailingStepATR, " ATR");
   }
   Print("========================================");
   
   eaInitialized = true;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   // Release indicator handles
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   Print("EA stopped. reason=", reason);
}

void OnTick()
{
   if(!EnsureSymbolReady(TradeSymbol))
      return;
   if(!SpreadOK(TradeSymbol))
      return;

   double atr = GetATR();
   if(atr <= 0.0)
      return;

   int totalTrades = PositionsCount(TradeSymbol) + PendingOrdersCount(TradeSymbol);
   
   // Manage exits - check basket profit and close all trades if target reached
   ManageExits(TradeSymbol, atr);
   
   // Recalculate after exits
   totalTrades = PositionsCount(TradeSymbol) + PendingOrdersCount(TradeSymbol);
   int maxTrades = MathMax(MinTotalTrades, MathMin(20, MaxTotalTrades));
   
   // Log basket profit status periodically
   static datetime lastBasketLog = 0;
   if(UseBasketProfit && TimeCurrent() - lastBasketLog > 60) // Log every minute
   {
      double basketProfit = BasketProfit(TradeSymbol);
      double totalLots = BasketLots(TradeSymbol);
      double profitTarget = CalculateBasketProfitTarget(TradeSymbol, atr, totalLots);
      
      if(totalTrades > 0)
      {
         Print("Basket Status: ", totalTrades, " trades | Profit: ", DoubleToString(basketProfit, 2), 
               " | Target: ", DoubleToString(profitTarget, 2),
               " | Progress: ", DoubleToString((basketProfit / profitTarget) * 100.0, 1), "%");
      }
      lastBasketLog = TimeCurrent();
   }
   
   // Check trade limit
   int maxForMode = UseLimitOrders ? (MarketOrdersAtExecution + LimitOrderCount) : maxTrades;
   if(totalTrades >= maxForMode)
      return;
   
   // Momentum Breakout Entry - Simple and effective for scalping
   int entryDirection = DetectMomentumBreakout(TradeSymbol, atr);
   
   // Log momentum status periodically
   static datetime lastMomentumLog = 0;
   if(TimeCurrent() - lastMomentumLog > 30) // Log every 30 seconds
   {
      if(entryDirection != 0)
      {
         double close[];
         ArraySetAsSeries(close, true);
         if(CopyClose(TradeSymbol, MomentumTF, 0, MomentumLookback + 1, close) >= MomentumLookback + 1)
         {
            double momentum = close[0] - close[MomentumLookback];
            double threshold = atr * MomentumThresholdATR;
            Print("Momentum Breakout detected: ", (entryDirection > 0 ? "BUY" : "SELL"),
                  " | Momentum: ", DoubleToString(momentum, 5),
                  " | Threshold: ", DoubleToString(threshold, 5));
         }
      }
      else
      {
         Print("Waiting for momentum breakout signal...");
      }
      lastMomentumLog = TimeCurrent();
   }
   
   // Open trade if momentum breakout detected
   if(entryDirection != 0)
   {
      // Same-direction rule: do not add opposite direction to basket
      int basketDir = GetBasketDirection(TradeSymbol);
      if(basketDir != 0 && entryDirection != basketDir)
         return;
      
      int pendingCount = PendingOrdersCount(TradeSymbol);
      
      if(UseLimitOrders)
      {
         // Cancel pendings on direction change (after min hold) or timeout (not filled)
         if(pendingCount > 0)
         {
            int pendingDir = GetPendingOrdersDirection(TradeSymbol);
            datetime oldestPending = GetOldestPendingOrderTime(TradeSymbol);
            int pendingAgeSec = (int)(TimeCurrent() - oldestPending);
            bool cancelOnDirection = (pendingDir != 0 && entryDirection != pendingDir && pendingAgeSec >= MinPendingHoldSeconds);
            bool cancelOnTimeout = (pendingAgeSec >= PendingOrderTimeoutSeconds);
            if(cancelOnDirection || cancelOnTimeout)
            {
               DeletePendingOrdersOnly(TradeSymbol);
               return;
            }
            return;  // Place only when no pendings (avoid duplicates)
         }
         // Entry cooldown
         if(TimeCurrent() - lastEntryTime < MinSecondsBetweenEntries)
            return;
         if(OneEntryPerBar)
         {
            datetime barTime = iTime(TradeSymbol, MomentumTF, 0);
            if(lastEntryBar == barTime)
               return;
         }
         
         double currentPrice = (SymbolInfoDouble(TradeSymbol, SYMBOL_BID) + SymbolInfoDouble(TradeSymbol, SYMBOL_ASK)) / 2.0;
         Print("Momentum Entry Signal: ", (entryDirection > 0 ? "BUY" : "SELL"),
               " | Price: ", DoubleToString(currentPrice, 5),
               " | Opening ", MarketOrdersAtExecution, " market + ", LimitOrderCount, " limit");
         
         // 1. Open 2 market orders immediately
         int marketOpened = 0;
         for(int m = 0; m < MarketOrdersAtExecution; m++)
         {
            int currentTotal = PositionsCount(TradeSymbol) + PendingOrdersCount(TradeSymbol);
            if(currentTotal >= maxForMode) break;
            if(OpenMarket(TradeSymbol, entryDirection, atr))
               marketOpened++;
         }
         
         // 2. Place 5 limit orders
         bool limitsOk = PlaceLimitOrders(TradeSymbol, entryDirection, atr);
         
         if(marketOpened > 0 || limitsOk)
         {
            lastEntryTime = TimeCurrent();
            if(OneEntryPerBar)
               lastEntryBar = iTime(TradeSymbol, MomentumTF, 0);
            Print("✓ Opened ", marketOpened, " market + ", (limitsOk ? LimitOrderCount : 0), " limits");
         }
         else
            Print("✗ Failed to place orders.");
      }
      else
      {
         // Market order path
         if(TimeCurrent() - lastEntryTime < MinSecondsBetweenEntries)
            return;
         if(OneEntryPerBar)
         {
            datetime barTime = iTime(TradeSymbol, MomentumTF, 0);
            if(lastEntryBar == barTime)
               return;
         }
         
         double currentPrice = (SymbolInfoDouble(TradeSymbol, SYMBOL_BID) + SymbolInfoDouble(TradeSymbol, SYMBOL_ASK)) / 2.0;
         Print("Momentum Breakout Entry Signal: ", (entryDirection > 0 ? "BUY" : "SELL"),
               " | Current Price: ", DoubleToString(currentPrice, 5),
               " | Total trades: ", totalTrades, "/", maxTrades);
         
         if(OpenMarket(TradeSymbol, entryDirection, atr))
         {
            lastEntryTime = TimeCurrent();
            if(OneEntryPerBar)
               lastEntryBar = iTime(TradeSymbol, MomentumTF, 0);
            Print("✓ Trade opened successfully");
         }
         else
            Print("✗ Failed to open trade.");
      }
   }
}

// Safety: clean up dangling pendings on stop
void OnTesterDeinit()
{
   CloseBasket(TradeSymbol);
}











