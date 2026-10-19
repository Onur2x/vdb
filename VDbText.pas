unit VDbText;

{ Metin islemleri (UTF-8, bagimsiz birim) + R-20 collation motoru.

  Girdi dizileri UTF-8 kodlu AnsiString kabul edilir (motorun formati).

  == TEMEL ISLEMLER ==
  - VDbTrUpper/VDbTrLower : Turkce noktali/noktasiz I cevrimi.
  - VDbUtf8Length        : karakter sayisi (LENGTH() icin; bayt degil).
  - VDbCompareTr         : Turk alfabesi sirasi (geriye uyum).

  == R-20 COLLATION ==
  Collate motoru DIL PROFILI uzerine kuruludur. Profil = locale + ICU
  secenek anahtarlari. Iki kademeli:

    (1) ALFABE AGIRLIKLARI  -> alfabetik sira
        Her alfabe (Latin, Kiril, Yunan, Arap, Ibran, Devanagari, ...)
        icin harflerin sirasi tanimlidir. Latin tabanli diller icin
        ek agirlik (accent) ayri bir TIER'a tasinir; Kiril/Yunan gibi
        alfabelerde harf + isaret birlikte agirlik tablosunda yer alir.

    (2) TIER'LAR (duyarlilik seviyeleri) -> esitlik
        primary   : alfabe agirligi
        secondary : vurgu (nokta)  -> -u-ks / -u-kn
        tertiary  : buyuk/kucuk     -> -u-kc / varsayilan
        quaternary: ayni tum katmanlarda -> deterministik bayt bag cozucu

  Desteklenen ana alfabeler: Latin, Kiril, Yunan, Arap, Ibran, Devanagari,
  Bengal, Gurmukhi, Gurjarati, Oriya, Tamil, Telugu, Kannada, Malayalam,
  Sinhala, Tay, Lao, Khmer, Myanmar, Gec, Ermeni, Han (Cin), Hiragana,
  Katakana, Hangul, Etiyopik.

  Bilinmeyen locale adi: alfabe otomatik secilir (Kod noktasi araligina
  bakarak), agirliklar genel Unicode sirasina yakin verilir. Boylece
  "de-DE", "ja-JP", "he-IL" gibi her etiket CALISIR; motor sabit bir dil
  listesine kilitli DEGILDIR.

  API:
    VDbLangProfile(Name, out P)  : ad -> dil profili (basarili mi)
    VDbCompareCol(A, B, P)       : profile gore karsilastirma
    VDbCollationKey(P, S)        : index/UNIQUE icin normalize anahtar
    VDbDefaultCollation(P)       : profilin varsayilan collation adi
}

{$mode delphi}

interface

uses SysUtils, Classes;

// ---- temel islemler (geriye uyum) ----
function VDbTrUpper(const S: string): string;
function VDbTrLower(const S: string): string;
function VDbUtf8Length(const S: string): Integer;
function VDbCompareTr(const A, B: string): Integer;

// ---- R-20: DIL PROFILI ----
type
  { Alfabe turleri. agirlik tablosu ve buyuk/kucuk cevrimi bununla
    secilir. }
  TVDbAlpha = (
    vaBinary,      // C / POSIX: ham kod noktasi
    vaLatin,       // Latin-1 + Latin Extended (Turkce dahil)
    vaCyrillic,    // Kiril
    vaGreek,       // Yunan
    vaArabic,      // Arap (bas ses uydurma)
    vaHebrew,      // Ibran (bas ses uydurma)
    vaDevanagari,  // Sanskrit
    vaBengali, vaGurmukhi, vaGujarati, vaOriya, vaTamil,
    vaTelugu, vaKannada, vaMalayalam, vaSinhala,
    vaThai,        // Tay (bas ses uydurma)
    vaLao, vaKhmer, vaMyanmar, vaTibetan,
    vaGeorgian, vaArmenian,
    vaHan,         // Cin ideograflari (kod noktasi / kanji)
    vaHiragana, vaKatakana, vaHangul,
    vaEthiopic
  );

  { Duyarlilik seviyesi: kac katman karsilastirilacak. }
  TVDbStrength = (vsPrimary, vsSecondary, vsTertiary, vsQuaternary);

  { Tek bir collation tanimi. }
  TVDbLang = record
    Name: string;        // normalize edilmis ad ('tr-tr-u-kn')
    Locale: string;      // ana dil/bolge ('tr-TR')
    Lang: string;        // sadece dil ('tr')
    Alpha: TVDbAlpha;
    Strength: TVDbStrength;
    // Turkce'ye ozgu buyuk/kucuk (i/ı ayrimi).
    TurkishCase: Boolean;
    // Arapca/Ibranice/Tay gibi bas ses uyduran alfabelerde harf
    // bicimleri (form) ayrimi.
    IgnoreForms: Boolean;   // -u-ks ile kapatilir
    // Sayi ve isaretler harflerden sonra mi once mi gelsin.
    NumericFirst: Boolean;
    // R-20 Full (-u-kn): dogal sayisal siralama. Metin icindeki rakam
    // kosuklari DEGERLE kiyaslanir: "a2" < "a10" < "a100". Bastaki
    // sifirlar esitlige etkisizdir ("a01" = "a1").
    NumericOrder: Boolean;
    // Varsa gercek Unicode collation (bkz. VDbNumericOnly).
    Custom: string;
  end;

{ Collate adini cozumler. "tr-TR-u-kn-ks", "de_DE", "C", "ja-JP" gibi
  her etiket kabul edilir. Bilinmeyen etiket de False DONDURMEZ: alfabe
  kod noktasi araligindan secilir ve True doner (motor kilitli dil
  listesine degildir). Yalnizca BOSTUR basindaki ozel adlar (C/POSIX/
  BINARY) ozel ele alinir. }
function VDbLangProfile(const Name: string; out P: TVDbLang): Boolean;

{ Iki metni profil ile karsilastirir: <0, 0, >0. }
function VDbCompareCol(const A, B: string; const Prof: TVDbLang): Integer;

{ Kolon anahtari / index / UNIQUE icin normalize edilmis anahtar.
  Ayni collation altinda esit sayilan degerler ayni anahtari uretir. }
function VDbCollationKey(const Prof: TVDbLang; const S: string): string;

{ Profil icin kanonik collation adi (sema kaydinda saklanir). }
function VDbCollationName(const Prof: TVDbLang): string;

// Yardimci: verilen kod noktasi icin uygun alfabeyi secer.
function VDbAlphaOfCp(Cp: Integer): TVDbAlpha;

// Yardimci: alfabe verilip verilmeden, bir dilin varsayilan alfabesini
// secer (locale'in ilk iki harfi + kod noktasi araligi).
function VDbAlphaForLang(const LangIn: string): TVDbAlpha;

{ M5 (2026-10-19): temel tam metin arama yardimcilari.
  Inverted index / BM25 HENUZ YOK; bu fonksiyonlar satir metni uzerinde
  calisir ve tarama tabanlidir. Token = harf/rakam (ASCII) veya >=128
  bayt; kucuk harfe cevrilir. }
function VDbFtsNormalize(const S: string): string;
function VDbFtsMatch(const Text, Query: string): Boolean;   // tum terimler (AND)
function VDbFtsRank(const Text, Query: string): Integer;    // terim gecis sayisi

implementation

// ---------------------------------------------------------------
//  UTF-8 yardimcilari
// ---------------------------------------------------------------

