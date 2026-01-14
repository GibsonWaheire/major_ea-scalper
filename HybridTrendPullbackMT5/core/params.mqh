//+------------------------------------------------------------------+
//| Inputs and configuration structures for Hybrid Trend Pullback EA |
//+------------------------------------------------------------------+
#ifndef PARAMS_MQH
#define PARAMS_MQH

// General inputs
input string   InpSymbol                = _Symbol;
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
#endif // PARAMS_MQH
