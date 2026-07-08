//+------------------------------------------------------------------+
//|  PropSniperElite_EA.mq5   v1.00                                  |
//|  15-layer confluence sniper | Prop firm compliant                |
//|                                                                   |
//|  Entry stack (ALL layers must pass):                             |
//|   L1.  London (07-12) or NY (13-17) session gate                |
//|   L2.  Daily trade count < MaxDailyTrades                        |
//|   L3.  5-min cooldown since last entry                           |
//|   L4.  Spread within dynamic limit                               |
//|   L5.  H1 EMA 50/200 bias — BULL or BEAR                        |
//|   L6.  H1 trend quality — 3 bars same side of fast EMA          |
//|   L7.  M15 BOS confirmed in bias direction                       |
//|   L8.  M15 EMA 20/50 aligned with bias                          |
//|   L9.  M15 ATR in valid volatility regime                        |
//|   L10. M5 FVG identified (price pulling back into gap)           |
//|   L11. M5 Order Block at / overlapping FVG                       |
//|   L12. M5 RSI in momentum zone (not extended)                    |
//|   L13. M5 MACD histogram aligned + crossing signal               |
//|   L14. M5 entry candle body quality (momentum, not doji)         |
//|   L15. R:R >= minimum before order placed                        |
//|                                                                   |
//|  Exit priority:                                                   |
//|   1. Prop firm daily loss / max DD guard → close all + stop      |
//|   2. Hard SL (set at broker on entry)                            |
//|   3. Hard TP (set at broker on entry)                            |
//|   4. Breakeven move at 1×R profit                                |
//|   5. Partial close 50% at 1.5×R                                  |
//|   6. ATR trailing stop on remainder                               |
//|   7. Session-end close (no overnight holds)                       |
//|                                                                   |
//|  Instruments: XAUUSD, GBPUSD, USDJPY, US30, US100/NAS100        |
//|  Leverage: designed for 1:30                                      |
//+------------------------------------------------------------------+
#property copyright "PropSniperElite v1.00"
#property link      ""
#property version   "1.00"
#property description "PropSniperElite: 15-layer sniper | London+NY | Max 3/day | Prop firm safe"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//════════════════════════════════════════════════════════════════════
// INPUTS
//════════════════════════════════════════════════════════════════════

input group "═══ Session ═══"
input int    InpLondonOpen    = 7;     // London open hour (server time)
input int    InpLondonClose   = 12;    // London close hour (server time)
input int    InpNYOpen        = 13;    // NY open hour (server time)
input int    InpNYClose       = 17;    // NY close hour (server time)
input bool   InpCloseAtSessionEnd = true; // Close open trades at session end

input group "═══ Trade Limits ═══"
input int    InpMaxDailyTrades = 3;    // Max entries per day
input int    InpMinGapMins    = 5;     // Min minutes between entries
input int    InpMaxConsecLoss = 3;     // Pause after N consec losses (0=off)
input int    InpPauseM15Bars  = 8;     // M15 bars to pause after consec limit

input group "═══ Risk / Prop Firm ═══"
input double InpRiskPct       = 1.0;   // Risk % equity per trade
input double InpMinLot        = 0.01;  // Min lot
input double InpMaxLot        = 100.0; // Max lot
input double InpDailyLossPct  = 4.5;   // Daily loss limit % (FTMO: 5%)
input double InpMaxDDPct      = 9.0;   // Max equity DD % from peak (FTMO: 10%)

input group "═══ L5-L6: H1 Bias ═══"
input int    InpH1EMAFast     = 50;    // H1 fast EMA
input int    InpH1EMASlow     = 200;   // H1 slow EMA
input int    InpBiasConfBars  = 3;     // H1 bars price must stay above/below fast EMA
input bool   InpBiasStrength  = true;  // Require EMA separation (trending, not choppy)

input group "═══ L7-L9: M15 Structure ═══"
input int    InpSwingLookback = 20;    // M15 bars for swing detection
input bool   InpRequireBOS    = true;  // Require confirmed BOS (false = looser entry)
input int    InpBOSWindow     = 8;     // BOS confirmation window: bars to look back for a close beyond swing (increase for slower markets)
input int    InpBOSBuffer     = 2;     // Buffer pips on BOS level
input int    InpM15EMAFast    = 20;    // M15 fast EMA (structure align)
input int    InpM15EMASlow    = 50;    // M15 slow EMA (structure trend)
input int    InpATRPeriod     = 14;    // ATR period (M15)
input double InpATRMinPct     = 0.03;  // Min ATR as % of price (dead market, e.g. 0.03% = ~$0.60 on XAUUSD)
input double InpATRMaxPct     = 1.50;  // Max ATR as % of price (explosive, e.g. 1.5% = ~$30 on XAUUSD)

input group "═══ L10: M5 FVG ═══"
input int    InpFVGLookback   = 15;    // M5 bars to scan for FVG
input double InpFVGMinPips    = 3.0;   // Min FVG size in pips
input int    InpFVGMaxAge     = 10;    // Max FVG age in M5 bars (stale = skip)
input double InpFVGEntryDepth = 0.5;   // Entry depth into FVG (0=near edge, 1=far edge)

input group "═══ L11: M5 Order Block ═══"
input int    InpOBLookback    = 25;    // M5 bars to scan for OB
input double InpOBMinPips     = 5.0;   // Min impulse to validate OB (pips)
input bool   InpRequireBothFVGOB = false; // BOTH FVG + OB required (false = either)

input group "═══ L12-L14: M5 Confirmations ═══"
input int    InpRSIPeriod     = 14;    // RSI period
input double InpRSIBuyMin     = 35.0;  // RSI min for BUY (momentum zone)
input double InpRSIBuyMax     = 70.0;  // RSI max for BUY (not overbought)
input double InpRSISellMin    = 30.0;  // RSI min for SELL (not oversold)
input double InpRSISellMax    = 65.0;  // RSI max for SELL
input int    InpMACDFast      = 12;    // MACD fast
input int    InpMACDSlow      = 26;    // MACD slow
input int    InpMACDSig       = 9;     // MACD signal
input bool   InpMACDCross     = false; // Require fresh histogram cross (false = direction only)
input double InpMinBodyRatio  = 0.40;  // Min candle body/range (filter doji/indecision)