function NextCp(const S: string; var P: Integer): Integer;
var
  b0, b1, b2, b3: Byte;
begin
  b0 := Byte(S[P]);
  if b0 < $80 then
  begin
    Result := b0;
    Inc(P);
  end
  else if (b0 and $E0 = $C0) and (P + 1 <= Length(S)) then
  begin
    b1 := Byte(S[P + 1]);
    Result := ((b0 and $1F) shl 6) or (b1 and $3F);
    Inc(P, 2);
  end
  else if (b0 and $F0 = $E0) and (P + 2 <= Length(S)) then
  begin
    b1 := Byte(S[P + 1]);
    b2 := Byte(S[P + 2]);
    Result := ((b0 and $0F) shl 12) or ((b1 and $3F) shl 6) or (b2 and $3F);
    Inc(P, 3);
  end
  else if (b0 and $F8 = $F0) and (P + 3 <= Length(S)) then
  begin
    b1 := Byte(S[P + 1]);
    b2 := Byte(S[P + 2]);
    b3 := Byte(S[P + 3]);
    Result := ((b0 and $07) shl 18) or ((b1 and $3F) shl 12) or
      ((b2 and $3F) shl 6) or (b3 and $3F);
    Inc(P, 4);
  end
  else
  begin
    Result := b0;
    Inc(P);
  end;
end;

procedure PutCp(var D: string; Cp: Integer);
begin
  if Cp < $80 then
    D := D + Chr(Cp)
  else if Cp < $800 then
    D := D + Chr($C0 or (Cp shr 6)) + Chr($80 or (Cp and $3F))
  else if Cp < $10000 then
    D := D + Chr($E0 or (Cp shr 12)) + Chr($80 or ((Cp shr 6) and $3F)) +
      Chr($80 or (Cp and $3F))
  else
    D := D + Chr($F0 or (Cp shr 18)) + Chr($80 or ((Cp shr 12) and $3F)) +
      Chr($80 or ((Cp shr 6) and $3F)) + Chr($80 or (Cp and $3F));
end;

// ---------------------------------------------------------------
//  Buyuk / kucuk cevrimi
//  DIL SPESIFIK: Turkce i/ı, Alman ß, Hollanda IJ, Ibranice nokta,
//  Arapca harf bicimleri.
// ---------------------------------------------------------------

function TrUpperCp(Cp: Integer): Integer;
begin
  case Cp of
    $69: Result := $130; // i -> İ
    $131: Result := $49; // ı -> I
    $15F: Result := $15E; // ş -> Ş
    $11F: Result := $11E; // ğ -> Ğ
    $FC: Result := $DC;  // ü -> Ü
    $F6: Result := $D6;  // ö -> Ö
    $E7: Result := $C7;  // ç -> Ç
    $61..$68, $6A..$7A: Result := Cp - $20;
  else
    Result := Cp;
  end;
end;

function TrLowerCp(Cp: Integer): Integer;
begin
  case Cp of
    $49: Result := $131; // I -> ı
    $130: Result := $69; // İ -> i
    $15E: Result := $15F;
    $11E: Result := $11F;
    $DC: Result := $FC;
    $D6: Result := $F6;
    $C7: Result := $E7;
    $41..$48, $4A..$5A: Result := Cp + $20;
  else
    Result := Cp;
  end;
end;

{ Genel ASCII + Latin-1 cevrim. Turkce modunda degil. }
function GenUpperCp(Cp: Integer): Integer;
begin
  case Cp of
    $DF: Result := Cp;                       // ß (buyutusu yok)
    $E0..$FE: if Cp <> $F7 then Result := Cp - $20 else Result := Cp;
    $FF: Result := $178;                     // ÿ -> Ÿ
    $3B1..$3C9: Result := Cp - $20;          // Yunan
    $3AC: Result := $386;                    // ά
    $3AD, $3AF, $3CC: Result := Cp - $20;
    $3CA..$3CB: Result := Cp - $20;
    $391..$3A9: Result := Cp - $20;
    $410..$42F: Result := Cp - $20;          // Kiril
    $400..$40F: Result := Cp - $50;
    $430..$44F: Result := Cp;
    $450..$45F: Result := Cp - $50;
    $100..$17F: if (Cp and 1) = 0 then Result := Cp - 1 else Result := Cp;
    $180: Result := $178;
  else
    Result := Cp;
  end;
end;

function GenLowerCp(Cp: Integer): Integer;
begin
  case Cp of
    $178: Result := $FF;
    $C0..$DE: if Cp <> $D7 then Result := Cp + $20 else Result := Cp;
    $DF: Result := Cp;                       // ß
    $100..$137: if (Cp and 1) = 1 then Result := Cp + 1 else Result := Cp;
    $139..$148: if (Cp and 1) = 1 then Result := Cp + 1 else Result := Cp;
    $14A..$177: if (Cp and 1) = 0 then Result := Cp + 1 else Result := Cp;
    $179..$17E: if (Cp and 1) = 1 then Result := Cp + 1 else Result := Cp;
    $391..$3A1: Result := Cp + $20;
    $3A3..$3AB: Result := Cp + $20;
    $3B1..$3C1: Result := Cp + $20;
    $3C3..$3CB: Result := Cp + $20;
    $386, $388..$38A, $38C, $38E, $38F: Result := Cp + $20;
    $400..$40F: Result := Cp + $50;
    $410..$42F: Result := Cp + $20;
    $450..$45F: Result := Cp + $80;
  else
    Result := Cp;
  end;
end;

function VDbTrUpper(const S: string): string;
var p: Integer;
begin
  Result := '';
  p := 1;
  while p <= Length(S) do
    PutCp(Result, TrUpperCp(NextCp(S, p)));
end;

function VDbTrLower(const S: string): string;
var p: Integer;
begin
  Result := '';
  p := 1;
  while p <= Length(S) do
    PutCp(Result, TrLowerCp(NextCp(S, p)));
end;

function VDbUtf8Length(const S: string): Integer;
var p: Integer;
begin
  Result := 0;
  p := 1;
  while p <= Length(S) do
  begin
    NextCp(S, p);
    Inc(Result);
  end;
end;

// ---------------------------------------------------------------
//  Alfabe secimi (dil etiketinden veya kod noktasindan)
// ---------------------------------------------------------------

