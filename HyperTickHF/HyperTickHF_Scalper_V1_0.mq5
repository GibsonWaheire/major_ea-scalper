#property copyright "Copyright 2025, HyperTick HF Scalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

CTrade trade;

// =====================================================================================================
// HYPER TICK HF SCALPER V1.0 - Pure HFT VPS EA
// Strategy: Ultra-fast tick-based scalping with momentum flip detection
// - No indicators, no EMA, no RSI
// - Tick-based momentum + tick speed
// - Micro pullback + momentum continuation
// - Recovery mode with strict safety limits
// - Designed for $50-$500 accounts growing to $10,000 safely
// =====================================================================================================

// ===== Core Inputs =====
input group "===== Core Trading Settings ====="
input int      MagicNumber         = 202501;
input double   LotSize             = 0.06;      // Fixed lot size (0.05-0.07)
input int      MaxHoldSeconds      = 4;         // Maximum hold time (3-5 seconds)
input bool     UseMomentumEntry    = true;      // Use momentum entry
input bool     UsePullbackEntry    = true;      // Use pullback entry

input group "===== Tick Speed & Spread Limits ====="
input double   TickSpeedLimit      = 0.1;      // Minimum ticks per second (stop if below) - RELAXED for automation
input double   SpreadLimit         = 10.0;     // Maximum spread in pips (stop if above) - RELAXED for automation
input bool     UseTickSpeedCheck   = false;    // Enable tick speed check (disable for long-term automation)
input bool     UseSpreadCheck      = true;     // Enable spread check

input group "===== Recovery Mode Settings ====="
input bool     RecoveryEnabled     = true;     // Enable recovery mode
input int      MaxRecoveryTrades   = 2;        // Maximum recovery trades (1-3)
input double   MaxRecoveryDD       = 22.0;     // Stop recovery if DD > 20-25%

input group "===== Entry Settings ====="
input int      AdditionalTrades    = 2;        // Additional small trades (1-3)
input double   RecoveryLotSize     = 0.03;     // Lot size for recovery trades (0.02-0.04)

input group "===== Exit Settings ====="
input double   MinProfitPoints     = 1.0;      // Minimum profit points above spread
input double   BreakevenProfitUSD  = 0.50;     // Close basket at breakeven or small profit ($)
input bool     UseMomentumReversalExit = true; // Close if momentum flips hard against trade
input int      MomentumReversalTicks   = 7;    // Minimum consecutive ticks against trade to exit (rarer)
input int      MomentumReversalMinHold = 30;   // Minimum seconds in trade before reversal exit (more patient)
input double   MomentumReversalMinLossUSD = 0.50; // Only exit on reversal if loss exceeds this
input bool     MomentumReversalRequireProfit = true; // Only close on reversal if trade is in profit

input group "===== Loss Timeout Exit (Safety) ====="
input bool     UseLossTimeoutExit      = false;  // Close losing trades if loss persists (default OFF for stability)
input int      LossTimeoutMinSeconds   = 60;     // Minimum seconds in loss before considering close
input int      LossTimeoutMaxSeconds   = 120;    // Hard timeout in seconds
input double   LossTimeoutLossPips     = 200.0;  // Close if loss exceeds this many pips (e.g., XAUUSD 200 pips)
input bool     LossTimeoutApplyWhen3Trades = true; // Apply aggressively when 3+ trades are open

input group "===== Anchor Mode (Trend Sentinel) ====="
input bool     UseAnchorMode           = true;   // Treat first trade as anchor (trend sentinel)
input double   AnchorLotSize           = 0.03;   // Anchor trade lot size (smaller to reduce risk)
input double   AnchorStopLossPips      = 300.0;  // Close anchor if loss exceeds this many pips

input group "===== Dynamic Leverage Strategy ====="
input bool     UseDynamicLeverage      = true;   // Enable dynamic lot sizing based on win/loss streaks
input double   LossMultiplier           = 1.5;    // Lot multiplier after consecutive losses (1.2-2.0)
input double   WinMultiplier            = 1.2;    // Lot multiplier after consecutive wins (1.1-1.5)
input double   MaxLotSize               = 0.15;   // Maximum lot size (safety limit)
input double   MinLotSize               = 0.01;   // Minimum lot size (safety limit)
input int      MaxConsecutiveLosses     = 3;      // Reset leverage after this many losses (safety)
input int      MaxConsecutiveWins       = 5;      // Reset leverage after this many wins (lock profits)
input bool     ResetOnBasketClose       = true;   // Reset win/loss streak when basket closes

// =====================================================================================================
// STRUCTURES & GLOBALS
// =====================================================================================================

struct HyperTrade {
   ulong    ticket;
   double   entryPrice;
   datetime openTime;
   int      direction;  // 1=BUY, -1=SELL
   double   lotSize;
   bool     isRecovery;
   ulong    openTickTime;
};

