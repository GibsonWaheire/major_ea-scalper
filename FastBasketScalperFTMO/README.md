# FastBasketScalperFTMO EA

**Type:** FTMO-Compliant Automated Trading Bot
**Platform:** MetaTrader 4
**Version:** 1.00
**Purpose:** FTMO Challenge & Verification Phases

## 🎯 FTMO Compliance

This EA is specifically designed to follow **FTMO rules** strictly:

### ✅ FTMO Rules Implemented:

1. **Daily Loss Limit**: 5% maximum per day ✓
2. **Maximum Drawdown**: 10% total from start ✓
3. **Profit Target**: 10% (Challenge) / 5% (Verification) ✓
4. **Conservative Trading**: Small positions, controlled risk ✓
5. **Automatic Protection**: Closes positions at 80% of daily limit ✓

## 📊 Key Features

- **Candle Position Strategy**: BUY/SELL based on candle close position
- **Portfolio Management**: Closes ALL trades at profit targets (0.5%, 1%, 2%)
- **Conservative Risk**: 0.5% risk per trade (FTMO safe)
- **Small Baskets**: Maximum 5 trades at once
- **Daily Reset**: Tracks daily P&L separately from total
- **Real-time Monitoring**: Shows FTMO limits on chart

## 🛡️ Safety Features

### Daily Loss Protection:
- Monitors equity vs day start
- Closes all positions at 80% of daily limit
- Stops trading if 5% daily loss hit
- **Result**: Prevents FTMO rule violations

### Maximum Drawdown Protection:
- Tracks total drawdown from initial balance
- Closes all at 80% of max DD limit
- Stops trading if 10% total DD hit
- **Result**: Account preservation

### Profit Target Tracking:
- Automatically tracks progress to 10% goal
- Closes all trades when target reached
- **Result**: Pass FTMO Challenge faster

## ⚙️ FTMO Settings

```mq4
InitialBalance = 100000.0          // FTMO account size (e.g., $100k)
DailyLossPercent = 5.0             // FTMO daily limit (DON'T CHANGE)
MaxDrawdownPercent = 10.0          // FTMO max DD (DON'T CHANGE)
ProfitTargetPercent = 10.0         // Challenge target
IsChallengePhase = true            // true=Challenge, false=Verification

RiskPerTradePercent = 0.5          // Conservative 0.5%
MaxLotSize = 0.5                   // Safe lot size
MaxConcurrentTrades = 5            // Small basket

QuickExitPercent = 0.5             // Close at 0.5% portfolio profit
MainExitPercent = 1.0              // Close at 1% portfolio profit
MaxExitPercent = 2.0               // Close at 2% portfolio profit
```

## 📈 Expected Performance

**FTMO Challenge ($100k account):**
- Target: $10,000 profit (10%)
- Expected trades: 200-400 per month
- Basket approach: 20-40 baskets
- Average basket profit: $500-$1,000
- Time to target: 2-4 weeks

**Risk Profile:**
- Maximum risk per day: $5,000 (5%)
- Maximum total risk: $10,000 (10%)
- Typical daily P&L: ±$500-$2,000
- Win rate target: 60%+

## 🚀 Installation

1. Copy `.mq4` file to `MT4/MQL4/Experts/`
2. Restart MT4 or refresh Navigator
3. **IMPORTANT**: Set `InitialBalance` to your FTMO account size
4. Drag EA onto chart (M1 timeframe recommended)
5. Set `IsChallengePhase = true` for Challenge
6. Set `IsChallengePhase = false` for Verification
7. Enable AutoTrading

## ⚠️ FTMO Trading Tips

1. **Start slow**: Test on Demo first
2. **Monitor daily**: Check limits before close
3. **Avoid weekends**: Close all trades Friday
4. **Avoid news**: Major events = high risk
5. **Be patient**: Target is achievable over weeks
6. **Indices work best**: US30, US100, NAS100

## 📊 Monitoring Dashboard

The EA displays on your chart:
- Daily Loss % (must stay < 5%)
- Max Drawdown % (must stay < 10%)
- Profit Progress % (target: 10%)
- Portfolio P&L (current basket)
- Open trades count

**Watch these metrics constantly!**

## ❌ What Will Fail FTMO

- ✗ Exceeding 5% daily loss (instant fail)
- ✗ Exceeding 10% max drawdown (instant fail)
- ✗ Over-trading / excessive risk
- ✗ Not reaching profit target in time

## ✅ What Will Pass FTMO

- ✓ Staying within 5% daily limit
- ✓ Staying within 10% max DD
- ✓ Reaching 10% profit target
- ✓ Conservative, consistent trading
- ✓ This EA's approach

## 🔒 Security

This code has been obfuscated. Compile to .ex4 for additional protection.

## 📞 Support

For FTMO-specific questions or issues, contact the developer.

---

**Disclaimer**: This EA is designed for FTMO compliance but does not guarantee passing. Always monitor your trades and risk management. Past performance does not guarantee future results.

