// UltimateScalper3.mq5
// HFT Basket + Dynamic Hold/Close Engine + Volatility Regime
//
// v3.00 additions over v2:
//   1. Per-position fate scoring  — each trade is scored every tick.
//      Score drives one of four actions: Hold / Partial-close / Full-close / BE-trail.
//   2. Basket Graduation          — on HFT threshold, the highest-scoring trade is
//      promoted directly to Quality mode (SL+TP added) instead of a forced full close.
//   3. Volatility Regime          — compares M1 ATR to a longer baseline (H1 ATR).
//      If the ratio exceeds VolSpikeMultiplier the EA enters Defensive mode:
//      fewer max trades, tighter exits, no new limit stacking.
//   4. All instrument-scaling (ATR-relative SL/spread/padding) from v2 retained.
//
// Score breakdown (per position, each tick):
//   Momentum alignment  +2 (agrees) / -2 (opposes) / 0 (none)
//   H1 bias             +1 (agrees) / -1 (opposes) / 0 (doji)
//   Profit tier         +3 (>2×ATR) / +2 (>1×ATR) / +1 (flat) / -1 (loss)
//   Age                 +1 (<5 min fresh) / -1 (>30 min aging)
//
//   Score >= ScoreHoldThreshold    → Hold; partial-close if far enough in profit
//   Score >= ScorePartialThreshold → Partial-close if profitable; else hold/SL
//   Score <  ScorePartialThreshold → Full close if profitable; else let SL handle

#property copyright "UltimateScalper3"
#property link      "local"
#property version   "3.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

// ─── Core ────────────────────────────────────────────────────────────────────
input string          TradeSymbol              = "";       // Blank = use chart symbol automatically
input int             MagicNumber              = 905535;
input bool            UseRiskPercent           = true;    // true = risk-% sizing (recommended); false = fixed BaseLot
input double          HFTRiskPercent           = 2.5;     // HFT mode: risk % of equity per trade
input double          BaseLot                  = 0.02;    // Fallback lot when UseRiskPercent=false or SL=0
input double          MaxLot                   = 0.10;    // Hard cap per trade (both modes)
input int             MaxTotalTrades           = 6;       // Max basket positions (HFT mode)
input int             DeviationPoints          = 30;
input double          SpreadLimitPoints        = 300;     // Used when SpreadATRMult = 0

// ─── ATR & Momentum ──────────────────────────────────────────────────────────
input int             ATRPeriod                = 14;
input ENUM_TIMEFRAMES ATRTimeframe             = PERIOD_M1;
input ENUM_TIMEFRAMES MomentumTF               = PERIOD_M1;
input double          MomentumThresholdATR     = 0.15;
input int             MomentumLookback         = 2;
input int             MinSecondsBetweenEntries = 5;

// ─── HFT Entry ───────────────────────────────────────────────────────────────
input bool            UseLimitOrders           = true;
input int             MarketOrdersAtExecution  = 2;
input int             LimitOrderCount          = 2;
input double          BodyStrengthATR          = 0.25;
input double          CloseLocationPct         = 0.30;
input bool            RequireAcceleration      = false;

// ─── Stop Loss ───────────────────────────────────────────────────────────────
input bool            UseStopLoss              = true;
input bool            UseCandleSL              = true;
input int             CandleLookback           = 5;
input int             CandlePaddingPoints      = 100;     // Used when PaddingATRMult = 0
input double          StopLossATRMultiplier    = 3.0;
input double          StopLossMinPoints        = 1000;    // Used when SLFloorATRMult = 0
input double          StopLossMaxPoints        = 1500;    // Used when SLCeilingATRMult = 0

// ─── Instrument Scaling (ATR-relative; set > 0 for non-XAUUSD) ──────────────
// Forex recommended: SLFloor=1.5, SLCeiling=6.0, Spread=0.3, Padding=0.1
// Indices recommended: SLFloor=1.0, SLCeiling=5.0, Spread=0.5, Padding=0.15
// Leave all at 0 to use the original XAUUSD point-based values above.
input double          SLFloorATRMult           = 0.0;
input double          SLCeilingATRMult         = 0.0;
input double          SpreadATRMult            = 0.0;
input double          PaddingATRMult           = 0.0;

// ─── HFT Basket Profit Exit ──────────────────────────────────────────────────
input double          BasketProfitATRMult      = 2.5;    // Close basket when total profit >= N×ATR (scaled to lots)
input double          MinProfitToClose         = 0.50;   // Floor: basket must show at least this $ before peak-pullback fires
input double          BasketProfitFloorPct     = 0.60;   // Fire close when profit pulls back to X% of its peak (0.60 = 60%)

// ─── Breakeven Trail ─────────────────────────────────────────────────────────
input double          BETrailATRTrigger        = 1.0;    // Move SL to breakeven when profit >= N×ATR
input double          BEBufferATRMult          = 0.1;    // Buffer above entry for BE SL (ATR × this)
input int             ScoreHoldThreshold       = 4;      // Min score for graduation candidate
input bool            EnableGraduation         = true;   // Promote best trade to Quality on threshold hit

