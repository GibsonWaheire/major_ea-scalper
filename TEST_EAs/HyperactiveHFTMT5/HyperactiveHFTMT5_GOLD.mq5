#property copyright "Copyright 2026, Hyperactive HFT MT5 Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "3.00"

#include <Trade/Trade.mqh>

CTrade trade;

// =====================================================================================================
// HYPERACTIVE HFT V3.0 - AGGRESSIVE MOMENTUM EDITION
// =====================================================================================================

input group "===== Aggressive Lot Settings ====="
input double   FixedLotSize         = 0.1;      // Lot size per trade
input int      MaxSimultaneousTrades = 10;      // High frequency limit
input int      MagicNumber          = 202610;

input group "===== HFT Exit Logic (Percentage & Decay) ====="
input double   TakeProfitPercent    = 0.5;      // Target % profit per trade for partial close
input double   DecayThreshold       = 0.4;      // Exit when speed drops to 40% of peak (Momentum Decay)
input double   HardStopPips         = 500.0;    // Disaster Stop (Pips)

input group "===== Momentum Entry ====="
input int      MomentumPeriod       = 10;       // Faster calculation for HFT
input double   BreakoutThreshold    = 10.0;     // Points to trigger entry
input int      MinTickSpeed         = 5;        // Minimum ticks per second

// Internal Globals
struct TradeInfo {
   ulong    ticket;
   double   entryPrice;
   double   peakVelocity;
   bool     partialClosed;
};

TradeInfo activeTrades[20]; 
int activeTradeCount = 0;
double tickPrices[20];
datetime lastTickTime;
double currentTicksPerSecond = 0;
int tickCounter = 0;

// =====================================================================================================
// INIT & CORE
// =====================================================================================================

int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   return(INIT_SUCCEEDED);
}

void OnTick() {
   UpdateVelocity();
   
   // 1. MANAGE EXITS (DECAY & PROFIT)
   ManageActiveExits();

   // 2. AGGRESSIVE ENTRY
   if(activeTradeCount < MaxSimultaneousTrades) {
      int signal = GetHFTMove();
      if(signal != 0) OpenAggressiveTrade(signal);
   }
}

// =====================================================================================================
// VELOCITY & MOMENTUM
// =====================================================================================================

void UpdateVelocity() {
   tickCounter++;
   datetime now = TimeCurrent();
   if(now > lastTickTime) {
      currentTicksPerSecond = tickCounter;
      tickCounter = 0;
      lastTickTime = now;
   }
   
   // Shift prices
   for(int i=19; i>0; i--) tickPrices[i] = tickPrices[i-1];
   tickPrices[0] = SymbolInfoDouble(_Symbol, SYMBOL_BID);
}

int GetHFTMove() {
   if(currentTicksPerSecond < MinTickSpeed) return 0;
   
   double change = tickPrices[0] - tickPrices[MomentumPeriod-1];
   double threshold = BreakoutThreshold * _Point;
   
   if(change > threshold) return 1;  // Bullish Momentum
   if(change < -threshold) return -1; // Bearish Momentum
   return 0;
}

// =====================================================================================================
// TRADE MANAGEMENT (THE "BETTER" EXIT)
// =====================================================================================================

void ManageActiveExits() {
   for(int i = activeTradeCount - 1; i >= 0; i--) {
      if(!PositionSelectByTicket(activeTrades[i].ticket)) {
         RemoveTrade(i);
         continue;
      }
      
      double profit = PositionGetDouble(POSITION_PROFIT);
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double profitPct = (profit / balance) * 100.0;
      
      // TRACK PEAK VELOCITY FOR DECAY
      if(currentTicksPerSecond > activeTrades[i].peakVelocity)
         activeTrades[i].peakVelocity = currentTicksPerSecond;

      // 1. PARTIAL CLOSE AT PERCENTAGE TARGET
      if(!activeTrades[i].partialClosed && profitPct >= TakeProfitPercent) {
         double lot = PositionGetDouble(POSITION_VOLUME);
         trade.PositionClosePartial(activeTrades[i].ticket, lot/2);
         activeTrades[i].partialClosed = true;
         Print("HFT: Partial profit taken at ", TakeProfitPercent, "%");
      }

      // 2. MOMENTUM DECAY EXIT (Exit when the move dies)
      // Only check decay if we have at least some profit
      if(profit > 0 && activeTrades[i].peakVelocity > (MinTickSpeed * 2)) {
         if(currentTicksPerSecond < (activeTrades[i].peakVelocity * DecayThreshold)) {
            trade.PositionClose(activeTrades[i].ticket);
            Print("HFT: Momentum Decayed. Closing at Profit.");
            RemoveTrade(i);
            continue;
         }
      }
      
      // 3. HARD DISASTER STOP (500 Pips)
      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      double curPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double dist = MathAbs(price - curPrice) / _Point;
      
      if(profit < 0 && dist >= (HardStopPips * 10)) {
         trade.PositionClose(activeTrades[i].ticket);
         Print("HFT: Disaster Stop Hit.");
         RemoveTrade(i);
      }
   }
}

// =====================================================================================================
// UTILITIES
// =====================================================================================================

void OpenAggressiveTrade(int dir) {
   bool sent = false;
   if(dir == 1) sent = trade.Buy(FixedLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), 0, 0);
   if(dir == -1) sent = trade.Sell(FixedLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), 0, 0);
   
   if(sent) {
      // Get position ticket
      ulong ticket = 0;
      if(trade.ResultDeal() > 0) {
         if(HistoryDealSelect(trade.ResultDeal())) {
            ticket = HistoryDealGetInteger(trade.ResultDeal(), DEAL_POSITION_ID);
         }
      }
      
      // If still no ticket, find position by symbol and magic
      if(ticket == 0) {
         for(int i = PositionsTotal() - 1; i >= 0; i--) {
            ulong posTicket = PositionGetTicket(i);
            if(posTicket > 0 && PositionSelectByTicket(posTicket)) {
               if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
                  PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
                  ticket = posTicket;
                  break;
               }
            }
         }
      }
      
      if(ticket > 0) {
         double entryPrice = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(PositionSelectByTicket(ticket)) {
            entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         }
         
         activeTrades[activeTradeCount].ticket = ticket;
         activeTrades[activeTradeCount].entryPrice = entryPrice;
         activeTrades[activeTradeCount].peakVelocity = currentTicksPerSecond;
         activeTrades[activeTradeCount].partialClosed = false;
         activeTradeCount++;
      }
   }
}

void RemoveTrade(int index) {
   for(int i = index; i < activeTradeCount - 1; i++) {
      activeTrades[i] = activeTrades[i+1];
   }
   activeTradeCount--;
}
