//+------------------------------------------------------------------+
//|         Pure Momentum Scalper - ICT Strategy for USDJPY          |
//|              HTF Bias + Order Blocks + FVG Confluence            |
//|                       © Gibson 2025                                |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "2.00"

#include <Trade\Trade.mqh>
CTrade trade;

//===================== ICT STRATEGY INPUTS =====================//
input group "===== ICT Strategy Settings ====="
input ENUM_TIMEFRAMES HTF_Timeframe = PERIOD_M15;  // Higher timeframe for bias (M15 or H1)
input ENUM_TIMEFRAMES EntryTimeframe = PERIOD_M1;  // Entry timeframe (M1 or M5)
input bool UseSessionFilter = true;                // Trade London + NY only
input double MaxSpreadPips = 3.0;                  // Maximum spread filter (USDJPY)
input double MinRiskReward = 2.0;                  // Minimum RR for TP
input bool UseLiquidityTP = true;                  // Use liquidity targets (previous highs/lows)
input bool UsePyramid = false;                      // Enable pyramid system
input int LookbackBars = 50;                       // Bars to look back for structure

input group "===== Risk Management ====="
input int    MagicNumber   = 202501;               // Magic Number
input double RiskPercent   = 0.5;                  // Risk % per trade
input double MinLotSize    = 0.05;                // Minimum lot size override
input int    P1 = 10;                              // Pyramid level 1 (if enabled)
input int    P2 = 20;                              // Pyramid level 2
input int    P3 = 30;                              // Pyramid level 3
input int    P4 = 40;                              // Pyramid level 4

//===================== BIAS TYPE =====================//
enum BIAS_TYPE {
   BIAS_NONE = 0,
   BIAS_BULLISH = 1,
   BIAS_BEARISH = 2
};

//===================== ORDER BLOCK STRUCTURE =====================//
struct OrderBlock {
   datetime time;
   double high;
   double low;
   bool bullish;      // true = bullish OB, false = bearish OB
   bool mitigated;
   bool valid;        // has BOS + FVG
   int barIndex;      // Bar index where OB was found
};

//===================== FVG ZONE STRUCTURE =====================//
struct FVGZone {
   datetime time;
   double top;
   double bottom;
   bool bullish;      // true = bullish FVG
   bool mitigated;
   int barIndex;       // Bar index where FVG was found
};

//===================== INTERNAL STATE =====================//
BIAS_TYPE currentBias = BIAS_NONE;
OrderBlock activeOB;
FVGZone activeFVG;
bool obDetected = false;
bool fvgDetected = false;

ulong t1, t2, t3, t4, t5;    // trade tickets
ENUM_POSITION_TYPE direction = WRONG_VALUE;
double entry1;
double entrySL = 0;
double entryTP = 0;

int atrHandle = INVALID_HANDLE;
int htfMAHandle = INVALID_HANDLE;

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
   if(slDistancePips <= 0) slDistancePips = 50; // Default fallback
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (RiskPercent / 100.0);
   double pipVal = PipValue();
   
   if(pipVal <= 0) return MinLotSize;
   
   double lot = riskMoney / (slDistancePips * pipVal);
   
   if(lot < MinLotSize) lot = MinLotSize;
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   if(lotStep > 0) lot = MathFloor(lot / lotStep) * lotStep;
   
   return NormalizeDouble(lot, 2);
}

//===================== HTF BIAS DETECTION =====================//

