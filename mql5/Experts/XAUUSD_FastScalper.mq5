//+------------------------------------------------------------------+
//| XAUUSD_FastScalper.mq5                                           |
//| GOLD ONLY - Etrink/MT5 compatible standalone EA                  |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"

#include <Trade/Trade.mqh>
CTrade trade;

input double LotSize            = 0.01;
input int    FastEMA            = 9;
input int    SlowEMA            = 21;
input int    RSIPeriod          = 7;
input double BuyRSIMin          = 50.5;
input double SellRSIMax         = 49.5;
input int    ATRPeriod          = 14;
input double SL_ATR_Mult        = 1.5;
input double Trail_ATR_Mult     = 0.8;
input double ProfitTargetMoney  = 0.10;
input double MaxLossMoney       = 10.0;
input int    MaxPositions       = 10;
input int    CooldownSeconds    = 2;
input ulong  MagicNumber        = 26100601;

int hFast = INVALID_HANDLE;
int hSlow = INVALID_HANDLE;
int hRSI  = INVALID_HANDLE;
int hATR  = INVALID_HANDLE;
datetime lastEntryTime = 0;

bool IsExactGold()
{
   return (_Symbol == "XAUUSD");
}

double NormalizeVolume(double volume)
{
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minVol <= 0 || maxVol <= 0 || step <= 0)
      return 0.0;

   volume = MathMax(minVol, MathMin(maxVol, volume));

   double steps = MathFloor((volume - minVol + 1e-12) / step);
   double result = minVol + steps * step;

   if(result < minVol) result = minVol;
   if(result > maxVol) result = maxVol;

   return NormalizeDouble(result, 8);
}

double NormalizePrice(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(tickSize > 0)
      price = MathRound(price / tickSize) * tickSize;

   return NormalizeDouble(price, digits);
}

bool ValidSL(ENUM_ORDER_TYPE type, double sl, double price)
{
   if(sl <= 0) return true;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(point <= 0 || stops <= 0) return true;

   double minDistance = stops * point;

   if(type == ORDER_TYPE_BUY)
      return ((price - sl) >= minDistance);

   return ((sl - price) >= minDistance);
}

int CountMyPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         count++;
      }
   }

   return count;
}

bool CloseMyPosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(PositionGetString(POSITION_SYMBOL));

   bool ok = trade.PositionClose(ticket, 30);

   if(!ok)
   {
      Print("CLOSE_ERROR | ticket=", ticket,
            " | retcode=", trade.ResultRetcode(),
            " | comment=", trade.ResultRetcodeDescription());
   }

   return ok;
}

bool ModifyMySL(ulong ticket, double newSL)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   string symbol = PositionGetString(POSITION_SYMBOL);
   double tp = PositionGetDouble(POSITION_TP);
   long type = PositionGetInteger(POSITION_TYPE);

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   long stops = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(point > 0 && stops > 0)
   {
      double minDistance = stops * point;

      if(type == POSITION_TYPE_BUY && (bid - newSL) < minDistance)
         return false;

      if(type == POSITION_TYPE_SELL && (newSL - ask) < minDistance)
         return false;
   }

   newSL = NormalizePrice(newSL);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(symbol);

   if(!trade.PositionModify(ticket, newSL, tp))
   {
      Print("SL_ERROR | ticket=", ticket,
            " | retcode=", trade.ResultRetcode(),
            " | comment=", trade.ResultRetcodeDescription());
      return false;
   }

   return true;
}

