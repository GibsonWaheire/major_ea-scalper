#property copyright "Copyright 2025, Hyperactive Day Trader"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

// =====================================================================================================
// HYPERACTIVE DAY TRADER MT5 (TREND FOLLOWING)
// - Candle-based trend/pullback/breakout entries
// - Keeps risk management, breakeven, partial exits, trailing
// - Removes all HFT tick-speed restrictions
// =====================================================================================================

CTrade trade;

// ===== Core Trading Settings =====
input group "===== Core Trading Settings ====="
input int      MagicNumber          = 302510;
input string   TradeSymbol          = "";       // Symbol to trade (empty = current chart symbol)
input bool     UseFixedLot          = true;     // Use fixed lot size (false = dynamic)
input double   FixedLotSize         = 0.10;     // Fixed lot size (if UseFixedLot = true)
input double   DynamicLotBase       = 0.05;     // Base lot for dynamic sizing
input double   DynamicLotMultiplier = 1.2;      // Multiplier for dynamic lot (based on balance)
input double   MaxLotSize           = 1.00;     // Maximum lot size (safety limit)
input double   MinLotSize           = 0.01;     // Minimum lot size (safety limit)

// ===== Trend & Signal Settings =====
input group "===== Trend & Signal Settings ====="
input ENUM_TIMEFRAMES TrendTF = PERIOD_M15;     // Trend direction timeframe
input ENUM_TIMEFRAMES SignalTF = PERIOD_M5;     // Entry precision timeframe
input int      EMAPeriod = 50;                  // Trend filter EMA period
input int      SignalEMAPeriod = 14;            // Signal EMA period
input double   PullbackPercent = 0.30;          // Pullback depth % of last swing
input double   BreakoutBufferPoints = 50;       // Confirm trend continuation
input int      SwingLookbackBars = 30;          // Bars to search swings on SignalTF

// ===== Exit Settings =====
input group "===== Exit Settings ====="
input double   TPPoints = 1500;                 // Typical day TP (e.g., NAS100)
input double   SLPoints = 700;                  // Reasonable SL
input double   TrailStart = 500;                // Start trailing once in profit
input double   TrailStep = 200;                 // Trail distance
input bool     UseStructureExit = true;         // Exit on opposite structure break or strong counter candle

// ===== Spread & Execution =====
input group "===== Spread & Execution ====="
input double   MaxSpreadPoints     = 50.0;      // Maximum spread in points
input int      MaxSlippagePoints   = 10;        // Maximum slippage in points
input int      OrderRetries        = 3;         // Number of order retries

// ===== Risk Management =====
input group "===== Risk Management ====="
input double   MaxDrawdownPercent  = 30.0;      // Maximum drawdown % (stop trading)
input bool     UseDrawdownProtection = true;    // Enable drawdown protection
input double   DailyProfitTarget   = 0.0;       // Daily profit target (0 = disabled)

// ===== Session Filter (optional) =====
input group "===== Session Filter ====="
input bool     UseSessionFilter    = false;     // Enable session filter
input int      SessionStartHour    = 8;         // Session start hour (GMT)
input int      SessionEndHour      = 20;        // Session end hour (GMT)

// ===== Dynamic Breakeven =====
input group "===== Dynamic Breakeven ====="
input bool     UseDynamicBreakeven = true;      // Enable dynamic breakeven
input double   BreakevenTriggerPoints = 350.0;  // Move SL when profit > X points
input double   BreakevenOffsetPoints = 50.0;    // Move SL to entry - X points

// ===== Partial Exit =====
input group "===== Partial Exit ====="
input bool     UsePartialExit = true;           // Enable partial exit
input double   PartialExitProfitPoints = 700.0; // Close 50% at X points profit
input double   PartialExitPercent = 50.0;       // Percentage to close (50% = half position)

// =====================================================================================================
// STRUCTURES & GLOBALS
// =====================================================================================================

struct TradeInfo {
   ulong    ticket;
   double   entryPrice;
   datetime openTime;
   int      direction;  // 1=BUY, -1=SELL
   double   lotSize;
   double   highestProfitPoints;
   bool     wasProfitable;
   bool     breakevenMoved;
   bool     partialExitDone;
};

