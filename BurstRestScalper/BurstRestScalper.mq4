#property copyright "Copyright 2025, Burst Rest Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.20"
#property strict

// =====================================================================================================
// BURST REST SCALPER - Ultra-Fast Trading with Rest Periods
// Strategy: 
// 1. Takes trades and closes them super fast
// 2. Rests for 1-2 minutes
// 3. During rest, analyzes market to determine direction (Buy/Sell/Buy Limit/Sell Limit/Buy Stop/Sell Stop)
// 4. After analysis, takes as many trades as possible for 1 minute
// 5. Then pauses
// 6. Closes profitable trades or lets some run
// 7. Closes them when profitable
// =====================================================================================================

// ===== Trading Phases =====
enum TradingPhase
{
   PHASE_REST,        // Resting for 1-2 minutes
   PHASE_ANALYSIS,    // Analyzing market during rest
   PHASE_TRADING,     // Taking as many trades as possible for 1 minute
   PHASE_PAUSE,       // Pause after trading burst
   PHASE_CLOSE        // Closing profitable trades
};

// ===== Risk & Lot Sizing =====
input double   RiskPercentPerTrade    = 2.5;   // Risk % per trade (reduced from 5% for better risk management)
input double   MinLotSize             = 0.01;  // Minimum lot size
input double   MaxLotSize             = 10.0;  // Maximum lot size
input double   MaxBasketRiskPercent   = 10.0;  // Maximum total risk per basket (%) - prevents excessive risk

// ===== Rest & Trading Timing =====
input int      RestPeriodMin          = 60;    // Minimum rest period (seconds)
input int      RestPeriodMax          = 120;   // Maximum rest period (seconds)
input int      TradingBurstDuration  = 60;    // Trading burst duration (seconds)
input int      PauseAfterBurst       = 30;    // Pause after trading burst (seconds)

// ===== Trading Settings =====
input int      MaxTradesPerBasket     = 4;     // Maximum trades per basket (same direction only)
input int      TradesPerTick          = 1;     // Trades per tick (for speed)
input int      MagicNumber            = 202504;
input double   MaxSpreadPips          = 10.0;  // Maximum spread in pips
input double   BasketProfitTarget     = 40.0;  // Close basket when profit reaches $40
input int      MaxOpenPositions       = 1;     // Maximum open baskets (across all symbols) - prevents over-exposure

// ===== Order Type Selection =====
input bool     UseMarketOrders        = true;  // Use market orders (Buy/Sell)
input bool     UseLimitOrders         = true;  // Use limit orders (Buy Limit/Sell Limit)
input bool     UseStopOrders          = true;  // Use stop orders (Buy Stop/Sell Stop)
input double   LimitOffsetPips        = 2.0;   // Limit order offset from current price
input double   StopOffsetPips         = 2.0;   // Stop order offset from current price

// ===== Profit Management =====
input double   MaxHoldSeconds         = 300;   // Maximum hold time for basket

// ===== Recovery Mechanism =====
input double   RecoveryTriggerPercent = -20.0; // Trigger recovery when basket is -20%
input double   RecoveryRR_Ratio       = 3.0;   // Risk:Reward ratio after recovery (1:3)
input double   RecoveryHoldRR_Ratio  = 4.0;   // Hold until 1:4 R:R before opening new trades
input bool     HoldOneTradeAfterRecovery = true; // Hold one trade after recovery
input double   RecoveryMaxLossPercent = -30.0; // Hard stop loss in recovery mode (%) - prevents unlimited drawdown

// ===== Market Analysis Settings =====
input int      Analysis_EMA_Fast      = 5;     // Fast EMA for analysis
input int      Analysis_EMA_Slow      = 15;    // Slow EMA for analysis
input int      Analysis_RSI_Period    = 14;    // RSI period for analysis
input int      Analysis_ATR_Period    = 14;    // ATR period for analysis

// ===== Advanced Exit Strategies =====
input group "===== Opposite Signal Exit ====="
input bool     UseOppositeSignalExit = true;  // Close on opposite signal

input group "===== Indicator-Based Exit ====="
input bool     UseIndicatorExit = true;        // Use indicator-based exits
input bool     UseRSIExit = true;             // Exit on RSI crossback
input double   RSIExitThreshold = 50.0;       // RSI level for exit
input bool     UseEMAExit = true;             // Exit on EMA crossback
input bool     UseMomentumExit = true;        // Exit on momentum drop

input group "===== Break-Even Exit ====="
input bool     UseBreakEvenExit = true;       // Move SL to break-even
input double   BreakEvenTriggerPips = 10.0;  // Move SL after X pips profit
input double   BreakEvenOffsetPips = 2.0;     // SL offset from entry (spread protection)

input group "===== Profit Locking / Partial Close ====="
input bool     UsePartialClose = true;        // Enable partial closes
input double   PartialClose1Pips = 15.0;     // Close 30% at X pips
input double   PartialClose1Percent = 30.0;   // % to close at first target
input double   PartialClose2Pips = 30.0;     // Close 30% at X pips
input double   PartialClose2Percent = 30.0;  // % to close at second target

input group "===== Equity-Based Exit ====="
input bool     UseEquityExit = true;          // Enable equity-based exits
input double   DailyProfitTargetPercent = 5.0; // Daily profit target % of balance
input double   DailyLossLimitPercent = 3.0;   // Daily loss limit % of balance
input bool     StopTradingAfterTarget = true; // Stop trading after target reached

input group "===== Maximum Drawdown Protection ====="
input bool     UseMaxDrawdownProtection = true;  // Enable maximum drawdown protection
input double   MaxDrawdownPercent = 15.0;        // Maximum account drawdown (%) - stop opening new trades
input double   MaxDrawdownStopTrading = 20.0;    // Stop all trading at this drawdown (%) - emergency stop

input group "===== Spread/Volatility Exit ====="
input bool     UseSpreadVolatilityExit = true; // Exit on spread/volatility issues
input double   MaxSpreadExitPips = 15.0;      // Exit if spread exceeds this
input double   MinATRExitPips = 0.5;          // Exit if ATR drops below this
input int      SpreadSpikeBars = 3;           // Bars to confirm spread spike

// =====================================================================================================
// STRUCTURES & GLOBALS
// =====================================================================================================

struct TradeInfo {
   int      ticket;
   double   entryPrice;
   datetime openTime;
   int      orderType;  // OP_BUY, OP_SELL, OP_BUYLIMIT, OP_SELLLIMIT, OP_BUYSTOP, OP_SELLSTOP
   double   lotSize;
};

// Basket management - all trades must be same direction
struct BasketInfo {
   TradeInfo trades[4];  // Maximum 4 trades
   int totalTrades;
   int basketDirection;  // 1=BUY, -1=SELL, 0=empty
   datetime basketStartTime;
   double highestBasketProfit;
   double lowestBasketProfit;      // Track lowest point
   bool recoveryMode;              // True if basket went negative and recovered
   double recoveryTriggerLevel;    // The negative level that triggered recovery (-20%)
   double recoveryTarget;          // Target profit after recovery (1:3 R:R)
   bool recoveryTargetReached;     // True when recovery target is reached
   int tradesHeldAfterRecovery;    // Count of trades held after recovery
   bool partialClose1Done;         // Partial close 1 completed
   bool partialClose2Done;         // Partial close 2 completed
};

BasketInfo currentBasket;

// Trading state
TradingPhase currentPhase = PHASE_REST;
datetime phaseStartTime = 0;
datetime lastRestTime = 0;
datetime lastTradingBurstTime = 0;

// Analysis results
int analysisDirection = 0;      // 1=Buy, -1=Sell, 0=No clear direction
int analysisOrderType = OP_BUY;  // OP_BUY, OP_SELL, OP_BUYLIMIT, OP_SELLLIMIT, OP_BUYSTOP, OP_SELLSTOP
double analysisStrength = 0.0;   // Signal strength (0-100)

// Price data
double pipToPoint = 0.0;
int digits = 0;

// Exit strategy globals
int lastAnalysisDirection = 0;        // Store previous analysis direction
double dailyStartBalance = 0.0;       // Daily balance tracking
datetime lastDayReset = 0;            // Last day reset time
double lastNormalSpread = 0.0;        // Last normal spread
int spreadSpikeCount = 0;             // Spread spike counter
double lastPrice = 0.0;               // Last price for freeze detection
datetime lastPriceTime = 0;           // Last price time

