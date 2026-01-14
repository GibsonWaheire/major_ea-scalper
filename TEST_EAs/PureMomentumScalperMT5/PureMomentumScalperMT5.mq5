//+------------------------------------------------------------------+
//|         Pure Momentum Scalper - Trend Following for JPY Pairs   |
//|          EMA + RSI + MACD Momentum Strategy                      |
//|          Optimized for USDJPY/EURJPY/GBPJPY - Asian Session      |
//|                       © Gibson 2025                               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "3.00"

#include <Trade\Trade.mqh>
CTrade trade;

//===================== STRATEGY INPUTS =====================//
input group "===== Momentum Strategy Settings (JPY Pairs) ====="
input ENUM_TIMEFRAMES HTF_Timeframe = PERIOD_M15;  // Trend timeframe (M15 or H1)
input ENUM_TIMEFRAMES EntryTimeframe = PERIOD_M5;  // Entry timeframe (M5 recommended)
input bool UseSessionFilter = true;                // Trade Asian/Tokyo session only (22:00-9:00 GMT)
input double MaxSpreadPips = 5.0;                  // Maximum spread filter

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
input double ATR_Multiplier_SL = 4.0;              // ATR multiplier for stop loss (wider = more flexible)
input double ATR_Multiplier_TP = 8.0;              // ATR multiplier for take profit (higher = longer holds)
input bool UseTakeProfit = false;                  // Use fixed TP (false = let trailing stop handle exits)
input bool UseTrailingStop = true;                 // Enable trailing stop (recommended for longer holds)
input double TrailingStop_ATR = 2.5;               // Trailing stop ATR multiplier (wider = let trades breathe)
input double TrailingStep_ATR = 1.0;                // Trailing step ATR multiplier (bigger step = less frequent updates)
input bool UseBreakeven = true;                    // Move SL to breakeven after profit threshold
input double Breakeven_ATR_Profit = 2.0;           // Move to breakeven after this ATR profit
input int MinBarsAfterEntry = 5;                   // Minimum bars before allowing new entry

input group "===== Risk Management ====="
input int    MagicNumber = 202501;                 // Magic Number
input double RiskPercent = 0.5;                    // Risk % per trade
input double MinLotSize = 0.5;                     // Minimum lot size (0.5 lots for JPY pairs)
input bool DebugMode = true;                       // Enable detailed logging

//===================== INTERNAL STATE =====================//
ulong currentTicket = 0;
ENUM_POSITION_TYPE currentDirection = WRONG_VALUE;
double currentSL = 0;
double currentTP = 0;
double highestProfit = 0;
datetime lastEntryTime = 0;
datetime lastBarTime = 0;

// Indicator handles
int atrHandle = INVALID_HANDLE;
int fastEMA_HTF = INVALID_HANDLE;
int slowEMA_HTF = INVALID_HANDLE;
int fastEMA_Entry = INVALID_HANDLE;
int slowEMA_Entry = INVALID_HANDLE;
int rsiHandle = INVALID_HANDLE;
int macdHandle = INVALID_HANDLE;

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

double CalcLot(double slDistancePips)
{
   if(slDistancePips <= 0) slDistancePips = 50;
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (RiskPercent / 100.0);
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
   
   // Fast EMA above Slow EMA = bullish trend
   // Also check if they're diverging (trend strengthening)
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
   
   // Fast EMA below Slow EMA = bearish trend
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
   
   // RSI above 50 and rising = bullish momentum
   return (rsi[0] > 50 && rsi[0] > rsi[1] && rsi[0] < RSI_Overbought);
}

bool CheckRSI_Bearish()
{
   if(rsiHandle == INVALID_HANDLE) return false;
   
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(rsiHandle, 0, 0, 2, rsi) < 2) return false;
   
   // RSI below 50 and falling = bearish momentum
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
   
   // MACD above signal and rising = bullish momentum
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
   
   // MACD below signal and falling = bearish momentum
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
   
   // Fast EMA crosses above Slow EMA (golden cross)
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
   
   // Fast EMA crosses below Slow EMA (death cross)
   bool crossed = (fastEMA[0] < slowEMA[0] && fastEMA[1] >= slowEMA[1]);
   bool priceBelow = (close[0] < fastEMA[0] && close[0] < slowEMA[0]);
   
   return (crossed || priceBelow);
}

//===================== ENTRY SIGNAL CHECK =====================//

