#property copyright "Copyright 2025, Hyperactive HFT MT5 - MSS + OB + FVG Confluence"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

CTrade trade;

// =====================================================================================================
// MSS + ORDER BLOCK + FVG CONFLUENCE EA
// Strategy: Quality setups per day using Market Structure Shift + Order Block + Fair Value Gap
// - Multi-instrument support
// - Limit orders only (no market orders)
// - Fixed lot: 1.0
// - SL beyond Order Block
// - TP at 1.5R-2R
// - Min 10 trades/day total, Min 2 trades per symbol
// - Stop trading after 3 consecutive losses
// =====================================================================================================

// ===== Core Trading Settings =====
input group "===== Core Trading Settings ====="
input int      MagicNumber         = 202520;
input string   TradeSymbols        = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,XAUUSD"; // Comma-separated symbols (base names, suffix auto-detected)
input ENUM_TIMEFRAMES Timeframe    = PERIOD_H1;  // Timeframe for MSS/OB/FVG detection
input double   FixedLotSize        = 1.0;         // Fixed lot size (always 1.0)
input int      SwingLookbackBars   = 20;         // Bars to look back for swing detection

// ===== FVG Settings =====
input group "===== Fair Value Gap Settings ====="
input double   FVGMinSizePoints    = 10.0;       // Minimum FVG size in points
input double   FVGEntryPercent     = 50.0;       // Entry at X% of FVG (0=start, 50=middle, 100=end)
input bool     RequireOBTouch      = false;       // Require OB touch as confirmation (optional)

// ===== Risk Management =====
input group "===== Risk Management ====="
input double   RiskRewardRatio     = 1.75;       // Risk:Reward ratio (1.5-2.0 range)
input double   SLBufferPoints      = 5.0;        // SL buffer beyond OB (points)
input int      MaxConsecutiveLosses = 3;         // Stop trading after N consecutive losses

// ===== Trade Limits =====
input group "===== Trade Limits ====="
input int      MinDailyTrades      = 10;         // Minimum trades per day (total)
input int      MinTradesPerSymbol  = 2;          // Minimum trades per symbol per day
input int      MaxDailyTrades      = 100;        // Maximum trades per day (safety limit)

// ===== Spread & Execution =====
input group "===== Spread & Execution ====="
input double   MaxSpreadPoints     = 30.0;       // Maximum spread in points
input double   MaxSpreadPercent    = 0.15;       // Maximum spread as % of price (for exotics)
input bool     TradeOnlyMajors     = false;      // Only trade major pairs (EUR, GBP, USD, JPY, AUD, CAD, CHF, NZD, XAU)
input string   BlacklistedSymbols  = "USDSEK,USDCNH,USDTRY,USDZAR,USDMXN,USDBRL"; // Comma-separated blacklist
input int      MaxSlippagePoints   = 10;         // Maximum slippage in points
input int      OrderRetries        = 3;          // Number of order retries

// ===== Debug Settings =====
input group "===== Debug Settings ====="
input bool     EnableDebugLogging  = true;       // Enable debug logging

// =====================================================================================================
// STRUCTURES & GLOBALS
// =====================================================================================================

// Structure for swing points
struct SwingPoint {
   double price;
   datetime time;
   int barIndex;
   bool isHigh;
};

// Structure for Order Block
struct OrderBlock {
   double high;
   double low;
   datetime time;
   int barIndex;
   bool isBullish;  // true = bullish OB (last bearish candle before bullish break)
};

// Structure for Fair Value Gap
struct FairValueGap {
   double top;
   double bottom;
   datetime time;
   int barIndex;
   bool isBullish;  // true = bullish FVG (gap up)
};

// Structure for Market Structure Shift
struct MarketStructureShift {
   bool detected;
   int direction;  // 1 = bullish MSS, -1 = bearish MSS
   datetime time;
   int barIndex;
   SwingPoint brokenSwing;
   OrderBlock ob;
   FairValueGap fvg;
};

// Structure for symbol data
struct SymbolData {
   string symbol;
   double point;
   int digits;
   int dailyTradeCount;
   datetime lastTradeTime;
   MarketStructureShift lastMSS;
   SwingPoint lastSwingHigh;
   SwingPoint lastSwingLow;
   bool hasActiveLimitOrder;
   ulong limitOrderTicket;
};

// Global arrays
string symbolList[];
SymbolData symbolData[];
int symbolCount = 0;

// Daily tracking
int dailyTotalTrades = 0;
datetime lastDayReset = 0;
int consecutiveLosses = 0;
bool tradingStopped = false;

// Trade tracking
struct PendingTrade {
   string symbol;
   int direction;  // 1=BUY, -1=SELL
   double entryPrice;
   double sl;
   double tp;
   ulong orderTicket;
   datetime orderTime;
   bool isActive;
};

