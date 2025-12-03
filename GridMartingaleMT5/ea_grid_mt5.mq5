//+------------------------------------------------------------------+
//|                                                  ea_grid_mt5.mq5 |
//|                        Grid + Martingale Basket EA for MetaTrader 5 |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      ""
#property version   "3.10"

#include <Trade\Trade.mqh>

//--- Input parameters
input group "===== Grid + Martingale Settings ====="
input bool     UsePercentageLotSizing = true; // Use % of balance for lot sizing
input double   BaseLotPercent = 4.0;     // Base lot % of account balance
input double   SmallLotPercent = 2.0;   // Small lot % (conservative/low momentum)
input double   RiskyLotPercent = 6.0;    // Risky lot % (aggressive/high momentum)
input double   BaseLotSize = 0.01;       // Base lot size (if % disabled)
input double   SmallLotSize = 0.005;     // Small lot (if % disabled)
input double   RiskyLotSize = 0.02;      // Risky lot (if % disabled)
input double   Multiplier = 2.0;         // Martingale multiplier
input int      StepPoints = 500;         // Grid step in points
input int      GridLevels = 3;           // Number of grid levels each side (max 3 pending orders)
input int      MinTakeProfitPips = 10;   // Minimum TP in pips for each order
input double   TakeProfitMoney = 5.0;    // Basket TP in account currency
input int      Direction = 0;            // 1=BUY only, -1=SELL only, 0=both
input ulong    Magic = 777;              // Magic number
input bool     UseDynamicLotSizing = true; // Use dynamic lot sizing based on momentum

input group "===== Trading Settings ====="
input int      Slippage = 0;             // Slippage in points
input string   CommentPrefix = "GridMart"; // Trade comment prefix
input bool     UseTrendFilter = true;    // Use trend filter for smarter entries
input int      TrendPeriod = 20;          // EMA period for trend
input bool     UseVolatilityFilter = true; // Filter low volatility
input double   MinATRMultiplier = 0.5;    // Minimum ATR for trading

input group "===== Advanced Profit System (99% Better) ====="
input bool     UseEquityBasedTP = true;   // Use equity-based profit targets (scales with account)
input double   BasketTPPercent = 2.0;     // Basket TP as % of equity (2% = $200 on $10k)
input double   MinBasketTPCurrency = 20.0; // Minimum basket TP in currency
input double   MaxBasketTPCurrency = 1000.0; // Maximum basket TP in currency
input bool     UseIndividualTP = false;    // Set TP per individual position (disabled for basket focus)
input double   IndividualTPPercent = 1.0;  // Individual TP as % of equity per position
input bool     UseDynamicScaling = true;   // Scale TP based on basket size
input double   ScalingFactor = 0.2;       // +20% TP per additional position
input bool     UseVolatilityAdaptiveTP = true; // Adjust TP based on market volatility
input double   VolatilityMultiplier = 1.5; // Increase TP in high volatility
input int      MinBasketTrades = 1;       // Minimum trades to keep in basket
input int      MaxBasketTrades = 5;       // Maximum trades in basket

input group "===== Profit Protection Settings ====="
input bool     UseTrailingStop = true;   // Use trailing stop for basket
input double   TrailingStartPercent = 0.3; // Start trailing after this % of equity profit
input double   TrailingStepPercent = 0.1; // Trailing step as % of equity
input bool     UseBreakEven = true;      // Move to break-even protection
input double   BreakEvenTriggerPercent = 0.2; // Trigger BE after this % of equity profit
input bool     UseProfitLock = true;     // Lock in profits (prevent reversal)
input double   ProfitLockPercent = 50.0;  // Lock this % of peak profit
input double   MaxDrawdownFromPeak = 30.0; // Close if profit drops this % from peak
input bool     UseMAEProtection = true;  // Maximum Adverse Excursion protection
input double   MAEThresholdPercent = 0.5; // Close if basket loss exceeds this % of equity
input bool     UseProgressiveExits = true; // Close partial positions at profit milestones
input double   ProgressiveExit1Percent = 1.0; // Close 25% at this % of equity
input double   ProgressiveExit2Percent = 1.5; // Close 25% at this % of equity
input bool     MaintainMinBasketSize = true; // Never close below MinBasketTrades
input bool     UseIndividualTrailing = false; // Trail individual positions (uses 50% of grid step)
input bool     PreventHedging = true;    // Prevent opposite direction trades (single direction only)
input int      ParameterChangeMode = 0;  // 0=Keep positions, 1=Close all, 2=Warn only
input bool     ImmediateMarketEntry = true; // Open market order immediately on EA load
input bool     ImmediateEntryIgnoreFilters = true; // Ignore filters for immediate entry

input group "===== Dynamic Lot Sizing Settings ====="
input int      MomentumPeriod = 14;      // Period for momentum calculation
input double   MomentumThreshold = 0.6;  // Threshold for risky lot (0.0-1.0)
input double   MomentumLowThreshold = 0.3; // Threshold for small lot (0.0-1.0)
input bool     UseTrendStrength = true;   // Consider trend strength in lot sizing
input bool     UseVolatilityFactor = true; // Consider volatility in lot sizing

//--- Global variables
CTrade trade;
int lastDirection = 1;  // Store last direction for Direction=0 (alternate mode)
datetime lastOrderTime = 0;  // Prevent rapid-fire orders
double lastGridCenter = 0.0;  // Last grid center price
int gridUpdateCounter = 0;  // Counter to update grid periodically
int lastPendingDirection = 0;  // Track direction of pending orders (1=BUY, -1=SELL, 0=none)
double peakBasketProfit = 0.0;  // Track peak profit for protection
double lockedProfitLevel = 0.0;  // Locked profit level
bool breakEvenActivated = false;  // Break-even protection activated
double trailingStopLevel = 0.0;  // Current trailing stop level
double currentBasketTP = 0.0;  // Current dynamic basket TP
bool progressiveExit1Done = false;  // Progressive exit milestone 1
bool progressiveExit2Done = false;  // Progressive exit milestone 2

