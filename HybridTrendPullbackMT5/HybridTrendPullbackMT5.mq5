//+------------------------------------------------------------------+
//| Hybrid Trend Pullback EA (XAUUSD M5, H1 bias)                    |
//| Trend-follow + micro pullback with ATR risk, BE & trailing       |
//| STANDALONE VERSION - All code in one file                        |
//+------------------------------------------------------------------+
#property copyright "Hybrid Trend Pullback"
#property version   "1.10"
#property description "Added: Partial Take Profit (20% intervals) + Momentum Break Exit"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+

// General inputs
input string   InpSymbol                = "";
input ENUM_TIMEFRAMES InpEntryTf        = PERIOD_M5;
input ENUM_TIMEFRAMES InpTrendTf        = PERIOD_H1;
input int      InpMagic                 = 460015;

// Trend filter (HTF)
input int      InpFastEma               = 50;
input int      InpSlowEma               = 200;
input int      InpMinBarsAfterFlip      = 2;

// Entry logic (LTF pullback + momentum)
input int      InpEntryPullbackEma      = 21;
input double   InpPullbackAtrMult       = 0.60;   // pullback tolerance vs ATR
input double   InpMomentumAtrMult       = 0.25;   // min body vs ATR
input double   InpMomentumRangeAtrMult  = 0.60;   // min candle range vs ATR

// Volatility filter
input int      InpAtrPeriod             = 14;
input ENUM_TIMEFRAMES InpAtrTf          = PERIOD_M5;
input double   InpMinAtrToSpread        = 3.0;    // ATR must be >= 3x spread (pips-equivalent)
input double   InpMaxAtrPctOfPrice      = 0.0030; // block if ATR > 0.30% of price

// Risk & RR
input double   InpRiskPerTradePct       = 0.50;   // fixed fractional risk
input double   InpSlAtrMult             = 1.8;
input double   InpTpAtrMult             = 2.4;
input double   InpMaxSpreadPips         = 25.0;   // XAUUSD: set per broker

// Break-even & trailing
input bool     InpUseBreakEven          = true;
input double   InpBreakEvenRR           = 1.0;
input double   InpBreakEvenBufferPips   = 20.0;
input bool     InpUseTrailing           = true;
input double   InpTrailStartRR          = 1.5;
input double   InpTrailStepPips         = 25.0;
input double   InpTrailAtrMult          = 0.8;

// Partial take profit
input bool     InpUsePartialTP          = true;
input double   InpPartialTP_Level1_ATR  = 2.0;   // Close 20% at this ATR profit
input double   InpPartialTP_Level2_ATR  = 3.5;   // Close 20% at this ATR profit (40% total)
input double   InpPartialTP_Level3_ATR  = 5.0;   // Close 20% at this ATR profit (60% total)
input double   InpPartialTP_Level4_ATR  = 6.5;   // Close 20% at this ATR profit (80% total)
input bool     InpUseMomentumBreakExit  = true;  // Close remaining on momentum break
input double   InpMomentumBreakThreshold = 0.3;  // ATR multiplier for momentum break detection

// Session control (broker time)
input bool     InpUseSessions           = true;
input int      InpLondonStartHour       = 7;
input int      InpLondonEndHour         = 17;
input int      InpNyStartHour           = 13;
input int      InpNyEndHour             = 22;
input int      InpSessionOffsetMinutes  = 0;      // adjust if broker != UTC
input bool     InpAvoidFridayLate       = true;
input int      InpFridayCutoffHour      = 20;

// Safety
input bool     InpOnePositionOnly       = true;
input bool     InpAllowHedgeBothSides   = false;

//+------------------------------------------------------------------+
//| STRUCTURES                                                       |
//+------------------------------------------------------------------+

struct TrendSettings
{
   string           symbol;
   ENUM_TIMEFRAMES  tf;
   int              fastEma;
   int              slowEma;
   int              minBarsAfterFlip;
};

struct EntrySettings
{
   string           symbol;
   ENUM_TIMEFRAMES  tf;
   int              pullbackEma;
   double           pullbackAtrMult;
   double           momentumAtrMult;
   double           momentumRangeAtrMult;
};

struct VolSettings
{
   int              atrPeriod;
   ENUM_TIMEFRAMES  atrTf;
   double           minAtrToSpread;
   double           maxAtrPctOfPrice;
};

struct RiskSettings
{
   double           riskPct;
   double           slAtrMult;
   double           tpAtrMult;
   double           maxSpreadPips;
};