// ─── Volatility Regime ────────────────────────────────────────────────────────
// Compares current ATRTimeframe ATR vs a longer VolATRTF baseline.
// When ratio > VolSpikeMultiplier: Defensive mode activates.
input bool            EnableVolFilter          = true;
input int             VolATRPeriod             = 20;
input ENUM_TIMEFRAMES VolATRTF                 = PERIOD_H1;
input double          VolSpikeMultiplier       = 2.0;    // ATR ratio to activate Defensive
input int             DefensiveMaxTrades       = 2;      // Max basket size in Defensive mode

// ─── State Machine ───────────────────────────────────────────────────────────
input int             HFTTradeThreshold        = 50;
input double          QualitySL_ATR            = 1.5;
input double          QualityTP_ATR            = 3.0;
input int             QualityTimeoutSeconds    = 1800;
input double          QualityRiskPercent       = 4.0;

// ─── Margin Protection ───────────────────────────────────────────────────────
input double          MarginTriggerLevel       = 150.0;

// ─── Overall Profit Target ───────────────────────────────────────────────────
input double          ProfitTargetPercent      = 70.0;

// ─── Basket Drawdown Protection ──────────────────────────────────────────────
// 3-stage response when total basket loss exceeds equity thresholds.
input bool            EnableBasketDDProtection = true;
input double          BasketDD_Caution_Pct     = 1.0;   // equity % → stop new entries + move all SLs to breakeven
input double          BasketDD_Danger_Pct      = 2.0;   // equity % → close weakest 50% of positions (by score)
input double          BasketDD_Emergency_Pct   = 3.0;   // equity % → close all positions immediately

// ─── Quality Profit Target ───────────────────────────────────────────────────
input double          QualityProfitTargetPct  = 5.0;   // Close quality trade when profit >= X% of account equity

// ─── Globals ─────────────────────────────────────────────────────────────────
CTrade        trade;
CPositionInfo pos;
int           atrHandle    = -1;
int           volAtrHandle = -1;   // Longer-period ATR for regime detection
datetime      lastEntryTime = 0;
double        gATR         = 0.0;  // Updated each tick for ATR-relative helpers
bool          gDefensive   = false;

// ─── Protection state ─────────────────────────────────────────────────────────
bool          gCautionActive   = false;  // Layer 1 DD: blocks new entries
double        gHFTStartEquity  = 0.0;   // Equity snapshot when current HFT cycle began

// ─── Basket profit tracking ──────────────────────────────────────────────────
double gBasketPeak = 0.0;   // High-water mark of basket profit within the current HFT cycle


// ─── Resolved symbol ─────────────────────────────────────────────────────────
string gSymbol = "";

// ─── State machine ───────────────────────────────────────────────────────────
enum EA_STATE { STATE_HFT = 0, STATE_QUALITY = 1 };
EA_STATE eaState         = STATE_HFT;
int      hftTradeCount   = 0;
ulong    qualityTicket   = 0;
datetime qualityOpenTime = 0;

// ─── Persistence (GlobalVariables) ───────────────────────────────────────────
// Keys are per-symbol (set in OnInit), so multiple chart instances never collide.
string GV_STATE     = "";
string GV_HFTCOUNT  = "";
string GV_QTICKET   = "";
string GV_QOPENTIME = "";
string GV_STARTBAL  = "";
string GV_STOPPED   = "";

double startingBalance = 0;
bool   profitTargetHit = false;

// ─── SaveState / LoadState ───────────────────────────────────────────────────

void SaveState()
{
   GlobalVariableSet(GV_STATE,     (double)eaState);
   GlobalVariableSet(GV_HFTCOUNT,  (double)hftTradeCount);
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
   qualityTicket   = (ulong)GlobalVariableGet(GV_QTICKET);
   qualityOpenTime = (datetime)GlobalVariableGet(GV_QOPENTIME);
   startingBalance = GlobalVariableGet(GV_STARTBAL);
   profitTargetHit = (bool)(int)GlobalVariableGet(GV_STOPPED);

   // If saved state was COOLDOWN (old data) or invalid, reset to HFT
   if((int)eaState > (int)STATE_QUALITY) eaState = STATE_HFT;

   if(qualityTicket > 0 && !PositionSelectByTicket(qualityTicket))
   {
      Print("Restored: Quality ticket #", qualityTicket, " not found. Resetting to HFT.");
      hftTradeCount=0; qualityTicket=0; qualityOpenTime=0; eaState=STATE_HFT;
   }
   Print("State restored | Mode: ", EnumToString(eaState),
         " | HFT trades: ", hftTradeCount, " | Quality ticket: ", qualityTicket);
   return true;
}

// ─── Panel ───────────────────────────────────────────────────────────────────
#define PANEL_PREFIX "US3_"
#define PANEL_X      10
#define PANEL_Y      20
#define PANEL_W      370
#define LINE_H       24
#define PANEL_LINES  10
#define PANEL_PAD_X  16
#define PANEL_PAD_Y  14

