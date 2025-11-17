

#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "4.00"
#property strict

input group "===== Dynamic Lot Sizing ====="
input double   AccountBalance_10K  = 10000.0;
input double   AccountBalance_100  = 100.0;
input double   AccountBalance_1500 = 1500.0;
input double   MinLotSize          = 0.01;
input double   MaxLotSizeLimit     = 1.0;

input group "===== Core Trading Settings ====="
input double   BaseLotSize         = 0.01;
input int      MinConsecutiveTrades= 3;
input int      MaxConsecutiveTrades= 10;
input int      MagicNumber         = 202501;

input group "===== Profit Management ====="
input double   MinProfitTarget     = 0.50;
input double   MaxSpreadPips       = 3.0;
input double   DailyLossLimit      = 50.0;
input double   MaxDrawdownPercent  = 20.0;
input bool     ProfitOnlyExits     = true;

input group "===== Flip Growth Settings ====="
input double   TargetEquityValue      = 1000000.0;
input double   StageGrowthPercent     = 15.0;     // Growth required to advance to next stage
input double   RiskPerTradePercent    = 2.0;      // Risked equity per trade
input double   StageDrawdownPercent   = 10.0;     // Pullback that resets stage baseline
input double   DefaultStopLossPips    = 120.0;    // Risk distance used for lot sizing
input double   TradeRewardPercent     = 1.5;      // Profit goal per trade as percent of stage equity
input int      MaxTradesPerHour       = 6;

input group "===== Partial Close Settings ====="
input bool     UsePartialClose        = true;
input int      PartialLevels          = 5;        // Number of partial close levels before full TP
input double   PartialThresholdStep   = 0.2;      // Portion of target per level (0.2 = 20% increments)
input double   PartialLotStep         = 0.2;      // Fraction of original lot to close per level
input double   MinimumPartialProfit   = 0.50;     // Floor currency profit per partial level
input double   FinalLotMinimum        = 0.01;     // Minimum lot to leave running after partials

input group "===== Quick Entry Filters ====="
input bool     UseDirectionalFilter   = true;
input int      FastEMAPeriod          = 5;
input int      SlowEMAPeriod          = 21;
input int      RSIPeriod              = 7;
input double   BuyRSIMin              = 55.0;
input double   SellRSIMax             = 45.0;
input double   MinCandleBodyPoints    = 30.0;     // minimum body in points to confirm momentum
input double   MinTickAccelerationPts = 10.0;     // minimum tick movement (points) over recent ticks
input int      TickAccelerationSamples= 5;        // samples to evaluate acceleration window

input group "===== Trading Controls ====="
input bool     TradeEnabled        = true;
input int      MinBarsBetweenTrades= 3;
input int      MaxConcurrentTrades = 5;
input int      MaxConsecutiveLosses= 3;
input bool     OnlyTradeXAUUSD     = true;

struct TradeInfo {
   int      ticket;
   double   entryPrice;
   double   lotSize;
   double   highestProfit;
   datetime openTime;
   int      tradeNumber;
   double   targetProfit;
   double   initialLotSize;
   double   partialThreshold;
   double   partialLotChunk;
   int      partialStage;
};

TradeInfo   openTrades[50];
int         totalOpenTrades = 0;
int         consecutiveTradeCount = 0;
int         lastTradeDirection = -1;
datetime    lastTradeBar = 0;
double      dailyProfit = 0;
datetime    lastDayReset = 0;
bool        tradingAllowed = true;

int         consecutiveLosses = 0;
bool        strategyShifted = false;

double      accountStartBalance = 0;
bool        drawdownTriggered = false;

int         currentFlipStage = 1;
double      stageBaseEquity = 0;
double      stageTargetEquity = 0;
double      stageTradeProfitTarget = 0;
datetime    lastStageUpdate = 0;

datetime    recentTradeTimes[50];
int         recentTradeCount = 0;
bool        firstTradeLaunched = false;

double      tickHistory[20];
int         tickHistoryCount = 0;

double CalculateNextStageTarget(double baseEquity)
{
   double growthPercent = MathMax(StageGrowthPercent, 1.0);
   double nextEquity = baseEquity * (1.0 + growthPercent / 100.0);
   if(TargetEquityValue > 0.0)
      nextEquity = MathMin(nextEquity, TargetEquityValue);
   return MathMax(nextEquity, baseEquity + 0.01);
}

