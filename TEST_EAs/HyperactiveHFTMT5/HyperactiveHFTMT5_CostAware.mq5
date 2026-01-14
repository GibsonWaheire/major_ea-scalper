#property copyright "Copyright 2025, Hyperactive HFT MT5 Scalper - Cost Aware"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "2.01"

#include <Trade/Trade.mqh>

CTrade trade;

// =====================================================================================================
// HYPERACTIVE HFT MT5 SCALPER - VELOCITY EXIT VERSION
// Strategy: Ultra-fast momentum breakout scalping with velocity-based profit exit
// - One trade at a time
// - Velocity-based profit exit (tracks profit rate, closes when velocity decays)
// - Loss protection (hard stop loss at 150 pips or user-defined)
// - Momentum breakout entry (unchanged)
// - Fast execution (quick open/close)
// - Dynamic or fixed lot sizing
// - Multi-instrument support
// - VELOCITY EXIT: Tracks profit velocity over time, closes when velocity decays significantly
//   - Only applies to trades with substantial profit (avoids $2 exits)
//   - Only applies after minimum hold time (avoids quick trades)
//   - Never closes at negative - stop loss must be hit first
// =====================================================================================================

// ===== Core Trading Settings =====
input group "===== Core Trading Settings ====="
input int      MagicNumber         = 202510;
input string   TradeSymbol         = "";      // Symbol to trade (empty = current chart symbol)
input bool     UseFixedLot         = true;     // Use fixed lot size (false = dynamic)
input double   FixedLotSize        = 0.1;      // Fixed lot size (if UseFixedLot = true)
input double   DynamicLotBase     = 0.05;     // Base lot for dynamic sizing
input double   DynamicLotMultiplier = 1.2;    // Multiplier for dynamic lot (based on balance)
input double   MaxLotSize          = 1.00;     // Maximum lot size (safety limit)
input double   MinLotSize          = 0.01;     // Minimum lot size (safety limit)

// ===== Entry Settings =====
input group "===== Momentum Breakout Entry ====="
input int      MomentumPeriod      = 18;       // Period for momentum calculation (ticks) - Reduced from 30 for more opportunities
input double   BreakoutThreshold   = 0.00035;  // Minimum price movement for breakout (reduced for more entries)
input int      MinTickSpeed        = 3;        // Minimum ticks per second for entry (reduced from 5)
input bool     UseTickSpeedFilter  = true;     // Enable tick speed filter
input double   StrongBreakoutMultiplier = 1.8; // Enter immediately if breakout >= threshold * multiplier (bypass pullback)

// ===== Exit Settings =====
input group "===== Velocity-Based Profit Exit Settings ====="
input double   MinProfitUSD        = 50.0;     // Minimum profit in USD to enable velocity exit (avoid small profits)
input int      MinHoldSeconds      = 30;       // Minimum seconds to hold before velocity exit (avoid quick trades)
input double   VelocityDecayThreshold = 0.3;   // Velocity decay threshold (0.3 = 30% reduction triggers exit)
input int      VelocityWindowSeconds = 10;      // Time window in seconds to calculate velocity

input group "===== Loss Protection Settings ====="
input double   MaxLossPoints       = 250.0;    // Maximum loss in points (stop loss) - Reduced from 100
input int      MaxLossHoldSeconds  = 100;      // Close losing trade after N seconds
input bool     UseTimeBasedLossExit = true;    // Enable time-based loss exit

// ===== Stop Loss Settings =====
input group "===== Stop Loss Settings ====="
input bool     UseStopLoss         = true;     // Use hard stop loss
input double   StopLossPoints      = 150.0;    // Stop loss in points (if UseStopLoss = true) - Default 150 pips
input bool     UseTrailingStop     = true;     // Use trailing stop loss
input double   TrailingStartPoints = 44.0;     // Start trailing after X points profit
input double   TrailingStepPoints  = 10.0;     // Trailing step in points (tighter for HFT)

// ===== Spread & Slippage =====
input group "===== Spread & Execution ====="
input double   MaxSpreadPoints     = 50.0;     // Maximum spread in points
input int      MaxSlippagePoints   = 10;       // Maximum slippage in points
input int      OrderRetries        = 3;        // Number of order retries

// ===== Cost-Aware Settings =====
input group "===== Cost-Aware Exit Settings ====="
input double   CommissionPerLotPerSide = 3.5;  // Commission per lot per side (USD) - Typical: $3.5 per lot per side
input double   CostBufferPoints = 2.0;         // Additional buffer in points to overcome execution costs (loosened exit)

// ===== Risk Management =====
input group "===== Risk Management ====="
input double   MaxDrawdownPercent  = 30.0;      // Maximum drawdown % (stop trading)
input bool     UseDrawdownProtection = true;    // Enable drawdown protection
input double   DailyProfitTarget   = 0.0;       // Daily profit target (0 = disabled)

// ===== Session Filter =====
input group "===== Session Filter ====="
input bool     UseSessionFilter    = false;     // Enable session filter
input int      SessionStartHour    = 8;         // Session start hour (GMT)
input int      SessionEndHour      = 20;        // Session end hour (GMT)

// ===== Pullback Entry Filter =====
input group "===== Pullback Entry Filter ====="
input bool     UsePullbackFilter  = true;       // Enable micro-pullback filter
input double   PullbackPoints     = 1.5;        // Retrace points after breakout (reduced from 2.5 for faster entries)
input int      PullbackTimeoutSeconds = 6;      // Timeout for pullback wait (reduced from 10 for faster reset)

// ===== Volatility Cycle Filter =====
input group "===== Volatility Cycle Filter ====="
input bool     UseVolatilityCycleFilter = true; // Enable volatility cycle filter
input int      VolatilityCycleSeconds = 2;      // Tick speed must be rising for N seconds (reduced from 4 for more entries)

// ===== Spread Normalized Filter =====
input group "===== Spread Normalized Filter ====="
input bool     UseSpreadNormalizedFilter = true; // Enable spread-normalized filter
input double   SpreadMultiplier = 1.5;           // Block when spread > avg * multiplier

// ===== Liquidity Time Filter =====
input group "===== Liquidity Time Filter ====="
input bool     UseLiquidityTimeFilter = true;   // Enable liquidity time filter
input int      BlockStartHour1 = 22;            // First blocked period start (GMT)
input int      BlockEndHour1 = 2;               // First blocked period end (GMT)
input int      BlockStartHour2 = 0;             // Second blocked period start (0 = disabled)
input int      BlockEndHour2 = 0;               // Second blocked period end

// ===== Dynamic Breakeven =====
input group "===== Dynamic Breakeven ====="
input bool     UseDynamicBreakeven = true;      // Enable dynamic breakeven
input double   BreakevenTriggerPoints = 2.0;    // Move SL when profit > X points
input double   BreakevenOffsetPoints = 2.0;     // Move SL to entry - X points

