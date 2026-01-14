//+------------------------------------------------------------------+
//| Hybrid Trend Pullback EA - Universal Multi-Instrument            |
//| Trend-following with pullback entries - High frequency trading   |
//+------------------------------------------------------------------+
#property copyright "Hybrid Trend Pullback - Universal"
#property version   "3.00"
#property description "Trend-following EA for all instruments (Majors, Minors, Gold)"
#property description "High frequency: 10-20 trades/hour with partial close at 2% capital profit"

#include <Trade/Trade.mqh>

CTrade trade;

// ===== Input Parameters =====
input group "===== Symbol & Timeframes ====="
input string   InpSymbol                = "";         // Trading symbol (empty = chart symbol)
input ENUM_TIMEFRAMES InpEntryTf        = PERIOD_M5;  // Entry timeframe
input ENUM_TIMEFRAMES InpTrendTf        = PERIOD_H1;  // Trend timeframe

input group "===== Trend Filter ====="
input int      InpFastEma               = 21;         // Fast EMA period
input int      InpSlowEma               = 50;         // Slow EMA period
input int      InpMinBarsAfterFlip      = 1;          // Bars to wait after trend flip (reduced for more trades)

input group "===== Entry Logic ====="
input int      InpEntryPullbackEma      = 21;         // Pullback EMA period
input double   InpPullbackAtrMult       = 0.70;       // Pullback tolerance (increased for more entries)
input double   InpMomentumAtrMult       = 0.15;       // Min candle body (reduced for more entries)
input double   InpMomentumRangeAtrMult  = 0.40;       // Min candle range (reduced for more entries)

input group "===== Volatility Filter ====="
input int      InpAtrPeriod             = 14;         // ATR period
input ENUM_TIMEFRAMES InpAtrTf          = PERIOD_M5;  // ATR timeframe
input double   InpMinAtrToSpread        = 1.5;        // ATR must be >= 1.5x spread (relaxed)
input double   InpMaxAtrPctOfPrice      = 0.0050;     // Block if ATR > 0.50% of price (universal)

input group "===== Risk Management ====="
input int      InpMagic                 = 202512;     // Magic number
input double   InpRiskPerTradePct       = 4.0;        // Risk per trade (3-5%)
input double   InpSlAtrMult             = 1.2;        // Stop Loss = 1.2x ATR
input double   InpTpAtrMult             = 2.4;        // Take Profit = 2.4x ATR (1:2 RR)
input double   InpMaxSpreadPips         = 10.0;       // Max spread filter (universal)

input group "===== Partial Close ====="
input bool     InpUsePartialClose       = true;       // Enable partial close
input double   InpPartialClosePct       = 60.0;       // Close 60% of position
input double   InpPartialCloseProfitPct = 2.0;         // Trigger at 2% capital profit

input group "===== Break-Even & Trailing ====="
input bool     InpUseBreakEven          = true;       // Enable break-even
input double   InpBreakEvenRR           = 1.0;        // Move to BE at 1:1 RR
input double   InpBreakEvenBufferPips   = 3.0;        // BE buffer
input bool     InpUseTrailing           = true;       // Enable trailing stop
input double   InpTrailStartRR          = 1.5;        // Start trailing at 1.5:1 RR
input double   InpTrailStepPips         = 5.0;        // Trailing step
input double   InpTrailAtrMult          = 0.5;        // Trailing distance (50% of ATR)

input group "===== Trading Limits ====="
input int      InpMaxPositions          = 20;         // Maximum concurrent positions
input int      InpMaxTradesPerHour      = 20;         // Maximum trades per hour

// ===== Global Variables =====
int g_emaFast = INVALID_HANDLE;
int g_emaSlow = INVALID_HANDLE;
int g_emaEntry = INVALID_HANDLE;
int g_atr = INVALID_HANDLE;

string g_symbol = "";
datetime g_lastEntryBar = 0;
int g_lastBias = 0;
int g_barsSinceFlip = 0;
datetime g_tradeTimes[];
double g_initialCapital = 0.0;

// ===== Utility Functions =====
double PipFactor()
{
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   return (digits == 3 || digits == 5) ? 10.0 : 1.0;
}

double SpreadPips(const MqlTick &tick)
{
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   return ((tick.ask - tick.bid) / point) / PipFactor();
}

