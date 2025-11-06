#property copyright "Copyright 2025, Advanced Trading Systems"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "2.00"
#property strict

// ===== TICK-BASED MACHINE-GUN SCALPER =====
// Ultra-fast tick-based trading with instant basket closure
// No indicators, no delays, no filters - pure tick-based execution

// ===== TRADING MODE =====
input group "===== Trading Mode ====="
input int TradingMode = 0;  // 0=Basket TP (recommended), 1=Per-Trade TP

// ===== TICK-BASED ENTRY SETTINGS =====
input group "===== Tick Entry Logic ====="
input int      EntryMethod = 0;           // 0=Micro price movement, 1=Random hedge, 2=Spread-based
input double   MicroMovementPips = 0.5;  // Minimum price movement to trigger entry (pips)
input int      MaxConcurrentTrades = 10;  // Maximum trades per symbol
input bool     OpenBothDirections = false;// Open BUY+SELL simultaneously (hedge mode)

// ===== POSITION SIZING =====
input group "===== Position Sizing ====="
input int      LotSizingMode = 3;        // 0=Fixed, 1=Risk%, 2=Martingale, 3=GridStep, 4=EquityScale
input double   BaseLot = 0.01;           // Base lot size
input double   LotSize = 0.01;           // Fixed lot (if mode 0)
input double   RiskPercent = 0.5;        // Risk % per trade (if mode 1)
input double   MartingaleFactor = 1.5;    // Multiplier after loss (if mode 2)
input double   GridLotStep = 0.01;       // Increment per extra trade (if mode 3)
input double   EquityPerLot = 2000.0;    // $ equity per BaseLot (if mode 4)
input double   MaxLot = 1.00;            // Safety cap
input double   MinLot = 0.01;            // Safety floor

// ===== BASKET TAKE-PROFIT (PRIMARY MODE) =====
input group "===== Basket Take-Profit ====="
input double   BasketProfitFixed = 1.0;  // Close all trades at this profit ($) - INSTANT CLOSE
input double   BasketProfitPercent = 0.0; // OR % of balance (0 = use fixed)
input bool     UseBasketTimeLimit = false;// Time limit (usually disabled for speed)
input int      BasketTimeLimitSeconds = 30; // Max seconds per basket

// ===== PER-TRADE TP (ALTERNATIVE MODE) =====
input group "===== Per-Trade Micro TP ====="
input double   MicroTPPips = 2.0;        // Micro TP in pips
input double   StopLossPips = 0.0;       // SL (0 = no SL, basket-only protection)

// ===== RISK MANAGEMENT =====
input group "===== Risk Management ====="
input double   MaxDrawdownPercent = 30.0; // Maximum equity drawdown %
input bool     UseDrawdownGuard = true;   // Enable drawdown protection
input double   MaxSpreadPips = 10.0;      // Max spread (relaxed for speed)

// ===== ORDER MANAGEMENT =====
input group "===== Order Management ====="
input int      MagicNumber = 202504;     // Magic number
input int      MaxRetries = 2;           // Maximum order retries (reduced for speed)
input int      RetryDelayMS = 50;        // Delay between retries (ms) - minimal
input int      SlippagePips = 5;         // Maximum slippage

// ===== DISPLAY =====
input group "===== Display ====="
input bool     ShowPanel = true;         // Show on-chart panel

// ===== INTERNAL STATE =====
double accountStartBalance = 0;
double accountStartEquity = 0;
datetime basketStartTime = 0;
bool basketActive = false;
int totalTrades = 0;
double totalFloatingProfit = 0;
double highestBasketProfit = 0;

double g_LastBasketResultProfit = 0.0;
double g_LastLotUsed = 0.0;
int g_SeqTradesSameDir = 0;

double g_LastPrice = 0.0;
datetime g_LastTickTime = 0;

struct TradeInfo {
   int ticket;
   double entryPrice;
   double lotSize;
   datetime openTime;
   int orderType;
   double highestProfit;
   bool breakEvenSet;
};

TradeInfo openTrades[100];
int totalOpenTrades = 0;

// ===== UTILITIES =====
double PipPoint()
{
   double point = MarketInfo(Symbol(), MODE_POINT);
   int digits = (int)MarketInfo(Symbol(), MODE_DIGITS);
   if(digits == 5 || digits == 3) point *= 10.0;
   return point;
}

