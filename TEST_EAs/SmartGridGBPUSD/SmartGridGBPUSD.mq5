//+------------------------------------------------------------------+
//|                                          SmartGridGBPUSD.mq5 |
//|                        Smart Grid EA with ATR Spacing & News Filter |
//|                        Prop-Firm Safe (No Martingale) |
//+------------------------------------------------------------------+
#property copyright "Smart Grid EA"
#property link      ""
#property version   "2.00"
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

input group "===== Trend Detection ====="
input bool     UseTrendFilter   = true;     // Enable trend filter
input int      EMA_Fast         = 21;       // Fast EMA period
input int      EMA_Slow         = 50;       // Slow EMA period
input int      ADX_Period       = 14;       // ADX period
input double   ADX_Threshold    = 25.0;     // ADX threshold for trending (below = ranging)

input group "===== Market Condition ====="
input bool     UseMarketCondition = true;   // Enable market condition detection
input int      BB_Period        = 20;       // Bollinger Bands period
input double   BB_Deviation     = 2.0;      // Bollinger Bands deviation

input group "===== Support/Resistance ====="
input bool     UseSRFilter      = true;     // Enable S/R filter
input double   SR_DistancePips = 20.0;     // Distance from S/R to avoid (pips)

input group "===== Entry Filters ====="
input bool     UseRSIFilter     = true;     // Enable RSI filter
input int      RSI_Period       = 14;       // RSI period
input bool     UseSpreadFilter  = true;     // Enable spread filter
input double   MaxSpreadPips    = 3.0;      // Maximum spread in pips
input bool     UseSessionFilter = true;     // Enable session filter
input int      SessionStartHour = 8;        // Trading session start (GMT)
input int      SessionEndHour   = 17;       // Trading session end (GMT)

input group "===== Exit Management ====="
input bool     UsePartialTP     = true;     // Enable partial take profit
input double   PartialTP1_Pips  = 20.0;     // First partial TP (pips)
input double   PartialTP2_Pips  = 40.0;     // Second partial TP (pips)
input bool     UseBreakeven     = true;     // Enable breakeven protection
input double   BreakevenTriggerPips = 10.0; // Trigger breakeven at profit (pips)
input double   MaxBasketHours   = 24.0;     // Max hours basket open without profit

input group "===== Enhanced Grid Management ====="
input bool     UseAsymmetricGrid = true;    // More levels in trend direction
input bool     UseGridRebalancing = true;   // Close losing side when profitable side reaches target
input double   MaxDrawdownPerSide = 2.0;    // Max drawdown % per side before stopping new levels