// ===== Partial Exit =====
input group "===== Partial Exit ====="
input bool     UsePartialExit = true;           // Enable partial exit
input double   PartialExitProfitPoints = 30.0; // Close 50% at X points profit
input double   PartialExitPercent = 50.0;      // Percentage to close (50% = half position)

// =====================================================================================================
// STRUCTURES & GLOBALS
// =====================================================================================================

struct TradeInfo {
   ulong    ticket;
   double   entryPrice;
   datetime openTime;
   int      direction;  // 1=BUY, -1=SELL
   double   lotSize;
   double   highestProfitPoints;  // Track highest profit for trailing
   bool     wasProfitable;  // Track if trade was ever profitable
   bool     breakevenMoved;  // Track if breakeven has been moved
   bool     partialExitDone; // Track if partial exit has been executed
};

// Profit history for velocity calculation
struct ProfitHistory {
   double profitUSD[50];  // Profit in USD at each sample
   datetime sampleTime[50];  // Time of each sample
   int count;  // Number of samples
   int index;  // Current index (ring buffer)
};

TradeInfo currentTrade;
bool hasActiveTrade = false;

// Profit velocity tracking
ProfitHistory profitHistory;

// Tick tracking for momentum
double tickPrices[50];
datetime tickTimes[50];
int tickIndex = 0;
bool tickBufferReady = false;

// Momentum tracking
double lastBid = 0.0;
double lastAsk = 0.0;
int momentumDirection = 0;  // 1=bullish, -1=bearish, 0=neutral
int consecutiveMomentumTicks = 0;

// Tick speed tracking
int tickCountInWindow = 0;
datetime lastTickSpeedCheck = 0;
double ticksPerSecond = 0.0;

// Market data
string tradeSymbol = "";
double point = 0.0;
int symbolDigits = 0;
MqlTick currentTick;
double currentBid = 0.0;
double currentAsk = 0.0;
double currentSpread = 0.0;

// Risk management
double initialBalance = 0.0;
double highestBalance = 0.0;
double dailyProfit = 0.0;
datetime lastDayReset = 0;
bool tradingStopped = false;

// Pullback tracking
double breakoutPeakPrice = 0.0;
bool breakoutDetected = false;
int breakoutDirection = 0;
datetime breakoutTime = 0;

// Volatility cycle tracking
double tickSpeedHistory[10];
datetime tickSpeedHistoryTime[10];
int tickSpeedHistoryIndex = 0;
int tickSpeedHistoryCount = 0;

// Spread history
double spreadHistory[100];
int spreadHistoryIndex = 0;
int spreadHistoryCount = 0;
double averageSpread = 0.0;

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("Hyperactive HFT MT5 Scalper V2.01 - VELOCITY EXIT");
   Print("Ultra-fast momentum breakout scalping with velocity-based profit exit");
   Print("========================================");
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints);
   trade.SetTypeFilling(ORDER_FILLING_FOK);  // Fast execution
   
   // Determine trade symbol
   if(TradeSymbol == "" || TradeSymbol == NULL)
      tradeSymbol = _Symbol;
   else
      tradeSymbol = TradeSymbol;
   
   // Initialize symbol data
   if(!SymbolInfoInteger(tradeSymbol, SYMBOL_SELECT))
   {
      Print("ERROR: Symbol ", tradeSymbol, " not found!");
      return(INIT_FAILED);
   }
   
   symbolDigits = (int)SymbolInfoInteger(tradeSymbol, SYMBOL_DIGITS);
   point = SymbolInfoDouble(tradeSymbol, SYMBOL_POINT);
   if(symbolDigits == 3 || symbolDigits == 5)
      point *= 10.0;
   
   // Initialize trading state
   hasActiveTrade = false;
   currentTrade.ticket = 0;
   
   // Initialize profit history
   profitHistory.count = 0;
   profitHistory.index = 0;
   for(int i = 0; i < 50; i++)
   {
      profitHistory.profitUSD[i] = 0.0;
      profitHistory.sampleTime[i] = 0;
   }
   
   // Initialize risk management
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   highestBalance = initialBalance;
   dailyProfit = 0.0;
   lastDayReset = TimeCurrent();
   tradingStopped = false;
   
   // Initialize arrays
   for(int i = 0; i < 50; i++)
   {
      tickPrices[i] = 0.0;
      tickTimes[i] = 0;
   }
   
   tickIndex = 0;
   tickBufferReady = false;
   lastBid = 0.0;
   lastAsk = 0.0;
   momentumDirection = 0;
   consecutiveMomentumTicks = 0;
   
   // Initialize pullback tracking
   breakoutPeakPrice = 0.0;
   breakoutDetected = false;
   breakoutDirection = 0;
   breakoutTime = 0;
   
   // Initialize volatility cycle tracking
   for(int i = 0; i < 10; i++)
   {
      tickSpeedHistory[i] = 0.0;
      tickSpeedHistoryTime[i] = 0;
   }
   tickSpeedHistoryIndex = 0;
   tickSpeedHistoryCount = 0;
   
   // Initialize spread history
   for(int i = 0; i < 100; i++)
   {
      spreadHistory[i] = 0.0;
   }
   spreadHistoryIndex = 0;
   spreadHistoryCount = 0;
   averageSpread = 0.0;
   
   Print("Trade Symbol: ", tradeSymbol);
   Print("Lot Mode: ", (UseFixedLot ? "FIXED" : "DYNAMIC"));
   Print("Fixed Lot: ", FixedLotSize);
   Print("Max Loss Points: ", MaxLossPoints);
   Print("Max Loss Hold: ", MaxLossHoldSeconds, " seconds");
   Print("Velocity Exit: Min Profit $", MinProfitUSD, " | Min Hold: ", MinHoldSeconds, "s | Decay: ", (VelocityDecayThreshold * 100.0), "%");
   Print("Commission: $", CommissionPerLotPerSide, " per lot per side (round-turn: $", (CommissionPerLotPerSide * 2.0), ")");
   Print("Cost Buffer: ", CostBufferPoints, " points");
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("Hyperactive HFT MT5 Scalper (Velocity Exit) deinitialized. Reason: ", reason);
}

// =====================================================================================================
// COST CALCULATION FUNCTIONS
// =====================================================================================================

