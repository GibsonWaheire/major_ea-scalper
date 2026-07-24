//+------------------------------------------------------------------+
//|  FixedLotStraddleEA_v6.mq5  v6.00                               |
//|  Fixed-Lot Buy/Sell Stop Straddle — Breakeven Loser Protection  |
//|  Hedging account | MetaEditor build 4000+                       |
//+------------------------------------------------------------------+
//
//  STRATEGY
//  --------
//  Same as v1 straddle entry. The key difference is in the exit:
//
//  When ONE leg wins (trail arms = profit >= InpTrailActivation):
//    1. The OTHER pending leg (not yet triggered) is DELETED immediately.
//    2. Any already-open opposite position has its SL moved to its own
//       entry price (breakeven ± InpBEBuffer pts).
//
//  Result: the losing leg can NEVER cost more than InpBEBuffer pts.
//  Only one leg ever takes a real loss — and that loss is capped at ~0.
//  The winner rides the trail freely.
//
//  This is Option B: let both legs open, but the moment the winner
//  proves itself, neutralise the loser at breakeven.
//
//+------------------------------------------------------------------+
#property copyright   "FixedLotStraddleEA v6"
#property link        ""
#property version     "6.00"
#property description "Straddle scalper: winner trails, loser moved to breakeven on trail arm."
#property description "M5 bar entry | hedging account | any symbol."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//──────────────────────────────────────────────────────────────────
//  INPUTS
//──────────────────────────────────────────────────────────────────
sinput string  _sep0               = "─── Entry ───────────────────────";
input  double  InpLot              = 0.05;   // Lot size (fixed)
input  int     InpEntryOffset      = 100;    // Offset from Ask/Bid (points)
input  int     InpStopLoss         = 1300;   // Hard SL from entry (points)
input  int     InpTakeProfit       = 50000;  // Hard TP (backstop — trail is primary exit)
input  int     InpMaxPositions     = 4;      // Max open positions (both sides)

sinput string  _sep1               = "─── Trail ───────────────────────";
input  int     InpTrailActivation  = 100;    // [OPT: 30–200 step 20] Arm trail when profit >= (points)
input  int     InpTrailDistance    = 20;     // [OPT: 10–60 step 10] Trail SL distance behind price (points)
input  int     InpBEBuffer         = 10;     // [OPT: 0–30 step 5] Breakeven buffer for loser (points)

sinput string  _sep1b              = "─── ATR Dynamic Mode ────────────";
input  bool    InpUseATRMode       = true;   // Scale all distances with ATR (recommended)
input  int     InpATRPeriod        = 14;     // ATR period (bars)
input  double  InpEntryATR         = 0.20;   // [OPT: 0.10–0.40 step 0.05] Entry offset = X × ATR
input  double  InpSLATR            = 2.00;   // [OPT: 1.0–3.0 step 0.5] Stop loss = X × ATR
input  double  InpTPATR            = 6.00;   // Take profit = X × ATR (backstop)
input  double  InpTrailActATR      = 0.60;   // [OPT: 0.30–1.20 step 0.15] Trail arm = X × ATR
input  double  InpTrailDistATR     = 0.40;   // [OPT: 0.10–0.60 step 0.10] Trail distance = X × ATR
input  double  InpBEBufferATR      = 0.10;   // Breakeven floor = X × ATR

sinput string  _sep_adx            = "─── ADX Chop Filter ─────────────";
input  bool    InpUseADX           = true;   // Skip straddle if ADX < MinLevel (avoids chop)
input  int     InpADXPeriod        = 14;     // ADX period (bars)
input  double  InpADXMinLevel      = 20.0;   // [OPT: 15–30 step 5] Min ADX to allow entry

sinput string  _sep2               = "─── Filters ─────────────────────";
input  int     InpMaxSpread        = 40;     // Skip entry if spread > (points)
input  bool    InpUseSessionFilter = false;  // Enable session time filter
input  int     InpStartHour        = 8;      // Session start hour (server time)
input  int     InpEndHour          = 20;     // Session end hour   (server time)

sinput string  _sep3               = "─── Risk ────────────────────────";
input  double  InpDailyLossUSD     = 100.0; // Daily loss halt in USD
input  int     InpSkipMinutesAfterOpen = 15;// Skip N min after weekly market open

sinput string  _sep4               = "─── Basket Protection ───────────";
input  double  InpBasketProtectPct = 50.0;  // Close all if basket drawdown >= X% of armed winSum
input  double  InpArmingPct        = 8.0;   // Arm when winSum >= X% of balance (needs >=70% wins)
input  double  InpATRResumeMulti   = 1.3;   // Resume when ATR > 5-bar avg * this multiplier

sinput string  _sep5               = "─── System ──────────────────────";
input  long    InpMagic            = 20246;  // Magic number

