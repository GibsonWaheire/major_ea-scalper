
#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "5.01"
#property strict

#define MAX_ACTIVE_TRADES 50     // BROKER-SAFE: Reduced from 1000 to prevent hyper-activity
#define MAX_PENDING_ORDERS 20    // BROKER-SAFE: Reduced from 400 to prevent order spamming

input group "===== Dynamic Lot Sizing ====="
input double   AccountBalance_10K  = 1000000.0;
input double   AccountBalance_100  = 100000.0;
input double   AccountBalance_1500 = 500000.0;
input double   MinLotSize          = 0.01;
input double   MaxLotSize          = 0.10;

input group "===== Core Trading Settings ====="
input int      MagicNumber         = 202503;
input int      MaxTrades           = 30;     // BROKER-SAFE: Reduced from 1000 to prevent hyper-activity
input int      TradesPerBurst      = 1;      // BROKER-SAFE: Reduced from 5 to single trade execution
input int      BurstDelayMS        = 700;    // BROKER-SAFE: Increased from 100ms to 500-900ms range

input group "===== Adaptive Profit Engine ====="
enum EquityTargetPresetOption
{
   EquityTarget_1Percent = 1,
   EquityTarget_2Percent = 2,
   EquityTarget_4Percent = 4
};
input EquityTargetPresetOption EquityTargetPreset = EquityTarget_2Percent;
input bool     UseCustomEquityTarget = false;
input double   CustomEquityPercent  = 2.0;
input bool     UseRiskRewardTarget  = false;
input double   RiskRewardMultiplier = 3.0;
input double   PeakGivebackPercent = 30.0;
input int      MinimumHoldMS       = 5000;  // INCREASED: Minimum hold 5 seconds (was 100ms)
input double   MaxSpreadPips       = 12.0;  // FIX: Increased from 3.0 to 12.0 for Gold (needs 8-12 pips)

input group "===== Trading Controls ====="
input bool     TradeEnabled        = true;
input int      TickDelay           = 1;
input int      MaxConsecutiveLosses= 5;
input bool     UseGoldOnly         = true;
input int      MaxDailyTrades      = 999999;  // Increased from 100000 - effectively unlimited

input group "===== Risk Parameters ====="
input double   StopLossPips        = 50.0;

input group "===== Strategy Settings ====="
input int      TrendPeriod         = 10;
input int      MomentumPeriod      = 9;
input double   MinMomentumStrength = 20.0;
input bool     OnlyTrendTrades     = false;

input group "===== Per-Trade Exit Options ====="
input bool     UseTakeProfitPips   = false;
input double   TakeProfitPips      = 150.0;
input bool     UseTrailingStop     = true;
input double   TrailingStartPips   = 120.0;
input double   TrailingStepPips    = 60.0;
input double   PerTradeProfitLock  = 5000.0;

input group "===== Instant Profit Exit ====="
input bool     UseInstantProfitExit = false; // DISABLED: Allow trades to develop more
input double   InstantProfitPips    = 10.0;  // INCREASED: Exit at 10 pips (was 3.0)
input bool     ExitOnAnyProfit      = false; // DISABLED: Don't exit on any profit
input int      QuickExitSeconds     = 300;   // INCREASED: Exit with profit after 5 minutes (was 10 seconds)

input group "===== Pattern Recovery Settings ====="
input bool     UsePatternRecovery      = true;
input int      LosingSellStreakTrigger = 2;
input int      LosingBuyStreakTrigger  = 2;
input int      RecoveryBuyBurst        = 3;
input int      RecoverySellBurst       = 3;
input bool     PatternRequiresSignal   = true;
input bool     UseImmediateReversal    = true;
input int      ImmediateReversalBursts = 1;

input group "===== Exposure Governor ====="
input bool     UseExposureGovernor        = true;
input double   MinFreeMarginPercent       = 30.0;  // FIX: Reduced from 60.0 to 30.0 to allow more trades
input double   MinEquityPercent           = 50.0;  // FIX: Reduced from 85.0 to 50.0 to keep exposureScale near 1.0
input double   MinLotScaleFactor          = 0.10;
input double   BurstScaleMin              = 0.25;
input double   BurstScaleMax              = 1.0;
input int      GovernorRefreshSeconds     = 30;

input group "===== Risk Controls (Guardrails) ====="
input bool     UseGuardrails           = true;
input double   MaxDailyLossPercent        = 5.0;
input double   MaxDailyProfitPercent      = 8.0;
input int      MaxHoldSeconds             = 900;   // BROKER-SAFE: Max 15 minutes per trade (reduced from 1800)
input double   QuickExitPips              = 10.0;   // INCREASED: Quick exit at 10 pips profit (was 3.0)
input bool     ForceQuickExit             = false; // DISABLED: Don't force quick exit
input int      MaxHoldSecondsLoss         = 600;   // INCREASED: Close losing trades after 10 minutes (was 30 seconds)
input bool     UseTrendReversalProtection = true;  // Close trades when trend reverses against position
input int      TrendReversalMinHoldSec    = 5;     // Minimum hold before checking trend reversal

input group "===== Broker Safe Mode ====="
input bool     BrokerSafeMode            = true;   // Enable broker-safe trading to avoid hyper-activity violations
input int      MinHoldTimeSec            = 5;      // FIX: Reduced from 20 to 5 seconds to allow faster exits
input int      MaxTradeLifeMinutes       = 15;     // BROKER-SAFE: Auto-close stuck trades after X minutes
input int      MaxLimitOrdersPerSymbol   = 3;      // BROKER-SAFE: Max pending limit orders per symbol
input int      MaxRequestsPerSecond      = 5;      // FIX: Increased from 1 to 5 to allow more requests
input bool     UseRandomDelays           = true;   // BROKER-SAFE: Add random delays between trades (human-like)

input group "===== Lot Growth Settings ====="
input double   ProfitStepForLotIncrease= 20.0;
input double   LotIncrementPerStep     = 0.01;

input group "===== Pending Order Grid ====="
input bool     UsePendingOrders        = true;  // Enable pending order grid
input double   LimitOffsetPips            = 1.2;  // Distance from trend EMA for limit orders
input double   LimitGridSpacingPips       = 2.0;
input int      PendingLimitOrdersPerSide  = 5;
input double   StopOffsetPips             = 0.0;  // Distance from trend EMA for stop orders
input double   StopGridSpacingPips        = 0.0;
input int      PendingStopOrdersPerSide   = 0;
input int      PendingOrderLifetimeMinutes= 1;   // REDUCED: Close pending orders after 1 min if not executed
input int      ActiveReplenishThreshold   = 3;
input bool     ForceTPOnPendingOrders     = true;  // Force TP on pending orders (scalping style)
input double   PendingOrderTPPips         = 5.0;   // TP for pending orders when they execute

input group "===== Market Execution ====="
input bool     UseMarketBursts            = true;  // Use market orders (BUY/SELL) in addition to pending
input int      MarketBurstSize            = 2;
input double   MarketEntryScoreThreshold  = 2.0;   // FIX: Reduced from 3.5 to 2.0 to allow more trades
input int      MarketBurstCooldownSec     = 45;

input group "===== Timed Trade Control ====="
input int      Pause1_Minutes             = 3;     // First pause duration in minutes
input int      Resume1_Minutes            = 2;     // First resume duration in minutes
input int      Pause2_Minutes             = 4;     // Second pause duration in minutes
input int      Resume2_Minutes            = 1;     // Second resume duration in minutes
input double   PauseEntryMultiplier       = 3.0;   // Multiplier for entry distances during pause

struct QuickTrade {
   int      ticket;
   double   entryPrice;
   datetime openTime;
   int      direction;
   ulong    openTickTime;
   bool     trailingArmed;
   double   highWatermark;
   double   lowWatermark;
};

struct PendingOrderInfo
{
   int      ticket;
   int      type;
   datetime placed;
};

QuickTrade activeTrades[MAX_ACTIVE_TRADES];
PendingOrderInfo pendingOrders[MAX_PENDING_ORDERS];
int totalPendingOrders = 0;
datetime lastPendingBatchTime = 0;
int lastActiveRefreshCount = 0;
int totalActiveTrades = 0;
int lastTickCount = 0;
double dailyProfit = 0;
datetime lastDayReset = 0;
bool tradingAllowed = true;
int dailyTradeCount = 0;
datetime lastTradeTime = 0;
double highestBasketProfit = 0;
bool basketTrailingActive = false;
double lastDynamicTarget = 0;
double lastTrailLevel = 0;

int consecutiveLosses = 0;
double lastTradePL = 0;
int lastTradeDirection = -1;
bool strategyShifted = false;
int consecutiveTradeCount = 0;

double lastPrice = 0;
int priceChangeCount = 0;
double tickSum = 0;

int consecutiveBuyLosses = 0;
int consecutiveSellLosses = 0;
int forcedDirection = -1;
int forcedBurstsRemaining = 0;
bool forcedBurstOverride = false;
double initialAccountBalance = 0.0;
double exposureScale = 1.0;
datetime lastGovernorRefresh = 0;
int effectiveMaxTrades = 12;
double effectiveLotScale = 1.0;
int effectiveBurstSize = 5;
int effectivePendingLimitsSide = 5;
int effectivePendingStopsSide = 0;
int effectiveMarketBurstSize = 2;
bool guardrailActive = false;
double guardrailPnlPercent = 0.0;
datetime lastMarketBurstTime = 0;
int lastBuyScore = 0;
int lastSellScore = 0;

// BROKER-SAFE: Request rate control variables
datetime lastRequestTime = 0;
int totalRequestsThisSecond = 0;
datetime currentSecond = 0;

// Timed Trade Control System variables
datetime cycleStartTime = 0;
bool inPauseMode = false;
double effectiveMaxSpreadPips = 12.0;
double effectiveLimitOffsetPips = 1.2;
double effectiveStopOffsetPips = 0.0;