// Calculate commission in points for a given lot size
// Commission is per lot per side, so round-turn = 2 * CommissionPerLotPerSide
double CalculateCommissionInPoints(double lotSize)
{
   // Total commission for round-turn (open + close) in account currency (USD)
   double totalCommissionUSD = CommissionPerLotPerSide * 2.0 * lotSize;
   
   // Get symbol properties for conversion
   double tickValue = SymbolInfoDouble(tradeSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(tradeSymbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;
   
   // Calculate how many points equal one tick
   double tickSizeInPoints = tickSize;
   if(point > 0.0)
      tickSizeInPoints = tickSize / point;
   
   // Calculate value of 1 point movement for the given lot size
   // tickValue is the profit/loss for 1 tick movement per lot
   // So: pointValue = tickValue * (point / tickSize) * lotSize
   double pointValue = 0.0;
   if(tickSizeInPoints > 0.0)
      pointValue = tickValue * (1.0 / tickSizeInPoints) * lotSize;
   
   if(pointValue <= 0.0)
      return 0.0;
   
   // Convert commission (USD) to points
   // commissionPoints = totalCommissionUSD / pointValue
   double commissionPoints = totalCommissionUSD / pointValue;
   
   return commissionPoints;
}

// Calculate minimum profit threshold in points (spread + commission + buffer)
double CalculateMinimumProfitThreshold(double lotSize)
{
   // Spread cost (already in points)
   double spreadCost = currentSpread;
   
   // Commission cost (convert to points)
   double commissionCost = CalculateCommissionInPoints(lotSize);
   
   // Total minimum threshold
   double minThreshold = spreadCost + commissionCost + CostBufferPoints;
   
   return minThreshold;
}

// Calculate net profit in points (gross profit - costs)
double CalculateNetProfitPoints(double grossProfitPoints, double lotSize)
{
   double minThreshold = CalculateMinimumProfitThreshold(lotSize);
   double netProfit = grossProfitPoints - minThreshold;
   return netProfit;
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   // Update market data
   if(!UpdateMarketData())
      return;
   
   // Update tick buffers
   UpdateTickBuffers();
   
   // Calculate tick speed
   CalculateTickSpeed();
   
   // Check risk management
   CheckRiskManagement();
   
   if(tradingStopped)
   {
      UpdateDisplay();
      return;
   }
   
   // Manage active trade
   if(hasActiveTrade)
   {
      ManageTrade();
   }
   
   // Look for new entry if no active trade
   if(!hasActiveTrade && !tradingStopped)
   {
      int direction = GetMomentumBreakoutSignal();
      
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
// MARKET DATA & TICK TRACKING
// =====================================================================================================

bool UpdateMarketData()
{
   if(!SymbolInfoTick(tradeSymbol, currentTick))
      return false;
   
   currentBid = currentTick.bid;
   currentAsk = currentTick.ask;
   currentSpread = (currentAsk - currentBid) / point;
   
   return (currentBid > 0.0 && currentAsk > 0.0);
}

void UpdateTickBuffers()
{
   double midPrice = (currentBid + currentAsk) / 2.0;
   datetime now = TimeCurrent();
   
   // Shift tick buffer (ring buffer)
   for(int i = 49; i > 0; i--)
   {
      tickPrices[i] = tickPrices[i-1];
      tickTimes[i] = tickTimes[i-1];
   }
   
   tickPrices[0] = midPrice;
   tickTimes[0] = now;
   
   tickIndex++;
   if(tickIndex >= MomentumPeriod)
      tickBufferReady = true;
   
   // Update momentum direction
   if(lastBid > 0.0 && lastAsk > 0.0)
   {
      if(currentBid > lastBid)
      {
         if(momentumDirection == 1)
            consecutiveMomentumTicks++;
         else
         {
            momentumDirection = 1;
            consecutiveMomentumTicks = 1;
         }
      }
      else if(currentBid < lastBid)
      {
         if(momentumDirection == -1)
            consecutiveMomentumTicks++;
         else
         {
            momentumDirection = -1;
            consecutiveMomentumTicks = 1;
         }
      }
      else
      {
         // Price unchanged, maintain momentum but don't increment
      }
   }
   
   lastBid = currentBid;
   lastAsk = currentAsk;
   
   // Update spread history
   UpdateSpreadHistory();
}

void CalculateTickSpeed()
{
   datetime now = TimeCurrent();
   
   if(lastTickSpeedCheck == 0)
   {
      lastTickSpeedCheck = now;
      tickCountInWindow = 0;
      return;
   }
   
   tickCountInWindow++;
   
   int elapsedSeconds = (int)(now - lastTickSpeedCheck);
   if(elapsedSeconds >= 1)
   {
      ticksPerSecond = (double)tickCountInWindow / (double)elapsedSeconds;
      
      // Store tick speed in history for volatility cycle filter
      if(tickSpeedHistoryCount < 10)
      {
         tickSpeedHistory[tickSpeedHistoryCount] = ticksPerSecond;
         tickSpeedHistoryTime[tickSpeedHistoryCount] = now;
         tickSpeedHistoryCount++;
      }
      else
      {
         // Shift array (ring buffer)
         for(int i = 0; i < 9; i++)
         {
            tickSpeedHistory[i] = tickSpeedHistory[i+1];
            tickSpeedHistoryTime[i] = tickSpeedHistoryTime[i+1];
         }
         tickSpeedHistory[9] = ticksPerSecond;
         tickSpeedHistoryTime[9] = now;
      }
      
      tickCountInWindow = 0;
      lastTickSpeedCheck = now;
   }
}

// =====================================================================================================
// SPREAD HISTORY TRACKING
// =====================================================================================================

void UpdateSpreadHistory()
{
   // Add current spread to history
   spreadHistory[spreadHistoryIndex] = currentSpread;
   spreadHistoryIndex = (spreadHistoryIndex + 1) % 100;
   
   if(spreadHistoryCount < 100)
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
}

// =====================================================================================================
// VOLATILITY CYCLE FILTER
// =====================================================================================================

bool CheckVolatilityCycle()
{
   if(!UseVolatilityCycleFilter)
      return true;  // Filter disabled, allow entry
   
   // In strategy tester, tick speed history might be limited
   // Allow entry if we don't have enough data yet (more lenient)
   if(tickSpeedHistoryCount < 2)
      return true;  // Not enough data yet, allow entry (don't block)
   
   datetime now = TimeCurrent();
   
   // Check if tick speed has been rising for the required duration
   // Look at tick speeds within the VolatilityCycleSeconds window
   int validSamples = 0;
   double previousSpeed = 0.0;
   bool isRising = true;
   bool hasRecentData = false;
   
   for(int i = tickSpeedHistoryCount - 1; i >= 0; i--)
   {
      int ageSeconds = (int)(now - tickSpeedHistoryTime[i]);
      
      if(ageSeconds <= VolatilityCycleSeconds)
      {
         hasRecentData = true;
         if(validSamples > 0)
         {
            // Check if current speed is higher than previous
            if(tickSpeedHistory[i] <= previousSpeed)
            {
               isRising = false;
               break;
            }
         }
         previousSpeed = tickSpeedHistory[i];
         validSamples++;
      }
   }
   
   // If we don't have recent data within the window, allow entry (don't block)
   if(!hasRecentData)
      return true;
   
   // Need at least 2 samples showing rising trend, OR if tick speed is stable/acceptable
   // More lenient: allow if speed is not declining significantly
   if(validSamples >= 2)
   {
      // Check if speed is rising OR at least stable (not declining)
      if(isRising)
         return true;
      
      // Allow if speed is stable (not declining more than 20%)
      if(validSamples >= 2 && tickSpeedHistory[tickSpeedHistoryCount - 1] >= (previousSpeed * 0.8))
         return true;
   }
   
   // If we have some data but not enough for rising trend, be lenient
   if(validSamples >= 1 && ticksPerSecond >= MinTickSpeed)
      return true;
   
   return false;
}

// =====================================================================================================
// LIQUIDITY TIME FILTER
// =====================================================================================================

bool CheckLiquidityTime()
{
   if(!UseLiquidityTimeFilter)
      return true;  // Filter disabled, allow trading
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentHour = dt.hour;
   
   // Check first blocked period (handles wraparound)
   if(BlockStartHour1 != BlockEndHour1)
   {
      bool inBlock1 = false;
      if(BlockStartHour1 < BlockEndHour1)
      {
         // Normal case: 8-20 (8 to 20)
         inBlock1 = (currentHour >= BlockStartHour1 && currentHour < BlockEndHour1);
      }
      else
      {
         // Wraparound case: 22-2 (22 to 2 next day)
         inBlock1 = (currentHour >= BlockStartHour1 || currentHour < BlockEndHour1);
      }
      
      if(inBlock1)
         return false;  // Blocked
   }
   
   // Check second blocked period (if enabled)
   if(BlockStartHour2 != BlockEndHour2 && BlockStartHour2 != 0)
   {
      bool inBlock2 = false;
      if(BlockStartHour2 < BlockEndHour2)
      {
         inBlock2 = (currentHour >= BlockStartHour2 && currentHour < BlockEndHour2);
      }
      else
      {
         inBlock2 = (currentHour >= BlockStartHour2 || currentHour < BlockEndHour2);
      }
      
      if(inBlock2)
         return false;  // Blocked
   }
   
   return true;  // Not blocked, allow trading
}

// =====================================================================================================
// RISK MANAGEMENT
// =====================================================================================================

void CheckRiskManagement()
{
   // Reset daily profit at start of new day
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   MqlDateTime lastDt;
   TimeToStruct(lastDayReset, lastDt);
   
   if(dt.day != lastDt.day || dt.mon != lastDt.mon || dt.year != lastDt.year)
   {
      dailyProfit = 0.0;
      lastDayReset = currentTime;
   }
   
   // Check drawdown
   if(UseDrawdownProtection)
   {
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(currentEquity > highestBalance)
         highestBalance = currentEquity;
      
      double drawdown = ((highestBalance - currentEquity) / highestBalance) * 100.0;
      
      if(drawdown >= MaxDrawdownPercent)
      {
         tradingStopped = true;
         Print("TRADING STOPPED: Drawdown ", DoubleToString(drawdown, 2), "% exceeds limit ", DoubleToString(MaxDrawdownPercent, 1), "%");
         
         // Close any open trade
         if(hasActiveTrade)
         {
            CloseTrade("Drawdown limit reached");
         }
      }
   }
   
   // Check daily profit target
   if(DailyProfitTarget > 0.0)
   {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyProfit = currentBalance - initialBalance;
      
      if(dailyProfit >= DailyProfitTarget)
      {
         tradingStopped = true;
         Print("TRADING STOPPED: Daily profit target reached: $", DoubleToString(dailyProfit, 2));
         
         if(hasActiveTrade)
         {
            CloseTrade("Daily profit target reached");
         }
      }
   }
}

// =====================================================================================================
// ENTRY LOGIC - MOMENTUM BREAKOUT
// =====================================================================================================

int GetMomentumBreakoutSignal()
{
   if(!tickBufferReady || tickIndex < MomentumPeriod)
      return 0;
   
   // Check liquidity time filter first
   if(!CheckLiquidityTime())
      return 0;
   
   // Check session filter
   if(UseSessionFilter)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int currentHour = dt.hour;
      
      if(currentHour < SessionStartHour || currentHour >= SessionEndHour)
         return 0;
   }
   
   // Check tick speed
   if(UseTickSpeedFilter && ticksPerSecond < MinTickSpeed)
      return 0;
   
   // Check volatility cycle filter
   if(!CheckVolatilityCycle())
      return 0;
   
   // Check spread
   if(currentSpread > MaxSpreadPoints)
      return 0;
   
   double midPrice = (currentBid + currentAsk) / 2.0;
   
   // Calculate momentum breakout
   double priceChange = 0.0;
   
   if(tickIndex >= MomentumPeriod)
   {
      // Calculate price change over momentum period
      double oldestPrice = tickPrices[MomentumPeriod - 1];
      double newestPrice = tickPrices[0];
      priceChange = newestPrice - oldestPrice;
      
      // Check for breakout: strong movement in momentum direction
      double breakoutThreshold = BreakoutThreshold;
      
      if(momentumDirection == 1 && priceChange >= breakoutThreshold)
      {
         // Bullish breakout detected
         if(consecutiveMomentumTicks >= 1)  // Reduced from 2 to 1 for more entries
         {
            // Check for strong breakout - enter immediately if momentum is very strong
            double strongBreakoutThreshold = breakoutThreshold * StrongBreakoutMultiplier;
            bool isStrongBreakout = (priceChange >= strongBreakoutThreshold && consecutiveMomentumTicks >= 2);
            
            if(isStrongBreakout)
            {
               // Strong breakout - enter immediately (sniper entry on strong momentum)
               breakoutDetected = false;  // Reset any pending pullback
               return 1;  // BUY immediately
            }
            
            if(UsePullbackFilter)
            {
               // Track breakout peak
               if(!breakoutDetected || breakoutDirection != 1)
               {
                  breakoutDetected = true;
                  breakoutDirection = 1;
                  breakoutPeakPrice = midPrice;
                  breakoutTime = TimeCurrent();
                  return 0;  // Wait for pullback
               }
               else if(breakoutDirection == 1)
               {
                  // Update peak if price goes higher
                  if(midPrice > breakoutPeakPrice)
                  {
                     breakoutPeakPrice = midPrice;
                     breakoutTime = TimeCurrent();
                     
                     // If price continues strongly upward, enter immediately (strong momentum)
                     double continuedMomentum = midPrice - breakoutPeakPrice;
                     if(continuedMomentum >= (breakoutThreshold * 0.5))
                     {
                        breakoutDetected = false;
                        return 1;  // BUY - momentum too strong, don't wait for pullback
                     }
                     
                     return 0;  // Still in breakout, wait for pullback
                  }
                  
                  // Check for pullback: price retraced PullbackPoints from peak
                  double retraceFromPeak = breakoutPeakPrice - midPrice;
                  if(retraceFromPeak >= (PullbackPoints * point))
                  {
                     // Pullback occurred, enter immediately
                     breakoutDetected = false;  // Reset for next breakout
                     return 1;  // BUY
                  }
                  
                  return 0;  // Still waiting for pullback
               }
            }
            else
            {
               // No pullback filter, enter immediately
               return 1;  // BUY
            }
         }
      }
      else if(momentumDirection == -1 && priceChange <= -breakoutThreshold)
      {
         // Bearish breakout detected
         if(consecutiveMomentumTicks >= 1)  // Reduced from 2 to 1 for more entries
         {
            // Check for strong breakout - enter immediately if momentum is very strong
            double strongBreakoutThreshold = breakoutThreshold * StrongBreakoutMultiplier;
            bool isStrongBreakout = (priceChange <= -strongBreakoutThreshold && consecutiveMomentumTicks >= 2);
            
            if(isStrongBreakout)
            {
               // Strong breakout - enter immediately (sniper entry on strong momentum)
               breakoutDetected = false;  // Reset any pending pullback
               return -1;  // SELL immediately
            }
            
            if(UsePullbackFilter)
            {
               // Track breakout peak (lowest point for SELL)
               if(!breakoutDetected || breakoutDirection != -1)
               {
                  breakoutDetected = true;
                  breakoutDirection = -1;
                  breakoutPeakPrice = midPrice;
                  breakoutTime = TimeCurrent();
                  return 0;  // Wait for pullback
               }
               else if(breakoutDirection == -1)
               {
                  // Update peak (lowest point) if price goes lower
                  if(midPrice < breakoutPeakPrice)
                  {
                     breakoutPeakPrice = midPrice;
                     breakoutTime = TimeCurrent();
                     
                     // If price continues strongly downward, enter immediately (strong momentum)
                     double continuedMomentum = breakoutPeakPrice - midPrice;
                     if(continuedMomentum >= (breakoutThreshold * 0.5))
                     {
                        breakoutDetected = false;
                        return -1;  // SELL - momentum too strong, don't wait for pullback
                     }
                     
                     return 0;  // Still in breakout, wait for pullback
                  }
                  
                  // Check for pullback: price retraced PullbackPoints from peak (lowest point)
                  double retraceFromPeak = midPrice - breakoutPeakPrice;
                  if(retraceFromPeak >= (PullbackPoints * point))
                  {
                     // Pullback occurred, enter immediately
                     breakoutDetected = false;  // Reset for next breakout
                     return -1;  // SELL
                  }
                  
                  return 0;  // Still waiting for pullback
               }
            }
            else
            {
               // No pullback filter, enter immediately
               return -1;  // SELL
            }
         }
      }
   }
   
   // Reset breakout if too much time has passed (timeout) - shorter timeout for faster reset
   if(breakoutDetected && (TimeCurrent() - breakoutTime) > PullbackTimeoutSeconds)
   {
      breakoutDetected = false;
      breakoutPeakPrice = 0.0;
      breakoutDirection = 0;
   }
   
   return 0;
}

bool ShouldOpenTrade(int direction)
{
   // Ensure only one trade at a time
   if(hasActiveTrade)
      return false;
   
   // Check if trading is stopped
   if(tradingStopped)
      return false;
   
   // Check spread
   if(currentSpread > MaxSpreadPoints)
      return false;
   
   // Check spread-normalized filter
   if(UseSpreadNormalizedFilter && averageSpread > 0.0)
   {
      if(currentSpread > (averageSpread * SpreadMultiplier))
         return false;  // Spread too high relative to average
   }
   
   // Check tick speed
   if(UseTickSpeedFilter && ticksPerSecond < MinTickSpeed)
      return false;
   
   return true;
}

// =====================================================================================================
// LOT SIZING
// =====================================================================================================

double CalculateLotSize()
{
   double lotSize = 0.0;
   
   if(UseFixedLot)
   {
      lotSize = FixedLotSize;
   }
   else
   {
      // Dynamic lot sizing based on account balance
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      lotSize = DynamicLotBase * (balance / 1000.0) * DynamicLotMultiplier;
   }
   
   // Normalize lot size
   double lotStep = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MAX);
   
   // Apply safety limits
   lotSize = MathMax(MinLotSize, MathMin(MaxLotSize, lotSize));
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   
   // Round to lot step
   if(lotStep > 0.0)
      lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   return NormalizeDouble(lotSize, 2);
}

// =====================================================================================================
// OPEN TRADE
// =====================================================================================================

bool OpenTrade(int direction)
{
   if(direction == 0)
      return false;
   
   if(hasActiveTrade)
      return false;
   
   double lotSize = CalculateLotSize();
   double price = (direction == 1) ? currentAsk : currentBid;
   
   // Calculate stop loss (always use hard stop loss for velocity exit)
   double sl = 0.0;
   if(UseStopLoss)
   {
      if(direction == 1)  // BUY
         sl = price - (StopLossPoints * point);
      else  // SELL
         sl = price + (StopLossPoints * point);
      
      sl = NormalizeDouble(sl, symbolDigits);
   }
   else
   {
      // Force stop loss even if UseStopLoss is false (for velocity exit safety)
      if(direction == 1)  // BUY
         sl = price - (StopLossPoints * point);
      else  // SELL
         sl = price + (StopLossPoints * point);
      
      sl = NormalizeDouble(sl, symbolDigits);
   }
   
   // No take profit (using dynamic exit)
   double tp = 0.0;
   
   string comment = "HyperHFT_CA_" + (direction == 1 ? "BUY" : "SELL");
   
   ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   bool sent = false;
   int retries = 0;
   
   while(retries < OrderRetries && !sent)
   {
      if(orderType == ORDER_TYPE_BUY)
         sent = trade.Buy(lotSize, tradeSymbol, 0.0, sl, tp, comment);
      else
         sent = trade.Sell(lotSize, tradeSymbol, 0.0, sl, tp, comment);
      
      if(!sent)
      {
         retries++;
         if(retries < OrderRetries)
         {
            Sleep(50);  // Small delay before retry
            // Update market data before retry
            SymbolInfoTick(tradeSymbol, currentTick);
            currentBid = currentTick.bid;
            currentAsk = currentTick.ask;
            price = (direction == 1) ? currentAsk : currentBid;
         }
      }
   }
   
   if(sent)
   {
      // Get position ticket
      ulong ticket = 0;
      if(trade.ResultDeal() > 0)
      {
         if(HistoryDealSelect(trade.ResultDeal()))
         {
            ticket = HistoryDealGetInteger(trade.ResultDeal(), DEAL_POSITION_ID);
         }
      }
      
      // If still no ticket, find position by symbol and magic
      if(ticket == 0)
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong posTicket = PositionGetTicket(i);
            if(posTicket > 0 && PositionSelectByTicket(posTicket))
            {
               if(PositionGetString(POSITION_SYMBOL) == tradeSymbol && 
                  PositionGetInteger(POSITION_MAGIC) == MagicNumber)
               {
                  ticket = posTicket;
                  break;
               }
            }
         }
      }
      
      if(ticket > 0)
      {
         double actualEntryPrice = price;
         if(PositionSelectByTicket(ticket))
         {
            actualEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         }
         
         currentTrade.ticket = ticket;
         currentTrade.entryPrice = actualEntryPrice;
         currentTrade.openTime = TimeCurrent();
         currentTrade.direction = direction;
         currentTrade.lotSize = lotSize;
         currentTrade.highestProfitPoints = 0.0;
         currentTrade.wasProfitable = false;
         currentTrade.breakevenMoved = false;
         currentTrade.partialExitDone = false;
         hasActiveTrade = true;
         
         // Reset profit history for new trade
         profitHistory.count = 0;
         profitHistory.index = 0;
         for(int i = 0; i < 50; i++)
         {
            profitHistory.profitUSD[i] = 0.0;
            profitHistory.sampleTime[i] = 0;
         }
         
         // Reset breakout tracking when trade opens
         breakoutDetected = false;
         breakoutPeakPrice = 0.0;
         breakoutDirection = 0;
         breakoutTime = 0;
         
         Print("TRADE OPENED: ", (direction == 1 ? "BUY" : "SELL"), 
               " | Lot: ", lotSize, " | Price: ", actualEntryPrice, " | SL: ", sl);
         return true;
      }
   }
   else
   {
      Print("Trade open failed: ", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
   }
   
   return false;
}

// =====================================================================================================
// VELOCITY CALCULATION FUNCTIONS
// =====================================================================================================

// Update profit history for velocity calculation
void UpdateProfitHistory(double currentProfitUSD)
{
   datetime now = TimeCurrent();
   
   // Add new sample
   profitHistory.profitUSD[profitHistory.index] = currentProfitUSD;
   profitHistory.sampleTime[profitHistory.index] = now;
   
   profitHistory.index = (profitHistory.index + 1) % 50;
   if(profitHistory.count < 50)
      profitHistory.count++;
}

// Calculate profit velocity (USD per second) over the velocity window
double CalculateProfitVelocity()
{
   if(profitHistory.count < 2)
      return 0.0;
   
   datetime now = TimeCurrent();
   double oldestProfit = 0.0;
   datetime oldestTime = 0;
   double newestProfit = 0.0;
   datetime newestTime = 0;
   bool foundOldest = false;
   bool foundNewest = false;
   
   // Find oldest and newest samples within the velocity window
   for(int i = 0; i < profitHistory.count; i++)
   {
      int idx = (profitHistory.index - profitHistory.count + i + 50) % 50;
      datetime sampleTime = profitHistory.sampleTime[idx];
      int ageSeconds = (int)(now - sampleTime);
      
      if(ageSeconds <= VelocityWindowSeconds)
      {
         if(!foundOldest || sampleTime < oldestTime)
         {
            oldestProfit = profitHistory.profitUSD[idx];
            oldestTime = sampleTime;
            foundOldest = true;
         }
         
         if(!foundNewest || sampleTime > newestTime)
         {
            newestProfit = profitHistory.profitUSD[idx];
            newestTime = sampleTime;
            foundNewest = true;
         }
      }
   }
   
   if(!foundOldest || !foundNewest || oldestTime == newestTime)
      return 0.0;
   
   // Calculate velocity: change in profit / change in time
   double profitChange = newestProfit - oldestProfit;
   int timeDiff = (int)(newestTime - oldestTime);
   
   if(timeDiff <= 0)
      return 0.0;
   
   double velocity = profitChange / (double)timeDiff;  // USD per second
   
   return velocity;
}

// Get peak velocity from history
double GetPeakVelocity()
{
   if(profitHistory.count < 2)
      return 0.0;
   
   datetime now = TimeCurrent();
   double peakVelocity = 0.0;
   bool foundAny = false;
   
   // Calculate velocity for each pair of consecutive samples within window
   for(int i = 1; i < profitHistory.count; i++)
   {
      int idx1 = (profitHistory.index - profitHistory.count + i - 1 + 50) % 50;
      int idx2 = (profitHistory.index - profitHistory.count + i + 50) % 50;
      
      datetime time1 = profitHistory.sampleTime[idx1];
      datetime time2 = profitHistory.sampleTime[idx2];
      
      int age1 = (int)(now - time1);
      int age2 = (int)(now - time2);
      
      // Only consider samples within velocity window
      if(age1 <= VelocityWindowSeconds && age2 <= VelocityWindowSeconds)
      {
         double profit1 = profitHistory.profitUSD[idx1];
         double profit2 = profitHistory.profitUSD[idx2];
         int timeDiff = (int)(time2 - time1);
         
         if(timeDiff > 0)
         {
            double velocity = (profit2 - profit1) / (double)timeDiff;
            if(!foundAny || velocity > peakVelocity)
            {
               peakVelocity = velocity;
               foundAny = true;
            }
         }
      }
   }
   
   return peakVelocity;
}

// Check if velocity has decayed significantly
bool HasVelocityDecayed()
{
   double currentVelocity = CalculateProfitVelocity();
   double peakVelocity = GetPeakVelocity();
   
   // Need at least some history
   if(profitHistory.count < 3)
      return false;
   
   // If we never had positive velocity, don't exit
   if(peakVelocity <= 0.0)
      return false;
   
   // If current velocity is still positive and strong, don't exit
   if(currentVelocity > 0.0 && currentVelocity >= (peakVelocity * (1.0 - VelocityDecayThreshold)))
      return false;
   
   // Velocity has decayed if:
   // 1. Current velocity is negative (profit decreasing), OR
   // 2. Current velocity is significantly lower than peak (decayed by threshold)
   if(currentVelocity < 0.0 || currentVelocity < (peakVelocity * (1.0 - VelocityDecayThreshold)))
   {
      return true;
   }
   
   return false;
}

// =====================================================================================================
// MANAGE TRADE (EXIT LOGIC) - VELOCITY-BASED
// =====================================================================================================

void ManageTrade()
{
   if(!hasActiveTrade || currentTrade.ticket == 0)
      return;
   
   if(!PositionSelectByTicket(currentTrade.ticket))
   {
      // Position closed externally
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      return;
   }
   
   // Get current position data
   double positionProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   int holdSeconds = (int)(TimeCurrent() - openTime);
   
   // Get current lot size (may have changed after partial exit)
   double currentLots = PositionGetDouble(POSITION_VOLUME);
   
   // Calculate profit/loss in points
   double currentPrice = (currentTrade.direction == 1) ? currentBid : currentAsk;
   double priceDiff = currentPrice - currentTrade.entryPrice;
   if(currentTrade.direction == -1)
      priceDiff = -priceDiff;  // For SELL, reverse the difference
   
   double grossProfitPoints = priceDiff / point;
   double lossPoints = (grossProfitPoints < 0) ? MathAbs(grossProfitPoints) : 0.0;
   
   // Calculate minimum profit threshold (spread + commission + buffer)
   double minProfitThreshold = CalculateMinimumProfitThreshold(currentLots);
   
   // Calculate net profit (gross - costs)
   double netProfitPoints = CalculateNetProfitPoints(grossProfitPoints, currentLots);
   
   // Update highest profit tracking (use gross for tracking, but check net for exits)
   if(grossProfitPoints > currentTrade.highestProfitPoints)
   {
      currentTrade.highestProfitPoints = grossProfitPoints;
      if(grossProfitPoints > 0.0)
         currentTrade.wasProfitable = true;
   }
   
   // Update profit history for velocity calculation (only for profitable trades)
   if(positionProfit > 0.0)
   {
      UpdateProfitHistory(positionProfit);
   }
   
   // =====================================================================
   // EXIT CONDITION 1: Hard stop loss - CRITICAL
   // Cannot close at negative - must hit stop loss
   // Priority: Use StopLossPoints if enabled, otherwise MaxLossPoints
   // =====================================================================
   double effectiveStopLoss = UseStopLoss ? StopLossPoints : MaxLossPoints;
   if(lossPoints >= effectiveStopLoss)
   {
      CloseTrade("Stop loss hit (" + DoubleToString(lossPoints, 1) + " pts)");
      return;
   }
   
   // =====================================================================
   // EXIT CONDITION 2: Time-based loss exit
   // Only close if still losing after timeout
   // =====================================================================
   if(UseTimeBasedLossExit && positionProfit < 0.0 && holdSeconds >= MaxLossHoldSeconds)
   {
      CloseTrade("Loss timeout (" + IntegerToString(holdSeconds) + " seconds)");
      return;
   }
   
   // =====================================================================
   // EXIT CONDITION 3: VELOCITY-BASED PROFIT EXIT
   // Only applies to profitable trades that meet minimum criteria
   // NEVER closes at negative - stop loss must be hit first
   // =====================================================================
   if(positionProfit > 0.0)
   {
      // Only apply velocity exit if:
      // 1. Profit exceeds minimum threshold (avoid small profits like $2)
      // 2. Trade has been held for minimum time (avoid quick trades)
      if(positionProfit >= MinProfitUSD && holdSeconds >= MinHoldSeconds)
      {
         // Check if velocity has decayed
         if(HasVelocityDecayed())
         {
            // Double-check we're still profitable (safety check)
            if(positionProfit > 0.0)
            {
               CloseTrade("Velocity decay detected (Profit: $" + DoubleToString(positionProfit, 2) + 
                         " | Hold: " + IntegerToString(holdSeconds) + "s)");
               return;
            }
         }
      }
   }
   
   // =====================================================================
   // EXIT CONDITION 4: Dynamic Breakeven
   // =====================================================================
   if(UseDynamicBreakeven && !currentTrade.breakevenMoved)
   {
      // Loosen trigger: require profit to cover costs before moving to breakeven
      double breakevenTrigger = BreakevenTriggerPoints + (minProfitThreshold * 0.5);  // Add 50% of cost threshold
      if(grossProfitPoints >= breakevenTrigger)
      {
         MoveToBreakeven();
      }
   }
   
   // =====================================================================
   // EXIT CONDITION 5: Partial Exit
   // =====================================================================
   if(UsePartialExit && !currentTrade.partialExitDone)
   {
      // Loosen partial exit threshold: add cost buffer
      double partialExitThreshold = PartialExitProfitPoints + (minProfitThreshold * 0.5);  // Add 50% of cost threshold
      
      if(grossProfitPoints >= partialExitThreshold)
      {
         // Only execute partial exit if net profit is positive
         if(netProfitPoints > 0.0)
         {
            ExecutePartialExit();
         }
      }
   }
   
   // =====================================================================
   // EXIT CONDITION 6: Trailing stop
   // Only trigger if net profit after costs is positive
   // =====================================================================
   if(UseTrailingStop && currentTrade.highestProfitPoints >= TrailingStartPoints)
   {
      // Use tighter trailing after partial exit
      double trailingStep = currentTrade.partialExitDone ? (TrailingStepPoints * 0.5) : TrailingStepPoints;
      double trailingStopLevel = currentTrade.highestProfitPoints - trailingStep;
      
      // Only close if trailing stop is hit AND net profit is still positive
      if(grossProfitPoints < trailingStopLevel)
      {
         // Check if we still have net profit after costs
         if(netProfitPoints > 0.0)
         {
            CloseTrade("Trailing stop hit (Net: " + DoubleToString(netProfitPoints, 1) + " pts after costs)");
            return;
         }
         // Otherwise, let it continue (costs haven't been covered yet)
      }
   }
}

// =====================================================================================================
// MOVE TO BREAKEVEN
// =====================================================================================================

void MoveToBreakeven()
{
   if(!hasActiveTrade || currentTrade.ticket == 0)
      return;
   
   if(!PositionSelectByTicket(currentTrade.ticket))
      return;
   
   double newSL = 0.0;
   
   if(currentTrade.direction == 1)  // BUY
   {
      newSL = currentTrade.entryPrice - (BreakevenOffsetPoints * point);
   }
   else  // SELL
   {
      newSL = currentTrade.entryPrice + (BreakevenOffsetPoints * point);
   }
   
   newSL = NormalizeDouble(newSL, symbolDigits);
   
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   
   // Only modify if new SL is better than current (closer to entry for profit protection)
   bool shouldModify = false;
   if(currentTrade.direction == 1)  // BUY
   {
      shouldModify = (currentSL == 0.0 || newSL > currentSL);
   }
   else  // SELL
   {
      shouldModify = (currentSL == 0.0 || newSL < currentSL);
   }
   
   if(shouldModify)
   {
      if(trade.PositionModify(currentTrade.ticket, newSL, currentTP))
      {
         currentTrade.breakevenMoved = true;
         Print("Breakeven moved: SL set to ", DoubleToString(newSL, symbolDigits), " (entry - ", BreakevenOffsetPoints, " points)");
      }
   }
}

// =====================================================================================================
// EXECUTE PARTIAL EXIT
// =====================================================================================================

void ExecutePartialExit()
{
   if(!hasActiveTrade || currentTrade.ticket == 0)
      return;
   
   if(!PositionSelectByTicket(currentTrade.ticket))
      return;
   
   double currentLots = PositionGetDouble(POSITION_VOLUME);
   double partialLots = currentLots * (PartialExitPercent / 100.0);
   
   // Normalize partial lots
   double lotStep = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0.0)
      partialLots = MathFloor(partialLots / lotStep) * lotStep;
   
   // Ensure partial lots is at least minimum lot
   double minLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MIN);
   if(partialLots < minLot)
      partialLots = minLot;
   
   // Ensure we don't close more than available
   if(partialLots >= currentLots)
      partialLots = currentLots * 0.5;  // Default to 50% if calculation is off
   
   partialLots = NormalizeDouble(partialLots, 2);
   
   // Close partial position
   if(trade.PositionClosePartial(currentTrade.ticket, partialLots))
   {
      currentTrade.partialExitDone = true;
      currentTrade.lotSize = currentLots - partialLots;  // Update remaining lot size
      Print("Partial exit executed: Closed ", DoubleToString(partialLots, 2), " lots (", DoubleToString(PartialExitPercent, 1), "%)");
   }
   else
   {
      Print("Partial exit failed: ", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
   }
}