TradeInfo currentTrade;
bool hasActiveTrade = false;

// Market data
string tradeSymbol = "";
double point = 0.0;
int symbolDigits = 0;
MqlTick currentTick;
double currentBid = 0.0;
double currentAsk = 0.0;
double currentSpread = 0.0;

// Risk management
double initialBalance = 0.0;
double highestBalance = 0.0;
double dailyProfit = 0.0;
datetime lastDayReset = 0;
bool tradingStopped = false;

// Trend & swing tracking
int trendDirection = 0;          // 1=uptrend, -1=downtrend
double lastSwingHigh = 0.0;
double lastSwingLow = 0.0;
datetime lastSignalBarTime = 0;  // Prevent multiple entries per bar

// =====================================================================================================
// FORWARD DECLARATIONS
// =====================================================================================================

double GetEMA(string symbol, ENUM_TIMEFRAMES tf, int period);
bool   CheckTrendDirection();
bool   RefreshSwingLevels();
bool   CheckPullback();
bool   CheckBreakout();
int    GetDayTradingSignal();
bool   ShouldOpenTrade(int direction);
bool   OpenTrade(int direction);
void   ManageTrade();
void   MoveToBreakeven();
void   ExecutePartialExit();
bool   ModifyStopLoss(double newSL);
bool   CheckStructureExit();
void   CloseTrade(string reason);
void   CheckRiskManagement();
bool   UpdateMarketData();
void   UpdateDisplay();

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("Hyperactive Day Trader MT5 v1.00");
   Print("Candle-based trend day-trading EA");
   Print("========================================");
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Determine trade symbol
   if(TradeSymbol == "" || TradeSymbol == NULL)
      tradeSymbol = _Symbol;
   else
      tradeSymbol = TradeSymbol;
   
   // Initialize symbol data
   if(!SymbolInfoInteger(tradeSymbol, SYMBOL_SELECT))
   {
      Print("ERROR: Symbol ", tradeSymbol, " not found!");
      return(INIT_FAILED);
   }
   
   symbolDigits = (int)SymbolInfoInteger(tradeSymbol, SYMBOL_DIGITS);
   point = SymbolInfoDouble(tradeSymbol, SYMBOL_POINT);
   if(symbolDigits == 3 || symbolDigits == 5)
      point *= 10.0;
   
   // Initialize trading state
   hasActiveTrade = false;
   currentTrade.ticket = 0;
   
   // Initialize risk management
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   highestBalance = initialBalance;
   dailyProfit = 0.0;
   lastDayReset = TimeCurrent();
   tradingStopped = false;
   
   Print("Trade Symbol: ", tradeSymbol);
   Print("Lot Mode: ", (UseFixedLot ? "FIXED" : "DYNAMIC"));
   Print("Fixed Lot: ", FixedLotSize);
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("Hyperactive Day Trader deinitialized. Reason: ", reason);
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   if(!UpdateMarketData())
      return;
   
   CheckRiskManagement();
   
   if(tradingStopped)
   {
      UpdateDisplay();
      return;
   }
   
   if(hasActiveTrade)
      ManageTrade();
   
   if(!hasActiveTrade && !tradingStopped)
   {
      int direction = GetDayTradingSignal();
      if(direction != 0 && ShouldOpenTrade(direction))
      {
         OpenTrade(direction);
      }
   }
   
   UpdateDisplay();
}

// =====================================================================================================
// MARKET DATA
// =====================================================================================================

bool UpdateMarketData()
{
   if(!SymbolInfoTick(tradeSymbol, currentTick))
      return false;
   
   currentBid = currentTick.bid;
   currentAsk = currentTick.ask;
   currentSpread = (currentAsk - currentBid) / point;
   
   return (currentBid > 0.0 && currentAsk > 0.0);
}

// =====================================================================================================
// RISK MANAGEMENT
// =====================================================================================================

