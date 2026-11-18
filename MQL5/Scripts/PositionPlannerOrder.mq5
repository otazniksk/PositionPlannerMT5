//+------------------------------------------------------------------+
//|                                          PositionPlannerOrder.mq5 |
//|                         Copyright 2026, otaznik.sk - Michal Škop |
//|                           https://www.mql5.com/en/users/otazniksk |
//+------------------------------------------------------------------+
//| Companion script of the PositionPlanner indicator.               |
//| Reads the ACTIVE box (clicked box) of PositionPlanner on this    |
//| chart and ALWAYS asks twice before sending:                      |
//|   1. inputs window: order type - pending at the box entry        |
//|      (Limit or Stop follows from the entry vs. the price) or     |
//|      market now (same SL / TP / lots)                            |
//|   2. confirmation with all values: Yes = send, No = nothing      |
//| Tip: Navigator -> Scripts -> PositionPlannerOrder -> right click |
//|      -> Set hotkey (e.g. Ctrl+Shift+O).                          |
//+------------------------------------------------------------------+
//| MIT License                                                      |
//|                                                                  |
//| Copyright (c) 2026 otaznik.sk - Michal Škop                      |
//|                                                                  |
//| Permission is hereby granted, free of charge, to any person      |
//| obtaining a copy of this software and associated documentation   |
//| files (the "Software"), to deal in the Software without          |
//| restriction, including without limitation the rights to use,     |
//| copy, modify, merge, publish, distribute, sublicense, and/or     |
//| sell copies of the Software, and to permit persons to whom the   |
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
#property copyright "Copyright 2026, otaznik.sk - Michal Škop"
#property link      "https://www.mql5.com/en/users/otazniksk"
#property version   "1.00"
#property description "Places an order from the active PositionPlanner box - always asks first."

#property script_show_inputs

#include <Trade\Trade.mqh>

enum ENUM_PP_ORDER
  {
   PP_PENDING = 0,   // Pending at box entry (Limit / Stop)
   PP_MARKET  = 1    // Market now
  };
input ENUM_PP_ORDER InpOrder     = PP_PENDING;   // Order type
input int           InpDeviation = 10;           // Market: max price change after confirmation / slippage (points)

#define TITLE "PositionPlanner Order"
#define ACT_OBJ "PPUI_ACT"
#define MAX_CONFIRM 5   // price / box changed after "Yes" -> ask again, at most this many times

void Info(const string msg, const uint icon = MB_ICONINFORMATION)
  {
   Print(TITLE, ": ", msg);
   MessageBox(msg, TITLE, MB_OK | icon);
  }

string Px(const double v) { return DoubleToString(v, _Digits); }

int LotDigits(const double step)
  {
   int d = 0;
   while(d < 8 && MathAbs(step * MathPow(10, d) - MathRound(step * MathPow(10, d))) > 1e-9)
      d++;
   return d;
  }

double NormPrice(const double price)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0)
      return NormalizeDouble(price, _Digits);
   return NormalizeDouble(MathRound(price / ts) * ts, _Digits);
  }

//--- strict number parsing (StringToDouble / StringToInteger accept garbage as 0) ---
bool ParseNum(const string s, double &v)
  {
   int n = StringLen(s), digits = 0, dots = 0;
   if(n == 0)
      return false;
   for(int i = 0; i < n; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c >= '0' && c <= '9')
         digits++;
      else
         if(c == '.')
            dots++;
         else
            if(!(c == '-' && i == 0))
               return false;
     }
   if(digits == 0 || dots > 1)
      return false;
   v = StringToDouble(s);
   return MathIsValidNumber(v);
  }

bool ParseLong(const string s, long &v)
  {
   int n = StringLen(s), digits = 0;
   for(int i = 0; i < n; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c >= '0' && c <= '9')
         digits++;
      else
         if(!(c == '-' && i == 0))
            return false;
     }
   if(digits == 0 || digits > 18)   // > 18 digits could overflow a long
      return false;
   v = StringToInteger(s);
   return true;
  }

