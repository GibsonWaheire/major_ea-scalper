#property copyright "Smart Momentum Labs"
#property link      "https://www.example.com"
#property version   "1.00"
#property strict

// ---------------------------------------------------------------------------
// SmartMomentumScalper_Aggressive
// A clean, single-trade scalper implementing advanced momentum, volatility,
// and exit management per the provided specifications.
// ---------------------------------------------------------------------------

// ==== Input Configuration ====================================================
input group "Trade Session & Limits"
input ENUM_TIMEFRAMES   SignalTimeframe        = PERIOD_M1;
input int               SessionStartUTC        = 2;      // 02:00 UTC
input int               SessionEndUTC          = 11;     // 11:00 UTC
input int               DailyTradeLimit        = 40;
input int               RolloverStartMinute    = 59;     // 23:59 server time
input int               RolloverEndMinute      = 10;     // 00:10 server time

input group "Risk Management"
input double            RiskPercentPerTrade    = 1.5;
input double            MaxSpreadPips          = 6.0;
input double            SlippagePips           = 2.0;
input int               MagicNumber            = 990001;

input group "Momentum Filters"
input double            MinCandleBodyPoints    = 30;
input double            MinTickAccelerationPts = 10;
input int               TickAccelerationWindow = 10;
input double            RSIUpper               = 55.0;
input double            RSILower               = 45.0;

input group "Volatility Engine"
input double            AtrVolatilityMaxPips   = 60.0;   // ATR14 must stay below this
input double            AtrStopMultiplier      = 2.5;
input double            AtrTakeMultiplier      = 3.0;
input double            VolatilitySpikeFactor  = 1.8;

input group "Smart Exit Engine"
input int               MaxBarsInTrade         = 4;
input double            ProfitDecayThreshold   = 0.60;   // 60% of peak
input double            ReversalBodyAtrRatio   = 0.50;
input double            SpreadSpikeFactor      = 1.8;
input double            PartialCloseRatio      = 0.3;
input double            PartialTriggerRatio    = 0.5;
input double            PartialSLBufferPips    = 2.0;

input group "Display"
input color             PanelTextColor         = clrWhite;
input color             PanelValueColor        = clrAqua;

// ==== Global State ===========================================================
struct ActiveTrade
{
   int      ticket;
   int      type;
   double   lots;
   double   initialLots;
   double   entryPrice;
   double   stopLoss;
   double   takeProfit;
   datetime openTime;
   datetime lastManaged;
   bool     partialDone;
   double   peakProfit;
};

ActiveTrade g_trade;
bool        g_tradeActive = false;

double   g_tickHistory[64];
int      g_tickCount = 0;
int      g_tickIndex = 0;

datetime g_dayMarker = 0;
int      g_tradesToday = 0;

string   g_panelText = "";

// ---------------------------------------------------------------------------
int OnInit()
{
   InitializeTradeState();
   g_dayMarker = DateOfDay(TimeCurrent());
   g_tradesToday = 0;
   Comment("");
   SyncTradeState(); // in case EA was attached with open trades
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Comment("");
}

void OnTick()
{
   RefreshRates();
   UpdateTickBuffer();
   UpdateDailyCounter();

   if(g_tradeActive)
      ManageActiveTrade();
   else
      TryOpenTrade();

   UpdateDisplay();
}

// ---------------------------------------------------------------------------
void InitializeTradeState()
{
   g_trade.ticket = -1;
   g_trade.type = -1;
   g_trade.lots = 0;
    g_trade.initialLots = 0;
   g_trade.entryPrice = 0;
   g_trade.stopLoss = 0;
   g_trade.takeProfit = 0;
   g_trade.openTime = 0;
   g_trade.partialDone = false;
   g_trade.peakProfit = 0;
   g_trade.lastManaged = 0;
   g_tradeActive = false;
}

// ---------------------------------------------------------------------------
void UpdateTickBuffer()
{
   double mid = (Bid + Ask) * 0.5;
   g_tickHistory[g_tickIndex] = mid;
   g_tickIndex = (g_tickIndex + 1) % ArraySize(g_tickHistory);
   if(g_tickCount < ArraySize(g_tickHistory))
      g_tickCount++;
}

