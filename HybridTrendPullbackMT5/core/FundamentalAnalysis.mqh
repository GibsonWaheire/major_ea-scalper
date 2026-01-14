//+------------------------------------------------------------------+
//| FundamentalAnalysis.mqh - Economic Calendar & News Integration   |
//| Combines Technical + Fundamental Analysis for Robust Trading    |
//+------------------------------------------------------------------+
#property copyright "Fundamental Analysis Module"
#property version   "1.00"

// ===== News Event Structure =====
struct NewsEvent
{
   datetime   time;           // Event time (GMT)
   string     currency;       // Currency (USD, JPY, EUR, etc.)
   string     event;          // Event name (NFP, CPI, FOMC, etc.)
   int         impact;        // Impact: 1=Low, 2=Medium, 3=High
   bool        isReleased;    // Has event occurred?
};

// ===== Economic Calendar Class =====
class EconomicCalendar
{
private:
   NewsEvent   events[];
   int         eventCount;
   datetime    lastUpdate;
   string      newsTimesArray[];
   
public:
   EconomicCalendar() 
   { 
      eventCount = 0; 
      lastUpdate = 0;
      ArrayResize(events, 0);
      ArrayResize(newsTimesArray, 0);
   }
   
   // Initialize with news times string (e.g., "08:30,12:30,13:30")
   void Initialize(string newsTimes, string currencies = "USD,JPY")
   {
      ParseNewsTimes(newsTimes);
   }
   
   // Parse news times from comma-separated string
   void ParseNewsTimes(string newsTimesStr)
   {
      string tempStr = newsTimesStr;
      int count = 0;
      
      // Count commas
      for(int i = 0; i < StringLen(tempStr); i++)
      {
         if(StringGetCharacter(tempStr, i) == ',')
            count++;
      }
      
      ArrayResize(newsTimesArray, count + 1);
      count = 0;
      
      // Split by comma
      int start = 0;
      for(int i = 0; i <= StringLen(tempStr); i++)
      {
         if(i == StringLen(tempStr) || StringGetCharacter(tempStr, i) == ',')
         {
            string timeStr = StringSubstr(tempStr, start, i - start);
            StringTrimLeft(timeStr);
            StringTrimRight(timeStr);
            
            if(StringLen(timeStr) > 0)
            {
               newsTimesArray[count] = timeStr;
               count++;
            }
            start = i + 1;
         }
      }
      
      ArrayResize(newsTimesArray, count);
   }
   
   // Add specific news event
   void AddEvent(datetime time, string currency, string eventName, int impact)
   {
      ArrayResize(events, eventCount + 1);
      events[eventCount].time = time;
      events[eventCount].currency = currency;
      events[eventCount].event = eventName;
      events[eventCount].impact = impact;
      events[eventCount].isReleased = (time < TimeCurrent());
      eventCount++;
   }
   
   // Check if news is approaching (time-based)
   bool IsNewsTime(int blockMinutesBefore = 30, int blockMinutesAfter = 60)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      
      int currentMinutes = dt.hour * 60 + dt.min;
      
      // Check each news time
      for(int i = 0; i < ArraySize(newsTimesArray); i++)
      {
         string timeStr = newsTimesArray[i];
         int colonPos = StringFind(timeStr, ":");
         if(colonPos < 0) continue;
         
         int newsHour = (int)StringToInteger(StringSubstr(timeStr, 0, colonPos));
         int newsMin = (int)StringToInteger(StringSubstr(timeStr, colonPos + 1));
         int newsMinutes = newsHour * 60 + newsMin;
         
         // Calculate minutes until news
         int minutesUntilNews = newsMinutes - currentMinutes;
         
         // Handle day rollover
         if(minutesUntilNews < 0)
            minutesUntilNews += 1440; // Add 24 hours
         
         // Block before news
         if(minutesUntilNews <= blockMinutesBefore)
         {
            // Check if we're past the news time
            int minutesAfterNews = currentMinutes - newsMinutes;
            if(minutesAfterNews < 0)
               minutesAfterNews += 1440;
            
            // Block after news too
            if(minutesAfterNews <= blockMinutesAfter)
               return true;
         }
      }
      