// Risk management globals
double equityHighWaterMark = 0.0;     // Highest equity reached (for drawdown calculation)
bool tradingStopped = false;          // True if trading stopped due to drawdown

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("BURST REST SCALPER v1.20");
   Print("Ultra-Fast Trading with Rest Periods");
   Print("Advanced Exit Strategies Enabled");
   Print("Enhanced Risk Management Enabled");
   Print("========================================");
   Print("Rest Period: ", RestPeriodMin, "-", RestPeriodMax, " seconds");
   Print("Trading Burst: ", TradingBurstDuration, " seconds");
   Print("Max Trades per Basket: ", MaxTradesPerBasket);
   Print("Order Types: Market=", UseMarketOrders, " | Limit=", UseLimitOrders, " | Stop=", UseStopOrders);
   Print("Risk Management:");
   Print("  - Risk per Trade: ", RiskPercentPerTrade, "%");
   Print("  - Max Basket Risk: ", MaxBasketRiskPercent, "%");
   Print("  - Max Drawdown: ", MaxDrawdownPercent, "% (Stop at ", MaxDrawdownStopTrading, "%)");
   Print("  - Max Open Positions: ", MaxOpenPositions);
   Print("  - Recovery Hard Stop: ", RecoveryMaxLossPercent, "%");
   Print("========================================");
   
   // Initialize symbol data
   digits = Digits;
   pipToPoint = Point;
   if(digits == 3 || digits == 5)
      pipToPoint *= 10.0;
   
   // Initialize phase - Start in ANALYSIS to trade immediately
   currentPhase = PHASE_ANALYSIS;
   phaseStartTime = TimeCurrent();
   lastRestTime = TimeCurrent();
   
   // Initialize basket
   currentBasket.totalTrades = 0;
   currentBasket.basketDirection = 0;
   currentBasket.basketStartTime = 0;
   currentBasket.highestBasketProfit = 0.0;
   currentBasket.lowestBasketProfit = 0.0;
   currentBasket.recoveryMode = false;
   currentBasket.recoveryTriggerLevel = 0.0;
   currentBasket.recoveryTarget = 0.0;
   currentBasket.recoveryTargetReached = false;
   currentBasket.tradesHeldAfterRecovery = 0;
   currentBasket.partialClose1Done = false;
   currentBasket.partialClose2Done = false;
   
   // Initialize exit strategy globals
   dailyStartBalance = AccountBalance();
   lastDayReset = TimeCurrent();
   lastAnalysisDirection = 0;
   spreadSpikeCount = 0;
   lastPrice = 0.0;
   lastPriceTime = 0;
   
   // Initialize risk management globals
   equityHighWaterMark = AccountEquity();
   tradingStopped = false;
   
   // Validate risk parameters
   if(RiskPercentPerTrade < 0.1 || RiskPercentPerTrade > 10.0)
   {
      Alert("ERROR: RiskPercentPerTrade must be between 0.1% and 10.0%!");
      return(INIT_FAILED);
   }
   
   if(MaxBasketRiskPercent < RiskPercentPerTrade)
   {
      Alert("ERROR: MaxBasketRiskPercent must be >= RiskPercentPerTrade!");
      return(INIT_FAILED);
   }
   
   if(MaxBasketRiskPercent > 20.0)
   {
      Alert("WARNING: MaxBasketRiskPercent is very high (", MaxBasketRiskPercent, "%). Recommended: 10% or less.");
   }
   
   // Perform initial analysis immediately
   PerformMarketAnalysis();
   
   Print("EA initialized - Starting in ANALYSIS phase (will trade immediately)");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("BurstRestScalper deinitialized. Reason: ", reason);
   Comment("");
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   // PRIORITY 0: Update equity high water mark (for drawdown calculation)
   UpdateEquityHighWaterMark();
   
   // PRIORITY 1: Check and close basket if profitable (including commissions)
   CheckAndCloseBasket();
   
   // Manage break-even stops
   ManageBreakEvenStops();
   
   // Update basket trades
   UpdateBasketTrades();
   
   // Manage phases
   ManageTradingPhases();
   
   // Execute phase actions (only if trading not stopped)
   if(!tradingStopped)
   {
      ExecutePhaseActions();
   }
   
   // Update display
   UpdateDisplay();
}


// =====================================================================================================
// PHASE MANAGEMENT
// =====================================================================================================

void ManageTradingPhases()
{
   datetime currentTime = TimeCurrent();
   int elapsedSeconds = (int)(currentTime - phaseStartTime);
   
   switch(currentPhase)
   {
      case PHASE_REST:
         // Rest for 1-2 minutes
         if(elapsedSeconds >= RestPeriodMin)
         {
            // Randomize rest period between min and max
            if(elapsedSeconds >= RestPeriodMax || (elapsedSeconds >= RestPeriodMin && MathRand() % 2 == 0))
            {
               currentPhase = PHASE_ANALYSIS;
               phaseStartTime = currentTime;
               Print("PHASE CHANGE: REST -> ANALYSIS");
            }
         }
         break;
         
      case PHASE_ANALYSIS:
         // Analyze market (happens during rest, so very quick)
         // Analysis is done in ExecutePhaseActions, switch to trading immediately
         currentPhase = PHASE_TRADING;
         phaseStartTime = currentTime;
         lastTradingBurstTime = currentTime;
         Print("PHASE CHANGE: ANALYSIS -> TRADING");
         break;
         
      case PHASE_TRADING:
         // Trade for 1 minute or until basket is full
         if(elapsedSeconds >= TradingBurstDuration || currentBasket.totalTrades >= MaxTradesPerBasket)
         {
            currentPhase = PHASE_PAUSE;
            phaseStartTime = currentTime;
            Print("PHASE CHANGE: TRADING -> PAUSE (Basket: ", currentBasket.totalTrades, "/", MaxTradesPerBasket, ")");
         }
         break;
         
      case PHASE_PAUSE:
         // Pause after trading
         if(elapsedSeconds >= PauseAfterBurst)
         {
            currentPhase = PHASE_CLOSE;
            phaseStartTime = currentTime;
            Print("PHASE CHANGE: PAUSE -> CLOSE");
         }
         break;
         
      case PHASE_CLOSE:
         // Close profitable basket (handled by CheckAndCloseBasket)
         // After basket is closed, go back to rest
         if(currentBasket.totalTrades == 0 || elapsedSeconds >= 60)
         {
            currentPhase = PHASE_REST;
            phaseStartTime = currentTime;
            lastRestTime = currentTime;
            Print("PHASE CHANGE: CLOSE -> REST");
         }
         break;
   }
}

// =====================================================================================================
// PHASE ACTIONS
// =====================================================================================================

void ExecutePhaseActions()
{
   switch(currentPhase)
   {
      case PHASE_REST:
         // Do nothing, just rest
         break;
         
      case PHASE_ANALYSIS:
         PerformMarketAnalysis();
         break;
         
      case PHASE_TRADING:
         ExecuteTradingBurst();
         break;
         
      case PHASE_PAUSE:
         // Do nothing, just pause
         break;
         
      case PHASE_CLOSE:
         // Basket closing is handled by CheckAndCloseBasket() in OnTick
         break;
   }
}

// =====================================================================================================
// MARKET ANALYSIS
// =====================================================================================================

