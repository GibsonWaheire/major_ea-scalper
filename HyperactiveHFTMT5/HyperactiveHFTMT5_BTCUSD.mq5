#property copyright "Copyright 2025, Hyperactive HFT MT5 Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "2.00"

#include <Trade/Trade.mqh>

CTrade trade;

// =====================================================================================================
// HYPERACTIVE HFT MT5 SCALPER
// Strategy: Ultra-fast momentum breakout scalping
// - One trade at a time
// - Dynamic profit exit (close immediately when profit, hold up to 20 seconds)
// - Loss protection (max 100 points, close after 10 seconds if losing)
// - Momentum breakout entry
// - Fast execution (quick open/close)
// - Dynamic or fixed lot sizing
// - Multi-instrument support
// MODIFIED: Fewer trades, longer holds
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
input int      MomentumPeriod      = 30;       // Period for momentum calculation (ticks) - Increased for fewer trades
input double   BreakoutThreshold   = 0.0005;   // Minimum price movement for breakout - Increased for fewer trades
input int      MinTickSpeed        = 5;        // Minimum ticks per second for entry - Increased for fewer trades
input bool     UseTickSpeedFilter  = true;     // Enable tick speed filter
input double   StrongBreakoutMultiplier = 2.0; // Enter immediately if breakout >= threshold * multiplier - Increased for fewer trades

// ===== Exit Settings =====
input group "===== Profit Exit Settings ====="
input double   MinProfitPoints     = 10.0;     // Minimum profit in points to exit
input int      MaxProfitHoldSeconds = 400;     // Maximum seconds to hold profitable trade - Increased for longer holds
input bool     ExitImmediatelyOnProfit = false; // Exit immediately when profit target reached - Disabled for longer holds

input group "===== Loss Protection Settings ====="
input double   MaxLossPoints       = 250.0;    // Maximum loss in points (stop loss) - Reduced from 100
input int      MaxLossHoldSeconds  = 150;      // Close losing trade after N seconds - Increased for longer holds
input bool     UseTimeBasedLossExit = true;    // Enable time-based loss exit

// ===== Stop Loss Settings =====
input group "===== Stop Loss Settings ====="
input bool     UseStopLoss         = false;    // Use hard stop loss
input double   StopLossPoints      = 250.0;    // Stop loss in points (if UseStopLoss = true) - Reduced from 100
input bool     UseTrailingStop     = true;     // Use trailing stop loss
input double   TrailingStartPoints = 44.0;     // Start trailing after X points profit
input double   TrailingStepPoints  = 10.0;     // Trailing step in points (tighter for HFT)

// ===== Spread & Slippage =====
input group "===== Spread & Execution ====="
input double   MaxSpreadPoints     = 50.0;     // Maximum spread in points
input int      MaxSlippagePoints   = 10;       // Maximum slippage in points
input int      OrderRetries        = 3;        // Number of order retries

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
input double   PullbackPoints     = 2.5;        // Retrace points after breakout - Increased for fewer trades
input int      PullbackTimeoutSeconds = 10;     // Timeout for pullback wait - Increased for fewer trades

// ===== Volatility Cycle Filter =====
input group "===== Volatility Cycle Filter ====="
input bool     UseVolatilityCycleFilter = true; // Enable volatility cycle filter
input int      VolatilityCycleSeconds = 4;      // Tick speed must be rising for N seconds - Increased for fewer trades

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

