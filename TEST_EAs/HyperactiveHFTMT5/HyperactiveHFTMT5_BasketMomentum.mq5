#property copyright "Copyright 2025, Hyperactive HFT MT5 Scalper - Basket Momentum"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "2.00"

#include <Trade/Trade.mqh>

CTrade trade;

// =====================================================================================================
// HYPERACTIVE HFT MT5 SCALPER - BASKET MOMENTUM EDITION
// Strategy: Ultra-fast momentum breakout scalping with basket trading
// - One position at a time (duplicates bulk-closed)
// - Basket-level equity percentage exits (TP/SL)
// - Momentum breakout entry
// - Fast execution with realistic latency simulation
// - Dynamic or fixed lot sizing
// - Multi-instrument support
// =====================================================================================================

// ===== Core Trading Settings =====
input group "===== Core Trading Settings ====="
input int      MagicNumber         = 202510;
input string   TradeSymbol         = "";      // Symbol to trade (empty = current chart symbol)
input bool     UseFixedLot         = true;     // Use fixed lot size (false = dynamic)
input double   TradeLot            = 0.1;      // Lot size per trade (adjust here; if UseFixedLot = true)
input double   DynamicLotBase     = 0.05;     // Base lot for dynamic sizing
input double   DynamicLotMultiplier = 1.2;    // Multiplier for dynamic lot (based on balance)
input double   MaxLotSize          = 1.00;     // Maximum lot size (safety limit)
input double   MinLotSize          = 0.01;     // Minimum lot size (safety limit)

// ===== Entry Settings =====
input group "===== Momentum Breakout Entry ====="
input int      MomentumPeriod      = 22;       // Period for momentum calculation (ticks) - FX optimized
input double   BreakoutThreshold   = 0.00045;  // Minimum price movement for breakout (FX optimized)
input int      MinTickSpeed        = 4;        // Minimum ticks per second for entry (FX optimized)
input bool     UseTickSpeedFilter  = true;     // Enable tick speed filter
input double   StrongBreakoutMultiplier = 1.8; // Enter immediately if breakout >= threshold * multiplier (bypass pullback)

// ===== Exit Settings =====
input group "===== Profit Exit Settings ====="
input double   MinProfitPoints     = 10.0;     // Minimum profit in points to exit (DISABLED in basket mode)
input int      MaxProfitHoldSeconds = 200;     // Maximum seconds to hold profitable trade (DISABLED in basket mode)
input bool     ExitImmediatelyOnProfit = false; // Exit immediately when profit target reached (DISABLED in basket mode)

input group "===== Loss Protection Settings ====="
input double   MaxLossPoints       = 250.0;    // Maximum loss in points (stop loss) - Reduced from 100
input int      MaxLossHoldSeconds  = 100;      // Close losing trade after N seconds (DISABLED in basket mode)
input bool     UseTimeBasedLossExit = false;    // Enable time-based loss exit (DISABLED in basket mode)

// ===== Stop Loss Settings =====
input group "===== Stop Loss Settings ====="
input bool     UseStopLoss         = false;    // Use hard stop loss
input double   StopLossPoints      = 250.0;    // Stop loss in points (if UseStopLoss = true) - Reduced from 100
input bool     UseTrailingStop     = false;     // Use trailing stop loss (DISABLED in basket mode)
input double   TrailingStartPoints = 44.0;     // Start trailing after X points profit
input double   TrailingStepPoints  = 10.0;     // Trailing step in points (tighter for HFT)

// ===== Spread & Slippage =====
input group "===== Spread & Execution ====="
input double   MaxSpreadPoints     = 50.0;     // Maximum spread in points
input int      MaxSlippagePoints   = 10;       // Maximum slippage in points
input int      OrderRetries        = 3;        // Number of order retries

// ===== Risk Management =====
input group "===== Risk Management ====="
input double   MaxDrawdownPercent  = 30.0;      // Maximum drawdown % (stop trading)
input bool     UseDrawdownProtection = true;    // Enable drawdown protection
input double   DailyProfitTarget   = 0.0;       // Daily profit target (0 = disabled)

// ===== Session Filter =====
input group "===== Session Filter ====="
input bool     UseSessionFilter    = false;     // Enable session filter
input int      SessionStartHour    = 8;         // Session start hour (GMT)
input int      SessionEndHour      = 20;        // Session end hour (GMT)

// ===== Pullback Entry Filter =====
input group "===== Pullback Entry Filter ====="
input bool     UsePullbackFilter  = true;       // Enable micro-pullback filter
input double   PullbackPoints     = 1.5;        // Retrace points after breakout (reduced from 2.5 for faster entries)
input int      PullbackTimeoutSeconds = 6;      // Timeout for pullback wait (reduced from 10 for faster reset)

// ===== Volatility Cycle Filter =====
input group "===== Volatility Cycle Filter ====="
input bool     UseVolatilityCycleFilter = true; // Enable volatility cycle filter
input int      VolatilityCycleSeconds = 2;      // Tick speed must be rising for N seconds (reduced from 4 for more entries)

// ===== Spread Normalized Filter =====
input group "===== Spread Normalized Filter ====="
input bool     UseSpreadNormalizedFilter = true; // Enable spread-normalized filter
input double   SpreadMultiplier = 1.5;           // Block when spread > avg * multiplier

// ===== Liquidity Time Filter =====
input group "===== Liquidity Time Filter ====="
input bool     UseLiquidityTimeFilter = true;   // Enable liquidity time filter
input int      BlockStartHour1 = 22;            // First blocked period start (GMT)
input int      BlockEndHour1 = 2;               // First blocked period end (GMT)
input int      BlockStartHour2 = 0;             // Second blocked period start (0 = disabled)
input int      BlockEndHour2 = 0;               // Second blocked period end

// ===== Dynamic Breakeven =====
input group "===== Dynamic Breakeven ====="
input bool     UseDynamicBreakeven = false;      // Enable dynamic breakeven (DISABLED in basket mode)
input double   BreakevenTriggerPoints = 2.0;    // Move SL when profit > X points
input double   BreakevenOffsetPoints = 2.0;     // Move SL to entry - X points

// ===== Partial Exit =====
input group "===== Partial Exit ====="
input bool     UsePartialExit = false;           // Enable partial exit (DISABLED in basket mode)
input double   PartialExitProfitPoints = 30.0; // Close 50% at X points profit
input double   PartialExitPercent = 50.0;      // Percentage to close (50% = half position)

// ===== Basket Trading Settings =====
input group "===== Basket Trading Settings ====="
input int      MaxBasketTrades        = 1;        // Maximum simultaneous trades (1 = one trade only)
input double   BasketProfitPercent    = 1.2;      // Basket TP as % of basketStartEquity (reduced for faster exits)
input double   BasketMaxLossPercent   = 4.0;      // Basket SL as % of basketStartEquity (FX optimized)
input double   BasketCloseBufferUSD   = 0.3;      // Safety buffer to absorb spread & latency
input int      MinHoldMilliseconds   = 800;      // Minimum hold time before allowing exits (scalp protection)
input double   BasketConfirmUSD      = 0.5;      // Required profit before allowing invalidation/exits
input int      BasketMaxHoldSeconds    = 300;      // Maximum hold time for profitable basket (5 minutes)
input bool     UseBasketTrailingStop  = true;     // Enable basket trailing stop
input double   BasketTrailingStartUSD = 1.0;      // Start trailing after $1 profit
input double   BasketTrailingStepUSD  = 0.3;      // Trail by $0.30

