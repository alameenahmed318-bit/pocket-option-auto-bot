//+------------------------------------------------------------------+
//| XAUUSD_FastScalper.mq5                                           |
//| GOLD ONLY - standalone MT5 EA, no external includes              |
//+------------------------------------------------------------------+
#property strict
#property version "2.10"

input double LotSize=0.01;
input int FastEMA=9;
input int SlowEMA=21;
input int RSIPeriod=7;
input double BuyRSIMin=50.5;
input double SellRSIMax=49.5;
input int ATRPeriod=14;
input double SL_ATR_Mult=1.5;
input double Trail_ATR_Mult=0.8;
input double ProfitTargetMoney=0.10;
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
 double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
 double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
 double st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 if(mn<=0||mx<=0||st<=0)return 0;
 v=MathMax(mn,MathMin(mx,v));
 double n=MathFloor((v-mn+1e-12)/st);
 return NormalizeDouble(mn+n*st,8);
}

ENUM_ORDER_TYPE_FILLING FillMode(){
 long m=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
 if((m&SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK)return ORDER_FILLING_FOK;
 if((m&SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC)return ORDER_FILLING_IOC;
 return ORDER_FILLING_RETURN;
}

int MyPositions(){
 int n=0;
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong t=PositionGetTicket(i);
  if(t==0||!PositionSelectByTicket(t))continue;
  if((ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber&&PositionGetString(POSITION_SYMBOL)==_Symbol)n++;
 }
 return n;
}

bool SendDeal(ENUM_ORDER_TYPE type,double vol,double sl,string comment){
 vol=NVolume(vol); if(vol<=0)return false;
 double price=(type==ORDER_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
 MqlTradeRequest r={}; MqlTradeResult x={};
 r.action=TRADE_ACTION_DEAL;r.symbol=_Symbol;r.volume=vol;r.type=type;r.price=price;
 r.sl=NPrice(sl);r.tp=0;r.deviation=30;r.magic=MagicNumber;r.type_filling=FillMode();r.comment=comment;
 bool ok=OrderSend(r,x);
 Print("TRADE_RESULT | ok=",ok," retcode=",x.retcode," deal=",x.deal," order=",x.order," comment=",x.comment);
 return ok&&(x.retcode==TRADE_RETCODE_DONE||x.retcode==TRADE_RETCODE_PLACED||x.retcode==TRADE_RETCODE_DONE_PARTIAL);
}

bool ClosePos(ulong ticket){
 if(!PositionSelectByTicket(ticket))return false;
 string s=PositionGetString(POSITION_SYMBOL);double v=PositionGetDouble(POSITION_VOLUME);
 long pt=PositionGetInteger(POSITION_TYPE);
 MqlTradeRequest r={};MqlTradeResult x={};
 r.action=TRADE_ACTION_DEAL;r.symbol=s;r.position=ticket;r.volume=v;
 r.type=(pt==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
 r.price=(r.type==ORDER_TYPE_BUY)?SymbolInfoDouble(s,SYMBOL_ASK):SymbolInfoDouble(s,SYMBOL_BID);
 r.deviation=30;r.magic=MagicNumber;r.type_filling=FillMode();r.comment="XAU auto close";
 bool ok=OrderSend(r,x);
 Print("CLOSE_RESULT | ticket=",ticket," ok=",ok," retcode=",x.retcode," comment=",x.comment);
 return ok&&(x.retcode==TRADE_RETCODE_DONE||x.retcode==TRADE_RETCODE_DONE_PARTIAL);
}

bool ModifySL(ulong ticket,double sl){
 if(!PositionSelectByTicket(ticket))return false;
 MqlTradeRequest r={};MqlTradeResult x={};
 r.action=TRADE_ACTION_SLTP;r.symbol=PositionGetString(POSITION_SYMBOL);r.position=ticket;
 r.sl=NPrice(sl);r.tp=PositionGetDouble(POSITION_TP);
 bool ok=OrderSend(r,x);
 if(!ok||x.retcode!=TRADE_RETCODE_DONE)Print("SL_RESULT | ticket=",ticket," ok=",ok," retcode=",x.retcode," comment=",x.comment);
 return ok&&x.retcode==TRADE_RETCODE_DONE;
}

void Manage(){
 double a[];ArraySetAsSeries(a,true);
 if(CopyBuffer(hATR,0,0,1,a)<1||a[0]<=0)return;
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;
  if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
  double p=PositionGetDouble(POSITION_PROFIT);
  if(p>=ProfitTargetMoney||p<=-MaxLossMoney){ClosePos(t);continue;}
  long ty=PositionGetInteger(POSITION_TYPE);double old=PositionGetDouble(POSITION_SL),ns=old;
  double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
  if(ty==POSITION_TYPE_BUY){double c=NPrice(bid-a[0]*Trail_ATR_Mult);if(old==0||c>old)ns=c;}
  else{double c=NPrice(ask+a[0]*Trail_ATR_Mult);if(old==0||c<old)ns=c;}
  if(ns>0&&ns!=old)ModifySL(t,ns);
 }
}

void OnTick(){
 if(!IsGold())return;
 Manage();
 if(MyPositions()>=MaxPositions)return;
 if((TimeCurrent()-lastEntryTime)<CooldownSeconds)return;
 double f[],s[],r[],a[];ArraySetAsSeries(f,true);ArraySetAsSeries(s,true);ArraySetAsSeries(r,true);ArraySetAsSeries(a,true);
 if(CopyBuffer(hFast,0,0,1,f)<1||CopyBuffer(hSlow,0,0,1,s)<1||CopyBuffer(hRSI,0,0,1,r)<1||CopyBuffer(hATR,0,0,1,a)<1||a[0]<=0)return;
 bool buy=f[0]>s[0]&&r[0]>=BuyRSIMin,sell=f[0]<s[0]&&r[0]<=SellRSIMax;
 double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
 if(buy&&SendDeal(ORDER_TYPE_BUY,LotSize,ask-a[0]*SL_ATR_Mult,"XAU Fast Buy"))lastEntryTime=TimeCurrent();
 else if(sell&&SendDeal(ORDER_TYPE_SELL,LotSize,bid+a[0]*SL_ATR_Mult,"XAU Fast Sell"))lastEntryTime=TimeCurrent();
}

int OnInit(){
 if(!IsGold()){Print("INIT_FAILED | XAUUSD ONLY | current symbol=",_Symbol);return INIT_FAILED;}
 hFast=iMA(_Symbol,PERIOD_M1,FastEMA,0,MODE_EMA,PRICE_CLOSE);
 hSlow=iMA(_Symbol,PERIOD_M1,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
 hRSI=iRSI(_Symbol,PERIOD_M1,RSIPeriod,PRICE_CLOSE);
 hATR=iATR(_Symbol,PERIOD_M1,ATRPeriod);
 if(hFast==INVALID_HANDLE||hSlow==INVALID_HANDLE||hRSI==INVALID_HANDLE||hATR==INVALID_HANDLE)return INIT_FAILED;
 Print("XAUUSD_FastScalper v2.10 READY | XAUUSD ONLY | M1 | LOT 0.01");
 return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){
 if(hFast!=INVALID_HANDLE)IndicatorRelease(hFast);if(hSlow!=INVALID_HANDLE)IndicatorRelease(hSlow);
 if(hRSI!=INVALID_HANDLE)IndicatorRelease(hRSI);if(hATR!=INVALID_HANDLE)IndicatorRelease(hATR);
}
//+------------------------------------------------------------------+