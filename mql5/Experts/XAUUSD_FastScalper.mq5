//+------------------------------------------------------------------+
//| XAUUSD_FastScalper.mq5                                           |
//| GOLD ONLY - Fast Small-Profit Scalper                            |
//+------------------------------------------------------------------+
#property strict
#property version "1.03"

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

bool IsGoldSymbol(){string s=_Symbol;StringToUpper(s);return(StringFind(s,"XAU")>=0||StringFind(s,"GOLD")>=0);}

ENUM_ORDER_TYPE_FILLING GetFilling(){
 long mode=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
 if((mode&SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK)return ORDER_FILLING_FOK;
 if((mode&SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC)return ORDER_FILLING_IOC;
 return ORDER_FILLING_RETURN;
}

bool SendDeal(ENUM_ORDER_TYPE type,double volume,double sl,string comment){
 MqlTradeRequest req={0}; MqlTradeResult res={0};
 double price=(type==ORDER_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
 int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
 req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.volume=volume; req.type=type;
 req.price=NormalizeDouble(price,digits); req.sl=(sl>0?NormalizeDouble(sl,digits):0);
 req.tp=0; req.deviation=30; req.magic=MagicNumber; req.type_filling=GetFilling(); req.comment=comment;
 if(!OrderSend(req,res))return false;
 return(res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_DONE_PARTIAL||res.retcode==TRADE_RETCODE_PLACED);
}

bool ClosePosition(ulong ticket){
 if(!PositionSelectByTicket(ticket))return false;
 string symbol=PositionGetString(POSITION_SYMBOL);
 double volume=PositionGetDouble(POSITION_VOLUME);
 long ptype=PositionGetInteger(POSITION_TYPE);
 MqlTradeRequest req={0}; MqlTradeResult res={0};
 req.action=TRADE_ACTION_DEAL; req.position=ticket; req.symbol=symbol; req.volume=volume;
 req.type=(ptype==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
 req.price=(req.type==ORDER_TYPE_BUY)?SymbolInfoDouble(symbol,SYMBOL_ASK):SymbolInfoDouble(symbol,SYMBOL_BID);
 req.deviation=30; req.magic=MagicNumber; req.type_filling=GetFilling(); req.comment="XAU Fast Close";
 if(!OrderSend(req,res))return false;
 return(res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_DONE_PARTIAL||res.retcode==TRADE_RETCODE_PLACED);
}

bool ModifySL(ulong ticket,double newSL){
 if(!PositionSelectByTicket(ticket))return false;
 MqlTradeRequest req={0}; MqlTradeResult res={0};
 req.action=TRADE_ACTION_SLTP; req.position=ticket; req.symbol=PositionGetString(POSITION_SYMBOL);
 req.sl=newSL; req.tp=PositionGetDouble(POSITION_TP);
 if(!OrderSend(req,res))return false;
 return(res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_PLACED);
}

int CountMyPositions(){
 int count=0;
 for(int i=PositionsTotal()-1;i>=0;i--){ulong ticket=PositionGetTicket(i);if(ticket==0||!PositionSelectByTicket(ticket))continue;
  if((ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber&&PositionGetString(POSITION_SYMBOL)==_Symbol)count++;}
 return count;
}

void ManagePositions(){
 double atr[];ArraySetAsSeries(atr,true);if(CopyBuffer(hATR,0,0,1,atr)<1||atr[0]<=0)return;
 int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
 double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong ticket=PositionGetTicket(i);if(ticket==0||!PositionSelectByTicket(ticket))continue;
  if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
  double profit=PositionGetDouble(POSITION_PROFIT);long type=PositionGetInteger(POSITION_TYPE);double sl=PositionGetDouble(POSITION_SL);
  if(profit>=ProfitTargetMoney){ClosePosition(ticket);continue;}
  if(profit<=-MaxLossMoney){ClosePosition(ticket);continue;}
  double newSL=sl;
  if(type==POSITION_TYPE_BUY){double c=NormalizeDouble(bid-atr[0]*Trail_ATR_Mult,digits);if(c>0&&c<bid&&(sl==0||c>sl))newSL=c;}
  else if(type==POSITION_TYPE_SELL){double c=NormalizeDouble(ask+atr[0]*Trail_ATR_Mult,digits);if(c>ask&&(sl==0||c<sl))newSL=c;}
  if(newSL!=sl&&newSL>0)ModifySL(ticket,newSL);
 }
}

void OnTick(){
 if(!IsGoldSymbol())return;
 ManagePositions();
 if(CountMyPositions()>=MaxPositions)return;
 if((TimeCurrent()-lastEntryTime)<CooldownSeconds)return;
 double fast[],slow[],rsi[],atr[];ArraySetAsSeries(fast,true);ArraySetAsSeries(slow,true);ArraySetAsSeries(rsi,true);ArraySetAsSeries(atr,true);
 if(CopyBuffer(hFast,0,0,2,fast)<2||CopyBuffer(hSlow,0,0,2,slow)<2||CopyBuffer(hRSI,0,0,2,rsi)<2||CopyBuffer(hATR,0,0,2,atr)<2||atr[0]<=0)return;
 bool buySignal=fast[0]>slow[0]&&rsi[0]>=BuyRSIMin;
 bool sellSignal=fast[0]<slow[0]&&rsi[0]<=SellRSIMax;
 int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),d=atr[0]*SL_ATR_Mult;
 if(buySignal){double sl=NormalizeDouble(ask-d,digits);if(SendDeal(ORDER_TYPE_BUY,LotSize,sl,"XAU Fast Buy"))lastEntryTime=TimeCurrent();}
 else if(sellSignal){double sl=NormalizeDouble(bid+d,digits);if(SendDeal(ORDER_TYPE_SELL,LotSize,sl,"XAU Fast Sell"))lastEntryTime=TimeCurrent();}
}

int OnInit(){
 if(!IsGoldSymbol())return INIT_FAILED;
 hFast=iMA(_Symbol,PERIOD_M1,FastEMA,0,MODE_EMA,PRICE_CLOSE);
 hSlow=iMA(_Symbol,PERIOD_M1,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
 hRSI=iRSI(_Symbol,PERIOD_M1,RSIPeriod,PRICE_CLOSE);hATR=iATR(_Symbol,PERIOD_M1,ATRPeriod);
 if(hFast==INVALID_HANDLE||hSlow==INVALID_HANDLE||hRSI==INVALID_HANDLE||hATR==INVALID_HANDLE)return INIT_FAILED;
 Print("XAUUSD_FastScalper v1.03 READY | Lot=0.01 | Target=0.10 | Cooldown=2s");return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){
 if(hFast!=INVALID_HANDLE)IndicatorRelease(hFast);if(hSlow!=INVALID_HANDLE)IndicatorRelease(hSlow);
 if(hRSI!=INVALID_HANDLE)IndicatorRelease(hRSI);if(hATR!=INVALID_HANDLE)IndicatorRelease(hATR);
}
