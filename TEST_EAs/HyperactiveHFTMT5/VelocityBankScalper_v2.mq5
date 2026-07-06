//+------------------------------------------------------------------+
//| VelocityBankScalper v3.0                                         |
//| Trend-filtered velocity scalper | EMA + RSI | ATR exits          |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, VelocityBankScalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "3.00"
#property description "VelocityBankScalper v3.0 — EMA trend filter + RSI guard + 2:1 R:R"

#include <Trade/Trade.mqh>
CTrade trade;

//=============================================================================
// SECTION A — INPUTS
//=============================================================================

input group "===== Symbols ====="
input string InpSymbols         = "USDJPY,GBPJPY,CADJPY,EURJPY,AUDJPY,NZDJPY";

input group "===== Lot & Risk ====="
input double InpRiskPct         = 0.5;    // % of balance risked per trade
input double InpMinLot          = 0.01;   // Minimum lot size
input double InpMaxLot          = 3.00;   // Maximum lot size

input group "===== ATR (SL/TP sizing) ====="
input int    InpAtrPeriod       = 14;
input double InpAtrSlMult       = 1.5;    // SL = ATR * this
input double InpAtrTpMult       = 3.0;    // TP = ATR * this  (2:1 R:R)
input double InpAtrMin          = 5.0;    // Min ATR in points to trade
input double InpAtrMax          = 80.0;   // Max ATR in points (skip spikes)

input group "===== Trend Filter (EMA) ====="
input int    InpEmaPeriod       = 50;     // EMA period on M5
input double InpEmaBufferPts    = 3.0;    // Price must be >= X pts beyond EMA

input group "===== RSI Momentum Confirm ====="
input int    InpRsiPeriod       = 14;
input double InpRsiBuyMin       = 50.0;   // Buy only when RSI > this (momentum bullish)
input double InpRsiSellMax      = 50.0;   // Sell only when RSI < this (momentum bearish)

input group "===== Tick Velocity ====="
input int    InpVelLookback     = 12;     // Snapshot depth
input double InpVelMinMedium    = 1.0;    // Min pts/snap to qualify (MEDIUM threshold)

input group "===== Spread & Entry ====="
input double InpMaxSpreadAtrPct = 40.0;   // Max spread as % of ATR (tight!)
input int    InpCooldownSec     = 60;     // Seconds between entries per symbol
input int    InpMaxOpenPerSym   = 1;      // Max open positions per symbol

input group "===== Trailing Stop ====="
input bool   InpUseTrail        = true;
input double InpTrailActiveMult = 1.5;    // Activate trail when profit >= X * ATR$
input double InpTrailDistMult   = 0.75;   // Trail distance in ATR units

input group "===== Session (GMT) ====="
input bool   TradeAsian         = false;
input bool   TradeLondon        = true;
input bool   TradeNY            = true;
input int    InpGmtOffset       = 0;      // Broker GMT offset (hours)

input group "===== Debug ====="
input bool   InpLogging         = true;
input int    InpLogLevel        = 1;      // 0=errors 1=trades 2=verbose

//=============================================================================
// SECTION B — STRUCTS & DEFINES
//=============================================================================

#define MAGIC    20260630
#define BUFLEN   60
#define MAXSYM   48

struct SymState
{
   string   sym;
   string   base;
   double   pt;
   int      digits;
   bool     valid;

   // Tick velocity ring-buffer
   double   mid[BUFLEN];
   int      filled;
   datetime lastEntry;

   // Indicator handles
   int      atrHandle;
   int      emaHandle;
   int      rsiHandle;

   // Cached values (refreshed each tick)
   double   atrPts;
   double   emaVal;
   double   rsiVal;
};

SymState g_sym[MAXSYM];
int      g_symCount = 0;

//=============================================================================
// SECTION C — INIT / DEINIT
//=============================================================================

