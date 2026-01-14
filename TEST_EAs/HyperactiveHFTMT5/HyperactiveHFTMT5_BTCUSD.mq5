#property copyright "Copyright 2025, Hyperactive HFT MT5 Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "2.10"

#include <Trade/Trade.mqh>

CTrade trade;

// =====================================================================================================
// HYPERACTIVE HFT MT5 SCALPER V2.1
// Strategy: Momentum breakout with information-based exits
// 
// EXIT PHILOSOPHY: Entry=fast, Exit=slow, Loss=quick, Profit=patient
// 
// Unified Exit Controller (evaluated in order):
// 1. Hard Max Loss (safety cap - non-negotiable)
// 2. Momentum Invalidation (market proves you wrong, not time)
// 3. Velocity Decay (exit when momentum dies, not when profit appears)
// 4. Trailing Stop (profit protection after meaningful move)
//
// Features:
// - Multiple simultaneous trades (1-5)
// - Momentum breakout entry with filters
// - No time-based exits - information-based only
// - Asymmetric loss protection (realistic caps)
// =====================================================================================================

// ===== Core Trading Settings =====
input group "===== Core Trading Settings ====="
input int      MagicNumber         = 202510;
input string   TradeSymbol         = "";      // Symbol to trade (empty = current chart symbol)
input bool     UseFixedLot         = true;     // Use fixed lot size (false = dynamic)
input double   FixedLotSize        = 0.1;      // Fixed lot size (if UseFixedLot = true)
input double   DynamicLotBase     = 0.05;     // Base lot for dynamic sizing
input double   DynamicLotMultiplier = 1.2;    // Multiplier for dynamic lot (based on balance)
input double   MaxLotSize          = 1.00;     // Maximum lot size (safety limit)
input double   MinLotSize          = 0.01;     // Minimum lot size (safety limit)
input int      MaxSimultaneousTrades = 1;     // Maximum simultaneous trades (1-5)

// ===== Entry Settings =====
input group "===== Momentum Breakout Entry ====="
input int      MomentumPeriod      = 18;       // Period for momentum calculation (ticks) - Reduced from 30 for more opportunities
input double   BreakoutThreshold   = 50.0;     // Minimum price movement for breakout (BTCUSD: ~$50 move)
input int      MinTickSpeed        = 3;        // Minimum ticks per second for entry (reduced from 5)
input bool     UseTickSpeedFilter  = true;     // Enable tick speed filter
input double   StrongBreakoutMultiplier = 1.8; // Enter immediately if breakout >= threshold * multiplier (bypass pullback)

// ===== Unified Exit Settings =====
input group "===== Hard Loss Protection ====="
input double   MaxLossPoints       = 5000.0;   // Maximum loss in points (BTCUSD: ~$50 on 0.01 lot)
input bool     UseStopLoss         = false;    // Use hard stop loss on broker side

input group "===== Momentum Invalidation Exit ====="
input int      MomentumFlipsToExit = 2;        // Exit unprofitable trade after N momentum flips against
input bool     ExitProfitableOnFlip = false;   // DISABLED: Exit if was profitable and momentum flips against
input int      FlipConfirmationTicks = 2;      // Ticks to confirm momentum flip (prevents noise)
input int      MinTradeMaturitySeconds = 8;    // No exits (except hard loss) before trade matures

input group "===== Velocity Decay Exit ====="
input double   VelocityDecayRatio  = 0.6;      // Exit when tick speed < peak * this ratio
input double   VelocityDecayMinProfit = 2000.0; // Minimum profit points before velocity decay (BTCUSD)

input group "===== Trailing Stop Settings ====="
input bool     UseTrailingStop     = true;     // Use trailing stop loss
input double   TrailingStartPoints = 3000.0;   // Start trailing after X points profit (BTCUSD)
input double   TrailingStepPoints  = 1500.0;   // Trailing step in points (BTCUSD)

