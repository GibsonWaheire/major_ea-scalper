//+------------------------------------------------------------------+
//|  FVG_EA.mq5                                                      |
//|  Multi-Strategy Day Trade EA v6.00                               |
//|  M15 Entry | H4 Bias | ICT: FVG/BOS/OB/S&R | MQL5              |
//|                                                                  |
//|  Entry hierarchy:                                                |
//|   1. FVG     → 3 limit orders (level, -5p, -10p)               |
//|   2. BOS     → market order on rejection candle                 |
//|   3. S&R     → 3 limit orders (level, -5p, -10p)               |
//|   4. OB      → market order on rejection candle                 |
//|   5. Session → 3 limit orders (level, -5p, -10p)               |
//|                                                                  |
//|  Limit cancellation:                                             |
//|   - Price moves 15p away from level                             |
//|   - H4 bias flips                                               |
//|   - Session ends                                                 |
//|   - Level invalidated                                           |
//|                                                                  |
//|  Exit (v6.00):                                                   |
//|   Risk: 5% of equity per trade (dynamic lot sizing)             |
//|   TP:   Hard 1:3 R:R (TP = SL distance × 3)                    |
//|   Partial: close InpPartialClosePct% every InpPartialIntervalPips|
//|   Trail: swing-based before first partial, tight 5p after       |
//|   Min SL: InpSLPips pips floor, capped at InpATRMaxPips         |
//|   Session: entries only from 08:00 server time (no Asian session)|
//|   Works on any instrument: XAUUSD, EURUSD, GBPUSD, NAS100, etc |
//+------------------------------------------------------------------+
#property copyright "FVG EA v6"
#property version   "6.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== LOT & ENTRY ==="
input double InpRiskPct           = 5.0;  // Risk % of equity per trade (dynamic lot)
input int    InpProximityPips     = 5;    // Pips from level to trigger scan
input int    InpLimitDepth1       = 5;    // T2 limit depth into zone (pips)
input int    InpLimitDepth2       = 10;   // T3 limit depth into zone (pips)
input int    InpLimitCancelPips   = 15;   // Cancel limits if price moves X pips away

input group "=== FVG ==="
input int    InpMinFVGSize        = 3;    // Min FVG width (pips)
input double InpBodyStrength      = 0.40; // Middle candle body/range ratio
input int    InpLookbackHours     = 48;   // Hours to scan back
input int    InpFVGSLBuffer       = 3;    // Buffer beyond FVG far edge (pips)

input group "=== BOS ==="
input int    InpBOSLookback       = 40;   // M15 candles to scan
input int    InpBOSSLBuffer       = 3;    // Buffer beyond broken level (pips)

input group "=== S&R ==="
input int    InpSRLookback        = 80;   // M15 candles to scan
input int    InpSRMinTouches      = 2;    // Min touches to confirm level
input int    InpSRZonePips        = 3;    // Zone around level (pips)
input int    InpSRSLBuffer        = 3;    // Buffer beyond swing point (pips)

input group "=== ORDER BLOCK ==="
input int    InpOBLookback        = 50;   // M15 candles to scan
input int    InpOBImpulsePips     = 5;    // Min impulse to validate OB (pips)
input int    InpOBSLBuffer        = 3;    // Buffer beyond OB candle (pips)

input group "=== SESSION LEVELS ==="
input int    InpAsiaStart         = 0;    // Asia start (server hour)
input int    InpAsiaEnd           = 8;    // Asia end (server hour)
input int    InpLondonStart       = 8;    // London start (server hour)
input int    InpLondonEnd         = 16;   // London end (server hour)
input int    InpSessionSLPips     = 20;   // Fixed SL for session levels (pips)

input group "=== EXIT ==="
input int    InpSLPips            = 20;   // Minimum SL pips (floor)
input double InpATRMultiplier     = 1.5;  // ATR multiplier for SL (1.5 x ATR14)
input int    InpATRMaxPips        = 35;   // Maximum SL pips cap
input int    InpRRRatio           = 3;    // R:R ratio — TP = SL distance × this (1:3)
input int    InpPartialIntervalPips = 100; // Take partial every X pips of profit
input int    InpPartialClosePct   = 33;   // % of current volume to close at each partial
input int    InpTrailSwingBars    = 3;    // Candles each side for trail swing detection
input int    InpTightTrailPips    = 5;    // Tight trail on remainder after first partial (pips)
input int    InpInvalidPips       = 5;    // Invalidation: pips through level to cancel limits

input group "=== SESSION FILTER ==="
input int    InpTradingStart      = 8;    // Block Asian session — start trading from this hour
// InpTradingEnd removed — EA trades until midnight except Asian session

input group "=== FILTERS ==="
input int    InpMaxSpreadPips     = 3;    // Max spread (pips)
input int    InpNewsFilterMins    = 30;   // Mins to block around news

input group "=== BASKET RULES ==="
input int    InpMaxOpenTrades    = 2;    // Max open positions at once
input int    InpNoDirectionBars  = 2;    // Close if no direction after X M15 bars (0=off)

input group "=== RISK PROTECTION ==="
input double InpMaxDrawdownPct    = 10.0;  // Max account drawdown % before EA stops
input double InpMaxDailyLossPct   = 5.0;   // Max daily loss % before EA stops

input group "=== MAGIC ==="
input long   InpMagicNumber       = 20240105;

//+------------------------------------------------------------------+
//| ENUMS & STRUCTS                                                  |
//+------------------------------------------------------------------+
enum ENUM_BIAS  { BIAS_BULL, BIAS_BEAR, BIAS_NONE };
enum ENUM_SETUP { SETUP_NONE, SETUP_FVG, SETUP_BOS, SETUP_SR,
                  SETUP_OB,   SETUP_SESSION };
struct SetupZone
{
    double      level;
    double      stopLoss;     // Calculated SL price
    double      slPips;       // SL distance in pips (for R calculation)
    bool        isBullish;
    bool        isValid;
    ENUM_SETUP  type;
};

struct TradeState
{
    ulong    ticket;
    int      index;
    double   entryPrice;
    double   stopLoss;           // Current SL price
    int      partialsCount;      // Number of partials taken so far
    double   nextPartialTarget;  // Price level of next partial
    bool     allPartialsDone;    // True when position too small for more partials
    datetime openTime;
};

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
CTrade      Trade;
SetupZone   ActiveSetup;
TradeState  Trades[3];
bool        SetupActive    = false;
bool        TradeFired     = false;
bool        LimitsPlaced   = false;   // Limits placed, waiting for fill
bool        T1Confirmed    = false;   // T1 showed profit on first bar close
bool        T2T3Placed     = false;   // T2/T3 limits placed
double      LimitLevel     = 0;       // The level limits were placed at
datetime    LastBarTime    = 0;
datetime    LastH4Time     = 0;
ENUM_BIAS   CachedBias     = BIAS_NONE;
double      PipSize        = 0.0001;   // 1 pip (not 1 point)
int         ATRHandle      = INVALID_HANDLE; // ATR14 indicator handle
int         BasketCount    = 0;        // Baskets taken this day
bool        HardStop       = false;     // True when risk limit breached — EA fully stops
bool        BasketClosed   = true;     // Current basket fully closed
ENUM_BIAS   LastBasketBias = BIAS_NONE; // Bias of last basket
datetime    LastDayReset   = 0;        // Last daily reset timestamp
double      DayStartEquity = 0;        // Equity at start of today
double      InitialBalance = 0;        // Balance at EA start
int         InvalidCount   = 0;       // Consecutive closes through level

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
    Trade.SetExpertMagicNumber(InpMagicNumber);
    Trade.SetDeviationInPoints(50);

    // Set filling mode — RETURN works in both tester and live
    Trade.SetTypeFilling(ORDER_FILLING_RETURN);

    InitialBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
    DayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
    LastDayReset    = TimeCurrent();

    // PipSize = 1 pip (not 1 point)
    // On 5-digit brokers: 1 pip = 0.0001 (10 points), NOT 0.00001
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    PipSize = (digits == 3 || digits == 5) ? 0.0001 : 0.001;

    // Create ATR handle once — reused every call
    ATRHandle = iATR(_Symbol, PERIOD_M15, 14);
    if(ATRHandle == INVALID_HANDLE)
        Print("WARNING: ATR handle failed — using fixed SL pips");
    else
        Print("ATR handle created OK");

    ActiveSetup.isValid = false;
    ResetTradeStates();

    Print("FVG EA v6 | ", _Symbol, " | PipSize=", PipSize,
          " | Risk=", InpRiskPct, "% equity | TP=1:", InpRRRatio, " R:R",
          " | Partials every ", InpPartialIntervalPips, "p (", InpPartialClosePct, "% each)",
          " | No-Asia mode | Trading from ", InpTradingStart, ":00");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(ATRHandle != INVALID_HANDLE) IndicatorRelease(ATRHandle);
    Print("FVG EA v5 stopped. Reason=", reason);
}

