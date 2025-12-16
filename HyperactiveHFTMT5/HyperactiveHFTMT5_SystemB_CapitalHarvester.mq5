#property copyright "Copyright 2025, System B - Capital Harvester"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"
#property description "Velocity-Harvesting EA - Captures explosive equity acceleration"
#property description "NO FIXED TP - NO EQUITY % - PURE VELOCITY PEAK + DECAY EXIT"
#property description "Progressive entry: Probe → Confirmation → Harvest"

#include <Trade/Trade.mqh>

CTrade trade;

// =====================================================================================================
// SYSTEM B — CAPITAL HARVESTER (EXPENDABLE EA)
// 
// CORE PHILOSOPHY:
// - Account is disposable
// - Goal is fast capital extraction, not longevity
// - Daily withdrawals expected
// - Broker bans are acceptable
// - No risk controls beyond spread filtering
//
// STRATEGY:
// - Detect price impulse bursts (≥20 points in 500ms)
// - Phase 1: Open 1 probe trade, start velocity tracking
// - Phase 2: Add trades when velocity confirms (>$3.5/sec)
// - Phase 3: Harvest - exit when velocity peaks and decays to 65%
// - Velocity-dependent basket scaling (1-15 trades based on equity + velocity)
// - XAUUSD only, live VPS tick behavior
// =====================================================================================================

// ===== Input Parameters =====
input group "===== System B - Velocity Harvester ====="
input int      MagicNumber = 202520;              // Magic number
input double   ImpulsePoints = 25.0;              // Minimum points for impulse (25 - stricter entry)
input int      ImpulseTimeMs = 500;               // Time window in milliseconds (500)
input double   LotMultiplier = 0.5;               // Lot scaling multiplier (0.5 - reduced risk)
input double   MaxSpreadPoints = 50.0;            // Maximum spread in points (50)

input group "===== Velocity Exit Settings (Profit-Only) ====="
input double   MinVelocityUSD = 3.5;              // MIN_VELOCITY threshold ($/second) - ONLY used when profitable
input double   DecayRatio = 0.65;                 // Decay ratio - exit when velocity drops to this % of peak (0.65)

input group "===== Velocity Confirmation Settings ====="
input double   MinVelocityForExpansion = 4.5;     // Velocity threshold for basket expansion ($/second) - higher than exit
input int      MinVelocityConfirmSamples = 2;     // Require velocity confirmed for N samples (250ms each) before expanding

input group "===== Abort Logic ====="
input double   SmallDamageCap = -10.0;            // Abort if equity drops this much (USD)
input int      DeadImpulseSeconds = 3;            // Abort time for winning trades (seconds)
input int      DeadImpulseSecondsLosing = 2;      // Abort time for losing trades - cut bad entries faster (seconds)
input int      FailsafeTimeSeconds = 8;           // Hard time cap failsafe (seconds)

// ===== Entry Phase State Machine =====
enum ENTRY_PHASE {
   PHASE_NONE,                                     // No active cycle
   PHASE_PROBE,                                    // 1 trade open, waiting for velocity
   PHASE_CONFIRMED,                                // Velocity > MIN_VELOCITY, can add trades
   PHASE_HARVEST                                   // Velocity peaked, waiting for decay exit
};

// ===== Global Variables =====
string g_Symbol = "XAUUSD";                       // Trading symbol (hardcoded)
bool inTrade = false;                             // Flag for active trade group
ulong entryTimeStamp = 0;                         // Entry time (broker time)
double entryEquity = 0.0;                         // Equity at entry (for damage cap)
int tickCount = 0;                                // Count of recorded ticks
ulong lastDebugTime = 0;                          // Last debug print time
ENTRY_PHASE currentPhase = PHASE_NONE;            // Current entry phase
int currentBasketSize = 0;                        // Current number of trades in basket
int baseTrades = 1;                               // Base basket size (floor(equity/2000), 1-5)
int maxBasketSize = 15;                           // Maximum basket size (3/6/15 based on equity)
int currentDirection = 0;                         // Current trade direction (1=BUY, -1=SELL)