PendingTrade pendingTrades[];
int pendingTradeCount = 0;

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("MSS + Order Block + FVG Confluence EA v1.00");
   Print("Multi-instrument quality setup trading");
   Print("========================================");
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints);
   
   // Parse symbol list
   if(!ParseSymbolList(TradeSymbols))
   {
      Print("ERROR: Failed to parse symbol list!");
      return(INIT_FAILED);
   }
   
   // Initialize symbol data and validate
   int totalSymbols = symbolCount;
   SymbolData tempData[];
   string tempList[];
   int validSymbols = 0;
   
   ArrayResize(tempData, totalSymbols);
   ArrayResize(tempList, totalSymbols);
   
   for(int i = 0; i < totalSymbols; i++)
   {
      if(!InitializeSymbol(tempData[validSymbols], symbolList[i]))
      {
         Print("WARNING: Failed to initialize symbol: ", symbolList[i]);
         continue;
      }
      
      // Validate symbol suitability
      if(IsSymbolBlacklisted(symbolList[i]))
      {
         Print("WARNING: Symbol is blacklisted: ", symbolList[i], " - Skipping");
         continue;
      }
      
      if(TradeOnlyMajors && !IsMajorPair(symbolList[i]))
      {
         Print("WARNING: Symbol is not a major pair: ", symbolList[i], " - Skipping (TradeOnlyMajors=true)");
         continue;
      }
      
      tempList[validSymbols] = symbolList[i];
      validSymbols++;
   }
   
   // Update arrays with only valid symbols
   if(validSymbols > 0)
   {
      ArrayResize(symbolData, validSymbols);
      ArrayResize(symbolList, validSymbols);
      
      for(int i = 0; i < validSymbols; i++)
      {
         symbolData[i] = tempData[i];
         symbolList[i] = tempList[i];
      }
      
      symbolCount = validSymbols;
      
      if(validSymbols < totalSymbols)
         Print("Filtered symbols: ", validSymbols, " valid out of ", totalSymbols, " total");
   }
   else
   {
      symbolCount = 0;
   }
   
   if(symbolCount == 0)
   {
      Print("ERROR: No valid symbols to trade!");
      return(INIT_FAILED);
   }
   
   // Initialize daily tracking
   lastDayReset = TimeCurrent();
   dailyTotalTrades = 0;
   consecutiveLosses = 0;
   tradingStopped = false;
   
   // Initialize pending trades array
   ArrayResize(pendingTrades, 0);
   pendingTradeCount = 0;
   
   Print("Initialized ", symbolCount, " valid symbols");
   Print("Timeframe: ", EnumToString(Timeframe));
   Print("Fixed Lot: ", FixedLotSize);
   Print("Trade Only Majors: ", (TradeOnlyMajors ? "YES" : "NO"));
   Print("Blacklisted Symbols: ", BlacklistedSymbols);
   Print("Max Spread: ", MaxSpreadPoints, " points (", MaxSpreadPercent, "% relative)");
   Print("Min Daily Trades: ", MinDailyTrades);
   Print("Min Trades Per Symbol: ", MinTradesPerSymbol);
   Print("Max Consecutive Losses: ", MaxConsecutiveLosses);
   Print("========================================");
   Print("NOTE: EA works in Strategy Tester. Symbols with high spreads");
   Print("      or blacklisted pairs will be automatically skipped.");
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // Cancel all pending limit orders
   for(int i = 0; i < pendingTradeCount; i++)
   {
      if(pendingTrades[i].isActive && pendingTrades[i].orderTicket > 0)
      {
         trade.OrderDelete(pendingTrades[i].orderTicket);
      }
   }
   
   Print("MSS + OB + FVG EA deinitialized. Reason: ", reason);
}

// =====================================================================================================
// SYMBOL VALIDATION
// =====================================================================================================

bool IsSymbolBlacklisted(string symbol)
{
   if(StringLen(BlacklistedSymbols) == 0)
      return false;
   
   string blacklist[];
   int count = StringSplit(BlacklistedSymbols, ',', blacklist);
   
   for(int i = 0; i < count; i++)
   {
      StringTrimLeft(blacklist[i]);
      StringTrimRight(blacklist[i]);
      if(StringFind(symbol, blacklist[i]) >= 0)
         return true;
   }
   
   return false;
}

bool IsMajorPair(string symbol)
{
   // Major pairs contain: EUR, GBP, USD, JPY, AUD, CAD, CHF, NZD, XAU
   string majors[] = {"EUR", "GBP", "USD", "JPY", "AUD", "CAD", "CHF", "NZD", "XAU"};
   
   for(int i = 0; i < ArraySize(majors); i++)
   {
      if(StringFind(symbol, majors[i]) >= 0)
      {
         // Check if it's a pair (contains two majors)
         for(int j = 0; j < ArraySize(majors); j++)
         {
            if(i != j && StringFind(symbol, majors[j]) >= 0)
               return true;
         }
      }
   }
   
   return false;
}