// ===== Velocity-Based Exit Settings =====
input group "===== Velocity-Based Exit Settings ====="
input bool     UseVelocityExits = true;           // Enable velocity-based exits
input double   VelocitySampleIntervalMS = 200.0;  // Velocity sampling interval (milliseconds)
input double   VelocityReversalThreshold = 0.3;   // Velocity reversal threshold (points/second)
input double   VelocityDecayRatio = 0.4;          // Close when velocity < peak * ratio
input double   VelocityTrailingMultiplier = 2.0;  // Trailing stop multiplier based on velocity
input double   MinVelocityForHold = 0.1;          // Minimum velocity to extend hold time

// =====================================================================================================
// STRUCTURES & GLOBALS
// =====================================================================================================

// ===== Basket Trading Globals =====
double basketStartEquity = 0.0;          // Equity when first trade of basket opens
double basketTotalProfitUSD = 0.0;
ulong basketOpenTimeMS = 0;          // Timestamp when first trade opened (milliseconds)
double basketMaxProfitUSD = 0.0;       // Maximum profit seen for trailing stop

// Tick tracking for momentum
double tickPrices[50];
datetime tickTimes[50];
int tickIndex = 0;
bool tickBufferReady = false;

// Momentum tracking
double lastBid = 0.0;
double lastAsk = 0.0;
int momentumDirection = 0;  // 1=bullish, -1=bearish, 0=neutral
int consecutiveMomentumTicks = 0;

// Tick speed tracking
int tickCountInWindow = 0;
datetime lastTickSpeedCheck = 0;
double ticksPerSecond = 0.0;

// Market data
string tradeSymbol = "";
double point = 0.0;
int symbolDigits = 0;
MqlTick currentTick;
double currentBid = 0.0;
double currentAsk = 0.0;
double currentSpread = 0.0;

// Risk management
double initialBalance = 0.0;
double highestBalance = 0.0;
double dailyProfit = 0.0;
datetime lastDayReset = 0;
bool tradingStopped = false;

// Pullback tracking
double breakoutPeakPrice = 0.0;
bool breakoutDetected = false;
int breakoutDirection = 0;
datetime breakoutTime = 0;

// Volatility cycle tracking
double tickSpeedHistory[10];
datetime tickSpeedHistoryTime[10];
int tickSpeedHistoryIndex = 0;
int tickSpeedHistoryCount = 0;

// Spread history
double spreadHistory[100];
int spreadHistoryIndex = 0;
int spreadHistoryCount = 0;
double averageSpread = 0.0;

// Basket invalidation tracking
int basketEntryDirection = 0;        // Direction when basket opened (1=BUY, -1=SELL, 0=none)
int momentumFlipCount = 0;           // Count of momentum flips from basket entry direction
int lastMomentumDirection = 0;       // Previous momentum direction (for flip detection)
double breakoutOriginPrice = 0.0;    // Price at first breakout detection (for failure detection)
bool momentumLegUsed = false;        // Track if current momentum leg already used for entry
int lastMomentumLegDirection = 0;    // Direction of last momentum leg that opened a trade

// Price velocity tracking
double priceVelocity = 0.0;              // Current price velocity (points/second)
double priceVelocityHistory[20];         // Velocity history for trend detection
ulong priceVelocityTimeMS[20];          // Timestamps for velocity samples (milliseconds)
int priceVelocityIndex = 0;              // Ring buffer index
int priceVelocityCount = 0;             // Number of samples collected
double peakVelocity = 0.0;               // Peak velocity seen since basket opened
double basketEntryPrice = 0.0;           // Entry price for velocity calculation
ulong lastVelocitySampleMS = 0;          // Last velocity sample time
double lastPriceForVelocity = 0.0;       // Last price used for velocity calculation
bool velocityTrackingActive = false;    // Whether velocity tracking is active

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   // Seed random generator for DelayExecution() - ensures truly random delays
   MathSrand((uint)TimeLocal());
   
   Print("========================================");
   Print("Hyperactive HFT MT5 Scalper V2A.00 - BASKET MOMENTUM");
   Print("Ultra-fast momentum breakout scalping with basket trading");
   Print("========================================");
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints);
   trade.SetTypeFilling(ORDER_FILLING_FOK);  // Fast execution
   
   // Determine trade symbol
   if(TradeSymbol == "" || TradeSymbol == NULL)
      tradeSymbol = _Symbol;
   else
      tradeSymbol = TradeSymbol;
   
   // Initialize symbol data
   if(!SymbolInfoInteger(tradeSymbol, SYMBOL_SELECT))
   {
      Print("ERROR: Symbol ", tradeSymbol, " not found!");
      return(INIT_FAILED);
   }
   
   symbolDigits = (int)SymbolInfoInteger(tradeSymbol, SYMBOL_DIGITS);
   point = SymbolInfoDouble(tradeSymbol, SYMBOL_POINT);
   if(symbolDigits == 3 || symbolDigits == 5)
      point *= 10.0;
   
   // Initialize basket trading state
   basketStartEquity = 0.0;
   basketTotalProfitUSD = 0.0;
   
   // Initialize risk management
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   highestBalance = initialBalance;
   dailyProfit = 0.0;
   lastDayReset = TimeCurrent();
   tradingStopped = false;
   
   // Initialize arrays
   for(int i = 0; i < 50; i++)
   {
      tickPrices[i] = 0.0;
      tickTimes[i] = 0;
   }
   
   tickIndex = 0;
   tickBufferReady = false;
   lastBid = 0.0;
   lastAsk = 0.0;
   momentumDirection = 0;
   consecutiveMomentumTicks = 0;
   
   // Initialize pullback tracking
   breakoutPeakPrice = 0.0;
   breakoutDetected = false;
   breakoutDirection = 0;
   breakoutTime = 0;
   
   // Initialize volatility cycle tracking
   for(int i = 0; i < 10; i++)
   {
      tickSpeedHistory[i] = 0.0;
      tickSpeedHistoryTime[i] = 0;
   }
   tickSpeedHistoryIndex = 0;
   tickSpeedHistoryCount = 0;
   
   // Initialize spread history
   for(int i = 0; i < 100; i++)
   {
      spreadHistory[i] = 0.0;
   }
   spreadHistoryIndex = 0;
   spreadHistoryCount = 0;
   averageSpread = 0.0;
   
   // Initialize basket invalidation tracking
   basketEntryDirection = 0;
   momentumFlipCount = 0;
   lastMomentumDirection = 0;
   breakoutOriginPrice = 0.0;
   momentumLegUsed = false;
   lastMomentumLegDirection = 0;
   
   // Initialize velocity tracking
   for(int i = 0; i < 20; i++)
   {
      priceVelocityHistory[i] = 0.0;
      priceVelocityTimeMS[i] = 0;
   }
   priceVelocityIndex = 0;
   priceVelocityCount = 0;
   priceVelocity = 0.0;
   peakVelocity = 0.0;
   basketEntryPrice = 0.0;
   lastVelocitySampleMS = 0;
   lastPriceForVelocity = 0.0;
   velocityTrackingActive = false;
   
   Print("Trade Symbol: ", tradeSymbol);
   Print("Lot Mode: ", (UseFixedLot ? "FIXED" : "DYNAMIC"));
   Print("Trade Lot: ", TradeLot);
   Print("Max Basket Trades: ", MaxBasketTrades);
   Print("Basket TP: ", BasketProfitPercent, "% of start equity");
   Print("Basket SL: ", BasketMaxLossPercent, "% of start equity");
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("Hyperactive HFT MT5 Scalper (Basket Momentum) deinitialized. Reason: ", reason);
}

// =====================================================================================================
// BASKET UTILITY FUNCTIONS
// =====================================================================================================

