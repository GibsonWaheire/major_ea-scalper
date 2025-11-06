

#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "2.00"
#property strict

input group "===== Dynamic Lot Sizing ====="
input double   AccountBalance_10K  = 10000.0;
input double   AccountBalance_100  = 100.0;
input double   AccountBalance_1500 = 1500.0;
input double   MinLotSize          = 0.01;
input double   MaxLotSizeLimit     = 1.0;

input group "===== Portfolio Profit Targets (%) ====="
input double   PortfolioProfitTarget = 2.0;
input double   QuickExitPercent      = 1.0;
input double   MaxProfitPercent      = 5.0;

input group "===== Core Trading Settings ====="
input int      MaxBasketSize       = 10;
input int      MinBasketSize       = 3;
input int      MagicNumber         = 202503;
input int      MaxConcurrentTrades = 15;

input group "===== Candle Position Strategy ====="
input double   BuyCloseThreshold   = 70.0;
input double   SellCloseThreshold  = 30.0;
input double   MinCandleBodyPercent = 50.0;
input bool     RequireStrongCandle = true;
input int      CandleLookback      = 1;

input group "===== Risk Management ====="
input double   MaxDrawdownPercent  = 25.0;
input double   DailyLossLimitPercent = 10.0;
input double   MaxSpreadPips       = 5.0;
input bool     UseQuickExit        = true;

input group "===== Trading Controls ====="
input bool     TradeEnabled        = true;
input int      MinBarsBetweenEntry = 1;
input int      EntryBurstCount     = 5;
input bool     AllowIndices        = true;

struct TradeInfo {
   int      ticket;
   double   entryPrice;
   double   lotSize;
   datetime openTime;
   int      orderType;
};

TradeInfo   openTrades[100];
int         totalOpenTrades = 0;
datetime    lastTradeBar = 0;
double      dailyProfit = 0;
datetime    lastDayReset = 0;
bool        tradingAllowed = true;

double      accountStartBalance = 0;
bool        drawdownTriggered = false;
int         tradesOpenedInBurst = 0;

int OnInit()
{
   Print("========================================");
   Print("FastBasketScalper V2.00 - CANDLE POSITION STRATEGY");
   Print("========================================");
   Print("Strategy: Candle Close Position + Body Strength");
   Print("Symbol: ", Symbol());
   Print("Timeframe: ", Period());

   if(AllowIndices)
   {
      string sym = Symbol();
      if(StringFind(sym, "US30") < 0 && StringFind(sym, "US100") < 0 &&
         StringFind(sym, "DSX") < 0 && StringFind(sym, "NAS") < 0 &&
         StringFind(sym, "DOW") < 0 && StringFind(sym, "SPX") < 0)
      {
         Print("WARNING: EA optimized for US indices (US30, US100, DSX). Current: ", sym);
      }
   }

   totalOpenTrades = 0;
   accountStartBalance = AccountBalance();
   tradesOpenedInBurst = 0;

   for(int i = 0; i < 100; i++)
   {
      openTrades[i].ticket = -1;
      openTrades[i].entryPrice = 0;
      openTrades[i].lotSize = 0;
      openTrades[i].openTime = 0;
      openTrades[i].orderType = -1;
   }

   Print("========================================");
   Print("CANDLE STRATEGY SETTINGS:");
   Print("BUY Threshold: Close >= ", BuyCloseThreshold, "% of candle");
   Print("SELL Threshold: Close <= ", SellCloseThreshold, "% of candle");
   Print("Min Body Strength: ", MinCandleBodyPercent, "%");
   Print("Strong Candle Required: ", (RequireStrongCandle ? "YES" : "NO"));
   Print("========================================");
   Print("Portfolio Profit Target: ", PortfolioProfitTarget, "%");
   Print("Quick Exit: ", QuickExitPercent, "% | Max Profit: ", MaxProfitPercent, "%");
   Print("Max Basket Size: ", MaxBasketSize, " trades");
   Print("========================================");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("FastBasketScalper V2.00 Deinitialized. Reason: ", reason);
}

