#property copyright "Better Bot (c) 2025"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "1.00"
#property strict

input group "=== Risk & Money Management ==="
input double   StopLossPips          = 40.0;   // Fixed stop loss distance
input double   RiskPercentPerTrade   = 20.0;   // Percent of equity risked per trade
input double   TargetProfitPercent   = 5.0;    // Percent gain targeted per trade
input double   MaxSpreadPips         = 3.0;    // Reject trades above this spread

input group "=== Execution Controls ==="
input int      MagicNumber           = 302025; // Unique identifier for Better Bot orders
input int      TimerIntervalSeconds  = 5;      // Evaluation cadence
input bool     EnableSymbolRotation  = true;   // Consider preferred symbols list
input bool     AllowCurrentSymbol    = true;   // Allow trading on the attached chart symbol

string PreferredSymbols[4] = {"USDJPY", "GBPUSD", "US30", "US100"};

datetime lastEvaluationTime = 0;
bool     timerActive        = false;

double GetPipSize(const string symbol)
{
   int    digits = (int)MarketInfo(symbol, MODE_DIGITS);
   double point  = MarketInfo(symbol, MODE_POINT);

   if(digits == 3 || digits == 5) return point * 10.0;
   if(digits == 1)                return point * 10.0;
   return point;
}

int GetLotDigits(double lotStep)
{
   int digits = 0;
   while(lotStep > 0.0 && lotStep < 1.0 && digits < 8)
   {
      lotStep *= 10.0;
      digits++;
   }
   return digits;
}

double GetPipValuePerLot(const string symbol)
{
   double tickValue = MarketInfo(symbol, MODE_TICKVALUE);
   double tickSize  = MarketInfo(symbol, MODE_TICKSIZE);
   double pipSize   = GetPipSize(symbol);

   if(tickSize <= 0.0) return 0.0;
   return tickValue * (pipSize / tickSize);
}

double NormalizeLot(const string symbol, double volume)
{
   double minLot  = MarketInfo(symbol, MODE_MINLOT);
   double maxLot  = MarketInfo(symbol, MODE_MAXLOT);
   double lotStep = MarketInfo(symbol, MODE_LOTSTEP);

   if(maxLot <= 0.0) maxLot = 100.0;
   if(lotStep <= 0.0) lotStep = 0.01;

   volume = MathMax(volume, minLot);
   volume = MathMin(volume, maxLot);

   int lotDigits     = GetLotDigits(lotStep);
   double steps      = MathFloor(volume / lotStep);
   double normalized = steps * lotStep;
   normalized        = NormalizeDouble(normalized, lotDigits);

   if(normalized < minLot) normalized = minLot;
   return normalized;
}

bool IsSpreadAcceptable(const string symbol)
{
   double ask    = MarketInfo(symbol, MODE_ASK);
   double bid    = MarketInfo(symbol, MODE_BID);
   double pip    = GetPipSize(symbol);
   double spread = (ask - bid) / pip;

   return (spread <= MaxSpreadPips);
}

bool HasOpenBetterBotTrade()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() == MagicNumber && OrderSymbol() != "") return true;
   }
   return false;
}

double GetEffectiveStopPips(const string symbol)
{
   double pipSize         = GetPipSize(symbol);
   double point           = MarketInfo(symbol, MODE_POINT);
   double stopLevelPoints = MarketInfo(symbol, MODE_STOPLEVEL);
   double minStopDistance = stopLevelPoints * point;
   double minStopPips     = (pipSize > 0.0) ? (minStopDistance / pipSize) : StopLossPips;

   return MathMax(StopLossPips, minStopPips);
}

