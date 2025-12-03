//+------------------------------------------------------------------+
//|                                            ea_grid_mt5_v2.mq5 |
//|              Advanced Grid + Martingale EA V2 - Next Generation |
//|                  ATR-Based Dynamic Grid | Market Structure | AI |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      ""
#property version   "2.00"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS - V2 Advanced Settings                          |
//+------------------------------------------------------------------+
input group "===== Core Trading Settings ====="
input double   RiskPercent = 2.0;        // Risk per trade as % of equity
input double   BaseLotSize = 0.01;       // Base lot size (fallback)
input double   Multiplier = 1.5;         // Martingale multiplier (reduced from 2.0)
input int      MinBasketTrades = 1;      // Minimum trades in basket
input int      MaxBasketTrades = 5;       // Maximum trades in basket
input ulong    Magic = 888;              // Magic number (different from V1)
input int      Direction = 0;            // 1=BUY, -1=SELL, 0=Auto (market structure)

input group "===== ATR-Based Dynamic Grid (V2 Innovation) ====="
input bool     UseATRGrid = true;        // Use ATR for grid spacing (dynamic)
input double   ATRMultiplier = 1.5;      // Grid spacing = ATR * this multiplier
input int      ATRPeriod = 14;           // ATR period
input int      GridLevels = 4;           // Number of grid levels each side
input int      FallbackStepPoints = 300; // Fallback if ATR unavailable

input group "===== Market Structure Analysis (V2 Innovation) ====="
input bool     UseMarketStructure = true; // Analyze swing highs/lows
input int      SwingLookback = 20;      // Bars to look back for swings
input bool     UseSupportResistance = true; // Use S/R levels for entries
input int      SRLevels = 3;             // Number of S/R levels to track
input bool     TradeWithTrend = true;    // Only trade in trend direction

input group "===== Multi-Timeframe Analysis (V2 Innovation) ====="
input bool     UseMultiTimeframe = true; // Confirm with higher timeframe
input ENUM_TIMEFRAMES HigherTF = PERIOD_H1; // Higher timeframe for confirmation
input bool     RequireHTFTrend = true;   // Require higher TF trend alignment

input group "===== Market Regime Detection (V2 Innovation) ====="
input bool     UseRegimeDetection = true; // Detect trending vs ranging
input int      RegimePeriod = 50;       // Period for regime detection
input double   TrendThreshold = 0.6;    // Threshold for trending market
input bool     OnlyTradeTrending = false; // Only trade in trending markets

input group "===== Advanced Profit System V2 ====="
input bool     UseEquityBasedTP = true; // Equity-based profit targets
input double   BasketTPPercent = 2.5;    // Basket TP as % of equity (increased)
input double   MinBasketTP = 25.0;      // Minimum basket TP
input double   MaxBasketTP = 1000.0;    // Maximum basket TP
input bool     UseATRTrailing = true;   // ATR-based trailing stop
input double   ATRTrailingMultiplier = 2.0; // Trailing distance in ATR
input bool     UseSmartExits = true;    // Exit at S/R levels
input bool     UsePartialExits = true;  // Partial exits at milestones
input double   PartialExit1Percent = 1.0; // Close 30% at this profit %
input double   PartialExit2Percent = 1.8; // Close 30% at this profit %

input group "===== Intelligent Recovery System (V2 Innovation) ====="
input bool     UseSmartRecovery = true; // Smart recovery (not just martingale)
input double   RecoveryThreshold = -0.5; // Start recovery at this % loss
input double   RecoveryLotMultiplier = 1.3; // Recovery lot multiplier (lower than martingale)
input int      MaxRecoveryTrades = 3;   // Max recovery trades per basket
input bool     UseAdaptiveRecovery = true; // Adapt recovery based on market conditions

input group "===== Risk Management V2 ====="
input double   MaxDrawdownPercent = 10.0; // Max drawdown % before stop
input double   DailyLossLimit = 5.0;     // Daily loss limit % of equity
input bool     UsePositionSizing = true; // Adaptive position sizing
input double   MaxRiskPerTrade = 3.0;    // Max risk % per trade
input bool     UseCorrelationFilter = false; // Filter correlated pairs (future)
input bool     PreventHedging = true;    // Cancel opposite orders when position opens

//--- Global Variables
CTrade trade;
int atrHandle = INVALID_HANDLE;
int emaFastHandle = INVALID_HANDLE;
int emaSlowHandle = INVALID_HANDLE;
int rsiHandle = INVALID_HANDLE;

// Market Structure
struct SwingPoint
{
   double price;
   datetime time;
   int type;  // 1=High, -1=Low
   bool valid;
};

SwingPoint swingPoints[];
double supportLevels[];
double resistanceLevels[];

// Market Regime
enum MARKET_REGIME
{
   REGIME_TRENDING_UP,
   REGIME_TRENDING_DOWN,
   REGIME_RANGING
};

MARKET_REGIME currentRegime = REGIME_RANGING;

