

#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https:
#property version   "3.00"
#property strict

input group "===== Dynamic Lot Sizing ====="
input double   AccountBalance_10K  = 10000.0;
input double   AccountBalance_100  = 100.0;
input double   AccountBalance_1500 = 1500.0;
input double   MinLotSize          = 0.01;
input double   MaxLotSizeLimit     = 1.0;

input group "===== Core Trading Settings ====="
input int      MaxBasketSize       = 10;
input int      MinBasketSize       = 2;
input int      MagicNumber         = 202504;
input int      MaxConcurrentTrades = 15;

input group "===== Loss Protection (V3) ====="
input double   PortfolioHealthThreshold = -0.3;
input double   BasketLossLimit = -0.5;
input int      CooldownAfterLoss = 60;

input group "===== Progressive Profit Exits (V3) ====="
input double   ProfitLevel1 = 0.5;
input double   ProfitLevel2 = 1.0;
input double   ProfitLevel3 = 2.0;
input bool     UseProgressiveExits = true;

input group "===== Trailing Stop Loss (V3) ====="
input bool     UseTrailingStop = true;
input double   TrailingStartPercent = 1.0;
input double   TrailingStepPercent = 0.2;

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

input group "===== Trading Controls ====="
input bool     TradeEnabled        = true;
input int      MinBarsBetweenEntry = 1;
input int      EntryBurstCount     = 3;
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

datetime    lastBasketCloseTime = 0;
bool        inCooldownPeriod = false;

double      basketHighestProfit = 0;
double      trailingStopLevel = 0;
bool        trailingStopActive = false;

int OnInit()
{
   Print("========================================");
   Print("FastBasketScalper V3.00 - PROTECTED");
   Print("========================================");
   Print("Strategy: Candle Position + Loss Protection + Trailing Stop");
   Print("Symbol: ", Symbol());
   Print("Timeframe: ", Period());

   if(AllowIndices)
   {
      string sym = Symbol();
      if(StringFind(sym, "US30") < 0 && StringFind(sym, "US100") < 0 &&
         StringFind(sym, "DSX") < 0 && StringFind(sym, "NAS") < 0 &&
         StringFind(sym, "DOW") < 0 && StringFind(sym, "SPX") < 0)
      {
         Print("WARNING: EA optimized for US indices. Current: ", sym);
      }
   }

   totalOpenTrades = 0;
   accountStartBalance = AccountBalance();
   tradesOpenedInBurst = 0;
   inCooldownPeriod = false;
   basketHighestProfit = 0;
   trailingStopLevel = 0;
   trailingStopActive = false;

   for(int i = 0; i < 100; i++)
   {
      openTrades[i].ticket = -1;
      openTrades[i].entryPrice = 0;
      openTrades[i].lotSize = 0;
      openTrades[i].openTime = 0;
      openTrades[i].orderType = -1;
   }

   Print("========================================");
   Print("V3 PROTECTIONS:");
   Print("Loss Limit: ", BasketLossLimit, "% | Health Threshold: ", PortfolioHealthThreshold, "%");
   Print("Cooldown: ", CooldownAfterLoss, " seconds");
   Print("Progressive Exits: ", (UseProgressiveExits ? "ENABLED" : "DISABLED"));
   Print("  Level 1: ", ProfitLevel1, "% | Level 2: ", ProfitLevel2, "% | Level 3: ", ProfitLevel3, "%");
   Print("Trailing Stop: ", (UseTrailingStop ? "ENABLED" : "DISABLED"));
   Print("  Start: ", TrailingStartPercent, "% | Step: ", TrailingStepPercent, "%");
   Print("Burst Size: ", EntryBurstCount, " trades (reduced)");
   Print("========================================");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("FastBasketScalper V3.00 Deinitialized. Reason: ", reason);
}

