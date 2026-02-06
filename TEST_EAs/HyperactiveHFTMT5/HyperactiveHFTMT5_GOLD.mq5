#property copyright "Copyright 2026, Tick Momentum Basket Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "3.00"

#include <Trade/Trade.mqh>

CTrade trade;

// =====================================================================================================
// TICK MOMENTUM BASKET SCALPER - CONSERVATIVE RISK EDITION
// =====================================================================================================

input group "===== Lot Settings ====="
input double   MinLotSize           = 0.01;     // Minimum lot size (safety limit)
input double   RiskPercentPerTrade  = 1.0;      // Risk % of balance per trade (conservative risk-based sizing)
input double   LotSizingStopLossPips = 100.0;   // Stop loss distance (pips) used for lot size calculation only (no broker stop loss)
input int      MagicNumber          = 202610;

input group "===== Progressive Lot Sizing ====="
input int      SafeTradeCount       = 10;       // Number of safe trades before going aggressive
input double   SafeTradeRiskPercent = 1.0;      // Risk % during safe phase (default 1%)
input bool     UseHTFTrendMaxLot    = true;     // Use HTF trend for aggressive sizing after safe phase

input group "===== Dynamic Trade Scaling ====="
input int      BaseSimultaneousTrades = 1;      // Base/minimum simultaneous trades
input int      MaxSimultaneousTrades  = 5;      // Maximum cap for simultaneous trades
input double   TickSpeedMultiplier    = 2.0;    // Scaling factor for tick speed

input group "===== Basket Profit Exit ====="
input int      BasketProfitExitSeconds = 3;      // Base seconds basket must be profitable before closing (EXACTLY 3 seconds for instant profit-taking)
input double   MinBasketProfitDollars  = 0.01;  // Minimum profit threshold to consider basket "profitable" ($) - ANY profit triggers timer
input bool     UseVolatilityAdjustedExit = false; // Adjust exit time based on volatility (high vol = faster exit, low vol = slower exit)
input double   VolatilityAdjustmentFactor = 0.5; // Adjustment factor (0.0 = no adjustment, 0.5 = moderate, 1.0 = maximum)

input group "===== Price Action Entry ====="
input double   PriceVelocityThreshold = 1.5;    // Minimum points/second for momentum burst entry (REDUCED from 3.0 for more entries)
input int      SwingPeriod           = 10;      // Period for swing high/low detection (price samples) (REDUCED from 20)
input double   ConsolidationMaxSpread = 5.0;    // Maximum spread for consolidation detection (points) (INCREASED from 2.0)
input double   BreakoutMinPoints     = 1.5;     // Minimum points beyond break for entry (REDUCED from 3.0)
input double   VelocityConfirmationSeconds = 1.0; // Time window for velocity confirmation
input int      MinTickSpeed          = 2;       // Minimum ticks per second (filter for market activity) (REDUCED from 5)
input int      EntryCooldownSeconds  = 1;       // Seconds between entries on same symbol (REDUCED for more frequent entries)

input group "===== Entry Quality Filters ====="
input double   MinVolatilityForEntry = 0.1;     // Minimum volatility points required for entry (REDUCED from 0.2 for more entries)
input double   MaxSpreadForEntry     = 25.0;    // Maximum spread in points to allow entry (INCREASED from 18.0 for more opportunities)
input bool     RequireMomentumAcceleration = false; // Require momentum to be accelerating (disabled by default for faster entries)
input double   MinPatternScore       = 30.0;    // Minimum pattern quality score (0-100) - lowered for quicker trades
input int      LossCooldownSeconds   = 0;       // Seconds to wait after closing basket at loss (REDUCED to 0 for immediate re-entry)
input bool     RequireMultiPatternConfirmation = false; // Require at least 2 patterns to align (disabled by default for faster entries)

input group "===== News Trading Filter ====="
input bool     EnableNewsFilter      = false;   // Enable news trading filter (block trades during news) - DISABLED BY DEFAULT
input int      NewsBlockMinutesBefore = 2;      // Minutes before news to block trading (reduced from 5)
input int      NewsBlockMinutesAfter  = 3;      // Minutes after news to block trading (reduced from 10 to prevent long blocks)
input bool     UseSpreadBasedNewsDetection = false; // Detect news by sudden spread widening (disabled to prevent false triggers)
input double   NewsSpreadMultiplier   = 3.0;    // Spread multiplier threshold for news detection (increased to reduce false triggers)
input double   NormalSpreadBaseline   = 5.0;    // Baseline normal spread in points (for news detection)

input group "===== Daily Trade Limit ====="
input bool     EnableDailyLimit      = true;    // Enable daily trade limit
input int      DailyMaxTrades        = 3000;    // Maximum trades per day

input group "===== Loss-Aware Exit Logic ====="
input bool     UseLossAwareExits     = true;    // Enable loss-aware exits (statistical survival)
input double   MaxBasketLossDollars  = 0.0;     // Maximum basket loss in $ (0 = disabled, use % only)
input double   MaxBasketLossPercent  = 1.5;     // Maximum basket loss as % of equity (loss-aware exit)
input int      MaxAdverseTimeSeconds = 60;      // Maximum time basket can stay in drawdown (force close if exceeded)

input group "===== Volatility-Aware Stop Behavior ====="
input bool     UseVolatilityStop     = false;   // Enable volatility-based exits and entry blocking (DISABLED to allow more entries)
input double   VolatilitySpreadMultiplier = 2.5; // Spread multiplier threshold (block entries or close negative baskets)
input double   VolatilityATRMultiplier = 2.0;    // ATR expansion multiplier (block entries or close negative baskets)
input int      ATRPeriod             = 14;      // Period for ATR calculation

input group "===== Maximum Lifetime Limits ====="
input bool     UseLifetimeLimits     = true;    // Enable hard maximum lifetime limits
input int      MaxTradeLifetimeSeconds = 300;  // Maximum lifetime per individual trade (5 minutes)
input int      MaxBasketLifetimeSeconds = 600;  // Maximum lifetime per basket (10 minutes)

input group "===== Forced Loss Cooldown ====="
input bool     UseForcedLossCooldown = true;    // Enable cooldown after forced loss exits
input int      ForcedLossCooldownSeconds = 30;  // Cooldown period after forced loss (seconds)

input group "===== Hard Basket Kill-Switch (Last Resort) ====="
input bool     UseBasketKillSwitch   = true;    // Enable hard basket kill-switch (last-resort protection)
input double   KillSwitchLossPercent = 2.0;     // Maximum basket loss as % of equity (kill-switch trigger - last resort)
input double   MaxPointsAgainst      = 0.0;     // Maximum points against basket (0 = disabled, use % only)

input group "===== Simplified Exit Logic ====="
input int      ProfitExitSeconds     = 3;       // Exit after 3 seconds if profitable
input double   HardLossPips          = 100.0;   // Hard loss exit: 100 pips
input double   HardLossPoints        = 1000.0;  // Hard loss exit: 1000 points (alternative to pips)

input group "===== Directional Bias Lock ====="
input bool     UseDirectionalBiasLock = false;  // Disable entries when price moves against basket (DISABLED for more entries)
input double   BiasLockPointsAgainst = 50.0;   // Points against basket to trigger directional lock

input group "===== Statistics Tracking (No Closing Logic) ====="
input bool     UseConsecutiveWinLossLimit = true; // Track consecutive wins (for statistics only - NO closing logic)
input double   LossLimitPerWinPercent = 25.0;  // Loss limit as % of basket profit per consecutive win (tracking only)
input double   MinLossLimitDollars   = 0.50;   // Minimum loss limit in dollars (tracking only)

input group "===== Account Drawdown Stop Loss ====="
input bool     UseDrawdownStopLoss   = true;    // Enable account drawdown stop loss
input double   MaxDrawdownPercent    = 30.0;    // Maximum drawdown % from highest equity (stop loss trigger)



// Internal Globals
struct TradeInfo {
   ulong    ticket;
   double   entryPrice;
   datetime openTime;
};

TradeInfo activeTrades[50]; 
int activeTradeCount = 0;

// Time-based price tracking structure
struct PricePoint {
   double price;
   datetime time;
};

PricePoint priceHistory[100];  // Track prices with timestamps
int priceHistoryCount = 0;
double tickPrices[20];  // Keep for backward compatibility/volatility calculation
datetime lastTickTime;
double currentTicksPerSecond = 0;
int tickCounter = 0;
double currentVolatility = 0.0;
double avgVolatility = 0.0;  // Average volatility for dynamic exit timing
double volatilityHistory[50];  // Track volatility history for average calculation
int volatilityHistoryCount = 0;  // Count of volatility samples

// Progressive lot sizing tracking
int totalTradesOpened = 0;  // Lifetime total trades opened
int htfTrendDirection = 0;  // HTF trend direction: 1=up, -1=down, 0=neutral

// Drawdown stop loss tracking
double highestEquity = 0.0;  // Track highest equity reached (for drawdown calculation)
bool drawdownStopLossTriggered = false;  // Flag to prevent trading after drawdown stop loss

int basketDirection = 0;  // 0=no trades, 1=BUY only, -1=SELL only
bool directionalBiasLocked = false;  // True when price moved too far against basket
int lockedDirection = 0;  // Direction that's locked (1=BUY locked, -1=SELL locked)
double basketEntryPrice = 0.0;  // Average entry price of basket (for bias lock calculation)
datetime lastEntryTime = 0;  // Track last entry time for cooldown
datetime basketFirstProfitTime = 0;  // When basket first became profitable
datetime lastBasketCloseTime = 0;  // Track when basket was last closed
double lastBasketCloseProfit = 0.0;  // Track if last close was profit or loss
bool lastCloseWasForcedLoss = false;  // Track if last close was a forced loss exit
datetime forcedLossCooldownUntil = 0;  // Cooldown end time after forced loss
double patternScores[3];  // Track scores for each pattern type [0]=velocity, [1]=consolidation, [2]=swing