void PanelLabel(const string name, const string text, int x, int y, color clr, int sz = 8)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR,     ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
      ObjectSetString (0, name, OBJPROP_FONT,       "Consolas");
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  sz);
   ObjectSetString (0, name, OBJPROP_TEXT,      text);
}

void DrawPanel(double atr, double baselineATR)
{
   int panelH = PANEL_LINES * LINE_H + (PANEL_PAD_Y * 2);

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
   PanelLabel(PANEL_PREFIX+"R0", "UltimateScalper3  v3.00", tx, ty, C'160,160,160', 8);
   ty += LINE_H;

   // Row 1 — Symbol + ATR
   PanelLabel(PANEL_PREFIX+"R1",
      StringFormat("%-8s  ATR: %.5f", gSymbol, atr),
      tx, ty, C'110,110,110', 8);
   ty += LINE_H;

   // Row 2 — Mode + optional Defensive badge
   string modeStr; color modeClr;
   if(profitTargetHit)
   {
      modeStr = "MODE:  PROFIT TARGET HIT";
      modeClr = C'255,215,0';
   }
   else
   {
      switch(eaState)
      {
         case STATE_HFT:     modeStr = "MODE:  HFT ACTIVE";   modeClr = C'0,220,100';  break;
         case STATE_QUALITY: modeStr = "MODE:  QUALITY HOLD";  modeClr = C'80,185,255'; break;
         default:            modeStr = "MODE:  ---";           modeClr = clrWhite;
      }
      if(gDefensive) { modeStr += "  [DEF]"; modeClr = C'255,100,80'; }
   }
   PanelLabel(PANEL_PREFIX+"R2", modeStr, tx, ty, modeClr, 9);
   ty += LINE_H;

   // Row 3 — State detail
   string detStr = ""; color detClr = C'160,160,160';
   if(eaState == STATE_HFT)
      detStr = StringFormat("Trades: %d / %d", hftTradeCount, HFTTradeThreshold);
   else if(eaState == STATE_QUALITY)
   {
      if(qualityTicket > 0)
      {
         int left = QualityTimeoutSeconds - (int)(TimeCurrent()-qualityOpenTime);
         if(left < 0) left = 0;
         detStr = StringFormat("Timeout in: %dm %02ds", left/60, left%60);
      }
      else detStr = "Waiting for H1 signal...";
      detClr = C'80,185,255';
   }
   PanelLabel(PANEL_PREFIX+"R3", detStr, tx, ty, detClr, 8);
   ty += LINE_H;

   // Row 4 — Basket P&L
   double profit = BasketProfit(gSymbol);
   color pnlClr = (profit >= 0) ? C'0,210,90' : C'255,75,75';
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

   // Row 7 — Profit progress
   double curBal    = AccountInfoDouble(ACCOUNT_BALANCE);
   double profitPct = (startingBalance > 0) ? ((curBal-startingBalance)/startingBalance)*100.0 : 0;
   color  prgClr    = profitTargetHit ? C'255,215,0' : (profitPct >= ProfitTargetPercent*0.75 ? C'0,210,90' : C'110,110,110');
   PanelLabel(PANEL_PREFIX+"R7",
      StringFormat("Profit: %+.1f%% / %.0f%%", profitPct, ProfitTargetPercent),
      tx, ty, prgClr, 8);
   ty += LINE_H;

   // Row 8 — Volatility regime
   double ratio   = (baselineATR > 0) ? atr/baselineATR : 0.0;
   string regStr  = gDefensive
      ? StringFormat("Vol: DEFENSIVE  (x%.1f baseline)", ratio)
      : StringFormat("Vol: Normal     (x%.1f baseline)", ratio);
   color regClr = gDefensive ? C'255,100,80' : C'80,180,80';
   PanelLabel(PANEL_PREFIX+"R8", regStr, tx, ty, regClr, 8);

   // Row 9 — Protection status
   ty += LINE_H;
   string protStr; color protClr;
   if(gCautionActive)
      { protStr = "DD CAUTION — entries paused";   protClr = C'255,160,0'; }
   else
      { protStr = "Protection: OK";                protClr = C'80,180,80'; }
   PanelLabel(PANEL_PREFIX+"R9", protStr, tx, ty, protClr, 8);

   ChartRedraw(0);
}

void DeletePanel() { ObjectsDeleteAll(0, PANEL_PREFIX); }

// ─── Symbol Helpers ──────────────────────────────────────────────────────────

bool EnsureSymbolReady(const string sym)
{
   if(!SymbolSelect(sym, true))
      { Print("Symbol select failed: ", sym); return false; }
   if(SymbolInfoInteger(sym, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      { Print("Trading disabled: ", sym); return false; }
   return true;
}

void CloseAllExistingTrades(const string sym)
{
   int closed = 0, deleted = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol() != sym) continue;
      if(trade.PositionClose(pos.Ticket(), DeviationPoints)) closed++;
   }
   for(int i = OrdersTotal()-1; i >= 0; i--)
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
                   ? (gATR * SpreadATRMult) / point
                   : SpreadLimitPoints;
   return spread <= limit;
}

