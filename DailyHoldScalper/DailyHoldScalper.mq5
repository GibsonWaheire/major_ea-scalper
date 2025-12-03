#property copyright "Copyright 2025, Daily Hold Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

CTrade trade;

// =====================================================================================================
// DAILY HOLD SCALPER - MT5
// Strategy:
// 1. Takes trades immediately based on market analysis
// 2. Holds trades until reasonable profit for the day
// 3. Takes another trade after 10 minutes
// 4. Maximum 5 trades per day
// 5. Holds all trades for the day
// 6. Risk per trade: 10%
// 7. Maximum daily drawdown: 40% (closes all trades)
// 8. No stop loss
// 9. Uses take profit and partial closes for inactive EA scenarios
// =====================================================================================================

input group "===== Trading Settings ====="
input string   TradeSymbols            = "USDGBP,USDJPY,GBPUSD,EURUSD,USDCHF";  // Comma-separated symbols
input int      MagicNumber              = 202505;
input int      MaxTradesPerDay          = 5;      // Maximum 5 trades per day
input int      MinutesBetweenTrades     = 10;     // 10 minutes between trades
input bool     TradeEnabled             = true;

input group "===== Risk Management ====="
input double   RiskPerTradePercent      = 10.0;   // 10% risk per trade
input double   MaxDailyDrawdownPercent  = 40.0;   // 40% max daily drawdown
input bool     NoStopLoss               = true;   // No stop loss (always true)

input group "===== Profit Management ====="
input double   TakeProfitPercent        = 50.0;   // Take profit at 50% profit (reasonable for day)
input double   PartialClosePercent     = 30.0;   // Partial close at 30% profit
input double   PartialCloseRatio        = 0.5;    // Close 50% of position at partial close level
input bool     UsePartialCloses         = true;   // Enable partial closes

input group "===== Market Analysis ====="
input int      EMA_Fast_Period         = 9;      // Fast EMA for trend
input int      EMA_Slow_Period         = 21;     // Slow EMA for trend
input int      RSI_Period              = 14;     // RSI for momentum
input double   RSI_Oversold            = 30.0;   // RSI oversold level
input double   RSI_Overbought          = 70.0;   // RSI overbought level
input int      ATR_Period              = 14;     // ATR for volatility
input double   MinATRMultiplier        = 1.5;    // Minimum ATR multiplier for signal
input double   MaxSpreadPips           = 5.0;    // Maximum spread filter

input group "===== Display Settings ====="
input bool     ShowInfoPanel           = true;   // Show info panel on chart
input color    PanelColor              = clrDarkSlateGray;
input int      PanelX                  = 20;
input int      PanelY                  = 50;

// =====================================================================================================
// STRUCTURES & GLOBALS
// =====================================================================================================

struct TradeInfo {
   ulong    ticket;
   string   symbol;
   double   entryPrice;
   double   lotSize;
   datetime openTime;
   int      direction;  // 1=BUY, -1=SELL
   double   initialEquity;
   bool     partialClosed;
   double   highestProfit;
   double   lowestProfit;
};

TradeInfo dailyTrades[5];  // Maximum 5 trades per day
int totalDailyTrades = 0;

// Daily tracking
double dailyStartBalance = 0.0;
double dailyStartEquity = 0.0;
double dailyHighEquity = 0.0;
double dailyLowEquity = 0.0;
datetime lastDayReset = 0;
datetime lastTradeTime = 0;
int tradesToday = 0;
bool dailyDrawdownReached = false;

// Indicator handles (per symbol)
struct SymbolIndicators {
   string symbol;
   int emaFastHandle;
   int emaSlowHandle;
   int rsiHandle;
   int atrHandle;
   bool initialized;
};

SymbolIndicators symbolIndicators[];
string tradeSymbolsArray[];
int totalSymbols = 0;

