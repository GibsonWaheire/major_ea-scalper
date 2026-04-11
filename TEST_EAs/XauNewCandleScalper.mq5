//+------------------------------------------------------------------+
//|  XauNewCandleScalper.mq5                                         |
//|  Senior MQL5 EA — XAUUSD New-Candle Entry + Dynamic Trailing SL |
//|  Strategy: RSI + Candle Colour confluence on candle open         |
//+------------------------------------------------------------------+
#property copyright "MT4-MT5 EA Collection"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- ================================================================
//    INPUT PARAMETERS
//--- ================================================================
input group "=== Trade Settings ==="
input ulong  InpMagicNumber   = 20260411;   // Magic Number
input double InpLotSize       = 0.10;       // Lot Size
input double InpStopLoss_Pips = 150.0;      // Stop Loss (in pips / points)

input group "=== Trailing Stop Settings ==="
input double InpTrailingStart = 100.0;      // Trailing Start — activate after X points profit
input double InpTrailingStep  =  50.0;      // Trailing Step  — move SL by X points each time

input group "=== RSI Filter ==="
input int    InpRSIPeriod     = 14;         // RSI Period
input int    InpRSIOverbought = 70;         // RSI Overbought level (Sell signal)
input int    InpRSIOversold   = 30;         // RSI Oversold   level (Buy signal)

//--- ================================================================
//    GLOBAL OBJECTS & HANDLES
//--- ================================================================
CTrade  Trade;                  // Standard trade object
int     g_rsi_handle;           // RSI indicator handle
datetime g_last_bar_time = 0;   // Tracks the open time of the last processed candle

//+------------------------------------------------------------------+
//|  OnInit — validate inputs, create indicator handles              |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Basic sanity checks
   if(InpLotSize     <= 0){ Alert("XauNewCandleScalper: LotSize must be > 0");        return INIT_PARAMETERS_INCORRECT; }
   if(InpTrailingStart <= 0){ Alert("XauNewCandleScalper: TrailingStart must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTrailingStep  <= 0){ Alert("XauNewCandleScalper: TrailingStep must be > 0");  return INIT_PARAMETERS_INCORRECT; }

   //--- Configure trade object
   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(30);          // max 3 pips slippage — tight for Gold
   Trade.SetTypeFilling(ORDER_FILLING_IOC); // IOC is widely supported on MT5 brokers

   //--- Create RSI handle on the current chart symbol & M1 timeframe
   g_rsi_handle = iRSI(_Symbol, PERIOD_CURRENT, InpRSIPeriod, PRICE_CLOSE);
   if(g_rsi_handle == INVALID_HANDLE)
   {
      Alert("XauNewCandleScalper: Failed to create RSI handle — error ", GetLastError());
      return INIT_FAILED;
   }

   Print("XauNewCandleScalper initialised. Symbol=", _Symbol,
         " | Magic=", InpMagicNumber,
         " | Lots=",  InpLotSize);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  OnDeinit — release indicator handles                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_rsi_handle != INVALID_HANDLE)
      IndicatorRelease(g_rsi_handle);

   Print("XauNewCandleScalper deinitialised. Reason=", reason);
}

//+------------------------------------------------------------------+
//|  OnTick — main loop                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1. Always run the trailing stop on every tick (protects during fast moves)
   ManageTrailingStop();

   //--- 2. Entry logic fires only on the open of a new candle
   if(!IsNewBar())
      return;

   //--- 3. Fetch indicator & price data
   double rsi_buf[2];
   if(CopyBuffer(g_rsi_handle, 0, 0, 2, rsi_buf) < 2)
   {
      Print("XauNewCandleScalper: CopyBuffer failed — skipping bar");
      return;
   }
   // rsi_buf[0] = current (just opened) bar RSI
   // rsi_buf[1] = previous completed bar RSI  (index 1 in indicator terms)
   double rsi_prev = rsi_buf[1];

   //--- 4. Read the PREVIOUS completed candle (index 1)
   double prev_open  = iOpen (_Symbol, PERIOD_CURRENT, 1);
   double prev_close = iClose(_Symbol, PERIOD_CURRENT, 1);

   bool prev_bullish = (prev_close > prev_open);
   bool prev_bearish = (prev_close < prev_open);

   //--- 5. Entry signal evaluation
   //       BUY  : previous candle was Bullish AND RSI < Oversold (30)
   //       SELL : previous candle was Bearish AND RSI > Overbought (70)
   if(prev_bullish && rsi_prev < InpRSIOversold)
   {
      if(!HasOpenPosition(POSITION_TYPE_BUY))
         OpenTrade(ORDER_TYPE_BUY);
   }
   else if(prev_bearish && rsi_prev > InpRSIOverbought)
   {
      if(!HasOpenPosition(POSITION_TYPE_SELL))
         OpenTrade(ORDER_TYPE_SELL);
   }
}

