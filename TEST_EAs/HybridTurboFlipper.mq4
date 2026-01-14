#property strict
#property version   "1.00"
#property description "HybridTurboFlipper - ultra high risk micro account flipper"

input group   "General"
input string  TradeSymbol              = "AUTO";
input int     MagicNumber              = 9152025;
input bool    EnableTrading            = true;
input double  LotMultiplier            = 0.01; // $1 equity -> 0.01 lot
input int     SlippagePoints           = 30;

input group   "Breakout Engine"
input int     FastEMAPeriod            = 5;
input int     SlowEMAPeriod            = 20;
input int     RSIPeriod                = 7;
input double  BodyRatioThreshold       = 0.70;
input int     VolumeLookback           = 10;
input double  VolumeSpikeMultiplier    = 1.50;
input double  TickAccelThreshold       = 0.02;

input group   "Stacking & Exits"
input double  StackLevel2TriggerPoints = 10.0;
input double  StackLevel3TriggerPoints = 20.0;
input double  PartialCloseMinPoints    = 15.0;
input double  PartialCloseMaxPoints    = 30.0;
input double  ProfitDecayPercent       = 40.0;
input double  EmergencyExitPoints      = 80.0;
input double  RSIBuyExitLevel          = 55.0;
input double  RSISellExitLevel         = 45.0;

input group   "Limits"
input double  MaxSpreadPips            = 8.0;
input double  SpreadSpikeFactor        = 1.80;
input int     MaxTradesPerDay          = 40;
input bool    BlockRollover            = true;

input group   "Execution Controls"
input bool    UseLimitEntries          = false;
input double  LimitOffsetPoints        = 10.0;   // points from current price for limit entries
input bool    LimitFallbackToMarket    = true;
input bool    EnableStarterTrades      = true;
input int     StarterCooldownSeconds   = 45;
input bool    StarterUseLimitEntries   = false;
input double  StarterLimitOffsetPoints = 12.0;

input group   "Filter & Debug Toggles"
input bool    RequireBodyStrength      = true;
input bool    RequireRSIFilter         = true;
input bool    RequireCloseBreakout     = true;
input bool    RequireVolumeSpikeFilter = true;
input bool    RequireTickAccelFilter   = true;
input bool    ShowBlockReasonOnPanel   = true;

// === Global State ============================================================
string  g_symbol = "";
double  g_point = 0.0;
int     g_digits = 0;
double  g_pipFactor = 1.0;
double  g_minLot = 0.01;
double  g_maxLot = 100.0;
double  g_lotStep = 0.01;
int     g_lotDigits = 2;

double  g_spreadEMA = 0.0;
int     g_spreadSamples = 0;

double  g_lastMid = 0.0;
double  g_lastVelocity = 0.0;
double  g_tickAcceleration = 0.0;
datetime g_lastTickTime = 0;

double  g_bid = 0.0;
double  g_ask = 0.0;

int     g_tradeDay = -1;
int     g_tradesToday = 0;

int     g_cycleDirection = 0;
double  g_firstEntryPrice = 0.0;
int     g_stackLevelAchieved = 0;
double  g_cyclePeakProfit = 0.0;
double  g_runningProfit = 0.0;
double  g_lastLotSize = 0.0;

double  g_stackTrigger2 = 10.0;
double  g_stackTrigger3 = 20.0;
double  g_partialTriggerPoints = 20.0;
string  g_lastBlockReason = "Booting";
string  g_lastSignalReason = "Scanning";
datetime g_lastStarterTime = 0;

struct OrderMemo
{
   int  ticket;
   bool partialDone;
};

OrderMemo g_memos[3];

