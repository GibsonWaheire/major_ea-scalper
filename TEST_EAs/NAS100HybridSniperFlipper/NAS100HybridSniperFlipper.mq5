//+------------------------------------------------------------------+
//|                                    NAS100HybridSniperFlipper.mq5 |
//|                        NAS100 Microsecond Scalper - Instant Execution |
//+------------------------------------------------------------------+
#property copyright "NAS100 Microsecond Scalper"
#property link      ""
#property version   "2.00"
#property strict
#property indicator_chart_window

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/AccountInfo.mqh>

//--- Input Parameters ---
input string   TradeSymbol          = "";            // Trading Symbol (empty = auto-detect NAS100)
input int      MagicNumber          = 20241201;      // Magic Number
input double   LotSize              = 0.50;          // Lot Size
input int      VirtualSLPoints      = 200;           // Virtual Stop Loss (NAS100 points)
input double   TPPoints             = 100;           // Take Profit (NAS100 points) - instant exit
input double   DailyProfitPercent   = 0.40;          // Daily Profit Cap (0.30, 0.40, or 0.50)
input bool     EnableNotifications  = true;          // Enable Push Notifications
input bool     ShowVisualIndicators = true;          // Show visual indicators on chart

// Microsecond Scalper Settings
input int      TickMovementThreshold = 1;            // Minimum tick movement to trigger (points) - AGGRESSIVE
input int      MaxSpreadPoints       = 300;          // Maximum spread to trade (points) - NAS100 compatible
input bool     UseTickBasedEntry     = true;         // Use tick-based instant entry
input int      MaxConcurrentTrades   = 10;           // Maximum concurrent trades (increased for scalping)
input double   MinTickMovement       = 0.5;          // Minimum tick movement for signal (points) - AGGRESSIVE
input bool     DisableTradingHours   = true;         // Disable trading hours restriction (trade 24/7)

//--- Global Variables ---
CTrade         trade;
CPositionInfo  position;
CAccountInfo   account;
string         detectedSymbol = "";  // Auto-detected NAS100 symbol

//+------------------------------------------------------------------+
//| Get trading symbol (auto-detected or from input)                |
//+------------------------------------------------------------------+
string GetTradeSymbol()
{
   if(StringLen(detectedSymbol) > 0)
      return detectedSymbol;
   if(StringLen(TradeSymbol) > 0)
      return TradeSymbol;
   return _Symbol;  // Fallback to chart symbol
}

// Tick-based scalping variables
double         lastBid = 0.0;
double         lastAsk = 0.0;
double         lastPrice = 0.0;
datetime       lastTickTime = 0;
int            tickDirection = 0;  // 1 = up, -1 = down, 0 = neutral
double         tickMovement = 0.0;
int            consecutiveTicks = 0;

// Indicator handles (only used when not in tick-based mode)
int            ema20Handle = INVALID_HANDLE;
int            ema50Handle = INVALID_HANDLE;
int            rsiHandle = INVALID_HANDLE;

// Time Management
datetime       startOfDayEquity = 0;
double         startOfDayBalance = 0.0;
datetime       lastDayReset = 0;
bool           tradingStoppedForDay = false;
bool           tradingStoppedForLoss = false;

// Sniper Setup Tracking
bool           sniperSetupActive = false;
int            sniperDirection = 0;  // 1 = BUY, -1 = SELL, 0 = none
double         sniperEntryPrice = 0.0;
datetime       sniperEntryTime = 0;
bool           recoveryEntryUsed = false;
double         sniperVirtualSL = 0.0;
double         sniperTargetProfit = 0.0;
double         sniperEntryEquity = 0.0;  // Equity at entry time for TP calculation

