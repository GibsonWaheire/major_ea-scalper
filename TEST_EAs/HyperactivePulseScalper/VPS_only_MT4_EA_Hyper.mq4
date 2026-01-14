#property copyright "Copyright 2025, VPS Only MT4 EA Hyper - Clean Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "5.00"
#property strict

// =====================================================================================================
// VPS ONLY MT4 EA HYPER - CLEAN TICK-DRIVEN SCALPER
// Strategy: 4-Filter Entry System + Immediate Profit Exit + Virtual Stop Loss
// - Micro Trend Calculation (20-40 ticks)
// - Tick Speed Filter
// - Spread-to-Range Filter
// - Micro Order Block Zones
// - Immediate exit on profit OR virtual stop loss
// - Fixed lot size
// - One trade at a time
// =====================================================================================================

// ===== Trading Settings =====
input double   FixedLotSize          = 0.05;   // Fixed lot size (0.03 to 0.10)
input int      MagicNumber           = 202503;
input int      VirtualSL_Points     = 10;     // Virtual stop loss in points (8-12 ticks)

// ===== Trend Filter Settings =====
input int      TrendLookbackTicks    = 30;     // Number of ticks for trend calculation (20-40)
input double   UpThreshold           = 0.0001; // Minimum trend value for BUY bias (adjust for symbol)
input double   DownThreshold         = -0.0001; // Maximum trend value for SELL bias (adjust for symbol)

// ===== Tick Speed Filter Settings =====
input int      MinTickSpeed          = 5;      // Minimum ticks per second required (5-10)
input int      TickSpeedWindowMs     = 1000;   // Window in milliseconds to measure tick speed

// ===== Spread-to-Range Filter Settings =====
input int      RangeLookbackTicks    = 10;     // Number of ticks for range calculation
input double   SpreadToRangeRatio    = 0.4;    // Maximum spread/range ratio (0.3-0.5)

// ===== Order Block Settings =====
input int      OrderBlockLookback    = 20;     // Lookback for order block detection
input int      MinRejections         = 3;      // Minimum rejections to form order block (reduced sensitivity)

// ===== Session Filter Settings =====
input bool     UseSessionFilter      = true;   // Only trade London & NY sessions
input int      LondonStartHour       = 8;      // London session start (GMT)
input int      LondonEndHour         = 16;     // London session end (GMT)
input int      NYStartHour           = 13;     // NY session start (GMT)
input int      NYEndHour             = 21;    // NY session end (GMT)

// ===== Slippage Protection =====
input int      MaxSlippage           = 7;      // Maximum slippage in points (7-10 for XAUUSD)

// ===== Time-Based Exit =====
input int      MaxHoldSeconds        = 3;      // Force close after N seconds if still open

// ===== Volatility Filter =====
input bool     UseVolatilityFilter   = true;   // Enable ATR volatility filter
input int      ATR_Period            = 14;     // ATR period (1-minute)
input double   MinATR_Multiplier     = 0.5;    // Minimum ATR multiplier (block if ATR too low)
input double   MaxATR_Multiplier     = 3.0;    // Maximum ATR multiplier (block if ATR too high)

// =====================================================================================================
// STRUCTURES & GLOBALS
// =====================================================================================================

struct TradeInfo {
   int      ticket;
   double   entryPrice;
   datetime openTime;
   int      openTimeSeconds;  // Store open time in seconds for time-based exit
   int      direction;  // 1=BUY, -1=SELL
   double   lotSize;
   double   highestProfitInPoints;  // Track highest profit in points for trailing stop
   bool     trailingStopActive;  // Whether trailing stop is active
};

TradeInfo currentTrade;
bool hasActiveTrade = false;

// Tick buffer for trend calculation
double bidBuffer[50];
double askBuffer[50];
int tickBufferIndex = 0;
int tickCount = 0;
bool buffersInitialized = false;

// Tick speed tracking (using incremented counter per tick)
int tickCounter = 0;
int tickCounterWindow[50];  // Store tick counter values
int tickCounterIndex = 0;
int tickCounterCount = 0;
int lastTickCounter = 0;

