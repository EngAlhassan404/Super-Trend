//+------------------------------------------------------------------+
//|                                              Super Trend EA.mq5  |
//|                               Supertrend with Telegram Alerts    |
//|                 Copyright 2026, Eng. Alhassan Ali Mubarak Bahbah |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Eng. Alhassan Ali Mubarak Bahbah"
#property version   "4.00"

#include <Canvas\Canvas.mqh>

#define CANVAS_NAME "SupertrendCanvas_EA"
#define ARROW_PREFIX "ST_ARROW_"

//--- Input Parameters
input group "Supertrend Calculation"
input ENUM_TIMEFRAMES CalcTimeframe   = PERIOD_CURRENT;  // Calculation Timeframe
input int             AtrPeriod       = 10;              // ATR Period
input double          AtrMultiplier   = 3.0;             // ATR Multiplier

input group "Buy/Sell Signals"
input bool            ShowSignals     = true;            // Show Buy/Sell Arrows

input group "Trend Visuals"
input bool            ShowCloud       = true;            // Show Trend Cloud
input color           CloudUpColor    = clrLimeGreen;    // Uptrend Cloud Color
input color           CloudDownColor  = clrRed;          // Downtrend Cloud Color
input uchar           CloudOpacity    = 60;              // Cloud Opacity (0-255)
input color           LineUpColor     = clrGreen;        // Uptrend Line Color
input color           LineDownColor   = clrRed;          // Downtrend Line Color

input group "Telegram Notifications"
input bool            EnableTelegram  = true;            // تفعيل إشعارات تيليجرام
input string          TelegramToken   = "YOUR_BOT_TOKEN";// توكن البوت
input string          TelegramChatID  = "YOUR_CHAT_ID";  // معرف المحادثة (Chat ID)

input group "Debugging"
input bool            DebugMode       = false;           // Print Debug Messages

//--- Global Buffers
double UpBuffer[];
double DnBuffer[];
double TrendBuffer[];
double MidBuffer[];

//--- Graphics & State
CCanvas  Canvas;
int      chart_width         = 0;
int      chart_height        = 0;
int      chart_scale         = 0;
int      chart_first_vis_bar = 0;
int      chart_vis_bars      = 0;
double   chart_prcmin        = 0.0;
double   chart_prcmax        = 0.0;
int      atrHandle           = INVALID_HANDLE;

int      g_last_width        = 0;
int      g_last_height       = 0;
int      g_last_scale        = 0;
int      g_last_first_bar    = 0;
int      g_last_vis_bars     = 0;
double   g_last_prcmin       = 0.0;
double   g_last_prcmax       = 0.0;
int      g_last_rates_total  = 0;
int      g_last_live_y1      = -1;
int      g_last_live_y2      = -1;

int      prev_calculated     = 0;
datetime last_alert_time     = 0;
bool     g_data_ready        = false;
bool     is_first_run        = true;

const double PRICE_EPSILON = 0.0000001;

//+------------------------------------------------------------------+
//| Utility Functions                                                |
//+------------------------------------------------------------------+
bool DoubleChanged(double a, double b) { return MathAbs(a - b) > PRICE_EPSILON; }
int BarWidth(int scale) { return (int)MathPow(2, scale); }
int ShiftToX(int shift) { return (chart_first_vis_bar - shift) * BarWidth(chart_scale) - 1; }
int PriceToY(double price) {
   if(chart_prcmax - chart_prcmin == 0.0) return 0;
   return (int)MathRound(chart_height * (chart_prcmax - price) / (chart_prcmax - chart_prcmin) - 1);
}

void UpdateChartProperties() {
   chart_width         = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   chart_height        = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   chart_scale         = (int)ChartGetInteger(0, CHART_SCALE);
   chart_first_vis_bar = (int)ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR);
   chart_vis_bars      = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);
   chart_prcmin        = ChartGetDouble(0, CHART_PRICE_MIN, 0);
   chart_prcmax        = ChartGetDouble(0, CHART_PRICE_MAX, 0);
}

