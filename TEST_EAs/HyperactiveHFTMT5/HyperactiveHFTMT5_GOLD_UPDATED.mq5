#property copyright "Copyright 2026, Tick Momentum Basket Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "3.01"

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
input int      MaxSimultaneousTrades  = 3;      // Maximum cap for simultaneous trades (FIX: reduced from 5)
input double   TickSpeedMultiplier    = 2.0;    // Scaling factor for tick speed

input group "===== Basket Profit Exit ====="
input int      BasketProfitExitSeconds = 3;      // Base seconds basket must be profitable before closing
input double   MinBasketProfitDollars  = 1.00;  // FIX: Minimum profit threshold ($) — was 0.01, must cover spread cost
input bool     UseVolatilityAdjustedExit = false; // Adjust exit time based on volatility
input double   VolatilityAdjustmentFactor = 0.5; // Adjustment factor

input group "===== Price Action Entry ====="
input double   PriceVelocityThreshold = 5.0;    // FIX: Min points/sec for momentum entry — was 1.5 (too low for gold, caused near-random entries)
input int      SwingPeriod           = 10;      // Period for swing high/low detection (price samples)
input double   ConsolidationMaxSpread = 5.0;    // Maximum spread for consolidation detection (points)
input double   BreakoutMinPoints     = 1.5;     // Minimum points beyond break for entry
input double   VelocityConfirmationSeconds = 1.0; // Time window for velocity confirmation
input int      MinTickSpeed          = 2;       // Minimum ticks per second
input int      EntryCooldownSeconds  = 1;       // Seconds between entries on same symbol

input group "===== Entry Quality Filters ====="
input double   MinVolatilityForEntry = 0.1;     // Minimum volatility points required for entry
input double   MaxSpreadForEntry     = 999.0;   // Maximum spread in points to allow entry (effectively disabled — set low to re-enable)
input bool     RequireMomentumAcceleration = false; // Require momentum to be accelerating
input double   MinPatternScore       = 30.0;    // Minimum pattern quality score (0-100)
input int      LossCooldownSeconds   = 0;       // Seconds to wait after closing basket at loss
input bool     RequireMultiPatternConfirmation = false; // Require at least 2 patterns to align

input group "===== News Trading Filter ====="
input bool     EnableNewsFilter      = false;
input int      NewsBlockMinutesBefore = 2;
input int      NewsBlockMinutesAfter  = 3;
input bool     UseSpreadBasedNewsDetection = false;
input double   NewsSpreadMultiplier   = 3.0;
input double   NormalSpreadBaseline   = 5.0;

input group "===== Daily Trade Limit ====="
input bool     EnableDailyLimit      = true;
input int      DailyMaxTrades        = 3000;

input group "===== Loss-Aware Exit Logic ====="
input bool     UseLossAwareExits     = true;
input double   MaxBasketLossDollars  = 0.0;
input double   MaxBasketLossPercent  = 1.5;
input int      MaxAdverseTimeSeconds = 60;

input group "===== Volatility-Aware Stop Behavior ====="
input bool     UseVolatilityStop     = false;
input double   VolatilitySpreadMultiplier = 2.5;
input double   VolatilityATRMultiplier = 2.0;
input int      ATRPeriod             = 14;

input group "===== Maximum Lifetime Limits ====="
input bool     UseLifetimeLimits     = true;
input int      MaxTradeLifetimeSeconds = 300;
input int      MaxBasketLifetimeSeconds = 600;

input group "===== Forced Loss Cooldown ====="
input bool     UseForcedLossCooldown = true;
input int      ForcedLossCooldownSeconds = 30;

input group "===== Hard Basket Kill-Switch (Last Resort) ====="
input bool     UseBasketKillSwitch   = true;
input double   KillSwitchLossPercent = 2.0;
input double   MaxPointsAgainst      = 0.0;

input group "===== Simplified Exit Logic ====="
input int      ProfitExitSeconds     = 3;       // Exit after N seconds if profitable (and above MinBasketProfitDollars)
input double   HardLossPips          = 30.0;    // FIX: Hard loss exit pips — was 100.0 (too wide, allows huge losses)
input double   HardLossPoints        = 300.0;   // FIX: Hard loss exit points — was 1000.0

input group "===== Directional Bias Lock ====="
input bool     UseDirectionalBiasLock = false;
input double   BiasLockPointsAgainst = 50.0;

input group "===== Statistics Tracking (No Closing Logic) ====="
input bool     UseConsecutiveWinLossLimit = true;
input double   LossLimitPerWinPercent = 25.0;
input double   MinLossLimitDollars   = 0.50;

input group "===== Account Drawdown Stop Loss ====="
input bool     UseDrawdownStopLoss   = true;
input double   MaxDrawdownPercent    = 30.0;


// Internal Globals
struct TradeInfo {
   ulong    ticket;
   double   entryPrice;
   datetime openTime;
};

TradeInfo activeTrades[50];
int activeTradeCount = 0;

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
double avgVolatility = 0.0;
double volatilityHistory[50];
int volatilityHistoryCount = 0;

int totalTradesOpened = 0;
int htfTrendDirection = 0;

double highestEquity = 0.0;
bool drawdownStopLossTriggered = false;

int basketDirection = 0;
bool directionalBiasLocked = false;
int lockedDirection = 0;
double basketEntryPrice = 0.0;
datetime lastEntryTime = 0;
datetime basketFirstProfitTime = 0;
datetime lastBasketCloseTime = 0;
double lastBasketCloseProfit = 0.0;
bool lastCloseWasForcedLoss = false;
datetime forcedLossCooldownUntil = 0;
double patternScores[3];

int dailyTradeCount = 0;
datetime lastDailyResetDate = 0;

int consecutiveWins = 0;
double recentBasketProfits[10];
int recentBasketIndex = 0;

datetime basketStartTime = 0;
double basketStartCapital = 0.0;
double basketMinEquity = 0.0;
double basketMaxDrawdown = 0.0;
double basketMaxLossDollars = 0.0;