double ClampLot(double lots)
{
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   double minL = MathMax(MinLot, MarketInfo(Symbol(), MODE_MINLOT));
   double maxL = MathMin(MaxLot, MarketInfo(Symbol(), MODE_MAXLOT));
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   if(lots < minL) lots = minL;
   if(lots > maxL) lots = maxL;
   return NormalizeDouble(lots, 2);
}

int CountOpenByDir(int dir)
{
   int c = 0;
   for(int i = 0; i < totalOpenTrades; i++)
   {
      if(openTrades[i].ticket > 0)
      {
         if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))
         {
            if(OrderType() == dir) c++;
         }
      }
   }
   return c;
}

bool IsLosingBasket()
{
   return (g_LastBasketResultProfit < 0.0);
}

double ComputeRiskPercentLot(double stopLossPips)
{
   if(stopLossPips <= 0.0) return BaseLot;
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double pipValuePerLot = tickValue * (PipPoint() / MarketInfo(Symbol(), MODE_TICKSIZE));
   double moneyAtSLPerLot = pipValuePerLot * stopLossPips;
   if(moneyAtSLPerLot <= 0.0) return BaseLot;
   double lots = (AccountBalance() * (RiskPercent / 100.0)) / moneyAtSLPerLot;
   return lots;
}

double NextLotForDirection(int direction)
{
   double stopPips = (TradingMode == 1 && StopLossPips > 0) ? StopLossPips : 0.0;
   double lots = BaseLot;

   if(LotSizingMode == 0){  // Fixed
      lots = LotSize;
   }
   else if(LotSizingMode == 1){  // Risk Percent
      lots = ComputeRiskPercentLot(stopPips);
   }
   else if(LotSizingMode == 2){  // Martingale
      if(IsLosingBasket() && g_LastLotUsed > 0){
         lots = g_LastLotUsed * MartingaleFactor;
      }else{
         lots = BaseLot;
      }
   }
   else if(LotSizingMode == 3){  // Grid Step
      int nSame = CountOpenByDir(direction);
      lots = BaseLot + (nSame * GridLotStep);
   }
   else if(LotSizingMode == 4){  // Equity Scale
      if(EquityPerLot > 0.0){
         lots = (AccountEquity() / EquityPerLot) * BaseLot;
      } else {
         lots = BaseLot;
      }
   }

   lots = ClampLot(lots);
   return lots;
}

// ===== INITIALIZATION =====
int OnInit()
{
   Print("========================================");
   Print("Tick-Based Machine-Gun Scalper v2.00");
   Print("========================================");
   Print("Mode: ", (TradingMode == 0 ? "BASKET TP" : "PER-TRADE TP"));
   Print("Entry Method: ", EntryMethod, " (0=Micro movement, 1=Random hedge, 2=Spread)");
   Print("Lot Sizing: ", LotSizingMode, " (0=Fixed,1=Risk,2=Martingale,3=Grid,4=Equity)");
   Print("Basket Target: $", BasketProfitFixed);
   Print("========================================");
   
   accountStartBalance = AccountBalance();
   accountStartEquity = AccountEquity();
   basketStartTime = 0;
   basketActive = false;
   totalTrades = 0;
   g_LastBasketResultProfit = 0.0;
   g_LastLotUsed = 0.0;
   g_SeqTradesSameDir = 0;
   g_LastPrice = (Ask + Bid) / 2.0;
   g_LastTickTime = TimeCurrent();
   
   for(int i = 0; i < 100; i++)
   {
      openTrades[i].ticket = -1;
      openTrades[i].entryPrice = 0;
      openTrades[i].lotSize = 0;
      openTrades[i].openTime = 0;
      openTrades[i].orderType = -1;
      openTrades[i].highestProfit = 0;
      openTrades[i].breakEvenSet = false;
   }
   
   CleanupClosedTrades();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(ShowPanel)
   {
      ObjectsDeleteAll(0, "TBSPanel_");
      Comment("");
   }
   Print("Tick-Based Scalper Deinitialized. Reason: ", reason);
}