// Average spread tracking
double spreadHistory[50];
int spreadHistoryIndex = 0;
int spreadHistoryCount = 0;
double averageSpread = 0.0;

// Order block zones
double bullishZones[10];
double bearishZones[10];
int bullishZoneCount = 0;
int bearishZoneCount = 0;

// Price data
double point = 0.0;
int digits = 0;

// Risk management
double initialBalance = 0.0;
bool tradingStopped = false;

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("VPS ONLY MT4 EA HYPER V5.00");
   Print("CLEAN TICK-DRIVEN SCALPER");
   Print("========================================");
   Print("Fixed Lot Size: ", FixedLotSize);
   Print("Virtual Stop Loss: ", VirtualSL_Points, " points");
   Print("Trend Lookback: ", TrendLookbackTicks, " ticks");
   Print("Min Tick Speed: ", MinTickSpeed, " ticks/second");
   Print("Spread-to-Range Ratio: ", SpreadToRangeRatio);
   Print("========================================");
   
   // Initialize symbol data
   digits = Digits;
   point = Point;
   if(digits == 3 || digits == 5)
      point *= 10.0;
   
   // Initialize trading state
   hasActiveTrade = false;
   currentTrade.ticket = 0;
   
   // Initialize risk management
   initialBalance = AccountBalance();
   tradingStopped = false;
   
   // Initialize buffers
   for(int i = 0; i < 50; i++)
   {
      bidBuffer[i] = 0.0;
      askBuffer[i] = 0.0;
      tickCounterWindow[i] = 0;
      spreadHistory[i] = 0.0;
   }
   
   // Initialize order block zones
   for(int i = 0; i < 10; i++)
   {
      bullishZones[i] = 0.0;
      bearishZones[i] = 0.0;
   }
   
   bullishZoneCount = 0;
   bearishZoneCount = 0;
   
   Print("EA initialized - ready for tick-driven scalping");
   
   // Check AutoTrading
   if(IsTradeAllowed())
   {
      Print("✓ AutoTrading is ENABLED - Ready to trade");
   }
   else
   {
      Print("⚠ AutoTrading is DISABLED - Please enable AutoTrading button in MT4!");
   }
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("VPS Only MT4 EA Hyper V5 deinitialized. Reason: ", reason);
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   // Update risk management
   UpdateRiskManagement();
   
   // Check drawdown - close all trades if 20% drawdown
   if(CheckDrawdown())
   {
      CloseAllTrades("20% Drawdown reached");
   }
   
   // Check profit - stop trading if 40% profit reached
   if(CheckProfitTarget())
   {
      tradingStopped = true;
      return;
   }
   
   // Update tick buffers
   UpdateTickBuffers();
   
   // Manage active trade (exit system)
   if(hasActiveTrade)
   {
      ManageTrade();
   }
   
   // Open new trade if no active trade and trading not stopped
   if(!hasActiveTrade && !tradingStopped)
   {
      int direction = GetEntrySignal();
      
      if(direction != 0)
      {
         if(ShouldOpenTrade(direction))
         {
            OpenTrade(direction);
         }
      }
   }
   
   // Update display
   UpdateDisplay();
}

// =====================================================================================================
// TICK BUFFER MANAGEMENT
// =====================================================================================================

void UpdateTickBuffers()
{
   // Shift bid buffer (ring buffer)
   for(int i = 49; i > 0; i--)
   {
      bidBuffer[i] = bidBuffer[i-1];
   }
   bidBuffer[0] = Bid;
   
   // Shift ask buffer (ring buffer)
   for(int i = 49; i > 0; i--)
   {
      askBuffer[i] = askBuffer[i-1];
   }
   askBuffer[0] = Ask;
   
   // Update tick count
   tickCount++;
   if(tickCount >= 50)
      buffersInitialized = true;
   
   // Update tick counter for speed calculation (incremented counter per tick)
   tickCounter++;
   tickCounterWindow[tickCounterIndex] = tickCounter;
   tickCounterIndex = (tickCounterIndex + 1) % 50;
   if(tickCounterCount < 50)
      tickCounterCount++;
   
   // Update spread history for dynamic spread compensation
   double currentSpread = Ask - Bid;
   spreadHistory[spreadHistoryIndex] = currentSpread;
   spreadHistoryIndex = (spreadHistoryIndex + 1) % 50;
   if(spreadHistoryCount < 50)
      spreadHistoryCount++;
   
   // Calculate average spread
   if(spreadHistoryCount > 0)
   {
      double sum = 0.0;
      for(int i = 0; i < spreadHistoryCount; i++)
      {
         sum += spreadHistory[i];
      }
      averageSpread = sum / spreadHistoryCount;
   }
   
   // Update order block zones periodically
   if(tickCount % 10 == 0)
   {
      UpdateOrderBlocks();
   }
}