// ─── ATR ─────────────────────────────────────────────────────────────────────

double GetATR()
{
   double buf[2];
   if(atrHandle < 0 || CopyBuffer(atrHandle, 0, 0, 2, buf) < 1) return 0.0;
   return buf[0];
}

double GetBaselineATR()
{
   double buf[2];
   if(volAtrHandle < 0 || CopyBuffer(volAtrHandle, 0, 0, 2, buf) < 1) return 0.0;
   return buf[0];
}

// ─── Volatility Regime ───────────────────────────────────────────────────────

void UpdateVolatilityRegime(double currentATR)
{
   if(!EnableVolFilter) { gDefensive = false; return; }
   double baseline = GetBaselineATR();
   if(baseline <= 0) { gDefensive = false; return; }
   bool spike = (currentATR > baseline * VolSpikeMultiplier);
   if(spike != gDefensive)
   {
      gDefensive = spike;
      Print("Volatility regime → ", (spike ? "DEFENSIVE" : "NORMAL"),
            " | ATR=", currentATR, " | Baseline=", baseline,
            " | Ratio=", DoubleToString(currentATR/baseline, 2));
   }
}

// ─── Momentum ────────────────────────────────────────────────────────────────

int DetectMomentum(const string sym, double atr, ENUM_TIMEFRAMES tf)
{
   if(atr <= 0) return 0;

   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(sym, tf, 0, 3, close) < 3) return 0;

   double velocity     = close[0] - close[1];
   double prevVelocity = close[1] - close[2];

   bool accelBull = (velocity > 0 && prevVelocity > 0 && MathAbs(velocity) > MathAbs(prevVelocity));
   bool accelBear = (velocity < 0 && prevVelocity < 0 && MathAbs(velocity) > MathAbs(prevVelocity));
   bool dirBull   = velocity > 0;
   bool dirBear   = velocity < 0;

   if(RequireAcceleration && !accelBull && !accelBear) return 0;
   if(!RequireAcceleration && !dirBull && !dirBear)    return 0;

   int dir = (RequireAcceleration ? accelBull : dirBull) ? 1 : -1;
   if(MathAbs(velocity) < atr * MomentumThresholdATR) return 0;

   double open[], high[], low[];
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low,  true);
   if(CopyOpen(sym, tf, 0, 1, open) < 1) return 0;
   if(CopyHigh(sym, tf, 0, 1, high) < 1) return 0;
   if(CopyLow (sym, tf, 0, 1, low)  < 1) return 0;

   double body  = MathAbs(close[0] - open[0]);
   double range = high[0] - low[0];
   if(body < atr * BodyStrengthATR) return 0;
   if(range <= 0) return 0;

   double closePct = (close[0] - low[0]) / range;
   if(dir > 0 && closePct < (1.0 - CloseLocationPct)) return 0;
   if(dir < 0 && closePct > CloseLocationPct)          return 0;

   return dir;
}

int GetH1Direction(const string sym)
{
   double h1c[], h1o[];
   ArraySetAsSeries(h1c, true);
   ArraySetAsSeries(h1o, true);
   if(CopyClose(sym, PERIOD_H1, 0, 2, h1c) < 2) return 0;
   if(CopyOpen( sym, PERIOD_H1, 0, 2, h1o) < 2) return 0;
   if(h1c[1] > h1o[1]) return  1;
   if(h1c[1] < h1o[1]) return -1;
   return 0;
}

// ─── Volume Helpers ──────────────────────────────────────────────────────────

double NormalizeVolume(const string sym, double lots)
{
   double minL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   lots = MathMax(minL, MathMin(maxL, lots));
   if(step > 0) lots = MathFloor(lots/step) * step;
   return NormalizeDouble(lots, 2);
}

double GetDynamicLot(const string sym, int tradeNum)
{
   return NormalizeVolume(sym, MathMin(MaxLot, MathMax(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), BaseLot)));
}

// ─── Position / Order Counts ─────────────────────────────────────────────────

int PositionsCount(const string sym)
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() == sym && pos.Magic() == MagicNumber) n++;
   }
   return n;
}

int PendingOrdersCount(const string sym)
{
   int n = 0;
   for(int i = OrdersTotal()-1; i >= 0; i--)
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
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
      if(pos.PositionType() == POSITION_TYPE_BUY) buys++; else sells++;
   }
   if(buys == 0 && sells == 0) return 0;
   return (buys >= sells) ? 1 : -1;
}

// ─── Basket P&L ──────────────────────────────────────────────────────────────

double BasketProfit(const string sym)
{
   double p = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
      p += pos.Profit() + pos.Swap() + pos.Commission();
   }
   return p;
}

double BasketLots(const string sym)
{
   double lots = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
      lots += pos.Volume();
   }
   return lots;
}

// ─── Close Helpers ───────────────────────────────────────────────────────────

void DeletePendingOrders(const string sym)
{
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL)==sym && OrderGetInteger(ORDER_MAGIC)==MagicNumber)
         trade.OrderDelete(t);
   }
}