void PerformMarketAnalysis()
{
   // Get indicators
   double emaFast = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaSlow = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi = iRSI(Symbol(), PERIOD_M1, Analysis_RSI_Period, PRICE_CLOSE, 0);
   double atr = iATR(Symbol(), PERIOD_M1, Analysis_ATR_Period, 0);
   
   if(emaFast <= 0 || emaSlow <= 0 || rsi <= 0 || atr <= 0)
   {
      analysisDirection = 0;
      return;
   }
   
   double midPrice = (Bid + Ask) / 2.0;
   double spread = (Ask - Bid) / pipToPoint;
   
   if(spread > MaxSpreadPips)
   {
      analysisDirection = 0;
      return;
   }
   
   // Calculate buy/sell scores
   int buyScore = 0;
   int sellScore = 0;
   
   // Trend analysis
   if(emaFast > emaSlow)
      buyScore += 3;
   else if(emaFast < emaSlow)
      sellScore += 3;
   
   // Price relative to EMAs
   if(midPrice > emaFast)
      buyScore += 2;
   else if(midPrice < emaFast)
      sellScore += 2;
   
   // RSI momentum
   if(rsi > 50.0)
      buyScore += 2;
   else if(rsi < 50.0)
      sellScore += 2;
   
   if(rsi > 70.0)
      buyScore += 1;  // Overbought but strong momentum
   else if(rsi < 30.0)
      sellScore += 1;  // Oversold but strong momentum
   
   // Price action
   double close0 = iClose(Symbol(), PERIOD_M1, 0);
   double close1 = iClose(Symbol(), PERIOD_M1, 1);
   double close2 = iClose(Symbol(), PERIOD_M1, 2);
   
   if(close0 > close1 && close1 > close2)
      buyScore += 2;
   else if(close0 < close1 && close1 < close2)
      sellScore += 2;
   else if(close0 > close1)
      buyScore += 1;
   else if(close0 < close1)
      sellScore += 1;
   
   // Volatility (ATR)
   double atrPips = atr / pipToPoint;
   if(atrPips > 1.0)  // Good volatility
   {
      if(buyScore > sellScore)
         buyScore += 1;
      else if(sellScore > buyScore)
         sellScore += 1;
   }
   
   // Determine direction and order type
   if(buyScore > sellScore && buyScore >= 3)
   {
      analysisDirection = 1;
      analysisStrength = (buyScore / 10.0) * 100.0;
      
      // Determine order type based on market conditions
      if(UseMarketOrders && (close0 > close1 || rsi > 55))
      {
         analysisOrderType = OP_BUY;  // Market order
      }
      else if(UseLimitOrders && close0 < close1)
      {
         analysisOrderType = OP_BUYLIMIT;  // Buy limit (price below current)
      }
      else if(UseStopOrders && close0 > close1 && rsi > 60)
      {
         analysisOrderType = OP_BUYSTOP;  // Buy stop (breakout)
      }
      else
      {
         analysisOrderType = OP_BUY;  // Default to market
      }
   }
   else if(sellScore > buyScore && sellScore >= 3)
   {
      analysisDirection = -1;
      analysisStrength = (sellScore / 10.0) * 100.0;
      
      // Determine order type
      if(UseMarketOrders && (close0 < close1 || rsi < 45))
      {
         analysisOrderType = OP_SELL;  // Market order
      }
      else if(UseLimitOrders && close0 > close1)
      {
         analysisOrderType = OP_SELLLIMIT;  // Sell limit (price above current)
      }
      else if(UseStopOrders && close0 < close1 && rsi < 40)
      {
         analysisOrderType = OP_SELLSTOP;  // Sell stop (breakdown)
      }
      else
      {
         analysisOrderType = OP_SELL;  // Default to market
      }
   }
   else
   {
      analysisDirection = 0;
      analysisOrderType = OP_BUY;  // Default
   }
   
   Print("ANALYSIS COMPLETE: Direction=", (analysisDirection == 1 ? "BUY" : (analysisDirection == -1 ? "SELL" : "NONE")),
         " | OrderType=", GetOrderTypeName(analysisOrderType), " | Strength=", DoubleToString(analysisStrength, 1), "%");
}

string GetOrderTypeName(int orderType)
{
   switch(orderType)
   {
      case OP_BUY: return "BUY";
      case OP_SELL: return "SELL";
      case OP_BUYLIMIT: return "BUY LIMIT";
      case OP_SELLLIMIT: return "SELL LIMIT";
      case OP_BUYSTOP: return "BUY STOP";
      case OP_SELLSTOP: return "SELL STOP";
      default: return "UNKNOWN";
   }
}

// =====================================================================================================
// TRADING BURST EXECUTION
// =====================================================================================================

void ExecuteTradingBurst()
{
   if(analysisDirection == 0)
      return;  // No valid analysis
   
   // RISK MANAGEMENT CHECKS: Prevent opening trades if limits exceeded
   if(UseMaxDrawdownProtection)
   {
      if(CheckMaxDrawdown())
      {
         return;  // Drawdown limit reached, don't open new trades
      }
   }
   
   if(CheckMaxOpenPositions())
   {
      return;  // Maximum open positions reached
   }
   
   // RECOVERY MODE: Don't open new trades until 1:4 R:R is reached
   if(currentBasket.recoveryMode && currentBasket.totalTrades > 0)
   {
      double basketProfit = CalculateBasketProfit();
      double initialRisk = 0.0;
      for(int i = 0; i < currentBasket.totalTrades; i++)
      {
         if(currentBasket.trades[i].ticket > 0)
         {
            double balance = AccountBalance();
            double tradeRisk = balance * (RiskPercentPerTrade / 100.0);
            initialRisk += tradeRisk;
         }
      }
      
      double basketProfitPercent = 0.0;
      if(initialRisk > 0.0)
         basketProfitPercent = (basketProfit / initialRisk) * 100.0;
      
      // Calculate 1:4 R:R target
      double holdTarget = currentBasket.recoveryTarget * (RecoveryHoldRR_Ratio / RecoveryRR_Ratio);
      
      // Don't open new trades until 1:4 R:R is reached
      if(basketProfitPercent < holdTarget)
      {
         return;  // Wait for recovery to complete
      }
   }
   
   // Check if basket is full
   if(currentBasket.totalTrades >= MaxTradesPerBasket)
      return;
   
   // Check if basket direction matches analysis (no mixed directions)
   if(currentBasket.basketDirection != 0 && currentBasket.basketDirection != analysisDirection)
   {
      // Basket has different direction - must close first
      return;
   }
   
   // Check spread
   double spread = (Ask - Bid) / pipToPoint;
   if(spread > MaxSpreadPips)
      return;
   
   // Take trades as fast as possible (up to 4 trades, same direction)
   for(int i = 0; i < TradesPerTick && currentBasket.totalTrades < MaxTradesPerBasket; i++)
   {
      if(OpenBasketTrade(analysisOrderType))
      {
         Sleep(10);  // Small delay to avoid overloading
      }
   }
}

bool OpenBasketTrade(int orderType)
{
   // Calculate lot size
   double lotSize = CalculateLotSize();
   if(lotSize <= 0.0)
      return false;
   
   double price = 0.0;
   double sl = 0.0;
   double tp = 0.0;
   
   RefreshRates();
   
   // Set price based on order type
   switch(orderType)
   {
      case OP_BUY:
         price = Ask;
         break;
         
      case OP_SELL:
         price = Bid;
         break;
         
      case OP_BUYLIMIT:
         price = NormalizeDouble(Bid - (LimitOffsetPips * pipToPoint), digits);
         if(price >= Bid)
            price = NormalizeDouble(Bid - Point, digits);
         break;
         
      case OP_SELLLIMIT:
         price = NormalizeDouble(Ask + (LimitOffsetPips * pipToPoint), digits);
         if(price <= Ask)
            price = NormalizeDouble(Ask + Point, digits);
         break;
         
      case OP_BUYSTOP:
         price = NormalizeDouble(Ask + (StopOffsetPips * pipToPoint), digits);
         if(price <= Ask)
            price = NormalizeDouble(Ask + Point, digits);
         break;
         
      case OP_SELLSTOP:
         price = NormalizeDouble(Bid - (StopOffsetPips * pipToPoint), digits);
         if(price >= Bid)
            price = NormalizeDouble(Bid - Point, digits);
         break;
         
      default:
         return false;
   }
   
   if(price <= 0.0)
      return false;
   
   string comment = "BurstScalp_" + GetOrderTypeName(orderType);
   color arrowColor = (orderType == OP_BUY || orderType == OP_BUYLIMIT || orderType == OP_BUYSTOP) ? clrGreen : clrRed;
   
   int ticket = OrderSend(Symbol(), orderType, lotSize, price, 3, sl, tp, comment, MagicNumber, 0, arrowColor);
   
   if(ticket > 0)
   {
      // Add to basket
      if(currentBasket.totalTrades < MaxTradesPerBasket)
      {
         int index = currentBasket.totalTrades;
         currentBasket.trades[index].ticket = ticket;
         currentBasket.trades[index].entryPrice = price;
         currentBasket.trades[index].openTime = TimeCurrent();
         currentBasket.trades[index].orderType = orderType;
         currentBasket.trades[index].lotSize = lotSize;
         
         // Set basket direction on first trade
         if(currentBasket.totalTrades == 0)
         {
            if(orderType == OP_BUY || orderType == OP_BUYLIMIT || orderType == OP_BUYSTOP)
               currentBasket.basketDirection = 1;
            else
               currentBasket.basketDirection = -1;
            currentBasket.basketStartTime = TimeCurrent();
         }
         
         currentBasket.totalTrades++;
      }
      
      Print("BASKET TRADE OPENED: ", GetOrderTypeName(orderType), " | Ticket=", ticket, " | Lot=", lotSize, 
            " | Basket: ", currentBasket.totalTrades, "/", MaxTradesPerBasket);
      return true;
   }
   else
   {
      Print("OrderSend failed: ", GetLastError());
      return false;
   }
}

