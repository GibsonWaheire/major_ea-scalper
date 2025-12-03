#property copyright "Copyright 2025, Hyperactive Pulse Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"
#property strict

// =====================================================================================================
// HYPERACTIVE PULSE SCALPER (MT4 VERSION)
// Strategy: 1-minute ON / 1-minute OFF pulse trading with millisecond-level exits
// - Opens 5-10 trades per basket in burst execution
// - Maximum 4 pending orders
// - Closes trades in milliseconds when profit target hit
// - Best strategy: Momentum + Volatility-based with fast exits
// =====================================================================================================

// ===== Pulse Trading Cycle =====
input bool     PulseTradingEnabled    = true;   // Enable 1-minute ON/OFF cycle
input int      PulseOnSeconds         = 60;      // Trading ON duration (seconds)
input int      PulseOffSeconds        = 60;      // Trading OFF duration (seconds)

// ===== Basket Configuration =====
input int      MinTradesPerBasket     = 5;       // Minimum trades per basket
input int      MaxTradesPerBasket     = 10;      // Maximum trades per basket
input int      TradesPerBurst         = 5;      // Trades opened per burst
input int      BurstDelayMS            = 10;     // Delay between trades in burst (milliseconds)

// ===== Pending Orders =====
input bool     UsePendingOrders       = true;    // Enable pending orders
input int      MaxPendingOrders       = 4;       // Maximum pending orders (STRICT LIMIT)
input double   PendingOrderSpacingPips = 2.0;    // Spacing between pending orders (pips)
input double   PendingOrderTPPips     = 5.0;    // Take profit for pending orders (pips)

// ===== Millisecond Exit Settings =====
input double   BasketProfitTargetUSD   = 2.0;    // Close basket when profit reaches this (USD)
input double   BasketProfitTargetPercent = 0.5;  // OR close at this % of balance (0 = use USD)
input double   MillisecondExitThreshold = 0.5;   // Minimum profit to exit (USD) - millisecond precision
input bool     CloseOnAnyProfit        = false;  // Close immediately on any profit (aggressive)
input int      MaxBasketHoldSeconds    = 60;     // Force close basket after X seconds (0 = disabled)

// ===== Lot Sizing =====
input double   LotSize                 = 0.01;   // Fixed lot size per trade
input bool     UseRiskBasedLots        = false; // Use risk-based lot sizing
input double   RiskPercentPerTrade      = 0.5;    // Risk % per trade (if risk-based enabled)

// ===== Strategy Settings =====
input int      MagicNumber             = 202501;
input int      TrendPeriod             = 10;     // EMA period for trend
input int      MomentumPeriod          = 9;      // RSI period for momentum
input double   MinMomentumStrength     = 15.0;   // Minimum RSI strength to trade
input double   MaxSpreadPips            = 5.0;   // Maximum spread filter
input bool     UseGoldOnly             = true;   // Trade XAUUSD only

// ===== Risk Management =====
input double   StopLossPips            = 20.0;   // Stop loss per trade (pips)
input double   MaxDrawdownPercent      = 10.0;   // Stop trading if drawdown exceeds %
input double   MaxDailyLossUSD         = 100.0;  // Stop trading if daily loss exceeds (USD)
input bool     EmergencyStopEnabled    = true;   // Enable emergency stop

// =====================================================================================================
// STRUCTURES & GLOBALS
// =====================================================================================================

struct PulseTrade {
   int      ticket;
   double   entryPrice;
   datetime openTime;
   int      openTickTime;
   int      direction;  // 1=BUY, -1=SELL
   double   lotSize;
};

// Helper function to initialize PulseTrade structure
void InitPulseTrade(PulseTrade &trade)
{
   trade.ticket = 0;
   trade.entryPrice = 0.0;
   trade.openTime = 0;
   trade.openTickTime = 0;
   trade.direction = 0;
   trade.lotSize = 0.0;
}

PulseTrade basketTrades[20];
int basketTradeCount = 0;

// Pulse cycle tracking
datetime pulseCycleStart = 0;
bool pulseTradingActive = false;
int pulseCycleCount = 0;

// Pending orders tracking
int pendingOrderCount = 0;
int pendingOrderTickets[4];