double CalculateTradeProfitTarget(double baseEquity)
{
   double percent = MathMax(TradeRewardPercent, 0.1);
   double target = baseEquity * (percent / 100.0);
   if(target < MinProfitTarget)
      target = MinProfitTarget;
   return target;
}

double CalculateLotSizeByRisk(double stopPips);
double NormalizeLotSize(double lot);
bool   ExecutePartialClose(int index, double closeLots, string reason);
void   UpdateTickHistory(double midPrice);
double GetRecentTickAcceleration();
int    DetermineImmediateDirection();
int    GetFilteredScalpingSignal();

void RecordRecentTradeTime(datetime timeValue)
{
   if(recentTradeCount >= ArraySize(recentTradeTimes))
      recentTradeCount = ArraySize(recentTradeTimes) - 1;

   for(int i = recentTradeCount; i > 0; i--)
      recentTradeTimes[i] = recentTradeTimes[i - 1];

   recentTradeTimes[0] = timeValue;
   if(recentTradeCount < ArraySize(recentTradeTimes))
      recentTradeCount++;
}

int CountRecentTradesWithin(int secondsWindow)
{
   datetime nowTime = TimeCurrent();
   int count = 0;

   for(int i = 0; i < recentTradeCount; i++)
   {
      if(recentTradeTimes[i] == 0)
         continue;
      if((nowTime - recentTradeTimes[i]) <= secondsWindow)
         count++;
   }

   return count;
}

void PurgeOldTradeTimes(int secondsWindow)
{
   datetime nowTime = TimeCurrent();
   int writeIndex = 0;

   for(int i = 0; i < recentTradeCount; i++)
   {
      if(recentTradeTimes[i] == 0)
         continue;
      if((nowTime - recentTradeTimes[i]) <= secondsWindow)
      {
         recentTradeTimes[writeIndex] = recentTradeTimes[i];
         writeIndex++;
      }
   }

   for(int j = writeIndex; j < recentTradeCount; j++)
      recentTradeTimes[j] = 0;

   recentTradeCount = writeIndex;
}

void UpdateTickHistory(double midPrice)
{
   if(tickHistoryCount < ArraySize(tickHistory))
   {
      tickHistory[tickHistoryCount] = midPrice;
      tickHistoryCount++;
   }
   else
   {
      for(int i = 1; i < ArraySize(tickHistory); i++)
         tickHistory[i - 1] = tickHistory[i];
      tickHistory[ArraySize(tickHistory) - 1] = midPrice;
   }
}

double GetRecentTickAcceleration()
{
   int samples = MathMin(TickAccelerationSamples, tickHistoryCount - 1);
   if(samples <= 0)
      return(0.0);

   double totalMove = 0.0;
   for(int i = tickHistoryCount - samples; i < tickHistoryCount - 1; i++)
   {
      totalMove += MathAbs(tickHistory[i + 1] - tickHistory[i]);
   }

   return totalMove / samples / Point;
}

int DetermineImmediateDirection()
{
   double openPrice = iOpen(Symbol(), PERIOD_M1, 0);
   double closePrice = iClose(Symbol(), PERIOD_M1, 0);
   if(closePrice >= openPrice)
      return OP_BUY;
   return OP_SELL;
}