HyperTrade activeTrades[10];
int totalActiveTrades = 0;

// Tick tracking
double tickPrices[20];
datetime tickTimes[20];
int tickIndex = 0;
bool tickBufferReady = false;

// Tick speed tracking
double ticksPerSecond = 0.0;
datetime lastTickSpeedCheck = 0;
int tickCountInWindow = 0;

// Momentum tracking
double lastBid = 0.0;
double lastAsk = 0.0;
int momentumDirection = 0;  // 1=bullish, -1=bearish, 0=neutral
int consecutiveMomentumTicks = 0;

// Pullback tracking
double swingHigh = 0.0;
double swingLow = 0.0;
bool pullbackDetected = false;

// Recovery tracking
int recoveryTradesAdded = 0;
double initialAccountBalance = 0.0;
double highestAccountBalance = 0.0;
double currentDrawdown = 0.0;

// Anchor tracking
ulong  anchorTicket = 0;
int    anchorDirection = 0;   // 1=BUY, -1=SELL
double anchorEntryPrice = 0.0;
datetime anchorOpenTime = 0;

// Leverage strategy tracking
int consecutiveWins = 0;
int consecutiveLosses = 0;
double baseLotSize = 0.0;  // Base lot size for calculations

// Market data
double pipToPoint = 0.0;
int symbolDigits = 0;
MqlTick currentTick;
double currentBid = 0.0;
double currentAsk = 0.0;
double currentSpread = 0.0;

// EA state
bool eaStopped = false;
string stopReason = "";

// =====================================================================================================
// INITIALIZATION
// =====================================================================================================

int OnInit()
{
   Print("========================================");
   Print("HyperTick HF Scalper V1.0 Initialized");
   Print("Pure HFT VPS EA - No Indicators");
   Print("========================================");
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(3);
   
   // Initialize symbol data
   symbolDigits = (int)_Digits;
   pipToPoint = _Point;
   if(symbolDigits == 3 || symbolDigits == 5)
      pipToPoint *= 10.0;
   
   // Initialize tracking
   initialAccountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   highestAccountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   recoveryTradesAdded = 0;
   totalActiveTrades = 0;
   tickIndex = 0;
   tickBufferReady = false;
   eaStopped = false;
   stopReason = "";
   anchorTicket = 0;
   anchorDirection = 0;
   anchorEntryPrice = 0.0;
   anchorOpenTime = 0;
   
   // Initialize leverage strategy
   consecutiveWins = 0;
   consecutiveLosses = 0;
   baseLotSize = LotSize;
   
   // Initialize arrays
   for(int i = 0; i < 10; i++)
   {
      activeTrades[i].ticket = 0;
      activeTrades[i].entryPrice = 0.0;
      activeTrades[i].openTime = 0;
      activeTrades[i].direction = 0;
      activeTrades[i].lotSize = 0.0;
      activeTrades[i].isRecovery = false;
      activeTrades[i].openTickTime = 0;
   }
   
   for(int i = 0; i < 20; i++)
   {
      tickPrices[i] = 0.0;
      tickTimes[i] = 0;
   }
   
   Print("Lot Size: ", LotSize);
   Print("Max Hold: ", MaxHoldSeconds, " seconds");
   Print("Tick Speed Limit: ", TickSpeedLimit, " ticks/sec");
   Print("Spread Limit: ", SpreadLimit, " pips");
   Print("Recovery Enabled: ", RecoveryEnabled);
   Print("Max Recovery Trades: ", MaxRecoveryTrades);
   Print("Max Recovery DD: ", MaxRecoveryDD, "%");
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("HyperTick HF Scalper V1.0 Deinitialized. Reason: ", reason);
}

// =====================================================================================================
// MAIN TICK FUNCTION
// =====================================================================================================

void OnTick()
{
   // Update market data
   if(!UpdateMarketData())
      return;
   
   // Update tick buffers
   UpdateTickBuffers();
   
   // Calculate tick speed
   CalculateTickSpeed();
   
   // Safety checks - Skip trading if conditions not met (but continue running)
   if(!CheckSafetyConditions())
   {
      // EA continues running, just skips this tick for trading
      UpdateDisplay();
      return;
   }
   
   // Manage active trades
   ManageActiveTrades();
   
   // Check for recovery mode activation
   if(RecoveryEnabled && totalActiveTrades > 0)
   {
      CheckRecoveryMode();
   }
   
   // Check basket breakeven/profit closing
   CheckBasketBreakeven();
   
   // Look for new entry signals
   if(totalActiveTrades == 0)
   {
      LookForEntry();
   }
   else if(totalActiveTrades < (1 + AdditionalTrades))
   {
      // Can add additional trades
      LookForEntry();
   }
   
   // Update display
   UpdateDisplay();
}

// =====================================================================================================
// MARKET DATA & TICK TRACKING
// =====================================================================================================