int OnInit()
{
   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(200);

   g_symCount = 0;

   string parts[];
   int n = StringSplit(InpSymbols, ',', parts);

   for(int i = 0; i < n && g_symCount < MAXSYM; i++)
   {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      if(StringLen(parts[i]) == 0) continue;

      string variants[];
      ArrayResize(variants, MAXSYM);
      int vCount = FindAllSymbols(parts[i], variants, MAXSYM - g_symCount);
      if(vCount == 0)
      {
         Print("WARNING: '", parts[i], "' not found or trade-disabled — skipped.");
         continue;
      }

      for(int v = 0; v < vCount && g_symCount < MAXSYM; v++)
      {
         string resolved = variants[v];
         int si = g_symCount;

         g_sym[si].base      = parts[i];
         g_sym[si].sym       = resolved;
         g_sym[si].pt        = SymbolInfoDouble(resolved, SYMBOL_POINT);
         g_sym[si].digits    = (int)SymbolInfoInteger(resolved, SYMBOL_DIGITS);
         g_sym[si].valid     = true;
         g_sym[si].filled    = 0;
         g_sym[si].lastEntry = 0;
         g_sym[si].atrPts    = 0.0;
         g_sym[si].emaVal    = 0.0;
         g_sym[si].rsiVal    = 50.0;
         ArrayInitialize(g_sym[si].mid, 0.0);

         g_sym[si].atrHandle = iATR(resolved, PERIOD_M5, InpAtrPeriod);
         g_sym[si].emaHandle = iMA(resolved,  PERIOD_M5, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
         g_sym[si].rsiHandle = iRSI(resolved, PERIOD_M5, InpRsiPeriod, PRICE_CLOSE);

         bool handleOk = (g_sym[si].atrHandle != INVALID_HANDLE)
                      && (g_sym[si].emaHandle != INVALID_HANDLE)
                      && (g_sym[si].rsiHandle != INVALID_HANDLE);
         if(!handleOk)
         {
            Print("WARNING: Indicator handle failed for ", resolved, " — skipped.");
            g_sym[si].valid = false;
         }

         SetFilling(resolved);

         Print("Loaded: ", parts[i], " -> ", resolved,
               "  pt=", g_sym[si].pt, "  digits=", g_sym[si].digits);
         g_symCount++;
      }
   }

   if(g_symCount == 0)
   {
      Alert("VelocityBankScalper v3.0: No valid symbols. Check InpSymbols.");
      return INIT_FAILED;
   }

   Print("==============================================");
   Print("VelocityBankScalper v3.0  STARTED");
   Print("Symbols   : ", g_symCount, " loaded");
   Print("Risk/trade: ", InpRiskPct, "%  Min:", InpMinLot, " Max:", InpMaxLot);
   Print("SL/TP     : ", InpAtrSlMult, "x ATR / ", InpAtrTpMult, "x ATR (", DoubleToString(InpAtrTpMult/InpAtrSlMult,1), ":1 R:R)");
   Print("EMA filter: ", InpEmaPeriod, " period, buffer=", InpEmaBufferPts, " pts");
   Print("RSI confirm: buy>", InpRsiBuyMin, "  sell<", InpRsiSellMax);
   Print("Cooldown  : ", InpCooldownSec, "s per symbol");
   Print("==============================================");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   for(int i = 0; i < g_symCount; i++)
   {
      if(g_sym[i].atrHandle != INVALID_HANDLE) IndicatorRelease(g_sym[i].atrHandle);
      if(g_sym[i].emaHandle != INVALID_HANDLE) IndicatorRelease(g_sym[i].emaHandle);
      if(g_sym[i].rsiHandle != INVALID_HANDLE) IndicatorRelease(g_sym[i].rsiHandle);
   }
   Comment("");
}

//=============================================================================
// SECTION D — MAIN TICK
//=============================================================================

void OnTick()
{
   for(int i = 0; i < g_symCount; i++)
   {
      if(!g_sym[i].valid) continue;
      PushSnapshot(g_sym[i]);
      RefreshIndicators(g_sym[i]);
   }

   ManageExits();

   for(int i = 0; i < g_symCount; i++)
   {
      if(g_sym[i].valid)
         TryEntry(g_sym[i]);
   }

   ShowPanel();
}

//=============================================================================
// SECTION E — TICK VELOCITY ENGINE
//=============================================================================

void PushSnapshot(SymState &s)
{
   MqlTick tk;
   if(!SymbolInfoTick(s.sym, tk)) return;
   double mid = (tk.bid + tk.ask) * 0.5;
   if(s.filled > 0 && mid == s.mid[0]) return;
   for(int i = BUFLEN - 1; i > 0; i--)
      s.mid[i] = s.mid[i-1];
   s.mid[0] = mid;
   if(s.filled < BUFLEN) s.filled++;
}

// Returns velocity in pts/snapshot and direction. Returns false if insufficient data.
bool CalcVel(SymState &s, double &ptsPerSnap, int &dir)
{
   ptsPerSnap = 0.0;
   dir        = 0;
   if(s.filled < InpVelLookback) return false;

   double oldest = s.mid[InpVelLookback - 1];
   double newest = s.mid[0];
   double chg    = newest - oldest;

   ptsPerSnap = MathAbs(chg) / s.pt / InpVelLookback;
   dir = (chg > s.pt) ? 1 : (chg < -s.pt ? -1 : 0);
   return true;
}

//=============================================================================
// SECTION F — INDICATORS
//=============================================================================

void RefreshIndicators(SymState &s)
{
   // ATR
   if(s.atrHandle != INVALID_HANDLE)
   {
      double buf[2];
      if(CopyBuffer(s.atrHandle, 0, 0, 2, buf) >= 2)
         s.atrPts = buf[1] / s.pt; // use confirmed bar [1] to avoid repainting
   }

   // EMA
   if(s.emaHandle != INVALID_HANDLE)
   {
      double buf[2];
      if(CopyBuffer(s.emaHandle, 0, 0, 2, buf) >= 2)
         s.emaVal = buf[1];
   }

   // RSI
   if(s.rsiHandle != INVALID_HANDLE)
   {
      double buf[2];
      if(CopyBuffer(s.rsiHandle, 0, 0, 2, buf) >= 2)
         s.rsiVal = buf[1];
   }
}

// 1x ATR value in account currency for a given lot size
double AtrToDollar(SymState &s, double lots)
{
   if(s.atrPts <= 0.0) return 0.0;
   double tv = SymbolInfoDouble(s.sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(s.sym, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0.0 || ts <= 0.0) return 0.0;
   return (s.atrPts * s.pt / ts) * tv * lots;
}

//=============================================================================
// SECTION G — SESSION
//=============================================================================

bool SessionAllows()
{
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now - InpGmtOffset * 3600, dt);
   int gmt = dt.hour * 60 + dt.min;

   bool london = (gmt >= 420 && gmt < 1020);
   bool ny     = (gmt >= 780 && gmt < 1260);
   bool asian  = (gmt >= 0   && gmt < 420);

   if(london && ny) return (TradeLondon || TradeNY);
   if(london)       return TradeLondon;
   if(ny)           return TradeNY;
   if(asian)        return TradeAsian;
   return false;
}

string SessionStr()
{
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now - InpGmtOffset * 3600, dt);
   int gmt = dt.hour * 60 + dt.min;

   bool london = (gmt >= 420 && gmt < 1020);
   bool ny     = (gmt >= 780 && gmt < 1260);
   bool asian  = (gmt >= 0   && gmt < 420);

   if(london && ny) return "OVR";
   if(london)       return "LON";
   if(ny)           return "NY";
   if(asian)        return "ASI";
   return "DED";
}

