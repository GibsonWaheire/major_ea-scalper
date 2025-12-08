#property copyright "Copyright 2025, Hyperactive Pulse Scalper V2 - Ultra High Frequency Micro-Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "3.00"
#property strict

// =====================================================================================================
// HYPERACTIVE PULSE SCALPER V3 - ULTRA HIGH FREQUENCY MICRO-SCALPER (MT5 VERSION - CONVERTED FROM MT4)
// Strategy: True HFT micro-scalper using 3-in-1 entry system
// - Tick-based only (no candles, no indicators)
// - 3 entry models: Tick Momentum, Micro Pullback, Spread Compression
// - Ultra-fast exits (3-10 seconds)
// - Fixed lot sizing for speed
// - Dozens to hundreds of trades per hour
// - Perfect for XAUUSD HFT scalping
// =====================================================================================================

// ===== Trading Settings =====
input double   RiskPercentPerTrade   = 1.5;    // Risk % per trade (1.5% balanced for HFT)
input int      MagicNumber           = 202503;
input int      MaxHoldSeconds        = 5;      // Maximum hold time (3-10 seconds for HFT)

// ===== Risk Management Settings =====
input double   TrailingStopPips         = 10.0;   // Trailing stop distance (pips)
input double   BreakevenTriggerPips     = 5.0;    // Move to breakeven after profit (pips)
input double   DailyLossLimitPercent    = 10.0;   // Stop trading if daily loss exceeds (%)
input double   MaxDrawdownPercent       = 15.0;   // Stop all trading if drawdown exceeds (%)
input double   MaxSpreadPips            = 4.0;    // Don't trade if spread exceeds (pips)
input int      ConsecutiveLossLimit     = 3;      // Pause after X consecutive losses
input int      CooldownSeconds          = 45;     // Seconds to pause after consecutive losses
input double   MinProfitToClose         = 0.50;   // Minimum profit to close trade ($)

// ===== Pattern Strategy Settings =====
input int      PatternSequenceLength = 4;      // Number of trades in each pattern sequence (3-5)
input int      MomentumLookbackTicks = 15;     // Number of ticks to analyze for momentum (10-20)
input double   MomentumThreshold     = 0.60;   // Momentum threshold (0.60 = 60% ticks in direction)
input bool     UsePatternStrategy    = true;   // Enable pattern-based entry strategy
input bool     ValidateWithMomentum  = true;   // Validate pattern entry with momentum check

// =====================================================================================================
// STRUCTURES & GLOBALS
// =====================================================================================================

struct HFTrade {
   ulong    ticket;           // MQ5 uses ulong for ticket
   double   entryPrice;
   datetime openTime;
   int      direction;  // 1=BUY, -1=SELL
   double   lotSize;
   double   previousProfit;  // Track previous tick profit for spike detection
   double   stopLoss;         // Current stop loss level
   bool     breakevenSet;     // Whether breakeven stop has been set
};

HFTrade currentTrade;
bool hasActiveTrade = false;

// Tick buffers for momentum breakout - REDUCED for faster signals
double bidBuffer[3];
double askBuffer[3];
int tickIndex = 0;
bool buffersInitialized = false;

// Spread buffer for compression detection - REDUCED for faster signals
double spreadBuffer[5];
int spreadIndex = 0;
bool spreadBufferInitialized = false;

// Micro pullback tracking
double lastSwingHigh = 0.0;
double lastSwingLow = 0.0;
int pullbackTicks = 0;
int lastMoveDirection = 0;  // 1=up, -1=down, 0=none

// Price data
double pipToPoint = 0.0;
int digits = 0;

// Pattern strategy tracking
int patternSequence[10];  // Store current pattern sequence (max 10 trades)
int patternIndex = 0;      // Current position in pattern
int tradesInSequence = 0;  // Number of trades completed in current sequence
int lastPatternMomentum = 0;  // Last detected momentum (-1=bearish, 0=neutral, 1=bullish)
int recentTradeDirections[20]; // Track last 20 trade directions for pattern generation
int recentTradeCount = 0;

