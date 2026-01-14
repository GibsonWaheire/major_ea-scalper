#property copyright "Copyright 2025, Advanced Trading Systems"

#property link      "https://www.mcgibsdigitalsolutions.com"

#property version   "1.10"

#property strict



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

   int ticket;

   double entryPrice;

   double lotSize;

   datetime openTime;

   int orderType;

   double highestProfit;  // For trailing stop

   bool breakEvenSet;

};

TradeInfo openTrades[100];

int totalOpenTrades = 0;



// ===== UTILS =====

double PipPoint()

{

   double point = MarketInfo(Symbol(), MODE_POINT);

   int digits = (int)MarketInfo(Symbol(), MODE_DIGITS);

   if(digits==5 || digits==3) point *= 10.0;

   return point;

}



double ClampLot(double lots)

{

   double step = MarketInfo(Symbol(), MODE_LOTSTEP);

   double minL = MathMax(MinLot, MarketInfo(Symbol(), MODE_MINLOT));

   double maxL = MathMin(MaxLot, MarketInfo(Symbol(), MODE_MAXLOT));

   if(step <= 0) step = 0.01;

   // round down to step

   lots = MathFloor(lots/step)*step;

   if(lots < minL) lots = minL;

   if(lots > maxL) lots = maxL;

   return NormalizeDouble(lots,2);

}



int CountOpenByDir(int dir)

{

   int c=0;

   for(int i=0;i<totalOpenTrades;i++){

      if(openTrades[i].ticket>0){

         if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET)){

            if(OrderType()==dir) c++;

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

   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);

   double pipValuePerLot = tickValue * (PipPoint()/MarketInfo(Symbol(), MODE_TICKSIZE));

   double moneyAtSLPerLot = pipValuePerLot * stopLossPips;

   if(moneyAtSLPerLot <= 0.0) return BaseLot;

   double lots = (AccountBalance() * (RiskPercent/100.0)) / moneyAtSLPerLot;

   return lots;

}



double NextLotForDirection(int direction)

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

         lots = (AccountEquity()/EquityPerLot) * BaseLot;

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

   Print("Mean Reversion Scalper EA v1.10 (Dynamic Lots)");

   Print("========================================");

   Print("Trading Mode: ", (TradingMode == 0 ? "BASKET TP" : "MICRO TP"));

   Print("LotSizingMode: ", LotSizingMode, " (0=Fixed,1=Risk,2=Martingale,3=Grid,4=EquityScale)");

   Print("Entry Timeframe: ", EnumToString(EntryTimeframe));

   Print("Symbol: ", Symbol());

   Print("========================================");

   

   accountStartBalance = AccountBalance();

   accountStartEquity = AccountEquity();

   basketStartTime = 0;

   basketActive = false;

   totalTrades = 0;

   g_LastBasketResultProfit = 0.0;

   g_LastLotUsed = 0.0;

   g_SeqTradesSameDir = 0;

   

   // Initialize trade array

   for(int i = 0; i < 100; i++)

   {

      openTrades[i].ticket = -1;

      openTrades[i].entryPrice = 0;

      openTrades[i].lotSize = 0;

      openTrades[i].openTime = 0;

      openTrades[i].orderType = -1;

      openTrades[i].highestProfit = 0;

      openTrades[i].breakEvenSet = false;

   }

   

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

   // Use last closed candle for more reliable signals

   double close1 = iClose(Symbol(), EntryTimeframe, 1);

   if(close1 <= 0) return;

   

   // Calculate moving average (use shift 1 for closed candle)

   double ma = iMA(Symbol(), EntryTimeframe, MeanReversionPeriod, 0, MODE_SMA, PRICE_CLOSE, 1);

   if(ma <= 0) return;

   

   // Calculate standard deviation

   double stdDev = CalculateStdDev(MeanReversionPeriod);

   if(stdDev <= 0) return;

   

   double point = PipPoint();

   double deviationPips = MathAbs(close1 - ma) / point;

   double thresholdPips  = (stdDev * DeviationMultiplier) / point;

   

   // Minimum deviation check - relaxed: use threshold OR min deviation, whichever is smaller

   double minRequiredDeviation = MathMin(MinDeviationPips, thresholdPips);

   if(deviationPips < minRequiredDeviation) return;

   

   int direction = -1;

   if(close1 < ma - (stdDev * DeviationMultiplier))

   {

      direction = OP_BUY; // Below mean => expect reversion up

   }

   else if(close1 > ma + (stdDev * DeviationMultiplier))

   {

      direction = OP_SELL; // Above mean => expect reversion down

   }

   

   if(direction >= 0)

   {

      OpenTrade(direction);

   }

}