// Current market data
MqlTick currentTick;
double currentBid = 0.0;
double currentAsk = 0.0;

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("DAILY HOLD SCALPER v1.00 - MT5");
   Print("========================================");
   Print("Strategy: Immediate trades, hold for day");
   Print("Max Trades: ", MaxTradesPerDay, " per day");
   Print("Risk: ", RiskPerTradePercent, "% per trade");
   Print("Max Drawdown: ", MaxDailyDrawdownPercent, "%");
   Print("No Stop Loss: ", NoStopLoss ? "YES" : "NO");
   Print("========================================");
   
   // Parse trade symbols
   ParseTradeSymbols();
   
   // Initialize indicators for each symbol
   if(!InitializeIndicators())
   {
      Print("ERROR: Failed to initialize indicators");
      return(INIT_FAILED);
   }
   
   // Initialize trading state
   ResetDailyTracking();
   
   // Set trade parameters
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Initialize trade array
   for(int i = 0; i < 5; i++)
   {
      dailyTrades[i].ticket = 0;
      dailyTrades[i].symbol = "";
      dailyTrades[i].entryPrice = 0.0;
      dailyTrades[i].lotSize = 0.0;
      dailyTrades[i].openTime = 0;
      dailyTrades[i].direction = 0;
      dailyTrades[i].initialEquity = 0.0;
      dailyTrades[i].partialClosed = false;
      dailyTrades[i].highestProfit = 0.0;
      dailyTrades[i].lowestProfit = 0.0;
   }
   totalDailyTrades = 0;
   
   // Sync existing positions (in case EA was restarted)
   SyncExistingPositions();
   
   Print("Initialization successful! Trading ", totalSymbols, " symbols");
   return(INIT_SUCCEEDED);
}

void SyncExistingPositions()
{
   // Find all open positions with our magic number
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;
      
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            string symbol = PositionGetString(POSITION_SYMBOL);
            datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
            
            // Check if this position is from today
            datetime time[];
            ArraySetAsSeries(time, true);
            if(CopyTime(_Symbol, PERIOD_D1, 0, 1, time) > 0)
            {
               if(posTime >= time[0]) // Position opened today
               {
                  // Add to daily trades if not already there
                  bool found = false;
                  for(int j = 0; j < totalDailyTrades; j++)
                  {
                     if(dailyTrades[j].ticket == ticket)
                     {
                        found = true;
                        break;
                     }
                  }
                  
                  if(!found && totalDailyTrades < 5)
                  {
                     int direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
                     
                     dailyTrades[totalDailyTrades].ticket = ticket;
                     dailyTrades[totalDailyTrades].symbol = symbol;
                     dailyTrades[totalDailyTrades].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                     dailyTrades[totalDailyTrades].lotSize = PositionGetDouble(POSITION_VOLUME);
                     dailyTrades[totalDailyTrades].openTime = posTime;
                     dailyTrades[totalDailyTrades].direction = direction;
                     dailyTrades[totalDailyTrades].initialEquity = AccountInfoDouble(ACCOUNT_EQUITY);
                     dailyTrades[totalDailyTrades].partialClosed = false;
                     dailyTrades[totalDailyTrades].highestProfit = 0.0;
                     dailyTrades[totalDailyTrades].lowestProfit = 0.0;
                     
                     totalDailyTrades++;
                     tradesToday++;
                     
                     Print("Synced existing position: ", symbol, " Ticket=", ticket);
                  }
               }
            }
         }
      }
   }
}

void OnDeinit(const int reason)
{
   // Release all indicators
   for(int i = 0; i < totalSymbols; i++)
   {
      if(symbolIndicators[i].emaFastHandle != INVALID_HANDLE)
         IndicatorRelease(symbolIndicators[i].emaFastHandle);
      if(symbolIndicators[i].emaSlowHandle != INVALID_HANDLE)
         IndicatorRelease(symbolIndicators[i].emaSlowHandle);
      if(symbolIndicators[i].rsiHandle != INVALID_HANDLE)
         IndicatorRelease(symbolIndicators[i].rsiHandle);
      if(symbolIndicators[i].atrHandle != INVALID_HANDLE)
         IndicatorRelease(symbolIndicators[i].atrHandle);
   }
   
   Print("DailyHoldScalper deinitialized. Reason: ", reason);
}

// =====================================================================================================
// UTILITY FUNCTIONS
// =====================================================================================================

