//+------------------------------------------------------------------+
//| Inputs and configuration structures for Hybrid Trend Pullback EA |
//| USDJPY Optimized Version                                         |
//+------------------------------------------------------------------+
#ifndef PARAMS_USDJPY_MQH
#define PARAMS_USDJPY_MQH

// General inputs
input string   InpSymbol                = "USDJPY";  // Trading symbol (USDJPY optimized)
input ENUM_TIMEFRAMES InpEntryTf        = PERIOD_M5;  // Entry timeframe (M5 recommended)
input ENUM_TIMEFRAMES InpTrendTf        = PERIOD_H1;  // Trend timeframe (H1 for bias)
input int      InpMagic                 = 202512;    // Magic number

// Trend filter (HTF) - USDJPY Optimized
input int      InpFastEma               = 21;        // Fast EMA period (optimized for USDJPY)
input int      InpSlowEma               = 50;         // Slow EMA period (optimized for USDJPY)
input int      InpMinBarsAfterFlip      = 2;         // Bars to wait after trend flip

// Entry logic (LTF pullback + momentum) - USDJPY Optimized
input int      InpEntryPullbackEma      = 21;        // Pullback EMA period
input double   InpPullbackAtrMult       = 0.50;      // pullback tolerance vs ATR (50% for USDJPY)
input double   InpMomentumAtrMult       = 0.20;      // min body vs ATR (20% for USDJPY)
input double   InpMomentumRangeAtrMult  = 0.50;       // min candle range vs ATR (50% for USDJPY)

// Volatility filter - USDJPY Optimized
input int      InpAtrPeriod             = 14;        // ATR period
input ENUM_TIMEFRAMES InpAtrTf          = PERIOD_M5; // ATR timeframe
input double   InpMinAtrToSpread        = 2.5;       // ATR must be >= 2.5x spread (USDJPY optimized)
input double   InpMaxAtrPctOfPrice      = 0.0020;    // block if ATR > 0.20% of price (USDJPY)

// Risk & RR - USDJPY Optimized
input double   InpRiskPerTradePct       = 0.50;      // fixed fractional risk (0.5% conservative)
input double   InpSlAtrMult             = 1.5;       // Stop Loss = 1.5x ATR (USDJPY optimized)
input double   InpTpAtrMult             = 3.0;       // Take Profit = 3.0x ATR (1:2 RR)
input double   InpMaxSpreadPips         = 3.0;       // Max spread filter (USDJPY: 1-2 pips typical)

// Break-even & trailing - USDJPY Optimized
input bool     InpUseBreakEven          = true;      // Enable break-even
input double   InpBreakEvenRR           = 1.0;       // Move to BE at 1:1 RR
input double   InpBreakEvenBufferPips   = 5.0;       // BE buffer (5 pips for USDJPY)
input bool     InpUseTrailing           = true;     // Enable trailing stop
input double   InpTrailStartRR          = 1.5;      // Start trailing at 1.5:1 RR
input double   InpTrailStepPips         = 10.0;     // Trailing step (10 pips for USDJPY)
input double   InpTrailAtrMult          = 0.6;      // Trailing distance (60% of ATR)

// Session control (broker time)
input bool     InpUseSessions           = true;     // Enable session filter
input int      InpLondonStartHour       = 7;        // London session start (GMT)
input int      InpLondonEndHour         = 17;       // London session end (GMT)
input int      InpNyStartHour           = 13;       // NY session start (GMT)
input int      InpNyEndHour             = 22;       // NY session end (GMT)
input int      InpSessionOffsetMinutes  = 0;         // adjust if broker != UTC
input bool     InpAvoidFridayLate       = true;     // Avoid late Friday trading
input int      InpFridayCutoffHour      = 20;       // Friday cutoff hour

// Safety
input bool     InpOnePositionOnly       = true;     // Only one position at a time
input bool     InpAllowHedgeBothSides   = false;    // Allow hedging (disabled)

//------------------------ Config aggregates ----------------------------------//

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

inline EAConfig LoadConfig()
{
   EAConfig cfg;
   cfg.symbol = InpSymbol;
   cfg.entryTf = InpEntryTf;
   cfg.trendTf = InpTrendTf;
   cfg.magic = InpMagic;
   cfg.onePositionOnly = InpOnePositionOnly;
   cfg.allowHedge = InpAllowHedgeBothSides;

   cfg.trend.symbol = InpSymbol;
   cfg.trend.tf = InpTrendTf;
   cfg.trend.fastEma = InpFastEma;
   cfg.trend.slowEma = InpSlowEma;
   cfg.trend.minBarsAfterFlip = InpMinBarsAfterFlip;

   cfg.entry.symbol = InpSymbol;
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
#endif // PARAMS_USDJPY_MQH