// ===== MAIN TICK FUNCTION - ULTRA FAST =====
void OnTick()
{
   // Update trade tracking (minimal overhead)
   CleanupClosedTrades();
   UpdateTradeInfo();
   
   // Check drawdown guard (quick check)
   if(UseDrawdownGuard && CheckDrawdown())
   {
      CloseAllTrades("Drawdown Protection");
      return;
   }
   
   // Quick spread check (minimal)
   if(!QuickSpreadCheck())
      return;
   
   // Mode-specific management
   if(TradingMode == 0)  // Basket TP Mode
   {
      ManageBasketMode();
   }
   else  // Per-Trade TP Mode
   {
      ManageMicroTPMode();
   }
   
   // TICK-BASED ENTRY - NO CANDLE WAITING
   if(totalOpenTrades < MaxConcurrentTrades)
   {
      CheckTickBasedEntry();
   }
   
   // Update display
   if(ShowPanel)
   {
      UpdatePanel();
   }
}

// ===== TICK-BASED ENTRY LOGIC =====
void CheckTickBasedEntry()
{
   double currentPrice = (Ask + Bid) / 2.0;
   double point = PipPoint();
   
   // Entry Method 0: Micro Price Movement
   if(EntryMethod == 0)
   {
      if(g_LastPrice > 0)
      {
         double priceChange = MathAbs(currentPrice - g_LastPrice) / point;
         
         if(priceChange >= MicroMovementPips)
         {
            // Price moved enough - open trade in direction of movement
            int direction = (currentPrice > g_LastPrice) ? OP_BUY : OP_SELL;
            OpenTrade(direction);
            
            if(OpenBothDirections)
            {
               // Also open opposite direction (hedge)
               OpenTrade((direction == OP_BUY) ? OP_SELL : OP_BUY);
            }
            
            g_LastPrice = currentPrice;
         }
      }
      else
      {
         g_LastPrice = currentPrice;
      }
   }
   // Entry Method 1: Random Hedge (open both directions)
   else if(EntryMethod == 1)
   {
      if(totalOpenTrades == 0 || (TimeCurrent() - g_LastTickTime) > 1)
      {
         OpenTrade(OP_BUY);
         OpenTrade(OP_SELL);
         g_LastTickTime = TimeCurrent();
      }
   }
   // Entry Method 2: Spread-Based (open when spread is tight)
   else if(EntryMethod == 2)
   {
      double spread = (Ask - Bid) / point;
      if(spread < (MaxSpreadPips * 0.5))  // Spread is half of max
      {
         // Open in random direction or based on current price
         int direction = (MathRand() % 2 == 0) ? OP_BUY : OP_SELL;
         OpenTrade(direction);
      }
   }
}

// ===== QUICK SPREAD CHECK =====
bool QuickSpreadCheck()
{
   double spread = (Ask - Bid) / PipPoint();
   return (spread <= MaxSpreadPips);
}

// ===== BASKET MODE MANAGEMENT =====
void ManageBasketMode()
{
   if(totalOpenTrades == 0)
   {
      if(basketActive)
      {
         g_LastBasketResultProfit = highestBasketProfit;
         if(totalFloatingProfit < 0) g_LastBasketResultProfit = -1.0;
      }
      basketActive = false;
      basketStartTime = 0;
      highestBasketProfit = 0;
      g_SeqTradesSameDir = 0;
      return;
   }
   
   if(!basketActive)
   {
      basketActive = true;
      basketStartTime = TimeCurrent();
      highestBasketProfit = 0;
   }
   
   // Calculate total floating profit (FAST)
   totalFloatingProfit = 0;
   for(int i = 0; i < totalOpenTrades; i++)
   {
      if(openTrades[i].ticket > 0)
      {
         if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))
         {
            totalFloatingProfit += OrderProfit() + OrderSwap() + OrderCommission();
         }
      }
   }
   
   // Track highest profit
   if(totalFloatingProfit > highestBasketProfit)
      highestBasketProfit = totalFloatingProfit;
   
   // INSTANT CLOSE ON PROFIT TARGET
   double profitTarget = (BasketProfitPercent > 0) ? 
                        (AccountBalance() * (BasketProfitPercent / 100.0)) : 
                        BasketProfitFixed;
   
   if(totalFloatingProfit >= profitTarget)
   {
      CloseAllTrades("Basket Profit: $" + DoubleToString(totalFloatingProfit, 2));
      return;
   }
   
   // Time limit (optional, usually disabled)
   if(UseBasketTimeLimit && basketStartTime > 0)
   {
      int elapsedSeconds = (int)(TimeCurrent() - basketStartTime);
      if(elapsedSeconds >= BasketTimeLimitSeconds)
      {
         CloseAllTrades("Time Limit: " + IntegerToString(elapsedSeconds) + "s");
         return;
      }
   }
}

