#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "5.00"
#property strict

#define MAX_ACTIVE_TRADES 1000
#define MAX_PENDING_ORDERS 400

input group "===== Dynamic Lot Sizing ====="
input double AccountBalance_10K  = 1000000.0;
input double AccountBalance_100  = 100000.0;
input double AccountBalance_1500 = 500000.0;
input double MinLotSize          = 0.01;
input double MaxLotSize          = 0.10;

input group "===== Core Trading Settings ====="
input int MagicNumber            = 202503;
input int MaxTrades              = 1000;
input int TradesPerBurst         = 5;
input int BurstDelayMS           = 100;

input group "===== Adaptive Profit Engine ====="
enum EquityTargetPresetOption 
{
   EquityTarget_1Percent = 1,
   EquityTarget_2Percent = 2,
   EquityTarget_4Percent = 4
};
input EquityTargetPresetOption EquityTargetPreset = EquityTarget_2Percent;

input bool   UseCustomEquityTarget = false;
input double CustomEquityPercent   = 2.0;

input bool   UseRiskRewardTarget   = false;
input double RiskRewardMultiplier  = 3.0;
input double PeakGivebackPercent   = 30.0;

input int MinimumHoldMS = 5000;

input double MaxSpreadPips = 3.0;

input group "===== Trading Controls ====="
input bool TradeEnabled       = true;
input int TickDelay           = 1;
input int MaxConsecutiveLosses= 5;
input bool UseGoldOnly        = true;
input int MaxDailyTrades      = 999999;

input group "===== Risk Parameters ====="
input double StopLossPips = 50.0;

input group "===== Strategy Settings ====="
input int TrendPeriod         = 10;
input int MomentumPeriod      = 9;
input double MinMomentumStrength = 20.0;
input bool OnlyTrendTrades    = false;

input group "===== Per-Trade Exit Options ====="
input bool   UseTakeProfitPips = false;
input double TakeProfitPips    = 150.0;

input bool   UseTrailingStop    = true;
input double TrailingStartPips  = 120.0;
input double TrailingStepPips   = 60.0;

input double PerTradeProfitLock = 5000.0;

input group "===== Instant Profit Exit ====="
input bool   UseInstantProfitExit = false;
input double InstantProfitPips     = 10.0;

input bool ExitOnAnyProfit   = false;
input int  QuickExitSeconds  = 300;

input group "===== Pattern Recovery Settings ====="
input bool UsePatternRecovery      = true;
input int  LosingSellStreakTrigger = 2;
input int  LosingBuyStreakTrigger  = 2;
input int  RecoveryBuyBurst        = 3;
input int  RecoverySellBurst       = 3;

input bool PatternRequiresSignal   = true;
input bool UseImmediateReversal    = true;
input int  ImmediateReversalBursts = 1;

input group "===== Exposure Governor ====="
input bool   UseExposureGovernor   = true;
input double MinFreeMarginPercent  = 60.0;
input double MinEquityPercent      = 85.0;
input double MinLotScaleFactor     = 0.10;
input double BurstScaleMin         = 0.25;
input double BurstScaleMax         = 1.0;
input int    GovernorRefreshSeconds= 30;

input group "===== Risk Controls (Guardrails) ====="
input bool   UseGuardrails          = true;
input double MaxDailyLossPercent    = 5.0;
input double MaxDailyProfitPercent  = 8.0;

input int    MaxHoldSeconds         = 1800;
input double QuickExitPips          = 10.0;
input bool   ForceQuickExit         = false;
input int    MaxHoldSecondsLoss     = 600;

input bool   UseTrendReversalProtection = true;
input int    TrendReversalMinHoldSec    = 5;

input group "===== Lot Growth Settings ====="
input double ProfitStepForLotIncrease = 20.0;
input double LotIncrementPerStep      = 0.01;

input group "===== Pending Order Grid ====="
input bool UsePendingOrders             = true;
input double LimitOffsetPips            = 1.2;
input double LimitGridSpacingPips       = 2.0;
input int    PendingLimitOrdersPerSide  = 5;

input double StopOffsetPips             = 0.0;
input double StopGridSpacingPips        = 0.0;
input int    PendingStopOrdersPerSide   = 0;

input int    PendingOrderLifetimeMinutes= 1;
input int    ActiveReplenishThreshold   = 3;

input bool   ForceTPOnPendingOrders     = true;
input double PendingOrderTPPips         = 5.0;

input group "===== Market Execution ====="
input bool UseMarketBursts      = true;
input int  MarketBurstSize      = 2;
input double MarketEntryScoreThreshold = 3.5;
input int MarketBurstCooldownSec= 45;

// ------------------------------------------------------------
// DATA STRUCTURES
// ------------------------------------------------------------

struct QuickTrade
{
   int ticket;
   double entryPrice;
   datetime openTime;
   int direction;
   ulong openTickTime;
   bool trailingArmed;
   double highWatermark;
   double lowWatermark;
};