// Calculate total profit for all basket trades (profit + swap + commission)
double CalculateBasketProfit()
{
    double total = 0.0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == tradeSymbol)
            {
                total += PositionGetDouble(POSITION_PROFIT)
                       + PositionGetDouble(POSITION_SWAP);
                // Note: POSITION_PROFIT already includes commission in MT5
            }
        }
    }
    return total;
}

// Count open trades in basket
int OpenTradesCount()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == tradeSymbol)
                count++;
        }
    }
    return count;
}

// Get direction of existing basket trades (1=BUY, -1=SELL, 0=none)
int GetExistingBasketDirection()
{
    // Returns 1 for BUY, -1 for SELL, 0 if no trades exist
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == tradeSymbol)
            {
                return (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
            }
        }
    }
    return 0;  // No existing trades
}

// Close all basket trades
void CloseAllBasketTrades()
{
    // First collect all tickets into an array (prevents skips if MT5 reorders positions during iteration)
    ulong tickets[];
    ArrayResize(tickets, 0);
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == tradeSymbol)
            {
                int size = ArraySize(tickets);
                ArrayResize(tickets, size + 1);
                tickets[size] = ticket;
            }
        }
    }
    
    // Now close all collected tickets
    for(int i = 0; i < ArraySize(tickets); i++)
    {
        if(PositionSelectByTicket(tickets[i]))
        {
            double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            trade.PositionClose(tickets[i]);
            Print("BASKET TRADE CLOSED: Ticket ", tickets[i], " | P&L: $", DoubleToString(profit, 2));
        }
    }
    
    // Reset basket equity tracking
    basketStartEquity = 0.0;
    basketTotalProfitUSD = 0.0;
    
    // Reset basket invalidation tracking
    basketEntryDirection = 0;
    momentumFlipCount = 0;
    lastMomentumDirection = 0;
    breakoutOriginPrice = 0.0;
    momentumLegUsed = false;
    lastMomentumLegDirection = 0;
    basketOpenTimeMS = 0;  // Reset basket open time
    basketMaxProfitUSD = 0.0;  // Reset trailing stop tracking
    
    // Reset velocity tracking
    priceVelocity = 0.0;
    peakVelocity = 0.0;
    basketEntryPrice = 0.0;
    lastVelocitySampleMS = 0;
    lastPriceForVelocity = 0.0;
    priceVelocityCount = 0;
    priceVelocityIndex = 0;
    velocityTrackingActive = false;
    
    // Clear velocity history
    for(int i = 0; i < 20; i++)
    {
       priceVelocityHistory[i] = 0.0;
       priceVelocityTimeMS[i] = 0;
    }
}

// Execution delay to simulate VPS + broker latency
void DelayExecution()
{
    int minDelay = 5;
    int maxDelay = 25;
    int delay = (int)MathRand() % (maxDelay - minDelay + 1) + minDelay;
    Sleep(delay);
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   // Update market data
   if(!UpdateMarketData())
      return;
   
   // Update tick buffers
   UpdateTickBuffers();
   
   // Calculate tick speed
   CalculateTickSpeed();
   
   // Check risk management
   CheckRiskManagement();
   
   if(OpenTradesCount() > 1)
   {
      Print("SINGLE POSITION: bulk closing ", OpenTradesCount(), " positions");
      CloseAllBasketTrades();
      UpdateDisplay();
      return;
   }
   
   if(tradingStopped)
   {
      UpdateDisplay();
      return;
   }
   
   // Manage basket trades
   if(OpenTradesCount() > 0)
   {
      // Calculate price velocity for velocity-based exits
      CalculatePriceVelocity();
      ManageBasket();
   }
   
   // Look for new entry if basket not full
   if(OpenTradesCount() < MaxBasketTrades && !tradingStopped)
   {
      int direction = GetMomentumBreakoutSignal();
      
      if(direction != 0)
      {
         if(ShouldOpenTrade(direction))
         {
            OpenTrade(direction);
         }
      }
   }
   
   // Update display
   UpdateDisplay();
}

// =====================================================================================================
// MARKET DATA & TICK TRACKING
// =====================================================================================================

bool UpdateMarketData()
{
   if(!SymbolInfoTick(tradeSymbol, currentTick))
      return false;
   
   currentBid = currentTick.bid;
   currentAsk = currentTick.ask;
   currentSpread = (currentAsk - currentBid) / point;
   
   return (currentBid > 0.0 && currentAsk > 0.0);
}

void UpdateTickBuffers()
{
   double midPrice = (currentBid + currentAsk) / 2.0;
   datetime now = TimeCurrent();
   
   // Shift tick buffer (ring buffer)
   for(int i = 49; i > 0; i--)
   {
      tickPrices[i] = tickPrices[i-1];
      tickTimes[i] = tickTimes[i-1];
   }
   
   tickPrices[0] = midPrice;
   tickTimes[0] = now;
   
   tickIndex++;
   if(tickIndex >= MomentumPeriod)
      tickBufferReady = true;
   
   // Update momentum direction
   if(lastBid > 0.0 && lastAsk > 0.0)
   {
      int previousMomentumDirection = momentumDirection;  // Store before update
      
      if(currentBid > lastBid)
      {
         if(momentumDirection == 1)
            consecutiveMomentumTicks++;
         else
         {
            momentumDirection = 1;
            consecutiveMomentumTicks = 1;
         }
      }
      else if(currentBid < lastBid)
      {
         if(momentumDirection == -1)
            consecutiveMomentumTicks++;
         else
         {
            momentumDirection = -1;
            consecutiveMomentumTicks = 1;
         }
      }
      else
      {
         // Price unchanged, maintain momentum but don't increment
      }
      
      // Track momentum flips relative to basket entry direction
      if(OpenTradesCount() > 0 && basketEntryDirection != 0)
      {
         // Check if momentum flipped from basket entry direction
         if(previousMomentumDirection != momentumDirection && previousMomentumDirection != 0)
         {
            // Momentum changed - check if it's opposite to basket entry
            if(momentumDirection == -basketEntryDirection)
            {
               momentumFlipCount++;
               Print("MOMENTUM FLIP DETECTED: Count = ", momentumFlipCount, " | Basket Direction: ", 
                     (basketEntryDirection == 1 ? "BUY" : "SELL"), " | Momentum: ", 
                     (momentumDirection == 1 ? "BULLISH" : "BEARISH"));
            }
         }
      }
      
      lastMomentumDirection = momentumDirection;  // Store for next tick
   }
   
   lastBid = currentBid;
   lastAsk = currentAsk;
   
   // Update spread history
   UpdateSpreadHistory();
}

void CalculateTickSpeed()
{
   datetime now = TimeCurrent();
   
   if(lastTickSpeedCheck == 0)
   {
      lastTickSpeedCheck = now;
      tickCountInWindow = 0;
      return;
   }
   
   tickCountInWindow++;
   
   int elapsedSeconds = (int)(now - lastTickSpeedCheck);
   if(elapsedSeconds >= 1)
   {
      ticksPerSecond = (double)tickCountInWindow / (double)elapsedSeconds;
      
      // Store tick speed in history for volatility cycle filter
      if(tickSpeedHistoryCount < 10)
      {
         tickSpeedHistory[tickSpeedHistoryCount] = ticksPerSecond;
         tickSpeedHistoryTime[tickSpeedHistoryCount] = now;
         tickSpeedHistoryCount++;
      }
      else
      {
         // Shift array (ring buffer)
         for(int i = 0; i < 9; i++)
         {
            tickSpeedHistory[i] = tickSpeedHistory[i+1];
            tickSpeedHistoryTime[i] = tickSpeedHistoryTime[i+1];
         }
         tickSpeedHistory[9] = ticksPerSecond;
         tickSpeedHistoryTime[9] = now;
      }
      
      tickCountInWindow = 0;
      lastTickSpeedCheck = now;
   }
}

