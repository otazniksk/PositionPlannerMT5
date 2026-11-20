//+------------------------------------------------------------------+
//|                                              PositionPlanner.mq5 |
//|                    Copyright 2026, otaznik.sk - Michal Škop      |
//|                       https://www.mql5.com/en/users/otazniksk    |
//+------------------------------------------------------------------+
//| TradingView-style Long/Short position planner for MetaTrader 5.  |
//|  - draw any number of boxes (Entry / Stop / Target) by clicking  |
//|  - live drag with grab handles, crosshair, snap to open trades   |
//|  - lot size by risk (% balance / % equity / money / fixed lots)  |
//|  - trade simulated on real bars: Target hit / Stop hit / P&L     |
//|  - statistics of all boxes (win rate, R, money), box navigation  |
//|  - box from an executed trade: click Long/Short, then its arrow   |
//|  - export of all boxes + simulated results to JSON (MQL5\Files)  |
//| No DLL imports, no internet access, never places or edits trades.|
//| All state lives in chart objects (survives TF change / restart). |
//+------------------------------------------------------------------+
//| MIT License                                                      |
//|                                                                  |
//| Copyright (c) 2026 otaznik.sk - Michal Škop                      |
//|                                                                  |
//| Permission is hereby granted, free of charge, to any person      |
//| obtaining a copy of this software and associated documentation   |
//| files (the "Software"), to deal in the Software without          |
//| restriction, including without limitation the rights to use,     |
//| copy, modify, merge, publish, distribute, sublicense, and/or sell|
//| copies of the Software, and to permit persons to whom the        |
//| Software is furnished to do so, subject to the following         |
//| conditions:                                                      |
//|                                                                  |
//| The above copyright notice and this permission notice shall be   |
//| included in all copies or substantial portions of the Software.  |
//|                                                                  |
//| THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,  |
//| EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES  |
//| OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND         |
//| NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT      |
//| HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,     |
//| WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING     |
//| FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR    |
//| OTHER DEALINGS IN THE SOFTWARE.                                  |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, otaznik.sk - Michal Škop"
#property link        "https://www.mql5.com/en/users/otazniksk"
// Internal version: raise it with every change (shown in the chart's indicator list).
#define PP_VERSION "1.11"
#property version     PP_VERSION
#property description "TradingView-style Long/Short position planner: draw boxes, drag Entry/Stop/Target,"
#property description "lot size by risk, R:R, trade result simulated on real bars, statistics, navigation, JSON export."
#property description "No DLL, no internet access, never places or modifies trades."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <Generic\HashMap.mqh>

//--- enums ----------------------------------------------------------
enum ENUM_RISK_MODE
  {
   RISK_PCT_BALANCE = 0, // % of balance
   RISK_PCT_EQUITY  = 1, // % of equity
   RISK_MONEY       = 2, // Fixed money (account currency)
   RISK_LOTS        = 3  // Fixed lots
  };

enum ENUM_PIP_MODE
  {
   PIP_AUTO  = 0, // Auto (10 points on 3/5-digit symbols)
   PIP_POINT = 1  // 1 pip = 1 point
  };

enum ENUM_PANEL_CORNER
  {
   PANEL_LEFT_UPPER  = 0, // Left upper
   PANEL_RIGHT_UPPER = 1, // Right upper
   PANEL_LEFT_LOWER  = 2, // Left lower
   PANEL_RIGHT_LOWER = 3  // Right lower
  };

//--- inputs ---------------------------------------------------------
input group "Risk"
input ENUM_RISK_MODE    InpRiskMode   = RISK_PCT_BALANCE; // Risk mode
input double            InpRiskValue  = 1.0;              // Risk value (%, money or lots)

input group "New position"
input double            InpDefaultSL  = 0;                // Default SL distance in pips (0 = auto: 1.5 x ATR14)
input double            InpDefaultRR  = 2.0;              // Default reward:risk
input int               InpBoxBars    = 30;               // Box width (bars)
input bool              InpSnap       = true;             // Snap to open trades (entry / SL / TP) while dragging
// Tip: after Long/Short, clicking on a trade arrow creates the box of that trade (entry, SL, TP, times).
input ENUM_PIP_MODE     InpPipMode    = PIP_AUTO;         // Pip size

input group "Look (None = auto by chart background)"
input color             InpTPColor    = clrNONE;          // Take Profit color
input color             InpSLColor    = clrNONE;          // Stop Loss color
input color             InpEntryColor = clrNONE;          // Entry color
input int               InpZoneOpacity= 22;               // Zone opacity (5-60 %)
input int               InpTradeOpacity= 32;              // Trade area opacity (5-80 %, a bit above zone)
input int               InpFontSize   = 8;                // Font size

input group "Panel"
input ENUM_PANEL_CORNER InpCorner     = PANEL_LEFT_LOWER; // Panel corner
input int               InpPanelX     = 10;               // Panel X offset (px)
input int               InpPanelY     = 10;               // Panel Y offset (px)

input group "Export"
input bool              InpShowExport = false;            // Show Export button (JSON to MQL5\Files\PositionPlanner)
input bool              InpExportLockedOnly = false;      // Export only locked boxes
input bool              InpAutoBackup = false;            // Auto backup after every change (MQL5\Files\PositionPlanner\backup)

input group "Debug"
input bool              InpDebug      = false;            // Debug: log to Experts tab

//--- constants ------------------------------------------------------
#define PFX          "PP_"     // position objects: PP_<id>_<L|S>_<part>
#define UIP          "PPUI_"   // panel objects
#define FONT         "Segoe UI"
#define BTN_W        56
#define BTN_H        22
#define BTN_GAP      3
#define CLEAR_ARM_MS 3000
#define HIT_TOL      6         // px: inert band along the box edges

enum ENUM_HIT { HIT_NONE = 0, HIT_TP, HIT_SL, HIT_ENTRY,  // line ids (highlight / drag level)
                HIT_BODY,                                  // inside of the box: moves it as a whole
                HIT_H_TP, HIT_H_SL, HIT_H_E, HIT_H_R };    // handles: left corners, left middle (circle), right middle

#define HANDLE_SIZE  17        // px
#define HANDLE_TOL   9         // px grab tolerance around a handle
#define HANDLE_COLOR C'41,98,255'

//--- state ----------------------------------------------------------
struct SPos
  {
   int      id;
   int      dir;      // +1 long, -1 short
   double   entry;
   double   sl;
   double   tp;
   datetime t1;
   datetime t2;
   bool     locked;
   long     ticket;   // >0 = box linked to a real position (results from account history)
  };

struct SCalc
  {
   bool     ok;
   double   rewardPct; // reward as % of balance
   bool     pctOk;     // % known (linked box: balance before the entry found in history)
   double   lots;
   bool     belowMin;
   double   risk;      // money lost at SL (positive)
   double   reward;    // money won at TP
   double   riskPct;   // risk as % of balance
   double   slPips;
   double   tpPips;
   double   rr;
  };

struct SDrag
  {
   bool     on;
   int      id;
   int      hit;
   double   p0;        // price under mouse at press
   datetime tm0;       // time under mouse at press
   SPos     start;     // position at press
   bool     scrollWas;
  };

SPos   g_pos[];
SDrag  g_drag;
int    g_active      = -1;
int    g_sel[];               // Ctrl+click: further selected boxes (besides g_active)
int    g_nextId      = 1;
bool   g_hidden      = false;
bool   g_mouseDown   = false;
bool   g_rDown       = false;   // right button state (context menu)
int    g_hoverId     = -1;
int    g_hoverHit    = HIT_NONE;
uint   g_lastRefresh = 0;
uint   g_clearArmed  = 0;
// Restore / auto backup state
#define RESTORE_ARM_MS 15000
uint   g_restArmed = 0;
string g_restFile  = "";
string g_bakSig    = "";
bool   g_bakFirst  = true;
uint   g_bakCheck  = 0;
uint   g_bakRetry  = 0;   // tick of the last failed backup (0 = none) -> retry after 5 s
int    g_restTotal = 0, g_restFresh = 0;   // what the armed Restore would add (shown in the stats box)
int    g_placeDir    = 0;     // armed Long(+1)/Short(-1) placement: next chart click creates the box
color  g_bg          = clrNONE;
bool   g_dark        = true;
bool   g_showStats   = false;
string g_selfDel[];             // objects deleted by the indicator itself -> their delete events are ignored
color  cTP, cSL, cEntry, cZoneTP, cZoneSL, cBadgeE, cText, cBtn, cBtnText;

//+------------------------------------------------------------------+
//| Debug helpers                                                    |
//+------------------------------------------------------------------+
void Dbg(const string s)
  {
   if(InpDebug)
      Print("[PP] ", s);
  }

void DbgPos(const string tag, const SPos &p)
  {
   if(!InpDebug)
      return;
   SCalc c;
   Calc(p, c);
   Print(StringFormat("[PP] %s id=%d %s entry=%s sl=%s tp=%s t1=%s t2=%s locked=%d | lots=%s risk=%.2f (%.2f%%) reward=%.2f rr=%.2f slPips=%.1f tpPips=%.1f ok=%d belowMin=%d",
                      tag, p.id, p.dir > 0 ? "LONG" : "SHORT",
                      DoubleToString(p.entry, _Digits), DoubleToString(p.sl, _Digits), DoubleToString(p.tp, _Digits),
                      TimeToString(p.t1), TimeToString(p.t2), p.locked,
                      DoubleToString(c.lots, LotDigits()), c.risk, c.riskPct, c.reward, c.rr, c.slPips, c.tpPips, c.ok, c.belowMin));
  }


//+------------------------------------------------------------------+
//| Generic helpers                                                  |
//+------------------------------------------------------------------+
double PipSize()
  {
   if(InpPipMode == PIP_AUTO && (_Digits == 3 || _Digits == 5))
      return _Point * 10.0;
   return _Point;
  }

double NormPrice(double p)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts > 0)
      p = MathRound(p / ts) * ts;
   return NormalizeDouble(p, _Digits);
  }

// Round money to cents like MT5 does (half away from zero). A tiny epsilon fixes
// binary floating point values such as 0.52499999 that really mean 0.525.
double Money2(const double v)
  {
   return MathRound(v * 100.0 + (v >= 0 ? 1e-6 : -1e-6)) / 100.0;
  }

int LotDigits()
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0)
      return 2;
   int d = 0;
   while(d < 8)
     {
      double v = step * MathPow(10, d);
      if(MathAbs(v - MathRound(v)) < 1e-8)
         break;
      d++;
     }
   return d;
  }

string DirCode(const int dir) { return dir > 0 ? "L" : "S"; }

string ObjName(const SPos &p, const string part)
  {
   return StringFormat("%s%d_%s_%s", PFX, p.id, DirCode(p.dir), part);
  }

string PosPrefix(const int id) { return StringFormat("%s%d_", PFX, id); }

bool ParseName(const string name, int &id, int &dir, string &part)
  {
   if(StringFind(name, PFX) != 0)
      return false;
   string a[];
   if(StringSplit(StringSubstr(name, StringLen(PFX)), '_', a) != 3)
      return false;
   id = (int)StringToInteger(a[0]);
   if(id <= 0)
      return false;
   if(a[1] == "L")
      dir = 1;
   else
      if(a[1] == "S")
         dir = -1;
      else
         return false;
   part = a[2];
   return true;
  }

bool KnownPart(const string part)
  {
   return part == "ZP" || part == "ZL" || part == "E" || part == "SL" || part == "TP" ||
          part == "RT" || part == "RS" || part == "RE" || part == "ZR" || part == "PL" ||
          part == "H1" || part == "H2" || part == "H3" || part == "H4" ||
          part == "TK" || part == "SY";
  }

bool IsIn(const int &arr[], const int v)
  {
   for(int i = 0; i < ArraySize(arr); i++)
      if(arr[i] == v)
         return true;
   return false;
  }

int FindPos(const int id)
  {
   for(int i = 0; i < ArraySize(g_pos); i++)
      if(g_pos[i].id == id)
         return i;
   return -1;
  }

//+------------------------------------------------------------------+
//| Colors                                                           |
//+------------------------------------------------------------------+
int CR(const color c) { return (int)(c & 0xFF); }
int CG(const color c) { return (int)((c >> 8) & 0xFF); }
int CB(const color c) { return (int)((c >> 16) & 0xFF); }

color RGB(const int r, const int g, const int b)
  {
   return (color)((MathMax(0, MathMin(255, r))) | (MathMax(0, MathMin(255, g)) << 8) | (MathMax(0, MathMin(255, b)) << 16));
  }

// k = weight of a (0..1)
color Blend(const color a, const color b, const double k)
  {
   return RGB((int)MathRound(CR(a) * k + CR(b) * (1 - k)),
              (int)MathRound(CG(a) * k + CG(b) * (1 - k)),
              (int)MathRound(CB(a) * k + CB(b) * (1 - k)));
  }

void ResolveColors()
  {
   g_bg   = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   g_dark = (0.299 * CR(g_bg) + 0.587 * CG(g_bg) + 0.114 * CB(g_bg)) < 128.0;

   cTP     = InpTPColor    != clrNONE ? InpTPColor    : C'8,153,129';
   cSL     = InpSLColor    != clrNONE ? InpSLColor    : C'242,54,69';
   cEntry  = InpEntryColor != clrNONE ? InpEntryColor : (g_dark ? C'120,123,134' : C'110,113,124');

   double k = MathMax(5, MathMin(60, InpZoneOpacity)) / 100.0;
   cZoneTP = Blend(cTP, g_bg, k);
   cZoneSL = Blend(cSL, g_bg, k);

   cBadgeE  = C'33,82,214';   // prominent middle badge
   cText    = clrWhite;
   cBtn     = g_dark ? C'42,46,57'    : C'230,232,238';
   cBtnText = g_dark ? C'209,212,220' : C'40,42,50';
  }

//+------------------------------------------------------------------+
//| Money / lot calculation                                          |
//+------------------------------------------------------------------+
// Signed profit for 1 lot when price goes from -> to.
// (OrderCalcProfit is not allowed in indicators - err 4014 - so tick value is used.)
double MoneyPerLot(const int dir, const double from, const double to)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0)
      return 0.0;
   double move = dir * (to - from);
   double tv   = SymbolInfoDouble(_Symbol, move >= 0 ? SYMBOL_TRADE_TICK_VALUE_PROFIT : SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0)
      tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   return move / ts * tv;
  }

// Tick size / tick value known -> MoneyPerLot is meaningful.
bool MoneyOk()
  {
   return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) > 0 &&
          (SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS) > 0 || SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) > 0);
  }

void Calc(const SPos &p, SCalc &c)
  {
   ZeroMemory(c);
   double pip = PipSize();
   c.slPips = MathAbs(p.entry - p.sl) / pip;
   c.tpPips = MathAbs(p.tp - p.entry) / pip;
   c.rr     = c.slPips > 0 ? c.tpPips / c.slPips : 0.0;

   if(p.ticket > 0)
     {
      // Linked to a real position: everything comes from the real trade, never from the
      // risk inputs (so changing the inputs never changes this box). Lots = real volume,
      // % = of the balance right before the entry. Not available -> nothing is shown.
      SReal r;
      if(GetReal(p.ticket, r))
        {
         double bal0 = BalanceAtEntry(p.ticket);
         c.lots      = r.volIn;
         c.risk      = c.slPips > 0 ? -MoneyPerLot(p.dir, p.entry, p.sl) * c.lots : 0;
         c.reward    = c.tpPips > 0 ?  MoneyPerLot(p.dir, p.entry, p.tp) * c.lots : 0;
         c.pctOk     = bal0 > 0;
         c.riskPct   = c.pctOk ? c.risk / bal0 * 100.0 : 0;
         c.rewardPct = c.pctOk ? c.reward / bal0 * 100.0 : 0;
         c.ok        = MoneyOk();   // no tick data -> no money figures (never a fake 0.00)
        }
      return;
     }

   // a price at or below zero is not a valid order level -> no lot size
   if(p.entry <= 0 || p.sl <= 0)
      return;
   double lossLot = -MoneyPerLot(p.dir, p.entry, p.sl);
   double profLot =  MoneyPerLot(p.dir, p.entry, p.tp);
   if(lossLot <= 0)
      return;

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double raw;
   if(InpRiskMode == RISK_LOTS)
      raw = InpRiskValue;
   else
     {
      double money = (InpRiskMode == RISK_MONEY) ? InpRiskValue
                     : ((InpRiskMode == RISK_PCT_EQUITY) ? eq : bal) * InpRiskValue / 100.0;
      raw = money / lossLot;
     }
   // zero / negative risk budget (inputs, balance) -> no lot size, never the minimum lot
   if(!MathIsValidNumber(raw) || raw <= 0)
      return;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0)
      step = 0.01;
   double lots = MathFloor(raw / step + 1e-9) * step;
   if(lots < vmin)
     {
      lots = vmin;
      c.belowMin = true;
     }
   if(vmax > 0 && lots > vmax)
      lots = vmax;

   c.lots    = NormalizeDouble(lots, LotDigits());
   c.risk    = lossLot * c.lots;
   c.reward  = profLot * c.lots;
   c.pctOk   = bal > 0;
   c.riskPct = bal > 0 ? c.risk / bal * 100.0 : 0.0;
   c.rewardPct = bal > 0 ? c.reward / bal * 100.0 : 0.0;
   c.ok      = true;
  }



//+------------------------------------------------------------------+
//| Geometry                                                         |
//+------------------------------------------------------------------+
bool PosXY(const SPos &p, int &x1, int &x2, int &yE, int &yS, int &yT)
  {
   int d;
   if(!ChartTimePriceToXY(0, 0, p.t1, p.entry, x1, yE))
      return false;
   if(!ChartTimePriceToXY(0, 0, p.t2, p.entry, x2, d))
      return false;
   if(!ChartTimePriceToXY(0, 0, p.t1, p.sl, d, yS))
      return false;
   if(!ChartTimePriceToXY(0, 0, p.t1, p.tp, d, yT))
      return false;
   return true;
  }

// x of the width handle: the right edge, but kept inside the visible chart, so the handle
// can always be grabbed even when the box reaches past the right edge of the chart.
// When the left edge itself is at the chart edge the handle stays fully visible (it may then
// overlap the left handles, which take precedence - move the box left to reach it).
int HandleRX(const int x1, const int x2)
  {
   int cw  = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int lim = cw - HANDLE_SIZE;
   if(x2 <= lim || x1 >= cw)   // fits, or the whole box is off screen to the right
      return x2;
   return MathMin(x2, MathMin(MathMax(lim, x1 + HANDLE_SIZE), cw - HANDLE_SIZE / 2 - 2));
  }

// Snap a time to the start of the nearest bar (objects are drawn snapped to bars,
// so pixel-positioned handles/badges must use the same times).
datetime SnapTime(const datetime t)
  {
   int      ps = PeriodSeconds();
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(ps <= 0 || t0 == 0)
      return t;
   if(t >= t0)   // future area: regular grid from the last bar
      return (datetime)((long)t0 + (long)MathRound((double)((long)t - (long)t0) / ps) * ps);
   int sh = iBarShift(_Symbol, _Period, t, false);   // bar with time <= t
   if(sh < 0)
      return t;
   datetime a = iTime(_Symbol, _Period, sh);
   datetime b = sh > 0 ? iTime(_Symbol, _Period, sh - 1) : (datetime)((long)t0 + ps);
   return ((long)t - (long)a <= (long)b - (long)t) ? a : b;
  }

// Bar index of a (snapped) time: 0 = current bar, >0 history, <0 future.
int BarIndex(const datetime t)
  {
   datetime t0 = iTime(_Symbol, _Period, 0);
   int ps = PeriodSeconds();
   if(t0 == 0 || ps <= 0)
      return 0;
   if(t >= t0)
      return -(int)MathRound((double)((long)t - (long)t0) / ps);
   int sh = iBarShift(_Symbol, _Period, t, false);
   return sh < 0 ? 0 : sh;
  }

// Time of a bar index (inverse of BarIndex; future bars on a regular grid).
datetime TimeAtIndex(const int idx)
  {
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(idx <= 0)
      return (datetime)((long)t0 + (long)(-idx) * PeriodSeconds());
   int bars = iBars(_Symbol, _Period);
   int k = MathMin(idx, bars - 1);
   return iTime(_Symbol, _Period, k);
  }

int HitTest(const SPos &p, const int x, const int y)
  {
   int x1, x2, yE, yS, yT;
   if(!PosXY(p, x1, x2, yE, yS, yT))
      return HIT_NONE;
   int xR = HandleRX(x1, x2);
   if(x < x1 - HANDLE_TOL || x > MathMax(x2, xR) + HANDLE_TOL)
      return HIT_NONE;
   int top = MathMin(yT, yS), bot = MathMax(yT, yS);
   if(y < top - HANDLE_TOL || y > bot + HANDLE_TOL)
      return HIT_NONE;
   // handles: left corners (Target / Stop), left middle (Entry), right middle (width)
   if(MathAbs(x - x1) <= HANDLE_TOL && MathAbs(y - yT) <= HANDLE_TOL)
      return HIT_H_TP;
   if(MathAbs(x - x1) <= HANDLE_TOL && MathAbs(y - yS) <= HANDLE_TOL)
      return HIT_H_SL;
   if(MathAbs(x - x1) <= HANDLE_TOL && MathAbs(y - yE) <= HANDLE_TOL)
      return HIT_H_E;
   if(MathAbs(x - xR) <= HANDLE_TOL && MathAbs(y - yE) <= HANDLE_TOL)
      return HIT_H_R;
   // size / levels change only via the blue handles. The edges do nothing (no resize,
   // no move) - only the inside of the box moves it as a whole.
   if(x <= x1 + HIT_TOL || x >= x2 - HIT_TOL || y <= top + 2 || y >= bot - 2)
      return HIT_NONE;
   return HIT_BODY;
  }

// Find position under mouse: active one first, then newest to oldest.
int FindHit(const int x, const int y, int &hit)
  {
   hit = HIT_NONE;
   if(g_hidden)
      return -1;
   int ai = FindPos(g_active);
   if(ai >= 0)
     {
      hit = HitTest(g_pos[ai], x, y);
      if(hit != HIT_NONE)
         return g_active;
     }
   for(int i = ArraySize(g_pos) - 1; i >= 0; i--)
     {
      if(i == ai)
         continue;
      hit = HitTest(g_pos[i], x, y);
      if(hit != HIT_NONE)
         return g_pos[i].id;
     }
   hit = HIT_NONE;
   return -1;
  }

