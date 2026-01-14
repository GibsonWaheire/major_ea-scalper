//+------------------------------------------------------------------+
//| FinnhubEconomicCalendar.mqh - Finnhub API Integration           |
//| Approach 2: Offensive News Trading                               |
//| Uses news events as confirmation for technical signals          |
//+------------------------------------------------------------------+
#property copyright "Finnhub Economic Calendar Integration"
#property version   "1.00"

// #include <Standard Library\Json.mqh>  // MQL5 Standard Library JSON parser (optional - currently using basic parsing)

// ===== Economic Event Structure =====
struct EconomicEvent
{
   datetime   time;           // Event time (Unix timestamp)
   string     currency;       // Currency code (USD, JPY, EUR, etc.)
   string     event;          // Event name
   string     impact;         // Impact: "high", "medium", "low"
   double     actual;         // Actual value (if released)
   double     forecast;       // Forecast value
   double     previous;       // Previous value
   bool       isReleased;     // Has event occurred?
   int         impactLevel;    // 1=Low, 2=Medium, 3=High
};

// ===== Finnhub API Class =====
class FinnhubEconomicCalendar
{
private:
   string      apiKey;
   string      baseUrl;
   datetime    lastUpdate;
   int         updateInterval;  // Update every X minutes
   EconomicEvent events[];
   int         eventCount;
   bool        isInitialized;
   
public:
   FinnhubEconomicCalendar(string key)
   {
      apiKey = key;
      baseUrl = "https://finnhub.io/api/v1/calendar/economic";
      lastUpdate = 0;
      updateInterval = 60; // Update every 60 minutes
      eventCount = 0;
      isInitialized = false;
      ArrayResize(events, 0);
   }
   
   // Initialize and load economic calendar
   bool Initialize()
   {
      if(StringLen(apiKey) == 0)
      {
         Print("❌ Finnhub API key not set");
         return false;
      }
      
      // Enable WebRequest in MT5 settings first!
      if(!LoadEconomicCalendar())
      {
         Print("⚠️ Failed to load economic calendar. Check API key and WebRequest settings.");
         return false;
      }
      
      isInitialized = true;
      Print("✅ Finnhub Economic Calendar initialized. Loaded ", eventCount, " events");
      return true;
   }
   
   // Load economic calendar from Finnhub API
   bool LoadEconomicCalendar()
   {
      datetime now = TimeCurrent();
      
      // Only update if interval has passed
      if(now - lastUpdate < updateInterval * 60)
         return (eventCount > 0); // Return true if we already have data
      
      // Get today's date and next 7 days
      MqlDateTime dt;
      TimeToStruct(now, dt);
      
      string fromDate = StringFormat("%04d-%02d-%02d", dt.year, dt.mon, dt.day);
      
      // Calculate 7 days ahead
      datetime futureDate = now + PeriodSeconds(PERIOD_D1) * 7;
      TimeToStruct(futureDate, dt);
      string toDate = StringFormat("%04d-%02d-%02d", dt.year, dt.mon, dt.day);
      
      // Build API URL
      string url = baseUrl + "?from=" + fromDate + "&to=" + toDate + "&token=" + apiKey;
      
      // Make WebRequest
      char data[];
      char result[];
      string headers;
      int timeout = 5000;
      
      int res = WebRequest("GET", url, "", NULL, timeout, data, 0, result, headers);
      
      if(res != 200)
      {
         Print("❌ WebRequest failed: ", res, " | URL: ", url);
         if(res == -1)
            Print("⚠️ Check: Tools > Options > Expert Advisors > Allow WebRequest for listed URL");
         return false;
      }
      
      // Parse JSON response
      string jsonString = CharArrayToString(result);
      
      if(!ParseEconomicCalendar(jsonString))
      {
         Print("❌ Failed to parse economic calendar JSON");
         return false;
      }
      
      lastUpdate = now;
      return true;
   }
   
