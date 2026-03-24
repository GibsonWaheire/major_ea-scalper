// GibsonScalpterV1.mq5
// Tick Velocity EA - Multi-instrument
#property copyright "Gibson Scalpter EA"
#property link      "local"
#property version   "3.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

// --- Inputs ---
input int      MagicNumber           = 905533;
input double   BaseLot               = 0.02;   // Lot for first trade (min)
input double   MaxLot                = 0.03;   // Cap (scale up to this)
input double   ProfitPerLotStep       = 10.0;  // Every $X realized profit adds LotIncrement
input double   LotIncrement          = 0.01;   // Lot added per profit step
input int      MinTotalTrades        = 1;      // Min trades per basket
input int      MaxTotalTrades        = 10;     // Max trades per basket (1-20 dynamic)
input int      ATRPeriod             = 14;
input ENUM_TIMEFRAMES MomentumTF     = PERIOD_M1; // Momentum timeframe (M1 for scalping)
input ENUM_TIMEFRAMES ATRTimeframe   = PERIOD_M1;
input double   MomentumThresholdATR  = 0.15;   // Minimum momentum to trigger breakout entry (ATR fraction)
input int      MomentumLookback      = 2;      // Number of candles to look back for momentum
input bool     RequireVolumeConfirmation = false; // Require volume confirmation for breakout
input int      DeviationPoints       = 30;     // Slippage guard
input double   SpreadLimitPoints     = 16;     // No trades when spread above this (points)
input int      MinSecondsBetweenEntries = 0;   // Min seconds between opening new trades (0 = HFT)
input int      MinSecondsBetweenTrades = 1;   // Min seconds between each new trade (staggered entry)
input bool     OneEntryPerBar       = false;  // Max one entry per M1 bar (false = HFT)
input bool     UseLimitOrders       = true;   // Use limit orders instead of market
input bool     UseStopOrders        = true;   // true=Breakout Stop, false=Limit (dip/rally)
input int      MarketOrdersAtExecution = 4;    // Market orders to open immediately on signal
input int      LimitOrderCount      = 5;      // Number of limit orders per basket
input int      MinPendingHoldSeconds = 3;     // Min seconds before cancelling pendings on direction change
input int      PendingOrderTimeoutSeconds = 60; // Cancel pendings if not filled after this many seconds
input double   TickVelocitySpikeATR = 0.5;  // Spike if price moves more than this ATR in 500ms (scales per instrument)
input int      TradingStartHour     = 7;     // Institutional hours: no new entries before this (broker time)
input int      TradingEndHour       = 20;    // Institutional hours: no new entries at or after this (broker time)
input bool     ShowStatusOnChart    = true;  // Show block reason on chart (spread, hours, etc.)

// --- Stop Loss Settings ---
input bool     UseStopLoss           = true;   // Enable stop loss
input double   StopLossPointsMetal   = 1000.0; // Stop loss in points for high-point symbols
input double   StopLossPointsForex   = 300.0;  // Stop loss in points for forex
input double   StopLossPointsIndex   = 200.0;  // Stop loss in points for indices

// --- Basket Exit Settings ---
input bool     IncludeAllTrades      = true;   // Include all trades (even pre-existing) in basket profit
input int      BulkCloseTimeoutSeconds = 180; // Retry failed closes for up to this many seconds

// --- Exit Settings ---
input bool     UseBreakEven          = false;  // Move stop loss to break-even (disables wide SL)
input double   BreakEvenTriggerATR   = 0.5;    // Move to BE when profit reaches this ATR
input bool     UseTrailingStop       = false;  // Use trailing stop (disables wide SL)
input double   TrailingStopATR        = 1.0;    // Trailing stop distance in ATR
input double   TrailingStepATR       = 0.3;    // Trailing step in ATR

// --- Globals ---
CTrade         trade;
CPositionInfo  pos;
int            atrHandle     = -1;
bool           eaInitialized = false;
double         lastPrice     = 0.0;  // Track last price for momentum calculation
datetime       lastEntryTime = 0;    // Entry cooldown
datetime       lastEntryBar  = 0;    // One entry per bar
datetime       lastTradeOpenTime = 0; // Last trade opened (staggered entry)
double         cumulativeRealizedProfit = 0;  // Realized profit from closed trades (for lot scaling)
double         tickVelPrice  = 0.0;  // Tick Velocity Filter: price at last sample
ulong          tickVelTime   = 0;    // Tick Velocity Filter: last sample time (ms)
double         g_spreadHistory[100];  // Last 100 tick spreads for defensive scaling
int            g_spreadHistoryCount = 0;
int            g_spreadHistoryIdx   = 0;
datetime       g_bulkCloseStart     = 0;  // When bulk close was triggered (for retry)
string         g_bulkCloseSymbol    = ""; // Symbol being bulk closed

// ---------------------------------------------------------------------------
// Debug instrumentation (agent log)
// ---------------------------------------------------------------------------
// #region agent log
void DebugLog(string loc, string msg, string hyp, string key, string val)
{
   string path = "debug.log";
   int h = FileOpen(path, FILE_TXT|FILE_READ|FILE_WRITE|FILE_ANSI);
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, "{\"loc\":\""+loc+"\",\"msg\":\""+msg+"\",\"hyp\":\""+hyp+"\",\""+key+"\":\""+val+"\",\"ts\":"+IntegerToString((int)TimeCurrent())+"}\n");
      FileClose(h);
   }
}
// #endregion

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------
void ChartStatus(const string msg)
{
   if(ShowStatusOnChart)
      Comment("GibsonScalpter\n", msg);
}

