# BurstRestScalper - Advanced Exit Strategies

## Current Exit Limitations

The EA currently only exits based on:
- Fixed profit target ($40)
- Max hold time (300 seconds)
- Recovery mode (1:3 then 1:4 R:R)

**Missing critical exits that could improve performance significantly.**

---

## 🎯 Recommended Exit Strategies (Priority Order)

### **1. Opposite Signal Exit** ⭐⭐⭐ (CRITICAL)
**Why:** If entry logic flips, the trade reason is gone. Close immediately.

**Implementation:**
```mql4
// Add to global variables
int lastAnalysisDirection = 0;  // Store previous analysis direction

// Add to input parameters
input bool     UseOppositeSignalExit = true;  // Close on opposite signal
input int      OppositeSignalConfirmation = 2; // Bars to confirm opposite signal

// Add function to CheckAndCloseBasket() before normal closing logic:
bool CheckOppositeSignalExit()
{
   if(!UseOppositeSignalExit || currentBasket.totalTrades == 0)
      return false;
   
   // Perform fresh analysis
   int currentDirection = GetCurrentAnalysisDirection();
   
   // Check if signal flipped
   if(currentBasket.basketDirection == 1 && currentDirection == -1)
   {
      // Was BUY, now SELL signal
      Print("OPPOSITE SIGNAL EXIT: BUY -> SELL");
      CloseEntireBasket("Opposite Signal: BUY->SELL | Profit: $" + 
                        DoubleToString(CalculateBasketProfit(), 2));
      return true;
   }
   else if(currentBasket.basketDirection == -1 && currentDirection == 1)
   {
      // Was SELL, now BUY signal
      Print("OPPOSITE SIGNAL EXIT: SELL -> BUY");
      CloseEntireBasket("Opposite Signal: SELL->BUY | Profit: $" + 
                        DoubleToString(CalculateBasketProfit(), 2));
      return true;
   }
   
   return false;
}

// Helper function to get current analysis direction without full analysis
int GetCurrentAnalysisDirection()
{
   double emaFast = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaSlow = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi = iRSI(Symbol(), PERIOD_M1, Analysis_RSI_Period, PRICE_CLOSE, 0);
   
   if(emaFast <= 0 || emaSlow <= 0 || rsi <= 0)
      return 0;
   
   int buyScore = 0;
   int sellScore = 0;
   
   if(emaFast > emaSlow)
      buyScore += 3;
   else if(emaFast < emaSlow)
      sellScore += 3;
   
   if(rsi > 50.0)
      buyScore += 2;
   else if(rsi < 50.0)
      sellScore += 2;
   
   if(buyScore > sellScore && buyScore >= 3)
      return 1;
   else if(sellScore > buyScore && sellScore >= 3)
      return -1;
   
   return 0;
}
```

**Add to CheckAndCloseBasket() after line 644:**
```mql4
// PRIORITY: Check opposite signal exit (before profit checks)
if(CheckOppositeSignalExit())
   return;
```

---

### **2. Indicator-Based Exit** ⭐⭐⭐ (CRITICAL)
**Why:** RSI/EMA crossbacks indicate momentum loss. Exit before reversal.

