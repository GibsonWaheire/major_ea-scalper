#property copyright "Copyright 2025, Hyperactive Pulse Scalper V2 - Ultra High Frequency Micro-Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "4.00"
#property strict

// =====================================================================================================
// HYPERACTIVE PULSE SCALPER V3 - ULTRA HIGH FREQUENCY MICRO-SCALPER
// Strategy: True HFT micro-scalper using 3-in-1 entry system
// - Tick-based only (no candles, no indicators)
// - 3 entry models: Tick Momentum, Micro Pullback, Spread Compression
// - Ultra-fast exits (3-10 seconds)
// - Fixed lot sizing for speed
// - Dozens to hundreds of trades per hour
// - Perfect for XAUUSD HFT scalping
// =====================================================================================================

// ===== Trading Settings =====
input double   RiskPercentPerTrade   = 5.0;    // Risk % per trade (5% default)
input int      MagicNumber           = 202503;
input int      MaxHoldSeconds        = 5;      // Maximum hold time (3-10 seconds for HFT)

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
   int      ticket;
   double   entryPrice;
   datetime openTime;
   int      direction;  // 1=BUY, -1=SELL
   double   lotSize;
   double   previousProfit;  // Track previous tick profit for spike detection
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

// =====================================================================================================
// MODULE 1: SMART PENDING ORDERS (STAGING SYSTEM) - GLOBAL VARIABLES
// =====================================================================================================

int pendingOrderTicket1 = 0;  // First pending order ticket
int pendingOrderTicket2 = 0;  // Second pending order ticket
datetime pendingOrderStartTime = 0;  // Time when pending orders were created
int pendingOrderDirection = 0;  // 1=BUY, -1=SELL, 0=none

// =====================================================================================================
// MODULE 2: HARD EQUITY STOP - GLOBAL VARIABLES
// =====================================================================================================