bool CheckEntrySignal(ENUM_POSITION_TYPE &dir)
{
   // 1. Basic filters
   if(!IsValidSession()) return false;
   if(!IsSpreadOK()) return false;
   
   // 2. Check minimum bars since last entry
   if(lastEntryTime > 0)
   {
      int barsSinceEntry = iBarShift(_Symbol, EntryTimeframe, lastEntryTime);
      if(barsSinceEntry < MinBarsAfterEntry) return false;
   }
   
   // 3. HTF Trend (must be clear)
   bool htfBullish = IsTrendBullish_HTF();
   bool htfBearish = IsTrendBearish_HTF();
   
   if(!htfBullish && !htfBearish)
   {
      if(DebugMode)
      {
         static datetime lastLog = 0;
         if(TimeCurrent() - lastLog > 300)
         {
            Print("❌ Entry blocked: No clear HTF trend");
            lastLog = TimeCurrent();
         }
      }
      return false;
   }
   
   // 4. Entry TF momentum confirmations
   bool rsiBullish = CheckRSI_Bullish();
   bool rsiBearish = CheckRSI_Bearish();
   bool macdBullish = CheckMACD_Bullish();
   bool macdBearish = CheckMACD_Bearish();
   bool emaBullish = CheckEMA_Bullish_Entry();
   bool emaBearish = CheckEMA_Bearish_Entry();
   
   // 5. BUY Signal: HTF bullish + Entry TF confirmations
   if(htfBullish && emaBullish && (rsiBullish || macdBullish))
   {
      dir = POSITION_TYPE_BUY;
      if(DebugMode)
         Print("✅ BUY Signal: HTF bullish + EMA/RSI/MACD confirmation");
      return true;
   }
   
   // 6. SELL Signal: HTF bearish + Entry TF confirmations
   if(htfBearish && emaBearish && (rsiBearish || macdBearish))
   {
      dir = POSITION_TYPE_SELL;
      if(DebugMode)
         Print("✅ SELL Signal: HTF bearish + EMA/RSI/MACD confirmation");
      return true;
   }
   
   return false;
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
   
   // Calculate stop loss (wider for flexibility)
   if(isBuy)
   {
      sl = entry - (atrValue * ATR_Multiplier_SL);
      // TP only if enabled, otherwise 0 (let trailing stop handle exit)
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

ulong OpenTrade(ENUM_POSITION_TYPE dir)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return 0;
   
   double entry = (dir == POSITION_TYPE_BUY) ? tick.ask : tick.bid;
   double sl, tp;
   CalculateSLTP(entry, (dir == POSITION_TYPE_BUY), sl, tp);
   
   // SL must be valid, TP can be 0 if UseTakeProfit is false
   if(sl <= 0) return 0;
   if(UseTakeProfit && tp <= 0) return 0;
   
   double slDistancePips = MathAbs(entry - sl) / PipPoint();
   double lot = CalcLot(slDistancePips);
   
   trade.SetExpertMagicNumber(MagicNumber);
   
   bool ok = (dir == POSITION_TYPE_BUY) ?
             trade.Buy(lot, _Symbol, entry, sl, tp, "Momentum-JPY") :
             trade.Sell(lot, _Symbol, entry, sl, tp, "Momentum-JPY");
   
   if(!ok)
   {
      Print("❌ Trade failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      return 0;
   }
   
   ulong ticket = trade.ResultOrder();
   string tpStr = (tp > 0) ? DoubleToString(tp, 5) : "None (trailing stop exit)";
   Print("✅ Trade opened: ", (dir == POSITION_TYPE_BUY ? "BUY" : "SELL"), " Ticket: ", ticket, " Lot: ", lot, " Entry: ", entry, " SL: ", sl, " TP: ", tpStr);
   
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
   
   // Check if already at or above breakeven
   double pipPoint = PipPoint();
   double slDistanceFromEntry = MathAbs(posSL - posPriceOpen) / pipPoint;
   if(slDistanceFromEntry <= 5.0) return; // Already at breakeven or better
   
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
   
   // Check if profit reached threshold to move to breakeven
   if(profit >= breakevenThreshold)
   {
      // Move SL to breakeven (entry price + small buffer for spread)
      double spreadBuffer = 3.0 * pipPoint; // Small buffer for spread
      double newSL = 0;
      if(posType == POSITION_TYPE_BUY)
         newSL = posPriceOpen + spreadBuffer; // Slightly above entry
      else
         newSL = posPriceOpen - spreadBuffer; // Slightly below entry
      
      // Only update if new SL is better than current SL
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
               Print("🔒 Breakeven stop set: Ticket=", currentTicket, " SL=", newSL, " (Entry=", posPriceOpen, ")");
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
   
   if(profit <= 0) return; // Only trail when in profit
   
   double atrValue = atr[0];
   double trailingDistance = atrValue * TrailingStop_ATR; // Wider distance (2.5 ATR default)
   double trailingStep = atrValue * TrailingStep_ATR; // Bigger step (1.0 ATR default = less frequent updates)
   
   double newSL = 0;
   bool shouldUpdate = false;
   
   if(posType == POSITION_TYPE_BUY)
   {
      newSL = currentPrice - trailingDistance;
      // Only update if new SL is significantly better (prevents overtightening)
      if(newSL > posSL + trailingStep) shouldUpdate = true;
   }
   else
   {
      newSL = currentPrice + trailingDistance;
      // Only update if new SL is significantly better
      if(posSL == 0 || newSL < posSL - trailingStep) shouldUpdate = true;
   }
   
   if(shouldUpdate && newSL > 0)
   {
      // Don't move SL below breakeven for long positions, or above breakeven for short positions
      double pipPoint = PipPoint();
      double slDistanceFromEntry = MathAbs(newSL - posPriceOpen) / pipPoint;
      double entryDistance = 5.0 * pipPoint; // Small buffer
      
      if(posType == POSITION_TYPE_BUY && newSL < posPriceOpen - entryDistance) return; // Don't move below entry
      if(posType == POSITION_TYPE_SELL && newSL > posPriceOpen + entryDistance) return; // Don't move above entry
      
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      newSL = NormalizeDouble(newSL, digits);
      if(trade.PositionModify(currentTicket, newSL, posTP))
      {
         if(DebugMode)
            Print("📈 Trailing stop updated: Ticket=", currentTicket, " New SL=", newSL, " (", DoubleToString((currentPrice - newSL) / pipPoint, 1), " pips away)");
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
   
   currentTicket = 0;
   currentDirection = WRONG_VALUE;
   currentSL = 0;
   currentTP = 0;
   highestProfit = 0;
   lastEntryTime = 0;
   lastBarTime = 0;
   
   SyncPositionState();
   
   Print("========================================");
   Print("Momentum Strategy EA for JPY Pairs v3.00");
   Print("Strategy: EMA + RSI + MACD (Longer Holds)");
   Print("HTF: ", EnumToString(HTF_Timeframe));
   Print("Entry TF: ", EnumToString(EntryTimeframe));
   Print("Session: ", (UseSessionFilter ? "Asian (22:00-9:00 GMT)" : "All"));
   Print("Min Lot: ", MinLotSize);
   Print("SL: ATR × ", ATR_Multiplier_SL, " | TP: ", (UseTakeProfit ? "ATR × " + DoubleToString(ATR_Multiplier_TP, 1) : "Disabled (trailing stop exit)"));
   Print("Trailing Stop: ", (UseTrailingStop ? "ON (ATR × " + DoubleToString(TrailingStop_ATR, 1) + ")" : "OFF"));
   Print("Breakeven: ", (UseBreakeven ? "ON (after ATR × " + DoubleToString(Breakeven_ATR_Profit, 1) + " profit)" : "OFF"));
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
   
   Print("EA deinitialized. Reason: ", reason);
}

//===================== ONTICK =====================//

void OnTick()
{
   // Check for new bar (entry signals only on new bar)
   datetime currentBarTime = iTime(_Symbol, EntryTimeframe, 0);
   bool isNewBar = (currentBarTime != lastBarTime);
   
   // Sync position state
   SyncPositionState();
   
   // Manage existing position
   if(currentTicket > 0 && PositionSelectByTicket(currentTicket))
   {
      UpdateBreakevenStop(); // First move to breakeven when profit threshold reached
      UpdateTrailingStop();  // Then trail the stop to lock in profits
      return; // Don't open new trades while one is open
   }
   
   // Check for entry signal (only on new bar)
   if(isNewBar && !HasExistingPosition())
   {
      lastBarTime = currentBarTime;
      ENUM_POSITION_TYPE dir = WRONG_VALUE;
      if(CheckEntrySignal(dir))
      {
         currentTicket = OpenTrade(dir);
         if(currentTicket > 0)
         {
            currentDirection = dir;
            lastEntryTime = TimeCurrent();
            SyncPositionState();
         }
      }
   }
}
//+------------------------------------------------------------------+
