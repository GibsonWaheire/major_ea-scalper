//+------------------------------------------------------------------+
//| Hybrid Trend Pullback EA - USDJPY Standalone                      |
//| Trend-following with pullback entries - Optimized for profitability |
//| STANDALONE VERSION - No core folder dependencies                  |
//+------------------------------------------------------------------+
#property copyright "Hybrid Trend Pullback - USDJPY Standalone"
#property version   "2.00"
#property description "Trend-following EA optimized for USDJPY profitability"
#property description "STANDALONE: All code in one file, no dependencies"
#property description "Uses H1 trend bias + M5 pullback entries with ATR-based risk management"

#include <Trade/Trade.mqh>

CTrade trade;

// ===== Input Parameters (USDJPY Optimized) =====
input group "===== Symbol & Timeframes ====="
input string   InpSymbol                = "USDJPY";  // Trading symbol
input ENUM_TIMEFRAMES InpEntryTf        = PERIOD_M5; // Entry timeframe (M5 recommended)
input ENUM_TIMEFRAMES InpTrendTf        = PERIOD_H1; // Trend timeframe (H1 for bias)

input group "===== Trend Filter (H1) ====="
input int      InpFastEma               = 21;        // Fast EMA period (optimized for USDJPY)
input int      InpSlowEma               = 50;        // Slow EMA period (optimized for USDJPY)
input int      InpMinBarsAfterFlip      = 2;         // Bars to wait after trend flip

input group "===== Entry Logic (M5 Pullback) ====="
input int      InpEntryPullbackEma      = 21;        // Pullback EMA period
input double   InpPullbackAtrMult       = 0.50;      // Pullback tolerance (50% of ATR)
input double   InpMomentumAtrMult       = 0.20;      // Min candle body (20% of ATR)
input double   InpMomentumRangeAtrMult  = 0.50;      // Min candle range (50% of ATR)

input group "===== Volatility Filter ====="
input int      InpAtrPeriod             = 14;        // ATR period
input ENUM_TIMEFRAMES InpAtrTf          = PERIOD_M5; // ATR timeframe
input double   InpMinAtrToSpread        = 2.5;       // ATR must be >= 2.5x spread (USDJPY optimized)
input double   InpMaxAtrPctOfPrice      = 0.0020;    // Block if ATR > 0.20% of price (USDJPY)

input group "===== Risk Management ====="
input int      InpMagic                 = 202512;    // Magic number
input double   InpRiskPerTradePct       = 0.50;      // Risk per trade (0.5% = conservative)
input double   InpSlAtrMult             = 1.5;       // Stop Loss = 1.5x ATR (USDJPY optimized)
input double   InpTpAtrMult             = 3.0;       // Take Profit = 3.0x ATR (1:2 RR)
input double   InpMaxSpreadPips         = 3.0;       // Max spread filter (USDJPY: 1-2 pips typical)

input group "===== Break-Even & Trailing ====="
input bool     InpUseBreakEven          = true;      // Enable break-even
input double   InpBreakEvenRR           = 1.0;       // Move to BE at 1:1 RR
input double   InpBreakEvenBufferPips   = 5.0;       // BE buffer (5 pips for USDJPY)
input bool     InpUseTrailing           = true;      // Enable trailing stop
input double   InpTrailStartRR          = 1.5;       // Start trailing at 1.5:1 RR
input double   InpTrailStepPips         = 10.0;      // Trailing step (10 pips for USDJPY)
input double   InpTrailAtrMult          = 0.6;       // Trailing distance (60% of ATR)

input group "===== Session Filter ====="
input bool     InpUseSessions           = true;      // Enable session filter
input int      InpLondonStartHour       = 7;         // London session start (GMT)
input int      InpLondonEndHour         = 17;        // London session end (GMT)
input int      InpNyStartHour           = 13;        // NY session start (GMT)
input int      InpNyEndHour             = 22;        // NY session end (GMT)
input int      InpSessionOffsetMinutes  = 0;         // Broker time offset (minutes)
input bool     InpAvoidFridayLate       = true;      // Avoid late Friday trading
input int      InpFridayCutoffHour      = 20;        // Friday cutoff hour

input group "===== Safety ====="
input bool     InpOnePositionOnly       = true;      // Only one position at a time

// ===== Global Variables =====
int g_emaFast = INVALID_HANDLE;
int g_emaSlow = INVALID_HANDLE;
int g_emaEntry = INVALID_HANDLE;
int g_atr = INVALID_HANDLE;

datetime g_lastEntryBar = 0;
int g_lastBias = 0;
int g_barsSinceFlip = 0;
bool g_beMoved = false;
bool g_trailActive = false;

// ===== Utility Functions =====
double PipFactor()
{
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   return (digits == 3 || digits == 5) ? 10.0 : 1.0;
}