//──────────────────────────────────────────────────────────────────
//  STRUCTS
//──────────────────────────────────────────────────────────────────
struct SVirtOrder
{
    bool   active;
    double triggerPrice;
    double sl;
    double tp;
};

struct SVirtSL
{
    ulong  ticket;
    double desiredSL;
};

//──────────────────────────────────────────────────────────────────
//  GLOBALS
//──────────────────────────────────────────────────────────────────
CTrade   g_trade;

datetime g_lastBarTime      = 0;
datetime g_today            = 0;
double   g_dailyClosedPnL   = 0.0;
int      g_closedTodayCount = 0;

bool       g_useVirtual     = false;
SVirtOrder g_virtBuy;
SVirtOrder g_virtSell;

SVirtSL    g_virtSLs[100];
int        g_virtSLCount    = 0;

int      g_atrHandle        = INVALID_HANDLE;
int      g_adxHandle        = INVALID_HANDLE;

// Effective parameters — recomputed each bar (ATR mode) or fixed fallback
struct SEff
{
    int entryOffset;
    int stopLoss;
    int takeProfit;
    int trailActivation;
    int trailDistance;
    int breakevenBuffer;
};
SEff g_eff;

double   g_tradeHistory[20];
int      g_tradeHistIdx     = 0;
int      g_tradeHistCount   = 0;
bool     g_basketArmed      = false;
double   g_armedWinSum      = 0.0;
bool     g_basketPaused     = false;

//──────────────────────────────────────────────────────────────────
//  INIT
//──────────────────────────────────────────────────────────────────
int OnInit()
{
    g_trade.SetExpertMagicNumber((ulong)InpMagic);
    g_trade.SetDeviationInPoints(30);
    g_trade.SetTypeFilling(DetectFillingMode());
    g_trade.SetAsyncMode(false);

    if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
        Print("WARNING: Account is not hedging mode — both straddle legs may not open simultaneously.");

    if(InpStopLoss <= 0 || InpTakeProfit <= 0 || InpEntryOffset <= 0)
    {
        Alert("FixedLotStraddleEA v6: SL, TP and EntryOffset must be > 0.");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpTrailDistance >= InpTrailActivation)
        Print("WARNING: InpTrailDistance >= InpTrailActivation — trail may never lock profit.");

    g_virtBuy.active  = false;
    g_virtSell.active = false;
    g_virtSLCount     = 0;

    ArrayInitialize(g_tradeHistory, 0.0);
    g_tradeHistIdx   = 0;
    g_tradeHistCount = 0;
    g_basketArmed    = false;
    g_armedWinSum    = 0.0;
    g_basketPaused   = false;

    g_today = TodayMidnight();
    RefreshDailyStats();

    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
    if(g_atrHandle == INVALID_HANDLE)
        Print("WARNING: ATR handle failed — ATR mode and basket ATR resume disabled.");

    g_adxHandle = iADX(_Symbol, PERIOD_CURRENT, InpADXPeriod);
    if(g_adxHandle == INVALID_HANDLE)
        Print("WARNING: ADX handle failed — chop filter disabled.");

    CalcEffectivePts();   // init g_eff with fallback values
    CheckBrokerStopsLevel();

    if(InpUseATRMode)
        PrintFormat("ATR mode ON: entry=%.2f×  SL=%.2f×  TP=%.2f×  trail=%.2f×  dist=%.2f×  BE=%.2f×",
                    InpEntryATR, InpSLATR, InpTPATR, InpTrailActATR, InpTrailDistATR, InpBEBufferATR);
    if(InpUseADX)
        PrintFormat("ADX filter ON: period=%d  minLevel=%.1f", InpADXPeriod, InpADXMinLevel);

    PrintFormat("Init OK | symbol=%s  digits=%d  point=%.5f  magic=%lld  virtualMode=%s",
                _Symbol, _Digits, _Point, InpMagic,
                g_useVirtual ? "YES" : "NO");
    return INIT_SUCCEEDED;
}

//──────────────────────────────────────────────────────────────────
//  DEINIT
//──────────────────────────────────────────────────────────────────
void OnDeinit(const int reason)
{
    if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
    if(g_adxHandle != INVALID_HANDLE) IndicatorRelease(g_adxHandle);
    Comment("");
}

