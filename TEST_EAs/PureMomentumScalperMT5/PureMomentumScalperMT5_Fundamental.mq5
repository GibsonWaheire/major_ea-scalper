//+------------------------------------------------------------------+
//| Pure Momentum Scalper - Enhanced with Fundamental Analysis      |
//| EMA + RSI + MACD + Finnhub Economic Calendar                     |
//| Approach 2: Offensive News Trading                               |
//| Optimized for USDJPY/EURJPY/GBPJPY - Asian Session               |
//|                       © Gibson 2025                               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "4.10"
#property description "Enhanced with Finnhub Economic Calendar Integration"
#property description "Approach 2: Offensive - Uses news as confirmation, increases size on alignment"
#property description "Added: Partial Take Profit (20% intervals) + Momentum Break Exit"

#include <Trade\Trade.mqh>
#include "FinnhubEconomicCalendar.mqh"

CTrade trade;

//===================== STRATEGY INPUTS =====================//
input group "===== Momentum Strategy Settings (JPY Pairs) ====="
input ENUM_TIMEFRAMES HTF_Timeframe = PERIOD_M15;  // Trend timeframe (M15 or H1)
input ENUM_TIMEFRAMES EntryTimeframe = PERIOD_M5;  // Entry timeframe (M5 recommended)
input bool UseSessionFilter = true;                // Trade Asian/Tokyo session only (22:00-9:00 GMT)
input double MaxSpreadPips = 5.0;                  // Maximum spread filter

input group "===== Fundamental Analysis (Finnhub API) ====="
input bool     UseFundamentalAnalysis = true;      // Enable fundamental analysis
input string   FinnhubAPIKey = "d5jljvpr01qgsosh1umgd5jljvpr01qgsosh1un0"; // Finnhub API Key
input int      FundamentalUpdateInterval = 60;      // Update calendar every X minutes
input bool     UseNewsConfirmation = true;          // Use news events as confirmation
input int      NewsConfidenceThreshold = 5;         // Minimum confidence to use fundamental bias (0-10)

input group "===== Indicator Settings ====="
input int FastEMA_Period = 12;                     // Fast EMA period
input int SlowEMA_Period = 26;                     // Slow EMA period
input int RSI_Period = 14;                         // RSI period
input int RSI_Overbought = 70;                     // RSI overbought level
input int RSI_Oversold = 30;                       // RSI oversold level
input int MACD_Fast = 12;                          // MACD fast EMA
input int MACD_Slow = 26;                          // MACD slow EMA
input int MACD_Signal = 9;                         // MACD signal line

input group "===== Entry/Exit Settings (Longer Holds) ====="
input double ATR_Multiplier_SL = 4.0;              // ATR multiplier for stop loss
input double ATR_Multiplier_TP = 8.0;              // ATR multiplier for take profit
input bool UseTakeProfit = false;                  // Use fixed TP (false = let trailing stop handle exits)
input bool UseTrailingStop = true;                 // Enable trailing stop
input double TrailingStop_ATR = 2.5;               // Trailing stop ATR multiplier
input double TrailingStep_ATR = 1.0;               // Trailing step ATR multiplier
input bool UseBreakeven = true;                    // Move SL to breakeven after profit threshold
input double Breakeven_ATR_Profit = 2.0;           // Move to breakeven after this ATR profit
input int MinBarsAfterEntry = 5;                   // Minimum bars before allowing new entry

input group "===== Partial Take Profit Settings ====="
input bool UsePartialTakeProfit = true;            // Enable partial profit taking
input double PartialTP_Level1_ATR = 2.0;           // Close 20% at this ATR profit
input double PartialTP_Level2_ATR = 3.5;           // Close 20% at this ATR profit (40% total)
input double PartialTP_Level3_ATR = 5.0;           // Close 20% at this ATR profit (60% total)
input double PartialTP_Level4_ATR = 6.5;           // Close 20% at this ATR profit (80% total)
input bool UseMomentumBreakExit = true;            // Close remaining on momentum break
input double MomentumBreakThreshold = 0.3;         // ATR multiplier for momentum break detection

input group "===== Risk Management ====="
input int    MagicNumber = 202501;                 // Magic Number
input double RiskPercent = 0.5;                   // Base risk % per trade (will be adjusted by fundamental multiplier)
input double MinLotSize = 0.5;                     // Minimum lot size
input bool DebugMode = true;                       // Enable detailed logging

//===================== INTERNAL STATE =====================//
ulong currentTicket = 0;
ENUM_POSITION_TYPE currentDirection = WRONG_VALUE;
double currentSL = 0;
double currentTP = 0;
double highestProfit = 0;
datetime lastEntryTime = 0;
datetime lastBarTime = 0;

// Partial take profit tracking
bool partialTP_Level1_Taken = false;
bool partialTP_Level2_Taken = false;
bool partialTP_Level3_Taken = false;
bool partialTP_Level4_Taken = false;
double initialPositionSize = 0;

