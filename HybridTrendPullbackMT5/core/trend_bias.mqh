//+------------------------------------------------------------------+
//| Higher timeframe trend filter                                    |
//+------------------------------------------------------------------+
#ifndef TREND_BIAS_MQH
#define TREND_BIAS_MQH

#include "state.mqh"
#include "utils.mqh"

enum BiasDirection
{
   BiasNone = 0,
   BiasLong = 1,
   BiasShort = -1
};

inline bool InitTrendHandles(const TrendSettings &cfg, IndicatorHandles &h)
{
   h.emaFast = iMA(cfg.symbol, cfg.tf, cfg.fastEma, 0, MODE_EMA, PRICE_CLOSE);
   h.emaSlow = iMA(cfg.symbol, cfg.tf, cfg.slowEma, 0, MODE_EMA, PRICE_CLOSE);
   return (h.emaFast != INVALID_HANDLE && h.emaSlow != INVALID_HANDLE);
}

inline BiasDirection GetTrendBias(const TrendSettings &cfg,
                                  const IndicatorHandles &h,
                                  TradeState &state)
{
   double fast=0.0, slow=0.0;
   if(CopyBuffer(h.emaFast, 0, 1, 1, &fast) <= 0) return BiasNone;
   if(CopyBuffer(h.emaSlow, 0, 1, 1, &slow) <= 0) return BiasNone;

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
#endif // TREND_BIAS_MQH