// Parameter change detection
double lastBaseLotSize = 0.0;
double lastMultiplier = 0.0;
int lastStepPoints = 0;
int lastGridLevels = 0;
int lastDirectionParam = 0;
bool parametersChanged = false;
bool positionsFromOldParams = false;  // Track if positions exist from old parameters
bool immediateEntryExecuted = false;  // Track if immediate entry was executed

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Detect parameter changes
   parametersChanged = false;
   if(lastBaseLotSize != 0.0 || lastMultiplier != 0.0 || lastStepPoints != 0 || lastGridLevels != 0)
   {
      if(lastBaseLotSize != BaseLotSize || lastMultiplier != Multiplier || lastStepPoints != StepPoints || 
         lastGridLevels != GridLevels || lastDirectionParam != Direction)
      {
         parametersChanged = true;
         Print("WARNING: Parameters changed while EA was running!");
         Print("Old: BaseLotSize=", lastBaseLotSize, " Multiplier=", lastMultiplier, " StepPoints=", lastStepPoints, " GridLevels=", lastGridLevels);
         Print("New: BaseLotSize=", BaseLotSize, " Multiplier=", Multiplier, " StepPoints=", StepPoints, " GridLevels=", GridLevels);
         
         int positionCount = CountPositions();
         if(positionCount > 0)
         {
            positionsFromOldParams = true;
            
            if(ParameterChangeMode == 1)  // Close all
            {
               Print("ParameterChangeMode=1: Closing all positions");
               CloseAll();
               positionsFromOldParams = false;
            }
            else if(ParameterChangeMode == 0)  // Keep positions
            {
               Print("ParameterChangeMode=0: Keeping existing positions");
               Print("New parameters will apply to new positions only");
            }
            else  // Warn only
            {
               Print("ParameterChangeMode=2: Warning only - continuing with mixed parameters");
            }
         }
         else
         {
            positionsFromOldParams = false;
         }
      }
   }
   
   // Check for and execute any existing pending orders (convert to market execution)
   ExecutePendingOrders();
   
   // Store current parameters
   lastBaseLotSize = BaseLotSize;
   lastMultiplier = Multiplier;
   lastStepPoints = StepPoints;
   lastGridLevels = GridLevels;
   lastDirectionParam = Direction;
   
   // Set magic number for CTrade
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(Slippage);
   
   // Set filling mode - try different modes
   ENUM_ORDER_TYPE_FILLING fillingMode = ORDER_FILLING_FOK;
   if((SymbolInfoInteger(Symbol(), SYMBOL_FILLING_MODE) & SYMBOL_FILLING_FOK) != 0)
      fillingMode = ORDER_FILLING_FOK;
   else if((SymbolInfoInteger(Symbol(), SYMBOL_FILLING_MODE) & SYMBOL_FILLING_IOC) != 0)
      fillingMode = ORDER_FILLING_IOC;
   else
      fillingMode = ORDER_FILLING_RETURN;
   
   trade.SetTypeFilling(fillingMode);
   
   Print("Grid + Martingale EA initialized");
   Print("Symbol: ", Symbol());
   Print("Base Lot Size: ", BaseLotSize, " | Small: ", SmallLotSize, " | Risky: ", RiskyLotSize);
   Print("Dynamic Lot Sizing: ", (UseDynamicLotSizing ? "ON" : "OFF"));
   Print("Multiplier: ", Multiplier);
   Print("Step Points: ", StepPoints);
   Print("Grid Levels: ", GridLevels);
   Print("Take Profit: ", TakeProfitMoney, " ", AccountInfoString(ACCOUNT_CURRENCY));
   Print("Hedging Prevention: ", (PreventHedging ? "ON" : "OFF"));
   Print("Immediate Market Entry: ", (ImmediateMarketEntry ? "ON" : "OFF"));
   
   // Reset immediate entry flag on init
   immediateEntryExecuted = false;
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("Grid + Martingale EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Prevent rapid-fire orders within same second
   datetime currentTime = TimeCurrent();
   if(currentTime == lastOrderTime)
      return;
   
   // Count positions (market execution only - no pending orders)
   int positionCount = CountPositions();
   
   // Check basket take profit and profit protection
   double basketProfit = GetBasketProfit();
   
   // Update peak profit tracking
   if(basketProfit > peakBasketProfit)
   {
      peakBasketProfit = basketProfit;
   }
   
   // Reset peak if no positions
   if(positionCount == 0)
   {
      peakBasketProfit = 0.0;
      lockedProfitLevel = 0.0;
      breakEvenActivated = false;
      trailingStopLevel = 0.0;
      positionsFromOldParams = false;  // Reset when all positions closed
      progressiveExit1Done = false;
      progressiveExit2Done = false;
      currentBasketTP = 0.0;
   }
   
   // Hedging prevention: Only trade in one direction when PreventHedging is enabled
   
   // Calculate dynamic profit targets based on equity
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   // Calculate basket TP (equity-based or fixed)
   if(UseEquityBasedTP)
   {
      currentBasketTP = equity * (BasketTPPercent / 100.0);
      
      // Apply dynamic scaling based on basket size
      if(UseDynamicScaling && positionCount > 1)
      {
         double scalingBonus = (positionCount - 1) * ScalingFactor;
         currentBasketTP = currentBasketTP * (1.0 + scalingBonus);
      }
      
      // Apply volatility multiplier
      if(UseVolatilityAdaptiveTP)
      {
         double volatilityFactor = GetVolatilityFactor();
         currentBasketTP = currentBasketTP * (1.0 + (volatilityFactor * VolatilityMultiplier));
      }
      
      // Apply min/max limits
      currentBasketTP = MathMax(currentBasketTP, MinBasketTPCurrency);
      currentBasketTP = MathMin(currentBasketTP, MaxBasketTPCurrency);
   }
   else
   {
      currentBasketTP = TakeProfitMoney;
   }
   
   // Check profit protection systems
   if(positionCount > 0)
   {
      // 1. Individual Position TP (close winners early)
      if(UseIndividualTP)
      {
         ManageIndividualPositionTPs(equity);
      }
      
      // 2. Progressive Exits (close partial positions at milestones)
      if(UseProgressiveExits)
      {
         ManageProgressiveExits(basketProfit, equity, positionCount);
      }
      
      // 3. Maximum Adverse Excursion (MAE) Protection (equity-based)
      double maeThreshold = UseEquityBasedTP ? (equity * MAEThresholdPercent / 100.0) : -10.0;
      if(UseMAEProtection && basketProfit <= -MathAbs(maeThreshold))
      {
         Print("MAE Protection: Basket loss exceeded threshold (", DoubleToString(maeThreshold, 2), "). Closing all positions.");
         CloseAll();
         lastOrderTime = currentTime;
         return;
      }
      
      // 4. Profit Lock Protection (prevent reversal from peak)
      if(UseProfitLock && peakBasketProfit > 0)
      {
         double profitDrop = peakBasketProfit - basketProfit;
         double dropPercent = (profitDrop / peakBasketProfit) * 100.0;
         
         if(dropPercent >= MaxDrawdownFromPeak)
         {
            Print("Profit Lock: Profit dropped ", DoubleToString(dropPercent, 2), "% from peak. Closing to protect gains.");
            CloseAll();
            lastOrderTime = currentTime;
            return;
         }
         
         // Lock profit level
         if(lockedProfitLevel == 0.0 && basketProfit >= (peakBasketProfit * ProfitLockPercent / 100.0))
         {
            lockedProfitLevel = basketProfit * ProfitLockPercent / 100.0;
            Print("Profit Locked: ", DoubleToString(lockedProfitLevel, 2), " ", AccountInfoString(ACCOUNT_CURRENCY));
         }
      }
      
      // 5. Trailing Stop Protection (equity-based)
      double trailingStart = UseEquityBasedTP ? (equity * TrailingStartPercent / 100.0) : 2.0;
      if(UseTrailingStop && basketProfit >= trailingStart)
      {
         double trailingStep = UseEquityBasedTP ? (equity * TrailingStepPercent / 100.0) : 1.0;
         double newTrailingLevel = basketProfit - trailingStep;
         if(trailingStopLevel == 0.0 || newTrailingLevel > trailingStopLevel)
         {
            trailingStopLevel = newTrailingLevel;
         }
         
         if(basketProfit < trailingStopLevel)
         {
            Print("Trailing Stop: Profit dropped below trailing level. Closing to protect gains.");
            CloseAll();
            lastOrderTime = currentTime;
            return;
         }
      }
      
      // 6. Break-Even Protection (equity-based)
      double beTrigger = UseEquityBasedTP ? (equity * BreakEvenTriggerPercent / 100.0) : 1.0;
      if(UseBreakEven && !breakEvenActivated && basketProfit >= beTrigger)
      {
         if(MoveBasketToBreakEven())
         {
            breakEvenActivated = true;
            Print("Break-Even Protection: All positions moved to break-even.");
         }
      }
      
      // 7. Final Basket Take Profit Check (dynamic)
      if(basketProfit >= currentBasketTP)
      {
         Print("Basket Take Profit reached: ", DoubleToString(basketProfit, 2), " (Target: ", DoubleToString(currentBasketTP, 2), ")");
         CloseAll();
         lastOrderTime = currentTime;
         return;
      }
   }
   
   // Execute immediate market entry if enabled and no positions exist
   if(ImmediateMarketEntry && !immediateEntryExecuted && positionCount == 0 && !positionsFromOldParams)
   {
      ExecuteImmediateMarketEntry();
      immediateEntryExecuted = true;
      // Re-count positions after immediate entry
      positionCount = CountPositions();
   }
   
   // Check for direction change - execute pending orders if direction changed
   int currentPendingDirection = GetPendingOrdersDirection();
   if(currentPendingDirection != 0 && lastPendingDirection != 0 && currentPendingDirection != lastPendingDirection)
   {
      Print("Direction change detected! Executing pending orders before direction change.");
      ExecuteAllPendingOrders();
      lastPendingDirection = 0;
   }
   
   // Initialize grid with pending orders if no positions exist
   // But skip if we have positions from old parameters (wait for them to close)
   if(positionCount == 0 && !positionsFromOldParams)
   {
      int pendingCount = CountPendingOrders();
      if(pendingCount == 0)
      {
         InitializeGrid();
         lastPendingDirection = GetPendingOrdersDirection();
         lastOrderTime = currentTime;
      }
      else
      {
         // Maintain exactly 3 pending orders (only check every 10 ticks to avoid excessive calls)
         gridUpdateCounter++;
         if(gridUpdateCounter >= 10)
         {
            ManagePendingOrders();
            lastPendingDirection = GetPendingOrdersDirection();
            gridUpdateCounter = 0;
         }
      }
   }
   
   // Reset immediate entry flag when all positions close
   if(positionCount == 0)
   {
      immediateEntryExecuted = false;
   }
   
   // If we have positions from old parameters, don't add new trades
   if(positionsFromOldParams && positionCount > 0)
   {
      // Only manage existing positions, don't add new trades
      int pendingCount = CountPendingOrders();
      UpdateDisplay(basketProfit, positionCount, pendingCount);
      return;
   }
   
   // Check if we need to add more grid trades (martingale on losing positions)
   // But respect MaxBasketTrades limit
   if(positionCount > 0 && positionCount < MaxBasketTrades)
   {
      CheckAndAddMartingaleTrades();
   }
   
   // Manage individual position trailing stops
   if(positionCount > 0 && UseIndividualTrailing)
   {
      ManageIndividualTrailingStops();
   }
   
   // Update display
   int pendingCount = CountPendingOrders();
   UpdateDisplay(basketProfit, positionCount, pendingCount);
}