int OnInit()
{
   Print("========================================");
   Print("QuickScalperPro EA v5.01 Improved Initialized");
   Print("========================================");
   Print("Strategy: Combined V3 + TickBased Features");
   Print("Symbol: ", Symbol());
   Print("Timeframe: ", Period());

   if(UseGoldOnly && Symbol() != "XAUUSD")
   {
      Alert("ERROR: This EA is optimized for XAUUSD only!");
      return(INIT_FAILED);
   }

   totalActiveTrades = 0;
   lastTickCount = 0;
   dailyTradeCount = 0;

   for(int i = 0; i < MAX_ACTIVE_TRADES; i++)
   {
      activeTrades[i].ticket = -1;
      activeTrades[i].entryPrice = 0;
      activeTrades[i].openTime = 0;
      activeTrades[i].direction = -1;
      activeTrades[i].openTickTime = 0;
      activeTrades[i].trailingArmed = false;
      activeTrades[i].highWatermark = 0;
      activeTrades[i].lowWatermark = 0;
   }

   for(int j = 0; j < MAX_PENDING_ORDERS; j++)
   {
      pendingOrders[j].ticket = -1;
      pendingOrders[j].type = -1;
      pendingOrders[j].placed = 0;
   }
   totalPendingOrders = 0;
   lastPendingBatchTime = 0;
   lastActiveRefreshCount = 0;

   initialAccountBalance = AccountBalance();
   if(initialAccountBalance <= 0.0)
      initialAccountBalance = AccountBalance();

   // Initialize timed trade control cycle
   cycleStartTime = TimeCurrent();
   inPauseMode = false;
   effectiveMaxSpreadPips = MaxSpreadPips;
   effectiveLimitOffsetPips = LimitOffsetPips;
   effectiveStopOffsetPips = StopOffsetPips;

   exposureScale = 1.0;
   effectiveMaxTrades = MaxTrades;
   effectiveLotScale = 1.0;
   // BROKER-SAFE: Force single trade execution when broker-safe mode is enabled
   if(BrokerSafeMode)
   {
      effectiveBurstSize = (int)1;
      effectiveMarketBurstSize = (int)1;
   }
   else
   {
      effectiveBurstSize = TradesPerBurst;
      effectiveMarketBurstSize = MarketBurstSize;
   }
   effectivePendingLimitsSide = PendingLimitOrdersPerSide;
   effectivePendingStopsSide = PendingStopOrdersPerSide;
   lastGovernorRefresh = 0;
   lastMarketBurstTime = 0;
   UpdateExposureGovernor();

   double minStopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL);

   Print("Initialization successful!");
   Print("========================================");
   Print("ADAPTIVE PROFIT ENGINE ACTIVE");
   double initTarget = GetEquityTargetPercent();
   Print("Equity Target: ", DoubleToString(initTarget, 2), "% | RR Target ",
         (UseRiskRewardTarget ? "ON" : "OFF"), " (x", DoubleToString(RiskRewardMultiplier, 2),
         ") | Giveback: ", DoubleToString(PeakGivebackPercent, 2), "%");
   Print("Minimum Hold: ", MinimumHoldMS, " ms | Max Spread: ", MaxSpreadPips, " pips");
   Print("Lot Bounds: Min=", MinLotSize, " | Max=", MaxLotSize);
   if(UsePatternRecovery)
      Print("PATTERN RECOVERY: ENABLED");
   if(UseExposureGovernor)
      Print("EXPOSURE GOVERNOR: ENABLED");
   if(UseGuardrails)
      Print("GUARDRAILS: ENABLED | Max Loss: ", MaxDailyLossPercent, "% | Max Profit: ", MaxDailyProfitPercent, "%");
   if(UsePendingOrders)
      Print("PENDING ORDERS: ENABLED | Limits: ", PendingLimitOrdersPerSide, " per side | Stops: ", PendingStopOrdersPerSide, " per side");
   if(UseMarketBursts)
      Print("MARKET BURSTS: ENABLED | Size: ", MarketBurstSize, " | Score Threshold: ", MarketEntryScoreThreshold);
   Print("========================================");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   CancelAllPendingOrders();
   Print("QuickScalperPro EA v5.01 Improved Deinitialized. Reason: ", reason);
}

void OnTick()
{
   CheckDailyReset();

   // ==== TIMED TRADE CONTROL SYSTEM ====
   int secs = TimeCurrent() - cycleStartTime;

   int pause1 = Pause1_Minutes * 60;
   int resume1 = pause1 + Resume1_Minutes * 60;
   int pause2 = resume1 + Pause2_Minutes * 60;
   int resume2 = pause2 + Resume2_Minutes * 60;

   // Determine state
   if(secs < pause1)
      inPauseMode = false;
   else if(secs < resume1)
      inPauseMode = true;
   else if(secs < pause2)
      inPauseMode = false;
   else if(secs < resume2)
      inPauseMode = true;
   else {
      // restart full cycle
      cycleStartTime = TimeCurrent();
      inPauseMode = false;
   }

   // When paused: increase distance for entries, but DO NOT disable EA logic
   if(inPauseMode)
   {
      effectiveMaxSpreadPips = MaxSpreadPips * PauseEntryMultiplier;
      effectiveLimitOffsetPips = LimitOffsetPips * PauseEntryMultiplier;
      effectiveStopOffsetPips = StopOffsetPips * PauseEntryMultiplier;
   }
   else
   {
      effectiveMaxSpreadPips = MaxSpreadPips;
      effectiveLimitOffsetPips = LimitOffsetPips;
      effectiveStopOffsetPips = StopOffsetPips;
   }
   // ==== END TIMED TRADE CONTROL SYSTEM ====

   bool preflightOk = PreFlightChecks();
   bool allowNewTrades = preflightOk && tradingAllowed && !guardrailActive;

   // BROKER-SAFE: Check broker-safe mode conditions
   if(BrokerSafeMode)
   {
      if(SpreadTooHigh())
      {
         Comment("BROKER-SAFE: Spread too high - trading paused");
         UpdateDisplay();
         return;
      }
      
      if(TooManyRequests())
      {
         // Rate limiting active - skip this tick
         UpdateDisplay();
         return;
      }
   }

   TrackTickMovement();

   ManageActiveTrades();

   CleanupClosedTrades();

   if(UsePendingOrders && allowNewTrades)
   {
      MaintainPendingOrders();
   }

   if(allowNewTrades && IsSpreadAcceptable())
   {
      if(UseMarketBursts)
      {
         AttemptMarketEntries();
      }
      else
      {
         LookForScalpingOpportunity();
      }
   }

   UpdateDisplay();
}

double CalculateDynamicLotSize()
{
   double currentBalance = AccountBalance();

   double baseLot = MinLotSize * effectiveLotScale;

   if(currentBalance >= AccountBalance_10K)
   {
      baseLot = MathMax(baseLot, 0.10);
   }
   else if(currentBalance >= AccountBalance_1500)
   {
      baseLot = MathMax(baseLot, 0.08);
   }
   else if(currentBalance >= AccountBalance_100)
   {
      baseLot = MathMax(baseLot, 0.05);
   }

   double progressiveLot = baseLot;
   if(dailyProfit > 0 && ProfitStepForLotIncrease > 0.0 && LotIncrementPerStep > 0.0)
   {
      double steps = MathFloor(dailyProfit / ProfitStepForLotIncrease);
      progressiveLot += LotIncrementPerStep * steps;
   }

   progressiveLot = MathMin(progressiveLot, MaxLotSize);
   progressiveLot = MathMax(progressiveLot, MinLotSize);

   return NormalizeDouble(progressiveLot, 2);
}

bool IsSpreadAcceptable()
{
   double currentSpread = (Ask - Bid) / Point / 10.0;
   return (currentSpread <= effectiveMaxSpreadPips);
}

// BROKER-SAFE: Check if spread is too high
bool SpreadTooHigh()
{
   if(!BrokerSafeMode) return false;
   double spread = (Ask - Bid) / Point / 10.0;
   return (spread > effectiveMaxSpreadPips);
}

// BROKER-SAFE: Check if too many requests (rate limiting)
bool TooManyRequests()
{
   if(!BrokerSafeMode) return false;
   if(MaxRequestsPerSecond <= 0) return false;
   
   datetime now = TimeCurrent();
   
   // Reset counter if we're in a new second
   if(now != currentSecond)
   {
      currentSecond = now;
      totalRequestsThisSecond = 0;
   }
   
   if(totalRequestsThisSecond >= MaxRequestsPerSecond)
   {
      return true; // Too many requests this second
   }
   
   // Check time since last request
   if(lastRequestTime > 0 && (now - lastRequestTime) < 1)
   {
      return true; // Less than 1 second since last request
   }
   
   return false;
}

// BROKER-SAFE: Record request
void RecordRequest()
{
   if(!BrokerSafeMode) return;
   datetime now = TimeCurrent();
   
   if(now != currentSecond)
   {
      currentSecond = now;
      totalRequestsThisSecond = 0;
   }
   
   totalRequestsThisSecond++;
   lastRequestTime = now;
}

// BROKER-SAFE: Check if trade is too old (stuck trade)
bool IsTradeTooOld(int ticket)
{
   if(!BrokerSafeMode || MaxTradeLifeMinutes <= 0) return false;
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return false;
   
   datetime openTime = OrderOpenTime();
   int ageMinutes = (int)((TimeCurrent() - openTime) / 60);
   
   return (ageMinutes >= MaxTradeLifeMinutes);
}

// BROKER-SAFE: Check minimum hold time before closing
bool CanCloseTrade(int ticket)
{
   if(!BrokerSafeMode || MinHoldTimeSec <= 0) return true;
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return false;
   
   datetime openTime = OrderOpenTime();
   int holdSeconds = (int)(TimeCurrent() - openTime);
   
   return (holdSeconds >= MinHoldTimeSec);
}

// BROKER-SAFE: Count limit orders for symbol
int CountLimitOrdersForSymbol(string symbol)
{
   int count = 0;
   int total = OrdersTotal();
   
   for(int i = 0; i < total; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS)) continue;
      if(OrderSymbol() != symbol || OrderMagicNumber() != MagicNumber) continue;
      
      int type = OrderType();
      if(type == OP_BUYLIMIT || type == OP_SELLLIMIT)
         count++;
   }
   
   return count;
}