// =====================================================================================================
// FILTER A: MICRO TREND CALCULATION
// =====================================================================================================

int GetTrendBias()
{
   if(!buffersInitialized || tickCount < TrendLookbackTicks)
      return 0;  // Not enough data
   
   double trend = 0.0;
   
   // Calculate trend: sum(Bid[i] - Bid[i-1], last N ticks)
   for(int i = 0; i < TrendLookbackTicks && i < tickCount - 1; i++)
   {
      trend += (bidBuffer[i] - bidBuffer[i+1]);
   }
   
   // Determine bias
   if(trend > UpThreshold)
      return 1;  // BUY bias
   else if(trend < DownThreshold)
      return -1;  // SELL bias
   
   return 0;  // No bias
}

// =====================================================================================================
// FILTER B: TICK SPEED FILTER
// =====================================================================================================

bool CheckTickSpeed()
{
   if(tickCounterCount < 2)
      return false;  // Not enough data
   
   // Track actual tick arrival intervals using incremented counter per tick
   // Count ticks in the last window (based on counter difference)
   int ticksInWindow = 0;
   int currentCounter = tickCounter;
   
   // Count how many ticks occurred (counter difference)
   for(int i = 0; i < tickCounterCount; i++)
   {
      int counterDiff = currentCounter - tickCounterWindow[i];
      if(counterDiff >= 0 && counterDiff <= 50)  // Last 50 ticks
      {
         ticksInWindow++;
      }
   }
   
   // Estimate ticks per second (assuming 50 ticks = ~1 second for active market)
   // This is an approximation - adjust based on your symbol's typical tick rate
   double tickSpeed = (double)ticksInWindow * 2.0;  // Rough estimate
   
   return (tickSpeed >= MinTickSpeed);
}

// =====================================================================================================
// FILTER C: SPREAD-TO-RANGE FILTER
// =====================================================================================================

bool CheckSpreadToRange()
{
   if(!buffersInitialized || tickCount < RangeLookbackTicks)
      return false;  // Not enough data
   
   // Calculate range: Highest(Bid, last N ticks) - Lowest(Bid, last N ticks)
   double highest = bidBuffer[0];
   double lowest = bidBuffer[0];
   
   for(int i = 0; i < RangeLookbackTicks && i < tickCount; i++)
   {
      if(bidBuffer[i] > highest)
         highest = bidBuffer[i];
      if(bidBuffer[i] < lowest)
         lowest = bidBuffer[i];
   }
   
   double range = highest - lowest;
   double spread = Ask - Bid;
   
   // Dynamic Spread Compensation: Allow trading only when spread <= average_spread * 1.3
   if(averageSpread > 0.0 && spread > averageSpread * 1.3)
      return false;  // Current spread too high relative to average
   
   // Spread compensation: entry_allowed = (range >= spread * 1.5)
   if(range < spread * 1.5)
      return false;  // Range too small relative to spread
   
   // Also check original condition: spread <= range * SpreadToRangeRatio
   return (range > 0.0 && spread <= range * SpreadToRangeRatio);
}

// =====================================================================================================
// FILTER D: MICRO ORDER BLOCK ZONES
// =====================================================================================================