double NormalizePrice(double price)
{
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

double PointsFromPips(double pips)
{
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   return pips * point * PipFactor();
}

bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastTime)
{
   datetime t[1];
   if(CopyTime(g_symbol, tf, 0, 1, t) <= 0)
      return false;
   if(lastTime != t[0])
   {
      lastTime = t[0];
      return true;
   }
   return false;
}

bool SpreadOk(const MqlTick &tick)
{
   return SpreadPips(tick) <= InpMaxSpreadPips;
}

// ===== Trend Bias Detection =====
int GetTrendBias()
{
   double fast[1], slow[1];
   if(CopyBuffer(g_emaFast, 0, 1, 1, fast) <= 0) return 0;
   if(CopyBuffer(g_emaSlow, 0, 1, 1, slow) <= 0) return 0;

   int bias = 0;
   if(fast[0] > slow[0]) bias = 1;
   else if(fast[0] < slow[0]) bias = -1;

   if(bias != g_lastBias)
   {
      g_barsSinceFlip = 0;
      g_lastBias = bias;
   }
   g_barsSinceFlip++;

   if(g_barsSinceFlip <= InpMinBarsAfterFlip)
      return 0;

   return bias;
}

// ===== Volatility Check =====
bool CheckVolatility(double &atr, const MqlTick &tick)
{
   if(g_atr == INVALID_HANDLE) return false;
   double atrBuffer[1];
   if(CopyBuffer(g_atr, 0, 1, 1, atrBuffer) <= 0) return false;
   atr = atrBuffer[0];
   if(atr <= 0.0) return false;

   double spreadPips = SpreadPips(tick);
   if(spreadPips <= 0.0) return false;

   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   double atrPips = atr / (point * PipFactor());

   if(atrPips < InpMinAtrToSpread * spreadPips)
      return false;

   double mid = (tick.ask + tick.bid) * 0.5;
   if(mid > 0.0 && (atr / mid) > InpMaxAtrPctOfPrice)
      return false;

   return true;
}

// ===== Momentum Check =====
bool MomentumOk(double atr)
{
   double open[1], close[1], high[1], low[1];
   
   if(CopyOpen(g_symbol, InpEntryTf, 1, 1, open) <= 0) return false;
   if(CopyClose(g_symbol, InpEntryTf, 1, 1, close) <= 0) return false;
   if(CopyHigh(g_symbol, InpEntryTf, 1, 1, high) <= 0) return false;
   if(CopyLow(g_symbol, InpEntryTf, 1, 1, low) <= 0) return false;

   double body = MathAbs(close[0] - open[0]);
   double range = high[0] - low[0];

   if(range < atr * InpMomentumRangeAtrMult) return false;
   if(body < atr * InpMomentumAtrMult) return false;
   return true;
}

// ===== Entry Signal Building =====
bool BuildEntry(ENUM_ORDER_TYPE &type, double &entryPrice, double &sl, double &tp, const MqlTick &tick)
{
   double atr = 0.0;
   if(!CheckVolatility(atr, tick)) return false;

   int bias = GetTrendBias();
   if(bias == 0) return false;

   double emaEntryBuffer[1];
   if(CopyBuffer(g_emaEntry, 0, 1, 1, emaEntryBuffer) <= 0) return false;
   double emaEntry = emaEntryBuffer[0];

   double closePrice[1], openPrice[1];
   if(CopyClose(g_symbol, InpEntryTf, 1, 1, closePrice) <= 0) return false;
   if(CopyOpen(g_symbol, InpEntryTf, 1, 1, openPrice) <= 0) return false;

   double pullbackDist = atr * InpPullbackAtrMult;
   bool pullbackOk = false;
   bool momentumOk = MomentumOk(atr);
   bool dirOk = false;

   if(bias == 1)
   {
      pullbackOk = (closePrice[0] <= emaEntry + pullbackDist);
      dirOk = (closePrice[0] > openPrice[0]);
      type = ORDER_TYPE_BUY;
      entryPrice = tick.ask;
   }
   else
   {
      pullbackOk = (closePrice[0] >= emaEntry - pullbackDist);
      dirOk = (closePrice[0] < openPrice[0]);
      type = ORDER_TYPE_SELL;
      entryPrice = tick.bid;
   }

   if(!(pullbackOk && momentumOk && dirOk))
      return false;

   double stopDist = atr * InpSlAtrMult;
   double takeDist = atr * InpTpAtrMult;

   if(type == ORDER_TYPE_BUY)
   {
      sl = NormalizePrice(entryPrice - stopDist);
      tp = NormalizePrice(entryPrice + takeDist);
   }
   else
   {
      sl = NormalizePrice(entryPrice + stopDist);
      tp = NormalizePrice(entryPrice - takeDist);
   }

   return true;
}