// Indicator handles
int atrHandle = INVALID_HANDLE;
int fastEMA_HTF = INVALID_HANDLE;
int slowEMA_HTF = INVALID_HANDLE;
int fastEMA_Entry = INVALID_HANDLE;
int slowEMA_Entry = INVALID_HANDLE;
int rsiHandle = INVALID_HANDLE;
int macdHandle = INVALID_HANDLE;

// Fundamental Analysis
FinnhubEconomicCalendar* g_finnhub = NULL;

//===================== UTILITY FUNCTIONS =====================//

double PipPoint()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return (digits == 3 || digits == 5) ? point * 10.0 : point;
}

double PipValue()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) return 0;
   return tickValue / tickSize;
}

double CalcLot(double slDistancePips, double multiplier = 1.0)
{
   if(slDistancePips <= 0) slDistancePips = 50;
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (RiskPercent / 100.0) * multiplier; // Apply multiplier
   double pipVal = PipValue();
   
   if(pipVal <= 0) return MinLotSize;
   
   double lot = riskMoney / (slDistancePips * pipVal);
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   double effectiveMinLot = MathMax(MinLotSize, minLot);
   
   if(lot < effectiveMinLot) lot = effectiveMinLot;
   if(lot > maxLot) lot = maxLot;
   if(lotStep > 0) lot = MathFloor(lot / lotStep) * lotStep;
   
   return NormalizeDouble(lot, 2);
}

//===================== SESSION FILTER =====================//

bool IsValidSession()
{
   if(!UseSessionFilter) return true;
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   
   bool asianSession = (hour >= 22 || hour < 9);
   
   if(DebugMode)
   {
      static datetime lastSessionLog = 0;
      if(TimeCurrent() - lastSessionLog > 3600)
      {
         if(!asianSession)
            Print("⏰ Session Filter: Outside Asian session (hour GMT: ", hour, "). Trading 22:00-9:00 GMT.");
         lastSessionLog = TimeCurrent();
      }
   }
   
   return asianSession;
}

//===================== SPREAD FILTER =====================//

bool IsSpreadOK()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;
   
   double spread = (tick.ask - tick.bid) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipPoint = PipPoint();
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double spreadPips = spread * (point / pipPoint);
   
   return (spreadPips <= MaxSpreadPips);
}

//===================== TREND DETECTION (HTF) =====================//

bool IsTrendBullish_HTF()
{
   if(fastEMA_HTF == INVALID_HANDLE || slowEMA_HTF == INVALID_HANDLE) return false;
   
   double fastEMA[], slowEMA[];
   ArraySetAsSeries(fastEMA, true);
   ArraySetAsSeries(slowEMA, true);
   
   if(CopyBuffer(fastEMA_HTF, 0, 0, 3, fastEMA) < 3) return false;
   if(CopyBuffer(slowEMA_HTF, 0, 0, 3, slowEMA) < 3) return false;
   
   bool trendBullish = (fastEMA[0] > slowEMA[0]);
   bool strengthening = (fastEMA[0] > fastEMA[1] && slowEMA[0] > slowEMA[1]);
   
   return (trendBullish && strengthening);
}

bool IsTrendBearish_HTF()
{
   if(fastEMA_HTF == INVALID_HANDLE || slowEMA_HTF == INVALID_HANDLE) return false;
   
   double fastEMA[], slowEMA[];
   ArraySetAsSeries(fastEMA, true);
   ArraySetAsSeries(slowEMA, true);
   
   if(CopyBuffer(fastEMA_HTF, 0, 0, 3, fastEMA) < 3) return false;
   if(CopyBuffer(slowEMA_HTF, 0, 0, 3, slowEMA) < 3) return false;
   
   bool trendBearish = (fastEMA[0] < slowEMA[0]);
   bool strengthening = (fastEMA[0] < fastEMA[1] && slowEMA[0] < slowEMA[1]);
   
   return (trendBearish && strengthening);
}

//===================== MOMENTUM CONFIRMATION (Entry TF) =====================//

bool CheckRSI_Bullish()
{
   if(rsiHandle == INVALID_HANDLE) return false;
   
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(rsiHandle, 0, 0, 2, rsi) < 2) return false;
   
   return (rsi[0] > 50 && rsi[0] > rsi[1] && rsi[0] < RSI_Overbought);
}

bool CheckRSI_Bearish()
{
   if(rsiHandle == INVALID_HANDLE) return false;
   
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(rsiHandle, 0, 0, 2, rsi) < 2) return false;
   
   return (rsi[0] < 50 && rsi[0] < rsi[1] && rsi[0] > RSI_Oversold);
}

bool CheckMACD_Bullish()
{
   if(macdHandle == INVALID_HANDLE) return false;
   
   double macdMain[], macdSignal[];
   ArraySetAsSeries(macdMain, true);
   ArraySetAsSeries(macdSignal, true);
   
   if(CopyBuffer(macdHandle, 0, 0, 2, macdMain) < 2) return false;
   if(CopyBuffer(macdHandle, 1, 0, 2, macdSignal) < 2) return false;
   
   return (macdMain[0] > macdSignal[0] && macdMain[0] > macdMain[1]);
}

