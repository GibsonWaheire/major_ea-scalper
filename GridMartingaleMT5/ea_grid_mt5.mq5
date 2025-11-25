//+------------------------------------------------------------------+
//|                                                  ea_grid_mt5.mq5 |
//|                        Grid + Martingale Basket EA for MetaTrader 5 |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Input parameters
input group "===== Grid + Martingale Settings ====="
input double   Lots = 0.01;              // Initial lot size
input double   Multiplier = 2.0;         // Martingale multiplier
input int      StepPoints = 500;         // Grid step in points
input double   TakeProfitMoney = 5.0;    // Basket TP in account currency
input int      Direction = 1;            // 1=BUY only, -1=SELL only, 0=both
input ulong    Magic = 777;              // Magic number

input group "===== Trading Settings ====="
input int      Slippage = 0;             // Slippage in points
input string   CommentPrefix = "GridMart"; // Trade comment prefix

//--- Global variables
CTrade trade;
int lastDirection = 1;  // Store last direction for Direction=0 (alternate mode)
datetime lastOrderTime = 0;  // Prevent rapid-fire orders

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Set magic number for CTrade
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);  // Try FOK first
   
   // Check if filling mode is supported
   if(!trade.SetTypeFilling(ORDER_FILLING_IOC))
   {
      if(!trade.SetTypeFilling(ORDER_FILLING_RETURN))
      {
         Print("Warning: Could not set filling mode");
      }
   }
   
   Print("Grid + Martingale EA initialized");
   Print("Symbol: ", Symbol());
   Print("Initial Lot: ", Lots);
   Print("Multiplier: ", Multiplier);
   Print("Step Points: ", StepPoints);
   Print("Take Profit: ", TakeProfitMoney, " ", AccountInfoString(ACCOUNT_CURRENCY));
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("Grid + Martingale EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Prevent rapid-fire orders within same second
   datetime currentTime = TimeCurrent();
   if(currentTime == lastOrderTime)
      return;
   
   // Count positions with this magic number
   int positionCount = CountPositions();
   
   // If no positions exist, open first trade
   if(positionCount == 0)
   {
      OpenFirstTrade();
      lastOrderTime = currentTime;
      return;
   }
   
   // Check if we need to add grid trades
   CheckAndAddGridTrades();
   
   // Check basket take profit
   double basketProfit = GetBasketProfit();
   if(basketProfit >= TakeProfitMoney)
   {
      Print("Basket Take Profit reached: ", DoubleToString(basketProfit, 2));
      CloseAll();
      lastOrderTime = currentTime;
      return;
   }
   
   // Update display
   UpdateDisplay(basketProfit, positionCount);
}

//+------------------------------------------------------------------+
//| Get total floating profit for all positions with this magic     |
//+------------------------------------------------------------------+
double GetBasketProfit()
{
   double totalProfit = 0.0;
   
   // Iterate through all positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            // Check if position belongs to this EA
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  totalProfit += PositionGetDouble(POSITION_PROFIT) + 
                                PositionGetDouble(POSITION_SWAP) + 
                                PositionGetDouble(POSITION_COMMISSION);
               }
            }
         }
      }
   }
   
   return totalProfit;
}

//+------------------------------------------------------------------+
//| Count positions with this magic number                           |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  count++;
               }
            }
         }
      }
   }
   
   return count;
}

//+------------------------------------------------------------------+
//| Get the price of the last opened position                        |
//+------------------------------------------------------------------+
double GetLastPositionPrice()
{
   double lastPrice = 0.0;
   datetime lastTime = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
                  if(openTime > lastTime)
                  {
                     lastTime = openTime;
                     lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                  }
               }
            }
         }
      }
   }
   
   return lastPrice;
}

//+------------------------------------------------------------------+
//| Get the lot size of the last opened position                     |
//+------------------------------------------------------------------+
double GetLastLotSize()
{
   double lastLot = Lots;
   datetime lastTime = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
                  if(openTime > lastTime)
                  {
                     lastTime = openTime;
                     lastLot = PositionGetDouble(POSITION_VOLUME);
                  }
               }
            }
         }
      }
   }
   
   return lastLot;
}

//+------------------------------------------------------------------+
//| Open BUY position                                                |
//+------------------------------------------------------------------+
void OpenBuy(double lot)
{
   double price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double sl = 0;
   double tp = 0;
   
   string comment = CommentPrefix + "_BUY";
   
   // Normalize lot size
   double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   
   if(trade.Buy(lot, Symbol(), price, sl, tp, comment))
   {
      Print("BUY order opened: Lot=", lot, " Price=", price);
      lastDirection = 1;
   }
   else
   {
      Print("BUY order failed: ", trade.ResultRetcodeDescription(), " (", trade.ResultRetcode(), ")");
   }
}