//+------------------------------------------------------------------+
//| Telegram WebRequest                                              |
//+------------------------------------------------------------------+
bool SendTelegramMessage(string message) {
    if(!EnableTelegram || TelegramToken == "" || TelegramChatID == "" || TelegramToken == "YOUR_BOT_TOKEN") return false;
    
    string url = "https://api.telegram.org/bot" + TelegramToken + "/sendMessage";
    char post[], result[];
    string headers = "Content-Type: application/json\r\n";
    
    string msg_json = message;
    StringReplace(msg_json, "\\", "\\\\");
    StringReplace(msg_json, "\n", "\\n");
    StringReplace(msg_json, "\r", "");
    StringReplace(msg_json, "\"", "\\\"");
    
    string payload = "{\"chat_id\":\"" + TelegramChatID + "\",\"text\":\"" + msg_json + "\",\"parse_mode\":\"HTML\"}";
    StringToCharArray(payload, post, 0, WHOLE_ARRAY, CP_UTF8);
    
    string res_headers;
    int timeout = 5000;
    
    int res = WebRequest("POST", url, headers, timeout, post, result, res_headers);
    if(res == 200) {
        if(DebugMode) Print("Telegram message sent successfully.");
        return true;
    } else {
        Print("Failed to send Telegram message. Error code: ", GetLastError(), " HTTP code: ", res);
        return false;
    }
}

//+------------------------------------------------------------------+
//| Arrows Management                                                |
//+------------------------------------------------------------------+
void CreateArrow(datetime time, double price, bool isBuy) {
    string name = ARROW_PREFIX + TimeToString(time);
    if(ObjectFind(0, name) < 0) {
        ObjectCreate(0, name, OBJ_ARROW, 0, time, price);
        ObjectSetInteger(0, name, OBJPROP_ARROWCODE, isBuy ? 233 : 234);
        ObjectSetInteger(0, name, OBJPROP_COLOR, isBuy ? LineUpColor : LineDownColor);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
        ObjectSetInteger(0, name, OBJPROP_ANCHOR, isBuy ? ANCHOR_TOP : ANCHOR_BOTTOM);
        ObjectSetInteger(0, name, OBJPROP_BACK, false);
        ObjectSetInteger(0, name, OBJPROP_HIDDEN, true); // hide from object list
    } else {
        ObjectSetDouble(0, name, OBJPROP_PRICE, price);
    }
}

void DeleteArrows() {
    int total = ObjectsTotal(0, 0, OBJ_ARROW);
    for(int i = total - 1; i >= 0; i--) {
        string name = ObjectName(0, i, 0, OBJ_ARROW);
        if(StringFind(name, ARROW_PREFIX) == 0) {
            ObjectDelete(0, name);
        }
    }
}

