#property copyright "QualityGapPro EA (c) 2025"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"
#property strict

// ============================================================================
// QualityGapPro EA - Phase 1: Complete Structure with Function Stubs
// ============================================================================
// Fair Value Gap + Candlestick Patterns + Market Structure + Quality Scoring
// ============================================================================

// ==== Input Parameters ======================================================

// ==== Symbol Selection ====
input string TradingSymbol = "GBPUSD";  // Trading symbol (GBPUSD or USDJPY)
input bool AutoSelectBestSymbol = true; // Auto-select best opportunity

// ==== Fair Value Gap Settings ====
input ENUM_TIMEFRAMES FVGTimeframe = PERIOD_M5;  // Primary FVG timeframe
input double MinFVGSizePips = 5.0;  // Minimum FVG size in pips
input bool RequireEMABias = true;  // Require EMA alignment
input int EMAFastPeriod = 21;  // Fast EMA period
input int EMASlowPeriod = 55;  // Slow EMA period

// ==== Candlestick Pattern Settings ====
input bool UseEngulfingPatterns = true;  // Enable engulfing patterns
input bool UsePinBars = true;  // Enable pin bar patterns
input bool UseInsideBars = false;  // Enable inside bar patterns
input double MinPinBarRatio = 0.6;  // Minimum pin bar tail ratio (60%)
input double MinEngulfingBodyRatio = 1.2;  // Minimum engulfing body ratio (120%)

// ==== Market Structure Settings ====
input bool UseOrderBlocks = true;  // Enable order block detection
input int OrderBlockLookback = 20;  // Order block lookback period
input bool UseLiquidityZones = true;  // Enable liquidity zone detection
input int LiquidityZoneLookback = 50;  // Liquidity zone lookback
input bool RequireStructureBreak = true;  // Require BOS/CHoCH for entry
input int SwingPointLookback = 5;  // Swing point detection lookback

// ==== Quality Filters ====
input int MinQualityScore = 6;  // Minimum quality score (out of 10)
input bool UseSessionFilter = true;  // Enable session filter
input int SessionStartHour = 8;  // Trading start hour (server time)
input int SessionEndHour = 17;  // Trading end hour (server time)
input double MaxSpreadPips = 2.0;  // Maximum spread (GBPUSD/USDJPY specific)
input double MaxATRPips = 100.0;  // Maximum ATR in pips (volatility cap)

// ==== Risk Management ====
input double RiskPercentPerTrade = 1.0;  // Risk % per trade
input double MinRiskReward = 2.0;  // Minimum risk/reward ratio
input bool UseDynamicStopLoss = true;  // Use structure-based stop loss
input double StructureStopBufferPips = 5.0;  // Stop loss buffer from structure
input int MaxConcurrentTrades = 3;  // Maximum concurrent trades
input int MaxDailyTrades = 50;  // Maximum trades per day
input double MaxDailyLossPercent = 5.0;  // Maximum daily loss %

// ==== Trade Management ====
input bool UsePartialCloses = true;  // Enable partial closes
input double PartialClose1Ratio = 0.5;  // Close 50% at 1R
input double PartialClose2Ratio = 0.3;  // Close 30% at 2R
input bool UseBreakEven = true;  // Enable break-even
input double BreakEvenTriggerPips = 1.5;  // Move to BE after 1.5R profit
input bool UseTrailingStop = true;  // Enable trailing stop
input double TrailingStartPips = 2.0;  // Start trailing after 2R
input double TrailingStepPips = 1.0;  // Trailing step in R multiples
input int MaxHoldSeconds = 3600;  // Maximum hold time (1 hour)
input bool UseTrendReversalProtection = true;  // Close on trend reversal
input int TrendReversalMinHoldSec = 60;  // Minimum hold before reversal check

// ==== Execution Settings ====
input int MagicNumber = 303025;  // Unique EA identifier
input int SlippagePips = 3;  // Maximum slippage
input bool TradeEnabled = true;  // Master trading switch

// ==== Display Settings ====
input bool ShowDashboard = true;  // Show on-chart dashboard
input color DashboardTextColor = clrWhite;  // Dashboard text color
input color DashboardValueColor = clrAqua;  // Dashboard value color

// ==== Visual Markers (Chart Objects) ====
input bool ShowVisualMarkers = true;  // Show trade markers on chart
input color BuyEntryColor = clrLimeGreen;  // Buy entry arrow color
input color SellEntryColor = clrRed;  // Sell entry arrow color
input color StopLossColor = clrOrangeRed;  // Stop loss line color
input color TakeProfitColor = clrDodgerBlue;  // Take profit line color
input int ArrowSize = 2;  // Entry arrow size (1-5)
input bool ShowEntryLabel = true;  // Show entry price label
input bool ShowSLLabel = true;  // Show stop loss label
input bool ShowTPLabel = true;  // Show take profit label