struct PendingOrderInfo
{
   int ticket;
   int type;
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

int effectiveMaxTrades        = 12;
double effectiveLotScale      = 1.0;
int effectiveBurstSize        = 5;
int effectivePendingLimitsSide= 5;
int effectivePendingStopsSide = 0;
int effectiveMarketBurstSize  = 2;

bool guardrailActive          = false;
double guardrailPnlPercent    = 0.0;

datetime lastMarketBurstTime  = 0;
int lastBuyScore              = 0;
int lastSellScore             = 0;

// ------------------------------------------------------------
// INITIALIZATION
// ------------------------------------------------------------

int OnInit()
{
   Print("========================================");
   Print("QuickScalperPro EA v5.00 Initialized");
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

   // Init active trade memory
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

   // Init pending memory
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

   exposureScale = 1.0;

   effectiveMaxTrades        = MaxTrades;
   effectiveLotScale         = 1.0;
   effectiveBurstSize        = TradesPerBurst;
   effectivePendingLimitsSide= PendingLimitOrdersPerSide;
   effectivePendingStopsSide = PendingStopOrdersPerSide;
   effectiveMarketBurstSize  = MarketBurstSize;

   lastGovernorRefresh = 0;
   lastMarketBurstTime = 0;

   UpdateExposureGovernor();

   double minStopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL);

   Print("Initialization successful!");
   Print("========================================");
   Print("ADAPTIVE PROFIT ENGINE ACTIVE");

   double initTarget = GetEquityTargetPercent();
   Print("Equity Target: ", DoubleToString(initTarget, 2), "%");

   return(INIT_SUCCEEDED);
}

void OnTick()
{
   CheckDailyReset();

   bool preflightOk = PreFlightChecks();
   bool allowNewTrades = preflightOk && tradingAllowed && !guardrailActive;

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
         AttemptMarketEntries();
      else
         LookForScalpingOpportunity();
   }

   UpdateDisplay();
}

// ------------------------------------------------------------
// DYNAMIC LOT SIZE CALCULATION
// ------------------------------------------------------------