//──────────────────────────────────────────────────────────────────
//  MAIN TICK
//──────────────────────────────────────────────────────────────────
void OnTick()
{
    datetime today = TodayMidnight();
    if(today != g_today)
    {
        g_today = today;
        RefreshDailyStats();
    }

    ManageVirtualOrders();
    ManageVirtualSLs();
    TrailOpenPositions();   // ← contains breakeven-loser logic
    CheckBasketProtection();
    CheckATRResume();
    DrawPanel();

    if(!IsNewBar()) return;

    RefreshDailyStats();
    CalcEffectivePts();
    CheckBrokerStopsLevel();
    CheckArmingCondition();

    DeletePendingOrders();
    g_virtBuy.active  = false;
    g_virtSell.active = false;

    if(g_basketPaused)         return;
    if(TooSoonAfterWeekOpen()) return;
    if(InpUseSessionFilter && !InTradingWindow()) return;
    if(IsChoppy())             return;
    if(CountPositions()       >= InpMaxPositions) return;

    long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    if(spread > (long)InpMaxSpread)
    {
        PrintFormat("Skip: spread=%d > max=%d", (int)spread, InpMaxSpread);
        return;
    }

    PlaceStraddleOrders();
}

//──────────────────────────────────────────────────────────────────
//  BROKER STOPS LEVEL CHECK
//──────────────────────────────────────────────────────────────────
void CheckBrokerStopsLevel()
{
    long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    g_useVirtual = (stopsLevel > 0 && (long)g_eff.entryOffset <= stopsLevel);
    if(g_useVirtual)
        PrintFormat("VirtualMode ON: entry offset %d pts <= broker stops level %d pts",
                    g_eff.entryOffset, (int)stopsLevel);
}

//──────────────────────────────────────────────────────────────────
//  COMPUTE EFFECTIVE PARAMETERS  (ATR-scaled or fixed fallback)
//──────────────────────────────────────────────────────────────────
void CalcEffectivePts()
{
    g_eff.entryOffset     = InpEntryOffset;
    g_eff.stopLoss        = InpStopLoss;
    g_eff.takeProfit      = InpTakeProfit;
    g_eff.trailActivation = InpTrailActivation;
    g_eff.trailDistance   = InpTrailDistance;
    g_eff.breakevenBuffer = InpBEBuffer;

    if(!InpUseATRMode || g_atrHandle == INVALID_HANDLE) return;

    double atrBuf[];
    ArraySetAsSeries(atrBuf, true);
    if(CopyBuffer(g_atrHandle, 0, 1, 1, atrBuf) < 1) return;
    double atrPts = atrBuf[0] / _Point;
    if(atrPts <= 0.0) return;

    g_eff.entryOffset     = (int)MathMax(1, MathRound(InpEntryATR     * atrPts));
    g_eff.stopLoss        = (int)MathMax(1, MathRound(InpSLATR        * atrPts));
    g_eff.takeProfit      = (int)MathMax(1, MathRound(InpTPATR        * atrPts));
    g_eff.trailActivation = (int)MathMax(1, MathRound(InpTrailActATR  * atrPts));
    g_eff.trailDistance   = (int)MathMax(1, MathRound(InpTrailDistATR * atrPts));
    g_eff.breakevenBuffer = (int)MathMax(0, MathRound(InpBEBufferATR  * atrPts));
}

//──────────────────────────────────────────────────────────────────
//  ADX CHOP FILTER
//──────────────────────────────────────────────────────────────────
bool IsChoppy()
{
    if(!InpUseADX || g_adxHandle == INVALID_HANDLE) return false;
    double adxBuf[];
    ArraySetAsSeries(adxBuf, true);
    if(CopyBuffer(g_adxHandle, 0, 1, 1, adxBuf) < 1) return false;
    if(adxBuf[0] < InpADXMinLevel)
    {
        PrintFormat("Skip: ADX=%.1f < %.1f (chop)", adxBuf[0], InpADXMinLevel);
        return true;
    }
    return false;
}

//──────────────────────────────────────────────────────────────────
//  PLACE BUY STOP + SELL STOP
//──────────────────────────────────────────────────────────────────
void PlaceStraddleOrders()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double pt  = _Point;
    double lot = NormalizeLot(InpLot);

    double bPrice = NormalizeDouble(ask + g_eff.entryOffset * pt, _Digits);
    double bSL    = NormalizeDouble(bPrice - g_eff.stopLoss  * pt, _Digits);
    double bTP    = NormalizeDouble(bPrice + g_eff.takeProfit * pt, _Digits);

    double sPrice = NormalizeDouble(bid - g_eff.entryOffset * pt, _Digits);
    double sSL    = NormalizeDouble(sPrice + g_eff.stopLoss  * pt, _Digits);
    double sTP    = NormalizeDouble(sPrice - g_eff.takeProfit * pt, _Digits);

    if(g_useVirtual)
    {
        g_virtBuy.active       = true;
        g_virtBuy.triggerPrice = bPrice;
        g_virtBuy.sl           = bSL;
        g_virtBuy.tp           = bTP;

        g_virtSell.active       = true;
        g_virtSell.triggerPrice = sPrice;
        g_virtSell.sl           = sSL;
        g_virtSell.tp           = sTP;

        PrintFormat("VirtualOrders set: BuyStop@%.5f  SellStop@%.5f", bPrice, sPrice);
    }
    else
    {
        if(!RetryBuyStop(lot, bPrice, bSL, bTP))
            PrintFormat("BuyStop FAILED after 3 retries [price=%.5f SL=%.5f TP=%.5f]",
                        bPrice, bSL, bTP);
        if(!RetrySellStop(lot, sPrice, sSL, sTP))
            PrintFormat("SellStop FAILED after 3 retries [price=%.5f SL=%.5f TP=%.5f]",
                        sPrice, sSL, sTP);
    }
}

