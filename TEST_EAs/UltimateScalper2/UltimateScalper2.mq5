// UltimateScalper2.mq5
// HFT Basket + Quality Hold State Machine
// Mode 1: HFT basket scalp — close at any profit, no SL pressure
// Mode 2: Cooldown (N seconds) after trade threshold
// Mode 3: Quality Hold — single H1-filtered trade with SL + TP, then reset
#property copyright "UltimateScalper2"
#property link      "local"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

// ─── Core ────────────────────────────────────────────────────────────────────
input string          TradeSymbol              = "XAUUSD";
input int             MagicNumber              = 905534;
input double          BaseLot                  = 0.02;
input double          LotStep                  = 0.00;    // 0 = flat lot for all trades
input double          MaxLot                   = 0.02;
input int             MaxTotalTrades           = 6;       // Max positions per HFT basket
input int             DeviationPoints          = 30;
input double          SpreadLimitPoints        = 300;

// ─── ATR & Momentum ──────────────────────────────────────────────────────────
input int             ATRPeriod                = 14;
input ENUM_TIMEFRAMES ATRTimeframe             = PERIOD_M1;
input ENUM_TIMEFRAMES MomentumTF               = PERIOD_M1;
input double          MomentumThresholdATR     = 0.15;    // Min momentum as ATR fraction
input int             MomentumLookback         = 2;       // Candles back for momentum calc
input int             MinSecondsBetweenEntries = 5;       // HFT entry rate limiter

// ─── HFT Entry ───────────────────────────────────────────────────────────────
input bool            UseLimitOrders           = true;
input int             MarketOrdersAtExecution  = 2;       // Instant market fills per signal
input int             LimitOrderCount          = 2;       // Limit orders stacked per signal
input double          BodyStrengthATR          = 0.25;    // Min candle body as ATR fraction (lower = more trades)
input double          CloseLocationPct         = 0.30;    // Close must be in top/bottom X% of range (higher = more trades)
input bool            RequireAcceleration      = false;   // Require momentum to be accelerating (false = more trades)

// ─── Stop Loss ───────────────────────────────────────────────────────────────
input bool            UseStopLoss              = true;
input bool            UseCandleSL              = true;    // Use High/Low candle for SL anchor
input int             CandleLookback           = 5;       // Candles to scan for H/L
input int             CandlePaddingPoints      = 100;     // Buffer beyond H/L in points
input double          StopLossATRMultiplier    = 3.0;     // ATR mult for floor SL distance
input double          StopLossMinPoints        = 1000;    // Min SL distance (breathing room)
input double          StopLossMaxPoints        = 1500;    // Max SL distance (account cap)

// ─── HFT Basket Profit ───────────────────────────────────────────────────────
input double          BasketProfitATRMult      = 2.5;     // Full target (ATR multiplier)
input bool            CloseAtAnyProfit         = true;    // Close basket at MinProfitToClose
input double          MinProfitToClose         = 0.01;    // Minimum profit to trigger close

// ─── State Machine ───────────────────────────────────────────────────────────
input int             HFTTradeThreshold        = 50;      // Market orders before cooldown
input int             HFTExtendedThreshold     = 70;      // Triggers extended cooldown
input int             CooldownSeconds          = 300;     // Base cooldown: 5 minutes
input double          QualitySL_ATR            = 1.5;     // Quality mode SL (ATR mult)
input double          QualityTP_ATR            = 3.0;     // Quality mode TP (ATR mult)
input int             QualityTimeoutSeconds    = 1800;    // Max quality hold: 30 min
input double          QualityRiskPercent       = 4.0;     // Quality mode risk % of equity

// ─── Margin Protection ───────────────────────────────────────────────────────
input double          MarginTriggerLevel       = 150.0;   // Close all if margin% drops below

// ─── Overall Profit Target ───────────────────────────────────────────────────
input double          ProfitTargetPercent      = 70.0;    // Stop all trading when profit reaches X% of starting balance