// ===== Global Variables =====
CTrade trade;
int atrHandle;
int emaFastHandle;
int emaSlowHandle;
int adxHandle;
int bbHandle;
int rsiHandle;
double lastBuyPrice = 0;
double lastSellPrice = 0;
int buyLevels = 0;
int sellLevels = 0;
double highestBasketProfit = 0;
bool eaDisabled = false;
datetime lastNewsCheck = 0;
string newsTimesArray[];
datetime basketOpenTime = 0;

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
   
   // Initialize trend detection indicators
   if(UseTrendFilter)
   {
      emaFastHandle = iMA(_Symbol, ATR_Timeframe, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      emaSlowHandle = iMA(_Symbol, ATR_Timeframe, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
      adxHandle = iADX(_Symbol, ATR_Timeframe, ADX_Period);
      
      if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE || adxHandle == INVALID_HANDLE)
      {
         Print("Error creating trend indicators: ", GetLastError());
         return(INIT_FAILED);
      }
   }
   else
   {
      emaFastHandle = INVALID_HANDLE;
      emaSlowHandle = INVALID_HANDLE;
      adxHandle = INVALID_HANDLE;
   }
   
   // Initialize market condition indicators
   if(UseMarketCondition)
   {
      bbHandle = iBands(_Symbol, ATR_Timeframe, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
      if(bbHandle == INVALID_HANDLE)
      {
         Print("Error creating Bollinger Bands: ", GetLastError());
         return(INIT_FAILED);
      }
   }
   else
   {
      bbHandle = INVALID_HANDLE;
   }
   
   // Initialize entry filter indicators
   if(UseRSIFilter)
   {
      rsiHandle = iRSI(_Symbol, ATR_Timeframe, RSI_Period, PRICE_CLOSE);
      if(rsiHandle == INVALID_HANDLE)
      {
         Print("Error creating RSI indicator: ", GetLastError());
         return(INIT_FAILED);
      }
   }
   else
   {
      rsiHandle = INVALID_HANDLE;
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
   
   Print("SmartGridGBPUSD EA v2.00 initialized successfully");
   Print("Lot Size: ", LotSize, " (Fixed - No Martingale)");
   Print("ATR Multiplier: ", ATR_Multiplier);
   Print("Max Grid Levels: ", MaxGridLevels);
   Print("Global Stop Loss: ", GlobalStopLoss, "%");
   Print("News Filter: ", (UseNewsFilter ? "Enabled" : "Disabled"));
   Print("Basket Trailing: ", (UseBasketTrailing ? "Enabled" : "Disabled"));
   Print("Trend Filter: ", (UseTrendFilter ? "Enabled" : "Disabled"));
   Print("Market Condition: ", (UseMarketCondition ? "Enabled" : "Disabled"));
   Print("S/R Filter: ", (UseSRFilter ? "Enabled" : "Disabled"));
   Print("Entry Filters: RSI=", (UseRSIFilter ? "On" : "Off"), 
         " Spread=", (UseSpreadFilter ? "On" : "Off"), 
         " Session=", (UseSessionFilter ? "On" : "Off"));
   Print("Exit Management: PartialTP=", (UsePartialTP ? "On" : "Off"), 
         " Breakeven=", (UseBreakeven ? "On" : "Off"));
   Print("Grid Management: Asymmetric=", (UseAsymmetricGrid ? "On" : "Off"), 
         " Rebalancing=", (UseGridRebalancing ? "On" : "Off"), 
         " MaxDrawdownPerSide=", MaxDrawdownPerSide, "%");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   if(emaFastHandle != INVALID_HANDLE)
      IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE)
      IndicatorRelease(emaSlowHandle);
   if(adxHandle != INVALID_HANDLE)
      IndicatorRelease(adxHandle);
   if(bbHandle != INVALID_HANDLE)
      IndicatorRelease(bbHandle);
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
   
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
   
   // 5. Track basket open time
   if(GetTotalPositions() > 0 && basketOpenTime == 0)
   {
      basketOpenTime = TimeCurrent();
   }
   else if(GetTotalPositions() == 0)
   {
      basketOpenTime = 0;
   }
   
   // 6. Time-based exit check
   if(basketOpenTime > 0 && MaxBasketHours > 0)
   {
      double hoursOpen = (TimeCurrent() - basketOpenTime) / 3600.0;
      double basketProfit = GetBasketProfit();
      
      if(hoursOpen >= MaxBasketHours && basketProfit <= 0)
      {
         Print("TIME-BASED EXIT: Basket open for ", hoursOpen, " hours without profit. Closing all positions.");
         CloseAllPositions();
         basketOpenTime = 0;
         return;
      }
   }
   
   // 7. Partial Take Profit Management
   if(UsePartialTP && GetTotalPositions() > 0)
   {
      ManagePartialTP();
   }
   
   // 8. Breakeven Protection
   if(UseBreakeven && GetTotalPositions() > 0)
   {
      MoveToBreakeven();
   }
   
   // 9. Enhanced Basket Trailing Take Profit
   if(UseBasketTrailing && PositionsTotal() > 0)
   {
      ManageBasketTrailing();
   }
   
   // 10. Grid Rebalancing: Close losing side when profitable side reaches target
   if(UseGridRebalancing && GetTotalPositions() > 0)
   {
      CheckGridRebalancing();
   }
   
   // 11. Grid Logic: Check if we should open next level
   if(GetTotalPositions() < MaxGridLevels)
   {
      double atr = GetATR();
      int trendDir = GetTrendDirection();
      int marketCond = GetMarketCondition();
      
      // Check per-side drawdown protection
      if(!CanOpenNewLevel(trendDir))
      {
         return; // One side exceeded max drawdown
      }
      
      // Adjust ATR multiplier based on market condition
      double adjustedMultiplier = ATR_Multiplier;
      if(marketCond == 3) // Volatile
      {
         adjustedMultiplier *= 1.5; // Wider spacing in volatile markets
      }
      else if(trendDir != 0) // Trending
      {
         double adxMain[];
         ArraySetAsSeries(adxMain, true);
         if(adxHandle != INVALID_HANDLE && CopyBuffer(adxHandle, 0, 0, 1, adxMain) > 0)
         {
            if(adxMain[0] > 40) // Strong trend
            {
               adjustedMultiplier *= 1.3; // Wider spacing in strong trends
            }
         }
      }
      
      double dynamicGap = atr * adjustedMultiplier;
      
      if(ShouldOpenNextLevel(dynamicGap, trendDir, marketCond))
      {
         ExecuteGridTrade(dynamicGap, trendDir, marketCond);
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
bool ShouldOpenNextLevel(double dynamicGap, int trendDir, int marketCond)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double gapInPrice = dynamicGap;
   
   // Convert gap to price difference
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      gapInPrice = dynamicGap / 10.0; // For 3/5 digit brokers
   
   // Trend-based filtering
   bool allowBuy = true;
   bool allowSell = true;
   
   // If trending, only allow trades in trend direction
   if(UseTrendFilter && trendDir != 0)
   {
      if(trendDir == 1) // Bullish trend
      {
         allowSell = false; // Don't sell against uptrend
      }
      else if(trendDir == -1) // Bearish trend
      {
         allowBuy = false; // Don't buy against downtrend
      }
   }
   
   // Check Buy side
   if((GridStartSide == 0 || GridStartSide == 1) && allowBuy)
   {
      if(buyLevels == 0)
      {
         // Check entry filters before opening first position
         if(CheckEntryFilters(1) && !IsNearSupportResistance(ask, 1))
         {
            return true;
         }
      }
      else if(lastBuyPrice > 0)
      {
         double distanceFromLastBuy = ask - lastBuyPrice;
         if(distanceFromLastBuy >= gapInPrice)
         {
            // Check entry filters and S/R
            if(CheckEntryFilters(1) && !IsNearSupportResistance(ask, 1))
            {
               return true; // Price moved down enough for next buy
            }
         }
      }
   }
   
   // Check Sell side
   if((GridStartSide == 0 || GridStartSide == 2) && allowSell)
   {
      if(sellLevels == 0)
      {
         // Check entry filters before opening first position
         if(CheckEntryFilters(-1) && !IsNearSupportResistance(bid, -1))
         {
            return true;
         }
      }
      else if(lastSellPrice > 0)
      {
         double distanceFromLastSell = lastSellPrice - bid;
         if(distanceFromLastSell >= gapInPrice)
         {
            // Check entry filters and S/R
            if(CheckEntryFilters(-1) && !IsNearSupportResistance(bid, -1))
            {
               return true; // Price moved up enough for next sell
            }
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Execute grid trade                                               |
//+------------------------------------------------------------------+
void ExecuteGridTrade(double dynamicGap, int trendDir, int marketCond)
{
   // Check asymmetric grid limits
   int maxBuyLevels = MaxGridLevels;
   int maxSellLevels = MaxGridLevels;
   
   if(UseAsymmetricGrid && trendDir != 0)
   {
      if(trendDir == 1) // Bullish - more buy levels
      {
         maxBuyLevels = (int)(MaxGridLevels * 1.5);
      }
      else if(trendDir == -1) // Bearish - more sell levels
      {
         maxSellLevels = (int)(MaxGridLevels * 1.5);
      }
   }
   
   // Check if we've reached max levels for a side
   if(buyLevels >= maxBuyLevels && sellLevels >= maxSellLevels)
      return;
   
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
   
   // Determine which side to trade based on trend
   bool openBuy = false;
   bool openSell = false;
   
   // Trend-based direction logic
   if(UseTrendFilter && trendDir != 0)
   {
      // In trending market, only trade with trend
      if(trendDir == 1 && (GridStartSide == 0 || GridStartSide == 1)) // Bullish - only buy
      {
         if(buyLevels == 0 || (lastBuyPrice > 0 && (ask - lastBuyPrice) >= gapInPrice))
         {
            if(CheckEntryFilters(1) && !IsNearSupportResistance(ask, 1))
               openBuy = true;
         }
      }
      else if(trendDir == -1 && (GridStartSide == 0 || GridStartSide == 2)) // Bearish - only sell
      {
         if(sellLevels == 0 || (lastSellPrice > 0 && (lastSellPrice - bid) >= gapInPrice))
         {
            if(CheckEntryFilters(-1) && !IsNearSupportResistance(bid, -1))
               openSell = true;
         }
      }
   }
   else
   {
      // Ranging market or trend filter disabled - allow both sides
      if(GridStartSide == 0) // Both sides
      {
         if(buyLevels == 0 && sellLevels == 0)
         {
            // Start with both if filters pass
            if(CheckEntryFilters(1) && !IsNearSupportResistance(ask, 1))
               openBuy = true;
            if(CheckEntryFilters(-1) && !IsNearSupportResistance(bid, -1))
               openSell = true;
         }
         else if(buyLevels <= sellLevels && lastBuyPrice > 0)
         {
            double distanceFromLastBuy = ask - lastBuyPrice;
            if(distanceFromLastBuy >= gapInPrice)
            {
               if(CheckEntryFilters(1) && !IsNearSupportResistance(ask, 1))
                  openBuy = true;
            }
         }
         else if(sellLevels < buyLevels && lastSellPrice > 0)
         {
            double distanceFromLastSell = lastSellPrice - bid;
            if(distanceFromLastSell >= gapInPrice)
            {
               if(CheckEntryFilters(-1) && !IsNearSupportResistance(bid, -1))
                  openSell = true;
            }
         }
      }
      else if(GridStartSide == 1) // Buy only
      {
         if(buyLevels == 0 || (lastBuyPrice > 0 && (ask - lastBuyPrice) >= gapInPrice))
         {
            if(CheckEntryFilters(1) && !IsNearSupportResistance(ask, 1))
               openBuy = true;
         }
      }
      else if(GridStartSide == 2) // Sell only
      {
         if(sellLevels == 0 || (lastSellPrice > 0 && (lastSellPrice - bid) >= gapInPrice))
         {
            if(CheckEntryFilters(-1) && !IsNearSupportResistance(bid, -1))
               openSell = true;
         }
      }
   }
   
   // Execute trades (respect asymmetric grid limits)
   if(openBuy && buyLevels < maxBuyLevels)
   {
      tp = ask + tpPrice;
      sl = ask - slPrice;
      
      if(trade.Buy(LotSize, _Symbol, ask, sl, tp, "Grid Buy"))
      {
         Print("Grid BUY opened: Lot=", LotSize, " Price=", ask, " TP=", tp, " SL=", sl, " Gap=", dynamicGap, " (", buyLevels+1, "/", maxBuyLevels, " levels)");
      }
      else
      {
         Print("Grid BUY failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      }
   }
   
   if(openSell && sellLevels < maxSellLevels)
   {
      tp = bid - tpPrice;
      sl = bid + slPrice;
      
      if(trade.Sell(LotSize, _Symbol, bid, sl, tp, "Grid Sell"))
      {
         Print("Grid SELL opened: Lot=", LotSize, " Price=", bid, " TP=", tp, " SL=", sl, " Gap=", dynamicGap, " (", sellLevels+1, "/", maxSellLevels, " levels)");
      }
      else
      {
         Print("Grid SELL failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
//| MODULE 5: Enhanced Basket Trailing Take Profit                  |
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
   
   // Profit lock-in: Close 30% at +30 pips, 50% at +50 pips
   static bool locked30 = false;
   static bool locked50 = false;
   
   // Calculate profit in pips (simplified)
   double profitPipsValue = 30.0 * point;
   double profit50PipsValue = 50.0 * point;
   if(digits == 3 || digits == 5)
   {
      profitPipsValue = 30.0 * point * 10;
      profit50PipsValue = 50.0 * point * 10;
   }
   
   // Approximate profit in pips (using account currency)
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double profitPercent = (currentProfit / balance) * 100.0;
   
   // Rough estimate: 30 pips ≈ 0.3% profit for GBPUSD with 0.01 lot
   if(!locked30 && profitPercent >= 0.3 && currentProfit > 0)
   {
      // Close 30% of positions
      ClosePercentageOfPositions(30);
      locked30 = true;
      Print("PROFIT LOCK-IN: Closed 30% of basket at profit threshold");
   }
   
   if(!locked50 && profitPercent >= 0.5 && currentProfit > 0)
   {
      // Close 50% of remaining positions
      ClosePercentageOfPositions(50);
      locked50 = true;
      Print("PROFIT LOCK-IN: Closed 50% of basket at profit threshold");
   }
   
   // Reset locks if basket is closed
   if(GetTotalPositions() == 0)
   {
      locked30 = false;
      locked50 = false;
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
         locked30 = false;
         locked50 = false;
      }
   }
}

//+------------------------------------------------------------------+
//| Close percentage of positions                                    |
//+------------------------------------------------------------------+
void ClosePercentageOfPositions(int percentage)
{
   ulong tickets[];
   double lots[];
   int count = 0;
   
   // Collect all positions
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            ArrayResize(tickets, count + 1);
            ArrayResize(lots, count + 1);
            tickets[count] = ticket;
            lots[count] = PositionGetDouble(POSITION_VOLUME);
            count++;
         }
      }
   }
   
   // Calculate total lots
   double totalLots = 0;
   for(int i = 0; i < count; i++)
      totalLots += lots[i];
   
   double closeLots = totalLots * percentage / 100.0;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   
   // Close positions starting with most profitable
   // Sort by profit (descending)
   for(int i = 0; i < count - 1; i++)
   {
      for(int j = i + 1; j < count; j++)
      {
         if(PositionSelectByTicket(tickets[i]) && PositionSelectByTicket(tickets[j]))
         {
            double profitI = PositionGetDouble(POSITION_PROFIT);
            double profitJ = PositionGetDouble(POSITION_PROFIT);
            
            if(profitJ > profitI)
            {
               ulong tempTicket = tickets[i];
               double tempLot = lots[i];
               tickets[i] = tickets[j];
               lots[i] = lots[j];
               tickets[j] = tempTicket;
               lots[j] = tempLot;
            }
         }
      }
   }
   
   // Close positions until we've closed enough lots
   double closedLots = 0;
   double targetLots = closeLots;
   for(int i = 0; i < count && closedLots < targetLots; i++)
   {
      if(PositionSelectByTicket(tickets[i]))
      {
         double lotToClose = MathMin(lots[i], targetLots - closedLots);
         if(lotToClose >= minLot)
         {
            if(trade.PositionClosePartial(tickets[i], lotToClose))
            {
               closedLots += lotToClose;
            }
         }
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
//| Get Trend Direction: 1=Bullish, -1=Bearish, 0=Neutral           |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
   if(!UseTrendFilter || emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE || adxHandle == INVALID_HANDLE)
      return 0;
   
   double emaFast[], emaSlow[], adxMain[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(adxMain, true);
   
   if(CopyBuffer(emaFastHandle, 0, 0, 2, emaFast) <= 0 ||
      CopyBuffer(emaSlowHandle, 0, 0, 2, emaSlow) <= 0 ||
      CopyBuffer(adxHandle, 0, 0, 1, adxMain) <= 0)
   {
      return 0;
   }
   
   double adxValue = adxMain[0];
   
   // If ADX < threshold, market is ranging (neutral)
   if(adxValue < ADX_Threshold)
      return 0;
   
   // Determine trend direction
   if(emaFast[0] > emaSlow[0])
      return 1; // Bullish
   else if(emaFast[0] < emaSlow[0])
      return -1; // Bearish
   
   return 0; // Neutral
}

//+------------------------------------------------------------------+
//| Get Market Condition: 0=Ranging, 1=Trending_Up, 2=Trending_Down, 3=Volatile |
//+------------------------------------------------------------------+
int GetMarketCondition()
{
   if(!UseMarketCondition || bbHandle == INVALID_HANDLE)
      return 0;
   
   double bbUpper[], bbLower[], bbMiddle[], close[];
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(bbMiddle, true);
   ArraySetAsSeries(close, true);
   
   if(CopyBuffer(bbHandle, 1, 0, 1, bbUpper) <= 0 ||
      CopyBuffer(bbHandle, 2, 0, 1, bbLower) <= 0 ||
      CopyBuffer(bbHandle, 0, 0, 1, bbMiddle) <= 0 ||
      CopyClose(_Symbol, ATR_Timeframe, 0, 1, close) <= 0)
   {
      return 0;
   }
   
   double bbWidth = bbUpper[0] - bbLower[0];
   double atr = GetATR();
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      point *= 10;
   
   // Volatile if BB width > 3 * ATR
   if(bbWidth > 3.0 * atr)
      return 3; // Volatile
   
   // Check price position relative to BB
   if(close[0] > bbUpper[0])
      return 1; // Trending Up (overbought)
   else if(close[0] < bbLower[0])
      return 2; // Trending Down (oversold)
   
   return 0; // Ranging
}

//+------------------------------------------------------------------+
//| Check if price is near Support/Resistance                      |
//+------------------------------------------------------------------+
bool IsNearSupportResistance(double price, int direction)
{
   if(!UseSRFilter)
      return false;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      point *= 10;
   
   double srDistance = SR_DistancePips * point;
   
   // Calculate pivot points (daily)
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime dayStart = StringToTime(IntegerToString(dt.year) + "." + 
                                    IntegerToString(dt.mon, 2, '0') + "." + 
                                    IntegerToString(dt.day, 2, '0') + " 00:00");
   
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   if(CopyHigh(_Symbol, PERIOD_D1, 0, 1, high) <= 0 ||
      CopyLow(_Symbol, PERIOD_D1, 0, 1, low) <= 0 ||
      CopyClose(_Symbol, PERIOD_D1, 1, 1, close) <= 0)
   {
      return false;
   }
   
   double pivot = (high[0] + low[0] + close[0]) / 3.0;
   double resistance = 2.0 * pivot - low[0];
   double support = 2.0 * pivot - high[0];
   
   // Check swing highs/lows (last 50 bars)
   double swingHigh = 0, swingLow = DBL_MAX;
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   
   if(CopyHigh(_Symbol, ATR_Timeframe, 0, 50, highs) > 0 &&
      CopyLow(_Symbol, ATR_Timeframe, 0, 50, lows) > 0)
   {
      for(int i = 1; i < 49; i++)
      {
         if(highs[i] > highs[i-1] && highs[i] > highs[i+1])
         {
            if(highs[i] > swingHigh)
               swingHigh = highs[i];
         }
         if(lows[i] < lows[i-1] && lows[i] < lows[i+1])
         {
            if(lows[i] < swingLow)
               swingLow = lows[i];
         }
      }
   }
   
   // Check if price is near S/R
   if(direction == 1) // Buy - check support
   {
      if(MathAbs(price - support) < srDistance || 
         (swingLow != DBL_MAX && MathAbs(price - swingLow) < srDistance))
         return true;
   }
   else if(direction == -1) // Sell - check resistance
   {
      if(MathAbs(price - resistance) < srDistance || 
         (swingHigh > 0 && MathAbs(price - swingHigh) < srDistance))
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check Entry Filters                                             |
//+------------------------------------------------------------------+
bool CheckEntryFilters(int direction)
{
   // Spread filter
   if(UseSpreadFilter)
   {
      double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      if(digits == 3 || digits == 5)
      {
         spread /= 10.0;
         point *= 10;
      }
      double maxSpread = MaxSpreadPips * point;
      
      if(spread > maxSpread)
      {
         return false; // Spread too wide
      }
   }
   
   // Session filter
   if(UseSessionFilter)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int currentHour = dt.hour;
      
      if(currentHour < SessionStartHour || currentHour >= SessionEndHour)
      {
         return false; // Outside trading session
      }
   }
   
   // RSI filter
   if(UseRSIFilter && rsiHandle != INVALID_HANDLE)
   {
      double rsi[];
      ArraySetAsSeries(rsi, true);
      
      if(CopyBuffer(rsiHandle, 0, 0, 1, rsi) > 0)
      {
         if(direction == 1 && rsi[0] >= 60) // Buy but RSI overbought
            return false;
         if(direction == -1 && rsi[0] <= 40) // Sell but RSI oversold
            return false;
      }
   }
   
   return true; // All filters passed
}

//+------------------------------------------------------------------+
//| Manage Partial Take Profit                                       |
//+------------------------------------------------------------------+
void ManagePartialTP()
{
   if(!UsePartialTP)
      return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      point *= 10;
   
   double tp1 = PartialTP1_Pips * point;
   double tp2 = PartialTP2_Pips * point;
   
   // Get all positions
   ulong tickets[];
   int count = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            ArrayResize(tickets, count + 1);
            tickets[count] = ticket;
            count++;
         }
      }
   }
   
   // Check each position for partial TP
   for(int i = 0; i < count; i++)
   {
      if(PositionSelectByTicket(tickets[i]))
      {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 
                              SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                              SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = PositionGetDouble(POSITION_PROFIT);
         double lotSize = PositionGetDouble(POSITION_VOLUME);
         string comment = PositionGetString(POSITION_COMMENT);
         
         // Check if already partially closed
         bool partialClosed = (StringFind(comment, "TP1") >= 0 || StringFind(comment, "TP2") >= 0);
         
         if(!partialClosed)
         {
            double profitPips = MathAbs(currentPrice - openPrice);
            
            // First partial TP
            if(profitPips >= PartialTP1_Pips && profit > 0)
            {
               double closeLot = NormalizeDouble(lotSize * 0.25, 2);
               if(closeLot >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
               {
                  if(trade.PositionClosePartial(tickets[i], closeLot))
                  {
                     Print("Partial TP1: Closed 25% of position ", tickets[i], " at +", PartialTP1_Pips, " pips");
                  }
               }
            }
         }
         else if(StringFind(comment, "TP1") >= 0 && StringFind(comment, "TP2") < 0)
         {
            // Already hit TP1, check for TP2
            double profitPips = MathAbs(currentPrice - openPrice);
            
            if(profitPips >= PartialTP2_Pips && profit > 0)
            {
               double closeLot = NormalizeDouble(lotSize * 0.5, 2);
               if(closeLot >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
               {
                  if(trade.PositionClosePartial(tickets[i], closeLot))
                  {
                     Print("Partial TP2: Closed 50% of position ", tickets[i], " at +", PartialTP2_Pips, " pips");
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if can open new level (per-side drawdown protection)       |
//+------------------------------------------------------------------+
bool CanOpenNewLevel(int trendDir)
{
   if(MaxDrawdownPerSide <= 0)
      return true;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0)
      return true;
   
   // Calculate drawdown per side
   double buyProfit = 0, sellProfit = 0;
   double buyLots = 0, sellLots = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double profit = PositionGetDouble(POSITION_PROFIT);
            double lots = PositionGetDouble(POSITION_VOLUME);
            
            if(type == POSITION_TYPE_BUY)
            {
               buyProfit += profit;
               buyLots += lots;
            }
            else if(type == POSITION_TYPE_SELL)
            {
               sellProfit += profit;
               sellLots += lots;
            }
         }
      }
   }
   
   // Calculate drawdown percentage per side
   double buyDrawdownPercent = 0;
   double sellDrawdownPercent = 0;
   
   if(buyLots > 0 && buyProfit < 0)
   {
      // Estimate drawdown based on lot size and profit
      buyDrawdownPercent = MathAbs(buyProfit / balance) * 100.0;
   }
   
   if(sellLots > 0 && sellProfit < 0)
   {
      sellDrawdownPercent = MathAbs(sellProfit / balance) * 100.0;
   }
   
   // Check if we can open new level based on trend direction
   if(trendDir == 1) // Bullish - check buy side
   {
      if(buyDrawdownPercent >= MaxDrawdownPerSide)
      {
         Print("BUY side drawdown protection: ", buyDrawdownPercent, "% >= ", MaxDrawdownPerSide, "%");
         return false;
      }
   }
   else if(trendDir == -1) // Bearish - check sell side
   {
      if(sellDrawdownPercent >= MaxDrawdownPerSide)
      {
         Print("SELL side drawdown protection: ", sellDrawdownPercent, "% >= ", MaxDrawdownPerSide, "%");
         return false;
      }
   }
   else // Neutral/ranging - check both sides
   {
      if(buyDrawdownPercent >= MaxDrawdownPerSide || sellDrawdownPercent >= MaxDrawdownPerSide)
      {
         Print("Per-side drawdown protection triggered. Buy: ", buyDrawdownPercent, "%, Sell: ", sellDrawdownPercent, "%");
         return false;
      }
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Grid Rebalancing: Close losing side when profitable side reaches target |
//+------------------------------------------------------------------+
void CheckGridRebalancing()
{
   double buyProfit = 0, sellProfit = 0;
   int buyCount = 0, sellCount = 0;
   ulong buyTickets[], sellTickets[];
   
   // Collect positions
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double profit = PositionGetDouble(POSITION_PROFIT);
            
            if(type == POSITION_TYPE_BUY)
            {
               buyProfit += profit;
               ArrayResize(buyTickets, buyCount + 1);
               buyTickets[buyCount] = ticket;
               buyCount++;
            }
            else if(type == POSITION_TYPE_SELL)
            {
               sellProfit += profit;
               ArrayResize(sellTickets, sellCount + 1);
               sellTickets[sellCount] = ticket;
               sellCount++;
            }
         }
      }
   }
   
   // Check if one side is profitable and other is losing
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      point *= 10;
   
   double targetProfit = 50.0 * point * LotSize * 100000; // Approximate 50 pips profit
   
   // If buy side is profitable and sell side is losing significantly
   if(buyProfit >= targetProfit && sellProfit < -targetProfit * 0.5)
   {
      Print("GRID REBALANCING: Buy side profitable (", buyProfit, "), closing losing sell side (", sellProfit, ")");
      // Close all sell positions
      for(int i = 0; i < sellCount; i++)
      {
         if(PositionSelectByTicket(sellTickets[i]))
         {
            trade.PositionClose(sellTickets[i]);
         }
      }
   }
   // If sell side is profitable and buy side is losing significantly
   else if(sellProfit >= targetProfit && buyProfit < -targetProfit * 0.5)
   {
      Print("GRID REBALANCING: Sell side profitable (", sellProfit, "), closing losing buy side (", buyProfit, ")");
      // Close all buy positions
      for(int i = 0; i < buyCount; i++)
      {
         if(PositionSelectByTicket(buyTickets[i]))
         {
            trade.PositionClose(buyTickets[i]);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Move positions to breakeven                                    |
//+------------------------------------------------------------------+
void MoveToBreakeven()
{
   if(!UseBreakeven)
      return;
   
   double basketProfit = GetBasketProfit();
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      point *= 10;
   
   double triggerProfit = BreakevenTriggerPips * point;
   
   // Check if basket profit exceeds trigger
   if(basketProfit < triggerProfit)
      return;
   
   // Move all stops to breakeven
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentSL = PositionGetDouble(POSITION_SL);
            double currentTP = PositionGetDouble(POSITION_TP);
            
            // Only move if SL is not already at or better than breakeven
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            {
               if(currentSL < openPrice)
               {
                  if(trade.PositionModify(ticket, openPrice, currentTP))
                  {
                     Print("Moved BUY position ", ticket, " to breakeven");
                  }
               }
            }
            else // SELL
            {
               if(currentSL > openPrice || currentSL == 0)
               {
                  if(trade.PositionModify(ticket, openPrice, currentTP))
                  {
                     Print("Moved SELL position ", ticket, " to breakeven");
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+

