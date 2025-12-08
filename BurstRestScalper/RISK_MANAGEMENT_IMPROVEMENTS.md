# Risk Management Improvements for BurstRestScalper

## Critical Issues Identified

### 1. **Excessive Cumulative Risk**
- **Current**: 5% risk per trade × 4 trades = **20% of account per basket**
- **Problem**: One losing basket can wipe out 20% of account
- **Impact**: High risk of account blowout

### 2. **No Maximum Basket Risk Cap**
- **Current**: No limit on total basket risk
- **Problem**: Risk scales linearly with number of trades
- **Impact**: Uncontrolled risk exposure

### 3. **Uses Balance Instead of Equity**
- **Current**: `AccountBalance()` used for lot calculation
- **Problem**: Ignores floating losses, can over-leverage
- **Impact**: Risk increases during drawdowns

### 4. **Recovery Mode Risk**
- **Current**: Holds losing positions until 1:4 R:R recovery
- **Problem**: Can extend drawdowns significantly
- **Impact**: Potential for larger losses if recovery fails

### 5. **No Maximum Drawdown Protection**
- **Current**: Only daily loss limit (3%)
- **Problem**: No overall account drawdown limit
- **Impact**: Can accumulate losses across multiple days

### 6. **No Maximum Open Positions**
- **Current**: No limit on total open positions
- **Problem**: Could open multiple baskets on different symbols
- **Impact**: Uncontrolled total exposure

## Recommended Solutions

### Solution 1: Add Maximum Basket Risk Cap (CRITICAL)

**Add new input parameter:**
```mql4
input double   MaxBasketRiskPercent = 10.0;  // Maximum total risk per basket (%)
```

**Modify lot calculation to distribute risk across basket:**
- If opening 4 trades, each should risk 2.5% (10% / 4) instead of 5%
- This caps total basket risk at 10% regardless of trade count

### Solution 2: Use AccountEquity() for Position Sizing

**Change in `CalculateLotSize()`:**
```mql4
// OLD:
double balance = AccountBalance();

// NEW:
double balance = AccountEquity();  // Accounts for floating losses
```

### Solution 3: Add Maximum Drawdown Protection

**Add new inputs:**
```mql4
input bool     UseMaxDrawdownProtection = true;  // Enable max drawdown protection
input double   MaxDrawdownPercent = 15.0;        // Maximum account drawdown (%)
input double   MaxDrawdownStopTrading = 20.0;    // Stop trading at this drawdown (%)
```

**Implementation:**
- Track account equity high water mark
- Calculate current drawdown from high
- Stop opening new trades if drawdown exceeds limit
- Close all positions if drawdown exceeds stop trading level

### Solution 4: Add Maximum Open Positions Limit

**Add new input:**
```mql4
input int      MaxOpenPositions = 1;  // Maximum open baskets (across all symbols)
```

**Implementation:**
- Count total open positions with EA's magic number
- Prevent opening new baskets if limit reached

### Solution 5: Add Hard Stop Loss to Recovery Mode

**Add new input:**
```mql4
input double   RecoveryMaxLossPercent = -30.0;  // Hard stop loss in recovery mode (%)
```

**Implementation:**
- If basket loss exceeds this level, close immediately
- Prevents unlimited drawdown in recovery mode

### Solution 6: Reduce Default Risk Per Trade

**Recommendation:**
- Change default `RiskPercentPerTrade` from 5.0% to **2.0%**
- With 4 trades, this gives 8% basket risk (more reasonable)
- Or implement Solution 1 to cap at 10% total

### Solution 7: Add Position Sizing Based on Drawdown

**Implementation:**
- Reduce lot size as account drawdown increases
- Example: If drawdown > 10%, reduce lot size by 50%
- Protects account during difficult periods

## Priority Implementation Order

1. **HIGH PRIORITY**: Solution 1 (Max Basket Risk Cap) - Prevents excessive risk
2. **HIGH PRIORITY**: Solution 2 (Use Equity) - Accurate risk calculation
3. **MEDIUM PRIORITY**: Solution 3 (Max Drawdown Protection) - Account protection
4. **MEDIUM PRIORITY**: Solution 5 (Recovery Hard Stop) - Limits recovery losses
5. **LOW PRIORITY**: Solution 4 (Max Open Positions) - Multi-symbol protection
6. **LOW PRIORITY**: Solution 7 (Drawdown-based sizing) - Advanced protection

## Example Risk Scenarios

### Current Setup (5% per trade, 4 trades):
- Basket Risk: **20%**
- If basket loses: **-20% account loss**
- Recovery needed: **+25% to break even**

### Recommended Setup (2.5% per trade, 4 trades, 10% cap):
- Basket Risk: **10%**
- If basket loses: **-10% account loss**
- Recovery needed: **+11.1% to break even**

### With Max Drawdown Protection (15%):
- Multiple losing baskets limited to 15% total
- Trading stops if drawdown exceeds 15%
- Account protected from catastrophic loss

## Code Changes Required

1. Add new input parameters (see above)
2. Modify `CalculateLotSize()` to:
   - Use `AccountEquity()` instead of `AccountBalance()`
   - Distribute risk across basket trades
   - Respect maximum basket risk cap
3. Add `CheckMaxDrawdown()` function
4. Add `CheckMaxOpenPositions()` function
5. Modify `CheckAndCloseBasket()` to check recovery hard stop
6. Modify `ExecuteTradingBurst()` to check all limits before opening trades

## Testing Recommendations

1. **Backtest** with different risk settings
2. **Paper trade** with recommended settings
3. **Monitor** drawdown levels in live trading
4. **Adjust** risk parameters based on results

## Conclusion

The current risk management allows for **20% account risk per basket**, which is extremely high. Implementing these improvements will:
- Reduce maximum basket risk to 10% or less
- Protect account from excessive drawdowns
- Use accurate equity-based position sizing
- Add multiple layers of risk protection

**Recommended immediate action**: Implement Solutions 1 and 2 (Max Basket Risk Cap + Use Equity) as these address the most critical issues.













