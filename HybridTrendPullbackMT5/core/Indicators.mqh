#ifndef INDICATORS_MQH
#define INDICATORS_MQH
#include <Indicators/Trend.mqh>
#include <Indicators/Indicators.mqh>
#include "Defs.mqh"

// Indicator utilities: initialization and safe value copies

bool InitIndicators(const TrendConfig &trendCfg,
                    const EntryConfig &entryCfg,
                    const RiskConfig  &riskCfg,
                    IndicatorHandles  &handles)
{
   handles.emaTrendFast = iMA(_Symbol, trendCfg.trendTf, trendCfg.fastEma, 0, MODE_EMA, PRICE_CLOSE);
   handles.emaTrendSlow = iMA(_Symbol, trendCfg.trendTf, trendCfg.slowEma, 0, MODE_EMA, PRICE_CLOSE);
   handles.emaEntry     = iMA(_Symbol, entryCfg.entryTf, entryCfg.pullbackEma, 0, MODE_EMA, PRICE_CLOSE);
   handles.rsi          = iRSI(_Symbol, entryCfg.entryTf, entryCfg.momentumRsi, PRICE_CLOSE);
   handles.atr          = iATR(_Symbol, riskCfg.atrTf, riskCfg.atrPeriod);

   return (handles.emaTrendFast != INVALID_HANDLE &&
           handles.emaTrendSlow != INVALID_HANDLE &&
           handles.emaEntry     != INVALID_HANDLE &&
           handles.rsi          != INVALID_HANDLE &&
           handles.atr          != INVALID_HANDLE);
}

void ReleaseIndicators(IndicatorHandles &handles)
{
   if(handles.emaTrendFast != INVALID_HANDLE) IndicatorRelease(handles.emaTrendFast);
   if(handles.emaTrendSlow != INVALID_HANDLE) IndicatorRelease(handles.emaTrendSlow);
   if(handles.emaEntry     != INVALID_HANDLE) IndicatorRelease(handles.emaEntry);
   if(handles.rsi          != INVALID_HANDLE) IndicatorRelease(handles.rsi);
   if(handles.atr          != INVALID_HANDLE) IndicatorRelease(handles.atr);

   handles.emaTrendFast = handles.emaTrendSlow = handles.emaEntry = INVALID_HANDLE;
   handles.rsi = handles.atr = INVALID_HANDLE;
}

bool CopyValue(int handle, int shift, double &value)
{
   double buffer[1];
   if(handle == INVALID_HANDLE) return false;
   if(CopyBuffer(handle, 0, shift, 1, buffer) <= 0) return false;
   value = buffer[0];
   return true;
}

double GetPipFactor()
{
   return (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
}

double SpreadInPips(const MqlTick &tick)
{
   return ((tick.ask - tick.bid) / _Point) / GetPipFactor();
}
#endif // INDICATORS_MQH
