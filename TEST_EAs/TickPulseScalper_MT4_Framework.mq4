//+------------------------------------------------------------------+
//|  TickPulseScalper_MT4_Framework.mq4                              |
//|  MQL5 → MQL4 Conversion Framework                               |
//|  XAUUSD High-Frequency Tick-Pulse Candle Analysis Scalper        |
//|                                                                  |
//|  INCREMENTAL BUILD GUIDE — paste your 13,000 lines into the      |
//|  labelled MODULE sections below one block at a time.             |
//|  Each module is self-contained and independently testable.       |
//+------------------------------------------------------------------+
#property copyright "MT4-MT5 EA Collection"
#property version   "1.00"
#property strict

//+==================================================================+
//||  SECTION 1 — GLOBAL MEMORY LAYOUT                              ||
//||  Rule: declare ALL arrays/objects here at file scope.           ||
//||  NEVER declare large arrays inside OnTick() — 32-bit MT4       ||
//||  stack is ~1MB; a 10k-element double array = 80KB on stack.    ||
//+==================================================================+

//--- ── Core state machine ──────────────────────────────────────────
datetime  g_last_bar_time     = 0;       // new-candle gate
double    g_candle_open       = 0.0;     // captured open of current bar
int       g_pulse_state       = 0;       // 0=waiting, 1=armed, 2=fired
int       g_tick_count        = 0;       // ticks elapsed since bar open
datetime  g_bar_arm_time      = 0;       // timestamp when pulse was armed

//--- ── Trade tracking ──────────────────────────────────────────────
int       g_buy_ticket        = -1;
int       g_sell_ticket       = -1;
double    g_last_trail_sl     = 0.0;

//--- ── Performance / safety counters ──────────────────────────────
int       g_error146_retries  = 0;
int       g_consecutive_fails = 0;
datetime  g_last_trade_time   = 0;

//--- ── Indicator value cache (refreshed once per bar) ─────────────
//    Store computed values here — never re-call iRSI/iBands inside
//    tight OnTick loops. Calculate once in OnNewBar(), read in OnTick.
double    g_rsi_val           = 50.0;
double    g_bands_upper       = 0.0;
double    g_bands_lower       = 0.0;
double    g_bands_mid         = 0.0;
double    g_atr_val           = 0.0;

//--- ── Pre-allocated tick-history ring buffer ──────────────────────
//    Fixed-size ring — NEVER use ArrayResize inside OnTick().
//    1,000 doubles = 8KB — safe for 32-bit MT4.
#define   TICK_BUFFER_SIZE    1000
double    g_bid_ring[TICK_BUFFER_SIZE];
double    g_ask_ring[TICK_BUFFER_SIZE];
datetime  g_tick_time[TICK_BUFFER_SIZE];
int       g_ring_pos          = 0;       // current write head

//--- ── Spread / volatility snapshot ───────────────────────────────
double    g_spread_points     = 0.0;
double    g_point             = 0.0;     // cached once in OnInit
int       g_digits            = 0;

//+==================================================================+
//||  SECTION 2 — INPUT PARAMETERS                                  ||
//||  #property strict forbids implicit casts — all types explicit. ||
//+==================================================================+

extern string  __s1__              = "=== Tick-Pulse Entry ===";
extern double  InpPulseTrigger     = 3.0;   // Points price must move from bar open to arm
extern int     InpPulseMaxTicks    = 10;    // Abandon pulse if not armed within N ticks
extern double  InpMinSpread        = 0.0;   // Min spread filter  (0 = disabled)
extern double  InpMaxSpread        = 40.0;  // Max spread filter  (40 pts on Gold)

extern string  __s2__              = "=== Trade Management ===";
extern int     InpMagicNumber      = 77777;
extern double  InpLotSize          = 0.10;
extern double  InpStopLoss_Pts     = 150.0; // SL in points
extern int     InpMaxOpenTrades    = 1;     // hard cap