// Daily trade limit tracking
int dailyTradeCount = 0;  // Counter for today's trades
datetime lastDailyResetDate = 0;  // Track last reset date

// Consecutive win tracking for loss limits
int consecutiveWins = 0;  // Count of consecutive winning baskets
double recentBasketProfits[10];  // Track recent basket profits for calculation
int recentBasketIndex = 0;  // Index for circular buffer

// Basket tracking (for exit logic only)
datetime basketStartTime = 0;  // When first trade in basket was opened
double basketStartCapital = 0.0;  // Capital when basket started
double basketMinEquity = 0.0;  // Minimum equity during basket lifecycle
double basketMaxDrawdown = 0.0;  // Maximum drawdown percentage during basket
double basketMaxLossDollars = 0.0;  // Maximum loss in dollars (for risk-to-reward calculation)

// News trading filter tracking
double spreadHistory[20];  // Track recent spreads for news detection
int spreadHistoryCount = 0;  // Count of spread samples
datetime lastNewsBlockTime = 0;  // Track when news was last detected

// Volatility tracking for ATR
double atrBuffer[];  // Buffer for ATR calculation
int atrHandle = INVALID_HANDLE;  // ATR indicator handle
double normalSpreadBaseline = 0.0;  // Baseline spread for volatility detection

// =====================================================================================================
// INIT & CORE
// =====================================================================================================

int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Initialize daily counter
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   lastDailyResetDate = StructToTime(dt);
   dailyTradeCount = 0;
   
   // Initialize consecutive win tracking
   consecutiveWins = 0;
   ArrayInitialize(recentBasketProfits, 0.0);
   recentBasketIndex = 0;
   
   // Initialize basket tracking
   basketStartTime = 0;
   basketStartCapital = 0.0;
   basketMinEquity = 0.0;
   basketMaxDrawdown = 0.0;
   basketMaxLossDollars = 0.0;
   lastCloseWasForcedLoss = false;
   forcedLossCooldownUntil = 0;
   
   // Initialize ATR indicator for volatility detection
   if(UseVolatilityStop) {
      atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
      if(atrHandle == INVALID_HANDLE) {
         Print("TMB ERROR: Failed to create ATR indicator");
         return INIT_FAILED;
      }
      ArraySetAsSeries(atrBuffer, true);
   }
   
   // Initialize normal spread baseline
   normalSpreadBaseline = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   
   // Initialize news filter tracking
   ArrayInitialize(spreadHistory, 0.0);
   spreadHistoryCount = 0;
   lastNewsBlockTime = 0;
   
   // Initialize drawdown stop loss tracking
   highestEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   drawdownStopLossTriggered = false;
   Print("TMB: Drawdown stop loss initialized. Starting equity: $", DoubleToString(highestEquity, 2), 
         ", Max drawdown: ", DoubleToString(MaxDrawdownPercent, 1), "%");
   
   // Create display panel background
   CreateDisplayPanel();
   
   // Sync with existing positions on EA restart
   SyncWithExistingPositions();
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   // Release ATR indicator handle
   if(atrHandle != INVALID_HANDLE) {
      IndicatorRelease(atrHandle);
      atrHandle = INVALID_HANDLE;
   }
   // Clean up display objects
   ObjectDelete(0, "TMB_DisplayPanel");
   ObjectDelete(0, "HFT_DisplayText");
   ObjectsDeleteAll(0, "HFT_");
   Comment("");
}

void OnTick() {
   UpdateVelocity();
   
   // Reset daily counter if new day
   ResetDailyCounterIfNeeded();
   
   // 0. CHECK DRAWDOWN STOP LOSS (before everything else)
   if(UseDrawdownStopLoss) {
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      
      // Update highest equity if current is higher (only if not already triggered)
      if(!drawdownStopLossTriggered && currentEquity > highestEquity) {
         highestEquity = currentEquity;
      }
      
      // Check if drawdown exceeds maximum (only if not already triggered)
      if(!drawdownStopLossTriggered && highestEquity > 0.0) {
         double drawdownPercent = ((highestEquity - currentEquity) / highestEquity) * 100.0;
         
         // Check if drawdown exceeds maximum
         if(drawdownPercent >= MaxDrawdownPercent) {
            Print("TMB: DRAWDOWN STOP LOSS TRIGGERED! Drawdown: ", DoubleToString(drawdownPercent, 2), 
                  "% (Limit: ", DoubleToString(MaxDrawdownPercent, 1), "%)");
            Print("TMB: Highest Equity: $", DoubleToString(highestEquity, 2), 
                  ", Current Equity: $", DoubleToString(currentEquity, 2));
            
            // Close all trades immediately
            CloseAllTrades();
            
            // Set flag to prevent further trading
            drawdownStopLossTriggered = true;
            
            Print("TMB: Drawdown stop loss activated. All trades will be closed and trading stopped.");
         }
      }
      
      // If drawdown stop loss was triggered, ensure all trades are closed and prevent new trades
      if(drawdownStopLossTriggered) {
         // Check if there are any remaining trades and close them
         int remainingPositions = 0;
         int totalPositions = PositionsTotal();
         for(int j = totalPositions - 1; j >= 0; j--) {
            ulong ticket = PositionGetTicket(j);
            if(ticket > 0 && PositionSelectByTicket(ticket)) {
               if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
                  PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
                  remainingPositions++;
                  // Close any remaining trades
                  trade.PositionClose(ticket);
               }
            }
         }
         
         if(remainingPositions > 0) {
            Print("TMB: Closing ", remainingPositions, " remaining trade(s) due to drawdown stop loss...");
         }
         
         // Stop all trading - don't allow any new entries or exits
         UpdateDisplay();
         return; // Stop trading permanently
      }
   }
   
   // 1. MANAGE EXITS
   ManageActiveExits();

   // 2. ENTRY - Dynamic trade limit based on market conditions
   // Check daily limit first
   if(EnableDailyLimit && dailyTradeCount >= DailyMaxTrades) {
      UpdateDisplay(); // Update display even when limit reached
      return; // Daily limit reached, stop trading
   }
   
   // Forced loss cooldown check
   if(UseForcedLossCooldown && forcedLossCooldownUntil > 0 && TimeCurrent() < forcedLossCooldownUntil) {
      UpdateDisplay();
      return; // Still in forced loss cooldown period
   }
   
   // Volatility blocking check (block new entries on volatility expansion)
   if(UseVolatilityStop) {
      bool spreadExpanded = false;
      bool atrExpanded = false;
      if(CheckVolatilityExpansion(spreadExpanded, atrExpanded)) {
         UpdateDisplay();
         return; // Volatility expansion detected - block new entries
      }
   }
   
   // Entry cooldown check
   if(TimeCurrent() - lastEntryTime >= EntryCooldownSeconds) {
      int dynamicMaxTrades = CalculateDynamicMaxTrades();
      if(activeTradeCount < dynamicMaxTrades) {
         int signal = GetHFTMove();
         // Check if signal matches basket direction (or basket is empty)
         if(signal != 0) {
            // Check directional bias lock
            if(UseDirectionalBiasLock && directionalBiasLocked) {
               if((signal == 1 && lockedDirection == 1) || (signal == -1 && lockedDirection == -1)) {
                  // Entry direction is locked - skip
                  return;
               }
            }
            
            if(basketDirection == 0 || signal == basketDirection) {
               OpenAggressiveTrade(signal);
               lastEntryTime = TimeCurrent(); // Update cooldown timer
            }
         }
      }
   }
   
   // Update display every tick
   UpdateDisplay();
}

int CalculateDynamicMaxTrades() {
   if(currentTicksPerSecond < MinTickSpeed) {
      return BaseSimultaneousTrades;
   }
   
   // Scale based on tick speed: base + (multiplier * (currentSpeed / minSpeed))
   double tickSpeedRatio = currentTicksPerSecond / MinTickSpeed;
   int dynamicTrades = (int)(BaseSimultaneousTrades + (TickSpeedMultiplier * tickSpeedRatio));
   
   // Ensure it's within bounds
   if(dynamicTrades < BaseSimultaneousTrades) dynamicTrades = BaseSimultaneousTrades;
   if(dynamicTrades > MaxSimultaneousTrades) dynamicTrades = MaxSimultaneousTrades;
   
   return dynamicTrades;
}

void ResetDailyCounterIfNeeded() {
   if(!EnableDailyLimit) return;
   
   // Get current date (midnight)
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime currentMidnight = StructToTime(dt);
   
   // If new day, reset counter
   if(currentMidnight > lastDailyResetDate) {
      dailyTradeCount = 0;
      lastDailyResetDate = currentMidnight;
      Print("TMB: Daily trade counter reset. New day started.");
   }
}


// =====================================================================================================
// VELOCITY & MOMENTUM
// =====================================================================================================

void UpdateVelocity() {
   tickCounter++;
   datetime now = TimeCurrent();
   if(now > lastTickTime) {
      currentTicksPerSecond = tickCounter;
      tickCounter = 0;
      lastTickTime = now;
   }
   
   // Shift prices (keep for volatility calculation)
   for(int i=19; i>0; i--) tickPrices[i] = tickPrices[i-1];
   tickPrices[0] = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Time-based price tracking - use mid-price to avoid spread noise
   double midPrice = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
   
   // Add new price point to history
   if(priceHistoryCount < 100) {
      priceHistory[priceHistoryCount].price = midPrice;
      priceHistory[priceHistoryCount].time = now;
      priceHistoryCount++;
   } else {
      // Shift array when full
      for(int i = 0; i < 99; i++) {
         priceHistory[i] = priceHistory[i+1];
      }
      priceHistory[99].price = midPrice;
      priceHistory[99].time = now;
   }
   
   // Clean old price points (older than 10 seconds)
   CleanOldPriceHistory(now);
   
   // Calculate volatility (price range over recent ticks)
   UpdateVolatility();
}

