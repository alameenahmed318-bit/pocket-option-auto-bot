#property strict
#include <Trade/Trade.mqh>
CTrade trade;
input string TradeSymbol = "Volatility 75 Index";
input double LotSize = 0.01;
input int MaxTrades = 2;
input double ProfitTargetUSD = 0.02;
input int CloseAfterSeconds = 2;
input int CooldownSeconds = 30;
input int EMAPeriodFast = 9;
input int EMAPeriodSlow = 21;
input int RSIPeriod = 14;
input double MaxSpreadPoints = 0;
input ulong MagicNumber = 75002026;
int hFast=INVALID_HANDLE,hSlow=INVALID_HANDLE,hRSI=INVALID_HANDLE;
datetime lastEntry=0;

int OnInit(){
 trade.SetExpertMagicNumber(MagicNumber);
 trade.SetDeviationInPoints(50);
 if(!SymbolSelect(TradeSymbol,true)) Print("WARNING: symbol not found: ",TradeSymbol);
 hFast=iMA(TradeSymbol,PERIOD_M1,EMAPeriodFast,0,MODE_EMA,PRICE_CLOSE);
 hSlow=iMA(TradeSymbol,PERIOD_M1,EMAPeriodSlow,0,MODE_EMA,PRICE_CLOSE);
 hRSI=iRSI(TradeSymbol,PERIOD_M1,RSIPeriod,PRICE_CLOSE);
 if(hFast==INVALID_HANDLE||hSlow==INVALID_HANDLE||hRSI==INVALID_HANDLE) return INIT_FAILED;
 Print("DERIV MT5 R75 EA READY | symbol=",TradeSymbol," | lot=",LotSize," | max_trades=",MaxTrades," | target=$",ProfitTargetUSD," | close_after=",CloseAfterSeconds,"s");
 return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){
 if(hFast!=INVALID_HANDLE) IndicatorRelease(hFast);
 if(hSlow!=INVALID_HANDLE) IndicatorRelease(hSlow);
 if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);
}
int CountOurPositions(){
 int n=0;
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
  if(PositionGetString(POSITION_SYMBOL)==TradeSymbol && (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber) n++;
 }
 return n;
}
void ManagePositions(){
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
  if(PositionGetString(POSITION_SYMBOL)!=TradeSymbol) continue;
  if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
  double profit=PositionGetDouble(POSITION_PROFIT);
  datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
  double age=(double)(TimeCurrent()-opened);
  if(profit>=ProfitTargetUSD){
   if(trade.PositionClose(ticket)) Print("CLOSED AT PROFIT TARGET | ticket=",ticket," | profit=",DoubleToString(profit,2));
   else Print("PROFIT CLOSE FAILED | retcode=",trade.ResultRetcode());
  } else if(age>=CloseAfterSeconds){
   if(trade.PositionClose(ticket)) Print("CLOSED BY TIMER | ticket=",ticket," | profit=",DoubleToString(profit,2));
   else Print("TIMER CLOSE FAILED | retcode=",trade.ResultRetcode());
  }
 }
}
bool SignalBuy(){
 double f[1],s[1],r[1];
 if(CopyBuffer(hFast,0,0,1,f)!=1||CopyBuffer(hSlow,0,0,1,s)!=1||CopyBuffer(hRSI,0,0,1,r)!=1) return false;
 MqlTick t; if(!SymbolInfoTick(TradeSymbol,t)) return false;
 double mid=(t.bid+t.ask)/2.0; if(mid<=0) return false;
 if(MaxSpreadPoints>0 && (t.ask-t.bid)/SymbolInfoDouble(TradeSymbol,SYMBOL_POINT)>MaxSpreadPoints) return false;
 double spread=MathAbs(f[0]-s[0])/mid;
 return spread<=0.006 && r[0]>=25.0 && r[0]<=75.0 && f[0]>=s[0];
}
void TryEntry(){
 if(CountOurPositions()>=MaxTrades || (TimeCurrent()-lastEntry)<CooldownSeconds || !SignalBuy()) return;
 if(trade.Buy(LotSize,TradeSymbol,0,0,0,"R75 MT5 bot")){
  lastEntry=TimeCurrent();
  Print("MT5 BUY OPENED | symbol=",TradeSymbol," | lot=",LotSize," | order=",trade.ResultOrder());
 } else Print("BUY FAILED | retcode=",trade.ResultRetcode()," | ",trade.ResultRetcodeDescription());
}
void OnTick(){ ManagePositions(); TryEntry(); }
