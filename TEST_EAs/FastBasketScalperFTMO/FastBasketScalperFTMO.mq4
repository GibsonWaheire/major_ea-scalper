

#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"
#property strict

input group "===== FTMO CHALLENGE SETTINGS ====="
input double   InitialBalance      = 100000.0;
input double   DailyLossPercent    = 5.0;
input double   MaxDrawdownPercent  = 10.0;
input double   ProfitTargetPercent = 10.0;
input bool     IsChallengePhase    = true;

input group "===== FTMO LOT SIZING ====="
input double   RiskPerTradePercent = 0.5;
input double   MaxLotSize          = 0.5;
input double   MinLotSize          = 0.01;
input int      MaxConcurrentTrades = 5;

input group "===== PORTFOLIO TARGETS (%) ====="
input double   QuickExitPercent    = 0.5;
input double   MainExitPercent     = 1.0;
input double   MaxExitPercent      = 2.0;

input group "===== BASKET SETTINGS ====="
input int      MaxBasketSize       = 5;
input int      MinBasketSize       = 2;
input int      EntryBurstCount     = 3;
input int      MagicNumber         = 202599;

input group "===== CANDLE STRATEGY ====="
input double   BuyCloseThreshold   = 70.0;
input double   SellCloseThreshold  = 30.0;
input double   MinCandleBodyPercent = 60.0;
input bool     RequireStrongCandle = true;
input int      CandleLookback      = 1;

input group "===== TRADING CONTROLS ====="
input bool     TradeEnabled        = true;
input int      MinBarsBetweenEntry = 2;
input double   MaxSpreadPips       = 3.0;
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

double      accountStartBalance = 0;
double      dailyStartEquity = 0;
double      currentDailyPL = 0;
double      totalPL = 0;
datetime    lastDayReset = 0;

double      dailyLossLimit = 0;
double      maxDrawdownLimit = 0;
double      profitTarget = 0;

bool        tradingAllowed = true;
bool        dailyLimitHit = false;
bool        maxDrawdownHit = false;
bool        profitTargetReached = false;
int         tradesOpenedInBurst = 0;

int OnInit()
{
   Print("========================================");
   Print("FTMO COMPLIANT BASKET SCALPER v1.00");
   Print("========================================");
   Print("FTMO Rules: 5% Daily Loss | 10% Max DD");
   Print("Symbol: ", Symbol());
   Print("Timeframe: ", Period());

   accountStartBalance = (InitialBalance > 0) ? InitialBalance : AccountBalance();
   dailyStartEquity = AccountEquity();

   dailyLossLimit = accountStartBalance * (DailyLossPercent / 100.0);
   maxDrawdownLimit = accountStartBalance * (MaxDrawdownPercent / 100.0);

   double targetPercent = IsChallengePhase ? ProfitTargetPercent : 5.0;
   profitTarget = accountStartBalance * (targetPercent / 100.0);

   totalOpenTrades = 0;
   currentDailyPL = 0;
   totalPL = 0;

   for(int i = 0; i < 100; i++)
   {
      openTrades[i].ticket = -1;
      openTrades[i].entryPrice = 0;
      openTrades[i].lotSize = 0;
      openTrades[i].openTime = 0;
      openTrades[i].orderType = -1;
   }

   Print("========================================");
   Print("FTMO SETTINGS:");
   Print("Initial Balance: $", DoubleToString(accountStartBalance, 2));
   Print("Daily Loss Limit: -$", DoubleToString(dailyLossLimit, 2), " (", DailyLossPercent, "%)");
   Print("Max Drawdown: -$", DoubleToString(maxDrawdownLimit, 2), " (", MaxDrawdownPercent, "%)");
   Print("Profit Target: +$", DoubleToString(profitTarget, 2), " (", targetPercent, "%)");
   Print("Phase: ", (IsChallengePhase ? "CHALLENGE" : "VERIFICATION"));
   Print("========================================");
   Print("RISK MANAGEMENT:");
   Print("Risk Per Trade: ", RiskPerTradePercent, "%");
   Print("Max Lot Size: ", MaxLotSize);
   Print("Max Basket Size: ", MaxBasketSize, " trades");
   Print("Portfolio Exits: ", QuickExitPercent, "% / ", MainExitPercent, "% / ", MaxExitPercent, "%");
   Print("========================================");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("========================================");
   Print("FTMO Scalper Deinitialized");
   Print("Final Total P&L: $", DoubleToString(totalPL, 2));
   Print("Daily P&L: $", DoubleToString(currentDailyPL, 2));
   Print("========================================");
}

