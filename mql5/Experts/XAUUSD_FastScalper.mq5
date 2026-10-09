//+------------------------------------------------------------------+
//| AL_ZOL.mq5 - XAUUSD breakout/retest strategy                     |
//+------------------------------------------------------------------+
#property strict
#property version "4.00"
#property description "AL ZOL - XAUUSD breakout/retest with M5 trend confirmation"

input double LotSize=0.01;
input ulong MagicNumber=26100601;
input int BreakoutLookback=12;
input int TrendFastEMA=50;
input int TrendSlowEMA=200;
input int ATRPeriod=14;
input double RetestATRAllowance=0.20;
input double StopATRMultiplier=1.50;
input double RewardRisk=1.30;
input double TrailStartR=0.80;
input double TrailATRMultiplier=1.00;
input int MaxSpreadPoints=80;
input int MinATRPoints=30;
input int MaxATRPoints=2500;
input int CooldownSeconds=60;
input double MaxLossMoney=10.0;
input bool EnableBreakEven=true;
input double BreakEvenAtR=0.70;

int hFast=INVALID_HANDLE,hSlow=INVALID_HANDLE,hATR=INVALID_HANDLE;
datetime lastBarTime=0,lastEntryTime=0;

bool IsGoldSymbol()
{
   string s=_Symbol;
   return (StringFind(s,"XAUUSD")>=0 || StringFind(s,"GOLD")>=0);
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
bool SendEntry(ENUM_ORDER_TYPE type,double atr)
{
   double vol=NVolume(LotSize);
   if(vol<=0) return false;
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double price=(type==ORDER_TYPE_BUY)?ask:bid;
   double risk=atr*StopATRMultiplier;
   double sl=(type==ORDER_TYPE_BUY)?price-risk:price+risk;
   double tp=(type==ORDER_TYPE_BUY)?price+risk*RewardRisk:price-risk*RewardRisk;
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.volume=vol;
   req.type=type; req.price=price; req.sl=NPrice(sl); req.tp=NPrice(tp);
   req.deviation=30; req.magic=MagicNumber; req.type_filling=FillMode();
   req.comment=(type==ORDER_TYPE_BUY)?"AL_ZOL breakout BUY":"AL_ZOL breakout SELL";
   bool sent=OrderSend(req,res);
   Print("AL_ZOL ENTRY | type=",EnumToString(type)," sent=",sent,
         " retcode=",res.retcode," comment=",res.comment,
         " ATR=",DoubleToString(atr,_Digits));
   if(sent && (res.retcode==TRADE_RETCODE_DONE ||
               res.retcode==TRADE_RETCODE_PLACED ||
               res.retcode==TRADE_RETCODE_DONE_PARTIAL))
   {
      lastEntryTime=TimeCurrent();
      return true;
   }
   return false;
}
bool ModifyPosition(ulong ticket,double sl,double tp)
{
   if(!PositionSelectByTicket(ticket)) return false;
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action=TRADE_ACTION_SLTP; req.symbol=_Symbol; req.position=ticket;
   req.sl=(sl>0)?NPrice(sl):0; req.tp=(tp>0)?NPrice(tp):0;
   bool sent=OrderSend(req,res);
   return sent && res.retcode==TRADE_RETCODE_DONE;
}
void ManagePositions(double atr)
{
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!ticket || !PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber ||
         PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      double profit=PositionGetDouble(POSITION_PROFIT);
      if(MaxLossMoney>0 && profit<=-MaxLossMoney)
      {
         // Emergency monetary loss cap; broker SL remains the primary protection.
         long side=PositionGetInteger(POSITION_TYPE);
         MqlTradeRequest req={}; MqlTradeResult res={};
         req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.position=ticket;
         req.volume=PositionGetDouble(POSITION_VOLUME);
         req.type=(side==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
         req.price=(req.type==ORDER_TYPE_BUY)?ask:bid;
         req.deviation=30; req.magic=MagicNumber; req.type_filling=FillMode();
         req.comment="AL_ZOL money loss cap";
         OrderSend(req,res);
         Print("AL_ZOL LOSS CAP | ticket=",ticket," retcode=",res.retcode);
         continue;
      }
      long side=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double oldSL=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double initialRisk=MathAbs(open-oldSL);
      if(initialRisk<=0) continue;
      double move=(side==POSITION_TYPE_BUY)?bid-open:open-ask;
      double rNow=move/initialRisk;
      double newSL=oldSL;
      if(EnableBreakEven && rNow>=BreakEvenAtR)
      {
         double be=(side==POSITION_TYPE_BUY)?open+point*2:open-point*2;
         if(side==POSITION_TYPE_BUY && be>newSL) newSL=be;
         if(side==POSITION_TYPE_SELL && (newSL==0 || be<newSL)) newSL=be;
      }
      if(rNow>=TrailStartR)
      {
         double trail=(side==POSITION_TYPE_BUY)?bid-atr*TrailATRMultiplier:ask+atr*TrailATRMultiplier;
         if(side==POSITION_TYPE_BUY && trail>newSL) newSL=trail;
         if(side==POSITION_TYPE_SELL && (newSL==0 || trail<newSL)) newSL=trail;
      }
      // Never loosen an existing stop.
      if(newSL>0 && newSL!=oldSL) ModifyPosition(ticket,newSL,tp);
   }
}
bool NewM1Bar()
{
   datetime t=iTime(_Symbol,PERIOD_M1,0);
   if(t<=0 || t==lastBarTime) return false;
   lastBarTime=t; return true;
}
bool GetATR(double &atr)
{
   double a[]; ArraySetAsSeries(a,true);
   if(CopyBuffer(hATR,0,1,1,a)<1 || a[0]<=0) return false;
   atr=a[0]; return true;
}
bool TrendAllows(bool &up,bool &down)
{
   double f[],s[]; ArraySetAsSeries(f,true); ArraySetAsSeries(s,true);
   if(CopyBuffer(hFast,0,1,1,f)<1 || CopyBuffer(hSlow,0,1,1,s)<1) return false;
   double c=iClose(_Symbol,PERIOD_M5,1);
   up=(f[0]>s[0] && c>f[0]);
   down=(f[0]<s[0] && c<f[0]);
   return true;
}
bool FindRetestSignal(bool &buy,bool &sell,double atr)
{
   buy=false; sell=false;
   MqlRates bars[]; ArraySetAsSeries(bars,true);
   int need=BreakoutLookback+4;
   if(CopyRates(_Symbol,PERIOD_M1,1,need,bars)<need) return false;
   double priorHigh=bars[3].high,priorLow=bars[3].low;
   for(int i=3;i<BreakoutLookback+3;i++)
   {
      priorHigh=MathMax(priorHigh,bars[i].high);
      priorLow=MathMin(priorLow,bars[i].low);
   }
   // bars[2] must break the prior range; bars[1] must retest and reject it.
   bool brokeUp=bars[2].close>priorHigh && bars[2].close>bars[2].open;
   bool brokeDown=bars[2].close<priorLow && bars[2].close<bars[2].open;
   double allowance=atr*RetestATRAllowance;
   bool retestBuy=(bars[1].low<=priorHigh+allowance &&
                   bars[1].low>=priorHigh-allowance &&
                   bars[1].close>priorHigh && bars[1].close>bars[1].open);
   bool retestSell=(bars[1].high>=priorLow-allowance &&
                    bars[1].high<=priorLow+allowance &&
                    bars[1].close<priorLow && bars[1].close<bars[1].open);
   bool up=false,down=false;
   if(!TrendAllows(up,down)) return false;
   buy=brokeUp && retestBuy && up;
   sell=brokeDown && retestSell && down;
   return true;
}
void OnTick()
{
   if(!IsGoldSymbol()) return;
   double atr=0; if(!GetATR(atr)) return;
   ManagePositions(atr);
   if(!NewM1Bar()) return;
   if(MyPositions()>0) return; // one position at a time; no stacking/grid
   if(TimeCurrent()-lastEntryTime<CooldownSeconds) return;
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(point<=0) return;
   double spread=(SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/point;
   if(MaxSpreadPoints>0 && spread>MaxSpreadPoints)
   {
      Print("AL_ZOL FILTER | spread too high: ",DoubleToString(spread,1));
      return;
   }
   double atrPts=atr/point;
   if((MinATRPoints>0 && atrPts<MinATRPoints) ||
      (MaxATRPoints>0 && atrPts>MaxATRPoints))
   {
      Print("AL_ZOL FILTER | ATR out of range: ",DoubleToString(atrPts,1));
      return;
   }
   bool buy=false,sell=false;
   if(!FindRetestSignal(buy,sell,atr)) return;
   if(buy) SendEntry(ORDER_TYPE_BUY,atr);
   else if(sell) SendEntry(ORDER_TYPE_SELL,atr);
}
int OnInit()
{
   if(!IsGoldSymbol())
   {
      Print("AL_ZOL INIT FAILED | attach to XAUUSD/GOLD chart; current=",_Symbol);
      return INIT_FAILED;
   }
   hFast=iMA(_Symbol,PERIOD_M5,TrendFastEMA,0,MODE_EMA,PRICE_CLOSE);
   hSlow=iMA(_Symbol,PERIOD_M5,TrendSlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hATR=iATR(_Symbol,PERIOD_M1,ATRPeriod);
   if(hFast==INVALID_HANDLE || hSlow==INVALID_HANDLE || hATR==INVALID_HANDLE)
      return INIT_FAILED;
   Print("AL_ZOL v4.00 READY | breakout + retest | M5 trend | M1 entries | no grid");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   if(hFast!=INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow!=INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
}
//+------------------------------------------------------------------+
