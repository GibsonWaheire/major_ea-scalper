#property copyright "Copyright 2025, Hyper Portfolio Scalper MT5 V6"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "6.10"
#property description "Gold (XAUUSD) Optimized Scalper - Ultra-fast tick-based trading"

#include <Trade\Trade.mqh>

// =====================================================================================================
// HYPER PORTFOLIO SCALPER MT5 V6
// Multi-symbol scalping EA that trades 11 symbols independently
// =====================================================================================================

// ===== INPUT PARAMETERS =====
input group "===== Trading Settings ====="
input int      BaseMagicNumber      = 202506;  // Magic number for Gold trades
input bool     TradeEnabled         = true;    // Enable/disable trading

input group "===== Lot Sizing ====="
enum LOT_MODE_ENUM {
   LOT_FIXED = 0,      // Fixed lot size
   LOT_RISK = 1        // Risk-based lot sizing
};
input LOT_MODE_ENUM LotMode         = LOT_RISK;  // Lot sizing mode
input double   FixedLotSize          = 0.01;      // Fixed lot size (if LotMode = FIXED)
input double   RiskPercent           = 1.0;       // Risk % per trade (if LotMode = RISK)

input group "===== Entry Filters ====="
input double   TrendThreshold        = 0.15;      // Trend bias threshold (points) - Relaxed for Gold
input double   ATRMinMultiplier      = 0.1;       // Minimum ATR multiplier (block dead market) - Relaxed
input double   ATRMaxMultiplier      = 5.0;       // Maximum ATR multiplier (block news spike) - Relaxed
input double   SpreadMultiplier      = 2.0;       // Spread must be <= avgSpread × this - Relaxed
input double   TickRangeMultiplier   = 1.0;       // Last 10 ticks range must be >= spread × this - Relaxed
input int      MinTicksPerSecond     = 2;         // Minimum ticks per second required - Reduced for Gold
input bool     UseSessionFilter      = false;     // Enable London + New York session filter - Disabled by default
input bool     ShowFilterDebug       = true;      // Show which filters are blocking trades

input group "===== Exit Settings ====="
input int      StopLossPoints        = 25;        // Stop loss in points
input int      TakeProfitPoints      = 15;        // Take profit in points
input int      BreakEvenPoints       = 7;         // Move to BE after +X points profit
input int      TrailingStartPoints   = 10;        // Start trailing after +X points profit
input int      TrailingStepPoints    = 2;         // Trailing step in points
input int      MaxHoldSeconds        = 20;        // Force close after X seconds
input bool     CloseOnAnyProfit      = true;      // Close immediately if profit > 0

input group "===== Risk Management ====="
input double   MaxSpreadWidenMultiplier = 2.0;    // Close if spread widens beyond avgSpread × this

// ===== TRADING SYMBOL =====
#define TRADE_SYMBOL "XAUUSD"  // Gold only

// ===== SYMBOL DATA STRUCTURE =====
struct SymbolData {
   string symbol;
   int magicNumber;
   double pointSize;           // Auto-calculated point size (0.01 for Gold)
   int digits;
   
   // Tick buffers for trend filter
   double tickPrices[30];
   ulong tickTimes[30];  // Store millisecond timestamps
   int tickCount;
   int lastTickIndex;
   
   // Spread tracking
   double spreadHistory[100];
   int spreadIndex;
   int spreadCount;  // Number of valid spread entries
   double avgSpread;
   
   // ATR handle
   int atrHandle;
   double lastATR;
   
   // Tick activity tracking (store millisecond timestamps)
   ulong ticksInLastSecond[100];
   int tickActivityIndex;
   
   // Position tracking
   ulong currentTicket;
   double entryPrice;
   datetime openTime;
   ENUM_POSITION_TYPE positionType;
   double highestProfit;
   double lowestProfit;
   bool breakEvenSet;
   bool trailingActive;
   double initialSpread;
   
   // Market data
   double currentBid;
   double currentAsk;
   double currentSpread;
   MqlTick lastTick;
   
   // State flags
   bool initialized;
   bool hasActivePosition;
};