//=============================================================================
// SECTION H — ENTRY ENGINE
// Entry logic:
//   1. Session allowed
//   2. ATR in acceptable range (not too flat, not spiking)
//   3. Spread tight enough (< 40% of ATR)
//   4. EMA confirms trend direction with buffer
//   5. RSI not overbought/oversold
//   6. Velocity >= MEDIUM and matches EMA direction
//   7. Max 1 open position per symbol
//   8. Cooldown passed
//=============================================================================

void TryEntry(SymState &s)
{
   if(!s.valid) return;
   if(s.atrPts <= 0.0 || s.emaVal <= 0.0) return;
   if(s.filled < InpVelLookback) return;

   // Session gate removed — trades 24/7

   // ATR range
   if(s.atrPts < InpAtrMin || s.atrPts > InpAtrMax) return;

   datetime now = TimeCurrent();
   if((int)(now - s.lastEntry) < InpCooldownSec) return;

   MqlTick tk;
   if(!SymbolInfoTick(s.sym, tk)) return;

   // Spread gate
   double spreadPts = (tk.ask - tk.bid) / s.pt;
   double maxSpread = s.atrPts * InpMaxSpreadAtrPct / 100.0;
   if(spreadPts > maxSpread) return;

   // Velocity
   double vel; int velDir;
   if(!CalcVel(s, vel, velDir)) return;
   if(vel < InpVelMinMedium) return;  // require MEDIUM+ strength
   if(velDir == 0) return;

   double midPrice = (tk.bid + tk.ask) * 0.5;
   double bufPts   = InpEmaBufferPts * s.pt;

   // EMA trend direction — price must be clearly beyond the EMA
   bool emaUp   = (midPrice > s.emaVal + bufPts);
   bool emaDown = (midPrice < s.emaVal - bufPts);

   // Velocity must agree with EMA trend
   if(velDir ==  1 && !emaUp)   return;  // velocity up but price below EMA
   if(velDir == -1 && !emaDown) return;  // velocity down but price above EMA

   // RSI momentum confirm — only enter when RSI agrees with direction
   if(velDir ==  1 && s.rsiVal < InpRsiBuyMin)  return;
   if(velDir == -1 && s.rsiVal > InpRsiSellMax) return;

   // Max open positions per symbol
   if(CountOpenForSymbol(s.sym) >= InpMaxOpenPerSym) return;

   // Lot sizing
   double lot = CalcLot(s, tk.ask);

   // SL and TP — hard levels set at entry
   double slDist = s.atrPts * InpAtrSlMult * s.pt;
   double tpDist = s.atrPts * InpAtrTpMult * s.pt;

   double sl, tp;
   if(velDir == 1)
   {
      sl = NormalizeDouble(tk.ask - slDist, s.digits);
      tp = NormalizeDouble(tk.ask + tpDist, s.digits);
   }
   else
   {
      sl = NormalizeDouble(tk.bid + slDist, s.digits);
      tp = NormalizeDouble(tk.bid - tpDist, s.digits);
   }

   SetFilling(s.sym);
   string cmt = "VBS3_" + s.base + "_" + (velDir == 1 ? "B" : "S");

   bool ok = (velDir == 1)
      ? trade.Buy(lot, s.sym, 0, sl, tp, cmt)
      : trade.Sell(lot, s.sym, 0, sl, tp, cmt);

   if(ok)
   {
      s.lastEntry = now;
      if(InpLogging && InpLogLevel >= 1)
         Print("OPEN ", s.sym, " ", (velDir==1?"BUY":"SELL"),
               "  lot=", DoubleToString(lot, 2),
               "  sl=",  DoubleToString(sl, s.digits),
               "  tp=",  DoubleToString(tp, s.digits),
               "  atr=", DoubleToString(s.atrPts, 1),
               "  rsi=", DoubleToString(s.rsiVal, 1),
               "  vel=", DoubleToString(vel, 2));
   }
   else if(InpLogging)
      Print("OPEN FAIL ", s.sym,
            " code=", trade.ResultRetcode(),
            " ",      trade.ResultRetcodeDescription());
}

