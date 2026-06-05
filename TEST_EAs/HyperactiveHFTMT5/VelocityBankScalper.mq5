#property copyright "Copyright 2026, VelocityBankScalper"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.10"
#property description "Multi-pair tick-velocity HFT basket scalper"
#property description "JPY pairs + US30 | Auto-detects broker suffixes"
#property description "Exits ONLY on net profit | Scales with free margin"

#include <Trade/Trade.mqh>
CTrade trade;

// =============================================================================
// INPUTS
// =============================================================================

input group "===== Symbols ====="
input string InpSymbols       = "USDJPY,GBPJPY,CADJPY,EURJPY,AUDJPY,NZDJPY";
// Base names only — broker suffix (.Z .b .m etc.) is auto-detected at startup.
// You can also add US30, NAS100, XAUUSD etc.

input group "===== Lot & Margin ====="
input double InpMinLot        = 0.10;   // Minimum lot size per trade
input double InpMarginUsePct  = 80.0;   // % of free margin to utilise (all symbols combined)
input int    InpMaxTrades     = 20;     // Hard cap: max simultaneous open positions (all symbols)

input group "===== Entry — Velocity ====="
input int    InpVelLookback   = 10;     // Snapshot buffer depth for velocity
input double InpVelStrong     = 3.0;    // pts/snapshot → STRONG (hold, let profits run)
input double InpVelMedium     = 1.5;    // pts/snapshot → MEDIUM (close at MedTarget)
input double InpVelWeak       = 0.5;    // pts/snapshot → WEAK   (close at MinTarget)
input double InpMaxSpreadPts  = 15.0;   // Max spread in points to allow entry
input int    InpCooldownSec   = 2;      // Min seconds between new entries (per symbol)

input group "===== Profit Targets (net of fees) ====="
input double InpMinProfitUSD  = 0.10;   // Close ($) when velocity WEAK / FLAT
input double InpMedProfitUSD  = 0.50;   // Close ($) when velocity MEDIUM
// STRONG velocity → hold until direction reverses

input group "===== Broker Fees ====="
input double InpCommPerLot    = 3.50;   // Round-turn commission per lot ($)
// Set 0 if your broker embeds commission in the spread

input group "===== Safety ====="
input double InpEmergStopPts  = 150.0;  // Points adverse per trade → emergency close
input double InpMaxDrawdownPct= 30.0;   // Account drawdown % → stop all trading
input int    InpMaxEmergStreak= 5;      // Consecutive emergency closes → pause

input group "===== Debug ====="
input bool   InpLogging       = true;

// =============================================================================
// STRUCTURES
// =============================================================================

#define MAGIC   20260605
#define BUFLEN  60
#define MAXSYM  16

struct SymState
{
   string   sym;           // Resolved symbol name (with broker suffix)
   string   base;          // User-supplied base name
   double   pt;            // Symbol point size
   int      digits;
   bool     valid;         // Successfully initialised

   // Price snapshot ring-buffer
   double   mid[BUFLEN];
   int      filled;

   // Per-symbol entry cooldown
   datetime lastEntry;
};

SymState g_sym[MAXSYM];
int      g_symCount   = 0;

double   g_startBal   = 0.0;
bool     g_stopped    = false;
int      g_emergStreak= 0;

enum EVel { VEL_FLAT=0, VEL_WEAK=1, VEL_MEDIUM=2, VEL_STRONG=3 };

// =============================================================================
// INIT
// =============================================================================