extern string  __s3__              = "=== Tight-Trace Trailing ===";
extern double  InpTrailActivate    = 10.0;  // Profit in points before trail starts
extern double  InpTrailStep        = 1.0;   // Trail moves every N points (1-2 for XAUUSD)
extern double  InpTrailLock        = 5.0;   // Lock-in floor (trail never goes below entry + this)

extern string  __s4__              = "=== Indicator Filters ===";
extern bool    InpUseRSI           = true;
extern int     InpRSIPeriod        = 14;
extern double  InpRSIBuyMax        = 60.0;  // Only buy if RSI < this
extern double  InpRSISellMin       = 40.0;  // Only sell if RSI > this
extern bool    InpUseBands         = false;
extern int     InpBandsPeriod      = 20;
extern double  InpBandsDeviation   = 2.0;
extern bool    InpUseATR           = true;
extern int     InpATRPeriod        = 14;
extern double  InpMinATR_Pts       = 5.0;   // Skip entry if ATR too low (flat market)

extern string  __s5__              = "=== Safety ===";
extern int     InpMaxRetries       = 3;     // Max retries on error 146
extern int     InpRetryDelayMs     = 200;   // ms between retries
extern int     InpCooldownSecs     = 5;     // seconds between any two trades
extern int     InpMaxDailyTrades   = 50;    // hard daily cap

//+==================================================================+
//||  SECTION 3 — OnInit                                            ||
//+==================================================================+
int OnInit()
{
   //--- Cache point/digits — used thousands of times in OnTick
   g_point  = MarketInfo(Symbol(), MODE_POINT);
   g_digits = (int)MarketInfo(Symbol(), MODE_DIGITS);

   if(g_point == 0){ Alert("TickPulse: Invalid symbol point size"); return INIT_FAILED; }

   //--- Zero the ring buffer
   ArrayInitialize(g_bid_ring,  0.0);
   ArrayInitialize(g_ask_ring,  0.0);
   ArrayInitialize(g_tick_time, 0);

   //--- Validate inputs
   if(InpLotSize    <= 0){ Alert("TickPulse: LotSize must be > 0");  return INIT_PARAMETERS_INCORRECT; }
   if(InpTrailStep  <= 0){ Alert("TickPulse: TrailStep must be > 0"); return INIT_PARAMETERS_INCORRECT; }

   Print("TickPulseScalper MT4 online | Symbol=", Symbol(),
         " | Point=", g_point, " | Digits=", g_digits,
         " | Magic=", InpMagicNumber);
   return INIT_SUCCEEDED;
}

//+==================================================================+
//||  SECTION 4 — OnDeinit                                          ||
//+==================================================================+
void OnDeinit(const int reason)
{
   // No handles to release in MT4 — all indicator calls are inline.
   Print("TickPulseScalper MT4 offline. Reason=", reason);
}

//+==================================================================+
//||  SECTION 5 — OnTick  (ZERO-LAG CRITICAL PATH)                 ||
//||  Rule: no heavy computation here. Read cached values only.     ||
//+==================================================================+
void OnTick()
{
   //--- 0. Push tick into ring buffer (always, every tick)
   PushTickToRing();

   //--- 1. Tight-Trace trailing stop — FIRST, before any logic
   TightTraceTrail();

   //--- 2. Detect new bar — runs indicator calcs once per bar
   bool new_bar = IsNewBar();
   if(new_bar)
      OnNewBar();

   //--- 3. Tick-pulse gate
   if(!IsPulseArmed(new_bar))
      return;

   //--- 4. Safety checks (spread, cooldown, daily cap)
   if(!IsTradingAllowed())
      return;

   //--- 5. Indicator confluence (reads cached values — no lag)
   int signal = GetSignal();
   if(signal == 0)
      return;

   //--- 6. Execute
   if(signal == 1  && !HasOpenOrder(OP_BUY))
      ExecuteTrade(OP_BUY);
   else if(signal == -1 && !HasOpenOrder(OP_SELL))
      ExecuteTrade(OP_SELL);
}