void TrackTickMovement()
{
   double currentPrice = (Ask + Bid) / 2.0;

   if(lastPrice != 0)
   {
      double priceChange = currentPrice - lastPrice;
      tickSum += priceChange;
      priceChangeCount++;

      if(priceChangeCount >= 10)
      {
         priceChangeCount = 0;
         tickSum = 0;
      }
   }

   lastPrice = currentPrice;
}

void LookForScalpingOpportunity()
{
   if(dailyTradeCount >= MaxDailyTrades)
   {
      Comment("Daily trade limit reached: ", dailyTradeCount, "/", MaxDailyTrades);
      return;
   }

   // BROKER-SAFE: Single execution per tick (no loops)
   if(totalActiveTrades >= effectiveMaxTrades || dailyTradeCount >= MaxDailyTrades)
      return;

   int signal = GetScalpingSignal();

   if(signal == OP_BUY || signal == OP_SELL)
   {
      // BROKER-SAFE: Execute only ONE trade per tick (no burst loops)
      if(signal == OP_BUY)
         OpenScalpTrade(OP_BUY);
      else
         OpenScalpTrade(OP_SELL);
   }
}

int GetScalpingSignal()
{
   double currentSpread = (Ask - Bid) / Point / 10.0;
   bool acceptableSpread = (currentSpread <= effectiveMaxSpreadPips);

   if(!acceptableSpread) return -1;

   // Check forced direction from pattern recovery
   if(forcedDirection == OP_BUY || forcedDirection == OP_SELL)
   {
      if(forcedBurstsRemaining > 0)
      {
         bool allowOverride = forcedBurstOverride || !PatternRequiresSignal;
         if(allowOverride)
            return forcedDirection;
      }
   }

   double ema_fast = iMA(Symbol(), PERIOD_M1, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema_slow = iMA(Symbol(), PERIOD_M1, TrendPeriod * 2, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi = iRSI(Symbol(), PERIOD_M1, MomentumPeriod, PRICE_CLOSE, 0);
   double currentPrice = (Ask + Bid) / 2.0;

   bool uptrend = ema_fast > ema_slow;
   bool downtrend = ema_fast < ema_slow;
   bool priceAboveEMA = currentPrice > ema_fast;
   bool priceBelowEMA = currentPrice < ema_fast;

   bool oversold = rsi < (50 - MinMomentumStrength);
   bool overbought = rsi > (50 + MinMomentumStrength);
   bool bullishMomentum = rsi > 50 && rsi < 70;
   bool bearishMomentum = rsi < 50 && rsi > 30;

   double previousClose = iClose(Symbol(), PERIOD_M1, 1);
   double currentClose = iClose(Symbol(), PERIOD_M1, 0);
   bool risingPrice = currentClose > previousClose;
   bool fallingPrice = currentClose < previousClose;

   bool buySignal = false;
   int buyScore = 0;

   if(uptrend) buyScore++;
   if(priceAboveEMA) buyScore++;
   if(bullishMomentum || oversold) buyScore++;
   if(risingPrice) buyScore++;

   if(OnlyTrendTrades)
   {
      buySignal = (buyScore >= 2);
   }
   else
   {
      buySignal = (buyScore >= 1);
   }

   bool sellSignal = false;
   int sellScore = 0;

   if(downtrend) sellScore++;
   if(priceBelowEMA) sellScore++;
   if(bearishMomentum || overbought) sellScore++;
   if(fallingPrice) sellScore++;

   if(OnlyTrendTrades)
   {
      sellSignal = (sellScore >= 2);
   }
   else
   {
      sellSignal = (sellScore >= 1);
   }

   if(consecutiveLosses >= MaxConsecutiveLosses)
   {
      if(UsePatternRecovery)
      {
         int forcedBias = -1;
         if(lastTradeDirection == OP_BUY)
            forcedBias = OP_SELL;
         else if(lastTradeDirection == OP_SELL)
            forcedBias = OP_BUY;

         if(forcedBias != -1)
         {
            int burst = (forcedBias == OP_BUY) ? RecoveryBuyBurst : RecoverySellBurst;
            if(burst > 0)
               StartForcedSequence(forcedBias, burst, "max-loss recovery");
         }
      }

      if(buyScore >= 2) return OP_BUY;
      if(sellScore >= 2) return OP_SELL;
      return -1;
   }

   if(buySignal && sellSignal)
   {
      if(buyScore > sellScore)
         return OP_BUY;
      else if(sellScore > buyScore)
         return OP_SELL;
      else
         return -1;
   }
   else if(buySignal)
   {
      return OP_BUY;
   }
   else if(sellSignal)
   {
      return OP_SELL;
   }

   return -1;
}

void StartForcedSequence(int direction, int bursts, string context)
{
   if(!UsePatternRecovery)
      return;

   if(direction != OP_BUY && direction != OP_SELL)
      return;

   forcedDirection = direction;
   forcedBurstsRemaining = MathMax(bursts, 0);
   forcedBurstOverride = false;
   Print("Pattern recovery trigger (", context, "): forcing ", 
         (direction == OP_BUY ? "BUY" : "SELL"), " for next ", forcedBurstsRemaining, " burst(s).");
}

void CompleteForcedBurst(bool executedTrades)
{
   if(!executedTrades)
      return;

   if(forcedDirection == -1)
   {
      forcedBurstsRemaining = 0;
      forcedBurstOverride = false;
      return;
   }

   if(forcedBurstsRemaining > 0)
   {
      forcedBurstsRemaining--;
      if(forcedBurstsRemaining <= 0)
      {
         forcedDirection = -1;
         forcedBurstsRemaining = 0;
         forcedBurstOverride = false;
         Print("Pattern recovery burst completed.");
      }
   }
}

int OpenScalpTrade(int orderType)
{
   double price = (orderType == OP_BUY) ? Ask : Bid;

   double lotSize = CalculateDynamicLotSize();
   double sl = 0;
   double tp = 0;
   double pipToPoint = Point * 10.0;

   if(!IsSpreadAcceptable())
   {
      Print("Trade blocked - Spread too high: ", DoubleToString((Ask - Bid) / Point / 10.0, 1));
      return 0;
   }

   double stopLossPips = StopLossPips;
   if(stopLossPips > 0.0 && pipToPoint > 0.0)
   {
      double slDistance = stopLossPips * pipToPoint;
      if(orderType == OP_BUY)
         sl = NormalizeDouble(price - slDistance, Digits);
      else
         sl = NormalizeDouble(price + slDistance, Digits);
   }

   if(UseTakeProfitPips && TakeProfitPips > 0.0 && pipToPoint > 0.0)
   {
      double tpDistance = TakeProfitPips * pipToPoint;
      if(orderType == OP_BUY)
         tp = NormalizeDouble(price + tpDistance, Digits);
      else
         tp = NormalizeDouble(price - tpDistance, Digits);
   }

   string comment = "ScalpProV5_Improved " + (orderType == OP_BUY ? "BUY" : "SELL") + " Lot:" + DoubleToString(lotSize, 2);
   color arrowColor = (orderType == OP_BUY) ? clrGreen : clrRed;

   // BROKER-SAFE: Record request before sending
   RecordRequest();

   int ticket = OrderSend(Symbol(), orderType, lotSize, price, 3, sl, tp,
                          comment, MagicNumber, 0, arrowColor);

   // BROKER-SAFE: Add random delay after order execution (human-like pattern)
   if(ticket > 0 && UseRandomDelays)
   {
      int delay = 100 + (MathRand() % 200); // Random delay 100-300ms
      Sleep(delay);
   }

   if(ticket > 0)
   {
      dailyTradeCount++;
      lastTradeTime = TimeCurrent();

      if(lastTradeDirection == orderType)
      {
         consecutiveTradeCount++;
      }
      else
      {
         consecutiveTradeCount = 1;
         lastTradeDirection = orderType;
      }

      // Strict bounds checking to prevent array out of range error
      if(totalActiveTrades >= 0 && totalActiveTrades < MAX_ACTIVE_TRADES)
      {
         int arraySize = ArraySize(activeTrades);
         if(totalActiveTrades >= arraySize)
         {
            Print("ERROR: totalActiveTrades (", totalActiveTrades, ") >= ArraySize (", arraySize, ") - preventing array overflow in OpenScalpTrade");
            return ticket; // Return ticket but don't add to array
         }
         
         activeTrades[totalActiveTrades].ticket = ticket;
         activeTrades[totalActiveTrades].entryPrice = price;
         activeTrades[totalActiveTrades].openTime = TimeCurrent();
         activeTrades[totalActiveTrades].direction = orderType;
         activeTrades[totalActiveTrades].openTickTime = GetTickCount();
         activeTrades[totalActiveTrades].trailingArmed = false;
         activeTrades[totalActiveTrades].highWatermark = price;
         activeTrades[totalActiveTrades].lowWatermark = price;
         
         // Increment AFTER successful assignment to prevent index issues
         int newCount = totalActiveTrades + 1;
         if(newCount <= MAX_ACTIVE_TRADES && newCount <= arraySize)
         {
            totalActiveTrades = newCount;
         }
         else
         {
            Print("WARNING: Cannot increment totalActiveTrades - at maximum capacity (", MAX_ACTIVE_TRADES, ")");
         }
      }

      Print("Basket trade #", dailyTradeCount, " opened: ", comment, " | Ticket: ", ticket,
            " | Price: ", DoubleToString(price, Digits), " | Lot: ", DoubleToString(lotSize, 2),
            " | Basket: ", totalActiveTrades, "/", effectiveMaxTrades);
      
      CompleteForcedBurst(true);
      return ticket;
   }
   else
   {
      Print("Error opening scalp trade: ", GetLastError());
      return 0;
   }
}

double GetPipValuePerLot()
{
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
   double pipSize = Point * 10.0;

   if(tickSize <= 0.0 || pipSize <= 0.0)
      return(0.0);

   return (tickValue / tickSize) * pipSize;
}

double GetEquityTargetPercent()
{
   double percent = (double)EquityTargetPreset;
   if(UseCustomEquityTarget && CustomEquityPercent > 0.0)
      percent = CustomEquityPercent;

   if(percent <= 0.0)
      percent = 1.0;

   return percent;
}

void UpdatePerTradeTrailing(int index, double pipToPoint)
{
   if(!UseTrailingStop || TrailingStartPips <= 0.0 || TrailingStepPips <= 0.0)
      return;

   if(index < 0 || index >= totalActiveTrades)
      return;

   int ticket = activeTrades[index].ticket;
   if(ticket <= 0)
      return;

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return;

   if(OrderCloseTime() > 0)
      return;

   int type = OrderType();
   double price = (type == OP_BUY) ? Bid : Ask;
   double entry = activeTrades[index].entryPrice;

   if(pipToPoint <= 0.0)
      return;

   double startDistance = TrailingStartPips * pipToPoint;
   double stepDistance  = TrailingStepPips * pipToPoint;

   if(type == OP_BUY)
   {
      activeTrades[index].highWatermark = MathMax(activeTrades[index].highWatermark, price);
      double moveDistance = activeTrades[index].highWatermark - entry;
      if(!activeTrades[index].trailingArmed && moveDistance >= startDistance)
         activeTrades[index].trailingArmed = true;

      if(activeTrades[index].trailingArmed)
      {
         double newStop = NormalizeDouble(activeTrades[index].highWatermark - stepDistance, Digits);
         if(newStop > OrderStopLoss() && newStop < price)
            ModifyOrderStop(ticket, newStop);
      }
   }
   else if(type == OP_SELL)
   {
      activeTrades[index].lowWatermark = MathMin(activeTrades[index].lowWatermark, price);
      double moveDistance = entry - activeTrades[index].lowWatermark;
      if(!activeTrades[index].trailingArmed && moveDistance >= startDistance)
         activeTrades[index].trailingArmed = true;

      if(activeTrades[index].trailingArmed)
      {
         double newStop = NormalizeDouble(activeTrades[index].lowWatermark + stepDistance, Digits);
         if((OrderStopLoss() == 0 || newStop < OrderStopLoss()) && newStop > price)
            ModifyOrderStop(ticket, newStop);
      }
   }
}

bool ModifyOrderStop(int ticket, double newStop)
{
   if(newStop <= 0.0)
      return(false);

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return(false);

   if(OrderCloseTime() > 0)
      return(false);

   double price = OrderOpenPrice();
   double tp = OrderTakeProfit();

   if(!OrderModify(ticket, price, newStop, tp, OrderExpiration()))
   {
      Print("OrderModify failed ticket=", ticket, " error=", GetLastError());
      return(false);
   }

   return(true);
}

double GetFreeMarginPercent()
{
   double freeMargin = AccountFreeMargin();
   double equity = AccountEquity();
   if(equity <= 0.0)
      return 0.0;
   return (freeMargin / equity) * 100.0;
}

double GetEquityDrawdownPercent()
{
   if(initialAccountBalance <= 0.0)
      return 0.0;

   double dd = (initialAccountBalance - AccountEquity());
   if(dd <= 0.0)
      return 0.0;

   return (dd / initialAccountBalance) * 100.0;
}

void UpdateExposureGovernor()
{
   if(!UseExposureGovernor)
   {
      exposureScale = 1.0;
      effectiveMaxTrades = MaxTrades;
      effectiveLotScale = 1.0;
      effectiveBurstSize = TradesPerBurst;
      effectivePendingLimitsSide = PendingLimitOrdersPerSide;
      effectivePendingStopsSide = PendingStopOrdersPerSide;
      effectiveMarketBurstSize = MarketBurstSize;
      return;
   }

   datetime nowTime = TimeCurrent();
   if(GovernorRefreshSeconds > 0 && lastGovernorRefresh > 0 &&
      (nowTime - lastGovernorRefresh) < GovernorRefreshSeconds)
      return;

   lastGovernorRefresh = nowTime;

   double freeMarginPct = GetFreeMarginPercent();
   double ddPct = GetEquityDrawdownPercent();

   double marginScale = 1.0;
   if(MinFreeMarginPercent > 0.0)
      marginScale = MathMin(1.0, MathMax(0.0, freeMarginPct / MinFreeMarginPercent));

   double equityScale = 1.0;
   if(MinEquityPercent > 0.0)
   {
      double equityPct = (initialAccountBalance > 0.0)
                         ? (AccountEquity() / initialAccountBalance) * 100.0
                         : 100.0;
      equityScale = MathMin(1.0, MathMax(0.0, equityPct / MinEquityPercent));
   }

   double ddScale = 1.0;
   if(ddPct > 0.0)
      ddScale = MathMax(0.0, 1.0 - (ddPct / 100.0));

   exposureScale = MathMin(MathMin(marginScale, equityScale), ddScale);
   exposureScale = MathMax(BurstScaleMin, MathMin(BurstScaleMax, exposureScale));

   effectiveLotScale = MathMax(MinLotScaleFactor, exposureScale);
   effectiveLotScale = MathMin(1.0, effectiveLotScale);

   // BROKER-SAFE: Force single trade execution when broker-safe mode is enabled
   if(BrokerSafeMode)
   {
      effectiveBurstSize = (int)1; // Single trade per execution
      effectiveMarketBurstSize = (int)1; // Single market trade per execution
   }
   else
   {
      effectiveBurstSize = (int)MathMax(1, MathRound(TradesPerBurst * exposureScale));
      effectiveMarketBurstSize = (int)MathMax(1, MathRound(MarketBurstSize * exposureScale));
   }
   
   effectiveMaxTrades = (int)MathMax(1, MathRound(MaxTrades * exposureScale));  // Changed from 5 to 1 to allow more flexibility
}

double ComputeDailyPnlPercent()
{
   double baseline = (initialAccountBalance > 0.0) ? initialAccountBalance : AccountBalance();
   if(baseline <= 0.0)
      return 0.0;
   return (dailyProfit / baseline) * 100.0;
}

void EvaluateGuardrails()
{
   if(!UseGuardrails)
      return;

   if(MaxDailyLossPercent <= 0.0 && MaxDailyProfitPercent <= 0.0)
      return;

   double pnlPercent = ComputeDailyPnlPercent();
   guardrailPnlPercent = pnlPercent;

   bool lossHit = (MaxDailyLossPercent > 0.0 && pnlPercent <= -MaxDailyLossPercent);
   bool profitHit = (MaxDailyProfitPercent > 0.0 && pnlPercent >= MaxDailyProfitPercent);

   bool shouldActivate = lossHit || profitHit;

   if(shouldActivate && !guardrailActive)
   {
      guardrailActive = true;
      CloseAllTrades("Guardrail triggered: Daily P&L " + DoubleToString(pnlPercent, 2) + "%");
      Print("Guardrail triggered: Daily P&L ", DoubleToString(pnlPercent, 2), "% | LossHit=",
            (lossHit ? "true" : "false"), " | ProfitHit=", (profitHit ? "true" : "false"));
   }
   else if(!shouldActivate && guardrailActive)
   {
      guardrailActive = false;
      Print("Guardrail reset - trading re-enabled.");
   }
}

void ManageActiveTrades()
{
   SyncActiveTradesWithBroker();
   UpdateExposureGovernor();

   if(totalActiveTrades == 0)
   {
      highestBasketProfit = 0;
      basketTrailingActive = false;
      lastDynamicTarget = 0;
      lastTrailLevel = 0;
      return;
   }

   ulong nowTick = GetTickCount();
   ulong minHoldMs = (MinimumHoldMS > 0) ? (ulong)MinimumHoldMS : 0;
   double pipToPoint = Point * 10.0;
   double pipValuePerLot = GetPipValuePerLot();

   double totalProfit = 0;
   double totalRiskCurrency = 0;
   bool holdSatisfied = true;

   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket <= 0)
         continue;

      if(!OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
         continue;

      int orderType = OrderType();
      if(orderType != OP_BUY && orderType != OP_SELL)
         continue;

      double entry = OrderOpenPrice();
      double currentPrice = (orderType == OP_BUY) ? Bid : Ask;
      double pipGain = 0.0;
      if(pipToPoint > 0.0)
      {
         if(orderType == OP_BUY)
            pipGain = (currentPrice - entry) / pipToPoint;
         else if(orderType == OP_SELL)
            pipGain = (entry - currentPrice) / pipToPoint;
      }

      double tradeProfit = OrderProfit() + OrderSwap() + OrderCommission();

      // EXIT MECHANISM 1: Instant Profit Exit
      double quickExitTarget = (QuickExitPips > 0.0) ? QuickExitPips : InstantProfitPips;
      if(UseInstantProfitExit && quickExitTarget > 0.0 && tradeProfit > 0.0 && pipGain >= quickExitTarget)
      {
         CloseTradeAtIndex(i, "Instant profit exit +" + DoubleToString(tradeProfit, 2));
         i--;
         continue;
      }

      // EXIT MECHANISM 2: Per-Trade Profit Lock
      if(PerTradeProfitLock > 0.0 && tradeProfit >= PerTradeProfitLock)
      {
         CloseTradeAtIndex(i, "Per-trade profit lock +" + DoubleToString(tradeProfit, 2));
         i--;
         continue;
      }

      // EXIT MECHANISM 3: Quick Exit on Any Profit (Scalping)
      ulong openTick = activeTrades[i].openTickTime;
      ulong heldMs = (openTick > 0 && nowTick >= openTick) ? (nowTick - openTick) : 0;
      ulong heldSeconds = heldMs / 1000;
      
      if(ExitOnAnyProfit && QuickExitSeconds > 0 && heldSeconds >= (ulong)QuickExitSeconds && tradeProfit > 0.0)
      {
         CloseTradeAtIndex(i, "Quick exit on profit after " + IntegerToString(heldSeconds) + "s");
         i--;
         continue;
      }
      
      // EXIT MECHANISM 4: Force Quick Exit on Loss (Scalping)
      if(ForceQuickExit && MaxHoldSecondsLoss > 0 && heldSeconds >= (ulong)MaxHoldSecondsLoss && tradeProfit < 0.0)
      {
         CloseTradeAtIndex(i, "Quick exit on loss after " + IntegerToString(heldSeconds) + "s");
         i--;
         continue;
      }

      // EXIT MECHANISM 5: Max Hold Time
      if(minHoldMs > 0)
      {
         if(heldMs < minHoldMs)
            holdSatisfied = false;
         
         ulong maxHoldMs = (MaxHoldSeconds > 0) ? (ulong)MaxHoldSeconds * 1000 : 0;
         if(maxHoldMs > 0 && heldMs >= maxHoldMs)
         {
            CloseTradeAtIndex(i, "Max hold exit after " + IntegerToString(MaxHoldSeconds) + "s");
            i--;
            continue;
         }
      }

      // BROKER-SAFE: Exit mechanism - Auto-close stuck trades (max trade life)
      if(BrokerSafeMode && MaxTradeLifeMinutes > 0)
      {
         datetime openTime = OrderOpenTime();
         int ageMinutes = (int)((TimeCurrent() - openTime) / 60);
         if(ageMinutes >= MaxTradeLifeMinutes)
         {
            CloseTradeAtIndex(i, "BROKER-SAFE: Stuck trade closed after " + IntegerToString(ageMinutes) + " minutes");
            i--;
            continue;
         }
      }

      // EXIT MECHANISM 6: Trend Reversal Protection (FIXES THE MAIN PROBLEM)
      if(UseTrendReversalProtection && heldSeconds >= (ulong)TrendReversalMinHoldSec)
      {
         double ema_fast = iMA(Symbol(), PERIOD_M1, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
         double ema_slow = iMA(Symbol(), PERIOD_M1, TrendPeriod * 2, 0, MODE_EMA, PRICE_CLOSE, 0);
         double rsi = iRSI(Symbol(), PERIOD_M1, MomentumPeriod, PRICE_CLOSE, 0);
         
         bool trendReversed = false;
         
         // If we have a BUY position but trend reversed to downtrend
         if(orderType == OP_BUY)
         {
            bool currentDowntrend = (ema_fast < ema_slow);
            bool rsiBearish = (rsi < 50);
            // Close if trend reversed AND RSI confirms bearish
            if(currentDowntrend && rsiBearish)
            {
               trendReversed = true;
            }
         }
         // If we have a SELL position but trend reversed to uptrend
         else if(orderType == OP_SELL)
         {
            bool currentUptrend = (ema_fast > ema_slow);
            bool rsiBullish = (rsi > 50);
            // Close if trend reversed AND RSI confirms bullish
            if(currentUptrend && rsiBullish)
            {
               trendReversed = true;
            }
         }
         
         if(trendReversed)
         {
            CloseTradeAtIndex(i, "Trend reversal protection - trend against position");
            i--;
            continue;
         }
      }

      totalProfit += tradeProfit;

      double lotSize = OrderLots();
      double riskPips = StopLossPips;
      double stop = OrderStopLoss();

      if(stop > 0 && pipToPoint > 0)
         riskPips = MathAbs(entry - stop) / pipToPoint;

      totalRiskCurrency += riskPips * pipValuePerLot * lotSize;

      UpdatePerTradeTrailing(i, pipToPoint);
   }

   if(totalProfit > highestBasketProfit)
      highestBasketProfit = totalProfit;

   double targetPercent = GetEquityTargetPercent();
   double equityTarget = (targetPercent > 0.0)
                         ? AccountBalance() * (targetPercent / 100.0)
                         : 0.0;
   double rrTarget = 0.0;
   if(UseRiskRewardTarget && RiskRewardMultiplier > 0.0)
      rrTarget = totalRiskCurrency * RiskRewardMultiplier;

   double dynamicTarget = (UseRiskRewardTarget)
                          ? MathMax(equityTarget, rrTarget)
                          : equityTarget;
   lastDynamicTarget = dynamicTarget;

   if(dynamicTarget <= 0.0)
      dynamicTarget = equityTarget;

   bool profitReady = (totalProfit > 0.0) && holdSatisfied;

   // EXIT MECHANISM 4: Dynamic Profit Target
   if(profitReady && dynamicTarget > 0.0 && totalProfit >= dynamicTarget)
   {
      CloseAllTrades("Dynamic profit target hit: KES " + DoubleToString(totalProfit, 2));
      return;
   }

   // EXIT MECHANISM 5: Peak Trailing Stop
   if(totalProfit > 0.0 && PeakGivebackPercent > 0.0 && dynamicTarget > 0.0 && highestBasketProfit >= dynamicTarget)
   {
      basketTrailingActive = true;
      double giveback = highestBasketProfit * (PeakGivebackPercent / 100.0);
      double trailLevel = highestBasketProfit - giveback;
      lastTrailLevel = trailLevel;

      if(profitReady && highestBasketProfit > 0.0 && giveback > 0.0 && totalProfit <= trailLevel)
      {
         CloseAllTrades("Dynamic peak trail: KES " + DoubleToString(totalProfit, 2));
         return;
      }
   }
   else
   {
      basketTrailingActive = false;
      lastTrailLevel = 0;
   }
}

void SyncActiveTradesWithBroker()
{
   int total = OrdersTotal();
   for(int pos = 0; pos < total; pos++)
   {
      if(!OrderSelect(pos, SELECT_BY_POS))
         continue;

      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber)
         continue;

      int type = OrderType();
      if(type == OP_BUY || type == OP_SELL)
      {
         bool found = false;
         for(int i = 0; i < totalActiveTrades; i++)
         {
            if(activeTrades[i].ticket == OrderTicket())
            {
               found = true;
               break;
            }
         }
         // Strict bounds checking to prevent array out of range error
         if(!found && totalActiveTrades >= 0 && totalActiveTrades < MAX_ACTIVE_TRADES)
         {
            int arraySize = ArraySize(activeTrades);
            if(totalActiveTrades >= arraySize)
            {
               Print("ERROR: totalActiveTrades (", totalActiveTrades, ") >= ArraySize (", arraySize, ") - preventing array overflow");
               break; // Exit loop to prevent crash
            }
            
            activeTrades[totalActiveTrades].ticket = OrderTicket();
            activeTrades[totalActiveTrades].entryPrice = OrderOpenPrice();
            activeTrades[totalActiveTrades].openTime = OrderOpenTime();
            activeTrades[totalActiveTrades].direction = type;
            activeTrades[totalActiveTrades].openTickTime = GetTickCount();
            activeTrades[totalActiveTrades].trailingArmed = false;
            activeTrades[totalActiveTrades].highWatermark = OrderOpenPrice();
            activeTrades[totalActiveTrades].lowWatermark = OrderOpenPrice();
            
            // Increment AFTER successful assignment to prevent index issues
            int newCount = totalActiveTrades + 1;
            if(newCount <= MAX_ACTIVE_TRADES && newCount <= arraySize)
            {
               totalActiveTrades = newCount;
            }
            else
            {
               Print("WARNING: Cannot increment totalActiveTrades - at maximum capacity (", MAX_ACTIVE_TRADES, ")");
               break; // Exit loop to prevent further additions
            }
         }
      }
   }
}

void EvaluatePatternRecovery(int orderType, double finalPL)
{
   if(!UsePatternRecovery)
      return;

   bool isLoss = (finalPL < 0.0);

   if(orderType == OP_BUY)
   {
      if(isLoss)
      {
         consecutiveBuyLosses++;
         consecutiveSellLosses = 0;

         if(UseImmediateReversal)
         {
            int bursts = MathMax(ImmediateReversalBursts, 1);
            forcedDirection = OP_SELL;
            forcedBurstsRemaining = bursts;
            forcedBurstOverride = true;
            Print("Immediate reversal: forcing SELL after BUY loss");
         }

         if(LosingBuyStreakTrigger > 0 && consecutiveBuyLosses >= LosingBuyStreakTrigger)
         {
            StartForcedSequence(OP_SELL, RecoverySellBurst,
                                "buy-loss streak " + IntegerToString(consecutiveBuyLosses));
            consecutiveBuyLosses = 0;
         }
      }
      else
      {
         consecutiveBuyLosses = 0;
      }
   }
   else if(orderType == OP_SELL)
   {
      if(isLoss)
      {
         consecutiveSellLosses++;
         consecutiveBuyLosses = 0;

         if(UseImmediateReversal)
         {
            int bursts = MathMax(ImmediateReversalBursts, 1);
            forcedDirection = OP_BUY;
            forcedBurstsRemaining = bursts;
            forcedBurstOverride = true;
            Print("Immediate reversal: forcing BUY after SELL loss");
         }

         if(LosingSellStreakTrigger > 0 && consecutiveSellLosses >= LosingSellStreakTrigger)
         {
            StartForcedSequence(OP_BUY, RecoveryBuyBurst,
                                "sell-loss streak " + IntegerToString(consecutiveSellLosses));
            consecutiveSellLosses = 0;
         }
      }
      else
      {
         consecutiveSellLosses = 0;
      }
   }
}

void CloseTradeAtIndex(int index, string reason)
{
   if(index < 0 || index >= totalActiveTrades) return;

   int ticket = activeTrades[index].ticket;
   if(ticket <= 0) return;

   // BROKER-SAFE: Check minimum hold time before closing (avoid toxic flow)
   if(!CanCloseTrade(ticket))
   {
      int holdSeconds = 0;
      if(OrderSelect(ticket, SELECT_BY_TICKET))
      {
         holdSeconds = (int)(TimeCurrent() - OrderOpenTime());
      }
      // Don't close yet - trade hasn't been held long enough
      return;
   }
   
   // BROKER-SAFE: Check if trade is too old (stuck trade - force close)
   if(IsTradeTooOld(ticket))
   {
      Print("BROKER-SAFE: Force closing stuck trade #", ticket, " (exceeded ", MaxTradeLifeMinutes, " minutes)");
      // Continue to close below
   }

   // Re-select order right before closing to ensure it still exists
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
   {
      // Order doesn't exist anymore - remove from array
      Print("OrderClose: Ticket ", ticket, " no longer exists - removing from array");
      for(int j = index; j < totalActiveTrades - 1; j++)
      {
         activeTrades[j] = activeTrades[j + 1];
      }
      if(totalActiveTrades > 0)
      {
         int lastIdx = totalActiveTrades - 1;
         activeTrades[lastIdx].ticket = -1;
         activeTrades[lastIdx].entryPrice = 0;
         activeTrades[lastIdx].openTime = 0;
         activeTrades[lastIdx].direction = -1;
         activeTrades[lastIdx].openTickTime = 0;
         activeTrades[lastIdx].trailingArmed = false;
         activeTrades[lastIdx].highWatermark = 0;
         activeTrades[lastIdx].lowWatermark = 0;
      }
      totalActiveTrades--;
      return;
   }

   // Verify order is still open (not already closed)
   if(OrderCloseTime() > 0)
   {
      // Order already closed - remove from array
      Print("OrderClose: Ticket ", ticket, " already closed - removing from array");
      for(int j = index; j < totalActiveTrades - 1; j++)
      {
         activeTrades[j] = activeTrades[j + 1];
      }
      if(totalActiveTrades > 0)
      {
         int lastIdx = totalActiveTrades - 1;
         activeTrades[lastIdx].ticket = -1;
         activeTrades[lastIdx].entryPrice = 0;
         activeTrades[lastIdx].openTime = 0;
         activeTrades[lastIdx].direction = -1;
         activeTrades[lastIdx].openTickTime = 0;
         activeTrades[lastIdx].trailingArmed = false;
         activeTrades[lastIdx].highWatermark = 0;
         activeTrades[lastIdx].lowWatermark = 0;
      }
      totalActiveTrades--;
      return;
   }

   // Verify it's a market order (BUY or SELL)
   int orderType = OrderType();
   if(orderType != OP_BUY && orderType != OP_SELL)
   {
      Print("OrderClose: Ticket ", ticket, " is not a market order (type: ", orderType, ") - skipping");
      return;
   }

   double preClosePL = OrderProfit() + OrderSwap() + OrderCommission();
   double closePrice = (orderType == OP_BUY) ? Bid : Ask;
   double volume = OrderLots();
   int closedType = orderType;

   RefreshRates();
   
   // Re-select one more time before closing to ensure validity
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
   {
      Print("OrderClose: Ticket ", ticket, " became invalid before close - removing from array");
      for(int j = index; j < totalActiveTrades - 1; j++)
      {
         activeTrades[j] = activeTrades[j + 1];
      }
      if(totalActiveTrades > 0)
      {
         int lastIdx = totalActiveTrades - 1;
         activeTrades[lastIdx].ticket = -1;
         activeTrades[lastIdx].entryPrice = 0;
         activeTrades[lastIdx].openTime = 0;
         activeTrades[lastIdx].direction = -1;
         activeTrades[lastIdx].openTickTime = 0;
         activeTrades[lastIdx].trailingArmed = false;
         activeTrades[lastIdx].highWatermark = 0;
         activeTrades[lastIdx].lowWatermark = 0;
      }
      totalActiveTrades--;
      return;
   }
   
   bool closed = OrderClose(ticket, volume, closePrice, 3, clrYellow);

   if(!closed)
   {
      int error = GetLastError();
      // Error 4108 = Invalid ticket, 129 = Invalid price, 146 = Trade context busy
      if(error == 4108 || error == 129 || error == 146)
      {
         Print("OrderClose failed for ticket ", ticket, " - Error: ", error, " (", reason, ")");
         // Remove invalid ticket from array to prevent future attempts
         for(int j = index; j < totalActiveTrades - 1; j++)
         {
            activeTrades[j] = activeTrades[j + 1];
         }
         if(totalActiveTrades > 0)
         {
            int lastIdx = totalActiveTrades - 1;
            activeTrades[lastIdx].ticket = -1;
            activeTrades[lastIdx].entryPrice = 0;
            activeTrades[lastIdx].openTime = 0;
            activeTrades[lastIdx].direction = -1;
            activeTrades[lastIdx].openTickTime = 0;
            activeTrades[lastIdx].trailingArmed = false;
            activeTrades[lastIdx].highWatermark = 0;
            activeTrades[lastIdx].lowWatermark = 0;
         }
         totalActiveTrades--;
      }
      return;
   }

   if(closed)
   {
      double finalPL = preClosePL;
      if(OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY))
      {
         finalPL = OrderProfit() + OrderSwap() + OrderCommission();
         closedType = OrderType();
      }

      dailyProfit += finalPL;
      lastTradePL = finalPL;
      EvaluateGuardrails();

      if(finalPL < 0)
      {
         consecutiveLosses++;
         Print("CONSECUTIVE LOSS #", consecutiveLosses, ": KES ", DoubleToString(finalPL, 2));
      }
      else
      {
         consecutiveLosses = 0;
         strategyShifted = false;
         Print("PROFIT - Reset consecutive loss counter and strategy");
      }

      Print("Trade closed: ", reason, " | P&L: KES ", DoubleToString(finalPL, 2));

      EvaluatePatternRecovery(closedType, finalPL);

      for(int i = index; i < totalActiveTrades - 1; i++)
      {
         activeTrades[i] = activeTrades[i + 1];
      }

      if(totalActiveTrades > 0)
      {
         int lastIdx = totalActiveTrades - 1;
         activeTrades[lastIdx].ticket = -1;
         activeTrades[lastIdx].entryPrice = 0;
         activeTrades[lastIdx].openTime = 0;
         activeTrades[lastIdx].direction = -1;
         activeTrades[lastIdx].openTickTime = 0;
         activeTrades[lastIdx].trailingArmed = false;
         activeTrades[lastIdx].highWatermark = 0;
         activeTrades[lastIdx].lowWatermark = 0;
      }

      totalActiveTrades--;
   }
}