SymbolData g_SymbolData;  // Single symbol data structure
CTrade g_Trade;

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("HYPER PORTFOLIO SCALPER MT5 V6 - GOLD OPTIMIZED");
   Print("Gold (XAUUSD) Ultra-Fast Scalper");
   Print("========================================");
   Print("Trading Symbol: ", TRADE_SYMBOL);
   Print("Lot Mode: ", (LotMode == LOT_FIXED ? "FIXED" : "RISK"));
   Print("========================================");
   
   // Initialize trade object
   g_Trade.SetExpertMagicNumber(BaseMagicNumber);
   g_Trade.SetDeviationInPoints(10);
   g_Trade.SetTypeFilling(ORDER_FILLING_FOK);
   g_Trade.SetAsyncMode(false);
   
   // Initialize Gold symbol
   if(!InitializeSymbol())
   {
      Print("ERROR: Failed to initialize ", TRADE_SYMBOL);
      Print("Please ensure ", TRADE_SYMBOL, " is in Market Watch and market is open.");
      return INIT_FAILED;
   }
   
   Print("========================================");
   Print("Initialization complete: ", TRADE_SYMBOL, " ready for trading");
   Print("========================================");
   return INIT_SUCCEEDED;
}

bool InitializeSymbol()
{
   // Initialize Gold symbol
   g_SymbolData.symbol = TRADE_SYMBOL;
   g_SymbolData.magicNumber = BaseMagicNumber;
   g_SymbolData.initialized = false;
   g_SymbolData.hasActivePosition = false;
   g_SymbolData.tickCount = 0;
   g_SymbolData.lastTickIndex = 0;
   g_SymbolData.spreadIndex = 0;
   g_SymbolData.spreadCount = 0;
   g_SymbolData.tickActivityIndex = 0;
   g_SymbolData.currentTicket = 0;
   g_SymbolData.breakEvenSet = false;
   g_SymbolData.trailingActive = false;
   g_SymbolData.lastATR = 0.0;
   g_SymbolData.avgSpread = 0.0;
   
   // Reset arrays
   ArrayInitialize(g_SymbolData.tickPrices, 0.0);
   ArrayInitialize(g_SymbolData.tickTimes, 0);
   ArrayInitialize(g_SymbolData.spreadHistory, 0.0);
   ArrayInitialize(g_SymbolData.ticksInLastSecond, 0);
   
   // Get symbol properties
   if(!SymbolSelect(g_SymbolData.symbol, true))
   {
      Print("ERROR: Symbol '", g_SymbolData.symbol, "' not found in Market Watch. Please add it to Market Watch.");
      return false;
   }
   
   // Verify symbol is tradeable
   if(!SymbolInfoInteger(g_SymbolData.symbol, SYMBOL_TRADE_MODE))
   {
      Print("ERROR: Symbol '", g_SymbolData.symbol, "' is not tradeable");
      return false;
   }
   
   g_SymbolData.digits = (int)SymbolInfoInteger(g_SymbolData.symbol, SYMBOL_DIGITS);
   
   // Gold point size: 0.01 (fixed for XAUUSD)
   g_SymbolData.pointSize = 0.01;
   
   // Create ATR indicator handle
   g_SymbolData.atrHandle = iATR(g_SymbolData.symbol, PERIOD_M1, 14);
   if(g_SymbolData.atrHandle == INVALID_HANDLE)
   {
      int error = GetLastError();
      Print("ERROR: Failed to create ATR handle for '", g_SymbolData.symbol, "'. Error code: ", error);
      return false;
   }
   
   // Get initial market data
   MqlTick tick;
   if(!SymbolInfoTick(g_SymbolData.symbol, tick))
   {
      int error = GetLastError();
      Print("ERROR: Failed to get tick data for '", g_SymbolData.symbol, "'. Error code: ", error);
      Print("This may happen if the market is closed or symbol is not available.");
      return false;
   }
   
   // Verify tick data is valid
   if(tick.bid <= 0.0 || tick.ask <= 0.0)
   {
      Print("ERROR: Invalid tick data for '", g_SymbolData.symbol, "' (bid=", tick.bid, ", ask=", tick.ask, ")");
      return false;
   }
   
   g_SymbolData.currentBid = tick.bid;
   g_SymbolData.currentAsk = tick.ask;
   g_SymbolData.currentSpread = tick.ask - tick.bid;
   g_SymbolData.lastTick = tick;
   
   // Check for existing position
   CheckExistingPosition();
   
   g_SymbolData.initialized = true;
   Print("Initialized: ", g_SymbolData.symbol, " | Magic: ", g_SymbolData.magicNumber, " | Point: ", g_SymbolData.pointSize);
   
   return true;
}

void CheckExistingPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == g_SymbolData.symbol && 
            PositionGetInteger(POSITION_MAGIC) == g_SymbolData.magicNumber)
         {
            g_SymbolData.currentTicket = ticket;
            g_SymbolData.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            g_SymbolData.openTime = (datetime)PositionGetInteger(POSITION_TIME);
            g_SymbolData.positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            g_SymbolData.hasActivePosition = true;
            g_SymbolData.initialSpread = g_SymbolData.currentSpread;
            
            double currentPrice = (g_SymbolData.positionType == POSITION_TYPE_BUY) ? g_SymbolData.currentBid : g_SymbolData.currentAsk;
            double profit = PositionGetDouble(POSITION_PROFIT);
            g_SymbolData.highestProfit = profit;
            g_SymbolData.lowestProfit = profit;
            
            Print("Found existing position: ", g_SymbolData.symbol, " | Ticket: ", ticket);
            break;
         }
      }
   }
}

void OnDeinit(const int reason)
{
   // Release ATR handle
   if(g_SymbolData.atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_SymbolData.atrHandle);
   }
   
   Print("Hyper Portfolio Scalper MT5 V6 (Gold Optimized) deinitialized. Reason: ", reason);
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

string g_LastStatusMessage = "";

void OnTick()
{
   if(!TradeEnabled)
   {
      Comment("EA Disabled");
      return;
   }
   
   // Skip if not initialized
   if(!g_SymbolData.initialized)
   {
      Comment("Initializing...");
      return;
   }
   
   // Update market data
   if(!UpdateMarketData())
      return;
   
   // Manage existing position
   if(g_SymbolData.hasActivePosition)
   {
      ManagePosition();
      UpdateDisplay("Managing position");
      return;
   }
   
   // Check for new entry signal (only if no active position)
   int direction = GetEntrySignal();
   if(direction != 0)
   {
      OpenPosition(direction);
   }
   else
   {
      // Update display even when no signal
      if(!ShowFilterDebug)
         UpdateDisplay("Waiting for signal...");
   }
}