// ===== MICRO TP MODE MANAGEMENT =====
void ManageMicroTPMode()
{
   double point = PipPoint();
   
   for(int i = totalOpenTrades - 1; i >= 0; i--)
   {
      if(openTrades[i].ticket > 0)
      {
         if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))
         {
            double profitPips = 0;
            if(OrderType() == OP_BUY)
               profitPips = (Bid - openTrades[i].entryPrice) / point;
            else
               profitPips = (openTrades[i].entryPrice - Ask) / point;
            
            // Instant close on micro TP
            if(profitPips >= MicroTPPips)
            {
               CloseTrade(i, "Micro TP: " + DoubleToString(profitPips, 1) + " pips");
               continue;
            }
         }
      }
   }
}

// ===== OPEN TRADE =====
void OpenTrade(int direction)
{
   double price = (direction == OP_BUY) ? Ask : Bid;
   double sl = 0, tp = 0;
   double point = PipPoint();
   int digits = (int)MarketInfo(Symbol(), MODE_DIGITS);
   
   // Compute dynamic lots
   double lots = NextLotForDirection(direction);
   
   // Set SL/TP only for per-trade mode
   if(TradingMode == 1)
   {
      if(direction == OP_BUY)
      {
         if(StopLossPips > 0) sl = price - (StopLossPips * point);
         tp = price + (MicroTPPips * point);
      }
      else
      {
         if(StopLossPips > 0) sl = price + (StopLossPips * point);
         tp = price - (MicroTPPips * point);
      }
      sl = (StopLossPips > 0) ? NormalizeDouble(sl, digits) : 0;
      tp = NormalizeDouble(tp, digits);
   }
   
   int ticket = SendOrderWithRetry(direction, lots, price, sl, tp);
   
   if(ticket > 0)
   {
      if(totalOpenTrades < 100)
      {
         openTrades[totalOpenTrades].ticket = ticket;
         openTrades[totalOpenTrades].entryPrice = price;
         openTrades[totalOpenTrades].lotSize = lots;
         openTrades[totalOpenTrades].openTime = TimeCurrent();
         openTrades[totalOpenTrades].orderType = direction;
         openTrades[totalOpenTrades].highestProfit = 0;
         openTrades[totalOpenTrades].breakEvenSet = false;
         totalOpenTrades++;
         totalTrades++;
      }
      g_LastLotUsed = lots;
      
      static int lastDir = -999;
      if(lastDir == direction) g_SeqTradesSameDir++;
      else g_SeqTradesSameDir = 1;
      lastDir = direction;
   }
}

// ===== SEND ORDER WITH RETRY =====
int SendOrderWithRetry(int orderType, double lots, double price, double sl, double tp)
{
   int attempts = 0;
   int ticket = -1;
   
   while(attempts < MaxRetries)
   {
      RefreshRates();
      price = (orderType == OP_BUY) ? Ask : Bid;
      
      ticket = OrderSend(Symbol(), orderType, lots, price, SlippagePips, sl, tp,
                        "TickScalper", MagicNumber, 0, 
                        (orderType == OP_BUY ? clrBlue : clrRed));
      
      if(ticket > 0)
         return ticket;
      
      int error = GetLastError();
      if(error == 130 || error == 131 || error == 134 || error == 146 || error == 136 || error == 4108)
      {
         Sleep(RetryDelayMS);
         attempts++;
      }
      else
      {
         break;
      }
   }
   
   return -1;
}

// ===== CLOSE TRADE =====
void CloseTrade(int index, string reason)
{
   if(openTrades[index].ticket <= 0) return;
   if(OrderSelect(openTrades[index].ticket, SELECT_BY_TICKET))
   {
      double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;
      bool closed = OrderClose(openTrades[index].ticket, OrderLots(), closePrice, SlippagePips, clrYellow);
      if(closed)
      {
         RemoveTradeFromArray(index);
      }
   }
}