void UpdateOrderBlocks()
{
   if(!buffersInitialized || tickCount < 30)  // Need at least 30 ticks for rejection detection
      return;
   
   // Reset zone counts
   bullishZoneCount = 0;
   bearishZoneCount = 0;
   
   // Redesigned: Detect price levels where price rejected 2-3 times in last 30 ticks
   // Track rejection zones by detecting bounces at specific price levels
   
   double zoneTolerance = point * 5.0;  // 5 points tolerance for zone detection
   
   // Scan last 30 ticks for rejection patterns
   for(int i = 0; i < 30 && i < tickCount - 1; i++)
   {
      double testPrice = bidBuffer[i];
      int rejectionCount = 0;
      bool isBullishRejection = false;
      bool isBearishRejection = false;
      
      // Check if price was rejected at this level (bounced away)
      for(int j = 0; j < 30 && j < tickCount; j++)
      {
         double priceDiff = MathAbs(bidBuffer[j] - testPrice);
         
         // Check for bullish rejection (price touched low and bounced up)
         if(priceDiff <= zoneTolerance && j < tickCount - 1)
         {
            if(bidBuffer[j] <= testPrice && bidBuffer[j+1] > testPrice)
            {
               rejectionCount++;
               isBullishRejection = true;
            }
         }
         
         // Check for bearish rejection (price touched high and bounced down)
         if(priceDiff <= zoneTolerance && j < tickCount - 1)
         {
            if(bidBuffer[j] >= testPrice && bidBuffer[j+1] < testPrice)
            {
               rejectionCount++;
               isBearishRejection = true;
            }
         }
      }
      
      // Store zone if rejected 2-3 times
      if(rejectionCount >= 2 && rejectionCount <= 3)
      {
         if(isBullishRejection && bullishZoneCount < 10)
         {
            bullishZones[bullishZoneCount] = testPrice;
            bullishZoneCount++;
         }
         
         if(isBearishRejection && bearishZoneCount < 10)
         {
            bearishZones[bearishZoneCount] = testPrice;
            bearishZoneCount++;
         }
      }
   }
}

bool CheckOrderBlockPosition(int direction)
{
   if(bullishZoneCount == 0 && bearishZoneCount == 0)
      return true;  // No zones detected yet, allow trade
   
   // BUY: must be above bullish zones
   if(direction == 1)
   {
      if(bullishZoneCount > 0)
      {
         double highestBullishZone = bullishZones[0];
         for(int i = 1; i < bullishZoneCount; i++)
         {
            if(bullishZones[i] > highestBullishZone)
               highestBullishZone = bullishZones[i];
         }
         return (Bid > highestBullishZone);
      }
      return true;
   }
   
   // SELL: must be below bearish zones
   if(direction == -1)
   {
      if(bearishZoneCount > 0)
      {
         double lowestBearishZone = bearishZones[0];
         for(int i = 1; i < bearishZoneCount; i++)
         {
            if(bearishZones[i] < lowestBearishZone)
               lowestBearishZone = bearishZones[i];
         }
         return (Ask < lowestBearishZone);
      }
      return true;
   }
   
   return false;
}

// =====================================================================================================
// VOLATILITY FILTER (ATR-based)
// =====================================================================================================

bool CheckVolatility()
{
   if(!UseVolatilityFilter)
      return true;  // Volatility filter disabled
   
   // Calculate ATR on 1-minute timeframe
   double atr = iATR(Symbol(), PERIOD_M1, ATR_Period, 0);
   
   if(atr <= 0.0)
      return true;  // ATR not available, allow trade
   
   // Calculate average ATR over last 20 periods
   double sumATR = 0.0;
   int count = 0;
   for(int i = 0; i < 20 && i < Bars; i++)
   {
      double atrValue = iATR(Symbol(), PERIOD_M1, ATR_Period, i);
      if(atrValue > 0.0)
      {
         sumATR += atrValue;
         count++;
      }
   }
   
   if(count == 0)
      return true;  // Not enough ATR data, allow trade
   
   double avgATR = sumATR / count;
   
   // Block trades when ATR is too low or too high
   double minATR = avgATR * MinATR_Multiplier;
   double maxATR = avgATR * MaxATR_Multiplier;
   
   if(atr < minATR)
      return false;  // ATR too low (low volatility)
   
   if(atr > maxATR)
      return false;  // ATR too high (high volatility)
   
   return true;  // ATR within normal levels
}