bool UpdateMarketData()
{
   if(!SymbolInfoTick(_Symbol, currentTick))
      return false;
   
   currentBid = currentTick.bid;
   currentAsk = currentTick.ask;
   currentSpread = (currentAsk - currentBid) / pipToPoint;
   
   return (currentBid > 0.0 && currentAsk > 0.0);
}

void UpdateTickBuffers()
{
   double midPrice = (currentBid + currentAsk) / 2.0;
   datetime now = TimeCurrent();
   
   // Shift tick buffer
   for(int i = 19; i > 0; i--)
   {
      tickPrices[i] = tickPrices[i-1];
      tickTimes[i] = tickTimes[i-1];
   }
   
   tickPrices[0] = midPrice;
   tickTimes[0] = now;
   
   tickIndex++;
   if(tickIndex >= 3)
      tickBufferReady = true;
   
   // Update momentum
   if(lastBid > 0.0 && lastAsk > 0.0)
   {
      if(currentBid > lastBid)
      {
         if(momentumDirection == 1)
            consecutiveMomentumTicks++;
         else
         {
            momentumDirection = 1;
            consecutiveMomentumTicks = 1;
         }
      }
      else if(currentBid < lastBid)
      {
         if(momentumDirection == -1)
            consecutiveMomentumTicks++;
         else
         {
            momentumDirection = -1;
            consecutiveMomentumTicks = 1;
         }
      }
   }
   
   lastBid = currentBid;
   lastAsk = currentAsk;
}

void CalculateTickSpeed()
{
   datetime now = TimeCurrent();
   
   if(lastTickSpeedCheck == 0)
   {
      lastTickSpeedCheck = now;
      tickCountInWindow = 0;
      return;
   }
   
   tickCountInWindow++;
   
   int elapsedSeconds = (int)(now - lastTickSpeedCheck);
   if(elapsedSeconds >= 1)
   {
      ticksPerSecond = (double)tickCountInWindow / (double)elapsedSeconds;
      tickCountInWindow = 0;
      lastTickSpeedCheck = now;
   }
}

// =====================================================================================================
// SAFETY CHECKS
// =====================================================================================================

bool CheckSafetyConditions()
{
   // Check spread limit (only if enabled)
   if(UseSpreadCheck)
   {
      double spreadPips = currentSpread;
      if(spreadPips > SpreadLimit)
      {
         // Don't stop EA, just skip this tick (allows EA to continue running)
         static datetime lastSpreadWarning = 0;
         if(TimeCurrent() - lastSpreadWarning > 60) // Warn once per minute
         {
            Print("WARNING: Spread high: ", DoubleToString(spreadPips, 2), " pips (Limit: ", DoubleToString(SpreadLimit, 1), ") - Skipping trade");
            lastSpreadWarning = TimeCurrent();
         }
         return false; // Skip trading but don't stop EA
      }
   }
   
   // Check tick speed limit (only if enabled and we have enough data)
   if(UseTickSpeedCheck && tickIndex >= 10 && ticksPerSecond > 0.0 && ticksPerSecond < TickSpeedLimit)
   {
      // Don't stop EA, just skip this tick (allows EA to continue running)
      static datetime lastSpeedWarning = 0;
      if(TimeCurrent() - lastSpeedWarning > 60) // Warn once per minute
      {
         Print("WARNING: Tick speed low: ", DoubleToString(ticksPerSecond, 2), " ticks/sec (Limit: ", DoubleToString(TickSpeedLimit, 2), ") - Skipping trade");
         lastSpeedWarning = TimeCurrent();
      }
      return false; // Skip trading but don't stop EA
   }
   
   // Check drawdown for recovery
   if(RecoveryEnabled && totalActiveTrades > 0)
   {
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(highestAccountBalance > 0.0)
      {
         currentDrawdown = ((highestAccountBalance - currentEquity) / highestAccountBalance) * 100.0;
         
         if(currentDrawdown > MaxRecoveryDD)
         {
            // Stop recovery mode
            if(recoveryTradesAdded < MaxRecoveryTrades)
            {
               Print("RECOVERY STOPPED: Drawdown ", DoubleToString(currentDrawdown, 2), "% exceeds limit ", DoubleToString(MaxRecoveryDD, 1), "%");
               recoveryTradesAdded = MaxRecoveryTrades; // Prevent more recovery trades
            }
         }
      }
      
      if(currentEquity > highestAccountBalance)
         highestAccountBalance = currentEquity;
   }
   
   // EA no longer stops permanently - it just skips trades when conditions aren't ideal
   // This allows for long-term automation
   return true;
}

// =====================================================================================================
// ENTRY LOGIC
// =====================================================================================================