// ===== Position Count & Limits =====
int CountPositions()
{
   int count = 0;
   int total = (int)PositionsTotal();
   int i;
   for(i = 0; i < total; i++)
   {
      if(!PositionSelectByIndex(i)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) == g_symbol)
         count++;
   }
   return count;
}

int CountTradesLastHour()
{
   datetime now = TimeCurrent();
   datetime oneHourAgo = now - 3600;
   int count = 0;
   
   int size = ArraySize(g_tradeTimes);
   for(int i = size - 1; i >= 0; i--)
   {
      if(g_tradeTimes[i] >= oneHourAgo)
         count++;
      else
         break;
   }
   return count;
}

void AddTradeTime()
{
   int size = ArraySize(g_tradeTimes);
   ArrayResize(g_tradeTimes, size + 1);
   g_tradeTimes[size] = TimeCurrent();
}

// ===== Position Management =====
double CurrentRR(ENUM_POSITION_TYPE type, double entry, double sl, double price)
{
   double riskDist = MathAbs(entry - sl);
   double profitDist = MathAbs(price - entry);
   if(riskDist <= 0.0) return 0.0;
   
   double rr = profitDist / riskDist;
   if((type == POSITION_TYPE_BUY && price < entry) || (type == POSITION_TYPE_SELL && price > entry))
      rr = -rr;
   return rr;
}

double GetPositionProfitPct()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0 || g_initialCapital <= 0.0) return 0.0;
   return ((balance - g_initialCapital) / g_initialCapital) * 100.0;
}

void ManagePosition()
{
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return;

   int total = (int)PositionsTotal();
   int i;
   for(i = 0; i < total; i++)
   {
      if(!PositionSelectByIndex(i)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double price = (type == POSITION_TYPE_BUY) ? tick.bid : tick.ask;

      double atr = 0.0;
      if(g_atr != INVALID_HANDLE)
      {
         double atrBuffer[1];
         if(CopyBuffer(g_atr, 0, 0, 1, atrBuffer) > 0)
            atr = atrBuffer[0];
      }

      // Partial close at 2% capital profit
      if(InpUsePartialClose)
      {
         double profitPct = GetPositionProfitPct();
         if(profitPct >= InpPartialCloseProfitPct)
         {
            double closeVolume = NormalizeDouble(volume * (InpPartialClosePct / 100.0), 2);
            double minLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
            if(closeVolume >= minLot && closeVolume < volume)
            {
               if(trade.PositionClosePartial(ticket, closeVolume))
               {
                  Print("PARTIAL CLOSE: ", closeVolume, " of ", volume, " at ", profitPct, "% capital profit");
               }
            }
         }
      }

      double rr = CurrentRR(type, entry, sl, price);

      // Break-even
      if(InpUseBreakEven && rr >= InpBreakEvenRR)
      {
         double bePrice = entry + (type == POSITION_TYPE_BUY ? 1 : -1) * PointsFromPips(InpBreakEvenBufferPips);
         bool shouldMove = false;
         if(type == POSITION_TYPE_BUY && (sl < bePrice || sl == 0.0))
            shouldMove = true;
         else if(type == POSITION_TYPE_SELL && (sl > bePrice || sl == 0.0))
            shouldMove = true;

         if(shouldMove)
         {
            trade.PositionModify(ticket, NormalizePrice(bePrice), tp);
         }
      }

      // Trailing stop
      if(InpUseTrailing && rr >= InpTrailStartRR)
      {
         double trailByPrice = PointsFromPips(InpTrailStepPips);
         double trailByAtr   = (atr > 0.0) ? atr * InpTrailAtrMult : 0.0;
         double trailDist    = MathMax(trailByPrice, trailByAtr);
         double newSl        = (type == POSITION_TYPE_BUY) ? price - trailDist : price + trailDist;

         bool shouldTrail = false;
         if(type == POSITION_TYPE_BUY && newSl > sl)
            shouldTrail = true;
         else if(type == POSITION_TYPE_SELL && (sl == 0.0 || newSl < sl))
            shouldTrail = true;

         if(shouldTrail)
         {
            trade.PositionModify(ticket, NormalizePrice(newSl), tp);
         }
      }
   }
}

// ===== Volume Calculation =====
double CalcVolumeByRisk(ENUM_ORDER_TYPE orderType, double entryPrice, double stopPrice)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPerTradePct / 100.0);
   double simLoss = 0.0;
   
   if(!OrderCalcProfit(orderType, g_symbol, 1.0, entryPrice, stopPrice, simLoss))
      return 0.0;
   if(simLoss == 0.0) return 0.0;

   double vol = riskMoney / MathAbs(simLoss);
   double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);

   vol = MathFloor(vol / step) * step;
   if(vol < minLot) vol = minLot;
   if(vol > maxLot) vol = maxLot;
   return NormalizeDouble(vol, 2);
}