double equityStart = 0.0;  // Starting equity value
bool equityStopActive = false;  // Flag to stop trading after equity stop triggers

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
   
   // ===== MODULE 2: Initialize Equity Stop at the very top =====
   equityStart = AccountEquity();
   equityStopActive = false;
   Print("Equity Safety Stop: Initialized at $", DoubleToString(equityStart, 2), " | Profit Stop: +20% | Drawdown Stop: -20%");
   
   // Initialize symbol data
   digits = Digits;
   pipToPoint = Point;
   if(digits == 3 || digits == 5)
      pipToPoint *= 10.0;
   
   // Initialize trading state
   hasActiveTrade = false;
   
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
   
   // ===== MODULE 1: Initialize pending orders system =====
   pendingOrderTicket1 = 0;
   pendingOrderTicket2 = 0;
   pendingOrderStartTime = 0;
   pendingOrderDirection = 0;
   
   Print("EA initialized - ready for ultra high-frequency trading");
   Print("Smart Pending Orders: ENABLED (2-stage entry system)");
   
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
      Print("⚠ AutoTrading is DISABLED - Please enable AutoTrading button in MT4!");
   }
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // Clean up pending orders on deinit
   DeleteAllPendingOrders();
   Print("HFT Micro-Scalper V3 deinitialized. Reason: ", reason);
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   // ===== MODULE 2: HARD EQUITY STOP - CHECK AT THE VERY TOP BEFORE ANYTHING ELSE =====
   if(!equityStopActive)
   {
      double currentEquity = AccountEquity();
      double changePercent = ((currentEquity - equityStart) / equityStart) * 100.0;
      
      if(changePercent >= 20.0 || changePercent <= -20.0)
      {
         Print("========================================");
         Print("EQUITY SAFETY STOP TRIGGERED!");
         Print("Starting Equity: $", DoubleToString(equityStart, 2));
         Print("Current Equity: $", DoubleToString(currentEquity, 2));
         Print("Change: ", DoubleToString(changePercent, 2), "%");
         Print("========================================");
         
         equityStopActive = true;
         CloseAllTradesImmediate();
         
         Print("Trading STOPPED - Equity safety stop activated");
         Comment("\n=== EQUITY SAFETY STOP ACTIVATED ===\nChange: " + DoubleToString(changePercent, 2) + "%\nTrading STOPPED");
         return;  // Exit OnTick completely - no more trading
      }
   }
   else
   {
      // Equity stop is active - do nothing
      return;
   }
   
   // Update tick buffers
   UpdateTickBuffers();
   
   // ===== MODULE 1: Check if any pending orders became market orders =====
   CheckPendingOrdersStatus();
   
   // ===== CRITICAL: Delete ALL pending orders if we have an active trade =====
   // This ensures no pending orders remain when a trade is active
   if(hasActiveTrade)
   {
      DeleteAllPendingOrdersByScan();  // Scan and delete ALL pending orders
   }
   
   // Manage active trade (ultra-fast exits) - MUST run immediately after pending order check
   if(hasActiveTrade)
   {
      ManageHFTrade();
   }
   
   // ===== MODULE 1: Manage pending orders (timeout check, cleanup) =====
   ManagePendingOrders();
   
   // Check for signals even when pending orders exist (to detect opposite signals)
   int direction = 0;
   
   if(!hasActiveTrade)
   {
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
               " | UsePatternStrategy=", UsePatternStrategy,
               " | Pending1=", pendingOrderTicket1, " | Pending2=", pendingOrderTicket2);
      }
      
      // More frequent logging when signal detected
      if(direction != 0)
      {
         Print("SIGNAL DETECTED: ", (direction == 1 ? "BUY" : "SELL"), 
               " | HasActiveTrade: ", hasActiveTrade,
               " | PendingOrders: ", (pendingOrderTicket1 > 0 ? "1" : "0"), "/", (pendingOrderTicket2 > 0 ? "1" : "0"));
      }
      
      // ===== MODULE 1: Check for opposite signal when pending orders exist =====
      if(direction != 0 && (pendingOrderTicket1 > 0 || pendingOrderTicket2 > 0))
      {
         // New signal detected while pending orders exist
         if(pendingOrderDirection != 0 && pendingOrderDirection != direction)
         {
            // Opposite signal detected - delete all pending orders
            Print("Opposite signal detected: ", (direction == 1 ? "BUY" : "SELL"), 
                  " (was ", (pendingOrderDirection == 1 ? "BUY" : "SELL"), ") - Deleting pending orders...");
            DeleteAllPendingOrders();
         }
         else
         {
            // Same direction signal - don't create new pending orders
            direction = 0;
         }
      }
      
      // Create new pending orders if no active trade and no pending orders
      if(direction != 0 && !hasActiveTrade && pendingOrderTicket1 == 0 && pendingOrderTicket2 == 0)
      {
         Print("Signal detected: ", (direction == 1 ? "BUY" : "SELL"), " - Staging pending orders...");
         
         // ===== MODULE 1: Use Smart Entry Staging instead of direct OpenHFTrade =====
         SmartEntryStaging(direction);
      }
   }
   
   // Update display
   UpdateDisplay();
}

// =====================================================================================================
// MODULE 1: SMART PENDING ORDERS (STAGING SYSTEM)
// =====================================================================================================