// ===== Velocity Tracking Variables =====
double equity_now = 0.0;                          // Current equity sample
double equity_prev = 0.0;                         // Previous equity sample
ulong time_now = 0;                               // Current time (ms)
ulong time_prev = 0;                              // Previous time (ms)
double equity_velocity = 0.0;                     // Current equity velocity (USD/second)
double peak_velocity = 0.0;                       // Highest velocity seen this cycle
bool velocity_tracking_active = false;            // Flag to start velocity tracking
bool first_sample = true;                         // First sample flag (no prev data)
ulong last_sample_time = 0;                       // Last equity sample time (ms) for 250ms intervals
bool isLosingState = false;                       // True when equity_velocity < 0 (equity declining)

// ===== Velocity Trend & Confirmation Tracking =====
enum VELOCITY_TREND {
   VEL_TREND_RISING,
   VEL_TREND_STABLE,
   VEL_TREND_DECLINING
};
VELOCITY_TREND velocity_trend = VEL_TREND_STABLE;
int velocity_confirmed_samples = 0;               // Consecutive samples where velocity >= threshold
double prev_velocity = 0.0;                       // Previous velocity for trend detection

// Tick history for impulse detection (circular buffer)
double tickPrices[];                              // Price history array
ulong tickTimes[];                                // OS timestamp history array (for debug)
ulong tickTimeMSC[];                              // Broker timestamp history array (for accuracy)
int tickIndex = 0;                                // Circular buffer index
int maxTicks = 1000;                              // Maximum ticks to store

// Impulse lockout and cooldown
double lastImpulsePrice = 0.0;                    // Last impulse price (lockout)
ulong lastImpulseTime = 0;                        // Last impulse time
int lastImpulseDirection = 0;                     // Last impulse direction (cooldown)

// Trade state tracking
bool isClosing = false;                           // Closing lock flag
bool velocity_rising = false;                     // Flag if velocity is currently rising

// Broker failure tracking
int failCount = 0;                                // Consecutive trade failures

// Point normalization
double normalizedImpulsePoints = 20.0;            // Normalized impulse points for broker

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   // Fix #20: Disable Strategy Tester explicitly
   if(MQLInfoInteger(MQL_TESTER))
   {
      Print("SYSTEM B DISABLED IN STRATEGY TESTER — Live VPS execution only");
      return INIT_FAILED;
   }
   
   // Validate g_Symbol
   if(!SymbolInfoInteger(g_Symbol, SYMBOL_SELECT))
   {
      Print("ERROR: Symbol ", g_Symbol, " not available!");
      return INIT_FAILED;
   }
   
   // Set g_Symbol
   if(!SymbolSelect(g_Symbol, true))
   {
      Print("ERROR: Failed to select g_Symbol ", g_Symbol);
      return INIT_FAILED;
   }
   
   // Initialize arrays (Fix #1: Circular buffer + Fix #10: Broker timestamp)
   ArrayResize(tickPrices, maxTicks);
   ArrayResize(tickTimes, maxTicks);
   ArrayResize(tickTimeMSC, maxTicks);
   ArrayInitialize(tickPrices, 0.0);
   ArrayInitialize(tickTimes, 0);
   ArrayInitialize(tickTimeMSC, 0);
   
   // Configure CTrade
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   // Auto-detect filling mode for best execution
   ENUM_ORDER_TYPE_FILLING filling = (ENUM_ORDER_TYPE_FILLING)SymbolInfoInteger(g_Symbol, SYMBOL_FILLING_MODE);
   if(filling == ORDER_FILLING_FOK || filling == ORDER_FILLING_IOC)
   {
      trade.SetTypeFilling(filling);
   }
   else
   {
      trade.SetTypeFilling(ORDER_FILLING_IOC); // Default to IOC for fast execution
   }
   trade.SetAsyncMode(false);
   
   // Validate broker settings
   double minLot = SymbolInfoDouble(g_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(g_Symbol, SYMBOL_VOLUME_STEP);
   
   // Fix #19: Gold Point Definition Fix (normalize impulse points)
   double point = SymbolInfoDouble(g_Symbol, SYMBOL_POINT);
   normalizedImpulsePoints = ImpulsePoints * (0.01 / point);
   
   // Setup timer (1 second minimum - we'll check for 250ms intervals inside OnTimer)
   EventSetTimer(1);
   
   Print("=== System B - Velocity Harvester Initialized ===");
   Print("Symbol: ", g_Symbol);
   Print("POINT VALUE: ", point);
   Print("Min Lot: ", minLot, " | Max Lot: ", maxLot, " | Lot Step: ", lotStep);
   Print("Impulse: ", ImpulsePoints, " points (normalized: ", normalizedImpulsePoints, ") in ", ImpulseTimeMs, "ms");
   Print("Velocity exit: MIN=$", MinVelocityUSD, "/sec, DECAY=", DecayRatio);
   Print("Abort logic: Damage=$", SmallDamageCap, ", Dead=", DeadImpulseSeconds, "s, Failsafe=", FailsafeTimeSeconds, "s");
   Print("Lot multiplier: ", LotMultiplier);
   Print("Max spread: ", MaxSpreadPoints, " points");
   
   // Check AutoTrading
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("WARNING: AutoTrading is disabled in terminal settings!");
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("WARNING: AutoTrading is disabled for this EA!");
   }
   
   return INIT_SUCCEEDED;
}