void CleanOldPriceHistory(datetime currentTime) {
   // Remove prices older than 10 seconds
   int writeIndex = 0;
   for(int i = 0; i < priceHistoryCount; i++) {
      if(currentTime - priceHistory[i].time <= 10) {
         if(writeIndex != i) {
            priceHistory[writeIndex] = priceHistory[i];
         }
         writeIndex++;
      }
   }
   priceHistoryCount = writeIndex;
}

void UpdateVolatility() {
   if(SwingPeriod < 2) return;
   
   double minPrice = tickPrices[0];
   double maxPrice = tickPrices[0];
   
   int checkPeriod = MathMin(SwingPeriod, 20);
   for(int i = 0; i < checkPeriod && i < 20; i++) {
      if(tickPrices[i] < minPrice) minPrice = tickPrices[i];
      if(tickPrices[i] > maxPrice) maxPrice = tickPrices[i];
   }
   
   currentVolatility = (maxPrice - minPrice) / _Point;
   
   // Track volatility history for average calculation (for dynamic exit timing)
   if(UseVolatilityAdjustedExit) {
      if(volatilityHistoryCount < 50) {
         volatilityHistory[volatilityHistoryCount] = currentVolatility;
         volatilityHistoryCount++;
      } else {
         // Shift array when full
         for(int i = 0; i < 49; i++) {
            volatilityHistory[i] = volatilityHistory[i+1];
         }
         volatilityHistory[49] = currentVolatility;
      }
      
      // Calculate average volatility
      if(volatilityHistoryCount > 0) {
         double volatilitySum = 0.0;
         for(int i = 0; i < volatilityHistoryCount; i++) {
            volatilitySum += volatilityHistory[i];
         }
         avgVolatility = volatilitySum / (double)volatilityHistoryCount;
      }
   }
}

// =====================================================================================================
// ENTRY QUALITY FILTERS
// =====================================================================================================

// Filter 1: Loss Cooldown - Prevents revenge trading after losses
bool CheckLossCooldown() {
   if(lastBasketCloseProfit < 0 && lastBasketCloseTime > 0) {
      int secondsSinceClose = (int)(TimeCurrent() - lastBasketCloseTime);
      if(secondsSinceClose < LossCooldownSeconds) {
         return false; // Still in cooldown period
      }
   }
   return true; // No recent loss or cooldown period passed
}

// Filter 2: Volatility Filter - Only enter during sufficient volatility
bool CheckVolatilityFilter() {
   return (currentVolatility >= MinVolatilityForEntry);
}

// Filter 3: Spread Filter - Avoid expensive entries when spread is too wide
bool CheckSpreadFilter() {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = (ask - bid) / _Point;
   
   // Track spread history for news detection
   if(EnableNewsFilter && UseSpreadBasedNewsDetection) {
      UpdateSpreadHistory(spread);
   }
   
   return (spread <= MaxSpreadForEntry);
}

// Filter 4: News Trading Filter - Block trades during news events
bool CheckNewsFilter() {
   if(!EnableNewsFilter) return true; // News filter disabled, allow trading
   
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   // Method 1: Time-based news filter (block during known high-impact news times)
   // Major news typically released at: 8:30, 10:00, 12:30, 14:00, 15:30 EST (13:30, 15:00, 17:30, 19:00, 20:30 GMT)
   // Convert to broker time (assuming GMT+0 or adjust as needed)
   int hour = dt.hour;
   int minute = dt.min;
   
   // Block during major news release windows (adjust times based on your broker's timezone)
   // Example: Block 5 minutes before and 10 minutes after major news times
   // 8:30 EST = 13:30 GMT, 10:00 EST = 15:00 GMT, 12:30 EST = 17:30 GMT, 14:00 EST = 19:00 GMT, 15:30 EST = 20:30 GMT
   int newsHours[] = {13, 15, 17, 19, 20};  // GMT hours for major news
   int newsMinutes[] = {30, 0, 30, 0, 30};  // Minutes for each news hour
   
   for(int i = 0; i < ArraySize(newsHours); i++) {
      int newsHour = newsHours[i];
      int newsMin = newsMinutes[i];
      
      // Calculate time window: NewsBlockMinutesBefore before to NewsBlockMinutesAfter after
      int totalMinutesBefore = hour * 60 + minute;
      int newsTotalMinutes = newsHour * 60 + newsMin;
      int minutesBeforeNews = newsTotalMinutes - totalMinutesBefore;
      
      // Check if we're in the news window
      if(minutesBeforeNews >= -NewsBlockMinutesBefore && minutesBeforeNews <= NewsBlockMinutesAfter) {
         Print("TMB: News filter blocking - Within news window (", hour, ":", minute, " near ", newsHour, ":", newsMin, ")");
         return false; // Block trading during news
      }
   }
   
   // Method 2: Spread-based news detection
   if(UseSpreadBasedNewsDetection && spreadHistoryCount >= 5) {
      // Calculate average spread
      double avgSpread = 0.0;
      for(int i = 0; i < spreadHistoryCount; i++) {
         avgSpread += spreadHistory[i];
      }
      avgSpread = avgSpread / (double)spreadHistoryCount;
      
      // Get current spread
      double currentSpread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
      
      // Check if current spread is abnormally wide (indicating news)
      double spreadBaseline = (NormalSpreadBaseline > 0) ? NormalSpreadBaseline : avgSpread;
      if(currentSpread > (spreadBaseline * NewsSpreadMultiplier)) {
         lastNewsBlockTime = currentTime;
         Print("TMB: News filter blocking - Spread widened to ", DoubleToString(currentSpread, 1), 
               " points (", DoubleToString((currentSpread/spreadBaseline), 2), "x normal)");
         return false; // Block trading due to spread widening
      }
      
      // Continue blocking for NewsBlockMinutesAfter minutes after spread widening
      // CRITICAL: Don't extend the block period - once the time expires, allow trading
      if(lastNewsBlockTime > 0) {
         int secondsSinceNews = (int)(currentTime - lastNewsBlockTime);
         if(secondsSinceNews < (NewsBlockMinutesAfter * 60)) {
            return false; // Still in news block period
         } else {
            // Block period has expired - reset timer and allow trading
            // This prevents indefinite blocking from repeated spread triggers
            lastNewsBlockTime = 0;
            return true; // Block period expired, allow trading
         }
      }
   }
   
   return true; // No news detected, allow trading
}

// Volatility Detection: Check for spread widening or ATR expansion
bool CheckVolatilityExpansion(bool& spreadExpanded, bool& atrExpanded) {
   spreadExpanded = false;
   atrExpanded = false;
   
   if(!UseVolatilityStop) return false;
   
   // Check spread widening
   double currentSpread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(normalSpreadBaseline > 0.0 && currentSpread >= (normalSpreadBaseline * VolatilitySpreadMultiplier)) {
      spreadExpanded = true;
   }
   
   // Check ATR expansion
   if(atrHandle != INVALID_HANDLE) {
      if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) > 0) {
         double currentATR = atrBuffer[0];
         // Calculate average ATR over recent period (simplified: use current ATR vs baseline)
         // In a more sophisticated implementation, we'd track average ATR
         // For now, we'll use a simple threshold based on current ATR
         if(currentATR > 0.0) {
            // Get price range over ATR period
            double high = iHigh(_Symbol, PERIOD_CURRENT, 0);
            double low = iLow(_Symbol, PERIOD_CURRENT, 0);
            for(int i = 1; i < ATRPeriod && i < Bars(_Symbol, PERIOD_CURRENT); i++) {
               double h = iHigh(_Symbol, PERIOD_CURRENT, i);
               double l = iLow(_Symbol, PERIOD_CURRENT, i);
               if(h > high) high = h;
               if(l < low) low = l;
            }
            double priceRange = (high - low) / _Point;
            double avgATR = currentATR / _Point;
            
            // ATR expansion: current range significantly exceeds average ATR
            if(avgATR > 0.0 && priceRange >= (avgATR * VolatilityATRMultiplier)) {
               atrExpanded = true;
            }
         }
      }
   }
   
   return (spreadExpanded || atrExpanded);
}

// Helper: Update spread history for news detection
void UpdateSpreadHistory(double currentSpread) {
   if(spreadHistoryCount < 20) {
      spreadHistory[spreadHistoryCount] = currentSpread;
      spreadHistoryCount++;
   } else {
      // Shift array when full
      for(int i = 0; i < 19; i++) {
         spreadHistory[i] = spreadHistory[i+1];
      }
      spreadHistory[19] = currentSpread;
   }
}

// Filter 4: Pattern Quality Scoring - Rate pattern quality 0-100
double CalculatePatternScore(int patternType, int signal, double velocity, double volatility) {
   if(signal == 0) return 0.0;
   
   double score = 0.0;
   
   // Base score from velocity strength (0-50 points)
   double velocityRatio = MathAbs(velocity) / PriceVelocityThreshold;
   score += MathMin(velocityRatio * 25.0, 50.0);
   
   // Bonus for volatility context (0-25 points)
   // Higher volatility during strong moves = better signal
   if(volatility > 0) {
      double volatilityBonus = MathMin((volatility / (PriceVelocityThreshold * 2.0)) * 25.0, 25.0);
      score += volatilityBonus;
   }
   
   // Pattern type bonus (0-25 points)
   // Velocity pattern gets highest base score (primary pattern)
   if(patternType == 1) {
      score += 25.0; // Velocity pattern (primary)
   } else if(patternType == 2) {
      score += 15.0; // Consolidation breakout (secondary)
   } else if(patternType == 3) {
      score += 10.0; // Swing breakout (tertiary)
   }
   
   // Cap at 100
   return MathMin(score, 100.0);
}

