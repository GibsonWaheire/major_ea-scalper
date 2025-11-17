

#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "3.00"
#property strict

#define FIXED_STOP_LOSS_PIPS 50.0
#define FORCED_TAKE_PROFIT_PIPS 5.0
#define MAX_ACTIVE_TRADES 200
#define MAX_PENDING_ORDERS 400

input group "===== Dynamic Lot Sizing ====="
input double   AccountBalance_10K  = 1000000.0;
input double   AccountBalance_100  = 100000.0;
input double   AccountBalance_1500 = 500000.0;
input double   MinLotSize          = 0.01;
input double   MaxLotSize          = 0.05;

input group "===== Core Trading Settings ====="
input int      MagicNumber         = 202503;
input int      MaxTrades           = 20;
input int      TradesPerBurst      = 3;
input int      BurstDelayMS        = 100;

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
input double   PeakGivebackPercent = 20.0;    // Allowable giveback from profit peak
input int      MinimumHoldMS       = 150;     // Prevent premature exits
input double   MaxSpreadPips       = 4.0;

input group "===== Trading Controls ====="
input bool     TradeEnabled        = true;
input int      TickDelay           = 1;
input int      MaxConsecutiveLosses= 5;
input bool     UseGoldOnly         = true;
input int      MaxDailyTrades      = 100000;

input group "===== Strategy Settings ====="
input int      TrendPeriod         = 10;
input int      MomentumPeriod      = 9;
input double   MinMomentumStrength = 20.0;
input bool     OnlyTrendTrades     = false;

input group "===== Per-Trade Exit Options ====="
input bool     UseTakeProfitPips   = true;
input double   TakeProfitPips      = 5.0;
input bool     UseTrailingStop     = true;
input double   TrailingStartPips   = 40.0;
input double   TrailingStepPips    = 20.0;
input double   PerTradeProfitLock  = 5000.0;   // Close individual positions once profit exceeds this amount

input group "===== Instant Profit Exit ====="
input bool     UseInstantProfitExit = true;
input double   InstantProfitPips    = 3.0;

input group "===== Pattern Recovery Settings ====="
input bool     UsePatternRecovery      = true;
input int      LosingSellStreakTrigger = 2;   // After this many losing sells, force buys
input int      LosingBuyStreakTrigger  = 2;   // After this many losing buys, force sells
input int      RecoveryBuyBurst        = 3;   // Number of forced BUY bursts once sell losses trigger
input int      RecoverySellBurst       = 3;   // Number of forced SELL bursts once buy losses trigger
input bool     PatternRequiresSignal   = true;// If true, only force direction when signal agrees or is absent
input bool     UseImmediateReversal    = true;// Immediately flip direction after any loss
input int      ImmediateReversalBursts = 1;   // Number of bursts to run in the opposite direction after a loss

input group "===== Pending Order Grid ====="
input double   LimitOffsetPips            = 1.2;  // Distance from trend EMA for limit orders
input double   LimitGridSpacingPips       = 2.0;
input int      PendingLimitOrdersPerSide  = 5;
input double   StopOffsetPips             = 0.0;  // Distance from trend EMA for stop orders
input double   StopGridSpacingPips        = 0.0;
input int      PendingStopOrdersPerSide   = 0;
input int      PendingOrderLifetimeMinutes= 2;
input int      ActiveReplenishThreshold   = 3;

input group "===== Market Execution ====="
input bool     UseMarketBursts            = false;
input int      MarketBurstSize            = 2;
input double   MarketEntryScoreThreshold  = 3.5;
input int      MarketBurstCooldownSec     = 45;

input group "===== Exposure Governor ====="
input bool     UseExposureGovernor        = true;
input double   MinFreeMarginPercent       = 60.0;
input double   MinEquityPercent           = 85.0;
input double   MinLotScaleFactor          = 0.10;
input double   PendingScaleMin            = 0.25;
input double   PendingScaleMax            = 1.0;
input double   BurstScaleMin              = 0.25;
input double   BurstScaleMax              = 1.0;
input int      GovernorRefreshSeconds     = 30;

input group "===== Risk Controls ====="
input bool     UseRiskBasedLots           = true;
input double   RiskPerTradePercent        = 0.30;
input double   MaxDailyLossPercent        = 5.0;
input double   MaxDailyProfitPercent      = 8.0;
input int      MaxHoldSeconds             = 180;
input double   QuickExitPips              = 3.0;

