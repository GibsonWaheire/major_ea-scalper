#property copyright "Copyright 2025, Hypersmartpro - Smart Pending Orders with Anti-Spam Direction Locking"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "4.00"
#property strict

// =====================================================================================================
// HYPERSMARTPRO - ULTRA HIGH FREQUENCY MICRO-SCALPER WITH SMART PENDING ORDERS
// Strategy: True HFT micro-scalper using 5-in-1 entry system + Smart Pending Orders
// - Tick-based only (no candles, no indicators)
// - 5 entry models: Tick Momentum, Direction Change, Micro Pullback, Spread Compression, Continuous Momentum
// - Ultra-fast exits (3-10 seconds)
// - Smart Pending Orders with Anti-Spam Direction Locking
// - Pending orders expire after 3-5 seconds if not triggered
// =====================================================================================================

// ===== Trading Settings =====
input double   RiskPercentPerTrade   = 5.0;    // Risk % per trade (5% default)
input int      MagicNumber           = 202503;
input int      MaxHoldSeconds        = 5;      // Maximum hold time (3-7 seconds for HFT)
input double   PendingOrderBuffer    = 0.5;    // Buffer for pending orders (0.5 for Gold/XAUUSD, adjust for other symbols)
input int      PendingOrderExpirySeconds = 4;  // Pending order expiry time (3-5 seconds)

// ===== Profit Wave Exit (PWE) Settings =====
input double   SpikeGain              = 0.10;   // Profit spike threshold ($0.05 to $0.20)
input double   BreakevenLossLimit    = -0.10;  // Breakeven loss limit (e.g., -$0.10)
input double   MinProfitForExit      = 0.05;   // Minimum profit required before allowing exits ($)
input bool     UseMomentumFadeExit   = false;  // Enable momentum fade exit (can be too aggressive)
input bool     CloseAtLossOnTimeout  = false;  // Allow closing at loss after max hold time
input bool     UseTrailingStop       = true;   // Enable trailing stop to lock in profits
input double   TrailingStopDistance  = 0.05;   // Trailing stop distance ($) - close if profit drops this much from peak

// ===== Pause Strategy Settings =====
input bool     TradingEnabled        = true;   // Master switch - Enable/Disable trading
input bool     PauseAfterConsecutiveLosses = true;  // Pause after consecutive losses
input int      MaxConsecutiveLosses  = 3;      // Maximum consecutive losses before pause
input int      PauseDurationMinutes  = 15;     // Pause duration after consecutive losses (minutes)
input bool     PauseOnDailyLossLimit = true;   // Pause when daily loss limit reached
input double   DailyLossLimitPercent = 5.0;    // Daily loss limit (% of balance)
input bool     PauseOnDailyProfitTarget = false; // Pause when daily profit target reached
input double   DailyProfitTargetPercent = 10.0; // Daily profit target (% of balance)
input int      MaxDailyTrades        = 0;      // Max trades per day (0 = unlimited)
input bool     PauseOnDrawdown       = false;  // Pause when drawdown limit reached
input double   MaxDrawdownPercent    = 10.0;   // Maximum drawdown % before pause
input int      TradingStartHour      = 0;      // Start trading hour (0-23, 0=midnight)
input int      TradingEndHour        = 23;     // End trading hour (0-23, 23=11pm)

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
   double   highestProfit;   // Track highest profit reached for trailing stop
};

struct PendingOrder {
   int      ticket;
   double   price;
   datetime createTime;
   int      direction;  // 1=BUYSTOP, -1=SELLSTOP
};

HFTrade currentTrade;
bool hasActiveTrade = false;

// Pending order tracking
PendingOrder pendingOrders[2];  // Maximum 2 pending orders per direction
int pendingOrderCount = 0;
int lastSignalDirection = 0;  // Track last signal direction (1=BUY, -1=SELL, 0=none)

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