int GetFilteredScalpingSignal()
{
   double currentSpread = (Ask - Bid) / Point / 10.0;
   bool tightSpread = (currentSpread <= MaxSpreadPips);

   if(consecutiveLosses >= MaxConsecutiveLosses && lastTradeDirection != -1)
   {
      strategyShifted = true;
      return (lastTradeDirection == OP_BUY) ? OP_SELL : OP_BUY;
   }

   double acceleration = GetRecentTickAcceleration();
   bool accelerationOK = (acceleration >= MinTickAccelerationPts);

   bool momentumBuy = true;
   bool momentumSell = true;

   if(UseDirectionalFilter)
   {
      double emaFast = iMA(Symbol(), PERIOD_M1, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
      double emaSlow = iMA(Symbol(), PERIOD_M1, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
      double rsi = iRSI(Symbol(), PERIOD_M1, RSIPeriod, PRICE_CLOSE, 0);
      double open0 = iOpen(Symbol(), PERIOD_M1, 0);
      double close0 = iClose(Symbol(), PERIOD_M1, 0);
      double candleBody = MathAbs(close0 - open0) / Point;

      momentumBuy = (emaFast > emaSlow) &&
                    (rsi >= BuyRSIMin) &&
                    (close0 > open0) &&
                    (candleBody >= MinCandleBodyPoints);

      momentumSell = (emaFast < emaSlow) &&
                     (rsi <= SellRSIMax) &&
                     (close0 < open0) &&
                     (candleBody >= MinCandleBodyPoints);
   }

   bool canAddBuy = (lastTradeDirection != OP_BUY) || (consecutiveTradeCount < MaxConsecutiveTrades);
   bool canAddSell = (lastTradeDirection != OP_SELL) || (consecutiveTradeCount < MaxConsecutiveTrades);

   if(tightSpread && accelerationOK && momentumBuy && canAddBuy)
      return OP_BUY;

   if(tightSpread && accelerationOK && momentumSell && canAddSell)
      return OP_SELL;

   return -1;
}

int OnInit()
{
   Print("========================================");
   Print("MomentumScalperPro EA v3.00 Initialized");
   Print("========================================");
   Print("Strategy: Pure Scalping - No Indicators");
   Print("Symbol: ", Symbol());
   Print("Timeframe: ", Period());

   string currentSymbol = Symbol();
   if(OnlyTradeXAUUSD && StringFind(currentSymbol, "XAU") < 0 && StringFind(currentSymbol, "GOLD") < 0)
   {
      Alert("ERROR: This EA is configured for Gold only. Current symbol: ", currentSymbol);
      return(INIT_FAILED);
   }

   totalOpenTrades = 0;
   consecutiveTradeCount = 0;
   lastTradeDirection = -1;
   accountStartBalance = AccountBalance();
   stageBaseEquity = accountStartBalance;
   stageTargetEquity = CalculateNextStageTarget(stageBaseEquity);
   stageTradeProfitTarget = CalculateTradeProfitTarget(stageBaseEquity);
   currentFlipStage = 1;
   lastStageUpdate = TimeCurrent();
   recentTradeCount = 0;
   firstTradeLaunched = false;
   tickHistoryCount = 0;

   for(int i = 0; i < 50; i++)
   {
      openTrades[i].ticket = -1;
      openTrades[i].entryPrice = 0;
      openTrades[i].lotSize = 0;
      openTrades[i].highestProfit = 0;
      openTrades[i].openTime = 0;
      openTrades[i].tradeNumber = 0;
      openTrades[i].targetProfit = 0;
      openTrades[i].initialLotSize = 0;
      openTrades[i].partialThreshold = 0;
      openTrades[i].partialLotChunk = 0;
      openTrades[i].partialStage = 0;
   }

   ArrayInitialize(recentTradeTimes, 0);
   ArrayInitialize(tickHistory, 0.0);

   Print("Initialization successful. Base Lot Size: ", DoubleToString(BaseLotSize, 2));
   Print("Min Consecutive Trades: ", MinConsecutiveTrades, " | Max: ", MaxConsecutiveTrades);
   Print("========================================");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("MomentumScalperPro EA v3.00 Deinitialized. Reason: ", reason);
}

void OnTick()
{

   double midPrice = (Ask + Bid) * 0.5;
   UpdateTickHistory(midPrice);

   if(!CheckDrawdownProtection())
   {

      CloseAllTrades("Drawdown Protection");
      Comment("DRAWDOWN LIMIT REACHED - All trades closed!");
      return;
   }

   CheckDailyReset();

   if(!PreFlightChecks()) return;

   if(!IsSpreadAcceptable())
   {
      Comment("SPREAD TOO HIGH: ", DoubleToString((Ask - Bid) / Point / 10.0, 1), " pips");
      return;
   }

   CleanupClosedTrades();
   ManageAllOpenPositions();

   if(CanOpenNewTrade())
   {
      AnalyzeAndTrade();
   }

   UpdateFlipProgress();
   UpdateDisplay();
}

bool PreFlightChecks()
{

   if(!TradeEnabled)
   {
      tradingAllowed = false;
      return false;
   }

   if(!IsTradeAllowed())
   {
      tradingAllowed = false;
      return false;
   }

   if(dailyProfit <= -DailyLossLimit)
   {
      Comment("DAILY LOSS LIMIT REACHED: $", DoubleToString(dailyProfit, 2));
      tradingAllowed = false;
      return false;
   }

   tradingAllowed = true;
   return true;
}

double CalculateDynamicLotSize()
{
   double stopPips = (DefaultStopLossPips > 0.0) ? DefaultStopLossPips : 100.0;
   return CalculateLotSizeByRisk(stopPips);
}

bool IsSpreadAcceptable()
{
   double currentSpread = (Ask - Bid) / Point / 10.0;
   return (currentSpread <= MaxSpreadPips);
}

bool CheckDrawdownProtection()
{
   double currentBalance = AccountBalance();
   double currentEquity = AccountEquity();
   double maxDrawdown = accountStartBalance * (MaxDrawdownPercent / 100.0);

   if(currentEquity < (accountStartBalance - maxDrawdown))
   {
      drawdownTriggered = true;
      Print("DRAWDOWN PROTECTION: ", MaxDrawdownPercent, "% limit reached!");
      return false;
   }

   return true;
}

double CalculateLotSizeByRisk(double stopPips)
{
   double balance = AccountBalance();
   double riskPercent = MathMax(RiskPerTradePercent, 0.1);
   double riskAmount = balance * (riskPercent / 100.0);

   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
   double pipSize   = Point * 10.0;

   if(tickSize <= 0.0 || pipSize <= 0.0 || stopPips <= 0.0)
      return NormalizeDouble(MinLotSize, 2);

   double pipValuePerLot = (tickValue / tickSize) * pipSize;
   if(pipValuePerLot <= 0.0)
      return NormalizeDouble(MinLotSize, 2);

   double lotSize = riskAmount / (stopPips * pipValuePerLot);

   lotSize = MathMax(lotSize, MinLotSize);
   lotSize = MathMin(lotSize, MaxLotSizeLimit);

   return NormalizeDouble(lotSize, 2);
}

double CalculateLotSize(int tradeNumber)
{
   double stopPips = (DefaultStopLossPips > 0.0) ? DefaultStopLossPips : 100.0;
   double lotSize = CalculateLotSizeByRisk(stopPips);

   if(tradeNumber > 1)
   {
      double stagedMultiplier = 1.0 + (MathMin(tradeNumber, 5) - 1) * 0.10;
      lotSize *= stagedMultiplier;
   }

   lotSize = MathMax(lotSize, MinLotSize);
   lotSize = MathMin(lotSize, MaxLotSizeLimit);

   return NormalizeDouble(lotSize, 2);
}

double NormalizeLotSize(double lot)
{
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   if(lotStep <= 0.0)
      lotStep = 0.01;

   if(minLot <= 0.0)
      minLot = 0.01;

   if(maxLot > 0.0)
      lot = MathMin(lot, maxLot);

   lot = MathMax(lot, minLot);

   lot = MathFloor((lot + 1e-8) / lotStep) * lotStep;

   if(lot < minLot)
      lot = minLot;

   return NormalizeDouble(lot, 2);
}

void AnalyzeAndTrade()
{

   int signal;

   if(!firstTradeLaunched)
   {
      signal = DetermineImmediateDirection();
   }
   else
   {
      signal = GetFilteredScalpingSignal();
   }

   if(signal == OP_BUY)
   {
      int before = totalOpenTrades;
      OpenTrade(OP_BUY);
      if(totalOpenTrades > before)
         firstTradeLaunched = true;
   }
   else if(signal == OP_SELL)
   {
      int before = totalOpenTrades;
      OpenTrade(OP_SELL);
      if(totalOpenTrades > before)
         firstTradeLaunched = true;
   }
}

int GetSimpleScalpingSignal()
{
   return GetFilteredScalpingSignal();
}

void OpenTrade(int orderType)
{
   double price = (orderType == OP_BUY) ? Ask : Bid;

   if(!IsSpreadAcceptable())
   {
      Print("Trade blocked - Spread too high: ", DoubleToString((Ask - Bid) / Point / 10.0, 1));
      return;
   }

   double sl = 0, tp = 0;

   double lotSize = CalculateLotSize(consecutiveTradeCount + 1);
   double pipToPoint = Point * 10.0;

    if(DefaultStopLossPips > 0.0 && pipToPoint > 0.0)
    {
       double stopDistance = DefaultStopLossPips * pipToPoint;
       if(orderType == OP_BUY)
          sl = NormalizeDouble(price - stopDistance, Digits);
       else
          sl = NormalizeDouble(price + stopDistance, Digits);
    }

    double perLotPipValue = 0;
    double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
    double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
    if(tickSize > 0.0)
       perLotPipValue = (tickValue / tickSize) * pipToPoint;

    double assignedTradeTarget = MathMax(stageTradeProfitTarget, MinProfitTarget);
    if(perLotPipValue > 0.0 && lotSize > 0.0)
    {
       double rewardPips = assignedTradeTarget / (perLotPipValue * lotSize);
       if(rewardPips > 0.0)
       {
          double tpDistance = rewardPips * pipToPoint;
          if(orderType == OP_BUY)
             tp = NormalizeDouble(price + tpDistance, Digits);
          else
             tp = NormalizeDouble(price - tpDistance, Digits);
       }
    }

   string comment = StringConcatenate("Scalp #", (consecutiveTradeCount + 1),
                                     (orderType == OP_BUY) ? " BUY" : " SELL");
   color arrowColor = (orderType == OP_BUY) ? clrGreen : clrRed;

   int ticket = OrderSend(Symbol(), orderType, lotSize, price, 3, sl, tp,
                          comment, MagicNumber, 0, arrowColor);

   if(ticket > 0)
   {

      if(totalOpenTrades < MaxConcurrentTrades)
      {
         openTrades[totalOpenTrades].ticket = ticket;
         openTrades[totalOpenTrades].entryPrice = price;
         openTrades[totalOpenTrades].lotSize = lotSize;
         openTrades[totalOpenTrades].highestProfit = 0;
         openTrades[totalOpenTrades].openTime = TimeCurrent();
         openTrades[totalOpenTrades].tradeNumber = consecutiveTradeCount + 1;
         openTrades[totalOpenTrades].targetProfit = assignedTradeTarget;

         openTrades[totalOpenTrades].initialLotSize = lotSize;
         if(UsePartialClose && PartialLevels > 0 && PartialThresholdStep > 0.0 && PartialLotStep > 0.0)
         {
            double thresholdStep = MathMax(MathMin(PartialThresholdStep, 0.9), 0.05);
            openTrades[totalOpenTrades].partialThreshold = assignedTradeTarget * thresholdStep;
            openTrades[totalOpenTrades].partialThreshold = MathMax(openTrades[totalOpenTrades].partialThreshold, MinimumPartialProfit);

            double lotChunk = openTrades[totalOpenTrades].initialLotSize * MathMax(MathMin(PartialLotStep, 0.9), 0.05);
            openTrades[totalOpenTrades].partialLotChunk = NormalizeLotSize(lotChunk);
            openTrades[totalOpenTrades].partialStage = 0;
         }
         else
         {
            openTrades[totalOpenTrades].partialThreshold = 0;
            openTrades[totalOpenTrades].partialLotChunk = 0;
            openTrades[totalOpenTrades].partialStage = PartialLevels;
         }
         totalOpenTrades++;
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

      lastTradeBar = iTime(Symbol(), PERIOD_M1, 0);
      RecordRecentTradeTime(TimeCurrent());

      Print("Trade opened: ", comment, " | Ticket: ", ticket, " | Lot: ", lotSize,
            " | Price: ", DoubleToString(price, Digits), " | Consecutive: ", consecutiveTradeCount);
   }
   else
   {
      Print("Error opening trade: ", GetLastError());
   }
}

void CleanupClosedTrades()
{
   for(int i = totalOpenTrades - 1; i >= 0; i--)
   {
      if(openTrades[i].ticket > 0)
      {
         if(!OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))
         {

            RemoveTradeFromArray(i);
         }
      }
   }
}

void ManageAllOpenPositions()
{
   for(int i = 0; i < totalOpenTrades; i++)
   {
      if(openTrades[i].ticket > 0)
      {
         if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))
         {
            double currentProfit = OrderProfit() + OrderSwap() + OrderCommission();

            if(currentProfit > openTrades[i].highestProfit)
               openTrades[i].highestProfit = currentProfit;

            double tradeTarget = MathMax(openTrades[i].targetProfit, MinProfitTarget);

            if(UsePartialClose && openTrades[i].partialStage < PartialLevels)
            {
               double requiredProfit = openTrades[i].partialThreshold * (openTrades[i].partialStage + 1);
               requiredProfit = MathMax(requiredProfit, MinimumPartialProfit);

               if(currentProfit >= requiredProfit)
               {
                  double currentLots = OrderLots();
                  double chunkLots = openTrades[i].partialLotChunk;

                  chunkLots = MathMin(chunkLots, currentLots - FinalLotMinimum);
                  chunkLots = MathMin(chunkLots, currentLots * 0.9);
                  chunkLots = NormalizeLotSize(chunkLots);

                  double minLot = MarketInfo(Symbol(), MODE_MINLOT);
                  if(minLot <= 0.0)
                     minLot = 0.01;

                  if(chunkLots >= minLot && chunkLots < currentLots - (FinalLotMinimum / 2.0))
                  {
                     if(ExecutePartialClose(i, chunkLots, StringConcatenate("Partial stage ", (openTrades[i].partialStage + 1))))
                     {
                        openTrades[i].partialStage++;
                        if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))
                        {
                           openTrades[i].lotSize = OrderLots();
                        }

                        double remainingTarget = openTrades[i].targetProfit - requiredProfit;
                        openTrades[i].targetProfit = MathMax(remainingTarget, MinProfitTarget);
                     }
                  }
               }
            }

            if(ProfitOnlyExits)
            {
               if(currentProfit >= tradeTarget)
               {
                  CloseTradeAtIndex(i, "Stage profit target: $" + DoubleToString(currentProfit, 2));
               }

            }
            else
            {

               if(currentProfit <= -25.0)
               {
                  CloseTradeAtIndex(i, "EMERGENCY STOP: $" + DoubleToString(currentProfit, 2));
               }
               else if(currentProfit >= tradeTarget)
               {
                  CloseTradeAtIndex(i, "Stage profit target: $" + DoubleToString(currentProfit, 2));
               }
            }
         }
      }
   }
}

