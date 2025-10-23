

#property copyright "Copyright 2025"
#property version   "1.00"
#property strict

input group "===== Trading Instruments ====="
input bool     TradeGold           = true;
input bool     TradeEURUSD         = true;
input bool     TradeGBPUSD         = true;
input bool     TradeUSDJPY         = true;
input bool     TradeOil            = true;

input group "===== Ultra-Fast Settings ====="
input double   FixedLotSize        = 0.02;
input int      MinTrades           = 2;
input int      MaxTrades           = 5;
input double   RiskRewardRatio     = 1.2;
input int      MaxBasketDuration   = 60;
input int      TicksBetweenBasket  = 3;

input group "===== Risk Settings ====="
input double   StopLossPips        = 10.0;
input double   MaxSpreadPips       = 4.0;
input int      MaxSlippagePips     = 3;

input group "===== Safety Limits ====="
input double   MaxDailyLossUSD     = 100.0;
input double   DailyProfitTargetUSD= 300.0;
input int      BaseMagicNumber     = 777000;

string tradingInstruments[];
int totalInstruments = 0;
int tickCounter = 0;
datetime basketOpenTime = 0;
double totalBasketRisk = 0;
double basketProfitTarget = 0;
bool basketActive = false;

double dailyProfit = 0;
int dailyTradeCount = 0;
int dailyWins = 0;
int dailyLosses = 0;
datetime lastDayReset = 0;
bool tradingEnabled = true;

struct BasketTrade {
   int ticket;
   string symbol;
   int direction;
   double openPrice;
   double sl;
   double risk;
   int magicNumber;
};

BasketTrade activeBasket[];

int OnInit()
{
   Print("========================================");
   Print("GOLD SCALPER PRO - BASKET MODE");
   Print("Ultra-Fast Tick-Based Scalping");
   Print("========================================");

   MathSrand((int)TimeLocal());

   ArrayResize(tradingInstruments, 0);
   if(TradeGold)
   {
      AddInstrument("XAUUSD");
      AddInstrument("GOLD");
   }
   if(TradeEURUSD) AddInstrument("EURUSD");
   if(TradeGBPUSD) AddInstrument("GBPUSD");
   if(TradeUSDJPY) AddInstrument("USDJPY");
   if(TradeOil)
   {
      AddInstrument("USOil");
      AddInstrument("UKOil");
   }

   totalInstruments = ArraySize(tradingInstruments);

   int validCount = 0;
   for(int i = 0; i < totalInstruments; i++)
   {
      if(MarketInfo(tradingInstruments[i], MODE_BID) > 0)
      {
         validCount++;
         Print("  ✓ ", tradingInstruments[i]);
      }
   }

   if(validCount < 2)
   {
      Alert("ERROR: Need at least 2 valid instruments!");
      return(INIT_FAILED);
   }

   Print("Valid Instruments: ", validCount);
   Print("Basket Size: ", MinTrades, "-", MaxTrades, " trades");
   Print("RRR: 1:", DoubleToString(RiskRewardRatio, 1), " (Close at ", DoubleToString(RiskRewardRatio * 100, 0), "% profit)");
   Print("Max Duration: ", MaxBasketDuration, " seconds");
   Print("Lot Size: ", DoubleToString(FixedLotSize, 2), " (FIXED)");
   Print("========================================");

   ArrayResize(activeBasket, 0);
   lastDayReset = iTime(Symbol(), PERIOD_D1, 0);
   basketActive = false;

   return(INIT_SUCCEEDED);
}

void OnTick()
{
   tickCounter++;

   CheckDailyReset();

   if(!tradingEnabled) return;
   CheckDailyLimits();

   if(basketActive)
   {
      ManageBasket();
      return;
   }

   if(tickCounter >= TicksBetweenBasket)
   {
      OpenBasket();
      tickCounter = 0;
   }
}

void AddInstrument(string instrument)
{
   int size = ArraySize(tradingInstruments);
   ArrayResize(tradingInstruments, size + 1);
   tradingInstruments[size] = instrument;
}

