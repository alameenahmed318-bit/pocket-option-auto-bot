//+------------------------------------------------------------------+
//| AL_ZOL.mq5 - Gold-only adaptive scalper                           |
//+------------------------------------------------------------------+
#property strict
#property version "3.00"
#property description "AL ZOL - XAUUSD adaptive scalper"

input double LotSize=0.01;
input int FastEMA=9;
input int SlowEMA=21;
input int RSIPeriod=7;
input double BuyRSIMin=50.5;
input double SellRSIMax=49.5;
input int ATRPeriod=14;
input double SL_ATR_Mult=1.5;
input double Trail_ATR_Mult=0.8;

// Live liquidity proxy: closed-bar tick volume versus its recent average.
input bool EnableLiquidityFilter=true;
input int LiquidityLookback=10;
input double MinLiquidityRatio=0.80;

// Close positions if a confirmed opposite entry signal appears.
input bool EnableSmartReverseClose=true;
input bool ReverseNeedsClosedBar=true;

// Dynamic points target, calculated from current ATR at entry.
input bool EnableLivePointsTarget=true;
input int MinTargetPoints=80;
input double TargetATR_Mult=0.70;
input int MaxTargetPoints=1200;

input double MinATRPoints=0.0;
input double ProfitLockMoney=0.10;
input double MaxLossMoney=10.0;
input int MaxPositions=10;
input int CooldownSeconds=2;
input ulong MagicNumber=26100601;

int hFast=INVALID_HANDLE,hSlow=INVALID_HANDLE,hRSI=INVALID_HANDLE,hATR=INVALID_HANDLE;
datetime lastEntryTime=0;

bool IsGold(){return _Symbol=="XAUUSD";}