// =====================================================================================================
// SESSION FILTER (London & NY Only)
// =====================================================================================================

bool IsTradingSession()
{
   if(!UseSessionFilter)
      return true;  // Session filter disabled
   
   int currentHour = Hour();  // GMT hour
   
   // Check London session (8:00 - 16:00 GMT)
   bool inLondonSession = (currentHour >= LondonStartHour && currentHour < LondonEndHour);
   
   // Check NY session (13:00 - 21:00 GMT)
   bool inNYSession = (currentHour >= NYStartHour && currentHour < NYEndHour);
   
   return (inLondonSession || inNYSession);
}

// =====================================================================================================
// ENTRY SIGNAL FUNCTION (ALL FILTERS MUST PASS)
// =====================================================================================================

int GetEntrySignal()
{
   // Session filter check
   if(!IsTradingSession())
      return 0;  // Outside trading sessions
   
   // Need minimum ticks for all filters
   if(!buffersInitialized || tickCount < TrendLookbackTicks)
      return 0;
   
   // Filter A: Get trend bias
   int trendBias = GetTrendBias();
   if(trendBias == 0)
      return 0;  // No trend bias
   
   // Filter B: Check tick speed
   if(!CheckTickSpeed())
      return 0;  // Tick speed too low
   
   // Filter C: Check spread-to-range (includes dynamic spread compensation)
   if(!CheckSpreadToRange())
      return 0;  // Spread too high relative to range or range too small
   
   // Volatility Filter: Check ATR levels
   if(UseVolatilityFilter && !CheckVolatility())
      return 0;  // ATR outside normal levels
   
   // Filter D: Check order block position
   if(!CheckOrderBlockPosition(trendBias))
      return 0;  // Price not positioned correctly relative to order blocks
   
   // All filters passed - return trend bias as entry direction
   return trendBias;
}

// =====================================================================================================
// SHOULD OPEN TRADE FUNCTION (Safety checks)
// =====================================================================================================

bool ShouldOpenTrade(int direction)
{
   // CRITICAL: Ensure only one trade at a time
   if(hasActiveTrade)
      return false;
   
   // Check if trading is stopped
   if(tradingStopped)
      return false;
   
   // Check AutoTrading
   if(!IsTradeAllowed())
      return false;
   
   // Check spread (simple check)
   double currentSpread = Ask - Bid;
   double maxSpread = MarketInfo(Symbol(), MODE_SPREAD) * point;
   if(currentSpread > maxSpread * 2.0)
      return false;  // Spread too high
   
   return true;
}

// =====================================================================================================
// OPEN TRADE FUNCTION
// =====================================================================================================

bool OpenTrade(int direction)
{
   if(direction == 0)
      return false;
   
   // Double-check no active trade
   if(hasActiveTrade)
      return false;
   
   // Calculate lot size
   double tradeLots = FixedLotSize;
   
   // Normalize lot size
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   
   tradeLots = MathFloor(tradeLots / lotStep) * lotStep;
   if(tradeLots < minLot) tradeLots = minLot;
   if(tradeLots > maxLot) tradeLots = maxLot;
   tradeLots = NormalizeDouble(tradeLots, 2);
   
   double price = (direction == 1) ? Ask : Bid;
   double sl = 0.0;  // NO STOP LOSS (using virtual stop)
   double tp = 0.0;  // NO TAKE PROFIT (using immediate profit exit)
   
   string comment = "VPS_Hyper_" + (direction == 1 ? "BUY" : "SELL");
   int orderType = (direction == 1) ? OP_BUY : OP_SELL;
   
   // OrderSend with slippage protection (7-10 for XAUUSD)
   int ticket = OrderSend(Symbol(), orderType, tradeLots, price, MaxSlippage, sl, tp, comment, MagicNumber, 0, 
                          (direction == 1 ? clrGreen : clrRed));
   
   if(ticket > 0)
   {
      if(OrderSelect(ticket, SELECT_BY_TICKET))
      {
         currentTrade.ticket = ticket;
         currentTrade.entryPrice = OrderOpenPrice();
         currentTrade.openTime = OrderOpenTime();
         currentTrade.openTimeSeconds = (int)TimeCurrent();  // Store open time in seconds
         currentTrade.direction = direction;
         currentTrade.lotSize = tradeLots;
         currentTrade.highestProfitInPoints = 0.0;
         currentTrade.trailingStopActive = false;
         hasActiveTrade = true;
         
         Print("TRADE OPENED: ", (direction == 1 ? "BUY" : "SELL"), 
               " | Lot: ", tradeLots, " | Price: ", price);
         return true;
      }
   }
   else
   {
      int error = GetLastError();
      Print("OrderSend FAILED: Error=", error, " | Symbol=", Symbol(), " | Type=", (direction == 1 ? "BUY" : "SELL"),
            " | Lot=", tradeLots, " | Price=", price);
      
      // Handle requotes
      if(error == 10004)
      {
         Print("Requote occurred - will retry on next tick");
      }
   }
   
   return false;
}