//+------------------------------------------------------------------+
//| Get total floating profit for all positions with this magic     |
//+------------------------------------------------------------------+
double GetBasketProfit()
{
   double totalProfit = 0.0;
   
   // Iterate through all positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            // Check if position belongs to this EA
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  totalProfit += PositionGetDouble(POSITION_PROFIT) + 
                                PositionGetDouble(POSITION_SWAP);
                  
                  // Get commission from deal history (POSITION_COMMISSION is deprecated)
                  double commission = GetPositionCommission(ticket);
                  totalProfit += commission;
               }
            }
         }
      }
   }
   
   return totalProfit;
}

//+------------------------------------------------------------------+
//| Get commission for a position from deal history                  |
//+------------------------------------------------------------------+
double GetPositionCommission(ulong positionTicket)
{
   double commission = 0.0;
   
   // Select position to get its deals
   if(PositionSelectByTicket(positionTicket))
   {
      datetime positionTime = (datetime)PositionGetInteger(POSITION_TIME);
      
      // Select deal history
      if(HistorySelect(positionTime, TimeCurrent()))
      {
         int totalDeals = HistoryDealsTotal();
         
         for(int i = 0; i < totalDeals; i++)
         {
            ulong dealTicket = HistoryDealGetTicket(i);
            if(dealTicket > 0)
            {
               if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) == Symbol())
               {
                  if(HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) == positionTicket)
                  {
                     commission += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
                  }
               }
            }
         }
      }
   }
   
   return commission;
}

//+------------------------------------------------------------------+
//| Count positions with this magic number                           |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  count++;
               }
            }
         }
      }
   }
   
   return count;
}

//+------------------------------------------------------------------+
//| Get the price of the last opened position                        |
//+------------------------------------------------------------------+
double GetLastPositionPrice()
{
   double lastPrice = 0.0;
   datetime lastTime = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
                  if(openTime > lastTime)
                  {
                     lastTime = openTime;
                     lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                  }
               }
            }
         }
      }
   }
   
   return lastPrice;
}

//+------------------------------------------------------------------+
//| Get the lot size of the last opened position                     |
//+------------------------------------------------------------------+
double GetLastLotSize()
{
   double lastLot = BaseLotSize;
   datetime lastTime = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
                  if(openTime > lastTime)
                  {
                     lastTime = openTime;
                     lastLot = PositionGetDouble(POSITION_VOLUME);
                  }
               }
            }
         }
      }
   }
   
   return lastLot;
}

//+------------------------------------------------------------------+
//| Open BUY position                                                |
//+------------------------------------------------------------------+
void OpenBuy(double lot)
{
   double price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double sl = 0;
   double tp = 0;
   
   string comment = CommentPrefix + "_BUY";
   
   // Normalize lot size
   double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   
   if(trade.Buy(lot, Symbol(), price, sl, tp, comment))
   {
      Print("BUY order opened: Lot=", lot, " Price=", price);
      lastDirection = 1;
      
      // Hedging prevention handled in grid logic (market execution only)
   }
   else
   {
      Print("BUY order failed: ", trade.ResultRetcodeDescription(), " (", trade.ResultRetcode(), ")");
   }
}

//+------------------------------------------------------------------+
//| Open SELL position                                              |
//+------------------------------------------------------------------+
void OpenSell(double lot)
{
   double price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double sl = 0;
   double tp = 0;
   
   string comment = CommentPrefix + "_SELL";
   
   // Normalize lot size
   double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   
   if(trade.Sell(lot, Symbol(), price, sl, tp, comment))
   {
      Print("SELL order opened: Lot=", lot, " Price=", price);
      lastDirection = -1;
      
      // Hedging prevention handled in grid logic (market execution only)
   }
   else
   {
      Print("SELL order failed: ", trade.ResultRetcodeDescription(), " (", trade.ResultRetcode(), ")");
   }
}

//+------------------------------------------------------------------+
//| Close all positions with this magic number                       |
//+------------------------------------------------------------------+
void CloseAll()
{
   int closedCount = 0;
   
   // Close all positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  if(trade.PositionClose(ticket))
                  {
                     closedCount++;
                     Print("Position closed: Ticket=", ticket);
                  }
                  else
                  {
                     Print("Failed to close position: Ticket=", ticket, " Error: ", trade.ResultRetcodeDescription());
                  }
               }
            }
         }
      }
   }
   
   Print("Closed ", closedCount, " positions. Basket profit: ", DoubleToString(GetBasketProfit(), 2));
}

//+------------------------------------------------------------------+
//| Move all positions to break-even                                |
//+------------------------------------------------------------------+
bool MoveBasketToBreakEven()
{
   bool allMoved = true;
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                  long posType = PositionGetInteger(POSITION_TYPE);
                  
                  // Calculate break-even price (entry price + spread)
                  double bePrice = openPrice;
                  double currentSL = PositionGetDouble(POSITION_SL);
                  double currentTP = PositionGetDouble(POSITION_TP);
                  
                  // Only move if current SL is worse than BE
                  bool needsMove = false;
                  if(posType == POSITION_TYPE_BUY)
                  {
                     if(currentSL == 0 || currentSL < bePrice)
                        needsMove = true;
                  }
                  else // SELL
                  {
                     if(currentSL == 0 || currentSL > bePrice)
                        needsMove = true;
                  }
                  
                  if(needsMove)
                  {
                     // Normalize BE price
                     bePrice = NormalizeDouble(bePrice, digits);
                     
                     if(trade.PositionModify(ticket, bePrice, currentTP))
                     {
                        Print("Position moved to BE: Ticket=", ticket, " BE Price=", bePrice);
                     }
                     else
                     {
                        Print("Failed to move position to BE: Ticket=", ticket, " Error: ", trade.ResultRetcodeDescription());
                        allMoved = false;
                     }
                  }
               }
            }
         }
      }
   }
   
   return allMoved;
}