**Implementation:**
```mql4
// Add to input parameters
input bool     UseIndicatorExit = true;        // Use indicator-based exits
input bool     UseRSIExit = true;              // Exit on RSI crossback
input double   RSIExitThreshold = 50.0;        // RSI level for exit
input bool     UseEMAExit = true;             // Exit on EMA crossback
input bool     UseMomentumExit = true;        // Exit on momentum drop

// Add function:
bool CheckIndicatorBasedExit()
{
   if(!UseIndicatorExit || currentBasket.totalTrades == 0)
      return false;
   
   double rsi = iRSI(Symbol(), PERIOD_M1, Analysis_RSI_Period, PRICE_CLOSE, 0);
   double rsiPrev = iRSI(Symbol(), PERIOD_M1, Analysis_RSI_Period, PRICE_CLOSE, 1);
   double emaFast = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaSlow = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaFastPrev = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlowPrev = iMA(Symbol(), PERIOD_M1, Analysis_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 1);
   
   if(rsi <= 0 || emaFast <= 0 || emaSlow <= 0)
      return false;
   
   // RSI Exit: RSI crosses back through 50 (momentum loss)
   if(UseRSIExit)
   {
      if(currentBasket.basketDirection == 1)  // BUY position
      {
         // RSI was above threshold, now crossing below
         if(rsiPrev > RSIExitThreshold && rsi < RSIExitThreshold)
         {
            double basketProfit = CalculateBasketProfit();
            if(basketProfit > 0)  // Only exit if profitable
            {
               Print("RSI EXIT: RSI crossed below ", DoubleToString(RSIExitThreshold, 1));
               CloseEntireBasket("RSI Crossback Exit | Profit: $" + 
                                DoubleToString(basketProfit, 2));
               return true;
            }
         }
      }
      else if(currentBasket.basketDirection == -1)  // SELL position
      {
         // RSI was below threshold, now crossing above
         if(rsiPrev < (100.0 - RSIExitThreshold) && rsi > (100.0 - RSIExitThreshold))
         {
            double basketProfit = CalculateBasketProfit();
            if(basketProfit > 0)
            {
               Print("RSI EXIT: RSI crossed above ", DoubleToString(100.0 - RSIExitThreshold, 1));
               CloseEntireBasket("RSI Crossback Exit | Profit: $" + 
                                DoubleToString(basketProfit, 2));
               return true;
            }
         }
      }
   }
   
   // EMA Crossback Exit: EMAs cross opposite to position
   if(UseEMAExit)
   {
      if(currentBasket.basketDirection == 1)  // BUY position
      {
         // Fast EMA was above Slow, now crossing below
         if(emaFastPrev > emaSlowPrev && emaFast < emaSlow)
         {
            double basketProfit = CalculateBasketProfit();
            if(basketProfit > 0)
            {
               Print("EMA EXIT: Fast EMA crossed below Slow EMA");
               CloseEntireBasket("EMA Crossback Exit | Profit: $" + 
                                DoubleToString(basketProfit, 2));
               return true;
            }
         }
      }
      else if(currentBasket.basketDirection == -1)  // SELL position
      {
         // Fast EMA was below Slow, now crossing above
         if(emaFastPrev < emaSlowPrev && emaFast > emaSlow)
         {
            double basketProfit = CalculateBasketProfit();
            if(basketProfit > 0)
            {
               Print("EMA EXIT: Fast EMA crossed above Slow EMA");
               CloseEntireBasket("EMA Crossback Exit | Profit: $" + 
                                DoubleToString(basketProfit, 2));
               return true;
            }
         }
      }
   }
   
   // Momentum Drop Exit
   if(UseMomentumExit)
   {
      double close0 = iClose(Symbol(), PERIOD_M1, 0);
      double close1 = iClose(Symbol(), PERIOD_M1, 1);
      double close2 = iClose(Symbol(), PERIOD_M1, 2);
      
      if(currentBasket.basketDirection == 1)  // BUY position
      {
         // Momentum was up, now reversing
         if(close1 > close2 && close0 < close1)
         {
            double basketProfit = CalculateBasketProfit();
            if(basketProfit > 0)
            {
               Print("MOMENTUM EXIT: Price momentum reversed");
               CloseEntireBasket("Momentum Drop Exit | Profit: $" + 
                                DoubleToString(basketProfit, 2));
               return true;
            }
         }
      }
      else if(currentBasket.basketDirection == -1)  // SELL position
      {
         // Momentum was down, now reversing
         if(close1 < close2 && close0 > close1)
         {
            double basketProfit = CalculateBasketProfit();
            if(basketProfit > 0)
            {
               Print("MOMENTUM EXIT: Price momentum reversed");
               CloseEntireBasket("Momentum Drop Exit | Profit: $" + 
                                DoubleToString(basketProfit, 2));
               return true;
            }
         }
      }
   }
   
   return false;
}
```

**Add to CheckAndCloseBasket() after opposite signal check:**
```mql4
// Check indicator-based exits
if(CheckIndicatorBasedExit())
   return;
```

---

### **3. Break-Even Exit** ⭐⭐ (HIGH PRIORITY)
**Why:** Eliminates losses on good entries. Protects capital.

