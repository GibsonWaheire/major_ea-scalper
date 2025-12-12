// DynamicXauBasketMT5.mq5
// Momentum Breakout EA - Maximum 5 trades, basket profit management
#property copyright "Dynamic XAU Momentum Breakout EA"
#property link      "local"
#property version   "3.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

// --- Inputs ---
input string   TradeSymbol           = "XAUUSD";
input int      MagicNumber           = 905533;
input double   RiskMarginPercent     = 95.0;   // % of free margin to deploy
input int      MaxTotalTrades        = 5;      // Maximum total trades (including existing)
input int      ATRPeriod             = 14;
input ENUM_TIMEFRAMES MomentumTF     = PERIOD_M1; // Momentum timeframe (M1 for scalping)
input ENUM_TIMEFRAMES ATRTimeframe   = PERIOD_M1;
input double   MomentumThresholdATR  = 0.15;   // Minimum momentum to trigger breakout entry (ATR fraction)
input int      MomentumLookback      = 2;      // Number of candles to look back for momentum
input bool     RequireVolumeConfirmation = false; // Require volume confirmation for breakout
input int      DeviationPoints       = 30;     // Slippage guard
input double   SpreadLimitPoints     = 900;    // Skip trading if spread too wide

// --- Stop Loss Settings ---
input bool     UseStopLoss           = true;   // Enable stop loss
input double   StopLossPointsXAU     = 200.0;  // Stop loss in points for XAUUSD
input double   StopLossPointsOther   = 20.0;   // Stop loss in points for other instruments

// --- Basket Profit Settings ---
input bool     UseBasketProfit       = true;   // Close all trades when basket profit target reached
input double   BasketProfitATRMultiplier = 2.5; // Basket profit target as multiple of ATR
input double   BasketProfitPercent   = 2.0;    // Alternative: Basket profit as % of account balance
input bool     UsePercentForBasket   = false;  // If true use %, if false use ATR multiplier
input bool     IncludeAllTrades      = true;   // Include all trades (even pre-existing) in basket profit
input bool     CloseEarlyWhenProfitable = true; // Close basket early when profitable (even below target)
input double   EarlyCloseProfitATR   = 1.5;    // Close basket early at this ATR multiplier (if profitable)
input double   EarlyCloseProfitPercent = 1.0;  // Alternative: Close early at this % profit
input bool     UsePercentForEarlyClose = false; // If true use % for early close, if false use ATR

// --- Exit Settings ---
input bool     UseBreakEven          = true;   // Move stop loss to break-even when profitable
input double   BreakEvenTriggerATR   = 0.5;    // Move to BE when profit reaches this ATR
input bool     UseTrailingStop       = true;   // Use trailing stop to protect profits
input double   TrailingStopATR        = 1.0;    // Trailing stop distance in ATR
input double   TrailingStepATR       = 0.3;    // Trailing step in ATR

// --- Globals ---
CTrade         trade;
CPositionInfo  pos;
int            atrHandle     = -1;
bool           eaInitialized = false;
double         lastPrice     = 0.0;  // Track last price for momentum calculation

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------
bool EnsureSymbolReady(const string symbol)
{
   if(!SymbolSelect(symbol, true))
   {
      Print("Failed to select symbol ", symbol);
      return false;
   }
   if(SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("Symbol trading disabled: ", symbol);
      return false;
   }
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

// Detect Momentum Breakout - Simple and effective for scalping
int DetectMomentumBreakout(const string symbol, double atr)
{
   if(atr <= 0)
      return 0;
   
   double close[];
   long volume[];
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(volume, true);
   
   int lookback = MomentumLookback + 1;
   if(CopyClose(symbol, MomentumTF, 0, lookback, close) < lookback)
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
   return NormalizeDouble(lots, 2);
}

double CalcDynamicLot(const string symbol)
{
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double marginPerLot = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, symbol, 1.0, ask, marginPerLot) || marginPerLot <= 0)
   {
      Print("OrderCalcMargin failed, fallback to min lot");
      return NormalizeVolume(symbol, SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN));
   }
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double usable = freeMargin * (RiskMarginPercent / 100.0);
   double totalLots = usable / marginPerLot;
   
   // Split margin across maximum 5 trades
   double lotPerTrade = totalLots / (double)MaxTotalTrades;
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   
   // Ensure minimum viable lot size
   if(lotPerTrade < minLot)
      lotPerTrade = minLot;
   
   return NormalizeVolume(symbol, lotPerTrade);
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