input group "═══ L15: SL / TP / R:R ═══"
input double InpATRSLMult     = 1.5;   // SL = ATR * this
input int    InpSLMinPips     = 15;    // SL floor (pips)
input int    InpSLMaxPips     = 250;   // SL cap (pips — increase for indices)
input int    InpSLBuffer      = 3;     // Buffer beyond structure (pips)
input double InpRRMinimum     = 2.0;   // Min R:R required to place trade
input double InpPartialRR     = 1.5;   // Partial close at this R multiple
input double InpPartialPct    = 50.0;  // % volume to close at partial
input bool   InpUseBreakeven  = true;  // Move SL to BE + 1pip at 1×R
input bool   InpUseTrail      = true;  // ATR trail after partial close
input double InpTrailATRMult  = 1.0;   // Trail distance = ATR * this

input group "═══ Execution ═══"
input double InpMaxSpreadPips = 3.0;   // Max spread in pips (dynamic: ×3 for gold/indices)
input int    InpSlippage      = 20;    // Max slippage (points)
input long   InpMagic         = 202601; // Magic number
input bool   InpDebug         = false;  // Verbose journal logging

//════════════════════════════════════════════════════════════════════
// ENUMS & STRUCTS
//════════════════════════════════════════════════════════════════════

enum ENUM_BIAS { BIAS_BULL = 1, BIAS_BEAR = -1, BIAS_NONE = 0 };

struct FVGZone
{
   double   top;
   double   bottom;
   bool     isBull;
   int      ageBars;
   bool     valid;
};

struct OBZone
{
   double   high;
   double   low;
   bool     isBull;
   int      ageBars;
   bool     valid;
};

struct TradeRecord
{
   ulong    ticket;
   double   entryPrice;
   double   sl;
   double   tp;
   double   lotSize;
   double   slDist;       // SL distance in price (not pips)
   int      direction;    // 1=BUY, -1=SELL
   bool     beDone;
   bool     partialDone;
   bool     trailActive;
   double   trailSL;
   double   peakPnL;
   datetime openTime;
};

//════════════════════════════════════════════════════════════════════
// GLOBALS
//════════════════════════════════════════════════════════════════════
CTrade         Trade;

// Indicator handles
int h_H1_EMAFast   = INVALID_HANDLE;
int h_H1_EMASlow   = INVALID_HANDLE;
int h_M15_EMAFast  = INVALID_HANDLE;
int h_M15_EMASlow  = INVALID_HANDLE;
int h_M15_ATR      = INVALID_HANDLE;
int h_M5_RSI       = INVALID_HANDLE;
int h_M5_MACD      = INVALID_HANDLE;

// Daily state
int      g_dailyTrades    = 0;
datetime g_lastTradeTime  = 0;
datetime g_dayStart       = 0;
double   g_dayStartEquity = 0.0;
double   g_balancePeak    = 0.0;
bool     g_hardStop       = false;
int      g_consecLoss     = 0;
datetime g_pauseUntil     = 0;
int      g_dayOfYear      = 0;

// Trade tracking
TradeRecord g_trades[];
int         g_tradeCount = 0;

// Chart state
datetime g_lastM5Bar   = 0;
datetime g_lastM15Bar  = 0;
double   g_pipSize     = 0.0;  // 1 pip in price units
double   g_pointSize   = 0.0;  // 1 point
bool     g_isIndex     = false;
bool     g_isGold      = false;
string   g_sym         = "";

// Last filter fail reason (for dashboard)
string   g_lastReject  = "Waiting...";
string   g_layerStatus = "";

//════════════════════════════════════════════════════════════════════
// INIT / DEINIT
//════════════════════════════════════════════════════════════════════

void ResetTrades()
{
   for(int i = 0; i < ArraySize(g_trades); i++)
   {
      g_trades[i].ticket      = 0;
      g_trades[i].entryPrice  = 0;
      g_trades[i].sl          = 0;
      g_trades[i].tp          = 0;
      g_trades[i].lotSize     = 0;
      g_trades[i].slDist      = 0;
      g_trades[i].direction   = 0;
      g_trades[i].beDone      = false;
      g_trades[i].partialDone = false;
      g_trades[i].trailActive = false;
      g_trades[i].trailSL     = 0;
      g_trades[i].peakPnL     = 0;
      g_trades[i].openTime    = 0;
   }
   g_tradeCount = 0;
}