void SmartEntryStaging(int signal)
{
   if(signal == 0)
      return;
   
   // Delete any existing pending orders from opposite direction
   if(pendingOrderDirection != 0 && pendingOrderDirection != signal)
   {
      DeleteAllPendingOrders();
   }
   
   // If there are already pending orders in the same direction, don't create new ones
   if(pendingOrderTicket1 != 0 || pendingOrderTicket2 != 0)
      return;
   
   // Check if AutoTrading is enabled
   if(!IsTradeAllowed())
   {
      Print("ERROR: Cannot create pending orders - AutoTrading is disabled!");
      return;
   }
   
   // Calculate lot size
   double tradeLots = CalculateRiskLotSize();
   if(tradeLots <= 0.0)
   {
      Print("ERROR: Invalid lot size calculated");
      return;
   }
   
   // Get broker's minimum stop level (in points)
   int minStopLevel = (int)MarketInfo(Symbol(), MODE_STOPLEVEL);
   double minStopDistance = minStopLevel * Point;
   if(minStopDistance <= 0.0)
      minStopDistance = Point;  // Default to 1 point if not available
   
   double price1 = 0.0;
   double price2 = 0.0;
   int orderType1 = 0;
   int orderType2 = 0;
   
   if(signal == 1)  // BUY signal
   {
      // Create two BUYSTOP orders - ensure they meet broker minimum distance
      double distance1 = MathMax(2 * Point, minStopDistance + Point);
      double distance2 = MathMax(4 * Point, minStopDistance + 3 * Point);
      
      price1 = NormalizeDouble(Ask + distance1, digits);
      price2 = NormalizeDouble(Ask + distance2, digits);
      orderType1 = OP_BUYSTOP;
      orderType2 = OP_BUYSTOP;
      
      // Verify prices are above current Ask (required for BUYSTOP)
      if(price1 <= Ask) price1 = NormalizeDouble(Ask + minStopDistance + Point, digits);
      if(price2 <= Ask || price2 <= price1) price2 = NormalizeDouble(price1 + minStopDistance, digits);
   }
   else if(signal == -1)  // SELL signal
   {
      // Create two SELLSTOP orders - ensure they meet broker minimum distance
      double distance1 = MathMax(2 * Point, minStopDistance + Point);
      double distance2 = MathMax(4 * Point, minStopDistance + 3 * Point);
      
      price1 = NormalizeDouble(Bid - distance1, digits);
      price2 = NormalizeDouble(Bid - distance2, digits);
      orderType1 = OP_SELLSTOP;
      orderType2 = OP_SELLSTOP;
      
      // Verify prices are below current Bid (required for SELLSTOP)
      if(price1 >= Bid) price1 = NormalizeDouble(Bid - minStopDistance - Point, digits);
      if(price2 >= Bid || price2 >= price1) price2 = NormalizeDouble(price1 - minStopDistance, digits);
   }
   
   string comment = "HFT_STAGE_" + (signal == 1 ? "BUY" : "SELL");
   double sl = 0.0;
   double tp = 0.0;
   
   RefreshRates();  // Refresh rates before placing orders
   
   // Create first pending order
   int ticket1 = OrderSend(Symbol(), orderType1, tradeLots, price1, 3, sl, tp, comment + "_1", MagicNumber, 0, 
                           (signal == 1 ? clrGreen : clrRed));
   
   if(ticket1 > 0)
   {
      pendingOrderTicket1 = ticket1;
      Print("Pending Order 1 created: ", (signal == 1 ? "BUYSTOP" : "SELLSTOP"), 
            " | Price: ", DoubleToString(price1, digits), 
            " | Lot: ", DoubleToString(tradeLots, 2),
            " | MinStopLevel: ", minStopLevel, " points");
   }
   else
   {
      int error = GetLastError();
      Print("Failed to create pending order 1: Error=", error, 
            " | Price: ", DoubleToString(price1, digits),
            " | MinStopLevel: ", minStopLevel);
      if(error == 130)
         Print("ERROR 130: Invalid stops - Price too close to current price. MinStopLevel: ", minStopLevel);
   }
   
   // Create second pending order
   RefreshRates();  // Refresh rates again
   int ticket2 = OrderSend(Symbol(), orderType2, tradeLots, price2, 3, sl, tp, comment + "_2", MagicNumber, 0, 
                           (signal == 1 ? clrGreen : clrRed));
   
   if(ticket2 > 0)
   {
      pendingOrderTicket2 = ticket2;
      Print("Pending Order 2 created: ", (signal == 1 ? "BUYSTOP" : "SELLSTOP"), 
            " | Price: ", DoubleToString(price2, digits),
            " | Lot: ", DoubleToString(tradeLots, 2));
      pendingOrderStartTime = TimeCurrent();
      pendingOrderDirection = signal;
   }
   else
   {
      int error = GetLastError();
      Print("Failed to create pending order 2: Error=", error, 
            " | Price: ", DoubleToString(price2, digits));
      if(error == 130)
         Print("ERROR 130: Invalid stops - Price too close to current price. MinStopLevel: ", minStopLevel);
      
      // If second order failed, delete first one
      if(pendingOrderTicket1 > 0)
      {
         if(OrderSelect(pendingOrderTicket1, SELECT_BY_TICKET))
         {
            if(!OrderDelete(pendingOrderTicket1))
            {
               Print("Warning: Failed to delete pending order 1 after creation failure: ", GetLastError());
            }
         }
         pendingOrderTicket1 = 0;
      }
   }
}

