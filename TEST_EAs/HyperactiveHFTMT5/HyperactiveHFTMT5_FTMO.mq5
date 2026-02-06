#property copyright "Copyright 2025, Hyperactive HFT MT5 Scalper FTMO"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "3.10"

#include <Trade/Trade.mqh>

CTrade trade;

// =====================================================================================================
// HYPERACTIVE HFT MT5 SCALPER - FTMO EDITION (Optimized for 8% Daily Profit)
// Strategy: FULLY REVERSED - Mean reversion scalping (counter-trend)
// - REVERSED SIGNALS: Bullish patterns -> SELL, Bearish patterns -> BUY
// - REVERSED ENTRIES: Enter on pullbacks/retracements instead of breakouts
// - REVERSED EXITS: Close losers quickly (3s), let winners run longer
// - Maximum 10 simultaneous trades (progressive reduction as approaching 8%)
// - 5-second time-based exit (extended for very profitable trades)
// - 2% capital-based stop loss (FTMO requirement)
// - Progressive risk management (0.05-0.08% per trade)
// - Conservative lot scaling after wins (1.1x-1.2x multiplier)
// - 8% daily profit target
// =====================================================================================================

// ===== Core Trading Settings =====
input group "===== Core Trading Settings ====="
input int      MagicNumber         = 202510;
input string   TradeSymbol         = "";      // Symbol to trade (empty = current chart symbol)
input int      MaxSimultaneousTrades = 10;    // Maximum simultaneous trades (FTMO: 10 max)
input int      TimeBasedExitSeconds = 5;      // Base exit time in seconds
input double   BaseRiskPercentPerTrade = 0.05; // Base risk % per trade
input double   StopLossPercentCapital = 2.0;  // Stop loss as % of capital (FTMO: 2%)
input double   DailyProfitTargetPercent = 8.0; // Daily profit target % (8% for FTMO)

// ===== Entry Settings =====
input group "===== Price Action Entry (Selective) ====="
input double   PriceVelocityThreshold = 4.5;    // Minimum points/second (increased for quality)
input int      SwingPeriod           = 20;      // Period for swing high/low detection
input double   ConsolidationMaxSpread = 1.5;    // Maximum spread for consolidation (tightened)
input double   BreakoutMinPoints     = 4.0;     // Minimum points beyond break (increased)
input int      MinTickSpeed          = 5;       // Minimum ticks per second
input int      EntryCooldownSeconds  = 1;       // Seconds between entries

// ===== Entry Quality Filters =====
input group "===== Entry Quality Filters ====="
input double   MinVolatilityForEntry = 1.2;     // Minimum volatility (increased for quality)
input double   MaxSpreadForEntry     = 10.0;    // Maximum spread in points
input int      LossCooldownSeconds   = 2;       // Seconds to wait after closing at loss
input double   MinPatternScore       = 60.0;    // Minimum pattern quality score (0-100)
input bool     RequireMultiPatternConfirmation = false; // Require 2+ patterns to agree

// ===== Extended Exit Settings =====
input group "===== Extended Exit Settings ====="
input double   ExtendedExitProfitPips = 100.0;  // Profit threshold for extended exit (pips)
input int      ExtendedExitSeconds = 12;        // Extended exit time for profitable trades (seconds)
input double   VeryProfitablePips = 200.0;      // Very profitable threshold (pips)
input int      VeryProfitableExitSeconds = 18;  // Exit time for very profitable trades

// ===== Lot Scaling Settings =====
input group "===== Lot Scaling After Wins ====="
input bool     UseLotScaling = true;            // Enable lot scaling after wins
input double   LotScalingMultiplier = 1.15;     // Lot multiplier per consecutive win (1.15 = 15% increase)
input double   MaxLotMultiplier = 2.0;          // Maximum lot multiplier cap

// ===== Spread & Slippage =====
input group "===== Spread & Execution ====="
input int      MaxSlippagePoints   = 10;       // Maximum slippage in points
input int      OrderRetries        = 3;        // Number of order retries

// ===== Risk Management =====
input group "===== Risk Management ====="
input double   MaxDrawdownPercent  = 30.0;      // Maximum drawdown % (stop trading)
input bool     UseDrawdownProtection = true;    // Enable drawdown protection
input double   DailyLossLimitPercent = 4.0;    // Daily loss limit % (FTMO: 4%)
input bool     UseDailyLossLimit   = true;      // Enable daily loss limit

// ===== Profit Targets =====
input group "===== Profit Targets ====="
input double   IndividualProfitTargetPips = 500.0; // Individual profit target in pips
input bool     UseProfitTarget     = true;      // Enable individual profit target

// =====================================================================================================
// STRUCTURES & GLOBALS
// =====================================================================================================

struct TradeInfo {
   ulong    ticket;
   double   entryPrice;
   datetime openTime;
   int      direction;  // 1=BUY, -1=SELL
   double   lotSize;
   double   stopLoss;   // Stop loss price (FTMO requirement)
};