// Trading state
double dailyLossUSD = 0.0;
double initialBalance = 0.0;
double highestEquity = 0.0;
datetime lastDayReset = 0;
bool tradingEnabled = true;

// Price data
double pipToPoint = 0.0;
int digits = 0;

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("HYPERACTIVE PULSE SCALPER v1.00 (MT4)");
   Print("========================================");
   Print("Strategy: 1-minute ON/OFF pulse trading");
   Print("Basket: ", MinTradesPerBasket, "-", MaxTradesPerBasket, " trades");
   Print("Pending Orders: Max ", MaxPendingOrders);
   Print("Exit: Millisecond-level precision");
   Print("========================================");
   
   if(UseGoldOnly && Symbol() != "XAUUSD")
   {
      Alert("ERROR: This EA is optimized for XAUUSD only!");
      return(INIT_FAILED);
   }
   
   // Initialize symbol data
   digits = Digits;
   pipToPoint = Point;
   if(digits == 3 || digits == 5)
      pipToPoint *= 10.0;
   
   // Initialize trading state
   basketTradeCount = 0;
   pendingOrderCount = 0;
   pulseCycleStart = TimeCurrent();
   pulseTradingActive = true;  // Start with pulse ON to begin trading immediately
   pulseCycleCount = 1;
   Print("PULSE ON: Starting initial trading cycle (", PulseOnSeconds, " seconds)");
   
   initialBalance = AccountBalance();
   highestEquity = AccountEquity();
   lastDayReset = iTime(Symbol(), PERIOD_D1, 0);
   
   // Clear pending orders array
   for(int i = 0; i < 4; i++)
      pendingOrderTickets[i] = 0;
   
   Print("Initialization successful!");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // Close all pending orders
   CancelAllPendingOrders();
   
   Print("HyperactivePulseScalper deinitialized. Reason: ", reason);
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   // Daily reset check
   CheckDailyReset();
   
   // Risk management checks
   if(!PreFlightChecks())
      return;
   
   // Update pending orders count
   RefreshPendingOrdersCount();
   
   // Manage pulse cycle (1 minute ON/OFF)
   ManagePulseCycle();
   
   // Manage active basket trades (millisecond-level exits)
   ManageBasketTrades();
   
   // Open new trades if pulse is active
   if(pulseTradingActive && tradingEnabled)
   {
      // Check if we need to open more trades
      if(basketTradeCount < MinTradesPerBasket)
      {
         Print("Attempting to open basket burst - current: ", basketTradeCount, " / min: ", MinTradesPerBasket);
         OpenBasketBurst();
      }
      
      // Maintain pending orders (max 4)
      if(UsePendingOrders && pendingOrderCount < MaxPendingOrders)
      {
         MaintainPendingOrders();
      }
   }
   else
   {
      if(!pulseTradingActive)
         Print("Pulse is OFF - waiting for next cycle");
      if(!tradingEnabled)
         Print("Trading is DISABLED");
   }
   
   // Update display
   UpdateDisplay();
}

// =====================================================================================================
// PULSE CYCLE MANAGEMENT (1 minute ON/OFF)
// =====================================================================================================

void ManagePulseCycle()
{
   if(!PulseTradingEnabled)
   {
      pulseTradingActive = true;  // Always active if pulse disabled
      return;
   }
   
   datetime now = TimeCurrent();
   int elapsed = (int)(now - pulseCycleStart);
   
   if(!pulseTradingActive)
   {
      // Currently OFF - check if we should turn ON
      if(elapsed >= PulseOffSeconds)
      {
         pulseTradingActive = true;
         pulseCycleStart = now;
         pulseCycleCount++;
         Print("PULSE ON: Starting trading cycle #", pulseCycleCount, " (", PulseOnSeconds, " seconds)");
         
         // Close any existing basket before starting new cycle
         if(basketTradeCount > 0)
         {
            CloseBasket("Pulse cycle start - closing previous basket");
         }
      }
   }
   else
   {
      // Currently ON - check if we should turn OFF
      if(elapsed >= PulseOnSeconds)
      {
         pulseTradingActive = false;
         pulseCycleStart = now;
         Print("PULSE OFF: Stopping trading (", PulseOffSeconds, " seconds rest)");
         
         // Close all trades when pulse turns OFF
         if(basketTradeCount > 0)
         {
            CloseBasket("Pulse cycle end - closing basket");
         }
         
         // Cancel all pending orders
         CancelAllPendingOrders();
      }
   }
}

