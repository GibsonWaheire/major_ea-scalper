#pragma once

// Core data structures shared across modules

struct TrendConfig
{
   ENUM_TIMEFRAMES trendTf;
   int             fastEma;
   int             slowEma;
   int             minBarsFromFlip;   // bars to wait after trend flip
};

struct EntryConfig
{
   ENUM_TIMEFRAMES entryTf;
   int             pullbackEma;
   int             momentumRsi;
   double          rsiBuy;
   double          rsiSell;
   double          pullbackAtr;       // how deep a pullback relative to ATR
};

struct RiskConfig
{
   int             atrPeriod;
   ENUM_TIMEFRAMES atrTf;
   double          slAtrMult;
   double          tpAtrMult;
   double          riskPct;           // percent of balance per trade
   double          maxSpreadPips;
   int             maxPositions;
};

struct ExitConfig
{
   bool   useBreakEven;
   double breakEvenRR;
   double breakEvenBufferPips;
   bool   useTrail;
   double trailStartRR;
   double trailStepPips;
   double trailAtrMult;
};

struct SessionConfig
{
   bool useSessions;
   int  session1Start;
   int  session1End;
   int  session2Start;
   int  session2End;
   bool avoidFridayLate;
   int  fridayCutoff;
};

struct FilterConfig
{
   double minAtrToSpread;
   double maxAtrPercentOfPrice;
   int    cooldownBars;
};

struct IndicatorHandles
{
   int emaTrendFast;
   int emaTrendSlow;
   int emaEntry;
   int rsi;
   int atr;
};

struct StrategyState
{
   datetime lastEntryBarTime;
   int      barsSinceFlip;
   int      barsSinceEntry;
   int      lastBias;
};
