#property copyright "Copyright 2025"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"
#property strict

// -----------------------------------------------------------------------------
// MicroMomentumScalper
//   Micro-scalping Expert Advisor for XAUUSD focusing on calm micro-momentum
//   conditions. Designed for VPS deployment with low latency. The EA enforces:
//     * Session/time filters (03:00 - 10:00 UTC)
//     * Spread + ATR calmness filters
//     * Micro-trend + momentum confirmation (MA, candles, VWAP/EMA)
//     * Liquidity imbalance detection (tick acceleration + range break)
//     * Dynamic TP / hidden ATR-based emergency stop
//     * Strict risk management with ATR-sized position sizing
//     * One-trade-at-a-time execution with optional hedge recovery flip
// -----------------------------------------------------------------------------

// === User Inputs =============================================================
input group   "General"
input string  TradeSymbol               = "XAUUSD";
input int     MagicNumber               = 251119;  // unique ID per account
input bool    VPSMode                   = true;    // reduces heavy logging/checks
input bool    EnableAutoTrading         = true;
input int     SlippagePoints            = 20;

input group   "Risk Management"
input double  RiskPerTradePercent       = 0.35;    // % of equity per trade
input double  MaxSpreadPoints           = 35.0;    // hard cap spread filter
input double  CalmSpreadPoints          = 30.0;    // average spread threshold
input double  ATRCalmThreshold          = 0.30;    // ATR/10 must be below
input double  ATRStopMultiplier         = 0.30;    // emergency stop multiplier
input double  HighVolatilityATRPoints   = 80.0;    // reduce lots when ATR above
input double  HighVolatilityLotReducer  = 0.50;    // multiplier when high vol
input int     MinTradeIntervalSec       = 20;
input bool    EnableHedging             = false;   // optional recovery flip
input double  HedgeDrawdownFactor       = 0.60;    // fraction of stop for hedge
input int     HedgeCooldownSeconds      = 45;

input group   "Signal Settings"
input int     FastMAPeriod              = 5;
input int     SlowMAPeriod              = 20;
input int     ATRPeriod                 = 14;
input int     VWAPPeriod                = 34;
input bool    UseVWAP                   = true;
input int     MomentumLookback          = 3;       // last n candles
input int     MicroRangeBars            = 6;
input double  RangeBreakBufferPoints    = 12.0;
input int     TickHistoryDepth          = 12;
input double  TickAccelerationFactor    = 1.80;

input group   "Exit Settings"
input double  TPSpreadMultiplier        = 1.50;
input double  TPVolatilityBuffer        = 0.20;    // ATR share added to TP
input double  QuickProfitFactor         = 1.00;    // multiples of spread
input int     QuickProfitSeconds        = 25;
input double  MomentumWeaknessBuffer    = 0.15;    // MA slope cushion

input group   "Filters"
input int     SessionStartUTC           = 3;
input int     SessionEndUTC             = 10;
input bool    UseNewsFilter             = true;
input datetime NextNewsTimeUTC          = D'1970.01.01 00:00';
input int     NewsBufferMinutes         = 30;

input group   "Diagnostics"
input bool    EnableDetailedLogging     = false;

// === Internal Structures =====================================================
struct MarketSnapshot
{
   double bid;
   double ask;
   double mid;
   double spreadPoints;
   double avgSpreadPoints;
   double atrPoints;
   bool   sessionAllowed;
   bool   newsAllowed;
   bool   calmVolatility;
};

struct TradeContext
{
   int      ticket;
   int      direction;        // 1 = buy, -1 = sell
   double   lots;
   double   entryPrice;
   double   emergencyStopPrice;
   double   dynamicTPPoints;
   datetime openTime;
   bool     hedgeAttempted;
};

// === Global State ============================================================
string  g_symbol = "";
double  g_point = 0.0;
int     g_digits = 0;
double  g_tickSize = 0.0;
double  g_tickValue = 0.0;
double  g_minLot = 0.01;
double  g_maxLot = 100.0;
double  g_lotStep = 0.01;

double  g_spreadHistory[64];
int     g_spreadSamples = 0;
int     g_spreadIndex = 0;
int     g_spreadDepth = 12;

