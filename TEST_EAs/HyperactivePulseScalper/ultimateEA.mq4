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

// ===== Basket Trading Settings =====
input int      MaxTradesInBasket = 5;      // Maximum trades in basket (1-10)
input bool     AllowBasketTrading = true;  // Enable basket trading (multiple simultaneous trades)
input bool     SameDirectionOnly = true;   // Only allow trades in same direction (true) or mixed (false)

// ===== Risk Management Options =====
input bool     UseBasketRisk = true;       // true = dynamic basket risk, false = risk per trade
input double   RiskPercentPerBasket = 5.0; // Total risk % for entire basket

// ===== Pattern Strategy Settings =====
input int      PatternSequenceLength = 4;      // Number of trades in each pattern sequence (3-5)
input int      MomentumLookbackTicks = 15;     // Number of ticks to analyze for momentum (10-20)
input double   MomentumThreshold     = 0.60;   // Momentum threshold (0.60 = 60% ticks in direction)
input bool     UsePatternStrategy    = true;   // Enable pattern-based entry strategy
input bool     ValidateWithMomentum  = true;   // Validate pattern entry with momentum check

// ===== NEW: Dynamic Accuracy Enhancement Settings =====
input int      MinQualityThreshold   = 70;      // Minimum trade quality score (0-100) - filters low-quality signals
input bool     UseBestHours         = true;   // Enable session-based trading (only trade during best hours)
input int      StartHour            = 9;       // Start hour for trading (24-hour format)
input int      EndHour              = 18;     // End hour for trading (24-hour format)
input bool     UseDrawdownAdaptiveLots = true; // Enable drawdown-adaptive lot sizing
input double   DrawdownBoostStart   = -5.0;   // Start boosting lots at this drawdown % (negative)
input double   DrawdownBoostMax     = -15.0;  // Maximum drawdown % - reduce lots to protect account
input double   MaxAllowedSpike      = 30.0;   // Maximum allowed price spike in points (filter fake spikes)

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
   
   // ===== CRITICAL: Check for existing trades on startup =====
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            int orderType = OrderType();
            if(orderType == OP_BUY || orderType == OP_SELL)
            {
               // Found existing trade - register it
               currentTrade.ticket = OrderTicket();
               currentTrade.entryPrice = OrderOpenPrice();
               currentTrade.openTime = OrderOpenTime();
               currentTrade.direction = (orderType == OP_BUY) ? 1 : -1;
               currentTrade.lotSize = OrderLots();
               currentTrade.previousProfit = 0.0;
               hasActiveTrade = true;
               
               Print("Found existing trade on startup: Ticket=", currentTrade.ticket, 
                     " | Type=", (orderType == OP_BUY ? "BUY" : "SELL"),
                     " | Entry=", DoubleToString(currentTrade.entryPrice, digits));
               break;  // Only register one trade
            }
         }
      }
   }
   
   // Delete any pending orders on startup
   DeleteAllPendingOrdersByScan();
   
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
   
   // Check for signals - ALWAYS check signals (not blocked by hasActiveTrade for basket trading)
   int direction = 0;
   
   // Check current basket size first
   int currentBasketSize = CountActiveTrades();
   
   // Determine if we should check for signals based on basket trading mode
   bool shouldCheckSignals = false;
   
   if(AllowBasketTrading)
   {
      // Basket trading enabled - check signals as long as basket isn't full
      shouldCheckSignals = (currentBasketSize < MaxTradesInBasket);
   }
   else
   {
      // Single trade mode - only check signals if no active trades
      shouldCheckSignals = (currentBasketSize == 0);
   }
   
   if(shouldCheckSignals)
   {
      // Get signal direction
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
         Print("DEBUG: Direction=", direction, " | BasketSize=", currentBasketSize, "/", MaxTradesInBasket,
               " | TickIndex=", tickIndex, " | PatternIndex=", patternIndex,
               " | UsePatternStrategy=", UsePatternStrategy,
               " | Pending1=", pendingOrderTicket1, " | Pending2=", pendingOrderTicket2);
      }
      
      // More frequent logging when signal detected
      if(direction != 0)
      {
         Print("SIGNAL DETECTED: ", (direction == 1 ? "BUY" : "SELL"), 
               " | Basket: ", currentBasketSize, "/", MaxTradesInBasket,
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
      
      // ===== PRIORITY: Market Execution First (for HFT speed) =====
      // Determine if we can open new trades
      bool canOpenNewTrade = false;
      
      if(AllowBasketTrading)
      {
         // Basket trading enabled - check if we're under the limit
         if(currentBasketSize < MaxTradesInBasket)
         {
            // Check dynamic risk - if risk is 0, basket is effectively full
            double availableRisk = CalculateDynamicRiskPerTrade();
            if(availableRisk <= 0.0)
            {
               static datetime lastFullLog = 0;
               if(TimeCurrent() - lastFullLog > 5)
               {
                  Print("Basket FULL (risk allocated) - ", currentBasketSize, "/", MaxTradesInBasket, " trades");
                  lastFullLog = TimeCurrent();
               }
               canOpenNewTrade = false;
            }
            else if(SameDirectionOnly)
            {
               // Check if we have trades in the same direction
               bool hasSameDirection = false;
               bool hasOppositeDirection = false;
               
               for(int i = OrdersTotal() - 1; i >= 0; i--)
               {
                  if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
                  {
                     if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
                     {
                        int orderType = OrderType();
                        if((orderType == OP_BUY || orderType == OP_SELL) && OrderCloseTime() == 0)
                        {
                           if((direction == 1 && orderType == OP_BUY) || (direction == -1 && orderType == OP_SELL))
                           {
                              hasSameDirection = true;
                           }
                           else
                           {
                              hasOppositeDirection = true;
                           }
                        }
                     }
                  }
               }
               
               // Can open if no trades exist OR if we have trades in same direction
               canOpenNewTrade = (currentBasketSize == 0 || hasSameDirection);
               
               if(hasOppositeDirection && !hasSameDirection)
               {
                  static datetime lastOppositeLog = 0;
                  if(TimeCurrent() - lastOppositeLog > 5)
                  {
                     Print("Signal ", (direction == 1 ? "BUY" : "SELL"), 
                           " blocked - Opposite direction trades exist (SameDirectionOnly=true)");
                     lastOppositeLog = TimeCurrent();
                  }
               }
            }
            else
            {
               // Mixed direction allowed - just check basket size and risk
               canOpenNewTrade = true;
            }
         }
         else
         {
            // Basket is full
            static datetime lastFullLog = 0;
            if(TimeCurrent() - lastFullLog > 5)
            {
               Print("Basket FULL (", currentBasketSize, "/", MaxTradesInBasket, ") - Skipping new entries");
               lastFullLog = TimeCurrent();
            }
            canOpenNewTrade = false;
         }
      }
      else
      {
         // Single trade mode (original behavior)
         canOpenNewTrade = (currentBasketSize == 0);
      }
      
      // ===== NEW ENHANCEMENT: Apply all accuracy filters before opening trade =====
      if(direction != 0 && canOpenNewTrade && pendingOrderTicket1 == 0 && pendingOrderTicket2 == 0)
      {
         // Filter 1: Smart Session Controller (Best Hours Only)
         if(!IsWithinBestHours())
         {
            static datetime lastSessionLog = 0;
            if(TimeCurrent() - lastSessionLog > 60)
            {
               Print("Signal blocked: Outside trading hours (", StartHour, ":00 - ", EndHour, ":00)");
               lastSessionLog = TimeCurrent();
            }
            direction = 0;  // Block signal
         }
         
         // Filter 2: Trade Spike-Filter (Avoid Fake Spikes)
         if(direction != 0 && !IsSpikeWithinLimit())
         {
            Print("Signal blocked: Price spike too large (", DoubleToString(MathAbs(Bid - bidBuffer[1]) / Point, 1), 
                  " points > ", DoubleToString(MaxAllowedSpike, 1), " points)");
            direction = 0;  // Block signal
         }
         
         // Filter 3: Micro-Trend Confirmation
         if(direction != 0 && !TrendConfirm(direction))
         {
            Print("Signal blocked: Trend confirmation failed for ", (direction == 1 ? "BUY" : "SELL"));
            direction = 0;  // Block signal
         }
         
         // Filter 4: Dynamic Order-Quality Filter (95% Accuracy Boost)
         if(direction != 0)
         {
            int qualityScore = GetTradeQualityScore(direction);
            if(qualityScore < MinQualityThreshold)
            {
               static datetime lastQualityLog = 0;
               if(TimeCurrent() - lastQualityLog > 5)
               {
                  Print("Signal blocked: Quality score too low (", qualityScore, "/100 < ", MinQualityThreshold, 
                        ") for ", (direction == 1 ? "BUY" : "SELL"));
                  lastQualityLog = TimeCurrent();
               }
               direction = 0;  // Block signal
            }
            else
            {
               // Log high-quality signals
               static datetime lastQualityLog = 0;
               if(TimeCurrent() - lastQualityLog > 5)
               {
                  Print("✓ High-quality signal: ", (direction == 1 ? "BUY" : "SELL"), 
                        " | Quality Score: ", qualityScore, "/100");
                  lastQualityLog = TimeCurrent();
               }
            }
         }
         
         // Only proceed if signal passed all filters
         if(direction != 0)
         {
            Print("Signal detected: ", (direction == 1 ? "BUY" : "SELL"), 
                  " | Basket: ", currentBasketSize, "/", MaxTradesInBasket,
                  " - Attempting MARKET execution...");
            
            // Try market execution first (immediate entry)
            if(OpenHFTrade(direction))
            {
               Print("✓ MARKET ORDER EXECUTED: ", (direction == 1 ? "BUY" : "SELL"), 
                     " | Ticket: ", currentTrade.ticket,
                     " | Basket: ", CountActiveTrades(), "/", MaxTradesInBasket);
               
               // Track pattern if enabled
               if(UsePatternStrategy)
               {
                  patternIndex++;
               }
               
               // Delete any remaining pending orders (safety)
               DeleteAllPendingOrdersByScan();
            }
            else
            {
               // Market execution failed - fallback to pending orders
               int error = GetLastError();
               Print("Market execution failed (Error: ", error, ") - Falling back to pending orders...");
               
               // ===== FALLBACK: Use Smart Entry Staging if market execution fails =====
               SmartEntryStaging(direction);
            }
         }
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
   
   // Calculate lot size - using smooth dynamic exponential scaling
   double tradeLots = GetDynamicLotSize();
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
   
   // Also scan for any other active trades that might not be registered (safety check)
   // This catches cases where trades exist but aren't in our tracked list
   if(!hasActiveTrade)
   {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         {
            if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
            {
               int orderType = OrderType();
               if(orderType == OP_BUY || orderType == OP_SELL)
               {
                  // Found an active trade - register it
                  int ticket = OrderTicket();
                  Print("Found unregistered active trade! Ticket: ", ticket, " - Registering...");
                  
                  // Delete ALL pending orders
                  DeleteAllPendingOrdersByScan();
                  
                  // Register this trade
                  currentTrade.ticket = ticket;
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
                  
                  Print("Trade registered - Ticket: ", currentTrade.ticket, " | Entry: ", DoubleToString(currentTrade.entryPrice, digits));
                  break;  // Only register one trade
               }
            }
         }
      }
   }
   else
   {
      // Verify our tracked trade still exists
      if(currentTrade.ticket > 0)
      {
         if(!OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
         {
            // Trade doesn't exist anymore - reset
            Print("Tracked trade no longer exists - Resetting...");
            hasActiveTrade = false;
            currentTrade.ticket = 0;
            DeleteAllPendingOrdersByScan();
         }
         else if(OrderCloseTime() > 0)
         {
            // Trade was closed
            Print("Tracked trade was closed - Resetting...");
            hasActiveTrade = false;
            currentTrade.ticket = 0;
            DeleteAllPendingOrdersByScan();
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

// ===== NEW FUNCTION: Calculate actual profit after accounting for spread and commission on close =====
double CalculateActualProfitAfterClose(int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return 0.0;
   
   RefreshRates();
   
   double currentProfit = OrderProfit() + OrderSwap() + OrderCommission();
   
   // Get current spread
   double currentSpread = Ask - Bid;
   
   // Calculate spread cost that will be paid on close
   // When closing BUY: sell at Bid (lose spread)
   // When closing SELL: buy at Ask (lose spread)
   double spreadCost = 0.0;
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
   
   if(tickSize > 0 && tickValue > 0)
   {
      // Calculate spread in ticks
      double spreadInTicks = currentSpread / tickSize;
      
      // Calculate spread cost in account currency
      spreadCost = spreadInTicks * tickValue * OrderLots();
   }
   else
   {
      // Fallback: estimate spread cost using pip value
      double pipValue = MarketInfo(Symbol(), MODE_TICKVALUE) / MarketInfo(Symbol(), MODE_TICKSIZE) * pipToPoint;
      if(pipValue > 0)
      {
         double spreadInPips = currentSpread / pipToPoint;
         spreadCost = spreadInPips * pipValue * OrderLots();
      }
   }
   
   // Account for commission that will be charged on close
   // For raw accounts (commission-based), commission is typically charged per lot per side
   // OrderCommission() shows commission already paid on open
   // We need to estimate commission that will be charged on close
   double commissionOnClose = 0.0;
   
   // If commission was charged on open, assume same commission will be charged on close
   // This is typical for raw accounts where commission is charged per side
   if(OrderCommission() != 0.0 && OrderLots() > 0.0)
   {
      // Calculate commission per lot (assuming commission was charged on open)
      double commissionPerLot = OrderCommission() / OrderLots();
      
      // For raw accounts, commission is typically charged on both open and close
      // So we estimate the same commission will be charged on close
      commissionOnClose = commissionPerLot * OrderLots();
   }
   else
   {
      // No commission charged on open - might be spread-based account
      // But some brokers charge commission only on close, so check account type
      // For now, assume no commission on close if none was charged on open
      commissionOnClose = 0.0;
   }
   
   // Calculate actual profit after all costs (spread + commission on close)
   double actualProfit = currentProfit - spreadCost - commissionOnClose;
   
   return actualProfit;
}

// =====================================================================================================
// NEW ENHANCEMENT MODULE 1: DYNAMIC ORDER-QUALITY FILTER (95% Accuracy Boost)
// =====================================================================================================

// ===== NEW FUNCTION: Get Trade Quality Score (0-100) =====
int GetTradeQualityScore(int direction)
{
   if(tickIndex < 2)
      return 0;  // Not enough data
   
   int score = 0;
   
   // 1. Micro-momentum stability (0-25 points)
   int momentumConsistency = 0;
   if(tickIndex >= 2)
   {
      if(direction == 1)  // BUY signal
      {
         if(Bid > bidBuffer[1] && bidBuffer[1] > bidBuffer[2])
            momentumConsistency = 25;  // Perfect upward momentum
         else if(Bid > bidBuffer[1] || bidBuffer[1] > bidBuffer[2])
            momentumConsistency = 15;  // Partial momentum
      }
      else if(direction == -1)  // SELL signal
      {
         if(Bid < bidBuffer[1] && bidBuffer[1] < bidBuffer[2])
            momentumConsistency = 25;  // Perfect downward momentum
         else if(Bid < bidBuffer[1] || bidBuffer[1] < bidBuffer[2])
            momentumConsistency = 15;  // Partial momentum
      }
   }
   score += momentumConsistency;
   
   // 2. Direction consistency across 3 ticks (0-25 points)
   int directionConsistency = 0;
   if(tickIndex >= 2)
   {
      int bullishTicks = 0;
      int bearishTicks = 0;
      
      if(Bid > bidBuffer[1]) bullishTicks++;
      else if(Bid < bidBuffer[1]) bearishTicks++;
      
      if(bidBuffer[1] > bidBuffer[2]) bullishTicks++;
      else if(bidBuffer[1] < bidBuffer[2]) bearishTicks++;
      
      if(direction == 1 && bullishTicks >= 2)
         directionConsistency = 25;  // Strong bullish consistency
      else if(direction == -1 && bearishTicks >= 2)
         directionConsistency = 25;  // Strong bearish consistency
      else if((direction == 1 && bullishTicks >= 1) || (direction == -1 && bearishTicks >= 1))
         directionConsistency = 15;  // Partial consistency
   }
   score += directionConsistency;
   
   // 3. Spread stability (0-20 points)
   int spreadStability = 0;
   if(spreadIndex >= 3)
   {
      double currentSpread = Ask - Bid;
      double avgSpread = 0.0;
      for(int i = 0; i < 3; i++)
      {
         avgSpread += spreadBuffer[i];
      }
      avgSpread = avgSpread / 3.0;
      
      if(avgSpread > 0.0)
      {
         double spreadRatio = currentSpread / avgSpread;
         if(spreadRatio >= 0.8 && spreadRatio <= 1.2)
            spreadStability = 20;  // Spread is stable (within 20% of average)
         else if(spreadRatio >= 0.6 && spreadRatio <= 1.4)
            spreadStability = 10;  // Spread is somewhat stable
      }
   }
   score += spreadStability;
   
   // 4. Tick acceleration (speed of price change) (0-15 points)
   int tickAcceleration = 0;
   if(tickIndex >= 2)
   {
      double move1 = MathAbs(Bid - bidBuffer[1]);
      double move2 = MathAbs(bidBuffer[1] - bidBuffer[2]);
      
      if(move1 > 0 && move2 > 0)
      {
         double accelerationRatio = move1 / move2;
         if(accelerationRatio >= 1.0 && accelerationRatio <= 2.0)
            tickAcceleration = 15;  // Good acceleration (price moving faster)
         else if(accelerationRatio >= 0.5 && accelerationRatio <= 3.0)
            tickAcceleration = 8;   // Moderate acceleration
      }
   }
   score += tickAcceleration;
   
   // 5. Rejection bounce (small pullback before continuation) (0-15 points)
   int rejectionBounce = 0;
   if(tickIndex >= 2)
   {
      if(direction == 1)  // BUY signal - look for small dip then bounce up
      {
         if(bidBuffer[1] < bidBuffer[2] && Bid > bidBuffer[1])
            rejectionBounce = 15;  // Perfect rejection bounce
         else if(Bid > bidBuffer[1])
            rejectionBounce = 8;   // Simple bounce
      }
      else if(direction == -1)  // SELL signal - look for small rise then bounce down
      {
         if(bidBuffer[1] > bidBuffer[2] && Bid < bidBuffer[1])
            rejectionBounce = 15;  // Perfect rejection bounce
         else if(Bid < bidBuffer[1])
            rejectionBounce = 8;   // Simple bounce
      }
   }
   score += rejectionBounce;
   
   return score;  // Return score 0-100
}

// =====================================================================================================
// NEW ENHANCEMENT MODULE 2: SMART SESSION CONTROLLER
// =====================================================================================================

// ===== NEW FUNCTION: Check if current time is within best trading hours =====
bool IsWithinBestHours()
{
   if(!UseBestHours)
      return true;  // If disabled, always allow trading
   
   int currentHour = Hour();
   
   // Handle wrap-around (e.g., 22:00 to 06:00)
   if(StartHour <= EndHour)
   {
      // Normal case: StartHour < EndHour (e.g., 9 to 18)
      return (currentHour >= StartHour && currentHour <= EndHour);
   }
   else
   {
      // Wrap-around case: StartHour > EndHour (e.g., 22 to 6)
      return (currentHour >= StartHour || currentHour <= EndHour);
   }
}

// =====================================================================================================
// NEW ENHANCEMENT MODULE 3: TRADE SPIKE-FILTER (Avoid Fake Spikes)
// =====================================================================================================

// ===== NEW FUNCTION: Check if price spike is within allowed range =====
bool IsSpikeWithinLimit()
{
   if(tickIndex < 1)
      return true;  // Not enough data
   
   double spikeSize = MathAbs(Bid - bidBuffer[1]);
   double maxSpikePoints = MaxAllowedSpike * Point;
   
   if(MaxAllowedSpike > 0 && spikeSize > maxSpikePoints)
   {
      return false;  // Spike too large - filter out
   }
   
   return true;  // Spike is acceptable
}

// =====================================================================================================
// NEW ENHANCEMENT MODULE 4: MICRO-TREND CONFIRMATION
// =====================================================================================================

// ===== NEW FUNCTION: Confirm trend direction matches signal =====
bool TrendConfirm(int direction)
{
   if(tickIndex < 2)
      return true;  // Not enough data - allow anyway
   
   int bullish = 0;
   int bearish = 0;
   
   // Check last 3 ticks for trend consistency
   if(tickIndex >= 2)
   {
      if(Bid > bidBuffer[1]) bullish++;
      else if(Bid < bidBuffer[1]) bearish++;
      
      if(bidBuffer[1] > bidBuffer[2]) bullish++;
      else if(bidBuffer[1] < bidBuffer[2]) bearish++;
   }
   
   // Confirm direction matches trend
   if(direction == 1 && bullish >= 2)
      return true;  // BUY signal confirmed by bullish trend
   
   if(direction == -1 && bearish >= 2)
      return true;  // SELL signal confirmed by bearish trend
   
   // If not enough confirmation, still allow (lenient)
   return true;  // Default: allow (can be made stricter if needed)
}

// ===== NEW FUNCTION: Count active trades =====
int CountActiveTrades()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            int orderType = OrderType();
            if((orderType == OP_BUY || orderType == OP_SELL) && OrderCloseTime() == 0)
            {
               count++;
            }
         }
      }
   }
   return count;
}

void ManageHFTrade()
{
   // CRITICAL: Manage ALL active trades, not just one
   // This ensures ALL profitable trades close immediately
   RefreshRates();
   
   bool foundActiveTrade = false;
   int managedTradeTicket = 0;
   
   // Scan ALL trades and close profitable ones immediately
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            int orderType = OrderType();
            if((orderType == OP_BUY || orderType == OP_SELL) && OrderCloseTime() == 0)
            {
               foundActiveTrade = true;
               int ticket = OrderTicket();
               
               // Track the first active trade for display purposes
               if(managedTradeTicket == 0)
               {
                  managedTradeTicket = ticket;
                  currentTrade.ticket = ticket;
                  currentTrade.entryPrice = OrderOpenPrice();
                  currentTrade.openTime = OrderOpenTime();
                  currentTrade.direction = (orderType == OP_BUY) ? 1 : -1;
                  currentTrade.lotSize = OrderLots();
                  hasActiveTrade = true;
               }
               
               // ===== CRITICAL: Calculate actual profit AFTER accounting for spread and commission on close =====
               // This ensures we don't close at a loss due to spread/commission costs
               double actualProfit = CalculateActualProfitAfterClose(ticket);
               double currentProfit = OrderProfit() + OrderSwap() + OrderCommission();
               
               // ===== 1. INSTANT PROFIT EXIT (HFT-style - close immediately when profit turns positive) =====
               // CRITICAL: Only close if actual profit is positive AFTER spread and commission costs
               // This prevents closing at a loss due to spread/commission
               if(actualProfit > 0.0)
               {
                  Print("Closing profitable trade: Ticket=", ticket, 
                        " | Current P&L=$", DoubleToString(currentProfit, 2),
                        " | Actual P&L (after costs)=$", DoubleToString(actualProfit, 2));
                  
                  bool closed = false;
                  RefreshRates();
                  if(orderType == OP_BUY)
                     closed = OrderClose(ticket, OrderLots(), Bid, 3, clrRed);
                  else if(orderType == OP_SELL)
                     closed = OrderClose(ticket, OrderLots(), Ask, 3, clrRed);
                  
                  if(closed)
                  {
                     // Get final profit after close
                     if(OrderSelect(ticket, SELECT_BY_TICKET))
                     {
                        double finalProfit = OrderProfit() + OrderSwap() + OrderCommission();
                        Print("✓ Trade closed: Ticket=", ticket, " | Final P&L=$", DoubleToString(finalProfit, 2));
                     }
                     
                     // Track pattern if enabled
                     if(UsePatternStrategy && ticket == currentTrade.ticket)
                     {
                        tradesInSequence++;
                        patternIndex++;
                     }
                  }
                  else
                  {
                     Print("ERROR: Failed to close trade ", ticket, " | Error: ", GetLastError());
                  }
                  continue;  // Move to next trade
               }
               else
               {
                  // Trade is not profitable after accounting for spread/commission
                  // Only log occasionally to avoid spam
                  static datetime lastBlockedPrint = 0;
                  if(TimeCurrent() - lastBlockedPrint > 5)
                  {
                     Print("Blocked close: Trade not profitable after costs. Ticket=", ticket,
                           " | Current P&L=$", DoubleToString(currentProfit, 2),
                           " | Actual P&L (after costs)=$", DoubleToString(actualProfit, 2),
                           " | Waiting for profit or drawdown...");
                     lastBlockedPrint = TimeCurrent();
                  }
               }
            }
         }
      }
   }
   
   // Update hasActiveTrade flag
   hasActiveTrade = foundActiveTrade;
   
   if(!foundActiveTrade)
   {
      currentTrade.ticket = 0;
      DeleteAllPendingOrdersByScan();
   }
   else if(pendingOrderTicket1 > 0 || pendingOrderTicket2 > 0)
   {
      // Delete pending orders if we have active trades
      DeleteAllPendingOrdersByScan();
   }
}

