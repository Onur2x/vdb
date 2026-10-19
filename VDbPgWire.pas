unit VDbPgWire;

{ M1 (2026-10-19): PostgreSQL wire protocol (v3) — MINIMAL sunucu.

  Amac: mevcut PostgreSQL istemcilerinin (psql, bazi suruculer) VDB'ye
  "basit sorgu" (Simple Query, 'Q') ile baglanabilmesi.

  Desteklenen:
    - StartupMessage v3 (SSLRequest/GSSENCRequest -> 'N')
    - AuthenticationOk (trust; parola istenmez)
    - ParameterStatus (server_version, client_encoding, DateStyle,
      integer_datetimes)
    - BackendKeyData, ReadyForQuery
    - 'Q' simple query: RowDescription + DataRow* + CommandComplete
    - Extended query protocol: Parse ('P'), Bind ('B'), Describe ('D'),
      Execute ('E'), Close ('C'), Flush ('H'), Sync ('S').
      Prepared statement ve portal adlari desteklenir; Describe Portal
      sorguyu calistirip sonucu onbellege alir.
    - Sorgu parametreleri: PostgreSQL uyumlu $1, $2 ... (metin veya
      int2/int4/int8/float4/float8/bool binary). ParameterDescription
      ('t') gercek parametre sayisini/OID'lerini bildirir.
      `?` yer tutuculari da SQL API'siyle ayni sekilde desteklenir.
    - ErrorResponse + ReadyForQuery; hata sonrasi Sync'e kadar mesajlar
      yutulur (PostgreSQL semantigi).
    - 'X' Terminate
    - COPY ... FROM STDIN / COPY ... TO STDOUT / COPY (SELECT ...) TO STDOUT
      (basit sorgu; CSV/TEXT). FROM akisi gecici dosyaya yazilip mevcut COPY
      motoruna devredilir; TO akisi SELECT sonucundan CSV/TEXT satirlari
      olarak uretilir.

  DESTEKLENMEYEN (bilincli sinir):
    - Extended protocol uzerinden COPY; SSL/TLS; gercek sonuc tip OID'leri
      (tum alanlar TEXT/OID 25).
    - Binary sonuc formati istenirse hata dondurulur; sonuclar metindir.
    - NULL ile bos metin ayrimi: motor ikisini de '' olarak tutar;
      DataRow'da her ikisi de uzunluk 0 olarak gonderilir.
    - Numeric/date/time/timestamp gibi karmasik binary parametreler
      reddedilir; bu tipler metin formatinda gonderilmelidir.

  Eszamanlilik: VDbSqlServer ile ayni model — baglanti basina TVSql,
  paylasilan TVTableDb; yazmalar Ftb kilidiyle serilesir.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, VDbTypes, VDbCore, VDbTable, VDbSql, VDbAst,
  VDbParser, VDbNet;

type
  TVdbPgServer = class;

  TVdbPgConn = class(TThread)
  private
    FServer: TVdbPgServer;
    FSock: TVdbSocket;
    FSql: TVSql;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TVdbPgServer; ASock: TVdbSocket);
    destructor Destroy; override;
    procedure Wake;
    property Sock: TVdbSocket read FSock;
  end;

  TVdbPgAccept = class(TThread)
  private
    FServer: TVdbPgServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TVdbPgServer);
  end;

  TVdbPgServer = class
  private
    FDir: string;
    FPort: Word;
    FListen: TVdbSocket;
    Fkv: TVDb;
    Ftb: TVTableDb;
    FConnsLock: TCriticalSection;
    FConns: TList;
    FAccept: TVdbPgAccept;
    FReady: Boolean;
    FStopping: Boolean;
    FLastErr: string;
    FServed: Integer;
    FMaxConns: Integer;
    procedure AddConn(AConn: TVdbPgConn);
    procedure CloseEngine;
  public
    constructor Create(const ADir: string; APort: Word);
    destructor Destroy; override;
    function Start(out AErr: string): Boolean;
    procedure Stop;
    property Ready: Boolean read FReady;
    property Port: Word read FPort;
    property LastError: string read FLastErr;
    property Served: Integer read FServed;
    property Dir: string read FDir;
  end;

implementation

type
  TPgPortal = record
    Sql: string;
    Params: TStrArray;
    Done: Boolean;
    Res: TSqlResult;
    Err: string;
  end;

  { M1: prepared statement; ParamOids uzunlugu parametre sayisidir. }
  TPgStmt = record
    Sql: string;
    ParamOids: array of LongInt;
  end;

  { M1: COPY ... FROM STDIN / TO STDOUT (yalniz basit sorgu). }
  TPgCopySpec = record
    TableName: string;
    Query: string;        // COPY (SELECT ...) TO STDOUT
    IsQuery: Boolean;
    Cols: TStrArray;
    Options: string;
    FromStdin: Boolean;
    ToStdout: Boolean;
    Format: string;       // csv | text
    Delimiter: string;
    NullStr: string;
    Quote: string;
    Header: Boolean;
  end;

{ ---------------------------------------------------- ag bayt duzeni (BE) }

function NetI16(V: SmallInt): AnsiString;
var
  u: Word;
begin
  u := Word(V);
  Result := AnsiChar(u shr 8) + AnsiChar(u and $FF);
end;

function NetI32(V: LongInt): AnsiString;
var
  u: Cardinal;
begin
  u := Cardinal(V);
  Result := AnsiChar(u shr 24) + AnsiChar((u shr 16) and $FF) +
    AnsiChar((u shr 8) and $FF) + AnsiChar(u and $FF);
end;

function PgMsg(const T: AnsiChar; const Body: AnsiString): AnsiString;
begin
  Result := T + NetI32(Length(Body) + 4) + Body;
end;

function RecvI32(S: TVdbSocket; out V: LongInt): Boolean;
var
  b: array[0..3] of Byte;
begin
  Result := VdbRecvAll(S, b, 4);
  if Result then
    V := LongInt((Cardinal(b[0]) shl 24) or (Cardinal(b[1]) shl 16) or
      (Cardinal(b[2]) shl 8) or Cardinal(b[3]));
end;

