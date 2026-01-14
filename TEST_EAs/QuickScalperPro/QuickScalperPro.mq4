

#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "3.03"
#property strict

// CRITICAL FIX: Re-enabled stop loss to prevent catastrophic losses
#define FIXED_STOP_LOSS_PIPS 50.0  // CRITICAL: Stop loss re-enabled (50 pips)

input group "===== Dynamic Lot Sizing ====="
input double   AccountBalance_10K  = 1000000.0;
input double   AccountBalance_100  = 100000.0;
input double   AccountBalance_1500 = 500000.0;
input double   MinLotSize          = 0.01;  // CRITICAL FIX: Reduced from 0.10 to prevent huge losses
input double   MaxLotSize          = 0.05;  // CRITICAL FIX: Reduced from 1.0 to prevent huge losses

input group "===== Core Trading Settings ====="
input int      MagicNumber         = 202503;
input int      MaxTrades           = 3;     // CRITICAL FIX: Further reduced to prevent over-trading
input int      TradesPerBurst      = 1;    // CRITICAL FIX: Only 1 trade per burst to prevent rapid losses
input int      BurstDelayMS        = 500;  // FIXED: Increased delay to avoid hyperactivity

input group "===== Adaptive Profit Engine ====="
enum EquityTargetPresetOption
{
   EquityTarget_1Percent = 1,
   EquityTarget_2Percent = 2,
   EquityTarget_4Percent = 4
};
input EquityTargetPresetOption EquityTargetPreset = EquityTarget_2Percent;  // Default basket target (percent)
input bool     UseCustomEquityTarget = false;   // Override preset with custom percent
input double   CustomEquityPercent  = 2.0;      // Used when custom target enabled
input bool     UseRiskRewardTarget  = false;    // Combine RR target with equity percent
input double   RiskRewardMultiplier = 3.0;      // Multiple of risk to target (if enabled)
input double   PeakGivebackPercent = 30.0;    // Allowable giveback from profit peak
input int      MinimumHoldMS       = 250;     // Prevent premature exits
input double   MaxSpreadPips       = 20.0;  // FIXED: Increased from 6.0 to accept more opportunities

input group "===== Trading Controls ====="
input bool     TradeEnabled        = true;
input int      TickDelay           = 1;
input int      MaxConsecutiveLosses= 5;
input bool     UseGoldOnly         = true;
input int      MaxDailyTrades      = 50;      // FIXED: Reduced to avoid hyperactivity

input group "===== Hyperactivity Protection ====="
input bool     UseHyperactivityProtection = true;  // NEW: Protect against account closure
input int      MinSecondsBetweenTrades    = 3;     // NEW: Minimum seconds between trades
input int      MaxTradesPerMinute         = 5;     // NEW: Max trades per minute
input int      MaxTradesPerHour           = 20;    // NEW: Max trades per hour
input int      RequestCooldownMS          = 1000;  // NEW: Cooldown between order requests (ms)

input group "===== Strategy Settings ====="
input int      TrendPeriod         = 10;
input int      MomentumPeriod      = 9;
input double   MinMomentumStrength = 20.0;
input bool     OnlyTrendTrades     = false;

input group "===== Per-Trade Exit Options (Profit-Based) ====="
input bool     UseTakeProfitPercent = false;   // NEW: Use profit percentage instead of pips
input double   TakeProfitPercent    = 100.0;   // NEW: Close at X% profit (100% = double)
input bool     UseTrailingStop      = true;
input double   TrailingStartPercent = 30.0;    // NEW: Start trailing at X% profit
input double   TrailingStepPercent  = 10.0;    // NEW: Trail by X% of profit
input double   PerTradeProfitLock   = 5000.0;  // Close individual positions once profit exceeds this amount

input group "===== Instant Profit Exit (Profit-Based) ====="
input bool     UseInstantProfitExit = true;   // FIXED: Enabled for instant profit
input double   InstantProfitPercent = 50.0;   // NEW: Close at X% profit (e.g., 50% = half profit, 100% = double)
input bool     UseProfitDouble      = true;   // NEW: Close when profit doubles (100% gain)

input group "===== Lot Growth Settings ====="
input double   ProfitStepForLotIncrease= 20.0;     // Increase lot size every X profit
input double   LotIncrementPerStep     = 0.01;     // Additional lot size per profit step