// === Prototypes ==============================================================
bool   ResolveSymbol();
bool   RefreshSymbolRates();
void   ResetCycleState();
void   DetectExistingCycle();
void   EnsureTradeDay();
void   UpdateSpreadStats(double spreadPoints);
void   UpdateTickAnalytics();
bool   IsSpreadCalm();
bool   AllowTradingNow();
bool   IsRolloverWindow();
int    EvaluateSignal();
bool   TrendConfirmed(int direction);
bool   BreakoutConfirmed(int direction);
bool   HasVolumeSpike();
bool   OpenEntry(int direction, const string tag);
void   RegisterTrade();
int    CountOpenPositions();
double GetTotalOpenProfit();
void   ManagePositions();
void   AttemptStackEntries();
void   HandlePartialClose(int ticket, int direction, double openPrice, double lots);
bool   ShouldMomentumExit();
bool   ShouldRSIExit();
bool   ShouldProfitDecayExit();
bool   ShouldEmergencyExit();
void   CloseAllPositions(const string reason);
void   UpdatePanel(double projectedLots);
string TrendLabel();
double NormalizeLots(double lots);
double NormalizeCloseLots(double desired, double maxLots);
double PointsToPips(double points);
void   RegisterMemo(int ticket);
bool   IsPartialTicket(int ticket);
void   MarkPartialTicket(int ticket);
void   PruneMemos();
double GetPartialTrigger();
string NormalizeSymbolKey(string name);
bool   SymbolMatchesKey(string desiredKey, string candidateName);
bool   ExecuteEntry(int direction, const string tag, bool useLimit, double offsetPoints);
void   MaybeFireStarter();
void   SetSignalReason(const string reason);

// === Lifecycle ===============================================================
int OnInit()
{
   if(!ResolveSymbol())
   {
      Print("HybridTurboFlipper: unable to resolve symbol");
      return(INIT_FAILED);
   }

   g_point   = MarketInfo(g_symbol, MODE_POINT);
   g_digits  = (int)MarketInfo(g_symbol, MODE_DIGITS);
   g_minLot  = MarketInfo(g_symbol, MODE_MINLOT);
   g_maxLot  = MarketInfo(g_symbol, MODE_MAXLOT);
   g_lotStep = MarketInfo(g_symbol, MODE_LOTSTEP);

   if(g_point <= 0.0 || g_minLot <= 0.0)
   {
      Print("HybridTurboFlipper: invalid contract specs for ", g_symbol);
      return(INIT_FAILED);
   }

   if(g_lotStep <= 0.0)
      g_lotStep = 0.01;

   g_lotDigits = 0;
   double stepProbe = g_lotStep;
   while(stepProbe < 1.0 && g_lotDigits < 8)
   {
      stepProbe *= 10.0;
      g_lotDigits++;
   }

   g_pipFactor = (g_digits == 3 || g_digits == 5) ? 10.0 : 1.0;
   g_stackTrigger2 = MathMax(1.0, StackLevel2TriggerPoints);
   g_stackTrigger3 = MathMax(g_stackTrigger2 + 1.0, StackLevel3TriggerPoints);
   g_partialTriggerPoints = GetPartialTrigger();

   ResetCycleState();
   DetectExistingCycle();

   Print("HybridTurboFlipper READY on ", g_symbol);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Comment("");
   Print("HybridTurboFlipper deinit: ", reason);
}

void OnTick()
{
   if(StringLen(g_symbol) == 0)
      return;

   if(!RefreshSymbolRates())
      return;

   EnsureTradeDay();
   double spreadPoints = (g_ask - g_bid) / g_point;
   UpdateSpreadStats(spreadPoints);
   UpdateTickAnalytics();

   ManagePositions();
   AttemptStackEntries();

   double projectedLots = NormalizeLots(AccountEquity() * LotMultiplier);
   UpdatePanel(projectedLots);

   if(CountOpenPositions() > 0)
   {
      g_lastBlockReason = "Managing active cycle";
      return;
   }

   if(!AllowTradingNow())
      return;

   int direction = EvaluateSignal();
   if(direction == 0)
   {
      g_lastBlockReason = g_lastSignalReason;
      MaybeFireStarter();
      return;
   }

   g_lastBlockReason = "Signal confirmed";
   OpenEntry(direction, "HybridTurboFlipper Core");
}

