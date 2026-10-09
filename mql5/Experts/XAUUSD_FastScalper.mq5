//+------------------------------------------------------------------+
//| AL_ZOL.mq5 - Fast M1 gold scalper                                 |
//+------------------------------------------------------------------+
#property strict
#property version   "5.00"
#property description "AL ZOL M1 quick scalper: EMA momentum + RSI + M5 trend, no grid"

input double LotSize=0.01;
input ulong MagicNumber=26100601;
input int EntryFastEMA=5;
input int EntrySlowEMA=13;
input int TrendFastEMA=20;
input int TrendSlowEMA=50;
input int RSIPeriod=7;
input double BuyRSILevel=53.0;
input double SellRSILevel=47.0;
input int ATRPeriod=14;
input double TakeProfitATR=0.45;
input double StopLossATR=1.00;
input double MinTargetSpreadMultiple=2.5;
input int MaxSpreadPoints=80;
input int MinATRPoints=20;
input int MaxATRPoints=2500;
input int CooldownSeconds=8;
input double ProfitTargetMoney=0.10;
input double MaxLossMoney=10.0;
input int MaxHoldMinutes=8;
input bool UseM5TrendFilter=true;

int hEntryFast=INVALID_HANDLE,hEntrySlow=INVALID_HANDLE;
int hTrendFast=INVALID_HANDLE,hTrendSlow=INVALID_HANDLE;
int hRSI=INVALID_HANDLE,hATR=INVALID_HANDLE;
datetime lastBarTime=0,lastEntryTime=0;

