#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "2.00"

#include <Trade\Trade.mqh>

// ===== TRADING MODE =====

enum MODE_TYPE {
   MODE_BASKET = 0,    // Basket Take-Profit Mode
   MODE_MICRO_TP = 1   // Per-Trade Micro TP with BE/Trailing
};

input group "===== Trading Mode ====="
input int TradingMode = 0;  // 0=Basket TP, 1=Micro TP

// ===== MEAN REVERSION SETTINGS =====

input group "===== Mean Reversion Entry ====="
input ENUM_TIMEFRAMES EntryTimeframe = PERIOD_M1;  // Entry timeframe (M1 or M5)
input int      MeanReversionPeriod = 20;           // Period for mean calculation (SMA)
input double   DeviationMultiplier = 2.0;          // Standard deviation multiplier
input double   MinDeviationPips = 5.0;             // Minimum deviation to enter
input int      MaxConcurrentTrades = 5;            // Maximum trades per symbol

input group "===== Testing / Signal Boost ====="
input bool     UseFastTestingMode       = false;   // Enable relaxed signal checks for demo/testing
input double   FastModeDeviationScale   = 0.5;     // Multiply deviation threshold (<1 = more trades)
input double   FastModeMinDeviationPips = 1.0;     // Override minimum deviation requirement when fast mode on
input bool     FastModeUseLiveCandle    = true;    // Evaluate forming candle instead of waiting for close

input group "===== Quick Entry Booster ====="
input bool     UseQuickEntryBoost       = true;    // Allow secondary, faster signal sweep
input double   QuickEntryDeviationScale = 0.6;     // Multiplier vs. active deviation multiplier
input double   QuickEntryMinDeviationPips = 1.5;   // Floor for quick-entry deviation requirement
input bool     QuickEntryUseLiveCandle  = true;    // Re-evaluate on forming candle for quick entries

// ===== LOT SIZE (ADDED DYNAMIC MODES) =====

enum LOT_MODE {
   LOT_FIXED = 0,         // Always use LotSize
   LOT_RISK_PERCENT = 1,  // Risk-based (requires SL)
   LOT_MARTINGALE = 2,    // Multiply last lot after a losing basket
   LOT_GRID_STEP = 3,     // Increase per additional open trade in same direction
   LOT_EQUITY_SCALE = 4   // Scale with account balance/equity
};

input group "===== Position Sizing ====="
input int      LotSizingMode = 3;                  // 0=Fixed,1=Risk%,2=Martingale,3=GridStep,4=EquityScale
input double   BaseLot      = 0.01;                // Base lot (used by all modes)
input double   LotSize      = 0.01;                // Fixed lot (if LOT_FIXED)
input double   RiskPercent  = 0.5;                 // Risk % per trade (LOT_RISK_PERCENT)
input double   MartingaleFactor = 1.5;             // Multiplier after loss (LOT_MARTINGALE)
input double   GridLotStep  = 0.01;                // Increment per extra open trade (LOT_GRID_STEP)
input double   EquityPerLot = 2000.0;              // $ equity required per BaseLot (LOT_EQUITY_SCALE)
input double   MaxLot       = 1.00;                // Safety cap
input double   MinLot       = 0.01;                // Safety floor

// ===== BASKET TAKE-PROFIT (Mode A) =====

input group "===== Basket Take-Profit Settings ====="
input double   BasketProfitPercent = 0.2;          // Close all trades at % of balance
input double   BasketProfitFixed   = 0.0;          // OR fixed currency amount (0 = use %)
input int      BasketTimeLimitMinutes = 60;        // Close basket after X minutes
input bool     UseBasketTimeLimit  = false;        // Enable time-based exit

// ===== PER-TRADE MICRO TP (Mode B) =====

input group "===== Per-Trade Micro TP Settings ====="
input double   MicroTPPips        = 3.0;           // Micro take-profit in pips
input double   BreakEvenPips      = 2.0;           // Move to BE after X pips profit
input double   TrailingStartPips  = 1.5;           // Start trailing after X pips
input double   TrailingStepPips   = 0.5;           // Trailing step in pips
input double   StopLossPips       = 10.0;          // Stop loss in pips