// === Core Helpers ============================================================
bool ResolveSymbol()
{
   string desired = TradeSymbol;
   if(StringLen(desired) == 0 || StringCompare(StringToUpper(desired), "AUTO") == 0)
      desired = Symbol();

   if(StringLen(desired) == 0)
      return false;

   if(SymbolSelect(desired, true))
   {
      g_symbol = desired;
      return true;
   }

   string desiredKey = NormalizeSymbolKey(desired);
   if(StringLen(desiredKey) == 0)
      return false;

   int total = SymbolsTotal(true);
   for(int i=0; i<total; ++i)
   {
      string name = SymbolName(i, true);
      if(SymbolMatchesKey(desiredKey, name))
      {
         if(SymbolSelect(name, true))
         {
            g_symbol = name;
            return true;
         }
      }
   }

   total = SymbolsTotal(false);
   for(int j=0; j<total; ++j)
   {
      string hidden = SymbolName(j, false);
      if(SymbolMatchesKey(desiredKey, hidden))
      {
         if(SymbolSelect(hidden, true))
         {
            g_symbol = hidden;
            return true;
         }
      }
   }

   double probePoint = MarketInfo(desired, MODE_POINT);
   if(probePoint > 0.0)
   {
      g_symbol = desired;
      return true;
   }

   return false;
}

bool RefreshSymbolRates()
{
   RefreshRates();
   g_bid = MarketInfo(g_symbol, MODE_BID);
   g_ask = MarketInfo(g_symbol, MODE_ASK);
   return (g_bid > 0.0 && g_ask > 0.0);
}

void ResetCycleState()
{
   g_cycleDirection = 0;
   g_firstEntryPrice = 0.0;
   g_stackLevelAchieved = 0;
   g_cyclePeakProfit = 0.0;
   g_runningProfit = 0.0;
   g_lastLotSize = 0.0;

   for(int i=0; i<3; i++)
   {
      g_memos[i].ticket = 0;
      g_memos[i].partialDone = false;
   }
}

void DetectExistingCycle()
{
   int count = 0;
   int direction = 0;
   datetime earliestTime = 0;
   double earliestPrice = 0.0;

   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != g_symbol)
         continue;

      count++;
      int dir = (OrderType() == OP_BUY ? 1 : -1);
      if(direction == 0)
         direction = dir;

      datetime openTime = OrderOpenTime();
      if(earliestTime == 0 || openTime < earliestTime)
      {
         earliestTime = openTime;
         earliestPrice = OrderOpenPrice();
      }
      RegisterMemo(OrderTicket());
   }

   if(count > 0)
   {
      g_cycleDirection = direction;
      g_firstEntryPrice = earliestPrice;
      g_stackLevelAchieved = MathMin(3, count);
      g_runningProfit = GetTotalOpenProfit();
      g_cyclePeakProfit = MathMax(0.0, g_runningProfit);
   }
}

void EnsureTradeDay()
{
   datetime now = TimeCurrent();
   int day = TimeDayOfYear(now);
   if(day != g_tradeDay)
   {
      g_tradeDay = day;
      g_tradesToday = 0;
   }
}

void UpdateSpreadStats(double spreadPoints)
{
   if(g_spreadSamples == 0)
      g_spreadEMA = spreadPoints;
   else
      g_spreadEMA = g_spreadEMA * 0.85 + spreadPoints * 0.15;

   if(g_spreadSamples < 1000000)
      g_spreadSamples++;
}

void UpdateTickAnalytics()
{
   if(g_point <= 0.0)
      return;

   double mid = (g_bid + g_ask) * 0.5;
   datetime now = TimeCurrent();
   if(g_lastTickTime != 0)
   {
      double seconds = MathMax(1.0, (double)(now - g_lastTickTime));
      double deltaPoints = (mid - g_lastMid) / g_point;
      double velocity = deltaPoints / seconds;
      double accel = velocity - g_lastVelocity;
      g_tickAcceleration = g_tickAcceleration * 0.6 + accel * 0.4;
      g_lastVelocity = velocity;
   }
   g_lastMid = mid;
   g_lastTickTime = now;
}

bool IsSpreadCalm()
{
   double spreadPoints = (g_ask - g_bid) / g_point;
   double spreadPips = PointsToPips(spreadPoints);
   if(spreadPips > MaxSpreadPips + 1e-6)
      return false;

   if(g_spreadSamples > 5 && SpreadSpikeFactor > 0.0)
   {
      if(spreadPoints > g_spreadEMA * SpreadSpikeFactor)
         return false;
   }
   return true;
}