//+------------------------------------------------------------------+
//| MAIN TICK                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
    // HARD STOP — risk limit breached, EA is fully frozen
    if(HardStop)
    {
        // Still manage existing trades to SL — never leave orphan positions
        if(HasOpenTrades()) ManageTrades();
        return;
    }

    // Check risk FIRST — before sync or any other logic
    if(IsRiskBreached()) return;

    SyncFilledTrades();

    // Reset when all trades closed — immediately ready for next signal
    if((SetupActive || TradeFired || LimitsPlaced) &&
       !HasOpenTrades() && !HasPendingOrders())
    { Print("Basket fully closed — scanning for next signal."); ResetSetup(); }

    // ALL bar-based logic runs once per M15 close
    bool newBar = IsNewBar();
    if(newBar)
    {
        // Exit management — only on confirmed candle close
        if(HasOpenTrades()) ManageTrades();

        // T2/T3 placement check — only place if T1 in profit after 1 bar
        CheckT2T3Placement();

        // Limit order monitoring
        if(LimitsPlaced) CheckLimitCancellation();

        // Invalidation check
        if(SetupActive && ActiveSetup.isValid && HasOpenTrades())
            CheckInvalidation();

        // Debug scan when idle
        if(!SetupActive && !TradeFired && !LimitsPlaced)
            DebugScan();
    }

    // Outside trading session — cancel pending, no new entries
    if(!IsTradingSession())
    {
        if(LimitsPlaced) { CancelAllPending(); LimitsPlaced=false; }
        return;
    }

    if(GetSpreadPips() > InpMaxSpreadPips) return;
    if(IsNewsTime()) return;

    // Daily reset — new trading day resets basket counter
    CheckDailyReset();

    // Hard guard — do not scan if anything is active
    if(SetupActive || TradeFired || LimitsPlaced) return;
    if(HasOpenTrades() || HasPendingOrders())     return;

    // Basket rule — wait for current basket to fully close before next
    if(!BasketClosed)
    { Print("Waiting for basket to fully close."); return; }

    ENUM_BIAS bias = GetCachedH4Bias();
    if(bias == BIAS_NONE) return;

    // H4 bias must confirm same direction as last basket (if any)
    if(LastBasketBias != BIAS_NONE && bias != LastBasketBias)
    { Print("H4 bias changed — waiting for reconfirmation."); return; }

    // Entry hierarchy
    SetupZone sz;
    if(CheckFVG(bias, sz))          { PlaceEntry(sz); return; }
    if(CheckBOS(bias, sz))          { PlaceEntry(sz); return; }
    if(CheckSR(bias, sz))           { PlaceEntry(sz); return; }
    if(CheckOrderBlock(bias, sz))   { PlaceEntry(sz); return; }
    if(CheckSessionLevel(bias, sz)) { PlaceEntry(sz); return; }
}

//+------------------------------------------------------------------+
//| PLACE ENTRY — routes to limit or market based on setup type     |
//+------------------------------------------------------------------+
void PlaceEntry(SetupZone &sz)
{
    if(IsNewsTime())                       { Print("News blocked."); return; }
    if(GetSpreadPips()>InpMaxSpreadPips)   { Print("Spread wide."); return; }
    if(HasOpenTrades()||HasPendingOrders()) return;

    // Count open positions — don't exceed max concurrent
    int openCount = CountOpenTrades();
    if(openCount >= InpMaxOpenTrades)
    { Print("Max concurrent trades (",InpMaxOpenTrades,") reached."); return; }

    ActiveSetup    = sz;
    BasketClosed   = false;
    LastBasketBias = sz.isBullish ? BIAS_BULL : BIAS_BEAR;

    // T1 always fires as market order immediately
    // T2 and T3 placed as limits AFTER T1 fill is confirmed
    FireT1Market(sz);
}

