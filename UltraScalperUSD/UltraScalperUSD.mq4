

#property copyright "Copyright 2025"
#property version   "1.00"
#property strict

input group "===== Trading Pairs ====="
input bool     TradeEURUSD         = true;
input bool     TradeGBPUSD         = true;
input bool     TradeUSDJPY         = true;
input bool     TradeAUDUSD         = true;
input bool     TradeUSDCAD         = true;
input bool     TradeNZDUSD         = true;
input bool     TradeEURGBP         = true;

input group "===== Ultra-Fast Settings ====="
input double   FixedLotSize        = 0.01;
input int      QuickProfitPips     = 3;
input int      StopLossPips        = 8;
input int      TradeIntervalSec    = 5;
input int      MaxConcurrentTrades = 10;
input double   MaxSpreadPips       = 4.0;
input int      MagicNumber         = 999999;

input group "===== Exit Strategy ====="
input bool     CloseIndividually   = true;
input double   BasketProfitUSD     = 5.0;
input double   BasketLossUSD       = 10.0;

input group "===== Safety Limits ====="
input double   MaxDailyLossUSD     = 50.0;
input double   DailyProfitTargetUSD= 100.0;
input int      MaxTradesPerDay     = 1000;
input int      StartHour           = 0;
input int      EndHour             = 23;

string tradingPairs[];
int totalPairs = 0;
datetime lastTradeTime = 0;
double dailyProfit = 0;
int dailyTradeCount = 0;
int dailyWins = 0;
int dailyLosses = 0;
datetime lastDayReset = 0;
bool tradingEnabled = true;
double dailyStartEquity = 0;

struct UltraFastTrade {
   int ticket;
   string symbol;
   int direction;
   double openPrice;
   datetime openTime;
   double highestProfit;
};

UltraFastTrade activeTrades[];

int OnInit()
{
   Print("========================================");
   Print("ULTRA-FAST USD SCALPER v1.00");
   Print("========================================");

   MathSrand((int)TimeLocal());

   ArrayResize(tradingPairs, 0);
   if(TradeEURUSD) AddPair("EURUSD");
   if(TradeGBPUSD) AddPair("GBPUSD");
   if(TradeUSDJPY) AddPair("USDJPY");
   if(TradeAUDUSD) AddPair("AUDUSD");
   if(TradeUSDCAD) AddPair("USDCAD");
   if(TradeNZDUSD) AddPair("NZDUSD");
   if(TradeEURGBP) AddPair("EURGBP");

   totalPairs = ArraySize(tradingPairs);

   Print("Trading Pairs: ", totalPairs);
   for(int i = 0; i < totalPairs; i++)
   {
      if(MarketInfo(tradingPairs[i], MODE_BID) > 0)
         Print("  [", i+1, "] ", tradingPairs[i], " - OK");
      else
         Print("  [", i+1, "] ", tradingPairs[i], " - WARNING: Not in Market Watch!");
   }

   if(totalPairs < 3)
   {
      Alert("WARNING: Enable at least 3 pairs!");
      return(INIT_FAILED);
   }

   Print("========================================");
   Print("LOT SIZE: ", DoubleToString(FixedLotSize, 2), " (FIXED)");
   Print("QUICK EXIT: ", QuickProfitPips, " pips | SL: ", StopLossPips, " pips");
   Print("Trade Interval: ", TradeIntervalSec, " seconds (LIGHTNING!)");
   Print("Max Concurrent: ", MaxConcurrentTrades, " trades");
   Print("Basket Limits: +", BasketProfitUSD, " USD profit | -", BasketLossUSD, " USD loss");
   Print("Daily Limits: +", DailyProfitTargetUSD, " USD profit | -", MaxDailyLossUSD, " USD loss");
   Print("========================================");

   ArrayResize(activeTrades, 0);
   lastDayReset = iTime(Symbol(), PERIOD_D1, 0);
   dailyStartEquity = AccountEquity();

   return(INIT_SUCCEEDED);
}