// Calculate dynamic basket profit target
double CalculateBasketProfitTarget(const string symbol, double atr, double totalLots)
{
   if(!UseBasketProfit)
      return 0.0;
   
   double target = 0.0;
   
   if(UsePercentForBasket)
   {
      // Use percentage of account balance
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      target = balance * (BasketProfitPercent / 100.0);
   }
   else
   {
      // Use ATR-based calculation
      if(atr > 0 && totalLots > 0)
      {
         double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
         double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
         if(tickSize > 0)
         {
            double valuePerPoint = tickValue / tickSize;
            double atrTarget = atr * BasketProfitATRMultiplier;
            target = atrTarget * valuePerPoint * totalLots;
         }
      }
   }
   
   return MathMax(target, 1.0); // Minimum target of $1
}

datetime BasketOldestOpen(const string symbol)
{
   datetime oldest = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Magic() != MagicNumber) continue;
      if(pos.Symbol() != symbol) continue;
      datetime opentime = pos.Time();
      if(oldest == 0 || opentime < oldest)
         oldest = opentime;
   }
   return oldest;
}

// Removed - not used in new strategy

// Close all trades in basket (including pre-existing if IncludeAllTrades is true)
bool CloseBasket(const string symbol)
{
   bool ok = true;
   int closed = 0;
   int deleted = 0;
   
   // Close all market positions
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != symbol) continue;
      
      // Include all trades if enabled, otherwise only EA trades
      if(!IncludeAllTrades && pos.Magic() != MagicNumber)
         continue;
      
      ulong ticket = pos.Ticket();
      if(trade.PositionClose(ticket, DeviationPoints))
      {
         closed++;
      }
      else
      {
         ok = false;
         Print("Failed to close position ", ticket, ". Error: ", trade.ResultRetcode());
      }
   }
   
   // Delete all pending orders
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      
      // Include all orders if enabled, otherwise only EA orders
      if(!IncludeAllTrades && OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;
      
      ulong ticket = OrderGetInteger(ORDER_TICKET);
      if(trade.OrderDelete(ticket))
      {
         deleted++;
      }
      else
      {
         ok = false;
      }
   }
   
   if(closed > 0 || deleted > 0)
   {
      Print("Basket closed: ", closed, " positions and ", deleted, " orders closed/deleted for ", symbol);
      Print("All trades closed - profit booked.");
   }
   
   return ok;
}

double GetStopLossPrice(const string symbol, int direction)
{
   if(!UseStopLoss)
      return 0;
   
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double stopLossPoints = 0;
   
   // Determine stop loss based on symbol
   if(symbol == "XAUUSD" || symbol == "GOLD")
      stopLossPoints = StopLossPointsXAU;
   else
      stopLossPoints = StopLossPointsOther;
   
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
   // Check total trades limit
   int totalTrades = PositionsCount(symbol) + PendingOrdersCount(symbol);
   if(totalTrades >= MaxTotalTrades)
   {
      Print("Maximum trades limit reached: ", totalTrades, "/", MaxTotalTrades);
      return false;
   }
   
   double lot = CalcDynamicLot(symbol);
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
      double slPoints = (symbol == "XAUUSD" || symbol == "GOLD") ? StopLossPointsXAU : StopLossPointsOther;
      Print("Opened trade: ", (direction > 0 ? "BUY" : "SELL"), 
            " | Lot: ", DoubleToString(lot, 2),
            " | SL: ", DoubleToString(stopLoss, 5), " (", DoubleToString(slPoints, 1), " pts)",
            " | TP: NONE (Basket management only)");
   }
   else
      Print("Failed to open trade. Error: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   return result;
}

// PlacePendingOrders removed - not used in order block strategy

bool SpreadOK(const string symbol)
{
   double spread = (SymbolInfoDouble(symbol, SYMBOL_ASK) - SymbolInfoDouble(symbol, SYMBOL_BID)) / SymbolInfoDouble(symbol, SYMBOL_POINT);
   return spread <= SpreadLimitPoints;
}