void OnTick()
{

   if(!CheckDrawdownProtection())
   {
      CloseAllTrades("Drawdown Protection - 25% Limit");
      Comment("DRAWDOWN LIMIT REACHED - All trades closed!");
      return;
   }

   CheckDailyReset();

   if(!PreFlightChecks()) return;

   if(!IsSpreadAcceptable())
   {
      Comment("SPREAD TOO HIGH: ", DoubleToString(GetCurrentSpread(), 1), " points");
      return;
   }

   CleanupClosedTrades();

   CheckPortfolioProfitAndClose();

   if(CanOpenNewTrade())
   {
      OpenBurstTrades();
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

   double dailyLossLimit = accountStartBalance * (DailyLossLimitPercent / 100.0);
   if(dailyProfit <= -dailyLossLimit)
   {
      Comment("DAILY LOSS LIMIT REACHED: ", DoubleToString(dailyProfit, 2), " (", DailyLossLimitPercent, "%)");
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
   double currentSpread = GetCurrentSpread();
   return (currentSpread <= MaxSpreadPips);
}

double GetCurrentSpread()
{

   return (Ask - Bid) / Point;
}

bool CheckDrawdownProtection()
{
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

void CheckPortfolioProfitAndClose()
{
   if(totalOpenTrades < MinBasketSize)
      return;

   double totalProfit = 0;
   for(int i = 0; i < totalOpenTrades; i++)
   {
      if(openTrades[i].ticket > 0)
      {
         if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))
         {
            totalProfit += OrderProfit() + OrderSwap() + OrderCommission();
         }
      }
   }

   double profitPercent = (totalProfit / accountStartBalance) * 100.0;

   if(UseQuickExit && profitPercent >= QuickExitPercent)
   {
      Print("QUICK EXIT TRIGGERED: Portfolio profit ", DoubleToString(profitPercent, 2), "% ($", DoubleToString(totalProfit, 2), ")");
      CloseAllTrades("Quick Exit: " + DoubleToString(profitPercent, 2) + "% Profit");
      return;
   }

   if(profitPercent >= PortfolioProfitTarget)
   {
      Print("PROFIT TARGET HIT: Portfolio profit ", DoubleToString(profitPercent, 2), "% ($", DoubleToString(totalProfit, 2), ")");
      CloseAllTrades("Target: " + DoubleToString(profitPercent, 2) + "% Profit");
      return;
   }

   if(profitPercent >= MaxProfitPercent)
   {
      Print("MAX PROFIT TARGET HIT: Portfolio profit ", DoubleToString(profitPercent, 2), "% ($", DoubleToString(totalProfit, 2), ")");
      CloseAllTrades("Max Target: " + DoubleToString(profitPercent, 2) + "% Profit");
      return;
   }

   if(totalOpenTrades >= MaxBasketSize && profitPercent < -2.0)
   {
      Print("EMERGENCY EXIT: Basket full with ", DoubleToString(profitPercent, 2), "% loss");
      CloseAllTrades("Emergency: Basket Full & Losing");
      return;
   }
}

void OpenBurstTrades()
{

   int direction = GetCandlePositionSignal();

   if(direction == -1)
      return;

   int tradesToOpen = MathMin(EntryBurstCount, MaxConcurrentTrades - totalOpenTrades);

   for(int i = 0; i < tradesToOpen; i++)
   {
      OpenTrade(direction);
      Sleep(100);
   }

   tradesOpenedInBurst = tradesToOpen;
   Print("BURST ENTRY: Opened ", tradesOpenedInBurst, " ", (direction == OP_BUY ? "BUY" : "SELL"), " trades (Candle Position Strategy)");
}

int GetCandlePositionSignal()
{

   double open = iOpen(Symbol(), PERIOD_M1, CandleLookback);
   double close = iClose(Symbol(), PERIOD_M1, CandleLookback);
   double high = iHigh(Symbol(), PERIOD_M1, CandleLookback);
   double low = iLow(Symbol(), PERIOD_M1, CandleLookback);

   double range = high - low;

   if(range == 0)
      return -1;

   double closePosition = ((close - low) / range) * 100.0;

   double bodySize = MathAbs(close - open);
   double bodyPercent = (bodySize / range) * 100.0;

   bool strongCandle = (bodyPercent >= MinCandleBodyPercent);

   if(RequireStrongCandle && !strongCandle)
   {
      return -1;
   }

   if(closePosition >= BuyCloseThreshold && close > open)
   {
      Print("BUY Signal: Close at ", DoubleToString(closePosition, 1), "% | Body: ", DoubleToString(bodyPercent, 1), "%");
      return OP_BUY;
   }

   if(closePosition <= SellCloseThreshold && close < open)
   {
      Print("SELL Signal: Close at ", DoubleToString(closePosition, 1), "% | Body: ", DoubleToString(bodyPercent, 1), "%");
      return OP_SELL;
   }

   return -1;
}

void OpenTrade(int orderType)
{
   double price = (orderType == OP_BUY) ? Ask : Bid;
   double lotSize = CalculateDynamicLotSize();

   double sl = 0, tp = 0;

   string comment = StringConcatenate("BasketV2 #", (totalOpenTrades + 1));
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
         openTrades[totalOpenTrades].openTime = TimeCurrent();
         openTrades[totalOpenTrades].orderType = orderType;
         totalOpenTrades++;
      }

      lastTradeBar = iTime(Symbol(), PERIOD_M1, 0);
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

void CloseAllTrades(string reason)
{
   Print("========================================");
   Print("CLOSING ALL TRADES: ", reason);
   Print("========================================");

   double totalPL = 0;
   int closedCount = 0;

   for(int i = totalOpenTrades - 1; i >= 0; i--)
   {
      if(openTrades[i].ticket > 0)
      {
         if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))
         {
            double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;
            double volume = OrderLots();

            bool closed = OrderClose(openTrades[i].ticket, volume, closePrice, 5, clrYellow);

            if(closed)
            {
               double pl = OrderProfit() + OrderSwap() + OrderCommission();
               totalPL += pl;
               closedCount++;
               Print("Trade #", openTrades[i].ticket, " closed: $", DoubleToString(pl, 2));
            }
         }

         RemoveTradeFromArray(i);
      }
   }

   dailyProfit += totalPL;
   double profitPercent = (totalPL / accountStartBalance) * 100.0;

   Print("========================================");
   Print("BASKET CLOSED: ", closedCount, " trades");
   Print("Total P&L: $", DoubleToString(totalPL, 2), " (", DoubleToString(profitPercent, 2), "%)");
   Print("Daily P&L: $", DoubleToString(dailyProfit, 2));
   Print("========================================");

   tradesOpenedInBurst = 0;
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
}