// Cancel pending orders whose direction opposes dir (+1=buy, -1=sell).
// Buy-limit/buy-stop are direction +1; sell-limit/sell-stop are -1.
void DeleteOppositePendingOrders(const string sym, int dir)
{
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != sym || OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      int odir = (otype == ORDER_TYPE_BUY_LIMIT || otype == ORDER_TYPE_BUY_STOP) ? 1 : -1;
      if(odir != dir) trade.OrderDelete(t);
   }
}

bool CloseBasket(const string sym)
{
   trade.SetAsyncMode(true);
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
      trade.PositionClose(pos.Ticket(), DeviationPoints);
   }
   DeletePendingOrders(sym);
   trade.SetAsyncMode(false);
   gBasketPeak = 0;
   return true;
}

// ─── Basket Drawdown Protection Helpers ──────────────────────────────────────

// Returns the effective max trades, accounting for defensive mode.
int GetEffectiveMaxTrades()
{
   return gDefensive ? DefensiveMaxTrades : MaxTotalTrades;
}

// Layer 1: move all basket SLs to entry price (breakeven protection).
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
      // Use BEBufferATRMult if available, else exactly at entry
      double buf   = (gATR > 0 && BEBufferATRMult > 0) ? gATR * BEBufferATRMult : 0.0;
      double beSL  = NormalizeDouble((dir > 0) ? openPx + buf : openPx - buf, digits);
      bool   improve = (dir > 0) ? (curSL == 0.0 || beSL > curSL)
                                 : (curSL == 0.0 || beSL < curSL);
      if(improve) trade.PositionModify(pos.Ticket(), beSL, curTP);
   }
}

// Layer 2: close the worst-scoring half of positions.
void CloseWorstHalf(const string sym, double atr)
{
   ulong  tickets[32];
   int    scores[32];
   int    count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
      if(count >= 32) break;
      tickets[count] = pos.Ticket();
      scores[count]  = ScorePosition(pos.Ticket(), atr);
      count++;
   }
   if(count == 0) return;
   // Bubble sort ascending by score (weakest first)
   for(int i = 0; i < count-1; i++)
      for(int j = i+1; j < count; j++)
         if(scores[j] < scores[i])
         {
            int   ts = scores[i];  scores[i]  = scores[j];  scores[j]  = ts;
            ulong tt = tickets[i]; tickets[i] = tickets[j]; tickets[j] = tt;
         }
   int closeN = MathMax(1, count / 2);
   for(int i = 0; i < closeN; i++)
   {
      Print("DD DANGER: closing weakest position #", tickets[i], " score=", scores[i]);
      trade.PositionClose(tickets[i], DeviationPoints);
   }
}

// Main basket DD check — called each tick while in HFT mode.
void CheckBasketDD(const string sym, double atr)
{
   if(!EnableBasketDDProtection) return;
   if(PositionsCount(sym) == 0) { gCautionActive = false; return; }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0) return;
   double loss   = -BasketProfit(sym);   // positive when basket is losing

   double cauAmt = equity * BasketDD_Caution_Pct   / 100.0;
   double danAmt = equity * BasketDD_Danger_Pct    / 100.0;
   double emgAmt = equity * BasketDD_Emergency_Pct / 100.0;

   if(loss >= emgAmt)
   {
      Print("DD EMERGENCY: basket loss=", DoubleToString(loss,2),
            " (", DoubleToString(BasketDD_Emergency_Pct,1), "% equity) → closing all");
      CloseBasket(sym);
      eaState        = STATE_HFT;
      gCautionActive = false;
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
      CloseWorstHalf(sym, atr);
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

// ─── Stop Loss Calculation ───────────────────────────────────────────────────

double GetCandleBasedSL(const string sym, int dir)
{
   double point   = SymbolInfoDouble(sym, SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double padding = (PaddingATRMult > 0 && gATR > 0)
                    ? gATR * PaddingATRMult
                    : CandlePaddingPoints * point;

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

double GetStopLoss(const string sym, int dir, double atr, double atrMult = -1)
{
   if(!UseStopLoss) return 0;

   double point    = SymbolInfoDouble(sym, SYMBOL_POINT);
   double bid      = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask      = SymbolInfoDouble(sym, SYMBOL_ASK);
   int    digits   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double mult     = (atrMult > 0) ? atrMult : StopLossATRMultiplier;
   double atrDist  = (atr > 0) ? atr * mult : 0;
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
         if(dir > 0) csl = MathMin(csl, ask - floorDist);
         else        csl = MathMax(csl, bid + floorDist);
         return NormalizeDouble(csl, digits);
      }
   }
   double sl = (dir > 0) ? ask - floorDist : bid + floorDist;
   return NormalizeDouble(sl, digits);
}

// ─── Breakeven Trail ─────────────────────────────────────────────────────────
// Moves SL to entry + buffer once the position has moved BETrailATRTrigger×ATR in profit.
// Never widens an existing SL.

void TryMoveToBreakeven(ulong ticket, double atr)
{
   if(atr <= 0 || BETrailATRTrigger <= 0 || BEBufferATRMult <= 0) return;
   if(!PositionSelectByTicket(ticket)) return;

   int    dir    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
   double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL  = PositionGetDouble(POSITION_SL);
   double curTP  = PositionGetDouble(POSITION_TP);
   string sym    = PositionGetString(POSITION_SYMBOL);
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);
   double curPx  = (dir > 0) ? bid : ask;

   double profitDist = (curPx - openPx) * dir;
   if(profitDist < atr * BETrailATRTrigger) return;

   double buffer = atr * BEBufferATRMult;
   double beSL   = NormalizeDouble((dir > 0) ? openPx + buffer : openPx - buffer, digits);

   bool shouldMove = (dir > 0) ? (curSL == 0.0 || beSL > curSL)
                                : (curSL == 0.0 || beSL < curSL);
   if(!shouldMove) return;

   if(trade.PositionModify(ticket, beSL, curTP))
      Print("BE trail: #", ticket, " SL → ", beSL, " (entry=", openPx, ")");
}