// =====================================================================================================
// SPREAD HISTORY TRACKING
// =====================================================================================================

void UpdateSpreadHistory()
{
   // Add current spread to history
   spreadHistory[spreadHistoryIndex] = currentSpread;
   spreadHistoryIndex = (spreadHistoryIndex + 1) % 100;
   
   if(spreadHistoryCount < 100)
      spreadHistoryCount++;
   
   // Calculate average spread
   if(spreadHistoryCount > 0)
   {
      double sum = 0.0;
      for(int i = 0; i < spreadHistoryCount; i++)
      {
         sum += spreadHistory[i];
      }
      averageSpread = sum / spreadHistoryCount;
   }
}

// =====================================================================================================
// PRICE VELOCITY TRACKING
// =====================================================================================================

void CalculatePriceVelocity()
{
   if(!velocityTrackingActive || OpenTradesCount() == 0)
      return;
   
   ulong currentTimeMS = GetTickCount64();
   double midPrice = (currentBid + currentAsk) / 2.0;
   
   // Initialize on first sample
   if(lastVelocitySampleMS == 0 || lastPriceForVelocity == 0.0)
   {
      lastVelocitySampleMS = currentTimeMS;
      lastPriceForVelocity = midPrice;
      return;
   }
   
   // Check if enough time has passed for sampling
   ulong elapsedMS = currentTimeMS - lastVelocitySampleMS;
   if(elapsedMS < (ulong)VelocitySampleIntervalMS)
      return;
   
   // Calculate velocity: (price_change) / (time_elapsed_in_seconds)
   double priceChange = midPrice - lastPriceForVelocity;
   double elapsedSeconds = (double)elapsedMS / 1000.0;
   
   if(elapsedSeconds > 0.001)  // Avoid division by zero
   {
      // Calculate velocity in points per second
      // For BUY trades, positive velocity is good (price going up)
      // For SELL trades, negative velocity is good (price going down)
      priceVelocity = priceChange / elapsedSeconds / point;  // Convert to points/second
      
      // Adjust sign based on basket direction for easier interpretation
      // Positive velocity = favorable for basket, negative = unfavorable
      if(basketEntryDirection == -1)  // SELL basket
         priceVelocity = -priceVelocity;  // Invert so positive = favorable
      
      // Track peak velocity
      if(MathAbs(priceVelocity) > MathAbs(peakVelocity))
         peakVelocity = priceVelocity;
      
      // Store in history (ring buffer)
      if(priceVelocityCount < 20)
      {
         priceVelocityHistory[priceVelocityCount] = priceVelocity;
         priceVelocityTimeMS[priceVelocityCount] = currentTimeMS;
         priceVelocityCount++;
      }
      else
      {
         // Shift array (ring buffer)
         for(int i = 0; i < 19; i++)
         {
            priceVelocityHistory[i] = priceVelocityHistory[i+1];
            priceVelocityTimeMS[i] = priceVelocityTimeMS[i+1];
         }
         priceVelocityHistory[19] = priceVelocity;
         priceVelocityTimeMS[19] = currentTimeMS;
      }
   }
   
   // Update for next sample
   lastVelocitySampleMS = currentTimeMS;
   lastPriceForVelocity = midPrice;
}

// =====================================================================================================
// VOLATILITY CYCLE FILTER
// =====================================================================================================

bool CheckVolatilityCycle()
{
   if(!UseVolatilityCycleFilter)
      return true;  // Filter disabled, allow entry
   
   // In strategy tester, tick speed history might be limited
   // Allow entry if we don't have enough data yet (more lenient)
   if(tickSpeedHistoryCount < 2)
      return true;  // Not enough data yet, allow entry (don't block)
   
   datetime now = TimeCurrent();
   
   // Check if tick speed has been rising for the required duration
   // Look at tick speeds within the VolatilityCycleSeconds window
   int validSamples = 0;
   double previousSpeed = 0.0;
   bool isRising = true;
   bool hasRecentData = false;
   
   for(int i = tickSpeedHistoryCount - 1; i >= 0; i--)
   {
      int ageSeconds = (int)(now - tickSpeedHistoryTime[i]);
      
      if(ageSeconds <= VolatilityCycleSeconds)
      {
         hasRecentData = true;
         if(validSamples > 0)
         {
            // Check if current speed is higher than previous
            if(tickSpeedHistory[i] <= previousSpeed)
            {
               isRising = false;
               break;
            }
         }
         previousSpeed = tickSpeedHistory[i];
         validSamples++;
      }
   }
   
   // If we don't have recent data within the window, allow entry (don't block)
   if(!hasRecentData)
      return true;
   
   // Need at least 2 samples showing rising trend, OR if tick speed is stable/acceptable
   // More lenient: allow if speed is not declining significantly
   if(validSamples >= 2)
   {
      // Check if speed is rising OR at least stable (not declining)
      if(isRising)
         return true;
      
      // Allow if speed is stable (not declining more than 20%)
      if(validSamples >= 2 && tickSpeedHistory[tickSpeedHistoryCount - 1] >= (previousSpeed * 0.8))
         return true;
   }
   
   // If we have some data but not enough for rising trend, be lenient
   if(validSamples >= 1 && ticksPerSecond >= MinTickSpeed)
      return true;
   
   return false;
}

// =====================================================================================================
// LIQUIDITY TIME FILTER
// =====================================================================================================

bool CheckLiquidityTime()
{
   if(!UseLiquidityTimeFilter)
      return true;  // Filter disabled, allow trading
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentHour = dt.hour;
   
   // Check first blocked period (handles wraparound)
   if(BlockStartHour1 != BlockEndHour1)
   {
      bool inBlock1 = false;
      if(BlockStartHour1 < BlockEndHour1)
      {
         // Normal case: 8-20 (8 to 20)
         inBlock1 = (currentHour >= BlockStartHour1 && currentHour < BlockEndHour1);
      }
      else
      {
         // Wraparound case: 22-2 (22 to 2 next day)
         inBlock1 = (currentHour >= BlockStartHour1 || currentHour < BlockEndHour1);
      }
      
      if(inBlock1)
         return false;  // Blocked
   }
   
   // Check second blocked period (if enabled)
   if(BlockStartHour2 != BlockEndHour2 && BlockStartHour2 != 0)
   {
      bool inBlock2 = false;
      if(BlockStartHour2 < BlockEndHour2)
      {
         inBlock2 = (currentHour >= BlockStartHour2 && currentHour < BlockEndHour2);
      }
      else
      {
         inBlock2 = (currentHour >= BlockStartHour2 || currentHour < BlockEndHour2);
      }
      
      if(inBlock2)
         return false;  // Blocked
   }
   
   return true;  // Not blocked, allow trading
}

// =====================================================================================================
// RISK MANAGEMENT
// =====================================================================================================

void CheckRiskManagement()
{
   // Reset daily profit at start of new day
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   MqlDateTime lastDt;
   TimeToStruct(lastDayReset, lastDt);
   
   if(dt.day != lastDt.day || dt.mon != lastDt.mon || dt.year != lastDt.year)
   {
      dailyProfit = 0.0;
      lastDayReset = currentTime;
   }
   
   // Check drawdown
   if(UseDrawdownProtection)
   {
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(currentEquity > highestBalance)
         highestBalance = currentEquity;
      
      double drawdown = ((highestBalance - currentEquity) / highestBalance) * 100.0;
      
      if(drawdown >= MaxDrawdownPercent)
      {
         tradingStopped = true;
         Print("TRADING STOPPED: Drawdown ", DoubleToString(drawdown, 2), "% exceeds limit ", DoubleToString(MaxDrawdownPercent, 1), "%");
         
         // Close any open basket trades
         if(OpenTradesCount() > 0)
         {
            DelayExecution();
            CloseAllBasketTrades();
         }
      }
   }
   
   // Check daily profit target
   if(DailyProfitTarget > 0.0)
   {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyProfit = currentBalance - initialBalance;
      
      if(dailyProfit >= DailyProfitTarget)
      {
         tradingStopped = true;
         Print("TRADING STOPPED: Daily profit target reached: $", DoubleToString(dailyProfit, 2));
         
         if(OpenTradesCount() > 0)
         {
            DelayExecution();
            CloseAllBasketTrades();
         }
      }
   }
}