//──────────────────────────────────────────────────────────────────
//  MANAGE VIRTUAL PENDING ORDERS
//──────────────────────────────────────────────────────────────────
void ManageVirtualOrders()
{
    if(!g_useVirtual) return;

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot = NormalizeLot(InpLot);

    if(g_virtBuy.active && ask >= g_virtBuy.triggerPrice)
    {
        g_virtBuy.active = false;
        PrintFormat("VirtualBuy triggered: Ask=%.5f >= threshold=%.5f",
                    ask, g_virtBuy.triggerPrice);
        if(!RetryMarketBuy(lot, g_virtBuy.sl, g_virtBuy.tp))
            PrintFormat("VirtualBuy market order FAILED after 3 retries");
    }

    if(g_virtSell.active && bid <= g_virtSell.triggerPrice)
    {
        g_virtSell.active = false;
        PrintFormat("VirtualSell triggered: Bid=%.5f <= threshold=%.5f",
                    bid, g_virtSell.triggerPrice);
        if(!RetryMarketSell(lot, g_virtSell.sl, g_virtSell.tp))
            PrintFormat("VirtualSell market order FAILED after 3 retries");
    }
}

//──────────────────────────────────────────────────────────────────
//  MANAGE VIRTUAL SLs
//──────────────────────────────────────────────────────────────────
void ManageVirtualSLs()
{
    if(g_virtSLCount == 0) return;

    long   freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
    double ask         = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid         = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    for(int i = g_virtSLCount - 1; i >= 0; i--)
    {
        ulong  ticket    = g_virtSLs[i].ticket;
        double desiredSL = g_virtSLs[i].desiredSL;

        if(!PositionSelectByTicket(ticket)) { RemoveVirtSL(i); continue; }

        int    posType  = (int)PositionGetInteger(POSITION_TYPE);
        double curSL    = PositionGetDouble(POSITION_SL);
        double curTP    = PositionGetDouble(POSITION_TP);
        double curPrice = (posType == POSITION_TYPE_BUY) ? bid : ask;

        if(freezeLevel > 0)
        {
            double distPts = MathAbs(curPrice - curSL) / _Point;
            if(distPts <= (double)freezeLevel) continue;
        }

        if(RetryModify(ticket, desiredSL, curTP))
            RemoveVirtSL(i);
        else
        {
            bool slHit = (posType == POSITION_TYPE_BUY  && bid <= desiredSL) ||
                         (posType == POSITION_TYPE_SELL && ask >= desiredSL);
            if(slHit)
            {
                PrintFormat("VirtSL manually closing ticket=%llu (SL=%.5f unreachable)", ticket, desiredSL);
                g_trade.PositionClose(ticket);
                RemoveVirtSL(i);
            }
        }
    }
}

void AddVirtSL(ulong ticket, double sl)
{
    for(int i = 0; i < g_virtSLCount; i++)
    {
        if(g_virtSLs[i].ticket == ticket) { g_virtSLs[i].desiredSL = sl; return; }
    }
    if(g_virtSLCount < ArraySize(g_virtSLs))
    {
        g_virtSLs[g_virtSLCount].ticket    = ticket;
        g_virtSLs[g_virtSLCount].desiredSL = sl;
        g_virtSLCount++;
    }
}

void RemoveVirtSL(int idx)
{
    for(int i = idx; i < g_virtSLCount - 1; i++)
        g_virtSLs[i] = g_virtSLs[i + 1];
    g_virtSLCount--;
}