TradeInfo activeTrades[10];  // Maximum 10 trades
int activeTradeCount = 0;

// Time-based price tracking structure
struct PricePoint {
   double price;
   datetime time;
};

PricePoint priceHistory[100];
int priceHistoryCount = 0;
double tickPrices[20];
datetime lastTickTime;
double currentTicksPerSecond = 0;
int tickCounter = 0;
double currentVolatility = 0.0;

int basketDirection = 0;
datetime lastEntryTime = 0;
datetime lastBasketCloseTime = 0;
double lastBasketCloseProfit = 0.0;

// Consecutive win tracking for lot scaling
int consecutiveWins = 0;
double recentTradeProfits[10];
int recentTradeIndex = 0;

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
double dailyLoss = 0.0;
double dailyStartBalance = 0.0;
double dailyProfitTarget = 0.0;  // 8% target in dollars
datetime lastDayReset = 0;
bool tradingStopped = false;

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("Hyperactive HFT MT5 Scalper FTMO V3.10");
   Print("Optimized for 8% Daily Profit Target");
   Print("========================================");
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
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
   
   // Initialize trading state
   activeTradeCount = 0;
   for(int i = 0; i < 10; i++)
      activeTrades[i].ticket = 0;
   
   // Initialize risk management
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   highestBalance = initialBalance;
   dailyProfit = 0.0;
   dailyLoss = 0.0;
   dailyStartBalance = initialBalance;
   dailyProfitTarget = dailyStartBalance * (DailyProfitTargetPercent / 100.0);
   lastDayReset = TimeCurrent();
   tradingStopped = false;
   
   // Initialize price tracking
   priceHistoryCount = 0;
   tickCounter = 0;
   lastTickTime = TimeCurrent();
   basketDirection = 0;
   lastEntryTime = 0;
   
   // Initialize consecutive win tracking
   consecutiveWins = 0;
   ArrayInitialize(recentTradeProfits, 0.0);
   recentTradeIndex = 0;
   
   // Sync with existing positions
   SyncWithExistingPositions();
   
   Print("Trade Symbol: ", tradeSymbol);
   Print("Max Simultaneous Trades: ", MaxSimultaneousTrades);
   Print("Daily Profit Target: ", DoubleToString(DailyProfitTargetPercent, 1), "% ($", DoubleToString(dailyProfitTarget, 2), ")");
   Print("Base Risk Per Trade: ", DoubleToString(BaseRiskPercentPerTrade, 2), "%");
   Print("Stop Loss: ", StopLossPercentCapital, "% of capital");
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("Hyperactive HFT MT5 Scalper FTMO deinitialized. Reason: ", reason);
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   if(!UpdateMarketData())
      return;
   
   UpdateVelocity();
   CheckRiskManagement();
   
   if(tradingStopped)
   {
      UpdateDisplay();
      return;
   }
   
   // Manage exits
   ManageActiveExits();
   
   // Look for new entries
   int currentMaxTrades = CalculateProgressiveMaxTrades();
   if(!tradingStopped && activeTradeCount < currentMaxTrades)
   {
      if(TimeCurrent() - lastEntryTime >= EntryCooldownSeconds)
      {
         int signal = GetHFTMove();
         if(signal != 0)
         {
            if(basketDirection == 0 || signal == basketDirection)
            {
               if(OpenTrade(signal))
                  lastEntryTime = TimeCurrent();
            }
         }
      }
   }
   
   UpdateDisplay();
}

// =====================================================================================================
// MARKET DATA & VELOCITY TRACKING
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

void UpdateVelocity()
{
   tickCounter++;
   datetime now = TimeCurrent();
   if(now > lastTickTime)
   {
      currentTicksPerSecond = tickCounter;
      tickCounter = 0;
      lastTickTime = now;
   }
   
   for(int i = 19; i > 0; i--)
      tickPrices[i] = tickPrices[i-1];
   tickPrices[0] = currentBid;
   
   double midPrice = (currentBid + currentAsk) / 2.0;
   
   if(priceHistoryCount < 100)
   {
      priceHistory[priceHistoryCount].price = midPrice;
      priceHistory[priceHistoryCount].time = now;
      priceHistoryCount++;
   }
   else
   {
      for(int i = 0; i < 99; i++)
         priceHistory[i] = priceHistory[i+1];
      priceHistory[99].price = midPrice;
      priceHistory[99].time = now;
   }
   
   CleanOldPriceHistory(now);
   UpdateVolatility();
}

void CleanOldPriceHistory(datetime currentTime)
{
   int writeIndex = 0;
   for(int i = 0; i < priceHistoryCount; i++)
   {
      if(currentTime - priceHistory[i].time <= 10)
      {
         if(writeIndex != i)
            priceHistory[writeIndex] = priceHistory[i];
         writeIndex++;
      }
   }
   priceHistoryCount = writeIndex;
}