void ParseTradeSymbols()
{
   string symbols = TradeSymbols;
   StringToUpper(symbols);
   
   int count = StringSplit(symbols, ',', tradeSymbolsArray);
   totalSymbols = 0;
   
   ArrayResize(symbolIndicators, count);
   ArrayResize(tradeSymbolsArray, count);
   
   for(int i = 0; i < count; i++)
   {
      string sym = tradeSymbolsArray[i];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      
      if(StringLen(sym) > 0)
      {
         tradeSymbolsArray[totalSymbols] = sym;
         symbolIndicators[totalSymbols].symbol = sym;
         symbolIndicators[totalSymbols].initialized = false;
         totalSymbols++;
      }
   }
   
   Print("Parsed ", totalSymbols, " trading symbols");
}

bool InitializeIndicators()
{
   for(int i = 0; i < totalSymbols; i++)
   {
      string sym = symbolIndicators[i].symbol;
      
      // Create EMA Fast
      symbolIndicators[i].emaFastHandle = iMA(sym, PERIOD_M1, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
      if(symbolIndicators[i].emaFastHandle == INVALID_HANDLE)
      {
         Print("ERROR: Failed to create Fast EMA for ", sym);
         return false;
      }
      
      // Create EMA Slow
      symbolIndicators[i].emaSlowHandle = iMA(sym, PERIOD_M1, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
      if(symbolIndicators[i].emaSlowHandle == INVALID_HANDLE)
      {
         Print("ERROR: Failed to create Slow EMA for ", sym);
         return false;
      }
      
      // Create RSI
      symbolIndicators[i].rsiHandle = iRSI(sym, PERIOD_M1, RSI_Period, PRICE_CLOSE);
      if(symbolIndicators[i].rsiHandle == INVALID_HANDLE)
      {
         Print("ERROR: Failed to create RSI for ", sym);
         return false;
      }
      
      // Create ATR
      symbolIndicators[i].atrHandle = iATR(sym, PERIOD_M1, ATR_Period);
      if(symbolIndicators[i].atrHandle == INVALID_HANDLE)
      {
         Print("ERROR: Failed to create ATR for ", sym);
         return false;
      }
      
      symbolIndicators[i].initialized = true;
   }
   
   return true;
}

void ResetDailyTracking()
{
   // Get current day start time (MT5 way)
   datetime time[];
   ArraySetAsSeries(time, true);
   if(CopyTime(_Symbol, PERIOD_D1, 0, 1, time) <= 0)
      return;
   
   datetime currentDay = time[0];
   
   if(currentDay != lastDayReset)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      dailyHighEquity = dailyStartEquity;
      dailyLowEquity = dailyStartEquity;
      lastDayReset = currentDay;
      tradesToday = 0;
      dailyDrawdownReached = false;
      lastTradeTime = 0;
      
      // Reset trade array
      for(int i = 0; i < 5; i++)
      {
         dailyTrades[i].ticket = 0;
         dailyTrades[i].symbol = "";
         dailyTrades[i].entryPrice = 0.0;
         dailyTrades[i].lotSize = 0.0;
         dailyTrades[i].openTime = 0;
         dailyTrades[i].direction = 0;
         dailyTrades[i].initialEquity = 0.0;
         dailyTrades[i].partialClosed = false;
         dailyTrades[i].highestProfit = 0.0;
         dailyTrades[i].lowestProfit = 0.0;
      }
      totalDailyTrades = 0;
      
      Print("Daily reset: Balance=", dailyStartBalance, " Equity=", dailyStartEquity);
   }
}

double GetSpreadPips(string symbol)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   if(digits == 3 || digits == 5)
      point *= 10.0;
   
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   
   if(point > 0)
      return (ask - bid) / point;
   
   return 0.0;
}

double CalculateLotSize(string symbol, double riskPercent)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * riskPercent / 100.0;
   
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   if(digits == 3 || digits == 5)
      point *= 10.0;
   
   // Use ATR as risk distance (no stop loss, but use ATR for sizing)
   double atr[];
   ArraySetAsSeries(atr, true);
   int atrHandle = GetATRHandle(symbol);
   
   if(atrHandle == INVALID_HANDLE)
      return 0.01;
   
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) <= 0)
      return 0.01;
   
   double riskDistance = atr[0] * MinATRMultiplier;
   if(riskDistance <= 0)
      riskDistance = point * 50; // Fallback to 50 pips
   
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(tickValue <= 0 || tickSize <= 0)
      return 0.01;
   
   double lotSize = riskAmount / (riskDistance / tickSize * tickValue);
   
   // Normalize lot size
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   
   return lotSize;
}