// Basket Management
double peakBasketProfit = 0.0;
double basketEntryPrice = 0.0;
int basketDirection = 0;
datetime basketStartTime = 0;
int recoveryTradesCount = 0;
double dailyStartEquity = 0.0;
double dailyProfit = 0.0;

// Progressive Exits
bool partialExit1Done = false;
bool partialExit2Done = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("========================================");
   Print("Grid + Martingale EA V2.00 Initialized");
   Print("Advanced Features: ATR Grid | Market Structure | Multi-TF");
   Print("========================================");
   
   // Initialize indicators
   atrHandle = iATR(Symbol(), PERIOD_CURRENT, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR indicator");
      return(INIT_FAILED);
   }
   
   if(UseMultiTimeframe)
   {
      emaFastHandle = iMA(Symbol(), HigherTF, 20, 0, MODE_EMA, PRICE_CLOSE);
      emaSlowHandle = iMA(Symbol(), HigherTF, 50, 0, MODE_EMA, PRICE_CLOSE);
      rsiHandle = iRSI(Symbol(), HigherTF, 14, PRICE_CLOSE);
      
      if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
      {
         Print("WARNING: Failed to create MTF indicators, continuing without MTF");
      }
   }
   
   // Initialize arrays
   ArrayResize(swingPoints, SwingLookback * 2);
   ArrayResize(supportLevels, SRLevels);
   ArrayResize(resistanceLevels, SRLevels);
   ArrayInitialize(supportLevels, 0.0);
   ArrayInitialize(resistanceLevels, 0.0);
   
   // Initialize daily tracking
   dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Set trade parameters
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(10);
   
   // Set filling mode
   ENUM_ORDER_TYPE_FILLING fillingMode = ORDER_FILLING_FOK;
   if(SymbolInfoInteger(Symbol(), SYMBOL_FILLING_MODE) & SYMBOL_FILLING_FOK)
      fillingMode = ORDER_FILLING_FOK;
   else if(SymbolInfoInteger(Symbol(), SYMBOL_FILLING_MODE) & SYMBOL_FILLING_IOC)
      fillingMode = ORDER_FILLING_IOC;
   else
      fillingMode = ORDER_FILLING_RETURN;
   
   trade.SetTypeFilling(fillingMode);
   
   Print("Symbol: ", Symbol());
   Print("Risk Per Trade: ", RiskPercent, "%");
   Print("ATR Grid: ", (UseATRGrid ? "ON" : "OFF"));
   Print("Market Structure: ", (UseMarketStructure ? "ON" : "OFF"));
   Print("Multi-Timeframe: ", (UseMultiTimeframe ? "ON" : "OFF"));
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicators
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   if(emaFastHandle != INVALID_HANDLE)
      IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE)
      IndicatorRelease(emaSlowHandle);
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
   
   Print("Grid + Martingale EA V2.00 Deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Update daily tracking
   UpdateDailyTracking();
   
   // Check risk limits
   if(!CheckRiskLimits())
      return;
   
   // Count positions
   int positionCount = CountPositions();
   double basketProfit = GetBasketProfit();
   
   // Update peak profit
   if(basketProfit > peakBasketProfit)
      peakBasketProfit = basketProfit;
   
   // Reset if no positions
   if(positionCount == 0)
   {
      ResetBasketState();
   }
   
   // Update market structure
   if(UseMarketStructure)
   {
      UpdateMarketStructure();
   }
   
   // Detect market regime
   if(UseRegimeDetection)
   {
      DetectMarketRegime();
   }
   
   // Manage existing positions
   if(positionCount > 0)
   {
      // Check profit protection
      ManageProfitProtection(basketProfit, positionCount);
      
      // Smart recovery if needed
      if(UseSmartRecovery && positionCount < MaxBasketTrades)
      {
         CheckSmartRecovery(basketProfit);
      }
      
      // ATR-based trailing stops
      if(UseATRTrailing)
      {
         ManageATRTrailingStops();
      }
      
      // Smart exits at S/R levels
      if(UseSmartExits)
      {
         CheckSmartExits();
      }
   }
   
   // Initialize or manage grid
   if(positionCount == 0)
   {
      // Determine direction
      int tradeDirection = DetermineTradeDirection();
      
      if(tradeDirection != 0)
      {
         InitializeSmartGrid(tradeDirection);
      }
   }
   else if(positionCount < MaxBasketTrades)
   {
      // Maintain grid
      MaintainGrid();
   }
   
   // Update display
   UpdateDisplay(basketProfit, positionCount);
}

//+------------------------------------------------------------------+
//| Determine trade direction using market structure and MTF        |
//+------------------------------------------------------------------+
int DetermineTradeDirection()
{
   // If Direction is set manually, use it
   if(Direction != 0)
      return Direction;
   
   // Use market structure to determine direction
   if(UseMarketStructure)
   {
      int structureDirection = GetMarketStructureDirection();
      if(structureDirection != 0)
         return structureDirection;
   }
   
   // Use multi-timeframe trend
   if(UseMultiTimeframe && RequireHTFTrend)
   {
      int mtfDirection = GetMTFTrendDirection();
      if(mtfDirection != 0)
         return mtfDirection;
   }
   
   // Use market regime
   if(UseRegimeDetection && OnlyTradeTrending)
   {
      if(currentRegime == REGIME_TRENDING_UP)
         return 1;
      else if(currentRegime == REGIME_TRENDING_DOWN)
         return -1;
   }
   
   // Default: use current trend
   return GetCurrentTrendDirection();
}

