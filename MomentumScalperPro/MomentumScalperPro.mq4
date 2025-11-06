

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

   for(int i = 0; i < 50; i++)
   {
      openTrades[i].ticket = -1;
      openTrades[i].entryPrice = 0;
      openTrades[i].lotSize = 0;
      openTrades[i].highestProfit = 0;
      openTrades[i].openTime = 0;
      openTrades[i].tradeNumber = 0;
   }

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
   double currentBalance = AccountBalance();

   if(currentBalance >= AccountBalance_10K)
   {
      return MathMin(MaxLotSizeLimit, 1.0);
   }
   else if(currentBalance >= AccountBalance_1500)
   {
      return MathMin(MaxLotSizeLimit, 0.5);
   }
   else if(currentBalance >= AccountBalance_100)
   {
      return MathMin(MaxLotSizeLimit, 0.2);
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

double CalculateLotSize(int tradeNumber)
{

   double lotSize = CalculateDynamicLotSize();

   if(tradeNumber > 1)
   {
      double multiplier = 1.0 + (tradeNumber - 1) * 0.15;
      lotSize = CalculateDynamicLotSize() * multiplier;
   }

   lotSize = MathMax(lotSize, MinLotSize);
   lotSize = MathMin(lotSize, MaxLotSizeLimit);

   return NormalizeDouble(lotSize, 2);
}

void AnalyzeAndTrade()
{

   int signal = GetSimpleScalpingSignal();

   if(signal == OP_BUY)
   {
      OpenTrade(OP_BUY);
   }
   else if(signal == OP_SELL)
   {
      OpenTrade(OP_SELL);
   }
}

int GetSimpleScalpingSignal()
{

   if(consecutiveLosses >= MaxConsecutiveLosses && lastTradeDirection != -1)
   {
      strategyShifted = true;

      if(lastTradeDirection == OP_BUY)
      {
         Print("STRATEGY SHIFT: Switching to SELL after consecutive losses");
         return OP_SELL;
      }
      else
      {
         Print("STRATEGY SHIFT: Switching to BUY after consecutive losses");
         return OP_BUY;
      }
   }

   double currentSpread = (Ask - Bid) / Point / 10.0;
   bool tightSpread = (currentSpread <= MaxSpreadPips);
   bool canBuyMore = (lastTradeDirection != OP_BUY) || (consecutiveTradeCount < 5);

   if(lastTradeDirection == -1 && consecutiveTradeCount == 0 && tightSpread)
   {
      Print("BUY SIGNAL: First trade with tight spread=", DoubleToString(currentSpread, 1));
      return OP_BUY;
   }

   if(tightSpread && canBuyMore)
   {

      if(lastTradeDirection == OP_BUY || consecutiveTradeCount < MinConsecutiveTrades)
      {
         Print("BUY SIGNAL: Continuing BUY direction | Spread=", DoubleToString(currentSpread, 1), " | Trades=", consecutiveTradeCount);
         return OP_BUY;
      }
   }

   if(consecutiveTradeCount >= MaxConsecutiveTrades || strategyShifted)
   {
      return OP_SELL;
   }

   return -1;
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

            if(ProfitOnlyExits)
            {
               if(currentProfit >= MinProfitTarget)
               {
                  CloseTradeAtIndex(i, "Profit Target: $" + DoubleToString(currentProfit, 2));
               }

            }
            else
            {

               if(currentProfit <= -25.0)
               {
                  CloseTradeAtIndex(i, "EMERGENCY STOP: $" + DoubleToString(currentProfit, 2));
               }
               else if(currentProfit >= MinProfitTarget)
               {
                  CloseTradeAtIndex(i, "Profit Target: $" + DoubleToString(currentProfit, 2));
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
}

bool CanOpenNewTrade()
{

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

   if(totalOpenTrades > 0)
   {
      status = StringConcatenate(
         "==== MomentumScalperPro v4.00 (Dynamic) ====\n",
         "Status: ", (tradingAllowed && !drawdownTriggered ? "SCALPING ACTIVE" : "PAUSED"), "\n",
         "Open Trades: ", totalOpenTrades, "\n",
         "Consecutive Count: ", consecutiveTradeCount, "\n",
         "Consecutive Losses: ", consecutiveLosses, " (", (strategyShifted ? "STRATEGY SHIFTED" : "NORMAL"), ")\n",
         "Last Direction: ", (lastTradeDirection == OP_BUY ? "BUY" : "SELL"), "\n",
         "----------------------------\n",
         "Daily P&L: $", DoubleToString(dailyProfit, 2), "\n",
         "Balance: $", DoubleToString(currentBalance, 2), " | Drawdown: ", DoubleToString(drawdownPercent, 1), "%\n",
         "Spread: ", DoubleToString(GetSpreadInPips(), 1), " pips (Max: ", MaxSpreadPips, ")\n",
         "Dynamic Lot: ", DoubleToString(currentLotSize, 2), " | Profit Only: ", (ProfitOnlyExits ? "YES" : "NO")
      );
   }
   else
   {
      status = StringConcatenate(
         "==== MomentumScalperPro v4.00 (Dynamic) ====\n",
         "Status: ", (tradingAllowed && !drawdownTriggered ? "SCANNING" : "PAUSED"), "\n",
         "Consecutive Count: ", consecutiveTradeCount, "\n",
         "Last Direction: ", (lastTradeDirection == -1 ? "NONE" : (lastTradeDirection == OP_BUY ? "BUY" : "SELL")), "\n",
         "Daily P&L: $", DoubleToString(dailyProfit, 2), "\n",
         "Balance: $", DoubleToString(currentBalance, 2), " | Drawdown: ", DoubleToString(drawdownPercent, 1), "%\n",
         "Spread: ", DoubleToString(GetSpreadInPips(), 1), " pips (Max: ", MaxSpreadPips, ")\n",
         "Dynamic Lot: ", DoubleToString(currentLotSize, 2), " | Profit Only: ", (ProfitOnlyExits ? "YES" : "NO")
      );
   }

   Comment(status);
}