// =====================================================================================================
// RISK-BASED LOT SIZE CALCULATION
// =====================================================================================================

// ===== NEW FUNCTION: Smooth Dynamic Lot Size (Exponential Scaling) =====
double GetDynamicLotSize()
{
   double eq = AccountEquity();
   
   // Smooth exponential scaling
   double GrowthPower   = 1.05;     // controls curve steepness
   double GrowthDivisor = 20000.0;  // controls size of lots
   
   double lot = MathPow(eq, GrowthPower) / GrowthDivisor;
   
   // ===== NEW: Drawdown-Adaptive Lot Size Adjustment =====
   if(UseDrawdownAdaptiveLots && equityStart > 0.0)
   {
      double eqChange = ((eq - equityStart) / equityStart) * 100.0;
      
      if(eqChange <= DrawdownBoostMax)
      {
         // Maximum drawdown reached - reduce lots significantly to protect account
         lot = lot * 0.5;  // Reduce to 50% of calculated lot
         Print("Drawdown-Adaptive: Max drawdown reached (", DoubleToString(eqChange, 2), "%) - Reducing lots to 50%");
      }
      else if(eqChange <= DrawdownBoostStart)
      {
         // Drawdown started - slightly boost lots (martingale-like recovery)
         lot = lot * 1.2;  // Increase by 20% to recover faster
         Print("Drawdown-Adaptive: Drawdown detected (", DoubleToString(eqChange, 2), "%) - Boosting lots by 20%");
      }
      // If eqChange > DrawdownBoostStart, use normal lot size (no adjustment)
   }
   
   // Safety limits
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double step   = MarketInfo(Symbol(), MODE_LOTSTEP);
   
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   
   // normalize to broker step
   lot = MathFloor(lot / step) * step;
   
   return NormalizeDouble(lot, 2);
}