// =====================================================================================================
// DEINITIALIZATION
// =====================================================================================================

void OnDeinit(const int reason)
{
   // Kill timer
   EventKillTimer();
   
   // Close all positions on EA removal
   CloseAllPositions();
   Print("System B - Velocity Harvester deinitialized. Reason: ", reason);
}

// =====================================================================================================
// MAIN TICK HANDLER
// =====================================================================================================

void OnTick()
{
   // Get current tick
   MqlTick tick;
   if(!SymbolInfoTick(g_Symbol, tick))
   {
      return; // Skip if tick data unavailable
   }
   
   // Entry detection only - exit logic moved to OnTimer()
   if(HasOpenPositions())
   {
      // We're in a trade - skip entry detection (exits handled in OnTimer)
      return;
   }
   
   // Fix #15: Hard Guard - Never Stack Impulses
   if(isClosing)
   {
      return; // Don't open new trades while closing
   }
   
   // Fix #18: VPS Load Protection - CPU yield every 50 ticks
   if((tickCount % 50) == 0)
   {
      Sleep(1);
   }
   
   ulong currentTime = GetTickCount64();
   double currentPrice = (tick.bid + tick.ask) / 2.0; // Use mid price for impulse detection
   
   // Fix #1 & #10: Record tick with circular buffer and broker time
   RecordTick(currentPrice, currentTime, tick.time_msc);
   
   // Debug print every 5 seconds
   if(currentTime - lastDebugTime > 5000)
   {
      double point = SymbolInfoDouble(g_Symbol, SYMBOL_POINT);
      double spreadPoints = (tick.ask - tick.bid) / point;
      Print("DEBUG: Ticks recorded: ", tickCount, " | Spread: ", spreadPoints, " points | Price: ", currentPrice);
      lastDebugTime = currentTime;
   }
   
   // Reset state (no open positions)
   inTrade = false;
   entryTimeStamp = 0;
   currentPhase = PHASE_NONE;
   velocity_tracking_active = false;
   
   // Fix #10: Use broker time for impulse detection
   int impulseDirection = DetectImpulse(currentPrice, tick.time_msc);
   if(impulseDirection != 0)
   {
      // Impulse detected - open probe trade (Phase 1)
      Print("IMPULSE DETECTED: ", (impulseDirection == 1 ? "BUY" : "SELL"), " | Opening probe trade...");
      OpenProbeTrade(impulseDirection);
   }
}

// =====================================================================================================
// TIMER HANDLER - Equity Velocity Sampling (250ms intervals)
// =====================================================================================================

void OnTimer()
{
   // Only process if we have open positions
   if(!HasOpenPositions())
   {
      // Reset velocity tracking when no positions
      if(velocity_tracking_active)
      {
         ResetVelocityTracking();
      }
      return;
   }
   
   // Check if 250ms has elapsed since last sample
   ulong current_time_ms = GetTickCount64();
   if(last_sample_time == 0)
   {
      last_sample_time = current_time_ms;
   }
   
   ulong elapsed_ms = current_time_ms - last_sample_time;
   
   // Only sample every 250ms
   if(elapsed_ms >= 250)
   {
      // Sample equity velocity
      SampleEquityVelocity();
      last_sample_time = current_time_ms;
   }
   
   // PRIORITY 1: Per-trade profit exits (velocity decay for profitable trades)
   CheckPerTradeProfitExits();
   
   // PRIORITY 2: Loss abort logic (only for losing basket)
   if(CheckAbortConditions())
      return;
   
   // PRIORITY 3: Velocity confirmation (basket expansion)
   if(currentPhase == PHASE_PROBE)
   {
      CheckVelocityConfirmation();
   }
   
   // Check basket expansion (if in confirmed phase)
   if(currentPhase == PHASE_CONFIRMED)
   {
      CheckBasketExpansion();
   }
   
   // PRIORITY 4: Failsafe time check (last resort, closes everything)
   CheckFailsafeTime();
}

