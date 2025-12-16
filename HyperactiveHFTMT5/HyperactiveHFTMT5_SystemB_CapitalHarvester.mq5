#property copyright "Copyright 2025, System B - Capital Harvester"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"
#property description "Expendable EA - Fast capital extraction via price impulse bursts"
#property description "NO STOP LOSS - NO TRAILING - NO BREAKEVEN"
#property description "Equity profit snap + Time kill-switch only"

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
// - Open 2-3 trades instantly per impulse
// - Close ALL trades when floating profit ≥ $25 OR 15 seconds elapsed
// - Aggressive lot scaling: Balance / 1000 * 0.8
// - XAUUSD only, M1/tick-based
// =====================================================================================================

// ===== Input Parameters =====
input group "===== System B - Capital Harvester ====="
input int      MagicNumber = 202520;              // Magic number
input double   ImpulsePoints = 20.0;              // Minimum points for impulse (20)
input int      ImpulseTimeMs = 500;               // Time window in milliseconds (500)
input int      TradesPerImpulse = 2;              // Trades per impulse (2-3)
input double   ProfitSnapUSD = 25.0;              // Equity profit target in USD (25)
input int      KillSwitchSeconds = 15;            // Time kill-switch in seconds (15)
input double   LotMultiplier = 0.8;               // Lot scaling multiplier (0.8)
input double   MaxSpreadPoints = 50.0;            // Maximum spread in points (50)

// ===== Global Variables =====
string g_Symbol = "XAUUSD";                       // Trading symbol (hardcoded)
bool inTrade = false;                             // Flag for active trade group
ulong entryTimeStamp = 0;                         // Entry time for kill-switch (broker time)
int tickCount = 0;                                // Count of recorded ticks
ulong lastDebugTime = 0;                          // Last debug print time

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