// ==== Fast Entry Mode (For Non-VPS Users) ====
input bool EnableFastEntryMode = true;  // Take trade within first minute
input int FastEntryWindowSeconds = 60;  // Fast entry window (default 60 seconds)
input int FastEntryMinQualityScore = 3;  // Lower quality threshold for fast entry (out of 10)
input bool FastEntryRequireFVG = false;  // Require FVG in fast mode (false = more aggressive)
input bool FastEntryRequirePattern = false;  // Require pattern in fast mode (false = more aggressive)
input bool FastEntryRequireStructure = false;  // Require structure in fast mode (false = more aggressive)

// ==== Constants =============================================================

#define FVG_BULLISH 1
#define FVG_BEARISH -1

#define PATTERN_BULLISH_ENGULFING 1
#define PATTERN_BEARISH_ENGULFING -1
#define PATTERN_BULLISH_PIN 2
#define PATTERN_BEARISH_PIN -2
#define PATTERN_INSIDE_BAR 3
#define PATTERN_THREE_WHITE_SOLDIERS 4
#define PATTERN_THREE_BLACK_CROWS -4

#define STRUCTURE_BULLISH_BOS 1
#define STRUCTURE_BEARISH_BOS -1
#define STRUCTURE_BULLISH_CHOCH 2
#define STRUCTURE_BEARISH_CHOCH -2
#define STRUCTURE_BULLISH_OB 3
#define STRUCTURE_BEARISH_OB -3

#define TRADE_DIRECTION_BULLISH 1
#define TRADE_DIRECTION_BEARISH -1

// ==== Global Variables =====================================================

datetime lastResetDate = 0;
int dailyTradeCount = 0;
double dailyStartingBalance = 0.0;

// Fast Entry Mode Tracking
datetime eaInitializationTime = 0;
bool fastEntryModeActive = false;
bool fastEntryTradeTaken = false;

// ==== Data Structures ======================================================

struct FVGData
{
   int type;  // FVG_BULLISH or FVG_BEARISH
   double size;
   double top;
   double bottom;
   ENUM_TIMEFRAMES timeframe;
   double qualityScore;
};

struct PatternData
{
   int type;  // Pattern type constant
   double strength;
   ENUM_TIMEFRAMES timeframe;
   double qualityScore;
};

struct SwingPoint
{
   int index;
   double price;
   datetime time;
};

struct SwingPointsData
{
   SwingPoint highs[];
   SwingPoint lows[];
};

struct OrderBlockData
{
   int type;  // STRUCTURE_BULLISH_OB or STRUCTURE_BEARISH_OB
   double top;
   double bottom;
   datetime time;
   double strength;
};

struct StructureData
{
   int bosType;  // BOS type or 0
   int chochType;  // CHoCH type or 0
   OrderBlockData orderBlocks[];
   SwingPointsData swingPoints;
   double qualityScore;
};

struct QualityScoreData
{
   double total;
   double max;
   double percentage;
   double fvgScore;
   double patternScore;
   double structureScore;
   double sessionScore;
};

struct EntryLevelsData
{
   double entryPrice;
   double stopLoss;
   double takeProfit;
   double riskPips;
   double rewardPips;
   double riskReward;
};

struct EntryValidationData
{
   bool valid;
   string reason;
   int direction;  // TRADE_DIRECTION_BULLISH or TRADE_DIRECTION_BEARISH
   FVGData fvg;
   PatternData pattern;
   QualityScoreData qualityScore;
   EntryLevelsData entry;
};

struct TradeData
{
   int ticket;
   bool partialClose1Done;
   bool partialClose2Done;
   EntryValidationData entryData;
};

TradeData tradeData[];

// ============================================================================
// ==== Utility Functions ====================================================
// ============================================================================

double GetPipSize(const string symbol)
{
   // TODO: Implement pip size calculation
   return 0.0;
}

double GetPipValuePerLot(const string symbol)
{
   // TODO: Implement pip value per lot calculation
   return 0.0;
}

double GetATRPips(const string symbol, const ENUM_TIMEFRAMES timeframe, const int period)
{
   // TODO: Implement ATR in pips calculation
   return 0.0;
}

double GetCurrentSpreadPips(const string symbol)
{
   // TODO: Implement current spread in pips calculation
   return 0.0;
}

int GetServerHour()
{
   // TODO: Implement server hour extraction
   return 0;
}

datetime GetTodayDate()
{
   // TODO: Implement today date extraction
   return 0;
}

datetime GetDateOfDay(const datetime time)
{
   // TODO: Implement date of day extraction
   return 0;
}

double NormalizeLot(const string symbol, const double volume)
{
   // TODO: Implement lot normalization
   return 0.0;
}