// ===== RISK MANAGEMENT =====

input group "===== Risk Management ====="
input double   MaxDrawdownPercent = 20.0;          // Maximum equity drawdown % (from start equity)
input double   MaxSpreadPips      = 5.0;           // Maximum spread filter
input bool     UseDrawdownGuard   = true;          // Enable drawdown protection

// ===== SESSION FILTERS =====

input group "===== Session Filters ====="
input bool     UseSessionFilter   = false;         // Enable session filter
input int      SessionStartHour   = 8;             // Trading session start (server time)
input int      SessionEndHour     = 20;            // Trading session end (server time)

// ===== NEWS FILTER =====

input group "===== News Filter ====="
input bool     UseNewsFilter      = false;         // Enable news filter
input int      NewsFilterMinutes  = 30;            // Avoid trading X minutes before/after news

// ===== ORDER MANAGEMENT =====

input group "===== Order Management ====="
input int      MagicNumber        = 202503;        // Magic number
input int      MaxRetries         = 3;             // Maximum order retries
input int      RetryDelayMS       = 100;           // Delay between retries (ms)
input int      SlippagePips       = 3;             // Maximum slippage

// ===== DISPLAY =====

input group "===== Display Settings ====="
input bool     ShowPanel          = true;          // Show on-chart panel
input int      PanelCorner        = 0;             // Panel corner (0=TopLeft, 1=TopRight, 2=BottomLeft, 3=BottomRight)
input int      PanelX             = 10;            // Panel X position
input int      PanelY             = 20;            // Panel Y position

// ===== INTERNAL / STATE =====

CTrade trade;
int maHandle = INVALID_HANDLE;

double accountStartBalance = 0;
double accountStartEquity  = 0;
datetime basketStartTime   = 0;
bool basketActive          = false;
int totalTrades            = 0;
double totalFloatingProfit = 0;
double highestBasketProfit = 0;

double g_LastBasketResultProfit = 0.0;     // Track last basket realized P/L for martingale logic
double g_LastLotUsed            = 0.0;     // Track last opened lot size
int    g_SeqTradesSameDir       = 0;       // For GRID_STEP sizing

struct TradeInfo {
   ulong ticket;
   double entryPrice;
   double lotSize;
   datetime openTime;
   ENUM_POSITION_TYPE positionType;
   double highestProfit;  // For trailing stop
   bool breakEvenSet;
};

TradeInfo openTrades[100];
int totalOpenTrades = 0;

// ===== UTILS =====

double PipPoint()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits==5 || digits==3) point *= 10.0;
   return point;
}

double ClampLot(double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = MathMax(MinLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   double maxL = MathMin(MaxLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));
   if(step <= 0) step = 0.01;
   
   // round down to step
   lots = MathFloor(lots/step)*step;
   if(lots < minL) lots = minL;
   if(lots > maxL) lots = maxL;
   return NormalizeDouble(lots, 2);
}

int CountOpenByDir(ENUM_POSITION_TYPE dir)
{
   int c=0;
   for(int i=0;i<totalOpenTrades;i++){
      if(openTrades[i].ticket>0){
         if(PositionSelectByTicket(openTrades[i].ticket)){
            if(PositionGetInteger(POSITION_TYPE)==dir) c++;
         }
      }
   }
   return c;
}

bool IsLosingBasket()
{
   // A losing basket is inferred when last basket result < 0
   return (g_LastBasketResultProfit < 0.0);
}

// ===== LOT SIZING CORE =====

double ComputeRiskPercentLot(double stopLossPips)
{
   // Lot = (AccountBalance * Risk%) / MoneyPerLotAtSL
   if(stopLossPips <= 0.0) return BaseLot;
   
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point = PipPoint();
   
   if(tickValue <= 0 || tickSize <= 0) return BaseLot;
   
   double pipValuePerLot = tickValue * (point / tickSize);
   double moneyAtSLPerLot = pipValuePerLot * stopLossPips;
   
   if(moneyAtSLPerLot <= 0.0) return BaseLot;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lots = (balance * (RiskPercent/100.0)) / moneyAtSLPerLot;
   
   return lots;
}