//+------------------------------------------------------------------+
//| Open SELL position                                              |
//+------------------------------------------------------------------+
void OpenSell(double lot)
{
   double price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double sl = 0;
   double tp = 0;
   
   string comment = CommentPrefix + "_SELL";
   
   // Normalize lot size
   double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   
   if(trade.Sell(lot, Symbol(), price, sl, tp, comment))
   {
      Print("SELL order opened: Lot=", lot, " Price=", price);
      lastDirection = -1;
   }
   else
   {
      Print("SELL order failed: ", trade.ResultRetcodeDescription(), " (", trade.ResultRetcode(), ")");
   }
}

//+------------------------------------------------------------------+
//| Close all positions with this magic number                       |
//+------------------------------------------------------------------+
void CloseAll()
{
   int closedCount = 0;
   
   // Close all positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  if(trade.PositionClose(ticket))
                  {
                     closedCount++;
                     Print("Position closed: Ticket=", ticket);
                  }
                  else
                  {
                     Print("Failed to close position: Ticket=", ticket, " Error: ", trade.ResultRetcodeDescription());
                  }
               }
            }
         }
      }
   }
   
   Print("Closed ", closedCount, " positions. Basket profit: ", DoubleToString(GetBasketProfit(), 2));
}

//+------------------------------------------------------------------+
//| Open first trade based on Direction input                        |
//+------------------------------------------------------------------+
void OpenFirstTrade()
{
   int tradeDirection = Direction;
   
   // If Direction = 0, use last direction or default to BUY
   if(Direction == 0)
   {
      tradeDirection = lastDirection;
      if(tradeDirection == 0)
         tradeDirection = 1;  // Default to BUY if never traded
   }
   
   if(tradeDirection == 1)
   {
      OpenBuy(Lots);
   }
   else if(tradeDirection == -1)
   {
      OpenSell(Lots);
   }
}

//+------------------------------------------------------------------+
//| Check if grid trades need to be added                            |
//+------------------------------------------------------------------+
void CheckAndAddGridTrades()
{
   // Get last position price and direction
   double lastPrice = GetLastPositionPrice();
   if(lastPrice == 0.0)
      return;
   
   // Determine position direction
   int positionDirection = GetPositionDirection();
   if(positionDirection == 0)
      return;
   
   // Get current price
   double currentPrice = 0.0;
   if(positionDirection == 1)  // BUY positions
   {
      currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   }
   else  // SELL positions
   {
      currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   }
   
   // Calculate price movement in points
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   
   double priceDiff = 0.0;
   if(positionDirection == 1)  // BUY - check if price went down
   {
      priceDiff = (lastPrice - currentPrice) / point;
   }
   else  // SELL - check if price went up
   {
      priceDiff = (currentPrice - lastPrice) / point;
   }
   
   // If price moved against position by StepPoints, open new trade
   if(priceDiff >= StepPoints)
   {
      double lastLot = GetLastLotSize();
      double newLot = lastLot * Multiplier;
      
      Print("Grid condition met: Price moved ", DoubleToString(priceDiff, 1), " points against position");
      Print("Opening new trade: Lot=", newLot, " (Last lot: ", lastLot, ")");
      
      if(positionDirection == 1)
      {
         OpenBuy(newLot);
      }
      else
      {
         OpenSell(newLot);
      }
   }
}

//+------------------------------------------------------------------+
//| Get the direction of existing positions (1=BUY, -1=SELL, 0=error) |
//+------------------------------------------------------------------+
int GetPositionDirection()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  long posType = PositionGetInteger(POSITION_TYPE);
                  if(posType == POSITION_TYPE_BUY)
                     return 1;
                  else if(posType == POSITION_TYPE_SELL)
                     return -1;
               }
            }
         }
      }
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Update display on chart                                          |
//+------------------------------------------------------------------+
void UpdateDisplay(double basketProfit, int positionCount)
{
   string info = "\n=== Grid + Martingale EA ===\n";
   info += "Magic: " + IntegerToString(Magic) + "\n";
   info += "Positions: " + IntegerToString(positionCount) + "\n";
   info += "Basket Profit: " + DoubleToString(basketProfit, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + "\n";
   info += "Target: " + DoubleToString(TakeProfitMoney, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + "\n";
   
   if(positionCount > 0)
   {
      double lastPrice = GetLastPositionPrice();
      double lastLot = GetLastLotSize();
      info += "Last Price: " + DoubleToString(lastPrice, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)) + "\n";
      info += "Last Lot: " + DoubleToString(lastLot, 2) + "\n";
      
      int posDir = GetPositionDirection();
      string dirStr = (posDir == 1) ? "BUY" : "SELL";
      info += "Direction: " + dirStr + "\n";
   }
   
   Comment(info);
}

//+------------------------------------------------------------------+

