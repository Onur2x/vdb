unit VDbJson;

{ JSON interchange: depolama binary kalir, tasima/incele JSON ile.
  Tum degerler JSON string (veya null) yazilir: sayi duyarligi ve
  locale bagimsizligi icin bilerek boyle (\"24.5\" her makinede ayni okunur).
  Export sirasi kanonik (tablo adi + PK sirali) -> ayni DB hep ayni dosya.
  fpjson yalnizca IMPORT parse icin (FPC RTL, DLL yok).
}

{$mode delphi}

interface

uses
  Classes, SysUtils, VDbCore, VDbTable, VDbErr,
  { VDbTypes'i DIREKT kullanmamiz gerekiyor: TStrArray, TStrMatrix,
    TColArray artik VDbTable'da DEGIL, VDbTypes biriminde tanimli
    (VDBTable <-> VDbAst dongusunu kirabilmek icin tasindi). FPC
    interface uses zincirlemesi normalde bunu aktarir; ancak VDbTable
    bu tipleri yalnizca TEKRAR KULLANMIYOR, VDbTypes'in interface'ine
    dokundugu icin burada acikca yazmak daha guvenli ve ucuz. }
  VDbTypes;

function VDbCtypeName(C: Byte): string;
function VDbCtypeByName(const S: string): Byte;
procedure VDbExportJson(Tb: TVTableDb; const Path, Table: string);
procedure VDbImportJson(Tb: TVTableDb; const Path: string);

{ ------------------------------------------------------------
  F-22: JSONB SORGULAMA
  Motor JSON metnini (TEXT kolonunda veya literal'da) ayristirip
  PostgreSQL jsonb operatorlerini destekler:
     a @> b   -> a icerme b   (containment)
     a <@ b   -> a, b icinde  (contained by)
     a ?  'k' -> anahtar 'k' var mi
     a ?| ARRAY['k1','k2'] -> anahtarlardan EN AZ BIRI var mi
     a ?& ARRAY['k1','k2'] -> anahtarlarin HEPSI var mi
  ------------------------------------------------------------ }

type
  TJsonKind = (jkNull, jkBool, jkNum, jkStr, jkArr, jkObj);

  { JSON deger agaci. Uyeleri ayri ayri Free edilir (VDbJsonFree). }
  TJsonVal = class
    Kind: TJsonKind;
    B: Boolean;              // jkBool
    Num: Double;             // jkNum
    Str: string;             // jkStr
    Keys: array of string;   // jkObj: uye adlari
    Items: array of TJsonVal;// jkObj: degerler | jkArr: ogeler
  end;

function VDbJsonParse(const S: string; out V: TJsonVal): Boolean;
procedure VDbJsonFree(V: TJsonVal);
function VDbJsonHas(const V: TJsonVal; const Key: string): Boolean;
function VDbJsonEqNode(const A, B: TJsonVal): Boolean;
// @> : L, R icermesini sagliyor mu
function VDbJsonContainsNode(const L, R: TJsonVal): Boolean;
function VDbJsonContainsStr(const L, R: string): Boolean;
function VDbJsonHasKeyStr(const L, Key: string): Boolean;
function VDbJsonAnyKeyStr(const L: string; const Keys: array of string): Boolean;
function VDbJsonAllKeysStr(const L: string; const Keys: array of string): Boolean;

{ M10 (2026-10-19): JSONPath alt kumesi.
  Desteklenen: $ , .ad , ["ad"] , [n] (negatif sondan) , son segmentte .*
  veya [*] (dizi/nesne degerleri -> JSON dizi).
  Yol gecersizse veya deger yoksa False doner; hata yukseltmez. }
function VDbJsonPathGet(const Json, Path: string; out OutText: string): Boolean;
function VDbJsonPathScalar(const Json, Path: string; out OutText: string): Boolean;
function VDbJsonPathExists(const Json, Path: string): Boolean;

{ M4 (2026-10-19): JSON sayi dizisi -> Double vektoru. Tum ogeler sayi
  olmali; aksi halde False. Vektor SQL fonksiyonlari icin. }
type
  TDoubleArray = array of Double;
function VDbJsonNumArray(const S: string; out Vals: TDoubleArray): Boolean;

implementation

uses
  fpjson, jsonparser, VDbSync;

{ ------------------------------------------------------------
  F-22: JSON ayristirici + operatorler
  fpjson IMPORT icin kullaniliyordu; burada SORGU operatorleri icin
  basit, bagimsiz bir ayristirici var. Boylece "@>" gibi operatorler
  satiri satiri ayristirmaya calismaz ve hata mesaji net olur.
  Derinlik siniri: 64 (cok derin JSON asiri girmez).
  //---------------------------------------------------------- }

const
  JSON_MAX_DEPTH = 64;

procedure VDbJsonFree(V: TJsonVal);
var
  i: Integer;
begin
  if V = nil then Exit;
  for i := 0 to High(V.Items) do VDbJsonFree(V.Items[i]);
  SetLength(V.Items, 0);
  SetLength(V.Keys, 0);
  V.Free;
end;

function VDbJsonParse(const S: string; out V: TJsonVal): Boolean;
var
  P: Integer;

  procedure Ws;
  begin
    while (P <= Length(S)) and (S[P] in [' ', #9, #10, #13]) do Inc(P);
  end;

  { JSON metin dizisinden bir deger okur; X = nil ise hata.
    Dis ekranlarda degil, BOS DIZI dondurur. }
  function ParseVal(out X: TJsonVal; Depth: Integer): Boolean;
  var
    b: Boolean;
    c: Char;
    key, numTxt: string;
    cnt, i: Integer;
    child: TJsonVal;
  begin
    Result := False;
    X := nil;
    if Depth > JSON_MAX_DEPTH then Exit(False);
    Ws;
    if P > Length(S) then Exit(False);
    c := S[P];

    // --- dizi [ ... ] ---
    if c = '[' then
    begin
      Inc(P);
      X := TJsonVal.Create;
      X.Kind := jkArr;
      cnt := 0;
      Ws;
      if (P <= Length(S)) and (S[P] = ']') then
      begin
        Inc(P);
        Exit(True);
      end;
      while True do
      begin
        if not ParseVal(child, Depth + 1) then Exit(False);
        SetLength(X.Items, cnt + 1);
        X.Items[cnt] := child;
        Inc(cnt);
        Ws;
        if (P <= Length(S)) and (S[P] = ',') then
        begin
          Inc(P);
          Continue;
        end;
        if (P <= Length(S)) and (S[P] = ']') then
        begin
          Inc(P);
          Exit(True);
        end;
        Exit(False);   // eksik ']' veya ',' yok
      end;
    end;

    // --- nesne { "k": v, ... } ---
    if c = '{' then
    begin
      Inc(P);
      X := TJsonVal.Create;
      X.Kind := jkObj;
      cnt := 0;
      Ws;
      if (P <= Length(S)) and (S[P] = '}') then
      begin
        Inc(P);
        Exit(True);
      end;
      while True do
      begin
        Ws;
        if (P > Length(S)) or (S[P] <> '"') then Exit(False);
        Inc(P);
        key := '';
        while (P <= Length(S)) and (S[P] <> '"') do
        begin
          if (S[P] = '\') and (P + 1 <= Length(S)) then
          begin
            Inc(P);
            case S[P] of
              'n': key := key + #10;
              't': key := key + #9;
              'r': key := key + #13;
              'b': key := key + #8;
              'f': key := key + #12;
              'u': if P + 4 <= Length(S) then
                     begin
                       key := key + Chr(StrToInt('$' + Copy(S, P + 1, 4)));
                       Inc(P, 4);
                     end;
            else
              key := key + S[P];
            end;
            Inc(P);
            Continue;
          end;
          key := key + S[P];
          Inc(P);
        end;
        if (P > Length(S)) or (S[P] <> '"') then Exit(False);
        Inc(P);
        Ws;
        if (P > Length(S)) or (S[P] <> ':') then Exit(False);
        Inc(P);
        if not ParseVal(child, Depth + 1) then Exit(False);
        SetLength(X.Keys, cnt + 1);
        SetLength(X.Items, cnt + 1);
        X.Keys[cnt] := key;
        X.Items[cnt] := child;
        Inc(cnt);
        Ws;
        if (P <= Length(S)) and (S[P] = ',') then
        begin
          Inc(P);
          Continue;
        end;
        if (P <= Length(S)) and (S[P] = '}') then
        begin
          Inc(P);
          Exit(True);
        end;
        Exit(False);
      end;
    end;

    // --- metin "..." ---
    if c = '"' then
    begin
      Inc(P);
      X := TJsonVal.Create;
      X.Kind := jkStr;
      while (P <= Length(S)) and (S[P] <> '"') do
      begin
        if (S[P] = '\') and (P + 1 <= Length(S)) then
        begin
          Inc(P);
          case S[P] of
            'n': X.Str := X.Str + #10;
            't': X.Str := X.Str + #9;
            'r': X.Str := X.Str + #13;
            'b': X.Str := X.Str + #8;
            'f': X.Str := X.Str + #12;
            'u': if P + 4 <= Length(S) then
                   begin
                     X.Str := X.Str + Chr(StrToInt('$' + Copy(S, P + 1, 4)));
                     Inc(P, 4);
                   end;
          else
            X.Str := X.Str + S[P];
          end;
          Inc(P);
          Continue;
        end;
        X.Str := X.Str + S[P];
        Inc(P);
      end;
      if (P > Length(S)) or (S[P] <> '"') then
      begin
        VDbJsonFree(X);
        Exit(False);
      end;
      Inc(P);
      Exit(True);
    end;

    // --- true / false / null ---
    if (P <= Length(S) - 3) and (Copy(S, P, 4) = 'true') then
    begin
      X := TJsonVal.Create;
      X.Kind := jkBool;
      X.B := True;
      Inc(P, 4);
      Exit(True);
    end;
    if (P <= Length(S) - 4) and (Copy(S, P, 5) = 'false') then
    begin
      X := TJsonVal.Create;
      X.Kind := jkBool;
      X.B := False;
      Inc(P, 5);
      Exit(True);
    end;
    if (P <= Length(S) - 3) and (Copy(S, P, 4) = 'null') then
    begin
      X := TJsonVal.Create;
      X.Kind := jkNull;
      Inc(P, 4);
      Exit(True);
    end;

    // --- sayi ---
    if (c = '-') or ((c >= '0') and (c <= '9')) then
    begin
      X := TJsonVal.Create;
      X.Kind := jkNum;
      numTxt := '';
      while (P <= Length(S)) and (((S[P] >= '0') and (S[P] <= '9')) or
            (S[P] = '-') or (S[P] = '+') or (S[P] = '.') or
            (S[P] = 'e') or (S[P] = 'E')) do
      begin
        numTxt := numTxt + S[P];
        Inc(P);
      end;
      // M10: JSON sayilari HER ZAMAN '.' ondalik ayiricisidir; locale'e
      // bagli TryStrToFloat TR gibi virgullu locale'lerde "1.5"u reddediyordu.
      if not VDbParseFloat(numTxt, X.Num) then
      begin
        VDbJsonFree(X);
        Exit(False);
      end;
      Exit(True);
    end;

    Exit(False);
  end;

var
  tail: Integer;
begin
  V := nil;
  if S = '' then Exit(False);
  P := 1;
  if not ParseVal(V, 1) then
  begin
    VDbJsonFree(V);
    V := nil;
    Exit(False);
  end;
  // Artik karakter kalmamali ("{...} xyz" -> gecersiz)
  Ws;
  if P <= Length(S) then
  begin
    VDbJsonFree(V);
    V := nil;
    Exit(False);
  end;
  tail := 0;
  Result := True;
end;

{ ------------------------------------------------------------
  F-22 operator cekirdegi
  //---------------------------------------------------------- }

function VDbJsonHas(const V: TJsonVal; const Key: string): Boolean;
// Nesne: anahtar var mi. Dizi: herhangi bir METIN oge anahtara esit mi
// (PostgreSQL ? operatorinin dizi davranisi).
var
  i: Integer;
begin
  Result := False;
  if V = nil then Exit;
  if V.Kind = jkObj then
  begin
    for i := 0 to High(V.Keys) do
      if V.Keys[i] = Key then
      begin
        Result := True;
        Exit;
      end;
    Exit;
  end;
  if V.Kind = jkArr then
    for i := 0 to High(V.Items) do
      if (V.Items[i] <> nil) and (V.Items[i].Kind = jkStr) and
         (V.Items[i].Str = Key) then
      begin
        Result := True;
        Exit;
      end;
end;

function VDbJsonEqNode(const A, B: TJsonVal): Boolean;
// JSON deger esitligi (containment icin). Sayilar 1 == 1.0 esittir.
var
  i, found, cmp: Integer;
begin
  Result := False;
  if (A = nil) or (B = nil) then Exit(False);
  if A.Kind <> B.Kind then Exit(False);
  case A.Kind of
    jkNull: Result := True;
    jkBool: Result := A.B = B.B;
    jkNum:  Result := A.Num = B.Num;
    jkStr:  Result := A.Str = B.Str;
    jkArr:
      begin
        if Length(A.Items) <> Length(B.Items) then Exit;
        for i := 0 to High(A.Items) do
          if not VDbJsonEqNode(A.Items[i], B.Items[i]) then Exit;
        Result := True;
      end;
    jkObj:
      begin
        // Nesne esitligi: ayni anahtar sayisi ve her deger esit.
        // Anahtar SIRASI onemsizdir (JSON sozluktur):
        //   {"a":1,"b":2} = {"b":2,"a":1}  -> True
        if Length(A.Keys) <> Length(B.Keys) then Exit;
        for i := 0 to High(A.Keys) do
        begin
          found := -1;
          for cmp := 0 to High(B.Keys) do
            if B.Keys[cmp] = A.Keys[i] then
            begin
              found := cmp;
              Break;
            end;
          if found < 0 then Exit;
          if not VDbJsonEqNode(A.Items[i], B.Items[found]) then Exit;
        end;
        Result := True;
      end;
  else
    Result := False;
  end;
end;

function VDbJsonContainsNode(const L, R: TJsonVal): Boolean;
// @> : L, R icermesini sagliyor mu (PostgreSQL jsonb containment).
var
  i, j: Integer;
  found: Boolean;
begin
  Result := False;
  if (L = nil) or (R = nil) then Exit;

  case R.Kind of
    jkObj:
      begin
      // L nesne olmali ve R'in her uyesi L'de AYNI degerle bulunmali
      if L.Kind <> jkObj then Exit;
      for i := 0 to High(R.Keys) do
      begin
        found := False;
        for j := 0 to High(L.Keys) do
          if L.Keys[j] = R.Keys[i] then
          begin
            // DIKKAT: ic ice degerlerde ESITLIK degil ICERME kullanilir.
            // {"adres":{"il":"A"}} , {"adres":{"il":"A","ilce":"X"}} icinde
            // bulunur. Esitlik kullanimkisi ikisini de esit sayardi ve
            // ic ice @> HATALI sonuc verirdi.
            found := VDbJsonContainsNode(L.Items[j], R.Items[i]);
            Break;
          end;
        if not found then Exit;
      end;
      Result := True;
      Exit;
      end;
    jkArr:
      begin
      // R dizi: HER ogesi L icinde bulunmali
      if L.Kind = jkArr then
      begin
        for i := 0 to High(R.Items) do
        begin
          found := False;
          for j := 0 to High(L.Items) do
            // dizi ogeleri icin de icerme (skaler esitligi ayni sey)
            if VDbJsonContainsNode(L.Items[j], R.Items[i]) then
            begin
              found := True;
              Break;
            end;
          if not found then Exit;
        end;
        Result := True;
        Exit;
      end;
      if L.Kind = jkObj then
      begin
        // L nesne: R dizisi L'nin AYNI KILITLI uye dizisi olmali
        for i := 0 to High(R.Items) do
          if R.Items[i].Kind <> jkStr then Exit;
        if Length(R.Items) <> Length(L.Keys) then Exit;
        for i := 0 to High(R.Items) do
        begin
          found := False;
          for j := 0 to High(L.Keys) do
            if L.Keys[j] = R.Items[i].Str then
            begin
              found := True;
              Break;
            end;
          if not found then Exit;
        end;
        Result := True;
        Exit;
      end;
      Exit;
      end;
    jkStr, jkNum, jkBool:
      begin
      // skaler: L dizi ise icinde bulunmali, degilse dogrudan esitlik
      if L.Kind = jkArr then
      begin
        for i := 0 to High(L.Items) do
          if VDbJsonContainsNode(L.Items[i], R) then
          begin
            Result := True;
            Exit;
          end;
        Exit;
      end;
      Result := VDbJsonEqNode(L, R);
      Exit;
      end;
    jkNull:
      Result := (L.Kind = jkNull);
  end;
end;

function VDbJsonContainsStr(const L, R: string): Boolean;
// Metin iki tarafi da ayristirip karsilastirir.
var
  a, b: TJsonVal;
begin
  Result := False;
  if (L = '') or (R = '') then Exit;
  if not VDbJsonParse(L, a) then Exit;
  try
    if VDbJsonParse(R, b) then
    begin
      try
        Result := VDbJsonContainsNode(a, b);
      finally
        VDbJsonFree(b);
      end;
    end;
  finally
    VDbJsonFree(a);
  end;
end;

function VDbJsonHasKeyStr(const L, Key: string): Boolean;
var
  a: TJsonVal;
begin
  Result := False;
  if (L = '') or (Key = '') then Exit;
  if not VDbJsonParse(L, a) then Exit;
  try
    Result := VDbJsonHas(a, Key);
  finally
    VDbJsonFree(a);
  end;
end;

function VDbJsonAnyKeyStr(const L: string; const Keys: array of string): Boolean;
var
  a: TJsonVal;
  i: Integer;
begin
  Result := False;
  if L = '' then Exit;
  if not VDbJsonParse(L, a) then Exit;
  try
    for i := 0 to High(Keys) do
      if VDbJsonHas(a, Keys[i]) then
      begin
        Result := True;
        Exit;
      end;
  finally
    VDbJsonFree(a);
  end;
end;

function VDbJsonAllKeysStr(const L: string; const Keys: array of string): Boolean;
var
  a: TJsonVal;
  i: Integer;
begin
  Result := False;
  if L = '' then Exit;
  if Length(Keys) = 0 then Exit(True);
  if not VDbJsonParse(L, a) then Exit;
  try
    for i := 0 to High(Keys) do
      if not VDbJsonHas(a, Keys[i]) then Exit;
    Result := True;
  finally
    VDbJsonFree(a);
  end;
end;

// ---- M10: JSONPath alt kumesi ----

procedure JsonAppendEscaped(const S: string; var O: string);
var
  i: Integer;
  c: Char;
begin
  O := O + '"';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    case c of
      '"': O := O + '\"';
      '\': O := O + '\\';
      #8: O := O + '\b';
      #9: O := O + '\t';
      #10: O := O + '\n';
      #12: O := O + '\f';
      #13: O := O + '\r';
    else
      if Ord(c) < 32 then
        O := O + '\u' + IntToHex(Ord(c), 4)
      else
        O := O + c;
    end;
  end;
  O := O + '"';
end;

function JsonNodeText(V: TJsonVal): string;
var
  i: Integer;
begin
  if V = nil then Exit('null');
  case V.Kind of
    jkNull: Result := 'null';
    jkBool: if V.B then Result := 'true' else Result := 'false';
    jkNum: Result := VDbFloatToStr(V.Num);
    jkStr:
      begin
        Result := '';
        JsonAppendEscaped(V.Str, Result);
      end;
    jkArr:
      begin
        Result := '[';
        for i := 0 to High(V.Items) do
        begin
          if i > 0 then Result := Result + ',';
          Result := Result + JsonNodeText(V.Items[i]);
        end;
        Result := Result + ']';
      end;
    jkObj:
      begin
        Result := '{';
        for i := 0 to High(V.Items) do
        begin
          if i > 0 then Result := Result + ',';
          JsonAppendEscaped(V.Keys[i], Result);
          Result := Result + ':' + JsonNodeText(V.Items[i]);
        end;
        Result := Result + '}';
      end;
  end;
end;

function JsonWildcardText(V: TJsonVal): string;
var
  i: Integer;
begin
  Result := '[';
  for i := 0 to High(V.Items) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + JsonNodeText(V.Items[i]);
  end;
  Result := Result + ']';
end;

{ M10 genisletme (2026-10-19): coklu dugum JSONPath degerlendiricisi.
  Destek: $ .ad ["ad"] [n] [a:b] [*] .* ..ad ..* [?(@.alan op literal)]
  op: = == != < <= > >= ; literal: sayi, 'metin', "metin", true/false/null.
  Filtre birlesimi: && (yuksek oncelik), ||, tek terim ! (parantez opsiyonel).
  Joker/filtre/recursive/slice adimlari coklu sonuc uretir; Get bunlari
  JSON dizi olarak dondurur. }

type
  TJsonNodeList = array of TJsonVal;
  TJsonLitKind = (jlNone, jlNum, jlStr, jlBool, jlNull);
  TJsonPred = record
    Fields: TStrArray;
    Op: string;
    LitKind: TJsonLitKind;
    Num: Double;
    Bool: Boolean;
    Str: string;
  end;
  { M10 (2026-10-19): JSONPath union secici ogesi: [0,2] veya ['a','b']. }
  TJsonUnionItem = record
    IsKey: Boolean;
    Key: string;
    Index: Integer;
  end;

procedure JsonAddNode(var L: TJsonNodeList; V: TJsonVal);
begin
  if V = nil then Exit;
  SetLength(L, Length(L) + 1);
  L[High(L)] := V;
end;

function JsonFieldOf(V: TJsonVal; const K: string): TJsonVal;
var
  i: Integer;
begin
  Result := nil;
  if (V = nil) or (V.Kind <> jkObj) then Exit;
  for i := 0 to High(V.Keys) do
    if V.Keys[i] = K then Exit(V.Items[i]);
end;

procedure JsonChildrenOf(V: TJsonVal; var L: TJsonNodeList);
var
  i: Integer;
begin
  if V = nil then Exit;
  if V.Kind = jkObj then
  begin
    for i := 0 to High(V.Items) do JsonAddNode(L, V.Items[i]);
  end
  else if V.Kind = jkArr then
    for i := 0 to High(V.Items) do JsonAddNode(L, V.Items[i]);
end;

procedure JsonCollectKey(V: TJsonVal; const K: string; var L: TJsonNodeList);
var
  i: Integer;
begin
  if V = nil then Exit;
  if V.Kind = jkObj then
  begin
    for i := 0 to High(V.Keys) do
    begin
      if V.Keys[i] = K then JsonAddNode(L, V.Items[i]);
      JsonCollectKey(V.Items[i], K, L);
    end;
  end
  else if V.Kind = jkArr then
    for i := 0 to High(V.Items) do
      JsonCollectKey(V.Items[i], K, L);
end;

procedure JsonCollectAll(V: TJsonVal; var L: TJsonNodeList);
var
  i: Integer;
begin
  if V = nil then Exit;
  if V.Kind = jkObj then
  begin
    for i := 0 to High(V.Items) do
    begin
      JsonAddNode(L, V.Items[i]);
      JsonCollectAll(V.Items[i], L);
    end;
  end
  else if V.Kind = jkArr then
    for i := 0 to High(V.Items) do
    begin
      JsonAddNode(L, V.Items[i]);
      JsonCollectAll(V.Items[i], L);
    end;
end;

function JsonParsePred(const S: string; out Pred: TJsonPred): Boolean;
var
  p, n, st: Integer;
  qch: Char;

  procedure SkipWs;
  begin
    while (p <= n) and (S[p] = ' ') do Inc(p);
  end;

  function ReadWord: string;
  begin
    Result := '';
    while (p <= n) and (S[p] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) do
    begin
      Result := Result + S[p];
      Inc(p);
    end;
  end;
begin
  Result := False;
  Pred := Default(TJsonPred);
  SetLength(Pred.Fields, 0);
  p := 1;
  n := Length(S);
  if n = 0 then Exit;
  SkipWs;
  if (p > n) or (S[p] <> '@') then Exit;
  Inc(p);
  while (p <= n) and (S[p] = '.') do
  begin
    Inc(p);
    st := p;
    while (p <= n) and (S[p] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) do
      Inc(p);
    if p = st then Exit;
    SetLength(Pred.Fields, Length(Pred.Fields) + 1);
    Pred.Fields[High(Pred.Fields)] := Copy(S, st, p - st);
  end;
  SkipWs;
  if p > n then Exit(True);   // yalniz @... -> dogruluk testi
  // operator
  if Copy(S, p, 2) = '==' then begin Pred.Op := '='; Inc(p, 2); end
  else if Copy(S, p, 2) = '!=' then begin Pred.Op := '!='; Inc(p, 2); end
  else if Copy(S, p, 2) = '<=' then begin Pred.Op := '<='; Inc(p, 2); end
  else if Copy(S, p, 2) = '>=' then begin Pred.Op := '>='; Inc(p, 2); end
  else if (p <= n) and (S[p] = '=') then begin Pred.Op := '='; Inc(p); end
  else if (p <= n) and (S[p] = '<') then begin Pred.Op := '<'; Inc(p); end
  else if (p <= n) and (S[p] = '>') then begin Pred.Op := '>'; Inc(p); end
  else Exit;
  SkipWs;
  if p > n then Exit;
  // literal
  if S[p] in ['''', '"'] then
  begin
    Pred.LitKind := jlStr;
    qch := S[p];
    Inc(p);
    Pred.Str := '';
    while (p <= n) and (S[p] <> qch) do
    begin
      if (S[p] = '\') and (p < n) then
      begin
        Inc(p);
        case S[p] of
          'n': Pred.Str := Pred.Str + #10;
          't': Pred.Str := Pred.Str + #9;
          'r': Pred.Str := Pred.Str + #13;
        else
          Pred.Str := Pred.Str + S[p];
        end;
      end
      else
        Pred.Str := Pred.Str + S[p];
      Inc(p);
    end;
    if p > n then Exit;
    Inc(p);
  end
  else if (S[p] = '-') or (S[p] in ['0'..'9']) then
  begin
    st := p;
    if S[p] = '-' then Inc(p);
    while (p <= n) and (S[p] in ['0'..'9', '.', 'e', 'E', '+', '-']) do
      Inc(p);
    if not VDbParseFloat(Copy(S, st, p - st), Pred.Num) then Exit;
    Pred.LitKind := jlNum;
  end
  else
  begin
    st := p;
    Pred.Str := UpperCase(ReadWord);
    if st = p then Exit;
    if Pred.Str = 'TRUE' then begin Pred.LitKind := jlBool; Pred.Bool := True; end
    else if Pred.Str = 'FALSE' then begin Pred.LitKind := jlBool; Pred.Bool := False; end
    else if Pred.Str = 'NULL' then Pred.LitKind := jlNull
    else Exit;
  end;
  SkipWs;
  Result := p > n;
end;

function JsonPredMatch(V: TJsonVal; const P: TJsonPred): Boolean;
var
  t: TJsonVal;
  i, cmp: Integer;
begin
  Result := False;
  t := V;
  for i := 0 to High(P.Fields) do
  begin
    t := JsonFieldOf(t, P.Fields[i]);
    if t = nil then Exit;
  end;
  if t = nil then Exit;
  if P.Op = '' then
  begin
    case t.Kind of
      jkNull: Exit(False);
      jkBool: Exit(t.B);
      jkNum: Exit(t.Num <> 0);
      jkStr: Exit(t.Str <> '');
    else
      Exit(True);
    end;
  end;
  cmp := 0;
  case P.LitKind of
    jlNull:
      begin
        if t.Kind <> jkNull then Exit(P.Op = '!=');
        cmp := 0;
      end;
    jlBool:
      begin
        if t.Kind <> jkBool then Exit(False);
        if t.B <> P.Bool then cmp := 1 else cmp := 0;
      end;
    jlNum:
      begin
        if t.Kind <> jkNum then Exit(False);
        if t.Num < P.Num then cmp := -1
        else if t.Num > P.Num then cmp := 1
        else cmp := 0;
      end;
    jlStr:
      begin
        if t.Kind <> jkStr then Exit(False);
        cmp := CompareStr(t.Str, P.Str);
        if cmp < 0 then cmp := -1 else if cmp > 0 then cmp := 1;
      end;
  else
    Exit(False);
  end;
  if P.Op = '=' then Exit(cmp = 0);
  if P.Op = '!=' then Exit(cmp <> 0);
  if P.Op = '<' then Exit(cmp < 0);
  if P.Op = '<=' then Exit(cmp <= 0);
  if P.Op = '>' then Exit(cmp > 0);
  if P.Op = '>=' then Exit(cmp >= 0);
end;

{ M10 (2026-10-19): filtre mantiksal birlesimi.
  Destek: terimler arasi && / || (&& daha yuksek oncelik) ve tek terim
  negasyonu (!). Parantez yalnizca tek terimi sarabilir; compound grouping
  henuz yok. }
type
  TJsonPredTermRec = record
    Pred: TJsonPred;
    Negate: Boolean;
  end;
  TJsonPredList = record
    Terms: array of TJsonPredTermRec;
    Joins: array of Char;   // Terms-1 adet: '&' veya '|'
  end;

function JsonStripOuterParens(const S: string; out Inner: string): Boolean;
var
  i, n, depth: Integer;
  q: Char;
  esc: Boolean;
begin
  Inner := S;
  n := Length(S);
  Result := True;
  if (n < 2) or (S[1] <> '(') or (S[n] <> ')') then Exit;
  depth := 0;
  q := #0;
  esc := False;
  for i := 1 to n do
  begin
    if q <> #0 then
    begin
      if esc then esc := False
      else if S[i] = '\' then esc := True
      else if S[i] = q then q := #0;
      Continue;
    end;
    if S[i] in ['''', '"'] then
    begin
      q := S[i];
      Continue;
    end;
    if S[i] = '(' then Inc(depth)
    else if S[i] = ')' then
    begin
      Dec(depth);
      if depth = 0 then
      begin
        // Yalnizca tum ifadeyi saran tek cift ise soy.
        if i <> n then Exit;
        Inner := Copy(S, 2, n - 2);
        Exit;
      end;
    end;
  end;
end;

function JsonParsePredList(const S: string; out L: TJsonPredList): Boolean;
var
  n, p, st, depth: Integer;
  q, j: Char;
  esc: Boolean;

  function AddPart(const Raw: string; J: Char): Boolean;
  var
    t, inner: string;
    neg: Boolean;
    pr: TJsonPred;
  begin
    Result := False;
    t := Trim(Raw);
    if t = '' then Exit;
    neg := False;
    if t[1] = '!' then
    begin
      neg := True;
      Delete(t, 1, 1);
      t := Trim(t);
    end;
    if not JsonStripOuterParens(t, inner) then Exit;
    t := inner;
    if not JsonParsePred(t, pr) then Exit;
    SetLength(L.Terms, Length(L.Terms) + 1);
    L.Terms[High(L.Terms)].Pred := pr;
    L.Terms[High(L.Terms)].Negate := neg;
    if J <> #0 then
    begin
      SetLength(L.Joins, Length(L.Joins) + 1);
      L.Joins[High(L.Joins)] := J;
    end;
    Result := True;
  end;

begin
  Result := False;
  L := Default(TJsonPredList);
  n := Length(S);
  if n = 0 then Exit;
  p := 1;
  st := 1;
  depth := 0;
  q := #0;
  esc := False;
  j := #0;
  while p <= n do
  begin
    if q <> #0 then
    begin
      if esc then esc := False
      else if S[p] = '\' then esc := True
      else if S[p] = q then q := #0;
      Inc(p);
      Continue;
    end;
    if S[p] in ['''', '"'] then
    begin
      q := S[p];
      Inc(p);
      Continue;
    end;
    if S[p] = '(' then
    begin
      Inc(depth);
      Inc(p);
      Continue;
    end;
    if S[p] = ')' then
    begin
      if depth > 0 then Dec(depth);
      Inc(p);
      Continue;
    end;
    if (depth = 0) and (p < n) and
       ((Copy(S, p, 2) = '&&') or (Copy(S, p, 2) = '||')) then
    begin
      if not AddPart(Copy(S, st, p - st), j) then Exit;
      if Copy(S, p, 2) = '&&' then j := '&' else j := '|';
      Inc(p, 2);
      st := p;
      Continue;
    end;
    Inc(p);
  end;
  if (q <> #0) or (depth <> 0) then Exit;
  if not AddPart(Copy(S, st, n - st + 1), j) then Exit;
  Result := True;
end;

function JsonPredListMatch(V: TJsonVal; const L: TJsonPredList): Boolean;
var
  i: Integer;
  andRes, term: Boolean;
begin
  Result := False;
  if Length(L.Terms) = 0 then Exit;
  andRes := JsonPredMatch(V, L.Terms[0].Pred);
  if L.Terms[0].Negate then andRes := not andRes;
  for i := 1 to High(L.Terms) do
  begin
    term := JsonPredMatch(V, L.Terms[i].Pred);
    if L.Terms[i].Negate then term := not term;
    if (i - 1 <= High(L.Joins)) and (L.Joins[i - 1] = '|') then
    begin
      Result := Result or andRes;
      andRes := term;
    end
    else
      andRes := andRes and term;
  end;
  Result := Result or andRes;
end;

function JsonParseQuotedItem(const S: string; out V: string): Boolean;
var
  i, n: Integer;
  q: Char;
begin
  Result := False;
  V := '';
  n := Length(S);
  if n < 2 then Exit;
  q := S[1];
  if (q <> '''') and (q <> '"') then Exit;
  if S[n] <> q then Exit;
  i := 2;
  while i < n do
  begin
    if S[i] = '\' then
    begin
      Inc(i);
      if i >= n then Exit;
      case S[i] of
        'n': V := V + #10;
        't': V := V + #9;
        'r': V := V + #13;
        'b': V := V + #8;
        'f': V := V + #12;
      else
        V := V + S[i];
      end;
      Inc(i);
    end
    else
    begin
      V := V + S[i];
      Inc(i);
    end;
  end;
  Result := True;
end;

function JsonParseUnionItem(const S: string; out Item: TJsonUnionItem): Boolean;
var
  t: string;
begin
  Result := False;
  Item := Default(TJsonUnionItem);
  t := Trim(S);
  if t = '' then Exit;
  if t[1] in ['''', '"'] then
  begin
    if not JsonParseQuotedItem(t, Item.Key) then Exit;
    Item.IsKey := True;
  end
  else
  begin
    if not TryStrToInt(t, Item.Index) then Exit;
    Item.IsKey := False;
  end;
  Result := True;
end;

function JsonSplitUnion(const S: string; out Parts: TStrArray): Boolean;
var
  p, n, st: Integer;
  q: Char;
begin
  Result := False;
  SetLength(Parts, 0);
  p := 1;
  n := Length(S);
  while p <= n do
  begin
    while (p <= n) and (S[p] = ' ') do Inc(p);
    if p > n then Exit;
    st := p;
    if S[p] in ['''', '"'] then
    begin
      q := S[p];
      Inc(p);
      while (p <= n) and (S[p] <> q) do
      begin
        if S[p] = '\' then Inc(p);
        if p <= n then Inc(p);
      end;
      if p > n then Exit;
      Inc(p);
      while (p <= n) and (S[p] = ' ') do Inc(p);
    end
    else
      while (p <= n) and (S[p] <> ',') do Inc(p);
    SetLength(Parts, Length(Parts) + 1);
    Parts[High(Parts)] := Trim(Copy(S, st, p - st));
    if (p <= n) and (S[p] = ',') then
    begin
      Inc(p);
      if p > n then Exit;
    end
    else if p <= n then
      Exit;
  end;
  Result := Length(Parts) > 0;
end;

function JsonNodesText(const N: TJsonNodeList): string;
var
  i: Integer;
begin
  Result := '[';
  for i := 0 to High(N) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + JsonNodeText(N[i]);
  end;
  Result := Result + ']';
end;

function JsonPathSelect(Root: TJsonVal; const Path: string;
  out Nodes: TJsonNodeList; out Multi: Boolean): Boolean;
var
  p, n, i, j, k, st, idx, aa, bb, cnt, depth: Integer;
  q: Char;
  esc: Boolean;
  cur, nxt: TJsonNodeList;
  name, pred: string;
  pl: TJsonPredList;
  parts: TStrArray;
  ui: TJsonUnionItem;
begin
  Result := False;
  SetLength(Nodes, 0);
  Multi := False;
  n := Length(Path);
  if (n < 1) or (Path[1] <> '$') then Exit;
  SetLength(cur, 1);
  cur[0] := Root;
  p := 2;
  while p <= n do
  begin
    SetLength(nxt, 0);
    if Path[p] = '.' then
    begin
      if (p < n) and (Path[p + 1] = '.') then
      begin
        Multi := True;
        Inc(p, 2);
        if (p <= n) and (Path[p] = '*') then
        begin
          Inc(p);
          for i := 0 to High(cur) do JsonCollectAll(cur[i], nxt);
        end
        else
        begin
          st := p;
          while (p <= n) and (Path[p] <> '.') and (Path[p] <> '[') do Inc(p);
          if p = st then Exit;
          name := Copy(Path, st, p - st);
          for i := 0 to High(cur) do JsonCollectKey(cur[i], name, nxt);
        end;
      end
      else
      begin
        Inc(p);
        if (p <= n) and (Path[p] = '*') then
        begin
          Inc(p);
          Multi := True;
          for i := 0 to High(cur) do JsonChildrenOf(cur[i], nxt);
        end
        else
        begin
          st := p;
          while (p <= n) and (Path[p] <> '.') and (Path[p] <> '[') do Inc(p);
          if p = st then Exit;
          name := Copy(Path, st, p - st);
          for i := 0 to High(cur) do
            JsonAddNode(nxt, JsonFieldOf(cur[i], name));
        end;
      end;
    end
    else if Path[p] = '[' then
    begin
      Inc(p);
      if (p <= n) and (Path[p] = '*') then
      begin
        Inc(p);
        if (p > n) or (Path[p] <> ']') then Exit;
        Inc(p);
        Multi := True;
        for i := 0 to High(cur) do JsonChildrenOf(cur[i], nxt);
      end
      else if (p < n) and (Path[p] = '?') and (Path[p + 1] = '(') then
      begin
        Inc(p, 2);
        st := p;
        depth := 1;
        q := #0;
        esc := False;
        while p <= n do
        begin
          if q <> #0 then
          begin
            if esc then esc := False
            else if Path[p] = '\' then esc := True
            else if Path[p] = q then q := #0;
            Inc(p);
            Continue;
          end;
          if Path[p] in ['''', '"'] then
          begin
            q := Path[p];
            Inc(p);
            Continue;
          end;
          if Path[p] = '(' then Inc(depth)
          else if Path[p] = ')' then
          begin
            Dec(depth);
            if depth = 0 then Break;
          end;
          Inc(p);
        end;
        if p > n then Exit;
        pred := Copy(Path, st, p - st);
        Inc(p);
        if (p > n) or (Path[p] <> ']') then Exit;
        Inc(p);
        if not JsonParsePredList(pred, pl) then Exit;
        Multi := True;
        for i := 0 to High(cur) do
          if (cur[i] <> nil) and (cur[i].Kind = jkArr) then
            for j := 0 to High(cur[i].Items) do
              if JsonPredListMatch(cur[i].Items[j], pl) then
                JsonAddNode(nxt, cur[i].Items[j]);
      end
      else
      begin
        st := p;
        while (p <= n) and (Path[p] <> ']') do Inc(p);
        if p > n then Exit;
        name := Copy(Path, st, p - st);
        Inc(p);
        if Pos(',', name) > 0 then
        begin
          Multi := True;
          if not JsonSplitUnion(name, parts) then Exit;
          for k := 0 to High(parts) do
          begin
            if not JsonParseUnionItem(parts[k], ui) then Exit;
            for i := 0 to High(cur) do
            begin
              if cur[i] = nil then Continue;
              if ui.IsKey then
              begin
                if cur[i].Kind = jkObj then
                  JsonAddNode(nxt, JsonFieldOf(cur[i], ui.Key));
              end
              else if cur[i].Kind = jkArr then
              begin
                j := ui.Index;
                if j < 0 then Inc(j, Length(cur[i].Items));
                if (j >= 0) and (j <= High(cur[i].Items)) then
                  JsonAddNode(nxt, cur[i].Items[j]);
              end;
            end;
          end;
        end
        else if (Length(name) >= 2) and
                (name[1] in ['''', '"']) and
                (name[Length(name)] = name[1]) then
        begin
          if not JsonParseUnionItem(name, ui) then Exit;
          for i := 0 to High(cur) do
            if (cur[i] <> nil) and (cur[i].Kind = jkObj) then
              JsonAddNode(nxt, JsonFieldOf(cur[i], ui.Key));
        end
        else if Pos(':', name) > 0 then
        begin
          Multi := True;
          j := Pos(':', name);
          if j > 1 then
          begin
            if not TryStrToInt(Copy(name, 1, j - 1), aa) then Exit;
          end
          else
            aa := 0;
          if j < Length(name) then
          begin
            if not TryStrToInt(Copy(name, j + 1, MaxInt), bb) then Exit;
          end
          else
            bb := MaxInt;
          for i := 0 to High(cur) do
            if (cur[i] <> nil) and (cur[i].Kind = jkArr) then
            begin
              cnt := Length(cur[i].Items);
              j := aa;
              if j < 0 then Inc(j, cnt);
              if j < 0 then j := 0;
              st := bb;
              if st < 0 then Inc(st, cnt);
              if st > cnt then st := cnt;
              while (j < st) and (j <= High(cur[i].Items)) do
              begin
                if j >= 0 then JsonAddNode(nxt, cur[i].Items[j]);
                Inc(j);
              end;
            end;
        end
        else
        begin
          if not TryStrToInt(name, idx) then Exit;
          for i := 0 to High(cur) do
            if (cur[i] <> nil) and (cur[i].Kind = jkArr) then
            begin
              j := idx;
              if j < 0 then Inc(j, Length(cur[i].Items));
              if (j >= 0) and (j <= High(cur[i].Items)) then
                JsonAddNode(nxt, cur[i].Items[j]);
            end;
        end;
      end;
    end
    else
      Exit;
    cur := nxt;
  end;
  Nodes := cur;
  Result := True;
end;

function JsonPathNeedsAdvanced(const Path: string): Boolean;
var
  i: Integer;
begin
  Result := True;
  if Pos('..', Path) > 0 then Exit;
  if Pos('[?', Path) > 0 then Exit;
  if Pos(':', Path) > 0 then Exit;
  if Pos(',', Path) > 0 then Exit;
  if Pos('''', Path) > 0 then Exit;
  i := Pos('.*', Path);
  if (i > 0) and (i + 2 <= Length(Path)) then Exit;
  i := Pos('[*]', Path);
  if (i > 0) and (i + 3 <= Length(Path)) then Exit;
  Result := False;
end;

function JsonPathNavigate(Root: TJsonVal; const Path: string;
  out Node: TJsonVal; out Wildcard: Boolean): Boolean;

  function FindKey(V: TJsonVal; const K: string): TJsonVal;
  var
    i: Integer;
  begin
    Result := nil;
    if (V = nil) or (V.Kind <> jkObj) then Exit;
    for i := 0 to High(V.Keys) do
      if V.Keys[i] = K then Exit(V.Items[i]);
  end;

var
  p, n, st, idx: Integer;
  name: string;
  cur: TJsonVal;
begin
  Result := False;
  Node := nil;
  Wildcard := False;
  n := Length(Path);
  if (n < 1) or (Path[1] <> '$') then Exit;
  cur := Root;
  p := 2;
  while p <= n do
  begin
    if Path[p] = '.' then
    begin
      Inc(p);
      if (p <= n) and (Path[p] = '*') then
      begin
        Inc(p);
        if p <= n then Exit;   // joker yalniz son segment
        if (cur = nil) or
           ((cur.Kind <> jkArr) and (cur.Kind <> jkObj)) then Exit;
        Node := cur;
        Wildcard := True;
        Exit(True);
      end;
      st := p;
      while (p <= n) and (Path[p] <> '.') and (Path[p] <> '[') do Inc(p);
      if p = st then Exit;
      name := Copy(Path, st, p - st);
      cur := FindKey(cur, name);
      if cur = nil then Exit;
    end
    else if Path[p] = '[' then
    begin
      Inc(p);
      if (p <= n) and (Path[p] = '"') then
      begin
        Inc(p);
        name := '';
        while (p <= n) and (Path[p] <> '"') do
        begin
          if (Path[p] = '\') and (p < n) then
          begin
            Inc(p);
            name := name + Path[p];
          end
          else
            name := name + Path[p];
          Inc(p);
        end;
        if p > n then Exit;
        Inc(p);  // kapanis tirnagi
        if (p > n) or (Path[p] <> ']') then Exit;
        Inc(p);
        cur := FindKey(cur, name);
        if cur = nil then Exit;
      end
      else
      begin
        st := p;
        if (p <= n) and (Path[p] = '-') then Inc(p);
        while (p <= n) and (Path[p] in ['0'..'9']) do Inc(p);
        if (p <= n) and (Path[p] = '*') then
        begin
          Inc(p);
          if (p > n) or (Path[p] <> ']') then Exit;
          Inc(p);
          if p <= n then Exit;
          if (cur = nil) or (cur.Kind <> jkArr) then Exit;
          Node := cur;
          Wildcard := True;
          Exit(True);
        end;
        if (p > n) or (Path[p] <> ']') then Exit;
        if not TryStrToInt(Copy(Path, st, p - st), idx) then Exit;
        Inc(p);
        if (cur = nil) or (cur.Kind <> jkArr) then Exit;
        if idx < 0 then idx := Length(cur.Items) + idx;
        if (idx < 0) or (idx > High(cur.Items)) then Exit;
        cur := cur.Items[idx];
      end;
    end
    else
      Exit;
  end;
  Node := cur;
  Result := Node <> nil;
end;

function VDbJsonPathGet(const Json, Path: string; out OutText: string): Boolean;
var
  root, node: TJsonVal;
  wild: Boolean;
  nodes: TJsonNodeList;
  multi: Boolean;
begin
  Result := False;
  OutText := '';
  if not VDbJsonParse(Json, root) then Exit;
  try
    if JsonPathNeedsAdvanced(Path) then
    begin
      if not JsonPathSelect(root, Path, nodes, multi) then Exit;
      if Length(nodes) = 0 then Exit;
      if multi then OutText := JsonNodesText(nodes)
      else OutText := JsonNodeText(nodes[0]);
      Result := True;
      Exit;
    end;
    if not JsonPathNavigate(root, Path, node, wild) then Exit;
    if wild then
      OutText := JsonWildcardText(node)
    else
      OutText := JsonNodeText(node);
    Result := True;
  finally
    VDbJsonFree(root);
  end;
end;

function VDbJsonPathScalar(const Json, Path: string; out OutText: string): Boolean;
var
  root, node: TJsonVal;
  wild: Boolean;
  nodes: TJsonNodeList;
  multi: Boolean;
begin
  Result := False;
  OutText := '';
  if not VDbJsonParse(Json, root) then Exit;
  try
    if JsonPathNeedsAdvanced(Path) then
    begin
      if not JsonPathSelect(root, Path, nodes, multi) then Exit;
      if multi or (Length(nodes) <> 1) then Exit;
      node := nodes[0];
      if node = nil then Exit;
      case node.Kind of
        jkNull: OutText := '';
        jkBool: OutText := BoolToStr(node.B, True);
        jkNum: OutText := VDbFloatToStr(node.Num);
        jkStr: OutText := node.Str;
      else
        Exit;
      end;
      Result := True;
      Exit;
    end;
    if not JsonPathNavigate(root, Path, node, wild) then Exit;
    if wild or (node = nil) then Exit;
    case node.Kind of
      jkNull: OutText := '';
      jkBool: OutText := BoolToStr(node.B, True);
      jkNum: OutText := VDbFloatToStr(node.Num);
      jkStr: OutText := node.Str;
    else
      Exit;   // nesne/dizi skaler degildir
    end;
    Result := True;
  finally
    VDbJsonFree(root);
  end;
end;

function VDbJsonPathExists(const Json, Path: string): Boolean;
var
  root, node: TJsonVal;
  wild: Boolean;
  nodes: TJsonNodeList;
  multi: Boolean;
begin
  Result := False;
  if not VDbJsonParse(Json, root) then Exit;
  try
    if JsonPathNeedsAdvanced(Path) then
    begin
      Result := JsonPathSelect(root, Path, nodes, multi) and
        (Length(nodes) > 0);
      Exit;
    end;
    Result := JsonPathNavigate(root, Path, node, wild);
  finally
    VDbJsonFree(root);
  end;
end;

function VDbJsonNumArray(const S: string; out Vals: TDoubleArray): Boolean;
var
  V: TJsonVal;
  i: Integer;
begin
  Result := False;
  SetLength(Vals, 0);
  if not VDbJsonParse(S, V) then Exit;
  try
    if (V = nil) or (V.Kind <> jkArr) then Exit;
    SetLength(Vals, Length(V.Items));
    for i := 0 to High(V.Items) do
    begin
      if V.Items[i].Kind <> jkNum then
      begin
        SetLength(Vals, 0);
        Exit;
      end;
      Vals[i] := V.Items[i].Num;
    end;
    Result := True;
  finally
    VDbJsonFree(V);
  end;
end;

function VDbCtypeName(C: Byte): string;
begin
  case C of
    VCT_INT: Result := 'INTEGER';
    VCT_FLOAT: Result := 'FLOAT';
    VCT_BOOL: Result := 'BOOLEAN';
    VCT_DATE: Result := 'DATE';
    VCT_DATETIME: Result := 'DATETIME';
    VCT_TIME: Result := 'TIME';
    VCT_BLOB: Result := 'BLOB';
  else
    Result := 'TEXT';
  end;
end;

function VDbCtypeByName(const S: string): Byte;
var
  u: string;
begin
  u := UpperCase(Trim(S));
  if (u = 'INTEGER') or (u = 'INT') then Exit(VCT_INT);
  if (u = 'FLOAT') or (u = 'DOUBLE') or (u = 'REAL') then Exit(VCT_FLOAT);
  if (u = 'BOOLEAN') or (u = 'BOOL') then Exit(VCT_BOOL);
  if u = 'DATE' then Exit(VCT_DATE);
  if (u = 'DATETIME') or (u = 'TIMESTAMP') then Exit(VCT_DATETIME);
  if u = 'TIME' then Exit(VCT_TIME);
  if (u = 'BLOB') or (u = 'BINARY') then Exit(VCT_BLOB);
  Result := VCT_STR;
end;

function JsEsc(const S: RawByteString): RawByteString;
var
  i: Integer;
  c: Byte;
begin
  Result := '"';
  for i := 1 to Length(S) do
  begin
    c := Byte(S[i]);
    case c of
      34: Result := Result + '\"';
      92: Result := Result + '\\';
      8: Result := Result + '\b';
      9: Result := Result + '\t';
      10: Result := Result + '\n';
      12: Result := Result + '\f';
      13: Result := Result + '\r';
    else
      if c < 32 then
        Result := Result + '\u' + IntToHex(c, 4)
      else
        Result := Result + AnsiChar(c);
    end;
  end;
  Result := Result + '"';
end;

procedure SortStr(var A: TStrArray);
  procedure Sort(L, H: Integer);
  var
    i, j: Integer;
    pv, tp: string;
  begin
    i := L; j := H; pv := A[(L + H) div 2];
    repeat
      while CompareStr(A[i], pv) < 0 do Inc(i);
      while CompareStr(A[j], pv) > 0 do Dec(j);
      if i <= j then
      begin tp := A[i]; A[i] := A[j]; A[j] := tp; Inc(i); Dec(j); end;
    until i > j;
    if L < j then Sort(L, j);
    if i < H then Sort(i, H);
  end;
begin
  if Length(A) > 1 then Sort(0, High(A));
end;

procedure WriteRaw(S: TFileStream; const T: RawByteString);
begin
  if Length(T) > 0 then
    S.WriteBuffer(T[1], Length(T));
end;

procedure VDbExportJson(Tb: TVTableDb; const Path, Table: string);
var
  names: TStrArray;
  ti, i, j: Integer;
  td: TTableDef;
  pks: TStrArray;
  rows: TStrMatrix;
  order: array of Integer;
  sw: Integer;
  tmp: TFileStream;
  tmpPath: string;
  first: Boolean;
begin
  if Table = '' then
    names := Tb.TableNames
  else
  begin
    SetLength(names, 1);
    names[0] := VDbNorm(Table);
    Tb.GetTable(names[0]); // yoksa hata
  end;
  SortStr(names);
  tmpPath := Path + '.tmp';
  if FileExists(tmpPath) then DeleteFile(tmpPath);
  tmp := TFileStream.Create(tmpPath, fmCreate);
  try
    WriteRaw(tmp, '{"tables":[');
    first := True;
    for ti := 0 to High(names) do
    begin
      td := Tb.GetTable(names[ti]);
      Tb.ScanRows(td.Name, pks, rows);
      // kanonik satir sirasi: PK string sirasi
      SetLength(order, Length(pks));
      for i := 0 to High(order) do order[i] := i;
      for i := 1 to High(order) do
      begin
        j := i;
        while (j > 0) and (CompareStr(pks[order[j]], pks[order[j - 1]]) < 0) do
        begin
          sw := order[j]; order[j] := order[j - 1]; order[j - 1] := sw;
          Dec(j);
        end;
      end;
      if not first then WriteRaw(tmp, ',');
      first := False;
      WriteRaw(tmp, '{"name":' + JsEsc(UTF8Encode(td.Name)) + ',"cols":[');
      for i := 0 to High(td.Cols) do
      begin
        if i > 0 then WriteRaw(tmp, ',');
        WriteRaw(tmp, '{"name":' + JsEsc(UTF8Encode(td.Cols[i].Name)) +
          ',"type":' + JsEsc(UTF8Encode(VDbCtypeName(td.Cols[i].Ctype))));
        if td.Cols[i].NotNull then WriteRaw(tmp, ',"notnull":true');
        if td.Cols[i].Unique then WriteRaw(tmp, ',"unique":true');
        if td.Cols[i].HasDef then
          WriteRaw(tmp, ',"default":' + JsEsc(UTF8Encode(td.Cols[i].Def)));
        WriteRaw(tmp, '}');
      end;
      WriteRaw(tmp, '],"pk":' + IntToStr(td.PkIndex));
      WriteRaw(tmp, ',"checks":[');
      for i := 0 to High(td.Checks) do
      begin
        if i > 0 then WriteRaw(tmp, ',');
        WriteRaw(tmp, '[');
        for j := 0 to High(td.Checks[i]) do
        begin
          if j > 0 then WriteRaw(tmp, ',');
          WriteRaw(tmp, '{"col":' + IntToStr(td.Checks[i][j].Col) +
            ',"op":' + JsEsc(UTF8Encode(td.Checks[i][j].Op)) +
            ',"val":' + JsEsc(UTF8Encode(td.Checks[i][j].Val)) + '}');
        end;
        WriteRaw(tmp, ']');
      end;
      WriteRaw(tmp, '],"fks":[');
      for i := 0 to High(td.Fks) do
      begin
        if i > 0 then WriteRaw(tmp, ',');
        // ONEDEN/ONUPDATE burada YAZILMIYORDU; import sonrasi tum FK'lar
        // varsayilan RESTRICT olurdu. CASCADE/SETNULL kullanan tablolar
        // export -> import dongusunde sessizce davranis degistiriyordu.
        WriteRaw(tmp, '{"col":' + IntToStr(td.Fks[i].Col) +
          ',"reftable":' + JsEsc(UTF8Encode(td.Fks[i].RefTable)) +
          ',"refcol":' + JsEsc(UTF8Encode(td.Fks[i].RefCol)) +
          ',"ondelete":' + JsEsc(UTF8Encode(td.Fks[i].OnDelete)) +
          ',"onupdate":' + JsEsc(UTF8Encode(td.Fks[i].OnUpdate)) + '}');
      end;
      WriteRaw(tmp, '],"rows":[');
      for i := 0 to High(order) do
      begin
        if i > 0 then WriteRaw(tmp, ',');
        WriteRaw(tmp, '[');
        for j := 0 to High(td.Cols) do
        begin
          if j > 0 then WriteRaw(tmp, ',');
          if rows[order[i]][j] = '' then
            WriteRaw(tmp, 'null')
          else if Pos(#0, rows[order[i]][j]) > 0 then
            // #0 bayti fpjson tarafindan yutulur (\u0000 kaybi): hucre
            // hex-nesne olarak yazilir (hem BLOB hem TEXT icin gecerli,
            // sekle bakilarak ayirt edilir; eski dosyalar etkilenmez).
            WriteRaw(tmp, '{"$hex":' +
              JsEsc(VDbHex(RawByteString(rows[order[i]][j]))) + '}')
          else if td.Cols[j].Ctype = VCT_BLOB then
            // BLOB ham bayt yazar: UTF8Encode gecersiz UTF-8 dizilerini
            // U+FFFD'ye cevirerek ikili veriyi bozardi. JsEsc bayt
            // duzeyinde calisir (kontrol baytlari \u ile kacar).
            WriteRaw(tmp, JsEsc(RawByteString(rows[order[i]][j])))
          else
            WriteRaw(tmp, JsEsc(UTF8Encode(rows[order[i]][j])));
        end;
        WriteRaw(tmp, ']');
      end;
      WriteRaw(tmp, ']}');
    end;
    WriteRaw(tmp, ']}');
    VDbFlushStream(tmp);
  finally
    tmp.Free;
  end;
  if FileExists(Path) then DeleteFile(Path);
  if not RenameFile(tmpPath, Path) then
    raise EVDbException.Create(ecIOError, 'JSON yazilamadi: ' + Path);
end;

procedure VDbImportJson(Tb: TVTableDb; const Path: string);
var
  sl: TStringList;
  js: TJSONData;
  root: TJSONObject;
  tbls: TJSONArray;
  ti, i, j: Integer;
  to_: TJSONObject;
  co: TJSONObject;
  cols: TJSONArray;
  rws: TJSONArray;
  row: TJSONArray;
  tname: string;
  cnames: TStrArray;
  cvals: TStrArray;
  cdef: TColArray;
  v: TJSONData;
  sinceCommit: Integer;
  torder: array of Integer;
  tdone: array of Boolean;
  tnames: TStrArray;
  oi: Integer;
  progressed: Boolean;
  pkIdx: Integer;
  chkGroups: TWhereGroups;
  fkArr: TFkArray;

  function JStr(d: TJSONData): string;
  var
    raw: AnsiString;
  begin
    // fpjson UTF-8 cozmez, byte'lari genisletir (probe ile dogrulandi).
    // 1) AnsiString atamasi ham UTF-8 byte'lari birebir geri verir.
    // 2) UTF8Decode bunlari gercekten cozer.
    if (d = nil) or (d is TJSONNull) then
      Exit('');
    raw := AnsiString(d.AsString);
    Result := string(UTF8Decode(raw));
  end;

  function JRaw(d: TJSONData): RawByteString;
  // BLOB icin ham bayt (UTF8Decode YOK: ikili veri bozulurdu).
  begin
    if (d = nil) or (d is TJSONNull) then
      Exit('');
    Result := AnsiString(d.AsString);
  end;

  function JBool(o: TJSONObject; const Key: string): Boolean;
  var
    d: TJSONData;
  begin
    d := o.Find(Key);
    Result := (d <> nil) and not (d is TJSONNull) and
      (SameText(d.AsString, 'true') or (d.AsString = '1'));
  end;

  function DepsReady(Tbls: TJSONArray; Ti: Integer; const Names: TStrArray;
    const Done: array of Boolean; Tb: TVTableDb): Boolean;
  // Ti tablosunun FK hedefleri ya DB'de var ya da dosyada once kuruldu
  var
    o, f, m: Integer;
    to2: TJSONObject;
    fks: TJSONArray;
    rt: string;
  begin
    Result := True;
    to2 := Tbls.Objects[Ti];
    fks := to2.Arrays['fks'];
    if fks = nil then Exit;
    for f := 0 to fks.Count - 1 do
    begin
      rt := VDbNorm(fks.Objects[f].Strings['reftable']);
      if Tb.TableExists(rt) then Continue;
      m := -1;
      for o := 0 to High(Names) do
        if Names[o] = rt then
        begin m := o; Break; end;
      if (m >= 0) and not Done[m] then Exit(False);
    end;
  end;

begin
  sl := TStringList.Create;
  try
    sl.LoadFromFile(Path);
    js := GetJSON(sl.Text);
  finally
    sl.Free;
  end;
  try
    if not (js is TJSONObject) then
      raise EVDbException.Create(ecJsonError, 'JSON kok obje degil');
    root := TJSONObject(js);
    tbls := root.Arrays['tables'];
    if tbls = nil then
      raise EVDbException.Create(ecJsonError, 'tables yok');
    // FK bagimlilik sirasi (ebeveyn once)
    SetLength(torder, tbls.Count);
    SetLength(tdone, tbls.Count);
    SetLength(tnames, tbls.Count);
    for ti := 0 to tbls.Count - 1 do
    begin
      torder[ti] := -1;
      tdone[ti] := False;
      tnames[ti] := VDbNorm(TJSONObject(tbls.Objects[ti]).Strings['name']);
    end;
    oi := 0;
    while oi < tbls.Count do
    begin
      progressed := False;
      for ti := 0 to tbls.Count - 1 do
      begin
        if tdone[ti] then Continue;
        if DepsReady(tbls, ti, tnames, tdone, Tb) then
        begin
          torder[oi] := ti;
          Inc(oi);
          tdone[ti] := True;
          progressed := True;
        end;
      end;
      if not progressed then
        raise EVDbException.Create(ecForeignKeyViolation, 'dongusel FK bagimliligi');
    end;
    sinceCommit := 0;
    Tb.Kv.BeginBatch;
    try
      for oi := 0 to High(torder) do
      begin
        ti := torder[oi];
        to_ := tbls.Objects[ti];
        tname := VDbNorm(to_.Strings['name']);
        cols := to_.Arrays['cols'];
        rws := to_.Arrays['rows'];
        if (tname = '') or (cols = nil) or (rws = nil) then
          raise EVDbException.Create(ecJsonError, 'tablo formati bozuk');
        if not Tb.TableExists(tname) then
        begin
          SetLength(cdef, cols.Count);
          for i := 0 to cols.Count - 1 do
          begin
            co := cols.Objects[i];
            cdef[i].Name := VDbNorm(co.Strings['name']);
            cdef[i].Ctype := VDbCtypeByName(co.Strings['type']);
            cdef[i].NotNull := JBool(co, 'notnull');
            cdef[i].Unique := JBool(co, 'unique');
            v := co.Find('default');
            cdef[i].HasDef := (v <> nil) and not (v is TJSONNull);
            if cdef[i].HasDef then
              cdef[i].Def := JStr(v)
            else
              cdef[i].Def := '';
          end;
          pkIdx := to_.Get('pk', 0);
          // checks
          SetLength(chkGroups, 0);
          v := to_.Find('checks');
          if (v <> nil) and (v is TJSONArray) then
            for i := 0 to TJSONArray(v).Count - 1 do
            begin
              row := TJSONArray(v).Arrays[i];
              SetLength(chkGroups, Length(chkGroups) + 1);
              SetLength(chkGroups[High(chkGroups)], row.Count);
              for j := 0 to row.Count - 1 do
              begin
                co := row.Objects[j];
                chkGroups[High(chkGroups)][j].Col := co.Integers['col'];
                chkGroups[High(chkGroups)][j].Op := co.Strings['op'];
                chkGroups[High(chkGroups)][j].Val := JStr(co.Find('val'));
              end;
            end;
          // fks
          SetLength(fkArr, 0);
          v := to_.Find('fks');
          if (v <> nil) and (v is TJSONArray) then
            for i := 0 to TJSONArray(v).Count - 1 do
            begin
              co := TJSONArray(v).Objects[i];
              SetLength(fkArr, Length(fkArr) + 1);
              fkArr[High(fkArr)].Col := co.Integers['col'];
              fkArr[High(fkArr)].RefTable := VDbNorm(co.Strings['reftable']);
              fkArr[High(fkArr)].RefCol := VDbNorm(co.Strings['refcol']);
              // ONDELETE/ONUPDATE aksiyonlari. ESKI JSON dosyalarinda bu
              // alanlar yok -> bos gelir ve CreateTable varsayilani atar.
              fkArr[High(fkArr)].OnDelete :=
                VDbNorm(JStr(co.Find('ondelete')));
              fkArr[High(fkArr)].OnUpdate :=
                VDbNorm(JStr(co.Find('onupdate')));
            end;
          Tb.CreateTable(tname, cdef, pkIdx, chkGroups, fkArr);
        end;
        SetLength(cnames, Length(Tb.GetTable(tname).Cols));
        for i := 0 to High(cnames) do
          cnames[i] := Tb.GetTable(tname).Cols[i].Name;
        for i := 0 to rws.Count - 1 do
        begin
          row := rws.Arrays[i];
          if row.Count <> Length(cnames) then
            raise EVDbException.CreateFmt(ecJsonError, 'kolon sayisi uymadi (%s satir %d)', [tname, i]);
          SetLength(cvals, Length(cnames));
          for j := 0 to High(cnames) do
          begin
            v := row.Items[j];
            if (v is TJSONObject) and
               (TJSONObject(v).Find('$hex') <> nil) then
              // #0 iceren hucre (BLOB veya TEXT): hex coz.
              cvals[j] := string(VDbUnhex(TJSONObject(v).Strings['$hex']))
            else if Tb.GetTable(tname).Cols[j].Ctype = VCT_BLOB then
              cvals[j] := string(JRaw(v))
            else
              cvals[j] := JStr(v);
          end;
          Tb.Insert(tname, cnames, cvals);
          Inc(sinceCommit);
          if sinceCommit >= 5000 then
          begin
            Tb.CommitBatch;
            Tb.BeginBatch;
            sinceCommit := 0;
          end;
        end;
      end;
      Tb.CommitBatch;
    except
      Tb.AbortBatch;
      raise;
    end;
  finally
    js.Free;
  end;
end;

end.