void CleanupClosedTrades()
{
   for(int i = totalActiveTrades - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket > 0)
      {
         if(!OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
         {
            double finalPL = 0;
            if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET, MODE_HISTORY))
            {
               finalPL = OrderProfit() + OrderSwap() + OrderCommission();
               int closedType = OrderType();
               bool wasPosition = (closedType == OP_BUY || closedType == OP_SELL);

               dailyProfit += finalPL;
               if(wasPosition)
                  lastTradePL = finalPL;
               if(wasPosition)
                  EvaluateGuardrails();

               if(finalPL < 0)
               {
                  consecutiveLosses++;
                  Print("CONSECUTIVE LOSS #", consecutiveLosses, ": KES ", DoubleToString(finalPL, 2));
               }
               else
               {
                  consecutiveLosses = 0;
                  strategyShifted = false;
               }

               Print("Trade auto-closed: KES ", DoubleToString(finalPL, 2));

               if(wasPosition)
                  EvaluatePatternRecovery(closedType, finalPL);
            }

            for(int j = i; j < totalActiveTrades - 1; j++)
            {
               activeTrades[j] = activeTrades[j + 1];
            }

            int lastIdx = totalActiveTrades - 1;
            activeTrades[lastIdx].ticket = -1;
            activeTrades[lastIdx].entryPrice = 0;
            activeTrades[lastIdx].openTime = 0;
            activeTrades[lastIdx].direction = -1;
            activeTrades[lastIdx].openTickTime = 0;
            activeTrades[lastIdx].trailingArmed = false;
            activeTrades[lastIdx].highWatermark = 0;
            activeTrades[lastIdx].lowWatermark = 0;

            totalActiveTrades--;
         }
      }
   }
}