//+------------------------------------------------------------------+
//| Drawing primitives                                               |
//+------------------------------------------------------------------+
void SetCommon(const string n, const bool back, const long zorder, const bool visible)
  {
   ObjectSetInteger(0, n, OBJPROP_BACK, back);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, n, OBJPROP_ZORDER, zorder);
   ObjectSetInteger(0, n, OBJPROP_TIMEFRAMES, visible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
   ObjectSetString(0, n, OBJPROP_TOOLTIP, "\n");
  }

void DrawRect(const string n, const datetime t1, const double p1, const datetime t2, const double p2, const color c)
  {
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   else
     {
      ObjectMove(0, n, 0, t1, p1);
      ObjectMove(0, n, 1, t2, p2);
     }
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_FILL, true);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 1);
   SetCommon(n, true, 0, !g_hidden);
  }

void DrawLine(const string n, const datetime t1, const datetime t2, const double price,
              const color c, const int width, const ENUM_LINE_STYLE style)
  {
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_TREND, 0, t1, price, t2, price);
   else
     {
      ObjectMove(0, n, 0, t1, price);
      ObjectMove(0, n, 1, t2, price);
     }
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, n, OBJPROP_STYLE, style);
   ObjectSetInteger(0, n, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, n, OBJPROP_RAY_LEFT, false);
   SetCommon(n, false, 10, !g_hidden);
  }

//--- rounded badges rendered into a bitmap resource (OBJ_BITMAP_LABEL) ---
// MT5 starts the NEW instance before it deinitializes the OLD one (input change,
// recompile), so bitmap resources get an instance suffix - otherwise the old
// instance frees the new one's images and badges keep showing stale values.
string g_inst = "";
string ResName(const string obj) { return "::" + obj + "_" + g_inst; }

string g_bName[];   // render cache: object name
string g_bSig[];    //               content signature
int    g_bW[];
int    g_bH[];

uint ARGB(const color c, const double a)
  {
   uint A = (uint)MathRound(255.0 * MathMax(0.0, MathMin(1.0, a)));
   return (A << 24) | ((uint)CR(c) << 16) | ((uint)CG(c) << 8) | (uint)CB(c);
  }

int BadgeCache(const string obj)
  {
   int freeSlot = -1;
   for(int k = 0; k < ArraySize(g_bName); k++)
     {
      if(g_bName[k] == obj)
         return k;
      if(freeSlot < 0 && g_bName[k] == "")
         freeSlot = k;
     }
   if(freeSlot >= 0)
     {
      g_bName[freeSlot] = obj;
      g_bSig[freeSlot]  = "";
      return freeSlot;
     }
   int n = ArraySize(g_bName);
   ArrayResize(g_bName, n + 1);
   ArrayResize(g_bSig, n + 1);
   ArrayResize(g_bW, n + 1);
   ArrayResize(g_bH, n + 1);
   g_bName[n] = obj;
   g_bSig[n]  = "";
   g_bW[n]    = 0;
   g_bH[n]    = 0;
   return n;
  }

// Free bitmap resources of objects starting with prefix ("" = all of this instance).
void FreeBadges(const string prefix)
  {
   for(int k = 0; k < ArraySize(g_bName); k++)
      if(g_bName[k] != "" && (prefix == "" || StringFind(g_bName[k], prefix) == 0))
        {
         ResourceFree(ResName(g_bName[k]));
         g_bName[k] = "";
         g_bSig[k]  = "";
        }
  }

// Render a rounded badge (anti-aliased) with 1..n centered text lines.
// border = clrNONE -> no border. Re-renders only when content changes.
void BadgeFont(const bool hi, const bool bold, const int fsize)
  {
   if(hi)
      TextSetFont(FONT, -(fsize + 1) * 10, FW_BOLD);
   else
      TextSetFont(FONT, -fsize * 10, bold ? FW_SEMIBOLD : FW_NORMAL);
  }

// hiLine >= 0: that line is highlighted (bold, one size bigger) with a gap above and below.
void BuildBadge(const string obj, const string &lines[], const color bg, const color border,
                const bool bold, const int fsize, int &w, int &h, const int hiLine = -1)
  {
   int n = ArraySize(lines);
   string sig = StringFormat("%u|%u|%d|%d|%d|", bg, border, bold, fsize, hiLine);
   for(int i = 0; i < n; i++)
      sig += lines[i] + "\n";
   int k = BadgeCache(obj);
   if(g_bSig[k] == sig && ObjectFind(0, obj) >= 0)
     {
      w = g_bW[k];
      h = g_bH[k];
      return;
     }

   uint tw = 0, th = 0;
   int maxw = 0, lh = 0, hiH = 0;
   for(int i = 0; i < n; i++)
     {
      BadgeFont(i == hiLine, bold, fsize);
      TextGetSize(lines[i], tw, th);
      maxw = MathMax(maxw, (int)tw);
      if(i == hiLine)
         hiH = (int)th;
      else
         lh = MathMax(lh, (int)th);
     }
   int padX = 11, padY = 4, hiGap = 5;
   bool hi = hiLine >= 0 && hiLine < n;
   w = maxw + 2 * padX;
   h = (hi ? (n - 1) * lh + hiH + 2 * hiGap : n * lh) + 2 * padY;

   uint data[];
   ArrayResize(data, w * h);
   double r  = MathMin(h / 2.0, 6.0);
   double hw = w / 2.0, hh = h / 2.0;
   double bw = (border == clrNONE) ? 0.0 : 1.0;
   for(int y = 0; y < h; y++)
      for(int x = 0; x < w; x++)
        {
         // signed distance to rounded rectangle
         double qx = MathAbs(x + 0.5 - hw) - (hw - r);
         double qy = MathAbs(y + 0.5 - hh) - (hh - r);
         double ox = MathMax(qx, 0.0), oy = MathMax(qy, 0.0);
         double d  = MathSqrt(ox * ox + oy * oy) + MathMin(MathMax(qx, qy), 0.0) - r;
         double aOut = MathMax(0.0, MathMin(1.0, 0.5 - d));
         if(aOut <= 0.0)
           {
            data[y * w + x] = 0;
            continue;
           }
         color c = bg;
         if(bw > 0)
           {
            double aIn = MathMax(0.0, MathMin(1.0, 0.5 - (d + bw)));
            c = Blend(bg, border, aIn);
           }
         data[y * w + x] = ARGB(c, aOut);
        }

   uint fg = ARGB(cText, 1.0);
   int y = padY;
   for(int i = 0; i < n; i++)
     {
      bool isHi = hi && i == hiLine;
      if(isHi)
         y += hiGap;
      BadgeFont(isHi, bold, fsize);
      TextOut(lines[i], w / 2, y - 1, TA_CENTER | TA_TOP, data, w, h, fg, COLOR_FORMAT_ARGB_NORMALIZE);
      y += isHi ? hiH + hiGap : lh;
     }

   string res = ResName(obj);
   ResourceCreate(res, data, w, h, 0, 0, w, COLOR_FORMAT_ARGB_NORMALIZE);
   if(ObjectFind(0, obj) < 0)
      ObjectCreate(0, obj, OBJ_BITMAP_LABEL, 0, 0, 0);
   ObjectSetString(0, obj, OBJPROP_BMPFILE, 0, res);
   ObjectSetString(0, obj, OBJPROP_BMPFILE, 1, res);
   ObjectSetInteger(0, obj, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, obj, OBJPROP_YSIZE, h);

   g_bSig[k] = sig;
   g_bW[k]   = w;
   g_bH[k]   = h;
  }