BIAS_TYPE DetectHTFBias(ENUM_TIMEFRAMES htf)
{
   // Get recent swing highs and lows
   double highs[];
   double lows[];
   datetime times[];
   
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   ArraySetAsSeries(times, true);
   
   int bars = MathMin(LookbackBars, 100);
   if(CopyHigh(_Symbol, htf, 0, bars, highs) <= 0) return BIAS_NONE;
   if(CopyLow(_Symbol, htf, 0, bars, lows) <= 0) return BIAS_NONE;
   if(CopyTime(_Symbol, htf, 0, bars, times) <= 0) return BIAS_NONE;
   
   // Find recent swing highs and lows (simplified: look for local extremes)
   double lastHigh = 0, lastLow = 0;
   double prevHigh = 0, prevLow = 0;
   int highIdx = -1, lowIdx = -1;
   
   // Find last significant high and low
   for(int i = 2; i < bars - 2; i++)
   {
      // Check for swing high
      if(highs[i] > highs[i-1] && highs[i] > highs[i-2] && 
         highs[i] > highs[i+1] && highs[i] > highs[i+2])
      {
         if(lastHigh == 0 || highs[i] > lastHigh)
         {
            prevHigh = lastHigh;
            lastHigh = highs[i];
            highIdx = i;
         }
      }
      
      // Check for swing low
      if(lows[i] < lows[i-1] && lows[i] < lows[i-2] && 
         lows[i] < lows[i+1] && lows[i] < lows[i+2])
      {
         if(lastLow == 0 || lows[i] < lastLow)
         {
            prevLow = lastLow;
            lastLow = lows[i];
            lowIdx = i;
         }
      }
   }
   
   if(lastHigh == 0 || lastLow == 0) return BIAS_NONE;
   
   // Bullish bias: Higher High + Higher Low
   if(prevHigh > 0 && prevLow > 0)
   {
      if(lastHigh > prevHigh && lastLow > prevLow)
      {
         Print("HTF BIAS: BULLISH detected (HH + HL)");
         return BIAS_BULLISH;
      }
   }
   
   // Bearish bias: Lower High + Lower Low
   if(prevHigh > 0 && prevLow > 0)
   {
      if(lastHigh < prevHigh && lastLow < prevLow)
      {
         Print("HTF BIAS: BEARISH detected (LH + LL)");
         return BIAS_BEARISH;
      }
   }
   
   return BIAS_NONE;
}

//===================== FVG DETECTION =====================//