void CheckRiskManagement()
{
   // Reset daily profit at start of new day
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   MqlDateTime lastDt;
   TimeToStruct(lastDayReset, lastDt);
   
   if(dt.day != lastDt.day || dt.mon != lastDt.mon || dt.year != lastDt.year)
   {
      dailyProfit = 0.0;
      lastDayReset = currentTime;
   }
   
   // Check drawdown
   if(UseDrawdownProtection)
   {
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(currentEquity > highestBalance)
         highestBalance = currentEquity;
      
      double drawdown = ((highestBalance - currentEquity) / highestBalance) * 100.0;
      
      if(drawdown >= MaxDrawdownPercent)
      {
         tradingStopped = true;
         Print("TRADING STOPPED: Drawdown ", DoubleToString(drawdown, 2), "% exceeds limit ", DoubleToString(MaxDrawdownPercent, 1), "%");
         
         if(hasActiveTrade)
            CloseTrade("Drawdown limit reached");
      }
   }
   
   // Check daily profit target
   if(DailyProfitTarget > 0.0)
   {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyProfit = currentBalance - initialBalance;
      
      if(dailyProfit >= DailyProfitTarget)
      {
         tradingStopped = true;
         Print("TRADING STOPPED: Daily profit target reached: $", DoubleToString(dailyProfit, 2));
         
         if(hasActiveTrade)
            CloseTrade("Daily profit target reached");
      }
   }
}

// =====================================================================================================
// ENTRY LOGIC - DAY TRADING TREND
// =====================================================================================================

double GetEMA(string symbol, ENUM_TIMEFRAMES tf, int period)
{
   // Use previous closed candle to avoid repaint
   return iMA(symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE, 1);
}

bool CheckTrendDirection()
{
   double ema = GetEMA(tradeSymbol, TrendTF, EMAPeriod);
   double closePrice = iClose(tradeSymbol, TrendTF, 1);
   
   if(ema <= 0.0 || closePrice <= 0.0)
   {
      trendDirection = 0;
      return false;
   }
   
   if(closePrice > ema)
      trendDirection = 1;
   else if(closePrice < ema)
      trendDirection = -1;
   else
      trendDirection = 0;
   
   return trendDirection != 0;
}

bool RefreshSwingLevels()
{
   if(Bars(tradeSymbol, SignalTF) < SwingLookbackBars + 5)
      return false;
   
   int highIndex = iHighest(tradeSymbol, SignalTF, MODE_HIGH, SwingLookbackBars, 1);
   int lowIndex  = iLowest(tradeSymbol, SignalTF, MODE_LOW, SwingLookbackBars, 1);
   
   if(highIndex < 0 || lowIndex < 0)
      return false;
   
   lastSwingHigh = iHigh(tradeSymbol, SignalTF, highIndex);
   lastSwingLow  = iLow(tradeSymbol, SignalTF, lowIndex);
   
   return (lastSwingHigh > 0.0 && lastSwingLow > 0.0);
}

bool CheckPullback()
{
   if(trendDirection == 0)
      return false;
   
   if(!RefreshSwingLevels())
      return false;
   
   double signalClose = iClose(tradeSymbol, SignalTF, 1);
   double signalEMA = GetEMA(tradeSymbol, SignalTF, SignalEMAPeriod);
   
   if(signalClose <= 0.0 || signalEMA <= 0.0)
      return false;
   
   double swingRange = lastSwingHigh - lastSwingLow;
   if(swingRange <= 0.0)
      return false;
   
   if(trendDirection == 1)
   {
      double pullbackDepth = (lastSwingHigh - signalClose) / swingRange;
      bool nearEMA = (signalClose <= signalEMA); // price pulled back toward 14 EMA
      return (pullbackDepth >= PullbackPercent && nearEMA);
   }
   else
   {
      double pullbackDepth = (signalClose - lastSwingLow) / swingRange;
      bool nearEMA = (signalClose >= signalEMA); // price pulled back toward 14 EMA
      return (pullbackDepth >= PullbackPercent && nearEMA);
   }
}