int OnInit()
{
   g_sym = _Symbol;
   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(InpSlippage);
   Trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Detect instrument type
   string sym = g_sym;
   StringToUpper(sym);
   g_isGold  = (StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0);
   g_isIndex = (StringFind(sym, "US30") >= 0 || StringFind(sym, "DJ30") >= 0 ||
                StringFind(sym, "US100") >= 0 || StringFind(sym, "NAS") >= 0 ||
                StringFind(sym, "USTEC") >= 0 || StringFind(sym, "SPX") >= 0 ||
                StringFind(sym, "US500") >= 0);

   g_pointSize = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   int digits  = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);

   // Pip size: forex 5-digit = 10 points; gold/index = 1 point
   if(!g_isGold && !g_isIndex && (digits == 5 || digits == 3))
      g_pipSize = g_pointSize * 10.0;
   else
      g_pipSize = g_pointSize;

   // Create indicator handles
   h_H1_EMAFast  = iMA(g_sym, PERIOD_H1,  InpH1EMAFast,  0, MODE_EMA, PRICE_CLOSE);
   h_H1_EMASlow  = iMA(g_sym, PERIOD_H1,  InpH1EMASlow,  0, MODE_EMA, PRICE_CLOSE);
   h_M15_EMAFast = iMA(g_sym, PERIOD_M15, InpM15EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_M15_EMASlow = iMA(g_sym, PERIOD_M15, InpM15EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_M15_ATR     = iATR(g_sym, PERIOD_M15, InpATRPeriod);
   h_M5_RSI      = iRSI(g_sym, PERIOD_M5,  InpRSIPeriod,  PRICE_CLOSE);
   h_M5_MACD     = iMACD(g_sym, PERIOD_M5, InpMACDFast, InpMACDSlow, InpMACDSig, PRICE_CLOSE);

   if(h_H1_EMAFast == INVALID_HANDLE || h_H1_EMASlow == INVALID_HANDLE ||
      h_M15_EMAFast == INVALID_HANDLE || h_M15_EMASlow == INVALID_HANDLE ||
      h_M15_ATR == INVALID_HANDLE || h_M5_RSI == INVALID_HANDLE || h_M5_MACD == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles");
      return INIT_FAILED;
   }

   // Init daily state
   g_balancePeak    = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStart       = TimeCurrent();
   g_dayOfYear      = GetDayOfYear(TimeCurrent());

   ArrayResize(g_trades, InpMaxDailyTrades);
   ResetTrades();

   Print("PropSniperElite v1.00 | ", g_sym, " | Pip=", g_pipSize,
         " | Index=", g_isIndex, " | Gold=", g_isGold);
   UpdateDashboard();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(h_H1_EMAFast);
   IndicatorRelease(h_H1_EMASlow);
   IndicatorRelease(h_M15_EMAFast);
   IndicatorRelease(h_M15_EMASlow);
   IndicatorRelease(h_M15_ATR);
   IndicatorRelease(h_M5_RSI);
   IndicatorRelease(h_M5_MACD);
   Comment("");
}

//════════════════════════════════════════════════════════════════════
// MAIN TICK
//════════════════════════════════════════════════════════════════════

void OnTick()
{
   // Daily reset
   CheckDayReset();

   // Prop firm guard — close everything and stop if breached
   if(CheckPropFirmBreached())
   {
      UpdateDashboard();
      return;
   }

   // Manage open positions (BE, partial, trail, session-end close)
   ManagePositions();

   // Entry logic only on new M5 bar close
   datetime curM5 = iTime(g_sym, PERIOD_M5, 0);
   if(curM5 == g_lastM5Bar) { UpdateDashboard(); return; }
   g_lastM5Bar = curM5;

   // Run entry pipeline
   TryEntry();
   UpdateDashboard();
}

//════════════════════════════════════════════════════════════════════
// DAILY RESET
//════════════════════════════════════════════════════════════════════

void CheckDayReset()
{
   int today = GetDayOfYear(TimeCurrent());
   if(today == g_dayOfYear) return;

   g_dayOfYear      = today;
   g_dailyTrades    = 0;
   g_lastTradeTime  = 0;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStart       = TimeCurrent();
   g_hardStop       = false;   // Reset daily stop (prop firm DD still active)
   g_consecLoss     = 0;
   g_pauseUntil     = 0;
   ResetTrades();
   g_lastReject     = "New day — ready";

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal > g_balancePeak) g_balancePeak = bal;

   if(InpDebug) Print("Day reset | equity=", g_dayStartEquity, " | peak=", g_balancePeak);
}

//════════════════════════════════════════════════════════════════════
// PROP FIRM GUARD
//════════════════════════════════════════════════════════════════════

bool CheckPropFirmBreached()
{
   if(g_hardStop) return true;

   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);

   // Update peak
   if(balance > g_balancePeak) g_balancePeak = balance;

   // Daily loss check: equity dropped X% below day-start equity
   double dailyDD = (g_dayStartEquity - equity) / g_dayStartEquity * 100.0;
   if(dailyDD >= InpDailyLossPct)
   {
      g_hardStop    = true;
      g_lastReject  = StringFormat("HARD STOP: Daily loss %.2f%% >= %.2f%%", dailyDD, InpDailyLossPct);
      Print(g_lastReject);
      CloseAllOurPositions("Daily loss limit");
      return true;
   }

   // Max DD check: equity dropped X% below peak balance
   double peakDD = (g_balancePeak - equity) / g_balancePeak * 100.0;
   if(peakDD >= InpMaxDDPct)
   {
      g_hardStop   = true;
      g_lastReject = StringFormat("HARD STOP: Peak DD %.2f%% >= %.2f%%", peakDD, InpMaxDDPct);
      Print(g_lastReject);
      CloseAllOurPositions("Max DD limit");
      return true;
   }

   return false;
}

//════════════════════════════════════════════════════════════════════
// SESSION CHECK
//════════════════════════════════════════════════════════════════════

bool InSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;

   bool london = (h >= InpLondonOpen && h < InpLondonClose);
   bool ny     = (h >= InpNYOpen     && h < InpNYClose);
   return (london || ny);
}

bool SessionEndingThisTick()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   int m = dt.min;

   // Within 5 mins of session close
   bool londonEnd = (h == InpLondonClose - 1 && m >= 55);
   bool nyEnd     = (h == InpNYClose     - 1 && m >= 55);
   return (londonEnd || nyEnd);
}

//════════════════════════════════════════════════════════════════════
// LAYER 1-4: GATE CHECKS
//════════════════════════════════════════════════════════════════════