// Basket Exit Management - Close all trades when basket profit target reached
void ManageExits(const string symbol, double atr)
{
   if(atr <= 0) return;
   
   // Calculate basket profit and target
   double basketProfit = BasketProfit(symbol);
   double totalLots = BasketLots(symbol);
   double profitTarget = CalculateBasketProfitTarget(symbol, atr, totalLots);
   
   // Check if basket profit target is reached (full target)
   if(UseBasketProfit && profitTarget > 0 && basketProfit >= profitTarget && basketProfit > 0)
   {
      Print("Basket profit target reached! Closing all trades.");
      Print("Basket Profit: ", DoubleToString(basketProfit, 2), 
            " | Target: ", DoubleToString(profitTarget, 2),
            " | Total Lots: ", DoubleToString(totalLots, 2));
      
      CloseBasket(symbol);
      return;
   }
   
   // Early close when profitable (even if below full target)
   if(CloseEarlyWhenProfitable && basketProfit > 0)
   {
      double earlyCloseTarget = 0.0;
      
      if(UsePercentForEarlyClose)
      {
         // Use percentage of account balance
         double balance = AccountInfoDouble(ACCOUNT_BALANCE);
         earlyCloseTarget = balance * (EarlyCloseProfitPercent / 100.0);
      }
      else
      {
         // Use ATR-based calculation
         if(atr > 0 && totalLots > 0)
         {
            double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
            double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
            if(tickSize > 0)
            {
               double valuePerPoint = tickValue / tickSize;
               double atrTarget = atr * EarlyCloseProfitATR;
               earlyCloseTarget = atrTarget * valuePerPoint * totalLots;
            }
         }
      }
      
      // Close basket if early profit target reached
      if(earlyCloseTarget > 0 && basketProfit >= earlyCloseTarget)
      {
         Print("Early basket close triggered! Basket is profitable.");
         Print("Basket Profit: ", DoubleToString(basketProfit, 2), 
               " | Early Close Target: ", DoubleToString(earlyCloseTarget, 2),
               " | Full Target: ", DoubleToString(profitTarget, 2),
               " | Total Lots: ", DoubleToString(totalLots, 2));
         
         CloseBasket(symbol);
         return;
      }
   }
   
   // Break-even protection and stop loss management
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double stopLossPoints = (symbol == "XAUUSD" || symbol == "GOLD") ? StopLossPointsXAU : StopLossPointsOther;
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
   if(!EnsureSymbolReady(TradeSymbol))
      return INIT_FAILED;
   
   // Close all existing trades when EA is activated
   CloseAllExistingTrades(TradeSymbol);
   
   // Initialize ATR
   atrHandle = iATR(TradeSymbol, ATRTimeframe, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ATR handle failed");
      return INIT_FAILED;
   }
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   
   // Test lot calculation
   double testLot = CalcDynamicLot(TradeSymbol);
   double minLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   
   Print("========================================");
   Print("Momentum Breakout EA initialized");
   Print("========================================");
   Print("Symbol: ", TradeSymbol);
   Print("Max Total Trades: ", MaxTotalTrades);
   string tfStr = (MomentumTF == PERIOD_M1) ? "M1 (Scalping)" : 
                  (MomentumTF == PERIOD_M5) ? "M5" :
                  (MomentumTF == PERIOD_M15) ? "M15" : "Custom";
   Print("Momentum Timeframe: ", tfStr);
   Print("Momentum Threshold: ", MomentumThresholdATR, "x ATR");
   Print("Momentum Lookback: ", MomentumLookback, " candles");
   Print("Volume Confirmation: ", (RequireVolumeConfirmation ? "ENABLED" : "DISABLED"));
   Print("Risk margin percent: ", RiskMarginPercent, "%");
   Print("Calculated lot per trade: ", DoubleToString(testLot, 2));
   Print("Minimum lot: ", DoubleToString(minLot, 2));
   Print("Free margin: ", DoubleToString(freeMargin, 2));
   Print("Stop Loss: ", (UseStopLoss ? "ENABLED" : "DISABLED"));
   if(UseStopLoss)
   {
      Print("  - XAUUSD Stop Loss: ", StopLossPointsXAU, " points");
      Print("  - Other instruments: ", StopLossPointsOther, " points");
   }
   Print("Trailing Stop: ", (UseTrailingStop ? "ENABLED" : "DISABLED"));
   if(UseTrailingStop)
   {
      Print("  - Trailing distance: ", TrailingStopATR, " ATR");
      Print("  - Trailing step: ", TrailingStepATR, " ATR");
   }
   Print("Strategy: MOMENTUM BREAKOUT - NO INDIVIDUAL TAKE PROFIT - Basket Management Only");
   Print("Basket Profit Management: ", (UseBasketProfit ? "ENABLED" : "DISABLED"));
   if(UseBasketProfit)
   {
      if(UsePercentForBasket)
         Print("  - Profit Target: ", BasketProfitPercent, "% of account balance");
      else
         Print("  - Profit Target: ", BasketProfitATRMultiplier, "x ATR");
      Print("  - Include All Trades: ", (IncludeAllTrades ? "YES" : "NO (EA trades only)"));
      if(CloseEarlyWhenProfitable)
      {
         if(UsePercentForEarlyClose)
            Print("  - Early Close: ", EarlyCloseProfitPercent, "% profit");
         else
            Print("  - Early Close: ", EarlyCloseProfitATR, "x ATR profit");
      }
   }
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
   
   if(testLot < minLot)
   {
      Print("WARNING: Calculated lot (", DoubleToString(testLot, 2), ") is less than minimum (", DoubleToString(minLot, 2), ")");
      Print("Consider increasing RiskMarginPercent");
   }
   
   eaInitialized = true;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   // Release indicator handles
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   Print("EA stopped. reason=", reason);
}