input group "===== Burst Scaling ====="
input bool     AddTradesAfterWin          = true;
input int      BonusTradesOnWin           = 1;
input bool     ScaleBurstWithBalance      = true;
input double   BalanceStepPerExtraBurst   = 1000.0;
input int      MaxBurstTrades             = 6;

input group "===== Lot Growth Settings ====="
input double   ProfitStepForLotIncrease= 20.0;     // Increase lot size every X profit
input double   LotIncrementPerStep     = 0.01;     // Additional lot size per profit step

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

QuickTrade activeTrades[MAX_ACTIVE_TRADES];
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
int lastBuyScore = 0;
int lastSellScore = 0;
bool lastTrendUp = false;
bool lastTrendDown = false;
double lastAtrPoints = 0.0;
datetime lastMarketBurstTime = 0;
double exposureScale = 1.0;
datetime lastGovernorRefresh = 0;
int effectiveMaxTrades = 200;
double effectiveLotScale = 1.0;
int effectivePendingLimitsSide = 50;
int effectivePendingStopsSide = 25;
int effectiveMarketBurstSize = 3;
bool guardrailActive = false;
double guardrailPnlPercent = 0.0;

struct PendingOrderInfo
{
   int      ticket;
   int      type;
   datetime placed;
};

PendingOrderInfo pendingOrders[MAX_PENDING_ORDERS];
int totalPendingOrders = 0;
datetime lastPendingBatchTime = 0;
int lastActiveRefreshCount = 0;

struct SignalSnapshot
{
   bool spreadOk;
   int buyScore;
   int sellScore;
   bool buySignal;
   bool sellSignal;
   bool uptrend;
   bool downtrend;
};

SignalSnapshot currentSignal = {false, 0, 0, false, false, false, false};

int OnInit()
{
   Print("========================================");
   Print("QuickScalperPro EA v3.00 Initialized");
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

   exposureScale = 1.0;
   effectiveMaxTrades = MaxTrades;
   effectiveLotScale = 1.0;
   effectivePendingLimitsSide = PendingLimitOrdersPerSide;
   effectivePendingStopsSide = PendingStopOrdersPerSide;
   effectiveMarketBurstSize = MarketBurstSize;
   lastGovernorRefresh = 0;
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
   Print("Lot Bounds: Min=", MinLotSize, " | Max=", MaxLotSize,
         " | Step Growth: +", DoubleToString(LotIncrementPerStep, 2),
         " per ", DoubleToString(ProfitStepForLotIncrease, 2), " profit");
   Print("========================================");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   CancelAllPendingOrders();
   Print("QuickScalperPro EA Deinitialized. Reason: ", reason);
}

void OnTick()
{

   CheckDailyReset();

   bool preflightOk = PreFlightChecks();
   bool allowNewTrades = preflightOk && tradingAllowed && !guardrailActive;

   TrackTickMovement();

   ManageActiveTrades();

   CleanupClosedTrades();

   MaintainPendingOrders();

   if(allowNewTrades && IsSpreadAcceptable())
   {
      AttemptMarketEntries();
   }

   UpdateDisplay();
}

double CalculateDynamicLotSize()
{
   double pipToPoint = Point * 10.0;
   if(pipToPoint <= 0.0)
      pipToPoint = Point;

   double baseLot = MinLotSize * effectiveLotScale;

   if(UseRiskBasedLots)
   {
      double pipValue = GetPipValuePerLot();
      if(pipValue > 0.0 && FIXED_STOP_LOSS_PIPS > 0.0)
      {
         double riskCurrency = AccountEquity() * (RiskPerTradePercent / 100.0);
         double riskLot = riskCurrency / (FIXED_STOP_LOSS_PIPS * pipValue);
         baseLot = MathMax(MinLotSize, riskLot);
   }
   }

   baseLot = MathMin(baseLot, MaxLotSize);
   baseLot = MathMax(baseLot, MinLotSize);

   return NormalizeDouble(baseLot, 2);
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

bool IsActiveTradeTracked(int ticket)
{
   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket == ticket)
         return true;
   }
   return false;
}

