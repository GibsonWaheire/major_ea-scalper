// NAS100HybridSniperFlipper - compacted
#property copyright "NAS100 Microsecond Scalper"
#property link      ""
#property version   "2.00"
#property strict
#property indicator_chart_window

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/AccountInfo.mqh>

//--- Input Parameters ---
input string   TradeSymbol          = "";            // Trading Symbol (empty = auto-detect NAS100)
input int      MagicNumber          = 20241201;      // Magic Number

//--- DYNAMIC LOT SIZING ---
input double   RiskPercentPerTrade  = 2.0;           // Risk % of equity per trade
input double   MinLotSize           = 0.1;           // Minimum lot size
input double   MaxLotSize           = 5.0;           // Maximum lot size
input double   FixedLotOverride     = 0.0;           // Override with fixed lot (0 = dynamic)

//--- DYNAMIC PROFIT TARGETS ---
input int      ATRPeriod            = 14;            // ATR period for dynamic targets
input double   ATRMinProfitMultiplier = 0.2;         // Min profit = ATR * 0.2 (~35-50 pts for NAS100)
input double   ATRMaxProfitMultiplier = 0.8;         // Max profit = ATR * 0.8 (~140+ pts for NAS100)
input int      SlippageBuffer       = 3;             // Buffer for slippage (points)

//--- TIME-BASED EXITS ---
input int      MaxPositionAgeSeconds = 120;          // Close position if older than this
input int      PartialCloseAtSeconds = 60;           // Close 50% at this time if still profitable
input int      FastExitAtSeconds    = 30;            // Close if 40+ points in this time
input int      FastExitMinProfit    = 40;            // Minimum profit for fast exit

//--- POSITION MANAGEMENT ---
input int      MaxConcurrentTrades  = 4;             // Maximum concurrent positions (pyramid strategy)
input bool     EnableSignalDecay    = true;          // Close on signal decay
input bool     EnableNotifications  = true;          // Enable Push Notifications
input bool     DisableTradingHours  = true;          // Disable trading hours restriction (trade 24/7)
//--- Legacy compatibility (kept for backward compatibility)
// legacy VirtualSLPoints and TPPoints removed (use ATR-based defaults)
//--- Tick/Microsecond scalper compatibility inputs
input bool     UseTickBasedEntry    = false;         // Use tick-based instant entry (DISABLED - Sniper mode)
input int      MaxSpreadPoints      = 300;           // Maximum spread to trade (points) - NAS100 compatible
input int      TickMovementThreshold = 1;            // Minimum tick movement to trigger (points) - AGGRESSIVE
input double   MinTickMovement       = 0.5;          // Minimum tick movement for signal (points) - AGGRESSIVE
input bool     ShowVisualIndicators = true;          // Show visual indicators on chart

//--- Global Variables ---
CTrade         trade;
CPositionInfo  position;
CAccountInfo   account;
string         detectedSymbol = "";  // Auto-detected NAS100 symbol

//+------------------------------------------------------------------+
//| Get trading symbol (auto-detected or from input)                |
//+------------------------------------------------------------------+
string GetTradeSymbol()
{
   if(StringLen(detectedSymbol) > 0)
      return detectedSymbol;
   if(StringLen(TradeSymbol) > 0)
      return TradeSymbol;
   return _Symbol;  // Fallback to chart symbol
}

// Tick-based scalping variables
double         lastBid = 0.0;
double         lastAsk = 0.0;
double         lastPrice = 0.0;
datetime       lastTickTime = 0;
int            tickDirection = 0;  // 1 = up, -1 = down, 0 = neutral
double         tickMovement = 0.0;
int            consecutiveTicks = 0;

// Indicator handles (only used when not in tick-based mode)
int            ema20Handle = INVALID_HANDLE;
int            ema50Handle = INVALID_HANDLE;
int            rsiHandle = INVALID_HANDLE;

// Time Management
datetime       startOfDayEquity = 0;
double         startOfDayBalance = 0.0;
datetime       lastDayReset = 0;
bool           tradingStoppedForDay = false;
bool           tradingStoppedForLoss = false;

// Sniper Setup Tracking
bool           sniperSetupActive = false;
int            sniperDirection = 0;  // 1 = BUY, -1 = SELL, 0 = none
double         sniperEntryPrice = 0.0;
datetime       sniperEntryTime = 0;
// recoveryEntryUsed removed - recovery entries disabled in redesign
double         sniperVirtualSL = 0.0;
double         sniperTargetProfit = 0.0;
double         sniperEntryEquity = 0.0;  // Equity at entry time for TP calculation

// Signal Decay Detection
int            lastConfirmedTrendDirection = 0;  // Last confirmed trend (for decay detection)
int            decayCheckCounter = 0;  // Counter for checking signal decay
int            decayCheckFrequency = 3;  // Check decay every 3 ticks

// Structure tracking for BOS and zones
double         lastM5High = 0.0;
double         lastM5Low = 0.0;
double         lastM5Close = 0.0;
datetime       lastM5BarTime = 0;

// Anti-Hedging & Direction Lock (Option B Enhancement)
int            lockedDirection = 0;  // 1 = BUY locked, -1 = SELL locked, 0 = no lock
datetime       directionLockTime = 0;  // Time when direction was locked
bool           hasPendingOppositeOrder = false;  // Track if pending opposite order exists
ulong          pendingOppositeTicket = 0;  // Store pending order ticket

// Pending Order Delay Management
datetime       lastOppositeCloseTime = 0;  // Track when opposite positions were closed
int            pendingOrderDelaySeconds = 3;  // Delay before placing pending order (1-5 seconds, default 3)
int            proposedPendingDirection = 0;  // Store direction for pending order after delay