   // Parse JSON response from Finnhub
   bool ParseEconomicCalendar(string json)
   {
      // Note: This is a simplified parser. You may need JAson.mqh for full parsing
      // For now, we'll use basic string parsing
      
      // Clear existing events
      eventCount = 0;
      ArrayResize(events, 0);
      
      // Finnhub returns: {"economicCalendar": [...]}
      // Each event has: time, currency, event, impact, actual, forecast, previous
      
      // Find economicCalendar array
      int startPos = StringFind(json, "\"economicCalendar\"");
      if(startPos < 0)
      {
         Print("❌ No economicCalendar found in response");
         return false;
      }
      
      // Find array start
      int arrayStart = StringFind(json, "[", startPos);
      if(arrayStart < 0) return false;
      
      // Find array end
      int arrayEnd = StringFind(json, "]", arrayStart);
      if(arrayEnd < 0) return false;
      
      // Extract array content
      string arrayContent = StringSubstr(json, arrayStart + 1, arrayEnd - arrayStart - 1);
      
      // Parse events (simplified - assumes events are separated by },{)
      int pos = 0;
      int eventStart = 0;
      
      while((eventStart = StringFind(arrayContent, "{", pos)) >= 0)
      {
         int eventEnd = StringFind(arrayContent, "}", eventStart);
         if(eventEnd < 0) break;
         
         string eventJson = StringSubstr(arrayContent, eventStart, eventEnd - eventStart + 1);
         
         EconomicEvent event;
         if(ParseEvent(eventJson, event))
         {
            ArrayResize(events, eventCount + 1);
            events[eventCount] = event;
            eventCount++;
         }
         
         pos = eventEnd + 1;
      }
      
      return (eventCount > 0);
   }
   
   // Parse individual event from JSON
   bool ParseEvent(string eventJson, EconomicEvent &event)
   {
      // Extract fields using basic string parsing
      // This is simplified - full JSON parser would be better
      
      // Extract time (Unix timestamp)
      int timePos = StringFind(eventJson, "\"time\":");
      if(timePos >= 0)
      {
         int timeStart = StringFind(eventJson, ":", timePos) + 1;
         int timeEnd = StringFind(eventJson, ",", timeStart);
         if(timeEnd < 0) timeEnd = StringFind(eventJson, "}", timeStart);
         
         string timeStr = StringSubstr(eventJson, timeStart, timeEnd - timeStart);
         StringTrimLeft(timeStr);
         StringTrimRight(timeStr);
         event.time = (datetime)StringToInteger(timeStr);
      }
      
      // Extract currency
      int currPos = StringFind(eventJson, "\"currency\":");
      if(currPos >= 0)
      {
         int currStart = StringFind(eventJson, "\"", currPos + 11) + 1;
         int currEnd = StringFind(eventJson, "\"", currStart);
         event.currency = StringSubstr(eventJson, currStart, currEnd - currStart);
      }
      
      // Extract event name
      int eventPos = StringFind(eventJson, "\"event\":");
      if(eventPos >= 0)
      {
         int eventStart = StringFind(eventJson, "\"", eventPos + 8) + 1;
         int eventEnd = StringFind(eventJson, "\"", eventStart);
         event.event = StringSubstr(eventJson, eventStart, eventEnd - eventStart);
      }
      
      // Extract impact
      int impactPos = StringFind(eventJson, "\"impact\":");
      if(impactPos >= 0)
      {
         int impactStart = StringFind(eventJson, "\"", impactPos + 9) + 1;
         int impactEnd = StringFind(eventJson, "\"", impactStart);
         string impactStr = StringSubstr(eventJson, impactStart, impactEnd - impactStart);
         
         if(impactStr == "high") event.impactLevel = 3;
         else if(impactStr == "medium") event.impactLevel = 2;
         else event.impactLevel = 1;
         
         event.impact = impactStr;
      }
      
      // Extract actual, forecast, previous (if available)
      event.actual = 0;
      event.forecast = 0;
      event.previous = 0;
      
      // Check if event has occurred
      event.isReleased = (event.time < TimeCurrent());
      
      return (StringLen(event.currency) > 0 && StringLen(event.event) > 0);
   }
   