//+------------------------------------------------------------------+
//| Manage individual position take profits (close winners early)    |
//+------------------------------------------------------------------+
void ManageIndividualPositionTPs(double equity)
{
   double individualTP = equity * (IndividualTPPercent / 100.0);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  double positionProfit = PositionGetDouble(POSITION_PROFIT);
                  double currentTP = PositionGetDouble(POSITION_TP);
                  double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                  long posType = PositionGetInteger(POSITION_TYPE);
                  double volume = PositionGetDouble(POSITION_VOLUME);
                  
                  // Only set TP if position is profitable and doesn't have TP set
                  if(positionProfit > 0 && currentTP == 0)
                  {
                     // Calculate TP price based on individual TP target
                     double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
                     double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
                     double contractSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_CONTRACT_SIZE);
                     
                     // Calculate how many points needed for individualTP profit
                     double pointsNeeded = 0.0;
                     if(tickValue > 0 && tickSize > 0 && volume > 0)
                     {
                        double valuePerPoint = (tickValue / tickSize) * point * volume * contractSize;
                        if(valuePerPoint > 0)
                           pointsNeeded = individualTP / valuePerPoint;
                     }
                     
                     // If calculation fails, use a percentage of entry price
                     if(pointsNeeded <= 0)
                     {
                        pointsNeeded = (openPrice * (IndividualTPPercent / 100.0)) / point;
                     }
                     
                     double tpPrice = 0.0;
                     if(posType == POSITION_TYPE_BUY)
                     {
                        tpPrice = NormalizeDouble(openPrice + (pointsNeeded * point), digits);
                     }
                     else // SELL
                     {
                        tpPrice = NormalizeDouble(openPrice - (pointsNeeded * point), digits);
                     }
                     
                     double currentSL = PositionGetDouble(POSITION_SL);
                     
                     if(trade.PositionModify(ticket, currentSL, tpPrice))
                     {
                        Print("Individual TP set: Ticket=", ticket, " TP=", tpPrice, " Target Profit=", DoubleToString(individualTP, 2));
                     }
                  }
                  // If TP is reached, close the position
                  else if(currentTP > 0)
                  {
                     double currentPrice = (posType == POSITION_TYPE_BUY) ? 
                                          SymbolInfoDouble(Symbol(), SYMBOL_BID) : 
                                          SymbolInfoDouble(Symbol(), SYMBOL_ASK);
                     
                     bool tpReached = false;
                     if(posType == POSITION_TYPE_BUY && currentPrice >= currentTP)
                        tpReached = true;
                     else if(posType == POSITION_TYPE_SELL && currentPrice <= currentTP)
                        tpReached = true;
                     
                     if(tpReached)
                     {
                        if(trade.PositionClose(ticket))
                        {
                           Print("Individual TP reached: Closed position Ticket=", ticket, " Profit=", DoubleToString(positionProfit, 2));
                        }
                     }
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage progressive exits (close partial positions at milestones)|
//+------------------------------------------------------------------+
void ManageProgressiveExits(double basketProfit, double equity, int positionCount)
{
   if(positionCount <= MinBasketTrades)
      return;  // Don't close if at minimum basket size
   
   double exit1Target = equity * (ProgressiveExit1Percent / 100.0);
   double exit2Target = equity * (ProgressiveExit2Percent / 100.0);
   
   // Exit 1: Close 25% of positions at first milestone, but maintain minimum
   if(!progressiveExit1Done && basketProfit >= exit1Target)
   {
      int positionsToClose = (int)MathMax(1, MathFloor(positionCount * 0.25));
      // Ensure we don't go below minimum
      if(MaintainMinBasketSize && (positionCount - positionsToClose) < MinBasketTrades)
      {
         positionsToClose = positionCount - MinBasketTrades;
      }
      
      if(positionsToClose > 0 && positionsToClose < positionCount)
      {
         ClosePartialPositions(positionsToClose, "Progressive Exit 1");
         progressiveExit1Done = true;
         Print("Progressive Exit 1: Closed ", positionsToClose, " positions at ", DoubleToString(exit1Target, 2), " (Remaining: ", positionCount - positionsToClose, ")");
      }
   }
   
   // Exit 2: Close another 25% at second milestone, but maintain minimum
   if(!progressiveExit2Done && basketProfit >= exit2Target)
   {
      int remainingPositions = CountPositions();
      if(remainingPositions > MinBasketTrades)
      {
         int positionsToClose = (int)MathMax(1, MathFloor(remainingPositions * 0.25));
         // Ensure we don't go below minimum
         if(MaintainMinBasketSize && (remainingPositions - positionsToClose) < MinBasketTrades)
         {
            positionsToClose = remainingPositions - MinBasketTrades;
         }
         
         if(positionsToClose > 0 && positionsToClose < remainingPositions)
         {
            ClosePartialPositions(positionsToClose, "Progressive Exit 2");
            progressiveExit2Done = true;
            Print("Progressive Exit 2: Closed ", positionsToClose, " positions at ", DoubleToString(exit2Target, 2), " (Remaining: ", remainingPositions - positionsToClose, ")");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close partial positions (most profitable first)                  |
//+------------------------------------------------------------------+
void ClosePartialPositions(int count, string reason)
{
   if(count <= 0)
      return;
   
   // Collect positions with their profits
   struct PositionInfo
   {
      ulong ticket;
      double profit;
   };
   
   PositionInfo positions[];
   ArrayResize(positions, 0);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  int size = ArraySize(positions);
                  ArrayResize(positions, size + 1);
                  positions[size].ticket = ticket;
                  positions[size].profit = PositionGetDouble(POSITION_PROFIT);
               }
            }
         }
      }
   }
   
   // Sort by profit (descending - most profitable first)
   for(int i = 0; i < ArraySize(positions) - 1; i++)
   {
      for(int j = i + 1; j < ArraySize(positions); j++)
      {
         if(positions[j].profit > positions[i].profit)
         {
            PositionInfo temp = positions[i];
            positions[i] = positions[j];
            positions[j] = temp;
         }
      }
   }
   
   // Close top N most profitable positions
   int closed = 0;
   for(int i = 0; i < MathMin(count, ArraySize(positions)); i++)
   {
      if(trade.PositionClose(positions[i].ticket))
      {
         closed++;
         Print(reason, ": Closed position Ticket=", positions[i].ticket, " Profit=", DoubleToString(positions[i].profit, 2));
      }
   }
}

//+------------------------------------------------------------------+
//| Get volatility factor for adaptive TP (0.0 to 1.0)              |
//+------------------------------------------------------------------+
double GetVolatilityFactor()
{
   int atrHandle = iATR(Symbol(), PERIOD_CURRENT, 14);
   if(atrHandle == INVALID_HANDLE)
      return 0.0;
   
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 0, 2, atr) < 2)
   {
      IndicatorRelease(atrHandle);
      return 0.0;
   }
   
   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(Symbol(), PERIOD_CURRENT, 0, 1, close) < 1)
   {
      IndicatorRelease(atrHandle);
      return 0.0;
   }
   
   // Calculate ATR as percentage of price
   double atrPercent = (atr[0] / close[0]) * 100.0;
   
   // Normalize to 0-1 range (assuming 0-2% ATR range)
   double volatilityFactor = MathMin(atrPercent / 2.0, 1.0);
   
   IndicatorRelease(atrHandle);
   return volatilityFactor;
}

//+------------------------------------------------------------------+
//| Manage individual position trailing stops                        |
//+------------------------------------------------------------------+
void ManageIndividualTrailingStops()
{
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   // Use StepPoints as trailing distance for individual positions
   double trailingStepPrice = StepPoints * point * 0.5;  // Trail by 50% of grid step
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                  double currentSL = PositionGetDouble(POSITION_SL);
                  double currentTP = PositionGetDouble(POSITION_TP);
                  long posType = PositionGetInteger(POSITION_TYPE);
                  
                  double currentPrice = (posType == POSITION_TYPE_BUY) ? 
                                        SymbolInfoDouble(Symbol(), SYMBOL_BID) : 
                                        SymbolInfoDouble(Symbol(), SYMBOL_ASK);
                  
                  double profit = PositionGetDouble(POSITION_PROFIT);
                  
                  // Only trail profitable positions
                  if(profit > 0)
                  {
                     double newSL = 0.0;
                     
                     if(posType == POSITION_TYPE_BUY)
                     {
                        // For BUY: SL should be below current price by trailing step
                        newSL = NormalizeDouble(currentPrice - trailingStepPrice, digits);
                        
                        // Only move SL up, never down
                        if(currentSL == 0 || newSL > currentSL)
                        {
                           if(trade.PositionModify(ticket, newSL, currentTP))
                           {
                              // Print("Trailing stop updated: BUY Ticket=", ticket, " New SL=", newSL);
                           }
                        }
                     }
                     else // SELL
                     {
                        // For SELL: SL should be above current price by trailing step
                        newSL = NormalizeDouble(currentPrice + trailingStepPrice, digits);
                        
                        // Only move SL down, never up
                        if(currentSL == 0 || newSL < currentSL || currentSL == 0)
                        {
                           if(trade.PositionModify(ticket, newSL, currentTP))
                           {
                              // Print("Trailing stop updated: SELL Ticket=", ticket, " New SL=", newSL);
                           }
                        }
                     }
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Execute any existing pending orders (convert to market exec)     |
//+------------------------------------------------------------------+
void ExecutePendingOrders()
{
   int executed = 0;
   int deleted = 0;
   
   // Check all orders in the order pool
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetInteger(ORDER_MAGIC) == Magic)
         {
            if(OrderGetString(ORDER_SYMBOL) == Symbol())
            {
               ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
               double orderLot = OrderGetDouble(ORDER_VOLUME);
               double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
               
               // Execute pending orders as market orders (only BUYSTOP/SELLSTOP, delete LIMIT orders)
               if(orderType == ORDER_TYPE_BUY_STOP)
               {
                  // Execute as market BUY
                  if(trade.Buy(orderLot, Symbol(), 0, 0, 0, "ExecutedPending_BUY"))
                  {
                     executed++;
                     Print("Executed pending BUYSTOP order: Ticket=", ticket, " Lot=", orderLot, " Original Price=", orderPrice);
                  }
                  // Delete the pending order
                  if(trade.OrderDelete(ticket))
                  {
                     deleted++;
                  }
               }
               else if(orderType == ORDER_TYPE_SELL_STOP)
               {
                  // Execute as market SELL
                  if(trade.Sell(orderLot, Symbol(), 0, 0, 0, "ExecutedPending_SELL"))
                  {
                     executed++;
                     Print("Executed pending SELLSTOP order: Ticket=", ticket, " Lot=", orderLot, " Original Price=", orderPrice);
                  }
                  // Delete the pending order
                  if(trade.OrderDelete(ticket))
                  {
                     deleted++;
                  }
               }
               else if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT)
               {
                  // Delete LIMIT orders (we don't use them)
                  if(trade.OrderDelete(ticket))
                  {
                     deleted++;
                     Print("Deleted LIMIT order: Ticket=", ticket, " (only BUYSTOP/SELLSTOP allowed)");
                  }
               }
            }
         }
      }
   }
   
   if(executed > 0)
   {
      Print("Executed ", executed, " pending orders as market orders. Deleted ", deleted, " pending orders.");
   }
}