bool CheckMACD_Bearish()
{
   if(macdHandle == INVALID_HANDLE) return false;
   
   double macdMain[], macdSignal[];
   ArraySetAsSeries(macdMain, true);
   ArraySetAsSeries(macdSignal, true);
   
   if(CopyBuffer(macdHandle, 0, 0, 2, macdMain) < 2) return false;
   if(CopyBuffer(macdHandle, 1, 0, 2, macdSignal) < 2) return false;
   
   return (macdMain[0] < macdSignal[0] && macdMain[0] < macdMain[1]);
}

bool CheckEMA_Bullish_Entry()
{
   if(fastEMA_Entry == INVALID_HANDLE || slowEMA_Entry == INVALID_HANDLE) return false;
   
   double fastEMA[], slowEMA[], close[];
   ArraySetAsSeries(fastEMA, true);
   ArraySetAsSeries(slowEMA, true);
   ArraySetAsSeries(close, true);
   
   if(CopyBuffer(fastEMA_Entry, 0, 0, 2, fastEMA) < 2) return false;
   if(CopyBuffer(slowEMA_Entry, 0, 0, 2, slowEMA) < 2) return false;
   if(CopyClose(_Symbol, EntryTimeframe, 0, 2, close) < 2) return false;
   
   bool crossed = (fastEMA[0] > slowEMA[0] && fastEMA[1] <= slowEMA[1]);
   bool priceAbove = (close[0] > fastEMA[0] && close[0] > slowEMA[0]);
   
   return (crossed || priceAbove);
}

bool CheckEMA_Bearish_Entry()
{
   if(fastEMA_Entry == INVALID_HANDLE || slowEMA_Entry == INVALID_HANDLE) return false;
   
   double fastEMA[], slowEMA[], close[];
   ArraySetAsSeries(fastEMA, true);
   ArraySetAsSeries(slowEMA, true);
   ArraySetAsSeries(close, true);
   
   if(CopyBuffer(fastEMA_Entry, 0, 0, 2, fastEMA) < 2) return false;
   if(CopyBuffer(slowEMA_Entry, 0, 0, 2, slowEMA) < 2) return false;
   if(CopyClose(_Symbol, EntryTimeframe, 0, 2, close) < 2) return false;
   
   bool crossed = (fastEMA[0] < slowEMA[0] && fastEMA[1] >= slowEMA[1]);
   bool priceBelow = (close[0] < fastEMA[0] && close[0] < slowEMA[0]);
   
   return (crossed || priceBelow);
}

//===================== MOMENTUM BREAK DETECTION =====================//

bool IsMomentumBroken()
{
   if(currentTicket == 0) return false;
   if(!PositionSelectByTicket(currentTicket)) return false;
   
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   
   // Check if price has moved against position significantly
   if(atrHandle == INVALID_HANDLE) return false;
   
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) <= 0) return false;
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;
   
   double posPriceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentPrice = (posType == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
   double atrValue = atr[0];
   
   // For BUY: Check if price has dropped significantly from entry or recent high
   // For SELL: Check if price has risen significantly from entry or recent low
   
   if(posType == POSITION_TYPE_BUY)
   {
      // Check if RSI/MACD are turning bearish
      bool rsiBearish = CheckRSI_Bearish();
      bool macdBearish = CheckMACD_Bearish();
      bool emaBearish = CheckEMA_Bearish_Entry();
      
      // Price pulled back more than threshold * ATR from entry
      double pullback = posPriceOpen - currentPrice;
      if(pullback > (atrValue * MomentumBreakThreshold) && (rsiBearish || macdBearish || emaBearish))
         return true;
   }
   else // SELL
   {
      // Check if RSI/MACD are turning bullish
      bool rsiBullish = CheckRSI_Bullish();
      bool macdBullish = CheckMACD_Bullish();
      bool emaBullish = CheckEMA_Bullish_Entry();
      
      // Price pulled back more than threshold * ATR from entry
      double pullback = currentPrice - posPriceOpen;
      if(pullback > (atrValue * MomentumBreakThreshold) && (rsiBullish || macdBullish || emaBullish))
         return true;
   }
   
   return false;
}

//===================== ENHANCED ENTRY SIGNAL (Technical + Fundamental) =====================//

struct EntrySignalResult
{
   bool        valid;
   ENUM_POSITION_TYPE direction;
   double      lotMultiplier;
   string      reason;
   int         technicalScore;
   int         fundamentalScore;
   int         combinedScore;
};