double CalculateDynamicLotSize()
{
   double currentBalance = AccountBalance();
   double baseLot = MinLotSize * effectiveLotScale;

   if(currentBalance >= AccountBalance_10K)
      baseLot = MathMax(baseLot, 0.10);
   else if(currentBalance >= AccountBalance_1500)
      baseLot = MathMax(baseLot, 0.08);
   else if(currentBalance >= AccountBalance_100)
      baseLot = MathMax(baseLot, 0.05);

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

// ------------------------------------------------------------
// TICK TRACKING
// ------------------------------------------------------------

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

// ------------------------------------------------------------
// SCALPING SIGNAL ENGINE
// ------------------------------------------------------------

void LookForScalpingOpportunity()
{
   if(dailyTradeCount >= MaxDailyTrades)
      return;

   int signal = GetScalpingSignal();
   if(signal != OP_BUY && signal != OP_SELL)
      return;

   int burstSize = (int)MathMax(1, MathRound(effectiveBurstSize));

   for(int burst = 0; burst < burstSize; burst++)
   {
      if(totalActiveTrades >= effectiveMaxTrades || dailyTradeCount >= MaxDailyTrades)
         break;

      if(signal == OP_BUY) 
         OpenScalpTrade(OP_BUY);
      else 
         OpenScalpTrade(OP_SELL);

      if(burst < burstSize - 1 && BurstDelayMS > 0)
         Sleep(BurstDelayMS);
   }
}

int GetScalpingSignal()
{
   double currentSpread = (Ask - Bid) / Point / 10.0;
   if(currentSpread > MaxSpreadPips)
      return -1;

   // Forced direction logic
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
   double rsi      = iRSI(Symbol(), PERIOD_M1, MomentumPeriod, PRICE_CLOSE, 0);

   double currentPrice = (Ask + Bid) / 2.0;
   double previousClose = iClose(Symbol(), PERIOD_M1, 1);
   double currentClose = iClose(Symbol(), PERIOD_M1, 0);

   bool uptrend     = ema_fast > ema_slow;
   bool downtrend   = ema_fast < ema_slow;
   bool priceAbove  = currentPrice > ema_fast;
   bool priceBelow  = currentPrice < ema_fast;
   bool risingPrice = currentClose > previousClose;
   bool fallingPrice= currentClose < previousClose;

   bool oversold     = rsi < (50 - MinMomentumStrength);
   bool overbought   = rsi > (50 + MinMomentumStrength);
   bool bullMomentum = (rsi > 50 && rsi < 70);
   bool bearMomentum = (rsi < 50 && rsi > 30);

   int buyScore = 0, sellScore = 0;

   if(uptrend) buyScore++;
   if(priceAbove) buyScore++;
   if(bullMomentum || oversold) buyScore++;
   if(risingPrice) buyScore++;

   if(downtrend) sellScore++;
   if(priceBelow) sellScore++;
   if(bearMomentum || overbought) sellScore++;
   if(fallingPrice) sellScore++;

   bool buySignal, sellSignal;

   if(OnlyTrendTrades)
   {
      buySignal  = (buyScore >= 2);
      sellSignal = (sellScore >= 2);
   }
   else
   {
      buySignal  = (buyScore >= 1);
      sellSignal = (sellScore >= 1);
   }

   // Consecutive loss recovery logic
   if(consecutiveLosses >= MaxConsecutiveLosses)
   {
      if(UsePatternRecovery)
      {
         int forcedBias = (lastTradeDirection == OP_BUY) ? OP_SELL : OP_BUY;
         if(forcedBias != -1)
            StartForcedSequence(forcedBias, (forcedBias == OP_BUY ? RecoveryBuyBurst : RecoverySellBurst), "max-loss recovery");
      }

      if(buyScore >= 2) return OP_BUY;
      if(sellScore >= 2) return OP_SELL;
      return -1;
   }

   if(buySignal && sellSignal)
   {
      if(buyScore > sellScore) return OP_BUY;
      if(sellScore > buyScore) return OP_SELL;
      return -1;
   }

   if(buySignal) return OP_BUY;
   if(sellSignal) return OP_SELL;

   return -1;
}
void StartForcedSequence(int direction, int bursts, string context)
{
   if(!UsePatternRecovery) return;
   if(direction != OP_BUY && direction != OP_SELL) return;

   forcedDirection       = direction;
   forcedBurstsRemaining = MathMax(bursts, 0);
   forcedBurstOverride   = false;

   Print("Pattern recovery trigger (", context, "): forcing ",
         (direction == OP_BUY ? "BUY" : "SELL"),
         " for next ", forcedBurstsRemaining, " burst(s).");
}

void CompleteForcedBurst(bool executed)
{
   if(!executed) return;

   if(forcedDirection == -1)
   {
      forcedBurstsRemaining = 0;
      forcedBurstOverride   = false;
      return;
   }

   if(forcedBurstsRemaining > 0)
   {
      forcedBurstsRemaining--;

      if(forcedBurstsRemaining <= 0)
      {
         forcedDirection       = -1;
         forcedBurstsRemaining = 0;
         forcedBurstOverride   = false;

         Print("Pattern recovery burst completed.");
      }
   }
}

// ------------------------------------------------------------
// OPEN TRADE
// ------------------------------------------------------------

int OpenScalpTrade(int orderType)
{
   double price = (orderType == OP_BUY ? Ask : Bid);
   double lotSize = CalculateDynamicLotSize();

   double sl = 0;
   double tp = 0;

   double pipToPoint = Point * 10.0;

   if(!IsSpreadAcceptable())
   {
      Print("Trade blocked - Spread too high: ",
            DoubleToString((Ask - Bid) / Point / 10.0, 1));
      return 0;
   }

   // Stop loss
   if(StopLossPips > 0.0)
   {
      double slDist = StopLossPips * pipToPoint;
      sl = (orderType == OP_BUY)
           ? NormalizeDouble(price - slDist, Digits)
           : NormalizeDouble(price + slDist, Digits);
   }

   // Take profit
   if(UseTakeProfitPips && TakeProfitPips > 0.0)
   {
      double tpDist = TakeProfitPips * pipToPoint;
      tp = (orderType == OP_BUY)
           ? NormalizeDouble(price + tpDist, Digits)
           : NormalizeDouble(price - tpDist, Digits);
   }

   string comment = "ScalpProV5 "
                    + (orderType == OP_BUY ? "BUY" : "SELL")
                    + " Lot:" + DoubleToString(lotSize, 2);

   color arrowColor = (orderType == OP_BUY) ? clrGreen : clrRed;

   int ticket = OrderSend(Symbol(), orderType, lotSize, price, 3,
                          sl, tp, comment, MagicNumber, 0, arrowColor);

   if(ticket <= 0)
   {
      Print("Error opening trade: ", GetLastError());
      return 0;
   }

   dailyTradeCount++;
   lastTradeTime = TimeCurrent();

   if(lastTradeDirection == orderType)
      consecutiveTradeCount++;
   else
   {
      lastTradeDirection = orderType;
      consecutiveTradeCount = 1;
   }

   // Register trade in active memory
   if(totalActiveTrades < MAX_ACTIVE_TRADES)
   {
      activeTrades[totalActiveTrades].ticket       = ticket;
      activeTrades[totalActiveTrades].entryPrice   = price;
      activeTrades[totalActiveTrades].openTime     = TimeCurrent();
      activeTrades[totalActiveTrades].direction    = orderType;
      activeTrades[totalActiveTrades].openTickTime = GetTickCount();
      activeTrades[totalActiveTrades].trailingArmed= false;
      activeTrades[totalActiveTrades].highWatermark= price;
      activeTrades[totalActiveTrades].lowWatermark = price;

      totalActiveTrades++;
   }

   Print("Basket trade #", dailyTradeCount, " opened: ",
         comment, " | Ticket: ", ticket,
         " | Price: ", DoubleToString(price, Digits),
         " | Lot: ", DoubleToString(lotSize, 2),
         " | Basket: ", totalActiveTrades, "/", effectiveMaxTrades);

   CompleteForcedBurst(true);
   return ticket;
}

// ------------------------------------------------------------
// PIP VALUE CALCULATION
// ------------------------------------------------------------

double GetPipValuePerLot()
{
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
   double pipSize   = Point * 10.0;

   if(tickSize <= 0 || pipSize <= 0)
      return 0.0;

   return (tickValue / tickSize) * pipSize;
}

// ------------------------------------------------------------
// EQUITY TARGET CALCULATION
// ------------------------------------------------------------

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
   double price = (type == OP_BUY ? Bid : Ask);
   double entry = activeTrades[index].entryPrice;

   if(pipToPoint <= 0.0) return;

   double startDistance = TrailingStartPips * pipToPoint;
   double stepDistance  = TrailingStepPips  * pipToPoint;

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

// ------------------------------------------------------------
// MODIFY STOPLOSS
// ------------------------------------------------------------

bool ModifyOrderStop(int ticket, double newStop)
{
   if(newStop <= 0.0)
      return false;

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return false;

   if(OrderCloseTime() > 0)
      return false;

   double price = OrderOpenPrice();
   double tp    = OrderTakeProfit();

   if(!OrderModify(ticket, price, newStop, tp, OrderExpiration()))
   {
      Print("OrderModify failed. Ticket=", ticket,
            " Error=", GetLastError());
      return false;
   }

   return true;
}

// ------------------------------------------------------------
// MARGIN & DRAWDOWN
// ------------------------------------------------------------

double GetFreeMarginPercent()
{
   double freeMargin = AccountFreeMargin();
   double equity     = AccountEquity();

   if(equity <= 0.0) return 0.0;

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

// ------------------------------------------------------------
// EXPOSURE GOVERNOR
// ------------------------------------------------------------

void UpdateExposureGovernor()
{
   if(!UseExposureGovernor)
   {
      exposureScale             = 1.0;
      effectiveMaxTrades        = MaxTrades;
      effectiveLotScale         = 1.0;
      effectiveBurstSize        = TradesPerBurst;
      effectivePendingLimitsSide= PendingLimitOrdersPerSide;
      effectivePendingStopsSide = PendingStopOrdersPerSide;
      effectiveMarketBurstSize  = MarketBurstSize;
      return;
   }

   datetime nowTime = TimeCurrent();

   if(GovernorRefreshSeconds > 0 &&
      lastGovernorRefresh > 0 &&
      (nowTime - lastGovernorRefresh) < GovernorRefreshSeconds)
      return;

   lastGovernorRefresh = nowTime;

   double freeMarginPct = GetFreeMarginPercent();
   double ddPct         = GetEquityDrawdownPercent();

   // Margin scaling
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

   effectiveLotScale          = MathMax(MinLotScaleFactor, exposureScale);
   effectiveLotScale          = MathMin(1.0, effectiveLotScale);

   effectiveBurstSize         = (int)MathMax(1, MathRound(TradesPerBurst * exposureScale));
   effectiveMaxTrades         = (int)MathMax(1, MathRound(MaxTrades * exposureScale));
   effectivePendingLimitsSide = PendingLimitOrdersPerSide;
   effectivePendingStopsSide  = PendingStopOrdersPerSide;
   effectiveMarketBurstSize   = MarketBurstSize;
}
void CheckGuardrails()
{
   if(!UseGuardrails)
      return;

   double equity   = AccountEquity();
   double balance  = AccountBalance();
   if(balance <= 0.0)
      return;

   double pnlPercent = ((equity - balance) / balance) * 100.0;

   guardrailActive = false;
   guardrailPnlPercent = pnlPercent;

   if(pnlPercent <= -MaxDailyLossPercent)
   {
      Print("Guardrail activated: daily loss limit reached: ",
            pnlPercent, "% <= -", MaxDailyLossPercent, "%");
      guardrailActive = true;
   }
   else if(pnlPercent >= MaxDailyProfitPercent)
   {
      Print("Guardrail activated: daily profit limit reached: ",
            pnlPercent, "% >= ", MaxDailyProfitPercent, "%");
      guardrailActive = true;
   }

   if(guardrailActive)
      CloseAllTradesAndOrders();
}

// ------------------------------------------------------------
// PRE-FLIGHT CHECKS
// ------------------------------------------------------------

bool PreFlightChecks()
{
   double currentSpread = (Ask - Bid) / Point / 10.0;

   if(currentSpread > MaxSpreadPips)
   {
      Print("Spread too high. Blocked: ", currentSpread, " pips");
      return false;
   }

   if(!TradeEnabled)
      return false;

   if(guardrailActive)
      return false;

   if(dailyTradeCount >= MaxDailyTrades)
      return false;

   return true;
}

// ------------------------------------------------------------
// MANAGE ACTIVE TRADES
// ------------------------------------------------------------

void ManageActiveTrades()
{
   double pipToPoint = Point * 10.0;
   if(pipToPoint <= 0.0) return;

   bool anyCloseTriggered = false;

   for(int i = totalActiveTrades - 1; i >= 0; i--)
   {
      int ticket = activeTrades[i].ticket;
      if(ticket <= 0) continue;

      if(!OrderSelect(ticket, SELECT_BY_TICKET))
         continue;

      if(OrderCloseTime() > 0)
      {
         RemoveActiveTrade(i);
         continue;
      }

      double profit = OrderProfit() + OrderSwap() + OrderCommission();

      // Time-based exit
      if(ForceQuickExit)
      {
         if(CheckQuickExit(i))
         {
            CloseTrade(ticket, profit);
            anyCloseTriggered = true;
            continue;
         }
      }

      // Instant profit exit
      if(UseInstantProfitExit && InstantProfitPips > 0.0)
      {
         if(CheckInstantProfitExit(i, pipToPoint))
         {
            CloseTrade(ticket, profit);
            anyCloseTriggered = true;
            continue;
         }
      }

      // Time-based loss exit
      if(MaxHoldSecondsLoss > 0)
      {
         datetime now = TimeCurrent();
         if((now - OrderOpenTime()) >= MaxHoldSecondsLoss && profit < 0.0)
         {
            CloseTrade(ticket, profit);
            anyCloseTriggered = true;
            continue;
         }
      }

      // Time-based forced exit
      if(MaxHoldSeconds > 0)
      {
         datetime now = TimeCurrent();
         if((now - OrderOpenTime()) >= MaxHoldSeconds && profit > 0.0)
         {
            CloseTrade(ticket, profit);
            anyCloseTriggered = true;
            continue;
         }
      }

      // Per-trade profit lock
      if(PerTradeProfitLock > 0.0)
      {
         if(profit >= PerTradeProfitLock)
         {
            CloseTrade(ticket, profit);
            anyCloseTriggered = true;
            continue;
         }
      }

      // Equity target exit
      if(CheckEquityTargetExit())
      {
         CloseTrade(ticket, profit);
         anyCloseTriggered = true;
         continue;
      }

      // Trailing stop
      UpdatePerTradeTrailing(i, pipToPoint);
   }

   if(anyCloseTriggered)
      CleanupClosedTrades();
}

// ------------------------------------------------------------
// CHECK: INSTANT PROFIT EXIT
// ------------------------------------------------------------

bool CheckInstantProfitExit(int index, double pipToPoint)
{
   if(index < 0 || index >= totalActiveTrades)
      return false;

   int ticket = activeTrades[index].ticket;
   if(ticket <= 0) return false;

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return false;

   int type = OrderType();
   double entry = OrderOpenPrice();
   double price = (type == OP_BUY ? Bid : Ask);

   double profitMove = MathAbs(price - entry);
   double requiredMove = InstantProfitPips * pipToPoint;

   if(profitMove >= requiredMove)
      return true;

   return false;
}

// ------------------------------------------------------------
// CHECK: QUICK EXIT AFTER X SECONDS
// ------------------------------------------------------------

bool CheckQuickExit(int index)
{
   if(index < 0 || index >= totalActiveTrades)
      return false;

   if(QuickExitSeconds <= 0)
      return false;

   int ticket = activeTrades[index].ticket;
   if(ticket <= 0) return false;

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return false;

   datetime now = TimeCurrent();
   datetime openTime = OrderOpenTime();

   if((now - openTime) >= QuickExitSeconds)
      return true;

   return false;
}

// ------------------------------------------------------------
// CHECK EQUITY TARGET EXIT
// ------------------------------------------------------------

bool CheckEquityTargetExit()
{
   if(!ExitOnAnyProfit && !UseRiskRewardTarget && !UseCustomEquityTarget)
      return false;

   double equity = AccountEquity();
   double balance = AccountBalance();
   double diff = (equity - balance);

   if(ExitOnAnyProfit && diff > 0.0)
      return true;

   if(UseRiskRewardTarget && RiskRewardMultiplier > 0.0)
   {
      double dd = initialAccountBalance - equity;
      if(dd <= 0) dd = 0;
      double allowedProfitTarget = dd * RiskRewardMultiplier;

      if(diff >= allowedProfitTarget)
         return true;
   }

   if((UseCustomEquityTarget || EquityTargetPreset > 0))
   {
      double percentTarget = GetEquityTargetPercent();
      double targetEquity = balance * (1.0 + percentTarget / 100.0);

      if(equity >= targetEquity)
         return true;
   }

   return false;
}
void RemoveActiveTrade(int index)
{
   if(index < 0 || index >= totalActiveTrades)
      return;

   for(int i = index; i < totalActiveTrades - 1; i++)
   {
      activeTrades[i] = activeTrades[i + 1];
   }

   totalActiveTrades--;
}

// ------------------------------------------------------------
// CLOSE TRADE
// ------------------------------------------------------------

bool CloseTrade(int ticket, double profit)
{
   if(ticket <= 0)
      return false;

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return false;

   int type = OrderType();
   double closePrice = (type == OP_BUY ? Bid : Ask);

   bool success = OrderClose(ticket, OrderLots(), closePrice, 3, clrAqua);

   if(success)
   {
      lastTradePL = profit;
      if(profit < 0)
         consecutiveLosses++;
      else
         consecutiveLosses = 0;
   }

   return success;
}

// ------------------------------------------------------------
// CLEANUP CLOSED TRADES
// ------------------------------------------------------------

void CleanupClosedTrades()
{
   for(int i = totalActiveTrades - 1; i >= 0; i--)
   {
      int ticket = activeTrades[i].ticket;
      if(ticket <= 0) continue;

      if(!OrderSelect(ticket, SELECT_BY_TICKET))
         continue;

      if(OrderCloseTime() > 0)
         RemoveActiveTrade(i);
   }
}

// ------------------------------------------------------------
// PENDING ORDER MAINTENANCE
// ------------------------------------------------------------

void MaintainPendingOrders()
{
   CleanupExpiredPendingOrders();

   int currentPendingCount = CountPendingOrders();
   if(currentPendingCount <= 0 ||
      currentPendingCount < ActiveReplenishThreshold)
      PlacePendingOrderBatch();
}

// ------------------------------------------------------------
// CLEANUP EXPIRED PENDING ORDERS
// ------------------------------------------------------------

void CleanupExpiredPendingOrders()
{
   datetime now = TimeCurrent();
   int expireSec = PendingOrderLifetimeMinutes * 60;

   for(int i = totalPendingOrders - 1; i >= 0; i--)
   {
      int ticket = pendingOrders[i].ticket;
      if(ticket <= 0)
         continue;

      if(!OrderSelect(ticket, SELECT_BY_TICKET))
         continue;

      int type = OrderType();
      if(type == OP_BUY || type == OP_SELL)
         continue;

      datetime placedAt = pendingOrders[i].placed;
      if((now - placedAt) >= expireSec)
      {
         if(!OrderDelete(ticket))
            Print("Error deleting expired pending order #", ticket, " ERR=", GetLastError());
         RemovePendingOrder(i);
      }
   }
}

// ------------------------------------------------------------
// REMOVE PENDING ORDER
// ------------------------------------------------------------

void RemovePendingOrder(int index)
{
   if(index < 0 || index >= totalPendingOrders)
      return;

   for(int i = index; i < totalPendingOrders - 1; i++)
      pendingOrders[i] = pendingOrders[i + 1];

   totalPendingOrders--;
}

// ------------------------------------------------------------
// COUNT PENDING ORDERS
// ------------------------------------------------------------

int CountPendingOrders()
{
   int count = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(OrderSelect(i, SELECT_BY_POS))
      {
         int type = OrderType();
         if(type == OP_BUYLIMIT || type == OP_SELLLIMIT ||
            type == OP_BUYSTOP  || type == OP_SELLSTOP)
         {
            count++;
         }
      }
   }
   return count;
}

// ------------------------------------------------------------
// PLACE PENDING ORDER BATCH
// ------------------------------------------------------------

void PlacePendingOrderBatch()
{
   datetime now = TimeCurrent();
   if(lastPendingBatchTime > 0 &&
      (now - lastPendingBatchTime) < 1)
      return;

   lastPendingBatchTime = now;

   PlaceLimitOrdersBatch();
   PlaceStopOrdersBatch();
}

void PlaceLimitOrdersBatch()
{
   if(!UsePendingOrders || LimitOffsetPips <= 0.0 ||
      LimitGridSpacingPips <= 0.0 ||
      effectivePendingLimitsSide <= 0)
      return;

   double pipToPoint = Point * 10.0;

   for(int side = 0; side < 2; side++)
   {
      int orderType = (side == 0 ? OP_BUYLIMIT : OP_SELLLIMIT);
      double basePrice = (side == 0 ? Bid : Ask);

      for(int i = 0; i < effectivePendingLimitsSide; i++)
      {
         double offset = LimitOffsetPips * pipToPoint +
                         (i * LimitGridSpacingPips * pipToPoint);

         double price = (orderType == OP_BUYLIMIT)
                        ? NormalizeDouble(basePrice - offset, Digits)
                        : NormalizeDouble(basePrice + offset, Digits);

         double lot = CalculateDynamicLotSize();
         double sl = 0, tp = 0;

         if(ForceTPOnPendingOrders && PendingOrderTPPips > 0.0)
         {
            double tpDist = PendingOrderTPPips * pipToPoint;
            tp = (orderType == OP_BUYLIMIT)
                 ? NormalizeDouble(price + tpDist, Digits)
                 : NormalizeDouble(price - tpDist, Digits);
         }

         string comment = "LimitGridV5 L" + IntegerToString(i+1);
         int ticket = OrderSend(Symbol(), orderType, lot, price, 3, sl, tp,
                                comment, MagicNumber, 0, clrBlue);

         if(ticket > 0 && totalPendingOrders < MAX_PENDING_ORDERS)
         {
            pendingOrders[totalPendingOrders].ticket = ticket;
            pendingOrders[totalPendingOrders].type   = orderType;
            pendingOrders[totalPendingOrders].placed = TimeCurrent();

            totalPendingOrders++;
         }
      }
   }
}
void PlaceStopOrdersBatch()
{
   if(!UsePendingOrders || StopOffsetPips <= 0.0 ||
      StopGridSpacingPips <= 0.0 ||
      effectivePendingStopsSide <= 0)
      return;

   double pipToPoint = Point * 10.0;

   for(int side = 0; side < 2; side++)
   {
      int orderType = (side == 0 ? OP_BUYSTOP : OP_SELLSTOP);
      double basePrice = (side == 0 ? Ask : Bid);

      for(int i = 0; i < effectivePendingStopsSide; i++)
      {
         double offset = StopOffsetPips * pipToPoint +
                         (i * StopGridSpacingPips * pipToPoint);

         double price = (orderType == OP_BUYSTOP)
                        ? NormalizeDouble(basePrice + offset, Digits)
                        : NormalizeDouble(basePrice - offset, Digits);

         double lot = CalculateDynamicLotSize();
         double sl = 0, tp = 0;

         if(ForceTPOnPendingOrders && PendingOrderTPPips > 0.0)
         {
            double tpDist = PendingOrderTPPips * pipToPoint;
            tp = (orderType == OP_BUYSTOP)
                 ? NormalizeDouble(price + tpDist, Digits)
                 : NormalizeDouble(price - tpDist, Digits);
         }

         string comment = "StopGridV5 S" + IntegerToString(i+1);

         int ticket = OrderSend(Symbol(), orderType, lot, price, 3, sl, tp,
                                comment, MagicNumber, 0, clrBlue);

         if(ticket > 0 && totalPendingOrders < MAX_PENDING_ORDERS)
         {
            pendingOrders[totalPendingOrders].ticket = ticket;
            pendingOrders[totalPendingOrders].type   = orderType;
            pendingOrders[totalPendingOrders].placed = TimeCurrent();

            totalPendingOrders++;
         }
      }
   }
}

// ------------------------------------------------------------
// MARKET BURST ENTRY ENGINE
// ------------------------------------------------------------

void AttemptMarketEntries()
{
   if(guardrailActive)
      return;

   datetime now = TimeCurrent();

   if(lastMarketBurstTime > 0 &&
      (now - lastMarketBurstTime) < MarketBurstCooldownSec)
      return;

   int signal = GetMarketBurstSignal();
   if(signal != OP_BUY && signal != OP_SELL)
      return;

   int burstSize = MathMax(1, effectiveMarketBurstSize);

   for(int i = 0; i < burstSize; i++)
   {
      if(totalActiveTrades >= effectiveMaxTrades)
         break;

      OpenScalpTrade(signal);

      if(i < burstSize - 1 && BurstDelayMS > 0)
         Sleep(BurstDelayMS);
   }

   lastMarketBurstTime = now;
}

int GetMarketBurstSignal()
{
   double ema_fast = iMA(Symbol(), PERIOD_M1, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema_slow = iMA(Symbol(), PERIOD_M1, TrendPeriod * 2, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi      = iRSI(Symbol(), PERIOD_M1, MomentumPeriod, PRICE_CLOSE, 0);

   double price = (Ask + Bid) / 2.0;

   bool uptrend      = ema_fast > ema_slow;
   bool downtrend    = ema_fast < ema_slow;

   bool bullish      = price > ema_fast && rsi > 50;
   bool bearish      = price < ema_slow && rsi < 50;

   int buyScore = 0;
   int sellScore = 0;

   if(uptrend) buyScore++;
   if(bullish) buyScore++;
   if(rsi > 55) buyScore++;

   if(downtrend) sellScore++;
   if(bearish) sellScore++;
   if(rsi < 45) sellScore++;

   int threshold = (int)MarketEntryScoreThreshold;

   lastBuyScore = buyScore;
   lastSellScore = sellScore;

   if(buyScore >= threshold)  return OP_BUY;
   if(sellScore >= threshold) return OP_SELL;

   return -1;
}

// ------------------------------------------------------------
// CLOSE ALL TRADES & ORDERS
// ------------------------------------------------------------

void CloseAllTradesAndOrders()
{
   // Close all open trades
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS))
         continue;

      if(OrderMagicNumber() != MagicNumber)
         continue;

      int type = OrderType();
      int ticket = OrderTicket();
      double price = (type == OP_BUY ? Bid : Ask);

      if(type == OP_BUY || type == OP_SELL)
      {
         if(!OrderClose(ticket, OrderLots(), price, 3, clrRed))
            Print("Error closing order #", ticket, " ERR=", GetLastError());
      }
   }

   // Delete all pending orders
   CancelAllPendingOrders();
}

