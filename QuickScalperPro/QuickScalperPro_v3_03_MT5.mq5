#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "3.03"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

// CRITICAL FIX: Re-enabled stop loss to prevent catastrophic losses
#define FIXED_STOP_LOSS_PIPS 100.0  // CRITICAL: Stop loss re-enabled (100 pips)

input group "===== Dynamic Lot Sizing ====="
input double   AccountBalance_10K  = 1000000.0;
input double   AccountBalance_100  = 100000.0;
input double   AccountBalance_1500 = 500000.0;
input double   MinLotSize          = 0.01;  // CRITICAL FIX: Reduced from 0.10 to prevent huge losses
input double   MaxLotSize          = 0.05;  // CRITICAL FIX: Reduced from 1.0 to prevent huge losses

input group "===== Core Trading Settings ====="
input int      MagicNumber         = 202503;
input int      MaxTrades           = 5;     // Allow up to 5 trades as long as previous is profitable
input int      TradesPerBurst      = 1;    // CRITICAL FIX: Only 1 trade per burst to prevent rapid losses
input int      BurstDelayMS        = 500;  // FIXED: Increased delay to avoid hyperactivity
input double   MinPreviousTradeProfitPips = 10.0;  // NEW: Minimum profit in pips required on previous trade before opening new one

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
input double   MinProfitPipsToClose = 20.0;    // NEW: Minimum profit in pips before closing (20+ pips)
input double   MaxProfitPipsToClose = 100.0;   // NEW: Maximum profit in pips before closing

input group "===== Instant Profit Exit (Profit-Based) ====="
input bool     UseInstantProfitExit = true;   // FIXED: Enabled for instant profit
input double   InstantProfitPercent = 50.0;   // NEW: Close at X% profit (e.g., 50% = half profit, 100% = double)
input bool     UseProfitDouble      = true;   // NEW: Close when profit doubles (100% gain)

input group "===== Lot Growth Settings ====="
input double   ProfitStepForLotIncrease= 20.0;     // Increase lot size every X profit
input double   LotIncrementPerStep     = 0.01;     // Additional lot size per profit step
input double   BaseLotPercentRisk      = 1.0;      // NEW: Base lot size as % of account balance
input double   MaxLotPercentRisk       = 5.0;      // NEW: Maximum lot size as % of account balance (after wins)

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
   ulong    ticket;
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
int currentBasketDirection = -1;  // -1 = no basket, ORDER_TYPE_BUY = buy basket, ORDER_TYPE_SELL = sell basket

// CRITICAL: Risk protection variables
double initialAccountBalance = 0.0;
double highestAccountBalance = 0.0;
bool emergencyStopActive = false;
double dailyLossUSD = 0.0;

// NEW: Dynamic lot sizing based on wins/losses
int consecutiveWins = 0;
int consecutiveLossesForLot = 0;
double currentLotPercent = 1.0;  // Start at 1% risk
double lastClosedTradePL = 0.0;

// MT5 indicator handles
int emaFastHandle = INVALID_HANDLE;
int emaSlowHandle = INVALID_HANDLE;
int rsiHandle = INVALID_HANDLE;

// Cached tick data for MT5
MqlTick currentTick;
double currentBid = 0.0;
double currentAsk = 0.0;
double pipToPoint = 0.0;
int currentDigits = 0;

// =====================================================================
// Utility helpers (conversion guarantees for MT5)
// =====================================================================
bool UpdateMarketData()
{
   if(!SymbolInfoTick(_Symbol, currentTick))
      return false;

   currentBid = currentTick.bid;
   currentAsk = currentTick.ask;
   pipToPoint = _Point * 10.0;
   currentDigits = (int)_Digits;
   return (currentBid > 0.0 && currentAsk > 0.0);
}

double GetCurrentSpreadPips()
{
   if(pipToPoint <= 0.0)
      pipToPoint = _Point * 10.0;
   return ((currentAsk - currentBid) / _Point) / 10.0;
}

bool CopyIndicatorValue(int handle, int shift, double &value)
{
   double buffer[1];
   if(handle == INVALID_HANDLE)
      return false;

   if(CopyBuffer(handle, 0, shift, 1, buffer) <= 0)
      return false;

   value = buffer[0];
   return true;
}

bool CopyClosePrice(ENUM_TIMEFRAMES timeframe, int shift, double &value)
{
   double buffer[1];
   if(CopyClose(_Symbol, timeframe, shift, 1, buffer) <= 0)
      return false;
   value = buffer[0];
   return true;
}

datetime CopyBarTime(ENUM_TIMEFRAMES timeframe, int shift)
{
   datetime buffer[1];
   if(CopyTime(_Symbol, timeframe, shift, 1, buffer) <= 0)
      return 0;
   return buffer[0];
}

bool SelectPosition(ulong ticket)
{
   return PositionSelectByTicket(ticket);
}

double GetPositionProfitValue(ulong ticket)
{
   if(!SelectPosition(ticket))
      return 0.0;
   // In MT5, POSITION_PROFIT already includes commission, only add swap
   return PositionGetDouble(POSITION_PROFIT) +
          PositionGetDouble(POSITION_SWAP);
}

double GetHistoricalPositionProfit(ulong ticket, datetime openTime)
{
   datetime fromTime = (openTime > 0) ? openTime - 60 : (TimeCurrent() - 86400);
   datetime toTime = TimeCurrent();

   if(!HistorySelect(fromTime, toTime))
      return 0.0;

   double profit = 0.0;
   int dealsTotal = HistoryDealsTotal();
   for(int i = 0; i < dealsTotal; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) == (long)ticket)
      {
         double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         double dealSwap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
         double dealCommission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         profit += (dealProfit + dealSwap + dealCommission);
      }
   }
   return profit;
}