bool EnsureSymbolReady(const string symbol)
{
   // #region agent log
   DebugLog("EnsureSymbolReady:entry", "check", "B", "symbol", symbol);
   // #endregion
   if(!SymbolSelect(symbol, true))
   {
      // #region agent log
      DebugLog("EnsureSymbolReady:fail", "SymbolSelect failed", "B", "symbol", symbol);
      // #endregion
      Print("Failed to select symbol ", symbol);
      return false;
   }
   if(SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      // #region agent log
      DebugLog("EnsureSymbolReady:fail", "trade disabled", "B", "symbol", symbol);
      // #endregion
      Print("Symbol trading disabled: ", symbol);
      return false;
   }
   // #region agent log
   DebugLog("EnsureSymbolReady:ok", "ready", "B", "symbol", symbol);
   // #endregion
   return true;
}

// Close all existing trades (any magic number) when EA is activated
void CloseAllExistingTrades(const string symbol)
{
   int closed = 0;
   int deleted = 0;
   
   // Close all market positions
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      
      ulong ticket = pos.Ticket();
      if(trade.PositionClose(ticket, DeviationPoints))
      {
         closed++;
         Print("Closed existing position: ", ticket);
      }
   }
   
   // Delete all pending orders
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      
      ulong ticket = OrderGetInteger(ORDER_TICKET);
      if(trade.OrderDelete(ticket))
      {
         deleted++;
         Print("Deleted existing order: ", ticket);
      }
   }
   
   if(closed > 0 || deleted > 0)
      Print("Closed ", closed, " positions and deleted ", deleted, " orders on EA activation");
}

double GetATR()
{
   if(atrHandle < 0)
      return 0.0;
   double buffer[2];
   if(CopyBuffer(atrHandle, 0, 0, 2, buffer) < 1)
      return 0.0;
   return buffer[0];
}

// Detect Momentum Breakout - Sniper entries with blockers
int DetectMomentumBreakout(const string symbol, double atr)
{
   if(atr <= 0)
      return 0;
   
   double high[], low[], open[], close[];
   long volume[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(volume, true);
   
   int lookback = MomentumLookback + 1;
   int ch = CopyHigh(symbol, MomentumTF, 0, lookback, high);
   int cl = CopyClose(symbol, MomentumTF, 0, lookback, close);
   // #region agent log
   static int momCount = 0;
   if(++momCount <= 2 || (momCount % 50 == 0))
      DebugLog("DetectMomentum:copy", "data", "E", "symbol_copyResult", symbol + " ch=" + IntegerToString(ch) + " cl=" + IntegerToString(cl) + " need=" + IntegerToString(lookback));
   // #endregion
   if(ch < lookback || CopyLow(symbol, MomentumTF, 0, lookback, low) < lookback ||
      CopyOpen(symbol, MomentumTF, 0, lookback, open) < lookback || cl < lookback)
      return 0;
   
   if(RequireVolumeConfirmation)
   {
      if(CopyTickVolume(symbol, MomentumTF, 0, lookback, volume) < lookback)
         return 0;
   }
   
   // Calculate momentum over lookback period
   double momentum = close[0] - close[MomentumLookback];
   double momentumThreshold = atr * MomentumThresholdATR;
   
   // Check if momentum exceeds threshold
   if(MathAbs(momentum) < momentumThreshold)
      return 0;
   
   // Volume confirmation (if enabled)
   if(RequireVolumeConfirmation && lookback > 1)
   {
      long currentVolume = volume[0];
      long avgVolume = 0;
      for(int i = 1; i < lookback; i++)
         avgVolume += volume[i];
      avgVolume = avgVolume / (lookback - 1);
      
      // Require current volume to be above average
      if(currentVolume < avgVolume * 0.8)
         return 0;
   }
   
   // Return direction: 1 = BUY, -1 = SELL
   return (momentum > 0) ? 1 : -1;
}

// GetEMA and GetRSI removed - not used in order block strategy

double NormalizeVolume(const string symbol, double lots)
{
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   lots = MathMax(minLot, MathMin(maxLot, lots));
   if(step > 0)
      lots = MathFloor(lots / step) * step;
   lots = MathMax(minLot, lots);  // Re-apply min after rounding
   return NormalizeDouble(lots, 2);
}

// Update spread history (call from OnTick each tick)
void UpdateSpreadHistory(const string symbol)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0) return;
   double spread = (SymbolInfoDouble(symbol, SYMBOL_ASK) - SymbolInfoDouble(symbol, SYMBOL_BID)) / point;
   g_spreadHistory[g_spreadHistoryIdx] = spread;
   g_spreadHistoryIdx = (g_spreadHistoryIdx + 1) % 100;
   if(g_spreadHistoryCount < 100) g_spreadHistoryCount++;
}

double GetAverageSpread()
{
   if(g_spreadHistoryCount < 10) return 0;
   double sum = 0;
   for(int i = 0; i < g_spreadHistoryCount; i++)
      sum += g_spreadHistory[i];
   return sum / g_spreadHistoryCount;
}

