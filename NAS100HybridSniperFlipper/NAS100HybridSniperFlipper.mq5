//+------------------------------------------------------------------+
//|                                    NAS100HybridSniperFlipper.mq5 |
//|                        NAS100 Hybrid Sniper Flipper - Moderate Risk |
//+------------------------------------------------------------------+
#property copyright "NAS100 Hybrid Sniper Flipper"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/AccountInfo.mqh>

//--- Input Parameters ---
input string   TradeSymbol          = "USTEC";        // Trading Symbol (USTEC/US100)
input int      MagicNumber          = 20241201;      // Magic Number
input double   FirstEntryLots       = 0.50;          // First Entry Lot Size
input double   RecoveryEntryLots   = 0.65;          // Recovery Entry Lot Size (only one)
input int      VirtualSLPoints      = 200;           // Virtual Stop Loss (150-250 NAS100 points)
input double   DailyProfitPercent   = 0.40;          // Daily Profit Cap (0.30, 0.40, or 0.50)
input bool     EnableNotifications  = true;          // Enable Push Notifications
input int      RSI_Period           = 14;            // RSI Period
input int      EMA_Fast_Period      = 20;            // Fast EMA Period
input int      EMA_Slow_Period      = 50;            // Slow EMA Period

//--- Global Variables ---
CTrade         trade;
CPositionInfo  position;
CAccountInfo   account;

// Handles
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
   // Set magic number
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Initialize indicators
   ema20Handle = iMA(TradeSymbol, PERIOD_M5, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   ema50Handle = iMA(TradeSymbol, PERIOD_M5, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle = iRSI(TradeSymbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   
   if(ema20Handle == INVALID_HANDLE || ema50Handle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }
   
   // Initialize daily tracking
   ResetDailyTracking();
   
   // Verify symbol
   if(!SymbolSelect(TradeSymbol, true))
   {
      Print("Failed to select symbol: ", TradeSymbol);
      return INIT_FAILED;
   }
   
   Print("NAS100 Hybrid Sniper Flipper initialized successfully");
   Print("Trading Symbol: ", TradeSymbol);
   Print("Trading Time: 15:30 - 18:00 Kenya Time");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
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
      // Still monitor for end of session to close positions
      if(IsEndOfSession())
      {
         CloseAllPositions();
      }
      return;
   }
   
   // Check trading time window
   if(!IsWithinTradingHours())
   {
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
   
   // If no active sniper setup, look for new entry
   if(!sniperSetupActive)
   {
      LookForSniperEntry();
   }
   else
   {
      // Check for recovery entry opportunity
      CheckRecoveryEntry();
   }
   
   // Update structure tracking
   UpdateStructureTracking();
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
   // Get UTC time (broker server time is typically UTC)
   datetime utcTime = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(utcTime, dt);
   
   // Convert to Kenya Time (UTC+3)
   int kenyaHour = dt.hour + 3;
   if(kenyaHour >= 24) kenyaHour -= 24;
   
   int totalMinutes = kenyaHour * 60 + dt.min;
   
   int startMinutes = 15 * 60 + 30;  // 15:30
   int endMinutes = 18 * 60;         // 18:00
   
   return (totalMinutes >= startMinutes && totalMinutes < endMinutes);
}

//+------------------------------------------------------------------+
//| Check if end of session (18:00 Kenya Time)                      |
//+------------------------------------------------------------------+
bool IsEndOfSession()
{
   // Get UTC time
   datetime utcTime = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(utcTime, dt);
   
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
      if(position.Symbol() != TradeSymbol) continue;
      
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
      if(position.Symbol() != TradeSymbol) continue;
      
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
   if(trendDirection == 0) return;  // No clear trend or filters disagree
   
   // Check for pullback into institutional zone
   bool inZone = CheckInstitutionalZone(trendDirection);
   if(!inZone) return;
   
   // Check momentum confirmation
   bool momentumConfirmed = CheckMomentumConfirmation(trendDirection);
   if(!momentumConfirmed) return;
   
   // All conditions met - open sniper entry
   OpenSniperEntry(trendDirection, FirstEntryLots);
}

//+------------------------------------------------------------------+
//| Get trend direction based on EMA, BOS, and momentum             |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
   // Get EMA values
   double ema20[], ema50[];
   ArraySetAsSeries(ema20, true);
   ArraySetAsSeries(ema50, true);
   
   if(CopyBuffer(ema20Handle, 0, 0, 2, ema20) < 2) return 0;
   if(CopyBuffer(ema50Handle, 0, 0, 2, ema50) < 2) return 0;
   
   bool emaBullish = (ema20[0] > ema50[0]);
   bool emaBearish = (ema20[0] < ema50[0]);
   
   // Check M5 BOS
   int bosDirection = GetM5BOSDirection();
   
   // Check momentum direction
   int momentumDirection = GetMomentumDirection();
   
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
   
   // Bullish BOS: current close breaks above recent swing high
   if(swingHigh > 0 && currentClose > swingHigh && swingHighBar > swingLowBar)
      return 1;
   
   // Bearish BOS: current close breaks below recent swing low
   if(swingLow < DBL_MAX && currentClose < swingLow && swingLowBar > swingHighBar)
      return -1;
   
   return 0;
}

//+------------------------------------------------------------------+
//| Get momentum direction                                          |
//+------------------------------------------------------------------+
int GetMomentumDirection()
{
   double close[];
   ArraySetAsSeries(close, true);
   
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, 5, close) < 5) return 0;
   
   // Simple momentum: compare recent closes
   double momentum = close[0] - close[3];  // Current vs 3 bars ago
   
   if(momentum > 0) return 1;   // Upward momentum
   if(momentum < 0) return -1;  // Downward momentum
   
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
         OpenSniperEntry(sniperDirection, RecoveryEntryLots);
         recoveryEntryUsed = true;
         
         if(EnableNotifications)
         {
            string msg = "Recovery entry opened. Lots: " + DoubleToString(RecoveryEntryLots, 2);
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




