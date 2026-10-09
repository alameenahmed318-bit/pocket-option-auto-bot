//+------------------------------------------------------------------+
//|                              Sniper_ZOL_M1_Scalper.mq5           |
//|                              AL ZOL - Gold M1 Scalper            |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, AL ZOL"
#property link      "https://mql5.com"
#property version   "5.10"
#property strict

input group "--- Risk & Lot Size Settings ---"
input double InpLotSize=0.01;
input double InpRewardRisk=0.4;
input double InpStopMultiplier=1.5;
input ulong InpMagicNumber=884422;

input group "--- M1 Breakout & Sniper Filters ---"
input int InpBreakLookback=5;
input int InpFastEMA=50;
input int InpSlowEMA=200;
input int InpMomentumPeriod=7;
input double InpBuyThreshold=100.10;
input double InpSellThreshold=99.90;

input group "--- Smart Protections & Cooldown ---"
input int InpMaxSpreadPoints=80;
input int InpMinATRPoints=30;
input int InpCooldownSeconds=5;
input int InpMaxHoldingBars=8;
input bool InpEnableBreakEven=true;
input double InpBreakEvenAtR=0.2;

int fastEmaHandle=INVALID_HANDLE, slowEmaHandle=INVALID_HANDLE;
int momHandle=INVALID_HANDLE, atrHandle=INVALID_HANDLE;
datetime lastTradeTime=0;