// ===== Spread & Slippage =====
input group "===== Spread & Execution ====="
input double   MaxSpreadPoints     = 50000.0;  // Maximum spread in points (BTCUSD has wider spreads)
input int      MaxSlippagePoints   = 300;      // Maximum slippage in points
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
input double   PullbackPoints     = 200.0;      // Retrace points after breakout (BTCUSD)
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
input bool     UseDynamicBreakeven = true;      // Enable dynamic breakeven
input double   BreakevenTriggerPoints = 1000.0; // Move SL when profit > X points (BTCUSD)
input double   BreakevenOffsetPoints = 300.0;   // Move SL to entry - X points (BTCUSD)

// ===== Trade Cooldown =====
input group "===== Trade Cooldown ====="
input int      TradeCooldownSeconds = 60;       // Wait N seconds after closing before new trade


// =====================================================================================================
// STRUCTURES & GLOBALS
// =====================================================================================================

struct TradeInfo {
   ulong    ticket;
   double   entryPrice;
   datetime openTime;
   int      direction;  // 1=BUY, -1=SELL
   double   lotSize;
   double   highestProfitPoints;  // Track highest profit for trailing
   bool     wasProfitable;  // Track if trade was ever profitable
   bool     breakevenMoved;  // Track if breakeven has been moved
   double   peakTickSpeed;  // Track peak tick speed during trade
   int      momentumFlipCount;  // Count confirmed momentum flips against trade
   int      lastMomentumDir;  // Last confirmed momentum direction
   int      pendingFlipDir;  // Direction of pending unconfirmed flip
   int      pendingFlipTicks;  // Ticks pending flip has been sustained
};

TradeInfo activeTrades[5];
int activeTradeCount = 0;
int maxTrades = 1;  // Will be set from input in OnInit()

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
double effectiveMaxLoss = 50.0;  // Symbol-aware max loss (set in OnInit)
double effectiveVelocityMinProfit = 25.0;  // Symbol-aware velocity decay floor (set in OnInit)

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

// Trade cooldown
datetime lastTradeCloseTime = 0;
int tradeCooldownSeconds = 60;  // Wait 60 seconds after closing before new trade

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("Hyperactive HFT MT5 Scalper V2.00");
   Print("Ultra-fast momentum breakout scalping with advanced filters");
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
   
   // Validate and set max trades (clamp between 1 and 5)
   maxTrades = MaxSimultaneousTrades;
   if(maxTrades < 1) maxTrades = 1;
   if(maxTrades > 5) maxTrades = 5;
   
   // Symbol-aware max loss: Different assets need different stops
   if(StringFind(tradeSymbol, "BTC") >= 0 || StringFind(tradeSymbol, "BITCOIN") >= 0)
   {
      // BTCUSD: Very wide stops needed due to high volatility
      effectiveMaxLoss = 5000.0;  // ~$50 on 0.01 lot
      effectiveVelocityMinProfit = 2000.0;
   }
   else if(StringFind(tradeSymbol, "XAU") >= 0 || StringFind(tradeSymbol, "GOLD") >= 0)
   {
      effectiveMaxLoss = 65.0;
      effectiveVelocityMinProfit = 40.0;
   }
   else
   {
      effectiveMaxLoss = 35.0;
      effectiveVelocityMinProfit = 25.0;
   }
   
   // Override with user input if specified higher
   if(MaxLossPoints > effectiveMaxLoss)
      effectiveMaxLoss = MaxLossPoints;
   if(VelocityDecayMinProfit > effectiveVelocityMinProfit)
      effectiveVelocityMinProfit = VelocityDecayMinProfit;
   
   // Initialize trading state
   activeTradeCount = 0;
   for(int i = 0; i < 5; i++)
   {
      activeTrades[i].ticket = 0;
   }
   
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
   
   // Initialize cooldown
   lastTradeCloseTime = 0;
   tradeCooldownSeconds = TradeCooldownSeconds;
   
   Print("Trade Symbol: ", tradeSymbol);
   Print("Lot Mode: ", (UseFixedLot ? "FIXED" : "DYNAMIC"));
   Print("Fixed Lot: ", FixedLotSize);
   Print("Max Loss Points: ", effectiveMaxLoss, " (symbol-aware)");
   Print("Velocity Decay Ratio: ", VelocityDecayRatio);
   Print("Momentum Flips to Exit: ", MomentumFlipsToExit);
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("Hyperactive HFT MT5 Scalper deinitialized. Reason: ", reason);
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
   
   if(tradingStopped)
   {
      UpdateDisplay();
      return;
   }
   
   // Manage active trades
   if(activeTradeCount > 0)
   {
      ManageTrade();
   }
   
   // Look for new entry if we can take more trades
   if(activeTradeCount < maxTrades && !tradingStopped)
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
         
         // Close all open trades
         CloseAllTrades("Drawdown limit reached");
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
         
         CloseAllTrades("Daily profit target reached");
      }
   }
}