//+------------------------------------------------------------------+
//| Get market structure direction                                   |
//+------------------------------------------------------------------+
int GetMarketStructureDirection()
{
   // Analyze swing points to determine structure
   int swingCount = ArraySize(swingPoints);
   if(swingCount < 4)
      return 0;
   
   // Find recent swing high and low
   double recentHigh = 0.0;
   double recentLow = DBL_MAX;
   datetime recentHighTime = 0;
   datetime recentLowTime = 0;
   
   for(int i = 0; i < swingCount; i++)
   {
      if(swingPoints[i].valid)
      {
         if(swingPoints[i].type == 1 && swingPoints[i].price > recentHigh)
         {
            recentHigh = swingPoints[i].price;
            recentHighTime = swingPoints[i].time;
         }
         if(swingPoints[i].type == -1 && swingPoints[i].price < recentLow)
         {
            recentLow = swingPoints[i].price;
            recentLowTime = swingPoints[i].time;
         }
      }
   }
   
   if(recentHigh == 0.0 || recentLow == DBL_MAX)
      return 0;
   
   // Higher highs and higher lows = uptrend
   // Lower highs and lower lows = downtrend
   double currentPrice = (SymbolInfoDouble(Symbol(), SYMBOL_BID) + SymbolInfoDouble(Symbol(), SYMBOL_ASK)) / 2.0;
   
   // Simple logic: if price above recent swing high, bullish
   // If price below recent swing low, bearish
   if(currentPrice > recentHigh * 0.999)  // Near or above high
      return 1;
   else if(currentPrice < recentLow * 1.001)  // Near or below low
      return -1;
   
   return 0;
}