void OpenBasket()
{
   if(!tradingEnabled) return;

   ArrayResize(activeBasket, 0);
   totalBasketRisk = 0;

   int numTrades = MinTrades + (MathRand() % (MaxTrades - MinTrades + 1));

   int opened = 0;
   int attempts = 0;

   while(opened < numTrades && attempts < totalInstruments * 3)
   {
      int randomIndex = MathRand() % totalInstruments;
      string instrument = tradingInstruments[randomIndex];

      if(MarketInfo(instrument, MODE_BID) <= 0)
      {
         attempts++;
         continue;
      }

      double spread = GetSpreadPips(instrument);
      if(spread > MaxSpreadPips || spread <= 0)
      {
         attempts++;
         continue;
      }

      bool alreadySelected = false;
      for(int i = 0; i < opened; i++)
      {
         if(activeBasket[i].symbol == instrument)
         {
            alreadySelected = true;
            break;
         }
      }

      if(alreadySelected)
      {
         attempts++;
         continue;
      }

      int direction = GetFastSignal(instrument);
      if(direction < 0)
      {
         attempts++;
         continue;
      }

      if(OpenInstantTrade(instrument, direction, opened))
      {
         opened++;
      }

      attempts++;
   }

   if(opened >= MinTrades)
   {

      basketProfitTarget = totalBasketRisk * RiskRewardRatio;
      basketActive = true;
      basketOpenTime = TimeCurrent();

   }
   else
   {

      CloseBasket("Insufficient trades");
   }
}

bool OpenInstantTrade(string symbol, int direction, int index)
{
   double price = (direction == OP_BUY) ? MarketInfo(symbol, MODE_ASK) : MarketInfo(symbol, MODE_BID);
   double point = MarketInfo(symbol, MODE_POINT);
   int digits = (int)MarketInfo(symbol, MODE_DIGITS);

   if(digits == 5 || digits == 3)
      point *= 10;

   double sl = 0;
   if(direction == OP_BUY)
      sl = price - (StopLossPips * point);
   else
      sl = price + (StopLossPips * point);

   sl = NormalizeDouble(sl, digits);

   double tickValue = MarketInfo(symbol, MODE_TICKVALUE);
   double slPoints = StopLossPips * (digits == 5 || digits == 3 ? 10.0 : 1.0);
   double risk = FixedLotSize * slPoints * tickValue;

   int magic = BaseMagicNumber + index;

   color arrowColor = (direction == OP_BUY) ? clrLime : clrRed;
   int ticket = OrderSend(symbol, direction, FixedLotSize, price, MaxSlippagePips,
                          sl, 0, "Basket", magic, 0, arrowColor);

   if(ticket > 0)
   {

      int size = ArraySize(activeBasket);
      ArrayResize(activeBasket, size + 1);

      activeBasket[size].ticket = ticket;
      activeBasket[size].symbol = symbol;
      activeBasket[size].direction = direction;
      activeBasket[size].openPrice = price;
      activeBasket[size].sl = sl;
      activeBasket[size].risk = risk;
      activeBasket[size].magicNumber = magic;

      totalBasketRisk += risk;

      return true;
   }

   return false;
}

int GetFastSignal(string symbol)
{

   double price1 = iClose(symbol, PERIOD_M1, 0);
   double price2 = iClose(symbol, PERIOD_M1, 1);

   if(price1 > price2)
      return OP_BUY;
   else if(price1 < price2)
      return OP_SELL;

   return (MathRand() % 2 == 0) ? OP_BUY : OP_SELL;
}

void ManageBasket()
{
   if(!basketActive) return;

   double totalPL = 0;
   int stillOpen = 0;

   for(int i = 0; i < ArraySize(activeBasket); i++)
   {
      if(OrderSelect(activeBasket[i].ticket, SELECT_BY_TICKET))
      {
         if(OrderCloseTime() == 0)
         {
            totalPL += OrderProfit() + OrderSwap() + OrderCommission();
            stillOpen++;
         }
      }
   }

   if(stillOpen == 0)
   {
      CloseBasket("All trades hit SL");
      return;
   }

   if(totalPL >= basketProfitTarget)
   {
      CloseBasket("Profit Target 1.2R");
      return;
   }

   int duration = (int)(TimeCurrent() - basketOpenTime);
   if(duration >= MaxBasketDuration)
   {
      CloseBasket("Time Limit");
      return;
   }

   UpdateDisplay(totalPL, stillOpen);
}