void CheckDailyReset()
{
   datetime now = TimeCurrent();
   datetime today = DateOfDay(now);

   if(today != lastDayReset)
   {
      lastDayReset = today;
      dailyTradeCount = 0;
      dailyProfit = 0;
      consecutiveLosses = 0;
      consecutiveBuyLosses = 0;
      consecutiveSellLosses = 0;

      guardrailActive = false;
      guardrailPnlPercent = 0.0;

      Print("===== Daily Reset Activated =====");
   }
}

datetime DateOfDay(datetime t)
{
   return t - (t % 86400);
}

// ------------------------------------------------------------
// DISPLAY PANEL
// ------------------------------------------------------------

void UpdateDisplay()
{
   static datetime lastUpdate = 0;
   datetime now = TimeCurrent();

   if(now == lastUpdate)
      return;

   lastUpdate = now;

   Comment(
      "QuickScalperPro v5.00", "\n",
      "==============================", "\n",
      "Balance: ", DoubleToString(AccountBalance(), 2), "\n",
      "Equity:  ", DoubleToString(AccountEquity(), 2), "\n",
      "FreeMargin: ", DoubleToString(AccountFreeMargin(), 2), "\n",
      "Daily Profit: ", DoubleToString(dailyProfit, 2), "\n",
      "Active Trades: ", totalActiveTrades, "/", effectiveMaxTrades, "\n",
      "Pending Orders: ", totalPendingOrders, "\n",
      "Consecutive Losses: ", consecutiveLosses, "\n",
      "Guardrail Active: ", (guardrailActive ? "YES" : "NO"), "\n",
      "ExposureScale: ", DoubleToString(exposureScale, 2), "\n",
      "Market Burst Cooldown(sec): ", MarketBurstCooldownSec, "\n",
      "BuyScore/SellScore: ", lastBuyScore, "/", lastSellScore, "\n"
   );
}

