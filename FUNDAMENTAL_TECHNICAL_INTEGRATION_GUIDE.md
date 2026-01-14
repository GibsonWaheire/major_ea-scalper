# Integrating Technical + Fundamental Analysis in EA

## 🎯 Overview

Combining **Technical Analysis** (price action, indicators) with **Fundamental Analysis** (economic news, events) creates a more robust trading system that:
- ✅ Avoids trading during volatile news events
- ✅ Aligns trades with fundamental market direction
- ✅ Reduces false signals from technical-only systems
- ✅ Improves win rate and risk management

---

## 📊 Current State Analysis

### ✅ What You Already Have (Technical Analysis)

**HybridTrendPullbackMT5** includes:
- ✅ Trend detection (EMA crossovers on H1)
- ✅ Pullback entries (M5 price action)
- ✅ Momentum confirmation (candle analysis)
- ✅ Volatility filters (ATR-based)
- ✅ Session filters (London/NY hours)
- ✅ Risk management (SL/TP, break-even, trailing)

### ❌ What's Missing (Fundamental Analysis)

- ❌ Economic calendar integration
- ❌ News impact assessment
- ❌ Fundamental bias detection
- ❌ News-based position sizing
- ❌ Pre/post news trading rules

---

## 🔧 Integration Strategy

### Approach 1: **Defensive** (News Avoidance)
- Block trading before/after high-impact news
- Close positions before major events
- Reduce position size during news periods

### Approach 2: **Offensive** (News Trading)
- Trade in direction of fundamental bias
- Increase position size on high-probability setups
- Use news events as confirmation

### Approach 3: **Hybrid** (Recommended)
- Avoid trading during news (defensive)
- Use fundamental bias to filter technical signals (offensive)
- Combine both for entry/exit decisions

---

## 💻 Implementation: Enhanced EA with Technical + Fundamental

### Step 1: Add Fundamental Analysis Module

Create a new include file: `FundamentalAnalysis.mqh`

```mql5
//+------------------------------------------------------------------+
//| FundamentalAnalysis.mqh - Economic Calendar & News Integration    |
//+------------------------------------------------------------------+
#property copyright "Fundamental Analysis Module"
#property version   "1.00"

// ===== News Event Structure =====
struct NewsEvent
{
   datetime   time;           // Event time (GMT)
   string     currency;       // Currency pair (USD, JPY, etc.)
   string     event;          // Event name (NFP, CPI, FOMC, etc.)
   int         impact;        // Impact level: 1=Low, 2=Medium, 3=High
   double      previous;      // Previous value
   double      forecast;      // Forecast value
   double      actual;        // Actual value (if released)
   bool        isReleased;    // Has the event occurred?
};

// ===== Economic Calendar Data =====
class EconomicCalendar
{
private:
   NewsEvent   events[];
   int         eventCount;
   datetime    lastUpdate;
   
public:
   EconomicCalendar() { eventCount = 0; lastUpdate = 0; }
   
   // Add news event manually or from calendar
   void AddEvent(datetime time, string currency, string eventName, int impact)
   {
      ArrayResize(events, eventCount + 1);
      events[eventCount].time = time;
      events[eventCount].currency = currency;
      events[eventCount].event = eventName;
      events[eventCount].impact = impact;
      events[eventCount].isReleased = false;
      eventCount++;
   }
   
   // Check if news is approaching
   bool IsNewsApproaching(string symbol, int minutesBefore = 30, int minutesAfter = 60)
   {
      datetime now = TimeCurrent();
      
      for(int i = 0; i < eventCount; i++)
      {
         if(events[i].isReleased) continue;
         
         // Extract base currency from symbol (e.g., USDJPY -> USD)
         string baseCurrency = StringSubstr(symbol, 0, 3);
         string quoteCurrency = StringSubstr(symbol, 3, 3);
         
         // Check if event affects this currency pair
         if(events[i].currency != baseCurrency && events[i].currency != quoteCurrency)
            continue;
         
         // Only check high-impact events
         if(events[i].impact < 3) continue;
         
         datetime eventTime = events[i].time;
         int minutesDiff = (int)((eventTime - now) / 60);
         
         // Block before news
         if(minutesDiff >= 0 && minutesDiff <= minutesBefore)
            return true;
         
         // Block after news
         if(minutesDiff < 0 && MathAbs(minutesDiff) <= minutesAfter)
            return true;
      }
      
      return false;
   }
   
   // Get fundamental bias for currency pair
   int GetFundamentalBias(string symbol)
   {
      // Returns: 1 = Bullish, -1 = Bearish, 0 = Neutral
      // This would integrate with economic data analysis
      // For now, returns neutral (can be enhanced with API)
      
      return 0; // Neutral by default
   }
   
   // Check if we should reduce position size due to news
   double GetPositionSizeMultiplier(string symbol)
   {
      if(IsNewsApproaching(symbol, 60, 60))
         return 0.5; // Reduce to 50% during news
      
      return 1.0; // Normal size
   }
};

// ===== High-Impact News Times (USDJPY) =====
// These are common high-impact news times for USD/JPY
string USDJPY_NewsTimes[] = {
   "08:30",  // US Employment Data
   "12:30",  // US CPI, PPI
   "13:30",  // US Retail Sales
   "14:00",  // FOMC Rate Decision
   "15:30",  // US Durable Goods
   "00:50",  // Japan Tankan Survey
   "02:30",  // Japan CPI
   "05:00"   // BOJ Rate Decision
};
```