void LookForEntry()
{
   if(!tickBufferReady || tickIndex < 3)
      return;
   
   // Entry requires BOTH momentum flip AND pullback + continuation when both enabled
   bool momentumFlip = false;
   bool pullbackContinuation = false;
   
   if(UseMomentumEntry)
      momentumFlip = DetectMomentumFlip();
   
   if(UsePullbackEntry)
      pullbackContinuation = DetectPullbackContinuation();
   
   // If both are enabled, require BOTH conditions
   if(UseMomentumEntry && UsePullbackEntry)
   {
      if(!momentumFlip || !pullbackContinuation)
         return;
   }
   // If only momentum is enabled, require momentum flip
   else if(UseMomentumEntry && !UsePullbackEntry)
   {
      if(!momentumFlip)
         return;
   }
   // If only pullback is enabled, require pullback continuation
   else if(UsePullbackEntry && !UseMomentumEntry)
   {
      if(!pullbackContinuation)
         return;
   }
   // If neither is enabled, don't trade
   else
   {
      return;
   }
   
   // Determine direction based on momentum (reduced requirement from 2 to 1 tick)
   int direction = 0;
   if(momentumDirection == 1 && consecutiveMomentumTicks >= 1)
      direction = 1; // BUY
   else if(momentumDirection == -1 && consecutiveMomentumTicks >= 1)
      direction = -1; // SELL
   
   if(direction == 0)
      return;
   
   // Anchor gating: if anchor exists, avoid opening in same direction (use anchor as sentinel)
   if(UseAnchorMode && anchorTicket != 0 && anchorDirection != 0)
   {
      if(direction == anchorDirection)
         return; // skip trades in same direction as anchor
   }
   
   // Debug logging
   static int debugCounter = 0;
   debugCounter++;
   if(debugCounter % 100 == 0)
   {
      Print("DEBUG Entry Check: tickIndex=", tickIndex, " | momentumFlip=", momentumFlip, 
            " | pullbackContinuation=", pullbackContinuation, " | momentumDir=", momentumDirection,
            " | consecutiveTicks=", consecutiveMomentumTicks, " | direction=", direction);
   }
   
   // Open trade
   double lotToUse = CalculateDynamicLotSize();
   bool isRecovery = false;
   
   // If this is the first trade and anchor mode is enabled, use anchor lot size
   if(UseAnchorMode && totalActiveTrades == 0 && anchorTicket == 0)
   {
      lotToUse = CalculateDynamicLotSize(AnchorLotSize);
   }
   else if(totalActiveTrades > 0 && recoveryTradesAdded < MaxRecoveryTrades)
   {
      // Check if we should add recovery trade
      if(CheckIfRecoveryNeeded())
      {
         lotToUse = CalculateDynamicLotSize(RecoveryLotSize);
         isRecovery = true;
      }
      else if(totalActiveTrades < (1 + AdditionalTrades))
      {
         // Add additional small trade
         lotToUse = CalculateDynamicLotSize(RecoveryLotSize); // Use smaller base for additional trades
      }
      else
      {
         return; // Already have enough trades
      }
   }
   
   OpenTrade(direction, lotToUse, isRecovery);
}

bool DetectMomentumFlip()
{
   if(tickIndex < 2)
      return false;
   
   // Check for sharp momentum flip
   // More lenient: just need direction change
   if(tickIndex >= 2)
   {
      // Check if price was moving down, then flipped up (BUY signal)
      double move1 = tickPrices[1] - tickPrices[2]; // Previous move
      double move2 = tickPrices[0] - tickPrices[1]; // Current move
      
      // Flip: previous move was down, current move is up
      if(move1 < 0 && move2 > 0)
      {
         return true; // Bullish flip
      }
      
      // Flip: previous move was up, current move is down
      if(move1 > 0 && move2 < 0)
      {
         return true; // Bearish flip
      }
   }
   
   return false;
}

bool DetectPullbackContinuation()
{
   if(tickIndex < 3)
      return false;
   
   // Micro pullback + momentum continuation (simplified for faster signals)
   // Pattern: price moves in direction, small pullback, then continues
   
   // For BUY: price was up, small pullback down, then continues up
   if(tickIndex >= 3)
   {
      if(tickPrices[1] < tickPrices[2]) // Pullback down
      {
         if(tickPrices[0] > tickPrices[1]) // Continues up
         {
            return true; // Pullback then continuation up
         }
      }
   }
   
   // For SELL: price was down, small pullback up, then continues down
   if(tickIndex >= 3)
   {
      if(tickPrices[1] > tickPrices[2]) // Pullback up
      {
         if(tickPrices[0] < tickPrices[1]) // Continues down
         {
            return true; // Pullback then continuation down
         }
      }
   }
   
   return false;
}

bool CheckIfRecoveryNeeded()
{
   if(!RecoveryEnabled || recoveryTradesAdded >= MaxRecoveryTrades)
      return false;
   
   // Check if any losing trade has been open too long
   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket == 0)
         continue;
      
      if(!PositionSelectByTicket(activeTrades[i].ticket))
         continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT) + 
                      PositionGetDouble(POSITION_SWAP);
      
      if(profit < 0.0)
      {
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         int holdSeconds = (int)(TimeCurrent() - openTime);
         
         if(holdSeconds >= MaxHoldSeconds)
         {
            return true; // Recovery needed
         }
      }
   }
   
   return false;
}