void OnTick()
{
   if(!CheckDrawdownProtection())
   {
      CloseAllTrades("Drawdown Protection - 25% Limit");
      Comment("DRAWDOWN LIMIT REACHED!");
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

double CalculatePortfolioProfit()
{
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
   return totalProfit;
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
      Comment("DAILY LOSS LIMIT REACHED: ", DoubleToString(dailyProfit, 2));
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
      return MathMin(MaxLotSizeLimit, 1.0);
   else if(currentBalance >= AccountBalance_1500)
      return MathMin(MaxLotSizeLimit, 0.5);
   else if(currentBalance >= AccountBalance_100)
      return MathMin(MaxLotSizeLimit, 0.2);
   else
      return MinLotSize;
}

bool IsSpreadAcceptable()
{
   return (GetCurrentSpread() <= MaxSpreadPips);
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
   {
      basketHighestProfit = 0;
      trailingStopLevel = 0;
      trailingStopActive = false;
      return;
   }

   double totalProfit = CalculatePortfolioProfit();
   double profitPercent = (totalProfit / accountStartBalance) * 100.0;

   if(profitPercent > basketHighestProfit)
      basketHighestProfit = profitPercent;

   if(profitPercent <= BasketLossLimit)
   {
      Print("BASKET LOSS LIMIT: ", DoubleToString(profitPercent, 2), "% (Limit: ", BasketLossLimit, "%)");
      CloseAllTrades("Loss Limit: " + DoubleToString(profitPercent, 2) + "%");
      inCooldownPeriod = true;
      lastBasketCloseTime = TimeCurrent();
      ResetBasketTracking();
      return;
   }

   if(UseTrailingStop && profitPercent >= TrailingStartPercent)
   {
      if(!trailingStopActive)
      {
         trailingStopActive = true;
         trailingStopLevel = profitPercent - TrailingStepPercent;
         Print("TRAILING STOP ACTIVATED at ", DoubleToString(profitPercent, 2), "% | Stop: ", DoubleToString(trailingStopLevel, 2), "%");
      }
      else
      {

         double newStopLevel = basketHighestProfit - TrailingStepPercent;
         if(newStopLevel > trailingStopLevel)
         {
            trailingStopLevel = newStopLevel;
            Print("TRAILING STOP UPDATED to ", DoubleToString(trailingStopLevel, 2), "% | Peak: ", DoubleToString(basketHighestProfit, 2), "%");
         }

         if(profitPercent <= trailingStopLevel)
         {
            Print("TRAILING STOP HIT: Current ", DoubleToString(profitPercent, 2), "% <= Stop ", DoubleToString(trailingStopLevel, 2), "%");
            CloseAllTrades("Trailing Stop: " + DoubleToString(profitPercent, 2) + "%");
            ResetBasketTracking();
            return;
         }
      }
   }

   if(UseProgressiveExits)
   {

      if(profitPercent >= ProfitLevel3)
      {
         Print("MAX PROFIT TARGET: ", DoubleToString(profitPercent, 2), "%");
         CloseAllTrades("Max Profit L3: " + DoubleToString(profitPercent, 2) + "%");
         ResetBasketTracking();
         return;
      }

      if(basketHighestProfit >= ProfitLevel2)
      {
         double protectionLevel = ProfitLevel2 * 0.75;
         if(profitPercent < protectionLevel)
         {
            Print("PROGRESSIVE EXIT L2: Peaked ", DoubleToString(basketHighestProfit, 2), "%, now ", DoubleToString(profitPercent, 2), "%");
            CloseAllTrades("Progressive L2: " + DoubleToString(profitPercent, 2) + "%");
            ResetBasketTracking();
            return;
         }
      }

      if(basketHighestProfit >= ProfitLevel1 && basketHighestProfit < ProfitLevel2)
      {
         double protectionLevel = ProfitLevel1 * 0.70;
         if(profitPercent < protectionLevel)
         {
            Print("PROGRESSIVE EXIT L1: Peaked ", DoubleToString(basketHighestProfit, 2), "%, now ", DoubleToString(profitPercent, 2), "%");
            CloseAllTrades("Progressive L1: " + DoubleToString(profitPercent, 2) + "%");
            ResetBasketTracking();
            return;
         }
      }
   }

   if(totalOpenTrades >= MaxBasketSize && profitPercent < -1.0)
   {
      Print("EMERGENCY EXIT: Basket full, ", DoubleToString(profitPercent, 2), "% loss");
      CloseAllTrades("Emergency Exit");
      inCooldownPeriod = true;
      lastBasketCloseTime = TimeCurrent();
      ResetBasketTracking();
      return;
   }
}

void ResetBasketTracking()
{
   basketHighestProfit = 0;
   trailingStopLevel = 0;
   trailingStopActive = false;
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
   double lotSize = CalculateDynamicLotSize();

   double sl = 0, tp = 0;

   string comment = "BasketV3 #" + IntegerToString(totalOpenTrades + 1);
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
            }
         }

         RemoveTradeFromArray(i);
      }
   }

   dailyProfit += totalPL;
   double profitPercent = (totalPL / accountStartBalance) * 100.0;

   Print("CLOSED: ", closedCount, " trades | P&L: $", DoubleToString(totalPL, 2), " (", DoubleToString(profitPercent, 2), "%)");
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

   if(inCooldownPeriod)
   {
      if(TimeCurrent() - lastBasketCloseTime < CooldownAfterLoss)
      {
         return false;
      }
      else
      {
         inCooldownPeriod = false;
         Print("Cooldown ended. Ready to trade.");
      }
   }

   if(totalOpenTrades > 0)
   {
      double portfolioProfit = CalculatePortfolioProfit();
      double portfolioProfitPercent = (portfolioProfit / accountStartBalance) * 100.0;

      if(portfolioProfitPercent < PortfolioHealthThreshold)
      {
         Print("Health Check FAILED: ", DoubleToString(portfolioProfitPercent, 2), "% < ", PortfolioHealthThreshold, "%");
         return false;
      }
   }

   if(totalOpenTrades == 0)
      return true;

   return true;
}