void RemoveActiveTrade(int index)
{
   if(index < 0 || index >= totalActiveTrades)
      return;

   for(int i = index; i < totalActiveTrades - 1; i++)
      activeTrades[i] = activeTrades[i + 1];

   if(totalActiveTrades > 0)
   {
      int lastIdx = totalActiveTrades - 1;
      activeTrades[lastIdx].ticket = 0;
      activeTrades[lastIdx].entryPrice = 0.0;
      activeTrades[lastIdx].openTime = 0;
      activeTrades[lastIdx].direction = -1;
      activeTrades[lastIdx].openTickTime = 0;
      activeTrades[lastIdx].trailingArmed = false;
      activeTrades[lastIdx].highWatermark = 0.0;
      activeTrades[lastIdx].lowWatermark = 0.0;
   }

   totalActiveTrades--;
   if(totalActiveTrades <= 0)
   {
      totalActiveTrades = 0;
      currentBasketDirection = -1;
   }
}

ulong ResolvePositionTicket(ulong candidateTicket, ENUM_ORDER_TYPE orderType, double targetPrice)
{
   if(candidateTicket != 0 && SelectPosition(candidateTicket))
      return candidateTicket;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!SelectPosition(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      if(symbol != _Symbol)
         continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      int mappedDirection = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(mappedDirection != orderType)
         continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(entry - targetPrice) < (5 * _Point))
         return ticket;
   }

   return candidateTicket;
}

// =====================================================================
// Core MT5 ported logic
// =====================================================================
int OnInit()
{
   Print("========================================");
   Print("QuickScalperPro EA v3.03 Initialized - SAFE MODE (Risk Protection Enabled)");

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(3);

   // CRITICAL: Initialize risk protection
   initialAccountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   highestAccountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   emergencyStopActive = false;
   dailyLossUSD = 0.0;
   Print("========================================");
   Print("Strategy: Ultra-Fast Tick-Based Scalping");
   Print("Symbol: ", _Symbol);
   Print("Timeframe: ", Period());

   if(UseGoldOnly && _Symbol != "XAUUSD")
   {
      Alert("ERROR: This EA is optimized for XAUUSD only!");
      return(INIT_FAILED);
   }

   totalActiveTrades = 0;
   lastTickCount = 0;
   dailyTradeCount = 0;

   for(int i = 0; i < 100; i++)
   {
      activeTrades[i].ticket = 0;
      activeTrades[i].entryPrice = 0;
      activeTrades[i].openTime = 0;
      activeTrades[i].direction = -1;
      activeTrades[i].openTickTime = 0;
      activeTrades[i].trailingArmed = false;
      activeTrades[i].highWatermark = 0;
      activeTrades[i].lowWatermark = 0;
   }

   long minStopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   // minStopLevel available if needed for validation

   emaFastHandle = iMA(_Symbol, PERIOD_M1, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, PERIOD_M1, TrendPeriod * 2, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle = iRSI(_Symbol, PERIOD_M1, MomentumPeriod, PRICE_CLOSE);

   if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles. MT5 conversion aborted.");
      return(INIT_FAILED);
   }

   double initTarget = GetEquityTargetPercent();
   
   // Initialize lot sizing variables
   consecutiveWins = 0;
   consecutiveLossesForLot = 0;
   currentLotPercent = BaseLotPercentRisk;
   lastClosedTradePL = 0.0;

   Print("Initialization successful!");
   Print("========================================");
   Print("ADAPTIVE PROFIT ENGINE ACTIVE");
   Print("Equity Target: ", DoubleToString(initTarget, 2), "% | RR Target ",
         (UseRiskRewardTarget ? "ON" : "OFF"), " (x", DoubleToString(RiskRewardMultiplier, 2),
         ") | Giveback: ", DoubleToString(PeakGivebackPercent, 2), "%");
   Print("Minimum Hold: ", MinimumHoldMS, " ms | Max Spread: ", MaxSpreadPips, " pips");
   Print("Profit Close Range: ", DoubleToString(MinProfitPipsToClose, 1), "-", DoubleToString(MaxProfitPipsToClose, 1), " pips");
   Print("Stop Loss: ", DoubleToString(FIXED_STOP_LOSS_PIPS, 1), " pips");
   Print("Dynamic Lot Sizing: ", DoubleToString(BaseLotPercentRisk, 1), "% to ", DoubleToString(MaxLotPercentRisk, 1), "% of account");
   Print("Previous Trade Check: Must be +", DoubleToString(MinPreviousTradeProfitPips, 1), " pips before new trade");
   Print("Max Trades: ", MaxTrades, " (as long as previous is profitable)");
   Print("Lot Bounds: Min=", MinLotSize, " | Max=", MaxLotSize);
   Print("========================================");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);

   Print("QuickScalperPro EA Deinitialized. Reason: ", reason);
}