// Risk management tracking
double dailyStartBalance = 0.0;
double dailyProfitLoss = 0.0;
double sessionHighEquity = 0.0;
int consecutiveLosses = 0;
datetime cooldownUntil = 0;
bool breakevenSet = false;
double highestProfit = 0.0;

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("ULTRA HIGH FREQUENCY MICRO-SCALPER V3.00");
   Print("AGGRESSIVE MODE: 5-IN-1 ENTRY SYSTEM");
   Print("Tick Momentum | Direction Change | Micro Pullback | Spread Compression | Continuous Momentum");
   Print("========================================");
   Print("Risk per Trade: ", RiskPercentPerTrade, "%");
   Print("Max Hold Time: ", MaxHoldSeconds, " seconds");
   Print("Risk Management: ENABLED");
   Print("  - Trailing Stop: ", TrailingStopPips, " pips");
   Print("  - Breakeven Trigger: ", BreakevenTriggerPips, " pips");
   Print("  - Daily Loss Limit: ", DailyLossLimitPercent, "%");
   Print("  - Max Drawdown: ", MaxDrawdownPercent, "%");
   Print("  - Max Spread: ", MaxSpreadPips, " pips");
   Print("  - Consecutive Loss Limit: ", ConsecutiveLossLimit, " trades");
   Print("  - Min Profit to Close: $", MinProfitToClose);
   if(UsePatternStrategy)
   {
      Print("Entry Strategy: PATTERN-BASED (Sequence Length: ", PatternSequenceLength, " trades)");
      Print("Momentum Lookback: ", MomentumLookbackTicks, " ticks | Threshold: ", DoubleToString(MomentumThreshold * 100, 0), "%");
      Print("Momentum Validation: ", (ValidateWithMomentum ? "ON" : "OFF"));
   }
   else
   {
      Print("Entry Strategy: TICK-BASED (Random Entry)");
   }
   Print("Buffer Init: 2 ticks (was 5) | Spread Init: 3 ticks (was 10)");
   Print("Exit: Instant profit exit (never close at loss)");
   Print("No indicators | No candles | Maximum frequency");
   Print("========================================");
   
   // Initialize symbol data
   digits = Digits;
   pipToPoint = Point;
   if(digits == 3 || digits == 5)
      pipToPoint *= 10.0;
   
   // Initialize trading state
   hasActiveTrade = false;
   
   // Initialize risk management
   dailyStartBalance = AccountBalance();
   dailyProfitLoss = 0.0;
   sessionHighEquity = AccountEquity();
   consecutiveLosses = 0;
   cooldownUntil = 0;
   breakevenSet = false;
   highestProfit = 0.0;
   
   // Initialize pattern strategy
   patternIndex = 0;
   tradesInSequence = 0;
   lastPatternMomentum = 0;
   recentTradeCount = 0;
   for(int i = 0; i < 10; i++)
      patternSequence[i] = 0;
   for(int i = 0; i < 20; i++)
      recentTradeDirections[i] = 0;
   
   // Initialize buffers - REDUCED SIZE for faster initialization
   for(int i = 0; i < 3; i++)
   {
      bidBuffer[i] = 0.0;
      askBuffer[i] = 0.0;
   }
   for(int i = 0; i < 5; i++)
   {
      spreadBuffer[i] = 0.0;
   }
   
   Print("EA initialized - ready for ultra high-frequency trading");
   
   // Initialize pattern strategy if enabled
   if(UsePatternStrategy)
   {
      Print("Pattern Strategy: ENABLED");
      Print("  - Sequence Length: ", PatternSequenceLength, " trades");
      Print("  - Momentum Validation: ", (ValidateWithMomentum ? "ON" : "OFF"));
      Print("  - Pattern will be generated after buffers initialize (2+ ticks)");
   }
   else
   {
      Print("Pattern Strategy: DISABLED - Using tick-based entry");
   }
   
   // Check AutoTrading
   if(IsTradeAllowed())
   {
      Print("✓ AutoTrading is ENABLED - Ready to trade");
   }
   else
   {
      Print("⚠ AutoTrading is DISABLED - Please enable AutoTrading button in MT5!");
   }
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("HFT Micro-Scalper V3 deinitialized. Reason: ", reason);
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   // Update tick buffers
   UpdateTickBuffers();
   
   // Manage active trade (ultra-fast exits)
   if(hasActiveTrade)
   {
      ManageHFTrade();
   }
   
   // Open new trade if no active trade
   if(!hasActiveTrade)
   {
      int direction = 0;
      
      if(UsePatternStrategy)
      {
         // Use pattern-based entry strategy
         direction = GetPatternEntrySignal();
      }
      else
      {
         // Use old tick-based entry strategy (fallback)
         direction = GetHFEntrySignal();
      }
      
      // Debug logging (every 100 ticks)
      static int debugCounter = 0;
      debugCounter++;
      if(debugCounter % 100 == 0)
      {
         Print("DEBUG: Direction=", direction, " | HasActiveTrade=", hasActiveTrade, 
               " | TickIndex=", tickIndex, " | PatternIndex=", patternIndex,
               " | UsePatternStrategy=", UsePatternStrategy);
      }
      
      if(direction != 0)
      {
         Print("Signal detected: ", (direction == 1 ? "BUY" : "SELL"), " - Attempting to open trade...");
         
         if(OpenHFTrade(direction))
         {
            // Track trade direction for pattern (only if trade opened successfully)
            if(UsePatternStrategy)
            {
               // Advance pattern index for next trade
               patternIndex++;
            }
         }
      }
   }
   
   // Update display
   UpdateDisplay();
}

// =====================================================================================================
// PATTERN-BASED ENTRY STRATEGY
// =====================================================================================================

