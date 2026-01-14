//+------------------------------------------------------------------+
//| Risk sizing helpers                                              |
//+------------------------------------------------------------------+
#ifndef RISK_MQH
#define RISK_MQH

#include <Trade/Trade.mqh>
#include "params.mqh"
#include "utils.mqh"

inline double CalcVolumeByRisk(const RiskSettings &cfg,
                               ENUM_ORDER_TYPE     orderType,
                               double              entryPrice,
                               double              stopPrice)
{
   double riskMoney = AccountBalance() * (cfg.riskPct / 100.0);
   double simLoss = 0.0;
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

inline bool SpreadOk(const RiskSettings &cfg, const MqlTick &tick)
{
   return SpreadWithin(cfg.maxSpreadPips, tick);
}
#endif // RISK_MQH