//=============================================================================
// SECTION I — EXIT ENGINE
// Winners: optional trailing stop once profit >= InpTrailActiveMult * ATR$
// Losers:  DO NOTHING — the hard SL set at entry handles it automatically.
//          Never hold losers hoping for recovery; let the broker close them.
//=============================================================================

void ManageExits()
{
   if(!InpUseTrail) return;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!ticket || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MAGIC) continue;

      string posSym = PositionGetString(POSITION_SYMBOL);

      int spIdx = -1;
      for(int j = 0; j < g_symCount; j++)
         if(g_sym[j].sym == posSym) { spIdx = j; break; }
      if(spIdx < 0) continue;

      MqlTick tk;
      if(!SymbolInfoTick(posSym, tk)) continue;

      double lots   = PositionGetDouble(POSITION_VOLUME);
      double curSl  = PositionGetDouble(POSITION_SL);
      double gross  = PositionGetDouble(POSITION_PROFIT)
                    + PositionGetDouble(POSITION_SWAP);
      ENUM_POSITION_TYPE ptype =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double atr    = g_sym[spIdx].atrPts;
      double atrVal = AtrToDollar(g_sym[spIdx], lots);

      // Only trail once profit >= activation threshold
      if(atrVal <= 0.0 || gross < atrVal * InpTrailActiveMult) continue;

      double trailDist = atr * InpTrailDistMult * g_sym[spIdx].pt;
      double trailSl;
      bool   needsMove;

      if(ptype == POSITION_TYPE_BUY)
      {
         trailSl   = NormalizeDouble(tk.bid - trailDist, g_sym[spIdx].digits);
         needsMove = (trailSl > curSl + g_sym[spIdx].pt);
      }
      else
      {
         trailSl   = NormalizeDouble(tk.ask + trailDist, g_sym[spIdx].digits);
         needsMove = (curSl == 0.0 || trailSl < curSl - g_sym[spIdx].pt);
      }

      if(needsMove)
      {
         double curTp = PositionGetDouble(POSITION_TP);
         trade.PositionModify(ticket, trailSl, curTp);
         if(InpLogging && InpLogLevel >= 2)
            Print("TRAIL ", posSym, " #", ticket,
                  " sl=", DoubleToString(trailSl, g_sym[spIdx].digits),
                  " profit=$", DoubleToString(gross, 2));
      }
   }
}

