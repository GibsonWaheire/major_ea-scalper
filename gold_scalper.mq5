//+------------------------------------------------------------------+
//|                                                gold_scalper.mq5 |
//|                                                     Claude Code |
//|                                             https://claude.ai/ |
//+------------------------------------------------------------------+
#property copyright "Claude Code"
#property link      "https://claude.ai/"
#property version   "1.00"
#property description "MT5 Gold Scalper EA with EMA and RSI entry, and trailing stop."

#include <Trade\Trade.mqh>

input double           InpLots             = 0.01;
input long             InpMagic            = 12345;
input ENUM_TIMEFRAMES  InpSignalTF         = PERIOD_CURRENT;
input int              InpEMAPeriod9       = 9;
input int              InpEMAPeriod21      = 21;
input int              InpRSIPeriod        = 14;
input bool             InpUseRSI           = true;
input double           InpRSIForBuy        = 48.0;
input double           InpRSIForSell       = 52.0;
input double           InpTrailStart       = 10.0;
input double           InpTrailStep        = 2.0;

CTrade        m_trade;
datetime      lastBarTime         = 0;
int           hEMA9               = INVALID_HANDLE;
int           hEMA21              = INVALID_HANDLE;
int           hRSI                = INVALID_HANDLE;

void SetTradeFillingBySymbol()
  {
   long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) != 0)
      m_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fm & SYMBOL_FILLING_IOC) != 0)
      m_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
  }

double InitialSlDistancePoints()
  {
   long stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return MathMax(InpTrailStep, (double)stops);
  }

ENUM_TIMEFRAMES SignalTimeframe()
  {
   if(InpSignalTF == PERIOD_CURRENT)
      return(Period());
   return(InpSignalTF);
  }

double NormalizeVolumeLots(const double lots)
  {
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st <= 0.0)
      st = 0.01;
   double v = lots;
   if(v < mn)
      v = mn;
   if(v > mx)
      v = mx;
   v = MathFloor(v / st + 1e-12) * st;
   if(v < mn)
      v = mn;
   return(v);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   m_trade.SetExpertMagicNumber(InpMagic);
   m_trade.SetDeviationInPoints(10);
   SetTradeFillingBySymbol();

   ENUM_TIMEFRAMES tf = SignalTimeframe();
   if(!SymbolSelect(_Symbol, true))
      Print("gold_scalper: SymbolSelect warning for ", _Symbol, " err=", GetLastError());

   ResetLastError();
   hEMA9  = iMA(_Symbol, tf, InpEMAPeriod9, 0, MODE_EMA, PRICE_CLOSE);
   hEMA21 = iMA(_Symbol, tf, InpEMAPeriod21, 0, MODE_EMA, PRICE_CLOSE);
   hRSI   = iRSI(_Symbol, tf, InpRSIPeriod, PRICE_CLOSE);
   if(hEMA9 == INVALID_HANDLE || hEMA21 == INVALID_HANDLE || hRSI == INVALID_HANDLE)
     {
      int err = GetLastError();
      Print("gold_scalper: indicator handle failed | hEMA9=", hEMA9,
            " hEMA21=", hEMA21, " hRSI=", hRSI,
            " tf=", (long)tf, " err=", err);
      return(INIT_FAILED);
     }
   long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   long st = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   Print("gold_scalper: started | ", _Symbol, " chartTF=", (long)Period(), " signalTF=", (long)tf,
         " magic=", InpMagic, " stopsLevel=", st, " fillingMode=", fm);
   Comment("gold_scalper running on ", _Symbol);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Comment("");
   Print("gold_scalper: stopped reason=", reason);
   if(hEMA9  != INVALID_HANDLE) IndicatorRelease(hEMA9);
   if(hEMA21 != INVALID_HANDLE) IndicatorRelease(hEMA21);
   if(hRSI   != INVALID_HANDLE) IndicatorRelease(hRSI);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   static bool s_loggedFirstTick = false;
   if(!s_loggedFirstTick)
     {
      s_loggedFirstTick = true;
      Print("gold_scalper: first OnTick (EA is receiving ticks)");
     }

   if(HasOpenPositions())
      ManageTrailingStop();

   datetime currentBarTime = iTime(_Symbol, SignalTimeframe(), 0);
   if(currentBarTime == 0 || currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;

   double ema9_buf[3], ema21_buf[3], rsi_buf[2];
   if(CopyBuffer(hEMA9, 0, 0, 3, ema9_buf) < 3 ||
      CopyBuffer(hEMA21, 0, 0, 3, ema21_buf) < 3)
      return;

   double ema9_bar1   = ema9_buf[1];
   double ema9_bar2   = ema9_buf[2];
   double ema21_bar1  = ema21_buf[1];
   double ema21_bar2  = ema21_buf[2];
   double rsi_bar1    = 50.0;

   if(ema9_bar1 == EMPTY_VALUE || ema9_bar2 == EMPTY_VALUE ||
      ema21_bar1 == EMPTY_VALUE || ema21_bar2 == EMPTY_VALUE)
      return;

   if(InpUseRSI)
     {
      if(CopyBuffer(hRSI, 0, 0, 2, rsi_buf) < 2)
         return;
      rsi_bar1 = rsi_buf[1];
      if(rsi_bar1 == EMPTY_VALUE)
         return;
     }

   bool hasOpenPosition = HasOpenPositions();

   if(!hasOpenPosition)
     {
      bool rsiBuyOk  = (!InpUseRSI) || (rsi_bar1 > InpRSIForBuy);
      bool rsiSellOk = (!InpUseRSI) || (rsi_bar1 < InpRSIForSell);
      if(ema9_bar2 < ema21_bar2 && ema9_bar1 > ema21_bar1 && rsiBuyOk)
         PlaceBuyOrder();
      else if(ema9_bar2 > ema21_bar2 && ema9_bar1 < ema21_bar1 && rsiSellOk)
         PlaceSellOrder();
     }
  }