void UpdateDisplay(string status = "")
{
   // Always show display when debug is enabled, or when there's a status message
   if(!ShowFilterDebug && status == "")
      return;
   
   string display = "\n=== GOLD SCALPER V6 ===\n";
   display += "Symbol: " + g_SymbolData.symbol + "\n";
   display += "Ticks: " + IntegerToString(g_SymbolData.tickCount) + "/30\n";
   display += "Spread: " + DoubleToString(g_SymbolData.currentSpread / g_SymbolData.pointSize, 2) + " pts\n";
   
   if(g_SymbolData.avgSpread > 0.0)
      display += "Avg Spread: " + DoubleToString(g_SymbolData.avgSpread / g_SymbolData.pointSize, 2) + " pts\n";
   
   if(g_SymbolData.lastATR > 0.0)
      display += "ATR: " + DoubleToString(g_SymbolData.lastATR / g_SymbolData.pointSize, 2) + " pts\n";
   else
      display += "ATR: Calculating...\n";
   
   // Show filter status
   display += "\n--- Filter Status ---\n";
   display += "Trend: " + (g_SymbolData.tickCount >= 10 ? "Ready" : "Waiting (" + IntegerToString(g_SymbolData.tickCount) + " ticks)") + "\n";
   display += "ATR: " + (g_SymbolData.lastATR > 0.0 ? "OK" : "Waiting") + "\n";
   display += "Spread: " + DoubleToString(g_SymbolData.currentSpread / g_SymbolData.pointSize, 2) + " pts\n";
   
   if(status != "")
      display += "\n>>> " + status + " <<<\n";
   else if(g_LastStatusMessage != "")
      display += "\n>>> " + g_LastStatusMessage + " <<<\n";
   
   if(g_SymbolData.hasActivePosition)
   {
      display += "\n=== ACTIVE TRADE ===\n";
      if(PositionSelectByTicket(g_SymbolData.currentTicket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         display += "P&L: $" + DoubleToString(profit, 2) + "\n";
      }
   }
   else
   {
      display += "\nNo active position\n";
   }
   
   Comment(display);
   if(status != "")
      g_LastStatusMessage = status;
}

bool UpdateMarketData()
{
   MqlTick tick;
   if(!SymbolInfoTick(g_SymbolData.symbol, tick))
      return false;
   
   // Check if this is a new tick
   if(tick.time == g_SymbolData.lastTick.time && tick.time_msc == g_SymbolData.lastTick.time_msc)
      return true; // Same tick, no update needed
   
   g_SymbolData.currentBid = tick.bid;
   g_SymbolData.currentAsk = tick.ask;
   g_SymbolData.currentSpread = tick.ask - tick.bid;
   g_SymbolData.lastTick = tick;
   
   // Update tick buffer for trend filter
   g_SymbolData.tickPrices[g_SymbolData.lastTickIndex] = tick.bid;
   g_SymbolData.tickTimes[g_SymbolData.lastTickIndex] = tick.time_msc;
   g_SymbolData.lastTickIndex = (g_SymbolData.lastTickIndex + 1) % 30;
   if(g_SymbolData.tickCount < 30)
      g_SymbolData.tickCount++;
   
   // Update spread history
   g_SymbolData.spreadHistory[g_SymbolData.spreadIndex] = g_SymbolData.currentSpread;
   g_SymbolData.spreadIndex = (g_SymbolData.spreadIndex + 1) % 100;
   if(g_SymbolData.spreadCount < 100)
      g_SymbolData.spreadCount++;
   
   // Calculate average spread (circular buffer)
   double sumSpread = 0.0;
   int count = g_SymbolData.spreadCount;
   
   if(count > 0)
   {
      // Iterate through circular buffer
      for(int i = 0; i < count; i++)
      {
         int idx = (g_SymbolData.spreadIndex - 1 - i + 100) % 100;
         if(idx >= 0 && idx < 100)
            sumSpread += g_SymbolData.spreadHistory[idx];
      }
      g_SymbolData.avgSpread = sumSpread / count;
   }
   else
   {
      g_SymbolData.avgSpread = g_SymbolData.currentSpread;
   }
   
   // Update tick activity (last 1 second) - store millisecond timestamp
   g_SymbolData.ticksInLastSecond[g_SymbolData.tickActivityIndex] = tick.time_msc;
   g_SymbolData.tickActivityIndex = (g_SymbolData.tickActivityIndex + 1) % 100;
   
   // Update ATR
   double atrBuffer[1];
   if(CopyBuffer(g_SymbolData.atrHandle, 0, 0, 1, atrBuffer) > 0)
   {
      g_SymbolData.lastATR = atrBuffer[0];
   }
   
   return true;
}

// =====================================================================================================
// ENTRY SIGNAL LOGIC
// =====================================================================================================

int GetEntrySignal()
{
   // A. Micro Trend Filter
   int trendBias = GetTrendBias();
   if(trendBias == 0)
   {
      if(ShowFilterDebug && g_SymbolData.tickCount >= 10)
         UpdateDisplay("Waiting: No clear trend");
      return 0; // Neutral trend
   }
   
   // B. ATR Volatility Filter
   if(!CheckATRFilter())
   {
      if(ShowFilterDebug)
         UpdateDisplay("Blocked: ATR filter");
      return 0;
   }
   
   // C. Spread Filter
   if(!CheckSpreadFilter())
   {
      if(ShowFilterDebug)
         UpdateDisplay("Blocked: Spread filter");
      return 0;
   }
   
   // D. Tick Activity Filter
   if(!CheckTickActivityFilter())
   {
      if(ShowFilterDebug)
         UpdateDisplay("Blocked: Low tick activity");
      return 0;
   }
   
   // E. Session Filter (optional)
   if(UseSessionFilter && !CheckSessionFilter())
   {
      if(ShowFilterDebug)
         UpdateDisplay("Blocked: Outside trading session");
      return 0;
   }
   
   // All filters passed!
   if(ShowFilterDebug)
      UpdateDisplay("Signal: " + (trendBias == 1 ? "BUY" : "SELL"));
   
   return trendBias;
}

int GetTrendBias()
{
   // Reduced requirement for Gold - start with 10 ticks minimum
   if(g_SymbolData.tickCount < 10)
      return 0; // Not enough ticks
   
   double upwardMovement = 0.0;
   double downwardMovement = 0.0;
   
   // Analyze available ticks (use up to 30 if available)
   int ticksToAnalyze = MathMin(g_SymbolData.tickCount, 30);
   for(int i = 0; i < ticksToAnalyze; i++)
   {
      int idx1 = (g_SymbolData.lastTickIndex - 1 - i + 30) % 30;
      int idx2 = (g_SymbolData.lastTickIndex - 1 - (i + 1) + 30) % 30;
      
      if(idx1 < 0 || idx2 < 0 || idx1 >= 30 || idx2 >= 30)
         continue;
      
      double price1 = g_SymbolData.tickPrices[idx1];
      double price2 = g_SymbolData.tickPrices[idx2];
      
      if(price1 > price2)
         upwardMovement += (price1 - price2);
      else if(price1 < price2)
         downwardMovement += (price2 - price1);
   }
   
   // Check thresholds
   double threshold = TrendThreshold * g_SymbolData.pointSize;
   
   if(upwardMovement > threshold && upwardMovement > downwardMovement)
      return 1; // BUY
   else if(downwardMovement > threshold && downwardMovement > upwardMovement)
      return -1; // SELL
   
   return 0; // Neutral
}

bool CheckATRFilter()
{
   // Allow trading even if ATR not ready yet (will be available after a few candles)
   if(g_SymbolData.lastATR <= 0.0)
   {
      // If we have at least some ticks, allow trading (ATR will catch up)
      if(g_SymbolData.tickCount >= 10)
         return true;
      return false;
   }
   
   // Convert ATR to points (normalized)
   double atrInPoints = g_SymbolData.lastATR / g_SymbolData.pointSize;
   
   // For Gold, use absolute ATR thresholds instead of relative
   // Gold ATR on M1 typically ranges from 0.5 to 5.0 points
   double minATR = 0.2;  // Minimum ATR in points (very relaxed)
   double maxATR = 10.0; // Maximum ATR in points (very relaxed)
   
   // Block if ATR too low (dead market)
   if(atrInPoints < minATR)
      return false;
   
   // Block if ATR too high (news spike)
   if(atrInPoints > maxATR)
      return false;
   
   return true;
}

bool CheckSpreadFilter()
{
   // For Gold, use absolute spread limits instead of relative
   // Gold spread typically ranges from 0.10 to 2.0 points
   double maxSpreadPoints = 5.0; // Maximum spread in points (very relaxed)
   
   if(g_SymbolData.currentSpread > maxSpreadPoints * g_SymbolData.pointSize)
      return false;
   
   // If we have average spread data, use it as additional check
   if(g_SymbolData.avgSpread > 0.0 && g_SymbolData.spreadCount >= 10)
   {
      if(g_SymbolData.currentSpread > g_SymbolData.avgSpread * SpreadMultiplier)
         return false;
   }
   
   // Check range of last ticks (very relaxed requirement)
   if(g_SymbolData.tickCount < 3)
      return false;
   
   double minPrice = g_SymbolData.tickPrices[0];
   double maxPrice = g_SymbolData.tickPrices[0];
   
   int ticksToCheck = MathMin(10, g_SymbolData.tickCount);
   for(int i = 0; i < ticksToCheck; i++)
   {
      int idx = (g_SymbolData.lastTickIndex - 1 - i + 30) % 30;
      if(idx >= 0 && idx < 30)
      {
         double price = g_SymbolData.tickPrices[idx];
         if(price < minPrice) minPrice = price;
         if(price > maxPrice) maxPrice = price;
      }
   }
   
   double tickRange = maxPrice - minPrice;
   double requiredRange = g_SymbolData.currentSpread * TickRangeMultiplier;
   
   // Very relaxed: only check if we have many ticks and range is way too small
   if(ticksToCheck >= 10 && tickRange < requiredRange * 0.5)
      return false;
   
   return true;
}

bool CheckTickActivityFilter()
{
   // Relaxed: If we have enough ticks accumulated, allow trading
   // (tick activity filter is less critical for Gold scalping)
   if(g_SymbolData.tickCount >= 10)
      return true; // We have enough historical ticks
   
   ulong currentTimeMs = g_SymbolData.lastTick.time_msc;
   int tickCount = 0;
   
   // Count ticks in last 1 second (1000 milliseconds)
   for(int i = 0; i < 100; i++)
   {
      if(g_SymbolData.ticksInLastSecond[i] == 0)
         break;
      
      // Check if tick is within last 1000 milliseconds
      if(currentTimeMs >= g_SymbolData.ticksInLastSecond[i] && 
         (currentTimeMs - g_SymbolData.ticksInLastSecond[i]) <= 1000)
         tickCount++;
   }
   
   return (tickCount >= MinTicksPerSecond);
}

bool CheckSessionFilter()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   
   // London session: 8:00 - 17:00 GMT
   // New York session: 13:00 - 22:00 GMT
   // Combined: 8:00 - 22:00 GMT
   
   if(hour >= 8 && hour < 22)
      return true;
   
   return false;
}

