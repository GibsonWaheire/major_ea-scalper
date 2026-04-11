// ============================================================
// DynamicXauCandleTrail.mq5
// XAUUSD HFT — One trade per candle, exit on candle direction flip
//
// ENTRY : On each new candle, read the direction of the last
//         closed candle body (bullish = BUY, bearish = SELL).
//         Body must exceed MinCandleBodyATR * ATR (noise filter).
//
// TRAIL : ATR-based trailing stop (safety net).
//
// EXIT  : Close when the LIVE (forming) candle body flips
//         against the trade by more than FlipBodyMinATR * ATR.
//         This is the "candle slightly changes direction" exit.
// ============================================================

#property copyright "Copyright 2026, McGibs Digital Solutions"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade        trade;
CPositionInfo pos;

// ===== Core Settings =====
input group "===== Core Settings ====="
input string           TradeSymbol      = "XAUUSD";
input int              MagicNumber      = 905541;
input ENUM_TIMEFRAMES  TradeTF          = PERIOD_M1;   // Candle timeframe (M1 recommended for HFT)

// ===== Lot Sizing =====
input group "===== Lot Sizing ====="
input bool             UseRiskPercent   = false;       // true = risk-%, false = fixed lot
input double           RiskPercent      = 1.0;         // % of balance to risk per trade
input double           BaseLot          = 0.01;        // Fixed lot (if UseRiskPercent=false)
input double           MaxLot           = 0.10;        // Hard cap

// ===== Entry Filter =====
input group "===== Entry Filter ====="
input double           MinCandleBodyATR = 0.15;        // Min closed-candle body as fraction of ATR to enter
input int              ATRPeriod        = 14;          // ATR period for body/trail calculations
input int              MaxPositions     = 1;           // Max simultaneous trades (1 = one at a time)

// ===== Candle Direction Flip Exit =====
input group "===== Candle Direction Flip Exit ====="
input double           FlipBodyMinATR   = 0.10;        // Min live-candle body to count as a direction flip
//   Lower  = more sensitive (exits sooner on small moves against)
//   Higher = less sensitive (waits for a stronger reversal candle)

// ===== Trailing Stop (Safety Net) =====
input group "===== Trailing Stop ====="
input bool             UseTrailingStop  = true;
input double           TrailStartATR    = 0.8;         // Start trailing after profit >= X * ATR
input double           TrailDistATR     = 0.6;         // Trail SL distance in ATR

// ===== Stop Loss =====
input group "===== Stop Loss ====="
input bool             UseStopLoss      = true;
input double           SLMultATR        = 3.0;         // SL = ATR * multiplier
input double           SLMinPoints      = 2500;        // Floor SL distance in points (gold = ~$2.50)
input double           SLMaxPoints      = 6000;        // Ceiling SL distance in points

// ===== Spread & Execution =====
input group "===== Spread & Execution ====="
input double           MaxSpreadPoints  = 300;         // Skip entry if spread wider than this
input int              DeviationPoints  = 30;

// ===== Globals =====
int      atrHandle  = INVALID_HANDLE;
datetime lastBarTime = 0;

// ============================================================
// INIT / DEINIT
// ============================================================
int OnInit()
{
   if(TradeSymbol == "" || !SymbolSelect(TradeSymbol, true))
   {
      Print("Symbol not available: ", TradeSymbol);
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);

   // Auto-detect filling mode
   long fm = SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) != 0)       trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fm & SYMBOL_FILLING_IOC) != 0)  trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                      trade.SetTypeFilling(ORDER_FILLING_RETURN);

   atrHandle = iATR(TradeSymbol, TradeTF, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle");
      return INIT_FAILED;
   }

   Print("DynamicXauCandleTrail ready | ", TradeSymbol, " | TF:", EnumToString(TradeTF));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(atrHandle);
}

// ============================================================
// HELPERS
// ============================================================
double GetATR()
{
   double buf[2];
   // Use index [1] = last fully-closed bar ATR for stability
   if(CopyBuffer(atrHandle, 0, 1, 1, buf) < 1) return 0;
   return buf[0];
}

bool SpreadOK()
{
   double point  = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double spread = (SymbolInfoDouble(TradeSymbol, SYMBOL_ASK) - SymbolInfoDouble(TradeSymbol, SYMBOL_BID)) / point;
   return (spread <= MaxSpreadPoints);
}

int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != TradeSymbol || pos.Magic() != MagicNumber) continue;
      count++;
   }
   return count;
}

int GetBasketDir()
{
   int buys = 0, sells = 0;
   for(int i = PositionsTotal()-1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != TradeSymbol || pos.Magic() != MagicNumber) continue;
      if(pos.PositionType() == POSITION_TYPE_BUY) buys++;
      else sells++;
   }
   if(buys == 0 && sells == 0) return 0;
   return (buys >= sells) ? 1 : -1;
}

double NormalizeVol(double lots)
{
   double mn = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP);
   lots = MathMax(mn, MathMin(mx, lots));
   if(st > 0) lots = MathFloor(lots / st + 1e-10) * st;
   return NormalizeDouble(lots, 2);
}