bool CanOpenNewTrade()
{

   if(totalOpenTrades >= MaxBasketSize)
      return false;

   if(totalOpenTrades >= MaxConcurrentTrades)
      return false;

   if(iTime(Symbol(), PERIOD_M1, 0) - lastTradeBar < MinBarsBetweenEntry * 60)
      return false;

   if(totalOpenTrades == 0)
      return true;

   return true;
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
   double currentEquity = AccountEquity();
   double drawdownPercent = ((accountStartBalance - currentEquity) / accountStartBalance) * 100.0;

   double portfolioProfit = 0;
   for(int i = 0; i < totalOpenTrades; i++)
   {
      if(openTrades[i].ticket > 0)
      {
         if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))
         {
            portfolioProfit += OrderProfit() + OrderSwap() + OrderCommission();
         }
      }
   }

   double portfolioProfitPercent = (portfolioProfit / accountStartBalance) * 100.0;

   double lastClose = iClose(Symbol(), PERIOD_M1, CandleLookback);
   double lastHigh = iHigh(Symbol(), PERIOD_M1, CandleLookback);
   double lastLow = iLow(Symbol(), PERIOD_M1, CandleLookback);
   double lastRange = lastHigh - lastLow;
   double lastClosePos = (lastRange > 0) ? ((lastClose - lastLow) / lastRange) * 100.0 : 0;

   status = StringConcatenate(
      "==== FastBasketScalper V2.00 (CANDLE) ====\n",
      "Status: ", (tradingAllowed && !drawdownTriggered ? "ACTIVE" : "PAUSED"), "\n",
      "Strategy: Candle Close Position\n",
      "----------------------------\n",
      "Last Candle Close: ", DoubleToString(lastClosePos, 1), "% (BUY>=", BuyCloseThreshold, "%, SELL<=", SellCloseThreshold, "%)\n",
      "----------------------------\n",
      "Open Trades: ", totalOpenTrades, " / ", MaxBasketSize, "\n",
      "Portfolio P&L: $", DoubleToString(portfolioProfit, 2), " (", DoubleToString(portfolioProfitPercent, 2), "%)\n",
      "Target: ", PortfolioProfitTarget, "% | Quick: ", QuickExitPercent, "% | Max: ", MaxProfitPercent, "%\n",
      "----------------------------\n",
      "Daily P&L: $", DoubleToString(dailyProfit, 2), "\n",
      "Balance: $", DoubleToString(currentBalance, 2), " | Equity: $", DoubleToString(currentEquity, 2), "\n",
      "Drawdown: ", DoubleToString(drawdownPercent, 1), "% (Max: ", MaxDrawdownPercent, "%)\n",
      "Spread: ", DoubleToString(GetCurrentSpread(), 1), " points\n",
      "Lot Size: ", DoubleToString(currentLotSize, 2)
   );

   Comment(status);
}