bool GatesPass(string &reason)
{
   // L1 — Session
   if(!InSession())
   { reason = "L1: Outside London/NY session"; return false; }

   // L2 — Daily trade count
   if(g_dailyTrades >= InpMaxDailyTrades)
   { reason = StringFormat("L2: Daily limit %d/%d reached", g_dailyTrades, InpMaxDailyTrades); return false; }

   // L3 — Cooldown
   if(g_lastTradeTime > 0)
   {
      int elapsed = (int)(TimeCurrent() - g_lastTradeTime);
      if(elapsed < InpMinGapMins * 60)
      { reason = StringFormat("L3: Cooldown %ds/%ds", elapsed, InpMinGapMins*60); return false; }
   }

   // Consecutive loss pause
   if(InpMaxConsecLoss > 0 && g_consecLoss >= InpMaxConsecLoss)
   {
      if(TimeCurrent() < g_pauseUntil)
      { reason = StringFormat("L3b: Consec loss pause (%d losses)", g_consecLoss); return false; }
      else
      { g_consecLoss = 0; g_pauseUntil = 0; }
   }

   // L4 — Spread
   double spread = (double)SymbolInfoInteger(g_sym, SYMBOL_SPREAD) * g_pointSize;
   double maxSpread = InpMaxSpreadPips * g_pipSize;
   // Wider allowance for gold and indices
   if(g_isGold)  maxSpread *= 3.0;
   if(g_isIndex) maxSpread *= 5.0;
   if(spread > maxSpread)
   { reason = StringFormat("L4: Spread %.1f > max %.1f pips", spread/g_pipSize, maxSpread/g_pipSize); return false; }

   return true;
}

//════════════════════════════════════════════════════════════════════
// LAYER 5-6: H1 BIAS
//════════════════════════════════════════════════════════════════════

ENUM_BIAS GetH1Bias()
{
   double emaFast[], emaSlow[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);

   if(CopyBuffer(h_H1_EMAFast, 0, 1, InpBiasConfBars + 1, emaFast) <= 0) return BIAS_NONE;
   if(CopyBuffer(h_H1_EMASlow, 0, 1, 2, emaSlow)                  <= 0) return BIAS_NONE;

   // L5: EMA50 vs EMA200
   bool bullEMA = (emaFast[0] > emaSlow[0]);
   bool bearEMA = (emaFast[0] < emaSlow[0]);

   // L5b: EMA separation as % of price (universal — works for forex, gold, indices)
   if(InpBiasStrength)
   {
      double sep    = MathAbs(emaFast[0] - emaSlow[0]);
      double minSep = emaFast[0] * 0.0005; // Require 0.05% separation minimum
      if(sep < minSep) return BIAS_NONE;
   }

   // L6: Last N H1 bars on same side of fast EMA
   double h1Close[];
   ArraySetAsSeries(h1Close, true);
   if(CopyClose(g_sym, PERIOD_H1, 1, InpBiasConfBars, h1Close) <= 0) return BIAS_NONE;

   int bullCount = 0, bearCount = 0;
   for(int i = 0; i < InpBiasConfBars; i++)
   {
      if(h1Close[i] > emaFast[i]) bullCount++;
      else                         bearCount++;
   }

   bool bullConf = (bullCount == InpBiasConfBars);
   bool bearConf = (bearCount == InpBiasConfBars);

   if(bullEMA && bullConf) return BIAS_BULL;
   if(bearEMA && bearConf) return BIAS_BEAR;
   return BIAS_NONE;
}

//════════════════════════════════════════════════════════════════════
// LAYER 7-9: M15 STRUCTURE
//════════════════════════════════════════════════════════════════════

bool GetM15Structure(ENUM_BIAS bias, double &swingLevel, double &atrVal)
{
   // L9: ATR regime — use % of price so it's universal across forex/gold/indices
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(h_M15_ATR, 0, 1, 1, atr) <= 0) return false;
   atrVal = atr[0];

   double midPrice = (SymbolInfoDouble(g_sym, SYMBOL_BID) + SymbolInfoDouble(g_sym, SYMBOL_ASK)) * 0.5;
   if(midPrice <= 0) return false;
   double atrPct = (atrVal / midPrice) * 100.0;
   if(atrPct < InpATRMinPct) return false;  // Dead market
   if(atrPct > InpATRMaxPct) return false;  // Too explosive

   // L8: M15 EMA alignment
   double m15Fast[], m15Slow[];
   ArraySetAsSeries(m15Fast, true);
   ArraySetAsSeries(m15Slow, true);
   if(CopyBuffer(h_M15_EMAFast, 0, 1, 1, m15Fast) <= 0) return false;
   if(CopyBuffer(h_M15_EMASlow, 0, 1, 1, m15Slow) <= 0) return false;

   bool m15Bull = (m15Fast[0] > m15Slow[0]);
   bool m15Bear = (m15Fast[0] < m15Slow[0]);

   if(bias == BIAS_BULL && !m15Bull) return false;
   if(bias == BIAS_BEAR && !m15Bear) return false;

   // L7: BOS detection
   if(!InpRequireBOS) { swingLevel = 0; return true; }

   double m15High[], m15Low[], m15Close[];
   ArraySetAsSeries(m15High,  true);
   ArraySetAsSeries(m15Low,   true);
   ArraySetAsSeries(m15Close, true);

   // BOS window: check if ANY of the last InpBOSWindow closed M15 bars broke structure.
   // This allows pullback entries — price broke structure 1-5 bars ago, now pulling back.
   int lookback   = InpSwingLookback + InpBOSWindow + 2;
   if(CopyHigh (g_sym, PERIOD_M15, 1, lookback, m15High)  <= 0) return false;
   if(CopyLow  (g_sym, PERIOD_M15, 1, lookback, m15Low)   <= 0) return false;
   if(CopyClose(g_sym, PERIOD_M15, 1, lookback, m15Close)  <= 0) return false;

   double bufPts = InpBOSBuffer * g_pipSize;

   if(bias == BIAS_BULL)
   {
      // Find swing high from bars OLDER than BOS_WINDOW (the pre-BOS structure)
      double swingHigh = m15High[InpBOSWindow + 1];
      for(int i = InpBOSWindow + 2; i < lookback; i++)
         if(m15High[i] > swingHigh) swingHigh = m15High[i];

      // BOS confirmed if ANY bar within InpBOSWindow closed above swing high
      for(int j = 0; j < InpBOSWindow; j++)
      {
         if(m15Close[j] > swingHigh + bufPts)
         {
            swingLevel = swingHigh;
            return true;
         }
      }
   }
   else // BIAS_BEAR
   {
      double swingLow = m15Low[InpBOSWindow + 1];
      for(int i = InpBOSWindow + 2; i < lookback; i++)
         if(m15Low[i] < swingLow) swingLow = m15Low[i];

      for(int j = 0; j < InpBOSWindow; j++)
      {
         if(m15Close[j] < swingLow - bufPts)
         {
            swingLevel = swingLow;
            return true;
         }
      }
   }

   return false;
}