void PlaceBadge(const string obj, const int cx, const int cy, const int w, const int h, const bool visible,
                const bool clampX = false)
  {
   ObjectSetInteger(0, obj, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, obj, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   // clampX: keep the whole badge inside the chart horizontally (box partly off screen)
   int bx = cx - w / 2;
   if(clampX)
      bx = MathMax(0, MathMin(bx, (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS) - w));
   ObjectSetInteger(0, obj, OBJPROP_XDISTANCE, bx);
   ObjectSetInteger(0, obj, OBJPROP_YDISTANCE, cy - h / 2);
   SetCommon(obj, false, 20, visible);
  }

//+------------------------------------------------------------------+
//| Trade simulation on real bars (like TradingView)                 |
//+------------------------------------------------------------------+
struct STrade
  {
   bool     triggered;  // price reached entry inside the box time range
   int      state;      // 0 = still open, 1 = target hit, -1 = stop hit
   datetime tIn;        // bar where entry was hit
   datetime tOut;       // bar where TP/SL was hit, or last bar inside the box
   double   exitPrice;  // TP / SL price, or last close when still open
   bool     closed;     // trade finished (TP / SL / BE / manual)
   bool     real;       // values come from the real position, not from the simulation
   double   pnl;        // real: money incl. commission + swap
   double   volume;     // real: position volume
   double   curSL;      // real & open: current SL of the position
   string   reason;     // real: "Target hit", "Stop hit", "Break-even", "Closed manually", ...
   datetime tInExact;   // real: exact entry deal time
   datetime tOutExact;  // real: exact (last) closing deal time
   datetime tExit;      // simulated: best known exit time (the M1 minute when resolved, else the bar)
   bool     exitMin;    // simulated: tExit is the M1 minute (else only the bar is known)
   bool     unknown;    // linked box whose real data is not available (history) -> no result at all
  };

//--- real position data (from account history), cached for 2 s ---------
struct SReal
  {
   long     ticket;
   bool     ok;
   bool     open;
   int      dir;
   double   entry;      // volume weighted
   double   exitPrice;  // volume weighted (closed part)
   double   volIn;
   double   volOut;
   double   pnlClosed;  // DEAL_PROFIT of closing deals
   double   costs;      // commission + swap + fee of all deals
   double   initSL;
   double   initTP;
   bool     slLater;    // initSL / initTP not on the opening deal / order: taken from the position
   bool     tpLater;    //   now or at the close (set or moved after the entry -> not the initial level)
   double   curSL;      // open: position SL now; closed: SL at the close
   double   curTP;
   datetime tIn;
   datetime tOut;
   long     reason;     // DEAL_REASON of the last closing deal
   uint     stamp;
  };

SReal g_real[];

bool LoadReal(const long ticket, SReal &r)
  {
   ZeroMemory(r);
   r.ticket = ticket;
   if(ticket <= 0 || !HistorySelectByPosition(ticket))
      return false;
   int n = HistoryDealsTotal();
   double sIn = 0, sOut = 0;
   for(int k = 0; k < n; k++)
     {
      ulong d = HistoryDealGetTicket(k);
      if(d == 0)
         continue;
      long     en = HistoryDealGetInteger(d, DEAL_ENTRY);
      long     ty = HistoryDealGetInteger(d, DEAL_TYPE);
      double   v  = HistoryDealGetDouble(d, DEAL_VOLUME);
      double   pr = HistoryDealGetDouble(d, DEAL_PRICE);
      datetime t  = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      r.costs += HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
      if(en == DEAL_ENTRY_IN && (ty == DEAL_TYPE_BUY || ty == DEAL_TYPE_SELL))
        {
         sIn += pr * v;
         r.volIn += v;
         if(r.tIn == 0 || t < r.tIn)
           {
            r.tIn    = t;
            r.dir    = (ty == DEAL_TYPE_BUY) ? 1 : -1;
            r.initSL = HistoryDealGetDouble(d, DEAL_SL);
            r.initTP = HistoryDealGetDouble(d, DEAL_TP);
           }
        }
      else
         if(en == DEAL_ENTRY_OUT || en == DEAL_ENTRY_OUT_BY)
           {
            sOut += pr * v;
            r.volOut += v;
            r.pnlClosed += HistoryDealGetDouble(d, DEAL_PROFIT);
            if(t >= r.tOut)
              {
               r.tOut   = t;
               r.reason = HistoryDealGetInteger(d, DEAL_REASON);
               r.curSL  = HistoryDealGetDouble(d, DEAL_SL);
               r.curTP  = HistoryDealGetDouble(d, DEAL_TP);
              }
           }
     }
   if(r.volIn <= 0)
      return false;
   r.entry = sIn / r.volIn;
   if(r.volOut > 0)
      r.exitPrice = sOut / r.volOut;
   // SL/TP not on the entry deal -> try the opening order
   if(r.initSL <= 0 || r.initTP <= 0)
     {
      datetime first = 0;
      for(int k = 0; k < HistoryOrdersTotal(); k++)
        {
         ulong o = HistoryOrderGetTicket(k);
         if(o == 0)
            continue;
         datetime ts = (datetime)HistoryOrderGetInteger(o, ORDER_TIME_SETUP);
         if(first == 0 || ts < first)
           {
            first = ts;
            if(r.initSL <= 0)
               r.initSL = HistoryOrderGetDouble(o, ORDER_SL);
            if(r.initTP <= 0)
               r.initTP = HistoryOrderGetDouble(o, ORDER_TP);
           }
        }
     }
   r.open = PositionSelectByTicket((ulong)ticket);
   if(r.open)
     {
      r.curSL = PositionGetDouble(POSITION_SL);
      r.curTP = PositionGetDouble(POSITION_TP);
     }
   // SL/TP set only after the entry (e.g. by an EA modifying the position):
   // best known values are those of the open position / at the moment of the close
   // -> marked as "set later" (shown as such), the initial level is not known
   if(r.initSL <= 0 && r.curSL > 0)
     {
      r.initSL  = r.curSL;
      r.slLater = true;
     }
   if(r.initTP <= 0 && r.curTP > 0)
     {
      r.initTP  = r.curTP;
      r.tpLater = true;
     }
   r.ok    = true;
   r.stamp = GetTickCount();
   return true;
  }

bool GetReal(const long ticket, SReal &r)
  {
   int k = -1;
   for(int j = 0; j < ArraySize(g_real); j++)
      if(g_real[j].ticket == ticket)
         k = j;
   if(k >= 0 && g_real[k].ok && GetTickCount() - g_real[k].stamp < 2000)
     {
      r = g_real[k];
      return true;
     }
   bool ok = LoadReal(ticket, r);
   if(k < 0)
     {
      k = ArraySize(g_real);
      ArrayResize(g_real, k + 1);
     }
   g_real[k] = r;
   return ok;
  }

// Account balance right before the entry deal of a position:
// current balance minus every balance change (profit, commission, swap, fee, deposits,
// withdrawals) from the entry deal on. Exact, from the account history; computed once.
long   g_balTk[];
double g_balV[];
uint   g_balFail = 0;   // last failed lookup (history still loading) -> retry at most every 5 s

double BalanceAtEntry(const long ticket)
  {
   for(int j = 0; j < ArraySize(g_balTk); j++)
      if(g_balTk[j] == ticket)
         return g_balV[j];
   if(g_balFail > 0 && GetTickCount() - g_balFail < 5000)
      return 0.0;
   if(!HistorySelect(0, TimeCurrent() + 86400))
     {
      g_balFail = GetTickCount();
      return 0.0;
     }
   int n = HistoryDealsTotal();
   long msIn = -1;
   for(int k = 0; k < n && msIn < 0; k++)
     {
      ulong d = HistoryDealGetTicket(k);
      if(HistoryDealGetInteger(d, DEAL_POSITION_ID) == ticket &&
         HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
         msIn = HistoryDealGetInteger(d, DEAL_TIME_MSC);
     }
   if(msIn < 0)
     {
      g_balFail = GetTickCount();
      return 0.0;   // entry deal not in history -> no %
     }
   double sum = 0.0;
   for(int k = 0; k < n; k++)
     {
      ulong d = HistoryDealGetTicket(k);
      if(HistoryDealGetInteger(d, DEAL_TIME_MSC) < msIn)
         continue;
      sum += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
             HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
     }
   double bal = AccountInfoDouble(ACCOUNT_BALANCE) - sum;
   int j = ArraySize(g_balTk);
   ArrayResize(g_balTk, j + 1);
   ArrayResize(g_balV, j + 1);
   g_balTk[j] = ticket;
   g_balV[j]  = bal;
   return bal;
  }

bool IsNone(const double level, const double entry) { return MathAbs(level - entry) < _Point * 0.5; }

// Price at which a position would be closed now (long -> Bid, short -> Ask).
double ClosePrice(const int dir)
  {
   return SymbolInfoDouble(_Symbol, dir > 0 ? SYMBOL_BID : SYMBOL_ASK);
  }

// Fills tr from the real position (linked boxes). Returns false if not available.
bool RealTrade(const SPos &p, STrade &tr)
  {
   SReal r;
   if(!GetReal(p.ticket, r))
      return false;
   tr.real      = true;
   tr.triggered = true;
   tr.volume    = r.volIn;
   tr.tIn       = BarStart(r.tIn);
   tr.tInExact  = r.tIn;
   tr.tOutExact = r.open ? 0 : r.tOut;
   tr.curSL     = r.curSL;
   if(r.open)
     {
      tr.closed    = false;
      tr.state     = 0;
      tr.tOut      = iTime(_Symbol, _Period, 0);
      tr.exitPrice = ClosePrice(p.dir);
      double live  = 0;
      if(PositionSelectByTicket((ulong)p.ticket))
         live = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      tr.pnl    = live + r.pnlClosed + r.costs;
      tr.reason = r.volOut > 0 ? "Open (part closed)" : "Open P&L";
      return true;
     }
   tr.closed    = true;
   tr.tOut      = BarStart(r.tOut);
   tr.exitPrice = r.exitPrice;
   tr.pnl       = r.pnlClosed + r.costs;
   double move  = (r.exitPrice - r.entry) * p.dir;
   double risk  = IsNone(p.sl, p.entry) ? 0 : MathAbs(p.entry - p.sl);
   double beTol = MathMax(5 * _Point, 0.05 * risk);
   switch((int)r.reason)
     {
      case DEAL_REASON_TP:
         tr.state = 1;
         tr.reason = "Target hit";
         break;
      case DEAL_REASON_SL:
         if(MathAbs(move) <= beTol)
           {
            tr.state  = 0;
            tr.reason = "Break-even";
           }
         else
           {
            tr.state  = move > 0 ? 1 : -1;
            tr.reason = move > 0 ? "Stop hit (in profit)" : "Stop hit";
           }
         break;
      case DEAL_REASON_SO:
         tr.state = -1;
         tr.reason = "Stop out";
         break;
      default:
         tr.state  = tr.pnl > 0 ? 1 : (tr.pnl < 0 ? -1 : 0);
         tr.reason = (r.reason == DEAL_REASON_EXPERT) ? "Closed by EA" : "Closed manually";
         break;
     }
   return true;
  }

// Simulated close at Stop (state -1) or Target (state 1) in the chart bar starting at t.
// tExit = the M1 minute of the hit when known (0 = only the bar is known).
void SimClose(const SPos &p, STrade &tr, const int state, const datetime t, const datetime tExit = 0)
  {
   tr.state     = state;
   tr.exitPrice = state < 0 ? p.sl : p.tp;
   tr.tOut      = t;
   tr.tExit     = tExit > 0 ? tExit : t;
   tr.exitMin   = tExit > 0;
   tr.closed    = true;
  }

// Last second of chart bar idx (r = rates oldest first). Uses the next bar's open time, so
// months of any length and session gaps are handled.
datetime BarEnd(const MqlRates &r[], const int idx, const int n)
  {
   if(idx + 1 < n)
      return (datetime)((long)r[idx + 1].time - 1);
   int sh = iBarShift(_Symbol, _Period, r[idx].time, true);
   if(sh > 0)
     {
      datetime nx = iTime(_Symbol, _Period, sh - 1);
      if(nx > r[idx].time)
         return (datetime)((long)nx - 1);
     }
   return TimeCurrent();
  }

// Cache of M1 decisions for finished chart bars (a finished bar never changes) - the
// simulation runs on every tick / redraw / stats refresh, M1 data is read once per bar + levels.
#define M1C_SIZE 1024
CHashMap<string, int> g_m1Map;
string   g_m1Key[M1C_SIZE];
bool     g_m1Ok[M1C_SIZE];
int      g_m1Res[M1C_SIZE];
datetime g_m1Hit[M1C_SIZE];
int      g_m1Next    = 0;
bool     g_m1Pending = false;   // M1 history was not ready -> finished boxes are recalculated later
CHashMap<string, uint> g_m1Wait; // bar key -> tick of the first "not ready"; after 60 s M1 gives up
#define M1_WAIT_MS 60000

void M1Store(const string key, const bool ok, const int res, const datetime hit)
  {
   int k = g_m1Next;
   g_m1Next = (g_m1Next + 1) % M1C_SIZE;
   if(g_m1Key[k] != "")
      g_m1Map.Remove(g_m1Key[k]);
   g_m1Key[k] = key;
   g_m1Ok[k]  = ok;
   g_m1Res[k] = res;
   g_m1Hit[k] = hit;
   g_m1Map.TrySetValue(key, k);
  }

// Looks at the M1 bars inside one chart bar to find what came first.
// needEntry = the entry bar: the entry must be reached first; inside the entry minute the
// conservative rule stays (stop counts, target alone does not); Stop and Target in one minute
// = stop. res: -1 stop first, 1 target first, 0 neither after the entry; tHit = that minute.
// Returns false when M1 cannot decide: chart is M1 or lower or above D1, M1 history not ready,
// or the M1 bars do not rebuild the chart bar exactly (open, high, low, close, tick volume).
bool InsideBar(const SPos &p, const MqlRates &bar, const datetime tEnd, const bool needEntry, int &res, datetime &tHit)
  {
   res  = 0;
   tHit = 0;
   if(PeriodSeconds() <= 60 || PeriodSeconds() > 86400)
      return false;
   bool fin = bar.time < iTime(_Symbol, _Period, 0);   // finished bar -> cacheable
   string key = StringFormat("%I64d|%I64d|%d|%s|%s|%s|%d", (long)bar.time, (long)tEnd, p.dir,
                             DoubleToString(p.entry, _Digits), DoubleToString(p.sl, _Digits),
                             DoubleToString(p.tp, _Digits), needEntry);
   int ci;
   if(fin && g_m1Map.TryGetValue(key, ci) && g_m1Key[ci] == key)
     {
      res  = g_m1Res[ci];
      tHit = g_m1Hit[ci];
      return g_m1Ok[ci];
     }
   MqlRates m[];
   int n = CopyRates(_Symbol, PERIOD_M1, bar.time, tEnd, m);
   bool synced = (bool)SeriesInfoInteger(_Symbol, PERIOD_M1, SERIES_SYNCHRONIZED);
   if(n <= 0 || !synced)
     {
      // history is being loaded - try again later; a finished bar that never gets M1 data
      // (outside the available history) is given up after M1_WAIT_MS -> conservative rule
      if(fin)
        {
         uint t0;
         if(!g_m1Wait.TryGetValue(key, t0))
            g_m1Wait.Add(key, GetTickCount());
         else
            if(GetTickCount() - t0 > M1_WAIT_MS)
              {
               g_m1Wait.Remove(key);
               M1Store(key, false, 0, 0);
               return false;
              }
        }
      g_m1Pending = true;
      return false;
     }
   if(fin)
      g_m1Wait.Remove(key);
   double hi = m[0].high, lo = m[0].low;
   long   tv = 0;
   for(int i = 0; i < n; i++)
     {
      hi = MathMax(hi, m[i].high);
      lo = MathMin(lo, m[i].low);
      tv += m[i].tick_volume;
     }
   bool same = MathAbs(m[0].open - bar.open) < _Point * 0.5 && MathAbs(m[n - 1].close - bar.close) < _Point * 0.5 &&
               MathAbs(hi - bar.high) < _Point * 0.5 && MathAbs(lo - bar.low) < _Point * 0.5 &&
               tv == bar.tick_volume;
   if(!same)
     {
      if(InpDebug)
         Print(StringFormat("[PP] M1 does not rebuild bar %s (M1 bars %d, tick volume %I64d vs %I64d) -> conservative rule",
                            TimeToString(bar.time), n, tv, bar.tick_volume));
      if(fin)
         M1Store(key, false, 0, 0);   // synchronized but different -> M1 cannot decide this bar
      return false;
     }
   bool slOn = !IsNone(p.sl, p.entry), tpOn = !IsNone(p.tp, p.entry);
   bool done = false;
   int i = 0;
   if(needEntry)
     {
      for(; i < n; i++)
         if(m[i].low <= p.entry && m[i].high >= p.entry)
            break;
      if(i >= n)
        {
         if(fin)
            M1Store(key, false, 0, 0);
         return false;
        }
      if(slOn && (p.dir > 0 ? m[i].low <= p.sl : m[i].high >= p.sl))
        {
         res  = -1;
         tHit = m[i].time;
         done = true;
        }
      i++;
     }
   for(; !done && i < n; i++)
     {
      bool hs = slOn && (p.dir > 0 ? m[i].low <= p.sl  : m[i].high >= p.sl);
      bool ht = tpOn && (p.dir > 0 ? m[i].high >= p.tp : m[i].low <= p.tp);
      if(hs || ht)
        {
         res  = hs ? -1 : 1;
         tHit = m[i].time;
         done = true;
        }
     }
   if(fin)
      M1Store(key, true, res, tHit);
   return true;
  }

void SimTrade(const SPos &p, STrade &tr)
  {
   ZeroMemory(tr);
   if(p.ticket > 0)
     {
      // linked box: real data or nothing - never a simulated result in its place
      if(!RealTrade(p, tr))
        {
         ZeroMemory(tr);
         tr.unknown = true;
        }
      return;
     }
   datetime tEnd = MathMin(p.t2, TimeCurrent());
   if(tEnd < p.t1)
      return;
   MqlRates r[];
   int n = CopyRates(_Symbol, _Period, p.t1, tEnd, r);   // oldest first
   if(n <= 0)
      return;
   int k = 0;
   for(; k < n; k++)
      if(r[k].low <= p.entry && r[k].high >= p.entry)
         break;
   if(k >= n)
      return;               // entry never reached
   tr.triggered = true;
   tr.tIn       = r[k].time;
   tr.tOut      = r[n - 1].time;
   tr.exitPrice = r[n - 1].close;
   // box still running -> value it like MT5 does: long closes at Bid, short at Ask
   bool live = (r[n - 1].time == iTime(_Symbol, _Period, 0));
   if(live)
     {
      double cp = ClosePrice(p.dir);
      if(cp > 0)
         tr.exitPrice = cp;
     }
   // Entry bar: OHLC does not tell whether Stop / Target were touched before or after the
   // entry. The M1 bars inside it decide; when they cannot (no / incomplete M1 history, chart
   // already M1), stay conservative: a stop inside the entry bar counts as hit, a target inside
   // the entry bar alone does not (it may have been before the entry) - the next bars decide.
   bool slK = !IsNone(p.sl, p.entry) && (p.dir > 0 ? r[k].low <= p.sl  : r[k].high >= p.sl);
   bool tpK = !IsNone(p.tp, p.entry) && (p.dir > 0 ? r[k].high >= p.tp : r[k].low <= p.tp);
   if(slK || tpK)
     {
      int res;
      datetime th;
      if(InsideBar(p, r[k], BarEnd(r, k, n), true, res, th))
        {
         if(res != 0)
           {
            SimClose(p, tr, res, r[k].time, th);
            return;
           }
        }
      else if(slK)
        {
         SimClose(p, tr, -1, r[k].time);
         return;
        }
     }
   for(int j = k + 1; j < n; j++)
     {
      // a "none" level (= entry) never hits
      bool hitSL = !IsNone(p.sl, p.entry) && (p.dir > 0 ? r[j].low <= p.sl  : r[j].high >= p.sl);
      bool hitTP = !IsNone(p.tp, p.entry) && (p.dir > 0 ? r[j].high >= p.tp : r[j].low <= p.tp);
      if(hitSL && hitTP)
        {
         // both in one bar: the M1 bars decide, otherwise stop (conservative)
         int res;
         datetime th;
         if(!InsideBar(p, r[j], BarEnd(r, j, n), false, res, th) || res == 0)
           {
            res = -1;
            th  = 0;
           }
         SimClose(p, tr, res, r[j].time, th);
         return;
        }
      if(hitSL || hitTP)
        {
         SimClose(p, tr, hitSL ? -1 : 1, r[j].time);
         return;
        }
     }
  }

// Darker area from entry to the exit / current price + dashed path line.
string g_trDbg[];   // last logged trade-area state per object (debug only)

void DrawTrade(const SPos &p, const STrade &tr)
  {
   string nR = ObjName(p, "ZR"), nL = ObjName(p, "PL");
   bool show = tr.triggered && !g_hidden;
   if(InpDebug)
     {
      string st = StringFormat("trade area %s: show=%d trig=%d state=%d tIn=%s tOut=%s exit=%s exists=%d",
                               nR, show, tr.triggered, tr.state, TimeToString(tr.tIn), TimeToString(tr.tOut),
                               DoubleToString(tr.exitPrice, _Digits), ObjectFind(0, nR) >= 0);
      int k = -1;
      for(int j = 0; j < ArraySize(g_trDbg); j += 2)
         if(g_trDbg[j] == nR)
            k = j;
      string key = StringFormat("%d|%d|%d|%d", show, tr.triggered, tr.state, (long)tr.tIn);
      if(k < 0 || g_trDbg[k + 1] != key)
        {
         Print("[PP] ", st);
         if(k < 0)
           {
            k = ArraySize(g_trDbg);
            ArrayResize(g_trDbg, k + 2);
            g_trDbg[k] = nR;
           }
         g_trDbg[k + 1] = key;
        }
     }
   if(!show)
     {
      if(ObjectFind(0, nR) >= 0)
         ObjectSetInteger(0, nR, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);   // hide, never delete (delete = remove position)
      if(ObjectFind(0, nL) >= 0)
         ObjectSetInteger(0, nL, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      return;
     }
   datetime tOut = tr.tOut > tr.tIn ? tr.tOut : (datetime)((long)tr.tIn + PeriodSeconds());
   bool profit = (tr.exitPrice - p.entry) * p.dir > 0;
   double k = MathMax(5, MathMin(80, InpTradeOpacity)) / 100.0;
   color want = Blend(profit ? cTP : cSL, g_bg, k);
   // MT5 combines overlapping filled background rectangles as A ^ B ^ background,
   // so pre-compensate to get exactly `want` on top of the zone.
   color zone = profit ? cZoneTP : cZoneSL;
   color c = RGB(CR(want) ^ CR(zone) ^ CR(g_bg), CG(want) ^ CG(zone) ^ CG(g_bg), CB(want) ^ CB(zone) ^ CB(g_bg));
   DrawRect(nR, tr.tIn, p.entry, tOut, tr.exitPrice, c);

   if(ObjectFind(0, nL) < 0)
      ObjectCreate(0, nL, OBJ_TREND, 0, tr.tIn, p.entry, tOut, tr.exitPrice);
   else
     {
      ObjectMove(0, nL, 0, tr.tIn, p.entry);
      ObjectMove(0, nL, 1, tOut, tr.exitPrice);
     }
   ObjectSetInteger(0, nL, OBJPROP_COLOR, cEntry);
   ObjectSetInteger(0, nL, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, nL, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, nL, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, nL, OBJPROP_RAY_LEFT, false);
   SetCommon(nL, false, 9, true);
  }

//+------------------------------------------------------------------+
//| Position drawing                                                 |
//+------------------------------------------------------------------+
void UpdateBadges(const SPos &p)
  {
   int x1, x2, yE, yS, yT;
   // badges + handles only for the active (clicked) or hovered position
   bool focus = (p.id == g_active) || IsSel(p.id) || (p.id == g_hoverId) || (g_drag.on && g_drag.id == p.id);
   bool vis = !g_hidden && focus && PosXY(p, x1, x2, yE, yS, yT);
   if(!vis)
     {
      string parts[] = {"RT", "RS", "RE", "H1", "H2", "H3", "H4"};
      for(int k = 0; k < ArraySize(parts); k++)
        {
         string nm = ObjName(p, parts[k]);
         if(ObjectFind(0, nm) >= 0)
            ObjectSetInteger(0, nm, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
        }
      return;
     }

   SCalc c;
   Calc(p, c);
   STrade tr;
   SimTrade(p, tr);
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   string sep = "   ·   ";

   bool noTP = IsNone(p.tp, p.entry), noSL = IsNone(p.sl, p.entry);
   // linked box: level not on the opening deal / order -> it was set later, not the initial one
   bool slLater = false, tpLater = false;
   if(p.ticket > 0)
     {
      SReal rr;
      if(GetReal(p.ticket, rr))
        {
         slLater = rr.slLater;
         tpLater = rr.tpLater;
        }
     }
   string tTxt = noTP ? "Target  none" :
                 StringFormat(tpLater ? "Target (set later)  %s%s%.1f %s%s" : "Target  %s%s%.1f %s%s", DoubleToString(p.tp, _Digits), sep, c.tpPips, PipUnit(),
                              c.ok ? StringFormat("%s+%.2f %s%s", sep, Money2(c.reward), cur, c.pctOk ? StringFormat(" (%.2f%%)", c.rewardPct) : "") : "");
   string sTxt = noSL ? "Stop  none" :
                 StringFormat(slLater ? "Stop (set later)  %s%s%.1f %s%s" : "Stop  %s%s%.1f %s%s", DoubleToString(p.sl, _Digits), sep, c.slPips, PipUnit(),
                              c.ok ? StringFormat("%s-%.2f %s%s", sep, Money2(c.risk), cur, c.pctOk ? StringFormat(" (%.2f%%)", c.riskPct) : "") : "");
   string lotTxt = c.ok ? DoubleToString(c.lots, LotDigits()) + " lot" + (c.belowMin ? " (MIN!)" : "") : "lot n/a";
   string eLines[];
   ArrayResize(eLines, 3);
   eLines[0] = StringFormat("%s%s%s%s", p.dir > 0 ? "LONG" : "SHORT", sep, lotTxt,
                            p.ticket > 0 ? sep + "#" + IntegerToString(p.ticket) : "");
   eLines[1] = (noSL || noTP) ? "Risk/reward  -" + (p.locked ? sep + "locked" : "")
               : StringFormat("Risk/reward  %.2f%s", c.rr, p.locked ? sep + "locked" : "");
   // P&L like TradingView: result of the simulated trade, or (not triggered yet)
   // where the current price is relative to entry. Middle badge is colored by it.
   double refPrice = tr.triggered ? tr.exitPrice : ClosePrice(p.dir);
   double plPts    = (refPrice - p.entry) * p.dir;
   double pl       = c.ok ? Money2(MoneyPerLot(p.dir, p.entry, refPrice) * c.lots) : 0.0;
   string what     = !tr.triggered ? "Price now" : (tr.state > 0 ? "Target hit" : (tr.state < 0 ? "Stop hit" : "Open P&L"));
   // money only when it can be calculated (lots + tick data), never a fake 0.00
   eLines[2] = c.ok ? StringFormat("%s  %s%.2f %s", what, pl >= 0 ? "+" : "", pl, cur) : what;
   color bgE = plPts > 0 ? cTP : (plPts < 0 ? cSL : cBadgeE);
   // box fully in the past and entry never reached -> neutral, current price is irrelevant
   if(!tr.triggered && p.t2 < TimeCurrent())
     {
      eLines[2] = "Not triggered";
      bgE = cBadgeE;
     }
   if(tr.unknown)
     {
      eLines[2] = "Real result n/a (history)";
      bgE = cBadgeE;
     }
   if(tr.real)
     {
      // real position: real money incl. commission + swap, real close reason
      double rpl = Money2(tr.pnl);
      eLines[2] = StringFormat("%s  %s%.2f %s", tr.reason, rpl >= 0 ? "+" : "", rpl, cur);
      bgE = rpl > 0 ? cTP : (rpl < 0 ? cSL : cBadgeE);
      if(!tr.closed && tr.curSL > 0 && !IsNone(tr.curSL, p.sl))
        {
         int n3 = ArraySize(eLines);
         ArrayResize(eLines, n3 + 1);
         eLines[n3] = "SL now " + DoubleToString(tr.curSL, _Digits) + (MathAbs(tr.curSL - p.entry) <= 5 * _Point ? " (BE)" : "");
        }
     }
   string tLines[1], sLines[1];
   tLines[0] = tTxt;
   sLines[0] = sTxt;

   bool onScr = x2 >= 0 && x1 < (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);   // box (partly) visible
   // centre of the visible part of the box (off screen: the real centre, stays off screen)
   int cx = onScr ? (MathMax(x1, 0) + HandleRX(x1, x2)) / 2 : (x1 + x2) / 2;
   string nT = ObjName(p, "RT"), nS = ObjName(p, "RS"), nE = ObjName(p, "RE");
     {
      int w, h;
      int boxW = HandleRX(x1, x2) - x1;
      // Like TradingView: a badge wider than the box would cover the corner handles
      // and the lines -> keep a bigger gap from its line.
      int gapNear = 4, gapFar = HANDLE_SIZE / 2 + 4;
      // Target / Stop: outside the box - upper one above its line, lower one below its line
      BuildBadge(nT, tLines, cTP, clrNONE, true, InpFontSize + 1, w, h);
      int g = (w + 2 * HANDLE_SIZE > boxW) ? gapFar : gapNear;
      PlaceBadge(nT, cx, (yT < yE) ? yT - g - h / 2 : yT + g + h / 2, w, h, true, onScr);
      BuildBadge(nS, sLines, cSL, clrNONE, true, InpFontSize + 1, w, h);
      g = (w + 2 * HANDLE_SIZE > boxW) ? gapFar : gapNear;
      PlaceBadge(nS, cx, (yS < yE) ? yS - g - h / 2 : yS + g + h / 2, w, h, true, onScr);
      // middle badge: more prominent (bold, white border). Centered on the entry line;
      // when the box is not clearly wider than it (~40 px free on each side), it moves just below the entry line.
      BuildBadge(nE, eLines, bgE, clrWhite, true, InpFontSize + 1, w, h);
      if(w + 98 > boxW)
         PlaceBadge(nE, cx, yE + gapFar + h / 2, w, h, true, onScr);
      else
         PlaceBadge(nE, cx, yE, w, h, true, onScr);
     }

   // blue grab handles (hidden for locked positions)
   bool hv = !p.locked;
   // like TradingView: square corners for Target / Stop, circle for Entry, square for width
   DrawHandle(ObjName(p, "H1"), x1, yT, false, false, hv && !Dragging(p, HIT_H_TP));
   DrawHandle(ObjName(p, "H2"), x1, yS, false, false, hv && !Dragging(p, HIT_H_SL));
   DrawHandle(ObjName(p, "H3"), x1, yE, true,  false, hv && !Dragging(p, HIT_H_E));
   DrawHandle(ObjName(p, "H4"), HandleRX(x1, x2), yE, false, true,  hv && !Dragging(p, HIT_H_R));
  }

// Like TradingView: the handle being dragged is hidden until the mouse is released,
// so it never covers the exact spot (the crosshair shows the price).
bool Dragging(const SPos &p, const int hit)
  {
   return g_drag.on && g_drag.id == p.id && g_drag.hit == hit;
  }

// Handle bitmaps: blue outline, inside filled with the chart background color
// (CHART_COLOR_BACKGROUND), anti-aliased, no hover highlight - like TradingView.
// Two shared resources per instance (square / circle), rebuilt only when the background changes.
color g_hndBg = clrNONE;
string HandleRes(const bool circle) { return "::PPH" + (circle ? "C_" : "S_") + g_inst; }

void BuildHandleRes()
  {
   if(g_hndBg == g_bg)
      return;
   int    sz = HANDLE_SIZE;
   double hw = sz / 2.0, bw = 2.0;
   uint data[];
   ArrayResize(data, sz * sz);
   for(int k = 0; k < 2; k++)
     {
      bool circle = (k == 1);
      double r = circle ? hw - 0.5 : 3.0;   // rounded square, or full circle
      for(int y = 0; y < sz; y++)
         for(int x = 0; x < sz; x++)
           {
            // signed distance to the rounded rectangle (r = half size -> circle)
            double qx = MathAbs(x + 0.5 - hw) - (hw - 0.5 - r);
            double qy = MathAbs(y + 0.5 - hw) - (hw - 0.5 - r);
            double ox = MathMax(qx, 0.0), oy = MathMax(qy, 0.0);
            double d  = MathSqrt(ox * ox + oy * oy) + MathMin(MathMax(qx, qy), 0.0) - r;
            double aOut = MathMax(0.0, MathMin(1.0, 0.5 - d));
            double aIn  = MathMax(0.0, MathMin(1.0, 0.5 - (d + bw)));
            data[y * sz + x] = aOut <= 0.0 ? 0 : ARGB(Blend(g_bg, HANDLE_COLOR, aIn), aOut);
           }
      ResourceCreate(HandleRes(circle), data, sz, sz, 0, 0, sz, COLOR_FORMAT_ARGB_NORMALIZE);
     }
   g_hndBg = g_bg;
  }

// cx / cy = ChartTimePriceToXY of the box corner. MT5 draws the box edges one pixel
// left / up of that point (right edge two pixels), so the handle is centered on the
// pixel actually drawn.
void DrawHandle(const string n, const int cx, const int cy, const bool circle, const bool right, const bool visible)
  {
   BuildHandleRes();
   if(ObjectFind(0, n) >= 0 && ObjectGetInteger(0, n, OBJPROP_TYPE) != OBJ_BITMAP_LABEL)
      ObjectDelete(0, n);   // old version used rectangle labels
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_BITMAP_LABEL, 0, 0, 0);
   int px = cx - (right ? 2 : 1), py = cy - 1;
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, px - HANDLE_SIZE / 2);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, py - HANDLE_SIZE / 2);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, HANDLE_SIZE);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, HANDLE_SIZE);
   ObjectSetString(0, n, OBJPROP_BMPFILE, 0, HandleRes(circle));
   ObjectSetString(0, n, OBJPROP_BMPFILE, 1, HandleRes(circle));
   SetCommon(n, false, 30, visible);
  }

// Which line does a hit belong to (handles highlight their line too).
int LineOfHit(const int hit)
  {
   switch(hit)
     {
      case HIT_H_TP: return HIT_TP;
      case HIT_H_SL: return HIT_SL;
      case HIT_H_E:
      case HIT_H_R:  return HIT_ENTRY;
     }
   return hit;
  }

// Line under the mouse (its handle) or being dragged: highlighted by color only,
// all box lines stay 1 px all the time.
bool LineHot(const SPos &p, const int hit)
  {
   if(g_drag.on && g_drag.id == p.id && LineOfHit(g_drag.hit) == hit)
      return true;
   return p.id == g_hoverId && LineOfHit(g_hoverHit) == hit && !p.locked;
  }

// Linked position id stored in a hidden label of the box (survives restart).
void SyncTicketObj(const SPos &p)
  {
   string n = ObjName(p, "TK");
   if(p.ticket <= 0)
     {
      if(ObjectFind(0, n) >= 0)
        {
         int k = ArraySize(g_selfDel);
         ArrayResize(g_selfDel, k + 1);
         g_selfDel[k] = n;
         ObjectDelete(0, n);
        }
      return;
     }
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetString(0, n, OBJPROP_TEXT, IntegerToString(p.ticket));
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, -1000);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, n, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
  }

// Symbol the box belongs to, stored in a hidden label of the box (survives restart).
// Chart objects stay on the chart when its symbol changes, so boxes of another symbol
// are hidden on load and come back when the chart returns to their symbol.
// Text "<symbol>", or while hidden because of a symbol change "<symbol>|F" (box was visible)
// / "<symbol>|H" (box was hidden by the user - Hide), so the Hide state survives the switch.
#define SYM_FOREIGN_VIS "|F"
#define SYM_FOREIGN_HID "|H"

void SyncSymbolObj(const SPos &p)
  {
   string n = ObjName(p, "SY");
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_XDISTANCE, -1000);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, n, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
     }
   if(ObjectGetString(0, n, OBJPROP_TEXT) != _Symbol)
      ObjectSetString(0, n, OBJPROP_TEXT, _Symbol);
  }

void DrawPos(const SPos &p)
  {
   SyncTicketObj(p);
   SyncSymbolObj(p);
   DrawRect(ObjName(p, "ZP"), p.t1, p.entry, p.t2, p.tp, cZoneTP);
   DrawRect(ObjName(p, "ZL"), p.t1, p.entry, p.t2, p.sl, cZoneSL);
   STrade tr;
   SimTrade(p, tr);
   DrawTrade(p, tr);
   // edge lines in muted color, full color while hovered / dragged
   bool hotTP = LineHot(p, HIT_TP), hotSL = LineHot(p, HIT_SL);
   DrawLine(ObjName(p, "TP"), p.t1, p.t2, p.tp, hotTP ? cTP : Blend(cTP, g_bg, 0.55), 1, STYLE_SOLID);
   DrawLine(ObjName(p, "SL"), p.t1, p.t2, p.sl, hotSL ? cSL : Blend(cSL, g_bg, 0.55), 1, STYLE_SOLID);
   DrawLine(ObjName(p, "E"),  p.t1, p.t2, p.entry, cEntry, 1, p.locked ? STYLE_DOT : STYLE_SOLID);
   UpdateBadges(p);
   if(p.id == g_active)
      PublishActive();
  }