struct ExitSettings
{
   bool             useBE;
   double           beRR;
   double           beBufferPips;
   bool             useTrail;
   double           trailStartRR;
   double           trailStepPips;
   double           trailAtrMult;
   bool             usePartialTP;
   double           partialTP_Level1_ATR;
   double           partialTP_Level2_ATR;
   double           partialTP_Level3_ATR;
   double           partialTP_Level4_ATR;
   bool             useMomentumBreakExit;
   double           momentumBreakThreshold;
};

struct SessionSettings
{
   bool             useSessions;
   int              londonStart;
   int              londonEnd;
   int              nyStart;
   int              nyEnd;
   int              offsetMinutes;
   bool             avoidFridayLate;
   int              fridayCutoffHour;
};

struct EAConfig
{
   TrendSettings    trend;
   EntrySettings    entry;
   VolSettings      vol;
   RiskSettings     risk;
   ExitSettings     exit;
   SessionSettings  session;
   string           symbol;
   ENUM_TIMEFRAMES  entryTf;
   ENUM_TIMEFRAMES  trendTf;
   int              magic;
   bool             onePositionOnly;
   bool             allowHedge;
};

struct IndicatorHandles
{
   int emaFast;
   int emaSlow;
   int emaEntry;
   int atr;
};

struct BarState
{
   datetime lastEntryTfBar;
   datetime lastTrendTfBar;
};

struct TradeState
{
   int      lastBias;
   int      barsSinceFlip;
   int      barsSinceEntry;
   bool     beMoved;
   bool     trailActive;
   bool     partialTP_Level1_Taken;
   bool     partialTP_Level2_Taken;
   bool     partialTP_Level3_Taken;
   bool     partialTP_Level4_Taken;
   double   initialPositionSize;
   ulong    currentTicket;
};

enum BiasDirection
{
   BiasNone = 0,
   BiasLong = 1,
   BiasShort = -1
};

struct EntrySignal
{
   bool            valid;
   ENUM_ORDER_TYPE type;
   double          entryPrice;
   double          sl;
   double          tp;
   double          atr;
   double          stopDistance;
};