//+==================================================================+
//||  SECTION 6 — TICK-PULSE ENGINE                                 ||
//+==================================================================+

//--- Called once on the open of each new bar
void OnNewBar()
{
   g_candle_open   = iOpen(Symbol(), PERIOD_CURRENT, 0); // current bar open
   g_pulse_state   = 1;    // armed — waiting for X-point move
   g_tick_count    = 0;
   g_bar_arm_time  = TimeCurrent();
   g_ring_pos      = 0;    // reset ring for fresh bar

   //--- Refresh all indicator caches here (once per bar = no OnTick lag)
   RefreshIndicatorCache();
}

//--- Returns true if the pulse trigger has fired this bar
bool IsPulseArmed(bool new_bar)
{
   if(g_pulse_state == 0) return false;  // not yet initialised
   if(g_pulse_state == 2) return false;  // already fired this bar

   g_tick_count++;

   //--- Abandon if too many ticks elapsed without triggering
   if(g_tick_count > InpPulseMaxTicks)
   {
      g_pulse_state = 0;
      return false;
   }

   double ask         = MarketInfo(Symbol(), MODE_ASK);
   double bid         = MarketInfo(Symbol(), MODE_BID);
   double trigger_up  = g_candle_open + InpPulseTrigger * g_point;
   double trigger_dn  = g_candle_open - InpPulseTrigger * g_point;

   //--- Price moved up by X points from bar open → bullish pulse
   if(ask >= trigger_up)
   {
      g_pulse_state = 2;  // fired — prevent re-entry this bar
      return true;
   }
   //--- Price moved down by X points from bar open → bearish pulse
   if(bid <= trigger_dn)
   {
      g_pulse_state = 2;
      return true;
   }

   return false;
}

//--- Determine direction from pulse + indicator confluence
int GetSignal()
{
   double ask = MarketInfo(Symbol(), MODE_ASK);
   double bid = MarketInfo(Symbol(), MODE_BID);

   double trigger_up = g_candle_open + InpPulseTrigger * g_point;
   double trigger_dn = g_candle_open - InpPulseTrigger * g_point;

   bool pulse_bull = (ask >= trigger_up);
   bool pulse_bear = (bid <= trigger_dn);

   //--- ATR volatility filter — skip flat markets
   if(InpUseATR && g_atr_val < InpMinATR_Pts * g_point)
      return 0;

   //--- RSI filter (cached — zero lag)
   bool rsi_buy_ok  = !InpUseRSI || (g_rsi_val < InpRSIBuyMax);
   bool rsi_sell_ok = !InpUseRSI || (g_rsi_val > InpRSISellMin);

   //--- Bollinger Bands filter (optional)
   bool bands_buy_ok  = !InpUseBands || (bid <= g_bands_lower);
   bool bands_sell_ok = !InpUseBands || (ask >= g_bands_upper);

   if(pulse_bull && rsi_buy_ok  && bands_buy_ok)  return  1;
   if(pulse_bear && rsi_sell_ok && bands_sell_ok) return -1;

   return 0;
}