//=============================================================================
// SECTION J — LOT SIZING (ATR risk-based)
//=============================================================================

double CalcLot(SymState &s, double askPx)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double free    = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   double slDist  = s.atrPts * InpAtrSlMult * s.pt;
   if(slDist <= 0.0) return InpMinLot;

   double riskAmt = balance * InpRiskPct / 100.0;

   double tv = SymbolInfoDouble(s.sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(s.sym, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0.0 || ts <= 0.0) return InpMinLot;

   double lot = riskAmt / (slDist / ts * tv);

   // Cap by free margin (use at most 60% per trade)
   double mgnPer = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, s.sym, lot, askPx, mgnPer) && mgnPer > 0.0)
   {
      double mgnMax = free * 0.60;
      if(mgnPer > mgnMax)
         lot = MathMax(InpMinLot, lot * (mgnMax / mgnPer));
   }

   double step   = SymbolInfoDouble(s.sym, SYMBOL_VOLUME_STEP);
   double volMin = SymbolInfoDouble(s.sym, SYMBOL_VOLUME_MIN);
   double volMax = SymbolInfoDouble(s.sym, SYMBOL_VOLUME_MAX);
   if(step   > 0.0) lot = MathFloor(lot / step) * step;
   if(volMin > 0.0) lot = MathMax(volMin, lot);
   if(volMax > 0.0) lot = MathMin(volMax, lot);

   return MathMax(InpMinLot, MathMin(InpMaxLot, lot));
}

//=============================================================================
// SECTION K — HELPERS
//=============================================================================

int CountOpenForSymbol(string sym)
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!t || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MAGIC) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym) n++;
   }
   return n;
}

void SetFilling(string sym)
{
   uint mode = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((mode & 1) != 0)      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((mode & 2) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                      trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

int FindAllSymbols(string base, string &results[], int maxResults)
{
   int found = 0;
   int bLen  = StringLen(base);
   int total = SymbolsTotal(false);

   for(int i = 0; i < total && found < maxResults; i++)
   {
      string s    = SymbolName(i, false);
      int    sLen = StringLen(s);

      if(sLen < bLen) continue;
      if(StringFind(s, base) != 0) continue;
      if(sLen > bLen + 6) continue;

      if(!SymbolSelect(s, true)) continue;
      ENUM_SYMBOL_TRADE_MODE tmode =
         (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(s, SYMBOL_TRADE_MODE);
      if(tmode == SYMBOL_TRADE_MODE_DISABLED) continue;

      results[found++] = s;
   }
   return found;
}

//=============================================================================
// SECTION L — DISPLAY PANEL
//=============================================================================

void ShowPanel()
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   double floating = 0.0;
   int    open     = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!t || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MAGIC)
      {
         floating += PositionGetDouble(POSITION_PROFIT)
                   + PositionGetDouble(POSITION_SWAP);
         open++;
      }
   }

   string panel = "\n=== VelocityBankScalper v3.0 ===\n";
   panel += "Session : " + SessionStr() + "\n";
   panel += "Trades  : " + IntegerToString(open) + " open\n";
   panel += "Floating: $" + DoubleToString(floating, 2) + "\n";
   panel += "Balance : $" + DoubleToString(balance, 2)  + "\n";
   panel += "Equity  : $" + DoubleToString(equity,  2)  + "\n\n";

   panel += "--- Symbols ---\n";
   for(int i = 0; i < g_symCount; i++)
   {
      if(!g_sym[i].valid) continue;
      double vel; int dir;
      bool hasVel = CalcVel(g_sym[i], vel, dir);
      string dirStr = (dir==1)?"^":(dir==-1)?"v":"-";

      MqlTick tk;
      SymbolInfoTick(g_sym[i].sym, tk);
      double spread = (tk.ask - tk.bid) / g_sym[i].pt;

      panel += g_sym[i].base
            + ": vel=" + (hasVel ? DoubleToString(vel,1)+dirStr : "--")
            + "  atr=" + DoubleToString(g_sym[i].atrPts, 1)
            + "  rsi=" + DoubleToString(g_sym[i].rsiVal, 1)
            + "  spd=" + DoubleToString(spread, 1)
            + "  pos=" + IntegerToString(CountOpenForSymbol(g_sym[i].sym))
            + "\n";
   }

   panel += "\nSTATUS: ACTIVE  |  v3.0 (EMA+RSI filtered)";
   Comment(panel);
}