double GetRecentSwingHigh(const string symbol, const ENUM_TIMEFRAMES timeframe, const int lookback)
{
   // TODO: Implement recent swing high extraction
   return 0.0;
}

double GetRecentSwingLow(const string symbol, const ENUM_TIMEFRAMES timeframe, const int lookback)
{
   // TODO: Implement recent swing low extraction
   return 0.0;
}

double GetPatternSize(const PatternData &pattern, const string symbol, const ENUM_TIMEFRAMES timeframe)
{
   // TODO: Implement pattern size calculation
   return 0.0;
}

int CountOpenTrades(const int magic)
{
   // TODO: Implement open trades count
   return 0;
}

void CloseAllTrades(const int magic)
{
   // TODO: Implement close all trades
}

bool ModifyOrderStopLoss(const int ticket, const double newStopLoss)
{
   // TODO: Implement order stop loss modification
   return false;
}

bool ClosePartialOrder(const int ticket, const double lots)
{
   // TODO: Implement partial order close
   return false;
}

void StoreTradeData(const int ticket, const EntryValidationData &entryData)
{
   // TODO: Implement trade data storage
}

void InitializeGlobalVariables()
{
   // TODO: Implement global variables initialization
}

void LoadDailyStartingBalance()
{
   // TODO: Implement daily starting balance loading
}

void UpdateDailyCounters()
{
   // TODO: Implement daily counters update
}

void UpdateDailyTradeCount()
{
   // TODO: Implement daily trade count update
}

void CheckDailyReset()
{
   datetime today = GetTodayDate();
   
   if(today != lastResetDate)
   {
      // New day - reset counters
      lastResetDate = today;
      dailyTradeCount = 0;
      dailyStartingBalance = AccountBalance();
      
      // Reset fast entry mode for new day
      if(EnableFastEntryMode)
      {
         eaInitializationTime = TimeCurrent();
         fastEntryModeActive = true;
         fastEntryTradeTaken = false;
         Print("Daily reset: Fast Entry Mode reactivated for new trading day");
      }
      
      Print("Daily reset completed. New starting balance: ", dailyStartingBalance);
   }
}

// ============================================================================
// ==== FVG Detection ========================================================
// ============================================================================

FVGData DetectFVG(const string symbol, const ENUM_TIMEFRAMES timeframe, const int shift)
{
   FVGData fvg;
   ZeroMemory(fvg);
   // TODO: Implement FVG detection logic
   return fvg;
}

double AssessFVGQuality(const FVGData &fvg, const string symbol, const ENUM_TIMEFRAMES timeframe)
{
   // TODO: Implement FVG quality assessment
   return 0.0;
}

FVGData ScanForFVG(const string symbol)
{
   FVGData fvg;
   ZeroMemory(fvg);
   // TODO: Implement FVG scanning workflow
   return fvg;
}

// ============================================================================
// ==== Candlestick Patterns =================================================
// ============================================================================

PatternData DetectCandlestickPattern(const string symbol, const ENUM_TIMEFRAMES timeframe, const int shift)
{
   PatternData pattern;
   ZeroMemory(pattern);
   // TODO: Implement candlestick pattern detection
   return pattern;
}

double AssessPatternQuality(const PatternData &pattern, const string symbol, const ENUM_TIMEFRAMES timeframe)
{
   // TODO: Implement pattern quality assessment
   return 0.0;
}

// ============================================================================
// ==== Market Structure =====================================================
// ============================================================================

// === Market Structure: Swing Detection ===

SwingPointsData DetectSwingPoints(const string symbol, const ENUM_TIMEFRAMES timeframe, const int lookback)
{
   SwingPointsData swingPoints;
   // TODO: Implement swing points detection
   return swingPoints;
}

// === Market Structure: BOS ===

StructureData DetectBOS(const string symbol, const ENUM_TIMEFRAMES timeframe)
{
   StructureData structure;
   ZeroMemory(structure);
   // TODO: Implement BOS detection
   return structure;
}

// === Market Structure: CHoCH ===

StructureData DetectCHoCH(const string symbol, const ENUM_TIMEFRAMES timeframe)
{
   StructureData structure;
   ZeroMemory(structure);
   // TODO: Implement CHoCH detection
   return structure;
}

// === Market Structure: Order Blocks ===

void DetectOrderBlocks(const string symbol, const ENUM_TIMEFRAMES timeframe, const int lookback, OrderBlockData &orderBlocks[])
{
   // TODO: Implement order blocks detection
   ArrayResize(orderBlocks, 0);
}

// === Market Structure: Structure Scoring ===

double AssessMarketStructure(const string symbol, const ENUM_TIMEFRAMES timeframe, const int tradeDirection)
{
   // TODO: Implement market structure quality assessment
   return 0.0;
}