void CloseAllTrades(string reason)
{
   for(int i = activeTradeCount - 1; i >= 0; i--)
   {
      CloseTrade(i, reason);
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
            // Check for strong breakout - enter immediately if momentum is very strong
            double strongBreakoutThreshold = breakoutThreshold * StrongBreakoutMultiplier;
            bool isStrongBreakout = (priceChange >= strongBreakoutThreshold && consecutiveMomentumTicks >= 2);
            
            if(isStrongBreakout)
            {
               // Strong breakout - enter immediately (sniper entry on strong momentum)
               breakoutDetected = false;  // Reset any pending pullback
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
                     return 1;  // BUY
                  }
                  
                  return 0;  // Still waiting for pullback
               }
            }
            else
            {
               // No pullback filter, enter immediately
               return 1;  // BUY
            }
         }
      }
      else if(momentumDirection == -1 && priceChange <= -breakoutThreshold)
      {
         // Bearish breakout detected
         if(consecutiveMomentumTicks >= 1)  // Reduced from 2 to 1 for more entries
         {
            // Check for strong breakout - enter immediately if momentum is very strong
            double strongBreakoutThreshold = breakoutThreshold * StrongBreakoutMultiplier;
            bool isStrongBreakout = (priceChange <= -strongBreakoutThreshold && consecutiveMomentumTicks >= 2);
            
            if(isStrongBreakout)
            {
               // Strong breakout - enter immediately (sniper entry on strong momentum)
               breakoutDetected = false;  // Reset any pending pullback
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
                     return -1;  // SELL
                  }
                  
                  return 0;  // Still waiting for pullback
               }
            }
            else
            {
               // No pullback filter, enter immediately
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
   // Check if we can open more trades
   if(activeTradeCount >= maxTrades)
      return false;
   
   // Check if trading is stopped
   if(tradingStopped)
      return false;
   
   // Check cooldown after last trade close
   if(lastTradeCloseTime > 0 && (TimeCurrent() - lastTradeCloseTime) < tradeCooldownSeconds)
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
   
   // Multi-trade mode requires stronger momentum confirmation to avoid noise stacking
   if(maxTrades > 1)
   {
      if(consecutiveMomentumTicks < 2)
         return false;
      if(ticksPerSecond < MinTickSpeed * 1.2)
         return false;
   }
   
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
      lotSize = FixedLotSize;
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
   
   if(activeTradeCount >= maxTrades)
      return false;
   
   double lotSize = CalculateLotSize();
   double price = (direction == 1) ? currentAsk : currentBid;
   
   // Calculate stop loss
   double sl = 0.0;
   if(UseStopLoss)
   {
      if(direction == 1)  // BUY
         sl = price - (effectiveMaxLoss * point);
      else  // SELL
         sl = price + (effectiveMaxLoss * point);
      
      sl = NormalizeDouble(sl, symbolDigits);
   }
   
   // No take profit (using dynamic exit)
   double tp = 0.0;
   
   string comment = "HyperHFT_" + (direction == 1 ? "BUY" : "SELL");
   
   ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
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
      // Get position ticket
      ulong ticket = 0;
      if(trade.ResultDeal() > 0)
      {
         if(HistoryDealSelect(trade.ResultDeal()))
         {
            ticket = HistoryDealGetInteger(trade.ResultDeal(), DEAL_POSITION_ID);
         }
      }
      
      // If still no ticket, find position by symbol and magic
      if(ticket == 0)
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong posTicket = PositionGetTicket(i);
            if(posTicket > 0 && PositionSelectByTicket(posTicket))
            {
               if(PositionGetString(POSITION_SYMBOL) == tradeSymbol && 
                  PositionGetInteger(POSITION_MAGIC) == MagicNumber)
               {
                  ticket = posTicket;
                  break;
               }
            }
         }
      }
      
      if(ticket > 0)
      {
         double actualEntryPrice = price;
         if(PositionSelectByTicket(ticket))
         {
            actualEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         }
         
         // Store trade in array
         activeTrades[activeTradeCount].ticket = ticket;
         activeTrades[activeTradeCount].entryPrice = actualEntryPrice;
         activeTrades[activeTradeCount].openTime = TimeCurrent();
         activeTrades[activeTradeCount].direction = direction;
         activeTrades[activeTradeCount].lotSize = lotSize;
         activeTrades[activeTradeCount].highestProfitPoints = 0.0;
         activeTrades[activeTradeCount].wasProfitable = false;
         activeTrades[activeTradeCount].breakevenMoved = false;
         activeTrades[activeTradeCount].peakTickSpeed = MathMax(ticksPerSecond, (double)MinTickSpeed);  // Avoid entry spike causing early velocity decay
         activeTrades[activeTradeCount].momentumFlipCount = 0;
         activeTrades[activeTradeCount].lastMomentumDir = momentumDirection;  // Use actual momentum, not trade direction
         activeTrades[activeTradeCount].pendingFlipDir = 0;
         activeTrades[activeTradeCount].pendingFlipTicks = 0;
         activeTradeCount++;
         
         // Reset breakout tracking when trade opens
         breakoutDetected = false;
         breakoutPeakPrice = 0.0;
         breakoutDirection = 0;
         breakoutTime = 0;
         
         Print("TRADE OPENED: ", (direction == 1 ? "BUY" : "SELL"), 
               " | Lot: ", lotSize, " | Price: ", actualEntryPrice, " | SL: ", sl,
               " | Active trades: ", activeTradeCount);
         return true;
      }
   }
   else
   {
      Print("Trade open failed: ", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
   }
   
   return false;
}