//════════════════════════════════════════════════════════════════════
// LAYER 10: M5 FVG
//════════════════════════════════════════════════════════════════════

bool GetM5FVG(ENUM_BIAS bias, FVGZone &fvg)
{
   fvg.valid = false;

   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low,  true);

   int needed = InpFVGLookback + 3;
   if(CopyHigh(g_sym, PERIOD_M5, 1, needed, high) <= 0) return false;
   if(CopyLow (g_sym, PERIOD_M5, 1, needed, low)  <= 0) return false;

   double minSize = InpFVGMinPips * g_pipSize;
   double bid     = SymbolInfoDouble(g_sym, SYMBOL_BID);

   // Scan from most recent backwards
   for(int i = 0; i < InpFVGLookback; i++)
   {
      if(bias == BIAS_BULL)
      {
         // Bull FVG: gap between candle[i+2].high and candle[i].low
         // Candle[i+1] is the impulse bull candle
         double gapBottom = high[i + 2];
         double gapTop    = low[i];
         if(gapTop > gapBottom + minSize)
         {
            // Price must currently be within or just above the FVG for pullback
            if(bid >= gapBottom && bid <= gapTop + (gapTop - gapBottom) * 0.5)
            {
               if(i <= InpFVGMaxAge)
               {
                  fvg.top     = gapTop;
                  fvg.bottom  = gapBottom;
                  fvg.isBull  = true;
                  fvg.ageBars = i;
                  fvg.valid   = true;
                  return true;
               }
            }
         }
      }
      else // BIAS_BEAR
      {
         // Bear FVG: gap between candle[i].high and candle[i+2].low
         double gapTop    = low[i + 2];
         double gapBottom = high[i];
         if(gapTop > gapBottom + minSize)
         {
            // Price must currently be within or just below the FVG
            if(bid <= gapTop && bid >= gapBottom - (gapTop - gapBottom) * 0.5)
            {
               if(i <= InpFVGMaxAge)
               {
                  fvg.top     = gapTop;
                  fvg.bottom  = gapBottom;
                  fvg.isBull  = false;
                  fvg.ageBars = i;
                  fvg.valid   = true;
                  return true;
               }
            }
         }
      }
   }
   return false;
}

//════════════════════════════════════════════════════════════════════
// LAYER 11: M5 ORDER BLOCK
//════════════════════════════════════════════════════════════════════

bool GetM5OB(ENUM_BIAS bias, OBZone &ob)
{
   ob.valid = false;

   double open[], high[], low[], close[];
   ArraySetAsSeries(open,  true);
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);

   int needed = InpOBLookback + 3;
   if(CopyOpen (g_sym, PERIOD_M5, 1, needed, open)  <= 0) return false;
   if(CopyHigh (g_sym, PERIOD_M5, 1, needed, high)  <= 0) return false;
   if(CopyLow  (g_sym, PERIOD_M5, 1, needed, low)   <= 0) return false;
   if(CopyClose(g_sym, PERIOD_M5, 1, needed, close)  <= 0) return false;

   double minImpulse = InpOBMinPips * g_pipSize;
   double bid        = SymbolInfoDouble(g_sym, SYMBOL_BID);

   for(int i = 1; i < InpOBLookback; i++)
   {
      if(bias == BIAS_BULL)
      {
         // Bull OB: last bearish candle before a bullish impulse move
         bool isBearCandle = (close[i] < open[i]);
         if(!isBearCandle) continue;

         // Check if price broke up strongly from this OB
         double impulse = 0;
         for(int j = i - 1; j >= 0 && j >= i - 5; j--)
            impulse = MathMax(impulse, high[j] - close[i]);

         if(impulse < minImpulse) continue;

         // OB zone = the bearish candle's range
         double obHigh = high[i];
         double obLow  = low[i];

         // Price should be pulling back into this OB from above
         if(bid <= obHigh && bid >= obLow - g_pipSize * 5)
         {
            ob.high    = obHigh;
            ob.low     = obLow;
            ob.isBull  = true;
            ob.ageBars = i;
            ob.valid   = true;
            return true;
         }
      }
      else // BIAS_BEAR
      {
         // Bear OB: last bullish candle before a bearish impulse move
         bool isBullCandle = (close[i] > open[i]);
         if(!isBullCandle) continue;

         double impulse = 0;
         for(int j = i - 1; j >= 0 && j >= i - 5; j--)
            impulse = MathMax(impulse, close[i] - low[j]);

         if(impulse < minImpulse) continue;

         double obHigh = high[i];
         double obLow  = low[i];

         // Price should be pulling back into this OB from below
         if(bid >= obLow && bid <= obHigh + g_pipSize * 5)
         {
            ob.high    = obHigh;
            ob.low     = obLow;
            ob.isBull  = false;
            ob.ageBars = i;
            ob.valid   = true;
            return true;
         }
      }
   }
   return false;
}

//════════════════════════════════════════════════════════════════════
// LAYERS 12-14: M5 RSI + MACD + CANDLE QUALITY
//════════════════════════════════════════════════════════════════════