//+------------------------------------------------------------------+
//| Initialize grid with pending orders (max 3)                      |
//+------------------------------------------------------------------+
void InitializeGrid()
{
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   
   // Check filters
   if(UseTrendFilter && !IsTrendFavorable())
   {
      Print("Trend filter: Waiting for favorable trend");
      return;
   }
   
   if(UseVolatilityFilter && !IsVolatilitySufficient())
   {
      Print("Volatility filter: Market too quiet");
      return;
   }
   
   // Determine entry direction
   int entryDirection = Direction;
   if(PreventHedging && Direction == 0)
   {
      entryDirection = lastDirection;
      if(entryDirection == 0)
         entryDirection = 1;  // Default to BUY
   }
   
   // Calculate TP in price (10+ pips)
   double tpPrice = 0.0;
   double tpPoints = MinTakeProfitPips * point;
   if(MinTakeProfitPips > 0)
   {
      tpPoints = MinTakeProfitPips * point;
   }
   
   // Place exactly 3 pending orders (STRICT LIMIT - always 3, never more)
   int maxPending = 3;
   
   if(entryDirection == 1)  // BUY - place BUYSTOP orders above current price
   {
      for(int i = 1; i <= maxPending; i++)
      {
         double gridPrice = ask + (StepPoints * point * i);
         double baseLot = CalculateDynamicLotSize(1);
         double lotSize = baseLot * MathPow(Multiplier, i - 1);
         tpPrice = NormalizeDouble(gridPrice + tpPoints, digits);
         
         string comment = CommentPrefix + "_BUY_L" + IntegerToString(i);
         if(trade.BuyStop(lotSize, gridPrice, Symbol(), 0, tpPrice, ORDER_TIME_GTC, 0, comment))
         {
            Print("BUYSTOP placed: Level ", i, " Price=", gridPrice, " Lot=", lotSize, " TP=", tpPrice, " (", MinTakeProfitPips, " pips)");
         }
         else
         {
            Print("BUYSTOP failed: ", trade.ResultRetcodeDescription());
         }
      }
      lastDirection = 1;
      lastPendingDirection = 1;
   }
   else if(entryDirection == -1)  // SELL - place SELLSTOP orders below current price
   {
      for(int i = 1; i <= maxPending; i++)
      {
         double gridPrice = bid - (StepPoints * point * i);
         double baseLot = CalculateDynamicLotSize(-1);
         double lotSize = baseLot * MathPow(Multiplier, i - 1);
         tpPrice = NormalizeDouble(gridPrice - tpPoints, digits);
         
         string comment = CommentPrefix + "_SELL_L" + IntegerToString(i);
         if(trade.SellStop(lotSize, gridPrice, Symbol(), 0, tpPrice, ORDER_TIME_GTC, 0, comment))
         {
            Print("SELLSTOP placed: Level ", i, " Price=", gridPrice, " Lot=", lotSize, " TP=", tpPrice, " (", MinTakeProfitPips, " pips)");
         }
         else
         {
            Print("SELLSTOP failed: ", trade.ResultRetcodeDescription());
         }
      }
      lastDirection = -1;
      lastPendingDirection = -1;
   }
   
   lastGridCenter = (ask + bid) / 2.0;
   Print("Grid initialized with ", maxPending, " pending orders (max 3)");
}

//+------------------------------------------------------------------+
//| Execute immediate market entry on EA load                        |
//+------------------------------------------------------------------+
void ExecuteImmediateMarketEntry()
{
   // Check filters unless we're ignoring them
   if(!ImmediateEntryIgnoreFilters)
   {
      if(UseTrendFilter && !IsTrendFavorable())
      {
         Print("Immediate entry: Trend filter blocked entry");
         return;
      }
      
      if(UseVolatilityFilter && !IsVolatilitySufficient())
      {
         Print("Immediate entry: Volatility filter blocked entry");
         return;
      }
   }
   
   // Determine entry direction
   int entryDirection = Direction;
   
   // If Direction=0 (both), use last direction or default to BUY
   if(Direction == 0)
   {
      entryDirection = lastDirection;
      if(entryDirection == 0)
         entryDirection = 1;  // Default to BUY
   }
   
   // Calculate dynamic lot size
   double lotSize = CalculateDynamicLotSize(entryDirection);
   
   // Execute immediate market order
   if(entryDirection == 1)
   {
      Print("Immediate Market Entry: Opening BUY position with lot=", lotSize);
      OpenBuy(lotSize);
   }
   else if(entryDirection == -1)
   {
      Print("Immediate Market Entry: Opening SELL position with lot=", lotSize);
      OpenSell(lotSize);
   }
   
   Print("Immediate market entry executed.");
}

//+------------------------------------------------------------------+
//| Check and add grid trades based on price movement (market exec)  |
//+------------------------------------------------------------------+
void CheckAndAddGridTrades()
{
   int positionCount = CountPositions();
   if(positionCount == 0 || positionCount >= MaxBasketTrades)
      return;
   
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double currentPrice = (ask + bid) / 2.0;
   
   // Get position direction and highest/lowest position price
   int posDirection = GetPositionDirection();
   if(posDirection == 0)
      return;
   
   // Prevent hedging: Only add trades in same direction if PreventHedging is enabled
   if(PreventHedging)
   {
      // Check Direction parameter
      if((posDirection == 1 && Direction == -1) || (posDirection == -1 && Direction == 1))
      {
         return;  // Direction parameter conflicts with existing positions
      }
   }
   
   // Get the furthest position price (for BUY: highest, for SELL: lowest)
   double furthestPrice = GetFurthestPositionPrice(posDirection);
   if(furthestPrice == 0.0)
      return;
   
   // Calculate price movement from furthest position (price moving AGAINST positions)
   double priceMove = 0.0;
   if(posDirection == 1)  // BUY positions - add when price moves DOWN (against us)
   {
      priceMove = furthestPrice - currentPrice;  // How much price moved down (against BUY)
   }
   else  // SELL positions - add when price moves UP (against us)
   {
      priceMove = currentPrice - furthestPrice;  // How much price moved up (against SELL)
   }
   
   // Check if price moved enough to add next grid level
   double gridStepPrice = StepPoints * point;
   int currentGridLevel = positionCount;  // Current number of positions = grid level
   
   // If price moved AGAINST positions by at least one grid step, add next position
   if(priceMove >= gridStepPrice && currentGridLevel < GridLevels)
   {
      // Calculate lot size for next grid level (martingale)
      double baseLot = CalculateDynamicLotSize(posDirection);
      double lotSize = baseLot * MathPow(Multiplier, currentGridLevel);
      
      // Execute market order
      if(posDirection == 1)
      {
         OpenBuy(lotSize);
         Print("Grid trade added: BUY Level ", currentGridLevel + 1, " Price moved: ", DoubleToString(priceMove / point, 0), " points");
      }
      else
      {
         OpenSell(lotSize);
         Print("Grid trade added: SELL Level ", currentGridLevel + 1, " Price moved: ", DoubleToString(priceMove / point, 0), " points");
      }
   }
}