// ─── Globals ─────────────────────────────────────────────────────────────────
CTrade        trade;
CPositionInfo pos;
int           atrHandle     = -1;
datetime      lastEntryTime = 0;

enum EA_STATE { STATE_HFT = 0, STATE_COOLDOWN = 1, STATE_QUALITY = 2 };
EA_STATE eaState         = STATE_HFT;
int      hftTradeCount   = 0;       // Market orders opened this HFT cycle
datetime cooldownStart   = 0;
int      cooldownDur     = 0;       // Actual cooldown duration (may be extended)
ulong    qualityTicket   = 0;
datetime qualityOpenTime = 0;

// ─── Persistence (GlobalVariables) ───────────────────────────────────────────
// Survives chart period changes and MT5 restarts without closing trades.
#define GV_STATE      "US2_State"
#define GV_HFTCOUNT   "US2_HFTCount"
#define GV_COOLSTART  "US2_CoolStart"
#define GV_COOLDUR    "US2_CoolDur"
#define GV_QTICKET    "US2_QTicket"
#define GV_QOPENTIME  "US2_QOpenTime"
#define GV_STARTBAL   "US2_StartBal"
#define GV_STOPPED    "US2_Stopped"

double startingBalance  = 0;
bool   profitTargetHit  = false;

void SaveState()
{
   GlobalVariableSet(GV_STATE,     (double)eaState);
   GlobalVariableSet(GV_HFTCOUNT,  (double)hftTradeCount);
   GlobalVariableSet(GV_COOLSTART, (double)cooldownStart);
   GlobalVariableSet(GV_COOLDUR,   (double)cooldownDur);
   GlobalVariableSet(GV_QTICKET,   (double)qualityTicket);
   GlobalVariableSet(GV_QOPENTIME, (double)qualityOpenTime);
   GlobalVariableSet(GV_STARTBAL,  startingBalance);
   GlobalVariableSet(GV_STOPPED,   (double)profitTargetHit);
}

bool LoadState()
{
   if(!GlobalVariableCheck(GV_STATE)) return false;

   eaState         = (EA_STATE)(int)GlobalVariableGet(GV_STATE);
   hftTradeCount   = (int)GlobalVariableGet(GV_HFTCOUNT);
   cooldownStart   = (datetime)GlobalVariableGet(GV_COOLSTART);
   cooldownDur     = (int)GlobalVariableGet(GV_COOLDUR);
   qualityTicket   = (ulong)GlobalVariableGet(GV_QTICKET);
   qualityOpenTime = (datetime)GlobalVariableGet(GV_QOPENTIME);
   startingBalance = GlobalVariableGet(GV_STARTBAL);
   profitTargetHit = (bool)(int)GlobalVariableGet(GV_STOPPED);

   // Validate quality ticket still exists
   if(qualityTicket > 0 && !PositionSelectByTicket(qualityTicket))
   {
      Print("Restored: Quality ticket #", qualityTicket, " no longer open. Resetting to HFT.");
      hftTradeCount   = 0;
      qualityTicket   = 0;
      qualityOpenTime = 0;
      eaState         = STATE_HFT;
   }

   // If cooldown already elapsed while EA was off, advance to quality
   if(eaState == STATE_COOLDOWN && (TimeCurrent() - cooldownStart) >= cooldownDur)
   {
      Print("Restored: Cooldown already elapsed. Advancing to QUALITY mode.");
      eaState = STATE_QUALITY;
   }

   Print("State restored | Mode: ", EnumToString(eaState),
         " | HFT trades: ", hftTradeCount,
         " | Quality ticket: ", qualityTicket);
   return true;
}

// ─── Panel ───────────────────────────────────────────────────────────────────
#define PANEL_PREFIX  "US2_"
#define PANEL_X       10
#define PANEL_Y       20
#define PANEL_W       260
#define LINE_H        22
#define PANEL_LINES   8
#define PANEL_PAD_X   14
#define PANEL_PAD_Y   12

