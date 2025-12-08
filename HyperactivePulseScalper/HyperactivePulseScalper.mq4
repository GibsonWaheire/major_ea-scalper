#property copyright "Copyright 2025, Hyperactive Pulse Scalper V2 - Ultra High Frequency Micro-Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "3.00"
#property strict

// =====================================================================================================
// HYPERACTIVE PULSE SCALPER V3 - ULTRA HIGH FREQUENCY MICRO-SCALPER
// Strategy: True HFT micro-scalper using 5-in-1 entry system
// - Tick-based only (no candles, no indicators)
// - 5 entry models: Tick Momentum, Direction Change, Micro Pullback, Spread Compression, Continuous Momentum
// - Ultra-fast exits with Smart Stop-Loss Engine
// - Risk-based lot sizing
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
};

HFTrade currentTrade;
bool hasActiveTrade = false;

// Tick buffers for momentum breakout - REDUCED for faster signals
double bidBuffer[3];
double askBuffer[3];
int tickIndex = 0;

// Spread buffer for compression detection - REDUCED for faster signals
double spreadBuffer[5];
int spreadIndex = 0;

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
   Print("Entry Strategy: TICK-BASED HFT");
   Print("Buffer Init: 2 ticks (was 5) | Spread Init: 3 ticks (was 10)");
   Print("Exit: Smart Stop-Loss Engine with profit exit");
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
      int direction = GetHFEntrySignal();
      
      if(direction != 0)
      {
         Print("Signal detected: ", (direction == 1 ? "BUY" : "SELL"), " - Attempting to open trade...");
         OpenHFTrade(direction);
      }
   }
   
   // Update display
   UpdateDisplay();
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
   
   // ===== SPREAD FILTER - Block garbage entries during wide spread =====
   double rawSpread = (Ask - Bid);
   double avgSpread = MarketInfo(Symbol(), MODE_SPREAD) * Point;
   
   // Block entries during wide spread or spikes
   if(rawSpread > avgSpread * 2.0)
      return 0;
   
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
   
   // ===== MAX HOLD TIME EXIT =====
   int holdTime = (int)(TimeCurrent() - currentTrade.openTime);
   if(holdTime >= MaxHoldSeconds)
   {
      double profit = OrderProfit() + OrderSwap() + OrderCommission();
      bool timeoutClose = false;
      if(OrderType() == OP_BUY)
         timeoutClose = OrderClose(currentTrade.ticket, OrderLots(), Bid, 3);
      else if(OrderType() == OP_SELL)
         timeoutClose = OrderClose(currentTrade.ticket, OrderLots(), Ask, 3);
      
      if(timeoutClose)
      {
         Print("HFT TRADE CLOSED: Max hold time reached | P&L: $", DoubleToString(profit, 2), 
               " | Hold: ", IntegerToString(holdTime), "s");
      }
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      return;
   }
   
   // Compute profit
   double profit = OrderProfit() + OrderSwap() + OrderCommission();
   
   // ===== SMART STOP-LOSS ENGINE (less aggressive) =====
   double tinyLoss = -(AccountBalance() * (RiskPercentPerTrade / 800.0));
   double maxAllowedLoss = -(AccountBalance() * (RiskPercentPerTrade / 200.0));
   
   // If profit is negative but >= tinyLoss, return (let small loss survive)
   if(profit < 0.0 && profit >= tinyLoss)
   {
      return;
   }
   
   // If profit < maxAllowedLoss, close trade immediately using direct OrderClose()
   if(profit < maxAllowedLoss)
   {
      bool result = false;
      if(OrderType() == OP_BUY)
         result = OrderClose(currentTrade.ticket, OrderLots(), Bid, 3, clrRed);
      else if(OrderType() == OP_SELL)
         result = OrderClose(currentTrade.ticket, OrderLots(), Ask, 3, clrRed);
      
      if(result)
      {
         Print("HFT TRADE CLOSED: Stop-loss triggered | P&L: $", DoubleToString(profit, 2), 
               " | Hold: ", IntegerToString(holdTime), "s");
         hasActiveTrade = false;
         currentTrade.ticket = 0;
      }
      return;
   }
   
   // ===== MINIMUM PROFIT THRESHOLD BEFORE CLOSING =====
   double minProfit = OrderLots() * 0.10;  // $0.10 per micro lot as baseline
   if(profit >= minProfit)
   {
      CloseHFTrade("Min profit reached");
      return;
   }
   
   // If profit is positive but below minimum threshold, let it continue
   return;
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
   
   // Check if AutoTrading is enabled
   if(!IsTradeAllowed())
   {
      static int lastWarningTime = 0;
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
   display += "Exit: Min profit threshold + Smart Stop-Loss Engine + Max hold time\n";
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