// ─── Position Fate Scoring ───────────────────────────────────────────────────
// Returns an integer score for a single open position.
// Higher = stronger case to hold; lower = close or reduce.

int ScorePosition(ulong ticket, double atr)
{
   if(!PositionSelectByTicket(ticket)) return -99;

   string sym   = PositionGetString(POSITION_SYMBOL);
   int    dir   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
   double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
   double bid   = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask   = SymbolInfoDouble(sym, SYMBOL_ASK);
   double curPx = (dir > 0) ? bid : ask;

   int score = 0;

   // 1. Momentum alignment
   int mom = DetectMomentum(sym, atr, MomentumTF);
   if(mom == dir)       score += 2;
   else if(mom != 0)    score -= 2;

   // 2. H1 bias alignment
   int h1 = GetH1Direction(sym);
   if(h1 == dir)        score += 1;
   else if(h1 != 0)     score -= 1;

   // 3. Profit tier (in ATR units)
   double profitDist = (curPx - openPx) * dir;
   if(atr > 0)
   {
      double profitATR = profitDist / atr;
      if(profitATR >= 2.0)      score += 3;
      else if(profitATR >= 1.0) score += 2;
      else if(profitATR >= 0.0) score += 1;
      else                      score -= 1;
   }

   // 4. Age (fresh entries have more runway; aging ones should be resolved)
   int age = (int)(TimeCurrent() - (datetime)PositionGetInteger(POSITION_TIME));
   if(age < 300)        score += 1;   // < 5 min — momentum probably still live
   else if(age > 1800)  score -= 1;   // > 30 min — stale, increase close pressure

   return score;
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
   // Breakeven trail — run on every position each tick
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
      TryMoveToBreakeven(pos.Ticket(), atr);
   }

   double profit = BasketProfit(sym);

   // Update basket high-water mark
   if(profit > gBasketPeak) gBasketPeak = profit;

   // Full ATR target — close basket immediately when hit
   double target = CalculateBasketProfitTarget(sym, atr, BasketLots(sym));
   if(profit >= target && profit > 0)
   {
      Print("Basket target hit: profit=", DoubleToString(profit,2), " target=", DoubleToString(target,2));
      gBasketPeak = 0;
      CloseBasket(sym);
      return;
   }

   // Peak-pullback close — only after a real peak has formed above MinProfitToClose
   if(profit >= MinProfitToClose && gBasketPeak > MinProfitToClose)
   {
      if(profit <= gBasketPeak * BasketProfitFloorPct)
      {
         Print("Basket pullback exit: profit=", DoubleToString(profit,2),
               " peak=", DoubleToString(gBasketPeak,2));
         gBasketPeak = 0;
         CloseBasket(sym);
      }
   }
}

bool OpenMarket(const string sym, int dir, double atr)
{
   if(gCautionActive) return false;   // Layer 1 DD: entries blocked
   int maxT  = GetEffectiveMaxTrades();
   int total = PositionsCount(sym) + PendingOrdersCount(sym);
   if(total >= maxT) return false;
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
      int cur  = PositionsCount(sym) + PendingOrdersCount(sym);
      int maxT = GetEffectiveMaxTrades();
      if(cur >= maxT) break;
      double offset = atr * offsets[MathMin(i, 4)];
      double price  = (dir > 0) ? NormalizeDouble(bid-offset, digits)
                                 : NormalizeDouble(ask+offset, digits);
      double sl     = GetStopLoss(sym, dir, atr);
      double lot    = (UseRiskPercent && sl > 0)
                      ? CalcRiskLot(sym, price, sl, HFTRiskPercent)
                      : GetDynamicLot(sym, cur);
      bool ok = (dir > 0) ? trade.BuyLimit(lot, price, sym, sl)
                           : trade.SellLimit(lot, price, sym, sl);
      if(ok) placed++;
   }
   return (placed > 0);
}

// ─── Basket Graduation ────────────────────────────────────────────────────────
// Called when the HFT trade threshold is hit.
// Finds the highest-scoring open position, adds SL/TP, closes all others, and
// promotes it directly to Quality mode — skipping cooldown entirely.
// Falls back to a normal cooldown if no worthy candidate is found.

