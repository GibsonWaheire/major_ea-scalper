//+------------------------------------------------------------------+
//|  FixedLotStraddleEA_v1.mq5  v1.00                               |
//|  Fixed-Lot Buy/Sell Stop Straddle — Any Symbol M5               |
//|  Hedging account | MetaEditor build 4000+                       |
//+------------------------------------------------------------------+
//
//  STRATEGY
//  --------
//  On each new M5 bar the EA deletes its stale pending orders, then
//  brackets price with a Buy Stop (Ask + InpEntryOffset pts) and a
//  Sell Stop (Bid - InpEntryOffset pts), each carrying hard SL/TP.
//  Both legs may trigger in the same bar. Whichever leg fills rides
//  a per-position trailing stop: it arms once the trade is
//  InpTrailActivation pts in profit and then ratchets InpTrailDistance
//  pts behind price. The hard TP is a distant backstop; the trail is
//  the primary exit. Fixed lot — no martingale, no grid, no scaling.
//
//  WARNING
//  -------
//  If both legs trigger in a choppy session both fill and stop out at
//  InpStopLoss. Use InpDailyLossUSD and the session filter to cap
//  exposure.
//
//  INPUTS
//  ------
//  InpLot               Fixed lot size per order (no scaling).
//  InpEntryOffset       Points above Ask (Buy Stop) / below Bid
//                       (Sell Stop) for the pending entry price.
//  InpStopLoss          Hard SL in points from entry price.
//  InpTakeProfit        Hard TP in points from entry price (backstop;
//                       trail is the primary exit).
//  InpTrailActivation   Profit in points before the trailing SL arms.
//  InpTrailDistance     Points the trailing SL stays behind price
//                       (ratchet — never moves backward).
//  InpMaxPositions      Max concurrent open positions (both sides);
//                       new pending orders skipped at/above cap.
//  InpMaxSpread         Skip placing orders when spread > this (pts).
//  InpUseSessionFilter  When true, entries only between InpStartHour
//                       and InpEndHour (server time).
//  InpStartHour         Session start hour (server, inclusive).
//  InpEndHour           Session end hour   (server, exclusive).
//  InpDailyLossUSD      Halt new entries when EA P/L today < -value.
//                       Does not close open trades. Resets next day.
//  InpSkipMinutesAfterOpen  Skip entries N minutes after Monday open.
//  InpBasketProtectPct  Close all if basket drawdown >= X% of armed winSum.
//  InpArmingPct         Arm basket when winSum >= X% of balance (>=70% wins).
//  InpATRResumeMulti    Resume after basket pause when ATR > avg * this.
//  InpMagic             Magic number — isolates this EA's trades.
//
//+------------------------------------------------------------------+
#property copyright   "FixedLotStraddleEA v1"
#property link        ""
#property version     "1.00"
#property description "Fixed-lot Buy Stop + Sell Stop straddle scalper."
#property description "M5 bar entry | per-tick trailing stop | hedging account."
#property description "Works on any symbol: XAUUSD, NAS100, US30, etc."

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
input  int     InpTakeProfit       = 5000;   // Hard TP from entry (points)
input  int     InpMaxPositions     = 5;      // Max open positions (both sides)

sinput string  _sep1               = "─── Trail ───────────────────────";
input  int     InpTrailActivation  = 100;    // Arm trail when profit >= (points)
input  int     InpTrailDistance    = 80;     // Trail SL distance behind price (points)

sinput string  _sep2               = "─── Filters ─────────────────────";
input  int     InpMaxSpread        = 40;     // Skip entry if spread > (points)
input  bool    InpUseSessionFilter = false;  // Enable session time filter
input  int     InpStartHour        = 8;      // Session start hour (server time)
input  int     InpEndHour          = 22;     // Session end hour   (server time)

sinput string  _sep3               = "─── Risk ────────────────────────";
input  double  InpDailyLossUSD     = 50.0;  // Daily loss halt in USD
input  int     InpSkipMinutesAfterOpen = 15;// Skip N min after weekly market open

sinput string  _sep4               = "─── Basket Protection ───────────";
input  double  InpBasketProtectPct = 50.0;  // Close all if basket drawdown >= X% of armed winSum
input  double  InpArmingPct        = 8.0;   // Arm when winSum >= X% of balance (needs >=70% wins)
input  double  InpATRResumeMulti   = 1.3;   // Resume when ATR > 5-bar avg * this multiplier