**Implementation:**
```mql4
// Add to input parameters
input bool     UseBreakEvenExit = true;        // Move SL to break-even
input double   BreakEvenTriggerPips = 10.0;   // Move SL after X pips profit
input double   BreakEvenOffsetPips = 2.0;     // SL offset from entry (spread protection)

// Add to BasketInfo structure:
// double breakEvenLevel;  // Break-even price level

// Add function to manage break-even stops:
void ManageBreakEvenStops()
{
   if(!UseBreakEvenExit || currentBasket.totalTrades == 0)
      return;
   
   double breakEvenTrigger = BreakEvenTriggerPips * pipToPoint;
   double breakEvenOffset = BreakEvenOffsetPips * pipToPoint;
   
   for(int i = 0; i < currentBasket.totalTrades; i++)
   {
      if(currentBasket.trades[i].ticket <= 0)
         continue;
      
      if(!OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET))
         continue;
      
      // Skip pending orders
      if(OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT || 
         OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
         continue;
      
      double entryPrice = OrderOpenPrice();
      double currentSL = OrderStopLoss();
      double currentPrice = (OrderType() == OP_BUY) ? Bid : Ask;
      double profitPips = 0.0;
      
      if(OrderType() == OP_BUY)
      {
         profitPips = (currentPrice - entryPrice) / pipToPoint;
         double breakEvenPrice = entryPrice + breakEvenOffset;
         
         // Check if profit reached trigger and SL not at break-even
         if(profitPips >= BreakEvenTriggerPips && 
            (currentSL == 0 || currentSL < breakEvenPrice))
         {
            if(OrderModify(currentBasket.trades[i].ticket, entryPrice, 
                          breakEvenPrice, OrderTakeProfit(), 0, clrBlue))
            {
               Print("BREAK-EVEN SET: Ticket=", currentBasket.trades[i].ticket, 
                     " | BE Price=", DoubleToString(breakEvenPrice, digits));
            }
         }
      }
      else if(OrderType() == OP_SELL)
      {
         profitPips = (entryPrice - currentPrice) / pipToPoint;
         double breakEvenPrice = entryPrice - breakEvenOffset;
         
         if(profitPips >= BreakEvenTriggerPips && 
            (currentSL == 0 || currentSL > breakEvenPrice))
         {
            if(OrderModify(currentBasket.trades[i].ticket, entryPrice, 
                          breakEvenPrice, OrderTakeProfit(), 0, clrBlue))
            {
               Print("BREAK-EVEN SET: Ticket=", currentBasket.trades[i].ticket, 
                     " | BE Price=", DoubleToString(breakEvenPrice, digits));
            }
         }
      }
   }
}
```

**Add to OnTick() after CheckAndCloseBasket():**
```mql4
// Manage break-even stops
ManageBreakEvenStops();
```

---

### **4. Profit Locking / Partial Close** ⭐⭐⭐ (CRITICAL)
**Why:** Lock profits early, let winners run. Best of both worlds.