//+------------------------------------------------------------------+
//| Get furthest position price (highest for BUY, lowest for SELL)  |
//+------------------------------------------------------------------+
double GetFurthestPositionPrice(int direction)
{
   double furthestPrice = 0.0;
   bool first = true;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  long posType = PositionGetInteger(POSITION_TYPE);
                  if((direction == 1 && posType == POSITION_TYPE_BUY) || 
                     (direction == -1 && posType == POSITION_TYPE_SELL))
                  {
                     double price = PositionGetDouble(POSITION_PRICE_OPEN);
                     if(first)
                     {
                        furthestPrice = price;
                        first = false;
                     }
                     else
                     {
                        if(direction == 1 && price > furthestPrice)
                           furthestPrice = price;  // BUY: highest price
                        else if(direction == -1 && price < furthestPrice)
                           furthestPrice = price;  // SELL: lowest price
                     }
                  }
               }
            }
         }
      }
   }
   
   return furthestPrice;
}

//+------------------------------------------------------------------+
//| Check and add martingale trades when positions are losing        |
//+------------------------------------------------------------------+
void CheckAndAddMartingaleTrades()
{
   int positionCount = CountPositions();
   if(positionCount == 0)
      return;
   
   // Don't add more trades if we're at max basket size
   if(positionCount >= MaxBasketTrades)
      return;
   
   // Get average position price and direction
   double avgPrice = GetAveragePositionPrice();
   int posDirection = GetPositionDirection();
   
   if(avgPrice == 0.0 || posDirection == 0)
      return;
   
   double currentPrice = (posDirection == 1) ? 
                         SymbolInfoDouble(Symbol(), SYMBOL_BID) : 
                         SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   
   // Calculate how far price moved against positions
   double priceDiff = 0.0;
   if(posDirection == 1)  // BUY positions
   {
      priceDiff = (avgPrice - currentPrice) / point;
   }
   else  // SELL positions
   {
      priceDiff = (currentPrice - avgPrice) / point;
   }
   
   // If price moved against by StepPoints, add martingale trade
   if(priceDiff >= StepPoints)
   {
      double totalLot = GetTotalLotSize();
      double baseLot = CalculateDynamicLotSize(posDirection);
      double newLot = (totalLot + baseLot) * Multiplier;
      
      // Execute market order if we haven't reached max basket size
      if(positionCount < MaxBasketTrades)
      {
         Print("Martingale: Price moved ", DoubleToString(priceDiff, 1), " points against. Adding trade: Lot=", newLot, " (Basket: ", positionCount, "/", MaxBasketTrades, ")");
         
         if(posDirection == 1)
         {
            OpenBuy(newLot);
         }
         else
         {
            OpenSell(newLot);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate dynamic lot size based on momentum and success probability |
//+------------------------------------------------------------------+
double CalculateDynamicLotSize(int direction)
{
   double lotSize = 0.0;
   double lotPercent = 0.0;
   
   // If percentage-based sizing is enabled
   if(UsePercentageLotSizing)
   {
      // If dynamic lot sizing is disabled, use base percent
      if(!UseDynamicLotSizing)
      {
         lotPercent = BaseLotPercent;
      }
      else
      {
         // Calculate momentum and success probability
         double momentum = CalculateMomentum(direction);
         double successProb = CalculateSuccessProbability(direction);
         
         // Combine momentum and success probability (weighted average)
         double combinedScore = (momentum * 0.6) + (successProb * 0.4);
         
         // Map to lot percentages
         if(combinedScore >= MomentumThreshold)
         {
            // High momentum/chance = Risky lot percent
            lotPercent = RiskyLotPercent;
         }
         else if(combinedScore <= MomentumLowThreshold)
         {
            // Low momentum/chance = Small lot percent
            lotPercent = SmallLotPercent;
         }
         else
         {
            // Medium = Base lot percent
            lotPercent = BaseLotPercent;
         }
      }
      
      // Calculate lot size from percentage of account balance
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmount = balance * lotPercent / 100.0;
      
      // Get contract specifications
      double contractSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_CONTRACT_SIZE);
      double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
      double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
      double currentPrice = (SymbolInfoDouble(Symbol(), SYMBOL_BID) + SymbolInfoDouble(Symbol(), SYMBOL_ASK)) / 2.0;
      
      // Calculate lot size: Use OrderCalcProfit to find lot size for target profit
      // We want riskAmount as the value, so we calculate backwards
      // For 1 standard lot, calculate value per point move
      double valuePerLotPerPoint = 0.0;
      
      if(tickValue > 0 && tickSize > 0 && point > 0)
      {
         // Value per lot per point = (tickValue / tickSize) * point * contractSize
         valuePerLotPerPoint = (tickValue / tickSize) * point;
         
         // For a 1% price move, how many points?
         double priceMove1Percent = currentPrice * 0.01;
         double pointsFor1Percent = priceMove1Percent / point;
         
         // Value of 1 lot for 1% move
         double valuePerLotFor1Percent = valuePerLotPerPoint * pointsFor1Percent;
         
         if(valuePerLotFor1Percent > 0)
         {
            // Calculate lot size: (RiskAmount / ValuePerLotFor1Percent) * (lotPercent / 1%)
            lotSize = (riskAmount / valuePerLotFor1Percent) * (lotPercent / 1.0);
         }
         else
         {
            // Fallback: use simple calculation
            lotSize = riskAmount / (currentPrice * contractSize * 0.01);
         }
      }
      else
      {
         // Fallback: simple calculation assuming 1% move
         lotSize = riskAmount / (currentPrice * contractSize * 0.01);
      }
   }
   else
   {
      // Fixed lot sizing (old method)
      if(!UseDynamicLotSizing)
      {
         lotSize = BaseLotSize;
      }
      else
      {
         // Calculate momentum and success probability
         double momentum = CalculateMomentum(direction);
         double successProb = CalculateSuccessProbability(direction);
         
         // Combine momentum and success probability (weighted average)
         double combinedScore = (momentum * 0.6) + (successProb * 0.4);
         
         // Map to lot sizes
         if(combinedScore >= MomentumThreshold)
         {
            lotSize = RiskyLotSize;
         }
         else if(combinedScore <= MomentumLowThreshold)
         {
            lotSize = SmallLotSize;
         }
         else
         {
            lotSize = BaseLotSize;
         }
      }
   }
   
   // Normalize lot size
   double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Calculate momentum score (0.0 to 1.0)                            |
//+------------------------------------------------------------------+
double CalculateMomentum(int direction)
{
   double momentum = 0.5;  // Default neutral
   
   // Get price change over momentum period
   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(Symbol(), PERIOD_CURRENT, 0, MomentumPeriod + 1, close) < MomentumPeriod + 1)
      return momentum;
   
   // Calculate price change
   double priceChange = 0.0;
   if(direction == 1)  // BUY - check upward momentum
   {
      priceChange = (close[0] - close[MomentumPeriod]) / close[MomentumPeriod];
   }
   else if(direction == -1)  // SELL - check downward momentum
   {
      priceChange = (close[MomentumPeriod] - close[0]) / close[MomentumPeriod];
   }
   
   // Normalize to 0-1 range (assuming max 5% move = full momentum)
   momentum = MathAbs(priceChange) / 0.05;
   momentum = MathMin(momentum, 1.0);
   momentum = MathMax(momentum, 0.0);
   
   // Add volatility factor if enabled
   if(UseVolatilityFactor)
   {
      int atrHandle = iATR(Symbol(), PERIOD_CURRENT, 14);
      if(atrHandle != INVALID_HANDLE)
      {
         double atr[];
         ArraySetAsSeries(atr, true);
         if(CopyBuffer(atrHandle, 0, 0, 1, atr) >= 1)
         {
            double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
            double normalizedATR = atr[0] / (close[0] * 0.01);  // ATR as % of price
            double volatilityBoost = MathMin(normalizedATR / 0.02, 0.3);  // Max 30% boost
            momentum += volatilityBoost;
            momentum = MathMin(momentum, 1.0);
         }
         IndicatorRelease(atrHandle);
      }
   }
   
   return momentum;
}

//+------------------------------------------------------------------+
//| Calculate success probability score (0.0 to 1.0)                |
//+------------------------------------------------------------------+
double CalculateSuccessProbability(int direction)
{
   double successProb = 0.5;  // Default neutral
   
   // Trend strength factor
   if(UseTrendStrength)
   {
      int emaHandle = iMA(Symbol(), PERIOD_CURRENT, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(emaHandle != INVALID_HANDLE)
      {
         double ema[];
         double close[];
         ArraySetAsSeries(ema, true);
         ArraySetAsSeries(close, true);
         
         if(CopyBuffer(emaHandle, 0, 0, 2, ema) >= 2 && CopyClose(Symbol(), PERIOD_CURRENT, 0, 2, close) >= 2)
         {
            bool trendUp = close[0] > ema[0] && close[1] > ema[1];
            bool trendDown = close[0] < ema[0] && close[1] < ema[1];
            
            if(direction == 1 && trendUp)
            {
               successProb = 0.7;  // Strong trend alignment for BUY
            }
            else if(direction == -1 && trendDown)
            {
               successProb = 0.7;  // Strong trend alignment for SELL
            }
            else if((direction == 1 && trendDown) || (direction == -1 && trendUp))
            {
               successProb = 0.3;  // Against trend
            }
            
            // Add momentum from EMA slope
            double emaSlope = (ema[0] - ema[1]) / ema[1];
            if((direction == 1 && emaSlope > 0) || (direction == -1 && emaSlope < 0))
            {
               successProb += MathAbs(emaSlope) * 10;  // Boost for strong EMA movement
               successProb = MathMin(successProb, 0.9);
            }
         }
         IndicatorRelease(emaHandle);
      }
   }
   
   // Spread factor (lower spread = higher success probability)
   double spread = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD) * SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double spreadPips = spread / point;
   
   if(spreadPips <= 2.0)
      successProb += 0.1;  // Low spread boost
   else if(spreadPips >= 5.0)
      successProb -= 0.1;  // High spread penalty
   
   successProb = MathMax(successProb, 0.0);
   successProb = MathMin(successProb, 1.0);
   
   return successProb;
}

//+------------------------------------------------------------------+
//| Check if trend is favorable for trading                          |
//+------------------------------------------------------------------+
bool IsTrendFavorable()
{
   double ema[];
   ArraySetAsSeries(ema, true);
   int handle = iMA(Symbol(), PERIOD_CURRENT, TrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   
   if(handle == INVALID_HANDLE)
      return true;  // If indicator fails, allow trading
   
   if(CopyBuffer(handle, 0, 0, 2, ema) < 2)
   {
      IndicatorRelease(handle);
      return true;
   }
   
   double currentPrice = (SymbolInfoDouble(Symbol(), SYMBOL_BID) + SymbolInfoDouble(Symbol(), SYMBOL_ASK)) / 2.0;
   bool isUptrend = currentPrice > ema[0];
   
   IndicatorRelease(handle);
   
   // If Direction=0 (both), always favorable
   if(Direction == 0)
      return true;
   
   // If Direction=1 (BUY only), favor uptrend
   if(Direction == 1)
      return isUptrend;
   
   // If Direction=-1 (SELL only), favor downtrend
   return !isUptrend;
}

//+------------------------------------------------------------------+
//| Check if volatility is sufficient                                |
//+------------------------------------------------------------------+
bool IsVolatilitySufficient()
{
   int handle = iATR(Symbol(), PERIOD_CURRENT, 14);
   if(handle == INVALID_HANDLE)
      return true;
   
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handle, 0, 0, 1, atr) < 1)
   {
      IndicatorRelease(handle);
      return true;
   }
   
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double minATR = StepPoints * point * MinATRMultiplier;
   bool sufficient = atr[0] >= minATR;
   
   IndicatorRelease(handle);
   return sufficient;
}

//+------------------------------------------------------------------+
//| Get the direction of existing positions (1=BUY, -1=SELL, 0=error) |
//+------------------------------------------------------------------+
int GetPositionDirection()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  long posType = PositionGetInteger(POSITION_TYPE);
                  if(posType == POSITION_TYPE_BUY)
                     return 1;
                  else if(posType == POSITION_TYPE_SELL)
                     return -1;
               }
            }
         }
      }
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Count pending orders with this magic number                      |
//+------------------------------------------------------------------+
int CountPendingOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetInteger(ORDER_MAGIC) == Magic)
         {
            if(OrderGetString(ORDER_SYMBOL) == Symbol())
            {
               ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
               // Only count BUYSTOP and SELLSTOP (LIMIT orders are deleted)
               if(orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP)
               {
                  count++;
               }
               // Delete any LIMIT orders found
               else if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT)
               {
                  trade.OrderDelete(ticket);
                  Print("Deleted LIMIT order during count: Ticket=", ticket);
               }
            }
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Get direction of pending orders (1=BUY, -1=SELL, 0=mixed/none)  |
//+------------------------------------------------------------------+
int GetPendingOrdersDirection()
{
   int buyCount = 0;
   int sellCount = 0;
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetInteger(ORDER_MAGIC) == Magic)
         {
            if(OrderGetString(ORDER_SYMBOL) == Symbol())
            {
               ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
               // Only check BUYSTOP and SELLSTOP (delete LIMIT orders)
               if(orderType == ORDER_TYPE_BUY_STOP)
                  buyCount++;
               else if(orderType == ORDER_TYPE_SELL_STOP)
                  sellCount++;
               else if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT)
               {
                  // Delete LIMIT orders
                  trade.OrderDelete(ticket);
                  Print("Deleted LIMIT order during direction check: Ticket=", ticket);
               }
            }
         }
      }
   }
   
   if(buyCount > 0 && sellCount == 0)
      return 1;  // BUY only
   else if(sellCount > 0 && buyCount == 0)
      return -1;  // SELL only
   else
      return 0;  // Mixed or none
}

