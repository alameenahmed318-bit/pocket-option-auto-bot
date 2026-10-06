//+------------------------------------------------------------------+
//| XAUUSD_FastScalper.mq5                                           |
//| GOLD ONLY - Fast Scalper                                         |
//+------------------------------------------------------------------+
#property strict
#property version "1.01"

#include <Trade/Trade.mqh>
CTrade trade;

input double LotSize           = 0.01;
input int    FastEMA           = 9;
input int    SlowEMA           = 21;
input int    RSIPeriod         = 7;
input double BuyRSIMin         = 52.0;
input double SellRSIMax        = 48.0;
input int    ATRPeriod         = 14;
input double SL_ATR_Mult       = 1.8;
input double Trail_ATR_Mult    = 1.2;
input double ProfitTargetMoney = 0.10;
input double MaxLossMoney      = 10.0;
input int    MaxPositions      = 5;
input int    CooldownSeconds   = 10;
input ulong  MagicNumber       = 26100601;

int hFast, hSlow, hRSI, hATR;
datetime lastEntryTime = 0;

bool IsGoldSymbol()
{
   string s = _Symbol;
   StringToUpper(s);
   return (StringFind(s,"XAU") >= 0 || StringFind(s,"GOLD") >= 0);
}

int CountMyPositions()
{
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         count++;
   }
   return count;
}

void ManagePositions()
{
   double atr[];
   ArraySetAsSeries(atr,true);
   if(CopyBuffer(hATR,0,0,1,atr) < 1) return;
   if(atr[0] <= 0) return;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      long type     = PositionGetInteger(POSITION_TYPE);
      double sl     = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);

      if(profit >= ProfitTargetMoney)
      {
         trade.PositionClose(ticket);
         continue;
      }

      if(profit <= -MaxLossMoney)
      {
         trade.PositionClose(ticket);
         continue;
      }

      int digits = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
      double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double newSL = sl;

      if(type == POSITION_TYPE_BUY)
      {
         double candidate = NormalizeDouble(bid - atr[0] * Trail_ATR_Mult,digits);
         if(candidate > 0 && candidate < bid && (sl == 0 || candidate > sl))
            newSL = candidate;
      }

      if(type == POSITION_TYPE_SELL)
      {
         double candidate = NormalizeDouble(ask + atr[0] * Trail_ATR_Mult,digits);
         if(candidate > ask && (sl == 0 || candidate < sl))
            newSL = candidate;
      }

      if(newSL != sl && newSL > 0)
         trade.PositionModify(ticket,newSL,tp);
   }
}

void OnTick()
{
   if(!IsGoldSymbol()) return;

   ManagePositions();

   if(CountMyPositions() >= MaxPositions) return;
   if((TimeCurrent() - lastEntryTime) < CooldownSeconds) return;

   double fast[], slow[], rsi[], atr[];
   ArraySetAsSeries(fast,true);
   ArraySetAsSeries(slow,true);
   ArraySetAsSeries(rsi,true);
   ArraySetAsSeries(atr,true);

   if(CopyBuffer(hFast,0,0,2,fast) < 2) return;
   if(CopyBuffer(hSlow,0,0,2,slow) < 2) return;
   if(CopyBuffer(hRSI,0,0,2,rsi) < 2) return;
   if(CopyBuffer(hATR,0,0,2,atr) < 2) return;
   if(atr[0] <= 0) return;

   bool buySignal  = fast[0] > slow[0] && rsi[0] >= BuyRSIMin;
   bool sellSignal = fast[0] < slow[0] && rsi[0] <= SellRSIMax;

   int digits = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double slDistance = atr[0] * SL_ATR_Mult;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);

   if(buySignal)
   {
      double sl = NormalizeDouble(ask - slDistance,digits);
      if(trade.Buy(LotSize,_Symbol,0,sl,0,"XAU Fast Buy"))
         lastEntryTime = TimeCurrent();
   }
   else if(sellSignal)
   {
      double sl = NormalizeDouble(bid + slDistance,digits);
      if(trade.Sell(LotSize,_Symbol,0,sl,0,"XAU Fast Sell"))
         lastEntryTime = TimeCurrent();
   }
}

int OnInit()
{
   if(!IsGoldSymbol())
   {
      Print("XAUUSD_FastScalper: GOLD ONLY");
      return INIT_FAILED;
   }

   hFast = iMA(_Symbol,PERIOD_M1,FastEMA,0,MODE_EMA,PRICE_CLOSE);
   hSlow = iMA(_Symbol,PERIOD_M1,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hRSI  = iRSI(_Symbol,PERIOD_M1,RSIPeriod,PRICE_CLOSE);
   hATR  = iATR(_Symbol,PERIOD_M1,ATRPeriod);

   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE ||
      hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE)
      return INIT_FAILED;

   Print("XAUUSD_FastScalper READY | Lot=0.01");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hRSI != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
}
