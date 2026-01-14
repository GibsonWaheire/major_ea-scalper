//+------------------------------------------------------------------+
//| Runtime state for Hybrid Trend Pullback EA                       |
//+------------------------------------------------------------------+
#ifndef STATE_MQH
#define STATE_MQH

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

inline void ResetTradeState(TradeState &st)
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
#endif // STATE_MQH