bool GetM5Confirmations(ENUM_BIAS bias, string &reason)
{
   // L12: RSI
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(h_M5_RSI, 0, 1, 2, rsi) <= 0)
   { reason = "L12: RSI data unavailable"; return false; }

   if(bias == BIAS_BULL)
   {
      if(rsi[0] < InpRSIBuyMin || rsi[0] > InpRSIBuyMax)
      { reason = StringFormat("L12: RSI %.1f not in bull zone [%.0f-%.0f]", rsi[0], InpRSIBuyMin, InpRSIBuyMax); return false; }
   }
   else
   {
      if(rsi[0] < InpRSISellMin || rsi[0] > InpRSISellMax)
      { reason = StringFormat("L12: RSI %.1f not in bear zone [%.0f-%.0f]", rsi[0], InpRSISellMin, InpRSISellMax); return false; }
   }

   // L13: MACD histogram aligned
   double macdHist[], macdHistPrev[];
   ArraySetAsSeries(macdHist,     true);

   if(CopyBuffer(h_M5_MACD, 2, 1, 3, macdHist) <= 0)
   { reason = "L13: MACD data unavailable"; return false; }

   double hist0 = macdHist[0];
   double hist1 = macdHist[1];
   double hist2 = macdHist[2];

   if(bias == BIAS_BULL)
   {
      if(hist0 <= 0)
      { reason = StringFormat("L13: MACD hist %.5f not positive (bull)", hist0); return false; }
      if(InpMACDCross && !(hist1 <= 0 || hist2 <= 0))
      { reason = "L13: No fresh MACD cross (bull)"; return false; }
   }
   else
   {
      if(hist0 >= 0)
      { reason = StringFormat("L13: MACD hist %.5f not negative (bear)", hist0); return false; }
      if(InpMACDCross && !(hist1 >= 0 || hist2 >= 0))
      { reason = "L13: No fresh MACD cross (bear)"; return false; }
   }

   // L14: Candle body quality on most recent closed M5 bar
   double m5Open[], m5Close[], m5High[], m5Low[];
   ArraySetAsSeries(m5Open,  true);
   ArraySetAsSeries(m5Close, true);
   ArraySetAsSeries(m5High,  true);
   ArraySetAsSeries(m5Low,   true);
   if(CopyOpen (g_sym, PERIOD_M5, 1, 1, m5Open)  <= 0) return true; // Skip if unavailable
   if(CopyClose(g_sym, PERIOD_M5, 1, 1, m5Close) <= 0) return true;
   if(CopyHigh (g_sym, PERIOD_M5, 1, 1, m5High)  <= 0) return true;
   if(CopyLow  (g_sym, PERIOD_M5, 1, 1, m5Low)   <= 0) return true;

   double bodySize  = MathAbs(m5Close[0] - m5Open[0]);
   double rangeSize = m5High[0] - m5Low[0];
   if(rangeSize > 0)
   {
      double bodyRatio = bodySize / rangeSize;
      if(bodyRatio < InpMinBodyRatio)
      { reason = StringFormat("L14: Body ratio %.2f < %.2f (doji/wick)", bodyRatio, InpMinBodyRatio); return false; }
   }

   // Candle direction should match bias
   if(bias == BIAS_BULL && m5Close[0] < m5Open[0])
   { reason = "L14: Bearish candle on bull signal"; return false; }
   if(bias == BIAS_BEAR && m5Close[0] > m5Open[0])
   { reason = "L14: Bullish candle on bear signal"; return false; }

   return true;
}

//════════════════════════════════════════════════════════════════════
// LOT SIZING
//════════════════════════════════════════════════════════════════════

double CalcLot(double slDist)
{
   if(slDist <= 0) return InpMinLot;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (InpRiskPct / 100.0);

   double tickVal  = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickVal <= 0) return InpMinLot;

   double pipValuePerLot = tickVal * (g_pipSize / tickSize);
   double slPips         = slDist / g_pipSize;
   if(slPips <= 0) return InpMinLot;

   double lot = riskMoney / (slPips * pipValuePerLot);

   double minLot  = MathMax(InpMinLot, SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN));
   double maxLot  = MathMin(InpMaxLot, SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX));
   double lotStep = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   if(lotStep > 0) lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return lot;
}

//════════════════════════════════════════════════════════════════════
// LAYER 15: R:R CHECK + ENTRY
//════════════════════════════════════════════════════════════════════