double  g_tickVelocityHistory[64];
int     g_tickVelocitySamples = 0;
int     g_tickVelocityIndex = 0;
double  g_tickDirectionHistory[64];
int     g_tickDepth = 12;
double  g_lastMid = 0.0;
datetime g_lastTickTime = 0;

datetime g_lastTradeTime = 0;
datetime g_lastCloseTime = 0;
TradeContext g_trade = {0};

// === Utility Forward Declarations ===========================================
void    ResetTradeContext();
int     SpreadSamplesTarget();
void    UpdateSpreadStats(double spreadPoints);
double  GetAverageSpread();
void    UpdateTickMetrics(double midPrice, datetime now);
double  GetAverageTickVelocity();
bool    ScanMarket(MarketSnapshot &snapshot);
bool    SessionFilter();
bool    NewsFilter();
double  ComputeATRPoints();
int     EvaluateSignal();
int     EvaluateMomentumBias();
int     EvaluateCandleBias();
int     EvaluateVWAPBias();
bool    DetectLiquidityImbalance(int direction);
bool    DetectTickAcceleration(int direction);
bool    DetectRangeEscape(int direction);
double  ComputeDynamicTPPoints(double spreadPoints, double atrPoints);
double  ComputeEmergencyStopPoints(double atrPoints);
double  CalculatePositionSize(double stopPoints);
bool    AllowNewTrade(const MarketSnapshot &snapshot);
bool    HasActiveTrade();
void    SyncActiveTrade();
void    ManageOpenTrade(const MarketSnapshot &snapshot);
bool    PriceHitHiddenStop(const MarketSnapshot &snapshot);
bool    ShouldQuickTakeProfit(const MarketSnapshot &snapshot);
bool    MomentumWeakening(int direction);
bool    CloseTrade(string reason);
bool    CloseTradeWithClock(string reason, bool updateClock);
bool    ExecuteEntry(int direction, double lots, const MarketSnapshot &snapshot);
bool    AttemptHedge(int direction, const MarketSnapshot &snapshot);
void    LogEvent(string tag, string message);

// === Lifecycle ===============================================================
int OnInit()
{
   g_symbol = TradeSymbol;
   if(StringLen(g_symbol) == 0)
   {
      Print("Symbol not specified. Abort.");
      return(INIT_FAILED);
   }

   if(!SymbolSelect(g_symbol, true))
   {
      Print("Unable to select symbol: ", g_symbol);
      return(INIT_FAILED);
   }

   g_point    = MarketInfo(g_symbol, MODE_POINT);
   g_digits   = (int)MarketInfo(g_symbol, MODE_DIGITS);
   g_tickSize = MarketInfo(g_symbol, MODE_TICKSIZE);
   if(g_tickSize <= 0.0)
      g_tickSize = g_point;
   g_tickValue= MarketInfo(g_symbol, MODE_TICKVALUE);
   g_minLot   = MarketInfo(g_symbol, MODE_MINLOT);
   g_maxLot   = MarketInfo(g_symbol, MODE_MAXLOT);
   g_lotStep  = MarketInfo(g_symbol, MODE_LOTSTEP);

   g_tickDepth = MathMax(3, MathMin(TickHistoryDepth, 64));
   ArrayInitialize(g_spreadHistory, 0.0);
   ArrayInitialize(g_tickVelocityHistory, 0.0);
   ArrayInitialize(g_tickDirectionHistory, 0.0);
   g_spreadSamples = 0;
   g_tickVelocitySamples = 0;
   g_lastMid = 0.0;
   g_lastTickTime = 0;

   ResetTradeContext();

   g_spreadDepth = MathMin(SpreadSamplesTarget(), 64);

   Print("MicroMomentumScalper READY on LIVE VPS");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   LogEvent("DEINIT", StringFormat("Reason=%d", reason));
}