// Lot scaling: profit-based + liquidity (volume/spread)
double GetScaledLot(const string symbol)
{
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   if(ProfitPerLotStep <= 0) return NormalizeVolume(symbol, BaseLot);
   int steps = (int)MathFloor(cumulativeRealizedProfit / ProfitPerLotStep);
   double lot = BaseLot + (steps * LotIncrement);
   lot = MathMin(MaxLot, MathMax(minLot, lot));
   
   // Liquidity-based scaling: 20-period volume
   long volume[];
   ArraySetAsSeries(volume, true);
   if(CopyTickVolume(symbol, MomentumTF, 0, 21, volume) >= 21)
   {
      long avgVolume = 0;
      for(int i = 1; i < 21; i++)
         avgVolume += volume[i];
      avgVolume /= 20;
      if(avgVolume > 0 && volume[0] > avgVolume * 1.5)
         lot *= 1.2;  // Aggressive: high volume
   }
   
   // Defensive: spread > avg spread * 1.5
   double avgSpread = GetAverageSpread();
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double currentSpread = (point > 0) ? (SymbolInfoDouble(symbol, SYMBOL_ASK) - SymbolInfoDouble(symbol, SYMBOL_BID)) / point : 0;
   if(avgSpread > 0 && currentSpread > avgSpread * 1.5)
      lot *= 0.5;  // Defensive: wide spread
   
   lot = MathMin(MaxLot, MathMax(minLot, lot));
   return NormalizeVolume(symbol, lot);
}

// Alternating lot: consecutive trades get different lots (even=base, odd=base+increment)
double GetNextLot(const string symbol)
{
   int count = PositionsCount(symbol) + PendingOrdersCount(symbol);
   double base = GetScaledLot(symbol);
   double lot = (count % 2 == 0) ? base : base + LotIncrement;
   return NormalizeVolume(symbol, MathMin(MaxLot, lot));
}

// Count all positions (including pre-existing if IncludeAllTrades is true)
int PositionsCount(const string symbol)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      
      // Include all trades if enabled, otherwise only EA trades
      if(!IncludeAllTrades && pos.Magic() != MagicNumber)
         continue;
      
      count++;
   }
   return count;
}

// Count all pending orders (including pre-existing if IncludeAllTrades is true)
int PendingOrdersCount(const string symbol)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      
      // Include all orders if enabled, otherwise only EA orders
      if(!IncludeAllTrades && OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;
      
      count++;
   }
   return count;
}

// Returns: 1 = any BUY (limit/stop), -1 = any SELL (limit/stop), 0 = none or mixed
int GetPendingOrdersDirection(const string symbol)
{
   int buys = 0, sells = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(!IncludeAllTrades && OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(otype == ORDER_TYPE_BUY_LIMIT || otype == ORDER_TYPE_BUY_STOP) buys++;
      else if(otype == ORDER_TYPE_SELL_LIMIT || otype == ORDER_TYPE_SELL_STOP) sells++;
   }
   if(buys == 0 && sells == 0) return 0;
   return (buys >= sells) ? 1 : -1;
}

datetime GetOldestPendingOrderTime(const string symbol)
{
   datetime oldest = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(!IncludeAllTrades && OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      datetime t = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(oldest == 0 || t < oldest)
         oldest = t;
   }
   return oldest;
}

void DeletePendingOrdersOnly(const string symbol)
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(!IncludeAllTrades && OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      ulong ticket = OrderGetInteger(ORDER_TICKET);
      if(trade.OrderDelete(ticket))
         Print("Deleted pending order ", ticket, " (direction change)");
   }
}

// Returns: 1 = BUY, -1 = SELL, 0 = none. Uses positions first, else pendings (one direction only)
int GetBasketOrPendingDirection(const string symbol)
{
   int posDir = GetBasketDirection(symbol);
   if(posDir != 0) return posDir;
   return GetPendingOrdersDirection(symbol);
}

// Returns: 1 = all BUY, -1 = all SELL, 0 = no positions
int GetBasketDirection(const string symbol)
{
   int buys = 0, sells = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      if(!IncludeAllTrades && pos.Magic() != MagicNumber) continue;
      if(pos.PositionType() == POSITION_TYPE_BUY) buys++; else sells++;
   }
   if(buys == 0 && sells == 0) return 0;
   return (buys >= sells) ? 1 : -1;
}

// Calculate total profit for all trades (basket)
double BasketProfit(const string symbol)
{
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      
      // Include all trades if enabled, otherwise only EA trades
      if(!IncludeAllTrades && pos.Magic() != MagicNumber)
         continue;
      
      profit += pos.Profit();
      profit += pos.Swap();
      profit += pos.Commission();
   }
   return profit;
}

// Calculate total lots for all trades (basket)
double BasketLots(const string symbol)
{
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      
      // Include all trades if enabled, otherwise only EA trades
      if(!IncludeAllTrades && pos.Magic() != MagicNumber)
         continue;
      
      lots += pos.Volume();
   }
   return lots;
}

datetime BasketOldestOpen(const string symbol)
{
   datetime oldest = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      if(!IncludeAllTrades && pos.Magic() != MagicNumber) continue;
      datetime opentime = pos.Time();
      if(oldest == 0 || opentime < oldest)
         oldest = opentime;
   }
   return oldest;
}

// Velocity: current bar range / ATR (0-1). High = fast market.
double GetVelocity(const string symbol, double atr)
{
   if(atr <= 0) return 0;
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   if(CopyHigh(symbol, MomentumTF, 0, 1, high) < 1 || CopyLow(symbol, MomentumTF, 0, 1, low) < 1)
      return 0;
   double range = high[0] - low[0];
   return MathMin(1.0, range / atr);
}

// Removed - not used in new strategy