input group "===== CRITICAL RISK PROTECTION ====="
input bool     OnlyCloseInProfit      = false;     // CRITICAL FIX: Allow closing losing trades if drawdown too high
input double   BreakEvenTriggerPercent = 20.0;      // NEW: Move to BE after X% profit (was pips)
input bool     UseMartingaleRecovery   = false;     // CRITICAL FIX: DISABLED - Prevents adding more losing trades
input int      MaxRecoveryTrades       = 0;        // CRITICAL FIX: Set to 0 - no recovery trades
input double   MaxDrawdownPercent      = 10.0;     // CRITICAL: Stop trading if drawdown exceeds X%
input double   MaxLossPerTradeUSD      = 50.0;     // CRITICAL: Close trade if loss exceeds X USD
input double   MaxDailyLossUSD         = 200.0;    // CRITICAL: Stop trading if daily loss exceeds X USD
input bool     EmergencyStopEnabled    = true;     // CRITICAL: Enable emergency stop protection

input group "===== No Hedging Protection ====="
input bool     EnforceSingleDirection = true;      // NEW: No hedging - all trades same direction per basket

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

QuickTrade activeTrades[100];  // FIXED: Increased from 20 to 100 to support many trades
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

// NEW: Hyperactivity protection variables
datetime lastTradeTimestamp = 0;
int tradesThisMinute = 0;
int tradesThisHour = 0;
datetime currentMinute = 0;
datetime currentHour = 0;
datetime lastRequestTime = 0;

// NEW: No hedging - track basket direction
int currentBasketDirection = -1;  // -1 = no basket, OP_BUY = buy basket, OP_SELL = sell basket

// CRITICAL: Risk protection variables
double initialAccountBalance = 0.0;
double highestAccountBalance = 0.0;
bool emergencyStopActive = false;
double dailyLossUSD = 0.0;

int OnInit()
{
   Print("========================================");
   Print("QuickScalperPro EA v3.03 Initialized - SAFE MODE (Risk Protection Enabled)");
   
   // CRITICAL: Initialize risk protection
   initialAccountBalance = AccountBalance();
   highestAccountBalance = AccountBalance();
   emergencyStopActive = false;
   dailyLossUSD = 0.0;
   Print("========================================");
   Print("Strategy: Ultra-Fast Tick-Based Scalping");
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

   for(int i = 0; i < 100; i++)  // FIXED: Increased array size
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

   double minStopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL);

   Print("Initialization successful!");
   Print("========================================");
   Print("ADAPTIVE PROFIT ENGINE ACTIVE");
   double initTarget = GetEquityTargetPercent();
   Print("Equity Target: ", DoubleToString(initTarget, 2), "% | RR Target ",
         (UseRiskRewardTarget ? "ON" : "OFF"), " (x", DoubleToString(RiskRewardMultiplier, 2),
         ") | Giveback: ", DoubleToString(PeakGivebackPercent, 2), "%");
   Print("Minimum Hold: ", MinimumHoldMS, " ms | Max Spread: ", MaxSpreadPips, " pips");
   Print("Lot Bounds: Min=", MinLotSize, " | Max=", MaxLotSize,
         " | Step Growth: +", DoubleToString(LotIncrementPerStep, 2),
         " per ", DoubleToString(ProfitStepForLotIncrease, 2), " profit");
   Print("========================================");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("QuickScalperPro EA Deinitialized. Reason: ", reason);
}

void OnTick()
{

   CheckDailyReset();
   
   // CRITICAL: Check emergency stop first
   if(EmergencyStopEnabled && CheckEmergencyStop())
   {
      Comment("EMERGENCY STOP ACTIVE - Trading Disabled");
      return;
   }
   
   // NEW: Update hyperactivity protection counters
   UpdateHyperactivityCounters();

   if(!PreFlightChecks()) return;

   if(!IsSpreadAcceptable())
   {
      Comment("SPREAD TOO HIGH: ", DoubleToString((Ask - Bid) / Point / 10.0, 1), " pips");
      return;
   }

   TrackTickMovement();

   ManageActiveTrades();

   CleanupClosedTrades();

   if(CanOpenNewTrade())
   {
      LookForScalpingOpportunity();
   }

   UpdateDisplay();
}