//+------------------------------------------------------------------+
//| FIRE T1 AS MARKET ORDER — direction confirmation                |
//+------------------------------------------------------------------+
void FireT1Market(SetupZone &sz)
{
    string names[]={"NONE","FVG","BOS","S&R","OB","SESSION"};
    double bid     = SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double ask     = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double atrPips = GetATRSlPips();
    double slDist  = atrPips * PipSize;
    double lot     = CalcLot(atrPips);
    double sl      = sz.isBullish ? NormalizeDouble(ask - slDist, _Digits)
                                  : NormalizeDouble(bid + slDist, _Digits);
    double tp      = sz.isBullish ? NormalizeDouble(ask + InpRRRatio * slDist, _Digits)
                                  : NormalizeDouble(bid - InpRRRatio * slDist, _Digits);

    ENUM_ORDER_TYPE ot = sz.isBullish ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    string cmt = "FVG_T1";
    bool ok = Trade.PositionOpen(_Symbol, ot, lot, 0, sl, tp, cmt);

    if(ok)
    {
        TradeFired  = true;
        SetupActive = true;
        double fillPx = Trade.ResultPrice();
        Print("=== T1 MARKET [",names[sz.type],"] Bull=",sz.isBullish,
              " Fill=",fillPx," Lot=",lot," SL=",sl," TP=",tp,
              " (",DoubleToString(atrPips,1),"p SL | 1:",InpRRRatio," R:R | 5% risk)");

        // T2/T3 placed on next bar ONLY if T1 shows profit
        // See CheckT2T3Placement() called on each M15 close
        T2T3Placed  = false;
        T1Confirmed = false;
    }
    else
        Print("T1 market failed [",Trade.ResultRetcode(),"] ",
              Trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| PLACE T2 + T3 AS LIMITS AFTER T1 FILLS                         |
//| Bull: Buy Limits below T1 entry (deeper retracement)           |
//| Bear: Sell Limits above T1 entry (deeper retracement)          |
//+------------------------------------------------------------------+
void PlaceT2T3Limits(bool bull, double t1Fill, double sl)
{
    double depth1  = InpLimitDepth1 * PipSize;
    double depth2  = InpLimitDepth2 * PipSize;
    double atrPips = GetATRSlPips();
    double slDist  = atrPips * PipSize;
    double minDist = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
    double bid    = SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double ask    = SymbolInfoDouble(_Symbol,SYMBOL_ASK);

    double price2, price3, sl2, sl3;

    if(bull)
    {
        // Buy limits below T1 fill
        price2 = NormalizeDouble(t1Fill - depth1, _Digits);
        price3 = NormalizeDouble(t1Fill - depth2, _Digits);
        // SL from LIMIT PRICE (what they'll fill at) not T1 fill
        sl2    = NormalizeDouble(price2 - slDist,  _Digits);
        sl3    = NormalizeDouble(price3 - slDist,  _Digits);

        // Must be below current ask with broker minimum
        if(price2 >= ask - minDist) price2 = NormalizeDouble(ask - minDist*2 - _Point, _Digits);
        if(price3 >= ask - minDist) price3 = NormalizeDouble(ask - minDist*3 - _Point, _Digits);
        // Recalc SL after price adjustment
        sl2 = NormalizeDouble(price2 - slDist, _Digits);
        sl3 = NormalizeDouble(price3 - slDist, _Digits);

        double tp2 = NormalizeDouble(price2 + InpRRRatio * slDist, _Digits);
        double tp3 = NormalizeDouble(price3 + InpRRRatio * slDist, _Digits);
        PlaceSingleLimit(ORDER_TYPE_BUY_LIMIT,  price2, sl2, tp2, 2);
        PlaceSingleLimit(ORDER_TYPE_BUY_LIMIT,  price3, sl3, tp3, 3);
    }
    else
    {
        // Sell limits above T1 fill
        price2 = NormalizeDouble(t1Fill + depth1, _Digits);
        price3 = NormalizeDouble(t1Fill + depth2, _Digits);
        sl2    = NormalizeDouble(price2 + slDist,  _Digits);
        sl3    = NormalizeDouble(price3 + slDist,  _Digits);

        if(price2 <= bid + minDist) price2 = NormalizeDouble(bid + minDist*2 + _Point, _Digits);
        if(price3 <= bid + minDist) price3 = NormalizeDouble(bid + minDist*3 + _Point, _Digits);
        sl2 = NormalizeDouble(price2 + slDist, _Digits);
        sl3 = NormalizeDouble(price3 + slDist, _Digits);

        double tp2 = NormalizeDouble(price2 - InpRRRatio * slDist, _Digits);
        double tp3 = NormalizeDouble(price3 - InpRRRatio * slDist, _Digits);
        PlaceSingleLimit(ORDER_TYPE_SELL_LIMIT, price2, sl2, tp2, 2);
        PlaceSingleLimit(ORDER_TYPE_SELL_LIMIT, price3, sl3, tp3, 3);
    }

    LimitsPlaced = true;
    LimitLevel   = t1Fill;
    Print("T2 @ ",price2," T3 @ ",price3," (limits placed after T1 fill)");
}

bool PlaceSingleLimit(ENUM_ORDER_TYPE type, double price, double sl, double tp, int idx)
{
    double lot = CalcLot(GetATRSlPips());
    string cmt = "FVG_T" + IntegerToString(idx);
    bool res = Trade.OrderOpen(_Symbol, type, lot, 0,
                               NormalizeDouble(price,_Digits),
                               NormalizeDouble(sl,_Digits),
                               NormalizeDouble(tp,_Digits),
                               ORDER_TIME_GTC, 0, cmt);
    if(!res) Print("Limit T",idx," failed [",Trade.ResultRetcode(),"] ",
                   Trade.ResultRetcodeDescription());
    else     Print("Limit T",idx," placed @ ",NormalizeDouble(price,_Digits),
                   " TP=",NormalizeDouble(tp,_Digits)," Lot=",lot);
    return res;
}

//+------------------------------------------------------------------+
//| CHECK LIMIT CANCELLATION CONDITIONS (runs on each new bar)      |
//+------------------------------------------------------------------+
void CheckLimitCancellation()
{
    if(!LimitsPlaced) return;

    double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double away = InpLimitCancelPips * PipSize;

    bool cancel = false;
    string reason = "";

    // 1. Price moved 15 pips away from level
    double dist = MathAbs((ActiveSetup.isBullish ? bid : ask) - LimitLevel);
    if(dist > away)
    { cancel=true; reason="Price moved "+DoubleToString(dist/PipSize,1)+"p from level"; }

    // 2. H4 bias flipped
    ENUM_BIAS cur = GetH4Bias();
    if((ActiveSetup.isBullish && cur==BIAS_BEAR) ||
       (!ActiveSetup.isBullish && cur==BIAS_BULL))
    { cancel=true; reason="H4 bias flipped"; }

    // 3. Price closed through level (invalidation)
    double cl[]; ArraySetAsSeries(cl,true);
    if(CopyClose(_Symbol,PERIOD_M15,1,1,cl)>=1)
    {
        double invDist = InpInvalidPips*PipSize;
        if(ActiveSetup.isBullish  && cl[0]<ActiveSetup.level-invDist)
        { cancel=true; reason="Price closed through bull level"; }
        if(!ActiveSetup.isBullish && cl[0]>ActiveSetup.level+invDist)
        { cancel=true; reason="Price closed through bear level"; }
    }

    if(cancel)
    {
        Print("Cancelling limits: ", reason);
        CancelAllPending();
        LimitsPlaced = false;
        ResetSetup();
    }
}

//+------------------------------------------------------------------+
//| SYNC NEW FILLS (limits or markets)                               |
//+------------------------------------------------------------------+
void SyncFilledTrades()
{
    for(int i=0; i<PositionsTotal(); i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;

        string cmt = PositionGetString(POSITION_COMMENT);
        int    idx = GetTradeIndex(cmt);
        if(idx<1||idx>3) continue;

        bool found=false;
        for(int t=0;t<3;t++) if(Trades[t].ticket==ticket){found=true;break;}
        if(found) continue;

        int slot=idx-1;
        Trades[slot].ticket             = ticket;
        Trades[slot].index              = idx;
        Trades[slot].entryPrice         = PositionGetDouble(POSITION_PRICE_OPEN);
        Trades[slot].stopLoss           = PositionGetDouble(POSITION_SL);
        Trades[slot].partialsCount      = 0;
        Trades[slot].nextPartialTarget  = 0;
        Trades[slot].allPartialsDone    = false;
        Trades[slot].openTime           = TimeCurrent();

        bool   bull    = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
        double entry   = Trades[slot].entryPrice;
        // ATR-based SL — adapts to current volatility
        double atrPips = GetATRSlPips();
        double slDist  = atrPips * PipSize;
        Print("T",idx," ATR SL = ",DoubleToString(atrPips,1),"p");

        // SL: fixed pips from entry price (not from current bid/ask)
        double slPx = bull ? entry - slDist : entry + slDist;
        slPx = NormalizeDouble(slPx, _Digits);

        // Enforce broker minimum stop distance from current price
        double minDist = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
        double bid     = SymbolInfoDouble(_Symbol,SYMBOL_BID);
        double ask     = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
        if(bull  && (bid-slPx) < minDist) slPx = bid - minDist - _Point;
        if(!bull && (slPx-ask) < minDist) slPx = ask + minDist + _Point;
        slPx = NormalizeDouble(slPx, _Digits);

        // Hard 1:R TP on the position (overrides any TP set at entry for limit fills)
        double tpPx = bull ? NormalizeDouble(entry + InpRRRatio * slDist, _Digits)
                           : NormalizeDouble(entry - InpRRRatio * slDist, _Digits);
        if(Trade.PositionModify(ticket, slPx, tpPx))
        {
            Trades[slot].stopLoss = slPx;
            double actualPips = MathAbs(entry-slPx)/PipSize;
            double tpPips     = MathAbs(tpPx-entry)/PipSize;
            Print("T",idx," SL=",slPx," (",DoubleToString(actualPips,1),"p)",
                  " TP=",tpPx," (",DoubleToString(tpPips,1),"p | 1:",InpRRRatio," R:R)");
        }

        // Partial targets: every InpPartialIntervalPips from entry
        double intervalDist            = InpPartialIntervalPips * PipSize;
        Trades[slot].partialsCount     = 0;
        Trades[slot].allPartialsDone   = false;
        Trades[slot].nextPartialTarget = bull
            ? entry + intervalDist
            : entry - intervalDist;
        Print("T",idx," First partial @ ",
              NormalizeDouble(Trades[slot].nextPartialTarget,_Digits),
              " (+",InpPartialIntervalPips,"p), then every ",
              InpPartialIntervalPips,"p | ",InpPartialClosePct,"% closed each time");

        // First fill — activate setup and count basket
        if(!SetupActive)
        {
            SetupActive = true;
            BasketCount++;
            Print("Basket ",BasketCount," opened.");
        }
    }
}

//+------------------------------------------------------------------+
//| CHECK T2/T3 PLACEMENT                                            |
//| After T1 fills, wait 1 M15 bar. If T1 is in profit → place     |
//| T2/T3 limits. If T1 is flat or losing → cancel idea, don't     |
//| average into a loser.                                           |
//+------------------------------------------------------------------+
void CheckT2T3Placement()
{
    // Only relevant if T1 filled but T2/T3 not yet placed
    if(!SetupActive || T2T3Placed || !HasOpenTrades()) return;

    // Find T1 position
    ulong t1Ticket = 0;
    double t1Entry = 0;
    bool   bull    = false;

    for(int t=0; t<3; t++)
    {
        if(Trades[t].ticket==0) continue;
        if(Trades[t].index==1)
        {
            t1Ticket = Trades[t].ticket;
            t1Entry  = Trades[t].entryPrice;
            if(PositionSelectByTicket(t1Ticket))
                bull = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
            break;
        }
    }
    if(t1Ticket==0) return;

    // Check T1 profit using last closed candle
    double cls[]; ArraySetAsSeries(cls,true);
    if(CopyClose(_Symbol,PERIOD_M15,1,1,cls)<1) return;
    double closePx   = cls[0];
    double profitPips = bull ? (closePx-t1Entry)/PipSize
                             : (t1Entry-closePx)/PipSize;

    if(profitPips >= 2.0) // T1 showing at least 2 pips profit
    {
        T1Confirmed = true;
        T2T3Placed  = true;
        double atrPips = GetATRSlPips();
        double sl1 = bull ? t1Entry - atrPips*PipSize
                          : t1Entry + atrPips*PipSize;
        PlaceT2T3Limits(bull, t1Entry, NormalizeDouble(sl1,_Digits));
        Print("T1 confirmed (+",DoubleToString(profitPips,1),"p) — T2/T3 placed.");
    }
    else if(profitPips < -2.0) // T1 losing — abort T2/T3
    {
        T2T3Placed = true; // mark as handled so we don't keep checking
        Print("T1 not confirmed (",DoubleToString(profitPips,1),"p) — T2/T3 cancelled.");
    }
}

//+------------------------------------------------------------------+
//| FIND LAST M15 SWING FOR TRAILING                                 |
//| bull=true  → find swing LOW  below current price (trail above) |
//| bull=false → find swing HIGH above current price (trail below) |
//+------------------------------------------------------------------+
double GetTrailSwing(bool bull)
{
    int lookback = 40;
    int strength = InpTrailSwingBars;
    double hi[], lo[];
    ArraySetAsSeries(hi, true);
    ArraySetAsSeries(lo, true);

    if(CopyHigh(_Symbol,PERIOD_M15,1,lookback,hi)<lookback) return 0;
    if(CopyLow (_Symbol,PERIOD_M15,1,lookback,lo)<lookback) return 0;

    double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);

    if(bull)
    {
        // Most recent swing low below current bid
        for(int i=strength; i<lookback-strength; i++)
        {
            bool isSwing=true;
            for(int j=1;j<=strength;j++)
                if(lo[i]>=lo[i-j]||lo[i]>=lo[i+j]){isSwing=false;break;}
            if(!isSwing) continue;
            if(lo[i] < bid) // below current price
                return NormalizeDouble(lo[i] - 2*PipSize, _Digits); // 2p buffer
        }
    }
    else
    {
        // Most recent swing high above current ask
        for(int i=strength; i<lookback-strength; i++)
        {
            bool isSwing=true;
            for(int j=1;j<=strength;j++)
                if(hi[i]<=hi[i-j]||hi[i]<=hi[i+j]){isSwing=false;break;}
            if(!isSwing) continue;
            if(hi[i] > ask)
                return NormalizeDouble(hi[i] + 2*PipSize, _Digits);
        }
    }
    return 0;
}

//+------------------------------------------------------------------+
//| MANAGE TRADES                                                    |
//|                                                                  |
//| Fixed 20p SL at entry — set on fill, never widened             |
//|                                                                  |
//| Trail: on every M15 close, SL moves to last M15 swing          |
//|   (only moves in profit direction — never back)                 |
//|                                                                  |
//| Partial: when price closes beyond entry + 1.5R                  |
//|   → close 75%, SL stays at last swing (already trailed there)  |
//|                                                                  |
//| Losing trade: SL only, zero interference                        |
//|                                                                  |
//| ALL decisions use previous M15 candle close — never live tick   |
//+------------------------------------------------------------------+
void ManageTrades()
{
    // Use last closed M15 candle for all profit checks
    double prevClose[]; ArraySetAsSeries(prevClose,true);
    if(CopyClose(_Symbol,PERIOD_M15,1,1,prevClose)<1) return;
    double closePx = prevClose[0];

    for(int t=0; t<3; t++)
    {
        if(Trades[t].ticket==0) continue;
        if(!PositionSelectByTicket(Trades[t].ticket)) continue;

        double openPx  = PositionGetDouble(POSITION_PRICE_OPEN);
        double curSL   = PositionGetDouble(POSITION_SL);
        double bid     = SymbolInfoDouble(_Symbol,SYMBOL_BID);
        double ask     = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
        ENUM_POSITION_TYPE pt =
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        bool bull = (pt==POSITION_TYPE_BUY);

        double minDist = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;

        // ── TRAILING ─────────────────────────────────────────────────
        // Before partial: trail by M15 swing structure
        // After partial:  tight 5p trail to lock profit aggressively
        double newSL = 0;

        if(Trades[t].partialsCount == 0)
        {
            // Swing-based trail — before first partial
            double swingSL = GetTrailSwing(bull);
            if(swingSL != 0)
            {
                bool canMove = bull ? (swingSL > curSL + _Point)
                                    : (swingSL < curSL - _Point);
                if(bull  && swingSL >= openPx) canMove = false;
                if(!bull && swingSL <= openPx) canMove = false;
                if(canMove) newSL = swingSL;
            }
        }
        else
        {
            // TIGHT trail after partial — lock profit, 5p behind price
            double tightDist = InpTightTrailPips * PipSize;
            double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
            double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
            if(bull)  newSL = NormalizeDouble(bid - tightDist, _Digits);
            else      newSL = NormalizeDouble(ask + tightDist, _Digits);

            // Only move forward, never back
            bool canMove = bull ? (newSL > curSL + _Point)
                                : (newSL < curSL - _Point);
            if(!canMove) newSL = 0;
        }

        if(newSL != 0)
        {
            // Preserve existing TP when moving SL
            double curTP = PositionGetDouble(POSITION_TP);
            if(Trade.PositionModify(Trades[t].ticket, newSL, curTP))
            {
                Trades[t].stopLoss = newSL;
                Print("T",Trades[t].index," Trail → ",newSL,
                      (Trades[t].partialsCount > 0) ? " (tight 5p)" : " (swing)");
            }
        }

        // ── NO DIRECTION EXIT ────────────────────────────────────────
        // If trade open X bars and price hasn't moved meaningfully
        // in our direction — close it. Prevents dead money.
        if(InpNoDirectionBars > 0 && Trades[t].partialsCount == 0)
        {
            int barsOpen = (int)((TimeCurrent() - Trades[t].openTime) / 900);
            if(barsOpen >= InpNoDirectionBars)
            {
                // Only close if price is NOT moving in our direction
                // "No direction" = profit less than 5 pips after X bars
                double profitPips = bull
                    ? (closePx - openPx) / PipSize
                    : (openPx - closePx) / PipSize;

                if(profitPips < 5.0) // less than 5 pips profit after X bars
                {
                    Print("T",Trades[t].index," no direction after ",barsOpen,
                          " bars (profit=",DoubleToString(profitPips,1),
                          "p) — closing.");
                    Trade.PositionClose(Trades[t].ticket);
                    Trades[t].ticket = 0;
                    continue;
                }
            }
        }

        // ── INTERVAL PARTIALS: close InpPartialClosePct% every InpPartialIntervalPips ──
        if(!Trades[t].allPartialsDone && Trades[t].nextPartialTarget != 0)
        {
            bool partialHit = bull ? (closePx >= Trades[t].nextPartialTarget)
                                   : (closePx <= Trades[t].nextPartialTarget);
            if(partialHit)
            {
                double vol  = PositionGetDouble(POSITION_VOLUME);
                double step = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
                double minV = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
                double cVol = MathFloor(vol * (InpPartialClosePct / 100.0) / step) * step;
                if(cVol < minV) cVol = minV;
                if(cVol >= vol) cVol = MathFloor((vol - minV) / step) * step;

                if(cVol >= minV)
                {
                    bool ok = Trade.PositionClosePartial(Trades[t].ticket, cVol);
                    if(!ok) { Sleep(200); ok = Trade.PositionClosePartial(Trades[t].ticket, minV); }
                    if(ok)
                    {
                        Trades[t].partialsCount++;
                        double profPips = MathAbs(closePx - openPx) / PipSize;
                        Print("T",Trades[t].index," PARTIAL #",Trades[t].partialsCount,
                              " (",InpPartialClosePct,"% → ",cVol," lots) @ +",
                              DoubleToString(profPips,1),"p (+",InpPartialIntervalPips,
                              "p interval)");
                        // Advance to next partial level
                        double intervalDist = InpPartialIntervalPips * PipSize;
                        Trades[t].nextPartialTarget = bull
                            ? Trades[t].nextPartialTarget + intervalDist
                            : Trades[t].nextPartialTarget - intervalDist;
                    }
                    else
                    {
                        // Volume too small for another partial — stop trying
                        Trades[t].allPartialsDone = true;
                        Print("T",Trades[t].index," partial failed — position too small, done.");
                    }
                }
                else
                {
                    // Lot below broker minimum — no more partials possible
                    Trades[t].allPartialsDone = true;
                    Print("T",Trades[t].index," volume below min lot — partial chain done.");
                }
            }
        }

        // ── LOSING TRADE: SL only, zero interference ─────────────────
    }
}

//+------------------------------------------------------------------+
//| INVALIDATION                                                     |
//+------------------------------------------------------------------+
void CheckInvalidation()
{
    if(!ActiveSetup.isValid) return;

    // Get last 2 closed M15 candles
    double cl[]; ArraySetAsSeries(cl,true);
    if(CopyClose(_Symbol,PERIOD_M15,1,2,cl)<2) return;

    double invDist=InpInvalidPips*PipSize;

    // Check if this candle closes through level
    bool closedThrough =
        (ActiveSetup.isBullish  && cl[0]<ActiveSetup.level-invDist) ||
        (!ActiveSetup.isBullish && cl[0]>ActiveSetup.level+invDist);

    if(closedThrough)
    {
        InvalidCount++;
        Print("Invalidation warning ",InvalidCount,"/2 | level=",
              ActiveSetup.level," close=",cl[0]);
    }
    else
    {
        // Reset counter if price recovers
        if(InvalidCount>0)
        {
            Print("Invalidation reset — price recovered.");
            InvalidCount=0;
        }
    }

    // Only close trades after 2 CONSECUTIVE closes through level
    if(InvalidCount>=2)
    {
        Print("2 consecutive closes through level — cancelling limits only.");
        CancelAllPending();
        // Open trades run to SL — no forced close
        LimitsPlaced=false;
        TradeFired=HasOpenTrades(); // keep true if trades still open
        ActiveSetup.isValid=false;
        InvalidCount=0;
        return;
    }

    // H4 bias flip — cancel pending limits, open trades run to SL
    ENUM_BIAS b=GetH4Bias();
    if((ActiveSetup.isBullish&&b==BIAS_BEAR)||
       (!ActiveSetup.isBullish&&b==BIAS_BULL))
    {
        Print("H4 flip — cancelling limits, open trades run to SL.");
        CancelAllPending();
        LimitsPlaced=false;
        TradeFired=HasOpenTrades();
        ActiveSetup.isValid=false;
    }
}

//+------------------------------------------------------------------+
//| H4 BIAS                                                          |
//+------------------------------------------------------------------+
ENUM_BIAS GetH4Bias()
{
    int lookback=80;
    double h4Hi[],h4Lo[],h4Op[],h4Cl[];
    ArraySetAsSeries(h4Hi,true); ArraySetAsSeries(h4Lo,true);
    ArraySetAsSeries(h4Op,true); ArraySetAsSeries(h4Cl,true);

    if(CopyHigh (_Symbol,PERIOD_H4,1,lookback,h4Hi)<lookback) return BIAS_NONE;
    if(CopyLow  (_Symbol,PERIOD_H4,1,lookback,h4Lo)<lookback) return BIAS_NONE;
    if(CopyOpen (_Symbol,PERIOD_H4,1,lookback,h4Op)<lookback) return BIAS_NONE;
    if(CopyClose(_Symbol,PERIOD_H4,1,lookback,h4Cl)<lookback) return BIAS_NONE;

    double sH[3],sL[3]; int hc=0,lc=0;
    for(int i=1;i<lookback-1&&(hc<3||lc<3);i++)
    {
        if(hc<3&&h4Hi[i]>h4Hi[i-1]&&h4Hi[i]>h4Hi[i+1]) sH[hc++]=h4Hi[i];
        if(lc<3&&h4Lo[i]<h4Lo[i-1]&&h4Lo[i]<h4Lo[i+1]) sL[lc++]=h4Lo[i];
    }
    if(hc>=2&&lc>=2)
    {
        if(sH[0]>sH[1]&&sL[0]>sL[1]) return BIAS_BULL;
        if(sH[0]<sH[1]&&sL[0]<sL[1]) return BIAS_BEAR;
    }

    int bull=0,bear=0;
    for(int i=0;i<3;i++) (h4Cl[i]>h4Op[i])?bull++:bear++;
    if(bull>bear) return BIAS_BULL;
    if(bear>bull) return BIAS_BEAR;
    return BIAS_NONE;
}

ENUM_BIAS GetCachedH4Bias()
{
    datetime t[]; ArraySetAsSeries(t,true);
    if(CopyTime(_Symbol,PERIOD_H4,0,1,t)<1) return CachedBias;
    if(t[0]!=LastH4Time)
    {
        LastH4Time=t[0]; CachedBias=GetH4Bias();
        Print("H4 Bias: ",(CachedBias==BIAS_BULL)?"BULL":
              (CachedBias==BIAS_BEAR)?"BEAR":"NONE");
    }
    return CachedBias;
}

//+------------------------------------------------------------------+
//| GET ATR-BASED SL DISTANCE                                        |
//| Uses ATR14 on M15 to measure current volatility                 |
//| SL = max(InpSLPips, ATR * multiplier), capped at InpATRMaxPips  |
//+------------------------------------------------------------------+
double GetATRSlPips()
{
    // Use persistent handle created in OnInit
    if(ATRHandle == INVALID_HANDLE)
    {
        // Try to recreate if lost
        ATRHandle = iATR(_Symbol, PERIOD_M15, 14);
        if(ATRHandle == INVALID_HANDLE)
        {
            Print("ATR unavailable — using fixed SL: ", InpSLPips, "p");
            return InpSLPips;
        }
    }

    double atr[];
    ArraySetAsSeries(atr, true);

    // Need at least 2 bars of data
    if(CopyBuffer(ATRHandle, 0, 1, 3, atr) < 3)
    {
        Print("ATR data not ready — using fixed SL: ", InpSLPips, "p");
        return InpSLPips;
    }

    double atrPips = atr[0] / PipSize;
    double slPips  = atrPips * InpATRMultiplier;

    // Floor and cap
    slPips = MathMax(slPips, (double)InpSLPips);
    slPips = MathMin(slPips, (double)InpATRMaxPips);

    return NormalizeDouble(slPips, 1);
}

//+------------------------------------------------------------------+
//| CALC LOT — 5% equity risk based on SL distance                  |
//| Works on any instrument: forex, gold, indices, etc.             |
//+------------------------------------------------------------------+
double CalcLot(double slPips)
{
    if(slPips <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskMoney = equity * InpRiskPct / 100.0;
    double slDist    = slPips * PipSize;
    double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickVal <= 0 || tickSize <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    // slMoney = cost of SL distance per 1 lot
    double slMoney = (slDist / tickSize) * tickVal;
    if(slMoney <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double lot  = riskMoney / slMoney;
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(step <= 0) step = 0.01;
    lot = MathFloor(lot / step) * step;
    lot = MathMax(lot, minL);
    lot = MathMin(lot, maxL);
    return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| NORMALISE SL — enforce min distance AND pip floor               |
//+------------------------------------------------------------------+
double NormaliseSL(bool bull, double sl)
{
    double minBroker = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
    double bid       = SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double ask       = SymbolInfoDouble(_Symbol,SYMBOL_ASK);

    // Cap: SL cannot be more than InpSLPips from current price
    if(bull)
    {
        double maxSL = ask - InpSLPips*PipSize;
        if(sl < maxSL) sl = maxSL;
        if((ask-sl) < minBroker) sl = ask-minBroker-_Point;
    }
    else
    {
        double maxSL = bid + InpSLPips*PipSize;
        if(sl > maxSL) sl = maxSL;
        if((sl-bid) < minBroker) sl = bid+minBroker+_Point;
    }
    return NormalizeDouble(sl, _Digits);
}

//+------------------------------------------------------------------+
//| 1. FVG — LIMIT ENTRY                                            |
//+------------------------------------------------------------------+
bool CheckFVG(ENUM_BIAS bias, SetupZone &sz)
{
    int lookback=InpLookbackHours*4+10;
    double hi[],lo[],op[],cl[]; datetime tm[];
    ArraySetAsSeries(hi,true);  ArraySetAsSeries(lo,true);
    ArraySetAsSeries(op,true);  ArraySetAsSeries(cl,true);
    ArraySetAsSeries(tm,true);

    if(CopyHigh (_Symbol,PERIOD_M15,1,lookback,hi)<lookback) return false;
    if(CopyLow  (_Symbol,PERIOD_M15,1,lookback,lo)<lookback) return false;
    if(CopyOpen (_Symbol,PERIOD_M15,1,lookback,op)<lookback) return false;
    if(CopyClose(_Symbol,PERIOD_M15,1,lookback,cl)<lookback) return false;
    if(CopyTime (_Symbol,PERIOD_M15,1,lookback,tm)<lookback) return false;

    double bid   = SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double ask   = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double minSz = InpMinFVGSize*PipSize;
    double prox  = InpProximityPips*PipSize;
    double buf   = InpFVGSLBuffer*PipSize;
    datetime cut = TimeCurrent()-(datetime)(InpLookbackHours*3600);

    for(int i=0;i<lookback-2;i++)
    {
        if(tm[i+1]<cut) break;

        double gH=0,gL=0; bool bull=false;
        if(bias==BIAS_BULL&&hi[i+2]<lo[i])
            {gL=hi[i+2];gH=lo[i];bull=true;}
        else if(bias==BIAS_BEAR&&lo[i+2]>hi[i])
            {gH=lo[i+2];gL=hi[i];}

        if(gH==0||gL==0) continue;
        if((gH-gL)<minSz) continue;
        double body=MathAbs(cl[i+1]-op[i+1]);
        double rng=hi[i+1]-lo[i+1];
        if(rng<=0||body/rng<InpBodyStrength) continue;

        // Price approaching within proximity — place limits
        bool approaching = bull ? (bid<=gH+prox && bid>gH)   // above gap, approaching
                                 : (ask>=gL-prox && ask<gL);  // below gap, approaching
        // OR already at the gap edge
        bool atEdge = bull ? (bid>=gL && bid<=gH)
                           : (ask>=gL && ask<=gH);

        if(!approaching && !atEdge) continue;

        double sl=NormaliseSL(bull, bull ? gL-buf : gH+buf);
        sz.level=bull?gL:gH; sz.stopLoss=sl;
        sz.isBullish=bull; sz.isValid=true;
        sz.type=SETUP_FVG;
        Print("SETUP FVG | Bull=",bull," Gap=[",gL,"-",gH,"] SL=",sl);
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| 2. BOS — MARKET ENTRY on rejection                              |
//+------------------------------------------------------------------+
bool CheckBOS(ENUM_BIAS bias, SetupZone &sz)
{
    int lookback=InpBOSLookback+10;
    double hi[],lo[],cl[];
    ArraySetAsSeries(hi,true);ArraySetAsSeries(lo,true);ArraySetAsSeries(cl,true);

    if(CopyHigh (_Symbol,PERIOD_M15,1,lookback,hi)<lookback) return false;
    if(CopyLow  (_Symbol,PERIOD_M15,1,lookback,lo)<lookback) return false;
    if(CopyClose(_Symbol,PERIOD_M15,1,lookback,cl)<lookback) return false;

    double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double prox=InpProximityPips*PipSize;
    double buf=InpBOSSLBuffer*PipSize;

    if(bias==BIAS_BULL)
    {
        for(int i=2;i<InpBOSLookback-1;i++)
        {
            if(hi[i]<=hi[i-1]||hi[i]<=hi[i+1]) continue;
            double level=hi[i];
            bool broken=false;
            for(int j=1;j<i;j++) if(cl[j]>level){broken=true;break;}
            if(!broken) continue;
            if(bid>level-prox&&bid<level+prox*3&&lo[0]<level&&cl[0]>level)
            {
                double sl=NormaliseSL(true,level-buf);
                sz.level=level;sz.stopLoss=sl;
                sz.isBullish=true;sz.isValid=true;
                sz.type=SETUP_BOS;
                Print("SETUP BOS Bull | Level=",level," SL=",sl);
                return true;
            }
        }
    }
    else
    {
        for(int i=2;i<InpBOSLookback-1;i++)
        {
            if(lo[i]>=lo[i-1]||lo[i]>=lo[i+1]) continue;
            double level=lo[i];
            bool broken=false;
            for(int j=1;j<i;j++) if(cl[j]<level){broken=true;break;}
            if(!broken) continue;
            if(ask<level+prox&&ask>level-prox*3&&hi[0]>level&&cl[0]<level)
            {
                double sl=NormaliseSL(false,level+buf);
                sz.level=level;sz.stopLoss=sl;
                sz.isBullish=false;sz.isValid=true;
                sz.type=SETUP_BOS;
                Print("SETUP BOS Bear | Level=",level," SL=",sl);
                return true;
            }
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| 3. S&R — LIMIT ENTRY                                            |
//+------------------------------------------------------------------+
bool CheckSR(ENUM_BIAS bias, SetupZone &sz)
{
    int lookback=InpSRLookback;
    double hi[],lo[],cl[];
    ArraySetAsSeries(hi,true);ArraySetAsSeries(lo,true);ArraySetAsSeries(cl,true);

    if(CopyHigh (_Symbol,PERIOD_M15,1,lookback,hi)<lookback) return false;
    if(CopyLow  (_Symbol,PERIOD_M15,1,lookback,lo)<lookback) return false;
    if(CopyClose(_Symbol,PERIOD_M15,1,lookback,cl)<lookback) return false;

    double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double prox=InpProximityPips*PipSize;
    double zone=InpSRZonePips*PipSize;
    double buf=InpSRSLBuffer*PipSize;

    double levels[50];int touches[50];bool isSup[50];int cnt=0;
    for(int i=1;i<lookback-1&&cnt<50;i++)
    {
        double level=0;bool sup=false;
        if(hi[i]>hi[i-1]&&hi[i]>hi[i+1])     {level=hi[i];sup=false;}
        else if(lo[i]<lo[i-1]&&lo[i]<lo[i+1]) {level=lo[i];sup=true;}
        if(level==0) continue;
        int tc=0;
        for(int j=0;j<lookback;j++)
            if(MathAbs(hi[j]-level)<zone||MathAbs(lo[j]-level)<zone) tc++;
        if(tc>=InpSRMinTouches)
            {levels[cnt]=level;touches[cnt]=tc;isSup[cnt]=sup;cnt++;}
    }

    for(int k=0;k<cnt;k++)
    {
        double level=levels[k];bool sup=isSup[k];
        if(bias==BIAS_BULL&&!sup) continue;
        if(bias==BIAS_BEAR&&sup)  continue;

        // Price approaching the level
        bool approaching=false;
        if(bias==BIAS_BULL) approaching=(bid<=level+prox*3&&bid>=level-prox);
        else                approaching=(ask>=level-prox*3&&ask<=level+prox);
        if(!approaching) continue;

        if(bias==BIAS_BULL)
        {
            double swLo=level;
            for(int j=0;j<20&&j<lookback;j++) if(lo[j]<swLo) swLo=lo[j];
            double sl=NormaliseSL(true,swLo-buf);
            sz.level=level;sz.stopLoss=sl;
            sz.isBullish=true;sz.isValid=true;
            sz.type=SETUP_SR;
            Print("SETUP S&R Support | Level=",level," T=",touches[k]," SL=",sl);
            return true;
        }
        else
        {
            double swHi=level;
            for(int j=0;j<20&&j<lookback;j++) if(hi[j]>swHi) swHi=hi[j];
            double sl=NormaliseSL(false,swHi+buf);
            sz.level=level;sz.stopLoss=sl;
            sz.isBullish=false;sz.isValid=true;
            sz.type=SETUP_SR;
            Print("SETUP S&R Resist | Level=",level," T=",touches[k]," SL=",sl);
            return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| 4. ORDER BLOCK — MARKET ENTRY                                   |
//+------------------------------------------------------------------+
bool CheckOrderBlock(ENUM_BIAS bias, SetupZone &sz)
{
    int lookback=InpOBLookback;
    double hi[],lo[],op[],cl[];
    ArraySetAsSeries(hi,true);ArraySetAsSeries(lo,true);
    ArraySetAsSeries(op,true);ArraySetAsSeries(cl,true);

    if(CopyHigh (_Symbol,PERIOD_M15,1,lookback,hi)<lookback) return false;
    if(CopyLow  (_Symbol,PERIOD_M15,1,lookback,lo)<lookback) return false;
    if(CopyOpen (_Symbol,PERIOD_M15,1,lookback,op)<lookback) return false;
    if(CopyClose(_Symbol,PERIOD_M15,1,lookback,cl)<lookback) return false;

    double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double prox=InpProximityPips*PipSize;
    double minImp=InpOBImpulsePips*PipSize;
    double buf=InpOBSLBuffer*PipSize;

    for(int i=1;i<lookback-3;i++)
    {
        if(bias==BIAS_BULL)
        {
            if(cl[i]>=op[i]) continue;
            if((cl[i-1]-op[i])<minImp) continue;
            double obHi=hi[i],obLo=lo[i];
            if(bid>=obLo-prox&&bid<=obHi+prox&&lo[0]<obLo&&cl[0]>obLo)
            {
                double sl=NormaliseSL(true,obLo-buf);
                sz.level=obLo;sz.stopLoss=sl;
                sz.isBullish=true;sz.isValid=true;
                sz.type=SETUP_OB;
                Print("SETUP OB Bull | Zone=[",obLo,"-",obHi,"] SL=",sl);
                return true;
            }
        }
        else
        {
            if(cl[i]<=op[i]) continue;
            if((op[i]-cl[i-1])<minImp) continue;
            double obHi=hi[i],obLo=lo[i];
            if(ask>=obLo-prox&&ask<=obHi+prox&&hi[0]>obHi&&cl[0]<obHi)
            {
                double sl=NormaliseSL(false,obHi+buf);
                sz.level=obHi;sz.stopLoss=sl;
                sz.isBullish=false;sz.isValid=true;
                sz.type=SETUP_OB;
                Print("SETUP OB Bear | Zone=[",obLo,"-",obHi,"] SL=",sl);
                return true;
            }
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| 5. SESSION HIGH/LOW — LIMIT ENTRY                               |
//+------------------------------------------------------------------+
bool CheckSessionLevel(ENUM_BIAS bias, SetupZone &sz)
{
    MqlDateTime now; TimeToStruct(TimeCurrent(),now);
    int curHour=now.hour;
    int sessStart=InpAsiaStart,sessEnd=InpAsiaEnd;
    if(curHour>=InpLondonEnd)
        {sessStart=InpLondonStart;sessEnd=InpLondonEnd;}
    else if(curHour>=InpAsiaEnd)
        {sessStart=InpAsiaStart;sessEnd=InpAsiaEnd;}

    int lookback=100;
    double hi[],lo[];datetime tm[];
    ArraySetAsSeries(hi,true);ArraySetAsSeries(lo,true);ArraySetAsSeries(tm,true);

    if(CopyHigh(_Symbol,PERIOD_M15,1,lookback,hi)<lookback) return false;
    if(CopyLow (_Symbol,PERIOD_M15,1,lookback,lo)<lookback) return false;
    if(CopyTime(_Symbol,PERIOD_M15,1,lookback,tm)<lookback) return false;

    double sHi=0,sLo=DBL_MAX;
    for(int i=0;i<lookback;i++)
    {
        MqlDateTime cdt;TimeToStruct(tm[i],cdt);
        if(cdt.hour>=sessStart&&cdt.hour<sessEnd)
        {
            if(hi[i]>sHi) sHi=hi[i];
            if(lo[i]<sLo) sLo=lo[i];
        }
    }
    if(sHi==0||sLo==DBL_MAX) return false;

    double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double prox=InpProximityPips*PipSize;
    double fixSL=InpSessionSLPips*PipSize;

    if(bias==BIAS_BULL&&bid>=sLo-prox&&bid<=sLo+prox*3)
    {
        double sl=NormaliseSL(true,sLo-fixSL);
        sz.level=sLo;sz.stopLoss=sl;
        sz.isBullish=true;sz.isValid=true;
        sz.type=SETUP_SESSION;
        Print("SETUP Session Low | Level=",sLo," SL=",sl);
        return true;
    }
    if(bias==BIAS_BEAR&&ask<=sHi+prox&&ask>=sHi-prox*3)
    {
        double sl=NormaliseSL(false,sHi+fixSL);
        sz.level=sHi;sz.stopLoss=sl;
        sz.isBullish=false;sz.isValid=true;
        sz.type=SETUP_SESSION;
        Print("SETUP Session High | Level=",sHi," SL=",sl);
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| SESSION TRADING FILTER (London + NY only)                       |
//+------------------------------------------------------------------+
bool IsTradingSession()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
    // Block Asian session only (00:00 - 08:00 server time)
    // Trade London + NY + any other time outside Asia
    return(dt.hour >= InpTradingStart); // InpTradingStart=8 blocks 00:00-07:59
}

//+------------------------------------------------------------------+
//| DEBUG SCAN                                                       |
//+------------------------------------------------------------------+
void DebugScan()
{
    ENUM_BIAS bias=GetCachedH4Bias();
    string bs=(bias==BIAS_BULL)?"BULL":(bias==BIAS_BEAR)?"BEAR":"NONE";
    MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);
    bool inSess=IsTradingSession();

    Print("--- SCAN | ",TimeToString(TimeCurrent()),
          " | Bias=",bs,
          " | Spread=",DoubleToString(GetSpreadPips(),1),
          " | Session=",inSess," | Hour=",dt.hour,
          " | Bid=",DoubleToString(SymbolInfoDouble(_Symbol,SYMBOL_BID),5));

    if(!inSess||bias==BIAS_NONE||
       GetSpreadPips()>InpMaxSpreadPips||IsNewsTime()) return;

    SetupZone dbg;
    Print("  FVG=",  CheckFVG(bias,dbg)          ?"FOUND":"none",
          " BOS=",   CheckBOS(bias,dbg)           ?"FOUND":"none",
          " S&R=",   CheckSR(bias,dbg)            ?"FOUND":"none",
          " OB=",    CheckOrderBlock(bias,dbg)    ?"FOUND":"none",
          " SESS=",  CheckSessionLevel(bias,dbg)  ?"FOUND":"none");
}

//+------------------------------------------------------------------+
//| DAILY RESET — resets basket counter at session start            |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
    MqlDateTime now; TimeToStruct(TimeCurrent(), now);
    MqlDateTime last; TimeToStruct(LastDayReset, last);

    // New trading day = hour just crossed InpTradingStart
    if(now.day != last.day && now.hour >= InpTradingStart)
    {
        int oldCount   = BasketCount;
        BasketCount    = 0;
        BasketClosed   = true;
        LastBasketBias = BIAS_NONE;
        DayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        LastDayReset   = TimeCurrent();
        // Daily loss resets on new day — but NOT hard stop (drawdown)
        // HardStop from drawdown requires manual EA restart
        Print("=== NEW DAY RESET | Baskets reset 0 | Day equity=",
              DoubleToString(DayStartEquity,2),
              " | Yesterday baskets=",oldCount);
    }
}

//+------------------------------------------------------------------+
//| RISK PROTECTION — equity drawdown and daily loss check          |
//+------------------------------------------------------------------+
bool IsRiskBreached()
{
    // Already hard stopped — stay stopped
    if(HardStop) return true;

    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

    // Max overall drawdown — FULL STOP, never trades again until restart
    double drawdownPct = (InitialBalance - equity) / InitialBalance * 100.0;
    if(drawdownPct >= InpMaxDrawdownPct)
    {
        HardStop = true;
        Print("=== HARD STOP: Drawdown ",DoubleToString(drawdownPct,1),
              "% >= ",InpMaxDrawdownPct,
              "% — EA fully stopped. Restart EA to resume.");
        CancelAllPending();
        // Do NOT close open trades — let SL handle them naturally
        // Closing at market during drawdown often makes it worse
        ResetSetup();
        return true;
    }

    // Max daily loss — blocks new trades today only, resets tomorrow
    double dailyLossPct = (DayStartEquity - equity) / DayStartEquity * 100.0;
    if(dailyLossPct >= InpMaxDailyLossPct)
    {
        Print("=== DAILY LOSS LIMIT ",DoubleToString(dailyLossPct,1),
              "% >= ",InpMaxDailyLossPct,
              "% — no new trades today. Resets tomorrow.");
        CancelAllPending();
        ResetSetup();
        return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| NEWS FILTER                                                      |
//+------------------------------------------------------------------+
bool IsNewsTime()
{
    MqlCalendarValue values[];
    datetime from=TimeCurrent()-InpNewsFilterMins*60;
    datetime to  =TimeCurrent()+InpNewsFilterMins*60;
    string bCcy=SymbolInfoString(_Symbol,SYMBOL_CURRENCY_BASE);
    string qCcy=SymbolInfoString(_Symbol,SYMBOL_CURRENCY_PROFIT);
    if(CalendarValueHistory(values,from,to,NULL,NULL)>0)
    {
        for(int i=0;i<ArraySize(values);i++)
        {
            MqlCalendarEvent ev;
            if(!CalendarEventById(values[i].event_id,ev)) continue;
            if(ev.importance!=CALENDAR_IMPORTANCE_HIGH)   continue;
            MqlCalendarCountry c;
            if(!CalendarCountryById(ev.country_id,c))     continue;
            if(c.currency==bCcy||c.currency==qCcy)        return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime t[];ArraySetAsSeries(t,true);
    if(CopyTime(_Symbol,PERIOD_M15,0,1,t)<1) return false;
    if(t[0]!=LastBarTime){LastBarTime=t[0];return true;}
    return false;
}

double GetSpreadPips()
{
    return(SymbolInfoDouble(_Symbol,SYMBOL_ASK)-
           SymbolInfoDouble(_Symbol,SYMBOL_BID))/PipSize;
}

bool HasOpenTrades()
{
    for(int i=0;i<PositionsTotal();i++)
    {
        ulong t=PositionGetTicket(i);
        if(PositionSelectByTicket(t)&&
           PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) return true;
    }
    return false;
}

int CountOpenTrades()
{
    int count=0;
    for(int i=0;i<PositionsTotal();i++)
    {
        ulong t=PositionGetTicket(i);
        if(PositionSelectByTicket(t)&&
           PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) count++;
    }
    return count;
}

bool HasPendingOrders()
{
    for(int i=0;i<OrdersTotal();i++)
    {
        ulong t=OrderGetTicket(i);
        if(OrderSelect(t)&&
           OrderGetInteger(ORDER_MAGIC)==InpMagicNumber) return true;
    }
    return false;
}

void CancelAllPending()
{
    for(int i=OrdersTotal()-1;i>=0;i--)
    {
        ulong t=OrderGetTicket(i);
        if(OrderSelect(t)&&
           OrderGetInteger(ORDER_MAGIC)==InpMagicNumber)
            Trade.OrderDelete(t);
    }
}

void CloseAllTrades()
{
    for(int i=PositionsTotal()-1;i>=0;i--)
    {
        ulong t=PositionGetTicket(i);
        if(PositionSelectByTicket(t)&&
           PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
            Trade.PositionClose(t);
    }
}

int GetTradeIndex(string comment)
{
    if(StringFind(comment,"FVG_T1")>=0) return 1;
    if(StringFind(comment,"FVG_T2")>=0) return 2;
    if(StringFind(comment,"FVG_T3")>=0) return 3;
    return 0;
}

void ResetSetup()
{
    ActiveSetup.isValid = false;
    SetupActive         = false;
    TradeFired          = false;
    LimitsPlaced        = false;
    LimitLevel          = 0;
    BasketClosed        = true;
    T2T3Placed          = false;
    T1Confirmed         = false;
    ResetTradeStates();


}

void ResetTradeStates()
{
    for(int t=0;t<3;t++)
    {
        Trades[t].ticket             = 0;
        Trades[t].index              = 0;
        Trades[t].entryPrice         = 0;
        Trades[t].stopLoss           = 0;
        Trades[t].partialsCount      = 0;
        Trades[t].nextPartialTarget  = 0;
        Trades[t].allPartialsDone    = false;
        Trades[t].openTime           = 0;
    }
    InvalidCount=0;
}
//+------------------------------------------------------------------+