void OnTick()
{
   if(!EnsureSymbolReady(TradeSymbol))
      return;
   if(!SpreadOK(TradeSymbol))
      return;

   double atr = GetATR();
   if(atr <= 0.0)
      return;

   int totalTrades = PositionsCount(TradeSymbol) + PendingOrdersCount(TradeSymbol);
   
   // Manage exits - check basket profit and close all trades if target reached
   ManageExits(TradeSymbol, atr);
   
   // Recalculate after exits
   totalTrades = PositionsCount(TradeSymbol) + PendingOrdersCount(TradeSymbol);
   
   // Log basket profit status periodically
   static datetime lastBasketLog = 0;
   if(UseBasketProfit && TimeCurrent() - lastBasketLog > 60) // Log every minute
   {
      double basketProfit = BasketProfit(TradeSymbol);
      double totalLots = BasketLots(TradeSymbol);
      double profitTarget = CalculateBasketProfitTarget(TradeSymbol, atr, totalLots);
      
      if(totalTrades > 0)
      {
         Print("Basket Status: ", totalTrades, " trades | Profit: ", DoubleToString(basketProfit, 2), 
               " | Target: ", DoubleToString(profitTarget, 2),
               " | Progress: ", DoubleToString((basketProfit / profitTarget) * 100.0, 1), "%");
      }
      lastBasketLog = TimeCurrent();
   }
   
   // Check trade limit (max 5 total trades)
   if(totalTrades >= MaxTotalTrades)
      return;
   
   // Momentum Breakout Entry - Simple and effective for scalping
   int entryDirection = DetectMomentumBreakout(TradeSymbol, atr);
   
   // Log momentum status periodically
   static datetime lastMomentumLog = 0;
   if(TimeCurrent() - lastMomentumLog > 30) // Log every 30 seconds
   {
      if(entryDirection != 0)
      {
         double close[];
         ArraySetAsSeries(close, true);
         if(CopyClose(TradeSymbol, MomentumTF, 0, MomentumLookback + 1, close) >= MomentumLookback + 1)
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
   
   // Open trade if momentum breakout detected
   if(entryDirection != 0)
   {
      double currentPrice = (SymbolInfoDouble(TradeSymbol, SYMBOL_BID) + SymbolInfoDouble(TradeSymbol, SYMBOL_ASK)) / 2.0;
      Print("Momentum Breakout Entry Signal: ", (entryDirection > 0 ? "BUY" : "SELL"),
            " | Current Price: ", DoubleToString(currentPrice, 5),
            " | Total trades: ", totalTrades, "/", MaxTotalTrades);
      
      if(OpenMarket(TradeSymbol, entryDirection, atr))
      {
         Print("✓ Trade opened successfully from Momentum Breakout", 
               " | Direction: ", (entryDirection > 0 ? "BUY" : "SELL"),
               " | Total trades: ", totalTrades + 1, "/", MaxTotalTrades);
      }
      else
      {
         Print("✗ Failed to open trade. Check logs above for error details.");
      }
   }
}

// Safety: clean up dangling pendings on stop
void OnTesterDeinit()
{
   CloseBasket(TradeSymbol);
}