// ============================================================================
// ==== Quality Score ========================================================
// ============================================================================

QualityScoreData CalculateQualityScore(const FVGData &fvg, const PatternData &pattern, const double marketStructureScore, const double sessionScore, const string symbol)
{
   QualityScoreData score;
   ZeroMemory(score);
   // TODO: Implement quality score calculation
   return score;
}

bool IsQualityTrade(const QualityScoreData &qualityScore)
{
   // TODO: Implement quality trade check
   return false;
}

// ============================================================================
// ==== Entry Validation =====================================================
// ============================================================================

EntryValidationData ValidateEntry(const string symbol)
{
   EntryValidationData entry;
   ZeroMemory(entry);
   entry.valid = false;
   // TODO: Implement complete entry validation
   return entry;
}

// === Fast Entry Mode: Aggressive Entry for First Minute ===
EntryValidationData FastValidateEntry(const string symbol)
{
   EntryValidationData entry;
   ZeroMemory(entry);
   entry.valid = false;
   
   // Fast entry mode: More aggressive, lower thresholds
   // Check multiple timeframes immediately
   ENUM_TIMEFRAMES timeframes[];
   ArrayResize(timeframes, 4);
   timeframes[0] = PERIOD_M1;
   timeframes[1] = PERIOD_M5;
   timeframes[2] = PERIOD_M15;
   timeframes[3] = PERIOD_H1;
   
   double bestScore = 0.0;
   EntryValidationData bestEntry;
   ZeroMemory(bestEntry);
   
   // Scan all timeframes for opportunities
   for(int tf = 0; tf < ArraySize(timeframes); tf++)
   {
      // Try to detect FVG (even if not required, it helps)
      FVGData fvg = DetectFVG(symbol, timeframes[tf], 0);
      if(fvg.type == 0 && FastEntryRequireFVG) continue; // Skip if FVG required but not found
      
      // Try to detect pattern
      PatternData pattern = DetectCandlestickPattern(symbol, timeframes[tf], 0);
      if(pattern.type == 0 && FastEntryRequirePattern) continue; // Skip if pattern required but not found
      
      // Try to detect structure (simplified)
      double structureScore = AssessMarketStructure(symbol, timeframes[tf], (fvg.type > 0) ? TRADE_DIRECTION_BULLISH : TRADE_DIRECTION_BEARISH);
      if(structureScore == 0 && FastEntryRequireStructure) continue; // Skip if structure required but not found
      
      // Calculate basic quality score (simplified for fast mode)
      double qualityScore = 0.0;
      if(fvg.type != 0) qualityScore += 2.0; // FVG found
      if(pattern.type != 0) qualityScore += 2.0; // Pattern found
      if(structureScore > 0) qualityScore += structureScore; // Structure found
      
      // Check EMA bias (simple trend filter)
      double emaFast = iMA(symbol, timeframes[tf], EMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
      double emaSlow = iMA(symbol, timeframes[tf], EMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
      double currentPrice = (Ask + Bid) / 2.0;
      
      int direction = 0;
      if(fvg.type == FVG_BULLISH && currentPrice > emaFast && emaFast > emaSlow)
      {
         direction = TRADE_DIRECTION_BULLISH;
         qualityScore += 1.0; // EMA alignment bonus
      }
      else if(fvg.type == FVG_BEARISH && currentPrice < emaFast && emaFast < emaSlow)
      {
         direction = TRADE_DIRECTION_BEARISH;
         qualityScore += 1.0; // EMA alignment bonus
      }
      else if(fvg.type == 0)
      {
         // No FVG, use EMA trend
         if(currentPrice > emaFast && emaFast > emaSlow)
         {
            direction = TRADE_DIRECTION_BULLISH;
            qualityScore += 1.0;
         }
         else if(currentPrice < emaFast && emaFast < emaSlow)
         {
            direction = TRADE_DIRECTION_BEARISH;
            qualityScore += 1.0;
         }
      }
      
      if(direction == 0) continue; // No clear direction
      
      // Check if quality score meets fast entry threshold
      if(qualityScore < FastEntryMinQualityScore) continue;
      
      // Calculate entry levels (simplified)
      double entryPrice = (direction == TRADE_DIRECTION_BULLISH) ? Ask : Bid;
      double pipSize = GetPipSize(symbol);
      
      // Simple stop loss: 20 pips or structure-based
      double stopLoss = 0.0;
      if(direction == TRADE_DIRECTION_BULLISH)
      {
         stopLoss = entryPrice - (20.0 * pipSize * 10);
         if(fvg.type == FVG_BULLISH && fvg.bottom > 0)
         {
            stopLoss = fvg.bottom - (StructureStopBufferPips * pipSize * 10);
         }
      }
      else
      {
         stopLoss = entryPrice + (20.0 * pipSize * 10);
         if(fvg.type == FVG_BEARISH && fvg.top > 0)
         {
            stopLoss = fvg.top + (StructureStopBufferPips * pipSize * 10);
         }
      }
      
      // Take profit: 2R minimum
      double riskPips = MathAbs(entryPrice - stopLoss) / (pipSize * 10);
      double takeProfit = 0.0;
      if(direction == TRADE_DIRECTION_BULLISH)
      {
         takeProfit = entryPrice + (riskPips * MinRiskReward * pipSize * 10);
      }
      else
      {
         takeProfit = entryPrice - (riskPips * MinRiskReward * pipSize * 10);
      }
      
      // Check risk/reward
      double rewardPips = MathAbs(takeProfit - entryPrice) / (pipSize * 10);
      if(rewardPips / riskPips < MinRiskReward) continue;
      
      // This is a valid fast entry
      if(qualityScore > bestScore)
      {
         bestScore = qualityScore;
         bestEntry.valid = true;
         bestEntry.direction = direction;
         bestEntry.fvg = fvg;
         bestEntry.pattern = pattern;
         bestEntry.qualityScore.total = qualityScore;
         bestEntry.qualityScore.max = 10.0;
         bestEntry.qualityScore.percentage = (qualityScore / 10.0) * 100.0;
         bestEntry.entry.entryPrice = entryPrice;
         bestEntry.entry.stopLoss = stopLoss;
         bestEntry.entry.takeProfit = takeProfit;
         bestEntry.entry.riskPips = riskPips;
         bestEntry.entry.rewardPips = rewardPips;
         bestEntry.entry.riskReward = rewardPips / riskPips;
      }
   }
   
   return bestEntry;
}

EntryLevelsData CalculateEntryLevels(const FVGData &fvgData, const PatternData &pattern, const string symbol, const int direction)
{
   EntryLevelsData entry;
   ZeroMemory(entry);
   // TODO: Implement entry levels calculation
   return entry;
}

// ============================================================================
// ==== Exit / Trade Management =============================================
// ============================================================================

bool ManageStopLoss(const int ticket, const EntryLevelsData &entryData)
{
   // TODO: Implement stop loss management
   return false;
}

bool ManageBreakEven(const int ticket, const EntryLevelsData &entryData)
{
   // TODO: Implement break-even management
   return false;
}

bool ManageTrailingStop(const int ticket)
{
   // TODO: Implement trailing stop management
   return false;
}

bool ManagePartialCloses(const int ticket, const EntryLevelsData &entryData)
{
   // TODO: Implement partial closes management
   return false;
}

bool CheckTimeBasedExit(const int ticket)
{
   // TODO: Implement time-based exit check
   return false;
}

bool CheckTrendReversal(const int ticket)
{
   // TODO: Implement trend reversal protection
   return false;
}

void ManageOpenTrades()
{
   // TODO: Implement complete trade management workflow
   
   // Update visual markers based on current profit/loss
   if(ShowVisualMarkers)
   {
      UpdateAllActiveTradeMarkers();
   }
}

// ============================================================================
// ==== Session Filter =======================================================
// ============================================================================

double AssessSessionQuality(const string symbol)
{
   // TODO: Implement session quality assessment
   return 0.0;
}

bool IsSessionAllowed()
{
   // TODO: Implement session filter check
   return false;
}

// ============================================================================
// ==== Spread & Volatility Filters ===========================================
// ============================================================================

bool IsSpreadAcceptable(const string symbol)
{
   // TODO: Implement spread validation
   return false;
}

bool IsVolatilityAcceptable(const string symbol)
{
   // TODO: Implement volatility validation
   return false;
}

bool PreFlightChecks(const string symbol)
{
   // TODO: Implement pre-flight checks
   return false;
}

// ============================================================================
// ==== Risk Management =======================================================
// ============================================================================

double CalculatePositionSize(const string symbol, const double entryPrice, const double stopLoss, const double riskPercent)
{
   // TODO: Implement position sizing calculation
   return 0.0;
}

double GetDailyLossPercent()
{
   // TODO: Implement daily loss percent calculation
   return 0.0;
}

bool CheckDailyLossLimit()
{
   // TODO: Implement daily loss limit check
   return false;
}

int GetDailyTradeCount()
{
   // TODO: Implement daily trade count calculation
   return 0;
}

bool RiskManagementWorkflow()
{
   // TODO: Implement complete risk management workflow
   return false;
}

double GetDailyStartingBalance()
{
   // TODO: Implement daily starting balance getter
   return 0.0;
}

double CalculateMaxLotSize(const string symbol, const double entryPrice, const double stopLoss)
{
   // TODO: Implement max lot size calculation
   return 0.0;
}

// ============================================================================
// ==== Core EA Event Loop ====================================================
// ============================================================================

int OnInit()
{
   InitializeGlobalVariables();
   LoadDailyStartingBalance();
   
   // Initialize fast entry mode tracking
   eaInitializationTime = TimeCurrent();
   fastEntryModeActive = EnableFastEntryMode;
   fastEntryTradeTaken = false;
   
   Print("QualityGapPro EA initialized");
   if(EnableFastEntryMode)
   {
      Print("Fast Entry Mode ENABLED: Will attempt trade within first ", FastEntryWindowSeconds, " seconds");
   }
   
   EventSetTimer(60);  // Timer every 60 seconds
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   
   // Clean up visual markers (optional - comment out if you want markers to persist)
   // CleanupAllMarkers();
   
   Print("QualityGapPro EA deinitialized. Reason=", reason);
}

void OnTick()
{
   RefreshRates();
   
   // Update daily counters
   UpdateDailyCounters();
   
   // Manage existing trades
   ManageOpenTrades();
   
   // Risk management checks
   if(!RiskManagementWorkflow())
   {
      return;  // Stop trading if risk limits hit
   }
   
   // Pre-flight checks
   if(!PreFlightChecks(TradingSymbol))
   {
      return;
   }
   
   // Check if we can open new trade
   if(CountOpenTrades(MagicNumber) >= MaxConcurrentTrades)
   {
      return;
   }
   
   // === FAST ENTRY MODE: Check if we're in the first minute ===
   if(EnableFastEntryMode && !fastEntryTradeTaken)
   {
      int secondsSinceInit = (int)(TimeCurrent() - eaInitializationTime);
      
      if(secondsSinceInit <= FastEntryWindowSeconds)
      {
         // We're in fast entry window - use aggressive entry logic
         fastEntryModeActive = true;
         
         // Try fast entry validation (more aggressive, lower thresholds)
         EntryValidationData entryData = FastValidateEntry(TradingSymbol);
         
         if(entryData.valid)
         {
            // Calculate position size
            double lotSize = CalculatePositionSize(
               TradingSymbol,
               entryData.entry.entryPrice,
               entryData.entry.stopLoss,
               RiskPercentPerTrade
            );
            
            if(lotSize > 0)
            {
               // Place trade
               int ticket = PlaceTrade(
                  TradingSymbol,
                  entryData.direction,
                  lotSize,
                  entryData.entry.entryPrice,
                  entryData.entry.stopLoss,
                  entryData.entry.takeProfit,
                  entryData
               );
               
               if(ticket > 0)
               {
                  Print("FAST ENTRY MODE: Trade opened within ", secondsSinceInit, " seconds | Ticket: ", ticket, " | Quality Score: ", DoubleToString(entryData.qualityScore.total, 1));
                  fastEntryTradeTaken = true;
                  fastEntryModeActive = false;
                  UpdateDailyTradeCount();
               }
            }
         }
         
         // Update display and return (skip normal entry validation during fast mode)
         if(ShowDashboard)
         {
            UpdateDashboard();
         }
         return;
      }
      else
      {
         // Fast entry window expired
         fastEntryModeActive = false;
         if(!fastEntryTradeTaken)
         {
            Print("Fast Entry Mode expired (", secondsSinceInit, " seconds) - No trade taken. Switching to normal quality mode.");
         }
      }
   }
   
   // === NORMAL ENTRY MODE: Standard quality validation ===
   EntryValidationData entryData = ValidateEntry(TradingSymbol);
   
   if(entryData.valid)
   {
      // Calculate position size
      double lotSize = CalculatePositionSize(
         TradingSymbol,
         entryData.entry.entryPrice,
         entryData.entry.stopLoss,
         RiskPercentPerTrade
      );
      
      if(lotSize > 0)
      {
         // Place trade
         int ticket = PlaceTrade(
            TradingSymbol,
            entryData.direction,
            lotSize,
            entryData.entry.entryPrice,
            entryData.entry.stopLoss,
            entryData.entry.takeProfit,
            entryData
         );
         
         if(ticket > 0)
         {
            Print("Quality trade opened: ", ticket, " | Quality Score: ", DoubleToString(entryData.qualityScore.total, 1));
            UpdateDailyTradeCount();
         }
      }
   }
   
   // Update display
   if(ShowDashboard)
   {
      UpdateDashboard();
   }
}

void OnTimer()
{
   if(ShowDashboard)
   {
      UpdateDashboard();
   }
   CheckDailyReset();
}

// ============================================================================
// ==== Visual Markers (Chart Objects) =======================================
// ============================================================================

void DrawTradeMarkers(const int ticket, const string symbol, const int direction, const double entryPrice, const double stopLoss, const double takeProfit)
{
   if(!ShowVisualMarkers) return;
   
   string prefix = "QGapPro_" + IntegerToString(ticket) + "_";
   datetime entryTime = TimeCurrent();
   
   // Draw entry arrow
   string arrowName = prefix + "Entry";
   int arrowCode = (direction == TRADE_DIRECTION_BULLISH) ? 233 : 234; // Up arrow for buy, down arrow for sell
   color arrowColor = (direction == TRADE_DIRECTION_BULLISH) ? BuyEntryColor : SellEntryColor;
   
   if(ObjectFind(0, arrowName) < 0)
   {
      ObjectCreate(0, arrowName, OBJ_ARROW, 0, entryTime, entryPrice);
      ObjectSetInteger(0, arrowName, OBJPROP_ARROWCODE, arrowCode);
      ObjectSetInteger(0, arrowName, OBJPROP_COLOR, arrowColor);
      ObjectSetInteger(0, arrowName, OBJPROP_WIDTH, ArrowSize);
      ObjectSetInteger(0, arrowName, OBJPROP_BACK, false);
      ObjectSetInteger(0, arrowName, OBJPROP_SELECTABLE, false);
   }
   
   // Draw stop loss line
   if(stopLoss > 0)
   {
      string slLineName = prefix + "SL";
      if(ObjectFind(0, slLineName) < 0)
      {
         ObjectCreate(0, slLineName, OBJ_HLINE, 0, 0, stopLoss);
         ObjectSetInteger(0, slLineName, OBJPROP_COLOR, StopLossColor);
         ObjectSetInteger(0, slLineName, OBJPROP_STYLE, STYLE_DASH);
         ObjectSetInteger(0, slLineName, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, slLineName, OBJPROP_BACK, true);
         ObjectSetInteger(0, slLineName, OBJPROP_SELECTABLE, false);
      }
      
      // Stop loss label
      if(ShowSLLabel)
      {
         string slLabelName = prefix + "SL_Label";
         if(ObjectFind(0, slLabelName) < 0)
         {
            ObjectCreate(0, slLabelName, OBJ_TEXT, 0, entryTime, stopLoss);
            ObjectSetString(0, slLabelName, OBJPROP_TEXT, "SL: " + DoubleToString(stopLoss, (int)MarketInfo(symbol, MODE_DIGITS)));
            ObjectSetInteger(0, slLabelName, OBJPROP_COLOR, StopLossColor);
            ObjectSetInteger(0, slLabelName, OBJPROP_FONTSIZE, 8);
            ObjectSetString(0, slLabelName, OBJPROP_FONT, "Arial Bold");
            ObjectSetInteger(0, slLabelName, OBJPROP_SELECTABLE, false);
         }
      }
   }
   
   // Draw take profit line
   if(takeProfit > 0)
   {
      string tpLineName = prefix + "TP";
      if(ObjectFind(0, tpLineName) < 0)
      {
         ObjectCreate(0, tpLineName, OBJ_HLINE, 0, 0, takeProfit);
         ObjectSetInteger(0, tpLineName, OBJPROP_COLOR, TakeProfitColor);
         ObjectSetInteger(0, tpLineName, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(0, tpLineName, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, tpLineName, OBJPROP_BACK, true);
         ObjectSetInteger(0, tpLineName, OBJPROP_SELECTABLE, false);
      }
      
      // Take profit label
      if(ShowTPLabel)
      {
         string tpLabelName = prefix + "TP_Label";
         if(ObjectFind(0, tpLabelName) < 0)
         {
            ObjectCreate(0, tpLabelName, OBJ_TEXT, 0, entryTime, takeProfit);
            ObjectSetString(0, tpLabelName, OBJPROP_TEXT, "TP: " + DoubleToString(takeProfit, (int)MarketInfo(symbol, MODE_DIGITS)));
            ObjectSetInteger(0, tpLabelName, OBJPROP_COLOR, TakeProfitColor);
            ObjectSetInteger(0, tpLabelName, OBJPROP_FONTSIZE, 8);
            ObjectSetString(0, tpLabelName, OBJPROP_FONT, "Arial Bold");
            ObjectSetInteger(0, tpLabelName, OBJPROP_SELECTABLE, false);
         }
      }
   }
   
   // Entry price label
   if(ShowEntryLabel)
   {
      string entryLabelName = prefix + "Entry_Label";
      if(ObjectFind(0, entryLabelName) < 0)
      {
         color labelColor = (direction == TRADE_DIRECTION_BULLISH) ? BuyEntryColor : SellEntryColor;
         string labelText = (direction == TRADE_DIRECTION_BULLISH) ? "BUY" : "SELL";
         labelText += " #" + IntegerToString(ticket);
         labelText += " @ " + DoubleToString(entryPrice, (int)MarketInfo(symbol, MODE_DIGITS));
         
         ObjectCreate(0, entryLabelName, OBJ_TEXT, 0, entryTime, entryPrice);
         ObjectSetString(0, entryLabelName, OBJPROP_TEXT, labelText);
         ObjectSetInteger(0, entryLabelName, OBJPROP_COLOR, labelColor);
         ObjectSetInteger(0, entryLabelName, OBJPROP_FONTSIZE, 9);
         ObjectSetString(0, entryLabelName, OBJPROP_FONT, "Arial Bold");
         ObjectSetInteger(0, entryLabelName, OBJPROP_SELECTABLE, false);
      }
   }
   
   ChartRedraw();
}

void UpdateTradeMarkerColor(const int ticket, const color newColor)
{
   if(!ShowVisualMarkers) return;
   
   string prefix = "QGapPro_" + IntegerToString(ticket) + "_";
   string arrowName = prefix + "Entry";
   
   if(ObjectFind(0, arrowName) >= 0)
   {
      ObjectSetInteger(0, arrowName, OBJPROP_COLOR, newColor);
      ChartRedraw();
   }
}

void UpdateTradeMarkerByProfit(const int ticket)
{
   if(!ShowVisualMarkers) return;
   
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return;
   
   double profit = OrderProfit() + OrderSwap() + OrderCommission();
   color markerColor;
   
   if(profit > 0)
   {
      // Profitable trade - bright green
      markerColor = clrLimeGreen;
   }
   else if(profit < 0)
   {
      // Losing trade - red
      markerColor = clrRed;
   }
   else
   {
      // Break even - yellow
      markerColor = clrYellow;
   }
   
   UpdateTradeMarkerColor(ticket, markerColor);
}

void UpdateAllActiveTradeMarkers()
{
   if(!ShowVisualMarkers) return;
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == TradingSymbol)
         {
            UpdateTradeMarkerByProfit(OrderTicket());
         }
      }
   }
}