// ===== CALCULATE STANDARD DEVIATION =====

double CalculateStdDev(int period)

{

   double sum = 0;

   double sumSq = 0;

   // Use shift 1 to match the MA calculation (closed candle)

   double ma = iMA(Symbol(), EntryTimeframe, period, 0, MODE_SMA, PRICE_CLOSE, 1);

   if(ma <= 0) return 0;

   

   for(int i = 1; i <= period; i++)

   {

      double close = iClose(Symbol(), EntryTimeframe, i);

      if(close > 0)

      {

         double diff = close - ma;

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

         // Compute realized profit of just-closed basket (approx via AccountEquity - previous; here we store max floating snapshot)

         // As a simple proxy, consider that basket closed either by target or protection; use highestBasketProfit if positive, else -1

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

         if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))

         {

            totalFloatingProfit += OrderProfit() + OrderSwap() + OrderCommission();

         }

      }

   }

   

   // Track highest profit

   if(totalFloatingProfit > highestBasketProfit)

      highestBasketProfit = totalFloatingProfit;

   

   // Check basket profit target

   double profitTarget = (BasketProfitFixed > 0) ? BasketProfitFixed : AccountBalance() * (BasketProfitPercent / 100.0);

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

   for(int i = totalOpenTrades - 1; i >= 0; i--)

   {

      if(openTrades[i].ticket > 0)

      {

         if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))

         {

            double point = PipPoint();

            double profitPips = 0;

            if(OrderType() == OP_BUY)  profitPips = (Bid - openTrades[i].entryPrice) / point;

            else                        profitPips = (openTrades[i].entryPrice - Ask) / point;

            

            // Update highest profit (money)

            double currentProfit = OrderProfit() + OrderSwap() + OrderCommission();

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

   if(!OrderSelect(openTrades[index].ticket, SELECT_BY_TICKET)) return;

   

   double newSL = openTrades[index].entryPrice;

   double currentSL = OrderStopLoss();

   

   // Only move if new SL is better

   if(OrderType() == OP_BUY && (currentSL < newSL || currentSL == 0))

      ModifyOrderWithRetry(openTrades[index].ticket, newSL, OrderTakeProfit());

   else if(OrderType() == OP_SELL && (currentSL > newSL || currentSL == 0))

      ModifyOrderWithRetry(openTrades[index].ticket, newSL, OrderTakeProfit());

}



// ===== UPDATE TRAILING STOP =====

void UpdateTrailingStop(int index, double currentProfitPips)

{

   if(openTrades[index].ticket <= 0) return;

   if(!OrderSelect(openTrades[index].ticket, SELECT_BY_TICKET)) return;

   

   double point = PipPoint();

   double newSL = 0;

   double currentSL = OrderStopLoss();

   

   if(OrderType() == OP_BUY)

   {

      newSL = Bid - (TrailingStepPips * point);

      if(newSL > openTrades[index].entryPrice && (currentSL < newSL || currentSL == 0))

         ModifyOrderWithRetry(openTrades[index].ticket, newSL, OrderTakeProfit());

   }

   else if(OrderType() == OP_SELL)

   {

      newSL = Ask + (TrailingStepPips * point);

      if(newSL < openTrades[index].entryPrice && (currentSL > newSL || currentSL == 0))

         ModifyOrderWithRetry(openTrades[index].ticket, newSL, OrderTakeProfit());

   }

}



// ===== OPEN TRADE =====

void OpenTrade(int direction)

