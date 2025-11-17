#property copyright "Copyright 2025"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "2.00"
#property strict

//==================================================================
// QuickScalperPro v2
// Aggressive tick scalper with adaptive risk, trend filters,
// dynamic trade management, and basket controls.
//==================================================================

input group "===== General Settings ====="
input string   EAName                  = "QuickScalperPro v2";
input int      MagicNumber             = 202502;
input bool     TradeEnabled            = true;
input bool     UseGoldOnly             = true;
input bool     AllowBuySignals         = true;
input bool     AllowSellSignals        = true;
input int      MaxTrades               = 12;
input int      MaxTradesPerBurst       = 3;
input int      BurstSpacingMS          = 150;
input int      MaxDailyTrades          = 200;
input double   MinLotSize              = 0.01;
input double   MaxLotSize              = 2.00;
input double   SlippagePips            = 2.0;

input group "===== Market Filters ====="
input double   MaxSpreadPips           = 3.0;
input bool     UseSessionFilter        = true;
input int      SessionStartHour        = 7;
input int      SessionEndHour          = 20;
input bool     BlockHighImpactNews     = false;  // placeholder switch for manual control

input group "===== Trend & Momentum Filter ====="
input ENUM_TIMEFRAMES SignalTimeframe  = PERIOD_M1;
input int      FastMAPeriod            = 10;
input int      SlowMAPeriod            = 20;
input int      RSIPeriod               = 9;
input double   RSIMidThreshold         = 50.0;
input double   MomentumBand            = 20.0;
input bool     OnlyTrendAlignedTrades  = true;
input ENUM_TIMEFRAMES HTFTimeframe     = PERIOD_M15;
input int      HTFTrendPeriod          = 50;
input double   HTFTrendSlopeFilter     = 0.0005;

input group "===== Volatility Filter ====="
input ENUM_TIMEFRAMES ATRTimeframe     = PERIOD_M5;
input int      ATRPeriod               = 14;
input double   MinATRPoints            = 100.0;
input double   MaxATRPoints            = 800.0;
input int      ATRSlopeLookback        = 4;

input group "===== Risk Management ====="
input double   RiskPerTradePercent     = 0.30;
input double   MaxOpenRiskPercent      = 2.0;
input double   MaxDailyDrawdownPercent = 6.0;
input double   BasketLossPercent       = 2.5;
input double   BasketTargetPercent     = 3.5;
input double   DailyProfitTargetPercent= 5.0;
input double   CooldownDrawdownPercent = 3.0;
input int      CooldownMinutes         = 45;
input double   EquityHardStopPercent   = 8.0;

input group "===== Trade Management ====="
input double   ATRStopMultiplier       = 2.2;
input double   ATRTrailMultiplier      = 1.5;
input double   ATRBreakEvenMultiplier  = 1.0;
input double   ATRPartialRR            = 1.0;
input double   PartialCloseRatio       = 0.5;
input double   TrailStartRR            = 1.5;
input double   MaxHoldSeconds          = 1800;

input group "===== Logging & Monitoring ====="
input bool     PrintDiagnostics        = true;
input bool     UseGlobalState          = true;

struct ManagedTrade
{
   int      ticket;
   int      direction;
   double   entryPrice;
   double   stopPrice;
   double   initialRiskPoints;
   double   riskAmount;
   double   atrAtEntry;
   bool     partialTaken;
   datetime openTime;
   ulong    openTick;
};

ManagedTrade trades[50];
int totalTrades = 0;

double basketPeakProfit = 0;
bool basketTrailing     = false;
double tradingDayStartBalance = 0;
double dailyProfitCurrency    = 0;
double dailyDrawdownPercent   = 0;
int    dailyTradeCount        = 0;
int    consecutiveLosses      = 0;
datetime cooldownUntil        = 0;
double sessionHighEquity      = 0;

// Global variable keys
string gvPrefix;

void ResetManagedTrades()
{
   totalTrades = 0;
   for(int i = 0; i < ArraySize(trades); i++)
   {
      trades[i].ticket = 0;
      trades[i].direction = 0;
      trades[i].entryPrice = 0.0;
      trades[i].stopPrice = 0.0;
      trades[i].initialRiskPoints = 0.0;
      trades[i].riskAmount = 0.0;
      trades[i].atrAtEntry = 0.0;
      trades[i].partialTaken = false;
      trades[i].openTime = 0;
      trades[i].openTick = 0;
   }
   basketPeakProfit = 0.0;
   basketTrailing = false;
   tradingDayStartBalance = AccountBalance();
   sessionHighEquity = AccountEquity();
   dailyProfitCurrency = 0.0;
   dailyDrawdownPercent = 0.0;
   dailyTradeCount = 0;
   consecutiveLosses = 0;
   cooldownUntil = 0;
}