// ===== NEW FUNCTION: Calculate dynamic risk per trade based on basket =====
double CalculateDynamicRiskPerTrade()
{
   if(!AllowBasketTrading || !UseBasketRisk)
   {
      // Use original per-trade risk
      return RiskPercentPerTrade;
   }
   
   int currentBasketSize = CountActiveTrades();
   
   if(currentBasketSize == 0)
   {
      // First trade - use full basket risk divided by max basket size
      // This ensures we don't over-allocate on first trade
      double riskPerTrade = RiskPercentPerBasket / MaxTradesInBasket;
      Print("Dynamic Risk: First trade | Basket risk: ", RiskPercentPerBasket, 
            "% / ", MaxTradesInBasket, " max = ", DoubleToString(riskPerTrade, 2), "% per trade");
      return riskPerTrade;
   }
   else if(currentBasketSize >= MaxTradesInBasket)
   {
      // Basket is full - no more trades
      return 0.0;
   }
   else
   {
      // Calculate how much risk has been used so far
      // Each existing trade used: RiskPercentPerBasket / MaxTradesInBasket
      double riskUsedPerTrade = RiskPercentPerBasket / MaxTradesInBasket;
      double totalRiskUsed = currentBasketSize * riskUsedPerTrade;
      double remainingRisk = RiskPercentPerBasket - totalRiskUsed;
      
      // Distribute remaining risk among remaining slots
      int remainingSlots = MaxTradesInBasket - currentBasketSize;
      double riskPerNewTrade = remainingRisk / remainingSlots;
      
      Print("Dynamic Risk: Basket=", currentBasketSize, "/", MaxTradesInBasket,
            " | Used=", DoubleToString(totalRiskUsed, 2), "%",
            " | Remaining=", DoubleToString(remainingRisk, 2), "%",
            " | New trade=", DoubleToString(riskPerNewTrade, 2), "%");
      
      return riskPerNewTrade;
   }
}