// =====================================================================================================
// MANAGE TRADE (EXIT LOGIC)
// =====================================================================================================

void ManageTrade()
{
   if(activeTradeCount == 0)
      return;
   
   // Loop through all active trades (in reverse to handle removals)
   for(int i = activeTradeCount - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket == 0)
         continue;
      
      if(!PositionSelectByTicket(activeTrades[i].ticket))
      {
         // Position closed externally - remove from array
         RemoveTrade(i);
         continue;
      }
      
      // Get current position data
      double positionProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      
      // Calculate hold time for maturity check
      int holdSeconds = (int)(TimeCurrent() - activeTrades[i].openTime);
      
      // Calculate profit/loss in points
      double currentPrice = (activeTrades[i].direction == 1) ? currentBid : currentAsk;
      double priceDiff = currentPrice - activeTrades[i].entryPrice;
      if(activeTrades[i].direction == -1)
         priceDiff = -priceDiff;  // For SELL, reverse the difference
      
      double profitPoints = priceDiff / point;
      double lossPoints = (profitPoints < 0) ? MathAbs(profitPoints) : 0.0;
      
      // Update highest profit tracking
      if(profitPoints > activeTrades[i].highestProfitPoints)
      {
         activeTrades[i].highestProfitPoints = profitPoints;
         if(profitPoints > 0.0)
            activeTrades[i].wasProfitable = true;
      }
      
      // Update peak tick speed tracking
      if(ticksPerSecond > activeTrades[i].peakTickSpeed)
         activeTrades[i].peakTickSpeed = ticksPerSecond;
      
      // Calculate EXIT MOMENTUM based on price displacement (NOT tick direction)
      // This prevents noisy tick-to-tick exits
      int exitMomentumDir = 0;
      if(tickBufferReady && tickIndex >= 5)
      {
         double exitMomentum = tickPrices[0] - tickPrices[5];
         double exitThreshold = BreakoutThreshold * 0.3;
         if(exitMomentum > exitThreshold) exitMomentumDir = 1;
         else if(exitMomentum < -exitThreshold) exitMomentumDir = -1;
      }
      
      // Track momentum flips using EXIT MOMENTUM (price displacement, not ticks)
      if(exitMomentumDir != 0)
      {
         // Check if exit momentum is against our trade
         bool isAgainstTrade = (activeTrades[i].direction == 1 && exitMomentumDir == -1) ||
                               (activeTrades[i].direction == -1 && exitMomentumDir == 1);
         
         if(isAgainstTrade && exitMomentumDir != activeTrades[i].lastMomentumDir)
         {
            // Potential flip detected - start or continue confirmation
            if(activeTrades[i].pendingFlipDir == exitMomentumDir)
            {
               // Same pending direction - increment confirmation counter
               activeTrades[i].pendingFlipTicks++;
               if(activeTrades[i].pendingFlipTicks >= FlipConfirmationTicks)
               {
                  // Flip confirmed after sustained ticks
                  activeTrades[i].momentumFlipCount++;
                  activeTrades[i].lastMomentumDir = exitMomentumDir;
                  activeTrades[i].pendingFlipDir = 0;
                  activeTrades[i].pendingFlipTicks = 0;
               }
            }
            else
            {
               // New potential flip direction - start confirmation
               activeTrades[i].pendingFlipDir = exitMomentumDir;
               activeTrades[i].pendingFlipTicks = 1;
            }
         }
         else if(!isAgainstTrade)
         {
            // Exit momentum is with our trade - reset pending flip
            activeTrades[i].pendingFlipDir = 0;
            activeTrades[i].pendingFlipTicks = 0;
            activeTrades[i].lastMomentumDir = exitMomentumDir;
            
            // Reset flip count when momentum aligns AND we're profitable (no ghost flips)
            if(profitPoints > 0)
               activeTrades[i].momentumFlipCount = 0;
         }
      }
      
      // =====================================================================
      // UNIFIED EXIT CONTROLLER - Evaluated in strict order
      // =====================================================================
      
      // ---------------------------------------------------------------------
      // EXIT 1: Hard Max Loss (Safety - non-negotiable, symbol-aware)
      // This is the ONLY exit allowed before trade maturity
      // ---------------------------------------------------------------------
      if(lossPoints >= effectiveMaxLoss)
      {
         CloseTrade(i, "Hard stop loss (" + DoubleToString(lossPoints, 1) + "/" + DoubleToString(effectiveMaxLoss, 0) + " pts)");
         continue;
      }
      
      // ---------------------------------------------------------------------
      // MATURITY GUARD: No other exits until trade has time to develop
      // This is protection, not time-based exit
      // ---------------------------------------------------------------------
      if(holdSeconds < MinTradeMaturitySeconds)
         continue;
      
      // ---------------------------------------------------------------------
      // EXIT 2: Momentum Invalidation
      // "Exit when the market proves you wrong, not when time runs out"
      // ---------------------------------------------------------------------
      if(ExitProfitableOnFlip && activeTrades[i].wasProfitable && activeTrades[i].momentumFlipCount >= 1)
      {
         // Was profitable, momentum flipped against us - market proved us wrong
         CloseTrade(i, "Momentum invalidation (was profitable, flip count: " + IntegerToString(activeTrades[i].momentumFlipCount) + ")");
         continue;
      }
      
      if(!activeTrades[i].wasProfitable && activeTrades[i].momentumFlipCount >= MomentumFlipsToExit)
      {
         // Never profitable and momentum flipped against us multiple times
         CloseTrade(i, "Momentum invalidation (never profitable, flip count: " + IntegerToString(activeTrades[i].momentumFlipCount) + ")");
         continue;
      }
      
      // ---------------------------------------------------------------------
      // EXIT 3: Velocity Decay (Profit exit based on momentum dying)
      // Requires: meaningful profit floor AND tick speed actually slow
      // ---------------------------------------------------------------------
      if(profitPoints >= effectiveVelocityMinProfit && activeTrades[i].peakTickSpeed > 0)
      {
         double velocityRatio = ticksPerSecond / activeTrades[i].peakTickSpeed;
         // Only exit if velocity is low AND tick speed is below minimum (true momentum death)
         if(velocityRatio < VelocityDecayRatio && ticksPerSecond < MinTickSpeed)
         {
            CloseTrade(i, "Velocity decay (speed ratio: " + DoubleToString(velocityRatio, 2) + ", profit: " + DoubleToString(profitPoints, 1) + ")");
            continue;
         }
      }
      
      // ---------------------------------------------------------------------
      // PROTECTION: Dynamic Breakeven (not exit, just SL adjustment)
      // ---------------------------------------------------------------------
      if(UseDynamicBreakeven && !activeTrades[i].breakevenMoved && profitPoints >= BreakevenTriggerPoints)
      {
         MoveToBreakeven(i);
      }
      
      // ---------------------------------------------------------------------
      // PROTECTION: Trailing Stop (profit protection, never primary exit)
      // Uses price retrace from peak, not profit delta
      // ---------------------------------------------------------------------
      if(UseTrailingStop && activeTrades[i].highestProfitPoints >= TrailingStartPoints)
      {
         // Trailing only allowed when velocity is declining (protection mode)
         if(activeTrades[i].wasProfitable && activeTrades[i].peakTickSpeed > ticksPerSecond)
         {
            // Calculate retrace from peak (not absolute level)
            double trailFromPeak = activeTrades[i].highestProfitPoints - profitPoints;
            if(trailFromPeak >= TrailingStepPoints)
            {
               CloseTrade(i, "Trailing stop (retrace: " + DoubleToString(trailFromPeak, 1) + " >= " + DoubleToString(TrailingStepPoints, 1) + ")");
               continue;
            }
         }
      }
   }
}