// =====================================================================================================
// RECORD TICK (Fix #1: Circular Buffer + Fix #10: Broker Timestamp)
// =====================================================================================================

void RecordTick(double price, ulong osTime, ulong brokerTime)
{
   // Circular buffer - O(1) insertion
   tickPrices[tickIndex] = price;
   tickTimes[tickIndex] = osTime;      // Keep OS time for debug
   tickTimeMSC[tickIndex] = brokerTime; // Broker time for accuracy
   tickIndex = (tickIndex + 1) % maxTicks;
   tickCount++;
}

// =====================================================================================================
// DETECT IMPULSE (Fix #1: Circular Buffer Scan + Fix #2: Impulse Lockout + Fix #11: One-Side Cooldown + Fix #10: Broker Time + Fix #19: Normalized Points)
// Returns: 1 for BUY, -1 for SELL, 0 for no impulse
// =====================================================================================================

int DetectImpulse(double currentPrice, ulong currentBrokerTime)
{
   // Need at least some tick history
   if(tickCount < 10)
   {
      return 0; // Not enough history yet
   }
   
   // Fix #10: Use broker time for impulse detection
   ulong targetTime = currentBrokerTime - ImpulseTimeMs;
   double priceFromPast = 0.0;
   bool found = false;
   
   // Fix #1: Search backwards through circular buffer
   ulong closestTime = 0;
   int closestIndex = -1;
   
   // Start from most recent tick (tickIndex - 1) and search backwards
   for(int offset = 0; offset < maxTicks; offset++)
   {
      int i = (tickIndex - 1 - offset + maxTicks) % maxTicks;
      
      if(tickTimeMSC[i] == 0)
      {
         continue; // Skip empty slots
      }
      
      if(tickTimeMSC[i] <= targetTime)
      {
         // Found a tick at or before target time - use the most recent one
         if(closestIndex == -1 || tickTimeMSC[i] > closestTime)
         {
            closestTime = tickTimeMSC[i];
            closestIndex = i;
            priceFromPast = tickPrices[i];
            found = true;
         }
      }
   }
   
   if(!found || priceFromPast == 0.0)
   {
      return 0; // Not enough history
   }
   
   // Calculate price movement in points
   double point = SymbolInfoDouble(g_Symbol, SYMBOL_POINT);
   double priceMovement = MathAbs(currentPrice - priceFromPast);
   double movementPoints = priceMovement / point;
   
   // Fix #19: Use normalized impulse points
   // Check if movement meets impulse threshold
   if(movementPoints >= normalizedImpulsePoints)
   {
      // Determine direction
      int direction = (currentPrice > priceFromPast) ? 1 : -1;
      
      // Fix #2: Impulse lockout - prevent re-fire on same leg
      if(lastImpulsePrice != 0.0)
      {
         double priceRetrace = MathAbs(currentPrice - lastImpulsePrice);
         double retracePoints = priceRetrace / point;
         if(retracePoints < normalizedImpulsePoints)
         {
            return 0; // Prevent re-fire on same leg
         }
      }
      
      // Fix #11: One-side cooldown - prevent flip-flopping
      if(direction == -lastImpulseDirection && lastImpulseDirection != 0)
      {
         return 0; // Block opposite direction immediately after previous
      }
      
      // Update lockout and cooldown
      lastImpulsePrice = currentPrice;
      lastImpulseTime = currentBrokerTime;
      lastImpulseDirection = direction;
      
      return direction;
   }
   
   return 0; // No impulse
}

// =====================================================================================================
// CHECK IF HAS OPEN POSITIONS
// =====================================================================================================