int DetectFairValueGap(const string symbol)
{
   const ENUM_TIMEFRAMES tf = PERIOD_M5;
   const int shiftC = 1;
   const int shiftB = shiftC + 1;
   const int shiftA = shiftC + 2;

   if(iBars(symbol, tf) <= shiftA) return -1;

   double highA  = iHigh(symbol, tf, shiftA);
   double lowA   = iLow(symbol, tf, shiftA);
   double highB  = iHigh(symbol, tf, shiftB);
   double lowB   = iLow(symbol, tf, shiftB);
   double openB  = iOpen(symbol, tf, shiftB);
   double closeB = iClose(symbol, tf, shiftB);
   double highC  = iHigh(symbol, tf, shiftC);
   double lowC   = iLow(symbol, tf, shiftC);
   double openC  = iOpen(symbol, tf, shiftC);
   double closeC = iClose(symbol, tf, shiftC);

   double emaFast = iMA(symbol, tf, 21, 0, MODE_EMA, PRICE_CLOSE, shiftC);
   double emaSlow = iMA(symbol, tf, 55, 0, MODE_EMA, PRICE_CLOSE, shiftC);

   bool bullishBias = (emaFast > emaSlow);
   bool bearishBias = (emaFast < emaSlow);

   bool bullishFVG = (highA < lowB) && (highA < lowC);
   bool bearishFVG = (lowA > highB) && (lowA > highC);

   bool midBullish = (closeB > openB) && (closeC > openC);
   bool midBearish = (closeB < openB) && (closeC < openC);

   if(bullishFVG && midBullish && bullishBias) return OP_BUY;
   if(bearishFVG && midBearish && bearishBias) return OP_SELL;

   if(bullishFVG && midBullish && !bearishBias) return OP_BUY;
   if(bearishFVG && midBearish && !bullishBias) return OP_SELL;

   return -1;
}

double CalculatePositionSize(const string symbol, int orderType, double stopPips)
{
   double riskAmount = AccountBalance() * (RiskPercentPerTrade / 100.0);
   double pipValue   = GetPipValuePerLot(symbol);

   if(pipValue <= 0.0) return 0.0;

   double riskPerLot = stopPips * pipValue;
   if(riskPerLot <= 0.0) return 0.0;

   double rawLot = riskAmount / riskPerLot;
   rawLot        = NormalizeLot(symbol, rawLot);

   double freeMargin = AccountFreeMarginCheck(symbol, orderType, rawLot);
   if(freeMargin < 0)
   {
      Print("Better Bot: Not enough margin for ", symbol, " at volume ", DoubleToString(rawLot, 2));
      return 0.0;
   }

   return rawLot;
}

bool PlaceBetterBotTrade(const string symbol, int orderType)
{
   if(orderType != OP_BUY && orderType != OP_SELL) return false;
   if(!SymbolSelect(symbol, true))
   {
      Print("Better Bot: Unable to select symbol ", symbol);
      return false;
   }

   RefreshRates();

   if(!IsSpreadAcceptable(symbol))
   {
      Print("Better Bot: Spread too high for ", symbol);
      return false;
   }

   double effectiveStopPips = GetEffectiveStopPips(symbol);
   double lot               = CalculatePositionSize(symbol, orderType, effectiveStopPips);
   if(lot <= 0.0)
   {
      Print("Better Bot: Lot size calculation failed for ", symbol);
      return false;
   }

   double pipSize    = GetPipSize(symbol);
   int    digits     = (int)MarketInfo(symbol, MODE_DIGITS);
   double ask        = MarketInfo(symbol, MODE_ASK);
   double bid        = MarketInfo(symbol, MODE_BID);
   double entryPrice = (orderType == OP_BUY) ? ask : bid;
   double slDistance = effectiveStopPips * pipSize;

   double minStopDistance = MarketInfo(symbol, MODE_STOPLEVEL) * MarketInfo(symbol, MODE_POINT);
   if(minStopDistance > 0.0 && slDistance < minStopDistance)
   {
      slDistance        = minStopDistance;
      effectiveStopPips = slDistance / pipSize;
   }

   double slPrice = (orderType == OP_BUY) ? (entryPrice - slDistance) : (entryPrice + slDistance);

   double pipValuePerLot = GetPipValuePerLot(symbol);
   double targetAmount   = AccountBalance() * (TargetProfitPercent / 100.0);
   double profitPerPip   = pipValuePerLot * lot;

   double targetPips = (profitPerPip > 0.0) ? (targetAmount / profitPerPip) : 0.0;
   if(targetPips <= 0.0) targetPips = effectiveStopPips;

   double tpDistance = targetPips * pipSize;
   if(tpDistance < pipSize) tpDistance = pipSize;

   double tpPrice = (orderType == OP_BUY) ? (entryPrice + tpDistance) : (entryPrice - tpDistance);

   slPrice    = NormalizeDouble(slPrice, digits);
   tpPrice    = NormalizeDouble(tpPrice, digits);
   entryPrice = NormalizeDouble(entryPrice, digits);

   string comment = "BetterBot FVG " + ((orderType == OP_BUY) ? "BUY" : "SELL");
   int    slippage = 3;

   int ticket = OrderSend(symbol, orderType, lot, entryPrice, slippage, slPrice, tpPrice, comment, MagicNumber, 0, clrDodgerBlue);
   if(ticket < 0)
   {
      int err = GetLastError();
      Print("Better Bot: OrderSend failed for ", symbol, " error=", err);
      return false;
   }

   Print("Better Bot: Opened ", (orderType == OP_BUY ? "BUY" : "SELL"), " ", symbol,
         " lot=", DoubleToString(lot, 2), " SL=", DoubleToString(slPrice, digits),
         " TP=", DoubleToString(tpPrice, digits), " ticket=", ticket);
   return true;
}

