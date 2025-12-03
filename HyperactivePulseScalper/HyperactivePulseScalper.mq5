#property copyright "Copyright 2025, Hyperactive Pulse Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

CTrade trade;

// =====================================================================================================
// HYPERACTIVE PULSE SCALPER
// Strategy: 1-minute ON / 1-minute OFF pulse trading with millisecond-level exits
// - Opens 5-10 trades per basket in burst execution
// - Maximum 4 pending orders
// - Closes trades in milliseconds when profit target hit
// - Best strategy: Momentum + Volatility-based with fast exits
// =====================================================================================================

input group "===== Pulse Trading Cycle ====="
input bool     PulseTradingEnabled    = true;   // Enable 1-minute ON/OFF cycle
input int      PulseOnSeconds         = 60;      // Trading ON duration (seconds)
input int      PulseOffSeconds        = 60;      // Trading OFF duration (seconds)

input group "===== Basket Configuration ====="
input int      MinTradesPerBasket     = 5;       // Minimum trades per basket
input int      MaxTradesPerBasket     = 10;      // Maximum trades per basket
input int      TradesPerBurst         = 5;      // Trades opened per burst
input int      BurstDelayMS            = 10;     // Delay between trades in burst (milliseconds)


input group "===== Millisecond Exit Settings ====="
input double   BasketProfitTargetUSD   = 2.0;    // Close basket when profit reaches this (USD)
input double   BasketProfitTargetPercent = 0.5;  // OR close at this % of balance (0 = use USD)
input double   MillisecondExitThreshold = 0.5;   // Minimum profit to exit (USD) - millisecond precision
input bool     CloseOnAnyProfit        = false;  // Close immediately on any profit (aggressive)
input int      MaxBasketHoldSeconds    = 60;     // Force close basket after X seconds (0 = disabled)

input group "===== Lot Sizing ====="
input double   LotSize                 = 0.01;   // Fixed lot size per trade
input bool     UseRiskBasedLots        = false; // Use risk-based lot sizing
input double   RiskPercentPerTrade      = 0.5;    // Risk % per trade (if risk-based enabled)

input group "===== Strategy Settings ====="
input int      MagicNumber             = 202501;
input int      TrendPeriod             = 10;     // EMA period for trend
input int      MomentumPeriod          = 9;      // RSI period for momentum
input double   MinMomentumStrength     = 15.0;   // Minimum RSI strength to trade
input double   MaxSpreadPips            = 5.0;   // Maximum spread filter
input bool     UseGoldOnly             = true;   // Trade XAUUSD only

input group "===== Risk Management ====="
input double   StopLossPips            = 20.0;   // Stop loss per trade (pips)
input double   MaxDrawdownPercent      = 10.0;   // Stop trading if drawdown exceeds %
input double   MaxDailyLossUSD         = 100.0;  // Stop trading if daily loss exceeds (USD)
input bool     EmergencyStopEnabled    = true;   // Enable emergency stop

// =====================================================================================================
// STRUCTURES & GLOBALS
// =====================================================================================================

struct PulseTrade {
   ulong    ticket;
   double   entryPrice;
   datetime openTime;
   ulong    openTickTime;
   int      direction;  // 1=BUY, -1=SELL
   double   lotSize;
};

PulseTrade basketTrades[20];
int basketTradeCount = 0;

// Pulse cycle tracking
datetime pulseCycleStart = 0;
bool pulseTradingActive = false;
int pulseCycleCount = 0;

// Pending orders tracking
int pendingOrderCount = 0;
ulong pendingOrderTickets[4];

// Trading state
double dailyLossUSD = 0.0;
double initialBalance = 0.0;
double highestEquity = 0.0;
datetime lastDayReset = 0;
bool tradingEnabled = true;

// Indicators
int emaHandle = INVALID_HANDLE;
int rsiHandle = INVALID_HANDLE;
int atrHandle = INVALID_HANDLE;

