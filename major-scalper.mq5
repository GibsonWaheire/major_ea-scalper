//+------------------------------------------------------------------+
//|  SCALPER_EA.mq5                                                  |
//|  Pure Price Action Scalper — Forex Majors Only                  |
//|  M5 Entry | M15 Trend Filter | MQL5                             |
//|                                                                  |
//|  Entry: All 3 must agree:                                       |
//|   1. Velocity  — 3 M5 candles same direction, >5p total        |
//|   2. Momentum  — strong body candle closing near high/low       |
//|   3. Breakout  — price breaks 10-bar high or low               |
//|                                                                  |
//|  Exit:                                                           |
//|   TP: Dynamic 1.5x ATR5 (typically 6-12 pips)                  |
//|   SL: Fixed 8 pips                                              |
//|   Trail: After 50% TP → SL moves to entry+1p                   |
//|                                                                  |
//|  Protection:                                                     |
//|   Max 5 consecutive losses → pause 1 hour                       |
//|   Max spread 2 pips                                             |
//|   News filter 30 mins                                           |
//+------------------------------------------------------------------+
#property copyright "Scalper EA v1"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== LOT & RISK ==="
input double InpLotSize          = 0.1;   // Lot size
input int    InpSLPips           = 8;     // Stop loss (pips)
input double InpTPMultiplier     = 1.5;   // TP = ATR x this multiplier
input int    InpATRPeriod        = 5;     // ATR period for dynamic TP

input group "=== ENTRY FILTERS ==="
input int    InpVelocityPips     = 5;     // Min total move for velocity (pips)
input int    InpBreakoutBars     = 10;    // Bars to look back for breakout level
input double InpBodyStrength     = 0.60;  // Min body/range ratio for momentum
input int    InpMaxSpreadPips    = 2;     // Max spread allowed (pips)

input group "=== PROTECTION ==="
input int    InpMaxConsecLosses  = 5;     // Pause after X consecutive losses
input int    InpPauseMinutes     = 60;    // Pause duration in minutes
input int    InpNewsFilterMins   = 30;    // Mins to block around news

input group "=== MAGIC ==="
input long   InpMagicNumber      = 20250101;

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
CTrade    Trade;
double    PipSize        = 0.0001;
int       ATRHandle      = INVALID_HANDLE;
int       ConsecLosses   = 0;
datetime  PauseUntil     = 0;
ulong     OpenTicket     = 0;
double    EntryPrice     = 0;
double    TradeTP        = 0;
bool      TrailActivated = false;
bool      PositionOpen   = false;
datetime  LastBarTime    = 0;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
    Trade.SetExpertMagicNumber(InpMagicNumber);
    Trade.SetDeviationInPoints(30);
    Trade.SetTypeFilling(ORDER_FILLING_RETURN);

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    PipSize = (digits == 3 || digits == 5) ? 0.0001 : 0.001;

    ATRHandle = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
    if(ATRHandle == INVALID_HANDLE)
    { Print("ATR handle failed"); return INIT_FAILED; }

    Print("Scalper EA | ",_Symbol," | PipSize=",PipSize);
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(ATRHandle != INVALID_HANDLE) IndicatorRelease(ATRHandle);
    Print("Scalper EA stopped. Reason=",reason);
}

//+------------------------------------------------------------------+
//| MAIN TICK                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
    // Manage open trade every tick
    if(PositionOpen) ManageTrade();

    // New bar logic
    bool newBar = IsNewBar();
    if(!newBar) return;

    // Sync position state
    SyncPosition();

    // Check for closed trade — update consecutive loss counter
    CheckTradeResult();

    // Blocked?
    if(IsPaused())    return;
    if(PositionOpen)  return;
    if(IsNewsTime())  return;
    if(GetSpread() > InpMaxSpreadPips) return;

    // Get M15 trend direction
    int trend = GetM15Trend();
    if(trend == 0) return; // no clear trend

    // Check all 3 entry conditions
    bool velOk  = CheckVelocity(trend);
    bool momOk  = CheckMomentum(trend);
    bool brkOk  = CheckBreakout(trend);

    if(velOk && momOk && brkOk)
        ExecuteTrade(trend);
}