bool CheckBreakout()
{
   double signalClose = iClose(tradeSymbol, SignalTF, 1);
   if(signalClose <= 0.0 || lastSwingHigh <= 0.0 || lastSwingLow <= 0.0)
      return false;
   
   double buffer = BreakoutBufferPoints * point;
   
   if(trendDirection == 1)
      return (signalClose > (lastSwingHigh + buffer));
   else if(trendDirection == -1)
      return (signalClose < (lastSwingLow - buffer));
   
   return false;
}

int GetDayTradingSignal()
{
   // One decision per closed SignalTF candle
   datetime barTime = iTime(tradeSymbol, SignalTF, 1);
   if(barTime == 0 || barTime == lastSignalBarTime)
      return 0;
   
   // Check session filter
   if(UseSessionFilter)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < SessionStartHour || dt.hour >= SessionEndHour)
      {
         lastSignalBarTime = barTime;
         return 0;
      }
   }
   
   if(currentSpread > MaxSpreadPoints)
   {
      lastSignalBarTime = barTime;
      return 0;
   }
   
   if(!CheckTrendDirection())
   {
      lastSignalBarTime = barTime;
      return 0;
   }
   
   if(!CheckPullback())
   {
      lastSignalBarTime = barTime;
      return 0;
   }
   
   int direction = 0;
   if(CheckBreakout())
      direction = trendDirection;
   
   lastSignalBarTime = barTime;
   return direction;
}

bool ShouldOpenTrade(int direction)
{
   if(direction == 0)
      return false;
   if(hasActiveTrade)
      return false;
   if(tradingStopped)
      return false;
   if(currentSpread > MaxSpreadPoints)
      return false;
   return true;
}

// =====================================================================================================
// LOT SIZING
// =====================================================================================================

double CalculateLotSize()
{
   double lotSize = 0.0;
   
   if(UseFixedLot)
      lotSize = FixedLotSize;
   else
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      lotSize = DynamicLotBase * (balance / 1000.0) * DynamicLotMultiplier;
   }
   
   double lotStep = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MAX);
   
   lotSize = MathMax(MinLotSize, MathMin(MaxLotSize, lotSize));
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   
   if(lotStep > 0.0)
      lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   return NormalizeDouble(lotSize, 2);
}

// =====================================================================================================
// OPEN TRADE
// =====================================================================================================

bool OpenTrade(int direction)
{
   if(direction == 0 || hasActiveTrade)
      return false;
   
   double lotSize = CalculateLotSize();
   double price = (direction == 1) ? currentAsk : currentBid;
   
   double sl = 0.0;
   double tp = 0.0;
   
   if(SLPoints > 0.0)
   {
      sl = (direction == 1) ? price - (SLPoints * point) : price + (SLPoints * point);
      sl = NormalizeDouble(sl, symbolDigits);
   }
   
   if(TPPoints > 0.0)
   {
      tp = (direction == 1) ? price + (TPPoints * point) : price - (TPPoints * point);
      tp = NormalizeDouble(tp, symbolDigits);
   }
   
   string comment = "DayTrend_" + (direction == 1 ? "BUY" : "SELL");
   ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   bool sent = false;
   int retries = 0;
   
   while(retries < OrderRetries && !sent)
   {
      if(orderType == ORDER_TYPE_BUY)
         sent = trade.Buy(lotSize, tradeSymbol, 0.0, sl, tp, comment);
      else
         sent = trade.Sell(lotSize, tradeSymbol, 0.0, sl, tp, comment);
      
      if(!sent)
      {
         retries++;
         if(retries < OrderRetries)
         {
            Sleep(50);
            SymbolInfoTick(tradeSymbol, currentTick);
            currentBid = currentTick.bid;
            currentAsk = currentTick.ask;
            price = (direction == 1) ? currentAsk : currentBid;
         }
      }
   }
   
   if(sent)
   {
      ulong ticket = 0;
      if(trade.ResultDeal() > 0 && HistoryDealSelect(trade.ResultDeal()))
         ticket = HistoryDealGetInteger(trade.ResultDeal(), DEAL_POSITION_ID);
      
      if(ticket == 0)
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong posTicket = PositionGetTicket(i);
            if(posTicket > 0 && PositionSelectByTicket(posTicket))
            {
               if(PositionGetString(POSITION_SYMBOL) == tradeSymbol &&
                  PositionGetInteger(POSITION_MAGIC) == MagicNumber)
               {
                  ticket = posTicket;
                  break;
               }
            }
         }
      }
      
      if(ticket > 0)
      {
         double actualEntryPrice = price;
         if(PositionSelectByTicket(ticket))
            actualEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         
         currentTrade.ticket = ticket;
         currentTrade.entryPrice = actualEntryPrice;
         currentTrade.openTime = TimeCurrent();
         currentTrade.direction = direction;
         currentTrade.lotSize = lotSize;
         currentTrade.highestProfitPoints = 0.0;
         currentTrade.wasProfitable = false;
         currentTrade.breakevenMoved = false;
         currentTrade.partialExitDone = false;
         hasActiveTrade = true;
         
         Print("TRADE OPENED: ", (direction == 1 ? "BUY" : "SELL"),
               " | Lot: ", lotSize, " | Price: ", actualEntryPrice, " | SL: ", sl, " | TP: ", tp);
         return true;
      }
   }
   
   Print("Trade open failed: ", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
   return false;
}