bool OpenTrade(ENUM_ORDER_TYPE type, double volume, double sl, string comment)
{
   volume = NormalizeVolume(volume);

   if(volume <= 0)
   {
      Print("TRADE_REJECT | invalid volume | requested=", LotSize);
      return false;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(_Symbol);

   sl = NormalizePrice(sl);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (type == ORDER_TYPE_BUY) ? ask : bid;

   if(!ValidSL(type, sl, price))
   {
      Print("SL_ADJUST | broker stop distance rejected requested SL; sending without initial SL");
      sl = 0.0;
   }

   bool ok = false;

   if(type == ORDER_TYPE_BUY)
      ok = trade.Buy(volume, _Symbol, 0.0, sl, 0.0, comment);
   else
      ok = trade.Sell(volume, _Symbol, 0.0, sl, 0.0, comment);

   Print("TRADE_RESULT | ok=", ok,
         " | retcode=", trade.ResultRetcode(),
         " | comment=", trade.ResultRetcodeDescription(),
         " | deal=", trade.ResultDeal(),
         " | order=", trade.ResultOrder(),
         " | volume=", volume);

   return ok;
}

void ManagePositions()
{
   double atr[];
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(hATR, 0, 0, 1, atr) < 1 || atr[0] <= 0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber ||
         PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      long type = PositionGetInteger(POSITION_TYPE);
      double oldSL = PositionGetDouble(POSITION_SL);

      if(profit >= ProfitTargetMoney)
      {
         CloseMyPosition(ticket);
         continue;
      }

      if(profit <= -MaxLossMoney)
      {
         CloseMyPosition(ticket);
         continue;
      }

      double newSL = oldSL;

      if(type == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double candidate = NormalizePrice(bid - atr[0] * Trail_ATR_Mult);

         if(candidate > 0 && candidate < bid &&
            (oldSL == 0 || candidate > oldSL))
         {
            newSL = candidate;
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double candidate = NormalizePrice(ask + atr[0] * Trail_ATR_Mult);

         if(candidate > ask &&
            (oldSL == 0 || candidate < oldSL))
         {
            newSL = candidate;
         }
      }

      if(newSL > 0 && newSL != oldSL)
         ModifyMySL(ticket, newSL);
   }
}

void OnTick()
{
   if(!IsExactGold())
      return;

   ManagePositions();

   if(CountMyPositions() >= MaxPositions)
      return;

   if((TimeCurrent() - lastEntryTime) < CooldownSeconds)
      return;

   double fast[], slow[], rsi[], atr[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(hFast, 0, 0, 2, fast) < 2 ||
      CopyBuffer(hSlow, 0, 0, 2, slow) < 2 ||
      CopyBuffer(hRSI, 0, 0, 2, rsi) < 2 ||
      CopyBuffer(hATR, 0, 0, 2, atr) < 2)
   {
      return;
   }

   if(atr[0] <= 0)
      return;

   bool buySignal  = (fast[0] > slow[0] && rsi[0] >= BuyRSIMin);
   bool sellSignal = (fast[0] < slow[0] && rsi[0] <= SellRSIMax);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double distance = atr[0] * SL_ATR_Mult;

   if(buySignal)
   {
      double sl = NormalizePrice(ask - distance);

      if(OpenTrade(ORDER_TYPE_BUY, LotSize, sl, "Etrink XAU Buy"))
         lastEntryTime = TimeCurrent();
   }
   else if(sellSignal)
   {
      double sl = NormalizePrice(bid + distance);

      if(OpenTrade(ORDER_TYPE_SELL, LotSize, sl, "Etrink XAU Sell"))
         lastEntryTime = TimeCurrent();
   }
}

int OnInit()
{
   if(!IsExactGold())
   {
      Print("INIT_FAILED | XAUUSD ONLY | current symbol=", _Symbol);
      return INIT_FAILED;
   }

   hFast = iMA(_Symbol, PERIOD_M1, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, PERIOD_M1, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI  = iRSI(_Symbol, PERIOD_M1, RSIPeriod, PRICE_CLOSE);
   hATR  = iATR(_Symbol, PERIOD_M1, ATRPeriod);

   if(hFast == INVALID_HANDLE ||
      hSlow == INVALID_HANDLE ||
      hRSI  == INVALID_HANDLE ||
      hATR  == INVALID_HANDLE)
   {
      Print("INIT_FAILED | indicator handle error | fast=", hFast,
            " slow=", hSlow,
            " rsi=", hRSI,
            " atr=", hATR);
      return INIT_FAILED;
   }

   Print("XAUUSD_FastScalper v2.00 READY | XAUUSD ONLY | M1 | Lot=0.01 | Target=0.10 | MaxLoss=10 | MaxPositions=10");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hRSI  != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
}
//+------------------------------------------------------------------+