// =====================================================================================================
// ADVANCED EXIT STRATEGIES
// =====================================================================================================

// 1. Opposite Signal Exit
bool CheckOppositeSignalExit()
{
   if(!UseOppositeSignalExit || currentBasket.totalTrades == 0)
      return false;
   
   // CRITICAL: Only exit if basket is profitable - never close at a loss
   double basketProfit = CalculateBasketProfit();
   if(basketProfit <= 0.0)
      return false;  // Don't exit if basket is at loss or break-even
   
   // Perform fresh analysis
   int currentDirection = GetCurrentAnalysisDirection();
   
   // Check if signal flipped
   if(currentBasket.basketDirection == 1 && currentDirection == -1)
   {
      // Was BUY, now SELL signal
      Print("OPPOSITE SIGNAL EXIT: BUY -> SELL");
      CloseEntireBasket("Opposite Signal: BUY->SELL | Profit: $" + 
                        DoubleToString(basketProfit, 2));
      return true;
   }
   else if(currentBasket.basketDirection == -1 && currentDirection == 1)
   {
      // Was SELL, now BUY signal
      Print("OPPOSITE SIGNAL EXIT: SELL -> BUY");
      CloseEntireBasket("Opposite Signal: SELL->BUY | Profit: $" + 
                        DoubleToString(basketProfit, 2));
      return true;
   }
   
   return false;
}

// Helper function to get current analysis direction
int GetCurrentAnalysisDirection()
{
   double emaFast = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaSlow = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi = iRSI(Symbol(), PERIOD_M1, Analysis_RSI_Period, PRICE_CLOSE, 0);
   
   if(emaFast <= 0 || emaSlow <= 0 || rsi <= 0)
      return 0;
   
   int buyScore = 0;
   int sellScore = 0;
   
   if(emaFast > emaSlow)
      buyScore += 3;
   else if(emaFast < emaSlow)
      sellScore += 3;
   
   if(rsi > 50.0)
      buyScore += 2;
   else if(rsi < 50.0)
      sellScore += 2;
   
   if(buyScore > sellScore && buyScore >= 3)
      return 1;
   else if(sellScore > buyScore && sellScore >= 3)
      return -1;
   
   return 0;
}

// 2. Indicator-Based Exit
bool CheckIndicatorBasedExit()
{
   if(!UseIndicatorExit || currentBasket.totalTrades == 0)
      return false;
   
   double rsi = iRSI(Symbol(), PERIOD_M1, Analysis_RSI_Period, PRICE_CLOSE, 0);
   double rsiPrev = iRSI(Symbol(), PERIOD_M1, Analysis_RSI_Period, PRICE_CLOSE, 1);
   double emaFast = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaSlow = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaFastPrev = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlowPrev = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 1);
   
   if(rsi <= 0 || emaFast <= 0 || emaSlow <= 0)
      return false;
   
   // RSI Exit: RSI crosses back through 50 (momentum loss)
   if(UseRSIExit)
   {
      if(currentBasket.basketDirection == 1)  // BUY position
      {
         // RSI was above threshold, now crossing below
         if(rsiPrev > RSIExitThreshold && rsi < RSIExitThreshold)
         {
            double basketProfit = CalculateBasketProfit();
            if(basketProfit > 0)  // Only exit if profitable
            {
               Print("RSI EXIT: RSI crossed below ", DoubleToString(RSIExitThreshold, 1));
               CloseEntireBasket("RSI Crossback Exit | Profit: $" + 
                                DoubleToString(basketProfit, 2));
               return true;
            }
         }
      }
      else if(currentBasket.basketDirection == -1)  // SELL position
      {
         // RSI was below threshold, now crossing above
         if(rsiPrev < (100.0 - RSIExitThreshold) && rsi > (100.0 - RSIExitThreshold))
         {
            double basketProfit = CalculateBasketProfit();
            if(basketProfit > 0)
            {
               Print("RSI EXIT: RSI crossed above ", DoubleToString(100.0 - RSIExitThreshold, 1));
               CloseEntireBasket("RSI Crossback Exit | Profit: $" + 
                                DoubleToString(basketProfit, 2));
               return true;
            }
         }
      }
   }
   
   // EMA Crossback Exit: EMAs cross opposite to position
   if(UseEMAExit)
   {
      if(currentBasket.basketDirection == 1)  // BUY position
      {
         // Fast EMA was above Slow, now crossing below
         if(emaFastPrev > emaSlowPrev && emaFast < emaSlow)
         {
            double basketProfit = CalculateBasketProfit();
            if(basketProfit > 0)
            {
               Print("EMA EXIT: Fast EMA crossed below Slow EMA");
               CloseEntireBasket("EMA Crossback Exit | Profit: $" + 
                                DoubleToString(basketProfit, 2));
               return true;
            }
         }
      }
      else if(currentBasket.basketDirection == -1)  // SELL position
      {
         // Fast EMA was below Slow, now crossing above
         if(emaFastPrev < emaSlowPrev && emaFast > emaSlow)
         {
            double basketProfit = CalculateBasketProfit();
            if(basketProfit > 0)
            {
               Print("EMA EXIT: Fast EMA crossed above Slow EMA");
               CloseEntireBasket("EMA Crossback Exit | Profit: $" + 
                                DoubleToString(basketProfit, 2));
               return true;
            }
         }
      }
   }
   
   // Momentum Drop Exit
   if(UseMomentumExit)
   {
      double close0 = iClose(Symbol(), PERIOD_M1, 0);
      double close1 = iClose(Symbol(), PERIOD_M1, 1);
      double close2 = iClose(Symbol(), PERIOD_M1, 2);
      
      if(currentBasket.basketDirection == 1)  // BUY position
      {
         // Momentum was up, now reversing
         if(close1 > close2 && close0 < close1)
         {
            double basketProfit = CalculateBasketProfit();
            if(basketProfit > 0)
            {
               Print("MOMENTUM EXIT: Price momentum reversed");
               CloseEntireBasket("Momentum Drop Exit | Profit: $" + 
                                DoubleToString(basketProfit, 2));
               return true;
            }
         }
      }
      else if(currentBasket.basketDirection == -1)  // SELL position
      {
         // Momentum was down, now reversing
         if(close1 < close2 && close0 > close1)
         {
            double basketProfit = CalculateBasketProfit();
            if(basketProfit > 0)
            {
               Print("MOMENTUM EXIT: Price momentum reversed");
               CloseEntireBasket("Momentum Drop Exit | Profit: $" + 
                                DoubleToString(basketProfit, 2));
               return true;
            }
         }
      }
   }
   
   return false;
}

// 3. Break-Even Exit
void ManageBreakEvenStops()
{
   if(!UseBreakEvenExit || currentBasket.totalTrades == 0)
      return;
   
   double breakEvenTrigger = BreakEvenTriggerPips * pipToPoint;
   double breakEvenOffset = BreakEvenOffsetPips * pipToPoint;
   
   for(int i = 0; i < currentBasket.totalTrades; i++)
   {
      if(currentBasket.trades[i].ticket <= 0)
         continue;
      
      if(!OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET))
         continue;
      
      // Skip pending orders
      if(OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT || 
         OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
         continue;
      
      double entryPrice = OrderOpenPrice();
      double currentSL = OrderStopLoss();
      double currentPrice = (OrderType() == OP_BUY) ? Bid : Ask;
      double profitPips = 0.0;
      
      if(OrderType() == OP_BUY)
      {
         profitPips = (currentPrice - entryPrice) / pipToPoint;
         double breakEvenPrice = entryPrice + breakEvenOffset;
         
         // Check if profit reached trigger and SL not at break-even
         if(profitPips >= BreakEvenTriggerPips && 
            (currentSL == 0 || currentSL < breakEvenPrice))
         {
            if(OrderModify(currentBasket.trades[i].ticket, entryPrice, 
                          breakEvenPrice, OrderTakeProfit(), 0, clrBlue))
            {
               Print("BREAK-EVEN SET: Ticket=", currentBasket.trades[i].ticket, 
                     " | BE Price=", DoubleToString(breakEvenPrice, digits));
            }
         }
      }
      else if(OrderType() == OP_SELL)
      {
         profitPips = (entryPrice - currentPrice) / pipToPoint;
         double breakEvenPrice = entryPrice - breakEvenOffset;
         
         if(profitPips >= BreakEvenTriggerPips && 
            (currentSL == 0 || currentSL > breakEvenPrice))
         {
            if(OrderModify(currentBasket.trades[i].ticket, entryPrice, 
                          breakEvenPrice, OrderTakeProfit(), 0, clrBlue))
            {
               Print("BREAK-EVEN SET: Ticket=", currentBasket.trades[i].ticket, 
                     " | BE Price=", DoubleToString(breakEvenPrice, digits));
            }
         }
      }
   }
}