void OnTick()
{
   if(!UpdateMarketData())
      return;

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
      Comment("SPREAD TOO HIGH: ", DoubleToString(GetCurrentSpreadPips(), 1), " pips");
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
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   // NEW: Calculate lot size based on win/loss streak (1% to 5% of account)
   double riskPercent = currentLotPercent;
   riskPercent = MathMax(riskPercent, BaseLotPercentRisk);
   riskPercent = MathMin(riskPercent, MaxLotPercentRisk);
   
   // Calculate lot size based on risk percentage
   // Assuming 1% risk means risking 1% of account balance
   // For simplicity, we'll use account balance to determine lot size
   double accountRiskAmount = currentBalance * (riskPercent / 100.0);
   
   // Calculate lot size based on stop loss distance
   double stopLossPips = FIXED_STOP_LOSS_PIPS;
   double pipValuePerLot = GetPipValuePerLot();
   
   double calculatedLot = MinLotSize;
   if(pipValuePerLot > 0 && stopLossPips > 0)
   {
      calculatedLot = accountRiskAmount / (stopLossPips * pipValuePerLot);
   }
   else
   {
      // Fallback calculation based on account balance
      if(currentBalance >= AccountBalance_10K)
      {
         calculatedLot = MathMax(MinLotSize, 0.10 * (riskPercent / BaseLotPercentRisk));
      }
      else if(currentBalance >= AccountBalance_1500)
      {
         calculatedLot = MathMax(MinLotSize, 0.08 * (riskPercent / BaseLotPercentRisk));
      }
      else if(currentBalance >= AccountBalance_100)
      {
         calculatedLot = MathMax(MinLotSize, 0.05 * (riskPercent / BaseLotPercentRisk));
      }
      else
      {
         calculatedLot = MinLotSize * (riskPercent / BaseLotPercentRisk);
      }
   }

   calculatedLot = MathMin(calculatedLot, MaxLotSize);
   calculatedLot = MathMax(calculatedLot, MinLotSize);

   return NormalizeDouble(calculatedLot, 2);
}

bool IsSpreadAcceptable()
{
   double currentSpread = GetCurrentSpreadPips();
   return (currentSpread <= MaxSpreadPips);
}

