//+------------------------------------------------------------------+
//|                                          SmartGridGBPUSD.mq5 |
//|                        Smart Grid EA with ATR Spacing & News Filter |
//|                        Prop-Firm Safe (No Martingale) |
//+------------------------------------------------------------------+
#property copyright "Smart Grid EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

// ===== Input Parameters =====
input group "===== Grid Settings ====="
input double   LotSize          = 0.01;      // Fixed lot size (No Martingale)
input double   ATR_Multiplier   = 1.5;       // ATR multiplier for dynamic spacing
input int      ATR_Period       = 14;        // ATR period
input ENUM_TIMEFRAMES ATR_Timeframe = PERIOD_H1; // Timeframe for ATR calculation
input int      MaxGridLevels    = 10;        // Maximum grid levels
input int      GridStartSide    = 0;         // 0=Both, 1=Buy only, 2=Sell only

input group "===== Risk Management ====="
input double   GlobalStopLoss   = 5.0;       // Max drawdown % (hard stop)
input double   TakeProfitPips   = 50;        // Take profit in pips (per position)
input double   StopLossPips     = 100;       // Stop loss in pips (per position)

input group "===== News Filter ====="
input bool     UseNewsFilter    = true;      // Enable news filter
input int      NewsBlockMinutes = 30;        // Block trading X minutes before news
input string   NewsTimes        = "08:30,12:30,13:30,14:00,15:30"; // High-impact news times (GMT)

input group "===== Basket Trailing ====="
input bool     UseBasketTrailing = true;     // Enable trailing take profit for basket
input double   TrailingStartPips = 20;       // Start trailing after X pips profit
input double   TrailingStepPips  = 10;       // Trailing step in pips

input group "===== Execution Settings ====="
input int      MagicNumber      = 999999;   // Magic number
input int      Slippage         = 30;       // Slippage in points

// ===== Global Variables =====
CTrade trade;
int atrHandle;
double lastBuyPrice = 0;
double lastSellPrice = 0;
int buyLevels = 0;
int sellLevels = 0;
double highestBasketProfit = 0;
bool eaDisabled = false;
datetime lastNewsCheck = 0;
string newsTimesArray[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Set trade parameters
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   // Initialize ATR indicator
   atrHandle = iATR(_Symbol, ATR_Timeframe, ATR_Period);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("Error creating ATR indicator: ", GetLastError());
      return(INIT_FAILED);
   }
   
   // Parse news times
   if(UseNewsFilter)
   {
      ParseNewsTimes();
   }
   
   // Verify symbol is GBPUSD
   if(_Symbol != "GBPUSD")
   {
      Print("WARNING: This EA is optimized for GBPUSD. Current symbol: ", _Symbol);
   }
   
   Print("SmartGridGBPUSD EA initialized successfully");
   Print("Lot Size: ", LotSize, " (Fixed - No Martingale)");
   Print("ATR Multiplier: ", ATR_Multiplier);
   Print("Max Grid Levels: ", MaxGridLevels);
   Print("Global Stop Loss: ", GlobalStopLoss, "%");
   Print("News Filter: ", (UseNewsFilter ? "Enabled" : "Disabled"));
   Print("Basket Trailing: ", (UseBasketTrailing ? "Enabled" : "Disabled"));
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   
   Print("SmartGridGBPUSD EA deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 0. Check for daily reset
   CheckDailyReset();
   
   // 1. Safety Check: Is EA disabled?
   if(eaDisabled)
   {
      return; // EA disabled for the day after drawdown stop
   }
   
   // 2. Safety Check: Is it News Time?
   if(UseNewsFilter && IsNewsTime())
   {
      return; // Skip if high impact news is near
   }
   
   // 3. Global Drawdown Protection
   double drawdownPercent = CheckDrawdown();
   if(drawdownPercent >= GlobalStopLoss)
   {
      Print("GLOBAL DRAWDOWN PROTECTION TRIGGERED: ", drawdownPercent, "% >= ", GlobalStopLoss, "%");
      CloseAllAndStop();
      return;
   }
   
   // 4. Update grid tracking
   UpdateGridTracking();
   
   // 5. Basket Trailing Take Profit
   if(UseBasketTrailing && PositionsTotal() > 0)
   {
      ManageBasketTrailing();
   }
   
   // 6. Grid Logic: Check if we should open next level
   if(GetTotalPositions() < MaxGridLevels)
   {
      double atr = GetATR();
      double dynamicGap = atr * ATR_Multiplier;
      
      if(ShouldOpenNextLevel(dynamicGap))
      {
         ExecuteGridTrade(dynamicGap);
      }
   }
}