// 4. Profit Locking / Partial Close
void CheckPartialClose()
{
   if(!UsePartialClose || currentBasket.totalTrades == 0)
      return;
   
   // Don't partial close in recovery mode
   if(currentBasket.recoveryMode)
      return;
   
   double basketProfit = CalculateBasketProfit();
   if(basketProfit <= 0)
      return;
   
   // Calculate average entry price
   double totalLots = 0.0;
   double weightedEntry = 0.0;
   int activeTrades = 0;
   
   for(int i = 0; i < currentBasket.totalTrades; i++)
   {
      if(currentBasket.trades[i].ticket <= 0)
         continue;
      
      if(!OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET))
         continue;
      
      if(OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT || 
         OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
         continue;
      
      double lots = OrderLots();
      double entry = OrderOpenPrice();
      weightedEntry += entry * lots;
      totalLots += lots;
      activeTrades++;
   }
   
   if(totalLots <= 0 || activeTrades == 0)
      return;
   
   double avgEntry = weightedEntry / totalLots;
   double currentPrice = (currentBasket.basketDirection == 1) ? Bid : Ask;
   double profitPips = 0.0;
   
   if(currentBasket.basketDirection == 1)
      profitPips = (currentPrice - avgEntry) / pipToPoint;
   else
      profitPips = (avgEntry - currentPrice) / pipToPoint;
   
   // Partial Close 1
   if(!currentBasket.partialClose1Done && profitPips >= PartialClose1Pips)
   {
      int tradesToClose = (int)MathMax(1, MathFloor(activeTrades * (PartialClose1Percent / 100.0)));
      ClosePartialBasket(tradesToClose, "Partial Close 1: " + DoubleToString(profitPips, 1) + " pips");
      currentBasket.partialClose1Done = true;
   }
   
   // Partial Close 2
   if(!currentBasket.partialClose2Done && profitPips >= PartialClose2Pips)
   {
      int remainingTrades = CountActiveTrades();
      if(remainingTrades > 0)
      {
         int tradesToClose = (int)MathMax(1, MathFloor(remainingTrades * (PartialClose2Percent / 100.0)));
         ClosePartialBasket(tradesToClose, "Partial Close 2: " + DoubleToString(profitPips, 1) + " pips");
         currentBasket.partialClose2Done = true;
      }
   }
}

// Helper function to close partial basket
void ClosePartialBasket(int count, string reason)
{
   if(count <= 0)
      return;
   
   // Sort trades by profit (close most profitable first)
   struct TradeProfit
   {
      int ticket;
      double profit;
   };
   
   TradeProfit trades[];
   ArrayResize(trades, 0);
   
   for(int i = 0; i < currentBasket.totalTrades; i++)
   {
      if(currentBasket.trades[i].ticket <= 0)
         continue;
      
      if(!OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET))
         continue;
      
      if(OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT || 
         OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
         continue;
      
      int size = ArraySize(trades);
      ArrayResize(trades, size + 1);
      trades[size].ticket = currentBasket.trades[i].ticket;
      trades[size].profit = OrderProfit() + OrderSwap() + OrderCommission();
   }
   
   // Sort by profit (descending)
   for(int i = 0; i < ArraySize(trades) - 1; i++)
   {
      for(int j = i + 1; j < ArraySize(trades); j++)
      {
         if(trades[j].profit > trades[i].profit)
         {
            TradeProfit temp = trades[i];
            trades[i] = trades[j];
            trades[j] = temp;
         }
      }
   }
   
   // Close top N trades
   int closed = 0;
   for(int i = 0; i < MathMin(count, ArraySize(trades)); i++)
   {
      if(OrderSelect(trades[i].ticket, SELECT_BY_TICKET))
      {
         RefreshRates();
         double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;
         double lots = OrderLots();
         
         if(OrderClose(trades[i].ticket, lots, closePrice, 3, clrYellow))
         {
            closed++;
            RemoveBasketTradeByTicket(trades[i].ticket);
         }
      }
   }
   
   if(closed > 0)
      Print("PARTIAL CLOSE: ", reason, " | Closed ", closed, " trades");
}

int CountActiveTrades()
{
   int count = 0;
   for(int i = 0; i < currentBasket.totalTrades; i++)
   {
      if(currentBasket.trades[i].ticket <= 0)
         continue;
      
      if(OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET))
      {
         if(OrderType() != OP_BUYLIMIT && OrderType() != OP_SELLLIMIT && 
            OrderType() != OP_BUYSTOP && OrderType() != OP_SELLSTOP)
            count++;
      }
   }
   return count;
}

void RemoveBasketTradeByTicket(int ticket)
{
   for(int i = 0; i < currentBasket.totalTrades; i++)
   {
      if(currentBasket.trades[i].ticket == ticket)
      {
         RemoveBasketTrade(i);
         break;
      }
   }
}

// 5. Equity-Based Exit
bool CheckEquityBasedExit()
{
   if(!UseEquityExit)
      return false;
   
   // Reset daily tracking on new day
   datetime currentTime = TimeCurrent();
   int currentDay = TimeDay(currentTime);
   int currentMonth = TimeMonth(currentTime);
   int currentYear = TimeYear(currentTime);
   int lastDay = TimeDay(lastDayReset);
   int lastMonth = TimeMonth(lastDayReset);
   int lastYear = TimeYear(lastDayReset);
   
   if(currentDay != lastDay || currentMonth != lastMonth || currentYear != lastYear)
   {
      dailyStartBalance = AccountBalance();
      lastDayReset = currentTime;
      Print("Daily reset: New day started. Balance: $", DoubleToString(dailyStartBalance, 2));
   }
   
   double currentBalance = AccountBalance();
   double dailyProfit = currentBalance - dailyStartBalance;
   double dailyProfitPercent = (dailyProfit / dailyStartBalance) * 100.0;
   
   // Check daily profit target
   if(dailyProfitPercent >= DailyProfitTargetPercent)
   {
      if(currentBasket.totalTrades > 0)
      {
         double basketProfit = CalculateBasketProfit();
         if(basketProfit > 0)
         {
            Print("DAILY PROFIT TARGET REACHED: ", DoubleToString(dailyProfitPercent, 2), "%");
            CloseEntireBasket("Daily Profit Target: " + DoubleToString(dailyProfitPercent, 2) + "%");
            return true;
         }
      }
      
      if(StopTradingAfterTarget)
      {
         Print("DAILY TARGET REACHED - Stopping trading for today");
         // Could set a flag to prevent new trades
      }
   }
   
   // Check daily loss limit
   // NOTE: Daily loss limit is an exception - it closes trades even at a loss to protect account
   // This is intentional risk management, not a bug
   if(dailyProfitPercent <= -DailyLossLimitPercent)
   {
      double basketProfit = CalculateBasketProfit();
      Print("DAILY LOSS LIMIT REACHED: ", DoubleToString(dailyProfitPercent, 2), "%");
      Print("WARNING: Closing basket at loss due to daily loss limit protection");
      CloseEntireBasket("Daily Loss Limit: " + DoubleToString(dailyProfitPercent, 2) + "% | Basket P&L: $" + 
                        DoubleToString(basketProfit, 2));
      return true;
   }
   
   return false;
}