void GraduateBestPosition(const string sym, double atr)
{
   // Find the highest-scoring position
   ulong bestTicket = 0;
   int   bestScore  = -99;

   if(EnableGraduation && PositionsCount(sym) > 0)
   {
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {
         if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
         int s = ScorePosition(pos.Ticket(), atr);
         if(s > bestScore) { bestScore = s; bestTicket = pos.Ticket(); }
      }
   }

   if(bestTicket == 0 || bestScore < ScoreHoldThreshold)
   {
      // No worthy candidate — close any winning positions, leave losers for SL
      trade.SetAsyncMode(true);
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {
         if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
         if(pos.Profit() + pos.Swap() > 0)
            trade.PositionClose(pos.Ticket(), DeviationPoints);
      }
      trade.SetAsyncMode(false);
      DeletePendingOrders(sym);
      gBasketPeak = 0;
      hftTradeCount = 0;
      eaState = STATE_HFT;
      Print("HFT cycle complete | trades=", hftTradeCount,
            (bestScore > -99 ? StringFormat(" | best score=%d (below threshold)", bestScore) : ""),
            " → restarting HFT");
      SaveState();
      return;
   }

   // Close all except the best trade — only those currently showing a gain
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol()!=sym || pos.Magic()!=MagicNumber) continue;
      if(pos.Ticket() == bestTicket) continue;
      double pnl = pos.Profit() + pos.Swap();
      if(pnl > 0)
         trade.PositionClose(pos.Ticket(), DeviationPoints);
   }
   DeletePendingOrders(sym);

   // Add/update SL + TP on the promoted position
   if(PositionSelectByTicket(bestTicket))
   {
      int    dir    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double sl     = GetStopLoss(sym, dir, atr, QualitySL_ATR);
      double tp     = NormalizeDouble(
                         (dir > 0) ? entry + atr*QualityTP_ATR
                                   : entry - atr*QualityTP_ATR, digits);
      trade.PositionModify(bestTicket, sl, tp);
      Print("GRADUATION: #", bestTicket, " → Quality | Score=", bestScore,
            " | SL=", sl, " | TP=", tp);
   }

   qualityTicket   = bestTicket;
   qualityOpenTime = TimeCurrent();
   eaState         = STATE_QUALITY;
   gBasketPeak     = 0;
   gCautionActive  = false;
   SaveState();
}

void RunHFT(const string sym, double atr)
{
   if(hftTradeCount >= HFTTradeThreshold)
   {
      GraduateBestPosition(sym, atr);
      return;
   }

   ManageHFTExits(sym, atr);

   if(TimeCurrent() - lastEntryTime < MinSecondsBetweenEntries) return;

   int dir = DetectMomentum(sym, atr, MomentumTF);
   if(dir == 0) return;

   int basketDir = GetBasketDirection(sym);
   if(basketDir != 0 && dir != basketDir) return;

   // Cancel any pending orders that are in the opposite direction before placing new ones.
   // Same-direction pending orders remain and count toward the MaxTotalTrades cap.
   DeleteOppositePendingOrders(sym, dir);

   if(UseLimitOrders)
   {
      for(int m = 0; m < MarketOrdersAtExecution; m++) OpenMarket(sym, dir, atr);
      PlaceLimitOrders(sym, dir, atr);
   }
   else
   {
      OpenMarket(sym, dir, atr);
   }
   lastEntryTime = TimeCurrent();
}

// ─── Risk-Based Lot (Quality Mode) ───────────────────────────────────────────

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
   int dir = GetH1Direction(sym);
   if(dir == 0) { Print("QUALITY: Waiting for H1 direction signal..."); return; }

   int m1dir = DetectMomentum(sym, atr, MomentumTF);
   if(m1dir != 0 && m1dir != dir)
   { Print("QUALITY: M1 conflicts with H1. Waiting..."); return; }

   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double entry  = (dir > 0) ? ask : bid;
   double sl     = GetStopLoss(sym, dir, atr, QualitySL_ATR);
   double tpDist = atr * QualityTP_ATR;
   double tp     = (dir > 0) ? NormalizeDouble(entry+tpDist, digits)
                              : NormalizeDouble(entry-tpDist, digits);
   double lot    = CalcRiskLot(sym, entry, sl, QualityRiskPercent);

   trade.SetExpertMagicNumber(MagicNumber);
   bool ok = (dir > 0) ? trade.Buy(lot, sym, 0, sl, tp)
                        : trade.Sell(lot, sym, 0, sl, tp);
   if(ok)
   {
      qualityTicket   = trade.ResultOrder();
      qualityOpenTime = TimeCurrent();
      Print("QUALITY trade opened | ", (dir>0?"BUY":"SELL"),
            " | SL=", sl, " | TP=", tp, " | Lot=", lot);
      SaveState();
   }
   else
      Print("QUALITY trade failed. RetCode=", trade.ResultRetcode());
}

