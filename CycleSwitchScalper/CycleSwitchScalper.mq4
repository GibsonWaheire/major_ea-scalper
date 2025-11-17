#property strict
#property copyright "Copyright 2025"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"

/*
   CycleSwitchScalper.mq4
   ----------------------------------------------------------------------
   Basket-oriented cycle trader that follows the requested rules:
   - Closes basket only after floating profit reaches defined percentage targets.
   - Basket stop loss at -40% drawdown (disabled for accounts < $300).
   - Automatically reverses direction or switches symbols based on cycle outcome.
   - Slippage fixed at 60 points globally.
   - Displays simple on-chart status panel.
   - Works tick-by-tick via OnTick and manages all orders under the same MagicNumber.
*/

// ===== INPUT SETTINGS =========================================================
input bool     EAEnabled              = true;
input double   ProfitTargetMinPercent = 5.0;      // Close basket when >= this %
input double   ProfitTargetMaxPercent = 500.0;    // Guard upper bound (not heavily used)
input double   DrawdownStopPercent    = 40.0;     // Basket SL (percentage of cycle start balance)
input double   LowBalanceThreshold    = 300.0;    // Accounts below this trade until balance hits 0
input int      SlippagePoints         = 60;       // Fixed slippage for all operations
input int      OrdersPerCycle         = 3;        // Number of trades opened at cycle start
input double   BaseLotSize            = 0.01;
input double   LotMultiplier          = 1.0;      // Optional escalation (1.0 = constant)
input int      MagicNumber            = 935010;
input string   CandidateSymbols       = "XAUUSD,USDJPY,NAS100";
input double   ProfitReverseThreshold = 40.0;     // BUY cycle profit below this reverses direction
input double   ProfitSwitchSymbolThreshold = 5.0; // SELL cycle profit below this switches symbol
input double   ProfitContinueThreshold = 20.0;    // Profit >= this keeps same direction

// ===== INTERNAL STATE =========================================================
#define DIR_BUY   1
#define DIR_SELL -1

string     g_symbols[32];
int        g_symbolCount           = 0;
int        g_currentSymbolIndex    = 0;
int        g_currentDirection      = DIR_BUY;
bool       g_cycleActive           = false;
double     g_cycleStartBalance     = 0.0;
double     g_cycleStartEquity      = 0.0;
datetime   g_cycleStartTime        = 0;
double     g_lastCycleResult       = 0.0;
bool       g_waitingForClosure     = false; // prevents new entries while basket open

// ===== UTILITY FUNCTIONS ======================================================
void DebugPrint(string msg)
{
   Print("[CycleSwitch] ", msg);
}

void ParseSymbols()
{
   g_symbolCount = 0;
   for(int i=0;i<ArraySize(g_symbols);i++)
      g_symbols[i] = "";
   int count = StringSplit(CandidateSymbols, ',', g_symbols);
   if(count > 0) g_symbolCount = count;
   if(g_symbolCount <= 0)
   {
      g_symbols[0] = Symbol();
      g_symbolCount = 1;
   }
   // trim whitespace
   for(int i=0;i<g_symbolCount;i++)
   {
      g_symbols[i] = StringTrimLeft(StringTrimRight(g_symbols[i]));
      if(g_symbols[i] == "") g_symbols[i] = Symbol();
   }
}

string CurrentSymbol()
{
   if(g_currentSymbolIndex >= g_symbolCount) g_currentSymbolIndex = 0;
   return g_symbols[g_currentSymbolIndex];
}

int CountOpenOrders()
{
   int count = 0;
   for(int i=0; i<OrdersTotal(); i++)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber) count++;
      }
   }
   return count;
}

double ComputeFloatingProfit()
{
   double sum = 0.0;
   for(int i=0; i<OrdersTotal(); i++)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber)
            sum += OrderProfit() + OrderSwap() + OrderCommission();
      }
   }
   return sum;
}

double ComputeFloatingPercent()
{
   if(g_cycleStartBalance <= 0.0) return 0.0;
   return (ComputeFloatingProfit() / g_cycleStartBalance) * 100.0;
}

double ComputeDrawdownPercent()
{
   if(g_cycleStartBalance <= 0.0) return 0.0;
   double dd = ((AccountEquity() - g_cycleStartBalance) / g_cycleStartBalance) * 100.0;
   return dd;
}

bool CloseAllOrders(string reason)
{
   bool ok = true;
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() != MagicNumber) continue;
         double price = (OrderType()==OP_BUY)?Bid:Ask;
         if(!OrderClose(OrderTicket(), OrderLots(), price, SlippagePoints, clrRed))
         {
            ok = false;
         }
      }
   }
   if(ok) DebugPrint("Closed basket: " + reason);
   return ok;
}

void SwitchToNextSymbol()
{
   g_currentSymbolIndex++;
   if(g_currentSymbolIndex >= g_symbolCount) g_currentSymbolIndex = 0;
   string sym = CurrentSymbol();
   if(!SymbolSelect(sym, true))
   {
      DebugPrint("Failed to select symbol " + sym + ". reverting to chart symbol");
      g_currentSymbolIndex = 0;
   }
}

