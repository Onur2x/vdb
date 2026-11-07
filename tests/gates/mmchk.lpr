program mmchk;

{ VDB - VDbMM ReallocMem sozlesme kapisi (R2-B-YENI-2)

  Kanitlananlar:
    1) ReallocMem(nil, 0) -> nil; P nil kalir.
    2) ReallocMem(nil, n) -> kullanilabilir blok; sonra Size=0 -> nil.
    3) Kucuk (slab) blok: buyutmede icerik korunur, kucultmede ayni
       isaretci doner.
    4) Buyuk (>512, orijinal yonetici) blok: buyutme/kucultme/sifir.
    5) Bozuk slab basligi: ReallocMem nil doner, P DEGISMEZ ve eski
       baytlar saglam kalir (Delphi "hata -> nil, eski blok gecerli"
       sozlesmesi).

  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: mmchk
}

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, VDbMM;

const
  TEST_SLAB_SIZE = 65536;
  TEST_SLAB_MAGIC = $5644424D;   // VDbMM.SLAB_MAGIC ('VDBM')

var
  gPass, gFail: Int64;

procedure Ok(const S: string);
begin
  Inc(gPass);
  WriteLn('   OK   ', S);
end;

procedure Fail(const S: string);
begin
  Inc(gFail);
  WriteLn('   FAIL ', S);
end;

function SlabBaseOf(P: Pointer): PByte; inline;
begin
  Result := PByte(PtrUInt(P) and not PtrUInt(TEST_SLAB_SIZE - 1));
end;

function PatternOk(P: Pointer; Len: Integer; Val: Byte): Boolean;
var
  i: Integer;
begin
  Result := P <> nil;
  if not Result then Exit;
  for i := 0 to Len - 1 do
    if PByte(PtrUInt(P) + PtrUInt(i))^ <> Val then Exit(False);
end;

procedure TestNilAndZero;
var
  P, R: Pointer;
begin
  WriteLn('1) nil / sifir sozlesmesi');
  P := nil;
  R := ReallocMem(P, 0);
  if (R = nil) and (P = nil) then
    Ok('ReallocMem(nil, 0) = nil')
  else
    Fail('ReallocMem(nil, 0) nil degil');

  P := nil;
  R := ReallocMem(P, 100);
  if (R <> nil) and (P = R) then
  begin
    FillChar(P^, 100, $11);
    Ok('ReallocMem(nil, 100) blok verdi');
  end
  else
    Fail('ReallocMem(nil, 100) blok vermedi');
  R := ReallocMem(P, 0);
  if (R = nil) and (P = nil) then
    Ok('ReallocMem(P, 0) = nil, P temizlendi')
  else
    Fail('ReallocMem(P, 0) sozlesmeye uymadi');
end;

procedure TestSmallSlab;
var
  P, R, Old: Pointer;
begin
  WriteLn('2) kucuk (slab) blok buyut/kucult');
  P := nil;
  P := ReallocMem(P, 40);
  if P = nil then
  begin
    Fail('kucuk tahsis basarisiz');
    Exit;
  end;
  FillChar(P^, 40, $5A);
  if PCardinal(SlabBaseOf(P))^ = TEST_SLAB_MAGIC then
    Ok('blok VDbMM slab icinde')
  else
    Fail('blok slab icinde degil (test varsayimi bozuk)');

  Old := P;
  R := ReallocMem(P, 300);   // 48 -> 320 sinifi: gercek buyutme
  if (R <> nil) and (P = R) and (R <> Old) then
    Ok('buyutme yeni blok verdi')
  else if (R <> nil) and (P = R) then
    Ok('buyutme basarili (ayni adres olabilir)')
  else
    Fail('buyutme basarisiz');
  if PatternOk(P, 40, $5A) then
    Ok('buyutmede eski 40 bayt korundu')
  else
    Fail('buyutmede eski icerik bozuldu');

  Old := P;
  R := ReallocMem(P, 20);    // kucultme: yerinde kalmali
  if (R = Old) and (P = Old) then
    Ok('kucultme ayni isaretciyi korudu')
  else
    Fail('kucultme isaretciyi degistirdi/reddetti');
  if PatternOk(P, 20, $5A) then
    Ok('kucultmeden sonra ilk 20 bayt saglam')
  else
    Fail('kucultmede icerik bozuldu');

  R := ReallocMem(P, 0);
  if (R = nil) and (P = nil) then
    Ok('kucuk blok Size=0 ile serbest')
  else
    Fail('kucuk blok Size=0 sozlesmesi bozuk');
