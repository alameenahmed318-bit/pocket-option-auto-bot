#property strict
#property version "1.0"

input double Lots = 0.01;
input double ProfitTarget = 0.10;
input double MaxLoss = 10.0;
input double TrailStart = 0.10;
input double Giveback = 0.05;
input int ScanSeconds = 2;
input int FastEMA = 9;
input int SlowEMA = 21;
input int RSIPeriod = 14;
input long Magic = 32432112;

int hFast = INVALID_HANDLE;
int hSlow = INVALID_HANDLE;
int hRSI  = INVALID_HANDLE;
datetime lastBar = 0;
double peakProfit = 0.0;

string GoldSymbol()
{
   if(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_DISABLED)
      return _Symbol;
   return _Symbol;
}

bool IsGold()
{
   string s=_Symbol;
   StringToUpper(s);
   return (StringFind(s,"XAU")>=0 || StringFind(s,"GOLD")>=0);
}

int OnInit()
{
   if(!IsGold())
   {
      Print("GOLD EA STOPPED: chart symbol is not Gold: ",_Symbol);
      return INIT_FAILED;
   }


   hFast=iMA(_Symbol,PERIOD_M1,FastEMA,0,MODE_EMA,PRICE_CLOSE);
   hSlow=iMA(_Symbol,PERIOD_M1,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hRSI=iRSI(_Symbol,PERIOD_M1,RSIPeriod,PRICE_CLOSE);

   if(hFast==INVALID_HANDLE || hSlow==INVALID_HANDLE || hRSI==INVALID_HANDLE)
      return INIT_FAILED;

   EventSetTimer(MathMax(1,ScanSeconds));
   Print("GOLD EA READY | symbol=",_Symbol,
         " | lot=",DoubleToString(Lots,2),
         " | target=",DoubleToString(ProfitTarget,2),
         " | maxloss=",DoubleToString(MaxLoss,2));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(hFast!=INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow!=INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);
}

bool ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;
   string symbol=PositionGetString(POSITION_SYMBOL);
   double volume=PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE ptype=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL;
   req.position=ticket;
   req.symbol=symbol;
   req.volume=volume;
   req.deviation=30;
   req.type=(ptype==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   req.price=(req.type==ORDER_TYPE_BUY)?SymbolInfoDouble(symbol,SYMBOL_ASK):SymbolInfoDouble(symbol,SYMBOL_BID);
   req.magic=Magic;
   return OrderSend(req,res) && (res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_DONE_PARTIAL);
}

bool OpenMarket(ENUM_ORDER_TYPE type,double volume,string comment)
{
   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.volume=volume;
   req.type=type;
   req.price=(type==ORDER_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   req.deviation=30;
   req.magic=Magic;
   req.comment=comment;
   return OrderSend(req,res) && (res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_DONE_PARTIAL);
}

bool OurPosition(ulong &ticket)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      ticket=t;
      return true;
   }
   return false;
}

void ProtectPosition()
{
   ulong ticket=0;
   if(!OurPosition(ticket))
   {
      peakProfit=0.0;
      return;
   }

   if(!PositionSelectByTicket(ticket)) return;

   double p=PositionGetDouble(POSITION_PROFIT);
   if(p>peakProfit) peakProfit=p;

   bool closeNow=false;
   string reason="";

   if(p>=ProfitTarget)
   {
      closeNow=true;
      reason="TARGET";
   }
   else if(p<=-MaxLoss)
   {
      closeNow=true;
      reason="MAX_LOSS";
   }
   else if(peakProfit>=TrailStart && p<=peakProfit-Giveback)
   {
      closeNow=true;
      reason="PROFIT_PROTECTION";
   }

   if(closeNow)
   {
      if(ClosePosition(ticket))
         Print("GOLD CLOSED | reason=",reason," | profit=",DoubleToString(p,2));
      else
         Print("GOLD CLOSE FAILED | reason=",reason);
      peakProfit=0.0;
   }
}

int Signal()
{
   double fast[3],slow[3],rsi[3];
   ArraySetAsSeries(fast,true);
   ArraySetAsSeries(slow,true);
   ArraySetAsSeries(rsi,true);

   if(CopyBuffer(hFast,0,0,3,fast)<3) return 0;
   if(CopyBuffer(hSlow,0,0,3,slow)<3) return 0;
   if(CopyBuffer(hRSI,0,0,3,rsi)<3) return 0;

   MqlRates rates[3];
   ArraySetAsSeries(rates,true);
   if(CopyRates(_Symbol,PERIOD_M1,0,3,rates)<3) return 0;

   if(slow[2]>=fast[2] && fast[1]>slow[1] &&
      rates[1].close>rates[1].open && rsi[1]>=52 && rsi[1]<=75)
      return 1;

   if(slow[2]<=fast[2] && fast[1]<slow[1] &&
      rates[1].close<rates[1].open && rsi[1]>=25 && rsi[1]<=48)
      return -1;

   return 0;
}

void OpenTrade()
{
   ulong ticket=0;
   if(OurPosition(ticket)) return;

   datetime bar=iTime(_Symbol,PERIOD_M1,1);
   if(bar==0 || bar==lastBar) return;
   lastBar=bar;

   int signal=Signal();
   if(signal==0) return;

   double volume=Lots;
   double minVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(step>0) volume=MathFloor(volume/step+1e-9)*step;
   volume=MathMax(minVol,MathMin(maxVol,volume));

   bool ok=false;
   if(signal>0) ok=OpenMarket(ORDER_TYPE_BUY,volume,"GOLD_FAST_BUY");
   else ok=OpenMarket(ORDER_TYPE_SELL,volume,"GOLD_FAST_SELL");

   if(ok)
      Print("GOLD OPENED | side=",signal>0?"BUY":"SELL",
            " | lot=",DoubleToString(volume,2),
            " | price=",DoubleToString(SymbolInfoDouble(_Symbol,signal>0?SYMBOL_ASK:SYMBOL_BID),_Digits));
   else
      Print("GOLD ORDER FAILED");
}

void OnTimer()
{
   ProtectPosition();
   OpenTrade();
}

void OnTick()
{
   ProtectPosition();
}