---

### Step 2: Enhanced Entry Logic (Technical + Fundamental)

Modify the entry signal function to include fundamental checks:

```mql5
//+------------------------------------------------------------------+
//| Enhanced Entry Signal with Technical + Fundamental              |
//+------------------------------------------------------------------+
struct EnhancedEntrySignal
{
   bool        valid;              // Is signal valid?
   ENUM_ORDER_TYPE type;          // BUY or SELL
   double      price;             // Entry price
   double      sl;                 // Stop loss
   double      tp;                 // Take profit
   double      lotSize;            // Position size
   int         technicalScore;    // Technical analysis score (0-10)
   int         fundamentalScore;   // Fundamental analysis score (0-10)
   int         combinedScore;     // Combined score (0-20)
   string      reason;            // Entry reason
};

EnhancedEntrySignal BuildEnhancedSignal(EconomicCalendar &calendar)
{
   EnhancedEntrySignal signal;
   signal.valid = false;
   signal.technicalScore = 0;
   signal.fundamentalScore = 0;
   signal.combinedScore = 0;
   
   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick)) return signal;
   
   // ===== STEP 1: Fundamental Filter (Defensive) =====
   if(calendar.IsNewsApproaching(InpSymbol, 30, 60))
   {
      signal.reason = "News approaching - trade blocked";
      return signal; // Block trade
   }
   
   // ===== STEP 2: Technical Analysis (Existing Logic) =====
   int trendBias = GetTrendBias();
   if(trendBias == 0)
   {
      signal.reason = "No clear trend bias";
      return signal;
   }
   signal.technicalScore += 3; // Trend confirmed
   
   double atr = 0;
   if(!CheckVolatility(atr, tick)) return signal;
   signal.technicalScore += 2; // Volatility OK
   
   // Pullback check
   double emaEntry[1];
   if(CopyBuffer(g_emaEntry, 0, 1, 1, emaEntry) <= 0) return signal;
   
   double close[1];
   if(CopyClose(InpSymbol, InpEntryTf, 1, 1, close) <= 0) return signal;
   
   double pullbackDist = atr * InpPullbackAtrMult;
   bool pullbackOk = false;
   
   if(trendBias > 0)
      pullbackOk = (close[0] <= emaEntry[0] + pullbackDist);
   else
      pullbackOk = (close[0] >= emaEntry[0] - pullbackDist);
   
   if(!pullbackOk) return signal;
   signal.technicalScore += 2; // Pullback confirmed
   
   // Momentum check
   if(!MomentumOk(atr)) return signal;
   signal.technicalScore += 3; // Momentum confirmed
   
   // Total technical score: 10/10
   
   // ===== STEP 3: Fundamental Bias (Offensive) =====
   int fundamentalBias = calendar.GetFundamentalBias(InpSymbol);
   
   // Align fundamental bias with technical signal
   if(fundamentalBias == trendBias)
   {
      signal.fundamentalScore = 10; // Perfect alignment
      signal.reason = "Technical + Fundamental alignment";
   }
   else if(fundamentalBias == 0)
   {
      signal.fundamentalScore = 5; // Neutral fundamental
      signal.reason = "Technical signal, neutral fundamental";
   }
   else
   {
      signal.fundamentalScore = 2; // Conflict
      signal.reason = "Technical vs Fundamental conflict";
   }
   
   // ===== STEP 4: Combined Score =====
   signal.combinedScore = signal.technicalScore + signal.fundamentalScore;
   
   // Only trade if combined score >= 15 (75% confidence)
   if(signal.combinedScore < 15)
   {
      signal.reason += " - Score too low: " + IntegerToString(signal.combinedScore);
      return signal;
   }
   
   // ===== STEP 5: Build Trade Parameters =====
   signal.type = (trendBias > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   signal.price = (trendBias > 0) ? tick.ask : tick.bid;
   
   double stopDist = atr * InpSlAtrMult;
   double takeDist = atr * InpTpAtrMult;
   
   signal.sl = (trendBias > 0) ? signal.price - stopDist : signal.price + stopDist;
   signal.tp = (trendBias > 0) ? signal.price + takeDist : signal.price - takeDist;
   
   // Adjust position size based on fundamental analysis
   double baseLot = CalculateLotSize(stopDist);
   double multiplier = calendar.GetPositionSizeMultiplier(InpSymbol);
   signal.lotSize = baseLot * multiplier;
   
   signal.valid = true;
   return signal;
}
```