// =====================================================================================================
// POSITION MANAGEMENT
// =====================================================================================================

void ManagePosition()
{
   // Verify position still exists
   if(!PositionSelectByTicket(g_SymbolData.currentTicket))
   {
      g_SymbolData.hasActivePosition = false;
      g_SymbolData.currentTicket = 0;
      return;
   }
   
   // Check if position was closed externally
   if(PositionGetString(POSITION_SYMBOL) != g_SymbolData.symbol)
   {
      g_SymbolData.hasActivePosition = false;
      g_SymbolData.currentTicket = 0;
      return;
   }
   
   // Update profit tracking
   double currentProfit = PositionGetDouble(POSITION_PROFIT);
   if(currentProfit > g_SymbolData.highestProfit)
      g_SymbolData.highestProfit = currentProfit;
   if(currentProfit < g_SymbolData.lowestProfit)
      g_SymbolData.lowestProfit = currentProfit;
   
   // Check for immediate profit exit
   if(CloseOnAnyProfit && currentProfit > 0.0)
   {
      ClosePosition("Immediate profit exit");
      return;
   }
   
   // Check spread widening protection
   if(g_SymbolData.avgSpread > 0.0 && g_SymbolData.currentSpread > g_SymbolData.avgSpread * MaxSpreadWidenMultiplier)
   {
      ClosePosition("Spread widened beyond safety limit");
      return;
   }
   
   // Check time-based exit
   datetime currentTime = TimeCurrent();
   int holdSeconds = (int)(currentTime - g_SymbolData.openTime);
   if(holdSeconds >= MaxHoldSeconds)
   {
      ClosePosition("Max hold time reached");
      return;
   }
   
   // Apply break-even
   if(!g_SymbolData.breakEvenSet)
   {
      double currentPrice = (g_SymbolData.positionType == POSITION_TYPE_BUY) ? g_SymbolData.currentBid : g_SymbolData.currentAsk;
      double profitInPoints = 0.0;
      
      if(g_SymbolData.positionType == POSITION_TYPE_BUY)
         profitInPoints = (currentPrice - g_SymbolData.entryPrice) / g_SymbolData.pointSize;
      else
         profitInPoints = (g_SymbolData.entryPrice - currentPrice) / g_SymbolData.pointSize;
      
      if(profitInPoints >= BreakEvenPoints)
      {
         ApplyBreakEven();
      }
   }
   
   // Apply trailing stop
   if(g_SymbolData.breakEvenSet)
   {
      double currentPrice = (g_SymbolData.positionType == POSITION_TYPE_BUY) ? g_SymbolData.currentBid : g_SymbolData.currentAsk;
      double profitInPoints = 0.0;
      
      if(g_SymbolData.positionType == POSITION_TYPE_BUY)
         profitInPoints = (currentPrice - g_SymbolData.entryPrice) / g_SymbolData.pointSize;
      else
         profitInPoints = (g_SymbolData.entryPrice - currentPrice) / g_SymbolData.pointSize;
      
      if(profitInPoints >= TrailingStartPoints)
      {
         ApplyTrailingStop();
      }
   }
   
   // Check TP/SL (handled by broker, but verify)
   // Note: In MT5, TP/SL are managed by broker automatically
}