function VDbAlphaOfCp(Cp: Integer): TVDbAlpha;
begin
  if Cp < $0250 then Result := vaLatin
  else if (Cp >= $0370) and (Cp <= $03FF) then Result := vaGreek
  else if (Cp >= $0400) and (Cp <= $052F) then Result := vaCyrillic
  else if (Cp >= $0530) and (Cp <= $058F) then Result := vaArmenian
  else if (Cp >= $0590) and (Cp <= $05FF) then Result := vaHebrew
  else if (Cp >= $0600) and (Cp <= $06FF) then Result := vaArabic
  else if (Cp >= $0700) and (Cp <= $074F) then Result := vaArabic   // Surani
  else if (Cp >= $0750) and (Cp <= $077F) then Result := vaArabic   // Arap ek
  else if (Cp >= $0900) and (Cp <= $097F) then Result := vaDevanagari
  else if (Cp >= $0980) and (Cp <= $09FF) then Result := vaBengali
  else if (Cp >= $0A00) and (Cp <= $0A7F) then Result := vaGurmukhi
  else if (Cp >= $0A80) and (Cp <= $0AFF) then Result := vaGujarati
  else if (Cp >= $0B00) and (Cp <= $0B7F) then Result := vaOriya
  else if (Cp >= $0B80) and (Cp <= $0BFF) then Result := vaTamil
  else if (Cp >= $0C00) and (Cp <= $0C7F) then Result := vaTelugu
  else if (Cp >= $0C80) and (Cp <= $0CFF) then Result := vaKannada
  else if (Cp >= $0D00) and (Cp <= $0D7F) then Result := vaMalayalam
  else if (Cp >= $0D80) and (Cp <= $0DFF) then Result := vaSinhala
  else if (Cp >= $0E00) and (Cp <= $0E7F) then Result := vaThai
  else if (Cp >= $0E80) and (Cp <= $0EFF) then Result := vaLao
  else if (Cp >= $0F00) and (Cp <= $0FFF) then Result := vaTibetan
  else if (Cp >= $1000) and (Cp <= $109F) then Result := vaMyanmar
  else if (Cp >= $10A0) and (Cp <= $10FF) then Result := vaGeorgian
  else if (Cp >= $1100) and (Cp <= $11FF) then Result := vaHangul
  else if (Cp >= $1200) and (Cp <= $137F) then Result := vaEthiopic
  else if (Cp >= $1780) and (Cp <= $17FF) then Result := vaKhmer
  else if (Cp >= $3040) and (Cp <= $309F) then Result := vaHiragana
  else if (Cp >= $30A0) and (Cp <= $30FF) then Result := vaKatakana
  else if (Cp >= $3130) and (Cp <= $318F) then Result := vaHangul
  else if (Cp >= $AC00) and (Cp <= $D7A3) then Result := vaHangul
  else if (Cp >= $4E00) and (Cp <= $9FFF) then Result := vaHan
  else if (Cp >= $3400) and (Cp <= $4DBF) then Result := vaHan
  else if (Cp >= $F900) and (Cp <= $FAFF) then Result := vaHan
  else if (Cp >= $20000) and (Cp <= $2FA1F) then Result := vaHan
  else Result := vaBinary;
end;

