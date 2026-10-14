unit VDbRange;

{ F-25: RANGE (ARALIK) TIPI.
  PostgreSQL'in range tipleri (int4range, numrange, tsrange, daterange) VDB'de
  TEXT kolonunda tutulan bir "kutu" olarak modellenir. Boylece dosya formatı,
  tablo semasi ve indeks kodu degismez; yeni yetenek tamamen sorgu katmaninda
  ve geriye donuk uyumlu gelir.

  Kanonik bicim:
    [alt,ust]      -> kapali aralik, iki ucte de DEGER VAR
    (alt,ust)      -> acik aralik,     iki ucte de deger YOK
    [alt,ust)      -> sol kapali, sag acik
    (alt,ust]      -> sol acik, sag kapali
    bos            -> 'empty' yazilir ('EMPTY' de kabul edilir)
                      NOT: Bos araligin kutu yazimi iki KOSELI parantezdir,
                      ama su an sadece 'empty' yazimi desteklenir; kutu
                      yazimi ayrica uygulanir.

  Uc degerli sinir belirteci: '*'  ->  '-infinity' / '+infinity' demektir.
    '[1,*)'  = 1 ve uzeri        '(*,10)' = -infinity .. 10 (ust haric)
    '[*,10)' = -infinity .. 10 (haric)

  BIRIM TIPI: aralik ogeleri sayisal (INTEGER/REAL), metin (TEXT) veya
  tarih/saat (DATE/TIMESTAMP) olabilir. Ayirici '..' her zaman sayisaldir;
  metin araliklarinda tek tirnak icinde yazilir: '[a..z)'.

  SONLU/BASLANGIC BOS: '[*,*)' her yonu sonsuz. Tamamen bos bir aralik
  'empty' ile temsil edilir ve hicbir operatorde eslesmez (digeriyle
  kesisimi yoktur, bir noktayla ic ice olmaz). }

{$mode delphi}

interface

uses
  SysUtils, Math, VDbTable;

type
  // Aralik uclarinin hangi tarafi kapali oldugunu tutan bayrak.
  TRangeBound = record
    Lo: string;        // alt sinir metni (bos = -infinity)
    Hi: string;        // ust sinir metni (bos = +infinity)
    LoIncl: Boolean;   // '[' -> True, '(' -> False
    HiIncl: Boolean;   // ']' -> True, ')' -> False
    Valid: Boolean;    // False => aralik bos ('{}')
  end;

function VDbParseRange(const S: string; out R: TRangeBound): Boolean;
function VDbRangeToText(const R: TRangeBound): string;
function VDbRangeIsEmpty(const R: TRangeBound): Boolean;
function VDbRangeHasLower(const R: TRangeBound): Boolean;
function VDbRangeHasUpper(const R: TRangeBound): Boolean;

// Tek bir deger, [Lo,Hi] araliginin icinde mi?
function VDbRangeContainsVal(const R: TRangeBound; const V: string): Boolean;
// Iki aralik kesisiyor mu?  (ortak bir nokta veya bos olmayan kesisim)
function VDbRangeOverlap(const A, B: TRangeBound): Boolean;
// A, B'nin icinde mi (tamamen kapsaniyor mu)?
function VDbRangeContains(const A, B: TRangeBound): Boolean;
// A, B'nin icinde mi? (PostgreSQL @>)
function VDbRangeContained(const A, B: TRangeBound): Boolean;
// A tam olarak B'den once mi?  A ve B kesismiyor olmali.
function VDbRangeBefore(const A, B: TRangeBound): Boolean;
// A tam olarak B'den sonra mi?
function VDbRangeAfter(const A, B: TRangeBound): Boolean;
// A, B'den baslayarak oteki tarafa kadar mi? (A once baslar, B daha once biter;
//   kesisim ZORUNLU)
function VDbRangeOverlapsLeft(const A, B: TRangeBound): Boolean;
function VDbRangeOverlapsRight(const A, B: TRangeBound): Boolean;
// Bitisiklik: kesisim YOK ama dokunuyorlar. A.Hi == B.Lo veya A.Lo == B.Hi.
function VDbRangeAdjacent(const A, B: TRangeBound): Boolean;
// Metin bir aralik DEGISI mi? ('[', '(' ile basliyor veya bos/empty)
function VDbIsRangeLit(const S: string): Boolean;