// =====================================================================================================
// BASKET TRADE MANAGEMENT (Millisecond-level exits)
// =====================================================================================================

void ManageBasketTrades()
{
   if(basketTradeCount == 0)
      return;
   
   // Calculate total basket profit (millisecond precision)
   double totalProfit = 0.0;
   int openTrades = 0;
   datetime oldestOpenTime = 0;
   
   for(int i = 0; i < basketTradeCount; i++)
   {
      if(basketTrades[i].ticket <= 0)
         continue;
      
      if(!OrderSelect(basketTrades[i].ticket, SELECT_BY_TICKET))
      {
         // Order closed - remove from basket
         basketTrades[i].ticket = 0;
         continue;
      }
      
      if(OrderCloseTime() > 0)
      {
         // Order already closed
         basketTrades[i].ticket = 0;
         continue;
      }
      
      openTrades++;
      double tradeProfit = OrderProfit() + OrderSwap() + OrderCommission();
      totalProfit += tradeProfit;
      
      if(oldestOpenTime == 0 || OrderOpenTime() < oldestOpenTime)
         oldestOpenTime = OrderOpenTime();
   }
   
   // Clean up closed trades
   CleanupBasketTrades();
   
   // MILLISECOND EXIT LOGIC
   bool shouldClose = false;
   string closeReason = "";
   
   // 1. Profit target hit (USD or %)
   double profitTarget = BasketProfitTargetUSD;
   if(BasketProfitTargetPercent > 0.0)
   {
      double balance = AccountBalance();
      profitTarget = balance * (BasketProfitTargetPercent / 100.0);
   }
   
   if(totalProfit >= profitTarget && totalProfit >= MillisecondExitThreshold)
   {
      shouldClose = true;
      closeReason = "Profit target hit: $" + DoubleToString(totalProfit, 2);
   }
   
   // 2. Close on any profit (if enabled)
   if(CloseOnAnyProfit && totalProfit > MillisecondExitThreshold)
   {
      shouldClose = true;
      closeReason = "Any profit exit: $" + DoubleToString(totalProfit, 2);
   }
   
   // 3. Time limit (force close after X seconds)
   if(MaxBasketHoldSeconds > 0 && oldestOpenTime > 0)
   {
      int holdSeconds = (int)(TimeCurrent() - oldestOpenTime);
      if(holdSeconds >= MaxBasketHoldSeconds)
      {
         shouldClose = true;
         closeReason = "Time limit reached: " + IntegerToString(holdSeconds) + " seconds";
      }
   }
   
   // 4. Stop loss (if basket loss exceeds threshold)
   if(totalProfit < 0 && MathAbs(totalProfit) >= MaxDailyLossUSD)
   {
      shouldClose = true;
      closeReason = "Basket stop loss: $" + DoubleToString(totalProfit, 2);
   }
   
   if(shouldClose)
   {
      CloseBasket(closeReason);
   }
}

void CleanupBasketTrades()
{
   int newCount = 0;
   for(int i = 0; i < basketTradeCount; i++)
   {
      if(basketTrades[i].ticket > 0)
      {
         if(newCount != i)
            basketTrades[newCount] = basketTrades[i];
         newCount++;
      }
   }
   basketTradeCount = newCount;
}

// =====================================================================================================
// OPEN BASKET BURST (5-10 trades)
// =====================================================================================================

void OpenBasketBurst()
{
   if(basketTradeCount >= MaxTradesPerBasket)
   {
      Print("Basket full: ", basketTradeCount, " trades (max: ", MaxTradesPerBasket, ")");
      return;
   }
   
   // Get trading signal
   int direction = GetTradingSignal();
   if(direction == 0)
   {
      Print("No trading signal - waiting...");
      return;  // No signal
   }
   
   // Calculate how many trades to open
   int tradesToOpen = MinTradesPerBasket - basketTradeCount;
   if(tradesToOpen > TradesPerBurst)
      tradesToOpen = TradesPerBurst;
   
   if(tradesToOpen > (MaxTradesPerBasket - basketTradeCount))
      tradesToOpen = MaxTradesPerBasket - basketTradeCount;
   
   // Open trades in burst
   int opened = 0;
   for(int i = 0; i < tradesToOpen; i++)
   {
      if(OpenTrade(direction))
      {
         opened++;
         if(i < tradesToOpen - 1 && BurstDelayMS > 0)
            Sleep(BurstDelayMS);
      }
   }
   
   if(opened > 0)
   {
      Print("BASKET BURST: Opened ", opened, " trades (direction: ", (direction == 1 ? "BUY" : "SELL"), ") | Total: ", basketTradeCount);
   }
}