// ------------------------------------------------------------
// HANDLE CLOSED TRADES: UPDATE DAILY PROFIT, LOSS STREAKS
// ------------------------------------------------------------

void RecordClosedTrade(int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return;

   double profit = OrderProfit() + OrderSwap() + OrderCommission();
   dailyProfit += profit;

   int type = OrderType();
   if(profit < 0)
   {
      if(type == OP_BUY)
         consecutiveBuyLosses++;
      if(type == OP_SELL)
         consecutiveSellLosses++;
   }
   else
   {
      if(type == OP_BUY)
         consecutiveBuyLosses = 0;
      if(type == OP_SELL)
         consecutiveSellLosses = 0;
   }
}

// ------------------------------------------------------------
// ORDER CLOSED EVENT EMULATION
// ------------------------------------------------------------

void CleanupTradeStateOnClose()
{
   for(int pos = OrdersHistoryTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_HISTORY))
         continue;

      int ticket = OrderTicket();

      RecordClosedTrade(ticket);
   }
}

// ------------------------------------------------------------
// UTILITY FUNCTIONS
// ------------------------------------------------------------

double NormalizeDoubleSafe(double val)
{
   if(Digits == 3 || Digits == 5)
      return NormalizeDouble(val, 5);
   return NormalizeDouble(val, 4);
}