// Profit and exit tracking
double maxFloatingProfit = 0.0;                   // Maximum floating profit (latch)
bool isClosing = false;                           // Closing lock flag

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
   
   Print("=== System B - Capital Harvester Initialized ===");
   Print("Symbol: ", g_Symbol);
   Print("POINT VALUE: ", point);
   Print("Min Lot: ", minLot, " | Max Lot: ", maxLot, " | Lot Step: ", lotStep);
   Print("Impulse: ", ImpulsePoints, " points (normalized: ", normalizedImpulsePoints, ") in ", ImpulseTimeMs, "ms");
   Print("Trades per impulse: ", TradesPerImpulse);
   Print("Profit snap: $", ProfitSnapUSD, " | Kill-switch: ", KillSwitchSeconds, "s");
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
   // Close all positions on EA removal
   CloseAllPositions();
   Print("System B - Capital Harvester deinitialized. Reason: ", reason);
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
   
   // Fix #4: Exit Logic Priority - check exits FIRST
   if(HasOpenPositions())
   {
      // We're in a trade - check exit conditions immediately
      CheckExitConditions();
      return; // Exit immediately, don't check for new entries
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
   
   // Fix #10: Use broker time for impulse detection
   int impulseDirection = DetectImpulse(currentPrice, tick.time_msc);
   if(impulseDirection != 0)
   {
      // Impulse detected - open trades
      Print("IMPULSE DETECTED: ", (impulseDirection == 1 ? "BUY" : "SELL"), " | Attempting to open trades...");
      OpenImpulseTrades(impulseDirection);
   }
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
// OPEN IMPULSE TRADES
// =====================================================================================================

void OpenImpulseTrades(int direction)
{
   // Fix #13: Trade Context Busy Protection
   if(trade.IsTradeContextBusy())
   {
      Print("TRADE CONTEXT BUSY — skipping impulse");
      return;
   }
   
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
   
   // Fix #6: Reset profit latch when opening new trades
   maxFloatingProfit = 0.0;
   
   // Fix #7: Staggered Trade Opening with Micro-Delays
   int openedCount = 0;
   for(int i = 0; i < TradesPerImpulse; i++)
   {
      if(i > 0)
         Sleep(3 + (i * 2)); // Stagger: 5ms, 7ms, 9ms...
      
      // Set magic number
      trade.SetExpertMagicNumber(MagicNumber);
      
      // Open trade (NO STOP LOSS, NO TAKE PROFIT)
      if(trade.PositionOpen(g_Symbol, orderType, lotSize, price, 0, 0, "SystemB Impulse"))
      {
         // Fix #9: Trade Result Checking
         if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
         {
            openedCount++;
            failCount = 0; // Reset on success
         }
         else
         {
            Print("ORDER FAIL: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
            // Fix #17: Broker Kill-Switch Detection
            failCount++;
         }
      }
      else
      {
         Print("Failed to open trade ", i + 1, ": ", trade.ResultRetcodeDescription());
         // Fix #17: Broker Kill-Switch Detection
         failCount++;
      }
      
      // Fix #17: Check for broker execution degradation
      if(failCount >= 3)
      {
         Print("BROKER EXECUTION DEGRADED — HALTING EA (", failCount, " consecutive failures)");
         ExpertRemove(); // Stop EA
         return;
      }
   }
   
   // Fix #12: Partial-Fill Detection
   if(openedCount < TradesPerImpulse)
   {
      Print("PARTIAL FILL — only ", openedCount, " of ", TradesPerImpulse, " filled. Closing leftovers.");
      CloseAllPositions();
      return;
   }
   
   // Only set state if all trades opened successfully
   if(openedCount == TradesPerImpulse)
   {
      inTrade = true;
      entryTimeStamp = tick.time_msc; // Fix #10: Use broker time
      Print("IMPULSE TRADES OPENED: ", openedCount, "x ", (direction == 1 ? "BUY" : "SELL"),
            " | Lot: ", lotSize, " | Price: ", price);
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
// CHECK EXIT CONDITIONS
// =====================================================================================================

void CheckExitConditions()
{
   bool shouldClose = false;
   string reason = "";
   
   // Fix #6: Profit Latch - Calculate total floating profit
   double totalFloatingProfit = 0.0;
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
               totalFloatingProfit += PositionGetDouble(POSITION_PROFIT);
            }
         }
      }
   }
   
   // Fix #6: Update max and check latch
   maxFloatingProfit = MathMax(maxFloatingProfit, totalFloatingProfit);
   
   if(maxFloatingProfit >= ProfitSnapUSD)
   {
      shouldClose = true;
      reason = "Profit snap latch: $" + DoubleToString(maxFloatingProfit, 2);
   }
   
   // Fix #16: Equity vs Floating Profit Mismatch (backup check)
   if(!shouldClose)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double equityDelta = equity - balance;
      
      if(equityDelta >= ProfitSnapUSD)
      {
         shouldClose = true;
         reason = "Equity snap: $" + DoubleToString(equityDelta, 2) + " (balance: $" + DoubleToString(balance, 2) + ")";
      }
   }
   
   // Fix #10: Check time kill-switch using broker time
   if(!shouldClose && entryTimeStamp > 0)
   {
      MqlTick tick;
      if(SymbolInfoTick(g_Symbol, tick))
      {
         ulong currentBrokerTime = tick.time_msc;
         ulong elapsedMs = currentBrokerTime - entryTimeStamp;
         double elapsedSeconds = elapsedMs / 1000.0;
         
         if(elapsedSeconds >= KillSwitchSeconds)
         {
            shouldClose = true;
            reason = "Kill-switch: " + DoubleToString(elapsedSeconds, 1) + "s elapsed";
         }
      }
   }
   
   if(shouldClose)
   {
      Print("EXIT TRIGGERED: ", reason);
      CloseAllPositions();
   }
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
   maxFloatingProfit = 0.0;        // Fix #6: Reset profit latch
   lastImpulsePrice = 0.0;         // Fix #2: Reset impulse lockout
   lastImpulseDirection = 0;       // Fix #11: Reset cooldown
   isClosing = false;              // Fix #15: Reset closing lock
   
   if(remaining == 0)
   {
      Print("CLOSED ALL POSITIONS: All positions verified closed");
   }
}