{ Dil etiketinin ilk kismindan alfabe. Bilinmeyen dil kod noktasi
  araligindan secilir; o da bilinmiyorsa Latin'e dusulur. }
function VDbAlphaForLang(const LangIn: string): TVDbAlpha;
var
  L: string;
begin
  L := LowerCase(LangIn);
  if L = '' then Exit(vaLatin);
  // Bilinen dil kodu -> alfabe eslemesi
  if (L = 'tr') or (L = 'az') or (L = 'kk') or (L = 'ky') or
     (L = 'uz') then Exit(vaLatin);
  if (L = 'ru') or (L = 'uk') or (L = 'bg') or (L = 'sr') or
     (L = 'mk') or (L = 'be') or (L = 'mn') then Exit(vaCyrillic);
  if L = 'el' then Exit(vaGreek);
  if (L = 'ar') or (L = 'fa') or (L = 'ur') or (L = 'ps') or
     (L = 'sd') or (L = 'ku') or (L = 'ug') then Exit(vaArabic);
  if (L = 'he') or (L = 'iw') then Exit(vaHebrew);
  if (L = 'yi') then Exit(vaHebrew);
  if (L = 'hi') or (L = 'mr') or (L = 'ne') or (L = 'sa') then
    Exit(vaDevanagari);
  if L = 'bn' then Exit(vaBengali);
  if L = 'pa' then Exit(vaGurmukhi);
  if L = 'gu' then Exit(vaGujarati);
  if L = 'or' then Exit(vaOriya);
  if L = 'ta' then Exit(vaTamil);
  if L = 'te' then Exit(vaTelugu);
  if L = 'kn' then Exit(vaKannada);
  if L = 'ml' then Exit(vaMalayalam);
  if L = 'si' then Exit(vaSinhala);
  if L = 'th' then Exit(vaThai);
  if L = 'lo' then Exit(vaLao);
  if L = 'km' then Exit(vaKhmer);
  if L = 'my' then Exit(vaMyanmar);
  if L = 'ka' then Exit(vaGeorgian);
  if L = 'hy' then Exit(vaArmenian);
  if L = 'am' then Exit(vaEthiopic);
  if L = 'zh' then Exit(vaHan);
  if L = 'ja' then Exit(vaHiragana);
  if L = 'ko' then Exit(vaHangul);
  if L = 'bo' then Exit(vaTibetan);
  // Bilinmeyen kod: Latin'e dus (motor kilitli dil listesine degildir;
  // alfabe kullanicinin verisi belirlendigi icin bu en guvenli varsayilan)
  Result := vaLatin;
end;

// ---------------------------------------------------------------
//  ALFABE AGIRLIK TABLOLARI
//  Her alfabe icin: harf -> alfabetik sira.
//  agirlik tablosu 1..N; harf-disi karakterler tablonun SONUNDA.
// ---------------------------------------------------------------

const
  // Latin harf sirasi. Ayni agirlikta olan harfler "genisletilmis"
  // kumesidir: 'c' ve 'ç' -> esit agirlik (accent TIER'ina tasinir).
  LATIN_STR = 'abcdefghijklmnopqrstuvwxyz';

function LatinWeight(Cp: Integer): Integer;
var
  L: Integer;
  i: Integer;
begin
  L := Cp;
  // Turkce: ı ve i AYRI agirliklar (bkz. LatinWeightTr)
  if L = $131 then Exit(9);   // ı
  if L = $130 then Exit(9);   // İ
  // Once BUYUK harfleri kucuge indir: ASCII A-Z, Latin-1 C0-DE,
  // Latin Ext-A (tek/ift kod noktasi ciftleri).
  if (L >= $41) and (L <= $5A) then L := L + $20;
  if (L >= $C0) and (L <= $DE) and (L <> $D7) then L := L + $20;
  if (L >= $100) and (L <= $17F) and ((L and 1) = 0) then L := L + 1;
  if L = $139 then L := $17F;   // Ĺ -> ſ
  // ß -> s ; Þ -> þ (th olarak "th" yerine "s" agirligi verilir)
  if L = $DF then L := $73;
  if L = $FE then L := $FE;
  // Kok harf eslemesi (vurgu ayri TIER'da)
  case L of
    $E0: L := $61;  // à
    $E1: L := $61;  // á
    $E2: L := $61;  // â
    $E3: L := $61;  // ã
    $E4: L := $61;  // ä
    $E5: L := $61;  // å
    $E6: L := $61;  // æ
    $E7: L := $63;  // ç
    $E8: L := $65;  // è
    $E9: L := $65;  // é
    $EA: L := $65;  // ê
    $EB: L := $65;  // ë
    $EC: L := $69;  // ì
    $ED: L := $69;  // í
    $EE: L := $69;  // î
    $EF: L := $69;  // ï
    $F1: L := $6E;  // ñ
    $F2: L := $6F;  // ò
    $F3: L := $6F;  // ó
    $F4: L := $6F;  // ô
    $F5: L := $6F;  // õ
    $F6: L := $6F;  // ö
    $F8: L := $6F;  // ø
    $F9: L := $75;  // ù
    $FA: L := $75;  // ú
    $FB: L := $75;  // û
    $FC: L := $75;  // ü
    $FD: L := $79;  // ý
    $FF: L := $79;
  end;
  for i := 1 to Length(LATIN_STR) do
    if L = Ord(LATIN_STR[i]) then Exit(i);
  Result := 0;   // harf disi
end;

{ Turkce: i ve ı AYRI harflerdir (ikisi de 12. sirada ama farkli
  birincil agirlikla). }
function LatinWeightTr(Cp: Integer): Integer;
var
  w: Integer;
begin
  if Cp = $69 then Exit(12);   // i
  if Cp = $131 then Exit(13);  // ı (ayri)
  if Cp = $130 then Exit(12);  // İ (i ile ayni agirlik, buyuk)
  if Cp = $49 then Exit(13);   // I -> ı
  w := LatinWeight(Cp);
  if w = 12 then Exit(12);     // ì, í, î, ï -> i
  Result := w;
end;

function LatinSecondary(Cp: Integer): Integer;
{ Vurgu (accent) TIER'i. Ayni kok harfin vurgusuz hali 0'dir.
  Vurgulu harfler 1..N alir; ic siralama kod noktasina gore.
  R-20 Full: buyuk harfler kucuge katlanir (Á da vurgulu sayilir). }
var
  L: Integer;
begin
  Result := 0;
  L := Cp;
  // buyuk -> kucuk katlama (LatinWeight ile ayni kurallar)
  if (L >= $41) and (L <= $5A) then L := L + $20;
  if (L >= $C0) and (L <= $DE) and (L <> $D7) then L := L + $20;
  if (L >= $100) and (L <= $17F) and ((L and 1) = 0) then L := L + 1;
  case L of
    $E1: Result := 1;   // á (en sik)
    $E0, $E3, $E8, $EA, $ED, $F3, $F5, $FA, $FD: Result := 2;
    $E2, $E6, $EC, $EF, $F4, $FB, $E9: Result := 3;
    $E4, $E7, $EB, $F6, $FC, $F1: Result := 4;
    $E5, $F8, $DD, $DF: Result := 5;
  else
    Result := 0;
  end;
end;

function CyrillicWeight(Cp: Integer): Integer;
{ R-20 Full DERSI: harf tablosu STRING SABITI olarak yazilmaz! Kaynak
  dosya UTF-8'dir; sabitin icindeki Kiril harfleri IKISER bayt olarak
  derlenir ve Ord(S[i]) kod noktasiyla HIC eslesmezdi (butun Kiril
  harfleri "harf disi" cikiyordu). Agirliklar kod noktasi ARITMETIGI
  ile uretilir. Rus alfabesi (yo haric) U+0430..U+044F araliginda
  KESINTISIZDIR; agirlik = pozisyon * 2 (yo icin araya tek deger
  birakilir). Diger Kiril harfleri (ukrayna vb.) temel alfabeden
  SONRA, kod noktasi sirasiyla (yaklasim). }
begin
  Result := 0;
  // buyuk harfleri kucuge indir
  if (Cp >= $410) and (Cp <= $42F) then Cp := Cp + $20;
  if (Cp >= $400) and (Cp <= $40F) then Cp := Cp + $50;
  if (Cp >= $460) and (Cp <= $481) and ((Cp and 1) = 0) then Inc(Cp);
  // temel Rus alfabesi: U+0430..U+044F kesintisiz (yo bu blokun disinda)
  if (Cp >= $430) and (Cp <= $44F) then Exit((Cp - $430 + 1) * 2);
  // yo (U+0451): e(12) ile zh(14) arasina
  if Cp = $451 then Exit(13);
  // kalan Kiril harfleri (ukrayna/ilave): temel alfabeden sonra
  if (Cp >= $450) and (Cp <= $52F) then Exit(70 + Cp - $450);
end;

function GreekWeight(Cp: Integer): Integer;
{ R-20 Full: ayni kodlama dersi — kod noktasi aritmetigi. Yunan
  alfabesinin kucuk harfleri: alpha..pi = $3B1..$3C0 ve rho..omega =
  $3C2..$3C9 (aradaki $3C1 = son sigma, sigma ile ayni agirliga
  katlanir). Buyuk harfler +$20 ile kucuge iner. }
begin
  Result := 0;
  if (Cp >= $391) and (Cp <= $3A9) then Cp := Cp + $20;
  if Cp = $3C1 then Cp := $3C3;   // son sigma -> sigma
  if (Cp >= $3B1) and (Cp <= $3C0) then Exit(Cp - $3B1 + 1);    // alpha..pi
  if (Cp >= $3C2) and (Cp <= $3C9) then Exit(Cp - $3C2 + 17);   // rho..omega
end;

function ArabicWeight(Cp: Integer): Integer;
{ R-20 Full: kod noktasi aritmetigi (string sabiti kodlama tuzağı).
  Arap alfabesi (28 harf): alef=$627, be=$628, te=$62A..ghayn=$63A,
  fe=$641..ye=$649. Ta marbuta ($629) alfabe harfi degildir; he'ye
  yakin sayilir (yaklasim). }
begin
  Result := 0;
  if Cp = $629 then Exit(26);   // ta marbuta ~ he (yaklasim)
  if (Cp >= $627) and (Cp <= $628) then Exit(Cp - $627 + 1);    // alef..be
  if (Cp >= $62A) and (Cp <= $63A) then Exit(Cp - $62A + 3);    // te..ghayn
  if (Cp >= $641) and (Cp <= $649) then Exit(Cp - $641 + 20);   // fe..ye
end;

function HebrewWeight(Cp: Integer): Integer;
var
  i: Integer;
begin
  if (Cp >= $5D0) and (Cp <= $5EA) then
  begin
    Result := Cp - $5D0 + 1;
    Exit;
  end;
  if (Cp >= $5B0) and (Cp <= $5C7) then
  begin
    // Noktali harfler: noktasiz karsiliklarina yakin
    Result := (Cp - $5B0) + 30;
    Exit;
  end;
  for i := 0 to 4 do
    if Cp = $5B0 + i * 10 then Exit(60 + i);
  Result := 0;
end;

{ Devanagari ve diger Indic alfabeleri: Unicode blok sirasi yeterli bir
  yaklasimdir (gercek vokal sirasi cok karmaSIk ve CLDR'e bagli). }
function BlockWeight(Cp, Lo, Hi: Integer): Integer;
begin
  if (Cp >= Lo) and (Cp <= Hi) then Exit(Cp - Lo + 1);
  Result := 0;
end;

function HanWeight(Cp: Integer): Integer;
begin
  // Cin ideograflari: kod noktasi sirasi (pinyin/stroke sirasi yok).
  if (Cp >= $4E00) and (Cp <= $9FFF) then Exit(Cp - $4E00 + 1);
  if (Cp >= $3400) and (Cp <= $4DBF) then Exit(Cp - $3400 + 1);
  if (Cp >= $F900) and (Cp <= $FAFF) then Exit(Cp - $F900 + 100000);
  Result := 0;
end;

function HiraganaWeight(Cp: Integer): Integer;
begin
  if (Cp >= $3041) and (Cp <= $3096) then Exit(Cp - $3041 + 1);
  Result := 0;
end;

function KatakanaWeight(Cp: Integer): Integer;
begin
  if (Cp >= $30A1) and (Cp <= $30FA) then Exit(Cp - $30A1 + 1);
  Result := 0;
end;

function HangulWeight(Cp: Integer): Integer;
begin
  // Hangul: on ses (choseong) + orta ses (jungseong) + son ses (jongseong)
  if (Cp >= $AC00) and (Cp <= $D7A3) then
  begin
    Result := (Cp - $AC00) div 588 * 1000 + ((Cp - $AC00) mod 588) div 28;
    Exit;
  end;
  if (Cp >= $1100) and (Cp <= $1112) then Exit((Cp - $1100) * 2000);
  if (Cp >= $3130) and (Cp <= $318E) then Exit((Cp - $3130) * 2000 + 5);
  Result := 0;
end;

function GeorgianWeight(Cp: Integer): Integer;
begin
  if (Cp >= $10D0) and (Cp <= $10FB) then Exit(Cp - $10D0 + 1);
  if (Cp >= $2D00) and (Cp <= $2D2F) then Exit(Cp - $2D00 + 500);
  Result := 0;
end;

function ArmenianWeight(Cp: Integer): Integer;
begin
  if (Cp >= $531) and (Cp <= $556) then Exit(Cp - $531 + 1);
  Result := 0;
end;

function EthiopicWeight(Cp: Integer): Integer;
begin
  if (Cp >= $1200) and (Cp <= $1248) then Exit(Cp - $1200 + 1);
  if (Cp >= $1260) and (Cp <= $1288) then Exit(Cp - $1260 + 500);
  Result := 0;
end;

{ Myanmar: kod noktasi sirasi (medya/kombinasyon yok). }
function MyanmarWeight(Cp: Integer): Integer;
begin
  if (Cp >= $1000) and (Cp <= $109F) then Exit(Cp - $1000 + 1);
  Result := 0;
end;

// ---------------------------------------------------------------
//  Agirlik cozumleyici
// ---------------------------------------------------------------

function AlphaWeight(A: TVDbAlpha; Cp: Integer): Integer;
begin
  case A of
    vaLatin:      Result := LatinWeight(Cp);
    vaCyrillic:   Result := CyrillicWeight(Cp);
    vaGreek:      Result := GreekWeight(Cp);
    vaArabic:     Result := ArabicWeight(Cp);
    vaHebrew:     Result := HebrewWeight(Cp);
    vaDevanagari: Result := BlockWeight(Cp, $900, $97F);
    vaBengali:    Result := BlockWeight(Cp, $980, $9FF);
    vaGurmukhi:   Result := BlockWeight(Cp, $A00, $A7F);
    vaGujarati:   Result := BlockWeight(Cp, $A80, $AFF);
    vaOriya:      Result := BlockWeight(Cp, $B00, $B7F);
    vaTamil:      Result := BlockWeight(Cp, $B80, $BFF);
    vaTelugu:     Result := BlockWeight(Cp, $C00, $C7F);
    vaKannada:    Result := BlockWeight(Cp, $C80, $CFF);
    vaMalayalam:  Result := BlockWeight(Cp, $D00, $D7F);
    vaSinhala:    Result := BlockWeight(Cp, $D80, $DFF);
    vaTibetan:    Result := BlockWeight(Cp, $F00, $FFF);
    vaThai:       Result := BlockWeight(Cp, $E00, $E7F);
    vaLao:        Result := BlockWeight(Cp, $E80, $EFF);
    vaKhmer:      Result := BlockWeight(Cp, $1780, $17FF);
    vaMyanmar:    Result := MyanmarWeight(Cp);
    vaGeorgian:   Result := GeorgianWeight(Cp);
    vaArmenian:   Result := ArmenianWeight(Cp);
    vaHan:        Result := HanWeight(Cp);
    vaHiragana:   Result := HiraganaWeight(Cp);
    vaKatakana:   Result := KatakanaWeight(Cp);
    vaHangul:     Result := HangulWeight(Cp);
    vaEthiopic:   Result := EthiopicWeight(Cp);
  else
    Result := 0;
  end;
end;

{ Isaret TIER'i: Ayni kok harfin varyasyonlari icin. Codepoint tabanli,
  deterministik. }
function SecondaryWeight(A: TVDbAlpha; Cp: Integer): Integer;
begin
  case A of
    vaLatin: Result := LatinSecondary(Cp);
  else
    Result := 0;
  end;
end;

// ---------------------------------------------------------------
//  Turkce collation (geriye uyum + R-20 taban)
// ---------------------------------------------------------------

function TrWeight(Cp: Integer): Integer;
begin
  if (Cp >= $41) and (Cp <= $5A) then
    Cp := Cp + $20;
  case Cp of
    $131: Exit(9); // ı
    $69: Exit(9);  // i  (genisletilmis kume)
    $E7: Exit(3);  // ç
    $11F: Exit(7); // ğ
    $F6: Exit(17); // ö
    $15F: Exit(21); // ş
    $FC: Exit(24); // ü
  else
    if (Cp < $61) or (Cp > $7A) then
    begin
      Exit($200000 + Cp);
    end;
  end;
  Result := Ord(Cp) - Ord('a') + 1;
  // Turkce'de q ve x yok; harf olmayan ASCII kod noktasi ile eski
  // davranis korunur (geriye uyum).
end;

function VDbCompareTr(const A, B: string): Integer;
var
  pa, pb, ca, cb, wa, wb: Integer;
  i, LB: Integer;
begin
  pa := 1;
  pb := 1;
  while (pa <= Length(A)) and (pb <= Length(B)) do
  begin
    ca := NextCp(A, pa);
    cb := NextCp(B, pb);
    wa := TrWeight(ca);
    wb := TrWeight(cb);
    if wa < wb then Exit(-1);
    if wa > wb then Exit(1);
  end;
  if Length(A) - pa <> Length(B) - pb then
  begin
    if (Length(A) - pa) < (Length(B) - pb) then Exit(-1) else Exit(1);
  end;
  LB := Length(A);
  if Length(B) < LB then LB := Length(B);
  for i := 1 to LB do
  begin
    if Byte(A[i]) < Byte(B[i]) then Exit(-1);
    if Byte(A[i]) > Byte(B[i]) then Exit(1);
  end;
  if Length(A) < Length(B) then Exit(-1);
  if Length(A) > Length(B) then Exit(1);
  Result := 0;
end;

// ---------------------------------------------------------------
//  R-20: DIL PROFILI COZUMLEME
// ---------------------------------------------------------------

function VDbLangProfile(const Name: string; out P: TVDbLang): Boolean;
var
  N, Base, Opts, Key, Val, Rest, LangOnly, Seg: string;
  q: Integer;
  i: Integer;
  UpperCaseMode, AccentSens, Forms, Numeric, NumericOrder: Boolean;
  Lang2: string;

  { R-20 Full: -u- anahtarini degeriyle uygular. Eski kodda bu if
    zinciri dongunun icindeydi ve DEGER segmentleri hic okunmuyordu
    ("kn-true" degeri yeni bir anahtar saniliyordu, "ks-level2"
    kayboluyordu). }
  procedure ApplyU(const K, V: string);
  begin
    if K = 'KS' then
    begin
      // ICU "ks" deger alir: level1..level4 / identic
      if V = 'LEVEL1' then
      begin
        AccentSens := False;
        P.Strength := vsPrimary;
      end
      else if V = 'LEVEL2' then
      begin
        AccentSens := True;
        if P.Strength < vsSecondary then P.Strength := vsSecondary;
      end
      else if V = 'LEVEL3' then
      begin
        AccentSens := True;
        UpperCaseMode := True;
        if P.Strength < vsTertiary then P.Strength := vsTertiary;
      end
      else if (V = 'LEVEL4') or (V = 'IDENTIC') then
      begin
        AccentSens := True;
        UpperCaseMode := True;
        P.Strength := vsQuaternary;
      end
      else
      begin
        // degerler N upper-case oldugu icin buyuk harfle kiyaslanir
        AccentSens := (V <> 'FALSE');
        Forms := (V <> 'TRUE');
        if P.Strength < vsSecondary then P.Strength := vsSecondary;
      end;
    end
    else if K = 'KN' then
      // R-20 Full: ICU "kn" = numeric ordering (dogal siralama):
      // rakam kosuklari degerle kiyaslanir ("a2" < "a10").
      NumericOrder := (V <> 'FALSE')
    else if K = 'KC' then
    begin
      UpperCaseMode := (V <> 'FALSE');
      if (V <> 'FALSE') and (P.Strength < vsTertiary) then
        P.Strength := vsTertiary;
    end
    else if K = 'KF' then
    begin
      UpperCaseMode := (V <> 'FALSE');
      if (V <> 'FALSE') and (P.Strength < vsTertiary) then
        P.Strength := vsTertiary;
    end
    else if K = 'KSLEVEL' then
    begin
      AccentSens := (V <> '0');
      Forms := True;
      if AccentSens and (P.Strength < vsSecondary) then
        P.Strength := vsSecondary;
    end
    else if K = 'TUCASE' then
    begin
      UpperCaseMode := True;
      if P.Strength < vsTertiary then P.Strength := vsTertiary;
    end
    else if K = 'NUMERIC' then
      Numeric := (V <> 'FALSE')
    else if K = 'S1' then P.Strength := vsPrimary
    else if K = 'S2' then P.Strength := vsSecondary
    else if K = 'S3' then P.Strength := vsTertiary
    else if K = 'S4' then P.Strength := vsQuaternary;
  end;

  { Bilinen -u- anahtari mi? Acik bir anahtar varken bilinmeyen
    segment deger sayilir; bilinen segment yeni anahtardir. }
  function IsUKey(const S: string): Boolean;
  begin
    Result := (S = 'KS') or (S = 'KN') or (S = 'KC') or (S = 'KF') or
              (S = 'S1') or (S = 'S2') or (S = 'S3') or (S = 'S4') or
              (S = 'NUMERIC') or (S = 'TUCASE') or (S = 'KSLEVEL');
  end;

begin
  N := UpperCase(Trim(Name));
  Result := False;
  if N = '' then Exit(False);
  // Tirnak soy
  while (Length(N) >= 2) and (N[1] = '"') and (N[Length(N)] = '"') do
    N := UpperCase(Copy(N, 2, Length(N) - 2));
  if N = '' then Exit(False);

  // Varsayilanlar
  UpperCaseMode := False;   // buyuk/kucuk duyarsiz
  AccentSens := False;      // vurgu duyarsiz
  Forms := True;
  Numeric := False;
  NumericOrder := False;    // R-20 Full: -u-kn (dogal siralama) kapali
  Base := N;
  { VARSAYILAN GUVVET: vsPrimary -> ne vurgu ne buyuk/kucuk dikkate alinir
    ("ARMUT" = "armut" = "ármut"). Bu PostgreSQL'in cogu locale'i icin
    varsayilanidir ve Turkce'de de gecerlidir.
      -u-ks   -> vurgu DUYARLI   (vsSecondary)
      -u-kc   -> buyuk/kucuk DUYARLI (vsTertiary)
      -u-ks + -u-kc -> ikisi birden (vsTertiary)
      -s1..s4 -> dogrudan guc seviyesi
  }
  P.Strength := vsPrimary;

  // ---- ozel adlar ----
  if (N = 'C') or (N = 'POSIX') or (N = 'BINARY') then
  begin
    P.Name := N;
    P.Locale := 'C';
    P.Lang := 'c';
    P.Alpha := vaBinary;
    P.TurkishCase := False;
    P.IgnoreForms := True;
    P.NumericFirst := False;
    P.NumericOrder := False;
    P.Custom := '';
    P.Strength := vsQuaternary;
    Result := True;
    Exit;
  end;

  // ---- ana dil/bolge + -u- uzanti anahtarlari ----
  q := Pos('-U-', Base);
  if q > 0 then
  begin
    Rest := Copy(Base, q + 3, Length(Base));
    Base := Copy(Base, 1, q - 1);
    { R-20 Full: bolum SEGMENT SEGMENT okunur. Bilinen bir ANAHTAR
      segmenti acik anahtari degersiz kapatir ("kn-ks"); bilinmeyen
      segment acik anahtarin DEGERIdir ("kn-true", "ks-level2").
      "U" ayirici olarak atlanir; boylece eski ayri bicim
      ("...-u-ks-u-kc") da geri uyumlu cozumlenir. }
    Key := '';
    while Rest <> '' do
    begin
      if Rest[1] = '-' then Delete(Rest, 1, 1);
      if Rest = '' then Break;
      i := 1;
      while (i <= Length(Rest)) and (Rest[i] <> '-') do Inc(i);
      Seg := Copy(Rest, 1, i - 1);
      Delete(Rest, 1, i - 1);
      if Seg = 'U' then Continue;
      if (Key <> '') and (not IsUKey(Seg)) then
      begin
        ApplyU(Key, Seg);
        Key := '';
      end
      else
      begin
        if Key <> '' then ApplyU(Key, 'TRUE');
        Key := Seg;
      end;
    end;
    if Key <> '' then ApplyU(Key, 'TRUE');
  end;

  // Ana kismi "dil" ve "bolge" olarak ayir
  q := Pos('-', Base);
  if q > 0 then
    LangOnly := Copy(Base, 1, q - 1)
  else
    LangOnly := Base;

  P.Locale := Base;
  P.Lang := LangOnly;
  P.IgnoreForms := not Forms;
  P.NumericFirst := Numeric;
  P.NumericOrder := NumericOrder;
  P.TurkishCase := (LangOnly = 'TR') or (LangOnly = 'AZ') or
                   (LangOnly = 'KK') or (LangOnly = 'KY');
  P.Custom := '';

  // Alfabe: once dilden, dilden cozulemezse kod noktasindan
  if (LangOnly = 'TR') or (LangOnly = 'AZ') or (LangOnly = 'KK') or
     (LangOnly = 'KY') or (LangOnly = 'UZ') then
    P.Alpha := vaLatin
  else
    P.Alpha := VDbAlphaForLang(LangOnly);

  // Turkce'ye ozgu kural
  if P.TurkishCase and (P.Alpha = vaLatin) then
    P.Alpha := vaLatin;

  // Guc arttir
  if AccentSens and (P.Strength < vsSecondary) then
    P.Strength := vsSecondary;
  if not AccentSens and (P.Strength < vsTertiary) then
  begin
    // Vurgu duyarsiz -> TERTIARY yeterli
  end;
  if UpperCaseMode and (P.Strength < vsTertiary) then
    P.Strength := vsTertiary;

  // Tam (normallestirilmis) etiket; kanonik ad icin VDbCollationName
  P.Name := N;
  Result := True;
end;

// ---------------------------------------------------------------
//  R-20: KARSILASTIRMA
// ---------------------------------------------------------------

function CompareCpTier(Cp: Integer; const Prof: TVDbLang; out W1, W2, W3: Integer): Boolean;
{ Bir kod noktasinin katman agirligini dondurur. True = harf. }
var
  w, s: Integer;
begin
  W1 := 0; W2 := 0; W3 := 0;
  if Prof.Alpha = vaBinary then
  begin
    W1 := Cp;
    Exit(True);
  end;
  if Prof.Alpha = vaLatin then
  begin
    if Prof.TurkishCase then w := LatinWeightTr(Cp) else w := LatinWeight(Cp);
    if w = 0 then Exit(False);
    W1 := w;
    s := LatinSecondary(Cp);
    if s = 0 then s := 1   // vurgusuz: 1
    else Inc(s);           // vurgulu: vurgusuz harften SONRA (ICU sirasi)
    W2 := s;
    if (Cp >= $41) and (Cp <= $5A) then W3 := 0   // buyuk harf 0 = once
    else if (Cp >= $130) and (Cp <= $24F) then W3 := 2  // buyuk uzantili
    else if (Cp >= $61) and (Cp <= $7A) then W3 := 1  // kucuk
    else W3 := 3;
    Exit(True);
  end;
  w := AlphaWeight(Prof.Alpha, Cp);
  if w = 0 then Exit(False);
  W1 := w;
  if (Cp >= $400) and (Cp <= $4FF) then W3 := 0
  else if (Cp >= $1E00) and (Cp <= $1EFF) then W3 := 0   // Kiril buyuk
  else if (Cp >= $100) and (Cp <= $24F) then
    if (Cp and 1) = 0 then W3 := 0 else W3 := 1
  else W3 := 1;
  W2 := 1;
  Exit(True);
end;

function VDbCompareCol(const A, B: string; const Prof: TVDbLang): Integer;
{ Katmanli karsilastirma:
    1) primary   -> alfabetik agirlik dizisi
    2) secondary -> vurgu (yalniz vsSecondary ve uzeri)
    3) tertiary  -> buyuk/kucuk (yalniz vsTertiary ve uzeri)
    4) quaternary-> bayt bag cozucu (yalniz vsQuaternary)
  Her katman tam esitse siradaki katmana gecilir. }