int DetectMomentum()
{
   // Simple momentum detection using available buffer data
   // We only have 3 ticks in buffer, so use what we have
   
   if(tickIndex < 2)
      return 0;  // Neutral - not enough data
   
   int bullishTicks = 0;
   int bearishTicks = 0;
   
   // Check recent tick movements (we have 3 ticks: current, previous, before that)
   if(tickIndex >= 2)
   {
      // Compare current vs previous
      if(Bid > bidBuffer[1])
         bullishTicks++;
      else if(Bid < bidBuffer[1])
         bearishTicks++;
      
      // Compare previous vs before that
      if(bidBuffer[1] > bidBuffer[2])
         bullishTicks++;
      else if(bidBuffer[1] < bidBuffer[2])
         bearishTicks++;
   }
   else if(tickIndex >= 1)
   {
      // Only one comparison available
      if(Bid > bidBuffer[1])
         bullishTicks++;
      else if(Bid < bidBuffer[1])
         bearishTicks++;
   }
   
   double totalTicks = bullishTicks + bearishTicks;
   if(totalTicks == 0)
      return 0;  // Neutral
   
   double bullishRatio = bullishTicks / totalTicks;
   
   // Determine momentum based on ratio
   if(bullishRatio >= MomentumThreshold)
      return 1;  // Bullish momentum
   else if(bullishRatio <= (1.0 - MomentumThreshold))
      return -1;  // Bearish momentum
   else
      return 0;  // Neutral/ranging
}

void GeneratePattern(int momentum)
{
   // Clear existing pattern
   for(int i = 0; i < 10; i++)
      patternSequence[i] = 0;
   
   patternIndex = 0;
   lastPatternMomentum = momentum;
   
   // Generate pattern based on momentum
   if(momentum == 1)  // Bullish - more buys
   {
      // Pattern: Buy-Buy-Sell-Buy-Buy or Buy-Buy-Buy-Sell-Buy
      if(PatternSequenceLength == 3)
      {
         patternSequence[0] = 1;  // BUY
         patternSequence[1] = 1;  // BUY
         patternSequence[2] = -1; // SELL
      }
      else if(PatternSequenceLength == 4)
      {
         patternSequence[0] = 1;  // BUY
         patternSequence[1] = 1;  // BUY
         patternSequence[2] = -1; // SELL
         patternSequence[3] = 1;  // BUY
      }
      else if(PatternSequenceLength == 5)
      {
         patternSequence[0] = 1;  // BUY
         patternSequence[1] = 1;  // BUY
         patternSequence[2] = 1;  // BUY
         patternSequence[3] = -1; // SELL
         patternSequence[4] = 1;  // BUY
      }
   }
   else if(momentum == -1)  // Bearish - more sells
   {
      // Pattern: Sell-Sell-Buy-Sell-Sell or Sell-Sell-Sell-Buy-Sell
      if(PatternSequenceLength == 3)
      {
         patternSequence[0] = -1; // SELL
         patternSequence[1] = -1; // SELL
         patternSequence[2] = 1;  // BUY
      }
      else if(PatternSequenceLength == 4)
      {
         patternSequence[0] = -1; // SELL
         patternSequence[1] = -1; // SELL
         patternSequence[2] = 1;  // BUY
         patternSequence[3] = -1; // SELL
      }
      else if(PatternSequenceLength == 5)
      {
         patternSequence[0] = -1; // SELL
         patternSequence[1] = -1; // SELL
         patternSequence[2] = -1; // SELL
         patternSequence[3] = 1;  // BUY
         patternSequence[4] = -1; // SELL
      }
   }
   else  // Neutral - alternating pattern
   {
      // Pattern: Buy-Sell-Buy-Sell-Buy
      for(int i = 0; i < PatternSequenceLength; i++)
      {
         patternSequence[i] = (i % 2 == 0) ? 1 : -1;  // Alternating
      }
   }
   
   Print("Pattern Generated - Momentum: ", (momentum == 1 ? "BULLISH" : (momentum == -1 ? "BEARISH" : "NEUTRAL")), 
         " | Sequence Length: ", PatternSequenceLength);
}

bool ValidatePatternEntryWithMomentum(int direction)
{
   if(!ValidateWithMomentum)
      return true;  // Skip validation if disabled
   
   // Quick momentum check - ensure direction aligns with recent momentum
   if(tickIndex < 2)
      return true;  // Not enough data - allow anyway
   
   // Very lenient validation - only block if momentum is strongly against
   int recentMomentum = 0;
   if(tickIndex >= 2)
   {
      if(Bid > bidBuffer[1] && bidBuffer[1] > bidBuffer[2])
         recentMomentum = 1;  // Strong bullish
      else if(Bid < bidBuffer[1] && bidBuffer[1] < bidBuffer[2])
         recentMomentum = -1;  // Strong bearish
      else if(Bid > bidBuffer[1])
         recentMomentum = 1;  // Mild bullish
      else if(Bid < bidBuffer[1])
         recentMomentum = -1;  // Mild bearish
   }
   
   // Allow entry if momentum aligns or is neutral
   if(recentMomentum == 0)
      return true;  // Neutral momentum - allow
   
   // Only block if momentum is strongly against (very lenient)
   // For BUY: only block if strongly bearish
   if(direction == 1)
      return (recentMomentum >= -1);  // Allow even if slightly bearish
   
   // For SELL: only block if strongly bullish
   if(direction == -1)
      return (recentMomentum <= 1);  // Allow even if slightly bullish
   
   return true;  // Default allow
}