void UpdateSignalSnapshot()
{
   currentSignal.spreadOk = false;
   currentSignal.buyScore = 0;
   currentSignal.sellScore = 0;
   currentSignal.buySignal = false;
   currentSignal.sellSignal = false;
   currentSignal.uptrend = false;
   currentSignal.downtrend = false;

   double currentSpread = (Ask - Bid) / Point / 10.0;
   bool acceptableSpread = (currentSpread <= MaxSpreadPips);
   if(!acceptableSpread)
      return;

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

   int buyScore = 0;
   if(uptrend) buyScore++;
   if(priceAboveEMA) buyScore++;
   if(bullishMomentum || oversold) buyScore++;
   if(risingPrice) buyScore++;

   int sellScore = 0;
   if(downtrend) sellScore++;
   if(priceBelowEMA) sellScore++;
   if(bearishMomentum || overbought) sellScore++;
   if(fallingPrice) sellScore++;

   bool buySignal = OnlyTrendTrades ? (buyScore >= 2) : (buyScore >= 1);
   bool sellSignal = OnlyTrendTrades ? (sellScore >= 2) : (sellScore >= 1);

   currentSignal.spreadOk = true;
   currentSignal.buyScore = buyScore;
   currentSignal.sellScore = sellScore;
   currentSignal.buySignal = buySignal;
   currentSignal.sellSignal = sellSignal;
   currentSignal.uptrend = uptrend;
   currentSignal.downtrend = downtrend;

   lastBuyScore = buyScore;
   lastSellScore = sellScore;
   lastTrendUp = uptrend;
   lastTrendDown = downtrend;
}

void RegisterActiveTrade(int ticket)
{
   if(ticket <= 0)
      return;

   if(IsActiveTradeTracked(ticket))
      return;

   if(totalActiveTrades >= MAX_ACTIVE_TRADES)
   {
      Print("Active trade registry full. Unable to track ticket ", ticket);
      return;
   }

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return;

   int type = OrderType();
   if(type != OP_BUY && type != OP_SELL)
      return;

   double price = OrderOpenPrice();

   activeTrades[totalActiveTrades].ticket = ticket;
   activeTrades[totalActiveTrades].entryPrice = price;
   activeTrades[totalActiveTrades].openTime = OrderOpenTime();
   activeTrades[totalActiveTrades].direction = type;
   activeTrades[totalActiveTrades].openTickTime = GetTickCount();
   activeTrades[totalActiveTrades].trailingArmed = false;
   activeTrades[totalActiveTrades].highWatermark = price;
   activeTrades[totalActiveTrades].lowWatermark = price;
   totalActiveTrades++;
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
         RegisterActiveTrade(OrderTicket());
   }
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

double GetEquityDrawdownPercent()
{
   if(initialAccountBalance <= 0.0)
      return 0.0;

   double dd = (initialAccountBalance - AccountEquity());
   if(dd <= 0.0)
      return 0.0;

   return (dd / initialAccountBalance) * 100.0;
   }

double GetFreeMarginPercent()
{
   double freeMargin = AccountFreeMargin();
   double equity = AccountEquity();
   if(equity <= 0.0)
      return 0.0;
   return (freeMargin / equity) * 100.0;
}

void UpdateExposureGovernor()
{
   if(!UseExposureGovernor)
   {
      exposureScale = 1.0;
      effectiveMaxTrades = MaxTrades;
      effectiveLotScale = 1.0;
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
   exposureScale = MathMax(PendingScaleMin, MathMin(PendingScaleMax, exposureScale));

   effectiveLotScale = MathMax(MinLotScaleFactor, exposureScale);
   effectiveLotScale = MathMin(1.0, effectiveLotScale);

   effectivePendingLimitsSide = (int)MathMax(1, MathRound(PendingLimitOrdersPerSide * exposureScale));
   effectivePendingStopsSide  = (int)MathMax(0, MathRound(PendingStopOrdersPerSide * exposureScale));
   effectiveMarketBurstSize   = (int)MathMax(1, MathRound(MarketBurstSize * MathMax(BurstScaleMin,
                                            MathMin(BurstScaleMax, exposureScale))));

   effectiveMaxTrades = (int)MathMax(10, MathRound(MaxTrades * exposureScale));
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
      CancelAllPendingOrders();
      Print("Guardrail triggered: Daily P&L ", DoubleToString(pnlPercent, 2), "% | LossHit=",
            (lossHit ? "true" : "false"), " | ProfitHit=", (profitHit ? "true" : "false"));
   }
   else if(!shouldActivate && guardrailActive)
   {
      guardrailActive = false;
      Print("Guardrail reset - trading re-enabled.");
   }
}