void OnTick()
{

   CheckDailyReset();

   if(!CheckFTMOLimits())
   {
      if(!dailyLimitHit && !maxDrawdownHit)
      {
         CloseAllTrades("FTMO Limit Protection");
      }
      Comment("FTMO LIMIT HIT - Trading Stopped!");
      return;
   }

   if(!PreFlightChecks()) return;

   if(!IsSpreadAcceptable())
   {
      Comment("SPREAD TOO HIGH: ", DoubleToString(GetCurrentSpread(), 1), " pips");
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

bool CheckFTMOLimits()
{
   double currentEquity = AccountEquity();

   double dailyLoss = dailyStartEquity - currentEquity;

   double totalDrawdown = accountStartBalance - currentEquity;

   if(dailyLoss >= dailyLossLimit)
   {
      if(!dailyLimitHit)
      {
         dailyLimitHit = true;
         Alert("FTMO DAILY LOSS LIMIT HIT: -$", DoubleToString(dailyLoss, 2), " / -$", DoubleToString(dailyLossLimit, 2));
         Print("========================================");
         Print("FTMO VIOLATION: DAILY LOSS LIMIT");
         Print("Daily Loss: -$", DoubleToString(dailyLoss, 2));
         Print("Limit: -$", DoubleToString(dailyLossLimit, 2));
         Print("========================================");
      }
      return false;
   }

   if(totalDrawdown >= maxDrawdownLimit)
   {
      if(!maxDrawdownHit)
      {
         maxDrawdownHit = true;
         Alert("FTMO MAX DRAWDOWN HIT: -$", DoubleToString(totalDrawdown, 2), " / -$", DoubleToString(maxDrawdownLimit, 2));
         Print("========================================");
         Print("FTMO VIOLATION: MAX DRAWDOWN");
         Print("Total Drawdown: -$", DoubleToString(totalDrawdown, 2));
         Print("Limit: -$", DoubleToString(maxDrawdownLimit, 2));
         Print("========================================");
      }
      return false;
   }

   totalPL = currentEquity - accountStartBalance;
   if(totalPL >= profitTarget)
   {
      if(!profitTargetReached)
      {
         profitTargetReached = true;
         Alert("FTMO PROFIT TARGET REACHED: +$", DoubleToString(totalPL, 2));
         Print("========================================");
         Print("FTMO SUCCESS: PROFIT TARGET REACHED!");
         Print("Profit: +$", DoubleToString(totalPL, 2));
         Print("Target: +$", DoubleToString(profitTarget, 2));
         Print("========================================");
         CloseAllTrades("FTMO Profit Target Reached");
      }
      return false;
   }

   if(dailyLoss >= (dailyLossLimit * 0.80))
   {
      Print("WARNING: Approaching FTMO daily limit (80%). Closing positions...");
      CloseAllTrades("FTMO Protection: Approaching Daily Limit");
      Sleep(300000);
      return false;
   }

   return true;
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

double CalculateFTMOLotSize()
{

   double balance = AccountBalance();
   double riskAmount = balance * (RiskPerTradePercent / 100.0);

   double lotSize = riskAmount / 1000.0;

   lotSize = MathMax(lotSize, MinLotSize);
   lotSize = MathMin(lotSize, MaxLotSize);

   return NormalizeDouble(lotSize, 2);
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

void CheckPortfolioProfitAndClose()
{
   if(totalOpenTrades < MinBasketSize)
      return;

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

   double profitPercent = (portfolioProfit / accountStartBalance) * 100.0;

   if(profitPercent >= QuickExitPercent)
   {
      Print("QUICK EXIT: Portfolio +", DoubleToString(profitPercent, 2), "% ($", DoubleToString(portfolioProfit, 2), ")");
      CloseAllTrades("Quick Exit: " + DoubleToString(profitPercent, 2) + "%");
      return;
   }

   if(profitPercent >= MainExitPercent)
   {
      Print("MAIN EXIT: Portfolio +", DoubleToString(profitPercent, 2), "% ($", DoubleToString(portfolioProfit, 2), ")");
      CloseAllTrades("Main Exit: " + DoubleToString(profitPercent, 2) + "%");
      return;
   }

   if(profitPercent >= MaxExitPercent)
   {
      Print("MAX EXIT: Portfolio +", DoubleToString(profitPercent, 2), "% ($", DoubleToString(portfolioProfit, 2), ")");
      CloseAllTrades("Max Exit: " + DoubleToString(profitPercent, 2) + "%");
      return;
   }

   if(profitPercent <= -1.0)
   {
      Print("EMERGENCY EXIT: Portfolio ", DoubleToString(profitPercent, 2), "%");
      CloseAllTrades("Emergency Exit");
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
   Print("BURST: Opened ", tradesOpenedInBurst, " ", (direction == OP_BUY ? "BUY" : "SELL"), " trades");
}

int GetCandlePositionSignal()
{
   double open = iOpen(Symbol(), PERIOD_M1, CandleLookback);
   double close = iClose(Symbol(), PERIOD_M1, CandleLookback);
   double high = iHigh(Symbol(), PERIOD_M1, CandleLookback);
   double low = iLow(Symbol(), PERIOD_M1, CandleLookback);

   double range = high - low;
   if(range == 0) return -1;

   double closePosition = ((close - low) / range) * 100.0;
   double bodySize = MathAbs(close - open);
   double bodyPercent = (bodySize / range) * 100.0;

   bool strongCandle = (bodyPercent >= MinCandleBodyPercent);

   if(RequireStrongCandle && !strongCandle)
      return -1;

   if(closePosition >= BuyCloseThreshold && close > open)
   {
      Print("BUY Signal: Close ", DoubleToString(closePosition, 1), "% | Body ", DoubleToString(bodyPercent, 1), "%");
      return OP_BUY;
   }

   if(closePosition <= SellCloseThreshold && close < open)
   {
      Print("SELL Signal: Close ", DoubleToString(closePosition, 1), "% | Body ", DoubleToString(bodyPercent, 1), "%");
      return OP_SELL;
   }

   return -1;
}

void OpenTrade(int orderType)
{
   double price = (orderType == OP_BUY) ? Ask : Bid;
   double lotSize = CalculateFTMOLotSize();

   double sl = 0, tp = 0;

   string comment = StringConcatenate("FTMO #", (totalOpenTrades + 1));
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

   double totalProfitLoss = 0;
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
               totalProfitLoss += pl;
               closedCount++;
            }
         }

         RemoveTradeFromArray(i);
      }
   }

   currentDailyPL += totalProfitLoss;
   totalPL = AccountEquity() - accountStartBalance;

   Print("CLOSED: ", closedCount, " trades | P&L: $", DoubleToString(totalProfitLoss, 2));
   Print("Daily P&L: $", DoubleToString(currentDailyPL, 2));
   Print("Total P&L: $", DoubleToString(totalPL, 2));
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
      Print("========================================");
      Print("FTMO DAILY RESET");
      Print("Previous Day P&L: $", DoubleToString(currentDailyPL, 2));
      Print("Total P&L: $", DoubleToString(totalPL, 2));
      Print("========================================");

      dailyStartEquity = AccountEquity();
      currentDailyPL = 0;
      dailyLimitHit = false;
      lastDayReset = currentDay;

      Print("New Day Started | Equity: $", DoubleToString(dailyStartEquity, 2));
   }
}