---

### Step 3: Economic Calendar Integration Options

#### Option A: Manual News Times (Simple)
```mql5
// Simple time-based news filter (like SmartGridGBPUSD)
input string NewsTimes = "08:30,12:30,13:30,14:00,15:30";
```

#### Option B: Economic Calendar API (Advanced)
```mql5
// Integrate with economic calendar API
// Examples: ForexFactory, Investing.com, TradingEconomics

// Using WebRequest to fetch calendar data
string FetchEconomicCalendar()
{
   string url = "https://api.forexfactory.com/calendar";
   char data[];
   char result[];
   string headers;
   
   int res = WebRequest("GET", url, "", "", 5000, data, 0, result, headers);
   
   if(res == 200)
   {
      // Parse JSON response
      // Extract high-impact events
      // Return formatted data
   }
   
   return "";
}
```

#### Option C: MQL5 Economic Calendar (Native)
```mql5
// MT5 has built-in economic calendar functions
#include <Trade\Calendar.mqh>

CCalendar calendar;

void LoadEconomicEvents()
{
   // Load events for specific date range
   datetime from = TimeCurrent();
   datetime to = from + PeriodSeconds(PERIOD_D1) * 7; // Next 7 days
   
   if(calendar.Load(from, to))
   {
      int total = calendar.EventsTotal();
      
      for(int i = 0; i < total; i++)
      {
         CCalendarEvent* event = calendar.EventByIndex(i);
         
         if(event.Impact() == CALENDAR_IMPACT_HIGH)
         {
            // Add to news filter
            AddNewsEvent(event.Time(), event.Currency(), event.Name(), 3);
         }
      }
   }
}
```

---

### Step 4: Fundamental Bias Detection

```mql5
//+------------------------------------------------------------------+
//| Calculate Fundamental Bias from Economic Data                    |
//+------------------------------------------------------------------+
int CalculateFundamentalBias(string symbol)
{
   // Extract currencies
   string base = StringSubstr(symbol, 0, 3);   // USD
   string quote = StringSubstr(symbol, 3, 3);   // JPY
   
   int baseScore = 0;
   int quoteScore = 0;
   
   // Analyze base currency fundamentals
   // This would integrate with economic indicators:
   // - GDP growth
   // - Interest rates
   // - Inflation (CPI)
   // - Employment data
   // - Central bank policy
   
   // Example: USD strength indicators
   if(GetUSDInterestRate() > GetJPYInterestRate())
      baseScore += 2; // USD stronger
   
   if(GetUSDGDPGrowth() > 2.0)
      baseScore += 1; // Strong economy
   
   if(GetUSDCPI() < 2.0)
      baseScore += 1; // Low inflation (good)
   
   // Analyze quote currency fundamentals
   if(GetJPYInterestRate() < 0)
      quoteScore -= 1; // Negative rates (weak)
   
   // Calculate bias
   int bias = baseScore - quoteScore;
   
   if(bias > 2) return 1;      // Bullish (base stronger)
   if(bias < -2) return -1;    // Bearish (base weaker)
   return 0;                   // Neutral
}
```

---

### Step 5: Complete Integration in Main EA

```mql5
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // ... existing initialization ...
   
   // Initialize Economic Calendar
   EconomicCalendar calendar;
   
   // Add high-impact news events (manual or from API)
   calendar.AddEvent(StringToTime("2025-12-15 08:30"), "USD", "NFP", 3);
   calendar.AddEvent(StringToTime("2025-12-15 12:30"), "USD", "CPI", 3);
   calendar.AddEvent(StringToTime("2025-12-15 14:00"), "USD", "FOMC", 3);
   
   // Store calendar in global variable
   // (You'll need to make it a global or class member)
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // ... existing code ...
   
   // Check if we already have a position
   if(InpOnePositionOnly && PositionSelect(InpSymbol))
      return;
   
   // ===== FUNDAMENTAL FILTER (Defensive) =====
   if(calendar.IsNewsApproaching(InpSymbol, 30, 60))
   {
      if(DebugMode)
         Print("⏸️ Trading blocked: News approaching");
      return; // Don't trade
   }
   
   // ===== TECHNICAL + FUNDAMENTAL SIGNAL =====
   EnhancedEntrySignal signal = BuildEnhancedSignal(calendar);
   
   if(!signal.valid)
   {
      if(DebugMode)
         Print("❌ No valid signal: ", signal.reason, " (Score: ", signal.combinedScore, ")");
      return;
   }
   
   // ===== ENTER TRADE =====
   if(signal.type == ORDER_TYPE_BUY)
   {
      trade.Buy(signal.lotSize, InpSymbol, signal.price, signal.sl, signal.tp, 
                "Tech+Fund: " + IntegerToString(signal.combinedScore));
   }
   else
   {
      trade.Sell(signal.lotSize, InpSymbol, signal.price, signal.sl, signal.tp, 
                 "Tech+Fund: " + IntegerToString(signal.combinedScore));
   }
   
   Print("✅ Trade opened: ", EnumToString(signal.type), 
         " | Tech Score: ", signal.technicalScore,
         " | Fund Score: ", signal.fundamentalScore,
         " | Combined: ", signal.combinedScore);
}
```