bool PreFlightChecks()
{
   if(!TradeEnabled)
   {
      tradingAllowed = false;
      return false;
   }

   if(!HasTerminalTradePermission())
   {
      tradingAllowed = false;
      return false;
   }

   tradingAllowed = true;
   return true;
}

bool HasTerminalTradePermission()
{
   if(!::IsTradeAllowed())
      return false;

   if(!::IsTradeAllowed(Symbol(), TimeCurrent()))
      return false;

   return true;
}

bool CanOpenNewTrade()
{
   return totalActiveTrades < effectiveMaxTrades && tradingAllowed && dailyTradeCount < MaxDailyTrades;
}

void CloseAllTrades(string reason)
{
   Print("BASKET CLOSE: Closing all ", totalActiveTrades, " trades - ", reason);

   double totalPL = 0;

   for(int i = totalActiveTrades - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket > 0)
      {
         if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
         {
            totalPL += OrderProfit() + OrderSwap() + OrderCommission();
         }
         CloseTradeAtIndex(i, reason);
      }
   }

   Print("Basket closed: KES ", DoubleToString(totalPL, 2), " | Reason: ", reason);

   highestBasketProfit = 0;
   basketTrailingActive = false;
   lastDynamicTarget = 0;
   lastTrailLevel = 0;
}

