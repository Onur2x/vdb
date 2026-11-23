unit VDbDecimal;
{ SKILL14: tam hassasiyetli ondalik (DECIMAL/NUMERIC) - saf Pascal,
  harici bagimlilik yok.

  NEDEN AYRI BIRIM: DECIMAL degeri ASLA `Double` uzerinden gecmez. Ikili
  kayan nokta 0.1'i tam temsil edemez; bu yuzden 0.1 + 0.2 ikili sistemde
  0.30000000000000004 verir. Buradaki model isaret + rakam dizisi + olcek
  (scale) uzerinden CALISIR; hicbir adimda kayan noktaya donusum yoktur.

  MODEL:
    D.Neg    : isaret (yalnizca sifir olmayan degerlerde True)
    D.Digits : yalnizca '0'..'9'; bas sifirlar temizlenmis, sifir icin '0'
    D.Scale  : ondalik hane sayisi (>= 0). Deger = Digits / 10^Scale

  Kanonik gosterim `VdbDecToStr` ile uretilir: isaret + tam kisim + '.' +
  tam Scale hane. Ayni deger HER ZAMAN ayni dizgeyi verir (olcek sabitse);
  bu yuzden metin anahtarli yollar (GROUP BY / DISTINCT) dogru kalir.

  YUVARLAMA: yarim yukari (half-up), yani tam .5'te SIFIRDAN UZAGA.
  2.345 -> 2.35, -2.345 -> -2.35. Kesme (truncate) YOKTUR.

  HASSASIYET: precision = max(Length(Digits), Scale). 0.001 -> 3,
  12.34 -> 4, 123 -> 3. Sinir `VDB_DEC_MAX_PREC` (38); asilirsa hata.

  TASMA: `VdbDecFit` olcek tasmasini yuvarlar (veri kaybi degil, tanimli
  yuvarlama), hassasiyet tasmasini HATA olarak dondurur. Sessiz kirpma
  hicbir yerde yoktur.

  DURUST SINIR: bu bir yazilim ondalik kutuphanesidir; donanim hizlandirmasi
  ya da 128-bit register kullanmaz. 38 hanelik degerler icin yeterince
  hizlidir, milyonlarca satirlik tam taramada toplama maliyeti metin
  islemeye benzer. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

const
  { Arrow Decimal128 tek bir 128-bit isaretli tamsayi tasir; 10^38 < 2^127
    oldugu icin 38 hane guvenle sigar. Ayni sinir Parquet DECIMAL ve SQL
    standardi uygulamalarinin coguyla uyumludur. }
  VDB_DEC_MAX_PREC = 38;
  { Olcek pratikte hassasiyetten buyuk olamaz; yine de ust sinir koyuyoruz
    ki '1e-200' gibi bir girdi bellekte 200 sifir uretmesin. }
  VDB_DEC_MAX_SCALE = 100;
  { Us (exponent) girdisinde kabul edilen aralik. }
  VDB_DEC_MAX_EXP = 100;

type
  TVdbDec = record
    Neg: Boolean;
    Digits: string;
    Scale: Integer;
  end;

function VdbDecZero: TVdbDec;
function VdbDecFromInt64(const V: Int64): TVdbDec;
{ Kayan noktadan donusum YALNIZCA acik CAST icin vardir ve 15 anlamli
  haneyle sinirlidir; DECIMAL'in kendi degerleri bu yoldan gecmez. }
function VdbDecFromFloat(const V: Double; out D: TVdbDec; out Err: string): Boolean;
function VdbDecParse(const S: string; out D: TVdbDec; out Err: string): Boolean;
function VdbDecToStr(const D: TVdbDec): string;
function VdbDecPrecision(const D: TVdbDec): Integer;
function VdbDecIsZero(const D: TVdbDec): Boolean;
function VdbDecCmp(const A, B: TVdbDec): Integer;
function VdbDecNegate(const D: TVdbDec): TVdbDec;
{ Cikis parametreleri `var`'dir (out DEGIL): `out` bir kaydi giriste
  sonlandirir, bu yuzden `VdbDecAdd(sum, x, sum)` gibi mesru bir
  biriktirme cagrisi A'yi da siler. `var` ile alias guvenlidir; her
  yol tum alanlari atar. }
function VdbDecAdd(const A, B: TVdbDec; var R: TVdbDec): Boolean;
function VdbDecSub(const A, B: TVdbDec; var R: TVdbDec): Boolean;
function VdbDecMul(const A, B: TVdbDec; var R: TVdbDec): Boolean;
{ Bolme: sonuc `AScale` haneye yuvarlanir (yarim yukari). Sifira bolme
  hatadir; `Err` doldurulur ve False doner. }
function VdbDecDiv(const A, B: TVdbDec; const AScale: Integer;
  var R: TVdbDec; out Err: string): Boolean;
{ Yarim yukari yuvarlama. AScale negatif olamaz. }
function VdbDecRound(const D: TVdbDec; const AScale: Integer;
  var R: TVdbDec; out Err: string): Boolean;
{ SQL kolon tipine oturtma: once ASize olcegine yuvarla, sonra hassasiyet
  sinirini denetle. Hassasiyet tasarsa False + Err. }
function VdbDecFit(const D: TVdbDec; const APrec, AScale: Integer;
  var R: TVdbDec; out Err: string): Boolean;

implementation

function NormDigits(const S: string): string;
var
  i, n: Integer;
begin
  i := 1;
  n := Length(S);
  while (i <= n) and (S[i] = '0') do
    Inc(i);
  if i > n then
    Result := '0'
  else
    Result := Copy(S, i, n - i + 1);
end;

function CmpUnsigned(const A, B: string): Integer;
begin
  if Length(A) <> Length(B) then
  begin
    if Length(A) < Length(B) then
      Exit(-1)
    else
      Exit(1);
  end;
  Result := CompareStr(A, B);
end;

function AddUnsigned(const A, B: string): string;
var
  i, j, k, s, carry: Integer;
  r: string;
begin
  i := Length(A);
  j := Length(B);
  carry := 0;
  if Length(A) > Length(B) then
    SetLength(r, Length(A) + 1)
  else
    SetLength(r, Length(B) + 1);
  k := Length(r);
  while k >= 1 do
  begin
    s := carry;
    if i >= 1 then
    begin
      Inc(s, Ord(A[i]) - 48);
      Dec(i);
    end;
    if j >= 1 then
    begin
      Inc(s, Ord(B[j]) - 48);
      Dec(j);
    end;
    carry := s div 10;
    r[k] := Chr(48 + (s mod 10));
    Dec(k);
  end;
  Result := NormDigits(r);
end;

{ A >= B varsayilir. }
function SubUnsigned(const A, B: string): string;
var
  i, j, k, d, borrow: Integer;
  r: string;
begin
  i := Length(A);
  j := Length(B);
  borrow := 0;
  SetLength(r, i);
  for k := i downto 1 do
  begin
    d := (Ord(A[k]) - 48) - borrow;
    if j >= 1 then
    begin
      Dec(d, Ord(B[j]) - 48);
      Dec(j);
    end;
    if d < 0 then
    begin
      Inc(d, 10);
      borrow := 1;
    end
    else
      borrow := 0;
    r[k] := Chr(48 + d);
  end;
  Result := NormDigits(r);
end;

function MulUnsigned(const A, B: string): string;
var
  i, j, k, s, carry, n: Integer;
  tmp: array of Integer;
begin
  if (A = '0') or (B = '0') then
    Exit('0');
  SetLength(tmp, Length(A) + Length(B));
  for i := 1 to Length(tmp) do
    tmp[i - 1] := 0;
  for i := Length(A) downto 1 do
    for j := Length(B) downto 1 do
      Inc(tmp[i + j - 1], (Ord(A[i]) - 48) * (Ord(B[j]) - 48));
  carry := 0;
  for k := Length(tmp) downto 1 do
  begin
    s := tmp[k - 1] + carry;
    tmp[k - 1] := s mod 10;
    carry := s div 10;
  end;
  n := Length(tmp);
  SetLength(Result, n);
  for k := 1 to n do
    Result[k] := Chr(48 + tmp[k - 1]);
  Result := NormDigits(Result);
end;

{ Pozitif tamsayi bolmesi: A / B. `AExtra` kadar sifir paya eklenir, yani
  sonuc olcegi AExtra olur. Kalan `Rem` icinde doner (yuvarlama karari icin
  gerekirse kullanilabilir). }
function DivUnsigned(const A, B: string; const AExtra: Integer;
  out Rem: string): string;
var
  i, d: Integer;
  a2, q: string;
begin
  a2 := A + StringOfChar('0', AExtra);
  Rem := '0';
  q := '';
  for i := 1 to Length(a2) do
  begin
    Rem := NormDigits(Rem + a2[i]);
    d := 0;
    while CmpUnsigned(Rem, B) >= 0 do
    begin
      Rem := SubUnsigned(Rem, B);
      Inc(d);
    end;
    q := q + Chr(48 + d);
  end;
  Result := NormDigits(q);
end;

function VdbDecZero: TVdbDec;
begin
  Result.Neg := False;
  Result.Digits := '0';
  Result.Scale := 0;
end;

function VdbDecFromInt64(const V: Int64): TVdbDec;
var
  u: QWord;
begin
  Result.Scale := 0;
  Result.Neg := V < 0;
  if V < 0 then
    u := QWord(-(V + 1)) + 1
  else
    u := QWord(V);
  Result.Digits := NormDigits(UIntToStr(u));
  if Result.Digits = '0' then
    Result.Neg := False;
end;

function VdbDecFromFloat(const V: Double; out D: TVdbDec;
  out Err: string): Boolean;
var
  s: string;
  FS: TFormatSettings;
begin
  Err := '';
  if V <> V then
  begin
    Err := 'Decimal: NaN degeri ondaliga cevrilemez';
    Exit(False);
  end;
  if (V > 1e308) or (V < -1e308) then
  begin
    Err := 'Decimal: sonsuz deger ondaliga cevrilemez';
    Exit(False);
  end;
  { 15 anlamli hane: Double'in guvenilir kismi. Daha fazlasini yazmak
    sahte bir hassasiyet iddiasi olurdu. Ayrica bicim YEREL AYARDAN
    bagimsiz olmali: aksi halde Turkce yerelde "0,5" uretilip ayristirici
    tarafindan reddediliyordu. }
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  s := FloatToStrF(V, ffGeneral, 15, 0, FS);
  Result := VdbDecParse(s, D, Err);
end;

function VdbDecParse(const S: string; out D: TVdbDec;
  out Err: string): Boolean;
var
  t: string;
  i, n, dotAt, expAt, expSign, expVal: Integer;
  hasDigits, hasDot, hasExp: Boolean;
  mant, frac, ds: string;
begin
  Err := '';
  D := VdbDecZero;
  t := Trim(S);
  if t = '' then
  begin
    Err := 'Decimal: bos deger';
    Exit(False);
  end;
  n := Length(t);
  i := 1;
  D.Neg := False;
  if (t[1] = '-') or (t[1] = '+') then
  begin
    D.Neg := t[1] = '-';
    Inc(i);
  end;
  dotAt := 0;
  expAt := 0;
  hasDigits := False;
  hasDot := False;
  hasExp := False;
  while i <= n do
  begin
    case t[i] of
      '0'..'9':
        hasDigits := True;
      '.':
        begin
          if hasDot or hasExp then
          begin
            Err := 'Decimal: gecersiz sayi "' + S + '"';
            Exit(False);
          end;
          hasDot := True;
          dotAt := i;
        end;
      'e', 'E':
        begin
          if hasExp or not hasDigits then
          begin
            Err := 'Decimal: gecersiz sayi "' + S + '"';
            Exit(False);
          end;
          hasExp := True;
          expAt := i;
          Break;
        end;
    else
      Err := 'Decimal: gecersiz karakter "' + S + '"';
      Exit(False);
    end;
    Inc(i);
  end;
  if not hasDigits then
  begin
    Err := 'Decimal: rakam yok "' + S + '"';
    Exit(False);
  end;
  if hasExp then
  begin
    mant := Copy(t, 1, expAt - 1);
    ds := Copy(t, expAt + 1, n - expAt);
    if ds = '' then
    begin
      Err := 'Decimal: us yok "' + S + '"';
      Exit(False);
    end;
    expSign := 1;
    if (ds[1] = '-') or (ds[1] = '+') then
    begin
      if ds[1] = '-' then
        expSign := -1;
      ds := Copy(ds, 2, Length(ds));
    end;
    if ds = '' then
    begin
      Err := 'Decimal: us yok "' + S + '"';
      Exit(False);
    end;
    for i := 1 to Length(ds) do
      if (ds[i] < '0') or (ds[i] > '9') then
      begin
        Err := 'Decimal: gecersiz us "' + S + '"';
        Exit(False);
      end;
    expVal := StrToIntDef(ds, MaxInt);
    if (expVal = MaxInt) or (expVal > VDB_DEC_MAX_EXP) then
    begin
      Err := 'Decimal: us siniri asildi "' + S + '"';
      Exit(False);
    end;
    expVal := expVal * expSign;
  end
  else
  begin
    mant := t;
    if (mant[1] = '-') or (mant[1] = '+') then
      mant := Copy(mant, 2, Length(mant));
    expVal := 0;
  end;
  { mantissa: tam + kesir }
  dotAt := Pos('.', mant);
  if dotAt > 0 then
  begin
    frac := Copy(mant, dotAt + 1, Length(mant));
    mant := Copy(mant, 1, dotAt - 1);
  end
  else
    frac := '';
  if (mant = '') and (frac = '') then
  begin
    Err := 'Decimal: rakam yok "' + S + '"';
    Exit(False);
  end;
  for i := 1 to Length(mant) do
    if (mant[i] < '0') or (mant[i] > '9') then
    begin
      Err := 'Decimal: gecersiz sayi "' + S + '"';
      Exit(False);
    end;
  for i := 1 to Length(frac) do
    if (frac[i] < '0') or (frac[i] > '9') then
    begin
      Err := 'Decimal: gecersiz sayi "' + S + '"';
      Exit(False);
    end;
  D.Scale := Length(frac) - expVal;
  D.Digits := NormDigits(mant + frac);
  if D.Scale < 0 then
  begin
    { us pozitif: sifir ekleyip olcegi 0'a indir }
    if -D.Scale > VDB_DEC_MAX_EXP then
    begin
      Err := 'Decimal: us siniri asildi "' + S + '"';
      Exit(False);
    end;
    D.Digits := D.Digits + StringOfChar('0', -D.Scale);
    D.Scale := 0;
  end;
  if D.Scale > VDB_DEC_MAX_SCALE then
  begin
    Err := 'Decimal: olcek siniri asildi "' + S + '"';
    Exit(False);
  end;
  D.Digits := NormDigits(D.Digits);
  if D.Digits = '0' then
    D.Neg := False;
  Result := True;
end;

function VdbDecToStr(const D: TVdbDec): string;
var
  s: string;
begin
  if (D.Digits = '0') or (D.Digits = '') then
  begin
    // Sifir da olcegi korumali: DECIMAL(10,3) icin '0.000', DECIMAL(10,0)
    // icin '0'. Aksi halde kanonik metin bozulur (''0.00'' ile ''0'' ayni
    // degerin iki farkli yazimi olur ve metin anahtarli kumeleme bozulur).
    if D.Scale > 0 then
      Exit('0.' + StringOfChar('0', D.Scale));
    Exit('0');
  end;
  s := '';
  if D.Neg then
    s := '-';
  if D.Scale = 0 then
    s := s + D.Digits
  else if Length(D.Digits) <= D.Scale then
    s := s + '0.' + StringOfChar('0', D.Scale - Length(D.Digits)) + D.Digits
  else
    s := s + Copy(D.Digits, 1, Length(D.Digits) - D.Scale) + '.' +
      Copy(D.Digits, Length(D.Digits) - D.Scale + 1, D.Scale);
  Result := s;
end;

function VdbDecPrecision(const D: TVdbDec): Integer;
begin
  if D.Digits = '0' then
    Exit(1);
  if Length(D.Digits) > D.Scale then
    Result := Length(D.Digits)
  else
    Result := D.Scale;
end;

function VdbDecIsZero(const D: TVdbDec): Boolean;
begin
  Result := (D.Digits = '0') or (D.Digits = '');
end;

function VdbDecCmp(const A, B: TVdbDec): Integer;
var
  sc: Integer;
  ad, bd: string;
begin
  if VdbDecIsZero(A) and VdbDecIsZero(B) then
    Exit(0);
  if VdbDecIsZero(A) then
  begin
    if B.Neg then Exit(1) else Exit(-1);
  end;
  if VdbDecIsZero(B) then
  begin
    if A.Neg then Exit(-1) else Exit(1);
  end;
  if A.Neg <> B.Neg then
  begin
    if A.Neg then Exit(-1) else Exit(1);
  end;
  sc := A.Scale;
  if B.Scale > sc then
    sc := B.Scale;
  ad := A.Digits + StringOfChar('0', sc - A.Scale);
  bd := B.Digits + StringOfChar('0', sc - B.Scale);
  Result := CmpUnsigned(ad, bd);
  if A.Neg then
    Result := -Result;
end;

function VdbDecNegate(const D: TVdbDec): TVdbDec;
begin
  Result := D;
  if not VdbDecIsZero(D) then
    Result.Neg := not D.Neg
  else
    Result.Neg := False;
end;

function VdbDecAdd(const A, B: TVdbDec; var R: TVdbDec): Boolean;
var
  sc, c: Integer;
  ad, bd: string;
begin
  sc := A.Scale;
  if B.Scale > sc then
    sc := B.Scale;
  ad := A.Digits + StringOfChar('0', sc - A.Scale);
  bd := B.Digits + StringOfChar('0', sc - B.Scale);
  R.Scale := sc;
  if A.Neg = B.Neg then
  begin
    R.Digits := AddUnsigned(ad, bd);
    R.Neg := A.Neg;
  end
  else
  begin
    c := CmpUnsigned(ad, bd);
    if c = 0 then
    begin
      R := VdbDecZero;
      Exit(True);
    end;
    if c > 0 then
    begin
      R.Digits := SubUnsigned(ad, bd);
      R.Neg := A.Neg;
    end
    else
    begin
      R.Digits := SubUnsigned(bd, ad);
      R.Neg := B.Neg;
    end;
  end;
  R.Digits := NormDigits(R.Digits);
  if R.Digits = '0' then
    R.Neg := False;
  Result := True;
end;

function VdbDecSub(const A, B: TVdbDec; var R: TVdbDec): Boolean;
var
  NB: TVdbDec;
begin
  { R, A ya da B ile ayni degisken olabilir; once isareti cevir. }
  NB := VdbDecNegate(B);
  Result := VdbDecAdd(A, NB, R);
end;

function VdbDecMul(const A, B: TVdbDec; var R: TVdbDec): Boolean;
var
  d: string;
  sc: Integer;
  ng: Boolean;
begin
  { R, A ya da B ile alias olabilir: once hesapla, sonra ata. }
  d := MulUnsigned(A.Digits, B.Digits);
  sc := A.Scale + B.Scale;
  ng := A.Neg xor B.Neg;
  R.Digits := NormDigits(d);
  R.Scale := sc;
  R.Neg := ng;
  if R.Digits = '0' then
    R.Neg := False;
  Result := True;
end;

function VdbDecDiv(const A, B: TVdbDec; const AScale: Integer;
  var R: TVdbDec; out Err: string): Boolean;
var
  shift, tmpScale, qScale: Integer;
  ad, bd, q: string;
  rem: string;
  T, LA, LB: TVdbDec;
begin
  Err := '';
  { R alias olabilir: girdileri KORU, sonra cikisi sifirla. }
  LA := A;
  LB := B;
  R := VdbDecZero;
  if AScale < 0 then
  begin
    Err := 'Decimal: bolme olcegi negatif olamaz';
    Exit(False);
  end;
  if VdbDecIsZero(LB) then
  begin
    Err := 'Decimal: sifira bolme';
    Exit(False);
  end;
  if VdbDecIsZero(LA) then
    Exit(True);
  { A/B = (ad/10^as) / (bd/10^bs) = (ad/bd) * 10^(bs-as).
    Sonucu qScale=AScale+1 hanede uretiyoruz (yuvarlama icin bir fazla
    hane), yani gereken kaydirma: shift = qScale + bs - as. }
  qScale := AScale + 1;
  shift := qScale + LB.Scale - LA.Scale;
  ad := LA.Digits;
  bd := LB.Digits;
  if shift >= 0 then
    q := DivUnsigned(ad, bd, shift, rem)
  else
  begin
    bd := bd + StringOfChar('0', -shift);
    q := DivUnsigned(ad, bd, 0, rem);
  end;
  T.Digits := q;
  T.Scale := qScale;
  T.Neg := LA.Neg xor LB.Neg;
  if T.Digits = '0' then
    T.Neg := False;
  if not VdbDecRound(T, AScale, R, Err) then
    Exit(False);
  Result := True;
end;

function VdbDecRound(const D: TVdbDec; const AScale: Integer;
  var R: TVdbDec; out Err: string): Boolean;
var
  cut, keep: Integer;
  digits: string;
  up: Boolean;
  DD: TVdbDec;
begin
  Err := '';
  { R, D ile alias olabilir: girdiyi koru, sonra cikisi sifirla. }
  DD := D;
  R := VdbDecZero;
  if AScale < 0 then
  begin
    Err := 'Decimal: olcek negatif olamaz';
    Exit(False);
  end;
  if AScale > VDB_DEC_MAX_SCALE then
  begin
    Err := 'Decimal: olcek siniri asildi';
    Exit(False);
  end;
  if VdbDecIsZero(DD) then
  begin
    R.Scale := AScale;
    Exit(True);
  end;
  R.Neg := DD.Neg;
  R.Scale := AScale;
  if DD.Scale <= AScale then
  begin
    digits := DD.Digits + StringOfChar('0', AScale - DD.Scale);
    R.Digits := NormDigits(digits);
    Exit(True);
  end;
  cut := DD.Scale - AScale;
  if cut >= Length(DD.Digits) then
  begin
    { Tum haneler kesiliyor. Yuvarlama yalnizca ilk kesilen hane tam
      basamak basindaysa (cut = Length) mumkundur. }
    up := (cut = Length(DD.Digits)) and (DD.Digits[1] >= '5');
    if up then
    begin
      R.Digits := '1';
      R.Neg := False;
      Exit(True);
    end;
    R.Digits := '0';
    R.Neg := False;
    Exit(True);
  end;
  keep := Length(DD.Digits) - cut;
  digits := Copy(DD.Digits, 1, keep);
  up := DD.Digits[keep + 1] >= '5';
  if up then
    digits := AddUnsigned(digits, '1');
  R.Digits := NormDigits(digits);
  if R.Digits = '0' then
    R.Neg := False;
  Result := True;
end;

function VdbDecFit(const D: TVdbDec; const APrec, AScale: Integer;
  var R: TVdbDec; out Err: string): Boolean;
var
  p: Integer;
  DD: TVdbDec;
begin
  Err := '';
  DD := D;
  R := VdbDecZero;
  if APrec < 1 then
  begin
    Err := 'Decimal: hassasiyet en az 1 olmali';
    Exit(False);
  end;
  if APrec > VDB_DEC_MAX_PREC then
  begin
    Err := Format('Decimal: hassasiyet %d desteklenen sinir %d ustunde',
      [APrec, VDB_DEC_MAX_PREC]);
    Exit(False);
  end;
  if AScale < 0 then
  begin
    Err := 'Decimal: olcek negatif olamaz';
    Exit(False);
  end;
  if AScale > APrec then
  begin
    Err := Format('Decimal(%d,%d): olcek hassasiyetten buyuk olamaz',
      [APrec, AScale]);
    Exit(False);
  end;
  if not VdbDecRound(DD, AScale, R, Err) then
    Exit(False);
  p := VdbDecPrecision(R);
  if p > APrec then
  begin
    Err := Format('Decimal(%d,%d): deger %s hassasiyeti asiyor (gerekli %d)',
      [APrec, AScale, VdbDecToStr(R), p]);
    Exit(False);
  end;
  Result := True;
end;

end.