double NextLotForDirection(ENUM_POSITION_TYPE direction)
{
   // Determine a lot size according to selected mode
   double stopPips = (TradingMode == 1) ? StopLossPips : 0.0;  // 1 = MODE_MICRO_TP
   double lots = BaseLot;

   if(LotSizingMode == 0){  // LOT_FIXED
      lots = LotSize;
   }
   else if(LotSizingMode == 1){  // LOT_RISK_PERCENT
      lots = ComputeRiskPercentLot(stopPips);
   }
   else if(LotSizingMode == 2){  // LOT_MARTINGALE
      // After a losing basket, multiply the last used lot; otherwise reset to BaseLot
      if(IsLosingBasket() && g_LastLotUsed>0){
         lots = g_LastLotUsed * MartingaleFactor;
      }else{
         lots = BaseLot;
      }
   }
   else if(LotSizingMode == 3){  // LOT_GRID_STEP
      // Increase lots with number of same-direction positions currently open
      int nSame = CountOpenByDir(direction);
      lots = BaseLot + (nSame * GridLotStep);
   }
   else if(LotSizingMode == 4){  // LOT_EQUITY_SCALE
      // Scale linearly with equity: equity/EquityPerLot * BaseLot
      if(EquityPerLot > 0.0){
         double equity = AccountInfoDouble(ACCOUNT_EQUITY);
         lots = (equity/EquityPerLot) * BaseLot;
      } else {
         lots = BaseLot;
      }
   }

   lots = ClampLot(lots);
   return lots;
}

// ===== INITIALIZATION =====

int OnInit()
{
   Print("========================================");
   Print("Mean Reversion Scalper EA v2.00 (MT5)");
   Print("========================================");
   Print("Trading Mode: ", (TradingMode == 0 ? "BASKET TP" : "MICRO TP"));
   Print("LotSizingMode: ", LotSizingMode, " (0=Fixed,1=Risk,2=Martingale,3=Grid,4=EquityScale)");
   Print("Entry Timeframe: ", EnumToString(EntryTimeframe));
   Print("Symbol: ", _Symbol);
   Print("========================================");
   
   accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   accountStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   basketStartTime = 0;
   basketActive = false;
   totalTrades = 0;
   g_LastBasketResultProfit = 0.0;
   g_LastLotUsed = 0.0;
   g_SeqTradesSameDir = 0;
   
   // Initialize trade array
   for(int i = 0; i < 100; i++)
   {
      openTrades[i].ticket = 0;
      openTrades[i].entryPrice = 0;
      openTrades[i].lotSize = 0;
      openTrades[i].openTime = 0;
      openTrades[i].positionType = WRONG_VALUE;
      openTrades[i].highestProfit = 0;
      openTrades[i].breakEvenSet = false;
   }
   
   // Initialize MA handle
   maHandle = iMA(_Symbol, EntryTimeframe, MeanReversionPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(maHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create MA indicator handle");
      return(INIT_FAILED);
   }
   
   // Set trade parameters
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints((ulong)SlippagePips);
   
   // Set filling mode
   ENUM_ORDER_TYPE_FILLING fillingMode = ORDER_FILLING_FOK;
   long fillingModeFlags = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingModeFlags & SYMBOL_FILLING_FOK) != 0)
      fillingMode = ORDER_FILLING_FOK;
   else if((fillingModeFlags & SYMBOL_FILLING_IOC) != 0)
      fillingMode = ORDER_FILLING_IOC;
   else
      fillingMode = ORDER_FILLING_RETURN;
   trade.SetTypeFilling(fillingMode);
   
   // Clean up any existing trades from this EA
   CleanupClosedTrades();
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(ShowPanel)
   {
      ObjectsDeleteAll(0, "MRSPanel_");
      Comment("");
   }
   
   // Release indicator handle
   if(maHandle != INVALID_HANDLE)
      IndicatorRelease(maHandle);
   
   Print("Mean Reversion Scalper EA Deinitialized. Reason: ", reason);
}

// ===== MAIN TICK FUNCTION =====

