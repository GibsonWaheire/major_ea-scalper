

#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "2.00"
#property strict

input group "===== Dynamic Lot Sizing ====="
input double   AccountBalance_10K  = 1000000.0;
input double   AccountBalance_100  = 100000.0;
input double   AccountBalance_1500 = 500000.0;
input double   MinLotSize          = 0.01;
input double   MaxLotSize          = 0.10;

input group "===== Core Trading Settings ====="
input int      MagicNumber         = 202501;
input int      MaxTrades           = 10;
input int      TradesPerBurst      = 5;
input int      BurstDelayMS        = 100;

input group "===== Basket Profit Management (TOTAL P&L) ====="
input double   BasketProfitTarget  = 600.0;
input double   BasketLossLimit     = 500.0;
input double   TrailingProfitStart = 400.0;
input double   TrailingStep        = 100.0;
input double   MaxSpreadPips       = 3.0;

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

struct QuickTrade {
   int      ticket;
   double   entryPrice;
   double   openTime;
   int      direction;
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
   Print("QuickScalperPro EA v1.00 Initialized");
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
   }

   double minStopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL);

   Print("Initialization successful!");
   Print("========================================");
   Print("AGGRESSIVE HIGH-FREQUENCY STRATEGY");
   Print("30+ Baskets Per Day - Quick Profits!");
   Print("========================================");
   Print("STRATEGY: Fast EMA(", TrendPeriod, ") + Quick RSI(", MomentumPeriod, ")");
   Print("Entry: ", (OnlyTrendTrades ? "MODERATE (2+ confirmations)" : "AGGRESSIVE (1+ confirmation)"));
   Print("Minimum Momentum: ", MinMomentumStrength, "% (LOW for more trades)");
   Print("========================================");
   Print("BASKET MANAGEMENT (QUICK EXITS):");
   Print("Profit Target: KES ", BasketProfitTarget, " | Loss Limit: KES -", BasketLossLimit);
   Print("Risk-Reward Ratio: 1:", DoubleToString(BasketProfitTarget/BasketLossLimit, 2));
   Print("Trailing: Starts at KES ", TrailingProfitStart, " (Early) | Step: KES ", TrailingStep);
   Print("Basket Size: ", TradesPerBurst, " trades | Max: ", MaxTrades, " concurrent");
   Print("Burst Delay: ", BurstDelayMS, "ms (FAST)");
   Print("========================================");
   Print("Expected: 30-50 baskets/day | ~150-250 trades/day");
   Print("Dynamic Lot: Min=", MinLotSize, " | Max=", MaxLotSize);
   Print("Max Spread: ", MaxSpreadPips, " pips");
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

   if(currentBalance >= AccountBalance_10K)
   {
      return MathMin(MaxLotSize, 0.10);
   }
   else if(currentBalance >= AccountBalance_1500)
   {
      return MathMin(MaxLotSize, 0.08);
   }
   else if(currentBalance >= AccountBalance_100)
   {
      return MathMin(MaxLotSize, 0.05);
   }
   else
   {
      return MinLotSize;
   }
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

   if(!IsSpreadAcceptable())
   {
      Print("Trade blocked - Spread too high: ", DoubleToString((Ask - Bid) / Point / 10.0, 1));
      return;
   }

   double sl = 0, tp = 0;

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
         activeTrades[totalActiveTrades].openTime = (double)TimeCurrent();
         activeTrades[totalActiveTrades].direction = orderType;
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

void ManageActiveTrades()
{

   if(totalActiveTrades == 0)
   {
      highestBasketProfit = 0;
      basketTrailingActive = false;
      return;
   }

   double totalProfit = 0;
   int validTrades = 0;

   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket > 0)
      {
         if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
         {
            double tradeProfit = OrderProfit() + OrderSwap() + OrderCommission();
            totalProfit += tradeProfit;
            validTrades++;
         }
      }
   }

   if(validTrades == 0) return;

   if(totalProfit > highestBasketProfit)
   {
      highestBasketProfit = totalProfit;
   }

   if(totalProfit >= BasketProfitTarget)
   {
      Print("BASKET PROFIT TARGET HIT: KES ", DoubleToString(totalProfit, 2), " (Target: ", BasketProfitTarget, ")");
      CloseAllTrades("Basket Profit Target: KES " + DoubleToString(totalProfit, 2));
      return;
   }

   if(totalProfit <= -BasketLossLimit)
   {
      Print("BASKET LOSS LIMIT HIT: KES ", DoubleToString(totalProfit, 2), " (Limit: -", BasketLossLimit, ")");
      CloseAllTrades("Basket Loss Limit: KES " + DoubleToString(totalProfit, 2));
      return;
   }

   if(totalProfit >= TrailingProfitStart)
   {
      basketTrailingActive = true;
      double trailingStop = highestBasketProfit - TrailingStep;

      if(totalProfit <= trailingStop && trailingStop > 0)
      {
         Print("BASKET TRAILING STOP HIT: KES ", DoubleToString(totalProfit, 2),
               " (Highest: ", DoubleToString(highestBasketProfit, 2), " | Trail: ", DoubleToString(trailingStop, 2), ")");
         CloseAllTrades("Basket Trailing Stop: KES " + DoubleToString(totalProfit, 2));
         return;
      }
   }
}

void CloseTradeAtIndex(int index, string reason)
{
   if(index < 0 || index >= totalActiveTrades) return;

   int ticket = activeTrades[index].ticket;

   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return;

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

            double finalPL = OrderProfit() + OrderSwap() + OrderCommission();
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

            Print("Trade auto-closed: KES ", DoubleToString(finalPL, 2));

            for(int j = i; j < totalActiveTrades - 1; j++)
            {
               activeTrades[j] = activeTrades[j + 1];
            }
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

   if(!IsTradeAllowed())
   {
      tradingAllowed = false;
      return false;
   }

   tradingAllowed = true;
   return true;
}

bool IsTradeAllowed()
{
   if(!::IsTradeAllowed())
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
   if(basketTrailingActive)
      trailingStatus = "ACTIVE @ KES " + DoubleToString(highestBasketProfit - TrailingStep, 2);

   int basketsCompleted = dailyTradeCount / TradesPerBurst;

   string status = StringConcatenate(
      "==== QuickScalperPro v2.00 (AGGRESSIVE HFT) ====\n",
      "Status: ", (tradingAllowed ? "ACTIVE" : "PAUSED"), " | ", trend, " | RSI: ", DoubleToString(rsi, 1), "\n",
      "Basket: ", totalActiveTrades, "/", MaxTrades, " | Daily Baskets: ", basketsCompleted, " | Trades: ", dailyTradeCount, "\n",
      "========================================\n",
      "BASKET P&L: KES ", DoubleToString(basketProfit, 2), "\n",
      "Target: +", BasketProfitTarget, " | Limit: -", BasketLossLimit, " | Trail: ", trailingStatus, "\n",
      "========================================\n",
      "Daily P&L: KES ", DoubleToString(dailyProfit, 2), "\n",
      "Balance: KES ", DoubleToString(currentBalance, 2), "\n",
      "Spread: ", DoubleToString((Ask - Bid) / Point / 10.0, 1), " pips | Lot: ", DoubleToString(currentLotSize, 2)
   );

   Comment(status);
}

