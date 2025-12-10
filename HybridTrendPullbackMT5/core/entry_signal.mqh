//+------------------------------------------------------------------+
//| Entry logic: pullback + momentum on entry timeframe               |
//+------------------------------------------------------------------+
#pragma once

#include "params.mqh"
#include "state.mqh"
#include "trend_bias.mqh"
#include "vol_filter.mqh"
#include "utils.mqh"

struct EntrySignal
{
   bool            valid;
   ENUM_ORDER_TYPE type;
   double          entryPrice;
   double          sl;
   double          tp;
   double          atr;
   double          stopDistance;
};

inline bool InitEntryHandles(const EntrySettings &cfg, IndicatorHandles &h)
{
   h.emaEntry = iMA(cfg.symbol, cfg.tf, cfg.pullbackEma, 0, MODE_EMA, PRICE_CLOSE);
   return (h.emaEntry != INVALID_HANDLE);
}

inline bool InitAtrHandle(const VolSettings &cfg, const string &symbol, IndicatorHandles &h)
{
   h.atr = iATR(symbol, cfg.atrTf, cfg.atrPeriod);
   return (h.atr != INVALID_HANDLE);
}

inline bool MomentumOk(const EntrySettings &cfg, double atr)
{
   double open  = iOpen(cfg.symbol, cfg.tf, 1);
   double close = iClose(cfg.symbol, cfg.tf, 1);
   double high  = iHigh(cfg.symbol, cfg.tf, 1);
   double low   = iLow(cfg.symbol, cfg.tf, 1);

   double body = MathAbs(close - open);
   double range = high - low;

   if(range < atr * cfg.momentumRangeAtrMult) return false;
   if(body < atr * cfg.momentumAtrMult) return false;
   // Bullish or bearish direction handled in BuildEntry
   return true;
}

inline EntrySignal BuildEntry(const EAConfig        &cfg,
                              const IndicatorHandles&h,
                              TradeState            &state,
                              const MqlTick         &tick)
{
   EntrySignal sig;
   sig.valid = false;
   sig.atr = 0.0;
   sig.stopDistance = 0.0;

   // Volatility gate
   VolCheckResult volRes = CheckVolatility(cfg.vol, h.atr, tick);
   if(!volRes.ok) return sig;

   // Trend bias
   BiasDirection bias = GetTrendBias(cfg.trend, h, state);
   if(bias == BiasNone) return sig;

   // Entry timeframe EMA + price values
   double emaEntry = 0.0;
   if(CopyBuffer(h.emaEntry, 0, 1, 1, &emaEntry) <= 0) return sig;

   double closePrice = iClose(cfg.entry.symbol, cfg.entry.tf, 1);
   double openPrice  = iOpen(cfg.entry.symbol, cfg.entry.tf, 1);

   double pullbackDist = volRes.atr * cfg.entry.pullbackAtrMult;
   bool pullbackOk = false;
   bool momentumOk = MomentumOk(cfg.entry, volRes.atr);
   bool dirOk = false;

   if(bias == BiasLong)
   {
      pullbackOk = (closePrice <= emaEntry + pullbackDist);
      dirOk = (closePrice > openPrice); // bullish candle
   }
   else if(bias == BiasShort)
   {
      pullbackOk = (closePrice >= emaEntry - pullbackDist);
      dirOk = (closePrice < openPrice); // bearish candle
   }

   if(!(pullbackOk && momentumOk && dirOk))
      return sig;

   // Build order parameters
   sig.type = (bias == BiasLong) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   sig.entryPrice = (sig.type == ORDER_TYPE_BUY) ? tick.ask : tick.bid;

   double stopDistPrice = volRes.atr * cfg.risk.slAtrMult;
   double takeDistPrice = volRes.atr * cfg.risk.tpAtrMult;

   if(sig.type == ORDER_TYPE_BUY)
   {
      sig.sl = NormalizePrice(sig.entryPrice - stopDistPrice);
      sig.tp = NormalizePrice(sig.entryPrice + takeDistPrice);
   }
   else
   {
      sig.sl = NormalizePrice(sig.entryPrice + stopDistPrice);
      sig.tp = NormalizePrice(sig.entryPrice - takeDistPrice);
   }

   sig.atr = volRes.atr;
   sig.stopDistance = stopDistPrice;
   sig.valid = true;
   return sig;
}