void OnTick()
{
   if(!EnableAutoTrading)
      return;

   if(Symbol() != g_symbol)
      RefreshRates();

   double bid = MarketInfo(g_symbol, MODE_BID);
   double ask = MarketInfo(g_symbol, MODE_ASK);
   if(bid <= 0 || ask <= 0)
      return;

   double mid = (bid + ask) * 0.5;
   datetime now = TimeCurrent();

   UpdateSpreadStats((ask - bid) / g_point);
   UpdateTickMetrics(mid, now);

   MarketSnapshot snapshot;
   if(!ScanMarket(snapshot))
      return;

   SyncActiveTrade();
   ManageOpenTrade(snapshot);

   if(HasActiveTrade())
      return;

   if(!AllowNewTrade(snapshot))
      return;

   int direction = EvaluateSignal();
   if(direction == 0)
      return;

   if(!DetectLiquidityImbalance(direction))
      return;

   double atrPoints = snapshot.atrPoints;
   double stopPoints = ComputeEmergencyStopPoints(atrPoints);
   if(stopPoints <= 0)
      return;

   double lots = CalculatePositionSize(stopPoints);
   if(lots < g_minLot)
      return;

   ExecuteEntry(direction, lots, snapshot);
}

// === Initial Helpers =========================================================
int SpreadSamplesTarget()
{
   int depth = 20;
   if(VPSMode)
      depth = 12;
   return depth;
}

void ResetTradeContext()
{
   g_trade.ticket = -1;
   g_trade.direction = 0;
   g_trade.lots = 0.0;
   g_trade.entryPrice = 0.0;
   g_trade.emergencyStopPrice = 0.0;
   g_trade.dynamicTPPoints = 0.0;
   g_trade.openTime = 0;
   g_trade.hedgeAttempted = false;
}

void UpdateSpreadStats(double spreadPoints)
{
   int depth = g_spreadDepth;
   if(depth <= 0)
      depth = 12;
   g_spreadHistory[g_spreadIndex] = spreadPoints;
   g_spreadIndex = (g_spreadIndex + 1) % depth;
   if(g_spreadSamples < depth)
      g_spreadSamples++;
}

double GetAverageSpread()
{
   if(g_spreadSamples == 0)
      return 0.0;
   double sum = 0.0;
   int depth = g_spreadDepth;
   if(depth <= 0)
      depth = g_spreadSamples;
   for(int i = 0; i < g_spreadSamples; i++)
      sum += g_spreadHistory[i];
   return sum / g_spreadSamples;
}

void UpdateTickMetrics(double midPrice, datetime now)
{
   if(g_lastTickTime != 0)
   {
     double delta = midPrice - g_lastMid;
     double deltaPoints = delta / g_point;
     int seconds = (int)MathMax(1, now - g_lastTickTime);
     double velocity = MathAbs(deltaPoints) / seconds;
     int depth = g_tickDepth;
     g_tickVelocityHistory[g_tickVelocityIndex] = velocity;
     g_tickDirectionHistory[g_tickVelocityIndex] = (delta > 0 ? 1 : (delta < 0 ? -1 : 0));
     g_tickVelocityIndex = (g_tickVelocityIndex + 1) % depth;
     if(g_tickVelocitySamples < depth)
        g_tickVelocitySamples++;
   }
   g_lastMid = midPrice;
   g_lastTickTime = now;
}

double GetAverageTickVelocity()
{
   if(g_tickVelocitySamples == 0)
      return 0.0;
   double sum = 0.0;
   for(int i = 0; i < g_tickVelocitySamples; i++)
      sum += g_tickVelocityHistory[i];
   return sum / g_tickVelocitySamples;
}

// === Market Scanner ==========================================================
bool ScanMarket(MarketSnapshot &snapshot)
{
   snapshot.bid = MarketInfo(g_symbol, MODE_BID);
   snapshot.ask = MarketInfo(g_symbol, MODE_ASK);
   if(snapshot.bid <= 0 || snapshot.ask <= 0)
      return false;
   snapshot.mid = (snapshot.bid + snapshot.ask) * 0.5;
   snapshot.spreadPoints = (snapshot.ask - snapshot.bid) / g_point;
   snapshot.avgSpreadPoints = GetAverageSpread();
   snapshot.atrPoints = ComputeATRPoints();
   snapshot.sessionAllowed = SessionFilter();
   snapshot.newsAllowed = NewsFilter();
   snapshot.calmVolatility = (snapshot.avgSpreadPoints > 0 &&
                              snapshot.avgSpreadPoints <= CalmSpreadPoints &&
                              (snapshot.atrPoints / 10.0) <= ATRCalmThreshold);
   if(snapshot.spreadPoints <= 0)
      return false;
   return true;
}

