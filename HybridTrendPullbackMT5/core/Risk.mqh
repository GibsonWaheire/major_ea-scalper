//+------------------------------------------------------------------+
//| Risk sizing helpers                                              |
//+------------------------------------------------------------------+
#pragma once

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
#pragma once
#include <Trade/Trade.mqh>
#include "Defs.mqh"
#include "Indicators.mqh"

// Risk & sizing helpers

double CalcStopDistancePoints(double atrValue, double slAtrMult)
{
   return (atrValue * slAtrMult) / _Point;
}

double CalcTakeDistancePoints(double atrValue, double tpAtrMult)
{
   return (atrValue * tpAtrMult) / _Point;
}

double CalcVolumeForRisk(ENUM_ORDER_TYPE orderType,
                         double           entryPrice,
                         double           stopPrice,
                         double           riskPct)
{
   double riskMoney = AccountBalance() * (riskPct / 100.0);
   double simulatedLoss = 0.0;

   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entryPrice, stopPrice, simulatedLoss))
      return 0.0;

   if(simulatedLoss == 0.0) return 0.0;

   double volume = riskMoney / MathAbs(simulatedLoss);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   volume = MathFloor(volume / lotStep) * lotStep;
   if(volume < minLot) volume = minLot;
   if(volume > maxLot) volume = maxLot;
   return volume;
}

bool SpreadAllowed(double maxSpreadPips, const MqlTick &tick)
{
   return SpreadInPips(tick) <= maxSpreadPips;
}