sinput string  _sep5               = "─── System ──────────────────────";
input  long    InpMagic            = 20240;  // Magic number

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

datetime g_lastBarTime    = 0;
datetime g_today          = 0;
double   g_dailyClosedPnL = 0.0;
int      g_closedTodayCount = 0;

bool       g_useVirtual   = false;
SVirtOrder g_virtBuy;
SVirtOrder g_virtSell;

SVirtSL    g_virtSLs[100];
int        g_virtSLCount  = 0;

// ATR handle for basket resume
int      g_atrHandle      = INVALID_HANDLE;

// Basket protection state
double   g_tradeHistory[20];
int      g_tradeHistIdx   = 0;
int      g_tradeHistCount = 0;
bool     g_basketArmed    = false;
double   g_armedWinSum    = 0.0;
bool     g_basketPaused   = false;

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
        Alert("FixedLotStraddleEA v1: SL, TP and EntryOffset must be > 0.");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpTrailDistance >= InpTrailActivation)
        Print("WARNING: InpTrailDistance >= InpTrailActivation — trail may never lock profit.");

    long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    if(InpMaxSpread <= (int)spread)
        PrintFormat("WARNING: MaxSpread filter (%d pts) <= current spread (%d pts) — EA will never place orders.",
                    InpMaxSpread, (int)spread);

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
    CheckBrokerStopsLevel();

    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
    if(g_atrHandle == INVALID_HANDLE)
        Print("WARNING: ATR handle failed — basket ATR resume disabled.");

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
    Comment("");
}

//──────────────────────────────────────────────────────────────────
//  MAIN TICK
//──────────────────────────────────────────────────────────────────
void OnTick()
{
    // Day rollover
    datetime today = TodayMidnight();
    if(today != g_today)
    {
        g_today = today;
        RefreshDailyStats();
    }

    // Per-tick work (always runs)
    ManageVirtualOrders();
    ManageVirtualSLs();
    TrailOpenPositions();
    CheckBasketProtection();
    CheckATRResume();
    DrawPanel();

    // New-bar gate
    if(!IsNewBar()) return;

    RefreshDailyStats();
    CheckBrokerStopsLevel();
    CheckArmingCondition();

    // Cancel stale pending and virtual orders from the previous bar
    DeletePendingOrders();
    g_virtBuy.active  = false;
    g_virtSell.active = false;

    // Entry conditions
    if(g_basketPaused)         return;
    if(DailyLossBreached())    return;
    if(TooSoonAfterWeekOpen()) return;
    if(InpUseSessionFilter && !InTradingWindow()) return;
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
    g_useVirtual = (stopsLevel > 0 && (long)InpEntryOffset <= stopsLevel);
    if(g_useVirtual)
        PrintFormat("VirtualMode ON: entry offset %d pts <= broker stops level %d pts",
                    InpEntryOffset, (int)stopsLevel);
}