// =====================================================================================================
// ENTRY LOGIC - MOMENTUM BREAKOUT
// =====================================================================================================

int GetMomentumBreakoutSignal()
{
   if(!tickBufferReady || tickIndex < MomentumPeriod)
      return 0;
   
   // Check liquidity time filter first
   if(!CheckLiquidityTime())
      return 0;
   
   // Check session filter
   if(UseSessionFilter)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int currentHour = dt.hour;
      
      if(currentHour < SessionStartHour || currentHour >= SessionEndHour)
         return 0;
   }
   
   // Check tick speed
   if(UseTickSpeedFilter && ticksPerSecond < MinTickSpeed)
      return 0;
   
   // Check volatility cycle filter
   if(!CheckVolatilityCycle())
      return 0;
   
   // Check spread
   if(currentSpread > MaxSpreadPoints)
      return 0;
   
   double midPrice = (currentBid + currentAsk) / 2.0;
   
   // Calculate momentum breakout
   double priceChange = 0.0;
   
   if(tickIndex >= MomentumPeriod)
   {
      // Calculate price change over momentum period
      double oldestPrice = tickPrices[MomentumPeriod - 1];
      double newestPrice = tickPrices[0];
      priceChange = newestPrice - oldestPrice;
      
      // Check for breakout: strong movement in momentum direction
      double breakoutThreshold = BreakoutThreshold;
      
      if(momentumDirection == 1 && priceChange >= breakoutThreshold)
      {
         // Bullish breakout detected
         if(consecutiveMomentumTicks >= 1)  // Reduced from 2 to 1 for more entries
         {
            // Capture breakout origin price at first detection (if no basket exists)
            if(OpenTradesCount() == 0 && breakoutOriginPrice == 0.0)
            {
               breakoutOriginPrice = midPrice;
            }
            
            // Check for strong breakout - enter immediately if momentum is very strong
            double strongBreakoutThreshold = breakoutThreshold * StrongBreakoutMultiplier;
            bool isStrongBreakout = (priceChange >= strongBreakoutThreshold && consecutiveMomentumTicks >= 2);
            
            if(isStrongBreakout)
            {
               // Strong breakout - enter immediately (sniper entry on strong momentum)
               breakoutDetected = false;  // Reset any pending pullback
               momentumLegUsed = false;  // Reset momentum leg flag for new entry
               return 1;  // BUY immediately
            }
            
            if(UsePullbackFilter)
            {
               // Track breakout peak
               if(!breakoutDetected || breakoutDirection != 1)
               {
                  breakoutDetected = true;
                  breakoutDirection = 1;
                  breakoutPeakPrice = midPrice;
                  breakoutTime = TimeCurrent();
                  return 0;  // Wait for pullback
               }
               else if(breakoutDirection == 1)
               {
                  // Update peak if price goes higher
                  if(midPrice > breakoutPeakPrice)
                  {
                     breakoutPeakPrice = midPrice;
                     breakoutTime = TimeCurrent();
                     
                     // If price continues strongly upward, enter immediately (strong momentum)
                     double continuedMomentum = midPrice - breakoutPeakPrice;
                     if(continuedMomentum >= (breakoutThreshold * 0.5))
                     {
                        breakoutDetected = false;
                        return 1;  // BUY - momentum too strong, don't wait for pullback
                     }
                     
                     return 0;  // Still in breakout, wait for pullback
                  }
                  
                  // Check for pullback: price retraced PullbackPoints from peak
                  double retraceFromPeak = breakoutPeakPrice - midPrice;
                  if(retraceFromPeak >= (PullbackPoints * point))
                  {
                     // Pullback occurred, enter immediately
                     breakoutDetected = false;  // Reset for next breakout
                     momentumLegUsed = false;  // Reset momentum leg flag - allow entry after pullback
                     return 1;  // BUY
                  }
                  
                  return 0;  // Still waiting for pullback
               }
            }
            else
            {
               // No pullback filter, enter immediately
               momentumLegUsed = false;  // Reset momentum leg flag for new entry
               return 1;  // BUY
            }
         }
      }
      else if(momentumDirection == -1 && priceChange <= -breakoutThreshold)
      {
         // Bearish breakout detected
         if(consecutiveMomentumTicks >= 1)  // Reduced from 2 to 1 for more entries
         {
            // Capture breakout origin price at first detection (if no basket exists)
            if(OpenTradesCount() == 0 && breakoutOriginPrice == 0.0)
            {
               breakoutOriginPrice = midPrice;
            }
            
            // Check for strong breakout - enter immediately if momentum is very strong
            double strongBreakoutThreshold = breakoutThreshold * StrongBreakoutMultiplier;
            bool isStrongBreakout = (priceChange <= -strongBreakoutThreshold && consecutiveMomentumTicks >= 2);
            
            if(isStrongBreakout)
            {
               // Strong breakout - enter immediately (sniper entry on strong momentum)
               breakoutDetected = false;  // Reset any pending pullback
               momentumLegUsed = false;  // Reset momentum leg flag for new entry
               return -1;  // SELL immediately
            }
            
            if(UsePullbackFilter)
            {
               // Track breakout peak (lowest point for SELL)
               if(!breakoutDetected || breakoutDirection != -1)
               {
                  breakoutDetected = true;
                  breakoutDirection = -1;
                  breakoutPeakPrice = midPrice;
                  breakoutTime = TimeCurrent();
                  return 0;  // Wait for pullback
               }
               else if(breakoutDirection == -1)
               {
                  // Update peak (lowest point) if price goes lower
                  if(midPrice < breakoutPeakPrice)
                  {
                     breakoutPeakPrice = midPrice;
                     breakoutTime = TimeCurrent();
                     
                     // If price continues strongly downward, enter immediately (strong momentum)
                     double continuedMomentum = breakoutPeakPrice - midPrice;
                     if(continuedMomentum >= (breakoutThreshold * 0.5))
                     {
                        breakoutDetected = false;
                        return -1;  // SELL - momentum too strong, don't wait for pullback
                     }
                     
                     return 0;  // Still in breakout, wait for pullback
                  }
                  
                  // Check for pullback: price retraced PullbackPoints from peak (lowest point)
                  double retraceFromPeak = midPrice - breakoutPeakPrice;
                  if(retraceFromPeak >= (PullbackPoints * point))
                  {
                     // Pullback occurred, enter immediately
                     breakoutDetected = false;  // Reset for next breakout
                     momentumLegUsed = false;  // Reset momentum leg flag - allow entry after pullback
                     return -1;  // SELL
                  }
                  
                  return 0;  // Still waiting for pullback
               }
            }
            else
            {
               // No pullback filter, enter immediately
               momentumLegUsed = false;  // Reset momentum leg flag for new entry
               return -1;  // SELL
            }
         }
      }
   }
   
   // Reset breakout if too much time has passed (timeout) - shorter timeout for faster reset
   if(breakoutDetected && (TimeCurrent() - breakoutTime) > PullbackTimeoutSeconds)
   {
      breakoutDetected = false;
      breakoutPeakPrice = 0.0;
      breakoutDirection = 0;
   }
   
   return 0;
}