bool OpenTrade(int direction)
{
   if(basketTradeCount >= 20)  // Max array size
      return false;
   
   double lotSize = CalculateLotSize();
   double price = (direction == 1) ? Ask : Bid;
   double sl = 0.0;
   double tp = 0.0;
   
   // Calculate stop loss
   if(StopLossPips > 0.0)
   {
      double slDistance = StopLossPips * pipToPoint;
      if(direction == 1)
         sl = NormalizeDouble(price - slDistance, digits);
      else
         sl = NormalizeDouble(price + slDistance, digits);
   }
   
   string comment = "PulseScalp_" + (direction == 1 ? "BUY" : "SELL");
   int orderType = (direction == 1) ? OP_BUY : OP_SELL;
   
   int ticket = OrderSend(Symbol(), orderType, lotSize, price, 3, sl, tp, comment, MagicNumber, 0, 
                          (direction == 1 ? clrGreen : clrRed));
   
   if(ticket > 0)
   {
      // Wait a bit for order to be processed
      Sleep(50);
      
      if(OrderSelect(ticket, SELECT_BY_TICKET))
      {
         PulseTrade newTrade;
         newTrade.ticket = ticket;
         newTrade.entryPrice = OrderOpenPrice();
         newTrade.openTime = OrderOpenTime();
         newTrade.openTickTime = (int)GetTickCount();
         newTrade.direction = direction;
         newTrade.lotSize = lotSize;
         
         basketTrades[basketTradeCount] = newTrade;
         basketTradeCount++;
         
         return true;
      }
   }
   else
   {
      Print("OrderSend failed: ", GetLastError());
   }
   
   return false;
}

// =====================================================================================================
// PENDING ORDERS MANAGEMENT (Max 4)
// =====================================================================================================

void MaintainPendingOrders()
{
   if(pendingOrderCount >= MaxPendingOrders)
      return;
   
   // Get signal direction
   int direction = GetTradingSignal();
   if(direction == 0)
      return;
   
   // Calculate how many pending orders to place
   int ordersToPlace = MaxPendingOrders - pendingOrderCount;
   
   double basePrice = (direction == 1) ? Ask : Bid;
   double spacing = PendingOrderSpacingPips * pipToPoint;
   double tpDistance = PendingOrderTPPips * pipToPoint;
   
   for(int i = 0; i < ordersToPlace; i++)
   {
      double orderPrice = 0.0;
      double tp = 0.0;
      int orderType = 0;
      
      if(direction == 1)
      {
         // BUYSTOP orders above current price
         orderPrice = NormalizeDouble(basePrice + (spacing * (i + 1)), digits);
         tp = NormalizeDouble(orderPrice + tpDistance, digits);
         orderType = OP_BUYSTOP;
      }
      else
      {
         // SELLSTOP orders below current price
         orderPrice = NormalizeDouble(basePrice - (spacing * (i + 1)), digits);
         tp = NormalizeDouble(orderPrice - tpDistance, digits);
         orderType = OP_SELLSTOP;
      }
      
      int ticket = OrderSend(Symbol(), orderType, LotSize, orderPrice, 3, 0, tp, 
                            "PulsePending_" + (direction == 1 ? "BUY" : "SELL"), 
                            MagicNumber, 0, clrBlue);
      
      if(ticket > 0)
      {
         pendingOrderTickets[pendingOrderCount] = ticket;
         pendingOrderCount++;
      }
      
      if(pendingOrderCount >= MaxPendingOrders)
         break;
   }
}

void RefreshPendingOrdersCount()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS))
      {
         if(OrderMagicNumber() == MagicNumber)
         {
            if(OrderSymbol() == Symbol())
            {
               int orderType = OrderType();
               if(orderType == OP_BUYSTOP || orderType == OP_SELLSTOP)
               {
                  count++;
               }
            }
         }
      }
   }
   pendingOrderCount = count;
}

void CancelAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS))
      {
         if(OrderMagicNumber() == MagicNumber)
         {
            if(OrderSymbol() == Symbol())
            {
               int orderType = OrderType();
               if(orderType == OP_BUYSTOP || orderType == OP_SELLSTOP)
               {
                  if(!OrderDelete(OrderTicket()))
                  {
                     Print("OrderDelete failed: ", GetLastError());
                  }
               }
            }
         }
      }
   }
   pendingOrderCount = 0;
   for(int i = 0; i < 4; i++)
      pendingOrderTickets[i] = 0;
}

// =====================================================================================================
// TRADING SIGNAL (Best Strategy: Momentum + Volatility)
// =====================================================================================================

int GetTradingSignal()
{
   // Check spread
   double spread = (Ask - Bid) / pipToPoint;
   if(spread > MaxSpreadPips)
   {
      Print("Signal blocked: Spread too high: ", DoubleToString(spread, 2), " pips (max: ", MaxSpreadPips, ")");
      return 0;
   }
   
   // Get indicator values (MT4 syntax)
   double ema = iMA(Symbol(), PERIOD_M1, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi = iRSI(Symbol(), PERIOD_M1, MomentumPeriod, PRICE_CLOSE, 0);
   double atr = iATR(Symbol(), PERIOD_M1, 14, 0);
   
   if(ema <= 0 || rsi <= 0 || atr <= 0)
   {
      Print("Signal blocked: Invalid indicator values");
      return 0;
   }
   
   double midPrice = (Bid + Ask) / 2.0;
   
   // Strategy: Momentum + Trend + Volatility (RELAXED for more signals)
   // BUY Signal: Price above EMA, RSI > 50, strong momentum
   // SELL Signal: Price below EMA, RSI < 50, strong momentum
   
   bool buySignal = false;
   bool sellSignal = false;
   
   // Trend filter
   bool uptrend = (midPrice > ema);
   bool downtrend = (midPrice < ema);
   
   // Momentum filter (relaxed - allow weaker momentum)
   double momentumStrength = MathAbs(rsi - 50.0);
   bool strongMomentum = (momentumStrength >= MinMomentumStrength);
   bool moderateMomentum = (momentumStrength >= (MinMomentumStrength * 0.7));  // 70% of required strength
   
   // Volatility filter (ATR-based) - relaxed
   double atrPips = atr / pipToPoint;
   bool acceptableVolatility = (atrPips > 0.5 && atrPips < 100.0);  // More lenient volatility range
   
   // BUY Signal (relaxed conditions)
   if(uptrend && rsi > 50.0 && (strongMomentum || moderateMomentum) && acceptableVolatility)
   {
      buySignal = true;
      Print("BUY SIGNAL: EMA=", DoubleToString(ema, 2), " RSI=", DoubleToString(rsi, 2), " ATR=", DoubleToString(atrPips, 2), " pips");
   }
   
   // SELL Signal (relaxed conditions)
   if(downtrend && rsi < 50.0 && (strongMomentum || moderateMomentum) && acceptableVolatility)
   {
      sellSignal = true;
      Print("SELL SIGNAL: EMA=", DoubleToString(ema, 2), " RSI=", DoubleToString(rsi, 2), " ATR=", DoubleToString(atrPips, 2), " pips");
   }
   
   if(buySignal && !sellSignal)
      return 1;  // BUY
   else if(sellSignal && !buySignal)
      return -1;  // SELL
   
   // Debug: Print why no signal
   if(!uptrend && !downtrend)
      Print("No signal: Price at EMA");
   else if(!strongMomentum && !moderateMomentum)
      Print("No signal: Momentum too weak: ", DoubleToString(momentumStrength, 2), " (need: ", MinMomentumStrength, ")");
   else if(!acceptableVolatility)
      Print("No signal: Volatility out of range: ", DoubleToString(atrPips, 2), " pips");
   
   return 0;  // No signal
}

// =====================================================================================================
// UTILITY FUNCTIONS
// =====================================================================================================

double CalculateLotSize()
{
   if(UseRiskBasedLots)
   {
      double balance = AccountBalance();
      double riskAmount = balance * (RiskPercentPerTrade / 100.0);
      double pipValue = GetPipValuePerLot();
      
      if(pipValue > 0 && StopLossPips > 0)
      {
         double riskLot = riskAmount / (StopLossPips * pipValue);
         return NormalizeDouble(MathMax(0.01, MathMin(riskLot, 1.0)), 2);
      }
   }
   
   return LotSize;
}

double GetPipValuePerLot()
{
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
   
   if(tickSize > 0 && pipToPoint > 0)
   {
      double pipValue = (tickValue / tickSize) * pipToPoint;
      return pipValue;
   }
   
   return 0.0;
}

void CloseBasket(string reason)
{
   Print("CLOSING BASKET: ", reason, " | Trades: ", basketTradeCount);
   
   double totalPL = 0.0;
   int closed = 0;
   
   for(int i = basketTradeCount - 1; i >= 0; i--)
   {
      if(basketTrades[i].ticket > 0)
      {
         if(OrderSelect(basketTrades[i].ticket, SELECT_BY_TICKET))
         {
            if(OrderCloseTime() == 0)  // Still open
            {
               double profit = OrderProfit() + OrderSwap() + OrderCommission();
               totalPL += profit;
               
               bool result = false;
               if(OrderType() == OP_BUY)
                  result = OrderClose(basketTrades[i].ticket, OrderLots(), Bid, 3, clrRed);
               else if(OrderType() == OP_SELL)
                  result = OrderClose(basketTrades[i].ticket, OrderLots(), Ask, 3, clrRed);
               
               if(result)
                  closed++;
            }
         }
      }
   }
   
   Print("Basket closed: ", closed, " trades | P&L: $", DoubleToString(totalPL, 2), " | Reason: ", reason);
   
   // Reset basket
   for(int i = 0; i < 20; i++)
      InitPulseTrade(basketTrades[i]);
   basketTradeCount = 0;
}

bool PreFlightChecks()
{
   // Check emergency stop
   if(EmergencyStopEnabled)
   {
      double equity = AccountEquity();
      double balance = AccountBalance();
      
      if(equity > highestEquity)
         highestEquity = equity;
      
      double drawdown = ((highestEquity - equity) / highestEquity) * 100.0;
      if(drawdown >= MaxDrawdownPercent)
      {
         tradingEnabled = false;
         Print("EMERGENCY STOP: Drawdown ", DoubleToString(drawdown, 2), "% exceeds limit");
         return false;
      }
      
      if(dailyLossUSD >= MaxDailyLossUSD)
      {
         tradingEnabled = false;
         Print("EMERGENCY STOP: Daily loss $", DoubleToString(dailyLossUSD, 2), " exceeds limit");
         return false;
      }
   }
   
   return true;
}

void CheckDailyReset()
{
   datetime currentDay = iTime(Symbol(), PERIOD_D1, 0);
   if(currentDay != lastDayReset)
   {
      dailyLossUSD = 0.0;
      lastDayReset = currentDay;
      tradingEnabled = true;
      Print("Daily reset: Trading re-enabled");
   }
}

void UpdateDisplay()
{
   string display = "\n=== HYPERACTIVE PULSE SCALPER ===\n";
   display += "Pulse: " + (pulseTradingActive ? "ON" : "OFF") + " | Cycle: #" + IntegerToString(pulseCycleCount) + "\n";
   display += "Basket: " + IntegerToString(basketTradeCount) + " trades\n";
   display += "Pending: " + IntegerToString(pendingOrderCount) + "/" + IntegerToString(MaxPendingOrders) + "\n";
   
   if(basketTradeCount > 0)
   {
      double basketProfit = 0.0;
      for(int i = 0; i < basketTradeCount; i++)
      {
         if(basketTrades[i].ticket > 0)
         {
            if(OrderSelect(basketTrades[i].ticket, SELECT_BY_TICKET))
            {
               if(OrderCloseTime() == 0)
               {
                  basketProfit += OrderProfit() + OrderSwap() + OrderCommission();
               }
            }
         }
      }
      display += "Basket P&L: $" + DoubleToString(basketProfit, 2) + "\n";
   }
   
   display += "Daily Loss: $" + DoubleToString(dailyLossUSD, 2) + "\n";
   display += "Status: " + (tradingEnabled ? "ACTIVE" : "STOPPED");
   
   Comment(display);
}