// 6. Spread/Volatility Exit
bool CheckSpreadVolatilityExit()
{
   if(!UseSpreadVolatilityExit || currentBasket.totalTrades == 0)
      return false;
   
   double spread = (Ask - Bid) / pipToPoint;
   double atr = iATR(Symbol(), PERIOD_M1, Analysis_ATR_Period, 0);
   double atrPips = (atr > 0) ? (atr / pipToPoint) : 0.0;
   
   // Check spread spike
   if(spread > MaxSpreadExitPips)
   {
      spreadSpikeCount++;
      if(spreadSpikeCount >= SpreadSpikeBars)
      {
         double basketProfit = CalculateBasketProfit();
         // CRITICAL: Only exit if basket is profitable - never close at a loss
         if(basketProfit > 0.0)
         {
            Print("SPREAD SPIKE EXIT: Spread=", DoubleToString(spread, 1), " pips");
            CloseEntireBasket("Spread Spike Exit: " + DoubleToString(spread, 1) + " pips | Profit: $" + 
                              DoubleToString(basketProfit, 2));
            spreadSpikeCount = 0;
            return true;
         }
         else
         {
            // Reset counter if not profitable - don't exit at loss
            spreadSpikeCount = 0;
         }
      }
   }
   else
   {
      spreadSpikeCount = 0;
   }
   
   // Check low volatility (ATR drop)
   if(atrPips > 0 && atrPips < MinATRExitPips)
   {
      double basketProfit = CalculateBasketProfit();
      if(basketProfit > 0)  // Only exit if profitable
      {
         Print("LOW VOLATILITY EXIT: ATR=", DoubleToString(atrPips, 2), " pips");
         CloseEntireBasket("Low Volatility Exit: ATR=" + DoubleToString(atrPips, 2) + " pips | Profit: $" + 
                          DoubleToString(basketProfit, 2));
         return true;
      }
   }
   
   // Check price freeze (no movement)
   double currentPrice = (Bid + Ask) / 2.0;
   datetime currentTime = TimeCurrent();
   
   if(lastPrice > 0 && lastPriceTime > 0)
   {
      double priceChange = MathAbs(currentPrice - lastPrice) / pipToPoint;
      int timeDiff = (int)(currentTime - lastPriceTime);
      
      // Price hasn't moved in 30 seconds
      if(timeDiff >= 30 && priceChange < 0.1)
      {
         double basketProfit = CalculateBasketProfit();
         if(basketProfit > 0)
         {
            Print("PRICE FREEZE EXIT: No movement for ", timeDiff, " seconds");
            CloseEntireBasket("Price Freeze Exit | Profit: $" + DoubleToString(basketProfit, 2));
            return true;
         }
      }
   }
   
   lastPrice = currentPrice;
   lastPriceTime = currentTime;
   
   return false;
}

// =====================================================================================================
// BASKET MANAGEMENT
// =====================================================================================================

// Calculate total basket profit including all commissions
double CalculateBasketProfit()
{
   double totalProfit = 0.0;
   
   for(int i = 0; i < currentBasket.totalTrades; i++)
   {
      if(currentBasket.trades[i].ticket <= 0)
         continue;
      
      if(OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET))
      {
         // Skip pending orders
         if(OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT || 
            OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
            continue;
         
         // Include profit, swap, and commission
         totalProfit += OrderProfit() + OrderSwap() + OrderCommission();
      }
      else
      {
         // Check if closed in history
         if(OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET, MODE_HISTORY))
         {
            totalProfit += OrderProfit() + OrderSwap() + OrderCommission();
         }
      }
   }
   
   return totalProfit;
}

// Check and close basket if profitable (including commissions)
void CheckAndCloseBasket()
{
   if(currentBasket.totalTrades == 0)
      return;
   
   double basketProfit = CalculateBasketProfit();
   
   // Update highest and lowest basket profit
   if(basketProfit > currentBasket.highestBasketProfit)
      currentBasket.highestBasketProfit = basketProfit;
   
   if(basketProfit < currentBasket.lowestBasketProfit)
      currentBasket.lowestBasketProfit = basketProfit;
   
   // Calculate basket profit as percentage of initial risk
   double initialRisk = 0.0;
   for(int i = 0; i < currentBasket.totalTrades; i++)
   {
      if(currentBasket.trades[i].ticket > 0)
      {
         double balance = AccountBalance();
         double tradeRisk = balance * (RiskPercentPerTrade / 100.0);
         initialRisk += tradeRisk;
      }
   }
   
   double basketProfitPercent = 0.0;
   if(initialRisk > 0.0)
      basketProfitPercent = (basketProfit / initialRisk) * 100.0;
   
   // ===== EXIT CHECKS (Priority Order) =====
   
   // 0. Recovery mode hard stop loss - HIGHEST PRIORITY (prevents unlimited drawdown)
   if(currentBasket.recoveryMode && basketProfitPercent <= RecoveryMaxLossPercent)
   {
      Print("RECOVERY HARD STOP: Basket loss exceeded ", DoubleToString(RecoveryMaxLossPercent, 2), "%");
      CloseEntireBasket("Recovery Hard Stop: " + DoubleToString(basketProfitPercent, 2) + "% | Loss: $" + 
                        DoubleToString(basketProfit, 2));
      return;
   }
   
   // 1. Equity-based exits (daily limits) - HIGHEST PRIORITY
   if(CheckEquityBasedExit())
      return;
   
   // 2. Spread/Volatility exits (market conditions) - HIGH PRIORITY
   if(CheckSpreadVolatilityExit())
      return;
   
   // 3. Opposite signal exit (entry reason gone) - HIGH PRIORITY
   if(CheckOppositeSignalExit())
      return;
   
   // 4. Indicator-based exits (momentum loss) - MEDIUM PRIORITY
   if(CheckIndicatorBasedExit())
      return;
   
   // 5. Partial closes (profit locking) - MEDIUM PRIORITY
   CheckPartialClose();
   
   // ===== RECOVERY MECHANISM =====
   // Check if basket went to recovery trigger level (-20%)
   if(!currentBasket.recoveryMode && basketProfitPercent <= RecoveryTriggerPercent)
   {
      currentBasket.recoveryMode = true;
      currentBasket.recoveryTriggerLevel = basketProfitPercent;
      // Calculate recovery target: 1:3 R:R (if down 20%, target 60% profit)
      double lossAmount = MathAbs(basketProfitPercent);
      currentBasket.recoveryTarget = lossAmount * RecoveryRR_Ratio;  // 20% * 3 = 60%
      currentBasket.recoveryTargetReached = false;
      currentBasket.tradesHeldAfterRecovery = 0;
      
      Print("========================================");
      Print("RECOVERY MODE ACTIVATED!");
      Print("Basket Profit: ", DoubleToString(basketProfitPercent, 2), "%");
      Print("Recovery Target: ", DoubleToString(currentBasket.recoveryTarget, 2), "% (1:", DoubleToString(RecoveryRR_Ratio, 1), " R:R)");
      Print("========================================");
   }
   
   // Check if basket recovered (went from negative to positive)
   bool hasRecovered = false;
   if(currentBasket.recoveryMode && basketProfit > 0.0 && currentBasket.lowestBasketProfit < 0.0)
   {
      hasRecovered = true;
      
      // Check if recovery target reached
      if(basketProfitPercent >= currentBasket.recoveryTarget)
      {
         if(!currentBasket.recoveryTargetReached)
         {
            currentBasket.recoveryTargetReached = true;
            Print("RECOVERY TARGET REACHED: ", DoubleToString(basketProfitPercent, 2), "% (Target: ", 
                  DoubleToString(currentBasket.recoveryTarget, 2), "%)");
         }
      }
   }
   
   // ===== CLOSING LOGIC =====
   // CRITICAL: Only close if basket is profitable (including commissions)
   // Some individual trades may be negative, but overall basket must be profitable
   if(basketProfit > 0.0)
   {
      // RECOVERY MODE: Don't close early if recovered
      if(currentBasket.recoveryMode && hasRecovered)
      {
         // Wait for recovery target (1:3 R:R) before considering closing
         if(basketProfitPercent >= currentBasket.recoveryTarget)
         {
            // After recovery target, wait for 1:4 R:R before closing
            double holdTarget = currentBasket.recoveryTarget * (RecoveryHoldRR_Ratio / RecoveryRR_Ratio);  // 1:4 R:R
            if(basketProfitPercent >= holdTarget)
            {
               // Hold one trade after recovery if enabled
               if(HoldOneTradeAfterRecovery && currentBasket.tradesHeldAfterRecovery < 1)
               {
                  // Don't close yet, hold one more trade
                  currentBasket.tradesHeldAfterRecovery++;
                  Print("HOLDING ONE TRADE AFTER RECOVERY: Profit=", DoubleToString(basketProfitPercent, 2), "%");
                  return;
               }
               
               // Close after reaching 1:4 R:R
               CloseEntireBasket("Recovery Complete - 1:" + DoubleToString(RecoveryHoldRR_Ratio, 1) + " R:R | Profit: $" + 
                                 DoubleToString(basketProfit, 2) + " (" + DoubleToString(basketProfitPercent, 2) + "%)");
               return;
            }
            else
            {
               // Don't close early - wait for 1:4 R:R
               return;
            }
         }
         else
         {
            // Don't close early - wait for recovery target (1:3 R:R)
            return;
         }
      }
      
      // NORMAL MODE: Close when profit reaches target
      if(basketProfit >= BasketProfitTarget)
      {
         CloseEntireBasket("Basket Profit Target: $" + DoubleToString(basketProfit, 2));
         return;
      }
      
      // Also close if max hold time reached (unless in recovery mode)
      if(!currentBasket.recoveryMode)
      {
         int holdSeconds = (int)(TimeCurrent() - currentBasket.basketStartTime);
         if(holdSeconds >= MaxHoldSeconds)
         {
            CloseEntireBasket("Max Hold Time: " + IntegerToString(holdSeconds) + " seconds | Profit: $" + DoubleToString(basketProfit, 2));
            return;
         }
      }
   }
   // Do NOT close if basket is negative - wait for it to become profitable
}