void CloseTradeAtIndex(int index, string reason)
{
   if(index < 0 || index >= totalOpenTrades)
      return;

   int ticket = openTrades[index].ticket;

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return;

   double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;
   double volume = OrderLots();

   bool closed = OrderClose(ticket, volume, closePrice, 3, clrYellow);

   if(closed)
   {
      double finalPL = OrderProfit() + OrderSwap() + OrderCommission();
      dailyProfit += finalPL;

      if(finalPL < 0)
      {
         consecutiveLosses++;
         Print("CONSECUTIVE LOSS #", consecutiveLosses, ": $", DoubleToString(finalPL, 2));
      }
      else
      {
         consecutiveLosses = 0;
         strategyShifted = false;
         Print("PROFIT - Reset consecutive loss counter and strategy");
      }

      Print("===========================================");
      Print("Trade closed: ", reason);
      Print("Ticket: ", ticket, " | Final P&L: $", DoubleToString(finalPL, 2));
      Print("Highest Profit: $", DoubleToString(openTrades[index].highestProfit, 2));
      Print("Daily P&L: $", DoubleToString(dailyProfit, 2));
      Print("Consecutive Losses: ", consecutiveLosses);
      Print("===========================================");

      RemoveTradeFromArray(index);
   }
   else
   {
      Print("Error closing trade: ", GetLastError());
   }
}