// Pause strategy tracking
bool tradingPaused = false;
string pauseReason = "";
datetime pauseUntil = 0;
int consecutiveLosses = 0;
datetime lastTradeCloseTime = 0;
double dailyProfit = 0.0;
int dailyTradeCount = 0;
int dailyWins = 0;
int dailyLosses = 0;
double accountStartBalance = 0.0;
double accountStartEquity = 0.0;
datetime lastDailyReset = 0;

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("HYPERSMARTPRO V4.00 - SMART PENDING ORDERS");
   Print("AGGRESSIVE MODE: 5-IN-1 ENTRY SYSTEM");
   Print("Tick Momentum | Direction Change | Micro Pullback | Spread Compression | Continuous Momentum");
   Print("========================================");
   Print("Risk per Trade: ", RiskPercentPerTrade, "%");
   Print("Max Hold Time: ", MaxHoldSeconds, " seconds");
   Print("Pending Order Buffer: ", PendingOrderBuffer);
   Print("Pending Order Expiry: ", PendingOrderExpirySeconds, " seconds");
   Print("Spike Gain: $", SpikeGain, " | Breakeven Loss Limit: $", BreakevenLossLimit);
   Print("Min Profit for Exit: $", MinProfitForExit, " | Momentum Fade: ", (UseMomentumFadeExit ? "ON" : "OFF"));
   Print("Trailing Stop: ", (UseTrailingStop ? "ON" : "OFF"), " | Distance: $", TrailingStopDistance);
   Print("Close at Loss on Timeout: ", (CloseAtLossOnTimeout ? "YES" : "NO"));
   Print("Strategy: Ultra-aggressive tick-based HFT scalping with Smart Pending Orders");
   Print("Buffer Init: 2 ticks (was 5) | Spread Init: 3 ticks (was 10)");
   Print("Exit: Profit Wave Exit (PWE) - Trailing Stop | Profit Spike | Max Hold Time");
   Print("No indicators | No candles | Maximum frequency");
   Print("========================================");
   
   // Initialize symbol data
   digits = Digits;
   pipToPoint = Point;
   if(digits == 3 || digits == 5)
      pipToPoint *= 10.0;
   
   // Initialize trading state
   hasActiveTrade = false;
   lastSignalDirection = 0;
   pendingOrderCount = 0;
   
   // Initialize pending order array
   for(int i = 0; i < 2; i++)
   {
      pendingOrders[i].ticket = 0;
      pendingOrders[i].price = 0.0;
      pendingOrders[i].createTime = 0;
      pendingOrders[i].direction = 0;
   }
   
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
   
   // Clean up any existing pending orders from previous session
   CleanupAllPendingOrders();
   
   // Find and track existing active trades
   FindAndTrackExistingTrades();
   
   // Initialize pause strategy variables
   tradingPaused = false;
   pauseReason = "";
   pauseUntil = 0;
   consecutiveLosses = 0;
   lastTradeCloseTime = 0;
   dailyProfit = 0.0;
   dailyTradeCount = 0;
   dailyWins = 0;
   dailyLosses = 0;
   accountStartBalance = AccountBalance();
   accountStartEquity = AccountEquity();
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   lastDailyReset = StringToTime(IntegerToString(dt.year) + "." + IntegerToString(dt.mon) + "." + IntegerToString(dt.day));
   
   Print("EA initialized - ready for ultra high-frequency trading with Smart Pending Orders");
   
   // Print trading status
   if(IsTradingAllowed())
   {
      Print("✓ Trading is ALLOWED - Ready to trade");
   }
   else
   {
      Print("⚠ Trading is BLOCKED - Reason: ", pauseReason);
      Print("   TradingEnabled: ", TradingEnabled);
      Print("   Check trading hours, pause conditions, and daily limits");
   }
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("Hypersmartpro V4 deinitialized. Reason: ", reason);
   CleanupAllPendingOrders();
}

// =====================================================================================================
// PAUSE STRATEGY FUNCTIONS
// =====================================================================================================

void CheckDailyReset()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime todayStart = StringToTime(IntegerToString(dt.year) + "." + IntegerToString(dt.mon) + "." + IntegerToString(dt.day));
   
   if(lastDailyReset < todayStart)
   {
      // New day - reset daily stats
      dailyProfit = 0.0;
      dailyTradeCount = 0;
      dailyWins = 0;
      dailyLosses = 0;
      accountStartBalance = AccountBalance();
      accountStartEquity = AccountEquity();
      lastDailyReset = todayStart;
      
      // Reset pause if it was a daily limit pause
      if(StringFind(pauseReason, "Daily") >= 0)
      {
         tradingPaused = false;
         pauseReason = "";
         pauseUntil = 0;
      }
      
      Print("Daily reset - New trading day started");
   }
}