//==================================================================
int OnInit()
{
   if(UseGoldOnly && Symbol() != "XAUUSD")
   {
      Alert(EAName, ": This EA is optimised for XAUUSD only.");
      return(INIT_FAILED);
   }

   gvPrefix = EAName + "_" + Symbol();

   ResetManagedTrades();

   if(UseGlobalState)
      LoadGlobalState();

   if(PrintDiagnostics)
   {
      Print(EAName, " initialised on ", Symbol(),
            " | Balance: ", DoubleToString(AccountBalance(), 2),
            " | Magic: ", MagicNumber);
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(UseGlobalState)
      SaveGlobalState();

   if(PrintDiagnostics)
      Print(EAName, " deinitialised. reason=", reason);
}

void OnTick()
{
   if(!TradeEnabled)
      return;

   RefreshRates();

   CheckDailyReset();
   UpdateSessionEquityStats();

   if(!PreFlightChecks())
      return;

   ManageTrades();
   CleanupClosedTrades();

   if(!CanTradeNow())
      return;

   int signal = GetTradingSignal();
   if(signal != -1)
      ExecuteBurst(signal);
}

//==================================================================
bool PreFlightChecks()
{
   if(UseGoldOnly && Symbol() != "XAUUSD")
      return(false);

   if(!IsTradeAllowed())
      return(false);

   if(MaxSpreadPips > 0 && CurrentSpreadPips() > MaxSpreadPips)
      return(false);

   if(UseSessionFilter && !IsSessionOpen())
      return(false);

   if(BlockHighImpactNews)
      return(false);

   if(TimeCurrent() < cooldownUntil)
      return(false);

   if(AccountEquity() <= 0)
      return(false);

   if(EquityExceededHardStop())
      return(false);

   if(MaxDailyDrawdownPercent > 0 && dailyDrawdownPercent >= MaxDailyDrawdownPercent)
      return(false);

   if(DailyProfitTargetPercent > 0 && GetDailyProfitPercent() >= DailyProfitTargetPercent)
      return(false);

   return(true);
}

bool CanTradeNow()
{
   if(dailyTradeCount >= MaxDailyTrades)
      return(false);

   if(totalTrades >= MaxTrades)
      return(false);

   if(GetOpenRiskPercent() >= MaxOpenRiskPercent)
      return(false);

   return(true);
}

int GetTradingSignal()
{
   if(MaxSpreadPips > 0 && CurrentSpreadPips() > MaxSpreadPips)
      return(-1);

   if(!IsVolatilityAcceptable())
      return(-1);

   int signal = EvaluateSignal();

   if(signal == OP_BUY && !AllowBuySignals)
      return(-1);
   if(signal == OP_SELL && !AllowSellSignals)
      return(-1);

   return(signal);
}

int EvaluateSignal()
{
   double fastMA = iMA(Symbol(), SignalTimeframe, FastMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double slowMA = iMA(Symbol(), SignalTimeframe, SlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi    = iRSI(Symbol(), SignalTimeframe, RSIPeriod, PRICE_CLOSE, 0);
   double price  = (Ask + Bid) / 2.0;
   double prevClose = iClose(Symbol(), SignalTimeframe, 1);
   double currClose = iClose(Symbol(), SignalTimeframe, 0);

   bool uptrend = fastMA > slowMA;
   bool downtrend = fastMA < slowMA;
   bool priceAboveMA = price > fastMA;
   bool priceBelowMA = price < fastMA;
   bool bullishMomentum = rsi > RSIMidThreshold && rsi < (RSIMidThreshold + MomentumBand);
   bool bearishMomentum = rsi < RSIMidThreshold && rsi > (RSIMidThreshold - MomentumBand);
   bool oversold = rsi <= (RSIMidThreshold - MomentumBand);
   bool overbought = rsi >= (RSIMidThreshold + MomentumBand);
   bool rising = currClose > prevClose;
   bool falling = currClose < prevClose;

   int buyScore = 0;
   int sellScore = 0;

   if(uptrend) buyScore++;
   if(priceAboveMA) buyScore++;
   if(bullishMomentum || oversold) buyScore++;
   if(rising) buyScore++;

   if(downtrend) sellScore++;
   if(priceBelowMA) sellScore++;
   if(bearishMomentum || overbought) sellScore++;
   if(falling) sellScore++;

   if(OnlyTrendAlignedTrades && !IsHigherTimeframeAligned(uptrend, downtrend))
   {
      buyScore = 0;
      sellScore = 0;
   }

   if(consecutiveLosses >= 3)
   {
      if(buyScore < 3) buyScore = 0;
      if(sellScore < 3) sellScore = 0;
   }

   if(buyScore == sellScore)
      return(-1);

   if(buyScore >= 2 && buyScore > sellScore)
      return(OP_BUY);

   if(sellScore >= 2 && sellScore > buyScore)
      return(OP_SELL);

   return(-1);
}

bool IsHigherTimeframeAligned(bool uptrend, bool downtrend)
{
   double htfFast = iMA(Symbol(), HTFTimeframe, HTFTrendPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double htfSlow = iMA(Symbol(), HTFTimeframe, HTFTrendPeriod * 2, 0, MODE_EMA, PRICE_CLOSE, 0);
   double htfFastPrev = iMA(Symbol(), HTFTimeframe, HTFTrendPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);

   double slope = htfFast - htfFastPrev;

   if(uptrend)
   {
      if(htfFast <= htfSlow) return(false);
      if(MathAbs(slope) < HTFTrendSlopeFilter) return(false);
      if(slope <= 0) return(false);
      return(true);
   }

   if(downtrend)
   {
      if(htfFast >= htfSlow) return(false);
      if(MathAbs(slope) < HTFTrendSlopeFilter) return(false);
      if(slope >= 0) return(false);
      return(true);
   }

   return(false);
}

bool IsVolatilityAcceptable()
{
   double atrNow = iATR(Symbol(), ATRTimeframe, ATRPeriod, 0) / Point;
   double atrPrev = iATR(Symbol(), ATRTimeframe, ATRPeriod, ATRSlopeLookback) / Point;

   if(atrNow <= 0) return(false);

   if(atrNow < MinATRPoints || atrNow > MaxATRPoints)
      return(false);

   if(atrNow < atrPrev)
      return(false);

   return(true);
}

void ExecuteBurst(int orderType)
{
   ulong nowTick = GetTickCount();

   for(int i=0; i<MaxTradesPerBurst; i++)
   {
      if(!CanTradeNow())
         break;

      if(orderType == OP_BUY)
      {
         if(!OpenAdaptiveTrade(OP_BUY, nowTick))
            break;
      }
      else if(orderType == OP_SELL)
      {
         if(!OpenAdaptiveTrade(OP_SELL, nowTick))
            break;
      }

      if(i < MaxTradesPerBurst - 1 && BurstSpacingMS > 0)
      {
         ulong startTick = GetTickCount();
         while(GetTickCount() - startTick < (ulong)BurstSpacingMS)
         {
            Sleep(10);
         }
      }
   }
}

bool OpenAdaptiveTrade(int orderType, ulong nowTick)
{
   double atr = iATR(Symbol(), ATRTimeframe, ATRPeriod, 0);
   if(atr <= 0) return(false);

   double stopDistance = atr * ATRStopMultiplier;
   if(stopDistance <= 0) return(false);

   double riskCurrency = AccountBalance() * (RiskPerTradePercent / 100.0);
   if(riskCurrency <= 0) return(false);

   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
   if(tickValue <= 0 || tickSize <= 0) return(false);

   double stopTicks = stopDistance / tickSize;
   double riskPerLot = stopTicks * tickValue;
   if(riskPerLot <= 0) return(false);

   double lotSize = riskCurrency / riskPerLot;
   lotSize = NormalizeDouble(lotSize, 2);
   lotSize = MathMax(lotSize, MinLotSize);
   lotSize = MathMin(lotSize, MaxLotSize);

   if(GetOpenRiskPercent() + RiskPerTradePercent > MaxOpenRiskPercent)
   {
      if(PrintDiagnostics)
         Print("Risk capped: open risk would exceed limit.");
      return(false);
   }

   double price = (orderType == OP_BUY) ? Ask : Bid;
   double stopPrice = (orderType == OP_BUY) ? price - stopDistance : price + stopDistance;
   stopPrice = NormalizeDouble(stopPrice, Digits);

   double volume = NormalizeDouble(lotSize, 2);
   double slippagePoints = SlippagePips * Point * 10.0;

   string comment = EAName + " " + (orderType == OP_BUY ? "BUY" : "SELL");
   int ticket = OrderSend(Symbol(), orderType, volume, price, (int)MathCeil(slippagePoints),
                          stopPrice, 0, comment, MagicNumber, 0,
                          (orderType == OP_BUY) ? clrGreen : clrRed);

   if(ticket < 0)
   {
      int error = GetLastError();
      if(PrintDiagnostics)
         Print("OrderSend failed: ", error);
      return(false);
   }

   if(dailyTradeCount < INT_MAX) dailyTradeCount++;

   if(totalTrades < ArraySize(trades))
   {
      trades[totalTrades].ticket = ticket;
      trades[totalTrades].direction = orderType;
      trades[totalTrades].entryPrice = price;
      trades[totalTrades].stopPrice = stopPrice;
      trades[totalTrades].initialRiskPoints = stopDistance / Point;
      trades[totalTrades].riskAmount = riskCurrency;
      trades[totalTrades].atrAtEntry = atr;
      trades[totalTrades].partialTaken = false;
      trades[totalTrades].openTime = TimeCurrent();
      trades[totalTrades].openTick = nowTick;
      totalTrades++;
   }

   if(PrintDiagnostics)
   {
      Print("Opened ", (orderType == OP_BUY ? "BUY" : "SELL"),
            " ticket=", ticket,
            " lot=", DoubleToString(volume, 2),
            " stop=", DoubleToString(stopPrice, Digits),
            " ATR=", DoubleToString(atr, Digits),
            " risk=", DoubleToString(riskCurrency, 2));
   }

   return(true);
}

void ManageTrades()
{
   double totalProfit = 0;
   double openRisk = 0;
   basketPeakProfit = MathMax(basketPeakProfit, 0);

   for(int i = totalTrades - 1; i >= 0; i--)
   {
      int ticket = trades[i].ticket;
      if(ticket <= 0) continue;

      if(!OrderSelect(ticket, SELECT_BY_TICKET))
         continue;

      double tradeProfit = OrderProfit() + OrderSwap() + OrderCommission();
      totalProfit += tradeProfit;

      double rr = 0;
      if(trades[i].riskAmount > 0)
         rr = tradeProfit / trades[i].riskAmount;

      ApplyBreakEven(ticket, i, rr);
      ApplyPartialClose(ticket, i, rr);
      ApplyTrailingStop(ticket, i, rr);
      CheckMaxHoldDuration(ticket, i);

      openRisk += trades[i].riskAmount;
   }

   ManageBasket(totalProfit);
}

void ApplyBreakEven(int ticket, int index, double rr)
{
   if(rr < (ATRBreakEvenMultiplier / ATRStopMultiplier))
      return;

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return;

   double entry = trades[index].entryPrice;
   double stop  = OrderStopLoss();

   if(stop == 0)
      stop = trades[index].stopPrice;

   if(trades[index].direction == OP_BUY && stop < entry)
   {
      ModifyOrderStop(ticket, entry);
   }
   else if(trades[index].direction == OP_SELL && stop > entry)
   {
      ModifyOrderStop(ticket, entry);
   }
}

void ApplyPartialClose(int ticket, int index, double rr)
{
   if(trades[index].partialTaken)
      return;

   if(rr < ATRPartialRR)
      return;

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return;

   double volume = OrderLots();
   double closeVolume = NormalizeDouble(volume * PartialCloseRatio, 2);
   if(closeVolume <= 0) return;
   if(volume - closeVolume < MinLotSize / 2.0) return;

   double closePrice = (trades[index].direction == OP_BUY) ? Bid : Ask;
   if(OrderClose(ticket, closeVolume, closePrice, (int)MathCeil(SlippagePips), clrYellow))
   {
      trades[index].partialTaken = true;
      if(PrintDiagnostics)
         Print("Partial close executed on ", ticket, " volume=", DoubleToString(closeVolume, 2));
   }
}

void ApplyTrailingStop(int ticket, int index, double rr)
{
   if(rr < TrailStartRR)
      return;

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return;

   double atr = iATR(Symbol(), ATRTimeframe, ATRPeriod, 0);
   if(atr <= 0) return;

   double trailDistance = atr * ATRTrailMultiplier;
   if(trailDistance <= 0) return;

   double newStop;
   if(trades[index].direction == OP_BUY)
   {
      newStop = NormalizeDouble(Bid - trailDistance, Digits);
      if(newStop <= OrderStopLoss())
         return;
   }
   else
   {
      newStop = NormalizeDouble(Ask + trailDistance, Digits);
      if(newStop >= OrderStopLoss() || OrderStopLoss() == 0)
      {
         if(OrderStopLoss() != 0 && newStop >= OrderStopLoss())
            return;
      }
   }

   ModifyOrderStop(ticket, newStop);
}

void CheckMaxHoldDuration(int ticket, int index)
{
   if(MaxHoldSeconds <= 0)
      return;

   datetime openTime = trades[index].openTime;
   if(TimeCurrent() - openTime < MaxHoldSeconds)
      return;

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return;

   double closePrice = (trades[index].direction == OP_BUY) ? Bid : Ask;
   bool closed = OrderClose(ticket, OrderLots(), closePrice, (int)MathCeil(SlippagePips), clrOrange);
   if(!closed && PrintDiagnostics)
      Print("Max hold close failed ticket=", ticket, " error=", GetLastError());
}

void ModifyOrderStop(int ticket, double newStop)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return;

   double price = OrderOpenPrice();
   double tp = OrderTakeProfit();

   if(!OrderModify(ticket, price, newStop, tp, OrderExpiration()))
   {
      if(PrintDiagnostics)
         Print("OrderModify failed ticket=", ticket, " error=", GetLastError());
   }
}

void ManageBasket(double totalProfit)
{
   if(totalProfit > basketPeakProfit)
      basketPeakProfit = totalProfit;

   double balance = tradingDayStartBalance;
   double targetCurrency = balance * (BasketTargetPercent / 100.0);
   double lossCurrency   = balance * (BasketLossPercent / 100.0);

   if(totalTrades == 0)
   {
      basketPeakProfit = 0;
      basketTrailing = false;
      return;
   }

   if(totalProfit >= targetCurrency && totalProfit > 0)
   {
      CloseAllTrades("Basket target reached");
      return;
   }

   if(totalProfit <= -lossCurrency)
   {
      CloseAllTrades("Basket loss limit");
      ActivateCooldown();
      return;
   }

   if(totalProfit >= targetCurrency / 2.0)
   {
      basketTrailing = true;
      double trailLevel = basketPeakProfit - (targetCurrency * 0.35);
      if(totalProfit <= trailLevel)
      {
         CloseAllTrades("Basket trailing stop");
         return;
      }
   }
}

void CloseAllTrades(string reason)
{
   if(PrintDiagnostics)
      Print("Closing basket: ", reason);

   for(int i = totalTrades - 1; i >= 0; i--)
   {
      int ticket = trades[i].ticket;
      if(ticket <= 0) continue;

      if(!OrderSelect(ticket, SELECT_BY_TICKET))
         continue;

      double closePrice = (trades[i].direction == OP_BUY) ? Bid : Ask;
      bool closed = OrderClose(ticket, OrderLots(), closePrice, (int)MathCeil(SlippagePips), clrRed);
      if(!closed && PrintDiagnostics)
         Print("Basket close failed ticket=", ticket, " error=", GetLastError());
   }
}

void CleanupClosedTrades()
{
   for(int i = totalTrades - 1; i >= 0; i--)
   {
      int ticket = trades[i].ticket;
      if(ticket <= 0)
         continue;

      if(OrderSelect(ticket, SELECT_BY_TICKET))
         continue;

      if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY))
         continue;

      double finalPL = OrderProfit() + OrderSwap() + OrderCommission();
      dailyProfitCurrency += finalPL;

      if(finalPL < 0)
      {
         consecutiveLosses++;
         UpdateDrawdown();
      }
      else
      {
         consecutiveLosses = MathMax(consecutiveLosses - 1, 0);
      }

      for(int j = i; j < totalTrades - 1; j++)
         trades[j] = trades[j + 1];

      trades[totalTrades - 1].ticket = 0;
      totalTrades--;
   }
}

void CheckDailyReset()
{
   datetime currentDay = iTime(Symbol(), PERIOD_D1, 0);
   static datetime storedDay = 0;

   if(storedDay == 0)
      storedDay = currentDay;

   if(currentDay != storedDay)
   {
      if(PrintDiagnostics)
      {
         Print("Daily reset. Profit=", DoubleToString(dailyProfitCurrency, 2),
               " trades=", dailyTradeCount);
      }

      storedDay = currentDay;
      tradingDayStartBalance = AccountBalance();
      dailyProfitCurrency = 0;
      dailyDrawdownPercent = 0;
      dailyTradeCount = 0;
      consecutiveLosses = 0;
      cooldownUntil = 0;
      sessionHighEquity = AccountEquity();
      basketPeakProfit = 0;
   }
}

void UpdateSessionEquityStats()
{
   sessionHighEquity = MathMax(sessionHighEquity, AccountEquity());
   UpdateDrawdown();
}

void UpdateDrawdown()
{
   double equity = AccountEquity();
   if(equity <= 0) return;

   double drop = sessionHighEquity - equity;
   if(sessionHighEquity > 0)
      dailyDrawdownPercent = MathMax(dailyDrawdownPercent, (drop / sessionHighEquity) * 100.0);

   if(dailyDrawdownPercent >= CooldownDrawdownPercent)
      ActivateCooldown();
}

void ActivateCooldown()
{
   if(CooldownMinutes <= 0)
      return;

   datetime newCooldown = TimeCurrent() + CooldownMinutes * 60;
   if(newCooldown > cooldownUntil)
   {
      cooldownUntil = newCooldown;
      if(PrintDiagnostics)
         Print("Cooldown active until ", TimeToString(cooldownUntil, TIME_DATE|TIME_MINUTES));
   }
}

// Helpers =========================================================
double CurrentSpreadPips()
{
   return ((Ask - Bid) / Point) / 10.0;
}

bool IsSessionOpen()
{
   int hour = TimeHour(TimeCurrent());
   if(SessionStartHour <= SessionEndHour)
      return(hour >= SessionStartHour && hour < SessionEndHour);
   return(hour >= SessionStartHour || hour < SessionEndHour);
}

double GetOpenRiskPercent()
{
   double totalRisk = 0;
   for(int i=0; i<totalTrades; i++)
      totalRisk += trades[i].riskAmount;

   if(AccountBalance() <= 0)
      return(0);

   return(totalRisk / AccountBalance() * 100.0);
}

double GetDailyProfitPercent()
{
   if(tradingDayStartBalance <= 0)
      return(0);

   return((AccountBalance() - tradingDayStartBalance) / tradingDayStartBalance * 100.0);
}

bool EquityExceededHardStop()
{
   if(EquityHardStopPercent <= 0)
      return(false);

   double lossPercent = (tradingDayStartBalance - AccountEquity()) / tradingDayStartBalance * 100.0;
   return(lossPercent >= EquityHardStopPercent);
}

void LoadGlobalState()
{
   string keyBalance = gvPrefix + "_startBal";
   string keyProfit  = gvPrefix + "_dailyPL";
   string keyTrades  = gvPrefix + "_tradeCount";
   string keyLosses  = gvPrefix + "_losses";
   string keyCooldown= gvPrefix + "_cooldown";

   if(GlobalVariableCheck(keyBalance))
      tradingDayStartBalance = GlobalVariableGet(keyBalance);

   if(GlobalVariableCheck(keyProfit))
      dailyProfitCurrency = GlobalVariableGet(keyProfit);

   if(GlobalVariableCheck(keyTrades))
      dailyTradeCount = (int)GlobalVariableGet(keyTrades);

   if(GlobalVariableCheck(keyLosses))
      consecutiveLosses = (int)GlobalVariableGet(keyLosses);

   if(GlobalVariableCheck(keyCooldown))
      cooldownUntil = (datetime)GlobalVariableGet(keyCooldown);
}

void SaveGlobalState()
{
   GlobalVariableSet(gvPrefix + "_startBal", tradingDayStartBalance);
   GlobalVariableSet(gvPrefix + "_dailyPL", dailyProfitCurrency);
   GlobalVariableSet(gvPrefix + "_tradeCount", (double)dailyTradeCount);
   GlobalVariableSet(gvPrefix + "_losses", (double)consecutiveLosses);
   GlobalVariableSet(gvPrefix + "_cooldown", (double)cooldownUntil);
}