//+------------------------------------------------------------------+
//| EA Initialization                                                |
//+------------------------------------------------------------------+
int OnInit() {
    ObjectDelete(0, CANVAS_NAME);
    if(!Canvas.CreateBitmapLabel(0, 0, CANVAS_NAME, 0, 0, 200, 150, COLOR_FORMAT_ARGB_NORMALIZE)) {
        Print("Error creating canvas bitmap label");
        return INIT_FAILED;
    }

    atrHandle = iATR(_Symbol, CalcTimeframe, AtrPeriod);
    if(atrHandle == INVALID_HANDLE) {
        Print("Error creating ATR handle");
        return INIT_FAILED;
    }
    
    if(EnableTelegram) {
        Print("Telegram is Enabled. Please ensure https://api.telegram.org is added to Tools -> Options -> Expert Advisors -> Allow WebRequest for listed URL");
    }

    g_last_width       = 0;
    g_last_height      = 0;
    g_last_scale       = 0;
    g_last_first_bar   = 0;
    g_last_vis_bars    = 0;
    g_last_prcmin      = 0.0;
    g_last_prcmax      = 0.0;
    g_last_rates_total = 0;
    g_last_live_y1     = -1;
    g_last_live_y2     = -1;
    
    prev_calculated    = 0;
    g_data_ready       = false;
    is_first_run       = true;

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EA Deinitialization                                              |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    Canvas.Destroy();
    ObjectDelete(0, CANVAS_NAME);
    DeleteArrows();
    ChartRedraw(0);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| Canvas Drawing                                                   |
//+------------------------------------------------------------------+
void DrawFillingCanvas(bool forceRedraw) {
    if(!g_data_ready) return;

    UpdateChartProperties();
    if(chart_width <= 0 || chart_height <= 0) return;

    int limit = ArraySize(UpBuffer);
    if(limit == 0) return;

    int liveBarIndex     = limit - 1;
    double liveTrendValue = (TrendBuffer[liveBarIndex] == 1) ? UpBuffer[liveBarIndex] : DnBuffer[liveBarIndex];
    double liveMidValue   = MidBuffer[liveBarIndex];

    int liveY1 = PriceToY(liveTrendValue);
    int liveY2 = PriceToY(liveMidValue);

    bool stateChanged = (chart_width != g_last_width ||
                         chart_height != g_last_height ||
                         chart_scale != g_last_scale ||
                         chart_first_vis_bar != g_last_first_bar ||
                         chart_vis_bars != g_last_vis_bars ||
                         DoubleChanged(chart_prcmin, g_last_prcmin) ||
                         DoubleChanged(chart_prcmax, g_last_prcmax) ||
                         limit != g_last_rates_total ||
                         liveY1 != g_last_live_y1 ||
                         liveY2 != g_last_live_y2);

    if(!forceRedraw && !stateChanged) return;

    g_last_width       = chart_width;
    g_last_height      = chart_height;
    g_last_scale       = chart_scale;
    g_last_first_bar   = chart_first_vis_bar;
    g_last_vis_bars    = chart_vis_bars;
    g_last_prcmin      = chart_prcmin;
    g_last_prcmax      = chart_prcmax;
    g_last_rates_total = limit;
    g_last_live_y1     = liveY1;
    g_last_live_y2     = liveY2;

    if(chart_width != Canvas.Width() || chart_height != Canvas.Height())
       Canvas.Resize(chart_width, chart_height);

    Canvas.Erase(0);

    uint argbUp     = ColorToARGB(CloudUpColor, CloudOpacity);
    uint argbDown   = ColorToARGB(CloudDownColor, CloudOpacity);
    uint argbLineUp = ColorToARGB(LineUpColor, 255);
    uint argbLineDn = ColorToARGB(LineDownColor, 255);

    int  prevX = 0, prevY1 = 0, prevY2 = 0;
    bool havePrevPoint = false;

    for(int i = 0; i < chart_vis_bars; i++) {
        int barShift = chart_first_vis_bar - i;
        int barIndex = limit - 1 - barShift;

        if(barIndex < 0 || barIndex >= limit) {
            havePrevPoint = false;
            continue;
        }

        double trendValue = (TrendBuffer[barIndex] == 1) ? UpBuffer[barIndex] : DnBuffer[barIndex];
        double midValue   = MidBuffer[barIndex];

        if(trendValue == EMPTY_VALUE || midValue == EMPTY_VALUE) {
            havePrevPoint = false;
            continue;
        }

        int x  = ShiftToX(barShift);
        int y1 = PriceToY(trendValue);
        int y2 = PriceToY(midValue);

        uint segmentColor = (TrendBuffer[barIndex] == 1) ? argbUp : argbDown;
        uint lineColor    = (TrendBuffer[barIndex] == 1) ? argbLineUp : argbLineDn;

        if(havePrevPoint) {
            if(ShowCloud) {
                if(prevY1 != prevY2) Canvas.FillTriangle(prevX, prevY1, prevX, prevY2, x, y1, segmentColor);
                if(y1 != y2) Canvas.FillTriangle(prevX, prevY2, x, y1, x, y2, segmentColor);
            }
            
            // Draw Thick Trend Line (using 3 adjacent lines to simulate thickness)
            Canvas.Line(prevX, prevY1, x, y1, lineColor);
            Canvas.Line(prevX, prevY1-1, x, y1-1, lineColor);
            Canvas.Line(prevX, prevY1+1, x, y1+1, lineColor);
        }

        prevX  = x;
        prevY1 = y1;
        prevY2 = y2;
        havePrevPoint = true;
    }

    Canvas.Update();
}

//+------------------------------------------------------------------+
//| Chart Event Handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam) {
    if(id == CHARTEVENT_CHART_CHANGE) {
        DrawFillingCanvas(true);
    }
}