bool IsTradingAllowed()
{
   // Master switch
   if(!TradingEnabled)
   {
      if(!tradingPaused)
      {
         tradingPaused = true;
         pauseReason = "Manual Pause (TradingEnabled = false)";
      }
      return false;
   }
   
   // Check if we're in a pause period
   if(tradingPaused)
   {
      if(pauseUntil > 0 && TimeCurrent() >= pauseUntil)
      {
         // Pause period expired
         tradingPaused = false;
         pauseReason = "";
         pauseUntil = 0;
         Print("Pause period expired - Trading resumed");
      }
      else
      {
         return false;  // Still paused
      }
   }
   
   // Check daily reset
   CheckDailyReset();
   
   // Check daily trade limit
   if(MaxDailyTrades > 0 && dailyTradeCount >= MaxDailyTrades)
   {
      if(!tradingPaused)
      {
         tradingPaused = true;
         pauseReason = "Daily Trade Limit Reached (" + IntegerToString(dailyTradeCount) + " trades)";
         Print("PAUSED: ", pauseReason);
      }
      return false;
   }
   
   // Check daily loss limit
   if(PauseOnDailyLossLimit && accountStartBalance > 0)
   {
      double lossPercent = (accountStartBalance - AccountEquity()) / accountStartBalance * 100.0;
      if(lossPercent >= DailyLossLimitPercent)
      {
         if(!tradingPaused)
         {
            tradingPaused = true;
            pauseReason = "Daily Loss Limit Reached (" + DoubleToString(lossPercent, 2) + "%)";
            Print("PAUSED: ", pauseReason);
         }
         return false;
      }
   }
   
   // Check daily profit target
   if(PauseOnDailyProfitTarget && accountStartBalance > 0)
   {
      double profitPercent = (AccountEquity() - accountStartBalance) / accountStartBalance * 100.0;
      if(profitPercent >= DailyProfitTargetPercent)
      {
         if(!tradingPaused)
         {
            tradingPaused = true;
            pauseReason = "Daily Profit Target Reached (" + DoubleToString(profitPercent, 2) + "%)";
            Print("PAUSED: ", pauseReason);
         }
         return false;
      }
   }
   
   // Check drawdown limit
   if(PauseOnDrawdown && accountStartEquity > 0)
   {
      double drawdownPercent = (accountStartEquity - AccountEquity()) / accountStartEquity * 100.0;
      if(drawdownPercent >= MaxDrawdownPercent)
      {
         if(!tradingPaused)
         {
            tradingPaused = true;
            pauseReason = "Drawdown Limit Reached (" + DoubleToString(drawdownPercent, 2) + "%)";
            Print("PAUSED: ", pauseReason);
         }
         return false;
      }
   }
   
   // Check trading hours (if set to 0-23, allow all hours)
   if(TradingStartHour == 0 && TradingEndHour == 23)
   {
      // Allow all hours - no restriction
   }
   else
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int currentHour = dt.hour;
      bool outsideHours = false;
      
      if(TradingStartHour > TradingEndHour)
      {
         // Trading hours span midnight (e.g., 22:00 to 6:00)
         if(currentHour < TradingStartHour && currentHour > TradingEndHour)
         {
            outsideHours = true;
         }
      }
      else
      {
         // Normal trading hours (e.g., 8:00 to 17:00)
         if(currentHour < TradingStartHour || currentHour > TradingEndHour)
         {
            outsideHours = true;
         }
      }
      
      if(outsideHours)
      {
         if(StringFind(pauseReason, "Trading Hours") < 0)
         {
            pauseReason = "Outside Trading Hours (Current: " + IntegerToString(currentHour) + 
                         ":00, Allowed: " + IntegerToString(TradingStartHour) + ":00 - " + 
                         IntegerToString(TradingEndHour) + ":00)";
         }
         return false;  // Outside trading hours
      }
   }
   
   // Clear pause reason if all checks passed
   if(pauseReason != "" && StringFind(pauseReason, "Manual Pause") < 0 && 
      StringFind(pauseReason, "Consecutive Losses") < 0 && 
      StringFind(pauseReason, "Daily") < 0 && 
      StringFind(pauseReason, "Drawdown") < 0)
   {
      // Clear temporary pause reasons
      pauseReason = "";
   }
   
   return true;  // All checks passed
}

void HandleConsecutiveLosses(double tradeProfit)
{
   if(tradeProfit < 0)
   {
      consecutiveLosses++;
      if(PauseAfterConsecutiveLosses && consecutiveLosses >= MaxConsecutiveLosses)
      {
         tradingPaused = true;
         pauseUntil = TimeCurrent() + (PauseDurationMinutes * 60);
         pauseReason = "Consecutive Losses (" + IntegerToString(consecutiveLosses) + " in a row)";
         Print("PAUSED: ", pauseReason, " - Resuming in ", PauseDurationMinutes, " minutes");
         consecutiveLosses = 0;  // Reset after pause
      }
   }
   else
   {
      // Winning trade - reset consecutive losses
      consecutiveLosses = 0;
   }
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   // Check if trading is allowed (pause strategy checks)
   if(!IsTradingAllowed())
   {
      // Still manage existing trades and pending orders even when paused
      if(hasActiveTrade)
      {
         ManageHFTrade();
      }
      ManagePendingOrders();
      UpdateDisplay();
      return;  // Don't open new trades when paused
   }
   
   // Update tick buffers
   UpdateTickBuffers();
   
   // Manage pending orders (check expiration, handle triggered orders)
   ManagePendingOrders();
   
   // Manage active trade (ultra-fast exits)
   if(hasActiveTrade)
   {
      ManageHFTrade();
   }
   
   // Always check for signal direction (for pending orders)
   int direction = GetHFEntrySignal();
   
   // Debug logging (only print occasionally to avoid spam)
   static int debugCounter = 0;
   debugCounter++;
   if(debugCounter % 100 == 0)  // Print every 100 ticks
   {
      Print("DEBUG: Signal=", direction, " | HasActiveTrade=", hasActiveTrade, " | TickIndex=", tickIndex, 
            " | TradingAllowed=", IsTradingAllowed());
   }
   
   if(direction != 0)
   {
      // Handle pending orders based on direction change (ALWAYS, regardless of active trade)
      HandlePendingOrdersForDirection(direction);
      
      // Open market order ONLY if no active trade
      if(!hasActiveTrade)
      {
         Print("Attempting to open ", (direction == 1 ? "BUY" : "SELL"), " trade...");
         OpenHFTrade(direction);
      }
      else
      {
         if(debugCounter % 100 == 0)
            Print("DEBUG: Signal detected but hasActiveTrade=true - skipping market order");
      }
   }
   
   // Update display
   UpdateDisplay();
}

// =====================================================================================================
// SMART PENDING ORDER MANAGEMENT
// =====================================================================================================