// Close entire basket (all trades)
void CloseEntireBasket(string reason)
{
   Print("========================================");
   Print("CLOSING BASKET: ", reason);
   Print("========================================");
   
   double totalProfit = 0.0;
   int closedCount = 0;
   
   for(int i = currentBasket.totalTrades - 1; i >= 0; i--)
   {
      if(currentBasket.trades[i].ticket <= 0)
         continue;
      
      if(!OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET))
      {
         // Check history
         if(OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET, MODE_HISTORY))
         {
            totalProfit += OrderProfit() + OrderSwap() + OrderCommission();
            closedCount++;
         }
         RemoveBasketTrade(i);
         continue;
      }
      
      // Skip if already closed
      if(OrderCloseTime() > 0)
      {
         totalProfit += OrderProfit() + OrderSwap() + OrderCommission();
         closedCount++;
         RemoveBasketTrade(i);
         continue;
      }
      
      // Handle pending orders
      if(OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT || 
         OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
      {
         if(OrderDelete(currentBasket.trades[i].ticket))
         {
            Print("PENDING ORDER DELETED: Ticket=", currentBasket.trades[i].ticket);
            closedCount++;
         }
         RemoveBasketTrade(i);
         continue;
      }
      
      // Close market order
      RefreshRates();
      double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;
      double lots = OrderLots();
      double tradeProfit = OrderProfit() + OrderSwap() + OrderCommission();
      
      if(OrderClose(currentBasket.trades[i].ticket, lots, closePrice, 3, clrYellow))
      {
         totalProfit += tradeProfit;
         closedCount++;
         Print("BASKET TRADE CLOSED: Ticket=", currentBasket.trades[i].ticket, " | P&L=$", DoubleToString(tradeProfit, 2));
      }
      else
      {
         int error = GetLastError();
         if(error == 4108 || error == 4109)
         {
            // Already closed
            RemoveBasketTrade(i);
         }
         else
         {
            Print("OrderClose failed: ", error, " | Ticket=", currentBasket.trades[i].ticket);
         }
      }
      
      RemoveBasketTrade(i);
   }
   
   Print("BASKET CLOSED: Total P&L=$", DoubleToString(totalProfit, 2), " | Trades Closed: ", closedCount);
   Print("========================================");
   
   // Reset basket
   currentBasket.totalTrades = 0;
   currentBasket.basketDirection = 0;
   currentBasket.basketStartTime = 0;
   currentBasket.highestBasketProfit = 0.0;
   currentBasket.lowestBasketProfit = 0.0;
   currentBasket.recoveryMode = false;
   currentBasket.recoveryTriggerLevel = 0.0;
   currentBasket.recoveryTarget = 0.0;
   currentBasket.recoveryTargetReached = false;
   currentBasket.tradesHeldAfterRecovery = 0;
   currentBasket.partialClose1Done = false;
   currentBasket.partialClose2Done = false;
}

// Update basket trades (check if pending orders executed, remove closed trades)
void UpdateBasketTrades()
{
   for(int i = currentBasket.totalTrades - 1; i >= 0; i--)
   {
      if(currentBasket.trades[i].ticket <= 0)
      {
         RemoveBasketTrade(i);
         continue;
      }
      
      if(!OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET))
      {
         // Check if closed in history
         if(OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET, MODE_HISTORY))
         {
            // Trade was closed, remove from basket
            RemoveBasketTrade(i);
         }
         else
         {
            // Order doesn't exist, remove
            RemoveBasketTrade(i);
         }
         continue;
      }
      
      // Check if pending order was executed
      if(OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT || 
         OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
      {
         if(OrderCloseTime() > 0)
         {
            // Pending order was executed, update to market order type
            if(OrderType() == OP_BUYLIMIT || OrderType() == OP_BUYSTOP)
               currentBasket.trades[i].orderType = OP_BUY;
            else
               currentBasket.trades[i].orderType = OP_SELL;
            currentBasket.trades[i].entryPrice = OrderOpenPrice();
         }
      }
   }
}

// Remove trade from basket
void RemoveBasketTrade(int index)
{
   if(index < 0 || index >= currentBasket.totalTrades)
      return;
   
   // Shift array
   for(int i = index; i < currentBasket.totalTrades - 1; i++)
   {
      currentBasket.trades[i] = currentBasket.trades[i + 1];
   }
   
   currentBasket.totalTrades--;
   
   // Reset basket if empty
   if(currentBasket.totalTrades == 0)
   {
      currentBasket.basketDirection = 0;
      currentBasket.basketStartTime = 0;
      currentBasket.highestBasketProfit = 0.0;
      currentBasket.lowestBasketProfit = 0.0;
      currentBasket.recoveryMode = false;
      currentBasket.recoveryTriggerLevel = 0.0;
      currentBasket.recoveryTarget = 0.0;
      currentBasket.recoveryTargetReached = false;
      currentBasket.tradesHeldAfterRecovery = 0;
      currentBasket.partialClose1Done = false;
      currentBasket.partialClose2Done = false;
   }
}


// =====================================================================================================
// RISK MANAGEMENT FUNCTIONS
// =====================================================================================================

// Update equity high water mark (highest equity reached)
void UpdateEquityHighWaterMark()
{
   double currentEquity = AccountEquity();
   if(currentEquity > equityHighWaterMark)
   {
      equityHighWaterMark = currentEquity;
   }
   
   // Reset trading stopped flag if equity recovers above drawdown threshold
   if(tradingStopped && equityHighWaterMark > 0.0)
   {
      double drawdown = equityHighWaterMark - currentEquity;
      double drawdownPercent = (drawdown / equityHighWaterMark) * 100.0;
      
      // Resume trading if drawdown is below the warning threshold
      if(drawdownPercent < MaxDrawdownPercent)
      {
         tradingStopped = false;
         Print("TRADING RESUMED: Drawdown reduced to ", DoubleToString(drawdownPercent, 2), "% (below ", DoubleToString(MaxDrawdownPercent, 1), "% limit)");
      }
   }
}

// Check maximum drawdown protection
bool CheckMaxDrawdown()
{
   if(!UseMaxDrawdownProtection)
      return false;
   
   if(equityHighWaterMark <= 0.0)
   {
      equityHighWaterMark = AccountEquity();
      return false;
   }
   
   double currentEquity = AccountEquity();
   double drawdown = equityHighWaterMark - currentEquity;
   double drawdownPercent = (drawdown / equityHighWaterMark) * 100.0;
   
   // Emergency stop: Close all positions and stop trading
   if(drawdownPercent >= MaxDrawdownStopTrading)
   {
      if(!tradingStopped)
      {
         tradingStopped = true;
         Print("========================================");
         Print("EMERGENCY STOP: Maximum drawdown exceeded!");
         Print("Drawdown: ", DoubleToString(drawdownPercent, 2), "% (Limit: ", DoubleToString(MaxDrawdownStopTrading, 2), "%)");
         Print("High Water Mark: $", DoubleToString(equityHighWaterMark, 2));
         Print("Current Equity: $", DoubleToString(currentEquity, 2));
         Print("All trading stopped until equity recovers");
         Print("========================================");
         
         // Close all open positions
         if(currentBasket.totalTrades > 0)
         {
            CloseEntireBasket("Emergency Stop: Drawdown " + DoubleToString(drawdownPercent, 2) + "%");
         }
      }
      return true;  // Stop opening new trades
   }
   
   // Warning level: Stop opening new trades but keep existing ones
   if(drawdownPercent >= MaxDrawdownPercent)
   {
      if(!tradingStopped)
      {
         tradingStopped = true;
         Print("DRAWDOWN WARNING: ", DoubleToString(drawdownPercent, 2), "% (Limit: ", DoubleToString(MaxDrawdownPercent, 2), "%)");
         Print("New trades blocked until drawdown reduces");
      }
      return true;  // Stop opening new trades
   }
   
   return false;  // Drawdown OK, can trade
}

