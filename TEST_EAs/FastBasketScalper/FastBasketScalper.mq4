

#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"
#property strict

input group "===== Dynamic Lot Sizing ====="
input double   AccountBalance_10K  = 10000.0;
input double   AccountBalance_100  = 100.0;
input double   AccountBalance_1500 = 1500.0;
input double   MinLotSize          = 0.01;
input double   MaxLotSizeLimit     = 1.0;

input group "===== Core Trading Settings ====="
input int      MaxBasketSize       = 10;
input int      MinBasketSize       = 3;
input int      MagicNumber         = 202502;
input int      MaxConcurrentTrades = 15;

input group "===== Risk Management ====="
input double   MaxDrawdownPercent  = 25.0;
input double   DailyLossLimitPercent = 10.0;
input double   MaxSpreadPips       = 50.0;

input group "===== Trading Controls ====="
input bool     TradeEnabled        = true;
input int      MinBarsBetweenEntry = 0;
input int      EntryBurstCount     = 5;
input bool     AllowIndices        = true;
input bool     BuyBiased           = true;
input bool     RequireOverallProfit = false;

input group "===== Portfolio Profit Targets (%) ====="
input double   PortfolioMinProfitPercent = 3.0;
input double   PortfolioMaxProfitPercent = 50.0;

input group "===== Individual Trade Exit Rules ====="
input double   IndividualLossLimitPercent = 30.0;
input double   IndividualProfitTargetPercent = 10.0;
input double   IndividualProfitHoldPercent = 5.0;
input int      ProfitHoldTimeMinutes = 5;

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
   Print("FastBasketScalper EA v1.00 Initialized");
   Print("========================================");
   Print("Strategy: Ultra-Fast Basket Trading");
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

   Print("Portfolio Profit Range: ", PortfolioMinProfitPercent, "% - ", PortfolioMaxProfitPercent, "%");
   Print("Individual Trade Rules: -", IndividualLossLimitPercent, "% loss | +", IndividualProfitTargetPercent, "% profit | +", IndividualProfitHoldPercent, "% hold for ", ProfitHoldTimeMinutes, " min");
   Print("Max Basket Size: ", MaxBasketSize, " trades");
   Print("========================================");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("FastBasketScalper EA v1.00 Deinitialized. Reason: ", reason);
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

   // Check for instant profit exits FIRST (highest priority)
   CheckIndividualTradeExitRules();
   
   CheckPortfolioProfitAndClose();

   // Open new trades continuously based on available capital
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
   // Calculate MAXIMUM lot size based on available free margin
   double freeMargin = AccountFreeMargin();
   double currentBalance = AccountBalance();
   
   // Get margin requirement per lot
   double marginPerLot = MarketInfo(Symbol(), MODE_MARGINREQUIRED);
   
   if(marginPerLot <= 0)
   {
      // Fallback calculation if margin info not available
      // Use leverage to estimate (assuming 1:100 leverage = 1% margin)
      double leverage = AccountLeverage();
      if(leverage <= 0) leverage = 100;
      double contractSize = MarketInfo(Symbol(), MODE_LOTSIZE);
      if(contractSize <= 0) contractSize = 100000;
      double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
      if(tickValue <= 0) tickValue = 1;
      
      double currentPrice = (Ask + Bid) / 2;
      marginPerLot = (contractSize / leverage) * (currentPrice / tickValue);
   }
   
   // Calculate maximum lots we can open with available free margin
   // Use 90% of free margin to leave some buffer
   double usableMargin = freeMargin * 0.90;
   double maxLots = usableMargin / marginPerLot;
   
   // Round down to nearest lot step
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(lotStep <= 0) lotStep = 0.01;
   
   maxLots = MathFloor(maxLots / lotStep) * lotStep;
   
   // Ensure within broker limits
   double maxLotAllowed = MarketInfo(Symbol(), MODE_MAXLOT);
   double minLotAllowed = MarketInfo(Symbol(), MODE_MINLOT);
   
   if(maxLotAllowed > 0)
      maxLots = MathMin(maxLots, maxLotAllowed);
   if(minLotAllowed > 0)
      maxLots = MathMax(maxLots, minLotAllowed);
   
   // Apply user-defined limits
   maxLots = MathMin(maxLots, MaxLotSizeLimit);
   maxLots = MathMax(maxLots, MinLotSize);
   
   // If calculation fails, use balance-based fallback
   if(maxLots < MinLotSize)
   {
      if(currentBalance >= AccountBalance_10K)
         return MathMin(MaxLotSizeLimit, 1.0);
      else if(currentBalance >= AccountBalance_1500)
         return MathMin(MaxLotSizeLimit, 0.5);
      else if(currentBalance >= AccountBalance_100)
         return MathMin(MaxLotSizeLimit, 0.2);
      else
         return MinLotSize;
   }
   
   return maxLots;
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
   if(totalOpenTrades == 0)
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

   if(profitPercent >= PortfolioMinProfitPercent && profitPercent <= PortfolioMaxProfitPercent)
   {
      Print("PORTFOLIO PROFIT TARGET: Closing all trades at ", DoubleToString(profitPercent, 2), "% profit ($", DoubleToString(totalProfit, 2), ")");
      CloseAllTrades("Portfolio Profit: " + DoubleToString(profitPercent, 2) + "%");
      return;
   }
   else if(profitPercent > PortfolioMaxProfitPercent)
   {
      Print("PORTFOLIO MAX PROFIT: Closing all trades at ", DoubleToString(profitPercent, 2), "% profit ($", DoubleToString(totalProfit, 2), ")");
      CloseAllTrades("Portfolio Max Profit: " + DoubleToString(profitPercent, 2) + "%");
      return;
   }
}