void UpdateDisplay()
{
   double currentEquity = AccountEquity();
   double dailyLoss = dailyStartEquity - currentEquity;
   double totalDrawdown = accountStartBalance - currentEquity;

   double dailyLossPercent = (dailyLoss / dailyStartEquity) * 100.0;
   double totalDrawdownPercent = (totalDrawdown / accountStartBalance) * 100.0;

   totalPL = currentEquity - accountStartBalance;
   double totalPLPercent = (totalPL / accountStartBalance) * 100.0;

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

   string status = "==== FTMO COMPLIANT SCALPER ====\n";
   status += "Phase: " + (IsChallengePhase ? "CHALLENGE" : "VERIFICATION") + " | ";
   status += (tradingAllowed && !dailyLimitHit && !maxDrawdownHit ? "ACTIVE" : "STOPPED") + "\n";
   status += "========================================\n";
   status += "FTMO LIMITS:\n";
   status += "Daily Loss: " + DoubleToString(dailyLossPercent, 2) + "% / 5% ";
   status += "(−$" + DoubleToString(dailyLoss, 2) + " / −$" + DoubleToString(dailyLossLimit, 2) + ")\n";
   status += "Max DD: " + DoubleToString(totalDrawdownPercent, 2) + "% / 10% ";
   status += "(−$" + DoubleToString(totalDrawdown, 2) + " / −$" + DoubleToString(maxDrawdownLimit, 2) + ")\n";
   status += "Profit: " + DoubleToString(totalPLPercent, 2) + "% / " + (IsChallengePhase ? "10" : "5") + "% ";
   status += "($" + DoubleToString(totalPL, 2) + " / $" + DoubleToString(profitTarget, 2) + ")\n";
   status += "========================================\n";
   status += "PORTFOLIO:\n";
   status += "Open Trades: " + IntegerToString(totalOpenTrades) + " / " + IntegerToString(MaxBasketSize) + "\n";
   status += "Portfolio P&L: $" + DoubleToString(portfolioProfit, 2) + " (" + DoubleToString(portfolioProfitPercent, 2) + "%)\n";
   status += "Exits: " + DoubleToString(QuickExitPercent, 1) + "% / " + DoubleToString(MainExitPercent, 1) + "% / " + DoubleToString(MaxExitPercent, 1) + "%\n";
   status += "========================================\n";
   status += "ACCOUNT:\n";
   status += "Balance: $" + DoubleToString(AccountBalance(), 2) + " | Equity: $" + DoubleToString(currentEquity, 2) + "\n";
   status += "Daily P&L: $" + DoubleToString(currentDailyPL, 2) + "\n";
   status += "Spread: " + DoubleToString(GetCurrentSpread(), 1) + " pips";

   Comment(status);
}

