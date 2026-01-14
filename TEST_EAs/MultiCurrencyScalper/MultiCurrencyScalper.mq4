

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

input group "===== Trade Management ====="
input int      ProfitTargetPips    = 15;
input int      StopLossPips        = 15;
input int      TrailingStartPips   = 10;
input int      TrailingStepPips    = 5;
input double   MaxSpreadPips       = 6.0;
input int      TradeIntervalSec    = 120;

input group "===== Risk Management ====="
input double   RiskPerTradePercent = 1.0;
input double   MaxDailyLossPercent = 3.0;
input double   DailyProfitTargetPercent = 5.0;
input int      MagicNumber         = 303303;

input group "===== Trading Hours ====="
input int      StartHour           = 8;
input int      EndHour             = 18;
input bool     AvoidFridayAfternoon = true;

string tradingPairs[];
int totalPairs = 0;
datetime lastTradeTime = 0;
int tradesThisRound = 0;
double dailyProfit = 0;
int dailyTradeCount = 0;
int dailyWins = 0;
int dailyLosses = 0;
datetime lastDayReset = 0;

double dailyStartEquity = 0;
double maxDailyLossEquity = 0;
bool tradingEnabled = true;

struct TradeInfo {
   int ticket;
   string symbol;
   double highestProfitPips;
   bool trailingActive;
};

TradeInfo activeTrades[];

int OnInit()
{
   Print("========================================");
   Print("Multi-Currency Tick Scalper v1.00");
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
         Print("  [", i+1, "] ", tradingPairs[i], " - WARNING: Not found in Market Watch!");
   }

   dailyStartEquity = AccountEquity();
   maxDailyLossEquity = dailyStartEquity * (1.0 - MaxDailyLossPercent / 100.0);

   Print("========================================");
   Print("Strategy: Multi-Factor Tick Scalping");
   Print("Profit Target: ", ProfitTargetPips, " pips per trade");
   Print("Stop Loss: ", StopLossPips, " pips per trade");
   Print("Trailing: Starts at ", TrailingStartPips, " pips | Step: ", TrailingStepPips, " pips");
   Print("Trade Interval: ", TradeIntervalSec, " seconds (", TradeIntervalSec/60, " minutes)");
   Print("Risk Per Trade: ", RiskPerTradePercent, "% of balance");
   Print("Daily Loss Limit: ", MaxDailyLossPercent, "% | Profit Target: ", DailyProfitTargetPercent, "%");
   Print("Trading Hours: ", StartHour, ":00 - ", EndHour, ":00");
   Print("Max Spread: ", MaxSpreadPips, " pips");
   Print("========================================");

   if(totalPairs < 3)
   {
      Alert("WARNING: Less than 3 pairs selected. Enable more pairs!");
      return(INIT_FAILED);
   }

   ArrayResize(activeTrades, 0);
   lastDayReset = iTime(Symbol(), PERIOD_D1, 0);

   return(INIT_SUCCEEDED);
}

void OnTick()
{

   CheckDailyReset();

   CheckDailyLimits();

   ManageActiveTrades();

   if(tradingEnabled && TimeCurrent() - lastTradeTime >= TradeIntervalSec)
   {
      OpenNewRound();
      lastTradeTime = TimeCurrent();
      tradesThisRound = 0;
   }

   UpdateDisplay();
}

void CheckDailyReset()
{
   datetime currentDay = iTime(Symbol(), PERIOD_D1, 0);

   if(currentDay != lastDayReset)
   {
      Print("========================================");
      Print("DAILY RESET");
      Print("Previous day stats:");
      Print("  Trades: ", dailyTradeCount);
      Print("  Wins: ", dailyWins, " (", (dailyTradeCount > 0 ? DoubleToString(dailyWins * 100.0 / dailyTradeCount, 1) : "0"), "%)");
      Print("  Losses: ", dailyLosses);
      Print("  Total P&L: ", DoubleToString(dailyProfit, 2), " ", AccountCurrency());
      Print("========================================");

      dailyProfit = 0;
      dailyTradeCount = 0;
      dailyWins = 0;
      dailyLosses = 0;
      lastDayReset = currentDay;

      dailyStartEquity = AccountEquity();
      maxDailyLossEquity = dailyStartEquity * (1.0 - MaxDailyLossPercent / 100.0);
      tradingEnabled = true;

      Print("New day started. Start Equity: ", DoubleToString(dailyStartEquity, 2), " ", AccountCurrency());
   }
}