void CheckIndividualTradeExitRules()
{
   // Ultra-fast profit detection - close immediately on ANY profit, never on loss
   for(int i = totalOpenTrades - 1; i >= 0; i--)
   {
      if(openTrades[i].ticket > 0)
      {
         if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))
         {
            double tradeProfit = OrderProfit() + OrderSwap() + OrderCommission();
            
            // Close IMMEDIATELY on ANY profit (even $0.01)
            if(tradeProfit > 0)
            {
               double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;
               double volume = OrderLots();
               bool closed = OrderClose(openTrades[i].ticket, volume, closePrice, 3, clrYellow);
               
               if(closed)
               {
                  Print("INSTANT PROFIT EXIT: Trade #", openTrades[i].ticket, " closed at $", DoubleToString(tradeProfit, 2), " profit");
                  dailyProfit += tradeProfit;
                  RemoveTradeFromArray(i);
               }
            }
            // Do NOT close on loss - let trades run
         }
      }
   }
}

void OpenBurstTrades()
{
   int direction = GetFastScalpingSignal();

   if(direction == -1)
      return;

   // Open ONE trade with MAXIMUM lot size - keep it simple
   // Will be called continuously by OnTick, so trades open as fast as possible
   OpenTrade(direction);
}

int GetFastScalpingSignal()
{

   if(BuyBiased)
   {

      int random = MathRand() % 10;
      if(random < 7)
         return OP_BUY;
      else
         return OP_SELL;
   }
   else
   {

      if(totalOpenTrades == 0)
         return OP_BUY;

      if(openTrades[totalOpenTrades - 1].orderType == OP_BUY)
         return OP_SELL;
      else
         return OP_BUY;
   }
}

void OpenTrade(int orderType)
{
   double price = (orderType == OP_BUY) ? Ask : Bid;
   double lotSize = CalculateDynamicLotSize();

   double sl = 0, tp = 0;

   string comment = StringConcatenate("Basket #", (totalOpenTrades + 1));
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

      lastTradeBar = TimeCurrent();
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
   // Simple: just check if we have margin and haven't hit max trades
   // Open continuously - close on profit, open new ones
   
   if(totalOpenTrades >= MaxConcurrentTrades)
      return false;

   // Check if we have enough free margin for maximum lot size trade
   double lotSize = CalculateDynamicLotSize();
   double marginRequired = MarketInfo(Symbol(), MODE_MARGINREQUIRED) * lotSize;
   if(marginRequired <= 0)
      marginRequired = AccountBalance() * 0.1; // Fallback
   
   if(AccountFreeMargin() < marginRequired)
      return false;

   return true;
}

bool HasOverallProfit()
{
   double currentBalance = AccountBalance();
   if(accountStartBalance <= 0)
      return true;
   
   double profitPercent = ((currentBalance - accountStartBalance) / accountStartBalance) * 100.0;
   return (profitPercent >= 0);
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

   status = StringConcatenate(
      "==== FastBasketScalper v1.00 ====\n",
      "Status: ", (tradingAllowed && !drawdownTriggered ? "ACTIVE" : "PAUSED"), "\n",
      "----------------------------\n",
      "Open Trades: ", totalOpenTrades, " / ", MaxBasketSize, "\n",
      "Portfolio P&L: $", DoubleToString(portfolioProfit, 2), " (", DoubleToString(portfolioProfitPercent, 2), "%)\n",
      "Target Range: ", PortfolioMinProfitPercent, "% - ", PortfolioMaxProfitPercent, "%\n",
      "----------------------------\n",
      "Daily P&L: $", DoubleToString(dailyProfit, 2), "\n",
      "Balance: $", DoubleToString(currentBalance, 2), " | Equity: $", DoubleToString(currentEquity, 2), "\n",
      "Drawdown: ", DoubleToString(drawdownPercent, 1), "% (Max: ", MaxDrawdownPercent, "%)\n",
      "Spread: ", DoubleToString(GetCurrentSpread(), 1), " points\n",
      "Lot Size: ", DoubleToString(currentLotSize, 2)
   );

   Comment(status);
}

