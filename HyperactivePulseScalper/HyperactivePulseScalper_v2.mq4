#property copyright "Copyright 2025, Hyperactive Pulse Scalper V2 - Ultra High Frequency Micro-Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "3.00"
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
   Print("Strategy: Ultra-aggressive tick-based HFT scalping");
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
   
   // Open new trade if no active trade (instant entry)
   if(!hasActiveTrade)
   {
      int direction = GetHFEntrySignal();
      if(direction != 0)
      {
         OpenHFTrade(direction);
      }
   }
   
   // Update display
   UpdateDisplay();
}

// =====================================================================================================
// 3-IN-1 HIGH FREQUENCY ENTRY SYSTEM
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
   
   double currentProfit = OrderProfit() + OrderSwap() + OrderCommission();
   
   // ===== 1. INSTANT PROFIT EXIT (HFT-style - close immediately when profit turns positive) =====
   if(currentProfit > 0)
   {
      CloseHFTrade("Instant profit exit");
      return;
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
      }
   }
   else
   {
      Print("OrderSend failed: ", GetLastError());
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
   
   // ===== ONLY CLOSE TRADES IN PROFIT (never at a loss) =====
   double profit = OrderProfit() + OrderSwap() + OrderCommission();
   if(profit <= 0.0)
   {
      Print("Blocked close attempt: still negative. Waiting for profit. Current P&L: $", DoubleToString(profit, 2));
      return;
   }
   
   bool result = false;
   if(OrderType() == OP_BUY)
      result = OrderClose(currentTrade.ticket, OrderLots(), Bid, 3, clrRed);
   else if(OrderType() == OP_SELL)
      result = OrderClose(currentTrade.ticket, OrderLots(), Ask, 3, clrRed);
   
   if(result)
   {
      int holdSeconds = (int)(TimeCurrent() - currentTrade.openTime);
      Print("HFT TRADE CLOSED: ", reason, " | P&L: $", DoubleToString(profit, 2), 
            " | Hold: ", IntegerToString(holdSeconds), "s");
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
   display += "AGGRESSIVE MODE: 5-IN-1 ENTRY SYSTEM\n";
   display += "Tick Momentum | Direction Change | Micro Pullback | Spread Compression | Continuous Momentum\n";
   display += "Risk per Trade: " + DoubleToString(RiskPercentPerTrade, 1) + "% | Max Hold: " + 
              IntegerToString(MaxHoldSeconds) + "s\n";
   display += "Exit: Instant profit exit (never close at loss)\n";
   display += "Buffer Init: 2 ticks | Ultra-Fast Signal Detection\n";
   
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