//──────────────────────────────────────────────────────────────────
//  PLACE BUY STOP + SELL STOP  (real pending or virtual)
//──────────────────────────────────────────────────────────────────
void PlaceStraddleOrders()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double pt  = _Point;
    double lot = NormalizeLot(InpLot);

    double bPrice = NormalizeDouble(ask + InpEntryOffset * pt, _Digits);
    double bSL    = NormalizeDouble(bPrice - InpStopLoss  * pt, _Digits);
    double bTP    = NormalizeDouble(bPrice + InpTakeProfit * pt, _Digits);

    double sPrice = NormalizeDouble(bid - InpEntryOffset * pt, _Digits);
    double sSL    = NormalizeDouble(sPrice + InpStopLoss  * pt, _Digits);
    double sTP    = NormalizeDouble(sPrice - InpTakeProfit * pt, _Digits);

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
//  MANAGE VIRTUAL PENDING ORDERS  (tick handler)
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
//  MANAGE VIRTUAL SLs  (freeze level fallback, tick handler)
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

        if(!PositionSelectByTicket(ticket))
        {
            RemoveVirtSL(i);
            continue;
        }

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
        {
            RemoveVirtSL(i);
        }
        else
        {
            bool slHit = (posType == POSITION_TYPE_BUY  && bid <= desiredSL) ||
                         (posType == POSITION_TYPE_SELL && ask >= desiredSL);
            if(slHit)
            {
                PrintFormat("VirtSL manually closing ticket=%llu (SL=%.5f unreachable)",
                            ticket, desiredSL);
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
        if(g_virtSLs[i].ticket == ticket)
        {
            g_virtSLs[i].desiredSL = sl;
            return;
        }
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
//  TRAILING STOP  (per tick, ratchet only)
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

        if(posType == POSITION_TYPE_BUY)
        {
            double profitPts = (bid - openPrice) / pt;
            if(profitPts < (double)InpTrailActivation) continue;
            newSL = NormalizeDouble(bid - InpTrailDistance * pt, _Digits);
            if(newSL > curSL) doModify = true;
        }
        else if(posType == POSITION_TYPE_SELL)
        {
            double profitPts = (openPrice - ask) / pt;
            if(profitPts < (double)InpTrailActivation) continue;
            newSL = NormalizeDouble(ask + InpTrailDistance * pt, _Digits);
            if(curSL <= 0.0 || newSL < curSL) doModify = true;
        }

        if(!doModify) continue;

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
//  COUNT OPEN POSITIONS  (direction: -1=both, 0=buy, 1=sell)
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
//  RETRY TRADE HELPERS  (3 attempts, 500 ms apart)
//──────────────────────────────────────────────────────────────────
bool RetryBuyStop(double lot, double price, double sl, double tp)
{
    for(int attempt = 1; attempt <= 3; attempt++)
    {
        if(g_trade.BuyStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "SB"))
            return true;
        PrintFormat("BuyStop attempt %d/3 failed [retcode=%u err=%d]: %s",
                    attempt, g_trade.ResultRetcode(), GetLastError(),
                    g_trade.ResultRetcodeDescription());
        if(attempt < 3) Sleep(500);
    }
    return false;
}

bool RetrySellStop(double lot, double price, double sl, double tp)
{
    for(int attempt = 1; attempt <= 3; attempt++)
    {
        if(g_trade.SellStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "SS"))
            return true;
        PrintFormat("SellStop attempt %d/3 failed [retcode=%u err=%d]: %s",
                    attempt, g_trade.ResultRetcode(), GetLastError(),
                    g_trade.ResultRetcodeDescription());
        if(attempt < 3) Sleep(500);
    }
    return false;
}

bool RetryMarketBuy(double lot, double sl, double tp)
{
    for(int attempt = 1; attempt <= 3; attempt++)
    {
        if(g_trade.Buy(lot, _Symbol, 0, sl, tp, "VB"))
            return true;
        PrintFormat("MarketBuy attempt %d/3 failed [retcode=%u err=%d]: %s",
                    attempt, g_trade.ResultRetcode(), GetLastError(),
                    g_trade.ResultRetcodeDescription());
        if(attempt < 3) Sleep(500);
    }
    return false;
}

bool RetryMarketSell(double lot, double sl, double tp)
{
    for(int attempt = 1; attempt <= 3; attempt++)
    {
        if(g_trade.Sell(lot, _Symbol, 0, sl, tp, "VS"))
            return true;
        PrintFormat("MarketSell attempt %d/3 failed [retcode=%u err=%d]: %s",
                    attempt, g_trade.ResultRetcode(), GetLastError(),
                    g_trade.ResultRetcodeDescription());
        if(attempt < 3) Sleep(500);
    }
    return false;
}