//──────────────────────────────────────────────────────────────────
//  TRAILING STOP + BREAKEVEN LOSER  (the core v6 logic)
//
//  On first trail arm:
//    - Delete the other pending leg (if not yet triggered)
//    - Move any open opposite position to breakeven ± InpBEBuffer pts
//  Winner continues to trail and ratchet.
//──────────────────────────────────────────────────────────────────
void TrailOpenPositions()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double pt  = _Point;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!ticket) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

        int    posType   = (int)PositionGetInteger(POSITION_TYPE);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double curSL     = PositionGetDouble(POSITION_SL);
        double curTP     = PositionGetDouble(POSITION_TP);
        double newSL     = 0.0;
        bool   doModify  = false;
        bool   firstArm  = false;

        if(posType == POSITION_TYPE_BUY)
        {
            double profitPts = (bid - openPrice) / pt;
            if(profitPts < (double)g_eff.trailActivation) continue;

            newSL = NormalizeDouble(bid - g_eff.trailDistance * pt, _Digits);
            if(newSL > curSL)
            {
                doModify = true;
                firstArm = (curSL < openPrice);
            }
        }
        else if(posType == POSITION_TYPE_SELL)
        {
            double profitPts = (openPrice - ask) / pt;
            if(profitPts < (double)g_eff.trailActivation) continue;

            newSL = NormalizeDouble(ask + g_eff.trailDistance * pt, _Digits);
            if(curSL <= 0.0 || newSL < curSL)
            {
                doModify = true;
                firstArm = (curSL <= 0.0 || curSL > openPrice);
            }
        }

        if(!doModify) continue;

        // ── FIRST ARM: neutralise the other leg ──────────────────
        if(firstArm)
        {
            // 1. Cancel the other pending stop order (if it hasn't triggered yet)
            DeletePendingOrders();
            if(g_virtBuy.active || g_virtSell.active)
            {
                g_virtBuy.active  = false;
                g_virtSell.active = false;
                PrintFormat("Trail armed: cancelled opposite virtual pending order");
            }

            // 2. Move any open opposite position to breakeven
            MoveOppositeToBreakeven(posType);

            PrintFormat("Trail ARMED on %s ticket=%llu | opposite leg neutralised at breakeven",
                        (posType == POSITION_TYPE_BUY) ? "BUY" : "SELL", ticket);
        }

        // ── RATCHET TRAIL ────────────────────────────────────────
        if(!RetryModify(ticket, newSL, curTP))
        {
            long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
            if(freezeLevel > 0)
            {
                PrintFormat("Trail modify rejected (freeze level), tracking VirtSL ticket=%llu SL=%.5f",
                            ticket, newSL);
                AddVirtSL(ticket, newSL);
            }
        }
    }
}

//──────────────────────────────────────────────────────────────────
//  MOVE OPPOSITE OPEN POSITION TO BREAKEVEN
//  Called once when the winner first arms its trail.
//  Loser SL is moved to its own entry ± InpBEBuffer pts.
//──────────────────────────────────────────────────────────────────
void MoveOppositeToBreakeven(int winnerType)
{
    int    loserType = (winnerType == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
    double pt        = _Point;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!ticket) continue;
        if(PositionGetString(POSITION_SYMBOL)  != _Symbol)   continue;
        if(PositionGetInteger(POSITION_MAGIC)  != InpMagic)  continue;
        if(PositionGetInteger(POSITION_TYPE)   != loserType) continue;

        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double curSL     = PositionGetDouble(POSITION_SL);
        double curTP     = PositionGetDouble(POSITION_TP);
        double newBE;
        bool   shouldMove;

        if(loserType == POSITION_TYPE_BUY)
        {
            newBE      = NormalizeDouble(openPrice + g_eff.breakevenBuffer * pt, _Digits);
            shouldMove = (curSL < newBE);
        }
        else
        {
            newBE      = NormalizeDouble(openPrice - g_eff.breakevenBuffer * pt, _Digits);
            shouldMove = (curSL <= 0.0 || curSL > newBE);
        }

        if(!shouldMove) continue;

        PrintFormat("BE-Loser: moving %s ticket=%llu SL from %.5f to %.5f (openPrice=%.5f buffer=%d)",
                    (loserType == POSITION_TYPE_BUY) ? "BUY" : "SELL",
                    ticket, curSL, newBE, openPrice, InpBEBuffer);

        if(!RetryModify(ticket, newBE, curTP))
        {
            long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
            if(freezeLevel > 0)
                AddVirtSL(ticket, newBE);
        }
    }
}

//──────────────────────────────────────────────────────────────────
//  DELETE ALL EA PENDING ORDERS
//──────────────────────────────────────────────────────────────────
void DeletePendingOrders()
{
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(!ticket) continue;
        if(OrderGetString(ORDER_SYMBOL)  != _Symbol)  continue;
        if(OrderGetInteger(ORDER_MAGIC)  != InpMagic) continue;

        ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
        if(ot != ORDER_TYPE_BUY_STOP  && ot != ORDER_TYPE_SELL_STOP &&
           ot != ORDER_TYPE_BUY_LIMIT && ot != ORDER_TYPE_SELL_LIMIT) continue;

        if(!g_trade.OrderDelete(ticket))
            PrintFormat("OrderDelete failed ticket=%llu: %s",
                        ticket, g_trade.ResultRetcodeDescription());
    }
}