// =====================================================================================================
// MOVE TO BREAKEVEN
// =====================================================================================================

void MoveToBreakeven(int tradeIndex)
{
   if(tradeIndex < 0 || tradeIndex >= activeTradeCount)
      return;
   
   if(activeTrades[tradeIndex].ticket == 0)
      return;
   
   if(!PositionSelectByTicket(activeTrades[tradeIndex].ticket))
      return;
   
   double newSL = 0.0;
   
   if(activeTrades[tradeIndex].direction == 1)  // BUY
   {
      newSL = activeTrades[tradeIndex].entryPrice - (BreakevenOffsetPoints * point);
   }
   else  // SELL
   {
      newSL = activeTrades[tradeIndex].entryPrice + (BreakevenOffsetPoints * point);
   }
   
   newSL = NormalizeDouble(newSL, symbolDigits);
   
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   
   // Only modify if new SL is better than current (closer to entry for profit protection)
   bool shouldModify = false;
   if(activeTrades[tradeIndex].direction == 1)  // BUY
   {
      shouldModify = (currentSL == 0.0 || newSL > currentSL);
   }
   else  // SELL
   {
      shouldModify = (currentSL == 0.0 || newSL < currentSL);
   }
   
   if(shouldModify)
   {
      if(trade.PositionModify(activeTrades[tradeIndex].ticket, newSL, currentTP))
      {
         activeTrades[tradeIndex].breakevenMoved = true;
         Print("Breakeven moved: SL set to ", DoubleToString(newSL, symbolDigits), " (entry - ", BreakevenOffsetPoints, " points)");
      }
   }
}