void OnTick()
{
   // Update trade tracking
   CleanupClosedTrades();
   UpdateTradeInfo();
   
   // Check drawdown guard
   if(UseDrawdownGuard && CheckDrawdown())
   {
      CloseAllTrades("Drawdown Protection");
      return;
   }
   
   // Check filters
   if(!CheckFilters())
      return;
   
   // Mode-specific management
   if(TradingMode == 0)  // MODE_BASKET
   {
      ManageBasketMode();
   }
   else  // MODE_MICRO_TP
   {
      ManageMicroTPMode();
   }
   
   // Check for entry signals
   if(totalOpenTrades < MaxConcurrentTrades)
   {
      CheckMeanReversionEntry();
   }
   
   // Update display
   if(ShowPanel)
   {
      UpdatePanel();
   }
}

// ===== MEAN REVERSION ENTRY LOGIC =====

void CheckMeanReversionEntry()
{
   double activeDeviationMultiplier = DeviationMultiplier;
   double activeMinDeviation = MinDeviationPips;
   int    signalShift = 1; // default to last closed candle

   if(UseFastTestingMode)
   {
      double scale = FastModeDeviationScale;
      if(scale <= 0) scale = 0.5;
      activeDeviationMultiplier = MathMax(0.1, DeviationMultiplier * scale);

      double minOverride = FastModeMinDeviationPips;
      if(minOverride <= 0) minOverride = 0.5;
      activeMinDeviation = MathMin(MinDeviationPips, minOverride);

      if(FastModeUseLiveCandle)
         signalShift = 0;
   }

   ENUM_POSITION_TYPE direction = EvaluateMeanReversionSignal(signalShift, activeDeviationMultiplier, activeMinDeviation);
   
   if(direction == WRONG_VALUE && UseQuickEntryBoost)
   {
      double quickMultScale = QuickEntryDeviationScale;
      if(quickMultScale <= 0) quickMultScale = 0.6;
      double quickMult = MathMax(0.1, activeDeviationMultiplier * quickMultScale);

      double quickMinDev = QuickEntryMinDeviationPips;
      if(quickMinDev <= 0) quickMinDev = activeMinDeviation * QuickEntryDeviationScale;
      quickMinDev = MathMin(activeMinDeviation, quickMinDev);
      quickMinDev = MathMax(0.1, quickMinDev);

      int quickShift = QuickEntryUseLiveCandle ? 0 : signalShift;
      direction = EvaluateMeanReversionSignal(quickShift, quickMult, quickMinDev);
   }

   if(direction != WRONG_VALUE)
      OpenTrade(direction);
}

ENUM_POSITION_TYPE EvaluateMeanReversionSignal(const int shift, const double deviationMultiplier, const double minDeviation)
{
   if(deviationMultiplier <= 0.0) return WRONG_VALUE;

   double effectiveMinDeviation = MathMax(0.1, minDeviation);

   // Get close price
   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(_Symbol, EntryTimeframe, shift, 1, close) <= 0) return WRONG_VALUE;
   double closePrice = close[0];
   if(closePrice <= 0) return WRONG_VALUE;

   // Get MA value
   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(maHandle, 0, shift, 1, ma) <= 0) return WRONG_VALUE;
   double maValue = ma[0];
   if(maValue <= 0) return WRONG_VALUE;

   double stdDev = CalculateStdDev(MeanReversionPeriod, shift);
   if(stdDev <= 0) return WRONG_VALUE;

   double point = PipPoint();
   double deviationPips = MathAbs(closePrice - maValue) / point;
   double thresholdPips = (stdDev * deviationMultiplier) / point;
   double minRequiredDeviation = MathMin(effectiveMinDeviation, thresholdPips);

   if(deviationPips < minRequiredDeviation)
      return WRONG_VALUE;

   if(closePrice < maValue - (stdDev * deviationMultiplier))
      return POSITION_TYPE_BUY;

   if(closePrice > maValue + (stdDev * deviationMultiplier))
      return POSITION_TYPE_SELL;

   return WRONG_VALUE;
}

// ===== CALCULATE STANDARD DEVIATION =====