//──────────────────────────────────────────────────────────────────
//  COUNT OPEN POSITIONS
//──────────────────────────────────────────────────────────────────
int CountPositions(int direction = -1)
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!ticket) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
        int posType = (int)PositionGetInteger(POSITION_TYPE);
        if(direction == -1 || direction == posType) count++;
    }
    return count;
}

//──────────────────────────────────────────────────────────────────
//  RETRY TRADE HELPERS
//──────────────────────────────────────────────────────────────────
bool RetryBuyStop(double lot, double price, double sl, double tp)
{
    for(int attempt = 1; attempt <= 3; attempt++)
    {
        if(g_trade.BuyStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "SB")) return true;
        PrintFormat("BuyStop attempt %d/3 failed [retcode=%u err=%d]: %s",
                    attempt, g_trade.ResultRetcode(), GetLastError(), g_trade.ResultRetcodeDescription());
        if(attempt < 3) Sleep(500);
    }
    return false;
}

bool RetrySellStop(double lot, double price, double sl, double tp)
{
    for(int attempt = 1; attempt <= 3; attempt++)
    {
        if(g_trade.SellStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "SS")) return true;
        PrintFormat("SellStop attempt %d/3 failed [retcode=%u err=%d]: %s",
                    attempt, g_trade.ResultRetcode(), GetLastError(), g_trade.ResultRetcodeDescription());
        if(attempt < 3) Sleep(500);
    }
    return false;
}

bool RetryMarketBuy(double lot, double sl, double tp)
{
    for(int attempt = 1; attempt <= 3; attempt++)
    {
        if(g_trade.Buy(lot, _Symbol, 0, sl, tp, "VB")) return true;
        PrintFormat("MarketBuy attempt %d/3 failed [retcode=%u err=%d]: %s",
                    attempt, g_trade.ResultRetcode(), GetLastError(), g_trade.ResultRetcodeDescription());
        if(attempt < 3) Sleep(500);
    }
    return false;
}

bool RetryMarketSell(double lot, double sl, double tp)
{
    for(int attempt = 1; attempt <= 3; attempt++)
    {
        if(g_trade.Sell(lot, _Symbol, 0, sl, tp, "VS")) return true;
        PrintFormat("MarketSell attempt %d/3 failed [retcode=%u err=%d]: %s",
                    attempt, g_trade.ResultRetcode(), GetLastError(), g_trade.ResultRetcodeDescription());
        if(attempt < 3) Sleep(500);
    }
    return false;
}

bool RetryModify(ulong ticket, double sl, double tp)
{
    for(int attempt = 1; attempt <= 3; attempt++)
    {
        if(g_trade.PositionModify(ticket, sl, tp)) return true;
        PrintFormat("PositionModify ticket=%llu attempt %d/3 failed [retcode=%u err=%d]: %s",
                    ticket, attempt, g_trade.ResultRetcode(), GetLastError(), g_trade.ResultRetcodeDescription());
        if(attempt < 3) Sleep(500);
    }
    return false;
}

//──────────────────────────────────────────────────────────────────
//  CONDITION HELPERS
//──────────────────────────────────────────────────────────────────
bool IsNewBar()
{
    datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(t == g_lastBarTime) return false;
    g_lastBarTime = t;
    return true;
}

bool InTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int h = dt.hour;
    if(InpStartHour < InpEndHour)
        return (h >= InpStartHour && h < InpEndHour);
    return (h >= InpStartHour || h < InpEndHour);
}

bool DailyLossBreached()
{
    return (g_dailyClosedPnL + FloatingPnL() < -MathAbs(InpDailyLossUSD));
}

bool TooSoonAfterWeekOpen()
{
    if(InpSkipMinutesAfterOpen <= 0) return false;
    return (TimeCurrent() - WeekMondayMidnight() < (datetime)(InpSkipMinutesAfterOpen * 60));
}

//──────────────────────────────────────────────────────────────────
//  P/L TRACKING
//──────────────────────────────────────────────────────────────────
double FloatingPnL()
{
    double total = 0.0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!ticket) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
        total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
    }
    return total;
}

void RefreshDailyStats()
{
    g_dailyClosedPnL   = 0.0;
    g_closedTodayCount = 0;

    datetime dayStart = TodayMidnight();
    if(!HistorySelect(dayStart, TimeCurrent())) return;

    int total = HistoryDealsTotal();
    for(int i = 0; i < total; i++)
    {
        ulong ticket = HistoryDealGetTicket(i);
        if(!ticket) continue;
        if(HistoryDealGetString(ticket,  DEAL_SYMBOL) != _Symbol)  continue;
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC)  != InpMagic) continue;

        ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
        if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

        g_dailyClosedPnL += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                          + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
                          + HistoryDealGetDouble(ticket, DEAL_SWAP);
        g_closedTodayCount++;
    }
}

