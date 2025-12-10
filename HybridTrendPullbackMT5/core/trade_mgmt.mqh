//+------------------------------------------------------------------+
//| Trade management: BE + trailing                                  |
//+------------------------------------------------------------------+
#pragma once

#include <Trade/Trade.mqh>
#include "params.mqh"
#include "state.mqh"
#include "utils.mqh"

inline double CurrentRR(ENUM_POSITION_TYPE type, double entry, double sl, double price)
{
   double riskDist = MathAbs(entry - sl);
   double profitDist = MathAbs(price - entry);
   if(riskDist <= 0.0) return 0.0;
   return profitDist / riskDist * ((price - entry) * (type == POSITION_TYPE_SELL ? -1.0 : 1.0) >= 0 ? 1.0 : -1.0);
}

inline void ManagePosition(CTrade &trade, const ExitSettings &cfg, const IndicatorHandles &h, int magic)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!PositionSelectByIndex(i)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double price = (type == POSITION_TYPE_BUY) ? tick.bid : tick.ask;

      double atr = 0.0;
      if(h.atr != INVALID_HANDLE)
         CopyBuffer(h.atr, 0, 0, 1, &atr);

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
   }
}

inline bool HasOpenPosition(int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!PositionSelectByIndex(i)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      return true;
   }
   return false;
}