EntrySignalResult CheckEnhancedEntrySignal()
{
   EntrySignalResult result;
   result.valid = false;
   result.direction = WRONG_VALUE;
   result.lotMultiplier = 1.0;
   result.reason = "";
   result.technicalScore = 0;
   result.fundamentalScore = 0;
   result.combinedScore = 0;
   
   // 1. Basic filters
   if(!IsValidSession())
   {
      result.reason = "Outside trading session";
      return result;
   }
   
   if(!IsSpreadOK())
   {
      result.reason = "Spread too wide";
      return result;
   }
   
   // 2. Check minimum bars since last entry
   if(lastEntryTime > 0)
   {
      int barsSinceEntry = iBarShift(_Symbol, EntryTimeframe, lastEntryTime);
      if(barsSinceEntry < MinBarsAfterEntry)
      {
         result.reason = "Min bars not reached";
         return result;
      }
   }
   
   // 3. HTF Trend (Technical Analysis)
   bool htfBullish = IsTrendBullish_HTF();
   bool htfBearish = IsTrendBearish_HTF();
   
   if(!htfBullish && !htfBearish)
   {
      result.reason = "No clear HTF trend";
      return result;
   }
   
   int technicalBias = 0;
   if(htfBullish) technicalBias = 1;
   if(htfBearish) technicalBias = -1;
   result.technicalScore = 5; // Base score for trend
   
   // 4. Entry TF momentum confirmations
   bool rsiBullish = CheckRSI_Bullish();
   bool rsiBearish = CheckRSI_Bearish();
   bool macdBullish = CheckMACD_Bullish();
   bool macdBearish = CheckMACD_Bearish();
   bool emaBullish = CheckEMA_Bullish_Entry();
   bool emaBearish = CheckEMA_Bearish_Entry();
   
   // 5. BUY Signal: HTF bullish + Entry TF confirmations
   bool buySignal = false;
   if(htfBullish && emaBullish && (rsiBullish || macdBullish))
   {
      buySignal = true;
      result.technicalScore += 5; // Full technical confirmation
      result.direction = POSITION_TYPE_BUY;
   }
   
   // 6. SELL Signal: HTF bearish + Entry TF confirmations
   bool sellSignal = false;
   if(htfBearish && emaBearish && (rsiBearish || macdBearish))
   {
      sellSignal = true;
      result.technicalScore += 5; // Full technical confirmation
      result.direction = POSITION_TYPE_SELL;
   }
   
   if(!buySignal && !sellSignal)
   {
      result.reason = "Technical signals not confirmed";
      return result;
   }
   
   // 7. Fundamental Analysis (Approach 2: Offensive)
   if(UseFundamentalAnalysis && g_finnhub != NULL && g_finnhub.IsInitialized())
   {
      int fundamentalBias = 0;
      int confidence = 0;
      
      fundamentalBias = g_finnhub.GetFundamentalBias(_Symbol, confidence);
      
      // Only use fundamental if confidence is high enough
      if(confidence >= NewsConfidenceThreshold)
      {
         // Calculate fundamental score
         if(fundamentalBias == technicalBias)
         {
            // Perfect alignment: Technical + Fundamental agree
            result.fundamentalScore = 10;
            result.reason = "Technical + Fundamental alignment";
            
            // Approach 2: Increase position size when aligned
            result.lotMultiplier = g_finnhub.GetPositionSizeMultiplier(_Symbol, technicalBias, fundamentalBias, confidence);
         }
         else if(fundamentalBias == 0)
         {
            // Neutral fundamental
            result.fundamentalScore = 5;
            result.reason = "Technical signal, neutral fundamental";
            result.lotMultiplier = 1.0;
         }
         else
         {
            // Conflict: Technical vs Fundamental
            result.fundamentalScore = 2;
            result.reason = "Technical vs Fundamental conflict";
            result.lotMultiplier = 0.5; // Reduce size when conflict
         }
      }
      else
      {
         // Low confidence - use technical only
         result.fundamentalScore = 5;
         result.reason = "Technical signal, low fundamental confidence";
         result.lotMultiplier = 1.0;
      }
   }
   else
   {
      // Fundamental analysis disabled or not initialized
      result.fundamentalScore = 5; // Neutral
      result.reason = "Technical signal only";
      result.lotMultiplier = 1.0;
   }
   
   // 8. Combined score
   result.combinedScore = result.technicalScore + result.fundamentalScore;
   
   // 9. Validate signal (minimum combined score)
   if(result.combinedScore >= 12) // Minimum threshold
   {
      result.valid = true;
   }
   else
   {
      result.reason += " - Score too low: " + IntegerToString(result.combinedScore);
   }
   
   return result;
}

//===================== CALCULATE SL/TP =====================//

void CalculateSLTP(double entry, bool isBuy, double &sl, double &tp)
{
   if(atrHandle == INVALID_HANDLE)
   {
      sl = 0;
      tp = 0;
      return;
   }
   
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) <= 0)
   {
      sl = 0;
      tp = 0;
      return;
   }
   
   double atrValue = atr[0];
   double pipPoint = PipPoint();
   
   if(isBuy)
   {
      sl = entry - (atrValue * ATR_Multiplier_SL);
      tp = UseTakeProfit ? entry + (atrValue * ATR_Multiplier_TP) : 0;
   }
   else
   {
      sl = entry + (atrValue * ATR_Multiplier_SL);
      tp = UseTakeProfit ? entry - (atrValue * ATR_Multiplier_TP) : 0;
   }
   
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   if(tp > 0) tp = NormalizeDouble(tp, digits);
}