void UpdateVolatility()
{
   if(SwingPeriod < 2) return;
   
   double minPrice = tickPrices[0];
   double maxPrice = tickPrices[0];
   
   int checkPeriod = MathMin(SwingPeriod, 20);
   for(int i = 0; i < checkPeriod && i < 20; i++)
   {
      if(tickPrices[i] < minPrice) minPrice = tickPrices[i];
      if(tickPrices[i] > maxPrice) maxPrice = tickPrices[i];
   }
   
   currentVolatility = (maxPrice - minPrice) / point;
}

// =====================================================================================================
// ENTRY QUALITY FILTERS
// =====================================================================================================

bool CheckLossCooldown()
{
   if(lastBasketCloseProfit < 0 && lastBasketCloseTime > 0)
   {
      int secondsSinceClose = (int)(TimeCurrent() - lastBasketCloseTime);
      if(secondsSinceClose < LossCooldownSeconds)
         return false;
   }
   return true;
}

bool CheckVolatilityFilter()
{
   // REVERSED: Prefer lower volatility for mean reversion (opposite of breakout strategy)
   // Allow entry when volatility is moderate (not too high, not too low)
   double maxVolatility = MinVolatilityForEntry * 2.0;  // Upper limit
   return (currentVolatility >= MinVolatilityForEntry * 0.5 && currentVolatility <= maxVolatility);
}

bool CheckSpreadFilter()
{
   return (currentSpread <= MaxSpreadForEntry);
}

// =====================================================================================================
// PATTERN SCORING SYSTEM
// =====================================================================================================

double CalculatePatternScore(int patternType, double velocity, double volatility)
{
   double score = 0.0;
   
   // Velocity strength (0-50 points)
   double velocityRatio = MathAbs(velocity) / PriceVelocityThreshold;
   score += MathMin(velocityRatio * 25.0, 50.0);
   
   // Volatility bonus (0-25 points)
   if(volatility > 0)
   {
      double volatilityBonus = MathMin((volatility / (PriceVelocityThreshold * 2.0)) * 25.0, 25.0);
      score += volatilityBonus;
   }
   
   // Pattern type bonus (0-25 points)
   if(patternType == 1)      // Velocity pattern (primary)
      score += 25.0;
   else if(patternType == 2) // Consolidation breakout
      score += 15.0;
   else if(patternType == 3) // Swing breakout
      score += 10.0;
   
   return MathMin(score, 100.0);
}

// =====================================================================================================
// ENTRY LOGIC - PRICE ACTION PATTERNS
// =====================================================================================================

int GetHFTMove()
{
   if(currentTicksPerSecond < MinTickSpeed) return 0;
   if(priceHistoryCount < 3) return 0;
   
   if(!CheckLossCooldown()) return 0;
   if(!CheckSpreadFilter()) return 0;
   if(!CheckVolatilityFilter()) return 0;
   
   datetime currentTime = TimeCurrent();
   double currentPrice = priceHistory[priceHistoryCount-1].price;
   
   int signal1 = 0, signal2 = 0, signal3 = 0;
   double score1 = 0.0, score2 = 0.0, score3 = 0.0;
   
   // Pattern 1: Price Velocity
   signal1 = CheckPriceVelocity(currentPrice, currentTime);
   if(signal1 != 0)
   {
      double velocity1s = 0.0;
      double price1sAgo = GetPriceAtTime(currentTime - 1);
      if(price1sAgo > 0)
         velocity1s = (currentPrice - price1sAgo) / point;
      score1 = CalculatePatternScore(1, velocity1s, currentVolatility);
   }
   
   // Pattern 2: Consolidation Breakout
   signal2 = CheckConsolidationBreakout(currentPrice, currentTime);
   if(signal2 != 0)
   {
      double velocity1s = 0.0;
      double price1sAgo = GetPriceAtTime(currentTime - 1);
      if(price1sAgo > 0)
         velocity1s = (currentPrice - price1sAgo) / point;
      score2 = CalculatePatternScore(2, velocity1s, currentVolatility);
   }
   
   // Pattern 3: Swing Breakout
   signal3 = CheckSwingBreakout(currentPrice, currentTime);
   if(signal3 != 0)
   {
      double velocity1s = 0.0;
      double price1sAgo = GetPriceAtTime(currentTime - 1);
      if(price1sAgo > 0)
         velocity1s = (currentPrice - price1sAgo) / point;
      score3 = CalculatePatternScore(3, velocity1s, currentVolatility);
   }
   
   // REVERSED STRATEGY: Flip all signals (bullish -> sell, bearish -> buy)
   // Multi-pattern confirmation
   if(RequireMultiPatternConfirmation)
   {
      int buyVotes = 0, sellVotes = 0;
      // Reverse: original buy signal (1) becomes sell vote (-1), original sell signal (-1) becomes buy vote (1)
      if(signal1 == 1 && score1 >= MinPatternScore) sellVotes++;  // Reversed
      else if(signal1 == -1 && score1 >= MinPatternScore) buyVotes++;  // Reversed
      if(signal2 == 1 && score2 >= MinPatternScore) sellVotes++;  // Reversed
      else if(signal2 == -1 && score2 >= MinPatternScore) buyVotes++;  // Reversed
      if(signal3 == 1 && score3 >= MinPatternScore) sellVotes++;  // Reversed
      else if(signal3 == -1 && score3 >= MinPatternScore) buyVotes++;  // Reversed
      
      if(buyVotes >= 2) return 1;
      if(sellVotes >= 2) return -1;
      return 0;
   }
   
   // Return best signal above threshold (reversed)
   if(signal1 != 0 && score1 >= MinPatternScore) return -signal1;  // Reverse signal
   if(signal2 != 0 && score2 >= MinPatternScore) return -signal2;  // Reverse signal
   if(signal3 != 0 && score3 >= MinPatternScore) return -signal3;  // Reverse signal
   
   return 0;
}