void OnTick()
{
   CheckDailyReset();
   CheckDailyLimits();

   ManageActiveTrades();

   if(tradingEnabled && ArraySize(activeTrades) < MaxConcurrentTrades)
   {
      if(TimeCurrent() - lastTradeTime >= TradeIntervalSec)
      {
         OpenUltraFastTrade();
         lastTradeTime = TimeCurrent();
      }
   }

   UpdateDisplay();
}

void CheckDailyReset()
{
   datetime currentDay = iTime(Symbol(), PERIOD_D1, 0);

   if(currentDay != lastDayReset)
   {
      Print("========================================");
      Print("DAILY RESET - Previous: ", dailyTradeCount, " trades | ",
            dailyWins, "W/", dailyLosses, "L | P&L: ", DoubleToString(dailyProfit, 2), " USD");
      Print("========================================");

      dailyProfit = 0;
      dailyTradeCount = 0;
      dailyWins = 0;
      dailyLosses = 0;
      lastDayReset = currentDay;
      dailyStartEquity = AccountEquity();
      tradingEnabled = true;
   }
}

void CheckDailyLimits()
{
   if(!tradingEnabled) return;

   if(dailyTradeCount >= MaxTradesPerDay)
   {
      tradingEnabled = false;
      Alert("Max trades per day reached (", MaxTradesPerDay, ")");
      return;
   }

   if(dailyProfit >= DailyProfitTargetUSD)
   {
      tradingEnabled = false;
      Alert("SUCCESS! Daily profit target reached: +", DoubleToString(dailyProfit, 2), " USD");
      CloseAllTrades("Daily Profit Target");
      return;
   }

   if(dailyProfit <= -MaxDailyLossUSD)
   {
      tradingEnabled = false;
      Alert("STOP! Daily loss limit hit: ", DoubleToString(dailyProfit, 2), " USD");
      CloseAllTrades("Daily Loss Limit");
      return;
   }
}

void AddPair(string pair)
{
   int size = ArraySize(tradingPairs);
   ArrayResize(tradingPairs, size + 1);
   tradingPairs[size] = pair;
}

void OpenUltraFastTrade()
{

   int currentHour = Hour();
   if(currentHour < StartHour || currentHour >= EndHour)
      return;

   string selectedPair = "";
   int attempts = 0;

   while(selectedPair == "" && attempts < 20)
   {
      int randomIndex = MathRand() % totalPairs;
      string pair = tradingPairs[randomIndex];

      double spread = GetSpreadPips(pair);
      if(spread <= MaxSpreadPips && spread > 0)
      {
         selectedPair = pair;
      }
      attempts++;
   }

   if(selectedPair == "")
      return;

   int direction = GetUltraFastSignal(selectedPair);
   if(direction < 0)
      direction = (MathRand() % 2 == 0) ? OP_BUY : OP_SELL;

   double price = (direction == OP_BUY) ? MarketInfo(selectedPair, MODE_ASK) : MarketInfo(selectedPair, MODE_BID);
   double point = MarketInfo(selectedPair, MODE_POINT);
   int digits = (int)MarketInfo(selectedPair, MODE_DIGITS);

   if(digits == 5 || digits == 3)
      point *= 10;

   double sl = 0, tp = 0;
   if(direction == OP_BUY)
   {
      sl = price - (StopLossPips * point);
      tp = price + (QuickProfitPips * point);
   }
   else
   {
      sl = price + (StopLossPips * point);
      tp = price - (QuickProfitPips * point);
   }

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   color arrowColor = (direction == OP_BUY) ? clrLime : clrRed;
   int ticket = OrderSend(selectedPair, direction, FixedLotSize, price, 3, sl, tp,
                          "UltraUSD", MagicNumber, 0, arrowColor);

   if(ticket > 0)
   {

      int size = ArraySize(activeTrades);
      ArrayResize(activeTrades, size + 1);

      activeTrades[size].ticket = ticket;
      activeTrades[size].symbol = selectedPair;
      activeTrades[size].direction = direction;
      activeTrades[size].openPrice = price;
      activeTrades[size].openTime = TimeCurrent();
      activeTrades[size].highestProfit = 0;
   }
}