---

## 📋 Implementation Checklist

### Phase 1: Basic News Filter (Defensive)
- [ ] Add news time input parameters
- [ ] Implement `IsNewsTime()` function
- [ ] Block trading 30 min before / 60 min after news
- [ ] Test on demo account

### Phase 2: Enhanced Entry Logic
- [ ] Create `EnhancedEntrySignal` structure
- [ ] Add technical score calculation
- [ ] Add fundamental score calculation
- [ ] Implement combined scoring system
- [ ] Set minimum score threshold (e.g., 15/20)

### Phase 3: Economic Calendar Integration
- [ ] Choose integration method (Manual/API/MT5 Calendar)
- [ ] Implement news event loading
- [ ] Add high-impact event detection
- [ ] Test calendar data accuracy

### Phase 4: Fundamental Bias Detection
- [ ] Research economic indicators for your pairs
- [ ] Implement bias calculation logic
- [ ] Add position size multiplier based on news
- [ ] Backtest fundamental bias accuracy

### Phase 5: Advanced Features
- [ ] Pre-news position reduction
- [ ] Post-news re-entry logic
- [ ] News impact assessment
- [ ] Multi-currency fundamental analysis

---

## 🎯 Recommended Configuration

### For USDJPY Trading:

```mql5
// Fundamental Analysis Settings
input group "===== Fundamental Analysis ====="
input bool     UseFundamentalFilter = true;     // Enable fundamental analysis
input bool     UseNewsBlocking = true;          // Block trading during news
input int      NewsBlockMinutesBefore = 30;     // Block X minutes before news
input int      NewsBlockMinutesAfter = 60;      // Block X minutes after news
input int      MinCombinedScore = 15;           // Minimum score to trade (0-20)
input double   NewsPositionMultiplier = 0.5;    // Reduce size during news periods

// High-Impact News Times (GMT)
input string   USDNewsTimes = "08:30,12:30,13:30,14:00,15:30";
input string   JPYNewsTimes = "00:50,02:30,05:00";
```

---

## 📊 Scoring System Example

### Technical Score (0-10):
- Trend Bias: 3 points
- Volatility OK: 2 points
- Pullback Confirmed: 2 points
- Momentum Confirmed: 3 points

### Fundamental Score (0-10):
- Perfect Alignment: 10 points (Tech + Fund agree)
- Neutral Fundamental: 5 points (No fundamental bias)
- Conflict: 2 points (Tech vs Fund disagree)

### Combined Score (0-20):
- **18-20**: Excellent setup (trade with full size)
- **15-17**: Good setup (trade with normal size)
- **12-14**: Moderate setup (reduce size by 50%)
- **<12**: Poor setup (don't trade)

---

## 🔗 Resources for Economic Data

1. **ForexFactory Calendar**: https://www.forexfactory.com/calendar
2. **Investing.com Economic Calendar**: https://www.investing.com/economic-calendar/
3. **TradingEconomics**: https://tradingeconomics.com/calendar
4. **MT5 Economic Calendar**: Built-in MQL5 functions
5. **Central Bank Websites**: Fed, BOJ, ECB announcements

---

## ⚠️ Important Notes

1. **News Data Accuracy**: Manual news times need regular updates
2. **API Limitations**: Free APIs may have rate limits
3. **Time Zone Handling**: Always use GMT/UTC for consistency
4. **Backtesting**: Fundamental data may not be available in backtests
5. **Market Impact**: High-impact news can cause slippage and gaps

---

## 🚀 Next Steps

1. **Start Simple**: Implement basic news time blocking first
2. **Test Thoroughly**: Demo test for 2-4 weeks
3. **Gradually Enhance**: Add fundamental bias detection later
4. **Monitor Performance**: Track how fundamental filter affects results
5. **Optimize**: Adjust scoring thresholds based on results

---

**Ready to implement?** I can help you:
1. Add the fundamental analysis module to HybridTrendPullbackMT5
2. Integrate economic calendar
3. Create the enhanced entry signal logic
4. Test and optimize the combined system

Let me know which approach you prefer!