double CalculateTakeProfitPrice(string symbol, double entryPrice, int direction, double profitPercent)
{
   // Calculate TP price based on profit percentage
   // For 50% profit: TP should be at price where profit = 50% of initial equity risk
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPerTradePercent / 100.0;
   double targetProfit = riskAmount * profitPercent / 100.0;
   
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   if(digits == 3 || digits == 5)
      point *= 10.0;
   
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotSize = CalculateLotSize(symbol, RiskPerTradePercent);
   
   if(tickValue <= 0 || tickSize <= 0 || lotSize <= 0)
   {
      // Fallback: use ATR-based TP
      double atr[];
      ArraySetAsSeries(atr, true);
      int atrHandle = GetATRHandle(symbol);
      
      if(atrHandle != INVALID_HANDLE && CopyBuffer(atrHandle, 0, 0, 1, atr) > 0)
      {
         double tpDistance = atr[0] * 3.0; // 3x ATR for reasonable profit
         if(direction == 1)
            return entryPrice + tpDistance;
         else
            return entryPrice - tpDistance;
      }
      
      // Final fallback: 100 pips
      double tpDistance = point * 100;
      if(direction == 1)
         return entryPrice + tpDistance;
      else
         return entryPrice - tpDistance;
   }
   
   // Calculate price distance needed for target profit
   double priceDistance = (targetProfit / (lotSize * tickValue / tickSize));
   
   // Normalize to tick size
   priceDistance = MathFloor(priceDistance / tickSize) * tickSize;
   
   double tpPrice = 0.0;
   if(direction == 1)
      tpPrice = entryPrice + priceDistance;
   else
      tpPrice = entryPrice - priceDistance;
   
   // Normalize TP price
   tpPrice = MathFloor(tpPrice / tickSize) * tickSize;
   
   return tpPrice;
}

int GetEMAHandle(string symbol, bool fast)
{
   for(int i = 0; i < totalSymbols; i++)
   {
      if(symbolIndicators[i].symbol == symbol)
      {
         return fast ? symbolIndicators[i].emaFastHandle : symbolIndicators[i].emaSlowHandle;
      }
   }
   return INVALID_HANDLE;
}

int GetRSIHandle(string symbol)
{
   for(int i = 0; i < totalSymbols; i++)
   {
      if(symbolIndicators[i].symbol == symbol)
         return symbolIndicators[i].rsiHandle;
   }
   return INVALID_HANDLE;
}

int GetATRHandle(string symbol)
{
   for(int i = 0; i < totalSymbols; i++)
   {
      if(symbolIndicators[i].symbol == symbol)
         return symbolIndicators[i].atrHandle;
   }
   return INVALID_HANDLE;
}

// =====================================================================================================
// MARKET ANALYSIS
// =====================================================================================================

int AnalyzeMarket(string symbol)
{
   // Get current spread
   double spread = GetSpreadPips(symbol);
   if(spread > MaxSpreadPips)
      return 0; // No trade if spread too high
   
   // Get EMA values
   double emaFast[], emaSlow[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   
   int emaFastHandle = GetEMAHandle(symbol, true);
   int emaSlowHandle = GetEMAHandle(symbol, false);
   
   if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE)
      return 0;
   
   if(CopyBuffer(emaFastHandle, 0, 0, 2, emaFast) <= 0)
      return 0;
   if(CopyBuffer(emaSlowHandle, 0, 0, 2, emaSlow) <= 0)
      return 0;
   
   // Get RSI
   double rsi[];
   ArraySetAsSeries(rsi, true);
   int rsiHandle = GetRSIHandle(symbol);
   
   if(rsiHandle == INVALID_HANDLE)
      return 0;
   
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsi) <= 0)
      return 0;
   
   // Get ATR
   double atr[];
   ArraySetAsSeries(atr, true);
   int atrHandle = GetATRHandle(symbol);
   
   if(atrHandle == INVALID_HANDLE)
      return 0;
   
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) <= 0)
      return 0;
   
   // Get current price
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   if(digits == 3 || digits == 5)
      point *= 10.0;
   
   // Analysis logic
   bool bullishTrend = emaFast[0] > emaSlow[0] && emaFast[1] > emaSlow[1];
   bool bearishTrend = emaFast[0] < emaSlow[0] && emaFast[1] < emaSlow[1];
   
   bool bullishMomentum = rsi[0] > 50 && rsi[0] < RSI_Overbought;
   bool bearishMomentum = rsi[0] < 50 && rsi[0] > RSI_Oversold;
   
   bool sufficientVolatility = atr[0] >= (point * 10 * MinATRMultiplier);
   
   // BUY signal
   if(bullishTrend && bullishMomentum && sufficientVolatility)
      return 1;
   
   // SELL signal
   if(bearishTrend && bearishMomentum && sufficientVolatility)
      return -1;
   
   return 0; // No signal
}