// Price data
double currentBid = 0.0;
double currentAsk = 0.0;
double pipToPoint = 0.0;
int digits = 0;

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("HYPERACTIVE PULSE SCALPER v1.00");
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
   digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   pipToPoint = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   if(digits == 3 || digits == 5)
      pipToPoint *= 10.0;
   
   // Initialize indicators (MT5 syntax)
   emaHandle = iMA(Symbol(), PERIOD_M1, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA indicator");
      return(INIT_FAILED);
   }
   
   rsiHandle = iRSI(Symbol(), PERIOD_M1, MomentumPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create RSI indicator");
      return(INIT_FAILED);
   }
   
   atrHandle = iATR(Symbol(), PERIOD_M1, 14);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR indicator");
      return(INIT_FAILED);
   }
   
   if(emaHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicators");
      return(INIT_FAILED);
   }
   
   // Initialize trading state
   basketTradeCount = 0;
   pendingOrderCount = 0;
   pulseCycleStart = TimeCurrent();
   pulseTradingActive = false;
   pulseCycleCount = 0;
   
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   highestEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   lastDayReset = CopyBarTime(PERIOD_D1, 0);
   
   // Set trade parameters
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Clear pending orders array
   ArrayInitialize(pendingOrderTickets, 0);
   
   Print("Initialization successful!");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // Close all pending orders
   CancelAllPendingOrders();
   
   // Release indicators
   if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   
   Print("HyperactivePulseScalper deinitialized. Reason: ", reason);
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   // Update price data
   if(!SymbolInfoTick(Symbol(), currentTick))
      return;
   
   currentBid = currentTick.bid;
   currentAsk = currentTick.ask;
   
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
         OpenBasketBurst();
      }
      
      // Maintain pending orders (max 4)
      if(UsePendingOrders && pendingOrderCount < MaxPendingOrders)
      {
         MaintainPendingOrders();
      }
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
      if(basketTrades[i].ticket == 0)
         continue;
      
      if(!PositionSelectByTicket(basketTrades[i].ticket))
      {
         // Position closed - remove from basket
         basketTrades[i].ticket = 0;
         continue;
      }
      
      openTrades++;
      double tradeProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      totalProfit += tradeProfit;
      
      if(oldestOpenTime == 0 || basketTrades[i].openTime < oldestOpenTime)
         oldestOpenTime = basketTrades[i].openTime;
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
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
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
      return;
   
   // Get trading signal
   int direction = GetTradingSignal();
   if(direction == 0)
      return;  // No signal
   
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
   double price = (direction == 1) ? currentAsk : currentBid;
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
   
   bool success = false;
   if(direction == 1)
      success = trade.Buy(lotSize, Symbol(), 0, sl, tp, comment);
   else
      success = trade.Sell(lotSize, Symbol(), 0, sl, tp, comment);
   
   if(success)
   {
      ulong ticket = trade.ResultOrder();
      if(ticket > 0)
      {
         // Wait for position to open
         Sleep(50);
         
         if(PositionSelectByTicket(ticket))
         {
            PulseTrade newTrade;
            newTrade.ticket = ticket;
            newTrade.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            newTrade.openTime = (datetime)PositionGetInteger(POSITION_TIME);
            newTrade.openTickTime = GetTickCount();
            newTrade.direction = direction;
            newTrade.lotSize = lotSize;
            
            basketTrades[basketTradeCount] = newTrade;
            basketTradeCount++;
            
            return true;
         }
      }
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
   
   double basePrice = (direction == 1) ? currentAsk : currentBid;
   double spacing = PendingOrderSpacingPips * pipToPoint;
   double tpDistance = PendingOrderTPPips * pipToPoint;
   
   for(int i = 0; i < ordersToPlace; i++)
   {
      double orderPrice = 0.0;
      double tp = 0.0;
      
      if(direction == 1)
      {
         // BUYSTOP orders above current price
         orderPrice = NormalizeDouble(basePrice + (spacing * (i + 1)), digits);
         tp = NormalizeDouble(orderPrice + tpDistance, digits);
         
         if(trade.BuyStop(LotSize, orderPrice, Symbol(), 0, tp, ORDER_TIME_GTC, 0, "PulsePending_BUY"))
         {
            ulong ticket = trade.ResultOrder();
            if(ticket > 0)
            {
               pendingOrderTickets[pendingOrderCount] = ticket;
               pendingOrderCount++;
            }
         }
      }
      else
      {
         // SELLSTOP orders below current price
         orderPrice = NormalizeDouble(basePrice - (spacing * (i + 1)), digits);
         tp = NormalizeDouble(orderPrice - tpDistance, digits);
         
         if(trade.SellStop(LotSize, orderPrice, Symbol(), 0, tp, ORDER_TIME_GTC, 0, "PulsePending_SELL"))
         {
            ulong ticket = trade.ResultOrder();
            if(ticket > 0)
            {
               pendingOrderTickets[pendingOrderCount] = ticket;
               pendingOrderCount++;
            }
         }
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
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetInteger(ORDER_MAGIC) == MagicNumber)
         {
            if(OrderGetString(ORDER_SYMBOL) == Symbol())
            {
               ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
               if(orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP)
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
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetInteger(ORDER_MAGIC) == MagicNumber)
         {
            if(OrderGetString(ORDER_SYMBOL) == Symbol())
            {
               ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
               if(orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP)
               {
                  trade.OrderDelete(ticket);
               }
            }
         }
      }
   }
   pendingOrderCount = 0;
   ArrayInitialize(pendingOrderTickets, 0);
}