//--- active box published by the indicator --------------------------
// "PP2|symbol|id|dir|entry|sl|tp|lots|riskMoney|riskPct|pctOk|ticket|locked"
// sl / tp: exactly "0" = none, otherwise a price that must be > 0.
struct SBox
  {
   string sym;
   int    id;
   int    dir;
   double entry;
   double sl;      // 0 = none
   double tp;      // 0 = none
   double lots;
   long   ticket;
  };

bool SameBox(const SBox &a, const SBox &b)
  {
   return a.sym == b.sym && a.id == b.id && a.dir == b.dir && a.entry == b.entry &&
          a.sl == b.sl && a.tp == b.tp && a.lots == b.lots && a.ticket == b.ticket;
  }

// optional level: "0" = none, anything else must be a valid price > 0
bool ParseLevel(const string s, double &v)
  {
   v = 0;
   if(s == "0")
      return true;
   double x;
   if(!ParseNum(s, x) || x <= 0)
      return false;
   v = NormPrice(x);
   return v > 0;
  }

bool ReadBox(SBox &b, string &err)
  {
   ZeroMemory(b);
   string raw = ObjectFind(0, ACT_OBJ) >= 0 ? ObjectGetString(0, ACT_OBJ, OBJPROP_TEXT) : "";
   if(raw == "")
     {
      err = "No active PositionPlanner box on this chart.\n\nClick a box first (PositionPlanner indicator must be on this chart).";
      return false;
     }
   string f[];
   int n = StringSplit(raw, '|', f);
   if(n > 0 && f[0] == "PP1")
     {
      err = "The PositionPlanner indicator on this chart is an older version.\n\nUpdate (recompile) the indicator, then run this script again.";
      return false;
     }
   if(n != 13 || f[0] != "PP2")
     {
      err = "Unknown data from the PositionPlanner indicator - nothing to place.\n\nIndicator and script versions must match.";
      return false;
     }
   b.sym = f[1];
   if(b.sym != _Symbol)
     {
      err = StringFormat("The active box belongs to %s, but this chart is %s - nothing to place.", b.sym, _Symbol);
      return false;
     }
   long id, dir, ticket;
   double entry, lots;
   if(!ParseLong(f[2], id) || id <= 0 || id > INT_MAX || !ParseLong(f[3], dir) || (dir != 1 && dir != -1) ||
      !ParseNum(f[4], entry) || !ParseNum(f[7], lots) || !ParseLong(f[11], ticket) || ticket < 0)
     {
      err = "Invalid data from the PositionPlanner indicator - nothing to place.";
      return false;
     }
   b.id     = (int)id;
   b.dir    = (int)dir;
   b.lots   = lots;
   b.ticket = ticket;
   b.entry = entry > 0 ? NormPrice(entry) : 0;
   if(b.entry <= 0)
     {
      err = StringFormat("Box #%d: entry price %s is not valid - nothing to place.", b.id, f[4]);
      return false;
     }
   if(!ParseLevel(f[5], b.sl))
     {
      err = StringFormat("Box #%d: stop price %s is not valid - nothing to place.", b.id, f[5]);
      return false;
     }
   if(!ParseLevel(f[6], b.tp))
     {
      err = StringFormat("Box #%d: target price %s is not valid - nothing to place.", b.id, f[6]);
      return false;
     }
   return true;
  }