bool IsSymbolSuitableForTrading(SymbolData &data)
{
   // Check blacklist
   if(IsSymbolBlacklisted(data.symbol))
   {
      if(EnableDebugLogging)
         Print("SKIP: Symbol blacklisted: ", data.symbol);
      return false;
   }
   
   // Check if only majors allowed
   if(TradeOnlyMajors && !IsMajorPair(data.symbol))
   {
      if(EnableDebugLogging)
         Print("SKIP: Not a major pair: ", data.symbol);
      return false;
   }
   
   // Get current spread
   MqlTick tick;
   if(!SymbolInfoTick(data.symbol, tick))
      return false;
   
   double spread = (tick.ask - tick.bid) / data.point;
   
   // Check absolute spread limit
   if(spread > MaxSpreadPoints)
   {
      if(EnableDebugLogging)
         Print("SKIP: Spread too wide (absolute) for ", data.symbol, ": ", spread, " points (max: ", MaxSpreadPoints, ")");
      return false;
   }
   
   // Check relative spread limit (for exotics that might pass absolute but have high % spread)
   double midPrice = (tick.ask + tick.bid) / 2.0;
   double spreadPercent = (spread * data.point / midPrice) * 100.0;
   
   if(spreadPercent > MaxSpreadPercent)
   {
      if(EnableDebugLogging)
         Print("SKIP: Spread too wide (percentage) for ", data.symbol, ": ", DoubleToString(spreadPercent, 3), "% (max: ", DoubleToString(MaxSpreadPercent, 2), "%)");
      return false;
   }
   
   return true;
}

// =====================================================================================================
// SYMBOL NAME RESOLUTION (handles broker suffixes like .Z, b, .m, etc.)
// =====================================================================================================

string ResolveSymbolName(string baseName)
{
   // 1. Try exact match first
   if(SymbolInfoInteger(baseName, SYMBOL_SELECT) || SymbolSelect(baseName, true))
      return baseName;

   // 2. Scan all available symbols for one that starts with baseName + suffix
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
   {
      string sym = SymbolName(i, false);
      int baseLen = StringLen(baseName);
      int symLen  = StringLen(sym);
      // Must start with baseName exactly, followed by a short suffix
      if(symLen > baseLen && symLen <= baseLen + 4 &&
         StringFind(sym, baseName) == 0)
      {
         if(EnableDebugLogging)
            Print("Symbol resolved: ", baseName, " -> ", sym);
         return sym;
      }
   }

   // 3. Not found — return original; InitializeSymbol will fail gracefully
   return baseName;
}

// =====================================================================================================
// SYMBOL MANAGEMENT
// =====================================================================================================

bool ParseSymbolList(string symbols)
{
   string temp[];
   int count = StringSplit(symbols, ',', temp);
   
   if(count <= 0)
   {
      Print("ERROR: No symbols provided!");
      return false;
   }
   
   ArrayResize(symbolList, count);
   symbolCount = 0;
   
   for(int i = 0; i < count; i++)
   {
      StringTrimLeft(temp[i]);
      StringTrimRight(temp[i]);
      
      if(StringLen(temp[i]) > 0)
      {
         symbolList[symbolCount] = temp[i];
         symbolCount++;
      }
   }
   
   return (symbolCount > 0);
}

bool InitializeSymbol(SymbolData &data, string symbol)
{
   // Auto-resolve broker suffix (e.g. GBPUSD → GBPUSD.Z)
   string resolved = ResolveSymbolName(symbol);
   data.symbol = resolved;

   // Ensure symbol is selected/visible in Market Watch
   if(!SymbolInfoInteger(resolved, SYMBOL_EXIST))
   {
      Print("ERROR: Symbol ", symbol, " not found (resolved: ", resolved, ")");
      return false;
   }
   SymbolSelect(resolved, true);
   
   data.digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   data.point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(data.digits == 3 || data.digits == 5)
      data.point *= 10.0;
   
   data.dailyTradeCount = 0;
   data.lastTradeTime = 0;
   data.hasActiveLimitOrder = false;
   data.limitOrderTicket = 0;
   
   // Initialize MSS
   data.lastMSS.detected = false;
   data.lastMSS.direction = 0;
   
   // Initialize swing points
   data.lastSwingHigh.price = 0.0;
   data.lastSwingLow.price = 0.0;
   
   return true;
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   // Reset daily counters if new day
   ResetDailyCounters();
   
   // Check if trading is stopped
   if(tradingStopped)
   {
      UpdateDisplay();
      return;
   }
   
   // Check pending orders and manage active trades
   ManagePendingOrders();
   ManageActiveTrades();
   
   // Scan all symbols for MSS + OB + FVG setups (only on new bar to avoid excessive scanning)
   // Use first symbol's bar time as reference
   static datetime lastBarTime = 0;
   datetime currentBarTime = 0;
   
   if(symbolCount > 0)
   {
      currentBarTime = iTime(symbolList[0], Timeframe, 0);
   }
   
   if(currentBarTime != lastBarTime && currentBarTime > 0)
   {
      lastBarTime = currentBarTime;
      
      // Scan all symbols for MSS + OB + FVG setups
      for(int i = 0; i < symbolCount; i++)
      {
         ScanForSetups(symbolData[i]);
      }
   }
   
   UpdateDisplay();
}