bool SessionFilter()
{
   datetime nowUTC = TimeGMT();
   MqlDateTime ts;
   TimeToStruct(nowUTC, ts);
   int hour = ts.hour;
   if(SessionEndUTC <= SessionStartUTC)
      return true;
   return (hour >= SessionStartUTC && hour < SessionEndUTC);
}

bool NewsFilter()
{
   if(!UseNewsFilter || NextNewsTimeUTC <= 0)
      return true;
   datetime nowUTC = TimeGMT();
   int diff = (int)MathAbs(nowUTC - NextNewsTimeUTC);
   return (diff > NewsBufferMinutes * 60);
}

double ComputeATRPoints()
{
   double atr = iATR(g_symbol, PERIOD_M1, ATRPeriod, 0);
   if(atr <= 0.0)
      return 0.0;
   return atr / g_point;
}

// === Signal Logic ============================================================
int EvaluateSignal()
{
   int biasMA = EvaluateMomentumBias();
   int biasCandle = EvaluateCandleBias();
   int biasVWAP = EvaluateVWAPBias();

   int score = biasMA + biasCandle + biasVWAP;
   if(score >= 2)
      return 1;
   if(score <= -2)
      return -1;
   return 0;
}

int EvaluateMomentumBias()
{
   double fastNow = iMA(g_symbol, PERIOD_M1, FastMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double slowNow = iMA(g_symbol, PERIOD_M1, SlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double fastPrev = iMA(g_symbol, PERIOD_M1, FastMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
   double slowPrev = iMA(g_symbol, PERIOD_M1, SlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);

   double slopeNow = fastNow - slowNow;
   double slopePrev = fastPrev - slowPrev;

   if(slopeNow > 0 && slopeNow > slopePrev)
      return 1;
   if(slopeNow < 0 && slopeNow < slopePrev)
      return -1;
   return 0;
}

int EvaluateCandleBias()
{
   int bullish = 0;
   int bearish = 0;
   for(int i = 1; i <= MomentumLookback; i++)
   {
      double open = iOpen(g_symbol, PERIOD_M1, i);
      double close = iClose(g_symbol, PERIOD_M1, i);
      if(close > open)
         bullish++;
      else if(close < open)
         bearish++;
   }
   if(bullish - bearish >= 1)
      return 1;
   if(bearish - bullish >= 1)
      return -1;
   return 0;
}

int EvaluateVWAPBias()
{
   double reference = 0.0;
   bool vwapOk = false;
   if(UseVWAP)
   {
      double numerator = 0.0;
      double denom = 0.0;
      for(int i = 0; i < VWAPPeriod; i++)
      {
         double high = iHigh(g_symbol, PERIOD_M1, i);
         double low = iLow(g_symbol, PERIOD_M1, i);
         double close = iClose(g_symbol, PERIOD_M1, i);
         double typical = (high + low + close) / 3.0;
         double volume = iVolume(g_symbol, PERIOD_M1, i);
         numerator += typical * volume;
         denom += volume;
      }
      if(denom > 0.0)
      {
         reference = numerator / denom;
         vwapOk = true;
      }
   }
   if(!vwapOk)
      reference = iMA(g_symbol, PERIOD_M1, 20, 0, MODE_EMA, PRICE_TYPICAL, 0);

   double price = MarketInfo(g_symbol, MODE_BID);
   if(price > reference)
      return 1;
   if(price < reference)
      return -1;
   return 0;
}

// === Liquidity Imbalance =====================================================
bool DetectLiquidityImbalance(int direction)
{
   bool accel = DetectTickAcceleration(direction);
   bool range = DetectRangeEscape(direction);
   return (accel && range);
}

bool DetectTickAcceleration(int direction)
{
   if(g_tickVelocitySamples < 3)
      return false;

   int depth = g_tickDepth;
   int latestIndex = (g_tickVelocityIndex - 1 + depth) % depth;
   double latestVelocity = g_tickVelocityHistory[latestIndex];
   double avgVelocity = GetAverageTickVelocity();
   double latestDir = g_tickDirectionHistory[latestIndex];

   if(avgVelocity <= 0.0)
      return false;

   if(latestVelocity >= avgVelocity * TickAccelerationFactor &&
      ((direction == 1 && latestDir > 0) || (direction == -1 && latestDir < 0)))
      return true;

   return false;
}

bool DetectRangeEscape(int direction)
{
   int bars = MathMax(3, MicroRangeBars);
   int highestShift = iHighest(g_symbol, PERIOD_M1, MODE_HIGH, bars, 1);
   int lowestShift  = iLowest(g_symbol, PERIOD_M1, MODE_LOW, bars, 1);
   if(highestShift < 0 || lowestShift < 0)
      return false;

   double highest = iHigh(g_symbol, PERIOD_M1, highestShift);
   double lowest  = iLow(g_symbol, PERIOD_M1, lowestShift);
   double bid = MarketInfo(g_symbol, MODE_BID);
   double ask = MarketInfo(g_symbol, MODE_ASK);
   double buffer = RangeBreakBufferPoints * g_point;

   if(direction == 1 && bid > highest + buffer)
      return true;
   if(direction == -1 && ask < lowest - buffer)
      return true;
   return false;
}

// === Position Sizing =========================================================
double ComputeDynamicTPPoints(double spreadPoints, double atrPoints)
{
   double baseTP = TPSpreadMultiplier * spreadPoints;
   double atrBuffer = atrPoints * TPVolatilityBuffer;
   double target = baseTP + atrBuffer;
   double minTP = spreadPoints + 2.0;
   if(target < minTP)
      target = minTP;
   return target;
}

double ComputeEmergencyStopPoints(double atrPoints)
{
   double stop = atrPoints * ATRStopMultiplier;
   stop = MathMax(stop, 50.0); // enforce >= ~5 pips
   return stop;
}

double CalculatePositionSize(double stopPoints)
{
   if(stopPoints <= 0.0)
      return 0.0;

   double riskCapital = AccountEquity() * (RiskPerTradePercent / 100.0);
   if(riskCapital <= 0)
      return 0.0;

   double lotStep = g_lotStep;
   if(lotStep <= 0.0)
      lotStep = 0.01;

   double valuePerPoint = 0.0;
   if(g_tickSize > 0.0 && g_tickValue > 0.0)
      valuePerPoint = g_tickValue * (g_point / g_tickSize);
   if(valuePerPoint <= 0.0)
      valuePerPoint = 1.0;

   double riskPerLot = stopPoints * valuePerPoint;
   if(riskPerLot <= 0.0)
      return 0.0;

   double lots = riskCapital / riskPerLot;

   if(stopPoints > HighVolatilityATRPoints)
      lots *= HighVolatilityLotReducer;

   lots = MathMax(lots, g_minLot);
   lots = MathMin(lots, g_maxLot);

   double steps = MathFloor(lots / lotStep);
   lots = steps * lotStep;
   lots = MathMax(lots, g_minLot);
   lots = MathMin(lots, g_maxLot);
   lots = NormalizeDouble(lots, 2);
   return lots;
}

// === Preconditions ===========================================================
bool AllowNewTrade(const MarketSnapshot &snapshot)
{
   if(!snapshot.sessionAllowed || !snapshot.newsAllowed)
      return false;
   if(!snapshot.calmVolatility)
      return false;
   if(snapshot.atrPoints <= 0.0)
      return false;
   if(snapshot.avgSpreadPoints <= 0 || snapshot.avgSpreadPoints > CalmSpreadPoints)
      return false;
   if(snapshot.spreadPoints > MaxSpreadPoints)
      return false;
   if((TimeCurrent() - g_lastTradeTime) < MinTradeIntervalSec)
      return false;
   return true;
}

bool HasActiveTrade()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == g_symbol && OrderMagicNumber() == MagicNumber)
         {
            g_trade.ticket = OrderTicket();
            g_trade.direction = (OrderType() == OP_BUY ? 1 : -1);
            g_trade.lots = OrderLots();
            g_trade.entryPrice = OrderOpenPrice();
            if(g_trade.openTime == 0)
               g_trade.openTime = OrderOpenTime();
            return true;
         }
      }
   }
   ResetTradeContext();
   return false;
}

