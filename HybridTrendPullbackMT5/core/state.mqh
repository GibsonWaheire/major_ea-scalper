//+------------------------------------------------------------------+
//| Runtime state for Hybrid Trend Pullback EA                       |
//+------------------------------------------------------------------+
#pragma once

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
};

inline void ResetTradeState(TradeState &st)
{
   st.lastBias = 0;
   st.barsSinceFlip = 0;
   st.barsSinceEntry = 0;
   st.beMoved = false;
   st.trailActive = false;
}