// Structure tracking for BOS and zones
double         lastM5High = 0.0;
double         lastM5Low = 0.0;
double         lastM5Close = 0.0;
datetime       lastM5BarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // Auto-detect NAS100 symbol if not specified
   string symbolToUse = TradeSymbol;
   if(StringLen(symbolToUse) == 0)
   {
      // Try common NAS100 symbols
      string nas100Symbols[] = {"USTEC", "US100", "NAS100", "NAS100.cash", "US100.cash", "USTEC.cash"};
      for(int i = 0; i < ArraySize(nas100Symbols); i++)
      {
         if(SymbolSelect(nas100Symbols[i], true))
         {
            MqlTick testTick;
            if(SymbolInfoTick(nas100Symbols[i], testTick))
            {
               symbolToUse = nas100Symbols[i];
               detectedSymbol = nas100Symbols[i];
               Print("Auto-detected NAS100 symbol: ", symbolToUse);
               break;
            }
         }
      }
      
      if(StringLen(symbolToUse) == 0)
      {
         // Try current chart symbol
         symbolToUse = _Symbol;
         detectedSymbol = _Symbol;
         Print("Using chart symbol: ", symbolToUse);
      }
   }
   else
   {
      detectedSymbol = symbolToUse;
   }
   
   // Set magic number
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Verify symbol exists and is selectable
   if(!SymbolSelect(symbolToUse, true))
   {
      Print("ERROR: Failed to select symbol: ", symbolToUse);
      Print("Please specify a valid NAS100 symbol in input parameters");
      return INIT_FAILED;
   }
   
   // Initialize tick tracking
   MqlTick tick;
   if(SymbolInfoTick(symbolToUse, tick))
   {
      lastBid = tick.bid;
      lastAsk = tick.ask;
      lastPrice = (tick.bid + tick.ask) / 2.0;
      lastTickTime = tick.time;
      Print("Initial tick - Bid: ", lastBid, " Ask: ", lastAsk);
   }
   else
   {
      Print("WARNING: Could not get initial tick data for ", symbolToUse);
   }
   
   // Initialize indicators only if not in tick-based mode
   if(!UseTickBasedEntry)
   {
      ema20Handle = iMA(symbolToUse, PERIOD_M5, 20, 0, MODE_EMA, PRICE_CLOSE);
      ema50Handle = iMA(symbolToUse, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE);
      rsiHandle = iRSI(symbolToUse, PERIOD_M5, 14, PRICE_CLOSE);
      
      if(ema20Handle == INVALID_HANDLE || ema50Handle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
      {
         Print("Warning: Failed to create indicator handles for non-tick mode");
      }
   }
   
   // Initialize daily tracking
   ResetDailyTracking();
   
   Print("========================================");
   Print("NAS100 Microsecond Scalper initialized");
   Print("Trading Symbol: ", symbolToUse);
   Print("Lot Size: ", LotSize);
   Print("Virtual SL Points: ", VirtualSLPoints);
   Print("TP Points: ", TPPoints);
   Print("Daily Profit Cap: ", DailyProfitPercent * 100, "%");
   Print("Tick-Based Entry: ", (UseTickBasedEntry ? "ENABLED" : "DISABLED"));
   Print("Trading Hours: ", (DisableTradingHours ? "DISABLED (24/7)" : "ENABLED (15:30-18:00 Kenya)"));
   Print("Max Spread: ", MaxSpreadPoints, " points");
   Print("Tick Threshold: ", TickMovementThreshold, " points");
   Print("Min Tick Movement: ", MinTickMovement, " points");
   Print("Max Concurrent Trades: ", MaxConcurrentTrades);
   Print("========================================");
   
   // Log current time status
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   int kenyaHour = dt.hour + 3;
   if(kenyaHour >= 24) kenyaHour -= 24;
   Print("Current Server Time: ", dt.hour, ":", dt.min, " UTC");
   Print("Current Kenya Time: ", kenyaHour, ":", dt.min, " (UTC+3)");
   Print("Within Trading Hours: ", IsWithinTradingHours());
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Clean up chart objects
   CleanupChartObjects();
   
   // Release indicator handles
   if(ema20Handle != INVALID_HANDLE) IndicatorRelease(ema20Handle);
   if(ema50Handle != INVALID_HANDLE) IndicatorRelease(ema50Handle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   
   Print("EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check daily reset
   CheckDailyReset();
   
   // Check if trading is stopped
   if(tradingStoppedForDay || tradingStoppedForLoss)
   {
      static datetime lastLogTime = 0;
      if(TimeCurrent() - lastLogTime > 300) // Log every 5 minutes
      {
         Print("Trading stopped - tradingStoppedForDay: ", tradingStoppedForDay, " | tradingStoppedForLoss: ", tradingStoppedForLoss);
         lastLogTime = TimeCurrent();
      }
      // Still monitor for end of session to close positions
      if(IsEndOfSession())
      {
         CloseAllPositions();
      }
      return;
   }
   
   // Check trading time window (only if not disabled)
   if(!DisableTradingHours && !IsWithinTradingHours())
   {
      static datetime lastLogTime = 0;
      if(TimeCurrent() - lastLogTime > 300) // Log every 5 minutes
      {
         Print("Outside trading hours - checking for end of session");
         lastLogTime = TimeCurrent();
      }
      if(IsEndOfSession())
      {
         CloseAllPositions();
         tradingStoppedForDay = true;
         if(EnableNotifications)
            SendEANotification("Trading session ended. All positions closed.");
      }
      return;
   }
   
   // Check daily loss protection
   if(CheckDailyLossProtection())
   {
      CloseAllPositions();
      tradingStoppedForLoss = true;
      if(EnableNotifications)
         SendEANotification("Daily loss limit reached (-15%). Trading stopped for the day.");
      return;
   }
   
   // Check daily profit cap
   if(CheckDailyProfitCap())
   {
      CloseAllPositions();
      tradingStoppedForDay = true;
      if(EnableNotifications)
         SendEANotification("Daily profit cap reached. Trading stopped for the day.");
      return;
   }
   
   // Check virtual stop loss if sniper setup is active
   if(sniperSetupActive)
   {
      if(CheckVirtualStopLoss())
      {
         CloseAllPositions();
         tradingStoppedForDay = true;
         sniperSetupActive = false;
         if(EnableNotifications)
            SendEANotification("Virtual stop loss hit. All positions closed. Trading stopped for the day.");
         return;
      }
      
      // Instant profit exit for microsecond scalper
      if(UseTickBasedEntry)
      {
         CheckInstantProfitExit();
      }
      else
      {
         // Check per-trade TP (5% of account equity)
         if(CheckPerTradeTP())
         {
            CloseAllPositions();
            sniperSetupActive = false;
            recoveryEntryUsed = false;
            sniperDirection = 0;
            sniperEntryEquity = 0.0;
            if(EnableNotifications)
               SendEANotification("Per-trade TP (5%) reached. All positions closed. Scanning for next setup.");
            // Continue scanning for next setup
         }
      }
   }
   
   // Microsecond scalper: instant tick-based entry
   // ALWAYS process tick movement first on every tick for instant evaluation
   if(UseTickBasedEntry)
   {
      // Process tick movement FIRST on every tick
      ProcessTickMovement();
      
      // Check for instant entry signal IMMEDIATELY after processing tick
      // Allow multiple concurrent trades up to MaxConcurrentTrades
      if(GetActivePositionCount() < MaxConcurrentTrades)
      {
         int signal = GetInstantScalpingSignal();
         if(signal != 0)
         {
            OpenInstantTrade(signal);
         }
      }
   }
   else
   {
      // Original logic (disabled for microsecond scalping)
      if(!sniperSetupActive)
      {
         LookForSniperEntry();
      }
      else
      {
         CheckRecoveryEntry();
      }
   }
   
   // Update structure tracking
   UpdateStructureTracking();
   
   // Update visual indicators
   if(ShowVisualIndicators)
   {
      UpdateVisualIndicators();
   }
}

//+------------------------------------------------------------------+
//| Update structure tracking for BOS detection                     |
//+------------------------------------------------------------------+
void UpdateStructureTracking()
{
   datetime currentBarTime = iTime(TradeSymbol, PERIOD_M5, 0);
   
   if(currentBarTime != lastM5BarTime)
   {
      lastM5BarTime = currentBarTime;
      lastM5High = iHigh(TradeSymbol, PERIOD_M5, 0);
      lastM5Low = iLow(TradeSymbol, PERIOD_M5, 0);
      lastM5Close = iClose(TradeSymbol, PERIOD_M5, 0);
   }
}

//+------------------------------------------------------------------+
//| Check if within trading hours (15:30 - 18:00 Kenya Time)        |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
   // Get broker server time (typically UTC)
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   
   // Convert to Kenya Time (UTC+3)
   int kenyaHour = dt.hour + 3;
   if(kenyaHour >= 24) kenyaHour -= 24;
   
   int totalMinutes = kenyaHour * 60 + dt.min;
   
   int startMinutes = 15 * 60 + 30;  // 15:30
   int endMinutes = 18 * 60;         // 18:00
   
   bool withinHours = (totalMinutes >= startMinutes && totalMinutes < endMinutes);
   
   // Debug logging
   static datetime lastLogTime = 0;
   if(TimeCurrent() - lastLogTime > 300) // Log every 5 minutes
   {
      Print("Time Check - Server Hour: ", dt.hour, ":", dt.min, " | Kenya Hour: ", kenyaHour, ":", dt.min, " | Within Hours: ", withinHours);
      lastLogTime = TimeCurrent();
   }
   
   return withinHours;
}

//+------------------------------------------------------------------+
//| Check if end of session (18:00 Kenya Time)                      |
//+------------------------------------------------------------------+
bool IsEndOfSession()
{
   // Get broker server time (typically UTC)
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   
   // Convert to Kenya Time (UTC+3)
   int kenyaHour = dt.hour + 3;
   if(kenyaHour >= 24) kenyaHour -= 24;
   
   int totalMinutes = kenyaHour * 60 + dt.min;
   
   return (totalMinutes >= 18 * 60);
}

//+------------------------------------------------------------------+
//| Reset daily tracking variables                                   |
//+------------------------------------------------------------------+
void ResetDailyTracking()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   // Check if new day
   MqlDateTime lastDt;
   TimeToStruct(lastDayReset, lastDt);
   if(lastDayReset == 0 || dt.day != lastDt.day)
   {
      startOfDayBalance = account.Equity();
      startOfDayEquity = currentTime;
      lastDayReset = currentTime;
      tradingStoppedForDay = false;
      tradingStoppedForLoss = false;
      sniperSetupActive = false;
      recoveryEntryUsed = false;
      sniperDirection = 0;
      
      Print("Daily reset: Start of day equity = ", startOfDayBalance);
   }
}

