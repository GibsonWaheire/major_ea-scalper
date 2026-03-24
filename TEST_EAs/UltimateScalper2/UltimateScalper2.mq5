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
input string          TradeSymbol              = "";       // Blank = use chart symbol automatically
input int             MagicNumber              = 905534;
input bool            UseRiskPercent           = true;    // true = risk-% sizing (recommended); false = fixed BaseLot
input double          HFTRiskPercent           = 2.5;     // HFT mode: risk % of equity per trade
input double          BaseLot                  = 0.02;    // Fallback lot when UseRiskPercent=false or SL=0
input double          MaxLot                   = 0.10;    // Hard cap per trade (both modes)
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
input int             CandlePaddingPoints      = 100;     // Buffer beyond H/L in points (used when PaddingATRMult=0)
input double          StopLossATRMultiplier    = 3.0;     // ATR mult for SL distance
input double          StopLossMinPoints        = 1000;    // Min SL distance in points (used when SLFloorATRMult=0)
input double          StopLossMaxPoints        = 1500;    // Max SL distance in points (used when SLCeilingATRMult=0)

// ─── Instrument Scaling (ATR-relative — set > 0 for non-XAUUSD instruments) ──
// These replace the fixed-point limits above and scale automatically with volatility.
// Recommended for forex: SLFloor=1.5, SLCeiling=6.0, Spread=0.3, Padding=0.1
// Leave all at 0 to preserve the original XAUUSD point-based behaviour.
input double          SLFloorATRMult           = 0.0;     // Min SL as ATR multiple  (0 = use StopLossMinPoints)
input double          SLCeilingATRMult         = 0.0;     // Max SL as ATR multiple  (0 = use StopLossMaxPoints)
input double          SpreadATRMult            = 0.0;     // Max spread as ATR multiple (0 = use SpreadLimitPoints)
input double          PaddingATRMult           = 0.0;     // Candle SL padding as ATR multiple (0 = use CandlePaddingPoints)

// ─── HFT Basket Profit ───────────────────────────────────────────────────────
input double          BasketProfitATRMult      = 2.5;     // Full target (ATR multiplier)
input bool            CloseAtAnyProfit         = true;    // Close basket at MinProfitToClose
input double          MinProfitToClose         = 0.01;    // Minimum profit to trigger close
input double          MinCloseATRMult          = 0.5;     // Min basket profit (N×ATR×lots value) before CloseAtAnyProfit fires

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

// ─── Basket Drawdown Protection ──────────────────────────────────────────────
// 3-stage response when total basket loss exceeds equity thresholds.
input bool            EnableBasketDDProtection = true;
input double          BasketDD_Caution_Pct     = 1.0;   // equity % → stop new entries + move all SLs to breakeven
input double          BasketDD_Danger_Pct      = 2.0;   // equity % → close weakest 50% of positions (by P&L)
input double          BasketDD_Emergency_Pct   = 3.0;   // equity % → close all positions + extended cooldown

// ─── Daily Loss Limit ─────────────────────────────────────────────────────────
input bool            EnableDailyLossLimit     = true;
input double          DailyLossLimitPct        = 5.0;   // % equity drop from session open → halt trading rest of day

// ─── Consecutive Loss Dampener ────────────────────────────────────────────────
input bool            EnableConsecLossDampen   = true;
input int             MaxConsecLosses          = 3;     // After N losing HFT cycles: halve max trades + double cooldown

// ─── Globals ─────────────────────────────────────────────────────────────────
CTrade        trade;
CPositionInfo pos;
int           atrHandle     = -1;
datetime      lastEntryTime = 0;
double        gATR          = 0.0;   // Updated each tick; used by helpers for ATR-relative scaling

// ─── Protection state ─────────────────────────────────────────────────────────
bool          gCautionActive   = false;  // Layer 1 DD: blocks new entries
double        gDayOpenEquity   = 0.0;   // Equity at calendar-day open
bool          gDailyHalted     = false;  // Session halted by daily loss limit
int           gDayChecked      = -1;    // Last day number gDayOpenEquity was refreshed
int           gConsecLosses    = 0;     // Consecutive HFT cycles that ended with net equity loss
double        gHFTStartEquity  = 0.0;   // Equity snapshot when current HFT cycle began