**Implementation:**
```mql4
// Add to input parameters
input bool     UsePartialClose = true;        // Enable partial closes
input double   PartialClose1Pips = 15.0;     // Close 30% at X pips
input double   PartialClose1Percent = 30.0;   // % to close at first target
input double   PartialClose2Pips = 30.0;     // Close 30% at X pips
input double   PartialClose2Percent = 30.0;  // % to close at second target
input bool     UseTrailingAfterPartial = true; // Trail remaining position

// Add to BasketInfo structure:
// bool partialClose1Done;
// bool partialClose2Done;

// Add function:
void CheckPartialClose()
{
   if(!UsePartialClose || currentBasket.totalTrades == 0)
      return;
   
   // Don't partial close in recovery mode
   if(currentBasket.recoveryMode)
      return;
   
   double basketProfit = CalculateBasketProfit();
   if(basketProfit <= 0)
      return;
   
   // Calculate average entry price
   double totalLots = 0.0;
   double weightedEntry = 0.0;
   int activeTrades = 0;
   
   for(int i = 0; i < currentBasket.totalTrades; i++)
   {
      if(currentBasket.trades[i].ticket <= 0)
         continue;
      
      if(!OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET))
         continue;
      
      if(OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT || 
         OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
         continue;
      
      double lots = OrderLots();
      double entry = OrderOpenPrice();
      weightedEntry += entry * lots;
      totalLots += lots;
      activeTrades++;
   }
   
   if(totalLots <= 0 || activeTrades == 0)
      return;
   
   double avgEntry = weightedEntry / totalLots;
   double currentPrice = (currentBasket.basketDirection == 1) ? Bid : Ask;
   double profitPips = 0.0;
   
   if(currentBasket.basketDirection == 1)
      profitPips = (currentPrice - avgEntry) / pipToPoint;
   else
      profitPips = (avgEntry - currentPrice) / pipToPoint;
   
   // Partial Close 1
   if(!currentBasket.partialClose1Done && profitPips >= PartialClose1Pips)
   {
      int tradesToClose = (int)MathMax(1, MathFloor(activeTrades * (PartialClose1Percent / 100.0)));
      ClosePartialBasket(tradesToClose, "Partial Close 1: " + DoubleToString(profitPips, 1) + " pips");
      currentBasket.partialClose1Done = true;
   }
   
   // Partial Close 2
   if(!currentBasket.partialClose2Done && profitPips >= PartialClose2Pips)
   {
      int remainingTrades = CountActiveTrades();
      if(remainingTrades > 0)
      {
         int tradesToClose = (int)MathMax(1, MathFloor(remainingTrades * (PartialClose2Percent / 100.0)));
         ClosePartialBasket(tradesToClose, "Partial Close 2: " + DoubleToString(profitPips, 1) + " pips");
         currentBasket.partialClose2Done = true;
      }
   }
}

// Helper function to close partial basket
void ClosePartialBasket(int count, string reason)
{
   if(count <= 0)
      return;
   
   // Sort trades by profit (close most profitable first)
   struct TradeProfit
   {
      int ticket;
      double profit;
   };
   
   TradeProfit trades[];
   ArrayResize(trades, 0);
   
   for(int i = 0; i < currentBasket.totalTrades; i++)
   {
      if(currentBasket.trades[i].ticket <= 0)
         continue;
      
      if(!OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET))
         continue;
      
      if(OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT || 
         OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
         continue;
      
      int size = ArraySize(trades);
      ArrayResize(trades, size + 1);
      trades[size].ticket = currentBasket.trades[i].ticket;
      trades[size].profit = OrderProfit() + OrderSwap() + OrderCommission();
   }
   
   // Sort by profit (descending)
   for(int i = 0; i < ArraySize(trades) - 1; i++)
   {
      for(int j = i + 1; j < ArraySize(trades); j++)
      {
         if(trades[j].profit > trades[i].profit)
         {
            TradeProfit temp = trades[i];
            trades[i] = trades[j];
            trades[j] = temp;
         }
      }
   }
   
   // Close top N trades
   int closed = 0;
   for(int i = 0; i < MathMin(count, ArraySize(trades)); i++)
   {
      if(OrderSelect(trades[i].ticket, SELECT_BY_TICKET))
      {
         RefreshRates();
         double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;
         double lots = OrderLots();
         
         if(OrderClose(trades[i].ticket, lots, closePrice, 3, clrYellow))
         {
            closed++;
            RemoveBasketTradeByTicket(trades[i].ticket);
         }
      }
   }
   
   if(closed > 0)
      Print("PARTIAL CLOSE: ", reason, " | Closed ", closed, " trades");
}

int CountActiveTrades()
{
   int count = 0;
   for(int i = 0; i < currentBasket.totalTrades; i++)
   {
      if(currentBasket.trades[i].ticket <= 0)
         continue;
      
      if(OrderSelect(currentBasket.trades[i].ticket, SELECT_BY_TICKET))
      {
         if(OrderType() != OP_BUYLIMIT && OrderType() != OP_SELLLIMIT && 
            OrderType() != OP_BUYSTOP && OrderType() != OP_SELLSTOP)
            count++;
      }
   }
   return count;
}

void RemoveBasketTradeByTicket(int ticket)
{
   for(int i = 0; i < currentBasket.totalTrades; i++)
   {
      if(currentBasket.trades[i].ticket == ticket)
      {
         RemoveBasketTrade(i);
         break;
      }
   }
}
```

**Add to CheckAndCloseBasket() before final closing:**
```mql4
// Check partial closes
CheckPartialClose();
```

---

### **5. Equity-Based Exit** ⭐⭐ (HIGH PRIORITY)
**Why:** Perfect for funded accounts. Protects daily targets/limits.