struct VolCheckResult
{
   bool   ok;
   double atr;
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+

CTrade          gTrade;
EAConfig        gCfg;
IndicatorHandles gHandles;
BarState        gBars;
TradeState      gState;

//+------------------------------------------------------------------+
//| UTILITY FUNCTIONS                                                |
//+------------------------------------------------------------------+

inline double PipFactor()
{
   return (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0; 
}

inline double SpreadPips(const MqlTick &tick)
{
   return ((tick.ask - tick.bid) / _Point) / PipFactor();
}

inline double NormalizePrice(double price)
{
   return NormalizeDouble(price, _Digits);
}

inline bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastTime)
{
   datetime t[1];
   if(CopyTime(_Symbol, tf, 0, 1, t) <= 0)
      return false;
   if(lastTime != t[0])
   {
      lastTime = t[0];
      return true;
   }
   return false;
}

inline bool TradingAllowed()
{
   return !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ? false : true;
}

inline bool SpreadWithin(double maxSpreadPips, const MqlTick &tick)
{
   return SpreadPips(tick) <= maxSpreadPips;
}

inline double PointsFromPips(double pips)
{
   return pips * _Point * PipFactor();
}

//+------------------------------------------------------------------+
//| CONFIGURATION LOADING                                            |
//+------------------------------------------------------------------+

EAConfig LoadConfig()
{
   EAConfig cfg;
   cfg.symbol = (InpSymbol == "") ? _Symbol : InpSymbol;
   cfg.entryTf = InpEntryTf;
   cfg.trendTf = InpTrendTf;
   cfg.magic = InpMagic;
   cfg.onePositionOnly = InpOnePositionOnly;
   cfg.allowHedge = InpAllowHedgeBothSides;

   cfg.trend.symbol = (InpSymbol == "") ? _Symbol : InpSymbol;
   cfg.trend.tf = InpTrendTf;
   cfg.trend.fastEma = InpFastEma;
   cfg.trend.slowEma = InpSlowEma;
   cfg.trend.minBarsAfterFlip = InpMinBarsAfterFlip;

   cfg.entry.symbol = (InpSymbol == "") ? _Symbol : InpSymbol;
   cfg.entry.tf = InpEntryTf;
   cfg.entry.pullbackEma = InpEntryPullbackEma;
   cfg.entry.pullbackAtrMult = InpPullbackAtrMult;
   cfg.entry.momentumAtrMult = InpMomentumAtrMult;
   cfg.entry.momentumRangeAtrMult = InpMomentumRangeAtrMult;

   cfg.vol.atrPeriod = InpAtrPeriod;
   cfg.vol.atrTf = InpAtrTf;
   cfg.vol.minAtrToSpread = InpMinAtrToSpread;
   cfg.vol.maxAtrPctOfPrice = InpMaxAtrPctOfPrice;

   cfg.risk.riskPct = InpRiskPerTradePct;
   cfg.risk.slAtrMult = InpSlAtrMult;
   cfg.risk.tpAtrMult = InpTpAtrMult;
   cfg.risk.maxSpreadPips = InpMaxSpreadPips;

   cfg.exit.useBE = InpUseBreakEven;
   cfg.exit.beRR = InpBreakEvenRR;
   cfg.exit.beBufferPips = InpBreakEvenBufferPips;
   cfg.exit.useTrail = InpUseTrailing;
   cfg.exit.trailStartRR = InpTrailStartRR;
   cfg.exit.trailStepPips = InpTrailStepPips;
   cfg.exit.trailAtrMult = InpTrailAtrMult;
   cfg.exit.usePartialTP = InpUsePartialTP;
   cfg.exit.partialTP_Level1_ATR = InpPartialTP_Level1_ATR;
   cfg.exit.partialTP_Level2_ATR = InpPartialTP_Level2_ATR;
   cfg.exit.partialTP_Level3_ATR = InpPartialTP_Level3_ATR;
   cfg.exit.partialTP_Level4_ATR = InpPartialTP_Level4_ATR;
   cfg.exit.useMomentumBreakExit = InpUseMomentumBreakExit;
   cfg.exit.momentumBreakThreshold = InpMomentumBreakThreshold;

   cfg.session.useSessions = InpUseSessions;
   cfg.session.londonStart = InpLondonStartHour;
   cfg.session.londonEnd = InpLondonEndHour;
   cfg.session.nyStart = InpNyStartHour;
   cfg.session.nyEnd = InpNyEndHour;
   cfg.session.offsetMinutes = InpSessionOffsetMinutes;
   cfg.session.avoidFridayLate = InpAvoidFridayLate;
   cfg.session.fridayCutoffHour = InpFridayCutoffHour;

   return cfg;
}

void ResetTradeState(TradeState &st)
{
   st.lastBias = 0;
   st.barsSinceFlip = 0;
   st.barsSinceEntry = 0;
   st.beMoved = false;
   st.trailActive = false;
   st.partialTP_Level1_Taken = false;
   st.partialTP_Level2_Taken = false;
   st.partialTP_Level3_Taken = false;
   st.partialTP_Level4_Taken = false;
   st.initialPositionSize = 0.0;
   st.currentTicket = 0;
}

//+------------------------------------------------------------------+
//| VOLATILITY FILTER                                                |
//+------------------------------------------------------------------+

VolCheckResult CheckVolatility(const VolSettings &cfg, int atrHandle, const MqlTick &tick)
{
   VolCheckResult res;
   res.ok = false;
   res.atr = 0.0;

   if(atrHandle == INVALID_HANDLE) return res;
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atrBuffer) <= 0) return res;
   res.atr = atrBuffer[0];
   if(res.atr <= 0.0) return res;

   double spreadPips = SpreadPips(tick);
   if(spreadPips <= 0.0) return res;

   double atrPips = res.atr / (_Point * PipFactor());

   // ATR must be sufficiently larger than spread (liquidity)
   if(atrPips < cfg.minAtrToSpread * spreadPips)
      return res;

   // Prevent extremely high volatility relative to price
   double mid = (tick.ask + tick.bid) * 0.5;
   if(mid > 0.0 && (res.atr / mid) > cfg.maxAtrPctOfPrice)
      return res;

   res.ok = true;
   return res;
}

//+------------------------------------------------------------------+
//| TREND BIAS                                                       |
//+------------------------------------------------------------------+

bool InitTrendHandles(const TrendSettings &cfg, IndicatorHandles &h)
{
   h.emaFast = iMA(cfg.symbol, cfg.tf, cfg.fastEma, 0, MODE_EMA, PRICE_CLOSE);
   h.emaSlow = iMA(cfg.symbol, cfg.tf, cfg.slowEma, 0, MODE_EMA, PRICE_CLOSE);
   return (h.emaFast != INVALID_HANDLE && h.emaSlow != INVALID_HANDLE);
}