// =====================================================================================================
// TRADING SIGNAL (Best Strategy: Momentum + Volatility)
// =====================================================================================================

int GetTradingSignal()
{
   // Check spread
   double spread = (currentAsk - currentBid) / pipToPoint;
   if(spread > MaxSpreadPips)
      return 0;
   
   // Get indicator values
   double emaBuffer[1];
   double rsiBuffer[1];
   double atrBuffer[1];
   
   if(CopyBuffer(emaHandle, 0, 0, 1, emaBuffer) <= 0)
      return 0;
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuffer) <= 0)
      return 0;
   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) <= 0)
      return 0;
   
   double ema = emaBuffer[0];
   double rsi = rsiBuffer[0];
   double atr = atrBuffer[0];
   double midPrice = (currentBid + currentAsk) / 2.0;
   
   // Strategy: Momentum + Trend + Volatility
   // BUY Signal: Price above EMA, RSI > 50, strong momentum
   // SELL Signal: Price below EMA, RSI < 50, strong momentum
   
   bool buySignal = false;
   bool sellSignal = false;
   
   // Trend filter
   bool uptrend = (midPrice > ema);
   bool downtrend = (midPrice < ema);
   
   // Momentum filter
   double momentumStrength = MathAbs(rsi - 50.0);
   bool strongMomentum = (momentumStrength >= MinMomentumStrength);
   
   // Volatility filter (ATR-based)
   double atrPips = atr / pipToPoint;
   bool acceptableVolatility = (atrPips > 1.0 && atrPips < 50.0);  // Not too calm, not too volatile
   
   // BUY Signal
   if(uptrend && rsi > 50.0 && strongMomentum && acceptableVolatility)
   {
      buySignal = true;
   }
   
   // SELL Signal
   if(downtrend && rsi < 50.0 && strongMomentum && acceptableVolatility)
   {
      sellSignal = true;
   }
   
   if(buySignal && !sellSignal)
      return 1;  // BUY
   else if(sellSignal && !buySignal)
      return -1;  // SELL
   
   return 0;  // No signal
}

// =====================================================================================================
// UTILITY FUNCTIONS
// =====================================================================================================

double CalculateLotSize()
{
   if(UseRiskBasedLots)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
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
   double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   
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
         if(PositionSelectByTicket(basketTrades[i].ticket))
         {
            double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            totalPL += profit;
            
            if(trade.PositionClose(basketTrades[i].ticket))
               closed++;
         }
      }
   }
   
   Print("Basket closed: ", closed, " trades | P&L: $", DoubleToString(totalPL, 2), " | Reason: ", reason);
   
   // Reset basket
   basketTradeCount = 0;
   ArrayInitialize(basketTrades, 0);
}

bool PreFlightChecks()
{
   // Check emergency stop
   if(EmergencyStopEnabled)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      
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
   datetime currentDay = CopyBarTime(PERIOD_D1, 0);
   if(currentDay != lastDayReset)
   {
      dailyLossUSD = 0.0;
      lastDayReset = currentDay;
      tradingEnabled = true;
      Print("Daily reset: Trading re-enabled");
   }
}

datetime CopyBarTime(ENUM_TIMEFRAMES timeframe, int shift)
{
   datetime buffer[1];
   if(CopyTime(Symbol(), timeframe, shift, 1, buffer) <= 0)
      return 0;
   return buffer[0];
}

MqlTick currentTick;

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
         if(basketTrades[i].ticket > 0 && PositionSelectByTicket(basketTrades[i].ticket))
         {
            basketProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         }
      }
      display += "Basket P&L: $" + DoubleToString(basketProfit, 2) + "\n";
   }
   
   display += "Daily Loss: $" + DoubleToString(dailyLossUSD, 2) + "\n";
   display += "Status: " + (tradingEnabled ? "ACTIVE" : "STOPPED");
   
   Comment(display);
}

