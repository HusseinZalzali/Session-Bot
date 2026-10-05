//+------------------------------------------------------------------+
//|                                          AsianLondonBreakout.mq5 |
//|  Asian Range -> London Breakout. BACKTEST ONLY (Strategy Tester) |
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "Asian range (UTC) -> London breakout on M5 candle close. Backtest only."

#include <Trade\Trade.mqh>

//--- SL methods
enum ENUM_SL_METHOD
  {
   SL_OPPOSITE_RANGE = 0, // Opposite side of Asian range
   SL_RANGE_MID      = 1, // Middle of Asian range
   SL_FIXED_POINTS   = 2  // Fixed distance (points)
  };

//--- How broker server time relates to UTC
enum ENUM_SERVER_TZ
  {
   TZ_AUTO_US_DST = 0, // Auto: UTC+2 winter / UTC+3 summer, US DST dates (most brokers)
   TZ_AUTO_EU_DST = 1, // Auto: UTC+2 winter / UTC+3 summer, EU DST dates
   TZ_FIXED       = 2  // Fixed offset (InpServerUTCOffset)
  };

input group "Sessions (hours, UTC)"
input int            InpAsianStartUTC   = 0;    // Asian start UTC
input int            InpAsianEndUTC     = 8;    // Asian end UTC (range frozen here)
input int            InpLondonStartUTC  = 8;    // London start UTC (first signal candle opens here)
input int            InpTradeEndUTC     = 12;   // Trading window end UTC (no new entries from here)

input group "Broker server time"
input ENUM_SERVER_TZ InpServerTZ        = TZ_AUTO_US_DST; // Server timezone mode
input int            InpServerUTCOffset = 2;    // Server UTC offset in hours (Fixed mode only)

input group "Trade"
input string         InpSymbol          = "";   // Symbol ("" = chart symbol)
input double         InpLots            = 0.01; // Lot size (fixed)
input ENUM_SL_METHOD InpSLMethod        = SL_OPPOSITE_RANGE; // SL method
input int            InpSLPoints        = 3000; // SL distance in points (Fixed method only)
input double         InpRR              = 2.0;  // Reward:Risk (TP = RR x SL distance)
input int            InpMaxTradesPerDay = 1;    // Maximum trades per UTC day
input ulong          InpMagic           = 240801; // Magic number

input group "Report"
input double         InpExtraCommission = 0.0;  // Extra round-turn commission per 1.0 lot (report only, 0 = off)

//--- globals
CTrade   g_trade;
string   g_sym;
datetime g_lastBar   = 0;   // open time of last processed M5 bar (server time)
long     g_rangeDay  = -1;  // UTC day number the stored range belongs to
double   g_asHigh    = 0;
double   g_asLow     = 0;

//+------------------------------------------------------------------+
//| Time helpers                                                     |
//+------------------------------------------------------------------+
datetime MakeDate(int y, int m, int d)
  {
   MqlDateTime s = {};
   s.year = y; s.mon = m; s.day = d;
   return StructToTime(s);
  }

// n-th Sunday (00:00) of a month
datetime NthSunday(int y, int m, int n)
  {
   datetime first = MakeDate(y, m, 1);
   MqlDateTime s; TimeToStruct(first, s);
   return first + (datetime)(((7 - s.day_of_week) % 7 + 7 * (n - 1)) * 86400);
  }

// last Sunday (00:00) of a month
datetime LastSunday(int y, int m)
  {
   datetime last = (m == 12 ? MakeDate(y + 1, 1, 1) : MakeDate(y, m + 1, 1)) - 86400;
   MqlDateTime s; TimeToStruct(last, s);
   return last - (datetime)(s.day_of_week * 86400);
  }

// server offset from UTC in seconds. DST switches happen on Sundays (market closed),
// so date-level precision is sufficient.
int OffsetSec(datetime t)
  {
   if(InpServerTZ == TZ_FIXED)
      return InpServerUTCOffset * 3600;
   MqlDateTime s; TimeToStruct(t, s);
   bool dst;
   if(InpServerTZ == TZ_AUTO_US_DST)
      dst = (t >= NthSunday(s.year, 3, 2) && t < NthSunday(s.year, 11, 1));
   else
      dst = (t >= LastSunday(s.year, 3) && t < LastSunday(s.year, 10));
   return (dst ? 3 : 2) * 3600;
  }