// =====================================================================================================
// DYNAMIC LEVERAGE STRATEGY
// =====================================================================================================

double CalculateDynamicLotSize(double baseLot = 0.0)
{
   if(baseLot <= 0.0)
      baseLot = LotSize;
   
   if(!UseDynamicLeverage)
      return baseLot;
   
   double calculatedLot = baseLot;
   
   // Apply loss multiplier (martingale-style for recovery)
   if(consecutiveLosses > 0)
   {
      // Increase lot size after losses (up to max consecutive losses)
      int effectiveLosses = MathMin(consecutiveLosses, MaxConsecutiveLosses);
      calculatedLot = baseLot * MathPow(LossMultiplier, effectiveLosses);
   }
   // Apply win multiplier (anti-martingale for profit growth)
   else if(consecutiveWins > 0)
   {
      // Increase lot size after wins (up to max consecutive wins)
      int effectiveWins = MathMin(consecutiveWins, MaxConsecutiveWins);
      calculatedLot = baseLot * MathPow(WinMultiplier, effectiveWins);
   }
   
   // Apply safety limits
   calculatedLot = MathMax(MinLotSize, MathMin(MaxLotSize, calculatedLot));
   
   // Normalize to broker's lot step
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0.0)
      calculatedLot = MathFloor(calculatedLot / lotStep) * lotStep;
   
   // Ensure it's at least minimum lot
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   calculatedLot = MathMax(minLot, calculatedLot);
   
   return NormalizeDouble(calculatedLot, 2);
}

void UpdateWinLossStreak(double tradeProfit)
{
   if(tradeProfit > 0.0)
   {
      // Winning trade
      consecutiveWins++;
      consecutiveLosses = 0; // Reset loss streak
      
      // Safety: reset after max wins to lock in profits
      if(consecutiveWins >= MaxConsecutiveWins)
      {
         Print("Leverage reset: Max consecutive wins (", MaxConsecutiveWins, ") reached. Locking profits.");
         consecutiveWins = 0;
      }
   }
   else if(tradeProfit < 0.0)
   {
      // Losing trade
      consecutiveLosses++;
      consecutiveWins = 0; // Reset win streak
      
      // Safety: reset after max losses to prevent excessive risk
      if(consecutiveLosses >= MaxConsecutiveLosses)
      {
         Print("Leverage reset: Max consecutive losses (", MaxConsecutiveLosses, ") reached. Reducing risk.");
         consecutiveLosses = 0;
      }
   }
   // If profit == 0, don't change streaks (breakeven)
}

void ResetWinLossStreak()
{
   consecutiveWins = 0;
   consecutiveLosses = 0;
   Print("Win/Loss streak reset");
}

bool OpenTrade(int direction, double lotSize, bool isRecovery)
{
   if(direction == 0 || lotSize <= 0.0)
      return false;
   
   double price = (direction == 1) ? currentAsk : currentBid;
   double sl = 0.0;
   double tp = 0.0;
   
   string comment = "HyperTick_" + (direction == 1 ? "BUY" : "SELL");
   if(isRecovery)
      comment += "_REC";
   
   ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   bool sent = false;
   if(orderType == ORDER_TYPE_BUY)
      sent = trade.Buy(lotSize, _Symbol, 0.0, sl, tp, comment);
   else
      sent = trade.Sell(lotSize, _Symbol, 0.0, sl, tp, comment);
   
   if(sent)
   {
      ulong ticket = 0;
      // Get position ticket - try ResultPosition first, if not available use ResultDeal
      ticket = trade.ResultDeal();
      if(ticket > 0)
      {
         // Get position ID from deal
         if(HistoryDealSelect(ticket))
         {
            ticket = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
         }
      }
      
      // If still no ticket, try to find position by symbol and magic
      if(ticket == 0)
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong posTicket = PositionGetTicket(i);
            if(posTicket > 0 && PositionSelectByTicket(posTicket))
            {
               if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
                  PositionGetInteger(POSITION_MAGIC) == MagicNumber)
               {
                  ticket = posTicket;
                  break;
               }
            }
         }
      }
      
      if(ticket > 0 && totalActiveTrades < 10)
      {
         // Get actual entry price from position
         double actualEntryPrice = price;
         if(PositionSelectByTicket(ticket))
         {
            actualEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         }
         
         activeTrades[totalActiveTrades].ticket = ticket;
         activeTrades[totalActiveTrades].entryPrice = actualEntryPrice;
         activeTrades[totalActiveTrades].openTime = TimeCurrent();
         activeTrades[totalActiveTrades].direction = direction;
         activeTrades[totalActiveTrades].lotSize = lotSize;
         activeTrades[totalActiveTrades].isRecovery = isRecovery;
         activeTrades[totalActiveTrades].openTickTime = GetTickCount();
         totalActiveTrades++;
         
         // Set anchor if enabled and not recovery and no anchor yet
         if(UseAnchorMode && !isRecovery && anchorTicket == 0)
         {
            anchorTicket = ticket;
            anchorDirection = direction;
            anchorEntryPrice = actualEntryPrice;
            anchorOpenTime = TimeCurrent();
         }
         
         if(isRecovery)
            recoveryTradesAdded++;
         
         Print("Trade opened: ", comment, " | Lot: ", lotSize, " | Ticket: ", ticket);
         return true;
      }
   }
   else
   {
      Print("Trade open failed: ", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
   }
   
   return false;
}