double SpreadPips(const MqlTick &tick)
{
   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   return ((tick.ask - tick.bid) / point) / PipFactor();
}

double NormalizePrice(double price)
{
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

double PointsFromPips(double pips)
{
   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   return pips * point * PipFactor();
}

bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastTime)
{
   datetime t[1];
   if(CopyTime(InpSymbol, tf, 0, 1, t) <= 0)
      return false;
   if(lastTime != t[0])
   {
      lastTime = t[0];
      return true;
   }
   return false;
}

// Helper function to get price data (MT5 compatible)
bool GetPriceData(string symbol, ENUM_TIMEFRAMES tf, int shift, double &open, double &close, double &high, double &low)
{
   double o[1], c[1], h[1], l[1];
   if(CopyOpen(symbol, tf, shift, 1, o) <= 0) return false;
   if(CopyClose(symbol, tf, shift, 1, c) <= 0) return false;
   if(CopyHigh(symbol, tf, shift, 1, h) <= 0) return false;
   if(CopyLow(symbol, tf, shift, 1, l) <= 0) return false;
   open = o[0];
   close = c[0];
   high = h[0];
   low = l[0];
   return true;
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
   if(fast[0] > slow[0]) bias = 1;  // Bullish
   else if(fast[0] < slow[0]) bias = -1;  // Bearish

   if(bias != g_lastBias)
   {
      g_barsSinceFlip = 0;
      g_lastBias = bias;
   }
   g_barsSinceFlip++;

   if(g_barsSinceFlip <= InpMinBarsAfterFlip)
      return 0;  // Wait after flip

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

   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   double atrPips = atr / (point * PipFactor());

   // ATR must be sufficiently larger than spread
   if(atrPips < InpMinAtrToSpread * spreadPips)
      return false;

   // Prevent extremely high volatility
   double mid = (tick.ask + tick.bid) * 0.5;
   if(mid > 0.0 && (atr / mid) > InpMaxAtrPctOfPrice)
      return false;

   return true;
}

// ===== Momentum Check =====
bool MomentumOk(double atr)
{
   double open[1], close[1], high[1], low[1];
   
   if(CopyOpen(InpSymbol, InpEntryTf, 1, 1, open) <= 0) return false;
   if(CopyClose(InpSymbol, InpEntryTf, 1, 1, close) <= 0) return false;
   if(CopyHigh(InpSymbol, InpEntryTf, 1, 1, high) <= 0) return false;
   if(CopyLow(InpSymbol, InpEntryTf, 1, 1, low) <= 0) return false;

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
   if(CopyClose(InpSymbol, InpEntryTf, 1, 1, closePrice) <= 0) return false;
   if(CopyOpen(InpSymbol, InpEntryTf, 1, 1, openPrice) <= 0) return false;

   double pullbackDist = atr * InpPullbackAtrMult;
   bool pullbackOk = false;
   bool momentumOk = MomentumOk(atr);
   bool dirOk = false;

   if(bias == 1)  // Bullish
   {
      pullbackOk = (closePrice[0] <= emaEntry + pullbackDist);
      dirOk = (closePrice[0] > openPrice[0]);  // Bullish candle
      type = ORDER_TYPE_BUY;
      entryPrice = tick.ask;
   }
   else  // Bearish
   {
      pullbackOk = (closePrice[0] >= emaEntry - pullbackDist);
      dirOk = (closePrice[0] < openPrice[0]);  // Bearish candle
      type = ORDER_TYPE_SELL;
      entryPrice = tick.bid;
   }

   if(!(pullbackOk && momentumOk && dirOk))
      return false;

   // Calculate SL and TP
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

// ===== Session Check =====
bool SessionAllowed()
{
   if(!InpUseSessions) return true;

   datetime now = TimeCurrent();
   if(InpSessionOffsetMinutes != 0)
      now += InpSessionOffsetMinutes * 60;

   MqlDateTime dt;
   TimeToStruct(now, dt);
   int hour = dt.hour;

   bool inLondon = (hour >= InpLondonStartHour && hour < InpLondonEndHour);
   bool inNy     = (hour >= InpNyStartHour && hour < InpNyEndHour);
   if(!(inLondon || inNy)) return false;

   if(InpAvoidFridayLate && dt.day_of_week == 5 && hour >= InpFridayCutoffHour)
      return false;

   return true;
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

void ManagePosition()
{
   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick)) return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!PositionSelectByIndex(i)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double price = (type == POSITION_TYPE_BUY) ? tick.bid : tick.ask;

      double atr = 0.0;
      if(g_atr != INVALID_HANDLE)
      {
         double atrBuffer[1];
         if(CopyBuffer(g_atr, 0, 0, 1, atrBuffer) > 0)
            atr = atrBuffer[0];
      }

      double rr = CurrentRR(type, entry, sl, price);

      // Break-even
      if(InpUseBreakEven && rr >= InpBreakEvenRR && !g_beMoved)
      {
         double bePrice = entry + (type == POSITION_TYPE_BUY ? 1 : -1) * PointsFromPips(InpBreakEvenBufferPips);
         bool shouldMove = false;
         if(type == POSITION_TYPE_BUY && (sl < bePrice || sl == 0.0))
            shouldMove = true;
         else if(type == POSITION_TYPE_SELL && (sl > bePrice || sl == 0.0))
            shouldMove = true;

         if(shouldMove)
         {
            if(trade.PositionModify(PositionGetInteger(POSITION_TICKET), NormalizePrice(bePrice), tp))
               g_beMoved = true;
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
            trade.PositionModify(PositionGetInteger(POSITION_TICKET), NormalizePrice(newSl), tp);
            g_trailActive = true;
         }
      }
   }
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!PositionSelectByIndex(i)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) == InpSymbol)
         return true;
   }
   return false;
}