// NAS100 Market Hours (US Stock Market: 9:30 AM - 5:00 PM EST = 14:30 - 21:00 UTC, or 15:30-22:00 UTC with DST)
bool           isWithinNAS100Hours = false;
datetime       lastHoursCheck = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // Auto-detect NAS100 symbol if not specified
   string symbolToUse = TradeSymbol;
   if(StringLen(symbolToUse) == 0)
   {
      // Try common NAS100 symbols
      string nas100Symbols[] = {"USTEC", "US100", "NAS100", "NAS100.cash", "US100.cash", "USTEC.cash"};
      for(int i = 0; i < ArraySize(nas100Symbols); i++)
      {
         if(SymbolSelect(nas100Symbols[i], true))
         {
            MqlTick testTick;
            if(SymbolInfoTick(nas100Symbols[i], testTick))
            {
               symbolToUse = nas100Symbols[i];
               detectedSymbol = nas100Symbols[i];
               Print("Auto-detected NAS100 symbol: ", symbolToUse);
               break;
            }
         }
      }
      
      if(StringLen(symbolToUse) == 0)
      {
         #property indicator_chart_window

         #include <Trade/Trade.mqh>

         // --- Small Account Sniper Flipper (Liquidity Sweep Trap) ---
         // Implements: 15m liquidity sweep detection, 1m trap confirmation (close back inside),
         // Fixed SL 150 points, Risk 10% equity per trade, Reward ratio 1:3, FOK filling, anti-hedge,
         // Max spread check.

         input string  TradeSymbol           = "";      // Trading Symbol (empty = use chart)
         input int     MagicNumber           = 20260130; // Magic Number

         // Risk sizing (required by user): 10% of equity per trade
         const double  RISK_RATIO            = 0.10;     // 10% equity risk per trade

         // Fixed SL (points) and reward
         const int     STOP_LOSS_POINTS      = 150;      // 150 points = 15 pips
         const int     REWARD_RATIO          = 3;        // 1:3 target

         // Sweep detection: break by 10 pips (1 pip = 10 points in this EA), so 10 pips = 100 points
         const int     SWEEP_BREAK_PIPS      = 10;
         const int     POINTS_PER_PIP        = 10;

         // Execution guardrails
         input double  MaxSpreadPoints       = 1.5;      // If spread (in points) > this, do not trade

         // Minimal lot (will be clamped to broker limits at runtime)
         input double  MinLotSize            = 0.01;

         // Globals
         CTrade        trade;
         string        g_symbol = "";
         datetime      lastM1BarTime = 0;

         //+------------------------------------------------------------------+
         //| Helpers                                                           |
         //+------------------------------------------------------------------+
         string GetSymbol()
         {
            if(StringLen(g_symbol) > 0) return g_symbol;
            if(StringLen(TradeSymbol) > 0) g_symbol = TradeSymbol;
            else g_symbol = _Symbol;
            return g_symbol;
         }

         // Return current spread in points
         double GetSpreadPoints(const string symbol)
         {
            double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
            double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
            double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
            if(point <= 0) point = _Point;
            double spreadPoints = (ask - bid) / point;
            return spreadPoints;
         }

         // Check anti-hedge: return true if opening 'direction' would create a hedge (opposite existing pos exists)
         bool HasOppositePosition(int direction, const string symbol)
         {
            for(int i = PositionsTotal() - 1; i >= 0; --i)
            {
               ulong ticket = PositionGetTicket(i);
               if(ticket == 0) continue;
               if(!PositionSelectByTicket(ticket)) continue;
               if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
               if(StringCompare(PositionGetString(POSITION_SYMBOL), symbol) != 0) continue;

               int ptype = (int)PositionGetInteger(POSITION_TYPE);
               if(direction == 1 && ptype == POSITION_TYPE_SELL) return true; // trying to BUY but SELL exists
               if(direction == -1 && ptype == POSITION_TYPE_BUY) return true; // trying to SELL but BUY exists
            }
            return false;
         }

         // Calculate volume (lots) based on fixed SL in points and 10% equity risk
         double CalculateLotByRisk(const string symbol)
         {
            double equity = AccountInfoDouble(ACCOUNT_EQUITY);
            double riskAmount = equity * RISK_RATIO; // e.g. $50 -> $5

            // Convert SL points to ticks for tick value calculation
            double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
            if(point <= 0) point = _Point;

            double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
            double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

            double loss_per_lot = 0.0;
            double sl_price_diff = STOP_LOSS_POINTS * point; // price difference

            if(tick_size > 0 && tick_value > 0)
            {
               double ticks = sl_price_diff / tick_size;
               loss_per_lot = ticks * tick_value; // monetary loss per 1 lot for SL
            }
            else
            {
               // Fallback approximation: use point * contract size estimate
               double contract = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
               if(contract <= 0) contract = 1.0;
               loss_per_lot = sl_price_diff * contract; // rough fallback
            }

            if(loss_per_lot <= 0)
            {
               Print("[CalcLot] Cannot compute loss per lot reliably, defaulting to min lot");
               return MathMax(MinLotSize, SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN));
            }

            double rawLots = riskAmount / loss_per_lot;

            // Normalize to broker step and clamp to allowed range
            double volStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
            double volMin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
            double volMax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
            if(volStep <= 0) volStep = 0.01;
            if(volMin <= 0) volMin = MinLotSize;
            if(volMax <= 0) volMax = volMin * 100;

            double digits = (double)SymbolInfoInteger(symbol, SYMBOL_VOLUME_DIGITS);
            double lots = MathFloor(rawLots / volStep) * volStep;
            if(lots < volMin) lots = volMin;
            if(lots > volMax) lots = volMax;
            // Round to allowed digits
            double pow10 = MathPow(10.0, digits);
            lots = MathFloor(lots * pow10 + 0.5) / pow10;

            return lots;
         }

         // Place market order with SL and TP (FOK enforced in OnInit via trade.SetTypeFilling)
         bool PlaceMarketOrder(int direction, double lots, const string symbol)
         {
            double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
            double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
            double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
            if(point <= 0) point = _Point;

            double slPrice = 0.0, tpPrice = 0.0;
            bool result = false;

            if(direction == 1) // BUY
            {
               double openPrice = ask;
               slPrice = openPrice - STOP_LOSS_POINTS * point;
               tpPrice = openPrice + STOP_LOSS_POINTS * point * REWARD_RATIO;
               result = trade.Buy(lots, symbol, 0, slPrice, tpPrice, "LS_BUY");
            }
            else if(direction == -1) // SELL
            {
               double openPrice = bid;
               slPrice = openPrice + STOP_LOSS_POINTS * point;
               tpPrice = openPrice - STOP_LOSS_POINTS * point * REWARD_RATIO;
               result = trade.Sell(lots, symbol, 0, slPrice, tpPrice, "LS_SELL");
            }

            if(result)
            {
               PrintFormat("[Trade] %s executed: lots=%.2f SL=%.1f TP=%.1f", (direction==1?"BUY":"SELL"), lots, slPrice, tpPrice);
               return true;
            }
            else
            {
               PrintFormat("[Trade] %s FAILED. Error=%d", (direction==1?"BUY":"SELL"), GetLastError());
               return false;
            }
         }

         //+------------------------------------------------------------------+
         //| Main tick - detect new 1m bar and evaluate liquidity-sweep trap   |
         //+------------------------------------------------------------------+
         void OnTick()
         {
            string symbol = GetSymbol();

            // Ensure market data
            if(!SymbolInfoTick(symbol, NULL)) return;

            datetime m1Time = (datetime)iTime(symbol, PERIOD_M1, 0);
            if(m1Time == 0) return;

            // When a new 1m bar appears, evaluate the previous (closed) 1m candle for trap
            if(m1Time != lastM1BarTime)
            {
               lastM1BarTime = m1Time;

               // Closed 1m candle is index 1
               double cHigh = iHigh(symbol, PERIOD_M1, 1);
               double cLow  = iLow(symbol, PERIOD_M1, 1);
               double cClose = iClose(symbol, PERIOD_M1, 1);

               // Previous 15m candle range (index 1)
               double prev15High = iHigh(symbol, PERIOD_M15, 1);
               double prev15Low  = iLow(symbol, PERIOD_M15, 1);

               if(prev15High == 0 || prev15Low == 0) return;

               double breakPoints = SWEEP_BREAK_PIPS * POINTS_PER_PIP; // e.g., 10 pips -> 100 points
               double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
               if(point <= 0) point = _Point;

               double thresholdPriceHigh = prev15High + breakPoints * point;
               double thresholdPriceLow  = prev15Low  - breakPoints * point;

               int detectedDirection = 0; // -1 = sell (sweep up then close inside), 1 = buy (sweep down then close inside)

               // Detect sweep above prev15High then close back inside => SELL trap
               if(cHigh >= thresholdPriceHigh && cClose < prev15High && cClose > prev15Low)
               {
                  detectedDirection = -1;
                  Print("[Sweep] Detected sweep-above then close-inside (SELL trap)");
               }

               // Detect sweep below prev15Low then close back inside => BUY trap
               if(detectedDirection == 0 && cLow <= thresholdPriceLow && cClose > prev15Low && cClose < prev15High)
               {
                  detectedDirection = 1;
                  Print("[Sweep] Detected sweep-below then close-inside (BUY trap)");
               }

               if(detectedDirection != 0)
               {
                  // Guard: spread
                  double spreadPts = GetSpreadPoints(symbol);
                  if(spreadPts > MaxSpreadPoints)
                  {
                     PrintFormat("[Guard] Spread too high (%.2f pts) > %.2f, skipping trade", spreadPts, MaxSpreadPoints);
                     return;
                  }

                  // Anti-hedge: do not open BUY if SELL exists and vice versa
                  if(HasOppositePosition(detectedDirection, symbol))
                  {
                     Print("[AntiHedge] Opposite position exists, blocking trade to avoid hedging");
                     return;
                  }

                  // Calculate lot based on 10% equity risk
                  double lots = CalculateLotByRisk(symbol);

                  // Place market order
                  PlaceMarketOrder(detectedDirection, lots, symbol);
               }
            }
         }

         //+------------------------------------------------------------------+
         //| Deinit                                                            |
         //+------------------------------------------------------------------+
         void OnDeinit(const int reason)
         {
            // intentionally minimal: no indicators to release
            Print("[Deinit] Small Account Sniper deinitialized. Reason=", reason);
         }

   Print("Current Server Time: ", dt.hour, ":", dt.min, " UTC");
   Print("Current Kenya Time: ", kenyaHour, ":", dt.min, " (UTC+3)");
   Print("Within Trading Hours: ", IsWithinTradingHours());
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Clean up chart objects
   CleanupChartObjects();
   
   // Release indicator handles
   if(ema20Handle != INVALID_HANDLE) IndicatorRelease(ema20Handle);
   if(ema50Handle != INVALID_HANDLE) IndicatorRelease(ema50Handle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   
   Print("EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Calculate Dynamic Lot Size Based on Risk Management              |
//+------------------------------------------------------------------+
double CalculateDynamicLotSize(double stopLossPoints)
{
   // If fixed lot override is set, use it
   if(FixedLotOverride > 0)
      return FixedLotOverride;
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (RiskPercentPerTrade / 100.0);
   
   // Get point value for lot calculation
   double pointValue = SymbolInfoDouble(GetTradeSymbol(), SYMBOL_POINT);
   double tickSize = SymbolInfoDouble(GetTradeSymbol(), SYMBOL_TRADE_TICK_SIZE);
   
   // Calculate lot size: Lots = Risk Amount / (SL Points * Point Value * 10000)
   // For NAS100: 1 lot = 100 units, so multiply by point value
   double lotSize = 0.0;
   if(stopLossPoints > 0)
   {
      lotSize = riskAmount / (stopLossPoints * pointValue * 10000);
   }
   
   // Apply limits
   if(lotSize < MinLotSize)
      lotSize = MinLotSize;
   if(lotSize > MaxLotSize)
      lotSize = MaxLotSize;
   
   // Round to broker's lot step (usually 0.01)
   double lotStep = SymbolInfoDouble(GetTradeSymbol(), SYMBOL_VOLUME_STEP);
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Calculate Dynamic Profit Target Based on ATR                    |
//+------------------------------------------------------------------+
int GetDynamicProfitTarget()
{
   string symbol = GetTradeSymbol();
   double atrValue = iATR(symbol, PERIOD_M5, ATRPeriod);
   
   if(atrValue <= 0)
      return 50;  // Fallback to minimum
   
   // Calculate min and max profit targets
   int minProfit = (int)(atrValue * ATRMinProfitMultiplier);
   int maxProfit = (int)(atrValue * ATRMaxProfitMultiplier);
   
   // Add slippage buffer
   minProfit += SlippageBuffer;
   
   return minProfit;  // Return min for aggressive take-profit
}

//+------------------------------------------------------------------+
//| Calculate Dynamic Profit Target (Max) Based on ATR              |
//+------------------------------------------------------------------+
int GetMaxDynamicProfitTarget()
{
   string symbol = GetTradeSymbol();
   double atrValue = iATR(symbol, PERIOD_M5, ATRPeriod);
   
   if(atrValue <= 0)
      return 150;  // Fallback to reasonable max
   
   int maxProfit = (int)(atrValue * ATRMaxProfitMultiplier);
   return maxProfit;
}

//+------------------------------------------------------------------+
//| Get default stop-loss (points) based on ATR                      |
//+------------------------------------------------------------------+
int GetDefaultStopLossPoints()
{
   string symbol = GetTradeSymbol();
   int period = ATRPeriod;
   int handle = iATR(symbol, PERIOD_M5, period);
   if(handle == INVALID_HANDLE)
      return 300; // conservative fallback

   double buf[];
   if(CopyBuffer(handle, 0, 0, 1, buf) <= 0)
   {
      IndicatorRelease(handle);
      return 300;
   }

   double atrValue = buf[0];
   IndicatorRelease(handle);

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0) point = Point;

   // Use ATR * max multiplier as baseline stop-loss in points, with a conservative floor
   int points = (int)MathMax(atrValue * ATRMaxProfitMultiplier / point, 150.0);
   return points;
}

//+------------------------------------------------------------------+
//| Check Time-Based Exit                                            |
//+------------------------------------------------------------------+
bool CheckTimeBasedExit()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i))
         continue;
      if(position.Magic() != MagicNumber || position.Symbol() != GetTradeSymbol())
         continue;
      
      datetime openTime = position.Time();
      int ageSeconds = (int)(TimeCurrent() - openTime);
      double profit = position.Profit();
      
      // Close if max age exceeded regardless of profit
      if(ageSeconds > MaxPositionAgeSeconds)
      {
         ClosePosition(position.Ticket());
         return true;
      }
      
      // Close 50% at partial time if profitable
      if(ageSeconds > PartialCloseAtSeconds && profit > 0)
      {
         double halfVolume = position.Volume() / 2;
         if(halfVolume > 0.01)  // Only if can split meaningfully
         {
            trade.PositionClosePartial(position.Ticket(), halfVolume);
            return true;
         }
      }
      
      // Fast exit: close if 40+ points in first 30 seconds
      if(ageSeconds < FastExitAtSeconds && profit >= FastExitMinProfit * SymbolInfoDouble(GetTradeSymbol(), SYMBOL_POINT) * 100)
      {
         ClosePosition(position.Ticket());
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Expert tick function - Simplified Priority Logic                 |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check daily reset
   CheckDailyReset();
   
   // PRIORITY 1: Check if trading is stopped
   if(tradingStoppedForDay || tradingStoppedForLoss)
   {
      if(IsEndOfSession())
      {
         CloseAllPositions();
      }
      return;
   }
   
   // PRIORITY 2: Check trading time window
   if(!DisableTradingHours && !IsNAS100MarketHours())
   {
      if(IsEndOfSession())
      {
         CloseAllPositions();
         CleanupPendingOrders();
         ResetDirectionLock();
         tradingStoppedForDay = true;
      }
      return;
   }
   
   // PRIORITY 3: Check daily protection limits
   if(CheckDailyLossProtection() || CheckDailyProfitCap())
   {
      CloseAllPositions();
      tradingStoppedForDay = true;
      return;
   }
   
   // PRIORITY 4: Close positions at PROFIT (fast exit)
   if(CheckAndCloseOnProfit())
   {
      if(GetActivePositionCount() == 0)
      {
         sniperSetupActive = false;
         sniperDirection = 0;
         ResetDirectionLock();
      }
      return;
   }
   
   // PRIORITY 5: Check time-based exits (close at max age or partial)
   if(CheckTimeBasedExit())
   {
      if(GetActivePositionCount() == 0)
      {
         sniperSetupActive = false;
         sniperDirection = 0;
         ResetDirectionLock();
      }
      return;
   }
   
   // PRIORITY 6: Check virtual stop loss
   if(CheckVirtualStopLoss())
   {
      return;
   }
   
   // PRIORITY 7: Check signal decay (early exit on reversal)
   if(EnableSignalDecay && IsSignalDecaying())
   {
      CloseAllPositions();
      sniperSetupActive = false;
      // recoveryEntryUsed removed
      sniperDirection = 0;
      ResetDirectionLock();
      return;
   }
   
   // PRIORITY 8: Process new entries if below concurrent limit
   if(GetActivePositionCount() < MaxConcurrentTrades)
   {
      if(!sniperSetupActive)
      {
         LookForSniperEntry();
      }
   }
}

//+------------------------------------------------------------------+
//| Update structure tracking for BOS detection                     |
//+------------------------------------------------------------------+
void UpdateStructureTracking()
{
   datetime currentBarTime = iTime(TradeSymbol, PERIOD_M5, 0);
   
   if(currentBarTime != lastM5BarTime)
   {
      lastM5BarTime = currentBarTime;
      lastM5High = iHigh(TradeSymbol, PERIOD_M5, 0);
      lastM5Low = iLow(TradeSymbol, PERIOD_M5, 0);
      lastM5Close = iClose(TradeSymbol, PERIOD_M5, 0);
   }
}

//+------------------------------------------------------------------+
//| Check if within trading hours (15:30 - 18:00 Kenya Time)        |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
   // Get broker server time (typically UTC)
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   
   // Convert to Kenya Time (UTC+3)
   int kenyaHour = dt.hour + 3;
   if(kenyaHour >= 24) kenyaHour -= 24;
   
   int totalMinutes = kenyaHour * 60 + dt.min;
   
   int startMinutes = 15 * 60 + 30;  // 15:30
   int endMinutes = 18 * 60;         // 18:00
   
   bool withinHours = (totalMinutes >= startMinutes && totalMinutes < endMinutes);
   
   // Debug logging
   static datetime lastLogTime = 0;
   if(TimeCurrent() - lastLogTime > 300) // Log every 5 minutes
   {
      Print("Time Check - Server Hour: ", dt.hour, ":", dt.min, " | Kenya Hour: ", kenyaHour, ":", dt.min, " | Within Hours: ", withinHours);
      lastLogTime = TimeCurrent();
   }
   
   return withinHours;
}

