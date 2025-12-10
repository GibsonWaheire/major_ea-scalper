# Burst Rest Scalper

## Overview
Ultra-fast scalping EA that operates in distinct phases: rest, analysis, trading burst, pause, and profit closing.

## Strategy Flow

1. **REST Phase (1-2 minutes)**
   - EA rests and does not take trades
   - Prepares for next trading cycle

2. **ANALYSIS Phase (during rest)**
   - Analyzes market conditions using EMA, RSI, ATR, and price action
   - Determines trading direction (Buy/Sell)
   - Selects optimal order type:
     - **Market Orders**: OP_BUY, OP_SELL (immediate execution)
     - **Limit Orders**: OP_BUYLIMIT, OP_SELLLIMIT (entry at better price)
     - **Stop Orders**: OP_BUYSTOP, OP_SELLSTOP (breakout entries)

3. **TRADING Phase (1 minute)**
   - Takes as many trades as possible based on analysis
   - Maximum trades per burst configurable
   - Uses determined order type from analysis
   - Ultra-fast execution

4. **PAUSE Phase (30 seconds)**
   - Brief pause after trading burst
   - Allows market to settle

5. **CLOSE Phase**
   - Closes profitable trades
   - Lets some profitable trades run if they exceed threshold
   - Returns to REST phase after closing

## Key Features

- **Super Fast Execution**: Closes trades immediately when quick profit target is hit
- **Rest Periods**: 1-2 minute rest periods between trading bursts
- **Market Analysis**: Multi-factor analysis during rest to determine direction
- **Multiple Order Types**: Supports market, limit, and stop orders
- **Profit Management**: 
  - Quick profit closing (configurable pips)
  - Let profitable trades run if they exceed threshold
  - Maximum hold time protection

## Input Parameters

### Risk & Lot Sizing
- `RiskPercentPerTrade`: Risk percentage per trade (default: 1.0%)
- `MinLotSize`: Minimum lot size (default: 0.01)
- `MaxLotSize`: Maximum lot size (default: 10.0)

### Timing
- `RestPeriodMin`: Minimum rest period in seconds (default: 60)
- `RestPeriodMax`: Maximum rest period in seconds (default: 120)
- `TradingBurstDuration`: Trading burst duration in seconds (default: 60)
- `PauseAfterBurst`: Pause after trading burst in seconds (default: 30)

### Trading Settings
- `MaxTradesPerBurst`: Maximum trades per burst (default: 50)
- `TradesPerTick`: Trades per tick for speed (default: 1)
- `MaxSpreadPips`: Maximum spread in pips (default: 10.0)

### Order Type Selection
- `UseMarketOrders`: Enable market orders (Buy/Sell) (default: true)
- `UseLimitOrders`: Enable limit orders (Buy Limit/Sell Limit) (default: true)
- `UseStopOrders`: Enable stop orders (Buy Stop/Sell Stop) (default: true)
- `LimitOffsetPips`: Limit order offset from current price (default: 2.0)
- `StopOffsetPips`: Stop order offset from current price (default: 2.0)

### Profit Management
- `QuickProfitPips`: Quick profit target in pips - closes immediately (default: 1.0)
- `LetRunProfitPips`: Let trades run if profit exceeds this (default: 5.0)
- `MaxHoldSeconds`: Maximum hold time for running trades (default: 300)
- `CloseAllOnProfit`: Close all profitable trades after burst (default: false)

### Market Analysis
- `Analysis_EMA_Fast`: Fast EMA period (default: 5)
- `Analysis_EMA_Slow`: Slow EMA period (default: 15)
- `Analysis_RSI_Period`: RSI period (default: 14)
- `Analysis_ATR_Period`: ATR period (default: 14)

## How It Works

### Market Analysis Logic

The EA uses a scoring system during the ANALYSIS phase:

1. **Trend Analysis**: EMA crossover and price position relative to EMAs
2. **Momentum Analysis**: RSI levels and momentum strength
3. **Price Action**: Recent candle patterns and price movement
4. **Volatility**: ATR-based volatility confirmation

Based on the analysis score, the EA determines:
- **Direction**: Buy (score > sell score) or Sell (score > buy score)
- **Order Type**: 
  - Market orders for immediate execution when momentum is strong
  - Limit orders when price is expected to retrace
  - Stop orders for breakout scenarios

### Trading Execution

During the TRADING phase:
- EA takes trades as fast as possible (up to MaxTradesPerBurst)
- Uses the order type determined during analysis
- Each trade is tracked individually

### Profit Management

- **Quick Profits**: Trades are closed immediately when they reach QuickProfitPips (super fast closing)
- **Let Run**: Trades exceeding LetRunProfitPips are allowed to run for larger profits
- **Max Hold**: All trades are closed after MaxHoldSeconds to prevent over-holding
- **Close Phase**: After trading burst, EA closes profitable trades but lets strong runners continue

## Usage Tips

1. **Start Conservative**: Begin with low RiskPercentPerTrade (0.5-1.0%)
2. **Adjust Rest Periods**: Longer rest periods = more analysis time but fewer trading opportunities
3. **Order Type Selection**: Enable all order types for maximum flexibility
4. **Quick Profit Target**: Set QuickProfitPips based on your broker's spread (typically 1-3 pips)
5. **Let Run Threshold**: Set LetRunProfitPips higher than QuickProfitPips to let winners run

## Risk Warning

This EA is designed for ultra-fast scalping with high trade frequency. It:
- Does not use stop loss (relies on quick profit closing)
- Takes many trades in short bursts
- Requires low latency and good broker execution
- May not be suitable for all market conditions

**Always test on a demo account first!**

## Notes

- The EA automatically cycles through phases
- Analysis happens during rest period
- Trading burst is limited to 1 minute to prevent over-trading
- Profitable trades can be let run if they exceed threshold
- All trades are tracked and managed individually

