bool IsGoldSymbol()
{
   return (StringFind(_Symbol,"XAUUSD")>=0 || StringFind(_Symbol,"GOLD")>=0);
}
double NPrice(double p)
{
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   if(tick>0) p=MathRound(p/tick)*tick;
   return NormalizeDouble(p,digits);
}
double NVolume(double v)
{
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(mn<=0 || mx<=0 || st<=0) return 0;
   v=MathMax(mn,MathMin(mx,v));
   return NormalizeDouble(mn+MathFloor((v-mn+1e-10)/st)*st,8);
}
ENUM_ORDER_TYPE_FILLING FillMode()
{
   long m=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((m&SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((m&SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}
int MyPositions()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t && PositionSelectByTicket(t) &&
         (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber &&
         PositionGetString(POSITION_SYMBOL)==_Symbol) n++;
   }
   return n;
}
bool ClosePosition(ulong ticket,string why)
{
   if(!PositionSelectByTicket(ticket)) return false;
   long side=PositionGetInteger(POSITION_TYPE);
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.position=ticket;
   req.volume=PositionGetDouble(POSITION_VOLUME);
   req.type=(side==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   req.price=(req.type==ORDER_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   req.deviation=30;
   req.magic=MagicNumber;
   req.type_filling=FillMode();
   req.comment=why;
   bool sent=OrderSend(req,res);
   Print("AL_ZOL CLOSE | reason=",why," sent=",sent," retcode=",res.retcode," ",res.comment);
   return sent && (res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_DONE_PARTIAL);
}
bool NewM1Bar()
{
   datetime t=iTime(_Symbol,PERIOD_M1,0);
   if(t<=0 || t==lastBarTime) return false;
   lastBarTime=t;
   return true;
}
bool ReadValue(int handle,int shift,double &value)
{
   double b[]; ArraySetAsSeries(b,true);
   if(CopyBuffer(handle,0,shift,1,b)<1) return false;
   value=b[0];
   return true;
}
void ManagePositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!ticket || !PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber ||
         PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      double profit=PositionGetDouble(POSITION_PROFIT);
      if(ProfitTargetMoney>0 && profit>=ProfitTargetMoney)
      {
         ClosePosition(ticket,"AL_ZOL small profit");
         continue;
      }
      if(MaxLossMoney>0 && profit<=-MaxLossMoney)
      {
         ClosePosition(ticket,"AL_ZOL max loss");
         continue;
      }
      if(MaxHoldMinutes>0)
      {
         datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
         if(TimeCurrent()-opened>=MaxHoldMinutes*60)
         {
            ClosePosition(ticket,"AL_ZOL time exit");
            continue;
         }
      }
   }
}
bool SendEntry(ENUM_ORDER_TYPE type,double atr,double spreadPrice)
{
   double vol=NVolume(LotSize);
   if(vol<=0) return false;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double price=(type==ORDER_TYPE_BUY)?ask:bid;
   double stopDist=MathMax(atr*StopLossATR,spreadPrice*2.0);
   double targetDist=MathMax(atr*TakeProfitATR,spreadPrice*MinTargetSpreadMultiple);
   long stopLevel=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double minDist=(double)stopLevel*point;
   stopDist=MathMax(stopDist,minDist+point);
   targetDist=MathMax(targetDist,minDist+point);
   double sl=(type==ORDER_TYPE_BUY)?price-stopDist:price+stopDist;
   double tp=(type==ORDER_TYPE_BUY)?price+targetDist:price-targetDist;
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.volume=vol;
   req.type=type; req.price=price; req.sl=NPrice(sl); req.tp=NPrice(tp);
   req.deviation=30; req.magic=MagicNumber; req.type_filling=FillMode();
   req.comment=(type==ORDER_TYPE_BUY)?"AL_ZOL M1 quick BUY":"AL_ZOL M1 quick SELL";
   bool sent=OrderSend(req,res);
   Print("AL_ZOL M1 ENTRY | type=",EnumToString(type)," sent=",sent,
         " retcode=",res.retcode," comment=",res.comment,
         " spreadPts=",DoubleToString(spreadPrice/point,1),
         " target=",DoubleToString(targetDist,_Digits),
         " stop=",DoubleToString(stopDist,_Digits));
   if(sent && (res.retcode==TRADE_RETCODE_DONE ||
               res.retcode==TRADE_RETCODE_PLACED ||
               res.retcode==TRADE_RETCODE_DONE_PARTIAL))
   {
      lastEntryTime=TimeCurrent();
      return true;
   }
   return false;
}
void OnTick()
{
   if(!IsGoldSymbol()) return;
   ManagePositions();
   if(!NewM1Bar()) return;
   if(MyPositions()>0) return; // one trade at a time; no stacking/grid
   if(TimeCurrent()-lastEntryTime<CooldownSeconds) return;

   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(point<=0) return;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double spreadPrice=ask-bid;
   double spreadPts=spreadPrice/point;
   if(MaxSpreadPoints>0 && spreadPts>MaxSpreadPoints)
   {
      Print("AL_ZOL FILTER | spread too high: ",DoubleToString(spreadPts,1));
      return;
   }
   double atr=0,ef=0,es=0,rsi=0,tf=0,ts=0;
   if(!ReadValue(hATR,1,atr) || atr<=0 ||
      !ReadValue(hEntryFast,1,ef) || !ReadValue(hEntrySlow,1,es) ||
      !ReadValue(hRSI,1,rsi)) return;
   double atrPts=atr/point;
   if((MinATRPoints>0 && atrPts<MinATRPoints) ||
      (MaxATRPoints>0 && atrPts>MaxATRPoints))
   {
      Print("AL_ZOL FILTER | ATR out of range: ",DoubleToString(atrPts,1));
      return;
   }
   bool upTrend=true,downTrend=true;
   if(UseM5TrendFilter)
   {
      if(!ReadValue(hTrendFast,1,tf) || !ReadValue(hTrendSlow,1,ts)) return;
      double m5close=iClose(_Symbol,PERIOD_M5,1);
      upTrend=(tf>ts && m5close>tf);
      downTrend=(tf<ts && m5close<tf);
   }
   MqlRates c[]; ArraySetAsSeries(c,true);
   if(CopyRates(_Symbol,PERIOD_M1,1,2,c)<2) return;
   bool bullish=(c[0].close>c[0].open && c[0].close>ef);
   bool bearish=(c[0].close<c[0].open && c[0].close<ef);
   bool buy=(ef>es && rsi>=BuyRSILevel && bullish && upTrend);
   bool sell=(ef<es && rsi<=SellRSILevel && bearish && downTrend);
   if(buy) SendEntry(ORDER_TYPE_BUY,atr,spreadPrice);
   else if(sell) SendEntry(ORDER_TYPE_SELL,atr,spreadPrice);
}
int OnInit()
{
   if(!IsGoldSymbol())
   {
      Print("AL_ZOL INIT FAILED | attach to XAUUSD/GOLD chart; current=",_Symbol);
      return INIT_FAILED;
   }
   hEntryFast=iMA(_Symbol,PERIOD_M1,EntryFastEMA,0,MODE_EMA,PRICE_CLOSE);
   hEntrySlow=iMA(_Symbol,PERIOD_M1,EntrySlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hTrendFast=iMA(_Symbol,PERIOD_M5,TrendFastEMA,0,MODE_EMA,PRICE_CLOSE);
   hTrendSlow=iMA(_Symbol,PERIOD_M5,TrendSlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hRSI=iRSI(_Symbol,PERIOD_M1,RSIPeriod,PRICE_CLOSE);
   hATR=iATR(_Symbol,PERIOD_M1,ATRPeriod);
   if(hEntryFast==INVALID_HANDLE || hEntrySlow==INVALID_HANDLE ||
      hTrendFast==INVALID_HANDLE || hTrendSlow==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE)
   {
      Print("AL_ZOL INIT FAILED | indicator handle error");
      return INIT_FAILED;
   }
   Print("AL_ZOL v5.00 READY | M1 quick scalping | small target | 0.01 lot | no grid/martingale");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   if(hEntryFast!=INVALID_HANDLE) IndicatorRelease(hEntryFast);
   if(hEntrySlow!=INVALID_HANDLE) IndicatorRelease(hEntrySlow);
   if(hTrendFast!=INVALID_HANDLE) IndicatorRelease(hTrendFast);
   if(hTrendSlow!=INVALID_HANDLE) IndicatorRelease(hTrendSlow);
   if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
}
//+------------------------------------------------------------------+