datetime ToUTC(datetime server) { return server - OffsetSec(server); }
datetime ToServer(datetime utc) { return utc + OffsetSec(utc); }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!MQLInfoInteger(MQL_TESTER))
     {
      Print("AsianLondonBreakout is for the Strategy Tester only.");
      return INIT_FAILED;
     }
   g_sym = (InpSymbol == "" ? _Symbol : InpSymbol);
   if(!SymbolSelect(g_sym, true))
     {
      Print("Symbol not available: ", g_sym);
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpAsianStartUTC < 0 || InpAsianStartUTC >= InpAsianEndUTC || InpAsianEndUTC > InpLondonStartUTC ||
      InpLondonStartUTC >= InpTradeEndUTC || InpTradeEndUTC > 24)
     {
      Print("Invalid session hours. Required: 0 <= AsianStart < AsianEnd <= LondonStart < TradeEnd <= 24");
      return INIT_PARAMETERS_INCORRECT;
     }
   double vmin = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX);
   if(InpRR <= 0 || InpMaxTradesPerDay < 1 || InpLots < vmin || InpLots > vmax ||
      (InpSLMethod == SL_FIXED_POINTS && InpSLPoints <= 0))
     {
      Print("Invalid RR / lots / max trades / SL points. Lot min=", vmin, " max=", vmax);
      return INIT_PARAMETERS_INCORRECT;
     }
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFillingBySymbol(g_sym);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Asian range from M5 candles that OPEN in [AsianStart, AsianEnd)   |
//| UTC. Last candle opens at AsianEnd-5min and is closed by AsianEnd.|
//+------------------------------------------------------------------+
bool EnsureRange(datetime dayUTC)
  {
   long day = (long)(dayUTC / 86400);
   if(g_rangeDay == day)
      return true;

   datetime fromSrv = ToServer(dayUTC + InpAsianStartUTC * 3600);
   datetime toSrv   = ToServer(dayUTC + InpAsianEndUTC * 3600) - 1; // excludes the AsianEnd candle
   MqlRates r[];
   int n = CopyRates(g_sym, PERIOD_M5, fromSrv, toSrv, r);
   if(n <= 0)
      return false;

   double hi = r[0].high, lo = r[0].low;
   for(int i = 1; i < n; i++)
     {
      if(r[i].high > hi) hi = r[i].high;
      if(r[i].low  < lo) lo = r[i].low;
     }
   g_asHigh = hi;
   g_asLow  = lo;
   g_rangeDay = day;
   return true;
  }