double spreadHistory[20];
int spreadHistoryCount = 0;
datetime lastNewsBlockTime = 0;

double atrBuffer[];
int atrHandle = INVALID_HANDLE;
double normalSpreadBaseline = 0.0;

// =====================================================================================================
// INIT & CORE
// =====================================================================================================

int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   lastDailyResetDate = StructToTime(dt);
   dailyTradeCount = 0;

   consecutiveWins = 0;
   ArrayInitialize(recentBasketProfits, 0.0);
   recentBasketIndex = 0;

   basketStartTime = 0;
   basketStartCapital = 0.0;
   basketMinEquity = 0.0;
   basketMaxDrawdown = 0.0;
   basketMaxLossDollars = 0.0;
   lastCloseWasForcedLoss = false;
   forcedLossCooldownUntil = 0;

   if(UseVolatilityStop) {
      atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
      if(atrHandle == INVALID_HANDLE) {
         Print("TMB ERROR: Failed to create ATR indicator");
         return INIT_FAILED;
      }
      ArraySetAsSeries(atrBuffer, true);
   }

   normalSpreadBaseline = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;

   ArrayInitialize(spreadHistory, 0.0);
   spreadHistoryCount = 0;
   lastNewsBlockTime = 0;

   highestEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   drawdownStopLossTriggered = false;
   Print("TMB: Drawdown stop loss initialized. Starting equity: $", DoubleToString(highestEquity, 2),
         ", Max drawdown: ", DoubleToString(MaxDrawdownPercent, 1), "%");

   CreateDisplayPanel();
   SyncWithExistingPositions();

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   if(atrHandle != INVALID_HANDLE) {
      IndicatorRelease(atrHandle);
      atrHandle = INVALID_HANDLE;
   }
   ObjectDelete(0, "TMB_DisplayPanel");
   ObjectDelete(0, "HFT_DisplayText");
   ObjectsDeleteAll(0, "HFT_");
   Comment("");
}

void OnTick() {
   UpdateVelocity();
   ResetDailyCounterIfNeeded();

   // 0. CHECK DRAWDOWN STOP LOSS
   if(UseDrawdownStopLoss && !drawdownStopLossTriggered) {
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(currentEquity > highestEquity) highestEquity = currentEquity;

      if(highestEquity > 0.0) {
         double drawdownPercent = ((highestEquity - currentEquity) / highestEquity) * 100.0;
         if(drawdownPercent >= MaxDrawdownPercent) {
            Print("TMB: DRAWDOWN STOP LOSS TRIGGERED! Drawdown: ", DoubleToString(drawdownPercent, 2), "%");
            CloseAllTrades();
            drawdownStopLossTriggered = true;
            UpdateDisplay();
            return;
         }
      }
   }

   if(drawdownStopLossTriggered) {
      UpdateDisplay();
      return;
   }

   // 1. MANAGE EXITS
   ManageActiveExits();

   // 2. ENTRY
   if(EnableDailyLimit && dailyTradeCount >= DailyMaxTrades) {
      UpdateDisplay();
      return;
   }

   if(UseForcedLossCooldown && forcedLossCooldownUntil > 0 && TimeCurrent() < forcedLossCooldownUntil) {
      UpdateDisplay();
      return;
   }

   if(UseVolatilityStop) {
      bool spreadExpanded = false;
      bool atrExpanded = false;
      if(CheckVolatilityExpansion(spreadExpanded, atrExpanded)) {
         UpdateDisplay();
         return;
      }
   }

   if(TimeCurrent() - lastEntryTime >= EntryCooldownSeconds) {
      int dynamicMaxTrades = CalculateDynamicMaxTrades();
      if(activeTradeCount < dynamicMaxTrades) {
         int signal = GetHFTMove();
         if(signal != 0) {
            if(UseDirectionalBiasLock && directionalBiasLocked) {
               if((signal == 1 && lockedDirection == 1) || (signal == -1 && lockedDirection == -1)) {
                  return;
               }
            }
            if(basketDirection == 0 || signal == basketDirection) {
               OpenAggressiveTrade(signal);
               lastEntryTime = TimeCurrent();
            }
         }
      }
   }

   UpdateDisplay();
}

int CalculateDynamicMaxTrades() {
   if(currentTicksPerSecond < MinTickSpeed) return BaseSimultaneousTrades;

   double tickSpeedRatio = currentTicksPerSecond / MinTickSpeed;
   int dynamicTrades = (int)(BaseSimultaneousTrades + (TickSpeedMultiplier * tickSpeedRatio));

   if(dynamicTrades < BaseSimultaneousTrades) dynamicTrades = BaseSimultaneousTrades;
   if(dynamicTrades > MaxSimultaneousTrades) dynamicTrades = MaxSimultaneousTrades;

   return dynamicTrades;
}

void ResetDailyCounterIfNeeded() {
   if(!EnableDailyLimit) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime currentMidnight = StructToTime(dt);

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

   for(int i=19; i>0; i--) tickPrices[i] = tickPrices[i-1];
   tickPrices[0] = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double midPrice = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;

   if(priceHistoryCount < 100) {
      priceHistory[priceHistoryCount].price = midPrice;
      priceHistory[priceHistoryCount].time = now;
      priceHistoryCount++;
   } else {
      for(int i = 0; i < 99; i++) priceHistory[i] = priceHistory[i+1];
      priceHistory[99].price = midPrice;
      priceHistory[99].time = now;
   }

   CleanOldPriceHistory(now);
   UpdateVolatility();
}