//+------------------------------------------------------------------+
//| Get multi-timeframe trend direction                              |
//+------------------------------------------------------------------+
int GetMTFTrendDirection()
{
   if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE)
      return 0;
   
   double emaFast[], emaSlow[], rsi[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(rsi, true);
   
   if(CopyBuffer(emaFastHandle, 0, 0, 2, emaFast) < 2)
      return 0;
   if(CopyBuffer(emaSlowHandle, 0, 0, 2, emaSlow) < 2)
      return 0;
   if(rsiHandle != INVALID_HANDLE && CopyBuffer(rsiHandle, 0, 0, 1, rsi) < 1)
      return 0;
   
   // Uptrend: Fast EMA above Slow EMA
   if(emaFast[0] > emaSlow[0] && emaFast[1] > emaSlow[1])
   {
      // Additional confirmation with RSI
      if(rsiHandle != INVALID_HANDLE)
      {
         if(rsi[0] > 50)
            return 1;
      }
      else
         return 1;
   }
   
   // Downtrend: Fast EMA below Slow EMA
   if(emaFast[0] < emaSlow[0] && emaFast[1] < emaSlow[1])
   {
      if(rsiHandle != INVALID_HANDLE)
      {
         if(rsi[0] < 50)
            return -1;
      }
      else
         return -1;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Get current trend direction (simple EMA)                         |
//+------------------------------------------------------------------+
int GetCurrentTrendDirection()
{
   int emaHandle = iMA(Symbol(), PERIOD_CURRENT, 20, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE)
      return 0;
   
   double ema[], close[];
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(close, true);
   
   if(CopyBuffer(emaHandle, 0, 0, 1, ema) < 1)
   {
      IndicatorRelease(emaHandle);
      return 0;
   }
   if(CopyClose(Symbol(), PERIOD_CURRENT, 0, 1, close) < 1)
   {
      IndicatorRelease(emaHandle);
      return 0;
   }
   
   IndicatorRelease(emaHandle);
   
   if(close[0] > ema[0])
      return 1;
   else if(close[0] < ema[0])
      return -1;
   
   return 0;
}

//+------------------------------------------------------------------+
//| Update market structure (swing highs/lows)                       |
//+------------------------------------------------------------------+
void UpdateMarketStructure()
{
   // This is a simplified version - in production, use more sophisticated swing detection
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int bars = SwingLookback * 2;
   if(CopyHigh(Symbol(), PERIOD_CURRENT, 0, bars, high) < bars)
      return;
   if(CopyLow(Symbol(), PERIOD_CURRENT, 0, bars, low) < bars)
      return;
   if(CopyClose(Symbol(), PERIOD_CURRENT, 0, bars, close) < bars)
      return;
   
   // Find swing highs and lows
   int swingIndex = 0;
   for(int i = SwingLookback; i < bars - SwingLookback; i++)
   {
      // Check for swing high
      bool isSwingHigh = true;
      bool isSwingLow = true;
      
      for(int j = i - SwingLookback; j <= i + SwingLookback; j++)
      {
         if(j != i)
         {
            if(high[i] <= high[j])
               isSwingHigh = false;
            if(low[i] >= low[j])
               isSwingLow = false;
         }
      }
      
      if(isSwingHigh && swingIndex < ArraySize(swingPoints))
      {
         swingPoints[swingIndex].price = high[i];
         swingPoints[swingIndex].time = iTime(Symbol(), PERIOD_CURRENT, i);
         swingPoints[swingIndex].type = 1;
         swingPoints[swingIndex].valid = true;
         swingIndex++;
      }
      else if(isSwingLow && swingIndex < ArraySize(swingPoints))
      {
         swingPoints[swingIndex].price = low[i];
         swingPoints[swingIndex].time = iTime(Symbol(), PERIOD_CURRENT, i);
         swingPoints[swingIndex].type = -1;
         swingPoints[swingIndex].valid = true;
         swingIndex++;
      }
   }
   
   // Update support/resistance levels
   UpdateSupportResistanceLevels();
}

//+------------------------------------------------------------------+
//| Update support and resistance levels                             |
//+------------------------------------------------------------------+
void UpdateSupportResistanceLevels()
{
   // Sort swing points by price
   int swingCount = 0;
   double swingPrices[];
   ArrayResize(swingPrices, ArraySize(swingPoints));
   
   for(int i = 0; i < ArraySize(swingPoints); i++)
   {
      if(swingPoints[i].valid)
      {
         swingPrices[swingCount] = swingPoints[i].price;
         swingCount++;
      }
   }
   
   if(swingCount < 2)
      return;
   
   // Sort prices (ascending) - use manual sort for MQL5 compatibility
   for(int i = 0; i < swingCount - 1; i++)
   {
      for(int j = i + 1; j < swingCount; j++)
      {
         if(swingPrices[j] < swingPrices[i])
         {
            double temp = swingPrices[i];
            swingPrices[i] = swingPrices[j];
            swingPrices[j] = temp;
         }
      }
   }
   
   // Get resistance levels (highest prices)
   int resistanceCount = MathMin(SRLevels, swingCount / 2);
   for(int i = 0; i < resistanceCount; i++)
   {
      resistanceLevels[i] = swingPrices[swingCount - 1 - i];
   }
   
   // Get support levels (lowest prices)
   for(int i = 0; i < resistanceCount; i++)
   {
      supportLevels[i] = swingPrices[i];
   }
}

//+------------------------------------------------------------------+
//| Detect market regime (trending vs ranging)                       |
//+------------------------------------------------------------------+
void DetectMarketRegime()
{
   double close[];
   ArraySetAsSeries(close, true);
   
   if(CopyClose(Symbol(), PERIOD_CURRENT, 0, RegimePeriod, close) < RegimePeriod)
      return;
   
   // Calculate linear regression slope
   double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
   for(int i = 0; i < RegimePeriod; i++)
   {
      sumX += i;
      sumY += close[i];
      sumXY += i * close[i];
      sumX2 += i * i;
   }
   
   double slope = (RegimePeriod * sumXY - sumX * sumY) / (RegimePeriod * sumX2 - sumX * sumX);
   double avgPrice = sumY / RegimePeriod;
   
   // Normalize slope
   double normalizedSlope = MathAbs(slope / avgPrice);
   
   if(normalizedSlope > TrendThreshold)
   {
      if(slope > 0)
         currentRegime = REGIME_TRENDING_UP;
      else
         currentRegime = REGIME_TRENDING_DOWN;
   }
   else
   {
      currentRegime = REGIME_RANGING;
   }
}

//+------------------------------------------------------------------+
//| Initialize smart grid with ATR-based spacing                     |
//+------------------------------------------------------------------+
void InitializeSmartGrid(int direction)
{
   double atr = GetCurrentATR();
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double gridSpacing = 0.0;
   
   if(UseATRGrid && atr > 0)
   {
      gridSpacing = atr * ATRMultiplier;
      Print("ATR Grid: Spacing = ", DoubleToString(gridSpacing / point, 1), " points (ATR=", DoubleToString(atr, 5), ")");
   }
   else
   {
      gridSpacing = FallbackStepPoints * point;
      Print("Using fallback grid spacing: ", FallbackStepPoints, " points");
   }
   
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   // Calculate lot size based on risk
   double lotSize = CalculatePositionSize(RiskPercent);
   
   // Place grid orders
   if(direction == 1 || direction == 0)  // BUY
   {
      PlaceBuyGridATR(ask, gridSpacing, lotSize);
   }
   
   if(direction == -1 || direction == 0)  // SELL
   {
      PlaceSellGridATR(bid, gridSpacing, lotSize);
   }
   
   basketDirection = direction;
   basketEntryPrice = currentPrice;
   basketStartTime = TimeCurrent();
   
   Print("Smart Grid Initialized: Direction=", (direction == 1 ? "BUY" : direction == -1 ? "SELL" : "BOTH"), 
         " | Spacing=", DoubleToString(gridSpacing / point, 1), " points");
}

//+------------------------------------------------------------------+
//| Place BUY grid with ATR spacing                                  |
//+------------------------------------------------------------------+
void PlaceBuyGridATR(double startPrice, double spacing, double baseLot)
{
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   
   for(int i = 1; i <= GridLevels; i++)
   {
      double gridPrice = startPrice + (spacing * i);
      double lotSize = baseLot * MathPow(Multiplier, i - 1);
      
      // Normalize lot
      lotSize = NormalizeLot(lotSize);
      gridPrice = NormalizeDouble(gridPrice, digits);
      
      string comment = "V2_BUY_L" + IntegerToString(i);
      
      if(trade.BuyStop(lotSize, gridPrice, Symbol(), 0, 0, ORDER_TIME_GTC, 0, comment))
      {
         Print("BUYSTOP V2: Level ", i, " Price=", gridPrice, " Lot=", lotSize);
      }
   }
}

//+------------------------------------------------------------------+
//| Place SELL grid with ATR spacing                               |
//+------------------------------------------------------------------+
void PlaceSellGridATR(double startPrice, double spacing, double baseLot)
{
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   
   for(int i = 1; i <= GridLevels; i++)
   {
      double gridPrice = startPrice - (spacing * i);
      double lotSize = baseLot * MathPow(Multiplier, i - 1);
      
      // Normalize lot
      lotSize = NormalizeLot(lotSize);
      gridPrice = NormalizeDouble(gridPrice, digits);
      
      string comment = "V2_SELL_L" + IntegerToString(i);
      
      if(trade.SellStop(lotSize, gridPrice, Symbol(), 0, 0, ORDER_TIME_GTC, 0, comment))
      {
         Print("SELLSTOP V2: Level ", i, " Price=", gridPrice, " Lot=", lotSize);
      }
   }
}

//+------------------------------------------------------------------+
//| Get current ATR value                                           |
//+------------------------------------------------------------------+
double GetCurrentATR()
{
   if(atrHandle == INVALID_HANDLE)
      return 0.0;
   
   double atr[];
   ArraySetAsSeries(atr, true);
   
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) < 1)
      return 0.0;
   
   return atr[0];
}