// ---------------------------------------------------------------------------
void UpdateDailyCounter()
{
   datetime today = DateOfDay(TimeCurrent());
   if(today != g_dayMarker)
   {
      g_dayMarker = today;
      g_tradesToday = 0;
   }
}

datetime DateOfDay(datetime ts)
{
   MqlDateTime dt;
   TimeToStruct(ts, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return(StructToTime(dt));
}

// ---------------------------------------------------------------------------
bool CanTradeNow()
{
   datetime nowUTC = TimeGMT();
   MqlDateTime tm;
   TimeToStruct(nowUTC, tm);
   int hourUTC = tm.hour;
   bool withinSession = (hourUTC >= SessionStartUTC && hourUTC < SessionEndUTC);
   if(!withinSession)
      return(false);

   // Rollover window uses server time
   datetime nowServer = TimeCurrent();
   TimeToStruct(nowServer, tm);
   if((tm.hour == 23 && tm.min >= RolloverStartMinute) ||
      (tm.hour == 0 && tm.min <= RolloverEndMinute))
      return(false);

   if(g_tradesToday >= DailyTradeLimit)
      return(false);

   return(true);
}

// ---------------------------------------------------------------------------
void TryOpenTrade()
{
   if(!CanTradeNow())
      return;

   if(HasManagedTrade())
      return;

   if(!SpreadAcceptable())
      return;

   double atr14 = iATR(Symbol(), SignalTimeframe, 14, 0);
   if(atr14 <= 0)
      return;

   double atrLimit = PipPoint() * AtrVolatilityMaxPips;
   if(atr14 > atrLimit)
      return;

   MarketScanResult scan = ScanMarket();
   if(!scan.valid)
      return;

   double atrStop = atr14 * AtrStopMultiplier;
   double atrTake = atr14 * AtrTakeMultiplier;
   if(atrStop <= 0 || atrTake <= 0)
      return;

   double lotSize = CalculatePositionSize(atrStop);
   if(lotSize <= 0)
      return;

   double entryPrice = (scan.direction == OP_BUY) ? Ask : Bid;
   double stopLoss = (scan.direction == OP_BUY) ? entryPrice - atrStop
                                                : entryPrice + atrStop;
   double takeProfit = (scan.direction == OP_BUY) ? entryPrice + atrTake
                                                  : entryPrice - atrTake;

   int digits = (int)MarketInfo(Symbol(), MODE_DIGITS);
   stopLoss = NormalizeDouble(stopLoss, digits);
   takeProfit = NormalizeDouble(takeProfit, digits);

   int slippage = (int)MathMax(1, MathRound(SlippagePips / PipPoint()));
   int ticket = OrderSend(Symbol(), scan.direction, lotSize, entryPrice,
                          slippage, stopLoss, takeProfit,
                          "SmartMomentumScalper", MagicNumber, 0,
                          (scan.direction == OP_BUY ? clrLime : clrTomato));

   if(ticket < 0)
   {
      Print("SmartMomentumScalper: OrderSend failed ", GetLastError());
      return;
   }

   g_trade.ticket = ticket;
   g_trade.type = scan.direction;
   g_trade.lots = lotSize;
   g_trade.initialLots = lotSize;
   g_trade.entryPrice = entryPrice;
   g_trade.stopLoss = stopLoss;
   g_trade.takeProfit = takeProfit;
   g_trade.openTime = TimeCurrent();
   g_trade.partialDone = false;
   g_trade.peakProfit = 0;
   g_trade.lastManaged = TimeCurrent();
   g_tradeActive = true;
   g_tradesToday++;
}

// ---------------------------------------------------------------------------
struct MarketScanResult
{
   bool valid;
   int  direction;
};

MarketScanResult ScanMarket()
{
   MarketScanResult r;
   r.valid = false;
   r.direction = -1;

   double emaFast0 = iMA(Symbol(), SignalTimeframe, 5, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaSlow0 = iMA(Symbol(), SignalTimeframe, 21, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi0     = iRSI(Symbol(), SignalTimeframe, 7, PRICE_CLOSE, 0);

   double candleBodyPoints = MathAbs(iClose(Symbol(), SignalTimeframe, 1) -
                                     iOpen(Symbol(), SignalTimeframe, 1)) / PipPoint();
   if(candleBodyPoints < MinCandleBodyPoints)
      return(r);

   int dir = 0;
   if(emaFast0 > emaSlow0 && rsi0 > RSIUpper)
      dir = OP_BUY;
   else if(emaFast0 < emaSlow0 && rsi0 < RSILower)
      dir = OP_SELL;
   else
      return(r);

   if(!TickAccelerationOK(dir))
      return(r);

   if(!FinalDirectionFilter(dir))
      return(r);

   r.valid = true;
   r.direction = dir;
   return(r);
}

// ---------------------------------------------------------------------------
bool TickAccelerationOK(const int direction)
{
   if(g_tickCount < TickAccelerationWindow + 1)
      return(false);

   int currentIndex = (g_tickIndex - 1 + ArraySize(g_tickHistory)) % ArraySize(g_tickHistory);
   int lookbackIndex = (currentIndex - TickAccelerationWindow + ArraySize(g_tickHistory)) % ArraySize(g_tickHistory);

   double currentPrice = g_tickHistory[currentIndex];
   double pastPrice    = g_tickHistory[lookbackIndex];

   double accelPoints = MathAbs(currentPrice - pastPrice) / PipPoint();
   return(accelPoints >= MinTickAccelerationPts);
}

// ---------------------------------------------------------------------------
bool FinalDirectionFilter(const int dir)
{
   double close0 = iClose(Symbol(), SignalTimeframe, 1);
   double open0  = iOpen(Symbol(), SignalTimeframe, 1);
   bool bullish0 = (close0 > open0);

   if(dir == OP_BUY && !bullish0) return(false);
   if(dir == OP_SELL && bullish0) return(false);

   for(int i = 1; i <= 2; i++)
   {
      double closeBar = iClose(Symbol(), SignalTimeframe, i);
      double openBar  = iOpen(Symbol(), SignalTimeframe, i);
      bool bull = (closeBar > openBar);

      if(dir == OP_BUY && !bull)
         return(false);
      if(dir == OP_SELL && bull)
         return(false);
   }

   return(true);
}

// ---------------------------------------------------------------------------
bool SpreadAcceptable()
{
   double spreadPips = (Ask - Bid) / PipPoint();
   return(spreadPips <= MaxSpreadPips);
}

// ---------------------------------------------------------------------------
double PipPoint()
{
   double point = MarketInfo(Symbol(), MODE_POINT);
   int digits = (int)MarketInfo(Symbol(), MODE_DIGITS);
   if(digits == 3 || digits == 5)
      point *= 10;
   return(point);
}

double PipValue()
{
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
   double pipPoint  = PipPoint();
   if(tickSize <= 0)
      return(0);
   return((tickValue / tickSize) * pipPoint);
}

double CalculatePositionSize(double stopDistance)
{
   double pipVal = PipValue();
   if(pipVal <= 0 || stopDistance <= 0)
      return(0);

   double stopPips = stopDistance / PipPoint();
   double riskPerTrade = AccountEquity() * (RiskPercentPerTrade / 100.0);
   double rawLots = riskPerTrade / (stopPips * pipVal);

   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   if(minLot <= 0) minLot = 0.01;
   if(maxLot <= 0) maxLot = 100;
   if(lotStep <= 0) lotStep = 0.01;

   double lots = rawLots;
   lots = MathFloor(lots / lotStep + 0.000001) * lotStep;
   if(lots < minLot && rawLots >= minLot)
      lots = minLot;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return(NormalizeDouble(lots, 2));
}

// ---------------------------------------------------------------------------
void SyncTradeState()
{
   if(HasManagedTrade())
      return;

   InitializeTradeState();
}

// ---------------------------------------------------------------------------
void ManageActiveTrade()
{
   if(!OrderSelect(g_trade.ticket, SELECT_BY_TICKET))
   {
      SyncTradeState();
      return;
   }

   if(OrderCloseTime() > 0)
   {
      SyncTradeState();
      return;
   }

   double floatingProfit = OrderProfit() + OrderSwap() + OrderCommission();
   g_trade.peakProfit = MathMax(g_trade.peakProfit, floatingProfit);

   if(PartialCloseCheck(floatingProfit))
      return;

   if(ShouldExitTrade(floatingProfit))
   {
      RefreshRates();
      double closePrice = (g_trade.type == OP_BUY) ? Bid : Ask;
      int slippage = (int)MathMax(1, MathRound(SlippagePips / PipPoint()));
      if(OrderClose(g_trade.ticket, OrderLots(), closePrice, slippage, clrAqua))
      {
         SyncTradeState();
      }
      return;
   }
}

// ---------------------------------------------------------------------------
bool PartialCloseCheck(double floatingProfit)
{
   if(g_trade.partialDone)
      return(false);

   double pipPoint = PipPoint();
   double targetPoints = MathAbs(g_trade.takeProfit - g_trade.entryPrice);
   double triggerPoints = targetPoints * PartialTriggerRatio;
   double currentPoints = (g_trade.type == OP_BUY)
                          ? (Bid - g_trade.entryPrice)
                          : (g_trade.entryPrice - Ask);

   if(currentPoints < triggerPoints || triggerPoints <= 0)
      return(false);

   double partialLots = NormalizeDouble(g_trade.lots * PartialCloseRatio, 2);
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   if(partialLots < minLot)
      return(false);

   int slippage = (int)MathMax(1, MathRound(SlippagePips / pipPoint));
   double price = (g_trade.type == OP_BUY) ? Bid : Ask;
   RefreshRates();
   if(OrderClose(g_trade.ticket, partialLots, price, slippage, clrGold))
   {
      if(OrderSelect(g_trade.ticket, SELECT_BY_TICKET))
      {
         g_trade.partialDone = true;
         g_trade.lots = OrderLots();
         double newSL = g_trade.entryPrice;
         if(g_trade.type == OP_BUY)
            newSL += PartialSLBufferPips * pipPoint;
         else
            newSL -= PartialSLBufferPips * pipPoint;
         double normalizedSL = NormalizeDouble(newSL, (int)MarketInfo(Symbol(), MODE_DIGITS));
         if(OrderModify(g_trade.ticket, OrderOpenPrice(), normalizedSL,
                        OrderTakeProfit(), 0, clrDodgerBlue))
         {
            g_trade.stopLoss = normalizedSL;
         }
      }
      return(true);
   }
   return(false);
}

// ---------------------------------------------------------------------------
bool ShouldExitTrade(double floatingProfit)
{
   double atr14 = iATR(Symbol(), SignalTimeframe, 14, 0);
   double atr3  = iATR(Symbol(), SignalTimeframe, 3, 0);

   if(atr14 > 0 && atr3 >= atr14 * VolatilitySpikeFactor)
      return(true);

   if(CurrentSpreadPips() > MaxSpreadPips * SpreadSpikeFactor)
      return(true);

   if(TimeCurrent() - g_trade.openTime >= MaxBarsInTrade * PeriodSecondsEx(SignalTimeframe))
      return(true);

   if(g_trade.peakProfit > 0 && floatingProfit <= g_trade.peakProfit * ProfitDecayThreshold)
      return(true);

   if(ReversalExitTriggered(atr14))
      return(true);

   return(false);
}

double CurrentSpreadPips()
{
   return((Ask - Bid) / PipPoint());
}

bool ReversalExitTriggered(double atr14)
{
   if(atr14 <= 0)
      return(false);

   int oppositeCount = 0;
   for(int i = 1; i <= 2; i++)
   {
      double closeBar = iClose(Symbol(), SignalTimeframe, i);
      double openBar  = iOpen(Symbol(), SignalTimeframe, i);
      bool bullish = (closeBar > openBar);
      double body = MathAbs(closeBar - openBar);

      if(g_trade.type == OP_BUY && !bullish && body >= atr14 * ReversalBodyAtrRatio)
         oppositeCount++;
      else if(g_trade.type == OP_SELL && bullish && body >= atr14 * ReversalBodyAtrRatio)
         oppositeCount++;
   }
   return(oppositeCount >= 2);
}

// ---------------------------------------------------------------------------
void UpdateDisplay()
{
   string trend = "-";
   if(g_tradeActive)
      trend = (g_trade.type == OP_BUY) ? "Bull" : "Bear";

   double atr14 = iATR(Symbol(), SignalTimeframe, 14, 0);
   double atr3  = iATR(Symbol(), SignalTimeframe, 3, 0);
   double spread = CurrentSpreadPips();
   double momentumState = iRSI(Symbol(), SignalTimeframe, 7, PRICE_CLOSE, 0);
   string tradeStatus = g_tradeActive ? (g_trade.partialDone ? "Active (partial)" : "Active") : "Standby";
   string sessionState = CanTradeNow() ? "OPEN" : "CLOSED";

   double floatingProfit = 0.0;
   if(g_tradeActive && OrderSelect(g_trade.ticket, SELECT_BY_TICKET))
      floatingProfit = OrderProfit() + OrderSwap() + OrderCommission();

   double profitDecayPct = 0.0;
   if(g_trade.peakProfit > 0 && g_tradeActive)
      profitDecayPct = 100.0 * (g_trade.peakProfit - floatingProfit) / g_trade.peakProfit;

   g_panelText =
      "SmartMomentumScalper\n" +
      "Trend: " + trend + " | Session: " + sessionState + "\n" +
      "ATR14: " + DoubleToString(atr14 / PipPoint(), 1) + " pts | ATR3: " +
      DoubleToString(atr3 / PipPoint(), 1) + " pts\n" +
      "Spread: " + DoubleToString(spread, 1) + " pts | Momentum RSI7: " +
      DoubleToString(momentumState, 1) + "\n" +
      "Trade: " + tradeStatus + " | Daily Trades: " + IntegerToString(g_tradesToday) + "\n" +
      "Lot: " + DoubleToString(g_trade.lots, 2) + " | Profit Peak: " +
      DoubleToString(g_trade.peakProfit, 2) + " | Decay: " +
      DoubleToString(profitDecayPct, 1) + "%";

   Comment(g_panelText);
}

// ---------------------------------------------------------------------------
bool HasManagedTrade()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
      {
         g_trade.ticket = OrderTicket();
         g_trade.type = OrderType();
         g_trade.lots = OrderLots();
         if(g_trade.initialLots == 0)
            g_trade.initialLots = g_trade.lots;
         else
            g_trade.initialLots = MathMax(g_trade.initialLots, g_trade.lots);
         g_trade.entryPrice = OrderOpenPrice();
         g_trade.stopLoss = OrderStopLoss();
         g_trade.takeProfit = OrderTakeProfit();
         g_trade.openTime = OrderOpenTime();
         g_trade.partialDone = (g_trade.lots < g_trade.initialLots - 0.0001);
         g_trade.peakProfit = MathMax(g_trade.peakProfit, OrderProfit() + OrderSwap() + OrderCommission());
         g_tradeActive = true;
         return(true);
      }
   }
   g_tradeActive = false;
   return(false);
}


int PeriodSecondsEx(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:   return(60);
      case PERIOD_M5:   return(300);
      case PERIOD_M15:  return(900);
      case PERIOD_M30:  return(1800);
      case PERIOD_H1:   return(3600);
      case PERIOD_H4:   return(14400);
      case PERIOD_D1:   return(86400);
      case PERIOD_W1:   return(604800);
      case PERIOD_MN1:  return(2592000);
      default:          return(PeriodSeconds(tf));
   }
}