double CalculateStdDev(int period, int shift)
{
   double sum = 0;
   double sumSq = 0;

   // Get MA value
   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(maHandle, 0, shift, 1, ma) <= 0) return 0;
   double maValue = ma[0];
   if(maValue <= 0) return 0;

   // Get close prices
   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(_Symbol, EntryTimeframe, shift, period, close) <= 0) return 0;

   int startIdx = 0;
   int endIdx = period;

   for(int i = startIdx; i < endIdx; i++)
   {
      if(i >= ArraySize(close)) break;
      double closeValue = close[i];
      if(closeValue > 0)
      {
         double diff = closeValue - maValue;
         sum   += diff;
         sumSq += diff * diff;
      }
   }

   if(period > 1)
   {
      double variance = (sumSq - (sum * sum / period)) / (period - 1);
      if(variance > 0) return MathSqrt(variance);
   }
   return 0;
}

// ===== BASKET MODE MANAGEMENT =====

void ManageBasketMode()
{
   if(totalOpenTrades == 0)
   {
      // Detect basket close result only when transitioning from active basket to zero trades
      if(basketActive)
      {
         // Compute realized profit of just-closed basket
         g_LastBasketResultProfit = highestBasketProfit; // heuristic
         if(totalFloatingProfit < 0) g_LastBasketResultProfit = -1.0; // if currently negative (should be 0), mark as loss
      }

      basketActive = false;
      basketStartTime = 0;
      highestBasketProfit = 0;
      g_SeqTradesSameDir = 0;
      return;
   }

   if(!basketActive)
   {
      basketActive = true;
      basketStartTime = TimeCurrent();
      highestBasketProfit = 0;
   }

   // Calculate total floating profit
   totalFloatingProfit = 0;
   for(int i = 0; i < totalOpenTrades; i++)
   {
      if(openTrades[i].ticket > 0)
      {
         if(PositionSelectByTicket(openTrades[i].ticket))
         {
            totalFloatingProfit += PositionGetDouble(POSITION_PROFIT) + 
                                    PositionGetDouble(POSITION_SWAP) + 
                                    PositionGetDouble(POSITION_COMMISSION);
         }
      }
   }

   // Track highest profit
   if(totalFloatingProfit > highestBasketProfit)
      highestBasketProfit = totalFloatingProfit;

   // Check basket profit target
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double profitTarget = (BasketProfitFixed > 0) ? BasketProfitFixed : balance * (BasketProfitPercent / 100.0);
   
   if(totalFloatingProfit >= profitTarget)
   {
      CloseAllTrades("Basket Profit Target: " + DoubleToString(totalFloatingProfit, 2));
      return;
   }

   // Check time limit
   if(UseBasketTimeLimit && basketStartTime > 0)
   {
      int elapsedMinutes = (int)((TimeCurrent() - basketStartTime) / 60);
      if(elapsedMinutes >= BasketTimeLimitMinutes)
      {
         CloseAllTrades("Basket Time Limit: " + IntegerToString(elapsedMinutes) + " minutes");
         return;
      }
   }
}

// ===== MICRO TP MODE MANAGEMENT =====

void ManageMicroTPMode()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   
   for(int i = totalOpenTrades - 1; i >= 0; i--)
   {
      if(openTrades[i].ticket > 0)
      {
         if(PositionSelectByTicket(openTrades[i].ticket))
         {
            double point = PipPoint();
            double profitPips = 0;
            
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            if(posType == POSITION_TYPE_BUY)  
               profitPips = (tick.bid - openTrades[i].entryPrice) / point;
            else                        
               profitPips = (openTrades[i].entryPrice - tick.ask) / point;

            // Update highest profit (money)
            double currentProfit = PositionGetDouble(POSITION_PROFIT) + 
                                  PositionGetDouble(POSITION_SWAP) + 
                                  PositionGetDouble(POSITION_COMMISSION);
            
            if(currentProfit > openTrades[i].highestProfit)
               openTrades[i].highestProfit = currentProfit;

            // Check micro TP
            if(profitPips >= MicroTPPips)
            {
               CloseTrade(i, "Micro TP: " + DoubleToString(profitPips, 1) + " pips");
               continue;
            }

            // Break-even logic
            if(!openTrades[i].breakEvenSet && profitPips >= BreakEvenPips)
            {
               MoveToBreakEven(i);
               openTrades[i].breakEvenSet = true;
            }

            // Trailing stop logic
            if(profitPips >= TrailingStartPips)
            {
               UpdateTrailingStop(i, profitPips);
            }
         }
      }
   }
}