{

   double price = (direction == OP_BUY) ? Ask : Bid;

   double sl = 0, tp = 0;

   double point = PipPoint();

   int digits = (int)MarketInfo(Symbol(), MODE_DIGITS);

   

   // Compute dynamic lots according to observed behavior

   double lots = NextLotForDirection(direction);

   

    // Set SL/TP for micro TP mode (needed also for risk-based lot computation reference)
    if(TradingMode == 1)  // MODE_MICRO_TP

   {

      if(direction == OP_BUY)

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

   

   int ticket = SendOrderWithRetry(direction, lots, price, sl, tp);

   

   if(ticket > 0)

   {

      if(totalOpenTrades < 100)

      {

         openTrades[totalOpenTrades].ticket = ticket;

         openTrades[totalOpenTrades].entryPrice = price;

         openTrades[totalOpenTrades].lotSize = lots;

         openTrades[totalOpenTrades].openTime = TimeCurrent();

         openTrades[totalOpenTrades].orderType = direction;

         openTrades[totalOpenTrades].highestProfit = 0;

         openTrades[totalOpenTrades].breakEvenSet = false;

         totalOpenTrades++;

         totalTrades++;

      }

      // Track last lot and sequence same direction for sizing logic

      g_LastLotUsed = lots;

      // reset or increment same-direction counter

      static int lastDir = -999;

      if(lastDir == direction) g_SeqTradesSameDir++;

      else g_SeqTradesSameDir = 1;

      lastDir = direction;

   }

}



// ===== SEND ORDER WITH RETRY =====

int SendOrderWithRetry(int orderType, double lots, double price, double sl, double tp)

{

   int attempts = 0;

   int ticket = -1;

   

   while(attempts < MaxRetries)

   {

      ticket = OrderSend(Symbol(), orderType, lots, price, SlippagePips, sl, tp,

                         "MR Scalper", MagicNumber, 0, 

                         (orderType == OP_BUY ? clrBlue : clrRed));

      

      if(ticket > 0)

         return ticket;

      

      int error = GetLastError();

      Print("OrderSend failed: ", error, " | Attempt: ", attempts + 1);

      

      if(error == 130 || error == 131 || error == 134 || error == 146 || error==136 || error==4108)

      {

         // Retry-able errors

         Sleep(RetryDelayMS);

         attempts++;

         RefreshRates();

         price = (orderType == OP_BUY) ? Ask : Bid;

      }

      else

      {

         // Non-retry-able error

         break;

      }

   }

   

   return -1;

}



// ===== MODIFY ORDER WITH RETRY =====

bool ModifyOrderWithRetry(int ticket, double sl, double tp)

{

   int attempts = 0;

   while(attempts < MaxRetries)

   {

      if(OrderSelect(ticket, SELECT_BY_TICKET))

      {

         bool modified = OrderModify(ticket, OrderOpenPrice(), sl, tp, 0, clrYellow);

         if(modified) return true;

         

         int error = GetLastError();

         if(error == 130 || error == 131 || error == 146 || error==4108)

         {

            Sleep(RetryDelayMS);

            attempts++;

            RefreshRates();

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

   if(OrderSelect(openTrades[index].ticket, SELECT_BY_TICKET))

   {

      double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;

      bool closed = OrderClose(openTrades[index].ticket, OrderLots(), closePrice, SlippagePips, clrYellow);

      if(closed)

      {

         Print("Trade closed: #", openTrades[index].ticket, " | ", reason);

         RemoveTradeFromArray(index);

      }

   }

}



// ===== CLOSE ALL TRADES =====

void CloseAllTrades(string reason)

{

   Print("========================================");

   Print("CLOSING ALL TRADES: ", reason);

   Print("========================================");

   

   // compute realized P/L snapshot before closing for martingale bookkeeping

   double preEquity = AccountEquity();

   

   for(int i = totalOpenTrades - 1; i >= 0; i--)

   {

      if(openTrades[i].ticket > 0)

      {

         CloseTrade(i, reason);

      }

   }

   

   // approximate basket result as change in equity vs. prior peak floating

   double postEquity = AccountEquity();

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

         if(!OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))

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

         if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))

         {

            double profit = OrderProfit() + OrderSwap() + OrderCommission();

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

   double currentEquity = AccountEquity();

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

   // Spread filter

   double spread = (Ask - Bid) / MarketInfo(Symbol(), MODE_POINT);

   int digits = (int)MarketInfo(Symbol(), MODE_DIGITS);

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

      int currentHour = Hour();

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

   panelText += "=== MEAN REVERSION SCALPER v1.10 ===\n";

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

         if(openTrades[i].ticket>0 && OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET)){

            floating += OrderProfit()+OrderSwap()+OrderCommission();

         }

      }

      panelText += "Basket P/L: $" + DoubleToString(floating, 2) + "\n";

      double profitTarget = (BasketProfitFixed > 0) ? BasketProfitFixed : (AccountBalance() * (BasketProfitPercent / 100.0));

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

   panelText += "Balance: $" + DoubleToString(AccountBalance(), 2) + "\n";

   panelText += "Equity: $" + DoubleToString(AccountEquity(), 2) + "\n";

   double drawdown = ((accountStartEquity - AccountEquity()) / accountStartEquity) * 100.0;

   panelText += "Drawdown: " + DoubleToString(drawdown, 2) + "%\n";

   double currentSpread = (Ask - Bid) / MarketInfo(Symbol(), MODE_POINT);

   if((int)MarketInfo(Symbol(), MODE_DIGITS) == 5 || (int)MarketInfo(Symbol(), MODE_DIGITS) == 3)

      currentSpread = currentSpread / 10.0;

   panelText += "Spread: " + DoubleToString(currentSpread, 1) + " pips\n";

   

   Comment(panelText);
}