double CalculateDynamicLotSize()
{
   double currentBalance = AccountBalance();

   double baseLot = MinLotSize;

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
   return (currentSpread <= MaxSpreadPips);
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

   // NEW: Check hyperactivity protection
   if(UseHyperactivityProtection && !CanTradeNow())
   {
      return;  // Blocked by hyperactivity protection
   }

   int signal = GetScalpingSignal();

   if(signal == OP_BUY || signal == OP_SELL)
   {
      // NEW: No hedging - enforce single direction per basket
      if(EnforceSingleDirection && totalActiveTrades > 0)
      {
         // Check if we have existing trades
         int existingDirection = GetBasketDirection();
         if(existingDirection != -1 && existingDirection != signal)
         {
            // Basket has trades in opposite direction - don't hedge
            Print("NO HEDGING: Existing basket direction is ", (existingDirection == OP_BUY ? "BUY" : "SELL"), 
                  " | Signal is ", (signal == OP_BUY ? "BUY" : "SELL"), " - Skipping to avoid hedge");
            return;
         }
      }

      // NEW: Set basket direction
      if(totalActiveTrades == 0)
      {
         currentBasketDirection = signal;  // Set direction for new basket
      }

      for(int burst = 0; burst < TradesPerBurst; burst++)
      {

         if(totalActiveTrades >= MaxTrades || dailyTradeCount >= MaxDailyTrades)
            break;

         // NEW: Double-check direction before opening (no hedging)
         if(EnforceSingleDirection && totalActiveTrades > 0)
         {
            if(currentBasketDirection != -1 && currentBasketDirection != signal)
            {
               Print("NO HEDGING: Stopping burst - direction mismatch");
               break;
            }
         }

         if(signal == OP_BUY)
            OpenScalpTrade(OP_BUY);
         else
            OpenScalpTrade(OP_SELL);

         if(burst < TradesPerBurst - 1 && BurstDelayMS > 0)
            Sleep(BurstDelayMS);
      }
   }
}