int GetUltraFastSignal(string symbol)
{

   double price1 = iClose(symbol, PERIOD_M1, 0);
   double price2 = iClose(symbol, PERIOD_M1, 1);

   if(price1 > price2)
      return OP_BUY;
   else if(price1 < price2)
      return OP_SELL;

   return -1;
}

void ManageActiveTrades()
{

   double totalPL = 0;
   int activeCount = 0;

   for(int i = 0; i < ArraySize(activeTrades); i++)
   {
      if(activeTrades[i].ticket > 0)
      {
         if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
         {
            if(OrderCloseTime() == 0)
            {
               double pl = OrderProfit() + OrderSwap() + OrderCommission();
               totalPL += pl;
               activeCount++;
            }
         }
      }
   }

   if(totalPL >= BasketProfitUSD)
   {
      CloseAllTrades("Basket Profit Target");
      return;
   }

   if(totalPL <= -BasketLossUSD)
   {
      CloseAllTrades("Basket Loss Limit");
      return;
   }

   if(CloseIndividually)
   {
      for(int i = ArraySize(activeTrades) - 1; i >= 0; i--)
      {
         if(activeTrades[i].ticket > 0)
         {
            if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
            {
               if(OrderCloseTime() > 0)
               {

                  TrackClosedTrade(OrderProfit() + OrderSwap() + OrderCommission());
                  RemoveTradeAtIndex(i);
                  continue;
               }

               double currentPrice = (OrderType() == OP_BUY) ? MarketInfo(OrderSymbol(), MODE_BID) : MarketInfo(OrderSymbol(), MODE_ASK);
               double point = MarketInfo(OrderSymbol(), MODE_POINT);
               int digits = (int)MarketInfo(OrderSymbol(), MODE_DIGITS);

               if(digits == 5 || digits == 3)
                  point *= 10;

               double profitPips = 0;
               if(OrderType() == OP_BUY)
                  profitPips = (currentPrice - OrderOpenPrice()) / point;
               else
                  profitPips = (OrderOpenPrice() - currentPrice) / point;

               if(profitPips >= QuickProfitPips)
               {
                  double closePrice = (OrderType() == OP_BUY) ? MarketInfo(OrderSymbol(), MODE_BID) : MarketInfo(OrderSymbol(), MODE_ASK);

                  if(closePrice > 0)
                  {
                     bool closed = OrderClose(OrderTicket(), OrderLots(), closePrice, 3, clrGold);

                     if(closed)
                     {
                        TrackClosedTrade(OrderProfit() + OrderSwap() + OrderCommission());
                        RemoveTradeAtIndex(i);
                     }
                  }
               }
            }
            else
            {

               RemoveTradeAtIndex(i);
            }
         }
      }
   }
   else
   {

      CleanClosedTrades();
   }
}

double GetSpreadPips(string symbol)
{
   double ask = MarketInfo(symbol, MODE_ASK);
   double bid = MarketInfo(symbol, MODE_BID);
   double point = MarketInfo(symbol, MODE_POINT);
   int digits = (int)MarketInfo(symbol, MODE_DIGITS);

   if(ask == 0 || bid == 0 || point == 0) return 999;

   double spread = (ask - bid) / point;

   if(digits == 5 || digits == 3)
      spread = spread / 10.0;

   return spread;
}

void CleanClosedTrades()
{
   for(int i = ArraySize(activeTrades) - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket > 0)
      {
         if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
         {
            if(OrderCloseTime() > 0)
            {

               TrackClosedTrade(OrderProfit() + OrderSwap() + OrderCommission());
               RemoveTradeAtIndex(i);
            }
         }
         else
         {
            RemoveTradeAtIndex(i);
         }
      }
   }
}