enum EA_STATE { STATE_HFT = 0, STATE_COOLDOWN = 1, STATE_QUALITY = 2 };
EA_STATE eaState         = STATE_HFT;
int      hftTradeCount   = 0;       // Market orders opened this HFT cycle
datetime cooldownStart   = 0;
int      cooldownDur     = 0;       // Actual cooldown duration (may be extended)
ulong    qualityTicket   = 0;
datetime qualityOpenTime = 0;

// ─── Resolved symbol (set in OnInit) ─────────────────────────────────────────
// Allows the EA to run on any instrument. Multiple instances on different
// symbols are fully independent — each gets its own GlobalVariable namespace.
string gSymbol = "";

// ─── Persistence (GlobalVariables) ───────────────────────────────────────────
// Survives chart period changes and MT5 restarts without closing trades.
// Keys are initialised in OnInit() so they are unique per symbol.
string GV_STATE     = "";
string GV_HFTCOUNT  = "";
string GV_COOLSTART = "";
string GV_COOLDUR   = "";
string GV_QTICKET   = "";
string GV_QOPENTIME = "";
string GV_STARTBAL  = "";
string GV_STOPPED   = "";

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
#define PANEL_W       350
#define LINE_H        24
#define PANEL_LINES   9
#define PANEL_PAD_X   16
#define PANEL_PAD_Y   14

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
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR,   C'38,42,52');
   ObjectSetInteger(0, bg, OBJPROP_COLOR,     C'80,88,108');

   int tx = PANEL_X + PANEL_PAD_X;
   int ty = PANEL_Y + PANEL_PAD_Y;

   // Row 0 — Header
   PanelLabel(PANEL_PREFIX+"R0", "UltimateScalper2  v1.00", tx, ty, C'160,160,160', 8);
   ty += LINE_H;

   // Row 1 — Symbol + ATR
   PanelLabel(PANEL_PREFIX+"R1",
      StringFormat("%-8s  ATR: %.2f", gSymbol, atr),
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
   double profit = BasketProfit(gSymbol);
   color pnlClr  = (profit >= 0) ? C'0,210,90' : C'255,75,75';
   PanelLabel(PANEL_PREFIX+"R4",
      StringFormat("Basket P&L:  %+.2f", profit),
      tx, ty, pnlClr, 8);
   ty += LINE_H;

   // Row 5 — Positions + Pending
   PanelLabel(PANEL_PREFIX+"R5",
      StringFormat("Positions: %d   Pending: %d",
         PositionsCount(gSymbol), PendingOrdersCount(gSymbol)),
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

   // Row 8 — Protection status
   ty += LINE_H;
   string protStr; color protClr;
   if(gDailyHalted)
      { protStr = "HALTED: daily loss limit";            protClr = C'255,75,75'; }
   else if(gCautionActive)
      { protStr = StringFormat("DD CAUTION  | Streak: %d/%d", gConsecLosses, MaxConsecLosses); protClr = C'255,160,0'; }
   else if(gConsecLosses > 0)
      { protStr = StringFormat("Protection: OK  | Streak: %d/%d", gConsecLosses, MaxConsecLosses); protClr = C'255,200,0'; }
   else
      { protStr = "Protection: OK";                      protClr = C'80,180,80'; }
   PanelLabel(PANEL_PREFIX+"R8", protStr, tx, ty, protClr, 8);

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
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double spread = (SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID)) / point;
   double limit  = (SpreadATRMult > 0 && gATR > 0)
                   ? (gATR * SpreadATRMult) / point   // ATR-relative limit
                   : SpreadLimitPoints;               // fixed-point fallback
   return spread <= limit;
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
   return NormalizeVolume(sym, MathMin(MaxLot, MathMax(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), BaseLot)));
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

// ─── Basket Drawdown Protection Helpers ──────────────────────────────────────

// Returns the effective MaxTotalTrades, halved after a losing streak.
int GetEffectiveMaxTrades()
{
   if(EnableConsecLossDampen && gConsecLosses >= MaxConsecLosses)
      return MathMax(1, MaxTotalTrades / 2);
   return MaxTotalTrades;
}

// Layer 1: move all basket SLs to entry price (protect from further loss).
void MoveAllToBreakeven(const string sym)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
      int    dir    = (pos.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
      double openPx = pos.PriceOpen();
      double curSL  = pos.StopLoss();
      double curTP  = pos.TakeProfit();
      int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double beSL   = NormalizeDouble(openPx, digits);
      bool   improve = (dir > 0) ? (curSL == 0.0 || beSL > curSL)
                                 : (curSL == 0.0 || beSL < curSL);
      if(improve) trade.PositionModify(pos.Ticket(), beSL, curTP);
   }
}

