//+------------------------------------------------------------------+
//|                                                  FlipperMT5.mq5 |
//|                                  High-Leverage Flipper EA for MT5 |
//|                        Dynamic Full-Margin Trading with Momentum |
//+------------------------------------------------------------------+
#property copyright "Flipper MT5 EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

// ===== Input Parameters =====
input group "===== Profit Target ====="
input double   TargetPercent      = 20.0;     // Target profit as % of balance (scales with account growth)

input group "===== Risk Protection ====="
input double   MaxDrawdownPercent = 15.0;     // Close all if drawdown exceeds this % (equity protector)

input group "===== Lot Size & Basket Trading ====="
input double   FixedLotSize       = 0.03;     // Fixed lot size per trade
input double   CapitalPerPosition = 1000.0;   // Capital required per additional position (e.g., $1000 per 0.03 lot)
input int      MaxBasketPositions = 10;       // Maximum number of simultaneous positions
input double   MarginSafetyBuffer = 0.80;     // Safety buffer for margin (80% of available margin)

input group "===== Execution Settings ====="
input int      SlippageBuffer     = 30;       // Slippage in points for fast exits
input int      MagicNumber        = 888888;   // Magic number for trade identification
input int      HardStopLoss       = 50;       // Hard stop loss in pips (50 pips = 500 points)

input group "===== Dynamic Trailing Profit ====="
input int      MinProfitPips      = 10;       // Minimum profit (pips) before trailing activates
input int      MaxProfitPips      = 100;      // Maximum profit target (pips) - auto close
input int      ProfitDecayPips    = 3;        // Close if profit decays by this many pips from peak
input int      MaxDecayPips       = 5;        // Maximum allowed decay before force close

input group "===== Momentum Entry Settings ====="
input int      MomentumPeriod     = 14;       // Period for momentum indicator
input ENUM_TIMEFRAMES MomentumTimeframe = PERIOD_M1; // Timeframe for momentum (M1)

input group "===== Volatility Filter (ATR) ====="
input bool     UseATRFilter      = true;     // Enable ATR volatility filter
input int      ATRPeriod         = 14;       // ATR period for volatility calculation
input double   ATRMultiplier      = 1.5;      // Minimum spike must be >= ATR * multiplier

