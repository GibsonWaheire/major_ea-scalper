//+------------------------------------------------------------------+
//|  XauNewCandleScalper.mq4                                         |
//|  MT4 — XAUUSD New-Candle Entry + Dynamic Trailing SL             |
//|  v1.1 — relaxed RSI defaults, UseRSIFilter toggle                |
//+------------------------------------------------------------------+
#property copyright "MT4-MT5 EA Collection"
#property version   "1.10"
#property strict

//--- ================================================================
//    INPUT PARAMETERS
//--- ================================================================
extern string  __TradeSettings__    = "=== Trade Settings ===";
extern int     InpMagicNumber       = 20260411;  // Magic Number
extern double  InpLotSize           = 0.10;      // Lot Size
extern double  InpStopLoss_Pips     = 150.0;     // Stop Loss (points)

extern string  __TrailingSettings__ = "=== Trailing Stop Settings ===";
extern double  InpTrailingStart     = 100.0;     // Activate trail after X points profit
extern double  InpTrailingStep      = 50.0;      // Move SL by X points each time

extern string  __RSISettings__      = "=== RSI Filter ===";
extern bool    InpUseRSIFilter      = true;      // Enable RSI filter
extern int     InpRSIPeriod         = 14;        // RSI Period
extern double  InpRSIOverbought     = 55.0;      // RSI Sell threshold  (>55 = bearish momentum)
extern double  InpRSIOversold       = 45.0;      // RSI Buy  threshold  (<45 = bullish momentum)

extern string  __CandleSettings__   = "=== Candle Filter ===";
extern double  InpMinBodyPips       = 5.0;       // Min candle body size (points) — filters dojis

//--- ================================================================
//    GLOBAL VARIABLES
//--- ================================================================
datetime g_last_bar_time = 0;

//+------------------------------------------------------------------+
//|  OnInit                                                          |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpLotSize       <= 0){ Alert("XauNewCandleScalper: LotSize must be > 0");        return INIT_PARAMETERS_INCORRECT; }
   if(InpTrailingStart <= 0){ Alert("XauNewCandleScalper: TrailingStart must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTrailingStep  <= 0){ Alert("XauNewCandleScalper: TrailingStep must be > 0");  return INIT_PARAMETERS_INCORRECT; }

   Print("XauNewCandleScalper v1.10 (MT4) initialised | Symbol=", Symbol(),
         " | Magic=", InpMagicNumber, " | Lots=", InpLotSize,
         " | RSI Filter=", InpUseRSIFilter);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  OnDeinit                                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("XauNewCandleScalper (MT4) deinitialised. Reason=", reason);
}

//+------------------------------------------------------------------+
//|  OnTick — main loop                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1. Trailing stop runs on every tick — must be first
   ManageTrailingStop();

   //--- 2. Entry logic fires only once per candle
   if(!IsNewBar())
      return;

   //--- 3. Previous completed candle data (shift = 1)
   double prev_open  = iOpen (Symbol(), PERIOD_CURRENT, 1);
   double prev_close = iClose(Symbol(), PERIOD_CURRENT, 1);
   double prev_high  = iHigh (Symbol(), PERIOD_CURRENT, 1);
   double prev_low   = iLow  (Symbol(), PERIOD_CURRENT, 1);

   double point      = MarketInfo(Symbol(), MODE_POINT);
   double body_size  = MathAbs(prev_close - prev_open);

   //--- 4. Filter out doji / near-doji candles
   if(body_size < InpMinBodyPips * point)
      return;

   bool prev_bullish = (prev_close > prev_open);
   bool prev_bearish = (prev_close < prev_open);

   //--- 5. RSI filter (shift=1 = confirmed bar value)
   bool rsi_buy_ok  = true;
   bool rsi_sell_ok = true;

   if(InpUseRSIFilter)
   {
      double rsi = iRSI(Symbol(), PERIOD_CURRENT, InpRSIPeriod, PRICE_CLOSE, 1);
      rsi_buy_ok  = (rsi < InpRSIOversold);    // below 45 → bullish pressure
      rsi_sell_ok = (rsi > InpRSIOverbought);  // above 55 → bearish pressure
   }

   //--- 6. Signal: Candle colour + RSI confluence
   if(prev_bullish && rsi_buy_ok)
   {
      if(!HasOpenOrder(OP_BUY))
         OpenTrade(OP_BUY);
   }
   else if(prev_bearish && rsi_sell_ok)
   {
      if(!HasOpenOrder(OP_SELL))
         OpenTrade(OP_SELL);
   }
}