//+------------------------------------------------------------------+
//| EA Main Logic (OnTick)                                           |
//+------------------------------------------------------------------+
void OnTick() {
    int rates_total = iBars(_Symbol, CalcTimeframe);
    if(rates_total < AtrPeriod + 2) return;

    MqlRates rates[];
    if(CopyRates(_Symbol, CalcTimeframe, 0, rates_total, rates) != rates_total) return;
    
    double atrValues[];
    if(CopyBuffer(atrHandle, 0, 0, rates_total, atrValues) != rates_total) return;

    // Detect history shifts to prevent calculation errors
    static datetime history_first_bar = 0;
    if(history_first_bar != rates[0].time || ArraySize(UpBuffer) != rates_total) {
        if(history_first_bar != rates[0].time) prev_calculated = 0;
        history_first_bar = rates[0].time;
        
        ArrayResize(UpBuffer, rates_total);
        ArrayResize(DnBuffer, rates_total);
        ArrayResize(TrendBuffer, rates_total);
        ArrayResize(MidBuffer, rates_total);
    }

    int startBar = (prev_calculated <= 1) ? AtrPeriod + 1 : prev_calculated - 1;
    if(startBar >= rates_total) startBar = rates_total - 1;

    for(int i = startBar; i < rates_total; i++) {
        double src = (rates[i].high + rates[i].low) / 2.0;
        double atr = atrValues[i];

        double up_basic = src - (AtrMultiplier * atr);
        double dn_basic = src + (AtrMultiplier * atr);

        double up_prev = (i > 0 && UpBuffer[i-1] != EMPTY_VALUE && UpBuffer[i-1] > 0) ? UpBuffer[i-1] : up_basic;
        double dn_prev = (i > 0 && DnBuffer[i-1] != EMPTY_VALUE && DnBuffer[i-1] > 0) ? DnBuffer[i-1] : dn_basic;

        UpBuffer[i]  = (i > 0 && rates[i-1].close > up_prev) ? MathMax(up_basic, up_prev) : up_basic;
        DnBuffer[i]  = (i > 0 && rates[i-1].close < dn_prev) ? MathMin(dn_basic, dn_prev) : dn_basic;
        MidBuffer[i] = (rates[i].open + rates[i].close) / 2.0;

        int prevTrendLocal = (i > 0 && TrendBuffer[i-1] != 0 && TrendBuffer[i-1] != EMPTY_VALUE) ? (int)TrendBuffer[i-1] : 1;
        int trend = prevTrendLocal;

        if(prevTrendLocal == -1 && rates[i].close > DnBuffer[i-1])      trend = 1;
        else if(prevTrendLocal == 1 && rates[i].close < UpBuffer[i-1]) trend = -1;

        TrendBuffer[i] = trend;

        // Draw Signals using Objects
        if(ShowSignals) {
            if(trend == 1 && prevTrendLocal == -1) {
                CreateArrow(rates[i].time, UpBuffer[i], true);
            }
            else if(trend == -1 && prevTrendLocal == 1) {
                CreateArrow(rates[i].time, DnBuffer[i], false);
            }
        }
    }
    
    prev_calculated = rates_total;
    g_data_ready = true;

    // --- TELEGRAM LOGIC ---
    if(rates_total >= 3) {
        int current_closed = rates_total - 2;
        int prev_closed    = rates_total - 3;
        
        // Prevent sending old signals instantly on the first launch
        if(is_first_run) {
            last_alert_time = rates[current_closed].time;
            is_first_run = false;
        } else if (EnableTelegram) {
            int t1 = (int)TrendBuffer[current_closed];
            int t2 = (int)TrendBuffer[prev_closed];
            datetime time_closed = rates[current_closed].time;
            
            // Trigger alert only when trend changes on a closed bar
            if(t1 != t2 && last_alert_time != time_closed) {
                last_alert_time = time_closed;
                
                string trend_str = (t1 == 1) ? "أحمر 🔴 إلى أخضر 🟢 (صعود)" : "أخضر 🟢 إلى أحمر 🔴 (هبوط)";
                double price_val = rates[current_closed].close;
                
                string msg = "🟢 <b>إشارة انعكاس - سوبر تريند</b> 🟢\n\n";
                msg += "📌 <b>الأصل المالي:</b> " + _Symbol + "\n";
                msg += "⏱️ <b>الإطار الزمني:</b> " + EnumToString(CalcTimeframe) + "\n";
                msg += "🔄 <b>الاتجاه:</b> تحول من " + trend_str + "\n";
                msg += "💲 <b>السعر عند التأكيد:</b> " + DoubleToString(price_val, _Digits) + "\n";
                
                SendTelegramMessage(msg);
            }
        }
    }
    
    DrawFillingCanvas(false);
}