// =====================================================================================================
// MANAGE TRADE (EXIT LOGIC)
// =====================================================================================================

void ManageTrade()
{
   if(!hasActiveTrade || currentTrade.ticket == 0)
      return;
   
   if(!PositionSelectByTicket(currentTrade.ticket))
   {
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      return;
   }
   
   double positionProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   double currentPrice = (currentTrade.direction == 1) ? currentBid : currentAsk;
   double priceDiff = currentPrice - currentTrade.entryPrice;
   if(currentTrade.direction == -1)
      priceDiff = -priceDiff;
   
   double profitPoints = priceDiff / point;
   double lossPoints = (profitPoints < 0) ? MathAbs(profitPoints) : 0.0;
   
   if(profitPoints > currentTrade.highestProfitPoints)
   {
      currentTrade.highestProfitPoints = profitPoints;
      if(profitPoints > 0.0)
         currentTrade.wasProfitable = true;
   }
   
   // Hard stop check (backup to broker SL)
   if(lossPoints >= SLPoints)
   {
      CloseTrade("Maximum loss points reached (" + DoubleToString(lossPoints, 1) + " pts)");
      return;
   }
   
   // Structure exit
   if(UseStructureExit && CheckStructureExit())
      return;
   
   // Dynamic Breakeven
   if(UseDynamicBreakeven && !currentTrade.breakevenMoved && profitPoints >= BreakevenTriggerPoints)
      MoveToBreakeven();
   
   // Partial Exit
   if(UsePartialExit && !currentTrade.partialExitDone && profitPoints >= PartialExitProfitPoints)
      ExecutePartialExit();
   
   // Trailing stop
   if(currentTrade.highestProfitPoints >= TrailStart)
   {
      double trailingLevel = currentTrade.highestProfitPoints - TrailStep;
      if(trailingLevel > 0 && profitPoints < trailingLevel)
      {
         CloseTrade("Trailing stop hit");
         return;
      }
      
      double desiredSL = (currentTrade.direction == 1)
         ? currentTrade.entryPrice + ((currentTrade.highestProfitPoints - TrailStep) * point)
         : currentTrade.entryPrice - ((currentTrade.highestProfitPoints - TrailStep) * point);
      
      ModifyStopLoss(desiredSL);
   }
}

