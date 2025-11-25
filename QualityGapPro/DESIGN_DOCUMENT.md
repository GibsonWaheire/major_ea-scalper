# QualityGapPro EA - Complete Design Document

**Version:** 1.0  
**Date:** 2025-01-XX  
**Target Symbols:** GBPUSD, USDJPY  
**Target Trades/Day:** 5-50 quality trades  
**Strategy:** Fair Value Gap + Candlestick Patterns + Market Structure

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Fair Value Gap (FVG) Detection Logic](#fair-value-gap-fvg-detection-logic)
3. [Candlestick Pattern Recognition](#candlestick-pattern-recognition)
4. [Market Structure Algorithm](#market-structure-algorithm)
5. [Quality Scoring System](#quality-scoring-system)
6. [Entry Criteria & Confluences](#entry-criteria--confluences)
7. [Exit Logic & Trade Management](#exit-logic--trade-management)
8. [Session Filters](#session-filters)
9. [Spread & Volatility Checks](#spread--volatility-checks)
10. [Risk Management Workflow](#risk-management-workflow)
11. [Complete Pseudocode](#complete-pseudocode)
12. [Input Parameters Specification](#input-parameters-specification)

---

## Executive Summary

**QualityGapPro** is a quality-focused trading EA that combines:
- **Fair Value Gap (FVG)** detection for price inefficiencies
- **Candlestick pattern** confirmation for entry timing
- **Market structure** analysis (swing points, BOS, CHoCH, Order Blocks)
- **Quality scoring** system to filter only high-probability setups
- **Multi-timeframe** confluence for trade validation

**Philosophy:** Quality over quantity. Each trade must pass multiple confluence checks before execution.

---

## Fair Value Gap (FVG) Detection Logic

### Definition
A Fair Value Gap is a price inefficiency where:
- **Bullish FVG:** Candle A high < Candle B low AND Candle A high < Candle C low
- **Bearish FVG:** Candle A low > Candle B high AND Candle A low > Candle C high

Where:
- Candle A = 2 candles ago (shift 2)
- Candle B = 1 candle ago (shift 1) 
- Candle C = Current candle (shift 0)

### Detection Algorithm

```
FUNCTION DetectFVG(symbol, timeframe, shift):
    // Get candle data
    highA = iHigh(symbol, timeframe, shift + 2)
    lowA = iLow(symbol, timeframe, shift + 2)
    highB = iHigh(symbol, timeframe, shift + 1)
    lowB = iLow(symbol, timeframe, shift + 1)
    highC = iHigh(symbol, timeframe, shift)
    lowC = iLow(symbol, timeframe, shift)
    
    // Calculate gap size
    bullishGapSize = lowB - highA
    bearishGapSize = highB - lowA
    
    // Check bullish FVG
    IF (highA < lowB) AND (highA < lowC):
        gapSize = bullishGapSize
        gapTop = lowB
        gapBottom = highA
        direction = BULLISH
        RETURN {type: BULLISH_FVG, size: gapSize, top: gapTop, bottom: gapBottom}
    
    // Check bearish FVG
    IF (lowA > highB) AND (lowA > highC):
        gapSize = bearishGapSize
        gapTop = lowA
        gapBottom = highB
        direction = BEARISH
        RETURN {type: BEARISH_FVG, size: gapSize, top: gapTop, bottom: gapBottom}
    
    RETURN NULL
```

### FVG Quality Assessment

```
FUNCTION AssessFVGQuality(fvg, symbol, timeframe):
    score = 0
    maxScore = 3
    
    // 1. Gap Size Quality (0-1 point)
    minGapPips = MinFVGSizePips
    gapPips = fvg.size / GetPipSize(symbol)
    IF gapPips >= minGapPips:
        IF gapPips >= minGapPips * 2:
            score += 1.0  // Large gap
        ELSE:
            score += 0.5  // Medium gap
    
    // 2. EMA Bias Alignment (0-1 point)
    IF RequireEMABias:
        emaFast = iMA(symbol, timeframe, EMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE, 0)
        emaSlow = iMA(symbol, timeframe, EMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE, 0)
        currentPrice = (Ask + Bid) / 2
        
        IF fvg.type == BULLISH_FVG:
            IF (emaFast > emaSlow) AND (currentPrice > emaFast):
                score += 1.0  // Strong bullish bias
            ELSE IF (emaFast > emaSlow):
                score += 0.5  // Weak bullish bias
        
        IF fvg.type == BEARISH_FVG:
            IF (emaFast < emaSlow) AND (currentPrice < emaFast):
                score += 1.0  // Strong bearish bias
            ELSE IF (emaFast < emaSlow):
                score += 0.5  // Weak bearish bias
    
    // 3. Gap Context & Freshness (0-1 point)
    // Check if gap is still unfilled
    currentPrice = (Ask + Bid) / 2
    IF fvg.type == BULLISH_FVG:
        IF currentPrice >= fvg.bottom AND currentPrice <= fvg.top:
            score += 1.0  // Price is in gap (fresh)
        ELSE IF currentPrice < fvg.bottom:
            score += 0.3  // Gap not yet reached
        ELSE:
            score += 0.0  // Gap filled
    
    IF fvg.type == BEARISH_FVG:
        IF currentPrice <= fvg.top AND currentPrice >= fvg.bottom:
            score += 1.0  // Price is in gap (fresh)
        ELSE IF currentPrice > fvg.top:
            score += 0.3  // Gap not yet reached
        ELSE:
            score += 0.0  // Gap filled
    
    RETURN score / maxScore  // Normalize to 0-1, then multiply by 3 for final score
```

### FVG Detection Workflow

```
FUNCTION ScanForFVG(symbol):
    // Primary timeframe (M5)
    fvgM5 = DetectFVG(symbol, PERIOD_M5, 0)
    IF fvgM5 == NULL:
        fvgM5 = DetectFVG(symbol, PERIOD_M5, 1)  // Check previous candle
    
    // Higher timeframe confirmation (M15)
    fvgM15 = DetectFVG(symbol, PERIOD_M15, 0)
    
    // Return best FVG
    IF fvgM5 != NULL:
        quality = AssessFVGQuality(fvgM5, symbol, PERIOD_M5)
        RETURN {fvg: fvgM5, timeframe: M5, quality: quality}
    
    IF fvgM15 != NULL:
        quality = AssessFVGQuality(fvgM15, symbol, PERIOD_M15)
        RETURN {fvg: fvgM15, timeframe: M15, quality: quality}
    
    RETURN NULL
```

---

## Candlestick Pattern Recognition

### Pattern Types

#### 1. Engulfing Patterns

**Bullish Engulfing:**
- Previous candle is bearish (close < open)
- Current candle is bullish (close > open)
- Current body completely engulfs previous body
- Current high > previous high AND current low < previous low

**Bearish Engulfing:**
- Previous candle is bullish (close > open)
- Current candle is bearish (close < open)
- Current body completely engulfs previous body
- Current high > previous high AND current low < previous low

#### 2. Pin Bars (Rejection Candles)

**Bullish Pin Bar:**
- Long lower wick (tail)
- Small upper wick
- Body at top 1/3 of candle
- Tail length >= 60% of total candle range
- Tail length >= 2x body size

**Bearish Pin Bar:**
- Long upper wick (tail)
- Small lower wick
- Body at bottom 1/3 of candle
- Tail length >= 60% of total candle range
- Tail length >= 2x body size

#### 3. Inside Bars

**Inside Bar:**
- Current high < previous high
- Current low > previous low
- Current candle is completely inside previous candle
- Indicates consolidation before breakout

#### 4. Three-Line Patterns

**Three White Soldiers (Bullish):**
- Three consecutive bullish candles
- Each close higher than previous
- Each open within previous body
- Strong momentum pattern

**Three Black Crows (Bearish):**
- Three consecutive bearish candles
- Each close lower than previous
- Each open within previous body
- Strong momentum pattern

### Pattern Detection Algorithm

```
FUNCTION DetectCandlestickPattern(symbol, timeframe, shift):
    // Get candle data
    open0 = iOpen(symbol, timeframe, shift)
    high0 = iHigh(symbol, timeframe, shift)
    low0 = iLow(symbol, timeframe, shift)
    close0 = iClose(symbol, timeframe, shift)
    
    open1 = iOpen(symbol, timeframe, shift + 1)
    high1 = iHigh(symbol, timeframe, shift + 1)
    low1 = iLow(symbol, timeframe, shift + 1)
    close1 = iClose(symbol, timeframe, shift + 1)
    
    open2 = iOpen(symbol, timeframe, shift + 2)
    high2 = iHigh(symbol, timeframe, shift + 2)
    low2 = iLow(symbol, timeframe, shift + 2)
    close2 = iClose(symbol, timeframe, shift + 2)
    
    // Calculate candle properties
    body0 = MathAbs(close0 - open0)
    body1 = MathAbs(close1 - open1)
    range0 = high0 - low0
    range1 = high1 - low1
    
    upperWick0 = high0 - MathMax(open0, close0)
    lowerWick0 = MathMin(open0, close0) - low0
    
    // 1. Check Bullish Engulfing
    IF UseEngulfingPatterns:
        IF (close1 < open1) AND (close0 > open0):  // Previous bearish, current bullish
            IF (close0 > open1) AND (open0 < close1):  // Current engulfs previous
                IF (high0 > high1) AND (low0 < low1):  // Complete engulfment
                    engulfingRatio = body0 / body1
                    IF engulfingRatio >= MinEngulfingBodyRatio:
                        RETURN {type: BULLISH_ENGULFING, strength: engulfingRatio}
    
    // 2. Check Bearish Engulfing
    IF UseEngulfingPatterns:
        IF (close1 > open1) AND (close0 < open0):  // Previous bullish, current bearish
            IF (close0 < open1) AND (open0 > close1):  // Current engulfs previous
                IF (high0 > high1) AND (low0 < low1):  // Complete engulfment
                    engulfingRatio = body0 / body1
                    IF engulfingRatio >= MinEngulfingBodyRatio:
                        RETURN {type: BEARISH_ENGULFING, strength: engulfingRatio}
    
    // 3. Check Bullish Pin Bar
    IF UsePinBars:
        IF range0 > 0:
            tailRatio = lowerWick0 / range0
            bodyRatio = body0 / range0
            IF (tailRatio >= MinPinBarRatio) AND (lowerWick0 >= body0 * 2):
                IF (upperWick0 < lowerWick0 * 0.5):  // Small upper wick
                    IF (MathMax(open0, close0) > low0 + range0 * 0.66):  // Body in top third
                        RETURN {type: BULLISH_PIN, strength: tailRatio}
    
    // 4. Check Bearish Pin Bar
    IF UsePinBars:
        IF range0 > 0:
            tailRatio = upperWick0 / range0
            bodyRatio = body0 / range0
            IF (tailRatio >= MinPinBarRatio) AND (upperWick0 >= body0 * 2):
                IF (lowerWick0 < upperWick0 * 0.5):  // Small lower wick
                    IF (MathMin(open0, close0) < high0 - range0 * 0.66):  // Body in bottom third
                        RETURN {type: BEARISH_PIN, strength: tailRatio}
    
    // 5. Check Inside Bar
    IF UseInsideBars:
        IF (high0 < high1) AND (low0 > low1):
            RETURN {type: INSIDE_BAR, strength: 0.5}
    
    // 6. Check Three White Soldiers
    IF (close0 > open0) AND (close1 > open1) AND (close2 > open2):
        IF (close0 > close1) AND (close1 > close2):
            IF (open0 >= close1 * 0.95) AND (open1 >= close2 * 0.95):  // Opens within previous body
                RETURN {type: THREE_WHITE_SOLDIERS, strength: 1.0}
    
    // 7. Check Three Black Crows
    IF (close0 < open0) AND (close1 < open1) AND (close2 < open2):
        IF (close0 < close1) AND (close1 < close2):
            IF (open0 <= close1 * 1.05) AND (open1 <= close2 * 1.05):  // Opens within previous body
                RETURN {type: THREE_BLACK_CROWS, strength: 1.0}
    
    RETURN NULL
```

### Pattern Quality Scoring

```
FUNCTION AssessPatternQuality(pattern, symbol, timeframe):
    score = 0
    maxScore = 3
    
    // 1. Pattern Type Strength (0-1 point)
    patternStrength = {
        BULLISH_ENGULFING: 1.0,
        BEARISH_ENGULFING: 1.0,
        BULLISH_PIN: 0.8,
        BEARISH_PIN: 0.8,
        THREE_WHITE_SOLDIERS: 1.0,
        THREE_BLACK_CROWS: 1.0,
        INSIDE_BAR: 0.5
    }
    score += patternStrength[pattern.type] * pattern.strength
    
    // 2. Pattern Location (0-1 point)
    // Check if pattern is at key support/resistance
    currentPrice = (Ask + Bid) / 2
    // Check proximity to recent swing high/low
    swingHigh = GetRecentSwingHigh(symbol, timeframe, 20)
    swingLow = GetRecentSwingLow(symbol, timeframe, 20)
    
    IF pattern.type IN [BULLISH_ENGULFING, BULLISH_PIN, THREE_WHITE_SOLDIERS]:
        distanceToSwingLow = MathAbs(currentPrice - swingLow)
        pipSize = GetPipSize(symbol)
        IF distanceToSwingLow <= 20 * pipSize:  // Within 20 pips of swing low
            score += 1.0
        ELSE IF distanceToSwingLow <= 50 * pipSize:
            score += 0.5
    
    IF pattern.type IN [BEARISH_ENGULFING, BEARISH_PIN, THREE_BLACK_CROWS]:
        distanceToSwingHigh = MathAbs(currentPrice - swingHigh)
        pipSize = GetPipSize(symbol)
        IF distanceToSwingHigh <= 20 * pipSize:  // Within 20 pips of swing high
            score += 1.0
        ELSE IF distanceToSwingHigh <= 50 * pipSize:
            score += 0.5
    
    // 3. Pattern Size & Volume Context (0-1 point)
    // Larger patterns in volatile markets score higher
    atr = iATR(symbol, timeframe, 14, 0)
    patternSize = GetPatternSize(pattern, symbol, timeframe)
    pipSize = GetPipSize(symbol)
    
    IF patternSize >= atr * 0.5:  // Pattern is at least 50% of ATR
        score += 1.0
    ELSE IF patternSize >= atr * 0.3:
        score += 0.5
    
    RETURN MathMin(score, maxScore)  // Cap at maxScore
```

---

## Market Structure Algorithm

### Core Concepts

#### 1. Swing Points (Highs & Lows)

**Swing High:**
- A candle where high > previous N candles' highs
- AND high > next N candles' highs
- N = lookback period (default: 5)

**Swing Low:**
- A candle where low < previous N candles' lows
- AND low < next N candles' lows
- N = lookback period (default: 5)

#### 2. Break of Structure (BOS)

**Bullish BOS:**
- Price breaks above a previous swing high
- Indicates trend change from bearish to bullish

**Bearish BOS:**
- Price breaks below a previous swing low
- Indicates trend change from bullish to bearish

#### 3. Change of Character (CHoCH)

**Bullish CHoCH:**
- Price makes a higher low after a downtrend
- First sign of potential trend reversal (softer than BOS)

**Bearish CHoCH:**
- Price makes a lower high after an uptrend
- First sign of potential trend reversal (softer than BOS)

#### 4. Order Blocks (OB)

**Bullish Order Block:**
- Last bearish candle before a strong bullish move
- The body of that candle becomes a support zone
- Price often reacts from this zone

**Bearish Order Block:**
- Last bullish candle before a strong bearish move
- The body of that candle becomes a resistance zone
- Price often reacts from this zone

### Market Structure Detection Algorithm

```
FUNCTION DetectSwingPoints(symbol, timeframe, lookback):
    swingHighs = []
    swingLows = []
    
    FOR i = lookback TO (iBars(symbol, timeframe) - lookback):
        high = iHigh(symbol, timeframe, i)
        low = iLow(symbol, timeframe, i)
        
        // Check if swing high
        isSwingHigh = true
        FOR j = 1 TO lookback:
            IF iHigh(symbol, timeframe, i - j) >= high:
                isSwingHigh = false
                BREAK
            IF iHigh(symbol, timeframe, i + j) >= high:
                isSwingHigh = false
                BREAK
        
        IF isSwingHigh:
            swingHighs.ADD({index: i, price: high, time: iTime(symbol, timeframe, i)})
        
        // Check if swing low
        isSwingLow = true
        FOR j = 1 TO lookback:
            IF iLow(symbol, timeframe, i - j) <= low:
                isSwingLow = false
                BREAK
            IF iLow(symbol, timeframe, i + j) <= low:
                isSwingLow = false
                BREAK
        
        IF isSwingLow:
            swingLows.ADD({index: i, price: low, time: iTime(symbol, timeframe, i)})
    
    RETURN {highs: swingHighs, lows: swingLows}
```

```
FUNCTION DetectBOS(symbol, timeframe):
    currentPrice = (Ask + Bid) / 2
    swingPoints = DetectSwingPoints(symbol, timeframe, 5)
    
    // Get most recent swing high and low
    recentSwingHigh = swingPoints.highs[0]  // Most recent
    recentSwingLow = swingPoints.lows[0]    // Most recent
    
    // Check for bullish BOS
    IF currentPrice > recentSwingHigh.price:
        RETURN {type: BULLISH_BOS, level: recentSwingHigh.price, time: recentSwingHigh.time}
    
    // Check for bearish BOS
    IF currentPrice < recentSwingLow.price:
        RETURN {type: BEARISH_BOS, level: recentSwingLow.price, time: recentSwingLow.time}
    
    RETURN NULL
```

```
FUNCTION DetectCHoCH(symbol, timeframe):
    swingPoints = DetectSwingPoints(symbol, timeframe, 5)
    
    // Need at least 2 swing highs and 2 swing lows
    IF swingPoints.highs.length < 2 OR swingPoints.lows.length < 2:
        RETURN NULL
    
    recentHigh = swingPoints.highs[0]
    previousHigh = swingPoints.highs[1]
    recentLow = swingPoints.lows[0]
    previousLow = swingPoints.lows[1]
    
    // Bullish CHoCH: Higher low
    IF recentLow.price > previousLow.price:
        RETURN {type: BULLISH_CHOCH, level: recentLow.price, time: recentLow.time}
    
    // Bearish CHoCH: Lower high
    IF recentHigh.price < previousHigh.price:
        RETURN {type: BEARISH_CHOCH, level: recentHigh.price, time: recentHigh.time}
    
    RETURN NULL
```

```
FUNCTION DetectOrderBlocks(symbol, timeframe, lookback):
    orderBlocks = []
    
    FOR i = lookback TO (iBars(symbol, timeframe) - 5):
        open = iOpen(symbol, timeframe, i)
        close = iClose(symbol, timeframe, i)
        high = iHigh(symbol, timeframe, i)
        low = iLow(symbol, timeframe, i)
        
        // Check for bullish order block (last bearish candle before strong bullish move)
        IF close < open:  // Bearish candle
            // Check if next 3-5 candles are strongly bullish
            bullishMove = true
            bullishStrength = 0
            FOR j = 1 TO 5:
                IF j > (iBars(symbol, timeframe) - i - 1):
                    bullishMove = false
                    BREAK
                nextClose = iClose(symbol, timeframe, i - j)
                nextOpen = iOpen(symbol, timeframe, i - j)
                IF nextClose > nextOpen:
                    bullishStrength += (nextClose - nextOpen)
                ELSE:
                    IF j <= 3:  // First 3 candles must be bullish
                        bullishMove = false
                        BREAK
            
            IF bullishMove AND bullishStrength > (high - low) * 2:
                orderBlocks.ADD({
                    type: BULLISH_OB,
                    top: MathMax(open, close),
                    bottom: MathMin(open, close),
                    time: iTime(symbol, timeframe, i),
                    strength: bullishStrength
                })
        
        // Check for bearish order block (last bullish candle before strong bearish move)
        IF close > open:  // Bullish candle
            // Check if next 3-5 candles are strongly bearish
            bearishMove = true
            bearishStrength = 0
            FOR j = 1 TO 5:
                IF j > (iBars(symbol, timeframe) - i - 1):
                    bearishMove = false
                    BREAK
                nextClose = iClose(symbol, timeframe, i - j)
                nextOpen = iOpen(symbol, timeframe, i - j)
                IF nextClose < nextOpen:
                    bearishStrength += (nextOpen - nextClose)
                ELSE:
                    IF j <= 3:  // First 3 candles must be bearish
                        bearishMove = false
                        BREAK
            
            IF bearishMove AND bearishStrength > (high - low) * 2:
                orderBlocks.ADD({
                    type: BEARISH_OB,
                    top: MathMax(open, close),
                    bottom: MathMin(open, close),
                    time: iTime(symbol, timeframe, i),
                    strength: bearishStrength
                })
    
    RETURN orderBlocks
```

### Market Structure Quality Assessment

```
FUNCTION AssessMarketStructure(symbol, timeframe, tradeDirection):
    score = 0
    maxScore = 2
    
    // 1. Order Block Alignment (0-1 point)
    IF UseOrderBlocks:
        orderBlocks = DetectOrderBlocks(symbol, timeframe, OrderBlockLookback)
        currentPrice = (Ask + Bid) / 2
        pipSize = GetPipSize(symbol)
        
        FOR EACH ob IN orderBlocks:
            // Check if price is near order block
            distance = 0
            IF currentPrice >= ob.bottom AND currentPrice <= ob.top:
                distance = 0  // Price is in order block
            ELSE IF currentPrice < ob.bottom:
                distance = (ob.bottom - currentPrice) / pipSize
            ELSE:
                distance = (currentPrice - ob.top) / pipSize
            
            IF distance <= 10:  // Within 10 pips
                IF (tradeDirection == BULLISH AND ob.type == BULLISH_OB):
                    score += 1.0
                    BREAK
                IF (tradeDirection == BEARISH AND ob.type == BEARISH_OB):
                    score += 1.0
                    BREAK
                IF distance <= 20:
                    score += 0.5
    
    // 2. Liquidity Zone Proximity (0-1 point)
    IF UseLiquidityZones:
        swingPoints = DetectSwingPoints(symbol, timeframe, 5)
        currentPrice = (Ask + Bid) / 2
        pipSize = GetPipSize(symbol)
        
        // Check proximity to recent swing points
        IF tradeDirection == BULLISH:
            // Look for nearby swing low (support)
            FOR EACH low IN swingPoints.lows:
                distance = (currentPrice - low.price) / pipSize
                IF distance <= 20 AND distance >= -10:  // Within 20 pips above, 10 pips below
                    score += 1.0
                    BREAK
                IF distance <= 50:
                    score += 0.5
        
        IF tradeDirection == BEARISH:
            // Look for nearby swing high (resistance)
            FOR EACH high IN swingPoints.highs:
                distance = (high.price - currentPrice) / pipSize
                IF distance <= 20 AND distance >= -10:  // Within 20 pips below, 10 pips above
                    score += 1.0
                    BREAK
                IF distance <= 50:
                    score += 0.5
    
    RETURN MathMin(score, maxScore)  // Cap at maxScore
```

---

## Quality Scoring System

### Overall Quality Score Calculation

```
FUNCTION CalculateQualityScore(fvg, pattern, marketStructure, session, symbol):
    totalScore = 0
    maxTotalScore = 10
    
    // 1. FVG Quality (0-3 points)
    fvgScore = AssessFVGQuality(fvg, symbol, fvg.timeframe)
    totalScore += fvgScore
    
    // 2. Candlestick Pattern Quality (0-3 points)
    IF pattern != NULL:
        patternScore = AssessPatternQuality(pattern, symbol, pattern.timeframe)
        totalScore += patternScore
    ELSE:
        totalScore += 0  // No pattern = no points
    
    // 3. Market Structure Quality (0-2 points)
    tradeDirection = (fvg.type == BULLISH_FVG) ? BULLISH : BEARISH
    structureScore = AssessMarketStructure(symbol, fvg.timeframe, tradeDirection)
    totalScore += structureScore
    
    // 4. Session Quality (0-2 points)
    sessionScore = AssessSessionQuality(symbol)
    totalScore += sessionScore
    
    RETURN {total: totalScore, max: maxTotalScore, percentage: (totalScore / maxTotalScore) * 100}
```

### Quality Score Breakdown

| Component | Max Points | Criteria |
|-----------|------------|----------|
| **FVG Quality** | 3 | Gap size (1), EMA bias (1), Gap freshness (1) |
| **Candlestick Pattern** | 3 | Pattern type (1), Location (1), Size (1) |
| **Market Structure** | 2 | Order block alignment (1), Liquidity zones (1) |
| **Session Quality** | 2 | Session overlap (1), Spread/volatility (1) |
| **TOTAL** | **10** | **Minimum required: 6/10 (60%)** |

### Quality Thresholds

```
FUNCTION IsQualityTrade(qualityScore):
    IF qualityScore.total >= MinQualityScore:  // Default: 6/10
        RETURN true
    RETURN false
```

---

## Entry Criteria & Confluences

### Complete Entry Validation

```
FUNCTION ValidateEntry(symbol):
    // Step 1: Pre-flight checks
    IF NOT PreFlightChecks(symbol):
        RETURN {valid: false, reason: "Pre-flight checks failed"}
    
    // Step 2: Detect FVG
    fvgData = ScanForFVG(symbol)
    IF fvgData == NULL:
        RETURN {valid: false, reason: "No FVG detected"}
    
    // Step 3: Detect candlestick pattern
    pattern = DetectCandlestickPattern(symbol, fvgData.timeframe, 0)
    IF pattern == NULL:
        pattern = DetectCandlestickPattern(symbol, fvgData.timeframe, 1)  // Check previous candle
    
    // Step 4: Assess market structure
    tradeDirection = (fvgData.fvg.type == BULLISH_FVG) ? BULLISH : BEARISH
    marketStructure = AssessMarketStructure(symbol, fvgData.timeframe, tradeDirection)
    
    // Step 5: Calculate quality score
    sessionQuality = AssessSessionQuality(symbol)
    qualityScore = CalculateQualityScore(fvgData, pattern, marketStructure, sessionQuality, symbol)
    
    // Step 6: Check minimum quality threshold
    IF NOT IsQualityTrade(qualityScore):
        RETURN {valid: false, reason: "Quality score too low: " + qualityScore.total}
    
    // Step 7: Check pattern-direction alignment
    IF pattern != NULL:
        IF (fvgData.fvg.type == BULLISH_FVG) AND (pattern.type NOT IN [BULLISH_ENGULFING, BULLISH_PIN, THREE_WHITE_SOLDIERS]):
            RETURN {valid: false, reason: "Pattern direction mismatch"}
        IF (fvgData.fvg.type == BEARISH_FVG) AND (pattern.type NOT IN [BEARISH_ENGULFING, BEARISH_PIN, THREE_BLACK_CROWS]):
            RETURN {valid: false, reason: "Pattern direction mismatch"}
    
    // Step 8: Check structure break requirement
    IF RequireStructureBreak:
        bos = DetectBOS(symbol, fvgData.timeframe)
        choch = DetectCHoCH(symbol, fvgData.timeframe)
        IF bos == NULL AND choch == NULL:
            RETURN {valid: false, reason: "No structure break detected"}
    
    // Step 9: Calculate entry price and levels
    entryData = CalculateEntryLevels(fvgData, pattern, symbol, tradeDirection)
    
    // Step 10: Check risk/reward
    IF entryData.riskReward < MinRiskReward:
        RETURN {valid: false, reason: "Risk/reward too low: " + entryData.riskReward}
    
    RETURN {
        valid: true,
        direction: tradeDirection,
        fvg: fvgData.fvg,
        pattern: pattern,
        qualityScore: qualityScore,
        entry: entryData
    }
```

### Entry Level Calculation

```
FUNCTION CalculateEntryLevels(fvgData, pattern, symbol, direction):
    currentPrice = (Ask + Bid) / 2
    pipSize = GetPipSize(symbol)
    
    IF direction == BULLISH:
        // Entry: Current price or gap bottom
        entryPrice = Ask
        IF currentPrice < fvgData.fvg.bottom:
            entryPrice = fvgData.fvg.bottom + (pipSize * 2)  // Slightly above gap bottom
        
        // Stop Loss: Below gap bottom or recent swing low
        swingLow = GetRecentSwingLow(symbol, fvgData.timeframe, 20)
        stopLoss = MathMin(fvgData.fvg.bottom - (pipSize * StructureStopBufferPips), swingLow - (pipSize * StructureStopBufferPips))
        
        // Take Profit: Gap top or structure target
        takeProfit = fvgData.fvg.top
        swingHigh = GetRecentSwingHigh(symbol, fvgData.timeframe, 20)
        IF swingHigh > takeProfit:
            takeProfit = swingHigh - (pipSize * 5)  // 5 pips before resistance
    
    ELSE:  // BEARISH
        // Entry: Current price or gap top
        entryPrice = Bid
        IF currentPrice > fvgData.fvg.top:
            entryPrice = fvgData.fvg.top - (pipSize * 2)  // Slightly below gap top
        
        // Stop Loss: Above gap top or recent swing high
        swingHigh = GetRecentSwingHigh(symbol, fvgData.timeframe, 20)
        stopLoss = MathMax(fvgData.fvg.top + (pipSize * StructureStopBufferPips), swingHigh + (pipSize * StructureStopBufferPips))
        
        // Take Profit: Gap bottom or structure target
        takeProfit = fvgData.fvg.bottom
        swingLow = GetRecentSwingLow(symbol, fvgData.timeframe, 20)
        IF swingLow < takeProfit:
            takeProfit = swingLow + (pipSize * 5)  // 5 pips before support
    
    // Calculate risk/reward
    riskPips = MathAbs(entryPrice - stopLoss) / pipSize
    rewardPips = MathAbs(takeProfit - entryPrice) / pipSize
    riskReward = (rewardPips > 0) ? (rewardPips / riskPips) : 0
    
    RETURN {
        entryPrice: entryPrice,
        stopLoss: stopLoss,
        takeProfit: takeProfit,
        riskPips: riskPips,
        rewardPips: rewardPips,
        riskReward: riskReward
    }
```

---

## Exit Logic & Trade Management

### Exit Strategy Components

#### 1. Stop Loss Management

```
FUNCTION ManageStopLoss(ticket, entryData):
    IF NOT OrderSelect(ticket, SELECT_BY_TICKET):
        RETURN false
    
    currentPrice = (OrderType() == OP_BUY) ? Bid : Ask
    entryPrice = OrderOpenPrice()
    stopLoss = OrderStopLoss()
    
    // Dynamic stop loss based on structure
    IF UseDynamicStopLoss:
        symbol = OrderSymbol()
        timeframe = PERIOD_M5
        
        IF OrderType() == OP_BUY:
            swingLow = GetRecentSwingLow(symbol, timeframe, 20)
            newStopLoss = swingLow - (GetPipSize(symbol) * StructureStopBufferPips)
            IF newStopLoss > stopLoss AND newStopLoss < currentPrice:
                ModifyOrderStopLoss(ticket, newStopLoss)
        
        ELSE:  // OP_SELL
            swingHigh = GetRecentSwingHigh(symbol, timeframe, 20)
            newStopLoss = swingHigh + (GetPipSize(symbol) * StructureStopBufferPips)
            IF newStopLoss < stopLoss AND newStopLoss > currentPrice:
                ModifyOrderStopLoss(ticket, newStopLoss)
    
    RETURN true
```

#### 2. Break-Even Management

```
FUNCTION ManageBreakEven(ticket, entryData):
    IF NOT UseBreakEven:
        RETURN false
    
    IF NOT OrderSelect(ticket, SELECT_BY_TICKET):
        RETURN false
    
    entryPrice = OrderOpenPrice()
    stopLoss = OrderStopLoss()
    currentPrice = (OrderType() == OP_BUY) ? Bid : Ask
    pipSize = GetPipSize(OrderSymbol())
    
    // Calculate risk in pips
    riskPips = MathAbs(entryPrice - stopLoss) / pipSize
    
    // Check if profit >= BreakEvenTriggerPips * risk
    profitPips = 0
    IF OrderType() == OP_BUY:
        profitPips = (currentPrice - entryPrice) / pipSize
    ELSE:
        profitPips = (entryPrice - currentPrice) / pipSize
    
    IF profitPips >= (riskPips * BreakEvenTriggerPips):
        // Move stop loss to break-even
        newStopLoss = entryPrice + (pipSize * 1)  // 1 pip above entry for BUY
        IF OrderType() == OP_SELL:
            newStopLoss = entryPrice - (pipSize * 1)  // 1 pip below entry for SELL
        
        IF (OrderType() == OP_BUY AND newStopLoss > stopLoss) OR (OrderType() == OP_SELL AND newStopLoss < stopLoss):
            ModifyOrderStopLoss(ticket, newStopLoss)
            RETURN true
    
    RETURN false
```

#### 3. Trailing Stop Management

```
FUNCTION ManageTrailingStop(ticket):
    IF NOT UseTrailingStop:
        RETURN false
    
    IF NOT OrderSelect(ticket, SELECT_BY_TICKET):
        RETURN false
    
    entryPrice = OrderOpenPrice()
    stopLoss = OrderStopLoss()
    currentPrice = (OrderType() == OP_BUY) ? Bid : Ask
    pipSize = GetPipSize(OrderSymbol())
    
    // Calculate profit in pips
    profitPips = 0
    IF OrderType() == OP_BUY:
        profitPips = (currentPrice - entryPrice) / pipSize
    ELSE:
        profitPips = (entryPrice - currentPrice) / pipSize
    
    // Check if trailing should activate
    IF profitPips < TrailingStartPips:
        RETURN false  // Not enough profit yet
    
    // Calculate new trailing stop
    IF OrderType() == OP_BUY:
        newStopLoss = currentPrice - (TrailingStepPips * pipSize)
        IF newStopLoss > stopLoss AND newStopLoss < currentPrice:
            ModifyOrderStopLoss(ticket, newStopLoss)
            RETURN true
    
    ELSE:  // OP_SELL
        newStopLoss = currentPrice + (TrailingStepPips * pipSize)
        IF newStopLoss < stopLoss AND newStopLoss > currentPrice:
            ModifyOrderStopLoss(ticket, newStopLoss)
            RETURN true
    
    RETURN false
```

#### 4. Partial Close Management

```
FUNCTION ManagePartialCloses(ticket, entryData):
    IF NOT UsePartialCloses:
        RETURN false
    
    IF NOT OrderSelect(ticket, SELECT_BY_TICKET):
        RETURN false
    
    entryPrice = OrderOpenPrice()
    stopLoss = OrderStopLoss()
    currentPrice = (OrderType() == OP_BUY) ? Bid : Ask
    pipSize = GetPipSize(OrderSymbol())
    lots = OrderLots()
    
    // Calculate risk in pips
    riskPips = MathAbs(entryPrice - stopLoss) / pipSize
    
    // Calculate profit in pips
    profitPips = 0
    IF OrderType() == OP_BUY:
        profitPips = (currentPrice - entryPrice) / pipSize
    ELSE:
        profitPips = (entryPrice - currentPrice) / pipSize
    
    // Partial Close 1: At 1R (risk = reward)
    IF profitPips >= riskPips AND NOT partialClose1Done:
        closeLots = lots * PartialClose1Ratio
        IF ClosePartialOrder(ticket, closeLots):
            partialClose1Done = true
            RETURN true
    
    // Partial Close 2: At 2R
    IF profitPips >= (riskPips * 2) AND NOT partialClose2Done:
        closeLots = lots * PartialClose2Ratio
        IF ClosePartialOrder(ticket, closeLots):
            partialClose2Done = true
            RETURN true
    
    RETURN false
```

#### 5. Time-Based Exit

```
FUNCTION CheckTimeBasedExit(ticket):
    IF NOT OrderSelect(ticket, SELECT_BY_TICKET):
        RETURN false
    
    openTime = OrderOpenTime()
    currentTime = TimeCurrent()
    holdSeconds = currentTime - openTime
    
    // Close if held too long (optional)
    IF MaxHoldSeconds > 0 AND holdSeconds >= MaxHoldSeconds:
        OrderClose(ticket, OrderLots(), (OrderType() == OP_BUY) ? Bid : Ask, 3)
        RETURN true
    
    RETURN false
```

#### 6. Trend Reversal Protection

```
FUNCTION CheckTrendReversal(ticket):
    IF NOT OrderSelect(ticket, SELECT_BY_TICKET):
        RETURN false
    
    symbol = OrderSymbol()
    timeframe = PERIOD_M5
    orderType = OrderType()
    
    // Get EMA trend
    emaFast = iMA(symbol, timeframe, EMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE, 0)
    emaSlow = iMA(symbol, timeframe, EMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE, 0)
    
    // Check if trend reversed against position
    IF orderType == OP_BUY:
        IF emaFast < emaSlow:  // Trend reversed to bearish
            // Check minimum hold time
            holdSeconds = TimeCurrent() - OrderOpenTime()
            IF holdSeconds >= TrendReversalMinHoldSec:
                OrderClose(ticket, OrderLots(), Bid, 3)
                RETURN true
    
    ELSE:  // OP_SELL
        IF emaFast > emaSlow:  // Trend reversed to bullish
            // Check minimum hold time
            holdSeconds = TimeCurrent() - OrderOpenTime()
            IF holdSeconds >= TrendReversalMinHoldSec:
                OrderClose(ticket, OrderLots(), Ask, 3)
                RETURN true
    
    RETURN false
```

### Complete Trade Management Workflow

```
FUNCTION ManageOpenTrades():
    FOR EACH ticket IN GetOpenTrades(MagicNumber):
        // 1. Check time-based exit
        IF CheckTimeBasedExit(ticket):
            CONTINUE
        
        // 2. Check trend reversal
        IF UseTrendReversalProtection:
            IF CheckTrendReversal(ticket):
                CONTINUE
        
        // 3. Manage break-even
        ManageBreakEven(ticket, entryData)
        
        // 4. Manage trailing stop
        ManageTrailingStop(ticket)
        
        // 5. Manage partial closes
        ManagePartialCloses(ticket, entryData)
        
        // 6. Update dynamic stop loss
        ManageStopLoss(ticket, entryData)
```

---

## Session Filters

### Session Quality Assessment

```
FUNCTION AssessSessionQuality(symbol):
    score = 0
    maxScore = 2
    
    // 1. Session Overlap (0-1 point)
    IF UseSessionFilter:
        currentHour = GetServerHour()
        
        // London session: 8:00 - 17:00
        // New York session: 13:00 - 22:00
        // Overlap: 13:00 - 17:00 (best liquidity)
        
        IF currentHour >= 13 AND currentHour < 17:
            score += 1.0  // London/NY overlap
        ELSE IF (currentHour >= 8 AND currentHour < 13) OR (currentHour >= 17 AND currentHour < 22):
            score += 0.5  // Single session active
        ELSE:
            score += 0.0  // Off-hours
    
    // 2. Spread & Volatility Quality (0-1 point)
    spreadPips = GetCurrentSpreadPips(symbol)
    atrPips = GetATRPips(symbol, PERIOD_M5, 14)
    
    // Check spread quality
    spreadScore = 0
    IF spreadPips <= MaxSpreadPips * 0.5:
        spreadScore = 1.0
    ELSE IF spreadPips <= MaxSpreadPips:
        spreadScore = 0.5
    
    // Check volatility quality
    volatilityScore = 0
    IF atrPips <= MaxATRPips AND atrPips >= (MaxATRPips * 0.3):
        volatilityScore = 1.0  // Good volatility
    ELSE IF atrPips > MaxATRPips:
        volatilityScore = 0.0  // Too volatile
    ELSE:
        volatilityScore = 0.3  // Low volatility
    
    score += (spreadScore + volatilityScore) / 2  // Average of spread and volatility
    
    RETURN MathMin(score, maxScore)
```

### Session Filter Check

```
FUNCTION IsSessionAllowed():
    IF NOT UseSessionFilter:
        RETURN true
    
    currentHour = GetServerHour()
    
    // Allow trading during configured session
    IF currentHour >= SessionStartHour AND currentHour < SessionEndHour:
        RETURN true
    
    RETURN false
```

---

## Spread & Volatility Checks

### Spread Validation

```
FUNCTION IsSpreadAcceptable(symbol):
    spreadPips = GetCurrentSpreadPips(symbol)
    
    IF spreadPips > MaxSpreadPips:
        RETURN false
    
    RETURN true
```

```
FUNCTION GetCurrentSpreadPips(symbol):
    ask = MarketInfo(symbol, MODE_ASK)
    bid = MarketInfo(symbol, MODE_BID)
    pipSize = GetPipSize(symbol)
    
    spreadPips = (ask - bid) / pipSize
    RETURN spreadPips
```

### Volatility Validation

```
FUNCTION IsVolatilityAcceptable(symbol):
    atrPips = GetATRPips(symbol, PERIOD_M5, 14)
    
    IF atrPips > MaxATRPips:
        RETURN false
    
    // Also check minimum volatility (avoid dead markets)
    minATRPips = MaxATRPips * 0.2  // At least 20% of max
    IF atrPips < minATRPips:
        RETURN false
    
    RETURN true
```

```
FUNCTION GetATRPips(symbol, timeframe, period):
    atr = iATR(symbol, timeframe, period, 0)
    pipSize = GetPipSize(symbol)
    
    atrPips = atr / pipSize
    RETURN atrPips
```

### Pre-Flight Checks

```
FUNCTION PreFlightChecks(symbol):
    // 1. Check if trading is enabled
    IF NOT TradeEnabled:
        RETURN false
    
    // 2. Check spread
    IF NOT IsSpreadAcceptable(symbol):
        RETURN false
    
    // 3. Check volatility
    IF NOT IsVolatilityAcceptable(symbol):
        RETURN false
    
    // 4. Check session
    IF NOT IsSessionAllowed():
        RETURN false
    
    // 5. Check account equity
    IF AccountEquity() <= 0:
        RETURN false
    
    // 6. Check daily loss limit
    IF GetDailyLossPercent() >= MaxDailyLossPercent:
        RETURN false
    
    // 7. Check max concurrent trades
    IF CountOpenTrades(MagicNumber) >= MaxConcurrentTrades:
        RETURN false
    
    // 8. Check max daily trades
    IF GetDailyTradeCount() >= MaxDailyTrades:
        RETURN false
    
    RETURN true
```

---

## Risk Management Workflow

### Position Sizing

```
FUNCTION CalculatePositionSize(symbol, entryPrice, stopLoss, riskPercent):
    // Calculate risk amount
    riskAmount = AccountEquity() * (riskPercent / 100.0)
    
    // Calculate risk in pips
    pipSize = GetPipSize(symbol)
    riskPips = MathAbs(entryPrice - stopLoss) / pipSize
    
    // Calculate pip value per lot
    pipValuePerLot = GetPipValuePerLot(symbol)
    
    // Calculate lot size
    IF pipValuePerLot > 0 AND riskPips > 0:
        lotSize = riskAmount / (pipValuePerLot * riskPips)
    ELSE:
        RETURN 0.0
    
    // Normalize lot size
    lotSize = NormalizeLot(symbol, lotSize)
    
    // Check margin
    freeMargin = AccountFreeMarginCheck(symbol, OP_BUY, lotSize)
    IF freeMargin < 0:
        // Reduce lot size if margin insufficient
        lotSize = CalculateMaxLotSize(symbol, entryPrice, stopLoss)
    
    RETURN lotSize
```

### Daily Loss Protection

```
FUNCTION GetDailyLossPercent():
    startingBalance = GetDailyStartingBalance()
    currentEquity = AccountEquity()
    
    IF startingBalance <= 0:
        RETURN 0.0
    
    lossPercent = ((startingBalance - currentEquity) / startingBalance) * 100.0
    
    RETURN lossPercent
```

```
FUNCTION CheckDailyLossLimit():
    dailyLossPercent = GetDailyLossPercent()
    
    IF dailyLossPercent >= MaxDailyLossPercent:
        // Close all trades
        CloseAllTrades(MagicNumber)
        RETURN true
    
    RETURN false
```

### Trade Count Management

```
FUNCTION GetDailyTradeCount():
    today = GetTodayDate()
    count = 0
    
    FOR i = OrdersHistoryTotal() - 1 TO 0:
        IF OrderSelect(i, SELECT_BY_POS, MODE_HISTORY):
            IF OrderMagicNumber() == MagicNumber:
                orderDate = GetDateOfDay(OrderCloseTime())
                IF orderDate == today:
                    count++
    
    RETURN count
```

### Complete Risk Management Workflow

```
FUNCTION RiskManagementWorkflow():
    // 1. Check daily loss limit
    IF CheckDailyLossLimit():
        RETURN false  // Trading stopped
    
    // 2. Check max concurrent trades
    IF CountOpenTrades(MagicNumber) >= MaxConcurrentTrades:
        RETURN false  // Max trades reached
    
    // 3. Check max daily trades
    IF GetDailyTradeCount() >= MaxDailyTrades:
        RETURN false  // Daily limit reached
    
    // 4. Check account equity
    IF AccountEquity() <= 0:
        RETURN false  // Invalid equity
    
    RETURN true  // All checks passed
```

---

## Complete Pseudocode

### Main EA Flow

```
PROGRAM QualityGapPro:
    
    // Initialization
    FUNCTION OnInit():
        InitializeGlobalVariables()
        LoadDailyStartingBalance()
        Print("QualityGapPro EA initialized")
        RETURN INIT_SUCCEEDED
    
    // Main tick processing
    FUNCTION OnTick():
        RefreshRates()
        
        // Update daily counters
        UpdateDailyCounters()
        
        // Manage existing trades
        ManageOpenTrades()
        
        // Risk management checks
        IF NOT RiskManagementWorkflow():
            RETURN  // Stop trading if risk limits hit
        
        // Pre-flight checks
        IF NOT PreFlightChecks(TradingSymbol):
            RETURN
        
        // Check if we can open new trade
        IF CountOpenTrades(MagicNumber) >= MaxConcurrentTrades:
            RETURN
        
        // Validate entry
        entryData = ValidateEntry(TradingSymbol)
        
        IF entryData.valid:
            // Calculate position size
            lotSize = CalculatePositionSize(
                TradingSymbol,
                entryData.entry.entryPrice,
                entryData.entry.stopLoss,
                RiskPercentPerTrade
            )
            
            IF lotSize > 0:
                // Place trade
                ticket = PlaceTrade(
                    TradingSymbol,
                    entryData.direction,
                    lotSize,
                    entryData.entry.entryPrice,
                    entryData.entry.stopLoss,
                    entryData.entry.takeProfit,
                    entryData
                )
                
                IF ticket > 0:
                    Print("Quality trade opened: ", ticket, " | Quality Score: ", entryData.qualityScore.total)
                    UpdateDailyTradeCount()
        
        // Update display
        UpdateDashboard()
    
    // Timer for periodic checks
    FUNCTION OnTimer():
        UpdateDashboard()
        CheckDailyReset()
    
    // Daily reset
    FUNCTION CheckDailyReset():
        today = GetTodayDate()
        IF today != lastResetDate:
            lastResetDate = today
            dailyTradeCount = 0
            dailyStartingBalance = AccountBalance()
            Print("Daily reset: New trading day")
```

### Trade Placement

```
FUNCTION PlaceTrade(symbol, direction, lots, entryPrice, stopLoss, takeProfit, entryData):
    orderType = (direction == BULLISH) ? OP_BUY : OP_SELL
    
    // Normalize prices
    digits = (int)MarketInfo(symbol, MODE_DIGITS)
    entryPrice = NormalizeDouble(entryPrice, digits)
    stopLoss = NormalizeDouble(stopLoss, digits)
    takeProfit = NormalizeDouble(takeProfit, digits)
    
    // Create trade comment
    comment = StringConcatenate(
        "QGapPro ",
        (direction == BULLISH) ? "BUY" : "SELL",
        " Q:", DoubleToString(entryData.qualityScore.total, 1)
    )
    
    // Place order
    ticket = OrderSend(
        symbol,
        orderType,
        lots,
        entryPrice,
        SlippagePips,
        stopLoss,
        takeProfit,
        comment,
        MagicNumber,
        0,
        (direction == BULLISH) ? clrBlue : clrRed
    )
    
    IF ticket < 0:
        error = GetLastError()
        Print("OrderSend failed: ", error)
        RETURN -1
    
    // Store trade data for management
    StoreTradeData(ticket, entryData)
    
    RETURN ticket
```

---

## Input Parameters Specification

### Complete Input Parameter List

```mql4
// ==== Symbol Selection ====
input string TradingSymbol = "GBPUSD";  // Trading symbol (GBPUSD or USDJPY)
input bool AutoSelectBestSymbol = true; // Auto-select best opportunity

// ==== Fair Value Gap Settings ====
input ENUM_TIMEFRAMES FVGTimeframe = PERIOD_M5;  // Primary FVG timeframe
input double MinFVGSizePips = 5.0;  // Minimum FVG size in pips
input bool RequireEMABias = true;  // Require EMA alignment
input int EMAFastPeriod = 21;  // Fast EMA period
input int EMASlowPeriod = 55;  // Slow EMA period

// ==== Candlestick Pattern Settings ====
input bool UseEngulfingPatterns = true;  // Enable engulfing patterns
input bool UsePinBars = true;  // Enable pin bar patterns
input bool UseInsideBars = false;  // Enable inside bar patterns
input double MinPinBarRatio = 0.6;  // Minimum pin bar tail ratio (60%)
input double MinEngulfingBodyRatio = 1.2;  // Minimum engulfing body ratio (120%)

// ==== Market Structure Settings ====
input bool UseOrderBlocks = true;  // Enable order block detection
input int OrderBlockLookback = 20;  // Order block lookback period
input bool UseLiquidityZones = true;  // Enable liquidity zone detection
input int LiquidityZoneLookback = 50;  // Liquidity zone lookback
input bool RequireStructureBreak = true;  // Require BOS/CHoCH for entry
input int SwingPointLookback = 5;  // Swing point detection lookback

// ==== Quality Filters ====
input int MinQualityScore = 6;  // Minimum quality score (out of 10)
input bool UseSessionFilter = true;  // Enable session filter
input int SessionStartHour = 8;  // Trading start hour (server time)
input int SessionEndHour = 17;  // Trading end hour (server time)
input double MaxSpreadPips = 2.0;  // Maximum spread (GBPUSD/USDJPY specific)
input double MaxATRPips = 100.0;  // Maximum ATR in pips (volatility cap)

// ==== Risk Management ====
input double RiskPercentPerTrade = 1.0;  // Risk % per trade
input double MinRiskReward = 2.0;  // Minimum risk/reward ratio
input bool UseDynamicStopLoss = true;  // Use structure-based stop loss
input double StructureStopBufferPips = 5.0;  // Stop loss buffer from structure
input int MaxConcurrentTrades = 3;  // Maximum concurrent trades
input int MaxDailyTrades = 50;  // Maximum trades per day
input double MaxDailyLossPercent = 5.0;  // Maximum daily loss %

// ==== Trade Management ====
input bool UsePartialCloses = true;  // Enable partial closes
input double PartialClose1Ratio = 0.5;  // Close 50% at 1R
input double PartialClose2Ratio = 0.3;  // Close 30% at 2R
input bool UseBreakEven = true;  // Enable break-even
input double BreakEvenTriggerPips = 1.5;  // Move to BE after 1.5R profit
input bool UseTrailingStop = true;  // Enable trailing stop
input double TrailingStartPips = 2.0;  // Start trailing after 2R
input double TrailingStepPips = 1.0;  // Trailing step in R multiples
input int MaxHoldSeconds = 3600;  // Maximum hold time (1 hour)
input bool UseTrendReversalProtection = true;  // Close on trend reversal
input int TrendReversalMinHoldSec = 60;  // Minimum hold before reversal check

// ==== Execution Settings ====
input int MagicNumber = 303025;  // Unique EA identifier
input int SlippagePips = 3;  // Maximum slippage
input bool TradeEnabled = true;  // Master trading switch

// ==== Display Settings ====
input bool ShowDashboard = true;  // Show on-chart dashboard
input color DashboardTextColor = clrWhite;  // Dashboard text color
input color DashboardValueColor = clrAqua;  // Dashboard value color
```

---

## Summary

This design document provides a complete blueprint for **QualityGapPro EA**:

✅ **FVG Detection** - Multi-timeframe gap detection with quality assessment  
✅ **Candlestick Patterns** - 7 pattern types with strength scoring  
✅ **Market Structure** - Swings, BOS, CHoCH, Order Blocks  
✅ **Quality Scoring** - 10-point system with minimum threshold  
✅ **Entry Criteria** - Multi-confluence validation  
✅ **Exit Logic** - SL, trailing, partials, BE, time-based, reversal protection  
✅ **Session Filters** - Time-based and quality-based filtering  
✅ **Spread/Volatility** - Pre-flight checks and quality assessment  
✅ **Risk Management** - Position sizing, daily limits, trade count management  
✅ **Complete Pseudocode** - Full implementation flow  

**Next Step:** Review and approve this design before code implementation begins.