// Box itself makes sense: linked? lots? stop on the loss side, target on the profit side.
bool CheckBox(const SBox &b, string &err)
  {
   if(b.ticket > 0)
     {
      err = StringFormat("Box #%d is linked to the real position #%I64d - nothing to place.", b.id, b.ticket);
      return false;
     }
   if(b.lots <= 0)
     {
      err = StringFormat("Box #%d has no lot size (no stop or no risk set) - nothing to place.", b.id);
      return false;
     }
   if(b.sl <= 0)
     {
      err = StringFormat("Box #%d has no stop - nothing to place.", b.id);
      return false;
     }
   if(b.dir > 0 ? b.sl >= b.entry : b.sl <= b.entry)
     {
      err = StringFormat("Box #%d: stop is on the wrong side of the entry - nothing to place.", b.id);
      return false;
     }
   if(b.tp > 0 && (b.dir > 0 ? b.tp <= b.entry : b.tp >= b.entry))
     {
      err = StringFormat("Box #%d: target is on the wrong side of the entry - nothing to place.", b.id);
      return false;
     }
   return true;
  }

// Open volume + pending volume in one direction on this symbol (for SYMBOL_VOLUME_LIMIT).
double DirVolume(const int dir)
  {
   double v = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      long t = PositionGetInteger(POSITION_TYPE);
      if((dir > 0 && t == POSITION_TYPE_BUY) || (dir < 0 && t == POSITION_TYPE_SELL))
         v += PositionGetDouble(POSITION_VOLUME);
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderGetTicket(i) == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      long t = OrderGetInteger(ORDER_TYPE);
      bool buy  = t == ORDER_TYPE_BUY || t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_BUY_STOP || t == ORDER_TYPE_BUY_STOP_LIMIT;
      bool sell = t == ORDER_TYPE_SELL || t == ORDER_TYPE_SELL_LIMIT || t == ORDER_TYPE_SELL_STOP || t == ORDER_TYPE_SELL_STOP_LIMIT;
      if((dir > 0 && buy) || (dir < 0 && sell))
         v += OrderGetDouble(ORDER_VOLUME_CURRENT);
     }
   return v;
  }

bool CheckVolume(const SBox &b, double &lots, int &ld, string &err)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vlim = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);
   if(step <= 0)
     {
      err = "The symbol has no volume step - nothing to place.";
      return false;
     }
   ld = LotDigits(step);
   double k = b.lots / step;   // the box volume itself, before any rounding
   lots = NormalizeDouble(MathRound(k) * step, ld);
   if(MathAbs(k - MathRound(k)) > 1e-6 || MathAbs(lots - b.lots) > step * 1e-6)
     {
      err = StringFormat("Lot %s is not a multiple of the volume step %s - nothing to place.",
                         DoubleToString(b.lots, 8), DoubleToString(step, ld));
      return false;
     }
   if(lots < vmin - 1e-9 || (vmax > 0 && lots > vmax + 1e-9))
     {
      err = StringFormat("Lot %s is outside the symbol limits (%s - %s).", DoubleToString(lots, ld),
                         DoubleToString(vmin, ld), DoubleToString(vmax, ld));
      return false;
     }
   if(vlim > 0)
     {
      double used = DirVolume(b.dir);
      if(used + lots > vlim + 1e-9)
        {
         err = StringFormat("Volume limit of %s: max %s lot in one direction (positions + pending orders).\n\nAlready %s lot %s, this order %s lot - nothing to place.",
                            _Symbol, DoubleToString(vlim, ld), DoubleToString(used, ld),
                            b.dir > 0 ? "buy" : "sell", DoubleToString(lots, ld));
         return false;
        }
     }
   return true;
  }

//--- CTrade that can run the exact request through OrderCheck only ---
class CPPTrade : public CTrade
  {
public:
   bool                 m_dry;
   MqlTradeCheckResult  m_chk;
                     CPPTrade(void) : m_dry(false) { ZeroMemory(m_chk); }
   virtual bool      OrderSend(const MqlTradeRequest &request, MqlTradeResult &result)
     {
      if(!m_dry)
         return CTrade::OrderSend(request, result);
      ZeroMemory(m_chk);
      ResetLastError();
      bool ok = ::OrderCheck(request, m_chk);
      result.retcode = m_chk.retcode;
      result.comment = m_chk.comment;
      return ok;
     }
  };

void SetupTrade(CPPTrade &trade)
  {
   trade.SetDeviationInPoints(MathMax(InpDeviation, 0));
   trade.SetTypeFillingBySymbol(_Symbol);
  }