void SyncActiveTrade()
{
   if(g_trade.ticket <= 0)
      return;
   if(!OrderSelect(g_trade.ticket, SELECT_BY_TICKET))
   {
      ResetTradeContext();
      return;
   }
   if(OrderCloseTime() > 0)
   {
      ResetTradeContext();
      return;
   }
   g_trade.entryPrice = OrderOpenPrice();
   g_trade.lots = OrderLots();
   g_trade.direction = (OrderType() == OP_BUY ? 1 : -1);
   g_trade.openTime = OrderOpenTime();
   if(g_trade.emergencyStopPrice == 0.0)
   {
      double atrPoints = ComputeATRPoints();
      double stopPoints = ComputeEmergencyStopPoints(atrPoints);
      if(stopPoints > 0)
         g_trade.emergencyStopPrice = (g_trade.direction == 1 ? g_trade.entryPrice - stopPoints * g_point
                                                              : g_trade.entryPrice + stopPoints * g_point);
   }
}

// === Trade Management ========================================================
void ManageOpenTrade(const MarketSnapshot &snapshot)
{
   if(!HasActiveTrade())
      return;

   double spread = snapshot.spreadPoints;
   double atrPoints = snapshot.atrPoints;
   g_trade.dynamicTPPoints = ComputeDynamicTPPoints(spread, atrPoints);

   if(PriceHitHiddenStop(snapshot))
   {
      CloseTrade("EmergencyStop");
      return;
   }

   if(ShouldQuickTakeProfit(snapshot))
   {
      CloseTrade("QuickMomentumTP");
      return;
   }

   if(MomentumWeakening(g_trade.direction))
   {
      CloseTrade("MomentumWeakness");
      return;
   }

   double currentPrice = (g_trade.direction == 1 ? snapshot.bid : snapshot.ask);
   double distancePoints = (currentPrice - g_trade.entryPrice) / g_point * g_trade.direction;
   if(distancePoints >= g_trade.dynamicTPPoints)
   {
      CloseTrade("DynamicTP");
      return;
   }

   double emergencyStopPoints = ComputeEmergencyStopPoints(atrPoints);
   double lossPoints = -distancePoints;
   if(EnableHedging && !g_trade.hedgeAttempted && lossPoints >= emergencyStopPoints * HedgeDrawdownFactor)
   {
      if((TimeCurrent() - g_trade.openTime) >= HedgeCooldownSeconds)
      {
         bool hedgeResult = AttemptHedge(g_trade.direction, snapshot);
         bool stillActive = HasActiveTrade();
         if(hedgeResult || !stillActive)
         {
            g_trade.hedgeAttempted = true;
            return;
         }
      }
   }
}