void CheckPendingOrdersStatus()
{
   // Check if pending order 1 became a market order
   if(pendingOrderTicket1 > 0)
   {
      if(OrderSelect(pendingOrderTicket1, SELECT_BY_TICKET))
      {
         if(OrderType() == OP_BUY || OrderType() == OP_SELL)
         {
            // Pending order became a market order
            Print("Pending Order 1 triggered! Opening trade...");
            
            // CRITICAL: Delete ALL pending orders immediately (scan all orders)
            DeleteAllPendingOrdersByScan();
            
            // Register this as active trade
            currentTrade.ticket = pendingOrderTicket1;
            currentTrade.entryPrice = OrderOpenPrice();
            currentTrade.openTime = OrderOpenTime();
            currentTrade.direction = (OrderType() == OP_BUY) ? 1 : -1;
            currentTrade.lotSize = OrderLots();
            currentTrade.previousProfit = 0.0;
            hasActiveTrade = true;
            
            // Clear pending order tracking
            pendingOrderTicket1 = 0;
            pendingOrderTicket2 = 0;
            pendingOrderStartTime = 0;
            pendingOrderDirection = 0;
            
            // Track pattern if enabled
            if(UsePatternStrategy)
            {
               patternIndex++;
            }
            
            Print("Trade registered - Ticket: ", currentTrade.ticket, " | Entry: ", DoubleToString(currentTrade.entryPrice, digits));
            return;
         }
         else if(OrderCloseTime() > 0)
         {
            // Order was closed or deleted
            pendingOrderTicket1 = 0;
         }
      }
      else
      {
         // Order doesn't exist anymore
         pendingOrderTicket1 = 0;
      }
   }
   
   // Check if pending order 2 became a market order
   if(pendingOrderTicket2 > 0)
   {
      if(OrderSelect(pendingOrderTicket2, SELECT_BY_TICKET))
      {
         if(OrderType() == OP_BUY || OrderType() == OP_SELL)
         {
            // Pending order became a market order
            Print("Pending Order 2 triggered! Opening trade...");
            
            // CRITICAL: Delete ALL pending orders immediately (scan all orders)
            DeleteAllPendingOrdersByScan();
            
            // Register this as active trade
            currentTrade.ticket = pendingOrderTicket2;
            currentTrade.entryPrice = OrderOpenPrice();
            currentTrade.openTime = OrderOpenTime();
            currentTrade.direction = (OrderType() == OP_BUY) ? 1 : -1;
            currentTrade.lotSize = OrderLots();
            currentTrade.previousProfit = 0.0;
            hasActiveTrade = true;
            
            // Clear pending order tracking
            pendingOrderTicket1 = 0;
            pendingOrderTicket2 = 0;
            pendingOrderStartTime = 0;
            pendingOrderDirection = 0;
            
            // Track pattern if enabled
            if(UsePatternStrategy)
            {
               patternIndex++;
            }
            
            Print("Trade registered - Ticket: ", currentTrade.ticket, " | Entry: ", DoubleToString(currentTrade.entryPrice, digits));
            return;
         }
         else if(OrderCloseTime() > 0)
         {
            // Order was closed or deleted
            pendingOrderTicket2 = 0;
         }
      }
      else
      {
         // Order doesn't exist anymore
         pendingOrderTicket2 = 0;
      }
   }
   
   // Also scan for any other pending orders that might have triggered (safety check)
   // This catches cases where orders trigger but aren't in our tracked list
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            int orderType = OrderType();
            if(orderType == OP_BUY || orderType == OP_SELL)
            {
               // Found an active trade - make sure it's registered
               if(!hasActiveTrade || currentTrade.ticket != OrderTicket())
               {
                  Print("Found unregistered active trade! Ticket: ", OrderTicket(), " - Registering...");
                  
                  // Delete ALL pending orders
                  DeleteAllPendingOrdersByScan();
                  
                  // Register this trade
                  currentTrade.ticket = OrderTicket();
                  currentTrade.entryPrice = OrderOpenPrice();
                  currentTrade.openTime = OrderOpenTime();
                  currentTrade.direction = (orderType == OP_BUY) ? 1 : -1;
                  currentTrade.lotSize = OrderLots();
                  currentTrade.previousProfit = 0.0;
                  hasActiveTrade = true;
                  
                  // Clear pending order tracking
                  pendingOrderTicket1 = 0;
                  pendingOrderTicket2 = 0;
                  pendingOrderStartTime = 0;
                  pendingOrderDirection = 0;
                  
                  break;  // Only register one trade
               }
            }
         }
      }
   }
}