void PanelLabel(const string name, const string text, int x, int y, color clr, int sz = 8)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR,    ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,    true);
      ObjectSetString (0, name, OBJPROP_FONT,      "Consolas");
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  sz);
   ObjectSetString (0, name, OBJPROP_TEXT,      text);
}

void DrawPanel(double atr)
{
   int panelH = PANEL_LINES * LINE_H + (PANEL_PAD_Y * 2);

   // Background
   string bg = PANEL_PREFIX + "BG";
   if(ObjectFind(0, bg) < 0)
   {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN,      true);
      ObjectSetInteger(0, bg, OBJPROP_BACK,        true);
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   }
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, PANEL_X);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, PANEL_Y);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE,     PANEL_W);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE,     panelH);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR,   C'22,22,22');
   ObjectSetInteger(0, bg, OBJPROP_COLOR,     C'55,55,55');

   int tx = PANEL_X + PANEL_PAD_X;
   int ty = PANEL_Y + PANEL_PAD_Y;

   // Row 0 — Header
   PanelLabel(PANEL_PREFIX+"R0", "UltimateScalper2  v1.00", tx, ty, C'160,160,160', 8);
   ty += LINE_H;

   // Row 1 — Symbol + ATR
   PanelLabel(PANEL_PREFIX+"R1",
      StringFormat("%-8s  ATR: %.2f", TradeSymbol, atr),
      tx, ty, C'110,110,110', 8);
   ty += LINE_H;

   // Row 2 — Mode (colour-coded)
   string modeStr; color modeClr;
   if(profitTargetHit)
   {
      modeStr = "MODE:  PROFIT TARGET HIT";
      modeClr = C'255,215,0';  // Gold
   }
   else
   {
      switch(eaState)
      {
         case STATE_HFT:      modeStr = "MODE:  HFT ACTIVE";   modeClr = C'0,220,100';  break;
         case STATE_COOLDOWN: modeStr = "MODE:  COOLDOWN";      modeClr = C'255,160,0';  break;
         case STATE_QUALITY:  modeStr = "MODE:  QUALITY HOLD";  modeClr = C'80,185,255'; break;
         default:             modeStr = "MODE:  ---";           modeClr = clrWhite;
      }
   }
   PanelLabel(PANEL_PREFIX+"R2", modeStr, tx, ty, modeClr, 9);
   ty += LINE_H;

   // Row 3 — State detail
   string detStr = ""; color detClr = C'160,160,160';
   if(eaState == STATE_HFT)
   {
      detStr = StringFormat("Trades:  %d / %d", hftTradeCount, HFTTradeThreshold);
   }
   else if(eaState == STATE_COOLDOWN)
   {
      int rem = cooldownDur - (int)(TimeCurrent() - cooldownStart);
      if(rem < 0) rem = 0;
      detStr = StringFormat("Resume in:  %dm %02ds", rem / 60, rem % 60);
      detClr = C'255,160,0';
   }
   else if(eaState == STATE_QUALITY)
   {
      if(qualityTicket > 0)
      {
         int left = QualityTimeoutSeconds - (int)(TimeCurrent() - qualityOpenTime);
         if(left < 0) left = 0;
         detStr = StringFormat("Timeout in: %dm %02ds", left / 60, left % 60);
      }
      else detStr = "Waiting for H1 signal...";
      detClr = C'80,185,255';
   }
   PanelLabel(PANEL_PREFIX+"R3", detStr, tx, ty, detClr, 8);
   ty += LINE_H;

   // Row 4 — Basket P&L
   double profit = BasketProfit(TradeSymbol);
   color pnlClr  = (profit >= 0) ? C'0,210,90' : C'255,75,75';
   PanelLabel(PANEL_PREFIX+"R4",
      StringFormat("Basket P&L:  %+.2f", profit),
      tx, ty, pnlClr, 8);
   ty += LINE_H;

   // Row 5 — Positions + Pending
   PanelLabel(PANEL_PREFIX+"R5",
      StringFormat("Positions: %d   Pending: %d",
         PositionsCount(TradeSymbol), PendingOrdersCount(TradeSymbol)),
      tx, ty, C'110,110,110', 8);
   ty += LINE_H;

   // Row 6 — Margin
   double mgn    = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   color  mgnClr = (mgn > 200) ? C'0,210,90' : (mgn > MarginTriggerLevel ? C'255,160,0' : C'255,75,75');
   string mgnStr = (mgn <= 0) ? "Margin: N/A" : StringFormat("Margin: %.0f%%", mgn);
   PanelLabel(PANEL_PREFIX+"R6", mgnStr, tx, ty, mgnClr, 8);
   ty += LINE_H;

   // Row 7 — Overall profit progress toward target
   double curBal    = AccountInfoDouble(ACCOUNT_BALANCE);
   double profitPct = (startingBalance > 0) ? ((curBal - startingBalance) / startingBalance) * 100.0 : 0;
   double targetPct = ProfitTargetPercent;
   color  prgClr    = profitTargetHit ? C'255,215,0' : (profitPct >= targetPct * 0.75 ? C'0,210,90' : C'110,110,110');
   PanelLabel(PANEL_PREFIX+"R7",
      StringFormat("Profit: %+.1f%% / %.0f%%", profitPct, targetPct),
      tx, ty, prgClr, 8);

   ChartRedraw(0);
}