bool SubmitPendingOrder(int pendingType, double price)
{
   bool isLong = (pendingType == OP_BUYLIMIT || pendingType == OP_BUYSTOP);
   bool isValidType = (pendingType == OP_BUYLIMIT || pendingType == OP_SELLLIMIT ||
                       pendingType == OP_BUYSTOP  || pendingType == OP_SELLSTOP);
   if(!isValidType)
      return false;

   RefreshRates();

   double lotSize = CalculateDynamicLotSize();
   double sl = 0;
   double tp = 0;
   double pipToPoint = Point * 10.0;
   if(pipToPoint <= 0.0)
      pipToPoint = Point;

   double stopLossPips = FIXED_STOP_LOSS_PIPS;
   if(stopLossPips > 0.0 && pipToPoint > 0.0)
   {
      double slDistance = stopLossPips * pipToPoint;
      if(isLong)
         sl = NormalizeDouble(price - slDistance, Digits);
      else
         sl = NormalizeDouble(price + slDistance, Digits);
   }

   double tpDistance = FORCED_TAKE_PROFIT_PIPS * pipToPoint;
   if(tpDistance > 0.0)
   {
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
   string comment = "ScalpPro " + side + " Lot:" + DoubleToString(lotSize, 2);
   color arrowColor = (isLong) ? clrGreen : clrRed;

   int ticket = OrderSend(Symbol(), pendingType, lotSize, price, 3, sl, tp,
                          comment, MagicNumber, 0, arrowColor);

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
            RegisterActiveTrade(ticket);
   }

      Print("Pending order placed: ", side, " ticket ", ticket,
            " price ", DoubleToString(price, Digits), " lot ", DoubleToString(lotSize, 2));
      return true;
   }

   Print("Error placing ", side, ": ", GetLastError());
   return false;
}

bool SubmitMarketOrder(int orderType)
{
   if(orderType != OP_BUY && orderType != OP_SELL)
      return false;

   RefreshRates();

   double lotSize = CalculateDynamicLotSize();
   double pipToPoint = Point * 10.0;
   if(pipToPoint <= 0.0)
      pipToPoint = Point;

   double price = (orderType == OP_BUY) ? Ask : Bid;
   double sl = 0;
   double tp = 0;

   double stopLossPips = FIXED_STOP_LOSS_PIPS;
   if(stopLossPips > 0.0 && pipToPoint > 0.0)
   {
      double slDistance = stopLossPips * pipToPoint;
      if(orderType == OP_BUY)
         sl = NormalizeDouble(price - slDistance, Digits);
      else
         sl = NormalizeDouble(price + slDistance, Digits);
   }

   double tpDistance = FORCED_TAKE_PROFIT_PIPS * pipToPoint;
   if(tpDistance > 0.0)
   {
      if(orderType == OP_BUY)
         tp = NormalizeDouble(price + tpDistance, Digits);
      else
         tp = NormalizeDouble(price - tpDistance, Digits);
   }

   string comment = "ScalpPro MARKET " + (orderType == OP_BUY ? "BUY" : "SELL") +
                    " Lot:" + DoubleToString(lotSize, 2);
   color arrowColor = (orderType == OP_BUY) ? clrLime : clrOrangeRed;

   int ticket = OrderSend(Symbol(), orderType, lotSize, price, 3, sl, tp,
                          comment, MagicNumber, 0, arrowColor);

   if(ticket > 0)
   {
      dailyTradeCount++;
      lastTradeTime = TimeCurrent();

      if(lastTradeDirection == orderType)
         consecutiveTradeCount++;
      else
      {
         consecutiveTradeCount = 1;
         lastTradeDirection = orderType;
      }

      RegisterActiveTrade(ticket);

      Print("Market order opened: ", comment, " | Ticket ", ticket,
            " | Price ", DoubleToString(price, Digits));
      return true;
   }

   Print("Error opening market order: ", GetLastError());
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
         RegisterActiveTrade(ticket);
         RemovePendingOrderAt(i);
         continue;
      }

      if(type != OP_BUYLIMIT && type != OP_SELLLIMIT && type != OP_BUYSTOP && type != OP_SELLSTOP)
      {
         RemovePendingOrderAt(i);
         continue;
      }

      if(lifetimeSeconds > 0 && (nowTime - pendingOrders[i].placed) >= lifetimeSeconds)
      {
         if(OrderDelete(ticket))
            Print("Pending order expired and cancelled ticket ", ticket);
         RemovePendingOrderAt(i);
      }
   }
}