void CheckDailyLimits()
{
   if(!tradingEnabled) return;

   double currentEquity = AccountEquity();

   if(currentEquity <= maxDailyLossEquity)
   {
      tradingEnabled = false;
      Alert("ALERT: Max Daily Drawdown ", MaxDailyLossPercent, "% hit! Trading disabled until tomorrow.");
      Print("========================================");
      Print("TRADING DISABLED: Max Daily Drawdown Hit");
      Print("Start Equity: ", DoubleToString(dailyStartEquity, 2));
      Print("Current Equity: ", DoubleToString(currentEquity, 2));
      Print("Loss: ", DoubleToString(dailyStartEquity - currentEquity, 2), " (",
            DoubleToString((dailyStartEquity - currentEquity) / dailyStartEquity * 100, 2), "%)");
      Print("========================================");
      CloseAllTrades();
      return;
   }

   double profitTarget = dailyStartEquity * (1.0 + DailyProfitTargetPercent / 100.0);
   if(currentEquity >= profitTarget)
   {
      tradingEnabled = false;
      Alert("SUCCESS: Daily Profit Target ", DailyProfitTargetPercent, "% reached! Trading disabled until tomorrow.");
      Print("========================================");
      Print("TRADING DISABLED: Daily Profit Target Reached");
      Print("Start Equity: ", DoubleToString(dailyStartEquity, 2));
      Print("Current Equity: ", DoubleToString(currentEquity, 2));
      Print("Profit: ", DoubleToString(currentEquity - dailyStartEquity, 2), " (",
            DoubleToString((currentEquity - dailyStartEquity) / dailyStartEquity * 100, 2), "%)");
      Print("========================================");
      CloseAllTrades();
      return;
   }
}

double CalculateLotSize(string symbol, double riskPercent, int slPips)
{

   double point = MarketInfo(symbol, MODE_POINT);
   int digits = (int)MarketInfo(symbol, MODE_DIGITS);
   double tickValue = MarketInfo(symbol, MODE_TICKVALUE);
   double minLot = MarketInfo(symbol, MODE_MINLOT);
   double maxLot = MarketInfo(symbol, MODE_MAXLOT);
   double lotStep = MarketInfo(symbol, MODE_LOTSTEP);

   if(digits == 5 || digits == 3)
      point *= 10;

   double slPoints = slPips * (digits == 5 || digits == 3 ? 10.0 : 1.0);

   double lossPerLotAccount = slPoints * tickValue;

   double maxLossAllowed = AccountBalance() * riskPercent / 100.0;

   double lotSize = 0;
   if(lossPerLotAccount > 0)
      lotSize = maxLossAllowed / lossPerLotAccount;

   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = NormalizeDouble(lotSize, 2);

   if(lotSize < minLot)
      lotSize = minLot;

   return lotSize;
}

void AddPair(string pair)
{
   int size = ArraySize(tradingPairs);
   ArrayResize(tradingPairs, size + 1);
   tradingPairs[size] = pair;
}