void CleanOldPriceHistory(datetime currentTime) {
   int writeIndex = 0;
   for(int i = 0; i < priceHistoryCount; i++) {
      if(currentTime - priceHistory[i].time <= 10) {
         if(writeIndex != i) priceHistory[writeIndex] = priceHistory[i];
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

   if(UseVolatilityAdjustedExit) {
      if(volatilityHistoryCount < 50) {
         volatilityHistory[volatilityHistoryCount] = currentVolatility;
         volatilityHistoryCount++;
      } else {
         for(int i = 0; i < 49; i++) volatilityHistory[i] = volatilityHistory[i+1];
         volatilityHistory[49] = currentVolatility;
      }

      if(volatilityHistoryCount > 0) {
         double volatilitySum = 0.0;
         for(int i = 0; i < volatilityHistoryCount; i++) volatilitySum += volatilityHistory[i];
         avgVolatility = volatilitySum / (double)volatilityHistoryCount;
      }
   }
}

// =====================================================================================================
// ENTRY QUALITY FILTERS
// =====================================================================================================

bool CheckLossCooldown() {
   if(lastBasketCloseProfit < 0 && lastBasketCloseTime > 0) {
      int secondsSinceClose = (int)(TimeCurrent() - lastBasketCloseTime);
      if(secondsSinceClose < LossCooldownSeconds) return false;
   }
   return true;
}

bool CheckVolatilityFilter() {
   return (currentVolatility >= MinVolatilityForEntry);
}

bool CheckSpreadFilter() {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = (ask - bid) / _Point;

   if(EnableNewsFilter && UseSpreadBasedNewsDetection) UpdateSpreadHistory(spread);

   return (spread <= MaxSpreadForEntry);
}

bool CheckNewsFilter() {
   if(!EnableNewsFilter) return true;

   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);

   int hour = dt.hour;
   int minute = dt.min;

   int newsHours[] = {13, 15, 17, 19, 20};
   int newsMinutes[] = {30, 0, 30, 0, 30};

   for(int i = 0; i < ArraySize(newsHours); i++) {
      int newsHour = newsHours[i];
      int newsMin = newsMinutes[i];

      int totalMinutesBefore = hour * 60 + minute;
      int newsTotalMinutes = newsHour * 60 + newsMin;
      int minutesBeforeNews = newsTotalMinutes - totalMinutesBefore;

      if(minutesBeforeNews >= -NewsBlockMinutesBefore && minutesBeforeNews <= NewsBlockMinutesAfter) {
         Print("TMB: News filter blocking - Within news window (", hour, ":", minute, " near ", newsHour, ":", newsMin, ")");
         return false;
      }
   }

   if(UseSpreadBasedNewsDetection && spreadHistoryCount >= 5) {
      double avgSpread = 0.0;
      for(int i = 0; i < spreadHistoryCount; i++) avgSpread += spreadHistory[i];
      avgSpread = avgSpread / (double)spreadHistoryCount;

      double currentSpread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
      double spreadBaseline = (NormalSpreadBaseline > 0) ? NormalSpreadBaseline : avgSpread;

      if(currentSpread > (spreadBaseline * NewsSpreadMultiplier)) {
         lastNewsBlockTime = currentTime;
         Print("TMB: News filter blocking - Spread widened to ", DoubleToString(currentSpread, 1), " points");
         return false;
      }

      if(lastNewsBlockTime > 0) {
         int secondsSinceNews = (int)(currentTime - lastNewsBlockTime);
         if(secondsSinceNews < (NewsBlockMinutesAfter * 60)) return false;
         else { lastNewsBlockTime = 0; return true; }
      }
   }

   return true;
}

bool CheckVolatilityExpansion(bool& spreadExpanded, bool& atrExpanded) {
   spreadExpanded = false;
   atrExpanded = false;

   if(!UseVolatilityStop) return false;

   double currentSpread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(normalSpreadBaseline > 0.0 && currentSpread >= (normalSpreadBaseline * VolatilitySpreadMultiplier))
      spreadExpanded = true;

   if(atrHandle != INVALID_HANDLE) {
      if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) > 0) {
         double currentATR = atrBuffer[0];
         if(currentATR > 0.0) {
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
            if(avgATR > 0.0 && priceRange >= (avgATR * VolatilityATRMultiplier)) atrExpanded = true;
         }
      }
   }

   return (spreadExpanded || atrExpanded);
}

void UpdateSpreadHistory(double currentSpread) {
   if(spreadHistoryCount < 20) {
      spreadHistory[spreadHistoryCount] = currentSpread;
      spreadHistoryCount++;
   } else {
      for(int i = 0; i < 19; i++) spreadHistory[i] = spreadHistory[i+1];
      spreadHistory[19] = currentSpread;
   }
}

double CalculatePatternScore(int patternType, int signal, double velocity, double volatility) {
   if(signal == 0) return 0.0;

   double score = 0.0;
   double velocityRatio = MathAbs(velocity) / PriceVelocityThreshold;
   score += MathMin(velocityRatio * 25.0, 50.0);

   if(volatility > 0) {
      double volatilityBonus = MathMin((volatility / (PriceVelocityThreshold * 2.0)) * 25.0, 25.0);
      score += volatilityBonus;
   }

   if(patternType == 1) score += 25.0;
   else if(patternType == 2) score += 15.0;
   else if(patternType == 3) score += 10.0;

   return MathMin(score, 100.0);
}

int GetMultiPatternSignal(int p1sig, double p1score, int p2sig, double p2score, int p3sig, double p3score) {
   if(!RequireMultiPatternConfirmation) {
      if(p1sig != 0 && p1score >= MinPatternScore) return p1sig;
      if(p2sig != 0 && p2score >= MinPatternScore) return p2sig;
      if(p3sig != 0 && p3score >= MinPatternScore) return p3sig;
      return 0;
   }

   int buyVotes = 0, sellVotes = 0;
   if(p1sig == 1 && p1score >= MinPatternScore) buyVotes++;
   else if(p1sig == -1 && p1score >= MinPatternScore) sellVotes++;
   if(p2sig == 1 && p2score >= MinPatternScore) buyVotes++;
   else if(p2sig == -1 && p2score >= MinPatternScore) sellVotes++;
   if(p3sig == 1 && p3score >= MinPatternScore) buyVotes++;
   else if(p3sig == -1 && p3score >= MinPatternScore) sellVotes++;

   if(buyVotes >= 2) return 1;
   if(sellVotes >= 2) return -1;
   return 0;
}