// ===== MOVE TO BREAK-EVEN =====

void MoveToBreakEven(int index)
{
   if(openTrades[index].ticket <= 0) return;
   if(!PositionSelectByTicket(openTrades[index].ticket)) return;

   double newSL = openTrades[index].entryPrice;
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   // Only move if new SL is better
   if(posType == POSITION_TYPE_BUY && (currentSL < newSL || currentSL == 0))
      ModifyPositionWithRetry(openTrades[index].ticket, newSL, currentTP);
   else if(posType == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))
      ModifyPositionWithRetry(openTrades[index].ticket, newSL, currentTP);
}

// ===== UPDATE TRAILING STOP =====

void UpdateTrailingStop(int index, double currentProfitPips)
{
   if(openTrades[index].ticket <= 0) return;
   if(!PositionSelectByTicket(openTrades[index].ticket)) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double point = PipPoint();
   double newSL = 0;
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   if(posType == POSITION_TYPE_BUY)
   {
      newSL = tick.bid - (TrailingStepPips * point);
      if(newSL > openTrades[index].entryPrice && (currentSL < newSL || currentSL == 0))
         ModifyPositionWithRetry(openTrades[index].ticket, newSL, currentTP);
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      newSL = tick.ask + (TrailingStepPips * point);
      if(newSL < openTrades[index].entryPrice && (currentSL > newSL || currentSL == 0))
         ModifyPositionWithRetry(openTrades[index].ticket, newSL, currentTP);
   }
}

// ===== OPEN TRADE =====

void OpenTrade(ENUM_POSITION_TYPE direction)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double price = (direction == POSITION_TYPE_BUY) ? tick.ask : tick.bid;
   double sl = 0, tp = 0;
   double point = PipPoint();
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Compute dynamic lots according to observed behavior
   double lots = NextLotForDirection(direction);

   // Set SL/TP for micro TP mode (needed also for risk-based lot computation reference)
   if(TradingMode == 1)  // MODE_MICRO_TP
   {
      if(direction == POSITION_TYPE_BUY)
      {
         sl = price - (StopLossPips * point);
         tp = price + (MicroTPPips * point);
      }
      else
      {
         sl = price + (StopLossPips * point);
         tp = price - (MicroTPPips * point);
      }
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
   }

   ulong ticket = SendOrderWithRetry(direction, lots, price, sl, tp);

   if(ticket > 0)
   {
      if(totalOpenTrades < 100)
      {
         openTrades[totalOpenTrades].ticket = ticket;
         openTrades[totalOpenTrades].entryPrice = price;
         openTrades[totalOpenTrades].lotSize = lots;
         openTrades[totalOpenTrades].openTime = TimeCurrent();
         openTrades[totalOpenTrades].positionType = direction;
         openTrades[totalOpenTrades].highestProfit = 0;
         openTrades[totalOpenTrades].breakEvenSet = false;
         totalOpenTrades++;
         totalTrades++;
      }
      
      // Track last lot and sequence same direction for sizing logic
      g_LastLotUsed = lots;
      
      // reset or increment same-direction counter
      static ENUM_POSITION_TYPE lastDir = WRONG_VALUE;
      if(lastDir == direction) g_SeqTradesSameDir++;
      else g_SeqTradesSameDir = 1;
      lastDir = direction;
   }
}

// ===== SEND ORDER WITH RETRY =====

