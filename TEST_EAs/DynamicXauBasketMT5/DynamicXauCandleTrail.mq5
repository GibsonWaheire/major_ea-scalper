// ============================================================
// DynamicXauCandleTrail.mq5  v5.0
// XAUUSD M1 — Every Candle Entry + Trailing Stop Exit
//
// RULES:
//   1. No trade active  → read last closed candle direction → ENTER
//   2. Trade active     → trail SL tightly every tick, no new entries
//   3. Trade closed     → skip this candle, enter on the next one
//
// FILLING MODE: Auto-tries FOK → IOC → RETURN until one works
// SL          : Respects broker minimum stop level + 2x spread
// TRAIL       : Activates after TrailActivatePips, trails TrailDistPips
// ============================================================

#property copyright "Copyright 2026, McGibs Digital Solutions"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "5.00"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade        trade;
CPositionInfo pos;

// ===== Core =====
input group "===== Core Settings ====="
input string          TradeSymbol       = "";     // Blank = use chart symbol
input int             MagicNumber       = 905545;
input ENUM_TIMEFRAMES TradeTF           = PERIOD_M1;

// ===== Stop Loss =====
input group "===== Stop Loss ====="
input double          StopLossPips      = 20.0;  // SL distance in pips (auto-extended if broker requires more)

// ===== Trailing Stop =====
input group "===== Trailing Stop ====="
input double          TrailActivatePips = 5.0;   // Start trailing after X pips profit
input double          TrailDistPips     = 4.0;   // Trail this many pips behind price

// ===== Lot Sizing =====
input group "===== Lot Sizing ====="
input bool            UseRiskPercent    = true;
input double          RiskPercent       = 1.0;   // % of balance to risk (any account currency)
input double          BaseLot           = 0.01;  // Fixed lot if UseRiskPercent=false
input double          MaxLot            = 0.10;

// ===== Execution =====
input group "===== Execution ====="
input int             DeviationPts      = 50;    // Slippage allowance in points

// ============================================================
// GLOBALS
// ============================================================
string   g_sym       = "";
datetime lastBarTime = 0;
datetime lastExitBar = 0;

// ============================================================
// INIT
// ============================================================
int OnInit()
{
   g_sym = (TradeSymbol == "") ? _Symbol : TradeSymbol;

   if(!SymbolSelect(g_sym, true))
   { Print("Symbol unavailable: ", g_sym); return INIT_FAILED; }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPts);

   Print("CandleTrail v5.0 | sym=", g_sym,
         " | SL=", StopLossPips, "p | Trail=", TrailDistPips, "p",
         " | filling=auto-detect");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {}

// ============================================================
// HELPERS
// ============================================================
double PipSize()
{
   double pt = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   int    dg = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   return (dg == 3 || dg == 5) ? pt * 10.0 : pt;
}

double NormalizeVol(double lots)
{
   double mn = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   lots = MathMax(mn, MathMin(mx, lots));
   if(st > 0) lots = MathFloor(lots / st + 1e-10) * st;
   return NormalizeDouble(lots, 2);
}

double CalcLot(double slDist)
{
   if(!UseRiskPercent || slDist <= 0) return NormalizeVol(BaseLot);
   double tv = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0) return NormalizeVol(BaseLot);
   double lot = (AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0)
                / (slDist / ts * tv);
   return NormalizeVol(MathMin(lot, MaxLot));
}

double CalcSLDist()
{
   double pip    = PipSize();
   double pt     = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   double ask    = SymbolInfoDouble(g_sym, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(g_sym, SYMBOL_BID);
   long   stopLv = SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL);
   double spread = ask - bid;

   double fromUser   = StopLossPips * pip;
   double fromBroker = (stopLv + 20) * pt;   // broker minimum + 20pt buffer
   double fromSpread = spread * 3.0;          // at least 3x spread

   return MathMax(fromUser, MathMax(fromBroker, fromSpread));
}

int CountMyPos()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() == g_sym && pos.Magic() == MagicNumber) n++;
   }
   return n;
}

int GetBasketDir()
{
   int b = 0, s = 0;
   for(int i = PositionsTotal()-1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != g_sym || pos.Magic() != MagicNumber) continue;
      if(pos.PositionType() == POSITION_TYPE_BUY) b++; else s++;
   }
   if(b == 0 && s == 0) return 0;
   return (b >= s) ? 1 : -1;
}