bool HasOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetString(POSITION_SYMBOL) == g_Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
               return true;
            }
         }
      }
   }
   return false;
}

// =====================================================================================================
// OPEN PROBE TRADE (Phase 1 - Single Trade Entry)
// =====================================================================================================

void OpenProbeTrade(int direction)
{
   // Get current price first (needed for spread check)
   MqlTick tick;
   if(!SymbolInfoTick(g_Symbol, tick))
   {
      return;
   }
   
   // Fix #3: Real Spread Check Using Live Tick Data
   double point = SymbolInfoDouble(g_Symbol, SYMBOL_POINT);
   double spreadPoints = (tick.ask - tick.bid) / point;
   if(spreadPoints > MaxSpreadPoints)
   {
      Print("BLOCKED: Spread too wide: ", spreadPoints, " points (max: ", MaxSpreadPoints, ")");
      return; // Spread too wide
   }
   
   // Fix #14: Dynamic Slippage Control
   int deviation = 15; // Default
   if(spreadPoints > 30)
      deviation = 30; // Wider deviation for volatile spreads
   else if(spreadPoints > 20)
      deviation = 20;
   
   trade.SetDeviationInPoints(deviation);
   
   // Check AutoTrading
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("BLOCKED: AutoTrading disabled in terminal!");
      return;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("BLOCKED: AutoTrading disabled for EA!");
      return;
   }
   
   // Calculate lot size
   double lotSize = CalculateLotSize();
   if(lotSize <= 0)
   {
      Print("ERROR: Invalid lot size calculated: ", lotSize);
      return;
   }
   
   double price = (direction == 1) ? tick.ask : tick.bid;
   ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   // Set magic number
   trade.SetExpertMagicNumber(MagicNumber);
   
   // Open single probe trade (NO STOP LOSS, NO TAKE PROFIT)
   if(trade.PositionOpen(g_Symbol, orderType, lotSize, price, 0, 0, "SystemB Probe"))
   {
      if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
      {
         // Success - initialize velocity tracking
         inTrade = true;
         currentPhase = PHASE_PROBE;
         currentDirection = direction;
         currentBasketSize = 1;
         entryTimeStamp = tick.time_msc;
         entryEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         
         // Initialize velocity tracking
         ResetVelocityTracking();
         velocity_tracking_active = true;
         first_sample = true;
         
         // Calculate basket sizing based on equity
         CalculateBasketSize();
         
         // Update actual basket size
         UpdateBasketSize();
         
         failCount = 0; // Reset on success
         Print("PROBE TRADE OPENED: ", (direction == 1 ? "BUY" : "SELL"),
               " | Lot: ", lotSize, " | Price: ", price, " | Base: ", baseTrades, " | Max: ", maxBasketSize);
      }
      else
      {
         Print("ORDER FAIL: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
         failCount++;
      }
   }
   else
   {
      Print("Failed to open probe trade: ", trade.ResultRetcodeDescription());
      failCount++;
   }
   
   // Check for broker execution degradation
   if(failCount >= 3)
   {
      Print("BROKER EXECUTION DEGRADED — HALTING EA (", failCount, " consecutive failures)");
      ExpertRemove(); // Stop EA
      return;
   }
}

// =====================================================================================================
// CALCULATE LOT SIZE
// Formula: Balance / 1000 * LotMultiplier
// =====================================================================================================

double CalculateLotSize()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lotSize = (balance / 1000.0) * LotMultiplier;
   
   // Get broker limits
   double minLot = SymbolInfoDouble(g_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(g_Symbol, SYMBOL_VOLUME_STEP);
   
   // Clamp to limits
   if(lotSize < minLot)
   {
      lotSize = minLot;
   }
   if(lotSize > maxLot)
   {
      lotSize = maxLot;
   }
   
   // Round to lot step
   if(lotStep > 0)
   {
      lotSize = MathFloor(lotSize / lotStep) * lotStep;
   }
   
   // Fix #8: Lot Size Normalization with NormalizeDouble
   lotSize = NormalizeDouble(lotSize, 2);
   
   return lotSize;
}

// =====================================================================================================
// CALCULATE BASKET SIZE (Velocity-Dependent Scaling)
// =====================================================================================================