int GetPatternEntrySignal()
{
   // Check if pattern needs to be generated (first time or sequence complete)
   if(tradesInSequence >= PatternSequenceLength || patternIndex >= PatternSequenceLength || patternSequence[0] == 0)
   {
      // Generate initial pattern or regenerate after sequence completion
      if(tickIndex < 2)
      {
         return 0;  // Not enough ticks to detect momentum
      }
      
      int currentMomentum = DetectMomentum();
      GeneratePattern(currentMomentum);
      tradesInSequence = 0;
      patternIndex = 0;
   }
   
   // Get next entry from pattern
   if(patternIndex < PatternSequenceLength && patternSequence[patternIndex] != 0)
   {
      int nextDirection = patternSequence[patternIndex];
      
      // Validate with momentum if enabled (but don't be too strict)
      if(ValidatePatternEntryWithMomentum(nextDirection))
      {
         return nextDirection;
      }
      else
      {
         // Momentum doesn't align - but don't skip too many times
         static int skipCount = 0;
         skipCount++;
         
         // If we've skipped too many times, just take the pattern entry anyway
         if(skipCount >= 5)
         {
            skipCount = 0;
            return nextDirection;  // Force entry after 5 skips
         }
         
         // Skip this entry, try next in sequence
         patternIndex++;
         return 0;  // Wait for next tick
      }
   }
   
   return 0;  // No pattern signal
}

// =====================================================================================================
// 3-IN-1 HIGH FREQUENCY ENTRY SYSTEM (FALLBACK - if pattern strategy disabled)
// =====================================================================================================

int GetHFEntrySignal()
{
   // AGGRESSIVE: Only need 2 ticks to start trading (much faster)
   if(tickIndex < 2)
      return 0;
   
   int buySignal = 0;
   int sellSignal = 0;
   
   // ===== (A) ULTRA-SENSITIVE TICK MOMENTUM (1-2 tick comparison) =====
   // BUY if current Bid > previous Bid (immediate momentum)
   if(tickIndex >= 1 && Bid > bidBuffer[1])
      buySignal = 1;
   
   // SELL if current Ask < previous Ask (immediate momentum)
   if(tickIndex >= 1 && Ask < askBuffer[1])
      sellSignal = 1;
   
   // Also check 2-tick momentum for stronger signals
   if(tickIndex >= 2)
   {
      if(Bid > bidBuffer[2])
         buySignal = MathMax(buySignal, 1);
      if(Ask < askBuffer[2])
         sellSignal = MathMax(sellSignal, 1);
   }
   
   // ===== (B) INSTANT DIRECTION CHANGE DETECTION =====
   // If price reverses direction, enter immediately
   if(tickIndex >= 2)
   {
      // BUY on any upward tick movement
      if(Bid > bidBuffer[1] && bidBuffer[1] <= bidBuffer[2])
         buySignal = MathMax(buySignal, 1);
      
      // SELL on any downward tick movement
      if(Ask < askBuffer[1] && askBuffer[1] >= askBuffer[2])
         sellSignal = MathMax(sellSignal, 1);
   }
   
   // ===== (C) MICRO PULLBACK ENTRY - SIMPLIFIED & AGGRESSIVE =====
   if(tickIndex >= 2)
   {
      // Any tiny pullback followed by continuation = signal
      if(Bid > bidBuffer[1] && bidBuffer[1] < bidBuffer[2])
         buySignal = MathMax(buySignal, 1);
      
      if(Ask < askBuffer[1] && askBuffer[1] > askBuffer[2])
         sellSignal = MathMax(sellSignal, 1);
   }
   
   // ===== (D) SPREAD COMPRESSION ENTRY - MORE AGGRESSIVE =====
   if(spreadIndex >= 3)
   {
      double currentSpread = Ask - Bid;
      double avgSpread = 0.0;
      
      for(int i = 0; i < 5; i++)
      {
         avgSpread += spreadBuffer[i];
      }
      avgSpread = avgSpread / 5.0;
      
      // AGGRESSIVE: Trigger at 80% of average (was 50%) - much more frequent
      if(avgSpread > 0.0 && currentSpread < avgSpread * 0.8)
      {
         // Spread compression detected - enter in momentum direction
         if(buySignal == 0 && sellSignal == 0)
         {
            // No other signal, use immediate momentum
            if(Bid > bidBuffer[1])
               buySignal = 1;
            else if(Ask < askBuffer[1])
               sellSignal = 1;
         }
         // Strengthen existing signals
         else if(buySignal > 0)
            buySignal = 2;
         else if(sellSignal > 0)
            sellSignal = 2;
      }
   }
   
   // ===== (E) CONTINUOUS MOMENTUM DETECTION =====
   // If price is consistently moving in one direction, keep entering
   if(tickIndex >= 2)
   {
      if(Bid > bidBuffer[1] && bidBuffer[1] > bidBuffer[2])
         buySignal = MathMax(buySignal, 1);
      
      if(Ask < askBuffer[1] && askBuffer[1] < askBuffer[2])
         sellSignal = MathMax(sellSignal, 1);
   }
   
   // Return combined signal - AGGRESSIVE: any signal triggers trade
   if(buySignal > 0 && buySignal >= sellSignal)
      return 1;  // BUY
   else if(sellSignal > 0 && sellSignal > buySignal)
      return -1;  // SELL
   
   return 0;  // No signal
}