bool PendingOrdersExistForDirection(int direction)
{
   for(int i = 0; i < 2; i++)
   {
      if(pendingOrders[i].ticket > 0 && pendingOrders[i].direction == direction)
      {
         // Check if order still exists and is valid
         if(OrderSelect(pendingOrders[i].ticket, SELECT_BY_TICKET))
         {
            if((direction == 1 && OrderType() == OP_BUYSTOP) || 
               (direction == -1 && OrderType() == OP_SELLSTOP))
            {
               // Check if order hasn't expired
               int ageSeconds = (int)(TimeCurrent() - pendingOrders[i].createTime);
               if(ageSeconds < PendingOrderExpirySeconds)
               {
                  return true;  // Valid pending order exists
               }
            }
         }
      }
   }
   return false;  // No valid pending orders found
}

void HandlePendingOrdersForDirection(int newDirection)
{
   // Check if we need to create pending orders
   bool needToCreate = false;
   
   if(newDirection != lastSignalDirection)
   {
      // Direction has changed - need to create new pending orders
      needToCreate = true;
      
      // Delete opposite direction pending orders
      if(newDirection == 1)  // BUY signal
      {
         DeletePendingOrdersByDirection(-1);
      }
      else if(newDirection == -1)  // SELL signal
      {
         DeletePendingOrdersByDirection(1);
      }
      
      // Update last signal direction
      lastSignalDirection = newDirection;
   }
   else
   {
      // Direction hasn't changed - check if pending orders still exist
      if(!PendingOrdersExistForDirection(newDirection))
      {
         // Pending orders don't exist or have expired - need to recreate
         needToCreate = true;
         Print("Pending orders missing or expired for direction ", newDirection, " - recreating...");
      }
   }
   
   // Create pending orders if needed
   if(needToCreate)
   {
      if(newDirection == 1)  // BUY signal
      {
         // Create 2 BUYSTOP pending orders (Ask + buffer, Ask + buffer*2)
         CreateBuyStopPendingOrders();
      }
      else if(newDirection == -1)  // SELL signal
      {
         // Create 2 SELLSTOP pending orders (Bid - buffer, Bid - buffer*2)
         CreateSellStopPendingOrders();
      }
   }
}

void CreateBuyStopPendingOrders()
{
   // First, clean up any existing BUYSTOP orders for this symbol/magic
   DeletePendingOrdersByDirection(1);
   
   double tradeLots = CalculateRiskLotSize();
   if(tradeLots <= 0.0)
   {
      Print("ERROR: Invalid lot size for pending orders");
      return;
   }
   
   double price1 = Ask + PendingOrderBuffer;
   double price2 = Ask + (PendingOrderBuffer * 2.0);
   
   // Ensure prices are valid (BUYSTOP must be above Ask)
   if(price1 <= Ask)
   {
      price1 = Ask + (Point * 10);  // At least 10 points above Ask
   }
   if(price2 <= price1)
   {
      price2 = price1 + PendingOrderBuffer;
   }
   
   datetime expiry = (datetime)(TimeCurrent() + PendingOrderExpirySeconds);
   
   // Create first BUYSTOP order
   int ticket1 = OrderSend(Symbol(), OP_BUYSTOP, tradeLots, NormalizeDouble(price1, Digits), 3, 0, 0, 
                           "HYPERSMART_BUYSTOP_1", MagicNumber, expiry, clrBlue);
   
   if(ticket1 > 0)
   {
      AddPendingOrder(ticket1, price1, 1);
      Print("BUYSTOP Pending Order Created: Ticket=", ticket1, " | Price=", price1, " | Ask=", Ask);
   }
   else
   {
      Print("Failed to create BUYSTOP order 1: Error=", GetLastError(), " | Price=", price1, " | Ask=", Ask);
   }
   
   // Create second BUYSTOP order
   int ticket2 = OrderSend(Symbol(), OP_BUYSTOP, tradeLots, NormalizeDouble(price2, Digits), 3, 0, 0, 
                           "HYPERSMART_BUYSTOP_2", MagicNumber, expiry, clrBlue);
   
   if(ticket2 > 0)
   {
      AddPendingOrder(ticket2, price2, 1);
      Print("BUYSTOP Pending Order Created: Ticket=", ticket2, " | Price=", price2);
   }
   else
   {
      Print("Failed to create BUYSTOP order 2: Error=", GetLastError(), " | Price=", price2);
   }
}

void CreateSellStopPendingOrders()
{
   // First, clean up any existing SELLSTOP orders for this symbol/magic
   DeletePendingOrdersByDirection(-1);
   
   double tradeLots = CalculateRiskLotSize();
   if(tradeLots <= 0.0)
   {
      Print("ERROR: Invalid lot size for pending orders");
      return;
   }
   
   double price1 = Bid - PendingOrderBuffer;
   double price2 = Bid - (PendingOrderBuffer * 2.0);
   
   // Ensure prices are valid (SELLSTOP must be below Bid)
   if(price1 >= Bid)
   {
      price1 = Bid - (Point * 10);  // At least 10 points below Bid
   }
   if(price2 >= price1)
   {
      price2 = price1 - PendingOrderBuffer;
   }
   
   datetime expiry = (datetime)(TimeCurrent() + PendingOrderExpirySeconds);
   
   // Create first SELLSTOP order
   int ticket1 = OrderSend(Symbol(), OP_SELLSTOP, tradeLots, NormalizeDouble(price1, Digits), 3, 0, 0, 
                           "HYPERSMART_SELLSTOP_1", MagicNumber, expiry, clrOrange);
   
   if(ticket1 > 0)
   {
      AddPendingOrder(ticket1, price1, -1);
      Print("SELLSTOP Pending Order Created: Ticket=", ticket1, " | Price=", price1, " | Bid=", Bid);
   }
   else
   {
      Print("Failed to create SELLSTOP order 1: Error=", GetLastError(), " | Price=", price1, " | Bid=", Bid);
   }
   
   // Create second SELLSTOP order
   int ticket2 = OrderSend(Symbol(), OP_SELLSTOP, tradeLots, NormalizeDouble(price2, Digits), 3, 0, 0, 
                           "HYPERSMART_SELLSTOP_2", MagicNumber, expiry, clrOrange);
   
   if(ticket2 > 0)
   {
      AddPendingOrder(ticket2, price2, -1);
      Print("SELLSTOP Pending Order Created: Ticket=", ticket2, " | Price=", price2);
   }
   else
   {
      Print("Failed to create SELLSTOP order 2: Error=", GetLastError(), " | Price=", price2);
   }
}