// Filter 5: Multi-Pattern Confirmation - Require pattern alignment
int GetMultiPatternSignal(int pattern1Signal, double pattern1Score, int pattern2Signal, double pattern2Score, int pattern3Signal, double pattern3Score) {
   if(!RequireMultiPatternConfirmation) {
      // If multi-pattern confirmation disabled, return first non-zero signal
      if(pattern1Signal != 0 && pattern1Score >= MinPatternScore) return pattern1Signal;
      if(pattern2Signal != 0 && pattern2Score >= MinPatternScore) return pattern2Signal;
      if(pattern3Signal != 0 && pattern3Score >= MinPatternScore) return pattern3Signal;
      return 0;
   }
   
   // Require at least 2 patterns to agree on direction
   int buyVotes = 0;
   int sellVotes = 0;
   
   if(pattern1Signal == 1 && pattern1Score >= MinPatternScore) buyVotes++;
   else if(pattern1Signal == -1 && pattern1Score >= MinPatternScore) sellVotes++;
   
   if(pattern2Signal == 1 && pattern2Score >= MinPatternScore) buyVotes++;
   else if(pattern2Signal == -1 && pattern2Score >= MinPatternScore) sellVotes++;
   
   if(pattern3Signal == 1 && pattern3Score >= MinPatternScore) buyVotes++;
   else if(pattern3Signal == -1 && pattern3Score >= MinPatternScore) sellVotes++;
   
   // Require at least 2 votes for same direction
   if(buyVotes >= 2) return 1;
   if(sellVotes >= 2) return -1;
   
   return 0;
}

// Helper: Get best pattern score
double GetBestPatternScore(double pattern1Score, double pattern2Score, double pattern3Score) {
   double best = 0.0;
   if(pattern1Score > best) best = pattern1Score;
   if(pattern2Score > best) best = pattern2Score;
   if(pattern3Score > best) best = pattern3Score;
   return best;
}

// Filter 6: Momentum Acceleration - Require momentum to be accelerating
bool CheckMomentumAcceleration(int signal) {
   if(!RequireMomentumAcceleration) return true;
   
   datetime currentTime = TimeCurrent();
   double currentPrice = priceHistoryCount > 0 ? priceHistory[priceHistoryCount-1].price : 0.0;
   if(currentPrice <= 0) return false;
   
   double price1sAgo = GetPriceAtTime(currentTime - 1);
   double price2sAgo = GetPriceAtTime(currentTime - 2);
   
   if(price1sAgo <= 0 || price2sAgo <= 0) return false;
   
   double velocity1s = (currentPrice - price1sAgo) / _Point; // Points per second
   double velocity2s = (currentPrice - price2sAgo) / (_Point * 2.0); // Average points per second over 2s
   
   // Check if momentum is accelerating (10% increase required)
   double absVelocity1s = MathAbs(velocity1s);
   double absVelocity2s = MathAbs(velocity2s);
   
   // Momentum must be accelerating (getting stronger)
   if(absVelocity2s > 0 && absVelocity1s > absVelocity2s * 1.1) {
      // Check direction matches signal
      if((signal == 1 && velocity1s > 0) || (signal == -1 && velocity1s < 0)) {
         return true;
      }
   }
   
   return false;
}

int GetHFTMove() {
   // Basic tick speed check (filter for market activity)
   if(currentTicksPerSecond < MinTickSpeed) {
      static datetime lastTickWarning = 0;
      if(TimeCurrent() - lastTickWarning > 10) { // Log every 10 seconds to avoid spam
         Print("TMB: Blocked - Tick speed too low: ", DoubleToString(currentTicksPerSecond, 1), " < ", MinTickSpeed);
         lastTickWarning = TimeCurrent();
      }
      return 0;
   }
   
   // Need sufficient price history
   if(priceHistoryCount < 3) {
      static datetime lastHistoryWarning = 0;
      if(TimeCurrent() - lastHistoryWarning > 10) {
         Print("TMB: Blocked - Insufficient price history: ", priceHistoryCount, " < 3");
         lastHistoryWarning = TimeCurrent();
      }
      return 0;
   }
   
   // Essential filters: Loss Cooldown, Spread, and News Filter
   if(!CheckLossCooldown()) {
      static datetime lastCooldownWarning = 0;
      if(TimeCurrent() - lastCooldownWarning > 5) {
         Print("TMB: Blocked - Loss cooldown active");
         lastCooldownWarning = TimeCurrent();
      }
      return 0;
   }
   if(!CheckSpreadFilter()) {
      static datetime lastSpreadWarning = 0;
      if(TimeCurrent() - lastSpreadWarning > 5) {
         double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
         Print("TMB: Blocked - Spread too high: ", DoubleToString(spread, 1), " > ", MaxSpreadForEntry);
         lastSpreadWarning = TimeCurrent();
      }
      return 0;
   }
   if(!CheckNewsFilter()) {
      static datetime lastNewsWarning = 0;
      if(TimeCurrent() - lastNewsWarning > 5) {
         Print("TMB: Blocked - News filter active");
         lastNewsWarning = TimeCurrent();
      }
      return 0;
   }
   
   datetime currentTime = TimeCurrent();
   double currentPrice = priceHistory[priceHistoryCount-1].price;
   
   // SIMPLIFIED: Just check patterns, take first signal found
   // Pattern 1: Price Velocity (Primary - fastest)
   int signal = CheckPriceVelocity(currentPrice, currentTime);
   if(signal != 0) {
      Print("TMB: Signal detected - Price Velocity: ", (signal == 1 ? "BUY" : "SELL"));
      return signal;
   }
   
   // Pattern 2: Consolidation Breakout
   signal = CheckConsolidationBreakout(currentPrice, currentTime);
   if(signal != 0) {
      Print("TMB: Signal detected - Consolidation Breakout: ", (signal == 1 ? "BUY" : "SELL"));
      return signal;
   }
   
   // Pattern 3: Swing Breakout
   signal = CheckSwingBreakout(currentPrice, currentTime);
   if(signal != 0) {
      Print("TMB: Signal detected - Swing Breakout: ", (signal == 1 ? "BUY" : "SELL"));
      return signal;
   }
   
   return 0;
   }
   
// Pattern 1: Price Velocity (Momentum Burst)
int CheckPriceVelocity(double currentPrice, datetime currentTime) {
   if(priceHistoryCount < 3) return 0;
   
   // Calculate velocity over different time periods
   double velocity1s = 0.0;
   double velocity2s = 0.0;
   
   // Find prices at different time intervals
   double price1sAgo = GetPriceAtTime(currentTime - 1);
   double price2sAgo = GetPriceAtTime(currentTime - 2);
   
   if(price1sAgo > 0) {
      velocity1s = (currentPrice - price1sAgo) / _Point; // Points per second
   }
   if(price2sAgo > 0) {
      velocity2s = (currentPrice - price2sAgo) / (_Point * 2.0); // Average points per second over 2s
   }
   
   // Check if velocity exceeds threshold - use velocity1s as primary, velocity2s as confirmation (relaxed to 50% for more entries)
   if(velocity1s >= PriceVelocityThreshold && velocity2s >= PriceVelocityThreshold * 0.5) {
      return 1; // Bullish momentum burst
   }
   if(velocity1s <= -PriceVelocityThreshold && velocity2s <= -PriceVelocityThreshold * 0.5) {
      return -1; // Bearish momentum burst
   }
   
   return 0;
}

// Pattern 2: Consolidation Breakout
int CheckConsolidationBreakout(double currentPrice, datetime currentTime) {
   if(priceHistoryCount < SwingPeriod) return 0;
   
   // Detect consolidation: price in tight range
   double recentHigh = currentPrice;
   double recentLow = currentPrice;
   
   int checkCount = MathMin(SwingPeriod, priceHistoryCount);
   for(int i = priceHistoryCount - checkCount; i < priceHistoryCount; i++) {
      if(priceHistory[i].price > recentHigh) recentHigh = priceHistory[i].price;
      if(priceHistory[i].price < recentLow) recentLow = priceHistory[i].price;
   }
   
   double consolidationSpread = (recentHigh - recentLow) / _Point;
   
   // Check if we're in consolidation (tight range)
   if(consolidationSpread > ConsolidationMaxSpread) {
      return 0; // Not in consolidation
   }
   
   // Check for breakout above consolidation
   if(currentPrice > recentHigh + (BreakoutMinPoints * _Point)) {
      return 1; // Bullish consolidation breakout
   }
   
   // Check for breakout below consolidation
   if(currentPrice < recentLow - (BreakoutMinPoints * _Point)) {
      return -1; // Bearish consolidation breakout
   }
   
   return 0;
}

// Pattern 3: Swing High/Low Breakout
int CheckSwingBreakout(double currentPrice, datetime currentTime) {
   if(priceHistoryCount < SwingPeriod) return 0;
   
   // Find swing high and low over the period
   double swingHigh = currentPrice;
   double swingLow = currentPrice;
   
   int checkCount = MathMin(SwingPeriod, priceHistoryCount);
   for(int i = priceHistoryCount - checkCount; i < priceHistoryCount; i++) {
      if(priceHistory[i].price > swingHigh) swingHigh = priceHistory[i].price;
      if(priceHistory[i].price < swingLow) swingLow = priceHistory[i].price;
   }
   
   double range = (swingHigh - swingLow) / _Point;
   
   // Check for breakout above swing high
   if(currentPrice > swingHigh + (BreakoutMinPoints * _Point)) {
      return 1; // Bullish breakout
   }
   
   // Check for breakout below swing low
   if(currentPrice < swingLow - (BreakoutMinPoints * _Point)) {
      return -1; // Bearish breakout
   }
   
   return 0;
}