//+==================================================================+
//||  SECTION 7 — INDICATOR CACHE                                   ||
//||  MQL5 → MQL4 conversion: handle-based → direct inline calls   ||
//||                                                                 ||
//||  MQL5 (OLD):                                                    ||
//||    int h = iRSI(_Symbol,PERIOD_CURRENT,14,PRICE_CLOSE);         ||
//||    double buf[1];                                               ||
//||    CopyBuffer(h,0,1,1,buf);  double rsi = buf[0];              ||
//||                                                                 ||
//||  MQL4 (NEW):                                                    ||
//||    double rsi = iRSI(Symbol(),PERIOD_CURRENT,14,PRICE_CLOSE,1); ||
//+==================================================================+
void RefreshIndicatorCache()
{
   //--- RSI
   if(InpUseRSI)
      g_rsi_val = iRSI(Symbol(), PERIOD_CURRENT, InpRSIPeriod, PRICE_CLOSE, 1);

   //--- Bollinger Bands
   if(InpUseBands)
   {
      g_bands_upper = iBands(Symbol(), PERIOD_CURRENT, InpBandsPeriod, InpBandsDeviation, 0, PRICE_CLOSE, MODE_UPPER, 1);
      g_bands_lower = iBands(Symbol(), PERIOD_CURRENT, InpBandsPeriod, InpBandsDeviation, 0, PRICE_CLOSE, MODE_LOWER, 1);
      g_bands_mid   = iBands(Symbol(), PERIOD_CURRENT, InpBandsPeriod, InpBandsDeviation, 0, PRICE_CLOSE, MODE_MAIN,  1);
   }

   //--- ATR
   if(InpUseATR)
      g_atr_val = iATR(Symbol(), PERIOD_CURRENT, InpATRPeriod, 1);

   //--- Spread snapshot
   g_spread_points = MarketInfo(Symbol(), MODE_SPREAD) * g_point;
}

//+==================================================================+
//||  SECTION 8 — TRADING ENGINE                                    ||
//||  MQL5 CTrade → MQL4 OrderSend/OrderModify/OrderClose           ||
//||                                                                 ||
//||  MQL5 (OLD):                                                    ||
//||    CTrade trade;                                                ||
//||    trade.Buy(lots, _Symbol, ask, sl, tp, "comment");           ||
//||                                                                 ||
//||  MQL4 (NEW):  OrderSend() — see ExecuteTrade() below           ||
//+==================================================================+

void ExecuteTrade(int order_type)
{
   double sl_distance = InpStopLoss_Pts * g_point;
   double ask         = MarketInfo(Symbol(), MODE_ASK);
   double bid         = MarketInfo(Symbol(), MODE_BID);

   double entry_price, stop_loss;

   if(order_type == OP_BUY)
   {
      entry_price = ask;
      stop_loss   = NormalizeDouble(ask - sl_distance, g_digits);
   }
   else
   {
      entry_price = bid;
      stop_loss   = NormalizeDouble(bid + sl_distance, g_digits);
   }

   //--- Send with full retry logic for errors 146 & 135
   int ticket = SendOrderWithRetry(order_type, entry_price, stop_loss);

   if(ticket > 0)
   {
      g_last_trade_time = TimeCurrent();
      g_consecutive_fails = 0;
      if(order_type == OP_BUY)  g_buy_ticket  = ticket;
      else                       g_sell_ticket = ticket;

      Print("TRADE OPENED | ", (order_type==OP_BUY?"BUY":"SELL"),
            " | Ticket=", ticket,
            " | Entry=",  entry_price,
            " | SL=",     stop_loss);
   }
   else
   {
      g_consecutive_fails++;
      Print("TRADE FAILED after ", InpMaxRetries, " retries | ConsecFails=", g_consecutive_fails);
   }
}