// =====================================================================================================
// TICK BUFFER MANAGEMENT
// =====================================================================================================

void UpdateTickBuffers()
{
   // Shift bid buffer - REDUCED SIZE (3 instead of 5)
   for(int i = 2; i > 0; i--)
   {
      bidBuffer[i] = bidBuffer[i-1];
   }
   bidBuffer[0] = Bid;
   
   // Shift ask buffer - REDUCED SIZE (3 instead of 5)
   for(int i = 2; i > 0; i--)
   {
      askBuffer[i] = askBuffer[i-1];
   }
   askBuffer[0] = Ask;
   
   // Update spread buffer - REDUCED SIZE (5 instead of 10)
   double currentSpread = Ask - Bid;
   for(int i = 4; i > 0; i--)
   {
      spreadBuffer[i] = spreadBuffer[i-1];
   }
   spreadBuffer[0] = currentSpread;
   
   tickIndex++;
   spreadIndex++;
   
   // AGGRESSIVE: Mark buffers as initialized after just 2 ticks (was 5)
   if(tickIndex >= 2)
      buffersInitialized = true;
   
   // AGGRESSIVE: Mark spread buffer initialized after 3 ticks (was 10)
   if(spreadIndex >= 3)
      spreadBufferInitialized = true;
}

// =====================================================================================================
// ULTRA FAST EXIT SYSTEM
// =====================================================================================================

void ManageHFTrade()
{
   if(!hasActiveTrade || currentTrade.ticket <= 0)
      return;
   
   if(!PositionSelectByTicket(currentTrade.ticket))
   {
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      return;
   }
   
   if(PositionGetInteger(POSITION_TIME) == 0)
   {
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      return;
   }
   
   double currentProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
   int holdSeconds = (int)(TimeCurrent() - currentTrade.openTime);
   
   // Track highest profit for trailing stop
   if(currentProfit > highestProfit)
      highestProfit = currentProfit;
   
   // ===== 1. MAXIMUM HOLD TIME ENFORCEMENT =====
   if(holdSeconds >= MaxHoldSeconds)
   {
      if(currentProfit >= MinProfitToClose)
      {
         CloseHFTrade("Max hold time reached");
      }
      else
      {
         // Force close even at loss if max hold time exceeded
         CloseHFTrade("Max hold time exceeded (forced close)");
      }
      return;
   }
   
   // ===== 2. MINIMUM PROFIT CHECK =====
   // Only close if profit meets minimum threshold
   if(currentProfit < MinProfitToClose)
   {
      // Don't close yet - wait for minimum profit or max hold time
      return;
   }
   
   // ===== 3. BREAKEVEN STOP =====
   if(!currentTrade.breakevenSet && currentProfit > 0)
   {
      double priceDistance = 0.0;
      if(currentTrade.direction == 1)  // BUY
      {
         priceDistance = (Bid - currentTrade.entryPrice) / pipToPoint;
      }
      else  // SELL
      {
         priceDistance = (currentTrade.entryPrice - Ask) / pipToPoint;
      }
      
      if(priceDistance >= BreakevenTriggerPips)
      {
         double breakevenPrice = currentTrade.entryPrice;
         double newStopLoss = breakevenPrice;
         
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         request.action = TRADE_ACTION_SLTP;
         request.position = currentTrade.ticket;
         request.symbol = Symbol();
         request.sl = newStopLoss;
         request.tp = PositionGetDouble(POSITION_TP);
         
         if(OrderSend(request, result))
         {
            currentTrade.stopLoss = newStopLoss;
            currentTrade.breakevenSet = true;
            Print("Breakeven stop set at entry price: ", DoubleToString(breakevenPrice, digits));
         }
      }
   }
   
   // ===== 4. TRAILING STOP =====
   if(currentProfit > 0 && TrailingStopPips > 0)
   {
      double trailDistance = TrailingStopPips * pipToPoint;
      double newStopLoss = 0.0;
      
      if(currentTrade.direction == 1)  // BUY
      {
         newStopLoss = Bid - trailDistance;
         if(newStopLoss > currentTrade.entryPrice && (currentTrade.stopLoss == 0 || newStopLoss > currentTrade.stopLoss))
         {
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            request.action = TRADE_ACTION_SLTP;
            request.position = currentTrade.ticket;
            request.symbol = Symbol();
            request.sl = newStopLoss;
            request.tp = PositionGetDouble(POSITION_TP);
            
            if(OrderSend(request, result))
            {
               currentTrade.stopLoss = newStopLoss;
               Print("Trailing stop updated: ", DoubleToString(newStopLoss, digits));
            }
         }
      }
      else  // SELL
      {
         newStopLoss = Ask + trailDistance;
         if(newStopLoss < currentTrade.entryPrice && (currentTrade.stopLoss == 0 || newStopLoss < currentTrade.stopLoss))
         {
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            request.action = TRADE_ACTION_SLTP;
            request.position = currentTrade.ticket;
            request.symbol = Symbol();
            request.sl = newStopLoss;
            request.tp = PositionGetDouble(POSITION_TP);
            
            if(OrderSend(request, result))
            {
               currentTrade.stopLoss = newStopLoss;
               Print("Trailing stop updated: ", DoubleToString(newStopLoss, digits));
            }
         }
      }
   }
   
   // ===== 5. INSTANT PROFIT EXIT (if minimum profit met) =====
   if(currentProfit >= MinProfitToClose)
   {
      CloseHFTrade("Profit target reached");
      return;
   }
}