// ===== CLOSE ALL TRADES =====
void CloseAllTrades(string reason)
{
   double preEquity = AccountEquity();
   
   for(int i = totalOpenTrades - 1; i >= 0; i--)
   {
      if(openTrades[i].ticket > 0)
      {
         CloseTrade(i, reason);
      }
   }
   
   double postEquity = AccountEquity();
   g_LastBasketResultProfit = postEquity - preEquity;
   
   basketActive = false;
   basketStartTime = 0;
   highestBasketProfit = 0;
   g_SeqTradesSameDir = 0;
}

// ===== CLEANUP CLOSED TRADES =====
void CleanupClosedTrades()
{
   for(int i = totalOpenTrades - 1; i >= 0; i--)
   {
      if(openTrades[i].ticket > 0)
      {
         if(!OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))
         {
            RemoveTradeFromArray(i);
         }
      }
   }
}

// ===== UPDATE TRADE INFO =====
void UpdateTradeInfo()
{
   for(int i = 0; i < totalOpenTrades; i++)
   {
      if(openTrades[i].ticket > 0)
      {
         if(OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))
         {
            double profit = OrderProfit() + OrderSwap() + OrderCommission();
            if(profit > openTrades[i].highestProfit)
               openTrades[i].highestProfit = profit;
         }
      }
   }
}

// ===== REMOVE TRADE FROM ARRAY =====
void RemoveTradeFromArray(int index)
{
   if(index < 0 || index >= totalOpenTrades) return;
   for(int i = index; i < totalOpenTrades - 1; i++)
      openTrades[i] = openTrades[i + 1];
   totalOpenTrades--;
}

// ===== CHECK DRAWDOWN =====
bool CheckDrawdown()
{
   if(!UseDrawdownGuard) return false;
   double currentEquity = AccountEquity();
   double maxDrawdown = accountStartEquity * (MaxDrawdownPercent / 100.0);
   if(currentEquity < (accountStartEquity - maxDrawdown))
   {
      return true;
   }
   return false;
}

// ===== UPDATE PANEL =====
void UpdatePanel()
{
   string panelText = "";
   panelText += "=== TICK-BASED MACHINE-GUN SCALPER ===\n";
   panelText += "Mode: " + (TradingMode == 0 ? "BASKET TP" : "PER-TRADE TP") + "\n";
   panelText += "Entry: " + IntegerToString(EntryMethod) + " | LotMode: " + IntegerToString(LotSizingMode) + "\n";
   panelText += "--------------------------------\n";
   panelText += "Open Trades: " + IntegerToString(totalOpenTrades) + "\n";
   panelText += "Total Trades: " + IntegerToString(totalTrades) + "\n";
   
   if(TradingMode == 0)
   {
      double floating = 0;
      for(int i = 0; i < totalOpenTrades; i++)
      {
         if(openTrades[i].ticket > 0 && OrderSelect(openTrades[i].ticket, SELECT_BY_TICKET))
         {
            floating += OrderProfit() + OrderSwap() + OrderCommission();
         }
      }
      panelText += "Basket P/L: $" + DoubleToString(floating, 2) + "\n";
      panelText += "Target: $" + DoubleToString(BasketProfitFixed, 2) + "\n";
      if(basketActive && basketStartTime > 0)
      {
         int elapsed = (int)(TimeCurrent() - basketStartTime);
         panelText += "Basket Time: " + IntegerToString(elapsed) + "s\n";
      }
   }
   else
   {
      panelText += "Micro TP: " + DoubleToString(MicroTPPips, 1) + " pips\n";
   }
   
   panelText += "--------------------------------\n";
   panelText += "Balance: $" + DoubleToString(AccountBalance(), 2) + "\n";
   panelText += "Equity: $" + DoubleToString(AccountEquity(), 2) + "\n";
   
   double drawdown = ((accountStartEquity - AccountEquity()) / accountStartEquity) * 100.0;
   panelText += "Drawdown: " + DoubleToString(drawdown, 2) + "%\n";
   
   double currentSpread = (Ask - Bid) / PipPoint();
   panelText += "Spread: " + DoubleToString(currentSpread, 1) + " pips\n";
   
   Comment(panelText);
}