TradeInfo currentTrade;
bool hasActiveTrade = false;

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
   Print("Hyperactive HFT MT5 Scalper V2.00");
   Print("Ultra-fast momentum breakout scalping with advanced filters");
   Print("MODIFIED: Fewer trades, longer holds");
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
   Print("Max Profit Hold: ", MaxProfitHoldSeconds, " seconds");
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("Hyperactive HFT MT5 Scalper deinitialized. Reason: ", reason);
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
         if(consecutiveMomentumTicks >= 2)  // Increased to 2 for fewer trades
         {
            // Check for strong breakout - enter immediately if momentum is very strong
            double strongBreakoutThreshold = breakoutThreshold * StrongBreakoutMultiplier;
            bool isStrongBreakout = (priceChange >= strongBreakoutThreshold && consecutiveMomentumTicks >= 3);  // Increased to 3
            
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
         if(consecutiveMomentumTicks >= 2)  // Increased to 2 for fewer trades
         {
            // Check for strong breakout - enter immediately if momentum is very strong
            double strongBreakoutThreshold = breakoutThreshold * StrongBreakoutMultiplier;
            bool isStrongBreakout = (priceChange <= -strongBreakoutThreshold && consecutiveMomentumTicks >= 3);  // Increased to 3
            
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
   
   // Calculate stop loss
   double sl = 0.0;
   if(UseStopLoss)
   {
      if(direction == 1)  // BUY
         sl = price - (StopLossPoints * point);
      else  // SELL
         sl = price + (StopLossPoints * point);
      
      sl = NormalizeDouble(sl, symbolDigits);
   }
   
   // No take profit (using dynamic exit)
   double tp = 0.0;
   
   string comment = "HyperHFT_" + (direction == 1 ? "BUY" : "SELL");
   
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
// MANAGE TRADE (EXIT LOGIC)
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
   
   // Calculate profit/loss in points
   double currentPrice = (currentTrade.direction == 1) ? currentBid : currentAsk;
   double priceDiff = currentPrice - currentTrade.entryPrice;
   if(currentTrade.direction == -1)
      priceDiff = -priceDiff;  // For SELL, reverse the difference
   
   double profitPoints = priceDiff / point;
   double lossPoints = (profitPoints < 0) ? MathAbs(profitPoints) : 0.0;
   
   // Update highest profit tracking
   if(profitPoints > currentTrade.highestProfitPoints)
   {
      currentTrade.highestProfitPoints = profitPoints;
      if(profitPoints > 0.0)
         currentTrade.wasProfitable = true;
   }
   
   // =====================================================================
   // EXIT CONDITION 1: Maximum loss points (hard stop)
   // =====================================================================
   if(lossPoints >= MaxLossPoints)
   {
      CloseTrade("Maximum loss points reached (" + DoubleToString(lossPoints, 1) + " pts)");
      return;
   }
   
   // =====================================================================
   // EXIT CONDITION 2: Time-based loss exit (close losing trade after 10 seconds)
   // =====================================================================
   if(UseTimeBasedLossExit && positionProfit < 0.0 && holdSeconds >= MaxLossHoldSeconds)
   {
      CloseTrade("Loss timeout (" + IntegerToString(holdSeconds) + " seconds)");
      return;
   }
   
   // =====================================================================
   // EXIT CONDITION 3: Immediate profit exit
   // =====================================================================
   if(ExitImmediatelyOnProfit && positionProfit > 0.0 && profitPoints >= MinProfitPoints)
   {
      CloseTrade("Profit target reached (" + DoubleToString(profitPoints, 1) + " pts)");
      return;
   }
   
   // =====================================================================
   // EXIT CONDITION 4: Maximum profit hold time (20 seconds)
   // =====================================================================
   if(positionProfit > 0.0 && holdSeconds >= MaxProfitHoldSeconds)
   {
      CloseTrade("Maximum profit hold time reached (" + IntegerToString(holdSeconds) + " seconds)");
      return;
   }
   
   // =====================================================================
   // EXIT CONDITION 5: Dynamic Breakeven
   // =====================================================================
   if(UseDynamicBreakeven && !currentTrade.breakevenMoved && profitPoints >= BreakevenTriggerPoints)
   {
      MoveToBreakeven();
   }
   
   // =====================================================================
   // EXIT CONDITION 6: Partial Exit
   // =====================================================================
   if(UsePartialExit && !currentTrade.partialExitDone && profitPoints >= PartialExitProfitPoints)
   {
      ExecutePartialExit();
   }
   
   // =====================================================================
   // EXIT CONDITION 7: Trailing stop (if enabled)
   // =====================================================================
   if(UseTrailingStop && currentTrade.highestProfitPoints >= TrailingStartPoints)
   {
      // Use tighter trailing after partial exit
      double trailingStep = currentTrade.partialExitDone ? (TrailingStepPoints * 0.5) : TrailingStepPoints;
      double trailingStopLevel = currentTrade.highestProfitPoints - trailingStep;
      if(profitPoints < trailingStopLevel)
      {
         CloseTrade("Trailing stop hit");
         return;
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
   string status = "\n=== Hyperactive HFT MT5 Scalper V2.00 ===\n";
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
         double profitPoints = priceDiff / point;
         
         status += "\n--- Active Trade ---\n";
         status += "Direction: " + (currentTrade.direction == 1 ? "BUY" : "SELL") + "\n";
         status += "P&L: $" + DoubleToString(profit, 2) + "\n";
         status += "Points: " + DoubleToString(profitPoints, 1);
         if(profitPoints < 0)
            status += " / SL: " + DoubleToString(MaxLossPoints, 0) + "\n";
         else
            status += " (Profit)\n";
         status += "Hold Time: " + IntegerToString(holdSeconds) + " seconds\n";
         if(profitPoints > 0)
            status += "Max Hold: " + IntegerToString(MaxProfitHoldSeconds) + " seconds\n";
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

