//+------------------------------------------------------------------+
//|      ULTRA FAST MEAN-REVERSION SCALPER WITH PENDING ORDERS     |
//|      - Pending Orders                                           |
//|      - Max Trades Per Minute                                    |
//|      - Ultra Fast Scalping Mode                                 |
//|      Author: McGibs Digital Solutions                           |
//|      Version: 2.00 (MT5 Optimized)                              |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "2.00"

#include <Trade\Trade.mqh>

CTrade trade;

//---------------- INPUTS ----------------

// --- Core Mean Reversion ---
input group "===== Core Mean Reversion ====="
input int      MAPeriod            = 20;
input double   DeviationMultiplier = 1.2;
input double   MinDeviationPips    = 3.0;

// --- Micro Scalping Mode ---
input group "===== Micro Scalping Mode ====="
input bool     ScalpingMode        = true;      // ultra fast entries
input double   MicroTPPips         = 5.0;
input double   SLpips              = 15.0;

// --- Pending Orders ---
input group "===== Pending Orders ====="
input bool     UsePendingOrders    = true;
input double   PendingDistancePips = 8.0;
input int      PendingExpireSec    = 8;

// --- Max Trades Per Minute ---
input group "===== Trade Rate Limiting ====="
input int      MaxTradesPerMinute  = 8;

// --- Lot size ---
input group "===== Position Sizing ====="
input double   LotSize             = 0.05;

// --- Spread Control ---
input group "===== Risk Management ====="
input double   MaxSpreadPips       = 6;

// --- Magic ---
input group "===== EA Settings ====="
input int      MagicNumber         = 999123;

//---------------- INTERNAL STATE ----------------

// Pending Order Tracking
struct PendingOrderInfo {
   ulong ticket;
   datetime placedTime;
   ENUM_ORDER_TYPE orderType;
};

PendingOrderInfo pendingOrders[100];
int totalPendingOrders = 0;

// Max Trades Per Minute Tracking
datetime executedTradeTimes[200];
int executedTradeCount = 0;

// Indicator Handles
int maHandle = INVALID_HANDLE;

// Performance Optimization - Cache frequently used values
static double cachedPipPoint = 0.0;
static int cachedDigits = 0;

//---------------- UTILITY FUNCTIONS ----------------

// Symbol-specific pip calculation (handles XAUUSD 3-digit and USTEC 2-digit)
double PipPoint()
{
   if(cachedPipPoint > 0.0) return cachedPipPoint;
   
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   cachedDigits = digits;
   // XAUUSD: digits=3, pip = point × 10
   // USTEC: digits=2, pip = point
   // Standard 5-digit: pip = point × 10
   cachedPipPoint = (digits == 3 || digits == 5) ? point * 10.0 : point;
   
   return cachedPipPoint;
}

// Normalize price for broker requirements
double NormalizePrice(double price)
{
   int digits = cachedDigits > 0 ? cachedDigits : (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0)
      return MathRound(price / tickSize) * tickSize;
   return NormalizeDouble(price, digits);
}

//---------------- INITIALIZATION ----------------

int OnInit()
{
   Print("========================================");
   Print("Ultra Fast Mean-Reversion Scalper v2.00");
   Print("========================================");
   Print("Symbol: ", _Symbol);
   Print("Max Trades/Min: ", MaxTradesPerMinute);
   Print("Pending Orders: ", (UsePendingOrders ? "ENABLED" : "DISABLED"));
   Print("========================================");
   
   // Initialize MA handle
   maHandle = iMA(_Symbol, PERIOD_M1, MAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(maHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create MA indicator handle");
      return INIT_FAILED;
   }
   
   // Initialize pip point cache
   PipPoint();
   
   // Set trade parameters
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   
   // Set filling mode
   ENUM_ORDER_TYPE_FILLING fillingMode = ORDER_FILLING_FOK;
   long fillingModeFlags = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingModeFlags & SYMBOL_FILLING_FOK) != 0)
      fillingMode = ORDER_FILLING_FOK;
   else if((fillingModeFlags & SYMBOL_FILLING_IOC) != 0)
      fillingMode = ORDER_FILLING_IOC;
   else
      fillingMode = ORDER_FILLING_RETURN;
   trade.SetTypeFilling(fillingMode);
   
   // Validate inputs
   if(MAPeriod <= 0 || DeviationMultiplier <= 0 || MinDeviationPips <= 0)
   {
      Print("ERROR: Invalid input parameters");
      return INIT_FAILED;
   }
   
   if(LotSize <= 0)
   {
      Print("ERROR: LotSize must be greater than 0");
      return INIT_FAILED;
   }
   
   // Initialize arrays
   for(int i = 0; i < 100; i++)
   {
      pendingOrders[i].ticket = 0;
      pendingOrders[i].placedTime = 0;
      pendingOrders[i].orderType = WRONG_VALUE;
   }
   for(int i = 0; i < 200; i++)
   {
      executedTradeTimes[i] = 0;
   }
   totalPendingOrders = 0;
   executedTradeCount = 0;
   
   Print("Ultra Fast Scalper initialized successfully");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   // Clean up pending orders array
   for(int i = 0; i < totalPendingOrders; i++)
   {
      if(pendingOrders[i].ticket > 0)
      {
         // Try to delete if still exists
         if(OrderSelect(pendingOrders[i].ticket))
            trade.OrderDelete(pendingOrders[i].ticket);
      }
   }
   
   // Release indicator handle
   if(maHandle != INVALID_HANDLE)
      IndicatorRelease(maHandle);
   
   Print("Ultra Fast Scalper deinitialized. Reason: ", reason);
}