//+------------------------------------------------------------------+
//| Check if end of session (18:00 Kenya Time)                      |
//+------------------------------------------------------------------+
bool IsEndOfSession()
{
   // Get broker server time (typically UTC)
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   
   // Convert to Kenya Time (UTC+3)
   int kenyaHour = dt.hour + 3;
   if(kenyaHour >= 24) kenyaHour -= 24;
   
   int totalMinutes = kenyaHour * 60 + dt.min;
   
   return (totalMinutes >= 18 * 60);
}

//+------------------------------------------------------------------+
//| Check if within NAS100 market hours (US Stock Market)           |
//| 9:30 AM - 5:00 PM EST = 14:30 - 21:00 UTC (winter)              |
//| 9:30 AM - 5:00 PM EDT = 13:30 - 20:00 UTC (summer)              |
//| Uses 15:30-22:00 UTC for safety margin (covers both)            |
//+------------------------------------------------------------------+
bool IsNAS100MarketHours()
{
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   
   // Skip weekends
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;  // Sunday=0, Saturday=6
   
   int utcHour = dt.hour;
   int utcMinutes = utcHour * 60 + dt.min;
   
   int startMinutes = 15 * 60 + 30;  // 15:30 UTC (safe margin for 9:30 AM EST)
   int endMinutes = 22 * 60;         // 22:00 UTC (safe margin for 5:00 PM EDT)
   
   bool withinHours = (utcMinutes >= startMinutes && utcMinutes < endMinutes);
   
   static datetime lastLogTime = 0;
   if(TimeCurrent() - lastLogTime > 600) // Log every 10 minutes
   {
      Print("NAS100 Hours Check - UTC Hour: ", utcHour, ":", dt.min, " | Day: ", dt.day_of_week, 
            " | Within Hours: ", withinHours, " | Status: ", (dt.day_of_week == 0 || dt.day_of_week == 6 ? "WEEKEND" : "WEEKDAY"));
      lastLogTime = TimeCurrent();
   }
   
   return withinHours;
}

//+------------------------------------------------------------------+
//| Check if adding a trade would create hedge (opposite positions) |
//+------------------------------------------------------------------+
bool IsHedgingPosition(int proposedDirection)
{
   // Count existing positions by direction
   int buyCount = 0;
   int sellCount = 0;
   string symbol = GetTradeSymbol();
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i)) continue;
      if(position.Magic() != MagicNumber) continue;
      if(position.Symbol() != symbol) continue;
      
      if(position.PositionType() == POSITION_TYPE_BUY)
         buyCount++;
      else if(position.PositionType() == POSITION_TYPE_SELL)
         sellCount++;
   }
   
   // Check if proposed trade would create hedge
   if(proposedDirection == 1 && sellCount > 0) return true;   // BUY proposed but SELL exists
   if(proposedDirection == -1 && buyCount > 0) return true;   // SELL proposed but BUY exists
   
   return false;
}

//+------------------------------------------------------------------+
//| Close all positions in opposite direction (PROFIT ONLY)          |
//+------------------------------------------------------------------+
bool CloseOppositePositions(int proposedDirection)
{
   string symbol = GetTradeSymbol();
   bool allClosed = true;
   int closedCount = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i)) continue;
      if(position.Magic() != MagicNumber) continue;
      if(position.Symbol() != symbol) continue;
      
      // Close opposite direction positions
      bool isOpposite = false;
      if(proposedDirection == 1 && position.PositionType() == POSITION_TYPE_SELL)
         isOpposite = true;
      else if(proposedDirection == -1 && position.PositionType() == POSITION_TYPE_BUY)
         isOpposite = true;
      
      if(isOpposite)
      {
         // CRITICAL: Only close if position is in PROFIT
         double profit = position.Profit() + position.Swap() + position.Commission();
         
         if(profit > 0)  // Position is profitable
         {
            ulong ticket = position.Ticket();
            if(trade.PositionClose(ticket))
            {
               closedCount++;
               Print("ANTI-HEDGE: Closed PROFITABLE ", (proposedDirection == 1 ? "SELL" : "BUY"), 
                     " position #", ticket, " (Profit: ", DoubleToString(profit, 2), ") to allow new ", 
                     (proposedDirection == 1 ? "BUY" : "SELL"), " trade");
            }
            else
            {
               Print("ANTI-HEDGE: Failed to close position #", ticket, ". Error: ", GetLastError());
               allClosed = false;
            }
         }
         else
         {
            Print("ANTI-HEDGE: Position #", position.Ticket(), " in LOSS (", DoubleToString(profit, 2), 
                  ") - NOT CLOSED. Waiting for profit...");
            allClosed = false;  // At least one position couldn't be closed (in loss)
         }
      }
   }
   
   if(closedCount > 0)
   {
      Print("ANTI-HEDGE: Closed ", closedCount, " PROFITABLE opposite position(s) before new trade");
      lastOppositeCloseTime = TimeCurrent();  // Record close time for pending order delay
      if(EnableNotifications)
      {
         SendEANotification("Anti-hedge: Closed " + string(closedCount) + " profitable opposite position(s). Proceeding with " + 
                           (proposedDirection == 1 ? "BUY" : "SELL") + " trade.");
      }
   }
   
   return allClosed;
}

//+------------------------------------------------------------------+
//| Lock direction for current trading session                       |
//+------------------------------------------------------------------+
void LockDirection(int direction)
{
   if(direction != 0 && direction != 1 && direction != -1) return;
   
   lockedDirection = direction;
   directionLockTime = TimeCurrent();
   
   if(direction != 0)
   {
      Print("DIRECTION LOCKED: ", (direction == 1 ? "BUY" : "SELL"), " mode active");
      if(EnableNotifications)
         SendEANotification("Direction locked: " + string(direction == 1 ? "BUY ONLY" : "SELL ONLY"));
   }
}

//+------------------------------------------------------------------+
//| Reset direction lock (when all positions close)                 |
//+------------------------------------------------------------------+
void ResetDirectionLock()
{
   if(lockedDirection != 0)
   {
      Print("DIRECTION LOCK RELEASED - Ready for new direction on next signal");
   }
   
   lockedDirection = 0;
   directionLockTime = 0;
   CleanupPendingOrders();
}