void ManagePendingOrders()
{
   // CRITICAL: If we have an active trade, delete ALL pending orders immediately
   if(hasActiveTrade)
   {
      DeleteAllPendingOrdersByScan();
      return;
   }
   
   // Delete pending orders if 3 seconds pass (timeout)
   // Note: For HFT, this timeout might be too short, but keeping as per requirements
   if(pendingOrderStartTime > 0 && (TimeCurrent() - pendingOrderStartTime) >= 3)
   {
      Print("Pending orders timeout (3 seconds) - Deleting all pending orders");
      Print("Debug: Order1=", pendingOrderTicket1, " Order2=", pendingOrderTicket2);
      DeleteAllPendingOrdersByScan();
      return;
   }
   
   // Clean up invalid pending orders
   if(pendingOrderTicket1 > 0)
   {
      if(!OrderSelect(pendingOrderTicket1, SELECT_BY_TICKET))
      {
         pendingOrderTicket1 = 0;
      }
      else if(OrderCloseTime() > 0)
      {
         pendingOrderTicket1 = 0;
      }
   }
   
   if(pendingOrderTicket2 > 0)
   {
      if(!OrderSelect(pendingOrderTicket2, SELECT_BY_TICKET))
      {
         pendingOrderTicket2 = 0;
      }
      else if(OrderCloseTime() > 0)
      {
         pendingOrderTicket2 = 0;
      }
   }
   
   // If both pending orders are cleared, reset tracking
   if(pendingOrderTicket1 == 0 && pendingOrderTicket2 == 0)
   {
      pendingOrderStartTime = 0;
      pendingOrderDirection = 0;
   }
}

void DeleteAllPendingOrders()
{
   if(pendingOrderTicket1 > 0)
   {
      if(OrderSelect(pendingOrderTicket1, SELECT_BY_TICKET))
      {
         if(OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
         {
            if(!OrderDelete(pendingOrderTicket1))
            {
               Print("Warning: Failed to delete pending order 1: ", GetLastError());
            }
         }
      }
      pendingOrderTicket1 = 0;
   }
   
   if(pendingOrderTicket2 > 0)
   {
      if(OrderSelect(pendingOrderTicket2, SELECT_BY_TICKET))
      {
         if(OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
         {
            if(!OrderDelete(pendingOrderTicket2))
            {
               Print("Warning: Failed to delete pending order 2: ", GetLastError());
            }
         }
      }
      pendingOrderTicket2 = 0;
   }
   
   pendingOrderStartTime = 0;
   pendingOrderDirection = 0;
}

// ===== NEW FUNCTION: Scan and delete ALL pending orders (more aggressive cleanup) =====
void DeleteAllPendingOrdersByScan()
{
   int deletedCount = 0;
   
   // Scan all orders and delete any pending orders with our magic number
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            int orderType = OrderType();
            if(orderType == OP_BUYSTOP || orderType == OP_SELLSTOP)
            {
               int ticket = OrderTicket();
               if(OrderDelete(ticket))
               {
                  deletedCount++;
                  Print("Deleted pending order: ", ticket, " (Type: ", (orderType == OP_BUYSTOP ? "BUYSTOP" : "SELLSTOP"), ")");
               }
               else
               {
                  Print("Warning: Failed to delete pending order ", ticket, ": ", GetLastError());
               }
            }
         }
      }
   }
   
   // Clear tracking variables
   pendingOrderTicket1 = 0;
   pendingOrderTicket2 = 0;
   pendingOrderStartTime = 0;
   pendingOrderDirection = 0;
   
   if(deletedCount > 0)
   {
      Print("Deleted ", deletedCount, " pending order(s)");
   }
}

// =====================================================================================================
// MODULE 2: HARD EQUITY STOP
// =====================================================================================================