// =====================================================================================================
// TRADE MANAGEMENT
// =====================================================================================================

void ManageActiveTrades()
{
   for(int i = totalActiveTrades - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket == 0)
         continue;
      
      if(!PositionSelectByTicket(activeTrades[i].ticket))
      {
         // Position closed externally
         RemoveTrade(i);
         continue;
      }
      
      // Compute hold time for exit logic
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      int holdSeconds = (int)(TimeCurrent() - openTime);
      
      // Anchor management: if this is anchor, enforce stop-loss in pips
      if(UseAnchorMode && anchorTicket != 0 && activeTrades[i].ticket == anchorTicket)
      {
         double lossPoints = 0.0;
         if(activeTrades[i].direction == 1) // BUY
            lossPoints = (anchorEntryPrice - currentBid) / pipToPoint;
         else
            lossPoints = (currentAsk - anchorEntryPrice) / pipToPoint;
         
         if(lossPoints >= AnchorStopLossPips)
         {
            CloseTrade(i, "Anchor SL hit (" + DoubleToString(lossPoints, 1) + " pts)");
            anchorTicket = 0;
            anchorDirection = 0;
            anchorEntryPrice = 0.0;
            anchorOpenTime = 0;
            continue;
         }
      }
      
      // =====================================================================
      // Momentum reversal exit (for losing trades) - more lenient
      // =====================================================================
      if(UseMomentumReversalExit)
      {
         double profitCheck = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         // Only close on reversal if conditions are met:
         // - holdSeconds >= MomentumReversalMinHold
         // - If MomentumReversalRequireProfit: trade must be in profit and above spread threshold
         // - Otherwise, allow loss-based exit using MomentumReversalMinLossUSD
         bool allowReversal = false;
         if(holdSeconds >= MomentumReversalMinHold)
         {
            if(MomentumReversalRequireProfit)
            {
               // Require trade to be in profit above spread+MinProfitPoints
               double spreadPoints = currentSpread;
               double minProfitPoints = spreadPoints + MinProfitPoints;
               double profitPoints = 0.0;
               if(activeTrades[i].direction == 1) // BUY
                  profitPoints = (currentBid - activeTrades[i].entryPrice) / pipToPoint;
               else
                  profitPoints = (activeTrades[i].entryPrice - currentAsk) / pipToPoint;
               
               if(profitCheck > 0.0 && profitPoints >= minProfitPoints)
                  allowReversal = true;
            }
            else
            {
               // Allow loss-based exit if loss exceeds threshold
               if(profitCheck < -MomentumReversalMinLossUSD)
                  allowReversal = true;
            }
         }
         
         if(allowReversal)
         {
            bool reversal = false;
            if(activeTrades[i].direction == 1) // BUY
            {
               if(momentumDirection == -1 && consecutiveMomentumTicks >= MomentumReversalTicks)
                  reversal = true;
            }
            else if(activeTrades[i].direction == -1) // SELL
            {
               if(momentumDirection == 1 && consecutiveMomentumTicks >= MomentumReversalTicks)
                  reversal = true;
            }
            
            if(reversal)
            {
               CloseTrade(i, "Momentum reversal against trade");
               continue;
            }
         }
      }
      
      // =====================================================================
      // Loss timeout exit (safety for prolonged losses)
      // =====================================================================
      if(UseLossTimeoutExit)
      {
         double lossPoints = 0.0;
         if(activeTrades[i].direction == 1) // BUY
            lossPoints = (activeTrades[i].entryPrice - currentBid) / pipToPoint;
         else
            lossPoints = (currentAsk - activeTrades[i].entryPrice) / pipToPoint;
         
         bool overTime = (holdSeconds >= LossTimeoutMinSeconds);
         bool hardTimeout = (holdSeconds >= LossTimeoutMaxSeconds);
         bool overPips = (lossPoints >= LossTimeoutLossPips);
         bool tooManyTrades = (LossTimeoutApplyWhen3Trades && totalActiveTrades >= 3);
         
         if((overTime && overPips) || hardTimeout || (tooManyTrades && overTime && lossPoints > 0))
         {
            CloseTrade(i, "Loss timeout safety exit");
            continue;
         }
      }
      
      if(holdSeconds >= MaxHoldSeconds)
      {
         // Check if profitable enough to close
         double profit = PositionGetDouble(POSITION_PROFIT) + 
                         PositionGetDouble(POSITION_SWAP);
         
         double spreadPoints = currentSpread;
         double minProfitPoints = spreadPoints + MinProfitPoints;
         
         // Convert profit to points
         double profitPoints = 0.0;
         if(activeTrades[i].direction == 1) // BUY
         {
            profitPoints = (currentBid - activeTrades[i].entryPrice) / pipToPoint;
         }
         else // SELL
         {
            profitPoints = (activeTrades[i].entryPrice - currentAsk) / pipToPoint;
         }
         
         // Only close if profit > spread + 1 point
         if(profitPoints >= minProfitPoints && profit > 0.0)
         {
            CloseTrade(i, "Profit target reached");
         }
         else if(profit < 0.0 && holdSeconds >= MaxHoldSeconds)
         {
            // Losing trade held too long - recovery mode will handle
            // Don't close here, let recovery mode add trades
         }
      }
      else
      {
         // Check if profit target met early
         double profit = PositionGetDouble(POSITION_PROFIT) + 
                         PositionGetDouble(POSITION_SWAP);
         
         if(profit > 0.0)
         {
            double spreadPoints = currentSpread;
            double minProfitPoints = spreadPoints + MinProfitPoints;
            
            double profitPoints = 0.0;
            if(activeTrades[i].direction == 1) // BUY
            {
               profitPoints = (currentBid - activeTrades[i].entryPrice) / pipToPoint;
            }
            else // SELL
            {
               profitPoints = (activeTrades[i].entryPrice - currentAsk) / pipToPoint;
            }
            
            if(profitPoints >= minProfitPoints)
            {
               CloseTrade(i, "Early profit target");
            }
         }
      }
   }
}