//--- active box for the companion script PositionPlannerOrder -------
// Hidden label PPUI_ACT holds the active box (the indicator never trades; the script reads
// this, asks for confirmation and places the order):
// "PP2|symbol|id|dir|entry|sl|tp|lots|riskMoney|riskPct|pctOk|ticket|locked"  (empty = no active box)
// sl / tp: exactly "0" = none, otherwise the price as is (a price <= 0 is invalid - the script refuses it)
string ActObj() { return UIP + "ACT"; }

void PublishActive()
  {
   string o = ActObj();
   if(ObjectFind(0, o) < 0)
     {
      ObjectCreate(0, o, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, o, OBJPROP_XDISTANCE, -1000);
      ObjectSetInteger(0, o, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, o, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, o, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      ObjectSetString(0, o, OBJPROP_TOOLTIP, "\n");
     }
   string txt = "";
   int i = FindPos(g_active);
   if(i >= 0)
     {
      SPos p = g_pos[i];
      SCalc c;
      Calc(p, c);
      txt = StringFormat("PP2|%s|%d|%d|%s|%s|%s|%s|%.2f|%.4f|%d|%I64d|%d", _Symbol, p.id, p.dir,
                         DoubleToString(p.entry, _Digits),
                         IsNone(p.sl, p.entry) ? "0" : DoubleToString(p.sl, _Digits),
                         IsNone(p.tp, p.entry) ? "0" : DoubleToString(p.tp, _Digits),
                         c.ok ? DoubleToString(c.lots, LotDigits()) : "0",
                         c.risk, c.riskPct, c.pctOk ? 1 : 0, p.ticket, p.locked ? 1 : 0);
     }
   if(ObjectGetString(0, o, OBJPROP_TEXT) != txt)
      ObjectSetString(0, o, OBJPROP_TEXT, txt);
  }

void DrawAll()
  {
   for(int i = 0; i < ArraySize(g_pos); i++)
      DrawPos(g_pos[i]);
  }

void UpdateAllBadges()
  {
   for(int i = 0; i < ArraySize(g_pos); i++)
      UpdateBadges(g_pos[i]);
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
// Panel layout: key order + widths. A small extra gap separates the navigation group.
string g_btnKeys[] = {"LONG", "SHORT", "LOCK", "HIDE", "STATS", "EXPORT", "RESTORE", "CLEAR", "PREV", "CNT", "NEXT"};
int    g_btnW[]    = {BTN_W,  BTN_W,   BTN_W,  BTN_W,  BTN_W,   BTN_W,    BTN_W,     64,      24,     50,    24};
int    g_btnN      = 11;     // buttons in the current layout (static arrays, so a counter instead of resizing)
#define NAV_EXTRA_GAP 8

int BtnIndex(const string key)
  {
   for(int i = 0; i < g_btnN; i++)
      if(g_btnKeys[i] == key)
         return i;
   return -1;
  }

int BtnOffset(const int idx)   // x offset of a button from the panel's left edge
  {
   int off = 0;
   for(int i = 0; i < idx; i++)
      off += g_btnW[i] + BTN_GAP + (g_btnKeys[i + 1] == "PREV" ? NAV_EXTRA_GAP : 0);
   return off;
  }

int PanelWidth()
  {
   int last = g_btnN - 1;
   return BtnOffset(last) + g_btnW[last];
  }

// Remove a button from the panel layout (e.g. Export when not enabled in inputs).
void DropButton(const string key)
  {
   int idx = BtnIndex(key);
   if(idx < 0)
      return;
   int n = g_btnN;
   for(int k = idx; k < n - 1; k++)
     {
      g_btnKeys[k] = g_btnKeys[k + 1];
      g_btnW[k]    = g_btnW[k + 1];
     }
   g_btnN = n - 1;
   if(ObjectFind(0, UIP + key) >= 0)
      ObjectDelete(0, UIP + key);
  }

void MakeButton(const string key, const string text, const color bg, const color fg, const string tip)
  {
   int idx = BtnIndex(key);
   if(idx < 0)
      return;               // button not part of the current layout
   int bw  = g_btnW[idx];
   string n = UIP + key;
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);

   ENUM_BASE_CORNER corner = CORNER_LEFT_UPPER;
   bool right = false, lower = false;
   switch(InpCorner)
     {
      case PANEL_RIGHT_UPPER: corner = CORNER_RIGHT_UPPER; right = true; break;
      case PANEL_LEFT_LOWER:  corner = CORNER_LEFT_LOWER;  lower = true; break;
      case PANEL_RIGHT_LOWER: corner = CORNER_RIGHT_LOWER; right = true; lower = true; break;
      default: break;
     }
   // button anchor is its upper-left point, so offsets differ per corner
   int x = right ? InpPanelX + PanelWidth() - BtnOffset(idx)
                 : InpPanelX + BtnOffset(idx);
   int y = lower ? InpPanelY + BTN_H : InpPanelY;

   ObjectSetInteger(0, n, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, bw);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, BTN_H);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, n, OBJPROP_COLOR, fg);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, bg);
   ObjectSetString(0, n, OBJPROP_FONT, FONT);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, n, OBJPROP_TEXT, text);
   ObjectSetString(0, n, OBJPROP_TOOLTIP, tip);
   ObjectSetInteger(0, n, OBJPROP_STATE, false);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, n, OBJPROP_BACK, false);
   ObjectSetInteger(0, n, OBJPROP_ZORDER, 100);
  }

string RiskDescr()
  {
   switch(InpRiskMode)
     {
      case RISK_PCT_BALANCE: return StringFormat("%.2f%% of balance", InpRiskValue);
      case RISK_PCT_EQUITY:  return StringFormat("%.2f%% of equity", InpRiskValue);
      case RISK_MONEY:       return StringFormat("%.2f %s", InpRiskValue, AccountInfoString(ACCOUNT_CURRENCY));
      default:               return StringFormat("%.2f lots", InpRiskValue);
     }
  }

void CreatePanel()
  {
   string r = "risk " + RiskDescr();
   MakeButton("LONG", "Long",   cTP,  clrWhite, "LONG: click here, then click on the chart (or on a trade arrow = box of that trade) (" + r + ")");
   MakeButton("SHORT", "Short",  cSL,  clrWhite, "SHORT: click here, then click on the chart (or on a trade arrow = box of that trade) (" + r + ")");
   MakeButton("LOCK", "Lock",   cBtn, cBtnText, "Lock / unlock the active position");
   MakeButton("HIDE", "Hide",   cBtn, cBtnText, "Hide / show all positions");
   MakeButton("STATS", "Stats",  cBtn, cBtnText, "Show / hide statistics of all boxes on the chart");
   MakeButton("EXPORT", "Export", cBtn, cBtnText, "Export boxes and their simulated results to JSON (MQL5\\Files\\PositionPlanner)");
   MakeButton("RESTORE", "Restore", cBtn, cBtnText, "Restore boxes from the newest backup / export of this symbol and timeframe (click twice)");
   MakeButton("CLEAR", "Clear all", cBtn, cBtnText, "Delete ALL boxes incl. locked ones (click twice). Active box: Delete key");
   MakeButton("PREV", "◄",      cBtn, cBtnText, "Previous box on the chart (by time)");
   MakeButton("CNT", "0",      cBtn, cBtnText, "Active box / number of boxes - click to jump to the active box");
   MakeButton("NEXT", "►",      cBtn, cBtnText, "Next box on the chart (by time)");
   UpdatePanel();
  }

void UpdatePanel()
  {
   PublishActive();
   int i = FindPos(g_active);
   ObjectSetString(0, UIP + "LOCK", OBJPROP_TEXT, (i >= 0 && g_pos[i].locked) ? "Unlock" : "Lock");
   ObjectSetString(0, UIP + "HIDE", OBJPROP_TEXT, g_hidden ? "Show" : "Hide");
   bool armed = g_clearArmed != 0 && (GetTickCount() - g_clearArmed) < CLEAR_ARM_MS;
   if(!armed)
      g_clearArmed = 0;
   ObjectSetString(0, UIP + "CLEAR", OBJPROP_TEXT, armed ? "Sure?" : "Clear all");
   bool rArmed = g_restArmed != 0 && (GetTickCount() - g_restArmed) < RESTORE_ARM_MS;
   if(!rArmed)
      g_restArmed = 0;
   if(ObjectFind(0, UIP + "RESTORE") >= 0)
      ObjectSetString(0, UIP + "RESTORE", OBJPROP_TEXT, rArmed ? "Sure?" : "Restore");
   ObjectSetString(0, UIP + "LONG",  OBJPROP_TEXT, g_placeDir > 0 ? "Click..." : "Long");
   ObjectSetString(0, UIP + "SHORT", OBJPROP_TEXT, g_placeDir < 0 ? "Click..." : "Short");
   ObjectSetInteger(0, UIP + "LONG",  OBJPROP_STATE, g_placeDir > 0);
   ObjectSetInteger(0, UIP + "SHORT", OBJPROP_STATE, g_placeDir < 0);

   // counter "active / total" in time order
   int n = ArraySize(g_pos);
   string cnt = IntegerToString(n);
   if(n > 0)
     {
      int ids[];
      SortedIds(ids);
      int cur = -1;
      for(int k = 0; k < n; k++)
         if(ids[k] == g_active)
            cur = k;
      cnt = (cur >= 0 ? IntegerToString(cur + 1) : "-") + " / " + IntegerToString(n);
     }
   ObjectSetString(0, UIP + "CNT", OBJPROP_TEXT, cnt);
   ObjectSetInteger(0, UIP + "STATS", OBJPROP_STATE, g_showStats);
   UpdateStats();
  }

//--- statistics of all boxes (simulated on real bars) ----------------
#define STATS_OBJ UIP "STATSBOX"
int g_statsW = 0, g_statsH = 0;

// Keep the stats box next to the panel (above it for lower corners, below for upper).
void PlaceStats()
  {
   if(!g_showStats || g_statsW <= 0 || ObjectFind(0, STATS_OBJ) < 0)
      return;
   int cw = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int ch = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   bool right = (InpCorner == PANEL_RIGHT_UPPER || InpCorner == PANEL_RIGHT_LOWER);
   bool lower = (InpCorner == PANEL_LEFT_LOWER  || InpCorner == PANEL_RIGHT_LOWER);
   int left = right ? cw - InpPanelX - g_statsW : InpPanelX;
   int top  = lower ? ch - InpPanelY - BTN_H - 6 - g_statsH : InpPanelY + BTN_H + 6;
   PlaceBadge(STATS_OBJ, left + g_statsW / 2, top + g_statsH / 2, g_statsW, g_statsH, true);
   ObjectSetInteger(0, STATS_OBJ, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, STATS_OBJ, OBJPROP_ZORDER, 100);
  }

// Last second of the chart bar that opens at t (next bar's open - 1; months of any length).
datetime BarEndTime(const datetime t)
  {
   int sh = iBarShift(_Symbol, _Period, t, true);
   if(sh > 0)
     {
      datetime nx = iTime(_Symbol, _Period, sh - 1);
      if(nx > t)
         return (datetime)((long)nx - 1);
     }
   return (datetime)((long)t + PeriodSeconds() - 1);
  }

// Worst possible maximum drawdown of results v[] (sorted by exit interval start a[]; b[] = end).
// Overlapping exit intervals form a group with unknown order. For each group with start total
// E, wins W and losses L: highest point E + W (wins first), lowest point E - L (losses first),
// and both can happen in different groups at once -> worst DD = max(L of a group,
// highest point of an earlier group - lowest point of a later group, 0 - lowest point).
// A group joined through a chain of overlaps is treated as freely ordered, so the result is an
// upper bound: the real drawdown is never higher, in rare chained cases it can be lower.
// uncertain = some group holds both a win and a loss (order matters).
double WorstDrawdown(const datetime &a[], const datetime &b[], const double &v[], bool &uncertain)
  {
   int n = ArraySize(v);
   double E = 0, peak = 0, dd = 0;
   int i = 0;
   while(i < n)
     {
      datetime end = b[i];
      double W = 0, L = 0;
      int j = i;
      while(j < n && (j == i || a[j] <= end))
        {
         if(b[j] > end)
            end = b[j];
         if(v[j] > 0)
            W += v[j];
         else
            L -= v[j];
         j++;
        }
      if(W > 0 && L > 0 && j - i > 1)
         uncertain = true;
      dd   = MathMax(dd, MathMax(L, peak - (E - L)));
      peak = MathMax(peak, E + W);
      E   += W - L;
      i = j;
     }
   return dd;
  }

// 200 s -> "3 min", 11700 s -> "3 h 15 min", 2 days -> "2 d 0 h"
string FmtDuration(const double sec)
  {
   long s = (long)MathRound(sec);
   if(s < 3600)
      return IntegerToString(s / 60) + " min";
   if(s < 86400)
      return StringFormat("%I64d h %02I64d min", s / 3600, (s % 3600) / 60);
   return StringFormat("%I64d d %I64d h", s / 86400, (s % 86400) / 3600);
  }

