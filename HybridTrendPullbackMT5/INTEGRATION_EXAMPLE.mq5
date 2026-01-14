//+------------------------------------------------------------------+
//| INTEGRATION EXAMPLE: How to Add Fundamental Analysis              |
//| This shows the modifications needed to integrate                |
//| FundamentalAnalysis.mqh into HybridTrendPullbackMT5              |
//+------------------------------------------------------------------+

// ===== STEP 1: Add Include at Top of EA =====
#include "core/FundamentalAnalysis.mqh"  // Add this line

// ===== STEP 2: Add Input Parameters =====
input group "===== Fundamental Analysis ====="
input bool     InpUseFundamentalFilter = true;     // Enable fundamental analysis
input bool     InpUseNewsBlocking = true;         // Block trading during news
input int      InpNewsBlockMinutesBefore = 30;     // Block X minutes before news
input int      InpNewsBlockMinutesAfter = 60;      // Block X minutes after news
input int      InpMinCombinedScore = 15;           // Minimum score to trade (0-20)
input string   InpNewsTimes = "";                  // News times (empty = auto-detect)

// ===== STEP 3: Add Global Variables =====
EconomicCalendar g_calendar;  // Add this global variable

// ===== STEP 4: Modify OnInit() =====
int OnInit()
{
   // ... existing initialization code ...
   
   // Initialize Economic Calendar
   if(InpUseFundamentalFilter)
   {
      string newsTimes = InpNewsTimes;
      if(StringLen(newsTimes) == 0)
         newsTimes = GetDefaultNewsTimes(InpSymbol); // Auto-detect
      
      g_calendar.Initialize(newsTimes);
      
      Print("✅ Fundamental Analysis Enabled");
      Print("   News Times: ", newsTimes);
      Print("   Block Before: ", InpNewsBlockMinutesBefore, " minutes");
      Print("   Block After: ", InpNewsBlockMinutesAfter, " minutes");
      Print("   Min Combined Score: ", InpMinCombinedScore);
   }
   
   return(INIT_SUCCEEDED);
}

// ===== STEP 5: Modify Entry Logic =====
bool CheckEntryConditions()
{
   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick)) return false;
   
   // ===== FUNDAMENTAL FILTER (Defensive) =====
   if(InpUseFundamentalFilter && InpUseNewsBlocking)
   {
      if(g_calendar.IsNewsApproaching(InpSymbol, InpNewsBlockMinutesBefore, InpNewsBlockMinutesAfter))
      {
         static datetime lastNewsLog = 0;
         if(TimeCurrent() - lastNewsLog > 300) // Log every 5 minutes
         {
            Print("⏸️ Trading blocked: News approaching");
            lastNewsLog = TimeCurrent();
         }
         return false; // Block trade
      }
   }
   
   // ===== TECHNICAL ANALYSIS (Existing Logic) =====
   int trendBias = GetTrendBias();
   if(trendBias == 0) return false;
   
   double atr = 0;
   if(!CheckVolatility(atr, tick)) return false;
   
   // ... rest of technical checks ...
   
   // Calculate technical score (0-10)
   int technicalScore = 0;
   if(trendBias != 0) technicalScore += 3;  // Trend confirmed
   if(CheckVolatility(atr, tick)) technicalScore += 2;  // Volatility OK
   // ... add more technical scoring ...
   
   // ===== FUNDAMENTAL BIAS (Offensive) =====
   int fundamentalBias = 0;
   if(InpUseFundamentalFilter)
   {
      fundamentalBias = g_calendar.GetFundamentalBias(InpSymbol);
   }
   
   // ===== COMBINED SCORE =====
   AnalysisScore score = CalculateCombinedScore(technicalScore, fundamentalBias, trendBias);
   
   if(!score.valid || score.combined < InpMinCombinedScore)
   {
      if(DebugMode)
         Print("❌ Signal rejected: ", score.reason, " (Score: ", score.combined, ")");
      return false;
   }
   
   // ===== ADJUST POSITION SIZE BASED ON NEWS =====
   double lotMultiplier = 1.0;
   if(InpUseFundamentalFilter)
   {
      lotMultiplier = g_calendar.GetPositionSizeMultiplier(InpSymbol, InpNewsBlockMinutesBefore);
   }
   
   // Use lotMultiplier when calculating position size
   // baseLotSize *= lotMultiplier;
   
   if(DebugMode)
   {
      Print("✅ Entry Signal Valid");
      Print("   Technical Score: ", score.technical, "/10");
      Print("   Fundamental Score: ", score.fundamental, "/10");
      Print("   Combined Score: ", score.combined, "/20");
      Print("   Reason: ", score.reason);
      Print("   Lot Multiplier: ", lotMultiplier);
   }
   
   return true;
}

// ===== STEP 6: Modify OnTick() =====
void OnTick()
{
   // ... existing code ...
   
   // Check entry conditions (now includes fundamental analysis)
   if(CheckEntryConditions())
   {
      // Open trade with adjusted lot size
      // ... existing trade opening code ...
   }
   
   // ... rest of OnTick() ...
}

//+------------------------------------------------------------------+
//| COMPLETE INTEGRATION CHECKLIST                                   |
//+------------------------------------------------------------------+
/*
✅ STEP 1: Add #include "core/FundamentalAnalysis.mqh"
✅ STEP 2: Add input parameters for fundamental analysis
✅ STEP 3: Add EconomicCalendar global variable
✅ STEP 4: Initialize calendar in OnInit()
✅ STEP 5: Add fundamental checks in entry logic
✅ STEP 6: Use combined score for entry decisions
✅ STEP 7: Adjust position size based on news proximity
✅ STEP 8: Test on demo account
✅ STEP 9: Monitor and optimize scores
*/