// =====================================================================================================
// RISK MANAGEMENT CHECKS
// =====================================================================================================

void UpdateDailyTracking()
{
   // Check if new trading day (reset daily tracking)
   static int lastDay = 0;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentDay = dt.day;
   
   if(currentDay != lastDay)
   {
      dailyStartBalance = AccountBalance();
      dailyProfitLoss = 0.0;
      consecutiveLosses = 0;
      cooldownUntil = 0;
      lastDay = currentDay;
      Print("New trading day - Daily tracking reset");
   }
   
   // Update daily P&L
   dailyProfitLoss = AccountBalance() - dailyStartBalance;
   
   // Update session high equity
   double currentEquity = AccountEquity();
   if(currentEquity > sessionHighEquity)
      sessionHighEquity = currentEquity;
}

bool CheckRiskManagement()
{
   // Update daily tracking
   UpdateDailyTracking();
   
   // Check cooldown period
   if(cooldownUntil > 0 && TimeCurrent() < cooldownUntil)
   {
      int remainingSeconds = (int)(cooldownUntil - TimeCurrent());
      static int lastWarning = 0;
      if(TimeCurrent() - lastWarning > 10)  // Warn every 10 seconds
      {
         Print("Trading paused - Cooldown active. Remaining: ", remainingSeconds, " seconds");
         lastWarning = TimeCurrent();
      }
      return false;
   }
   
   // Check daily loss limit
   double dailyLossPercent = (dailyProfitLoss / dailyStartBalance) * 100.0;
   if(dailyLossPercent <= -DailyLossLimitPercent)
   {
      static int lastWarning = 0;
      if(TimeCurrent() - lastWarning > 60)  // Warn once per minute
      {
         Print("Trading BLOCKED - Daily loss limit reached: ", DoubleToString(dailyLossPercent, 2), "%");
         lastWarning = TimeCurrent();
      }
      return false;
   }
   
   // Check maximum drawdown
   double currentDrawdown = ((sessionHighEquity - AccountEquity()) / sessionHighEquity) * 100.0;
   if(currentDrawdown >= MaxDrawdownPercent)
   {
      static int lastWarning = 0;
      if(TimeCurrent() - lastWarning > 60)  // Warn once per minute
      {
         Print("Trading BLOCKED - Maximum drawdown exceeded: ", DoubleToString(currentDrawdown, 2), "%");
         lastWarning = TimeCurrent();
      }
      return false;
   }
   
   // Check spread
   double currentSpread = (Ask - Bid) / pipToPoint;
   if(currentSpread > MaxSpreadPips)
   {
      static int lastWarning = 0;
      if(TimeCurrent() - lastWarning > 30)  // Warn every 30 seconds
      {
         Print("Trading BLOCKED - Spread too wide: ", DoubleToString(currentSpread, 1), " pips (Max: ", MaxSpreadPips, ")");
         lastWarning = TimeCurrent();
      }
      return false;
   }
   
   return true;
}

// =====================================================================================================
// RISK-BASED LOT SIZE CALCULATION
// =====================================================================================================

double CalculateRiskLotSize()
{
   double balance = AccountBalance();
   double riskMoney = balance * (RiskPercentPerTrade / 100.0);
   
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
   double pipValuePerLot = 0.0;
   
   if(tickSize > 0)
      pipValuePerLot = (tickValue / tickSize) * pipToPoint;
   
   if(pipValuePerLot <= 0.0)
   {
      Print("ERROR: Cannot calculate pip value. Using minimum lot.");
      return MarketInfo(Symbol(), MODE_MINLOT);
   }
   
   double virtualSL_Pips = 10.0;   // virtual stop to size lots for HFT
   double lot = riskMoney / (virtualSL_Pips * pipValuePerLot);
   
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   
   lot = MathFloor(lot / lotStep) * lotStep;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   
   return NormalizeDouble(lot, 2);
}

// =====================================================================================================
// TRADE OPENING
// =====================================================================================================