// Yardimci: iki degeri karsilastir (sayisal > metin > tarih).
function VDbRangeCmp(const A, B: string): Integer;
// RANGE(...) kurucu: 'RANGE(alt, ust [, acik])'
function VDbMakeRange(const Lo, Hi: string; LoIncl, HiIncl: Boolean): string;

implementation

{ ------------------------------------------------------------
  VDbRangeCmp
  Once sayisal denenir; degilse metin; degilse ISO tarih/saat.
  Bu sıralama 'tokala' (token) mantığıdır: aynı tipte iki deger
  karsılastırılır, tip uyusmazlığında sonuc belirsizdir.
  //---------------------------------------------------------- }
function VDbRangeCmp(const A, B: string): Integer;
var
  fa, fb: Double;
begin
  if (A = '') and (B = '') then Exit(0);
  // Bos sinirli taraf her zaman "daha kucuk"tür.
  if A = '' then Exit(-1);
  if B = '' then Exit(1);
  if VDbParseFloat(A, fa) and VDbParseFloat(B, fb) then
  begin
    if fa < fb then Exit(-1);
    if fa > fb then Exit(1);
    Exit(0);
  end;
  Result := CompareText(A, B);
  if Result < 0 then Result := -1
  else if Result > 0 then Result := 1;
end;

function VDbRangeIsEmpty(const R: TRangeBound): Boolean;
begin
  Result := not R.Valid;
end;

function VDbRangeHasLower(const R: TRangeBound): Boolean;
begin
  Result := R.Valid and (R.Lo <> '');
end;

function VDbRangeHasUpper(const R: TRangeBound): Boolean;
begin
  Result := R.Valid and (R.Hi <> '');
end;

{ ------------------------------------------------------------
  VDbParseRange
  Kabul edilen yazimlar:
    bos aralik: iki KOSELI parantez veya 'empty'
    '[a,b]' '[a,b)' '(a,b]' '(a,b)'     -> sayisal / tarih
    '[a..b]'                          -> kanonik sayisal bicim
    '[a,b]' (tirnakli degerler)        -> metin araligi
    '*' yerine bos birakmak da gecerli: '[1,)'
  Uclardaki tirnak isaretleri temizlenir.
  DIKKAT: bu yorumda KOSELI parantez KISAYOLU yazilmaz; ilk kapanis
  yorumu erken kapatir ve unit derlenmez.
  //---------------------------------------------------------- }
function VDbParseRange(const S: string; out R: TRangeBound): Boolean;
var
  t, lo, hi: string;
  i, sep, sepLen: Integer;
  loIncl, hiIncl, numericSep, inQuote: Boolean;
begin
  R.Lo := ''; R.Hi := ''; R.LoIncl := False; R.HiIncl := False; R.Valid := False;
  t := Trim(S);
  if t = '' then Exit(True);        // bos string = bos aralik
  // Bos aralik iki yazimla verilir: iki KOSELI parantez veya 'empty'.
  // DIKKAT: bu yorumda KOSELI parantez yazilmaz; ilk kapanis yorumu
  // erken kapatir.
  if (Length(t) = 2) and (t[1] = '{') and (t[2] = '}') then Exit(True);
  if SameText(t, 'empty') then Exit(True);
  if Length(t) < 3 then Exit(False);
  if not (t[1] in ['[', '(']) then Exit(False);
  if not (t[Length(t)] in [']', ')']) then Exit(False);
  loIncl := t[1] = '[';
  hiIncl := t[Length(t)] = ']';
  t := Copy(t, 2, Length(t) - 2);          // dis parantezler ve tirnak gitti
  if t = '' then Exit(False);

  // Ayirici: '..' (sayisal/tarih) ya da ',' (metin).
  // Tirnak icindeki karakterler ayirici sayilmaz.
  sep := 0;
  sepLen := 0;
  numericSep := False;
  inQuote := False;
  for i := 1 to Length(t) do
  begin
    if t[i] = '''' then inQuote := not inQuote
    else if not inQuote then
    begin
      if (sep = 0) and (t[i] = ',') then
      begin
        sep := i; sepLen := 1; numericSep := False;
      end
      else if (sep = 0) and (t[i] = '.') and (i < Length(t)) and
              (t[i + 1] = '.') then
      begin
        sep := i; sepLen := 2; numericSep := True;
      end;
    end;
  end;
  if sep = 0 then Exit(False);

  lo := Trim(Copy(t, 1, sep - 1));
  hi := Trim(Copy(t, sep + sepLen, MaxInt));
  // Tirnak temizligi
  if (Length(lo) >= 2) and (lo[1] = '''') and (lo[Length(lo)] = '''') then
    lo := Copy(lo, 2, Length(lo) - 2);
  if (Length(hi) >= 2) and (hi[1] = '''') and (hi[Length(hi)] = '''') then
    hi := Copy(hi, 2, Length(hi) - 2);
  // '..' ayiricili bicimde kalan tirnak degersiz
  if numericSep and (Pos('''', lo + hi) > 0) then Exit(False);
  // '*' = -/+ infinity
  if lo = '*' then lo := '';
  if hi = '*' then hi := '';
  // Mantiksal tutarlilik
  if (lo <> '') and (hi <> '') then
  begin
    if VDbRangeCmp(lo, hi) > 0 then Exit(False);         // alt > ust
    if (VDbRangeCmp(lo, hi) = 0) and not (loIncl and hiIncl) then
      Exit(False);                                      // acik bos aralik
  end;
  R.Lo := lo;
  R.Hi := hi;
  R.LoIncl := loIncl;
  R.HiIncl := hiIncl;
  R.Valid := True;
  Result := True;
end;

function VDbRangeToText(const R: TRangeBound): string;
var
  lo, hi: string;
begin
  if not R.Valid then Exit('{}');
  if R.Lo <> '' then lo := R.Lo else lo := '*';
  if R.Hi <> '' then hi := R.Hi else hi := '*';
  if R.LoIncl then Result := '[' else Result := '(';
  Result := Result + lo + '..';
  if R.HiIncl then Result := Result + ']' else Result := Result + ')';
  Result := Result + hi;
end;

function VDbMakeRange(const Lo, Hi: string; LoIncl, HiIncl: Boolean): string;
var
  R: TRangeBound;
begin
  R.Lo := Lo; R.Hi := Hi; R.LoIncl := LoIncl; R.HiIncl := HiIncl;
  R.Valid := True;
  Result := VDbRangeToText(R);
end;

function VDbRangeContainsVal(const R: TRangeBound; const V: string): Boolean;
var
  c: Integer;
begin
  Result := False;
  if not R.Valid then Exit;
  if V = '' then Exit;                 // NULL hicbir araliga uymaz
  // Alt sinir
  if R.Lo <> '' then
  begin
    c := VDbRangeCmp(V, R.Lo);
    if c < 0 then Exit;
    if (c = 0) and not R.LoIncl then Exit;
  end;
  // Ust sinir
  if R.Hi <> '' then
  begin
    c := VDbRangeCmp(V, R.Hi);
    if c > 0 then Exit;
    if (c = 0) and not R.HiIncl then Exit;
  end;
  Result := True;
end;

{ ------------------------------------------------------------
  VDbRangeOverlap
  Kesisim alt siniri = max(A.Lo, B.Lo), ust siniri = min(A.Hi, B.Hi).
  Kritik nokta: bu tek DEGER icin iki araligin KAPALILIK bayraklari
  birlestirilemez. (1,5] ile [5,10) kesisimi: kesisim tek deger olan 5.
  Alt siniri 5 olan taraf B'dir ve B.Lo kapali (5'i icerir); ama 5'i A da
  icerir (A'nin UST siniri kapali). Kaba "LoIncl and HiIncl" kurali
  burada hatali sonuc verir. Dogru kural: **kesisim tek noktadaysa o
  degeri HER IKI aralik da icermelidir**; VDbRangeContainsVal bunu zaten
  dogru hesapliyor.
  //---------------------------------------------------------- }
function VDbRangeOverlap(const A, B: TRangeBound): Boolean;
var
  lo, hi: string;
  c: Integer;
begin
  Result := False;
  if (not A.Valid) or (not B.Valid) then Exit;   // bos aralik kesismez

  // Alt sinir: daha buyuk olan ('' = -infinity, her zaman kucerktir)
  if A.Lo = '' then lo := B.Lo
  else if B.Lo = '' then lo := A.Lo
  else
  begin
    c := VDbRangeCmp(A.Lo, B.Lo);
    if c >= 0 then lo := A.Lo else lo := B.Lo;
  end;

  // Ust sinir: daha kucuk olan ('' = +infinity, her zaman buyuktur)
  if A.Hi = '' then hi := B.Hi
  else if B.Hi = '' then hi := A.Hi
  else
  begin
    c := VDbRangeCmp(A.Hi, B.Hi);
    if c <= 0 then hi := A.Hi else hi := B.Hi;
  end;

  if (lo = '') or (hi = '') then Exit(True);     // bir yon sonsuz
  c := VDbRangeCmp(lo, hi);
  if c < 0 then Exit(True);                      // bos olmayan aralik
  if c > 0 then Exit(False);                     // ters -> kesismez
  // Tek nokta: her iki aralik de o degeri icermeli
  Result := VDbRangeContainsVal(A, lo) and VDbRangeContainsVal(B, lo);
end;

{ ------------------------------------------------------------
  VDbRangeContains
  A, B'yi tamamen kapsiyor mu?
  o aralik HER seyi kapsar. Matematiksel gerekce: bos bir kume her alt
  kumesini de icerir. Buna karsilik '&&', '<<', '>>', '-|-' operatorleri
  bos araligi FALSE dondurur (PostgreSQL ile ayni).
  //---------------------------------------------------------- }
function VDbRangeContains(const A, B: TRangeBound): Boolean;
var
  c: Integer;
begin
  Result := False;
  if not A.Valid then Exit(True);       // bos aralik her seyi kapsar
  if not B.Valid then Exit(True);       // bos her araligin icindedir
  // Alt: A.Low <= B.Low ve esitlikte A.LowIncl
  if (A.Lo <> '') and (B.Lo <> '') then
  begin
    c := VDbRangeCmp(A.Lo, B.Lo);
    if c > 0 then Exit;
    if (c = 0) and (B.LoIncl and not A.LoIncl) then Exit;
  end
  else if (A.Lo = '') and (B.Lo <> '') then Exit;   // A -inf ile baslar, B degil
  // Ust: A.High >= B.High ve esitlikte A.HighIncl
  if (A.Hi <> '') and (B.Hi <> '') then
  begin
    c := VDbRangeCmp(A.Hi, B.Hi);
    if c < 0 then Exit;
    if (c = 0) and (B.HiIncl and not A.HiIncl) then Exit;
  end
  else if (A.Hi = '') and (B.Hi <> '') then Exit;
  Result := True;
end;

function VDbRangeContained(const A, B: TRangeBound): Boolean;
begin
  Result := VDbRangeContains(B, A);   // @>  =  <@  (ters cevrim)
end;

{ ------------------------------------------------------------
  VDbRangeBefore / VDbRangeAfter
  Kesisim ZORUNLU DEGIL. Dokunma (uc nokta birebir) durumunda denge
  kurali: "once/sonra" diyen aralik dokunma DEGERINI ICERMEMELIDIR.
    A << B :  A.Hi < B.Lo  VEYA  (A.Hi = B.Lo ve A.Hi ACIK)
    A >> B :  A.Lo > B.Hi  VEYA  (A.Lo = B.Hi ve A.Lo ACIK)
  Ornegin A = [5,10], B = [1,5): deger 5'te dokunuluyor. A 5'i icerir,
  B icermez -> A "sonra" sayilmaz; B "once" sayilmaz; ikisi de kesisir
  degil ama hicbir operator de once/sonra donmez.
  A = [5,10], B = [1,5]: 5'i A icerir, B de icerir -> kesisirler.
  A = [5,10], B = [1,5]: A 5'i icermez, B icerir -> A "sonra" olur.
  //---------------------------------------------------------- }
function VDbRangeBefore(const A, B: TRangeBound): Boolean;
var
  c: Integer;
begin
  Result := False;
  if (not A.Valid) or (not B.Valid) then Exit;
  if B.Lo = '' then Exit;              // B -inf ile basliyorsa once olamaz
  if A.Hi = '' then Exit;              // A +inf ise hicbir zaman once degil
  c := VDbRangeCmp(A.Hi, B.Lo);
  if c < 0 then Exit(True);
  Result := (c = 0) and (not A.HiIncl);
end;

function VDbRangeAfter(const A, B: TRangeBound): Boolean;
var
  c: Integer;
begin
  Result := False;
  if (not A.Valid) or (not B.Valid) then Exit;
  if A.Lo = '' then Exit;
  if B.Hi = '' then Exit;
  c := VDbRangeCmp(A.Lo, B.Hi);
  if c > 0 then Exit(True);
  // Dokunma: A "sonra" sayilmasi icin o degeri ICERMEMELI.
  Result := (c = 0) and (not A.LoIncl);
end;

{ ------------------------------------------------------------
  VDbRangeOverlapsLeft / Right  (&<  /  &>)
  "&<": A, B ile kesisir; A, B'den once baslar; B, A'dan once biter.
  "&>": simetrik.
  //---------------------------------------------------------- }
{ ------------------------------------------------------------
  VDbRangeOverlapsLeft / Right  (&<  /  &>)
  PostgreSQL "&<" = "does not extend to the right of": A, B'nin soluna
  UZANMAZ. Yani A ve B kesisir, A once baslar ve A, B'nin ust sinirini
  GECMEZ:
    A &< B :  A && B  ve  lower(A) < lower(B)  ve  upper(A) <= upper(B)
    A &> B :  A && B  ve  upper(A) > upper(B)  ve  lower(A) >= lower(B)
  Ornek: [1,8] &< [5,10] -> kesisir, 1<5, 8<=10 -> TRUE.
          [5,10] &< [1,8]  -> 5<1 yanlis -> FALSE.
  DIKKAT: bu, "<< once" DEN FARKLIDIR; << kesisim istemez.
  //---------------------------------------------------------- }
function VDbRangeOverlapsLeft(const A, B: TRangeBound): Boolean;
var
  cLo, cHi: Integer;
begin
  Result := False;
  if (not A.Valid) or (not B.Valid) then Exit;
  if not VDbRangeOverlap(A, B) then Exit;
  if (A.Lo = '') or (B.Lo = '') then Exit;   // -inf kenar durumu: belirsiz
  cLo := VDbRangeCmp(A.Lo, B.Lo);
  if cLo >= 0 then Exit;                       // A once baslamali
  if (A.Hi <> '') and (B.Hi <> '') then
  begin
    cHi := VDbRangeCmp(A.Hi, B.Hi);
    if cHi > 0 then Exit;                      // A B'nin ustunu gecmemeli
  end;
  Result := True;
end;

function VDbRangeOverlapsRight(const A, B: TRangeBound): Boolean;
var
  cLo, cHi: Integer;
begin
  Result := False;
  if (not A.Valid) or (not B.Valid) then Exit;
  if not VDbRangeOverlap(A, B) then Exit;
  if (A.Hi = '') or (B.Hi = '') then Exit;
  cHi := VDbRangeCmp(A.Hi, B.Hi);
  if cHi <= 0 then Exit;                       // A daha yuksek bitmeli
  if (A.Lo <> '') and (B.Lo <> '') then
  begin
    cLo := VDbRangeCmp(A.Lo, B.Lo);
    if cLo < 0 then Exit;                      // A daha dusuk baslamali
  end;
  Result := True;
end;

{ ------------------------------------------------------------
  VDbRangeAdjacent  (-|-)
  Kesisim YOK olmali, ama bir araligin ucu digerinin basina degmeli.
  Yani A.Hi == B.Lo veya A.Lo == B.Hi.
  //---------------------------------------------------------- }
function VDbRangeAdjacent(const A, B: TRangeBound): Boolean;
begin
  Result := False;
  if (not A.Valid) or (not B.Valid) then Exit;
  if VDbRangeOverlap(A, B) then Exit;   // kesisiyorlarsa bitisik degiller
  if (A.Hi <> '') and (B.Lo <> '') then
    if VDbRangeCmp(A.Hi, B.Lo) = 0 then Exit(True);
  if (A.Lo <> '') and (B.Hi <> '') then
    if VDbRangeCmp(A.Lo, B.Hi) = 0 then Exit(True);
end;

function VDbIsRangeLit(const S: string): Boolean;
var
  t: string;
begin
  t := Trim(S);
  if t = '' then Exit(True);                     // NULL/bos -> aralik gibi ele al
  // Bos aralik iki yazimla verilir: iki KOSELI parantez veya 'empty'
  if (Length(t) = 2) and (t[1] = '{') and (t[2] = '}') then Exit(True);
  if SameText(t, 'empty') then Exit(True);
  Result := (t[1] = '[') or (t[1] = '(');
end;

end.