//+------------------------------------------------------------------+
//| Calculate position size based on risk percentage                 |
//+------------------------------------------------------------------+
double CalculatePositionSize(double riskPercent)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (riskPercent / 100.0);
   
   // Get contract specifications
   double contractSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_CONTRACT_SIZE);
   double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double currentPrice = (SymbolInfoDouble(Symbol(), SYMBOL_BID) + SymbolInfoDouble(Symbol(), SYMBOL_ASK)) / 2.0;
   
   // Calculate stop loss distance (use ATR)
   double atr = GetCurrentATR();
   double stopDistance = (atr > 0) ? atr * 2.0 : (currentPrice * 0.01);  // 2 ATR or 1% fallback
   
   // Calculate lot size
   double valuePerLotPerPoint = 0.0;
   if(tickValue > 0 && tickSize > 0)
   {
      valuePerLotPerPoint = (tickValue / tickSize) * point;
   }
   
   double lotSize = 0.0;
   if(valuePerLotPerPoint > 0)
   {
      double pointsForStop = stopDistance / point;
      double valuePerLotForStop = valuePerLotPerPoint * pointsForStop;
      if(valuePerLotForStop > 0)
         lotSize = riskAmount / valuePerLotForStop;
   }
   else
   {
      // Fallback calculation
      lotSize = riskAmount / (currentPrice * contractSize * 0.01);
   }
   
   // Apply max risk limit
   double maxRiskLot = equity * (MaxRiskPerTrade / 100.0) / (currentPrice * contractSize * 0.01);
   lotSize = MathMin(lotSize, maxRiskLot);
   
   return NormalizeLot(lotSize);
}

//+------------------------------------------------------------------+
//| Normalize lot size                                               |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   
   return lot;
}