void CalculateBasketSize()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Base trades: clamp(floor(Equity / 3000), 1, 3) - reduced risk
   baseTrades = (int)MathMax(1, MathMin(3, MathFloor(equity / 3000.0)));
   
   // Max basket size based on equity - reduced risk
   if(equity < 500)
      maxBasketSize = 2;
   else if(equity < 3000)
      maxBasketSize = 4;
   else
      maxBasketSize = 8;
   
   // Note: We start with 1 trade (probe), then:
   // - When velocity confirms (>MIN_VELOCITY), we can add up to baseTrades
   // - If velocity is strong (>= STRONG_VELOCITY) and rising, we can expand beyond baseTrades up to maxBasketSize
}

// =====================================================================================================
// RESET VELOCITY TRACKING
// =====================================================================================================

void ResetVelocityTracking()
{
   equity_now = 0.0;
   equity_prev = 0.0;
   time_now = 0;
   time_prev = 0;
   equity_velocity = 0.0;
   peak_velocity = 0.0;
   velocity_tracking_active = false;
   first_sample = true;
   velocity_rising = false;
   last_sample_time = 0;
   isLosingState = false;
   velocity_confirmed_samples = 0;
   prev_velocity = 0.0;
   velocity_trend = VEL_TREND_STABLE;
}

// =====================================================================================================
// SAMPLE EQUITY VELOCITY (Called every 250ms from OnTimer)
// =====================================================================================================

void SampleEquityVelocity()
{
   if(!velocity_tracking_active)
      return;
   
   // Get current equity and time
   equity_now = AccountInfoDouble(ACCOUNT_EQUITY);
   time_now = GetTickCount64();
   
   // Handle first sample
   if(first_sample)
   {
      equity_prev = equity_now;
      time_prev = time_now;
      first_sample = false;
      return; // No velocity calculation on first sample
   }
   
   // Calculate time delta in seconds
   double delta_time_ms = (double)(time_now - time_prev);
   double delta_time_seconds = delta_time_ms / 1000.0;
   
   // Avoid division by zero
   if(delta_time_seconds < 0.001)
      return;
   
   // Calculate velocity: (equity_now - equity_prev) / delta_time_seconds
   equity_velocity = (equity_now - equity_prev) / delta_time_seconds;
   
   // Track losing state (negative velocity = equity declining)
   isLosingState = (equity_velocity < 0);
   
   // Track velocity trend (rising/stable/declining)
   if(!first_sample && prev_velocity != 0.0)
   {
      if(equity_velocity > prev_velocity * 1.05)      // 5% increase = rising
         velocity_trend = VEL_TREND_RISING;
      else if(equity_velocity < prev_velocity * 0.95) // 5% decrease = declining
         velocity_trend = VEL_TREND_DECLINING;
      else
         velocity_trend = VEL_TREND_STABLE;
   }
   prev_velocity = equity_velocity;
   
   // Track sustained velocity confirmation for basket expansion
   if(equity_velocity >= MinVelocityForExpansion)
      velocity_confirmed_samples++;
   else
      velocity_confirmed_samples = 0; // Reset if drops below threshold
   
   // Update peak velocity (track highest velocity seen)
   if(equity_velocity > peak_velocity)
   {
      peak_velocity = equity_velocity;
      velocity_rising = true;
   }
   else if(equity_velocity < peak_velocity)
   {
      velocity_rising = false;
   }
   
   // Update previous values for next sample
   equity_prev = equity_now;
   time_prev = time_now;
}

// =====================================================================================================
// CHECK PER-TRADE PROFIT EXITS (Velocity Decay for Profitable Trades)
// =====================================================================================================

void CheckPerTradeProfitExits()
{
   // Velocity exits are profit-only - check if velocity has decayed
   // Only evaluate if we've seen a peak velocity that meets threshold
   if(peak_velocity < MinVelocityUSD)
      return; // No velocity peak yet, skip
   
   // Check if velocity has decayed below decay ratio
   double decay_threshold = peak_velocity * DecayRatio;
   if(equity_velocity > decay_threshold)
      return; // Velocity hasn't decayed yet, skip
   
   // Iterate through positions and close profitable ones individually
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == g_Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            double tradeProfit = PositionGetDouble(POSITION_PROFIT);
            
            // Only close if trade is profitable (velocity is harvest signal, not loss management)
            if(tradeProfit > 0)
            {
               Print("PER-TRADE PROFIT EXIT: Ticket=", ticket, " Profit=$", DoubleToString(tradeProfit, 2),
                     " Velocity decayed (peak=", DoubleToString(peak_velocity, 2), " current=", DoubleToString(equity_velocity, 2), ")");
               trade.PositionClose(ticket);
            }
         }
      }
   }
}