void MoveToBreakeven()
{
   if(!hasActiveTrade || currentTrade.ticket == 0)
      return;
   
   if(!PositionSelectByTicket(currentTrade.ticket))
      return;
   
   double newSL = 0.0;
   if(currentTrade.direction == 1)
      newSL = currentTrade.entryPrice - (BreakevenOffsetPoints * point);
   else
      newSL = currentTrade.entryPrice + (BreakevenOffsetPoints * point);
   
   newSL = NormalizeDouble(newSL, symbolDigits);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   
   bool shouldModify = false;
   if(currentTrade.direction == 1)
      shouldModify = (currentSL == 0.0 || newSL > currentSL);
   else
      shouldModify = (currentSL == 0.0 || newSL < currentSL);
   
   if(shouldModify && trade.PositionModify(currentTrade.ticket, newSL, currentTP))
   {
      currentTrade.breakevenMoved = true;
      Print("Breakeven moved: SL set to ", DoubleToString(newSL, symbolDigits));
   }
}

void ExecutePartialExit()
{
   if(!hasActiveTrade || currentTrade.ticket == 0)
      return;
   
   if(!PositionSelectByTicket(currentTrade.ticket))
      return;
   
   double currentLots = PositionGetDouble(POSITION_VOLUME);
   double partialLots = currentLots * (PartialExitPercent / 100.0);
   
   double lotStep = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0.0)
      partialLots = MathFloor(partialLots / lotStep) * lotStep;
   
   double minLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MIN);
   if(partialLots < minLot)
      partialLots = minLot;
   
   if(partialLots >= currentLots)
      partialLots = currentLots * 0.5;
   
   partialLots = NormalizeDouble(partialLots, 2);
   
   if(trade.PositionClosePartial(currentTrade.ticket, partialLots))
   {
      currentTrade.partialExitDone = true;
      currentTrade.lotSize = currentLots - partialLots;
      Print("Partial exit executed: Closed ", DoubleToString(partialLots, 2), " lots (", DoubleToString(PartialExitPercent, 1), "%)");
   }
   else
   {
      Print("Partial exit failed: ", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
   }
}

bool ModifyStopLoss(double newSL)
{
   if(!PositionSelectByTicket(currentTrade.ticket))
      return false;
   
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   
   if(currentTrade.direction == 1 && newSL <= 0.0)
      return false;
   if(currentTrade.direction == -1 && newSL <= 0.0)
      return false;
   
   bool better = false;
   if(currentTrade.direction == 1)
      better = (currentSL == 0.0 || newSL > currentSL);
   else
      better = (currentSL == 0.0 || newSL < currentSL);
   
   if(better)
   {
      newSL = NormalizeDouble(newSL, symbolDigits);
      return trade.PositionModify(currentTrade.ticket, newSL, currentTP);
   }
   
   return false;
}

bool CheckStructureExit()
{
   if(!PositionSelectByTicket(currentTrade.ticket))
      return false;
   
   // Refresh swing levels for exit decisions
   RefreshSwingLevels();
   
   MqlRates rates[3];
   if(CopyRates(tradeSymbol, SignalTF, 1, 3, rates) != 3)
      return false;
   
   MqlRates lastCandle = rates[0];   // most recent closed
   MqlRates prevCandle = rates[1];
   
   // Opposite swing break
   if(currentTrade.direction == 1 && lastSwingLow > 0.0 && lastCandle.close < lastSwingLow)
   {
      CloseTrade("Structure break below last swing low");
      return true;
   }
   if(currentTrade.direction == -1 && lastSwingHigh > 0.0 && lastCandle.close > lastSwingHigh)
   {
      CloseTrade("Structure break above last swing high");
      return true;
   }
   
   // Strong counter candle (simple engulfing/body filter)
   double body = MathAbs(lastCandle.close - lastCandle.open);
   double range = lastCandle.high - lastCandle.low;
   if(range <= 0)
      return false;
   
   double bodyRatio = body / range;
   bool isEngulfingBear = (lastCandle.close < lastCandle.open) && (lastCandle.close < prevCandle.low);
   bool isEngulfingBull = (lastCandle.close > lastCandle.open) && (lastCandle.close > prevCandle.high);
   
   if(currentTrade.direction == 1)
   {
      if((bodyRatio >= 0.6 && lastCandle.close < lastCandle.open && lastCandle.close < prevCandle.close) || isEngulfingBear)
      {
         CloseTrade("Strong counter candle (bearish)");
         return true;
      }
   }
   else
   {
      if((bodyRatio >= 0.6 && lastCandle.close > lastCandle.open && lastCandle.close > prevCandle.close) || isEngulfingBull)
      {
         CloseTrade("Strong counter candle (bullish)");
         return true;
      }
   }
   
   return false;
}

