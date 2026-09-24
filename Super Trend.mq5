//+------------------------------------------------------------------+
//|                                  SuperTrend.mq5                  |
//|                               Supertrend with Transparent Canvas |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Eng. Alhassan Ali Mubarak Bahbah"
#property version   "4.00"
#property indicator_chart_window
#property indicator_buffers 8
#property indicator_plots   4

#include <Canvas\Canvas.mqh>

#define CANVAS_NAME "SupertrendCanvas"

#property indicator_label1  "Up Trend"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrGreen
#property indicator_width1  2

#property indicator_label2  "Down Trend"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrRed
#property indicator_width2  2

#property indicator_label3  "Buy Signal"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrGreen
#property indicator_width3  2

#property indicator_label4  "Sell Signal"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrRed
#property indicator_width4  2

input group "Supertrend Calculation"
input ENUM_TIMEFRAMES CalcTimeframe   = PERIOD_CURRENT;  // Calculation Timeframe
input int              AtrPeriod      = 10;               // ATR Period
input double            AtrMultiplier  = 3.0;              // ATR Multiplier

input group "Buy/Sell Signals"
input bool              ShowSignals    = true;             // Show Buy/Sell Arrows

input group "Trend Cloud"
input bool              ShowCloud          = true;         // Show Trend Cloud
input color              CloudUpColor       = clrLimeGreen; // Uptrend Cloud Color
input color              CloudDownColor     = clrRed;       // Downtrend Cloud Color
input uchar              CloudOpacity       = 60;           // Cloud Opacity (0=Transparent, 255=Opaque)

input group "Debugging"
input bool              DebugMode          = false;         // Print Debug Messages to Experts Log

double UpTrendBuffer[];
double DnTrendBuffer[];
double BuySignalBuffer[];
double SellSignalBuffer[];
double UpBuffer[];
double DnBuffer[];
double TrendBuffer[];
double MidBuffer[];

CCanvas Canvas;
int      chart_width         = 0;
int      chart_height        = 0;
int      chart_scale         = 0;
int      chart_first_vis_bar = 0;
int      chart_vis_bars      = 0;
double   chart_prcmin        = 0.0;
double   chart_prcmax        = 0.0;
int      atrHandle           = INVALID_HANDLE;

// Cached state used to decide whether the cloud actually needs a redraw
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

// True only once a full OnCalculate pass has completed successfully.
// DrawFillingCanvas must never paint while this is false, regardless
// of what triggered it (OnCalculate or OnChartEvent).
bool     g_data_ready         = false;

const double PRICE_EPSILON = 0.0000001;

//+------------------------------------------------------------------+
bool DoubleChanged(double a, double b)
{
   return MathAbs(a - b) > PRICE_EPSILON;
}

//+------------------------------------------------------------------+
int BarWidth(int scale)
{
   return (int)MathPow(2, scale);
}

//+------------------------------------------------------------------+
int ShiftToX(int shift)
{
   return (chart_first_vis_bar - shift) * BarWidth(chart_scale) - 1;
}

//+------------------------------------------------------------------+
int PriceToY(double price)
{
   if(chart_prcmax - chart_prcmin == 0.0) return 0;
   return (int)MathRound(chart_height * (chart_prcmax - price) / (chart_prcmax - chart_prcmin) - 1);
}

//+------------------------------------------------------------------+
void UpdateChartProperties()
{
   chart_width         = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   chart_height         = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   chart_scale          = (int)ChartGetInteger(0, CHART_SCALE);
   chart_first_vis_bar  = (int)ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR);
   chart_vis_bars       = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);
   chart_prcmin         = ChartGetDouble(0, CHART_PRICE_MIN, 0);
   chart_prcmax         = ChartGetDouble(0, CHART_PRICE_MAX, 0);
}