void ApplyBreakEven()
{
   if(g_SymbolData.breakEvenSet)
      return;
   
   if(!PositionSelectByTicket(g_SymbolData.currentTicket))
      return;
   
   double slPrice = g_SymbolData.entryPrice; // Break-even = entry price
   double tpPrice = PositionGetDouble(POSITION_TP);
   
   g_Trade.SetExpertMagicNumber(g_SymbolData.magicNumber);
   if(g_Trade.PositionModify(g_SymbolData.currentTicket, slPrice, tpPrice))
   {
      g_SymbolData.breakEvenSet = true;
      Print("Break-even applied: ", g_SymbolData.symbol, " | Ticket: ", g_SymbolData.currentTicket);
   }
}

void ApplyTrailingStop()
{
   if(!PositionSelectByTicket(g_SymbolData.currentTicket))
      return;
   
   double currentPrice = (g_SymbolData.positionType == POSITION_TYPE_BUY) ? g_SymbolData.currentBid : g_SymbolData.currentAsk;
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double newSL = currentSL;
   
   if(g_SymbolData.positionType == POSITION_TYPE_BUY)
   {
      double trailPrice = currentPrice - (TrailingStepPoints * g_SymbolData.pointSize);
      if((currentSL == 0.0 || trailPrice > currentSL) && trailPrice < currentPrice)
         newSL = trailPrice;
   }
   else // SELL
   {
      double trailPrice = currentPrice + (TrailingStepPoints * g_SymbolData.pointSize);
      if((currentSL == 0.0 || trailPrice < currentSL) && trailPrice > currentPrice)
         newSL = trailPrice;
   }
   
   if(newSL != currentSL)
   {
      g_Trade.SetExpertMagicNumber(g_SymbolData.magicNumber);
      if(g_Trade.PositionModify(g_SymbolData.currentTicket, newSL, currentTP))
      {
         g_SymbolData.trailingActive = true;
         Print("Trailing stop updated: ", g_SymbolData.symbol, " | New SL: ", newSL);
      }
   }
}