bool ShouldOpenTrade(int direction)
{
   // Check if basket is full
   if(OpenTradesCount() >= MaxBasketTrades)
      return false;
   
   // Direction consistency safeguard - enforce same-direction basket
   if(OpenTradesCount() > 0 && direction != GetExistingBasketDirection())
      return false;
   
   // Prevent multiple trades per momentum leg
   if(OpenTradesCount() > 0 && momentumLegUsed && momentumDirection == lastMomentumLegDirection)
   {
      return false;  // Same momentum leg already used, wait for re-acceleration or pullback
   }
   
   // Check if trading is stopped
   if(tradingStopped)
      return false;
   
   // Check spread
   if(currentSpread > MaxSpreadPoints)
      return false;
   
   // Check spread-normalized filter
   if(UseSpreadNormalizedFilter && averageSpread > 0.0)
   {
      if(currentSpread > (averageSpread * SpreadMultiplier))
         return false;  // Spread too high relative to average
   }
   
   // Check tick speed
   if(UseTickSpeedFilter && ticksPerSecond < MinTickSpeed)
      return false;
   
   return true;
}

// =====================================================================================================
// LOT SIZING
// =====================================================================================================

double CalculateLotSize()
{
   double lotSize = 0.0;
   
   if(UseFixedLot)
   {
      lotSize = TradeLot;
   }
   else
   {
      // Dynamic lot sizing based on account balance
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      lotSize = DynamicLotBase * (balance / 1000.0) * DynamicLotMultiplier;
   }
   
   // Normalize lot size
   double lotStep = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MAX);
   
   // Apply safety limits
   lotSize = MathMax(MinLotSize, MathMin(MaxLotSize, lotSize));
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   
   // Round to lot step
   if(lotStep > 0.0)
      lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   return NormalizeDouble(lotSize, 2);
}

// =====================================================================================================
// OPEN TRADE
// =====================================================================================================