// Close all trades in basket - async bulk close, retry within BulkCloseTimeoutSeconds
bool CloseBasket(const string symbol)
{
   // Count first for pre-allocation
   int nPos = 0, nOrd = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      if(!IncludeAllTrades && pos.Magic() != MagicNumber) continue;
      nPos++;
   }
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(!IncludeAllTrades && OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      nOrd++;
   }
   if(nPos == 0 && nOrd == 0)
   {
      g_bulkCloseStart = 0;
      g_bulkCloseSymbol = "";
      return true;
   }
   
   // Pre-allocate and collect tickets
   ulong posTickets[];
   ulong ordTickets[];
   ArrayResize(posTickets, nPos);
   ArrayResize(ordTickets, nOrd);
   int iPos = 0, iOrd = 0;
   for(int i = PositionsTotal() - 1; i >= 0 && iPos < nPos; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      if(!IncludeAllTrades && pos.Magic() != MagicNumber) continue;
      posTickets[iPos++] = pos.Ticket();
   }
   for(int i = OrdersTotal() - 1; i >= 0 && iOrd < nOrd; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(!IncludeAllTrades && OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      ordTickets[iOrd++] = OrderGetInteger(ORDER_TICKET);
   }
   
   // Bulk close: async mode - send all requests as fast as possible
   g_bulkCloseStart = TimeCurrent();
   g_bulkCloseSymbol = symbol;
   trade.SetAsyncMode(true);
   for(int i = 0; i < nPos; i++)
      trade.PositionClose(posTickets[i], DeviationPoints);
   for(int i = 0; i < nOrd; i++)
      trade.OrderDelete(ordTickets[i]);
   trade.SetAsyncMode(false);
   
   // Defer Print until after async requests sent
   if(nPos > 0 || nOrd > 0)
   {
      Print("Bulk close sent: ", nPos, " positions, ", nOrd, " orders for ", symbol);
   }
   return true;
}

// Symbol type helpers - select SL by instrument point scale
bool IsMetalSymbol(const string symbol)
{
   double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
   return (pt > 0 && pt >= 0.01);
}
bool IsIndexSymbol(const string symbol)
{
   return (StringFind(symbol, "US30") >= 0 || StringFind(symbol, "DJ30") >= 0 ||
           StringFind(symbol, "USTEC") >= 0 || StringFind(symbol, "NAS") >= 0 ||
           StringFind(symbol, "US500") >= 0 || StringFind(symbol, "SPX") >= 0);
}
double GetStopLossPointsForSymbol(const string symbol)
{
   if(IsMetalSymbol(symbol)) return StopLossPointsMetal;
   if(IsIndexSymbol(symbol)) return StopLossPointsIndex;
   return StopLossPointsForex;
}

double GetStopLossPrice(const string symbol, int direction)
{
   if(!UseStopLoss)
      return 0;
   
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double stopLossPoints = GetStopLossPointsForSymbol(symbol);
   
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double stopLoss = 0;
   
   if(direction > 0) // BUY
   {
      stopLoss = ask - (stopLossPoints * point);
   }
   else // SELL
   {
      stopLoss = bid + (stopLossPoints * point);
   }
   
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return NormalizeDouble(stopLoss, digits);
}

