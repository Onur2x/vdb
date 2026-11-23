program decimal_core;
{ SKILL14: VDbDecimal biriminin kendi testi (saf Pascal, harici bagimlilik
  yok). Bu kapi motorun SQL yolunu degil, ondalik aritmetigin KENDISINI
  dogrular: tamlik, yuvarlama, tasma, isaret ve kanonik metin.

  Her kontrol PASS/FAIL yazar; en sonda `SONUC: n PASS, m FAIL` basilir ve
  hata varsa cikis kodu 1 olur. }

{$mode objfpc}{$H+}

uses
  SysUtils, VDbDecimal;

var
  GPass, GFail: Integer;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' - ', ADetail);
  end;
end;

function P(const S: string; out D: TVdbDec): Boolean;
var
  e: string;
begin
  Result := VdbDecParse(S, D, e);
  if not Result then
    WriteLn('  (parse hatasi: ', S, ' -> ', e, ')');
end;

function S(const D: TVdbDec): string;
begin
  Result := VdbDecToStr(D);
end;

var
  A, B, R, T, F: TVdbDec;
  E: string;
  ok: Boolean;
  sum: TVdbDec;
  i: Integer;

begin
  GPass := 0;
  GFail := 0;

  { D1: klasik ikili kayan nokta hatasi. 0.1 + 0.2 TAM 0.3 olmali; Double
    ile 0.30000000000000004 cikardi. }
  ok := P('0.1', A) and P('0.2', B);
  ok := ok and VdbDecAdd(A, B, R);
  Chk('D1 0.1 + 0.2 = 0.3 (tam)', ok and (S(R) = '0.3'),
    'sonuc=' + S(R));

  { D2: 24 haneli tam sayi kayipsiz gidis-donus. }
  ok := P('999999999999999999999999', A);
  Chk('D2 24 haneli tam sayi kayipsiz', ok and
    (S(A) = '999999999999999999999999') and (VdbDecPrecision(A) = 24),
    'sonuc=' + S(A) + ' p=' + IntToStr(VdbDecPrecision(A)));

  { D3: cok kucuk deger, olcek 20. }
  ok := P('0.00000000000000000001', A);
  Chk('D3 cok kucuk deger (olcek 20)', ok and (S(A) = '0.00000000000000000001')
    and (A.Scale = 20) and (VdbDecPrecision(A) = 20),
    'sonuc=' + S(A) + ' scale=' + IntToStr(A.Scale));

  { D4: negatif aritmetik. -5.25 + 2.5 = -2.75 ; -2 - (-7) = 5 }
  ok := P('-5.25', A) and P('2.5', B) and VdbDecAdd(A, B, R);
  Chk('D4a negatif + pozitif = -2.75', ok and (S(R) = '-2.75'), 'sonuc=' + S(R));
  ok := P('-2', A) and P('-7', B) and VdbDecSub(A, B, R);
  Chk('D4b -2 - (-7) = 5', ok and (S(R) = '5'), 'sonuc=' + S(R));

  { D5: yarim yukari yuvarlama, sifirdan uzaga. }
  ok := P('2.345', A) and VdbDecRound(A, 2, R, E);
  Chk('D5a 2.345 -> 2.35', ok and (S(R) = '2.35'), 'sonuc=' + S(R) + ' ' + E);
  ok := P('2.344', A) and VdbDecRound(A, 2, R, E);
  Chk('D5b 2.344 -> 2.34', ok and (S(R) = '2.34'), 'sonuc=' + S(R));
  ok := P('-2.345', A) and VdbDecRound(A, 2, R, E);
  Chk('D5c -2.345 -> -2.35 (sifirdan uzak)', ok and (S(R) = '-2.35'),
    'sonuc=' + S(R));
  ok := P('2.5', A) and VdbDecRound(A, 0, R, E);
  Chk('D5d 2.5 -> 3 (yarim yukari)', ok and (S(R) = '3'), 'sonuc=' + S(R));

  { D6: olcek buyutme kanonik metin uretir. }
  ok := P('1.5', A) and VdbDecFit(A, 4, 3, R, E);
  Chk('D6 1.5 -> Decimal(4,3) = 1.500', ok and (S(R) = '1.500'),
    'sonuc=' + S(R) + ' ' + E);

  { D7: hassasiyet tasmasi HATA olmali, sessiz kirpma degil. }
  ok := P('999.99', A);
  Chk('D7 Decimal(4,2) 999.99 tasar',
    ok and (not VdbDecFit(A, 4, 2, R, E)) and (E <> ''), 'err=' + E);
  ok := P('99.99', A) and VdbDecFit(A, 4, 2, R, E);
  Chk('D7b Decimal(4,2) 99.99 sigar', ok and (S(R) = '99.99'),
    'err=' + E + ' sonuc=' + S(R));

  { D8: carpma ve olcek toplami. 1.005 * 2 = 2.010 }
  ok := P('1.005', A) and P('2', B) and VdbDecMul(A, B, R);
  Chk('D8 1.005 * 2 = 2.010', ok and (S(R) = '2.010') and (R.Scale = 3),
    'sonuc=' + S(R) + ' scale=' + IntToStr(R.Scale));

  { D9: bolme ve yuvarlama. 1/3 (6 hane) = 0.333333 ; 2/3 = 0.666667 }
  ok := P('1', A) and P('3', B) and VdbDecDiv(A, B, 6, R, E);
  Chk('D9a 1/3 olcek 6 = 0.333333', ok and (S(R) = '0.333333'),
    'sonuc=' + S(R) + ' ' + E);
  ok := P('2', A) and P('3', B) and VdbDecDiv(A, B, 6, R, E);
  Chk('D9b 2/3 olcek 6 = 0.666667 (yuvarlar)', ok and (S(R) = '0.666667'),
    'sonuc=' + S(R));

  { D10: sifira bolme hata. }
  ok := P('1', A) and P('0', B);
  Chk('D10 sifira bolme hata verir',
    ok and (not VdbDecDiv(A, B, 6, R, E)) and (E <> ''), 'err=' + E);

  { D11: karsilastirma olcekten bagimsiz. }
  ok := P('2.50', A) and P('2.5', B);
  Chk('D11a 2.50 = 2.5', ok and (VdbDecCmp(A, B) = 0),
    'cmp=' + IntToStr(VdbDecCmp(A, B)));
  ok := P('10', A) and P('9.99', B);
  Chk('D11b 10 > 9.99 (metin sirasi DEGIL)', ok and (VdbDecCmp(A, B) > 0),
    'cmp=' + IntToStr(VdbDecCmp(A, B)));
  ok := P('-10', A) and P('-9.99', B);
  Chk('D11c -10 < -9.99', ok and (VdbDecCmp(A, B) < 0),
    'cmp=' + IntToStr(VdbDecCmp(A, B)));
  ok := P('0.001', A) and P('0.0009', B);
  Chk('D11d 0.001 > 0.0009', ok and (VdbDecCmp(A, B) > 0),
    'cmp=' + IntToStr(VdbDecCmp(A, B)));

  { D12: buyuk carpma. 999999999999999999999999 * 3 }
  ok := P('999999999999999999999999', A) and P('3', B) and
    VdbDecMul(A, B, R);
  Chk('D12 24 hane * 3', ok and (S(R) = '2999999999999999999999997'),
    'sonuc=' + S(R));

  { D13: gecersiz girdiler reddedilir. }
  Chk('D13a bos deger reddedilir', not P('', A), 'bos kabul edildi');
  Chk('D13b "1.2.3" reddedilir', not P('1.2.3', A), 'kabul edildi');
  Chk('D13c "abc" reddedilir', not P('abc', A), 'kabul edildi');
  Chk('D13d "1e" reddedilir', not P('1e', A), 'kabul edildi');

  { D14: us gosterimi. 1.5e3 = 1500 ; 2.5e-3 = 0.0025 }
  ok := P('1.5e3', A);
  Chk('D14a 1.5e3 = 1500', ok and (S(A) = '1500'), 'sonuc=' + S(A));
  ok := P('2.5e-3', A);
  Chk('D14b 2.5e-3 = 0.0025', ok and (S(A) = '0.0025'), 'sonuc=' + S(A));

  { D15: kanonik gosterim, olcek korunur. }
  ok := P('7', A) and VdbDecFit(A, 5, 2, R, E);
  Chk('D15 7 -> Decimal(5,2) = 7.00', ok and (S(R) = '7.00'), 'sonuc=' + S(R));

  { D16: farkli olcekli toplama. 1.5 + 1.25 = 2.75 }
  ok := P('1.5', A) and P('1.25', B) and VdbDecAdd(A, B, R);
  Chk('D16 1.5 + 1.25 = 2.75', ok and (S(R) = '2.75'), 'sonuc=' + S(R));

  { D17: -0 tek gosterim, isaretsiz. Olcek korunur: '-0.00' -> '0.00'
    (D25 ile ayni kural; eski beklenti '0' idi ve sifir olcegini atan
    hatayi kodluyordu, interop kapisinda bulundu). }
  ok := P('-0.00', A);
  Chk('D17 -0 kanonik 0.00 olur', ok and (S(A) = '0.00') and (not A.Neg),
    'sonuc=' + S(A));

  { D18: precision tanimi. 0.001 -> 3 ; 12.34 -> 4 ; 123 -> 3 }
  ok := P('0.001', A);
  Chk('D18a 0.001 precision 3', ok and (VdbDecPrecision(A) = 3),
    'p=' + IntToStr(VdbDecPrecision(A)));
  ok := P('12.34', A);
  Chk('D18b 12.34 precision 4', ok and (VdbDecPrecision(A) = 4),
    'p=' + IntToStr(VdbDecPrecision(A)));
  ok := P('123', A);
  Chk('D18c 123 precision 3', ok and (VdbDecPrecision(A) = 3),
    'p=' + IntToStr(VdbDecPrecision(A)));

  { D19: SUM benzetimi - ayni olcekte 1000 deger toplami tam. }
  sum := VdbDecZero;
  ok := True;
  for i := 0 to 999 do
  begin
    if not P('0.01', A) then
    begin
      ok := False;
      Break;
    end;
    VdbDecAdd(sum, A, sum);
  end;
  Chk('D19 1000 x 0.01 = 10 tam', ok and (S(sum) = '10.00'),
    'sonuc=' + S(sum));

  { D20: %0,5 sinirinda cift yon. 1.25 -> 1.3 ; 1.35 -> 1.4 }
  ok := P('1.25', A) and VdbDecRound(A, 1, R, E);
  Chk('D20a 1.25 -> 1.3', ok and (S(R) = '1.3'), 'sonuc=' + S(R));
  ok := P('1.35', A) and VdbDecRound(A, 1, R, E);
  Chk('D20b 1.35 -> 1.4', ok and (S(R) = '1.4'), 'sonuc=' + S(R));

  { D21: Int64 donusumu ve en kucuk Int64. }
  A := VdbDecFromInt64(-9223372036854775808);
  Chk('D21 Int64 min kayipsiz', S(A) = '-9223372036854775808',
    'sonuc=' + S(A));

  { D22: Float'tan CAST sinirli ama calisir. }
  ok := VdbDecFromFloat(0.5, T, E);
  Chk('D22 0.5 float -> 0.5', ok and (S(T) = '0.5'),
    'sonuc=' + S(T) + ' ' + E);

  { D23/D24: Yazarken bulunan gercek hata - `out` cikis parametresi
    ayni degisken verildiginde girdiyi de siliyordu. Cikislar artik
    `var`; asagidaki iki cagri YERINDE calisir ve ayni sonucu vermeli. }
  ok := P('1.234', A) and VdbDecRound(A, 2, A, E);
  Chk('D23 yerinde yuvarlama (R = D)', ok and (S(A) = '1.23'),
    'sonuc=' + S(A) + ' ' + E);
  ok := P('1.5', A) and VdbDecMul(A, A, A);
  Chk('D24 yerinde carpma (R = A = B)', ok and (S(A) = '2.25'),
    'sonuc=' + S(A));

  { D25: Sifir da olcegi korumali. Bu hata gercek kapida bulundu: sifir
    degeri olcek atilinca '0.000' yerine '0' uretiliyor, kanonik metin
    bozuluyor ve metin anahtarli GROUP BY/DISTINCT ayni degeri iki farkli
    anahtar saniyordu. }
  A := VdbDecZero;
  A.Scale := 3;
  Chk('D25a sifir olcekli 0.000', S(A) = '0.000', 'sonuc=' + S(A));
  A := VdbDecZero;
  Chk('D25b olceksiz sifir 0', S(A) = '0', 'sonuc=' + S(A));
  A := VdbDecZero;
  A.Scale := 2;
  A.Neg := True;
  Chk('D25c negatif sifir isaretsiz (0.00)', S(A) = '0.00', 'sonuc=' + S(A));

  { D26: Sifir aritmetigi olcegi korumali. }
  ok := P('0.000', A) and P('0', B) and VdbDecAdd(A, B, R);
  Chk('D26 sifir + sifir olcek korunur', ok and (S(R) = '0.000'),
    'sonuc=' + S(R));

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then
    Halt(1);
end.