**Implementation:**
```mql4
// Add to input parameters
input bool     UseEquityExit = true;           // Enable equity-based exits
input double   DailyProfitTargetPercent = 5.0; // Daily profit target % of balance
input double   DailyLossLimitPercent = 3.0;   // Daily loss limit % of balance
input bool     StopTradingAfterTarget = true; // Stop trading after target reached

// Add to global variables
double dailyStartBalance = 0.0;
datetime lastDayReset = 0;

// Initialize in OnInit():
dailyStartBalance = AccountBalance();
lastDayReset = TimeCurrent();

// Add function:
bool CheckEquityBasedExit()
{
   if(!UseEquityExit)
      return false;
   
   // Reset daily tracking on new day
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   MqlDateTime lastDt;
   TimeToStruct(lastDayReset, lastDt);
   
   if(dt.day != lastDt.day)
   {
      dailyStartBalance = AccountBalance();
      lastDayReset = TimeCurrent();
      Print("Daily reset: New day started. Balance: $", DoubleToString(dailyStartBalance, 2));
   }
   
   double currentBalance = AccountBalance();
   double dailyProfit = currentBalance - dailyStartBalance;
   double dailyProfitPercent = (dailyProfit / dailyStartBalance) * 100.0;
   
   // Check daily profit target
   if(dailyProfitPercent >= DailyProfitTargetPercent)
   {
      if(currentBasket.totalTrades > 0)
      {
         double basketProfit = CalculateBasketProfit();
         if(basketProfit > 0)
         {
            Print("DAILY PROFIT TARGET REACHED: ", DoubleToString(dailyProfitPercent, 2), "%");
            CloseEntireBasket("Daily Profit Target: " + DoubleToString(dailyProfitPercent, 2) + "%");
            return true;
         }
      }
      
      if(StopTradingAfterTarget)
      {
         Print("DAILY TARGET REACHED - Stopping trading for today");
         // Could set a flag to prevent new trades
      }
   }
   
   // Check daily loss limit
   if(dailyProfitPercent <= -DailyLossLimitPercent)
   {
      Print("DAILY LOSS LIMIT REACHED: ", DoubleToString(dailyProfitPercent, 2), "%");
      CloseEntireBasket("Daily Loss Limit: " + DoubleToString(dailyProfitPercent, 2) + "%");
      return true;
   }
   
   return false;
}
```

**Add to CheckAndCloseBasket() at the beginning:**
```mql4
// PRIORITY: Check equity-based exits first
if(CheckEquityBasedExit())
   return;
```

---

### **6. Spread/Volatility Exit** ⭐⭐ (HIGH PRIORITY)
**Why:** Spread spikes and low volatility kill scalpers. Exit immediately.

**Implementation:**
```mql4
// Add to input parameters
input bool     UseSpreadVolatilityExit = true; // Exit on spread/volatility issues
input double   MaxSpreadExitPips = 15.0;     // Exit if spread exceeds this
input double   MinATRExitPips = 0.5;         // Exit if ATR drops below this
input int      SpreadSpikeBars = 3;          // Bars to confirm spread spike

// Add to global variables
double lastNormalSpread = 0.0;
int spreadSpikeCount = 0;

// Add function:
bool CheckSpreadVolatilityExit()
{
   if(!UseSpreadVolatilityExit || currentBasket.totalTrades == 0)
      return false;
   
   double spread = (Ask - Bid) / pipToPoint;
   double atr = iATR(Symbol(), PERIOD_M1, Analysis_ATR_Period, 0);
   double atrPips = (atr > 0) ? (atr / pipToPoint) : 0.0;
   
   // Check spread spike
   if(spread > MaxSpreadExitPips)
   {
      spreadSpikeCount++;
      if(spreadSpikeCount >= SpreadSpikeBars)
      {
         double basketProfit = CalculateBasketProfit();
         Print("SPREAD SPIKE EXIT: Spread=", DoubleToString(spread, 1), " pips");
         CloseEntireBasket("Spread Spike Exit: " + DoubleToString(spread, 1) + " pips | Profit: $" + 
                          DoubleToString(basketProfit, 2));
         spreadSpikeCount = 0;
         return true;
      }
   }
   else
   {
      spreadSpikeCount = 0;
   }
   
   // Check low volatility (ATR drop)
   if(atrPips > 0 && atrPips < MinATRExitPips)
   {
      double basketProfit = CalculateBasketProfit();
      if(basketProfit > 0)  // Only exit if profitable
      {
         Print("LOW VOLATILITY EXIT: ATR=", DoubleToString(atrPips, 2), " pips");
         CloseEntireBasket("Low Volatility Exit: ATR=" + DoubleToString(atrPips, 2) + " pips | Profit: $" + 
                          DoubleToString(basketProfit, 2));
         return true;
      }
   }
   
   // Check price freeze (no movement)
   static double lastPrice = 0.0;
   static datetime lastPriceTime = 0;
   double currentPrice = (Bid + Ask) / 2.0;
   datetime currentTime = TimeCurrent();
   
   if(lastPrice > 0 && lastPriceTime > 0)
   {
      double priceChange = MathAbs(currentPrice - lastPrice) / pipToPoint;
      int timeDiff = (int)(currentTime - lastPriceTime);
      
      // Price hasn't moved in 30 seconds
      if(timeDiff >= 30 && priceChange < 0.1)
      {
         double basketProfit = CalculateBasketProfit();
         if(basketProfit > 0)
         {
            Print("PRICE FREEZE EXIT: No movement for ", timeDiff, " seconds");
            CloseEntireBasket("Price Freeze Exit | Profit: $" + DoubleToString(basketProfit, 2));
            return true;
         }
      }
   }
   
   lastPrice = currentPrice;
   lastPriceTime = currentTime;
   
   return false;
}
```