// =====================================================================================================
// CLOSE TRADE
// =====================================================================================================

void CloseTrade(string reason)
{
   if(!hasActiveTrade || currentTrade.ticket == 0)
      return;
   
   if(!PositionSelectByTicket(currentTrade.ticket))
   {
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      return;
   }
   
   double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   
   bool closed = trade.PositionClose(currentTrade.ticket);
   
   if(closed)
   {
      Print("TRADE CLOSED: ", reason, " | P&L: $", DoubleToString(profit, 2));
      
      // Update daily profit
      dailyProfit += profit;
      
      hasActiveTrade = false;
      currentTrade.ticket = 0;
   }
   else
   {
      Print("Close failed: ", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
   }
}

// =====================================================================================================
// DISPLAY
// =====================================================================================================

void UpdateDisplay()
{
   string status = "\n=== Hyperactive HFT MT5 Scalper V2.01 - VELOCITY EXIT ===\n";
   status += "Symbol: " + tradeSymbol + "\n";
   status += "Lot Mode: " + (UseFixedLot ? "FIXED" : "DYNAMIC") + "\n";
   if(UseFixedLot)
      status += "Lot Size: " + DoubleToString(FixedLotSize, 2) + "\n";
   else
      status += "Dynamic Lot: " + DoubleToString(CalculateLotSize(), 2) + "\n";
   
   status += "Tick Speed: " + DoubleToString(ticksPerSecond, 2) + " ticks/sec";
   if(UseTickSpeedFilter && ticksPerSecond < MinTickSpeed)
      status += " [LOW]";
   status += "\n";
   
   status += "Spread: " + DoubleToString(currentSpread, 1) + " points";
   if(currentSpread > MaxSpreadPoints)
      status += " [HIGH]";
   if(UseSpreadNormalizedFilter && averageSpread > 0.0)
   {
      status += " (Avg: " + DoubleToString(averageSpread, 1);
      if(currentSpread > (averageSpread * SpreadMultiplier))
         status += " [SPIKE]";
      status += ")";
   }
   status += "\n";
   
   status += "Momentum: " + (momentumDirection == 1 ? "BULLISH" : (momentumDirection == -1 ? "BEARISH" : "NEUTRAL"));
   status += " (" + IntegerToString(consecutiveMomentumTicks) + " ticks)\n";
   
   // Show filter statuses
   if(UsePullbackFilter && breakoutDetected)
   {
      status += "Breakout: " + (breakoutDirection == 1 ? "BULLISH" : "BEARISH");
      status += " | Peak: " + DoubleToString(breakoutPeakPrice, symbolDigits);
      status += " | Waiting for pullback...\n";
   }
   
   if(UseVolatilityCycleFilter)
   {
      status += "Volatility Cycle: " + (CheckVolatilityCycle() ? "RISING" : "NOT RISING") + "\n";
   }
   
   if(UseLiquidityTimeFilter)
   {
      status += "Liquidity Time: " + (CheckLiquidityTime() ? "ALLOWED" : "BLOCKED") + "\n";
   }
   
   if(tradingStopped)
   {
      status += "\nSTATUS: TRADING STOPPED\n";
      if(UseDrawdownProtection)
      {
         double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         double drawdown = ((highestBalance - currentEquity) / highestBalance) * 100.0;
         status += "Drawdown: " + DoubleToString(drawdown, 2) + "%\n";
      }
   }
   else
   {
      status += "STATUS: ACTIVE\n";
   }
   
   if(hasActiveTrade)
   {
      if(PositionSelectByTicket(currentTrade.ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         int holdSeconds = (int)(TimeCurrent() - openTime);
         
         double currentPrice = (currentTrade.direction == 1) ? currentBid : currentAsk;
         double priceDiff = currentPrice - currentTrade.entryPrice;
         if(currentTrade.direction == -1)
            priceDiff = -priceDiff;
         double grossProfitPoints = priceDiff / point;
         
         double currentLots = PositionGetDouble(POSITION_VOLUME);
         double minProfitThreshold = CalculateMinimumProfitThreshold(currentLots);
         double netProfitPoints = CalculateNetProfitPoints(grossProfitPoints, currentLots);
         
         status += "\n--- Active Trade ---\n";
         status += "Direction: " + (currentTrade.direction == 1 ? "BUY" : "SELL") + "\n";
         status += "P&L: $" + DoubleToString(profit, 2) + "\n";
         status += "Gross Points: " + DoubleToString(grossProfitPoints, 1);
         if(grossProfitPoints < 0)
            status += " / SL: " + DoubleToString(MaxLossPoints, 0) + "\n";
         else
            status += " (Profit)\n";
         status += "Net Points (after costs): " + DoubleToString(netProfitPoints, 1) + "\n";
         status += "Min Threshold: " + DoubleToString(minProfitThreshold, 1) + " pts (spread + commission + buffer)\n";
         status += "Hold Time: " + IntegerToString(holdSeconds) + " seconds\n";
         if(grossProfitPoints > 0)
         {
            status += "Velocity Exit: ";
            if(profit >= MinProfitUSD && holdSeconds >= MinHoldSeconds)
            {
               double velocity = CalculateProfitVelocity();
               double peakVelocity = GetPeakVelocity();
               bool velocityDecayed = HasVelocityDecayed();
               status += "ACTIVE (Vel: $" + DoubleToString(velocity, 2) + "/s";
               if(peakVelocity > 0.0)
                  status += " | Peak: $" + DoubleToString(peakVelocity, 2) + "/s";
               status += ")";
               if(velocityDecayed)
                  status += " [DECAYED]";
            }
            else
            {
               status += "WAITING (Min: $" + DoubleToString(MinProfitUSD, 2) + " | " + IntegerToString(MinHoldSeconds) + "s)";
            }
            status += "\n";
         }
         else
            status += "Max Hold: " + IntegerToString(MaxLossHoldSeconds) + " seconds\n";
         
         // Show breakeven and partial exit status
         if(currentTrade.breakevenMoved)
            status += "Breakeven: MOVED\n";
         if(currentTrade.partialExitDone)
            status += "Partial Exit: DONE (" + DoubleToString(PartialExitPercent, 0) + "%)\n";
      }
   }
   else
   {
      status += "\nNo active trade\n";
      status += "Waiting for momentum breakout signal...\n";
   }
   
   status += "\n--- Account ---\n";
   status += "Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n";
   status += "Equity: $" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\n";
   if(DailyProfitTarget > 0.0)
   {
      status += "Daily Profit: $" + DoubleToString(dailyProfit, 2);
      status += " / $" + DoubleToString(DailyProfitTarget, 2) + "\n";
   }
   
   Comment(status);
}