//===================== OPEN TRADE =====================//

ulong OpenTrade(ENUM_POSITION_TYPE dir, double lotMultiplier)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return 0;
   
   double entry = (dir == POSITION_TYPE_BUY) ? tick.ask : tick.bid;
   double sl, tp;
   CalculateSLTP(entry, (dir == POSITION_TYPE_BUY), sl, tp);
   
   if(sl <= 0) return 0;
   if(UseTakeProfit && tp <= 0) return 0;
   
   double slDistancePips = MathAbs(entry - sl) / PipPoint();
   double lot = CalcLot(slDistancePips, lotMultiplier);
   
   trade.SetExpertMagicNumber(MagicNumber);
   
   bool ok = (dir == POSITION_TYPE_BUY) ?
             trade.Buy(lot, _Symbol, entry, sl, tp, "Momentum+Fund") :
             trade.Sell(lot, _Symbol, entry, sl, tp, "Momentum+Fund");
   
   if(!ok)
   {
      Print("❌ Trade failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      return 0;
   }
   
   ulong ticket = trade.ResultOrder();
   string tpStr = (tp > 0) ? DoubleToString(tp, 5) : "None (trailing stop exit)";
   string multiplierStr = (lotMultiplier != 1.0) ? " (Size: " + DoubleToString(lotMultiplier * 100, 0) + "%)" : "";
   
   Print("✅ Trade opened: ", (dir == POSITION_TYPE_BUY ? "BUY" : "SELL"), 
         " Ticket: ", ticket, " Lot: ", lot, multiplierStr,
         " Entry: ", entry, " SL: ", sl, " TP: ", tpStr);
   
   // Reset partial TP tracking
   if(UsePartialTakeProfit)
   {
      partialTP_Level1_Taken = false;
      partialTP_Level2_Taken = false;
      partialTP_Level3_Taken = false;
      partialTP_Level4_Taken = false;
      initialPositionSize = lot;
      
      if(DebugMode)
         Print("📊 Partial TP enabled: Levels at ", PartialTP_Level1_ATR, ", ", PartialTP_Level2_ATR, 
               ", ", PartialTP_Level3_ATR, ", ", PartialTP_Level4_ATR, " ATR");
   }
   
   return ticket;
}

//===================== BREAKEVEN STOP =====================//

void UpdateBreakevenStop()
{
   if(!UseBreakeven || currentTicket == 0) return;
   if(!PositionSelectByTicket(currentTicket)) return;
   
   double posSL = PositionGetDouble(POSITION_SL);
   double posTP = PositionGetDouble(POSITION_TP);
   double posPriceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   
   double pipPoint = PipPoint();
   double slDistanceFromEntry = MathAbs(posSL - posPriceOpen) / pipPoint;
   if(slDistanceFromEntry <= 5.0) return;
   
   if(atrHandle == INVALID_HANDLE) return;
   
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) <= 0) return;
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   
   double currentPrice = (posType == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
   double profit = (posType == POSITION_TYPE_BUY) ? (currentPrice - posPriceOpen) : (posPriceOpen - currentPrice);
   double atrValue = atr[0];
   double breakevenThreshold = atrValue * Breakeven_ATR_Profit;
   
   if(profit >= breakevenThreshold)
   {
      double spreadBuffer = 3.0 * pipPoint;
      double newSL = 0;
      if(posType == POSITION_TYPE_BUY)
         newSL = posPriceOpen + spreadBuffer;
      else
         newSL = posPriceOpen - spreadBuffer;
      
      bool shouldUpdate = false;
      if(posType == POSITION_TYPE_BUY && newSL > posSL) shouldUpdate = true;
      else if(posType == POSITION_TYPE_SELL && (newSL < posSL || posSL == 0)) shouldUpdate = true;
      
      if(shouldUpdate)
      {
         int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         newSL = NormalizeDouble(newSL, digits);
         if(trade.PositionModify(currentTicket, newSL, posTP))
         {
            if(DebugMode)
               Print("🔒 Breakeven stop set: Ticket=", currentTicket, " SL=", newSL);
         }
      }
   }
}

//===================== PARTIAL TAKE PROFIT =====================//

