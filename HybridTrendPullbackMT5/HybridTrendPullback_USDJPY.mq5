//+------------------------------------------------------------------+
//| Hybrid Trend Pullback EA - USDJPY Optimized (Uses Core Folder)   |
//| Trend-follow + micro pullback with ATR risk, BE & trailing       |
//| Optimized for USDJPY profitability                               |
//+------------------------------------------------------------------+
#property copyright "Hybrid Trend Pullback - USDJPY Optimized"
#property version   "2.00"
#property description "Trend-following EA optimized for USDJPY - Uses core folder structure"

#include <Trade/Trade.mqh>

#include "core/params_usdjpy.mqh"
#include "core/state.mqh"
#include "core/utils.mqh"
#include "core/trend_bias.mqh"
#include "core/entry_signal.mqh"
#include "core/vol_filter.mqh"
#include "core/risk.mqh"
#include "core/trade_mgmt.mqh"
#include "core/session.mqh"

CTrade          gTrade;
EAConfig        gCfg;
IndicatorHandles gHandles;
BarState        gBars;
TradeState      gState;

//--- helpers
void ReleaseHandles(IndicatorHandles &h)
{
   if(h.emaFast != INVALID_HANDLE) IndicatorRelease(h.emaFast);
   if(h.emaSlow != INVALID_HANDLE) IndicatorRelease(h.emaSlow);
   if(h.emaEntry != INVALID_HANDLE) IndicatorRelease(h.emaEntry);
   if(h.atr != INVALID_HANDLE) IndicatorRelease(h.atr);
   h.emaFast = h.emaSlow = h.emaEntry = h.atr = INVALID_HANDLE;
}

bool InitIndicators()
{
   if(!InitTrendHandles(gCfg.trend, gHandles))
   {
      Print("Failed to init trend EMAs");
      return false;
   }
   if(!InitEntryHandles(gCfg.entry, gHandles))
   {
      Print("Failed to init entry EMA");
      return false;
   }
   if(!InitAtrHandle(gCfg.vol, gCfg.symbol, gHandles))
   {
      Print("Failed to init ATR");
      return false;
   }
   return true;
}

int OnInit()
{
   gCfg = LoadConfig();
   ResetTradeState(gState);
   gBars.lastEntryTfBar = 0;
   gBars.lastTrendTfBar = 0;

   if(!SymbolSelect(gCfg.symbol, true))
   {
      Print("Cannot select symbol: ", gCfg.symbol);
      return INIT_FAILED;
   }

   if(_Symbol != gCfg.symbol)
      Print("Warning: chart symbol ", _Symbol, " differs from InpSymbol ", gCfg.symbol);

   if(!InitIndicators())
      return INIT_FAILED;

   gTrade.SetExpertMagicNumber(gCfg.magic);
   
   Print("=== Hybrid Trend Pullback - USDJPY Optimized ===");
   Print("Symbol: ", gCfg.symbol);
   Print("Entry TF: ", EnumToString(gCfg.entryTf), " | Trend TF: ", EnumToString(gCfg.trendTf));
   Print("Risk per trade: ", gCfg.risk.riskPct, "%");
   Print("Max spread: ", gCfg.risk.maxSpreadPips, " pips");
   Print("================================================");
   
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ReleaseHandles(gHandles);
}

void OnTick()
{
   if(!TradingAllowed()) return;

   MqlTick tick;
   if(!SymbolInfoTick(gCfg.symbol, tick)) return;

   // Manage open trades each tick
   ManagePosition(gTrade, gCfg.exit, gHandles, gCfg.magic);

   // If already in trade and single-position rule enforced, skip entries
   if(gCfg.onePositionOnly && HasOpenPosition(gCfg.magic))
      return;

   // Session/time guard
   if(!SessionAllowed(gCfg.session, TimeCurrent()))
      return;

   // Work only on new entry timeframe bar
   if(!IsNewBar(gCfg.entryTf, gBars.lastEntryTfBar))
      return;

   if(!SpreadOk(gCfg.risk, tick))
      return;

   EntrySignal sig = BuildEntry(gCfg, gHandles, gState, tick);
   if(!sig.valid) return;

   double volume = CalcVolumeByRisk(gCfg.risk, sig.type, sig.entryPrice, sig.sl);
   if(volume <= 0.0)
   {
      Print("Volume calc failed. Check symbol settings or stop distance.");
      return;
   }

   bool sent = false;
   if(sig.type == ORDER_TYPE_BUY)
      sent = gTrade.Buy(volume, gCfg.symbol, sig.entryPrice, sig.sl, sig.tp, "HTrend_USDJPY");
   else
      sent = gTrade.Sell(volume, gCfg.symbol, sig.entryPrice, sig.sl, sig.tp, "HTrend_USDJPY");

   if(!sent)
   {
      Print("Order send failed. Code=", gTrade.ResultRetcode(), " desc=", gTrade.ResultRetcodeDescription());
      return;
   }

   gState.barsSinceEntry = 0;
   gState.beMoved = false;
   gState.trailActive = false;
}