//+------------------------------------------------------------------+
bool HasOpenPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong position_ticket = PositionGetTicket(i);
      if(position_ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
void PlaceBuyOrder()
  {
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    dig   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double slPts = InitialSlDistancePoints();
   double sl    = NormalizeDouble(ask - slPts * point, dig);
   double tp    = 0;

   double vol = NormalizeVolumeLots(InpLots);
   if(m_trade.Buy(vol, _Symbol, ask, sl, tp, "GoldScalperBuy"))
      Print("BUY order placed successfully.");
   else
      Print("Failed to place BUY order. Error: ", m_trade.ResultRetcode(), " - ", m_trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
void PlaceSellOrder()
  {
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    dig   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double slPts = InitialSlDistancePoints();
   double sl    = NormalizeDouble(bid + slPts * point, dig);
   double tp    = 0;

   double vol = NormalizeVolumeLots(InpLots);
   if(m_trade.Sell(vol, _Symbol, bid, sl, tp, "GoldScalperSell"))
      Print("SELL order placed successfully.");
   else
      Print("Failed to place SELL order. Error: ", m_trade.ResultRetcode(), " - ", m_trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong position_ticket = PositionGetTicket(i);
      if(position_ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      double open_price  = PositionGetDouble(POSITION_PRICE_OPEN);
      double current_sl  = PositionGetDouble(POSITION_SL);
      double current_tp  = PositionGetDouble(POSITION_TP);
      long   position_type = PositionGetInteger(POSITION_TYPE);
      double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int    dig           = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      if(position_type == POSITION_TYPE_BUY)
        {
         double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit_in_points = (current_price - open_price) / point;
         if(profit_in_points >= InpTrailStart)
           {
            double new_sl = NormalizeDouble(current_price - InpTrailStep * point, dig);
            if(current_sl == 0.0 || new_sl > current_sl)
              {
               if(!m_trade.PositionModify(position_ticket, new_sl, current_tp))
                  Print("Failed to modify BUY position #", position_ticket, " SL. Error: ", m_trade.ResultRetcode(), " - ", m_trade.ResultRetcodeDescription());
              }
           }
        }
      else if(position_type == POSITION_TYPE_SELL)
        {
         double current_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit_in_points = (open_price - current_price) / point;
         if(profit_in_points >= InpTrailStart)
           {
            double new_sl = NormalizeDouble(current_price + InpTrailStep * point, dig);
            if(current_sl == 0.0 || new_sl < current_sl)
              {
               if(!m_trade.PositionModify(position_ticket, new_sl, current_tp))
                  Print("Failed to modify SELL position #", position_ticket, " SL. Error: ", m_trade.ResultRetcode(), " - ", m_trade.ResultRetcodeDescription());
              }
           }
        }
     }
  }