//+------------------------------------------------------------------+
//| Check and perform daily reset if needed                         |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   MqlDateTime lastDt;
   TimeToStruct(lastDayReset, lastDt);
   if(lastDayReset == 0 || dt.day != lastDt.day)
   {
      ResetDailyTracking();
   }
}

//+------------------------------------------------------------------+
//| Check daily loss protection (-15%)                              |
//+------------------------------------------------------------------+
bool CheckDailyLossProtection()
{
   double currentEquity = account.Equity();
   double lossThreshold = startOfDayBalance * 0.85;  // -15%
   
   return (currentEquity < lossThreshold);
}

//+------------------------------------------------------------------+
//| Check daily profit cap (30-50%)                                 |
//+------------------------------------------------------------------+
bool CheckDailyProfitCap()
{
   double currentEquity = account.Equity();
   double profitTarget = startOfDayBalance * (1.0 + DailyProfitPercent);
   
   return (currentEquity >= profitTarget);
}

//+------------------------------------------------------------------+
//| Check virtual stop loss                                         |
//+------------------------------------------------------------------+
bool CheckVirtualStopLoss()
{
   if(sniperVirtualSL == 0.0) return false;
   
   double currentPrice = (sniperDirection == 1) ? SymbolInfoDouble(TradeSymbol, SYMBOL_BID) : SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   
   if(sniperDirection == 1)  // BUY
   {
      return (currentPrice <= sniperVirtualSL);
   }
   else if(sniperDirection == -1)  // SELL
   {
      return (currentPrice >= sniperVirtualSL);
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check per-trade TP (5% of account equity at entry)            |
//+------------------------------------------------------------------+
bool CheckPerTradeTP()
{
   if(sniperEntryEquity <= 0) return false;
   
   double target = sniperEntryEquity * 0.05;  // 5% of equity at entry
   
   double totalProfit = GetTotalFloatingProfit();
   
   return (totalProfit >= target && totalProfit > 0);
}

//+------------------------------------------------------------------+
//| Get total floating profit from all positions                    |
//+------------------------------------------------------------------+
double GetTotalFloatingProfit()
{
   double totalProfit = 0.0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i)) continue;
      if(position.Magic() != MagicNumber) continue;
      if(position.Symbol() != GetTradeSymbol()) continue;
      
      totalProfit += position.Profit() + position.Swap() + position.Commission();
   }
   
   return totalProfit;
}

//+------------------------------------------------------------------+
//| Close all positions                                             |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i)) continue;
      if(position.Magic() != MagicNumber) continue;
      if(position.Symbol() != GetTradeSymbol()) continue;
      
      ulong ticket = position.Ticket();
      trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| Look for sniper entry opportunity                               |
//+------------------------------------------------------------------+
void LookForSniperEntry()
{
   // Check trend filter
   int trendDirection = GetTrendDirection();
   if(trendDirection == 0)
   {
      static datetime lastLogTime = 0;
      if(TimeCurrent() - lastLogTime > 60) // Log every minute
      {
         Print("Entry Check: Trend filter returned 0 (no clear trend or filters disagree)");
         lastLogTime = TimeCurrent();
      }
      return;  // No clear trend or filters disagree
   }
   
   // Check for pullback into institutional zone
   bool inZone = CheckInstitutionalZone(trendDirection);
   if(!inZone)
   {
      static datetime lastLogTime = 0;
      if(TimeCurrent() - lastLogTime > 60)
      {
         Print("Entry Check: Price not in institutional zone. Trend: ", (trendDirection == 1 ? "BUY" : "SELL"));
         lastLogTime = TimeCurrent();
      }
      return;
   }
   
   // Check momentum confirmation
   bool momentumConfirmed = CheckMomentumConfirmation(trendDirection);
   if(!momentumConfirmed)
   {
      static datetime lastLogTime = 0;
      if(TimeCurrent() - lastLogTime > 60)
      {
         Print("Entry Check: Momentum not confirmed. Trend: ", (trendDirection == 1 ? "BUY" : "SELL"));
         lastLogTime = TimeCurrent();
      }
      return;
   }
   
   // All conditions met - open sniper entry
   Print("=== ALL CONDITIONS MET - Opening Sniper Entry ===");
   Print("Trend Direction: ", (trendDirection == 1 ? "BUY" : "SELL"));
   OpenSniperEntry(trendDirection, LotSize);
}

//+------------------------------------------------------------------+
//| Get trend direction based on EMA, BOS, and momentum             |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
   // If in tick-based mode or handles are invalid, return neutral
   if(UseTickBasedEntry || ema20Handle == INVALID_HANDLE || ema50Handle == INVALID_HANDLE)
      return 0;
   
   // Get EMA values
   double ema20[], ema50[];
   ArraySetAsSeries(ema20, true);
   ArraySetAsSeries(ema50, true);
   
   if(CopyBuffer(ema20Handle, 0, 0, 2, ema20) < 2)
   {
      Print("GetTrendDirection: Failed to copy EMA20 buffer");
      return 0;
   }
   if(CopyBuffer(ema50Handle, 0, 0, 2, ema50) < 2)
   {
      Print("GetTrendDirection: Failed to copy EMA50 buffer");
      return 0;
   }
   
   bool emaBullish = (ema20[0] > ema50[0]);
   bool emaBearish = (ema20[0] < ema50[0]);
   
   // Check M5 BOS
   int bosDirection = GetM5BOSDirection();
   
   // Check momentum direction
   int momentumDirection = GetMomentumDirection();
   
   // Debug logging
   static datetime lastLogTime = 0;
   if(TimeCurrent() - lastLogTime > 300) // Log every 5 minutes
   {
      Print("Trend Filter - EMA20: ", ema20[0], " EMA50: ", ema50[0], " | EMA Bullish: ", emaBullish, " Bearish: ", emaBearish);
      Print("Trend Filter - BOS Direction: ", bosDirection, " | Momentum Direction: ", momentumDirection);
      lastLogTime = TimeCurrent();
   }
   
   // BUY only if all agree
   if(emaBullish && bosDirection == 1 && momentumDirection == 1)
      return 1;
   
   // SELL only if all agree
   if(emaBearish && bosDirection == -1 && momentumDirection == -1)
      return -1;
   
   // Filters disagree - no trade
   return 0;
}