// =====================================================================================================
// CLOSE TRADE
// =====================================================================================================

void CloseTrade(string reason)
{
   if(!hasActiveTrade || currentTrade.ticket == 0)
      return;
   
   if(!PositionSelectByTicket(currentTrade.ticket))
   {
      hasActiveTrade = false;
      currentTrade.ticket = 0;
      return;
   }
   
   double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   
   if(trade.PositionClose(currentTrade.ticket))
   {
      Print("TRADE CLOSED: ", reason, " | P&L: $", DoubleToString(profit, 2));
      dailyProfit += profit;
      hasActiveTrade = false;
      currentTrade.ticket = 0;
   }
   else
   {
      Print("Close failed: ", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
   }
}

// =====================================================================================================
// DISPLAY
// =====================================================================================================

void UpdateDisplay()
{
   string status = "\n=== Hyperactive Day Trader MT5 ===\n";
   status += "Symbol: " + tradeSymbol + "\n";
   status += "Lot Mode: " + (UseFixedLot ? "FIXED" : "DYNAMIC") + "\n";
   if(UseFixedLot)
      status += "Lot Size: " + DoubleToString(FixedLotSize, 2) + "\n";
   else
      status += "Dynamic Lot: " + DoubleToString(CalculateLotSize(), 2) + "\n";
   
   status += "Spread: " + DoubleToString(currentSpread, 1) + " pts";
   if(currentSpread > MaxSpreadPoints)
      status += " [HIGH]";
   status += "\n";
   
   // Trend view
   CheckTrendDirection();
   status += "Trend TF: " + EnumToString(TrendTF) + " | ";
   status += (trendDirection == 1 ? "UP" : (trendDirection == -1 ? "DOWN" : "FLAT")) + "\n";
   status += "Signal TF: " + EnumToString(SignalTF) + "\n";
   
   if(tradingStopped)
   {
      status += "\nSTATUS: TRADING STOPPED\n";
      if(UseDrawdownProtection)
      {
         double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         double drawdown = ((highestBalance - currentEquity) / highestBalance) * 100.0;
         status += "Drawdown: " + DoubleToString(drawdown, 2) + "%\n";
      }
   }
   else
   {
      status += "STATUS: ACTIVE\n";
   }
   
   if(hasActiveTrade && PositionSelectByTicket(currentTrade.ticket))
   {
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double currentPrice = (currentTrade.direction == 1) ? currentBid : currentAsk;
      double priceDiff = currentPrice - currentTrade.entryPrice;
      if(currentTrade.direction == -1)
         priceDiff = -priceDiff;
      double profitPoints = priceDiff / point;
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      int holdSeconds = (int)(TimeCurrent() - openTime);
      
      status += "\n--- Active Trade ---\n";
      status += "Direction: " + (currentTrade.direction == 1 ? "BUY" : "SELL") + "\n";
      status += "P&L: $" + DoubleToString(profit, 2) + "\n";
      status += "Points: " + DoubleToString(profitPoints, 1) + "\n";
      status += "Hold Time: " + IntegerToString(holdSeconds) + " seconds\n";
      if(currentTrade.breakevenMoved)
         status += "Breakeven: MOVED\n";
      if(currentTrade.partialExitDone)
         status += "Partial Exit: DONE (" + DoubleToString(PartialExitPercent, 0) + "%)\n";
   }
   else
   {
      status += "\nNo active trade\n";
      status += "Waiting for day-trading signal...\n";
   }
   
   status += "\n--- Account ---\n";
   status += "Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n";
   status += "Equity: $" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\n";
   if(DailyProfitTarget > 0.0)
   {
      status += "Daily Profit: $" + DoubleToString(dailyProfit, 2);
      status += " / $" + DoubleToString(DailyProfitTarget, 2) + "\n";
   }
   
   Comment(status);
}