//---------------- ONTICK ----------------

void OnTick()
{
   // Spread check
   if(!SpreadOK()) return;
   
   // Clean up expired pending orders
   CleanupExpiredPendings();
   
   // Check max trades per minute
   if(!CanTradeNow()) return;
   
   // Get mean reversion signal
   ENUM_POSITION_TYPE dir = GetDeviationSignal();
   
   if(dir != WRONG_VALUE)
   {
      if(UsePendingOrders)
         PlacePendingOrder(dir);
      else
         OpenMarketOrder(dir);
   }
}

//---------------- SPREAD CHECK ----------------

bool SpreadOK()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;
   
   double spread = (tick.ask - tick.bid) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipPoint = PipPoint();
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // Convert spread to pips
   double spreadPips = spread * (point / pipPoint);
   
   if(spreadPips > MaxSpreadPips)
   {
      static datetime lastLog = 0;
      if(TimeCurrent() - lastLog > 60)
      {
         Print("Spread too high: ", DoubleToString(spreadPips, 2), " pips (Max: ", MaxSpreadPips, ")");
         lastLog = TimeCurrent();
      }
      return false;
   }
   
   return true;
}

//---------------- MAX TRADES PER MINUTE ----------------

bool CanTradeNow()
{
   datetime now = TimeCurrent();
   int count = 0;
   
   // Count trades in last 60 seconds
   for(int i = 0; i < executedTradeCount; i++)
   {
      if(executedTradeTimes[i] > 0 && (now - executedTradeTimes[i]) <= 60)
         count++;
   }
   
   if(count >= MaxTradesPerMinute)
   {
      static datetime lastLog = 0;
      if(TimeCurrent() - lastLog > 5)
      {
         Print("MAX TRADES PER MINUTE BLOCKED: ", count, " trades in last 60 seconds (Limit: ", MaxTradesPerMinute, ")");
         lastLog = TimeCurrent();
      }
      return false;
   }
   
   return true;
}

// Clean up old trade times (older than 60 seconds)
void CleanupOldTradeTimes()
{
   datetime now = TimeCurrent();
   int writeIdx = 0;
   
   for(int i = 0; i < executedTradeCount; i++)
   {
      if(executedTradeTimes[i] > 0 && (now - executedTradeTimes[i]) <= 60)
      {
         executedTradeTimes[writeIdx] = executedTradeTimes[i];
         writeIdx++;
      }
   }
   
   // Clear remaining slots
   for(int i = writeIdx; i < executedTradeCount; i++)
      executedTradeTimes[i] = 0;
   
   executedTradeCount = writeIdx;
}

//---------------- GET SIGNAL ----------------

