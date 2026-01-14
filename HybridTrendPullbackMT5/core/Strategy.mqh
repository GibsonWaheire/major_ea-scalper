#ifndef STRATEGY_MQH
#define STRATEGY_MQH
#include "Defs.mqh"
#include "Indicators.mqh"

struct EntrySignal
{
   bool            valid;
   ENUM_ORDER_TYPE type;
   double          price;
   double          sl;
   double          tp;
   double          atr;
   double          stopPoints;
};

bool NewEntryBar(const EntryConfig &entryCfg, StrategyState &state)
{
   datetime barTime[1];
   if(CopyTime(_Symbol, entryCfg.entryTf, 0, 1, barTime) <= 0)
      return false;

   if(state.lastEntryBarTime != barTime[0])
   {
      state.lastEntryBarTime = barTime[0];
      return true;
   }
   return false;
}

int TrendBias(const TrendConfig &trendCfg, const IndicatorHandles &handles, StrategyState &state)
{
   double emaFast = 0.0, emaSlow = 0.0;
   if(!CopyValue(handles.emaTrendFast, 1, emaFast)) return 0;
   if(!CopyValue(handles.emaTrendSlow, 1, emaSlow)) return 0;

   int bias = 0;
   if(emaFast > emaSlow) bias = 1;
   if(emaFast < emaSlow) bias = -1;

   if(bias != 0 && bias != state.barsSinceFlip)
      state.barsSinceFlip = 0;

   state.barsSinceFlip++;
   if(state.barsSinceFlip < trendCfg.minBarsFromFlip)
      return 0; // wait after a flip

   return bias;
}

bool VolatilityOk(const FilterConfig &filterCfg,
                  double atr,
                  const MqlTick &tick)
{
   double spread = SpreadInPips(tick);
   if(spread <= 0.0) return false;
   if((atr / (_Point * SpreadInPips(tick))) < filterCfg.minAtrToSpread)
      return false;

   double price = (tick.ask + tick.bid) * 0.5;
   if(price > 0.0 && (atr / price) > filterCfg.maxAtrPercentOfPrice)
      return false;

   return true;
}

bool SessionsOk(const SessionConfig &sessionCfg, datetime now)
{
   if(!sessionCfg.useSessions) return true;

   MqlDateTime t;
   TimeToStruct(now, t);
   int hour = t.hour;

   bool inSession1 = (hour >= sessionCfg.session1Start && hour < sessionCfg.session1End);
   bool inSession2 = (hour >= sessionCfg.session2Start && hour < sessionCfg.session2End);
   if(!(inSession1 || inSession2))
      return false;

   if(sessionCfg.avoidFridayLate && t.day_of_week == 5 && hour >= sessionCfg.fridayCutoff)
      return false;

   return true;
}

EntrySignal BuildSignal(const TrendConfig      &trendCfg,
                        const EntryConfig      &entryCfg,
                        const RiskConfig       &riskCfg,
                        const FilterConfig     &filterCfg,
                        const IndicatorHandles &handles,
                        StrategyState          &state)
{
   EntrySignal signal;
   signal.valid = false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return signal;

   double atr = 0.0;
   if(!CopyValue(handles.atr, 1, atr)) return signal;
   if(atr <= 0.0) return signal;

   // Volatility gate
   if(!VolatilityOk(filterCfg, atr, tick)) return signal;

   // Trend bias
   int bias = TrendBias(trendCfg, handles, state);
   if(bias == 0) return signal;

   // Entry timeframe conditions
   double emaEntry = 0.0, rsi = 0.0;
   if(!CopyValue(handles.emaEntry, 1, emaEntry)) return signal;
   if(!CopyValue(handles.rsi, 1, rsi)) return signal;

   double closePrice = iClose(_Symbol, entryCfg.entryTf, 1);
   double pullbackDist = atr * entryCfg.pullbackAtr;

   bool pullbackOk = false;
   bool momentumOk = false;

   if(bias > 0)
   {
      pullbackOk = (closePrice <= emaEntry + pullbackDist);
      momentumOk = (rsi >= entryCfg.rsiBuy);
   }
   else if(bias < 0)
   {
      pullbackOk = (closePrice >= emaEntry - pullbackDist);
      momentumOk = (rsi <= entryCfg.rsiSell);
   }

   if(!(pullbackOk && momentumOk))
      return signal;

   // Build order parameters
   signal.type = (bias > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   signal.price = (bias > 0) ? tick.ask : tick.bid;

   double stopDistPrice = atr * riskCfg.slAtrMult;
   double takeDistPrice = atr * riskCfg.tpAtrMult;
   signal.sl = (bias > 0) ? signal.price - stopDistPrice : signal.price + stopDistPrice;
   signal.tp = (bias > 0) ? signal.price + takeDistPrice : signal.price - takeDistPrice;
   signal.atr = atr;
   signal.stopPoints = stopDistPrice / _Point;
   signal.valid = true;
   return signal;
}
#endif // STRATEGY_MQH