//+------------------------------------------------------------------+
//| MODULE 1: ATR-Based Dynamic Spacing                             |
//+------------------------------------------------------------------+
double GetATR()
{
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   
   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) <= 0)
   {
      Print("Error copying ATR buffer: ", GetLastError());
      return 0;
   }
   
   return atrBuffer[0];
}

//+------------------------------------------------------------------+
//| MODULE 2: News Filter Logic                                      |
//+------------------------------------------------------------------+
bool IsNewsTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   int currentMinutes = dt.hour * 60 + dt.min;
   
   // Check each news time
   for(int i = 0; i < ArraySize(newsTimesArray); i++)
   {
      string timeStr = newsTimesArray[i];
      int colonPos = StringFind(timeStr, ":");
      if(colonPos < 0) continue;
      
      int newsHour = (int)StringToInteger(StringSubstr(timeStr, 0, colonPos));
      int newsMin = (int)StringToInteger(StringSubstr(timeStr, colonPos + 1));
      int newsMinutes = newsHour * 60 + newsMin;
      
      // Check if we're within the block window
      int minutesUntilNews = newsMinutes - currentMinutes;
      
      // Handle day rollover
      if(minutesUntilNews < 0)
         minutesUntilNews += 1440; // Add 24 hours
      
      if(minutesUntilNews <= NewsBlockMinutes)
      {
         // Check if we're past the news time (allow 1 hour after)
         int minutesAfterNews = currentMinutes - newsMinutes;
         if(minutesAfterNews < 0)
            minutesAfterNews += 1440;
         
         if(minutesAfterNews <= 60) // Block 1 hour after news
         {
            if(TimeCurrent() - lastNewsCheck > 300) // Log every 5 minutes
            {
               Print("NEWS FILTER: Blocking trades. News at ", timeStr, " GMT. Current: ", 
                     IntegerToString(dt.hour, 2, '0'), ":", IntegerToString(dt.min, 2, '0'), " GMT");
               lastNewsCheck = TimeCurrent();
            }
            return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Parse news times from input string                               |
//+------------------------------------------------------------------+
void ParseNewsTimes()
{
   string tempStr = NewsTimes;
   int count = 0;
   
   // Count commas to determine array size
   for(int i = 0; i < StringLen(tempStr); i++)
   {
      if(StringGetCharacter(tempStr, i) == ',')
         count++;
   }
   
   ArrayResize(newsTimesArray, count + 1);
   count = 0;
   
   // Split by comma
   int start = 0;
   for(int i = 0; i <= StringLen(tempStr); i++)
   {
      if(i == StringLen(tempStr) || StringGetCharacter(tempStr, i) == ',')
      {
         string timeStr = StringSubstr(tempStr, start, i - start);
         StringTrimLeft(timeStr);
         StringTrimRight(timeStr);
         if(StringLen(timeStr) > 0)
         {
            newsTimesArray[count] = timeStr;
            count++;
         }
         start = i + 1;
      }
   }
   
   ArrayResize(newsTimesArray, count);
   Print("Parsed ", count, " news times");
}

//+------------------------------------------------------------------+
//| MODULE 3: Global Drawdown Protection                            |
//+------------------------------------------------------------------+
double CheckDrawdown()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   if(balance <= 0)
      return 0;
   
   double drawdownPercent = ((balance - equity) / balance) * 100.0;
   return drawdownPercent;
}

//+------------------------------------------------------------------+
//| Close all positions and disable EA                               |
//+------------------------------------------------------------------+
void CloseAllAndStop()
{
   Print("Closing all positions and disabling EA...");
   CloseAllPositions();
   eaDisabled = true;
   
   // Reset for next day (check at midnight)
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   Print("EA disabled. Will reset at midnight GMT.");
}

//+------------------------------------------------------------------+
//| Check if EA should reset (new day)                               |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   static int lastDay = -1;
   static int lastMonth = -1;
   static int lastYear = -1;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // Check if it's a new day (handles month/year rollovers)
   bool isNewDay = false;
   if(lastDay != -1)
   {
      if(dt.year != lastYear || dt.mon != lastMonth || dt.day != lastDay)
      {
         isNewDay = true;
      }
   }
   
   if(isNewDay && eaDisabled)
   {
      Print("New day detected. Resetting EA...");
      eaDisabled = false;
      highestBasketProfit = 0;
   }
   
   lastDay = dt.day;
   lastMonth = dt.mon;
   lastYear = dt.year;
}

//+------------------------------------------------------------------+
//| Update grid level tracking                                       |
//+------------------------------------------------------------------+
void UpdateGridTracking()
{
   buyLevels = 0;
   sellLevels = 0;
   lastBuyPrice = 0;
   lastSellPrice = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            
            if(type == POSITION_TYPE_BUY)
            {
               buyLevels++;
               if(lastBuyPrice == 0 || openPrice < lastBuyPrice)
                  lastBuyPrice = openPrice;
            }
            else if(type == POSITION_TYPE_SELL)
            {
               sellLevels++;
               if(lastSellPrice == 0 || openPrice > lastSellPrice)
                  lastSellPrice = openPrice;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get total positions for this EA                                  |
//+------------------------------------------------------------------+
int GetTotalPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check if we should open next grid level                          |
//+------------------------------------------------------------------+
bool ShouldOpenNextLevel(double dynamicGap)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double gapInPrice = dynamicGap;
   
   // Convert gap to price difference
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      gapInPrice = dynamicGap / 10.0; // For 3/5 digit brokers
   
   // Check Buy side
   if(GridStartSide == 0 || GridStartSide == 1)
   {
      if(buyLevels == 0)
      {
         // No buy positions, can open first
         return true;
      }
      else if(lastBuyPrice > 0)
      {
         double distanceFromLastBuy = ask - lastBuyPrice;
         if(distanceFromLastBuy >= gapInPrice)
         {
            return true; // Price moved down enough for next buy
         }
      }
   }
   
   // Check Sell side
   if(GridStartSide == 0 || GridStartSide == 2)
   {
      if(sellLevels == 0)
      {
         // No sell positions, can open first
         return true;
      }
      else if(lastSellPrice > 0)
      {
         double distanceFromLastSell = lastSellPrice - bid;
         if(distanceFromLastSell >= gapInPrice)
         {
            return true; // Price moved up enough for next sell
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Execute grid trade                                               |
//+------------------------------------------------------------------+
void ExecuteGridTrade(double dynamicGap)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double gapInPrice = dynamicGap;
   
   // Convert gap to price difference
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      gapInPrice = dynamicGap / 10.0;
   
   double tp = 0, sl = 0;
   
   // Calculate TP/SL in price terms
   double tpPrice = TakeProfitPips * point;
   double slPrice = StopLossPips * point;
   if(digits == 3 || digits == 5)
   {
      tpPrice = TakeProfitPips * point * 10;
      slPrice = StopLossPips * point * 10;
   }
   
   // Determine which side to trade
   bool openBuy = false;
   bool openSell = false;
   
   if(GridStartSide == 0) // Both sides
   {
      if(buyLevels == 0 && sellLevels == 0)
      {
         // Start with both
         openBuy = true;
         openSell = true;
      }
      else if(buyLevels <= sellLevels && lastBuyPrice > 0)
      {
         double distanceFromLastBuy = ask - lastBuyPrice;
         if(distanceFromLastBuy >= gapInPrice)
            openBuy = true;
      }
      else if(sellLevels < buyLevels && lastSellPrice > 0)
      {
         double distanceFromLastSell = lastSellPrice - bid;
         if(distanceFromLastSell >= gapInPrice)
            openSell = true;
      }
   }
   else if(GridStartSide == 1) // Buy only
   {
      if(buyLevels == 0 || (lastBuyPrice > 0 && (ask - lastBuyPrice) >= gapInPrice))
         openBuy = true;
   }
   else if(GridStartSide == 2) // Sell only
   {
      if(sellLevels == 0 || (lastSellPrice > 0 && (lastSellPrice - bid) >= gapInPrice))
         openSell = true;
   }
   
   // Execute trades
   if(openBuy)
   {
      tp = ask + tpPrice;
      sl = ask - slPrice;
      
      if(trade.Buy(LotSize, _Symbol, ask, sl, tp, "Grid Buy"))
      {
         Print("Grid BUY opened: Lot=", LotSize, " Price=", ask, " TP=", tp, " SL=", sl, " Gap=", dynamicGap);
      }
      else
      {
         Print("Grid BUY failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      }
   }
   
   if(openSell)
   {
      tp = bid - tpPrice;
      sl = bid + slPrice;
      
      if(trade.Sell(LotSize, _Symbol, bid, sl, tp, "Grid Sell"))
      {
         Print("Grid SELL opened: Lot=", LotSize, " Price=", bid, " TP=", tp, " SL=", sl, " Gap=", dynamicGap);
      }
      else
      {
         Print("Grid SELL failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
//| MODULE 5: Basket Trailing Take Profit                           |
//+------------------------------------------------------------------+
void ManageBasketTrailing()
{
   double currentProfit = GetBasketProfit();
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Convert trailing values to price
   double trailingStart = TrailingStartPips * point;
   double trailingStep = TrailingStepPips * point;
   if(digits == 3 || digits == 5)
   {
      trailingStart = TrailingStartPips * point * 10;
      trailingStep = TrailingStepPips * point * 10;
   }
   
   // Update highest profit
   if(currentProfit > highestBasketProfit)
   {
      highestBasketProfit = currentProfit;
   }
   
   // Check if we should start trailing
   if(currentProfit >= trailingStart)
   {
      // Calculate trailing level
      double trailingLevel = highestBasketProfit - trailingStep;
      
      // If current profit drops below trailing level, close all
      if(currentProfit < trailingLevel && currentProfit > 0)
      {
         Print("BASKET TRAILING: Profit dropped to ", currentProfit, " from ", highestBasketProfit, ". Closing all positions.");
         CloseAllPositions();
         highestBasketProfit = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| Get total profit of all positions                                |
//+------------------------------------------------------------------+
double GetBasketProfit()
{
   double totalProfit = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            totalProfit += PositionGetDouble(POSITION_PROFIT);
         }
      }
   }
   
   return totalProfit;
}

//+------------------------------------------------------------------+
//| Close all positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   int maxAttempts = 10;
   int attempt = 0;
   
   while(GetTotalPositions() > 0 && attempt < maxAttempts)
   {
      int totalPositions = GetTotalPositions();
      
      if(attempt == 0)
         Print("Closing all ", totalPositions, " grid positions...");
      
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
               PositionGetString(POSITION_SYMBOL) == _Symbol)
            {
               if(trade.PositionClose(ticket))
               {
                  Print("Position closed: Ticket=", ticket);
               }
               else
               {
                  Print("Failed to close position: Ticket=", ticket, " Error=", 
                        trade.ResultRetcode());
               }
            }
         }
      }
      
      attempt++;
      if(GetTotalPositions() > 0)
         Sleep(50);
   }
   
   int remaining = GetTotalPositions();
   if(remaining == 0)
   {
      double finalProfit = GetBasketProfit();
      Print("All positions closed. Final basket profit: $", finalProfit);
      highestBasketProfit = 0;
   }
   else
   {
      Print("WARNING: ", remaining, " positions still open after ", maxAttempts, " attempts");
   }
}

//+------------------------------------------------------------------+