//+------------------------------------------------------------------+
//| Check if pending order in opposite direction already exists     |
//+------------------------------------------------------------------+
bool HasPendingOppositeOrder(int direction)
{
   string symbol = GetTradeSymbol();
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket == 0) continue;
      
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      
      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      
      // Check for opposite direction pending orders
      if(direction == 1 && orderType == ORDER_TYPE_BUY_LIMIT) return true;   // BUY pending already exists
      if(direction == -1 && orderType == ORDER_TYPE_SELL_LIMIT) return true; // SELL pending already exists
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check if pending order delay has elapsed                         |
//+------------------------------------------------------------------+
bool IsPendingOrderDelayElapsed()
{
   if(lastOppositeCloseTime == 0) return false;  // No close recorded yet
   
   datetime currentTime = TimeCurrent();
   int secondsElapsed = (int)(currentTime - lastOppositeCloseTime);
   
   if(secondsElapsed >= pendingOrderDelaySeconds)
   {
      Print("PENDING ORDER DELAY: ", secondsElapsed, " seconds elapsed (threshold: ", 
            pendingOrderDelaySeconds, " seconds). Ready to place pending order.");
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Process delayed pending order placement                          |
//+------------------------------------------------------------------+
void ProcessDelayedPendingOrder()
{
   // Check if we have a pending direction and delay has elapsed
   if(proposedPendingDirection != 0 && IsPendingOrderDelayElapsed())
   {
      Print("PENDING ORDER: Placing queued ", (proposedPendingDirection == 1 ? "BUY" : "SELL"), 
         " order after ", pendingOrderDelaySeconds, " second delay...");
      double pendingLots = CalculateDynamicLotSize(GetDefaultStopLossPoints());
      PlacePendingOppositeOrder(proposedPendingDirection, pendingLots);
      
      // Reset pending direction and close time
      proposedPendingDirection = 0;
      lastOppositeCloseTime = 0;
   }
}

//+------------------------------------------------------------------+
//| Place pending limit order for opposite direction                |
//+------------------------------------------------------------------+
void PlacePendingOppositeOrder(int direction, double lots)
{
   string symbol = GetTradeSymbol();
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   
   // Check if pending order in same direction already exists to prevent duplicates
   if(HasPendingOppositeOrder(direction))
   {
      Print("PENDING ORDER ALREADY EXISTS: Skipping duplicate pending ", 
            (direction == 1 ? "BUY" : "SELL"), " order");
      return;
   }
   
   // Clean up existing pending order first
   CleanupPendingOrders();
   
   bool result = false;
   double limitPrice = 0.0;
   
   if(direction == 1)  // Place BUY LIMIT (below current ask)
   {
      limitPrice = ask - (50 * point);  // 50 points below current ask
      result = trade.BuyLimit(lots, limitPrice, symbol, 0, 0, ORDER_TIME_DAY, 0, "Pending BUY (Queued)");
   }
   else if(direction == -1)  // Place SELL LIMIT (above current bid)
   {
      limitPrice = bid + (50 * point);  // 50 points above current bid
      result = trade.SellLimit(lots, limitPrice, symbol, 0, 0, ORDER_TIME_DAY, 0, "Pending SELL (Queued)");
   }
   
   if(result)
   {
      pendingOppositeTicket = trade.ResultOrder();
      hasPendingOppositeOrder = true;
      
      Print("PENDING ORDER PLACED: ", (direction == 1 ? "BUY LIMIT" : "SELL LIMIT"), 
            " at ", limitPrice, " (Queued due to opposite direction lock)");
      if(EnableNotifications)
         SendEANotification("Opposite signal queued as pending limit order (Direction locked)");
   }
   else
   {
      Print("Failed to place pending order. Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Clean up any pending orders                                     |
//+------------------------------------------------------------------+
void CleanupPendingOrders()
{
   string symbol = GetTradeSymbol();
   
   // Iterate through all orders and delete pending orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   //| Close a position by ticket (wrapper)                            |
   //+------------------------------------------------------------------+
   bool ClosePosition(ulong ticket)
   {
      if(ticket == 0) return false;
      // Use CTrade wrapper to close by ticket
      if(trade.PositionClose(ticket))
      {
         Print("Position closed: #", ticket);
         return true;
      }
      else
      {
         Print("Failed to close position #", ticket, ". Error: ", GetLastError());
         return false;
      }
   }

   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket == 0) continue;
      
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      
      // Delete pending orders (BUY LIMIT or SELL LIMIT)
      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT)
      {
         if(trade.OrderDelete(orderTicket))
         {
            Print("Pending order #", orderTicket, " deleted");
         }
      }
   }
   
   hasPendingOppositeOrder = false;
   pendingOppositeTicket = 0;
}

//+------------------------------------------------------------------+
//| Reset daily tracking variables                                   |
//+------------------------------------------------------------------+
void ResetDailyTracking()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   // Check if new day
   MqlDateTime lastDt;
   TimeToStruct(lastDayReset, lastDt);
   if(lastDayReset == 0 || dt.day != lastDt.day)
   {
      startOfDayBalance = account.Equity();
      startOfDayEquity = currentTime;
      lastDayReset = currentTime;
      tradingStoppedForDay = false;
      tradingStoppedForLoss = false;
      sniperSetupActive = false;
      // recoveryEntryUsed removed
      sniperDirection = 0;
      
      Print("Daily reset: Start of day equity = ", startOfDayBalance);
   }
}

//+------------------------------------------------------------------+
//| Check and perform daily reset if needed                         |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   MqlDateTime lastDt;
   TimeToStruct(lastDayReset, lastDt);
   if(lastDayReset == 0 || dt.day != lastDt.day)
   {
      ResetDailyTracking();
   }
}

//+------------------------------------------------------------------+
//| Check daily loss protection (-15%)                              |
//+------------------------------------------------------------------+
bool CheckDailyLossProtection()
{
   double currentEquity = account.Equity();
   double lossThreshold = startOfDayBalance * 0.85;  // -15%
   
   return (currentEquity < lossThreshold);
}

//+------------------------------------------------------------------+
//| Check daily profit cap (30-50%)                                 |
//+------------------------------------------------------------------+
bool CheckDailyProfitCap()
{
   double currentEquity = account.Equity();
   double profitTarget = startOfDayBalance * (1.0 + DailyProfitPercent);
   
   return (currentEquity >= profitTarget);
}

//+------------------------------------------------------------------+
//| Check virtual stop loss                                         |
//+------------------------------------------------------------------+
bool CheckVirtualStopLoss()
{
   if(sniperVirtualSL == 0.0) return false;
   
   double currentPrice = (sniperDirection == 1) ? SymbolInfoDouble(TradeSymbol, SYMBOL_BID) : SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   
   if(sniperDirection == 1)  // BUY
   {
      return (currentPrice <= sniperVirtualSL);
   }
   else if(sniperDirection == -1)  // SELL
   {
      return (currentPrice >= sniperVirtualSL);
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check and close positions reaching profit threshold (FAST EXIT)  |
//+------------------------------------------------------------------+
bool CheckAndCloseOnProfit()
{
   string symbol = GetTradeSymbol();
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int minProfitTarget = GetDynamicProfitTarget();  // Dynamic ATR-based target
   bool anyClosedOnProfit = false;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i)) continue;
      if(position.Magic() != MagicNumber) continue;
      if(position.Symbol() != symbol) continue;
      
      double positionProfit = position.Profit() + position.Swap() + position.Commission();
      double profitInPoints = 0.0;
      
      if(position.PositionType() == POSITION_TYPE_BUY)
      {
         profitInPoints = (SymbolInfoDouble(symbol, SYMBOL_BID) - position.PriceOpen()) / point;
      }
      else if(position.PositionType() == POSITION_TYPE_SELL)
      {
         profitInPoints = (position.PriceOpen() - SymbolInfoDouble(symbol, SYMBOL_ASK)) / point;
      }
      
      // DYNAMIC PROFIT EXIT: Close when dynamic ATR-based target is reached
      if(profitInPoints >= minProfitTarget)
      {
         ulong ticket = position.Ticket();
         double closePrice = (position.PositionType() == POSITION_TYPE_BUY) ? 
                            SymbolInfoDouble(symbol, SYMBOL_BID) : 
                            SymbolInfoDouble(symbol, SYMBOL_ASK);
         
         if(trade.PositionClose(ticket))
         {
            Print("DYNAMIC PROFIT EXIT: Closed ", (position.PositionType() == POSITION_TYPE_BUY ? "BUY" : "SELL"), 
                  " position #", ticket, " at ", profitInPoints, " points profit (ATR target: ", minProfitTarget, 
                  ", P&L: ", DoubleToString(positionProfit, 2), ")");
            
            anyClosedOnProfit = true;
            
            if(EnableNotifications)
            {
               SendEANotification("PROFIT EXIT: Closed at " + DoubleToString(profitInPoints, 1) + 
                                 " points profit (ATR target: " + IntegerToString(minProfitTarget) + 
                                 "). P&L: " + DoubleToString(positionProfit, 2));
            }
         }
         else
         {
            Print("DYNAMIC PROFIT EXIT FAILED: Could not close position #", ticket, 
                  " at ", profitInPoints, " points. Error: ", GetLastError());
         }
      }
   }
   
   return anyClosedOnProfit;
}

//+------------------------------------------------------------------+
//| Get total floating profit from all positions                    |
//+------------------------------------------------------------------+
double GetTotalFloatingProfit()
{
   double totalProfit = 0.0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i)) continue;
      if(position.Magic() != MagicNumber) continue;
      if(position.Symbol() != GetTradeSymbol()) continue;
      
      totalProfit += position.Profit() + position.Swap() + position.Commission();
   }
   
   return totalProfit;
}

//+------------------------------------------------------------------+
//| Close all positions                                             |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i)) continue;
      if(position.Magic() != MagicNumber) continue;
      if(position.Symbol() != GetTradeSymbol()) continue;
      
      ulong ticket = position.Ticket();
      trade.PositionClose(ticket);
   }
   
   // After closing all positions, reset direction lock to allow new direction
   if(PositionsTotal() == 0)
   {
      ResetDirectionLock();
   }
}