bool IsPendingTracked(int ticket)
{
   for(int i = 0; i < totalPendingOrders; i++)
   {
      if(pendingOrders[i].ticket == ticket)
         return true;
   }
   return false;
}

void AddPendingOrderEntry(int ticket, int type, datetime placed)
{
   if(ticket <= 0)
      return;

   if(IsPendingTracked(ticket))
      return;

   if(totalPendingOrders >= MAX_PENDING_ORDERS)
   {
      Print("Pending order registry full. Unable to track ticket ", ticket);
      return;
   }

   pendingOrders[totalPendingOrders].ticket = ticket;
   pendingOrders[totalPendingOrders].type = type;
   pendingOrders[totalPendingOrders].placed = placed;
   totalPendingOrders++;
}

void RemovePendingOrderAt(int index)
{
   if(index < 0 || index >= totalPendingOrders)
      return;

   for(int i = index; i < totalPendingOrders - 1; i++)
   {
      pendingOrders[i] = pendingOrders[i + 1];
   }

   int lastIdx = totalPendingOrders - 1;
   if(lastIdx >= 0)
   {
      pendingOrders[lastIdx].ticket = -1;
      pendingOrders[lastIdx].type = -1;
      pendingOrders[lastIdx].placed = 0;
   }

   totalPendingOrders--;
   if(totalPendingOrders < 0)
      totalPendingOrders = 0;
}

void SyncPendingOrdersWithBroker()
{
   int total = OrdersTotal();
   for(int pos = 0; pos < total; pos++)
   {
      if(!OrderSelect(pos, SELECT_BY_POS))
         continue;

      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber)
         continue;

      int type = OrderType();
      if(type == OP_BUYLIMIT || type == OP_SELLLIMIT || type == OP_BUYSTOP || type == OP_SELLSTOP)
         AddPendingOrderEntry(OrderTicket(), type, OrderOpenTime());
   }
}