   // Get fundamental bias for currency pair (Approach 2: Offensive)
   int GetFundamentalBias(string symbol, int &confidence)
   {
      confidence = 0;
      
      if(!isInitialized || eventCount == 0)
         return 0; // Neutral if no data
      
      string baseCurrency = StringSubstr(symbol, 0, 3);
      string quoteCurrency = StringSubstr(symbol, 3, 3);
      
      int baseScore = 0;
      int quoteScore = 0;
      int highImpactCount = 0;
      
      datetime now = TimeCurrent();
      datetime lookAhead = now + PeriodSeconds(PERIOD_D1) * 3; // Next 3 days
      
      // Analyze upcoming high-impact events
      for(int i = 0; i < eventCount; i++)
      {
         if(events[i].time < now || events[i].time > lookAhead) continue;
         if(events[i].impactLevel < 3) continue; // Only high-impact
         
         highImpactCount++;
         
         // Check if event affects base currency
         if(events[i].currency == baseCurrency)
         {
            // Positive events (GDP growth, employment, etc.) = bullish
            // Negative events (recession, high unemployment) = bearish
            // For now, we'll use a simple heuristic based on event type
            if(StringFind(events[i].event, "GDP") >= 0 || 
               StringFind(events[i].event, "Employment") >= 0 ||
               StringFind(events[i].event, "Retail Sales") >= 0)
            {
               baseScore += 2; // Positive economic indicator
            }
            else if(StringFind(events[i].event, "Unemployment") >= 0 ||
                    StringFind(events[i].event, "CPI") >= 0) // High CPI can be negative
            {
               // Check if actual vs forecast
               if(events[i].isReleased && events[i].actual > 0)
               {
                  if(StringFind(events[i].event, "Unemployment") >= 0)
                     baseScore -= 2; // High unemployment = bearish
                  // CPI is more complex - skip for now
               }
            }
         }
         
         // Check if event affects quote currency
         if(events[i].currency == quoteCurrency)
         {
            // Inverse logic for quote currency
            if(StringFind(events[i].event, "GDP") >= 0 || 
               StringFind(events[i].event, "Employment") >= 0)
            {
               quoteScore += 2; // Strong quote = bearish for pair
            }
         }
      }
      
      // Calculate bias
      int netScore = baseScore - quoteScore;
      
      // Confidence based on number of high-impact events
      if(highImpactCount >= 3) confidence = 10; // Very confident
      else if(highImpactCount >= 2) confidence = 7;
      else if(highImpactCount >= 1) confidence = 5;
      else confidence = 3;
      
      if(netScore > 2) return 1;      // Bullish
      if(netScore < -2) return -1;    // Bearish
      return 0;                        // Neutral
   }
   
   // Check if high-impact news is approaching (for position sizing)
   bool IsHighImpactNewsApproaching(string symbol, int minutesBefore = 60)
   {
      if(!isInitialized || eventCount == 0) return false;
      
      string baseCurrency = StringSubstr(symbol, 0, 3);
      string quoteCurrency = StringSubstr(symbol, 3, 3);
      
      datetime now = TimeCurrent();
      
      for(int i = 0; i < eventCount; i++)
      {
         if(events[i].isReleased) continue;
         if(events[i].impactLevel < 3) continue; // Only high-impact
         
         // Check if event affects this pair
         if(events[i].currency != baseCurrency && events[i].currency != quoteCurrency)
            continue;
         
         int minutesDiff = (int)((events[i].time - now) / 60);
         
         // Check if within time window
         if(minutesDiff >= 0 && minutesDiff <= minutesBefore)
            return true;
      }
      
      return false;
   }
   
   // Get position size multiplier based on fundamental alignment (Approach 2)
   double GetPositionSizeMultiplier(string symbol, int technicalBias, int fundamentalBias, int confidence)
   {
      // Approach 2: Offensive - Increase size when fundamentals align
      
      // Perfect alignment: Technical + Fundamental agree
      if(technicalBias == fundamentalBias && technicalBias != 0 && confidence >= 7)
      {
         return 1.5; // Increase to 150% when both agree with high confidence
      }
      
      // Good alignment: Technical + Fundamental agree (medium confidence)
      if(technicalBias == fundamentalBias && technicalBias != 0 && confidence >= 5)
      {
         return 1.25; // Increase to 125%
      }
      
      // Neutral fundamental: Use normal size
      if(fundamentalBias == 0)
      {
         return 1.0; // Normal size
      }
      
      // Conflict: Technical vs Fundamental disagree
      if(technicalBias != 0 && fundamentalBias != 0 && technicalBias != fundamentalBias)
      {
         return 0.5; // Reduce to 50% when they conflict
      }
      
      return 1.0; // Default: normal size
   }
   
   // Get upcoming high-impact events for logging
   string GetUpcomingEvents(string symbol, int count = 3)
   {
      if(!isInitialized || eventCount == 0) return "No events";
      
      string baseCurrency = StringSubstr(symbol, 0, 3);
      string quoteCurrency = StringSubstr(symbol, 3, 3);
      
      string result = "";
      int found = 0;
      datetime now = TimeCurrent();
      
      for(int i = 0; i < eventCount && found < count; i++)
      {
         if(events[i].isReleased) continue;
         if(events[i].impactLevel < 3) continue;
         
         if(events[i].currency == baseCurrency || events[i].currency == quoteCurrency)
         {
            if(result != "") result += ", ";
            result += events[i].event + " (" + events[i].currency + ")";
            found++;
         }
      }
      
      return (result == "" ? "No upcoming events" : result);
   }
   
   // Force refresh of calendar data
   void Refresh()
   {
      lastUpdate = 0;
      LoadEconomicCalendar();
   }
   
   int GetEventCount() { return eventCount; }
   bool IsInitialized() { return isInitialized; }
};

//+------------------------------------------------------------------+