**Add to CheckAndCloseBasket() after equity check:**
```mql4
// Check spread/volatility exits
if(CheckSpreadVolatilityExit())
   return;
```

---

## 📋 Implementation Order in CheckAndCloseBasket()

```mql4
void CheckAndCloseBasket()
{
   if(currentBasket.totalTrades == 0)
      return;
   
   double basketProfit = CalculateBasketProfit();
   
   // Update tracking...
   
   // ===== EXIT CHECKS (Priority Order) =====
   
   // 1. Equity-based exits (daily limits) - HIGHEST PRIORITY
   if(CheckEquityBasedExit())
      return;
   
   // 2. Spread/Volatility exits (market conditions) - HIGH PRIORITY
   if(CheckSpreadVolatilityExit())
      return;
   
   // 3. Opposite signal exit (entry reason gone) - HIGH PRIORITY
   if(CheckOppositeSignalExit())
      return;
   
   // 4. Indicator-based exits (momentum loss) - MEDIUM PRIORITY
   if(CheckIndicatorBasedExit())
      return;
   
   // 5. Partial closes (profit locking) - MEDIUM PRIORITY
   CheckPartialClose();
   
   // 6. Recovery mode logic (existing) - MEDIUM PRIORITY
   // ... existing recovery code ...
   
   // 7. Normal profit target (existing) - LOW PRIORITY
   // ... existing profit target code ...
}
```

---

## 🎯 Expected Impact

### **Performance Improvements:**
- **Opposite Signal Exit:** Prevents holding losing trades when reason is gone
- **Indicator-Based Exit:** Exits before reversals, captures more profit
- **Break-Even:** Eliminates losses on good entries
- **Partial Close:** Locks profits early, lets winners run
- **Equity-Based:** Protects funded accounts, prevents overtrading
- **Spread/Volatility:** Exits during bad market conditions

### **Risk Reduction:**
- ✅ Prevents holding trades when market conditions change
- ✅ Protects profits with break-even and partial closes
- ✅ Exits during spread spikes (news events)
- ✅ Respects daily limits (funded account rules)

---

## ⚙️ Recommended Settings

```mql4
// Exit Strategy Settings
UseOppositeSignalExit = true;
UseIndicatorExit = true;
UseRSIExit = true;
RSIExitThreshold = 50.0;
UseEMAExit = true;
UseMomentumExit = true;

UseBreakEvenExit = true;
BreakEvenTriggerPips = 10.0;
BreakEvenOffsetPips = 2.0;

UsePartialClose = true;
PartialClose1Pips = 15.0;
PartialClose1Percent = 30.0;
PartialClose2Pips = 30.0;
PartialClose2Percent = 30.0;

UseEquityExit = true;
DailyProfitTargetPercent = 5.0;
DailyLossLimitPercent = 3.0;

UseSpreadVolatilityExit = true;
MaxSpreadExitPips = 15.0;
MinATRExitPips = 0.5;
```

---

## 🧪 Testing Recommendations

1. **Backtest with all exits enabled** - Compare to current version
2. **Test opposite signal exit** - Verify it closes when signal flips
3. **Test partial closes** - Ensure profit locking works correctly
4. **Test spread exit** - Verify exits during news events
5. **Test equity exits** - Verify daily limits work correctly

---

## 📝 Notes

- **Recovery Mode:** Some exits (opposite signal, spread) should work even in recovery mode
- **Partial Closes:** Reset flags when basket resets
- **Break-Even:** Only move SL forward, never backward
- **Equity Exits:** Reset daily tracking on new day