void CloseAllTradesImmediate()
{
   Print("Closing ALL trades immediately (Equity Safety Stop)...");
   
   int totalClosed = 0;
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            if(OrderType() == OP_BUY)
            {
               if(OrderClose(OrderTicket(), OrderLots(), Bid, 3, clrRed))
               {
                  totalClosed++;
                  Print("Closed BUY trade: ", OrderTicket(), " | P&L: $", DoubleToString(OrderProfit() + OrderSwap() + OrderCommission(), 2));
               }
            }
            else if(OrderType() == OP_SELL)
            {
               if(OrderClose(OrderTicket(), OrderLots(), Ask, 3, clrRed))
               {
                  totalClosed++;
                  Print("Closed SELL trade: ", OrderTicket(), " | P&L: $", DoubleToString(OrderProfit() + OrderSwap() + OrderCommission(), 2));
               }
            }
         }
      }
   }
   
   // Also close any pending orders
   DeleteAllPendingOrders();
   
   // Reset trade tracking
   hasActiveTrade = false;
   currentTrade.ticket = 0;
   
   Print("Total trades closed: ", totalClosed);
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
   
   // Refresh rates for accurate pricing
   RefreshRates();
   
   if(!OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
   {
      // Trade doesn't exist - might have been closed manually
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      DeleteAllPendingOrdersByScan();  // Clean up any remaining pending orders
      return;
   }
   
   if(OrderCloseTime() > 0)
   {
      // Trade already closed
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      DeleteAllPendingOrdersByScan();  // Clean up any remaining pending orders
      return;
   }
   
   double currentProfit = OrderProfit() + OrderSwap() + OrderCommission();
   
   // ===== 1. INSTANT PROFIT EXIT (HFT-style - close immediately when profit turns positive) =====
   // CRITICAL: Close immediately at ANY profit, no matter how small
   if(currentProfit > 0.0)
   {
      CloseHFTrade("Instant profit exit");
      return;
   }
   
   // Also check if we have any pending orders that should be deleted
   if(pendingOrderTicket1 > 0 || pendingOrderTicket2 > 0)
   {
      DeleteAllPendingOrdersByScan();
   }
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
// TRADE OPENING (KEPT FOR BACKWARD COMPATIBILITY - NOT USED DIRECTLY ANYMORE)
// =====================================================================================================

bool OpenHFTrade(int direction)
{
   if(direction == 0)
      return false;
   
   // Check if AutoTrading is enabled
   if(!IsTradeAllowed())
   {
      static datetime lastWarningTime = 0;
      if(TimeCurrent() - lastWarningTime > 60)  // Warn once per minute
      {
         Print("ERROR: AutoTrading is disabled in MT4. Please enable AutoTrading button!");
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
   int orderType = (direction == 1) ? OP_BUY : OP_SELL;
   
   int ticket = OrderSend(Symbol(), orderType, tradeLots, price, 3, sl, tp, comment, MagicNumber, 0, 
                          (direction == 1 ? clrGreen : clrRed));
   
   if(ticket > 0)
   {
      if(OrderSelect(ticket, SELECT_BY_TICKET))
      {
         currentTrade.ticket = ticket;
         currentTrade.entryPrice = OrderOpenPrice();
         currentTrade.openTime = OrderOpenTime();
         currentTrade.direction = direction;
         currentTrade.lotSize = tradeLots;
         currentTrade.previousProfit = 0.0;
         hasActiveTrade = true;
         
         Print("HFT TRADE OPENED: ", (direction == 1 ? "BUY" : "SELL"), 
               " | Lot: ", tradeLots, " | Risk: ", RiskPercentPerTrade, "% | Price: ", price);
         return true;
      }
   }
   else
   {
      int error = GetLastError();
      Print("OrderSend FAILED: Error=", error, " | Symbol=", Symbol(), " | Type=", (direction == 1 ? "BUY" : "SELL"),
            " | Lot=", tradeLots, " | Price=", price);
      
      // Common error messages
      if(error == 130)
         Print("ERROR 130: Invalid stops. Check price and stop levels.");
      else if(error == 131)
         Print("ERROR 131: Invalid trade volume. Check lot size limits.");
      else if(error == 134)
         Print("ERROR 134: Not enough money to open trade.");
      else if(error == 146)
         Print("ERROR 146: Trading subsystem is busy. Try again.");
      else if(error == 10004)
         Print("ERROR 10004: Requote occurred. Price changed during order execution.");
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
   
   RefreshRates();  // Get latest prices
   
   if(!OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
   {
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      DeleteAllPendingOrdersByScan();  // Clean up
      return;
   }
   
   if(OrderCloseTime() > 0)
   {
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      DeleteAllPendingOrdersByScan();  // Clean up
      return;
   }
   
   // ===== ONLY CLOSE TRADES IN PROFIT (never at a loss) =====
   double profit = OrderProfit() + OrderSwap() + OrderCommission();
   if(profit <= 0.0)
   {
      // Don't print this every tick - only occasionally
      static datetime lastBlockedPrint = 0;
      if(TimeCurrent() - lastBlockedPrint > 5)
      {
         Print("Blocked close attempt: still negative. Waiting for profit. Current P&L: $", DoubleToString(profit, 2));
         lastBlockedPrint = TimeCurrent();
      }
      return;
   }
   
   // CRITICAL: Delete ALL pending orders before closing trade
   DeleteAllPendingOrdersByScan();
   
   bool result = false;
   RefreshRates();  // Refresh again right before closing
   if(OrderType() == OP_BUY)
      result = OrderClose(currentTrade.ticket, OrderLots(), Bid, 3, clrRed);
   else if(OrderType() == OP_SELL)
      result = OrderClose(currentTrade.ticket, OrderLots(), Ask, 3, clrRed);
   
   if(result)
   {
      int holdSeconds = (int)(TimeCurrent() - currentTrade.openTime);
      Print("HFT TRADE CLOSED: ", reason, " | P&L: $", DoubleToString(profit, 2), 
            " | Hold: ", IntegerToString(holdSeconds), "s");
      
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
      Print("OrderClose failed: ", GetLastError());
   }
   
   hasActiveTrade = false;
   currentTrade.ticket = 0;
}

// =====================================================================================================
// DISPLAY
// =====================================================================================================

void UpdateDisplay()
{
   string display = "\n=== ULTRA HIGH FREQUENCY MICRO-SCALPER V3 ===\n";
   
   // Show equity stop status
   if(equityStopActive)
   {
      double currentEquity = AccountEquity();
      double changePercent = ((currentEquity - equityStart) / equityStart) * 100.0;
      display += "⚠ EQUITY SAFETY STOP ACTIVE ⚠\n";
      display += "Change: " + DoubleToString(changePercent, 2) + "% | Trading STOPPED\n";
      display += "========================================\n";
      Comment(display);
      return;
   }
   
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
   display += "Exit: Instant profit exit (never close at loss)\n";
   display += "Buffer Init: 2 ticks | Ultra-Fast Signal Detection\n";
   
   // Show equity status
   double currentEquity = AccountEquity();
   double changePercent = ((currentEquity - equityStart) / equityStart) * 100.0;
   display += "Equity: $" + DoubleToString(currentEquity, 2) + " (" + DoubleToString(changePercent, 2) + "%) | Safety Stop: ±20%\n";
   
   // Show pending orders status
   if(pendingOrderTicket1 > 0 || pendingOrderTicket2 > 0)
   {
      display += "\nPending Orders: ACTIVE\n";
      if(pendingOrderTicket1 > 0)
         display += "  Order 1: " + IntegerToString(pendingOrderTicket1) + "\n";
      if(pendingOrderTicket2 > 0)
         display += "  Order 2: " + IntegerToString(pendingOrderTicket2) + "\n";
   }
   
   if(hasActiveTrade)
   {
      if(OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
      {
         double profit = OrderProfit() + OrderSwap() + OrderCommission();
         int holdSeconds = (int)(TimeCurrent() - currentTrade.openTime);
         
         display += "\nTRADE: " + (currentTrade.direction == 1 ? "BUY" : "SELL") + "\n";
         display += "P&L: $" + DoubleToString(profit, 2) + "\n";
         display += "Hold: " + IntegerToString(holdSeconds) + "s / " + 
                    IntegerToString(MaxHoldSeconds) + "s max\n";
      }
   }
   else
   {
      display += "\nNo active trade\n";
      display += "Waiting for HFT signal...\n";
      if(tickIndex >= 2)
         display += "Buffers: READY (Ultra-Fast Mode)\n";
      else
         display += "Buffers: Initializing (" + IntegerToString(tickIndex) + "/2 ticks)...\n";
   }
   
   Comment(display);
}