bool DetectFVG(FVGZone &fvg, ENUM_TIMEFRAMES tf)
{
   double high[], low[], open[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(close, true);
   
   if(CopyHigh(_Symbol, tf, 0, 5, high) < 5) return false;
   if(CopyLow(_Symbol, tf, 0, 5, low) < 5) return false;
   if(CopyOpen(_Symbol, tf, 0, 5, open) < 5) return false;
   if(CopyClose(_Symbol, tf, 0, 5, close) < 5) return false;
   
   // Bullish FVG: Candle 1 high < Candle 3 low
   if(high[2] < low[0])
   {
      fvg.bullish = true;
      fvg.top = MathMax(high[1], high[2]);
      fvg.bottom = MathMin(low[0], low[1]);
      fvg.time = iTime(_Symbol, tf, 1);
      fvg.barIndex = 1;
      fvg.mitigated = false;
      
      Print("BULLISH FVG detected: Top=", fvg.top, " Bottom=", fvg.bottom);
      return true;
   }
   
   // Bearish FVG: Candle 1 low > Candle 3 high
   if(low[2] > high[0])
   {
      fvg.bullish = false;
      fvg.top = MathMax(high[0], high[1]);
      fvg.bottom = MathMin(low[1], low[2]);
      fvg.time = iTime(_Symbol, tf, 1);
      fvg.barIndex = 1;
      fvg.mitigated = false;
      
      Print("BEARISH FVG detected: Top=", fvg.top, " Bottom=", fvg.bottom);
      return true;
   }
   
   return false;
}

//===================== ORDER BLOCK DETECTION =====================//

bool DetectOrderBlock(OrderBlock &ob, BIAS_TYPE bias, ENUM_TIMEFRAMES tf)
{
   if(bias == BIAS_NONE) return false;
   
   double high[], low[], open[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(close, true);
   
   int lookback = 20;
   if(CopyHigh(_Symbol, tf, 0, lookback, high) < lookback) return false;
   if(CopyLow(_Symbol, tf, 0, lookback, low) < lookback) return false;
   if(CopyOpen(_Symbol, tf, 0, lookback, open) < lookback) return false;
   if(CopyClose(_Symbol, tf, 0, lookback, close) < lookback) return false;
   
   // For bullish bias: find last bearish candle before bullish impulse
   if(bias == BIAS_BULLISH)
   {
      for(int i = 3; i < lookback - 3; i++)
      {
         // Check if candle i is bearish
         if(close[i] < open[i])
         {
            // Check for bullish impulse after (BOS)
            bool hasImpulse = false;
            double impulseStart = low[i];
            
            for(int j = i - 1; j >= 0; j--)
            {
               if(close[j] > open[j] && high[j] > high[i+1])
               {
                  // Check if impulse creates FVG
                  if(j >= 2 && high[i+1] < low[j-1]) // Bullish FVG pattern
                  {
                     hasImpulse = true;
                     break;
                  }
               }
            }
            
            if(hasImpulse)
            {
               ob.bullish = true;
               ob.high = high[i];
               ob.low = low[i];
               ob.time = iTime(_Symbol, tf, i);
               ob.barIndex = i;
               ob.mitigated = false;
               ob.valid = true;
               
               Print("BULLISH ORDER BLOCK detected at bar ", i, " High=", ob.high, " Low=", ob.low);
               return true;
            }
         }
      }
   }
   
   // For bearish bias: find last bullish candle before bearish impulse
   if(bias == BIAS_BEARISH)
   {
      for(int i = 3; i < lookback - 3; i++)
      {
         // Check if candle i is bullish
         if(close[i] > open[i])
         {
            // Check for bearish impulse after (BOS)
            bool hasImpulse = false;
            
            for(int j = i - 1; j >= 0; j--)
            {
               if(close[j] < open[j] && low[j] < low[i+1])
               {
                  // Check if impulse creates FVG
                  if(j >= 2 && low[i+1] > high[j-1]) // Bearish FVG pattern
                  {
                     hasImpulse = true;
                     break;
                  }
               }
            }
            
            if(hasImpulse)
            {
               ob.bullish = false;
               ob.high = high[i];
               ob.low = low[i];
               ob.time = iTime(_Symbol, tf, i);
               ob.barIndex = i;
               ob.mitigated = false;
               ob.valid = true;
               
               Print("BEARISH ORDER BLOCK detected at bar ", i, " High=", ob.high, " Low=", ob.low);
               return true;
            }
         }
      }
   }
   
   return false;
}

//===================== CHECK OB + FVG CONFLUENCE =====================//

bool CheckOBFVGConfluence(OrderBlock &ob, FVGZone &fvg, BIAS_TYPE bias)
{
   if(!ob.valid || bias == BIAS_NONE) return false;
   
   // Check if OB and FVG overlap
   bool overlaps = (ob.low <= fvg.top && ob.high >= fvg.bottom);
   
   if(!overlaps) return false;
   
   // Check if price is retracing into OB (50-100% of OB range)
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;
   
   double currentPrice = (bias == BIAS_BULLISH) ? tick.bid : tick.ask;
   double obRange = ob.high - ob.low;
   double obMid = (ob.high + ob.low) / 2.0;
   
   if(bias == BIAS_BULLISH)
   {
      // Price should be in OB range or retracing into it
      bool inOB = (currentPrice >= ob.low && currentPrice <= ob.high);
      bool retracing = (currentPrice <= ob.high && currentPrice >= obMid);
      
      if(inOB || retracing)
      {
         Print("OB + FVG CONFLUENCE: Price retracing into bullish OB+FVG");
         return true;
      }
   }
   else // BEARISH
   {
      bool inOB = (currentPrice >= ob.low && currentPrice <= ob.high);
      bool retracing = (currentPrice >= ob.low && currentPrice <= obMid);
      
      if(inOB || retracing)
      {
         Print("OB + FVG CONFLUENCE: Price retracing into bearish OB+FVG");
         return true;
      }
   }
   
   return false;
}

//===================== CHECK IF OB IS MITIGATED =====================//

bool IsOBMitigated(OrderBlock &ob)
{
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   int bars = 20;
   if(CopyHigh(_Symbol, EntryTimeframe, 0, bars, high) < bars) return false;
   if(CopyLow(_Symbol, EntryTimeframe, 0, bars, low) < bars) return false;
   
   // Check if price has closed through OB
   for(int i = 0; i < bars; i++)
   {
      if(ob.bullish)
      {
         // Bullish OB mitigated if price closes below OB low
         if(low[i] < ob.low) return true;
      }
      else
      {
         // Bearish OB mitigated if price closes above OB high
         if(high[i] > ob.high) return true;
      }
   }
   
   return false;
}

//===================== CALCULATE SL (OB EXTREME + BUFFER) =====================//

double CalculateSL(OrderBlock &ob, bool isBuy)
{
   if(atrHandle == INVALID_HANDLE) return 0;
   
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) <= 0) return 0;
   
   double buffer = atr[0] * 0.2;
   double pipPoint = PipPoint();
   double bufferPips = 3.0; // Additional 3 pip buffer
   
   if(isBuy)
   {
      // SL below OB low
      return ob.low - buffer - (bufferPips * pipPoint);
   }
   else
   {
      // SL above OB high
      return ob.high + buffer + (bufferPips * pipPoint);
   }
}