// The same request is used for the dry run (OrderCheck) and for sending.
bool Place(CPPTrade &trade, const SBox &b, const bool market, const ENUM_ORDER_TYPE pType,
           const double lots, const double price)
  {
   string comment = "PositionPlanner #" + IntegerToString(b.id);
   if(!market)
      return trade.OrderOpen(_Symbol, pType, lots, 0, b.entry, b.sl, b.tp, ORDER_TIME_GTC, 0, comment);
   return b.dir > 0 ? trade.Buy(lots, _Symbol, price, b.sl, b.tp, comment)
                    : trade.Sell(lots, _Symbol, price, b.sl, b.tp, comment);
  }

//--- everything that depends on the current price -------------------
struct SPlan
  {
   double          ref;     // price at which the order would fill now (Ask buy / Bid sell)
   ENUM_ORDER_TYPE pType;   // pending type
   string          pName;
   string          msg;     // confirmation text
  };

// distance in whole points, >= stops level and > 0
bool FarEnough(const double dist, const long stopsPts)
  {
   long pts = (long)MathRound(dist / _Point);
   return dist > 0 && pts >= MathMax(stopsPts, 1);
  }

// Money lost at SL for `lots` opened at `open` (positive number), exact via OrderCalcProfit.
bool RiskAt(const int dir, const double lots, const double open, const double sl, double &risk)
  {
   risk = 0;
   if(sl <= 0)
      return false;
   double pr = 0;
   if(!OrderCalcProfit(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, open, sl, pr))
      return false;
   risk = -pr;
   return risk > 0;   // SL on the wrong side of the open price -> no risk figure
  }