double GetBestPatternScore(double s1, double s2, double s3) {
   double best = 0.0;
   if(s1 > best) best = s1;
   if(s2 > best) best = s2;
   if(s3 > best) best = s3;
   return best;
}

bool CheckMomentumAcceleration(int signal) {
   if(!RequireMomentumAcceleration) return true;

   datetime currentTime = TimeCurrent();
   double currentPrice = priceHistoryCount > 0 ? priceHistory[priceHistoryCount-1].price : 0.0;
   if(currentPrice <= 0) return false;

   double price1sAgo = GetPriceAtTime(currentTime - 1);
   double price2sAgo = GetPriceAtTime(currentTime - 2);
   if(price1sAgo <= 0 || price2sAgo <= 0) return false;

   double velocity1s = (currentPrice - price1sAgo) / _Point;
   double velocity2s = (currentPrice - price2sAgo) / (_Point * 2.0);

   if(MathAbs(velocity2s) > 0 && MathAbs(velocity1s) > MathAbs(velocity2s) * 1.1) {
      if((signal == 1 && velocity1s > 0) || (signal == -1 && velocity1s < 0)) return true;
   }

   return false;
}

int GetHFTMove() {
   if(currentTicksPerSecond < MinTickSpeed) {
      static datetime lastTickWarning = 0;
      if(TimeCurrent() - lastTickWarning > 10) {
         Print("TMB: Blocked - Tick speed too low: ", DoubleToString(currentTicksPerSecond, 1), " < ", MinTickSpeed);
         lastTickWarning = TimeCurrent();
      }
      return 0;
   }

   if(priceHistoryCount < 3) {
      static datetime lastHistoryWarning = 0;
      if(TimeCurrent() - lastHistoryWarning > 10) {
         Print("TMB: Blocked - Insufficient price history: ", priceHistoryCount, " < 3");
         lastHistoryWarning = TimeCurrent();
      }
      return 0;
   }

   if(!CheckLossCooldown()) {
      static datetime lastCooldownWarning = 0;
      if(TimeCurrent() - lastCooldownWarning > 5) {
         Print("TMB: Blocked - Loss cooldown active");
         lastCooldownWarning = TimeCurrent();
      }
      return 0;
   }
   // Spread filter: only blocks if MaxSpreadForEntry is set to a meaningful low value
   // Default is 999.0 (effectively off). Lower it to re-enable spread filtering.
   if(MaxSpreadForEntry < 900.0 && !CheckSpreadFilter()) {
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

   // Pattern 1: Price Velocity (Primary)
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

   double velocity1s = 0.0;
   double velocity2s = 0.0;

   double price1sAgo = GetPriceAtTime(currentTime - 1);
   double price2sAgo = GetPriceAtTime(currentTime - 2);

   if(price1sAgo > 0) velocity1s = (currentPrice - price1sAgo) / _Point;
   if(price2sAgo > 0) velocity2s = (currentPrice - price2sAgo) / (_Point * 2.0);

   if(velocity1s >= PriceVelocityThreshold && velocity2s >= PriceVelocityThreshold * 0.5) return 1;
   if(velocity1s <= -PriceVelocityThreshold && velocity2s <= -PriceVelocityThreshold * 0.5) return -1;

   return 0;
}

// Pattern 2: Consolidation Breakout
// FIX: Exclude current price from range — previously currentPrice was range start AND included in
// the loop, so recentHigh >= currentPrice always, making breakout condition impossible to trigger.
int CheckConsolidationBreakout(double currentPrice, datetime currentTime) {
   if(priceHistoryCount < SwingPeriod + 1) return 0;

   // Build range from HISTORICAL prices only (exclude current = last element)
   double recentHigh = priceHistory[priceHistoryCount - 2].price;
   double recentLow  = priceHistory[priceHistoryCount - 2].price;

   int checkCount = MathMin(SwingPeriod, priceHistoryCount - 1);
   int startIdx = MathMax(0, priceHistoryCount - 1 - checkCount);
   for(int i = startIdx; i < priceHistoryCount - 1; i++) {
      if(priceHistory[i].price > recentHigh) recentHigh = priceHistory[i].price;
      if(priceHistory[i].price < recentLow)  recentLow  = priceHistory[i].price;
   }

   double consolidationSpread = (recentHigh - recentLow) / _Point;
   if(consolidationSpread > ConsolidationMaxSpread) return 0;

   if(currentPrice > recentHigh + (BreakoutMinPoints * _Point)) return 1;
   if(currentPrice < recentLow  - (BreakoutMinPoints * _Point)) return -1;

   return 0;
}

// Pattern 3: Swing High/Low Breakout
// FIX: Same fix as consolidation — exclude current price from historical range.
int CheckSwingBreakout(double currentPrice, datetime currentTime) {
   if(priceHistoryCount < SwingPeriod + 1) return 0;

   double swingHigh = priceHistory[priceHistoryCount - 2].price;
   double swingLow  = priceHistory[priceHistoryCount - 2].price;

   int checkCount = MathMin(SwingPeriod, priceHistoryCount - 1);
   int startIdx = MathMax(0, priceHistoryCount - 1 - checkCount);
   for(int i = startIdx; i < priceHistoryCount - 1; i++) {
      if(priceHistory[i].price > swingHigh) swingHigh = priceHistory[i].price;
      if(priceHistory[i].price < swingLow)  swingLow  = priceHistory[i].price;
   }

   if(currentPrice > swingHigh + (BreakoutMinPoints * _Point)) return 1;
   if(currentPrice < swingLow  - (BreakoutMinPoints * _Point)) return -1;

   return 0;
}

bool ConfirmWithVelocity(double currentPrice, datetime currentTime) {
   if(priceHistoryCount < 3) return false;

   double priceAtWindow = GetPriceAtTime(currentTime - (int)VelocityConfirmationSeconds);
   if(priceAtWindow <= 0) return false;

   double velocity = (currentPrice - priceAtWindow) / (_Point * VelocityConfirmationSeconds);

   if(MathAbs(velocity) >= PriceVelocityThreshold * 0.7) {
      double price1sAgo = GetPriceAtTime(currentTime - 1);
      if(price1sAgo > 0) {
         double recentVelocity = (currentPrice - price1sAgo) / _Point;
         if(MathAbs(recentVelocity) >= MathAbs(velocity) * 0.8) return true;
      }
   }

   return false;
}

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

   if(minTimeDiff <= 2) return closestPrice;
   return 0.0;
}