function NetToI32(const S: AnsiString; Ofs: Integer): LongInt;
begin
  Result := LongInt((Cardinal(Ord(S[Ofs])) shl 24) or
    (Cardinal(Ord(S[Ofs + 1])) shl 16) or
    (Cardinal(Ord(S[Ofs + 2])) shl 8) or Cardinal(Ord(S[Ofs + 3])));
end;

function ReadCStr(const Buf: AnsiString; var P: Integer): string;
var
  st: Integer;
begin
  Result := '';
  st := P;
  while (P <= Length(Buf)) and (Buf[P] <> #0) do Inc(P);
  if P > st then
    Result := Copy(Buf, st, P - st);
  if P <= Length(Buf) then Inc(P);   // #0'i atla
end;

{ -------------------------------------------------------- mesaj uretimi }

function AuthOkMsg: AnsiString;
begin
  Result := PgMsg('R', NetI32(0));
end;

function ParamMsg(const Nm, Val: string): AnsiString;
begin
  Result := PgMsg('S', Nm + #0 + Val + #0);
end;

function BackendKeyMsg(Pid, Secret: LongInt): AnsiString;
begin
  Result := PgMsg('K', NetI32(Pid) + NetI32(Secret));
end;

function ReadyMsg: AnsiString;
begin
  Result := PgMsg('Z', 'I');
end;

function RowDescMsg(const Fields: TStrArray): AnsiString;
var
  body: AnsiString;
  i: Integer;
begin
  body := NetI16(Length(Fields));
  for i := 0 to High(Fields) do
    body := body + Fields[i] + #0 + NetI32(0) + NetI16(0) + NetI32(25) +
      NetI16(-1) + NetI32(-1) + NetI16(0);
  Result := PgMsg('T', body);
end;

function DataRowMsg(const Row: TStrArray): AnsiString;
var
  body: AnsiString;
  i: Integer;
  v: string;
begin
  body := NetI16(Length(Row));
  for i := 0 to High(Row) do
  begin
    v := Row[i];
    body := body + NetI32(Length(v)) + v;
  end;
  Result := PgMsg('D', body);
end;

function ParamDescMsg(const Oids: array of LongInt): AnsiString;
var
  body: AnsiString;
  i: Integer;
begin
  body := NetI16(Length(Oids));
  for i := 0 to High(Oids) do
    body := body + NetI32(Oids[i]);
  Result := PgMsg('t', body);
end;

{ M1: PostgreSQL binary parametre -> VDB metin degeri. }
function PgParamText(const Raw: AnsiString; Fmt: Integer;
  Oid: LongInt): string;
var
  b1, b2, b3, b4: Byte;
  u32: Cardinal;
  u64: QWord;
  i64: Int64;
  f32: Single;
  f64: Double;
  k: Integer;
begin
  if Fmt = 0 then Exit(Raw);          // metin formati
  if Fmt <> 1 then
    raise Exception.CreateFmt('gecersiz parametre formati: %d', [Fmt]);
  if Oid = 0 then Oid := 25;          // tur belirtilmemis -> metin

  case Oid of
    16: begin                         // bool
      if Length(Raw) <> 1 then
        raise Exception.Create('bool parametre uzunlugu 1 olmali');
      if Raw[1] <> #0 then Result := 'True' else Result := 'False';
    end;
    21: begin                         // int2
      if Length(Raw) <> 2 then
        raise Exception.Create('int2 parametre uzunlugu 2 olmali');
      b1 := Ord(Raw[1]); b2 := Ord(Raw[2]);
      Result := IntToStr(SmallInt((Word(b1) shl 8) or b2));
    end;
    23: begin                         // int4
      if Length(Raw) <> 4 then
        raise Exception.Create('int4 parametre uzunlugu 4 olmali');
      b1 := Ord(Raw[1]); b2 := Ord(Raw[2]);
      b3 := Ord(Raw[3]); b4 := Ord(Raw[4]);
      u32 := (Cardinal(b1) shl 24) or (Cardinal(b2) shl 16) or
        (Cardinal(b3) shl 8) or Cardinal(b4);
      Result := IntToStr(LongInt(u32));
    end;
    20: begin                         // int8
      if Length(Raw) <> 8 then
        raise Exception.Create('int8 parametre uzunlugu 8 olmali');
      u64 := 0;
      for k := 1 to 8 do
        u64 := (u64 shl 8) or Ord(Raw[k]);
      Move(u64, i64, SizeOf(i64));
      Result := IntToStr(i64);
    end;
    700: begin                        // float4
      if Length(Raw) <> 4 then
        raise Exception.Create('float4 parametre uzunlugu 4 olmali');
      b1 := Ord(Raw[1]); b2 := Ord(Raw[2]);
      b3 := Ord(Raw[3]); b4 := Ord(Raw[4]);
      u32 := (Cardinal(b1) shl 24) or (Cardinal(b2) shl 16) or
        (Cardinal(b3) shl 8) or Cardinal(b4);
      Move(u32, f32, SizeOf(f32));
      Result := VDbFloatToStr(f32);
    end;
    701: begin                        // float8
      if Length(Raw) <> 8 then
        raise Exception.Create('float8 parametre uzunlugu 8 olmali');
      u64 := 0;
      for k := 1 to 8 do
        u64 := (u64 shl 8) or Ord(Raw[k]);
      Move(u64, f64, SizeOf(f64));
      Result := VDbFloatToStr(f64);
    end;
    18, 19, 25, 1042, 1043:           // char/name/text/varchar
      Result := Raw;
  else
    raise Exception.CreateFmt(
      'binary parametre tipi desteklenmiyor (OID %d); metin formatinda gonderin',
      [Oid]);
  end;
end;

function CommandMsg(const Tag: string): AnsiString;
begin
  Result := PgMsg('C', Tag + #0);
end;

function ErrorMsg(const Msg: string): AnsiString;
var
  body: AnsiString;
begin
  body := 'S' + 'ERROR' + #0 + 'V' + 'ERROR' + #0 + 'C' + '42000' +
    #0 + 'M' + Msg + #0 + #0;
  Result := PgMsg('E', body);
end;

function CommandTag(const Sql: string; const Res: TSqlResult): string;
var
  s, w1, w2: string;
  i, n: Integer;
begin
  if Length(Res.Fields) > 0 then
    Exit('SELECT ' + IntToStr(Length(Res.Rows)));
  s := UpperCase(Trim(Sql));
  w1 := '';
  w2 := '';
  n := 0;
  i := 1;
  while (i <= Length(s)) and (n < 2) do
  begin
    while (i <= Length(s)) and (s[i] = ' ') do Inc(i);
    if i > Length(s) then Break;
    if n = 0 then
    begin
      while (i <= Length(s)) and (s[i] <> ' ') do
      begin
        w1 := w1 + s[i];
        Inc(i);
      end;
    end
    else
    begin
      while (i <= Length(s)) and (s[i] <> ' ') do
      begin
        w2 := w2 + s[i];
        Inc(i);
      end;
    end;
    Inc(n);
  end;
  if w1 = 'INSERT' then Exit('INSERT 0 ' + IntToStr(Res.Affected));
  if w1 = 'UPDATE' then Exit('UPDATE ' + IntToStr(Res.Affected));
  if w1 = 'DELETE' then Exit('DELETE ' + IntToStr(Res.Affected));
  if ((w1 = 'CREATE') or (w1 = 'DROP') or (w1 = 'ALTER')) and (w2 <> '') then
    Exit(w1 + ' ' + w2);
  if w1 = '' then Exit('SELECT 0');
  Result := w1;
end;

function SendPg(S: TVdbSocket; const M: AnsiString): Boolean;
begin
  Result := False;
  if M = '' then Exit(True);
  Result := VdbSendAll(S, M[1], Length(M));
end;

{ ------------------------------------------------ startup + basit sorgu }

function ReadStartup(S: TVdbSocket; out AUser: string): Boolean;
var
  len, code: LongInt;
  body: AnsiString;
  p: Integer;
  k, v: string;
begin
  Result := False;
  AUser := '';
  while True do
  begin
    if not RecvI32(S, len) then Exit;
    if (len < 8) or (len > 65536) then Exit;
    SetLength(body, len - 4);
    if (len - 4) > 0 then
      if not VdbRecvAll(S, body[1], len - 4) then Exit;
    code := NetToI32(body, 1);
    if (code = 80877103) or (code = 80877104) then
    begin
      // SSLRequest / GSSENCRequest: sifreleme yok -> tek bayt 'N'.
      if not VdbSendU8(S, Ord('N')) then Exit;
      Continue;
    end;
    if code <> 196608 then Exit;       // yalnizca 3.0
    p := 5;
    while p <= Length(body) do
    begin
      k := ReadCStr(body, p);
      if k = '' then Break;
      v := ReadCStr(body, p);
      if k = 'user' then AUser := v;
    end;
    Exit(True);
  end;
end;

procedure PgSkipWs(const S: string; var P: Integer);
begin
  while (P <= Length(S)) and (S[P] in [' ', #9, #10, #13]) do Inc(P);
end;

function PgWordChar(C: Char): Boolean;
begin
  Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '_', '$'];
end;

function PgMatchWord(const S: string; var P: Integer; const W: string): Boolean;
var
  q, k: Integer;
begin
  Result := False;
  PgSkipWs(S, P);
  if P + Length(W) - 1 > Length(S) then Exit;
  for k := 1 to Length(W) do
    if UpCase(S[P + k - 1]) <> UpCase(W[k]) then Exit;
  q := P + Length(W);
  if (q <= Length(S)) and PgWordChar(S[q]) then Exit;
  P := q;
  Result := True;
end;

function PgReadIdent(const S: string; var P: Integer; out V: string): Boolean;
var
  st: Integer;
begin
  Result := False;
  V := '';
  PgSkipWs(S, P);
  if P > Length(S) then Exit;
  if not (S[P] in ['A'..'Z', 'a'..'z', '_']) then Exit;
  st := P;
  while (P <= Length(S)) and PgWordChar(S[P]) do Inc(P);
  V := Copy(S, st, P - st);
  Result := True;
end;

procedure PgParseCopyOptions(const Opt: string; var Spec: TPgCopySpec);
var
  s, w, v, q: string;
  p, n, st: Integer;

  procedure Skip;
  begin
    while (p <= n) and (s[p] in [' ', #9, #10, #13]) do Inc(p);
  end;

  function ReadWord: string;
  begin
    Skip;
    st := p;
    while (p <= n) and not (s[p] in [' ', #9, #10, #13, ',', ')', '=']) do
      Inc(p);
    Result := Copy(s, st, p - st);
  end;

  function ReadVal: string;
  begin
    Skip;
    Result := '';
    if p > n then Exit;
    if s[p] in ['''', '"'] then
    begin
      q := s[p];
      Inc(p);
      while p <= n do
        if s[p] = q then
        begin
          if (p < n) and (s[p + 1] = q) then
          begin
            Result := Result + q;
            Inc(p, 2);
          end
          else
          begin
            Inc(p);
            Break;
          end;
        end
        else
        begin
          Result := Result + s[p];
          Inc(p);
        end;
    end
    else
    begin
      st := p;
      while (p <= n) and not (s[p] in [',', ')']) do Inc(p);
      Result := Trim(Copy(s, st, p - st));
    end;
  end;

begin
  Spec.Format := 'text';
  Spec.Delimiter := #9;
  Spec.NullStr := '\N';
  Spec.Quote := '"';
  Spec.Header := False;

  s := Trim(Opt);
  if s = '' then Exit;
  if UpperCase(Copy(s, 1, 4)) = 'WITH' then
  begin
    Delete(s, 1, 4);
    s := Trim(s);
  end;
  if (s <> '') and (s[1] = '(') then
  begin
    Delete(s, 1, 1);
    if (s <> '') and (s[Length(s)] = ')') then
      Delete(s, Length(s), 1);
  end;

  p := 1;
  n := Length(s);
  while p <= n do
  begin
    Skip;
    if p > n then Break;
    w := UpperCase(ReadWord);
    if w = '' then Break;
    Skip;
    if (p <= n) and (s[p] = '=') then
    begin
      Inc(p);
      Skip;
    end;
    if w = 'HEADER' then
    begin
      if (p > n) or (s[p] in [',', ')']) then
        Spec.Header := True
      else
      begin
        v := UpperCase(ReadVal);
        Spec.Header := (v = 'TRUE') or (v = 'ON') or (v = '1') or (v = 'YES');
      end;
    end
    else
    begin
      v := ReadVal;
      if w = 'FORMAT' then
      begin
        Spec.Format := LowerCase(v);
        if Spec.Format = 'csv' then
        begin
          Spec.Delimiter := ',';
          Spec.NullStr := '';
        end
        else if Spec.Format = 'text' then
        begin
          Spec.Delimiter := #9;
          Spec.NullStr := '\N';
        end;
      end
      else if w = 'DELIMITER' then
        Spec.Delimiter := v
      else if w = 'NULL' then
        Spec.NullStr := v
      else if w = 'QUOTE' then
        Spec.Quote := v
      else if w = 'ESCAPE' then
        ; // kabul edilir, yok sayilir
    end;
    Skip;
    if (p <= n) and (s[p] = ',') then Inc(p)
    else Break;
  end;
end;

function TryParsePgCopy(const Sql: string; out Spec: TPgCopySpec;
  out AErr: string): Boolean;
var
  p, n, qStart, depth: Integer;
  tbl: string;
  qch: Char;
  inQuote: Boolean;
begin
  Result := False;
  AErr := '';
  Spec := Default(TPgCopySpec);

  p := 1;
  n := Length(Sql);
  PgSkipWs(Sql, p);
  if not PgMatchWord(Sql, p, 'COPY') then Exit;

  PgSkipWs(Sql, p);
  if (p <= n) and (Sql[p] = '(') then
  begin
    // COPY (SELECT ...) TO STDOUT
    qStart := p;
    depth := 0;
    inQuote := False;
    qch := #0;
    while p <= n do
    begin
      if inQuote then
      begin
        if Sql[p] = '\' then
        begin
          Inc(p, 2);
          Continue;
        end;
        if Sql[p] = qch then
        begin
          if (p < n) and (Sql[p + 1] = qch) then
            Inc(p, 2)
          else
          begin
            inQuote := False;
            Inc(p);
          end;
        end
        else
          Inc(p);
      end
      else
      begin
        case Sql[p] of
          '''', '"':
            begin
              inQuote := True;
              qch := Sql[p];
              Inc(p);
            end;
          '(':
            begin
              Inc(depth);
              Inc(p);
            end;
          ')':
            begin
              Dec(depth);
              Inc(p);
              if depth = 0 then Break;
            end;
        else
          Inc(p);
        end;
      end;
    end;
    if (depth <> 0) or inQuote then
    begin
      AErr := 'COPY: sorgu parantezi kapatilmadi';
      Exit;
    end;
    Spec.Query := Trim(Copy(Sql, qStart + 1, p - qStart - 2));
    if Spec.Query = '' then
    begin
      AErr := 'COPY: sorgu bos';
      Exit;
    end;
    PgSkipWs(Sql, p);
    if not PgMatchWord(Sql, p, 'TO') then Exit;
    PgSkipWs(Sql, p);
    if not PgMatchWord(Sql, p, 'STDOUT') then Exit;
    Spec.IsQuery := True;
    Spec.ToStdout := True;
  end
  else
  begin
    if not PgReadIdent(Sql, p, tbl) then
    begin
      AErr := 'COPY: tablo adi bekleniyordu';
      Exit;
    end;
    Spec.TableName := tbl;

    PgSkipWs(Sql, p);
    if (p <= n) and (Sql[p] = '(') then
    begin
      Inc(p);
      while True do
      begin
        PgSkipWs(Sql, p);
        if not PgReadIdent(Sql, p, tbl) then
        begin
          AErr := 'COPY: kolon adi bekleniyordu';
          Exit;
        end;
        SetLength(Spec.Cols, Length(Spec.Cols) + 1);
        Spec.Cols[High(Spec.Cols)] := tbl;
        PgSkipWs(Sql, p);
        if (p <= n) and (Sql[p] = ',') then Inc(p)
        else if (p <= n) and (Sql[p] = ')') then
        begin
          Inc(p);
          Break;
        end
        else
        begin
          AErr := 'COPY: kolon listesi kapatilmadi';
          Exit;
        end;
      end;
    end;

    PgSkipWs(Sql, p);
    if PgMatchWord(Sql, p, 'FROM') then
    begin
      PgSkipWs(Sql, p);
      if not PgMatchWord(Sql, p, 'STDIN') then Exit;  // dosya COPY motoruna kalsin
      Spec.FromStdin := True;
    end
    else if PgMatchWord(Sql, p, 'TO') then
    begin
      PgSkipWs(Sql, p);
      if not PgMatchWord(Sql, p, 'STDOUT') then Exit;
      Spec.ToStdout := True;
    end
    else
      Exit;
  end;

  PgSkipWs(Sql, p);
  Spec.Options := Trim(Copy(Sql, p, MaxInt));
  if (Spec.Options <> '') and
     (Spec.Options[Length(Spec.Options)] = ';') then
    Spec.Options := Trim(Copy(Spec.Options, 1, Length(Spec.Options) - 1));
  if Spec.Options <> '' then
    if (UpperCase(Copy(Spec.Options, 1, 4)) <> 'WITH') and
       (Spec.Options[1] <> '(') then
    begin
      AErr := 'COPY: secenekler WITH veya ( ile baslamali';
      Exit;
    end;

  if Spec.ToStdout then
    PgParseCopyOptions(Spec.Options, Spec);
  Result := True;
end;

function PgCopyResponse(const T: AnsiChar; NCols: Integer): AnsiString;
var
  i: Integer;
begin
  Result := #0 + NetI16(NCols);
  for i := 1 to NCols do
    Result := Result + NetI16(0);
  Result := PgMsg(T, Result);
end;

function PgCsvField(const V, D, Q: string): string;
var
  qq: string;
begin
  qq := Q;
  if qq = '' then qq := '"';
  if (Pos(D, V) > 0) or (Pos(qq, V) > 0) or
     (Pos(#10, V) > 0) or (Pos(#13, V) > 0) then
    Result := qq + StringReplace(V, qq, qq + qq, [rfReplaceAll]) + qq
  else
    Result := V;
end;

function PgTextField(const V: string): string;
begin
  Result := StringReplace(V, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, #9, '\t', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '\r', [rfReplaceAll]);
end;

function PgCopyLine(const Fields: TStrArray; const Spec: TPgCopySpec): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Fields) do
  begin
    if i > 0 then Result := Result + Spec.Delimiter;
    if Spec.Format = 'csv' then
      Result := Result + PgCsvField(Fields[i], Spec.Delimiter, Spec.Quote)
    else
      Result := Result + PgTextField(Fields[i]);
  end;
end;

function PgTempCopyPath: string;
var
  i: Integer;
begin
  i := 0;
  repeat
    Result := IncludeTrailingPathDelimiter(GetTempDir) + 'vdb_pgcopy_' +
      IntToStr(GetTickCount64) + '_' + IntToStr(i) + '.tmp';
    Inc(i);
  until not FileExists(Result);
end;

function HandlePgCopyIn(S: TVdbSocket; FSql: TVSql;
  const Spec: TPgCopySpec): Boolean;
var
  td: TTableDef;
  ncols, i, len, plen: Integer;
  fs: TFileStream;
  path, sql, cols, msg: string;
  b: Byte;
  buf: TBytes;
  Res: TSqlResult;
begin
  Result := False;
  try
    td := FSql.TableDb.GetTable(Spec.TableName);
  except
    on E: Exception do
    begin
      SendPg(S, ErrorMsg(E.Message));
      Exit(SendPg(S, ReadyMsg));
    end;
  end;
  if Length(Spec.Cols) > 0 then ncols := Length(Spec.Cols)
  else ncols := Length(td.Cols);
  if ncols <= 0 then
  begin
    SendPg(S, ErrorMsg('COPY: tabloda kolon yok'));
    Exit(SendPg(S, ReadyMsg));
  end;

  if not SendPg(S, PgCopyResponse('G', ncols)) then Exit;

  path := PgTempCopyPath;
  fs := nil;
  try
    try
      fs := TFileStream.Create(path, fmCreate);
      while True do
      begin
        if not VdbRecvU8(S, b) then Exit;
        if not RecvI32(S, len) then Exit;
        plen := len - 4;
        if (plen < 0) or (plen > 64 * 1024 * 1024) then
        begin
          SendPg(S, ErrorMsg('COPY: gecersiz veri parcasi'));
          Exit(SendPg(S, ReadyMsg));
        end;
        SetLength(buf, plen);
        if (plen > 0) and not VdbRecvAll(S, buf[1], plen) then Exit;
        case AnsiChar(b) of
          'd':
            if plen > 0 then fs.WriteBuffer(buf[1], plen);
          'c':
            Break;
          'H':
            ; // Flush
          'f':
            begin
              msg := '';
              if plen > 0 then
              begin
                SetLength(msg, plen);
                Move(buf[0], msg[1], plen);
                if (msg <> '') and (msg[Length(msg)] = #0) then
                  Delete(msg, Length(msg), 1);
              end;
              SendPg(S, ErrorMsg('COPY: ' + msg));
              Exit(SendPg(S, ReadyMsg));
            end;
          else
            begin
              SendPg(S, ErrorMsg('COPY: beklenmeyen istemci mesaji'));
              Exit(SendPg(S, ReadyMsg));
            end;
        end;
      end;
    finally
      if fs <> nil then fs.Free;
    end;

    sql := 'COPY ' + Spec.TableName;
    if Length(Spec.Cols) > 0 then
    begin
      cols := '';
      for i := 0 to High(Spec.Cols) do
      begin
        if i > 0 then cols := cols + ', ';
        cols := cols + Spec.Cols[i];
      end;
      sql := sql + ' (' + cols + ')';
    end;
    sql := sql + ' FROM ''' +
      StringReplace(path, '''', '''''', [rfReplaceAll]) + '''';
    if Spec.Options <> '' then
      sql := sql + ' ' + Spec.Options;

    Res := Default(TSqlResult);
    try
      Res := FSql.Exec(sql);
      Result := SendPg(S, CommandMsg('COPY ' + IntToStr(Res.Affected))) and
        SendPg(S, ReadyMsg);
    except
      on E: Exception do
        Result := SendPg(S, ErrorMsg(E.Message)) and SendPg(S, ReadyMsg);
    end;
  finally
    if FileExists(path) then DeleteFile(path);
  end;
end;

function HandlePgCopyOut(S: TVdbSocket; FSql: TVSql;
  var Spec: TPgCopySpec): Boolean;
var
  td: TTableDef;
  names, row: TStrArray;
  i, j, n: Integer;
  sql, line: string;
  Res: TSqlResult;
begin
  Result := False;
  if (Spec.Format <> 'csv') and (Spec.Format <> 'text') then
  begin
    SendPg(S, ErrorMsg('COPY: yalniz FORMAT CSV veya TEXT destekleniyor'));
    Exit(SendPg(S, ReadyMsg));
  end;
  if Spec.Delimiter = '' then
  begin
    if Spec.Format = 'csv' then Spec.Delimiter := ',' else Spec.Delimiter := #9;
  end;

  Res := Default(TSqlResult);
  if Spec.IsQuery then
  begin
    try
      Res := FSql.Exec(Spec.Query);
    except
      on E: Exception do
      begin
        SendPg(S, ErrorMsg(E.Message));
        Exit(SendPg(S, ReadyMsg));
      end;
    end;
    if Length(Res.Fields) = 0 then
    begin
      SendPg(S, ErrorMsg('COPY: sorgu kolon dondurmedi'));
      Exit(SendPg(S, ReadyMsg));
    end;
    names := Res.Fields;
  end
  else
  begin
    try
      td := FSql.TableDb.GetTable(Spec.TableName);
    except
      on E: Exception do
      begin
        SendPg(S, ErrorMsg(E.Message));
        Exit(SendPg(S, ReadyMsg));
      end;
    end;
    if Length(Spec.Cols) = 0 then
    begin
      SetLength(names, Length(td.Cols));
      for i := 0 to High(td.Cols) do names[i] := td.Cols[i].Name;
    end
    else
      names := Spec.Cols;
    if Length(names) = 0 then
    begin
      SendPg(S, ErrorMsg('COPY: tabloda kolon yok'));
      Exit(SendPg(S, ReadyMsg));
    end;

    sql := 'SELECT ';
    for i := 0 to High(names) do
    begin
      if i > 0 then sql := sql + ', ';
      sql := sql + names[i];
    end;
    sql := sql + ' FROM ' + Spec.TableName;

    try
      Res := FSql.Exec(sql);
    except
      on E: Exception do
      begin
        SendPg(S, ErrorMsg(E.Message));
        Exit(SendPg(S, ReadyMsg));
      end;
    end;
  end;

  if not SendPg(S, PgCopyResponse('H', Length(names))) then Exit;
  if Spec.Header then
  begin
    line := PgCopyLine(names, Spec);
    if not SendPg(S, PgMsg('d', line + #10)) then Exit;
  end;
  n := 0;
  for i := 0 to High(Res.Rows) do
  begin
    SetLength(row, Length(names));
    for j := 0 to High(row) do
      if j <= High(Res.Rows[i]) then row[j] := Res.Rows[i][j]
      else row[j] := '';
    line := PgCopyLine(row, Spec);
    if not SendPg(S, PgMsg('d', line + #10)) then Exit;
    Inc(n);
  end;
  if not SendPg(S, PgMsg('c', '')) then Exit;
  if not SendPg(S, CommandMsg('COPY ' + IntToStr(n))) then Exit;
  Result := SendPg(S, ReadyMsg);
end;

function HandleQuery(S: TVdbSocket; FSql: TVSql; const Sql: string;
  out AServed: Boolean): Boolean;
var
  Res: TSqlResult;
  err, cpErr: string;
  i: Integer;
  CopySpec: TPgCopySpec;
begin
  Result := False;
  AServed := True;
  err := '';
  Res := Default(TSqlResult);
  // M1: COPY ... FROM STDIN / TO STDOUT basit sorgu akisi.
  if TryParsePgCopy(Sql, CopySpec, cpErr) then
  begin
    if CopySpec.FromStdin then Exit(HandlePgCopyIn(S, FSql, CopySpec));
    if CopySpec.ToStdout then Exit(HandlePgCopyOut(S, FSql, CopySpec));
  end
  else if cpErr <> '' then
  begin
    if not SendPg(S, ErrorMsg(cpErr)) then Exit;
    Exit(SendPg(S, ReadyMsg));
  end;
  try
    Res := FSql.Exec(Sql);
  except
    on E: Exception do
      err := E.Message;
  end;
  if err <> '' then
  begin
    if not SendPg(S, ErrorMsg(err)) then Exit;
    Exit(SendPg(S, ReadyMsg));
  end;
  if Length(Res.Fields) > 0 then
  begin
    if not SendPg(S, RowDescMsg(Res.Fields)) then Exit;
    for i := 0 to High(Res.Rows) do
      if not SendPg(S, DataRowMsg(Res.Rows[i])) then Exit;
  end;
  if not SendPg(S, CommandMsg(CommandTag(Sql, Res))) then Exit;
  Result := SendPg(S, ReadyMsg);
end;

{ ------------------------------------------------------- baglanti thread }

constructor TVdbPgConn.Create(AServer: TVdbPgServer; ASock: TVdbSocket);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServer := AServer;
  FSock := ASock;
  FSql := TVSql.Create(AServer.Ftb);
  AServer.AddConn(Self);
  Start;
end;

destructor TVdbPgConn.Destroy;
begin
  if FSql <> nil then
  begin
    FSql.Free;
    FSql := nil;
  end;
  inherited Destroy;
end;

procedure TVdbPgConn.Wake;
begin
  if FSock <> VDB_SOCK_INVALID then
    VdbSockShutdown(FSock);
end;

procedure TVdbPgConn.Execute;
var
  typ: Byte;
  len: LongInt;
  payload: AnsiString;
  sql, user: string;
  served: Boolean;
  Stmts: TDictionary<string, TPgStmt>;
  Portals: TDictionary<string, TPgPortal>;
  skipUntilSync: Boolean;
  p, np, nf, i2, nParams, nFmt, maxRows: Integer;
  declared, inferred, oid, fmt, plen, nResFmt: Integer;
  nm, q, kind: string;
  pt: TPgPortal;
  st: TPgStmt;
  fmts: array of Integer;
  params: TStrArray;
  raw: AnsiString;
  bad: Boolean;

  function TakeI16: Integer;
  begin
    Result := 0;
    if p + 1 <= Length(payload) then
    begin
      Result := (Ord(payload[p]) shl 8) or Ord(payload[p + 1]);
      Inc(p, 2);
    end;
  end;

  function TakeI32: LongInt;
  begin
    Result := 0;
    if p + 3 <= Length(payload) then
    begin
      Result := LongInt((Cardinal(Ord(payload[p])) shl 24) or
        (Cardinal(Ord(payload[p + 1])) shl 16) or
        (Cardinal(Ord(payload[p + 2])) shl 8) or
        Cardinal(Ord(payload[p + 3])));
      Inc(p, 4);
    end;
  end;

  procedure ExtFail(const Msg: string);
  begin
    skipUntilSync := True;
    SendPg(FSock, ErrorMsg(Msg));
  end;

  function ExecutePortal(var P: TPgPortal): Boolean;
  begin
    Result := False;
    P.Err := '';
    P.Res := Default(TSqlResult);
    try
      P.Res := FSql.Exec(P.Sql, P.Params);
      Result := True;
    except
      on E: Exception do P.Err := E.Message;
    end;
    P.Done := True;
  end;

begin
  Stmts := nil;
  Portals := nil;
  try
    if not ReadStartup(FSock, user) then Exit;
    Stmts := TDictionary<string, TPgStmt>.Create;
    Portals := TDictionary<string, TPgPortal>.Create;
    if not SendPg(FSock, AuthOkMsg) then Exit;
    if not SendPg(FSock, ParamMsg('server_version', '14.0 (VDB)')) then Exit;
    if not SendPg(FSock, ParamMsg('client_encoding', 'UTF8')) then Exit;
    if not SendPg(FSock, ParamMsg('DateStyle', 'ISO')) then Exit;
    if not SendPg(FSock, ParamMsg('integer_datetimes', 'on')) then Exit;
    if not SendPg(FSock, BackendKeyMsg(1, 0)) then Exit;
    if not SendPg(FSock, ReadyMsg) then Exit;

    skipUntilSync := False;
    while not Terminated do
    begin
      if not VdbRecvU8(FSock, typ) then Break;
      if typ = Ord('X') then Break;          // Terminate
      if not RecvI32(FSock, len) then Break;
      if (len < 4) or (len > 64 * 1024 * 1024) then Break;
      SetLength(payload, len - 4);
      if (len - 4) > 0 then
        if not VdbRecvAll(FSock, payload[1], len - 4) then Break;

      // Hata sonrasi Sync'e kadar tum mesajlari yut.
      if skipUntilSync and (typ <> Ord('S')) then Continue;

      if typ = Ord('Q') then
      begin
        sql := payload;
        while (sql <> '') and (sql[Length(sql)] = #0) do
          SetLength(sql, Length(sql) - 1);
        Stmts.Remove('');
        Portals.Remove('');
        if not HandleQuery(FSock, FSql, sql, served) then Break;
        if served then InterlockedIncrement(FServer.FServed);
      end
      else if typ = Ord('P') then            // Parse
      begin
        p := 1;
        nm := ReadCStr(payload, p);
        q := ReadCStr(payload, p);
        declared := TakeI16;
        inferred := VDbCountSqlParams(q);
        if inferred < declared then inferred := declared;
        if (declared > 0) and (p + declared * 4 - 1 > Length(payload)) then
        begin
          ExtFail('Parse mesaji eksik parametre OID listesi');
          Continue;
        end;
        st := Default(TPgStmt);
        st.Sql := q;
        SetLength(st.ParamOids, inferred);
        for i2 := 0 to inferred - 1 do st.ParamOids[i2] := 25;  // text
        for i2 := 0 to declared - 1 do
        begin
          oid := TakeI32;
          if oid = 0 then oid := 25;
          st.ParamOids[i2] := oid;
        end;
        Stmts.AddOrSetValue(nm, st);
        if not SendPg(FSock, PgMsg('1', '')) then Break;
      end
      else if typ = Ord('B') then            // Bind
      begin
        p := 1;
        nm := ReadCStr(payload, p);          // portal
        q := ReadCStr(payload, p);           // statement
        if not Stmts.TryGetValue(q, st) then
        begin
          ExtFail('prepared statement yok: ' + q);
          Continue;
        end;
        nFmt := TakeI16;
        if (nFmt < 0) or (p + nFmt * 2 - 1 > Length(payload)) then
        begin
          ExtFail('Bind mesaji eksik parametre formati');
          Continue;
        end;
        SetLength(fmts, nFmt);
        for i2 := 0 to nFmt - 1 do fmts[i2] := TakeI16;
        nParams := TakeI16;
        // `?` yer tutuculari icin: Parse'te OID verilmediyse Bind sayisini
        // esas al (standart istemciler $n kullanir; bu yalnizca uyumluluk).
        if (Length(st.ParamOids) = 0) and (nParams > 0) then
        begin
          SetLength(st.ParamOids, nParams);
          for i2 := 0 to nParams - 1 do st.ParamOids[i2] := 25;
        end;
        if nParams <> Length(st.ParamOids) then
        begin
          ExtFail(Format('parametre sayisi uyusmuyor: beklenen %d, gelen %d',
            [Length(st.ParamOids), nParams]));
          Continue;
        end;
        if (nFmt <> 0) and (nFmt <> 1) and (nFmt <> nParams) then
        begin
          ExtFail('parametre format sayisi gecersiz');
          Continue;
        end;
        SetLength(params, nParams);
        bad := False;
        for i2 := 0 to nParams - 1 do
        begin
          if p + 3 > Length(payload) then
          begin
            bad := True;
            Break;
          end;
          plen := TakeI32;
          if plen = -1 then
          begin
            params[i2] := '';               // motor NULL/bos ayrimi yapmaz
            Continue;
          end;
          if (plen < 0) or (p + plen - 1 > Length(payload)) then
          begin
            bad := True;
            Break;
          end;
          raw := Copy(payload, p, plen);
          Inc(p, plen);
          if nFmt = 0 then fmt := 0
          else if nFmt = 1 then fmt := fmts[0]
          else fmt := fmts[i2];
          try
            params[i2] := PgParamText(raw, fmt, st.ParamOids[i2]);
          except
            on E: Exception do
            begin
              bad := True;
              ExtFail(E.Message);
              Break;
            end;
          end;
        end;
        if bad then Continue;
        nResFmt := TakeI16;
        if (nResFmt < 0) or (p + nResFmt * 2 - 1 > Length(payload)) then
        begin
          ExtFail('Bind mesaji eksik sonuc formati');
          Continue;
        end;
        bad := False;
        for i2 := 0 to nResFmt - 1 do
          if TakeI16 <> 0 then bad := True;
        if bad then
        begin
          ExtFail('binary sonuc formati desteklenmiyor');
          Continue;
        end;
        pt := Default(TPgPortal);
        pt.Sql := st.Sql;
        pt.Params := params;
        pt.Done := False;
        Portals.AddOrSetValue(nm, pt);
        if not SendPg(FSock, PgMsg('2', '')) then Break;
      end
      else if typ = Ord('D') then            // Describe
      begin
        if Length(payload) >= 2 then
        begin
          kind := AnsiChar(payload[1]);
          p := 2;
          nm := ReadCStr(payload, p);
          if kind = 'S' then
          begin
            if not Stmts.TryGetValue(nm, st) then
            begin
              ExtFail('prepared statement yok: ' + nm);
              Continue;
            end;
            if not SendPg(FSock, ParamDescMsg(st.ParamOids)) then Break;
            if not SendPg(FSock, PgMsg('n', '')) then Break;          // NoData
          end
          else if Portals.TryGetValue(nm, pt) then
          begin
            if not pt.Done then
            begin
              ExecutePortal(pt);
              Portals.AddOrSetValue(nm, pt);
            end;
            if pt.Err <> '' then
              ExtFail(pt.Err)
            else if Length(pt.Res.Fields) > 0 then
            begin
              if not SendPg(FSock, RowDescMsg(pt.Res.Fields)) then Break;
            end
            else if not SendPg(FSock, PgMsg('n', '')) then Break;
          end
          else
            ExtFail('portal yok: ' + nm);
        end;
      end
      else if typ = Ord('E') then            // Execute
      begin
        p := 1;
        nm := ReadCStr(payload, p);
        if Portals.TryGetValue(nm, pt) then
        begin
          if not pt.Done then
          begin
            ExecutePortal(pt);
            Portals.AddOrSetValue(nm, pt);
          end;
          if pt.Err <> '' then
            ExtFail(pt.Err)
          else
          begin
            for i2 := 0 to High(pt.Res.Rows) do
              if not SendPg(FSock, DataRowMsg(pt.Res.Rows[i2])) then Break;
            if not SendPg(FSock, CommandMsg(CommandTag(pt.Sql, pt.Res))) then Break;
            InterlockedIncrement(FServer.FServed);
          end;
        end
        else
          ExtFail('portal yok: ' + nm);
      end
      else if typ = Ord('C') then            // Close
      begin
        if Length(payload) >= 2 then
        begin
          kind := AnsiChar(payload[1]);
          p := 2;
          nm := ReadCStr(payload, p);
          if kind = 'S' then Stmts.Remove(nm) else Portals.Remove(nm);
        end;
        if not SendPg(FSock, PgMsg('3', '')) then Break;
      end
      else if typ = Ord('S') then            // Sync
      begin
        skipUntilSync := False;
        if not SendPg(FSock, ReadyMsg) then Break;
      end
      else if typ = Ord('H') then            // Flush: hemen gonderiyoruz, no-op
      begin
      end
      else
      begin
        // Bilinmeyen mesaj turu: protokol bozulmasin diye kapat.
        Break;
      end;
    end;
  finally
    Portals.Free;
    Stmts.Free;
    VdbSockClose(FSock);
  end;
end;

{ --------------------------------------------------------- kabul thread }

constructor TVdbPgAccept.Create(AServer: TVdbPgServer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServer := AServer;
  Start;
end;

procedure TVdbPgAccept.Execute;
var
  sock: TVdbSocket;
begin
  while not FServer.FStopping do
  begin
    sock := VdbTcpAccept(FServer.FListen);
    if sock = VDB_SOCK_INVALID then Break;
    if FServer.FConns.Count >= FServer.FMaxConns then
    begin
      VdbSockClose(sock);   // startup oncesi: protokol mesaji gondermeden kapat
      Continue;
    end;
    TVdbPgConn.Create(FServer, sock);
  end;
end;

{ --------------------------------------------------------------- sunucu }

constructor TVdbPgServer.Create(const ADir: string; APort: Word);
begin
  inherited Create;
  FDir := ADir;
  FPort := APort;
  FListen := VDB_SOCK_INVALID;
  FConnsLock := TCriticalSection.Create;
  FConns := TList.Create;
  FMaxConns := 16;
end;

destructor TVdbPgServer.Destroy;
begin
  Stop;
  FConns.Free;
  FConnsLock.Free;
  inherited;
end;

procedure TVdbPgServer.CloseEngine;
begin
  if Ftb <> nil then begin Ftb.Close; Ftb.Free; Ftb := nil; end;
  if Fkv <> nil then begin Fkv.Close; Fkv.Free; Fkv := nil; end;
end;

function TVdbPgServer.Start(out AErr: string): Boolean;
begin
  Result := False;
  AErr := '';
  if FReady then
  begin
    AErr := 'sunucu zaten aktif';
    Exit;
  end;
  try
    Fkv := TVDb.Create;
    Fkv.Open(FDir);
    Ftb := TVTableDb.Create(Fkv);
    Ftb.Open(FDir);
  except
    on E: Exception do
    begin
      AErr := 'motor acilamadi: ' + E.Message;
      CloseEngine;
      Exit;
    end;
  end;
  FListen := VdbTcpListen(FPort);
  if FListen = VDB_SOCK_INVALID then
  begin
    AErr := 'dinleme kurulamadi (port ' + IntToStr(FPort) + ')';
    CloseEngine;
    Exit;
  end;
  FStopping := False;
  FReady := True;
  FLastErr := '';
  FServed := 0;
  FAccept := TVdbPgAccept.Create(Self);
  Result := True;
end;

procedure TVdbPgServer.Stop;
var
  snap: array of TVdbPgConn;
  i, n: Integer;
begin
  if not FReady then Exit;
  FStopping := True;
  if FListen <> VDB_SOCK_INVALID then
  begin
    VdbSockClose(FListen);
    FListen := VDB_SOCK_INVALID;
  end;
  if FAccept <> nil then
  begin
    FAccept.WaitFor;
    FreeAndNil(FAccept);
  end;
  FConnsLock.Enter;
  try
    n := FConns.Count;
    SetLength(snap, n);
    for i := 0 to n - 1 do
      snap[i] := TVdbPgConn(FConns[i]);
  finally
    FConnsLock.Leave;
  end;
  for i := 0 to High(snap) do
    snap[i].Wake;
  for i := 0 to High(snap) do
  begin
    snap[i].WaitFor;
    snap[i].Free;
  end;
  FConnsLock.Enter;
  try
    FConns.Clear;
  finally
    FConnsLock.Leave;
  end;
  CloseEngine;
  FReady := False;
end;

procedure TVdbPgServer.AddConn(AConn: TVdbPgConn);
begin
  FConnsLock.Enter;
  try
    FConns.Add(AConn);
  finally
    FConnsLock.Leave;
  end;
end;

end.