bool AllowTradingNow()
{
   if(!EnableTrading)
   {
      g_lastBlockReason = "Trading toggle disabled";
      return false;
   }
   if(IsRolloverWindow())
   {
      g_lastBlockReason = "Rollover lockout";
      return false;
   }
   if(MaxTradesPerDay > 0 && g_tradesToday >= MaxTradesPerDay)
   {
      g_lastBlockReason = "Daily trade cap reached";
      return false;
   }
   if(!IsSpreadCalm())
   {
      g_lastBlockReason = "Spread filter blocking";
      return false;
   }
   g_lastBlockReason = "Filters ready";
   return true;
}

bool IsRolloverWindow()
{
   if(!BlockRollover)
      return false;

   datetime now = TimeCurrent();
   int hour = TimeHour(now);
   int minute = TimeMinute(now);

   if(hour == 23 && minute >= 59)
      return true;
   if(hour == 0 && minute <= 10)
      return true;
   return false;
}

int EvaluateSignal()
{
   if(Bars < SlowEMAPeriod + 5)
   {
      SetSignalReason("Insufficient bars for signal");
      return 0;
   }

   bool buyOk = TrendConfirmed(1) && BreakoutConfirmed(1);
   bool sellOk = TrendConfirmed(-1) && BreakoutConfirmed(-1);

   if(buyOk && !sellOk)
      return 1;
   if(sellOk && !buyOk)
      return -1;
   if(buyOk && sellOk)
      return (g_tickAcceleration >= 0.0 ? 1 : -1);

   return 0;
}