// =====================================================================================================
// RISK MANAGEMENT HELPERS
// =====================================================================================================

double CalculateLossLimit() {
   if(!UseConsecutiveWinLossLimit || consecutiveWins <= 0) return 0.0;

   double totalRecentProfit = 0.0;
   for(int i = 0; i < 10; i++) {
      if(recentBasketProfits[i] > 0) totalRecentProfit += recentBasketProfits[i];
   }

   if(totalRecentProfit <= 0) return MinLossLimitDollars;

   double lossLimit = (totalRecentProfit * (LossLimitPerWinPercent / 100.0)) * consecutiveWins;
   if(lossLimit < MinLossLimitDollars) lossLimit = MinLossLimitDollars;

   return lossLimit;
}

// =====================================================================================================
// TRADE MANAGEMENT
// =====================================================================================================

void ManageActiveExits() {
   SyncWithExistingPositions();

   for(int i = activeTradeCount - 1; i >= 0; i--) {
      if(!PositionSelectByTicket(activeTrades[i].ticket)) {
         RemoveTrade(i);
         if(activeTradeCount == 0) {
            basketDirection = 0;
            basketFirstProfitTime = 0;
         }
      }
   }

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

   if(basketStartTime > 0 && basketStartCapital > 0) {
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(basketMinEquity == 0.0 || currentEquity < basketMinEquity) basketMinEquity = currentEquity;

      if(basketStartCapital > 0) {
         double currentDrawdown = ((basketStartCapital - basketMinEquity) / basketStartCapital) * 100.0;
         if(currentDrawdown > basketMaxDrawdown) basketMaxDrawdown = currentDrawdown;
      }
   }

   // Calculate total basket profit
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

   if(totalLotSize > 0.0 && basketDirection != 0) basketEntryPrice = totalEntryValue / totalLotSize;

   // Directional bias lock check
   if(UseDirectionalBiasLock && basketDirection != 0 && basketEntryPrice > 0.0) {
      double currentPrice = (basketDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double pipValue = (digits == 3 || digits == 5) ? (_Point * 10.0) : _Point;
      double priceDiff = 0.0;

      if(basketDirection == 1) {
         priceDiff = (basketEntryPrice - currentPrice) / pipValue;
         if(priceDiff >= BiasLockPointsAgainst) {
            directionalBiasLocked = true;
            lockedDirection = 1;
            Print("TMB: Directional bias lock activated - Price moved ", DoubleToString(priceDiff, 1), " points against BUY basket");
         }
      } else if(basketDirection == -1) {
         priceDiff = (currentPrice - basketEntryPrice) / pipValue;
         if(priceDiff >= BiasLockPointsAgainst) {
            directionalBiasLocked = true;
            lockedDirection = -1;
            Print("TMB: Directional bias lock activated - Price moved ", DoubleToString(priceDiff, 1), " points against SELL basket");
         }
      }
   }

   // EXIT 1: Hard Loss Exit
   if(basketDirection != 0 && basketEntryPrice > 0.0) {
      double currentPrice = (basketDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double pipValue = (digits == 3 || digits == 5) ? (_Point * 10.0) : _Point;
      double pointsAgainst = 0.0;
      double pipsAgainst = 0.0;

      if(basketDirection == 1) {
         pointsAgainst = (basketEntryPrice - currentPrice) / _Point;
         pipsAgainst = (basketEntryPrice - currentPrice) / pipValue;
      } else {
         pointsAgainst = (currentPrice - basketEntryPrice) / _Point;
         pipsAgainst = (currentPrice - basketEntryPrice) / pipValue;
      }

      bool hardLossTriggered = false;
      string lossReason = "";

      if(HardLossPips > 0.0 && pipsAgainst >= HardLossPips) {
         hardLossTriggered = true;
         lossReason = "Hard loss: " + DoubleToString(pipsAgainst, 1) + " pips (limit: " + DoubleToString(HardLossPips, 1) + " pips)";
      }
      if(!hardLossTriggered && HardLossPoints > 0.0 && pointsAgainst >= HardLossPoints) {
         hardLossTriggered = true;
         lossReason = "Hard loss: " + DoubleToString(pointsAgainst, 1) + " points (limit: " + DoubleToString(HardLossPoints, 1) + " points)";
      }

      if(hardLossTriggered) {
         Print("TMB: ", lossReason, " - Closing all trades");
         lastCloseWasForcedLoss = true;
         CloseAllTrades();
         return;
      }
   }

   // EXIT 2: Profit Exit — FIX: use MinBasketProfitDollars, not just > 0
   // Previously the check was `totalProfit > 0.0` which exits at $0.001 (less than spread cost).
   // Now requires profit >= MinBasketProfitDollars before starting the timer.
   if(totalProfit >= MinBasketProfitDollars) {
      if(basketFirstProfitTime == 0) {
         basketFirstProfitTime = TimeCurrent();
         Print("TMB: Basket profit $", DoubleToString(totalProfit, 2), " >= threshold $",
               DoubleToString(MinBasketProfitDollars, 2), " - Timer started (", ProfitExitSeconds, "s)");
      } else {
         int profitDurationSeconds = (int)(TimeCurrent() - basketFirstProfitTime);
         if(profitDurationSeconds >= ProfitExitSeconds) {
            Print("TMB: Basket profitable for ", profitDurationSeconds, "s ($", DoubleToString(totalProfit, 2), ") - Closing");
            CloseAllTrades();
            return;
         }
      }
   } else {
      // Reset profit timer if profit drops below threshold
      if(basketFirstProfitTime != 0) basketFirstProfitTime = 0;
   }
}

void CloseAllTrades() {
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

   lastBasketCloseTime = TimeCurrent();
   lastBasketCloseProfit = totalProfit;

   if(UseForcedLossCooldown && lastCloseWasForcedLoss) {
      forcedLossCooldownUntil = TimeCurrent() + ForcedLossCooldownSeconds;
      Print("TMB: Forced loss cooldown until ", TimeToString(forcedLossCooldownUntil, TIME_SECONDS));
   } else {
      forcedLossCooldownUntil = 0;
   }

   basketStartTime = 0;
   basketStartCapital = 0.0;
   basketMinEquity = 0.0;
   basketMaxDrawdown = 0.0;
   basketMaxLossDollars = 0.0;

   if(UseConsecutiveWinLossLimit) {
      if(totalProfit > 0) {
         consecutiveWins++;
         recentBasketProfits[recentBasketIndex] = totalProfit;
         recentBasketIndex = (recentBasketIndex + 1) % 10;
      } else {
         consecutiveWins = 0;
      }
   }

   for(int i = totalPositions - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            trade.PositionClose(ticket);
         }
      }
   }

   activeTradeCount = 0;
   for(int i = 0; i < 50; i++) activeTrades[i].ticket = 0;

   basketDirection = 0;
   basketFirstProfitTime = 0;
   basketEntryPrice = 0.0;
   directionalBiasLocked = false;
   lockedDirection = 0;
}

