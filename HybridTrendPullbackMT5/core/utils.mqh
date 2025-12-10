//+------------------------------------------------------------------+
//| Utility helpers                                                  |
//+------------------------------------------------------------------+
#pragma once

inline double PipFactor()
{
   return (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
}

inline double SpreadPips(const MqlTick &tick)
{
   return ((tick.ask - tick.bid) / _Point) / PipFactor();
}

inline double NormalizePrice(double price)
{
   return NormalizeDouble(price, _Digits);
}

inline bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastTime)
{
   datetime t[1];
   if(CopyTime(_Symbol, tf, 0, 1, t) <= 0)
      return false;
   if(lastTime != t[0])
   {
      lastTime = t[0];
      return true;
   }
   return false;
}

inline bool TradingAllowed()
{
   return !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ? false : true;
}

inline bool GetTick(MqlTick &tick)
{
   return SymbolInfoTick(_Symbol, tick);
}

inline bool SpreadWithin(double maxSpreadPips, const MqlTick &tick)
{
   return SpreadPips(tick) <= maxSpreadPips;
}

inline double PointsFromPips(double pips)
{
   return pips * _Point * PipFactor();
}