bool TrendConfirmed(int direction)
{
   if(Bars < SlowEMAPeriod + 3)
   {
      SetSignalReason("Waiting for more bars");
      return false;
   }

   double emaFast = iMA(g_symbol, 0, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlow = iMA(g_symbol, 0, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
   double rsi = iRSI(g_symbol, 0, RSIPeriod, PRICE_CLOSE, 1);

   double close1 = iClose(g_symbol, 0, 1);
   double open1  = iOpen(g_symbol, 0, 1);
   double high1  = iHigh(g_symbol, 0, 1);
   double low1   = iLow(g_symbol, 0, 1);
   double prevHigh = iHigh(g_symbol, 0, 2);
   double prevLow  = iLow(g_symbol, 0, 2);

   double range = high1 - low1;
   if(range <= g_point)
   {
      if(RequireBodyStrength)
         SetSignalReason("Candle range too small");
      return false;
   }

   double body = MathAbs(close1 - open1);
   double ratio = (range > 0 ? body / range : 0.0);
   if(RequireBodyStrength && ratio < BodyRatioThreshold)
   {
      SetSignalReason("Body ratio below threshold");
      return false;
   }

   if(direction > 0)
   {
      if(emaFast <= emaSlow)
      {
         SetSignalReason("EMA alignment bearish");
         return false;
      }
      if(RequireRSIFilter && rsi <= 60.0)
      {
         SetSignalReason("RSI gate (buy) failed");
         return false;
      }
      if(RequireCloseBreakout && close1 <= prevHigh)
      {
         SetSignalReason("Close not beyond prev high");
         return false;
      }
      return true;
   }
   else
   {
      if(emaFast >= emaSlow)
      {
         SetSignalReason("EMA alignment bullish");
         return false;
      }
      if(RequireRSIFilter && rsi >= 40.0)
      {
         SetSignalReason("RSI gate (sell) failed");
         return false;
      }
      if(RequireCloseBreakout && close1 >= prevLow)
      {
         SetSignalReason("Close not beyond prev low");
         return false;
      }
      return true;
   }
}

bool BreakoutConfirmed(int direction)
{
   if(!IsSpreadCalm())
   {
      SetSignalReason("Spread instability");
      return false;
   }
   if(RequireVolumeSpikeFilter && !HasVolumeSpike())
   {
      SetSignalReason("No volume spike");
      return false;
   }
   if(Bars < 2)
   {
      SetSignalReason("Waiting for history");
      return false;
   }

   double prevHigh = iHigh(g_symbol, 0, 1);
   double prevLow  = iLow(g_symbol, 0, 1);

   bool priceBreak = (direction > 0) ? (g_bid > prevHigh) : (g_bid < prevLow);
   if(!priceBreak)
   {
      SetSignalReason(direction > 0 ? "Bid <= prev high" : "Bid >= prev low");
      return false;
   }

   if(!RequireTickAccelFilter)
      return true;

   if(direction > 0)
   {
      if(g_tickAcceleration < TickAccelThreshold)
      {
         SetSignalReason("Tick accel (buy) too weak");
         return false;
      }
      return true;
   }
   else
   {
      if(g_tickAcceleration > -TickAccelThreshold)
      {
         SetSignalReason("Tick accel (sell) too weak");
         return false;
      }
      return true;
   }
}

bool HasVolumeSpike()
{
   int depth = MathMax(3, VolumeLookback);
   if(Bars < depth + 3)
      return false;

   double sum = 0.0;
   for(int i=2; i<2 + depth; ++i)
      sum += iVolume(g_symbol, 0, i);

   double avg = sum / depth;
   double current = iVolume(g_symbol, 0, 1);
   if(avg <= 0.0)
      return (current > 0.0);

   return (current >= avg * VolumeSpikeMultiplier);
}

bool OpenEntry(int direction, const string tag)
{
   return ExecuteEntry(direction, tag, UseLimitEntries, LimitOffsetPoints);
}

bool ExecuteEntry(int direction, const string tag, bool useLimit, double offsetPoints)
{
   if(!RefreshSymbolRates())
      return false;

   double lots = NormalizeLots(AccountEquity() * LotMultiplier);
   if(lots < g_minLot)
      lots = g_minLot;

   double price = (direction > 0 ? g_ask : g_bid);
   int type = (direction > 0 ? OP_BUY : OP_SELL);
   bool pendingAttempt = false;
   double normalizedOffset = MathMax(offsetPoints, 0.0);
   double priceOffset = normalizedOffset * g_point;
   if(useLimit)
   {
      if(priceOffset <= 0.0)
         priceOffset = g_point;
      double desired = (direction > 0 ? price - priceOffset : price + priceOffset);
      price = NormalizeDouble(desired, g_digits);
      type = (direction > 0 ? OP_BUYLIMIT : OP_SELLLIMIT);
      pendingAttempt = true;
   }
   else
   {
      price = NormalizeDouble(price, g_digits);
   }

   color arrowColor = (direction > 0 ? clrLime : clrTomato);
   int ticket = OrderSend(g_symbol, type, lots, price, SlippagePoints, 0, 0, tag, MagicNumber, 0, arrowColor);

   if(ticket < 0 && pendingAttempt && LimitFallbackToMarket)
   {
      int err = GetLastError();
      Print("HybridTurboFlipper pending entry failed err=", err, ". Retrying as market order.");
      RefreshSymbolRates();
      double fallbackPrice = NormalizeDouble((direction > 0 ? g_ask : g_bid), g_digits);
      type = (direction > 0 ? OP_BUY : OP_SELL);
      ticket = OrderSend(g_symbol, type, lots, fallbackPrice, SlippagePoints, 0, 0, tag + " (mkt)", MagicNumber, 0, arrowColor);
   }

   if(ticket < 0)
   {
      Print("HybridTurboFlipper OrderSend failed. err=", GetLastError());
      return false;
   }

   RegisterTrade();

   if(g_stackLevelAchieved == 0)
   {
      g_cycleDirection = direction;
      if(OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
         g_firstEntryPrice = OrderOpenPrice();
      else
         g_firstEntryPrice = price;
      g_cyclePeakProfit = 0.0;
      g_runningProfit = 0.0;
   }

   g_stackLevelAchieved = MathMin(3, MathMax(1, g_stackLevelAchieved + 1));
   g_lastLotSize = lots;
   RegisterMemo(ticket);
   g_lastBlockReason = pendingAttempt ? "Limit entry placed" : "Market entry placed";
   return true;
}

void MaybeFireStarter()
{
   if(!EnableStarterTrades)
      return;
   if(StarterCooldownSeconds > 0 && g_lastStarterTime != 0)
   {
      if((TimeCurrent() - g_lastStarterTime) < StarterCooldownSeconds)
      {
         SetSignalReason("Starter cooldown");
         return;
      }
   }
   if(!EnableTrading || IsRolloverWindow())
      return;
   if(!IsSpreadCalm())
   {
     SetSignalReason("Starter blocked by spread");
     return;
   }
   if(Bars < SlowEMAPeriod + 2)
      return;

   double emaFast = iMA(g_symbol, 0, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaSlow = iMA(g_symbol, 0, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);

   int bias = 0;
   if(emaFast > emaSlow) bias = 1;
   else if(emaFast < emaSlow) bias = -1;

   if(bias == 0)
   {
      SetSignalReason("Starter waiting for EMA bias");
      return;
   }

   double starterOffset = StarterUseLimitEntries ? StarterLimitOffsetPoints : 0.0;
   if(starterOffset <= 0.0)
      starterOffset = LimitOffsetPoints;
   if(!StarterUseLimitEntries)
      starterOffset = 0.0;

   if(ExecuteEntry(bias, "HybridTurbo Starter", StarterUseLimitEntries, starterOffset))
   {
      g_lastStarterTime = TimeCurrent();
      g_lastBlockReason = "Starter entry placed";
   }
}

void RegisterTrade()
{
   EnsureTradeDay();
   g_tradesToday++;
}

int CountOpenPositions()
{
   int count = 0;
   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() == MagicNumber && OrderSymbol() == g_symbol)
         count++;
   }
   return count;
}

double GetTotalOpenProfit()
{
   double profit = 0.0;
   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != g_symbol)
         continue;
      profit += OrderProfit() + OrderSwap() + OrderCommission();
   }
   return profit;
}