int OnInit()
{
   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(50);

   g_symCount  = 0;
   g_startBal  = AccountInfoDouble(ACCOUNT_BALANCE);
   g_stopped   = false;
   g_emergStreak = 0;

   // Parse comma-separated symbol list
   string parts[];
   int n = StringSplit(InpSymbols, ',', parts);

   for(int i = 0; i < n && g_symCount < MAXSYM; i++)
   {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      if(StringLen(parts[i]) == 0) continue;

      string resolved = FindSymbol(parts[i]);
      if(resolved == "")
      {
         Print("WARNING: '", parts[i], "' not found in Market Watch — skipped.");
         continue;
      }

      SymbolSelect(resolved, true);

      g_sym[g_symCount].base   = parts[i];
      g_sym[g_symCount].sym    = resolved;
      g_sym[g_symCount].pt     = SymbolInfoDouble(resolved, SYMBOL_POINT);
      g_sym[g_symCount].digits = (int)SymbolInfoInteger(resolved, SYMBOL_DIGITS);
      g_sym[g_symCount].valid  = true;
      g_sym[g_symCount].filled = 0;
      g_sym[g_symCount].lastEntry = 0;
      ArrayInitialize(g_sym[g_symCount].mid, 0.0);

      // Set filling type per symbol
      SetFilling(resolved);

      Print("Symbol loaded: ", parts[i], " -> ", resolved,
            "  pt=", g_sym[g_symCount].pt, "  digits=", g_sym[g_symCount].digits);
      g_symCount++;
   }

   if(g_symCount == 0)
   {
      Alert("VelocityBankScalper: No valid symbols found. Check InpSymbols and Market Watch.");
      return INIT_FAILED;
   }

   Print("========================================");
   Print("VelocityBankScalper v1.10  started");
   Print("Active symbols : ", g_symCount);
   Print("Min lot        : ", InpMinLot,
         "  MarginUse: ", InpMarginUsePct, "%",
         "  MaxTrades: ", InpMaxTrades);
   Print("Vel thresholds : Strong=", InpVelStrong,
         " Med=", InpVelMedium, " Weak=", InpVelWeak, " pts/snap");
   Print("Targets        : $", InpMinProfitUSD,
         " / $", InpMedProfitUSD, " / hold(STRONG)");
   Print("Commission     : $", InpCommPerLot, "/lot");
   Print("EmergStop      : ", InpEmergStopPts,
         " pts  MaxDD: ", InpMaxDrawdownPct, "%");
   Print("========================================");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
}

// =============================================================================
// FILLING TYPE — detect per symbol
// =============================================================================