ulong SendOrderWithRetry(ENUM_POSITION_TYPE orderType, double lots, double price, double sl, double tp)
{
   int attempts = 0;
   ulong ticket = 0;

   while(attempts < MaxRetries)
   {
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) break;
      
      double currentPrice = (orderType == POSITION_TYPE_BUY) ? tick.ask : tick.bid;
      bool success = false;
      
      if(orderType == POSITION_TYPE_BUY)
      {
         success = trade.Buy(lots, _Symbol, currentPrice, sl, tp, "MR Scalper");
      }
      else
      {
         success = trade.Sell(lots, _Symbol, currentPrice, sl, tp, "MR Scalper");
      }

      if(success)
      {
         // Find the position ticket by magic number and symbol
         Sleep(50); // Small delay to ensure position is registered
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong posTicket = PositionGetTicket(i);
            if(posTicket > 0 && PositionSelectByTicket(posTicket))
            {
               if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
                  PositionGetInteger(POSITION_MAGIC) == MagicNumber)
               {
                  ticket = posTicket;
                  return ticket;
               }
            }
         }
      }

      int error = GetLastError();
      Print("OrderSend failed: ", error, " | Attempt: ", attempts + 1);

      if(error == 10004 || error == 10006 || error == 10007 || error == 10010 || error == 10011 || error == 10012)
      {
         // Retry-able errors
         Sleep(RetryDelayMS);
         attempts++;
      }
      else
      {
         // Non-retry-able error
         break;
      }
   }

   return 0;
}

// ===== MODIFY POSITION WITH RETRY =====

bool ModifyPositionWithRetry(ulong ticket, double sl, double tp)
{
   int attempts = 0;
   
   while(attempts < MaxRetries)
   {
      if(PositionSelectByTicket(ticket))
      {
         if(trade.PositionModify(ticket, sl, tp))
            return true;

         int error = GetLastError();
         if(error == 10004 || error == 10006 || error == 10010 || error == 10011 || error == 10012)
         {
            Sleep(RetryDelayMS);
            attempts++;
         }
         else
         {
            break;
         }
      }
      else break;
   }
   return false;
}

// ===== CLOSE TRADE =====

void CloseTrade(int index, string reason)
{
   if(openTrades[index].ticket <= 0) return;
   
   if(trade.PositionClose(openTrades[index].ticket))
   {
      Print("Trade closed: #", openTrades[index].ticket, " | ", reason);
      RemoveTradeFromArray(index);
   }
}

// ===== CLOSE ALL TRADES =====

void CloseAllTrades(string reason)
{
   Print("========================================");
   Print("CLOSING ALL TRADES: ", reason);
   Print("========================================");

   // compute realized P/L snapshot before closing for martingale bookkeeping
   double preEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   for(int i = totalOpenTrades - 1; i >= 0; i--)
   {
      if(openTrades[i].ticket > 0)
      {
         CloseTrade(i, reason);
      }
   }

   // approximate basket result as change in equity vs. prior peak floating
   double postEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_LastBasketResultProfit = postEquity - preEquity; // rough proxy

   basketActive = false;
   basketStartTime = 0;
   highestBasketProfit = 0;
   g_SeqTradesSameDir = 0;
}

// ===== CLEANUP CLOSED TRADES =====

void CleanupClosedTrades()
{
   for(int i = totalOpenTrades - 1; i >= 0; i--)
   {
      if(openTrades[i].ticket > 0)
      {
         if(!PositionSelectByTicket(openTrades[i].ticket))
         {
            RemoveTradeFromArray(i);
         }
      }
   }
}

// ===== UPDATE TRADE INFO =====

void UpdateTradeInfo()
{
   for(int i = 0; i < totalOpenTrades; i++)
   {
      if(openTrades[i].ticket > 0)
      {
         if(PositionSelectByTicket(openTrades[i].ticket))
         {
            double profit = PositionGetDouble(POSITION_PROFIT) + 
                           PositionGetDouble(POSITION_SWAP) + 
                           PositionGetDouble(POSITION_COMMISSION);
            
            if(profit > openTrades[i].highestProfit)
               openTrades[i].highestProfit = profit;
         }
      }
   }
}

// ===== REMOVE TRADE FROM ARRAY =====

void RemoveTradeFromArray(int index)
{
   if(index < 0 || index >= totalOpenTrades) return;
   for(int i = index; i < totalOpenTrades - 1; i++)
      openTrades[i] = openTrades[i + 1];
   totalOpenTrades--;
}

// ===== CHECK DRAWDOWN =====