bool OpenMarket(const string symbol, int direction, double atr)
{
   // Check total trades limit (dynamic 1-10)
   int totalTrades = PositionsCount(symbol) + PendingOrdersCount(symbol);
   int maxTrades = MathMax(MinTotalTrades, MathMin(10, MaxTotalTrades));
   if(totalTrades >= maxTrades)
   {
      Print("Maximum trades limit reached: ", totalTrades, "/", maxTrades);
      return false;
   }
   
   double lot = GetNextLot(symbol);
   if(lot <= 0)
   {
      Print("Lot calculation failed, aborting entry");
      return false;
   }
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   
   double stopLoss = GetStopLossPrice(symbol, direction);
   // NO TAKE PROFIT - Let trades run until basket profit target is reached
   double takeProfit = 0; // No individual TP - basket management only
   bool result = false;
   
   if(direction > 0)
      result = trade.Buy(lot, symbol, 0, stopLoss, 0, "Momentum BUY");
   else
      result = trade.Sell(lot, symbol, 0, stopLoss, 0, "Momentum SELL");
   
   if(result)
   {
      double slPoints = GetStopLossPointsForSymbol(symbol);
      Print("Opened trade: ", (direction > 0 ? "BUY" : "SELL"), 
            " | Lot: ", DoubleToString(lot, 2),
            " | SL: ", DoubleToString(stopLoss, 5), " (", DoubleToString(slPoints, 1), " pts)",
            " | TP: NONE (Basket management only)");
   }
   else
      Print("Failed to open trade. Error: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   return result;
}

bool PlaceSingleLimitOrder(const string symbol, int direction, double atr)
{
   int pendingCount = PendingOrdersCount(symbol);
   if(pendingCount >= LimitOrderCount)
      return false;
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stopLossPoints = GetStopLossPointsForSymbol(symbol);
   
   double offsets[] = {0.2, 0.4, 0.6, 0.8, 1.0};
   double minOffset = MathMax(atr * 0.2, (double)stopsLevel * point);
   int offsetIndex = MathMin(pendingCount, 4);
   double offset = MathMax(atr * offsets[offsetIndex], minOffset);
   double lot = GetNextLot(symbol);
   double limitPrice = 0;
   double sl = 0;
   
   if(direction > 0)  // BUY
   {
      if(UseStopOrders)  // Breakout: Buy Stop above ask
      {
         limitPrice = NormalizeDouble(ask + offset, digits);
         sl = NormalizeDouble(limitPrice - stopLossPoints * point, digits);
         if(trade.BuyStop(lot, limitPrice, symbol, sl, 0, ORDER_TIME_GTC, 0, "Stop BUY"))
         {
            Print("Placed stop BUY ", (pendingCount + 1), "/", LimitOrderCount, " | Lot: ", DoubleToString(lot, 2));
            return true;
         }
         Print("BuyStop failed: ", trade.ResultRetcode(), " at ", limitPrice);
      }
      else  // Limit: Buy Limit below bid
      {
         limitPrice = NormalizeDouble(bid - offset, digits);
         sl = NormalizeDouble(limitPrice - stopLossPoints * point, digits);
         if(trade.BuyLimit(lot, limitPrice, symbol, sl, 0, ORDER_TIME_GTC, 0, "Limit BUY"))
         {
            Print("Placed limit BUY ", (pendingCount + 1), "/", LimitOrderCount, " | Lot: ", DoubleToString(lot, 2));
            return true;
         }
         Print("BuyLimit failed: ", trade.ResultRetcode(), " at ", limitPrice);
      }
   }
   else  // SELL
   {
      if(UseStopOrders)  // Breakout: Sell Stop below bid
      {
         limitPrice = NormalizeDouble(bid - offset, digits);
         sl = NormalizeDouble(limitPrice + stopLossPoints * point, digits);
         if(trade.SellStop(lot, limitPrice, symbol, sl, 0, ORDER_TIME_GTC, 0, "Stop SELL"))
         {
            Print("Placed stop SELL ", (pendingCount + 1), "/", LimitOrderCount, " | Lot: ", DoubleToString(lot, 2));
            return true;
         }
         Print("SellStop failed: ", trade.ResultRetcode(), " at ", limitPrice);
      }
      else  // Limit: Sell Limit above ask
      {
         limitPrice = NormalizeDouble(ask + offset, digits);
         sl = NormalizeDouble(limitPrice + stopLossPoints * point, digits);
         if(trade.SellLimit(lot, limitPrice, symbol, sl, 0, ORDER_TIME_GTC, 0, "Limit SELL"))
         {
            Print("Placed limit SELL ", (pendingCount + 1), "/", LimitOrderCount, " | Lot: ", DoubleToString(lot, 2));
            return true;
         }
         Print("SellLimit failed: ", trade.ResultRetcode(), " at ", limitPrice);
      }
   }
   return false;
}

bool SpreadOK(const string symbol)
{
   double spread = (SymbolInfoDouble(symbol, SYMBOL_ASK) - SymbolInfoDouble(symbol, SYMBOL_BID)) / SymbolInfoDouble(symbol, SYMBOL_POINT);
   return spread <= SpreadLimitPoints;
}

// Basket Exit Management - Close individual or basket when profitable
void ManageExits(const string symbol, double atr)
{
   if(atr <= 0) return;
   
   double basketProfit = BasketProfit(symbol);
   double totalLots = BasketLots(symbol);
   
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double spreadPts = (point > 0) ? (ask - bid) / point : 0;
   double spreadCost = 0;
   if(point > 0 && tickSize > 0 && totalLots > 0)
      spreadCost = (spreadPts * point) * (totalLots / tickSize) * tickValue;
   double profitFloor = 1.2 * spreadCost;
   
   // Bulk close profitable - overrides all
   if(basketProfit > 0 && basketProfit >= profitFloor)
   {
      cumulativeRealizedProfit += basketProfit;
      Print("Bulk close profitable: ", DoubleToString(basketProfit, 2));
      CloseBasket(symbol);
      return;
   }
   
   // Break-even protection and stop loss management
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double stopLossPoints = GetStopLossPointsForSymbol(symbol);
   double breakEvenTrigger = atr * BreakEvenTriggerATR;
   
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      
      // Include all trades if enabled
      if(!IncludeAllTrades && pos.Magic() != MagicNumber)
         continue;
      
      ulong ticket = pos.Ticket();
      double currentSL = pos.StopLoss();
      double currentTP = pos.TakeProfit();
      double openPrice = pos.PriceOpen();
      double positionProfit = pos.Profit() + pos.Swap() + pos.Commission();
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)pos.PositionType();
      
      // Add stop loss if missing
      if(UseStopLoss && currentSL == 0)
      {
         double newSL = 0;
         
         if(ptype == POSITION_TYPE_BUY)
            newSL = ask - (stopLossPoints * point);
         else if(ptype == POSITION_TYPE_SELL)
            newSL = bid + (stopLossPoints * point);
         
         if(newSL > 0)
         {
            newSL = NormalizeDouble(newSL, digits);
            trade.PositionModify(ticket, newSL, currentTP);
         }
         continue;
      }
      
      // Break-even protection - move SL to entry when profitable
      if(UseBreakEven && currentSL > 0 && positionProfit > 0)
      {
         double priceDistance = 0;
         bool shouldMoveToBE = false;
         
         if(ptype == POSITION_TYPE_BUY)
         {
            priceDistance = bid - openPrice;
            // Move to BE if profit distance >= trigger and SL is below entry
            if(priceDistance >= breakEvenTrigger && currentSL < openPrice)
               shouldMoveToBE = true;
         }
         else if(ptype == POSITION_TYPE_SELL)
         {
            priceDistance = openPrice - ask;
            // Move to BE if profit distance >= trigger and SL is above entry
            if(priceDistance >= breakEvenTrigger && currentSL > openPrice)
               shouldMoveToBE = true;
         }
         
         if(shouldMoveToBE)
         {
            double newSL = NormalizeDouble(openPrice, digits);
            // Add small buffer to avoid immediate stop
            if(ptype == POSITION_TYPE_BUY)
               newSL = NormalizeDouble(openPrice - (point * 5), digits); // 5 points below entry
            else
               newSL = NormalizeDouble(openPrice + (point * 5), digits); // 5 points above entry
               
            if(newSL != currentSL)
            {
               if(trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("Break-even set for position ", ticket, " at ", DoubleToString(newSL, digits));
               }
            }
         }
      }
   }
   
   // Trailing stop - protect profits as they grow
   if(UseTrailingStop)
   {
      double trailingDistance = atr * TrailingStopATR;
      double trailingStep = atr * TrailingStepATR;
      
      for(int i = PositionsTotal() - 1; i >= 0; --i)
      {
         if(!pos.SelectByIndex(i)) continue;
         if(pos.Symbol() != symbol) continue;
         
         // Include all trades if enabled
         if(!IncludeAllTrades && pos.Magic() != MagicNumber)
            continue;
         
         ulong ticket = pos.Ticket();
         double currentSL = pos.StopLoss();
         double currentTP = pos.TakeProfit();
         double openPrice = pos.PriceOpen();
         double positionProfit = pos.Profit() + pos.Swap() + pos.Commission();
         ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)pos.PositionType();
         
         // Only trail if position is profitable and has stop loss
         if(currentSL > 0 && positionProfit > 0)
         {
            double newSL = currentSL;
            bool modifyNeeded = false;
            
            if(ptype == POSITION_TYPE_BUY)
            {
               double idealSL = bid - trailingDistance;
               // Only move SL up, never down
               if(idealSL > currentSL + trailingStep && idealSL > openPrice)
               {
                  newSL = NormalizeDouble(idealSL, digits);
                  modifyNeeded = true;
               }
            }
            else if(ptype == POSITION_TYPE_SELL)
            {
               double idealSL = ask + trailingDistance;
               // Only move SL down, never up
               if((idealSL < currentSL - trailingStep || currentSL == 0) && idealSL < openPrice)
               {
                  newSL = NormalizeDouble(idealSL, digits);
                  modifyNeeded = true;
               }
            }
            
            if(modifyNeeded && newSL != currentSL)
            {
               if(trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("Trailing stop updated for position ", ticket, 
                        " | Old SL: ", DoubleToString(currentSL, digits),
                        " | New SL: ", DoubleToString(newSL, digits));
               }
            }
         }
      }
   }
}

