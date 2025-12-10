//+------------------------------------------------------------------+
//| Session / time filters                                           |
//+------------------------------------------------------------------+
#pragma once

#include "params.mqh"

inline datetime ApplyOffset(datetime t, int offsetMinutes)
{
   return t + offsetMinutes * 60;
}

inline bool SessionAllowed(const SessionSettings &cfg, datetime now)
{
   if(!cfg.useSessions) return true;

   datetime shifted = ApplyOffset(now, cfg.offsetMinutes);
   MqlDateTime dt;
   TimeToStruct(shifted, dt);
   int hour = dt.hour;

   bool inLondon = (hour >= cfg.londonStart && hour < cfg.londonEnd);
   bool inNy     = (hour >= cfg.nyStart && hour < cfg.nyEnd);
   if(!(inLondon || inNy)) return false;

   if(cfg.avoidFridayLate && dt.day_of_week == 5 && hour >= cfg.fridayCutoffHour)
      return false;

   return true;
}