//--- Retry wrapper — handles Error 146 (Trade Context Busy)
//    and Error 135 (Off Quotes / price moved)
int SendOrderWithRetry(int order_type, double price, double sl)
{
   int ticket = -1;

   for(int attempt = 0; attempt < InpMaxRetries; attempt++)
   {
      //--- Refresh price on each attempt (critical for error 135)
      if(order_type == OP_BUY)
         price = NormalizeDouble(MarketInfo(Symbol(), MODE_ASK), g_digits);
      else
         price = NormalizeDouble(MarketInfo(Symbol(), MODE_BID), g_digits);

      //--- Recalculate SL with fresh price
      if(order_type == OP_BUY)
         sl = NormalizeDouble(price - InpStopLoss_Pts * g_point, g_digits);
      else
         sl = NormalizeDouble(price + InpStopLoss_Pts * g_point, g_digits);

      ticket = OrderSend(
         Symbol(),
         order_type,
         InpLotSize,
         price,
         30,             // slippage — 3 pips on Gold
         sl,
         0,
         "TickPulseScalper",
         InpMagicNumber,
         0,
         order_type == OP_BUY ? clrDodgerBlue : clrOrangeRed
      );

      if(ticket > 0) break;  // success

      int err = GetLastError();

      //--- Error 146: Trade context is busy (another EA or manual trade in progress)
      //    Solution: wait and retry
      if(err == 146)
      {
         g_error146_retries++;
         Print("ERR 146 Trade Context Busy — retry ", attempt+1, "/", InpMaxRetries);
         Sleep(InpRetryDelayMs);
         continue;
      }

      //--- Error 135: Off quotes / stale price
      //    Solution: immediately refresh price (done at top of loop) and retry
      if(err == 135)
      {
         Print("ERR 135 Off Quotes — refreshing price, retry ", attempt+1, "/", InpMaxRetries);
         RefreshRates();
         Sleep(50);
         continue;
      }

      //--- Error 130: Invalid stops — SL/TP too close to market
      if(err == 130)
      {
         Print("ERR 130 Invalid Stops — SL too close, skipping");
         break;
      }

      //--- Any other error — log and abort
      Print("OrderSend ERR ", err, " | attempt=", attempt+1, " | price=", price, " | sl=", sl);
      break;
   }

   return ticket;
}

//+==================================================================+
//||  SECTION 9 — TIGHT-TRACE TRAILING STOP                        ||
//||  Moves every InpTrailStep points (1-2 pts for XAUUSD HF)      ||
//||  Runs on EVERY tick — must be < 1ms execution time            ||
//+==================================================================+
void TightTraceTrail()
{
   double trail_activate = InpTrailActivate * g_point;
   double trail_step     = InpTrailStep     * g_point;
   double trail_lock     = InpTrailLock     * g_point;

   double ask = MarketInfo(Symbol(), MODE_ASK);
   double bid = MarketInfo(Symbol(), MODE_BID);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()      != Symbol())        continue;
      if(OrderMagicNumber() != InpMagicNumber)  continue;

      int    ticket     = OrderTicket();
      int    otype      = OrderType();
      double open_price = OrderOpenPrice();
      double current_sl = OrderStopLoss();
      double current_tp = OrderTakeProfit();

      //--- ── BUY trail ──────────────────────────────────────────────
      if(otype == OP_BUY)
      {
         double profit = bid - open_price;
         if(profit < trail_activate) continue;

         //--- New SL = bid minus one step
         double new_sl = NormalizeDouble(bid - trail_step, g_digits);

         //--- Never let trail fall below entry + lock floor
         double floor_sl = NormalizeDouble(open_price + trail_lock, g_digits);
         if(new_sl < floor_sl) new_sl = floor_sl;

         //--- Only modify if it improves by at least one step
         if(new_sl <= current_sl) continue;

         ModifyOrderWithRetry(ticket, open_price, new_sl, current_tp);
      }

      //--- ── SELL trail ─────────────────────────────────────────────
      else if(otype == OP_SELL)
      {
         double profit = open_price - ask;
         if(profit < trail_activate) continue;

         double new_sl = NormalizeDouble(ask + trail_step, g_digits);

         //--- Floor: never let SL rise above entry - lock floor
         double floor_sl = NormalizeDouble(open_price - trail_lock, g_digits);
         if(new_sl > floor_sl) new_sl = floor_sl;

         //--- Only modify if it improves (moves down for sells)
         if(current_sl > 0 && new_sl >= current_sl) continue;

         ModifyOrderWithRetry(ticket, open_price, new_sl, current_tp);
      }
   }
}