double NPrice(double p){
 double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
 int d=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
 if(ts>0)p=MathRound(p/ts)*ts;
 return NormalizeDouble(p,d);
}
double NVolume(double v){
 double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 if(mn<=0||mx<=0||st<=0)return 0;
 v=MathMax(mn,MathMin(mx,v));
 return NormalizeDouble(mn+MathFloor((v-mn+1e-12)/st)*st,8);
}
ENUM_ORDER_TYPE_FILLING FillMode(){
 long m=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
 if((m&SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK)return ORDER_FILLING_FOK;
 if((m&SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC)return ORDER_FILLING_IOC;
 return ORDER_FILLING_RETURN;
}
int MyPositions(){
 int n=0;
 for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t&&PositionSelectByTicket(t)&&(ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber&&PositionGetString(POSITION_SYMBOL)==_Symbol)n++;}
 return n;
}
bool SendDeal(ENUM_ORDER_TYPE type,double vol,double sl,double tp,string comment){
 vol=NVolume(vol);if(vol<=0)return false;
 double price=(type==ORDER_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
 MqlTradeRequest r={};MqlTradeResult x={};
 r.action=TRADE_ACTION_DEAL;r.symbol=_Symbol;r.volume=vol;r.type=type;r.price=price;r.sl=NPrice(sl);r.tp=(tp>0?NPrice(tp):0);
 r.deviation=30;r.magic=MagicNumber;r.type_filling=FillMode();r.comment=comment;
 bool ok=OrderSend(r,x);
 Print("AL_ZOL TRADE | ok=",ok," retcode=",x.retcode," deal=",x.deal," comment=",x.comment);
 return ok&&(x.retcode==TRADE_RETCODE_DONE||x.retcode==TRADE_RETCODE_PLACED||x.retcode==TRADE_RETCODE_DONE_PARTIAL);
}
bool ClosePos(ulong ticket,string why){
 if(!PositionSelectByTicket(ticket))return false;
 string s=PositionGetString(POSITION_SYMBOL);double v=PositionGetDouble(POSITION_VOLUME);long pt=PositionGetInteger(POSITION_TYPE);
 MqlTradeRequest r={};MqlTradeResult x={};r.action=TRADE_ACTION_DEAL;r.symbol=s;r.position=ticket;r.volume=v;
 r.type=(pt==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
 r.price=(r.type==ORDER_TYPE_BUY)?SymbolInfoDouble(s,SYMBOL_ASK):SymbolInfoDouble(s,SYMBOL_BID);
 r.deviation=30;r.magic=MagicNumber;r.type_filling=FillMode();r.comment=why;
 bool ok=OrderSend(r,x);Print("AL_ZOL CLOSE | ",why," ticket=",ticket," ok=",ok," retcode=",x.retcode);
 return ok&&(x.retcode==TRADE_RETCODE_DONE||x.retcode==TRADE_RETCODE_DONE_PARTIAL);
}
bool ModifyStops(ulong ticket,double sl,double tp){
 if(!PositionSelectByTicket(ticket))return false;
 MqlTradeRequest r={};MqlTradeResult x={};r.action=TRADE_ACTION_SLTP;r.symbol=PositionGetString(POSITION_SYMBOL);r.position=ticket;
 r.sl=(sl>0?NPrice(sl):0);r.tp=(tp>0?NPrice(tp):0);
 bool ok=OrderSend(r,x);
 if(!ok||x.retcode!=TRADE_RETCODE_DONE)Print("AL_ZOL MODIFY | ticket=",ticket," retcode=",x.retcode," ",x.comment);
 return ok&&x.retcode==TRADE_RETCODE_DONE;
}
bool GetSignals(bool closedBar,bool &buy,bool &sell,double &atr){
 int shift=closedBar?1:0;double f[],s[],r[],a[];
 ArraySetAsSeries(f,true);ArraySetAsSeries(s,true);ArraySetAsSeries(r,true);ArraySetAsSeries(a,true);
 if(CopyBuffer(hFast,0,shift,1,f)<1||CopyBuffer(hSlow,0,shift,1,s)<1||CopyBuffer(hRSI,0,shift,1,r)<1||CopyBuffer(hATR,0,shift,1,a)<1||a[0]<=0)return false;
 atr=a[0];buy=f[0]>s[0]&&r[0]>=BuyRSIMin;sell=f[0]<s[0]&&r[0]<=SellRSIMax;return true;
}
bool LiquidityOK(){
 if(!EnableLiquidityFilter)return true;
 int n=MathMax(3,LiquidityLookback);long v[];
 ArraySetAsSeries(v,true);
 if(CopyTickVolume(_Symbol,PERIOD_M1,1,n+1,v)<n+1)return false;
 double sum=0;for(int i=1;i<=n;i++)sum+=(double)v[i];
 double avg=sum/n;if(avg<=0)return true;
 double ratio=(double)v[0]/avg;
 Print("AL_ZOL LIQUIDITY | last=",v[0]," avg=",DoubleToString(avg,1)," ratio=",DoubleToString(ratio,2));
 return ratio>=MinLiquidityRatio;
}
int DynamicTargetPoints(double atr){
 double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);if(point<=0)return MinTargetPoints;
 int p=(int)MathRound((atr/point)*TargetATR_Mult);
 p=MathMax(MinTargetPoints,p);if(MaxTargetPoints>0)p=MathMin(MaxTargetPoints,p);return p;
}
void Manage(bool reverseBuy,bool reverseSell,double atr){
 double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong t=PositionGetTicket(i);if(!t||!PositionSelectByTicket(t))continue;
  if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
  long ty=PositionGetInteger(POSITION_TYPE);double profit=PositionGetDouble(POSITION_PROFIT);
  if(profit<=-MaxLossMoney){ClosePos(t,"AL_ZOL max-loss protection");continue;}
  if(EnableSmartReverseClose&&((ty==POSITION_TYPE_BUY&&reverseSell)||(ty==POSITION_TYPE_SELL&&reverseBuy))){
   if(ClosePos(t,"AL_ZOL smart reverse"))lastEntryTime=TimeCurrent();
   continue;
  }
  double open=PositionGetDouble(POSITION_PRICE_OPEN),oldSL=PositionGetDouble(POSITION_SL),oldTP=PositionGetDouble(POSITION_TP),newSL=oldSL;
  if(profit>=ProfitLockMoney){
   double lock=(ty==POSITION_TYPE_BUY)?open+atr*0.05:open-atr*0.05;
   if(ty==POSITION_TYPE_BUY){if(lock>newSL)newSL=lock;}
   else if(newSL==0||lock<newSL)newSL=lock;
  }
  if(ty==POSITION_TYPE_BUY){double tr=NPrice(bid-atr*Trail_ATR_Mult);if(oldSL==0||tr>newSL)newSL=tr;}
  else {double tr=NPrice(ask+atr*Trail_ATR_Mult);if(oldSL==0||tr<newSL)newSL=tr;}
  // Keep the originally set dynamic target; the target is computed live at entry.
  if(newSL>0&&newSL!=oldSL)ModifyStops(t,newSL,oldTP);
 }
}
void OnTick(){
 if(!IsGold())return;
 bool buy=false,sell=false,revBuy=false,revSell=false;double atr=0,revAtr=0;
 if(!GetSignals(false,buy,sell,atr))return;
 if(!GetSignals(EnableSmartReverseClose&&ReverseNeedsClosedBar,revBuy,revSell,revAtr))return;
 Manage(revBuy,revSell,atr);
 if(MyPositions()>=MaxPositions)return;
 if((TimeCurrent()-lastEntryTime)<CooldownSeconds)return;
 double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);if(point<=0)return;
 if(MinATRPoints>0&&atr/point<MinATRPoints)return;
 if(!LiquidityOK())return;
 double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
 int tpPts=EnableLivePointsTarget?DynamicTargetPoints(atr):0;
 double buyTP=tpPts>0?ask+tpPts*point:0,sellTP=tpPts>0?bid-tpPts*point:0;
 if(buy&&SendDeal(ORDER_TYPE_BUY,LotSize,ask-atr*SL_ATR_Mult,buyTP,"AL_ZOL BUY"))lastEntryTime=TimeCurrent();
 else if(sell&&SendDeal(ORDER_TYPE_SELL,LotSize,bid+atr*SL_ATR_Mult,sellTP,"AL_ZOL SELL"))lastEntryTime=TimeCurrent();
}
int OnInit(){
 if(!IsGold()){Print("AL_ZOL INIT FAILED | XAUUSD ONLY | current=",_Symbol);return INIT_FAILED;}
 hFast=iMA(_Symbol,PERIOD_M1,FastEMA,0,MODE_EMA,PRICE_CLOSE);hSlow=iMA(_Symbol,PERIOD_M1,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
 hRSI=iRSI(_Symbol,PERIOD_M1,RSIPeriod,PRICE_CLOSE);hATR=iATR(_Symbol,PERIOD_M1,ATRPeriod);
 if(hFast==INVALID_HANDLE||hSlow==INVALID_HANDLE||hRSI==INVALID_HANDLE||hATR==INVALID_HANDLE)return INIT_FAILED;
 Print("AL_ZOL v3.00 READY | XAUUSD | M1 | liquidity filter + smart reverse + ATR points target");
 return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){
 if(hFast!=INVALID_HANDLE)IndicatorRelease(hFast);if(hSlow!=INVALID_HANDLE)IndicatorRelease(hSlow);
 if(hRSI!=INVALID_HANDLE)IndicatorRelease(hRSI);if(hATR!=INVALID_HANDLE)IndicatorRelease(hATR);
}
//+------------------------------------------------------------------+