bool CheckDrawdown()
{
   if(!UseDrawdownGuard) return false;

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxDrawdown = accountStartEquity * (MaxDrawdownPercent / 100.0);
   
   if(currentEquity < (accountStartEquity - maxDrawdown))
   {
      Print("DRAWDOWN LIMIT REACHED: ", MaxDrawdownPercent, "%");
      return true;
   }
   return false;
}

// ===== CHECK FILTERS =====

bool CheckFilters()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;

   // Spread filter
   double spread = (tick.ask - tick.bid) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 5 || digits == 3) spread = spread / 10.0;

   // Debug spread (throttled)
   static datetime lastSpreadLog = 0;
   if(TimeCurrent() - lastSpreadLog > 300)
   {
      Print("Spread Check: ", DoubleToString(spread, 2), " pips (Max: ", MaxSpreadPips, ")");
      lastSpreadLog = TimeCurrent();
   }
   if(spread > MaxSpreadPips) return false;

   // Session filter
   if(UseSessionFilter)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int currentHour = dt.hour;
      
      if(currentHour < SessionStartHour || currentHour >= SessionEndHour) return false;
   }

   // News filter placeholder (no calendar integration in this build)
   if(UseNewsFilter)
   {
      // Could integrate with a CSV/WebRequest calendar in a future build
   }
   return true;
}

// ===== UPDATE PANEL =====

void UpdatePanel()
{
   string panelText = "";
   panelText += "=== MEAN REVERSION SCALPER v2.00 (MT5) ===\n";
   panelText += "Mode: " + (TradingMode == 0 ? "BASKET TP" : "MICRO TP") + "\n";
   panelText += "LotMode: " + IntegerToString(LotSizingMode) + " (0=fixed,1=risk,2=marti,3=grid,4=equity)\n";
   panelText += "--------------------------------\n";
   panelText += "Open Trades: " + IntegerToString(totalOpenTrades) + "\n";
   panelText += "Total Trades: " + IntegerToString(totalTrades) + "\n";

   if(TradingMode == 0)  // MODE_BASKET
   {
      // Recompute floating for live display
      double floating=0;
      for(int i=0;i<totalOpenTrades;i++){
         if(openTrades[i].ticket>0 && PositionSelectByTicket(openTrades[i].ticket)){
            floating += PositionGetDouble(POSITION_PROFIT)+
                        PositionGetDouble(POSITION_SWAP)+
                        PositionGetDouble(POSITION_COMMISSION);
         }
      }
      panelText += "Basket P/L: $" + DoubleToString(floating, 2) + "\n";
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double profitTarget = (BasketProfitFixed > 0) ? BasketProfitFixed : (balance * (BasketProfitPercent / 100.0));
      panelText += "Target: $" + DoubleToString(profitTarget, 2) + "\n";
      if(basketActive && basketStartTime > 0){
         int elapsed = (int)((TimeCurrent() - basketStartTime) / 60);
         panelText += "Basket Time: " + IntegerToString(elapsed) + " min\n";
      }
   }
   else
   {
      panelText += "Micro TP: " + DoubleToString(MicroTPPips, 1) + " pips\n";
      panelText += "SL: " + DoubleToString(StopLossPips, 1) + " pips\n";
   }

   panelText += "--------------------------------\n";
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   panelText += "Balance: $" + DoubleToString(balance, 2) + "\n";
   panelText += "Equity: $" + DoubleToString(equity, 2) + "\n";
   double drawdown = ((accountStartEquity - equity) / accountStartEquity) * 100.0;
   panelText += "Drawdown: " + DoubleToString(drawdown, 2) + "%\n";
   
   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick))
   {
      double currentSpread = (tick.ask - tick.bid) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      if(digits == 5 || digits == 3)
         currentSpread = currentSpread / 10.0;
      panelText += "Spread: " + DoubleToString(currentSpread, 1) + " pips\n";
   }

   Comment(panelText);
}

// ===== ON TRADE TRANSACTION =====

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   // Handle position updates
   if(trans.type == TRADE_TRANSACTION_POSITION)
   {
      // Position was modified or closed
      CleanupClosedTrades();
      UpdateTradeInfo();
   }
}