//+------------------------------------------------------------------+
//| GET M15 TREND — direction of last closed M15 candle             |
//+------------------------------------------------------------------+
int GetM15Trend()
{
    double op[], cl[];
    ArraySetAsSeries(op, true);
    ArraySetAsSeries(cl, true);

    if(CopyOpen (_Symbol,PERIOD_M15,1,3,op)<3) return 0;
    if(CopyClose(_Symbol,PERIOD_M15,1,3,cl)<3) return 0;

    // Majority of last 3 M15 candles
    int bull=0, bear=0;
    for(int i=0;i<3;i++)
        (cl[i]>op[i]) ? bull++ : bear++;

    if(bull>bear) return  1; // bullish
    if(bear>bull) return -1; // bearish
    return 0;
}

//+------------------------------------------------------------------+
//| VELOCITY — last 3 M5 candles same direction, total > X pips    |
//+------------------------------------------------------------------+
bool CheckVelocity(int trend)
{
    double op[], cl[];
    ArraySetAsSeries(op, true);
    ArraySetAsSeries(cl, true);

    if(CopyOpen (_Symbol,PERIOD_M5,1,3,op)<3) return false;
    if(CopyClose(_Symbol,PERIOD_M5,1,3,cl)<3) return false;

    // All 3 candles same direction
    for(int i=0;i<3;i++)
    {
        bool candleBull = cl[i] > op[i];
        if(trend== 1 && !candleBull) return false;
        if(trend==-1 &&  candleBull) return false;
    }

    // Total move > InpVelocityPips
    double totalMove = MathAbs(cl[0] - op[2]) / PipSize;
    return (totalMove >= InpVelocityPips);
}

//+------------------------------------------------------------------+
//| MOMENTUM — last closed M5 candle strong body, closes near edge  |
//+------------------------------------------------------------------+
bool CheckMomentum(int trend)
{
    double op[], cl[], hi[], lo[];
    ArraySetAsSeries(op, true); ArraySetAsSeries(cl, true);
    ArraySetAsSeries(hi, true); ArraySetAsSeries(lo, true);

    if(CopyOpen (_Symbol,PERIOD_M5,1,1,op)<1) return false;
    if(CopyClose(_Symbol,PERIOD_M5,1,1,cl)<1) return false;
    if(CopyHigh (_Symbol,PERIOD_M5,1,1,hi)<1) return false;
    if(CopyLow  (_Symbol,PERIOD_M5,1,1,lo)<1) return false;

    double body  = MathAbs(cl[0]-op[0]);
    double range = hi[0]-lo[0];
    if(range <= 0) return false;

    // Body strength check
    if(body/range < InpBodyStrength) return false;

    // Closes near edge: bull=top 30%, bear=bottom 30%
    double closePos = (trend==1) ? (cl[0]-lo[0])/range
                                 : (hi[0]-cl[0])/range;
    return (closePos >= 0.70);
}

//+------------------------------------------------------------------+
//| BREAKOUT — price breaks above/below last N bars high/low        |
//+------------------------------------------------------------------+
bool CheckBreakout(int trend)
{
    double hi[], lo[];
    ArraySetAsSeries(hi, true);
    ArraySetAsSeries(lo, true);

    if(CopyHigh(_Symbol,PERIOD_M5,2,InpBreakoutBars,hi)<InpBreakoutBars) return false;
    if(CopyLow (_Symbol,PERIOD_M5,2,InpBreakoutBars,lo)<InpBreakoutBars) return false;

    double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);

    if(trend == 1)
    {
        // Find highest high in lookback
        double highest = hi[ArrayMaximum(hi,0,InpBreakoutBars)];
        return (ask > highest); // price broke above
    }
    else
    {
        // Find lowest low in lookback
        double lowest = lo[ArrayMinimum(lo,0,InpBreakoutBars)];
        return (bid < lowest); // price broke below
    }
}