var
  pa, pb, ca, cb: Integer;
  a1, b1, a2, b2, a3, b3: Integer;
  okA, okB: Boolean;
  i, LB: Integer;
  ea, eb, za, zb: Integer;
begin
  if Prof.Alpha = vaBinary then
  begin
    if A = B then Exit(0);
    if A < B then Exit(-1);
    Exit(1);
  end;
  pa := 1;
  pb := 1;
  while (pa <= Length(A)) and (pb <= Length(B)) do
  begin
    // R-20 Full (-u-kn): rakam kosuklari DEGERLE kiyaslanir
    // ("a2" < "a10" < "a100"). Bastaki sifirlar degeri degistirmez;
    // sayisal esit kosuklarda yola devam edilir ("a01" = "a1").
    if Prof.NumericOrder and (A[pa] >= '0') and (A[pa] <= '9') and
       (B[pb] >= '0') and (B[pb] <= '9') then
    begin
      ea := pa;
      while (ea <= Length(A)) and (A[ea] >= '0') and (A[ea] <= '9') do Inc(ea);
      eb := pb;
      while (eb <= Length(B)) and (B[eb] >= '0') and (B[eb] <= '9') do Inc(eb);
      // bastaki sifirlari at (en az 1 rakam kalir)
      za := pa;
      while (za < ea - 1) and (A[za] = '0') do Inc(za);
      zb := pb;
      while (zb < eb - 1) and (B[zb] = '0') do Inc(zb);
      if (ea - za) <> (eb - zb) then
      begin
        if (ea - za) < (eb - zb) then Exit(-1) else Exit(1);
      end;
      i := 0;
      while i < (ea - za) do
      begin
        if A[za + i] < B[zb + i] then Exit(-1);
        if A[za + i] > B[zb + i] then Exit(1);
        Inc(i);
      end;
      pa := ea;
      pb := eb;
      Continue;
    end;
    ca := NextCp(A, pa);
    cb := NextCp(B, pb);
    okA := CompareCpTier(ca, Prof, a1, a2, a3);
    okB := CompareCpTier(cb, Prof, b1, b2, b3);
    if okA and okB then
    begin
      if a1 <> b1 then
      begin
        if a1 < b1 then Exit(-1) else Exit(1);
      end;
      if (Prof.Strength >= vsSecondary) and (a2 <> b2) then
      begin
        if a2 < b2 then Exit(-1) else Exit(1);
      end;
      if (Prof.Strength >= vsTertiary) and (a3 <> b3) then
      begin
        if a3 < b3 then Exit(-1) else Exit(1);
      end;
    end
    else if okA and not okB then
    begin
      // harf, harf-disi karakterden ONCE gelir
      Exit(-1);
    end
    else if okB and not okA then
      Exit(1)
    else
    begin
      // ikisi de harf disi: kod noktasi
      if ca <> cb then
      begin
        if ca < cb then Exit(-1) else Exit(1);
      end;
    end;
  end;
  if (Length(A) - pa) <> (Length(B) - pb) then
  begin
    if (Length(A) - pa) < (Length(B) - pb) then Exit(-1) else Exit(1);
  end;
  if Prof.Strength < vsQuaternary then Exit(0);
  // Quaternary: deterministik bayt bag cozucu
  LB := Length(A);
  if Length(B) < LB then LB := Length(B);
  for i := 1 to LB do
  begin
    if Byte(A[i]) < Byte(B[i]) then Exit(-1);
    if Byte(A[i]) > Byte(B[i]) then Exit(1);
  end;
  if Length(A) < Length(B) then Exit(-1);
  if Length(A) > Length(B) then Exit(1);
  Result := 0;