void ClosePosition(string reason)
{
   if(!PositionSelectByTicket(g_SymbolData.currentTicket))
   {
      g_SymbolData.hasActivePosition = false;
      g_SymbolData.currentTicket = 0;
      return;
   }
   
   double lots = PositionGetDouble(POSITION_VOLUME);
   g_Trade.SetExpertMagicNumber(g_SymbolData.magicNumber);
   
   if(g_Trade.PositionClose(g_SymbolData.currentTicket))
   {
      double profit = PositionGetDouble(POSITION_PROFIT);
      Print("Position closed: ", g_SymbolData.symbol, " | Reason: ", reason, " | P&L: $", DoubleToString(profit, 2));
      
      g_SymbolData.hasActivePosition = false;
      g_SymbolData.currentTicket = 0;
      g_SymbolData.breakEvenSet = false;
      g_SymbolData.trailingActive = false;
   }
   else
   {
      Print("Failed to close position: ", g_SymbolData.symbol, " | Error: ", GetLastError());
   }
}

// =====================================================================================================
// POSITION OPENING
// =====================================================================================================

void OpenPosition(int direction)
{
   if(g_SymbolData.hasActivePosition)
      return; // Already have a position
   
   // Calculate lot size
   double lotSize = CalculateLotSize();
   if(lotSize <= 0.0)
   {
      Print("ERROR: Invalid lot size for ", g_SymbolData.symbol);
      return;
   }
   
   // Calculate SL/TP prices
   double price = (direction == 1) ? g_SymbolData.currentAsk : g_SymbolData.currentBid;
   double slPrice = 0.0;
   double tpPrice = 0.0;
   
   if(direction == 1) // BUY
   {
      slPrice = price - (StopLossPoints * g_SymbolData.pointSize);
      tpPrice = price + (TakeProfitPoints * g_SymbolData.pointSize);
   }
   else // SELL
   {
      slPrice = price + (StopLossPoints * g_SymbolData.pointSize);
      tpPrice = price - (TakeProfitPoints * g_SymbolData.pointSize);
   }
   
   // Normalize prices
   slPrice = NormalizeDouble(slPrice, g_SymbolData.digits);
   tpPrice = NormalizeDouble(tpPrice, g_SymbolData.digits);
   
   // Open position
   g_Trade.SetExpertMagicNumber(g_SymbolData.magicNumber);
   ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   if(g_Trade.PositionOpen(g_SymbolData.symbol, orderType, lotSize, price, slPrice, tpPrice, "HyperPortfolioV6"))
   {
      g_SymbolData.currentTicket = g_Trade.ResultOrder();
      g_SymbolData.entryPrice = price;
      g_SymbolData.openTime = TimeCurrent();
      g_SymbolData.positionType = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      g_SymbolData.hasActivePosition = true;
      g_SymbolData.breakEvenSet = false;
      g_SymbolData.trailingActive = false;
      g_SymbolData.initialSpread = g_SymbolData.currentSpread;
      g_SymbolData.highestProfit = 0.0;
      g_SymbolData.lowestProfit = 0.0;
      
      Print("Position opened: ", g_SymbolData.symbol, " | ", (direction == 1 ? "BUY" : "SELL"), 
            " | Lot: ", lotSize, " | Price: ", price, " | SL: ", slPrice, " | TP: ", tpPrice);
   }
   else
   {
      Print("Failed to open position: ", g_SymbolData.symbol, " | Error: ", GetLastError(), 
            " | ", g_Trade.ResultRetcodeDescription());
   }
}