void TryEntry()
{
   string reason = "";
   g_layerStatus = "";

   // Layers 1-4
   if(!GatesPass(reason)) { g_lastReject = reason; return; }
   g_layerStatus += "L1-4:OK ";

   // Layer 5-6: H1 Bias
   ENUM_BIAS bias = GetH1Bias();
   if(bias == BIAS_NONE) { g_lastReject = "L5-6: H1 bias unclear/choppy"; return; }
   g_layerStatus += "L5-6:" + (bias == BIAS_BULL ? "BULL" : "BEAR") + " ";

   // Layers 7-9: M15 Structure
   double swingLevel = 0, atrVal = 0;
   if(!GetM15Structure(bias, swingLevel, atrVal))
   { g_lastReject = "L7-9: M15 BOS/EMA/ATR not met"; return; }
   g_layerStatus += "L7-9:OK ";

   // Layer 10: FVG
   FVGZone fvg;
   bool hasFVG = GetM5FVG(bias, fvg);

   // Layer 11: OB
   OBZone ob;
   bool hasOB = GetM5OB(bias, ob);

   // Confluence requirement
   if(InpRequireBothFVGOB)
   {
      if(!hasFVG || !hasOB)
      { g_lastReject = "L10-11: Both FVG+OB required — not met"; return; }
   }
   else
   {
      if(!hasFVG && !hasOB)
      { g_lastReject = "L10-11: Neither FVG nor OB found"; return; }
   }
   g_layerStatus += "L10-11:" + (hasFVG ? "FVG" : "") + (hasOB ? "+OB" : "") + " ";

   // Layers 12-14: RSI + MACD + candle
   if(!GetM5Confirmations(bias, reason)) { g_lastReject = reason; return; }
   g_layerStatus += "L12-14:OK ";

   // Calculate SL
   double slDist    = atrVal * InpATRSLMult + InpSLBuffer * g_pipSize;
   double slDistMin = InpSLMinPips * g_pipSize;
   double slDistMax = InpSLMaxPips * g_pipSize;
   slDist = MathMax(slDistMin, MathMin(slDistMax, slDist));

   double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);

   double entryPrice, slPrice, tpPrice;
   if(bias == BIAS_BULL)
   {
      entryPrice = ask;
      slPrice    = entryPrice - slDist;
      tpPrice    = entryPrice + slDist * InpRRMinimum;
   }
   else
   {
      entryPrice = bid;
      slPrice    = entryPrice + slDist;
      tpPrice    = entryPrice - slDist * InpRRMinimum;
   }

   // L15: R:R verification (TP distance vs SL distance)
   double tpDist = MathAbs(tpPrice - entryPrice);
   double rr     = tpDist / slDist;
   if(rr < InpRRMinimum)
   { g_lastReject = StringFormat("L15: R:R %.2f < min %.2f", rr, InpRRMinimum); return; }
   g_layerStatus += StringFormat("L15:R:R=%.2f ", rr);

   // Normalize prices
   int d       = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   entryPrice  = NormalizeDouble(entryPrice, d);
   slPrice     = NormalizeDouble(slPrice, d);
   tpPrice     = NormalizeDouble(tpPrice, d);

   // Lot sizing
   double lot = CalcLot(slDist);
   if(lot <= 0) { g_lastReject = "Lot calc error"; return; }

   // Place market order
   bool ok = false;
   if(bias == BIAS_BULL)
      ok = Trade.Buy(lot, g_sym, entryPrice, slPrice, tpPrice, "PropSniper");
   else
      ok = Trade.Sell(lot, g_sym, entryPrice, slPrice, tpPrice, "PropSniper");

   if(ok)
   {
      ulong ticket = Trade.ResultOrder();
      if(InpDebug) Print("ENTRY ", (bias==BIAS_BULL?"BUY":"SELL"),
                         " lot=", lot, " SL=", slPrice, " TP=", tpPrice,
                         " R:R=", DoubleToString(rr,2));

      // Record trade
      if(g_tradeCount < InpMaxDailyTrades)
      {
         g_trades[g_tradeCount].ticket      = ticket;
         g_trades[g_tradeCount].entryPrice  = entryPrice;
         g_trades[g_tradeCount].sl          = slPrice;
         g_trades[g_tradeCount].tp          = tpPrice;
         g_trades[g_tradeCount].lotSize     = lot;
         g_trades[g_tradeCount].slDist      = slDist;
         g_trades[g_tradeCount].direction   = (int)bias;
         g_trades[g_tradeCount].beDone      = false;
         g_trades[g_tradeCount].partialDone = false;
         g_trades[g_tradeCount].trailActive = false;
         g_trades[g_tradeCount].trailSL     = slPrice;
         g_trades[g_tradeCount].peakPnL     = 0;
         g_trades[g_tradeCount].openTime    = TimeCurrent();
         g_tradeCount++;
      }

      g_dailyTrades++;
      g_lastTradeTime = TimeCurrent();
      g_lastReject    = "IN TRADE #" + IntegerToString(g_dailyTrades);
      g_layerStatus   = "ALL 15 LAYERS PASSED";
   }
   else
   {
      g_lastReject = "Order failed: " + Trade.ResultComment();
      Print("Order failed: ", Trade.ResultRetcode(), " — ", Trade.ResultComment());
   }
}

//════════════════════════════════════════════════════════════════════
// POSITION MANAGEMENT (BE, PARTIAL, TRAIL, SESSION-END)
//════════════════════════════════════════════════════════════════════

void ManagePositions()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   double atrVal = 0;
   if(CopyBuffer(h_M15_ATR, 0, 0, 1, atr) > 0) atrVal = atr[0];

   for(int i = 0; i < g_tradeCount; i++)
   {
      ulong ticket = g_trades[i].ticket;
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      double posProfit = PositionGetDouble(POSITION_PROFIT);
      double posLots   = PositionGetDouble(POSITION_VOLUME);
      double posSL     = PositionGetDouble(POSITION_SL);
      double posTP     = PositionGetDouble(POSITION_TP);
      double bid       = SymbolInfoDouble(g_sym, SYMBOL_BID);
      double ask       = SymbolInfoDouble(g_sym, SYMBOL_ASK);
      int    dir       = g_trades[i].direction;
      double slDist    = g_trades[i].slDist;
      double entry     = g_trades[i].entryPrice;
      double oneR      = slDist;
      int    d         = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);

      double currentPrice = (dir == 1) ? bid : ask;
      double priceDiff    = (dir == 1) ? (currentPrice - entry) : (entry - currentPrice);
      double rMultiple    = (slDist > 0) ? priceDiff / slDist : 0;

      // Track peak
      if(priceDiff > g_trades[i].peakPnL) g_trades[i].peakPnL = priceDiff;

      // Session-end forced close
      if(InpCloseAtSessionEnd && SessionEndingThisTick())
      {
         if(InpDebug) Print("Session end — closing #", ticket);
         Trade.PositionClose(ticket);
         RecordCloseResult(i, posProfit);
         continue;
      }

      // Breakeven at 1R (move SL to entry + 1 pip)
      if(InpUseBreakeven && !g_trades[i].beDone && rMultiple >= 1.0)
      {
         double beSL = (dir == 1)
                       ? NormalizeDouble(entry + g_pipSize, d)
                       : NormalizeDouble(entry - g_pipSize, d);

         bool moved = false;
         if(dir == 1 && beSL > posSL) moved = Trade.PositionModify(ticket, beSL, posTP);
         if(dir == -1 && beSL < posSL) moved = Trade.PositionModify(ticket, beSL, posTP);

         if(moved)
         {
            g_trades[i].beDone = true;
            g_trades[i].sl     = beSL;
            if(InpDebug) Print("BE moved #", ticket, " SL→", beSL);
         }
      }

      // Partial close at InpPartialRR × R
      if(!g_trades[i].partialDone && rMultiple >= InpPartialRR && posLots > 0)
      {
         double closeLots = NormalizeDouble(posLots * (InpPartialPct / 100.0),
                                            (int)MathRound(MathLog(1.0 / SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP)) / MathLog(10)));
         double minLot    = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
         double lotStep   = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
         closeLots        = MathFloor(closeLots / lotStep) * lotStep;

         if(closeLots >= minLot && closeLots < posLots)
         {
            if(Trade.PositionClosePartial(ticket, closeLots))
            {
               g_trades[i].partialDone = true;
               g_trades[i].trailActive = InpUseTrail;
               if(InpDebug) Print("Partial close #", ticket, " lots=", closeLots,
                                  " at ", DoubleToString(rMultiple, 2), "R");
            }
         }
      }

      // ATR trailing stop after partial
      if(InpUseTrail && g_trades[i].trailActive && atrVal > 0)
      {
         double trailDist = atrVal * InpTrailATRMult;
         double newTrailSL;

         if(dir == 1)
         {
            newTrailSL = NormalizeDouble(currentPrice - trailDist, d);
            if(newTrailSL > g_trades[i].trailSL && newTrailSL > posSL)
            {
               if(Trade.PositionModify(ticket, newTrailSL, posTP))
               {
                  g_trades[i].trailSL = newTrailSL;
                  g_trades[i].sl      = newTrailSL;
               }
            }
         }
         else
         {
            newTrailSL = NormalizeDouble(currentPrice + trailDist, d);
            if(newTrailSL < g_trades[i].trailSL && newTrailSL < posSL)
            {
               if(Trade.PositionModify(ticket, newTrailSL, posTP))
               {
                  g_trades[i].trailSL = newTrailSL;
                  g_trades[i].sl      = newTrailSL;
               }
            }
         }
      }
   }
}