bool MakePlan(const SBox &b, const bool market, const double lots, const int ld, SPlan &pl, string &err)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0 || tick.ask <= 0)
     {
      err = "No price for " + _Symbol + ".";
      return false;
     }
   int dir = b.dir;
   pl.ref = dir > 0 ? tick.ask : tick.bid;
   if(dir > 0)
      pl.pType = b.entry < pl.ref ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_BUY_STOP;
   else
      pl.pType = b.entry > pl.ref ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_SELL_STOP;
   pl.pName = StringSubstr(EnumToString(pl.pType), 11);   // ORDER_TYPE_BUY_LIMIT -> BUY_LIMIT
   StringReplace(pl.pName, "_", " ");
   string side = dir > 0 ? "BUY" : "SELL";

   //--- stops level: pending entry vs. price, SL / TP vs. entry (pending) or vs. Bid/Ask (market)
   long stopsPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   string lvl = stopsPts > 0 ? StringFormat(" (broker minimum %I64d points)", stopsPts) : "";
   if(!market)
     {
      if(!FarEnough(MathAbs(b.entry - pl.ref), stopsPts))
        {
         err = "Entry is too close to the current price for a pending order" + lvl + ".\n\nRun again and choose \"Market now\".";
         return false;
        }
      if(!FarEnough(dir * (b.entry - b.sl), stopsPts) || (b.tp > 0 && !FarEnough(dir * (b.tp - b.entry), stopsPts)))
        {
         err = "Stop or target is too close to the entry" + lvl + " - nothing to place.";
         return false;
        }
     }
   else
     {
      // buy position: SL / TP against Bid, sell position: against Ask
      double cp = dir > 0 ? tick.bid : tick.ask;
      // ... and the target must still be a profit from the real fill price (Ask buy / Bid sell)
      if(!FarEnough(dir * (cp - b.sl), stopsPts) || (b.tp > 0 && !FarEnough(dir * (b.tp - cp), stopsPts)) ||
         dir * (pl.ref - b.sl) <= 0 || (b.tp > 0 && dir * (b.tp - pl.ref) <= 0))
        {
         err = "Price is already at or beyond the box stop / target" + lvl + " - a market order is not possible.\n\nRun again and choose \"Pending\".";
         return false;
        }
     }

   //--- confirmation text; money at SL / TP exact (OrderCalcProfit) from the real open price
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   string what = market ? StringFormat("%s %s lot at market now (~%s)", side, DoubleToString(lots, ld), Px(pl.ref))
                        : StringFormat("%s %s lot @ %s", pl.pName, DoubleToString(lots, ld), Px(b.entry));
   string msg = StringFormat("Box #%d   %s %s\n\n", b.id, _Symbol, dir > 0 ? "LONG" : "SHORT");
   msg += what + "\n\n";
   double open = market ? pl.ref : b.entry;
   double mSL = 0, mTP = 0;
   bool   hasSL = RiskAt(dir, lots, open, b.sl, mSL);
   bool   hasTP = b.tp > 0 && OrderCalcProfit(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, open, b.tp, mTP) && mTP > 0;
   // % of balance only when the balance is known (> 0) - otherwise left out, never 0 %
   string sTxt = Px(b.sl) + (hasSL ? StringFormat("     -%.2f %s", mSL, cur) + (bal > 0 ? StringFormat(" (%.2f%%)", mSL / bal * 100) : "") : "");
   string tTxt = b.tp <= 0 ? "none" : Px(b.tp) + (hasTP ? StringFormat("     +%.2f %s", mTP, cur) + (bal > 0 ? StringFormat(" (%.2f%%)", mTP / bal * 100) : "") : "");
   msg += "Stop      " + sTxt + "\n";
   msg += "Target   " + tTxt + "\n";
   if(hasSL && hasTP)
      msg += StringFormat("R:R        %.2f\n", mTP / mSL);

   //--- dry run of the exact request on the trade server rules (OrderCheck)
   CPPTrade dry;
   SetupTrade(dry);
   dry.m_dry = true;
   if(!Place(dry, b, market, pl.pType, lots, pl.ref))
     {
      uint rc = dry.ResultRetcode();
      err = StringFormat("The order would be rejected: %u - %s", rc,
                         dry.ResultComment() != "" ? dry.ResultComment() : dry.ResultRetcodeDescription());
      return false;
     }

   // Margin of THIS order alone (OrderCalcMargin ignores other positions / orders - scripts may
   // call it, indicators may not). Market: free margin after the order from OrderCheck, which
   // includes the account's existing positions. Not shown if it cannot be calculated.
   double mrg = 0;
   if(OrderCalcMargin(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, open, mrg) && mrg > 0)
      msg += StringFormat("Margin of this order   %.2f %s\n", mrg, cur);
   if(market)
      msg += StringFormat("Free margin after       %.2f %s\n", dry.m_chk.margin_free, cur);
   else
      msg += StringFormat("Free margin now          %.2f %s\n", AccountInfoDouble(ACCOUNT_MARGIN_FREE), cur);
   if(market && SymbolInfoInteger(_Symbol, SYMBOL_TRADE_EXEMODE) == SYMBOL_TRADE_EXECUTION_MARKET)
      msg += "\nMarket execution: the broker fills at its current price - the fill may differ from ~" + Px(pl.ref) +
             "\n(the max price change is checked only until sending).\n";
   if(!market && AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      msg += "\nNetting account: if " + _Symbol + " has an open position when this order fills,\nthe order is merged into it.\n";
   pl.msg = msg;
   return true;
  }

// Netting account: a new order is merged into the existing position of the symbol (the box SL / TP
// would then apply to the whole position) -> refused, so the confirmed risk is the real risk.
bool CheckNetting(string &err)
  {
   ENUM_ACCOUNT_MARGIN_MODE mm = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mm == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      return true;
   if(PositionSelect(_Symbol))
     {
      err = StringFormat("Netting account: %s already has an open position (%s lot).\n\nA new order would be merged into it and the box Stop / Target would apply to the whole position - nothing to place.",
                         _Symbol, DoubleToString(PositionGetDouble(POSITION_VOLUME), 2));
      return false;
     }
   return true;
  }