void GeneratePendingOrderGrid()
{
   UpdateSignalSnapshot();
   RefreshRates();
   double emaTrend = iMA(Symbol(), PERIOD_M1, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double pipToPoint = Point * 10.0;
   if(pipToPoint <= 0.0)
      pipToPoint = Point;

   double limitSpacing = MathMax(LimitGridSpacingPips, 0.1) * pipToPoint;
   double limitOffset = MathMax(LimitOffsetPips, 0.0) * pipToPoint;
   double stopSpacing = MathMax(StopGridSpacingPips, 0.1) * pipToPoint;
   double stopOffset = MathMax(StopOffsetPips, 0.0) * pipToPoint;

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
   if(!TradeEnabled || !tradingAllowed)
      return;

    if(guardrailActive)
    {
       if(totalPendingOrders > 0)
          CancelAllPendingOrders();
       return;
    }

   UpdateSignalSnapshot();
   UpdateExposureGovernor();
   RefreshPendingOrders();

   datetime nowTime = TimeCurrent();
   bool timeElapsed = (lastPendingBatchTime == 0) || ((nowTime - lastPendingBatchTime) >= 60);
   int totalDesiredPending = (int)MathMax(2, MathRound(effectivePendingLimitsSide * 2 + effectivePendingStopsSide * 2));
   bool needsTopUp = (totalPendingOrders < totalDesiredPending * exposureScale);
   bool activeTrigger = (ActiveReplenishThreshold > 0 &&
                         totalActiveTrades >= lastActiveRefreshCount + ActiveReplenishThreshold);

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
   int tradeDirection = ResolveTradeDirection(baseSignal);
   if(tradeDirection != OP_BUY && tradeDirection != OP_SELL)
      return;

   int strength = (tradeDirection == OP_BUY) ? lastBuyScore : lastSellScore;
   if(strength < MarketEntryScoreThreshold)
      return;

   int burstSize = MathMax(burstCap, 1);
   int executed = 0;

   for(int i = 0; i < burstSize; i++)
   {
      if(totalActiveTrades >= MaxTrades || dailyTradeCount >= MaxDailyTrades)
         break;

      if(SubmitMarketOrder(tradeDirection))
         executed++;

      if(i < burstSize - 1 && BurstDelayMS > 0)
         Sleep(BurstDelayMS);
   }

   if(executed > 0)
   {
      lastMarketBurstTime = TimeCurrent();
      CompleteForcedBurst(true);
   }
}
string DirectionLabel(int direction)
{
   if(direction == OP_BUY)  return "BUY";
   if(direction == OP_SELL) return "SELL";
   return "NONE";
}

void ApplyForcedSequence(int direction, int bursts, string context, bool bypassToggle)
{
   if(!bypassToggle && !UsePatternRecovery)
      return;

   if(direction != OP_BUY && direction != OP_SELL)
      return;

   int normalizedBursts = MathMax(bursts, 0);
   if(normalizedBursts <= 0)
   {
      forcedDirection = -1;
      forcedBurstsRemaining = 0;
      forcedBurstOverride = false;
      return;
   }

   forcedDirection = direction;
   forcedBurstsRemaining = normalizedBursts;
   forcedBurstOverride = bypassToggle;
   Print("Pattern recovery trigger (", context, "): forcing ", DirectionLabel(direction),
         " for next ", forcedBurstsRemaining, " burst(s).");
}

void StartForcedSequence(int direction, int trades, string context)
{
   ApplyForcedSequence(direction, trades, context, false);
}

void ForceSequenceOverride(int direction, int bursts, string context)
{
   ApplyForcedSequence(direction, bursts, context, true);
}

int DetermineBurstSize()
{
   int burstSize = TradesPerBurst;

   if(AddTradesAfterWin && lastTradePL > 0 && BonusTradesOnWin > 0)
      burstSize += BonusTradesOnWin;

   if(ScaleBurstWithBalance && BalanceStepPerExtraBurst > 0.0 && initialAccountBalance > 0.0)
   {
      double balanceDelta = AccountBalance() - initialAccountBalance;
      if(balanceDelta > 0.0)
      {
         int balanceSteps = (int)MathFloor(balanceDelta / BalanceStepPerExtraBurst);
         if(balanceSteps > 0)
            burstSize += balanceSteps;
      }
   }

   if(MaxBurstTrades > 0)
      burstSize = MathMin(burstSize, MaxBurstTrades);

   burstSize = MathMax(burstSize, 1);
   return burstSize;
}

int ResolveTradeDirection(int baseSignal)
{
   bool signalValid = (baseSignal == OP_BUY || baseSignal == OP_SELL);
   bool forcedActive = (forcedDirection == OP_BUY || forcedDirection == OP_SELL) && forcedBurstsRemaining > 0;

   if(forcedActive)
   {
      bool allowOverride = forcedBurstOverride ||
                           (!PatternRequiresSignal) ||
                           !signalValid ||
                           baseSignal == forcedDirection;

      if(allowOverride)
         return forcedDirection;

      if(UsePatternRecovery)
         return -1;
   }

   if(!UsePatternRecovery)
      return baseSignal;

   return baseSignal;
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

void LookForScalpingOpportunity()
{
   // No direct action; pending orders are generated via MaintainPendingOrders().
}

int GetScalpingSignal()
{
   UpdateSignalSnapshot();

   if(!currentSignal.spreadOk)
      return -1;

   int buyScore = currentSignal.buyScore;
   int sellScore = currentSignal.sellScore;
   bool buySignal = currentSignal.buySignal;
   bool sellSignal = currentSignal.sellSignal;

   if(consecutiveLosses >= MaxConsecutiveLosses)
   {
      strategyShifted = true;

      int forcedBias = -1;
      if(lastTradeDirection == OP_BUY)
         forcedBias = OP_SELL;
      else if(lastTradeDirection == OP_SELL)
         forcedBias = OP_BUY;

      if(UsePatternRecovery && forcedBias != -1)
      {
         int burst = (forcedBias == OP_BUY) ? RecoveryBuyBurst : RecoverySellBurst;
         if(burst > 0)
            StartForcedSequence(forcedBias, burst,
                                StringConcatenate("max-loss recovery (", IntegerToString(consecutiveLosses), ")"));
      }

      if(buyScore > sellScore)
         return OP_BUY;
      if(sellScore > buyScore)
         return OP_SELL;
      if(forcedBias != -1)
         return forcedBias;

      return OP_BUY;
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
   if(orderType != OP_BUY && orderType != OP_SELL)
      return;

   if(!IsSpreadAcceptable())
   {
      Print("Trade blocked - Spread too high: ", DoubleToString((Ask - Bid) / Point / 10.0, 1));
      return;
   }

   double emaTrend = iMA(Symbol(), PERIOD_M1, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double pipToPoint = Point * 10.0;
   if(pipToPoint <= 0.0)
      pipToPoint = Point;

   double offsetPoints = MathMax(LimitOffsetPips, 0.0) * pipToPoint;
   int pendingType = (orderType == OP_BUY) ? OP_BUYLIMIT : OP_SELLLIMIT;
   double price = emaTrend;

   if(pendingType == OP_BUYLIMIT)
      price -= offsetPoints;
   else
      price += offsetPoints;

   price = NormalizeDouble(price, Digits);
   SubmitPendingOrder(pendingType, price);
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

void ManageActiveTrades()
{
   SyncActiveTradesWithBroker();

   if(totalActiveTrades == 0)
   {
      highestBasketProfit = 0;
      basketTrailingActive = false;
      lastDynamicTarget = 0;
      lastTrailLevel = 0;
      lastActiveRefreshCount = 0;
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

      double quickExitTarget = (QuickExitPips > 0.0) ? QuickExitPips : InstantProfitPips;
      if(UseInstantProfitExit && quickExitTarget > 0.0 && tradeProfit > 0.0 && pipGain >= quickExitTarget)
       {
         CloseTradeAtIndex(i, "Instant profit exit +" + DoubleToString(tradeProfit, 2));
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

      double lotSize = OrderLots();
      double riskPips = FIXED_STOP_LOSS_PIPS;
      double stop = OrderStopLoss();

      if(stop > 0 && pipToPoint > 0)
         riskPips = MathAbs(entry - stop) / pipToPoint;

      totalRiskCurrency += riskPips * pipValuePerLot * lotSize;

      if(minHoldMs > 0)
      {
         ulong openTick = activeTrades[i].openTickTime;
         ulong heldMs = (openTick > 0 && nowTick >= openTick) ? (nowTick - openTick) : 0;
         if(heldMs < minHoldMs)
            holdSatisfied = false;
         ulong maxHoldMs = (MaxHoldSeconds > 0) ? (ulong)MaxHoldSeconds * 1000 : 0;
         if(maxHoldMs > 0 && heldMs >= maxHoldMs)
         {
            CloseTradeAtIndex(i, "Max hold exit");
            i--;
            continue;
         }
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

   if(profitReady && dynamicTarget > 0.0 && totalProfit >= dynamicTarget)
   {
      CloseAllTrades("Dynamic profit target hit: KES " + DoubleToString(totalProfit, 2));
      return;
   }

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
            ForceSequenceOverride(OP_SELL, bursts, "instant reversal after BUY loss");
         }

         if(LosingBuyStreakTrigger > 0 && consecutiveBuyLosses >= LosingBuyStreakTrigger)
         {
            StartForcedSequence(OP_SELL, RecoverySellBurst,
                                StringConcatenate("buy-loss streak ", IntegerToString(consecutiveBuyLosses)));
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
            ForceSequenceOverride(OP_BUY, bursts, "instant reversal after SELL loss");
         }

         if(LosingSellStreakTrigger > 0 && consecutiveSellLosses >= LosingSellStreakTrigger)
         {
            StartForcedSequence(OP_BUY, RecoveryBuyBurst,
                                StringConcatenate("sell-loss streak ", IntegerToString(consecutiveSellLosses)));
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

   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return;

   int closedType = OrderType();
   bool isPending = (closedType == OP_BUYLIMIT || closedType == OP_SELLLIMIT);
   double finalPL = 0.0;
   bool successfulClose = false;

   if(isPending)
   {
      if(OrderDelete(ticket))
      {
         Print("Pending order cancelled: ", reason, " | Ticket ", ticket);
         successfulClose = true;
      }
   }
   else
   {
   double preClosePL = OrderProfit() + OrderSwap() + OrderCommission();
   double closePrice = (closedType == OP_BUY) ? Bid : Ask;
   double volume = OrderLots();

   RefreshRates();
      if(OrderClose(ticket, volume, closePrice, 3, clrYellow))
   {
         finalPL = preClosePL;
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
         successfulClose = true;
      }
   }

   if(!successfulClose)
      return;

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
      CancelAllPendingOrders();
      guardrailActive = false;
      guardrailPnlPercent = 0.0;
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
   if(UsePatternRecovery || forcedBurstOverride)
   {
      if(forcedDirection != -1 && forcedBurstsRemaining > 0)
      {
         patternStatus = StringConcatenate("FORCED ", DirectionLabel(forcedDirection),
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

   string status = StringConcatenate(
      "==== QuickScalperPro v3.00 (Adaptive Engine) ====\n",
      "Status: ", (tradingAllowed ? "ACTIVE" : "PAUSED"), " | ", trend, " | RSI: ", DoubleToString(rsi, 1), " | Momentum: ", momentum, "\n",
      "Basket: ", totalActiveTrades, "/", effectiveMaxTrades, " | Daily Baskets: ", basketsCompleted, " | Trades: ", dailyTradeCount, "\n",
      "========================================\n",
      "BASKET P&L: KES ", DoubleToString(basketProfit, 2), "\n",
      profitInfo, "\n",
      "Trailing: ", trailingStatus, "\n",
      "Pattern: ", patternStatus, "\n",
      "Guardrail: ", guardrailStatus, "\n",
      "========================================\n",
      "Daily P&L: KES ", DoubleToString(dailyProfit, 2), "\n",
      "Balance: KES ", DoubleToString(currentBalance, 2), "\n",
      "Spread: ", DoubleToString((Ask - Bid) / Point / 10.0, 1), " pips | Lot: ", DoubleToString(currentLotSize, 2), "\n",
      "Equity Target: ", DoubleToString(displayPercent, 2), "% | Hold >= ", IntegerToString(MinimumHoldMS), " ms"
   );

   Comment(status);
}