bool ExecutePartialClose(int index, double closeLots, string reason)
{
   if(index < 0 || index >= totalOpenTrades)
      return false;

   int ticket = openTrades[index].ticket;
   if(ticket <= 0)
      return false;

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return false;

   double currentLots = OrderLots();
   int orderType = OrderType();
   double openPrice = OrderOpenPrice();
   if(closeLots <= 0.0 || closeLots >= currentLots)
      return false;

   RefreshRates();
   double closePrice = (orderType == OP_BUY) ? Bid : Ask;

   bool closed = OrderClose(ticket, closeLots, closePrice, 3, clrAqua);

   if(closed)
   {
      int direction = (orderType == OP_BUY) ? 1 : -1;
      double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
      double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
      double partialProfit = 0.0;

      if(tickSize > 0.0)
      {
         partialProfit = (closePrice - openPrice) * direction / tickSize * tickValue * closeLots;
      }

      dailyProfit += partialProfit;

      if(partialProfit < 0)
      {
         consecutiveLosses++;
         Print("PARTIAL CLOSE LOSS: ", DoubleToString(partialProfit, 2));
      }
      else
      {
         consecutiveLosses = 0;
         strategyShifted = false;
      }

      Print("Partial close executed: ", reason, " | Lots: ", DoubleToString(closeLots, 2),
            " | Profit: $", DoubleToString(partialProfit, 2));
      return true;
   }
   else
   {
      Print("Partial close failed: ", GetLastError());
   }

   return false;
}