// ---------------------------------------------------------------------------
// Core logic
// ---------------------------------------------------------------------------
int OnInit()
{
   // #region agent log
   DebugLog("OnInit", "start", "A", "symbol", _Symbol);
   // #endregion
   if(!EnsureSymbolReady(_Symbol))
      return INIT_FAILED;
   
   // Close all existing trades when EA is activated
   CloseAllExistingTrades(_Symbol);
   
   // Initialize ATR
   atrHandle = iATR(_Symbol, ATRTimeframe, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ATR handle failed");
      return INIT_FAILED;
   }
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   
   cumulativeRealizedProfit = 0;
   
   double firstLot = GetScaledLot(_Symbol);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(BaseLot < minLot)
      Print("WARNING: BaseLot ", BaseLot, " < broker min ", minLot, ". Using ", minLot);
   int maxTrades = MathMax(MinTotalTrades, MathMin(20, MaxTotalTrades));
   
   Print("========================================");
   Print("Momentum Breakout EA initialized");
   Print("========================================");
   Print("Symbol: ", _Symbol, " (chart symbol - trades this instrument)");
   Print("Lot: Base=", BaseLot, " Max=", MaxLot, " | Every $", ProfitPerLotStep, " profit + ", LotIncrement, " (first=", DoubleToString(firstLot, 2), ")");
   Print("Trades per basket: ", MinTotalTrades, "-", maxTrades);
   string tfStr = (MomentumTF == PERIOD_M1) ? "M1 (Scalping)" : 
                  (MomentumTF == PERIOD_M5) ? "M5" :
                  (MomentumTF == PERIOD_M15) ? "M15" : "Custom";
   Print("Momentum Timeframe: ", tfStr);
   Print("Momentum Threshold: ", MomentumThresholdATR, "x ATR");
   Print("Momentum Lookback: ", MomentumLookback, " candles");
   Print("Volume Confirmation: ", (RequireVolumeConfirmation ? "ENABLED" : "DISABLED"));
   Print("Entry cooldown: ", MinSecondsBetweenEntries, " sec | Stagger: ", MinSecondsBetweenTrades, " sec between trades | One per bar: ", (OneEntryPerBar ? "YES" : "NO"));
   Print("Institutional hours: ", TradingStartHour, ":00 - ", TradingEndHour, ":00 broker time");
   Print("Liquidity scaling: 1.2x on high volume, 0.5x on wide spread");
   if(TickVelocitySpikeATR > 0)
      Print("Tick Velocity Filter: ENABLED | Spike if price moves > ", TickVelocitySpikeATR, " ATR in 500ms");
   else
      Print("Tick Velocity Filter: DISABLED");
   Print("Same-direction rule: ENABLED (no mixed BUY/SELL basket)");
   if(UseLimitOrders)
   {
      long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      Print("Entry: ", MarketOrdersAtExecution, " market + ", LimitOrderCount, " ", (UseStopOrders ? "stop" : "limit"), " | Min distance: ", stopsLevel, " pts");
      Print("Cancel pendings: direction change after ", MinPendingHoldSeconds, " sec | timeout ", PendingOrderTimeoutSeconds, " sec");
      double atrInit = GetATR();
      if(atrInit > 0)
      {
         double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         double minOffset = MathMax(atrInit * 0.2, (double)stopsLevel * point);
         Print("First limit offset: ", DoubleToString(minOffset, 5), " (price)");
      }
   }
   Print("Stop Loss: ", (UseStopLoss ? "ENABLED" : "DISABLED"));
   if(UseStopLoss)
   {
      Print("  - Metal: ", StopLossPointsMetal, " pts | Forex: ", StopLossPointsForex, " pts | Index: ", StopLossPointsIndex, " pts");
   }
   Print("Trailing Stop: ", (UseTrailingStop ? "ENABLED" : "DISABLED"));
   if(UseTrailingStop)
   {
      Print("  - Trailing distance: ", TrailingStopATR, " ATR");
      Print("  - Trailing step: ", TrailingStepATR, " ATR");
   }
   Print("Strategy: MOMENTUM BREAKOUT - Bulk Close Profitable");
   Print("Exit: Bulk close when profitable (1.2x spread cost) | Include All: ", (IncludeAllTrades ? "YES" : "NO"));
   Print("  - Bulk close retry: ", BulkCloseTimeoutSeconds, "s");
   Print("Break-Even Protection: ", (UseBreakEven ? "ENABLED" : "DISABLED"));
   if(UseBreakEven)
      Print("  - Break-Even Trigger: ", BreakEvenTriggerATR, "x ATR profit");
   Print("Trailing Stop: ", (UseTrailingStop ? "ENABLED" : "DISABLED"));
   if(UseTrailingStop)
   {
      Print("  - Trailing distance: ", TrailingStopATR, " ATR");
      Print("  - Trailing step: ", TrailingStepATR, " ATR");
   }
   Print("========================================");
   
   eaInitialized = true;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");  // Clear status on chart
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   Print("EA stopped. reason=", reason);
}