void ProcessPartialTakeProfit()
{
   if(!UsePartialTakeProfit || currentTicket == 0) return;
   if(!PositionSelectByTicket(currentTicket)) return;
   
   double posVolume = PositionGetDouble(POSITION_VOLUME);
   double posPriceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   
   // If position was already partially closed, get initial size from tracking
   double currentPositionSize = posVolume;
   double baseSize = (initialPositionSize > 0) ? initialPositionSize : posVolume;
   
   if(atrHandle == INVALID_HANDLE) return;
   
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) <= 0) return;
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   
   double currentPrice = (posType == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
   double profit = (posType == POSITION_TYPE_BUY) ? (currentPrice - posPriceOpen) : (posPriceOpen - currentPrice);
   double atrValue = atr[0];
   
   // Calculate profit levels in ATR
   double level1Target = atrValue * PartialTP_Level1_ATR;
   double level2Target = atrValue * PartialTP_Level2_ATR;
   double level3Target = atrValue * PartialTP_Level3_ATR;
   double level4Target = atrValue * PartialTP_Level4_ATR;
   
   double minLotSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   // Level 1: Close 20% at first ATR target
   if(!partialTP_Level1_Taken && profit >= level1Target)
   {
      double closeLot = NormalizeDouble(baseSize * 0.20, 2);
      if(closeLot >= minLotSize && closeLot < currentPositionSize)
      {
         if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
         
         if(trade.PositionClosePartial(currentTicket, closeLot))
         {
            partialTP_Level1_Taken = true;
            if(DebugMode)
               Print("💰 Partial TP Level 1 (20%): Closed ", closeLot, " lots at ", currentPrice, 
                     " (Profit: ", DoubleToString(profit / atrValue, 2), " ATR)");
            
            // Update position state
            SyncPositionState();
         }
      }
   }
   
   // Level 2: Close 20% at second ATR target (40% total)
   if(!partialTP_Level2_Taken && profit >= level2Target && partialTP_Level1_Taken)
   {
      double closeLot = NormalizeDouble(baseSize * 0.20, 2);
      if(closeLot >= minLotSize)
      {
         // Get current position size after previous partial close
         if(PositionSelectByTicket(currentTicket))
         {
            currentPositionSize = PositionGetDouble(POSITION_VOLUME);
            if(closeLot < currentPositionSize)
            {
               if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
               
               if(trade.PositionClosePartial(currentTicket, closeLot))
               {
                  partialTP_Level2_Taken = true;
                  if(DebugMode)
                     Print("💰 Partial TP Level 2 (20%): Closed ", closeLot, " lots at ", currentPrice,
                           " (Profit: ", DoubleToString(profit / atrValue, 2), " ATR, Total: 40%)");
                  
                  SyncPositionState();
               }
            }
         }
      }
   }
   
   // Level 3: Close 20% at third ATR target (60% total)
   if(!partialTP_Level3_Taken && profit >= level3Target && partialTP_Level2_Taken)
   {
      double closeLot = NormalizeDouble(baseSize * 0.20, 2);
      if(closeLot >= minLotSize)
      {
         if(PositionSelectByTicket(currentTicket))
         {
            currentPositionSize = PositionGetDouble(POSITION_VOLUME);
            if(closeLot < currentPositionSize)
            {
               if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
               
               if(trade.PositionClosePartial(currentTicket, closeLot))
               {
                  partialTP_Level3_Taken = true;
                  if(DebugMode)
                     Print("💰 Partial TP Level 3 (20%): Closed ", closeLot, " lots at ", currentPrice,
                           " (Profit: ", DoubleToString(profit / atrValue, 2), " ATR, Total: 60%)");
                  
                  SyncPositionState();
               }
            }
         }
      }
   }
   
   // Level 4: Close 20% at fourth ATR target (80% total)
   if(!partialTP_Level4_Taken && profit >= level4Target && partialTP_Level3_Taken)
   {
      double closeLot = NormalizeDouble(baseSize * 0.20, 2);
      if(closeLot >= minLotSize)
      {
         if(PositionSelectByTicket(currentTicket))
         {
            currentPositionSize = PositionGetDouble(POSITION_VOLUME);
            if(closeLot < currentPositionSize)
            {
               if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
               
               if(trade.PositionClosePartial(currentTicket, closeLot))
               {
                  partialTP_Level4_Taken = true;
                  if(DebugMode)
                     Print("💰 Partial TP Level 4 (20%): Closed ", closeLot, " lots at ", currentPrice,
                           " (Profit: ", DoubleToString(profit / atrValue, 2), " ATR, Total: 80%)");
                  
                  SyncPositionState();
               }
            }
         }
      }
   }
   
   // Momentum Break Exit: Close remaining position if momentum breaks
   if(UseMomentumBreakExit && IsMomentumBroken())
   {
      if(PositionSelectByTicket(currentTicket))
      {
         double remainingVolume = PositionGetDouble(POSITION_VOLUME);
         if(remainingVolume >= minLotSize)
         {
            if(trade.PositionClose(currentTicket))
            {
               if(DebugMode)
                  Print("⚡ Momentum Break Exit: Closed remaining ", remainingVolume, " lots at ", currentPrice);
               
               currentTicket = 0;
               SyncPositionState();
            }
         }
      }
   }
}

//===================== TRAILING STOP =====================//

