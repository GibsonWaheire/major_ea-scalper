# JAson.mqh Library Guide

## 📍 Where to Find JAson.mqh

### Option 1: MQL5 Standard Library (Built-in) ✅

**JAson.mqh is included with MetaTrader 5!** You don't need to download it separately.

#### Location in MT5 Installation:

**Windows:**
```
C:\Program Files\MetaTrader 5\MQL5\Include\Standard Library\Json.mqh
```

**macOS:**
```
~/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Include/Standard Library/Json.mqh
```

**Linux:**
```
~/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Include/Standard Library/Json.mqh
```

#### How to Access:

**Method 1: Through MetaEditor**
1. Open **MetaTrader 5**
2. Press **F4** to open **MetaEditor**
3. In the **Navigator** panel (left side), expand:
   - `Include` folder
   - `Standard Library` subfolder
   - Look for `Json.mqh` (note: it's `Json.mqh`, not `JAson.mqh`)

**Method 2: Through File Explorer**
1. In MetaTrader 5, go to **File** → **Open Data Folder**
2. Navigate to: `MQL5\Include\Standard Library\`
3. You'll find `Json.mqh` there

---

## 🔧 How to Use It

### Current Code Issue

The current `FinnhubEconomicCalendar.mqh` uses:
```mql5
#include <JAson.mqh>  // This won't work!
```

### Correct Include Statement

Update the include statement to:
```mql5
#include <Standard Library\Json.mqh>  // Correct path
```

**Note**: The file is named `Json.mqh` (capital J, lowercase son), not `JAson.mqh`.

---

## 📝 Step-by-Step Integration

### Step 1: Update FinnhubEconomicCalendar.mqh

1. Open `FinnhubEconomicCalendar.mqh` in MetaEditor
2. Find line 9:
   ```mql5
   #include <JAson.mqh>  // JSON parsing library (you may need to add this)
   ```
3. Replace with:
   ```mql5
   #include <Standard Library\Json.mqh>  // MQL5 Standard Library JSON parser
   ```

### Step 2: Update JSON Parsing Functions

The current code uses basic string parsing. With `Json.mqh`, you can use proper JSON parsing:

**Example:**
```mql5
// Old way (basic string parsing)
string timeStr = StringSubstr(eventJson, timeStart, timeEnd - timeStart);

// New way (using Json.mqh)
CJsonParser parser;
CJsonObject* root = parser.Parse(jsonString);
if(root != NULL)
{
   CJsonArray* calendar = root.GetArray("economicCalendar");
   // Parse events properly
}
```

---

## 🚀 Quick Fix: Update the Include

Let me update the file for you:

**File to update**: `FinnhubEconomicCalendar.mqh`

**Change line 9 from:**
```mql5
#include <JAson.mqh>  // JSON parsing library (you may need to add this)
```

**To:**
```mql5
#include <Standard Library\Json.mqh>  // MQL5 Standard Library JSON parser
```

---

## ✅ Verification

### Check if Json.mqh Exists:

1. Open MetaEditor (F4)
2. Navigate to: `Include` → `Standard Library`
3. Look for `Json.mqh`
4. If you see it, you're good to go!

### If Json.mqh is Missing:

**Option A: Update MT5**
- Make sure you have the latest version of MetaTrader 5
- Standard Library comes with MT5 installation

**Option B: Download from MQL5 Community**
- Visit: https://www.mql5.com/en/code
- Search for "Json.mqh" or "JSON parser"
- Download and place in `MQL5/Include/` folder

**Option C: Use Alternative Library**
- Search MQL5 CodeBase for "JSON" libraries
- Popular alternatives: `JAson.mqh`, `JSON.mqh`

---

## 📚 Json.mqh Documentation

### Common Functions:

```mql5
// Parse JSON string
CJsonParser parser;
CJsonObject* root = parser.Parse(jsonString);

// Get array
CJsonArray* array = root.GetArray("economicCalendar");

// Get object from array
CJsonObject* event = array.GetObject(0);

// Get string value
string currency = event.GetString("currency");

// Get number value
double time = event.GetNumber("time");

// Get boolean value
bool released = event.GetBool("isReleased");
```

---

## 🔄 Current Implementation Status

### Current Code:
- ✅ Uses basic string parsing (works but limited)
- ⚠️ Include statement needs fixing
- ✅ Will work without Json.mqh (basic parsing)

### With Json.mqh:
- ✅ Proper JSON parsing
- ✅ More robust error handling
- ✅ Better support for nested structures
- ✅ Recommended for production use

---

## 🎯 Recommendation

### For Testing (Current):
- Keep basic string parsing
- Fix include statement (even if not using it)
- Works fine for simple JSON structures

### For Production:
- Update to use `Json.mqh` properly
- Rewrite parsing functions to use CJsonParser
- More reliable and maintainable

---

## 📝 Next Steps

1. **Verify Json.mqh exists** in your MT5 installation
2. **Update include statement** in `FinnhubEconomicCalendar.mqh`
3. **Test compilation** - should compile without errors
4. **Optional**: Rewrite parsing to use Json.mqh functions (for better reliability)

---

## 🔗 Additional Resources

- **MQL5 Standard Library**: https://www.mql5.com/en/docs/standardlibrary
- **MQL5 CodeBase**: https://www.mql5.com/en/code (search for JSON)
- **MT5 Documentation**: https://www.mql5.com/en/docs

---

**Summary**: `Json.mqh` is already in your MT5 installation at `MQL5/Include/Standard Library/Json.mqh`. Just update the include statement to use the correct path!