//+------------------------------------------------------------------+
//| Entries already opened today (UTC) by this EA                    |
//+------------------------------------------------------------------+
bool CanOpen(datetime dayUTC)
  {
   if(!HistorySelect(ToServer(dayUTC), TimeCurrent() + 60))
      return false;
   int cnt = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(HistoryDealGetString(d, DEAL_SYMBOL) == g_sym &&
         HistoryDealGetInteger(d, DEAL_MAGIC) == (long)InpMagic &&
         HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
         cnt++;
     }
   return cnt < InpMaxTradesPerDay;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- act only on the first tick of a new M5 candle (= open of the candle after the signal)
   datetime barTime = iTime(g_sym, PERIOD_M5, 0);
   if(barTime == 0 || barTime == g_lastBar)
      return;
   g_lastBar = barTime;

   datetime nowUTC = ToUTC(TimeCurrent());
   datetime dayUTC = (datetime)(((long)nowUTC / 86400) * 86400);

   //--- entry window: no new entries at/after window end
   if(nowUTC >= dayUTC + InpTradeEndUTC * 3600)
      return;

   //--- last fully closed M5 candle (shift 1)
   MqlRates sig[];
   if(CopyRates(g_sym, PERIOD_M5, 1, 1, sig) != 1)
      return;
   datetime sigOpenUTC = ToUTC(sig[0].time);
   if(sigOpenUTC < dayUTC + InpLondonStartUTC * 3600) // must be today's London candle
      return;

   if(!EnsureRange(dayUTC))
      return;

   bool buy  = sig[0].close > g_asHigh;   // candle CLOSE above range (wick alone is ignored)
   bool sell = sig[0].close < g_asLow;    // candle CLOSE below range
   if(!buy && !sell)
      return;

   if(!CanOpen(dayUTC))
      return;

   //--- prices
   MqlTick tk;
   if(!SymbolInfoTick(g_sym, tk))
      return;
   int    digits = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   double entry  = buy ? tk.ask : tk.bid;   // buy fills at Ask, sell at Bid (spread included)

   double sl;
   switch(InpSLMethod)
     {
      case SL_RANGE_MID:    sl = (g_asHigh + g_asLow) / 2.0; break;
      case SL_FIXED_POINTS: sl = buy ? entry - InpSLPoints * point : entry + InpSLPoints * point; break;
      default:              sl = buy ? g_asLow : g_asHigh; break;
     }
   sl = NormalizeDouble(sl, digits);
   double risk = buy ? entry - sl : sl - entry;
   if(risk <= 0)
     {
      Print("Skip: SL on wrong side of entry. entry=", entry, " sl=", sl);
      return;
     }
   double tp = NormalizeDouble(buy ? entry + InpRR * risk : entry - InpRR * risk, digits);

   //--- broker minimum stop distance (buy stops checked vs Bid, sell stops vs Ask)
   double minDist = SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   if(minDist > 0)
     {
      double ref = buy ? tk.bid : tk.ask;
      if(MathAbs(ref - sl) < minDist || MathAbs(tp - ref) < minDist)
        {
         Print("Skip: SL/TP closer than stops level.");
         return;
        }
     }

   bool ok = buy ? g_trade.Buy(InpLots, g_sym, entry, sl, tp, "ALB buy")
                 : g_trade.Sell(InpLots, g_sym, entry, sl, tp, "ALB sell");
   if(!ok || g_trade.ResultRetcode() != TRADE_RETCODE_DONE)
      Print("Order failed: ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
   else
      Print(buy ? "BUY " : "SELL ", TimeToString(TimeCurrent()),
            " | AsianH=", DoubleToString(g_asHigh, digits), " AsianL=", DoubleToString(g_asLow, digits),
            " | entry=", DoubleToString(entry, digits), " SL=", DoubleToString(sl, digits),
            " TP=", DoubleToString(tp, digits));
  }

//+------------------------------------------------------------------+
//| Report                                                           |
//+------------------------------------------------------------------+
struct TradeRec
  {
   ulong    pos;
   bool     isLong;
   double   entry;
   double   sl;
   double   vol;
   double   net;      // profit + commission + swap + fee (- extra commission)
   datetime closeT;   // server time of closing deal, 0 = not closed
  };

int FindTrade(const TradeRec &t[], int n, ulong pos)
  {
   for(int i = n - 1; i >= 0; i--)
      if(t[i].pos == pos)
         return i;
   return -1;
  }

int g_fh = INVALID_HANDLE;
void Out(string s)
  {
   Print(s);
   if(g_fh != INVALID_HANDLE)
      FileWriteString(g_fh, s + "\r\n");
  }
string D2(double v) { return DoubleToString(v, 2); }

double OnTester()
  {
   if(!HistorySelect(0, TimeCurrent() + 86400))
      return 0;
   int total = HistoryDealsTotal();

   //--- pass 1: entries opened by this EA
   TradeRec tr[];
   int nt = 0;
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(HistoryDealGetString(d, DEAL_SYMBOL) != g_sym ||
         HistoryDealGetInteger(d, DEAL_MAGIC) != (long)InpMagic ||
         HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      ArrayResize(tr, nt + 1, 1000);
      tr[nt].pos    = (ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID);
      tr[nt].isLong = (HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_BUY);
      tr[nt].entry  = HistoryDealGetDouble(d, DEAL_PRICE);
      tr[nt].sl     = HistoryDealGetDouble(d, DEAL_SL);
      tr[nt].vol    = HistoryDealGetDouble(d, DEAL_VOLUME);
      tr[nt].net    = -InpExtraCommission * tr[nt].vol;
      tr[nt].closeT = 0;
      nt++;
     }

   //--- pass 2: all deals of those positions (incl. SL/TP and end-of-test closes)
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      int k = FindTrade(tr, nt, (ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID));
      if(k < 0)
         continue;
      tr[k].net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
                   HistoryDealGetDouble(d, DEAL_SWAP)   + HistoryDealGetDouble(d, DEAL_FEE);
      long e = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY)
         tr[k].closeT = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
     }

   //--- order by close time (positions can overlap across days)
   for(int i = 1; i < nt; i++)
     {
      TradeRec x = tr[i];
      int j = i - 1;
      while(j >= 0 && tr[j].closeT > x.closeT) { tr[j + 1] = tr[j]; j--; }
      tr[j + 1] = x;
     }

   //--- statistics
   int    closed = 0, wins = 0, losses = 0, longs = 0, shorts = 0, longWins = 0, shortWins = 0;
   int    curW = 0, curL = 0, maxW = 0, maxL = 0, rCount = 0;
   double grossP = 0, grossL = 0, sumR = 0;
   double deposit = TesterStatistics(STAT_INITIAL_DEPOSIT);
   double bal = deposit, peak = deposit, ddMoney = 0, ddPct = 0;

   int    mKey[]; int mTr[]; int mWin[]; double mNet[];
   int    nm = 0;

   for(int i = 0; i < nt; i++)
     {
      if(tr[i].closeT == 0)
         continue;
      closed++;
      double net = tr[i].net;
      bool win = net > 0, loss = net < 0;

      if(tr[i].isLong) { longs++;  if(win) longWins++; }
      else             { shorts++; if(win) shortWins++; }

      if(win)  { wins++;   grossP += net; curW++; curL = 0; if(curW > maxW) maxW = curW; }
      if(loss) { losses++; grossL += net; curL++; curW = 0; if(curL > maxL) maxL = curL; }

      //--- realized R = net / initial risk money
      double riskMoney = 0;
      if(tr[i].sl > 0 &&
         OrderCalcProfit(tr[i].isLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, g_sym, tr[i].vol,
                         tr[i].entry, tr[i].sl, riskMoney) && riskMoney < 0)
        { sumR += net / -riskMoney; rCount++; }

      //--- closed-trade balance drawdown
      bal += net;
      if(bal > peak) peak = bal;
      if(peak - bal > ddMoney) ddMoney = peak - bal;
      if(peak > 0 && (peak - bal) / peak * 100.0 > ddPct) ddPct = (peak - bal) / peak * 100.0;

      //--- monthly (UTC month of close)
      MqlDateTime s; TimeToStruct(ToUTC(tr[i].closeT), s);
      int key = s.year * 100 + s.mon, m = -1;
      for(int j = 0; j < nm; j++) if(mKey[j] == key) { m = j; break; }
      if(m < 0)
        {
         m = nm++;
         ArrayResize(mKey, nm); ArrayResize(mTr, nm); ArrayResize(mWin, nm); ArrayResize(mNet, nm);
         mKey[m] = key; mTr[m] = 0; mWin[m] = 0; mNet[m] = 0;
        }
      mTr[m]++; if(win) mWin[m]++; mNet[m] += net;
     }

   double netProfit = grossP + grossL;
   double avgWin  = wins   > 0 ? grossP / wins   : 0;
   double avgLoss = losses > 0 ? grossL / losses : 0;

   //--- output (journal + Common\Files CSV); skip file during optimization
   if(!MQLInfoInteger(MQL_OPTIMIZATION))
      g_fh = FileOpen("AsianLondonBreakout_Report.csv", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);

   Out("===== AsianLondonBreakout report =====");
   Out("Symbol," + g_sym);
   Out("Lots," + DoubleToString(InpLots, 2) + ",RR," + D2(InpRR) + ",SL method," + EnumToString(InpSLMethod));
   Out("Extra commission per lot (report only)," + D2(InpExtraCommission));
   Out("Total trades," + IntegerToString(closed));
   Out("Winning trades," + IntegerToString(wins));
   Out("Losing trades," + IntegerToString(losses));
   Out("Breakeven trades," + IntegerToString(closed - wins - losses));
   Out("Win rate %," + D2(closed > 0 ? 100.0 * wins / closed : 0));
   Out("Net profit," + D2(netProfit));
   Out("Gross profit," + D2(grossP));
   Out("Gross loss," + D2(grossL));
   Out("Profit factor," + (grossL < 0 ? D2(grossP / -grossL) : "n/a (no losses)"));
   Out("Max drawdown $ (equity; tester)," + D2(TesterStatistics(STAT_EQUITY_DD)));
   Out("Max drawdown % (equity; tester)," + D2(TesterStatistics(STAT_EQUITYDD_PERCENT)));
   Out("Max drawdown $ (closed trades)," + D2(ddMoney));
   Out("Max drawdown % (closed trades)," + D2(ddPct));
   Out("Average win," + D2(avgWin));
   Out("Average loss," + D2(avgLoss));
   Out("Average RR (avg win / avg loss)," + (avgLoss < 0 ? D2(avgWin / -avgLoss) : "n/a"));
   Out("Average realized R per trade," + (rCount > 0 ? D2(sumR / rCount) : "n/a"));
   Out("Long trades," + IntegerToString(longs));
   Out("Short trades," + IntegerToString(shorts));
   Out("Long win rate %," + D2(longs > 0 ? 100.0 * longWins / longs : 0));
   Out("Short win rate %," + D2(shorts > 0 ? 100.0 * shortWins / shorts : 0));
   Out("Max consecutive wins," + IntegerToString(maxW));
   Out("Max consecutive losses," + IntegerToString(maxL));
   if(nt > closed)
      Out("Still open at end (excluded)," + IntegerToString(nt - closed));
   Out("");
   Out("Month (UTC),Trades,Wins,Losses/BE,Win rate %,Net profit");
   for(int j = 0; j < nm; j++)
      Out(StringFormat("%04d-%02d,%d,%d,%d,%s,%s", mKey[j] / 100, mKey[j] % 100, mTr[j], mWin[j],
                       mTr[j] - mWin[j], D2(100.0 * mWin[j] / mTr[j]), D2(mNet[j])));

   if(g_fh != INVALID_HANDLE)
     {
      FileClose(g_fh);
      g_fh = INVALID_HANDLE;
      Print("Report saved to: ", TerminalInfoString(TERMINAL_COMMONDATA_PATH), "\\Files\\AsianLondonBreakout_Report.csv");
     }
   return netProfit;
  }
//+------------------------------------------------------------------+