void UpdateTrailingStop()
{
   if(!UseTrailingStop || currentTicket == 0) return;
   if(!PositionSelectByTicket(currentTicket)) return;
   
   double posSL = PositionGetDouble(POSITION_SL);
   double posTP = PositionGetDouble(POSITION_TP);
   double posPriceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   
   if(atrHandle == INVALID_HANDLE) return;
   
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) <= 0) return;
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   
   double currentPrice = (posType == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
   double profit = (posType == POSITION_TYPE_BUY) ? (currentPrice - posPriceOpen) : (posPriceOpen - currentPrice);
   
   if(profit <= 0) return;
   
   double atrValue = atr[0];
   double trailingDistance = atrValue * TrailingStop_ATR;
   double trailingStep = atrValue * TrailingStep_ATR;
   
   double newSL = 0;
   bool shouldUpdate = false;
   
   if(posType == POSITION_TYPE_BUY)
   {
      newSL = currentPrice - trailingDistance;
      if(newSL > posSL + trailingStep) shouldUpdate = true;
   }
   else
   {
      newSL = currentPrice + trailingDistance;
      if(posSL == 0 || newSL < posSL - trailingStep) shouldUpdate = true;
   }
   
   if(shouldUpdate && newSL > 0)
   {
      double pipPoint = PipPoint();
      double entryDistance = 5.0 * pipPoint;
      
      if(posType == POSITION_TYPE_BUY && newSL < posPriceOpen - entryDistance) return;
      if(posType == POSITION_TYPE_SELL && newSL > posPriceOpen + entryDistance) return;
      
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      newSL = NormalizeDouble(newSL, digits);
      if(trade.PositionModify(currentTicket, newSL, posTP))
      {
         if(DebugMode)
            Print("📈 Trailing stop updated: Ticket=", currentTicket, " New SL=", newSL);
      }
   }
}

//===================== CHECK EXISTING POSITION =====================//

bool HasExistingPosition()
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         return true;
      }
   }
   return false;
}

void SyncPositionState()
{
   if(!HasExistingPosition())
   {
      currentTicket = 0;
      currentDirection = WRONG_VALUE;
      currentSL = 0;
      currentTP = 0;
      highestProfit = 0;
      
      // Reset partial TP tracking when no position
      if(UsePartialTakeProfit)
      {
         partialTP_Level1_Taken = false;
         partialTP_Level2_Taken = false;
         partialTP_Level3_Taken = false;
         partialTP_Level4_Taken = false;
         initialPositionSize = 0;
      }
      return;
   }
   
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         
         // If this is a different ticket, reset partial TP tracking
         if(ticket != currentTicket && UsePartialTakeProfit)
         {
            partialTP_Level1_Taken = false;
            partialTP_Level2_Taken = false;
            partialTP_Level3_Taken = false;
            partialTP_Level4_Taken = false;
            initialPositionSize = PositionGetDouble(POSITION_VOLUME);
         }
         // If same ticket and we don't have initial size yet, set it
         else if(ticket == currentTicket && UsePartialTakeProfit && initialPositionSize == 0)
         {
            initialPositionSize = PositionGetDouble(POSITION_VOLUME);
         }
         
         currentTicket = ticket;
         currentDirection = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         currentSL = PositionGetDouble(POSITION_SL);
         currentTP = PositionGetDouble(POSITION_TP);
         break;
      }
   }
}

//===================== INITIALIZATION =====================//