      return false;
   }
   
   // Check if news is approaching for specific symbol
   bool IsNewsApproaching(string symbol, int blockMinutesBefore = 30, int blockMinutesAfter = 60)
   {
      // First check time-based news
      if(IsNewsTime(blockMinutesBefore, blockMinutesAfter))
         return true;
      
      // Then check specific events
      datetime now = TimeCurrent();
      string baseCurrency = StringSubstr(symbol, 0, 3);
      string quoteCurrency = StringSubstr(symbol, 3, 3);
      
      for(int i = 0; i < eventCount; i++)
      {
         if(events[i].isReleased) continue;
         if(events[i].impact < 3) continue; // Only high-impact
         
         // Check if event affects this pair
         if(events[i].currency != baseCurrency && events[i].currency != quoteCurrency)
            continue;
         
         datetime eventTime = events[i].time;
         int minutesDiff = (int)((eventTime - now) / 60);
         
         // Block before news
         if(minutesDiff >= 0 && minutesDiff <= blockMinutesBefore)
            return true;
         
         // Block after news
         if(minutesDiff < 0 && MathAbs(minutesDiff) <= blockMinutesAfter)
            return true;
      }
      
      return false;
   }
   
   // Get position size multiplier based on news proximity
   double GetPositionSizeMultiplier(string symbol, int blockMinutesBefore = 60)
   {
      if(IsNewsApproaching(symbol, blockMinutesBefore, 0))
         return 0.5; // Reduce to 50% when news is approaching
      
      return 1.0; // Normal size
   }
   
   // Get fundamental bias (simplified - can be enhanced with API)
   int GetFundamentalBias(string symbol)
   {
      // Returns: 1 = Bullish, -1 = Bearish, 0 = Neutral
      // This is a placeholder - enhance with actual economic data
      
      // Example logic (simplified):
      // - Check interest rate differentials
      // - Check GDP growth rates
      // - Check inflation trends
      // - Check central bank policy
      
      // For now, return neutral (can be enhanced)
      return 0;
   }
   
   // Get number of events
   int GetEventCount() { return eventCount; }
};

// ===== Combined Analysis Score =====
struct AnalysisScore
{
   int technical;      // Technical analysis score (0-10)
   int fundamental;    // Fundamental analysis score (0-10)
   int combined;       // Combined score (0-20)
   string reason;      // Reason for score
   bool valid;         // Is signal valid?
};

// Calculate combined analysis score
AnalysisScore CalculateCombinedScore(int technicalScore, int fundamentalBias, int technicalBias)
{
   AnalysisScore score;
   score.technical = technicalScore;
   score.fundamental = 0;
   score.combined = 0;
   score.valid = false;
   
   // Fundamental score based on alignment
   if(fundamentalBias == technicalBias && technicalBias != 0)
   {
      score.fundamental = 10; // Perfect alignment
      score.reason = "Technical + Fundamental alignment";
   }
   else if(fundamentalBias == 0)
   {
      score.fundamental = 5; // Neutral fundamental
      score.reason = "Technical signal, neutral fundamental";
   }
   else if(technicalBias != 0)
   {
      score.fundamental = 2; // Conflict
      score.reason = "Technical vs Fundamental conflict";
   }
   else
   {
      score.reason = "No technical bias";
      return score;
   }
   
   // Combined score
   score.combined = score.technical + score.fundamental;
   
   // Signal is valid if combined score >= 15 (75% confidence)
   score.valid = (score.combined >= 15);
   
   if(!score.valid)
      score.reason += " - Score too low: " + IntegerToString(score.combined);
   
   return score;
}

//+------------------------------------------------------------------+
//| Get High-Impact News Times for Currency Pair                    |
//+------------------------------------------------------------------+
string GetDefaultNewsTimes(string symbol)
{
   string base = StringSubstr(symbol, 0, 3);
   string quote = StringSubstr(symbol, 3, 3);
   
   // USD News Times (GMT)
   if(base == "USD" || quote == "USD")
   {
      return "08:30,12:30,13:30,14:00,15:30"; // NFP, CPI, Retail Sales, FOMC, Durable Goods
   }
   
   // JPY News Times (GMT)
   if(base == "JPY" || quote == "JPY")
   {
      return "00:50,02:30,05:00"; // Tankan, CPI, BOJ
   }
   
   // EUR News Times (GMT)
   if(base == "EUR" || quote == "EUR")
   {
      return "08:00,09:00,12:00,13:00"; // GDP, CPI, ECB
   }
   
   // GBP News Times (GMT)
   if(base == "GBP" || quote == "GBP")
   {
      return "08:30,09:30"; // GDP, CPI, BOE
   }
   
   // Default: Common news times
   return "08:30,12:30,13:30,14:00";
}

//+------------------------------------------------------------------+