void RemoveTradeFromArray(int index)
{
   if(index < 0 || index >= totalOpenTrades)
      return;

   for(int i = index; i < totalOpenTrades - 1; i++)
   {
      openTrades[i] = openTrades[i + 1];
   }

   totalOpenTrades--;

   if(totalOpenTrades == 0)
   {
      consecutiveTradeCount = 0;
      lastTradeDirection = -1;
   }

   int lastIndex = totalOpenTrades;
   if(lastIndex >= 0 && lastIndex < ArraySize(openTrades))
   {
      openTrades[lastIndex].ticket = -1;
      openTrades[lastIndex].entryPrice = 0;
      openTrades[lastIndex].lotSize = 0;
      openTrades[lastIndex].highestProfit = 0;
      openTrades[lastIndex].openTime = 0;
      openTrades[lastIndex].tradeNumber = 0;
      openTrades[lastIndex].targetProfit = 0;
      openTrades[lastIndex].initialLotSize = 0;
      openTrades[lastIndex].partialThreshold = 0;
      openTrades[lastIndex].partialLotChunk = 0;
      openTrades[lastIndex].partialStage = 0;
   }
}

void UpdateFlipProgress()
{
   double equity = AccountEquity();

   if(stageTargetEquity <= 0.0)
      stageTargetEquity = CalculateNextStageTarget(stageBaseEquity);

   if(stageTradeProfitTarget <= 0.0)
      stageTradeProfitTarget = CalculateTradeProfitTarget(stageBaseEquity);

   if(equity >= stageTargetEquity - Point)
   {
      stageBaseEquity = equity;
      currentFlipStage++;
      stageTargetEquity = CalculateNextStageTarget(stageBaseEquity);
      stageTradeProfitTarget = CalculateTradeProfitTarget(stageBaseEquity);
      lastStageUpdate = TimeCurrent();
      Print("FLIP STAGE ADVANCED: Stage ", currentFlipStage, " | New base equity: ", DoubleToString(stageBaseEquity, 2),
            " | Next target: ", DoubleToString(stageTargetEquity, 2));
   }
   else
   {
      double drawdownLevel = stageBaseEquity * (1.0 - StageDrawdownPercent / 100.0);
      if(StageDrawdownPercent > 0.0 && equity < drawdownLevel)
      {
         stageBaseEquity = equity;
         stageTargetEquity = CalculateNextStageTarget(stageBaseEquity);
         stageTradeProfitTarget = CalculateTradeProfitTarget(stageBaseEquity);
         currentFlipStage = MathMax(1, currentFlipStage - 1);
         lastStageUpdate = TimeCurrent();
         Print("FLIP STAGE RESET: Stage ", currentFlipStage, " | Base equity adjusted to ", DoubleToString(stageBaseEquity, 2));
      }
   }
}