//+------------------------------------------------------------------+
//|  IsNewBar — returns true exactly once on the open of each candle |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime current_bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(current_bar_time != g_last_bar_time)
   {
      g_last_bar_time = current_bar_time;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//|  OpenTrade — normalise price & SL then place the order           |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE order_type)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl_distance = InpStopLoss_Pips * point;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double entry_price, stop_loss;

   if(order_type == ORDER_TYPE_BUY)
   {
      entry_price = ask;
      stop_loss   = NormalizeDouble(ask - sl_distance, digits);
      Trade.Buy(InpLotSize, _Symbol, entry_price, stop_loss, 0,
                "XauNewCandleScalper BUY");
   }
   else
   {
      entry_price = bid;
      stop_loss   = NormalizeDouble(bid + sl_distance, digits);
      Trade.Sell(InpLotSize, _Symbol, entry_price, stop_loss, 0,
                 "XauNewCandleScalper SELL");
   }

   if(Trade.ResultRetcode() == TRADE_RETCODE_DONE ||
      Trade.ResultRetcode() == TRADE_RETCODE_PLACED)
      Print("Trade opened: ", EnumToString(order_type),
            " | Entry=", entry_price, " | SL=", stop_loss,
            " | Ticket=", Trade.ResultOrder());
   else
      Print("Trade FAILED: ", Trade.ResultRetcodeDescription(),
            " (", Trade.ResultRetcode(), ")");
}

//+------------------------------------------------------------------+
//|  ManageTrailingStop — runs every tick after TrailingStart hit    |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double trailing_start_dist = InpTrailingStart * point;
   double trailing_step_dist  = InpTrailingStep  * point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      //--- Only manage positions belonging to this EA and symbol
      if(PositionGetString(POSITION_SYMBOL)         != _Symbol)       continue;
      if(PositionGetInteger(POSITION_MAGIC)          != InpMagicNumber) continue;

      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double current_sl = PositionGetDouble(POSITION_SL);
      ENUM_POSITION_TYPE pos_type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(pos_type == POSITION_TYPE_BUY)
      {
         double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit_dist = bid - open_price;

         //--- Only activate once TrailingStart profit is reached
         if(profit_dist < trailing_start_dist) continue;

         //--- Desired new SL = current bid minus one trailing step
         double new_sl = NormalizeDouble(bid - trailing_step_dist, digits);

         //--- Only move SL upward and only by at least one step
         if(new_sl > current_sl + trailing_step_dist)
         {
            if(!Trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP)))
               Print("TrailSL modify failed: ", Trade.ResultRetcodeDescription());
         }
      }
      else if(pos_type == POSITION_TYPE_SELL)
      {
         double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit_dist = open_price - ask;

         if(profit_dist < trailing_start_dist) continue;

         double new_sl = NormalizeDouble(ask + trailing_step_dist, digits);

         //--- Only move SL downward and only by at least one step
         if(new_sl < current_sl - trailing_step_dist || current_sl == 0)
         {
            if(!Trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP)))
               Print("TrailSL modify failed: ", Trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
//|  HasOpenPosition — prevents stacking duplicate positions         |
//+------------------------------------------------------------------+
bool HasOpenPosition(ENUM_POSITION_TYPE pos_type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)        continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == pos_type)
         return true;
   }
   return false;
}
//+------------------------------------------------------------------+