// =====================================================================================================
// DAILY COUNTERS
// =====================================================================================================

void ResetDailyCounters()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime dt, lastDt;
   TimeToStruct(currentTime, dt);
   TimeToStruct(lastDayReset, lastDt);
   
   if(dt.day != lastDt.day || dt.mon != lastDt.mon || dt.year != lastDt.year)
   {
      // New day - reset counters
      dailyTotalTrades = 0;
      lastDayReset = currentTime;
      
      // Reset symbol daily counts
      for(int i = 0; i < symbolCount; i++)
      {
         symbolData[i].dailyTradeCount = 0;
      }
      
      Print("New day - counters reset");
   }
}

// =====================================================================================================
// SWING DETECTION
// =====================================================================================================

bool DetectSwingPoints(SymbolData &data, SwingPoint &swingHigh, SwingPoint &swingLow)
{
   if(Bars(data.symbol, Timeframe) < SwingLookbackBars + 5)
      return false;
   
   double highBuffer[];
   double lowBuffer[];
   datetime timeBuffer[];
   
   ArrayResize(highBuffer, SwingLookbackBars);
   ArrayResize(lowBuffer, SwingLookbackBars);
   ArrayResize(timeBuffer, SwingLookbackBars);
   
   if(CopyHigh(data.symbol, Timeframe, 1, SwingLookbackBars, highBuffer) <= 0)
      return false;
   if(CopyLow(data.symbol, Timeframe, 1, SwingLookbackBars, lowBuffer) <= 0)
      return false;
   if(CopyTime(data.symbol, Timeframe, 1, SwingLookbackBars, timeBuffer) <= 0)
      return false;
   
   // Find swing high (highest high in lookback)
   int highIndex = ArrayMaximum(highBuffer, 0, SwingLookbackBars);
   if(highIndex < 0)
      return false;
   
   swingHigh.price = highBuffer[highIndex];
   swingHigh.time = timeBuffer[highIndex];
   swingHigh.barIndex = highIndex;
   swingHigh.isHigh = true;
   
   // Find swing low (lowest low in lookback)
   int lowIndex = ArrayMinimum(lowBuffer, 0, SwingLookbackBars);
   if(lowIndex < 0)
      return false;
   
   swingLow.price = lowBuffer[lowIndex];
   swingLow.time = timeBuffer[lowIndex];
   swingLow.barIndex = lowIndex;
   swingLow.isHigh = false;
   
   return true;
}

// =====================================================================================================
// MARKET STRUCTURE SHIFT DETECTION
// =====================================================================================================

bool DetectMarketStructureShift(SymbolData &data, MarketStructureShift &mss)
{
   if(Bars(data.symbol, Timeframe) < SwingLookbackBars + 10)
      return false;
   
   // Get current and previous candles
   MqlRates rates[3];
   if(CopyRates(data.symbol, Timeframe, 1, 3, rates) != 3)
      return false;
   
   MqlRates currentCandle = rates[0];  // Most recent closed candle
   MqlRates prevCandle = rates[1];
   
   // Detect swing points
   SwingPoint swingHigh, swingLow;
   if(!DetectSwingPoints(data, swingHigh, swingLow))
      return false;
   
   // Check for bullish MSS: price breaks and closes above swing high
   if(currentCandle.close > swingHigh.price && prevCandle.close <= swingHigh.price)
   {
      mss.detected = true;
      mss.direction = 1;  // Bullish
      mss.time = currentCandle.time;
      mss.barIndex = 0;
      mss.brokenSwing = swingHigh;
      
      // Find Order Block (last bearish candle before the break)
      if(!FindOrderBlock(data, mss, 1))
         return false;
      
      // Find FVG created by the impulse
      if(!FindFVG(data, mss, 1))
         return false;
      
      return true;
   }
   
   // Check for bearish MSS: price breaks and closes below swing low
   if(currentCandle.close < swingLow.price && prevCandle.close >= swingLow.price)
   {
      mss.detected = true;
      mss.direction = -1;  // Bearish
      mss.time = currentCandle.time;
      mss.barIndex = 0;
      mss.brokenSwing = swingLow;
      
      // Find Order Block (last bullish candle before the break)
      if(!FindOrderBlock(data, mss, -1))
         return false;
      
      // Find FVG created by the impulse
      if(!FindFVG(data, mss, -1))
         return false;
      
      return true;
   }
   
   return false;
}