void UpdateStats()
  {
   // armed Restore: the stats box asks the question instead (no modal window)
   if(g_restArmed != 0 && (GetTickCount() - g_restArmed) < RESTORE_ARM_MS && g_restFile != "")
     {
      string f = g_restFile;
      StringReplace(f, "PositionPlanner\\", "");
      string q[3];
      q[0] = StringFormat("Restore %d of %d box(es)?", g_restFresh, g_restTotal);
      q[1] = "from  " + f;
      q[2] = StringFormat("Click Restore again (%d s) to confirm", RESTORE_ARM_MS / 1000);
      BuildBadge(STATS_OBJ, q, C'30,34,45', C'90,95,110', false, InpFontSize + 1, g_statsW, g_statsH);
      ObjectSetInteger(0, STATS_OBJ, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
      bool was = g_showStats;
      g_showStats = true;        // PlaceStats only places a shown box
      PlaceStats();
      g_showStats = was;
      return;
     }
   if(!g_showStats)
     {
      if(ObjectFind(0, STATS_OBJ) >= 0)
         ObjectSetInteger(0, STATS_OBJ, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      return;
     }
   int n = ArraySize(g_pos), trig = 0, tp = 0, sl = 0, be = 0, open = 0, unk = 0;
   double totR = 0, totUsd = 0;
   bool   usdOk = true;   // every counted trade has a money result
   datetime cT[], cB[];    // closed trades: exit time interval (from, to), R, money, money known
   double   cR[], cM[];
   bool     cOk[];
   bool     ddRok = true;
   double   durSum = 0;
   int      durN = 0;
   bool     durBar = false; // some durations come from bar times (simulated boxes)
   int ids[], openNo[];   // open boxes by their number in the panel counter (time order)
   SortedIds(ids);
   for(int i = 0; i < n; i++)
     {
      SPos p = g_pos[i];
      STrade tr;
      SimTrade(p, tr);
      if(tr.unknown)
        {
         unk++;
         continue;
        }
      if(!tr.triggered)
         continue;
      trig++;
      if(!tr.closed)
        {
         open++;
         for(int k = 0; k < n; k++)
            if(ids[k] == p.id)
              {
               int m = ArraySize(openNo);
               ArrayResize(openNo, m + 1);
               openNo[m] = k + 1;
              }
        }
      else
         if(tr.state > 0)
            tp++;
         else
            if(tr.state < 0)
               sl++;
            else
               be++;
      double rMul = !IsNone(p.sl, p.entry) ? (tr.exitPrice - p.entry) * p.dir / MathAbs(p.entry - p.sl) : 0;
      totR += rMul;
      double mon = 0;
      bool   monOk = true;
      if(tr.real)
         mon = Money2(tr.pnl);                           // real money incl. costs
      else
        {
         SCalc c;
         Calc(p, c);
         if(c.ok)
            mon = Money2(MoneyPerLot(p.dir, p.entry, tr.exitPrice) * c.lots);   // sum of rounded trades, like a statement
         else
            monOk = false;
        }
      if(monOk)
         totUsd += mon;
      else
         usdOk = false;
      if(tr.closed)
        {
         // closed trades for drawdown (in exit order) and average time in trade
         datetime tI = tr.real ? tr.tInExact : tr.tIn, tO = tr.real ? tr.tOutExact : tr.tOut;
         // when the exit happened, as far as it is known: real = exact, M1 = that minute, else the bar
         datetime tA = tr.real ? tr.tOutExact : tr.tExit;
         datetime tB = tr.real ? tA : (tr.exitMin ? (datetime)((long)tA + 59) : BarEndTime(tA));
         int m = ArraySize(cT);
         ArrayResize(cT, m + 1);
         ArrayResize(cB, m + 1);
         ArrayResize(cR, m + 1);
         ArrayResize(cM, m + 1);
         ArrayResize(cOk, m + 1);
         if(IsNone(p.sl, p.entry))
            ddRok = false;          // no stop -> no R for this trade -> no drawdown in R
         cT[m] = tA;
         cB[m] = tB;
         cR[m] = rMul;
         cM[m] = mon;
         cOk[m] = monOk;
         if(tO >= tI && tI > 0)
           {
            durSum += (double)((long)tO - (long)tI);
            durN++;
            if(!tr.real)
               durBar = true;
           }
        }
     }
   // max drawdown: largest fall of the running total from its peak (start = 0), closed trades
   // in exit order. Trades whose exit times overlap (same bar / minute, order not known) form a
   // group; the worst possible order inside every group is taken -> exact worst case.
   int nc = ArraySize(cT);
   for(int i = 1; i < nc; i++)   // insertion sort by the start of the exit interval
     {
      datetime t = cT[i], tb = cB[i];
      double r = cR[i], mo = cM[i];
      bool ok = cOk[i];
      int j = i - 1;
      while(j >= 0 && cT[j] > t)
        {
         cT[j + 1] = cT[j];
         cB[j + 1] = cB[j];
         cR[j + 1] = cR[j];
         cM[j + 1] = cM[j];
         cOk[j + 1] = cOk[j];
         j--;
        }
      cT[j + 1] = t;
      cB[j + 1] = tb;
      cR[j + 1] = r;
      cM[j + 1] = mo;
      cOk[j + 1] = ok;
     }
   bool ddMOk = true, ddWorst = false;
   for(int i = 0; i < nc; i++)
      if(!cOk[i])
         ddMOk = false;
   double ddR = WorstDrawdown(cT, cB, cR, ddWorst);
   bool   wM  = false;
   double ddM = WorstDrawdown(cT, cB, cM, wM);
   ddWorst = ddWorst || wM;
   string sep = "   ·   ";
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   string lines[];
   ArrayResize(lines, open > 0 ? 7 : 6);
   lines[0] = StringFormat("Boxes %d%striggered %d%snot triggered %d", n, sep, trig, sep, n - trig - unk) +
              (unk > 0 ? StringFormat("%sn/a %d", sep, unk) : "");
   lines[1] = StringFormat("Win %d%sLoss %d%sBE %d%sopen %d", tp, sep, sl, sep, be, sep, open);
   lines[2] = (tp + sl) > 0 ? StringFormat("Win rate  %.1f %%", 100.0 * tp / (tp + sl)) : "Win rate  -";
   lines[3] = StringFormat("Total  %s%.2f R%s", totR >= 0 ? "+" : "", totR, sep) +
              (usdOk ? StringFormat("%s%.2f %s", totUsd >= 0 ? "+" : "", totUsd, cur) : "money n/a");
   lines[4] = nc > 0 ? "Max drawdown  " + (ddRok ? StringFormat("-%.2f R", ddR) : "R n/a") + sep +
                       (ddMOk ? StringFormat("-%.2f %s", ddM, cur) : "money n/a") +
                       (ddWorst ? "  (worst case)" : "")
                     : "Max drawdown  -";
   lines[5] = durN > 0 ? "Avg time in trade  " + (durBar ? "~" : "") + FmtDuration(durSum / durN)
                       : "Avg time in trade  -";
   if(open > 0)
     {
      // which boxes are open: the same numbers as the panel counter  ◄ n / total ►
      ArraySort(openNo);
      int no = ArraySize(openNo), show = MathMin(no, 10);
      string l = "Open boxes  ";
      for(int k = 0; k < show; k++)
         l += (k > 0 ? ", " : "") + IntegerToString(openNo[k]);
      if(no > show)
         l += StringFormat(" … (+%d)", no - show);
      lines[6] = l + "   (◄ n / " + IntegerToString(n) + " ►)";
     }

   BuildBadge(STATS_OBJ, lines, C'30,34,45', C'90,95,110', false, InpFontSize + 1, g_statsW, g_statsH, 3);   // Total
   PlaceStats();
  }

//--- JSON export ------------------------------------------------------
string JStr(const string v)
  {
   string r = v;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, "\"", "\\\"");
   return "\"" + r + "\"";
  }

string JNum(const double v, const int digits) { return DoubleToString(v, digits); }

string JTime(const datetime t)
  {
   if(t <= 0)
      return "null";
   string s = TimeToString(t, TIME_DATE | TIME_SECONDS);   // 2026.11.17 19:35:00
   StringReplace(s, ".", "-");
   StringReplace(s, " ", "T");
   return "\"" + s + "\"";
  }

string RiskModeName()
  {
   switch(InpRiskMode)
     {
      case RISK_PCT_BALANCE: return "percent_of_balance";
      case RISK_PCT_EQUITY:  return "percent_of_equity";
      case RISK_MONEY:       return "fixed_money";
      default:               return "fixed_lots";
     }
  }

string SafeFileName(const string v)
  {
   string r = v;
   string bad[] = {"\\", "/", ":", "*", "?", "\"", "<", ">", "|"};
   for(int k = 0; k < ArraySize(bad); k++)
      StringReplace(r, bad[k], "_");
   return r;
  }

// Export statistics accumulator (all / trade / manual). Sums are kept unrounded.
struct SExpStat
  {
   int    boxes, trig, tp, sl, be, open, unk;
   double totR, totUsd;
   bool   usdMissing;   // some counted trade has no money result -> total unknown
  };

void StatAdd(SExpStat &st, const STrade &tr, const double rMul, const double plRaw, const bool plOk)
  {
   st.boxes++;
   if(tr.unknown)
     {
      st.unk++;
      return;
     }
   if(!tr.triggered)
      return;
   if(!plOk)
      st.usdMissing = true;
   st.trig++;
   if(!tr.closed)
      st.open++;
   else
      if(tr.state > 0)
         st.tp++;
      else
         if(tr.state < 0)
            st.sl++;
         else
            st.be++;
   st.totR   += rMul;
   st.totUsd += plRaw;
  }

string StatJson(const SExpStat &st, const string ind)
  {
   string r = "{\n";
   r += ind + "  \"boxes\": " + IntegerToString(st.boxes) + ",\n";
   r += ind + "  \"triggered\": " + IntegerToString(st.trig) + ",\n";
   r += ind + "  \"target_hit\": " + IntegerToString(st.tp) + ",\n";
   r += ind + "  \"stop_hit\": " + IntegerToString(st.sl) + ",\n";
   r += ind + "  \"break_even\": " + IntegerToString(st.be) + ",\n";
   r += ind + "  \"open\": " + IntegerToString(st.open) + ",\n";
   r += ind + "  \"win_rate_percent\": " + ((st.tp + st.sl) > 0 ? JNum(100.0 * st.tp / (st.tp + st.sl), 1) : "null") + ",\n";
   r += ind + "  \"total_r\": " + JNum(st.totR, 4) + ",\n";
   r += ind + "  \"unavailable\": " + IntegerToString(st.unk) + ",\n";
   r += ind + "  \"total_pnl_money\": " + (st.usdMissing ? "null" : JNum(Money2(st.totUsd), 2)) + "\n";
   r += ind + "}";
   return r;
  }

// Writes all boxes (or only locked ones) with their simulated results to
// MQL5\Files\PositionPlanner\<symbol>_<tf>_<time>.json (UTF-8). Times are broker server time.
// onlyId > 0: export just that box (context menu), otherwise all / locked boxes.
void ExportJson(const int onlyId = 0)
  {
   int ids[];
   if(onlyId > 0)
     {
      ArrayResize(ids, 1);
      ids[0] = onlyId;
     }
   else
      SortedIds(ids);
   string tf = StringSubstr(EnumToString(_Period), 7);   // PERIOD_M5 -> M5
   string stamp = TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS);
   StringReplace(stamp, ".", "");
   StringReplace(stamp, ":", "");
   StringReplace(stamp, " ", "_");
   string file = "PositionPlanner\\" + SafeFileName(_Symbol) + "_" + tf + "_" + stamp +
                 (onlyId > 0 ? "_box" + IntegerToString(onlyId) : "") + ".json";

   int h = FileOpen(file, FILE_WRITE | FILE_TXT | FILE_ANSI, 0, CP_UTF8);
   if(h == INVALID_HANDLE)
     {
      Alert("PositionPlanner: export failed, error ", GetLastError());
      return;
     }
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   int ld = LotDigits();
   double pip = PipSize();
   FileWriteString(h, "{\n");
   FileWriteString(h, "  \"schema_version\": 1,\n");
   FileWriteString(h, "  \"tool\": \"PositionPlanner\",\n");
   FileWriteString(h, "  \"exported_local\": " + JTime(TimeLocal()) + ",\n");
   FileWriteString(h, "  \"times_are\": \"broker server time\",\n");
   FileWriteString(h, "  \"symbol\": " + JStr(_Symbol) + ",\n");
   FileWriteString(h, "  \"account\": " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ",\n");
   FileWriteString(h, "  \"server\": " + JStr(AccountInfoString(ACCOUNT_SERVER)) + ",\n");
   FileWriteString(h, "  \"timeframe\": " + JStr(tf) + ",\n");
   FileWriteString(h, "  \"digits\": " + IntegerToString(_Digits) + ",\n");
   FileWriteString(h, "  \"point\": " + JNum(_Point, _Digits) + ",\n");
   FileWriteString(h, "  \"pip_size\": " + JNum(pip, _Digits) + ",\n");
   FileWriteString(h, "  \"distance_unit\": " + JStr(PipUnit()) + ",\n");
   FileWriteString(h, "  \"tick_size\": " + JNum(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), _Digits) + ",\n");
   FileWriteString(h, "  \"tick_value\": " + JNum(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), 6) + ",\n");
   FileWriteString(h, "  \"account_currency\": " + JStr(cur) + ",\n");
   FileWriteString(h, "  \"balance\": " + JNum(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ",\n");
   FileWriteString(h, "  \"risk_mode\": " + JStr(RiskModeName()) + ",\n");
   FileWriteString(h, "  \"risk_value\": " + JNum(InpRiskValue, 4) + ",\n");
   FileWriteString(h, "  \"locked_only\": " + ((InpExportLockedOnly && onlyId <= 0) ? "true" : "false") + ",\n");
   FileWriteString(h, "  \"boxes\": [");

   int cnt = 0;
   SExpStat stAll, stTrade, stManual;
   ZeroMemory(stAll);
   ZeroMemory(stTrade);
   ZeroMemory(stManual);
   for(int k = 0; k < ArraySize(ids); k++)
     {
      int i = FindPos(ids[k]);
      if(i < 0)
         continue;
      SPos p = g_pos[i];
      if(InpExportLockedOnly && !p.locked && onlyId <= 0)
         continue;
      SCalc c;
      Calc(p, c);
      STrade tr;
      SimTrade(p, tr);
      string status;
      if(tr.unknown)
         status = "unavailable";
      else
      if(!tr.triggered)
         status = "not_triggered";
      else
         if(!tr.closed)
            status = "open";
         else
            if(tr.real)
              {
               status = tr.reason;
               StringToLower(status);
               StringReplace(status, " (in profit)", "_in_profit");
               StringReplace(status, " ", "_");
               StringReplace(status, "-", "_");
              }
            else
               status = tr.state > 0 ? "target_hit" : "stop_hit";
      bool   hasRisk = !IsNone(p.sl, p.entry);
      double risk = MathAbs(p.entry - p.sl);
      double rMul = (tr.triggered && hasRisk) ? (tr.exitPrice - p.entry) * p.dir / risk : 0;
      // unrounded money for the statistics, rounded to cents only for the per-box field
      double plRaw = tr.real ? tr.pnl : ((tr.triggered && c.ok) ? MoneyPerLot(p.dir, p.entry, tr.exitPrice) * c.lots : 0);
      double pl    = Money2(plRaw);
      bool plOk = tr.real || c.ok;
      StatAdd(stAll, tr, rMul, plRaw, plOk);
      if(p.ticket > 0)
         StatAdd(stTrade, tr, rMul, plRaw, plOk);
      else
         StatAdd(stManual, tr, rMul, plRaw, plOk);

      string b = (cnt > 0 ? "," : "") + "\n    {\n";
      b += "      \"id\": " + IntegerToString(p.id) + ",\n";
      b += "      \"source\": " + JStr(p.ticket > 0 ? "trade" : "manual") + ",\n";
      b += "      \"position_id\": " + (p.ticket > 0 ? IntegerToString(p.ticket) : "null") + ",\n";
      b += "      \"direction\": " + JStr(p.dir > 0 ? "long" : "short") + ",\n";
      b += "      \"locked\": " + (p.locked ? "true" : "false") + ",\n";
      b += "      \"entry\": " + JNum(p.entry, _Digits) + ",\n";
      b += "      \"stop\": " + (hasRisk ? JNum(p.sl, _Digits) : "null") + ",\n";
      b += "      \"target\": " + (IsNone(p.tp, p.entry) ? "null" : JNum(p.tp, _Digits)) + ",\n";
      {
         // linked box: level not on the opening deal / order -> set later, not the initial one
         SReal rx;
         bool  gotR = p.ticket > 0 && GetReal(p.ticket, rx);
         b += "      \"stop_set_later\": " + ((gotR && rx.slLater && hasRisk) ? "true" : "false") + ",\n";
         b += "      \"target_set_later\": " + ((gotR && rx.tpLater && !IsNone(p.tp, p.entry)) ? "true" : "false") + ",\n";
      }
      b += "      \"time_start\": " + JTime(p.t1) + ",\n";
      b += "      \"time_end\": " + JTime(p.t2) + ",\n";
      b += "      \"stop_distance\": " + JNum(c.slPips, 1) + ",\n";
      b += "      \"target_distance\": " + JNum(c.tpPips, 1) + ",\n";
      b += "      \"risk_reward\": " + ((hasRisk && !IsNone(p.tp, p.entry)) ? JNum(c.rr, 4) : "null") + ",\n";
      b += "      \"lots\": " + (c.ok ? JNum(c.lots, ld) : "null") + ",\n";
      b += "      \"risk_money\": " + (c.ok ? JNum(Money2(c.risk), 2) : "null") + ",\n";
      b += "      \"reward_money\": " + (c.ok ? JNum(Money2(c.reward), 2) : "null") + ",\n";
      b += "      \"lot_below_min\": " + (c.belowMin ? "true" : "false") + ",\n";
      b += "      \"result\": {\n";
      b += "        \"status\": " + JStr(status) + ",\n";
      // real trades: exact deal times; simulated boxes: bar times
      b += "        \"entry_time\": " + (tr.triggered ? JTime(tr.real ? tr.tInExact : tr.tIn) : "null") + ",\n";
      b += "        \"exit_time\": " + ((tr.triggered && tr.closed) ? JTime(tr.real ? tr.tOutExact : tr.tOut) : "null") + ",\n";
      b += "        \"time_precision\": " + (tr.triggered ? JStr(tr.real ? "exact" : "bar") : "null") + ",\n";
      b += "        \"exit_price\": " + (tr.triggered ? JNum(tr.exitPrice, _Digits) : "null") + ",\n";
      b += "        \"r_multiple\": " + ((tr.triggered && hasRisk) ? JNum(rMul, 4) : "null") + ",\n";
      b += "        \"pnl_money\": " + (tr.triggered && (c.ok || tr.real) ? JNum(pl, 2) : "null") + ",\n";
      b += "        \"pnl_includes_costs\": " + (tr.real ? "true" : "false") + ",\n";
      b += "        \"real_volume\": " + (tr.real ? JNum(tr.volume, ld) : "null") + ",\n";
      b += "        \"current_sl\": " + ((tr.real && !tr.closed && tr.curSL > 0) ? JNum(tr.curSL, _Digits) : "null") + "\n";
      b += "      }\n    }";
      FileWriteString(h, b);
      cnt++;
     }
   FileWriteString(h, (cnt > 0 ? "\n  " : "") + "],\n");
   FileWriteString(h, "  \"stats\": " + StatJson(stAll, "  ") + ",\n");
   FileWriteString(h, "  \"stats_by_source\": {\n");
   FileWriteString(h, "    \"trade\": " + StatJson(stTrade, "    ") + ",\n");
   FileWriteString(h, "    \"manual\": " + StatJson(stManual, "    ") + "\n");
   FileWriteString(h, "  }\n}\n");
   FileClose(h);

   string full = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\" + file;
   Print("PositionPlanner: exported ", cnt, " box(es) to ", full);
   Alert("PositionPlanner: exported ", cnt, " box(es) -> ", full);   // one line: Alert shows only the first line
  }

// Position ids sorted by box start time (oldest first).
void SortedIds(int &ids[])
  {
   int n = ArraySize(g_pos);
   ArrayResize(ids, n);
   datetime tm[];
   ArrayResize(tm, n);
   for(int i = 0; i < n; i++)
     {
      ids[i] = g_pos[i].id;
      tm[i]  = g_pos[i].t1;
     }
   for(int i = 1; i < n; i++)   // insertion sort (few boxes)
     {
      int id = ids[i];
      datetime t = tm[i];
      int j = i - 1;
      while(j >= 0 && tm[j] > t)
        {
         ids[j + 1] = ids[j];
         tm[j + 1]  = tm[j];
         j--;
        }
      ids[j + 1] = id;
      tm[j + 1]  = t;
     }
  }

// Scroll the chart so the box is in the middle of the screen.
void CenterOn(const SPos &p)
  {
   ChartSetInteger(0, CHART_AUTOSCROLL, false);
   int vis = (int)ChartGetInteger(0, CHART_WIDTH_IN_BARS);
   datetime mid = (datetime)((long)p.t1 + ((long)p.t2 - (long)p.t1) / 2);
   datetime t0  = iTime(_Symbol, _Period, 0);
   int ps = PeriodSeconds();
   int shMid;
   if(mid >= t0)
      shMid = -(int)(((long)mid - (long)t0) / ps);   // future: negative shift
   else
      shMid = iBarShift(_Symbol, _Period, mid, false);
   int rightBar = shMid - vis / 2;                   // index of the rightmost visible bar
   if(rightBar < 0)
      rightBar = 0;
   ChartNavigate(0, CHART_END, -rightBar);
  }

void Navigate(const int step)
  {
   int n = ArraySize(g_pos);
   if(n == 0)
      return;
   SetHidden(false);
   int ids[];
   SortedIds(ids);
   int cur = -1;
   for(int k = 0; k < n; k++)
      if(ids[k] == g_active)
         cur = k;
   int nx = (cur < 0) ? (step > 0 ? 0 : n - 1) : (cur + step + n) % n;
   SetActive(ids[nx]);
   int i = FindPos(ids[nx]);
   if(i >= 0)
     {
      CenterOn(g_pos[i]);
      DbgPos(StringFormat("navigate %d/%d", nx + 1, n), g_pos[i]);
     }
   UpdatePanel();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Position management                                              |
//+------------------------------------------------------------------+
void SetHidden(const bool h)
  {
   if(g_hidden == h)
      return;
   g_hidden = h;
   DrawAll();
  }

// Average bar range (ATR 14) around time t, x1.5 -> volatility based default SL.
double AutoSLDistance(const datetime t)
  {
   int sh = iBarShift(_Symbol, _Period, t, false);
   if(sh < 0)
      sh = 0;
   MqlRates r[];
   int n = CopyRates(_Symbol, _Period, sh, 15, r);
   double sum = 0;
   int cnt = 0;
   for(int i = 1; i < n; i++)
     {
      double tr = MathMax(r[i].high, r[i - 1].close) - MathMin(r[i].low, r[i - 1].close);
      sum += tr;
      cnt++;
     }
   double atr = cnt > 0 ? sum / cnt : 0;
   double d = atr * 1.5;
   if(d < 10 * _Point)
      d = 100 * _Point;
   return d;
  }

// "pips" only where a pip differs from a point (3/5-digit FX), otherwise "pts".
string PipUnit() { return PipSize() > _Point ? "pips" : "pts"; }

//--- box from an executed trade ---------------------------------------
// Start of the bar that contains time t (history), or grid bar in the future.
datetime BarStart(const datetime t)
  {
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t >= t0)
      return (datetime)((long)t0 + ((long)t - (long)t0) / PeriodSeconds() * PeriodSeconds());
   int sh = iBarShift(_Symbol, _Period, t, false);
   return sh >= 0 ? iTime(_Symbol, _Period, sh) : t;
  }

#define TRADE_PICK_PX 12

// Direction / entry / SL / TP of a linked box from its real position.
// Missing or invalid SL / TP stay "none" (= entry) - nothing is guessed.
void ApplyRealLevels(SPos &p, const SReal &r)
  {
   double sl = r.initSL, tp = r.initTP;
   if(sl <= 0 || (r.dir > 0 ? sl >= r.entry : sl <= r.entry))
      sl = r.entry;
   if(tp <= 0 || (r.dir > 0 ? tp <= r.entry : tp >= r.entry))
      tp = r.entry;
   p.dir   = r.dir;
   p.entry = NormPrice(r.entry);
   p.sl    = NormPrice(sl);
   p.tp    = NormPrice(tp);
  }

// Finds the entry deal (this symbol) whose arrow is nearest to the click (within
// TRADE_PICK_PX) and builds the box from it: real entry, SL/TP, entry and exit bar.
bool BoxFromTrade(const int x, const int y, SPos &p)
  {
   if(!HistorySelect(0, TimeCurrent() + 86400))
      return false;
   int total = HistoryDealsTotal();
   ulong best = 0;
   int bestD = TRADE_PICK_PX + 1;
   for(int k = 0; k < total; k++)
     {
      ulong tk = HistoryDealGetTicket(k);
      if(tk == 0 || HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol)
         continue;
      long en = HistoryDealGetInteger(tk, DEAL_ENTRY);
      long ty = HistoryDealGetInteger(tk, DEAL_TYPE);
      if((en != DEAL_ENTRY_IN && en != DEAL_ENTRY_INOUT) || (ty != DEAL_TYPE_BUY && ty != DEAL_TYPE_SELL))
         continue;
      int dx, dy;
      if(!ChartTimePriceToXY(0, 0, BarStart((datetime)HistoryDealGetInteger(tk, DEAL_TIME)),
                             HistoryDealGetDouble(tk, DEAL_PRICE), dx, dy))
         continue;
      int d = MathMax(MathAbs(dx - x), MathAbs(dy - y));
      if(d < bestD)
        {
         bestD = d;
         best  = tk;
        }
     }
   if(best == 0)
      return false;

   long posId = HistoryDealGetInteger(best, DEAL_POSITION_ID);
   SReal r;
   if(!LoadReal(posId, r))
      return false;

   ZeroMemory(p);
   p.ticket = posId;
   ApplyRealLevels(p, r);
   p.locked = true;          // real trade: protected; unlock + move a level = unlink
   long ps  = PeriodSeconds();
   p.t1     = BarStart(r.tIn);
   if(r.open)
      p.t2 = (datetime)MathMax((long)p.t1 + MathMax(InpBoxBars, 2) * ps, (long)iTime(_Symbol, _Period, 0) + 5 * ps);
   else
      p.t2 = BarStart(r.tOut);
   if(p.t2 <= p.t1)
      p.t2 = (datetime)((long)p.t1 + ps);
   Dbg(StringFormat("box from deal #%I64u position #%I64d", best, posId));
   return true;
  }

// Adds a prepared box (id assigned here) and activates it.
void AddBox(SPos &p)
  {
   SetHidden(false);
   p.id = g_nextId++;
   int n = ArraySize(g_pos);
   ArrayResize(g_pos, n + 1);
   g_pos[n] = p;
   SetActive(p.id);
   ChartRedraw();
   DbgPos("new", p);
  }

void NewPos(const int dir, const datetime tc, const double price)
  {
   SetHidden(false);

   SPos p;
   ZeroMemory(p);
   p.id  = g_nextId++;
   p.dir = dir;

   double dist = InpDefaultSL > 0 ? InpDefaultSL * PipSize() : AutoSLDistance(tc);
   if(dist <= 0)
      dist = 100 * _Point;
   double rr = InpDefaultRR > 0 ? InpDefaultRR : 1.0;

   p.entry = NormPrice(price);
   p.sl    = NormPrice(price - dir * dist);
   p.tp    = NormPrice(price + dir * dist * rr);

   // box starts at the clicked bar (entry line at the clicked price)
   int  bars = MathMax(InpBoxBars, 2);
   long ps   = PeriodSeconds();
   p.t1 = SnapTime(tc);
   // zoomed-in chart: no wider than the visible chart to the right of the click
   // (MT5 draws 2^scale px per bar), so the right edge and its handle stay on screen
   int xc, yc;
   if(ChartTimePriceToXY(0, 0, p.t1, price, xc, yc))
     {
      int barPx = 1 << (int)ChartGetInteger(0, CHART_SCALE);
      int room  = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS) - HANDLE_SIZE - xc;
      bars = MathMax(2, MathMin(bars, room / MathMax(barPx, 1)));
     }
   p.t2 = SnapTime((datetime)((long)p.t1 + bars * ps));
   if(p.t2 <= p.t1)
      p.t2 = (datetime)((long)p.t1 + bars * ps);

   int n = ArraySize(g_pos);
   ArrayResize(g_pos, n + 1);
   g_pos[n] = p;

   SetActive(p.id);
   ChartRedraw();
   DbgPos("new", p);
  }

void RemoveFromCache(const int id)
  {
   int i = FindPos(id);
   if(i < 0)
      return;
   int n = ArraySize(g_pos);
   for(int k = i; k < n - 1; k++)
      g_pos[k] = g_pos[k + 1];
   ArrayResize(g_pos, n - 1);
  }

void DeletePos(const int id)
  {
   if(FindPos(id) < 0)
      return;
   RemoveFromCache(id);              // first, so async delete events for this id are ignored
   ObjectsDeleteAll(0, PosPrefix(id));
   FreeBadges(PosPrefix(id));
   Dbg(StringFormat("deleted id=%d", id));
   if(g_active == id)
      g_active = -1;
   if(g_hoverId == id)
      g_hoverId = -1;
   SelRemove(id);
   UpdatePanel();
   ChartRedraw();
  }

void DeleteAllPos()
  {
   // all boxes of this symbol, locked ones too (the only way to delete a locked box without
   // unlocking it) - boxes of other symbols (hidden) stay on the chart
   int ids[];
   int n = ArraySize(g_pos);
   ArrayResize(ids, n);
   for(int i = 0; i < n; i++)
      ids[i] = g_pos[i].id;
   ArrayResize(g_pos, 0);   // first, so the async delete events are ignored
   for(int i = 0; i < n; i++)
     {
      ObjectsDeleteAll(0, PosPrefix(ids[i]));
      FreeBadges(PosPrefix(ids[i]));
     }
   g_active  = -1;
   g_hoverId = -1;
   ArrayResize(g_sel, 0);
   Dbg("deleted all positions");
   UpdatePanel();
   ChartRedraw();
  }

//--- multi-selection (Ctrl+click): g_active + g_sel[] ---------------
bool IsSel(const int id)
  {
   for(int k = 0; k < ArraySize(g_sel); k++)
      if(g_sel[k] == id)
         return true;
   return false;
  }

void SelRemove(const int id)
  {
   int n = ArraySize(g_sel);
   for(int k = 0; k < n; k++)
      if(g_sel[k] == id)
        {
         for(int j = k; j < n - 1; j++)
            g_sel[j] = g_sel[j + 1];
         ArrayResize(g_sel, n - 1);
         return;
        }
  }

void SelClear()
  {
   int ids[];
   ArrayCopy(ids, g_sel);
   ArrayResize(g_sel, 0);
   for(int k = 0; k < ArraySize(ids); k++)
     {
      int i = FindPos(ids[k]);
      if(i >= 0)
         DrawPos(g_pos[i]);
     }
  }