void DeletePanel()
{
   ObjectsDeleteAll(0, PANEL_PREFIX);
}

// ─── Symbol Helpers ──────────────────────────────────────────────────────────

bool EnsureSymbolReady(const string sym)
{
   if(!SymbolSelect(sym, true))                                           { Print("Symbol select failed: ", sym); return false; }
   if(SymbolInfoInteger(sym, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED) { Print("Trading disabled: ",    sym); return false; }
   return true;
}

void CloseAllExistingTrades(const string sym)
{
   int closed = 0, deleted = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol() != sym) continue;
      if(trade.PositionClose(pos.Ticket(), DeviationPoints)) closed++;
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t) || OrderGetString(ORDER_SYMBOL) != sym) continue;
      if(trade.OrderDelete(t)) deleted++;
   }
   if(closed > 0 || deleted > 0)
      Print("Startup cleanup: ", closed, " positions, ", deleted, " orders.");
}

bool SpreadOK(const string sym)
{
   double spread = (SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID))
                   / SymbolInfoDouble(sym, SYMBOL_POINT);
   return spread <= SpreadLimitPoints;
}

// ─── ATR & Momentum ──────────────────────────────────────────────────────────

double GetATR()
{
   double buf[2];
   if(atrHandle < 0 || CopyBuffer(atrHandle, 0, 0, 2, buf) < 1) return 0.0;
   return buf[0];
}

int DetectMomentum(const string sym, double atr, ENUM_TIMEFRAMES tf)
{
   if(atr <= 0) return 0;

   // ── Option A: Momentum Acceleration ──────────────────────────────────────
   // Requires momentum to be BUILDING across two consecutive candles,
   // not just present. Rejects drifts and fading moves.
   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(sym, tf, 0, 3, close) < 3) return 0;

   double velocity     = close[0] - close[1];  // current candle move
   double prevVelocity = close[1] - close[2];  // previous candle move

   bool accelBull = (velocity > 0 && prevVelocity > 0 && MathAbs(velocity) > MathAbs(prevVelocity));
   bool accelBear = (velocity < 0 && prevVelocity < 0 && MathAbs(velocity) > MathAbs(prevVelocity));
   bool dirBull   = velocity > 0;
   bool dirBear   = velocity < 0;

   // RequireAcceleration=true: both candles must agree AND accelerate (strict)
   // RequireAcceleration=false: just need directional velocity above threshold (relaxed)
   if(RequireAcceleration && !accelBull && !accelBear) return 0;
   if(!RequireAcceleration && !dirBull && !dirBear)    return 0;

   int dir = (RequireAcceleration ? accelBull : dirBull) ? 1 : -1;

   // ── ATR minimum threshold — filters micro-noise ───────────────────────────
   if(MathAbs(velocity) < atr * MomentumThresholdATR) return 0;

   // ── Option B: Candle Body Strength + Close Location ──────────────────────
   // Requires a decisive candle — large body, closed at the extreme.
   double open[], high[], low[];
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   if(CopyOpen(sym, tf, 0, 1, open) < 1) return 0;
   if(CopyHigh(sym, tf, 0, 1, high) < 1) return 0;
   if(CopyLow (sym, tf, 0, 1, low)  < 1) return 0;

   double body  = MathAbs(close[0] - open[0]);
   double range = high[0] - low[0];

   if(body  < atr * BodyStrengthATR) return 0;  // Weak candle — body too small
   if(range <= 0)                    return 0;

   double closePct = (close[0] - low[0]) / range;  // 0.0 = bottom, 1.0 = top
   if(dir > 0 && closePct < (1.0 - CloseLocationPct)) return 0;  // BUY: close in top X%
   if(dir < 0 && closePct > CloseLocationPct)          return 0;  // SELL: close in bottom X%

   return dir;
}