void OnStart()
  {
   string err;
   SBox   b;
   if(!ReadBox(b, err) || !CheckBox(b, err))
     {
      Info(err, MB_ICONWARNING);
      return;
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      Info("Trading is not allowed.\n\nTurn on \"Algo Trading\" in the toolbar (and allow it for scripts).", MB_ICONWARNING);
      return;
     }

   bool   market = (InpOrder == PP_MARKET);
   double lots   = 0;
   int    ld     = 2;
   SPlan  pl;
   string note   = "";
   bool   go     = false;
   for(int attempt = 0; attempt < MAX_CONFIRM && !go; attempt++)
     {
      if(!CheckNetting(err) || !CheckVolume(b, lots, ld, err) || !MakePlan(b, market, lots, ld, pl, err))
        {
         Info(err, MB_ICONWARNING);
         return;
        }
      if(MessageBox(note + pl.msg + "\nSend this order?", TITLE, MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) != IDYES)
        {
         Print(TITLE, ": cancelled");
         return;
        }

      //--- the dialog may have been open for a while: box and price again
      SBox b2;
      if(!ReadBox(b2, err) || !CheckBox(b2, err))
        {
         Info("The box changed while the confirmation was open - nothing sent.\n\n" + err, MB_ICONWARNING);
         return;
        }
      if(!SameBox(b, b2))
        {
         b    = b2;
         note = "The box changed - values updated, please check again.\n\n";
         continue;
        }
      SPlan pl2;
      if(!CheckNetting(err) || !CheckVolume(b, lots, ld, err) || !MakePlan(b, market, lots, ld, pl2, err))
        {
         Info("Nothing sent - the price changed:\n\n" + err, MB_ICONWARNING);
         return;
        }
      if(market ? MathAbs(pl2.ref - pl.ref) > MathMax(InpDeviation, 0) * _Point + _Point * 0.5
                : pl2.pType != pl.pType)
        {
         note = market ? StringFormat("The price moved from %s to %s - values updated, please check again.\n\n", Px(pl.ref), Px(pl2.ref))
                       : StringFormat("The price crossed the entry - the order is now %s, please check again.\n\n", pl2.pName);
         continue;
        }
      // pl (confirmed price) stays: the request price is the confirmed one, so the
      // deviation (instant / request execution) is measured from what was confirmed
      go = true;
     }
   if(!go)
     {
      Info("The price keeps changing - nothing sent. Run the script again.", MB_ICONWARNING);
      return;
     }

   CPPTrade trade;
   SetupTrade(trade);
   bool ok = Place(trade, b, market, pl.pType, lots, pl.ref);
   uint rc = trade.ResultRetcode();
   string sl = Px(b.sl), tp = b.tp > 0 ? Px(b.tp) : "none";
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
     {
      if(market)
        {
         double vol = trade.ResultVolume();
         string part = rc == TRADE_RETCODE_DONE_PARTIAL
                       ? StringFormat("\n\nPARTIAL FILL: %s of %s lot.", DoubleToString(vol, ld), DoubleToString(lots, ld)) : "";
         Info(StringFormat("%s market sent.\n\nOrder #%I64u   %s lot @ %s   SL %s   TP %s%s",
                           b.dir > 0 ? "BUY" : "SELL", trade.ResultOrder(), DoubleToString(vol > 0 ? vol : lots, ld),
                           trade.ResultPrice() > 0 ? Px(trade.ResultPrice()) : "-", sl, tp, part));
        }
      else
         Info(StringFormat("%s placed.\n\nOrder #%I64u   %s lot @ %s   SL %s   TP %s",
                           pl.pName, trade.ResultOrder(), DoubleToString(lots, ld), Px(b.entry), sl, tp));
     }
   else
      Info(StringFormat("Order failed: %u - %s", rc, trade.ResultRetcodeDescription()), MB_ICONERROR);
  }
//+------------------------------------------------------------------+