//──────────────────────────────────────────────────────────────────
//  UTILITIES
//──────────────────────────────────────────────────────────────────
datetime TodayMidnight()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    dt.hour = dt.min = dt.sec = 0;
    return StructToTime(dt);
}

datetime WeekMondayMidnight()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int daysSinceMonday = (dt.day_of_week == 0) ? 6 : (dt.day_of_week - 1);
    dt.hour = dt.min = dt.sec = 0;
    datetime todayMidnight = StructToTime(dt);
    return todayMidnight - (datetime)(daysSinceMonday * 86400);
}

double NormalizeLot(double lot)
{
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(step <= 0.0) step = 0.01;
    lot = MathFloor(lot / step) * step;
    int decimals = 0;
    double s = step;
    while(s < 1.0 - 1e-9 && decimals < 8) { s *= 10.0; decimals++; }
    return NormalizeDouble(MathMax(minL, MathMin(maxL, lot)), decimals);
}

ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
    int mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
    if((mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
    if((mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
    return ORDER_FILLING_RETURN;
}

//──────────────────────────────────────────────────────────────────
//  TRADE TRANSACTION — ring buffer for basket protection
//──────────────────────────────────────────────────────────────────
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
    if(!HistoryDealSelect(trans.deal))           return;
    if(HistoryDealGetString(trans.deal,  DEAL_SYMBOL) != _Symbol)  return;
    if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC)  != InpMagic) return;
    if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY)  != DEAL_ENTRY_OUT) return;

    double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
               + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION)
               + HistoryDealGetDouble(trans.deal, DEAL_SWAP);

    g_tradeHistory[g_tradeHistIdx] = pnl;
    g_tradeHistIdx = (g_tradeHistIdx + 1) % 20;
    if(g_tradeHistCount < 20) g_tradeHistCount++;

    if(!g_basketArmed && !g_basketPaused)
        CheckArmingCondition();
}

//──────────────────────────────────────────────────────────────────
//  BASKET PROTECTION
//──────────────────────────────────────────────────────────────────
void CheckArmingCondition()
{
    if(g_basketArmed || g_basketPaused) return;
    if(g_tradeHistCount < 20) return;

    int    wins   = 0;
    double winSum = 0.0;
    for(int i = 0; i < 20; i++)
    {
        if(g_tradeHistory[i] > 0.0) { wins++; winSum += g_tradeHistory[i]; }
    }

    bool winRateOK = (wins == 20) || (wins >= 14);
    bool winSumOK  = (winSum >= AccountInfoDouble(ACCOUNT_BALANCE) * InpArmingPct / 100.0);

    if(winRateOK && winSumOK)
    {
        g_basketArmed = true;
        g_armedWinSum = winSum;
        PrintFormat("Basket ARMED: wins=%d/20  winSum=%.2f  armThreshold=%.2f",
                    wins, winSum, AccountInfoDouble(ACCOUNT_BALANCE) * InpArmingPct / 100.0);
    }
}

void CheckBasketProtection()
{
    if(!g_basketArmed) return;

    double floatPnL  = FloatingPnL();
    double threshold = -(g_armedWinSum * InpBasketProtectPct / 100.0);

    if(floatPnL <= threshold)
    {
        PrintFormat("Basket PROTECTION fired: floatPnL=%.2f  threshold=%.2f  armedWinSum=%.2f",
                    floatPnL, threshold, g_armedWinSum);
        CloseAllPositions();
        g_basketArmed    = false;
        g_armedWinSum    = 0.0;
        g_tradeHistCount = 0;
        g_tradeHistIdx   = 0;
        ArrayInitialize(g_tradeHistory, 0.0);
        g_basketPaused   = true;
    }
}

void CloseAllPositions()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!ticket) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
        if(!g_trade.PositionClose(ticket))
            PrintFormat("CloseAll failed ticket=%llu: %s", ticket, g_trade.ResultRetcodeDescription());
    }
    DeletePendingOrders();
    g_virtBuy.active  = false;
    g_virtSell.active = false;
}

void CheckATRResume()
{
    if(!g_basketPaused) return;
    if(g_atrHandle == INVALID_HANDLE) return;

    double atrBuf[];
    ArraySetAsSeries(atrBuf, true);
    if(CopyBuffer(g_atrHandle, 0, 1, 5, atrBuf) < 5) return;

    double atrCur = atrBuf[0];
    double atrSum = 0.0;
    for(int i = 0; i < 5; i++) atrSum += atrBuf[i];
    double atrAvg = atrSum / 5.0;

    if(atrAvg <= 0.0) return;
    if(atrCur <= atrAvg * InpATRResumeMulti) return;

    PrintFormat("ATR Resume: atr=%.0f pts > avg=%.0f pts * %.2f — entries re-enabled",
                atrCur / _Point, atrAvg / _Point, InpATRResumeMulti);
    g_basketPaused = false;
}