//--- OrderModify with error 146 retry
bool ModifyOrderWithRetry(int ticket, double open_price, double new_sl, double tp)
{
   for(int attempt = 0; attempt < InpMaxRetries; attempt++)
   {
      if(OrderModify(ticket, open_price, new_sl, tp, 0))
         return true;

      int err = GetLastError();

      if(err == 146)
      {
         Sleep(InpRetryDelayMs);
         continue;
      }
      if(err == 1)   // no change needed — SL already at that level
         return true;

      Print("OrderModify ERR ", err, " | ticket=", ticket, " | new_sl=", new_sl);
      break;
   }
   return false;
}

//+==================================================================+
//||  SECTION 10 — TICK RING BUFFER                                 ||
//||  Fixed pre-allocated array — no dynamic resize in OnTick.      ||
//||  Use for velocity / momentum calculations if needed.           ||
//+==================================================================+
void PushTickToRing()
{
   g_bid_ring [g_ring_pos] = MarketInfo(Symbol(), MODE_BID);
   g_ask_ring [g_ring_pos] = MarketInfo(Symbol(), MODE_ASK);
   g_tick_time[g_ring_pos] = TimeCurrent();

   g_ring_pos = (g_ring_pos + 1) % TICK_BUFFER_SIZE; // wrap-around
}

//--- Read last N bids from ring (for velocity calc)
//    Returns average price change per tick over last N ticks
double GetTickVelocity(int n_ticks)
{
   if(n_ticks < 2) return 0.0;
   int cap = MathMin(n_ticks, TICK_BUFFER_SIZE - 1);

   int newest = (g_ring_pos - 1 + TICK_BUFFER_SIZE) % TICK_BUFFER_SIZE;
   int oldest = (g_ring_pos - cap + TICK_BUFFER_SIZE) % TICK_BUFFER_SIZE;

   double delta = g_bid_ring[newest] - g_bid_ring[oldest];
   return delta / cap;  // points per tick
}

//+==================================================================+
//||  SECTION 11 — UTILITY FUNCTIONS                                ||
//+==================================================================+

bool IsNewBar()
{
   datetime t = iTime(Symbol(), PERIOD_CURRENT, 0);
   if(t != g_last_bar_time)
   {
      g_last_bar_time = t;
      return true;
   }
   return false;
}

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

int CountOpenOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()      != Symbol())        continue;
      if(OrderMagicNumber() != InpMagicNumber)  continue;
      if(OrderType() <= OP_SELL)                count++;
   }
   return count;
}

bool IsTradingAllowed()
{
   //--- Hard cap
   if(CountOpenOrders() >= InpMaxOpenTrades) return false;

   //--- Spread guard
   double spread = MarketInfo(Symbol(), MODE_SPREAD) * g_point;
   if(InpMaxSpread > 0 && spread > InpMaxSpread * g_point) return false;
   if(InpMinSpread > 0 && spread < InpMinSpread * g_point) return false;

   //--- Cooldown between trades
   if(TimeCurrent() - g_last_trade_time < InpCooldownSecs) return false;

   //--- Broker allows trading
   if(!IsTradeAllowed()) return false;

   return true;
}

