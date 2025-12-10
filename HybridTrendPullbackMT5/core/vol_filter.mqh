//+------------------------------------------------------------------+
//| Volatility regime filter                                         |
//+------------------------------------------------------------------+
#pragma once

#include "utils.mqh"

struct VolCheckResult
{
   bool   ok;
   double atr;
};

inline VolCheckResult CheckVolatility(const VolSettings &cfg,
                                      int atrHandle,
                                      const MqlTick &tick)
{
   VolCheckResult res;
   res.ok = false;
   res.atr = 0.0;

   if(atrHandle == INVALID_HANDLE) return res;
   if(CopyBuffer(atrHandle, 0, 1, 1, &res.atr) <= 0) return res;
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
