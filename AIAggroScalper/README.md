# AIAggroScalper EA

An ultra-aggressive, tick-driven Expert Advisor engineered to grow micro accounts rapidly. This build intentionally ignores spread filters, relies on AI-inspired pulse logic, and automatically compounds profits via high-frequency bursts. **Use at your own risk – this EA is extremely speculative.**

## Highlights

- Pulse engine that fires bursts of trades whenever idle ticks accumulate or AI heuristics signal opportunity.
- Synthetic reinforcement learning heuristics track reward history and bias direction selection dynamically.
- Cycle manager handles multiple active bursts, each with its own state (prepare, fire, monitor, exit, failsafe).
- Equity ledger and risk modules implement hard/soft stops, equity locks, trailing equity guards, and macro profit tracking.
- Trailing stop matrix automatically activates once trades reach predefined profit triggers.
- Massive 2,500+ line source file packed with documentation, expansion slots, and AI archive notes.

## Key Inputs

### Master Switches
- `EAEnabled`: Global enable.
- `AllowMultiSymbol`: Future expansion for multi-symbol execution (currently single symbol).
- `AllowHedge`: Permit BUY and SELL simultaneously.
- `OperationProfile`: 0=AI Pulse (default), 1=Momentum, 2=Reversion, 3=Hybrid.
- `MaxParallelCycles`: Number of concurrent bursts.

### Capital & Lot Sizing
- `BaseLotSize`: Initial micro lot.
- `LotGrowthRate`: Lot multiplier per trade within a cycle.
- `MaxLotPerCycle`: Hard cap per trade.
- `EquityRiskPerCyclePercent`: Risk allocation per burst.
- `EquityLockPercent`: Auto lock-in threshold.
- `AdaptiveDeleveragePercent`: Aggressive lot reduction after drawdown.

### Profit Targets & Trailing
- `MicroProfitUSD`: Basket close trigger.
- `MacroSessionTargetUSD`: Aspirational session goal.
- `MinTradesPerBurst` / `MaxTradesPerBurst`: Burst size range.
- `PerTradeTPPoints`, `PerTradeSLPoints`: Per-order TP/SL (points).
- `EnableAutoTrailing`, `TrailingActivationPoints`, `TrailingStepPoints`: Trailing matrix controls.

### Pulse Timing
- `MinTicksBetweenBursts` / `MaxTicksBetweenBursts`: Idle window before firing or forcing exit.
- `PulseCooldownMillis`: Delay between orders within a burst.
- `MaxIdleTicksBeforeForce`: Force-shot after prolonged stagnation.
- `MaxStagnantTicksAI`: Force-shot after AI stagnation counter hits threshold.

### Synthetic AI
- `EnableSyntheticAI`: Toggle heuristics.
- `AIWindowTicks`, `AIRewardLookback`: Reward averaging windows.
- `AIAggressionWeight`, `AIRiskPenaltyWeight`, `AIVolatilityPenaltyWeight`, `AISpreadPenaltyWeight`, `AIPatternMemoryWeight`: Weighting factors.

### Safety Systems
- `HardStopLossPercent`, `SoftStopLossPercent`: Equity-based stops.
- `MaxSequentialLossCycles`: Pause after consecutive losses.
- `CloseAllOnEquityDrop`: Emergency exit toggle.
- `EnableEquityTrailingLock`, `EquityLockStepPercent`: Equity trailing guard.

### Diagnostics
- `EnableConsoleLog`, `EnableVerboseJournal`: Logging controls.
- `ConsoleThrottleMilliseconds`: Console rate limit.
- `DumpStateOnDeinit`: Dump session summary on exit.

## Usage Tips

1. Attach to a high-volatility symbol (e.g., XAUUSD) on M1 or tick chart.
2. Set broker leverage high; ensure margin can handle frequent bursts.
3. Start with small lot sizes; the EA self-scales aggressively.
4. Monitor `Macro Profit` and equity panel; use on VPS for minimal latency.
5. Understand that the EA **does not** filter spread – it will trade in all conditions.

## Disclaimer

This EA is intentionally extreme and may blow accounts rapidly. It is provided for educational and experimental purposes only. Hyper Scalper Labs and contributors bear no responsibility for financial losses.