// =====================================================================================================
// DISPLAY
// =====================================================================================================

void CreateDisplayPanel() {
   if(ObjectFind(0, "TMB_DisplayPanel") < 0) {
      ObjectCreate(0, "TMB_DisplayPanel", OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_YDISTANCE, 30);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_XSIZE, 630);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_YSIZE, 455);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_BGCOLOR, C'135,206,235');
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_COLOR, C'70,130,180');
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_BACK, true);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_SELECTED, false);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_HIDDEN, true);
   } else {
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_XSIZE, 630);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_YSIZE, 455);
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_BGCOLOR, C'135,206,235');
      ObjectSetInteger(0, "TMB_DisplayPanel", OBJPROP_BACK, true);
   }
}

void UpdateDisplay() {
   if(ObjectFind(0, "TMB_DisplayPanel") < 0) CreateDisplayPanel();

   string status = "=== Tick Momentum Basket Scalper v3.01 ===\n";

   int overallSignal = GetHFTMove();
   status += "Signal: ";
   if(overallSignal == 1) status += "BUY\n";
   else if(overallSignal == -1) status += "SELL\n";
   else status += "WAITING\n";

   if(UseDirectionalBiasLock && directionalBiasLocked)
      status += "Bias Lock: " + (lockedDirection == 1 ? "BUY" : "SELL") + " [LOCKED]\n";

   status += "Tick: " + DoubleToString(currentTicksPerSecond, 1);
   status += (currentTicksPerSecond < MinTickSpeed) ? " [LOW]\n" : " [OK]\n";

   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   status += "Spread: " + DoubleToString(spread, 1);
   status += (spread > MaxSpreadForEntry) ? " [HIGH]\n" : " [OK]\n";

   status += "Vol: " + DoubleToString(currentVolatility, 1);
   status += (currentVolatility < MinVolatilityForEntry) ? " [LOW]\n" : " [OK]\n";

   int dynamicMaxTrades = CalculateDynamicMaxTrades();
   status += "Trades: " + IntegerToString(activeTradeCount) + "/" + IntegerToString(dynamicMaxTrades) + "\n";

   string phaseStatus = "";
   if(totalTradesOpened < SafeTradeCount)
      phaseStatus = "Phase 1 (SAFE): " + IntegerToString(totalTradesOpened) + "/" + IntegerToString(SafeTradeCount);
   else {
      phaseStatus = "Phase 2 (AGGRESSIVE): " + IntegerToString(totalTradesOpened) + " trades";
      if(UseHTFTrendMaxLot) {
         string trendStr = (htfTrendDirection == 1) ? "UP" : (htfTrendDirection == -1 ? "DOWN" : "NEUTRAL");
         phaseStatus += " | HTF: " + trendStr;
      }
   }
   status += "Lot Sizing: " + phaseStatus + "\n";
   status += "Min Profit: $" + DoubleToString(MinBasketProfitDollars, 2) + "\n";

   if(activeTradeCount > 0) {
      double totalBasketProfit = 0.0;
      int totalPositions = PositionsTotal();
      for(int j = totalPositions - 1; j >= 0; j--) {
         ulong ticket = PositionGetTicket(j);
         if(ticket > 0 && PositionSelectByTicket(ticket)) {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
               totalBasketProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         }
      }

      status += "P&L: $" + DoubleToString(totalBasketProfit, 2);
      if(totalBasketProfit >= MinBasketProfitDollars && basketFirstProfitTime > 0) {
         int profitDuration = (int)(TimeCurrent() - basketFirstProfitTime);
         status += " (" + IntegerToString(profitDuration) + "/" + IntegerToString(ProfitExitSeconds) + "s)";
      }
      status += "\n";
   }

   if(overallSignal == 0) {
      string blockingReasons = "";
      if(currentTicksPerSecond < MinTickSpeed) blockingReasons += "TickLow ";
      if(priceHistoryCount < 3) blockingReasons += "NoData ";
      if(!CheckLossCooldown()) {
         int secondsSinceClose = (int)(TimeCurrent() - lastBasketCloseTime);
         blockingReasons += "Cooldown(" + IntegerToString(secondsSinceClose) + "s) ";
      }
      if(!CheckSpreadFilter()) blockingReasons += "SpreadHigh ";
      if(currentVolatility < MinVolatilityForEntry) blockingReasons += "VolLow ";
      if(!CheckNewsFilter()) blockingReasons += "News ";
      if(UseDirectionalBiasLock && directionalBiasLocked)
         blockingReasons += "BiasLock(" + (lockedDirection == 1 ? "BUY" : "SELL") + ") ";

      datetime currentTime = TimeCurrent();
      double currentPrice = priceHistoryCount > 0 ? priceHistory[priceHistoryCount-1].price : 0.0;
      if(priceHistoryCount >= 3) {
         int p1 = CheckPriceVelocity(currentPrice, currentTime);
         int p2 = CheckConsolidationBreakout(currentPrice, currentTime);
         int p3 = CheckSwingBreakout(currentPrice, currentTime);
         if(p1 == 0 && p2 == 0 && p3 == 0) blockingReasons += "NoPattern";
      }

      if(StringLen(blockingReasons) > 0) status += "Blocked: " + blockingReasons + "\n";
   }

   status += "Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n";
   status += "Equity: $" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2);

   if(UseDrawdownStopLoss && highestEquity > 0.0) {
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      double drawdownPercent = ((highestEquity - currentEquity) / highestEquity) * 100.0;
      status += "\nDrawdown: " + DoubleToString(drawdownPercent, 2) + "% / " + DoubleToString(MaxDrawdownPercent, 1) + "%";
      if(drawdownStopLossTriggered) status += " [STOPPED]";
      else if(drawdownPercent >= MaxDrawdownPercent * 0.8) status += " [WARNING]";
   }

   Comment(status);
}