end;

procedure TestLargeForeign;
var
  P, R: Pointer;
begin
  WriteLn('3) buyuk (>512) blok: orijinal yonetici yolu');
  P := nil;
  P := ReallocMem(P, 1000);
  if P = nil then
  begin
    Fail('buyuk tahsis basarisiz');
    Exit;
  end;
  FillChar(P^, 1000, $33);
  if PCardinal(SlabBaseOf(P))^ = TEST_SLAB_MAGIC then
    Fail('buyuk blok yanlislikla slab icinde');
  R := ReallocMem(P, 4000);
  if (R <> nil) and (P <> nil) then
    Ok('buyuk blok buyutuldu')
  else
    Fail('buyuk blok buyutulemedi');
  if PatternOk(P, 1000, $33) then
    Ok('buyuk buyutmede icerik korundu')
  else
    Fail('buyuk buyutmede icerik bozuldu');
  R := ReallocMem(P, 500);
  if (R <> nil) and (P <> nil) then
    Ok('buyuk blok kucultuldu')
  else
    Fail('buyuk blok kucultulemedi');
  if PatternOk(P, 500, $33) then
    Ok('buyuk kucultmede icerik korundu')
  else
    Fail('buyuk kucultmede icerik bozuldu');
  R := ReallocMem(P, 0);
  if (R = nil) and (P = nil) then
    Ok('buyuk blok Size=0 ile serbest')
  else
    Fail('buyuk blok Size=0 sozlesmesi bozuk');
end;

procedure TestCorruptHeader;
var
  P, OldP, R: Pointer;
  Base: PByte;
  SavedMagic: Cardinal;
begin
  WriteLn('4) bozuk slab basligi: hata -> nil, P korunur');
  P := nil;
  P := ReallocMem(P, 64);
  if P = nil then
  begin
    Fail('test blogu ayrilamadi');
    Exit;
  end;
  FillChar(P^, 64, $7E);
  Base := SlabBaseOf(P);
  if PCardinal(Base)^ <> TEST_SLAB_MAGIC then
  begin
    Fail('slab basligi beklenen sihirli sayiyi tasimiyor');
    Exit;
  end;
  SavedMagic := PCardinal(Base)^;
  PCardinal(Base)^ := 0;             // basligi boz
  OldP := P;
  try
    R := ReallocMem(P, 1024);        // bozuk: basarisiz olmali
    if R = nil then
      Ok('bozuk baslikta nil dondu')
    else
      Fail('bozuk baslikta nil yerine isaretci dondu');
    if P = OldP then
      Ok('bozuk baslikta P degismedi')
    else
      Fail('bozuk baslikta P degisti (eski blok kaybi)');
    if PatternOk(P, 64, $7E) then
      Ok('bozuk baslikta eski 64 bayt saglam')
    else
      Fail('bozuk baslikta eski blok bozuldu');
  finally
    PCardinal(Base)^ := SavedMagic;  // FreeMem calisabilsin
  end;
  R := ReallocMem(P, 0);
  if (R = nil) and (P = nil) then
    Ok('bozuk blogun sahibi temizlendi (magic geri yuklendi)')
  else
    Fail('bozuk blok temizlenemedi');
end;

begin
  Randomize;
  TestNilAndZero;
  TestSmallSlab;
  TestLargeForeign;
  TestCorruptHeader;
  WriteLn('===============================');
  WriteLn('SONUC: gecen=', gPass, ' kalan=', gFail);
  if gFail > 0 then
  begin
    WriteLn('MM SOZLESMESI BASARISIZ');
    Halt(1);
  end;
  WriteLn('MM SOZLESMESI DOGRULANDI');
end.