// =====================================================================================================
// ORDER BLOCK DETECTION
// =====================================================================================================

bool FindOrderBlock(SymbolData &data, MarketStructureShift &mss, int direction)
{
   // Look back from the break candle to find the last opposite candle
   MqlRates rates[];
   int lookback = 20;  // Look back up to 20 bars
   
   if(CopyRates(data.symbol, Timeframe, 1, lookback, rates) < lookback)
      return false;
   
   // For bullish MSS, find last bearish candle before break
   // For bearish MSS, find last bullish candle before break
   for(int i = 1; i < lookback; i++)
   {
      bool isOpposite = false;
      
      if(direction == 1)  // Bullish MSS - find bearish candle
      {
         isOpposite = (rates[i].close < rates[i].open);
      }
      else  // Bearish MSS - find bullish candle
      {
         isOpposite = (rates[i].close > rates[i].open);
      }
      
      if(isOpposite)
      {
         // Found the Order Block
         mss.ob.high = rates[i].high;
         mss.ob.low = rates[i].low;
         mss.ob.time = rates[i].time;
         mss.ob.barIndex = i;
         mss.ob.isBullish = (direction == 1);
         
         return true;
      }
   }
   
   return false;
}

// =====================================================================================================
// FAIR VALUE GAP DETECTION
// =====================================================================================================

bool FindFVG(SymbolData &data, MarketStructureShift &mss, int direction)
{
   // FVG is created by the MSS impulse (the break candle and subsequent candles)
   // Look for a gap between candle wicks in the impulse move
   
   MqlRates rates[10];
   int barsToCheck = 10;
   if(CopyRates(data.symbol, Timeframe, 1, barsToCheck, rates) < barsToCheck)
      return false;
   
   // The break candle is at index 0 (most recent closed)
   // Look for FVG in the impulse move (break candle and next few candles)
   
   if(direction == 1)  // Bullish MSS - look for gap up
   {
      // Look for gap up: current low > previous high (gap between wicks)
      // Check from break candle (index 0) backwards through the impulse
      for(int i = 0; i < 5; i++)
      {
         if(i + 1 >= barsToCheck)
            break;
            
         // Gap up: current candle's low is above previous candle's high
         if(rates[i].low > rates[i+1].high)
         {
            // Found bullish FVG
            mss.fvg.bottom = rates[i+1].high;  // Bottom of gap = previous high
            mss.fvg.top = rates[i].low;        // Top of gap = current low
            mss.fvg.time = rates[i].time;
            mss.fvg.barIndex = i;
            mss.fvg.isBullish = true;
            
            // Check FVG size
            double fvgSize = (mss.fvg.top - mss.fvg.bottom) / data.point;
            if(fvgSize >= FVGMinSizePoints)
            {
               // Check if FVG sits above/overlapping OB for buys
               if(mss.fvg.bottom >= mss.ob.low)  // FVG overlaps or above OB
               {
                  return true;
               }
            }
         }
      }
   }
   else  // Bearish MSS - look for gap down
   {
      // Look for gap down: current high < previous low (gap between wicks)
      for(int i = 0; i < 5; i++)
      {
         if(i + 1 >= barsToCheck)
            break;
            
         // Gap down: current candle's high is below previous candle's low
         if(rates[i].high < rates[i+1].low)
         {
            // Found bearish FVG
            mss.fvg.top = rates[i+1].low;      // Top of gap = previous low
            mss.fvg.bottom = rates[i].high;     // Bottom of gap = current high
            mss.fvg.time = rates[i].time;
            mss.fvg.barIndex = i;
            mss.fvg.isBullish = false;
            
            // Check FVG size
            double fvgSize = (mss.fvg.top - mss.fvg.bottom) / data.point;
            if(fvgSize >= FVGMinSizePoints)
            {
               // Check if FVG sits below/overlapping OB for sells
               if(mss.fvg.top <= mss.ob.high)  // FVG overlaps or below OB
               {
                  return true;
               }
            }
         }
      }
   }
   
   return false;
}

// =====================================================================================================
// SCAN FOR SETUPS
// =====================================================================================================