bool OpenTrade(int direction)
{
   if(direction == 0)
      return false;
   
   double lotSize = CalculateLotSize();
   double price = (direction == 1) ? currentAsk : currentBid;
   
   // Track basket equity when first trade opens
   if(OpenTradesCount() == 0)
   {
      basketStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      basketEntryDirection = direction;  // Store entry direction
      momentumFlipCount = 0;            // Reset flip count
      lastMomentumDirection = momentumDirection;  // Store current momentum
      // breakoutOriginPrice already captured at breakout detection
      momentumLegUsed = true;           // Mark this momentum leg as used
      lastMomentumLegDirection = direction;
      basketOpenTimeMS = GetTickCount64();  // Record basket open time
      basketMaxProfitUSD = 0.0;  // Reset trailing stop tracking
      
      // Initialize velocity tracking
      basketEntryPrice = (currentBid + currentAsk) / 2.0;
      lastPriceForVelocity = basketEntryPrice;
      lastVelocitySampleMS = GetTickCount64();
      priceVelocity = 0.0;
      peakVelocity = 0.0;
      priceVelocityCount = 0;
      priceVelocityIndex = 0;
      velocityTrackingActive = true;
      
      Print("BASKET ENTRY: Direction = ", (direction == 1 ? "BUY" : "SELL"), 
            " | Origin Price = ", DoubleToString(breakoutOriginPrice, symbolDigits));
   }
   else
   {
      // Additional trade in same basket - check if new momentum leg
      if(momentumDirection != lastMomentumLegDirection)
      {
         momentumLegUsed = false;  // New momentum leg, allow entry
         lastMomentumLegDirection = direction;
      }
      else
      {
         momentumLegUsed = true;  // Same momentum leg, prevent stacking
      }
   }
   
   // Calculate stop loss
   double sl = 0.0;
   if(UseStopLoss)
   {
      if(direction == 1)  // BUY
         sl = price - (StopLossPoints * point);
      else  // SELL
         sl = price + (StopLossPoints * point);
      
      sl = NormalizeDouble(sl, symbolDigits);
   }
   
   // No take profit (using basket-level exit)
   double tp = 0.0;
   
   string comment = "HyperHFT_BM_" + (direction == 1 ? "BUY" : "SELL");
   
   ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   // Add execution delay before trade operations (once before loop)
   DelayExecution();
   
   bool sent = false;
   int retries = 0;
   
   while(retries < OrderRetries && !sent)
   {
      if(orderType == ORDER_TYPE_BUY)
         sent = trade.Buy(lotSize, tradeSymbol, 0.0, sl, tp, comment);
      else
         sent = trade.Sell(lotSize, tradeSymbol, 0.0, sl, tp, comment);
      
      if(!sent)
      {
         retries++;
         if(retries < OrderRetries)
         {
            Sleep(50);  // Small delay before retry
            // Update market data before retry
            SymbolInfoTick(tradeSymbol, currentTick);
            currentBid = currentTick.bid;
            currentAsk = currentTick.ask;
            price = (direction == 1) ? currentAsk : currentBid;
         }
      }
   }
   
   if(sent)
   {
      // Reset breakout tracking when trade opens
      breakoutDetected = false;
      breakoutPeakPrice = 0.0;
      breakoutDirection = 0;
      breakoutTime = 0;
      
      // Mark momentum leg as used after successful entry
      momentumLegUsed = true;
      lastMomentumLegDirection = direction;
      
      Print("BASKET TRADE OPENED: ", (direction == 1 ? "BUY" : "SELL"), 
            " | Lot: ", lotSize, " | Price: ", price, " | Basket Trades: ", OpenTradesCount(), "/", MaxBasketTrades);
      return true;
   }
   else
   {
      Print("Trade open failed: ", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
   }
   
   return false;
}

// =====================================================================================================
// VELOCITY-BASED EXIT CHECKS
// =====================================================================================================

// Check velocity-based exit conditions
// Returns true if basket should be closed, false otherwise
bool CheckVelocityExits()
{
   if(!UseVelocityExits || !velocityTrackingActive || OpenTradesCount() == 0)
      return false;
   
   // Need at least a few velocity samples before making decisions
   if(priceVelocityCount < 2)
      return false;
   
   // ===== VELOCITY REVERSAL EXIT (Highest Priority for Profitable Trades) =====
   // If basket is profitable AND velocity reverses direction, close immediately
   if(basketTotalProfitUSD > 0.0 && priceVelocityCount >= 2)
   {
      // Get recent velocity samples to detect reversal
      double currentVel = priceVelocity;
      double previousVel = 0.0;
      
      // Find previous velocity sample
      if(priceVelocityCount >= 2)
      {
         int prevIndex = (priceVelocityCount >= 2) ? priceVelocityCount - 2 : 0;
         previousVel = priceVelocityHistory[prevIndex];
      }
      
      // Check for velocity reversal: was positive (favorable) now negative (unfavorable)
      // Or was negative (favorable for SELL) now positive (unfavorable)
      if(previousVel > VelocityReversalThreshold && currentVel < -VelocityReversalThreshold)
      {
         // Velocity reversed from favorable to unfavorable
         DelayExecution();
         CloseAllBasketTrades();
         Print("BASKET CLOSED: Velocity reversal detected | Profit: $", DoubleToString(basketTotalProfitUSD, 2), 
               " | Previous Vel: ", DoubleToString(previousVel, 3), " | Current Vel: ", DoubleToString(currentVel, 3));
         return true;
      }
   }
   
   // ===== VELOCITY DECAY EXIT =====
   // Close when velocity drops below decay ratio of peak (momentum exhaustion)
   if(MathAbs(peakVelocity) > 0.1 && priceVelocityCount >= 3)  // Need peak velocity and some history
   {
      double decayThreshold = peakVelocity * VelocityDecayRatio;
      
      // Check if current velocity has decayed significantly from peak
      // For favorable velocity (positive), check if it dropped below threshold
      if(peakVelocity > 0 && priceVelocity < decayThreshold)
      {
         // Only exit if we're at least slightly profitable (don't exit losing trades on decay alone)
         if(basketTotalProfitUSD > 0.0)
         {
            DelayExecution();
            CloseAllBasketTrades();
            Print("BASKET CLOSED: Velocity decay detected | Profit: $", DoubleToString(basketTotalProfitUSD, 2), 
                  " | Peak Vel: ", DoubleToString(peakVelocity, 3), " | Current Vel: ", DoubleToString(priceVelocity, 3), 
                  " | Decay Threshold: ", DoubleToString(decayThreshold, 3));
            return true;
         }
      }
   }
   
   return false;  // No velocity-based exit triggered
}

// Get velocity-adjusted trailing stop level
// Returns the trailing stop level in USD, or 0 if trailing stop shouldn't be applied
double GetVelocityAdjustedTrailingStop()
{
   if(!UseVelocityExits || !UseBasketTrailingStop || basketTotalProfitUSD <= 0.0)
      return 0.0;
   
   if(basketMaxProfitUSD < BasketTrailingStartUSD)
      return 0.0;  // Haven't reached trailing start threshold
   
   // Base trailing step
   double baseTrailingStep = BasketTrailingStepUSD;
   
   // Adjust trailing step based on current velocity
   // High velocity = wider trailing stop (allow more room for volatility)
   // Low velocity = tighter trailing stop (protect profits)
   double velocityMultiplier = 1.0;
   
   if(MathAbs(priceVelocity) > MinVelocityForHold)
   {
      // Scale multiplier based on velocity magnitude
      // Higher velocity = larger multiplier (up to VelocityTrailingMultiplier)
      double velocityRatio = MathAbs(priceVelocity) / MathMax(MathAbs(peakVelocity), 0.1);
      velocityMultiplier = 1.0 + (VelocityTrailingMultiplier - 1.0) * velocityRatio;
   }
   else
   {
      // Low velocity - use tighter trailing stop (smaller multiplier)
      velocityMultiplier = 0.7;  // 30% tighter when velocity is low
   }
   
   double adjustedTrailingStep = baseTrailingStep * velocityMultiplier;
   double trailingStopLevel = basketMaxProfitUSD - adjustedTrailingStep;
   
   return trailingStopLevel;
}

// Check if velocity indicates we should extend hold time
bool ShouldExtendHoldTime()
{
   if(!UseVelocityExits)
      return false;
   
   // If velocity is accelerating favorably (positive and increasing), extend hold time
   if(priceVelocityCount >= 2 && priceVelocity > MinVelocityForHold)
   {
      // Check if velocity is increasing (accelerating)
      if(priceVelocityCount >= 2)
      {
         double currentVel = priceVelocity;
         double previousVel = priceVelocityHistory[priceVelocityCount - 2];
         
         // If velocity is positive and increasing, extend hold
         if(currentVel > previousVel && currentVel > MinVelocityForHold)
            return true;
      }
   }
   
   return false;
}

// =====================================================================================================
// BASKET MANAGEMENT (EXIT LOGIC)
// =====================================================================================================

void ManageBasket()
{
   if(OpenTradesCount() == 0)
      return;
   
   // Calculate basket total profit
   basketTotalProfitUSD = CalculateBasketProfit();
   
   // ===== PHASE 1: SCALP PROTECTION =====
   if(basketOpenTimeMS > 0)
   {
      ulong currentTimeMS = GetTickCount64();
      ulong elapsedMS = currentTimeMS - basketOpenTimeMS;
      
      if(elapsedMS < (ulong)MinHoldMilliseconds)
      {
         return;  // Too early - prevent any exits during scalp protection period
      }
   }
   
   // ===== PHASE 2: BASKET CONFIRMATION =====
   bool basketConfirmed = (basketTotalProfitUSD >= BasketConfirmUSD);
   
   // ===== TIME-BASED PROFIT EXIT =====
   if(basketTotalProfitUSD > 0.0 && basketOpenTimeMS > 0)
   {
      ulong currentTimeMS = GetTickCount64();
      ulong elapsedMS = currentTimeMS - basketOpenTimeMS;
      ulong elapsedSeconds = elapsedMS / 1000;
      
      // Check if velocity indicates we should extend hold time
      bool extendHold = ShouldExtendHoldTime();
      
      if(elapsedSeconds >= (ulong)BasketMaxHoldSeconds && !extendHold)
      {
         DelayExecution();
         CloseAllBasketTrades();
         Print("BASKET CLOSED: Maximum hold time reached | Profit: $", DoubleToString(basketTotalProfitUSD, 2), 
               " | Hold Time: ", IntegerToString(elapsedSeconds), " seconds");
         return;
      }
   }
   
   // ===== BASKET TRAILING STOP =====
   if(UseBasketTrailingStop && basketTotalProfitUSD > 0.0)
   {
      // Update maximum profit seen
      if(basketTotalProfitUSD > basketMaxProfitUSD)
      {
         basketMaxProfitUSD = basketTotalProfitUSD;
      }
      
      // Check if profit has dropped by trailing step from peak
      if(basketMaxProfitUSD >= BasketTrailingStartUSD)
      {
         // Use velocity-adjusted trailing stop if enabled, otherwise use fixed trailing stop
         double trailingStopLevel = 0.0;
         
         if(UseVelocityExits)
         {
            trailingStopLevel = GetVelocityAdjustedTrailingStop();
            if(trailingStopLevel == 0.0)  // Fallback to fixed if velocity-adjusted returns 0
               trailingStopLevel = basketMaxProfitUSD - BasketTrailingStepUSD;
         }
         else
         {
            trailingStopLevel = basketMaxProfitUSD - BasketTrailingStepUSD;
         }
         
         if(basketTotalProfitUSD <= trailingStopLevel)
         {
            DelayExecution();
            CloseAllBasketTrades();
            Print("BASKET CLOSED: Trailing stop hit | Profit: $", DoubleToString(basketTotalProfitUSD, 2), 
                  " | Peak: $", DoubleToString(basketMaxProfitUSD, 2), 
                  " | Trailing Level: $", DoubleToString(trailingStopLevel, 2));
            return;
         }
      }
   }
   
   // ===== INVALIDATION RULE 1: Momentum Flip Invalidation =====
   // Only allow invalidation if basket is confirmed OR basket is deeply negative
   if(basketConfirmed || basketTotalProfitUSD < -BasketConfirmUSD)
   {
      if(basketTotalProfitUSD < 0.0 && basketEntryDirection != 0)
      {
         if(momentumFlipCount >= 2)
         {
            DelayExecution();
            CloseAllBasketTrades();
            Print("BASKET INVALIDATED: Momentum flipped twice | Flips: ", momentumFlipCount, 
                  " | Loss: $", DoubleToString(basketTotalProfitUSD, 2));
            return;
         }
      }
   }
   
   // ===== INVALIDATION RULE 2: Breakout Failure Invalidation =====
   // Only allow invalidation if basket is confirmed OR basket is deeply negative
   if(basketConfirmed || basketTotalProfitUSD < -BasketConfirmUSD)
   {
      if(basketTotalProfitUSD < 0.0 && breakoutOriginPrice > 0.0)
      {
         double midPrice = (currentBid + currentAsk) / 2.0;
         bool breakoutFailed = false;
         
         if(basketEntryDirection == 1)  // BUY basket
         {
            // Breakout failed if price returns below origin
            if(midPrice < breakoutOriginPrice)
            {
               breakoutFailed = true;
            }
         }
         else if(basketEntryDirection == -1)  // SELL basket
         {
            // Breakout failed if price returns above origin
            if(midPrice > breakoutOriginPrice)
            {
               breakoutFailed = true;
            }
         }
         
         if(breakoutFailed)
         {
            DelayExecution();
            CloseAllBasketTrades();
            Print("BASKET INVALIDATED: Breakout failure | Price returned to origin | Origin: ", 
                  DoubleToString(breakoutOriginPrice, symbolDigits), " | Current: ", 
                  DoubleToString(midPrice, symbolDigits), " | Loss: $", 
                  DoubleToString(basketTotalProfitUSD, 2));
            return;
         }
      }
   }
   
   // ===== VELOCITY-BASED EXITS (Before Fixed Profit Target) =====
   if(UseVelocityExits)
   {
      if(CheckVelocityExits())
      {
         return;  // Basket was closed by velocity exit
      }
   }
   
   // Basket Take Profit (PRIMARY EXIT)
   double basketTargetUSD = basketStartEquity * (BasketProfitPercent / 100.0);
   
   if(basketTotalProfitUSD >= (basketTargetUSD + BasketCloseBufferUSD))
   {
      DelayExecution();
      CloseAllBasketTrades();
      Print("BASKET CLOSED: Take Profit reached | Profit: $", DoubleToString(basketTotalProfitUSD, 2), 
            " | Target: $", DoubleToString(basketTargetUSD, 2));
      return;
   }
   
   // Basket Stop Loss (EQUITY-BASED ONLY)
   double basketLossLimitUSD = basketStartEquity * (BasketMaxLossPercent / 100.0);
   
   if(basketTotalProfitUSD <= -basketLossLimitUSD)
   {
      DelayExecution();
      CloseAllBasketTrades();
      Print("BASKET CLOSED: Stop Loss reached | Loss: $", DoubleToString(basketTotalProfitUSD, 2), 
            " | Limit: $", DoubleToString(basketLossLimitUSD, 2));
      return;
   }
}

// =====================================================================================================
// DISPLAY
// =====================================================================================================

void UpdateDisplay()
{
   string status = "\n=== Hyperactive HFT MT5 Scalper V2A.00 - BASKET MOMENTUM ===\n";
   status += "Symbol: " + tradeSymbol + "\n";
   status += "Lot Mode: " + (UseFixedLot ? "FIXED" : "DYNAMIC") + "\n";
   if(UseFixedLot)
      status += "Lot Size: " + DoubleToString(TradeLot, 2) + "\n";
   else
      status += "Dynamic Lot: " + DoubleToString(CalculateLotSize(), 2) + "\n";
   
   status += "Tick Speed: " + DoubleToString(ticksPerSecond, 2) + " ticks/sec";
   if(UseTickSpeedFilter && ticksPerSecond < MinTickSpeed)
      status += " [LOW]";
   status += "\n";
   
   status += "Spread: " + DoubleToString(currentSpread, 1) + " points";
   if(currentSpread > MaxSpreadPoints)
      status += " [HIGH]";
   if(UseSpreadNormalizedFilter && averageSpread > 0.0)
   {
      status += " (Avg: " + DoubleToString(averageSpread, 1);
      if(currentSpread > (averageSpread * SpreadMultiplier))
         status += " [SPIKE]";
      status += ")";
   }
   status += "\n";
   
   status += "Momentum: " + (momentumDirection == 1 ? "BULLISH" : (momentumDirection == -1 ? "BEARISH" : "NEUTRAL"));
   status += " (" + IntegerToString(consecutiveMomentumTicks) + " ticks)\n";
   
   // Show filter statuses
   if(UsePullbackFilter && breakoutDetected)
   {
      status += "Breakout: " + (breakoutDirection == 1 ? "BULLISH" : "BEARISH");
      status += " | Peak: " + DoubleToString(breakoutPeakPrice, symbolDigits);
      status += " | Waiting for pullback...\n";
   }
   
   if(UseVolatilityCycleFilter)
   {
      status += "Volatility Cycle: " + (CheckVolatilityCycle() ? "RISING" : "NOT RISING") + "\n";
   }
   
   if(UseLiquidityTimeFilter)
   {
      status += "Liquidity Time: " + (CheckLiquidityTime() ? "ALLOWED" : "BLOCKED") + "\n";
   }
   
   if(tradingStopped)
   {
      status += "\nSTATUS: TRADING STOPPED\n";
      if(UseDrawdownProtection)
      {
         double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         double drawdown = ((highestBalance - currentEquity) / highestBalance) * 100.0;
         status += "Drawdown: " + DoubleToString(drawdown, 2) + "%\n";
      }
   }
   else
   {
      status += "STATUS: ACTIVE\n";
   }
   
   int basketCount = OpenTradesCount();
   if(basketCount > 0)
   {
      status += "\n--- Basket Status ---\n";
      status += "Open Trades: " + IntegerToString(basketCount) + " / " + IntegerToString(MaxBasketTrades) + "\n";
      status += "Basket Profit: $" + DoubleToString(basketTotalProfitUSD, 2) + "\n";
      
      if(basketStartEquity > 0.0)
      {
         double basketTargetUSD = basketStartEquity * (BasketProfitPercent / 100.0);
         double basketLossLimitUSD = basketStartEquity * (BasketMaxLossPercent / 100.0);
         status += "Basket TP: $" + DoubleToString(basketTargetUSD, 2) + " (" + DoubleToString(BasketProfitPercent, 1) + "%)\n";
         status += "Basket SL: $" + DoubleToString(basketLossLimitUSD, 2) + " (" + DoubleToString(BasketMaxLossPercent, 1) + "%)\n";
         status += "Start Equity: $" + DoubleToString(basketStartEquity, 2) + "\n";
      }
      
      // Show direction
      int basketDir = GetExistingBasketDirection();
      if(basketDir != 0)
      {
         status += "Direction: " + (basketDir == 1 ? "BUY" : "SELL") + "\n";
      }
      
      // Show velocity information
      if(UseVelocityExits && velocityTrackingActive)
      {
         status += "\n--- Velocity Status ---\n";
         status += "Current Velocity: " + DoubleToString(priceVelocity, 3) + " pts/sec";
         if(priceVelocity > 0)
            status += " [FAVORABLE]";
         else if(priceVelocity < 0)
            status += " [UNFAVORABLE]";
         status += "\n";
         status += "Peak Velocity: " + DoubleToString(peakVelocity, 3) + " pts/sec\n";
         status += "Samples: " + IntegerToString(priceVelocityCount) + "\n";
         
         // Show velocity trend
         if(priceVelocityCount >= 2)
         {
            double prevVel = priceVelocityHistory[priceVelocityCount - 2];
            if(priceVelocity > prevVel)
               status += "Trend: ACCELERATING\n";
            else if(priceVelocity < prevVel)
               status += "Trend: DECELERATING\n";
            else
               status += "Trend: STABLE\n";
         }
      }
   }
   else
   {
      status += "\nNo basket trades\n";
      status += "Waiting for momentum breakout signal...\n";
   }
   
   status += "\n--- Account ---\n";
   status += "Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n";
   status += "Equity: $" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\n";
   if(DailyProfitTarget > 0.0)
   {
      status += "Daily Profit: $" + DoubleToString(dailyProfit, 2);
      status += " / $" + DoubleToString(DailyProfitTarget, 2) + "\n";
   }
   
   Comment(status);
}