// =====================================================================================================
// CHECK ABORT CONDITIONS (DISABLED - Only Close Profitable Trades)
// =====================================================================================================
// NOTE: Abort conditions are disabled to ensure ONLY profitable trades are closed.
// Losing trades are never closed - they run until they become profitable or are closed manually.

bool CheckAbortConditions()
{
   // ABORT CONDITIONS DISABLED - Always return false (never abort)
   // Only per-trade profit exits can close trades, and only profitable ones
   // Losing trades are never closed - they run until they become profitable or are closed manually
   return false;
}

// =====================================================================================================
// CHECK VELOCITY CONFIRMATION (Progressive Basket Scaling)
// =====================================================================================================

void CheckVelocityConfirmation()
{
   // Only process if we're in probe phase
   if(currentPhase != PHASE_PROBE)
      return;
   
   // Require velocity confirmed for multiple samples (sustained momentum) AND not declining
   if(velocity_confirmed_samples >= MinVelocityConfirmSamples && velocity_trend != VEL_TREND_DECLINING)
   {
      // Velocity confirmed - move to confirmed phase
      currentPhase = PHASE_CONFIRMED;
      Print("VELOCITY CONFIRMED (sustained): ", DoubleToString(equity_velocity, 2), 
            " $/sec for ", velocity_confirmed_samples, " samples - Moving to Phase 2");
      
      // Add second trade when velocity first confirms (if baseTrades > 1)
      UpdateBasketSize(); // Sync actual basket size
      if(currentBasketSize == 1 && baseTrades > 1)
      {
         AddToBasket(); // Add trade #2 to reach base
      }
   }
}

// =====================================================================================================
// UPDATE BASKET SIZE (Sync with actual positions)
// =====================================================================================================

void UpdateBasketSize()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetString(POSITION_SYMBOL) == g_Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
               count++;
            }
         }
      }
   }
   currentBasketSize = count;
}

// =====================================================================================================
// CHECK BASKET EXPANSION (Called from OnTimer when in confirmed phase)
// =====================================================================================================

void CheckBasketExpansion()
{
   // Only add trades if we're in confirmed phase (not harvest)
   if(currentPhase != PHASE_CONFIRMED)
      return;
   
   // Never expand if velocity is declining (too late to add trades)
   if(velocity_trend == VEL_TREND_DECLINING)
   {
      currentPhase = PHASE_HARVEST;
      Print("PHASE 3: HARVEST - Velocity declining, stopping basket expansion");
      return;
   }
   
   // If velocity peaked and is declining, move to harvest phase (stop adding)
   if(!velocity_rising && peak_velocity >= MinVelocityUSD)
   {
      currentPhase = PHASE_HARVEST;
      Print("PHASE 3: HARVEST - Velocity peaked at ", DoubleToString(peak_velocity, 2), " $/sec - Stopping basket expansion");
      return;
   }
   
   UpdateBasketSize(); // Sync actual basket size
   
   // Continue adding to reach baseTrades if not there yet
   if(currentBasketSize < baseTrades && velocity_rising)
   {
      AddToBasket();
      return;
   }
   
   // Calculate strong velocity threshold (for basket expansion beyond base)
   double strongVelocity = MinVelocityUSD * 1.5; // ~$5.25/sec
   
   // Only add beyond baseTrades if velocity is strong AND rising AND we haven't reached maxBasketSize
   if(equity_velocity >= strongVelocity && velocity_rising && currentBasketSize >= baseTrades && currentBasketSize < maxBasketSize)
   {
      // Add one trade at a time when velocity is strong and rising (beyond base)
      AddToBasket();
   }
}

// =====================================================================================================
// ADD TO BASKET (Progressive Trade Addition)
// =====================================================================================================