// H1 candle direction — uses completed candle [1] for signal stability
int GetH1Direction(const string sym)
{
   double h1c[], h1o[];
   ArraySetAsSeries(h1c, true);
   ArraySetAsSeries(h1o, true);
   if(CopyClose(sym, PERIOD_H1, 0, 2, h1c) < 2) return 0;
   if(CopyOpen( sym, PERIOD_H1, 0, 2, h1o) < 2) return 0;
   if(h1c[1] > h1o[1]) return  1;  // Bullish H1
   if(h1c[1] < h1o[1]) return -1;  // Bearish H1
   return 0;
}

// ─── Volume Helpers ──────────────────────────────────────────────────────────

double NormalizeVolume(const string sym, double lots)
{
   double minL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   lots = MathMax(minL, MathMin(maxL, lots));
   if(step > 0) lots = MathFloor(lots / step) * step;
   return NormalizeDouble(lots, 2);
}

double GetDynamicLot(const string sym, int tradeNum)
{
   double lot = (LotStep == 0.0) ? BaseLot : BaseLot + tradeNum * LotStep;
   return NormalizeVolume(sym, MathMin(MaxLot, MathMax(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), lot)));
}

// ─── Position/Order Counts ───────────────────────────────────────────────────

int PositionsCount(const string sym)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() == sym && pos.Magic() == MagicNumber) n++;
   }
   return n;
}

int PendingOrdersCount(const string sym)
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) == sym && OrderGetInteger(ORDER_MAGIC) == MagicNumber) n++;
   }
   return n;
}

int GetBasketDirection(const string sym)
{
   int buys = 0, sells = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol() != sym || pos.Magic() != MagicNumber) continue;
      if(pos.PositionType() == POSITION_TYPE_BUY) buys++; else sells++;
   }
   if(buys == 0 && sells == 0) return 0;
   return (buys >= sells) ? 1 : -1;
}

// ─── Basket P&L ──────────────────────────────────────────────────────────────

double BasketProfit(const string sym)
{
   double p = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol() != sym || pos.Magic() != MagicNumber) continue;
      p += pos.Profit() + pos.Swap() + pos.Commission();
   }
   return p;
}

double BasketLots(const string sym)
{
   double lots = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol() != sym || pos.Magic() != MagicNumber) continue;
      lots += pos.Volume();
   }
   return lots;
}

// ─── Close Helpers ───────────────────────────────────────────────────────────

void DeletePendingOrders(const string sym)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) == sym && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
         trade.OrderDelete(t);
   }
}

bool CloseBasket(const string sym)
{
   trade.SetAsyncMode(true);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol() != sym || pos.Magic() != MagicNumber) continue;
      trade.PositionClose(pos.Ticket(), DeviationPoints);
   }
   DeletePendingOrders(sym);
   trade.SetAsyncMode(false);
   return true;
}

// ─── Stop Loss Calculation ───────────────────────────────────────────────────