// all selected boxes: the active one + Ctrl+clicked ones
int SelectedIds(int &ids[])
  {
   ArrayResize(ids, 0);
   if(FindPos(g_active) >= 0)
     {
      ArrayResize(ids, 1);
      ids[0] = g_active;
     }
   for(int k = 0; k < ArraySize(g_sel); k++)
      if(FindPos(g_sel[k]) >= 0 && g_sel[k] != g_active)
        {
         int n = ArraySize(ids);
         ArrayResize(ids, n + 1);
         ids[n] = g_sel[k];
        }
   return ArraySize(ids);
  }

// Ctrl+click on a box: add it to the selection (it becomes the active one) or remove it.
void SelToggle(const int id)
  {
   if(id == g_active)
     {
      int n = ArraySize(g_sel);
      int next = n > 0 ? g_sel[n - 1] : -1;
      if(n > 0)
         ArrayResize(g_sel, n - 1);
      SetActive(next, true);
     }
   else
      if(IsSel(id))
        {
         SelRemove(id);
         int i = FindPos(id);
         if(i >= 0)
            DrawPos(g_pos[i]);
        }
      else
        {
         if(g_active >= 0 && FindPos(g_active) >= 0)
           {
            int n = ArraySize(g_sel);
            ArrayResize(g_sel, n + 1);
            g_sel[n] = g_active;
           }
         SetActive(id, true);
        }
   Dbg(StringFormat("selection: active=%d + %d more", g_active, ArraySize(g_sel)));
  }

// Deletes the selected boxes; locked ones are skipped (unlock first or use Clear all).
void DeleteSelected()
  {
   int ids[];
   int n = SelectedIds(ids), skipped = 0;
   for(int k = 0; k < n; k++)
     {
      int i = FindPos(ids[k]);
      if(i < 0)
         continue;
      if(g_pos[i].locked)
         skipped++;
      else
         DeletePos(ids[k]);
     }
   Dbg(StringFormat("delete selected: %d box(es), %d locked skipped", n - skipped, skipped));
  }

void SetActive(const int id, const bool keepSel = false)
  {
   if(!keepSel && ArraySize(g_sel) > 0)
      SelClear();
   int prev = g_active;
   g_active = id;
   int i = FindPos(prev);
   if(i >= 0 && prev != id)
      DrawPos(g_pos[i]);
   i = FindPos(id);
   if(i >= 0)
      DrawPos(g_pos[i]);
   UpdatePanel();
  }

//+------------------------------------------------------------------+
//| Mouse: hover, drag                                               |
//+------------------------------------------------------------------+
//--- protection of real trade levels ---------------------------------
// While the mouse is over one of our boxes, MT5's own dragging of real
// order/position SL/TP lines is switched off, so dragging our lines can
// never modify a real trade. Restored as soon as the mouse leaves.
bool g_tradeDragOff   = false;
bool g_tradeDragSaved = true;
bool g_ctxMenuSaved   = true;   // MT5 right-click menu, replaced by ours over a box

#define BLOCK_MARGIN 12   // px around a box where trade-level dragging is blocked

void BlockTradeDrag(const bool block)
  {
   if(block && !g_tradeDragOff)
     {
      g_tradeDragSaved = (bool)ChartGetInteger(0, CHART_DRAG_TRADE_LEVELS);
      ChartSetInteger(0, CHART_DRAG_TRADE_LEVELS, false);
      g_ctxMenuSaved = (bool)ChartGetInteger(0, CHART_CONTEXT_MENU);
      ChartSetInteger(0, CHART_CONTEXT_MENU, false);
      g_tradeDragOff = true;
      Dbg("trade level dragging blocked");
     }
   else
      if(!block && g_tradeDragOff)
        {
         ChartSetInteger(0, CHART_DRAG_TRADE_LEVELS, g_tradeDragSaved);
         ChartSetInteger(0, CHART_CONTEXT_MENU, g_ctxMenuSaved);
         g_tradeDragOff = false;
         Dbg("trade level dragging restored");
        }
  }

// Is the point over (or near) any visible box?
bool NearAnyPos(const int x, const int y)
  {
   if(g_hidden)
      return false;
   for(int i = 0; i < ArraySize(g_pos); i++)
     {
      int x1, x2, yE, yS, yT;
      if(!PosXY(g_pos[i], x1, x2, yE, yS, yT))
         continue;
      int top = MathMin(yT, yS), bot = MathMax(yT, yS);
      if(x >= x1 - BLOCK_MARGIN && x <= x2 + BLOCK_MARGIN && y >= top - BLOCK_MARGIN && y <= bot + BLOCK_MARGIN)
         return true;
     }
   return false;
  }

void Hover(const int x, const int y)
  {
   BlockTradeDrag(NearAnyPos(x, y));
   int hit;
   int id = FindHit(x, y, hit);
   if(id == g_hoverId && hit == g_hoverHit)
      return;
   int oldId = g_hoverId;
   g_hoverId  = id;
   g_hoverHit = hit;
   int i = FindPos(oldId);
   if(i >= 0)
      DrawPos(g_pos[i]);
   if(id != oldId)
     {
      i = FindPos(id);
      if(i >= 0)
         DrawPos(g_pos[i]);
     }
   ChartRedraw();
  }

// Is the point over one of the panel buttons?
bool PointInPanel(const int x, const int y)
  {
   int cw = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int ch = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   for(int k = 0; k < g_btnN; k++)
     {
      string n = UIP + g_btnKeys[k];
      if(ObjectFind(0, n) < 0)
         continue;
      int  xd = (int)ObjectGetInteger(0, n, OBJPROP_XDISTANCE);
      int  yd = (int)ObjectGetInteger(0, n, OBJPROP_YDISTANCE);
      long c  = ObjectGetInteger(0, n, OBJPROP_CORNER);
      int left = (c == CORNER_RIGHT_UPPER || c == CORNER_RIGHT_LOWER) ? cw - xd : xd;
      int top  = (c == CORNER_LEFT_LOWER  || c == CORNER_RIGHT_LOWER) ? ch - yd : yd;
      int bw = (int)ObjectGetInteger(0, n, OBJPROP_XSIZE);
      if(x >= left && x < left + bw && y >= top && y < top + BTN_H)
         return true;
     }
   return false;
  }

void StartDrag(const int x, const int y, const bool ctrl = false)
  {
   if(PointInPanel(x, y))
      return;               // button click is handled by OBJECT_CLICK
   if(g_placeDir != 0)
     {
      int sub;
      datetime tc;
      double pc;
      if(ChartXYToTimePrice(0, x, y, sub, tc, pc) && sub == 0)
        {
         int d = g_placeDir;
         g_placeDir = 0;
         UpdatePanel();
         SPos tp;
         if(BoxFromTrade(x, y, tp))
            AddBox(tp);           // clicked on an executed trade -> exact box of that trade
         else
            NewPos(d, tc, pc);
        }
      return;
     }
   int hit;
   int id = FindHit(x, y, hit);
   if(id >= 0)
      BlockTradeDrag(true);   // safety net, normally already blocked by hover
   if(id < 0)
     {
      // click on empty chart -> deactivate (hides badges); Ctrl+click on empty chart keeps the selection
      if(!ctrl && (g_active != -1 || ArraySize(g_sel) > 0))
        {
         SetActive(-1);
         ChartRedraw();
        }
      return;
     }
   if(ctrl)
     {
      SelToggle(id);   // Ctrl+click: select / deselect, never drags
      ChartRedraw();
      return;
     }
   SetActive(id);
   int i = FindPos(id);
   if(i < 0 || g_pos[i].locked)
     {
      ChartRedraw();
      return;
     }
   int sub;
   datetime t;
   double pr;
   if(!ChartXYToTimePrice(0, x, y, sub, t, pr) || sub != 0)
      return;

   g_drag.on        = true;
   g_drag.id        = id;
   g_drag.hit       = hit;
   g_drag.p0        = pr;
   g_drag.tm0       = t;
   g_drag.start     = g_pos[i];
   g_drag.scrollWas = (bool)ChartGetInteger(0, CHART_MOUSE_SCROLL);
   ChartSetInteger(0, CHART_MOUSE_SCROLL, false);   // don't scroll the chart while dragging
   CollectSnapLevels();
   Crosshair(true, DragLevel(g_pos[i], hit), hit == HIT_BODY ? g_pos[i].t1 : SnapTime(t));
   DrawPos(g_pos[i]);
   ChartRedraw();
   Dbg(StringFormat("drag start id=%d hit=%d", id, hit));
  }

//--- drag crosshair (like TradingView): full-width dashed line at the level
//    being set + vertical line at the bar under the mouse. Never deleted while
//    running, only hidden (deleting a panel object would rebuild the panel).
void Crosshair(const bool on, const double price, const datetime t)
  {
   string h = UIP + "XH", v = UIP + "XV";
   if(ObjectFind(0, h) < 0)
      ObjectCreate(0, h, OBJ_HLINE, 0, 0, price);
   if(ObjectFind(0, v) < 0)
      ObjectCreate(0, v, OBJ_VLINE, 0, t, 0);
   if(on)
     {
      ObjectMove(0, h, 0, 0, price);
      ObjectMove(0, v, 0, t, 0);
     }
   string names[] = {h, v};
   for(int k = 0; k < 2; k++)
     {
      ObjectSetInteger(0, names[k], OBJPROP_COLOR, cEntry);
      ObjectSetInteger(0, names[k], OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, names[k], OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, names[k], OBJPROP_BACK, false);
      ObjectSetInteger(0, names[k], OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, names[k], OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, names[k], OBJPROP_ZORDER, 0);
      ObjectSetString(0, names[k], OBJPROP_TOOLTIP, "\n");
      ObjectSetInteger(0, names[k], OBJPROP_TIMEFRAMES, on ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
     }
  }

// Price of the level a drag is setting.
double DragLevel(const SPos &p, const int hit)
  {
   switch(LineOfHit(hit))
     {
      case HIT_TP: return p.tp;
      case HIT_SL: return p.sl;
     }
   return p.entry;
  }

//--- snap to real trade levels -------------------------------------
// Prices of open positions and pending orders on this symbol (entry, SL, TP),
// collected when a drag starts. A dragged level within SNAP_PX pixels jumps onto them.
#define SNAP_PX 8
double g_snapLv[];

void AddSnap(const double v)
  {
   if(v <= 0)
      return;
   int n = ArraySize(g_snapLv);
   ArrayResize(g_snapLv, n + 1);
   g_snapLv[n] = v;
  }

void CollectSnapLevels()
  {
   ArrayResize(g_snapLv, 0);
   if(!InpSnap)
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != _Symbol)
         continue;
      AddSnap(PositionGetDouble(POSITION_PRICE_OPEN));
      AddSnap(PositionGetDouble(POSITION_SL));
      AddSnap(PositionGetDouble(POSITION_TP));
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      AddSnap(OrderGetDouble(ORDER_PRICE_OPEN));
      AddSnap(OrderGetDouble(ORDER_SL));
      AddSnap(OrderGetDouble(ORDER_TP));
     }
  }

// Nearest trade level within SNAP_PX pixels of the price, otherwise the price itself.
double SnapPrice(const double price)
  {
   int n = ArraySize(g_snapLv);
   if(n == 0)
      return price;
   datetime t0 = iTime(_Symbol, _Period, 0);
   int x, y, yl;
   if(!ChartTimePriceToXY(0, 0, t0, price, x, y))
      return price;
   double best = price;
   int bestD = SNAP_PX + 1;
   for(int k = 0; k < n; k++)
     {
      if(!ChartTimePriceToXY(0, 0, t0, g_snapLv[k], x, yl))
         continue;
      int d = MathAbs(yl - y);
      if(d < bestD)
        {
         bestD = d;
         best  = g_snapLv[k];
        }
     }
   return bestD <= SNAP_PX ? NormPrice(best) : price;
  }

// Remember objects we delete ourselves, so their (asynchronous) delete
// events are not mistaken for "user deleted the box".
void SelfDeleteByPrefix(const string prefix)
  {
   int total = ObjectsTotal(0, -1, -1);
   for(int k = total - 1; k >= 0; k--)
     {
      string nm = ObjectName(0, k, -1, -1);
      if(StringFind(nm, prefix) != 0)
         continue;
      int n = ArraySize(g_selfDel);
      ArrayResize(g_selfDel, n + 1);
      g_selfDel[n] = nm;
      ObjectDelete(0, nm);
     }
  }

bool ConsumeSelfDeleted(const string nm)
  {
   for(int k = 0; k < ArraySize(g_selfDel); k++)
      if(g_selfDel[k] == nm)
        {
         int n = ArraySize(g_selfDel);
         g_selfDel[k] = g_selfDel[n - 1];
         ArrayResize(g_selfDel, n - 1);
         return true;
        }
   return false;
  }

// New TP on the wrong side of entry -> flip LONG <-> SHORT (stop mirrored).
// Returns true when the TP was accepted.
bool ApplyTP(SPos &p, const double np)
  {
   if(p.dir > 0 ? np > p.entry : np < p.entry)
     {
      p.tp = np;
      return true;
     }
   if(MathAbs(np - p.entry) < _Point * 0.5)
      return false;
   p.dir = -p.dir;
   p.sl  = NormPrice(2.0 * p.entry - p.sl);
   p.tp  = np;
   return true;
  }

void DoDrag(const int x, const int y)
  {
   int i = FindPos(g_drag.id);
   if(i < 0)
     {
      EndDrag();
      return;
     }
   int sub;
   datetime t;
   double pr;
   if(!ChartXYToTimePrice(0, x, y, sub, t, pr))
      return;

   t = SnapTime(t);
   SPos p = g_pos[i];
   double np = SnapPrice(NormPrice(pr));
   switch(g_drag.hit)
     {
      // left corner handles: level only (height), like TradingView - the time edges
      // are changed by the Entry circle (left edge) and the right middle handle (width)
      case HIT_H_TP:
         ApplyTP(p, np);
         break;
      case HIT_H_SL:
         if(p.dir > 0 ? np < p.entry : np > p.entry)
            p.sl = np;
         break;
      // left middle (Entry circle): entry price and the left edge
      case HIT_H_E:
         if(p.dir > 0 ? (np > p.sl && np < p.tp) : (np < p.sl && np > p.tp))
            p.entry = np;
         if(t < p.t2)
            p.t1 = t;
         break;
      // right middle handle: width only
      case HIT_H_R:
         if(t > p.t1)
            p.t2 = t;
         break;
      case HIT_BODY:
        {
         p = g_drag.start;
         double d  = pr - g_drag.p0;
         d = SnapPrice(NormPrice(p.entry + d)) - p.entry;   // whole box: entry snaps
         p.entry = NormPrice(p.entry + d);
         p.sl    = NormPrice(p.sl + d);
         p.tp    = NormPrice(p.tp + d);
         // move by whole bars, so the width in bars never changes
         // (time gaps - weekends, session breaks - would change it otherwise)
         int dBars = BarIndex(SnapTime(g_drag.tm0)) - BarIndex(t);
         int i1 = BarIndex(g_drag.start.t1) - dBars;
         int i2 = BarIndex(g_drag.start.t2) - dBars;
         p.t1 = TimeAtIndex(i1);
         p.t2 = TimeAtIndex(i2);
         if(p.t2 <= p.t1)
            p.t2 = (datetime)((long)p.t1 + PeriodSeconds());
         break;
        }
      default:
         return;
     }
   // Linked box edited -> no longer the real trade, becomes a simulated box. Compared with
   // the state at drag start (a body move restarts from g_drag.start every step, which still
   // has the ticket - comparing with the previous step would re-link it). Moving the box in
   // time unlinks it too; changing only the width keeps the link.
   const SPos s0 = g_drag.start;
   if(s0.ticket > 0 &&
      (!IsNone(p.entry, s0.entry) || !IsNone(p.sl, s0.sl) || !IsNone(p.tp, s0.tp) || p.dir != s0.dir ||
       (g_drag.hit == HIT_BODY && p.t1 != s0.t1)))
     {
      if(p.ticket > 0)
         Dbg(StringFormat("id=%d unlinked from position (box edited)", p.id));
      p.ticket = 0;
     }
   if(p.dir != g_pos[i].dir)
     {
      // direction is part of the object names -> replace the objects
      FreeBadges(PosPrefix(p.id));
      SelfDeleteByPrefix(PosPrefix(p.id));
      Dbg(StringFormat("id=%d flipped to %s", p.id, p.dir > 0 ? "LONG" : "SHORT"));
     }
   g_pos[i] = p;
   // the vertical crosshair line follows the time actually set: corner handles (level only)
   // and the body keep it on the left edge, Entry / width handles follow the mouse
   bool atLeft = (g_drag.hit == HIT_BODY || g_drag.hit == HIT_H_TP || g_drag.hit == HIT_H_SL);
   Crosshair(true, DragLevel(p, g_drag.hit), atLeft ? p.t1 : t);
   DrawPos(p);
   ChartRedraw();
  }