void SetFilling(string sym)
{
   uint mode = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((mode & 1) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((mode & 2) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

// =============================================================================
// SYMBOL RESOLVER — tries exact name then scans for base+suffix variants
// =============================================================================

string FindSymbol(string base)
{
   // 1. Exact match
   if(SymbolSelect(base, true)) return base;

   // 2. Scan all available symbols for base + short suffix
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
   {
      string s   = SymbolName(i, false);
      int    bLen = StringLen(base);
      int    sLen = StringLen(s);

      // Must start with base name exactly, suffix max 4 chars (.Z .b .m z b etc.)
      if(sLen > bLen && sLen <= bLen + 4 && StringFind(s, base) == 0)
         return s;
   }
   return "";
}

// =============================================================================
// MAIN TICK
// =============================================================================

void OnTick()
{
   // Snapshot all symbols' prices on every tick event
   // (chart symbol fires OnTick; we piggy-back to check all others)
   for(int i = 0; i < g_symCount; i++)
      PushSnapshot(g_sym[i]);

   if(g_stopped) { ShowPanel(); return; }
   if(CheckDrawdown()) { ShowPanel(); return; }

   // Manage exits across all positions
   ManageExits();

   // Attempt entries across all symbols
   for(int i = 0; i < g_symCount; i++)
      TryEntry(g_sym[i]);

   ShowPanel();
}

// =============================================================================
// PRICE SNAPSHOT — maintains per-symbol ring-buffer
// =============================================================================

void PushSnapshot(SymState &s)
{
   MqlTick tk;
   if(!SymbolInfoTick(s.sym, tk)) return;

   double mid = (tk.bid + tk.ask) * 0.5;

   // Shift ring buffer
   for(int i = BUFLEN - 1; i > 0; i--)
      s.mid[i] = s.mid[i-1];

   s.mid[0] = mid;
   if(s.filled < BUFLEN) s.filled++;
}

// =============================================================================
// VELOCITY — per symbol, returns pts/snapshot and direction
// =============================================================================

EVel CalcVel(SymState &s, double &ptsPerSnap, int &dir)
{
   ptsPerSnap = 0.0;
   dir        = 0;

   if(s.filled < InpVelLookback) return VEL_FLAT;

   double oldest = s.mid[InpVelLookback - 1];
   double newest = s.mid[0];
   double chg    = newest - oldest;

   ptsPerSnap = MathAbs(chg) / s.pt / InpVelLookback;
   dir        = (chg > 0) ? 1 : (chg < 0 ? -1 : 0);

   if(ptsPerSnap >= InpVelStrong) return VEL_STRONG;
   if(ptsPerSnap >= InpVelMedium) return VEL_MEDIUM;
   if(ptsPerSnap >= InpVelWeak)   return VEL_WEAK;
   return VEL_FLAT;
}

// =============================================================================
// ENTRY — per symbol
// =============================================================================

void TryEntry(SymState &s)
{
   if(!s.valid) return;
   if(s.filled < InpVelLookback) return;

   datetime now = TimeCurrent();
   bool inTester = (bool)MQLInfoInteger(MQL_TESTER);
   if(!inTester && (int)(now - s.lastEntry) < InpCooldownSec) return;

   MqlTick tk;
   if(!SymbolInfoTick(s.sym, tk)) return;

   double spread = (tk.ask - tk.bid) / s.pt;
   if(spread > InpMaxSpreadPts) return;

   double vel; int dir;
   EVel tier = CalcVel(s, vel, dir);
   // In tester, skip velocity filter — simulated ticks lack real velocity signal
   if(!inTester && (tier < VEL_WEAK || dir == 0)) return;
   if(inTester && dir == 0) return;

   // Check total open positions vs allowed
   int openTotal = CountAllPos();
   int maxMgn    = CalcMaxFromMargin(s.sym, tk.ask);
   int allowed   = MathMin(InpMaxTrades, maxMgn);
   if(openTotal >= allowed) return;

   // Apply correct filling for this symbol before placing order
   SetFilling(s.sym);

   double price = (dir == 1) ? tk.ask : tk.bid;
   string cmt   = "VBS_" + s.base + "_" + (dir == 1 ? "B" : "S");

   bool ok = (dir == 1)
      ? trade.Buy(InpMinLot,  s.sym, price, 0, 0, cmt)
      : trade.Sell(InpMinLot, s.sym, price, 0, 0, cmt);

   if(ok)
   {
      s.lastEntry = now;
      if(InpLogging)
         Print("OPEN ", s.sym, " ", (dir==1?"BUY":"SELL"),
               " lot=", InpMinLot,
               " px=", DoubleToString(price, s.digits),
               " vel=", VelStr(tier), " (", DoubleToString(vel,2), " pts/snap)",
               " spread=", DoubleToString(spread,1));
   }
   else if(InpLogging)
      Print("OPEN FAIL ", s.sym, ": ", trade.ResultRetcodeDescription());
}

// =============================================================================
// EXIT MANAGEMENT — profit-only, velocity-aware, one close per call
// =============================================================================

void ManageExits()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!ticket) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MAGIC) continue;

      string posSym = PositionGetString(POSITION_SYMBOL);

      // Find the SymState for this position's symbol
      int spIdx = -1;
      for(int j = 0; j < g_symCount; j++)
      {
         if(g_sym[j].sym == posSym) { spIdx = j; break; }
      }
      if(spIdx < 0) continue;

      MqlTick tk;
      if(!SymbolInfoTick(posSym, tk)) continue;

      double lots    = PositionGetDouble(POSITION_VOLUME);
      double openPx  = PositionGetDouble(POSITION_PRICE_OPEN);
      double gross   = PositionGetDouble(POSITION_PROFIT)
                     + PositionGetDouble(POSITION_SWAP);
      ENUM_POSITION_TYPE ptype =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      // --- Emergency close ---
      double ptsLoss = (ptype == POSITION_TYPE_BUY)
         ? (openPx - tk.bid) / g_sym[spIdx].pt
         : (tk.ask - openPx) / g_sym[spIdx].pt;

      if(ptsLoss >= InpEmergStopPts)
      {
         SetFilling(posSym);
         if(trade.PositionClose(ticket, 50))
         {
            g_emergStreak++;
            if(InpLogging)
               Print("EMERGENCY ", posSym, " #", ticket,
                     " loss=$", DoubleToString(gross,2),
                     " pts=", DoubleToString(ptsLoss,1),
                     " streak=", g_emergStreak);

            if(g_emergStreak >= InpMaxEmergStreak)
            {
               g_stopped = true;
               Print("TRADING PAUSED — ", InpMaxEmergStreak,
                     " emergency stops fired. Remove & re-attach EA to resume.");
            }
         }
         return; // one action per call
      }

      // --- Profit exit ---
      double netProfit = gross - (InpCommPerLot * lots);
      if(netProfit <= 0.0) continue; // still underwater net of fees — hold

      double vel; int dir;
      EVel tier = CalcVel(g_sym[spIdx], vel, dir);

      bool doClose = false;
      switch(tier)
      {
         case VEL_STRONG:
            // Momentum still running — only take profit if it reversed
            doClose = (ptype == POSITION_TYPE_BUY  && dir == -1)
                   || (ptype == POSITION_TYPE_SELL && dir ==  1);
            break;
         case VEL_MEDIUM:
            doClose = (netProfit >= InpMedProfitUSD);
            break;
         case VEL_WEAK:
         case VEL_FLAT:
            doClose = (netProfit >= InpMinProfitUSD);
            break;
      }

      if(doClose)
      {
         SetFilling(posSym);
         if(trade.PositionClose(ticket, 50))
         {
            g_emergStreak = 0;
            if(InpLogging)
               Print("PROFIT ", posSym, " #", ticket,
                     " net=$", DoubleToString(netProfit,2),
                     " vel=", VelStr(tier));
         }
         return; // one close per call — server-friendly
      }
   }
}