bool RetryModify(ulong ticket, double sl, double tp)
{
    for(int attempt = 1; attempt <= 3; attempt++)
    {
        if(g_trade.PositionModify(ticket, sl, tp))
            return true;
        PrintFormat("PositionModify ticket=%llu attempt %d/3 failed [retcode=%u err=%d]: %s",
                    ticket, attempt, g_trade.ResultRetcode(), GetLastError(),
                    g_trade.ResultRetcodeDescription());
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
        total += PositionGetDouble(POSITION_PROFIT)
               + PositionGetDouble(POSITION_SWAP);
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
//  TRADE TRANSACTION — record each closed trade into ring buffer
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
//  BASKET PROTECTION — check if Phase 2 should arm
//──────────────────────────────────────────────────────────────────
void CheckArmingCondition()
{
    if(g_basketArmed || g_basketPaused) return;
    if(g_tradeHistCount < 20) return;

    int    wins   = 0;
    double winSum = 0.0;
    for(int i = 0; i < 20; i++)
    {
        if(g_tradeHistory[i] > 0.0)
        {
            wins++;
            winSum += g_tradeHistory[i];
        }
    }

    bool winRateOK = (wins == 20) || (wins >= 14); // 100% or >=70% of 20
    bool winSumOK  = (winSum >= AccountInfoDouble(ACCOUNT_BALANCE) * InpArmingPct / 100.0);

    if(winRateOK && winSumOK)
    {
        g_basketArmed = true;
        g_armedWinSum = winSum;
        PrintFormat("Basket ARMED: wins=%d/20  winSum=%.2f  armThreshold=%.2f",
                    wins, winSum, AccountInfoDouble(ACCOUNT_BALANCE) * InpArmingPct / 100.0);
    }
}

//──────────────────────────────────────────────────────────────────
//  BASKET PROTECTION — Phase 2 monitor (per tick)
//──────────────────────────────────────────────────────────────────
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

//──────────────────────────────────────────────────────────────────
//  BASKET PROTECTION — close ALL EA positions and pending orders
//──────────────────────────────────────────────────────────────────
void CloseAllPositions()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!ticket) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
        if(!g_trade.PositionClose(ticket))
            PrintFormat("CloseAll failed ticket=%llu: %s",
                        ticket, g_trade.ResultRetcodeDescription());
    }
    DeletePendingOrders();
    g_virtBuy.active  = false;
    g_virtSell.active = false;
}

//──────────────────────────────────────────────────────────────────
//  BASKET PROTECTION — ATR resume check (per tick while paused)
//──────────────────────────────────────────────────────────────────
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
//  CHART COMMENT PANEL  (updated every tick)
//──────────────────────────────────────────────────────────────────
void DrawPanel()
{
    int    buyPos   = CountPositions(POSITION_TYPE_BUY);
    int    sellPos  = CountPositions(POSITION_TYPE_SELL);
    double floatPnL = FloatingPnL();
    double dailyPnL = g_dailyClosedPnL + floatPnL;
    bool   halted   = DailyLossBreached();
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

    string statusStr;
    if(g_basketPaused) statusStr = "*** PAUSED (basket fired — await ATR) ***";
    else if(halted)    statusStr = "*** HALTED (daily loss) ***";
    else if(weekSkip)  statusStr = "WEEK-OPEN SKIP";
    else               statusStr = "ACTIVE";

    string basketStr;
    if(g_basketArmed)
        basketStr = StringFormat("ARMED  winSum=%.2f  guard=-%.2f",
                                 g_armedWinSum,
                                 g_armedWinSum * InpBasketProtectPct / 100.0);
    else
        basketStr = StringFormat("Building (%d/20 trades)", g_tradeHistCount);

    Comment(StringFormat(
        "=== FixedLotStraddleEA v1.00 ===\n"
        " Buys      : %d       Sells     : %d\n"
        " Pending   : %d       VirtPend  : %d\n"
        " VirtSLs   : %d       Orders    : %s\n"
        "─────────────────────────────────\n"
        " Entry off : %d pts   SL: %d pts\n"
        " TP        : %d pts\n"
        " TrailArm  : %d pts   Dist: %d pts\n"
        "─────────────────────────────────\n"
        " Float P/L : %+.2f USD\n"
        " Closed    : %d trades today\n"
        " Daily P/L : %+.2f / limit -%.2f\n"
        "─────────────────────────────────\n"
        " Basket    : %s\n"
        "─────────────────────────────────\n"
        " Status    : %s",
        buyPos, sellPos,
        pending, virtPend,
        g_virtSLCount, g_useVirtual ? "virtual" : "real",
        InpEntryOffset, InpStopLoss,
        InpTakeProfit,
        InpTrailActivation, InpTrailDistance,
        floatPnL,
        g_closedTodayCount,
        dailyPnL, InpDailyLossUSD,
        basketStr,
        statusStr
    ));
}
//+------------------------------------------------------------------+