int CheckPriceVelocity(double currentPrice, datetime currentTime)
{
   if(priceHistoryCount < 3) return 0;
   
   double velocity1s = 0.0;
   double velocity2s = 0.0;
   
   double price1sAgo = GetPriceAtTime(currentTime - 1);
   double price2sAgo = GetPriceAtTime(currentTime - 2);
   
   if(price1sAgo > 0)
      velocity1s = (currentPrice - price1sAgo) / point;
   if(price2sAgo > 0)
      velocity2s = (currentPrice - price2sAgo) / (point * 2.0);
   
   if(velocity1s >= PriceVelocityThreshold && velocity2s >= PriceVelocityThreshold * 0.7)
      return 1;
   if(velocity1s <= -PriceVelocityThreshold && velocity2s <= -PriceVelocityThreshold * 0.7)
      return -1;
   
   return 0;
}

int CheckConsolidationBreakout(double currentPrice, datetime currentTime)
{
   if(priceHistoryCount < SwingPeriod) return 0;
   
   double recentHigh = currentPrice;
   double recentLow = currentPrice;
   
   int checkCount = MathMin(SwingPeriod, priceHistoryCount);
   for(int i = priceHistoryCount - checkCount; i < priceHistoryCount; i++)
   {
      if(priceHistory[i].price > recentHigh) recentHigh = priceHistory[i].price;
      if(priceHistory[i].price < recentLow) recentLow = priceHistory[i].price;
   }
   
   double consolidationSpread = (recentHigh - recentLow) / point;
   
   if(consolidationSpread > ConsolidationMaxSpread)
      return 0;
   
   // REVERSED: Enter on pullback instead of breakout
   // If price was at high but now pulling back, that's a buy signal (mean reversion)
   // If price was at low but now bouncing up, that's a sell signal (mean reversion)
   double pullbackThreshold = BreakoutMinPoints * 0.5;  // Smaller threshold for pullbacks
   
   // Check if price pulled back from recent high (buy signal - mean reversion)
   if(currentPrice < recentHigh - (pullbackThreshold * point) && currentPrice > (recentHigh + recentLow) / 2.0)
      return 1;  // Buy on pullback from high
   
   // Check if price bounced from recent low (sell signal - mean reversion)
   if(currentPrice > recentLow + (pullbackThreshold * point) && currentPrice < (recentHigh + recentLow) / 2.0)
      return -1;  // Sell on bounce from low
   
   return 0;
}

int CheckSwingBreakout(double currentPrice, datetime currentTime)
{
   if(priceHistoryCount < SwingPeriod) return 0;
   
   double swingHigh = currentPrice;
   double swingLow = currentPrice;
   
   int checkCount = MathMin(SwingPeriod, priceHistoryCount);
   for(int i = priceHistoryCount - checkCount; i < priceHistoryCount; i++)
   {
      if(priceHistory[i].price > swingHigh) swingHigh = priceHistory[i].price;
      if(priceHistory[i].price < swingLow) swingLow = priceHistory[i].price;
   }
   
   // REVERSED: Enter on retracement instead of breakout
   // Mean reversion: buy when price retraces from swing high, sell when bounces from swing low
   double retracementThreshold = BreakoutMinPoints * 0.6;
   double swingRange = swingHigh - swingLow;
   
   // Buy signal: Price retraced from swing high (mean reversion opportunity)
   if(swingRange > 0 && currentPrice < swingHigh - (retracementThreshold * point) && 
      currentPrice > swingLow + (swingRange * 0.3))  // At least 30% retracement but not too deep
      return 1;
   
   // Sell signal: Price bounced from swing low (mean reversion opportunity)
   if(swingRange > 0 && currentPrice > swingLow + (retracementThreshold * point) && 
      currentPrice < swingHigh - (swingRange * 0.3))  // At least 30% bounce but not too high
      return -1;
   
   return 0;
}

double GetPriceAtTime(datetime targetTime)
{
   double closestPrice = 0.0;
   long minTimeDiff = LONG_MAX;
   
   for(int i = 0; i < priceHistoryCount; i++)
   {
      long timeDiff = MathAbs((long)(priceHistory[i].time - targetTime));
      if(timeDiff < minTimeDiff)
      {
         minTimeDiff = timeDiff;
         closestPrice = priceHistory[i].price;
      }
   }
   
   if(minTimeDiff <= 2)
      return closestPrice;
   
   return 0.0;
}

