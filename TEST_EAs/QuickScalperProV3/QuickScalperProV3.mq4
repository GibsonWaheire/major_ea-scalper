

#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "3.00"
#property strict

input group "===== Dynamic Lot Sizing ====="
input double   AccountBalance_10K  = 1000000.0;
input double   AccountBalance_100  = 100000.0;
input double   AccountBalance_1500 = 500000.0;
input double   MinLotSize          = 0.01;
input double   MaxLotSize          = 0.10;

input group "===== Core Trading Settings ====="
input int      MagicNumber         = 202503;
input int      MaxTrades           = 12;
input int      TradesPerBurst      = 5;
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
input double   PeakGivebackPercent = 30.0;    // Allowable giveback from profit peak
input int      MinimumHoldMS       = 250;     // Prevent premature exits
input double   MaxSpreadPips       = 3.0;

input group "===== Trading Controls ====="
input bool     TradeEnabled        = true;
input int      TickDelay           = 1;
input int      MaxConsecutiveLosses= 5;
input bool     UseGoldOnly         = true;
input int      MaxDailyTrades      = 100000;

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
input double   PerTradeProfitLock  = 5000.0;   // Close individual positions once profit exceeds this amount

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

QuickTrade activeTrades[20];
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

   for(int i = 0; i < 20; i++)
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

   int signal = GetScalpingSignal();

   if(signal == OP_BUY || signal == OP_SELL)
   {

      for(int burst = 0; burst < TradesPerBurst; burst++)
      {

         if(totalActiveTrades >= MaxTrades || dailyTradeCount >= MaxDailyTrades)
            break;

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

   string comment = "ScalpPro " + (orderType == OP_BUY ? "BUY" : "SELL") + " Lot:" + DoubleToString(lotSize, 2);
   color arrowColor = (orderType == OP_BUY) ? clrGreen : clrRed;

   int ticket = OrderSend(Symbol(), orderType, lotSize, price, 3, sl, tp,
                          comment, MagicNumber, 0, arrowColor);

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

      if(totalActiveTrades < 20)
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
   if(!UseTrailingStop || TrailingStartPips <= 0.0 || TrailingStepPips <= 0.0)
      return;

   if(index < 0 || index >= totalActiveTrades)
      return;

   int ticket = activeTrades[index].ticket;
   if(ticket <= 0)
      return;

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
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

      double tradeProfit = OrderProfit() + OrderSwap() + OrderCommission();

       if(PerTradeProfitLock > 0.0 && tradeProfit >= PerTradeProfitLock)
       {
         CloseTradeAtIndex(i, "Per-trade profit lock +" + DoubleToString(tradeProfit, 2));
         i--;
         continue;
       }

      totalProfit += tradeProfit;

      double lotSize = OrderLots();
      double riskPips = StopLossPips;
      double stop = OrderStopLoss();
      double entry = OrderOpenPrice();

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

void CloseTradeAtIndex(int index, string reason)
{
   if(index < 0 || index >= totalActiveTrades) return;

   int ticket = activeTrades[index].ticket;

   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return;

   double preClosePL = OrderProfit() + OrderSwap() + OrderCommission();
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
   return totalActiveTrades < MaxTrades && tradingAllowed && dailyTradeCount < MaxDailyTrades;
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

   string status = StringConcatenate(
      "==== QuickScalperPro v3.00 (Adaptive Engine) ====\n",
      "Status: ", (tradingAllowed ? "ACTIVE" : "PAUSED"), " | ", trend, " | RSI: ", DoubleToString(rsi, 1), " | Momentum: ", momentum, "\n",
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