void EndDrag()
  {
   if(!g_drag.on)
      return;
   g_drag.on = false;
   ChartSetInteger(0, CHART_MOUSE_SCROLL, g_drag.scrollWas);
   Crosshair(false, 0, 0);
   int i = FindPos(g_drag.id);
   if(i >= 0)
     {
      DrawPos(g_pos[i]);
      DbgPos(StringFormat("drag end hit=%d", g_drag.hit), g_pos[i]);
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Rebuild state from chart objects                                 |
//+------------------------------------------------------------------+
void LoadFromChart()
  {
   ArrayResize(g_pos, 0);
   g_nextId = 1;
   bool anyHidden = false;
   int  foreign[];   // ids of boxes that belong to another symbol (kept, hidden)

   int total = ObjectsTotal(0, 0, -1);
   for(int k = 0; k < total; k++)
     {
      string nm = ObjectName(0, k, 0, -1);
      int id, dir;
      string part;
      if(!ParseName(nm, id, dir, part) || part != "E")
         continue;
      if(FindPos(id) >= 0)
         continue;

      SPos p;
      ZeroMemory(p);
      p.id  = id;
      p.dir = dir;
      string nSL = ObjName(p, "SL"), nTP = ObjName(p, "TP");
      if(ObjectFind(0, nSL) < 0 || ObjectFind(0, nTP) < 0)
         continue;

      // symbol ownership (boxes from older versions have no tag -> this symbol)
      string nSY = ObjName(p, "SY");
      string sym = ObjectFind(0, nSY) >= 0 ? ObjectGetString(0, nSY, OBJPROP_TEXT) : "";
      int    fl  = StringLen(sym) - StringLen(SYM_FOREIGN_VIS);
      string flag = fl > 0 ? StringSubstr(sym, fl) : "";
      bool   hiddenBySym = flag == SYM_FOREIGN_VIS || flag == SYM_FOREIGN_HID;
      bool   userHidden  = hiddenBySym ? flag == SYM_FOREIGN_HID
                                       : ObjectGetInteger(0, nm, OBJPROP_TIMEFRAMES) == OBJ_NO_PERIODS;
      if(hiddenBySym)
         sym = StringSubstr(sym, 0, fl);
      if(sym != "" && sym != _Symbol)
        {
         int f = ArraySize(foreign);
         ArrayResize(foreign, f + 1);
         foreign[f] = id;
         if(!hiddenBySym)
            ObjectSetString(0, nSY, OBJPROP_TEXT, sym + (userHidden ? SYM_FOREIGN_HID : SYM_FOREIGN_VIS));
         if(id >= g_nextId)
            g_nextId = id + 1;   // ids stay unique across symbols (object names)
         continue;
        }

      p.entry  = ObjectGetDouble(0, nm, OBJPROP_PRICE, 0);
      p.t1     = (datetime)ObjectGetInteger(0, nm, OBJPROP_TIME, 0);
      p.t2     = (datetime)ObjectGetInteger(0, nm, OBJPROP_TIME, 1);
      p.sl     = ObjectGetDouble(0, nSL, OBJPROP_PRICE, 0);
      p.tp     = ObjectGetDouble(0, nTP, OBJPROP_PRICE, 0);
      p.locked = ObjectGetInteger(0, nm, OBJPROP_STYLE) == STYLE_DOT;
      string nTK = ObjName(p, "TK");
      if(ObjectFind(0, nTK) >= 0)
         p.ticket = StringToInteger(ObjectGetString(0, nTK, OBJPROP_TEXT));
      p.t1     = SnapTime(p.t1);   // fix boxes saved with off-bar times
      p.t2     = SnapTime(p.t2);
      if(p.t2 < p.t1)
        {
         datetime t = p.t1;
         p.t1 = p.t2;
         p.t2 = t;
        }
      // hidden by the user (Hide button), not by a symbol change
      if(userHidden)
         anyHidden = true;
      if(p.ticket > 0)
        {
         SReal r;
         if(LoadReal(p.ticket, r) && r.dir == p.dir)
            ApplyRealLevels(p, r);   // linked box: levels always from the account history
        }

      int n = ArraySize(g_pos);
      ArrayResize(g_pos, n + 1);
      g_pos[n] = p;
      if(id >= g_nextId)
         g_nextId = id + 1;
     }
   g_hidden = anyHidden;

   // remove orphans and objects from older versions; hide boxes of other symbols
   string junk[];
   total = ObjectsTotal(0, 0, -1);
   for(int k = 0; k < total; k++)
     {
      string nm = ObjectName(0, k, 0, -1);
      int id, dir;
      string part;
      if(!ParseName(nm, id, dir, part))
         continue;
      if(IsIn(foreign, id))
        {
         if(!KnownPart(part))
           {
            int n = ArraySize(junk);
            ArrayResize(junk, n + 1);
            junk[n] = nm;
           }
         else
            if(ObjectGetInteger(0, nm, OBJPROP_TIMEFRAMES) != OBJ_NO_PERIODS)
               ObjectSetInteger(0, nm, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
         continue;
        }
      if(FindPos(id) < 0 || !KnownPart(part))
        {
         int n = ArraySize(junk);
         ArrayResize(junk, n + 1);
         junk[n] = nm;
        }
     }
   for(int k = 0; k < ArraySize(junk); k++)
      ObjectDelete(0, junk[k]);

   int n = ArraySize(g_pos);
   g_active = -1;   // nothing active after load -> badges hidden until hover/click
   ArrayResize(g_sel, 0);
   Dbg(StringFormat("loaded %d position(s) from chart, %d of other symbols hidden, removed %d stale object(s), hidden=%d",
                    n, ArraySize(foreign), ArraySize(junk), g_hidden));
  }


//+------------------------------------------------------------------+
//| Backup / Restore                                                 |
//+------------------------------------------------------------------+
// Backup (input InpAutoBackup): after every change the boxes of this chart are written to
// PositionPlanner\backup\<account>_<symbol>_<TF>.json (levels, times, lock, linked position).
// The file is written to a .tmp first, read back and checked, and only then replaces the
// backup - a crash while writing never destroys the last good backup.
// Before the first write of an indicator instance, a backup holding boxes that are not on this
// chart (e.g. a chart lost in a crash) is kept as ..._prev_<time>.json (the newest PREV_KEEP).
// Restore: the newest complete backup / previous backup / full export (not "locked only",
// not single box) of this symbol + timeframe that has boxes not on the chart yet.
#define PREV_KEEP 5

string TfName() { return StringSubstr(EnumToString(_Period), 7); }   // PERIOD_M5 -> M5
string BakName() { return IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + SafeFileName(_Symbol) + "_" + TfName(); }
string BakDir()  { return "PositionPlanner\\backup\\"; }
string BakBase() { return BakDir() + BakName(); }

string BoxesSig()
  {
   string r = "";
   for(int i = 0; i < ArraySize(g_pos); i++)
     {
      SPos p = g_pos[i];
      r += StringFormat("%d|%d|%s|%s|%s|%I64d|%I64d|%d|%I64d;", p.id, p.dir,
                        DoubleToString(p.entry, _Digits), DoubleToString(p.sl, _Digits), DoubleToString(p.tp, _Digits),
                        (long)p.t1, (long)p.t2, p.locked, p.ticket);
     }
   return r;
  }

bool SameBoxLv(const SPos &a, const SPos &b)
  {
   if(a.ticket > 0 || b.ticket > 0)
      return a.ticket == b.ticket;
   return a.dir == b.dir && a.t1 == b.t1 && a.t2 == b.t2 &&
          MathAbs(a.entry - b.entry) < _Point * 0.5 && MathAbs(a.sl - b.sl) < _Point * 0.5 &&
          MathAbs(a.tp - b.tp) < _Point * 0.5;
  }

bool OnChartAlready(const SPos &b)
  {
   for(int i = 0; i < ArraySize(g_pos); i++)
      if(SameBoxLv(g_pos[i], b))
         return true;
   return false;
  }

// "2026-10-08T23:30:00" -> datetime (0 = invalid)
datetime JParseTime(string v)
  {
   if(StringLen(v) < 19)
      return 0;
   StringReplace(v, "-", ".");
   StringReplace(v, "T", " ");
   return StringToTime(v);
  }

// Reads the boxes of a PositionPlanner export / backup file (our own one-key-per-line format;
// boxes are the objects at depth 3 of "boxes"). The whole file is rejected when it is not
// complete (truncated), not for this symbol, or any box is incomplete / invalid.
// lockedOnly = export of locked boxes only. Linked boxes of another account lose the link.
bool ReadBoxesFile(const string file, SPos &out[], string &err, bool &lockedOnly)
  {
   ArrayResize(out, 0);
   lockedOnly = false;
   int h = FileOpen(file, FILE_READ | FILE_TXT | FILE_ANSI, 0, CP_UTF8);
   if(h == INVALID_HANDLE)
     {
      err = "cannot open (error " + IntegerToString(GetLastError()) + ")";
      return false;
     }
   int depth = 0;
   bool started = false, ended = false, inBoxes = false, boxesDone = false, inBox = false, symOk = false, bad = false;
   long acc = -1;
   string srv = "";
   SPos b;
   ZeroMemory(b);
   bool hasStop = false, hasTarget = false;
   int  got = 0;                 // required box fields seen (bit mask)
   while(!FileIsEnding(h))
     {
      string ln = FileReadString(h);
      StringTrimLeft(ln);
      StringTrimRight(ln);
      if(ln == "")
         continue;
      if(ended)
        {
         bad = true;             // content after the end of the document
         break;
        }
      string key = "", val = "";
      if(StringGetCharacter(ln, 0) == '"')
        {
         int q = StringFind(ln, "\"", 1);
         int c = q > 0 ? StringFind(ln, ":", q) : -1;
         if(c > 0)
           {
            key = StringSubstr(ln, 1, q - 1);
            val = StringSubstr(ln, c + 1);
            StringTrimLeft(val);
            StringTrimRight(val);
            if(StringLen(val) > 0 && StringGetCharacter(val, StringLen(val) - 1) == ',')
               val = StringSubstr(val, 0, StringLen(val) - 1);
            if(StringLen(val) >= 2 && StringGetCharacter(val, 0) == '"')
               val = StringSubstr(val, 1, StringLen(val) - 2);
           }
        }
      if(depth == 1 && key == "symbol")
        {
         if(val != _Symbol)
           {
            FileClose(h);
            err = "file is for " + val;
            return false;
           }
         symOk = true;
        }
      if(depth == 1 && key == "account")
         acc = StringToInteger(val);
      if(depth == 1 && key == "server")
         srv = val;
      if(depth == 1 && key == "locked_only")
         lockedOnly = (val == "true");
      if(depth == 1 && key == "boxes")
         inBoxes = true;
      if(inBoxes && depth == 2 && (ln == "{" || ln == "{,"))
        {
         inBox = true;
         ZeroMemory(b);
         hasStop = hasTarget = false;
         got = 0;
        }
      if(inBox && depth == 3 && key != "")
        {
         if(key == "position_id")
           {
            b.ticket = (val == "null") ? 0 : StringToInteger(val);
            got |= 1;
           }
         else if(key == "direction")
           {
            b.dir = (val == "long") ? 1 : (val == "short" ? -1 : 0);
            got |= 2;
           }
         else if(key == "locked")
            b.locked = (val == "true");
         else if(key == "entry")
           {
            b.entry = NormPrice(StringToDouble(val));
            got |= 4;
           }
         else if(key == "stop")
           {
            if(val != "null")
              {
               b.sl = NormPrice(StringToDouble(val));
               hasStop = true;
              }
            got |= 8;
           }
         else if(key == "target")
           {
            if(val != "null")
              {
               b.tp = NormPrice(StringToDouble(val));
               hasTarget = true;
              }
            got |= 16;
           }
         else if(key == "time_start")
           {
            b.t1 = JParseTime(val);
            got |= 32;
           }
         else if(key == "time_end")
           {
            b.t2 = JParseTime(val);
            got |= 64;
           }
        }
      // depth after this line (our strings never contain braces; brackets in symbols come in pairs)
      for(int k = 0; k < StringLen(ln); k++)
        {
         ushort ch = StringGetCharacter(ln, k);
         if(ch == '{' || ch == '[')
           {
            depth++;
            started = true;
           }
         else if(ch == '}' || ch == ']')
            depth--;
        }
      if(depth < 0)
        {
         bad = true;
         break;
        }
      if(inBox && depth == 2)
        {
         inBox = false;
         if(!hasStop)
            b.sl = b.entry;     // "none" level = entry
         if(!hasTarget)
            b.tp = b.entry;
         // a linked box takes the real SL / TP, which may be past the entry (trailing / break-even)
         bool lk = b.ticket > 0;
         bool ok = got == 127 && (b.dir == 1 || b.dir == -1) && b.entry > 0 && b.t1 > 0 && b.t2 > b.t1 && b.ticket >= 0 &&
                   (!hasStop || (b.sl > 0 && (lk || (b.dir > 0 ? b.sl < b.entry : b.sl > b.entry)))) &&
                   (!hasTarget || (b.tp > 0 && (lk || (b.dir > 0 ? b.tp > b.entry : b.tp < b.entry))));
         if(!ok)
           {
            bad = true;
            break;
           }
         int n = ArraySize(out);
         ArrayResize(out, n + 1);
         out[n] = b;
        }
      if(inBoxes && depth <= 1)
        {
         inBoxes = false;
         boxesDone = true;
        }
      if(started && depth == 0)
         ended = true;
     }
   FileClose(h);
   if(bad || !ended || !boxesDone)
     {
      ArrayResize(out, 0);
      err = "file is incomplete or damaged";
      return false;
     }
   if(!symOk)
     {
      ArrayResize(out, 0);
      err = "not a PositionPlanner file";
      return false;
     }
   // position ids of another account / server mean nothing here -> normal boxes. Older files
   // without the account are taken as this account's (they were written by this terminal).
   if((acc >= 0 && acc != AccountInfoInteger(ACCOUNT_LOGIN)) || (srv != "" && srv != AccountInfoString(ACCOUNT_SERVER)))
     {
      int w = 0;
      for(int k = 0; k < ArraySize(out); k++)
        {
         SPos x = out[k];
         if(x.ticket > 0)
           {
            x.ticket = 0;
            // a real trailing / break-even level past the entry is not valid for a normal box
            if((!IsNone(x.sl, x.entry) && (x.dir > 0 ? x.sl >= x.entry : x.sl <= x.entry)) ||
               (!IsNone(x.tp, x.entry) && (x.dir > 0 ? x.tp <= x.entry : x.tp >= x.entry)))
              {
               Print("PositionPlanner: restore skips a box of another account (its real stop / target is past the entry)");
               continue;
              }
           }
         out[w++] = x;
        }
      ArrayResize(out, w);
     }
   return true;
  }

int CountNew(const SPos &bx[])
  {
   int c = 0;
   for(int k = 0; k < ArraySize(bx); k++)
      if(!OnChartAlready(bx[k]))
         c++;
   return c;
  }

void AddCand(string &cand[], datetime &when[], const string f)
  {
   int n = ArraySize(cand);
   ArrayResize(cand, n + 1);
   ArrayResize(when, n + 1);
   cand[n] = f;
   when[n] = (datetime)FileGetInteger(f, FILE_MODIFY_DATE);
  }

// files folder\pattern -> names (without the folder)
void ListFiles(const string folder, const string pattern, string &names[])
  {
   ArrayResize(names, 0);
   string fn;
   long fh = FileFindFirst(folder + pattern, fn);
   if(fh == INVALID_HANDLE)
      return;
   do
     {
      int n = ArraySize(names);
      ArrayResize(names, n + 1);
      names[n] = fn;
     }
   while(FileFindNext(fh, fn));
   FileFindClose(fh);
  }

// Newest complete backup / export of this symbol + timeframe with boxes not on the chart.
string FindRestoreFile(int &total, int &fresh)
  {
   string cand[];
   datetime when[];
   string names[];
   if(FileIsExist(BakBase() + ".json"))
      AddCand(cand, when, BakBase() + ".json");
   ListFiles(BakDir(), BakName() + "_prev_*.json", names);
   for(int k = 0; k < ArraySize(names); k++)
      AddCand(cand, when, BakDir() + names[k]);
   ListFiles("PositionPlanner\\", SafeFileName(_Symbol) + "_" + TfName() + "_*.json", names);
   for(int k = 0; k < ArraySize(names); k++)
      if(StringFind(names[k], "_box") < 0)          // single-box exports are not a chart state
         AddCand(cand, when, "PositionPlanner\\" + names[k]);
   int n = ArraySize(cand);
   for(int i = 1; i < n; i++)                         // newest first
     {
      string c = cand[i];
      datetime w = when[i];
      int j = i - 1;
      while(j >= 0 && when[j] < w)
        {
         cand[j + 1] = cand[j];
         when[j + 1] = when[j];
         j--;
        }
      cand[j + 1] = c;
      when[j + 1] = w;
     }
   for(int i = 0; i < n; i++)
     {
      SPos bx[];
      string err;
      bool lockedOnly;
      if(!ReadBoxesFile(cand[i], bx, err, lockedOnly))
        {
         Print("PositionPlanner: restore skips ", cand[i], " - ", err);
         continue;
        }
      if(lockedOnly)
         continue;                                    // only part of the chart
      int c = CountNew(bx);
      if(c > 0)
        {
         total = ArraySize(bx);
         fresh = c;
         return cand[i];
        }
     }
   return "";
  }

void RestoreClick()
  {
   if(g_restArmed != 0 && (GetTickCount() - g_restArmed) < RESTORE_ARM_MS && g_restFile != "")
     {
      g_restArmed = 0;
      SPos bx[];
      string err;
      bool lockedOnly;
      if(!ReadBoxesFile(g_restFile, bx, err, lockedOnly))
        {
         Alert("PositionPlanner: restore failed - ", g_restFile, ": ", err);
         g_restFile = "";
         return;
        }
      SetHidden(false);
      int added = 0;
      for(int k = 0; k < ArraySize(bx); k++)
        {
         SPos p = bx[k];
         if(OnChartAlready(p))
            continue;
         p.id = g_nextId++;      // new id: old ids may belong to other boxes now
         int n = ArraySize(g_pos);
         ArrayResize(g_pos, n + 1);
         g_pos[n] = p;
         DrawPos(p);
         added++;
        }
      Print("PositionPlanner: restored ", added, " box(es) from ", g_restFile);
      g_restFile = "";
      UpdatePanel();
      ChartRedraw();
      return;
     }
   int total = 0, fresh = 0;
   g_restFile = FindRestoreFile(total, fresh);
   if(g_restFile == "")
     {
      g_restArmed = 0;
      Alert("PositionPlanner: nothing to restore for ", _Symbol, " ", TfName(),
            " - no backup / export with boxes that are not on the chart yet");
      return;
     }
   g_restArmed = GetTickCount();
   g_restTotal = total;
   g_restFresh = fresh;
   Print(StringFormat("PositionPlanner: Restore armed - %d of %d box(es) from %s", fresh, total, g_restFile));
  }

bool WStr(const int h, const string v, bool &ok)
  {
   if(ok && FileWriteString(h, v) <= 0)
      ok = false;
   return ok;
  }

// Writes the backup to a .tmp, reads it back, then replaces the backup file.
bool WriteBackup(const string file)
  {
   string tmp = BakBase() + ".tmp";
   int h = FileOpen(tmp, FILE_WRITE | FILE_TXT | FILE_ANSI, 0, CP_UTF8);
   if(h == INVALID_HANDLE)
      return false;
   bool ok = true;
   WStr(h, "{\n", ok);
   WStr(h, "  \"schema_version\": 1,\n", ok);
   WStr(h, "  \"tool\": \"PositionPlanner\",\n", ok);
   WStr(h, "  \"kind\": \"backup\",\n", ok);
   WStr(h, "  \"saved_local\": " + JTime(TimeLocal()) + ",\n", ok);
   WStr(h, "  \"times_are\": \"broker server time\",\n", ok);
   WStr(h, "  \"symbol\": " + JStr(_Symbol) + ",\n", ok);
   WStr(h, "  \"account\": " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ",\n", ok);
   WStr(h, "  \"server\": " + JStr(AccountInfoString(ACCOUNT_SERVER)) + ",\n", ok);
   WStr(h, "  \"timeframe\": " + JStr(TfName()) + ",\n", ok);
   WStr(h, "  \"boxes\": [", ok);
   int ids[];
   SortedIds(ids);
   int cnt = 0;
   for(int k = 0; k < ArraySize(ids); k++)
     {
      int i = FindPos(ids[k]);
      if(i < 0)
         continue;
      SPos p = g_pos[i];
      string b = (cnt > 0 ? "," : "") + "\n    {\n";
      b += "      \"id\": " + IntegerToString(p.id) + ",\n";
      b += "      \"source\": " + JStr(p.ticket > 0 ? "trade" : "manual") + ",\n";
      b += "      \"position_id\": " + (p.ticket > 0 ? IntegerToString(p.ticket) : "null") + ",\n";
      b += "      \"direction\": " + JStr(p.dir > 0 ? "long" : "short") + ",\n";
      b += "      \"locked\": " + (p.locked ? "true" : "false") + ",\n";
      b += "      \"entry\": " + JNum(p.entry, _Digits) + ",\n";
      b += "      \"stop\": " + (IsNone(p.sl, p.entry) ? "null" : JNum(p.sl, _Digits)) + ",\n";
      b += "      \"target\": " + (IsNone(p.tp, p.entry) ? "null" : JNum(p.tp, _Digits)) + ",\n";
      b += "      \"time_start\": " + JTime(p.t1) + ",\n";
      b += "      \"time_end\": " + JTime(p.t2) + "\n";
      b += "    }";
      WStr(h, b, ok);
      cnt++;
     }
   WStr(h, (cnt > 0 ? "\n  " : "") + "]\n}\n", ok);
   FileFlush(h);
   FileClose(h);
   // read back: complete and the same number of boxes
   SPos chk[];
   string err;
   bool lo;
   if(!ok || !ReadBoxesFile(tmp, chk, err, lo) || ArraySize(chk) != cnt)
     {
      FileDelete(tmp);
      return false;
     }
   return FileMove(tmp, 0, file, FILE_REWRITE);
  }

// Keep the newest PREV_KEEP previous backups, delete older ones.
void PrunePrev()
  {
   string names[];
   ListFiles(BakDir(), BakName() + "_prev_*.json", names);
   int n = ArraySize(names);
   if(n <= PREV_KEEP)
      return;
   ArraySort(names);            // ..._prev_YYYYMMDD_HHMMSS.json -> oldest first
   for(int k = 0; k < n - PREV_KEEP; k++)
      FileDelete(BakDir() + names[k]);
  }

// Every saved field equal (direction, levels, times, lock, link)?
bool SameBoxFull(const SPos &a, const SPos &b)
  {
   return a.dir == b.dir && a.t1 == b.t1 && a.t2 == b.t2 && a.locked == b.locked && a.ticket == b.ticket &&
          MathAbs(a.entry - b.entry) < _Point * 0.5 && MathAbs(a.sl - b.sl) < _Point * 0.5 &&
          MathAbs(a.tp - b.tp) < _Point * 0.5;
  }

// Same boxes (all saved fields) in both sets?
bool SameBoxSet(const SPos &a[], const SPos &b[])
  {
   if(ArraySize(a) != ArraySize(b))
      return false;
   for(int i = 0; i < ArraySize(a); i++)
     {
      bool f = false;
      for(int j = 0; j < ArraySize(b) && !f; j++)
         f = SameBoxFull(a[i], b[j]);
      if(!f)
         return false;
     }
   return true;
  }

// The newest kept previous backup already holds exactly these boxes?
bool SameAsNewestPrev(const SPos &bx[])
  {
   string names[];
   ListFiles(BakDir(), BakName() + "_prev_*.json", names);
   if(ArraySize(names) == 0)
      return false;
   ArraySort(names);
   SPos last[];
   string err;
   bool lo;
   return ReadBoxesFile(BakDir() + names[ArraySize(names) - 1], last, err, lo) && SameBoxSet(bx, last);
  }

// ..._prev_YYYYMMDD_HHMMSS[_n].json that does not exist yet (never overwrites a kept backup)
string NewPrevName()
  {
   string stamp = TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS);
   StringReplace(stamp, ".", "");
   StringReplace(stamp, ":", "");
   StringReplace(stamp, " ", "_");
   for(int k = 0; k < 100; k++)
     {
      string f = BakBase() + "_prev_" + stamp + (k > 0 ? StringFormat("_%02d", k) : "") + ".json";
      if(!FileIsExist(f))
         return f;
     }
   return "";
  }

void MaybeBackup()
  {
   string sig = BoxesSig();
   if(sig == g_bakSig)
      return;                    // saved already
   if(g_bakRetry != 0 && GetTickCount() - g_bakRetry < 5000)
      return;                    // last attempt failed - wait a moment, then try again
   string file = BakBase() + ".json";
   if(g_bakFirst && FileIsExist(file))
     {
      // once per indicator instance: keep an older backup whose boxes are not on this chart
      SPos old[];
      string err;
      bool lo;
      if(ReadBoxesFile(file, old, err, lo) && CountNew(old) > 0 && !SameAsNewestPrev(old))
        {
         string gen = NewPrevName();
         if(gen == "" || !FileCopy(file, 0, gen, 0))
           {
            Print("PositionPlanner: backup not written - could not keep the previous backup, error ", GetLastError());
            g_bakRetry = GetTickCount() | 1;
            return;              // the old backup stays untouched
           }
        }
     }
   g_bakFirst = false;
   if(WriteBackup(file))
     {
      g_bakSig   = sig;
      g_bakRetry = 0;
      PrunePrev();
      Dbg("backup -> " + file);
     }
   else
     {
      g_bakRetry = GetTickCount() | 1;   // the old backup stays; try again in 5 s
      Print("PositionPlanner: backup failed, error ", GetLastError());
     }
  }

//+------------------------------------------------------------------+
//| Event handlers                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   IndicatorSetString(INDICATOR_SHORTNAME, PP_VERSION);
   if(InpRiskValue <= 0)
      Print("PositionPlanner: risk value must be > 0");

   ZeroMemory(g_drag);
   g_inst = IntegerToString((long)(GetMicrosecondCount() % 1000000000));

   ResolveColors();
   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   LoadFromChart();
   if(!InpShowExport)
     {
      DropButton("EXPORT");
      DropButton("RESTORE");
     }
   g_bakSig   = BoxesSig();   // the boxes as loaded are not a change -> no backup yet
   g_bakFirst = true;
   CreatePanel();
   DrawAll();
   ChartRedraw();

   if(InpDebug)
     {
      Print(StringFormat("[PP] init %s %s digits=%d point=%s pip=%s tickSize=%s tickValue=%s volMin=%s volStep=%s volMax=%s currency=%s balance=%.2f bg=%s",
                         _Symbol, EnumToString(_Period), _Digits,
                         DoubleToString(_Point, _Digits), DoubleToString(PipSize(), _Digits),
                         DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), _Digits),
                         DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), 5),
                         DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), 2),
                         DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), 2),
                         DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), 2),
                         AccountInfoString(ACCOUNT_CURRENCY), AccountInfoDouble(ACCOUNT_BALANCE),
                         ColorToString(g_bg)));

      for(int i = 0; i < ArraySize(g_pos); i++)
         DbgPos("loaded", g_pos[i]);
     }
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_drag.on)
      ChartSetInteger(0, CHART_MOUSE_SCROLL, g_drag.scrollWas);
   CloseMenu();             // also gives mouse scrolling back
   BlockTradeDrag(false);   // always give trade-level dragging + MT5 context menu back
   // Only a real removal cleans the chart. On input change / recompile / TF change
   // the new instance is already running and reuses these objects.
   if(reason == REASON_REMOVE)
     {
      ObjectsDeleteAll(0, UIP);
      ObjectsDeleteAll(0, PFX);
     }
   FreeBadges("");          // own (instance-suffixed) bitmap resources only
   ResourceFree(HandleRes(false));
   ResourceFree(HandleRes(true));
   ChartRedraw();
  }

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
   // the visible (active / hovered) box follows every tick, like MT5's P&L
   if(!g_drag.on)
     {
      bool upd = false;
      int ia = FindPos(g_active), ih = FindPos(g_hoverId);
      if(ia >= 0)
        {
         UpdateBadges(g_pos[ia]);
         PublishActive();   // same tick as the badge -> the script never reads an older lot size
         upd = true;
        }
      if(ih >= 0 && ih != ia)
        {
         UpdateBadges(g_pos[ih]);
         upd = true;
        }
      for(int k = 0; k < ArraySize(g_sel); k++)   // Ctrl+selected boxes show their labels too
        {
         int is = FindPos(g_sel[k]);
         if(is >= 0 && is != ia && is != ih)
           {
            UpdateBadges(g_pos[is]);
            upd = true;
           }
        }
      if(upd)
         ChartRedraw();
     }

   // refresh texts (balance / tick value may change) at most every 2 s
   uint now = GetTickCount();
   if(!g_drag.on && now - g_lastRefresh >= 2000)
     {
      g_lastRefresh = now;
      // M1 history was not ready on an earlier pass -> finished boxes may change now
      bool again = g_m1Pending;
      g_m1Pending = false;
      datetime t0 = iTime(_Symbol, _Period, 0);
      for(int i = 0; i < ArraySize(g_pos); i++)
        {
         if(g_pos[i].ticket > 0)
           {
            SReal r;
            if(GetReal(g_pos[i].ticket, r) && r.open && g_pos[i].t2 < (datetime)((long)t0 + PeriodSeconds()))
              {
               g_pos[i].t2 = (datetime)((long)t0 + 5 * PeriodSeconds());   // open trade keeps growing
               DrawPos(g_pos[i]);
               continue;
              }
            if(r.ok && !r.open && g_pos[i].t2 < t0)
               continue;            // closed real trade - final
           }
         if(g_pos[i].t2 < t0 && g_pos[i].ticket <= 0 && !again)
            continue;               // finished box - nothing can change (unless M1 history arrived)
         STrade tr;
         SimTrade(g_pos[i], tr);
         DrawTrade(g_pos[i], tr);   // price moved -> update trade area
        }
      UpdateAllBadges();
      UpdatePanel();
      ChartRedraw();
     }
   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Right-click menu of a box (MT5's own menu is off over a box)     |
//+------------------------------------------------------------------+
#define MENU_ROW_H  24
int    g_menuId   = -1;          // box the open menu belongs to, -1 = closed
int    g_menuX    = 0, g_menuY = 0, g_menuW = 0, g_menuH = 0;
int    g_menuHot  = -1;          // hovered row
bool   g_menuScrollWas = true;
string g_menuKeys[];
string g_menuText[];
string g_menuShort[];   // shortcut shown on the right

string MenuObj() { return UIP + "MENU"; }
string MenuRes() { return "::PPMENU_" + g_inst; }

// Box whose rectangle (incl. the margin where MT5's own menu is off) contains the point - active box first.
int BoxAt(const int x, const int y)
  {
   if(g_hidden)
      return -1;
   int best = -1;
   for(int i = 0; i < ArraySize(g_pos); i++)
     {
      int x1, x2, yE, yS, yT;
      if(!PosXY(g_pos[i], x1, x2, yE, yS, yT))
         continue;
      int top = MathMin(yT, yS), bot = MathMax(yT, yS);
      if(x < x1 - BLOCK_MARGIN || x > x2 + BLOCK_MARGIN || y < top - BLOCK_MARGIN || y > bot + BLOCK_MARGIN)
         continue;
      if(g_pos[i].id == g_active)
         return g_active;
      best = g_pos[i].id;   // newest wins (drawn on top)
     }
   return best;
  }

void MenuAdd(const string key, const string text, const string shortcut = "")
  {
   int n = ArraySize(g_menuKeys);
   ArrayResize(g_menuKeys, n + 1);
   ArrayResize(g_menuText, n + 1);
   ArrayResize(g_menuShort, n + 1);
   g_menuKeys[n]  = key;
   g_menuText[n]  = text;
   g_menuShort[n] = shortcut;
  }

// Item layout (separators are thinner); fills top y of each item, returns total height.
#define MENU_SEP_H  9
#define MENU_ICON_W 30
#define MENU_SHADOW 3
int MenuLayout(int &tops[])
  {
   int n = ArraySize(g_menuKeys);
   ArrayResize(tops, n);
   int y = 3;
   for(int i = 0; i < n; i++)
     {
      tops[i] = y;
      y += (g_menuKeys[i] == "SEP") ? MENU_SEP_H : MENU_ROW_H;
     }
   return y + 3;
  }

// Classic MT5 / Windows menu look: light grey, square, thin grey border, small shadow,
// icon column on the left, shortcut on the right, light blue hovered row.
void DrawMenu()
  {
   int n = ArraySize(g_menuKeys);
   const color bg = C'240,240,240', bd = C'160,160,160', sep = C'200,200,200';
   const color hotBg = C'204,232,255', hotBd = C'153,209,255', fg = C'0,0,0', fgKey = C'90,90,90';

   TextSetFont(FONT, -90, FW_NORMAL);
   uint tw = 0, th = 0;
   int maxw = 0, maxk = 0;
   for(int i = 0; i < n; i++)
     {
      TextGetSize(g_menuText[i], tw, th);
      maxw = MathMax(maxw, (int)tw);
      TextGetSize(g_menuShort[i], tw, th);
      maxk = MathMax(maxk, (int)tw);
     }
   int tops[];
   int mh = MenuLayout(tops);
   int mw = MathMax(150, MENU_ICON_W + 8 + maxw + (maxk > 0 ? 40 + maxk : 0) + 20);
   int w = mw + MENU_SHADOW, h = mh + MENU_SHADOW;
   uint data[];
   ArrayResize(data, w * h);
   ArrayInitialize(data, 0);
   // soft shadow (right + bottom)
   for(int y = MENU_SHADOW; y < h; y++)
      for(int x = MENU_SHADOW; x < w; x++)
        {
         int dx = MathMax(0, x - (mw - 1)), dy = MathMax(0, y - (mh - 1));
         int dd = MathMax(dx, dy);
         if(dd > 0)
            data[y * w + x] = ARGB(clrBlack, 0.30 * (MENU_SHADOW + 1 - dd) / (MENU_SHADOW + 1));
        }
   for(int y = 0; y < mh; y++)
      for(int x = 0; x < mw; x++)
         data[y * w + x] = ARGB((x == 0 || y == 0 || x == mw - 1 || y == mh - 1) ? bd : bg, 1.0);
   for(int i = 0; i < n; i++)
     {
      int ty = tops[i];
      if(g_menuKeys[i] == "SEP")
        {
         for(int x = MENU_ICON_W; x < mw - 3; x++)
            data[(ty + MENU_SEP_H / 2) * w + x] = ARGB(sep, 1.0);
         continue;
        }
      if(i == g_menuHot)
         for(int y = ty; y < ty + MENU_ROW_H; y++)
            for(int x = 3; x < mw - 3; x++)
               data[y * w + x] = ARGB((y == ty || y == ty + MENU_ROW_H - 1 || x == 3 || x == mw - 4) ? hotBd : hotBg, 1.0);
      int cy = ty + MENU_ROW_H / 2;
      bool off = g_menuKeys[i] == "DELOFF";
      TextOut(g_menuText[i], MENU_ICON_W + 8, cy, TA_LEFT | TA_VCENTER, data, w, h, ARGB(off ? C'150,150,150' : fg, 1.0), COLOR_FORMAT_ARGB_NORMALIZE);
      if(g_menuShort[i] != "")
         TextOut(g_menuShort[i], mw - 20, cy, TA_RIGHT | TA_VCENTER, data, w, h, ARGB(fgKey, 1.0), COLOR_FORMAT_ARGB_NORMALIZE);
      MenuIcon(data, w, g_menuKeys[i], 15, cy);
     }
   ResourceCreate(MenuRes(), data, w, h, 0, 0, w, COLOR_FORMAT_ARGB_NORMALIZE);

   // keep it inside the chart
   int cw = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS), ch = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   if(g_menuX + w > cw)
      g_menuX = MathMax(0, cw - w);
   if(g_menuY + h > ch)
      g_menuY = MathMax(0, ch - h);
   g_menuW = mw;
   g_menuH = mh;

   string o = MenuObj();
   if(ObjectFind(0, o) < 0)
      ObjectCreate(0, o, OBJ_BITMAP_LABEL, 0, 0, 0);
   ObjectSetInteger(0, o, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, o, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, o, OBJPROP_XDISTANCE, g_menuX);
   ObjectSetInteger(0, o, OBJPROP_YDISTANCE, g_menuY);
   ObjectSetInteger(0, o, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, o, OBJPROP_YSIZE, h);
   ObjectSetString(0, o, OBJPROP_BMPFILE, 0, MenuRes());
   ObjectSetString(0, o, OBJPROP_BMPFILE, 1, MenuRes());
   SetCommon(o, false, 100, true);
  }