// ===== Volume Calculation =====
double CalcVolumeByRisk(ENUM_ORDER_TYPE orderType, double entryPrice, double stopPrice)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPerTradePct / 100.0);
   double simLoss = 0.0;
   
   if(!OrderCalcProfit(orderType, InpSymbol, 1.0, entryPrice, stopPrice, simLoss))
      return 0.0;
   if(simLoss == 0.0) return 0.0;

   double vol = riskMoney / MathAbs(simLoss);
   double step = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);

   vol = MathFloor(vol / step) * step;
   if(vol < minLot) vol = minLot;
   if(vol > maxLot) vol = maxLot;
   return NormalizeDouble(vol, 2);
}

// ===== Initialization =====
int OnInit()
{
   if(!SymbolSelect(InpSymbol, true))
   {
      Print("ERROR: Cannot select symbol: ", InpSymbol);
      return INIT_FAILED;
   }

   // Initialize indicators
   g_emaFast = iMA(InpSymbol, InpTrendTf, InpFastEma, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlow = iMA(InpSymbol, InpTrendTf, InpSlowEma, 0, MODE_EMA, PRICE_CLOSE);
   g_emaEntry = iMA(InpSymbol, InpEntryTf, InpEntryPullbackEma, 0, MODE_EMA, PRICE_CLOSE);
   g_atr = iATR(InpSymbol, InpAtrTf, InpAtrPeriod);

   if(g_emaFast == INVALID_HANDLE || g_emaSlow == INVALID_HANDLE || 
      g_emaEntry == INVALID_HANDLE || g_atr == INVALID_HANDLE)
   {
      Print("ERROR: Failed to initialize indicators");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   Print("=== Hybrid Trend Pullback - USDJPY Optimized ===");
   Print("Symbol: ", InpSymbol);
   Print("Entry TF: ", EnumToString(InpEntryTf), " | Trend TF: ", EnumToString(InpTrendTf));
   Print("Risk per trade: ", InpRiskPerTradePct, "%");
   Print("Max spread: ", InpMaxSpreadPips, " pips");
   Print("================================================");

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
   if(!SymbolInfoTick(InpSymbol, tick)) return;

   // Manage open positions
   ManagePosition();

   // Check if already in trade
   if(InpOnePositionOnly && HasOpenPosition())
      return;

   // Session filter
   if(!SessionAllowed())
      return;

   // Check for new bar on entry timeframe
   if(!IsNewBar(InpEntryTf, g_lastEntryBar))
      return;

   // Spread check
   if(!SpreadOk(tick))
      return;

   // Build entry signal
   ENUM_ORDER_TYPE type;
   double entryPrice, sl, tp;
   if(!BuildEntry(type, entryPrice, sl, tp, tick))
      return;

   // Calculate volume
   double volume = CalcVolumeByRisk(type, entryPrice, sl);
   if(volume <= 0.0)
   {
      Print("ERROR: Volume calculation failed");
      return;
   }

   // Open trade
   bool sent = false;
   if(type == ORDER_TYPE_BUY)
      sent = trade.Buy(volume, InpSymbol, entryPrice, sl, tp, "HTrend_USDJPY");
   else
      sent = trade.Sell(volume, InpSymbol, entryPrice, sl, tp, "HTrend_USDJPY");

   if(sent)
   {
      Print("TRADE OPENED: ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), 
            " | Lot: ", volume, " | Entry: ", entryPrice, 
            " | SL: ", sl, " | TP: ", tp);
      g_beMoved = false;
      g_trailActive = false;
   }
   else
   {
      Print("ERROR: Order failed - ", trade.ResultRetcodeDescription());
   }
}
