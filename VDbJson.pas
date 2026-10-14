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
      if not TryStrToFloat(numTxt, X.Num) then
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