void TrackClosedTrade(double pl)
{
   dailyProfit += pl;
   dailyTradeCount++;

   if(pl > 0)
      dailyWins++;
   else
      dailyLosses++;
}

void CloseAllTrades(string reason)
{
   Print("========================================");
   Print("CLOSING ALL TRADES: ", reason);
   Print("========================================");

   for(int i = ArraySize(activeTrades) - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket > 0)
      {
         if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
         {
            if(OrderCloseTime() == 0)
            {
               double closePrice = (OrderType() == OP_BUY) ? MarketInfo(OrderSymbol(), MODE_BID) : MarketInfo(OrderSymbol(), MODE_ASK);

               if(closePrice > 0)
               {
                  bool closed = OrderClose(activeTrades[i].ticket, OrderLots(), closePrice, 5, clrYellow);

                  if(closed)
                  {
                     TrackClosedTrade(OrderProfit() + OrderSwap() + OrderCommission());
                  }
               }
            }
         }

         RemoveTradeAtIndex(i);
      }
   }

   Print("All trades closed");
}

void RemoveTradeAtIndex(int index)
{
   int size = ArraySize(activeTrades);

   for(int i = index; i < size - 1; i++)
   {
      activeTrades[i] = activeTrades[i + 1];
   }

   ArrayResize(activeTrades, size - 1);
}

void UpdateDisplay()
{
   int activeCount = ArraySize(activeTrades);
   int nextTrade = (int)(TradeIntervalSec - (TimeCurrent() - lastTradeTime));
   if(nextTrade < 0) nextTrade = 0;

   double currentPL = 0;
   for(int i = 0; i < activeCount; i++)
   {
      if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
      {
         if(OrderCloseTime() == 0)
            currentPL += OrderProfit() + OrderSwap() + OrderCommission();
      }
   }

   double winRate = (dailyTradeCount > 0) ? (dailyWins * 100.0 / dailyTradeCount) : 0;

   string exitMode = CloseIndividually ? "INDIVIDUAL" : "BASKET ONLY";

   string status = "⚡💵 ULTRA-FAST USD SCALPER 💵⚡\n";
   status += "Status: " + (tradingEnabled ? "ACTIVE ✓" : "STOPPED ✗") + " | Mode: " + exitMode + "\n";
   status += "========================================\n";
   status += "Active: " + IntegerToString(activeCount) + "/" + IntegerToString(MaxConcurrentTrades);
   status += " | Next: " + IntegerToString(nextTrade) + "s\n";
   status += "Current P&L: " + DoubleToString(currentPL, 2) + " USD\n";
   status += "Basket Limits: +" + DoubleToString(BasketProfitUSD, 2) + " | -" + DoubleToString(BasketLossUSD, 2) + " USD\n";
   status += "========================================\n";
   status += "TODAY: " + IntegerToString(dailyTradeCount) + " trades | ";
   status += IntegerToString(dailyWins) + "W/" + IntegerToString(dailyLosses) + "L (";
   status += DoubleToString(winRate, 1) + "%)\n";
   status += "Daily P&L: " + DoubleToString(dailyProfit, 2) + " USD\n";
   status += "Target: +" + DoubleToString(DailyProfitTargetUSD, 0) + " | Limit: -" + DoubleToString(MaxDailyLossUSD, 0) + " USD\n";
   status += "========================================\n";
   status += "Lot: " + DoubleToString(FixedLotSize, 2) + " (FIXED) | Quick Exit: " + IntegerToString(QuickProfitPips) + " pips\n";
   status += "SL: " + IntegerToString(StopLossPips) + " pips | Interval: " + IntegerToString(TradeIntervalSec) + "s ⚡";

   Comment(status);
}