void CheckRecoveryMode()
{
   if(!RecoveryEnabled || recoveryTradesAdded >= MaxRecoveryTrades)
      return;
   
   if(currentDrawdown > MaxRecoveryDD)
      return; // Recovery stopped due to DD limit
   
   // Check if any losing trade has been open too long
   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket == 0)
         continue;
      
      if(activeTrades[i].isRecovery)
         continue; // Already a recovery trade
      
      if(!PositionSelectByTicket(activeTrades[i].ticket))
         continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT) + 
                      PositionGetDouble(POSITION_SWAP);
      
      if(profit < 0.0)
      {
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         int holdSeconds = (int)(TimeCurrent() - openTime);
         
         if(holdSeconds >= MaxHoldSeconds)
         {
            // Activate recovery - add opposite direction trade
            int recoveryDirection = -activeTrades[i].direction;
            
            if(totalActiveTrades < 10)
            {
               OpenTrade(recoveryDirection, RecoveryLotSize, true);
            }
            
            break; // Only add one recovery trade per check
         }
      }
   }
}

void CheckBasketBreakeven()
{
   if(totalActiveTrades == 0)
      return;
   
   double totalProfit = 0.0;
   
   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket == 0)
         continue;
      
      if(!PositionSelectByTicket(activeTrades[i].ticket))
         continue;
      
      totalProfit += PositionGetDouble(POSITION_PROFIT) + 
                     PositionGetDouble(POSITION_SWAP);
   }
   
   // Close all trades if basket reaches breakeven or small profit
   if(totalProfit >= BreakevenProfitUSD)
   {
      CloseAllTrades("Basket breakeven/profit target");
   }
}

void CloseTrade(int index, string reason, bool updateStreak = true)
{
   if(index < 0 || index >= totalActiveTrades)
      return;
   
   ulong ticket = activeTrades[index].ticket;
   if(ticket == 0)
      return;
   
   if(!PositionSelectByTicket(ticket))
   {
      RemoveTrade(index);
      return;
   }
   
   double profit = PositionGetDouble(POSITION_PROFIT) + 
                   PositionGetDouble(POSITION_SWAP);
   
   bool closed = trade.PositionClose(ticket);
   
   if(closed)
   {
      Print("Trade closed: ", reason, " | P&L: $", DoubleToString(profit, 2));
      
      // Update win/loss streak for individual trade (skip if called from basket close)
      if(updateStreak && reason != "Basket breakeven/profit target")
      {
         UpdateWinLossStreak(profit);
      }
      
      RemoveTrade(index);
   }
   else
   {
      Print("Close failed: ", trade.ResultRetcode(), " -> ", trade.ResultRetcodeDescription());
   }
}