BiasDirection GetTrendBias(const TrendSettings &cfg, const IndicatorHandles &h, TradeState &state)
{
   double fastBuffer[], slowBuffer[];
   ArraySetAsSeries(fastBuffer, true);
   ArraySetAsSeries(slowBuffer, true);
   if(CopyBuffer(h.emaFast, 0, 1, 1, fastBuffer) <= 0) return BiasNone;
   if(CopyBuffer(h.emaSlow, 0, 1, 1, slowBuffer) <= 0) return BiasNone;
   double fast = fastBuffer[0];
   double slow = slowBuffer[0];

   BiasDirection bias = BiasNone;
   if(fast > slow) bias = BiasLong;
   else if(fast < slow) bias = BiasShort;

   if(bias != state.lastBias)
   {
      state.barsSinceFlip = 0;
      state.lastBias = bias;
   }
   state.barsSinceFlip++;

   if(state.barsSinceFlip <= cfg.minBarsAfterFlip)
      return BiasNone;

   return bias;
}

//+------------------------------------------------------------------+
//| ENTRY SIGNAL                                                     |
//+------------------------------------------------------------------+

bool InitEntryHandles(const EntrySettings &cfg, IndicatorHandles &h)
{
   h.emaEntry = iMA(cfg.symbol, cfg.tf, cfg.pullbackEma, 0, MODE_EMA, PRICE_CLOSE);
   return (h.emaEntry != INVALID_HANDLE);
}

bool InitAtrHandle(const VolSettings &cfg, const string &symbol, IndicatorHandles &h)
{
   h.atr = iATR(symbol, cfg.atrTf, cfg.atrPeriod);
   return (h.atr != INVALID_HANDLE);
}

bool MomentumOk(const EntrySettings &cfg, double atr)
{
   double open  = iOpen(cfg.symbol, cfg.tf, 1);
   double close = iClose(cfg.symbol, cfg.tf, 1);
   double high  = iHigh(cfg.symbol, cfg.tf, 1);
   double low   = iLow(cfg.symbol, cfg.tf, 1);

   double body = MathAbs(close - open);
   double range = high - low;

   if(range < atr * cfg.momentumRangeAtrMult) return false;
   if(body < atr * cfg.momentumAtrMult) return false;
   return true;
}

EntrySignal BuildEntry(const EAConfig &cfg, const IndicatorHandles &h, TradeState &state, const MqlTick &tick)
{
   EntrySignal sig;
   sig.valid = false;
   sig.atr = 0.0;
   sig.stopDistance = 0.0;

   // Volatility gate
   VolCheckResult volRes = CheckVolatility(cfg.vol, h.atr, tick);
   if(!volRes.ok) return sig;

   // Trend bias
   BiasDirection bias = GetTrendBias(cfg.trend, h, state);
   if(bias == BiasNone) return sig;

   // Entry timeframe EMA + price values
   double emaEntryBuffer[];
   ArraySetAsSeries(emaEntryBuffer, true);
   if(CopyBuffer(h.emaEntry, 0, 1, 1, emaEntryBuffer) <= 0) return sig;
   double emaEntry = emaEntryBuffer[0];

   double closePrice = iClose(cfg.entry.symbol, cfg.entry.tf, 1);
   double openPrice  = iOpen(cfg.entry.symbol, cfg.entry.tf, 1);

   double pullbackDist = volRes.atr * cfg.entry.pullbackAtrMult;
   bool pullbackOk = false;
   bool momentumOk = MomentumOk(cfg.entry, volRes.atr);
   bool dirOk = false;

   if(bias == BiasLong)
   {
      pullbackOk = (closePrice <= emaEntry + pullbackDist);
      dirOk = (closePrice > openPrice); // bullish candle
   }
   else if(bias == BiasShort)
   {
      pullbackOk = (closePrice >= emaEntry - pullbackDist);
      dirOk = (closePrice < openPrice); // bearish candle
   }

   if(!(pullbackOk && momentumOk && dirOk))
      return sig;

   // Build order parameters
   sig.type = (bias == BiasLong) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   sig.entryPrice = (sig.type == ORDER_TYPE_BUY) ? tick.ask : tick.bid;

   double stopDistPrice = volRes.atr * cfg.risk.slAtrMult;
   double takeDistPrice = volRes.atr * cfg.risk.tpAtrMult;

   if(sig.type == ORDER_TYPE_BUY)
   {
      sig.sl = NormalizePrice(sig.entryPrice - stopDistPrice);
      sig.tp = NormalizePrice(sig.entryPrice + takeDistPrice);
   }
   else
   {
      sig.sl = NormalizePrice(sig.entryPrice + stopDistPrice);
      sig.tp = NormalizePrice(sig.entryPrice - takeDistPrice);
   }

   sig.atr = volRes.atr;
   sig.stopDistance = stopDistPrice;
   sig.valid = true;
   return sig;
}