// =====================================================================================================
// TRADE MANAGEMENT
// =====================================================================================================

bool CanTakeNewTrade()
{
   // Check if daily drawdown reached
   if(dailyDrawdownReached)
      return false;
   
   // Check if max trades reached
   if(tradesToday >= MaxTradesPerDay)
      return false;
   
   // Check if 10 minutes passed since last trade
   if(lastTradeTime > 0)
   {
      datetime currentTime = TimeCurrent();
      int secondsSinceLastTrade = (int)(currentTime - lastTradeTime);
      
      if(secondsSinceLastTrade < (MinutesBetweenTrades * 60))
         return false;
   }
   
   return true;
}

bool OpenTrade(string symbol, int direction)
{
   if(!CanTakeNewTrade())
      return false;
   
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   
   double price = (direction == 1) ? ask : bid;
   double lotSize = CalculateLotSize(symbol, RiskPerTradePercent);
   
   if(lotSize <= 0)
   {
      Print("ERROR: Invalid lot size for ", symbol);
      return false;
   }
   
   // Calculate take profit price (for automatic closing when EA inactive)
   double tpPrice = CalculateTakeProfitPrice(symbol, price, direction, TakeProfitPercent);
   
   // Normalize prices
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   price = MathFloor(price / tickSize) * tickSize;
   tpPrice = MathFloor(tpPrice / tickSize) * tickSize;
   
   bool result = false;
   ulong ticket = 0;
   
   if(direction == 1)
   {
      // BUY: TP above entry
      if(tpPrice > price)
         result = trade.Buy(lotSize, symbol, 0, tpPrice, 0, NULL);
      else
         result = trade.Buy(lotSize, symbol, 0, 0, 0, NULL);
      ticket = trade.ResultOrder();
   }
   else
   {
      // SELL: TP below entry
      if(tpPrice < price)
         result = trade.Sell(lotSize, symbol, 0, tpPrice, 0, NULL);
      else
         result = trade.Sell(lotSize, symbol, 0, 0, 0, NULL);
      ticket = trade.ResultOrder();
   }
   
   if(result && ticket > 0)
   {
      // Wait a moment for order to become position (MT5)
      Sleep(100);
      
      // Find the position ticket (in MT5, order becomes position)
      ulong positionTicket = 0;
      for(int pos = PositionsTotal() - 1; pos >= 0; pos--)
      {
         if(PositionGetSymbol(pos) == symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            ulong posTicket = PositionGetInteger(POSITION_TICKET);
            // Check if this position was just opened (by checking time)
            if(PositionSelectByTicket(posTicket))
            {
               datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
               if(MathAbs((int)(TimeCurrent() - posTime)) < 5) // Within 5 seconds
               {
                  positionTicket = posTicket;
                  break;
               }
            }
         }
      }
      
      if(positionTicket == 0)
      {
         // Fallback: try to get position by symbol and magic
         if(PositionSelect(symbol))
         {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
               positionTicket = PositionGetInteger(POSITION_TICKET);
         }
      }
      
      if(positionTicket > 0)
      {
         // Add to daily trades array
         if(totalDailyTrades < 5)
         {
            dailyTrades[totalDailyTrades].ticket = positionTicket;
            dailyTrades[totalDailyTrades].symbol = symbol;
            dailyTrades[totalDailyTrades].entryPrice = price;
            dailyTrades[totalDailyTrades].lotSize = lotSize;
            dailyTrades[totalDailyTrades].openTime = TimeCurrent();
            dailyTrades[totalDailyTrades].direction = direction;
            dailyTrades[totalDailyTrades].initialEquity = AccountInfoDouble(ACCOUNT_EQUITY);
            dailyTrades[totalDailyTrades].partialClosed = false;
            dailyTrades[totalDailyTrades].highestProfit = 0.0;
            dailyTrades[totalDailyTrades].lowestProfit = 0.0;
            
            totalDailyTrades++;
            tradesToday++;
            lastTradeTime = TimeCurrent();
            
            Print("Trade opened: ", symbol, " ", (direction == 1 ? "BUY" : "SELL"), 
                  " Lot=", lotSize, " Price=", price, " Ticket=", positionTicket);
            
            return true;
         }
      }
      else
      {
         Print("WARNING: Trade opened but position ticket not found. Order ticket=", ticket);
      }
   }
   else
   {
      Print("ERROR: Failed to open trade. Code=", trade.ResultRetcode(), " Description=", trade.ResultRetcodeDescription());
   }
   
   return false;
}