//+==================================================================+
//||  SECTION 12 — MQL5→MQL4 CONVERSION CHEAT SHEET               ||
//||  (comments only — reference when porting your 13,000 lines)   ||
//+==================================================================+
//
//  ┌─────────────────────────────────────────────────────────────┐
//  │  TRADING ENGINE                                             │
//  ├──────────────────────────┬──────────────────────────────────┤
//  │  MQL5                    │  MQL4                            │
//  ├──────────────────────────┼──────────────────────────────────┤
//  │  CTrade.Buy(...)         │  OrderSend(..., OP_BUY, ...)     │
//  │  CTrade.Sell(...)        │  OrderSend(..., OP_SELL, ...)    │
//  │  CTrade.PositionClose()  │  OrderClose(ticket,lots,price,slip)│
//  │  CTrade.PositionModify() │  OrderModify(ticket,...)         │
//  │  PositionGetDouble(...)  │  OrderOpenPrice(), OrderSL()...  │
//  │  PositionGetInteger(...) │  OrderType(), OrderTicket()...   │
//  │  PositionsTotal()        │  OrdersTotal()                   │
//  │  PositionGetTicket(i)    │  OrderSelect(i,SELECT_BY_POS,...)│
//  ├──────────────────────────┼──────────────────────────────────┤
//  │  INDICATORS                                                 │
//  ├──────────────────────────┬──────────────────────────────────┤
//  │  MQL5 (handle system)    │  MQL4 (direct call)              │
//  ├──────────────────────────┼──────────────────────────────────┤
//  │  int h=iRSI(...)         │  (no handle needed)              │
//  │  CopyBuffer(h,0,1,1,buf) │  iRSI(sym,tf,period,price,shift) │
//  │  int h=iBands(...)       │  iBands(sym,tf,p,dev,0,pr,mode,shift)│
//  │  int h=iATR(...)         │  iATR(sym, tf, period, shift)    │
//  │  int h=iMA(...)          │  iMA(sym, tf, period, shift, method, price, shift)│
//  │  int h=iCustom(...)      │  iCustom(sym, tf, "name", p1, p2, buf, shift)│
//  │  IndicatorRelease(h)     │  (not needed in MQL4)            │
//  ├──────────────────────────┼──────────────────────────────────┤
//  │  PRICE / SYMBOL INFO                                        │
//  ├──────────────────────────┬──────────────────────────────────┤
//  │  SymbolInfoDouble(sym, SYMBOL_ASK)  │  MarketInfo(sym, MODE_ASK)  │
//  │  SymbolInfoDouble(sym, SYMBOL_BID)  │  MarketInfo(sym, MODE_BID)  │
//  │  SymbolInfoDouble(sym, SYMBOL_POINT)│  MarketInfo(sym, MODE_POINT)│
//  │  SymbolInfoInteger(sym, SYMBOL_DIGITS)│ MarketInfo(sym, MODE_DIGITS)│
//  │  SymbolInfoDouble(sym, SYMBOL_SPREAD)│ MarketInfo(sym, MODE_SPREAD)│
//  ├──────────────────────────┼──────────────────────────────────┤
//  │  DATA TYPES / MISC                                          │
//  ├──────────────────────────┬──────────────────────────────────┤
//  │  input  double Foo=1.0;  │  extern double Foo=1.0;          │
//  │  OnTimer()               │  EventSetTimer(n); OnTimer()     │
//  │  ChartGetInteger(...)    │  WindowHandle() / WindowFind()   │
//  │  ENUM_POSITION_TYPE      │  int (OP_BUY=0, OP_SELL=1)      │
//  │  ulong ticket            │  int  ticket                     │
//  │  string(EnumToString())  │  manual string map               │
//  └──────────────────────────┴──────────────────────────────────┘
//
//  MEMORY RULES FOR 32-BIT MT4:
//  ─────────────────────────────
//  1. Stack limit ≈ 1MB.  Declare large arrays at FILE SCOPE (global),
//     never inside a function.
//  2. ArrayResize() is safe at file scope (heap), deadly in OnTick().
//  3. Each double = 8 bytes.  10,000-element array = 80KB.
//     A 13,000-line EA with 20 such arrays = 1.6MB → stack overflow.
//  4. Use #define constants for buffer sizes instead of dynamic sizing.
//  5. Split logic into multiple .mqh include files to improve compiler
//     performance:
//       #include "TickPulse_Indicators.mqh"
//       #include "TickPulse_TradeEngine.mqh"
//       #include "TickPulse_RiskManager.mqh"
//  6. Avoid string concatenation inside OnTick() — use integer codes
//     and only format strings for Print() calls.
//
//+------------------------------------------------------------------+