// ===== Initialization =====
int OnInit()
{
   // Determine symbol
   if(InpSymbol == "" || InpSymbol == NULL)
      g_symbol = _Symbol;
   else
      g_symbol = InpSymbol;

   // Normalize symbol name (handles extensions like .z, .a automatically)
   // MT5 handles symbol extensions automatically, so we just use the symbol as-is
   
   if(!SymbolSelect(g_symbol, true))
   {
      Print("ERROR: Cannot select symbol: ", g_symbol);
      return INIT_FAILED;
   }

   // Initialize indicators
   g_emaFast = iMA(g_symbol, InpTrendTf, InpFastEma, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlow = iMA(g_symbol, InpTrendTf, InpSlowEma, 0, MODE_EMA, PRICE_CLOSE);
   g_emaEntry = iMA(g_symbol, InpEntryTf, InpEntryPullbackEma, 0, MODE_EMA, PRICE_CLOSE);
   g_atr = iATR(g_symbol, InpAtrTf, InpAtrPeriod);

   if(g_emaFast == INVALID_HANDLE || g_emaSlow == INVALID_HANDLE || 
      g_emaEntry == INVALID_HANDLE || g_atr == INVALID_HANDLE)
   {
      Print("ERROR: Failed to initialize indicators");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   g_initialCapital = AccountInfoDouble(ACCOUNT_BALANCE);
   ArrayResize(g_tradeTimes, 0);

   Print("=== Hybrid Trend Pullback - Universal ===");
   Print("Symbol: ", g_symbol);
   Print("Entry TF: ", EnumToString(InpEntryTf), " | Trend TF: ", EnumToString(InpTrendTf));
   Print("Risk per trade: ", InpRiskPerTradePct, "%");
   Print("Max positions: ", InpMaxPositions, " | Max trades/hour: ", InpMaxTradesPerHour);
   Print("Partial close: ", InpPartialClosePct, "% at ", InpPartialCloseProfitPct, "% capital profit");
   Print("=========================================");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_emaFast != INVALID_HANDLE) IndicatorRelease(g_emaFast);
   if(g_emaSlow != INVALID_HANDLE) IndicatorRelease(g_emaSlow);
   if(g_emaEntry != INVALID_HANDLE) IndicatorRelease(g_emaEntry);
   if(g_atr != INVALID_HANDLE) IndicatorRelease(g_atr);
}

// ===== Main Tick Handler =====
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;

   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return;

   ManagePosition();

   // Check position limits
   if(CountPositions() >= InpMaxPositions)
      return;

   // Check trades per hour limit
   if(CountTradesLastHour() >= InpMaxTradesPerHour)
      return;

   // Spread check
   if(!SpreadOk(tick))
      return;

   // Check for new bar (but also allow entries on tick for more opportunities)
   bool isNewBar = IsNewBar(InpEntryTf, g_lastEntryBar);

   // Build entry signal
   ENUM_ORDER_TYPE type;
   double entryPrice, sl, tp;
   if(!BuildEntry(type, entryPrice, sl, tp, tick))
      return;

   // Calculate volume
   double volume = CalcVolumeByRisk(type, entryPrice, sl);
   if(volume <= 0.0)
      return;

   // Open trade
   bool sent = false;
   if(type == ORDER_TYPE_BUY)
      sent = trade.Buy(volume, g_symbol, entryPrice, sl, tp, "HTrend_Universal");
   else
      sent = trade.Sell(volume, g_symbol, entryPrice, sl, tp, "HTrend_Universal");

   if(sent)
   {
      Print("TRADE OPENED: ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), 
            " | Lot: ", volume, " | Entry: ", entryPrice, 
            " | SL: ", sl, " | TP: ", tp);
      AddTradeTime();
   }
}