void AddPendingOrder(int ticket, double price, int direction)
{
   // Find empty slot or replace oldest
   int slot = -1;
   for(int i = 0; i < 2; i++)
   {
      if(pendingOrders[i].ticket == 0)
      {
         slot = i;
         break;
      }
   }
   
   if(slot == -1)
   {
      // No empty slot, find oldest
      datetime oldestTime = TimeCurrent();
      for(int i = 0; i < 2; i++)
      {
         if(pendingOrders[i].createTime < oldestTime)
         {
            oldestTime = pendingOrders[i].createTime;
            slot = i;
         }
      }
   }
   
   if(slot >= 0)
   {
      pendingOrders[slot].ticket = ticket;
      pendingOrders[slot].price = price;
      pendingOrders[slot].createTime = TimeCurrent();
      pendingOrders[slot].direction = direction;
      pendingOrderCount++;
   }
}

void DeletePendingOrdersByDirection(int direction)
{
   for(int i = 0; i < 2; i++)
   {
      if(pendingOrders[i].ticket > 0 && pendingOrders[i].direction == direction)
      {
         if(OrderSelect(pendingOrders[i].ticket, SELECT_BY_TICKET))
         {
            if(OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
            {
               if(OrderDelete(pendingOrders[i].ticket))
               {
                  Print("Deleted pending order: Ticket=", pendingOrders[i].ticket, 
                        " | Direction=", (direction == 1 ? "BUYSTOP" : "SELLSTOP"));
                  pendingOrders[i].ticket = 0;
                  pendingOrders[i].price = 0.0;
                  pendingOrders[i].createTime = 0;
                  pendingOrders[i].direction = 0;
                  pendingOrderCount--;
               }
            }
         }
         else
         {
            // Order doesn't exist, clear from array
            pendingOrders[i].ticket = 0;
            pendingOrders[i].price = 0.0;
            pendingOrders[i].createTime = 0;
            pendingOrders[i].direction = 0;
            pendingOrderCount--;
         }
      }
   }
}

void ManagePendingOrders()
{
   for(int i = 0; i < 2; i++)
   {
      if(pendingOrders[i].ticket > 0)
      {
         if(OrderSelect(pendingOrders[i].ticket, SELECT_BY_TICKET))
         {
            // Check if order was closed (shouldn't happen for pending, but check anyway)
            if(OrderCloseTime() > 0)
            {
               // Order was closed, remove from tracking
               pendingOrders[i].ticket = 0;
               pendingOrders[i].price = 0.0;
               pendingOrders[i].createTime = 0;
               pendingOrders[i].direction = 0;
               pendingOrderCount--;
               continue;
            }
            
            // Check if order was triggered (converted to market order)
            if(OrderType() == OP_BUY || OrderType() == OP_SELL)
            {
               // Pending order was triggered - it's now a market order
               // Track it like a regular trade (it will follow PWE exit logic)
               if(!hasActiveTrade)
               {
                  double currentProfit = OrderProfit() + OrderSwap() + OrderCommission();
                  currentTrade.ticket = pendingOrders[i].ticket;
                  currentTrade.entryPrice = OrderOpenPrice();
                  currentTrade.openTime = OrderOpenTime();
                  currentTrade.direction = (OrderType() == OP_BUY) ? 1 : -1;
                  currentTrade.lotSize = OrderLots();
                  currentTrade.previousProfit = currentProfit;  // Initialize to current profit for PWE
                  currentTrade.highestProfit = currentProfit;   // Initialize highest profit
                  hasActiveTrade = true;
                  
                  Print("Pending order triggered: Ticket=", pendingOrders[i].ticket, 
                        " | Now tracking as active trade | Current P&L: $", DoubleToString(currentProfit, 2));
               }
               
               // Remove from pending order tracking
               pendingOrders[i].ticket = 0;
               pendingOrders[i].price = 0.0;
               pendingOrders[i].createTime = 0;
               pendingOrders[i].direction = 0;
               pendingOrderCount--;
            }
            // Check if order expired (3-5 seconds) - still a pending order
            else if(OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
            {
               int ageSeconds = (int)(TimeCurrent() - pendingOrders[i].createTime);
               if(ageSeconds >= PendingOrderExpirySeconds)
               {
                  // Order expired, delete it
                  if(OrderDelete(pendingOrders[i].ticket))
                  {
                     Print("Pending order expired and deleted: Ticket=", pendingOrders[i].ticket, 
                           " | Age=", ageSeconds, "s");
                     pendingOrders[i].ticket = 0;
                     pendingOrders[i].price = 0.0;
                     pendingOrders[i].createTime = 0;
                     pendingOrders[i].direction = 0;
                     pendingOrderCount--;
                  }
               }
            }
         }
         else
         {
            // Order doesn't exist anymore (might have been deleted manually or expired)
            pendingOrders[i].ticket = 0;
            pendingOrders[i].price = 0.0;
            pendingOrders[i].createTime = 0;
            pendingOrders[i].direction = 0;
            pendingOrderCount--;
         }
      }
   }
}

void CleanupAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            if(OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
            {
               OrderDelete(OrderTicket());
            }
         }
      }
   }
   
   // Clear pending order array
   for(int i = 0; i < 2; i++)
   {
      pendingOrders[i].ticket = 0;
      pendingOrders[i].price = 0.0;
      pendingOrders[i].createTime = 0;
      pendingOrders[i].direction = 0;
   }
   pendingOrderCount = 0;
}