void ManageQualityTrade(const string sym, double atr)
{
   if(!IsQualityPositionOpen())
   {
      Print("QUALITY trade closed (TP/SL hit). Resetting to HFT.");
      hftTradeCount   = 0;
      qualityTicket   = 0;
      qualityOpenTime = 0;
      eaState         = STATE_HFT;
      gHFTStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      gCautionActive  = false;
      SaveState();
      return;
   }

   // Apply breakeven trail to the quality position as profit grows
   TryMoveToBreakeven(qualityTicket, atr);

   // Quality profit target: close when position profit reaches X% of equity
   if(PositionSelectByTicket(qualityTicket))
   {
      double qProfit = PositionGetDouble(POSITION_PROFIT)
                     + PositionGetDouble(POSITION_SWAP);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > 0 && qProfit >= equity * QualityProfitTargetPct / 100.0)
      {
         Print("QUALITY target hit: +", QualityProfitTargetPct, "% equity | P&L=", DoubleToString(qProfit,2));
         trade.PositionClose(qualityTicket, DeviationPoints);
         hftTradeCount   = 0; qualityTicket   = 0; qualityOpenTime = 0;
         eaState         = STATE_HFT;
         gHFTStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         gCautionActive  = false;
         SaveState();
         return;
      }
   }

   if(TimeCurrent()-qualityOpenTime >= QualityTimeoutSeconds)
   {
      Print("QUALITY trade timed out (", QualityTimeoutSeconds, "s). Closing → HFT.");
      trade.PositionClose(qualityTicket, DeviationPoints);
      hftTradeCount   = 0;
      qualityTicket   = 0;
      qualityOpenTime = 0;
      eaState         = STATE_HFT;
      gHFTStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      gCautionActive  = false;
      SaveState();
   }
}

// ─── Lifecycle ───────────────────────────────────────────────────────────────

int OnInit()
{
   // Resolve active symbol
   gSymbol = (TradeSymbol == "") ? Symbol() : TradeSymbol;

   // Build per-symbol GlobalVariable keys (US3 prefix avoids collision with US2)
   string pfx  = "US3_" + gSymbol + "_";
   GV_STATE     = pfx + "State";
   GV_HFTCOUNT  = pfx + "HFTCount";
   GV_QTICKET   = pfx + "QTicket";
   GV_QOPENTIME = pfx + "QOpenTime";
   GV_STARTBAL  = pfx + "StartBal";
   GV_STOPPED   = pfx + "Stopped";

   if(!EnsureSymbolReady(gSymbol)) return INIT_FAILED;

   atrHandle = iATR(gSymbol, ATRTimeframe, ATRPeriod);
   if(atrHandle < 0) { Print("ATR handle failed."); return INIT_FAILED; }

   volAtrHandle = iATR(gSymbol, VolATRTF, VolATRPeriod);
   if(volAtrHandle < 0)
      Print("Baseline ATR handle failed — volatility filter will be inactive.");

   if(!LoadState())
   {
      CloseAllExistingTrades(gSymbol);
      startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      profitTargetHit = false;
      Print("UltimateScalper3 v3.00 fresh start | Symbol: ", gSymbol,
            " | Balance: ", startingBalance,
            " | Target: +", ProfitTargetPercent, "%");
      SaveState();
   }

   gHFTStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   gCautionActive  = false;

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   SaveState();
   IndicatorRelease(atrHandle);
   if(volAtrHandle >= 0) IndicatorRelease(volAtrHandle);
   DeletePanel();
}

void OnTick()
{
   if(profitTargetHit) { DrawPanel(gATR, GetBaselineATR()); return; }

   double atr = GetATR();
   if(atr <= 0) return;
   gATR = atr;

   // Volatility regime check — updates gDefensive flag
   UpdateVolatilityRegime(atr);

   // Profit target check
   if(startingBalance > 0)
   {
      double curBal    = AccountInfoDouble(ACCOUNT_BALANCE);
      double profitPct = ((curBal-startingBalance)/startingBalance)*100.0;
      if(profitPct >= ProfitTargetPercent)
      {
         CloseBasket(gSymbol);
         profitTargetHit = true;
         SaveState();
         Print("PROFIT TARGET HIT: +", DoubleToString(profitPct,1), "% | Trading stopped.");
         DrawPanel(atr, GetBaselineATR());
         return;
      }
   }

   // Margin protection
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(marginLevel > 0 && marginLevel < MarginTriggerLevel)
   {
      Print("Margin protection: ", marginLevel, "% → closing all.");
      CloseBasket(gSymbol);
      qualityTicket=0; eaState=STATE_HFT;
      SaveState();
      return;
   }

   if(!EnsureSymbolReady(gSymbol) || !SpreadOK(gSymbol)) return;

   // State machine
   switch(eaState)
   {
      case STATE_HFT:
         CheckBasketDD(gSymbol, atr);
         if(eaState == STATE_HFT) RunHFT(gSymbol, atr);
         break;

      case STATE_QUALITY:
         if(qualityTicket == 0) OpenQualityTrade(gSymbol, atr);
         else                   ManageQualityTrade(gSymbol, atr);
         break;
   }

   DrawPanel(atr, GetBaselineATR());
}