double CalcLot(double atr)
{
   if(!UseRiskPercent) return NormalizeVol(BaseLot);

   double point     = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double tickVal   = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || atr <= 0) return NormalizeVol(BaseLot);

   double slDist    = MathMax(SLMinPoints * point, atr * SLMultATR);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double lot       = (balance * RiskPercent / 100.0) / ((slDist / tickSize) * tickVal);
   return NormalizeVol(MathMin(lot, MaxLot));
}

double CalcSL(int direction, double atr)
{
   if(!UseStopLoss) return 0;

   double point  = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double ask    = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   double atrDist = atr * SLMultATR;
   double minDist = SLMinPoints * point;
   double maxDist = SLMaxPoints * point;
   double dist    = MathMax(minDist, MathMin((atrDist > 0 ? atrDist : minDist), maxDist));

   double sl = (direction > 0) ? ask - dist : bid + dist;
   return NormalizeDouble(sl, digits);
}

// ============================================================
// ENTRY SIGNAL
// Read the body of the last CLOSED candle.
// Returns: 1=BUY, -1=SELL, 0=no signal
// ============================================================
int GetEntrySignal(double atr)
{
   double o[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);

   // Index 1 = last fully-closed candle
   if(CopyOpen (TradeSymbol, TradeTF, 1, 1, o) < 1) return 0;
   if(CopyClose(TradeSymbol, TradeTF, 1, 1, c) < 1) return 0;

   double body    = c[0] - o[0];
   double minBody = atr * MinCandleBodyATR;

   if(MathAbs(body) < minBody) return 0;   // Body too small — indecision candle
   return (body > 0) ? 1 : -1;
}

// ============================================================
// FLIP EXIT CHECK
// Looks at the LIVE (still-forming) candle body.
// Returns true when the body has moved against the trade
// by more than FlipBodyMinATR * ATR.
// ============================================================
bool LiveCandleFlippedAgainst(int tradeDir, double atr)
{
   double o[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);

   // Index 0 = current live candle
   if(CopyOpen (TradeSymbol, TradeTF, 0, 1, o) < 1) return false;
   if(CopyClose(TradeSymbol, TradeTF, 0, 1, c) < 1) return false;

   double body    = c[0] - o[0];          // positive = bullish candle so far
   double minFlip = atr * FlipBodyMinATR;

   if(tradeDir > 0)  // We are LONG — exit if live candle turns bearish
      return (body < -minFlip);
   else               // We are SHORT — exit if live candle turns bullish
      return (body >  minFlip);
}

// ============================================================
// TRAILING STOP
// Moves the broker-side SL as price extends in our favour.
// Acts as a safety net in case the flip check is delayed.
// ============================================================
void ManageTrailingStops(double atr)
{
   if(!UseTrailingStop || atr <= 0) return;

   double trailStart = atr * TrailStartATR;
   double trailDist  = atr * TrailDistATR;
   int    digits     = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);
   double point      = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);

   for(int i = PositionsTotal()-1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != TradeSymbol || pos.Magic() != MagicNumber) continue;

      double sl        = pos.StopLoss();
      double openPrice = pos.PriceOpen();
      double bid       = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
      double ask       = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);

      if(pos.PositionType() == POSITION_TYPE_BUY)
      {
         if(bid - openPrice < trailStart) continue;   // Not enough profit yet
         double newSL = NormalizeDouble(bid - trailDist, digits);
         if(newSL > sl + point)                        // Only ever move SL up
            trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
      }
      else // SELL
      {
         if(openPrice - ask < trailStart) continue;
         double newSL = NormalizeDouble(ask + trailDist, digits);
         if(sl == 0 || newSL < sl - point)             // Only ever move SL down
            trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
      }
   }
}

// ============================================================
// CANDLE FLIP EXIT
// Close all positions when live candle body flips against us.
// ============================================================
void ManageCandleFlipExit(double atr)
{
   int dir = GetBasketDir();
   if(dir == 0) return;                               // No open positions

   if(!LiveCandleFlippedAgainst(dir, atr)) return;   // No flip detected

   Print("Candle flip exit triggered — closing all positions (dir=", dir, ")");
   for(int i = PositionsTotal()-1; i >= 0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != TradeSymbol || pos.Magic() != MagicNumber) continue;
      trade.PositionClose(pos.Ticket(), DeviationPoints);
   }
}

// ============================================================
// ON TICK
// ============================================================
void OnTick()
{
   if(!SpreadOK()) return;

   double atr = GetATR();
   if(atr <= 0) return;

   // --- EXITS run on every tick ---
   ManageTrailingStops(atr);
   ManageCandleFlipExit(atr);

   // --- ENTRY runs only on new candle ---
   datetime barTime[1];
   if(CopyTime(TradeSymbol, TradeTF, 0, 1, barTime) < 1) return;
   if(barTime[0] == lastBarTime) return;   // Still on the same candle
   lastBarTime = barTime[0];

   if(CountMyPositions() >= MaxPositions) return;

   int signal = GetEntrySignal(atr);
   if(signal == 0) return;

   // Don't open a trade against an already-open basket direction
   int basketDir = GetBasketDir();
   if(basketDir != 0 && basketDir != signal) return;

   double sl  = CalcSL(signal, atr);
   double lot = CalcLot(atr);

   if(signal > 0)
      trade.Buy (lot, TradeSymbol, 0, sl, 0, "CandleTrail");
   else
      trade.Sell(lot, TradeSymbol, 0, sl, 0, "CandleTrail");
}