void TrackTickMovement()
{
   double currentPrice = (currentAsk + currentBid) / 2.0;

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

   if(signal == ORDER_TYPE_BUY || signal == ORDER_TYPE_SELL)
   {
      // NEW: No hedging - enforce single direction per basket
      if(EnforceSingleDirection && totalActiveTrades > 0)
      {
         int existingDirection = GetBasketDirection();
         if(existingDirection != -1 && existingDirection != signal)
         {
            Print("NO HEDGING: Existing basket direction is ", (existingDirection == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  " | Signal is ", (signal == ORDER_TYPE_BUY ? "BUY" : "SELL"), " - Skipping to avoid hedge");
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

         if(signal == ORDER_TYPE_BUY)
            OpenScalpTrade(ORDER_TYPE_BUY);
         else
            OpenScalpTrade(ORDER_TYPE_SELL);

         if(burst < TradesPerBurst - 1 && BurstDelayMS > 0)
            Sleep(BurstDelayMS);
      }
   }
}

int GetScalpingSignal()
{
   double currentSpread = GetCurrentSpreadPips();
   bool acceptableSpread = (currentSpread <= MaxSpreadPips);

   if(!acceptableSpread) return -1;

   double ema_fast = 0.0;
   double ema_slow = 0.0;
   double rsi = 0.0;

   if(!CopyIndicatorValue(emaFastHandle, 0, ema_fast)) return -1;
   if(!CopyIndicatorValue(emaSlowHandle, 0, ema_slow)) return -1;
   if(!CopyIndicatorValue(rsiHandle, 0, rsi)) return -1;

   double currentPrice = (currentAsk + currentBid) / 2.0;

   bool uptrend = ema_fast > ema_slow;
   bool downtrend = ema_fast < ema_slow;
   bool priceAboveEMA = currentPrice > ema_fast;
   bool priceBelowEMA = currentPrice < ema_fast;

   bool oversold = rsi < (50 - MinMomentumStrength);
   bool overbought = rsi > (50 + MinMomentumStrength);
   bool bullishMomentum = rsi > 50 && rsi < 70;
   bool bearishMomentum = rsi < 50 && rsi > 30;

   double previousClose = 0.0;
   double currentClose = 0.0;
   if(!CopyClosePrice(PERIOD_M1, 1, previousClose)) return -1;
   if(!CopyClosePrice(PERIOD_M1, 0, currentClose)) return -1;
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
      if(buyScore >= 2) return ORDER_TYPE_BUY;
      if(sellScore >= 2) return ORDER_TYPE_SELL;
      return -1;
   }

   if(buySignal && sellSignal)
   {
      if(buyScore > sellScore)
         return ORDER_TYPE_BUY;
      else if(sellScore > buyScore)
         return ORDER_TYPE_SELL;
      else
         return -1;
   }
   else if(buySignal)
   {
      return ORDER_TYPE_BUY;
   }
   else if(sellSignal)
   {
      return ORDER_TYPE_SELL;
   }

   return -1;
}

void OpenScalpTrade(int orderType)
{
   if(orderType != ORDER_TYPE_BUY && orderType != ORDER_TYPE_SELL)
      return;

   double price = (orderType == ORDER_TYPE_BUY) ? currentAsk : currentBid;

   double lotSize = CalculateDynamicLotSize();
   double sl = 0;
   double tp = 0;
   double localPipToPoint = pipToPoint;

   if(!IsSpreadAcceptable())
   {
      Print("Trade blocked - Spread too high: ", DoubleToString(GetCurrentSpreadPips(), 1));
      return;
   }

   // CRITICAL FIX: Stop loss re-enabled to prevent catastrophic losses
   double stopLossPips = FIXED_STOP_LOSS_PIPS;
   if(stopLossPips > 0.0 && localPipToPoint > 0.0)
   {
      double slDistance = stopLossPips * localPipToPoint;
      if(orderType == ORDER_TYPE_BUY)
         sl = NormalizeDouble(price - slDistance, currentDigits);
      else
         sl = NormalizeDouble(price + slDistance, currentDigits);
   }
   else
   {
      double minSafetyStop = 100.0 * localPipToPoint;
      if(orderType == ORDER_TYPE_BUY)
         sl = NormalizeDouble(price - minSafetyStop, currentDigits);
      else
         sl = NormalizeDouble(price + minSafetyStop, currentDigits);
   }

   if(UseTakeProfitPercent && TakeProfitPercent > 0.0 && localPipToPoint > 0.0)
   {
      tp = 0;  // TP managed later via profit percentage logic
   }

   string comment = "ScalpPro " + (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL") + " Lot:" + DoubleToString(lotSize, 2);

   // NEW: Record request time for hyperactivity protection
   if(UseHyperactivityProtection)
   {
      lastRequestTime = GetTickCount();

      if(lastRequestTime > 0 && RequestCooldownMS > 0)
      {
         ulong timeSinceRequest = GetTickCount() - lastRequestTime;
         if(timeSinceRequest < (ulong)RequestCooldownMS)
         {
            Sleep((int)(RequestCooldownMS - timeSinceRequest));
         }
      }
   }

   bool sent = false;
   if(orderType == ORDER_TYPE_BUY)
      sent = trade.Buy(lotSize, _Symbol, price, sl, tp, comment);
   else
      sent = trade.Sell(lotSize, _Symbol, price, sl, tp, comment);

   if(sent)
   {
      // In MT5, ResultPosition() doesn't exist in CTrade class
      // Search for the position that was just opened by matching symbol, direction, and entry price
      ulong positionTicket = ResolvePositionTicket(0, (ENUM_ORDER_TYPE)orderType, price);

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

      if(totalActiveTrades == 0)
      {
         currentBasketDirection = orderType;  // Set direction for new basket
      }

      if(totalActiveTrades < 100 && positionTicket != 0)
      {
         activeTrades[totalActiveTrades].ticket = positionTicket;
         activeTrades[totalActiveTrades].entryPrice = price;
         activeTrades[totalActiveTrades].openTime = TimeCurrent();
         activeTrades[totalActiveTrades].direction = orderType;
         activeTrades[totalActiveTrades].openTickTime = GetTickCount();
         activeTrades[totalActiveTrades].trailingArmed = false;
         activeTrades[totalActiveTrades].highWatermark = price;
         activeTrades[totalActiveTrades].lowWatermark = price;
         totalActiveTrades++;
      }

      Print("Basket trade #", dailyTradeCount, " opened: ", comment, " | Ticket: ", positionTicket,
            " | Price: ", DoubleToString(price, currentDigits), " | Lot: ", DoubleToString(lotSize, 2),
            " | Basket: ", totalActiveTrades, "/", MaxTrades);
   }
   else
   {
      Print("Error opening scalp trade: ", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
   }
}

double GetPipValuePerLot()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double localPoint = _Point;
   double pipSize = localPoint * 10.0;

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

void UpdatePerTradeTrailing(int index, double localPipToPoint)
{
   if(!UseTrailingStop || TrailingStartPercent <= 0.0 || TrailingStepPercent <= 0.0)
      return;

   if(index < 0 || index >= totalActiveTrades)
      return;

   ulong ticket = activeTrades[index].ticket;
   if(ticket == 0)
      return;

   if(!SelectPosition(ticket))
      return;

   // FIXED: Only trail if trade is profitable - never trail losing trades
   // In MT5, POSITION_PROFIT already includes commission, only add swap
   double tradeProfit = PositionGetDouble(POSITION_PROFIT) +
                        PositionGetDouble(POSITION_SWAP);
   if(OnlyCloseInProfit && tradeProfit <= 0.0)
      return;  // Don't trail losing trades

   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double price = (type == POSITION_TYPE_BUY) ? currentBid : currentAsk;
   double entry = activeTrades[index].entryPrice;
   double lotSize = PositionGetDouble(POSITION_VOLUME);

   double pipValuePerLot = GetPipValuePerLot();
   double riskAmount = entry * lotSize * 0.01;  // Base risk calculation
   double profitPercent = 0.0;
   if(riskAmount > 0.0)
      profitPercent = (tradeProfit / riskAmount) * 100.0;

   if(localPipToPoint <= 0.0)
      return;

   // NEW: Trailing using profit percentage
   if(profitPercent >= TrailingStartPercent)
   {
      if(!activeTrades[index].trailingArmed)
         activeTrades[index].trailingArmed = true;

      if(activeTrades[index].trailingArmed)
      {
         double trailPercent = profitPercent - TrailingStepPercent;
         if(trailPercent > 0.0)
         {
            double trailProfit = riskAmount * (trailPercent / 100.0);
            double trailDistance = 0.0;

            if(type == POSITION_TYPE_BUY)
            {
               activeTrades[index].highWatermark = MathMax(activeTrades[index].highWatermark, price);
               trailDistance = trailProfit / (pipValuePerLot * lotSize);
               if(trailDistance > 0 && localPipToPoint > 0)
               {
                  trailDistance = trailDistance * localPipToPoint;
                  double newStop = NormalizeDouble(activeTrades[index].highWatermark - trailDistance, currentDigits);
                  if(newStop >= entry && newStop > PositionGetDouble(POSITION_SL) && newStop < price)
                     ModifyOrderStop(ticket, newStop);
               }
            }
            else if(type == POSITION_TYPE_SELL)
            {
               activeTrades[index].lowWatermark = MathMin(activeTrades[index].lowWatermark, price);
               trailDistance = trailProfit / (pipValuePerLot * lotSize);
               if(trailDistance > 0 && localPipToPoint > 0)
               {
                  trailDistance = trailDistance * localPipToPoint;
                  double newStop = NormalizeDouble(activeTrades[index].lowWatermark + trailDistance, currentDigits);
                  double currentStop = PositionGetDouble(POSITION_SL);
                  if(newStop <= entry && (currentStop == 0 || newStop < currentStop) && newStop > price)
                     ModifyOrderStop(ticket, newStop);
               }
            }
         }
      }
   }
}

bool ModifyOrderStop(ulong ticket, double newStop)
{
   if(newStop <= 0.0)
      return(false);

   if(!SelectPosition(ticket))
      return(false);

   double tp = PositionGetDouble(POSITION_TP);

   if(!trade.PositionModify(ticket, newStop, tp))
   {
      Print("OrderModify failed ticket=", ticket, " error=", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
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
   double localPipToPoint = pipToPoint;
   double pipValuePerLot = GetPipValuePerLot();

   double totalProfit = 0;
   double totalRiskCurrency = 0;
   bool holdSatisfied = true;

   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket == 0)
         continue;

      if(!SelectPosition(activeTrades[i].ticket))
         continue;

      ENUM_POSITION_TYPE orderType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentPrice = (orderType == POSITION_TYPE_BUY) ? currentBid : currentAsk;
      double pipGain = 0.0;
      if(localPipToPoint > 0.0)
      {
         if(orderType == POSITION_TYPE_BUY)
            pipGain = (currentPrice - entry) / localPipToPoint;
         else if(orderType == POSITION_TYPE_SELL)
            pipGain = (entry - currentPrice) / localPipToPoint;
      }

      // In MT5, POSITION_PROFIT already includes commission, only add swap
      double tradeProfit = PositionGetDouble(POSITION_PROFIT) +
                           PositionGetDouble(POSITION_SWAP);
      double lotSize = PositionGetDouble(POSITION_VOLUME);
      double entryPrice = activeTrades[i].entryPrice;
      double stop = PositionGetDouble(POSITION_SL);

      double riskAmount = 0.0;
      if(stop > 0 && localPipToPoint > 0)
      {
         double riskPips = MathAbs(entry - stop) / localPipToPoint;
         riskAmount = riskPips * pipValuePerLot * lotSize;
      }
      else
      {
         riskAmount = entryPrice * lotSize * 0.01;  // 1% of entry value as base
      }

      double profitPercent = 0.0;
      if(riskAmount > 0.0)
         profitPercent = (tradeProfit / riskAmount) * 100.0;

      // NEW: Break-Even Protection - Move SL to BE once profitable (using percentage)
      if(BreakEvenTriggerPercent > 0.0 && tradeProfit > 0.0 && profitPercent >= BreakEvenTriggerPercent)
      {
         double currentSL = PositionGetDouble(POSITION_SL);
         if(orderType == POSITION_TYPE_BUY && (currentSL == 0 || currentSL < entryPrice))
         {
            ModifyOrderStop(activeTrades[i].ticket, entryPrice);
         }
         else if(orderType == POSITION_TYPE_SELL && (currentSL == 0 || currentSL > entryPrice))
         {
            ModifyOrderStop(activeTrades[i].ticket, entryPrice);
         }
      }

      // CRITICAL FIX: Allow closing losing trades if loss is too high
      if(OnlyCloseInProfit && tradeProfit <= 0.0)
      {
         if(MaxLossPerTradeUSD > 0.0 && MathAbs(tradeProfit) >= MaxLossPerTradeUSD)
         {
            CloseTradeAtIndex(i, "CRITICAL: Max loss per trade exceeded: $" + DoubleToString(tradeProfit, 2));
            i--;
            continue;
         }

         totalProfit += tradeProfit;
         UpdatePerTradeTrailing(i, localPipToPoint);
         continue;
      }

      // NEW: Only close profits at 20+ pips (prevent premature exits, not based on dollar amount)
      if(tradeProfit > 0.0 && localPipToPoint > 0.0)
      {
         bool shouldClose = false;
         string closeReason = "";
         
         // Check if profit is at least 20 pips (or up to max range)
         if(pipGain >= MinProfitPipsToClose && pipGain <= MaxProfitPipsToClose)
         {
            shouldClose = true;
            closeReason = "Profit target reached: " + DoubleToString(pipGain, 1) + " pips | P&L: " + DoubleToString(tradeProfit, 2);
         }
         // Allow closing if profit exceeds maximum range (don't hold too long)
         else if(pipGain > MaxProfitPipsToClose)
         {
            shouldClose = true;
            closeReason = "Profit exceeded max range: " + DoubleToString(pipGain, 1) + " pips | P&L: " + DoubleToString(tradeProfit, 2);
         }
         // Don't close if below minimum (prevent premature exits)
         
         if(shouldClose)
         {
            CloseTradeAtIndex(i, closeReason);
            i--;
            continue;
         }
      }
      
      // Keep emergency exit conditions but only for very high profits or losses
      if(UseTakeProfitPercent && TakeProfitPercent > 0.0 && profitPercent >= TakeProfitPercent && pipGain >= MinProfitPipsToClose)
      {
         CloseTradeAtIndex(i, "Take profit " + DoubleToString(profitPercent, 1) + "%: " + DoubleToString(tradeProfit, 2));
         i--;
         continue;
      }

      totalProfit += tradeProfit;

      double riskPips = FIXED_STOP_LOSS_PIPS;
      if(stop > 0 && localPipToPoint > 0)
         riskPips = MathAbs(entry - stop) / localPipToPoint;

      totalRiskCurrency += riskPips * pipValuePerLot * lotSize;

      if(minHoldMs > 0)
      {
         ulong openTick = activeTrades[i].openTickTime;
         ulong heldMs = (openTick > 0 && nowTick >= openTick) ? (nowTick - openTick) : 0;
         if(heldMs < minHoldMs)
            holdSatisfied = false;
      }

      UpdatePerTradeTrailing(i, localPipToPoint);
   }

   if(totalProfit > highestBasketProfit)
      highestBasketProfit = totalProfit;

   double targetPercent = GetEquityTargetPercent();
   double equityTarget = (targetPercent > 0.0)
                         ? AccountInfoDouble(ACCOUNT_BALANCE) * (targetPercent / 100.0)
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

   if(OnlyCloseInProfit && totalProfit <= 0.0)
   {
      if(UseMartingaleRecovery && totalActiveTrades < MaxTrades)
      {
         TriggerMartingaleRecovery(totalProfit);
      }
      return;
   }

   if(profitReady && dynamicTarget > 0.0 && totalProfit >= dynamicTarget)
   {
      CloseAllTrades("Dynamic profit target hit: USD " + DoubleToString(totalProfit, 2));
      return;
   }

   if(totalProfit > 0.0 && PeakGivebackPercent > 0.0 && dynamicTarget > 0.0 && highestBasketProfit >= dynamicTarget)
   {
      basketTrailingActive = true;
      double giveback = highestBasketProfit * (PeakGivebackPercent / 100.0);
      double trailLevel = highestBasketProfit - giveback;
      lastTrailLevel = trailLevel;

      if(profitReady && highestBasketProfit > 0.0 && giveback > 0.0 && totalProfit <= trailLevel && totalProfit > 0.0)
      {
        CloseAllTrades("Dynamic peak trail: USD " + DoubleToString(totalProfit, 2));
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

   ulong ticket = activeTrades[index].ticket;

   if(ticket == 0) return;

   if(!SelectPosition(ticket))
   {
      double finalAutoPL = GetHistoricalPositionProfit(ticket, activeTrades[index].openTime);
      if(finalAutoPL != 0.0)
      {
         dailyProfit += finalAutoPL;
         UpdateDailyLossTracking(finalAutoPL);
      }
      RemoveActiveTrade(index);
      return;
   }

   // In MT5, POSITION_PROFIT already includes commission, only add swap
   double preClosePL = PositionGetDouble(POSITION_PROFIT) +
                       PositionGetDouble(POSITION_SWAP);

   if(OnlyCloseInProfit && preClosePL <= 0.0)
   {
      Print("BLOCKED: Attempted to close losing trade #", ticket, " | P&L: ", DoubleToString(preClosePL, 2), " | Reason: ", reason);
      return;
   }

   bool closed = trade.PositionClose(ticket);

   if(closed)
   {
      // In MT5, get profit from the deal that was created when closing
      double finalPL = preClosePL;
      ulong dealTicket = trade.ResultDeal();
      if(dealTicket > 0)
      {
         if(HistoryDealSelect(dealTicket))
         {
            double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            double dealSwap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            double dealCommission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            finalPL = dealProfit + dealSwap + dealCommission;
         }
      }

      dailyProfit += finalPL;
      lastClosedTradePL = finalPL;

      UpdateDailyLossTracking(finalPL);

      // NEW: Update lot sizing based on win/loss
      if(finalPL < 0)
      {
         consecutiveLosses++;
         consecutiveLossesForLot++;
         consecutiveWins = 0;
         
         // After losing trade: keep same or reduce lot size
         // Don't reduce below base (1%), but reduce incrementally
         if(consecutiveLossesForLot > 0)
         {
            double reductionFactor = 0.95; // Reduce by 5% per loss (but not below base)
            currentLotPercent = MathMax(BaseLotPercentRisk, currentLotPercent * reductionFactor);
         }
         
         Print("CONSECUTIVE LOSS #", consecutiveLosses, ": USD ", DoubleToString(finalPL, 2), 
               " | Lot % reduced to: ", DoubleToString(currentLotPercent, 2), "%");
      }
      else
      {
         consecutiveLosses = 0;
         consecutiveLossesForLot = 0;
         consecutiveWins++;
         strategyShifted = false;
         
         // After winning trade: increase lot size from 1% to 5%
         if(consecutiveWins > 0)
         {
            // Increase lot size progressively: start at 1%, go up to 5%
            double increasePerWin = (MaxLotPercentRisk - BaseLotPercentRisk) / 5.0; // Reach max in 5 wins
            currentLotPercent = MathMin(MaxLotPercentRisk, BaseLotPercentRisk + (increasePerWin * consecutiveWins));
         }
         
         Print("PROFIT #", consecutiveWins, " - Reset consecutive loss counter | Lot % increased to: ", 
               DoubleToString(currentLotPercent, 2), "%");
      }

      Print("Trade closed: ", reason, " | P&L: USD ", DoubleToString(finalPL, 2));

      RemoveActiveTrade(index);
   }
   else
   {
      Print("Trade close failed ticket=", ticket, " error=", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
   }
}

void CleanupClosedTrades()
{
   for(int i = totalActiveTrades - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket > 0)
      {
         if(!SelectPosition(activeTrades[i].ticket))
         {
            double finalPL = GetHistoricalPositionProfit(activeTrades[i].ticket, activeTrades[i].openTime);
            dailyProfit += finalPL;

            lastClosedTradePL = finalPL;
            
            if(finalPL < 0)
            {
               consecutiveLosses++;
               consecutiveLossesForLot++;
               consecutiveWins = 0;
               
               // After losing trade: keep same or reduce lot size
               if(consecutiveLossesForLot > 0)
               {
                  double reductionFactor = 0.95;
                  currentLotPercent = MathMax(BaseLotPercentRisk, currentLotPercent * reductionFactor);
               }
               
               Print("CONSECUTIVE LOSS #", consecutiveLosses, ": USD ", DoubleToString(finalPL, 2),
                     " | Lot % reduced to: ", DoubleToString(currentLotPercent, 2), "%");
            }
            else
            {
               consecutiveLosses = 0;
               consecutiveLossesForLot = 0;
               consecutiveWins++;
               strategyShifted = false;
               
               // After winning trade: increase lot size
               if(consecutiveWins > 0)
               {
                  double increasePerWin = (MaxLotPercentRisk - BaseLotPercentRisk) / 5.0;
                  currentLotPercent = MathMin(MaxLotPercentRisk, BaseLotPercentRisk + (increasePerWin * consecutiveWins));
               }
               
               Print("PROFIT #", consecutiveWins, " | Lot % increased to: ", DoubleToString(currentLotPercent, 2), "%");
            }

            Print("Trade auto-closed: USD ", DoubleToString(finalPL, 2));

            RemoveActiveTrade(i);
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

bool CheckEmergencyStop()
{
   if(!EmergencyStopEnabled)
      return false;

   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(currentBalance > highestAccountBalance)
      highestAccountBalance = currentBalance;

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
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return false;

   return true;
}

bool CanOpenNewTrade()
{
   if(!tradingAllowed || dailyTradeCount >= MaxDailyTrades)
      return false;
   
   // NEW: Can take up to MaxTrades (5) as long as ALL previous trades are profitable above 10 pips
   if(totalActiveTrades >= MaxTrades)
      return false;
   
   // NEW: Must not take trade before ALL previous trades are +10 pips profitable
   if(totalActiveTrades > 0 && MinPreviousTradeProfitPips > 0.0)
   {
      // Check ALL active trades - all must be profitable above 10 pips
      for(int i = 0; i < totalActiveTrades; i++)
      {
         if(activeTrades[i].ticket > 0)
         {
            if(SelectPosition(activeTrades[i].ticket))
            {
               // In MT5, POSITION_PROFIT already includes commission, only add swap
               double tradePL = PositionGetDouble(POSITION_PROFIT) +
                              PositionGetDouble(POSITION_SWAP);
               
               ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
               double entry = PositionGetDouble(POSITION_PRICE_OPEN);
               double currentPrice = (posType == POSITION_TYPE_BUY) ? currentBid : currentAsk;
               
               double pipGain = 0.0;
               if(pipToPoint > 0.0)
               {
                  if(posType == POSITION_TYPE_BUY)
                     pipGain = (currentPrice - entry) / pipToPoint;
                  else if(posType == POSITION_TYPE_SELL)
                     pipGain = (entry - currentPrice) / pipToPoint;
               }
               
               // Block new trade if ANY active trade is not profitable or below 10 pips
               if(tradePL <= 0.0 || pipGain < MinPreviousTradeProfitPips)
               {
                  return false;
               }
            }
         }
      }
   }
   
   return true;
}

void CloseAllTrades(string reason)
{
   Print("BASKET CLOSE: Closing all ", totalActiveTrades, " trades - ", reason);

   double totalPL = 0;
   int profitableTrades = 0;
   int losingTrades = 0;

   for(int i = totalActiveTrades - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket > 0)
      {
         double tradePL = GetPositionProfitValue(activeTrades[i].ticket);
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

   Print("Basket closed: USD ", DoubleToString(totalPL, 2), " | Profitable: ", profitableTrades, " | Losing (kept): ", losingTrades, " | Reason: ", reason);

   highestBasketProfit = 0;
   basketTrailingActive = false;
   lastDynamicTarget = 0;
   lastTrailLevel = 0;

   if(totalActiveTrades == 0)
      currentBasketDirection = -1;
}

void UpdateDailyLossTracking(double tradePL)
{
   if(tradePL < 0.0)
   {
      dailyLossUSD += MathAbs(tradePL);
   }
}

void CheckDailyReset()
{
   datetime currentDay = CopyBarTime(PERIOD_D1, 0);

   if(currentDay != lastDayReset)
   {
      Print("Daily reset - Previous P&L: USD ", DoubleToString(dailyProfit, 2), " | Total Trades: ", dailyTradeCount);
      dailyProfit = 0;
      dailyTradeCount = 0;
      lastDayReset = currentDay;
      highestBasketProfit = 0;
      basketTrailingActive = false;
      lastDynamicTarget = 0;
      lastTrailLevel = 0;

      dailyLossUSD = 0.0;
      emergencyStopActive = false;
      
      // Reset lot sizing variables
      consecutiveWins = 0;
      consecutiveLossesForLot = 0;
      currentLotPercent = BaseLotPercentRisk;
      lastClosedTradePL = 0.0;

      if(UseHyperactivityProtection)
      {
         tradesThisMinute = 0;
         tradesThisHour = 0;
         lastTradeTimestamp = 0;
         lastRequestTime = 0;
         currentMinute = 0;
         currentHour = 0;
      }

      currentBasketDirection = -1;

      initialAccountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      highestAccountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      emergencyStopActive = false;
      dailyLossUSD = 0.0;
   }
}

void UpdateDisplay()
{
   double currentLotSize = CalculateDynamicLotSize();
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   double basketProfit = 0;
   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket > 0)
      {
         basketProfit += GetPositionProfitValue(activeTrades[i].ticket);
      }
   }

   double ema_fast = 0.0;
   double ema_slow = 0.0;
   double rsi = 0.0;
   CopyIndicatorValue(emaFastHandle, 0, ema_fast);
   CopyIndicatorValue(emaSlowHandle, 0, ema_slow);
   CopyIndicatorValue(rsiHandle, 0, rsi);
   string trend = (ema_fast > ema_slow) ? "UPTREND" : "DOWNTREND";
   string momentum = (rsi > 50) ? "BULLISH" : "BEARISH";

   string trailingStatus = "OFF";
   if(basketTrailingActive && lastTrailLevel > 0.0)
      trailingStatus = "ACTIVE @ USD " + DoubleToString(lastTrailLevel, 2);

   int basketsCompleted = (TradesPerBurst > 0) ? dailyTradeCount / TradesPerBurst : dailyTradeCount;
   double effectiveTarget = lastDynamicTarget;
   double displayPercent = GetEquityTargetPercent();
   if(effectiveTarget <= 0.0 && displayPercent > 0.0)
      effectiveTarget = AccountInfoDouble(ACCOUNT_BALANCE) * (displayPercent / 100.0);

   string profitInfo = "Dynamic Target: USD " + DoubleToString(effectiveTarget, 2) +
                       " | Peak: " + DoubleToString(highestBasketProfit, 2);
   if(basketTrailingActive && lastTrailLevel > 0.0)
      profitInfo += " | Trail: " + DoubleToString(lastTrailLevel, 2);
   profitInfo += " | RR x" + DoubleToString(RiskRewardMultiplier, 1);

   string emergencyStatus = "";
   if(EmergencyStopEnabled && emergencyStopActive)
   {
      emergencyStatus = " | EMERGENCY STOP: ACTIVE";
   }

   // In MT5, use string concatenation with + operator instead of StringConcatenate
   string status = "==== QuickScalperPro v3.03 (SAFE MODE - Risk Protection) ====\n" +
      "Status: " + (string)(tradingAllowed ? "ACTIVE" : "PAUSED") + emergencyStatus + " | " + trend + " | RSI: " + DoubleToString(rsi, 1) + " | Momentum: " + momentum + "\n" +
      "Basket: " + IntegerToString(totalActiveTrades) + "/" + IntegerToString(MaxTrades) + " | Daily Baskets: " + IntegerToString(basketsCompleted) + " | Trades: " + IntegerToString(dailyTradeCount) + "\n" +
      "========================================\n" +
      "BASKET P&L: USD " + DoubleToString(basketProfit, 2) + "\n" +
      profitInfo + "\n" +
      "Trailing: " + trailingStatus + "\n" +
      "========================================\n" +
      "Daily P&L: USD " + DoubleToString(dailyProfit, 2) + "\n" +
      "Balance: USD " + DoubleToString(currentBalance, 2) + "\n" +
      "Spread: " + DoubleToString(GetCurrentSpreadPips(), 1) + " pips | Lot: " + DoubleToString(currentLotSize, 2) + "\n" +
      "Equity Target: " + DoubleToString(displayPercent, 2) + "% | Hold >= " + IntegerToString(MinimumHoldMS) + " ms";

   Comment(status);
}

void UpdateHyperactivityCounters()
{
   if(!UseHyperactivityProtection)
      return;

   datetime now = TimeCurrent();
   datetime currentMin = (now / 60) * 60;
   datetime currentHr = (now / 3600) * 3600;

   if(currentMin != currentMinute)
   {
      tradesThisMinute = 0;
      currentMinute = currentMin;
   }

   if(currentHr != currentHour)
   {
      tradesThisHour = 0;
      currentHour = currentHr;
   }
}

bool CanTradeNow()
{
   if(!UseHyperactivityProtection)
      return true;

   datetime now = TimeCurrent();

   if(lastTradeTimestamp > 0 && (now - lastTradeTimestamp) < MinSecondsBetweenTrades)
   {
      return false;
   }

   if(tradesThisMinute >= MaxTradesPerMinute)
   {
      return false;
   }

   if(tradesThisHour >= MaxTradesPerHour)
   {
      return false;
   }

   if(lastRequestTime > 0)
   {
      ulong timeSinceRequest = GetTickCount() - lastRequestTime;
      if(timeSinceRequest < (ulong)RequestCooldownMS)
      {
         return false;
      }
   }

   return true;
}

int GetBasketDirection()
{
   if(totalActiveTrades == 0)
      return -1;

   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket > 0)
      {
         if(SelectPosition(activeTrades[i].ticket))
         {
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            return (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         }
      }
   }

   return currentBasketDirection;
}

void TriggerMartingaleRecovery(double currentBasketPL)
{
   if(!UseMartingaleRecovery)
      return;

   if(currentBasketPL >= 0.0)
      return;

   static datetime lastRecoveryTime = 0;
   static int recoveryTradesAdded = 0;

   if(currentBasketPL > 0.0)
   {
      recoveryTradesAdded = 0;
      return;
   }

   if(recoveryTradesAdded >= MaxRecoveryTrades)
      return;

   if(TimeCurrent() - lastRecoveryTime < 30)
      return;

   if(totalActiveTrades >= MaxTrades)
      return;

   int buyCount = 0;
   int sellCount = 0;
   double buyPL = 0;
   double sellPL = 0;

   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket <= 0) continue;
      if(!SelectPosition(activeTrades[i].ticket)) continue;

      // In MT5, POSITION_PROFIT already includes commission, only add swap
      double tradePL = PositionGetDouble(POSITION_PROFIT) +
                       PositionGetDouble(POSITION_SWAP);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(posType == POSITION_TYPE_BUY)
      {
         buyCount++;
         buyPL += tradePL;
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         sellCount++;
         sellPL += tradePL;
      }
   }

   int recoveryDirection = -1;
   if(buyPL < sellPL && buyPL < 0)
   {
      recoveryDirection = ORDER_TYPE_BUY;
   }
   else if(sellPL < buyPL && sellPL < 0)
   {
      recoveryDirection = ORDER_TYPE_SELL;
   }
   else if(buyPL < 0)
   {
      recoveryDirection = ORDER_TYPE_BUY;
   }
   else if(sellPL < 0)
   {
      recoveryDirection = ORDER_TYPE_SELL;
   }

   if(recoveryDirection != -1)
   {
      Print("MARTINGALE RECOVERY: Adding trade #", (recoveryTradesAdded + 1), " | Basket P&L: ", DoubleToString(currentBasketPL, 2));
      OpenScalpTrade(recoveryDirection);
      recoveryTradesAdded++;
      lastRecoveryTime = TimeCurrent();
   }
}