double CalculateLotSize()
{
   if(LotMode == LOT_FIXED)
   {
      return NormalizeLotSize(FixedLotSize);
   }
   else // LOT_RISK
   {
      // Risk-based: Lot = (AccountRisk% × Equity) / (SL distance in money)
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskMoney = equity * (RiskPercent / 100.0);
      
      // Calculate SL distance in money per lot
      double slDistance = StopLossPoints * g_SymbolData.pointSize;
      double tickValue = SymbolInfoDouble(g_SymbolData.symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(g_SymbolData.symbol, SYMBOL_TRADE_TICK_SIZE);
      
      if(tickValue <= 0.0 || tickSize <= 0.0)
         return NormalizeLotSize(FixedLotSize); // Fallback
      
      double moneyPerLotAtSL = (tickValue / tickSize) * slDistance;
      if(moneyPerLotAtSL <= 0.0)
         return NormalizeLotSize(FixedLotSize); // Fallback
      
      double lotSize = riskMoney / moneyPerLotAtSL;
      return NormalizeLotSize(lotSize);
   }
}

double NormalizeLotSize(double lots)
{
   double minLot = SymbolInfoDouble(g_SymbolData.symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_SymbolData.symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(g_SymbolData.symbol, SYMBOL_VOLUME_STEP);
   
   if(lotStep <= 0.0)
      lotStep = 0.01;
   
   // Round to lot step
   lots = MathFloor(lots / lotStep) * lotStep;
   
   // Clamp to min/max
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   
   return NormalizeDouble(lots, 2);
}