//+------------------------------------------------------------------+
//| RISK MANAGEMENT                                                  |
//+------------------------------------------------------------------+

double CalcVolumeByRisk(RiskSettings cfg, ENUM_ORDER_TYPE orderType, double entryPrice, double stopPrice)
{
   double riskMoney;
   double simLoss;
   double riskPct;
   riskPct = cfg.riskPct;
   riskMoney = AccountBalance() * (riskPct / 100.0);
   simLoss = 0.0;
   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entryPrice, stopPrice, simLoss))
      return 0.0;
   if(simLoss == 0.0) return 0.0;

   double vol = riskMoney / MathAbs(simLoss);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   vol = MathFloor(vol / step) * step;
   if(vol < minLot) vol = minLot;
   if(vol > maxLot) vol = maxLot;
   return vol;
}

bool SpreadOk(RiskSettings cfg, MqlTick tick)
{
   double maxSpread;
   maxSpread = cfg.maxSpreadPips;
   return SpreadWithin(maxSpread, tick);
}

//+------------------------------------------------------------------+
//| SESSION FILTER                                                   |
//+------------------------------------------------------------------+

datetime ApplyOffset(datetime t, int offsetMinutes)
{
   return t + offsetMinutes * 60;
}

bool SessionAllowed(const SessionSettings &cfg, datetime now)
{
   if(!cfg.useSessions) return true;

   datetime shifted = ApplyOffset(now, cfg.offsetMinutes);
   MqlDateTime dt;
   TimeToStruct(shifted, dt);
   int hour = dt.hour;

   bool inLondon = (hour >= cfg.londonStart && hour < cfg.londonEnd);
   bool inNy     = (hour >= cfg.nyStart && hour < cfg.nyEnd);
   if(!(inLondon || inNy)) return false;

   if(cfg.avoidFridayLate && dt.day_of_week == 5 && hour >= cfg.fridayCutoffHour)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| TRADE MANAGEMENT                                                 |
//+------------------------------------------------------------------+

double CurrentRR(ENUM_POSITION_TYPE type, double entry, double sl, double price)
{
   double riskDist = MathAbs(entry - sl);
   double profitDist = MathAbs(price - entry);
   if(riskDist <= 0.0) return 0.0;
   return profitDist / riskDist * ((price - entry) * (type == POSITION_TYPE_SELL ? -1.0 : 1.0) >= 0 ? 1.0 : -1.0);
}

void ManagePosition(CTrade &trade, ExitSettings cfg, IndicatorHandles &h, int magic)
{
   MqlTick tick;
   int total;
   int i;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   total = PositionsTotal();
   i = total - 1;
   while(i >= 0)
   {
      if(!PositionSelectByIndex(i))
      {
         i = i - 1;
         continue;
      }
      if((int)PositionGetInteger(POSITION_MAGIC) != magic)
      {
         i = i - 1;
         continue;
      }

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double price = (type == POSITION_TYPE_BUY) ? tick.bid : tick.ask;

      double atr = 0.0;
      if(h.atr != INVALID_HANDLE)
      {
         double atrBuffer[];
         ArraySetAsSeries(atrBuffer, true);
         if(CopyBuffer(h.atr, 0, 0, 1, atrBuffer) > 0)
            atr = atrBuffer[0];
      }

      double rr = CurrentRR(type, entry, sl, price);

      // Break-even
      if(cfg.useBE && rr >= cfg.beRR)
      {
         double bePrice = entry + (type == POSITION_TYPE_BUY ? 1 : -1) * PointsFromPips(cfg.beBufferPips);
         if((type == POSITION_TYPE_BUY && (sl < bePrice || sl == 0.0)) ||
            (type == POSITION_TYPE_SELL && (sl > bePrice || sl == 0.0)))
         {
            trade.PositionModify(PositionGetInteger(POSITION_TICKET), NormalizePrice(bePrice), tp);
         }
      }

      // Trailing
      if(cfg.useTrail && rr >= cfg.trailStartRR)
      {
         double trailByPrice = PointsFromPips(cfg.trailStepPips);
         double trailByAtr   = (atr > 0.0) ? atr * cfg.trailAtrMult : 0.0;
         double trailDist    = MathMax(trailByPrice, trailByAtr);
         double newSl        = (type == POSITION_TYPE_BUY) ? price - trailDist : price + trailDist;

         if(type == POSITION_TYPE_BUY && newSl > sl)
            trade.PositionModify(PositionGetInteger(POSITION_TICKET), NormalizePrice(newSl), tp);
         if(type == POSITION_TYPE_SELL && (sl == 0.0 || newSl < sl))
            trade.PositionModify(PositionGetInteger(POSITION_TICKET), NormalizePrice(newSl), tp);
      }
      i = i - 1;
   }
}

bool HasOpenPosition(int magic)
{
   int total;
   int i;
   total = PositionsTotal();
   i = total - 1;
   while(i >= 0)
   {
      if(!PositionSelectByIndex(i))
      {
         i = i - 1;
         continue;
      }
      if((int)PositionGetInteger(POSITION_MAGIC) != magic)
      {
         i = i - 1;
         continue;
      }
      return true;
   }
   return false;
}

ulong GetOpenPositionTicket(int magic)
{
   int total;
   int i;
   total = PositionsTotal();
   i = total - 1;
   while(i >= 0)
   {
      if(!PositionSelectByIndex(i))
      {
         i = i - 1;
         continue;
      }
      if((int)PositionGetInteger(POSITION_MAGIC) != magic)
      {
         i = i - 1;
         continue;
      }
      return PositionGetInteger(POSITION_TICKET);
   }
   return 0;
}

bool IsMomentumBroken(const EAConfig &cfg, const IndicatorHandles &h, ulong ticket, double atr)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket)) return false;
   
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double posPriceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
   
   MqlTick tick;
   if(!SymbolInfoTick(cfg.symbol, tick)) return false;
   
   double currentPrice = (posType == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
   double pullback = (posType == POSITION_TYPE_BUY) ? (posPriceOpen - currentPrice) : (currentPrice - posPriceOpen);
   
   // Check if price pulled back significantly
   if(pullback < (atr * cfg.exit.momentumBreakThreshold)) return false;
   
   // Check entry timeframe EMA for reversal
   double emaEntryBuffer[];
   ArraySetAsSeries(emaEntryBuffer, true);
   if(h.emaEntry == INVALID_HANDLE || CopyBuffer(h.emaEntry, 0, 1, 1, emaEntryBuffer) <= 0) return false;
   double emaEntry = emaEntryBuffer[0];
   
   double closePrice = iClose(cfg.symbol, cfg.entryTf, 1);
   double openPrice = iOpen(cfg.symbol, cfg.entryTf, 1);
   
   // For BUY: Check if price broke below EMA or candle turned bearish
   if(posType == POSITION_TYPE_BUY)
   {
      if(closePrice < emaEntry || closePrice < openPrice)
         return true;
   }
   // For SELL: Check if price broke above EMA or candle turned bullish
   else
   {
      if(closePrice > emaEntry || closePrice > openPrice)
         return true;
   }
   
   return false;
}