// =============================================================================
// MARGIN-BASED MAX TRADES (across ALL symbols combined)
// =============================================================================

int CalcMaxFromMargin(string sym, double askPx)
{
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double mgnPerTrade = 0.0;

   if(!OrderCalcMargin(ORDER_TYPE_BUY, sym, InpMinLot, askPx, mgnPerTrade)
      || mgnPerTrade <= 0.0)
      return 1;

   double usable = free * (InpMarginUsePct / 100.0);
   return (int)MathMax(1, MathFloor(usable / mgnPerTrade));
}

// =============================================================================
// DRAWDOWN PROTECTION
// =============================================================================

bool CheckDrawdown()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_startBal <= 0.0) return false;

   double dd = (g_startBal - equity) / g_startBal * 100.0;
   if(dd < InpMaxDrawdownPct) return false;

   g_stopped = true;
   Print("MAX DRAWDOWN (", DoubleToString(dd,1), "%) — closing all & stopping.");

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!t) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MAGIC)
      {
         SetFilling(PositionGetString(POSITION_SYMBOL));
         trade.PositionClose(t, 50);
      }
   }
   return true;
}

// =============================================================================
// HELPERS
// =============================================================================

int CountAllPos()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!t) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MAGIC) n++;
   }
   return n;
}

string VelStr(EVel v)
{
   switch(v)
   {
      case VEL_STRONG: return "STRONG";
      case VEL_MEDIUM: return "MEDIUM";
      case VEL_WEAK:   return "WEAK";
      default:         return "FLAT";
   }
}

// =============================================================================
// DISPLAY PANEL
// =============================================================================

void ShowPanel()
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd      = (g_startBal > 0.0)
      ? MathMax(0.0, (g_startBal - equity) / g_startBal * 100.0) : 0.0;

   double floating = 0.0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!t) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MAGIC)
         floating += PositionGetDouble(POSITION_PROFIT)
                   + PositionGetDouble(POSITION_SWAP);
   }

   int open    = CountAllPos();
   MqlTick tk0;
   SymbolInfoTick(g_sym[0].sym, tk0);
   int maxMgn  = CalcMaxFromMargin(g_sym[0].sym, tk0.ask);
   int allowed = MathMin(InpMaxTrades, maxMgn);

   string s = "\n=== VelocityBankScalper v1.10 ===\n";
   s += "Trades : " + IntegerToString(open)
      + " open / " + IntegerToString(allowed) + " allowed\n";
   s += "Floating: $" + DoubleToString(floating, 2) + "\n";
   s += "Balance : $" + DoubleToString(balance, 2) + "\n";
   s += "Equity  : $" + DoubleToString(equity,  2) + "\n";
   s += "Drawdown: " + DoubleToString(dd, 1) + "%\n";
   s += "Emerg   : " + IntegerToString(g_emergStreak)
      + " / " + IntegerToString(InpMaxEmergStreak) + "\n\n";

   // Per-symbol velocity snapshot
   s += "--- Symbol Velocity ---\n";
   for(int i = 0; i < g_symCount; i++)
   {
      double vel; int dir;
      EVel tier = CalcVel(g_sym[i], vel, dir);
      string dirStr = (dir == 1) ? "^" : (dir == -1) ? "v" : "-";

      // Count open positions for this symbol
      int symOpen = 0;
      for(int j = PositionsTotal()-1; j >= 0; j--)
      {
         ulong t = PositionGetTicket(j);
         if(!t) continue;
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) == MAGIC &&
            PositionGetString(POSITION_SYMBOL) == g_sym[i].sym)
            symOpen++;
      }

      MqlTick tk;
      SymbolInfoTick(g_sym[i].sym, tk);
      double spread = (tk.ask - tk.bid) / g_sym[i].pt;

      s += g_sym[i].base + ": " + VelStr(tier) + " " + dirStr
         + "  vel=" + DoubleToString(vel,1)
         + "  spd=" + DoubleToString(spread,1)
         + "  pos=" + IntegerToString(symOpen) + "\n";
   }

   s += "\n" + (g_stopped ? ">>> STATUS: STOPPED <<<" : "STATUS: ACTIVE");
   Comment(s);
}