// Confirmation: Time-Based Velocity Confirmation
bool ConfirmWithVelocity(double currentPrice, datetime currentTime) {
   if(priceHistoryCount < 3) return false;
   
   // Calculate velocity over confirmation window
   double priceAtWindow = GetPriceAtTime(currentTime - (int)VelocityConfirmationSeconds);
   if(priceAtWindow <= 0) return false;
   
   double velocity = (currentPrice - priceAtWindow) / (_Point * VelocityConfirmationSeconds);
   
   // Velocity must exceed threshold AND be accelerating
   if(MathAbs(velocity) >= PriceVelocityThreshold * 0.7) {
      // Check if velocity is accelerating (getting stronger) - compare with shorter window
      double price1sAgo = GetPriceAtTime(currentTime - 1);
      if(price1sAgo > 0) {
         double recentVelocity = (currentPrice - price1sAgo) / _Point; // Points per second
         // Velocity should be strong or accelerating
         if(MathAbs(recentVelocity) >= MathAbs(velocity) * 0.8) {
            return true;
         }
      }
   }
   
      return false;
}


// Helper function: Get price at specific time (or closest)
double GetPriceAtTime(datetime targetTime) {
   double closestPrice = 0.0;
   long minTimeDiff = LONG_MAX;
   
   for(int i = 0; i < priceHistoryCount; i++) {
      long timeDiff = MathAbs((long)(priceHistory[i].time - targetTime));
      if(timeDiff < minTimeDiff) {
         minTimeDiff = timeDiff;
         closestPrice = priceHistory[i].price;
      }
   }
   
   // Only return if within reasonable time range (within 2 seconds)
   if(minTimeDiff <= 2) {
      return closestPrice;
   }
   
   return 0.0;
}

// =====================================================================================================
// RISK MANAGEMENT HELPERS
// =====================================================================================================

double CalculateLossLimit() {
   if(!UseConsecutiveWinLossLimit || consecutiveWins <= 0) return 0.0;
   
   // Calculate sum of recent basket profits
   double totalRecentProfit = 0.0;
   int profitCount = 0;
   for(int i = 0; i < 10; i++) {
      if(recentBasketProfits[i] > 0) {
         totalRecentProfit += recentBasketProfits[i];
         profitCount++;
      }
   }
   
   if(totalRecentProfit <= 0) return MinLossLimitDollars;
   
   // Calculate loss limit: (Total profit * % per win) * consecutive wins
   double lossLimit = (totalRecentProfit * (LossLimitPerWinPercent / 100.0)) * consecutiveWins;
   
   // Ensure minimum loss limit
   if(lossLimit < MinLossLimitDollars) {
      lossLimit = MinLossLimitDollars;
   }
   
   return lossLimit;
}


// =====================================================================================================
// TRADE MANAGEMENT (THE "BETTER" EXIT)
// =====================================================================================================

void ManageActiveExits() {
   // Sync tracked trades with actual positions periodically
   SyncWithExistingPositions();
   
   // Remove invalid trades from tracking array
   for(int i = activeTradeCount - 1; i >= 0; i--) {
      if(!PositionSelectByTicket(activeTrades[i].ticket)) {
         RemoveTrade(i);
         // Reset basket direction if no trades remain
         if(activeTradeCount == 0) {
            basketDirection = 0;
            basketFirstProfitTime = 0; // Reset profit timer when basket is empty
         }
      }
   }
   
   // If no active trades, reset profit timer and basket tracking
   if(activeTradeCount == 0) {
      basketFirstProfitTime = 0;
      basketStartTime = 0;
      basketStartCapital = 0.0;
      basketMinEquity = 0.0;
      basketMaxDrawdown = 0.0;
      basketMaxLossDollars = 0.0;
      basketEntryPrice = 0.0;
      directionalBiasLocked = false;
      lockedDirection = 0;
      return;
   }
   
   // Track basket drawdown if basket is active
   if(basketStartTime > 0 && basketStartCapital > 0) {
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      
      // Update minimum equity
      if(basketMinEquity == 0.0 || currentEquity < basketMinEquity) {
         basketMinEquity = currentEquity;
      }
      
      // Calculate current drawdown percentage
      if(basketStartCapital > 0) {
         double currentDrawdown = ((basketStartCapital - basketMinEquity) / basketStartCapital) * 100.0;
         if(currentDrawdown > basketMaxDrawdown) {
            basketMaxDrawdown = currentDrawdown;
         }
      }
   }
   
   // =====================================================================
   // LOSS-AWARE EXIT LOGIC (Statistical Survival)
   // Replaces profit-only assumption with loss-aware exits
   // =====================================================================
   
   // Calculate total basket profit from ALL actual positions
   double totalProfit = 0.0;
   double totalEntryValue = 0.0;
   double totalLotSize = 0.0;
   int totalPositions = PositionsTotal();
   
   for(int j = totalPositions - 1; j >= 0; j--) {
      ulong ticket = PositionGetTicket(j);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            totalEntryValue += PositionGetDouble(POSITION_PRICE_OPEN) * PositionGetDouble(POSITION_VOLUME);
            totalLotSize += PositionGetDouble(POSITION_VOLUME);
         }
      }
   }
   
   // Calculate average basket entry price (for directional bias lock)
   if(totalLotSize > 0.0 && basketDirection != 0) {
      basketEntryPrice = totalEntryValue / totalLotSize;
   }
   
   // Calculate current price movement against basket (for directional bias lock)
   if(UseDirectionalBiasLock && basketDirection != 0 && basketEntryPrice > 0.0) {
      double currentPrice = (basketDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double priceDiff = 0.0;
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double pipValue = (digits == 3 || digits == 5) ? (_Point * 10.0) : _Point;
      
      if(basketDirection == 1) {
         // BUY basket - check if price moved down against us
         priceDiff = (basketEntryPrice - currentPrice) / pipValue;
         if(priceDiff >= BiasLockPointsAgainst) {
            directionalBiasLocked = true;
            lockedDirection = 1; // Lock BUY entries
            Print("TMB: Directional bias lock activated - Price moved ", DoubleToString(priceDiff, 1), " points against BUY basket");
         }
      } else if(basketDirection == -1) {
         // SELL basket - check if price moved up against us
         priceDiff = (currentPrice - basketEntryPrice) / pipValue;
         if(priceDiff >= BiasLockPointsAgainst) {
            directionalBiasLocked = true;
            lockedDirection = -1; // Lock SELL entries
            Print("TMB: Directional bias lock activated - Price moved ", DoubleToString(priceDiff, 1), " points against SELL basket");
         }
      }
   }
   
   // =====================================================================
   // PROFIT-ONLY EXIT LOGIC: Close only when ALL trades are profitable
   // =====================================================================
   
   // Check if ALL individual trades are profitable
   bool allTradesProfitable = true;
   int negativeTradeCount = 0;
   double minTradeProfit = 0.0;
   
   for(int j = totalPositions - 1; j >= 0; j--) {
      ulong ticket = PositionGetTicket(j);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            double tradeProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            
            // #region agent log
            Print("TMB DEBUG H2: Trade ", ticket, " profit: $", DoubleToString(tradeProfit, 2), ", Total: $", DoubleToString(totalProfit, 2));
            // #endregion
            
            if(tradeProfit <= 0.0) {
               allTradesProfitable = false;
               negativeTradeCount++;
               if(minTradeProfit == 0.0 || tradeProfit < minTradeProfit) {
                  minTradeProfit = tradeProfit;
               }
            }
         }
      }
   }
   
   // #region agent log
   Print("TMB DEBUG H3: Total profit: $", DoubleToString(totalProfit, 2), ", All profitable: ", (allTradesProfitable ? "YES" : "NO"), ", Negative trades: ", negativeTradeCount, ", Min trade profit: $", DoubleToString(minTradeProfit, 2));
   // #endregion
   
   // Only proceed with profit exit if ALL trades are profitable AND total is positive
   if(totalProfit > 0.0 && allTradesProfitable) {
      if(basketFirstProfitTime == 0) {
         basketFirstProfitTime = TimeCurrent();
         Print("TMB: All trades profitable: $", DoubleToString(totalProfit, 2), " - Timer started (", ProfitExitSeconds, " seconds)");
      } else {
         int profitDurationSeconds = (int)(TimeCurrent() - basketFirstProfitTime);
         if(profitDurationSeconds >= ProfitExitSeconds) {
            // Double-check all trades are still profitable before closing
            bool stillAllProfitable = true;
            for(int j = totalPositions - 1; j >= 0; j--) {
               ulong ticket = PositionGetTicket(j);
               if(ticket > 0 && PositionSelectByTicket(ticket)) {
                  if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
                     PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
                     double tradeProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
                     if(tradeProfit <= 0.0) {
                        stillAllProfitable = false;
                        Print("TMB: Trade ", ticket, " is negative ($", DoubleToString(tradeProfit, 2), ") - Pausing close until all profitable");
                        break;
                     }
                  }
               }
            }
            
            if(stillAllProfitable) {
               Print("TMB: All trades profitable for ", profitDurationSeconds, " seconds ($", DoubleToString(totalProfit, 2), ") - Closing all trades");
               CloseAllTrades();
               return;
            } else {
               // Reset timer if any trade became negative
               basketFirstProfitTime = 0;
               Print("TMB: Close paused - waiting for all trades to be profitable again");
            }
         }
      }
   } else {
      // Reset profit timer if basket becomes unprofitable OR any trade is negative
      if(basketFirstProfitTime != 0) {
         if(!allTradesProfitable) {
            Print("TMB: Profit timer reset - ", negativeTradeCount, " trade(s) negative (min: $", DoubleToString(minTradeProfit, 2), ")");
         } else {
            Print("TMB: Profit timer reset - Total basket unprofitable");
         }
         basketFirstProfitTime = 0;
      }
   }
}