void OpenNewRound()
{
   if(!tradingEnabled)
   {
      Comment("Trading disabled due to daily limit.");
      return;
   }

   int currentHour = Hour();
   if(currentHour < StartHour || currentHour >= EndHour)
   {
      Print("Skipping trade: Outside trading hours (", currentHour, ":00)");
      return;
   }

   if(AvoidFridayAfternoon && DayOfWeek() == 5 && currentHour >= 12)
   {
      Print("Skipping trade: Friday afternoon - News avoidance active");
      return;
   }

   Print("========================================");
   Print("NEW ROUND: Opening 3 trades...");
   Print("========================================");

   string selectedPairs[];
   ArrayResize(selectedPairs, 0);

   int attempts = 0;
   while(ArraySize(selectedPairs) < 3 && attempts < totalPairs * 3)
   {
      int randomIndex = MathRand() % totalPairs;
      string pair = tradingPairs[randomIndex];

      bool alreadySelected = false;
      for(int i = 0; i < ArraySize(selectedPairs); i++)
      {
         if(selectedPairs[i] == pair)
         {
            alreadySelected = true;
            break;
         }
      }

      if(!alreadySelected)
      {

         double spread = GetSpreadPips(pair);
         if(spread <= MaxSpreadPips && spread > 0)
         {
            int size = ArraySize(selectedPairs);
            ArrayResize(selectedPairs, size + 1);
            selectedPairs[size] = pair;
            Print("Selected: ", pair, " (Spread: ", DoubleToString(spread, 1), " pips)");
         }
      }

      attempts++;
   }

   for(int i = 0; i < ArraySize(selectedPairs); i++)
   {
      OpenScalpTrade(selectedPairs[i]);
      Sleep(200);
   }

   Print("Round complete: ", ArraySize(selectedPairs), " trades opened");
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

int GetTradeDirection(string symbol)
{

   double price1 = iClose(symbol, PERIOD_M1, 0);
   double price2 = iClose(symbol, PERIOD_M1, 1);
   double price3 = iClose(symbol, PERIOD_M1, 2);

   double momentum = price1 - price3;
   double recentMove = price1 - price2;

   int m1Direction = -1;

   if(momentum > 0 && recentMove > 0)
   {
      m1Direction = OP_BUY;
   }
   else if(momentum < 0 && recentMove < 0)
   {
      m1Direction = OP_SELL;
   }
   else
   {

      return -1;
   }

   double maFast = iMA(symbol, PERIOD_M5, 10, 0, MODE_EMA, PRICE_CLOSE, 0);
   double maSlow = iMA(symbol, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE, 0);

   int m5Trend = -1;
   if(maFast > maSlow)
      m5Trend = OP_BUY;
   else if(maFast < maSlow)
      m5Trend = OP_SELL;
   else
      return -1;

   if(m1Direction == m5Trend)
   {
      Print("Signal confirmed: ", symbol, " ", (m1Direction == OP_BUY ? "BUY" : "SELL"),
            " | M1 momentum + M5 trend aligned");
      return m1Direction;
   }

   Print("Signal skipped: ", symbol, " - M1 and M5 not aligned");
   return -1;
}

void OpenScalpTrade(string symbol)
{
   int direction = GetTradeDirection(symbol);

   if(direction < 0)
   {
      Print("No valid signal for ", symbol);
      return;
   }

   double lotSize = CalculateLotSize(symbol, RiskPerTradePercent, StopLossPips);

   if(lotSize <= 0)
   {
      Print("ERROR: Invalid lot size calculated for ", symbol);
      return;
   }

   double price = (direction == OP_BUY) ? MarketInfo(symbol, MODE_ASK) : MarketInfo(symbol, MODE_BID);
   double point = MarketInfo(symbol, MODE_POINT);
   int digits = (int)MarketInfo(symbol, MODE_DIGITS);

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

   string comment = "MultiScalp_" + symbol;
   color arrowColor = (direction == OP_BUY) ? clrGreen : clrRed;

   int ticket = OrderSend(symbol, direction, lotSize, price, 3, sl, tp,
                          comment, MagicNumber, 0, arrowColor);

   if(ticket > 0)
   {

      int size = ArraySize(activeTrades);
      ArrayResize(activeTrades, size + 1);

      activeTrades[size].ticket = ticket;
      activeTrades[size].symbol = symbol;
      activeTrades[size].highestProfitPips = 0;
      activeTrades[size].trailingActive = false;

      tradesThisRound++;

      Print("TRADE OPENED: ", symbol, " ", (direction == OP_BUY ? "BUY" : "SELL"),
            " | Ticket: ", ticket, " | Price: ", DoubleToString(price, digits),
            " | Lot: ", DoubleToString(lotSize, 2),
            " | SL: ", DoubleToString(sl, digits), " | TP: ", DoubleToString(tp, digits));
   }
   else
   {
      Print("ERROR opening trade on ", symbol, ": ", GetLastError());
   }
}

void ManageActiveTrades()
{
   for(int i = ArraySize(activeTrades) - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket > 0)
      {
         if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
         {

            if(OrderCloseTime() > 0)
            {

               double finalPL = OrderProfit() + OrderSwap() + OrderCommission();
               TrackClosedTrade(finalPL);
               RemoveTradeAtIndex(i);
               continue;
            }

            double entryPrice = OrderOpenPrice();
            double currentPrice = (OrderType() == OP_BUY) ? MarketInfo(OrderSymbol(), MODE_BID) : MarketInfo(OrderSymbol(), MODE_ASK);
            double point = MarketInfo(OrderSymbol(), MODE_POINT);
            int digits = (int)MarketInfo(OrderSymbol(), MODE_DIGITS);

            if(digits == 5 || digits == 3)
               point *= 10;

            double profitPips = 0;
            if(OrderType() == OP_BUY)
               profitPips = (currentPrice - entryPrice) / point;
            else
               profitPips = (entryPrice - currentPrice) / point;

            if(profitPips >= TrailingStartPips)
            {

               if(profitPips > activeTrades[i].highestProfitPips)
               {
                  activeTrades[i].highestProfitPips = profitPips;
                  activeTrades[i].trailingActive = true;
               }

               double newSL = 0;
               if(OrderType() == OP_BUY)
               {
                  newSL = currentPrice - (TrailingStepPips * point);

                  if(newSL > OrderStopLoss() && newSL < currentPrice)
                  {
                     newSL = NormalizeDouble(newSL, digits);
                     bool modified = OrderModify(OrderTicket(), OrderOpenPrice(), newSL, OrderTakeProfit(), 0, clrBlue);
                     if(modified)
                        Print("Trailing Stop moved: ", OrderSymbol(), " | New SL: ", newSL, " | Profit: ", DoubleToString(profitPips, 1), " pips");
                  }
               }
               else
               {
                  newSL = currentPrice + (TrailingStepPips * point);

                  if(newSL < OrderStopLoss() || OrderStopLoss() == 0)
                  {
                     if(newSL > currentPrice)
                     {
                        newSL = NormalizeDouble(newSL, digits);
                        bool modified = OrderModify(OrderTicket(), OrderOpenPrice(), newSL, OrderTakeProfit(), 0, clrRed);
                        if(modified)
                           Print("Trailing Stop moved: ", OrderSymbol(), " | New SL: ", newSL, " | Profit: ", DoubleToString(profitPips, 1), " pips");
                     }
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

void TrackClosedTrade(double finalPL)
{
   dailyProfit += finalPL;
   dailyTradeCount++;

   if(finalPL > 0)
      dailyWins++;
   else
      dailyLosses++;

   Print("Trade closed | P&L: ", DoubleToString(finalPL, 2), " ", AccountCurrency(),
         " | Daily: ", dailyWins, "W/", dailyLosses, "L");
}

void CloseAllTrades()
{
   Print("========================================");
   Print("CLOSING ALL TRADES");
   Print("========================================");

   for(int i = ArraySize(activeTrades) - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket > 0)
      {
         CloseTradeAtIndex(i, "Emergency Close - Daily Limit");
      }
   }

   Print("All trades closed");
}

void CloseTradeAtIndex(int index, string reason)
{
   if(index < 0 || index >= ArraySize(activeTrades)) return;

   int ticket = activeTrades[index].ticket;

   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return;

   double closePrice = (OrderType() == OP_BUY) ? MarketInfo(OrderSymbol(), MODE_BID) : MarketInfo(OrderSymbol(), MODE_ASK);
   double volume = OrderLots();

   if(closePrice <= 0)
   {
      Print("ERROR: Invalid close price for ", OrderSymbol());
      return;
   }

   bool closed = OrderClose(ticket, volume, closePrice, 5, clrYellow);

   if(closed)
   {
      double finalPL = OrderProfit() + OrderSwap() + OrderCommission();
      TrackClosedTrade(finalPL);
      Print("TRADE CLOSED: ", OrderSymbol(), " | ", reason,
            " | P&L: ", DoubleToString(finalPL, 2), " ", AccountCurrency());
   }
   else
   {
      Print("ERROR closing trade #", ticket, ": ", GetLastError());
   }

   RemoveTradeAtIndex(index);
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
   int activeTrade = ArraySize(activeTrades);
   int secondsUntilNext = (int)(TradeIntervalSec - (TimeCurrent() - lastTradeTime));
   if(secondsUntilNext < 0) secondsUntilNext = 0;

   double totalProfit = 0;
   int trailingCount = 0;

   for(int i = 0; i < activeTrade; i++)
   {
      if(OrderSelect(activeTrades[i].ticket, SELECT_BY_TICKET))
      {
         totalProfit += OrderProfit() + OrderSwap() + OrderCommission();
         if(activeTrades[i].trailingActive) trailingCount++;
      }
   }

   double winRate = (dailyTradeCount > 0) ? (dailyWins * 100.0 / dailyTradeCount) : 0;
   double currentEquity = AccountEquity();
   double dailyPLPercent = (dailyStartEquity > 0) ? ((currentEquity - dailyStartEquity) / dailyStartEquity * 100.0) : 0;

   string tradingStatus = tradingEnabled ? "ACTIVE" : "STOPPED";
   if(!tradingEnabled)
   {
      if(currentEquity <= maxDailyLossEquity)
         tradingStatus = "STOPPED (Max DD Hit)";
      else
         tradingStatus = "STOPPED (Profit Target)";
   }

   int currentHour = Hour();
   bool inTradingHours = (currentHour >= StartHour && currentHour < EndHour);

   string status = "==== Multi-Currency Pro Scalper v2.0 ====\n";
   status += "Status: " + tradingStatus + " | " + (inTradingHours ? "IN HOURS" : "OUT OF HOURS") + "\n";
   status += "Active: " + IntegerToString(activeTrade) + " (" + IntegerToString(trailingCount) + " trailing) | Next: " + IntegerToString(secondsUntilNext) + "s\n";
   status += "========================================\n";
   status += "CURRENT P&L: " + DoubleToString(totalProfit, 2) + " " + AccountCurrency() + "\n";
   status += "TP: " + IntegerToString(ProfitTargetPips) + " pips | SL: " + IntegerToString(StopLossPips) + " pips per trade\n";
   status += "Trailing: Starts at " + IntegerToString(TrailingStartPips) + " pips | Step: " + IntegerToString(TrailingStepPips) + " pips\n";
   status += "========================================\n";
   status += "TODAY: " + IntegerToString(dailyTradeCount) + " trades | " + IntegerToString(dailyWins) + "W / " + IntegerToString(dailyLosses) + "L (" + DoubleToString(winRate, 1) + "%)\n";
   status += "Daily P&L: " + DoubleToString(dailyProfit, 2) + " " + AccountCurrency() + " (" + DoubleToString(dailyPLPercent, 2) + "%)\n";
   status += "Equity: " + DoubleToString(currentEquity, 2) + " | Start: " + DoubleToString(dailyStartEquity, 2) + "\n";
   status += "========================================\n";
   status += "Pairs: " + IntegerToString(totalPairs) + " | Risk: " + DoubleToString(RiskPerTradePercent, 1) + "% per trade\n";
   status += "Interval: " + IntegerToString(TradeIntervalSec/60) + " min | Hours: " + IntegerToString(StartHour) + "-" + IntegerToString(EndHour) + "\n";
   status += "Max DD: " + DoubleToString(MaxDailyLossPercent, 1) + "% | Profit Target: " + DoubleToString(DailyProfitTargetPercent, 1) + "%";

   Comment(status);
}

