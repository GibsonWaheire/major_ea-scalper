

#property copyright "Copyright 2025"
#property link      "https://www.mcgibsdigitalsolutions.com"
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
input int      ProfitTargetPips    = 5;
input int      StopLossPips        = 8;
input int      TradeIntervalSec    = 10;
input int      MaxConcurrentTrades = 5;
input double   MaxSpreadPips       = 4.0;
input int      MagicNumber         = 888888;

input group "===== Safety Limits ====="
input double   MaxDailyLossKES     = 5000.0;
input double   DailyProfitTargetKES= 10000.0;
input int      MaxTradesPerDay     = 500;
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

struct FastTrade {
   int ticket;
   string symbol;
   datetime openTime;
};

FastTrade activeTrades[];

int OnInit()
{
   Print("========================================");
   Print("ULTRA-FAST SCALPER v1.00 - Lightning Speed!");
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
   Print("TP: ", ProfitTargetPips, " pips | SL: ", StopLossPips, " pips");
   Print("Trade Interval: ", TradeIntervalSec, " seconds (ULTRA-FAST!)");
   Print("Max Concurrent: ", MaxConcurrentTrades, " trades");
   Print("Daily Limits: +", DailyProfitTargetKES, " KES profit | -", MaxDailyLossKES, " KES loss");
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
   CleanClosedTrades();

   if(tradingEnabled && ArraySize(activeTrades) < MaxConcurrentTrades)
   {
      if(TimeCurrent() - lastTradeTime >= TradeIntervalSec)
      {
         OpenFastTrade();
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
            dailyWins, "W/", dailyLosses, "L | P&L: ", DoubleToString(dailyProfit, 2), " KES");
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

   if(dailyProfit >= DailyProfitTargetKES)
   {
      tradingEnabled = false;
      Alert("SUCCESS! Daily profit target reached: +", DoubleToString(dailyProfit, 2), " KES");
      CloseAllTrades();
      return;
   }

   if(dailyProfit <= -MaxDailyLossKES)
   {
      tradingEnabled = false;
      Alert("STOP! Daily loss limit hit: ", DoubleToString(dailyProfit, 2), " KES");
      CloseAllTrades();
      return;
   }
}

void AddPair(string pair)
{
   int size = ArraySize(tradingPairs);
   ArrayResize(tradingPairs, size + 1);
   tradingPairs[size] = pair;
}

void OpenFastTrade()
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

   int direction = GetFastSignal(selectedPair);
   if(direction < 0)
      return;

   double price = (direction == OP_BUY) ? MarketInfo(selectedPair, MODE_ASK) : MarketInfo(selectedPair, MODE_BID);
   double point = MarketInfo(selectedPair, MODE_POINT);
   int digits = (int)MarketInfo(selectedPair, MODE_DIGITS);

   if(digits == 5 || digits == 3)
      point *= 10;

   double sl = 0, tp = 0;
   if(direction == OP_BUY)
   {
      sl = price - (StopLossPips * point);
      tp = price + (ProfitTargetPips * point);
   }
   else
   {
      sl = price + (StopLossPips * point);
      tp = price - (ProfitTargetPips * point);
   }

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   color arrowColor = (direction == OP_BUY) ? clrLime : clrRed;
   int ticket = OrderSend(selectedPair, direction, FixedLotSize, price, 3, sl, tp,
                          "UltraFast", MagicNumber, 0, arrowColor);

   if(ticket > 0)
   {

      int size = ArraySize(activeTrades);
      ArrayResize(activeTrades, size + 1);

      activeTrades[size].ticket = ticket;
      activeTrades[size].symbol = selectedPair;
      activeTrades[size].openTime = TimeCurrent();

   }
}

int GetFastSignal(string symbol)
{

   double price1 = iClose(symbol, PERIOD_M1, 0);
   double price2 = iClose(symbol, PERIOD_M1, 1);
   double price3 = iClose(symbol, PERIOD_M1, 2);

   double momentum = price1 - price3;
   double recent = price1 - price2;

   if(momentum > 0 && recent > 0)
      return OP_BUY;

   if(momentum < 0 && recent < 0)
      return OP_SELL;

   if(MathRand() % 3 == 0)
      return (MathRand() % 2 == 0) ? OP_BUY : OP_SELL;

   return -1;
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

               double pl = OrderProfit() + OrderSwap() + OrderCommission();
               dailyProfit += pl;
               dailyTradeCount++;

               if(pl > 0)
                  dailyWins++;
               else
                  dailyLosses++;

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

void CloseAllTrades()
{
   for(int i = ArraySize(activeTrades) - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket > 0)
      {
         if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
         {
            double closePrice = (OrderType() == OP_BUY) ? MarketInfo(OrderSymbol(), MODE_BID) : MarketInfo(OrderSymbol(), MODE_ASK);

            if(closePrice > 0)
            {
               OrderClose(activeTrades[i].ticket, OrderLots(), closePrice, 5, clrYellow);
            }
         }
      }
   }

   ArrayResize(activeTrades, 0);
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
         currentPL += OrderProfit() + OrderSwap() + OrderCommission();
      }
   }

   double winRate = (dailyTradeCount > 0) ? (dailyWins * 100.0 / dailyTradeCount) : 0;

   string status = "⚡ ULTRA-FAST SCALPER ⚡\n";
   status += "Status: " + (tradingEnabled ? "ACTIVE ✓" : "STOPPED ✗") + "\n";
   status += "========================================\n";
   status += "Active: " + IntegerToString(activeCount) + "/" + IntegerToString(MaxConcurrentTrades);
   status += " | Next: " + IntegerToString(nextTrade) + "s\n";
   status += "Current P&L: " + DoubleToString(currentPL, 2) + " KES\n";
   status += "========================================\n";
   status += "TODAY: " + IntegerToString(dailyTradeCount) + " trades | ";
   status += IntegerToString(dailyWins) + "W/" + IntegerToString(dailyLosses) + "L (";
   status += DoubleToString(winRate, 1) + "%)\n";
   status += "Daily P&L: " + DoubleToString(dailyProfit, 2) + " KES\n";
   status += "Target: +" + DoubleToString(DailyProfitTargetKES, 0) + " | Limit: -" + DoubleToString(MaxDailyLossKES, 0) + "\n";
   status += "========================================\n";
   status += "Lot: " + DoubleToString(FixedLotSize, 2) + " (FIXED) | ";
   status += "TP: " + IntegerToString(ProfitTargetPips) + " | SL: " + IntegerToString(StopLossPips) + " pips\n";
   status += "Interval: " + IntegerToString(TradeIntervalSec) + "s ⚡";

   Comment(status);
}