//──────────────────────────────────────────────────────────────────
//  CHART PANEL
//──────────────────────────────────────────────────────────────────
void DrawPanel()
{
    int    buyPos   = CountPositions(POSITION_TYPE_BUY);
    int    sellPos  = CountPositions(POSITION_TYPE_SELL);
    double floatPnL = FloatingPnL();
    double dailyPnL = g_dailyClosedPnL + floatPnL;
    bool   weekSkip = TooSoonAfterWeekOpen();

    int pending = 0;
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong t = OrderGetTicket(i);
        if(!t) continue;
        if(OrderGetString(ORDER_SYMBOL)  != _Symbol)  continue;
        if(OrderGetInteger(ORDER_MAGIC)  != InpMagic) continue;
        pending++;
    }

    int virtPend = (g_virtBuy.active ? 1 : 0) + (g_virtSell.active ? 1 : 0);

    // Live ADX value for panel
    double adxNow = 0.0;
    if(g_adxHandle != INVALID_HANDLE)
    {
        double adxBuf[]; ArraySetAsSeries(adxBuf, true);
        if(CopyBuffer(g_adxHandle, 0, 1, 1, adxBuf) >= 1) adxNow = adxBuf[0];
    }

    string statusStr;
    if(g_basketPaused) statusStr = "*** PAUSED (basket fired — await ATR) ***";
    else if(weekSkip)  statusStr = "WEEK-OPEN SKIP";
    else if(adxNow > 0 && adxNow < InpADXMinLevel)
                       statusStr = StringFormat("CHOP SKIP (ADX=%.1f < %.1f)", adxNow, InpADXMinLevel);
    else               statusStr = "ACTIVE";

    string basketStr;
    if(g_basketArmed)
        basketStr = StringFormat("ARMED  winSum=%.2f  guard=-%.2f",
                                 g_armedWinSum, g_armedWinSum * InpBasketProtectPct / 100.0);
    else
        basketStr = StringFormat("Building (%d/20 trades)", g_tradeHistCount);

    string modeStr = InpUseATRMode ? "ATR" : "fixed";

    Comment(StringFormat(
        "=== FixedLotStraddleEA v6.10 ===\n"
        " Buys      : %d       Sells     : %d\n"
        " Pending   : %d       VirtPend  : %d\n"
        " VirtSLs   : %d       Orders    : %s\n"
        "─────────────────────────────────\n"
        " Mode      : %s\n"
        " Entry off : %d pts   SL: %d pts\n"
        " TrailArm  : %d pts   Dist: %d pts\n"
        " BE Buffer : %d pts\n"
        " ADX now   : %.1f     Min: %.1f\n"
        "─────────────────────────────────\n"
        " Float P/L : %+.2f USD\n"
        " Closed    : %d trades today\n"
        " Daily P/L : %+.2f USD\n"
        "─────────────────────────────────\n"
        " Basket    : %s\n"
        "─────────────────────────────────\n"
        " Status    : %s",
        buyPos, sellPos,
        pending, virtPend,
        g_virtSLCount, g_useVirtual ? "virtual" : "real",
        modeStr,
        g_eff.entryOffset, g_eff.stopLoss,
        g_eff.trailActivation, g_eff.trailDistance,
        g_eff.breakevenBuffer,
        adxNow, InpADXMinLevel,
        floatPnL,
        g_closedTodayCount,
        dailyPnL,
        basketStr,
        statusStr
    ));
}

//──────────────────────────────────────────────────────────────────
//  ON TESTER — custom optimization criterion
//  In Strategy Tester → Optimization tab → select "Custom max"
//  Score = ProfitFactor × WinRate × sqrt(Trades) × (1 − DrawdownPct)
//──────────────────────────────────────────────────────────────────
double OnTester()
{
    double profit      = TesterStatistics(STAT_PROFIT);
    double pf          = TesterStatistics(STAT_PROFIT_FACTOR);
    double totalTrades = TesterStatistics(STAT_TRADES);
    double winTrades   = TesterStatistics(STAT_PROFIT_TRADES);
    double ddPct       = TesterStatistics(STAT_EQUITY_DD_RELATIVE);

    if(totalTrades  < 30)   return 0.0;
    if(profit       <= 0.0) return 0.0;
    if(pf           < 1.1)  return 0.0;
    if(ddPct        > 40.0) return 0.0;

    double winRate = winTrades / MathMax(totalTrades, 1.0);

    return pf
         * winRate
         * MathSqrt(totalTrades)
         * (1.0 - ddPct / 100.0);
}
//+------------------------------------------------------------------+