double GetCandleBasedSL(const string sym, int dir)
{
   double point   = SymbolInfoDouble(sym, SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double padding = CandlePaddingPoints * point;

   if(dir > 0)
   {
      double lows[];
      ArraySetAsSeries(lows, true);
      if(CopyLow(sym, MomentumTF, 1, CandleLookback, lows) < CandleLookback) return 0;
      return NormalizeDouble(lows[ArrayMinimum(lows)] - padding, digits);
   }
   else
   {
      double highs[];
      ArraySetAsSeries(highs, true);
      if(CopyHigh(sym, MomentumTF, 1, CandleLookback, highs) < CandleLookback) return 0;
      return NormalizeDouble(highs[ArrayMaximum(highs)] + padding, digits);
   }
}

// atrMult: pass > 0 to override StopLossATRMultiplier (used by quality mode)
double GetStopLoss(const string sym, int dir, double atr, double atrMult = -1)
{
   if(!UseStopLoss) return 0;

   double point    = SymbolInfoDouble(sym, SYMBOL_POINT);
   double bid      = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask      = SymbolInfoDouble(sym, SYMBOL_ASK);
   int    digits   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double mult     = (atrMult > 0) ? atrMult : StopLossATRMultiplier;
   double atrDist  = (atr > 0) ? atr * mult : 0;
   double minDist  = StopLossMinPoints * point;
   double maxDist  = StopLossMaxPoints * point;
   double floorDist = MathMax(minDist, MathMin((atrDist > 0 ? atrDist : minDist), maxDist));

   if(UseCandleSL)
   {
      double csl = GetCandleBasedSL(sym, dir);
      if(csl > 0)
      {
         // Ensure candle SL is never tighter than the floor distance
         if(dir > 0) csl = MathMin(csl, ask - floorDist);
         else        csl = MathMax(csl, bid + floorDist);
         return NormalizeDouble(csl, digits);
      }
   }
   double sl = (dir > 0) ? ask - floorDist : bid + floorDist;
   return NormalizeDouble(sl, digits);
}

// ─── HFT Mode ────────────────────────────────────────────────────────────────

double CalculateBasketProfitTarget(const string sym, double atr, double totalLots)
{
   if(atr <= 0 || totalLots <= 0) return 1.0;
   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) return 1.0;
   return MathMax((atr * BasketProfitATRMult) * (tv / ts) * totalLots, 1.0);
}

void ManageHFTExits(const string sym, double atr)
{
   double profit = BasketProfit(sym);
   double target = CalculateBasketProfitTarget(sym, atr, BasketLots(sym));
   if(profit >= target && profit > 0)            { CloseBasket(sym); return; }
   if(CloseAtAnyProfit && profit >= MinProfitToClose) { CloseBasket(sym); return; }
}

bool OpenMarket(const string sym, int dir, double atr)
{
   int total = PositionsCount(sym) + PendingOrdersCount(sym);
   if(total >= MaxTotalTrades) return false;
   double lot = GetDynamicLot(sym, total);
   if(lot <= 0) return false;
   double sl = GetStopLoss(sym, dir, atr);
   trade.SetExpertMagicNumber(MagicNumber);
   bool ok = (dir > 0) ? trade.Buy(lot, sym, 0, sl, 0) : trade.Sell(lot, sym, 0, sl, 0);
   if(ok) { hftTradeCount++; SaveState(); }
   return ok;
}

bool PlaceLimitOrders(const string sym, int dir, double atr)
{
   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double offsets[] = {0.2, 0.4, 0.6, 0.8, 1.0};
   int placed = 0;
   trade.SetExpertMagicNumber(MagicNumber);

   for(int i = 0; i < LimitOrderCount; i++)
   {
      int cur = PositionsCount(sym) + PendingOrdersCount(sym);
      if(cur >= MaxTotalTrades) break;
      double lot    = GetDynamicLot(sym, cur);
      double offset = atr * offsets[MathMin(i, 4)];
      double price  = (dir > 0) ? NormalizeDouble(bid - offset, digits) : NormalizeDouble(ask + offset, digits);
      double sl     = GetStopLoss(sym, dir, atr);
      bool ok = (dir > 0) ? trade.BuyLimit(lot, price, sym, sl) : trade.SellLimit(lot, price, sym, sl);
      if(ok) placed++;
   }
   return (placed > 0);
}