bool CanOpenNewTrade()
{

   PurgeOldTradeTimes(3600);
   if(MaxTradesPerHour > 0 && CountRecentTradesWithin(3600) >= MaxTradesPerHour)
      return false;

   if(iTime(Symbol(), PERIOD_M1, 0) - lastTradeBar < MinBarsBetweenTrades * 60)
      return false;

   if(consecutiveTradeCount >= MaxConsecutiveTrades)
      return false;

   if(totalOpenTrades >= MaxConcurrentTrades)
      return false;

   return true;
}

double GetSpreadInPips()
{
   return (Ask - Bid) / Point / 10.0;
}

void CloseAllTrades(string reason)
{
   Print("EMERGENCY: Closing all trades - ", reason);

   for(int i = totalOpenTrades - 1; i >= 0; i--)
   {
      if(openTrades[i].ticket > 0)
      {
         CloseTradeAtIndex(i, reason);
      }
   }

   Print("All trades closed due to: ", reason);
}

void CheckDailyReset()
{
   datetime currentDay = iTime(Symbol(), PERIOD_D1, 0);

   if(currentDay != lastDayReset)
   {
      Print("Daily reset - Previous day P&L: $", DoubleToString(dailyProfit, 2));
      dailyProfit = 0;
      lastDayReset = currentDay;
   }
}

