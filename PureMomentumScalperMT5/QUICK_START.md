# 🚀 Quick Start Guide - ICT Strategy EA

## 📦 What You Have

1. **PureMomentumScalperMT5.mq5** - The Expert Advisor
2. **README.md** - Complete installation & configuration guide
3. **TRADING_GUIDE.md** - Exit signals & trading strategy
4. **check_status.sh** - Status checker script (shows when to exit)
5. **QUICK_START.md** - This file (quick reference)

---

## ⚡ 5-Minute Setup

### Step 1: Install EA
```bash
cd /path/to/mt4-mt5-ea-collection
./copy_puremomentum_ict_to_mt5.sh
```

### Step 2: Compile in MetaEditor
1. Open MT5 → Press **F4** (MetaEditor)
2. Find `PureMomentumScalperMT5.mq5` in Navigator
3. Press **F7** to compile
4. Verify: **0 errors, 0 warnings**

### Step 3: Attach to Chart
1. Open **USDJPY** chart (M1 or M5)
2. Drag EA onto chart
3. Enable **AutoTrading** (green button)
4. Click **OK**

**Done! ✅**

---

## 📊 Check Status Anytime

Run this command to see:
- Current trading session status
- Exit signal guide
- Monitoring checklist
- Decision matrix

```bash
cd PureMomentumScalperMT5
./check_status.sh
```

**Or copy/paste the output to chat for help!**

---

## 🎯 When to Exit - Quick Reference

### ✅ CLOSE TRADE (Take Profit)
- Price hits **previous high/low** (liquidity)
- Trade reaches **1:2 Risk/Reward**
- **Equal highs/lows** hit

### ⚠️ PARTIAL CLOSE (50%)
- Order Block getting **mitigated**
- FVG zone **filling**
- **Opposite structure** forming
- **Session ending** soon

### 🔴 EMERGENCY EXIT (Close All)
- HTF bias **reversed**
- Order Block **fully mitigated**
- **High-impact news** approaching
- **Spread > 5 pips**

---

## 📱 Use in Chat

### Copy Status to Chat:
```bash
./check_status.sh
```
Then paste the output - shows everything you need!

### Ask for Help:
```
"Check my EA status"
"Should I exit now?"
"Is it a good time to trade?"
```

---

## 📚 Full Documentation

- **README.md** - Everything about installation & settings
- **TRADING_GUIDE.md** - Detailed exit signals & strategy
- **check_status.sh** - Real-time status checker

---

## 💡 Pro Tip

**Run the status checker every hour:**
```bash
./check_status.sh
```

It will tell you:
- ✅ If trading session is active
- ✅ What exit signals to watch for
- ✅ What to monitor
- ✅ When to take action

---

## 🆘 Need Help?

1. **Check Status**: `./check_status.sh`
2. **Read README.md** for installation issues
3. **Read TRADING_GUIDE.md** for exit signals
4. **Check MT5 Expert tab** for EA errors

---

**Happy Trading! 🚀**