// ===== Global Variables =====
CTrade trade;
int momentumHandle;
int atrHandle;
double momentumBuffer[];
double momentumBufferPrev[];
double peakProfitPips = 0;           // Track highest profit achieved in pips
bool trailingActive = false;         // Flag to indicate trailing is active
double pointValue;                   // Store point value for pip calculation

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Set magic number
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippageBuffer);
   trade.SetTypeFilling(ORDER_FILLING_IOC); // Immediate or Cancel - allows partial fills, more reliable
   
   // Initialize momentum indicator
   momentumHandle = iMomentum(_Symbol, MomentumTimeframe, MomentumPeriod, PRICE_CLOSE);
   if(momentumHandle == INVALID_HANDLE)
   {
      Print("Error creating momentum indicator: ", GetLastError());
      return(INIT_FAILED);
   }
   
   // Initialize ATR indicator for volatility filter
   if(UseATRFilter)
   {
      atrHandle = iATR(_Symbol, MomentumTimeframe, ATRPeriod);
      if(atrHandle == INVALID_HANDLE)
      {
         Print("Error creating ATR indicator: ", GetLastError());
         return(INIT_FAILED);
      }
   }
   else
   {
      atrHandle = INVALID_HANDLE;
   }
   
   // Set indicator as series
   ArraySetAsSeries(momentumBuffer, true);
   ArraySetAsSeries(momentumBufferPrev, true);
   
   // Initialize pip calculation variables
   pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // For 3-digit and 5-digit brokers, adjust pip calculation
   int symbolDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(symbolDigits == 3 || symbolDigits == 5)
      pointValue = pointValue * 10;
   
   // Reset tracking variables
   peakProfitPips = 0;
   trailingActive = false;
   
   Print("FlipperMT5 EA initialized successfully");
   Print("Target Profit: ", TargetPercent, "% of balance (dynamic)");
   Print("Max Drawdown Protection: ", MaxDrawdownPercent, "%");
   Print("Fixed Lot Size: ", FixedLotSize, " per position");
   Print("Basket Trading: Capital per position=$", CapitalPerPosition, " Max positions=", MaxBasketPositions);
   Print("Margin Safety Buffer: ", MarginSafetyBuffer * 100, "%");
   Print("Hard Stop Loss: ", HardStopLoss, " pips");
   Print("Trailing Profit: Min=", MinProfitPips, " Max=", MaxProfitPips, " Decay=", ProfitDecayPips, "-", MaxDecayPips, " pips");
   Print("ATR Filter: ", (UseATRFilter ? "Enabled" : "Disabled"));
   
   // Display initial position capacity
   double initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   int initialCapacity = CalculateAllowedPositions(initialBalance);
   Print("Initial balance: $", initialBalance, " -> Allowed positions: ", initialCapacity);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicator handles
   if(momentumHandle != INVALID_HANDLE)
      IndicatorRelease(momentumHandle);
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // ===== EQUITY PROTECTOR: Check for excessive drawdown =====
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdownPercent = 0;
   
   if(balance > 0)
   {
      drawdownPercent = ((balance - equity) / balance) * 100.0;
      
      if(drawdownPercent >= MaxDrawdownPercent)
      {
         Print("EQUITY PROTECTOR TRIGGERED: Drawdown=", drawdownPercent, "% >= ", MaxDrawdownPercent, "%");
         Print("Balance: $", balance, " Equity: $", equity);
         CloseAllPositions();
         return; // Exit immediately to prevent margin call
      }
   }
   
   // ===== MODULE 3: Global Basket Management (The "Grab") - Dynamic Target =====
   double accountProfit = AccountInfoDouble(ACCOUNT_PROFIT);
   double dynamicTarget = balance * (TargetPercent / 100.0);
   
   if(accountProfit >= dynamicTarget && dynamicTarget > 0)
   {
      Print("Target profit reached: $", accountProfit, " >= $", dynamicTarget, " (", TargetPercent, "% of balance)");
      CloseAllPositions();
      return; // Exit immediately after closing
   }
   
   // ===== DYNAMIC TRAILING PROFIT MANAGEMENT =====
   int ownPositions = GetOwnPositionsCount();
   if(ownPositions > 0)
   {
      // Check trailing stop conditions
      CheckTrailingProfit();
   }
   else
   {
      // Reset tracking when no positions
      peakProfitPips = 0;
      trailingActive = false;
   }
   
   // ===== MODULE 2: Momentum Decay Entry (Basket Trading Enabled) =====
   // Get momentum values for signal detection
   if(CopyBuffer(momentumHandle, 0, 0, 3, momentumBuffer) <= 0)
   {
      Print("Error copying momentum buffer: ", GetLastError());
      return;
   }
   
   // Copy previous values for comparison
   ArrayCopy(momentumBufferPrev, momentumBuffer, 0, 1, 2);
   
   // Check for momentum exhaustion signal with volatility filter
   int signal = IsMomentumExhausted();
   
   // Get current positions count for this EA
   int currentPositions = GetOwnPositionsCount();
   int allowedPositions = CalculateAllowedPositions(balance);
   
   // Only enter if we have signal and haven't reached max basket size
   if(signal > 0 && currentPositions < allowedPositions && currentPositions < MaxBasketPositions)
   {
      // Check if we have enough margin for another position
      if(CanOpenNewPosition())
      {
         if(signal == 1) // Buy signal: Price spiking down, momentum rising (exhaustion)
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double stopLoss = ask - (HardStopLoss * pointValue);
            
            // Normalize stop loss to tick size
            double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
            stopLoss = MathFloor(stopLoss / tickSize) * tickSize;
            
            if(trade.Buy(FixedLotSize, _Symbol, ask, stopLoss, 0, "Flipper Buy"))
            {
               Print("BUY order opened: Lot=", FixedLotSize, " Price=", ask, " StopLoss=", stopLoss, 
                     " Positions=", (currentPositions + 1), "/", allowedPositions,
                     " Margin Used=", AccountInfoDouble(ACCOUNT_MARGIN));
               // Reset trailing only if this is the first position
               if(currentPositions == 0)
               {
                  peakProfitPips = 0;
                  trailingActive = false;
               }
            }
            else
            {
               Print("BUY order failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
            }
         }
         else if(signal == 2) // Sell signal: Price spiking up, momentum dropping (exhaustion)
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double stopLoss = bid + (HardStopLoss * pointValue);
            
            // Normalize stop loss to tick size
            double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
            stopLoss = MathCeil(stopLoss / tickSize) * tickSize;
            
            if(trade.Sell(FixedLotSize, _Symbol, bid, stopLoss, 0, "Flipper Sell"))
            {
               Print("SELL order opened: Lot=", FixedLotSize, " Price=", bid, " StopLoss=", stopLoss, 
                     " Positions=", (currentPositions + 1), "/", allowedPositions,
                     " Margin Used=", AccountInfoDouble(ACCOUNT_MARGIN));
               // Reset trailing only if this is the first position
               if(currentPositions == 0)
               {
                  peakProfitPips = 0;
                  trailingActive = false;
               }
            }
            else
            {
               Print("SELL order failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get count of positions opened by this EA                         |
//+------------------------------------------------------------------+
int GetOwnPositionsCount()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Collect EA-owned position tickets into array                     |
//| filter: WRONG_VALUE/-1 = all, POSITION_TYPE_BUY = buys only,     |
//|         POSITION_TYPE_SELL = sells only. Returns count.          |
//+------------------------------------------------------------------+
int CollectOwnTickets(ulong &tickets[], ENUM_POSITION_TYPE filter = (ENUM_POSITION_TYPE)-1)
{
   ArrayResize(tickets, 0);
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(filter >= 0 && type != filter) continue;
      ArrayResize(tickets, n + 1);
      tickets[n++] = ticket;
   }
   return n;
}

//+------------------------------------------------------------------+
//| Calculate allowed number of positions based on capital           |
//+------------------------------------------------------------------+
int CalculateAllowedPositions(double accountBalance)
{
   // Calculate based on capital per position
   int positionsByCapital = (int)MathFloor(accountBalance / CapitalPerPosition);
   
   // Ensure at least 1 position is allowed if balance > 0
   if(positionsByCapital < 1 && accountBalance > 0)
      positionsByCapital = 1;
   
   // Don't exceed maximum
   if(positionsByCapital > MaxBasketPositions)
      positionsByCapital = MaxBasketPositions;
   
   return positionsByCapital;
}

//+------------------------------------------------------------------+
//| Check if we can open a new position based on margin             |
//+------------------------------------------------------------------+
bool CanOpenNewPosition()
{
   // Get free margin
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin <= 0)
   {
      Print("Error: No free margin available");
      return false;
   }
   
   // Calculate margin required for one position with fixed lot
   double onePositionMargin = 0;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, FixedLotSize, ask, onePositionMargin))
   {
      Print("Error calculating margin: ", GetLastError());
      return false;
   }
   
   // Check if we have enough margin with safety buffer
   double availableMargin = freeMargin * MarginSafetyBuffer;
   
   if(onePositionMargin > availableMargin)
   {
      Print("Insufficient margin: Required=", onePositionMargin, " Available=", availableMargin);
      return false;
   }
   
   // Validate fixed lot size
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(FixedLotSize < minLot || FixedLotSize > maxLot)
   {
      Print("Fixed lot size (", FixedLotSize, ") is outside broker limits: Min=", minLot, " Max=", maxLot);
      return false;
   }
   
   // Normalize lot size to broker's step
   double normalizedLot = MathFloor(FixedLotSize / lotStep) * lotStep;
   if(normalizedLot != FixedLotSize)
   {
      Print("Warning: Fixed lot size should be normalized to broker step (", lotStep, ")");
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| MODULE 2: Momentum Decay Entry Logic                            |
//| Returns: 0 = No signal, 1 = Buy, 2 = Sell                       |
//+------------------------------------------------------------------+
int IsMomentumExhausted()
{
   // Need at least 3 bars for comparison
   if(ArraySize(momentumBuffer) < 3)
      return 0;
   
   // Get current price movement using MQL5 CopyClose
   double closePrices[];
   ArraySetAsSeries(closePrices, true);
   if(CopyClose(_Symbol, MomentumTimeframe, 0, 3, closePrices) <= 0)
   {
      Print("Error copying close prices: ", GetLastError());
      return 0;
   }
   
   double priceCurrent = closePrices[0];
   double pricePrev = closePrices[1];
   double pricePrev2 = closePrices[2];
   
   // Calculate price velocity (spike detection)
   double priceChange1 = priceCurrent - pricePrev;
   double priceChange2 = pricePrev - pricePrev2;
   
   // ===== ATR VOLATILITY FILTER: Only enter on significant moves =====
   if(UseATRFilter && atrHandle != INVALID_HANDLE)
   {
      double atrBuffer[];
      ArraySetAsSeries(atrBuffer, true);
      if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) <= 0)
      {
         Print("Error copying ATR buffer: ", GetLastError());
         return 0;
      }
      
      double currentATR = atrBuffer[0];
      double minSpikeSize = currentATR * ATRMultiplier;
      
      // Calculate absolute price movement
      double absPriceChange1 = MathAbs(priceChange1);
      double absPriceChange2 = MathAbs(priceChange2);
      
      // Both price changes must exceed minimum spike size
      if(absPriceChange1 < minSpikeSize || absPriceChange2 < minSpikeSize)
      {
         // Spike too small - filtered out by volatility
         return 0;
      }
   }
   
   // Get momentum values
   double momentumCurrent = momentumBuffer[0];
   double momentumPrev = momentumBuffer[1];
   double momentumPrev2 = momentumBuffer[2];
   
   // Calculate momentum change
   double momentumChange1 = momentumCurrent - momentumPrev;
   double momentumChange2 = momentumPrev - momentumPrev2;
   
   // SELL Signal: Price spiking UP but momentum starting to drop (exhaustion)
   // Price is rising (positive change) but momentum is declining (negative change)
   if(priceChange1 > 0 && priceChange2 > 0) // Price spiking up
   {
      // Enhanced condition: Momentum must be strong initially, then show clear exhaustion
      bool momentumWasStrong = momentumPrev2 > 100.0 || momentumPrev > 100.0; // Above baseline
      bool momentumDeclining = momentumChange1 < 0 && momentumPrev > momentumPrev2; // Momentum curling back down
      bool strongDeceleration = MathAbs(momentumChange1) > MathAbs(momentumChange2) * 0.5; // Accelerating decline
      
      if(momentumDeclining && (momentumWasStrong || strongDeceleration))
      {
         Print("SELL Signal: Price spike up, momentum exhaustion detected");
         Print("  Price: ", pricePrev2, " -> ", pricePrev, " -> ", priceCurrent);
         Print("  Momentum: ", momentumPrev2, " -> ", momentumPrev, " -> ", momentumCurrent);
         Print("  Momentum Change: ", momentumChange2, " -> ", momentumChange1);
         return 2;
      }
   }
   
   // BUY Signal: Price spiking DOWN but momentum starting to rise (exhaustion)
   // Price is falling (negative change) but momentum is rising (positive change)
   if(priceChange1 < 0 && priceChange2 < 0) // Price spiking down
   {
      // Enhanced condition: Momentum must be strong initially, then show clear exhaustion
      bool momentumWasStrong = momentumPrev2 > 100.0 || momentumPrev > 100.0; // Above baseline
      bool momentumRising = momentumChange1 > 0 && momentumPrev < momentumPrev2; // Momentum curling back up
      bool strongAcceleration = MathAbs(momentumChange1) > MathAbs(momentumChange2) * 0.5; // Accelerating rise
      
      if(momentumRising && (momentumWasStrong || strongAcceleration))
      {
         Print("BUY Signal: Price spike down, momentum exhaustion detected");
         Print("  Price: ", pricePrev2, " -> ", pricePrev, " -> ", priceCurrent);
         Print("  Momentum: ", momentumPrev2, " -> ", momentumPrev, " -> ", momentumCurrent);
         Print("  Momentum Change: ", momentumChange2, " -> ", momentumChange1);
         return 1;
      }
   }
   
   return 0; // No signal
}

