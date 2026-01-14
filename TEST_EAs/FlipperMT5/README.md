# FlipperMT5 - High-Leverage Flipper EA

## Overview

FlipperMT5 is an extreme capital amplification EA designed for high-leverage trading. This EA focuses on maximum margin utilization with dynamic lot sizing, momentum decay entry signals, and dollar-based profit targets.

**⚠️ WARNING: This EA uses full margin and is designed for high-risk, high-reward trading. Use only with capital you can afford to lose.**

## Core Strategy

The EA operates on three core modules:

### Module 1: Dynamic Full-Margin Lot Sizing
- **No fixed lot sizes** - Calculates maximum volume based on available margin
- Uses `OrderCalcMargin()` to determine maximum position size
- Applies safety buffers (MarginUsage × RiskMultiplier) to prevent order rejection
- Respects broker limits (SYMBOL_VOLUME_MIN, SYMBOL_VOLUME_MAX, SYMBOL_VOLUME_STEP)

### Module 2: Momentum Decay Entry
- Uses **iMomentum (14-period)** on **M1 timeframe**
- Detects "velocity spikes" with momentum exhaustion:
  - **SELL Signal**: Price spiking UP but momentum curling back DOWN (exhaustion)
  - **BUY Signal**: Price spiking DOWN but momentum curling back UP (exhaustion)
- Only enters when no positions are open

### Module 3: Global Basket Management
- Monitors `ACCOUNT_PROFIT` in **dollars** (not pips or ratios)
- Closes **all positions** immediately when profit target is reached
- Uses slippage buffer for fast execution
- High-speed exit mechanism optimized for broker latency

## Input Parameters

### Profit Target
- **TargetInDollars** (default: 5.0) - Profit goal in USD to close all positions

### Margin Management
- **MarginUsage** (default: 0.95) - Percentage of available margin to use (95% = leaves 5% buffer)
- **RiskMultiplier** (default: 0.95) - Additional safety buffer multiplier

### Execution Settings
- **SlippageBuffer** (default: 30) - Slippage tolerance in points for fast exits
- **MagicNumber** (default: 888888) - Unique identifier for EA trades

### Momentum Entry Settings
- **MomentumPeriod** (default: 14) - Period for momentum indicator calculation
- **MomentumTimeframe** (default: PERIOD_M1) - Timeframe for momentum analysis

## Installation

1. Copy `FlipperMT5.mq5` to your MT5 `Experts` folder:
   ```
   MetaTrader 5/MQL5/Experts/
   ```

2. Compile the EA in MetaEditor (F7)

3. Attach to chart (preferably M1 timeframe for best results)

4. Configure parameters according to your risk tolerance

## Operational Requirements

### VPS Requirements
- **Critical**: Requires VPS with **< 5ms ping** to broker server
- Full margin trading means 1-second delay can turn profit into loss
- Recommended: Dedicated VPS in same data center as broker

### Recommended Symbols
- **Gold (XAUUSD)**: High volatility, good for momentum strategies
- **Major Forex Pairs**: EURUSD, GBPUSD, USDJPY
- **Indices**: NAS100, SPX500 (if broker supports)

### Risk Management
1. **Withdrawal Strategy**: Withdraw original deposit when account doubles
2. **Broker Limits**: Some brokers may flag "Full Margin" EAs for leverage reduction
3. **Account Size**: Start with minimum viable account size for testing
4. **Monitoring**: Monitor trades closely, especially during high volatility

## How It Works

### Entry Logic Flow
1. EA monitors account profit on every tick
2. If profit >= TargetInDollars → Close all positions immediately
3. If no positions open → Check momentum exhaustion signal
4. If signal detected → Calculate max lot size → Open trade

### Momentum Exhaustion Detection
```
SELL Signal:
- Price: Rising (spike up)
- Momentum: Was rising, now declining (curl back)
- Interpretation: Upward momentum exhausted, reversal likely

BUY Signal:
- Price: Falling (spike down)  
- Momentum: Was falling, now rising (curl back)
- Interpretation: Downward momentum exhausted, reversal likely
```

### Lot Size Calculation
```
1. Get free margin from account
2. Calculate margin for 1 lot using OrderCalcMargin()
3. Apply buffers: freeMargin × MarginUsage × RiskMultiplier
4. Calculate: availableMargin / oneLotMargin
5. Normalize to broker's lot step
6. Apply min/max limits
```

## Performance Considerations

### Execution Speed
- Uses `ORDER_FILLING_FOK` (Fill or Kill) for fastest execution
- Sets deviation in points for slippage tolerance
- Optimized tick processing to minimize latency

### Margin Safety
- Double buffer system (MarginUsage + RiskMultiplier)
- Prevents order rejection due to insufficient margin
- Accounts for price movement during execution

## Limitations & Warnings

1. **High Risk**: Uses maximum available margin - can lead to significant losses
2. **Broker Dependency**: Requires fast execution and low latency
3. **Market Conditions**: Works best in trending/volatile markets
4. **No Stop Loss**: Relies on profit target exit only (by design)
5. **Single Symbol**: Designed for one symbol at a time

## Troubleshooting

### "No free margin available"
- Reduce MarginUsage or RiskMultiplier
- Check account balance
- Verify symbol margin requirements

### "Order failed" errors
- Increase SlippageBuffer
- Check broker spread limits
- Verify symbol is tradeable

### Positions not closing
- Check SlippageBuffer setting
- Verify broker allows position closing
- Check for pending orders blocking execution

## Version History

- **v1.00** (2025-01-XX): Initial release
  - Dynamic full-margin lot sizing
  - Momentum decay entry logic
  - Dollar-based profit target exit

## Support & Disclaimer

This EA is provided as-is for educational purposes. Trading with high leverage and full margin carries extreme risk. Always:
- Test on demo account first
- Start with minimum capital
- Monitor trades actively
- Understand the risks involved

**The developer is not responsible for any financial losses incurred from using this EA.**