//+------------------------------------------------------------------+
int OnInit()
{
   SetIndexBuffer(0, UpTrendBuffer,    INDICATOR_DATA);
   SetIndexBuffer(1, DnTrendBuffer,    INDICATOR_DATA);
   SetIndexBuffer(2, BuySignalBuffer,  INDICATOR_DATA);
   SetIndexBuffer(3, SellSignalBuffer, INDICATOR_DATA);
   SetIndexBuffer(4, UpBuffer,         INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, DnBuffer,         INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, TrendBuffer,      INDICATOR_CALCULATIONS);
   SetIndexBuffer(7, MidBuffer,        INDICATOR_CALCULATIONS);

   PlotIndexSetInteger(2, PLOT_ARROW, 233);
   PlotIndexSetInteger(3, PLOT_ARROW, 234);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   ObjectDelete(0, CANVAS_NAME);

   if(!Canvas.CreateBitmapLabel(0, 0, CANVAS_NAME, 0, 0, 200, 150, COLOR_FORMAT_ARGB_NORMALIZE))
   {
      Print("Error creating canvas bitmap label");
      return INIT_FAILED;
   }

   atrHandle = iATR(_Symbol, CalcTimeframe, AtrPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("Error creating ATR handle");
      return INIT_FAILED;
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
   g_data_ready       = false;

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Canvas.Destroy();
   ObjectDelete(0, CANVAS_NAME);
   ChartRedraw(0);

   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
void DrawFillingCanvas(bool forceRedraw)
{
   if(!ShowCloud)
   {
      Canvas.Erase(0);
      Canvas.Update();
      return;
   }

   // Never paint from a stale or partially-computed buffer state, no
   // matter what triggered this call (OnCalculate or OnChartEvent).
   if(!g_data_ready)
      return;

   UpdateChartProperties();

   if(chart_width <= 0 || chart_height <= 0)
   {
      if(DebugMode)
         Print("DrawFillingCanvas: invalid chart dimensions, skipping redraw");
      return;
   }

   int limit = ArraySize(UpBuffer);
   if(limit == 0)
      return;

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

   // forceRedraw only bypasses the "nothing changed" shortcut above.
   // It must never bypass the g_data_ready guard checked earlier.
   if(!forceRedraw && !stateChanged)
      return;

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

   uint argbUp   = ColorToARGB(CloudUpColor, CloudOpacity);
   uint argbDown = ColorToARGB(CloudDownColor, CloudOpacity);

   int  prevX = 0, prevY1 = 0, prevY2 = 0;
   bool havePrevPoint = false;

   for(int i = 0; i < chart_vis_bars; i++)
   {
      int barShift = chart_first_vis_bar - i;
      int barIndex = limit - 1 - barShift;

      if(barIndex < 0 || barIndex >= limit)
      {
         havePrevPoint = false;
         continue;
      }

      double trendValue = (TrendBuffer[barIndex] == 1) ? UpBuffer[barIndex] : DnBuffer[barIndex];
      double midValue    = MidBuffer[barIndex];

      if(trendValue == EMPTY_VALUE || midValue == EMPTY_VALUE)
      {
         havePrevPoint = false;
         continue;
      }

      int x  = ShiftToX(barShift);
      int y1 = PriceToY(trendValue);
      int y2 = PriceToY(midValue);

      uint segmentColor = (TrendBuffer[barIndex] == 1) ? argbUp : argbDown;

      if(havePrevPoint)
      {
         if(prevY1 != prevY2)
            Canvas.FillTriangle(prevX, prevY1, prevX, prevY2, x, y1, segmentColor);
         if(y1 != y2)
            Canvas.FillTriangle(prevX, prevY2, x, y1, x, y2, segmentColor);
      }

      prevX  = x;
      prevY1 = y1;
      prevY2 = y2;
      havePrevPoint = true;
   }

   Canvas.Update();
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total < AtrPeriod + 2)
      return 0;

   g_data_ready = false;

   double atrValues[];
   int copied = CopyBuffer(atrHandle, 0, 0, rates_total, atrValues);
   if(copied != rates_total)
   {
      if(DebugMode)
         PrintFormat("OnCalculate: ATR not fully ready (copied %d of %d), waiting for next tick", copied, rates_total);
      return 0;
   }
   ArraySetAsSeries(atrValues, false);

   int startBar = (prev_calculated <= 1) ? AtrPeriod + 1 : prev_calculated - 1;

   for(int i = startBar; i < rates_total; i++)
   {
      double src = (high[i] + low[i]) / 2.0;
      double atr = atrValues[i];

      double up_basic = src - (AtrMultiplier * atr);
      double dn_basic = src + (AtrMultiplier * atr);

      double up_prev = (i > 0 && UpBuffer[i-1] != EMPTY_VALUE && UpBuffer[i-1] > 0) ? UpBuffer[i-1] : up_basic;
      double dn_prev = (i > 0 && DnBuffer[i-1] != EMPTY_VALUE && DnBuffer[i-1] > 0) ? DnBuffer[i-1] : dn_basic;

      UpBuffer[i]  = (i > 0 && close[i-1] > up_prev) ? MathMax(up_basic, up_prev) : up_basic;
      DnBuffer[i]  = (i > 0 && close[i-1] < dn_prev) ? MathMin(dn_basic, dn_prev) : dn_basic;
      MidBuffer[i] = (open[i] + close[i]) / 2.0;

      int prevTrendLocal = (i > 0 && TrendBuffer[i-1] != 0 && TrendBuffer[i-1] != EMPTY_VALUE) ? (int)TrendBuffer[i-1] : 1;
      int trend = prevTrendLocal;

      if(prevTrendLocal == -1 && close[i] > DnBuffer[i-1])      trend = 1;
      else if(prevTrendLocal == 1 && close[i] < UpBuffer[i-1]) trend = -1;

      TrendBuffer[i] = trend;

      if(trend == 1)
      {
         UpTrendBuffer[i] = UpBuffer[i];
         DnTrendBuffer[i] = EMPTY_VALUE;
      }
      else
      {
         DnTrendBuffer[i] = DnBuffer[i];
         UpTrendBuffer[i] = EMPTY_VALUE;
      }

      if(trend == 1 && prevTrendLocal == -1)
      {
         BuySignalBuffer[i]  = ShowSignals ? UpBuffer[i] : EMPTY_VALUE;
         SellSignalBuffer[i] = EMPTY_VALUE;
      }
      else if(trend == -1 && prevTrendLocal == 1)
      {
         SellSignalBuffer[i] = ShowSignals ? DnBuffer[i] : EMPTY_VALUE;
         BuySignalBuffer[i]  = EMPTY_VALUE;
      }
      else
      {
         BuySignalBuffer[i]  = EMPTY_VALUE;
         SellSignalBuffer[i] = EMPTY_VALUE;
      }
   }

   g_data_ready = true;

   DrawFillingCanvas(false);

   return rates_total;
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam)
{
   if(id == CHARTEVENT_CHART_CHANGE)
   {
      DrawFillingCanvas(true);
   }
}