//===================== CALCULATE TP (LIQUIDITY OR RR) =====================//

double CalculateTP(double entry, double sl, bool isBuy, double &slDistancePips)
{
   double pipPoint = PipPoint();
   slDistancePips = MathAbs(entry - sl) / pipPoint;
   
   if(UseLiquidityTP)
   {
      // Find nearest liquidity (previous high/low)
      double high[], low[];
      ArraySetAsSeries(high, true);
      ArraySetAsSeries(low, true);
      
      int bars = 50;
      if(CopyHigh(_Symbol, HTF_Timeframe, 0, bars, high) < bars) return 0;
      if(CopyLow(_Symbol, HTF_Timeframe, 0, bars, low) < bars) return 0;
      
      if(isBuy)
      {
         // Find nearest resistance (previous high)
         double nearestHigh = 0;
         for(int i = 1; i < bars; i++)
         {
            if(high[i] > entry && (nearestHigh == 0 || high[i] < nearestHigh))
            {
               nearestHigh = high[i];
            }
         }
         
         if(nearestHigh > 0)
         {
            double tpDistancePips = (nearestHigh - entry) / pipPoint;
            if(tpDistancePips >= slDistancePips * MinRiskReward)
            {
               Print("TP at liquidity (previous high): ", nearestHigh, " RR: ", tpDistancePips / slDistancePips);
               return nearestHigh;
            }
         }
      }
      else // SELL
      {
         // Find nearest support (previous low)
         double nearestLow = 0;
         for(int i = 1; i < bars; i++)
         {
            if(low[i] < entry && (nearestLow == 0 || low[i] > nearestLow))
            {
               nearestLow = low[i];
            }
         }
         
         if(nearestLow > 0)
         {
            double tpDistancePips = (entry - nearestLow) / pipPoint;
            if(tpDistancePips >= slDistancePips * MinRiskReward)
            {
               Print("TP at liquidity (previous low): ", nearestLow, " RR: ", tpDistancePips / slDistancePips);
               return nearestLow;
            }
         }
      }
   }
   
   // Fallback to fixed RR
   double tpDistancePips = slDistancePips * MinRiskReward;
   if(isBuy)
      return entry + (tpDistancePips * pipPoint);
   else
      return entry - (tpDistancePips * pipPoint);
}

//===================== SESSION FILTER =====================//

