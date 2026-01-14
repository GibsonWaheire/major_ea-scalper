# HyperTick HF Scalper V1.0

## Overview
Pure HFT (High Frequency Trading) VPS EA designed for ultra-fast tick-based scalping. This EA operates without any indicators (no EMA, no RSI) and uses pure tick momentum and speed analysis for entry signals.

## Target Account Range
- **Starting Range**: $50 - $500
- **Target Growth**: Safely grow to $10,000
- **Risk Management**: Strict safety limits prevent account blowout

## Key Features

### Pure HFT Architecture
- **No Lag**: Zero indicator calculations
- **No EMA/RSI**: Pure tick-based analysis
- **Ultra-Fast Execution**: Tick-based entry/exit logic
- **VPS Optimized**: Designed for low-latency VPS environments

### Entry System
- **Momentum Flip Detection**: Enters only when momentum sharply flips direction
- **Micro Pullback + Continuation**: Requires both pullback and momentum continuation
- **Tick Momentum + Tick Speed**: Uses both tick momentum and tick speed for validation
- **Dual Entry Modes**: 
  - Momentum Entry (UseMomentumEntry)
  - Pullback Entry (UsePullbackEntry)
- **Additional Trades**: Opens 1-3 additional small trades (0.02-0.04 lots) after initial entry

### Exit System
- **Strict Profit Target**: Closes trades ONLY when profit > spread + 1 point
- **Maximum Hold Time**: 3-5 seconds (configurable via MaxHoldSeconds)
- **Basket Breakeven**: Closes all trades when basket reaches breakeven or small profit
- **No Loss Closing**: Never closes trades at a loss unless recovery mode activates

### Recovery Mode
- **Automatic Activation**: Activates when losing trade stays open too long (3-5 seconds)
- **Limited Recovery**: Maximum 1-3 recovery trades (configurable)
- **Drawdown Protection**: Stops recovery if DD > 20-25%
- **Small Lot Recovery**: Uses smaller lot sizes (0.02-0.04) for recovery trades
- **NO Martingale**: Does NOT aggressively increase lot sizes

### Safety Features
- **Spread Protection**: Stops EA if spread spikes above limit
- **Tick Speed Protection**: Stops EA if tick speed drops below minimum
- **Drawdown Limits**: Stops recovery mode if drawdown exceeds 20-25%
- **Account Protection**: EA designed to NEVER let account blow
- **Fixed Lot Sizing**: Uses fixed lot sizes (0.05-0.07) - NO aggressive lot increases

## Input Parameters

### Core Trading Settings
- **MagicNumber**: Unique identifier for EA trades (default: 202501)
- **LotSize**: Fixed lot size (0.05-0.07 recommended)
- **MaxHoldSeconds**: Maximum hold time in seconds (3-5 recommended)
- **UseMomentumEntry**: Enable momentum-based entry
- **UsePullbackEntry**: Enable pullback-based entry

### Tick Speed & Spread Limits
- **TickSpeedLimit**: Minimum ticks per second (EA stops if below this)
- **SpreadLimit**: Maximum spread in pips (EA stops if above this)

### Recovery Mode Settings
- **RecoveryEnabled**: Enable/disable recovery mode
- **MaxRecoveryTrades**: Maximum recovery trades (1-3 recommended)
- **MaxRecoveryDD**: Maximum drawdown % before stopping recovery (20-25% recommended)

### Entry Settings
- **AdditionalTrades**: Number of additional small trades to open (1-3)
- **RecoveryLotSize**: Lot size for recovery trades (0.02-0.04)

### Exit Settings
- **MinProfitPoints**: Minimum profit points above spread (default: 1.0)
- **BreakevenProfitUSD**: Close basket at breakeven or small profit ($)

## Trading Logic

### Entry Conditions
1. **Momentum Flip**: Sharp reversal in tick direction detected
2. **Pullback Continuation**: Micro pullback followed by continuation (if UsePullbackEntry enabled)
3. **Tick Speed**: Validated against minimum tick speed
4. **Spread**: Validated against maximum spread

### Exit Conditions
1. **Profit Target**: Profit > spread + MinProfitPoints
2. **Maximum Hold**: Trade held for MaxHoldSeconds
3. **Basket Breakeven**: Total basket profit >= BreakevenProfitUSD

### Recovery Mode Logic
1. **Trigger**: Losing trade held open for MaxHoldSeconds
2. **Action**: Opens opposite direction trade with smaller lot size
3. **Limit**: Maximum MaxRecoveryTrades recovery trades
4. **Stop**: If drawdown exceeds MaxRecoveryDD, recovery stops

## Safety Mechanisms

### EA Stop Conditions
- **Spread Spike**: If spread exceeds SpreadLimit, EA stops trading
- **Tick Speed Drop**: If tick speed drops below TickSpeedLimit, EA stops trading
- **Auto Resume**: EA automatically resumes when conditions normalize

### Recovery Stop Conditions
- **Drawdown Limit**: Recovery stops if drawdown exceeds MaxRecoveryDD
- **Trade Limit**: Recovery stops after MaxRecoveryTrades added

### Account Protection
- **Fixed Lot Sizes**: No aggressive lot size increases
- **No Martingale**: Recovery uses smaller lots, not larger
- **Strict Profit Targets**: Only closes when profit exceeds spread + points
- **Basket Management**: Closes entire basket at breakeven/profit

## Recommended Settings

### For $50-$100 Accounts
- LotSize: 0.05
- RecoveryLotSize: 0.02
- MaxRecoveryTrades: 1
- MaxRecoveryDD: 20%

### For $100-$500 Accounts
- LotSize: 0.06
- RecoveryLotSize: 0.03
- MaxRecoveryTrades: 2
- MaxRecoveryDD: 22%

### For $500+ Accounts
- LotSize: 0.07
- RecoveryLotSize: 0.04
- MaxRecoveryTrades: 3
- MaxRecoveryDD: 25%

## Installation
1. Copy `HyperTickHF_Scalper_V1_0.mq5` to `MQL5/Experts/`
2. Compile in MetaEditor
3. Attach to chart (M1 timeframe recommended)
4. Configure input parameters
5. Enable AutoTrading

## Requirements
- **Platform**: MetaTrader 5
- **Timeframe**: M1 (recommended) or any tick-based timeframe
- **Symbol**: Any liquid symbol (XAUUSD recommended for HFT)
- **VPS**: Low-latency VPS recommended for optimal performance
- **Broker**: ECN/STP broker with tight spreads

## Risk Warning
This EA is designed for high-frequency trading and requires:
- Low-latency VPS connection
- Tight spreads (preferably under 3 pips)
- High tick speed (preferably >0.5 ticks/second)
- Sufficient account balance to handle drawdowns

**Always test on demo account first before live trading.**

## Version History
- **V1.0** (2025-01-XX): Initial release
  - Pure tick-based HFT scalping
  - Momentum flip + pullback entry system
  - Recovery mode with safety limits
  - Spread and tick speed protection

## Support
For issues or questions, please refer to the EA code comments or contact support.