void RemoveTradeMarkers(const int ticket)
{
   string prefix = "QGapPro_" + IntegerToString(ticket) + "_";
   
   // Remove all objects with this prefix
   int total = ObjectsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      string objName = ObjectName(0, i);
      if(StringFind(objName, prefix) == 0)
      {
         ObjectDelete(0, objName);
      }
   }
   
   ChartRedraw();
}

void CleanupAllMarkers()
{
   // Remove all QualityGapPro markers
   int total = ObjectsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      string objName = ObjectName(0, i);
      if(StringFind(objName, "QGapPro_") == 0)
      {
         ObjectDelete(0, objName);
      }
   }
   
   ChartRedraw();
}

// ============================================================================
// ==== Trade Placement ======================================================
// ============================================================================

int PlaceTrade(const string symbol, const int direction, const double lots, const double entryPrice, const double stopLoss, const double takeProfit, const EntryValidationData &entryData)
{
   // TODO: Implement trade placement
   // After trade is placed successfully, call:
   // DrawTradeMarkers(ticket, symbol, direction, entryPrice, stopLoss, takeProfit);
   return -1;
}

// ============================================================================
// ==== Display ==============================================================
// ============================================================================

void UpdateDashboard()
{
   if(!ShowDashboard)
   {
      Comment("");
      return;
   }
   
   string dashboard = "";
   dashboard += "==== QualityGapPro EA ====\n";
   dashboard += "Symbol: " + TradingSymbol + "\n";
   dashboard += "Magic: " + IntegerToString(MagicNumber) + "\n";
   dashboard += "Daily Trades: " + IntegerToString(dailyTradeCount) + " / " + IntegerToString(MaxDailyTrades) + "\n";
   dashboard += "Active Trades: " + IntegerToString(CountOpenTrades(MagicNumber)) + " / " + IntegerToString(MaxConcurrentTrades) + "\n";
   
   // Fast Entry Mode Status
   if(EnableFastEntryMode)
   {
      if(fastEntryModeActive && !fastEntryTradeTaken)
      {
         int secondsRemaining = FastEntryWindowSeconds - (int)(TimeCurrent() - eaInitializationTime);
         if(secondsRemaining > 0)
         {
            dashboard += "FAST ENTRY MODE: " + IntegerToString(secondsRemaining) + "s remaining\n";
         }
      }
      else if(fastEntryTradeTaken)
      {
         dashboard += "FAST ENTRY: Trade taken ✓\n";
      }
      else
      {
         dashboard += "Fast Entry: Expired (Normal mode)\n";
      }
   }
   
   dashboard += "\n";
   dashboard += "Status: " + (TradeEnabled ? "ENABLED" : "DISABLED") + "\n";
   
   Comment(dashboard);
}