int CountPendingByType(int type)
{
   int count = 0;
   for(int i = 0; i < totalPendingOrders; i++)
   {
      if(pendingOrders[i].type == type)
         count++;
   }
   return count;
}

bool SubmitPendingOrder(int pendingType, double price)
{
   bool isLong = (pendingType == OP_BUYLIMIT || pendingType == OP_BUYSTOP);
   bool isValidType = (pendingType == OP_BUYLIMIT || pendingType == OP_SELLLIMIT ||
                       pendingType == OP_BUYSTOP  || pendingType == OP_SELLSTOP);
   if(!isValidType)
      return false;

   // BROKER-SAFE: Check limit orders count before placing
   if(BrokerSafeMode && (pendingType == OP_BUYLIMIT || pendingType == OP_SELLLIMIT))
   {
      int currentLimitOrders = CountLimitOrdersForSymbol(Symbol());
      if(currentLimitOrders >= MaxLimitOrdersPerSymbol)
      {
         // Already at max limit orders - don't place more
         return false;
      }
   }

   RefreshRates();

   double lotSize = CalculateDynamicLotSize();
   double sl = 0;
   double tp = 0;
   double pipToPoint = Point * 10.0;
   if(pipToPoint <= 0.0)
      pipToPoint = Point;

   double stopLossPips = StopLossPips;
   if(stopLossPips > 0.0 && pipToPoint > 0.0)
   {
      double slDistance = stopLossPips * pipToPoint;
      if(isLong)
         sl = NormalizeDouble(price - slDistance, Digits);
      else
         sl = NormalizeDouble(price + slDistance, Digits);
   }

   // Force TP on pending orders for scalping
   if(ForceTPOnPendingOrders && PendingOrderTPPips > 0.0 && pipToPoint > 0.0)
   {
      double tpDistance = PendingOrderTPPips * pipToPoint;
      if(isLong)
         tp = NormalizeDouble(price + tpDistance, Digits);
      else
         tp = NormalizeDouble(price - tpDistance, Digits);
   }
   else if(UseTakeProfitPips && TakeProfitPips > 0.0 && pipToPoint > 0.0)
   {
      double tpDistance = TakeProfitPips * pipToPoint;
      if(isLong)
         tp = NormalizeDouble(price + tpDistance, Digits);
      else
         tp = NormalizeDouble(price - tpDistance, Digits);
   }

   string side;
   switch(pendingType)
   {
      case OP_BUYLIMIT: side = "BUY LIMIT"; break;
      case OP_SELLLIMIT: side = "SELL LIMIT"; break;
      case OP_BUYSTOP: side = "BUY STOP"; break;
      case OP_SELLSTOP: side = "SELL STOP"; break;
      default: side = "PENDING";
   }
   string comment = "ScalpProV5_Improved " + side + " Lot:" + DoubleToString(lotSize, 2);
   color arrowColor = (isLong) ? clrGreen : clrRed;

   // BROKER-SAFE: Record request before sending
   RecordRequest();

   int ticket = OrderSend(Symbol(), pendingType, lotSize, price, 3, sl, tp,
                          comment, MagicNumber, 0, arrowColor);

   // BROKER-SAFE: Add random delay after pending order placement
   if(ticket > 0 && UseRandomDelays)
   {
      int delay = 100 + (MathRand() % 200); // Random delay 100-300ms
      Sleep(delay);
   }

   if(ticket > 0)
   {
      dailyTradeCount++;
      lastTradeTime = TimeCurrent();
      int logicalDirection = (pendingType == OP_BUYLIMIT || pendingType == OP_BUYSTOP) ? OP_BUY : OP_SELL;
      if(lastTradeDirection == logicalDirection)
      {
         consecutiveTradeCount++;
      }
      else
      {
         consecutiveTradeCount = 1;
         lastTradeDirection = logicalDirection;
      }

      if(OrderSelect(ticket, SELECT_BY_TICKET))
      {
         int resultingType = OrderType();
         if(resultingType == OP_BUYLIMIT || resultingType == OP_SELLLIMIT ||
            resultingType == OP_BUYSTOP || resultingType == OP_SELLSTOP)
            AddPendingOrderEntry(ticket, resultingType, OrderOpenTime());
         else if(resultingType == OP_BUY || resultingType == OP_SELL)
            SyncActiveTradesWithBroker();
      }

      Print("Pending order placed: ", side, " ticket ", ticket,
            " price ", DoubleToString(price, Digits), " lot ", DoubleToString(lotSize, 2));
      return true;
   }

   Print("Error placing ", side, ": ", GetLastError());
   return false;
}

void RefreshPendingOrders()
{
   SyncPendingOrdersWithBroker();
   datetime nowTime = TimeCurrent();
   int lifetimeSeconds = PendingOrderLifetimeMinutes * 60;

   for(int i = totalPendingOrders - 1; i >= 0; i--)
   {
      int ticket = pendingOrders[i].ticket;
      if(ticket <= 0)
      {
         RemovePendingOrderAt(i);
         continue;
      }

      if(!OrderSelect(ticket, SELECT_BY_TICKET))
      {
         RemovePendingOrderAt(i);
         continue;
      }

      int type = OrderType();
      if(type == OP_BUY || type == OP_SELL)
      {
         SyncActiveTradesWithBroker();
         RemovePendingOrderAt(i);
         continue;
      }

      if(type != OP_BUYLIMIT && type != OP_SELLLIMIT && type != OP_BUYSTOP && type != OP_SELLSTOP)
      {
         RemovePendingOrderAt(i);
         continue;
      }

      // Close pending orders that haven't executed quickly (scalping style)
      if(lifetimeSeconds > 0 && (nowTime - pendingOrders[i].placed) >= lifetimeSeconds)
      {
         if(OrderDelete(ticket))
            Print("Pending order expired (not executed) - cancelled ticket ", ticket, " after ", lifetimeSeconds, " seconds");
         RemovePendingOrderAt(i);
      }
   }
}