// =====================================================================================================
// MANAGE TRADE FUNCTION (Exit System)
// =====================================================================================================

void ManageTrade()
{
   if(!hasActiveTrade || currentTrade.ticket <= 0)
      return;
   
   // Refresh rates for accurate pricing
   RefreshRates();
   
   if(!OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
   {
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      return;
   }
   
   if(OrderCloseTime() > 0)
   {
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      return;
   }
   
   // Calculate current profit
   double currentProfit = OrderProfit() + OrderSwap() + OrderCommission();
   
   // Calculate spread cost
   double spread = Ask - Bid;
   double spreadCost = spread * currentTrade.lotSize * MarketInfo(Symbol(), MODE_TICKVALUE) / MarketInfo(Symbol(), MODE_TICKSIZE);
   double onePointValue = point * currentTrade.lotSize * MarketInfo(Symbol(), MODE_TICKVALUE) / MarketInfo(Symbol(), MODE_TICKSIZE);
   double minProfitThreshold = spreadCost + onePointValue;  // profit >= spread + 1 point
   
   // Calculate current price and profit in points
   double currentPrice = (currentTrade.direction == 1) ? Bid : Ask;
   double priceDiff = currentPrice - currentTrade.entryPrice;
   if(currentTrade.direction == -1)
      priceDiff = -priceDiff;  // For SELL, reverse the difference
   double profitInPoints = priceDiff / point;
   
   // Exit condition 1: Exit immediately when profit >= spread + 1 point
   if(currentProfit >= minProfitThreshold)
   {
      CloseTrade("Profit >= Spread + 1 point");
      return;
   }
   
   // Exit condition 2: Time-based exit - Force close after 3 seconds
   int currentTimeSeconds = (int)TimeCurrent();
   int holdTimeSeconds = currentTimeSeconds - currentTrade.openTimeSeconds;
   if(holdTimeSeconds >= MaxHoldSeconds)
   {
      CloseTrade("3-second timeout");
      return;
   }
   
   // Micro trailing stop: activates after +3 points profit
   if(profitInPoints >= 3.0)
   {
      currentTrade.trailingStopActive = true;
      
      // Update highest profit in points
      if(profitInPoints > currentTrade.highestProfitInPoints)
      {
         currentTrade.highestProfitInPoints = profitInPoints;
      }
      
      // Trailing stop: if profit drops by 2 points from highest, close
      if(profitInPoints < (currentTrade.highestProfitInPoints - 2.0))
      {
         CloseTrade("Micro trailing stop");
         return;
      }
   }
   
   // Exit condition 2: Virtual stop loss (8-12 ticks)
   double lossInPoints = MathAbs(priceDiff / point);
   if(lossInPoints >= VirtualSL_Points)
   {
      CloseTrade("Virtual stop loss");
      return;
   }
}

// =====================================================================================================
// CLOSE TRADE FUNCTION
// =====================================================================================================

void CloseTrade(string reason)
{
   if(!hasActiveTrade || currentTrade.ticket <= 0)
      return;
   
   // Refresh rates immediately before closing
   RefreshRates();
   
   if(!OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
   {
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      return;
   }
   
   if(OrderCloseTime() > 0)
   {
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      return;
   }
   
   bool result = false;
   if(OrderType() == OP_BUY)
      result = OrderClose(currentTrade.ticket, OrderLots(), Bid, 3, clrRed);
   else if(OrderType() == OP_SELL)
      result = OrderClose(currentTrade.ticket, OrderLots(), Ask, 3, clrRed);
   
   if(result)
   {
      double profit = OrderProfit() + OrderSwap() + OrderCommission();
      Print("TRADE CLOSED: ", reason, " | P&L: $", DoubleToString(profit, 2));
      
      hasActiveTrade = false;
      currentTrade.ticket = 0;
   }
   else
   {
      Print("OrderClose failed: ", GetLastError());
   }
}

// =====================================================================================================
// DISPLAY
// =====================================================================================================

void UpdateDisplay()
{
   string display = "\n=== VPS ONLY MT4 EA HYPER V5 ===\n";
   display += "CLEAN TICK-DRIVEN SCALPER\n";
   display += "Fixed Lot Size: " + DoubleToString(FixedLotSize, 2) + "\n";
   display += "Virtual Stop Loss: " + IntegerToString(VirtualSL_Points) + " points\n";
   display += "Exit: Profit >= Spread*1.2 OR virtual stop loss OR trailing stop\n";
   
   // Session status
   if(UseSessionFilter)
   {
      display += "Session: " + (IsTradingSession() ? "ACTIVE (London/NY)" : "CLOSED") + "\n";
   }
   
   // Filter status
   if(buffersInitialized)
   {
      int trendBias = GetTrendBias();
      string trendStr = (trendBias == 1 ? "BULLISH" : (trendBias == -1 ? "BEARISH" : "NEUTRAL"));
      display += "Trend Bias: " + trendStr + "\n";
      display += "Tick Speed: " + DoubleToString(GetTickSpeedValue(), 1) + " ticks/sec\n";
      display += "Spread-to-Range: " + (CheckSpreadToRange() ? "OK" : "BLOCKED") + "\n";
   }
   else
   {
      display += "Buffers: Initializing (" + IntegerToString(tickCount) + "/50 ticks)...\n";
   }
   
   // Risk management status
   if(initialBalance > 0.0)
   {
      double currentEquity = AccountEquity();
      double drawdownPercent = ((initialBalance - currentEquity) / initialBalance) * 100.0;
      double profitPercent = ((currentEquity - initialBalance) / initialBalance) * 100.0;
      
      display += "\n--- Risk Management ---\n";
      display += "Balance: $" + DoubleToString(currentEquity, 2) + " | ";
      if(profitPercent > 0)
         display += "Profit: +" + DoubleToString(profitPercent, 2) + "%\n";
      else if(drawdownPercent > 0)
         display += "Drawdown: -" + DoubleToString(drawdownPercent, 2) + "%\n";
      else
         display += "Flat\n";
      
      if(tradingStopped)
         display += "STATUS: TRADING STOPPED (40% profit reached)\n";
      else if(drawdownPercent >= 20.0)
         display += "STATUS: 20% DRAWDOWN - All trades closed\n";
      else
         display += "STATUS: ACTIVE\n";
   }
   
   if(hasActiveTrade)
   {
      if(OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
      {
         double profit = OrderProfit() + OrderSwap() + OrderCommission();
         double currentPrice = (currentTrade.direction == 1) ? Bid : Ask;
         double priceDiff = currentPrice - currentTrade.entryPrice;
         if(currentTrade.direction == -1)
            priceDiff = -priceDiff;
         double profitInPoints = priceDiff / point;
         
         display += "\nTRADE: " + (currentTrade.direction == 1 ? "BUY" : "SELL") + "\n";
         display += "P&L: $" + DoubleToString(profit, 2) + "\n";
         display += "Points: " + DoubleToString(profitInPoints, 1);
         if(profitInPoints < 0)
            display += " / SL: " + IntegerToString(VirtualSL_Points) + "\n";
         else
            display += " (Profit)\n";
         
         if(currentTrade.trailingStopActive)
            display += "Trailing Stop: ACTIVE\n";
      }
   }
   else
   {
      display += "\nNo active trade\n";
      display += "Waiting for entry signal...\n";
   }
   
   Comment(display);
}

// Helper function for display
double GetTickSpeedValue()
{
   if(tickCounterCount < 2)
      return 0.0;
   
   // Use incremented counter per tick (new system)
   int currentCounter = tickCounter;
   int ticksInWindow = 0;
   
   for(int i = 0; i < tickCounterCount; i++)
   {
      int counterDiff = currentCounter - tickCounterWindow[i];
      if(counterDiff >= 0 && counterDiff <= 50)  // Last 50 ticks
      {
         ticksInWindow++;
      }
   }
   
   // Estimate ticks per second (rough approximation)
   return (double)ticksInWindow * 2.0;
}

// =====================================================================================================
// RISK MANAGEMENT FUNCTIONS
// =====================================================================================================

void UpdateRiskManagement()
{
   double currentEquity = AccountEquity();
   
   if(currentEquity > initialBalance * 1.40)
   {
      tradingStopped = true;
   }
}

bool CheckDrawdown()
{
   if(initialBalance <= 0.0)
      return false;
   
   double currentEquity = AccountEquity();
   double drawdownPercent = ((initialBalance - currentEquity) / initialBalance) * 100.0;
   
   if(drawdownPercent >= 20.0)
   {
      static int lastWarningTime = 0;
      if(TimeCurrent() - lastWarningTime > 5)
      {
         Print("WARNING: 20% Drawdown detected! Drawdown: ", DoubleToString(drawdownPercent, 2), "%");
         lastWarningTime = TimeCurrent();
      }
      return true;
   }
   
   return false;
}

bool CheckProfitTarget()
{
   if(initialBalance <= 0.0)
      return false;
   
   double currentEquity = AccountEquity();
   double profitPercent = ((currentEquity - initialBalance) / initialBalance) * 100.0;
   
   if(profitPercent >= 40.0)
   {
      static int lastWarningTime = 0;
      if(TimeCurrent() - lastWarningTime > 5)
      {
         Print("SUCCESS: 40% Profit target reached! Profit: ", DoubleToString(profitPercent, 2), "% - Trading stopped");
         lastWarningTime = TimeCurrent();
      }
      return true;
   }
   
   return false;
}

void CloseAllTrades(string reason)
{
   Print("Attempting to close all trades: ", reason);
   
   RefreshRates();
   
   int closedCount = 0;
   
   // Close current active trade if any
   if(hasActiveTrade && currentTrade.ticket > 0)
   {
      if(OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
      {
         if(OrderCloseTime() == 0)
         {
            bool result = false;
            if(OrderType() == OP_BUY)
               result = OrderClose(currentTrade.ticket, OrderLots(), Bid, 3, clrRed);
            else if(OrderType() == OP_SELL)
               result = OrderClose(currentTrade.ticket, OrderLots(), Ask, 3, clrRed);
            
            if(result)
            {
               double profit = OrderProfit() + OrderSwap() + OrderCommission();
               Print("Closed active trade: ", reason, " | P&L: $", DoubleToString(profit, 2));
               closedCount++;
            }
         }
      }
      hasActiveTrade = false;
      currentTrade.ticket = 0;
   }
   
   // Close all other trades with this magic number
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            if(OrderCloseTime() == 0)
            {
               RefreshRates();
               
               bool result = false;
               if(OrderType() == OP_BUY)
                  result = OrderClose(OrderTicket(), OrderLots(), Bid, 3, clrRed);
               else if(OrderType() == OP_SELL)
                  result = OrderClose(OrderTicket(), OrderLots(), Ask, 3, clrRed);
               
               if(result)
               {
                  double profit = OrderProfit() + OrderSwap() + OrderCommission();
                  Print("Closed trade #", OrderTicket(), ": ", reason, " | P&L: $", DoubleToString(profit, 2));
                  closedCount++;
               }
            }
         }
      }
   }
   
   Print("CloseAllTrades result: ", closedCount, " closed");
}