//+------------------------------------------------------------------+
//| Calculate current profit in pips for all positions              |
//+------------------------------------------------------------------+
double CalculateProfitInPips()
{
   double totalProfitPips = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         string symbol = PositionGetString(POSITION_SYMBOL);
         long magic = PositionGetInteger(POSITION_MAGIC);
         
         // Only count positions for this EA and symbol
         if(symbol != _Symbol || magic != MagicNumber)
            continue;
            
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = (type == POSITION_TYPE_BUY) ? 
                              SymbolInfoDouble(symbol, SYMBOL_BID) : 
                              SymbolInfoDouble(symbol, SYMBOL_ASK);
         
         double priceDiff = 0;
         if(type == POSITION_TYPE_BUY)
            priceDiff = currentPrice - openPrice;
         else
            priceDiff = openPrice - currentPrice;
         
         // Convert to pips
         double pipValue = pointValue;
         double profitInPips = priceDiff / pipValue;
         
         totalProfitPips += profitInPips;
      }
   }
   
   return totalProfitPips;
}

//+------------------------------------------------------------------+
//| Check trailing profit conditions and close if decay detected    |
//+------------------------------------------------------------------+
void CheckTrailingProfit()
{
   double currentProfitPips = CalculateProfitInPips();
   
   // Update peak profit if current profit is higher
   if(currentProfitPips > peakProfitPips)
   {
      peakProfitPips = currentProfitPips;
      
      // Activate trailing once we reach minimum profit threshold
      if(peakProfitPips >= MinProfitPips && !trailingActive)
      {
         trailingActive = true;
         Print("Trailing profit activated at ", peakProfitPips, " pips");
      }
   }
   
   // If trailing is active, check for decay
   if(trailingActive && peakProfitPips >= MinProfitPips)
   {
      double profitDecay = peakProfitPips - currentProfitPips;
      
      // Close if profit exceeds maximum target
      if(currentProfitPips >= MaxProfitPips)
      {
         Print("Maximum profit target reached: ", currentProfitPips, " pips >= ", MaxProfitPips, " pips");
         CloseAllPositions();
         return;
      }
      
      // Force close if decay exceeds maximum allowed (safety catch)
      if(profitDecay > MaxDecayPips)
      {
         Print("CRITICAL: Profit decay exceeded maximum: Peak=", peakProfitPips, 
               " Current=", currentProfitPips, " Decay=", profitDecay, " pips");
         CloseAllPositions();
         return;
      }
      
      // Close if profit decays by minimum threshold (3 pips or more)
      if(profitDecay >= ProfitDecayPips)
      {
         Print("Profit decay detected: Peak=", peakProfitPips, " Current=", currentProfitPips, 
               " Decay=", profitDecay, " pips (threshold: ", ProfitDecayPips, " pips)");
         Print("Closing all positions to lock in profit");
         CloseAllPositions();
         return;
      }
      
      // Only close if we're still above minimum threshold
      if(currentProfitPips < MinProfitPips)
      {
         Print("Profit dropped below minimum threshold: ", currentProfitPips, " < ", MinProfitPips, " pips");
         CloseAllPositions();
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Bulk close positions by filter (internal)                        |
//+------------------------------------------------------------------+
void BulkClosePositions(ENUM_POSITION_TYPE filter = (ENUM_POSITION_TYPE)-1)
{
   ulong tickets[];
   int n = CollectOwnTickets(tickets, filter);
   if(n == 0) return;
   
   trade.SetDeviationInPoints(SlippageBuffer);
   trade.SetAsyncMode(true);
   for(int i = 0; i < n; i++)
      trade.PositionClose(tickets[i], SlippageBuffer);
   trade.SetAsyncMode(false);
   
   // Retry pass for any remaining
   Sleep(50);
   n = CollectOwnTickets(tickets, filter);
   if(n > 0)
   {
      trade.SetAsyncMode(true);
      for(int i = 0; i < n; i++)
         trade.PositionClose(tickets[i], SlippageBuffer);
      trade.SetAsyncMode(false);
   }
}

//+------------------------------------------------------------------+
//| MODULE 3: Close All Positions (High-Speed Exit)                 |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   int ownPositionsCount = GetOwnPositionsCount();
   if(ownPositionsCount == 0) return;
   
   Print("Closing all ", ownPositionsCount, " EA positions...");
   BulkClosePositions((ENUM_POSITION_TYPE)-1);
   
   int remaining = GetOwnPositionsCount();
   if(remaining > 0)
   {
      Print("WARNING: ", remaining, " EA positions still open after bulk close. Manual intervention may be required");
   }
   else
   {
      double finalProfit = AccountInfoDouble(ACCOUNT_PROFIT);
      double finalBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      Print("All EA positions closed successfully. Final profit: $", finalProfit, " Balance: $", finalBalance);
   }
}

//+------------------------------------------------------------------+
//| Close all BUY positions owned by this EA                         |
//+------------------------------------------------------------------+
void CloseAllBuys()
{
   ulong tickets[];
   int n = CollectOwnTickets(tickets, POSITION_TYPE_BUY);
   if(n == 0) return;
   Print("Closing ", n, " EA BUY positions...");
   trade.SetDeviationInPoints(SlippageBuffer);
   trade.SetAsyncMode(true);
   for(int i = 0; i < n; i++)
      trade.PositionClose(tickets[i], SlippageBuffer);
   trade.SetAsyncMode(false);
}

//+------------------------------------------------------------------+
//| Close all SELL positions owned by this EA                        |
//+------------------------------------------------------------------+
void CloseAllSells()
{
   ulong tickets[];
   int n = CollectOwnTickets(tickets, POSITION_TYPE_SELL);
   if(n == 0) return;
   Print("Closing ", n, " EA SELL positions...");
   trade.SetDeviationInPoints(SlippageBuffer);
   trade.SetAsyncMode(true);
   for(int i = 0; i < n; i++)
      trade.PositionClose(tickets[i], SlippageBuffer);
   trade.SetAsyncMode(false);
}

//+------------------------------------------------------------------+
//| Modify SL and/or TP on all EA positions. Use 0 to keep current.  |
//+------------------------------------------------------------------+
int BulkModifySLTP(double newSL = 0, double newTP = 0)
{
   ulong tickets[];
   int n = CollectOwnTickets(tickets, (ENUM_POSITION_TYPE)-1);
   int modified = 0;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   for(int i = 0; i < n; i++)
   {
      if(!PositionSelectByTicket(tickets[i])) continue;
      double sl = (newSL != 0) ? NormalizeDouble(newSL, digits) : PositionGetDouble(POSITION_SL);
      double tp = (newTP != 0) ? NormalizeDouble(newTP, digits) : PositionGetDouble(POSITION_TP);
      if(trade.PositionModify(tickets[i], sl, tp))
         modified++;
      else
         Print("BulkModifySLTP failed ticket=", tickets[i], " err=", trade.ResultRetcode());
   }
   if(modified > 0)
      Print("BulkModifySLTP: ", modified, "/", n, " positions modified");
   return modified;
}

//+------------------------------------------------------------------+