//+------------------------------------------------------------------+
//| Maintain grid (add missing orders)                               |
//+------------------------------------------------------------------+
void MaintainGrid()
{
   int positionCount = CountPositions();
   if(positionCount >= MaxBasketTrades)
      return;
   
   int pendingCount = CountPendingOrders();
   if(pendingCount >= GridLevels * 2)
      return;
   
   // Get current ATR for spacing
   double atr = GetCurrentATR();
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double spacing = (UseATRGrid && atr > 0) ? (atr * ATRMultiplier) : (FallbackStepPoints * point);
   
   // Determine direction from existing positions
   int posDirection = GetPositionDirection();
   if(posDirection == 0)
      return;
   
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double baseLot = CalculatePositionSize(RiskPercent);
   
   // Count existing pending orders
   int buyPending = CountPendingOrdersByType(ORDER_TYPE_BUY_STOP);
   int sellPending = CountPendingOrdersByType(ORDER_TYPE_SELL_STOP);
   
   // Add missing orders in same direction
   if(posDirection == 1 && buyPending < GridLevels)
   {
      double highestBuy = GetHighestPendingPrice(ORDER_TYPE_BUY_STOP);
      if(highestBuy == 0)
         highestBuy = ask;
      
      for(int i = buyPending + 1; i <= GridLevels; i++)
      {
         double gridPrice = highestBuy + (spacing * i);
         double lotSize = baseLot * MathPow(Multiplier, i - 1);
         lotSize = NormalizeLot(lotSize);
         gridPrice = NormalizeDouble(gridPrice, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS));
         
         string comment = "V2_BUY_L" + IntegerToString(i);
         trade.BuyStop(lotSize, gridPrice, Symbol(), 0, 0, ORDER_TIME_GTC, 0, comment);
      }
   }
   else if(posDirection == -1 && sellPending < GridLevels)
   {
      double lowestSell = GetLowestPendingPrice(ORDER_TYPE_SELL_STOP);
      if(lowestSell == 0)
         lowestSell = bid;
      
      for(int i = sellPending + 1; i <= GridLevels; i++)
      {
         double gridPrice = lowestSell - (spacing * i);
         double lotSize = baseLot * MathPow(Multiplier, i - 1);
         lotSize = NormalizeLot(lotSize);
         gridPrice = NormalizeDouble(gridPrice, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS));
         
         string comment = "V2_SELL_L" + IntegerToString(i);
         trade.SellStop(lotSize, gridPrice, Symbol(), 0, 0, ORDER_TIME_GTC, 0, comment);
      }
   }
}

//+------------------------------------------------------------------+
//| Smart recovery system (intelligent, not just martingale)         |
//+------------------------------------------------------------------+
void CheckSmartRecovery(double basketProfit)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double profitPercent = (basketProfit / equity) * 100.0;
   
   // Only recover if below threshold
   if(profitPercent > RecoveryThreshold)
      return;
   
   // Check if we've exceeded max recovery trades
   if(recoveryTradesCount >= MaxRecoveryTrades)
      return;
   
   int positionCount = CountPositions();
   if(positionCount >= MaxBasketTrades)
      return;
   
   // Get average position price
   double avgPrice = GetAveragePositionPrice();
   int posDirection = GetPositionDirection();
   
   if(avgPrice == 0.0 || posDirection == 0)
      return;
   
   double currentPrice = (posDirection == 1) ? 
                         SymbolInfoDouble(Symbol(), SYMBOL_BID) : 
                         SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double atr = GetCurrentATR();
   
   // Calculate distance moved against
   double priceDiff = 0.0;
   if(posDirection == 1)
      priceDiff = (avgPrice - currentPrice) / point;
   else
      priceDiff = (currentPrice - avgPrice) / point;
   
   // Use ATR-based trigger for recovery
   double triggerDistance = (atr > 0) ? (atr * ATRMultiplier / point) : FallbackStepPoints;
   
   if(priceDiff >= triggerDistance)
   {
      // Calculate recovery lot (smaller than martingale)
      double totalLot = GetTotalLotSize();
      double recoveryLot = totalLot * RecoveryLotMultiplier;
      
      // Adapt recovery based on market conditions
      if(UseAdaptiveRecovery)
      {
         // Reduce recovery in ranging markets
         if(currentRegime == REGIME_RANGING)
            recoveryLot *= 0.8;
         
         // Increase recovery in strong trends
         if((currentRegime == REGIME_TRENDING_UP && posDirection == 1) ||
            (currentRegime == REGIME_TRENDING_DOWN && posDirection == -1))
            recoveryLot *= 1.1;
      }
      
      recoveryLot = NormalizeLot(recoveryLot);
      
      Print("Smart Recovery: Adding trade at ", DoubleToString(priceDiff, 1), " points. Lot=", recoveryLot);
      
      if(posDirection == 1)
         OpenBuy(recoveryLot);
      else
         OpenSell(recoveryLot);
      
      recoveryTradesCount++;
   }
}