end;

// ---------------------------------------------------------------
//  R-20: KOLON ANAHTARI (index / UNIQUE)
// ---------------------------------------------------------------

function VDbCollationKey(const Prof: TVDbLang; const S: string): string;
{ Ayni collation altinda ESIT sayilan degerler ayni anahtari uretir.
  Varsayilan (tertiary) kuvvette anahtar = normalize metnin kendisi.
  R-20 Full: -u-kn acikken rakam kosuklarindaki bastaki sifirlar
  atilir; boylece "a01" ile "a1" ayni anahtari uretir. }
var
  i, j, k: Integer;
  cp: Integer;
  w1, w2, w3: Integer;
  Src: string;
begin
  if Prof.Alpha = vaBinary then Exit(S);
  Src := S;
  if Prof.NumericOrder then
  begin
    Src := '';
    i := 1;
    while i <= Length(S) do
    begin
      if (S[i] >= '0') and (S[i] <= '9') then
      begin
        j := i;
        while (j <= Length(S)) and (S[j] >= '0') and (S[j] <= '9') do Inc(j);
        k := i;
        while (k < j - 1) and (S[k] = '0') do Inc(k);
        Src := Src + Copy(S, k, j - k);
        i := j;
      end
      else
      begin
        Src := Src + S[i];
        Inc(i);
      end;
    end;
  end;
  Result := '';
  i := 1;
  while i <= Length(Src) do
  begin
    cp := NextCp(Src, i);
    if CompareCpTier(cp, Prof, w1, w2, w3) then
    begin
      // Buyuk/kucuk ve vurgu katmanlari kuvvet seviyesine gore
      if Prof.Strength >= vsTertiary then
        Result := Result + IntToHex(w3, 2)
      else if Prof.Strength >= vsSecondary then
        Result := Result + IntToHex(w2, 2)
      else
        Result := Result + IntToHex(w1, 4);
    end
    else
      // harf-disi: kod noktasi olarak ekle
      Result := Result + '#' + IntToHex(cp, 6);
  end;