// =====================================================================================================
// PROGRESSIVE RISK MANAGEMENT
// =====================================================================================================

double CalculateProgressiveRisk()
{
   double progress = (dailyProfit / dailyProfitTarget) * 100.0;
   
   if(progress < 50.0)
      return BaseRiskPercentPerTrade * 1.6;  // 0.08% (slightly increased)
   else if(progress < 75.0)
      return BaseRiskPercentPerTrade * 1.2;  // 0.06%
   else if(progress < 90.0)
      return BaseRiskPercentPerTrade;         // 0.05%
   else
      return BaseRiskPercentPerTrade * 0.6;  // 0.03% (very conservative near target)
}

int CalculateProgressiveMaxTrades()
{
   double progress = (dailyProfit / dailyProfitTarget) * 100.0;
   
   if(progress < 50.0)
      return MaxSimultaneousTrades;      // 10 trades
   else if(progress < 75.0)
      return 7;                          // 7 trades
   else if(progress < 90.0)
      return 5;                          // 5 trades
   else
      return 3;                          // 3 trades (very conservative)
}

// =====================================================================================================
// RISK MANAGEMENT
// =====================================================================================================

void CheckRiskManagement()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   MqlDateTime lastDt;
   TimeToStruct(lastDayReset, lastDt);
   
   if(dt.day != lastDt.day || dt.mon != lastDt.mon || dt.year != lastDt.year)
   {
      dailyProfit = 0.0;
      dailyLoss = 0.0;
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyProfitTarget = dailyStartBalance * (DailyProfitTargetPercent / 100.0);
      lastDayReset = currentTime;
      consecutiveWins = 0;  // Reset on new day
   }
   
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyChange = currentBalance - dailyStartBalance;
   if(dailyChange > 0.0)
   {
      dailyProfit = dailyChange;
      dailyLoss = 0.0;
   }
   else
   {
      dailyProfit = 0.0;
      dailyLoss = MathAbs(dailyChange);
   }
   
   // Check daily loss limit
   if(UseDailyLossLimit)
   {
      double dailyLossPercent = (dailyLoss / dailyStartBalance) * 100.0;
      if(dailyLossPercent >= DailyLossLimitPercent)
      {
         tradingStopped = true;
         Print("TRADING STOPPED: Daily loss limit reached: ", DoubleToString(dailyLossPercent, 2), "%");
         CloseAllTrades();
         return;
      }
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
         Print("TRADING STOPPED: Drawdown ", DoubleToString(drawdown, 2), "%");
         CloseAllTrades();
      }
   }
   
   // Check 8% profit target
   if(dailyProfit >= dailyProfitTarget)
   {
      tradingStopped = true;
      Print("TRADING STOPPED: 8% Daily profit target reached: $", DoubleToString(dailyProfit, 2));
      CloseAllTrades();
   }
}

// =====================================================================================================
// LOT SIZING
// =====================================================================================================

double CalculateLotSize(int direction, double entryPrice, double stopLossPrice)
{
   // Calculate progressive risk
   double riskPercent = CalculateProgressiveRisk();
   
   // Apply lot scaling multiplier if enabled
   double lotMultiplier = 1.0;
   if(UseLotScaling && consecutiveWins > 0)
   {
      lotMultiplier = MathPow(LotScalingMultiplier, consecutiveWins);
      if(lotMultiplier > MaxLotMultiplier)
         lotMultiplier = MaxLotMultiplier;
   }
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (riskPercent / 100.0);
   
   double slDistance = 0.0;
   if(direction == 1)
      slDistance = (entryPrice - stopLossPrice) / point;
   else
      slDistance = (stopLossPrice - entryPrice) / point;
   
   if(slDistance <= 0.0)
      return 0.0;
   
   double tickValue = SymbolInfoDouble(tradeSymbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue <= 0.0)
   {
      double contractSize = SymbolInfoDouble(tradeSymbol, SYMBOL_TRADE_CONTRACT_SIZE);
      tickValue = contractSize * point;
   }
   
   double lotSize = (riskAmount / (slDistance * tickValue)) * lotMultiplier;
   
   double lotStep = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MAX);
   
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   
   if(lotStep > 0.0)
      lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   return NormalizeDouble(lotSize, 2);
}

double CalculateStopLoss(int direction, double entryPrice)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double slAmount = balance * (StopLossPercentCapital / 100.0);
   
   double tickValue = SymbolInfoDouble(tradeSymbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue <= 0.0)
   {
      double contractSize = SymbolInfoDouble(tradeSymbol, SYMBOL_TRADE_CONTRACT_SIZE);
      tickValue = contractSize * point;
   }
   
   double standardLot = 0.01;
   double slDistancePoints = slAmount / (standardLot * tickValue);
   
   if(slDistancePoints < 10.0) slDistancePoints = 10.0;
   if(slDistancePoints > 500.0) slDistancePoints = 500.0;
   
   double sl = 0.0;
   if(direction == 1)
      sl = entryPrice - (slDistancePoints * point);
   else
      sl = entryPrice + (slDistancePoints * point);
   
   return NormalizeDouble(sl, symbolDigits);
}