//+------------------------------------------------------------------+
//| Manage ATR-based trailing stops                                  |
//+------------------------------------------------------------------+
void ManageATRTrailingStops()
{
   double atr = GetCurrentATR();
   if(atr <= 0)
      return;
   
   double trailingDistance = atr * ATRTrailingMultiplier;
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
                        newSL = NormalizeDouble(currentPrice - trailingDistance, digits);
                        if(currentSL == 0 || newSL > currentSL)
                        {
                           trade.PositionModify(ticket, newSL, currentTP);
                        }
                     }
                     else // SELL
                     {
                        newSL = NormalizeDouble(currentPrice + trailingDistance, digits);
                        if(currentSL == 0 || newSL < currentSL)
                        {
                           trade.PositionModify(ticket, newSL, currentTP);
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
//| Check smart exits at support/resistance levels                   |
//+------------------------------------------------------------------+
void CheckSmartExits()
{
   if(!UseSupportResistance)
      return;
   
   double currentPrice = (SymbolInfoDouble(Symbol(), SYMBOL_BID) + SymbolInfoDouble(Symbol(), SYMBOL_ASK)) / 2.0;
   double atr = GetCurrentATR();
   double tolerance = (atr > 0) ? atr * 0.3 : (currentPrice * 0.001);
   
   int posDirection = GetPositionDirection();
   
   // Check if price is near resistance (for BUY positions)
   if(posDirection == 1)
   {
      for(int i = 0; i < SRLevels; i++)
      {
         if(resistanceLevels[i] > 0 && MathAbs(currentPrice - resistanceLevels[i]) <= tolerance)
         {
            // Close partial positions at resistance
            int positionCount = CountPositions();
            if(positionCount > MinBasketTrades)
            {
               int toClose = (int)MathMax(1, MathFloor(positionCount * 0.3));
               ClosePartialPositions(toClose, "Resistance Exit");
               Print("Smart Exit: Price reached resistance at ", resistanceLevels[i]);
            }
         }
      }
   }
   // Check if price is near support (for SELL positions)
   else if(posDirection == -1)
   {
      for(int i = 0; i < SRLevels; i++)
      {
         if(supportLevels[i] > 0 && MathAbs(currentPrice - supportLevels[i]) <= tolerance)
         {
            int positionCount = CountPositions();
            if(positionCount > MinBasketTrades)
            {
               int toClose = (int)MathMax(1, MathFloor(positionCount * 0.3));
               ClosePartialPositions(toClose, "Support Exit");
               Print("Smart Exit: Price reached support at ", supportLevels[i]);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage profit protection                                         |
//+------------------------------------------------------------------+
void ManageProfitProtection(double basketProfit, int positionCount)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Calculate dynamic basket TP
   double basketTP = equity * (BasketTPPercent / 100.0);
   basketTP = MathMax(basketTP, MinBasketTP);
   basketTP = MathMin(basketTP, MaxBasketTP);
   
   // Partial exits
   if(UsePartialExits && positionCount > MinBasketTrades)
   {
      double exit1Target = equity * (PartialExit1Percent / 100.0);
      double exit2Target = equity * (PartialExit2Percent / 100.0);
      
      if(!partialExit1Done && basketProfit >= exit1Target)
      {
         int toClose = (int)MathMax(1, MathFloor(positionCount * 0.3));
         if((positionCount - toClose) >= MinBasketTrades)
         {
            ClosePartialPositions(toClose, "Partial Exit 1");
            partialExit1Done = true;
         }
      }
      
      if(!partialExit2Done && basketProfit >= exit2Target)
      {
         int remaining = CountPositions();
         if(remaining > MinBasketTrades)
         {
            int toClose = (int)MathMax(1, MathFloor(remaining * 0.3));
            if((remaining - toClose) >= MinBasketTrades)
            {
               ClosePartialPositions(toClose, "Partial Exit 2");
               partialExit2Done = true;
            }
         }
      }
   }
   
   // Final basket TP
   if(basketProfit >= basketTP)
   {
      Print("Basket TP Reached: ", DoubleToString(basketProfit, 2), " (Target: ", DoubleToString(basketTP, 2), ")");
      CloseAll();
      DeleteAllPendingOrders();
   }
}

//+------------------------------------------------------------------+
//| Check risk limits                                                |
//+------------------------------------------------------------------+
bool CheckRiskLimits()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Check daily loss limit
   if(dailyStartEquity > 0)
   {
      double dailyLoss = ((equity - dailyStartEquity) / dailyStartEquity) * 100.0;
      if(dailyLoss <= -DailyLossLimit)
      {
         Print("Daily Loss Limit Reached: ", DoubleToString(dailyLoss, 2), "%");
         CloseAll();
         DeleteAllPendingOrders();
         return false;
      }
   }
   
   // Check max drawdown
   if(peakBasketProfit > 0)
   {
      double currentProfit = GetBasketProfit();
      double drawdown = ((peakBasketProfit - currentProfit) / peakBasketProfit) * 100.0;
      if(drawdown >= MaxDrawdownPercent)
      {
         Print("Max Drawdown Reached: ", DoubleToString(drawdown, 2), "%");
         CloseAll();
         DeleteAllPendingOrders();
         return false;
      }
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Update daily tracking                                            |
//+------------------------------------------------------------------+
void UpdateDailyTracking()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   static int lastDay = -1;
   
   if(lastDay == -1)
      lastDay = dt.day;
   
   // Reset daily tracking on new day
   if(dt.day != lastDay)
   {
      dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      dailyProfit = 0.0;
      lastDay = dt.day;
   }
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   dailyProfit = equity - dailyStartEquity;
}

//+------------------------------------------------------------------+
//| Reset basket state                                               |
//+------------------------------------------------------------------+
void ResetBasketState()
{
   peakBasketProfit = 0.0;
   basketEntryPrice = 0.0;
   basketDirection = 0;
   basketStartTime = 0;
   recoveryTradesCount = 0;
   partialExit1Done = false;
   partialExit2Done = false;
}

//+------------------------------------------------------------------+
//| Helper Functions                                                 |
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
                  count++;
            }
         }
      }
   }
   return count;
}

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
               count++;
         }
      }
   }
   return count;
}