void OnTick()
{
   // Bulk close retry: if previous close left positions, retry within timeout window
   if(g_bulkCloseStart > 0 && g_bulkCloseSymbol != "")
   {
      int elapsed = (int)(TimeCurrent() - g_bulkCloseStart);
      int remaining = PositionsCount(g_bulkCloseSymbol) + PendingOrdersCount(g_bulkCloseSymbol);
      if(remaining == 0 || elapsed >= BulkCloseTimeoutSeconds)
      {
         g_bulkCloseStart = 0;
         g_bulkCloseSymbol = "";
         if(remaining == 0)
            Print("Bulk close complete - all positions closed.");
         else if(elapsed >= BulkCloseTimeoutSeconds)
            Print("Bulk close timeout (", BulkCloseTimeoutSeconds, "s) - ", remaining, " positions remain.");
      }
      else
      {
         if(EnsureSymbolReady(g_bulkCloseSymbol))
            CloseBasket(g_bulkCloseSymbol);
         return;
      }
   }
   
   // #region agent log
   static int tickCount = 0;
   if(++tickCount <= 3 || (tickCount % 100 == 0))
      DebugLog("OnTick:entry", "tick", "A", "symbol", _Symbol);
   // #endregion
   if(!EnsureSymbolReady(_Symbol))
   {
      ChartStatus("Symbol not ready");
      return;
   }
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double spreadPts = (point > 0) ? (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / point : 0;
   // #region agent log
   if(tickCount <= 5 || (tickCount % 100 == 0))
      DebugLog("OnTick:spread", "check", "C", "spreadPts", DoubleToString(spreadPts, 1) + " limit=" + DoubleToString(SpreadLimitPoints, 0));
   // #endregion
   if(!SpreadOK(_Symbol))
   {
      ChartStatus("Spread too high: " + DoubleToString(spreadPts, 0) + " pts (max " + IntegerToString((int)SpreadLimitPoints) + ")");
      return;
   }
   
   UpdateSpreadHistory(_Symbol);

   double atr = GetATR();
   // #region agent log
   if(tickCount <= 5 || (tickCount % 100 == 0))
      DebugLog("OnTick:atr", "get", "D", "atr", DoubleToString(atr, 5));
   // #endregion
   if(atr <= 0.0)
   {
      ChartStatus("ATR not ready");
      return;
   }

   // Tick Velocity Filter: spike if price moves > ATR threshold in 500ms (scales per instrument)
   if(TickVelocitySpikeATR > 0 && atr > 0)
   {
      double mid = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
      ulong now = GetTickCount64();
      if(tickVelTime > 0 && (now - tickVelTime) >= 500)
      {
         double changePrice = MathAbs(mid - tickVelPrice);
         if(changePrice >= atr * TickVelocitySpikeATR)
         {
            ChartStatus("TICK VELOCITY SPIKE! " + DoubleToString(changePrice, 5) + " in 500ms - closing");
            Print("Tick Velocity Spike! ", DoubleToString(changePrice, 5), " (", DoubleToString(TickVelocitySpikeATR, 1), " ATR) in 500ms - closing");
            CloseBasket(_Symbol);
            return;
         }
         tickVelPrice = mid;
         tickVelTime = now;
      }
      else if(tickVelTime == 0)
      {
         tickVelPrice = mid;
         tickVelTime = now;
      }
   }

   int totalTrades = PositionsCount(_Symbol) + PendingOrdersCount(_Symbol);
   
   // Manage exits - check basket profit and close all trades if target reached
   ManageExits(_Symbol, atr);
   
   // Recalculate after exits
   totalTrades = PositionsCount(_Symbol) + PendingOrdersCount(_Symbol);
   int maxTrades = MathMax(MinTotalTrades, MathMin(20, MaxTotalTrades));
   
   // Check trade limit
   int maxForMode = UseLimitOrders ? (MarketOrdersAtExecution + LimitOrderCount) : maxTrades;
   if(totalTrades >= maxForMode)
   {
      ChartStatus("Max trades: " + IntegerToString(totalTrades) + "/" + IntegerToString(maxForMode) + "\nSpread: " + DoubleToString(spreadPts, 0) + " pts");
      return;
   }
   
   // Momentum Breakout Entry - Simple and effective for scalping
   int entryDirection = DetectMomentumBreakout(_Symbol, atr);
   // #region agent log
   if(tickCount <= 5 || (tickCount % 100 == 0) || entryDirection != 0)
      DebugLog("OnTick:entryDir", "momentum", "E", "entryDirection", IntegerToString(entryDirection));
   // #endregion
   
   // Log momentum status periodically
   static datetime lastMomentumLog = 0;
   if(TimeCurrent() - lastMomentumLog > 30) // Log every 30 seconds
   {
      if(entryDirection != 0)
      {
         double close[];
         ArraySetAsSeries(close, true);
         if(CopyClose(_Symbol, MomentumTF, 0, MomentumLookback + 1, close) >= MomentumLookback + 1)
         {
            double momentum = close[0] - close[MomentumLookback];
            double threshold = atr * MomentumThresholdATR;
            Print("Momentum Breakout detected: ", (entryDirection > 0 ? "BUY" : "SELL"),
                  " | Momentum: ", DoubleToString(momentum, 5),
                  " | Threshold: ", DoubleToString(threshold, 5));
         }
      }
      else
      {
         Print("Waiting for momentum breakout signal...");
      }
      lastMomentumLog = TimeCurrent();
   }
   
   // Open trade if momentum breakout detected (1 trade per tick - staggered entry)
   if(entryDirection != 0)
   {
      int posCount = PositionsCount(_Symbol);
      int pendingCount = PendingOrdersCount(_Symbol);
      
      // Cancel pendings on direction change (after min hold) or timeout (not filled)
      if(pendingCount > 0)
      {
         int pendingDir = GetPendingOrdersDirection(_Symbol);
         datetime oldestPending = GetOldestPendingOrderTime(_Symbol);
         int pendingAgeSec = (int)(TimeCurrent() - oldestPending);
         bool cancelOnDirection = (pendingDir != 0 && entryDirection != pendingDir && pendingAgeSec >= MinPendingHoldSeconds);
         bool cancelOnTimeout = (pendingAgeSec >= PendingOrderTimeoutSeconds);
         if(cancelOnDirection || cancelOnTimeout)
         {
            DeletePendingOrdersOnly(_Symbol);
            ChartStatus("Cancelled pendings (direction/timeout)\nSpread: " + DoubleToString(spreadPts, 0) + " pts");
            return;
         }
      }
      
      if(totalTrades >= maxForMode)
      {
         ChartStatus("Max trades: " + IntegerToString(totalTrades) + "/" + IntegerToString(maxForMode) + "\nSpread: " + DoubleToString(spreadPts, 0) + " pts");
         return;
      }
      
      // Institutional timing: only trade 07:00-20:00 broker time
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int hour = dt.hour;
      if(hour < TradingStartHour || hour >= TradingEndHour)
      {
         ChartStatus("Outside hours: " + IntegerToString(hour) + ":00 (trade " + IntegerToString(TradingStartHour) + "-" + IntegerToString(TradingEndHour) + ")\nSignal: " + (entryDirection > 0 ? "BUY" : "SELL") + " | Spread: " + DoubleToString(spreadPts, 0) + " pts");
         return;
      }
      
      bool opened = false;
      if(UseLimitOrders)
      {
         // Markets first (1 per tick), then limits (1 per tick)
         if(posCount < MarketOrdersAtExecution)
         {
            opened = OpenMarket(_Symbol, entryDirection, atr);
         }
         else if(pendingCount < LimitOrderCount)
         {
            opened = PlaceSingleLimitOrder(_Symbol, entryDirection, atr);
         }
      }
      else
      {
         opened = OpenMarket(_Symbol, entryDirection, atr);
      }
      
      if(opened)
      {
         lastTradeOpenTime = TimeCurrent();
         lastEntryTime = TimeCurrent();
         Print("✓ Staggered entry: 1 trade opened | Total: ", (posCount + pendingCount + 1), "/", maxForMode);
         ChartStatus("Opened " + (entryDirection > 0 ? "BUY" : "SELL") + " | Total: " + IntegerToString(posCount + pendingCount + 1) + "/" + IntegerToString(maxForMode) + "\nSpread: " + DoubleToString(spreadPts, 0) + " pts");
      }
      else
         ChartStatus("Failed to open " + (entryDirection > 0 ? "BUY" : "SELL") + " (check logs)\nSpread: " + DoubleToString(spreadPts, 0) + " pts");
   }
   else
      ChartStatus("Waiting for signal\nSpread: " + DoubleToString(spreadPts, 0) + " pts | Trades: " + IntegerToString(totalTrades) + "/" + IntegerToString(maxForMode));
}

// Safety: clean up dangling pendings on stop
void OnTesterDeinit()
{
   CloseBasket(_Symbol);
}