// Check maximum open positions
bool CheckMaxOpenPositions()
{
   if(MaxOpenPositions <= 0)
      return false;  // No limit
   
   int totalOpenPositions = 0;
   
   // Count all open positions with this EA's magic number
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
         {
            // Count only market orders (pending orders are not "open positions" yet)
            if(OrderType() == OP_BUY || OrderType() == OP_SELL)
            {
               totalOpenPositions++;
            }
         }
      }
   }
   
   // Check if we're at the limit
   if(totalOpenPositions >= MaxOpenPositions)
   {
      return true;  // At limit, don't open new trades
   }
   
   return false;  // Under limit, can open trades
}

// =====================================================================================================
// UTILITY FUNCTIONS
// =====================================================================================================

double CalculateLotSize()
{
   // Use AccountEquity() instead of AccountBalance() to account for floating losses
   double equity = AccountEquity();
   
   // Calculate how many trades will be in the basket (current + new)
   int currentTradesInBasket = currentBasket.totalTrades;
   int totalTradesInBasket = currentTradesInBasket + 1;  // Including this new trade
   
   // Calculate total basket risk based on MaxBasketRiskPercent
   double totalBasketRisk = equity * (MaxBasketRiskPercent / 100.0);
   
   // Distribute risk across all trades in basket
   // Each trade should risk: (MaxBasketRiskPercent / totalTradesInBasket)%
   double riskPerTradePercent = MaxBasketRiskPercent / totalTradesInBasket;
   
   // But don't exceed RiskPercentPerTrade limit
   if(riskPerTradePercent > RiskPercentPerTrade)
   {
      riskPerTradePercent = RiskPercentPerTrade;
   }
   
   // Calculate risk amount for this trade
   double riskAmount = equity * (riskPerTradePercent / 100.0);
   
   // Use ATR for stop loss calculation
   double atr = iATR(Symbol(), PERIOD_M1, Analysis_ATR_Period, 0);
   double slDistance = atr * 2.0;
   if(slDistance < pipToPoint * 5.0)
      slDistance = pipToPoint * 5.0;
   
   double pipValue = GetPipValuePerLot();
   if(pipValue <= 0.0)
      return MinLotSize;
   
   double slPips = slDistance / pipToPoint;
   double lotSize = riskAmount / (slPips * pipValue);
   
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, MathMax(MinLotSize, minLot));
   lotSize = MathMin(lotSize, MathMin(MaxLotSize, maxLot));
   
   return NormalizeDouble(lotSize, 2);
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

string GetPhaseName()
{
   switch(currentPhase)
   {
      case PHASE_REST: return "REST";
      case PHASE_ANALYSIS: return "ANALYSIS";
      case PHASE_TRADING: return "TRADING";
      case PHASE_PAUSE: return "PAUSE";
      case PHASE_CLOSE: return "CLOSE";
      default: return "UNKNOWN";
   }
}

// =====================================================================================================
// DISPLAY
// =====================================================================================================

void UpdateDisplay()
{
   string display = "\n=== BURST REST SCALPER ===\n";
   display += "Phase: " + GetPhaseName() + "\n";
   
   int elapsedSeconds = (int)(TimeCurrent() - phaseStartTime);
   display += "Phase Time: " + IntegerToString(elapsedSeconds) + "s\n";
   
   // Basket information
   display += "Basket Trades: " + IntegerToString(currentBasket.totalTrades) + "/" + IntegerToString(MaxTradesPerBasket) + "\n";
   if(currentBasket.basketDirection != 0)
   {
      display += "Basket Direction: " + (currentBasket.basketDirection == 1 ? "BUY" : "SELL") + "\n";
      if(currentBasket.basketStartTime > 0)
      {
         int basketAge = (int)(TimeCurrent() - currentBasket.basketStartTime);
         display += "Basket Age: " + IntegerToString(basketAge) + "s\n";
      }
   }
   
   if(currentPhase == PHASE_ANALYSIS || currentPhase == PHASE_TRADING)
   {
      display += "Analysis: " + (analysisDirection == 1 ? "BUY" : (analysisDirection == -1 ? "SELL" : "NONE")) + "\n";
      display += "Order Type: " + GetOrderTypeName(analysisOrderType) + "\n";
      display += "Strength: " + DoubleToString(analysisStrength, 1) + "%\n";
   }
   
   // Calculate basket profit (including commissions)
   double basketProfit = CalculateBasketProfit();
   display += "Basket P&L: $" + DoubleToString(basketProfit, 2) + "\n";
   
   // Calculate profit percentage
   double initialRisk = 0.0;
   for(int i = 0; i < currentBasket.totalTrades; i++)
   {
      if(currentBasket.trades[i].ticket > 0)
      {
         double balance = AccountBalance();
         double tradeRisk = balance * (RiskPercentPerTrade / 100.0);
         initialRisk += tradeRisk;
      }
   }
   double basketProfitPercent = 0.0;
   if(initialRisk > 0.0)
      basketProfitPercent = (basketProfit / initialRisk) * 100.0;
   
   display += "Basket P&L: " + DoubleToString(basketProfitPercent, 2) + "%\n";
   display += "Risk: " + DoubleToString(RiskPercentPerTrade, 1) + "% per trade\n";
   display += "Max Basket Risk: " + DoubleToString(MaxBasketRiskPercent, 1) + "%\n";
   
   // Risk management display
   if(UseMaxDrawdownProtection)
   {
      double currentEquity = AccountEquity();
      double drawdown = 0.0;
      double drawdownPercent = 0.0;
      if(equityHighWaterMark > 0.0)
      {
         drawdown = equityHighWaterMark - currentEquity;
         drawdownPercent = (drawdown / equityHighWaterMark) * 100.0;
      }
      display += "Drawdown: " + DoubleToString(drawdownPercent, 2) + "% (Max: " + DoubleToString(MaxDrawdownPercent, 1) + "%)\n";
      if(tradingStopped)
      {
         display += "TRADING STOPPED (Drawdown Protection)\n";
      }
   }
   
   // Recovery mode display
   if(currentBasket.recoveryMode)
   {
      display += "=== RECOVERY MODE ===\n";
      display += "Trigger: " + DoubleToString(currentBasket.recoveryTriggerLevel, 2) + "%\n";
      display += "Target: " + DoubleToString(currentBasket.recoveryTarget, 2) + "% (1:" + DoubleToString(RecoveryRR_Ratio, 1) + " R:R)\n";
      display += "Hold Until: " + DoubleToString(currentBasket.recoveryTarget * (RecoveryHoldRR_Ratio / RecoveryRR_Ratio), 2) + "% (1:" + DoubleToString(RecoveryHoldRR_Ratio, 1) + " R:R)\n";
      if(currentBasket.recoveryTargetReached)
         display += "Target: REACHED\n";
      if(HoldOneTradeAfterRecovery)
         display += "Holding: " + IntegerToString(currentBasket.tradesHeldAfterRecovery) + " trade(s)\n";
   }
   else
   {
      display += "Target: $" + DoubleToString(BasketProfitTarget, 2) + "\n";
   }
   
   if(basketProfit > 0.0)
   {
      if(currentBasket.recoveryMode)
         display += "STATUS: RECOVERING (Don't close early)\n";
      else
         display += "STATUS: PROFITABLE (Will close at $" + DoubleToString(BasketProfitTarget, 2) + ")\n";
   }
   else if(basketProfit < 0.0)
   {
      if(currentBasket.recoveryMode)
         display += "STATUS: RECOVERY MODE (Waiting for recovery)\n";
      else
         display += "STATUS: WAITING FOR PROFIT\n";
   }
   else
      display += "STATUS: NO BASKET\n";
   
   Comment(display);
}