int CountPendingOrdersByType(ENUM_ORDER_TYPE orderType)
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
               if(OrderGetInteger(ORDER_TYPE) == orderType)
                  count++;
            }
         }
      }
   }
   return count;
}

double GetBasketProfit()
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
                  total += PositionGetDouble(POSITION_PROFIT);
                  total += PositionGetDouble(POSITION_SWAP);
               }
            }
         }
      }
   }
   return total;
}

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

double GetHighestPendingPrice(ENUM_ORDER_TYPE orderType)
{
   double highest = 0.0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetInteger(ORDER_MAGIC) == Magic)
         {
            if(OrderGetString(ORDER_SYMBOL) == Symbol())
            {
               if(OrderGetInteger(ORDER_TYPE) == orderType)
               {
                  double price = 0.0;
                  if(OrderGetDouble(ORDER_PRICE_OPEN, price))
                  {
                     if(price > highest)
                        highest = price;
                  }
               }
            }
         }
      }
   }
   return highest;
}

double GetLowestPendingPrice(ENUM_ORDER_TYPE orderType)
{
   double lowest = 0.0;
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
               if(OrderGetInteger(ORDER_TYPE) == orderType)
               {
                  double price = 0.0;
                  if(OrderGetDouble(ORDER_PRICE_OPEN, price))
                  {
                     if(first || price < lowest)
                     {
                        lowest = price;
                        first = false;
                     }
                  }
               }
            }
         }
      }
   }
   return lowest;
}

void OpenBuy(double lot)
{
   double price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   lot = NormalizeLot(lot);
   
   if(trade.Buy(lot, Symbol(), price, 0, 0, "V2_BUY"))
   {
      Print("BUY opened: Lot=", lot, " Price=", price);
      // Cancel opposite pending orders if hedging prevention enabled
      if(PreventHedging)
         CancelOppositePendingOrders(ORDER_TYPE_SELL_STOP);
   }
}

void OpenSell(double lot)
{
   double price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   lot = NormalizeLot(lot);
   
   if(trade.Sell(lot, Symbol(), price, 0, 0, "V2_SELL"))
   {
      Print("SELL opened: Lot=", lot, " Price=", price);
      // Cancel opposite pending orders if hedging prevention enabled
      if(PreventHedging)
         CancelOppositePendingOrders(ORDER_TYPE_BUY_STOP);
   }
}

void CancelOppositePendingOrders(ENUM_ORDER_TYPE orderType)
{
   int cancelled = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetInteger(ORDER_MAGIC) == Magic)
         {
            if(OrderGetString(ORDER_SYMBOL) == Symbol())
            {
               if(OrderGetInteger(ORDER_TYPE) == orderType)
               {
                  if(trade.OrderDelete(ticket))
                     cancelled++;
               }
            }
         }
      }
   }
   if(cancelled > 0)
      Print("Cancelled ", cancelled, " opposite pending orders");
}

void CloseAll()
{
   int closed = 0;
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
                     closed++;
               }
            }
         }
      }
   }
   Print("Closed ", closed, " positions");
}

void DeleteAllPendingOrders()
{
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
               if(trade.OrderDelete(ticket))
                  deleted++;
            }
         }
      }
   }
}

void ClosePartialPositions(int count, string reason)
{
   if(count <= 0)
      return;
   
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
   
   // Sort by profit (descending)
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
   
   // Close top N
   int closed = 0;
   for(int i = 0; i < MathMin(count, ArraySize(positions)); i++)
   {
      if(trade.PositionClose(positions[i].ticket))
         closed++;
   }
   
   if(closed > 0)
      Print(reason, ": Closed ", closed, " positions");
}

void UpdateDisplay(double basketProfit, int positionCount)
{
   string info = "\n=== Grid + Martingale EA V2.00 ===\n";
   info += "Magic: " + IntegerToString(Magic) + "\n";
   info += "Positions: " + IntegerToString(positionCount) + "/" + IntegerToString(MaxBasketTrades) + "\n";
   info += "Pending: " + IntegerToString(CountPendingOrders()) + "\n";
   info += "Basket Profit: " + DoubleToString(basketProfit, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + "\n";
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double basketTP = equity * (BasketTPPercent / 100.0);
   info += "Target: " + DoubleToString(basketTP, 2) + " (" + DoubleToString(BasketTPPercent, 1) + "%)\n";
   
   if(positionCount > 0)
   {
      double atr = GetCurrentATR();
      double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
      info += "ATR: " + DoubleToString(atr / point, 1) + " points\n";
      
      string regimeStr = "RANGING";
      if(currentRegime == REGIME_TRENDING_UP)
         regimeStr = "TRENDING UP";
      else if(currentRegime == REGIME_TRENDING_DOWN)
         regimeStr = "TRENDING DOWN";
      info += "Regime: " + regimeStr + "\n";
      
      int posDir = GetPositionDirection();
      info += "Direction: " + (posDir == 1 ? "BUY" : "SELL") + "\n";
   }
   
   Comment(info);
}

//+------------------------------------------------------------------+