void GeneratePendingOrderGrid()
{
   RefreshRates();
   double emaTrend = iMA(Symbol(), PERIOD_M1, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double pipToPoint = Point * 10.0;
   if(pipToPoint <= 0.0)
      pipToPoint = Point;

   double limitSpacing = MathMax(LimitGridSpacingPips, 0.1) * pipToPoint;
   double limitOffset = MathMax(effectiveLimitOffsetPips, 0.0) * pipToPoint;
   double stopSpacing = MathMax(StopGridSpacingPips, 0.1) * pipToPoint;
   double stopOffset = MathMax(effectiveStopOffsetPips, 0.0) * pipToPoint;

   int limitBudget = MathMax((int)MathRound(effectivePendingLimitsSide * 2), 2);
   int stopBudget = MathMax((int)MathRound(effectivePendingStopsSide * 2), 0);
   double bias = MathMax(MathMin((double)(lastBuyScore - lastSellScore) / 6.0, 0.4), -0.4);

   double buyLimitWeight = 0.5 + bias;
   double sellLimitWeight = 0.5 - bias;
   double buyStopWeight = 0.5 - bias;
   double sellStopWeight = 0.5 + bias;

   int targetBuyLimits = MathMax(1, (int)MathRound(limitBudget * buyLimitWeight));
   int targetSellLimits = MathMax(1, limitBudget - targetBuyLimits);
   int targetBuyStops = MathMax(0, (int)MathRound(stopBudget * buyStopWeight));
   int targetSellStops = MathMax(0, stopBudget - targetBuyStops);

   int currentBuyLimits = CountPendingByType(OP_BUYLIMIT);
   int currentSellLimits = CountPendingByType(OP_SELLLIMIT);
   int currentBuyStops = CountPendingByType(OP_BUYSTOP);
   int currentSellStops = CountPendingByType(OP_SELLSTOP);

   double currentAsk = Ask;
   double currentBid = Bid;

   // Buy limits below bid
   double baseBuyLimit = emaTrend - limitOffset;
   for(int i = currentBuyLimits; i < targetBuyLimits && totalPendingOrders < MAX_PENDING_ORDERS; i++)
   {
      double price = baseBuyLimit - (i * limitSpacing);
      double maxBuyLimitPrice = currentBid - Point;
      if(price >= maxBuyLimitPrice)
         price = maxBuyLimitPrice - (i + 1) * Point;
      if(price <= 0)
         break;
      SubmitPendingOrder(OP_BUYLIMIT, NormalizeDouble(price, Digits));
   }

   // Sell limits above ask
   double baseSellLimit = emaTrend + limitOffset;
   for(int i = currentSellLimits; i < targetSellLimits && totalPendingOrders < MAX_PENDING_ORDERS; i++)
   {
      double price = baseSellLimit + (i * limitSpacing);
      double minSellLimitPrice = currentAsk + Point;
      if(price <= minSellLimitPrice)
         price = minSellLimitPrice + (i + 1) * Point;
      SubmitPendingOrder(OP_SELLLIMIT, NormalizeDouble(price, Digits));
   }

   // Buy stops above ask
   double baseBuyStop = emaTrend + stopOffset;
   for(int i = currentBuyStops; i < targetBuyStops && totalPendingOrders < MAX_PENDING_ORDERS; i++)
   {
      double price = baseBuyStop + (i * stopSpacing);
      double minBuyStopPrice = currentAsk + Point;
      if(price <= minBuyStopPrice)
         price = minBuyStopPrice + (i + 1) * Point;
      SubmitPendingOrder(OP_BUYSTOP, NormalizeDouble(price, Digits));
   }

   // Sell stops below bid
   double baseSellStop = emaTrend - stopOffset;
   for(int i = currentSellStops; i < targetSellStops && totalPendingOrders < MAX_PENDING_ORDERS; i++)
   {
      double price = baseSellStop - (i * stopSpacing);
      double maxSellStopPrice = currentBid - Point;
      if(price >= maxSellStopPrice)
         price = maxSellStopPrice - (i + 1) * Point;
      if(price <= 0)
         break;
      SubmitPendingOrder(OP_SELLSTOP, NormalizeDouble(price, Digits));
   }
}

void MaintainPendingOrders()
{
   if(!UsePendingOrders || !TradeEnabled || !tradingAllowed)
      return;

   if(guardrailActive)
   {
      if(totalPendingOrders > 0)
         CancelAllPendingOrders();
      return;
   }

   UpdateExposureGovernor();
   RefreshPendingOrders();

   datetime nowTime = TimeCurrent();
   // More frequent refresh for scalping - check every 30 seconds instead of 60
   bool timeElapsed = (lastPendingBatchTime == 0) || ((nowTime - lastPendingBatchTime) >= 30);
   int totalDesiredPending = (int)MathMax(2, MathRound(effectivePendingLimitsSide * 2 + effectivePendingStopsSide * 2));
   bool needsTopUp = (totalPendingOrders < totalDesiredPending * exposureScale);
   bool activeTrigger = (ActiveReplenishThreshold > 0 &&
                         totalActiveTrades >= lastActiveRefreshCount + ActiveReplenishThreshold);

   // Always replenish if orders were closed (scalping style - keep grid full)
   if(timeElapsed || needsTopUp || activeTrigger)
   {
      GeneratePendingOrderGrid();
      lastPendingBatchTime = nowTime;
      lastActiveRefreshCount = totalActiveTrades;
   }
}

void CancelAllPendingOrders()
{
   for(int i = totalPendingOrders - 1; i >= 0; i--)
   {
      int ticket = pendingOrders[i].ticket;
      if(ticket > 0 && OrderSelect(ticket, SELECT_BY_TICKET))
      {
         int type = OrderType();
         if(type == OP_BUYLIMIT || type == OP_SELLLIMIT || type == OP_BUYSTOP || type == OP_SELLSTOP)
         {
            if(!OrderDelete(ticket))
               Print("OrderDelete failed ticket=", ticket, " error=", GetLastError());
         }
      }
      RemovePendingOrderAt(i);
   }
   totalPendingOrders = 0;
   lastPendingBatchTime = 0;
   lastActiveRefreshCount = totalActiveTrades;
}

void AttemptMarketEntries()
{
   if(!UseMarketBursts || !tradingAllowed)
      return;

   if(guardrailActive)
      return;

   int burstCap = (int)MathMax(1, MathRound(effectiveMarketBurstSize));

   if(totalActiveTrades >= effectiveMaxTrades || dailyTradeCount >= MaxDailyTrades)
      return;

   if(MarketBurstCooldownSec > 0 && lastMarketBurstTime > 0 &&
      (TimeCurrent() - lastMarketBurstTime) < MarketBurstCooldownSec)
      return;

   int baseSignal = GetScalpingSignal();
   if(baseSignal != OP_BUY && baseSignal != OP_SELL)
      return;

   int buyScore = 0, sellScore = 0;
   double ema_fast = iMA(Symbol(), PERIOD_M1, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema_slow = iMA(Symbol(), PERIOD_M1, TrendPeriod * 2, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi = iRSI(Symbol(), PERIOD_M1, MomentumPeriod, PRICE_CLOSE, 0);
   double currentPrice = (Ask + Bid) / 2.0;
   bool uptrend = ema_fast > ema_slow;
   bool priceAboveEMA = currentPrice > ema_fast;
   bool bullishMomentum = rsi > 50 && rsi < 70;
   bool oversold = rsi < (50 - MinMomentumStrength);
   bool risingPrice = iClose(Symbol(), PERIOD_M1, 0) > iClose(Symbol(), PERIOD_M1, 1);
   if(uptrend) buyScore++;
   if(priceAboveEMA) buyScore++;
   if(bullishMomentum || oversold) buyScore++;
   if(risingPrice) buyScore++;

   bool downtrend = ema_fast < ema_slow;
   bool priceBelowEMA = currentPrice < ema_fast;
   bool bearishMomentum = rsi < 50 && rsi > 30;
   bool overbought = rsi > (50 + MinMomentumStrength);
   bool fallingPrice = iClose(Symbol(), PERIOD_M1, 0) < iClose(Symbol(), PERIOD_M1, 1);
   if(downtrend) sellScore++;
   if(priceBelowEMA) sellScore++;
   if(bearishMomentum || overbought) sellScore++;
   if(fallingPrice) sellScore++;

   lastBuyScore = buyScore;
   lastSellScore = sellScore;

   int strength = (baseSignal == OP_BUY) ? buyScore : sellScore;
   if(strength < MarketEntryScoreThreshold)
      return;

   // BROKER-SAFE: Single execution per tick (no loops)
   if(totalActiveTrades >= effectiveMaxTrades || dailyTradeCount >= MaxDailyTrades)
      return;

   if(OpenScalpTrade(baseSignal) > 0)
   {
      lastMarketBurstTime = TimeCurrent();
      CompleteForcedBurst(true);
   }
}

void CheckDailyReset()
{
   datetime currentDay = iTime(Symbol(), PERIOD_D1, 0);

   if(currentDay != lastDayReset)
   {
      Print("Daily reset - Previous P&L: KES ", DoubleToString(dailyProfit, 2), " | Total Trades: ", dailyTradeCount);
      dailyProfit = 0;
      dailyTradeCount = 0;
      lastDayReset = currentDay;
      highestBasketProfit = 0;
      basketTrailingActive = false;
      lastDynamicTarget = 0;
      lastTrailLevel = 0;
      consecutiveBuyLosses = 0;
      consecutiveSellLosses = 0;
      forcedDirection = -1;
      forcedBurstsRemaining = 0;
      forcedBurstOverride = false;
      initialAccountBalance = AccountBalance();
      guardrailActive = false;
      guardrailPnlPercent = 0.0;
      cycleStartTime = TimeCurrent(); // Reset timed trade control cycle on daily reset
      inPauseMode = false;
      CancelAllPendingOrders();
   }
}

void UpdateDisplay()
{
   double currentLotSize = CalculateDynamicLotSize();
   double currentBalance = AccountBalance();

   double basketProfit = 0;
   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket > 0)
      {
         if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
         {
            basketProfit += OrderProfit() + OrderSwap() + OrderCommission();
         }
      }
   }

   double ema_fast = iMA(Symbol(), PERIOD_M1, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema_slow = iMA(Symbol(), PERIOD_M1, TrendPeriod * 2, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi = iRSI(Symbol(), PERIOD_M1, MomentumPeriod, PRICE_CLOSE, 0);
   string trend = (ema_fast > ema_slow) ? "UPTREND" : "DOWNTREND";
   string momentum = (rsi > 50) ? "BULLISH" : "BEARISH";

   string trailingStatus = "OFF";
   if(basketTrailingActive && lastTrailLevel > 0.0)
      trailingStatus = "ACTIVE @ KES " + DoubleToString(lastTrailLevel, 2);

   int basketsCompleted = (TradesPerBurst > 0) ? dailyTradeCount / TradesPerBurst : dailyTradeCount;
   double effectiveTarget = lastDynamicTarget;
   double displayPercent = GetEquityTargetPercent();
   if(effectiveTarget <= 0.0 && displayPercent > 0.0)
      effectiveTarget = AccountBalance() * (displayPercent / 100.0);

   string profitInfo = "Dynamic Target: KES " + DoubleToString(effectiveTarget, 2) +
                       " | Peak: " + DoubleToString(highestBasketProfit, 2);
   if(basketTrailingActive && lastTrailLevel > 0.0)
      profitInfo += " | Trail: " + DoubleToString(lastTrailLevel, 2);
   profitInfo += " | RR x" + DoubleToString(RiskRewardMultiplier, 1);

   string patternStatus = "DISABLED";
   if(UsePatternRecovery)
   {
      if(forcedDirection != -1 && forcedBurstsRemaining > 0)
      {
         patternStatus = StringConcatenate("FORCED ", (forcedDirection == OP_BUY ? "BUY" : "SELL"),
                                           " (", IntegerToString(forcedBurstsRemaining), " bursts left)");
      }
      else
      {
         patternStatus = StringConcatenate("Neutral | BuyLosses:", IntegerToString(consecutiveBuyLosses),
                                           " | SellLosses:", IntegerToString(consecutiveSellLosses));
      }
   }

   string guardrailStatus = guardrailActive
                            ? StringConcatenate("HIT (", DoubleToString(guardrailPnlPercent, 2), "%)")
                            : "CLEAR";

   string exposureStatus = UseExposureGovernor
                           ? StringConcatenate("Scale: ", DoubleToString(exposureScale, 2),
                                             " | MaxTrades: ", IntegerToString(effectiveMaxTrades),
                                             " | Burst: ", IntegerToString(effectiveBurstSize))
                           : "DISABLED";

   string status = StringConcatenate(
      "==== QuickScalperPro v5.01 Improved (Combined Strategy) ====\n",
      "Status: ", (tradingAllowed ? "ACTIVE" : "PAUSED"), " | ", trend, " | RSI: ", DoubleToString(rsi, 1), " | Momentum: ", momentum, "\n",
      "Basket: ", totalActiveTrades, "/", effectiveMaxTrades, " | Daily Baskets: ", basketsCompleted, " | Trades: ", dailyTradeCount, "\n",
      "========================================\n",
      "BASKET P&L: KES ", DoubleToString(basketProfit, 2), "\n",
      profitInfo, "\n",
      "Trailing: ", trailingStatus, "\n",
      "Pattern: ", patternStatus, "\n",
      "Guardrail: ", guardrailStatus, "\n",
      "Exposure: ", exposureStatus, "\n",
      "========================================\n",
      "Daily P&L: KES ", DoubleToString(dailyProfit, 2), "\n",
      "Balance: KES ", DoubleToString(currentBalance, 2), "\n",
      "Spread: ", DoubleToString((Ask - Bid) / Point / 10.0, 1), " pips (Max: ", DoubleToString(effectiveMaxSpreadPips, 1), ") | Lot: ", DoubleToString(currentLotSize, 2), "\n",
      "Trade Control: ", (inPauseMode ? "PAUSED" : "ACTIVE"), "\n",
      "Equity Target: ", DoubleToString(displayPercent, 2), "% | Hold >= ", IntegerToString(MinimumHoldMS), " ms"
   );

   Comment(status);
}