bool GoodRetcode(uint code)
{
   return code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL ||
          code==TRADE_RETCODE_PLACED;
}
double NPrice(double p)
{
   return NormalizeDouble(p,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
}
double NVolume(double requested)
{
   double minv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) return 0;
   double v=MathMax(minv,MathMin(maxv,requested));
   v=MathFloor(v/step+1e-8)*step;
   v=NormalizeDouble(v,2);
   if(v<minv || v>maxv) return 0;
   return v;
}
bool FindPosition(ulong &ticket,ENUM_POSITION_TYPE &type,datetime &opened,
                  double &price,double &sl,double &tp,double &vol)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      ticket=t;
      type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      opened=(datetime)PositionGetInteger(POSITION_TIME);
      price=PositionGetDouble(POSITION_PRICE_OPEN);
      sl=PositionGetDouble(POSITION_SL);
      tp=PositionGetDouble(POSITION_TP);
      vol=PositionGetDouble(POSITION_VOLUME);
      return true;
   }
   return false;
}
ENUM_ORDER_TYPE_FILLING FillingMode()
{
   long mode=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((mode & SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}
bool CloseOurPosition(ulong ticket,ENUM_POSITION_TYPE type,double volume)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;
   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL;
   req.position=ticket;
   req.symbol=_Symbol;
   req.volume=volume;
   req.magic=InpMagicNumber;
   req.deviation=10;
   req.type_filling=FillingMode();
   req.type=(type==POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
   req.price=(type==POSITION_TYPE_BUY ? tick.bid : tick.ask);
   req.comment="Sniper-ZOL time exit";
   if(!OrderSend(req,res) || !GoodRetcode(res.retcode))
   {
      Print("Close failed: ",res.retcode," ",res.comment);
      return false;
   }
   return true;
}
bool SetStops(ulong ticket,double sl,double tp)
{
   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_SLTP;
   req.position=ticket;
   req.symbol=_Symbol;
   req.sl=NPrice(sl);
   req.tp=(tp>0 ? NPrice(tp) : 0);
   if(!OrderSend(req,res) || !GoodRetcode(res.retcode))
   {
      Print("Stop update failed: ",res.retcode," ",res.comment);
      return false;
   }
   return true;
}
int OnInit()
{
   if(InpLotSize<=0 || InpRewardRisk<=0 || InpStopMultiplier<=0 ||
      InpBreakLookback<1 || InpFastEMA<1 || InpSlowEMA<1 ||
      InpMomentumPeriod<1 || InpMaxHoldingBars<1 || InpCooldownSeconds<0 ||
      InpMaxSpreadPoints<0 || InpMinATRPoints<0 || InpBreakEvenAtR<0)
      return INIT_PARAMETERS_INCORRECT;

   fastEmaHandle=iMA(_Symbol,PERIOD_M1,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
   slowEmaHandle=iMA(_Symbol,PERIOD_M1,InpSlowEMA,0,MODE_EMA,PRICE_CLOSE);
   momHandle=iMomentum(_Symbol,PERIOD_M1,InpMomentumPeriod,PRICE_CLOSE);
   atrHandle=iATR(_Symbol,PERIOD_M1,14);
   if(fastEmaHandle==INVALID_HANDLE || slowEmaHandle==INVALID_HANDLE ||
      momHandle==INVALID_HANDLE || atrHandle==INVALID_HANDLE)
   {
      Print("Failed to create indicator handles. Error ",GetLastError());
      return INIT_FAILED;
   }
   Print("Sniper ZOL initialized on ",_Symbol,". Use an XAUUSD/GOLD M1 chart.");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   if(fastEmaHandle!=INVALID_HANDLE) IndicatorRelease(fastEmaHandle);
   if(slowEmaHandle!=INVALID_HANDLE) IndicatorRelease(slowEmaHandle);
   if(momHandle!=INVALID_HANDLE) IndicatorRelease(momHandle);
   if(atrHandle!=INVALID_HANDLE) IndicatorRelease(atrHandle);
}
void OnTick()
{
   string sym=_Symbol;
   StringToUpper(sym);
   if(StringFind(sym,"XAU")<0 && StringFind(sym,"GOLD")<0) return;

   ulong ticket=0;
   ENUM_POSITION_TYPE ptype=POSITION_TYPE_BUY;
   datetime opened=0;
   double openPrice=0,sl=0,tp=0,vol=0;
   if(FindPosition(ticket,ptype,opened,openPrice,sl,tp,vol))
   {
      if(TimeCurrent()-opened >= (long)InpMaxHoldingBars*60)
      {
         CloseOurPosition(ticket,ptype,vol);
         return;
      }
      if(InpEnableBreakEven && tp>0)
      {
         MqlTick tick;
         if(!SymbolInfoTick(_Symbol,tick)) return;
         if(ptype==POSITION_TYPE_BUY && sl<openPrice)
         {
            double trigger=openPrice+(tp-openPrice)*InpBreakEvenAtR;
            double newSL=openPrice+5*_Point;
            if(tick.bid>=trigger && newSL>sl && newSL<tick.bid)
               SetStops(ticket,newSL,tp);
         }
         else if(ptype==POSITION_TYPE_SELL && (sl==0 || sl>openPrice))
         {
            double trigger=openPrice-(openPrice-tp)*InpBreakEvenAtR;
            double newSL=openPrice-5*_Point;
            if(tick.ask<=trigger && (sl==0 || newSL<sl) && newSL>tick.ask)
               SetStops(ticket,newSL,tp);
         }
      }
      return; // one position per symbol and magic number
   }

   if(TimeCurrent()-lastTradeTime<InpCooldownSeconds) return;
   if(SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)>InpMaxSpreadPoints) return;
   if(Bars(_Symbol,PERIOD_M1)<MathMax(InpSlowEMA,InpBreakLookback)+5) return;

   double fast[2],slow[2],mom[2],atr[2];
   ArraySetAsSeries(fast,true); ArraySetAsSeries(slow,true);
   ArraySetAsSeries(mom,true); ArraySetAsSeries(atr,true);
   if(CopyBuffer(fastEmaHandle,0,0,2,fast)!=2 ||
      CopyBuffer(slowEmaHandle,0,0,2,slow)!=2 ||
      CopyBuffer(momHandle,0,0,2,mom)!=2 ||
      CopyBuffer(atrHandle,0,0,2,atr)!=2) return;
   if(atr[0]<=0 || atr[0]/_Point<InpMinATRPoints) return;

   int hi=iHighest(_Symbol,PERIOD_M1,MODE_HIGH,InpBreakLookback,1);
   int lo=iLowest(_Symbol,PERIOD_M1,MODE_LOW,InpBreakLookback,1);
   if(hi<0 || lo<0) return;
   double highest=iHigh(_Symbol,PERIOD_M1,hi);
   double lowest=iLow(_Symbol,PERIOD_M1,lo);
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;

   bool buy=(tick.ask>highest && fast[0]>slow[0] && mom[0]>InpBuyThreshold);
   bool sell=(tick.bid<lowest && fast[0]<slow[0] && mom[0]<InpSellThreshold);
   if(!buy && !sell) return;

   double volume=NVolume(InpLotSize);
   if(volume<=0) { Print("Invalid lot size for symbol: ",InpLotSize); return; }
   long stopsLevel=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double distance=MathMax(atr[0]*InpStopMultiplier,(stopsLevel+2)*_Point);

   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.volume=volume;
   req.magic=InpMagicNumber;
   req.deviation=10;
   req.type_filling=FillingMode();
   if(buy)
   {
      req.type=ORDER_TYPE_BUY;
      req.price=tick.ask;
      req.sl=NPrice(tick.ask-distance);
      req.tp=NPrice(tick.ask+distance*InpRewardRisk);
      req.comment="Sniper-ZOL M1 Buy";
   }
   else
   {
      req.type=ORDER_TYPE_SELL;
      req.price=tick.bid;
      req.sl=NPrice(tick.bid+distance);
      req.tp=NPrice(tick.bid-distance*InpRewardRisk);
      req.comment="Sniper-ZOL M1 Sell";
   }
   if(!OrderSend(req,res) || !GoodRetcode(res.retcode))
   {
      Print("Order failed: ",res.retcode," ",res.comment," error=",GetLastError());
      return;
   }
   lastTradeTime=TimeCurrent();
   Print("Order accepted: ",req.comment," volume=",DoubleToString(volume,2),
         " SL=",DoubleToString(req.sl,_Digits)," TP=",DoubleToString(req.tp,_Digits));
}
//+------------------------------------------------------------------+