void CheckDailyReset()
{
   datetime currentDay = iTime(Symbol(), PERIOD_D1, 0);

   if(currentDay != lastDayReset)
   {
      Print("Daily reset - Previous P&L: $", DoubleToString(dailyProfit, 2));
      dailyProfit = 0;
      lastDayReset = currentDay;
   }
}

void UpdateDisplay()
{
   double currentLotSize = CalculateDynamicLotSize();
   double currentBalance = AccountBalance();
   double currentEquity = AccountEquity();
   double drawdownPercent = ((accountStartBalance - currentEquity) / accountStartBalance) * 100.0;

   double portfolioProfit = CalculatePortfolioProfit();
   double portfolioProfitPercent = (portfolioProfit / accountStartBalance) * 100.0;

   double lastClose = iClose(Symbol(), PERIOD_M1, CandleLookback);
   double lastHigh = iHigh(Symbol(), PERIOD_M1, CandleLookback);
   double lastLow = iLow(Symbol(), PERIOD_M1, CandleLookback);
   double lastRange = lastHigh - lastLow;
   double lastClosePos = (lastRange > 0) ? ((lastClose - lastLow) / lastRange) * 100.0 : 0;

   string trailingInfo = "OFF";
   if(trailingStopActive)
      trailingInfo = "ACTIVE @ " + DoubleToString(trailingStopLevel, 2) + "%";

   string status = "==== FastBasketScalper V3.00 (PROTECTED) ====\n";
   status += "Status: " + (tradingAllowed && !drawdownTriggered ? "ACTIVE" : "PAUSED") + "\n";
   status += "Strategy: Candle + Loss Protection + Trailing\n";
   status += "----------------------------\n";
   status += "Last Candle: " + DoubleToString(lastClosePos, 1) + "% (BUY>=" + DoubleToString(BuyCloseThreshold, 0) + "%, SELL<=" + DoubleToString(SellCloseThreshold, 0) + "%)\n";
   status += "----------------------------\n";
   status += "BASKET STATUS:\n";
   status += "Open Trades: " + IntegerToString(totalOpenTrades) + " / " + IntegerToString(MaxBasketSize) + "\n";
   status += "Portfolio P&L: $" + DoubleToString(portfolioProfit, 2) + " (" + DoubleToString(portfolioProfitPercent, 2) + "%)\n";
   status += "Highest: " + DoubleToString(basketHighestProfit, 2) + "% | Trailing: " + trailingInfo + "\n";
   status += "----------------------------\n";
   status += "PROTECTIONS:\n";
   status += "Health: " + DoubleToString(portfolioProfitPercent, 2) + "% (Threshold: " + DoubleToString(PortfolioHealthThreshold, 1) + "%)\n";
   status += "Loss Limit: " + DoubleToString(BasketLossLimit, 1) + "% | Cooldown: " + (inCooldownPeriod ? "ACTIVE" : "OFF") + "\n";
   status += "Progressive: L1=" + DoubleToString(ProfitLevel1, 1) + "% | L2=" + DoubleToString(ProfitLevel2, 1) + "% | L3=" + DoubleToString(ProfitLevel3, 1) + "%\n";
   status += "----------------------------\n";
   status += "ACCOUNT:\n";
   status += "Daily P&L: $" + DoubleToString(dailyProfit, 2) + "\n";
   status += "Balance: $" + DoubleToString(currentBalance, 2) + " | Equity: $" + DoubleToString(currentEquity, 2) + "\n";
   status += "Drawdown: " + DoubleToString(drawdownPercent, 1) + "% (Max: " + DoubleToString(MaxDrawdownPercent, 0) + "%)\n";
   status += "Spread: " + DoubleToString(GetCurrentSpread(), 1) + " | Lot: " + DoubleToString(currentLotSize, 2);

   Comment(status);
}