//+------------------------------------------------------------------+
//| Execute all pending orders as market orders                      |
//+------------------------------------------------------------------+
void ExecuteAllPendingOrders()
{
   int executed = 0;
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetInteger(ORDER_MAGIC) == Magic)
         {
            if(OrderGetString(ORDER_SYMBOL) == Symbol())
            {
               ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
               double orderLot = OrderGetDouble(ORDER_VOLUME);
               double orderTP = OrderGetDouble(ORDER_TP);
               
               // Only execute BUYSTOP and SELLSTOP (delete LIMIT orders)
               if(orderType == ORDER_TYPE_BUY_STOP)
               {
                  if(trade.Buy(orderLot, Symbol(), 0, 0, orderTP, "ExecutedPending_BUY"))
                  {
                     executed++;
                     trade.OrderDelete(ticket);
                  }
               }
               else if(orderType == ORDER_TYPE_SELL_STOP)
               {
                  if(trade.Sell(orderLot, Symbol(), 0, 0, orderTP, "ExecutedPending_SELL"))
                  {
                     executed++;
                     trade.OrderDelete(ticket);
                  }
               }
               else if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT)
               {
                  // Delete LIMIT orders (we don't use them)
                  if(trade.OrderDelete(ticket))
                  {
                     Print("Deleted LIMIT order during execution: Ticket=", ticket);
                  }
               }
            }
         }
      }
   }
   
   if(executed > 0)
      Print("Executed ", executed, " pending orders due to direction change");
}