// =====================================================================================================
// OPEN TRADE
// =====================================================================================================

bool OpenTrade(int direction)
{
   if(direction == 0) return false;
   
   int currentMaxTrades = CalculateProgressiveMaxTrades();
   if(activeTradeCount >= currentMaxTrades) return false;
   
   double entryPrice = (direction == 1) ? currentAsk : currentBid;
   double sl = CalculateStopLoss(direction, entryPrice);
   double lotSize = CalculateLotSize(direction, entryPrice, sl);
   
   if(lotSize <= 0.0) return false;
   
   string comment = "HFT_FTMO_" + (direction == 1 ? "BUY" : "SELL");
   
   bool sent = false;
   int retries = 0;
   
   while(retries < OrderRetries && !sent)
   {
      if(direction == 1)
         sent = trade.Buy(lotSize, tradeSymbol, 0.0, sl, 0.0, comment);
      else
         sent = trade.Sell(lotSize, tradeSymbol, 0.0, sl, 0.0, comment);
      
      if(!sent)
      {
         retries++;
         if(retries < OrderRetries)
         {
            Sleep(50);
            SymbolInfoTick(tradeSymbol, currentTick);
            currentBid = currentTick.bid;
            currentAsk = currentTick.ask;
            entryPrice = (direction == 1) ? currentAsk : currentBid;
            sl = CalculateStopLoss(direction, entryPrice);
         }
      }
   }
   
   if(sent)
   {
      ulong ticket = 0;
      if(trade.ResultDeal() > 0)
      {
         if(HistoryDealSelect(trade.ResultDeal()))
            ticket = HistoryDealGetInteger(trade.ResultDeal(), DEAL_POSITION_ID);
      }
      
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
         double actualEntryPrice = entryPrice;
         double actualSL = sl;
         if(PositionSelectByTicket(ticket))
         {
            actualEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            actualSL = PositionGetDouble(POSITION_SL);
            
            if(actualSL == 0.0)
            {
               Print("WARNING: Position opened without stop loss! Attempting to set...");
               trade.PositionModify(ticket, sl, 0.0);
            }
         }
         
         activeTrades[activeTradeCount].ticket = ticket;
         activeTrades[activeTradeCount].entryPrice = actualEntryPrice;
         activeTrades[activeTradeCount].openTime = TimeCurrent();
         activeTrades[activeTradeCount].direction = direction;
         activeTrades[activeTradeCount].lotSize = lotSize;
         activeTrades[activeTradeCount].stopLoss = actualSL;
         activeTradeCount++;
         
         if(basketDirection == 0)
            basketDirection = direction;
         
         Print("TRADE OPENED: ", (direction == 1 ? "BUY" : "SELL"), 
               " | Lot: ", lotSize, " | Price: ", actualEntryPrice, " | SL: ", actualSL);
         return true;
      }
   }
   
   return false;
}

// =====================================================================================================
// MANAGE ACTIVE EXITS
// =====================================================================================================