void ScanForSetups(SymbolData &data)
{
   // Check daily limits
   if(dailyTotalTrades >= MaxDailyTrades)
      return;
   
   if(data.dailyTradeCount >= MinTradesPerSymbol && dailyTotalTrades >= MinDailyTrades)
   {
      // Symbol has met minimum, and daily minimum met - can still trade if under max
      if(data.dailyTradeCount >= MaxDailyTrades / symbolCount)
         return;  // Symbol has reached its fair share
   }
   
   // Check if symbol already has active limit order
   if(data.hasActiveLimitOrder)
      return;
   
   // Validate symbol suitability (blacklist, majors only, spread checks)
   if(!IsSymbolSuitableForTrading(data))
      return;
   
   // Detect Market Structure Shift
   MarketStructureShift mss;
   if(!DetectMarketStructureShift(data, mss))
      return;
   
   // Check if this is a new MSS (not the same as last one)
   if(data.lastMSS.detected && 
      data.lastMSS.time == mss.time && 
      data.lastMSS.direction == mss.direction)
   {
      return;  // Already processed this MSS
   }
   
   // Optional: Check if OB was touched (enhanced confirmation)
   if(RequireOBTouch)
   {
      MqlTick tick;
      if(!SymbolInfoTick(data.symbol, tick))
         return;
      
      double currentPrice = (tick.bid + tick.ask) / 2.0;
      bool obTouched = false;
      
      if(mss.direction == 1)  // Bullish - check if price touched OB before breaking
      {
         // For bullish, check if price was in OB range at some point
         // Look at recent candles to see if OB was touched
         MqlRates rates[10];
         if(CopyRates(data.symbol, Timeframe, 1, 10, rates) >= 10)
         {
            for(int i = 0; i < 10; i++)
            {
               // Check if candle touched OB (low <= OB high && high >= OB low)
               if(rates[i].low <= mss.ob.high && rates[i].high >= mss.ob.low)
               {
                  obTouched = true;
                  break;
               }
            }
         }
      }
      else  // Bearish - check if price touched OB before breaking
      {
         // For bearish, check if price was in OB range at some point
         MqlRates rates[10];
         if(CopyRates(data.symbol, Timeframe, 1, 10, rates) >= 10)
         {
            for(int i = 0; i < 10; i++)
            {
               // Check if candle touched OB (low <= OB high && high >= OB low)
               if(rates[i].low <= mss.ob.high && rates[i].high >= mss.ob.low)
               {
                  obTouched = true;
                  break;
               }
            }
         }
      }
      
      if(!obTouched)
      {
         if(EnableDebugLogging)
            Print("SKIP: OB not touched for ", data.symbol);
         return;  // OB not touched, skip
      }
   }
   
   // Setup confirmed - place limit order
   PlaceLimitOrder(data, mss);
   
   // Store MSS
   data.lastMSS = mss;
}

// =====================================================================================================
// PLACE LIMIT ORDER
// =====================================================================================================