void UpdateDisplay()
{
   string status = "";

   double currentLotSize = CalculateDynamicLotSize();
   double currentBalance = AccountBalance();
   double drawdownPercent = ((accountStartBalance - AccountEquity()) / accountStartBalance) * 100.0;
   double currentEquity = AccountEquity();

   if(totalOpenTrades > 0)
   {
      status = StringConcatenate(
         "==== MomentumScalperPro v4.00 (Dynamic) ====\n",
         "Status: ", (tradingAllowed && !drawdownTriggered ? "SCALPING ACTIVE" : "PAUSED"), "\n",
         "Open Trades: ", totalOpenTrades, "\n",
         "Consecutive Count: ", consecutiveTradeCount, "\n",
         "Consecutive Losses: ", consecutiveLosses, " (", (strategyShifted ? "STRATEGY SHIFTED" : "NORMAL"), ")\n",
         "Last Direction: ", (lastTradeDirection == OP_BUY ? "BUY" : "SELL"), "\n",
         "Flip Stage: ", currentFlipStage, " | Base: $", DoubleToString(stageBaseEquity, 2),
         " | Target: $", DoubleToString(stageTargetEquity, 2), "\n",
         "Stage Profit Target: $", DoubleToString(stageTradeProfitTarget, 2),
         " | Equity: $", DoubleToString(currentEquity, 2), "\n",
         "----------------------------\n",
         "Daily P&L: $", DoubleToString(dailyProfit, 2), "\n",
         "Balance: $", DoubleToString(currentBalance, 2), " | Drawdown: ", DoubleToString(drawdownPercent, 1), "%\n",
         "Spread: ", DoubleToString(GetSpreadInPips(), 1), " pips (Max: ", MaxSpreadPips, ")\n",
         "Dynamic Lot: ", DoubleToString(currentLotSize, 2), " | Profit Only: ", (ProfitOnlyExits ? "YES" : "NO"),
         " | Risk/Trade: ", DoubleToString(RiskPerTradePercent, 1), "% | Max/Hour: ", MaxTradesPerHour
      );
   }
   else
   {
      status = StringConcatenate(
         "==== MomentumScalperPro v4.00 (Dynamic) ====\n",
         "Status: ", (tradingAllowed && !drawdownTriggered ? "SCANNING" : "PAUSED"), "\n",
         "Consecutive Count: ", consecutiveTradeCount, "\n",
         "Last Direction: ", (lastTradeDirection == -1 ? "NONE" : (lastTradeDirection == OP_BUY ? "BUY" : "SELL")), "\n",
         "Flip Stage: ", currentFlipStage, " | Base: $", DoubleToString(stageBaseEquity, 2),
         " | Target: $", DoubleToString(stageTargetEquity, 2), "\n",
         "Stage Profit Target: $", DoubleToString(stageTradeProfitTarget, 2),
         " | Equity: $", DoubleToString(currentEquity, 2), "\n",
         "Daily P&L: $", DoubleToString(dailyProfit, 2), "\n",
         "Balance: $", DoubleToString(currentBalance, 2), " | Drawdown: ", DoubleToString(drawdownPercent, 1), "%\n",
         "Spread: ", DoubleToString(GetSpreadInPips(), 1), " pips (Max: ", MaxSpreadPips, ")\n",
         "Dynamic Lot: ", DoubleToString(currentLotSize, 2), " | Profit Only: ", (ProfitOnlyExits ? "YES" : "NO"),
         " | Risk/Trade: ", DoubleToString(RiskPerTradePercent, 1), "% | Max/Hour: ", MaxTradesPerHour
      );
   }

   Comment(status);
}