void ManageActiveExits()
{
   SyncWithExistingPositions();
   
   // Remove invalid trades
   for(int i = activeTradeCount - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(activeTrades[i].ticket))
      {
         double closedProfit = 0.0;
         datetime closeTime = TimeCurrent();
         
         HistorySelect(closeTime - 3600, closeTime);
         int totalDeals = HistoryDealsTotal();
         for(int j = totalDeals - 1; j >= 0; j--)
         {
            ulong dealTicket = HistoryDealGetTicket(j);
            if(dealTicket > 0)
            {
               if(HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) == activeTrades[i].ticket &&
                  HistoryDealGetString(dealTicket, DEAL_SYMBOL) == tradeSymbol &&
                  HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == MagicNumber)
               {
                  if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
                  {
                     closedProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) + HistoryDealGetDouble(dealTicket, DEAL_SWAP);
                     break;
                  }
               }
            }
         }
         
         // Update consecutive wins
         if(closedProfit > 0.0)
         {
            consecutiveWins++;
            recentTradeProfits[recentTradeIndex] = closedProfit;
            recentTradeIndex = (recentTradeIndex + 1) % 10;
         }
         else if(closedProfit < 0.0)
         {
            consecutiveWins = 0;
         }
         
         // Update daily tracking
         if(closedProfit > 0.0)
         {
            dailyProfit += closedProfit;
            dailyLoss = 0.0;
         }
         else if(closedProfit < 0.0)
         {
            dailyLoss += MathAbs(closedProfit);
            dailyProfit = 0.0;
         }
         
         RemoveTrade(i);
         if(activeTradeCount == 0)
            basketDirection = 0;
      }
   }
   
   if(activeTradeCount == 0) return;
   
   datetime currentTime = TimeCurrent();
   
   for(int i = activeTradeCount - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket > 0 && PositionSelectByTicket(activeTrades[i].ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         int holdSeconds = (int)(currentTime - activeTrades[i].openTime);
         
         double currentPrice = (activeTrades[i].direction == 1) ? currentBid : currentAsk;
         double priceDiff = currentPrice - activeTrades[i].entryPrice;
         if(activeTrades[i].direction == -1)
            priceDiff = -priceDiff;
         
         double profitPoints = priceDiff / point;
         
         // Exit condition 1: Profit target
         if(UseProfitTarget && profitPoints >= IndividualProfitTargetPips)
         {
            if(trade.PositionClose(activeTrades[i].ticket))
            {
               Print("TRADE CLOSED (Profit Target): ", profitPoints, " pips | P&L: $", DoubleToString(profit, 2));
               
               if(profit > 0.0)
               {
                  consecutiveWins++;
                  dailyProfit += profit;
                  dailyLoss = 0.0;
               }
               else
               {
                  consecutiveWins = 0;
                  dailyLoss += MathAbs(profit);
                  dailyProfit = 0.0;
               }
               
               RemoveTrade(i);
               continue;
            }
         }
         
         // REVERSED EXIT STRATEGY: Close losing trades quickly, let winners run longer
         // Exit condition 2a: Close losing trades quickly (3 seconds)
         if(holdSeconds >= 3 && profit < 0.0)
         {
            if(trade.PositionClose(activeTrades[i].ticket))
            {
               Print("TRADE CLOSED (Loss Time-based): ", holdSeconds, "s | ", profitPoints, " pips | P&L: $", DoubleToString(profit, 2));
               
               consecutiveWins = 0;
               dailyLoss += MathAbs(profit);
               dailyProfit = 0.0;
               
               RemoveTrade(i);
               continue;
            }
         }
         
         // Exit condition 2b: Extended time-based exit for VERY profitable trades only
         int exitTime = VeryProfitableExitSeconds;  // Only close very profitable trades after extended time
         if(profitPoints >= VeryProfitablePips && holdSeconds >= exitTime && profit > 0.0)
         {
            if(trade.PositionClose(activeTrades[i].ticket))
            {
               Print("TRADE CLOSED (Extended Profit): ", holdSeconds, "s | ", profitPoints, " pips | P&L: $", DoubleToString(profit, 2));
               
               consecutiveWins++;
               dailyProfit += profit;
               dailyLoss = 0.0;
               
               RemoveTrade(i);
               continue;
            }
         }
         
         // Let smaller profitable trades run indefinitely (no time-based exit for them)
      }
   }
   
   if(activeTradeCount == 0)
      basketDirection = 0;
}

void CloseAllTrades()
{
   double totalProfit = 0.0;
   int totalPositions = PositionsTotal();
   for(int j = totalPositions - 1; j >= 0; j--)
   {
      ulong ticket = PositionGetTicket(j);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == tradeSymbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         }
      }
   }
   
   lastBasketCloseTime = TimeCurrent();
   lastBasketCloseProfit = totalProfit;
   
   if(totalProfit > 0.0)
   {
      dailyProfit += totalProfit;
      dailyLoss = 0.0;
   }
   else if(totalProfit < 0.0)
   {
      dailyLoss += MathAbs(totalProfit);
      dailyProfit = 0.0;
   }
   
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == tradeSymbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            trade.PositionClose(ticket);
         }
      }
   }
   
   activeTradeCount = 0;
   for(int i = 0; i < 10; i++)
      activeTrades[i].ticket = 0;
   
   basketDirection = 0;
}

void RemoveTrade(int index)
{
   for(int i = index; i < activeTradeCount - 1; i++)
      activeTrades[i] = activeTrades[i+1];
   activeTradeCount--;
}

// =====================================================================================================
// SYNC FUNCTIONS
// =====================================================================================================

void SyncWithExistingPositions()
{
   activeTradeCount = 0;
   for(int i = 0; i < 10; i++)
      activeTrades[i].ticket = 0;
   
   int totalPositions = PositionsTotal();
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == tradeSymbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            if(activeTradeCount < 10)
            {
               activeTrades[activeTradeCount].ticket = ticket;
               activeTrades[activeTradeCount].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               activeTrades[activeTradeCount].openTime = (datetime)PositionGetInteger(POSITION_TIME);
               activeTrades[activeTradeCount].direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
               activeTrades[activeTradeCount].lotSize = PositionGetDouble(POSITION_VOLUME);
               activeTrades[activeTradeCount].stopLoss = PositionGetDouble(POSITION_SL);
               activeTradeCount++;
            }
         }
      }
   }
   
   RecalculateBasketDirection();
}