bool IsValidSession()
{
   if(!UseSessionFilter) return true;
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   
   // London: 8-16 GMT, NY: 13-21 GMT
   bool london = (hour >= 8 && hour < 16);
   bool ny = (hour >= 13 && hour < 21);
   
   return (london || ny);
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

//===================== ENTRY SIGNAL CHECK =====================//

bool CheckEntrySignal(ENUM_POSITION_TYPE &dir)
{
   // 1. Check filters
   if(!IsValidSession())
   {
      static datetime lastLog = 0;
      if(TimeCurrent() - lastLog > 300)
      {
         Print("Entry blocked: Outside trading session");
         lastLog = TimeCurrent();
      }
      return false;
   }
   
   if(!IsSpreadOK())
   {
      static datetime lastLog = 0;
      if(TimeCurrent() - lastLog > 300)
      {
         Print("Entry blocked: Spread too high");
         lastLog = TimeCurrent();
      }
      return false;
   }
   
   // 2. Check HTF bias
   currentBias = DetectHTFBias(HTF_Timeframe);
   if(currentBias == BIAS_NONE) return false;
   
   // 3. Detect Order Block
   if(!DetectOrderBlock(activeOB, currentBias, HTF_Timeframe))
   {
      obDetected = false;
      return false;
   }
   obDetected = true;
   
   // 4. Check if OB is mitigated
   if(IsOBMitigated(activeOB))
   {
      Print("Order Block mitigated, waiting for new OB");
      obDetected = false;
      return false;
   }
   
   // 5. Detect FVG
   if(!DetectFVG(activeFVG, EntryTimeframe))
   {
      fvgDetected = false;
      return false;
   }
   fvgDetected = true;
   
   // 6. Check OB + FVG confluence
   if(!CheckOBFVGConfluence(activeOB, activeFVG, currentBias))
   {
      return false;
   }
   
   // 7. Set direction based on bias
   if(currentBias == BIAS_BULLISH)
      dir = POSITION_TYPE_BUY;
   else
      dir = POSITION_TYPE_SELL;
   
   Print("ENTRY SIGNAL CONFIRMED: ", (dir == POSITION_TYPE_BUY ? "BUY" : "SELL"),
         " | OB+FVG Confluence | HTF Bias: ", EnumToString(currentBias));
   
   return true;
}

//===================== OPEN TRADE =====================//

ulong Open(ENUM_POSITION_TYPE dir)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return 0;
   
   double price = (dir == POSITION_TYPE_BUY) ? tick.ask : tick.bid;
   
   // Calculate SL from OB
   double sl = CalculateSL(activeOB, (dir == POSITION_TYPE_BUY));
   if(sl <= 0) return 0;
   
   // Calculate TP
   double slDistancePips = 0;
   double tp = CalculateTP(price, sl, (dir == POSITION_TYPE_BUY), slDistancePips);
   if(tp <= 0) return 0;
   
   // Normalize prices
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   
   // Calculate lot size
   double lot = CalcLot(slDistancePips);
   
   trade.SetExpertMagicNumber(MagicNumber);
   
   bool ok = (dir == POSITION_TYPE_BUY) ?
             trade.Buy(lot, _Symbol, price, sl, tp, "ICT-USDJPY") :
             trade.Sell(lot, _Symbol, price, sl, tp, "ICT-USDJPY");
   
   if(!ok)
   {
      Print("Failed to open trade: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      return 0;
   }
   
   Print("Trade opened: ", (dir == POSITION_TYPE_BUY ? "BUY" : "SELL"),
         " Lot: ", lot, " Entry: ", price, " SL: ", sl, " TP: ", tp);
   
   // Get position ticket
   Sleep(100);
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if(posType != dir) continue;
         double posEntry = PositionGetDouble(POSITION_PRICE_OPEN);
         if(MathAbs(posEntry - price) < (20 * _Point))
         {
            entrySL = sl;
            entryTP = tp;
            return ticket;
         }
      }
   }
   
   return 0;
}

//===================== CHECK PYRAMIDS (OPTIONAL) =====================//