void FindAndTrackExistingTrades()
{
   // First, try to find trades with our magic number
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            if(OrderType() == OP_BUY || OrderType() == OP_SELL)
            {
               if(OrderCloseTime() == 0)  // Trade is still open
               {
                  // Track this trade
                  double currentProfit = OrderProfit() + OrderSwap() + OrderCommission();
                  currentTrade.ticket = OrderTicket();
                  currentTrade.entryPrice = OrderOpenPrice();
                  currentTrade.openTime = OrderOpenTime();
                  currentTrade.direction = (OrderType() == OP_BUY) ? 1 : -1;
                  currentTrade.lotSize = OrderLots();
                  currentTrade.previousProfit = currentProfit;  // Initialize to current profit for PWE
                  currentTrade.highestProfit = currentProfit;   // Initialize highest profit
                  hasActiveTrade = true;
                  
                  Print("Found existing active trade: Ticket=", currentTrade.ticket, 
                        " | Type=", (currentTrade.direction == 1 ? "BUY" : "SELL"),
                        " | Price=", currentTrade.entryPrice,
                        " | Current P&L: $", DoubleToString(currentProfit, 2));
                  return;  // Found one, exit
               }
            }
         }
      }
   }
   
   // If no trade found with magic number, check for any open trade on this symbol
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol())
         {
            if(OrderType() == OP_BUY || OrderType() == OP_SELL)
            {
               if(OrderCloseTime() == 0)  // Trade is still open
               {
                  // Track this trade (even if it doesn't have our magic number)
                  double currentProfit = OrderProfit() + OrderSwap() + OrderCommission();
                  currentTrade.ticket = OrderTicket();
                  currentTrade.entryPrice = OrderOpenPrice();
                  currentTrade.openTime = OrderOpenTime();
                  currentTrade.direction = (OrderType() == OP_BUY) ? 1 : -1;
                  currentTrade.lotSize = OrderLots();
                  currentTrade.previousProfit = currentProfit;  // Initialize to current profit for PWE
                  currentTrade.highestProfit = currentProfit;   // Initialize highest profit
                  hasActiveTrade = true;
                  
                  Print("Found existing active trade (no magic match): Ticket=", currentTrade.ticket, 
                        " | Type=", (currentTrade.direction == 1 ? "BUY" : "SELL"),
                        " | Price=", currentTrade.entryPrice,
                        " | Magic=", OrderMagicNumber(),
                        " | Current P&L: $", DoubleToString(currentProfit, 2));
                  return;  // Found one, exit
               }
            }
         }
      }
   }
   
   Print("No existing active trades found");
}