void RecalculateBasketDirection()
{
   int totalPositions = PositionsTotal();
   int buyCount = 0, sellCount = 0;
   
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == tradeSymbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(posType == POSITION_TYPE_BUY) buyCount++;
            else if(posType == POSITION_TYPE_SELL) sellCount++;
         }
      }
   }
   
   if(buyCount > 0 && sellCount == 0)
      basketDirection = 1;
   else if(sellCount > 0 && buyCount == 0)
      basketDirection = -1;
   else if(buyCount == 0 && sellCount == 0)
      basketDirection = 0;
   else
      basketDirection = (buyCount > sellCount) ? 1 : -1;
}

// =====================================================================================================
// DISPLAY
// =====================================================================================================

void UpdateDisplay()
{
   string status = "\n=== Hyperactive HFT MT5 Scalper FTMO V3.10 ===\n";
   status += "Symbol: " + tradeSymbol + "\n";
   
   int currentMaxTrades = CalculateProgressiveMaxTrades();
   double currentRisk = CalculateProgressiveRisk();
   double progress = (dailyProfit / dailyProfitTarget) * 100.0;
   
   status += "Active Trades: " + IntegerToString(activeTradeCount) + " / " + IntegerToString(currentMaxTrades) + "\n";
   status += "Risk Per Trade: " + DoubleToString(currentRisk, 2) + "%\n";
   status += "Progress to 8%: " + DoubleToString(progress, 1) + "%\n";
   
   if(UseLotScaling)
   {
      double currentMultiplier = (consecutiveWins > 0) ? MathPow(LotScalingMultiplier, consecutiveWins) : 1.0;
      if(currentMultiplier > MaxLotMultiplier) currentMultiplier = MaxLotMultiplier;
      status += "Consecutive Wins: " + IntegerToString(consecutiveWins) + " | Lot Multiplier: " + DoubleToString(currentMultiplier, 2) + "x\n";
   }
   
   status += "Tick Speed: " + DoubleToString(currentTicksPerSecond, 2) + " ticks/sec";
   if(currentTicksPerSecond < MinTickSpeed)
      status += " [LOW]";
   status += "\n";
   
   status += "Spread: " + DoubleToString(currentSpread, 1) + " points\n";
   status += "Volatility: " + DoubleToString(currentVolatility, 1) + " points\n";
   
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
   
   if(activeTradeCount > 0)
   {
      status += "\n--- Active Trades ---\n";
      double totalProfit = 0.0;
      for(int i = 0; i < activeTradeCount; i++)
      {
         if(activeTrades[i].ticket > 0 && PositionSelectByTicket(activeTrades[i].ticket))
         {
            double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            int holdSeconds = (int)(TimeCurrent() - openTime);
            
            totalProfit += profit;
            
            double currentPrice = (activeTrades[i].direction == 1) ? currentBid : currentAsk;
            double priceDiff = currentPrice - activeTrades[i].entryPrice;
            if(activeTrades[i].direction == -1) priceDiff = -priceDiff;
            double profitPoints = priceDiff / point;
            
            int exitTime = TimeBasedExitSeconds;
            if(profitPoints >= VeryProfitablePips)
               exitTime = VeryProfitableExitSeconds;
            else if(profitPoints >= ExtendedExitProfitPips)
               exitTime = ExtendedExitSeconds;
            
            status += "Trade " + IntegerToString(i+1) + ": " + 
                     (activeTrades[i].direction == 1 ? "BUY" : "SELL") + 
                     " | P&L: $" + DoubleToString(profit, 2) + 
                     " (" + DoubleToString(profitPoints, 1) + " pips)" +
                     " | Hold: " + IntegerToString(holdSeconds) + "s";
            
            if(profit > 0.0 && holdSeconds >= exitTime)
               status += " [READY TO CLOSE]";
            else if(UseProfitTarget && profitPoints >= IndividualProfitTargetPips)
               status += " [PROFIT TARGET]";
            else if(profitPoints >= VeryProfitablePips && holdSeconds >= VeryProfitableExitSeconds)
               status += " [EXTENDED PROFIT - READY TO CLOSE]";
            else if(profit > 0.0)
               status += " [WINNER - LETTING RUN]";
            else if(profit < 0.0)
               status += " [WAITING FOR SL]";
            
            status += "\n";
         }
      }
      status += "Total P&L: $" + DoubleToString(totalProfit, 2) + "\n";
   }
   else
   {
      status += "\nNo active trades\n";
   }
   
   status += "\n--- Account ---\n";
   status += "Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n";
   status += "Equity: $" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\n";
   
   status += "Daily Profit: $" + DoubleToString(dailyProfit, 2) + " / $" + DoubleToString(dailyProfitTarget, 2);
   status += " (" + DoubleToString(progress, 1) + "%)\n";
   
   if(UseDailyLossLimit && dailyLoss > 0.0)
   {
      double dailyLossPercent = (dailyLoss / dailyStartBalance) * 100.0;
      status += "Daily Loss: $" + DoubleToString(dailyLoss, 2) + " (" + DoubleToString(dailyLossPercent, 2) + "%)\n";
   }
   
   Comment(status);
}