end;

function VDbCollationName(const Prof: TVDbLang): string;
{ KANONIK AD: sema kaydinda saklanan ve yeniden cozumlenebilir tam etiket.
  DIKKAT: yalniz ana locale yazilirsa secenek anahtarlari (-u-ks, -u-kc)
  KAYBOLUR ve kolon varsayilani sessizce degisir. Bu yuzden guc
  seviyesi etikete geri yazilir. }
begin
  if Prof.Alpha = vaBinary then
  begin
    Result := 'C';   // ozel ad: secenek anahtari YOK
    Exit;
  end;
  Result := Prof.Locale;
  { R-20 Full: kn bayragi kanonik ada YAZILMALI; yoksa kolon
    varsayilani yeniden acilista sessizce sayisal siralamayi kaybeder. }
  if Prof.NumericOrder then Result := Result + '-u-kn';
  if Prof.Strength = vsSecondary then Result := Result + '-u-ks'
  else if Prof.Strength = vsTertiary then Result := Result + '-u-ks-u-kc'
  else if Prof.Strength = vsQuaternary then Result := Result + '-u-s4';
end;

// ---- M5: temel FTS (index'siz) ----

procedure VDbFtsSplit(const S: string; var Toks: TStringList);
var
  i: Integer;
  c: Char;
  cur: string;
