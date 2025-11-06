

#property copyright "Copyright 2025"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"
#property strict

input group "===== Trading Instruments ====="
input bool     TradeGold           = true;
input bool     TradeEURUSD         = true;
input bool     TradeGBPUSD         = true;
input bool     TradeUSDJPY         = true;
input bool     TradeOil            = true;

input group "===== Ultra-Fast Settings ====="
input double   CapitalPercentPerTrade = 5.0;  // % of capital per trade
input int      MinTrades           = 2;
input int      MaxTrades           = 5;
input double   MinProfitPercent    = 3.0;     // Close basket at 3% profit
input double   MaxProfitPercent    = 10.0;    // Close basket at 10% profit
input int      MaxBasketDuration   = 300;     // Increased for profit targets
input int      TicksBetweenBasket  = 3;

input group "===== Risk Settings ====="
input double   StopLossPips        = 10.0;
input double   MaxSpreadPips       = 4.0;
input int      MaxSlippagePips     = 3;
input double   MaxDrawdownPercent  = 40.0;    // Maximum drawdown protection
input double   MaxLossPercent      = 10.0;    // Close basket if loss exceeds 10% of capital

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
double accountStartBalance = 0;

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
   Print("Profit Target: ", MinProfitPercent, "% - ", MaxProfitPercent, "% per basket");
   Print("Max Duration: ", MaxBasketDuration, " seconds");
   Print("Capital per Trade: ", CapitalPercentPerTrade, "%");
   Print("Max Drawdown: ", MaxDrawdownPercent, "% | Max Loss per Basket: ", MaxLossPercent, "%");
   Print("========================================");

   accountStartBalance = AccountBalance();
   ArrayResize(activeBasket, 0);
   lastDayReset = iTime(Symbol(), PERIOD_D1, 0);
   basketActive = false;

   return(INIT_SUCCEEDED);
}

