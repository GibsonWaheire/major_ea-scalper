#!/bin/bash

# ICT Strategy EA Status Checker
# This script helps you monitor your EA and understand when to exit

echo "=========================================="
echo "  ICT Strategy EA - Status Checker"
echo "  Pure Momentum Scalper for USDJPY"
echo "=========================================="
echo ""

# Get current time
CURRENT_TIME=$(date +"%H:%M")
CURRENT_HOUR=$(date +"%H")

echo "📅 Current Time: $CURRENT_TIME GMT"
echo ""

# Check if in trading session
LONDON_START=8
LONDON_END=16
NY_START=13
NY_END=21

IN_LONDON=false
IN_NY=false

if [ $CURRENT_HOUR -ge $LONDON_START ] && [ $CURRENT_HOUR -lt $LONDON_END ]; then
    IN_LONDON=true
    echo "✅ LONDON SESSION: ACTIVE (8:00-16:00 GMT)"
else
    echo "❌ LONDON SESSION: INACTIVE"
fi

if [ $CURRENT_HOUR -ge $NY_START ] && [ $CURRENT_HOUR -lt $NY_END ]; then
    IN_NY=true
    echo "✅ NY SESSION: ACTIVE (13:00-21:00 GMT)"
else
    echo "❌ NY SESSION: INACTIVE"
fi

if [ "$IN_LONDON" = true ] || [ "$IN_NY" = true ]; then
    echo ""
    echo "🟢 TRADING SESSION: ACTIVE - EA can trade"
else
    echo ""
    echo "🔴 TRADING SESSION: INACTIVE - EA will not enter new trades"
    echo "   (Wait for London 8:00 GMT or NY 13:00 GMT)"
fi

echo ""
echo "=========================================="
echo "  EXIT SIGNAL GUIDE"
echo "=========================================="
echo ""

echo "🟢 TAKE PROFIT (Close Trade):"
echo "   ✅ Price reaches previous high/low (liquidity)"
echo "   ✅ Trade reaches 1:2 Risk/Reward minimum"
echo "   ✅ Equal highs/lows hit"
echo ""

echo "🟡 PARTIAL CLOSE (Close 50%):"
echo "   ⚠️  Order Block starting to get mitigated"
echo "   ⚠️  FVG zone getting filled"
echo "   ⚠️  Opposite structure forming on HTF"
echo "   ⚠️  Session ending soon"
echo ""

echo "🔴 EMERGENCY EXIT (Close Immediately):"
echo "   🚨 HTF bias reversed (structure break)"
echo "   🚨 Order Block fully mitigated"
echo "   🚨 High-impact news approaching"
echo "   🚨 Spread > 5 pips"
echo "   🚨 Opposite FVG created"
echo ""

echo "=========================================="
echo "  MONITORING CHECKLIST"
echo "=========================================="
echo ""

echo "Check Every 15 Minutes:"
echo "  [ ] HTF structure still valid?"
echo "  [ ] Order Block still valid (not mitigated)?"
echo "  [ ] FVG still open (not filled)?"
echo "  [ ] Spread still acceptable (< 3 pips)?"
echo ""

echo "Check Every Hour:"
echo "  [ ] Overall market structure review"
echo "  [ ] Upcoming news events?"
echo "  [ ] Session still active?"
echo ""

echo "Before Session Close:"
echo "  [ ] TP close? (within 10-20 pips)"
echo "  [ ] Hold overnight or close?"
echo "  [ ] Consider partial close?"
echo ""

echo "=========================================="
echo "  QUICK DECISION MATRIX"
echo "=========================================="
echo ""

echo "Signal                    | Action              | Priority"
echo "--------------------------|---------------------|----------"
echo "TP Hit (Liquidity)        | ✅ Close Trade      | HIGH"
echo "TP Hit (RR Target)        | ✅ Close Trade      | HIGH"
echo "OB Mitigation Started     | ⚠️  Partial Close   | MEDIUM"
echo "FVG Filling               | ⚠️  Partial Close   | MEDIUM"
echo "HTF Bias Reversed         | 🔴 Close Immediately| CRITICAL"
echo "OB Fully Mitigated        | 🔴 Close Immediately| CRITICAL"
echo "News Approaching          | 🔴 Close Immediately| CRITICAL"
echo "Spread > 5 pips           | 🔴 Close Immediately| CRITICAL"
echo ""

echo "=========================================="
echo "  IMPORTANT REMINDERS"
echo "=========================================="
echo ""

echo "✅ EA will NOT exit early - trades hold to TP"
echo "✅ Only exit at TP, SL, or manual close"
echo "✅ Monitor HTF chart (M15/H1) for bias changes"
echo "✅ Watch for OB mitigation signals"
echo "✅ Respect liquidity levels (previous highs/lows)"
echo ""

echo "❌ Don't trade without HTF bias"
echo "❌ Don't ignore OB mitigation"
echo "❌ Don't trade during news"
echo "❌ Don't overtrade - wait for quality setups"
echo ""

echo "=========================================="
echo "  NEXT STEPS"
echo "=========================================="
echo ""

if [ "$IN_LONDON" = true ] || [ "$IN_NY" = true ]; then
    echo "1. ✅ Check MT5 chart for open positions"
    echo "2. ✅ Monitor HTF structure (M15/H1)"
    echo "3. ✅ Watch for exit signals above"
    echo "4. ✅ Set alerts for TP approaching"
else
    echo "1. ⏳ Wait for trading session to start"
    echo "2. 📊 Review HTF structure while waiting"
    echo "3. 📝 Plan your exit strategy"
    echo "4. 🔔 Set alerts for session start"
fi

echo ""
echo "For detailed information, see:"
echo "  - README.md (Installation & Configuration)"
echo "  - TRADING_GUIDE.md (Exit Signals & Strategy)"
echo ""
echo "=========================================="