// ===== CYCLE MANAGEMENT =======================================================
void StartNewCycle()
{
   string sym = CurrentSymbol();
   if(!SymbolSelect(sym, true))
   {
      DebugPrint("Cannot trade symbol " + sym);
      return;
   }
   g_cycleStartBalance = AccountBalance();
   g_cycleStartEquity  = AccountEquity();
   g_cycleStartTime    = TimeCurrent();
   g_waitingForClosure = false;

   double lot = BaseLotSize;
   // open orders
   for(int i=0; i<OrdersPerCycle; i++)
   {
      double factor = MathPow(LotMultiplier, i);
      double lots   = NormalizeDouble(lot * factor, 2);
      int type      = (g_currentDirection == DIR_BUY) ? OP_BUY : OP_SELL;
      double price  = (type==OP_BUY)?MarketInfo(sym, MODE_ASK):MarketInfo(sym, MODE_BID);
      int ticket    = OrderSend(sym, type, lots, price, SlippagePoints, 0, 0, "CycleSwitch", MagicNumber, 0, clrBlue);
      if(ticket < 0)
      {
         DebugPrint("OrderSend failed: " + IntegerToString(GetLastError()));
      }
   }
   g_cycleActive = true;
   DebugPrint(StringFormat("Cycle started on %s direction %s", sym, (g_currentDirection==DIR_BUY)?"BUY":"SELL"));
}

void EvaluateCycleClosure()
{
   if(!g_cycleActive) return;
   int openOrders = CountOpenOrders();
   if(openOrders == 0 && !g_waitingForClosure)
   {
      // previous cycle ended without us tracking closure; treat as complete
      double resultPercent = (g_cycleStartBalance>0)?((AccountBalance()-g_cycleStartBalance)/g_cycleStartBalance)*100.0:0.0;
      g_lastCycleResult = resultPercent;
      g_cycleActive = false;
      g_waitingForClosure = false;
   }
}

void HandleCycleClosure()
{
   if(!g_cycleActive) return;
   double profitPercent = ComputeFloatingPercent();
   double drawdownPercent = ComputeDrawdownPercent();
   double balance = AccountBalance();

   bool lowBalanceMode = (balance < LowBalanceThreshold);

   bool shouldCloseForProfit = false;
   if(!lowBalanceMode)
   {
      if(profitPercent >= ProfitTargetMinPercent && profitPercent <= ProfitTargetMaxPercent)
         shouldCloseForProfit = true;
      if(profitPercent > ProfitTargetMaxPercent)
         shouldCloseForProfit = true;
   }

   bool shouldCloseForDrawdown = false;
   if(!lowBalanceMode)
   {
      if(drawdownPercent <= -MathAbs(DrawdownStopPercent))
         shouldCloseForDrawdown = true;
   }
   else
   {
      // Low balance mode: allow closure only when equity effectively zero
      if(AccountEquity() <= 1.0)
         shouldCloseForDrawdown = true;
   }

   if(shouldCloseForProfit || shouldCloseForDrawdown)
   {
      g_waitingForClosure = true;
      if(CloseAllOrders(shouldCloseForProfit?"profit target":"drawdown"))
      {
         // compute cycle result
         double resultPercent = (g_cycleStartBalance>0)?((AccountBalance()-g_cycleStartBalance)/g_cycleStartBalance)*100.0:0.0;
         g_lastCycleResult = resultPercent;
         g_cycleActive = false;
         g_waitingForClosure = false;

         // direction/symbol management
         if(g_currentDirection == DIR_BUY)
         {
            if(resultPercent < ProfitReverseThreshold)
            {
               g_currentDirection = DIR_SELL;
            }
            else if(resultPercent >= ProfitContinueThreshold)
            {
               // keep direction
            }
         }
         else if(g_currentDirection == DIR_SELL)
         {
            if(resultPercent < ProfitSwitchSymbolThreshold)
            {
               SwitchToNextSymbol();
               g_currentDirection = DIR_BUY; // reset to buy after switch
            }
            else if(resultPercent >= ProfitContinueThreshold)
            {
               // keep direction (SELL)
            }
            else if(resultPercent < ProfitReverseThreshold)
            {
               g_currentDirection = DIR_BUY;
            }
         }
      }
   }
}

// ===== PANEL ==============================================================
void UpdatePanel()
{
   string text = "CycleSwitchScalper\n";
   text += StringFormat("Symbol: %s\n", CurrentSymbol());
   text += StringFormat("Mode: %s\n", (g_currentDirection==DIR_BUY)?"BUY":"SELL");
   text += StringFormat("Floating %%: %.2f\n", ComputeFloatingPercent());
   text += StringFormat("Target %%: %.2f\n", ProfitTargetMinPercent);
   text += StringFormat("Drawdown %%: %.2f\n", ComputeDrawdownPercent());
   text += StringFormat("Last Cycle %%: %.2f\n", g_lastCycleResult);
   Comment(text);
}

// ===== MAIN ================================================================
int OnInit()
{
   ParseSymbols();
   if(!EAEnabled)
   {
      DebugPrint("EA disabled at init");
      return(INIT_SUCCEEDED);
   }
   SymbolSelect(CurrentSymbol(), true);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Comment("");
}

void OnTick()
{
   if(!EAEnabled) return;
   EvaluateCycleClosure();

   if(!g_cycleActive)
   {
      // ready for next cycle
      if(CountOpenOrders() == 0)
      {
         StartNewCycle();
      }
   }
   else
   {
      HandleCycleClosure();
   }

   UpdatePanel();
}