//+------------------------------------------------------------------+
//| Look for sniper entry opportunity                               |
//+------------------------------------------------------------------+
void LookForSniperEntry()
{
   // Check if within NAS100 market hours - critical for sniper mode
   if(!isWithinNAS100Hours)
   {
      return;  // Skip if outside market hours
   }
   
   // Check trend filter
   int trendDirection = GetTrendDirection();
   if(trendDirection == 0)
   {
      static datetime lastLogTime = 0;
      if(TimeCurrent() - lastLogTime > 60) // Log every minute
      {
         Print("Entry Check: Trend filter returned 0 (no clear trend or filters disagree)");
         lastLogTime = TimeCurrent();
      }
      return;  // No clear trend or filters disagree
   }
   
   // Check for pullback into institutional zone
   bool inZone = CheckInstitutionalZone(trendDirection);
   if(!inZone)
   {
      static datetime lastLogTime = 0;
      if(TimeCurrent() - lastLogTime > 60)
      {
         Print("Entry Check: Price not in institutional zone. Trend: ", (trendDirection == 1 ? "BUY" : "SELL"));
         lastLogTime = TimeCurrent();
      }
      return;
   }
   
   // Check momentum confirmation
   bool momentumConfirmed = CheckMomentumConfirmation(trendDirection);
   if(!momentumConfirmed)
   {
      static datetime lastLogTime = 0;
      if(TimeCurrent() - lastLogTime > 60)
      {
         Print("Entry Check: Momentum not confirmed. Trend: ", (trendDirection == 1 ? "BUY" : "SELL"));
         lastLogTime = TimeCurrent();
      }
      return;
   }
   
   // ===== ANTI-HEDGING LOGIC (Option B Enhancement) =====
   
   // Check if this would create a hedging position
   if(IsHedgingPosition(trendDirection))
   {
      Print("ANTI-HEDGE: Signal received for ", (trendDirection == 1 ? "BUY" : "SELL"), 
            " but opposite positions exist. Queuing as pending order.");
      
      // Place pending limit order for opposite direction (use dynamic lot sizing)
      double queuedLots = CalculateDynamicLotSize(GetDefaultStopLossPoints());
      PlacePendingOppositeOrder(trendDirection, queuedLots);
      return;
   }
   
   // Check if direction already locked - allow multiple entries in same direction
   if(lockedDirection != 0 && lockedDirection != trendDirection)
   {
      Print("DIRECTION LOCKED: Current lock is ", (lockedDirection == 1 ? "BUY" : "SELL"), 
            " but signal is ", (trendDirection == 1 ? "BUY" : "SELL"), ". Queuing as pending order.");
      
      // Place pending limit order for opposite direction (use dynamic lot sizing)
      double dynamicLots = CalculateDynamicLotSize(GetDefaultStopLossPoints());
      PlacePendingOppositeOrder(trendDirection, dynamicLots);
      return;
   }
   
   // All conditions met - open sniper entry with dynamic lot sizing
   Print("=== ALL CONDITIONS MET - Opening Sniper Entry ===");
   Print("Trend Direction: ", (trendDirection == 1 ? "BUY" : "SELL"));
   double dynamicLots = CalculateDynamicLotSize(GetDefaultStopLossPoints());
   OpenSniperEntry(trendDirection, dynamicLots);
}

//+------------------------------------------------------------------+
//| Get trend direction based on EMA, BOS, and momentum             |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
   // If in tick-based mode or handles are invalid, return neutral
   if(UseTickBasedEntry || ema20Handle == INVALID_HANDLE || ema50Handle == INVALID_HANDLE)
      return 0;
   
   // Get EMA values
   double ema20[], ema50[];
   ArraySetAsSeries(ema20, true);
   ArraySetAsSeries(ema50, true);
   
   if(CopyBuffer(ema20Handle, 0, 0, 2, ema20) < 2)
   {
      Print("GetTrendDirection: Failed to copy EMA20 buffer");
      return 0;
   }
   if(CopyBuffer(ema50Handle, 0, 0, 2, ema50) < 2)
   {
      Print("GetTrendDirection: Failed to copy EMA50 buffer");
      return 0;
   }
   
   bool emaBullish = (ema20[0] > ema50[0]);
   bool emaBearish = (ema20[0] < ema50[0]);
   
   // Check M5 BOS
   int bosDirection = GetM5BOSDirection();
   
   // Check momentum direction
   int momentumDirection = GetMomentumDirection();
   
   // Debug logging
   static datetime lastLogTime = 0;
   if(TimeCurrent() - lastLogTime > 300) // Log every 5 minutes
   {
      Print("Trend Filter - EMA20: ", ema20[0], " EMA50: ", ema50[0], " | EMA Bullish: ", emaBullish, " Bearish: ", emaBearish);
      Print("Trend Filter - BOS Direction: ", bosDirection, " | Momentum Direction: ", momentumDirection);
      lastLogTime = TimeCurrent();
   }
   
   // BUY only if all agree
   if(emaBullish && bosDirection == 1 && momentumDirection == 1)
      return 1;
   
   // SELL only if all agree
   if(emaBearish && bosDirection == -1 && momentumDirection == -1)
      return -1;
   
   // Filters disagree - no trade
   return 0;
}

//+------------------------------------------------------------------+
//| Get M5 BOS (Break of Structure) direction                      |
//+------------------------------------------------------------------+
int GetM5BOSDirection()
{
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int bars = 20;  // Look back for structure
   if(CopyHigh(TradeSymbol, PERIOD_M5, 0, bars, high) < bars) return 0;
   if(CopyLow(TradeSymbol, PERIOD_M5, 0, bars, low) < bars) return 0;
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, bars, close) < bars) return 0;
   
   // Bullish BOS: price breaks above previous high
   // Bearish BOS: price breaks below previous low
   
   double currentHigh = high[0];
   double currentLow = low[0];
   double currentClose = close[0];
   
   // Find recent swing high and low
   double swingHigh = 0.0;
   double swingLow = DBL_MAX;
   int swingHighBar = 0;
   int swingLowBar = 0;
   
   for(int i = 5; i < bars - 1; i++)
   {
      // Check for swing high (higher than neighbors)
      if(high[i] > high[i-1] && high[i] > high[i+1] && high[i] > swingHigh)
      {
         swingHigh = high[i];
         swingHighBar = i;
      }
      
      // Check for swing low (lower than neighbors)
      if(low[i] < low[i-1] && low[i] < low[i+1] && low[i] < swingLow)
      {
         swingLow = low[i];
         swingLowBar = i;
      }
   }
   
   // More lenient BOS detection: check overall structure trend
   // Bullish BOS: higher highs and higher lows pattern, or break above swing high
   bool bullishStructure = false;
   if(swingHigh > 0 && swingLow < DBL_MAX)
   {
      // Check if we have higher highs (current high > previous swing high)
      if(currentHigh > swingHigh)
         bullishStructure = true;
      // Or check if swing high came after swing low (uptrend structure)
      else if(swingHighBar < swingLowBar && currentClose > (swingHigh + swingLow) / 2.0)
         bullishStructure = true;
   }
   
   // Bearish BOS: lower highs and lower lows pattern, or break below swing low
   bool bearishStructure = false;
   if(swingHigh > 0 && swingLow < DBL_MAX)
   {
      // Check if we have lower lows (current low < previous swing low)
      if(currentLow < swingLow)
         bearishStructure = true;
      // Or check if swing low came after swing high (downtrend structure)
      else if(swingLowBar < swingHighBar && currentClose < (swingHigh + swingLow) / 2.0)
         bearishStructure = true;
   }
   
   // Debug logging
   static datetime lastLogTime = 0;
   if(TimeCurrent() - lastLogTime > 300) // Log every 5 minutes
   {
      Print("BOS Check - SwingHigh: ", swingHigh, " at bar ", swingHighBar, " | SwingLow: ", swingLow, " at bar ", swingLowBar);
      Print("BOS Check - Current Close: ", currentClose, " | Bullish: ", bullishStructure, " | Bearish: ", bearishStructure);
      lastLogTime = TimeCurrent();
   }
   
   if(bullishStructure) return 1;
   if(bearishStructure) return -1;
   
   return 0;
}

//+------------------------------------------------------------------+
//| Get momentum direction                                          |
//+------------------------------------------------------------------+
int GetMomentumDirection()
{
   double close[];
   ArraySetAsSeries(close, true);
   
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, 5, close) < 5)
   {
      Print("GetMomentumDirection: Failed to copy close prices");
      return 0;
   }
   
   // More robust momentum: check multiple timeframes
   // Primary: compare current vs 3 bars ago
   double momentum = close[0] - close[3];
   
   // Secondary: check if price is making higher highs or lower lows
   bool higherHighs = (close[0] > close[1] && close[1] > close[2]);
   bool lowerLows = (close[0] < close[1] && close[1] < close[2]);
   
   // If momentum is strong or we have clear pattern, return direction
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double minMomentum = 10.0 * point;  // Minimum 10 points movement
   
   if(momentum > minMomentum || higherHighs) return 1;   // Upward momentum
   if(momentum < -minMomentum || lowerLows) return -1;  // Downward momentum
   
   // If momentum is weak but trend is clear, still return direction
   if(momentum > 0) return 1;
   if(momentum < 0) return -1;
   
   return 0;
}