void CloseAllTrades(string reason)
{
   Print("Closing all trades: ", reason);
   
   // Calculate total basket profit before closing
   double totalBasketProfit = 0.0;
   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket > 0 && PositionSelectByTicket(activeTrades[i].ticket))
      {
         totalBasketProfit += PositionGetDouble(POSITION_PROFIT) + 
                             PositionGetDouble(POSITION_SWAP);
      }
   }
   
   // Close all trades without updating streak (we'll do it once at the end)
   for(int i = totalActiveTrades - 1; i >= 0; i--)
   {
      if(activeTrades[i].ticket > 0)
      {
         CloseTrade(i, reason, false); // Don't update streak for individual trades
      }
   }
   
   // Update win/loss streak based on basket result (once for the whole basket)
   if(ResetOnBasketClose)
   {
      ResetWinLossStreak();
   }
   else
   {
      // Update streak based on total basket profit
      UpdateWinLossStreak(totalBasketProfit);
   }
   
   recoveryTradesAdded = 0;
}

void RemoveTrade(int index)
{
   if(index < 0 || index >= totalActiveTrades)
      return;
   
   for(int i = index; i < totalActiveTrades - 1; i++)
   {
      activeTrades[i] = activeTrades[i + 1];
   }
   
   totalActiveTrades--;
   activeTrades[totalActiveTrades].ticket = 0;
}

// =====================================================================================================
// DISPLAY
// =====================================================================================================

void UpdateDisplay()
{
   double basketProfit = 0.0;
   int buyTrades = 0;
   int sellTrades = 0;
   
   for(int i = 0; i < totalActiveTrades; i++)
   {
      if(activeTrades[i].ticket == 0)
         continue;
      
      if(PositionSelectByTicket(activeTrades[i].ticket))
      {
         basketProfit += PositionGetDouble(POSITION_PROFIT) + 
                        PositionGetDouble(POSITION_SWAP);
         
         if(activeTrades[i].direction == 1)
            buyTrades++;
         else
            sellTrades++;
      }
   }
   
   string status = "\n=== HyperTick HF Scalper V1.0 ===\n";
   status += "Status: ACTIVE (Long-term Automation Mode)\n";
   status += "Tick Speed: " + DoubleToString(ticksPerSecond, 2) + " ticks/sec";
   if(UseTickSpeedCheck && ticksPerSecond > 0.0 && ticksPerSecond < TickSpeedLimit)
      status += " [LOW - Trading Skipped]";
   status += "\n";
   status += "Spread: " + DoubleToString(currentSpread, 2) + " pips";
   if(UseSpreadCheck && currentSpread > SpreadLimit)
      status += " [HIGH - Trading Skipped]";
   status += "\n";
   status += "Speed Check: " + (UseTickSpeedCheck ? "ON" : "OFF");
   status += " | Spread Check: " + (UseSpreadCheck ? "ON" : "OFF") + "\n";
   status += "Tick Buffer: " + IntegerToString(tickIndex) + " ticks";
   if(!tickBufferReady)
      status += " [INIT]";
   status += "\n";
   status += "Momentum: " + (momentumDirection == 1 ? "BULLISH" : (momentumDirection == -1 ? "BEARISH" : "NEUTRAL"));
   status += " (" + IntegerToString(consecutiveMomentumTicks) + " ticks)\n";
   status += "Entry Ready: " + (tickBufferReady ? "YES" : "NO");
   status += " | Momentum Entry: " + (UseMomentumEntry ? "ON" : "OFF");
   status += " | Pullback Entry: " + (UsePullbackEntry ? "ON" : "OFF") + "\n";
   status += "\n--- Active Trades ---\n";
   status += "Total: " + IntegerToString(totalActiveTrades) + " (BUY: " + IntegerToString(buyTrades) + ", SELL: " + IntegerToString(sellTrades) + ")\n";
   status += "Basket P&L: $" + DoubleToString(basketProfit, 2) + "\n";
   status += "Recovery Trades: " + IntegerToString(recoveryTradesAdded) + "/" + IntegerToString(MaxRecoveryTrades) + "\n";
   status += "Drawdown: " + DoubleToString(currentDrawdown, 2) + "%";
   if(currentDrawdown > MaxRecoveryDD)
      status += " [LIMIT]";
   status += "\n";
   if(UseDynamicLeverage)
   {
      status += "\n--- Leverage Strategy ---\n";
      status += "Consecutive Wins: " + IntegerToString(consecutiveWins);
      if(consecutiveWins > 0)
         status += " (Lot: " + DoubleToString(CalculateDynamicLotSize(), 2) + ")";
      status += "\n";
      status += "Consecutive Losses: " + IntegerToString(consecutiveLosses);
      if(consecutiveLosses > 0)
         status += " (Lot: " + DoubleToString(CalculateDynamicLotSize(), 2) + ")";
      status += "\n";
   }
   status += "\n--- Account ---\n";
   status += "Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n";
   status += "Equity: $" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\n";
   
   Comment(status);
}