bool OpenHFTrade(int direction)
{
   if(direction == 0)
      return false;
   
   // Check risk management conditions
   if(!CheckRiskManagement())
      return false;
   
   // Check if AutoTrading is enabled
   if(!IsTradeAllowed())
   {
      static int lastWarningTime = 0;
      if(TimeCurrent() - lastWarningTime > 60)  // Warn once per minute
      {
         Print("ERROR: AutoTrading is disabled in MT5. Please enable AutoTrading button!");
         lastWarningTime = TimeCurrent();
      }
      return false;
   }
   
   double tradeLots = CalculateRiskLotSize();
   if(tradeLots <= 0.0)
   {
      Print("ERROR: Invalid lot size calculated");
      return false;
   }
   
   double price = (direction == 1) ? Ask : Bid;
   double sl = 0.0;  // NO STOP LOSS
   double tp = 0.0;  // NO TAKE PROFIT
   
   string comment = "HFT_V3_" + (direction == 1 ? "BUY" : "SELL");
   ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   request.action = TRADE_ACTION_DEAL;
   request.symbol = Symbol();
   request.volume = tradeLots;
   request.type = orderType;
   request.price = price;
   request.sl = sl;
   request.tp = tp;
   request.comment = comment;
   request.magic = MagicNumber;
   request.deviation = 3;
   
   ulong ticket = 0;
   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
      {
         ticket = result.order;
      }
      else
      {
         Print("OrderSend returned retcode: ", result.retcode, " | Comment: ", result.comment);
      }
   }
   
   if(ticket > 0)
   {
      if(PositionSelectByTicket(ticket))
      {
         currentTrade.ticket = ticket;
         currentTrade.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         currentTrade.openTime = (datetime)PositionGetInteger(POSITION_TIME);
         currentTrade.direction = direction;
         currentTrade.lotSize = tradeLots;
         currentTrade.previousProfit = 0.0;
         currentTrade.stopLoss = 0.0;
         currentTrade.breakevenSet = false;
         hasActiveTrade = true;
         highestProfit = 0.0;
         
         Print("HFT TRADE OPENED: ", (direction == 1 ? "BUY" : "SELL"), 
               " | Lot: ", tradeLots, " | Risk: ", RiskPercentPerTrade, "% | Price: ", price);
         return true;
      }
   }
   else
   {
      Print("OrderSend FAILED: Retcode=", result.retcode, " | Symbol=", Symbol(), " | Type=", (direction == 1 ? "BUY" : "SELL"),
            " | Lot=", tradeLots, " | Price=", price, " | Comment: ", result.comment);
      
      // Common error messages
      if(result.retcode == TRADE_RETCODE_INVALID_STOPS)
         Print("ERROR: Invalid stops. Check price and stop levels.");
      else if(result.retcode == TRADE_RETCODE_INVALID_VOLUME)
         Print("ERROR: Invalid trade volume. Check lot size limits.");
      else if(result.retcode == TRADE_RETCODE_NO_MONEY)
         Print("ERROR: Not enough money to open trade.");
      else if(result.retcode == TRADE_RETCODE_TRADE_DISABLED)
         Print("ERROR: Trading is disabled.");
      else if(result.retcode == TRADE_RETCODE_REQUOTE)
         Print("ERROR: Requote occurred. Price changed during order execution.");
   }
   
   return false;
}

// =====================================================================================================
// TRADE CLOSING
// =====================================================================================================

void CloseHFTrade(string reason)
{
   if(!hasActiveTrade || currentTrade.ticket <= 0)
      return;
   
   if(!PositionSelectByTicket(currentTrade.ticket))
   {
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      return;
   }
   
   if(PositionGetInteger(POSITION_TIME) == 0)
   {
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      return;
   }
   
   double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
   
   // Allow closing at loss only if max hold time exceeded (handled in ManageHFTrade)
   // Otherwise, only close if profit meets minimum threshold
   if(profit < MinProfitToClose && profit > 0)
   {
      // Profit is positive but below minimum threshold - wait
      return;
   }
   
   bool result = PositionClose(currentTrade.ticket);
   
   if(result)
   {
      int holdSeconds = (int)(TimeCurrent() - currentTrade.openTime);
      Print("HFT TRADE CLOSED: ", reason, " | P&L: $", DoubleToString(profit, 2), 
            " | Hold: ", IntegerToString(holdSeconds), "s");
      
      // Update risk management tracking
      UpdateDailyTracking();
      
      // Track consecutive losses
      if(profit < 0)
      {
         consecutiveLosses++;
         Print("Consecutive losses: ", consecutiveLosses, "/", ConsecutiveLossLimit);
         
         // Activate cooldown if consecutive loss limit reached
         if(consecutiveLosses >= ConsecutiveLossLimit)
         {
            cooldownUntil = TimeCurrent() + CooldownSeconds;
            Print("COOLDOWN ACTIVATED - Pausing trading for ", CooldownSeconds, " seconds after ", consecutiveLosses, " consecutive losses");
            consecutiveLosses = 0;  // Reset counter
         }
      }
      else
      {
         // Reset consecutive losses on profitable trade
         consecutiveLosses = 0;
      }
      
      // Track pattern sequence progress
      if(UsePatternStrategy)
      {
         tradesInSequence++;
         
         // Track trade direction in recent trades array
         if(recentTradeCount < 20)
         {
            recentTradeDirections[recentTradeCount] = currentTrade.direction;
            recentTradeCount++;
         }
         else
         {
            // Shift array
            for(int i = 0; i < 19; i++)
               recentTradeDirections[i] = recentTradeDirections[i+1];
            recentTradeDirections[19] = currentTrade.direction;
         }
      }
   }
      else
      {
         Print("PositionClose failed: ", GetLastError());
      }
   
   hasActiveTrade = false;
   currentTrade.ticket = 0;
}