//+------------------------------------------------------------------+
//| Check if price is in institutional zone                         |
//+------------------------------------------------------------------+
bool CheckInstitutionalZone(int direction)
{
   double currentPrice = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   
   // Check for M5 Order Block
   if(CheckM5OrderBlock(currentPrice, direction)) return true;
   
   // Check for M1/M5 FVG
   if(CheckFVG(currentPrice, direction)) return true;
   
   // Check for 50% retrace of last impulse
   if(Check50PercentRetrace(currentPrice, direction)) return true;
   
   // Check for previous structure retest
   if(CheckStructureRetest(currentPrice, direction)) return true;
   
   // Check for imbalance fill
   if(CheckImbalanceFill(currentPrice, direction)) return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Check M5 Order Block                                            |
//+------------------------------------------------------------------+
bool CheckM5OrderBlock(double price, int direction)
{
   double open[], high[], low[], close[];
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int bars = 10;
   if(CopyOpen(TradeSymbol, PERIOD_M5, 0, bars, open) < bars) return false;
   if(CopyHigh(TradeSymbol, PERIOD_M5, 0, bars, high) < bars) return false;
   if(CopyLow(TradeSymbol, PERIOD_M5, 0, bars, low) < bars) return false;
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, bars, close) < bars) return false;
   
   // Look for order block: strong candle followed by opposite candles
   for(int i = 3; i < bars - 1; i++)
   {
      double bodySize = MathAbs(close[i] - open[i]);
      double range = high[i] - low[i];
      if(range == 0) continue;
      
      double bodyPercent = (bodySize / range) * 100.0;
      
      // Strong bullish candle (order block for buys)
      if(direction == 1 && close[i] > open[i] && bodyPercent > 60.0)
      {
         // Check if price is retesting the low of that candle
         if(price >= low[i] && price <= high[i])
            return true;
      }
      
      // Strong bearish candle (order block for sells)
      if(direction == -1 && close[i] < open[i] && bodyPercent > 60.0)
      {
         // Check if price is retesting the high of that candle
         if(price >= low[i] && price <= high[i])
            return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check FVG (Fair Value Gap)                                      |
//+------------------------------------------------------------------+
bool CheckFVG(double price, int direction)
{
   // Check M5 FVG
   if(CheckFVGOnTimeframe(PERIOD_M5, price, direction)) return true;
   
   // Check M1 FVG
   if(CheckFVGOnTimeframe(PERIOD_M1, price, direction)) return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Check FVG on specific timeframe                                 |
//+------------------------------------------------------------------+
bool CheckFVGOnTimeframe(ENUM_TIMEFRAMES tf, double price, int direction)
{
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   int bars = 5;
   if(CopyHigh(TradeSymbol, tf, 0, bars, high) < bars) return false;
   if(CopyLow(TradeSymbol, tf, 0, bars, low) < bars) return false;
   
   // Bullish FVG: gap between candle 2 low and candle 0 high
   if(direction == 1 && bars >= 3)
   {
      double fvgTop = high[0];
      double fvgBottom = low[2];
      if(fvgBottom < fvgTop && price >= fvgBottom && price <= fvgTop)
         return true;
   }
   
   // Bearish FVG: gap between candle 2 high and candle 0 low
   if(direction == -1 && bars >= 3)
   {
      double fvgTop = high[2];
      double fvgBottom = low[0];
      if(fvgBottom < fvgTop && price >= fvgBottom && price <= fvgTop)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check 50% retrace of last impulse                               |
//+------------------------------------------------------------------+
bool Check50PercentRetrace(double price, int direction)
{
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int bars = 20;
   if(CopyHigh(TradeSymbol, PERIOD_M5, 0, bars, high) < bars) return false;
   if(CopyLow(TradeSymbol, PERIOD_M5, 0, bars, low) < bars) return false;
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, bars, close) < bars) return false;
   
   // Find last impulse move
   double impulseStart = 0.0;
   double impulseEnd = 0.0;
   
   if(direction == 1)
   {
      // Find last significant upward move
      for(int i = 1; i < bars - 1; i++)
      {
         if(close[i] > close[i+1] && close[i] > close[i-1])
         {
            impulseEnd = high[i];
            // Find start of impulse
            for(int j = i + 1; j < bars; j++)
            {
               if(low[j] < low[j-1])
               {
                  impulseStart = low[j];
                  break;
               }
            }
            break;
         }
      }
      
      if(impulseStart > 0 && impulseEnd > impulseStart)
      {
         double retraceLevel = impulseStart + (impulseEnd - impulseStart) * 0.5;
         double tolerance = (impulseEnd - impulseStart) * 0.1;  // 10% tolerance
         if(MathAbs(price - retraceLevel) <= tolerance)
            return true;
      }
   }
   else if(direction == -1)
   {
      // Find last significant downward move
      for(int i = 1; i < bars - 1; i++)
      {
         if(close[i] < close[i+1] && close[i] < close[i-1])
         {
            impulseEnd = low[i];
            // Find start of impulse
            for(int j = i + 1; j < bars; j++)
            {
               if(high[j] > high[j-1])
               {
                  impulseStart = high[j];
                  break;
               }
            }
            break;
         }
      }
      
      if(impulseStart > 0 && impulseEnd < impulseStart)
      {
         double retraceLevel = impulseStart - (impulseStart - impulseEnd) * 0.5;
         double tolerance = (impulseStart - impulseEnd) * 0.1;  // 10% tolerance
         if(MathAbs(price - retraceLevel) <= tolerance)
            return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check previous structure retest                                 |
//+------------------------------------------------------------------+
bool CheckStructureRetest(double price, int direction)
{
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int bars = 15;
   if(CopyHigh(TradeSymbol, PERIOD_M5, 0, bars, high) < bars) return false;
   if(CopyLow(TradeSymbol, PERIOD_M5, 0, bars, low) < bars) return false;
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, bars, close) < bars) return false;
   
   // Find previous structure levels
   double supportLevel = 0.0;
   double resistanceLevel = 0.0;
   
   for(int i = 3; i < bars - 1; i++)
   {
      // Support (swing low)
      if(low[i] < low[i-1] && low[i] < low[i+1])
      {
         if(supportLevel == 0 || low[i] < supportLevel)
            supportLevel = low[i];
      }
      
      // Resistance (swing high)
      if(high[i] > high[i-1] && high[i] > high[i+1])
      {
         if(resistanceLevel == 0 || high[i] > resistanceLevel)
            resistanceLevel = high[i];
      }
   }
   
   // Check retest
   if(direction == 1 && supportLevel > 0)
   {
      double tolerance = (resistanceLevel > supportLevel) ? (resistanceLevel - supportLevel) * 0.05 : 10.0;
      if(MathAbs(price - supportLevel) <= tolerance)
         return true;
   }
   
   if(direction == -1 && resistanceLevel > 0)
   {
      double tolerance = (resistanceLevel > supportLevel) ? (resistanceLevel - supportLevel) * 0.05 : 10.0;
      if(MathAbs(price - resistanceLevel) <= tolerance)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check imbalance fill                                            |
//+------------------------------------------------------------------+
bool CheckImbalanceFill(double price, int direction)
{
   // Similar to FVG but looking for price filling the gap
   return CheckFVG(price, direction);
}

//+------------------------------------------------------------------+
//| Check momentum confirmation                                     |
//+------------------------------------------------------------------+
bool CheckMomentumConfirmation(int direction)
{
   // Strong engulfing candle
   if(CheckEngulfingCandle(direction)) return true;
   
   // Minor structure break in trend direction
   if(CheckStructureBreak(direction)) return true;
   
   // Tick momentum spike
   if(CheckTickMomentumSpike(direction)) return true;
   
   // RSI confirmation
   if(CheckRSIConfirmation(direction)) return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Check engulfing candle                                          |
//+------------------------------------------------------------------+
bool CheckEngulfingCandle(int direction)
{
   double open[], high[], low[], close[];
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   if(CopyOpen(TradeSymbol, PERIOD_M5, 0, 2, open) < 2) return false;
   if(CopyHigh(TradeSymbol, PERIOD_M5, 0, 2, high) < 2) return false;
   if(CopyLow(TradeSymbol, PERIOD_M5, 0, 2, low) < 2) return false;
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, 2, close) < 2) return false;
   
   // Bullish engulfing
   if(direction == 1)
   {
      bool prevBearish = (close[1] < open[1]);
      bool currBullish = (close[0] > open[0]);
      bool engulfs = (open[0] < close[1] && close[0] > open[1]);
      
      if(prevBearish && currBullish && engulfs)
         return true;
   }
   
   // Bearish engulfing
   if(direction == -1)
   {
      bool prevBullish = (close[1] > open[1]);
      bool currBearish = (close[0] < open[0]);
      bool engulfs = (open[0] > close[1] && close[0] < open[1]);
      
      if(prevBullish && currBearish && engulfs)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check structure break                                           |
//+------------------------------------------------------------------+
bool CheckStructureBreak(int direction)
{
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int bars = 10;
   if(CopyHigh(TradeSymbol, PERIOD_M5, 0, bars, high) < bars) return false;
   if(CopyLow(TradeSymbol, PERIOD_M5, 0, bars, low) < bars) return false;
   if(CopyClose(TradeSymbol, PERIOD_M5, 0, bars, close) < bars) return false;
   
   if(direction == 1)
   {
      // Break above recent high
      for(int i = 1; i < 5; i++)
      {
         if(close[0] > high[i])
            return true;
      }
   }
   else if(direction == -1)
   {
      // Break below recent low
      for(int i = 1; i < 5; i++)
      {
         if(close[0] < low[i])
            return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check tick momentum spike                                       |
//+------------------------------------------------------------------+
bool CheckTickMomentumSpike(int direction)
{
   // Simplified: check if current price movement is strong
   double close[];
   ArraySetAsSeries(close, true);
   
   if(CopyClose(TradeSymbol, PERIOD_M1, 0, 3, close) < 3) return false;
   
   double momentum = close[0] - close[2];
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double minSpike = 50.0 * point;  // Minimum 50 points movement
   
   if(direction == 1 && momentum > minSpike) return true;
   if(direction == -1 && momentum < -minSpike) return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Check RSI confirmation                                          |
//+------------------------------------------------------------------+
bool CheckRSIConfirmation(int direction)
{
   // If in tick-based mode or handle is invalid, return false
   if(UseTickBasedEntry || rsiHandle == INVALID_HANDLE)
      return false;
   
   double rsi[];
   ArraySetAsSeries(rsi, true);
   
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsi) < 1) return false;
   
   if(direction == 1 && rsi[0] > 50) return true;
   if(direction == -1 && rsi[0] < 50) return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Open sniper entry with dynamic lot sizing and ATR targets       |
//+------------------------------------------------------------------+
void OpenSniperEntry(int direction, double lots)
{
   double price = (direction == 1) ? SymbolInfoDouble(TradeSymbol, SYMBOL_ASK) : SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   
   // ===== PRE-TRADE VALIDATION =====
   // Check if this would create hedging position
   if(IsHedgingPosition(direction))
   {
      Print("PRE-TRADE CHECK FAILED: Opposite positions exist. Attempting to close them...");
      CloseOppositePositions(direction);
      // Abort this entry attempt - will retry on next tick
      return;
   }
   
   // Normalize lot size
   double minLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP);
   lots = MathMax(minLot, MathMin(maxLot, lots));
   if(lotStep > 0)
      lots = MathFloor(lots / lotStep) * lotStep;
   lots = NormalizeDouble(lots, 2);
   
   // ===== LOCK DIRECTION BEFORE TRADE EXECUTION (PREVENTS RACE CONDITIONS) =====
   // Lock direction FIRST to prevent another tick from opening opposite trade
   LockDirection(direction);
   
   bool result = false;
   if(direction == 1)
   {
      result = trade.Buy(lots, TradeSymbol, 0, 0, 0, "Sniper BUY");
   }
   else
   {
      result = trade.Sell(lots, TradeSymbol, 0, 0, 0, "Sniper SELL");
   }
   
   if(result)
   {
      sniperSetupActive = true;
      sniperDirection = direction;
      sniperEntryPrice = price;
      sniperEntryTime = TimeCurrent();
      sniperEntryEquity = account.Equity();
      // Direction already locked above
      
      // Set virtual stop loss (ATR-based)
      int slPoints = GetDefaultStopLossPoints();
      if(direction == 1)
         sniperVirtualSL = price - (slPoints * point);
      else
         sniperVirtualSL = price + (slPoints * point);
      
      // Calculate dynamic target profit using ATR (no fixed TP needed)
      int dynamicMinProfit = GetDynamicProfitTarget();
      int dynamicMaxProfit = GetMaxDynamicProfitTarget();
      sniperTargetProfit = dynamicMinProfit * 10.0;  // Store as value units
      
      if(EnableNotifications)
      {
         string msg = StringFormat("Sniper %s entry opened. Lots: %.2f, Entry: %.2f, Virtual SL: %.2f, ATR Target: %d-%d pts",
                                   (direction == 1 ? "BUY" : "SELL"), lots, price, sniperVirtualSL, dynamicMinProfit, dynamicMaxProfit);
         SendEANotification(msg);
      }
      
      Print("Sniper entry opened: ", (direction == 1 ? "BUY" : "SELL"), " Lots: ", lots, " Price: ", price, 
            " ATR Profit Target: ", dynamicMinProfit, "-", dynamicMaxProfit, " points");
   }
   else
   {
      Print("Failed to open sniper entry. Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Detect signal decay (trend filter weakening)                     |
//+------------------------------------------------------------------+
bool IsSignalDecaying()
{
   // Only check signal decay if in sniper mode with active trade
   if(UseTickBasedEntry || !sniperSetupActive) return false;
   
   // Get current trend direction
   int currentTrendDirection = GetTrendDirection();
   
   // Signal decay occurs when:
   // 1. Trend changes from confirmed direction to neutral/opposite
   // 2. EMA cross breaks down
   // 3. Momentum reverses
   
   if(sniperDirection == 1)  // BUY trade active
   {
      // Decay if trend is now SELL or NEUTRAL
      if(currentTrendDirection != 1)
      {
         Print("SIGNAL DECAY: BUY trade active but trend changed to ", 
               (currentTrendDirection == -1 ? "SELL" : "NEUTRAL"));
         return true;
      }
   }
   else if(sniperDirection == -1)  // SELL trade active
   {
      // Decay if trend is now BUY or NEUTRAL
      if(currentTrendDirection != -1)
      {
         Print("SIGNAL DECAY: SELL trade active but trend changed to ", 
               (currentTrendDirection == 1 ? "BUY" : "NEUTRAL"));
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check for EMA crossover reversal (early decay indicator)         |
//+------------------------------------------------------------------+
bool CheckEMACrossoverReversal()
{
   // Early warning: if EMAs cross, signal is weakening
   if(UseTickBasedEntry || ema20Handle == INVALID_HANDLE || ema50Handle == INVALID_HANDLE)
      return false;
   
   double ema20[], ema50[], ema20_prev[], ema50_prev[];
   ArraySetAsSeries(ema20, true);
   ArraySetAsSeries(ema50, true);
   ArraySetAsSeries(ema20_prev, true);
   ArraySetAsSeries(ema50_prev, true);
   
   if(CopyBuffer(ema20Handle, 0, 0, 2, ema20) < 2) return false;
   if(CopyBuffer(ema50Handle, 0, 0, 2, ema50) < 2) return false;
   
   // Check if EMAs are crossing (diverging)
   bool currCrossing = (ema20[0] > ema50[0] && ema20[1] < ema50[1]) ||  // BUY cross reversing
                       (ema20[0] < ema50[0] && ema20[1] > ema50[1]);    // SELL cross reversing
   
   if(currCrossing)
   {
      Print("EARLY DECAY WARNING: EMA crossover detected - signal weakening");
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check price action reversal (breaks support/resistance)          |
//+------------------------------------------------------------------+
bool CheckPriceActionReversal()
{
   if(!sniperSetupActive) return false;
   
   double currentPrice = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   
   if(sniperDirection == 1)  // BUY trade - check for break below entry
   {
      double breakPoint = sniperEntryPrice * 0.995;  // 0.5% below entry
      if(currentPrice < breakPoint)
      {
         Print("SIGNAL DECAY: BUY entry broken by ", DoubleToString((sniperEntryPrice - currentPrice) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT), 1), " points");
         return true;
      }
   }
   else if(sniperDirection == -1)  // SELL trade - check for break above entry
   {
      double breakPoint = sniperEntryPrice * 1.005;  // 0.5% above entry
      if(currentPrice > breakPoint)
      {
         Print("SIGNAL DECAY: SELL entry broken by ", DoubleToString((currentPrice - sniperEntryPrice) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT), 1), " points");
         return true;
      }
   }
   
   return false;
}

// Recovery entry function removed in redesign to simplify entry rules.
// If recovery logic is desired, reintroduce a controlled, single-entry recovery
// with strict anti-hedging checks and dynamic lot sizing.

//+------------------------------------------------------------------+
//| Send notification                                               |
//+------------------------------------------------------------------+
void SendEANotification(string message)
{
   SendMail("NAS100 Hybrid Sniper", message);
   Print(message);
}

//+------------------------------------------------------------------+
//| Update visual indicators on chart                               |
//+------------------------------------------------------------------+
void UpdateVisualIndicators()
{
   // Update status panel
   UpdateStatusPanel();
   
   // Draw virtual stop loss line if active
   if(sniperSetupActive && sniperVirtualSL > 0)
   {
      DrawVirtualStopLoss();
   }
   else
   {
      DeleteObject("EA_VirtualSL");
   }
   
   // Draw entry price marker if active
   if(sniperSetupActive && sniperEntryPrice > 0)
   {
      DrawEntryMarker();
   }
   else
   {
      DeleteObject("EA_EntryMarker");
   }
   
   // Draw trend filter indicators
   DrawTrendFilters();
}

//+------------------------------------------------------------------+
//| Update status panel on chart                                    |
//+------------------------------------------------------------------+
void UpdateStatusPanel()
{
   string statusText = "\n=== NAS100 Microsecond Scalper ===\n";
   
   if(UseTickBasedEntry)
   {
      statusText += "MODE: INSTANT TICK-BASED\n";
   }
   else
   {
      statusText += "MODE: HYBRID SNIPER\n";
   }
   
   // Trading hours status
   bool withinHours = IsWithinTradingHours();
   statusText += "Trading Hours: " + (withinHours ? "✓ ACTIVE" : "✗ INACTIVE") + "\n";
   
   // Get current time
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   int kenyaHour = dt.hour + 3;
   if(kenyaHour >= 24) kenyaHour -= 24;
   statusText += "Kenya Time: " + IntegerToString(kenyaHour) + ":" + 
                 StringFormat("%02d", dt.min) + "\n\n";
   
   // Trading status
   if(tradingStoppedForDay)
      statusText += "Status: STOPPED (Daily Limit)\n";
   else if(tradingStoppedForLoss)
      statusText += "Status: STOPPED (Loss Limit)\n";
   else if(sniperSetupActive)
      statusText += "Status: ACTIVE TRADE\n";
   else
      statusText += "Status: SCANNING TICKS\n";
   
   // Tick-based information
   if(UseTickBasedEntry)
   {
      double spread = (lastAsk - lastBid) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
      statusText += "\n--- Tick Data ---\n";
      statusText += "Bid: " + DoubleToString(lastBid, 2) + "\n";
      statusText += "Ask: " + DoubleToString(lastAsk, 2) + "\n";
      statusText += "Spread: " + DoubleToString(spread, 1) + " pts\n";
      statusText += "Tick Movement: " + DoubleToString(tickMovement, 2) + " pts\n";
      statusText += "Direction: " + (tickDirection == 1 ? "UP" : 
                                     tickDirection == -1 ? "DOWN" : "NEUTRAL") + "\n";
      statusText += "Consecutive Ticks: " + IntegerToString(consecutiveTicks) + "\n";
      statusText += "Signal: " + (GetInstantScalpingSignal() == 1 ? "BUY" : 
                                  GetInstantScalpingSignal() == -1 ? "SELL" : "NONE") + "\n";
   }
   
   // Sniper setup info
   if(sniperSetupActive)
   {
      statusText += "\n--- Active Trade ---\n";
      statusText += "Direction: " + (sniperDirection == 1 ? "BUY" : "SELL") + "\n";
      statusText += "Entry: " + DoubleToString(sniperEntryPrice, 2) + "\n";
      if(sniperVirtualSL > 0)
         statusText += "Virtual SL: " + DoubleToString(sniperVirtualSL, 2) + "\n";
      // Show ATR-based TP range
      int minTP = GetDynamicProfitTarget();
      int maxTP = GetMaxDynamicProfitTarget();
      statusText += "TP Target (ATR): " + IntegerToString(minTP) + "-" + IntegerToString(maxTP) + " pts\n";
   }
   
   // Show trend filters only if not in tick-based mode
   if(!UseTickBasedEntry)
   {
      int trendDirection = GetTrendDirection();
      statusText += "\n--- Trend Filters ---\n";
      statusText += "Overall: " + (trendDirection == 1 ? "BULLISH" : 
                                   trendDirection == -1 ? "BEARISH" : "NEUTRAL") + "\n";
   }
   
   // Account info
   statusText += "\n--- Account ---\n";
   statusText += "Equity: " + DoubleToString(account.Equity(), 2) + "\n";
   statusText += "Balance: " + DoubleToString(account.Balance(), 2) + "\n";
   if(startOfDayBalance > 0)
   {
      double dailyPL = account.Equity() - startOfDayBalance;
      double dailyPLPercent = (dailyPL / startOfDayBalance) * 100.0;
      statusText += "Daily P/L: " + DoubleToString(dailyPL, 2) + 
                   " (" + DoubleToString(dailyPLPercent, 2) + "%)\n";
   }
   
   // Position info
   int posCount = 0;
   double totalProfit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i)) continue;
      if(position.Magic() != MagicNumber) continue;
      if(position.Symbol() != GetTradeSymbol()) continue;
      posCount++;
      totalProfit += position.Profit() + position.Swap() + position.Commission();
   }
   statusText += "\nPositions: " + IntegerToString(posCount) + "\n";
   if(posCount > 0)
      statusText += "Floating P/L: " + DoubleToString(totalProfit, 2) + "\n";
   
   // Display on chart
   Comment(statusText);
}

//+------------------------------------------------------------------+
//| Draw virtual stop loss line                                     |
//+------------------------------------------------------------------+
void DrawVirtualStopLoss()
{
   string objName = "EA_VirtualSL";
   datetime time1 = iTime(TradeSymbol, PERIOD_M5, 0);
   datetime time2 = time1 + 300 * 20; // Extend 20 bars (300 seconds = 5 minutes)
   
   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_TREND, 0, time1, sniperVirtualSL, time2, sniperVirtualSL);
      ObjectSetInteger(0, objName, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, objName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, objName, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, objName, OBJPROP_RAY_RIGHT, true);
      ObjectSetString(0, objName, OBJPROP_TEXT, "Virtual SL: " + DoubleToString(sniperVirtualSL, 2));
   }
   else
   {
      ObjectSetDouble(0, objName, OBJPROP_PRICE, 0, sniperVirtualSL);
      ObjectSetDouble(0, objName, OBJPROP_PRICE, 1, sniperVirtualSL);
   }
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Draw entry price marker                                         |
//+------------------------------------------------------------------+
void DrawEntryMarker()
{
   string objName = "EA_EntryMarker";
   datetime time = iTime(TradeSymbol, PERIOD_M5, 0);
   
   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_ARROW, 0, time, sniperEntryPrice);
      ObjectSetInteger(0, objName, OBJPROP_ARROWCODE, 
                      (sniperDirection == 1) ? 233 : 234); // Up arrow for BUY, down for SELL
      ObjectSetInteger(0, objName, OBJPROP_COLOR, 
                      (sniperDirection == 1) ? clrLime : clrOrange);
      ObjectSetInteger(0, objName, OBJPROP_WIDTH, 3);
      ObjectSetString(0, objName, OBJPROP_TEXT, 
                      (sniperDirection == 1 ? "BUY" : "SELL") + " Entry: " + 
                      DoubleToString(sniperEntryPrice, 2));
   }
   else
   {
      ObjectSetDouble(0, objName, OBJPROP_PRICE, sniperEntryPrice);
      ObjectSetInteger(0, objName, OBJPROP_TIME, time);
   }
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Draw trend filter indicators                                    |
//+------------------------------------------------------------------+
void DrawTrendFilters()
{
   // Only draw EMA labels if not in tick-based mode and handles exist
   if(UseTickBasedEntry)
   {
      // Remove EMA labels in tick-based mode
      DeleteObject("EA_EMA20_Label");
      DeleteObject("EA_EMA50_Label");
      return;
   }
   
   // Draw EMA lines on chart (they should already be on chart if indicators are added)
   // We'll just add text labels for clarity
   
   // Note: EMA handles may not exist if EA was initialized in tick-based mode
   // This is handled gracefully by checking handles first
}

//+------------------------------------------------------------------+
//| Delete chart object                                             |
//+------------------------------------------------------------------+
void DeleteObject(string objName)
{
   if(ObjectFind(0, objName) >= 0)
   {
      ObjectDelete(0, objName);
      ChartRedraw();
   }
}

//+------------------------------------------------------------------+
//| Clean up all EA objects on deinit                               |
//+------------------------------------------------------------------+
void CleanupChartObjects()
{
   DeleteObject("EA_VirtualSL");
   DeleteObject("EA_EntryMarker");
   DeleteObject("EA_EMA20_Label");
   DeleteObject("EA_EMA50_Label");
   Comment("");
}

//+------------------------------------------------------------------+
//| Process tick movement for microsecond scalping                  |
//+------------------------------------------------------------------+
void ProcessTickMovement()
{
   string symbol = GetTradeSymbol();
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
   {
      // Fallback to Bid/Ask if tick not available
      tick.bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      tick.ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      tick.time = TimeCurrent();
   }
   
   double currentPrice = (tick.bid + tick.ask) / 2.0;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   
   // Calculate tick movement
   if(lastPrice > 0)
   {
      tickMovement = (currentPrice - lastPrice) / point;
      
      // Determine direction
      if(tickMovement > MinTickMovement)
      {
         tickDirection = 1;
         consecutiveTicks = (tickDirection == 1) ? consecutiveTicks + 1 : 1;
      }
      else if(tickMovement < -MinTickMovement)
      {
         tickDirection = -1;
         consecutiveTicks = (tickDirection == -1) ? consecutiveTicks + 1 : 1;
      }
      else
      {
         // Reset if movement is too small
         if(MathAbs(tickMovement) < MinTickMovement * 0.5)
         {
            tickDirection = 0;
            consecutiveTicks = 0;
         }
      }
   }
   
   lastBid = tick.bid;
   lastAsk = tick.ask;
   lastPrice = currentPrice;
   lastTickTime = tick.time;
}

//+------------------------------------------------------------------+
//| Get instant scalping signal from tick movement                  |
//+------------------------------------------------------------------+
int GetInstantScalpingSignal()
{
   // Check spread
   string symbol = GetTradeSymbol();
   double spread = (lastAsk - lastBid) / SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(spread > MaxSpreadPoints)
      return 0;
   
   // Instant signal based on tick movement
   // BUY: consecutive upward ticks with sufficient movement
   if(tickDirection == 1 && consecutiveTicks >= 2 && tickMovement >= TickMovementThreshold)
   {
      return 1; // BUY
   }
   
   // SELL: consecutive downward ticks with sufficient movement
   if(tickDirection == -1 && consecutiveTicks >= 2 && tickMovement <= -TickMovementThreshold)
   {
      return -1; // SELL
   }
   
   // Alternative: instant entry on strong tick movement
   if(MathAbs(tickMovement) >= TickMovementThreshold * 2)
   {
      return (tickMovement > 0) ? 1 : -1;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Open instant trade (microsecond scalper)                        |
//+------------------------------------------------------------------+
void OpenInstantTrade(int direction)
{
   if(direction == 0) return;
   
   // ===== CRITICAL: PRE-TRADE ANTI-HEDGING VALIDATION FOR TICK-BASED MODE =====
   // Check if this would create hedging position (MOST CRITICAL FIX FOR TICK-BASED MODE)
   if(IsHedgingPosition(direction))
   {
      Print("TICK-BASED ANTI-HEDGE: Signal for ", (direction == 1 ? "BUY" : "SELL"), 
            " but opposite position exists. Attempting to close profitable position...");
      
      bool allClosed = CloseOppositePositions(direction);
      
      if(!allClosed)
      {
         Print("TICK-BASED ANTI-HEDGE: Opposite position(s) in LOSS - cannot close. Queuing as pending order after delay...");
         proposedPendingDirection = direction;  // Queue for pending order placement after delay
      }
      
      return;  // Abort this trade, retry on next tick after close/delay completes
   }
   
   // Check if we already have a position
   if(GetActivePositionCount() >= MaxConcurrentTrades)
      return;
   
   string symbol = GetTradeSymbol();
   double price = (direction == 1) ? lastAsk : lastBid;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   
   // Normalize lot size
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double lots = LotSize;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   if(lotStep > 0)
      lots = MathFloor(lots / lotStep) * lotStep;
   lots = NormalizeDouble(lots, 2);
   
   // NO SL/TP at order placement - manage virtually to avoid broker rejection
   // Execute trade instantly WITHOUT SL/TP
   bool result = false;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   if(direction == 1)
   {
      result = trade.Buy(lots, symbol, 0, 0, 0, "MicroScalp BUY");
   }
   else
   {
      result = trade.Sell(lots, symbol, 0, 0, 0, "MicroScalp SELL");
   }
   
   if(result)
   {
      sniperSetupActive = true;
      sniperDirection = direction;
      sniperEntryPrice = price;
      sniperEntryTime = TimeCurrent();
      sniperEntryEquity = account.Equity();
      // Lock direction in tick-based mode too
      LockDirection(direction);
      
      // Set virtual SL from ATR-based default
      int slPoints = GetDefaultStopLossPoints();
      if(direction == 1)
         sniperVirtualSL = price - (slPoints * point);
      else
         sniperVirtualSL = price + (slPoints * point);
      
      Print("INSTANT TRADE OPENED: ", (direction == 1 ? "BUY" : "SELL"), 
            " | Price: ", price, " | Lots: ", lots,
            " | Tick Movement: ", tickMovement, " | Consecutive: ", consecutiveTicks);
      
      if(EnableNotifications)
      {
         string msg = StringFormat("MicroScalp %s opened instantly. Price: %.2f, Movement: %.1f points",
                                  (direction == 1 ? "BUY" : "SELL"), price, tickMovement);
         SendEANotification(msg);
      }
      
      // Reset tick tracking after entry
      consecutiveTicks = 0;
      tickDirection = 0;
   }
   else
   {
      Print("INSTANT TRADE FAILED: ", GetLastError(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Get active position count                                       |
//+------------------------------------------------------------------+
int GetActivePositionCount()
{
   string symbol = GetTradeSymbol();
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i)) continue;
      if(position.Magic() != MagicNumber) continue;
      if(position.Symbol() != symbol) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check instant profit exit (microsecond scalper)                |
//+------------------------------------------------------------------+
void CheckInstantProfitExit()
{
   string symbol = GetTradeSymbol();
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double currentPrice = (lastBid + lastAsk) / 2.0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!position.SelectByIndex(i)) continue;
      if(position.Magic() != MagicNumber) continue;
      if(position.Symbol() != symbol) continue;
      
      double profit = position.Profit() + position.Swap() + position.Commission();
      double profitPoints = 0.0;
      
      if(position.PositionType() == POSITION_TYPE_BUY)
      {
         profitPoints = (currentPrice - position.PriceOpen()) / point;
      }
      else
      {
         profitPoints = (position.PriceOpen() - currentPrice) / point;
      }
      
      // Exit when dynamic max ATR target reached
      if(profitPoints >= GetMaxDynamicProfitTarget())
      {
         ulong ticket = position.Ticket();
         if(trade.PositionClose(ticket))
         {
            Print("SNIPER TP EXIT: Trade #", ticket, " closed at ", profitPoints, " points profit (Target: ", GetMaxDynamicProfitTarget(), ")");
            sniperSetupActive = false;
            sniperDirection = 0;
         }
      }
   }
}

//+------------------------------------------------------------------+