begin
  Toks.Clear;
  cur := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if ((c >= 'A') and (c <= 'Z')) or ((c >= 'a') and (c <= 'z')) or
       ((c >= '0') and (c <= '9')) or (Ord(c) >= 128) then
      cur := cur + c
    else
    begin
      if cur <> '' then
      begin
        Toks.Add(VDbTrLower(cur));
        cur := '';
      end;
    end;
  end;
  if cur <> '' then
    Toks.Add(VDbTrLower(cur));
end;

function VDbFtsNormalize(const S: string): string;
var
  L: TStringList;
  i: Integer;
begin
  L := TStringList.Create;
  try
    VDbFtsSplit(S, L);
    Result := '';
    for i := 0 to L.Count - 1 do
      if i = 0 then Result := L[i]
      else Result := Result + ' ' + L[i];
  finally
    L.Free;
  end;
end;

{ M5 (2026-10-19): sorgu sozdizimi.
  Terimler AND ile birlesir; -terim negasyon; "iki kelime" phrase.
  Donen liste kodlanmis oge tutar: P/N:tek terim, Q/R:phrase. }
function VDbFtsParseQuery(const Query: string): TStringList;
var
  i, n: Integer;
  c: Char;
  cur: string;
  inQuote, neg: Boolean;

  procedure AddWords(const Prefix, Payload: string);
  var
    W: TStringList;
    k: Integer;
  begin
    W := TStringList.Create;
    try
      VDbFtsSplit(Payload, W);
      for k := 0 to W.Count - 1 do
        Result.Add(Prefix + ':' + W[k]);
    finally
      W.Free;
    end;
  end;

  procedure FlushTerm;
  var
    norm: string;
  begin
    norm := VDbFtsNormalize(cur);
    if norm <> '' then
    begin
      if inQuote then
      begin
        if neg then Result.Add('R:' + norm)
        else Result.Add('Q:' + norm);
      end
      else
      begin
        if neg then AddWords('N', norm)
        else AddWords('P', norm);
      end;
    end;
    cur := '';
    inQuote := False;
    neg := False;
  end;

begin
  Result := TStringList.Create;
  n := Length(Query);
  cur := '';
  inQuote := False;
  neg := False;
  i := 1;
  while i <= n do
  begin
    c := Query[i];
    if inQuote then
    begin
      if c = '"' then
      begin
        FlushTerm;
        Inc(i);
        Continue;
      end;
      cur := cur + c;
      Inc(i);
      Continue;
    end;
    if c = '"' then
    begin
      if cur <> '' then FlushTerm;
      inQuote := True;
      Inc(i);
      Continue;
    end;
    if (c = '-') and (cur = '') then
    begin
      neg := True;
      Inc(i);
      Continue;
    end;
    if (c = ' ') or (c = #9) or (c = #10) or (c = #13) then
    begin
      if cur <> '' then FlushTerm;
      Inc(i);
      Continue;
    end;
    cur := cur + c;
    Inc(i);
  end;
  if (cur <> '') or inQuote then FlushTerm;
end;

function VDbFtsPhraseAt(T: TStringList; Start: Integer;
  const Phrase: string): Boolean;
var
  W: TStringList;
  j: Integer;
begin
  Result := False;
  if (Start < 0) or (Start >= T.Count) then Exit;
  W := TStringList.Create;
  try
    VDbFtsSplit(Phrase, W);
    if (W.Count = 0) or (Start + W.Count > T.Count) then Exit;
    for j := 0 to W.Count - 1 do
      if T[Start + j] <> W[j] then Exit;
    Result := True;
  finally
    W.Free;
  end;
end;

function VDbFtsMatch(const Text, Query: string): Boolean;
var
  T, Q: TStringList;
  i, j: Integer;
  item, prefix, payload: string;
  neg, phrase, hit: Boolean;
begin
  Result := False;
  if (Text = '') or (Query = '') then Exit;
  T := TStringList.Create;
  Q := VDbFtsParseQuery(Query);
  try
    if Q.Count = 0 then Exit;
    VDbFtsSplit(Text, T);
    for i := 0 to Q.Count - 1 do
    begin
      item := Q[i];
      prefix := Copy(item, 1, 1);
      payload := Copy(item, 3, Length(item) - 2);
      neg := (prefix = 'N') or (prefix = 'R');
      phrase := (prefix = 'Q') or (prefix = 'R');
      if phrase then
      begin
        hit := False;
        if T.Count > 0 then
          for j := 0 to T.Count - 1 do
            if VDbFtsPhraseAt(T, j, payload) then
            begin
              hit := True;
              Break;
            end;
      end
      else
        hit := T.IndexOf(payload) >= 0;
      if neg and hit then Exit(False);
      if (not neg) and (not hit) then Exit(False);
    end;
    Result := True;
  finally
    Q.Free;
    T.Free;
  end;
end;

function VDbFtsRank(const Text, Query: string): Integer;
var
  T, Q: TStringList;
  i, j: Integer;
  item, prefix, payload: string;
  phrase: Boolean;
begin
  Result := 0;
  if (Text = '') or (Query = '') then Exit;
  T := TStringList.Create;
  Q := VDbFtsParseQuery(Query);
  try
    VDbFtsSplit(Text, T);
    for i := 0 to Q.Count - 1 do
    begin
      item := Q[i];
      prefix := Copy(item, 1, 1);
      if (prefix = 'N') or (prefix = 'R') then Continue;
      payload := Copy(item, 3, Length(item) - 2);
      phrase := prefix = 'Q';
      if phrase then
      begin
        for j := 0 to T.Count - 1 do
          if VDbFtsPhraseAt(T, j, payload) then Inc(Result);
      end
      else
        for j := 0 to T.Count - 1 do
          if T[j] = payload then Inc(Result);
    end;
  finally
    Q.Free;
    T.Free;
  end;
end;

end.