//+------------------------------------------------------------------+
//| Trade management: BE + trailing + partial TP                     |
//+------------------------------------------------------------------+
#ifndef TRADE_MGMT_MQH
#define TRADE_MGMT_MQH

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

//+------------------------------------------------------------------+
//| Get current open position ticket                                 |
//+------------------------------------------------------------------+
inline ulong GetOpenPositionTicket(int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!PositionSelectByIndex(i)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      return PositionGetInteger(POSITION_TICKET);
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Check if momentum has broken (for momentum break exit)           |
//+------------------------------------------------------------------+
inline bool IsMomentumBroken(const EAConfig &cfg, const IndicatorHandles &h, ulong ticket, double atr)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket)) return false;
   
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double posPriceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
   
   MqlTick tick;
   if(!SymbolInfoTick(cfg.symbol, tick)) return false;
   
   double currentPrice = (posType == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
   double pullback = (posType == POSITION_TYPE_BUY) ? (posPriceOpen - currentPrice) : (currentPrice - posPriceOpen);
   
   // Check if price pulled back significantly
   if(pullback < (atr * cfg.exit.momentumBreakThreshold)) return false;
   
   // Check entry timeframe EMA for reversal
   double emaEntry = 0.0;
   if(h.emaEntry == INVALID_HANDLE || CopyBuffer(h.emaEntry, 0, 1, 1, &emaEntry) <= 0) return false;
   
   double closePrice = iClose(cfg.symbol, cfg.entryTf, 1);
   double openPrice = iOpen(cfg.symbol, cfg.entryTf, 1);
   
   // For BUY: Check if price broke below EMA or candle turned bearish
   if(posType == POSITION_TYPE_BUY)
   {
      if(closePrice < emaEntry || closePrice < openPrice)
         return true;
   }
   // For SELL: Check if price broke above EMA or candle turned bullish
   else
   {
      if(closePrice > emaEntry || closePrice > openPrice)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Process partial take profit levels                               |
//+------------------------------------------------------------------+
inline void ProcessPartialTakeProfit(CTrade &trade, 
                                     const EAConfig &cfg, 
                                     const IndicatorHandles &h, 
                                     TradeState &state,
                                     int magic)
{
   if(!cfg.exit.usePartialTP) return;
   
   ulong ticket = GetOpenPositionTicket(magic);
   if(ticket == 0 || !PositionSelectByTicket(ticket)) 
   {
      // Reset state when no position
      state.partialTP_Level1_Taken = false;
      state.partialTP_Level2_Taken = false;
      state.partialTP_Level3_Taken = false;
      state.partialTP_Level4_Taken = false;
      state.initialPositionSize = 0.0;
      state.currentTicket = 0;
      return;
   }
   
   // If this is a new ticket, reset partial TP tracking
   if(state.currentTicket != ticket)
   {
      state.partialTP_Level1_Taken = false;
      state.partialTP_Level2_Taken = false;
      state.partialTP_Level3_Taken = false;
      state.partialTP_Level4_Taken = false;
      state.initialPositionSize = PositionGetDouble(POSITION_VOLUME);
      state.currentTicket = ticket;
   }
   
   // Get position info
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double posPriceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentVolume = PositionGetDouble(POSITION_VOLUME);
   
   // Get ATR
   double atr = 0.0;
   if(h.atr == INVALID_HANDLE || CopyBuffer(h.atr, 0, 0, 1, &atr) <= 0) return;
   
   MqlTick tick;
   if(!SymbolInfoTick(cfg.symbol, tick)) return;
   
   double currentPrice = (posType == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
   double profit = (posType == POSITION_TYPE_BUY) ? (currentPrice - posPriceOpen) : (posPriceOpen - currentPrice);
   
   // Base size for partial closes (use initial size if available, otherwise current)
   double baseSize = (state.initialPositionSize > 0) ? state.initialPositionSize : currentVolume;
   
   // Lot size constraints
   double minLot = SymbolInfoDouble(cfg.symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(cfg.symbol, SYMBOL_VOLUME_STEP);
   
   // Level 1: Close 20% at first ATR target
   if(!state.partialTP_Level1_Taken && profit >= (atr * cfg.exit.partialTP_Level1_ATR))
   {
      double closeLot = NormalizeDouble(baseSize * 0.20, 2);
      if(closeLot >= minLot && closeLot < currentVolume)
      {
         if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
         
         if(trade.PositionClosePartial(ticket, closeLot))
         {
            state.partialTP_Level1_Taken = true;
            Print("💰 Partial TP Level 1 (20%): Closed ", closeLot, " lots at ", currentPrice, 
                  " (Profit: ", DoubleToString(profit / atr, 2), " ATR)");
         }
      }
   }
   
   // Level 2: Close 20% at second ATR target (40% total)
   if(!state.partialTP_Level2_Taken && profit >= (atr * cfg.exit.partialTP_Level2_ATR) && state.partialTP_Level1_Taken)
   {
      if(PositionSelectByTicket(ticket))
      {
         currentVolume = PositionGetDouble(POSITION_VOLUME);
         double closeLot = NormalizeDouble(baseSize * 0.20, 2);
         if(closeLot >= minLot && closeLot < currentVolume)
         {
            if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
            
            if(trade.PositionClosePartial(ticket, closeLot))
            {
               state.partialTP_Level2_Taken = true;
               Print("💰 Partial TP Level 2 (20%): Closed ", closeLot, " lots at ", currentPrice,
                     " (Profit: ", DoubleToString(profit / atr, 2), " ATR, Total: 40%)");
            }
         }
      }
   }
   
   // Level 3: Close 20% at third ATR target (60% total)
   if(!state.partialTP_Level3_Taken && profit >= (atr * cfg.exit.partialTP_Level3_ATR) && state.partialTP_Level2_Taken)
   {
      if(PositionSelectByTicket(ticket))
      {
         currentVolume = PositionGetDouble(POSITION_VOLUME);
         double closeLot = NormalizeDouble(baseSize * 0.20, 2);
         if(closeLot >= minLot && closeLot < currentVolume)
         {
            if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
            
            if(trade.PositionClosePartial(ticket, closeLot))
            {
               state.partialTP_Level3_Taken = true;
               Print("💰 Partial TP Level 3 (20%): Closed ", closeLot, " lots at ", currentPrice,
                     " (Profit: ", DoubleToString(profit / atr, 2), " ATR, Total: 60%)");
            }
         }
      }
   }
   
   // Level 4: Close 20% at fourth ATR target (80% total)
   if(!state.partialTP_Level4_Taken && profit >= (atr * cfg.exit.partialTP_Level4_ATR) && state.partialTP_Level3_Taken)
   {
      if(PositionSelectByTicket(ticket))
      {
         currentVolume = PositionGetDouble(POSITION_VOLUME);
         double closeLot = NormalizeDouble(baseSize * 0.20, 2);
         if(closeLot >= minLot && closeLot < currentVolume)
         {
            if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
            
            if(trade.PositionClosePartial(ticket, closeLot))
            {
               state.partialTP_Level4_Taken = true;
               Print("💰 Partial TP Level 4 (20%): Closed ", closeLot, " lots at ", currentPrice,
                     " (Profit: ", DoubleToString(profit / atr, 2), " ATR, Total: 80%)");
            }
         }
      }
   }
   
   // Momentum Break Exit: Close remaining position if momentum breaks
   if(cfg.exit.useMomentumBreakExit && IsMomentumBroken(cfg, h, ticket, atr))
   {
      if(PositionSelectByTicket(ticket))
      {
         double remainingVolume = PositionGetDouble(POSITION_VOLUME);
         if(remainingVolume >= minLot)
         {
            if(trade.PositionClose(ticket))
            {
               Print("⚡ Momentum Break Exit: Closed remaining ", remainingVolume, " lots at ", currentPrice);
               state.currentTicket = 0;
            }
         }
      }
   }
}
#endif // TRADE_MGMT_MQH