//+------------------------------------------------------------------+
//| GET DYNAMIC TP FROM ATR                                          |
//+------------------------------------------------------------------+
double GetDynamicTP()
{
    double atr[];
    ArraySetAsSeries(atr, true);
    if(CopyBuffer(ATRHandle, 0, 1, 1, atr) < 1)
        return 8 * PipSize; // fallback 8 pips

    double tpPips = (atr[0] / PipSize) * InpTPMultiplier;
    tpPips = MathMax(tpPips, 5.0);   // min 5 pips
    tpPips = MathMin(tpPips, 20.0);  // max 20 pips
    return NormalizeDouble(tpPips * PipSize, _Digits);
}

//+------------------------------------------------------------------+
//| EXECUTE TRADE                                                    |
//+------------------------------------------------------------------+
void ExecuteTrade(int trend)
{
    double bid    = SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double ask    = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double slDist = InpSLPips * PipSize;
    double tpDist = GetDynamicTP();
    double sl, tp;

    ENUM_ORDER_TYPE ot;
    if(trend == 1)
    {
        ot = ORDER_TYPE_BUY;
        sl = NormalizeDouble(ask - slDist, _Digits);
        tp = NormalizeDouble(ask + tpDist, _Digits);
    }
    else
    {
        ot = ORDER_TYPE_SELL;
        sl = NormalizeDouble(bid + slDist, _Digits);
        tp = NormalizeDouble(bid - tpDist, _Digits);
    }

    // Enforce broker min stop
    double minDist = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
    if(trend== 1 && (ask-sl)<minDist) sl=ask-minDist-_Point;
    if(trend==-1 && (sl-bid)<minDist) sl=bid+minDist+_Point;

    bool ok = Trade.PositionOpen(_Symbol, ot, InpLotSize, 0, sl, tp, "SCALP");
    if(ok)
    {
        OpenTicket     = Trade.ResultDeal();
        EntryPrice     = Trade.ResultPrice();
        TradeTP        = (trend==1) ? tp : tp;
        TrailActivated = false;
        PositionOpen   = true;

        double tpPips = tpDist/PipSize;
        Print("SCALP ",trend==1?"BUY":"SELL",
              " | Fill=",EntryPrice,
              " | SL=",sl," (",InpSLPips,"p)",
              " | TP=",NormalizeDouble(tp,_Digits),
              " (",DoubleToString(tpPips,1),"p)",
              " | Consec losses=",ConsecLosses);
    }
    else
        Print("Trade failed [",Trade.ResultRetcode(),"] ",
              Trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| MANAGE OPEN TRADE — trail after 50% TP                         |
//+------------------------------------------------------------------+
void ManageTrade()
{
    if(!PositionSelectByMagic()) return;

    double openPx  = PositionGetDouble(POSITION_PRICE_OPEN);
    double curSL   = PositionGetDouble(POSITION_SL);
    double curTP   = PositionGetDouble(POSITION_TP);
    double bid     = SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double ask     = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    ENUM_POSITION_TYPE pt =
        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    bool bull = (pt==POSITION_TYPE_BUY);

    double profitPips = bull ? (bid-openPx)/PipSize
                             : (openPx-ask)/PipSize;
    double tpPips     = MathAbs(curTP-openPx)/PipSize;
    double halfTP     = tpPips * 0.5;

    // Activate trail when 50% of TP reached
    if(!TrailActivated && profitPips >= halfTP)
    {
        // Move SL to entry + 1 pip
        double minDist = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
        double newSL   = bull
            ? NormalizeDouble(openPx + PipSize, _Digits)
            : NormalizeDouble(openPx - PipSize, _Digits);

        if(bull  && (bid-newSL)<minDist) newSL=bid-minDist-_Point;
        if(!bull && (newSL-ask)<minDist) newSL=ask+minDist+_Point;

        if(Trade.PositionModify(GetOpenTicket(), NormalizeDouble(newSL,_Digits), curTP))
        {
            TrailActivated = true;
            Print("TRAIL activated @ +",DoubleToString(profitPips,1),
                  "p | SL → entry+1p");
        }
    }
}

//+------------------------------------------------------------------+
//| SYNC POSITION STATE                                              |
//+------------------------------------------------------------------+
void SyncPosition()
{
    bool found = false;
    for(int i=0;i<PositionsTotal();i++)
    {
        ulong t = PositionGetTicket(i);
        if(PositionSelectByTicket(t) &&
           PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
        { found=true; break; }
    }
    PositionOpen = found;
}

//+------------------------------------------------------------------+
//| GET OPEN TICKET                                                  |
//+------------------------------------------------------------------+
ulong GetOpenTicket()
{
    for(int i=0;i<PositionsTotal();i++)
    {
        ulong t = PositionGetTicket(i);
        if(PositionSelectByTicket(t) &&
           PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
            return t;
    }
    return 0;
}

bool PositionSelectByMagic()
{
    ulong t = GetOpenTicket();
    return (t != 0 && PositionSelectByTicket(t));
}

//+------------------------------------------------------------------+
//| CHECK LAST TRADE RESULT — update consecutive loss counter       |
//+------------------------------------------------------------------+
void CheckTradeResult()
{
    static datetime lastDealTime = 0;

    HistorySelect(TimeCurrent()-3600, TimeCurrent());
    int total = HistoryDealsTotal();

    for(int i=total-1; i>=0; i--)
    {
        ulong deal = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagicNumber) continue;
        if(HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;

        datetime dealTime = (datetime)HistoryDealGetInteger(deal,DEAL_TIME);
        if(dealTime <= lastDealTime) break;
        lastDealTime = dealTime;

        double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
        if(profit < 0)
        {
            ConsecLosses++;
            Print("Consecutive losses: ",ConsecLosses,"/",InpMaxConsecLosses);
            if(ConsecLosses >= InpMaxConsecLosses)
            {
                PauseUntil = TimeCurrent() + InpPauseMinutes*60;
                Print("=== PAUSED for ",InpPauseMinutes,
                      " mins after ",InpMaxConsecLosses," consecutive losses.");
            }
        }
        else
        {
            if(ConsecLosses > 0)
                Print("Winning trade — consecutive loss counter reset.");
            ConsecLosses = 0;
        }
        break;
    }
}

//+------------------------------------------------------------------+
//| IS PAUSED                                                        |
//+------------------------------------------------------------------+
bool IsPaused()
{
    if(PauseUntil == 0) return false;
    if(TimeCurrent() < PauseUntil)
    {
        static datetime lastPrint = 0;
        if(TimeCurrent() - lastPrint > 300) // print every 5 mins
        {
            int minsLeft = (int)((PauseUntil-TimeCurrent())/60);
            Print("Paused — ",minsLeft," mins remaining.");
            lastPrint = TimeCurrent();
        }
        return true;
    }
    PauseUntil   = 0;
    ConsecLosses = 0;
    Print("Pause ended — resuming trading.");
    return false;
}

//+------------------------------------------------------------------+
//| NEWS FILTER                                                      |
//+------------------------------------------------------------------+
bool IsNewsTime()
{
    MqlCalendarValue values[];
    datetime from = TimeCurrent()-InpNewsFilterMins*60;
    datetime to   = TimeCurrent()+InpNewsFilterMins*60;
    string bCcy = SymbolInfoString(_Symbol,SYMBOL_CURRENCY_BASE);
    string qCcy = SymbolInfoString(_Symbol,SYMBOL_CURRENCY_PROFIT);

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
//| SPREAD IN PIPS                                                   |
//+------------------------------------------------------------------+
double GetSpread()
{
    return (SymbolInfoDouble(_Symbol,SYMBOL_ASK) -
            SymbolInfoDouble(_Symbol,SYMBOL_BID)) / PipSize;
}

//+------------------------------------------------------------------+
//| NEW BAR DETECTION                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime t[]; ArraySetAsSeries(t,true);
    if(CopyTime(_Symbol,PERIOD_M5,0,1,t)<1) return false;
    if(t[0]!=LastBarTime){LastBarTime=t[0];return true;}
    return false;
}
//+------------------------------------------------------------------+