ENUM_POSITION_TYPE GetDeviationSignal()
{
   // Get live price (shift=0 for scalping mode)
   double closePrice[];
   ArraySetAsSeries(closePrice, true);
   if(CopyClose(_Symbol, PERIOD_M1, 0, 1, closePrice) <= 0)
   {
      Print("ERROR: Failed to copy close price");
      return WRONG_VALUE;
   }
   double price = closePrice[0];
   if(price <= 0) return WRONG_VALUE;
   
   // Get SMA value
   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(maHandle, 0, 0, 1, ma) <= 0)
   {
      Print("ERROR: Failed to copy MA buffer");
      return WRONG_VALUE;
   }
   double maValue = ma[0];
   if(maValue <= 0) return WRONG_VALUE;
   
   // Calculate Standard Deviation (optimized single-pass)
   double stdDev = CalcStdDev();
   if(stdDev <= 0)
   {
      Print("ERROR: Invalid standard deviation");
      return WRONG_VALUE;
   }
   
   double pipPoint = PipPoint();
   double deviationPips = MathAbs(price - maValue) / pipPoint;
   double threshold = MathMax(MinDeviationPips, (stdDev * DeviationMultiplier) / pipPoint);
   
   // Log signal detection
   static datetime lastSignalLog = 0;
   if(TimeCurrent() - lastSignalLog > 10)
   {
      Print("Signal Check: Price=", DoubleToString(price, 5), 
            " MA=", DoubleToString(maValue, 5),
            " Deviation=", DoubleToString(deviationPips, 2), " pips",
            " Threshold=", DoubleToString(threshold, 2), " pips");
      lastSignalLog = TimeCurrent();
   }
   
   if(deviationPips < threshold)
      return WRONG_VALUE;
   
   // Determine direction
   ENUM_POSITION_TYPE direction = WRONG_VALUE;
   
   if(price < maValue - (stdDev * DeviationMultiplier))
   {
      direction = POSITION_TYPE_BUY;
      Print("BUY SIGNAL: Price below MA deviation zone. Deviation=", DoubleToString(deviationPips, 2), " pips");
   }
   else if(price > maValue + (stdDev * DeviationMultiplier))
   {
      direction = POSITION_TYPE_SELL;
      Print("SELL SIGNAL: Price above MA deviation zone. Deviation=", DoubleToString(deviationPips, 2), " pips");
   }
   
   return direction;
}

//---------------- STDDEV CALCULATION (OPTIMIZED) ----------------

double CalcStdDev()
{
   double close[];
   double ma[];
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(ma, true);
   
   if(CopyClose(_Symbol, PERIOD_M1, 0, MAPeriod, close) <= 0) return 0;
   if(CopyBuffer(maHandle, 0, 0, 1, ma) <= 0) return 0;
   
   double m = ma[0];
   if(m <= 0) return 0;
   
   // Single-pass variance calculation
   double sumSq = 0;
   int validCount = 0;
   
   for(int i = 0; i < MAPeriod && i < ArraySize(close); i++)
   {
      if(close[i] > 0)
      {
         double diff = close[i] - m;
         sumSq += diff * diff;
         validCount++;
      }
   }
   
   if(validCount <= 1) return 0;
   
   double variance = sumSq / validCount;
   if(variance <= 0) return 0;
   
   return MathSqrt(variance);
}

//---------------- MARKET ORDER ----------------

void OpenMarketOrder(ENUM_POSITION_TYPE dir)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("ERROR: Failed to get tick data");
      return;
   }
   
   double pipPoint = PipPoint();
   double price = (dir == POSITION_TYPE_BUY) ? tick.ask : tick.bid;
   double sl = (dir == POSITION_TYPE_BUY) ? 
               NormalizePrice(price - SLpips * pipPoint) : 
               NormalizePrice(price + SLpips * pipPoint);
   double tp = (dir == POSITION_TYPE_BUY) ? 
               NormalizePrice(price + MicroTPPips * pipPoint) : 
               NormalizePrice(price - MicroTPPips * pipPoint);
   
   bool success = false;
   ulong ticket = 0;
   
   if(dir == POSITION_TYPE_BUY)
      success = trade.Buy(LotSize, _Symbol, price, sl, tp, "UltraFast Scalp");
   else
      success = trade.Sell(LotSize, _Symbol, price, sl, tp, "UltraFast Scalp");
   
   if(success)
   {
      // Find the position ticket (MT5 creates position immediately)
      Sleep(50); // Small delay to ensure position is registered
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong posTicket = PositionGetTicket(i);
         if(posTicket > 0 && PositionSelectByTicket(posTicket))
         {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
               ticket = posTicket;
               Print("MARKET ORDER EXECUTED: ", (dir == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                     " Ticket=", ticket,
                     " Price=", DoubleToString(price, 5),
                     " SL=", DoubleToString(sl, 5),
                     " TP=", DoubleToString(tp, 5));
               
               // Track trade execution time
               LogTradeExecution();
               break;
            }
         }
      }
   }
   else
   {
      int error = GetLastError();
      Print("MARKET ORDER FAILED: ", (dir == POSITION_TYPE_BUY ? "BUY" : "SELL"),
            " Error=", error, " (", ErrorDescription(error), ")");
   }
}