//+------------------------------------------------------------------+
//| Manage pending orders (maintain exactly 3)                       |
//+------------------------------------------------------------------+
void ManagePendingOrders()
{
   int pendingCount = CountPendingOrders();
   
   // STRICT LIMIT: If we have more than 3, delete ALL and recreate exactly 3
   if(pendingCount > 3)
   {
      Print("WARNING: Found ", pendingCount, " pending orders (max 3 allowed). Deleting all and recreating exactly 3.");
      
      // Delete ALL pending orders
      int deleted = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong ticket = OrderGetTicket(i);
         if(ticket > 0)
         {
            if(OrderGetInteger(ORDER_MAGIC) == Magic)
            {
               if(OrderGetString(ORDER_SYMBOL) == Symbol())
               {
                  ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
                  if(orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP || 
                     orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT)
                  {
                     if(trade.OrderDelete(ticket))
                        deleted++;
                  }
               }
            }
         }
      }
      
      Print("Deleted ", deleted, " pending orders. Recreating exactly 3.");
      
      // Recreate exactly 3 pending orders
      InitializeGrid();
      return;  // Exit after recreating
   }
   
   // If we have less than 3, add missing ones (STRICT LIMIT: never exceed 3)
   if(pendingCount < 3)
   {
      int toAdd = 3 - pendingCount;  // Calculate how many to add
      int currentPendingDir = GetPendingOrdersDirection();
      
      // If no pending orders, initialize grid (will create exactly 3)
      if(currentPendingDir == 0)
      {
         InitializeGrid();
         return;  // Exit after initialization
      }
      else
      {
         // Add missing orders in same direction (but check count after each addition)
         double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
         double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
         double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
         int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
         double tpPoints = MinTakeProfitPips * point;
         
         // Find highest BUY or lowest SELL price
         double highestPrice = 0.0;
         double lowestPrice = 0.0;
         bool first = true;
         
         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            ulong ticket = OrderGetTicket(i);
            if(ticket > 0)
            {
               if(OrderGetInteger(ORDER_MAGIC) == Magic)
               {
                  if(OrderGetString(ORDER_SYMBOL) == Symbol())
                  {
                     ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
                     // Only process BUYSTOP and SELLSTOP (delete LIMIT orders)
                     if(orderType == ORDER_TYPE_BUY_STOP)
                     {
                        double price = OrderGetDouble(ORDER_PRICE_OPEN);
                        if(first || price > highestPrice)
                        {
                           highestPrice = price;
                           first = false;
                        }
                     }
                     else if(orderType == ORDER_TYPE_SELL_STOP)
                     {
                        double price = OrderGetDouble(ORDER_PRICE_OPEN);
                        if(first || price < lowestPrice || lowestPrice == 0)
                        {
                           lowestPrice = price;
                           first = false;
                        }
                     }
                     else if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT)
                     {
                        // Delete LIMIT orders
                        trade.OrderDelete(ticket);
                        Print("Deleted LIMIT order during price search: Ticket=", ticket);
                     }
                  }
               }
            }
         }
         
         // Add orders one by one, checking count after each to ensure we never exceed 3
         int added = 0;
         if(currentPendingDir == 1)  // BUY
         {
            double startPrice = (highestPrice > 0) ? highestPrice : ask;
            for(int i = 1; i <= toAdd && added < toAdd; i++)
            {
               // Re-check count before adding each order
               int currentCount = CountPendingOrders();
               if(currentCount >= 3)
                  break;  // Stop if we already have 3
               
               double gridPrice = startPrice + (StepPoints * point * i);
               double baseLot = CalculateDynamicLotSize(1);
               double lotSize = baseLot * MathPow(Multiplier, pendingCount + i - 1);
               double tpPrice = NormalizeDouble(gridPrice + tpPoints, digits);
               
               string comment = CommentPrefix + "_BUY_L" + IntegerToString(pendingCount + i);
               if(trade.BuyStop(lotSize, gridPrice, Symbol(), 0, tpPrice, ORDER_TIME_GTC, 0, comment))
               {
                  added++;
                  Print("Added BUYSTOP order ", added, "/", toAdd, " - Total pending: ", currentCount + 1);
               }
            }
         }
         else if(currentPendingDir == -1)  // SELL
         {
            double startPrice = (lowestPrice > 0) ? lowestPrice : bid;
            for(int i = 1; i <= toAdd && added < toAdd; i++)
            {
               // Re-check count before adding each order
               int currentCount = CountPendingOrders();
               if(currentCount >= 3)
                  break;  // Stop if we already have 3
               
               double gridPrice = startPrice - (StepPoints * point * i);
               double baseLot = CalculateDynamicLotSize(-1);
               double lotSize = baseLot * MathPow(Multiplier, pendingCount + i - 1);
               double tpPrice = NormalizeDouble(gridPrice - tpPoints, digits);
               
               string comment = CommentPrefix + "_SELL_L" + IntegerToString(pendingCount + i);
               if(trade.SellStop(lotSize, gridPrice, Symbol(), 0, tpPrice, ORDER_TIME_GTC, 0, comment))
               {
                  added++;
                  Print("Added SELLSTOP order ", added, "/", toAdd, " - Total pending: ", currentCount + 1);
               }
            }
         }
      }
   }
   
   // Update last pending direction
   lastPendingDirection = GetPendingOrdersDirection();
}

//+------------------------------------------------------------------+
//| Get average position price                                       |
//+------------------------------------------------------------------+
double GetAveragePositionPrice()
{
   double totalVolume = 0.0;
   double weightedPrice = 0.0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  double volume = PositionGetDouble(POSITION_VOLUME);
                  double price = PositionGetDouble(POSITION_PRICE_OPEN);
                  weightedPrice += price * volume;
                  totalVolume += volume;
               }
            }
         }
      }
   }
   
   if(totalVolume > 0)
      return weightedPrice / totalVolume;
   
   return 0.0;
}

//+------------------------------------------------------------------+
//| Get total lot size of all positions                              |
//+------------------------------------------------------------------+
double GetTotalLotSize()
{
   double total = 0.0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == Magic)
            {
               if(PositionGetString(POSITION_SYMBOL) == Symbol())
               {
                  total += PositionGetDouble(POSITION_VOLUME);
               }
            }
         }
      }
   }
   
   return total;
}

//+------------------------------------------------------------------+
//| Update display on chart                                          |
//+------------------------------------------------------------------+
void UpdateDisplay(double basketProfit, int positionCount, int pendingCount)
{
   string info = "\n=== Smart Grid + Martingale EA ===\n";
   info += "Magic: " + IntegerToString(Magic) + "\n";
   info += "Positions: " + IntegerToString(positionCount) + "/" + IntegerToString(MaxBasketTrades) + "\n";
   info += "Pending: " + IntegerToString(pendingCount) + "/3 (max)\n";
   info += "Basket Profit: " + DoubleToString(basketProfit, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + "\n";
   
   // Show dynamic TP target
   if(UseEquityBasedTP && currentBasketTP > 0)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double tpPercent = (currentBasketTP / equity) * 100.0;
      info += "Target: " + DoubleToString(currentBasketTP, 2) + " (" + DoubleToString(tpPercent, 2) + "% equity)\n";
   }
   else
   {
      info += "Target: " + DoubleToString(TakeProfitMoney, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + "\n";
   }
   
   if(positionCount > 0)
   {
      double avgPrice = GetAveragePositionPrice();
      double totalLot = GetTotalLotSize();
      int posDir = GetPositionDirection();
      string dirStr = (posDir == 1) ? "BUY" : "SELL";
      
      info += "Avg Price: " + DoubleToString(avgPrice, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)) + "\n";
      info += "Total Lot: " + DoubleToString(totalLot, 2) + "\n";
      info += "Direction: " + dirStr + "\n";
      
      // Show protection status
      if(peakBasketProfit > 0)
      {
         double equity = AccountInfoDouble(ACCOUNT_EQUITY);
         double peakPercent = (peakBasketProfit / equity) * 100.0;
         info += "Peak: " + DoubleToString(peakBasketProfit, 2) + " (" + DoubleToString(peakPercent, 2) + "%)\n";
         if(lockedProfitLevel > 0)
            info += "Locked: " + DoubleToString(lockedProfitLevel, 2) + "\n";
      }
      if(trailingStopLevel > 0)
         info += "Trailing SL: " + DoubleToString(trailingStopLevel, 2) + "\n";
      if(breakEvenActivated)
         info += "Break-Even: ACTIVE\n";
      if(UseProgressiveExits)
      {
         if(progressiveExit1Done)
            info += "Exit 1: DONE\n";
         if(progressiveExit2Done)
            info += "Exit 2: DONE\n";
      }
      if(UseIndividualTP)
      {
         double equity = AccountInfoDouble(ACCOUNT_EQUITY);
         double individualTP = equity * (IndividualTPPercent / 100.0);
         info += "Individual TP: " + DoubleToString(individualTP, 2) + " per position\n";
      }
   }
   
   // Show hedging prevention status
   if(PreventHedging)
   {
      info += "Hedging Prevention: ON\n";
   }
   
   // Show immediate entry status
   if(ImmediateMarketEntry)
   {
      info += "Immediate Entry: " + (immediateEntryExecuted ? "EXECUTED" : "PENDING") + "\n";
   }
   
   // Show parameter change status
   if(positionsFromOldParams)
   {
      info += "WARNING: Positions from old parameters!\n";
      info += "New params apply after positions close\n";
   }
   
   Comment(info);
}

//+------------------------------------------------------------------+