void OnTick()
{
   tickCounter++;

   CheckDailyReset();
   CheckDrawdownProtection();

   if(!tradingEnabled) return;
   CheckDailyLimits();

   // PRIORITY: Check profit FIRST if basket is active
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

   // Scan all instruments for calculated signals (not random)
   int opened = 0;
   int validSignals = 0;
   
   // First pass: count valid signals
   for(int i = 0; i < totalInstruments; i++)
   {
      string instrument = tradingInstruments[i];
      
      if(MarketInfo(instrument, MODE_BID) <= 0)
         continue;
      
      double spread = GetSpreadPips(instrument);
      if(spread > MaxSpreadPips || spread <= 0)
         continue;
      
      int direction = GetFastSignal(instrument);
      if(direction >= 0)
         validSignals++;
   }
   
   // Only open basket if we have enough valid calculated signals
   if(validSignals < MinTrades)
   {
      return; // Wait for better signals
   }
   
   // Second pass: open trades based on calculated signals
   // Prioritize strongest signals first
   for(int i = 0; i < totalInstruments && opened < MaxTrades; i++)
   {
      string instrument = tradingInstruments[i];
      
      if(MarketInfo(instrument, MODE_BID) <= 0)
         continue;
      
      double spread = GetSpreadPips(instrument);
      if(spread > MaxSpreadPips || spread <= 0)
         continue;
      
      // Check if already in basket
      bool alreadySelected = false;
      for(int j = 0; j < opened; j++)
      {
         if(activeBasket[j].symbol == instrument)
         {
            alreadySelected = true;
            break;
         }
      }
      
      if(alreadySelected)
         continue;
      
      // Get calculated signal (not random)
      int direction = GetFastSignal(instrument);
      if(direction < 0)
         continue; // No valid signal for this instrument
      
      // Open trade with calculated direction
      if(OpenInstantTrade(instrument, direction, opened))
      {
         opened++;
      }
   }

   if(opened >= MinTrades)
   {
      // Calculate profit targets based on capital percentage (3-10%)
      double currentBalance = AccountBalance();
      double minProfitTarget = currentBalance * (MinProfitPercent / 100.0);
      double maxProfitTarget = currentBalance * (MaxProfitPercent / 100.0);
      
      // Use minimum profit target as initial target, will close anywhere in 3-10% range
      basketProfitTarget = minProfitTarget;
      basketActive = true;
      basketOpenTime = TimeCurrent();
      
      Print("BASKET OPENED: ", opened, " calculated trades | Profit Target: ", MinProfitPercent, "-", MaxProfitPercent, "% (", 
            DoubleToString(minProfitTarget, 2), "-", DoubleToString(maxProfitTarget, 2), " USD)");

   }
   else
   {
      // Not enough valid signals - don't open basket
      ArrayResize(activeBasket, 0);
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

   // Calculate lot size based on 5% of capital
   double currentBalance = AccountBalance();
   double capitalPerTrade = currentBalance * (CapitalPercentPerTrade / 100.0);
   
   // Calculate lot size based on risk
   double tickValue = MarketInfo(symbol, MODE_TICKVALUE);
   double slPoints = StopLossPips * (digits == 5 || digits == 3 ? 10.0 : 1.0);
   
   // Calculate lot size: capital / (SL pips * tick value per lot)
   double lotSize = 0;
   if(slPoints > 0 && tickValue > 0)
   {
      lotSize = capitalPerTrade / (slPoints * tickValue);
   }
   else
   {
      // Fallback calculation
      double contractSize = MarketInfo(symbol, MODE_LOTSIZE);
      if(contractSize <= 0) contractSize = 100000;
      lotSize = capitalPerTrade / (slPoints * (contractSize * point));
   }
   
   // Normalize lot size
   double minLot = MarketInfo(symbol, MODE_MINLOT);
   double maxLot = MarketInfo(symbol, MODE_MAXLOT);
   double lotStep = MarketInfo(symbol, MODE_LOTSTEP);
   if(lotStep <= 0) lotStep = 0.01;
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   if(minLot > 0) lotSize = MathMax(lotSize, minLot);
   if(maxLot > 0) lotSize = MathMin(lotSize, maxLot);
   
   double risk = lotSize * slPoints * tickValue;

   int magic = BaseMagicNumber + index;

   color arrowColor = (direction == OP_BUY) ? clrLime : clrRed;
   int ticket = OrderSend(symbol, direction, lotSize, price, MaxSlippagePips,
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
   // Calculate tick-based momentum using current bid/ask and recent ticks
   double currentBid = MarketInfo(symbol, MODE_BID);
   double currentAsk = MarketInfo(symbol, MODE_ASK);
   
   if(currentBid <= 0 || currentAsk <= 0)
      return -1;
   
   double spread = currentAsk - currentBid;
   double point = MarketInfo(symbol, MODE_POINT);
   int digits = (int)MarketInfo(symbol, MODE_DIGITS);
   
   if(digits == 5 || digits == 3)
      point *= 10;
   
   // Get tick data from M1 chart (most recent candles)
   double close0 = iClose(symbol, PERIOD_M1, 0);
   double close1 = iClose(symbol, PERIOD_M1, 1);
   double close2 = iClose(symbol, PERIOD_M1, 2);
   double close3 = iClose(symbol, PERIOD_M1, 3);
   
   if(close0 <= 0 || close1 <= 0 || close2 <= 0)
      return -1;
   
   // Calculate momentum from last 3-4 candles
   double momentum1 = close0 - close1;  // Latest momentum
   double momentum2 = close1 - close2;  // Previous momentum
   double momentum3 = (close2 - close3); // Earlier momentum (if available)
   
   // Calculate average price movement
   double avgMovement = (MathAbs(momentum1) + MathAbs(momentum2)) / 2.0;
   
   // Minimum movement threshold: must be at least 2x the spread to be significant
   double minMovement = spread * 2.0;
   
   // STRONG BUY: Clear upward momentum with acceleration
   if(momentum1 > 0 && momentum2 > 0 && momentum1 >= minMovement)
   {
      // Additional confirmation: momentum is increasing
      if(momentum1 > momentum2 || avgMovement >= minMovement)
      {
         return OP_BUY;
      }
   }
   
   // STRONG SELL: Clear downward momentum with acceleration
   if(momentum1 < 0 && momentum2 < 0 && MathAbs(momentum1) >= minMovement)
   {
      // Additional confirmation: momentum is increasing
      if(MathAbs(momentum1) > MathAbs(momentum2) || avgMovement >= minMovement)
      {
         return OP_SELL;
      }
   }
   
   // No clear calculated signal - don't trade (no random fallback)
   return -1;
}

void ManageBasket()
{
   if(!basketActive) return;

   double totalPL = 0;
   int stillOpen = 0;

   // Calculate current P&L
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
      CloseBasket("All trades closed");
      return;
   }

   double currentBalance = AccountBalance();
   double profitPercent = (totalPL / accountStartBalance) * 100.0;
   double lossPercent = (totalPL < 0) ? MathAbs(profitPercent) : 0;

   // PRIORITY 1: Close on PROFIT (3-10% range) - FAST EXIT
   if(totalPL > 0)
   {
      double minProfitUSD = accountStartBalance * (MinProfitPercent / 100.0);
      double maxProfitUSD = accountStartBalance * (MaxProfitPercent / 100.0);
      
      // Close immediately if profit is in 3-10% range
      if(totalPL >= minProfitUSD && totalPL <= maxProfitUSD)
      {
         CloseBasket("Profit Target " + DoubleToString(profitPercent, 2) + "%");
         return;
      }
      
      // Close if profit exceeds 10% (take profit quickly)
      if(totalPL > maxProfitUSD)
      {
         CloseBasket("Max Profit " + DoubleToString(profitPercent, 2) + "%");
         return;
      }
   }

   // PRIORITY 2: Only close on loss if it exceeds 10% of capital
   if(totalPL < 0 && lossPercent >= MaxLossPercent)
   {
      CloseBasket("Loss Limit " + DoubleToString(lossPercent, 2) + "%");
      return;
   }

   // Time limit - only close if still in profit or small loss
   int duration = (int)(TimeCurrent() - basketOpenTime);
   if(duration >= MaxBasketDuration)
   {
      if(totalPL > 0)
      {
         CloseBasket("Time Limit (Profit: " + DoubleToString(profitPercent, 2) + "%)");
      }
      // Don't close on time limit if in loss (let it recover)
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

void CheckDrawdownProtection()
{
   double currentEquity = AccountEquity();
   double maxDrawdown = accountStartBalance * (MaxDrawdownPercent / 100.0);

   if(accountStartBalance > 0 && currentEquity < (accountStartBalance - maxDrawdown))
   {
      tradingEnabled = false;
      Alert("MAX DRAWDOWN LIMIT: ", MaxDrawdownPercent, "% reached!");
      if(basketActive) CloseBasket("Max Drawdown " + DoubleToString(MaxDrawdownPercent, 1) + "%");
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
      double profitPercent = (accountStartBalance > 0) ? (currentPL / accountStartBalance * 100.0) : 0;
      double minProfitUSD = accountStartBalance * (MinProfitPercent / 100.0);
      double maxProfitUSD = accountStartBalance * (MaxProfitPercent / 100.0);

      status += "Basket: " + IntegerToString(openTrades) + " trades | " + IntegerToString(duration) + "s\n";
      status += "P&L: " + DoubleToString(currentPL, 2) + " USD (" + DoubleToString(profitPercent, 2) + "%)\n";
      status += "Target: " + DoubleToString(MinProfitPercent, 1) + "-" + DoubleToString(MaxProfitPercent, 1) + "% (" + 
                DoubleToString(minProfitUSD, 2) + "-" + DoubleToString(maxProfitUSD, 2) + " USD)\n";
   }
   else
   {
      status += "Next basket in: " + IntegerToString(TicksBetweenBasket - tickCounter) + " ticks\n";
   }

   status += "========================================\n";
   status += "TODAY: " + IntegerToString(dailyTradeCount) + " trades | " + IntegerToString(dailyWins) + "W/" + IntegerToString(dailyLosses) + "L\n";
   status += "Daily P&L: " + DoubleToString(dailyProfit, 2) + " USD\n";
   status += "========================================\n";
   status += "Capital/Trade: " + DoubleToString(CapitalPercentPerTrade, 1) + "% | Profit Target: " + DoubleToString(MinProfitPercent, 1) + "-" + DoubleToString(MaxProfitPercent, 1) + "% | SL: " + IntegerToString((int)StopLossPips) + " pips";

   Comment(status);
}