void MPix(uint &data[], const int w, const int x, const int y, const color c)
  {
   if(x >= 0 && x < w && y >= 0 && y * w + x < ArraySize(data))
      data[y * w + x] = ARGB(c, 1.0);
  }

// Small 14 px icons in MT5 colors: padlock, export arrow, red cross.
void MenuIcon(uint &data[], const int w, const string key, const int cx, const int cy)
  {
   if(key == "LOCK")
     {
      const color c = C'60,110,190';
      for(int x = cx - 5; x <= cx + 5; x++)          // body
         for(int y = cy - 1; y <= cy + 5; y++)
            MPix(data, w, x, y, c);
      MPix(data, w, cx, cy + 1, C'240,240,240');     // key hole
      MPix(data, w, cx, cy + 2, C'240,240,240');
      for(int y = cy - 5; y <= cy - 2; y++)          // shackle
        {
         MPix(data, w, cx - 4, y, c);
         MPix(data, w, cx - 3, y, c);
         MPix(data, w, cx + 3, y, c);
         MPix(data, w, cx + 4, y, c);
        }
      for(int x = cx - 3; x <= cx + 3; x++)
        {
         MPix(data, w, x, cy - 6, c);
         MPix(data, w, x, cy - 5, c);
        }
     }
   else
      if(key == "EXP")
        {
         const color c = C'40,150,70';
         for(int x = cx - 6; x <= cx + 6; x++)        // tray
            MPix(data, w, x, cy + 5, c);
         MPix(data, w, cx - 6, cy + 4, c);
         MPix(data, w, cx + 6, cy + 4, c);
         MPix(data, w, cx - 6, cy + 3, c);
         MPix(data, w, cx + 6, cy + 3, c);
         for(int y = cy - 6; y <= cy + 2; y++)        // arrow shaft
           {
            MPix(data, w, cx, y, c);
            MPix(data, w, cx + 1, y, c);
           }
         for(int k = 1; k <= 3; k++)                  // arrow head
           {
            MPix(data, w, cx - k, cy - 6 + k, c);
            MPix(data, w, cx + 1 + k, cy - 6 + k, c);
           }
        }
      else
         if(key == "DEL")
           {
            const color c = C'215,50,50';
            for(int k = -5; k <= 5; k++)
              {
               MPix(data, w, cx + k, cy + k, c);
               MPix(data, w, cx + k + 1, cy + k, c);
               MPix(data, w, cx + k, cy - k, c);
               MPix(data, w, cx + k + 1, cy - k, c);
              }
           }
  }

void OpenMenu(const int id, const int x, const int y)
  {
   int i = FindPos(id);
   if(i < 0)
      return;
   if(g_menuId < 0)
     {
      g_menuScrollWas = (bool)ChartGetInteger(0, CHART_MOUSE_SCROLL);
      ChartSetInteger(0, CHART_MOUSE_SCROLL, false);   // clicking the menu must not scroll the chart
     }
   g_menuId  = id;
   g_menuX   = x + 2;
   g_menuY   = y + 2;
   g_menuHot = -1;
   ArrayResize(g_menuKeys, 0);
   ArrayResize(g_menuText, 0);
   ArrayResize(g_menuShort, 0);
   MenuAdd("LOCK", g_pos[i].locked ? "Unlock" : "Lock");
   MenuAdd("EXP",  "Export box");
   MenuAdd("SEP",  "");
   // right-click on a selected box keeps the selection: Delete then removes all selected
   bool inSel = id == g_active || IsSel(id);
   if(inSel && id != g_active)
     {
      // promote a selected box to active, the previous active one stays selected
      SelRemove(id);
      if(FindPos(g_active) >= 0)
        {
         int ns0 = ArraySize(g_sel);
         ArrayResize(g_sel, ns0 + 1);
         g_sel[ns0] = g_active;
        }
     }
   SetActive(id, inSel);
   int sel[];
   int ns = SelectedIds(sel), nu = 0;
   for(int k = 0; k < ns; k++)
     {
      int j = FindPos(sel[k]);
      if(j >= 0 && !g_pos[j].locked)
         nu++;
     }
   if(nu == 0)
      MenuAdd("DELOFF", "Delete (unlock first)");   // greyed out, not clickable
   else
      if(g_pos[i].locked)   // locked box in a selection with unlocked ones: delete those
         MenuAdd("DEL", StringFormat("Delete %d unlocked", nu), "Del");
      else
         MenuAdd("DEL", nu > 1 ? StringFormat("Delete %d boxes", nu) : "Delete", "Del");
   DrawMenu();
   Dbg(StringFormat("menu opened id=%d", id));
   ChartRedraw();
  }

void CloseMenu()
  {
   if(g_menuId < 0)
      return;
   g_menuId = -1;
   ObjectDelete(0, MenuObj());
   ResourceFree(MenuRes());
   ChartSetInteger(0, CHART_MOUSE_SCROLL, g_menuScrollWas);
   ChartRedraw();
  }

int MenuRowAt(const int x, const int y)
  {
   if(g_menuId < 0 || x < g_menuX || x >= g_menuX + g_menuW || y < g_menuY || y >= g_menuY + g_menuH)
      return -1;
   int tops[];
   MenuLayout(tops);
   for(int i = 0; i < ArraySize(tops); i++)
      if(g_menuKeys[i] != "SEP" && g_menuKeys[i] != "DELOFF" && y - g_menuY >= tops[i] && y - g_menuY < tops[i] + MENU_ROW_H)
         return i;
   return -1;
  }

void MenuHover(const int x, const int y)
  {
   int row = MenuRowAt(x, y);
   if(row == g_menuHot)
      return;
   g_menuHot = row;
   DrawMenu();
   ChartRedraw();
  }

void MenuAction(const int row)
  {
   int id = g_menuId;
   string key = g_menuKeys[row];
   CloseMenu();
   int i = FindPos(id);
   if(i < 0)
      return;
   Dbg("menu " + key);
   if(key == "LOCK")
     {
      g_pos[i].locked = !g_pos[i].locked;
      DrawPos(g_pos[i]);
      DbgPos(g_pos[i].locked ? "locked" : "unlocked", g_pos[i]);
     }
   else
      if(key == "EXP")
         ExportJson(id);
      else
         if(key == "DEL")
            DeleteSelected();   // the clicked box + the other selected ones (locked skipped)
   UpdatePanel();
   ChartRedraw();
  }

void OnButton(const string key)
  {
   Dbg("button " + key);
   if(key == "LONG" || key == "SHORT")
     {
      int d = (key == "LONG") ? 1 : -1;
      g_placeDir = (g_placeDir == d) ? 0 : d;   // click again = cancel
      Dbg(g_placeDir != 0 ? "placement armed - click on chart" : "placement cancelled");
     }
   else
      if(key == "EXPORT")
         ExportJson();
      else
      if(key == "RESTORE")
         RestoreClick();
      else
      if(key == "STATS")
        {
         g_showStats = !g_showStats;
         Dbg(g_showStats ? "stats shown" : "stats hidden");
        }
      else
      if(key == "PREV" || key == "NEXT")
         Navigate(key == "NEXT" ? 1 : -1);
      else
      if(key == "CNT")
        {
         int i = FindPos(g_active);
         if(i >= 0)
            CenterOn(g_pos[i]);
         else
            Navigate(1);
        }
      else
         if(key == "LOCK")
           {
            int i = FindPos(g_active);
            if(i >= 0)
              {
               g_pos[i].locked = !g_pos[i].locked;
               DrawPos(g_pos[i]);
               DbgPos(g_pos[i].locked ? "locked" : "unlocked", g_pos[i]);
              }
           }
         else
            if(key == "HIDE")
              {
               SetHidden(!g_hidden);
               Dbg(g_hidden ? "hidden" : "shown");
              }
            else
                  if(key == "CLEAR")
                    {
                     if(g_clearArmed != 0 && (GetTickCount() - g_clearArmed) < CLEAR_ARM_MS)
                       {
                        g_clearArmed = 0;
                        DeleteAllPos();
                       }
                     else
                        g_clearArmed = GetTickCount();
                    }
   UpdatePanel();
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   HandleChartEvent(id, lparam, dparam, sparam);
   // auto backup after a change (throttled for mouse moves; never in the middle of a drag)
   if(InpAutoBackup && !g_drag.on && (id != CHARTEVENT_MOUSE_MOVE || GetTickCount() - g_bakCheck >= 500))
     {
      g_bakCheck = GetTickCount();
      MaybeBackup();
     }
  }

void HandleChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_MOUSE_MOVE)
     {
      int  x     = (int)lparam;
      int  y     = (int)dparam;
      int  state = (int)StringToInteger(sparam);
      bool down  = (state & 1) != 0;
      bool rdown = (state & 2) != 0;
      // right button pressed over a box -> our menu (MT5's menu is off there)
      if(rdown && !g_rDown)
        {
         g_rDown = true;
         int bid = g_drag.on ? -1 : BoxAt(x, y);
         // While MT5's own menu was open no mouse-move events arrived, so the "MT5 menu off
         // over a box" state may be stale. MT5 opens its menu on button RELEASE -> switch it
         // off right now, at press, so only our menu appears.
         BlockTradeDrag(bid > 0);
         if(bid > 0)
           {
            ChartSetInteger(0, CHART_CONTEXT_MENU, false);
            OpenMenu(bid, x, y);
           }
         else
           {
            CloseMenu();
            if(g_active != -1 || ArraySize(g_sel) > 0)   // right-click on empty chart deselects, like a left click
              {
               SetActive(-1);
               ChartRedraw();
              }
           }
         return;
        }
      if(!rdown)
         g_rDown = false;
      // open menu: it takes the mouse
      if(g_menuId >= 0)
        {
         if(down && !g_mouseDown)
           {
            g_mouseDown = true;
            int row = MenuRowAt(x, y);
            bool inside = x >= g_menuX && x < g_menuX + g_menuW && y >= g_menuY && y < g_menuY + g_menuH;
            if(row >= 0)
               MenuAction(row);
            else
               if(!inside)
                  CloseMenu();  // click outside = just close (separator / border = nothing)
           }
         else
            if(!down)
              {
               g_mouseDown = false;
               MenuHover(x, y);
              }
         return;
        }
      if(down && !g_mouseDown)
        {
         g_mouseDown = true;
         StartDrag(x, y, (state & 8) != 0);   // 8 = Ctrl held
        }
      else
         if(down && g_drag.on)
            DoDrag(x, y);
         else
            if(!down)
              {
               if(g_mouseDown)
                 {
                  g_mouseDown = false;
                  EndDrag();
                 }
               Hover(x, y);
              }
      return;
     }

   if(id == CHARTEVENT_KEYDOWN && lparam == 27 && g_menuId >= 0)   // Esc closes the menu
     {
      CloseMenu();
      return;
     }

   if(id == CHARTEVENT_KEYDOWN && lparam == 46 && (g_active > 0 || ArraySize(g_sel) > 0) && !g_drag.on)   // Delete key -> delete active box
     {
      CloseMenu();
      Dbg("Delete key");
      DeleteSelected();   // active + Ctrl+clicked boxes; locked ones stay
      return;
     }

   if(id == CHARTEVENT_KEYDOWN && lparam == 27 && g_placeDir != 0)   // Esc
     {
      g_placeDir = 0;
      UpdatePanel();
      ChartRedraw();
      return;
     }

   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(StringFind(sparam, UIP) == 0)
        {
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         OnButton(StringSubstr(sparam, StringLen(UIP)));
         ChartRedraw();
        }
      return;
     }

   if(id == CHARTEVENT_OBJECT_CHANGE || id == CHARTEVENT_OBJECT_DRAG)
     {
      // edited via properties dialog -> restore our geometry
      int pid, dir;
      string part;
      if(ParseName(sparam, pid, dir, part))
        {
         int i = FindPos(pid);
         if(i >= 0)
           {
            DrawPos(g_pos[i]);
            ChartRedraw();
           }
        }
      return;
     }

   if(id == CHARTEVENT_OBJECT_DELETE)
     {
      if(sparam == UIP + "XH" || sparam == UIP + "XV" || sparam == MenuObj() || sparam == ActObj())
         return;          // crosshair / menu: recreated when needed
      if(StringFind(sparam, UIP) == 0)
        {
         CreatePanel();   // panel deleted by user -> restore
         ChartRedraw();
         return;
        }
      if(ConsumeSelfDeleted(sparam))
         return;          // removed by the indicator itself (direction flip)
      int pid, dir;
      string part;
      // user deleted a part -> delete whole position (ignored if already removed by us)
      if(ParseName(sparam, pid, dir, part))
        {
         int i = FindPos(pid);
         if(i >= 0 && g_pos[i].dir == dir)
           {
            if(g_pos[i].locked)
              {
               DrawPos(g_pos[i]);   // locked box: put the deleted part back
               ChartRedraw();
               Dbg(StringFormat("locked id=%d - deleted part restored", pid));
              }
            else
               DeletePos(pid);
           }
        }
      return;
     }

   if(id == CHARTEVENT_CHART_CHANGE)
     {
      if((color)ChartGetInteger(0, CHART_COLOR_BACKGROUND) != g_bg)
        {
         ResolveColors();
         CreatePanel();
         DrawAll();
        }
      else
         UpdateAllBadges();   // scroll / zoom -> reposition pixel badges (visible box only)
      PlaceStats();           // chart resize -> keep stats next to the panel
      ChartRedraw();
     }
  }
//+------------------------------------------------------------------+
