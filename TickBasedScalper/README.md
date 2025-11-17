# Tick-Based Machine-Gun Scalper EA

Ultra-fast tick-based trading EA designed for instant entries/exits with basket profit closure - matching the "machine-gun" trading pattern.

## Key Differences from MeanReversionScalper

| Feature | MeanReversionScalper | TickBasedScalper |
|---------|---------------------|------------------|
| **Entry Logic** | Candle-based (waits for M1/M5 close) | Tick-based (every price change) |
| **Indicators** | Uses RSI, MA, StdDev | No indicators - pure price movement |
| **Speed** | Waits for candle confirmation | Instant on every tick |
| **Filters** | Session, News, Cooldown | Minimal - only spread check |
| **Entry Method** | Mean reversion signals | Micro price movement / Random / Spread-based |
| **Execution** | Standard | Ultra-fast, minimal delays |

## Features

### Tick-Based Entry Methods

1. **Micro Price Movement (Default)**
   - Opens trades when price moves X **points** from the last tick
   - Direction based on price movement direction (or preferred direction)
   - Locks the basket to a single direction until it closes

2. **Random Direction**
   - Chooses a direction per cycle (respecting preferred direction)
   - Useful for fast testing without directional bias

3. **Spread-Based**
   - Opens when spread is tight (half of max)
   - Takes advantage of low spread conditions

### Basket Take-Profit (Primary Mode)

- **Instant Closure**: Closes ALL trades immediately when basket profit reaches target ($1-$5 default)
- **No Traditional TP/SL**: Uses basket-wide profit, not individual trade TP/SL
- **Continuous Cycle**: Immediately starts new basket after closure
- **Time Limit**: Optional (usually disabled for maximum speed)

### Position Sizing

- **Grid Step (Default)**: Increases lot size per additional trade in same direction
- **Martingale**: Multiplies lot after losing basket
- **Risk-Based**: Calculates lot based on risk percentage
- **Equity Scale**: Scales with account equity
- **Fixed**: Uses fixed lot size

### Ultra-Fast Execution

- **No Delays**: Minimal retry delays (50ms default)
- **No Cooldowns**: Continuous trading
- **No Session Filters**: Trades 24/7
- **No News Filters**: No calendar integration
- **Minimal Spread Check**: Only basic spread validation

## Input Parameters

### Trading Mode
- `TradingMode`: 0 = Basket TP (recommended), 1 = Per-Trade TP

### Tick Entry Logic
- `EntryMethod`: 0 = Micro movement, 1 = Random, 2 = Spread-based
- `PreferredDirection`: 0 = Auto, 1 = Buy only, -1 = Sell only (default: 1)
- `MicroMovementPoints`: Minimum price movement to trigger entry (default: 1 point)
- `MaxConcurrentTrades`: Maximum trades per symbol (default: 10)
- `AllowOppositeDirection`: Allow switching direction while a basket is open (default: false)
- `MaxStagnantTicks`: Force entry after this many ticks without movement (default: 5)
- `EnableDebugLogs`: Print spread and entry diagnostics to the Journal (default: true)

### Position Sizing
- `LotSizingMode`: 0=Fixed, 1=Risk%, 2=Martingale, 3=GridStep (default), 4=EquityScale
- `BaseLot`: Base lot size (default: 0.01)
- `GridLotStep`: Increment per extra trade (default: 0.01)

### Basket Take-Profit
- `BasketProfitFixed`: Close all trades at this profit in $ (default: $1.00)
- `BasketProfitPercent`: OR % of balance (0 = use fixed)
- `BasketTimeLimitSeconds`: Max seconds per basket (default: 30, usually disabled)

### Risk Management
- `MaxDrawdownPercent`: Maximum equity drawdown % (default: 30%)
- `MaxSpreadPoints`: Max spread filter in points (default: 45.0 for gold-style pricing)

## Usage

1. **Attach to M1 chart** (or any timeframe - it's tick-based)
2. **Set Entry Method**:
   - Method 0: Adjust `MicroMovementPoints` (smaller = more trades)
   - Method 1: Pure random direction (still respects preferred direction)
   - Method 2: Uses spread conditions
3. **Set Basket Target**: `BasketProfitFixed` = $1-$5 for fast cycles
4. **Set Lot Sizing**: `LotSizingMode = 3` (GridStep) recommended
5. **Disable Time Limit**: Set `UseBasketTimeLimit = false` for continuous trading

## Behavior

### Typical Cycle

1. **Tick arrives** → Price moves X pips → **Opens trade(s)**
2. **More ticks** → Opens more trades (GridStep increases lot size)
3. **Basket profit reaches $1** → **INSTANTLY closes ALL trades**
4. **Immediately starts new cycle** → Opens new trades

### Speed Characteristics

- **Entry**: Every tick (milliseconds)
- **Exit**: Instant when basket profit target hit
- **No waiting**: No candle closes, no signal confirmations
- **Continuous**: Cycles repeat non-stop

## Warnings

⚠️ **High Frequency Trading**: This EA trades very frequently
⚠️ **Spread Costs**: Many small trades = cumulative spread costs
⚠️ **Broker Requirements**: Needs low-latency broker/VPS
⚠️ **Risk**: Can generate many trades quickly - monitor closely

## Recommended Settings

For "machine-gun" behavior:
- `EntryMethod = 0` (Micro movement)
- `MicroMovementPoints = 1.0`
- `PreferredDirection = 1` for BUY cycles or `-1` for SELL cycles (keeps direction consistent)
- `BasketProfitFixed = 1.0` ($1 target)
- `LotSizingMode = 3` (GridStep)
- `GridLotStep = 0.01`
- `MaxConcurrentTrades = 10`
- `UseBasketTimeLimit = false`
- `MaxSpreadPoints = 45.0`
- `MaxStagnantTicks = 5`

## Version

v2.10 - Direction-locked tick-based release with point-based controls