void AddToBasket()
{
   if(isClosing)
      return;
   
   // Get current price
   MqlTick tick;
   if(!SymbolInfoTick(g_Symbol, tick))
      return;
   
   // Check spread
   double point = SymbolInfoDouble(g_Symbol, SYMBOL_POINT);
   double spreadPoints = (tick.ask - tick.bid) / point;
   if(spreadPoints > MaxSpreadPoints)
      return; // Spread too wide
   
   // Calculate lot size
   double lotSize = CalculateLotSize();
   if(lotSize <= 0)
      return;
   
   double price = (currentDirection == 1) ? tick.ask : tick.bid;
   ENUM_ORDER_TYPE orderType = (currentDirection == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   // Set magic number
   trade.SetExpertMagicNumber(MagicNumber);
   
   // Open additional trade
   if(trade.PositionOpen(g_Symbol, orderType, lotSize, price, 0, 0, "SystemB Add"))
   {
      if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
      {
         UpdateBasketSize(); // Sync actual basket size
         Print("BASKET EXPANDED: Trade #", currentBasketSize, " added | Lot: ", lotSize, 
               " | Velocity: ", DoubleToString(equity_velocity, 2), " $/sec | Phase: ", 
               (currentPhase == PHASE_CONFIRMED ? "Confirmed" : "Probe"));
      }
      else
      {
         Print("Failed to add trade: ", trade.ResultRetcodeDescription());
      }
   }
   else
   {
      Print("Failed to add trade: ", trade.ResultRetcodeDescription());
   }
}

// =====================================================================================================
// CHECK FAILSAFE TIME (DISABLED - Only Close Profitable Trades)
// =====================================================================================================
// NOTE: Failsafe time is disabled to ensure ONLY profitable trades are closed.
// Losing trades are never closed - they run until they become profitable or are closed manually.

void CheckFailsafeTime()
{
   // FAILSAFE TIME DISABLED - Do nothing (never close trades based on time limit)
   // Only per-trade profit exits can close trades, and only profitable ones
   return;
   
   // OLD CODE (DISABLED - was closing losing trades):
   // Failsafe time limit is disabled to ensure only profitable trades close via CheckPerTradeProfitExits()
}

// =====================================================================================================
// CHECK EXIT CONDITIONS (DEPRECATED - Replaced by velocity system)
// =====================================================================================================

// This function is deprecated - all exit logic moved to OnTimer()
void CheckExitConditions()
{
   // Empty - all exit logic handled in OnTimer() via:
   // - CheckPerTradeProfitExits() - per-trade profit exits (velocity decay) - ONLY closes profitable trades
   // - CheckAbortConditions() - DISABLED (never closes trades)
   // - CheckFailsafeTime() - DISABLED (never closes trades)
   // Only profitable trades are closed when velocity decays
}

// =====================================================================================================
// CLOSE ALL POSITIONS
// =====================================================================================================

void CloseAllPositions()
{
   // Fix #15: Hard Guard - Set closing lock
   isClosing = true;
   
   // Fix #5: Faster Position Closing Using Symbol Close
   if(trade.PositionClose(g_Symbol))
   {
      Print("CLOSED ALL POSITIONS for ", g_Symbol);
   }
   else
   {
      Print("Close failed: ", trade.ResultRetcodeDescription());
      // Fallback: close individually if symbol close fails
   }
   
   // Verify no leftovers
   int remaining = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetString(POSITION_SYMBOL) == g_Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
               remaining++;
               // Force close individual position
               trade.PositionClose(ticket);
            }
         }
      }
   }
   
   if(remaining > 0)
   {
      Print("WARNING: ", remaining, " positions still open after close");
   }
   
   // Reset all state
   inTrade = false;
   entryTimeStamp = 0;
   entryEquity = 0.0;
   currentPhase = PHASE_NONE;
   currentBasketSize = 0;
   baseTrades = 1;
   maxBasketSize = 15;
   currentDirection = 0;
   lastImpulsePrice = 0.0;         // Fix #2: Reset impulse lockout
   lastImpulseDirection = 0;       // Fix #11: Reset cooldown
   isClosing = false;              // Fix #15: Reset closing lock
   
   // Reset velocity tracking
   ResetVelocityTracking();
   
   if(remaining == 0)
   {
      Print("CLOSED ALL POSITIONS: All positions verified closed");
   }
}