void EvaluateBetterBot()
{
   if(HasOpenBetterBotTrade()) return;

   string scanList[8];
   int    scanCount = 0;

   if(EnableSymbolRotation)
   {
      for(int i = 0; i < ArraySize(PreferredSymbols); i++)
      {
         if(PreferredSymbols[i] == "" || PreferredSymbols[i] == Symbol()) continue;
         scanList[scanCount++] = PreferredSymbols[i];
      }
   }

   if(AllowCurrentSymbol) scanList[scanCount++] = Symbol();

   for(int i = 0; i < scanCount; i++)
   {
      string sym = scanList[i];
      if(sym == "") continue;

      if(!SymbolSelect(sym, true)) continue;
      if(!IsSpreadAcceptable(sym)) continue;

      int signal = DetectFairValueGap(sym);
      if(signal == OP_BUY || signal == OP_SELL)
      {
         if(PlaceBetterBotTrade(sym, signal)) return;
      }
   }
}

int OnInit()
{
   Print("Better Bot EA initialized.");
   EventSetTimer(TimerIntervalSeconds);
   timerActive = true;
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(timerActive)
   {
      EventKillTimer();
      timerActive = false;
   }
   Print("Better Bot EA deinitialized. Reason=", reason);
}

void OnTimer()
{
   datetime now = TimeCurrent();
   if(lastEvaluationTime == now) return;

   lastEvaluationTime = now;
   EvaluateBetterBot();
   UpdateDashboard();
}

void OnTick()
{
   // Logic handled by timer; keep OnTick lightweight
}

void UpdateDashboard()
{
   double equity       = AccountEquity();
   double balance      = AccountBalance();
   bool   hasPosition  = HasOpenBetterBotTrade();
   string activeSymbol = "";
   int    orderType    = -1;
   double lotSize      = 0.0;
   double tradeProfit  = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber)           continue;

      activeSymbol = OrderSymbol();
      orderType    = OrderType();
      lotSize      = OrderLots();
      tradeProfit  = OrderProfit() + OrderSwap() + OrderCommission();
      break;
   }

   string positionText = "None";
   if(hasPosition)
   {
      if(orderType == OP_BUY)      positionText = "BUY " + activeSymbol;
      else if(orderType == OP_SELL) positionText = "SELL " + activeSymbol;
      else                          positionText = "OPEN " + activeSymbol;
   }

   string symbolLine = "";
   for(int i = 0; i < ArraySize(PreferredSymbols); i++)
   {
      if(PreferredSymbols[i] == "") continue;
      if(symbolLine != "") symbolLine += ", ";
      symbolLine += PreferredSymbols[i];
   }

   string status = StringFormat(
      "=== Better Bot v1.00 ===\nEquity: %.2f | Balance: %.2f\nPosition: %s\nLot: %.2f | P/L: %.2f\nRisk: %.1f%% | Target: %.1f%%\nSymbols: %s",
      equity,
      balance,
      positionText,
      lotSize,
      tradeProfit,
      RiskPercentPerTrade,
      TargetProfitPercent,
      symbolLine
   );

   Comment(status);
}