//---------------- PENDING ORDER ----------------

void PlacePendingOrder(ENUM_POSITION_TYPE dir)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("ERROR: Failed to get tick data for pending order");
      return;
   }
   
   double pipPoint = PipPoint();
   double dist = PendingDistancePips * pipPoint;
   
   // BUY LIMIT below current price, SELL LIMIT above current price
   double price = (dir == POSITION_TYPE_BUY) ? 
                  NormalizePrice(tick.bid - dist) : 
                  NormalizePrice(tick.ask + dist);
   
   double sl = (dir == POSITION_TYPE_BUY) ? 
               NormalizePrice(price - SLpips * pipPoint) : 
               NormalizePrice(price + SLpips * pipPoint);
   double tp = (dir == POSITION_TYPE_BUY) ? 
               NormalizePrice(price + MicroTPPips * pipPoint) : 
               NormalizePrice(price - MicroTPPips * pipPoint);
   
   ulong ticket = 0;
   bool success = false;
   
   // MT5: Place pending order (expiration handled manually in CleanupExpiredPendings)
   // BuyLimit/SellLimit signature: volume, price, symbol, sl, tp, type_time, expiration, comment
   if(dir == POSITION_TYPE_BUY)
   {
      success = trade.BuyLimit(LotSize, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "Pending Buy");
   }
   else
   {
      success = trade.SellLimit(LotSize, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "Pending Sell");
   }
   
   if(success)
   {
      // Find the pending order ticket
      Sleep(50); // Small delay to ensure order is registered
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong orderTicket = OrderGetTicket(i);
         if(orderTicket > 0 && OrderSelect(orderTicket))
         {
            if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
               OrderGetInteger(ORDER_MAGIC) == MagicNumber)
            {
               ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
               if((dir == POSITION_TYPE_BUY && orderType == ORDER_TYPE_BUY_LIMIT) ||
                  (dir == POSITION_TYPE_SELL && orderType == ORDER_TYPE_SELL_LIMIT))
               {
                  ticket = orderTicket;
                  
                  // Add to pending orders tracking
                  if(totalPendingOrders < 100)
                  {
                     pendingOrders[totalPendingOrders].ticket = ticket;
                     pendingOrders[totalPendingOrders].placedTime = TimeCurrent();
                     pendingOrders[totalPendingOrders].orderType = orderType;
                     totalPendingOrders++;
                     
                     Print("PENDING ORDER PLACED: ", (dir == POSITION_TYPE_BUY ? "BUY LIMIT" : "SELL LIMIT"),
                           " Ticket=", ticket,
                           " Price=", DoubleToString(price, 5),
                           " Current Bid=", DoubleToString(tick.bid, 5),
                           " Current Ask=", DoubleToString(tick.ask, 5),
                           " SL=", DoubleToString(sl, 5),
                           " TP=", DoubleToString(tp, 5),
                           " Expires in ", PendingExpireSec, " seconds");
                  }
                  break;
               }
            }
         }
      }
   }
   else
   {
      int error = GetLastError();
      Print("PENDING ORDER FAILED: ", (dir == POSITION_TYPE_BUY ? "BUY LIMIT" : "SELL LIMIT"),
            " Error=", error, " (", ErrorDescription(error), ")");
   }
}

//---------------- CLEANUP EXPIRED PENDING ORDERS ----------------