//+------------------------------------------------------------------+
//|  IsNewBar                                                        |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime current_bar_time = iTime(Symbol(), PERIOD_CURRENT, 0);
   if(current_bar_time != g_last_bar_time)
   {
      g_last_bar_time = current_bar_time;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//|  OpenTrade                                                       |
//+------------------------------------------------------------------+
void OpenTrade(int order_type)
{
   double point  = MarketInfo(Symbol(), MODE_POINT);
   int    digits = (int)MarketInfo(Symbol(), MODE_DIGITS);

   double sl_distance = InpStopLoss_Pips * point;
   double ask         = MarketInfo(Symbol(), MODE_ASK);
   double bid         = MarketInfo(Symbol(), MODE_BID);

   double entry_price, stop_loss;

   if(order_type == OP_BUY)
   {
      entry_price = ask;
      stop_loss   = NormalizeDouble(ask - sl_distance, digits);
   }
   else
   {
      entry_price = bid;
      stop_loss   = NormalizeDouble(bid + sl_distance, digits);
   }

   int ticket = OrderSend(
      Symbol(),
      order_type,
      InpLotSize,
      entry_price,
      30,             // 3-pip slippage allowance
      stop_loss,
      0,              // no fixed TP — trailing stop manages exit
      "XauNewCandleScalper",
      InpMagicNumber,
      0,
      order_type == OP_BUY ? clrDodgerBlue : clrOrangeRed
   );

   if(ticket > 0)
      Print("Opened ", (order_type == OP_BUY ? "BUY" : "SELL"),
            " | Entry=", entry_price, " | SL=", stop_loss, " | Ticket=", ticket);
   else
      Print("OrderSend FAILED | error=", GetLastError(),
            " | ", (order_type == OP_BUY ? "BUY" : "SELL"),
            " | Ask=", ask, " | Bid=", bid, " | SL=", stop_loss);
}

//+------------------------------------------------------------------+
//|  ManageTrailingStop — every tick                                 |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double point  = MarketInfo(Symbol(), MODE_POINT);
   int    digits = (int)MarketInfo(Symbol(), MODE_DIGITS);

   double trail_start = InpTrailingStart * point;
   double trail_step  = InpTrailingStep  * point;

   double ask = MarketInfo(Symbol(), MODE_ASK);
   double bid = MarketInfo(Symbol(), MODE_BID);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()      != Symbol())        continue;
      if(OrderMagicNumber() != InpMagicNumber)  continue;

      double open_price = OrderOpenPrice();
      double current_sl = OrderStopLoss();
      double current_tp = OrderTakeProfit();
      int    otype      = OrderType();
      int    ticket     = OrderTicket();

      if(otype == OP_BUY)
      {
         double profit_dist = bid - open_price;
         if(profit_dist < trail_start) continue;

         double new_sl = NormalizeDouble(bid - trail_step, digits);
         if(new_sl > current_sl + trail_step)
         {
            if(!OrderModify(ticket, open_price, new_sl, current_tp, 0, clrDodgerBlue))
               Print("TrailSL BUY failed | error=", GetLastError(), " | ticket=", ticket);
         }
      }
      else if(otype == OP_SELL)
      {
         double profit_dist = open_price - ask;
         if(profit_dist < trail_start) continue;

         double new_sl = NormalizeDouble(ask + trail_step, digits);
         if(new_sl < current_sl - trail_step || current_sl == 0)
         {
            if(!OrderModify(ticket, open_price, new_sl, current_tp, 0, clrOrangeRed))
               Print("TrailSL SELL failed | error=", GetLastError(), " | ticket=", ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//|  HasOpenOrder                                                    |
//+------------------------------------------------------------------+
bool HasOpenOrder(int order_type)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()      != Symbol())        continue;
      if(OrderMagicNumber() != InpMagicNumber)  continue;
      if(OrderType()        == order_type)       return true;
   }
   return false;
}
//+------------------------------------------------------------------+