void UpdateTradeInfo()
{
   for(int i = 0; i < totalDailyTrades; i++)
   {
      if(dailyTrades[i].ticket == 0)
         continue;
      
      if(!PositionSelectByTicket(dailyTrades[i].ticket))
         continue;
      
      double currentProfit = PositionGetDouble(POSITION_PROFIT);
      double currentSwap = PositionGetDouble(POSITION_SWAP);
      double totalPL = currentProfit + currentSwap;
      
      // Update highest/lowest profit
      if(totalPL > dailyTrades[i].highestProfit)
         dailyTrades[i].highestProfit = totalPL;
      
      if(totalPL < dailyTrades[i].lowestProfit)
         dailyTrades[i].lowestProfit = totalPL;
   }
}

void ManageTrades()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Update daily high/low equity
   if(currentEquity > dailyHighEquity)
      dailyHighEquity = currentEquity;
   
   if(currentEquity < dailyLowEquity)
      dailyLowEquity = currentEquity;
   
   // Check daily drawdown
   double drawdownPercent = ((dailyStartEquity - dailyLowEquity) / dailyStartEquity) * 100.0;
   
   if(drawdownPercent >= MaxDailyDrawdownPercent && !dailyDrawdownReached)
   {
      dailyDrawdownReached = true;
      Print("ALERT: Daily drawdown reached ", drawdownPercent, "% - Closing all trades!");
      CloseAllTrades();
      return;
   }
   
   // Manage individual trades
   for(int i = 0; i < totalDailyTrades; i++)
   {
      if(dailyTrades[i].ticket == 0)
         continue;
      
      if(!PositionSelectByTicket(dailyTrades[i].ticket))
      {
         // Position closed, remove from array
         dailyTrades[i].ticket = 0;
         continue;
      }
      
      double currentProfit = PositionGetDouble(POSITION_PROFIT);
      double currentSwap = PositionGetDouble(POSITION_SWAP);
      double totalPL = currentProfit + currentSwap;
      double initialEquity = dailyTrades[i].initialEquity;
      
      // Calculate profit percentage
      double profitPercent = 0.0;
      if(initialEquity > 0)
         profitPercent = (totalPL / initialEquity) * 100.0;
      
      // Partial close at 30% profit
      if(UsePartialCloses && !dailyTrades[i].partialClosed && profitPercent >= PartialClosePercent)
      {
         double currentVolume = PositionGetDouble(POSITION_VOLUME);
         double closeVolume = NormalizeDouble(currentVolume * PartialCloseRatio, 2);
         
         if(closeVolume >= SymbolInfoDouble(dailyTrades[i].symbol, SYMBOL_VOLUME_MIN))
         {
            if(trade.PositionClosePartial(dailyTrades[i].ticket, closeVolume))
            {
               dailyTrades[i].partialClosed = true;
               Print("Partial close: ", dailyTrades[i].symbol, " Ticket=", dailyTrades[i].ticket, 
                     " Volume=", closeVolume, " Profit%=", profitPercent);
            }
         }
      }
      
      // Take profit at 50% profit (reasonable for day)
      // Note: TP is already set on order, but we can also close manually if needed
      if(profitPercent >= TakeProfitPercent)
      {
         if(trade.PositionClose(dailyTrades[i].ticket))
         {
            Print("Take profit: ", dailyTrades[i].symbol, " Ticket=", dailyTrades[i].ticket, 
                  " Profit%=", profitPercent);
            dailyTrades[i].ticket = 0;
         }
      }
      else
      {
         // Update TP if profit increases (trailing TP concept)
         // This ensures TP is always at reasonable level even if EA restarts
         double currentTP = PositionGetDouble(POSITION_TP);
         double newTP = CalculateTakeProfitPrice(dailyTrades[i].symbol, dailyTrades[i].entryPrice, 
                                                  dailyTrades[i].direction, TakeProfitPercent);
         
         // Only update if new TP is better (further from entry for profit)
         bool shouldUpdateTP = false;
         if(dailyTrades[i].direction == 1 && (currentTP == 0 || newTP > currentTP))
            shouldUpdateTP = true;
         else if(dailyTrades[i].direction == -1 && (currentTP == 0 || newTP < currentTP))
            shouldUpdateTP = true;
         
         if(shouldUpdateTP && currentTP != newTP)
         {
            if(trade.PositionModify(dailyTrades[i].ticket, 0, newTP))
            {
               Print("Updated TP: ", dailyTrades[i].symbol, " Ticket=", dailyTrades[i].ticket, 
                     " New TP=", newTP);
            }
         }
      }
   }
}