void CloseAllTrades() {
   // Calculate total profit BEFORE closing (for loss cooldown tracking)
   double totalProfit = 0.0;
   int totalPositions = PositionsTotal();
   for(int j = totalPositions - 1; j >= 0; j--) {
      ulong ticket = PositionGetTicket(j);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         }
      }
   }
   
   // Track last close time and profit/loss state
   lastBasketCloseTime = TimeCurrent();
   lastBasketCloseProfit = totalProfit;
   
   // Set forced loss cooldown if this was a forced loss exit
   if(UseForcedLossCooldown && lastCloseWasForcedLoss) {
      forcedLossCooldownUntil = TimeCurrent() + ForcedLossCooldownSeconds;
      Print("TMB: Forced loss cooldown activated until ", TimeToString(forcedLossCooldownUntil, TIME_SECONDS), " (", ForcedLossCooldownSeconds, " seconds)");
   } else {
      forcedLossCooldownUntil = 0;
   }
   
   // Reset basket tracking variables
   basketStartTime = 0;
   basketStartCapital = 0.0;
   basketMinEquity = 0.0;
   basketMaxDrawdown = 0.0;
   basketMaxLossDollars = 0.0;
   
   // Update consecutive win tracking
   if(UseConsecutiveWinLossLimit) {
      if(totalProfit > 0) {
         // Winning basket - increment consecutive wins
         consecutiveWins++;
         // Store profit in circular buffer
         recentBasketProfits[recentBasketIndex] = totalProfit;
         recentBasketIndex = (recentBasketIndex + 1) % 10;
      } else {
         // Losing basket - reset consecutive wins
         consecutiveWins = 0;
      }
   }
   
   // Close all positions matching our symbol and magic number simultaneously
   // Iterate through all positions and close matching ones in one pass - maximum speed
   for(int i = totalPositions - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            // Close immediately - all closes sent in rapid succession
            trade.PositionClose(ticket);
         }
      }
   }
   
   // Clear the active trades array after all closes are sent
   activeTradeCount = 0;
   for(int i = 0; i < 50; i++) {
      activeTrades[i].ticket = 0;
   }
   
   // Reset basket direction and profit timer when all trades are closed
   basketDirection = 0;
   basketFirstProfitTime = 0;
   basketEntryPrice = 0.0;
   directionalBiasLocked = false;
   lockedDirection = 0;
}

// =====================================================================================================
// DISPLAY - Enhanced Visual Status with Panel
// =====================================================================================================

void CreateDisplayPanel() {
   // Create sky blue background rectangle - set to BACK so text appears on top
   if(ObjectFind(0, "TMB_DisplayPanel") < 0) {
      ObjectCreate(0, "TMB_DisplayPanel", OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_YDISTANCE, 30);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_XSIZE, 630);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_YSIZE, 455);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_BGCOLOR, C'135,206,235');  // Sky blue background
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_COLOR, C'70,130,180');  // Steel blue border
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_BACK, true);  // Put panel behind text
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_SELECTED, false);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_HIDDEN, true);
   } else {
      // Update size and color if exists
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_XSIZE, 630);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_YSIZE, 455);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_BGCOLOR, C'135,206,235');  // Sky blue
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_BACK, true);  // Ensure it's behind text
   }
}

void UpdateDisplay() {
   // Ensure panel exists
   if(ObjectFind(0, "TMB_DisplayPanel") < 0) {
      CreateDisplayPanel();
   }
   
   string status = "=== Tick Momentum Basket Scalper ===\n";
   
   // Signal Status
   int overallSignal = GetHFTMove();
   status += "Signal: ";
   if(overallSignal == 1) status += "BUY\n";
   else if(overallSignal == -1) status += "SELL\n";
   else status += "WAITING\n";
   
   // Directional Bias Lock Status
   if(UseDirectionalBiasLock && directionalBiasLocked) {
      status += "Bias Lock: " + (lockedDirection == 1 ? "BUY" : "SELL") + " [LOCKED]\n";
   }
   
   // Market Conditions
   status += "Tick: " + DoubleToString(currentTicksPerSecond, 1);
   if(currentTicksPerSecond < MinTickSpeed) status += " [LOW]\n";
   else status += " [OK]\n";
   
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   status += "Spread: " + DoubleToString(spread, 1);
   if(spread > MaxSpreadForEntry) status += " [HIGH]\n";
   else status += " [OK]\n";
   
   status += "Vol: " + DoubleToString(currentVolatility, 1);
   if(currentVolatility < MinVolatilityForEntry) status += " [LOW]\n";
   else status += " [OK]\n";
   
   // Active Trades
   int dynamicMaxTrades = CalculateDynamicMaxTrades();
   status += "Trades: " + IntegerToString(activeTradeCount) + "/" + IntegerToString(dynamicMaxTrades) + "\n";
   
   // Progressive Lot Sizing Status
   string phaseStatus = "";
   if(totalTradesOpened < SafeTradeCount) {
      phaseStatus = "Phase 1 (SAFE): " + IntegerToString(totalTradesOpened) + "/" + IntegerToString(SafeTradeCount) + " trades";
   } else {
      phaseStatus = "Phase 2 (AGGRESSIVE): " + IntegerToString(totalTradesOpened) + " trades";
      if(UseHTFTrendMaxLot) {
         string trendStr = "NEUTRAL";
         if(htfTrendDirection == 1) trendStr = "UP";
         else if(htfTrendDirection == -1) trendStr = "DOWN";
         phaseStatus += " | HTF: " + trendStr;
      }
   }
   status += "Lot Sizing: " + phaseStatus + "\n";
   
   // Basket P&L if trades exist
   if(activeTradeCount > 0) {
      double totalBasketProfit = 0.0;
      int totalPositions = PositionsTotal();
      for(int j = totalPositions - 1; j >= 0; j--) {
         ulong ticket = PositionGetTicket(j);
         if(ticket > 0 && PositionSelectByTicket(ticket)) {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
               PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
               totalBasketProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            }
         }
      }
      
      status += "P&L: $" + DoubleToString(totalBasketProfit, 2);
      if(totalBasketProfit > 0.0 && basketFirstProfitTime > 0) {
         int profitDuration = (int)(TimeCurrent() - basketFirstProfitTime);
         status += " (" + IntegerToString(profitDuration) + "/" + IntegerToString(ProfitExitSeconds) + "s)";
      }
      status += "\n";
   }
   
   // Entry Blocking Reasons (if no signal)
   if(overallSignal == 0) {
      string blockingReasons = "";
      bool lossCooldownOK = CheckLossCooldown();
      bool spreadOK = CheckSpreadFilter();
      bool volatilityOK = (currentVolatility >= MinVolatilityForEntry);
      bool newsOK = CheckNewsFilter();
      
      if(currentTicksPerSecond < MinTickSpeed) blockingReasons += "TickLow ";
      if(priceHistoryCount < 3) blockingReasons += "NoData ";
      if(!lossCooldownOK) {
         int secondsSinceClose = (int)(TimeCurrent() - lastBasketCloseTime);
         blockingReasons += "Cooldown(" + IntegerToString(secondsSinceClose) + "s) ";
      }
      if(!spreadOK) blockingReasons += "SpreadHigh ";
      if(!volatilityOK) blockingReasons += "VolLow ";
      if(!newsOK) blockingReasons += "News ";
      if(UseDirectionalBiasLock && directionalBiasLocked) {
         blockingReasons += "BiasLock(" + (lockedDirection == 1 ? "BUY" : "SELL") + ") ";
      }
      
      datetime currentTime = TimeCurrent();
      double currentPrice = priceHistoryCount > 0 ? priceHistory[priceHistoryCount-1].price : 0.0;
      int pattern1Signal = 0, pattern2Signal = 0, pattern3Signal = 0;
      if(priceHistoryCount >= 3) {
         pattern1Signal = CheckPriceVelocity(currentPrice, currentTime);
         pattern2Signal = CheckConsolidationBreakout(currentPrice, currentTime);
         pattern3Signal = CheckSwingBreakout(currentPrice, currentTime);
      }
      if(pattern1Signal == 0 && pattern2Signal == 0 && pattern3Signal == 0) blockingReasons += "NoPattern";
      
      if(StringLen(blockingReasons) > 0) {
         status += "Blocked: " + blockingReasons + "\n";
      }
   }
   
   // Account
   status += "Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n";
   status += "Equity: $" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2);
   
   // Drawdown Stop Loss Status
   if(UseDrawdownStopLoss) {
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(highestEquity > 0.0) {
         double drawdownPercent = ((highestEquity - currentEquity) / highestEquity) * 100.0;
         status += "\nDrawdown: " + DoubleToString(drawdownPercent, 2) + "% / " + DoubleToString(MaxDrawdownPercent, 1) + "%";
         if(drawdownStopLossTriggered) {
            status += " [STOPPED]";
         } else if(drawdownPercent >= MaxDrawdownPercent * 0.8) {
            status += " [WARNING]";
         }
      }
   }
   
   Comment(status);
}

// =====================================================================================================
// UTILITIES
// =====================================================================================================