// Layer 2: close the worst-performing half of positions by P&L.
void CloseWorstHalf(const string sym)
{
   ulong  tickets[32];
   double profits[32];
   int    count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
      if(count >= 32) break;
      tickets[count] = pos.Ticket();
      profits[count] = pos.Profit() + pos.Swap() + pos.Commission();
      count++;
   }
   if(count == 0) return;
   // Bubble sort ascending by profit (worst first)
   for(int i = 0; i < count-1; i++)
      for(int j = i+1; j < count; j++)
         if(profits[j] < profits[i])
         {
            double tp = profits[i]; profits[i] = profits[j]; profits[j] = tp;
            ulong  tt = tickets[i]; tickets[i] = tickets[j]; tickets[j] = tt;
         }
   int closeN = MathMax(1, count / 2);
   for(int i = 0; i < closeN; i++)
   {
      Print("DD DANGER: closing worst position #", tickets[i], " P&L=", DoubleToString(profits[i],2));
      trade.PositionClose(tickets[i], DeviationPoints);
   }
}

// Main basket DD check — called each tick while in HFT mode.
void CheckBasketDD(const string sym, double atr)
{
   if(!EnableBasketDDProtection) return;
   if(PositionsCount(sym) == 0) { gCautionActive = false; return; }

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0) return;
   double loss      = -BasketProfit(sym);   // positive when basket is losing

   double cauAmt = equity * BasketDD_Caution_Pct   / 100.0;
   double danAmt = equity * BasketDD_Danger_Pct    / 100.0;
   double emgAmt = equity * BasketDD_Emergency_Pct / 100.0;

   if(loss >= emgAmt)
   {
      Print("DD EMERGENCY: basket loss=", DoubleToString(loss,2),
            " (", DoubleToString(BasketDD_Emergency_Pct,1), "% equity) → closing all + extended cooldown");
      CloseBasket(sym);
      eaState       = STATE_COOLDOWN;
      cooldownStart = TimeCurrent();
      cooldownDur   = CooldownSeconds * 3;
      gCautionActive = false;
      gConsecLosses++;
      SaveState();
   }
   else if(loss >= danAmt)
   {
      if(!gCautionActive)
      {
         Print("DD DANGER: basket loss=", DoubleToString(loss,2),
               " → closing weakest 50% of positions");
         gCautionActive = true;
      }
      CloseWorstHalf(sym);
   }
   else if(loss >= cauAmt)
   {
      if(!gCautionActive)
      {
         Print("DD CAUTION: basket loss=", DoubleToString(loss,2),
               " → stopping entries + moving SLs to breakeven");
         gCautionActive = true;
         MoveAllToBreakeven(sym);
      }
   }
   else
   {
      gCautionActive = false;   // Basket recovered above caution threshold
   }
}

// Daily loss limit — resets at midnight, halts session if limit is breached.
void CheckDailyLoss(const string sym)
{
   if(!EnableDailyLossLimit) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != gDayChecked)
   {
      gDayOpenEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      gDayChecked    = dt.day;
      gDailyHalted   = false;
      Print("Daily loss tracker reset | Day equity: ", DoubleToString(gDayOpenEquity,2));
   }
   if(gDailyHalted || gDayOpenEquity <= 0) return;

   double curEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct   = (gDayOpenEquity - curEquity) / gDayOpenEquity * 100.0;
   if(lossPct >= DailyLossLimitPct)
   {
      Print("DAILY LOSS LIMIT: -", DoubleToString(lossPct,1), "% → halting session for today");
      CloseBasket(sym);
      gDailyHalted  = true;
      eaState       = STATE_COOLDOWN;
      cooldownStart = TimeCurrent();
      cooldownDur   = 28800;   // 8-hour cooldown (sits out the rest of the trading day)
      SaveState();
   }
}

// ─── Stop Loss Calculation ───────────────────────────────────────────────────