void ManagePositions()
{
   PruneMemos();
   g_runningProfit = 0.0;
   int counted = 0;
   datetime earliestTime = 0;
   double earliestPrice = 0.0;
   int detectedDirection = g_cycleDirection;

   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != g_symbol)
         continue;

      counted++;
      g_runningProfit += OrderProfit() + OrderSwap() + OrderCommission();

      int direction = (OrderType() == OP_BUY ? 1 : -1);
      if(detectedDirection == 0)
         detectedDirection = direction;

      datetime openTime = OrderOpenTime();
      if(earliestTime == 0 || openTime < earliestTime)
      {
         earliestTime = openTime;
         earliestPrice = OrderOpenPrice();
      }

      HandlePartialClose(OrderTicket(), direction, OrderOpenPrice(), OrderLots());
   }

   if(counted == 0)
   {
      if(g_cycleDirection != 0)
         ResetCycleState();
      return;
   }

   g_cycleDirection = detectedDirection;
   if(earliestPrice > 0.0)
      g_firstEntryPrice = earliestPrice;
   if(g_stackLevelAchieved < counted)
      g_stackLevelAchieved = MathMin(3, counted);

   if(g_runningProfit > g_cyclePeakProfit)
      g_cyclePeakProfit = g_runningProfit;

   if(ShouldMomentumExit())
   {
      CloseAllPositions("Momentum exit");
      return;
   }
   if(ShouldRSIExit())
   {
      CloseAllPositions("RSI exit");
      return;
   }
   if(ShouldProfitDecayExit())
   {
      CloseAllPositions("Profit decay");
      return;
   }
   if(ShouldEmergencyExit())
   {
      CloseAllPositions("Emergency exit");
      return;
   }
}

void AttemptStackEntries()
{
   if(g_cycleDirection == 0)
      return;
   if(g_stackLevelAchieved >= 3)
      return;
   if(CountOpenPositions() == 0)
      return;
   if(g_firstEntryPrice <= 0.0)
      return;

   double favorablePoints = (g_cycleDirection > 0 ? (g_bid - g_firstEntryPrice) : (g_firstEntryPrice - g_bid)) / g_point;

   if(g_stackLevelAchieved < 2 && favorablePoints >= g_stackTrigger2)
   {
      if(AllowTradingNow())
         OpenEntry(g_cycleDirection, "HybridTurboFlipper Stack-2");
   }

   if(g_stackLevelAchieved < 3 && favorablePoints >= g_stackTrigger3)
   {
      if(AllowTradingNow())
         OpenEntry(g_cycleDirection, "HybridTurboFlipper Stack-3");
   }
}