void EnterCooldown(const string sym)
{
   CloseBasket(sym);
   eaState      = STATE_COOLDOWN;
   cooldownStart = TimeCurrent();
   // Extended cooldown if second threshold was hit
   cooldownDur   = (hftTradeCount >= HFTExtendedThreshold) ? CooldownSeconds * 2 : CooldownSeconds;
   Print("HFT → COOLDOWN | trades=", hftTradeCount,
         " | cooldown=", cooldownDur, "s",
         (hftTradeCount >= HFTExtendedThreshold ? " [EXTENDED]" : ""));
   SaveState();
}

void RunHFT(const string sym, double atr)
{
   // Threshold check — evaluate before exits so we don't take new profits into cooldown
   if(hftTradeCount >= HFTTradeThreshold)
   {
      EnterCooldown(sym);
      return;
   }

   ManageHFTExits(sym, atr);

   // Rate limiter
   if(TimeCurrent() - lastEntryTime < MinSecondsBetweenEntries) return;

   int dir = DetectMomentum(sym, atr, MomentumTF);
   if(dir == 0) return;

   // Don't fight an existing basket
   int basketDir = GetBasketDirection(sym);
   if(basketDir != 0 && dir != basketDir) return;

   if(UseLimitOrders)
   {
      if(PendingOrdersCount(sym) > 0) return;
      for(int m = 0; m < MarketOrdersAtExecution; m++) OpenMarket(sym, dir, atr);
      PlaceLimitOrders(sym, dir, atr);
   }
   else
   {
      OpenMarket(sym, dir, atr);
   }
   lastEntryTime = TimeCurrent();
}

// ─── Risk-Based Lot (Quality Mode Only) ──────────────────────────────────────

double CalcRiskLot(const string sym, double entryPrice, double slPrice)
{
   double slDist = MathAbs(entryPrice - slPrice);
   if(slDist <= 0) return NormalizeVolume(sym, BaseLot); // fallback

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmt   = equity * (QualityRiskPercent / 100.0);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0) return NormalizeVolume(sym, BaseLot);

   double lot = riskAmt / ((slDist / tickSize) * tickValue);
   return NormalizeVolume(sym, lot);
}

// ─── Quality Mode ────────────────────────────────────────────────────────────

bool IsQualityPositionOpen()
{
   if(qualityTicket == 0) return false;
   return PositionSelectByTicket(qualityTicket);
}

void OpenQualityTrade(const string sym, double atr)
{
   // Require H1 candle alignment for direction — completed candle only
   int dir = GetH1Direction(sym);
   if(dir == 0)
   {
      Print("QUALITY: Waiting for H1 direction signal...");
      return;
   }

   // Also confirm M1 momentum agrees with H1
   int m1dir = DetectMomentum(sym, atr, MomentumTF);
   if(m1dir != 0 && m1dir != dir)
   {
      Print("QUALITY: M1 momentum conflicts with H1 direction. Waiting...");
      return;
   }

   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double entry  = (dir > 0) ? ask : bid;
   double sl     = GetStopLoss(sym, dir, atr, QualitySL_ATR);
   double tpDist = atr * QualityTP_ATR;
   double tp     = (dir > 0) ? NormalizeDouble(entry + tpDist, digits)
                              : NormalizeDouble(entry - tpDist, digits);
   double lot    = CalcRiskLot(sym, entry, sl);

   trade.SetExpertMagicNumber(MagicNumber);
   bool ok = (dir > 0) ? trade.Buy(lot, sym, 0, sl, tp) : trade.Sell(lot, sym, 0, sl, tp);
   if(ok)
   {
      qualityTicket   = trade.ResultOrder();
      qualityOpenTime = TimeCurrent();
      Print("QUALITY trade opened | ", (dir > 0 ? "BUY" : "SELL"),
            " | SL=", sl, " | TP=", tp, " | Lot=", lot);
      SaveState();
   }
   else
   {
      Print("QUALITY trade failed to open. RetCode=", trade.ResultRetcode());
   }
}