// =====================================================================================================
// UTILITIES
// =====================================================================================================

int CheckHTFTrend() {
   if(!UseHTFTrendMaxLot) return 0;

   ENUM_TIMEFRAMES htfPeriod = PERIOD_H4;

   double closeBuffer[];
   ArraySetAsSeries(closeBuffer, true);
   if(CopyClose(_Symbol, htfPeriod, 0, 3, closeBuffer) < 3) return 0;

   double close0 = closeBuffer[0];
   double close1 = closeBuffer[1];
   double close2 = closeBuffer[2];

   if(close0 <= 0 || close1 <= 0 || close2 <= 0) return 0;

   bool higherHighs = (close0 > close1) && (close1 > close2);
   bool lowerLows   = (close0 < close1) && (close1 < close2);

   int maHandle = iMA(_Symbol, htfPeriod, 50, 0, MODE_SMA, PRICE_CLOSE);
   if(maHandle == INVALID_HANDLE) {
      if(higherHighs) return 1;
      if(lowerLows) return -1;
      return 0;
   }

   double maBuffer[];
   ArraySetAsSeries(maBuffer, true);
   if(CopyBuffer(maHandle, 0, 0, 2, maBuffer) < 2) {
      IndicatorRelease(maHandle);
      if(higherHighs) return 1;
      if(lowerLows) return -1;
      return 0;
   }

   bool priceAboveMA = close0 > maBuffer[0];
   bool priceBelowMA = close0 < maBuffer[0];

   IndicatorRelease(maHandle);

   if(priceAboveMA && higherHighs) return 1;
   if(priceBelowMA && lowerLows)   return -1;

   return 0;
}