void HandlePartialClose(int ticket, int direction, double openPrice, double lots)
{
   if(IsPartialTicket(ticket))
      return;

   double movePoints = (direction > 0 ? (g_bid - openPrice) : (openPrice - g_bid)) / g_point;
   if(movePoints < g_partialTriggerPoints)
      return;

   double closeLots = NormalizeCloseLots(lots * 0.5, lots);
   if(closeLots <= 0.0)
      return;

   if(!RefreshSymbolRates())
      return;

   double price = (direction > 0 ? g_bid : g_ask);
   if(OrderClose(ticket, closeLots, price, SlippagePoints, clrDodgerBlue))
   {
      MarkPartialTicket(ticket);
   }
}

bool ShouldMomentumExit()
{
   if(g_cycleDirection == 0)
      return false;
   if(Bars < SlowEMAPeriod + 2)
      return false;

   double emaFast = iMA(g_symbol, 0, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaSlow = iMA(g_symbol, 0, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);

   if(g_cycleDirection > 0)
      return (emaFast <= emaSlow);
   return (emaFast >= emaSlow);
}

bool ShouldRSIExit()
{
   if(g_cycleDirection == 0)
      return false;
   if(Bars < RSIPeriod + 2)
      return false;

   double rsi = iRSI(g_symbol, 0, RSIPeriod, PRICE_CLOSE, 0);
   if(g_cycleDirection > 0)
      return (rsi <= RSIBuyExitLevel);
   return (rsi >= RSISellExitLevel);
}

bool ShouldProfitDecayExit()
{
   if(g_cycleDirection == 0)
      return false;
   if(ProfitDecayPercent <= 0.0)
      return false;
   if(g_cyclePeakProfit <= 0.0)
      return false;

   double threshold = g_cyclePeakProfit * (1.0 - ProfitDecayPercent / 100.0);
   return (g_runningProfit <= threshold);
}

bool ShouldEmergencyExit()
{
   if(g_cycleDirection == 0)
      return false;

   double limit = MathMax(10.0, EmergencyExitPoints);
   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != g_symbol)
         continue;

      int direction = (OrderType() == OP_BUY ? 1 : -1);
      double adverse = (direction > 0 ? (OrderOpenPrice() - g_bid) : (g_bid - OrderOpenPrice())) / g_point;
      if(adverse >= limit)
         return true;
   }
   return false;
}

void CloseAllPositions(const string reason)
{
   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != g_symbol)
         continue;

      int type = OrderType();
      double lots = OrderLots();
      if(!RefreshSymbolRates())
         return;
      double price = (type == OP_BUY ? g_bid : g_ask);
      if(!OrderClose(OrderTicket(), lots, price, SlippagePoints, clrWhite))
      {
         Print("HybridTurboFlipper close failed ticket=", OrderTicket(), " err=", GetLastError());
      }
   }
   Print("HybridTurboFlipper exit reason: ", reason);
   PruneMemos();
}

void UpdatePanel(double projectedLots)
{
   double spreadPoints = (g_ask - g_bid) / g_point;
   double spreadPips = PointsToPips(spreadPoints);
   int entries = CountOpenPositions();
   double peak = g_cyclePeakProfit;
   double decay = (peak > 0.0 ? (peak - g_runningProfit) / peak * 100.0 : 0.0);
   if(decay < 0.0)
      decay = 0.0;
   double lotForRatio = (g_lastLotSize > 0.0 ? g_lastLotSize : projectedLots);
   double flipPower = (AccountEquity() > 0.0 ? lotForRatio / AccountEquity() : 0.0);

   string panel =
      StringFormat("HybridTurboFlipper\nTrend: %s\nLot (proj): %.2f\nTick Accel: %.4f\nSpread: %.2f pips\nEquity: %.2f\nEntries: %d\nRun Profit: %.2f\nPeak Profit: %.2f\nDecay: %.1f%%\nFlip Power: %.4f",
         TrendLabel(), projectedLots, g_tickAcceleration, spreadPips, AccountEquity(), entries, g_runningProfit, peak, decay, flipPower);

   if(ShowBlockReasonOnPanel)
   {
      panel += StringFormat("\nSignal: %s\nBlock: %s", g_lastSignalReason, g_lastBlockReason);
   }

   Comment(panel);
}