int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   
   ENUM_ORDER_TYPE_FILLING fillingMode = ORDER_FILLING_FOK;
   long fillingModeFlags = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingModeFlags & SYMBOL_FILLING_FOK) != 0)
      fillingMode = ORDER_FILLING_FOK;
   else if((fillingModeFlags & SYMBOL_FILLING_IOC) != 0)
      fillingMode = ORDER_FILLING_IOC;
   else
      fillingMode = ORDER_FILLING_RETURN;
   trade.SetTypeFilling(fillingMode);
   
   // Initialize indicators
   atrHandle = iATR(_Symbol, EntryTimeframe, 14);
   fastEMA_HTF = iMA(_Symbol, HTF_Timeframe, FastEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   slowEMA_HTF = iMA(_Symbol, HTF_Timeframe, SlowEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   fastEMA_Entry = iMA(_Symbol, EntryTimeframe, FastEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   slowEMA_Entry = iMA(_Symbol, EntryTimeframe, SlowEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle = iRSI(_Symbol, EntryTimeframe, RSI_Period, PRICE_CLOSE);
   macdHandle = iMACD(_Symbol, EntryTimeframe, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   
   if(atrHandle == INVALID_HANDLE || fastEMA_HTF == INVALID_HANDLE || slowEMA_HTF == INVALID_HANDLE ||
      fastEMA_Entry == INVALID_HANDLE || slowEMA_Entry == INVALID_HANDLE || rsiHandle == INVALID_HANDLE || macdHandle == INVALID_HANDLE)
   {
      Print("❌ ERROR: Failed to create indicators");
      return INIT_FAILED;
   }
   
   // Initialize Fundamental Analysis (Finnhub)
   if(UseFundamentalAnalysis)
   {
      g_finnhub = new FinnhubEconomicCalendar(FinnhubAPIKey);
      
      if(!g_finnhub.Initialize())
      {
         Print("⚠️ WARNING: Finnhub initialization failed. EA will continue with technical analysis only.");
         Print("⚠️ Make sure:");
         Print("   1. API key is correct");
         Print("   2. Tools > Options > Expert Advisors > Allow WebRequest for listed URL");
         Print("   3. Add 'https://finnhub.io' to allowed URLs");
      }
      else
      {
         string upcomingEvents = g_finnhub.GetUpcomingEvents(_Symbol, 3);
         Print("📅 Upcoming high-impact events: ", upcomingEvents);
      }
   }
   
   currentTicket = 0;
   currentDirection = WRONG_VALUE;
   currentSL = 0;
   currentTP = 0;
   highestProfit = 0;
   lastEntryTime = 0;
   lastBarTime = 0;
   
   SyncPositionState();
   
   Print("========================================");
   Print("Momentum Strategy EA v4.10 (Enhanced)");
   Print("Strategy: EMA + RSI + MACD + Fundamental");
   Print("Approach: Offensive News Trading");
   Print("HTF: ", EnumToString(HTF_Timeframe));
   Print("Entry TF: ", EnumToString(EntryTimeframe));
   Print("Session: ", (UseSessionFilter ? "Asian (22:00-9:00 GMT)" : "All"));
   Print("Fundamental: ", (UseFundamentalAnalysis ? "ENABLED (Finnhub)" : "DISABLED"));
   Print("Partial TP: ", (UsePartialTakeProfit ? "ENABLED (20% intervals)" : "DISABLED"));
   Print("Momentum Break Exit: ", (UseMomentumBreakExit ? "ENABLED" : "DISABLED"));
   Print("========================================");
   
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(fastEMA_HTF != INVALID_HANDLE) IndicatorRelease(fastEMA_HTF);
   if(slowEMA_HTF != INVALID_HANDLE) IndicatorRelease(slowEMA_HTF);
   if(fastEMA_Entry != INVALID_HANDLE) IndicatorRelease(fastEMA_Entry);
   if(slowEMA_Entry != INVALID_HANDLE) IndicatorRelease(slowEMA_Entry);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
   
   if(g_finnhub != NULL)
   {
      delete g_finnhub;
      g_finnhub = NULL;
   }
   
   Print("EA deinitialized. Reason: ", reason);
}

//===================== ONTICK =====================//

void OnTick()
{
   // Update fundamental calendar periodically
   if(UseFundamentalAnalysis && g_finnhub != NULL)
   {
      static datetime lastFundamentalUpdate = 0;
      if(TimeCurrent() - lastFundamentalUpdate > FundamentalUpdateInterval * 60)
      {
         g_finnhub.LoadEconomicCalendar();
         lastFundamentalUpdate = TimeCurrent();
      }
   }
   
   // Check for new bar
   datetime currentBarTime = iTime(_Symbol, EntryTimeframe, 0);
   bool isNewBar = (currentBarTime != lastBarTime);
   
   // Sync position state
   SyncPositionState();
   
   // Manage existing position
   if(currentTicket > 0 && PositionSelectByTicket(currentTicket))
   {
      // Process partial take profits first (they may close the position)
      if(UsePartialTakeProfit)
         ProcessPartialTakeProfit();
      
      // If position still exists, update stops
      if(PositionSelectByTicket(currentTicket))
      {
         UpdateBreakevenStop();
         UpdateTrailingStop();
      }
      return;
   }
   
   // Check for entry signal (only on new bar)
   if(isNewBar && !HasExistingPosition())
   {
      lastBarTime = currentBarTime;
      
      EntrySignalResult signal = CheckEnhancedEntrySignal();
      
      if(signal.valid)
      {
         if(DebugMode)
         {
            Print("✅ Entry Signal Valid:");
            Print("   Direction: ", EnumToString(signal.direction));
            Print("   Technical Score: ", signal.technicalScore, "/10");
            Print("   Fundamental Score: ", signal.fundamentalScore, "/10");
            Print("   Combined Score: ", signal.combinedScore, "/20");
            Print("   Lot Multiplier: ", DoubleToString(signal.lotMultiplier * 100, 0), "%");
            Print("   Reason: ", signal.reason);
         }
         
         currentTicket = OpenTrade(signal.direction, signal.lotMultiplier);
         if(currentTicket > 0)
         {
            currentDirection = signal.direction;
            lastEntryTime = TimeCurrent();
            SyncPositionState();
         }
      }
      else if(DebugMode && StringLen(signal.reason) > 0)
      {
         static datetime lastLog = 0;
         if(TimeCurrent() - lastLog > 300) // Log every 5 minutes
         {
            Print("❌ Entry blocked: ", signal.reason, " (Score: ", signal.combinedScore, ")");
            lastLog = TimeCurrent();
         }
      }
   }
}
//+------------------------------------------------------------------+