//+------------------------------------------------------------------+
//| Get M5 BOS (Break of Structure) direction                      |
//+------------------------------------------------------------------+
int GetM5BOSDirection()
{
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int bars = 20;  // Look back for structure
   if(CopyHigh(TradeSymbol, PERIOD_M5, 0, bars, high) < bars) return 0;
   if(CopyLow(TradeSymbol, PERIOD_M5, 0, bars, low) < bars) return 0;
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, bars, close) < bars) return 0;
   
   // Bullish BOS: price breaks above previous high
   // Bearish BOS: price breaks below previous low
   
   double currentHigh = high[0];
   double currentLow = low[0];
   double currentClose = close[0];
   
   // Find recent swing high and low
   double swingHigh = 0.0;
   double swingLow = DBL_MAX;
   int swingHighBar = 0;
   int swingLowBar = 0;
   
   for(int i = 5; i < bars - 1; i++)
   {
      // Check for swing high (higher than neighbors)
      if(high[i] > high[i-1] && high[i] > high[i+1] && high[i] > swingHigh)
      {
         swingHigh = high[i];
         swingHighBar = i;
      }
      
      // Check for swing low (lower than neighbors)
      if(low[i] < low[i-1] && low[i] < low[i+1] && low[i] < swingLow)
      {
         swingLow = low[i];
         swingLowBar = i;
      }
   }
   
   // More lenient BOS detection: check overall structure trend
   // Bullish BOS: higher highs and higher lows pattern, or break above swing high
   bool bullishStructure = false;
   if(swingHigh > 0 && swingLow < DBL_MAX)
   {
      // Check if we have higher highs (current high > previous swing high)
      if(currentHigh > swingHigh)
         bullishStructure = true;
      // Or check if swing high came after swing low (uptrend structure)
      else if(swingHighBar < swingLowBar && currentClose > (swingHigh + swingLow) / 2.0)
         bullishStructure = true;
   }
   
   // Bearish BOS: lower highs and lower lows pattern, or break below swing low
   bool bearishStructure = false;
   if(swingHigh > 0 && swingLow < DBL_MAX)
   {
      // Check if we have lower lows (current low < previous swing low)
      if(currentLow < swingLow)
         bearishStructure = true;
      // Or check if swing low came after swing high (downtrend structure)
      else if(swingLowBar < swingHighBar && currentClose < (swingHigh + swingLow) / 2.0)
         bearishStructure = true;
   }
   
   // Debug logging
   static datetime lastLogTime = 0;
   if(TimeCurrent() - lastLogTime > 300) // Log every 5 minutes
   {
      Print("BOS Check - SwingHigh: ", swingHigh, " at bar ", swingHighBar, " | SwingLow: ", swingLow, " at bar ", swingLowBar);
      Print("BOS Check - Current Close: ", currentClose, " | Bullish: ", bullishStructure, " | Bearish: ", bearishStructure);
      lastLogTime = TimeCurrent();
   }
   
   if(bullishStructure) return 1;
   if(bearishStructure) return -1;
   
   return 0;
}

//+------------------------------------------------------------------+
//| Get momentum direction                                          |
//+------------------------------------------------------------------+
int GetMomentumDirection()
{
   double close[];
   ArraySetAsSeries(close, true);
   
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, 5, close) < 5)
   {
      Print("GetMomentumDirection: Failed to copy close prices");
      return 0;
   }
   
   // More robust momentum: check multiple timeframes
   // Primary: compare current vs 3 bars ago
   double momentum = close[0] - close[3];
   
   // Secondary: check if price is making higher highs or lower lows
   bool higherHighs = (close[0] > close[1] && close[1] > close[2]);
   bool lowerLows = (close[0] < close[1] && close[1] < close[2]);
   
   // If momentum is strong or we have clear pattern, return direction
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double minMomentum = 10.0 * point;  // Minimum 10 points movement
   
   if(momentum > minMomentum || higherHighs) return 1;   // Upward momentum
   if(momentum < -minMomentum || lowerLows) return -1;  // Downward momentum
   
   // If momentum is weak but trend is clear, still return direction
   if(momentum > 0) return 1;
   if(momentum < 0) return -1;
   
   return 0;
}