void CloseBasket(string reason)
{
   double basketPL = 0;

   for(int i = ArraySize(activeBasket) - 1; i >= 0; i--)
   {
      if(OrderSelect(activeBasket[i].ticket, SELECT_BY_TICKET))
      {
         if(OrderCloseTime() == 0)
         {
            double closePrice = (OrderType() == OP_BUY) ?
                               MarketInfo(OrderSymbol(), MODE_BID) :
                               MarketInfo(OrderSymbol(), MODE_ASK);

            if(closePrice > 0)
            {
               bool closed = OrderClose(activeBasket[i].ticket, OrderLots(),
                                       closePrice, MaxSlippagePips, clrGold);

               if(closed)
               {
                  basketPL += OrderProfit() + OrderSwap() + OrderCommission();
               }
            }
         }
         else
         {

            basketPL += OrderProfit() + OrderSwap() + OrderCommission();
         }
      }
   }

   dailyProfit += basketPL;
   dailyTradeCount += ArraySize(activeBasket);

   if(basketPL > 0)
      dailyWins++;
   else
      dailyLosses++;

   ArrayResize(activeBasket, 0);
   basketActive = false;
   totalBasketRisk = 0;
   basketProfitTarget = 0;
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

void CheckDailyReset()
{
   datetime currentDay = iTime(Symbol(), PERIOD_D1, 0);

   if(currentDay != lastDayReset)
   {
      Print("Daily Reset - Trades: ", dailyTradeCount, " | P&L: ", DoubleToString(dailyProfit, 2), " USD");

      dailyProfit = 0;
      dailyTradeCount = 0;
      dailyWins = 0;
      dailyLosses = 0;
      lastDayReset = currentDay;
      tradingEnabled = true;
   }
}

void CheckDailyLimits()
{
   if(!tradingEnabled) return;

   if(dailyProfit >= DailyProfitTargetUSD)
   {
      tradingEnabled = false;
      Alert("Daily Profit Target Hit: +", DoubleToString(dailyProfit, 2), " USD");
      if(basketActive) CloseBasket("Daily Target");
      return;
   }

   if(dailyProfit <= -MaxDailyLossUSD)
   {
      tradingEnabled = false;
      Alert("Daily Loss Limit Hit: ", DoubleToString(dailyProfit, 2), " USD");
      if(basketActive) CloseBasket("Daily Limit");
      return;
   }
}

void UpdateDisplay(double currentPL, int openTrades)
{
   string status = "⚡ GOLD SCALPER PRO - BASKET ⚡\n";
   status += "Status: " + (basketActive ? "BASKET ACTIVE" : "WAITING") + "\n";
   status += "========================================\n";

   if(basketActive)
   {
      int duration = (int)(TimeCurrent() - basketOpenTime);
      double progress = (basketProfitTarget > 0) ? (currentPL / basketProfitTarget * 100.0) : 0;

      status += "Basket: " + IntegerToString(openTrades) + " trades | " + IntegerToString(duration) + "s\n";
      status += "P&L: " + DoubleToString(currentPL, 2) + " / " + DoubleToString(basketProfitTarget, 2) + " USD\n";
      status += "Progress: " + DoubleToString(progress, 1) + "% → 120% (1.2R)\n";
   }
   else
   {
      status += "Next basket in: " + IntegerToString(TicksBetweenBasket - tickCounter) + " ticks\n";
   }

   status += "========================================\n";
   status += "TODAY: " + IntegerToString(dailyTradeCount) + " trades | " + IntegerToString(dailyWins) + "W/" + IntegerToString(dailyLosses) + "L\n";
   status += "Daily P&L: " + DoubleToString(dailyProfit, 2) + " USD\n";
   status += "========================================\n";
   status += "RRR: 1:" + DoubleToString(RiskRewardRatio, 1) + " | Lot: " + DoubleToString(FixedLotSize, 2) + " | SL: " + IntegerToString((int)StopLossPips) + " pips";

   Comment(status);
}

