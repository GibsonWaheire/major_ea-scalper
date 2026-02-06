#property copyright "Copyright 2026, Hyperactive HFT Extreme"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "4.00"

#include <Trade/Trade.mqh>

CTrade trade;

// =====================================================================================================
// 1. INPUT PARAMETERS (THE "FLIPPING" CALIBRATION)
// =====================================================================================================

input group "===== EXTREME GROWTH SETTINGS ====="
input double  GrowthLotStep        = 10.0;     // Add 'BaseLot' for every $10 in account
input double  BaseLot              = 0.05;     // Starting lot for $10 (High Risk)
input double  MaxMarginUsagePct    = 85.0;     // Use up to 85% of margin (Max Aggression)
input double  TargetProfitPerBurst = 0.50;     // Target per cycle to compound
input int     MagicNumber          = 202699;

input group "===== HFT CORE (YOUR LOGIC) ====="
input double  VelocityTrigger      = 1.5;      // Points move required to trigger
input int     MinTicksPerSecond    = 3;        // Activity filter
input int     SwingPeriod          = 20;       // Your original swing period
input double  ConsolidationMax     = 2.0;      // Tight range filter

input group "===== SPREAD & NEWS PROTECTION ====="
input double  MaxSpreadForEntry    = 15.0;     // Max points allowed
input bool    UseNewsDetection     = true;     // Spread-based news detection
input double  NewsSpreadMult       = 2.5;      // Detect news by spread spike

// =====================================================================================================
// 2. INTERNAL STRUCTURES & GLOBALS (KEEPING YOUR ARCHITECTURE)
// =====================================================================================================

struct PricePoint { double price; datetime time; };
PricePoint priceHistory[100];
int priceHistoryCount = 0;

double lastTickPrice = 0;
datetime lastTickTime = 0;
int tickCount = 0;
double currentTPS = 0;
int basketDirection = 0; // 0=none, 1=BUY, -1=SELL

// =====================================================================================================
// 3. INITIALIZATION & HUD
// =====================================================================================================

int OnInit() {
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetTypeFilling(ORDER_FILLING_FOK);
    CreateHFTPanel();
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    ObjectsDeleteAll(0, "HFT_");
    Comment("");
}

// =====================================================================================================
// 4. CORE EXECUTION ENGINE
// =====================================================================================================

void OnTick() {
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    datetime now = TimeCurrent();

    // A. UPDATE HFT TRACKING
    UpdateHFTMetrics(bid, now);
    
    // B. MANAGE BASKETS (ONE-WAY ONLY)
    ManageActiveBaskets();

    // C. ENTRY LOGIC
    if(currentTPS >= MinTicksPerSecond && CheckSpreadSafe()) {
        
        // Use your original Velocity calculation logic
        double velocity = CalculateCurrentVelocity();
        
        if(MathAbs(velocity) >= VelocityTrigger) {
            int signal = (velocity > 0) ? 1 : -1;
            
            // DIRECTIONAL GUARD: Don't hedge. Build the burst.
            if(basketDirection == 0 || basketDirection == signal) {
                
                // YOUR RE-ENGINEERED LOT CALC (Prevents Rejections)
                double aggressiveLot = CalculateAggressiveLot();
                
                if(aggressiveLot >= 0.01) {
                    ExecuteHFTTrade(signal, aggressiveLot, (signal == 1 ? ask : bid));
                    basketDirection = signal;
                }
            }
        }
        
        // Update HUD with velocity
        UpdateHUD(bid, velocity);
    } else {
        UpdateHUD(bid, 0.0);
    }
    
    lastTickPrice = bid;
}

// =====================================================================================================
// 5. SURGICAL LOGIC FUNCTIONS
// =====================================================================================================

double CalculateAggressiveLot() {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    
    // Calculate lot based on your $10 step requirement
    double stepMultiplier = MathFloor(equity / GrowthLotStep);
    if(stepMultiplier < 1) stepMultiplier = 1;
    double targetLot = NormalizeDouble(BaseLot * stepMultiplier, 2);
    
    // MARGIN GUARD (Prevents "Not Enough Money" Rejection)
    double marginReq;
    if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginReq))
        marginReq = SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_INITIAL);

    double maxSafeLot = (freeMargin * (MaxMarginUsagePct / 100.0)) / marginReq;
    
    return NormalizeDouble(MathMin(targetLot, maxSafeLot), 2);
}

void UpdateHFTMetrics(double price, datetime time) {
    tickCount++;
    if(time > lastTickTime) {
        currentTPS = tickCount;
        tickCount = 0;
        lastTickTime = time;
    }
    
    // Shift and update price history
    if(priceHistoryCount < 100) {
        priceHistory[priceHistoryCount].price = price;
        priceHistory[priceHistoryCount].time = time;
        priceHistoryCount++;
    } else {
        for(int i=0; i<99; i++) priceHistory[i] = priceHistory[i+1];
        priceHistory[99].price = price;
        priceHistory[99].time = time;
    }
}

double CalculateCurrentVelocity() {
    if(priceHistoryCount < 5) return 0;
    return (priceHistory[priceHistoryCount-1].price - priceHistory[priceHistoryCount-5].price) / _Point;
}

bool CheckSpreadSafe() {
    double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
    return (spread <= MaxSpreadForEntry);
}

void ManageActiveBaskets() {
    double totalProfit = 0;
    int posCount = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            totalProfit += PositionGetDouble(POSITION_PROFIT);
            posCount++;
        }
    }

    if(posCount == 0) {
        basketDirection = 0;
        return;
    }

    // EXIT LOGIC: Target per burst
    if(totalProfit >= TargetProfitPerBurst) {
        CloseAll();
    }
}

void ExecuteHFTTrade(int dir, double lot, double price) {
    if(dir == 1) trade.Buy(lot, _Symbol, price, 0, 0, "HFT_EXTREME");
    else trade.Sell(lot, _Symbol, price, 0, 0, "HFT_EXTREME");
}

void CloseAll() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            trade.PositionClose(PositionGetTicket(i));
    }
}

// =====================================================================================================
// 6. HUD DISPLAY (YOUR VISUALS)
// =====================================================================================================

void CreateHFTPanel() {
    ObjectCreate(0, "HFT_Panel", OBJ_RECT_LABEL, 0, 0, 0);
    ObjectSetInteger(0, "HFT_Panel", OBJPROP_XDISTANCE, 20);
    ObjectSetInteger(0, "HFT_Panel", OBJPROP_YDISTANCE, 20);
    ObjectSetInteger(0, "HFT_Panel", OBJPROP_XSIZE, 200);
    ObjectSetInteger(0, "HFT_Panel", OBJPROP_YSIZE, 100);
    ObjectSetInteger(0, "HFT_Panel", OBJPROP_BGCOLOR, clrDarkBlue);
}

void UpdateHUD(double bid, double vel) {
    string msg = StringFormat("TPS: %.0f | VEL: %.1f | LOT: %.2f", currentTPS, vel, CalculateAggressiveLot());
    Comment(msg);
}