//+------------------------------------------------------------------+
//| Check if price is in institutional zone                         |
//+------------------------------------------------------------------+
bool CheckInstitutionalZone(int direction)
{
   double currentPrice = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   
   // Check for M5 Order Block
   if(CheckM5OrderBlock(currentPrice, direction)) return true;
   
   // Check for M1/M5 FVG
   if(CheckFVG(currentPrice, direction)) return true;
   
   // Check for 50% retrace of last impulse
   if(Check50PercentRetrace(currentPrice, direction)) return true;
   
   // Check for previous structure retest
   if(CheckStructureRetest(currentPrice, direction)) return true;
   
   // Check for imbalance fill
   if(CheckImbalanceFill(currentPrice, direction)) return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Check M5 Order Block                                            |
//+------------------------------------------------------------------+
bool CheckM5OrderBlock(double price, int direction)
{
   double open[], high[], low[], close[];
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int bars = 10;
   if(CopyOpen(TradeSymbol, PERIOD_M5, 0, bars, open) < bars) return false;
   if(CopyHigh(TradeSymbol, PERIOD_M5, 0, bars, high) < bars) return false;
   if(CopyLow(TradeSymbol, PERIOD_M5, 0, bars, low) < bars) return false;
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, bars, close) < bars) return false;
   
   // Look for order block: strong candle followed by opposite candles
   for(int i = 3; i < bars - 1; i++)
   {
      double bodySize = MathAbs(close[i] - open[i]);
      double range = high[i] - low[i];
      if(range == 0) continue;
      
      double bodyPercent = (bodySize / range) * 100.0;
      
      // Strong bullish candle (order block for buys)
      if(direction == 1 && close[i] > open[i] && bodyPercent > 60.0)
      {
         // Check if price is retesting the low of that candle
         if(price >= low[i] && price <= high[i])
            return true;
      }
      
      // Strong bearish candle (order block for sells)
      if(direction == -1 && close[i] < open[i] && bodyPercent > 60.0)
      {
         // Check if price is retesting the high of that candle
         if(price >= low[i] && price <= high[i])
            return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check FVG (Fair Value Gap)                                      |
//+------------------------------------------------------------------+
bool CheckFVG(double price, int direction)
{
   // Check M5 FVG
   if(CheckFVGOnTimeframe(PERIOD_M5, price, direction)) return true;
   
   // Check M1 FVG
   if(CheckFVGOnTimeframe(PERIOD_M1, price, direction)) return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Check FVG on specific timeframe                                 |
//+------------------------------------------------------------------+
bool CheckFVGOnTimeframe(ENUM_TIMEFRAMES tf, double price, int direction)
{
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   int bars = 5;
   if(CopyHigh(TradeSymbol, tf, 0, bars, high) < bars) return false;
   if(CopyLow(TradeSymbol, tf, 0, bars, low) < bars) return false;
   
   // Bullish FVG: gap between candle 2 low and candle 0 high
   if(direction == 1 && bars >= 3)
   {
      double fvgTop = high[0];
      double fvgBottom = low[2];
      if(fvgBottom < fvgTop && price >= fvgBottom && price <= fvgTop)
         return true;
   }
   
   // Bearish FVG: gap between candle 2 high and candle 0 low
   if(direction == -1 && bars >= 3)
   {
      double fvgTop = high[2];
      double fvgBottom = low[0];
      if(fvgBottom < fvgTop && price >= fvgBottom && price <= fvgTop)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check 50% retrace of last impulse                               |
//+------------------------------------------------------------------+
bool Check50PercentRetrace(double price, int direction)
{
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int bars = 20;
   if(CopyHigh(TradeSymbol, PERIOD_M5, 0, bars, high) < bars) return false;
   if(CopyLow(TradeSymbol, PERIOD_M5, 0, bars, low) < bars) return false;
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, bars, close) < bars) return false;
   
   // Find last impulse move
   double impulseStart = 0.0;
   double impulseEnd = 0.0;
   
   if(direction == 1)
   {
      // Find last significant upward move
      for(int i = 1; i < bars - 1; i++)
      {
         if(close[i] > close[i+1] && close[i] > close[i-1])
         {
            impulseEnd = high[i];
            // Find start of impulse
            for(int j = i + 1; j < bars; j++)
            {
               if(low[j] < low[j-1])
               {
                  impulseStart = low[j];
                  break;
               }
            }
            break;
         }
      }
      
      if(impulseStart > 0 && impulseEnd > impulseStart)
      {
         double retraceLevel = impulseStart + (impulseEnd - impulseStart) * 0.5;
         double tolerance = (impulseEnd - impulseStart) * 0.1;  // 10% tolerance
         if(MathAbs(price - retraceLevel) <= tolerance)
            return true;
      }
   }
   else if(direction == -1)
   {
      // Find last significant downward move
      for(int i = 1; i < bars - 1; i++)
      {
         if(close[i] < close[i+1] && close[i] < close[i-1])
         {
            impulseEnd = low[i];
            // Find start of impulse
            for(int j = i + 1; j < bars; j++)
            {
               if(high[j] > high[j-1])
               {
                  impulseStart = high[j];
                  break;
               }
            }
            break;
         }
      }
      
      if(impulseStart > 0 && impulseEnd < impulseStart)
      {
         double retraceLevel = impulseStart - (impulseStart - impulseEnd) * 0.5;
         double tolerance = (impulseStart - impulseEnd) * 0.1;  // 10% tolerance
         if(MathAbs(price - retraceLevel) <= tolerance)
            return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check previous structure retest                                 |
//+------------------------------------------------------------------+
bool CheckStructureRetest(double price, int direction)
{
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int bars = 15;
   if(CopyHigh(TradeSymbol, PERIOD_M5, 0, bars, high) < bars) return false;
   if(CopyLow(TradeSymbol, PERIOD_M5, 0, bars, low) < bars) return false;
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, bars, close) < bars) return false;
   
   // Find previous structure levels
   double supportLevel = 0.0;
   double resistanceLevel = 0.0;
   
   for(int i = 3; i < bars - 1; i++)
   {
      // Support (swing low)
      if(low[i] < low[i-1] && low[i] < low[i+1])
      {
         if(supportLevel == 0 || low[i] < supportLevel)
            supportLevel = low[i];
      }
      
      // Resistance (swing high)
      if(high[i] > high[i-1] && high[i] > high[i+1])
      {
         if(resistanceLevel == 0 || high[i] > resistanceLevel)
            resistanceLevel = high[i];
      }
   }
   
   // Check retest
   if(direction == 1 && supportLevel > 0)
   {
      double tolerance = (resistanceLevel > supportLevel) ? (resistanceLevel - supportLevel) * 0.05 : 10.0;
      if(MathAbs(price - supportLevel) <= tolerance)
         return true;
   }
   
   if(direction == -1 && resistanceLevel > 0)
   {
      double tolerance = (resistanceLevel > supportLevel) ? (resistanceLevel - supportLevel) * 0.05 : 10.0;
      if(MathAbs(price - resistanceLevel) <= tolerance)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check imbalance fill                                            |
//+------------------------------------------------------------------+
bool CheckImbalanceFill(double price, int direction)
{
   // Similar to FVG but looking for price filling the gap
   return CheckFVG(price, direction);
}

//+------------------------------------------------------------------+
//| Check momentum confirmation                                     |
//+------------------------------------------------------------------+
bool CheckMomentumConfirmation(int direction)
{
   // Strong engulfing candle
   if(CheckEngulfingCandle(direction)) return true;
   
   // Minor structure break in trend direction
   if(CheckStructureBreak(direction)) return true;
   
   // Tick momentum spike
   if(CheckTickMomentumSpike(direction)) return true;
   
   // RSI confirmation
   if(CheckRSIConfirmation(direction)) return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Check engulfing candle                                          |
//+------------------------------------------------------------------+
bool CheckEngulfingCandle(int direction)
{
   double open[], high[], low[], close[];
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   if(CopyOpen(TradeSymbol, PERIOD_M5, 0, 2, open) < 2) return false;
   if(CopyHigh(TradeSymbol, PERIOD_M5, 0, 2, high) < 2) return false;
   if(CopyLow(TradeSymbol, PERIOD_M5, 0, 2, low) < 2) return false;
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, 2, close) < 2) return false;
   
   // Bullish engulfing
   if(direction == 1)
   {
      bool prevBearish = (close[1] < open[1]);
      bool currBullish = (close[0] > open[0]);
      bool engulfs = (open[0] < close[1] && close[0] > open[1]);
      
      if(prevBearish && currBullish && engulfs)
         return true;
   }
   
   // Bearish engulfing
   if(direction == -1)
   {
      bool prevBullish = (close[1] > open[1]);
      bool currBearish = (close[0] < open[0]);
      bool engulfs = (open[0] > close[1] && close[0] < open[1]);
      
      if(prevBullish && currBearish && engulfs)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check structure break                                           |
//+------------------------------------------------------------------+
bool CheckStructureBreak(int direction)
{
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int bars = 10;
   if(CopyHigh(TradeSymbol, PERIOD_M5, 0, bars, high) < bars) return false;
   if(CopyLow(TradeSymbol, PERIOD_M5, 0, bars, low) < bars) return false;
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, bars, close) < bars) return false;
   
   if(direction == 1)
   {
      // Break above recent high
      for(int i = 1; i < 5; i++)
      {
         if(close[0] > high[i])
            return true;
      }
   }
   else if(direction == -1)
   {
      // Break below recent low
      for(int i = 1; i < 5; i++)
      {
         if(close[0] < low[i])
            return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check tick momentum spike                                       |
//+------------------------------------------------------------------+
bool CheckTickMomentumSpike(int direction)
{
   // Simplified: check if current price movement is strong
   double close[];
   ArraySetAsSeries(close, true);
   
   if(CopyClose(TradeSymbol, PERIOD_M1, 0, 3, close) < 3) return false;
   
   double momentum = close[0] - close[2];
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double minSpike = 50.0 * point;  // Minimum 50 points movement
   
   if(direction == 1 && momentum > minSpike) return true;
   if(direction == -1 && momentum < -minSpike) return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Check RSI confirmation                                          |
//+------------------------------------------------------------------+
bool CheckRSIConfirmation(int direction)
{
   // If in tick-based mode or handle is invalid, return false
   if(UseTickBasedEntry || rsiHandle == INVALID_HANDLE)
      return false;
   
   double rsi[];
   ArraySetAsSeries(rsi, true);
   
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsi) < 1) return false;
   
   if(direction == 1 && rsi[0] > 50) return true;
   if(direction == -1 && rsi[0] < 50) return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Open sniper entry                                               |
//+------------------------------------------------------------------+
void OpenSniperEntry(int direction, double lots)
{
   double price = (direction == 1) ? SymbolInfoDouble(TradeSymbol, SYMBOL_ASK) : SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   
   // Normalize lot size
   double minLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP);
   lots = MathMax(minLot, MathMin(maxLot, lots));
   if(lotStep > 0)
      lots = MathFloor(lots / lotStep) * lotStep;
   lots = NormalizeDouble(lots, 2);
   
   bool result = false;
   if(direction == 1)
   {
      result = trade.Buy(lots, TradeSymbol, 0, 0, 0, "Sniper BUY");
   }
   else
   {
      result = trade.Sell(lots, TradeSymbol, 0, 0, 0, "Sniper SELL");
   }
   
   if(result)
   {
      sniperSetupActive = true;
      sniperDirection = direction;
      sniperEntryPrice = price;
      sniperEntryTime = TimeCurrent();
      sniperEntryEquity = account.Equity();
      
      // Set virtual stop loss
      if(direction == 1)
         sniperVirtualSL = price - (VirtualSLPoints * point);
      else
         sniperVirtualSL = price + (VirtualSLPoints * point);
      
      // Calculate target profit (5% of equity at entry)
      sniperTargetProfit = sniperEntryEquity * 0.05;
      
      if(EnableNotifications)
      {
         string msg = StringFormat("Sniper %s entry opened. Lots: %.2f, Entry: %.2f, Virtual SL: %.2f",
                                   (direction == 1 ? "BUY" : "SELL"), lots, price, sniperVirtualSL);
         SendEANotification(msg);
      }
      
      Print("Sniper entry opened: ", (direction == 1 ? "BUY" : "SELL"), " Lots: ", lots, " Price: ", price);
   }
   else
   {
      Print("Failed to open sniper entry. Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Check for recovery entry opportunity                            |
//+------------------------------------------------------------------+
void CheckRecoveryEntry()
{
   // Only one recovery entry allowed
   if(recoveryEntryUsed) return;
   
   // Check if trend filter still valid
   int trendDirection = GetTrendDirection();
   if(trendDirection != sniperDirection) return;
   
   // Check for deeper pullback into next zone
   double currentPrice = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   bool deeperPullback = false;
   
   if(sniperDirection == 1)
   {
      // For BUY, check if price pulled back deeper (lower)
      if(currentPrice < sniperEntryPrice)
      {
         deeperPullback = CheckInstitutionalZone(sniperDirection);
      }
   }
   else if(sniperDirection == -1)
   {
      // For SELL, check if price pulled back deeper (higher)
      if(currentPrice > sniperEntryPrice)
      {
         deeperPullback = CheckInstitutionalZone(sniperDirection);
      }
   }
   
   if(deeperPullback)
   {
      // Check momentum confirmation again
      if(CheckMomentumConfirmation(sniperDirection))
      {
         OpenSniperEntry(sniperDirection, LotSize);
         recoveryEntryUsed = true;
         
         if(EnableNotifications)
         {
            string msg = "Recovery entry opened. Lots: " + DoubleToString(LotSize, 2);
            SendEANotification(msg);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Send notification                                               |
//+------------------------------------------------------------------+
void SendEANotification(string message)
{
   SendMail("NAS100 Hybrid Sniper", message);
   Print(message);
}

//+------------------------------------------------------------------+
//| Update visual indicators on chart                               |
//+------------------------------------------------------------------+
void UpdateVisualIndicators()
{
   // Update status panel
   UpdateStatusPanel();
   
   // Draw virtual stop loss line if active
   if(sniperSetupActive && sniperVirtualSL > 0)
   {
      DrawVirtualStopLoss();
   }
   else
   {
      DeleteObject("EA_VirtualSL");
   }
   
   // Draw entry price marker if active
   if(sniperSetupActive && sniperEntryPrice > 0)
   {
      DrawEntryMarker();
   }
   else
   {
      DeleteObject("EA_EntryMarker");
   }
   
   // Draw trend filter indicators
   DrawTrendFilters();
}

//+------------------------------------------------------------------+
//| Update status panel on chart                                    |
//+------------------------------------------------------------------+
void UpdateStatusPanel()
{
   string statusText = "\n=== NAS100 Microsecond Scalper ===\n";
   
   if(UseTickBasedEntry)
   {
      statusText += "MODE: INSTANT TICK-BASED\n";
   }
   else
   {
      statusText += "MODE: HYBRID SNIPER\n";
   }
   
   // Trading hours status
   bool withinHours = IsWithinTradingHours();
   statusText += "Trading Hours: " + (withinHours ? "✓ ACTIVE" : "✗ INACTIVE") + "\n";
   
   // Get current time
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   int kenyaHour = dt.hour + 3;
   if(kenyaHour >= 24) kenyaHour -= 24;
   statusText += "Kenya Time: " + IntegerToString(kenyaHour) + ":" + 
                 StringFormat("%02d", dt.min) + "\n\n";
   
   // Trading status
   if(tradingStoppedForDay)
      statusText += "Status: STOPPED (Daily Limit)\n";
   else if(tradingStoppedForLoss)
      statusText += "Status: STOPPED (Loss Limit)\n";
   else if(sniperSetupActive)
      statusText += "Status: ACTIVE TRADE\n";
   else
      statusText += "Status: SCANNING TICKS\n";
   
   // Tick-based information
   if(UseTickBasedEntry)
   {
      double spread = (lastAsk - lastBid) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
      statusText += "\n--- Tick Data ---\n";
      statusText += "Bid: " + DoubleToString(lastBid, 2) + "\n";
      statusText += "Ask: " + DoubleToString(lastAsk, 2) + "\n";
      statusText += "Spread: " + DoubleToString(spread, 1) + " pts\n";
      statusText += "Tick Movement: " + DoubleToString(tickMovement, 2) + " pts\n";
      statusText += "Direction: " + (tickDirection == 1 ? "UP" : 
                                     tickDirection == -1 ? "DOWN" : "NEUTRAL") + "\n";
      statusText += "Consecutive Ticks: " + IntegerToString(consecutiveTicks) + "\n";
      statusText += "Signal: " + (GetInstantScalpingSignal() == 1 ? "BUY" : 
                                  GetInstantScalpingSignal() == -1 ? "SELL" : "NONE") + "\n";
   }
   
   // Sniper setup info
   if(sniperSetupActive)
   {
      statusText += "\n--- Active Trade ---\n";
      statusText += "Direction: " + (sniperDirection == 1 ? "BUY" : "SELL") + "\n";
      statusText += "Entry: " + DoubleToString(sniperEntryPrice, 2) + "\n";
      if(sniperVirtualSL > 0)
         statusText += "Virtual SL: " + DoubleToString(sniperVirtualSL, 2) + "\n";
      if(TPPoints > 0)
         statusText += "TP Target: " + DoubleToString(TPPoints, 0) + " pts\n";
   }
   
   // Show trend filters only if not in tick-based mode
   if(!UseTickBasedEntry)
   {
      int trendDirection = GetTrendDirection();
      statusText += "\n--- Trend Filters ---\n";
      statusText += "Overall: " + (trendDirection == 1 ? "BULLISH" : 
                                   trendDirection == -1 ? "BEARISH" : "NEUTRAL") + "\n";
   }
   
   // Account info
   statusText += "\n--- Account ---\n";
   statusText += "Equity: " + DoubleToString(account.Equity(), 2) + "\n";
   statusText += "Balance: " + DoubleToString(account.Balance(), 2) + "\n";
   if(startOfDayBalance > 0)
   {
      double dailyPL = account.Equity() - startOfDayBalance;
      double dailyPLPercent = (dailyPL / startOfDayBalance) * 100.0;
      statusText += "Daily P/L: " + DoubleToString(dailyPL, 2) + 
                   " (" + DoubleToString(dailyPLPercent, 2) + "%)\n";
   }
   
   // Position info
   int posCount = 0;
   double totalProfit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i)) continue;
      if(position.Magic() != MagicNumber) continue;
      if(position.Symbol() != GetTradeSymbol()) continue;
      posCount++;
      totalProfit += position.Profit() + position.Swap() + position.Commission();
   }
   statusText += "\nPositions: " + IntegerToString(posCount) + "\n";
   if(posCount > 0)
      statusText += "Floating P/L: " + DoubleToString(totalProfit, 2) + "\n";
   
   // Display on chart
   Comment(statusText);
}

//+------------------------------------------------------------------+
//| Draw virtual stop loss line                                     |
//+------------------------------------------------------------------+
void DrawVirtualStopLoss()
{
   string objName = "EA_VirtualSL";
   datetime time1 = iTime(TradeSymbol, PERIOD_M5, 0);
   datetime time2 = time1 + 300 * 20; // Extend 20 bars (300 seconds = 5 minutes)
   
   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_TREND, 0, time1, sniperVirtualSL, time2, sniperVirtualSL);
      ObjectSetInteger(0, objName, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, objName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, objName, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, objName, OBJPROP_RAY_RIGHT, true);
      ObjectSetString(0, objName, OBJPROP_TEXT, "Virtual SL: " + DoubleToString(sniperVirtualSL, 2));
   }
   else
   {
      ObjectSetDouble(0, objName, OBJPROP_PRICE, 0, sniperVirtualSL);
      ObjectSetDouble(0, objName, OBJPROP_PRICE, 1, sniperVirtualSL);
   }
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Draw entry price marker                                         |
//+------------------------------------------------------------------+
void DrawEntryMarker()
{
   string objName = "EA_EntryMarker";
   datetime time = iTime(TradeSymbol, PERIOD_M5, 0);
   
   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_ARROW, 0, time, sniperEntryPrice);
      ObjectSetInteger(0, objName, OBJPROP_ARROWCODE, 
                      (sniperDirection == 1) ? 233 : 234); // Up arrow for BUY, down for SELL
      ObjectSetInteger(0, objName, OBJPROP_COLOR, 
                      (sniperDirection == 1) ? clrLime : clrOrange);
      ObjectSetInteger(0, objName, OBJPROP_WIDTH, 3);
      ObjectSetString(0, objName, OBJPROP_TEXT, 
                      (sniperDirection == 1 ? "BUY" : "SELL") + " Entry: " + 
                      DoubleToString(sniperEntryPrice, 2));
   }
   else
   {
      ObjectSetDouble(0, objName, OBJPROP_PRICE, sniperEntryPrice);
      ObjectSetInteger(0, objName, OBJPROP_TIME, time);
   }
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Draw trend filter indicators                                    |
//+------------------------------------------------------------------+
void DrawTrendFilters()
{
   // Only draw EMA labels if not in tick-based mode and handles exist
   if(UseTickBasedEntry)
   {
      // Remove EMA labels in tick-based mode
      DeleteObject("EA_EMA20_Label");
      DeleteObject("EA_EMA50_Label");
      return;
   }
   
   // Draw EMA lines on chart (they should already be on chart if indicators are added)
   // We'll just add text labels for clarity
   
   // Note: EMA handles may not exist if EA was initialized in tick-based mode
   // This is handled gracefully by checking handles first
}

//+------------------------------------------------------------------+
//| Delete chart object                                             |
//+------------------------------------------------------------------+
void DeleteObject(string objName)
{
   if(ObjectFind(0, objName) >= 0)
   {
      ObjectDelete(0, objName);
      ChartRedraw();
   }
}

//+------------------------------------------------------------------+
//| Clean up all EA objects on deinit                               |
//+------------------------------------------------------------------+
void CleanupChartObjects()
{
   DeleteObject("EA_VirtualSL");
   DeleteObject("EA_EntryMarker");
   DeleteObject("EA_EMA20_Label");
   DeleteObject("EA_EMA50_Label");
   Comment("");
}

//+------------------------------------------------------------------+
//| Process tick movement for microsecond scalping                  |
//+------------------------------------------------------------------+
void ProcessTickMovement()
{
   string symbol = GetTradeSymbol();
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
   {
      // Fallback to Bid/Ask if tick not available
      tick.bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      tick.ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      tick.time = TimeCurrent();
   }
   
   double currentPrice = (tick.bid + tick.ask) / 2.0;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   
   // Calculate tick movement
   if(lastPrice > 0)
   {
      tickMovement = (currentPrice - lastPrice) / point;
      
      // Determine direction
      if(tickMovement > MinTickMovement)
      {
         tickDirection = 1;
         consecutiveTicks = (tickDirection == 1) ? consecutiveTicks + 1 : 1;
      }
      else if(tickMovement < -MinTickMovement)
      {
         tickDirection = -1;
         consecutiveTicks = (tickDirection == -1) ? consecutiveTicks + 1 : 1;
      }
      else
      {
         // Reset if movement is too small
         if(MathAbs(tickMovement) < MinTickMovement * 0.5)
         {
            tickDirection = 0;
            consecutiveTicks = 0;
         }
      }
   }
   
   lastBid = tick.bid;
   lastAsk = tick.ask;
   lastPrice = currentPrice;
   lastTickTime = tick.time;
}

//+------------------------------------------------------------------+
//| Get instant scalping signal from tick movement                  |
//+------------------------------------------------------------------+
int GetInstantScalpingSignal()
{
   // Check spread
   string symbol = GetTradeSymbol();
   double spread = (lastAsk - lastBid) / SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(spread > MaxSpreadPoints)
      return 0;
   
   // Instant signal based on tick movement
   // BUY: consecutive upward ticks with sufficient movement
   if(tickDirection == 1 && consecutiveTicks >= 2 && tickMovement >= TickMovementThreshold)
   {
      return 1; // BUY
   }
   
   // SELL: consecutive downward ticks with sufficient movement
   if(tickDirection == -1 && consecutiveTicks >= 2 && tickMovement <= -TickMovementThreshold)
   {
      return -1; // SELL
   }
   
   // Alternative: instant entry on strong tick movement
   if(MathAbs(tickMovement) >= TickMovementThreshold * 2)
   {
      return (tickMovement > 0) ? 1 : -1;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Open instant trade (microsecond scalper)                        |
//+------------------------------------------------------------------+
void OpenInstantTrade(int direction)
{
   if(direction == 0) return;
   
   // Check if we already have a position
   if(GetActivePositionCount() >= MaxConcurrentTrades)
      return;
   
   string symbol = GetTradeSymbol();
   double price = (direction == 1) ? lastAsk : lastBid;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   
   // Normalize lot size
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double lots = LotSize;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   if(lotStep > 0)
      lots = MathFloor(lots / lotStep) * lotStep;
   lots = NormalizeDouble(lots, 2);
   
   // NO SL/TP at order placement - manage virtually to avoid broker rejection
   // Execute trade instantly WITHOUT SL/TP
   bool result = false;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   if(direction == 1)
   {
      result = trade.Buy(lots, symbol, 0, 0, 0, "MicroScalp BUY");
   }
   else
   {
      result = trade.Sell(lots, symbol, 0, 0, 0, "MicroScalp SELL");
   }
   
   if(result)
   {
      sniperSetupActive = true;
      sniperDirection = direction;
      sniperEntryPrice = price;
      sniperEntryTime = TimeCurrent();
      sniperEntryEquity = account.Equity();
      
      if(VirtualSLPoints > 0)
      {
         if(direction == 1)
            sniperVirtualSL = price - (VirtualSLPoints * point);
         else
            sniperVirtualSL = price + (VirtualSLPoints * point);
      }
      
      Print("INSTANT TRADE OPENED: ", (direction == 1 ? "BUY" : "SELL"), 
            " | Price: ", price, " | Lots: ", lots,
            " | Tick Movement: ", tickMovement, " | Consecutive: ", consecutiveTicks);
      
      if(EnableNotifications)
      {
         string msg = StringFormat("MicroScalp %s opened instantly. Price: %.2f, Movement: %.1f points",
                                  (direction == 1 ? "BUY" : "SELL"), price, tickMovement);
         SendEANotification(msg);
      }
      
      // Reset tick tracking after entry
      consecutiveTicks = 0;
      tickDirection = 0;
   }
   else
   {
      Print("INSTANT TRADE FAILED: ", GetLastError(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Get active position count                                       |
//+------------------------------------------------------------------+
int GetActivePositionCount()
{
   string symbol = GetTradeSymbol();
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i)) continue;
      if(position.Magic() != MagicNumber) continue;
      if(position.Symbol() != symbol) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check instant profit exit (microsecond scalper)                |
//+------------------------------------------------------------------+
void CheckInstantProfitExit()
{
   string symbol = GetTradeSymbol();
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double currentPrice = (lastBid + lastAsk) / 2.0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i)) continue;
      if(position.Magic() != MagicNumber) continue;
      if(position.Symbol() != symbol) continue;
      
      double profit = position.Profit() + position.Swap() + position.Commission();
      double profitPoints = 0.0;
      
      if(position.PositionType() == POSITION_TYPE_BUY)
      {
         profitPoints = (currentPrice - position.PriceOpen()) / point;
      }
      else
      {
         profitPoints = (position.PriceOpen() - currentPrice) / point;
      }
      
      // Instant exit on TP points
      if(TPPoints > 0 && profitPoints >= TPPoints)
      {
         ulong ticket = position.Ticket();
         if(trade.PositionClose(ticket))
         {
            Print("INSTANT TP EXIT: Trade #", ticket, " closed at ", profitPoints, " points profit");
            sniperSetupActive = false;
            sniperDirection = 0;
            recoveryEntryUsed = false;
         }
      }
      
      // Instant exit on any profit if TPPoints is very small (scalping mode)
      if(TPPoints <= 10 && profit > 0.01)
      {
         ulong ticket = position.Ticket();
         if(trade.PositionClose(ticket))
         {
            Print("INSTANT SCALP EXIT: Trade #", ticket, " closed at $", profit, " profit");
            sniperSetupActive = false;
            sniperDirection = 0;
            recoveryEntryUsed = false;
         }
      }
   }
}

//+------------------------------------------------------------------+