int GetScalpingSignal()
{

   double currentSpread = (Ask - Bid) / Point / 10.0;
   bool acceptableSpread = (currentSpread <= MaxSpreadPips);

   if(!acceptableSpread) return -1;

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

void OpenScalpTrade(int orderType)
{
   double price = (orderType == OP_BUY) ? Ask : Bid;

   double lotSize = CalculateDynamicLotSize();
   double sl = 0;
   double tp = 0;
   double pipToPoint = Point * 10.0;

   if(!IsSpreadAcceptable())
   {
      Print("Trade blocked - Spread too high: ", DoubleToString((Ask - Bid) / Point / 10.0, 1));
      return;
   }

   // CRITICAL FIX: Stop loss re-enabled to prevent catastrophic losses
   double stopLossPips = FIXED_STOP_LOSS_PIPS;
   if(stopLossPips > 0.0 && pipToPoint > 0.0)
   {
      double slDistance = stopLossPips * pipToPoint;
      if(orderType == OP_BUY)
         sl = NormalizeDouble(price - slDistance, Digits);
      else
         sl = NormalizeDouble(price + slDistance, Digits);
   }
   else
   {
      // CRITICAL: If stop loss is 0, set a minimum safety stop
      double minSafetyStop = 100.0 * pipToPoint;  // 100 pips minimum safety stop
      if(orderType == OP_BUY)
         sl = NormalizeDouble(price - minSafetyStop, Digits);
      else
         sl = NormalizeDouble(price + minSafetyStop, Digits);
   }

   // FIXED: Changed to use profit percentage instead of pips
   if(UseTakeProfitPercent && TakeProfitPercent > 0.0 && pipToPoint > 0.0)
   {
      // Note: TakeProfitPercent is handled in ManageActiveTrades, not here
      // This section can be removed or kept for backward compatibility
      tp = 0;  // TP will be managed by profit percentage logic
   }

   string comment = "ScalpPro " + (orderType == OP_BUY ? "BUY" : "SELL") + " Lot:" + DoubleToString(lotSize, 2);
   color arrowColor = (orderType == OP_BUY) ? clrGreen : clrRed;

   // NEW: Record request time for hyperactivity protection
   if(UseHyperactivityProtection)
   {
      lastRequestTime = GetTickCount();
      
      // Check cooldown before sending
      if(lastRequestTime > 0 && RequestCooldownMS > 0)
      {
         ulong timeSinceRequest = GetTickCount() - lastRequestTime;
         if(timeSinceRequest < (ulong)RequestCooldownMS)
         {
            Sleep((int)(RequestCooldownMS - timeSinceRequest));
         }
      }
   }

   int ticket = OrderSend(Symbol(), orderType, lotSize, price, 3, sl, tp,
                          comment, MagicNumber, 0, arrowColor);

   if(ticket > 0)
   {

      dailyTradeCount++;
      lastTradeTime = TimeCurrent();
      
      // NEW: Update hyperactivity counters
      if(UseHyperactivityProtection)
      {
         lastTradeTimestamp = TimeCurrent();
         tradesThisMinute++;
         tradesThisHour++;
      }

      if(lastTradeDirection == orderType)
      {
         consecutiveTradeCount++;
      }
      else
      {
         consecutiveTradeCount = 1;
         lastTradeDirection = orderType;
      }

      // NEW: Update basket direction
      if(totalActiveTrades == 0)
      {
         currentBasketDirection = orderType;  // Set direction for new basket
      }

      if(totalActiveTrades < 100)  // FIXED: Increased limit
      {
         activeTrades[totalActiveTrades].ticket = ticket;
         activeTrades[totalActiveTrades].entryPrice = price;
         activeTrades[totalActiveTrades].openTime = TimeCurrent();
         activeTrades[totalActiveTrades].direction = orderType;
         activeTrades[totalActiveTrades].openTickTime = GetTickCount();
         activeTrades[totalActiveTrades].trailingArmed = false;
         activeTrades[totalActiveTrades].highWatermark = price;
         activeTrades[totalActiveTrades].lowWatermark = price;
         totalActiveTrades++;
      }

      Print("Basket trade #", dailyTradeCount, " opened: ", comment, " | Ticket: ", ticket,
            " | Price: ", DoubleToString(price, Digits), " | Lot: ", DoubleToString(lotSize, 2),
            " | Basket: ", totalActiveTrades, "/", MaxTrades);
   }
   else
   {
      Print("Error opening scalp trade: ", GetLastError());
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
   if(!UseTrailingStop || TrailingStartPercent <= 0.0 || TrailingStepPercent <= 0.0)
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

   // FIXED: Only trail if trade is profitable - never trail losing trades
   double tradeProfit = OrderProfit() + OrderSwap() + OrderCommission();
   if(OnlyCloseInProfit && tradeProfit <= 0.0)
      return;  // Don't trail losing trades

   int type = OrderType();
   double price = (type == OP_BUY) ? Bid : Ask;
   double entry = activeTrades[index].entryPrice;
   double lotSize = OrderLots();
   
   // NEW: Calculate profit percentage for trailing
   double pipValuePerLot = GetPipValuePerLot();
   double riskAmount = entry * lotSize * 0.01;  // Base risk calculation
   double profitPercent = 0.0;
   if(riskAmount > 0.0)
      profitPercent = (tradeProfit / riskAmount) * 100.0;

   if(pipToPoint <= 0.0)
      return;

   // NEW: Trailing using profit percentage
   if(profitPercent >= TrailingStartPercent)
   {
      if(!activeTrades[index].trailingArmed)
         activeTrades[index].trailingArmed = true;

      if(activeTrades[index].trailingArmed)
      {
         // Calculate trailing stop based on profit percentage
         double trailPercent = profitPercent - TrailingStepPercent;
         if(trailPercent > 0.0)
         {
            double trailProfit = riskAmount * (trailPercent / 100.0);
            double trailDistance = 0.0;
            
            if(type == OP_BUY)
            {
               // For BUY: trail stop below high watermark
               activeTrades[index].highWatermark = MathMax(activeTrades[index].highWatermark, price);
               trailDistance = trailProfit / (pipValuePerLot * lotSize);
               if(trailDistance > 0 && pipToPoint > 0)
               {
                  trailDistance = trailDistance * pipToPoint;
                  double newStop = NormalizeDouble(activeTrades[index].highWatermark - trailDistance, Digits);
                  if(newStop >= entry && newStop > OrderStopLoss() && newStop < price)
            ModifyOrderStop(ticket, newStop);
      }
   }
   else if(type == OP_SELL)
   {
               // For SELL: trail stop above low watermark
      activeTrades[index].lowWatermark = MathMin(activeTrades[index].lowWatermark, price);
               trailDistance = trailProfit / (pipValuePerLot * lotSize);
               if(trailDistance > 0 && pipToPoint > 0)
               {
                  trailDistance = trailDistance * pipToPoint;
                  double newStop = NormalizeDouble(activeTrades[index].lowWatermark + trailDistance, Digits);
                  if(newStop <= entry && (OrderStopLoss() == 0 || newStop < OrderStopLoss()) && newStop > price)
            ModifyOrderStop(ticket, newStop);
               }
            }
         }
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

void ManageActiveTrades()
{
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
      double lotSize = OrderLots();
      double entryPrice = activeTrades[i].entryPrice;
      double stop = OrderStopLoss();
      
      // NEW: Calculate profit percentage based on risk
      double riskAmount = 0.0;
      if(stop > 0 && pipToPoint > 0)
      {
         double riskPips = MathAbs(entry - stop) / pipToPoint;
         riskAmount = riskPips * pipValuePerLot * lotSize;
      }
      else
      {
         // No stop loss - use entry price as base for percentage calculation
         riskAmount = entryPrice * lotSize * 0.01;  // 1% of entry value as base
      }
      
      double profitPercent = 0.0;
      if(riskAmount > 0.0)
         profitPercent = (tradeProfit / riskAmount) * 100.0;

      // NEW: Break-Even Protection - Move SL to BE once profitable (using percentage)
      if(BreakEvenTriggerPercent > 0.0 && tradeProfit > 0.0 && profitPercent >= BreakEvenTriggerPercent)
      {
         double currentSL = OrderStopLoss();
         if(orderType == OP_BUY && (currentSL == 0 || currentSL < entryPrice))
         {
            ModifyOrderStop(activeTrades[i].ticket, entryPrice);
         }
         else if(orderType == OP_SELL && (currentSL == 0 || currentSL > entryPrice))
         {
            ModifyOrderStop(activeTrades[i].ticket, entryPrice);
         }
      }

      // CRITICAL FIX: Allow closing losing trades if loss is too high
      if(OnlyCloseInProfit && tradeProfit <= 0.0)
      {
         // Check if loss exceeds maximum per trade
         if(MaxLossPerTradeUSD > 0.0 && MathAbs(tradeProfit) >= MaxLossPerTradeUSD)
         {
            // CRITICAL: Close trade even if losing - loss too high
            CloseTradeAtIndex(i, "CRITICAL: Max loss per trade exceeded: $" + DoubleToString(tradeProfit, 2));
            i--;
            continue;
         }
         
         // Trade is losing but within limits - skip exit conditions, let it recover
         totalProfit += tradeProfit;
         UpdatePerTradeTrailing(i, pipToPoint);
         continue;
      }

      // NEW: Instant Profit Exit - using profit percentage instead of pips
      if(UseInstantProfitExit && tradeProfit > 0.0)
      {
         bool shouldClose = false;
         string closeReason = "";
         
         if(UseProfitDouble && profitPercent >= 100.0)
         {
            shouldClose = true;
            closeReason = "Profit doubled (100%): " + DoubleToString(tradeProfit, 2);
         }
         else if(InstantProfitPercent > 0.0 && profitPercent >= InstantProfitPercent)
         {
            shouldClose = true;
            closeReason = "Instant profit " + DoubleToString(profitPercent, 1) + "%: " + DoubleToString(tradeProfit, 2);
         }
         
         if(shouldClose)
       {
            CloseTradeAtIndex(i, closeReason);
            i--;
            continue;
         }
      }

      // NEW: Take Profit using percentage instead of pips
      if(UseTakeProfitPercent && TakeProfitPercent > 0.0 && profitPercent >= TakeProfitPercent)
      {
         CloseTradeAtIndex(i, "Take profit " + DoubleToString(profitPercent, 1) + "%: " + DoubleToString(tradeProfit, 2));
         i--;
         continue;
       }

       if(PerTradeProfitLock > 0.0 && tradeProfit >= PerTradeProfitLock)
       {
         CloseTradeAtIndex(i, "Per-trade profit lock +" + DoubleToString(tradeProfit, 2));
         i--;
         continue;
       }

      totalProfit += tradeProfit;

      // FIXED: lotSize and stop already declared earlier in the loop (lines 749, 751)
      // Reuse existing variables instead of redeclaring
      double riskPips = FIXED_STOP_LOSS_PIPS;

      if(stop > 0 && pipToPoint > 0)
         riskPips = MathAbs(entry - stop) / pipToPoint;

      totalRiskCurrency += riskPips * pipValuePerLot * lotSize;

      if(minHoldMs > 0)
      {
         ulong openTick = activeTrades[i].openTickTime;
         ulong heldMs = (openTick > 0 && nowTick >= openTick) ? (nowTick - openTick) : 0;
         if(heldMs < minHoldMs)
            holdSatisfied = false;
      }

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

   // FIXED: Only close basket if profitable
   if(OnlyCloseInProfit && totalProfit <= 0.0)
   {
      // Basket is losing - trigger martingale recovery if enabled
      if(UseMartingaleRecovery && totalActiveTrades < MaxTrades)
      {
         TriggerMartingaleRecovery(totalProfit);
      }
      return;  // Don't close losing basket
   }

   if(profitReady && dynamicTarget > 0.0 && totalProfit >= dynamicTarget)
   {
      CloseAllTrades("Dynamic profit target hit: KES " + DoubleToString(totalProfit, 2));
      return;
   }

   // FIXED: Peak giveback only applies if basket is profitable
   if(totalProfit > 0.0 && PeakGivebackPercent > 0.0 && dynamicTarget > 0.0 && highestBasketProfit >= dynamicTarget)
   {
      basketTrailingActive = true;
      double giveback = highestBasketProfit * (PeakGivebackPercent / 100.0);
      double trailLevel = highestBasketProfit - giveback;
      lastTrailLevel = trailLevel;

      // FIXED: Only close if trail level is still profitable
      if(profitReady && highestBasketProfit > 0.0 && giveback > 0.0 && totalProfit <= trailLevel && totalProfit > 0.0)
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

void CloseTradeAtIndex(int index, string reason)
{
   if(index < 0 || index >= totalActiveTrades) return;

   int ticket = activeTrades[index].ticket;

   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return;

   double preClosePL = OrderProfit() + OrderSwap() + OrderCommission();
   
   // FIXED: CRITICAL - Only close if trade is profitable
   if(OnlyCloseInProfit && preClosePL <= 0.0)
   {
      Print("BLOCKED: Attempted to close losing trade #", ticket, " | P&L: ", DoubleToString(preClosePL, 2), " | Reason: ", reason);
      return;  // Never close losing trades
   }

   double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;
   double volume = OrderLots();

   RefreshRates();
   bool closed = OrderClose(ticket, volume, closePrice, 3, clrYellow);

   if(closed)
   {
      double finalPL = preClosePL;
      if(OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY))
      {
         finalPL = OrderProfit() + OrderSwap() + OrderCommission();
      }

      dailyProfit += finalPL;
      
      // CRITICAL: Update daily loss tracking
      UpdateDailyLossTracking(finalPL);

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
               dailyProfit += finalPL;

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
   
   // CRITICAL: Check emergency stop
   if(EmergencyStopEnabled && emergencyStopActive)
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

// CRITICAL: Emergency stop protection
bool CheckEmergencyStop()
{
   if(!EmergencyStopEnabled)
      return false;
   
   double currentBalance = AccountBalance();
   double currentEquity = AccountEquity();
   
   // Update highest balance
   if(currentBalance > highestAccountBalance)
      highestAccountBalance = currentBalance;
   
   // Check maximum drawdown
   if(highestAccountBalance > 0.0)
   {
      double drawdown = ((highestAccountBalance - currentEquity) / highestAccountBalance) * 100.0;
      if(drawdown >= MaxDrawdownPercent)
      {
         if(!emergencyStopActive)
         {
            Print("CRITICAL: EMERGENCY STOP ACTIVATED - Drawdown: ", DoubleToString(drawdown, 2), "%");
            Alert("EMERGENCY STOP: Drawdown exceeded ", DoubleToString(MaxDrawdownPercent, 1), "%");
         }
         emergencyStopActive = true;
         return true;
      }
   }
   
   // Check daily loss limit
   if(dailyLossUSD >= MaxDailyLossUSD)
   {
      if(!emergencyStopActive)
      {
         Print("CRITICAL: EMERGENCY STOP ACTIVATED - Daily Loss: $", DoubleToString(dailyLossUSD, 2));
         Alert("EMERGENCY STOP: Daily loss limit exceeded");
      }
      emergencyStopActive = true;
      return true;
   }
   
   emergencyStopActive = false;
   return false;
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
   return totalActiveTrades < MaxTrades && tradingAllowed && dailyTradeCount < MaxDailyTrades;
}

void CloseAllTrades(string reason)
{
   Print("BASKET CLOSE: Closing all ", totalActiveTrades, " trades - ", reason);

   double totalPL = 0;
   int profitableTrades = 0;
   int losingTrades = 0;

   // FIXED: Only close profitable trades, skip losing ones
   for(int i = totalActiveTrades - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket > 0)
      {
         if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
         {
            double tradePL = OrderProfit() + OrderSwap() + OrderCommission();
            totalPL += tradePL;
            
            if(OnlyCloseInProfit && tradePL <= 0.0)
            {
               losingTrades++;
               Print("SKIPPED: Losing trade #", activeTrades[i].ticket, " | P&L: ", DoubleToString(tradePL, 2), " - Will not close");
               continue;  // Skip losing trades
            }
            
            profitableTrades++;
         CloseTradeAtIndex(i, reason);
         }
      }
   }

   Print("Basket closed: KES ", DoubleToString(totalPL, 2), " | Profitable: ", profitableTrades, " | Losing (kept): ", losingTrades, " | Reason: ", reason);

   highestBasketProfit = 0;
   basketTrailingActive = false;
   lastDynamicTarget = 0;
   lastTrailLevel = 0;
   
   // NEW: Reset basket direction when all trades closed
   if(totalActiveTrades == 0)
      currentBasketDirection = -1;
}

// CRITICAL: Update daily loss tracking
void UpdateDailyLossTracking(double tradePL)
{
   if(tradePL < 0.0)
   {
      dailyLossUSD += MathAbs(tradePL);
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
      
      // CRITICAL: Reset daily loss tracking
      dailyLossUSD = 0.0;
      emergencyStopActive = false;
      
      // NEW: Reset hyperactivity counters
      if(UseHyperactivityProtection)
      {
         tradesThisMinute = 0;
         tradesThisHour = 0;
         lastTradeTimestamp = 0;
         lastRequestTime = 0;
         currentMinute = 0;
         currentHour = 0;
      }
      
   // NEW: Reset basket direction
   currentBasketDirection = -1;
   
   // CRITICAL: Reset risk protection
   initialAccountBalance = AccountBalance();
   highestAccountBalance = AccountBalance();
   emergencyStopActive = false;
   dailyLossUSD = 0.0;
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

   string emergencyStatus = "";
   if(EmergencyStopEnabled && emergencyStopActive)
   {
      emergencyStatus = " | EMERGENCY STOP: ACTIVE";
   }

   string status = StringConcatenate(
      "==== QuickScalperPro v3.03 (SAFE MODE - Risk Protection) ====\n",
      "Status: ", (tradingAllowed ? "ACTIVE" : "PAUSED"), emergencyStatus, " | ", trend, " | RSI: ", DoubleToString(rsi, 1), " | Momentum: ", momentum, "\n",
      "Basket: ", totalActiveTrades, "/", MaxTrades, " | Daily Baskets: ", basketsCompleted, " | Trades: ", dailyTradeCount, "\n",
      "========================================\n",
      "BASKET P&L: KES ", DoubleToString(basketProfit, 2), "\n",
      profitInfo, "\n",
      "Trailing: ", trailingStatus, "\n",
      "========================================\n",
      "Daily P&L: KES ", DoubleToString(dailyProfit, 2), "\n",
      "Balance: KES ", DoubleToString(currentBalance, 2), "\n",
      "Spread: ", DoubleToString((Ask - Bid) / Point / 10.0, 1), " pips | Lot: ", DoubleToString(currentLotSize, 2), "\n",
      "Equity Target: ", DoubleToString(displayPercent, 2), "% | Hold >= ", IntegerToString(MinimumHoldMS), " ms"
   );

   Comment(status);
}

// NEW: Update hyperactivity protection counters
void UpdateHyperactivityCounters()
{
   if(!UseHyperactivityProtection)
      return;
   
   datetime now = TimeCurrent();
   datetime currentMin = (now / 60) * 60;  // Round to minute
   datetime currentHr = (now / 3600) * 3600;  // Round to hour
   
   // Reset minute counter if new minute
   if(currentMin != currentMinute)
   {
      tradesThisMinute = 0;
      currentMinute = currentMin;
   }
   
   // Reset hour counter if new hour
   if(currentHr != currentHour)
   {
      tradesThisHour = 0;
      currentHour = currentHr;
   }
}

// NEW: Check if trading is allowed (hyperactivity protection)
bool CanTradeNow()
{
   if(!UseHyperactivityProtection)
      return true;
   
   datetime now = TimeCurrent();
   
   // Check minimum time between trades
   if(lastTradeTimestamp > 0 && (now - lastTradeTimestamp) < MinSecondsBetweenTrades)
   {
      return false;  // Too soon since last trade
   }
   
   // Check trades per minute limit
   if(tradesThisMinute >= MaxTradesPerMinute)
   {
      return false;  // Too many trades this minute
   }
   
   // Check trades per hour limit
   if(tradesThisHour >= MaxTradesPerHour)
   {
      return false;  // Too many trades this hour
   }
   
   // Check request cooldown
   if(lastRequestTime > 0)
   {
      ulong timeSinceRequest = GetTickCount() - lastRequestTime;
      if(timeSinceRequest < (ulong)RequestCooldownMS)
      {
         return false;  // Too soon since last request
      }
   }
   
   return true;
}

// NEW: Get current basket direction (for no-hedging protection)
int GetBasketDirection()
{
   if(totalActiveTrades == 0)
      return -1;  // No basket
   
   // Check first active trade direction
   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket > 0)
      {
         if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
         {
            return OrderType();  // Return direction of first trade
         }
      }
   }
   
   return currentBasketDirection;  // Fallback to tracked direction
}

// FIXED: NEW FUNCTION - Martingale Recovery System
void TriggerMartingaleRecovery(double currentBasketPL)
{
   if(!UseMartingaleRecovery)
      return;
   
   if(currentBasketPL >= 0.0)
      return;  // Only trigger when basket is losing
   
   static datetime lastRecoveryTime = 0;
   static int recoveryTradesAdded = 0;
   
   // Reset recovery counter if basket becomes profitable
   if(currentBasketPL > 0.0)
   {
      recoveryTradesAdded = 0;
      return;
   }
   
   // Limit recovery trades
   if(recoveryTradesAdded >= MaxRecoveryTrades)
      return;
   
   // Cooldown between recovery trades (30 seconds)
   if(TimeCurrent() - lastRecoveryTime < 30)
      return;
   
   // Check if we can add more trades
   if(totalActiveTrades >= MaxTrades)
      return;
   
   // Determine direction based on current losing trades
   int buyCount = 0;
   int sellCount = 0;
   double buyPL = 0;
   double sellPL = 0;
   
   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket <= 0) continue;
      if(!OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET)) continue;
      
      double tradePL = OrderProfit() + OrderSwap() + OrderCommission();
      if(OrderType() == OP_BUY)
      {
         buyCount++;
         buyPL += tradePL;
      }
      else if(OrderType() == OP_SELL)
      {
         sellCount++;
         sellPL += tradePL;
      }
   }
   
   // Add recovery trade in the direction that's losing more
   int recoveryDirection = -1;
   if(buyPL < sellPL && buyPL < 0)
   {
      recoveryDirection = OP_BUY;  // Buy more to average down
   }
   else if(sellPL < buyPL && sellPL < 0)
   {
      recoveryDirection = OP_SELL;  // Sell more to average down
   }
   else if(buyPL < 0)
   {
      recoveryDirection = OP_BUY;
   }
   else if(sellPL < 0)
   {
      recoveryDirection = OP_SELL;
   }
   
   if(recoveryDirection != -1)
   {
      Print("MARTINGALE RECOVERY: Adding trade #", (recoveryTradesAdded + 1), " | Basket P&L: ", DoubleToString(currentBasketPL, 2));
      OpenScalpTrade(recoveryDirection);
      recoveryTradesAdded++;
      lastRecoveryTime = TimeCurrent();
   }
}

