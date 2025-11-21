

#property copyright "Copyright 2025"
#property link      "https://www.mcgibsdigitalsolutions.com"
#property version   "2.00"
#property strict

// ---------------------------------------------------------------------------
// Input Configuration
// ---------------------------------------------------------------------------
input group "===== Instruments ====="
input string   SymbolList          = "AUTO";   // comma separated symbols; AUTO = majors+minors from Market Watch
input bool     UseAllMarketWatch   = true;
input bool     RestrictToFXMajors  = true;

input group "===== Signal Settings ====="
input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_M1;
input int      TrendPeriodFast     = 10;
input int      TrendPeriodSlow     = 20;
input int      MomentumPeriod      = 9;
input double   MinMomentumStrength = 15.0;

input group "===== Execution Settings ====="
input bool     UseRiskPerTrade     = true;
input double   RiskPercentPerTrade = 0.40;
input double   FixedLotSize        = 0.01;
input bool     UseStopLoss         = false;
input int      StopLossPips        = 15;
input double   TakeProfitPips1     = 5.0;
input double   TakeProfitPips2     = 8.0;
input double   TakeProfitPips3     = 10.0;
input bool     UseLimitEntries     = true;
input bool     AutoFallbackToMarket= true;
input double   LimitOffsetPips     = 1.5;
input double   CommissionBufferPips= 0.3;
input double   BasketProfitPercent = 1.5;
input bool     CloseOnTP2Reach     = true;
input double   MaxSpreadPips       = 6.0;
input int      TradeIntervalSec    = 5;
input int      MagicNumber         = 888888;
input group "===== Symbol Filter ====="
input bool     UseMajorSymbolFilter = true;
input string   AllowedSymbolsList   = "EURUSD,GBPUSD,USDJPY,USDCHF,USDCAD,AUDUSD,NZDUSD,XAUUSD";

input group "===== Safety Limits ====="
input double   MaxDailyLossKES     = 5000.0;
input double   DailyProfitTargetKES= 10000.0;
input int      MaxTradesPerDay     = 5;
input int      StartHour           = 0;
input int      EndHour             = 23;

// ---------------------------------------------------------------------------
// Internal Structures
// ---------------------------------------------------------------------------
struct ActiveTrade
{
   int      ticket;
   string   symbol;
   int      direction;
   double   lots;
   datetime openTime;
   double   entryPrice;
   bool     isPending;
};

// ---------------------------------------------------------------------------
// Global State
// ---------------------------------------------------------------------------
string  symbolPool[];
int     symbolCount     = 0;
int     symbolCursor    = 0;
datetime lastTradeTime  = 0;

double   dailyProfit    = 0;
int      dailyTradeCount= 0;
int      dailyWins      = 0;
int      dailyLosses    = 0;
datetime lastDayReset   = 0;
double   dailyStartEquity = 0;
bool     tradingEnabled = true;

ActiveTrade currentTrade;
bool        tradeActive = false;

string majorTokens[];
int    majorTokenCount = 0;
string allowedMajorBases[] = {"EURUSD","GBPUSD","USDJPY","USDCHF","USDCAD","AUDUSD","NZDUSD"};
string allowedMinorPrefixes[] = {"EUR","GBP","AUD","NZD","CHF","CAD","USD","JPY"};
string exoticPrefixes[] = {"USDTRY","USDZAR","USDMXN","USDHUF","EURSEK","EURPLN","USDNOK","USDINR","USDHKD","EURTRY","GBPTRY","CHFTRY","JPYTRY"};
string commodityBlocks[] = {"XAG","SILVER","UKOIL","USOIL","WTI","BRENT","COPPER","NGAS","XPT","XPD","WHEAT","CORN"};
string indexPrefixes[] = {"NAS","US3","SPX","SP","DJ","GER","DE","JP","NK","FTSE","FRA","ITA","AUS","HK","HSI","UK","EU","CAC","DAX"};
string usIndexPrefixes[] = {"US30","US500","US100","US2000","NAS","NDX","SPX","SP500","SP","DJ","DJI","US3","US5","US10"};
string strictSymbolWhitelist[] = {"XAUUSD","US30","GBPUSD"};
string cryptoPrefixes[] = {"BTC","ETH","XRP","SOL","ADA","DOT","DOGE","BNB","LTC","SHIB","BCH","XLM","TRX","AVAX","MATIC"};

