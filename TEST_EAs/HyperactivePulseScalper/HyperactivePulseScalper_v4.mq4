#property copyright "Hyperactive Pulse Scalper V4"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "4.00"
#property strict

// ============================================================================
// HYPERACTIVE PULSE SCALPER — V4 PROFESSIONAL EDITION
// Pure Tick HFT | 3-in-1 Entry Engine | Profit-Only Exit | 5% Risk Per Trade
// ============================================================================

// ----- Inputs -----
input double RiskPercentPerTrade = 5.0;    // 5% dynamic risk
input int    MaxHoldSeconds      = 6;      // 3–7 seconds recommended
input int    MagicNumber         = 202504;

// ----- Trade Structure -----
struct TradeState {
   int      ticket;
   double   entryPrice;
   datetime openTime;
   int      direction;     // 1=BUY, -1=SELL
   double   lotSize;
   double   prevProfit;
};

TradeState trade;
bool hasTrade = false;

// ----- Tick Buffers -----
double bidBuf[5];
double askBuf[5];
bool tickInit = false;
int tickCount = 0;

// ----- Spread Buffers -----
double spreadBuf[10];
bool spreadInit = false;
int spreadCount = 0;

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

// --- Dynamic lot size from risk ---
double CalculateRiskLotSize()
{
   double balance = AccountBalance();
   double riskMoney = balance * (RiskPercentPerTrade / 100.0);

   double pipVal = MarketInfo(Symbol(), MODE_TICKVALUE) / MarketInfo(Symbol(), MODE_TICKSIZE);
   double virtualSL = 10;   // 10 pip virtual stop for sizing

   double lot = riskMoney / (virtualSL * pipVal);
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double step   = MarketInfo(Symbol(), MODE_LOTSTEP);

   lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return NormalizeDouble(lot, 2);
}

// ============================================================================
// TICK BUFFER UPDATE
// ============================================================================
void UpdateTickBuffers()
{
   for(int i=4;i>0;i--) bidBuf[i]=bidBuf[i-1];
   for(int i=4;i>0;i--) askBuf[i]=askBuf[i-1];

   bidBuf[0] = Bid;
   askBuf[0] = Ask;

   tickCount++;
   if(tickCount >= 5) tickInit = true;

   // Spread buffer
   for(int i=9;i>0;i--) spreadBuf[i] = spreadBuf[i-1];
   spreadBuf[0] = Ask - Bid;

   spreadCount++;
   if(spreadCount >= 10) spreadInit = true;
}

// ============================================================================
// 3-IN-1 ENTRY ENGINE (Professional HFT)
// ============================================================================
int GetEntrySignal()
{
   if(!tickInit || !spreadInit) return 0;

   int buySig = 0;
   int sellSig = 0;

   // --- 1. Tick Momentum Breakout ---
   double highBid = bidBuf[1];
   double lowAsk  = askBuf[1];
   for(int i=2;i<5;i++)
   {
      if(bidBuf[i] > highBid) highBid = bidBuf[i];
      if(askBuf[i] < lowAsk)  lowAsk  = askBuf[i];
   }

   if(Bid > highBid) buySig = 1;
   if(Ask < lowAsk)  sellSig = 1;

   // --- 2. Micro Pullback Continuation ---
   double t0 = bidBuf[0], t1 = bidBuf[1], t2 = bidBuf[2];

   // Up micro-impulse
   if(t0 > t2)
   {
      if(Bid > t1) buySig = 1;
   }

   // Down micro-impulse
   if(t0 < t2)
   {
      if(Ask < t1) sellSig = 1;
   }

   // --- 3. Spread Compression ---
   double avgSp = 0;
   for(int i=0;i<10;i++) avgSp+=spreadBuf[i];
   avgSp /= 10;

   if((Ask-Bid) < avgSp*0.5)
   {
      // Spread window → liquidity pocket
      if(Bid > bidBuf[1]) buySig = 2;
      if(Ask < askBuf[1]) sellSig = 2;
   }

   // Final decision
   if(buySig >= sellSig && buySig > 0) return 1;
   if(sellSig >  buySig && sellSig > 0) return -1;

   return 0;
}

// ============================================================================
// TRADE OPENING
// ============================================================================
void OpenTrade(int direction)
{
   if(direction == 0) return;

   double lots = CalculateRiskLotSize();
   double price = (direction==1?Ask:Bid);

   int type = (direction==1 ? OP_BUY : OP_SELL);

   int ticket = OrderSend(Symbol(), type, lots, price, 3, 0, 0,
                          "HFT_V4", MagicNumber, 0,
                          (direction==1?clrGreen:clrRed));

   if(ticket > 0)
   {
      OrderSelect(ticket, SELECT_BY_TICKET);
      trade.ticket     = ticket;
      trade.entryPrice = OrderOpenPrice();
      trade.openTime   = TimeCurrent();
      trade.direction  = direction;
      trade.lotSize    = lots;
      trade.prevProfit = 0;
      hasTrade = true;

      Print("V4 TRADE OPENED → ", (direction==1?"BUY":"SELL"),
            " | Lots: ", lots, " | Price: ", price);
   }
}

// ============================================================================
// TRADE MANAGEMENT (Professional HFT)
// ============================================================================
void ManageTrade()
{
   if(!hasTrade) return;
   if(!OrderSelect(trade.ticket, SELECT_BY_TICKET)) { hasTrade = false; return; }

   double profit = OrderProfit() + OrderSwap() + OrderCommission();
   int hold = TimeCurrent() - trade.openTime;

   // --- 1. Instant Profit Exit ---
   if(profit > 0)
   {
      CloseTrade("Instant profit");
      return;
   }

   // --- 2. Time-Based Exit (But ONLY if profit > 0) ---
   if(hold >= MaxHoldSeconds && profit > 0)
   {
      CloseTrade("Time exit");
      return;
   }

   // --- 3. Spike Exit ---
   if(trade.prevProfit != 0 && profit > trade.prevProfit*2.0 && profit > 0)
   {
      CloseTrade("Profit spike");
      return;
   }

   trade.prevProfit = profit;
}

// ============================================================================
// CLOSE TRADE (profit-only enforced)
// ============================================================================
void CloseTrade(string reason)
{
   if(!OrderSelect(trade.ticket, SELECT_BY_TICKET)) return;

   double profit = OrderProfit() + OrderSwap() + OrderCommission();
   if(profit <= 0) return; // profit-only exit

   bool ok = false;
   if(trade.direction == 1)
      ok = OrderClose(trade.ticket, OrderLots(), Bid, 3, clrRed);
   else
      ok = OrderClose(trade.ticket, OrderLots(), Ask, 3, clrRed);

   if(ok)
   {
      Print("V4 TRADE CLOSED → ", reason, " | Profit: ", profit);
      hasTrade = false;
   }
}

// ============================================================================
// MAIN TICK
// ============================================================================
void OnTick()
{
   UpdateTickBuffers();

   if(hasTrade) ManageTrade();
   else
   {
      int signal = GetEntrySignal();
      if(signal != 0) OpenTrade(signal);
   }
}

// ============================================================================
// END EA
// ============================================================================