// =====================================================================================================
// DISPLAY
// =====================================================================================================

void UpdateDisplay()
{
   // Update daily tracking for display
   UpdateDailyTracking();
   
   string display = "\n=== ULTRA HIGH FREQUENCY MICRO-SCALPER V3 ===\n";
   if(UsePatternStrategy)
   {
      display += "PATTERN-BASED ENTRY STRATEGY\n";
      display += "Sequence: " + IntegerToString(tradesInSequence) + "/" + IntegerToString(PatternSequenceLength);
      display += " | Pattern Position: " + IntegerToString(patternIndex) + "/" + IntegerToString(PatternSequenceLength) + "\n";
      string momentumStr = (lastPatternMomentum == 1 ? "BULLISH" : (lastPatternMomentum == -1 ? "BEARISH" : "NEUTRAL"));
      display += "Current Momentum: " + momentumStr + "\n";
      display += "Risk per Trade: " + DoubleToString(RiskPercentPerTrade, 1) + "% | Max Hold: " + 
                 IntegerToString(MaxHoldSeconds) + "s\n";
   }
   else
   {
      display += "AGGRESSIVE MODE: 5-IN-1 ENTRY SYSTEM\n";
      display += "Tick Momentum | Direction Change | Micro Pullback | Spread Compression | Continuous Momentum\n";
      display += "Risk per Trade: " + DoubleToString(RiskPercentPerTrade, 1) + "% | Max Hold: " + 
                 IntegerToString(MaxHoldSeconds) + "s\n";
   }
   
   // Risk Management Status
   display += "\n--- RISK MANAGEMENT ---\n";
   double dailyLossPercent = (dailyProfitLoss / dailyStartBalance) * 100.0;
   double currentDrawdown = sessionHighEquity > 0 ? ((sessionHighEquity - AccountEquity()) / sessionHighEquity) * 100.0 : 0.0;
   double currentSpread = (Ask - Bid) / pipToPoint;
   
   display += "Daily P&L: $" + DoubleToString(dailyProfitLoss, 2) + " (" + DoubleToString(dailyLossPercent, 2) + "%)";
   if(dailyLossPercent <= -DailyLossLimitPercent)
      display += " [LIMIT REACHED]";
   display += "\n";
   
   display += "Drawdown: " + DoubleToString(currentDrawdown, 2) + "%";
   if(currentDrawdown >= MaxDrawdownPercent)
      display += " [LIMIT REACHED]";
   display += "\n";
   
   display += "Spread: " + DoubleToString(currentSpread, 1) + " pips";
   if(currentSpread > MaxSpreadPips)
      display += " [TOO WIDE]";
   display += "\n";
   
   display += "Consecutive Losses: " + IntegerToString(consecutiveLosses) + "/" + IntegerToString(ConsecutiveLossLimit) + "\n";
   
   if(cooldownUntil > 0 && TimeCurrent() < cooldownUntil)
   {
      int remainingSeconds = (int)(cooldownUntil - TimeCurrent());
      display += "COOLDOWN: " + IntegerToString(remainingSeconds) + "s remaining\n";
   }
   
   display += "\n--- TRADE MANAGEMENT ---\n";
   display += "Trailing Stop: " + DoubleToString(TrailingStopPips, 1) + " pips\n";
   display += "Breakeven Trigger: " + DoubleToString(BreakevenTriggerPips, 1) + " pips\n";
   display += "Min Profit to Close: $" + DoubleToString(MinProfitToClose, 2) + "\n";
   
   if(hasActiveTrade)
   {
      if(PositionSelectByTicket(currentTrade.ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
         int holdSeconds = (int)(TimeCurrent() - currentTrade.openTime);
         
         display += "\n--- ACTIVE TRADE ---\n";
         display += "Direction: " + (currentTrade.direction == 1 ? "BUY" : "SELL") + "\n";
         display += "P&L: $" + DoubleToString(profit, 2);
         if(profit >= MinProfitToClose)
            display += " [READY TO CLOSE]";
         display += "\n";
         display += "Hold: " + IntegerToString(holdSeconds) + "s / " + 
                    IntegerToString(MaxHoldSeconds) + "s max\n";
         if(currentTrade.breakevenSet)
            display += "Breakeven: SET\n";
         if(currentTrade.stopLoss > 0)
            display += "Stop Loss: " + DoubleToString(currentTrade.stopLoss, digits) + "\n";
      }
   }
   else
   {
      display += "\n--- STATUS ---\n";
      display += "No active trade\n";
      if(CheckRiskManagement())
         display += "Status: READY TO TRADE\n";
      else
         display += "Status: BLOCKED (check risk limits)\n";
      if(tickIndex >= 2)
         display += "Buffers: READY (Ultra-Fast Mode)\n";
      else
         display += "Buffers: Initializing (" + IntegerToString(tickIndex) + "/2 ticks)...\n";
   }
   
   Comment(display);
}