// ---------------------------------------------------------------------------
// Helper Utilities
// ---------------------------------------------------------------------------
string TrimString(string text)
{
   int len = StringLen(text);
   if(len == 0) return "";

   int start = 0;
   while(start < len)
   {
      int ch = StringGetChar(text, start);
      if(ch != ' ' && ch != '\t' && ch != '\r' && ch != '\n')
         break;
      start++;
   }

   int end = len - 1;
   while(end >= start)
   {
      int ch = StringGetChar(text, end);
      if(ch != ' ' && ch != '\t' && ch != '\r' && ch != '\n')
         break;
      end--;
   }

   if(end < start)
      return "";

   return StringSubstr(text, start, end - start + 1);
}

string ToUpper(string text)
{
   int len = StringLen(text);
   string result = "";
   for(int i = 0; i < len; i++)
   {
      int ch = StringGetChar(text, i);
      if(ch >= 'a' && ch <= 'z')
         ch -= 32;
      result += CharToString((ushort)ch);
   }
   return result;
}

string CurrencyLabel()
{
   string cur = AccountCurrency();
   if(StringLen(cur) == 0)
      cur = "CUR";
   return cur;
}

void ClearSymbolPool()
{
   ArrayResize(symbolPool, 0);
   symbolCount = 0;
   symbolCursor = 0;
}

void ResetCurrentTrade()
{
   currentTrade.ticket = -1;
   currentTrade.symbol = "";
   currentTrade.direction = 0;
   currentTrade.lots = 0;
   currentTrade.openTime = 0;
   currentTrade.entryPrice = 0;
   currentTrade.isPending = false;
   tradeActive = false;
}

void BuildMajorTokenList()
{
   ArrayResize(majorTokens, 0);
   majorTokenCount = 0;

   if(!UseMajorSymbolFilter)
      return;

   string token = "";
   int len = StringLen(AllowedSymbolsList);
   for(int idx = 0; idx < len; idx++)
   {
      int ch = StringGetChar(AllowedSymbolsList, idx);
      if(ch == ',' || ch == ';')
      {
         token = TrimString(token);
         if(StringLen(token) > 0)
         {
            int size = ArraySize(majorTokens);
            ArrayResize(majorTokens, size + 1);
            majorTokens[size] = ToUpper(token);
         }
         token = "";
      }
      else
      {
         token += StringSubstr(AllowedSymbolsList, idx, 1);
      }
   }
   token = TrimString(token);
   if(StringLen(token) > 0)
   {
      int size = ArraySize(majorTokens);
      ArrayResize(majorTokens, size + 1);
      majorTokens[size] = ToUpper(token);
   }

   majorTokenCount = ArraySize(majorTokens);
}