double CalculateLotSize(int tradeDirection) {
   // PHASE 1: Safe Micro Lots (First SafeTradeCount trades)
   if(totalTradesOpened < SafeTradeCount) {
      Print("TMB: Phase 1 (SAFE) - Trade #", totalTradesOpened + 1, "/", SafeTradeCount);

      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmount = balance * (SafeTradeRiskPercent / 100.0);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double pipValuePerLot = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

      if(digits == 3 || digits == 5) {
         if(pipValuePerLot < 0.1) pipValuePerLot *= 10.0;
      }
      if(pipValuePerLot <= 0.0) pipValuePerLot = 1.0;

      double stopLossInPips = (LotSizingStopLossPips > 0.0) ? LotSizingStopLossPips : 100.0;
      double lotSize = riskAmount / (stopLossInPips * pipValuePerLot);
      if(lotSize <= 0.0) lotSize = MinLotSize;

      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

      lotSize = MathMax(MinLotSize, MathMax(minLot, MathMin(maxLot, lotSize)));
      if(lotStep > 0.0) lotSize = MathFloor(lotSize / lotStep) * lotStep;

      // Margin check
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(freeMargin > 0.0) {
         double marginRequired = 0.0;
         ENUM_ORDER_TYPE orderType = (tradeDirection == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         double price = (tradeDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

         if(OrderCalcMargin(orderType, _Symbol, lotSize, price, marginRequired)) {
            double maxMarginToUse = freeMargin * 0.8;
            if(marginRequired > maxMarginToUse) {
               double testLot = lotSize;
               double step = (lotStep > 0.0) ? lotStep : 0.01;
               while(testLot >= MinLotSize && marginRequired > maxMarginToUse) {
                  testLot -= step;
                  if(testLot < MinLotSize) { testLot = MinLotSize; break; }
                  if(!OrderCalcMargin(orderType, _Symbol, testLot, price, marginRequired)) break;
               }
               lotSize = testLot;
            }
         }
      }

      if(lotStep > 0.0) lotSize = MathFloor(lotSize / lotStep) * lotStep;
      return NormalizeDouble(lotSize, 2);
   }

   // PHASE 2: Trend-Based Sizing (After SafeTradeCount trades)
   Print("TMB: Phase 2 (AGGRESSIVE) - Trade #", totalTradesOpened + 1, " - Checking HTF trend");

   htfTrendDirection = CheckHTFTrend();
   bool trendAligned = (htfTrendDirection != 0) && (htfTrendDirection == tradeDirection);

   // FIX: Reduced Phase 2 max margin from 90% to 25% — 90% was catastrophic on a single bad trade
   if(trendAligned && UseHTFTrendMaxLot) {
      Print("TMB: Trend aligned - Using 25% margin (was 90%)");

      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(freeMargin > 0.0) {
         double maxMarginToUse = freeMargin * 0.25;  // FIX: was 0.9

         ENUM_ORDER_TYPE orderType = (tradeDirection == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         double price = (tradeDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

         double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
         double step    = (lotStep > 0.0) ? lotStep : 0.01;

         double testLot = maxLot;
         double marginRequired = 0.0;

         while(testLot >= minLot) {
            if(OrderCalcMargin(orderType, _Symbol, testLot, price, marginRequired)) {
               if(marginRequired <= maxMarginToUse) break;
            }
            testLot -= step;
            if(testLot < minLot) { testLot = minLot; break; }
         }

         if(testLot < MinLotSize) testLot = MinLotSize;
         if(lotStep > 0.0) testLot = MathFloor(testLot / lotStep) * lotStep;

         Print("TMB: Phase 2 lot: ", DoubleToString(testLot, 4),
               " (Margin: $", DoubleToString(marginRequired, 2), "/$", DoubleToString(maxMarginToUse, 2), ")");
         return NormalizeDouble(testLot, 2);
      }
   }

   // Trend not aligned — fall back to safe risk
   Print("TMB: Trend NOT aligned - Using safe risk (", DoubleToString(SafeTradeRiskPercent, 1), "%)");

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (SafeTradeRiskPercent / 100.0);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipValuePerLot = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(digits == 3 || digits == 5) {
      if(pipValuePerLot < 0.1) pipValuePerLot *= 10.0;
   }
   if(pipValuePerLot <= 0.0) pipValuePerLot = 1.0;

   double stopLossInPips = (LotSizingStopLossPips > 0.0) ? LotSizingStopLossPips : 100.0;
   double lotSize = riskAmount / (stopLossInPips * pipValuePerLot);
   if(lotSize <= 0.0) lotSize = MinLotSize;

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lotSize = MathMax(MinLotSize, MathMax(minLot, MathMin(maxLot, lotSize)));
   if(lotStep > 0.0) lotSize = MathFloor(lotSize / lotStep) * lotStep;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin > 0.0) {
      double marginRequired = 0.0;
      ENUM_ORDER_TYPE orderType = (tradeDirection == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double price = (tradeDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(OrderCalcMargin(orderType, _Symbol, lotSize, price, marginRequired)) {
         double maxMarginToUse = freeMargin * 0.8;
         if(marginRequired > maxMarginToUse) {
            double testLot = lotSize;
            double step = (lotStep > 0.0) ? lotStep : 0.01;
            while(testLot >= MinLotSize && marginRequired > maxMarginToUse) {
               testLot -= step;
               if(testLot < MinLotSize) { testLot = MinLotSize; break; }
               if(!OrderCalcMargin(orderType, _Symbol, testLot, price, marginRequired)) break;
            }
            lotSize = testLot;
         }
      }
   }

   if(lotStep > 0.0) lotSize = MathFloor(lotSize / lotStep) * lotStep;
   return NormalizeDouble(lotSize, 2);
}

void OpenAggressiveTrade(int dir) {
   double lotSize = CalculateLotSize(dir);

   if(lotSize <= 0.0 || lotSize < MinLotSize) {
      Print("TMB ERROR: Invalid lot size: ", DoubleToString(lotSize, 4));
      return;
   }

   double stopLoss = 0.0;
   bool sent = false;
   if(dir == 1)  sent = trade.Buy(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), stopLoss, 0);
   if(dir == -1) sent = trade.Sell(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), stopLoss, 0);

   if(sent) {
      ulong ticket = 0;
      if(trade.ResultDeal() > 0) {
         if(HistoryDealSelect(trade.ResultDeal()))
            ticket = HistoryDealGetInteger(trade.ResultDeal(), DEAL_POSITION_ID);
      }

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

            if(basketDirection == 0) {
               basketDirection = dir;
               if(basketStartTime == 0) {
                  basketStartTime = TimeCurrent();
                  basketStartCapital = AccountInfoDouble(ACCOUNT_BALANCE);
                  lastCloseWasForcedLoss = false;
                  basketMinEquity = AccountInfoDouble(ACCOUNT_EQUITY);
                  basketMaxDrawdown = 0.0;
               }
            }

            if(basketDirection != 0 && basketDirection != dir) {
               Print("ERROR: Basket direction mismatch! Expected: ", basketDirection, " Got: ", dir);
               return;
            }

            activeTrades[activeTradeCount].ticket = ticket;
            activeTrades[activeTradeCount].entryPrice = entryPrice;
            activeTrades[activeTradeCount].openTime = openTime;
            activeTradeCount++;

            totalTradesOpened++;
            Print("TMB: Trade opened #", totalTradesOpened, " Lot:", DoubleToString(lotSize, 2),
                  " (Safe: ", (totalTradesOpened <= SafeTradeCount ? "YES" : "NO"), ")");

            if(EnableDailyLimit) dailyTradeCount++;
         }
      }
   }
}

void RemoveTrade(int index) {
   for(int i = index; i < activeTradeCount - 1; i++) activeTrades[i] = activeTrades[i+1];
   activeTradeCount--;
}

// =====================================================================================================
// SYNC FUNCTIONS
// =====================================================================================================

void SyncWithExistingPositions() {
   activeTradeCount = 0;
   for(int i = 0; i < 50; i++) activeTrades[i].ticket = 0;

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

   RecalculateBasketDirection();
}

void RecalculateBasketDirection() {
   int totalPositions = PositionsTotal();
   int buyCount = 0, sellCount = 0;

   for(int i = totalPositions - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(posType == POSITION_TYPE_BUY) buyCount++;
            else if(posType == POSITION_TYPE_SELL) sellCount++;
         }
      }
   }

   if(buyCount > 0 && sellCount == 0)       basketDirection = 1;
   else if(sellCount > 0 && buyCount == 0)  basketDirection = -1;
   else if(buyCount == 0 && sellCount == 0) basketDirection = 0;
   else basketDirection = (buyCount > sellCount) ? 1 : -1;
}