void PlaceLimitOrder(SymbolData &data, MarketStructureShift &mss)
{
   // Get current price
   MqlTick tick;
   if(!SymbolInfoTick(data.symbol, tick))
   {
      Print("ERROR: Cannot get tick data for ", data.symbol);
      return;
   }
   
   double currentBid = tick.bid;
   double currentAsk = tick.ask;
   double currentPrice = (currentBid + currentAsk) / 2.0;
   
   // Calculate entry price (at FVG start or 50%)
   double entryPrice = 0.0;
   double fvgSize = mss.fvg.top - mss.fvg.bottom;
   
   if(FVGEntryPercent <= 0.0)
      entryPrice = mss.fvg.bottom;  // Start of FVG
   else if(FVGEntryPercent >= 100.0)
      entryPrice = mss.fvg.top;  // End of FVG
   else
      entryPrice = mss.fvg.bottom + (fvgSize * FVGEntryPercent / 100.0);  // X% into FVG
   
   entryPrice = NormalizeDouble(entryPrice, data.digits);
   
   // Validate entry price for limit orders
   if(mss.direction == 1)  // BUY - entry must be below current ask
   {
      if(entryPrice >= currentAsk)
      {
         if(EnableDebugLogging)
            Print("SKIP: BUY limit entry price (", entryPrice, ") >= current ask (", currentAsk, ")");
         return;  // Price already moved past entry
      }
      
      // Ensure entry is within FVG
      if(entryPrice < mss.fvg.bottom || entryPrice > mss.fvg.top)
      {
         if(EnableDebugLogging)
            Print("SKIP: BUY entry price (", entryPrice, ") outside FVG [", mss.fvg.bottom, ", ", mss.fvg.top, "]");
         return;
      }
   }
   else  // SELL - entry must be above current bid
   {
      if(entryPrice <= currentBid)
      {
         if(EnableDebugLogging)
            Print("SKIP: SELL limit entry price (", entryPrice, ") <= current bid (", currentBid, ")");
         return;  // Price already moved past entry
      }
      
      // Ensure entry is within FVG
      if(entryPrice < mss.fvg.bottom || entryPrice > mss.fvg.top)
      {
         if(EnableDebugLogging)
            Print("SKIP: SELL entry price (", entryPrice, ") outside FVG [", mss.fvg.bottom, ", ", mss.fvg.top, "]");
         return;
      }
   }
   
   // Calculate SL (beyond Order Block)
   double sl = 0.0;
   if(mss.direction == 1)  // BUY
   {
      sl = mss.ob.low - (SLBufferPoints * data.point);
   }
   else  // SELL
   {
      sl = mss.ob.high + (SLBufferPoints * data.point);
   }
   sl = NormalizeDouble(sl, data.digits);
   
   // Calculate TP (1.5R-2R)
   double risk = MathAbs(entryPrice - sl);
   double tp = 0.0;
   if(mss.direction == 1)  // BUY
   {
      tp = entryPrice + (risk * RiskRewardRatio);
   }
   else  // SELL
   {
      tp = entryPrice - (risk * RiskRewardRatio);
   }
   tp = NormalizeDouble(tp, data.digits);
   
   // Determine order type
   ENUM_ORDER_TYPE orderType;
   if(mss.direction == 1)  // BUY
   {
      orderType = ORDER_TYPE_BUY_LIMIT;
   }
   else  // SELL
   {
      orderType = ORDER_TYPE_SELL_LIMIT;
   }
   
   // Place limit order
   string comment = "MSS_OB_FVG_" + (mss.direction == 1 ? "BUY" : "SELL");
   
   bool sent = false;
   int retries = 0;
   
   while(retries < OrderRetries && !sent)
   {
      if(mss.direction == 1)  // BUY
      {
         sent = trade.BuyLimit(FixedLotSize, entryPrice, data.symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      }
      else  // SELL
      {
         sent = trade.SellLimit(FixedLotSize, entryPrice, data.symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      }
      
      if(!sent)
      {
         retries++;
         if(retries < OrderRetries)
         {
            Sleep(50);
         }
      }
   }
   
   if(sent)
   {
      ulong ticket = trade.ResultOrder();
      
      if(ticket > 0)
      {
         // Add to pending trades
         int index = pendingTradeCount;
         ArrayResize(pendingTrades, pendingTradeCount + 1);
         
         pendingTrades[index].symbol = data.symbol;
         pendingTrades[index].direction = mss.direction;
         pendingTrades[index].entryPrice = entryPrice;
         pendingTrades[index].sl = sl;
         pendingTrades[index].tp = tp;
         pendingTrades[index].orderTicket = ticket;
         pendingTrades[index].orderTime = TimeCurrent();
         pendingTrades[index].isActive = true;
         
         pendingTradeCount++;
         
         data.hasActiveLimitOrder = true;
         data.limitOrderTicket = ticket;
         
         Print("LIMIT ORDER PLACED: ", data.symbol, " | ", 
               (mss.direction == 1 ? "BUY" : "SELL"), 
               " | Entry: ", entryPrice, " | SL: ", sl, " | TP: ", tp);
      }
   }
   else
   {
      Print("LIMIT ORDER FAILED: ", data.symbol, " | Error: ", 
            trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}

// =====================================================================================================
// MANAGE PENDING ORDERS
// =====================================================================================================

void ManagePendingOrders()
{
   // Check all pending orders in MT5
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0)
         continue;
      
      if(!OrderSelect(ticket))
         continue;
      
      // Check if this is our order
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;
      
      string orderSymbol = OrderGetString(ORDER_SYMBOL);
      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      
      // Check if order is still pending
      if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT)
      {
         // Order still pending - update symbol data
         for(int j = 0; j < symbolCount; j++)
         {
            if(symbolData[j].symbol == orderSymbol)
            {
               symbolData[j].hasActiveLimitOrder = true;
               symbolData[j].limitOrderTicket = ticket;
               break;
            }
         }
      }
   }
   
   // Check history for filled orders
   datetime currentTime = TimeCurrent();
   datetime checkTime = currentTime - 60;  // Last minute
   
   if(HistorySelect(checkTime, currentTime))
   {
      int totalOrders = HistoryOrdersTotal();
      
      for(int i = 0; i < totalOrders; i++)
      {
         ulong ticket = HistoryOrderGetTicket(i);
         if(ticket <= 0)
            continue;
         
         if(HistoryOrderGetInteger(ticket, ORDER_MAGIC) != MagicNumber)
            continue;
         
         // Check if this order was in our pending list
         for(int j = 0; j < pendingTradeCount; j++)
         {
            if(pendingTrades[j].orderTicket == ticket && pendingTrades[j].isActive)
            {
               // Order was filled or deleted
               Print("ORDER PROCESSED: ", pendingTrades[j].symbol, " | Ticket: ", ticket);
               
               // Update symbol data
               for(int k = 0; k < symbolCount; k++)
               {
                  if(symbolData[k].symbol == pendingTrades[j].symbol)
                  {
                     symbolData[k].hasActiveLimitOrder = false;
                     symbolData[k].limitOrderTicket = 0;
                     break;
                  }
               }
               
               // Remove from pending
               RemovePendingTrade(j);
               break;
            }
         }
      }
   }
   
   // Clean up inactive pending trades
   for(int i = pendingTradeCount - 1; i >= 0; i--)
   {
      if(!pendingTrades[i].isActive)
      {
         RemovePendingTrade(i);
         continue;
      }
      
      // Check if order still exists
      bool orderExists = false;
      for(int j = 0; j < OrdersTotal(); j++)
      {
         ulong ticket = OrderGetTicket(j);
         if(ticket == pendingTrades[i].orderTicket)
         {
            orderExists = true;
            break;
         }
      }
      
      if(!orderExists)
      {
         // Order no longer exists - remove from pending
         RemovePendingTrade(i);
      }
   }
}

void RemovePendingTrade(int index)
{
   if(index < 0 || index >= pendingTradeCount)
      return;
   
   // Shift array
   for(int i = index; i < pendingTradeCount - 1; i++)
   {
      pendingTrades[i] = pendingTrades[i + 1];
   }
   
   pendingTradeCount--;
   ArrayResize(pendingTrades, pendingTradeCount);
}

// =====================================================================================================
// MANAGE ACTIVE TRADES
// =====================================================================================================

void ManageActiveTrades()
{
   // Check all open positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;
      
      if(!PositionSelectByTicket(ticket))
         continue;
      
      // Check if this is our position
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      
      string symbol = PositionGetString(POSITION_SYMBOL);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      
      // Position is managed by SL/TP - just track for statistics
      // No micro exits, no tick-scalping
   }
   
   // Check closed positions for statistics
   CheckClosedPositions();
}