string ExtractBaseSymbol(const string sym)
{
   string up = ToUpper(sym);
   string base = "";
   int len = StringLen(up);
   for(int i = 0; i < len; i++)
   {
      int ch = StringGetChar(up, i);
      if((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9'))
         base += CharToString((char)ch);
      else
         break;
   }
   return base;
}

bool StartsWith(const string value, const string prefix)
{
   int plen = StringLen(prefix);
   if(plen == 0) return false;
   if(StringLen(value) < plen) return false;
   return StringSubstr(value, 0, plen) == prefix;
}

bool InStringArray(const string value, string &arr[])
{
   for(int i = 0; i < ArraySize(arr); i++)
      if(value == arr[i])
         return true;
   return false;
}

bool SymbolMatchesAllowed(const string sym)
{
   string base = ExtractBaseSymbol(sym);
   if(base == "")
      return false;

   if(!IsStrictWhitelisted(base))
   {
      Print("Trading disabled for this symbol.");
      return false;
   }

   bool isGold = StartsWith(base, "XAU");

   for(int c = 0; c < ArraySize(commodityBlocks); c++)
      if(StartsWith(base, commodityBlocks[c]))
      {
         Print("Trading disabled for this symbol.");
         return false;
      }

   for(int e = 0; e < ArraySize(exoticPrefixes); e++)
      if(StartsWith(base, exoticPrefixes[e]))
      {
         Print("Trading disabled for this symbol.");
         return false;
      }

   bool isUSIndex = false;
   for(int u = 0; u < ArraySize(usIndexPrefixes); u++)
      if(StartsWith(base, usIndexPrefixes[u])) { isUSIndex = true; break; }

   bool matchesIndex = isUSIndex;
   if(!matchesIndex)
   {
      for(int i = 0; i < ArraySize(indexPrefixes); i++)
         if(StartsWith(base, indexPrefixes[i])) { matchesIndex = true; break; }
   }

   bool isCrypto = false;
   for(int k = 0; k < ArraySize(cryptoPrefixes); k++)
      if(StartsWith(base, cryptoPrefixes[k])) { isCrypto = true; break; }

   if(isCrypto)
   {
      Print("Trading disabled for this symbol.");
      return false;
   }

   if(matchesIndex && !isUSIndex)
   {
      Print("Trading disabled for this symbol.");
      return false;
   }

   bool fxCandidate = IsFxMajorOrMinor(base);
   if(!isGold && !isUSIndex && !fxCandidate)
   {
      Print("Trading disabled for this symbol.");
      return false;
   }

   if(RestrictToFXMajors)
   {
      if(!fxCandidate && !isGold && !isUSIndex)
      {
         Print("Trading disabled for this symbol.");
         return false;
      }
   }

   if(UseMajorSymbolFilter && majorTokenCount > 0 && fxCandidate)
   {
      bool match = false;
      for(int j = 0; j < majorTokenCount; j++)
      {
         string token = majorTokens[j];
         if(token == "") continue;
         if(StartsWith(base, token))
         {
            match = true;
            break;
         }
      }
      if(!match)
      {
         Print("Trading disabled for this symbol.");
         return false;
      }
   }

   return true;
}

bool IsFxMajorOrMinor(const string base)
{
   if(StringLen(base) < 6)
      return false;

   if(InStringArray(base, allowedMajorBases))
      return true;

   string pref = StringSubstr(base, 0, 3);
   string suff = StringSubstr(base, 3, 3);
   if(InStringArray(pref, allowedMinorPrefixes) && InStringArray(suff, allowedMinorPrefixes))
      return true;

   return false;
}

bool CanTradeSymbol(const string sym)
{
   if(!IsTradeAllowed(sym, TimeCurrent()))
      return false;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;

   double tradeAllowed = MarketInfo(sym, MODE_TRADEALLOWED);
   if(tradeAllowed == 0.0)
      return false;

   return true;
}

bool ShouldFallbackToMarket(const int errorCode)
{
   if(errorCode == ERR_TRADE_DISABLED || errorCode == ERR_TRADE_NOT_ALLOWED)
      return true;

   return false;
}

bool IsStrictWhitelisted(const string base)
{
   string upper = ToUpper(base);
   for(int i = 0; i < ArraySize(strictSymbolWhitelist); i++)
   {
      string token = strictSymbolWhitelist[i];
      if(token == "") continue;
      if(upper == token)
         return true;
   }
   return false;
}

// ---------------------------------------------------------------------------
// Forward Declarations
// ---------------------------------------------------------------------------
string  ExtractBaseSymbol(const string sym);
bool    StartsWith(const string value, const string prefix);
bool    InStringArray(const string value, string &arr[]);
bool    BuildSymbolPool();
void    AddSymbol(string sym);
bool    TryOpenTrade();
bool    EvaluateSymbol(const string sym, int &direction);
bool    PlaceOrder(const string sym, int direction);
double  CalculatePipPoint(const string sym);
double  CalculatePipValue(const string sym);
double  NormalizeLots(const string sym, double lots);
int     GetSymbolSignal(const string sym);
bool    SpreadAcceptable(const string sym);
void    ManageActiveTrade();
void    SyncActiveTrade();
bool    CloseActiveTrade(const string reason);
void    CloseAllTrades();
void    CheckDailyReset();
void    CheckDailyLimits();
void    HandleClosedTrade(int ticket, double pl);
void    UpdateDisplay();
string  GetStatus();
bool    IsFxMajorOrMinor(const string base);
bool    CanTradeSymbol(const string sym);
bool    ShouldFallbackToMarket(const int errorCode);
bool    IsStrictWhitelisted(const string base);

// ---------------------------------------------------------------------------
int OnInit()
{
   Print("========================================");
   Print("UltraFastScalper v2.00");
   Print("========================================");

   MathSrand((int)TimeLocal());
   ClearSymbolPool();

   if(!BuildSymbolPool())
   {
      Alert("UltraFastScalper: No tradable symbols found. Please configure SymbolList/MarketWatch.");
      return(INIT_FAILED);
   }

   ResetCurrentTrade();

   lastDayReset     = iTime(Symbol(), PERIOD_D1, 0);
   dailyStartEquity = AccountEquity();
   lastTradeTime    = 0;

   Print("Loaded symbols: ", symbolCount);
   return(INIT_SUCCEEDED);
}

// ---------------------------------------------------------------------------
void OnDeinit(const int reason)
{
   CloseAllTrades();
   Comment("");
   Print("UltraFastScalper deinitialized. Reason: ", reason);
}

// ---------------------------------------------------------------------------
void OnTick()
{
   CheckDailyReset();
   CheckDailyLimits();
   SyncActiveTrade();
   ManageActiveTrade();

   if(tradingEnabled && !tradeActive)
   {
      if((TimeCurrent() - lastTradeTime) >= TradeIntervalSec)
      {
         if(TryOpenTrade())
         lastTradeTime = TimeCurrent();
      }
   }

   UpdateDisplay();
}

// ---------------------------------------------------------------------------
bool BuildSymbolPool()
{
   ClearSymbolPool();

   bool useAuto = true;
   string cleanedList = TrimString(SymbolList);
   if(StringLen(cleanedList) > 0 && StringCompare(ToUpper(cleanedList), "AUTO") != 0)
      useAuto = false;

   if(UseAllMarketWatch || useAuto)
   {
      int total = SymbolsTotal(true);
      for(int i = 0; i < total; i++)
      {
         string sym = SymbolName(i, true);
         if(StringLen(sym) > 0)
            AddSymbol(sym);
      }
   }

   if(!useAuto && StringLen(SymbolList) > 0)
   {
      string token = "";
      int len = StringLen(SymbolList);
      for(int idx = 0; idx < len; idx++)
      {
         int ch = StringGetChar(SymbolList, idx);
         if(ch == ',' || ch == ';')
         {
            token = TrimString(token);
            if(StringLen(token) > 0)
               AddSymbol(token);
            token = "";
         }
         else
         {
            token += StringSubstr(SymbolList, idx, 1);
         }
      }
      token = TrimString(token);
      if(StringLen(token) > 0)
         AddSymbol(token);
   }

   symbolCount = ArraySize(symbolPool);
   symbolCursor = 0;
   return (symbolCount > 0);
}

// ---------------------------------------------------------------------------
void AddSymbol(string sym)
{
   if(sym == "") return;
   sym = TrimString(sym);
   if(StringLen(sym) == 0) return;

   // ensure symbol is available
   bool selected = SymbolSelect(sym, true);
   double tick = MarketInfo(sym, MODE_TICKSIZE);
    if(!selected || tick <= 0)
      return;

   if(!SymbolMatchesAllowed(sym))
      return;

   // check duplicates
   for(int i = 0; i < ArraySize(symbolPool); i++)
   {
      if(symbolPool[i] == sym)
      return;
   }

   int size = ArraySize(symbolPool);
   ArrayResize(symbolPool, size + 1);
   symbolPool[size] = sym;
}

// ---------------------------------------------------------------------------
bool TryOpenTrade()
{
   if(symbolCount == 0) return false;

   int attempts = symbolCount;
   while(attempts > 0)
   {
      if(symbolCursor >= symbolCount)
         symbolCursor = 0;

      string sym = symbolPool[symbolCursor];
      symbolCursor++;
      attempts--;

      int direction = 0;
      if(EvaluateSymbol(sym, direction))
      {
         if(direction == OP_BUY || direction == OP_SELL)
         {
            if(PlaceOrder(sym, direction))
               return true;
         }
      }
   }
   return false;
}

// ---------------------------------------------------------------------------
bool EvaluateSymbol(const string sym, int &direction)
{
   direction = -1;

   if(!SpreadAcceptable(sym))
      return false;

   int signal = GetSymbolSignal(sym);
   if(signal != OP_BUY && signal != OP_SELL)
      return false;

   direction = signal;
   return true;
}

// ---------------------------------------------------------------------------
bool PlaceOrder(const string sym, int direction)
{
   int currentHour = Hour();
   if(currentHour < StartHour || currentHour >= EndHour)
      return false;

   if(!CanTradeSymbol(sym))
   {
      Print("UltraFastScalper: Trading disabled by broker for ", sym, ". Skipping order attempt.");
      return false;
   }

   double lotSize = FixedLotSize;
   if(UseRiskPerTrade && UseStopLoss && StopLossPips > 0)
   {
      double pipValue = CalculatePipValue(sym);
      if(pipValue > 0)
      {
         double riskCurrency = AccountEquity() * (RiskPercentPerTrade / 100.0);
         double calcLot = riskCurrency / (StopLossPips * pipValue);
         lotSize = NormalizeLots(sym, calcLot);
      }
      else
      {
         lotSize = NormalizeLots(sym, FixedLotSize);
      }
   }
   else
   {
      lotSize = NormalizeLots(sym, FixedLotSize);
   }

   lotSize = MathMax(lotSize, FixedLotSize);

   double marketPrice = (direction == OP_BUY) ? MarketInfo(sym, MODE_ASK) : MarketInfo(sym, MODE_BID);
   double pipPoint = CalculatePipPoint(sym);
   int digits = (int)MarketInfo(sym, MODE_DIGITS);

   double entryPrice = marketPrice;
   int sendType = direction;
   bool pendingAttempt = false;

   if(UseLimitEntries)
   {
      double offset = MathMax(LimitOffsetPips, 0.1) * pipPoint;
      if(direction == OP_BUY)
      {
         sendType = OP_BUYLIMIT;
         entryPrice = marketPrice - offset;
      }
      else
      {
         sendType = OP_SELLLIMIT;
         entryPrice = marketPrice + offset;
      }
      pendingAttempt = true;
   }

   entryPrice = NormalizeDouble(entryPrice, digits);

   double tp1 = MathMax(TakeProfitPips1, 1.0);
   double tp2 = MathMax(TakeProfitPips2, tp1);
   double tp3 = MathMax(TakeProfitPips3, tp2);
   double buffer = MathMax(CommissionBufferPips, 0.0);
   double targetPips = tp3 + buffer;

   double sl = 0.0;
   if(UseStopLoss && StopLossPips > 0)
   {
      sl = (direction == OP_BUY) ? entryPrice - StopLossPips * pipPoint
                                 : entryPrice + StopLossPips * pipPoint;
      sl = NormalizeDouble(sl, digits);
   }
   double tp = (direction == OP_BUY) ? entryPrice + targetPips * pipPoint
                                     : entryPrice - targetPips * pipPoint;

   tp = NormalizeDouble(tp, digits);

   color arrowColor = (direction == OP_BUY) ? clrLime : clrTomato;
   for(int attempt = 0; attempt < 2; attempt++)
   {
      int ticket = OrderSend(sym, sendType, lotSize, entryPrice, 0, sl, tp,
                             "UltraFast", MagicNumber, 0, arrowColor);

      if(ticket > 0)
      {
         currentTrade.ticket = ticket;
         currentTrade.symbol = sym;
         currentTrade.direction = direction;
         currentTrade.lots = lotSize;
         currentTrade.openTime = TimeCurrent();
         currentTrade.entryPrice = entryPrice;
         currentTrade.isPending = (sendType == OP_BUYLIMIT || sendType == OP_SELLLIMIT);
         tradeActive = true;
         return true;
      }

      int err = GetLastError();
      Print("UltraFastScalper: OrderSend failed ", err, " on ", sym, " (attempt ", attempt + 1, ")");

      bool allowRetry = (attempt == 0 && pendingAttempt && AutoFallbackToMarket && ShouldFallbackToMarket(err));
      if(!allowRetry)
         return false;

      Print("UltraFastScalper: Retrying ", sym, " as market order because pending order was rejected (error ", err, ")");

      pendingAttempt = false;
      sendType = direction;
      RefreshRates();
      marketPrice = (direction == OP_BUY) ? MarketInfo(sym, MODE_ASK) : MarketInfo(sym, MODE_BID);
      entryPrice = NormalizeDouble(marketPrice, digits);
      if(UseStopLoss && StopLossPips > 0)
      {
         sl = (direction == OP_BUY) ? entryPrice - StopLossPips * pipPoint
                                    : entryPrice + StopLossPips * pipPoint;
         sl = NormalizeDouble(sl, digits);
      }
      else
      {
         sl = 0.0;
      }
      tp = (direction == OP_BUY) ? entryPrice + targetPips * pipPoint
                                 : entryPrice - targetPips * pipPoint;
      tp = NormalizeDouble(tp, digits);
   }

   return false;
}

// ---------------------------------------------------------------------------
double CalculatePipPoint(const string sym)
{
   double point = MarketInfo(sym, MODE_POINT);
   int digits = (int)MarketInfo(sym, MODE_DIGITS);
   if(digits == 3 || digits == 5)
      point *= 10.0;
   return point;
}

// ---------------------------------------------------------------------------
double CalculatePipValue(const string sym)
{
   double tickValue = MarketInfo(sym, MODE_TICKVALUE);
   double tickSize  = MarketInfo(sym, MODE_TICKSIZE);
   double pipPoint  = CalculatePipPoint(sym);
   if(tickSize <= 0 || pipPoint <= 0) return 0.0;
   return (tickValue / tickSize) * pipPoint;
}

// ---------------------------------------------------------------------------
double NormalizeLots(const string sym, double lots)
{
   double minLot  = MarketInfo(sym, MODE_MINLOT);
   double maxLot  = MarketInfo(sym, MODE_MAXLOT);
   double lotStep = MarketInfo(sym, MODE_LOTSTEP);

   if(lotStep <= 0) lotStep = 0.01;
   if(minLot <= 0)  minLot  = 0.01;
   if(maxLot <= 0)  maxLot  = 100.0;

   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / lotStep + 0.0001) * lotStep;
   return NormalizeDouble(lots, 2);
}

// ---------------------------------------------------------------------------
int GetSymbolSignal(const string sym)
{
   double emaFast = iMA(sym, SignalTimeframe, TrendPeriodFast, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaSlow = iMA(sym, SignalTimeframe, TrendPeriodSlow, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi     = iRSI(sym, SignalTimeframe, MomentumPeriod, PRICE_CLOSE, 0);

   double price   = iClose(sym, SignalTimeframe, 0);
   double prev    = iClose(sym, SignalTimeframe, 1);

   bool uptrend   = emaFast > emaSlow;
   bool downtrend = emaFast < emaSlow;
   bool priceAbove= price > emaFast;
   bool priceBelow= price < emaFast;

   bool bullishMomentum = rsi > (50 + MinMomentumStrength);
   bool bearishMomentum = rsi < (50 - MinMomentumStrength);

   int buyScore = 0;
   if(uptrend) buyScore++;
   if(priceAbove) buyScore++;
   if(bullishMomentum) buyScore++;
   if(price > prev) buyScore++;

   int sellScore = 0;
   if(downtrend) sellScore++;
   if(priceBelow) sellScore++;
   if(bearishMomentum) sellScore++;
   if(price < prev) sellScore++;

   if(buyScore >= 3 && sellScore <= 1)  return OP_BUY;
   if(sellScore >= 3 && buyScore <= 1)  return OP_SELL;
   return -1;
}

// ---------------------------------------------------------------------------
bool SpreadAcceptable(const string sym)
{
   double ask = MarketInfo(sym, MODE_ASK);
   double bid = MarketInfo(sym, MODE_BID);
   if(ask <= 0 || bid <= 0) return false;

   double spread = (ask - bid) / CalculatePipPoint(sym);
   return (spread <= MaxSpreadPips);
}

// ---------------------------------------------------------------------------
void ManageActiveTrade()
{
   if(!tradeActive || currentTrade.ticket <= 0)
      return;

   if(!OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
   {
      if(OrderSelect(currentTrade.ticket, SELECT_BY_TICKET, MODE_HISTORY))
      {
         double pl = OrderProfit() + OrderSwap() + OrderCommission();
         HandleClosedTrade(currentTrade.ticket, pl);
      }
      tradeActive = false;
      currentTrade.ticket = -1;
      return;
   }

   if(OrderCloseTime() > 0)
   {
      double pl = OrderProfit() + OrderSwap() + OrderCommission();
      HandleClosedTrade(currentTrade.ticket, pl);
      tradeActive = false;
      currentTrade.ticket = -1;
      return;
   }

   double floatingPL = OrderProfit() + OrderSwap() + OrderCommission();
   if(BasketProfitPercent > 0.0)
   {
      double trigger = AccountBalance() * (BasketProfitPercent / 100.0);
      if(floatingPL >= trigger)
      {
         CloseActiveTrade("Basket percent target");
         return;
      }
   }

   if(CloseOnTP2Reach && TakeProfitPips2 > 0.0)
   {
      double pipPoint = CalculatePipPoint(currentTrade.symbol);
      double price    = (currentTrade.direction == OP_BUY)
                        ? MarketInfo(currentTrade.symbol, MODE_BID)
                        : MarketInfo(currentTrade.symbol, MODE_ASK);
      double entry    = currentTrade.entryPrice;
      double gainPips = (currentTrade.direction == OP_BUY)
                        ? (price - entry) / pipPoint
                        : (entry - price) / pipPoint;

      if(gainPips >= TakeProfitPips2)
      {
         CloseActiveTrade("TP2 reached");
         return;
      }
   }
}

// ---------------------------------------------------------------------------
void SyncActiveTrade()
{
   if(!tradeActive || currentTrade.ticket <= 0)
      return;

   if(OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
      return;

   if(OrderSelect(currentTrade.ticket, SELECT_BY_TICKET, MODE_HISTORY))
   {
      double pl = OrderProfit() + OrderSwap() + OrderCommission();
      HandleClosedTrade(currentTrade.ticket, pl);
   }
   tradeActive = false;
   currentTrade.ticket = -1;
}

// ---------------------------------------------------------------------------
bool CloseActiveTrade(const string reason)
{
   if(!tradeActive || currentTrade.ticket <= 0)
      return false;

   if(OrderSelect(currentTrade.ticket, SELECT_BY_TICKET))
   {
      double floatingPL = OrderProfit() + OrderSwap() + OrderCommission();
      if(floatingPL <= 0)
      {
         Print("UltraFastScalper: Skipping close (", reason, ") because trade not yet profitable (P&L: ",
               DoubleToString(floatingPL, 2), ")");
         return false;
      }

      double price = (currentTrade.direction == OP_BUY)
                     ? MarketInfo(currentTrade.symbol, MODE_BID)
                     : MarketInfo(currentTrade.symbol, MODE_ASK);

      if(price <= 0)
         return false;

      if(OrderClose(currentTrade.ticket, OrderLots(), price, 3, clrAqua))
      {
         Print("UltraFastScalper: Trade closed (", reason, ") | P&L: ",
               DoubleToString(floatingPL, 2));
         return true;
      }
      return false;
   }

   if(OrderSelect(currentTrade.ticket, SELECT_BY_TICKET, MODE_HISTORY))
      return true;

   return false;
}

// ---------------------------------------------------------------------------
void CloseAllTrades()
{
   if(!tradeActive)
      return;

   bool closed = CloseActiveTrade("CloseAll");
   if(closed)
   {
      tradeActive = false;
      currentTrade.ticket = -1;
   }
}

// ---------------------------------------------------------------------------
void CheckDailyReset()
{
   datetime currentDay = iTime(Symbol(), PERIOD_D1, 0);
   if(currentDay == lastDayReset)
      return;

   Print("========================================");
   Print("Daily Reset | Trades: ", dailyTradeCount, " | Wins: ", dailyWins,
         " | Losses: ", dailyLosses, " | P&L: ", DoubleToString(dailyProfit, 2));
   Print("========================================");

   dailyProfit = 0;
   dailyTradeCount = 0;
   dailyWins = 0;
   dailyLosses = 0;
   dailyStartEquity = AccountEquity();
   lastDayReset = currentDay;
   tradingEnabled = true;
}

// ---------------------------------------------------------------------------
void CheckDailyLimits()
{
   if(!tradingEnabled)
      return;

   if(dailyTradeCount >= MaxTradesPerDay)
   {
      tradingEnabled = false;
      CloseAllTrades();
      Print("UltraFastScalper: Max trades per day reached. Pausing.");
      return;
   }

   if(dailyProfit >= DailyProfitTargetKES)
   {
      tradingEnabled = false;
      CloseAllTrades();
      Print("UltraFastScalper: Daily profit target hit (", CurrencyLabel(), "). Pausing.");
      return;
   }

   if(dailyProfit <= -MaxDailyLossKES)
   {
      tradingEnabled = false;
      CloseAllTrades();
      Print("UltraFastScalper: Daily loss limit hit (", CurrencyLabel(), "). Pausing.");
      return;
   }
}

// ---------------------------------------------------------------------------
void HandleClosedTrade(int ticket, double pl)
{
   dailyProfit += pl;
   dailyTradeCount++;
   if(pl > 0) dailyWins++; else dailyLosses++;
}

// ---------------------------------------------------------------------------
void UpdateDisplay()
{
   Comment(GetStatus());
}

// ---------------------------------------------------------------------------
string GetStatus()
{
   double winRate = (dailyTradeCount > 0) ? (double)dailyWins * 100.0 / dailyTradeCount : 0.0;
   string tradeInfo = tradeActive ? StringConcatenate(currentTrade.symbol, " | ",
                                                      DoubleToString(currentTrade.lots, 2), " lots, ",
                                                      (currentTrade.direction == OP_BUY ? "BUY" : "SELL"))
                                  : "None";
   string cur = CurrencyLabel();

   string status = "⚡ UltraFastScalper ⚡\n";
   status += "Trading: " + string(tradingEnabled ? "ON" : "OFF") + " | Active Trade: " + tradeInfo + "\n";
   status += "========================================\n";
   status += "Daily P&L: " + DoubleToString(dailyProfit, 2) + " " + cur + " | Trades: " +
             IntegerToString(dailyTradeCount) + " | Win%: " + DoubleToString(winRate, 1) + "%\n";
   status += "Goals: +" + DoubleToString(DailyProfitTargetKES, 0) + " / -" +
             DoubleToString(MaxDailyLossKES, 0) + " " + cur + " | Max/Day: " +
             IntegerToString(MaxTradesPerDay) + "\n";
   status += "Current Pool: " + IntegerToString(symbolCount) + " symbols\n";
   status += "========================================\n";
   status += "Risk: " + DoubleToString(RiskPercentPerTrade, 2) + "% | SL: " + IntegerToString(StopLossPips) +
             " pips | TP Levels: " + DoubleToString(TakeProfitPips1, 1) + "/" +
             DoubleToString(TakeProfitPips2, 1) + "/" + DoubleToString(TakeProfitPips3, 1) + " pips\n";
   return status;
}