void CheckPyramids()
{
   if(!UsePyramid) return;
   
   if(t1 == 0 || direction == WRONG_VALUE)
   {
      t1 = t2 = t3 = t4 = t5 = 0;
      direction = WRONG_VALUE;
      return;
   }
   
   if(!PositionSelectByTicket(t1))
   {
      t1 = t2 = t3 = t4 = t5 = 0;
      direction = WRONG_VALUE;
      return;
   }
   
   if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
   {
      t1 = t2 = t3 = t4 = t5 = 0;
      direction = WRONG_VALUE;
      return;
   }
   
   double realEntry = PositionGetDouble(POSITION_PRICE_OPEN);
   double price = (direction == POSITION_TYPE_BUY) ?
                  SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double pips = (direction == POSITION_TYPE_BUY) ? 
                 (price - realEntry) / _Point :
                 (realEntry - price) / _Point;
   
   if(pips >= P1 && !PositionSelectByTicket(t2)) t2 = Open(direction);
   if(pips >= P2 && !PositionSelectByTicket(t3)) t3 = Open(direction);
   if(pips >= P3 && !PositionSelectByTicket(t4)) t4 = Open(direction);
   if(pips >= P4 && !PositionSelectByTicket(t5)) t5 = Open(direction);
}

//===================== CHECK BASKET TP (LIQUIDITY-BASED) =====================//

void CheckBasketTP()
{
   if(t1 == 0 || direction == WRONG_VALUE) return;
   
   // Check if any position hit TP (broker will close automatically)
   // Or check if combined profit meets target
   double totalProfit = 0;
   ulong tickets[5] = {t1, t2, t3, t4, t5};
   
   for(int i = 0; i < 5; i++)
   {
      if(tickets[i] > 0 && PositionSelectByTicket(tickets[i]))
      {
         if((ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            totalProfit += PositionGetDouble(POSITION_PROFIT) + 
                          PositionGetDouble(POSITION_SWAP);
            // POSITION_COMMISSION is deprecated, commission is included in POSITION_PROFIT
         }
      }
   }
   
   // If all positions closed (totalProfit == 0 and no positions), reset
   bool hasOpenPositions = false;
   for(int i = 0; i < 5; i++)
   {
      if(tickets[i] > 0 && PositionSelectByTicket(tickets[i]))
      {
         hasOpenPositions = true;
         break;
      }
   }
   
   if(!hasOpenPositions)
   {
      t1 = t2 = t3 = t4 = t5 = 0;
      direction = WRONG_VALUE;
      currentBias = BIAS_NONE;
      obDetected = false;
      fvgDetected = false;
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
   atrHandle = iATR(_Symbol, PERIOD_M1, 1);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR indicator");
      return INIT_FAILED;
   }
   
   // Initialize variables
   t1 = t2 = t3 = t4 = t5 = 0;
   direction = WRONG_VALUE;
   currentBias = BIAS_NONE;
   obDetected = false;
   fvgDetected = false;
   
   Print("========================================");
   Print("ICT Strategy EA for USDJPY initialized");
   Print("HTF Timeframe: ", EnumToString(HTF_Timeframe));
   Print("Entry Timeframe: ", EnumToString(EntryTimeframe));
   Print("Session Filter: ", (UseSessionFilter ? "ON" : "OFF"));
   Print("========================================");
   
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   
   Print("ICT Strategy EA deinitialized. Reason: ", reason);
}

//===================== ONTICK =====================//

void OnTick()
{
   // NO TRADE OPEN → check entry
   if(direction == WRONG_VALUE)
   {
      ENUM_POSITION_TYPE dir = WRONG_VALUE;
      if(CheckEntrySignal(dir))
      {
         t1 = Open(dir);
         if(t1 > 0 && PositionSelectByTicket(t1))
         {
            direction = dir;
            entry1 = PositionGetDouble(POSITION_PRICE_OPEN);
            Print("Trade 1 opened. Ticket: ", t1, " Entry: ", entry1);
         }
         else
         {
            direction = WRONG_VALUE;
            t1 = 0;
            Print("Trade open failed, will retry on next signal");
         }
         return;
      }
   }
   
   // If direction active → manage trades
   if(UsePyramid) CheckPyramids();
   CheckBasketTP();
}

//+------------------------------------------------------------------+
