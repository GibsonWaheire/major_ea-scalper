#pragma once
#include <Trade/Trade.mqh>
#include "Defs.mqh"
#include "Indicators.mqh"

// Position management: break-even and trailing logic

int CountPositionsByMagic(int magic)
{
   int total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!PositionSelectByIndex(i)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) == magic)
         total++;
   }
   return total;
}

int PositionDirection()
{
   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)  return 1;
   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) return -1;
   return 0;
}

void ManageOpenPositions(CTrade        &trade,
                         const ExitConfig &exitCfg,
                         const IndicatorHandles &handles,
                         int magic)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double pipFactor = GetPipFactor();
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!PositionSelectByIndex(i)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry   = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl      = PositionGetDouble(POSITION_SL);
      double tp      = PositionGetDouble(POSITION_TP);
      double volume  = PositionGetDouble(POSITION_VOLUME);
      double price   = (type == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
      double atr     = 0.0;
      CopyValue(handles.atr, 0, atr);

      double stopDist = MathAbs(entry - sl);
      double profitDist = MathAbs(price - entry);
      double rr = (stopDist > 0) ? profitDist / stopDist : 0;

      // Break-even logic
      if(exitCfg.useBreakEven && rr >= exitCfg.breakEvenRR)
      {
         double bePrice = entry + PositionDirection() * (exitCfg.breakEvenBufferPips * _Point * pipFactor);
         // Only tighten stop, never loosen
         if(type == POSITION_TYPE_BUY && (sl < bePrice || sl == 0.0))
            trade.PositionModify(PositionGetInteger(POSITION_TICKET), bePrice, tp);
         if(type == POSITION_TYPE_SELL && (sl > bePrice || sl == 0.0))
            trade.PositionModify(PositionGetInteger(POSITION_TICKET), bePrice, tp);
      }

      // Trailing logic
      if(exitCfg.useTrail && rr >= exitCfg.trailStartRR)
      {
         double trailByPrice = exitCfg.trailStepPips * _Point * pipFactor;
         double trailByAtr   = (atr > 0.0) ? atr * exitCfg.trailAtrMult : 0.0;
         double trailDist    = MathMax(trailByPrice, trailByAtr);
         double newSL        = (type == POSITION_TYPE_BUY) ? price - trailDist : price + trailDist;

         // Only move in direction of profit
         if(type == POSITION_TYPE_BUY && newSL > sl)
            trade.PositionModify(PositionGetInteger(POSITION_TICKET), newSL, tp);
         if(type == POSITION_TYPE_SELL && (sl == 0.0 || newSL < sl))
            trade.PositionModify(PositionGetInteger(POSITION_TICKET), newSL, tp);
      }
   }
}