// Check Higher Timeframe Trend
// Returns: 1 for uptrend, -1 for downtrend, 0 for neutral/no trend
int CheckHTFTrend() {
   if(!UseHTFTrendMaxLot) return 0;
   
   // Use H4 timeframe as HTF (4-hour chart)
   ENUM_TIMEFRAMES htfPeriod = PERIOD_H4;
   
   // Get close prices on HTF using CopyClose
   double closeBuffer[];
   ArraySetAsSeries(closeBuffer, true);
   if(CopyClose(_Symbol, htfPeriod, 0, 3, closeBuffer) < 3) {
      return 0;  // Failed to get data
   }
   
   double close0 = closeBuffer[0];
   double close1 = closeBuffer[1];
   double close2 = closeBuffer[2];
   
   if(close0 <= 0 || close1 <= 0 || close2 <= 0) return 0;
   
   // Simple trend detection: compare recent closes
   // Uptrend: higher highs and higher lows
   // Downtrend: lower highs and lower lows
   bool higherHighs = (close0 > close1) && (close1 > close2);
   bool lowerLows = (close0 < close1) && (close1 < close2);
   
   // Also check moving average for additional confirmation
   int maHandle = iMA(_Symbol, htfPeriod, 50, 0, MODE_SMA, PRICE_CLOSE);
   if(maHandle == INVALID_HANDLE) {
      // Fallback to simple price comparison
      if(higherHighs) return 1;
      if(lowerLows) return -1;
      return 0;
   }
   
   double maBuffer[];
   ArraySetAsSeries(maBuffer, true);
   if(CopyBuffer(maHandle, 0, 0, 2, maBuffer) < 2) {
      IndicatorRelease(maHandle);
      // Fallback to simple price comparison
      if(higherHighs) return 1;
      if(lowerLows) return -1;
      return 0;
   }
   
   // Trend is up if price is above MA and making higher highs
   // Trend is down if price is below MA and making lower lows
   bool priceAboveMA = close0 > maBuffer[0];
   bool priceBelowMA = close0 < maBuffer[0];
   
   IndicatorRelease(maHandle);
   
   if(priceAboveMA && higherHighs) return 1;  // Uptrend
   if(priceBelowMA && lowerLows) return -1;    // Downtrend
   
   return 0;  // Neutral/no clear trend
}