void CloseAllTrades()
{
   Print("Closing all trades due to drawdown limit...");
   
   for(int i = 0; i < totalDailyTrades; i++)
   {
      if(dailyTrades[i].ticket == 0)
         continue;
      
      if(PositionSelectByTicket(dailyTrades[i].ticket))
      {
         if(trade.PositionClose(dailyTrades[i].ticket))
         {
            Print("Closed trade: ", dailyTrades[i].symbol, " Ticket=", dailyTrades[i].ticket);
         }
      }
      
      dailyTrades[i].ticket = 0;
   }
   
   totalDailyTrades = 0;
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   if(!TradeEnabled)
      return;
   
   // Reset daily tracking if new day
   ResetDailyTracking();
   
   // Update trade information
   UpdateTradeInfo();
   
   // Manage existing trades (partial closes, take profits)
   ManageTrades();
   
   // Check if we can take new trade
   if(!CanTakeNewTrade())
      return;
   
   // Try to find trading opportunity
   for(int i = 0; i < totalSymbols; i++)
   {
      string symbol = tradeSymbolsArray[i];
      
      // Analyze market
      int signal = AnalyzeMarket(symbol);
      
      if(signal != 0)
      {
         if(OpenTrade(symbol, signal))
         {
            // Trade opened successfully, break to wait for next interval
            break;
         }
      }
   }
   
   // Display info panel
   if(ShowInfoPanel)
      DisplayInfoPanel();
}

// =====================================================================================================
// DISPLAY FUNCTIONS
// =====================================================================================================

void DisplayInfoPanel()
{
   string panelText = "\n=== DAILY HOLD SCALPER ===\n";
   panelText += "Trades Today: " + IntegerToString(tradesToday) + "/" + IntegerToString(MaxTradesPerDay) + "\n";
   panelText += "Open Positions: " + IntegerToString(totalDailyTrades) + "\n";
   
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdown = ((dailyStartEquity - dailyLowEquity) / dailyStartEquity) * 100.0;
   
   panelText += "Daily Start: $" + DoubleToString(dailyStartEquity, 2) + "\n";
   panelText += "Current Equity: $" + DoubleToString(currentEquity, 2) + "\n";
   panelText += "Daily Drawdown: " + DoubleToString(drawdown, 2) + "%\n";
   panelText += "Max Drawdown: " + DoubleToString(MaxDailyDrawdownPercent, 1) + "%\n";
   
   if(dailyDrawdownReached)
      panelText += "STATUS: DRAWDOWN LIMIT REACHED\n";
   else if(tradesToday >= MaxTradesPerDay)
      panelText += "STATUS: MAX TRADES REACHED\n";
   else
   {
      int secondsUntilNext = (MinutesBetweenTrades * 60) - (int)(TimeCurrent() - lastTradeTime);
      if(secondsUntilNext > 0)
         panelText += "Next Trade In: " + IntegerToString(secondsUntilNext) + "s\n";
      else
         panelText += "STATUS: READY TO TRADE\n";
   }
   
   Comment(panelText);
}