void ManageQualityTrade(const string sym)
{
   if(!IsQualityPositionOpen())
   {
      // TP or SL was hit — clean return to HFT
      Print("QUALITY trade closed (TP/SL hit). Resetting to HFT.");
      hftTradeCount   = 0;
      qualityTicket   = 0;
      qualityOpenTime = 0;
      eaState         = STATE_HFT;
      SaveState();
      return;
   }

   if(TimeCurrent() - qualityOpenTime >= QualityTimeoutSeconds)
   {
      Print("QUALITY trade timed out (", QualityTimeoutSeconds, "s). Closing → HFT.");
      trade.PositionClose(qualityTicket, DeviationPoints);
      hftTradeCount   = 0;
      qualityTicket   = 0;
      qualityOpenTime = 0;
      eaState         = STATE_HFT;
      SaveState();
   }
}

// ─── Lifecycle ───────────────────────────────────────────────────────────────

int OnInit()
{
   if(!EnsureSymbolReady(TradeSymbol)) return INIT_FAILED;

   atrHandle = iATR(TradeSymbol, ATRTimeframe, ATRPeriod);
   if(atrHandle < 0) { Print("ATR indicator failed to initialize."); return INIT_FAILED; }

   // Restore state if available — skips trade cleanup to preserve open positions
   if(!LoadState())
   {
      // Fresh start — no saved state, clean slate
      CloseAllExistingTrades(TradeSymbol);
      startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      profitTargetHit = false;
      Print("UltimateScalper2 v1.00 fresh start | Starting balance: ", startingBalance,
            " | Profit target: +", ProfitTargetPercent, "%");
      SaveState();
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   SaveState();
   IndicatorRelease(atrHandle);
   DeletePanel();
}

void OnTick()
{
   // ── Profit Target — stops all trading when reached ────────────────────────
   if(profitTargetHit)
   {
      DrawPanel(GetATR());
      return;
   }
   if(startingBalance > 0)
   {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double profitPct      = ((currentBalance - startingBalance) / startingBalance) * 100.0;
      if(profitPct >= ProfitTargetPercent)
      {
         CloseBasket(TradeSymbol);
         profitTargetHit = true;
         SaveState();
         Print("PROFIT TARGET HIT: +", DoubleToString(profitPct, 1), "% | Trading stopped.");
         return;
      }
   }

   // ── Margin Protection — always runs first ─────────────────────────────────
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(marginLevel > 0 && marginLevel < MarginTriggerLevel)
   {
      Print("Margin protection: ", marginLevel, "% below ", MarginTriggerLevel, "% — closing all.");
      CloseBasket(TradeSymbol);
      qualityTicket = 0;
      eaState       = STATE_COOLDOWN;
      cooldownStart = TimeCurrent();
      cooldownDur   = CooldownSeconds;
      SaveState();
      return;
   }

   if(!EnsureSymbolReady(TradeSymbol) || !SpreadOK(TradeSymbol)) return;
   double atr = GetATR();
   if(atr <= 0) return;

   // ── State Machine ─────────────────────────────────────────────────────────
   switch(eaState)
   {
      case STATE_HFT:
         RunHFT(TradeSymbol, atr);
         break;

      case STATE_COOLDOWN:
         if(TimeCurrent() - cooldownStart >= cooldownDur)
         {
            Print("Cooldown complete (", cooldownDur, "s) → QUALITY mode.");
            eaState = STATE_QUALITY;
            SaveState();
         }
         break;

      case STATE_QUALITY:
         if(qualityTicket == 0)
            OpenQualityTrade(TradeSymbol, atr);
         else
            ManageQualityTrade(TradeSymbol);
         break;
   }

   // ── Panel ─────────────────────────────────────────────────────────────────
   DrawPanel(atr);
}