// =====================================================================================================
// CLOSE TRADE
// =====================================================================================================

void CloseTrade(int tradeIndex, string reason)
{
   if(tradeIndex < 0 || tradeIndex >= activeTradeCount)
      return;
   
   if(activeTrades[tradeIndex].ticket == 0)
      return;
   
   if(!PositionSelectByTicket(activeTrades[tradeIndex].ticket))
   {
      RemoveTrade(tradeIndex);
      return;
   }
   
   double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   
   bool closed = trade.PositionClose(activeTrades[tradeIndex].ticket);
   
   if(closed)
   {
      Print("TRADE CLOSED: ", reason, " | P&L: $", DoubleToString(profit, 2), " | Remaining trades: ", activeTradeCount - 1);
      
      // Set cooldown timer
      lastTradeCloseTime = TimeCurrent();
      
      // Daily profit calculated dynamically from balance - no manual tracking
      RemoveTrade(tradeIndex);
   }
   else
   {
      Print("Close failed: ", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
   }
}

void RemoveTrade(int tradeIndex)
{
   // Shift remaining trades down
   for(int i = tradeIndex; i < activeTradeCount - 1; i++)
   {
      activeTrades[i] = activeTrades[i + 1];
   }
   activeTradeCount--;
   
   // Clear the last slot
   if(activeTradeCount >= 0 && activeTradeCount < 5)
   {
      activeTrades[activeTradeCount].ticket = 0;
   }
}

// =====================================================================================================
// DISPLAY
// =====================================================================================================

void UpdateDisplay()
{
   string status = "\n=== Hyperactive HFT MT5 Scalper V2.00 ===\n";
   status += "Symbol: " + tradeSymbol + "\n";
   status += "Lot Mode: " + (UseFixedLot ? "FIXED" : "DYNAMIC") + "\n";
   if(UseFixedLot)
      status += "Lot Size: " + DoubleToString(FixedLotSize, 2) + "\n";
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
   
   status += "\n--- Active Trades: " + IntegerToString(activeTradeCount) + "/" + IntegerToString(maxTrades) + " ---\n";
   
   if(activeTradeCount > 0)
   {
      for(int i = 0; i < activeTradeCount; i++)
      {
         if(PositionSelectByTicket(activeTrades[i].ticket))
         {
            double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            int holdSeconds = (int)(TimeCurrent() - openTime);
            
            double currentPrice = (activeTrades[i].direction == 1) ? currentBid : currentAsk;
            double priceDiff = currentPrice - activeTrades[i].entryPrice;
            if(activeTrades[i].direction == -1)
               priceDiff = -priceDiff;
            double profitPoints = priceDiff / point;
            
            double velocityRatio = (activeTrades[i].peakTickSpeed > 0) ? (ticksPerSecond / activeTrades[i].peakTickSpeed) : 1.0;
            
            status += "[" + IntegerToString(i+1) + "] " + (activeTrades[i].direction == 1 ? "BUY" : "SELL");
            status += " | $" + DoubleToString(profit, 2);
            status += " | " + DoubleToString(profitPoints, 1) + " pts";
            status += " | " + IntegerToString(holdSeconds) + "s";
            status += "\n    Flips:" + IntegerToString(activeTrades[i].momentumFlipCount);
            status += " | Vel:" + DoubleToString(velocityRatio, 2);
            if(activeTrades[i].wasProfitable) status += " [WasProfit]";
            if(activeTrades[i].breakevenMoved) status += " [BE]";
            status += "\n";
         }
      }
   }
   else
   {
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