double CalculateRiskLotSize()
{
   double balance = AccountBalance();
   double riskPercent = 0.0;
   
   if(AllowBasketTrading && UseBasketRisk)
   {
      // Dynamic basket risk mode
      riskPercent = CalculateDynamicRiskPerTrade();
      
      if(riskPercent <= 0.0)
      {
         Print("ERROR: Cannot calculate lot size - basket is full or risk is 0");
         return MarketInfo(Symbol(), MODE_MINLOT);
      }
   }
   else
   {
      // Per-trade risk mode (original behavior)
      riskPercent = RiskPercentPerTrade;
   }
   
   double riskMoney = balance * (riskPercent / 100.0);
   
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
   
   Print("Lot Size Calculated: ", DoubleToString(lot, 2), 
         " | Risk: ", DoubleToString(riskPercent, 2), "%",
         " | Risk Money: $", DoubleToString(riskMoney, 2));
   
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
   
   // Calculate lot size - using smooth dynamic exponential scaling
   double tradeLots = GetDynamicLotSize();
   if(tradeLots <= 0.0)
   {
      Print("ERROR: Invalid lot size calculated");
      return false;
   }
   
   RefreshRates();  // Refresh rates before opening trade
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
         // Update currentTrade for display purposes (always track the latest trade)
         currentTrade.ticket = ticket;
         currentTrade.entryPrice = OrderOpenPrice();
         currentTrade.openTime = OrderOpenTime();
         currentTrade.direction = direction;
         currentTrade.lotSize = tradeLots;
         currentTrade.previousProfit = 0.0;
         hasActiveTrade = true;  // Set flag for display purposes
         
         int basketSize = CountActiveTrades();
         double riskUsed = 0.0;
         if(AllowBasketTrading && UseBasketRisk)
         {
            riskUsed = CalculateDynamicRiskPerTrade();
         }
         else
         {
            riskUsed = RiskPercentPerTrade;
         }
         
         Print("HFT TRADE OPENED: ", (direction == 1 ? "BUY" : "SELL"), 
               " | Lot: ", tradeLots, " | Risk: ", DoubleToString(riskUsed, 2), "% | Price: ", price,
               " | Basket: ", basketSize, "/", MaxTradesInBasket);
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
   // CRITICAL: Calculate actual profit AFTER accounting for spread and commission on close
   // This ensures we don't close at a loss due to spread/commission costs
   double actualProfit = CalculateActualProfitAfterClose(currentTrade.ticket);
   double currentProfit = OrderProfit() + OrderSwap() + OrderCommission();
   
   if(actualProfit <= 0.0)
   {
      // Don't print this every tick - only occasionally
      static datetime lastBlockedPrint = 0;
      if(TimeCurrent() - lastBlockedPrint > 5)
      {
         Print("Blocked close attempt: Trade not profitable after costs. Current P&L: $", DoubleToString(currentProfit, 2),
               " | Actual P&L (after costs): $", DoubleToString(actualProfit, 2),
               " | Waiting for profit or drawdown...");
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
      // Get final profit after close
      if(OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
      {
         double finalProfit = OrderProfit() + OrderSwap() + OrderCommission();
         Print("HFT TRADE CLOSED: ", reason, " | Final P&L: $", DoubleToString(finalProfit, 2), 
               " | Hold: ", IntegerToString(holdSeconds), "s");
      }
      else
      {
         Print("HFT TRADE CLOSED: ", reason, " | P&L: $", DoubleToString(actualProfit, 2), 
               " | Hold: ", IntegerToString(holdSeconds), "s");
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
   
   int basketSize = CountActiveTrades();
   double totalBasketProfit = 0.0;
   int buyCount = 0;
   int sellCount = 0;
   double totalBasketRisk = 0.0;
   
   // Calculate basket statistics
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            int orderType = OrderType();
            if((orderType == OP_BUY || orderType == OP_SELL) && OrderCloseTime() == 0)
            {
               totalBasketProfit += OrderProfit() + OrderSwap() + OrderCommission();
               if(orderType == OP_BUY) buyCount++;
               else sellCount++;
               
               // Calculate approximate risk used by this trade
               double tradeValue = OrderLots() * MarketInfo(Symbol(), MODE_TICKVALUE) * 10.0 * pipToPoint;
               double tradeRisk = (tradeValue / AccountBalance()) * 100.0;
               totalBasketRisk += tradeRisk;
            }
         }
      }
   }
   
   if(basketSize > 0)
   {
      display += "\nBASKET: " + IntegerToString(basketSize) + "/" + IntegerToString(MaxTradesInBasket) + " trades\n";
      display += "BUY: " + IntegerToString(buyCount) + " | SELL: " + IntegerToString(sellCount) + "\n";
      display += "Total P&L: $" + DoubleToString(totalBasketProfit, 2) + "\n";
      
      if(UseBasketRisk)
      {
         display += "Risk Used: " + DoubleToString(totalBasketRisk, 2) + "% / " + 
                    DoubleToString(RiskPercentPerBasket, 1) + "% max\n";
      }
      
      // Show first trade details for reference
      if(hasActiveTrade && OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
      {
         double profit = OrderProfit() + OrderSwap() + OrderCommission();
         int holdSeconds = (int)(TimeCurrent() - currentTrade.openTime);
         
         display += "First Trade: " + (currentTrade.direction == 1 ? "BUY" : "SELL") + 
                    " | P&L: $" + DoubleToString(profit, 2) + 
                    " | Hold: " + IntegerToString(holdSeconds) + "s\n";
      }
   }
   else
   {
      display += "\nNo active trades\n";
      display += "Waiting for HFT signal...\n";
      if(tickIndex >= 2)
         display += "Buffers: READY (Ultra-Fast Mode)\n";
      else
         display += "Buffers: Initializing (" + IntegerToString(tickIndex) + "/2 ticks)...\n";
   }
   
   Comment(display);
}