void ProcessPartialTakeProfit(CTrade &trade, const EAConfig &cfg, const IndicatorHandles &h, TradeState &state, int magic)
{
   if(!cfg.exit.usePartialTP) return;
   
   ulong ticket = GetOpenPositionTicket(magic);
   if(ticket == 0 || !PositionSelectByTicket(ticket)) 
   {
      // Reset state when no position
      state.partialTP_Level1_Taken = false;
      state.partialTP_Level2_Taken = false;
      state.partialTP_Level3_Taken = false;
      state.partialTP_Level4_Taken = false;
      state.initialPositionSize = 0.0;
      state.currentTicket = 0;
      return;
   }
   
   // If this is a new ticket, reset partial TP tracking
   if(state.currentTicket != ticket)
   {
      state.partialTP_Level1_Taken = false;
      state.partialTP_Level2_Taken = false;
      state.partialTP_Level3_Taken = false;
      state.partialTP_Level4_Taken = false;
      state.initialPositionSize = PositionGetDouble(POSITION_VOLUME);
      state.currentTicket = ticket;
   }
   
   // Get position info
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double posPriceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentVolume = PositionGetDouble(POSITION_VOLUME);
   
   // Get ATR
   double atr = 0.0;
   if(h.atr != INVALID_HANDLE)
   {
      double atrBuffer[];
      ArraySetAsSeries(atrBuffer, true);
      if(CopyBuffer(h.atr, 0, 0, 1, atrBuffer) <= 0) return;
      atr = atrBuffer[0];
   }
   else return;
   
   MqlTick tick;
   if(!SymbolInfoTick(cfg.symbol, tick)) return;
   
   double currentPrice = (posType == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
   double profit = (posType == POSITION_TYPE_BUY) ? (currentPrice - posPriceOpen) : (posPriceOpen - currentPrice);
   
   // Base size for partial closes (use initial size if available, otherwise current)
   double baseSize = (state.initialPositionSize > 0) ? state.initialPositionSize : currentVolume;
   
   // Lot size constraints
   double minLot = SymbolInfoDouble(cfg.symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(cfg.symbol, SYMBOL_VOLUME_STEP);
   
   // Level 1: Close 20% at first ATR target
   if(!state.partialTP_Level1_Taken && profit >= (atr * cfg.exit.partialTP_Level1_ATR))
   {
      double closeLot = NormalizeDouble(baseSize * 0.20, 2);
      if(closeLot >= minLot && closeLot < currentVolume)
      {
         if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
         
         if(trade.PositionClosePartial(ticket, closeLot))
         {
            state.partialTP_Level1_Taken = true;
            Print("💰 Partial TP Level 1 (20%): Closed ", closeLot, " lots at ", currentPrice, 
                  " (Profit: ", DoubleToString(profit / atr, 2), " ATR)");
         }
      }
   }
   
   // Level 2: Close 20% at second ATR target (40% total)
   if(!state.partialTP_Level2_Taken && profit >= (atr * cfg.exit.partialTP_Level2_ATR) && state.partialTP_Level1_Taken)
   {
      if(PositionSelectByTicket(ticket))
      {
         currentVolume = PositionGetDouble(POSITION_VOLUME);
         double closeLot = NormalizeDouble(baseSize * 0.20, 2);
         if(closeLot >= minLot && closeLot < currentVolume)
         {
            if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
            
            if(trade.PositionClosePartial(ticket, closeLot))
            {
               state.partialTP_Level2_Taken = true;
               Print("💰 Partial TP Level 2 (20%): Closed ", closeLot, " lots at ", currentPrice,
                     " (Profit: ", DoubleToString(profit / atr, 2), " ATR, Total: 40%)");
            }
         }
      }
   }
   
   // Level 3: Close 20% at third ATR target (60% total)
   if(!state.partialTP_Level3_Taken && profit >= (atr * cfg.exit.partialTP_Level3_ATR) && state.partialTP_Level2_Taken)
   {
      if(PositionSelectByTicket(ticket))
      {
         currentVolume = PositionGetDouble(POSITION_VOLUME);
         double closeLot = NormalizeDouble(baseSize * 0.20, 2);
         if(closeLot >= minLot && closeLot < currentVolume)
         {
            if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
            
            if(trade.PositionClosePartial(ticket, closeLot))
            {
               state.partialTP_Level3_Taken = true;
               Print("💰 Partial TP Level 3 (20%): Closed ", closeLot, " lots at ", currentPrice,
                     " (Profit: ", DoubleToString(profit / atr, 2), " ATR, Total: 60%)");
            }
         }
      }
   }
   
   // Level 4: Close 20% at fourth ATR target (80% total)
   if(!state.partialTP_Level4_Taken && profit >= (atr * cfg.exit.partialTP_Level4_ATR) && state.partialTP_Level3_Taken)
   {
      if(PositionSelectByTicket(ticket))
      {
         currentVolume = PositionGetDouble(POSITION_VOLUME);
         double closeLot = NormalizeDouble(baseSize * 0.20, 2);
         if(closeLot >= minLot && closeLot < currentVolume)
         {
            if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
            
            if(trade.PositionClosePartial(ticket, closeLot))
            {
               state.partialTP_Level4_Taken = true;
               Print("💰 Partial TP Level 4 (20%): Closed ", closeLot, " lots at ", currentPrice,
                     " (Profit: ", DoubleToString(profit / atr, 2), " ATR, Total: 80%)");
            }
         }
      }
   }
   
   // Momentum Break Exit: Close remaining position if momentum breaks
   if(cfg.exit.useMomentumBreakExit && IsMomentumBroken(cfg, h, ticket, atr))
   {
      if(PositionSelectByTicket(ticket))
      {
         double remainingVolume = PositionGetDouble(POSITION_VOLUME);
         if(remainingVolume >= minLot)
         {
            if(trade.PositionClose(ticket))
            {
               Print("⚡ Momentum Break Exit: Closed remaining ", remainingVolume, " lots at ", currentPrice);
               state.currentTicket = 0;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| INITIALIZATION                                                   |
//+------------------------------------------------------------------+

void ReleaseHandles(IndicatorHandles &h)
{
   if(h.emaFast != INVALID_HANDLE) IndicatorRelease(h.emaFast);
   if(h.emaSlow != INVALID_HANDLE) IndicatorRelease(h.emaSlow);
   if(h.emaEntry != INVALID_HANDLE) IndicatorRelease(h.emaEntry);
   if(h.atr != INVALID_HANDLE) IndicatorRelease(h.atr);
   h.emaFast = h.emaSlow = h.emaEntry = h.atr = INVALID_HANDLE;
}

bool InitIndicators()
{
   if(!InitTrendHandles(gCfg.trend, gHandles))
   {
      Print("Failed to init trend EMAs");
      return false;
   }
   if(!InitEntryHandles(gCfg.entry, gHandles))
   {
      Print("Failed to init entry EMA");
      return false;
   }
   if(!InitAtrHandle(gCfg.vol, gCfg.symbol, gHandles))
   {
      Print("Failed to init ATR");
      return false;
   }
   return true;
}

int OnInit()
{
   gCfg = LoadConfig();
   ResetTradeState(gState);
   gBars.lastEntryTfBar = 0;
   gBars.lastTrendTfBar = 0;

   if(!SymbolSelect(gCfg.symbol, true))
   {
      Print("Cannot select symbol: ", gCfg.symbol);
      return INIT_FAILED;
   }

   if(_Symbol != gCfg.symbol)
      Print("Warning: chart symbol ", _Symbol, " differs from InpSymbol ", gCfg.symbol);

   if(!InitIndicators())
      return INIT_FAILED;

   gTrade.SetExpertMagicNumber(gCfg.magic);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ReleaseHandles(gHandles);
}

void OnTick()
{
   if(!TradingAllowed()) return;

   MqlTick tick;
   if(!SymbolInfoTick(gCfg.symbol, tick)) return;

   // Process partial take profits first (may close position)
   if(gCfg.exit.usePartialTP)
      ProcessPartialTakeProfit(gTrade, gCfg, gHandles, gState, gCfg.magic);

   // Manage open trades each tick (BE & trailing)
   if(HasOpenPosition(gCfg.magic))
      ManagePosition(gTrade, gCfg.exit, gHandles, gCfg.magic);

   // If already in trade and single-position rule enforced, skip entries
   if(gCfg.onePositionOnly && HasOpenPosition(gCfg.magic))
      return;

   // Session/time guard
   if(!SessionAllowed(gCfg.session, TimeCurrent()))
      return;

   // Work only on new entry timeframe bar
   if(!IsNewBar(gCfg.entryTf, gBars.lastEntryTfBar))
      return;

   if(!SpreadOk(gCfg.risk, tick))
      return;

   EntrySignal sig = BuildEntry(gCfg, gHandles, gState, tick);
   if(!sig.valid) return;

   double volume = CalcVolumeByRisk(gCfg.risk, sig.type, sig.entryPrice, sig.sl);
   if(volume <= 0.0)
   {
      Print("Volume calc failed. Check symbol settings or stop distance.");
      return;
   }

   bool sent = false;
   ulong ticket = 0;
   if(sig.type == ORDER_TYPE_BUY)
      sent = gTrade.Buy(volume, gCfg.symbol, sig.entryPrice, sig.sl, sig.tp, "HybridTrendPullback");
   else
      sent = gTrade.Sell(volume, gCfg.symbol, sig.entryPrice, sig.sl, sig.tp, "HybridTrendPullback");

   if(!sent)
   {
      Print("Order send failed. Code=", gTrade.ResultRetcode(), " desc=", gTrade.ResultRetcodeDescription());
      return;
   }

   // Get position ticket and initialize partial TP tracking
   if(gCfg.exit.usePartialTP)
   {
      // Find the position ticket (position is created immediately after successful order)
      ticket = GetOpenPositionTicket(gCfg.magic);
      if(ticket > 0)
      {
         gState.currentTicket = ticket;
         gState.initialPositionSize = volume;
         gState.partialTP_Level1_Taken = false;
         gState.partialTP_Level2_Taken = false;
         gState.partialTP_Level3_Taken = false;
         gState.partialTP_Level4_Taken = false;
      }
   }

   gState.barsSinceEntry = 0;
   gState.beMoved = false;
   gState.trailActive = false;
}
//+------------------------------------------------------------------+