string TrendLabel()
{
   if(Bars < SlowEMAPeriod + 2)
      return "Booting";

   double emaFast = iMA(g_symbol, 0, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaSlow = iMA(g_symbol, 0, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);

   if(emaFast > emaSlow)
      return "Turbo Bull";
   if(emaFast < emaSlow)
      return "Turbo Bear";
   return "Neutral";
}

double NormalizeLots(double lots)
{
   if(lots <= 0.0)
      lots = g_minLot;

   double steps = MathFloor(lots / g_lotStep + 0.5);
   double normalized = steps * g_lotStep;
   if(normalized < g_minLot)
      normalized = g_minLot;
   if(normalized > g_maxLot)
      normalized = g_maxLot;
   return NormalizeDouble(normalized, g_lotDigits);
}

double NormalizeCloseLots(double desired, double maxLots)
{
   if(desired <= 0.0)
      desired = g_minLot;

   double steps = MathFloor(desired / g_lotStep + 0.5);
   double normalized = steps * g_lotStep;
   if(normalized < g_minLot)
   {
      if(maxLots <= g_minLot + 1e-9)
         normalized = maxLots;
      else
         normalized = g_minLot;
   }
   if(normalized > maxLots)
      normalized = maxLots;
   return NormalizeDouble(normalized, g_lotDigits);
}

double PointsToPips(double points)
{
   if(g_pipFactor <= 0.0)
      return 0.0;
   return points / g_pipFactor;
}

void RegisterMemo(int ticket)
{
   if(ticket <= 0)
      return;

   for(int i=0; i<3; ++i)
   {
      if(g_memos[i].ticket == ticket)
         return;
   }

   for(int j=0; j<3; ++j)
   {
      if(g_memos[j].ticket <= 0)
      {
         g_memos[j].ticket = ticket;
         g_memos[j].partialDone = false;
         return;
      }
   }

   g_memos[0].ticket = ticket;
   g_memos[0].partialDone = false;
}

bool IsPartialTicket(int ticket)
{
   for(int i=0; i<3; ++i)
   {
      if(g_memos[i].ticket == ticket)
         return g_memos[i].partialDone;
   }
   return false;
}

void MarkPartialTicket(int ticket)
{
   for(int i=0; i<3; ++i)
   {
      if(g_memos[i].ticket == ticket)
      {
         g_memos[i].partialDone = true;
         return;
      }
   }
   RegisterMemo(ticket);
   MarkPartialTicket(ticket);
}

void PruneMemos()
{
   for(int i=0; i<3; ++i)
   {
      if(g_memos[i].ticket <= 0)
         continue;
      if(!OrderSelect(g_memos[i].ticket, SELECT_BY_TICKET, MODE_TRADES))
      {
         g_memos[i].ticket = 0;
         g_memos[i].partialDone = false;
      }
   }
}

double GetPartialTrigger()
{
   double low = MathMax(1.0, PartialCloseMinPoints);
   double high = MathMax(low, PartialCloseMaxPoints);
   if(high <= low)
      return low;
   return (low + high) * 0.5;
}

void SetSignalReason(const string reason)
{
   g_lastSignalReason = reason;
}

string NormalizeSymbolKey(string name)
{
   string upper = StringToUpper(name);
   string result = "";
   int len = StringLen(upper);
   for(int i=0; i<len; ++i)
   {
      string ch = StringSubstr(upper, i, 1);
      if(ch == " " || ch == "." || ch == "_" || ch == "-" || ch == "/")
         continue;
      result += ch;
   }
   return result;
}

bool SymbolMatchesKey(string desiredKey, string candidateName)
{
   string candidateKey = NormalizeSymbolKey(candidateName);
   if(StringLen(candidateKey) == 0 || StringLen(desiredKey) == 0)
      return false;

   if(candidateKey == desiredKey)
      return true;

   if(StringFind(candidateKey, desiredKey) >= 0)
      return true;

   if(StringFind(desiredKey, candidateKey) >= 0)
      return true;

   if(StringFind(desiredKey, "XAUUSD") >= 0)
   {
      if(StringFind(candidateKey, "XAU") >= 0 && StringFind(candidateKey, "USD") >= 0)
         return true;
   }
   return false;
}