int LastCandleDir()
{
   double o[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);
   if(CopyOpen (g_sym, TradeTF, 1, 1, o) < 1) return 0;
   if(CopyClose(g_sym, TradeTF, 1, 1, c) < 1) return 0;
   if(c[0] == o[0]) return 1;
   return (c[0] > o[0]) ? 1 : -1;
}

// ============================================================
// SEND ORDER — tries FOK, IOC, RETURN until one succeeds
// ============================================================
bool SendOrder(int dir, double lot, double sl)
{
   ENUM_ORDER_TYPE_FILLING modes[3];
   modes[0] = ORDER_FILLING_FOK;
   modes[1] = ORDER_FILLING_IOC;
   modes[2] = ORDER_FILLING_RETURN;

   for(int i = 0; i < 3; i++)
   {
      trade.SetTypeFilling(modes[i]);
      bool sent = (dir > 0)
                  ? trade.Buy (lot, g_sym, 0, sl, 0, "CandleTrail")
                  : trade.Sell(lot, g_sym, 0, sl, 0, "CandleTrail");

      uint code = trade.ResultRetcode();
      Print("Fill=", EnumToString(modes[i]), " code=", code, " ", trade.ResultRetcodeDescription());

      if(code == TRADE_RETCODE_DONE ||
         code == TRADE_RETCODE_PLACED ||
         code == TRADE_RETCODE_DONE_PARTIAL)
      {
         Print("Order placed using ", EnumToString(modes[i]));
         return true;
      }

      // Only retry on fill-related rejections
      if(code != TRADE_RETCODE_REJECT &&
         code != TRADE_RETCODE_INVALID_FILL)
         break;
   }
   return false;
}

// ============================================================
// TRAILING STOP — every tick
// ============================================================
void ManageTrail()
{
   double pip   = PipSize();
   double actDist = TrailActivatePips * pip;
   double tDist   = TrailDistPips    * pip;
   int    dg    = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   double pt    = SymbolInfoDouble(g_sym, SYMBOL_POINT);

   for(int i = PositionsTotal()-1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != g_sym || pos.Magic() != MagicNumber) continue;

      double sl   = pos.StopLoss();
      double open = pos.PriceOpen();
      double bid  = SymbolInfoDouble(g_sym, SYMBOL_BID);
      double ask  = SymbolInfoDouble(g_sym, SYMBOL_ASK);

      if(pos.PositionType() == POSITION_TYPE_BUY)
      {
         if(bid - open < actDist) continue;
         double nSL = NormalizeDouble(bid - tDist, dg);
         if(nSL > sl + pt)
            trade.PositionModify(pos.Ticket(), nSL, 0);
      }
      else
      {
         if(open - ask < actDist) continue;
         double nSL = NormalizeDouble(ask + tDist, dg);
         if(sl == 0 || nSL < sl - pt)
            trade.PositionModify(pos.Ticket(), nSL, 0);
      }
   }
}

// ============================================================
// ON TICK
// ============================================================
void OnTick()
{
   ManageTrail();

   // Candle-level logic — once per new bar
   datetime bt[1];
   if(CopyTime(g_sym, TradeTF, 0, 1, bt) < 1) return;
   if(bt[0] == lastBarTime) return;
   lastBarTime = bt[0];

   if(CountMyPos() > 0) return;                    // Trade open — wait
   if(lastExitBar == bt[0]) return;                 // Just closed — skip this candle

   int sig = LastCandleDir();
   if(sig == 0) return;

   double slDist = CalcSLDist();
   double lot    = CalcLot(slDist);
   int    dg     = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   double ask    = SymbolInfoDouble(g_sym, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(g_sym, SYMBOL_BID);
   double sl     = (sig > 0)
                   ? NormalizeDouble(ask - slDist, dg)
                   : NormalizeDouble(bid + slDist, dg);

   Print(">>> ", (sig>0?"BUY":"SELL"), " lot=", lot,
         " sl=", sl, " slDist=", slDist,
         " ask=", ask, " bid=", bid);

   SendOrder(sig, lot, sl);
}

// ============================================================
// TRACK CLOSES (broker SL hit / manual close)
// ============================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal_type != DEAL_TYPE_BUY && trans.deal_type != DEAL_TYPE_SELL) return;
   datetime bt[1];
   if(CopyTime(g_sym, TradeTF, 0, 1, bt) >= 1)
      lastExitBar = bt[0];
}