// =====================================================================================================
// 5-IN-1 HIGH FREQUENCY ENTRY SYSTEM
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
   {
      // No trade tracked, check if there are any active trades
      FindAndTrackExistingTrades();
      return;
   }
   
   if(!OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
   {
      // Trade doesn't exist anymore, check for other trades
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      FindAndTrackExistingTrades();
      return;
   }
   
   if(OrderCloseTime() > 0)
   {
      // Trade was closed (manually or by another process), check for other trades
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      FindAndTrackExistingTrades();
      return;
   }
   
   double currentProfit = OrderProfit() + OrderSwap() + OrderCommission();
   int holdSeconds = (int)(TimeCurrent() - currentTrade.openTime);
   
   // Update highest profit reached
   if(currentProfit > currentTrade.highestProfit)
   {
      currentTrade.highestProfit = currentProfit;
   }
   
   // ===== PROFIT WAVE EXIT (PWE) STRATEGY =====
   
   // Only apply exit logic if trade has reached minimum profit threshold
   // This prevents closing trades too early
   
   // TRAILING STOP: Close if profit dropped from peak by TrailingStopDistance
   if(UseTrailingStop && currentTrade.highestProfit >= MinProfitForExit)
   {
      double profitDropFromPeak = currentTrade.highestProfit - currentProfit;
      if(profitDropFromPeak >= TrailingStopDistance)
      {
         CloseHFTrade("Trailing stop exit (PWE) - Peak: $" + DoubleToString(currentTrade.highestProfit, 2) + 
                      " | Drop: $" + DoubleToString(profitDropFromPeak, 2));
         return;
      }
   }
   
   // 2. Exit on Profit Spike: If profit spike >= SpikeGain AND current profit >= MinProfitForExit
   double profitChange = currentProfit - currentTrade.previousProfit;
   if(profitChange >= SpikeGain && currentProfit >= MinProfitForExit)
   {
      CloseHFTrade("Profit spike exit (PWE) - Spike: $" + DoubleToString(profitChange, 2));
      return;
   }
   
   // 1. Exit on Momentum Fade: Only if enabled AND profit >= MinProfitForExit
   // This prevents closing trades on small fluctuations
   if(UseMomentumFadeExit && currentProfit >= MinProfitForExit)
   {
      if(currentProfit > 0 && currentProfit < currentTrade.previousProfit)
      {
         // Additional check: only exit if profit dropped significantly (not just small fluctuation)
         double profitDrop = currentTrade.previousProfit - currentProfit;
         if(profitDrop >= (MinProfitForExit * 0.5))  // Must drop by at least 50% of min profit
         {
            CloseHFTrade("Momentum fade exit (PWE) - Drop: $" + DoubleToString(profitDrop, 2));
            return;
         }
      }
   }
   
   // 3. Max Hold Time Exit: Only close if profit is positive (or if CloseAtLossOnTimeout enabled)
   if(holdSeconds >= MaxHoldSeconds)
   {
      if(CloseAtLossOnTimeout)
      {
         // Allow closing at breakeven/small loss
         if(currentProfit > BreakevenLossLimit)
         {
            CloseHFTrade("Max hold time exit (PWE) - Time: " + IntegerToString(holdSeconds) + "s");
            return;
         }
      }
      else
      {
         // Only close if profit is positive (safer)
         if(currentProfit > 0)
         {
            CloseHFTrade("Max hold time exit (PWE) - Time: " + IntegerToString(holdSeconds) + "s");
            return;
         }
      }
   }
   
   // Update previousProfit for next tick
   currentTrade.previousProfit = currentProfit;
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

void OpenHFTrade(int direction)
{
   if(direction == 0)
      return;
   
   double tradeLots = CalculateRiskLotSize();
   if(tradeLots <= 0.0)
   {
      Print("ERROR: Invalid lot size calculated");
      return;
   }
   
   double price = (direction == 1) ? Ask : Bid;
   double sl = 0.0;  // NO STOP LOSS
   double tp = 0.0;  // NO TAKE PROFIT
   
   string comment = "HYPERSMART_" + (direction == 1 ? "BUY" : "SELL");
   int orderType = (direction == 1) ? OP_BUY : OP_SELL;
   
   // Check if trading is allowed one more time before sending order
   if(!IsTradingAllowed())
   {
      Print("ERROR: Cannot open trade - Trading not allowed. Reason: ", pauseReason);
      return;
   }
   
   // Verify AutoTrading is enabled
   if(!IsTradeAllowed())
   {
      Print("ERROR: Cannot open trade - AutoTrading is disabled in MT4. Please enable AutoTrading button.");
      return;
   }
   
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
         currentTrade.highestProfit = 0.0;  // Initialize highest profit
         hasActiveTrade = true;
         
         Print("HYPERSMART TRADE OPENED: ", (direction == 1 ? "BUY" : "SELL"), 
               " | Lot: ", tradeLots, " | Risk: ", RiskPercentPerTrade, "% | Price: ", price);
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
}

// =====================================================================================================
// TRADE CLOSING
// =====================================================================================================

void CloseHFTrade(string reason)
{
   if(!hasActiveTrade || currentTrade.ticket <= 0)
      return;
   
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
   
   // Get current profit for logging
   double profit = OrderProfit() + OrderSwap() + OrderCommission();
   
   // PWE strategy handles exit logic - execute the close
   bool result = false;
   if(OrderType() == OP_BUY)
      result = OrderClose(currentTrade.ticket, OrderLots(), Bid, 3, clrRed);
   else if(OrderType() == OP_SELL)
      result = OrderClose(currentTrade.ticket, OrderLots(), Ask, 3, clrRed);
   
   if(result)
   {
      int holdSeconds = (int)(TimeCurrent() - currentTrade.openTime);
      Print("HYPERSMART TRADE CLOSED: ", reason, " | P&L: $", DoubleToString(profit, 2), 
            " | Hold: ", IntegerToString(holdSeconds), "s");
      
      // Track daily stats and consecutive losses
      dailyProfit += profit;
      dailyTradeCount++;
      lastTradeCloseTime = TimeCurrent();
      
      if(profit > 0)
      {
         dailyWins++;
      }
      else
      {
         dailyLosses++;
      }
      
      // Handle consecutive losses and pause logic
      HandleConsecutiveLosses(profit);
   }
   else
   {
      Print("OrderClose failed: ", GetLastError());
   }
   
   hasActiveTrade = false;
   currentTrade.ticket = 0;
   
   // After closing, check if there are other active trades to manage
   FindAndTrackExistingTrades();
}

// =====================================================================================================
// DISPLAY
// =====================================================================================================

void UpdateDisplay()
{
   string display = "\n=== HYPERSMARTPRO V4.00 - SMART PENDING ORDERS ===\n";
   display += "AGGRESSIVE MODE: 5-IN-1 ENTRY SYSTEM\n";
   display += "Tick Momentum | Direction Change | Micro Pullback | Spread Compression | Continuous Momentum\n";
   display += "Risk per Trade: " + DoubleToString(RiskPercentPerTrade, 1) + "% | Max Hold: " + 
              IntegerToString(MaxHoldSeconds) + "s\n";
   display += "Exit: Profit Wave Exit (PWE) | Spike: $" + DoubleToString(SpikeGain, 2) + 
              " | Breakeven: $" + DoubleToString(BreakevenLossLimit, 2) + "\n";
   display += "Buffer Init: 2 ticks | Ultra-Fast Signal Detection\n";
   display += "Pending Orders: " + IntegerToString(pendingOrderCount) + " active\n";
   display += "Last Signal Direction: " + (lastSignalDirection == 1 ? "BUY" : (lastSignalDirection == -1 ? "SELL" : "NONE")) + "\n";
   
   // Show pause status
   if(tradingPaused)
   {
      display += "\n⚠⚠⚠ TRADING PAUSED ⚠⚠⚠\n";
      display += "Reason: " + pauseReason + "\n";
      if(pauseUntil > 0)
      {
         int minutesLeft = (int)((pauseUntil - TimeCurrent()) / 60);
         if(minutesLeft > 0)
            display += "Resuming in: " + IntegerToString(minutesLeft) + " minutes\n";
         else
            display += "Resuming soon...\n";
      }
   }
   else
   {
      display += "\n✓ Trading Active\n";
   }
   
   // Show daily stats
   double winRate = (dailyTradeCount > 0) ? (double)dailyWins * 100.0 / dailyTradeCount : 0.0;
   display += "\n--- Daily Stats ---\n";
   display += "Trades: " + IntegerToString(dailyTradeCount);
   if(MaxDailyTrades > 0)
      display += " / " + IntegerToString(MaxDailyTrades);
   display += " | Wins: " + IntegerToString(dailyWins) + " | Losses: " + IntegerToString(dailyLosses);
   display += " | Win Rate: " + DoubleToString(winRate, 1) + "%\n";
   display += "Daily P&L: $" + DoubleToString(dailyProfit, 2);
   if(accountStartBalance > 0)
   {
      double dailyPercent = (AccountEquity() - accountStartBalance) / accountStartBalance * 100.0;
      display += " (" + DoubleToString(dailyPercent, 2) + "%)\n";
   }
   else
   {
      display += "\n";
   }
   if(consecutiveLosses > 0)
      display += "Consecutive Losses: " + IntegerToString(consecutiveLosses);
   if(MaxConsecutiveLosses > 0)
      display += " / " + IntegerToString(MaxConsecutiveLosses);
   if(consecutiveLosses > 0)
      display += "\n";
   
   if(hasActiveTrade)
   {
      if(OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
      {
         double profit = OrderProfit() + OrderSwap() + OrderCommission();
         int holdSeconds = (int)(TimeCurrent() - currentTrade.openTime);
         
         double profitChange = profit - currentTrade.previousProfit;
         double profitDropFromPeak = currentTrade.highestProfit - profit;
         display += "\nTRADE: " + (currentTrade.direction == 1 ? "BUY" : "SELL") + "\n";
         display += "P&L: $" + DoubleToString(profit, 2) + " | Peak: $" + DoubleToString(currentTrade.highestProfit, 2) + "\n";
         display += "Change: $" + DoubleToString(profitChange, 2);
         if(UseTrailingStop && currentTrade.highestProfit >= MinProfitForExit)
            display += " | Drop from Peak: $" + DoubleToString(profitDropFromPeak, 2) + " / $" + DoubleToString(TrailingStopDistance, 2);
         display += "\n";
         display += "Hold: " + IntegerToString(holdSeconds) + "s / " + 
                    IntegerToString(MaxHoldSeconds) + "s max\n";
         if(profit > 0 && profit < currentTrade.previousProfit)
            display += "⚠ Momentum Fading\n";
         if(profitChange >= SpikeGain)
            display += "⚡ Profit Spike Detected!\n";
         if(UseTrailingStop && profitDropFromPeak >= TrailingStopDistance * 0.8)
            display += "⚠ Trailing Stop Near (" + DoubleToString(profitDropFromPeak, 2) + " >= " + DoubleToString(TrailingStopDistance, 2) + ")\n";
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
   
   // Show pending orders info
   if(pendingOrderCount > 0)
   {
      display += "\n--- Pending Orders ---\n";
      for(int i = 0; i < 2; i++)
      {
         if(pendingOrders[i].ticket > 0)
         {
            if(OrderSelect(pendingOrders[i].ticket, SELECT_BY_TICKET))
            {
               int ageSeconds = (int)(TimeCurrent() - pendingOrders[i].createTime);
               display += "Ticket: " + IntegerToString(pendingOrders[i].ticket) + 
                         " | " + (pendingOrders[i].direction == 1 ? "BUYSTOP" : "SELLSTOP") +
                         " | Price: " + DoubleToString(pendingOrders[i].price, digits) +
                         " | Age: " + IntegerToString(ageSeconds) + "s\n";
            }
         }
      }
   }
   
   Comment(display);
}