void CheckClosedPositions()
{
   // Check history for recently closed positions
   // Use static variable to track last checked deal to avoid duplicates
   static ulong lastCheckedDeal = 0;
   
   datetime currentTime = TimeCurrent();
   datetime checkTime = currentTime - 3600;  // Last hour
   
   if(!HistorySelect(checkTime, currentTime))
      return;
   
   int totalDeals = HistoryDealsTotal();
   
   for(int i = 0; i < totalDeals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0)
         continue;
      
      // Skip if already checked
      if(ticket <= lastCheckedDeal)
         continue;
      
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber)
         continue;
      
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;  // Only check exit deals
      
      // Update last checked
      if(ticket > lastCheckedDeal)
         lastCheckedDeal = ticket;
      
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + 
                      HistoryDealGetDouble(ticket, DEAL_SWAP);
      
      // Update daily trade count
      string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
      bool found = false;
      for(int j = 0; j < symbolCount; j++)
      {
         if(symbolData[j].symbol == symbol)
         {
            symbolData[j].dailyTradeCount++;
            symbolData[j].lastTradeTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
            found = true;
            break;
         }
      }
      
      if(found)
      {
         dailyTotalTrades++;
         
         // Track consecutive losses
         if(profit < 0.0)
         {
            consecutiveLosses++;
            
            if(consecutiveLosses >= MaxConsecutiveLosses)
            {
               tradingStopped = true;
               Print("TRADING STOPPED: ", consecutiveLosses, " consecutive losses reached!");
            }
         }
         else
         {
            consecutiveLosses = 0;  // Reset on win
         }
      }
   }
}

// =====================================================================================================
// DISPLAY
// =====================================================================================================

void UpdateDisplay()
{
   string status = "\n=== MSS + OB + FVG Confluence EA ===\n";
   status += "Symbols: " + IntegerToString(symbolCount) + "\n";
   status += "Timeframe: " + EnumToString(Timeframe) + "\n";
   status += "Fixed Lot: " + DoubleToString(FixedLotSize, 2) + "\n\n";
   
   status += "Daily Trades: " + IntegerToString(dailyTotalTrades);
   status += " / Min: " + IntegerToString(MinDailyTrades);
   status += " / Max: " + IntegerToString(MaxDailyTrades) + "\n";
   
   status += "Consecutive Losses: " + IntegerToString(consecutiveLosses);
   status += " / Max: " + IntegerToString(MaxConsecutiveLosses) + "\n";
   
   if(tradingStopped)
   {
      status += "\nSTATUS: TRADING STOPPED\n";
   }
   else
   {
      status += "\nSTATUS: ACTIVE\n";
   }
   
   status += "\n--- Symbol Status ---\n";
   for(int i = 0; i < symbolCount; i++)
   {
      status += symbolData[i].symbol + ": " + IntegerToString(symbolData[i].dailyTradeCount) + " trades";
      if(symbolData[i].hasActiveLimitOrder)
         status += " [PENDING ORDER]";
      status += "\n";
   }
   
   status += "\n--- Pending Orders ---\n";
   status += "Count: " + IntegerToString(pendingTradeCount) + "\n";
   
   status += "\n--- Open Positions ---\n";
   int openPositions = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            openPositions++;
            string posSymbol = PositionGetString(POSITION_SYMBOL);
            double posProfit = PositionGetDouble(POSITION_PROFIT);
            status += posSymbol + ": $" + DoubleToString(posProfit, 2) + "\n";
         }
      }
   }
   if(openPositions == 0)
      status += "None\n";
   
   Comment(status);
}