double GetCandleBasedSL(const string sym, int dir)
{
   double point   = SymbolInfoDouble(sym, SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double padding = (PaddingATRMult > 0 && gATR > 0)
                    ? gATR * PaddingATRMult         // ATR-relative padding
                    : CandlePaddingPoints * point;  // fixed-point fallback

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
   // Use ATR-relative floor/ceiling when enabled, otherwise fall back to fixed points.
   double minDist  = (SLFloorATRMult > 0 && atr > 0)
                     ? atr * SLFloorATRMult
                     : StopLossMinPoints * point;
   double maxDist  = (SLCeilingATRMult > 0 && atr > 0)
                     ? atr * SLCeilingATRMult
                     : StopLossMaxPoints * point;
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

   // Full ATR target — always honoured regardless of MinCloseATRMult
   if(profit >= target && profit > 0) { CloseBasket(sym); return; }

   // CloseAtAnyProfit — only fires when basket profit has reached a meaningful ATR distance.
   // Prevents tiny $0.01 closes that leave nothing to absorb the next loss.
   if(CloseAtAnyProfit && profit >= MinProfitToClose)
   {
      bool profitWorthy = true;
      if(MinCloseATRMult > 0 && atr > 0)
      {
         double lots = BasketLots(sym);
         double tv   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
         double ts   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
         if(ts > 0 && tv > 0 && lots > 0)
            profitWorthy = (profit >= MinCloseATRMult * atr * (tv / ts) * lots);
      }
      if(profitWorthy) { CloseBasket(sym); return; }
   }
}

bool OpenMarket(const string sym, int dir, double atr)
{
   if(gCautionActive) return false;   // Layer 1 DD: entries blocked
   int total = PositionsCount(sym) + PendingOrdersCount(sym);
   if(total >= GetEffectiveMaxTrades()) return false;
   double sl    = GetStopLoss(sym, dir, atr);
   double entry = (dir > 0) ? SymbolInfoDouble(sym, SYMBOL_ASK)
                             : SymbolInfoDouble(sym, SYMBOL_BID);
   double lot   = (UseRiskPercent && sl > 0)
                  ? CalcRiskLot(sym, entry, sl, HFTRiskPercent)
                  : GetDynamicLot(sym, total);
   if(lot <= 0) return false;
   trade.SetExpertMagicNumber(MagicNumber);
   bool ok = (dir > 0) ? trade.Buy(lot, sym, 0, sl, 0) : trade.Sell(lot, sym, 0, sl, 0);
   if(ok) { hftTradeCount++; SaveState(); }
   return ok;
}

bool PlaceLimitOrders(const string sym, int dir, double atr)
{
   if(gCautionActive) return false;   // Layer 1 DD: entries blocked
   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double offsets[] = {0.2, 0.4, 0.6, 0.8, 1.0};
   int placed = 0;
   trade.SetExpertMagicNumber(MagicNumber);

   for(int i = 0; i < LimitOrderCount; i++)
   {
      int cur = PositionsCount(sym) + PendingOrdersCount(sym);
      if(cur >= GetEffectiveMaxTrades()) break;
      double offset = atr * offsets[MathMin(i, 4)];
      double price  = (dir > 0) ? NormalizeDouble(bid - offset, digits) : NormalizeDouble(ask + offset, digits);
      double sl     = GetStopLoss(sym, dir, atr);
      double lot    = (UseRiskPercent && sl > 0)
                      ? CalcRiskLot(sym, price, sl, HFTRiskPercent)
                      : GetDynamicLot(sym, cur);
      bool ok = (dir > 0) ? trade.BuyLimit(lot, price, sym, sl) : trade.SellLimit(lot, price, sym, sl);
      if(ok) placed++;
   }
   return (placed > 0);
}

void EnterCooldown(const string sym)
{
   // Track consecutive loss cycles (compare equity to cycle-start snapshot)
   if(EnableConsecLossDampen && gHFTStartEquity > 0)
   {
      double curEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(curEquity < gHFTStartEquity * 0.9995)
         gConsecLosses++;
      else
         gConsecLosses = 0;
   }

   CloseBasket(sym);
   eaState       = STATE_COOLDOWN;
   cooldownStart = TimeCurrent();
   cooldownDur   = (hftTradeCount >= HFTExtendedThreshold) ? CooldownSeconds * 2 : CooldownSeconds;

   // Consecutive loss dampener: double cooldown after streak
   if(EnableConsecLossDampen && gConsecLosses >= MaxConsecLosses)
   {
      cooldownDur *= 2;
      Print("Consec loss streak: ", gConsecLosses, " → cooldown doubled to ", cooldownDur, "s | next cycle max trades halved");
   }

   Print("HFT → COOLDOWN | trades=", hftTradeCount,
         " | cooldown=", cooldownDur, "s",
         (hftTradeCount >= HFTExtendedThreshold ? " [EXTENDED]" : ""),
         " | streak=", gConsecLosses);
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

double CalcRiskLot(const string sym, double entryPrice, double slPrice, double riskPercent)
{
   double slDist = MathAbs(entryPrice - slPrice);
   if(slDist <= 0) return NormalizeVolume(sym, BaseLot);

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmt   = equity * (riskPercent / 100.0);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0) return NormalizeVolume(sym, BaseLot);

   double lot = riskAmt / ((slDist / tickSize) * tickValue);
   return NormalizeVolume(sym, MathMin(MaxLot, lot));
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
   double lot    = CalcRiskLot(sym, entry, sl, QualityRiskPercent);

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
      gHFTStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);  // Snapshot for next cycle
      gCautionActive  = false;
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
   // ── Resolve active symbol ─────────────────────────────────────────────────
   gSymbol = (TradeSymbol == "") ? Symbol() : TradeSymbol;

   // ── Build per-symbol GlobalVariable keys ─────────────────────────────────
   // Prefix includes the symbol so multiple instances never share state.
   string pfx  = "US2_" + gSymbol + "_";
   GV_STATE     = pfx + "State";
   GV_HFTCOUNT  = pfx + "HFTCount";
   GV_COOLSTART = pfx + "CoolStart";
   GV_COOLDUR   = pfx + "CoolDur";
   GV_QTICKET   = pfx + "QTicket";
   GV_QOPENTIME = pfx + "QOpenTime";
   GV_STARTBAL  = pfx + "StartBal";
   GV_STOPPED   = pfx + "Stopped";

   if(!EnsureSymbolReady(gSymbol)) return INIT_FAILED;

   atrHandle = iATR(gSymbol, ATRTimeframe, ATRPeriod);
   if(atrHandle < 0) { Print("ATR indicator failed to initialize."); return INIT_FAILED; }

   // Restore state if available — skips trade cleanup to preserve open positions
   if(!LoadState())
   {
      // Fresh start — no saved state, clean slate
      CloseAllExistingTrades(gSymbol);
      startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      profitTargetHit = false;
      Print("UltimateScalper2 v1.00 fresh start | Symbol: ", gSymbol,
            " | Starting balance: ", startingBalance,
            " | Profit target: +", ProfitTargetPercent, "%");
      SaveState();
   }
   gHFTStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   gCautionActive  = false;
   gDailyHalted    = false;
   gConsecLosses   = 0;

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
         CloseBasket(gSymbol);
         profitTargetHit = true;
         SaveState();
         Print("PROFIT TARGET HIT: +", DoubleToString(profitPct, 1), "% | Trading stopped.");
         return;
      }
   }

   // ── Daily Loss Limit ──────────────────────────────────────────────────────
   CheckDailyLoss(gSymbol);
   if(gDailyHalted) { DrawPanel(GetATR()); return; }

   // ── Margin Protection — always runs first ─────────────────────────────────
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(marginLevel > 0 && marginLevel < MarginTriggerLevel)
   {
      Print("Margin protection: ", marginLevel, "% below ", MarginTriggerLevel, "% — closing all.");
      CloseBasket(gSymbol);
      qualityTicket = 0;
      eaState       = STATE_COOLDOWN;
      cooldownStart = TimeCurrent();
      cooldownDur   = CooldownSeconds;
      SaveState();
      return;
   }

   double atr = GetATR();
   if(atr <= 0) return;
   gATR = atr;  // Update global so all helpers can use ATR-relative scaling

   if(!EnsureSymbolReady(gSymbol) || !SpreadOK(gSymbol)) return;

   // ── State Machine ─────────────────────────────────────────────────────────
   switch(eaState)
   {
      case STATE_HFT:
         CheckBasketDD(gSymbol, atr);
         if(eaState == STATE_HFT) RunHFT(gSymbol, atr);  // DD may have triggered cooldown
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
            OpenQualityTrade(gSymbol, atr);
         else
            ManageQualityTrade(gSymbol);
         break;
   }

   // ── Panel ─────────────────────────────────────────────────────────────────
   DrawPanel(atr);
}