int GetTickCountSafe()
{
   return (int)GetTickCount();
}

double GetBidSafe() { return Bid; }
double GetAskSafe() { return Ask; }

bool IsTradeType(int type)
{
   return (type == OP_BUY || type == OP_SELL);
}

bool IsPendingType(int type)
{
   return (type == OP_BUYLIMIT || type == OP_SELLLIMIT ||
           type == OP_BUYSTOP  || type == OP_SELLSTOP);
}

int GetOrderCountByMagic(int magic, bool includePendings)
{
   int count = 0;

   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS))
         continue;

      if(OrderMagicNumber() != magic)
         continue;

      int type = OrderType();

      if(IsTradeType(type))
         count++;
      else if(includePendings && IsPendingType(type))
         count++;
   }

   return count;
}

// ------------------------------------------------------------
// CHECK: TREND REVERSAL PROTECTION
// ------------------------------------------------------------

bool IsTrendReversing()
{
   if(!UseTrendReversalProtection)
      return false;

   double ema_fast = iMA(Symbol(), PERIOD_M1, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema_slow = iMA(Symbol(), PERIOD_M1, TrendPeriod * 2, 0, MODE_EMA, PRICE_CLOSE, 0);

   return ema_fast < ema_slow;
}
/*  
===============================================================
 FINAL EXIT LOGIC + END OF FILE  
===============================================================
*/

void FinalizeTradeHandling()
{
   // Ensure all closed trades are accounted for
   CleanupTradeStateOnClose();

   // Re-evaluate guardrails after all adjustments
   CheckGuardrails();
}

// ------------------------------------------------------------
// MASTER EXIT FUNCTION FOR ALL TRADES
// ------------------------------------------------------------

void CloseAllTrades(string reason)
{
   Print("==== Closing ALL trades: ", reason, " ====");

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS))
         continue;

      if(OrderMagicNumber() != MagicNumber)
         continue;

      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;

      double price = (type == OP_BUY ? Bid : Ask);
      double volume = OrderLots();

      RefreshRates();

      bool closed = OrderClose(OrderTicket(), volume, price, 3, clrYellow);

      if(closed)
         Print("Closed ticket ", OrderTicket(), " because: ", reason);
      else
         Print("FAILED closing ticket ", OrderTicket(), " ERR=", GetLastError());
   }
}

// ------------------------------------------------------------
// SAFETY — DELETE ALL PENDING ORDERS
// ------------------------------------------------------------

void CancelAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS))
         continue;

      if(OrderMagicNumber() != MagicNumber)
         continue;

      int type = OrderType();
      if(!IsPendingType(type))
         continue;

      int ticket = OrderTicket();

      if(!OrderDelete(ticket))
         Print("Error deleting pending #", ticket, " ERR=", GetLastError());
      else
         Print("Deleted pending order #", ticket);
   }
}

// ------------------------------------------------------------
// EA STOP EVENT
// ------------------------------------------------------------

void OnDeinit(const int reason)
{
   Print("QuickScalperPro v5.00 is shutting down. Reason: ", reason);

   // Clean up comment panel
   Comment("");

   // Optional: clear pendings on deinit
   CancelAllPendingOrders();
}

/*
===============================================================
  END OF QuickScalperPro v5.00
===============================================================
*/