void CleanupExpiredPendings()
{
   datetime now = TimeCurrent();
   int writeIdx = 0;
   
   // Build a set of active order tickets (single pass for efficiency)
   ulong activeOrderTickets[];
   ArrayResize(activeOrderTickets, OrdersTotal());
   int activeCount = 0;
   
   for(int j = OrdersTotal() - 1; j >= 0; j--)
   {
      ulong orderTicket = OrderGetTicket(j);
      if(orderTicket > 0 && OrderSelect(orderTicket))
      {
         if(OrderGetInteger(ORDER_MAGIC) == MagicNumber && 
            OrderGetString(ORDER_SYMBOL) == _Symbol)
         {
            activeOrderTickets[activeCount] = orderTicket;
            activeCount++;
         }
      }
   }
   
   // Now process our tracked pending orders
   for(int i = 0; i < totalPendingOrders; i++)
   {
      ulong ticket = pendingOrders[i].ticket;
      if(ticket == 0) continue;
      
      // Check if order still exists in active orders
      bool orderExists = false;
      for(int k = 0; k < activeCount; k++)
      {
         if(activeOrderTickets[k] == ticket)
         {
            orderExists = true;
            
            // Check if order has expired
            if(OrderSelect(ticket))
            {
               datetime orderTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
               if((now - orderTime) >= PendingExpireSec)
               {
                  // Delete expired order
                  if(trade.OrderDelete(ticket))
                  {
                     Print("PENDING ORDER EXPIRED: Ticket=", ticket,
                           " Type=", EnumToString((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)),
                           " Age=", (now - orderTime), " seconds");
                  }
                  else
                  {
                     int error = GetLastError();
                     Print("FAILED TO DELETE EXPIRED ORDER: Ticket=", ticket, " Error=", error);
                  }
                  orderExists = false; // Mark for removal
               }
            }
            break;
         }
      }
      
      // Keep this order in tracking array if it still exists and hasn't expired
      if(orderExists)
      {
         if(writeIdx != i)
         {
            pendingOrders[writeIdx] = pendingOrders[i];
         }
         writeIdx++;
      }
      // Otherwise, order was filled, deleted, or expired - remove from tracking
   }
   
   // Clear remaining slots
   for(int i = writeIdx; i < totalPendingOrders; i++)
   {
      pendingOrders[i].ticket = 0;
      pendingOrders[i].placedTime = 0;
      pendingOrders[i].orderType = WRONG_VALUE;
   }
   
   totalPendingOrders = writeIdx;
}

//---------------- TRADE TRANSACTION HANDLER ----------------

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   // Track when pending orders become positions (for max trades per minute)
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(HistoryDealSelect(trans.deal))
      {
         ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
         if(dealType == DEAL_TYPE_BUY || dealType == DEAL_TYPE_SELL)
         {
            // Check if this is our magic number
            if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == MagicNumber)
            {
               // This is a trade execution (market or pending fill)
               LogTradeExecution();
               
               // Remove from pending orders if it was a pending
               ulong orderTicket = HistoryDealGetInteger(trans.deal, DEAL_ORDER);
               RemovePendingOrder(orderTicket);
            }
         }
      }
   }
}

// Remove pending order from tracking when it becomes a position
void RemovePendingOrder(ulong orderTicket)
{
   for(int i = 0; i < totalPendingOrders; i++)
   {
      if(pendingOrders[i].ticket == orderTicket)
      {
         // Shift array
         for(int j = i; j < totalPendingOrders - 1; j++)
         {
            pendingOrders[j] = pendingOrders[j + 1];
         }
         totalPendingOrders--;
         pendingOrders[totalPendingOrders].ticket = 0;
         pendingOrders[totalPendingOrders].placedTime = 0;
         pendingOrders[totalPendingOrders].orderType = WRONG_VALUE;
         break;
      }
   }
}

//---------------- LOG TRADE EXECUTION TIME ----------------

void LogTradeExecution()
{
   datetime now = TimeCurrent();
   
   // Clean up old entries periodically
   if(executedTradeCount >= 180) // Clean when getting close to array limit
   {
      CleanupOldTradeTimes();
   }
   
   // Add new trade time
   if(executedTradeCount < 200)
   {
      executedTradeTimes[executedTradeCount] = now;
      executedTradeCount++;
   }
   else
   {
      // Array full, shift and add
      for(int i = 0; i < 199; i++)
         executedTradeTimes[i] = executedTradeTimes[i + 1];
      executedTradeTimes[199] = now;
   }
}

//---------------- ERROR DESCRIPTION ----------------

string ErrorDescription(int errorCode)
{
   switch(errorCode)
   {
      case 10004: return "Requote";
      case 10006: return "Request rejected";
      case 10007: return "Request canceled by trader";
      case 10008: return "Order placed";
      case 10009: return "Request partially accepted";
      case 10010: return "Request processing error";
      case 10011: return "Request canceled by timeout";
      case 10012: return "Invalid request";
      case 10013: return "Invalid volume";
      case 10014: return "Invalid price";
      case 10015: return "Invalid stops";
      case 10016: return "Trade is disabled";
      case 10017: return "Market is closed";
      case 10018: return "No money";
      case 10019: return "Price changed";
      case 10020: return "Off quotes";
      case 10021: return "Broker is busy";
      case 10022: return "Requote";
      case 10023: return "Order locked";
      case 10024: return "Long positions only allowed";
      case 10025: return "Too many requests";
      default: return "Unknown error";
   }
}

//+------------------------------------------------------------------+