double CalculateLotSize(int tradeDirection) {
   // =====================================================================
   // PROGRESSIVE LOT SIZING: Two-Phase Approach
   // Phase 1: First 10 trades - Safe Micro Lots (1% risk)
   // Phase 2: After 10 trades - Trend-Based Aggressive Sizing
   // =====================================================================
   
   // PHASE 1: Safe Micro Lots (First 10 trades)
   if(totalTradesOpened < SafeTradeCount) {
      Print("TMB: Phase 1 (SAFE) - Trade #", totalTradesOpened + 1, "/", SafeTradeCount, " - Using ", DoubleToString(SafeTradeRiskPercent, 1), "% risk");
      
      // Force safe risk percentage
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmount = balance * (SafeTradeRiskPercent / 100.0);
      
      // Calculate stop loss distance in pips
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double pipValue = (digits == 3 || digits == 5) ? (_Point * 10.0) : _Point;
      double stopLossDistance = LotSizingStopLossPips * pipValue;
      
      // Calculate lot size based on safe risk
      double lotSize = 0.0;
      if(stopLossDistance > 0.0) {
         // Get pip value per lot for this symbol
         double pipValuePerLot = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         
         // For 5-digit brokers, convert if needed
         if(digits == 3 || digits == 5) {
            double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
            if(contractSize > 0 && pipValuePerLot > 0) {
               if(pipValuePerLot < 0.1) {
                  pipValuePerLot = pipValuePerLot * 10.0; // Convert point value to pip value
               }
            }
         }
         
         // If pip value is still 0 or invalid, use fallback
         if(pipValuePerLot <= 0.0) {
            if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
               pipValuePerLot = 1.0;
            else
               pipValuePerLot = 1.0; // Default fallback
         }
         
         // Calculate lot size: riskAmount / (stopLossInPips * pipValuePerLot)
         double stopLossInPips = LotSizingStopLossPips;
         if(stopLossInPips <= 0.0) stopLossInPips = 100.0; // Default to 100 pips
         
         lotSize = riskAmount / (stopLossInPips * pipValuePerLot);
         
         Print("TMB: Safe phase lot calculation - Risk: $", DoubleToString(riskAmount, 2), 
               ", SL: ", DoubleToString(stopLossInPips, 1), " pips, Calculated Lot: ", DoubleToString(lotSize, 4));
      } else {
         lotSize = MinLotSize;
         Print("TMB WARNING: Safe phase lot calculation failed, using minimum: ", DoubleToString(lotSize, 4));
      }
      
      // Normalize and validate lot size
      if(lotSize <= 0.0) lotSize = MinLotSize;
      
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      
      lotSize = MathMax(MinLotSize, lotSize);
      lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
      
      if(lotStep > 0.0) {
         lotSize = MathFloor(lotSize / lotStep) * lotStep;
      }
      
      // Check margin (conservative check for safe phase)
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(freeMargin > 0.0) {
         double marginRequired = 0.0;
         ENUM_ORDER_TYPE orderType = (tradeDirection == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         double price = (tradeDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         
         if(OrderCalcMargin(orderType, _Symbol, lotSize, price, marginRequired)) {
            double maxMarginToUse = freeMargin * 0.8;
            if(marginRequired > maxMarginToUse) {
               double testLotSize = lotSize;
               double step = lotStep > 0.0 ? lotStep : 0.01;
               
               while(testLotSize >= MinLotSize && marginRequired > maxMarginToUse) {
                  testLotSize = testLotSize - step;
                  if(testLotSize < MinLotSize) {
                     testLotSize = MinLotSize;
                     break;
                  }
                  if(!OrderCalcMargin(orderType, _Symbol, testLotSize, price, marginRequired)) {
                     break;
                  }
               }
               lotSize = testLotSize;
            }
         }
      }
      
      if(lotStep > 0.0) {
         lotSize = MathFloor(lotSize / lotStep) * lotStep;
      }
      
      return NormalizeDouble(lotSize, 2);
   }
   
   // PHASE 2: Trend-Based Aggressive Sizing (After 10 trades)
   Print("TMB: Phase 2 (AGGRESSIVE) - Trade #", totalTradesOpened + 1, " - Checking HTF trend alignment");
   
   // Check HTF trend alignment
   htfTrendDirection = CheckHTFTrend();
   bool trendAligned = false;
   
   if(htfTrendDirection != 0) {
      // Check if trend direction matches trade direction
      trendAligned = (htfTrendDirection == tradeDirection);
      Print("TMB: HTF Trend Direction: ", (htfTrendDirection == 1 ? "UP" : "DOWN"), 
            ", Trade Direction: ", (tradeDirection == 1 ? "BUY" : "SELL"),
            ", Aligned: ", (trendAligned ? "YES" : "NO"));
   } else {
      Print("TMB: HTF Trend: NEUTRAL - Using safe risk");
   }
   
   // If trend aligns, use maximum margin trade (90% of free margin)
   if(trendAligned && UseHTFTrendMaxLot) {
      Print("TMB: Trend confirmed - Using MAXIMUM MARGIN trade (90% of free margin)");
      
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(freeMargin > 0.0) {
         double maxMarginToUse = freeMargin * 0.9;  // 90% of available margin
         
         ENUM_ORDER_TYPE orderType = (tradeDirection == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         double price = (tradeDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         
         // Binary search for maximum lot size that fits within 90% margin
         double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
         
         double testLotSize = maxLot;
         double marginRequired = 0.0;
         double step = lotStep > 0.0 ? lotStep : 0.01;
         
         // Start from max lot and work down until margin fits
         while(testLotSize >= minLot) {
            if(OrderCalcMargin(orderType, _Symbol, testLotSize, price, marginRequired)) {
               if(marginRequired <= maxMarginToUse) {
                  // Found maximum lot size that fits
                  break;
               }
            }
            testLotSize = testLotSize - step;
            if(testLotSize < minLot) {
               testLotSize = minLot;
               break;
            }
         }
         
         // Ensure minimum lot size
         if(testLotSize < MinLotSize) testLotSize = MinLotSize;
         
         // Round to lot step
         if(lotStep > 0.0) {
            testLotSize = MathFloor(testLotSize / lotStep) * lotStep;
         }
         
         Print("TMB: Maximum margin lot size: ", DoubleToString(testLotSize, 4), 
               " (Margin: $", DoubleToString(marginRequired, 2), "/$", DoubleToString(maxMarginToUse, 2), ")");
         
         return NormalizeDouble(testLotSize, 2);
      }
   }
   
   // If trend does NOT align, continue with safe risk (1%)
   Print("TMB: Trend NOT aligned - Using safe risk (", DoubleToString(SafeTradeRiskPercent, 1), "%)");
   
   // RISK-BASED LOT SIZING: Calculate lot size based on safe risk percentage
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (SafeTradeRiskPercent / 100.0);
   
   // Calculate stop loss distance in pips (hard coded to 100 pips)
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipValue = (digits == 3 || digits == 5) ? (_Point * 10.0) : _Point;
   double stopLossDistance = LotSizingStopLossPips * pipValue;
   
   // Calculate lot size based on risk
   double lotSize = 0.0;
   if(stopLossDistance > 0.0) {
      // Get pip value per lot for this symbol
      double pipValuePerLot = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      
      // For 5-digit brokers, convert if needed
      if(digits == 3 || digits == 5) {
         double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
         if(contractSize > 0 && pipValuePerLot > 0) {
            if(pipValuePerLot < 0.1) {
               pipValuePerLot = pipValuePerLot * 10.0; // Convert point value to pip value
            }
         }
      }
      
      // If pip value is still 0 or invalid, use fallback
      if(pipValuePerLot <= 0.0) {
         // Fallback: For gold, assume $1 per pip per lot; for FX, use contract size
         if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
            pipValuePerLot = 1.0;
         else
            pipValuePerLot = 1.0; // Default fallback
      }
      
      // Calculate lot size: riskAmount / (stopLossInPips * pipValuePerLot)
      double stopLossInPips = LotSizingStopLossPips;
      if(stopLossInPips <= 0.0) stopLossInPips = 100.0; // Default to 100 pips
      
      lotSize = riskAmount / (stopLossInPips * pipValuePerLot);
      
      Print("TMB: Risk-based lot calculation - Risk: $", DoubleToString(riskAmount, 2), 
            ", SL: ", DoubleToString(stopLossInPips, 1), " pips, PipValue: $", DoubleToString(pipValuePerLot, 2),
            ", Calculated Lot: ", DoubleToString(lotSize, 4));
   } else {
      // Fallback: if calculation fails, use minimum lot size
      lotSize = MinLotSize;
      Print("HFT WARNING: Lot sizing calculation failed, using minimum lot size: ", DoubleToString(lotSize, 4));
   }
   
   // CRITICAL: Ensure lot size is valid (not 0 or negative)
   if(lotSize <= 0.0) {
      // Ultimate fallback: use minimum lot size
      lotSize = MinLotSize;
      Print("TMB WARNING: Invalid lot size, using minimum: ", DoubleToString(lotSize, 4));
   }
   
   // Normalize lot size
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   // Apply safety limits
   lotSize = MathMax(MinLotSize, lotSize);
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   
   // Round to lot step
   if(lotStep > 0.0) {
      lotSize = MathFloor(lotSize / lotStep) * lotStep;
   }
   
   // CRITICAL: Check available margin and cap lot size to what account can afford
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   
   if(freeMargin > 0.0) {
      // Use MT5's OrderCalcMargin to calculate actual margin required for this lot size
      double marginRequired = 0.0;
      ENUM_ORDER_TYPE orderType = (tradeDirection == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double price = (tradeDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      
      if(OrderCalcMargin(orderType, _Symbol, lotSize, price, marginRequired)) {
         // Check if we have enough margin (leave 20% buffer - more conservative than 10%)
         double maxMarginToUse = freeMargin * 0.8;
         
         if(marginRequired > maxMarginToUse) {
            // Calculate maximum lot size we can afford
            // Use binary search approach: try smaller lot sizes until margin fits
            double testLotSize = lotSize;
            double step = lotStep > 0.0 ? lotStep : 0.01;
            
            while(testLotSize >= MinLotSize && marginRequired > maxMarginToUse) {
               testLotSize = testLotSize - step;
               if(testLotSize < MinLotSize) {
                  testLotSize = MinLotSize;
                  break;
               }
               // Check return value of OrderCalcMargin
               if(!OrderCalcMargin(orderType, _Symbol, testLotSize, price, marginRequired)) {
                  // If calculation fails, break to avoid infinite loop
                  break;
               }
            }
            
            Print("HFT WARNING: Calculated lot size (", DoubleToString(lotSize, 4), 
                  ") exceeds available margin ($", DoubleToString(freeMargin, 2), 
                  "). Reducing to ", DoubleToString(testLotSize, 4));
            lotSize = testLotSize;
         }
      } else {
         // If margin calculation fails, use conservative approach: cap at 30% of free margin
         // Estimate: use contract size to approximate margin
         double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
         double leverage = (double)AccountInfoInteger(ACCOUNT_LEVERAGE);
         double estimatedMarginPerLot = (contractSize / leverage) * price;
         
         if(estimatedMarginPerLot > 0.0) {
            double maxLotByMargin = (freeMargin * 0.3) / estimatedMarginPerLot;
            if(lotSize > maxLotByMargin) {
               Print("HFT WARNING: Estimated margin too low. Capping lot size to ", DoubleToString(maxLotByMargin, 4));
               lotSize = maxLotByMargin;
            }
         }
      }
      
      // Ensure minimum lot size even if margin is tight
      if(lotSize < MinLotSize) {
         lotSize = MinLotSize;
         Print("HFT WARNING: Margin too low, using minimum lot size: ", DoubleToString(lotSize, 4));
      }
   }
   
   // Re-round after margin adjustment
   if(lotStep > 0.0) {
      lotSize = MathFloor(lotSize / lotStep) * lotStep;
   }
   
   return NormalizeDouble(lotSize, 2);
}

void OpenAggressiveTrade(int dir) {
   double lotSize = CalculateLotSize(dir);
   
   // CRITICAL: Validate lot size before opening trade
   if(lotSize <= 0.0 || lotSize < MinLotSize) {
      Print("TMB ERROR: Invalid lot size calculated: ", DoubleToString(lotSize, 4), " - Cannot open trade");
      return;
   }
   
   // No hard stop loss - trades will be managed by EA exit logic only
   double stopLoss = 0.0;
   
   bool sent = false;
   if(dir == 1) sent = trade.Buy(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), stopLoss, 0);
   if(dir == -1) sent = trade.Sell(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), stopLoss, 0);
   
   if(sent) {
      // Get position ticket
      ulong ticket = 0;
      if(trade.ResultDeal() > 0) {
         if(HistoryDealSelect(trade.ResultDeal())) {
            ticket = HistoryDealGetInteger(trade.ResultDeal(), DEAL_POSITION_ID);
         }
      }
      
      // If still no ticket, find position by symbol and magic
      if(ticket == 0) {
         for(int i = PositionsTotal() - 1; i >= 0; i--) {
            ulong posTicket = PositionGetTicket(i);
            if(posTicket > 0 && PositionSelectByTicket(posTicket)) {
               if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
                  PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
                  ticket = posTicket;
                  break;
               }
            }
         }
      }
      
      if(ticket > 0) {
         // Validate position type matches direction
         if(PositionSelectByTicket(ticket)) {
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            bool typeMatches = ((dir == 1 && posType == POSITION_TYPE_BUY) || 
                               (dir == -1 && posType == POSITION_TYPE_SELL));
            
            if(!typeMatches) {
               Print("ERROR: Position type mismatch! Expected: ", (dir == 1 ? "BUY" : "SELL"));
      return;
            }
            
            double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            
            // Set basket direction if this is the first trade
            if(basketDirection == 0) {
               basketDirection = dir;
               // Initialize basket tracking when first trade opens
               if(basketStartTime == 0) {
                  basketStartTime = TimeCurrent();
                  basketStartCapital = AccountInfoDouble(ACCOUNT_BALANCE);
                  lastCloseWasForcedLoss = false; // Reset when new basket starts
                  basketMinEquity = AccountInfoDouble(ACCOUNT_EQUITY);
                  basketMaxDrawdown = 0.0;
               }
            }
            
            // Validate basket direction matches (double check)
            if(basketDirection != 0 && basketDirection != dir) {
               Print("ERROR: Basket direction mismatch! Expected: ", basketDirection, " Got: ", dir, " - Not tracking this trade");
               return; // Don't track this trade, but don't close it individually (no partial exits)
            }
   
            activeTrades[activeTradeCount].ticket = ticket;
            activeTrades[activeTradeCount].entryPrice = entryPrice;
            activeTrades[activeTradeCount].openTime = openTime;
            activeTradeCount++;
            
            // Increment lifetime trade counter
            totalTradesOpened++;
            Print("TMB: Trade opened. Total trades: ", totalTradesOpened, " (Safe phase: ", (totalTradesOpened < SafeTradeCount ? "YES" : "NO"), ")");
            
            // Increment daily trade counter
            if(EnableDailyLimit) {
               dailyTradeCount++;
            }
         }
      }
   }
}

void RemoveTrade(int index) {
   for(int i = index; i < activeTradeCount - 1; i++) {
      activeTrades[i] = activeTrades[i+1];
   }
   activeTradeCount--;
}

// =====================================================================================================
// SYNC FUNCTIONS
// =====================================================================================================

void SyncWithExistingPositions() {
   // Clear current tracking
   activeTradeCount = 0;
   for(int i = 0; i < 50; i++) {
      activeTrades[i].ticket = 0;
   }
   
   // Rebuild from actual positions
   int totalPositions = PositionsTotal();
   
   for(int i = totalPositions - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            
            if(activeTradeCount < 50) {
               activeTrades[activeTradeCount].ticket = ticket;
               activeTrades[activeTradeCount].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               activeTrades[activeTradeCount].openTime = (datetime)PositionGetInteger(POSITION_TIME);
               activeTradeCount++;
            }
         }
      }
   }
   
   // Recalculate basket direction from actual positions
   RecalculateBasketDirection();
}

void RecalculateBasketDirection() {
   int totalPositions = PositionsTotal();
   int buyCount = 0;
   int sellCount = 0;
   
   for(int i = totalPositions - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(posType == POSITION_TYPE_BUY) {
               buyCount++;
            } else if(posType == POSITION_TYPE_SELL) {
               sellCount++;
            }
         }
      }
   }
   
   // Set basket direction based on existing positions
   if(buyCount > 0 && sellCount == 0) {
      basketDirection = 1;  // BUY only
   } else if(sellCount > 0 && buyCount == 0) {
      basketDirection = -1;  // SELL only
   } else if(buyCount == 0 && sellCount == 0) {
      basketDirection = 0;  // No positions
   } else {
      // Mixed positions (shouldn't happen, but handle it)
      basketDirection = (buyCount > sellCount) ? 1 : -1;
   }
}

