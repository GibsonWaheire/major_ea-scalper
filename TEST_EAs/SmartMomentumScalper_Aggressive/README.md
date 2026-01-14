# SmartMomentumScalper_Aggressive

SmartMomentumScalper_Aggressive is a clean, single-trade MT4 scalper designed for aggressive momentum entries with professional risk controls.

## Key Features
- **Single trade at a time** – no martingale, grid, or stacking.
- **Momentum entry stack** – EMA(5/21), RSI(7), candle body threshold, tick-acceleration, ATR volatility guard, spread filter, and direction validation.
- **Smart Exit Engine** – ATR-based SL/TP, 4-bar time exit, profit-decay watchdog, reversal/volatility/spread spike exits, and emergency fail-safes.
- **Partial Close** – automatically closes 30% @ 50% TP and shifts SL to breakeven+buffer.
- **Risk-based sizing** – 1.5% default risk with broker min/max/step handling.
- **Session controls** – trades only 02:00–11:00 UTC, skips rollover, caps at 40 trades/day.
- **Display module** – shows trend, ATR, spread, momentum state, profit decay, trade status, and session state.

## Files
- `SmartMomentumScalper_Aggressive.mq4` – Expert Advisor source
- `README.md` – this overview

## Usage
1. Copy both files into your MT4 `MQL4/Experts/SmartMomentumScalper_Aggressive/` folder.
2. Compile with MetaEditor (F7).
3. Attach to an M1 chart of the instrument you want to trade.
4. Adjust inputs (session hours, risk%, ATR caps, etc.) to match your broker.
5. Enable AutoTrading and monitor the on-chart panel for status.

> **Note:** This EA is aggressive. Always forward-test on demo first and confirm broker slippage/lot rules before going live.