bool PriceHitHiddenStop(const MarketSnapshot &snapshot)
{
   if(g_trade.direction == 0 || g_trade.emergencyStopPrice == 0.0)
      return false;
   if(g_trade.direction == 1 && snapshot.bid <= g_trade.emergencyStopPrice)
      return true;
   if(g_trade.direction == -1 && snapshot.ask >= g_trade.emergencyStopPrice)
      return true;
   return false;
}

bool ShouldQuickTakeProfit(const MarketSnapshot &snapshot)
{
   double elapsed = TimeCurrent() - g_trade.openTime;
   if(elapsed > QuickProfitSeconds)
      return false;

   double price = (g_trade.direction == 1 ? snapshot.bid : snapshot.ask);
   double gainPoints = (price - g_trade.entryPrice) / g_point * g_trade.direction;
   double trigger = MathMax(snapshot.spreadPoints * QuickProfitFactor, 4.0);
   return (gainPoints >= trigger);
}

bool MomentumWeakening(int direction)
{
   double fastNow = iMA(g_symbol, PERIOD_M1, FastMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double fastPrev = iMA(g_symbol, PERIOD_M1, FastMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
   double slowNow = iMA(g_symbol, PERIOD_M1, SlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double slowPrev = iMA(g_symbol, PERIOD_M1, SlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
   double diffNow = fastNow - slowNow;
   double diffPrev = fastPrev - slowPrev;

   int candleBias = EvaluateCandleBias();

   if(direction == 1)
   {
      if(diffNow < MomentumWeaknessBuffer || candleBias < 0)
         return true;
      if(diffNow < diffPrev)
         return true;
   }
   else
   {
      if(diffNow > -MomentumWeaknessBuffer || candleBias > 0)
         return true;
      if(diffNow > diffPrev)
         return true;
   }
   return false;
}

bool CloseTrade(string reason)
{
   return CloseTradeWithClock(reason, true);
}

bool CloseTradeWithClock(string reason, bool updateClock)
{
   if(g_trade.ticket <= 0)
      return false;

   if(!OrderSelect(g_trade.ticket, SELECT_BY_TICKET))
   {
      ResetTradeContext();
      return false;
   }

   double price = (g_trade.direction == 1 ? MarketInfo(g_symbol, MODE_BID) : MarketInfo(g_symbol, MODE_ASK));
   bool result = OrderClose(g_trade.ticket, g_trade.lots, price, SlippagePoints, clrFireBrick);
   if(result)
   {
      g_lastCloseTime = TimeCurrent();
      if(updateClock)
         g_lastTradeTime = g_lastCloseTime;
      LogEvent("EXIT", reason + " | Profit=" + DoubleToString(OrderProfit(), 2));
      ResetTradeContext();
   }
   else
   {
      LogEvent("EXIT_FAIL", reason + " error=" + IntegerToString(GetLastError()));
   }
   return result;
}

// === Order Entry =============================================================
bool ExecuteEntry(int direction, double lots, const MarketSnapshot &snapshot)
{
   int orderType = (direction == 1 ? OP_BUY : OP_SELL);
   double price = (direction == 1 ? snapshot.ask : snapshot.bid);

   double stopPoints = ComputeEmergencyStopPoints(snapshot.atrPoints);
   double stopPrice = (direction == 1 ? price - stopPoints * g_point : price + stopPoints * g_point);
   double dynamicTP = ComputeDynamicTPPoints(snapshot.spreadPoints, snapshot.atrPoints);

   int retries = 3;
   int ticket = -1;
   for(int attempt = 0; attempt < retries; attempt++)
   {
      RefreshRates();
      price = (direction == 1 ? MarketInfo(g_symbol, MODE_ASK) : MarketInfo(g_symbol, MODE_BID));
      ticket = OrderSend(g_symbol, orderType, lots, price, SlippagePoints, 0, 0, "MicroMomentumScalper", MagicNumber, 0, clrDodgerBlue);
      if(ticket > 0)
         break;
      Sleep(200);
   }

   if(ticket <= 0)
   {
      LogEvent("ORDER_FAIL", StringFormat("dir=%d lots=%.2f err=%d", direction, lots, GetLastError()));
      return false;
   }

   if(OrderSelect(ticket, SELECT_BY_TICKET))
   {
      g_trade.ticket = ticket;
      g_trade.direction = direction;
      g_trade.lots = lots;
      g_trade.entryPrice = OrderOpenPrice();
      double entry = g_trade.entryPrice;
      double stop = (direction == 1 ? entry - stopPoints * g_point : entry + stopPoints * g_point);
      g_trade.emergencyStopPrice = stop;
      g_trade.dynamicTPPoints = dynamicTP;
      g_trade.openTime = OrderOpenTime();
      g_trade.hedgeAttempted = false;
      g_lastTradeTime = TimeCurrent();
      LogEvent("ENTRY", StringFormat("Ticket=%d dir=%s lots=%.2f spread=%.1f ATR=%.1f", ticket, (direction==1?"BUY":"SELL"), lots, snapshot.spreadPoints, snapshot.atrPoints));
      return true;
   }

   return false;
}

bool AttemptHedge(int direction, const MarketSnapshot &snapshot)
{
   int hedgeDirection = -direction;
   double lots = g_trade.lots;
   if(lots < g_minLot)
      lots = g_minLot;

   LogEvent("HEDGE", "Flip attempt to " + (hedgeDirection==1?"BUY":"SELL"));
   if(!CloseTradeWithClock("HedgeFlip", false))
      return false;

   return ExecuteEntry(hedgeDirection, lots, snapshot);
}

// === Logging =================================================================
void LogEvent(string tag, string message)
{
   bool important = (tag == "ENTRY" || tag == "EXIT" || tag == "EXIT_FAIL" || tag == "ORDER_FAIL" || tag == "HEDGE" || tag == "DEINIT");
   if(!important && VPSMode && !EnableDetailedLogging)
      return;
   Print("[MicroMomentumScalper][", tag, "] ", message);
}