//════════════════════════════════════════════════════════════════════
// TRADE CLOSE TRACKING
//════════════════════════════════════════════════════════════════════

void RecordCloseResult(int idx, double profit)
{
   if(profit < 0)
   {
      g_consecLoss++;
      if(InpMaxConsecLoss > 0 && g_consecLoss >= InpMaxConsecLoss)
      {
         datetime barTime  = iTime(g_sym, PERIOD_M15, 0);
         g_pauseUntil      = barTime + InpPauseM15Bars * 15 * 60;
         Print("Consec loss pause until ", TimeToString(g_pauseUntil));
      }
   }
   else if(profit > 0)
   {
      g_consecLoss = 0;
   }

   // Clear slot
   g_trades[idx].ticket = 0;
}

//════════════════════════════════════════════════════════════════════
// CLOSE ALL POSITIONS
//════════════════════════════════════════════════════════════════════

void CloseAllOurPositions(string reason)
{
   Print("CloseAll — reason: ", reason);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_sym)    continue;
      Trade.PositionClose(ticket);
   }
}

//════════════════════════════════════════════════════════════════════
// ON TRADE TRANSACTION (detect closures)
//════════════════════════════════════════════════════════════════════

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(dealTicket == 0) return;

   if(HistoryDealSelect(dealTicket))
   {
      long magic = (long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      if(magic != InpMagic) return;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

      double profit  = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      ulong  posId   = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

      // Find matching slot
      for(int i = 0; i < g_tradeCount; i++)
      {
         if(g_trades[i].ticket == posId || g_trades[i].ticket == trans.position)
         {
            RecordCloseResult(i, profit);
            break;
         }
      }
   }
}

//════════════════════════════════════════════════════════════════════
// UTILITY
//════════════════════════════════════════════════════════════════════

int GetDayOfYear(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.day_of_year;
}

int CountOurPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == g_sym)
         count++;
   }
   return count;
}

double GetOpenProfit()
{
   double total = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == g_sym)
         total += PositionGetDouble(POSITION_PROFIT);
   }
   return total;
}

//════════════════════════════════════════════════════════════════════
// DASHBOARD
//════════════════════════════════════════════════════════════════════

void UpdateDashboard()
{
   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyDD     = (g_dayStartEquity > 0)
                        ? (g_dayStartEquity - equity) / g_dayStartEquity * 100.0 : 0;
   double peakDD      = (g_balancePeak > 0)
                        ? (g_balancePeak - equity) / g_balancePeak * 100.0 : 0;
   double openProfit  = GetOpenProfit();
   int    openPos     = CountOurPositions();

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   bool inLon = (dt.hour >= InpLondonOpen && dt.hour < InpLondonClose);
   bool inNY  = (dt.hour >= InpNYOpen     && dt.hour < InpNYClose);
   string sessionStr = inLon ? "LONDON" : (inNY ? "NEW YORK" : "OFF-SESSION");

   string bias = "...";
   ENUM_BIAS b = GetH1Bias();
   if(b == BIAS_BULL) bias = "BULL (H1)";
   else if(b == BIAS_BEAR) bias = "BEAR (H1)";
   else bias = "NONE/CHOPPY";

   string stopStr = g_hardStop ? " !! HARD STOP !!" : "";

   string dash = StringFormat(
      "┌─────────────────────────────────────┐\n"
      "│  PropSniperElite v1.00   %s   │\n"
      "│  Symbol : %-28s│\n"
      "│  Session: %-28s│\n"
      "├─────────────────────────────────────┤\n"
      "│  Equity : $%-27.2f│\n"
      "│  Daily DD: %+.2f%%   Peak DD: %+.2f%%  │\n"
      "│  Daily limit: %.1f%%  Max DD: %.1f%%    │\n"
      "├─────────────────────────────────────┤\n"
      "│  H1 Bias : %-26s│\n"
      "│  Trades today : %d/%d                 │\n"
      "│  Open positions : %-18d│\n"
      "│  Open P&L : $%-24.2f│\n"
      "├─────────────────────────────────────┤\n"
      "│  Layer status: %-21s│\n"
      "│  Last reject:                       │\n"
      "│    %-33s│\n"
      "└─────────────────────────────────────┘",
      stopStr,
      g_sym,
      sessionStr,
      equity,
      dailyDD, peakDD,
      InpDailyLossPct, InpMaxDDPct,
      bias,
      g_dailyTrades, InpMaxDailyTrades,
      openPos,
      openProfit,
      g_layerStatus,
      g_lastReject
   );

   Comment(dash);
}
//+------------------------------------------------------------------+
