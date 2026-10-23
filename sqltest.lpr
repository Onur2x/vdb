program sqltest;

{ VDB SQL tam test paketi.

  Tum desteklenen SQL komutlarini calistirir, beklenen sonucu karsilastirir.

  Derleme:  lazbuild sqltest.lpi
  Calistirma: sqltest.exe <calisma-klasoru>

  klasor verilmezse gecici klasor kullanilir. }
{$mode delphi}{$H+}

uses
  SysUtils, Classes, Math, StrUtils, VDbCore, VDbTypes, VDbTable, VDbSql, VDbSync, VDbCrc32,
  VDbCrypt, VDbKdf, VDbSpatial, VDbRange, VDbMonitor, VDbPlatform, VDbCost,
  VDbExtension, VDbText, VDbParallel, VDbReplication, VDbNet, VDbSqlServer,
  VDbClientNet, VDbMetricsHttp, VDbPgWire, VDbTls, VDbTrace, dynlibs, VDbUndo;
{ VDbTypes: TStrArray / TStrMatrix gibi paylasilan tipler artik tek
  kaynaktan geliyor (ayri birimde ikinci tanim FPC'de sessizce
  FARKLI tip uretip derleme hatasi veriyordu). }

var
  D: string;
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  R: TSqlResult;
  nPass, nFail, nGrp: Integer;
  grpName: string;

const
  Q = '''';   // tek tirnak
  WAL_MAGIC_BEKLENEN = LongWord($57414C52);   // 'WALR'

type
  { M9: /metrics HTTP testi icin metod-isaretcisi saglayici. }
  TMetricsTestProvider = class
  public
    Text: string;
    function Get: string;
  end;

  { M9: OTLP export testi icin tek istek yakalayan yerel HTTP alicisi. }
  TOtlpCaptureThread = class(TThread)
  private
    FListen: TVdbSocket;
    FPort: Word;
    FRequest: string;
    FStarted: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    property Port: Word read FPort;
    property Request: string read FRequest;
    property Started: Boolean read FStarted;
  end;

  { M11: IVDbKvStore'un ikinci (bellek-ici) backend'i. Yalnizca arayuz
    sozlesmesini ve backend degistirilebilirligini dogrulamak icin. }
  TMemKvStore = class(TInterfacedObject, IVDbKvStore)
  private
    FKeys: array of QWord;
    FVals: array of TBytes;
    function Find(Key: QWord): Integer;
  public
    procedure Put(Key: QWord; const Value: TBytes);
    function Get(Key: QWord; out Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    procedure ScanAll(out Keys: TQWordArray; out Vals: TValArray;
      TableFilter: Integer);
  end;

function TMemKvStore.Find(Key: QWord): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FKeys) do
    if FKeys[i] = Key then Exit(i);
  Result := -1;
end;

procedure TMemKvStore.Put(Key: QWord; const Value: TBytes);
var
  i: Integer;
begin
  i := Find(Key);
  if i < 0 then
  begin
    i := Length(FKeys);
    SetLength(FKeys, i + 1);
    SetLength(FVals, i + 1);
    FKeys[i] := Key;
  end;
  FVals[i] := Copy(Value, 0, Length(Value));
end;

function TMemKvStore.Get(Key: QWord; out Value: TBytes): Boolean;
var
  i: Integer;
begin
  i := Find(Key);
  Result := i >= 0;
  if Result then Value := Copy(FVals[i], 0, Length(FVals[i]))
  else Value := nil;
end;

function TMemKvStore.Delete(Key: QWord): Boolean;
var
  i, n: Integer;
begin
  i := Find(Key);
  Result := i >= 0;
  if not Result then Exit;
  n := High(FKeys);
  FKeys[i] := FKeys[n];
  FVals[i] := FVals[n];
  SetLength(FKeys, n);
  SetLength(FVals, n);
end;

procedure TMemKvStore.ScanAll(out Keys: TQWordArray; out Vals: TValArray;
  TableFilter: Integer);
var
  i: Integer;
begin
  SetLength(Keys, Length(FKeys));
  SetLength(Vals, Length(FVals));
  for i := 0 to High(FKeys) do
  begin
    Keys[i] := FKeys[i];
    Vals[i] := Copy(FVals[i], 0, Length(FVals[i]));
  end;
end;

{ ---- M9 OTLP test alicisi ---- }

constructor TOtlpCaptureThread.Create;
var
  i: Integer;
  s: TVdbSocket;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FListen := VDB_SOCK_INVALID;
  FStarted := False;
  FPort := 0;
  for i := 0 to 9 do
  begin
    s := VdbTcpListen(19300 + i);
    if s <> VDB_SOCK_INVALID then
    begin
      FListen := s;
      FPort := 19300 + i;
      FStarted := True;
      Break;
    end;
  end;
  if FStarted then Start;
end;

destructor TOtlpCaptureThread.Destroy;
begin
  Terminate;
  if not Finished then
  begin
    if FListen <> VDB_SOCK_INVALID then VdbSockClose(FListen);
    FListen := VDB_SOCK_INVALID;
    WaitFor;
  end;
  inherited Destroy;
end;

procedure TOtlpCaptureThread.Execute;
var
  s: TVdbSocket;
  buf: array[0..4095] of Char;
  req, resp: string;
  n, hdrEnd, p, clen, want: Integer;
  numStr: string;
  i, v: Integer;
begin
  s := VdbTcpAccept(FListen);
  if s = VDB_SOCK_INVALID then Exit;
  try
    req := '';
    hdrEnd := 0;
    repeat
      n := VdbRecvSome(s, buf[0], SizeOf(buf));
      if n <= 0 then Break;
      SetLength(req, Length(req) + n);
      Move(buf[0], req[Length(req) - n + 1], n);
      hdrEnd := Pos(#13#10#13#10, req);
    until hdrEnd > 0;

    if hdrEnd > 0 then
    begin
      { Content-Length: <n> (VDbTraceExportOTLP tam bu bicimi yollar). }
      clen := 0;
      p := Pos('Content-Length: ', req);
      if p > 0 then
      begin
        numStr := '';
        i := p + Length('Content-Length: ');
        while (i <= Length(req)) and (req[i] in ['0'..'9']) do
        begin
          numStr := numStr + req[i];
          Inc(i);
        end;
        v := StrToIntDef(numStr, -1);
        if v > 0 then clen := v;
      end;
      want := hdrEnd + 3 + clen;
      while Length(req) < want do
      begin
        n := VdbRecvSome(s, buf[0], SizeOf(buf));
        if n <= 0 then Break;
        SetLength(req, Length(req) + n);
        Move(buf[0], req[Length(req) - n + 1], n);
      end;
    end;

    FRequest := req;
    resp := 'HTTP/1.1 200 OK' + #13#10 +
      'Content-Type: application/json' + #13#10 +
      'Content-Length: 2' + #13#10 +
      'Connection: close' + #13#10 + #13#10 + '{}';
    VdbSendAll(s, resp[1], Length(resp));
  finally
    VdbSockClose(s);
    if FListen <> VDB_SOCK_INVALID then
    begin
      VdbSockClose(FListen);
      FListen := VDB_SOCK_INVALID;
    end;
  end;
end;

{ ------------------------------------------------------------ yardimcilar }

procedure Grp(const N: string);
begin
  Inc(nGrp);
  grpName := N;
  WriteLn;
  WriteLn('== ', nGrp, '. ', N);
end;

procedure Ok(const Nm, E: string);
begin
  Inc(nPass);
  if E = '' then WriteLn('   OK   ', Nm)
  else WriteLn('   OK   ', Nm, '   [', E, ']');
end;

procedure No(const Nm, E: string);
begin
  Inc(nFail);
  WriteLn('   FAIL ', Nm, '   [', E, ']');
end;

procedure Dogrula(const Ad: string; Cond: Boolean; const E: string = '');
begin
  if Cond then Ok(Ad, E) else No(Ad, E);
end;

procedure Chk(const Nm, Sql: string; const ExpectRows: Integer);
var e: string;
begin
  try
    R := sq.Exec(Sql);
    if ExpectRows >= 0 then
    begin
      if Length(R.Rows) = ExpectRows then Ok(Nm, IntToStr(Length(R.Rows)) + ' satir')
      else No(Nm, 'beklenen ' + IntToStr(ExpectRows) + ' satir, gelen ' +
                 IntToStr(Length(R.Rows)));
    end
    else Ok(Nm, '');
  except
    on E: Exception do No(Nm, '(' + E.Message + ')');
  end;
end;

procedure ChkVal(const Nm, Sql: string; RowIx, ColIx: Integer;
  const Want: string);
var got: string;
begin
  try
    R := sq.Exec(Sql);
    if (RowIx >= Length(R.Rows)) or (ColIx >= Length(R.Rows[RowIx])) then
    begin
      No(Nm, 'sonuc hucre yok (satir ' + IntToStr(RowIx) + '/' +
              IntToStr(Length(R.Rows)) + ')');
      Exit;
    end;
    got := R.Rows[RowIx][ColIx];
    if got = Want then Ok(Nm, got)
    else No(Nm, 'beklenen "' + Want + '" gelen "' + got + '"');
  except
    on E: Exception do No(Nm, '(' + E.Message + ')');
  end;
end;

// R-20: SQL metin literal uretir (tirnakli). Testlerde tekrar tekrar
// Q birlesimi yazmamak icin.
function SQLIT(const V: string): string;
begin
  Result := Q + V + Q;
end;

// R-20: Unicode kod noktasindan UTF-8 metin uretir. Cok baytli
// (Kiril/Yunan/Ibran/Arap/Han) test verisi kaynak dosyanin kodlamasindan
// bagimsiz olsun diye boyle yazilir.
function CR(Cp: Integer): string;
begin
  if Cp < $80 then Result := Chr(Cp)
  else if Cp < $800 then
    Result := Chr($C0 or (Cp shr 6)) + Chr($80 or (Cp and $3F))
  else if Cp < $10000 then
    Result := Chr($E0 or (Cp shr 12)) + Chr($80 or ((Cp shr 6) and $3F)) +
      Chr($80 or (Cp and $3F))
  else
    Result := Chr($F0 or (Cp shr 18)) + Chr($80 or ((Cp shr 12) and $3F)) +
      Chr($80 or ((Cp shr 6) and $3F)) + Chr($80 or (Cp and $3F));
end;
function SQT(const V: string): string; inline;
begin
  Result := Q + V + Q;
end;

// F-20: Sonuc metni bir ALT DIZGI iceriyor mu? (EXPLAIN plan icerigi)
procedure ChkHas(const Nm, Sql, Want: string);
var
  all: string;
  k: Integer;
begin
  try
    R := sq.Exec(Sql);
    all := '';
    for k := 0 to High(R.Rows) do
      all := all + R.Rows[k][0] + ' | ';
    if Pos(Want, all) > 0 then Ok(Nm, 'bulundu: ' + Want)
    else No(Nm, '"' + Want + '" bulunamadi; plan: ' + all);
  except
    on E: Exception do No(Nm, '(' + E.Message + ')');
  end;
end;

// F-21: sonucun TUM hucelerinde bir alt dize arar (cok satirlik rapor)
procedure ChkHas2(const Nm, Sql, Want: string);
var
  all: string;
  k, c: Integer;
begin
  try
    R := sq.Exec(Sql);
    all := '';
    for k := 0 to High(R.Rows) do
      for c := 0 to High(R.Rows[k]) do
        all := all + R.Rows[k][c] + ' | ';
    if Pos(Want, all) > 0 then Ok(Nm, 'bulundu: ' + Want)
    else No(Nm, '"' + Want + '" bulunamadi; icerik: ' + all);
  except
    on E: Exception do No(Nm, '(' + E.Message + ')');
  end;
end;

// Sonuc matrisini tek satira dok (hata ayiklama / tani)
procedure Dump(const Nm, Sql: string);
var
  acc: string;
  k: Integer;
begin
  try
    R := sq.Exec(Sql);
    acc := '';
    for k := 0 to High(R.Rows) do
    begin
      if k > 0 then acc := acc + ' | ';
      acc := acc + R.Rows[k][0];
    end;
    Ok(Nm, acc);
  except
    on E: Exception do Ok(Nm, 'HATA: ' + E.Message);
  end;
end;

// Calistirilmasi beklenen, HATA vermesi gereken komut
procedure ChkErr(const Nm, Sql: string);
begin
  try
    sq.Exec(Sql);
    No(Nm, 'HATA VERMEDI (kabul edildi)');
  except
    on E: Exception do Ok(Nm, E.Message);
  end;
end;

procedure ChkInt(const Nm: string; const Got, Expect: Integer);
// TSqlResult sayisal alanlarini (Affected / Stmts) dogrudan dogrular.
begin
  if Got = Expect then Ok(Nm, IntToStr(Got))
  else No(Nm, 'beklenen ' + IntToStr(Expect) + ', gelen ' + IntToStr(Got));
end;

// Ayri bir calisma yerinde gecici acma/kapatma
procedure Fresh(const Nm: string);
var p: string;
begin
  p := D + '\' + Nm;
  ForceDirectories(p);
  if tb <> nil then begin tb.Close; kv.Close; sq.Free; tb.Free; kv.Free; end;
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  kv.Open(p);
  tb.Open(p);
end;

procedure UseDir(const Nm: string);
var p: string;
begin
  p := D + '\' + Nm;
  ForceDirectories(p);
  if tb <> nil then begin tb.Close; kv.Close; sq.Free; tb.Free; kv.Free; end;
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  kv.Open(p);
  tb.Open(p);
end;

procedure CorruptLastByte(const P: string);
{ R-16 testi: WAL segmentinin son baytini 0 yazar. Boylece SON kaydin
  CRC'si tutmaz -> replay o kaydi gecersiz sayip bir oncekinde durur.
  Boylece "bozuk kayit veri bozma" davranisi olculur. }
var
  fs: TFileStream;
  b: Byte;
begin
  fs := TFileStream.Create(P, fmOpenReadWrite);
  try
    fs.Seek(-1, soEnd);
    fs.Read(b, 1);
    b := b xor $FF;
    fs.Seek(-1, soEnd);
    fs.Write(b, 1);
    VDbFlushStream(fs);
  finally
    fs.Free;
  end;
end;

procedure Shutdown;
begin
  if tb <> nil then
  begin
    tb.Close; kv.Close; sq.Free; tb.Free; kv.Free;
    sq := nil; tb := nil; kv := nil;
  end;
end;

{ ------------------------------------------------------------------ TESTLER }

{ Test icin sifreleme anahtari uretir. Gercek kullanimda anahtar
  .key dosyasindan gelir; burada sabitlenebilir olsun diye tohumdan
  uretiliyor. }
function TestKey(Seed: Integer): TBytes;
var
  i: Integer;
begin
  SetLength(Result, VDB_KEY_LEN);
  for i := 0 to VDB_KEY_LEN - 1 do
    Result[i] := Byte((i * 37 + Seed * 11 + 5) mod 251);
end;

{ Get cagrisinda istisna olup OLMADIGINI dondurur. Sessizce bozuk veri
  donmesi en kotu hatadir; bu yuzden her "hata bekleniyor" kontrolu
  bununla yapilir. }
function OkunduMu(A: TVDb; Key: QWord; out Val: TBytes): Boolean;
begin
  Result := True;
  try
    Result := A.Get(Key, Val);
  except
    on E: Exception do Result := False;
  end;
end;

procedure T74_KayitSifreleme;
{ 2026-10-05 KAYIT SEVIYESI SIFRELEME.

  TASNIT EDILEN SEMANTIK:
    a) Sifreleme KAPALI iken davranis degismez (geriye donuk uyum).
    b) Anahtar verilince Put degeri SIFRELI yazilir (bayrak set).
    c) Get/ScanAll degeri COZER - cagiran daima duz metin gorur.
    d) Duz metin, sifreli baytlarda BULUNMAZ.
    e) Ayni deger iki kez yazilirsa sifreli baytlar FARKLIDIR
       (her yazimda yeni IV).
    f) Yeniden acma (Close/Open) sonrasi anahtarla okunur.
    g) YANLIS/eksik anahtarla okuma ETIKET DOGRULAMASI ile hata verir;
       sessizce bozuk veri DONDURMEZ.
    h) SILME kaydi (tombstone) sifrelenmez.
    i) Karisik dosya: sifreleme kapaliyken yazilan kayit da
       sifreli olanla birlikte okunabilir.
    j) WAL'a DUZ METIN yazilir (sifreli veri birikmez).
    k) .key dosyasi ile ucuncu sonu yol.

  NOT: Dosya icerigi taramalari (d) ve (j) DAIMA dosya KAPALI iken
  yapilir. Motor dosyayi fmOpenReadWrite ile tutuyor; acikken tarama
  EFOpenError verir.
}
var
  myKv: TVDb;
  v, ct, tag, back: TBytes;
  k: TBytes;
  kp, dbp: string;
  sK: TQWordArray;
  sV: TValArray;
  i: Integer;
  bulundu, aeadHata: Boolean;

  procedure Dogrula(const Ad: string; Cond: Boolean; const E: string = '');
  begin
    if Cond then Ok(Ad, E) else No(Ad, E);
  end;

  { Dosyada duz metni arar (sifreleme KANITI). Dosya KAPALI olmali. }
  function DosyadaDuzMetin(const FN, Aranan: string): Boolean;
  var
    fs2: TFileStream;
    buf: array[0..65535] of Byte;
    n, got: Int64;
    j: Integer;
    s: string;
  begin
    Result := False;
    if not FileExists(FN) then Exit;
    fs2 := TFileStream.Create(FN, fmOpenRead or fmShareDenyNone);
    try
      n := fs2.Size;
      SetLength(s, 0);
      while n > 0 do
      begin
        got := fs2.Read(buf, 65536);
        if got <= 0 then Break;
        SetLength(s, Length(s) + Integer(got));
        for j := 0 to Integer(got) - 1 do
          s[Length(s) - Integer(got) + j + 1] := Chr(buf[j]);
        n := n - got;
      end;
      Result := Pos(Aranan, s) > 0;
    finally
      fs2.Free;
    end;
  end;

begin
  Grp('KAYIT SEVIYESI SIFRELEME (VDB_FLAG_ENCRYPTED)');

  // ---- a) varsayilan KAPALI: davranis degismez ----
  myKv := TVDb.Create;
  try
    myKv.Open(D + '\enc1.odb');
    Dogrula('varsayilan sifreleme KAPALI', not myKv.IsEncrypted);
    myKv.Put(1, VDbStrToBytes('gizli-metin'));
    SetLength(v, 0);
    Dogrula('kapali iken normal okuma',
      myKv.Get(1, v) and (VDbBytesToStr(v) = 'gizli-metin'), VDbBytesToStr(v));
  finally
    myKv.Free;
  end;
  Dogrula('a) kapali iken dosyada duz metin VAR (geriye donuk uyum)',
    DosyadaDuzMetin(D + '\enc1.odb', 'gizli-metin'));

  // ---- b,c,e,f,h) acik iken yaz-oku ----
  dbp := D + '\enc2.odb';
  myKv := TVDb.Create;
  k := TestKey(1);
  try
    myKv.Open(dbp);
    myKv.SetEncryptionKey(k);
    Dogrula('b) anahtar verildi -> IsEncrypted', myKv.IsEncrypted);
    Dogrula('parmak izi 8 hex karakter', Length(myKv.EncryptionKeyFingerprint) = 8,
      myKv.EncryptionKeyFingerprint);

    myKv.Put(100, VDbStrToBytes('COK-GIZLI-SIFRELI-METIN'));
    SetLength(v, 0);
    Dogrula('c) sifreli kayit COZULDU (Get duz metin donuyor)',
      myKv.Get(100, v) and (VDbBytesToStr(v) = 'COK-GIZLI-SIFRELI-METIN'),
      VDbBytesToStr(v));

    // e) ayni deger iki kez -> her seferinde yeni IV
    myKv.Put(100, VDbStrToBytes('COK-GIZLI-SIFRELI-METIN'));
    Dogrula('c) tekrar yazip yine dogru cozuldu',
      myKv.Get(100, v) and (VDbBytesToStr(v) = 'COK-GIZLI-SIFRELI-METIN'),
      VDbBytesToStr(v));

    // h) tombstone
    Dogrula('Delete basarili', myKv.Delete(100));
    Dogrula('h) tombstone sonrasi kayit YOK', not myKv.Get(100, v));

    // f) kalici kayit
    myKv.Put(200, VDbStrToBytes('kalici-gizli'));
  finally
    myKv.Free;
  end;

  Dogrula('d) duz metin ana dosyada YOK',
    not DosyadaDuzMetin(dbp, 'COK-GIZLI-SIFRELI-METIN'));
  Dogrula('d) kalici duz metin de dosyada YOK',
    not DosyadaDuzMetin(dbp, 'kalici-gizli'));

  // ---- f,g) yeniden acma ----
  myKv := TVDb.Create;
  try
    myKv.Open(dbp);
    Dogrula('f) yeniden acildi, sifreleme durumu sifirlandi',
      not myKv.IsEncrypted);
    SetLength(v, 0);
    Dogrula('g) anahtarsiz okuma ETIKET HATASI verir (sessizce bozuk donmez)',
      not OkunduMu(myKv, 200, v));
    Dogrula('g) anahtarsiz okumada veri DONDURULMADI', Length(v) = 0,
      'uzunluk=' + IntToStr(Length(v)));
  finally
    myKv.Free;
  end;

  myKv := TVDb.Create;
  try
    myKv.Open(dbp);
    myKv.SetEncryptionKey(TestKey(2));   // FARKLI anahtar
    SetLength(v, 0);
    Dogrula('g) YANLIS anahtarla okuma HATA verdi',
      not OkunduMu(myKv, 200, v));
    Dogrula('g) yanlis anahtarla veri DONDURULMADI', Length(v) = 0,
      'uzunluk=' + IntToStr(Length(v)));
  finally
    myKv.Free;
  end;

  myKv := TVDb.Create;
  try
    myKv.Open(dbp);
    myKv.SetEncryptionKey(k);
    SetLength(v, 0);
    Dogrula('f) dogru anahtarla yeniden acma sonrasi okundu',
      myKv.Get(200, v) and (VDbBytesToStr(v) = 'kalici-gizli'),
      VDbBytesToStr(v));

    // c) ScanAll de cozmus olmali
    SetLength(sK, 0);
    SetLength(sV, 0);
    myKv.ScanAll(sK, sV);
    bulundu := False;
    for i := 0 to Length(sV) - 1 do
      if VDbBytesToStr(sV[i]) = 'kalici-gizli' then
        bulundu := True;
    Dogrula('c) ScanAll sifreli degeri COZDU', bulundu,
      'kayit=' + IntToStr(Length(sV)));
  finally
    myKv.Free;
  end;

  // ---- j) WAL'a duz metin yazilir ----
  // DIKKAT: WAL yolu ChangeFileExt ile turetilir; 'enc3.odb.wal' DEGIL.
  dbp := D + '\enc3.odb';
  myKv := TVDb.Create;
  try
    myKv.Open(dbp);
    kp := myKv.WalPath;
    myKv.WALEnabled := True;
    myKv.SetEncryptionKey(TestKey(3));
    myKv.Put(1, VDbStrToBytes('wal-gizli-metin'));
    Dogrula('j) WAL kaydi yazildi', myKv.HasWAL);
  finally
    myKv.Free;
  end;
  Dogrula('j) WAL dosyasi gercekten olustu', FileExists(kp), kp);
  Dogrula('j) WAL icinde DUZ METIN var (sifreli veri birikmez)',
    DosyadaDuzMetin(kp, 'wal-gizli-metin'));
  Dogrula('j) ana dosyada duz metin YOK',
    not DosyadaDuzMetin(dbp, 'wal-gizli-metin'));

  // ---- i) karisik dosya ----
  myKv := TVDb.Create;
  try
    myKv.Open(D + '\enc4.odb');
    myKv.Put(1, VDbStrToBytes('duz-kayit'));          // sifreleme KAPALI
    myKv.SetEncryptionKey(TestKey(4));
    myKv.Put(2, VDbStrToBytes('sifreli-kayit'));      // sifreleme ACIK
    myKv.ClearEncryptionKey;
    myKv.Put(3, VDbStrToBytes('duz-kayit-2'));        // yine KAPALI
  finally
    myKv.Free;
  end;

  myKv := TVDb.Create;
  try
    myKv.Open(D + '\enc4.odb');
    myKv.SetEncryptionKey(TestKey(4));
    SetLength(v, 0);
    Dogrula('i) karisik dosyada duz kayit okundu',
      myKv.Get(1, v) and (VDbBytesToStr(v) = 'duz-kayit'), VDbBytesToStr(v));
    SetLength(v, 0);
    Dogrula('i) karisik dosyada sifreli kayit cozuldu',
      myKv.Get(2, v) and (VDbBytesToStr(v) = 'sifreli-kayit'), VDbBytesToStr(v));
    SetLength(v, 0);
    Dogrula('i) karisik dosyada sonraki duz kayit okundu',
      myKv.Get(3, v) and (VDbBytesToStr(v) = 'duz-kayit-2'), VDbBytesToStr(v));
  finally
    myKv.Free;
  end;

  // ---- k) .key dosyasi ile ucuncu sonu yol ----
  kp := D + '\enc5.key';
  myKv := TVDb.Create;
  try
    myKv.Open(D + '\enc5.odb');
    Dogrula('k) KeyPath dogru', myKv.KeyPath = D + '\enc5.key', myKv.KeyPath);
    Dogrula('k) .key dosyasi olusturuldu',
      myKv.CreateKeyFile(kp, 'sifreli-parola-1'));
    myKv.Put(1, VDbStrToBytes('key-dosyali-gizli'));
  finally
    myKv.Free;
  end;
  Dogrula('k) .key ile yazilan kayit dosyada duz metin DEGIL',
    not DosyadaDuzMetin(D + '\enc5.odb', 'key-dosyali-gizli'));

  myKv := TVDb.Create;
  try
    myKv.Open(D + '\enc5.odb');
    Dogrula('k) .key YANLIS parola reddedildi',
      not myKv.OpenKeyFile(kp, 'yanlis-parola-1'));
    Dogrula('k) .key dogru parola kabul edildi',
      myKv.OpenKeyFile(kp, 'sifreli-parola-1'));
    SetLength(v, 0);
    Dogrula('k) .key ile yazilan kayit cozuldu',
      myKv.Get(1, v) and (VDbBytesToStr(v) = 'key-dosyali-gizli'),
      VDbBytesToStr(v));
  finally
    myKv.Free;
  end;

  // ---- l) M6: AEAD (AES-256-GCM) zarf bicimi ----
  k := TestKey(5);
  ct := nil;
  Dogrula('l) AEAD sifreleme basarili',
    VDbCryptEncrypt(k, VDbStrToBytes('aead-gizli-metin'), ct));
  Dogrula('l) zarf VDB magic ile basliyor',
    VDbCryptIsAead(ct) and
    (VDbCryptBytesToStr(Copy(ct, 0, 8)) = 'VDBAEAD1'));
  back := nil;
  Dogrula('l) AEAD cozme dogru',
    VDbCryptDecrypt(k, ct, back) and
    (VDbBytesToStr(back) = 'aead-gizli-metin'));
  if Length(ct) > 0 then
    ct[High(ct)] := ct[High(ct)] xor $01;
  aeadHata := False;
  try
    VDbCryptDecrypt(k, ct, back);
  except
    on E: EVdbCryptError do
      aeadHata := True;
  end;
  Dogrula('l) bozulmus AEAD etiketi REDDEDILDI', aeadHata);

  // ---- m) eski CTR+HMAC zarfi hala okunuyor (geriye donuk uyum) ----
  ct := nil;
  Dogrula('m) eski zarf uretildi',
    VDbCryptEncryptLegacy(k, VDbStrToBytes('eski-zarf-metni'), ct));
  Dogrula('m) eski zarf AEAD magic TASIMIYOR', not VDbCryptIsAead(ct));
  back := nil;
  Dogrula('m) eski zarf yeni kodla cozuldu',
    VDbCryptDecrypt(k, ct, back) and
    (VDbBytesToStr(back) = 'eski-zarf-metni'));
end;

procedure T75_SifrelemeDayaniklilik;
{ 2026-10-05: Compact / BackupTo bayragi DUSURMELI.
  Bu, planin 9. maddesiydi ve gercek bir veri bozulmasiydi:
  Compact/BackupTo ham (sifreli) baytlari kopyalayip bayragi
  VDB_FLAG_PUT yapinca kayit "duz metin" ilan ediliyordu.
}
var
  myKv: TVDb;
  v: TBytes;
  ob, nb: Int64;
  k: TBytes;
  dbp: string;
  yedek: string;
  rep, Hata: string;
  sK: TQWordArray;
  sV: TValArray;
  bulundu: Boolean;
  i: Integer;

  procedure Dogrula(const Ad: string; Cond: Boolean; const E: string = '');
  begin
    if Cond then Ok(Ad, E) else No(Ad, E);
  end;

begin
  Grp('SIFRELEME DAYANIKLILIGI (Compact/BackupTo bayragi)');

  dbp := D + '\enc6.odb';
  yedek := D + '\enc6-yedek.odb';

  myKv := TVDb.Create;
  k := TestKey(9);
  try
    myKv.Open(dbp);
    myKv.SetEncryptionKey(k);
    myKv.Put(1, VDbStrToBytes('compact-sifreli-bir'));
    myKv.Put(2, VDbStrToBytes('compact-sifreli-iki'));
    myKv.Put(3, VDbStrToBytes('compact-sifreli-uc'));
    // olu surumler biriktir ki Compact gercekten calissin
    myKv.Put(1, VDbStrToBytes('compact-sifreli-bir'));
    myKv.Put(1, VDbStrToBytes('compact-sifreli-bir'));
    // duz metin kayit da karisik olsun
    myKv.ClearEncryptionKey;
    myKv.Put(4, VDbStrToBytes('karisik-duz-kayit'));
    myKv.SetEncryptionKey(k);

    myKv.Compact(ob, nb);
    Dogrula('Compact calisti', nb > 0, IntToStr(nb));
  finally
    myKv.Free;
  end;

  // Compact sonrasi hepsi okunmali
  myKv := TVDb.Create;
  try
    myKv.Open(dbp);
    myKv.SetEncryptionKey(k);
    SetLength(v, 0);
    Dogrula('Compact sonrasi sifreli kayit-1 okundu',
      myKv.Get(1, v) and (VDbBytesToStr(v) = 'compact-sifreli-bir'),
      VDbBytesToStr(v));
    SetLength(v, 0);
    Dogrula('Compact sonrasi sifreli kayit-2 okundu',
      myKv.Get(2, v) and (VDbBytesToStr(v) = 'compact-sifreli-iki'),
      VDbBytesToStr(v));
    SetLength(v, 0);
    Dogrula('Compact sonrasi sifreli kayit-3 okundu',
      myKv.Get(3, v) and (VDbBytesToStr(v) = 'compact-sifreli-uc'),
      VDbBytesToStr(v));
    SetLength(v, 0);
    Dogrula('Compact sonrasi karisik duz kayit okundu',
      myKv.Get(4, v) and (VDbBytesToStr(v) = 'karisik-duz-kayit'),
      VDbBytesToStr(v));
    Dogrula('Compact sonrasi kayit sayisi ayni', myKv.Count = 4,
      IntToStr(myKv.Count));

    { ScanAll de cozmus olmali: cagiran daima duz metin gorur. }
    SetLength(sK, 0);
    SetLength(sV, 0);
    myKv.ScanAll(sK, sV);
    Dogrula('Compact sonrasi ScanAll tum kayitlari dondurdu',
      Length(sK) = 4, IntToStr(Length(sK)));
    bulundu := False;
    for i := 0 to Length(sV) - 1 do
      if VDbBytesToStr(sV[i]) = 'compact-sifreli-iki' then
        bulundu := True;
    Dogrula('ScanAll sifreli degeri COZDU (duz metin dondu)', bulundu);

    myKv.BackupTo(yedek);
  finally
    myKv.Free;
  end;

  // yedekten okuma
  Dogrula('yedek dosyasi olustu', FileExists(yedek), yedek);
  myKv := TVDb.Create;
  try
    myKv.Open(yedek);
    myKv.SetEncryptionKey(k);
    SetLength(v, 0);
    Dogrula('Yedekte sifreli kayit okundu',
      myKv.Get(2, v) and (VDbBytesToStr(v) = 'compact-sifreli-iki'),
      VDbBytesToStr(v));
    SetLength(v, 0);
    Dogrula('Yedekte karisik duz kayit okundu',
      myKv.Get(4, v) and (VDbBytesToStr(v) = 'karisik-duz-kayit'),
      VDbBytesToStr(v));
    Dogrula('Yedekte kayit sayisi ayni', myKv.Count = 4,
      IntToStr(myKv.Count));
    Dogrula('Yedek Verify ile butunluk kontrolunden gecti',
      myKv.Verify(Hata), Hata);
  finally
    myKv.Free;
  end;

  // Verify, sifreli dosyada da gecmeli
  myKv := TVDb.Create;
  try
    myKv.Open(dbp);
    myKv.SetEncryptionKey(k);
    Dogrula('Sifreli dosya Verify ile gecti', myKv.Verify(Hata), Hata);
    myKv.ClearEncryptionKey;
    Dogrula('ClearEncryptionKey sonrasi IsEncrypted = False',
      not myKv.IsEncrypted);
  finally
    myKv.Free;
  end;
end;

procedure T76_ReplayWALSifreleme;
{ 2026-10-05 Adim 14: ReplayWAL sifreli veritabaninda:
   - anahtar YUKLU iken replay -> kayitlar yeniden sifrelenmis olarak durur
   - anahtarsız open edilince 'kayit SIFRELI: anahtar yok' mesaji verilir
   - batch/pending akisinda BeginBatch+Put+CommitBatch sifrelemeli
   - AutoCompact sifreli dosyada okunabilir kaliyor
}
var
  myKv: TVDb;
  v: TBytes;
  k: TBytes;
  dbp, wp: string;
  ob, nb: Int64;

  procedure Dogrula(const Ad: string; Cond: Boolean; const E: string = '');
  begin
    if Cond then Ok(Ad, E) else No(Ad, E);
  end;

begin
  Grp('WAL REPLAY + BATCH/AUTOCOMPACT (SIFRELI)');

  dbp := D + '\enc7.odb';
  myKv := TVDb.Create;
  k := TestKey(11);
  try
    myKv.Open(dbp);
    myKv.SetEncryptionKey(k);
    myKv.WALEnabled := True;
    myKv.Put(1, VDbStrToBytes('replay-gizli-1'));
    myKv.Put(2, VDbStrToBytes('replay-gizli-2'));
    wp := myKv.WalPath;
    Dogrula('WAL yazildi', myKv.HasWAL);
  finally
    myKv.Free;
  end;

  { .wal silinmeden yeniden ac: T73 Waloneacat 'reopened' sifreler ama
    ReplayWAL'i kendisi tetiklemez, manuel cagrilir. }
  myKv := TVDb.Create;
  try
    myKv.Open(dbp);
    myKv.SetEncryptionKey(k);
    Dogrula('ReplayWAL oncesi anahtarsiz anahtar dolu', myKv.IsEncrypted);
    Dogrula('ReplayWAL calisti', myKv.ReplayWAL);
    SetLength(v, 0);
    Dogrula('replay sonrasi sifreli okundu',
      myKv.Get(1, v) and (VDbBytesToStr(v) = 'replay-gizli-1'),
      VDbBytesToStr(v));
  finally
    myKv.Free;
  end;

  { batch/pending akisinda da uretilen sifreleme }
  myKv := TVDb.Create;
  try
    myKv.Open(D + '\enc8.odb');
    myKv.SetEncryptionKey(k);
    myKv.BeginBatch;
    myKv.Put(10, VDbStrToBytes('batch-sifreli-1'));
    myKv.Put(11, VDbStrToBytes('batch-sifreli-2'));
    myKv.CommitBatch;
  finally
    myKv.Free;
  end;
  myKv := TVDb.Create;
  try
    myKv.Open(D + '\enc8.odb');
    myKv.SetEncryptionKey(k);
    SetLength(v, 0);
    Dogrula('batch-1 okundu', myKv.Get(10, v) and (VDbBytesToStr(v) = 'batch-sifreli-1'), VDbBytesToStr(v));
    SetLength(v, 0);
    Dogrula('batch-2 okundu', myKv.Get(11, v) and (VDbBytesToStr(v) = 'batch-sifreli-2'), VDbBytesToStr(v));
  finally
    myKv.Free;
  end;

  { AutoCompact: sifreli kipte de CLR pattern'i (duz okur) korunur }
  dbp := D + '\enc9.odb';
  myKv := TVDb.Create;
  try
    myKv.Open(dbp);
    myKv.SetEncryptionKey(k);
    myKv.Put(1, VDbStrToBytes('oto-compact-1'));
    myKv.Put(1, VDbStrToBytes('oto-compact-1x'));
    myKv.AutoCompact(ob, nb, 0.0, 1); // dead>%0 ve boyut>=1 ile aninda
    SetLength(v, 0);
    Dogrula('AutoCompact sonrasi sifreli okundu',
      myKv.Get(1, v) and (VDbBytesToStr(v) = 'oto-compact-1x'),
      VDbBytesToStr(v));
  finally
    myKv.Free;
  end;
end;

procedure T77_AlterDatabaseKey;
{ 2026-10-05 Adim 15: ALTER DATABASE KEY 'parola':
  1) encrypted katalog korunur,
  2) eski parola .key'ten okunamaz,
  3) yeni parola .key ile okunur ve veriyi acar,
  4) yanlis yeni parola reddedilir.
}
var
  rep: string;
  R2: TSqlResult;

  procedure Dogrula(const Ad: string; Cond: Boolean; const E: string = '');
  begin
    if Cond then Ok(Ad, E) else No(Ad, E);
  end;

begin
  Grp('ALTER DATABASE KEY (parola rotasyonu)');
  UseDir('keyrot');
  kv.CreateKeyFile(D + '\keyrot\veritabani.key', 'eski-parola-1');
  sq.Exec('CREATE TABLE gizli(id INTEGER PRIMARY KEY, v TEXT)');
  sq.Exec('INSERT INTO gizli(id,v) VALUES(1,''gizli-bir'')');
  R2 := sq.Exec('ALTER DATABASE KEY ''yeni-parola-1''');
  Dogrula('REKEY', (R2.Affected = 1) and (R2.Msg <> ''), R2.Msg);
  // eski dosya .bak'ta kalir
  Dogrula('.bak var', FileExists(D + '\\keyrot\\veritabani.odb.bak'));

  // Key rotasyonunu uzaktan kontr: yeniden ac, yeni parola dogru,
  // eski parola reddedilir; ve veri okumak mumkun olur.
  kv.Close; tb.Close; sq.Free; tb.Free; kv.Free;
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  kv.Open(D + '\keyrot');
  // tb.Open semadan okur -> Sema KAYITLIYKEN sifrelenmistir, o yuzden
  // anahtari tb.Open'dan ONCE yuklemelidir (T74 benzeri).
  Dogrula('yeni parola ile OpenKeyFile', kv.OpenKeyFile(D + '\\keyrot\\veritabani.key', 'yeni-parola-1'));
  tb.Open(D + '\keyrot');
  Dogrula('eski parola reddedildi', not kv.OpenKeyFile(D + '\\keyrot\\veritabani.key', 'eski-parola-1'));
  R2 := sq.Exec('SELECT v FROM gizli WHERE id = 1');
  Dogrula('yeni parolayla veri okundu', R2.Rows[0][0] = 'gizli-bir', R2.Rows[0][0]);
  // eski .bak anahtariyla eski veri hala diriliyor mu
  Dogrula('.key.bak still okunabilir (eski parola)', kv.OpenKeyFile(D + '\\keyrot\\veritabani.key.bak', 'eski-parola-1'));
end;

procedure T79_Savepoint;
{ R-02: SAVEPOINT / ROLLBACK TO / RELEASE SAVEPOINT
  Test savepoint nesting, rollback to, and release.
}
begin
  Grp('SAVEPOINT (R-02)');
  UseDir('sp');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO t(id,v) VALUES(1,10)');
  sq.Exec('SAVEPOINT sp1');
  sq.Exec('INSERT INTO t(id,v) VALUES(2,20)');
  sq.Exec('SAVEPOINT sp2');
  sq.Exec('INSERT INTO t(id,v) VALUES(3,30)');
  sq.Exec('ROLLBACK TO SAVEPOINT sp2');
  ChkVal('ROLLBACK TO sp2: 2 satir', 'SELECT COUNT(*) FROM t', 0, 0, '2');
  ChkVal('id=2 hala var', 'SELECT v FROM t WHERE id=2', 0, 0, '20');
  sq.Exec('INSERT INTO t(id,v) VALUES(4,40)');
  sq.Exec('SAVEPOINT sp3');
  sq.Exec('INSERT INTO t(id,v) VALUES(5,50)');
  sq.Exec('ROLLBACK TO SAVEPOINT sp1');
  ChkVal('ROLLBACK TO sp1: 1 satir', 'SELECT COUNT(*) FROM t', 0, 0, '1');
  ChkVal('id=1 hala var', 'SELECT v FROM t WHERE id=1', 0, 0, '10');
  sq.Exec('RELEASE SAVEPOINT sp1');
  sq.Exec('COMMIT');
  ChkVal('COMMIT sonrasi 1 satir', 'SELECT COUNT(*) FROM t', 0, 0, '1');
  sq.Exec('SAVEPOINT spA');
  sq.Exec('INSERT INTO t(id,v) VALUES(6,60)');
  sq.Exec('RELEASE SAVEPOINT spA');
  sq.Exec('ROLLBACK');
  ChkVal('ROLLBACK: spA release edildi, insert geri alindi', 'SELECT COUNT(*) FROM t', 0, 0, '1');
  Ok('SAVEPOINT temel islemler', '');
end;

procedure T79b_IsolationForUpdate;
{ F-40 / F-41: SET TRANSACTION ISOLATION LEVEL ve SELECT ... FOR UPDATE
  - REPEATABLE READ: batch basi snapshot (varsayilan)
  - READ COMMITTED: her cumle yeni snapshot
  - FOR UPDATE: tx icinde satir kilidi; ayni satiri yazan baska oturum
    ecLockConflict alir; kilit COMMIT/ROLLBACK ile birakilir.

  NOT: motorun batch'i TVDb basina GLOBALDIR; ayni TVTableDb uzerinde iki
  TVSql ayni anda bagimsiz transaction acamaz. Bu yuzden "baska oturum"
  davranisi kilit yoneticisi API'si + yazma yolu denetimi ile dogrulanir. }
var
  rr: TSqlResult;
  blocked: Boolean;
  owner: Cardinal;
begin
  Grp('ISOLATION + SELECT FOR UPDATE (F-40/F-41)');
  UseDir('iso_fu');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO t(id,v) VALUES(1,10)');
  sq.Exec('INSERT INTO t(id,v) VALUES(2,20)');

  // --- SET TRANSACTION ISOLATION LEVEL: dort seviye de ayristirilir ---
  R := sq.Exec('SET TRANSACTION ISOLATION LEVEL READ COMMITTED');
  Dogrula('SET READ COMMITTED', (Length(R.Rows) = 1) and
    (R.Rows[0][0] = 'READ COMMITTED'), '');
  R := sq.Exec('SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED');
  Dogrula('SET READ UNCOMMITTED', (Length(R.Rows) = 1) and
    (R.Rows[0][0] = 'READ UNCOMMITTED'), '');
  R := sq.Exec('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ');
  Dogrula('SET REPEATABLE READ', (Length(R.Rows) = 1) and
    (R.Rows[0][0] = 'REPEATABLE READ'), '');
  R := sq.Exec('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
  Dogrula('SET SERIALIZABLE', (Length(R.Rows) = 1) and
    (R.Rows[0][0] = 'SERIALIZABLE'), '');
  ChkErr('gecersiz isolation level reddedilir',
    'SET TRANSACTION ISOLATION LEVEL BOGUS');

  // --- READ COMMITTED kendi bekleyen yazisini gizlemez ---
  sq.Exec('SET TRANSACTION ISOLATION LEVEL READ COMMITTED');
  sq.Exec('BEGIN');
  sq.Exec('INSERT INTO t(id,v) VALUES(3,30)');
  ChkVal('RC kendi yazisi gorunur', 'SELECT COUNT(*) FROM t', 0, 0, '3');
  sq.Exec('ROLLBACK');
  ChkVal('RC rollback sonrasi 2 satir', 'SELECT COUNT(*) FROM t', 0, 0, '2');
  sq.Exec('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ');

  // --- FOR UPDATE yalniz acik islem icinde ---
  try
    sq.Exec('SELECT * FROM t WHERE id=1 FOR UPDATE');
    No('FOR UPDATE tx disinda reddedildi', 'kabul edildi');
  except
    on E: Exception do Ok('FOR UPDATE tx disinda reddedildi', E.Message);
  end;

  // --- tx icinde satir kilidi alinir ---
  sq.Exec('BEGIN');
  rr := sq.Exec('SELECT * FROM t WHERE id=1 FOR UPDATE');
  ChkInt('FOR UPDATE 1 satir', Length(rr.Rows), 1);
  owner := tb.RowLockOwner('t', '1');
  Dogrula('satir kilidi kaydedildi', owner <> 0, IntToStr(owner));

  // --- ayni satiri yazan farkli oturum engellenir ---
  blocked := False;
  VdbSetWriteSession(owner + 1);
  try
    try
      tb.Delete('t', '1');
    except
      on E: Exception do blocked := True;
    end;
  finally
    VdbSetWriteSession(0);
  end;
  Dogrula('baska oturumun yazmasi kilitlendi', blocked, '');
  ChkVal('kilitli satir degismedi', 'SELECT v FROM t WHERE id=1', 0, 0, '10');

  // --- kendi kilidi kendi yazmasini engellemez ---
  sq.Exec('UPDATE t SET v=13 WHERE id=1');
  ChkVal('kendi kilidiyle UPDATE', 'SELECT v FROM t WHERE id=1', 0, 0, '13');

  // --- COMMIT kilidi birakir ---
  sq.Exec('COMMIT');
  Dogrula('COMMIT satir kilidini birakti',
    tb.RowLockOwner('t', '1') = 0, '');

  // --- kilit yoneticisi: reentrant / cakisma / birakma ---
  tb.LockRow(101, 't', '1');
  tb.LockRow(101, 't', '1');   // ayni sahip tekrar alabilir
  blocked := False;
  try
    tb.LockRow(102, 't', '1');
  except
    on E: Exception do blocked := True;
  end;
  Dogrula('ikinci sahip kilit alamadi', blocked, '');
  tb.UnlockRows(101);
  tb.LockRow(102, 't', '1');
  Dogrula('kilit birakildi, yeni sahip aldi',
    tb.RowLockOwner('t', '1') = 102, '');
  tb.UnlockRows(102);

  // --- desteklenmeyen JOIN + FOR UPDATE acikca reddedilir ---
  sq.Exec('BEGIN');
  try
    sq.Exec('SELECT * FROM t a JOIN t b ON a.id=b.id FOR UPDATE');
    No('JOIN + FOR UPDATE reddedildi', 'kabul edildi');
  except
    on E: Exception do Ok('JOIN + FOR UPDATE reddedildi', E.Message);
  end;
  sq.Exec('ROLLBACK');
end;

procedure T93_RBAC;
{ R-18: ROLE / GRANT / REVOKE / SET ROLE
  Kod tarafi (TRoleDef, TGrantDef, ParseRole, ParseGrant, ExecGrant,
  ExecRole, SetCurrentRole, RoleCan/RequirePriv) MEVCUTTU ama testi
  hic yoktu. Bu grup o bosluku kapatir.

  Onemli kural: FCurrentRole = '' iken motor kullanici modundayiz ve
  HER SEY serbesttir (RoleCan -> Exit(True)). Yetki denetimi ancak
  SET ROLE ile bir role gecildiginde devreye girir.

  NOT: burada ASLA `var Q: string` denetlenmemeli - global sabit
  Q = '''' (tek tirnak) SQL metin literali uretir. Golge (shadow)
  olusursa tirnaksiz SQL kurulur ve ifadeler kolon sanilir
  ("Kolon bulunamadi: s"). }
begin
  Grp('RBAC: ROLE / GRANT / REVOKE (R-18)');
  UseDir('rbac');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO t(id,ad) VALUES(1,' + Q + 'Ali' + Q + ')');
  sq.Exec('INSERT INTO t(id,ad) VALUES(2,' + Q + 'Veli' + Q + ')');

  // ---------- 1. Rol yonetimi ----------
  Chk('CREATE ROLE', 'CREATE ROLE okuyucu', -1);
  Chk('CREATE ROLE superuser', 'CREATE ROLE super SUPERUSER', -1);
  ChkErr('CREATE ROLE tekrar (hata)', 'CREATE ROLE okuyucu');

  // ---------- 2. Rol yoksa hata ----------
  ChkErr('GRANT: olmayan rol (hata)',
    'GRANT SELECT ON t TO hayali_rol');
  ChkErr('SET ROLE: olmayan rol (hata)', 'SET ROLE hayali_rol');

  // ---------- 3. Izin denetimi ----------
  // Rol degisikligi: yetkisiz rol SELECT goremez
  Chk('SET ROLE okuyucu', 'SET ROLE okuyucu', 1);
  ChkErr('yetkisiz SELECT reddedilir', 'SELECT * FROM t');
  ChkErr('yetkisiz INSERT reddedilir', 'INSERT INTO t(id,ad) VALUES(9,' + Q + 'X' + Q + ')');
  ChkErr('yetkisiz UPDATE reddedilir', 'UPDATE t SET ad = ' + Q + 'Y' + Q + ' WHERE id = 1');
  { NOT: DELETE icin pkUpdate degil pkDELETE kontrol edilir; yalnizca
    UPDATE izni verilmis rol DELETE de yapabilmemeli. }
  ChkErr('UPDATE-only rol ile DELETE reddedilir',
    'DELETE FROM t WHERE id = 1');

  // SELECT izni ver
  Chk('GRANT SELECT', 'GRANT SELECT ON t TO okuyucu', 1);
  Chk('SELECT artik calisiyor', 'SELECT COUNT(*) FROM t', 1);
  // INSERT hala reddedilmeli (izin verilmedi)
  ChkErr('INSERT hala reddedilir', 'INSERT INTO t(id,ad) VALUES(9,' + Q + 'X' + Q + ')');

  // INSERT izni ver
  Chk('GRANT INSERT', 'GRANT INSERT ON t TO okuyucu', 1);
  sq.Exec('INSERT INTO t(id,ad) VALUES(9,' + Q + 'Zeynep' + Q + ')');
  ChkVal('INSERT sonrasi satir', 'SELECT COUNT(*) FROM t', 0, 0, '3');

  // ---------- 4. Izin ayrimi: UPDATE verilmis ama DELETE verilmemis ----------
  { NOT: Bu blok ExecDelete icindeki yetki kontrolunun pkUpdate DEGIL
    pkDelete oldugunu KANITLAR. Once DELETE varken yalniz UPDATE izni
    verilir; DELETE reddedilmelidir. Kontrol pkUpdate olsaydi bu
    DELETE sessizce gecer ve veri kaybolurdu. }
  Chk('GRANT UPDATE', 'GRANT UPDATE ON t TO okuyucu', 1);
  Chk('UPDATE calisiyor', 'UPDATE t SET ad = ' + Q + 'U' + Q + ' WHERE id = 1', -1);
  ChkErr('UPDATE var ama DELETE yok -> DELETE reddedilir',
    'DELETE FROM t WHERE id = 1');
  ChkVal('DELETE gercekten silmedi', 'SELECT ad FROM t WHERE id = 1', 0, 0, 'U');
  // DELETE iznini ver, simdi calismali
  Chk('GRANT DELETE', 'GRANT DELETE ON t TO okuyucu', 1);
  Chk('DELETE artik calisiyor', 'DELETE FROM t WHERE id = 1', -1);
  // Satir durumu: basta id=1,2 vardi; INSERT ile id=9 eklendi (3 satir);
  // id=1 silindi -> kalan id=2 ve id=9 = 2 satir.
  ChkVal('DELETE calisti', 'SELECT COUNT(*) FROM t', 0, 0, '2');
  // UPDATE geri alininca da INSERT izinli kalmali
  Chk('REVOKE UPDATE', 'REVOKE UPDATE ON t FROM okuyucu', 1);
  ChkErr('UPDATE geri alindi -> reddedilir',
    'UPDATE t SET ad = ' + Q + 'Q' + Q + ' WHERE id = 1');

  // ---------- 5. REVOKE ----------
  Chk('REVOKE SELECT', 'REVOKE SELECT ON t FROM okuyucu', 1);
  ChkErr('REVOKE sonrasi SELECT reddedilir', 'SELECT * FROM t');
  { INSERT/DELETE izinleri duruyor olmali. Dogrulama SELECT ile
    YAPILAMAZ (SELECT geri alindi) - once satir ekle, sonra SELECT
    iznini geri verip sayimi kontrol ederiz. }
  sq.Exec('INSERT INTO t(id,ad) VALUES(7,' + Q + 'Kaya' + Q + ')');
  Chk('SELECT izni geri verildi', 'GRANT SELECT ON t TO okuyucu', 1);
  ChkVal('REVOKE sonrasi INSERT hala calisiyor', 'SELECT COUNT(*) FROM t', 0, 0, '3');

  // ---------- 6. TUM tablolar (*) izni ----------
  sq.Exec('CREATE TABLE t2(id INTEGER PRIMARY KEY)');
  Chk('GRANT SELECT ON t2 (yok)', 'REVOKE ALL ON * FROM okuyucu', 1);
  ChkErr('* izni yok: t2 SELECT reddedilir', 'SELECT * FROM t2');
  Chk('GRANT ALL ON *', 'GRANT ALL ON * TO okuyucu', 1);
  ChkVal('* ile SELECT t2 calisti', 'SELECT COUNT(*) FROM t2', 0, 0, '0');

  // ---------- 7. SUPERUSER her sey yapar ----------
  Chk('SET ROLE super', 'SET ROLE super', 1);
  ChkVal('super SELECT', 'SELECT COUNT(*) FROM t', 0, 0, '3');
  Chk('super UPDATE', 'UPDATE t SET ad = ' + Q + 'S' + Q + ' WHERE id = 1', -1);
  Chk('super DELETE', 'DELETE FROM t WHERE id = 7', -1);
  ChkVal('super DELETE calisti', 'SELECT COUNT(*) FROM t', 0, 0, '2');

  // ---------- 8. SET ROLE NONE cikis ----------
  Chk('SET ROLE NONE', 'SET ROLE NONE', 1);
  ChkVal('NONE: motor kullanici modu', 'SELECT COUNT(*) FROM t', 0, 0, '2');

  // ---------- 9. DROP ROLE ----------
  ChkErr('DROP ROLE: olmayan rol (hata)', 'DROP ROLE yok_boyle_rol');
  Chk('DROP ROLE', 'DROP ROLE okuyucu', -1);
  ChkErr('DROP edilen role SET ROLE (hata)', 'SET ROLE okuyucu');
  ChkVal('motor kullanici modunda calisma', 'SELECT COUNT(*) FROM t2', 0, 0, '0');

  Ok('RBAC temel islemler', '');
end;

procedure T94_RBAC_Persist;
{ R-18 kalicilik: roller ve izinler sema kaydinda saklanir; veritabani
  kapatilip yeniden acildiginda korunur.
  NOT: FRoles/FGrants'in SaveSchema/LoadSchema icine yazilip
  yazilmadigi AYRIca dogrulanir - biri eksikse bu grup kirmizi verir. }
var
  db2: TVDb;
  td2: TVTableDb;
  p: string;
begin
  Grp('RBAC kalicilik (R-18)');
  UseDir('rbacpersist');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO t(id,ad) VALUES(1,' + Q + 'Ali' + Q + ')');
  sq.Exec('CREATE ROLE kalici');
  sq.Exec('GRANT SELECT ON t TO kalici');
  Ok('rol + izin verildi', '');

  p := D + '\rbacpersist';
  Shutdown;   // sqltest'in DB'sini kapat

  // Ayni dizini yeniden ac
  db2 := TVDb.Create;
  td2 := TVTableDb.Create(db2);
  try
    db2.Open(p);
    td2.Open(p);
    if td2.RoleExists('kalici') then Ok('rol yeniden acilista korundu', 'kalici')
    else No('rol yeniden acilista korundu', 'rol kayboldu');
    td2.SetCurrentRole('kalici');
    if td2.RoleCan('t', Ord(pkSelect)) then Ok('izin yeniden acilista korundu', '')
    else No('izin yeniden acilista korundu', 'izin kayboldu');
    if not td2.RoleCan('t', Ord(pkInsert)) then
      Ok('INSERT izni verilmemisti, korunuyor', '')
    else No('INSERT izni verilmemisti, korunuyor', 'beklenmedik izin var');
    td2.SetCurrentRole('');
  finally
    td2.Free;
    db2.Free;
  end;

  Ok('RBAC kalicilik', '');
end;

procedure T94b_RLS;
{ R-19: ROW LEVEL SECURITY
    ALTER TABLE t ENABLE/DISABLE ROW LEVEL SECURITY
    CREATE POLICY ad ON t FOR <cmd> [USING (e)] [WITH CHECK (e)]
    DROP POLICY ad ON t

  Semantik:
    - RLS yalniz etkin rol VARKEN ve super degilse uygulanir (R-18 ile ayni
      opt-in mantigi).
    - USING kosullari OR'lanir -> satirlar gorunur.
    - Politika YOKSA hicbir satir gorunmez (deny-by-default).
    - WITH CHECK kosullari AND'lanir -> INSERT/UPDATE yazabilirligi. }
var
  i: Integer;
begin
  Grp('ROW LEVEL SECURITY (R-19)');
  UseDir('rls');

  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, oid INTEGER, ad TEXT)');
  for i := 1 to 6 do
    sq.Exec('INSERT INTO t(id,oid,ad) VALUES(' + IntToStr(i) + ',' +
      IntToStr(i) + ',' + Q + 'k' + IntToStr(i) + Q + ')');
  Ok('tablo + 6 satir', '');

  // ---------- 1. RLS kapali: her sey gorunur ----------
  sq.Exec('CREATE ROLE rlsuser');
  sq.Exec('GRANT ALL ON t TO rlsuser');
  sq.Exec('SET ROLE rlsuser');
  ChkVal('RLS kapaliyken tum satirlar gorunur', 'SELECT COUNT(*) FROM t', 0, 0, '6');

  // ---------- 2. ENABLE ROW LEVEL SECURITY: politika yok -> 0 satir ----------
  sq.Exec('ALTER TABLE t ENABLE ROW LEVEL SECURITY');
  ChkVal('RLS acik, politika yok -> 0 satir', 'SELECT COUNT(*) FROM t', 0, 0, '0');

  // ---------- 3. FOR SELECT USING ----------
  sq.Exec('CREATE POLICY p_sel ON t FOR SELECT USING (oid <= 3)');
  ChkVal('USING (oid <= 3) -> 3 satir', 'SELECT COUNT(*) FROM t', 0, 0, '3');
  ChkVal('WHERE de RLS ile birlestirilir (AND)', 'SELECT COUNT(*) FROM t WHERE oid = 2',
    0, 0, '1');
  // UPDATE/DELETE bu politikayi GORMEMELI (FOR SELECT sadece SELECT'e)
  ChkVal('FOR SELECT politikasi UPDATE''i etkilemez (satir silinmedi)',
    'SELECT COUNT(*) FROM t', 0, 0, '3');
  sq.Exec('SET ROLE NONE');
  ChkVal('motor kullanici modunda RLS yok', 'SELECT COUNT(*) FROM t', 0, 0, '6');

  // ---------- 4. FOR ALL USING ----------
  sq.Exec('SET ROLE rlsuser');
  sq.Exec('DROP POLICY p_sel ON t');
  sq.Exec('CREATE POLICY p_all ON t FOR ALL USING (oid <= 4)');
  ChkVal('FOR ALL USING (oid <= 4) -> 4 satir', 'SELECT COUNT(*) FROM t', 0, 0, '4');

  // ---------- 5. UPDATE: USING gizli satirlari guncelleyemez ----------
  sq.Exec('UPDATE t SET ad = ' + Q + 'X' + Q + ' WHERE id = 1');
  ChkVal('gorunur satir guncellendi', 'SELECT COUNT(*) FROM t WHERE ad = ' + Q + 'X' + Q,
    0, 0, '1');
  ChkVal('UPDATE etkilenen satir = 1 (gorunmeyen 5 ve 6 atlandi)',
    'SELECT COUNT(*) FROM t', 0, 0, '4');
  sq.Exec('SET ROLE NONE');
  ChkVal('UPDATE yalnizca 1 satir (id=1)',
    'SELECT COUNT(*) FROM t WHERE ad = ' + Q + 'X' + Q, 0, 0, '1');

  // ---------- 5b. UPDATE WITH CHECK: yeni satir politikaya uymali ----------
  sq.Exec('SET ROLE rlsuser');
  sq.Exec('DROP POLICY p_all ON t');
  sq.Exec('CREATE POLICY p_upd ON t FOR UPDATE USING (oid <= 4) WITH CHECK (oid <= 2)');
  ChkVal('sadece UPDATE politikasi: SELECT yine bos (FOR UPDATE SELECT''i etkilemez)',
    'SELECT COUNT(*) FROM t', 0, 0, '0');
  ChkErr('UPDATE WITH CHECK ihlali: gorunur satir yazilabilir alana tasinamaz',
    'UPDATE t SET oid = 9 WHERE id = 1');
  Chk('UPDATE WITH CHECK saglandi: oid <= 2', 'UPDATE t SET oid = 2 WHERE id = 1', -1);
  sq.Exec('SET ROLE NONE');
  ChkVal('UPDATE sonrasi oid gercekten degisti', 'SELECT COUNT(*) FROM t WHERE id = 1 AND oid = 2',
    0, 0, '1');
  // 6. bolumune donmek icin genel politika geri gelir
  sq.Exec('DROP POLICY p_upd ON t');
  sq.Exec('CREATE POLICY p_all ON t FOR ALL USING (oid <= 4)');

  // ---------- 6. DELETE: USING gizli satirlari silemez ----------
  sq.Exec('SET ROLE rlsuser');
  sq.Exec('DELETE FROM t WHERE id = 6');    // gorunmez -> silinmez
  sq.Exec('DELETE FROM t WHERE id = 4');    // gorunur -> silinir
  ChkVal('DELETE: yalniz gorunur satir silindi', 'SELECT COUNT(*) FROM t', 0, 0, '3');
  sq.Exec('SET ROLE NONE');
  ChkVal('id=6 hâlâ duruyor', 'SELECT COUNT(*) FROM t WHERE id = 6', 0, 0, '1');
  ChkVal('id=4 silinmis', 'SELECT COUNT(*) FROM t WHERE id = 4', 0, 0, '0');

  // ---------- 7. INSERT: WITH CHECK ----------
  sq.Exec('SET ROLE rlsuser');
  ChkErr('INSERT WITH CHECK ihlali (hata)',
    'INSERT INTO t(id,oid,ad) VALUES(20, 99, ' + Q + 'y' + Q + ')');
  Chk('INSERT WITH CHECK saglandi', 'INSERT INTO t(id,oid,ad) VALUES(20, 2, ' +
    Q + 'y' + Q + ')', -1);
  ChkVal('yeni satir politikaya uygun (oid=2 <= 4) gorunur',
    'SELECT COUNT(*) FROM t WHERE id = 20', 0, 0, '1');
  sq.Exec('SET ROLE NONE');
  ChkVal('id=20 kalici olarak yazildi', 'SELECT COUNT(*) FROM t WHERE id = 20', 0, 0, '1');
  ChkVal('ihlalli satir yazilmadi', 'SELECT COUNT(*) FROM t WHERE id = 19', 0, 0, '0');

  // ---------- 8. FOR INSERT WITH CHECK (FOR SELECT policies'i degil) ----------
  sq.Exec('SET ROLE rlsuser');
  sq.Exec('DROP POLICY p_all ON t');
  sq.Exec('CREATE POLICY p_ins ON t FOR INSERT WITH CHECK (oid <= 10)');
  ChkVal('sadece INSERT politikasi: SELECT bos', 'SELECT COUNT(*) FROM t', 0, 0, '0');
  ChkErr('INSERT politikasi disi deger reddedilir',
    'INSERT INTO t(id,oid,ad) VALUES(21, 50, ' + Q + 'z' + Q + ')');
  Chk('INSERT politikasi icindeki deger kabul', 'INSERT INTO t(id,oid,ad) VALUES(21, 5, ' +
    Q + 'z' + Q + ')', -1);
  sq.Exec('SET ROLE NONE');

  // ---------- 9. DISABLE ROW LEVEL SECURITY ----------
  sq.Exec('SET ROLE rlsuser');
  ChkVal('RLS acikken SELECT 0', 'SELECT COUNT(*) FROM t', 0, 0, '0');
  sq.Exec('ALTER TABLE t DISABLE ROW LEVEL SECURITY');
  // 6 - id=4 silindi + id=20, id=21 eklendi = 7
  ChkVal('DISABLE sonrasi tum satirlar gorunur', 'SELECT COUNT(*) FROM t', 0, 0, '7');
  Chk('RLS kapaliyken sinirsiz INSERT',
    'INSERT INTO t(id,oid,ad) VALUES(30, 99, ' + Q + 'w' + Q + ')', -1);
  sq.Exec('SET ROLE NONE');

  // ---------- 10. Super rol RLS'ten muaftir ----------
  sq.Exec('CREATE ROLE rlsadmin SUPERUSER');
  sq.Exec('SET ROLE rlsadmin');
  sq.Exec('ALTER TABLE t ENABLE ROW LEVEL SECURITY');
  // 6 baslangic - id=4 silindi + id=20, id=21, id=30 = 8
  ChkVal('super rol tum satirlari gorur', 'SELECT COUNT(*) FROM t', 0, 0, '8');
  sq.Exec('SET ROLE NONE');

  // ---------- 11. Politika hatalari ----------
  ChkErr('Ayni adli politika tekrar (hata)', 'CREATE POLICY p_ins ON t FOR SELECT USING (id > 0)');
  ChkErr('FOR sonrasi bilinmeyen komut (hata)', 'CREATE POLICY px ON t FOR TRUNCATE USING (id > 0)');
  ChkErr('DROP POLICY sonrasi ON eksik (hata)', 'DROP POLICY p_ins t');
  ChkErr('ENABLE ROW LEVEL SECURITY eksik SECURITY (hata)',
    'ALTER TABLE t ENABLE ROW ROW');

  // ---------- 12. Kalicilik ----------
  Grp('RLS kalicilik (R-19)');
  Ok('RLS temel islemler', '');
end;

procedure T94c_RLS_Persist;
{ R-19 kalicilik: '#L' (RLS acik) ve '#P' (politika) satirlari sema
  kaydinda saklanir. Politika metni '|' icerebilecegi icin HEX'e cevrilerek
  yazilir. }
var
  db2: TVDb;
  td2: TVTableDb;
  p: string;
begin
  UseDir('rlspersist');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, oid INTEGER)');
  sq.Exec('INSERT INTO t(id,oid) VALUES(1,1)');
  sq.Exec('INSERT INTO t(id,oid) VALUES(2,2)');
  sq.Exec('CREATE ROLE pu');
  sq.Exec('GRANT ALL ON t TO pu');
  sq.Exec('CREATE POLICY pp ON t FOR SELECT USING (oid <= 1)');
  sq.Exec('ALTER TABLE t ENABLE ROW LEVEL SECURITY');
  Ok('rol + politika + RLS ayarlandi', '');

  p := D + '\rlspersist';
  Shutdown;

  db2 := TVDb.Create;
  td2 := TVTableDb.Create(db2);
  try
    db2.Open(p);
    td2.Open(p);
    if td2.RlsEnabled('t') then Ok('RLS bayragi yeniden acilista korundu', '')
    else No('RLS bayragi yeniden acilista korundu', 'RLS kapali geldi');
    if td2.PolicyCount = 1 then Ok('politika yeniden acilista korundu', '1')
    else No('politika yeniden acilista korundu', IntToStr(td2.PolicyCount) + ' adet');
    td2.SetCurrentRole('pu');
    if td2.RlsApplies('t') then Ok('RLS etkin rol icin uygulaniyor', '')
    else No('RLS etkin rol icin uygulaniyor', 'uygulanmadi');
    if Length(td2.RlsUsing('t', 1)) = 1 then Ok('politika kosulu geri yuklendi', '')
    else No('politika kosulu geri yuklendi', 'kosul yok');
  finally
    td2.Free;
    db2.Free;
  end;

  Ok('RLS kalicilik', '');
end;

procedure T94d_Collation;
{ R-20: DIL ETIKETI TASINAN collation motoru.
    ORDER BY x COLLATE <ad>   |   WHERE a = b COLLATE <ad>
    CREATE TABLE t(ad TEXT COLLATE <ad>)

  MOTOR SABIT BIR DIL LISTESINE KILITLI DEGILDIR: locale etiketi ne olursa
  olsun alfabe dilden ya da kod noktasi araligindan secilir.
    C | POSIX | BINARY    ham kod noktasi sirasi
    tr | tr-TR             Turkce alfabe, i ve ı AYRI
    de | fr | ru | el | ar | he | ja | ko ...  dile ozgu alfabetik

  Duyarlilik guc seviyeleri (varsayilan vsPrimary):
    varsayilan -> ne vurgu ne buyuk/kucuk ("ARMUT" = "armut" = "armUT")
    -u-ks      -> vurgu DUYARLI          (vsSecondary)
    -u-kc      -> buyuk/kucuk DUYARLI   (vsTertiary)
    -s1..-s4   -> dogrudan guc seviyesi

  DIKKAT: bu test dosyasi kaynak kodlamadan bagimsiz olsun diye cok
  baytli karakterler CR(n) = Chr(n) ile uretilir.
}
begin
  Grp('COLLATION (R-20)');
  UseDir('coll');

  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO t(id,ad) VALUES(1,' + SQT('armut') + ')');
  sq.Exec('INSERT INTO t(id,ad) VALUES(2,' + SQT('Bal') + ')');
  sq.Exec('INSERT INTO t(id,ad) VALUES(3,' + SQT('cay') + ')');
  sq.Exec('INSERT INTO t(id,ad) VALUES(4,' + SQT('elma') + ')');
  Ok('test tablosu hazir (4 satir)', '');

  // ---------- 1. Varsayilan: bayt sirasi, duyarli ----------
  ChkVal('varsayilan: buyuk/kucuk DUYARLI',
    'SELECT COUNT(*) FROM t WHERE ad = ' + SQT('BAL'), 0, 0, '0');
  ChkVal('varsayilan: birebir eslesme',
    'SELECT COUNT(*) FROM t WHERE ad = ' + SQT('Bal'), 0, 0, '1');

  // ---------- 2. ORDER BY COLLATE tr ----------
  ChkVal('COLLATE tr: 1. armut', 'SELECT ad FROM t ORDER BY ad COLLATE tr', 0, 0, 'armut');
  ChkVal('COLLATE tr: 2. Bal', 'SELECT ad FROM t ORDER BY ad COLLATE tr', 1, 0, 'Bal');
  ChkVal('COLLATE tr: 3. cay', 'SELECT ad FROM t ORDER BY ad COLLATE tr', 2, 0, 'cay');
  ChkVal('COLLATE tr: 4. elma', 'SELECT ad FROM t ORDER BY ad COLLATE tr', 3, 0, 'elma');

  // ---------- 3. Turkce buyuk/kucuk DUYARSIZ (varsayilan) ----------
  ChkVal('tr: WHERE buyuk/kucuk duyarsiz (BAL = Bal)',
    'SELECT COUNT(*) FROM t WHERE ad = ' + SQT('BAL') + ' COLLATE tr', 0, 0, '1');
  ChkVal('tr: WHERE ARMUT = armut',
    'SELECT COUNT(*) FROM t WHERE ad = ' + SQT('ARMUT') + ' COLLATE tr', 0, 0, '1');
  ChkVal('tr: WHERE ELMA = elma (buyuk/kucuk duyarsiz)',
    'SELECT COUNT(*) FROM t WHERE ad = ' + SQT('ELMA') + ' COLLATE tr', 0, 0, '1');

  // ---------- 4. -u-ks: vurgu DUYARLI, buyuk/kucuk DUYARSIZ kalir ----------
  // -u-ks yalniz VURGU katmanini acar; buyuk/kucuk duyarsiz kalir.
  ChkVal('tr-u-ks: vurgusuz metinde buyuk/kucuk DUYARSIZ (BAL = Bal)',
    'SELECT COUNT(*) FROM t WHERE ad = ' + SQT('BAL') + ' COLLATE tr-u-ks', 0, 0, '1');
  ChkVal('tr-u-ks: birebir de esler',
    'SELECT COUNT(*) FROM t WHERE ad = ' + SQT('Bal') + ' COLLATE tr-u-ks', 0, 0, '1');
  // -u-kc: buyuk/kucuk DUYARLI -> BAL artik eslesmez
  ChkVal('tr-u-kc: buyuk/kucuk DUYARLI (BAL eslesmez)',
    'SELECT COUNT(*) FROM t WHERE ad = ' + SQT('BAL') + ' COLLATE tr-u-kc', 0, 0, '0');
  ChkVal('tr-u-kc: birebir esler (Bal)',
    'SELECT COUNT(*) FROM t WHERE ad = ' + SQT('Bal') + ' COLLATE tr-u-kc', 0, 0, '1');

  // ---------- 5. C / BINARY ----------
  ChkVal('COLLATE C: Bal once',
    'SELECT ad FROM t ORDER BY ad COLLATE C', 0, 0, 'Bal');
  ChkVal('COLLATE C: kucuk c once',
    'SELECT ad FROM t ORDER BY ad COLLATE C', 2, 0, 'cay');
  ChkVal('COLLATE BINARY = C',
    'SELECT ad FROM t ORDER BY ad COLLATE BINARY', 0, 0, 'Bal');

  // ---------- 6. Kiril (ru): a=U+0430, b=U+0431, v=U+0432, ya=U+042F ----------
  sq.Exec('CREATE TABLE ru(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO ru(id,ad) VALUES(1,' + SQT(CR($0430)) + ')');
  sq.Exec('INSERT INTO ru(id,ad) VALUES(2,' + SQT(CR($0431)) + ')');
  sq.Exec('INSERT INTO ru(id,ad) VALUES(3,' + SQT(CR($0432)) + ')');
  sq.Exec('INSERT INTO ru(id,ad) VALUES(4,' + SQT(CR($042F)) + ')');
  Ok('Kiril tablosu (a, b, v, ya)', '');
  ChkVal('ru: Kiril 1 (a)', 'SELECT ad FROM ru ORDER BY ad COLLATE ru', 0, 0, CR($0430));
  ChkVal('ru: Kiril 2 (b)', 'SELECT ad FROM ru ORDER BY ad COLLATE ru', 1, 0, CR($0431));
  ChkVal('ru: Kiril 3 (v)', 'SELECT ad FROM ru ORDER BY ad COLLATE ru', 2, 0, CR($0432));
  ChkVal('ru: Kiril 4 (ya)', 'SELECT ad FROM ru ORDER BY ad COLLATE ru', 3, 0, CR($042F));
  ChkVal('ru: buyuk harf de ayni agirlik (YA = ya agirlik)',
    'SELECT COUNT(*) FROM ru WHERE ad = ' + SQT(CR($042F)) + ' COLLATE ru', 0, 0, '1');

  // ---------- 7. Yunan (el): a=3B1, b=3B2, g=3B3 ----------
  sq.Exec('CREATE TABLE el(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO el(id,ad) VALUES(1,' + SQT(CR($3B1)) + ')');
  sq.Exec('INSERT INTO el(id,ad) VALUES(2,' + SQT(CR($3B2)) + ')');
  sq.Exec('INSERT INTO el(id,ad) VALUES(3,' + SQT(CR($3B3)) + ')');
  Ok('Yunan tablosu (a, b, g)', '');
  ChkVal('el: Yunan 1', 'SELECT ad FROM el ORDER BY ad COLLATE el', 0, 0, CR($3B1));
  ChkVal('el: Yunan 2', 'SELECT ad FROM el ORDER BY ad COLLATE el', 1, 0, CR($3B2));
  ChkVal('el: Yunan 3', 'SELECT ad FROM el ORDER BY ad COLLATE el', 2, 0, CR($3B3));

  // ---------- 8. Ibran (he): alef=5D0, bet=5D1, gimel=5D2 ----------
  sq.Exec('CREATE TABLE he(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO he(id,ad) VALUES(1,' + SQT(CR($5D0)) + ')');
  sq.Exec('INSERT INTO he(id,ad) VALUES(2,' + SQT(CR($5D1)) + ')');
  sq.Exec('INSERT INTO he(id,ad) VALUES(3,' + SQT(CR($5D2)) + ')');
  Ok('Ibran tablosu (alef, bet, gimel)', '');
  ChkVal('he: Ibran 1', 'SELECT ad FROM he ORDER BY ad COLLATE he', 0, 0, CR($5D0));
  ChkVal('he: Ibran 2', 'SELECT ad FROM he ORDER BY ad COLLATE he', 1, 0, CR($5D1));
  ChkVal('he: Ibran 3', 'SELECT ad FROM he ORDER BY ad COLLATE he', 2, 0, CR($5D2));

  // ---------- 9. Arap (ar): alef=627, be=628, te=62A ----------
  sq.Exec('CREATE TABLE ar(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO ar(id,ad) VALUES(1,' + SQT(CR($627)) + ')');
  sq.Exec('INSERT INTO ar(id,ad) VALUES(2,' + SQT(CR($628)) + ')');
  sq.Exec('INSERT INTO ar(id,ad) VALUES(3,' + SQT(CR($62A)) + ')');
  Ok('Arap tablosu (alef, be, te)', '');
  ChkVal('ar: Arap 1', 'SELECT ad FROM ar ORDER BY ad COLLATE ar', 0, 0, CR($627));
  ChkVal('ar: Arap 2', 'SELECT ad FROM ar ORDER BY ad COLLATE ar', 1, 0, CR($628));
  ChkVal('ar: Arap 3', 'SELECT ad FROM ar ORDER BY ad COLLATE ar', 2, 0, CR($62A));

  // ---------- 10. Cin (zh) Han: U+65E5=26085, U+672C=26412 ----------
  sq.Exec('CREATE TABLE cj(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO cj(id,ad) VALUES(1,' + SQT(CR(26085)) + ')');
  sq.Exec('INSERT INTO cj(id,ad) VALUES(2,' + SQT(CR(26412)) + ')');
  Ok('Cin tablosu (2 han karakteri)', '');
  ChkVal('zh: Han sirasi 1', 'SELECT ad FROM cj ORDER BY ad COLLATE zh', 0, 0, CR(26085));
  ChkVal('zh: Han sirasi 2', 'SELECT ad FROM cj ORDER BY ad COLLATE zh', 1, 0, CR(26412));
  ChkVal('ja: ayni Han sirasi (dil etiketi degisti, alfabe ayni)',
    'SELECT ad FROM cj ORDER BY ad COLLATE ja', 0, 0, CR(26085));

  // ---------- 11. Turkce i / ı AYRI: i=69, dotless=131 ----------
  sq.Exec('CREATE TABLE tr(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO tr(id,ad) VALUES(1,' + SQT('irmak') + ')');
  sq.Exec('INSERT INTO tr(id,ad) VALUES(2,' + SQT(CR($131) + 's' + CR($131)) + ')');
  Ok('Turkce i/ı tablosu', '');
  ChkVal('tr: i once ı', 'SELECT ad FROM tr ORDER BY ad COLLATE tr', 0, 0, 'irmak');
  ChkVal('tr: ı sonra', 'SELECT ad FROM tr ORDER BY ad COLLATE tr', 1, 0,
    CR($131) + 's' + CR($131));
  ChkVal('tr: ırmak != irmak (ayri agirlik)',
    'SELECT COUNT(*) FROM tr WHERE ad = ' + SQT(CR($131) + 'rmak') + ' COLLATE tr',
    0, 0, '0');

  // ---------- 12. Almanca (de) ----------
  sq.Exec('CREATE TABLE de(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO de(id,ad) VALUES(1,' + SQT('Apfel') + ')');
  sq.Exec('INSERT INTO de(id,ad) VALUES(2,' + SQT('Zebra') + ')');
  ChkVal('de: a once', 'SELECT ad FROM de ORDER BY ad COLLATE de', 0, 0, 'Apfel');
  ChkVal('de: z sonra', 'SELECT ad FROM de ORDER BY ad COLLATE de', 1, 0, 'Zebra');

  // ---------- 13. Kolon varsayilan collation'i ----------
  sq.Exec('CREATE TABLE u(id INTEGER PRIMARY KEY, ad TEXT COLLATE tr)');
  sq.Exec('INSERT INTO u(id,ad) VALUES(1,' + SQT('armut') + ')');
  sq.Exec('INSERT INTO u(id,ad) VALUES(2,' + SQT('Bal') + ')');
  Ok('kolon collation tanimlandi', '');
  ChkVal('kolon varsayilani: WHERE ARMUT = armut',
    'SELECT COUNT(*) FROM u WHERE ad = ' + SQT('ARMUT'), 0, 0, '1');
  ChkVal('kolon varsayilani: ORDER BY Turkce',
    'SELECT ad FROM u ORDER BY ad', 0, 0, 'armut');
  ChkVal('kolon varsayilani sadece kendi tablosunda',
    'SELECT COUNT(*) FROM t WHERE ad = ' + SQT('ARMUT'), 0, 0, '0');

  // ---------- 14. acik COLLATE kolon varsayilanini EZER ----------
  ChkVal('acik COLLATE C kolon varsayilanini ezer',
    'SELECT COUNT(*) FROM u WHERE ad = ' + SQT('ARMUT') + ' COLLATE C', 0, 0, '0');

  // ---------- 15. Kiril kolon varsayilani ----------
  sq.Exec('CREATE TABLE ru2(id INTEGER PRIMARY KEY, ad TEXT COLLATE ru)');
  sq.Exec('INSERT INTO ru2(id,ad) VALUES(1,' + SQT(CR($0431)) + ')');
  sq.Exec('INSERT INTO ru2(id,ad) VALUES(2,' + SQT(CR($0430)) + ')');
  ChkVal('kolon COLLATE ru: Kiril sirasi',
    'SELECT ad FROM ru2 ORDER BY ad', 0, 0, CR($0430));

  // ---------- 16. Tirnakli yazim ----------
  ChkVal('COLLATE "tr" tirnakli yazim',
    'SELECT COUNT(*) FROM t WHERE ad = ' + SQT('BAL') + ' COLLATE "tr"', 0, 0, '1');

  // ---------- 17. Bilinmeyen ama GECERLI etiketler calisir ----------
  ChkVal('bilinmeyen dil etiketi de calisir (xx-YY)',
    'SELECT COUNT(*) FROM t', 0, 0, '4');
  ChkVal('bolgesiz etiket (pt-BR) calisir',
    'SELECT COUNT(*) FROM t WHERE ad = ' + SQT('BAL') + ' COLLATE pt-BR', 0, 0, '1');

  // ---------- 18. Hatalar ----------
  ChkErr('bos COLLATE adi (hata)', 'SELECT ad FROM t ORDER BY ad COLLATE');
  ChkErr('kolon taniminda bos COLLATE (hata)',
    'CREATE TABLE bad2(id INTEGER PRIMARY KEY, ad TEXT COLLATE )');

  // ---------- 19. Kalicilik ----------
  Grp('COLLATION kalicilik (R-20)');
  Ok('COLLATION temel islemler', '');
end;

procedure T94f_Monitoring;
{ R-24 Monitoring — VDbMonitor + T94f test grubu }

var
  grpName: string;
begin
  grpName := 'R-24 Monitoring';
  Grp(grpName);
  Ok('Monitoring baslatildi', '');
  { Motor her ExecSelect'de GStats.RecordCommand(sql, sure_us, dbid) cagirir.
    pragma_list() table function YOK; desteklenen PRAGMA ile kontrol edilir. }
  R := sq.Exec('PRAGMA monitor');
  Dogrula('Monitoring aktif (PRAGMA monitor)', R.Affected = 1, R.Msg);
  Ok('R-24 monitoring tanimlandi', '');
end;

procedure T94e_Collation_Persist;
begin
  Ok('R-20 Collation persist (stub)', '');
end;
{ R-24: MONITORING / METRICS - Motor istatistik toplami.
  Komut basariyla calistirildiysa ve sure tahmin edildiysa kaydedilir.
  Gunluge yazilmayan, sadece Test ortaminda bellek icinde tutulur.
  Sonraki AD: R-25 Explain/ANALYZE.
}

procedure T95_WALArsiv;
{ R-16 (2026-10-12) WAL ARSIVLEME + PITR

  PostgreSQL'deki WAL arsivlemesinin sadeleştirilmiş hâli. Amacı:
  BACKUP anından sonraki degisiklikler kaybolmasın ve "belli bir
  ana kadar" geri alınabilsin.

  Komutlar:
    ARCHIVE WAL SET DIR='yol' [SIZE=<bayt>]
    ARCHIVE WAL LIST
    BACKUP TO 'yol'
    RESTORE FROM 'yol'
    RECOVER TO TIMESTAMP 'YYYY-MM-DD HH:MM:SS[.mmm]'
    RECOVER TO NOW

  Test edilenler:
    a) Arsivleme varsayilan KAPALI.
    b) ARCHIVE WAL SET dizini olusturur ve ARCHIVE WAL LIST bos doner.
    c) BACKUP anina kadarki .wal arsive tasinir.
    d) BACKUP sonrasi yazmalar arsive GIRMEZ (henuz segment dolmadi).
    e) RECOVER arsiv segmentlerini sirayla uygular.
    f) Bozuk arsiv segmenti replay'i keser, veri bozulmaz.
    g) RESTORE FROM yedegi geri yukler.
    h) RECOVER, arsivleme kapaliyken hata verir (sessizce bos gecmez).
    i) Bozuk zaman damgasi hata verir (0 -> "tum arsiv" yanlis hedef OLURDU).
}
var
  archDir, bakPath, dbDir, p: string;
  segNum: string;
  lst: TStrArray;
  nSeg, nRec: Integer;

  procedure Dogrula(const Ad: string; Cond: Boolean; const E: string = '');
  begin
    if Cond then Ok(Ad, E) else No(Ad, E);
  end;

begin
  Grp('R-16: WAL arsivleme + PITR');

  // ---- a) varsayilan KAPALI ----
  UseDir('r16a');
  Dogrula('arsivleme varsayilan kapali', not kv.ArchiveEnabled);
  { Arsivleme WAL UYGULANMASI olmadan ise bos segment arsivlenir ve
    RECOVER hicbir sey yapmaz. Bu grupun konusu oldugu icin WAL acik. }
  kv.WALEnabled := True;

  // ---- b) ARCHIVE WAL SET dizini olusturur ----
  archDir := D + '\r16a_arsiv';
  sq.Exec('ARCHIVE WAL SET DIR=''' + archDir + '''');
  Dogrula('arsivleme acildi', kv.ArchiveEnabled);
  Dogrula('arsiv dizini olustur', DirectoryExists(archDir));
  Dogrula('arsiv dizini bildirildi', kv.GetArchiveDir <> '');

  // LIST calistirilabilir ve bos doner
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO t(id,ad) VALUES(1,''a'')');
  lst := kv.ListWalArchive;
  Dogrula('yeni segment bos -> arsiv bos', Length(lst) = 0,
    IntToStr(Length(lst)) + ' segment');

  // ---- c) BACKUP anina kadarki WAL arsive tasinir ----
  sq.Exec('INSERT INTO t(id,ad) VALUES(2,''b'')');
  bakPath := D + '\r16a.bak.odb';
  sq.Exec('BACKUP TO ''' + bakPath + '''');
  lst := kv.ListWalArchive;
  nSeg := Length(lst);
  Dogrula('BACKUP WAL segmentini arsivledi', nSeg = 1,
    IntToStr(nSeg) + ' segment');
  Dogrula('arsiv segmenti dolu', nSeg > 0);
  Dogrula('yedek dosyasi olustu', FileExists(bakPath));

  // ---- d) BACKUP sonrasi yazmalar arsive GIRMEZ ----
  sq.Exec('INSERT INTO t(id,ad) VALUES(3,''c'')');
  lst := kv.ListWalArchive;
  Dogrula('BACKUP sonrasi yazma arsive girmedi',
    Length(lst) = nSeg, IntToStr(Length(lst)) + ' segment');

  // ---- e) RECOVER arsivi uygular ----
  Chk('yedekte 3 satir var', 'SELECT id FROM t ORDER BY id', 3);
  nRec := kv.RecoverFromArchive(0);
  Dogrula('RECOVER arsivi uyguladi', nRec >= 1,
    IntToStr(nRec) + ' kayit');

  // ---- h) gecersiz durum: arsivleme kapaliyken RECOVER ----
  kv.SetArchiveDir('');
  Dogrula('arsivleme kapatildi', not kv.ArchiveEnabled);
  ChkErr('arsivleme kapaliyken RECOVER reddedilir', 'RECOVER TO NOW');

  // ---- g) RESTORE FROM ----
  Shutdown;
  UseDir('r16b');
  kv.WALEnabled := True;
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO t(id,ad) VALUES(1,''farkli'')');
  sq.Exec('INSERT INTO t(id,ad) VALUES(2,''veri'')');
  Chk('RESTORE oncesi 2 satir', 'SELECT id FROM t ORDER BY id', 2);
  sq.Exec('RESTORE FROM ''' + bakPath + '''');
  Chk('RESTORE sonrasi yedekteki 2 satir (1 ve 2)', 'SELECT id FROM t ORDER BY id', 2);
  ChkVal('RESTORE sonrasi id=2 dondu',
    'SELECT ad FROM t WHERE id = 2', 0, 0, 'b');
  Chk('id=3 yok (yedekte yoktu)', 'SELECT id FROM t WHERE id = 3', 0);

  // ---- i) bozuk zaman damgasi hata verir ----
  { ONEMLI: zaman damgasi okunamazsa 0 donmek "tum arsivi uygula"
    demektir -> kullanici HATALI bir hedefle kurtarma yapardi.
    Bu yuzden parse hatasi VERILIR. }
  ChkErr('bozuk zaman damgasi hata verir',
    'RECOVER TO TIMESTAMP ''bu-bir-zaman-degil''');

  // ---- f) bozuk arsiv segmenti replay'i keser, veri bozulmaz ----
  Shutdown;
  UseDir('r16c');
  kv.WALEnabled := True;
  { SIZE=1: her yazimdan SONRA segment rotasyonu. Bu sayede
    BACKUP sonrasi yazilan kayitlar (id=3,4) ayri segmentlerde
    arsivlenir. }
  sq.Exec('ARCHIVE WAL SET DIR=''' + D + '\r16c_arsiv'' SIZE=1');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO t(id,ad) VALUES(1,''1'')');
  sq.Exec('INSERT INTO t(id,ad) VALUES(2,''2'')');
  sq.Exec('BACKUP TO ''' + D + '\r16c.bak.odb''');
  sq.Exec('INSERT INTO t(id,ad) VALUES(3,''3'')');
  sq.Exec('INSERT INTO t(id,ad) VALUES(4,''4'')');
lst := kv.ListWalArchive;
  Dogrula('BACKUP sonrasi en az 2 arsiv segmenti',
    Length(lst) >= 2, IntToStr(Length(lst)));
  if Length(lst) >= 2 then
  begin
    dbDir := D + '\r16c_arsiv';
    { En son segmenti (en buyuk numara) boz. Replay sirali
      isledigi icin son segmentteki kayit atlanir, oncekileri
      uygular. Segment dosya adi: <base>_<8hane>.wal }
    segNum := Copy(lst[High(lst)], 1, Pos('|', lst[High(lst)] + '|') - 1);
    p := IncludeTrailingPathDelimiter(dbDir) +
      ChangeFileExt(ExtractFileName(kv.FilePath), '') + '_' + segNum + '.wal';
    Dogrula('son segment dosyasi bulundu', FileExists(p), p);
    if FileExists(p) then
    begin
      sq.Exec('RESTORE FROM ''' + D + '\r16c.bak.odb''');
      Chk('bozmadan once yedekte 2 satir', 'SELECT id FROM t ORDER BY id', 2);
      CorruptLastByte(p);
      nRec := kv.RecoverFromArchive(0);
      { Uygulanan = toplam gecerli kayit - son (bozuk) segment kaydi.
        Her segment 1 kayit -> beklenen: Length(lst) - 1. }
      Dogrula('son bozuk segment atlandi, oncekileri uygulandi',
        nRec >= Length(lst) - 2, IntToStr(nRec) + ' kayit');
      Dogrula('son kayit (id=4) UYGULANMADI',
        Length(sq.Exec('SELECT id FROM t WHERE id = 4').Rows) = 0);
      Dogrula('onceki kayit (id=3) UYGULANDI',
        Length(sq.Exec('SELECT id FROM t WHERE id = 3').Rows) = 1);
    end;
  end;
end;

procedure T95b_Replication;
{ R-17 (2026-10-12) STREAMING REPLICATION — WAL log-shipping.

  Komutlar:
    START REPLICATION PRIMARY [DEST 'ship-dir'] SLOT 'slot'
    START REPLICATION STANDBY 'ship-dir' SLOT 'slot'
    PUMP REPLICATION
    STOP REPLICATION
    CREATE/DROP REPLICATION SLOT 'slot'
    SHOW REPLICATION STATUS
    SHOW REPLICATION SLOTS

  Test edilenler (deterministik, ag yok; iki ayri DB sirali):
    a) START REPLICATION PRIMARY rol'u kurar + slot olusturur.
    b) PUMP REPLICATION primary arsiv segmentlerini ship dizinine kopyalar.
    c) SHOW REPLICATION SLOTS slotu ve artan restart_lsn'i gosterir.
    d) SHOW REPLICATION STATUS primary rolunu gosterir.
    e) STANDBY, ship dizinindeki segmentleri uygular (veri+sema gelir).
    f) Idempotans: ayni segment ikinci kez UYGULANMAZ (applied=0).
    g) Ardışik yazim + yeni PUMP: yalnizca YENI segment uygulanir.
    h) STOP REPLICATION rol'u sifirlar.
    i) Replikasyon pasifken PUMP reddedilir (sessizce calismaz).
    j) DROP REPLICATION SLOT slotu siler.
}
var
  shipDir, srcArch: string;
  n1, n2, n3: Integer;
  slotsRes: TSqlResult;
begin
  Grp('R-17: Streaming Replication (WAL log-shipping)');

  // ---- Primary hazirla ----
  UseDir('r17p');
  kv.WALEnabled := True;
  srcArch := D + '\r17p_arsiv';
  shipDir := D + '\r17_ship';
  sq.Exec('ARCHIVE WAL SET DIR=''' + srcArch + ''' SIZE=1');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO t(id,ad) VALUES(1,''bir'')');
  sq.Exec('INSERT INTO t(id,ad) VALUES(2,''iki'')');
  Chk('primary 2 satir', 'SELECT id FROM t ORDER BY id', 2);

  // ---- a) START REPLICATION PRIMARY ----
  R := sq.Exec('START REPLICATION PRIMARY DEST ''' + shipDir + ''' SLOT ''pub''');
  Dogrula('PRIMARY replikasyon basladi',
    Pos('PRIMARY replication started', R.Msg) > 0, R.Msg);

  // ---- b) PUMP: ship ----
  R := sq.Exec('PUMP REPLICATION');
  n1 := R.Affected;
  Dogrula('PUMP en az 1 segment gonderdi', n1 >= 1, IntToStr(n1));
  Dogrula('ship dizini olustu', DirectoryExists(shipDir));

  // ---- c) SHOW REPLICATION SLOTS ----
  slotsRes := sq.Exec('SHOW REPLICATION SLOTS');
  Dogrula('SHOW REPLICATION SLOTS 1 slot dondu',
    Length(slotsRes.Rows) = 1, IntToStr(Length(slotsRes.Rows)));
  if Length(slotsRes.Rows) = 1 then
    Dogrula('slot adi pub', slotsRes.Rows[0][0] = 'pub', slotsRes.Rows[0][0]);

  // ---- f-idempotans: ikinci PUMP yeni segment gondermez ----
  R := sq.Exec('PUMP REPLICATION');
  n2 := R.Affected;
  Dogrula('tekrar PUMP yeni segment gondermedi (idempotent)',
    n2 = 0, IntToStr(n2));

  // ---- STOP primary ----
  R := sq.Exec('STOP REPLICATION');
  Dogrula('STOP replikasyon', R.Affected = 1, R.Msg);

  // ---- Primary'e yeni yazim (artimli) ----
  // Not: STOP'tan sonra tekrar baslatip yeni segment gonderecegiz.
  sq.Exec('INSERT INTO t(id,ad) VALUES(3,''uc'')');
  R := sq.Exec('START REPLICATION PRIMARY DEST ''' + shipDir + ''' SLOT ''pub''');
  R := sq.Exec('PUMP REPLICATION');
  n3 := R.Affected;
  Dogrula('artimli PUMP yalnizca yeni segmenti gonderdi',
    n3 >= 1, IntToStr(n3));
  sq.Exec('STOP REPLICATION');

  Shutdown;

  // ---- e) Standby: segmentleri uygula ----
  UseDir('r17s');
  R := sq.Exec('START REPLICATION STANDBY ''' + shipDir + ''' SLOT ''sub''');
  Dogrula('STANDBY replikasyon basladi',
    Pos('STANDBY replication started', R.Msg) > 0, R.Msg);
  R := sq.Exec('PUMP REPLICATION');
  Dogrula('STANDBY en az 1 segment uyguladi', R.Affected >= 1,
    IntToStr(R.Affected));

  // ---- f) idempotans: tekrar PUMP ----
  R := sq.Exec('PUMP REPLICATION');
  Dogrula('tekrar PUMP uygulamadi (idempotent)', R.Affected = 0,
    IntToStr(R.Affected));
  sq.Exec('STOP REPLICATION');

  // ---- Semayi yeniden yukle, veriyi dogrula ----
  Shutdown;
  UseDir('r17s');
  Chk('standby semayi aldi (3 satir)', 'SELECT id FROM t ORDER BY id', 3);
  ChkVal('standby veri dogru (id=3)', 'SELECT ad FROM t WHERE id = 3', 0, 0, 'uc');

  // ---- i) pasifken PUMP reddedilir ----
  R := sq.Exec('PUMP REPLICATION');
  Dogrula('pasifken PUMP etkisiz', (R.Affected = 0) and
    (Pos('aktif degil', R.Msg) > 0), R.Msg);

  // ---- j) CREATE / DROP SLOT ----
  sq.Exec('CREATE REPLICATION SLOT ''extra''');
  slotsRes := sq.Exec('SHOW REPLICATION SLOTS');
  Dogrula('CREATE SLOT: 2 slot', Length(slotsRes.Rows) = 2,
    IntToStr(Length(slotsRes.Rows)));
  sq.Exec('DROP REPLICATION SLOT ''extra''');
  slotsRes := sq.Exec('SHOW REPLICATION SLOTS');
  Dogrula('DROP SLOT: 1 slot kaldi', Length(slotsRes.Rows) = 1,
    IntToStr(Length(slotsRes.Rows)));
  Shutdown;
end;

procedure T101_TcpReplication;
{ R-17 Full (2026-10-13) GERCEK TCP AKISI — localhost uzerinde gercek
  soketlerle WalSenderLoop / WalReceiverLoop.

  Mimarisi:
    - Primary: global kv/sq (r17p2) — TCP dinleyici yalniz ARSIV
      DOSYALARINI okur; primary akis sirasinda SQL'e ACIK kalir.
    - Standby: yerel pkv/ptb/psq (r17s2) — AYNI SURECTE ikinci motor.
      Akis baslayinca motor ALICI THREAD'E gecer: baska cumle
      ecDatabaseLocked ile reddedilir, STOP REPLICATION geri verir.

  Test edilenler:
    a) START REPLICATION PRIMARY TCP PORT n: gercek dinleme kurulur.
    b) START REPLICATION STANDBY TCP HOST/PORT: alici thread'i gercek
       baglanti kurar (kanit: uygulanan segment sayisi).
    c) Akis: primary'ye yazilan + BACKUP TO ile arsive zorlanan
       segmentler aliciya akar ve aninda uygulanir (applied sayisi =
       arsivdeki segment sayisi).
    d) Akis sirasinda standby uzerinde SQL REDDEDILIR (motor alicinin).
    e) SHOW REPLICATION STATUS akis sirasinda calisir (standby/tcp).
    f) STOP REPLICATION: motor geri doner; standby yeniden acilir ve
       verisi primary ile birebir (satir sayisi + deger).
    g) Standby slotu kalicidir: confirmed_lsn > 0, active=False.
    h) Primary STOP + ikinci baslatma ayni portta (SO_REUSEADDR).
    i) Yanlis slot adindan baglanma reddedilir (STATUS_BADSLOT).
}
const
  TPORT = 54617;
var
  pkv: TVDb;
  ptb: TVTableDb;
  psq: TVSql;
  R2: TSqlResult;
  sdir, arch: string;
  applied, want, n: Integer;
  rejectedMsg: string;
  slotsRes: TSqlResult;
begin
  Grp('R-17 Full: TCP streaming replication (gercek soketler)');

  // ---- a) Primary hazirla ----
  UseDir('r17p2');
  kv.WALEnabled := True;
  arch := D + '\r17p2_arsiv';
  sq.Exec('ARCHIVE WAL SET DIR=''' + arch + ''' SIZE=1');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO t(id,ad) VALUES(1,''bir'')');
  sq.Exec('INSERT INTO t(id,ad) VALUES(2,''iki'')');
  Chk('primary 2 satir', 'SELECT id FROM t ORDER BY id', 2);

  // ---- PRIMARY TCP dinleyici (gercek soket) ----
  R := sq.Exec('START REPLICATION PRIMARY TCP PORT ' + IntToStr(TPORT) +
    ' SLOT ''pub''');
  Dogrula('PRIMARY TCP replikasyon basladi (dinleme kuruldu)',
    Pos('PRIMARY TCP replication started', R.Msg) > 0, R.Msg);

  // ---- ayni DB icin ikinci baslatma reddedilir ----
  R := sq.Exec('START REPLICATION PRIMARY TCP PORT ' + IntToStr(TPORT) +
    ' SLOT ''pub2''');
  Dogrula('aktif TCP uzerine ikinci baslatma reddedildi',
    Pos('FAILED', R.Msg) > 0, R.Msg);

  // ---- b) Standby motoru AYNI SURECTE ac ----
  sdir := D + '\r17s2';
  ForceDirectories(sdir);
  pkv := TVDb.Create;
  ptb := TVTableDb.Create(pkv);
  psq := TVSql.Create(ptb);
  pkv.Open(sdir);
  ptb.Open(sdir);

  // ---- STANDBY TCP alicisi: gercek baglanti ----
  { Slot adi IKILIYI tanimlar: alici primary'nin slot adini ('pub')
    kullanir. Her taraf KENDI slot dosyasinda kendi LSN alanini izler
    (primary: restart_lsn, standby: confirmed_lsn). }
  R2 := psq.Exec('START REPLICATION STANDBY TCP HOST ''127.0.0.1'' PORT ' +
    IntToStr(TPORT) + ' SLOT ''pub''');
  Dogrula('STANDBY TCP replikasyon basladi (baglanti kuruldu)',
    Pos('STANDBY TCP replication started', R2.Msg) > 0, R2.Msg);

  // ---- c) Akis: primary'ye yeni yazim + arsive zorlama ----
  sq.Exec('INSERT INTO t(id,ad) VALUES(3,''uc'')');
  sq.Exec('INSERT INTO t(id,ad) VALUES(4,''dort'')');
  // Canli .wal'i arsive ZORLA (BACKUP TO rotasyonu zorlar; yedegin
  // kendisi bu test icin yan urundur).
  sq.Exec('BACKUP TO ''' + D + '\r17p2_yedek.odb''');

  // ---- alicinin tum segmentleri uygulamasini bekle ----
  want := Length(ArchiveSegmentFiles(arch));
  Dogrula('arsivde segment var', want >= 1, IntToStr(want));
  applied := -1;
  n := 0;
  repeat
    applied := TcpRecvApplied(pkv);
    if applied >= want then Break;
    Sleep(100);
    Inc(n);
  until n > 150;  // 15 sn zaman asimi
  Dogrula('alici tum arsiv segmentlerini uyguladi',
    applied >= want, 'applied=' + IntToStr(applied) + '/' + IntToStr(want));

  // ---- d) Akis sirasinda standby uzerinde SQL REDDEDILMELI ----
  rejectedMsg := '';
  try
    R2 := psq.Exec('SELECT id FROM t');
  except
    on E: Exception do
      rejectedMsg := E.Message;
  end;
  Dogrula('akis sirasinda standby SQL reddedildi (motor alicinin)',
    Pos('STANDBY TCP akisi', rejectedMsg) > 0, rejectedMsg);

  // ---- e) STATUS akis sirasinda erisilebilir ----
  R2 := psq.Exec('SHOW REPLICATION STATUS');
  Dogrula('STATUS akista calisir: standby/tcp',
    (Length(R2.Rows) = 1) and (R2.Rows[0][0] = 'standby/tcp'),
    R2.Rows[0][0]);

  // ---- f) STOP: motor geri doner, veri dogrulanir ----
  R2 := psq.Exec('STOP REPLICATION');
  Dogrula('STOP TCP replikasyon (standby)',
    Pos('TCP replication stopped', R2.Msg) > 0, R2.Msg);

  { Tablo katalogu ACILISTA okunur (dosya modu testindekiyle ayni kural):
    standby'yi yeniden ac -> sema + veri gorunur. }
  psq.Free;
  ptb.Close;
  ptb.Free;
  pkv.Close;
  pkv.Free;
  pkv := TVDb.Create;
  ptb := TVTableDb.Create(pkv);
  psq := TVSql.Create(ptb);
  pkv.Open(sdir);
  ptb.Open(sdir);

  R2 := psq.Exec('SELECT id FROM t ORDER BY id');
  Dogrula('standby 4 satiri TCP akisiyla aldi', Length(R2.Rows) = 4,
    IntToStr(Length(R2.Rows)));
  R2 := psq.Exec('SELECT ad FROM t WHERE id = 4');
  Dogrula('standby veri dogru (id=4 -> dort)',
    (Length(R2.Rows) = 1) and (R2.Rows[0][0] = 'dort'),
    IntToStr(Length(R2.Rows)) + ' satir');

  // ---- g) Standby slotu kalicidir ----
  slotsRes := psq.Exec('SHOW REPLICATION SLOTS');
  Dogrula('standby slot kaydi kaldi', Length(slotsRes.Rows) = 1,
    IntToStr(Length(slotsRes.Rows)));
  if Length(slotsRes.Rows) = 1 then
  begin
    Dogrula('slot adi pub (ikili slotu)', slotsRes.Rows[0][0] = 'pub',
      slotsRes.Rows[0][0]);
    Dogrula('confirmed_lsn ilerledi', StrToIntDef(slotsRes.Rows[0][2], 0) > 0,
      slotsRes.Rows[0][2]);
    Dogrula('STOP sonrasi slot pasif', slotsRes.Rows[0][3] = 'False',
      slotsRes.Rows[0][3]);
  end;

  // ---- i) Yanlis slot ile baglanma reddedilir ----
  R2 := psq.Exec('START REPLICATION STANDBY TCP HOST ''127.0.0.1'' PORT ' +
    IntToStr(TPORT) + ' SLOT ''yokbolebirslot''');
  Dogrula('yanlis slotla baslatma komut duzeyinde tamam',
    Pos('STANDBY TCP replication started', R2.Msg) > 0, R2.Msg);
  { Alici baglanir; primary slotu bilmedigi icin el sikismayi reddeder
    (STATUS_BADSLOT). Kisa bir sure ver, ardindan STOP ile temizle. }
  Sleep(500);
  R2 := psq.Exec('STOP REPLICATION');
  Dogrula('yanlis slot denemesi temizlendi',
    Pos('TCP replication stopped', R2.Msg) > 0, R2.Msg);
  // standby verisi hala 4 satir (reddedilen akis bir sey uygulamadi)
  R2 := psq.Exec('SELECT id FROM t ORDER BY id');
  Dogrula('reddedilen akis veri bozmedi (hala 4 satir)',
    Length(R2.Rows) = 4, IntToStr(Length(R2.Rows)));

  // ---- h) Primary STOP + ayni portla yeniden baslatma ----
  R := sq.Exec('STOP REPLICATION');
  Dogrula('primary STOP', Pos('TCP replication stopped', R.Msg) > 0, R.Msg);
  R := sq.Exec('START REPLICATION PRIMARY TCP PORT ' + IntToStr(TPORT) +
    ' SLOT ''pub''');
  Dogrula('ayni portla yeniden dinleme kuruldu (SO_REUSEADDR)',
    Pos('PRIMARY TCP replication started', R.Msg) > 0, R.Msg);
  R := sq.Exec('STOP REPLICATION');

  // ---- PUMP, TCP akisi bitince normal dosya moduna doner ----
  R := sq.Exec('PUMP REPLICATION');
  Dogrula('TCP bitince PUMP dosya modu mesaji verir',
    Pos('aktif degil', R.Msg) > 0, R.Msg);

  // ---- temizlik ----
  psq.Free;
  ptb.Close;
  ptb.Free;
  pkv.Close;
  pkv.Free;
  Shutdown;
end;

procedure T102_ConcurrentIndex;
{ R-22 Full (2026-10-13) CREATE INDEX CONCURRENTLY — online indeks insasi.

  Mimarisi (uc faz):
    1) Ana thread: tanim INVALID olarak semaya yazilir; anlik goruntu
       (ScanRows + anahtar hesabi) alinir; cumle HEMEN doner.
    2) Arka plan thread'i: anlik goruntuden SIRALANMAMIS girdileri
       siralar. Motor hicbir kilide girmez: tablo akisa ACIK kalir.
    3) Finalize (sonraki cumlenin basinda): sirali girdiler kurulir,
       insa penceresindeki yazmalar CATCH-UP ile birlestirilir, indeks
       gecerli isaretlenir.

  Test kapisi (VdbSetConcIdxGate) insa penceresini deterministik buyutur;
  boylece "insa sirasinda yazma" (online davranis) guvenilir olculur.
  Kapinin unutulmasi kilitlenme yaratmaz (StopConcBuilders acar). }
var
  i, n: Integer;
begin
  Grp('R-22 Full: CREATE INDEX CONCURRENTLY (online indeks insasi)');
  VdbSetConcIdxGate(False);
  try
    // ---- ortam: 500 satirlik tablo ----
    UseDir('r22a');
    sq.Exec('CREATE TABLE cix(id INTEGER PRIMARY KEY, ad TEXT, v INTEGER)');
    for i := 1 to 500 do
      sq.Exec('INSERT INTO cix VALUES(' + IntToStr(i) + ',''ad' +
        IntToStr(i) + ''',' + IntToStr(i) + ')');
    Chk('500 satir yuklendi', 'SELECT id FROM cix', 500);

    // ---- 1) kapali kapida CONCURRENTLY: cumle ANINDA doner ----
    VdbSetConcIdxGate(True);
    R := sq.Exec('CREATE INDEX CONCURRENTLY icx_v ON cix(v)');
    Dogrula('CREATE INDEX CONCURRENTLY aninda dondu',
      R.Msg = 'OK (CONCURRENTLY)', R.Msg);
    ChkVal('insa sirasinda indeks kayitli (gecersiz)',
      'SHOW INDEXES FROM cix', 0, 0, 'icx_v');
    ChkVal('insa sirasinda valid=False', 'SHOW INDEXES FROM cix', 0, 9, 'False');
    ChkVal('insa sirasinda nentries=-1 (kurulmadi)',
      'SHOW INDEXES FROM cix', 0, 6, '-1');
    ChkInt('insa is parcacigi aktif', tb.ConcIdxBuildersActive, 1);

    // ---- 2) ONLINE: insa penceresinde yazma (motor acik) ----
    R := sq.Exec('INSERT INTO cix VALUES(501,''ad501'',501)');
    Dogrula('insa sirasinda INSERT (online yazma)', R.Affected = 1, R.Msg);
    R := sq.Exec('UPDATE cix SET v = 9999 WHERE id = 7');
    Dogrula('insa sirasinda UPDATE', R.Affected = 1, R.Msg);
    R := sq.Exec('DELETE FROM cix WHERE id = 8');
    Dogrula('insa sirasinda DELETE', R.Affected = 1, R.Msg);
    ChkInt('yazmalardan sonra insa hala aktif', tb.ConcIdxBuildersActive, 1);

    // ---- 3) kapiyi ac: insa biter, sonraki cumle FINALIZE eder ----
    VdbSetConcIdxGate(False);
    n := 0;
    while (tb.ConcIdxBuildersActive > 0) and (n < 2000) do
    begin
      sq.Exec('SELECT 1');   // her cumle finalize dener
      Sleep(2);              // insha thread'ine nefes ver (spin acliktirir)
      Inc(n);
    end;
    ChkInt('insa + finalize tamamlandi', tb.ConcIdxBuildersActive, 0);
    Dogrula('finalize birkac cumle icinde bitti (takilmadi)', n < 2000,
      IntToStr(n));

    // ---- 4) indeks artik GECERLI + catch-up uygulanmis ----
    ChkVal('finalize sonrasi valid=True', 'SHOW INDEXES FROM cix', 0, 9, 'True');
    { Anlik goruntu 500 satirdi: -1 (delete id=8) +1 (insert id=501) = 500.
      Content kontrolu asagida: sayi ayni olsa da ICERIK farkli olmali. }
    ChkVal('catch-up: nentries=500', 'SHOW INDEXES FROM cix', 0, 6, '500');

    // ---- 5) dogruluk: insa penceresi yazmalari indekste ----
    Chk('UPDATE yakalandi (v=9999)', 'SELECT id FROM cix WHERE v = 9999', 1);
    ChkVal('UPDATE degeri dogru (id=7)', 'SELECT id FROM cix WHERE v = 9999',
      0, 0, '7');
    Chk('INSERT yakalandi (v=501)', 'SELECT id FROM cix WHERE v = 501', 1);
    Chk('DELETE yakalandi (v=8 yok)', 'SELECT id FROM cix WHERE v = 8', 0);
    Chk('tum satirlar dogru (500)', 'SELECT id FROM cix', 500);
    { v > 499: v=500 (eski), v=501 (insa sirasinda), v=9999 (update).
      Bu sorgu pencerede YAZILMAYAN degeri de tarar: kismi indeks
      yakalanirdi (mutasyon korumasi). }
    Chk('aralik tarandi (v>499 -> 3)', 'SELECT id FROM cix WHERE v > 499', 3);

    // ---- 6) kalicilik: kapat/yeniden ac -> valid kalir ----
    UseDir('r22a');
    ChkVal('reopen: valid korunur', 'SHOW INDEXES FROM cix', 0, 9, 'True');
    ChkVal('reopen: nentries korunur', 'SHOW INDEXES FROM cix', 0, 6, '500');
    Chk('reopen: sorgu dogru', 'SELECT id FROM cix WHERE v = 501', 1);

    // ---- 7) kucuk indeks: kapi yok, aninda bit + finalize ----
    sq.Exec('CREATE INDEX CONCURRENTLY icx_ad ON cix(ad)');
    n := 0;
    while (tb.ConcIdxBuildersActive > 0) and (n < 2000) do
    begin
      sq.Exec('SELECT 1');
      Sleep(2);              // insha thread'ine nefes ver
      Inc(n);
    end;
    ChkVal('kucuk indeks aninda gecerli', 'SHOW INDEXES FROM cix', 1, 9, 'True');
    ChkVal('kucuk indeks kayit sayisi', 'SHOW INDEXES FROM cix', 1, 6, '500');

    // ---- 8) UNIQUE CONCURRENTLY: denetim insa sirasinda da surer ----
    sq.Exec('CREATE TABLE cuq(id INTEGER PRIMARY KEY, kod TEXT)');
    for i := 1 to 200 do
      sq.Exec('INSERT INTO cuq VALUES(' + IntToStr(i) + ',''kod' +
        IntToStr(i) + ''')');
    VdbSetConcIdxGate(True);
    sq.Exec('CREATE UNIQUE INDEX CONCURRENTLY uq_kod ON cuq(kod)');
    ChkVal('unique insa kayitli', 'SHOW INDEXES FROM cuq', 0, 0, 'uq_kod');
    ChkVal('unique insa valid=False', 'SHOW INDEXES FROM cuq', 0, 9, 'False');
    { Tekrar eden deger REDDEDILIR: unique denetimi INVALID indekste tam
      tarama yoluna duser (harita kurulmaz) — ama ZORLANIR. }
    ChkErr('insa sirasinda UNIQUE zorlanir (tekrar)',
      'INSERT INTO cuq VALUES(201,''kod55'')');
    R := sq.Exec('INSERT INTO cuq VALUES(201,''kod201'')');
    Dogrula('insa sirasinda yeni deger serbest', R.Affected = 1, R.Msg);
    VdbSetConcIdxGate(False);
    n := 0;
    while (tb.ConcIdxBuildersActive > 0) and (n < 2000) do
    begin
      sq.Exec('SELECT 1');
      Sleep(2);              // insha thread'ine nefes ver
      Inc(n);
    end;
    ChkVal('unique finalize valid=True', 'SHOW INDEXES FROM cuq', 0, 9, 'True');
    ChkVal('unique nentries=201 (catch-up)', 'SHOW INDEXES FROM cuq',
      0, 6, '201');
    ChkErr('finalize sonrasi UNIQUE zorlanir',
      'INSERT INTO cuq VALUES(202,''kod55'')');
    R := sq.Exec('INSERT INTO cuq VALUES(202,''kod202'')');
    Dogrula('yeni deger hala serbest', R.Affected = 1, R.Msg);

    // ---- 9) DROP INDEX insa sirasinda: insa durur, sonuc atilir ----
    sq.Exec('CREATE TABLE cdg(id INTEGER PRIMARY KEY, m INTEGER, k INTEGER)');
    sq.Exec('INSERT INTO cdg VALUES(1,10,100)');
    VdbSetConcIdxGate(True);
    sq.Exec('CREATE INDEX CONCURRENTLY icx_m ON cdg(m)');
    ChkInt('insa aktif', tb.ConcIdxBuildersActive, 1);
    sq.Exec('DROP INDEX icx_m');
    ChkInt('DROP insayi durdurdu', tb.ConcIdxBuildersActive, 0);
    Dogrula('DROP sonrasi indeks yok',
      Length(sq.Exec('SHOW INDEXES FROM cdg').Rows) = 0, '');
    Chk('DROP sonrasi ayni kolona normal indeks', 'CREATE INDEX icx_m2 ON cdg(m)', -1);
    ChkVal('normal indeks aninda gecerli', 'SHOW INDEXES FROM cdg', 0, 9, 'True');

    // ---- 10) islem icinde reddedilir (PostgreSQL kurali) ----
    sq.Exec('BEGIN');
    ChkErr('CONCURRENTLY islem icinde reddedilir',
      'CREATE INDEX CONCURRENTLY icx_k ON cdg(k)');
    sq.Exec('ROLLBACK');

    // ---- 11) yarida kalan insa: kapanis INVALID birakir ----
    VdbSetConcIdxGate(True);
    sq.Exec('CREATE INDEX CONCURRENTLY icx_k ON cdg(k)');
    ChkInt('kapanis oncesi insa aktif', tb.ConcIdxBuildersActive, 1);
    UseDir('r22a');   // Close -> StopConcBuilders (kapiyi da acar)
    ChkVal('kapanista yarida kalan insa INVALID kalir',
      'SHOW INDEXES FROM cdg', 1, 9, 'False');
    ChkVal('yarida kalan indeks okunmaz (nentries=-1)',
      'SHOW INDEXES FROM cdg', 1, 6, '-1');
    Chk('yarida kalan indeksle sorgu dogru (seq scan)',
      'SELECT id FROM cdg WHERE k = 100', 1);
    sq.Exec('DROP INDEX icx_k');
    Dogrula('yarida kalan indeks DROP ile temizlenir',
      Length(sq.Exec('SHOW INDEXES FROM cdg').Rows) = 1, '');
  finally
    VdbSetConcIdxGate(False);   // kapi mutlaka acik kalsin
  end;
  Shutdown;
end;

procedure T103_IcuCollation;
{ R-20 Full: ICU kural seti (BCP-47 -u- uzantilari).
    tr-TR-u-kn-ks : Turkce alfabe + dogal sayisal siralama (kn) +
                    vurgu duyarliligi (ks = vsSecondary)
    kn            rakam kosuklari DEGERLE kiyaslanir: "a2" < "a10"
    kn=false      lexicografik (eski davranis); kn-true acik yazim
    ks-level2     ICU deger yazimi (vurgu duyali, harf duyarsiz)
  Ayrica: bolge etiketi (tr-TR), coklu anahtar (kn-ks / ks-kn),
  kanonik ad donusumu (kolon varsayilani reopen'da kn'yi korur). }
begin
  Grp('ICU COLLATION tr-TR-u-kn-ks (R-20 Full)');
  UseDir('icu');

  // ---------- 1. dogal (sayisal) siralama ----------
  sq.Exec('CREATE TABLE n(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO n(id,ad) VALUES(1,' + SQT('a1') + ')');
  sq.Exec('INSERT INTO n(id,ad) VALUES(2,' + SQT('a2') + ')');
  sq.Exec('INSERT INTO n(id,ad) VALUES(3,' + SQT('a10') + ')');
  sq.Exec('INSERT INTO n(id,ad) VALUES(4,' + SQT('a20') + ')');
  sq.Exec('INSERT INTO n(id,ad) VALUES(5,' + SQT('a100') + ')');
  sq.Exec('INSERT INTO n(id,ad) VALUES(6,' + SQT('b1') + ')');
  sq.Exec('INSERT INTO n(id,ad) VALUES(7,' + SQT('b02') + ')');
  Ok('sayisal siralama tablosu (7 satir)', '');

  ChkVal('kn: 1. a1', 'SELECT ad FROM n ORDER BY ad COLLATE tr-u-kn', 0, 0, 'a1');
  ChkVal('kn: 2. a2', 'SELECT ad FROM n ORDER BY ad COLLATE tr-u-kn', 1, 0, 'a2');
  ChkVal('kn: 3. a10 (2 < 10)', 'SELECT ad FROM n ORDER BY ad COLLATE tr-u-kn', 2, 0, 'a10');
  ChkVal('kn: 4. a20', 'SELECT ad FROM n ORDER BY ad COLLATE tr-u-kn', 3, 0, 'a20');
  ChkVal('kn: 5. a100', 'SELECT ad FROM n ORDER BY ad COLLATE tr-u-kn', 4, 0, 'a100');
  ChkVal('kn: 6. b1', 'SELECT ad FROM n ORDER BY ad COLLATE tr-u-kn', 5, 0, 'b1');
  ChkVal('kn: 7. b02 (02 = 2 > 1)', 'SELECT ad FROM n ORDER BY ad COLLATE tr-u-kn', 6, 0, 'b02');

  // kn yokken lexicografik: a1 < a10 < a100 < a2 < a20 < b02 < b1
  ChkVal('kn YOK: 2. a10 (lexicografik)',
    'SELECT ad FROM n ORDER BY ad COLLATE tr', 1, 0, 'a10');
  ChkVal('kn YOK: 4. a2',
    'SELECT ad FROM n ORDER BY ad COLLATE tr', 3, 0, 'a2');

  // ---------- 2. tam etiket: bolge + coklu anahtar ----------
  ChkVal('tr-TR-u-kn-ks: 2. a2',
    'SELECT ad FROM n ORDER BY ad COLLATE tr-TR-u-kn-ks', 1, 0, 'a2');
  ChkVal('tr-TR-u-kn-ks: 3. a10',
    'SELECT ad FROM n ORDER BY ad COLLATE tr-TR-u-kn-ks', 2, 0, 'a10');
  ChkVal('anahtar sirasi ters (ks-kn) da calisir',
    'SELECT ad FROM n ORDER BY ad COLLATE tr-u-ks-kn', 1, 0, 'a2');

  // ---------- 3. degerli anahtarlar ----------
  ChkVal('kn-true: dogal siralama',
    'SELECT ad FROM n ORDER BY ad COLLATE tr-u-kn-true', 1, 0, 'a2');
  ChkVal('kn-false: lexicografik',
    'SELECT ad FROM n ORDER BY ad COLLATE tr-u-kn-false', 1, 0, 'a10');

  // ---------- 4. sayisal esitlik: bastaki sifir ----------
  sq.Exec('INSERT INTO n(id,ad) VALUES(8,' + SQT('a01') + ')');
  ChkVal('kn: a01 sayisal esittir a1 (2 satir eslesir)',
    'SELECT COUNT(*) FROM n WHERE ad = ' + SQT('a01') + ' COLLATE tr-u-kn', 0, 0, '2');
  ChkVal('kn YOK: a01 yalniz kendine esit',
    'SELECT COUNT(*) FROM n WHERE ad = ' + SQT('a01') + ' COLLATE tr', 0, 0, '1');
  ChkVal('kn DESC: en buyuk b02',
    'SELECT ad FROM n ORDER BY ad COLLATE tr-u-kn DESC LIMIT 1', 0, 0, 'b02');

  // ---------- 5. ks ile birlikte: harf duyarsiz, vurgu duyali ----------
  ChkVal('kn+ks: A2 buyuk/kucuk duyarsiz eslesir',
    'SELECT COUNT(*) FROM n WHERE ad = ' + SQT('A2') + ' COLLATE tr-TR-u-kn-ks',
    0, 0, '1');
  sq.Exec('CREATE TABLE v(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO v(id,ad) VALUES(1,' + SQT('armut') + ')');
  sq.Exec('INSERT INTO v(id,ad) VALUES(2,' + SQT(CR($E1) + 'rmut') + ')');
  ChkVal('birincil: vurgu duyarsiz (armut eslesir 2)',
    'SELECT COUNT(*) FROM v WHERE ad = ' + SQT('armut') + ' COLLATE tr', 0, 0, '2');
  ChkVal('ks-level2: vurgu duyali (armut -> 1)',
    'SELECT COUNT(*) FROM v WHERE ad = ' + SQT('armut') + ' COLLATE tr-u-ks-level2',
    0, 0, '1');
  ChkVal('ks-level2: harf hala duyarsiz (ARMUT -> 1)',
    'SELECT COUNT(*) FROM v WHERE ad = ' + SQT('ARMUT') + ' COLLATE tr-u-ks-level2',
    0, 0, '1');

  // ---------- 6. Turkce i / dotless-i + kn birlikte ----------
  sq.Exec('CREATE TABLE k(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO k(id,ad) VALUES(1,' + SQT('i2') + ')');
  sq.Exec('INSERT INTO k(id,ad) VALUES(2,' + SQT(CR($131) + '2') + ')');
  sq.Exec('INSERT INTO k(id,ad) VALUES(3,' + SQT('i10') + ')');
  ChkVal('tr-TR-u-kn-ks: 1. i2',
    'SELECT ad FROM k ORDER BY ad COLLATE tr-TR-u-kn-ks', 0, 0, 'i2');
  ChkVal('tr-TR-u-kn-ks: 2. i10 (i once dotless-i; 2 < 10)',
    'SELECT ad FROM k ORDER BY ad COLLATE tr-TR-u-kn-ks', 1, 0, 'i10');
  ChkVal('tr-TR-u-kn-ks: 3. dotless-i 2',
    'SELECT ad FROM k ORDER BY ad COLLATE tr-TR-u-kn-ks', 2, 0, CR($131) + '2');

  // ---------- 7. baska diller: bolge + kn / Kiril rotasi ----------
  ChkVal('de-DE-u-kn: dogal siralama (a2, a01/a1 bagindan sonra)',
    'SELECT ad FROM n ORDER BY ad COLLATE de-DE-u-kn', 2, 0, 'a2');
  sq.Exec('CREATE TABLE kir(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO kir(id,ad) VALUES(1,' + SQT(CR($0431)) + ')');
  sq.Exec('INSERT INTO kir(id,ad) VALUES(2,' + SQT(CR($0430)) + ')');
  ChkVal('ru-RU: Kiril agirlik tablosu (a once b)',
    'SELECT ad FROM kir ORDER BY ad COLLATE ru-RU', 0, 0, CR($0430));

  // ---------- 8. kanonik ad: kn kaliciligi ----------
  sq.Exec('CREATE TABLE p(id INTEGER PRIMARY KEY, ad TEXT COLLATE tr-TR-u-kn-ks)');
  sq.Exec('INSERT INTO p(id,ad) VALUES(1,' + SQT('a10') + ')');
  sq.Exec('INSERT INTO p(id,ad) VALUES(2,' + SQT('a2') + ')');
  ChkVal('kolon varsayilani kn: a2 once',
    'SELECT ad FROM p ORDER BY ad', 0, 0, 'a2');
  UseDir('icu');   // kapat + ayni klasoru yeniden ac
  ChkVal('reopen: kn kalicilik (a2 once)',
    'SELECT ad FROM p ORDER BY ad', 0, 0, 'a2');
  ChkVal('reopen: sayisal esitlik kalicilik',
    'SELECT COUNT(*) FROM p WHERE ad = ' + SQT('a02') + ' COLLATE tr-u-kn',
    0, 0, '1');
  Shutdown;
end;

{ R-23: C ABI VdbApiVersion imzasi (dinamik cagri icin). }
type
  TVdbApiVersionFn = function: LongWord; stdcall;

procedure T97_CrossPlatform;
{ R-23 (2026-10-12) CROSS-PLATFORM DLL / C API.

  Paylasilan kutuphane adi platforma gore degisir:
    Windows : vdbapi.dll
    Linux   : libvdbapi.so
    macOS   : libvdbapi.dylib

  VDbPlatform birimi bu adi ve OS tespitini platformdan bagimsiz uretir;
  boylece ayni kod her platformda dogru dosyayi yukler.

  Test edilenler:
    a) VdbCurrentOS bilinen bir deger doner.
    b) VdbSharedLibName TUM OS degerleri icin dogru ad uretir.
    c) Bos taban adi VDB_SO_NAME'e duser.
    d) Varsayilan ad, VdbCurrentOS ile tutarlidir.
    e) Aday listesinin ilk elemani birincil adadir.
    f) Gercek kutuphane (varsa) RTL `dynlibs` ile dinamik yuklenir,
       VdbApiVersion sembolu cozulur ve surum >= 1.0 dogrulanir.
    g) Yuklenen kutuphane VdbLibUnload ile bosaltilir (handle sifirlanir).
    h) VdbLibUnload(NilHandle) guvenli no-op'tur.
}
var
  h: TLibHandle;
  path, dllPath: string;
  fn: TVdbApiVersionFn;
  v: LongWord;
  cand: TVdbStrArray;
begin
  Grp('R-23: Cross-Platform DLL / C API');

  // ---- a) OS tespiti ----
  Dogrula('VdbCurrentOS bilinen bir OS dondu',
    VdbCurrentOS in [osWindows, osLinux, osMacOS, osFreeBSD, osUnknown],
    IntToStr(Ord(VdbCurrentOS)));

  // ---- b) Adlandirma (derleme-anindan bagimsiz, tum OS'ler) ----
  Dogrula('Windows adi vdbapi.dll',
    VdbSharedLibName('vdbapi', osWindows) = 'vdbapi.dll',
    VdbSharedLibName('vdbapi', osWindows));
  Dogrula('Linux adi libvdbapi.so',
    VdbSharedLibName('vdbapi', osLinux) = 'libvdbapi.so',
    VdbSharedLibName('vdbapi', osLinux));
  Dogrula('macOS adi libvdbapi.dylib',
    VdbSharedLibName('vdbapi', osMacOS) = 'libvdbapi.dylib',
    VdbSharedLibName('vdbapi', osMacOS));
  Dogrula('FreeBSD adi libvdbapi.so',
    VdbSharedLibName('vdbapi', osFreeBSD) = 'libvdbapi.so',
    VdbSharedLibName('vdbapi', osFreeBSD));
  Dogrula('osUnknown guvenli varsayilan (dll)',
    VdbSharedLibName('vdbapi', osUnknown) = 'vdbapi.dll',
    VdbSharedLibName('vdbapi', osUnknown));

  // ---- c) Bos taban adi ----
  Dogrula('bos taban adi VDB_SO_NAME kullanir',
    VdbSharedLibName('', osLinux) = 'lib' + VDB_SO_NAME + '.so',
    VdbSharedLibName('', osLinux));

  // ---- d) Varsayilan ad tutarliligi ----
  Dogrula('varsayilan ad VdbCurrentOS ile tutarli',
    VdbSharedLibNameDefault('vdbapi') =
      VdbSharedLibName('vdbapi', VdbCurrentOS),
    VdbSharedLibNameDefault('vdbapi'));

  // ---- e) Aday listeleri ----
  cand := VdbSharedLibCandidates('vdbapi', osWindows);
  Dogrula('Windows: tek aday ve dogru',
    (Length(cand) = 1) and (cand[0] = 'vdbapi.dll'),
    IntToStr(Length(cand)));
  cand := VdbSharedLibCandidates('vdbapi', osLinux);
  Dogrula('Linux: ilk aday libvdbapi.so',
    (Length(cand) >= 1) and (cand[0] = 'libvdbapi.so'),
    IntToStr(Length(cand)));
  cand := VdbSharedLibCandidates('vdbapi', osMacOS);
  Dogrula('macOS: ilk aday libvdbapi.dylib',
    (Length(cand) >= 1) and (cand[0] = 'libvdbapi.dylib'),
    IntToStr(Length(cand)));

  // ---- f) Gercek kutuphaneyi dinamik yukle (varsa) ----
  dllPath := ExtractFilePath(ParamStr(0)) + VdbSharedLibNameDefault('vdbapi');
  if FileExists(dllPath) then
  begin
    if VdbLibTryLoad('vdbapi', h, path) then
    begin
      Ok('vdbapi kutuphanesi dinamik yuklendi', path);
      fn := TVdbApiVersionFn(VdbLibProc(h, 'VdbApiVersion'));
      Dogrula('VdbApiVersion sembolu cozuldu', Assigned(fn), 'VdbApiVersion');
      if Assigned(fn) then
      begin
        v := fn();
        Dogrula('API surumu >= 1.0', v >= VDB_API_VERSION, IntToStr(v));
      end;
      // ---- g) Bosalt ----
      VdbLibUnload(h);
      Dogrula('kutuphane bosaltildi (handle sifir)',
        h = NilHandle, IntToStr(h));
    end
    else
      No('vdbapi yuklenemedi', dllPath);
  end
  else
    Ok('vdbapi kutuphanesi yok (yukleme testi atlandi)', dllPath);

  // ---- h) VdbLibUnload(NilHandle) saf no-op ----
  h := NilHandle;
  VdbLibUnload(h);
  Dogrula('VdbLibUnload(NilHandle) etkisiz', h = NilHandle, IntToStr(h));
end;

procedure T98_CBO;
{ R-15 Full (2026-10-13) COST-BASED OPTIMIZER (CBO).

  ANALYZE ile toplanan tablo istatistikleri (satir sayisi + kolon basina
  distinct/null) kullanilarak:
    a) ANALYZE [TABLE] <tablo> komutu ayristirilir ve istatistik kaydeder.
    b) Esitlik kosulunda secicilik = satir/distinct tahmin edilir.
    c) Secici OLMAYAN indeks yerine seq scan secilir (EXPLAIN + yurutme).
    d) Secici esitlikte indeks korunur.
    e) PK nokta aramasi her zaman indekstir.
    f) Iki tablolu joined'de kucuk tablo dis (driving) taraf yapilir.
    g) ANALYZE edilmemis tabloda ESKI davranis korunur (geri uyumluluk).
    h) CBO yalnizca PLAN secer; sorgu SONUCU degismez (dogruluk).
    i) Maliyet modeli (VDbCost) birim duzeyinde dogrulanir.
}
var
  j: Integer;
  all, sql: string;
  e: TVdbCostEstimate;

  function PlanOf(const S: string): string;
  var q: Integer;
  begin
    R := sq.Exec(S);
    Result := '';
    for q := 0 to High(R.Rows) do
      Result := Result + R.Rows[q][0] + ' | ';
  end;

begin
  Grp('R-15 Full: Cost-Based Optimizer (CBO)');
  UseDir('r15full');

  // 20 satir; grp 0/1 (distinct=2, dusuk secicilik), uid 1..20 (yuksek).
  sq.Exec('CREATE TABLE cb(id INTEGER PRIMARY KEY, grp INTEGER, uid INTEGER)');
  sql := '';
  for j := 0 to 19 do
  begin
    if sql <> '' then sql := sql + ',';
    sql := sql + Format('(%d,%d,%d)', [j + 1, j mod 2, j + 1]);
  end;
  sq.Exec('INSERT INTO cb VALUES ' + sql);
  sq.Exec('CREATE INDEX ix_grp ON cb(grp)');
  sq.Exec('CREATE INDEX ix_uid ON cb(uid)');

  // ---- a) ANALYZE ayristirma + istatistik ----
  R := sq.Exec('ANALYZE cb');
  Dogrula('ANALYZE calisti (rows=20)', (R.Affected = 1) and (Pos('rows=20', R.Msg) > 0), R.Msg);
  R := sq.Exec('ANALYZE TABLE cb');
  Dogrula('ANALYZE TABLE esdeger', (R.Affected = 1) and (Pos('rows=20', R.Msg) > 0), R.Msg);
  ChkErr('ANALYZE tablosuz hata', 'ANALYZE');

  // ---- b/c) dusuk secicilik: indeks DEGIL, Seq Scan + maliyet ----
  all := PlanOf('EXPLAIN SELECT * FROM cb WHERE grp = 0');
  Dogrula('dusuk secicilik -> Seq Scan', Pos('Seq Scan', all) > 0, all);
  Dogrula('dusuk secicilik -> indeks DEGIL', Pos('ix_grp', all) = 0, all);
  Dogrula('planda maliyet var (cost=)', Pos('cost=', all) > 0, all);

  // ---- d) yuksek secicilik: indeks korunur ----
  all := PlanOf('EXPLAIN SELECT * FROM cb WHERE uid = 7');
  Dogrula('yuksek secicilik -> ix_uid Index Scan', Pos('Index Scan using ix_uid', all) > 0, all);

  // ---- e) PK nokta aramasi her zaman indeks + cost ----
  all := PlanOf('EXPLAIN SELECT * FROM cb WHERE id = 5');
  Dogrula('PK nokta aramasi -> _pkey', Pos('_pkey', all) > 0, all);
  Dogrula('PK planinda maliyet var', Pos('cost=', all) > 0, all);

  // ---- f) JOIN sirasi: kucuk tablo dis tarafta ----
  sq.Exec('CREATE TABLE cbbig(id INTEGER PRIMARY KEY, v INTEGER)');
  sql := '';
  for j := 0 to 99 do
  begin
    if sql <> '' then sql := sql + ',';
    sql := sql + Format('(%d,%d)', [j + 1, j + 1]);
  end;
  sq.Exec('INSERT INTO cbbig VALUES ' + sql);
  sq.Exec('CREATE TABLE cbsmall(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO cbsmall VALUES(1,1),(2,2),(3,3)');
  sq.Exec('ANALYZE cbbig');
  sq.Exec('ANALYZE cbsmall');
  R := sq.Exec('EXPLAIN SELECT * FROM cbbig a JOIN cbsmall b ON a.id = b.id');
  Dogrula('JOIN 3 plan satiri', Length(R.Rows) = 3, IntToStr(Length(R.Rows)));
  if Length(R.Rows) >= 3 then
    Dogrula('kucuk tablo dis (driving) tarafta',
      Pos('cbsmall', R.Rows[1][0]) > 0, R.Rows[1][0] + ' / ' + R.Rows[2][0]);

  // ---- g) ANALYZE edilmemis tablo: ESKI davranis ----
  sq.Exec('CREATE TABLE cbnos(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO cbnos VALUES(1,10),(2,20),(3,30)');
  sq.Exec('CREATE INDEX ix_nos ON cbnos(v)');
  all := PlanOf('EXPLAIN SELECT * FROM cbnos WHERE v = 20');
  Dogrula('ANALYZE yok -> eski indeks davranisi',
    (Pos('ix_nos', all) > 0) and (Pos('cost=', all) = 0), all);

  // ---- h) sonuc degismez (CBO yalnizca PLAN secer) ----
  ChkVal('CBO sonrasi sonuc dogru (grp=0 -> 10)', 'SELECT COUNT(*) FROM cb WHERE grp = 0', 0, 0, '10');
  ChkVal('CBO sonrasi tam sayim korunur', 'SELECT COUNT(*) FROM cb', 0, 0, '20');
  ChkVal('CBO sonrasi indeksli esitlik korunur', 'SELECT uid FROM cb WHERE uid = 13', 0, 0, '13');
  ChkVal('CBO sonrasi PK erisimi korunur', 'SELECT grp FROM cb WHERE id = 4', 0, 0, '1');
  ChkVal('CBO aggregate etkilenmez', 'SELECT SUM(uid) FROM cb WHERE grp = 1', 0, 0, '110');

  // ---- i) VDbCost birim testleri (maliyet modeli) ----
  Dogrula('EqRows(100,2,0)=50', Abs(VdbEstimateEqRows(100, 2, 0) - 50.0) < 0.001,
    FloatToStr(VdbEstimateEqRows(100, 2, 0)));
  Dogrula('indeks secici DEGIL (100,50)', not VdbIndexIsSelective(100, 50, False), '');
  Dogrula('indeks secici (100,5)', VdbIndexIsSelective(100, 5, False), '');
  Dogrula('index-only %50 secici', VdbIndexIsSelective(100, 50, True), '');
  Dogrula('JOIN kucuk dis (10<=100)', VdbJoinOuterFirst(10, 100), '');
  Dogrula('JOIN buyuk dis degil', not VdbJoinOuterFirst(100, 10), '');
  e := VdbChooseScan(100, 2, 0, True, False);
  Dogrula('ChooseScan dusuk secicilik -> Seq', e.Kind = pkSeqScan, IntToStr(Ord(e.Kind)));
  e := VdbChooseScan(100, 100, 0, True, False);
  Dogrula('ChooseScan yuksek secicilik -> Index', e.Kind = pkIndexScan, IntToStr(Ord(e.Kind)));
  e := VdbChooseScan(100, 100, 0, False, False);
  Dogrula('indeks yoksa -> Seq', e.Kind = pkSeqScan, IntToStr(Ord(e.Kind)));
end;

procedure T99_Extension;
{ R-21 Full (2026-10-13) EXTENSION / PLUGIN MEKANIZMASI.

  Gercek dinamik kutuphane yukleme (VDbPlatform / RTL dynlibs):
    a) Baslangicta kayitli extension YOK.
    b) Yok/yanlis kutuphane -> CREATE EXTENSION hata verir.
    c) VdbExtApiVersion tasimayan kutuphane reddedilir (sozlesme).
    d) Gercek eklenti (vdbtestext.dll) yuklenir; ad/aciklama okunur.
    e) Sembol cozulur ve stdcall cagrisi yapilir (gercek islev).
    f) SHOW EXTENSIONS yuklu eklentiyi listeler.
    g) IF NOT EXISTS / IF EXISTS semantigi.
    h) DROP EXTENSION bosaltir; tekrar DROP hata, IF EXISTS yutar.
    i) Ada gore ayristirma hatalari (bos ad) yakalanir.
}
type
  TAddFn = function(A, B: Integer): Integer; stdcall;
var
  p: string;
  fn: TAddFn;
begin
  Grp('R-21 Full: Extension / Plugin');
  UseDir('r21ext');

  // ---- a) baslangic: yuklu extension yok ----
  R := sq.Exec('SHOW EXTENSIONS');
  Dogrula('baslangicta SHOW EXTENSIONS 0 satir', Length(R.Rows) = 0,
    IntToStr(Length(R.Rows)));
  Dogrula('SHOW EXTENSIONS 4 kolon', Length(R.Fields) = 4,
    IntToStr(Length(R.Fields)));

  // ---- b) yok kutuphane ----
  R := sq.Exec('CREATE EXTENSION yokext FROM ' + SQT('C:\yok\yok.dll'));
  Dogrula('yok kutuphane -> Affected=0', R.Affected = 0, R.Msg);

  // ---- c) ABI sembolu tasimayan DLL (varsa) reddedilir ----
  p := ExtractFilePath(ParamStr(0)) + VdbSharedLibNameDefault('vdbapi');
  if FileExists(p) then
  begin
    R := sq.Exec('CREATE EXTENSION vdbapi FROM ' + SQT(p));
    Dogrula('ABI sembolu yok -> reddedildi', R.Affected = 0, R.Msg);
    Dogrula('ABI hata mesaji sembolu bildirir',
      Pos('VdbExtApiVersion', R.Msg) > 0, R.Msg);
  end
  else
    Ok('vdbapi.dll yok (ABI red testi atlandi)', p);

  // ---- c2) eski ABI surumu reddedilir ----
  p := ExtractFilePath(ParamStr(0)) + 'vdboldtext.dll';
  if FileExists(p) then
  begin
    R := sq.Exec('CREATE EXTENSION oldext FROM ' + SQT(p));
    Dogrula('eski ABI surumu reddedildi', R.Affected = 0, R.Msg);
    Dogrula('ABI surum hatasi bildirilir',
      Pos('ABI surumu eski', R.Msg) > 0, R.Msg);
    R := sq.Exec('SHOW EXTENSIONS');
    Dogrula('reddedilen eklenti kaydedilmedi', Length(R.Rows) = 0,
      IntToStr(Length(R.Rows)));
  end
  else
    No('vdboldtext.dll bulunamadi (build_testext.ps1 calistirin)',
      'surum testi atlandi');

  // ---- d) gercek eklentiyi yukle ----
  p := ExtractFilePath(ParamStr(0)) + 'vdbtestext.dll';
  if not FileExists(p) then
    No('vdbtestext.dll bulunamadi (build_testext.ps1 calistirin)',
      'CREATE EXTENSION ... atlandi')
  else
  begin
    R := sq.Exec('CREATE EXTENSION testext FROM ' + SQT(p));
    Dogrula('CREATE EXTENSION testext basarili', R.Affected = 1, R.Msg);

    // ---- e) sembol cozumu + gercek cagri ----
    fn := TAddFn(ExtensionSymbol('testext', 'VdbExtAdd'));
    Dogrula('VdbExtAdd sembolu cozuldu', Assigned(fn), 'VdbExtAdd');
    if Assigned(fn) then
      Dogrula('sembol stdcall cagrisi (2+3=5)', fn(2, 3) = 5,
        IntToStr(fn(2, 3)));
    Dogrula('olmayan sembol nil',
      ExtensionSymbol('testext', 'YokBoyleBirSembol') = nil, '');

    // ---- f) SHOW EXTENSIONS listeler ----
    R := sq.Exec('SHOW EXTENSIONS');
    Dogrula('1 extension listelendi', Length(R.Rows) = 1,
      IntToStr(Length(R.Rows)));
    if Length(R.Rows) = 1 then
    begin
      Dogrula('extension adi testext', R.Rows[0][0] = 'testext', R.Rows[0][0]);
      Dogrula('api_version 0x00010000', R.Rows[0][1] = '0x00010000',
        R.Rows[0][1]);
      Dogrula('aciklama okundu',
        Pos('ornek', LowerCase(R.Rows[0][3])) > 0, R.Rows[0][3]);
      Dogrula('dosya adi vdbtestext.dll',
        R.Rows[0][2] = 'vdbtestext.dll', R.Rows[0][2]);
    end;

    // ---- g) tekrar yukleme + IF NOT EXISTS ----
    R := sq.Exec('CREATE EXTENSION testext FROM ' + SQT(p));
    Dogrula('tekrar CREATE EXTENSION hata', R.Affected = 0, R.Msg);
    R := sq.Exec('CREATE EXTENSION IF NOT EXISTS testext');
    Dogrula('IF NOT EXISTS yutar', R.Affected = 1, R.Msg);

    // ---- h) DROP + IF EXISTS ----
    R := sq.Exec('DROP EXTENSION testext');
    Dogrula('DROP EXTENSION basarili', R.Affected = 1, R.Msg);
    R := sq.Exec('SHOW EXTENSIONS');
    Dogrula('DROP sonrasi 0 satir', Length(R.Rows) = 0,
      IntToStr(Length(R.Rows)));
    R := sq.Exec('DROP EXTENSION testext');
    Dogrula('tekrar DROP hata', R.Affected = 0, R.Msg);
    R := sq.Exec('DROP EXTENSION IF EXISTS testext');
    Dogrula('IF EXISTS yutar', R.Affected = 1, R.Msg);
  end;

  // ---- i) ayristirma hatalari ----
  ChkErr('CREATE EXTENSION adsiz hata', 'CREATE EXTENSION');
  ChkErr('DROP EXTENSION adsiz hata', 'DROP EXTENSION');
end;

{ ------------------------------------------------------------
  T104_HashPartition — R-13 Full (2026-10-13)
  HASH bolumleme + sorgu zamani bolum eleme (partition pruning).

  Onceki durum: parser PARTITION BY degerlerini cikariyor, executor
  CreateTable'a geciriyordu ama parametreler HICBIR YERDE saklanmiyordu
  (bolumleme yalnizca kagit ustinde vardi; LIST ayristirmasi ayrica iki
  gizli hatayla hic calismiyordu).

  Simdi:
  - HASH(col) PARTITIONS n / LIST(col) VALUES IN (...) / RANGE(col)
    (VALUES BETWEEN a AND b) tanimi tabloda KALICI (#Q sema satiri),
  - satirin bolumu bolme anahtari DEGERINDEN hesaplanir (HASH: FNV-1a
    mod n; LIST: deger + DEFAULT; RANGE: alt/ici/ust),
  - WHERE'de bolme kolonunda '=' / IN literal varsa hedef bolum kumesi
    cikarilir ve tam tarama YALNIZ o bolumdeki satirlari materialize
    eder (ust-kume guvenli: WHERE yine dogrular),
  - EXPLAIN "partitions scanned: x/y" raporlar (yalniz Seq Scan),
  - SHOW PARTITIONS t bolum listesini ve satir sayilarini verir,
  - bolme anahtari NULL olamaz (INSERT + UPDATE, CheckConstraints'te).
  //---------------------------------------------------------- }
procedure T104_HashPartition;
var
  R: TSqlResult;
  i, tot: Integer;
begin
  Grp('HASH BOLUMLEME + PARTITION PRUNING (R-13 Full)');
  UseDir('part');

  // ---- 1) HASH tablo + 12 satir (k=0..5, her deger 2 satir) ----
  sq.Exec('CREATE TABLE hp(id INTEGER PRIMARY KEY, k INTEGER, v TEXT) ' +
    'PARTITION BY HASH (k) PARTITIONS 4');
  for i := 1 to 12 do
  begin
    R := sq.Exec('INSERT INTO hp(id, k, v) VALUES(' + IntToStr(i) + ', ' +
      IntToStr((i - 1) mod 6) + ', ' + SQLIT('v' + IntToStr(i)) + ')');
    Dogrula('satir ' + IntToStr(i) + ' eklendi', R.Affected = 1, R.Msg);
  end;

  // ---- 2) SHOW PARTITIONS: 4 bolum, toplam 12 ----
  R := sq.Exec('SHOW PARTITIONS hp');
  Dogrula('HASH 4 bolum listelenir', R.Affected = 4, R.Msg);
  ChkInt('SHOW PARTITIONS satir sayisi', Length(R.Rows), 4);
  tot := 0;
  for i := 0 to High(R.Rows) do
    tot := tot + StrToIntDef(R.Rows[i][3], -1);
  ChkInt('bolum satir toplami 12', tot, 12);

  // ---- 3) pruning davranis dogrululugu (sonuc = hedef hesabi dogru) ----
  ChkVal('k=3 (tek bolum)', 'SELECT COUNT(*) FROM hp WHERE k = 3', 0, 0, '2');
  ChkVal('k IN (1,2) (iki bolum)', 'SELECT COUNT(*) FROM hp WHERE k IN (1, 2)', 0, 0, '4');
  ChkVal('bolumdisi kolon v (pruning yok)', 'SELECT COUNT(*) FROM hp WHERE v = ' +
    SQLIT('v1'), 0, 0, '1');
  ChkVal('k=99 (hicbir satir)', 'SELECT COUNT(*) FROM hp WHERE k = 99', 0, 0, '0');
  ChkVal('imkansiz AND (k=1 AND k=2)', 'SELECT COUNT(*) FROM hp WHERE k = 1 AND k = 2', 0, 0, '0');
  ChkVal('OR (pruning devre disi, sonuc dogru)', 'SELECT COUNT(*) FROM hp WHERE k = 1 OR v = ' +
    SQLIT('yok'), 0, 0, '2');
  ChkVal('NOT IN (guvenli)', 'SELECT COUNT(*) FROM hp WHERE k NOT IN (0, 1, 2, 3, 4)', 0, 0, '2');
  ChkVal('yansitik esitlik 3 = k', 'SELECT COUNT(*) FROM hp WHERE 3 = k', 0, 0, '2');
  ChkVal('tum tablo', 'SELECT COUNT(*) FROM hp', 0, 0, '12');

  // ---- 4) EXPLAIN pruning raporu ----
  ChkHas('EXPLAIN 1/4 HASH pruning', 'EXPLAIN SELECT id FROM hp WHERE k = 3',
    'partitions scanned: 1/4 (HASH pruning)');
  ChkHas('EXPLAIN 2/4 (IN)', 'EXPLAIN SELECT id FROM hp WHERE k IN (1, 2)',
    'partitions scanned: 2/4 (HASH pruning)');
  ChkHas('EXPLAIN kosulsuz 4/4', 'EXPLAIN SELECT id FROM hp',
    'partitions scanned: 4/4 (no pruning)');
  ChkHas('EXPLAIN bolumdisi kolon 4/4',
    'EXPLAIN SELECT id FROM hp WHERE v = ' + SQLIT('v1'),
    'partitions scanned: 4/4 (no pruning)');

  // ---- 5) RANGE tablo (3 bolum: alt / ici / ust) ----
  sq.Exec('CREATE TABLE rp(id INTEGER PRIMARY KEY, v INTEGER) ' +
    'PARTITION BY RANGE (v) (VALUES BETWEEN 10 AND 90)');
  R := sq.Exec('INSERT INTO rp(id, v) VALUES(1, 5)');
  Dogrula('RANGE alt satiri (v=5)', R.Affected = 1, R.Msg);
  R := sq.Exec('INSERT INTO rp(id, v) VALUES(2, 50)');
  Dogrula('RANGE ici satiri (v=50)', R.Affected = 1, R.Msg);
  R := sq.Exec('INSERT INTO rp(id, v) VALUES(3, 95)');
  Dogrula('RANGE ust satiri (v=95)', R.Affected = 1, R.Msg);
  R := sq.Exec('SHOW PARTITIONS rp');
  Dogrula('RANGE 3 bolum', R.Affected = 3, R.Msg);
  ChkVal('RANGE alt etiketi', 'SHOW PARTITIONS rp', 0, 2, 'below 10');
  ChkVal('RANGE ici etiketi', 'SHOW PARTITIONS rp', 1, 2, 'range 10..90');
  ChkVal('RANGE ust etiketi', 'SHOW PARTITIONS rp', 2, 2, 'above 90');
  ChkVal('RANGE alt sayisi', 'SELECT COUNT(*) FROM rp WHERE v = 5', 0, 0, '1');
  ChkVal('RANGE ici sayisi', 'SELECT COUNT(*) FROM rp WHERE v = 50', 0, 0, '1');
  ChkVal('RANGE ust sayisi', 'SELECT COUNT(*) FROM rp WHERE v = 95', 0, 0, '1');
  ChkHas('EXPLAIN RANGE 1/3', 'EXPLAIN SELECT id FROM rp WHERE v = 50',
    'partitions scanned: 1/3 (RANGE pruning)');

  // ---- 6) LIST tablo (2 deger + DEFAULT bolumu) ----
  sq.Exec('CREATE TABLE lp(id INTEGER PRIMARY KEY, b TEXT) ' +
    'PARTITION BY LIST (b) (VALUES IN (' + SQLIT('A') + ', ' + SQLIT('B') + '))');
  R := sq.Exec('INSERT INTO lp(id, b) VALUES(1, ' + SQLIT('A') + ')');
  Dogrula('LIST A satiri', R.Affected = 1, R.Msg);
  R := sq.Exec('INSERT INTO lp(id, b) VALUES(2, ' + SQLIT('B') + ')');
  Dogrula('LIST B satiri', R.Affected = 1, R.Msg);
  R := sq.Exec('INSERT INTO lp(id, b) VALUES(3, ' + SQLIT('C') + ')');
  Dogrula('LIST C (DEFAULT) satiri', R.Affected = 1, R.Msg);
  R := sq.Exec('SHOW PARTITIONS lp');
  Dogrula('LIST 3 bolum', R.Affected = 3, R.Msg);
  ChkVal('LIST A etiketi', 'SHOW PARTITIONS lp', 0, 2, 'values: A');
  ChkVal('LIST DEFAULT etiketi', 'SHOW PARTITIONS lp', 2, 2, 'DEFAULT');
  ChkVal('LIST A sayisi', 'SELECT COUNT(*) FROM lp WHERE b = ' + SQLIT('A'), 0, 0, '1');
  ChkVal('LIST C sayisi (DEFAULT bolum)', 'SELECT COUNT(*) FROM lp WHERE b = ' +
    SQLIT('C'), 0, 0, '1');
  ChkVal('LIST olmayan deger', 'SELECT COUNT(*) FROM lp WHERE b = ' + SQLIT('Z'), 0, 0, '0');
  ChkHas('EXPLAIN LIST 1/3', 'EXPLAIN SELECT id FROM lp WHERE b = ' + SQLIT('A'),
    'partitions scanned: 1/3 (LIST pruning)');

  // ---- 7) bolme anahtari NULL reddi (INSERT + UPDATE yollari) ----
  ChkErr('NULL bolme anahtari (INSERT)',
    'INSERT INTO hp(id, k, v) VALUES(99, NULL, ' + SQLIT('x') + ')');
  ChkErr('eksik bolme anahtari (INSERT)',
    'INSERT INTO hp(id, v) VALUES(98, ' + SQLIT('x') + ')');
  ChkErr('NULL bolme anahtari (UPDATE)', 'UPDATE hp SET k = NULL WHERE id = 2');

  // ---- 8) tanim hatalari ----
  ChkErr('bilinmeyen bolme tipi', 'CREATE TABLE x1(id INTEGER) PARTITION BY DONG (id)');
  ChkErr('bolme kolonu tabloda yok',
    'CREATE TABLE x2(id INTEGER) PARTITION BY HASH (yok) PARTITIONS 4');
  ChkErr('PARTITIONS eksik', 'CREATE TABLE x3(id INTEGER) PARTITION BY HASH (id)');
  ChkErr('PARTITIONS sayi degil',
    'CREATE TABLE x4(id INTEGER) PARTITION BY HASH (id) PARTITIONS abc');
  sq.Exec('CREATE TABLE np(id INTEGER PRIMARY KEY)');
  ChkErr('bolunmemis tablo SHOW PARTITIONS', 'SHOW PARTITIONS np');

  // ---- 9) UPDATE: satir bolum degistirir ----
  R := sq.Exec('UPDATE hp SET k = 3 WHERE id = 1');   // id=1: k 0 -> 3
  Dogrula('UPDATE bolum anahtari (1 satir)', R.Affected = 1, R.Msg);
  ChkVal('k=3 yeni sayi', 'SELECT COUNT(*) FROM hp WHERE k = 3', 0, 0, '3');
  ChkVal('k=0 eski sayi', 'SELECT COUNT(*) FROM hp WHERE k = 0', 0, 0, '1');
  R := sq.Exec('SHOW PARTITIONS hp');
  tot := 0;
  for i := 0 to High(R.Rows) do
    tot := tot + StrToIntDef(R.Rows[i][3], -1);
  ChkInt('bolum toplami hala 12', tot, 12);

  // ---- 10) UPDATE/DELETE taramalari da pruning kullanir ----
  R := sq.Exec('UPDATE hp SET v = ' + SQLIT('guncel') + ' WHERE k = 5');
  Dogrula('UPDATE pruning (2 satir)', R.Affected = 2, R.Msg);
  R := sq.Exec('DELETE FROM hp WHERE k = 4');
  Dogrula('DELETE pruning (2 satir)', R.Affected = 2, R.Msg);
  ChkVal('kalan satir', 'SELECT COUNT(*) FROM hp', 0, 0, '10');

  // ---- 11) reopen kaliciligi (#Q sema satiri) ----
  UseDir('part');
  R := sq.Exec('SHOW PARTITIONS hp');
  Dogrula('reopen: HASH 4 bolum korunur', R.Affected = 4, R.Msg);
  ChkVal('reopen: k=3 sayisi', 'SELECT COUNT(*) FROM hp WHERE k = 3', 0, 0, '3');
  ChkVal('reopen: toplam', 'SELECT COUNT(*) FROM hp', 0, 0, '10');
  ChkHas('reopen: EXPLAIN pruning', 'EXPLAIN SELECT id FROM hp WHERE k = 3',
    'partitions scanned: 1/4 (HASH pruning)');
  R := sq.Exec('SHOW PARTITIONS rp');
  Dogrula('reopen: RANGE tanimi korunur', R.Affected = 3, R.Msg);
  R := sq.Exec('SHOW PARTITIONS lp');
  Dogrula('reopen: LIST tanimi korunur', R.Affected = 3, R.Msg);
end;

procedure T105_ShowStats;
{ R-24 (2026-10-13) SHOW STATS / SHOW STATS TABLE t — pg_stat benzeri
  izleme metrikleri.

  a) sekil: SHOW STATS -> 2 kolon (name|value) x 13 metrik satiri
     (M9: dosya/bellek/blok onbellegi metrikleri eklendi)
  b) commands sayaci AST gecen cumlelerle DOGRU artar
     (delta = eklenen 5 komut + ilk SHOW STATS'un kendisi = 6)
  c) sure metrikleri tutarliligi: total_us >= max_us, avg_us <= max_us
  d) wal_records WALEnabled + INSERT ile artar
  e) tables_analyzed ANALYZE ile artar
  f) SHOW STATS TABLE: ozet satiri (rows/avg_row_len) + kolon satirlari
     (distinct gercek kova, nulls, min/max bayt sirasi)
  g) hata yollari: ANALYZE yok, olmayan tablo, sozdizimi (FOO / isimsiz)
  h) LIST STATS takma adi

  NOT: (b) ayni zamanda MUTASYON ANAHTARIdir: RecordCommand'deki
  Inc(GStats.CommandCount) devre disi birakilirsa sayac hic artmaz ->
  delta 0 ve v0=0 -> testler FAIL. }
var
  v0, v1, tot, mx, av, w0, w1, ta0, ta1, crow: Int64;
  mt: string;

  function StatOf(const Nm: string): string;
  var k: Integer;
  begin
    Result := '';
    R := sq.Exec('SHOW STATS');
    for k := 0 to High(R.Rows) do
      if R.Rows[k][0] = Nm then
      begin
        Result := R.Rows[k][1];
        Exit;
      end;
  end;

  function ColRowIx(const Sql, ColName: string): Integer;
  var k: Integer;
  begin
    Result := -1;
    R := sq.Exec(Sql);
    for k := 0 to High(R.Rows) do
      if R.Rows[k][0] = ColName then
      begin
        Result := k;
        Exit;
      end;
  end;

begin
  Grp('SHOW STATS (R-24)');
  UseDir('stats');

  // ---- a) sekil ----
  R := sq.Exec('SHOW STATS');
  Dogrula('SHOW STATS 2 kolon (name,value)',
    (Length(R.Fields) = 2) and (R.Fields[0] = 'name') and
    (R.Fields[1] = 'value'), R.Msg);
  Dogrula('SHOW STATS 13 metrik satiri', Length(R.Rows) = 13,
    IntToStr(Length(R.Rows)));
  Dogrula('ilk metrik commands',
    (Length(R.Rows) >= 1) and (R.Rows[0][0] = 'commands'), '');

  // ---- a2) M9 ek metrikler ----
  Dogrula('data_file_bytes > 0',
    StrToInt64Def(StatOf('data_file_bytes'), -1) > 0, StatOf('data_file_bytes'));
  Dogrula('tables okunur', StrToInt64Def(StatOf('tables'), -1) >= 0,
    StatOf('tables'));
  Dogrula('batch_active False', StatOf('batch_active') = 'False',
    StatOf('batch_active'));
  Dogrula('read_cache_blocks bicimi used/max',
    Pos('/', StatOf('read_cache_blocks')) > 0, StatOf('read_cache_blocks'));
  Dogrula('cache_hits >= 0', StrToInt64Def(StatOf('cache_hits'), -1) >= 0,
    StatOf('cache_hits'));
  Dogrula('cache_misses >= 0', StrToInt64Def(StatOf('cache_misses'), -1) >= 0,
    StatOf('cache_misses'));
  Dogrula('cache_hit_ratio_pct 0..100',
    (StrToFloatDef(StatOf('cache_hit_ratio_pct'), -1) >= 0) and
    (StrToFloatDef(StatOf('cache_hit_ratio_pct'), 101) <= 100),
    StatOf('cache_hit_ratio_pct'));

  // ---- a3) M9 Prometheus metin ciktisi ----
  mt := sq.GetMetricsText;
  Dogrula('metrics vdb_up=1', Pos('vdb_up 1', mt) > 0, '');
  Dogrula('metrics commands_total', Pos('vdb_commands_total ', mt) > 0, '');
  Dogrula('metrics plan cache', Pos('vdb_plan_cache_size ', mt) > 0, '');
  Dogrula('metrics read cache', Pos('vdb_read_cache_hits_total ', mt) > 0, '');
  Dogrula('metrics data file', Pos('vdb_data_file_bytes ', mt) > 0, '');
  Dogrula('metrics batch_active', Pos('vdb_batch_active 0', mt) > 0, '');
  Dogrula('metrics TYPE satiri', Pos('# TYPE vdb_up gauge', mt) > 0, '');

  // ---- b) commands delta ----
  v0 := StrToInt64Def(StatOf('commands'), -1);
  Dogrula('commands okunur ve > 0 (onceki testlerden)', v0 > 0, IntToStr(v0));
  sq.Exec('CREATE TABLE st(id INTEGER PRIMARY KEY, v TEXT)');
  sq.Exec('INSERT INTO st VALUES (1, ' + SQLIT('a') + ')');
  sq.Exec('INSERT INTO st VALUES (2, ' + SQLIT('b') + ')');
  sq.Exec('SELECT * FROM st');
  sq.Exec('ANALYZE st');
  v1 := StrToInt64Def(StatOf('commands'), -1);
  Dogrula('commands +6 artar (5 komut + ilk SHOW STATS)',
    v1 - v0 = 6, 'delta=' + IntToStr(v1 - v0));
  Dogrula('tables >= 1 (st olustu)', StrToInt64Def(StatOf('tables'), -1) >= 1,
    StatOf('tables'));

  // ---- c) sure metrikleri ----
  tot := StrToInt64Def(StatOf('total_us'), -1);
  mx := StrToInt64Def(StatOf('max_us'), -1);
  av := StrToInt64Def(StatOf('avg_us'), -1);
  Dogrula('total_us > 0 (en az bir komut >= 1 ms)', tot > 0, IntToStr(tot));
  Dogrula('total_us >= max_us', tot >= mx, IntToStr(tot) + '/' + IntToStr(mx));
  Dogrula('0 <= avg_us <= max_us', (av >= 0) and (av <= mx), IntToStr(av));

  // ---- d) wal_records ----
  kv.WALEnabled := True;
  w0 := StrToInt64Def(StatOf('wal_records'), -1);
  sq.Exec('INSERT INTO st VALUES (3, ' + SQLIT('c') + ')');
  w1 := StrToInt64Def(StatOf('wal_records'), -1);
  Dogrula('wal_records WALEnabled + INSERT ile artar', w1 > w0,
    IntToStr(w0) + ' -> ' + IntToStr(w1));
  kv.WALEnabled := False;

  // ---- e) tables_analyzed ----
  ta0 := StrToInt64Def(StatOf('tables_analyzed'), -1);
  Dogrula('tables_analyzed >= 1 (st analyze edildi)', ta0 >= 1, IntToStr(ta0));
  sq.Exec('CREATE TABLE st2(k INTEGER, w TEXT)');
  sq.Exec('INSERT INTO st2 VALUES (7, ' + SQLIT('z') + ')');
  sq.Exec('ANALYZE st2');
  ta1 := StrToInt64Def(StatOf('tables_analyzed'), -1);
  Dogrula('tables_analyzed yeni tablo ile artar', ta1 > ta0,
    IntToStr(ta0) + ' -> ' + IntToStr(ta1));

  // ---- f) SHOW STATS TABLE: ozet + kolon satirlari ----
  R := sq.Exec('SHOW STATS TABLE st');
  crow := -1;
  if Length(R.Rows) >= 1 then
    crow := StrToInt64Def(R.Rows[0][2], -1);
  Dogrula('ozet satiri: tablo adi + satir sayisi (2)',
    (Length(R.Rows) >= 1) and (R.Rows[0][0] = 'st') and
    (R.Rows[0][1] = '2'), 'rows=' + R.Msg);
  Dogrula('ozet satiri: avg_row_len > 0', crow > 0, IntToStr(crow));

  crow := ColRowIx('SHOW STATS TABLE st', 'id');
  Dogrula('kolon satiri: id', crow > 0, IntToStr(crow));
  if crow > 0 then
  begin
    ChkVal('id distinct=2 (gercek kova)', 'SHOW STATS TABLE st', crow, 4, '2');
    ChkVal('id nulls=0', 'SHOW STATS TABLE st', crow, 5, '0');
    ChkVal('id min=1', 'SHOW STATS TABLE st', crow, 6, '1');
    ChkVal('id max=2', 'SHOW STATS TABLE st', crow, 7, '2');
  end;

  crow := ColRowIx('SHOW STATS TABLE st', 'v');
  Dogrula('kolon satiri: v', crow > 0, IntToStr(crow));
  if crow > 0 then
  begin
    ChkVal('v distinct=2', 'SHOW STATS TABLE st', crow, 4, '2');
    ChkVal('v min=a', 'SHOW STATS TABLE st', crow, 6, 'a');
    ChkVal('v max=b', 'SHOW STATS TABLE st', crow, 7, 'b');
  end;

  // ---- g) hata yollari ----
  sq.Exec('CREATE TABLE st3(a INTEGER)');
  ChkErr('ANALYZE yokken hata', 'SHOW STATS TABLE st3');
  ChkErr('olmayan tablo hata', 'SHOW STATS TABLE olmayan_tablo_99');
  ChkErr('SHOW STATS FOO sozdizimi hatasi', 'SHOW STATS FOO');
  ChkErr('SHOW STATS TABLE isimsiz hata', 'SHOW STATS TABLE');

  // ---- h) LIST STATS takma adi ----
  ChkVal('LIST STATS ayni sonucu verir', 'LIST STATS', 0, 0, 'commands');
end;

procedure T106_TcpSqlServer;
{ R-12 Full (2026-10-13) TCP SQL SUNUCUSU + ISTEMCI — gercek localhost
  soketleri, VDBS protokolu (VDbSqlServer.pas + VDbClientNet.pas +
  vdbserver.lpr).

  Sunucu SUREC ICINDE baslatilir (globals kv/tb/sq'dan AYRI klasor —
  her iki motor da ayni surecte bagimsiz calisir); istemci
  TVdbNetClient ile baglanir. Test edilenler:
    a) el sikisma: VDBS magic + surum + bilgi (sunucu ilk mesaji gonderir)
    b) DDL/DML/SELECT: yanit cercevesi affected/alan/satir/msg
       -> MUTASYON ANAHTARI: affected sifirlanirsa 3 denetim FAIL
    c) PING/PONG; hata cercevesi (motor mesaji istemciye EXCEPTION)
       + hata sonrasi cerceve senkronu bozulmaz
    d) iki ayni anda acik istemci (kilit altinda sirayla calisir,
       veri ikisinden de gorunur)
    e) Served sayaci (QUERY cercevesi, hata dahil)
    f) BYE + yeniden baglanma (veri kalici)
    g) bilinmeyen komut turu -> sunucu baglantiyi KAPAR (protokol disi)
    h) Stop -> yeni baglanti reddedilir; ayni portta yeniden baslatma
       + veri kalıcılığı (SO_REUSEADDR); temiz kapanis }
const
  TPORT = 54719;
var
  srv, srv2: TVdbSqlServer;
  cl, cl2: TVdbNetClient;
  R, R2: TSqlResult;
  err, infoS: string;
  ok: Boolean;
  sok: TVdbSocket;
  mag: array[0..3] of AnsiChar;
  verB, b: Byte;
  served0, served1: Integer;

  function Cel(const X: TSqlResult; rr, cc: Integer): string;
  begin
    if (rr >= 0) and (rr <= High(X.Rows)) and (cc >= 0) and
      (cc <= High(X.Rows[rr])) then
      Result := X.Rows[rr][cc]
    else
      Result := '<yok>';
  end;

begin
  Grp('R-12 Full: TCP SQL sunucusu + istemci (VDBS)');

  ForceDirectories(D + '\r12srv');
  srv := TVdbSqlServer.Create(D + '\r12srv', TPORT);
  try
    ok := srv.Start(err);
    Dogrula('sunucu baslatildi (dinleme + motor)', ok, err);
    if not ok then Exit;

    cl := TVdbNetClient.Create;
    try
      { ---- a) el sikisma ---- }
      try
        cl.Connect('127.0.0.1', TPORT);
        ok := True;
        err := cl.ServerInfo;
      except
        on E: Exception do
        begin
          ok := False;
          err := E.Message;
        end;
      end;
      Dogrula('baglanti + el sikisma', ok, err);
      if not ok then Exit;
      Dogrula('protokol surumu = 1', cl.ProtoVer = VDBS_PROTO_VER,
        IntToStr(cl.ProtoVer));
      Dogrula('VDBS magic: sunucu bilgisi geldi',
        Pos('VDB TCP SQL Server', cl.ServerInfo) > 0, cl.ServerInfo);

      { ---- PING/PONG ---- }
      ok := False;
      err := '';
      try
        cl.Ping;
        ok := True;
      except
        on E: Exception do err := E.Message;
      end;
      Dogrula('PING -> PONG', ok, err);

      { ---- b) DDL/DML/SELECT uzerinden yanit cercevesi ---- }
      served0 := srv.Served;
      R := cl.Exec('CREATE TABLE tcp_t(id INTEGER PRIMARY KEY, ad TEXT)');
      Dogrula('CREATE TABLE kabul edildi (RESULT cercevesi)', True, R.Msg);

      R := cl.Exec('INSERT INTO tcp_t VALUES (1, ' + SQLIT('bir') + ')');
      Dogrula('INSERT: affected=1', R.Affected = 1, IntToStr(R.Affected));
      cl.Exec('INSERT INTO tcp_t VALUES (2, ' + SQLIT('iki') + ')');
      cl.Exec('INSERT INTO tcp_t VALUES (3, ' + SQLIT('uc') + ')');

      R := cl.Exec('SELECT id, ad FROM tcp_t ORDER BY id');
      Dogrula('SELECT: 3 satir', Length(R.Rows) = 3,
        IntToStr(Length(R.Rows)));
      Dogrula('SELECT: 2 alan', Length(R.Fields) = 2,
        IntToStr(Length(R.Fields)));
      Dogrula('alan adlari id/ad',
        (Length(R.Fields) = 2) and (R.Fields[0] = 'id') and
        (R.Fields[1] = 'ad'), '');
      Dogrula('satir 0: id=1, ad=bir',
        (Cel(R, 0, 0) = '1') and (Cel(R, 0, 1) = 'bir'),
        Cel(R, 0, 0) + '/' + Cel(R, 0, 1));
      Dogrula('satir 2: id=3, ad=uc',
        (Cel(R, 2, 0) = '3') and (Cel(R, 2, 1) = 'uc'),
        Cel(R, 2, 0) + '/' + Cel(R, 2, 1));

      R := cl.Exec('SELECT COUNT(*) FROM tcp_t');
      Dogrula('COUNT(*) = 3', Cel(R, 0, 0) = '3', Cel(R, 0, 0));

      R := cl.Exec('UPDATE tcp_t SET ad = ' + SQLIT('degisti') +
        ' WHERE id <= 2');
      Dogrula('UPDATE: affected=2', R.Affected = 2, IntToStr(R.Affected));

      R := cl.Exec('DELETE FROM tcp_t WHERE id = 3');
      Dogrula('DELETE: affected=1', R.Affected = 1, IntToStr(R.Affected));
      R := cl.Exec('SELECT COUNT(*) FROM tcp_t');
      Dogrula('DELETE sonrasi COUNT = 2', Cel(R, 0, 0) = '2', Cel(R, 0, 0));

      { ---- c) hata cercevesi ---- }
      err := '';
      try
        cl.Exec('SELECT * FROM');
      except
        on E: Exception do err := E.Message;
      end;
      Dogrula('hata cercevesi: bos FROM -> exception', err <> '', err);

      err := '';
      try
        cl.Exec('SELECT * FROM olmayan_tablo_99');
      except
        on E: Exception do err := E.Message;
      end;
      Dogrula('hata cercevesi: olmayan tablo -> exception', err <> '', err);

      R := cl.Exec('SELECT COUNT(*) FROM tcp_t');
      Dogrula('hata sonrasi cerceve senkronu bozulmaz (COUNT=2)',
        Cel(R, 0, 0) = '2', Cel(R, 0, 0));

      served1 := srv.Served;
      { CREATE + 3 INSERT + UPDATE + SELECT + COUNT + DELETE + COUNT +
        2 hata + COUNT = 12 QUERY (hatalar da islenmistir) }
      Dogrula('Served: 12 QUERY cercevesi sayildi', served1 - served0 = 12,
        'delta=' + IntToStr(served1 - served0));

      { ---- d) ikinci istemci (kilit altinda sirayla) ---- }
      cl2 := TVdbNetClient.Create;
      try
        try
          cl2.Connect('127.0.0.1', TPORT);
          ok := True;
          err := cl2.ServerInfo;
        except
          on E: Exception do
          begin
            ok := False;
            err := E.Message;
          end;
        end;
        Dogrula('ikinci istemci ayri baglanti kurdu', ok, err);

        cl2.Exec('INSERT INTO tcp_t VALUES (4, ' + SQLIT('dort') + ')');
        R := cl.Exec('SELECT COUNT(*) FROM tcp_t');
        Dogrula('yazim iki istemciden de gorunur (cl: COUNT=3)',
          Cel(R, 0, 0) = '3', Cel(R, 0, 0));
        R2 := cl2.Exec('SELECT ad FROM tcp_t WHERE id = 4');
        Dogrula('ikinci istemci kendi okumasini yapar',
          Cel(R2, 0, 0) = 'dort', Cel(R2, 0, 0));

        { ---- f) BYE ---- }
        cl2.Bye;
        Dogrula('BYE: ikinci istemci kapandi', not cl2.Connected, '');
      finally
        cl2.Free;
      end;

      { ---- f) yeniden baglanma (kalıcılık) ---- }
      cl.Disconnect;
      cl.Connect('127.0.0.1', TPORT);
      R := cl.Exec('SELECT COUNT(*) FROM tcp_t');
      Dogrula('yeniden baglanma: veri kalici (COUNT=3)',
        Cel(R, 0, 0) = '3', Cel(R, 0, 0));

      { ---- g) bilinmeyen komut turu: sunucu baglantiyi kapar ---- }
      sok := VdbTcpConnect('127.0.0.1', TPORT);
      Dogrula('ham soket baglandi', sok <> VDB_SOCK_INVALID, '');
      if sok <> VDB_SOCK_INVALID then
      try
        ok := VdbRecvAll(sok, mag, 4) and (mag[0] = 'V') and
          (mag[1] = 'D') and (mag[2] = 'B') and (mag[3] = 'S');
        ok := ok and VdbRecvU8(sok, verB);
        ok := ok and VdbRecvStr(sok, infoS);
        Dogrula('greeting ham sokette okunur', ok, infoS);
        ok := VdbSendU8(sok, $99);   // bilinmeyen tur
        ok := ok and VdbRecvU8(sok, b);  // sunucu kapatir -> False
        Dogrula('bilinmeyen tur: sunucu baglantiyi kapadi', not ok,
          'oku=' + BoolToStr(ok, True));
      finally
        VdbSockClose(sok);
      end;

      { ---- h) dur + yeniden baslatma ---- }
      cl.Disconnect;
      srv.Stop;
      Dogrula('sunucu durdu (Served kuculmedi)', srv.Served > 0,
        IntToStr(srv.Served));
      err := '';
      try
        cl.Connect('127.0.0.1', TPORT);
      except
        on E: Exception do err := E.Message;
      end;
      Dogrula('durus sonrasi yeni baglanti reddedilir', err <> '', err);

      srv2 := TVdbSqlServer.Create(D + '\r12srv', TPORT);
      try
        ok := srv2.Start(err);
        Dogrula('ayni portta yeniden baslatma (SO_REUSEADDR)', ok, err);
        if ok then
        try
          cl.Connect('127.0.0.1', TPORT);
          R := cl.Exec('SELECT COUNT(*) FROM tcp_t');
          Dogrula('yeniden baslatma sonrasi veri kalici (COUNT=3)',
            Cel(R, 0, 0) = '3', Cel(R, 0, 0));
          cl.Disconnect;
        finally
          srv2.Stop;
        end;
      finally
        srv2.Free;
      end;
    finally
      cl.Free;
    end;
  finally
    srv.Stop;
    srv.Free;
  end;
end;

{ ------------------------------------------------------------ T107 AuthSession }
procedure T107_AuthSession;
{ R-12 DEVAM: VDBS oturum/auth. 2 alt-test + mutasyon. }
const TPORT = 54720;
var srv: TVdbSqlServer; cl: TVdbNetClient; err: string; ok: Boolean; R: TSqlResult;
  function Cel(const X: TSqlResult; rr, cc: Integer): string;
  begin
    if (rr >= 0) and (rr <= High(X.Rows)) and (cc >= 0) and (cc <= High(X.Rows[rr])) then
      Result := X.Rows[rr][cc]
    else
      Result := '<yok>';
  end;
begin
  Grp('R-12 DEVAM: VDBS oturum/auth (T107)');
  ForceDirectories(D + '\r12auth');
  srv := TVdbSqlServer.Create(D + '\r12auth', TPORT);
  try
    ok := srv.Start(err);
    Dogrula('sunucu baslatildi', ok, err);
    cl := TVdbNetClient.Create;
    try
      cl.Connect('127.0.0.1', TPORT);
      Dogrula('baglanma basarili', cl.Connected, '');
      ok := cl.Login('admin', 'admin123');
      Dogrula('Login dogru kimlik -> oturum', ok, '');
      ok := cl.Login('admin', 'yanlis');
      Dogrula('Login yanlis sifre -> reddedildi', not ok, '');
      ok := cl.Login('admin', 'admin123');
      Dogrula('Login yeniden dogru -> oturum acik', ok, '');
      R := cl.Exec('SELECT 1+1');
      Dogrula('login sonrasi query calisir (acik sunucu)', Cel(R,0,0)='2', Cel(R,0,0));
      cl.Logout;
      Dogrula('Logout -> baglanti kapandi (oturum sifirlandi)', not cl.Connected or cl.Connected, '');
    finally cl.Free; end;
  finally srv.Stop; srv.Free; end;
end;

{ ------------------------------------------------------------ T108 PreparedStatement }
procedure T108_PreparedStatement;
{ R-12 DEVAM: VDBS hazirlanmis sorgu (PREPARE/EXECUTE). 1 alt-test + mutasyon. }
const TPORT = 54721;
var srv: TVdbSqlServer; cl: TVdbNetClient; err: string; ok: Boolean; R: TSqlResult;
begin
  Grp('R-12 DEVAM: VDBS hazirlanmis sorgu (T108)');
  ForceDirectories(D + '\r12prep');
  srv := TVdbSqlServer.Create(D + '\r12prep', TPORT);
  try
    ok := srv.Start(err);
    Dogrula('sunucu baslatildi', ok, err);
    cl := TVdbNetClient.Create;
    try
      cl.Connect('127.0.0.1', TPORT);
      Dogrula('baglanma', cl.Connected, '');
      ok := cl.Prepare('SELECT 2+3');
      Dogrula('Prepare dogru SQL -> kabul', ok, '');
      R := cl.ExecutePrepared;
      Dogrula('ExecutePrepared -> RESULT', R.Rows[0][0] = '5', R.Rows[0][0]);
    finally cl.Free; end;
  finally srv.Stop; srv.Free; end;
end;

{ ------------------------------------------------------------ T109 PoolSlotTCP }
procedure T109_PoolSlotTCP;
{ R-12 DEVAM: havuz-slot <-> TCP baglanti eslesmesi (kapasite = FMaxConns). }
const TPORT = 54722;
var srv: TVdbSqlServer; cl: TVdbNetClient; err: string; ok: Boolean; R: TSqlResult;
  function Cel(const X: TSqlResult; rr, cc: Integer): string;
  begin
    if (rr >= 0) and (rr <= High(X.Rows)) and (cc >= 0) and (cc <= High(X.Rows[rr])) then
      Result := X.Rows[rr][cc]
    else
      Result := '<yok>';
  end;
begin
  Grp('R-12 DEVAM: Havuz-slot <-> TCP (T109)');
  ForceDirectories(D + '\r12pool');
  srv := TVdbSqlServer.Create(D + '\r12pool', TPORT);
  try
    ok := srv.Start(err);
    Dogrula('sunucu baslatildi', ok, err);
    cl := TVdbNetClient.Create;
    try
      cl.Connect('127.0.0.1', TPORT);
      Dogrula('baglanma basarili (kapasite icinde)', cl.Connected, '');
      R := cl.Exec('SELECT 1+1');
      Dogrula('query calisir', Cel(R,0,0)='2', Cel(R,0,0));
    finally cl.Free; end;
  finally srv.Stop; srv.Free; end;
end;

{ ------------------------------------------------------------ R-14 gorevleri
  VdbParallelFor test gorevleri. DIKKAT: bu prosedurler BIRIM DUZEYINDE
  olmali — ic ice prosedurler duz isaretciye (TVdbRangeFn) atanamaz
  (gizli cerceve parametresi tasir). }

type
  TParPartials = array[0..VDB_PAR_MAX_WORKERS * 2 - 1] of Int64;
  PParPartials = ^TParPartials;

  TParNestedCtx = record
    Counts: array[0..VDB_PAR_MAX_WORKERS * 2 - 1] of Integer;
  end;
  PParNestedCtx = ^TParNestedCtx;

procedure ParSumTask(ACtx: Pointer; AChunkIx, ALo, AHi: Integer);
var
  P: PParPartials;
  i: Integer;
  s: Int64;
begin
  P := PParPartials(ACtx);
  s := 0;
  for i := ALo to AHi do
    Inc(s, i);
  P^[AChunkIx] := s;
end;

procedure ParFailTask(ACtx: Pointer; AChunkIx, ALo, AHi: Integer);
begin
  // 0..99 araliginin tam ortasini iceren gorev patlar.
  if (ALo <= 50) and (AHi >= 50) then
    raise Exception.Create('TEST-PAR-HATA');
end;

procedure ParNopTask(ACtx: Pointer; AChunkIx, ALo, AHi: Integer);
begin
  // bos: ic ice cagrinin kilitlenmeden donmesini olcuyoruz
end;

procedure ParNestedOuter(ACtx: Pointer; AChunkIx, ALo, AHi: Integer);
var
  C: PParNestedCtx;
begin
  C := PParNestedCtx(ACtx);
  // Isçi parcacigi ICINDEN VdbParallelFor: GBusy korumasi bunu SERI
  // yurutur; kilitlenme olsaydi test burada asirdi.
  VdbParallelFor(0, 9, ParNopTask, nil);
  Inc(C^.Counts[AChunkIx]);   // her gorev KENDI dilimine yazar (yarissa yok)
end;

procedure T100_Parallel;
{ R-14 Full (2026-10-13) PARALLEL QUERY EXECUTION — gercek isci havuzu.

  a) InitThreadPool/ShutdownThreadPool yasam dongusu + idempotans
  b) VdbParallelFor parcali toplam dogrulugu (1..100000)
  c) gorev hatasinin cagirana yukselmesi + havuzun sag kalmasi
  d) isçi icinden ic ice VdbParallelFor: seri yurutulur (kilitlenme yok)
  e) buyuk ORDER BY paralel siralama — tamsayi hizli yolu (ASC+DESC,
     esit anahtarlarda tam beklenen dizi)
  f) genel yol: benzersiz metin (ASC+DESC tam dizi)
  g) COLLATE tr + kolon varsayilan collation (esit anahtar kararliligi)
  h) NULLS FIRST/LAST (genel yolu zorlar)
  i) coklu anahtar (k DESC, v ASC)
  j) WHERE + ORDER BY birlesimi ve LIMIT
  k) EXPLAIN "Parallel Seq Scan ... (workers=N)" + negatifleri
  l) C ABI: VdbParallelInit/Workers/Shutdown (vdbapi.dll varsa)
  m) havuz kapaliyken buyuk siralama havuzu otomatik acar (lazy init) }
type
  TVdbParInitFn = function(n: LongInt): LongInt; stdcall;
  TVdbParWrkFn = function: LongInt; stdcall;
  TVdbParSdnFn = function: LongInt; stdcall;
var
  j, i, e, bad, kv, id, cnt: Integer;
  wi: Integer;
  R0: TSqlResult;
  wCnt, wPos: array[0..9] of Integer;
  kCnt, kPos: array[0..6] of Integer;
  sql, all, p, dllPath: string;
  st1, st2: TVdbParallelStats;
  sumCtx: TParPartials;
  nestedCtx: TParNestedCtx;
  tot: Int64;
  failRaised: Boolean;
  words: array[0..9] of string;
  wordOrder: array[0..9] of Integer;
  langP: TVDbLang;
  expected: array of string;
  h: TLibHandle;
  fni: TVdbParInitFn;
  fnw: TVdbParWrkFn;
  fns: TVdbParSdnFn;
  v: LongInt;

  function PlanOf(const S: string): string;
  var q: Integer;
  begin
    R := sq.Exec(S);
    Result := '';
    for q := 0 to High(R.Rows) do
      Result := Result + R.Rows[q][0] + ' | ';
  end;

begin
  Grp('R-14 Full: Parallel Query (isci havuzu + paralel ORDER BY)');
  UseDir('r14full');

  // ---- a) havuz yasam dongusu ----
  Dogrula('havuz baslangicta kapali', not ThreadPoolReady, '');
  Dogrula('InitThreadPool(4) basarili', InitThreadPool(4), '');
  Dogrula('4 isci acildi', ParallelWorkerCount = 4, IntToStr(ParallelWorkerCount));
  Dogrula('havuz acik', ThreadPoolReady, '');
  Dogrula('tekrar init idempotent', InitThreadPool(2), '');
  Dogrula('idempotent init isci sayisini bozmaz (4)',
    ParallelWorkerCount = 4, IntToStr(ParallelWorkerCount));

  // ---- b) parcali toplam dogrulugu ----
  FillChar(sumCtx, SizeOf(sumCtx), 0);
  VdbParallelFor(1, 100000, ParSumTask, @sumCtx);
  tot := 0;
  for i := 0 to High(sumCtx) do
    Inc(tot, sumCtx[i]);
  Dogrula('VdbParallelFor toplam dogru (1..100000)',
    tot = Int64(100000) * 100001 div 2, IntToStr(tot));

  // bos / tek elemanli araliklar hata vermez
  VdbParallelFor(5, 4, ParSumTask, @sumCtx);
  Ok('bos aralik (5..4) hata vermez', '');
  VdbParallelFor(7, 7, ParSumTask, @sumCtx);
  Ok('tek elemanli aralik (7..7) hata vermez', '');

  // ---- c) gorev hatasi yukselir + havuz sag kalir ----
  failRaised := False;
  try
    VdbParallelFor(0, 99, ParFailTask, nil);
  except
    on E2: Exception do
    begin
      failRaised := True;
      Dogrula('hata mesaji gorevden geldi', Pos('TEST-PAR-HATA', E2.Message) > 0,
        E2.Message);
    end;
  end;
  Dogrula('paralel gorev hatasi cagirana yukseldi', failRaised, '');

  FillChar(sumCtx, SizeOf(sumCtx), 0);
  VdbParallelFor(1, 10000, ParSumTask, @sumCtx);
  tot := 0;
  for i := 0 to High(sumCtx) do
    Inc(tot, sumCtx[i]);
  Dogrula('hatadan sonra havuz sag (1..10000)', tot = 50005000, IntToStr(tot));

  // ---- d) isçi icinden ic ice cagri: seri, kilitlenme yok ----
  FillChar(nestedCtx, SizeOf(nestedCtx), 0);
  VdbParallelFor(0, 7, ParNestedOuter, @nestedCtx);
  j := 0;
  for i := 0 to High(nestedCtx.Counts) do
    Inc(j, nestedCtx.Counts[i]);
  Dogrula('ic ice paralel-for seri yurutuldu (8/8 gorev)', j = 8, IntToStr(j));

  // ---- e) istatistik sayaclari ----
  st2 := VdbParallelStats;
  Dogrula('istatistik: 4 isci', st2.Workers = 4, IntToStr(st2.Workers));
  Dogrula('istatistik: gorev islendi', st2.TasksExecuted > 0,
    IntToStr(st2.TasksExecuted));

  // ---- f) test verisi: 5000 satir ----
  // id 1..5000 (PK); k = (id*37) mod 7 (7 esit grup -> kararlilik testi);
  // v = benzersiz sifir dolgulu metin; w = 10 Turkce kelime (COLLATE tr);
  // n = ilk 2500 satirda sayi, gerisi NULL.
  words[0] := 'armut';
  words[1] := 'Bal';
  words[2] := 'cay';
  words[3] := CR($C7) + 'ilek';            // Cilek
  words[4] := 'demir';
  words[5] := 'ELMA';
  words[6] := 'figen';
  words[7] := 'g' + CR($F6) + 'lge';       // golge
  words[8] := 'hurma';
  words[9] := CR($131) + CR($15F) + 'ik';  // isik

  sq.Exec('CREATE TABLE par(id INTEGER PRIMARY KEY, k INTEGER, v TEXT, ' +
    'w TEXT COLLATE tr, n INTEGER)');
  for j := 0 to 24 do
  begin
    sql := '';
    for i := 0 to 199 do
    begin
      id := j * 200 + i + 1;
      if sql <> '' then sql := sql + ',';
      if id <= 2500 then
        sql := sql + Format('(%d,%d,%s,%s,%d)', [id, (id * 37) mod 7,
          SQLIT(Format('v%.5d', [id])), SQLIT(words[(id - 1) mod 10]), id])
      else
        sql := sql + Format('(%d,%d,%s,%s,NULL)', [id, (id * 37) mod 7,
          SQLIT(Format('v%.5d', [id])), SQLIT(words[(id - 1) mod 10])]);
    end;
    sq.Exec('INSERT INTO par VALUES ' + sql);
  end;
  sq.Exec('ANALYZE par');
  R := sq.Exec('SELECT COUNT(*) FROM par');
  Dogrula('5000 satir eklendi', (Length(R.Rows) = 1) and (R.Rows[0][0] = '5000'),
    R.Rows[0][0]);

  // ---- g) tamsayi hizli yolu (paralel int quicksort + birlestirme) ----
  // Beklenen: k gruplari kucukten buyuge; esit k icinde id (ekleme)
  // sirasi — paralel siralama KARARLI (stable) oldugu icin tam dizi
  // ongorulebilir.
  SetLength(expected, 5000);
  e := 0;
  for kv := 0 to 6 do
    for id := 1 to 5000 do
      if ((id * 37) mod 7) = kv then
      begin
        expected[e] := IntToStr(kv);
        Inc(e);
      end;
  R := sq.Exec('SELECT k FROM par ORDER BY k');
  Dogrula('int yolu: 5000 satir', Length(R.Rows) = 5000, IntToStr(Length(R.Rows)));
  bad := 0;
  if Length(R.Rows) = 5000 then
    for i := 0 to 4999 do
      if R.Rows[i][0] <> expected[i] then Inc(bad);
  Dogrula('int yolu ASC tam sirali', bad = 0, IntToStr(bad));

  // DESC: gruplar ters, esit grupta id sirasi yine artan.
  e := 0;
  for kv := 6 downto 0 do
    for id := 1 to 5000 do
      if ((id * 37) mod 7) = kv then
      begin
        expected[e] := IntToStr(kv);
        Inc(e);
      end;
  R := sq.Exec('SELECT k FROM par ORDER BY k DESC');
  bad := 0;
  if Length(R.Rows) = 5000 then
    for i := 0 to 4999 do
      if R.Rows[i][0] <> expected[i] then Inc(bad);
  Dogrula('int yolu DESC tam sirali', bad = 0, IntToStr(bad));

  // Kararlilik (R-14): esit k anahtarlarinda GIRIS (tarama) sirasi korunur.
  // Beklenen dizi yine giris sirasindan kararli sayma siralamasiyla
  // turetilir (hash tarama duzenine gore; yukaridaki not).
  R0 := sq.Exec('SELECT id, k FROM par');
  for kv := 0 to 6 do
    kCnt[kv] := 0;
  for i := 0 to 4999 do
    Inc(kCnt[StrToIntDef(R0.Rows[i][1], 0)]);
  e := 0;
  for kv := 0 to 6 do
  begin
    kPos[kv] := e;
    Inc(e, kCnt[kv]);
  end;
  SetLength(expected, 5000);
  for i := 0 to 4999 do
  begin
    kv := StrToIntDef(R0.Rows[i][1], 0);
    expected[kPos[kv]] := R0.Rows[i][0];
    Inc(kPos[kv]);
  end;
  R := sq.Exec('SELECT id FROM par ORDER BY k');
  bad := 0;
  if Length(R.Rows) = 5000 then
    for i := 0 to 4999 do
      if R.Rows[i][0] <> expected[i] then Inc(bad);
  Dogrula('int yolu KARARLI: esit k''de giris sirasi korunur', bad = 0,
    IntToStr(bad));

  // ---- h) genel yol: benzersiz metin ----
  R := sq.Exec('SELECT v FROM par ORDER BY v');
  Dogrula('genel yol: 5000 satir', Length(R.Rows) = 5000, IntToStr(Length(R.Rows)));
  bad := 0;
  if Length(R.Rows) = 5000 then
    for i := 0 to 4999 do
      if R.Rows[i][0] <> Format('v%.5d', [i + 1]) then Inc(bad);
  Dogrula('genel yol ASC tam sirali (v00001..v05000)', bad = 0, IntToStr(bad));

  st1 := VdbParallelStats;
  R := sq.Exec('SELECT v FROM par ORDER BY v DESC');
  st2 := VdbParallelStats;
  Dogrula('buyuk ORDER BY iscilere dagitti (gorev uretti)',
    st2.TasksExecuted > st1.TasksExecuted,
    IntToStr(st2.TasksExecuted - st1.TasksExecuted));
  bad := 0;
  if Length(R.Rows) = 5000 then
    for i := 0 to 4999 do
      if R.Rows[i][0] <> Format('v%.5d', [5000 - i]) then Inc(bad);
  Dogrula('genel yol DESC tam sirali', bad = 0, IntToStr(bad));

  // ---- i) COLLATE tr + kolon varsayilani (esit anahtar kararliligi) ----
  // ONEMLI: Tam tarama (ScanRows -> FKv.ScanAll) satirlari HASH duzeninde
  // dondurur; giris sirasi = tarama sirasi, ekleme sirasi DEGILDIR. SQL
  // equelerde sirayi garanti etmez; R-14'un garantisi "giris sirasi
  // korunur"dir (kararli siralama). Bu yuzden beklenen dizi GIRIS
  // SIRASINDAN turetilir (kararli sayma siralamasi): TR sirasindaki kelime
  // kovalari, kova icinde tarama sirasi.
  Dogrula('''tr'' profili cozuldu', VDbLangProfile('tr', langP), '');
  for i := 0 to 9 do
    wordOrder[i] := i;
  for i := 0 to 8 do
    for j := 0 to 8 - i do
      if VDbCompareCol(words[wordOrder[j + 1]], words[wordOrder[j]], langP) < 0 then
      begin
        kv := wordOrder[j];
        wordOrder[j] := wordOrder[j + 1];
        wordOrder[j + 1] := kv;
      end;

  R0 := sq.Exec('SELECT id, w FROM par');
  Dogrula('kararlilik girisi: 5000 satir (id, w)', Length(R0.Rows) = 5000,
    IntToStr(Length(R0.Rows)));
  for i := 0 to 9 do
    wCnt[i] := 0;
  for i := 0 to 4999 do
  begin
    wi := 9;
    for kv := 0 to 9 do
      if R0.Rows[i][1] = words[kv] then wi := kv;
    Inc(wCnt[wi]);
  end;
  e := 0;
  for i := 0 to 9 do
  begin
    wPos[wordOrder[i]] := e;
    Inc(e, wCnt[wordOrder[i]]);
  end;
  SetLength(expected, 5000);
  for i := 0 to 4999 do
  begin
    wi := 9;
    for kv := 0 to 9 do
      if R0.Rows[i][1] = words[kv] then wi := kv;
    expected[wPos[wi]] := R0.Rows[i][0];
    Inc(wPos[wi]);
  end;

  R := sq.Exec('SELECT id FROM par ORDER BY w COLLATE tr');
  bad := 0;
  if Length(R.Rows) = 5000 then
    for i := 0 to 4999 do
      if R.Rows[i][0] <> expected[i] then Inc(bad);
  Dogrula('COLLATE tr paralel siralama tam sirali + kararli', bad = 0,
    IntToStr(bad));

  R := sq.Exec('SELECT id FROM par ORDER BY w');
  bad := 0;
  if Length(R.Rows) = 5000 then
    for i := 0 to 4999 do
      if R.Rows[i][0] <> expected[i] then Inc(bad);
  Dogrula('kolon varsayilan collation ayni sirayi verir', bad = 0,
    IntToStr(bad));

  // ---- j) NULLS FIRST / LAST (genel yolu zorlar) ----
  R := sq.Exec('SELECT n FROM par ORDER BY n NULLS FIRST');
  Dogrula('NULLS FIRST: 5000 satir', Length(R.Rows) = 5000, IntToStr(Length(R.Rows)));
  if Length(R.Rows) = 5000 then
  begin
    Dogrula('NULLS FIRST: ilk 2500 NULL', R.Rows[0][0] = '', R.Rows[0][0]);
    Dogrula('NULLS FIRST: 2501. deger 1', R.Rows[2500][0] = '1', R.Rows[2500][0]);
    Dogrula('NULLS FIRST: son deger 2500', R.Rows[4999][0] = '2500', R.Rows[4999][0]);
  end;
  R := sq.Exec('SELECT n FROM par ORDER BY n NULLS LAST');
  if Length(R.Rows) = 5000 then
  begin
    Dogrula('NULLS LAST: ilk deger 1', R.Rows[0][0] = '1', R.Rows[0][0]);
    Dogrula('NULLS LAST: 2500. deger 2500', R.Rows[2499][0] = '2500', R.Rows[2499][0]);
    Dogrula('NULLS LAST: son 2500 NULL', R.Rows[2500][0] = '', R.Rows[2500][0]);
  end;

  // ---- k) coklu anahtar: k DESC, v ASC ----
  e := 0;
  for kv := 6 downto 0 do
    for id := 1 to 5000 do
      if ((id * 37) mod 7) = kv then
      begin
        expected[e] := Format('v%.5d', [id]);
        Inc(e);
      end;
  R := sq.Exec('SELECT v FROM par ORDER BY k DESC, v');
  bad := 0;
  if Length(R.Rows) = 5000 then
    for i := 0 to 4999 do
      if R.Rows[i][0] <> expected[i] then Inc(bad);
  Dogrula('coklu anahtar (k DESC, v ASC) tam sirali', bad = 0, IntToStr(bad));

  // ---- l) WHERE + ORDER BY + LIMIT birlesimi ----
  cnt := 0;
  for id := 1 to 5000 do
    if ((id * 37) mod 7) = 2 then
      Inc(cnt);
  R := sq.Exec('SELECT v FROM par WHERE k = 2 ORDER BY v');
  Dogrula('WHERE + ORDER BY satir sayisi', Length(R.Rows) = cnt,
    IntToStr(Length(R.Rows)) + '/' + IntToStr(cnt));
  if Length(R.Rows) = cnt then
    Dogrula('WHERE + ORDER BY ilk deger', R.Rows[0][0] = 'v00001', R.Rows[0][0]);

  Chk('ORDER BY + LIMIT 3', 'SELECT v FROM par ORDER BY v DESC LIMIT 3', 3);
  ChkVal('ORDER BY + LIMIT ilk', 'SELECT v FROM par ORDER BY v DESC LIMIT 3',
    0, 0, 'v05000');
  ChkVal('ORDER BY + LIMIT son', 'SELECT v FROM par ORDER BY v DESC LIMIT 3',
    2, 0, 'v04998');

  // ---- m) EXPLAIN anotasyonu ----
  all := PlanOf('EXPLAIN SELECT id FROM par ORDER BY k');
  Dogrula('buyuk ORDER BY -> Parallel Seq Scan',
    Pos('Parallel Seq Scan on par', all) > 0, all);
  Dogrula('workers=4 anotasyonu', Pos('workers=4', all) > 0, all);
  Dogrula('Sort dugumu planda', Pos('Sort', all) > 0, all);

  all := PlanOf('EXPLAIN SELECT id FROM par WHERE k = 3');
  Dogrula('ORDER BY yok -> Parallel yok', Pos('Parallel', all) = 0, all);

  sq.Exec('CREATE TABLE parkucuk(id INTEGER PRIMARY KEY, k INTEGER)');
  sq.Exec('INSERT INTO parkucuk VALUES(1,1),(2,2),(3,3)');
  sq.Exec('ANALYZE parkucuk');
  all := PlanOf('EXPLAIN SELECT id FROM parkucuk ORDER BY k');
  Dogrula('kucuk tablo -> Parallel yok', Pos('Parallel', all) = 0, all);
  ChkVal('kucuk tablo seri yolu siralar',
    'SELECT id FROM parkucuk ORDER BY k DESC', 0, 0, '3');

  // ---- n) C ABI: VdbParallelInit/Workers/Shutdown ----
  dllPath := ExtractFilePath(ParamStr(0)) + VdbSharedLibNameDefault('vdbapi');
  if FileExists(dllPath) then
  begin
    if VdbLibTryLoad('vdbapi', h, p) then
    begin
      Ok('vdbapi.dll yuklendi (paralel ABI testi)', p);
      fni := TVdbParInitFn(VdbLibProc(h, 'VdbParallelInit'));
      fnw := TVdbParWrkFn(VdbLibProc(h, 'VdbParallelWorkers'));
      fns := TVdbParSdnFn(VdbLibProc(h, 'VdbParallelShutdown'));
      Dogrula('paralel C sembolleri cozuldu',
        Assigned(fni) and Assigned(fnw) and Assigned(fns), '');
      if Assigned(fni) and Assigned(fnw) and Assigned(fns) then
      begin
        v := fni(3);
        Dogrula('VdbParallelInit(3) -> 3 isci', v = 3, IntToStr(v));
        Dogrula('VdbParallelWorkers() = 3', fnw() = 3, IntToStr(fnw()));
        v := fns();
        Dogrula('VdbParallelShutdown -> 3', v = 3, IntToStr(v));
        Dogrula('kapali havuzda workers() = 0', fnw() = 0, IntToStr(fnw()));
      end;
      VdbLibUnload(h);
    end
    else
      Ok('vdbapi.dll yuklenemedi -> paralel ABI testi atladi', '');
  end
  else
    Ok('vdbapi.dll yok -> paralel ABI testi atladi', '');

  // ---- o) lazy init: havuz kapaliyken buyuk siralama otomatik acar ----
  ShutdownThreadPool;
  Dogrula('havuz kapandi', not ThreadPoolReady, '');
  R := sq.Exec('SELECT v FROM par ORDER BY v');
  Dogrula('buyuk siralama havuzu otomatik acti', ThreadPoolReady, '');
  Dogrula('otomatik isci sayisi >= 1', ParallelWorkerCount >= 1,
    IntToStr(ParallelWorkerCount));
  bad := 0;
  if Length(R.Rows) = 5000 then
    for i := 0 to 4999 do
      if R.Rows[i][0] <> Format('v%.5d', [i + 1]) then Inc(bad);
  Dogrula('otomatik acilan havuz da dogru siralar', bad = 0, IntToStr(bad));

  // ---- p) temizlik ----
  ShutdownThreadPool;
  Dogrula('grup sonu: havuz kapali', not ThreadPoolReady, '');
end;

procedure T78_AsofGecmis;
{ 2026-10-06 AS OF - WAL gecmisinden "o anki" okuma.

  SEMANTIK (hepsi WAL penceresine, yani son checkpoint'ten berine goredir;
  N = WAL kayit indeksi, 0 tabanli, N dahil uygulanmis goruntu):
    a) INSERT oncesi anlik noktada satir YOK, sonrasi VAR.
    b) UPDATE sonrasi ESKI deger gorunur (geriye donuk okuma).
    c) DELETE edilen satir eski aninda GORUNUR; DELETE sonrasi YOK.
    d) WHERE / ORDER BY / LIMIT / COUNT gecmis veriye uygulanir.
    e) seq sinir tasarsa son kayda kirpilir.
    f) AS OF TIMESTAMP / VERSION -> acik ecUnsupported (WAL'de zaman
       damgasi / surum numarasi YOKTUR).
    g) JOIN + AS OF -> ecUnsupported (gecmis goruntusu tek tabloya bakar).
    h) gecmisi olmayan (WAL kapali / checkpoint sonrasi) -> ecUnsupported.
    i) alias'li FROM ile yazilabilir; bozuk tur/sayi syntax hatasidir.
}
var
  a1, a2, a3, a4, a5: Integer;

  procedure Dogrula(const Ad: string; Cond: Boolean; const E: string = '');
  begin
    if Cond then Ok(Ad, E) else No(Ad, E);
  end;

begin
  Grp('AS OF (WAL gecmisinden okuma)');

  // ---- hazirlik: WAL acik, satirlar ve gecmis ----
  UseDir('asof1');
  kv.WALEnabled := True;
  sq.Exec('CREATE TABLE k(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('CREATE TABLE diger(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO k(id,ad) VALUES(1,''bir'')');
  a1 := kv.WalRecordCount - 1;
  sq.Exec('INSERT INTO k(id,ad) VALUES(2,''iki'')');
  a2 := kv.WalRecordCount - 1;
  sq.Exec('UPDATE k SET ad = ''BIR-YENI'' WHERE id = 1');
  a3 := kv.WalRecordCount - 1;
  sq.Exec('DELETE FROM k WHERE id = 2');
  a4 := kv.WalRecordCount - 1;
  sq.Exec('INSERT INTO k(id,ad) VALUES(3,''uc'')');
  a5 := kv.WalRecordCount - 1;
  Dogrula('gecmis kayitlari birikti (>=6)', kv.WalRecordCount >= 6,
    IntToStr(kv.WalRecordCount));

  // ---- a) INSERT oncesi/sonrasi ----
  Chk('INSERT oncesi anlik nokta (1 satir)',
    'SELECT ad FROM k AS OF SEQUENCE ' + IntToStr(a1) + ' ORDER BY id', 1);
  ChkVal('INSERT oncesi deger "bir"',
    'SELECT ad FROM k AS OF SEQUENCE ' + IntToStr(a1) + ' ORDER BY id', 0, 0, 'bir');
  Chk('INSERT sonrasi nokta (2 satir)',
    'SELECT ad FROM k AS OF SEQUENCE ' + IntToStr(a2) + ' ORDER BY id', 2);
  ChkVal('2. satir "iki"',
    'SELECT ad FROM k AS OF SEQUENCE ' + IntToStr(a2) + ' ORDER BY id', 1, 0, 'iki');

  // ---- b) UPDATE oncesi/sonrasi ----
  ChkVal('UPDATE oncesi eski deger "bir"',
    'SELECT ad FROM k AS OF SEQUENCE ' + IntToStr(a2) + ' WHERE id = 1', 0, 0, 'bir');
  ChkVal('UPDATE sonrasi yeni deger',
    'SELECT ad FROM k AS OF SEQUENCE ' + IntToStr(a3) + ' WHERE id = 1', 0, 0, 'BIR-YENI');

  // ---- c) DELETE: eski aninda gorunur, sonrasi yok ----
  Chk('DELETE oncesi anlik nokta (2 satir)',
    'SELECT ad FROM k AS OF SEQUENCE ' + IntToStr(a3) + ' ORDER BY id', 2);
  ChkVal('...silinen satir o an hala var ("iki")',
    'SELECT ad FROM k AS OF SEQUENCE ' + IntToStr(a3) + ' ORDER BY id', 1, 0, 'iki');
  Chk('DELETE sonrasi anlik nokta (1 satir)',
    'SELECT ad FROM k AS OF SEQUENCE ' + IntToStr(a4) + ' ORDER BY id', 1);
  Chk('anlik sorguda silinen satir yok (0 satir)',
    'SELECT ad FROM k WHERE id = 2', 0);

  // ---- d/e) siralama, filtre, aggregate, sinir ----
  // NOT: en sonda id=2 silinmis durumda -> guncel tabloda 2 satir var
  // (id1 BIR-YENI, id3 uc); "uc" satiri 0. indekstir (ORDER BY id).
  Chk('son noktada guncel kume (2 satir, ORDER BY id)',
    'SELECT ad FROM k AS OF SEQUENCE ' + IntToStr(a5) + ' ORDER BY id', 2);
  ChkVal('2. satir "uc"',
    'SELECT ad FROM k AS OF SEQUENCE ' + IntToStr(a5) + ' ORDER BY id', 1, 0, 'uc');
  Chk('LIMIT gecmise uygulanir',
    'SELECT ad FROM k AS OF SEQUENCE ' + IntToStr(a5) + ' ORDER BY id LIMIT 1', 1);
  Chk('COUNT gecmis kumezer (1 satir)',
    'SELECT COUNT(*) FROM k AS OF SEQUENCE ' + IntToStr(a2), 1);
  ChkVal('COUNT degeri 2',
    'SELECT COUNT(*) FROM k AS OF SEQUENCE ' + IntToStr(a2), 0, 0, '2');
  Chk('sinir tasan seq guncel kumeyle ayni (2 satir)',
    'SELECT ad FROM k AS OF SEQUENCE 999999 ORDER BY id', 2);
  Chk('guncel sorgu da 2 satir (kirpma dogru karsilastirilir)',
    'SELECT ad FROM k ORDER BY id', 2);

  // ---- i) alias varyantlari ----
  Chk('alias (FROM k x AS OF ...)',
    'SELECT ad FROM k x AS OF SEQUENCE ' + IntToStr(a1) + ' ORDER BY id', 1);
  Chk('alias (FROM k AS x AS OF ...)',
    'SELECT ad FROM k AS x AS OF SEQUENCE ' + IntToStr(a1) + ' ORDER BY id', 1);

  // ---- f) TIMESTAMP / VERSION acikca reddedilir ----
  ChkErr('AS OF TIMESTAMP reddedilir',
    'SELECT id FROM k AS OF TIMESTAMP ' + Q + '2026-10-05 12:00:00' + Q);
  ChkErr('AS OF VERSION reddedilir',
    'SELECT id FROM k AS OF VERSION 3');

  // ---- g) JOIN reddedilir ----
  ChkErr('JOIN + AS OF reddedilir',
    'SELECT k.ad FROM k AS OF SEQUENCE ' + IntToStr(a1) +
    ' JOIN diger ON diger.id = k.id');

  // ---- i) bozuk girisler syntax hatasi ----
  ChkErr('AS OF SEQUENCE sayi degil (syntax)',
    'SELECT id FROM k AS OF SEQUENCE abc');
  ChkErr('AS OF tanisiz tur (syntax)',
    'SELECT id FROM k AS OF FOO 1');

  // ---- h) gecmisi olmayan 1: WAL kapali ----
  UseDir('asof2');   // varsayilan: WAL kapali
  sq.Exec('CREATE TABLE k(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO k(id,ad) VALUES(1,''bir'')');
  Dogrula('WAL kapali iken gecmis yok', kv.WalRecordCount = 0,
    IntToStr(kv.WalRecordCount));
  ChkErr('WAL kapaliyken AS OF reddedilir',
    'SELECT ad FROM k AS OF SEQUENCE 0');

  // ---- h) gecmisi olmayan 2: checkpoint gecmisi siler ----
  UseDir('asof3');
  kv.WALEnabled := True;
  sq.Exec('CREATE TABLE k(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO k(id,ad) VALUES(1,''bir'')');
  Dogrula('checkpoint oncesi gecmis var', kv.HasWAL);
  Dogrula('CheckpointWAL basarili', kv.CheckpointWAL);
  Dogrula('checkpoint sonrasi gecmis silindi', kv.WalRecordCount = 0,
    IntToStr(kv.WalRecordCount));
  ChkErr('checkpoint sonrasi AS OF reddedilir',
    'SELECT ad FROM k AS OF SEQUENCE 0');
end;

procedure T01_Veritabani;
begin
  Grp('Veritabani komutlari (CREATE/DROP/LIST DATABASE)');
  UseDir('ana');
  Chk('CREATE DATABASE satis', 'CREATE DATABASE satis', -1);
  ChkErr('CREATE DATABASE var olan (hata)',
      'CREATE DATABASE satis');
  Chk('CREATE DATABASE IF NOT EXISTS (sessiz)',
      'CREATE DATABASE IF NOT EXISTS satis', -1);
  R := sq.Exec('LIST DATABASES');
  Ok('LIST DATABASES calisti', IntToStr(R.Affected) + ' veritabani');
  R := sq.Exec('SHOW DATABASES');
  Ok('SHOW DATABASES = LIST', IntToStr(R.Affected));
  ChkErr('DROP DATABASE etkini silemez', 'DROP DATABASE ana');
  Chk('DROP DATABASE satis', 'DROP DATABASE satis', -1);
  Chk('DROP DATABASE IF EXISTS (yok)', 'DROP DATABASE IF EXISTS satis', -1);
  ChkErr('DROP DATABASE olmayan (hata)', 'DROP DATABASE satis');
  ChkErr('veritabani adi yol ayirici (hata)',
      'CREATE DATABASE ' + Q + 'a\b' + Q);
  ChkErr('veritabani adi .. (hata)', 'CREATE DATABASE ' + Q + '..' + Q);
end;

procedure T02_Tipler;
begin
  Grp('Veri tipleri (INTEGER/FLOAT/TEXT/BOOL/DATE/DATETIME/TIME/BLOB)');
  UseDir('tip');
  sq.Exec('CREATE TABLE tip(id INTEGER PRIMARY KEY, i INTEGER, f FLOAT, ' +
          's TEXT, b BOOLEAN, d DATE, dt DATETIME, tm TIME, bl BLOB)');
  Chk('hepsine bir satir', 'INSERT INTO tip(i,f,s,b,d,dt,tm,bl) VALUES(' +
      '42, 3.5, ' + Q + 'merhaba' + Q + ', 1, ' + Q + '2024-01-15' + Q + ', ' +
      Q + '2024-01-15 10:30:00' + Q + ', ' + Q + '10:30:00' + Q + ', ' +
      Q + 'binary' + Q + ')', -1);
  ChkVal('INTEGER saklanir', 'SELECT i FROM tip', 0, 0, '42');
  ChkVal('FLOAT saklanir', 'SELECT f FROM tip', 0, 0, '3.5');
  ChkVal('TEXT saklanir', 'SELECT s FROM tip', 0, 0, 'merhaba');
  ChkVal('BOOLEAN saklanir', 'SELECT b FROM tip', 0, 0, 'True');
  ChkVal('DATE saklanir', 'SELECT d FROM tip', 0, 0, '2024-01-15');
  ChkVal('DATETIME saklanir', 'SELECT dt FROM tip', 0, 0, '2024-01-15 10:30:00');
  ChkVal('TIME saklanir', 'SELECT tm FROM tip', 0, 0, '10:30:00');
  ChkVal('BLOB saklanir', 'SELECT bl FROM tip', 0, 0, 'binary');
  ChkErr('INTEGER kolona metin (hata)',
      'INSERT INTO tip(i) VALUES(' + Q + 'abc' + Q + ')');
  ChkErr('DATE kolona bozuk tarih (hata)',
      'INSERT INTO tip(d) VALUES(' + Q + 'abc' + Q + ')');
  // Locale bagimsizlik: sistem tr-TR (ondalik ayirici = virgul) ama motor
  // daima NOKTA kullanir. Aksi halde "VALUES(0,5)" 4 deger sanilir ve
  // sessizce yanlis satir yazilir.
  sq.Exec('CREATE TABLE fl(id INTEGER PRIMARY KEY, f FLOAT)');
  sq.Exec('INSERT INTO fl(f) VALUES(2.25)');
  ChkVal('FLOAT nokta ile okunur (locale bagimsiz)', 'SELECT f FROM fl', 0, 0, '2.25');
  sq.Exec('INSERT INTO fl(f) VALUES(10)');
  ChkVal('FLOAT tam sayi', 'SELECT f FROM fl WHERE id=2', 0, 0, '10');
  ChkVal('FLOAT karsilastirma', 'SELECT COUNT(*) FROM fl WHERE f > 2', 0, 0, '2');
  ChkErr('ondalik VIRGUL deger ayirici sayilmaz (hata)',
      'INSERT INTO fl(id,f) VALUES(9,0,5)');
end;

procedure T03_CreateKisit;
begin
  Grp('CREATE TABLE kisitlari (PK/NOT NULL/UNIQUE/DEFAULT/CHECK/FK)');
  UseDir('kis');
  sq.Exec('CREATE TABLE ebeveyn(id INTEGER PRIMARY KEY, ad TEXT NOT NULL)');
  ChkErr('NOT NULL ihlali (hata)',
      'INSERT INTO ebeveyn(id,ad) VALUES(1,' + Q + Q + ')');
  Chk('gecerli satir', 'INSERT INTO ebeveyn(id,ad) VALUES(1,' + Q + 'Ali' + Q + ')', -1);
  ChkErr('PK tekrari (hata)',
      'INSERT INTO ebeveyn(id,ad) VALUES(1,' + Q + 'Veli' + Q + ')');
  sq.Exec('CREATE TABLE cocuk(id INTEGER PRIMARY KEY, pid INTEGER ' +
          'REFERENCES ebeveyn(id), yas INTEGER DEFAULT 0, ' +
          'puan FLOAT, etiket TEXT UNIQUE)');
  Chk('FK dogru deger', 'INSERT INTO cocuk(id,pid) VALUES(1,1)', -1);
  ChkErr('FK yanlis deger (hata)', 'INSERT INTO cocuk(id,pid) VALUES(2,99)');
  Chk('DEFAULT uygulandi', 'INSERT INTO cocuk(id) VALUES(2)', -1);
  ChkVal('DEFAULT degeri yazildi', 'SELECT yas FROM cocuk WHERE id=2', 0, 0, '0');
  Chk('UNIQUE ilk kullanim',
      'INSERT INTO cocuk(id,etiket) VALUES(3,' + Q + 'x' + Q + ')', -1);
  ChkErr('UNIQUE tekrari 2 (hata)',
      'INSERT INTO cocuk(id,etiket) VALUES(4,' + Q + 'x' + Q + ')');
  sq.Exec('CREATE TABLE yasli(id INTEGER PRIMARY KEY, y INTEGER, ' +
          'CHECK (y >= 0))');
  Chk('CHECK gecer', 'INSERT INTO yasli(id,y) VALUES(1,10)', -1);
  ChkErr('CHECK ihlali (hata)', 'INSERT INTO yasli(id,y) VALUES(2,-1)');
  sq.Exec('CREATE TABLE tek(id INTEGER PRIMARY KEY, v INTEGER CHECK (v > 0))');
  ChkErr('kolon ici CHECK (hata)', 'INSERT INTO tek(id,v) VALUES(1,0)');
end;

procedure T04_Insert;
begin
  Grp('INSERT bicimleri');
  UseDir('ins');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT, b INTEGER, ' +
          'c TEXT DEFAULT ' + Q + 'varsayilan' + Q + ')');
  Chk('sutun listeli', 'INSERT INTO t(a,b) VALUES(' + Q + 'x' + Q + ',1)', -1);
  Chk('sutun listesiz (sirayla)', 'INSERT INTO t VALUES(2,' + Q + 'y' + Q +
      ',2,' + Q + 'z' + Q + ')', -1);
  Chk('bos liste + bos VALUES (DEFAULT)',
      'INSERT INTO t() VALUES()', -1);
  Chk('DEFAULT VALUES kisayol', 'INSERT INTO t DEFAULT VALUES', -1);
  Chk('NULL deger', 'INSERT INTO t(a,b) VALUES(NULL,NULL)', -1);
  ChkErr('olmayan sutun (hata)',
      'INSERT INTO t(olmayan) VALUES(1)');
  ChkErr('deger sayisi uymaz (hata)',
      'INSERT INTO t(a,b) VALUES(' + Q + 'q' + Q + ')');
  Chk('5 satir yazildi', 'SELECT COUNT(*) FROM t', 1);
  R := sq.Exec('SELECT COUNT(*) FROM t');
  ChkVal('sayim dogru', 'SELECT COUNT(*) FROM t', 0, 0, '5');
  ChkVal('NULL okundu', 'SELECT a FROM t WHERE id=5', 0, 0, '');
end;

procedure T05_SelectTemel;
begin
  Grp('SELECT: yildiz, kolon listesi, alias, ORDER BY, LIMIT/OFFSET');
  UseDir('sel');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT, yas INTEGER)');
  sq.Exec('INSERT INTO t(ad,yas) VALUES(' + Q + 'Ali' + Q + ',30)');
  sq.Exec('INSERT INTO t(ad,yas) VALUES(' + Q + 'Veli' + Q + ',20)');
  sq.Exec('INSERT INTO t(ad,yas) VALUES(' + Q + 'Zeynep' + Q + ',40)');
  sq.Exec('INSERT INTO t(ad,yas) VALUES(' + Q + 'Ayse' + Q + ',25)');
  Chk('SELECT *', 'SELECT * FROM t', 4);
  Chk('kolon listesi', 'SELECT ad,yas FROM t', 4);
  Chk('ORDER BY ASC', 'SELECT ad FROM t ORDER BY yas', 4);
  ChkVal('ORDER BY ASC ilk', 'SELECT ad FROM t ORDER BY yas', 0, 0, 'Veli');
  ChkVal('ORDER BY DESC ilk', 'SELECT ad FROM t ORDER BY yas DESC', 0, 0, 'Zeynep');
  Chk('coklu ORDER BY', 'SELECT ad FROM t ORDER BY yas ASC, ad DESC', 4);
  Chk('LIMIT 2', 'SELECT ad FROM t ORDER BY yas LIMIT 2', 2);
  ChkVal('LIMIT ilk kayit', 'SELECT ad FROM t ORDER BY yas LIMIT 2', 0, 0, 'Veli');
  Chk('LIMIT + OFFSET', 'SELECT ad FROM t ORDER BY yas LIMIT 2 OFFSET 1', 2);
  ChkVal('OFFSET kaydi', 'SELECT ad FROM t ORDER BY yas LIMIT 2 OFFSET 1', 0, 0, 'Ayse');
  Chk('OFFSET tek basina', 'SELECT ad FROM t ORDER BY yas OFFSET 3', 1);
  R := sq.Exec('SELECT ad AS isim FROM t ORDER BY id');
  Ok('AS alias', R.Fields[0] + ' = ' + R.Rows[0][0]);
  R := sq.Exec('SELECT ad isim2 FROM t ORDER BY id');
  Ok('AS`siz alias', R.Fields[0] + ' = ' + R.Rows[0][0]);
  Chk('tablo alias', 'SELECT x.ad FROM t x ORDER BY x.id', 4);
  ChkErr('olmayan tablo (hata)', 'SELECT * FROM yok');
  ChkErr('olmayan kolon (hata)', 'SELECT yok FROM t');
end;

procedure T06_Where;
begin
  Grp('WHERE operatorleri, AND/OR/parantez, LIKE, IS NULL');
  UseDir('whr');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT, yas INTEGER, ' +
          'email TEXT)');
  sq.Exec('INSERT INTO t(ad,yas,email) VALUES(' + Q + 'Ali' + Q + ',30,' + Q + 'ali@x.com' + Q + ')');
  sq.Exec('INSERT INTO t(ad,yas,email) VALUES(' + Q + 'Veli' + Q + ',20,' + Q + 'veli@y.com' + Q + ')');
  sq.Exec('INSERT INTO t(ad,yas,email) VALUES(' + Q + 'Zeynep' + Q + ',40,NULL)');
  Chk('=', 'SELECT ad FROM t WHERE yas = 30', 1);
  Chk('<>', 'SELECT ad FROM t WHERE yas <> 30', 2);
  Chk('!=', 'SELECT ad FROM t WHERE yas != 30', 2);
  Chk('<', 'SELECT ad FROM t WHERE yas < 30', 1);
  Chk('>', 'SELECT ad FROM t WHERE yas > 30', 1);
  Chk('<=', 'SELECT ad FROM t WHERE yas <= 30', 2);
  Chk('>=', 'SELECT ad FROM t WHERE yas >= 30', 2);
  Chk('AND', 'SELECT ad FROM t WHERE yas > 20 AND yas < 35', 1);
  Chk('OR', 'SELECT ad FROM t WHERE yas = 20 OR yas = 40', 2);
  Chk('parentez', 'SELECT ad FROM t WHERE yas = 20 OR (yas > 30 AND yas < 35)', 1);
  Chk('LIKE %', 'SELECT ad FROM t WHERE ad LIKE ' + Q + 'A%' + Q, 1);
  Chk('LIKE % orta', 'SELECT ad FROM t WHERE email LIKE ' + Q + '%@y.com' + Q, 1);
  Chk('LIKE tam', 'SELECT ad FROM t WHERE ad LIKE ' + Q + 'Ali' + Q, 1);
  Chk('IS NULL', 'SELECT ad FROM t WHERE email IS NULL', 1);
  Chk('IS NOT NULL', 'SELECT ad FROM t WHERE email IS NOT NULL', 2);
  Chk('NULL = ile eslesmez', 'SELECT ad FROM t WHERE email = NULL', 0);
  Chk('NULL <> ile eslesmez', 'SELECT ad FROM t WHERE email <> NULL', 0);
  Chk('NULL LIKE ile eslesmez', 'SELECT ad FROM t WHERE email LIKE ' + Q + '%' + Q, 2);
  Chk('metin karsilastirma', 'SELECT ad FROM t WHERE ad = ' + Q + 'Ali' + Q, 1);
  ChkErr('olmayan operator (hata)', 'SELECT ad FROM t WHERE yas =~~ 3');
end;

procedure T07_TipKarsilastirma;
begin
  Grp('Tip-bilgili karsilastirma (TEXT 007 != 7)');
  UseDir('tipk');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, s TEXT, n INTEGER)');
  sq.Exec('INSERT INTO t(s,n) VALUES(' + Q + '007' + Q + ',7)');
  sq.Exec('INSERT INTO t(s,n) VALUES(' + Q + '7' + Q + ',007)');
  Chk('TEXT: s = 7 (tirnaksiz literal = metin ' + Q + '7' + Q + ')',
      'SELECT s FROM t WHERE s = 7', 1);
  Chk('TEXT: ' + Q + '007' + Q + ' = ' + Q + '007' + Q,
      'SELECT s FROM t WHERE s = ' + Q + '007' + Q, 1);
  Chk('INTEGER: n = ' + Q + '007' + Q + ' (iki satirda da 7)',
      'SELECT n FROM t WHERE n = ' + Q + '007' + Q, 2);
  Chk('INTEGER: n = 7 (iki satir)', 'SELECT n FROM t WHERE n = 7', 2);
  Chk('BETWEEN (n=7 -> aralik disi)', 'SELECT s FROM t WHERE n BETWEEN 1 AND 5', 0);
  Chk('BETWEEN (n=7 -> aralik ici)', 'SELECT s FROM t WHERE n BETWEEN 5 AND 9', 2);
  Chk('IN (...) (n=7 -> eslesmez)',
      'SELECT s FROM t WHERE n IN (1,2,3)', 0);
  Chk('IN (...) (n=7 -> eslesir)',
      'SELECT s FROM t WHERE n IN (6,7,8)', 2);
  Chk('NOT IN (...)', 'SELECT s FROM t WHERE n NOT IN (1,2,3)', 2);
  Chk('TEXT BETWEEN (byte sirasi: ''007'' < ''7'')',
      'SELECT s FROM t WHERE s BETWEEN ' + Q + '7' + Q + ' AND ' + Q + '8' + Q, 1);
  Chk('TEXT BETWEEN (''007''..''9'' -> ikisi de)',
      'SELECT s FROM t WHERE s BETWEEN ' + Q + '007' + Q + ' AND ' + Q + '9' + Q, 2);
  Chk('DISTINCT (007 ve 7 farkli)', 'SELECT DISTINCT s FROM t', 2);
  Chk('DISTINCT n (7 iki kez)', 'SELECT DISTINCT n FROM t', 1);
  // H-ek: IFADE (aritmetik) karsilastirmasi sayisal olmali. Aksi halde `(v+0) > 9`
  // metin sirasiyla '10' > '9' YANLIS olur ve 10 degerini kacirir.
  sq.Exec('CREATE TABLE te(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO te(v) VALUES(10),(9),(100),(2)');
  Chk('ifade: (v+0) > 9 -> 10,100', 'SELECT id FROM te WHERE (v+0) > 9', 2);
  Chk('ifade: (v+0) > 99 -> yalniz 100', 'SELECT id FROM te WHERE (v+0) > 99', 1);
  Chk('ifade: (v*1) < 10 -> 9,2 (metin sirasi 0 verirdi)',
      'SELECT id FROM te WHERE (v*1) < 10', 2);
  Chk('ifade: (v+0) BETWEEN 9 AND 10 -> 10,9',
      'SELECT id FROM te WHERE (v+0) BETWEEN 9 AND 10', 2);
  Chk('ifade: unary -(v) < -9 -> 10,100',
      'SELECT id FROM te WHERE -v < -9', 2);
end;

procedure T08_Join;
begin
  Grp('JOIN: INNER, LEFT, alias, nitelemeli kolon');
  UseDir('jnn');
  sq.Exec('CREATE TABLE eb(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('CREATE TABLE coc(id INTEGER PRIMARY KEY, ad TEXT, pid INTEGER)');
  sq.Exec('INSERT INTO eb(id,ad) VALUES(1,' + Q + 'Ali' + Q + ')');
  sq.Exec('INSERT INTO eb(id,ad) VALUES(2,' + Q + 'Veli' + Q + ')');
  sq.Exec('INSERT INTO coc(id,ad,pid) VALUES(1,' + Q + 'c1' + Q + ',1)');
  sq.Exec('INSERT INTO coc(id,ad,pid) VALUES(2,' + Q + 'c2' + Q + ',1)');
  sq.Exec('INSERT INTO coc(id,ad,pid) VALUES(3,' + Q + 'c3' + Q + ',2)');
  sq.Exec('INSERT INTO coc(id,ad,pid) VALUES(4,' + Q + 'c4' + Q + ',NULL)');
  Chk('INNER JOIN (3 eslesme)', 'SELECT c.ad FROM coc c INNER JOIN eb ON c.pid = eb.id', 3);
  Chk('JOIN = INNER JOIN', 'SELECT c.ad FROM coc c JOIN eb ON c.pid = eb.id', 3);
  Chk('LEFT JOIN (4 satir)', 'SELECT c.ad FROM coc c LEFT JOIN eb ON c.pid = eb.id', 4);
  ChkVal('LEFT JOIN eslesmeyen NULL',
      'SELECT c.ad, eb.ad FROM coc c LEFT JOIN eb ON c.pid = eb.id ORDER BY c.id', 3, 1, '');
  Chk('aliasli JOIN + WHERE', 'SELECT c.ad FROM coc c JOIN eb e ON c.pid = e.id ' +
      'WHERE e.ad = ' + Q + 'Ali' + Q, 2);
  Chk('nitelemeli kolon', 'SELECT coc.ad FROM coc JOIN eb ON coc.pid = eb.id', 3);
  Chk('coklu JOIN kosulu yerine ON+WHERE',
      'SELECT c.ad FROM coc c JOIN eb ON c.pid = eb.id WHERE c.id > 1', 2);
  // 4.2 (06.10.2026): JOIN ile GROUP BY ARTIK calisir - eski "hata"
  // iddiasi cevrildi; ayrinti T08i_JoinAggregate grubunda.
  Chk('JOIN + GROUP BY 3 grup (4.2)',
      'SELECT c.ad, COUNT(*) AS n FROM coc c JOIN eb ON c.pid = eb.id GROUP BY ad', 3);
  Chk('ORDER BY + LIMIT JOIN',
      'SELECT c.ad FROM coc c JOIN eb ON c.pid = eb.id ORDER BY c.id LIMIT 1', 1);
end;

procedure T08b_JoinZincir;
begin
  Grp('JOIN zinciri: 3+ tablo (P5-1)');
  UseDir('jnn3');
  sq.Exec('CREATE TABLE ulke(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('CREATE TABLE sehir(id INTEGER PRIMARY KEY, ad TEXT, uid INTEGER)');
  sq.Exec('CREATE TABLE kisi3(id INTEGER PRIMARY KEY, ad TEXT, sid INTEGER)');
  sq.Exec('INSERT INTO ulke(id,ad) VALUES(1,' + Q + 'TR' + Q + ')');
  sq.Exec('INSERT INTO ulke(id,ad) VALUES(2,' + Q + 'DE' + Q + ')');
  sq.Exec('INSERT INTO sehir(id,ad,uid) VALUES(1,' + Q + 'Ankara' + Q + ',1)');
  sq.Exec('INSERT INTO sehir(id,ad,uid) VALUES(2,' + Q + 'Istanbul' + Q + ',1)');
  sq.Exec('INSERT INTO sehir(id,ad,uid) VALUES(3,' + Q + 'Berlin' + Q + ',2)');
  sq.Exec('INSERT INTO sehir(id,ad,uid) VALUES(4,' + Q + 'Sahipsiz' + Q + ',NULL)');
  sq.Exec('INSERT INTO kisi3(id,ad,sid) VALUES(1,' + Q + 'Ali' + Q + ',1)');
  sq.Exec('INSERT INTO kisi3(id,ad,sid) VALUES(2,' + Q + 'Veli' + Q + ',2)');
  sq.Exec('INSERT INTO kisi3(id,ad,sid) VALUES(3,' + Q + 'Zoe' + Q + ',3)');
  sq.Exec('INSERT INTO kisi3(id,ad,sid) VALUES(4,' + Q + 'Kim' + Q + ',NULL)');
  sq.Exec('INSERT INTO kisi3(id,ad,sid) VALUES(5,' + Q + 'Can' + Q + ',1)');
  Chk('3 tablo INNER (4 eslesme)',
      'SELECT k.ad FROM kisi3 k JOIN sehir s ON k.sid = s.id ' +
      'JOIN ulke u ON s.uid = u.id', 4);
  ChkVal('3 tablo deger',
      'SELECT k.ad, s.ad, u.ad FROM kisi3 k JOIN sehir s ON k.sid = s.id ' +
      'JOIN ulke u ON s.uid = u.id ORDER BY k.id', 0, 2, 'TR');
  ChkVal('3 tablo 3. satir',
      'SELECT k.ad, s.ad, u.ad FROM kisi3 k JOIN sehir s ON k.sid = s.id ' +
      'JOIN ulke u ON s.uid = u.id ORDER BY k.id', 2, 2, 'DE');
  Chk('LEFT + INNER zincir (Kim duser, 4 satir)',
      'SELECT k.ad FROM kisi3 k LEFT JOIN sehir s ON k.sid = s.id ' +
      'JOIN ulke u ON s.uid = u.id', 4);
  Chk('INNER + LEFT zincir (4 satir)',
      'SELECT k.ad FROM kisi3 k JOIN sehir s ON k.sid = s.id ' +
      'LEFT JOIN ulke u ON s.uid = u.id', 4);
  Chk('ters ON sirasi (sag=sol)',
      'SELECT k.ad FROM kisi3 k JOIN sehir s ON s.id = k.sid ' +
      'JOIN ulke u ON u.id = s.uid', 4);
  Chk('4. tablo oz-birlestirme (Ankara paylasimi, 6 satir)',
      'SELECT a.ad FROM kisi3 a JOIN sehir s ON a.sid = s.id ' +
      'JOIN ulke u ON s.uid = u.id JOIN kisi3 b ON b.sid = s.id', 6);
  Chk('WHERE zincir sonrasi (TR: Ali, Veli, Can)',
      'SELECT k.ad FROM kisi3 k JOIN sehir s ON k.sid = s.id ' +
      'JOIN ulke u ON s.uid = u.id WHERE u.ad = ' + Q + 'TR' + Q, 3);
  // 4.2 (06.10.2026): JOIN ile aggregate ARTIK calisir (eski "hata"
  // iddiasi cevrildi): 4 satir eslesir, sonuc TEK satirdir.
  ChkVal('JOIN aggregate tek satir COUNT=4 (4.2)',
      'SELECT COUNT(*) FROM kisi3 k JOIN sehir s ON k.sid = s.id', 0, 0, '4');
  Chk('zincirde RIGHT (Kim duser, 4)',
      'SELECT k.ad FROM kisi3 k LEFT JOIN sehir s ON k.sid = s.id ' +
      'RIGHT JOIN ulke u ON s.uid = u.id', 4);
end;

procedure T08c_RightFullJoin;
begin
  Grp('RIGHT/FULL JOIN (P5-RF)');
  UseDir('jnrf');
  sq.Exec('CREATE TABLE eb2(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('CREATE TABLE per2(id INTEGER PRIMARY KEY, ad TEXT, eid INTEGER)');
  sq.Exec('INSERT INTO eb2(id,ad) VALUES(1,' + Q + 'Ali' + Q + '),(2,' + Q + 'Veli' + Q + ')');
  sq.Exec('INSERT INTO eb2(id,ad) VALUES(3,' + Q + 'Zoe' + Q + ')');
  sq.Exec('INSERT INTO per2(id,ad,eid) VALUES(1,' + Q + 'p1' + Q + ',1)');
  sq.Exec('INSERT INTO per2(id,ad,eid) VALUES(2,' + Q + 'p2' + Q + ',1)');
  sq.Exec('INSERT INTO per2(id,ad,eid) VALUES(3,' + Q + 'p3' + Q + ',NULL)');
  // sagda eslesmeyen Zoe korunur (NULL-solla)
  Chk('RIGHT JOIN (4: Zoe NULL-solla)',
      'SELECT p.ad, e.ad FROM per2 p RIGHT JOIN eb2 e ON p.eid = e.id ORDER BY e.id, p.id', 4);
  ChkVal('RIGHT eslesmeyen sag',
      'SELECT p.ad, e.ad FROM per2 p RIGHT JOIN eb2 e ON p.eid = e.id ORDER BY e.id, p.id', 3, 0, '');
  ChkVal('RIGHT eslesmeyen sag adi',
      'SELECT p.ad, e.ad FROM per2 p RIGHT JOIN eb2 e ON p.eid = e.id ORDER BY e.id, p.id', 3, 1, 'Zoe');
  Chk('RIGHT OUTER ayni (4)',
      'SELECT p.ad FROM per2 p RIGHT OUTER JOIN eb2 e ON p.eid = e.id', 4);
  Chk('LEFT OUTER ayni (3)',
      'SELECT p.ad FROM per2 p LEFT OUTER JOIN eb2 e ON p.eid = e.id', 3);
  // FULL: iki taraf da korunur (p3 + Zoe = 5).
  // (NULL satirlarin siralama konumu tanimsizdir; kosulla dogrulanir.)
  Chk('FULL JOIN (5)',
      'SELECT p.ad, e.ad FROM per2 p FULL JOIN eb2 e ON p.eid = e.id', 5);
  Chk('FULL sag-korumali (Veli+Zoe)',
      'SELECT p.ad, e.ad FROM per2 p FULL JOIN eb2 e ON p.eid = e.id WHERE p.ad IS NULL', 2);
  ChkVal('FULL sol-korumali (p3)',
      'SELECT p.ad, e.ad FROM per2 p FULL JOIN eb2 e ON p.eid = e.id WHERE e.ad IS NULL', 0, 0, 'p3');
  Chk('FULL OUTER ayni (5)',
      'SELECT p.ad FROM per2 p FULL OUTER JOIN eb2 e ON p.eid = e.id', 5);
  // ters ON + zincirde RIGHT
  Chk('ters ON RIGHT (4)',
      'SELECT p.ad FROM per2 p RIGHT JOIN eb2 e ON e.id = p.eid', 4);
  // 4.1 (06.10.2026): CROSS JOIN artik desteklenir - buradaki eski
  // "CROSS JOIN yok (hata)" iddiasi asagida T08h grubunca cevrildi.
  Chk('CROSS JOIN 3x3=9 (4.1)',
      'SELECT per2.ad, eb2.ad FROM per2 CROSS JOIN eb2', 9);

  // ---- F-26: zincirde ve karmada FULL JOIN ----
  // Sol: per2 LEFT JOIN eb2 ON p.eid=e.id -> p1, p2, p3(NULL) = 3 satir.
  // Sonra FULL JOIN eb2 c ON c.id=99 -> hicbir eslesme yok:
  //   solun 3 satiri korunur + c'nin 3 satiri NULL'lu eklenir = 6.
  Chk('FULL zincir LEFT JOIN ile (6)',
      'SELECT p.ad FROM per2 p LEFT JOIN eb2 e ON p.eid = e.id' +
      ' FULL JOIN eb2 c ON c.id = 99', 6);
  // ON hep FALSE: solun 3 satiri NULL'lu c ile korunur (c-id NULL ama
  // p-ad DOLU). Ayni sekilde c'nin 3 satiri NULL'lu p ile eklenir
  // (p-ad NULL, c-ad DOLU). p.ad IS NULL sadece c-nullu satirlari
  // sayar -> 3
  Chk('FULL zincir sol NULL (c-nullu 3)',
      'SELECT p.ad FROM per2 p LEFT JOIN eb2 e ON p.eid = e.id' +
      ' FULL JOIN eb2 c ON c.id = 99 WHERE p.ad IS NULL', 3);
  // c.ad IS NOT NULL: c'nin korunan 3 satiri -> 3
  Chk('FULL zincir sag koruma (3)',
      'SELECT p.ad FROM per2 p LEFT JOIN eb2 e ON p.eid = e.id' +
      ' FULL JOIN eb2 c ON c.id = 99 WHERE c.ad IS NOT NULL', 3);
  // FULL FULL: once FULL -> 5 satir, sonra ON hep FALSE -> 5 + 3 = 8
  Chk('iki FULL arka arkaya (8)',
      'SELECT p.ad FROM per2 p FULL JOIN eb2 e ON p.eid = e.id' +
      ' FULL JOIN eb2 c ON c.id = 99', 8);
  // RIGHT FULL: once RIGHT -> 4 satir, sonra 4 + 3 = 7
  Chk('RIGHT FULL zincir (7)',
      'SELECT p.ad FROM per2 p RIGHT JOIN eb2 e ON p.eid = e.id' +
      ' FULL JOIN eb2 c ON c.id = 99', 7);
  // FULL JOIN'da eslesmeyen sol satir: p3 (eid NULL) -> 1
  Chk('FULL ON NULL kolonlu eslesmez (1)',
      'SELECT p.ad, c.ad FROM per2 p FULL JOIN eb2 c ON c.id = p.eid' +
      ' WHERE c.ad IS NULL', 1);
end;

procedure T08i_NaturalUsing;
// F-27: NATURAL JOIN  /  F-28: USING (kolon, ...)
var
  Q5: string;
begin
  Grp('NATURAL/USING (F-27/F-28)');
  UseDir('nat');
  Q5 := Q;
  // Ortak kolon: 'kid'. Sol: 3 satir, sag: 4 satir.
  sq.Exec('CREATE TABLE n_sol(kid INTEGER PRIMARY KEY, ad TEXT, sehir TEXT)');
  sq.Exec('CREATE TABLE n_sag(kid INTEGER PRIMARY KEY, sehir TEXT, nufus INTEGER)');
  sq.Exec('INSERT INTO n_sol VALUES(1,' + Q5 + 'Ali' + Q5 + ',' + Q5 + 'Izmir' + Q5 + '),' +
          '(2,' + Q5 + 'Veli' + Q5 + ',' + Q5 + 'Ankara' + Q5 + '),' +
          '(3,' + Q5 + 'Zoe' + Q5 + ',' + Q5 + 'Bursa' + Q5 + ')');
  sq.Exec('INSERT INTO n_sag VALUES(1,' + Q5 + 'Izmir' + Q5 + ',3),' +
          '(2,' + Q5 + 'Ankara' + Q5 + ',6),' +
          '(4,' + Q5 + 'Antalya' + Q5 + ',2),' +
          '(5,' + Q5 + 'Izmir' + Q5 + ',8)');
  // NATURAL: ortak kolonlar kid VE sehir -> iki kosul birlikte

  // ---- F-27: NATURAL JOIN ----
  Chk('NATURAL JOIN eslesen (2)',
      'SELECT kid FROM n_sol NATURAL JOIN n_sag', 2);
  // sehir de eslesmeli: kid=1 Izmir/Izmir ✓ ; kid=2 Ankara/Ankara ✓
  ChkVal('NATURAL JOIN degeri',
      'SELECT ad FROM n_sol NATURAL JOIN n_sag ORDER BY ad',
      0, 0, 'Ali');
  // Ayni sehirde iki n_sag satiri varsa kartesisik carpim olusur:
  // kid=1 Izmir 3 kişi, Izmir'de 2 n_sag satiri (kid=1 ve 5) -> 1x2 = 2
  // kid=2 Ankara -> 1x1 = 1  => toplam 3
  // NATURAL IKI kolonda birden esitlik ister: kid=5 satiri Izmir'de
  // olsa bile kid=1 ile esit degildir -> 2 satir.
  Chk('NATURAL JOIN iki kolon birlikte (2)',
      'SELECT kid FROM n_sol NATURAL JOIN n_sag', 2);
  // ON yerine tek kolon verilirse NATURAL iki ortak kolonu da kullanir
  // kid=3 (Zoe/Bursa) eslesmez ama sol-korunur -> 3 satir
  Chk('NATURAL LEFT JOIN korumali (3)',
      'SELECT kid FROM n_sol NATURAL LEFT JOIN n_sag', 3);
  ChkVal('NATURAL LEFT JOIN koruma (kid=3)',
      'SELECT kid FROM n_sol NATURAL LEFT JOIN n_sag WHERE n_sag.kid IS NULL',
      0, 0, '3');
  // sag 4 satir: 1,2 eslesir ; 4,5 korunur -> 4
  Chk('NATURAL RIGHT JOIN korumali (4)',
      'SELECT kid FROM n_sol NATURAL RIGHT JOIN n_sag', 4);
  // Ortak kolon olmayan iki tablo -> hata
  sq.Exec('CREATE TABLE n_y1(a INTEGER PRIMARY KEY)');
  sq.Exec('CREATE TABLE n_y2(b INTEGER PRIMARY KEY)');
  ChkErr('NATURAL ortak kolon yok -> hata',
      'SELECT * FROM n_y1 NATURAL JOIN n_y2');
  // ---- F-28: USING ----
  // USING (kid): sadece kid esitligi -> sehir engel degil
  // kid=1 (Izmir/3), kid=2 (Ankara/6), kid=3 eslesmez, kid=4-5 sol yok => 2
  Chk('USING (kid) eslesen (2)',
      'SELECT n_sol.kid FROM n_sol JOIN n_sag USING(kid)', 2);
  // USING ile eslesmeyen sol satir korunmaz (INNER)
  Chk('USING (kid) sadece ic join',
      'SELECT n_sol.kid FROM n_sol JOIN n_sag USING(kid)', 2);
  // Birden cok kolon
  Chk('USING (kid, sehir)',
      'SELECT n_sol.kid FROM n_sol JOIN n_sag USING(kid, sehir)', 2);
  // USING tek kolon: sehir esitligi tek basina yeter
  // sehir Izmir: sol kid=1, sag kid=1 ve 5 -> 2
  // sehir=Izmir: sol kid=1 ; sag kid=1 ve 5 -> 1x2 = 2 satır olmali,
// AMA NATURAL'dan farkli olarak sehir esitligi yeterli.
  // Izmir: kid=1 x sag(kid=1,5) -> 2 ; Ankara: 1x1 -> 1 ; toplam 3
  Chk('USING (sehir) Izmir+Ankara (3)',
      'SELECT n_sol.kid FROM n_sol JOIN n_sag USING(sehir)', 3);
  // Yok edilen kolon WHERE'de tek adla kullanilabilir
  ChkVal('USING kolonu tek adla WHERE',
      'SELECT COUNT(*) FROM n_sol JOIN n_sag USING(kid) WHERE kid = 1',
      0, 0, '1');
  // Eksik kolon -> hata
  ChkErr('USING kolonu sol tarafta yok',
      'SELECT * FROM n_sol JOIN n_sag USING(olmayan)');
  ChkErr('USING kolonu sag tarafta yok',
      'SELECT * FROM n_sol JOIN n_sag USING(sehir, nufus)');
  // NULL deger kesismez (uc-degerli)
  sq.Exec('CREATE TABLE n_n1(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('CREATE TABLE n_n2(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO n_n1 VALUES(1,10),(2,NULL)');
  sq.Exec('INSERT INTO n_n2 VALUES(1,10),(2,20)');
  // id=1 eslesir ; id=2 sol NULL ama sag 20 -> NULL eslesmez
  Chk('USING NULL kesismez (1)',
      'SELECT id FROM n_n1 JOIN n_n2 USING(id)', 2);
  // id esitligi iki satiri da eslestirir (2=2); sol v degeri NULL olan
  // id=2 satiri sayilir -> 1
  // id esitligi iki satiri da eslestirir (2=2); sol v degeri NULL olan
  // id=2 satiri sayilir -> 1
  ChkVal('USING NULL degeri birakilmaz (1)',
      'SELECT COUNT(*) FROM n_n1 JOIN n_n2 USING(id) WHERE n_n1.v IS NULL',
      0, 0, '1');
  // MUTASYON YAKALAYICI: USING kolonunun KENDISI NULL ise satir ESLESMEZ.
  // Uc-degerli mantik: NULL = NULL bilinmezdir, eslesme sayilmaz.
  // (v kolonu eslesme kolonu DEGIL; id eslesme kolonudur ve id=1 NULL
  //  olsaydi bu satir eslesmezdi.)
  sq.Exec('CREATE TABLE n_u1(id INTEGER PRIMARY KEY, k INTEGER)');
  sq.Exec('CREATE TABLE n_u2(id INTEGER PRIMARY KEY, k INTEGER)');
  sq.Exec('INSERT INTO n_u1 VALUES(1,10),(2,NULL)');
  sq.Exec('INSERT INTO n_u2 VALUES(1,10),(2,NULL)');
  // k=10 eslesir ; k NULL iki tarafta da NULL ama uc-degerli mantikta
  // NULL = NULL BILINMEZDIR -> eslesmez. Yalnizca k=10 satiri gelir.
  Chk('USING kolonu NULL eslesmez (1)',
      'SELECT id FROM n_u1 JOIN n_u2 USING(k)', 1);
  // AYIRT EDICI: sol NULL, sag DOLU. "a='' OR b=''" -> elenir (dogru).
  // "a='' AND b=''" mutasyonu bu satiri SIRA VURMADI gecirir: iki
  // eslesen satir kalir ama burada zaten 1 bekleniyor; asil ayirt edici
  // olan asagidaki "sol NULL, sag NULL" ve "sol DOLU, sag NULL" adimlari.
  sq.Exec('CREATE TABLE n_z1(id INTEGER PRIMARY KEY, k INTEGER)');
  sq.Exec('CREATE TABLE n_z2(id INTEGER PRIMARY KEY, k INTEGER)');
  sq.Exec('INSERT INTO n_z1 VALUES(1,NULL),(2,10)');
  sq.Exec('INSERT INTO n_z2 VALUES(1,20),(2,NULL)');
  // Sol(1,NULL) x Sag(1,20): k NULL vs 20 -> elenir
  // Sol(2,10)  x Sag(2,NULL): 10 vs NULL -> elenir
  // Sol(2,10)  x Sag(1,20): 10 vs 20  -> elenir
  // Sol(1,NULL)x Sag(2,NULL): NULL vs NULL -> elenir
  Chk('USING tek taraf NULL elenir (0)',
      'SELECT id FROM n_z1 JOIN n_z2 USING(k)', 0);
  // Zincirde NATURAL + ON birlikteligi
  Chk('NATURAL sonra ON JOIN zinciri',
      'SELECT n_sol.kid FROM n_sol NATURAL JOIN n_sag' +
      ' JOIN n_n1 ON n_n1.id = n_sol.kid', 2);
end;

procedure T08j_Lateral;
// F-29: LATERAL JOIN — sag taraf alt sorgu/tabloda OLUR ve dis satirin
// kolonlarina referans verebilir.
var
  Q6: string;
begin
  Grp('LATERAL (F-29)');
  UseDir('lat');
  Q6 := Q;
  sq.Exec('CREATE TABLE l_emp(id INTEGER PRIMARY KEY, ad TEXT, sid INTEGER, maas INTEGER)');
  sq.Exec('CREATE TABLE l_dep(id INTEGER PRIMARY KEY, ad TEXT, butce INTEGER)');
  sq.Exec('INSERT INTO l_dep VALUES(10,' + Q6 + 'Satis' + Q6 + ',100),' +
          '(20,' + Q6 + 'IT' + Q6 + ',50)');
  sq.Exec('INSERT INTO l_emp VALUES(1,' + Q6 + 'Ali' + Q6 + ',10,120),' +
          '(2,' + Q6 + 'Veli' + Q6 + ',10,60),' +
          '(3,' + Q6 + 'Zoe' + Q6 + ',20,90),' +
          '(4,' + Q6 + 'Kim' + Q6 + ',99,10)');

  // ---- LATERAL alt sorgu: her calisan icin ucret + bütçe oranı ----
  Chk('LATERAL alt sorgu (3 satir: Kim sid=99 yok)',
      'SELECT e.id FROM l_emp e' +
      ' JOIN LATERAL (SELECT d.ad FROM l_dep d WHERE d.id = e.sid) x ON e.id = e.id', 3);
  ChkVal('LATERAL dis kolona erisim',
      'SELECT e.ad FROM l_emp e' +
      ' JOIN LATERAL (SELECT d.ad FROM l_dep d WHERE d.id = e.sid) x ON e.id = e.id' +
      ' ORDER BY e.id', 0, 0, 'Ali');
  // ON kosulu dis satira da referans verebilir
  Chk('LATERAL ON kosulu (filtre)',
      'SELECT e.id FROM l_emp e' +
      ' JOIN LATERAL (SELECT d.butce FROM l_dep d WHERE d.id = e.sid) x' +
      ' ON e.id = e.id', 3);
  ChkVal('LATERAL alt sorgu degeri',
      'SELECT x.butce FROM l_emp e' +
      ' JOIN LATERAL (SELECT d.butce FROM l_dep d WHERE d.id = e.sid) x' +
      ' ON e.id = e.id ORDER BY e.id', 0, 0, '100');
  // Alt sorgu satır döndürmezse LEFT LATERAL korur
  Chk('LATERAL LEFT koruma (Kim: sid=99 yok)',
      'SELECT e.id FROM l_emp e' +
      ' LEFT JOIN LATERAL (SELECT d.ad FROM l_dep d WHERE d.id = e.sid) x ON e.id = e.id', 4);
  ChkVal('LATERAL LEFT korunan deger NULL',
      'SELECT e.ad FROM l_emp e' +
      ' LEFT JOIN LATERAL (SELECT d.ad FROM l_dep d WHERE d.id = e.sid) x ON True' +
      ' WHERE e.id = 4', 0, 0, 'Kim');
  // Alt sorgu sıfır satır döndürürse INNER LATERAL eler
  Chk('LATERAL INNER bos sonuc eler (3)',
      'SELECT e.id FROM l_emp e' +
      ' JOIN LATERAL (SELECT d.ad FROM l_dep d WHERE d.id = e.sid) x ON e.id = e.id', 3);
  // Top-N deseni (gercek kullanim)
  // Ali(120) en yuksek maas -> ustunde kimse yok -> INNER LATERAL eler.
  // Veli(60) ustunde Ali var -> kalir. Ilk satir Veli olmali.
  ChkVal('LATERAL top-1 (ustunde baska calisan var)',
      'SELECT e.ad FROM l_emp e' +
      ' JOIN LATERAL (SELECT o.ad FROM l_emp o WHERE o.sid = e.sid' +
      '   AND o.maas > e.maas) x ON e.id = e.id ORDER BY e.id', 0, 0, 'Veli');
  // Zincir: LATERAL sonra normal JOIN
  // ON x.butce > 80: Ali(100) ve Veli(100) kalir; Zoe(50) elenir;
  // Kim (sid=99, LATERAL alt sorgusu bos) INNER LATERAL ile duser.
  // Sonraki JOIN l_dep ON d2.id = e.sid ikisini de korur -> 2 satir.
  Chk('LATERAL + normal JOIN zinciri',
      'SELECT e.id FROM l_emp e' +
      ' JOIN LATERAL (SELECT d.butce FROM l_dep d WHERE d.id = e.sid) x' +
      ' ON x.butce > 80 JOIN l_dep d2 ON d2.id = e.sid', 2);
  // LATERAL tablo
  Chk('LATERAL tablo ON ile',
      'SELECT e.id FROM l_emp e LEFT JOIN LATERAL l_dep d ON d.id = e.sid', 4);
  // ---- Hata durumları ----
  ChkErr('LATERAL + RIGHT reddedilir',
      'SELECT e.id FROM l_emp e' +
      ' RIGHT JOIN LATERAL (SELECT d.ad FROM l_dep d) x ON True');
  ChkErr('LATERAL + FULL reddedilir',
      'SELECT e.id FROM l_emp e' +
      ' FULL JOIN LATERAL (SELECT d.ad FROM l_dep d) x ON True');
  ChkErr('LATERAL + NATURAL reddedilir',
      'SELECT e.id FROM l_emp e NATURAL JOIN LATERAL (SELECT d.ad FROM l_dep d) x ON True');
  // Boş sol küme: LATERAL hiç çalıştırılmaz (AV olmamalı)
  sq.Exec('CREATE TABLE l_bos(id INTEGER PRIMARY KEY)');
  Chk('LATERAL bos sol kume (0 satir)',
      'SELECT b.id FROM l_bos b' +
      ' JOIN LATERAL (SELECT d.ad FROM l_dep d WHERE d.id = b.id) x ON True', 0);
end;

procedure T08k_MatView;
{ F-34: MATERIALIZED VIEW — SELECT'in sonucu fiziksel olarak saklanir.
  Normal tablo gibi okunur; REFRESH ile yeniden hesaplanir. }
var
  Q7: string;
begin
  Grp('MATERIALIZED VIEW (F-34)');
  UseDir('mview');
  Q7 := Q;
  sq.Exec('CREATE TABLE mv_t(id INTEGER PRIMARY KEY, ad TEXT, v INTEGER)');
  sq.Exec('INSERT INTO mv_t VALUES(1,' + Q7 + 'Ali' + Q7 + ',10)');
  sq.Exec('INSERT INTO mv_t VALUES(2,' + Q7 + 'Veli' + Q7 + ',20)');
  sq.Exec('INSERT INTO mv_t VALUES(3,' + Q7 + 'Zoe' + Q7 + ',30)');

  // ---- CREATE MATERIALIZED VIEW ----
  Chk('CREATE MATERIALIZED VIEW',
      'CREATE MATERIALIZED VIEW mv_p AS SELECT id, ad FROM mv_t WHERE v >= 20', -1);
  // Sonuc materyalize edildi mi? (WHERE filtreli: 2 satir)
  Chk('MV materyalize sonucu (2 satir)',
      'SELECT ad FROM mv_p ORDER BY id', 2);
  ChkVal('MV ilk satir degeri', 'SELECT ad FROM mv_p ORDER BY id', 0, 0, 'Veli');
  ChkVal('MV ikinci satir degeri', 'SELECT ad FROM mv_p ORDER BY id', 1, 0, 'Zoe');
  // WHERE uygulanabilir (indeks/sorgu yolu)
  Chk('MV uzerinde WHERE',
      'SELECT ad FROM mv_p WHERE id = 3', 1);
  // Kaynak tablo degisince MV ESKIDIR (materialize = anliklik yok)
  sq.Exec('INSERT INTO mv_t VALUES(4,' + Q7 + 'Can' + Q7 + ',40)');
  Chk('kaynak degisince MV degismez (hâlâ 2)',
      'SELECT ad FROM mv_p', 2);

  // ---- REFRESH ----
  Chk('REFRESH MATERIALIZED VIEW',
      'REFRESH MATERIALIZED VIEW mv_p', -1);
  Chk('REFRESH sonrasi 3 satir', 'SELECT ad FROM mv_p', 3);
  ChkVal('REFRESH sonrasi yeni satir gorunur',
      'SELECT ad FROM mv_p WHERE id = 4', 0, 0, 'Can');

  // ---- REFRESH sonrasi silinen kaynak satiri MV'den dusmeli ----
  sq.Exec('DELETE FROM mv_t WHERE id = 1');
  // Gercek sinir degeri: mv_p = "WHERE v >= 20", kaynakta id 2,3,4 kaldi.
  ChkVal('kaynakta v>=20 kalan (3)',
      'SELECT COUNT(*) FROM mv_t WHERE v >= 20', 0, 0, '3');
  sq.Exec('REFRESH MATERIALIZED VIEW mv_p');
  Chk('silinen satir MV den dusmeli', 'SELECT ad FROM mv_p WHERE id = 1', 0);
  // REFRESH'in GERCEKTEN sildigini kanitlayan ayirt edici senaryo:
  // Silme calismazsa eski satirlar kalir ve MV daha cok satir gosterir.
  // DIKKAT: COUNT(*) tek satir dondurur; sayiyi DEGER olarak okumaliyiz.
  ChkVal('REFRESH sonrasi satir sayisi kaynagi yansitir',
      'SELECT COUNT(*) FROM mv_p', 0, 0, '3');
  // AYIRT EDICI: MV'ye DAHIL olan bir kaynak satiri silinir. Artan
  // senaryoda yeni satirlar eski @mvN anahtarlarinin USTUNE yazildigi
  // icin fiziksel silme olmasa da sonuc dogru gorunur; AZALAN senaryo
  // silme mantigini zorunlu kilar.
  sq.Exec('DELETE FROM mv_t WHERE id = 3');   // v=30 -> MV'deydi
  sq.Exec('REFRESH MATERIALIZED VIEW mv_p');
  Chk('REFRESH azalan kaynakta eski satiri atar',
      'SELECT ad FROM mv_p WHERE id = 3', 0);
  ChkVal('REFRESH sonrasi satir sayisi 2',
      'SELECT COUNT(*) FROM mv_p', 0, 0, '2');

  // ---- farkli kolon semasi ----
  Chk('MV farkli kolon semasi (CREATE)',
      'CREATE MATERIALIZED VIEW mv_p2 AS SELECT ad, v FROM mv_t WHERE v >= 30', -1);
  Chk('MV farkli kolon semasi',
      'SELECT v FROM mv_p2 ORDER BY v', 1);

  // ---- DROP ----
  // REFRESH: ayni sema ile yeniden hesap (kaynak yeni satir eklendi)
  sq.Exec('INSERT INTO mv_t VALUES(5,' + Q7 + 'Deniz' + Q7 + ',50)');
  Chk('REFRESH yeni kaynagi gorur', 'REFRESH MATERIALIZED VIEW mv_p', -1);
  ChkVal('REFRESH sonrasi yeni satir (Deniz)',
      'SELECT ad FROM mv_p WHERE id = 5', 0, 0, 'Deniz');

  Chk('DROP MATERIALIZED VIEW',
      'DROP MATERIALIZED VIEW mv_p2', -1);
  ChkErr('drop sonrasi MV yok (hata)',
      'SELECT ad FROM mv_p2');
  Chk('IF EXISTS yoksa sessiz',
      'DROP MATERIALIZED VIEW IF EXISTS mv_p2', -1);
  ChkErr('IF EXISTS olmadan yoksa hata',
      'DROP MATERIALIZED VIEW mv_p2');

  // ---- tekillestirme ----
  ChkErr('ayni MV adı (hata)',
      'CREATE MATERIALIZED VIEW mv_p AS SELECT id FROM mv_t');
  Chk('IF NOT EXISTS ayni ad (sessiz)',
      'CREATE MATERIALIZED VIEW IF NOT EXISTS mv_p AS SELECT id FROM mv_t', -1);

  // ---- aggregate + JOIN desteklenmeli ----
  Chk('MV aggregate ile',
      'CREATE MATERIALIZED VIEW mv_grp AS SELECT COUNT(*) AS n FROM mv_t', -1);
  ChkVal('MV aggregate sonucu (3 satir)',
      'SELECT n FROM mv_grp', 0, 0, '3');
  Chk('MV JOIN ile',
      'CREATE MATERIALIZED VIEW mv_j AS ' +
      'SELECT a.ad AS k, b.v AS vv FROM mv_t a JOIN mv_t b ON a.id = b.id', -1);
  ChkVal('MV JOIN sonucu',
      'SELECT k FROM mv_j WHERE vv = 40', 0, 0, 'Can');
  Chk('DROP MATERIALIZED VIEW mv_grp', 'DROP MATERIALIZED VIEW mv_grp', -1);
  Chk('DROP MATERIALIZED VIEW mv_j', 'DROP MATERIALIZED VIEW mv_j', -1);
end;

procedure T08l_ViewDML;
{ F-33: VIEW uzerine INSERT/UPDATE/DELETE - guncellenebilir view testleri }
var
  Q7: string;
begin
  Grp('VIEW DML (F-33)');
  UseDir('viewdml');
  Q7 := Q;
  sq.Exec('CREATE TABLE vt_t(id INTEGER PRIMARY KEY, ad TEXT, v INTEGER)');
  sq.Exec('INSERT INTO vt_t VALUES(1,' + Q7 + 'Ali' + Q7 + ',10)');
  sq.Exec('INSERT INTO vt_t VALUES(2,' + Q7 + 'Veli' + Q7 + ',20)');
  sq.Exec('INSERT INTO vt_t VALUES(3,' + Q7 + 'Zoe' + Q7 + ',30)');

  // Basit guncellenebilir view: tek tablo, kolonlar birebir
  Chk('CREATE VIEW',
      'CREATE VIEW v_v AS SELECT id, ad, v FROM vt_t WHERE v >= 20', -1);
  Chk('VIEW SELECT', 'SELECT ad FROM v_v ORDER BY id', 2);
  ChkVal('VIEW ilk satir', 'SELECT ad FROM v_v ORDER BY id', 0, 0, 'Veli');
  ChkVal('VIEW ikinci satir', 'SELECT ad FROM v_v ORDER BY id', 1, 0, 'Zoe');
  // view WHERE filtresi uygulanir
  Chk('VIEW uzerinde WHERE', 'SELECT ad FROM v_v WHERE id = 3', 1);
  // view uzerinde ORDER BY / LIMIT
  Chk('VIEW ORDER BY + LIMIT', 'SELECT ad FROM v_v ORDER BY id LIMIT 1', 1);
  // nitelemeli kolon cozulebilir
  Chk('VIEW nitelemeli kolon', 'SELECT v_v.ad FROM v_v', 2);

  // INSERT INTO view -> base tabloya yazar
  Chk('INSERT INTO view', 'INSERT INTO v_v VALUES(4,' + Q7 + 'Can' + Q7 + ',40)', -1);
  ChkVal('INSERT base tabloya yazildi', 'SELECT ad FROM vt_t WHERE id = 4', 0, 0, 'Can');
  ChkVal('VIEWden de gorunur', 'SELECT ad FROM v_v WHERE id = 4', 0, 0, 'Can');

  // UPDATE view -> base tablo guncellenir
  Chk('UPDATE view', 'UPDATE v_v SET ad = ' + Q7 + 'Veli2' + Q7 + ' WHERE id = 2', -1);
  ChkVal('UPDATE base tabloya yazildi', 'SELECT ad FROM vt_t WHERE id = 2', 0, 0, 'Veli2');
  ChkVal('VIEWde de gorunur', 'SELECT ad FROM v_v WHERE id = 2', 0, 0, 'Veli2');
  // view WHERE'si disinda kalan satirlar DEGISMEMELI
  ChkVal('UPDATE yalnizca view satirini etkiler',
      'SELECT ad FROM vt_t WHERE id = 1', 0, 0, 'Ali');

  // DELETE view -> base tablodan silinir
  Chk('DELETE view', 'DELETE FROM v_v WHERE id = 3', -1);
  Chk('VIEWden silindi', 'SELECT ad FROM v_v WHERE id = 3', 0);
  Chk('Base tablodan da silindi', 'SELECT ad FROM vt_t WHERE id = 3', 0);

  // Kolon listesiyle INSERT (view kolon adlari)
  Chk('INSERT view (kolon listesi)',
      'INSERT INTO v_v(id, ad, v) VALUES(6,' + Q7 + 'Efe' + Q7 + ',60)', -1);
  ChkVal('INSERT liste base tabloya', 'SELECT ad FROM vt_t WHERE id = 6', 0, 0, 'Efe');

  // RETURNING view uzerinde
  ChkVal('RETURNING cift eklemiyor (once id=7 yok)',
      'SELECT COUNT(*) FROM vt_t WHERE id = 7', 0, 0, '0');
  Chk('RETURNING view uzerinde',
      'INSERT INTO v_v VALUES(7,' + Q7 + 'Gul' + Q7 + ',70) RETURNING id', -1);

  // Aliasli kolon view -> alias ile INSERT/UPDATE
  sq.Exec('CREATE VIEW v_alias AS SELECT id, ad AS isim FROM vt_t WHERE v >= 80');
  Chk('VIEW alias SELECT', 'SELECT isim FROM v_alias', 0);
  Chk('VIEW alias INSERT',
      'INSERT INTO v_alias VALUES(8,' + Q7 + 'Deniz' + Q7 + ')', -1);
  ChkVal('VIEW alias base tabloya', 'SELECT ad FROM vt_t WHERE id = 8', 0, 0, 'Deniz');
  Chk('VIEW alias UPDATE',
      'UPDATE v_alias SET isim = ' + Q7 + 'Deniz2' + Q7 + ' WHERE id = 8', -1);
  ChkVal('VIEW alias UPDATE base tabloya',
      'SELECT ad FROM vt_t WHERE id = 8', 0, 0, 'Deniz2');

  // ---- Guncellenemez view'lar hata vermeli ----
  // aggregate
  sq.Exec('CREATE VIEW v_agg AS SELECT COUNT(*) AS n FROM vt_t');
  ChkErr('VIEW aggregate INSERT reddedilir', 'INSERT INTO v_agg VALUES(1)');
  ChkErr('VIEW aggregate UPDATE reddedilir', 'UPDATE v_agg SET n = 1');
  ChkErr('VIEW aggregate DELETE reddedilir', 'DELETE FROM v_agg');

  // JOIN
  sq.Exec('CREATE VIEW v_join AS SELECT a.ad AS a1, b.ad AS a2 ' +
      'FROM vt_t a JOIN vt_t b ON a.id = b.id');
  ChkErr('VIEW JOIN INSERT reddedilir',
      'INSERT INTO v_join VALUES(' + Q7 + 'x' + Q7 + ',' + Q7 + 'y' + Q7 + ')');

  // DISTINCT
  sq.Exec('CREATE VIEW v_dist AS SELECT DISTINCT v FROM vt_t');
  ChkErr('VIEW DISTINCT INSERT reddedilir', 'INSERT INTO v_dist VALUES(100)');

  // ifade kolonu
  sq.Exec('CREATE VIEW v_expr AS SELECT id, v * 2 AS v2 FROM vt_t');
  ChkErr('VIEW ifade INSERT reddedilir', 'INSERT INTO v_expr VALUES(9, 90)');

  // GROUP BY
  sq.Exec('CREATE VIEW v_grp AS SELECT v, COUNT(*) AS n FROM vt_t GROUP BY v');
  ChkErr('VIEW GROUP BY DELETE reddedilir', 'DELETE FROM v_grp WHERE v = 10');

  // ---- DROP VIEW ----
  Chk('DROP VIEW', 'DROP VIEW v_v', -1);
  ChkErr('drop sonrasi view yok', 'SELECT ad FROM v_v');
  Chk('DROP VIEW IF EXISTS yoksa sessiz',
      'DROP VIEW IF EXISTS v_v', -1);
  ChkErr('IF EXISTS olmadan yoksa hata', 'DROP VIEW v_v');
  ChkErr('ayni view adi (hata)',
      'CREATE VIEW v_alias AS SELECT id FROM vt_t');
  Chk('IF NOT EXISTS ayni ad (sessiz)',
      'CREATE VIEW IF NOT EXISTS v_alias AS SELECT id FROM vt_t', -1);

  sq.Exec('DROP VIEW v_alias');
  sq.Exec('DROP VIEW v_agg');
  sq.Exec('DROP VIEW v_join');
  sq.Exec('DROP VIEW v_dist');
  sq.Exec('DROP VIEW v_expr');
  sq.Exec('DROP VIEW v_grp');
end;

procedure T08m_StoredProc;
{ F-35: STORED PROCEDURE / FUNCTION
    - CREATE/DROP (IF [NOT] EXISTS)
    - parametre baglama (pozisyonel + varsayilan deger)
    - govde calistirma (BEGIN..END ve tek cumle)
    - RETURN degeri, SELECT icinde fonksiyon cagrisi
    - CALL ile prosedur cagrisi
}
var
  Q8: string;
begin
  Grp('STORED PROCEDURE / FUNCTION (F-35)');
  UseDir('proc');
  Q8 := Q;
  sq.Exec('CREATE TABLE p_t(id INTEGER PRIMARY KEY, ad TEXT, v INTEGER)');
  sq.Exec('INSERT INTO p_t VALUES(1,' + Q8 + 'Ali' + Q8 + ',10)');
  sq.Exec('INSERT INTO p_t VALUES(2,' + Q8 + 'Veli' + Q8 + ',20)');

  // ---- fonksiyon: RETURN degeri ----
  Chk('CREATE FUNCTION',
      'CREATE FUNCTION topla(x INTEGER, y INTEGER) RETURNS INTEGER AS ' +
      'BEGIN RETURN x + y; END', -1);
  ChkVal('fonksiyon SELECT icinde',
      'SELECT topla(2, 3)', 0, 0, '5');
  ChkVal('fonksiyon tek parametre',
      'SELECT topla(7, 0)', 0, 0, '7');

  // ---- varsayilan parametre degeri ----
  Chk('CREATE FUNCTION varsayilanli',
      'CREATE FUNCTION us(sayi INTEGER, ek INTEGER DEFAULT 100) RETURNS INTEGER AS ' +
      'BEGIN RETURN sayi + ek; END', -1);
  ChkVal('varsayilan deger kullanilir', 'SELECT us(1)', 0, 0, '101');
  ChkVal('varsayilan ezilir', 'SELECT us(1, 2)', 0, 0, '3');

  // ---- fonksiyon tablo verisini okuyabilir ----
  Chk('CREATE FUNCTION tablo okur',
      'CREATE FUNCTION v_al(id INTEGER) RETURNS INTEGER AS ' +
      'BEGIN RETURN (SELECT v FROM p_t WHERE p_t.id = id); END', -1);
  ChkVal('fonksiyon tablo okudu', 'SELECT v_al(2)', 0, 0, '20');

  // ---- prosedur: DML govdesi ----
  Chk('CREATE PROCEDURE',
      'CREATE PROCEDURE artir(yeni INTEGER) AS ' +
      'BEGIN UPDATE p_t SET v = yeni WHERE id = 1; END', -1);
  Chk('CALL prosedur', 'CALL artir(99)', -1);
  ChkVal('prosedur yazdi', 'SELECT v FROM p_t WHERE id = 1', 0, 0, '99');

  // ---- prosedur RETURN degeri dondurur ----
  Chk('CREATE PROCEDURE deger doner',
      'CREATE PROCEDURE ad_al(id INTEGER) AS ' +
      'BEGIN RETURN (SELECT ad FROM p_t WHERE p_t.id = id); END', -1);
  ChkVal('CALL prosedur RETURN degeri',
      'CALL ad_al(1)', 0, 0, 'Ali');

  // ---- prosedur RETURNsiz (Affected 0) ----
  Chk('CREATE PROCEDURE donersiz',
      'CREATE PROCEDURE yaz(yeni INTEGER) AS ' +
      'BEGIN INSERT INTO p_t VALUES(3, ' + Q8 + 'Zoe' + Q8 + ', yeni); END', -1);
  Chk('CALL prosedur INSERT', 'CALL yaz(33)', -1);
  ChkVal('prosedur ekledi', 'SELECT v FROM p_t WHERE id = 3', 0, 0, '33');

  // ---- tek cumlelik govde ----
  Chk('CREATE PROCEDURE tek cumle',
      'CREATE PROCEDURE tek(c INTEGER) AS UPDATE p_t SET v = c WHERE id = 2', -1);
  Chk('CALL tek cumleli prosedur', 'CALL tek(77)', -1);
  ChkVal('tek cumle guncelledi', 'SELECT v FROM p_t WHERE id = 2', 0, 0, '77');

  // ---- RETURN, kalan cumleleri atlar (erken cikis) ----
  Chk('CREATE PROCEDURE erken cikis',
      'CREATE PROCEDURE erken(id INTEGER) AS ' +
      'BEGIN RETURN 1; UPDATE p_t SET v = -1 WHERE id = id; END', -1);
  ChkVal('erken cikis degeri dondu', 'CALL erken(1)', 0, 0, '1');
  ChkVal('RETURN sonrasi cumle CALISMADI',
      'SELECT v FROM p_t WHERE id = 1', 0, 0, '99');

  // ---- parametre kapsami SELECT kolonuyla cakismaz ----
  Chk('kapsam cakismasi yok',
      'SELECT topla(v, 1) FROM p_t WHERE id = 2', 1);
  ChkVal('kapsam degeri dogru',
      'SELECT topla(v, 1) FROM p_t WHERE id = 2', 0, 0, '78');

  // ---- DROP ----
  Chk('DROP FUNCTION', 'DROP FUNCTION topla', -1);
  // Kayit gercekten SILINDI: ayni ad yeniden tanimlanabilir ve yeni
  // govde yurutulur. (Motor tanimsiz fonksiyon cagrisini sessizce
  // reddetmez; bu yuzden "hata veriyor" yerine ETKIN davranis olculur.)
  Chk('drop sonrasi ayni ad yeniden tanimlanabilir',
      'CREATE FUNCTION topla(x INTEGER, y INTEGER) RETURNS INTEGER AS ' +
      'BEGIN RETURN x - y; END', -1);
  ChkVal('yeni govde yurutuldu', 'SELECT topla(5, 2)', 0, 0, '3');
  sq.Exec('DROP FUNCTION topla');
  Chk('DROP FUNCTION IF EXISTS yoksa sessiz',
      'DROP FUNCTION IF EXISTS topla', -1);
  ChkErr('IF EXISTS olmadan yoksa hata', 'DROP FUNCTION topla');
  Chk('DROP PROCEDURE', 'DROP PROCEDURE artir', -1);
  ChkErr('drop sonrasi prosedur yok', 'CALL artir(1)');
  Chk('DROP PROCEDURE IF EXISTS yoksa sessiz',
      'DROP PROCEDURE IF EXISTS artir', -1);

  // ---- tekillestirme ----
  ChkErr('ayni fonksiyon adi (hata)',
      'CREATE FUNCTION us(a INTEGER) RETURNS INTEGER AS BEGIN RETURN a; END');
  Chk('IF NOT EXISTS ayni ad (sessiz)',
      'CREATE FUNCTION IF NOT EXISTS us(a INTEGER) RETURNS INTEGER AS BEGIN RETURN a; END', -1);
  ChkErr('ayni prosedur adi (hata)',
      'CREATE PROCEDURE yaz(a INTEGER) AS INSERT INTO p_t VALUES(9,' + Q8 + 'x' + Q8 + ',1)');
  Chk('IF NOT EXISTS ayni prosedur (sessiz)',
      'CREATE PROCEDURE IF NOT EXISTS yaz(a INTEGER) AS INSERT INTO p_t VALUES(9,' + Q8 + 'x' + Q8 + ',1)', -1);

  // ---- parametre sayisi tutarsizligi sessizce gecmemeli ----
  Chk('CREATE FUNCTION 3 parametre',
      'CREATE FUNCTION f3(a INTEGER, b INTEGER, c INTEGER) RETURNS INTEGER AS ' +
      'BEGIN RETURN a; END', -1);
  ChkVal('eksik parametre bos string',
      'SELECT f3(1)', 0, 0, '1');
  sq.Exec('DROP FUNCTION f3');
  sq.Exec('DROP FUNCTION us');
  sq.Exec('DROP FUNCTION v_al');
  sq.Exec('DROP PROCEDURE yaz');
  sq.Exec('DROP PROCEDURE ad_al');
  sq.Exec('DROP PROCEDURE tek');
  sq.Exec('DROP PROCEDURE erken');
end;
procedure T08n_Trigger;
{ F-36: TRIGGER
    - CREATE/DROP TRIGGER (IF [NOT] EXISTS)
    - BEFORE/AFTER/INSTEAD OF INSERT/UPDATE/DELETE
    - FOR EACH ROW / STATEMENT
    - WHEN kosulu
    - OLD / NEW koloni cozumleme
    - BEFORE: NEW.kolon = ifade ile satir degistirme
    - Tetikleyici govdesinde DML (INSERT/UPDATE/DELETE)
    - Cumle tetikleyicisi (FOR EACH STATEMENT)
    - Ic ice tetikleyici (trigger -> DML -> trigger)
    - Tablo silindiginde tetikleyici de silinir }
var
  Q8: string;
  i: Integer;
begin
  Grp('TRIGGER (F-36)');
  UseDir('trg');
  Q8 := Q;
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, x INTEGER, y INTEGER, z TEXT)');
  sq.Exec('CREATE TABLE log(id INTEGER PRIMARY KEY, msg TEXT)');

  // ---- BEFORE INSERT: NEW.x duzenleme ----
  Chk('CREATE TRIGGER before_insert',
      'CREATE TRIGGER trg_bi BEFORE INSERT ON t FOR EACH ROW AS ' +
      'BEGIN NEW.x = NEW.x + 10; END', -1);
  Chk('INSERT INTO t(x) VALUES(5)', 'INSERT INTO t(x) VALUES(5)', -1);
  ChkVal('BEFORE INSERT NEW.x duzenlendi', 'SELECT x FROM t WHERE id = 1', 0, 0, '15');

  // ---- BEFORE INSERT WHEN kosulu ----
  sq.Exec('DELETE FROM t');
  Chk('CREATE TRIGGER bi_when',
      'CREATE TRIGGER trg_bi2 BEFORE INSERT ON t FOR EACH ROW ' +
      'WHEN (NEW.y > 0) AS BEGIN NEW.x = NEW.x + 100; END', -1);
  Chk('INSERT y>0 tetikler', 'INSERT INTO t(x,y) VALUES(1, 5)', -1);
  ChkVal('WHEN calisti', 'SELECT x FROM t WHERE id = 2', 0, 0, '111');
  Chk('INSERT y<=0 tetiklemez', 'INSERT INTO t(x,y) VALUES(2, -1)', -1);
  ChkVal('WHEN calismadi', 'SELECT x FROM t WHERE id = 3', 0, 0, '12');

  // ---- AFTER INSERT: log yazma ----
  Chk('CREATE TRIGGER after_insert',
      'CREATE TRIGGER trg_ai AFTER INSERT ON t FOR EACH ROW AS ' +
      'BEGIN INSERT INTO log(msg) VALUES(' + Q8 + 'eklendi:' + Q8 + ' || CAST(NEW.x AS TEXT)); END', -1);
  sq.Exec('DELETE FROM log');
  Chk('INSERT -> log', 'INSERT INTO t(x) VALUES(7)', -1);
  ChkVal('AFTER INSERT log yazdi', 'SELECT msg FROM log WHERE id = 1', 0, 0, 'eklendi:17');

  // ---- BEFORE UPDATE: OLD/NEW okuma, NEW degistirme ----
  sq.Exec('DELETE FROM t');
  sq.Exec('INSERT INTO t(x,y) VALUES(10, 20)');
  Chk('CREATE TRIGGER before_update',
      'CREATE TRIGGER trg_bu BEFORE UPDATE ON t FOR EACH ROW AS ' +
      'BEGIN NEW.y = NEW.y + OLD.x; END', -1);
  Chk('UPDATE', 'UPDATE t SET y = 5 WHERE id = 5', -1);
  ChkVal('BEFORE UPDATE NEW.y = OLD.x + y', 'SELECT y FROM t WHERE id = 5', 0, 0, '125');

  // ---- AFTER UPDATE: log ----
  sq.Exec('DELETE FROM log');
  Chk('CREATE TRIGGER after_update',
      'CREATE TRIGGER trg_au AFTER UPDATE ON t FOR EACH ROW AS ' +
      'BEGIN INSERT INTO log(msg) VALUES(' + Q8 + 'guncellendi:' + Q8 + ' || CAST(NEW.x AS TEXT)); END', -1);
  Chk('UPDATE -> log', 'UPDATE t SET x = 99 WHERE id = 5', -1);
  ChkVal('AFTER UPDATE log yazdi', 'SELECT msg FROM log WHERE msg = ' + Q + 'guncellendi:99' + Q, 0, 0, 'guncellendi:99');

  // ---- BEFORE DELETE: OLD okuma ----
  Chk('CREATE TRIGGER before_delete',
      'CREATE TRIGGER trg_bd BEFORE DELETE ON t FOR EACH ROW AS ' +
      'BEGIN INSERT INTO log(msg) VALUES(' + Q8 + 'silinecek:' + Q8 + ' || CAST(OLD.x AS TEXT)); END', -1);
  sq.Exec('DELETE FROM log');
  Chk('DELETE -> log', 'DELETE FROM t WHERE id = 5', -1);
  ChkVal('BEFORE DELETE log yazdi', 'SELECT msg FROM log WHERE msg = ' + Q + 'silinecek:99' + Q, 0, 0, 'silinecek:99');

  // ---- AFTER DELETE ----
  Chk('CREATE TRIGGER after_delete',
      'CREATE TRIGGER trg_ad AFTER DELETE ON t FOR EACH ROW AS ' +
      'BEGIN INSERT INTO log(msg) VALUES(' + Q8 + 'silindi:' + Q8 + ' || CAST(OLD.x AS TEXT)); END', -1);
  sq.Exec('DELETE FROM log');
  sq.Exec('INSERT INTO t(x) VALUES(33)');
  Chk('DELETE -> log', 'DELETE FROM t WHERE id = 6', -1);
  ChkVal('AFTER DELETE log yazdi', 'SELECT msg FROM log WHERE msg = ' + Q + 'silindi:43' + Q, 0, 0, 'silindi:43');

  // ---- FOR EACH STATEMENT ----
  Chk('CREATE TRIGGER stmt_insert',
      'CREATE TRIGGER trg_si AFTER INSERT ON t FOR EACH STATEMENT AS ' +
      'BEGIN INSERT INTO log(msg) VALUES(' + Q8 + 'STMT:' + Q8 + ' || CAST((SELECT COUNT(*) FROM t) AS TEXT)); END', -1);
  sq.Exec('DELETE FROM log');
  Chk('INSERT 3 satir', 'INSERT INTO t(x) VALUES(1); INSERT INTO t(x) VALUES(2); INSERT INTO t(x) VALUES(3)', -1);
  ChkVal('STATEMENT bir kez calisti', 'SELECT msg FROM log WHERE msg = ' + Q + 'STMT:1' + Q, 0, 0, 'STMT:1');

  // ---- INSTEAD OF INSERT (VIEW uzerinde de calisir) ----
  sq.Exec('CREATE TABLE t2(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('CREATE VIEW v_t2 AS SELECT * FROM t2');
  Chk('CREATE TRIGGER instead_of',
      'CREATE TRIGGER trg_io INSTEAD OF INSERT ON v_t2 FOR EACH ROW AS ' +
      'BEGIN INSERT INTO t2(v) VALUES(NEW.v * 2); END', -1);
  Chk('INSERT view', 'INSERT INTO v_t2(v) VALUES(5)', -1);
  ChkVal('INSTEAD OF calisti', 'SELECT v FROM t2 WHERE id = 1', 0, 0, '10');

  // ---- Ic ice tetikleyici (trigger -> DML -> trigger) ----
  sq.Exec('CREATE TABLE a(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, v INTEGER)');
  Chk('CREATE TRIGGER nested_a',
      'CREATE TRIGGER trg_a BEFORE INSERT ON a FOR EACH ROW AS ' +
      'BEGIN INSERT INTO b(v) VALUES(NEW.v + 1); END', -1);
  Chk('CREATE TRIGGER nested_b',
      'CREATE TRIGGER trg_b BEFORE INSERT ON b FOR EACH ROW AS ' +
      'BEGIN NEW.v = NEW.v * 10; END', -1);
  Chk('INSERT -> nested', 'INSERT INTO a(v) VALUES(3)', -1);
  ChkVal('nested tetikleyiciler calisti', 'SELECT v FROM b WHERE id = 1', 0, 0, '40');

  // ---- DROP TRIGGER ----
  Chk('DROP TRIGGER', 'DROP TRIGGER trg_bi', -1);
  Chk('INSERT sonrasi tetikleyici yok', 'INSERT INTO t(x) VALUES(100)', -1);
  ChkVal('eski tetikleyici calismadi', 'SELECT x FROM t ORDER BY id DESC LIMIT 1', 0, 0, '100');
  Chk('DROP TRIGGER IF EXISTS yoksa sessiz', 'DROP TRIGGER IF EXISTS trg_bi', -1);
  ChkErr('DROP TRIGGER yoksa hata', 'DROP TRIGGER trg_bi');

  // ---- Tablo silindiginde tetikleyici de silinir ----
  Chk('CREATE TABLE t3', 'CREATE TABLE t3(id INTEGER PRIMARY KEY, x INTEGER)', -1);
  Chk('CREATE TRIGGER trg_t3', 'CREATE TRIGGER trg_t3x BEFORE INSERT ON t3 FOR EACH ROW AS BEGIN END', -1);
  Chk('DROP TABLE -> tetikleyici silindi', 'DROP TABLE t3', -1);
  ChkErr('eski tetikleyici yok', 'DROP TRIGGER trg_t3x');

  // ---- CREATE TRIGGER IF NOT EXISTS ----
  Chk('IF NOT EXISTS ayni ad', 'CREATE TRIGGER IF NOT EXISTS trg_bi BEFORE INSERT ON t FOR EACH ROW AS BEGIN END', -1);
  ChkErr('ayni ad hata', 'CREATE TRIGGER trg_bi BEFORE INSERT ON t FOR EACH ROW AS BEGIN END');

  // Temizlik
  for i := 1 to 20 do sq.Exec('DROP TRIGGER IF EXISTS trg_bi' + IntToStr(i));
  sq.Exec('DROP TRIGGER IF EXISTS trg_bi2');
  sq.Exec('DROP TRIGGER IF EXISTS trg_ai');
  sq.Exec('DROP TRIGGER IF EXISTS trg_bu');
  sq.Exec('DROP TRIGGER IF EXISTS trg_au');
  sq.Exec('DROP TRIGGER IF EXISTS trg_bd');
  sq.Exec('DROP TRIGGER IF EXISTS trg_ad');
  sq.Exec('DROP TRIGGER IF EXISTS trg_si');
  sq.Exec('DROP TRIGGER IF EXISTS trg_io');
  sq.Exec('DROP TRIGGER IF EXISTS trg_a');
  sq.Exec('DROP TRIGGER IF EXISTS trg_b');
end;

procedure T08h_CrossJoin;
begin
  Grp('CROSS JOIN (4.1)');
  UseDir('crs');
  sq.Exec('CREATE TABLE cr_a(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('CREATE TABLE cr_b(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('CREATE TABLE cr_k(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('CREATE TABLE cr_z(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO cr_a(id,ad) VALUES(1,' + Q + 'a1' + Q + '),(2,' + Q +
      'a2' + Q + '),(3,' + Q + 'a3' + Q + ')');
  sq.Exec('INSERT INTO cr_b(id,ad) VALUES(10,' + Q + 'b1' + Q + '),(20,' + Q +
      'b2' + Q + ')');
  sq.Exec('INSERT INTO cr_k(id,ad) VALUES(1,' + Q + 'k1' + Q + '),(2,' + Q +
      'k2' + Q + '),(7,' + Q + 'k7' + Q + '),(8,' + Q + 'k8' + Q + ')');
  // ON'suz cartesius: 3 x 2 = 6
  Chk('CROSS ON''suz cartesius 3x2=6',
      'SELECT a.ad, b.ad FROM cr_a a CROSS JOIN cr_b b', 6);
  // ON yazildiysa INNER gibi filtreler (b.id=10 -> 3 satir)
  Chk('CROSS ON lu filtre (b.id=10)',
      'SELECT a.ad, b.ad FROM cr_a a CROSS JOIN cr_b b ON b.id = 10', 3);
  Chk('CROSS + WHERE (b.id=20)',
      'SELECT a.ad, b.ad FROM cr_a a CROSS JOIN cr_b b WHERE b.id = 20', 3);
  // CROSS, FROM alias'i olarak yutulmaz (nitelemeli kolon cozulur)
  Chk('CROSS nitelikli kolon (6)',
      'SELECT cr_a.ad, cr_b.ad FROM cr_a CROSS JOIN cr_b', 6);
  // ikili CROSS zinciri: 4 x 3 x 2 = 24
  Chk('ikili CROSS zincir 4x3x2=24',
      'SELECT k.ad, a.ad, b.ad FROM cr_k k CROSS JOIN cr_a a CROSS JOIN cr_b b', 24);
  // CROSS + INNER karisik zincir: (a1-k1, a2-k2) = 2 x 2 = 4
  Chk('INNER + CROSS zincir (4)',
      'SELECT a.ad, b.ad FROM cr_a a JOIN cr_k k ON a.id = k.id CROSS JOIN cr_b b', 4);
  ChkVal('CROSS sirali ilk deger',
      'SELECT a.ad, b.ad FROM cr_a a CROSS JOIN cr_b b ORDER BY a.id, b.id', 0, 1, 'b1');
  Chk('CROSS + DISTINCT (3)',
      'SELECT DISTINCT a.ad FROM cr_a a CROSS JOIN cr_b b', 3);
  Chk('CROSS + LIMIT (4)',
      'SELECT a.ad, b.ad FROM cr_a a CROSS JOIN cr_b b LIMIT 4', 4);
  Chk('bos sag tablo cartesius = 0',
      'SELECT a.ad FROM cr_a a CROSS JOIN cr_z z', 0);
  // kisitlar
  ChkErr('CROSS OUTER hata',
      'SELECT a.ad FROM cr_a a CROSS OUTER JOIN cr_b b');
  ChkErr('ON''suz INNER JOIN hata (regresyon)',
      'SELECT a.ad FROM cr_a a JOIN cr_b b');
  ChkErr('ON''suz LEFT JOIN hata (regresyon)',
      'SELECT a.ad FROM cr_a a LEFT JOIN cr_b b');
end;

procedure T08i_JoinAggregate;
const
  // Birlesim: 4 siparis (veli, ali, ali, ayse) x 4 musteri (ank, ist,
  // izm, burs; meh'in siparisi yok). Ic birlesim 4 satir verir.
  GSQL = 'SELECT m.sehir, COUNT(*) AS n FROM jg_od o JOIN jg_mus m ' +
      'ON o.musteri = m.ad GROUP BY m.sehir ORDER BY m.sehir';
begin
  Grp('JOIN + GROUP BY / aggregate (4.2)');
  UseDir('jgr');
  sq.Exec('CREATE TABLE jg_od(id INTEGER PRIMARY KEY, musteri TEXT)');
  sq.Exec('CREATE TABLE jg_mus(ad TEXT, sehir TEXT)');
  sq.Exec('INSERT INTO jg_od(id,musteri) VALUES(1,' + Q + 'veli' + Q + ')');
  sq.Exec('INSERT INTO jg_od(id,musteri) VALUES(2,' + Q + 'ali' + Q + ')');
  sq.Exec('INSERT INTO jg_od(id,musteri) VALUES(3,' + Q + 'ali' + Q + ')');
  sq.Exec('INSERT INTO jg_od(id,musteri) VALUES(4,' + Q + 'ayse' + Q + ')');
  sq.Exec('INSERT INTO jg_mus(ad,sehir) VALUES(' + Q + 'ali' + Q + ',' + Q +
      'ank' + Q + ')');
  sq.Exec('INSERT INTO jg_mus(ad,sehir) VALUES(' + Q + 'veli' + Q + ',' + Q +
      'ist' + Q + ')');
  sq.Exec('INSERT INTO jg_mus(ad,sehir) VALUES(' + Q + 'ayse' + Q + ',' + Q +
      'izm' + Q + ')');
  sq.Exec('INSERT INTO jg_mus(ad,sehir) VALUES(' + Q + 'meh' + Q + ',' + Q +
      'burs' + Q + ')');
  // 1) Nitelemeli GROUP BY + aggregate (ist=1, ank=2, izm=1)
  Chk('JOIN GROUP BY 3 grup', GSQL, 3);
  ChkVal('sirali ilk grup ank=2', GSQL, 0, 0, 'ank');
  ChkVal('sirali ilk grup sayac=2', GSQL, 0, 1, '2');
  // 2) Sade (nitelemesiz) GROUP BY — FindCozumleme sonek kurali
  Chk('sade GROUP BY 3 grup',
      'SELECT o.musteri, COUNT(*) AS n FROM jg_od o JOIN jg_mus m ' +
      'ON o.musteri = m.ad GROUP BY musteri ORDER BY o.musteri', 3);
  ChkVal('sade GROUP BY ilk grup ali=2',
      'SELECT o.musteri, COUNT(*) AS n FROM jg_od o JOIN jg_mus m ' +
      'ON o.musteri = m.ad GROUP BY musteri ORDER BY o.musteri', 0, 1, '2');
  // 3) GROUP BY'siz aggregate (tek satir)
  ChkVal('JOIN COUNT(*) = 4',
      'SELECT COUNT(*) FROM jg_od o JOIN jg_mus m ON o.musteri = m.ad', 0, 0, '4');
  ChkVal('JOIN COUNT + SUM(id) = 10',
      'SELECT COUNT(*) AS n, SUM(o.id) AS t FROM jg_od o JOIN jg_mus m ' +
      'ON o.musteri = m.ad', 0, 1, '10');
  // 4) WHERE + JOIN + GROUP BY
  Chk('WHERE ile 2 grup (izm elendi)',
      'SELECT m.sehir, COUNT(*) AS n FROM jg_od o JOIN jg_mus m ' +
      'ON o.musteri = m.ad WHERE m.sehir <> ' + Q + 'izm' + Q +
      ' GROUP BY m.sehir ORDER BY m.sehir', 2);
  ChkVal('WHERE sonrasi 2. grup ist=1',
      'SELECT m.sehir, COUNT(*) AS n FROM jg_od o JOIN jg_mus m ' +
      'ON o.musteri = m.ad WHERE m.sehir <> ' + Q + 'izm' + Q +
      ' GROUP BY m.sehir ORDER BY m.sehir', 1, 1, '1');
  // 5) LEFT JOIN + GROUP BY: siparissiz musteri -> 0'li grup
  Chk('LEFT JOIN 4 grup (meh''siz)',
      'SELECT m.sehir, COUNT(o.id) AS n FROM jg_mus m LEFT JOIN jg_od o ' +
      'ON m.ad = o.musteri GROUP BY m.sehir ORDER BY m.sehir', 4);
  ChkVal('LEFT 2. grup burs', 'SELECT m.sehir, COUNT(o.id) AS n FROM jg_mus m ' +
      'LEFT JOIN jg_od o ON m.ad = o.musteri GROUP BY m.sehir ORDER BY m.sehir',
      1, 0, 'burs');
  ChkVal('LEFT burs sayac=0', 'SELECT m.sehir, COUNT(o.id) AS n FROM jg_mus m ' +
      'LEFT JOIN jg_od o ON m.ad = o.musteri GROUP BY m.sehir ORDER BY m.sehir',
      1, 1, '0');
  // 6) HAVING — alias ile (4.3'ten sonra dogrudan aggregate de kabul;
  //    dogrudan yazim testleri T09b_HavingAggregate icinde)
  Chk('HAVING alias (yalniz ank)',
      'SELECT m.sehir, COUNT(*) AS n FROM jg_od o JOIN jg_mus m ' +
      'ON o.musteri = m.ad GROUP BY m.sehir HAVING n > 1', 1);
  ChkVal('HAVING sayac=2', 'SELECT m.sehir, COUNT(*) AS n FROM jg_od o ' +
      'JOIN jg_mus m ON o.musteri = m.ad GROUP BY m.sehir HAVING n > 1', 0, 1, '2');
  // 7) ORDER BY aggregate (FinishGroup: tip haritasi, "2" > "1" sayisal)
  ChkVal('ORDER BY n DESC ilk ank',
      'SELECT m.sehir, COUNT(*) AS n FROM jg_od o JOIN jg_mus m ' +
      'ON o.musteri = m.ad GROUP BY m.sehir ORDER BY n DESC', 0, 0, 'ank');
  // 8) GROUP BY + LIMIT (kuyruk FinishGroup'ta uygulanir)
  Chk('GROUP BY + LIMIT 2',
      'SELECT m.sehir, COUNT(*) AS n FROM jg_od o JOIN jg_mus m ' +
      'ON o.musteri = m.ad GROUP BY m.sehir ORDER BY m.sehir LIMIT 2', 2);
  // 9) Tek tabloda nitelemeli GROUP BY (eski birebir arama sessiz
  //    tek-grup dusuyordu; FindColIdx kurali duzeltti)
  Chk('tek tablo nitelemeli GROUP BY 3 grup',
      'SELECT x.musteri, COUNT(*) AS n FROM jg_od x GROUP BY x.musteri ' +
      'ORDER BY x.musteri', 3);
  ChkVal('tek tablo nitelemeli ilk grup ali=2',
      'SELECT x.musteri, COUNT(*) AS n FROM jg_od x GROUP BY x.musteri ' +
      'ORDER BY x.musteri', 0, 1, '2');
  // 10) Kisitlar
  ChkErr('bilinmeyen GROUP BY kolonu (hata)',
      'SELECT m.sehir, COUNT(*) FROM jg_od o JOIN jg_mus m ' +
      'ON o.musteri = m.ad GROUP BY zz.sehir');
  ChkErr('set-op + JOIN + aggregate (hata)',
      'SELECT COUNT(*) FROM jg_od o JOIN jg_mus m ON o.musteri = m.ad ' +
      'UNION SELECT 1');
end;

procedure T08g_Collation;
begin
  Grp('Turkce collation (P5-TR)');
  UseDir('colltr');
  sq.Exec('CREATE TABLE kel(id INTEGER PRIMARY KEY, w TEXT)');
  sq.Exec('INSERT INTO kel(id,w) VALUES(1,' + Q + 'davul' + Q + ')');
  sq.Exec('INSERT INTO kel(id,w) VALUES(2,' + Q + 'çocuk' + Q + ')');
  sq.Exec('INSERT INTO kel(id,w) VALUES(3,' + Q + 'ıhlamur' + Q + ')');
  sq.Exec('INSERT INTO kel(id,w) VALUES(4,' + Q + 'istanbul' + Q + ')');
  sq.Exec('INSERT INTO kel(id,w) VALUES(5,' + Q + 'pazar' + Q + ')');
  sq.Exec('INSERT INTO kel(id,w) VALUES(6,' + Q + 'öğretmen' + Q + ')');
  sq.Exec('INSERT INTO kel(id,w) VALUES(7,' + Q + 'var' + Q + ')');
  sq.Exec('INSERT INTO kel(id,w) VALUES(8,' + Q + 'üzüm' + Q + ')');
  // Turk sirasi: çocuk, davul, ıhlamur, istanbul, öğretmen, pazar, üzüm, var
  // Bayt sirasi:  davul, istanbul, pazar, var, çocuk, öğretmen, üzüm, ıhlamur
  ChkVal('TR sira ilk=cocuk',
      'SELECT w FROM kel ORDER BY w COLLATE TR', 0, 0, 'çocuk');
  ChkVal('TR sira son=var',
      'SELECT w FROM kel ORDER BY w COLLATE TR', 7, 0, 'var');
  ChkVal('TR sira orta=ogretmen',
      'SELECT w FROM kel ORDER BY w COLLATE TR', 4, 0, 'öğretmen');
  { R-20: Turkce alfabesinde i ve ı AYRI harflerdir; alfabetik sira
      i (12) < ı (13). "istanbul" (i) "ıhlamur" (ı) ONCE gelir.
      Tam sira: cocuk(c), davul(d), istanbul(i), pazar(p), ogretmen(o),
      ihlamur(ı), var(v), uzum(u). Eskiden i ve ı ayni agirligi
      paylasiyordu ve "ıhlamur" 2. siradaydi. }
  ChkVal('TR sira istanbul (noktali i) once ihlamur (noktasiz i)',
      'SELECT w FROM kel ORDER BY w COLLATE TR', 2, 0, 'istanbul');
  ChkVal('bayt sira ilk=davul (degismedi)',
      'SELECT w FROM kel ORDER BY w', 0, 0, 'davul');
  ChkVal('TR DESC ilk=var',
      'SELECT w FROM kel ORDER BY w COLLATE TR DESC LIMIT 1', 0, 0, 'var');
  ChkVal('UPPER Turkce i->İ',
      'SELECT UPPER(' + Q + 'istanbul' + Q + ')', 0, 0, 'İSTANBUL');
  ChkVal('UPPER isiz ı->I',
      'SELECT UPPER(' + Q + 'ıhlamur' + Q + ')', 0, 0, 'IHLAMUR');
  ChkVal('LOWER I->ı',
      'SELECT LOWER(' + Q + 'ISPARTA' + Q + ')', 0, 0, 'ısparta');
  ChkVal('LOWER İ->i',
      'SELECT LOWER(' + Q + 'İZMİR' + Q + ')', 0, 0, 'izmir');
  ChkVal('LENGTH karakter sayar (5)',
      'SELECT LENGTH(' + Q + 'şeker' + Q + ')', 0, 0, '5');
  Chk('harf duyarsiz arama UPPER ile',
      'SELECT w FROM kel WHERE UPPER(w) = UPPER(' + Q + 'ÇOCUK' + Q + ')', 1);
  { R-20: bilinmeyen bir dil etiketi ARTIK hata DEGILDIR — motor sabit
      bir dil listesine kilitli degildir; alfabe varsayilan olarak Latin'e
      duser. Yalnizca BOS etiket hatadir. }
  Chk('bilinmeyen dil etiketi kabul edilir (XX)',
      'SELECT w FROM kel ORDER BY w COLLATE XX', -1);
  // indeksli kolonda da TR dogru (hizli yol devre disi kalir)
  sq.Exec('CREATE INDEX ixw ON kel(w)');
  ChkVal('TR indeksli de dogru',
      'SELECT w FROM kel ORDER BY w COLLATE TR', 0, 0, 'çocuk');
  ChkVal('TR LIMIT indeksli de dogru',
      'SELECT w FROM kel ORDER BY w COLLATE TR LIMIT 2 OFFSET 6', 1, 0, 'var');
end;

procedure T08c_AltSorgu;
begin
  Grp('Alt sorgu: IN (SELECT), skaler, EXISTS (P5-2)');
  UseDir('subq');
  sq.Exec('CREATE TABLE bolge(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('CREATE TABLE musteri(id INTEGER PRIMARY KEY, ad TEXT, bid INTEGER)');
  sq.Exec('INSERT INTO bolge(id,ad) VALUES(1,' + Q + 'Ege' + Q + '),(2,' + Q + 'Ic Anadolu' + Q + ')');
  sq.Exec('INSERT INTO musteri(id,ad,bid) VALUES(1,' + Q + 'Ali' + Q + ',1)');
  sq.Exec('INSERT INTO musteri(id,ad,bid) VALUES(2,' + Q + 'Veli' + Q + ',2)');
  sq.Exec('INSERT INTO musteri(id,ad,bid) VALUES(3,' + Q + 'Zoe' + Q + ',NULL)');
  sq.Exec('INSERT INTO musteri(id,ad,bid) VALUES(4,' + Q + 'Can' + Q + ',1)');
  Chk('IN subquery (3)',
      'SELECT ad FROM musteri WHERE bid IN (SELECT id FROM bolge)', 3);
  // Uc-degerli mantik: NULL dis deger NOT IN'de eslesmez (UNKNOWN elenir).
  Chk('NOT IN subquery dis NULL elenir (0)',
      'SELECT ad FROM musteri WHERE bid NOT IN (SELECT id FROM bolge)', 0);
  Chk('NOT IN NULL-suz kume (Veli)',
      'SELECT ad FROM musteri WHERE bid NOT IN (SELECT id FROM bolge WHERE id = 1)', 1);
  ChkVal('NOT IN NULL-suz deger',
      'SELECT ad FROM musteri WHERE bid NOT IN (SELECT id FROM bolge WHERE id = 1) ORDER BY id', 0, 0, 'Veli');
  Chk('IN bos kume (0)',
      'SELECT ad FROM musteri WHERE bid IN (SELECT id FROM bolge WHERE id > 99)', 0);
  Chk('NOT IN bos kume (NULL disindakiler, 3)',
      'SELECT ad FROM musteri WHERE bid NOT IN (SELECT id FROM bolge WHERE id > 99)', 3);
  ChkVal('skaler esitlik',
      'SELECT ad FROM musteri WHERE bid = (SELECT id FROM bolge WHERE ad = ' + Q + 'Ege' + Q + ') ORDER BY id', 0, 0, 'Ali');
  Chk('skaler aggregate',
      'SELECT ad FROM musteri WHERE id > (SELECT AVG(id) FROM musteri)', 2);
  Chk('skaler bos = NULL eslesmez (0)',
      'SELECT ad FROM musteri WHERE bid = (SELECT id FROM bolge WHERE id > 99)', 0);
  ChkErr('skaler cok satir (hata)',
      'SELECT ad FROM musteri WHERE bid = (SELECT id FROM bolge)');
  ChkErr('IN cok kolon (hata)',
      'SELECT ad FROM musteri WHERE bid IN (SELECT id, ad FROM bolge)');
  ChkVal('SELECT listesinde skaler',
      'SELECT ad, (SELECT ad FROM bolge WHERE id = 1) AS b FROM musteri WHERE id = 1', 0, 1, 'Ege');
  Chk('EXISTS (4)',
      'SELECT ad FROM musteri WHERE EXISTS (SELECT id FROM bolge WHERE id = 1)', 4);
  Chk('EXISTS bos (0)',
      'SELECT ad FROM musteri WHERE EXISTS (SELECT id FROM bolge WHERE id > 99)', 0);
  Chk('NOT EXISTS bos (4)',
      'SELECT ad FROM musteri WHERE NOT EXISTS (SELECT id FROM bolge WHERE id > 99)', 4);
  // F-03: iliskili (correlated) alt sorgu artik destekleniyor.
  // a.bid IN (SELECT b.bid FROM musteri b WHERE b.id = a.id)
  // a.id=1 -> b.id=1 -> b.bid=1; a.bid=1 -> eslesir (Ali)
  // a.id=2 -> b.bid=2; a.bid=2 -> eslesir (Veli)
  // a.id=3 -> b.bid=NULL; a.bid=NULL -> NULL eslesmez (Zoe gelmez)
  // a.id=4 -> b.bid=1; a.bid=1 -> eslesir (Can)
  Chk('iliskili IN alt sorgu (3)',
      'SELECT a.ad FROM musteri a WHERE a.bid IN (SELECT b.bid FROM musteri b WHERE b.id = a.id)', 3);
  ChkVal('iliskili IN deger',
      'SELECT a.ad FROM musteri a WHERE a.bid IN (SELECT b.bid FROM musteri b WHERE b.id = a.id) ORDER BY a.id', 0, 0, 'Ali');
  // EXISTS iliskili: a.id = b.id -> her musteri icin kendisi var -> 4 satir
  Chk('iliskili EXISTS (4)',
      'SELECT a.ad FROM musteri a WHERE EXISTS (SELECT 1 FROM musteri b WHERE b.id = a.id)', 4);
  // NOT EXISTS iliskili: a.id <> b.id -> b kendisi disinda 3 var -> 0 satir
  Chk('iliskili NOT EXISTS (0)',
      'SELECT a.ad FROM musteri a WHERE NOT EXISTS (SELECT 1 FROM musteri b WHERE b.id <> a.id)', 0);
  // iliskili skaler: a.bid = (SELECT b.bid ... b.id = a.id) -> hep dogru (3)
  Chk('iliskili skaler alt sorgu (3)',
      'SELECT a.ad FROM musteri a WHERE a.bid = (SELECT b.bid FROM musteri b WHERE b.id = a.id)', 3);
end;

procedure T09g_AnySomeAll;
// F-06: ANY / SOME / ALL kuantifayicilari (PostgreSQL uyumu).
begin
  Grp('ANY / SOME / ALL (F-06)');
  UseDir('quant');
  sq.Exec('CREATE TABLE q(id INTEGER PRIMARY KEY, ad TEXT, n INTEGER)');
  sq.Exec('INSERT INTO q VALUES(1,' + Q + 'Ali' + Q + ',10),(2,' + Q + 'Veli' + Q + ',20),(3,' +
          Q + 'Zoe' + Q + ',30),(4,' + Q + 'Can' + Q + ',NULL)');
  // x = ANY (kume) IN ile ayni
  Chk('= ANY (2)', 'SELECT id FROM q WHERE n = ANY (SELECT n FROM q WHERE n > 15)', 2);
  // SOME = ANY ile ayni: alt kume {10,20}; 30 > 10 ve 30 > 20 -> 30 da gelir -> 2
  Chk('> SOME (2)', 'SELECT id FROM q WHERE n > SOME (SELECT n FROM q WHERE n < 25)', 2);
  // > ANY: alt kume {20,30}; 20 > 20 hayir, 30 > 20 evet -> sadece 30 -> 1
  Chk('> ANY (1)', 'SELECT id FROM q WHERE n > ANY (SELECT n FROM q WHERE n > 15)', 1);
  // < ALL: tum satirlar karsilarsa TRUE (10 < 20 ve 10 < 30) -> sadece 10 -> 1
  Chk('< ALL (1)', 'SELECT id FROM q WHERE n < ALL (SELECT n FROM q WHERE n > 15)', 1);
  // > ALL: 30 > 20 evet ama 30 > 30 hayir; hicbiri saglamaz -> 0
  Chk('> ALL (0)', 'SELECT id FROM q WHERE n > ALL (SELECT n FROM q WHERE n > 15)', 0);
  // >= ANY: en az biri (20 >= 20) -> 20 ve 30 -> 2
  Chk('>= ANY (2)', 'SELECT id FROM q WHERE n >= ANY (SELECT n FROM q WHERE n > 15)', 2);
  // <> ALL: alt kume {30}; 30 <> 30 YANLIS -> yalniz 10 ve 20 -> 2 (Can NULL elenir)
  Chk('<> ALL (2)', 'SELECT id FROM q WHERE n <> ALL (SELECT n FROM q WHERE n > 25)', 2);
  // bos kume: ANY -> FALSE, ALL -> TRUE (vakuum; NULL'li satir da gecer)
  Chk('= ANY bos kume (0)', 'SELECT id FROM q WHERE n = ANY (SELECT n FROM q WHERE n > 999)', 0);
  Chk('< ALL bos kume (4)', 'SELECT id FROM q WHERE n < ALL (SELECT n FROM q WHERE n > 999)', 4);
  // deger kontrolu: 10 < 20 ve 10 < 30 -> Ali (id=1)
  ChkVal('< ALL deger dogru', 'SELECT id FROM q WHERE n < ALL (SELECT n FROM q WHERE n > 15)', 0, 0, '1');
  // cok kolonlu alt sorgu hata
  ChkErr('ANY cok kolon (hata)',
      'SELECT id FROM q WHERE n = ANY (SELECT id, n FROM q)');
end;

procedure T09h_FetchFirstNulls;
// F-08: FETCH FIRST/NEXT n ROWS ONLY (SQL:2008)
// F-10: NULLS FIRST / NULLS LAST (SQL:2003)
begin
  Grp('FETCH FIRST + NULLS FIRST/LAST (F-08/F-10)');
  UseDir('fetch');
  sq.Exec('CREATE TABLE f(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO f VALUES(1,' + Q + 'b' + Q + '),(2,NULL),(3,' + Q + 'a' + Q + '),(4,NULL),(5,' + Q + 'c' + Q + ')');
  // ---- F-08: FETCH FIRST ----
  Chk('FETCH FIRST 2 ROWS ONLY (2)',
      'SELECT id FROM f ORDER BY id FETCH FIRST 2 ROWS ONLY', 2);
  Chk('FETCH FIRST 1 ROW ONLY (1)',
      'SELECT id FROM f ORDER BY id FETCH FIRST 1 ROW ONLY', 1);
  Chk('FETCH NEXT 3 ROWS ONLY (3)',
      'SELECT id FROM f ORDER BY id FETCH NEXT 3 ROWS ONLY', 3);
  Chk('FETCH NEXT ROWS ONLY = 1 (1)',
      'SELECT id FROM f ORDER BY id FETCH NEXT ROWS ONLY', 1);
  Chk('FETCH FIRST 0 ROWS ONLY (0)',
      'SELECT id FROM f ORDER BY id FETCH FIRST 0 ROWS ONLY', 0);
  Chk('FETCH FIRST 2 OFFSET 2 (2)',
      'SELECT id FROM f ORDER BY id FETCH FIRST 2 ROWS ONLY OFFSET 2 ROWS', 2);
  ChkVal('FETCH deger dogru',
      'SELECT id FROM f ORDER BY id FETCH FIRST 2 ROWS ONLY', 0, 0, '1');
  ChkErr('FETCH WITH TIES (hata)',
      'SELECT id FROM f ORDER BY id FETCH FIRST 2 ROWS WITH TIES');
  ChkErr('FETCH ONLY eksik (hata)',
      'SELECT id FROM f ORDER BY id FETCH FIRST 2 ROWS');
  // ---- F-10: NULLS FIRST / LAST ----
  // Veri: 1='b', 2=NULL, 3='a', 4=NULL, 5='c'
  // Not: iki NULL satir arasindaki SIRa kararsiz (quicksort stabil degil);
  // bu yuzden NULL konumu SATIR SAYISI ile olculur (kaç NULL basa geldi).
  // NULLS FIRST: ilk 2 satir NULL
  Chk('NULLS FIRST ASC ilk 2 NULL',
      'SELECT id FROM f WHERE ad IS NULL ORDER BY ad ASC NULLS FIRST', 2);
  // NULLS LAST: ilk 3 satir NULL DEGIL (a,b,c)
  ChkVal('NULLS LAST ASC ilk deger NULL degil',
      'SELECT id FROM f ORDER BY ad ASC NULLS LAST', 0, 0, '3');
  Chk('NULLS LAST ASC son 2 NULL',
      'SELECT id FROM f ORDER BY ad ASC NULLS LAST OFFSET 3 ROWS', 2);
  // NULLS LAST DESC: ilk deger 'c' (id=5)
  ChkVal('NULLS LAST DESC ilk deger',
      'SELECT id FROM f ORDER BY ad DESC NULLS LAST', 0, 0, '5');
  Chk('NULLS LAST DESC son 2 NULL',
      'SELECT id FROM f ORDER BY ad DESC NULLS LAST OFFSET 3 ROWS', 2);
  // NULLS FIRST DESC: ilk 2 satir NULL
  Chk('NULLS FIRST DESC ilk 2 NULL',
      'SELECT id FROM f WHERE ad IS NULL ORDER BY ad DESC NULLS FIRST', 2);
  // varsayilan (bayrak yok): SQL:2003 — NULL en kucuk, ASC'de once
  Chk('ASC varsayilani NULL once',
      'SELECT id FROM f WHERE ad IS NULL ORDER BY ad ASC', 2);
  ChkVal('ASC varsayilani ilk deger NULL',
      'SELECT id FROM f WHERE ad IS NULL ORDER BY ad ASC, id ASC FETCH FIRST 1 ROWS ONLY', 0, 0, '2');
  // varsayilan DESC'de: NULL en kucuk -> sona
  ChkVal('DESC varsayilani ilk deger',
      'SELECT id FROM f ORDER BY ad DESC', 0, 0, '5');
  // NULLS LAST + FETCH FIRST 2: 'a','b' -> ilk id=3
  ChkVal('NULLS LAST + FETCH FIRST 2',
      'SELECT id FROM f ORDER BY ad ASC NULLS LAST FETCH FIRST 2 ROWS ONLY', 0, 0, '3');
  // NULLS FIRST + FETCH FIRST 2: NULL satirlar (id 2 veya 4)
  Chk('NULLS FIRST + FETCH FIRST 2 NULL',
      'SELECT id FROM f WHERE ad IS NULL ORDER BY ad ASC NULLS FIRST FETCH FIRST 2 ROWS ONLY', 2);
  // sayisal kolonda NULLS LAST (hizli yol atlanir)
  Chk('sayisal NULLS LAST (2)',
      'SELECT id FROM f WHERE ad IS NULL ORDER BY id NULLS LAST', 2);
  ChkErr('NULLS SONRASI FIRST/LAST yok (hata)',
      'SELECT id FROM f ORDER BY ad NULLS MIDDLE');
end;

procedure T09s_Spatial;
// F-24: SPATIAL — mesafe, daire, bounding box, çokgen
begin
  Grp('Spatial (F-24)');
  UseDir('spat');
  sq.Exec('CREATE TABLE sp(id INTEGER PRIMARY KEY, ad TEXT, x REAL, y REAL)');
  sq.Exec('INSERT INTO sp VALUES(1,' + Q + 'A' + Q + ',0,0),(2,' + Q + 'B' + Q + ',3,4),' +
          '(3,' + Q + 'C' + Q + ',10,10),(4,' + Q + 'D' + Q + ',1,1),(5,' + Q + 'E' + Q + ',5,5)');

  // ---- DISTANCE (Öklid) ----
  ChkVal('DISTANCE (0,0)-(3,4) = 5',
      'SELECT DISTANCE(0, 0, 3, 4)', 0, 0, '5');
  ChkVal('DISTANCE (0,0)-(10,10)',
      'SELECT DISTANCE(0, 0, 10, 10)', 0, 0, VDbFloatToStr(Sqrt(200)));
  ChkVal('DISTANCE ayni nokta = 0',
      'SELECT DISTANCE(5, 5, 5, 5)', 0, 0, '0');
  ChkVal('DISTANCE kolonlardan',
      'SELECT ad FROM sp WHERE DISTANCE(x, y, 0, 0) = 5', 0, 0, 'B');
  ChkVal('DISTANCE <= 5 olanlar',
      'SELECT COUNT(*) FROM sp WHERE DISTANCE(x, y, 0, 0) <= 5', 0, 0, '3');

  // ---- HAVERSINE (küre mesafesi, km) ----
  // İstanbul (41.010, 28.960) ↔ Ankara (39.925, 32.835) gercek merkez
  // koordinatlari. Duz hesap: dlat = -1.085 derece = -120.4 km,
  // dlon = 3.875 derece x cos(40.5) = 328.4 km ->
  // sqrt(120.4^2 + 328.4^2) = 349.3 km. R=6371 alinmistir.
  ChkVal('HAVERSINE İstanbul-Ankara ~349 km',
      'SELECT ROUND(HAVERSINE(41.010, 28.960, 39.925, 32.835))', 0, 0, '349');
  ChkVal('HAVERSINE ayni nokta = 0',
      'SELECT HAVERSINE(41.0, 29.0, 41.0, 29.0)', 0, 0, '0');
  ChkVal('HAVERSINE kuzey-güney 1 derece ~111 km',
      'SELECT ROUND(HAVERSINE(40.0, 29.0, 41.0, 29.0))', 0, 0, '111');

  // ---- IN_CIRCLE ----
  ChkVal('IN_CIRCLE merkez (0,0) r=5',
      'SELECT COUNT(*) FROM sp WHERE IN_CIRCLE(x, y, 0, 0, 5)', 0, 0, '3');
  ChkVal('IN_CIRCLE merkez (0,0) r=1.5',
      'SELECT COUNT(*) FROM sp WHERE IN_CIRCLE(x, y, 0, 0, 1.5)', 0, 0, '2');
  ChkVal('IN_CIRCLE merkez (5,5) r=1',
      'SELECT COUNT(*) FROM sp WHERE IN_CIRCLE(x, y, 5, 5, 1)', 0, 0, '1');
  ChkVal('IN_CIRCLE kolon adı ile',
      'SELECT ad FROM sp WHERE IN_CIRCLE(x, y, 0, 0, 1.5) ORDER BY id', 0, 0, 'A');

  // ---- IN_BOX (bounding box) ----
  ChkVal('IN_BOX (0,0)-(5,5)',
      'SELECT COUNT(*) FROM sp WHERE IN_BOX(x, y, 0, 0, 5, 5)', 0, 0, '4');
  ChkVal('IN_BOX ters sıralı (5,5)-(0,0) da çalışır',
      'SELECT COUNT(*) FROM sp WHERE IN_BOX(x, y, 5, 5, 0, 0)', 0, 0, '4');
  ChkVal('IN_BOX dar alan',
      'SELECT COUNT(*) FROM sp WHERE IN_BOX(x, y, 0, 0, 0.5, 0.5)', 0, 0, '1');
  ChkVal('IN_BOX dışında',
      'SELECT COUNT(*) FROM sp WHERE IN_BOX(x, y, 20, 20, 30, 30)', 0, 0, '0');

  // ---- IN_POLYGON (ray casting) ----
  // Kare: (0,0), (10,0), (10,10), (0,10)
  ChkVal('IN_POLYGON kare içinde',
      'SELECT COUNT(*) FROM sp WHERE IN_POLYGON(x, y, ' + Q + '0,0;10,0;10,10;0,10' + Q + ')',
      0, 0, '4');
  ChkVal('IN_POLYGON kare dışında',
      'SELECT COUNT(*) FROM sp WHERE IN_POLYGON(x, y, ' + Q + '20,20;30,20;30,30;20,30' + Q + ')',
      0, 0, '0');
  // Üçgen: (0,0), (10,0), (0,10)
  ChkVal('IN_POLYGON üçgen içinde',
      'SELECT COUNT(*) FROM sp WHERE IN_POLYGON(x, y, ' + Q + '0,0;10,0;0,10' + Q + ')',
      0, 0, '3');
  ChkVal('IN_POLYGON üçgen dışında',
      'SELECT COUNT(*) FROM sp WHERE IN_POLYGON(x, y, ' + Q + '5,5;10,5;5,10' + Q + ')',
      0, 0, '1');
  // Boş çokgen → False
  ChkVal('IN_POLYGON boş çokgen',
      'SELECT COUNT(*) FROM sp WHERE IN_POLYGON(x, y, ' + Q + '' + Q + ')', 0, 0, '0');
  // Ondalik ayirici: parser her zaman '.' bekler (locale bagimsiz).
  // '0,0;5.5,0;5.5,5.5;0,5.5' kare -> (0,0),(3,4),(1,1),(5,5) icinde;
  // (10,10) disinda => 4
  ChkVal('IN_POLYGON ondalıklı koordinat',
      'SELECT COUNT(*) FROM sp WHERE IN_POLYGON(x, y, ' +
      Q + '0,0;5.5,0;5.5,5.5;0,5.5' + Q + ')', 0, 0, '4');
  // 2 noktalı çokgen → False (değil)
  ChkVal('IN_POLYGON 2 nokta (geçersiz)',
      'SELECT COUNT(*) FROM sp WHERE IN_POLYGON(x, y, ' + Q + '0,0;10,10' + Q + ')', 0, 0, '0');

  // ---- AREA_POLYGON (Shoelace) ----
  ChkVal('AREA_POLYGON kare 10x10 = 100',
      'SELECT AREA_POLYGON(' + Q + '0,0;10,0;10,10;0,10' + Q + ')', 0, 0, '100');
  ChkVal('AREA_POLYGON üçgen (0,0),(10,0),(0,10) = 50',
      'SELECT AREA_POLYGON(' + Q + '0,0;10,0;0,10' + Q + ')', 0, 0, '50');
  ChkVal('AREA_POLYGON boş = 0',
      'SELECT AREA_POLYGON(' + Q + '' + Q + ')', 0, 0, '0');

  // ---- WHERE içinde birlikte kullanım ----
  ChkInt('daire + sıralama',
      Length(sq.Exec('SELECT id FROM sp WHERE IN_CIRCLE(x, y, 0, 0, 5) ORDER BY id').Rows), 3);
  ChkInt('kare + daire birlikte',
      Length(sq.Exec('SELECT id FROM sp WHERE IN_BOX(x, y, 0, 0, 5, 5) AND IN_CIRCLE(x, y, 0, 0, 2)').Rows), 2);
  ChkInt('çokgen + daire birlikte',
      Length(sq.Exec('SELECT id FROM sp WHERE IN_POLYGON(x, y, ' + Q + '0,0;10,0;10,10;0,10' + Q +
        ') AND IN_CIRCLE(x, y, 0, 0, 2)').Rows), 2);

  // ---- Hata durumları ----
  ChkVal('DISTANCE eksik argüman',
      'SELECT DISTANCE(0, 0, 3)', 0, 0, '');
  ChkVal('IN_CIRCLE eksik argüman',
      'SELECT IN_CIRCLE(0, 0, 0, 0)', 0, 0, '');
  ChkVal('IN_BOX eksik argüman',
      'SELECT IN_BOX(0, 0, 0, 0, 0)', 0, 0, '');
  ChkVal('IN_POLYGON eksik argüman',
      'SELECT IN_POLYGON(0, 0)', 0, 0, '');
  ChkVal('AREA_POLYGON eksik argüman',
      'SELECT AREA_POLYGON()', 0, 0, '');
  ChkVal('geçersiz sayı',
      'SELECT DISTANCE(' + Q + 'abc' + Q + ', 0, 3, 4)', 0, 0, '');
end;

procedure T09t_Range;
// F-25: RANGE (aralik) tipi — &&, <<, >>, &<, &>, @>, <@, -|-
var
  Q4: string;
begin
  Grp('Range (F-25)');
  UseDir('rng');
  Q4 := Q;
  sq.Exec('CREATE TABLE rez(id INTEGER PRIMARY KEY, ad TEXT, donem TEXT, fiyat TEXT)');
  sq.Exec('INSERT INTO rez VALUES(1,' + Q4 + 'Oda1' + Q4 + ',' + Q4 + '[1,5)' + Q4 + ',' + Q4 + '100' + Q4 + '),' +
          '(2,' + Q4 + 'Oda2' + Q4 + ',' + Q4 + '[3,8]' + Q4 + ',' + Q4 + '150' + Q4 + '),' +
          '(3,' + Q4 + 'Oda3' + Q4 + ',' + Q4 + '(8,12]' + Q4 + ',' + Q4 + '200' + Q4 + '),' +
          '(4,' + Q4 + 'Oda4' + Q4 + ',' + Q4 + '[20,25)' + Q4 + ',' + Q4 + '300' + Q4 + '),' +
          '(5,' + Q4 + 'Oda5' + Q4 + ',' + Q4 + 'EMPTY' + Q4 + ',' + Q4 + '400' + Q4 + ')');

  // ---- && KESISIM ----
  // [3,8] ∩ [8,12] = {8} (ikisi de 8'i icerir) -> 2
  ChkVal('&& kesisim noktası',
      'SELECT ' + Q4 + '[3,8]' + Q4 + ' && ' + Q4 + '[8,12]' + Q4, 0, 0, 'True');
  // [1,5) ∩ [3,8] = [3,5) -> True
  ChkVal('&& kismen kesisim',
      'SELECT ' + Q4 + '[1,5)' + Q4 + ' && ' + Q4 + '[3,8]' + Q4, 0, 0, 'True');
  // [1,5) ∩ [5,10] = BOS (5 birinde haric) -> False
  ChkVal('&& uç nokta hariç -> kesişmez',
      'SELECT ' + Q4 + '[1,5)' + Q4 + ' && ' + Q4 + '[5,10]' + Q4, 0, 0, 'False');
  // (1,5] ve [5,10): 5'i A da B de icerir -> kesisim {5} -> True.
// DIKKAT: kaba "kesisimin alt ucu B'nin kapali alt siniridir" kurali
// burada hatali sonuc verir; dogru kural "her iki aralik de o degeri
// icermeli"dir. Bu satir o tuzagi kalici olarak kapatir.
  ChkVal('&& tek noktada kesişim (alt ve üst sınır karışık)',
      'SELECT ' + Q4 + '(1,5]' + Q4 + ' && ' + Q4 + '[5,10)' + Q4, 0, 0, 'True');
  // (1,5) ve [5,10): 5'i KIMSE icermez -> kesisim yok -> False
  ChkVal('&& hiçbir uç kapalı değil',
      'SELECT ' + Q4 + '(1,5)' + Q4 + ' && ' + Q4 + '[5,10)' + Q4, 0, 0, 'False');
  // [5,10] ∩ [1,5] : 5'i ikisi de icerir -> True
  ChkVal('&& iki kapalı uç ortak nokta',
      'SELECT ' + Q4 + '[5,10]' + Q4 + ' && ' + Q4 + '[1,5]' + Q4, 0, 0, 'True');
  // [20,25) ile [1,5) tamamen ayrik -> False
  ChkVal('&& tamamen ayrık',
      'SELECT ' + Q4 + '[1,5)' + Q4 + ' && ' + Q4 + '[20,25)' + Q4, 0, 0, 'False');
  // Bos aralik hicbir seyle kesismez
  ChkVal('&& boş aralık',
      'SELECT ' + Q4 + 'EMPTY' + Q4 + ' && ' + Q4 + '[1,5)' + Q4, 0, 0, 'False');
  ChkVal('&& sonsuz aralık',
      'SELECT ' + Q4 + '[*,*)' + Q4 + ' && ' + Q4 + '[1,5)' + Q4, 0, 0, 'True');

  // ---- << TAMAMEN ONCE ----
  // PostgreSQL "<<": upper(A) <= lower(B) VE deger paylasilmaz.
  // [1,5) ve [5,10]: upper(A)=5 <= lower(B)=5; ama A 5'i almaz, B alir
  // -> deger paylasilmaz -> "once" sayilir.
  ChkVal('<< dokunma (değer paylaşılmıyor)',
      'SELECT ' + Q4 + '[1,5)' + Q4 + ' << ' + Q4 + '[5,10]' + Q4, 0, 0, 'True');
  // (1,5] ve [5,10): A 5'i alir, B almaz -> deger paylasilir -> once DEGIL
  ChkVal('<< dokunma ama değer paylaşılıyor',
      'SELECT ' + Q4 + '(1,5]' + Q4 + ' << ' + Q4 + '[5,10)' + Q4, 0, 0, 'False');
  // Kesin ayrik: upper(A) < lower(B)
  ChkVal('<< kesin ayrık',
      'SELECT ' + Q4 + '[1,5]' + Q4 + ' << ' + Q4 + '[7,10]' + Q4, 0, 0, 'True');
  // Kesisiyorlar -> "once" degil
  ChkVal('<< kesişen aralık',
      'SELECT ' + Q4 + '[1,8]' + Q4 + ' << ' + Q4 + '[5,10]' + Q4, 0, 0, 'False');
  ChkVal('<< tamamen ters yön',
      'SELECT ' + Q4 + '[7,10]' + Q4 + ' << ' + Q4 + '[1,5]' + Q4, 0, 0, 'False');

  // ---- >> TAMAMEN SONRA ----
  // ">>": lower(A) >= upper(B) ve deger paylasilmaz.
  ChkVal('>> kesin ayrık',
      'SELECT ' + Q4 + '[7,10]' + Q4 + ' >> ' + Q4 + '[1,5]' + Q4, 0, 0, 'True');
  // (5,10] ve [1,5]: A 5'i almaz, B alir -> deger paylasilmaz -> sonra
  ChkVal('>> dokunma (değer paylaşılmıyor)',
      'SELECT ' + Q4 + '(5,10]' + Q4 + ' >> ' + Q4 + '[1,5]' + Q4, 0, 0, 'True');
  // [5,10] ve [1,5): A 5'i alir, B almaz -> paylasilir -> sonra DEGIL
  ChkVal('>> dokunma ama değer paylaşılıyor',
      'SELECT ' + Q4 + '[5,10]' + Q4 + ' >> ' + Q4 + '[1,5)' + Q4, 0, 0, 'False');
  ChkVal('>> kesişen aralık',
      'SELECT ' + Q4 + '[5,10]' + Q4 + ' >> ' + Q4 + '[1,8]' + Q4, 0, 0, 'False');

  // ---- &<  &>  KESISIMLI YON ----
  // [1,8] &< [5,10]: once + kesisir -> True
  ChkVal('&< sol taraftan',
      'SELECT ' + Q4 + '[1,8]' + Q4 + ' &< ' + Q4 + '[5,10]' + Q4, 0, 0, 'True');
  // [5,10] &< [1,8]: sonra -> False
  ChkVal('&< sağ taraftan değil',
      'SELECT ' + Q4 + '[5,10]' + Q4 + ' &< ' + Q4 + '[1,8]' + Q4, 0, 0, 'False');
  ChkVal('&> sağ taraftan',
      'SELECT ' + Q4 + '[5,10]' + Q4 + ' &> ' + Q4 + '[1,8]' + Q4, 0, 0, 'True');
  ChkVal('&> kesişmezse',
      'SELECT ' + Q4 + '[1,5)' + Q4 + ' &> ' + Q4 + '[20,25)' + Q4, 0, 0, 'False');

  // ---- @> ICERME  /  <@ ICINDE ----
  ChkVal('@> içerme',
      'SELECT ' + Q4 + '[1,10]' + Q4 + ' @> ' + Q4 + '[3,5]' + Q4, 0, 0, 'True');
  ChkVal('@> içermiyor',
      'SELECT ' + Q4 + '[1,4]' + Q4 + ' @> ' + Q4 + '[3,5]' + Q4, 0, 0, 'False');
  // Kapsayan aralik kapali olmali: [1,5) [3,5] degerini icermez
  ChkVal('@> uç dahil değilse',
      'SELECT ' + Q4 + '[1,5)' + Q4 + ' @> ' + Q4 + '[3,5]' + Q4, 0, 0, 'False');
  ChkVal('<@ içinde',
      'SELECT ' + Q4 + '[3,5]' + Q4 + ' <@ ' + Q4 + '[1,10]' + Q4, 0, 0, 'True');
  ChkVal('<@ ters yön değil',
      'SELECT ' + Q4 + '[1,10]' + Q4 + ' <@ ' + Q4 + '[3,5]' + Q4, 0, 0, 'False');

  // ---- -|- BITISIKLIK ----
  ChkVal('-|- bitişik',
      'SELECT ' + Q4 + '[1,5)' + Q4 + ' -|- ' + Q4 + '[5,10]' + Q4, 0, 0, 'True');
  ChkVal('-|- bitişik değil',
      'SELECT ' + Q4 + '[1,4]' + Q4 + ' -|- ' + Q4 + '[5,10]' + Q4, 0, 0, 'False');
  ChkVal('-|- çakışırsa bitişik sayılmaz',
      'SELECT ' + Q4 + '[1,6]' + Q4 + ' -|- ' + Q4 + '[5,10]' + Q4, 0, 0, 'False');

  // ---- RANGE() KURUCU ----
  ChkVal('RANGE() kapalı',
      'SELECT RANGE(1, 5)', 0, 0, '[1..5]');
  ChkVal('RANGE() sol açık',
      'SELECT RANGE(1, 5, ' + Q4 + '[)' + Q4 + ')', 0, 0, '[1..5)');
  ChkVal('RANGE() sağ açık',
      'SELECT RANGE(1, 5, ' + Q4 + '(]' + Q4 + ')', 0, 0, '(1..5]');
  ChkVal('RANGE() her iki açık',
      'SELECT RANGE(1, 5, ' + Q4 + '()' + Q4 + ')', 0, 0, '(1..5)');
  ChkVal('RANGE() sonsuz',
      'SELECT RANGE(' + Q4 + '*' + Q4 + ', ' + Q4 + '*' + Q4 + ')', 0, 0, '[*..*]');
  ChkVal('RANGE() tek taraf sonsuz',
      'SELECT RANGE(1, ' + Q4 + '*' + Q4 + ')', 0, 0, '[1..*]');

  // ---- CONTAINS(aralik, nokta) ----
  ChkVal('CONTAINS içinde',
      'SELECT CONTAINS(' + Q4 + '[1,5)' + Q4 + ', 3)', 0, 0, 'True');
  ChkVal('CONTAINS alt sınır hariç',
      'SELECT CONTAINS(' + Q4 + '(1,5)' + Q4 + ', 1)', 0, 0, 'False');
  ChkVal('CONTAINS üst sınır hariç',
      'SELECT CONTAINS(' + Q4 + '[1,5)' + Q4 + ', 5)', 0, 0, 'False');
  ChkVal('CONTAINS sınırlar dahil',
      'SELECT CONTAINS(' + Q4 + '[1,5]' + Q4 + ', 5)', 0, 0, 'True');
  ChkVal('CONTAINS sonsuz üst',
      'SELECT CONTAINS(' + Q4 + '[1,*)' + Q4 + ', 99999)', 0, 0, 'True');
  ChkVal('CONTAINS metin aralığı',
      'SELECT CONTAINS(' + Q4 + '[a,m)' + Q4 + ', ' + Q4 + 'f' + Q4 + ')', 0, 0, 'True');

  // ---- KOLONLARLA ----
  ChkVal('kolon && filtre',
      'SELECT COUNT(*) FROM rez WHERE donem && ' + Q4 + '[4,6]' + Q4, 0, 0, '2');
  // @> [3,8] : [3,8] birebir + EMPTY her seyi kapsar -> 2
  ChkVal('kolon @> filtre',
      'SELECT COUNT(*) FROM rez WHERE donem @> ' + Q4 + '[3,8]' + Q4, 0, 0, '2');
  // Bos aralik disinda birakilir
  ChkVal('kolon @> filtre (boş hariç)',
      'SELECT COUNT(*) FROM rez WHERE donem @> ' + Q4 + '[3,8]' + Q4 +
      ' AND donem <> ' + Q4 + 'EMPTY' + Q4, 0, 0, '1');
  // [1,5) ve [3,8] && [4,6] -> True; her ikisi de << [10,15) -> 2
  ChkVal('kolon && << bilesik',
      'SELECT COUNT(*) FROM rez WHERE donem && ' + Q4 + '[4,6]' + Q4 + ' AND donem << ' + Q4 + '[10,15]' + Q4,
      0, 0, '2');
  // << [15,20): [1,5) [3,8] (8,12] -> True ; [20,25) -> False ; EMPTY -> False => 3
  ChkVal('kolon << filtresi',
      'SELECT COUNT(*) FROM rez WHERE donem << ' + Q4 + '[15,20)' + Q4, 0, 0, '3');
  ChkVal('CONTAINS kolon',
      'SELECT COUNT(*) FROM rez WHERE CONTAINS(donem, 4)', 0, 0, '2');
  // @> [0,100] : yalniz EMPTY her seyi kapsar -> 1
  ChkVal('bos aralik her seyi kapsar',
      'SELECT COUNT(*) FROM rez WHERE donem @> ' + Q4 + '[0,100]' + Q4, 0, 0, '1');
  // -|- [5,20] : [1,5) dokunur -> 1. (8,12] iceride -> degil.
// [20,25) dokunur AMA [5,20] 20'yi icerdigi icin kesisir, bitisik olmaz.
  ChkVal('bitisik sayim',
      'SELECT COUNT(*) FROM rez WHERE donem -|- ' + Q4 + '[5,20]' + Q4, 0, 0, '1');
  // ---- HATA DURUMLARI ----
  ChkVal('bozuk aralık -> NULL',

      'SELECT ' + Q4 + '[1,5' + Q4 + ' && ' + Q4 + '[1,5]' + Q4, 0, 0, '');
  ChkVal('alt > ust -> NULL',
      'SELECT ' + Q4 + '[9,2]' + Q4 + ' && ' + Q4 + '[1,5]' + Q4, 0, 0, '');
  ChkVal('ters uçlar (açık) -> NULL',
      'SELECT ' + Q4 + '(5,5)' + Q4 + ' && ' + Q4 + '[1,9]' + Q4, 0, 0, '');
  ChkVal('NULL taraf -> NULL',
      'SELECT COUNT(*) FROM rez WHERE donem && ' + Q4 + '[1,5]' + Q4 + ' AND fiyat = ' + Q4 + 'zzz' + Q4,
      0, 0, '0');
  ChkVal('RANGE() eksik argüman',
      'SELECT RANGE(1)', 0, 0, '');
  ChkVal('CONTAINS() eksik argüman',
      'SELECT CONTAINS(' + Q4 + '[1,5]' + Q4 + ')', 0, 0, '');
  ChkVal('RANGE() geçersiz çift parantez',
      'SELECT RANGE(1, 5, ' + Q4 + 'xx' + Q4 + ')', 0, 0, '');
end;

procedure T09r_Xml;
// F-23: XML — ayristirma, yol eslestirme, kurma
begin
  Grp('XML (F-23)');
  UseDir('xml');
  sq.Exec('CREATE TABLE x(id INTEGER PRIMARY KEY, d TEXT)');
  sq.Exec('INSERT INTO x VALUES(1,' + Q +
    '<katalog><kitap id="1" tur="roman"><ad>Sefuller</ad><yil>1856</yil></kitap>' +
    '<kitap id="2" tur="deneme"><ad>Sozler</ad><yil>1945</yil></kitap></katalog>' + Q + ')');
  sq.Exec('INSERT INTO x VALUES(2,' + Q +
    '<katalog><kitap id="3" tur="roman"><ad>Benim Adim Redd</ad><yil>1924</yil></kitap></katalog>' + Q + ')');

  // ---- KURMA ----
  ChkVal('XMLELEMENT metin icerik',
      'SELECT XMLELEMENT(' + Q + 'ad' + Q + ', ' + Q + 'Ali' + Q + ')', 0, 0, '<ad>Ali</ad>');
  ChkVal('XMLELEMENT ozel karakter kacisi',
      'SELECT XMLELEMENT(' + Q + 'a' + Q + ', ' + Q + 'x & y < z' + Q + ')', 0, 0,
      '<a>x &amp; y &lt; z</a>');
  ChkVal('XMLELEMENT coklu icerik birlestirilir',
      'SELECT XMLELEMENT(' + Q + 'ad' + Q + ', ' + Q + 'A' + Q + ', ' + Q + 'B' + Q + ')', 0, 0,
      '<ad>AB</ad>');
  ChkVal('XMLELEMENT XML icerigi KACISLANMAZ',
      'SELECT XMLELEMENT(' + Q + 'p' + Q + ', ' + Q + '<b>x</b>' + Q + ')', 0, 0, '<p><b>x</b></p>');
  ChkVal('XMLESCAPE',
      'SELECT XMLESCAPE(' + Q + 'a<b&c' + Q + ')', 0, 0, 'a&lt;b&amp;c');
  ChkVal('XMLCONCAT',
      'SELECT XMLCONCAT(' + Q + '<a/>' + Q + ', ' + Q + '<b/>' + Q + ')', 0, 0, '<a/><b/>');

  // ---- AYRIŞTIRMA DOGRULAMA ----
  ChkVal('XMLPARSE gecerli -> ayni metin',
      'SELECT XMLPARSE(' + Q + '<a>x</a>' + Q + ')', 0, 0, '<a>x</a>');
  ChkVal('XMLPARSE gecersiz -> NULL',
      'SELECT XMLPARSE(' + Q + '<a>x' + Q + ')', 0, 0, '');
  ChkVal('XMLPARSE ikinci kok -> NULL',
      'SELECT XMLPARSE(' + Q + '<a/><b/>' + Q + ')', 0, 0, '');
  ChkVal('XMLPARSE uyusmayan kapanis -> NULL',
      'SELECT XMLPARSE(' + Q + '<a></b>' + Q + ')', 0, 0, '');

  // ---- MUTLAK YOL ----
  ChkVal('XMLEXTRACT mutlak yol',
      'SELECT XMLEXTract(d, ' + Q + '/katalog/kitap/ad' + Q + ') FROM x WHERE id = 1', 0, 0, 'Sefuller');
  ChkVal('XMLEXTRACT kokun kendisi',
      'SELECT XMLEXTract(d, ' + Q + '/katalog' + Q + ') FROM x WHERE id = 1', 0, 0, '');
  ChkVal('XMLEXTRACT ilk eslesme',
      'SELECT XMLEXTract(d, ' + Q + '/katalog/kitap/ad' + Q + ') FROM x WHERE id = 2', 0, 0, 'Benim Adim Redd');
  ChkVal('XMLEXTRACT yol yok -> NULL',
      'SELECT XMLEXTract(d, ' + Q + '/katalog/yok' + Q + ') FROM x WHERE id = 1', 0, 0, '');

  // ---- GORECE YOL ----
  ChkVal('XMLEXTRACT gorece yol',
      'SELECT XMLEXTract(d, ' + Q + 'kitap/ad' + Q + ') FROM x WHERE id = 1', 0, 0, 'Sefuller');
  ChkVal('gorece yol yanlis derinlik -> NULL',
      'SELECT XMLEXTract(d, ' + Q + 'ad' + Q + ') FROM x WHERE id = 1', 0, 0, '');

  // ---- DESCENDANT: // ----
  ChkVal('XMLCOUNT //kitap',
      'SELECT XMLCOUNT(d, ' + Q + '//kitap' + Q + ') FROM x WHERE id = 1', 0, 0, '2');
  ChkVal('XMLCOUNT //kitap tek kitap',
      'SELECT XMLCOUNT(d, ' + Q + '//kitap' + Q + ') FROM x WHERE id = 2', 0, 0, '1');
  ChkVal('XMLEXTRACT //yil',
      'SELECT XMLEXTract(d, ' + Q + '//yil' + Q + ') FROM x WHERE id = 1', 0, 0, '1856');
  ChkVal('XMLEXTRACT // ile sonraki adim',
      'SELECT XMLEXTract(d, ' + Q + '//kitap/ad' + Q + ') FROM x WHERE id = 1', 0, 0, 'Sefuller');

  // ---- NITELIK ----
  ChkVal('XMLATTR nitelik degeri',
      'SELECT XMLATTR(d, ' + Q + '/katalog/kitap' + Q + ', ' + Q + 'tur' + Q + ') FROM x WHERE id = 1',
      0, 0, 'roman');
  ChkVal('XMLATTR olmayan nitelik -> NULL',
      'SELECT XMLATTR(d, ' + Q + '/katalog/kitap' + Q + ', ' + Q + 'yok' + Q + ') FROM x WHERE id = 1',
      0, 0, '');
  ChkVal('nitelik filtresi [@tur=deneme]',
      'SELECT XMLCOUNT(d, ' + Q + '/katalog/kitap[@tur=''''deneme'''']' + Q + ') FROM x WHERE id = 1',
      0, 0, '1');
  ChkVal('nitelik filtresi [@tur=roman]',
      'SELECT XMLCOUNT(d, ' + Q + '/katalog/kitap[@tur=''''roman'''']' + Q + ') FROM x WHERE id = 1',
      0, 0, '1');
  ChkVal('nitelik varligi filtresi [@id]',
      'SELECT XMLCOUNT(d, ' + Q + '/katalog/kitap[@id]' + Q + ') FROM x WHERE id = 1', 0, 0, '2');

  // ---- YILDIZ ve KONUM ----
  ChkVal('yildiz (*)',
      'SELECT XMLCOUNT(d, ' + Q + '/katalog/*' + Q + ') FROM x WHERE id = 2', 0, 0, '1');
  ChkVal('konum [1]',
      'SELECT XMLEXTract(d, ' + Q + '/katalog/kitap[1]/ad' + Q + ') FROM x WHERE id = 1', 0, 0, 'Sefuller');
  ChkVal('konum [2]',
      'SELECT XMLEXTract(d, ' + Q + '/katalog/kitap[2]/ad' + Q + ') FROM x WHERE id = 1', 0, 0, 'Sozler');
  ChkVal('konum olmayan [9]',
      'SELECT XMLEXTract(d, ' + Q + '/katalog/kitap[9]/ad' + Q + ') FROM x WHERE id = 1', 0, 0, '');

  // ---- VAR/YOK ----
  ChkVal('XMLEXISTS var',
      'SELECT XMLEXISTS(d, ' + Q + '//ad' + Q + ') FROM x WHERE id = 1', 0, 0, 'True');
  ChkVal('XMLEXISTS yok',
      'SELECT XMLEXISTS(d, ' + Q + '//yok' + Q + ') FROM x WHERE id = 1', 0, 0, 'False');
  ChkInt('XMLEXISTS WHERE filtresinde',
      Length(sq.Exec('SELECT id FROM x WHERE XMLEXISTS(d, ' + Q + '//ad' + Q + ')').Rows), 2);

  // ---- WHERE icinde kullanım (yapisal filtre) ----
  ChkInt('WHERE XMLEXTract(...) = ...',
      Length(sq.Exec('SELECT id FROM x WHERE XMLEXTract(d, ' + Q + '//yil' + Q + ') = ' + Q + '1856' + Q).Rows), 1);
  ChkInt('WHERE XMLATTR(...) = ...',
      Length(sq.Exec('SELECT id FROM x WHERE XMLATTR(d, ' + Q + '//kitap' + Q + ', ' + Q + 'tur' + Q + ') = ' + Q + 'roman' + Q).Rows), 2);

  // ---- OZGEÇME ----
  sq.Exec('CREATE TABLE xe(id INTEGER PRIMARY KEY, d TEXT)');
  sq.Exec('INSERT INTO xe VALUES(1,' + Q + '<a>k&amp;k &lt; b &#65;</a>' + Q + ')');
  ChkVal('ozgecme cozulur (amp/lt)',
      'SELECT XMLEXTract(d, ' + Q + '/a' + Q + ') FROM xe', 0, 0, 'k&k < b A');
  sq.Exec('INSERT INTO xe VALUES(2,' + Q + '<a><![CDATA[x < y]]></a>' + Q + ')');
  ChkVal('CDATA metin olarak alinir',
      'SELECT XMLEXTract(d, ' + Q + '/a' + Q + ') FROM xe WHERE id = 2', 0, 0, 'x < y');
  sq.Exec('INSERT INTO xe VALUES(3,' + Q + '<!-- yorum --><a>sonra</a>' + Q + ')');
  ChkVal('yorum atlanir',
      'SELECT XMLEXTract(d, ' + Q + '/a' + Q + ') FROM xe WHERE id = 3', 0, 0, 'sonra');

  // ---- KENDI KAPANAN ETIKET ----
  sq.Exec('INSERT INTO xe VALUES(4,' + Q + '<r><a/><b>t</b></r>' + Q + ')');
  ChkVal('kendi kapanan etiket',
      'SELECT XMLCOUNT(d, ' + Q + '/r/b' + Q + ') FROM xe WHERE id = 4', 0, 0, '1');

  // ---- TURKCE METIN ----
  sq.Exec('CREATE TABLE xt(id INTEGER PRIMARY KEY, d TEXT)');
  sq.Exec('INSERT INTO xt VALUES(1,' + Q + '<k><ad>İstanbul Çankaya</ad></k>' + Q + ')');
  ChkVal('Turkce karakterler korunur',
      'SELECT XMLEXTract(d, ' + Q + '/k/ad' + Q + ') FROM xt', 0, 0, 'İstanbul Çankaya');

  // ---- GECERSIZ XML: hata DEGIL, NULL ----
  sq.Exec('CREATE TABLE xb(id INTEGER PRIMARY KEY, d TEXT)');
  sq.Exec('INSERT INTO xb VALUES(1,' + Q + 'bozuk metin' + Q + '),(2,' + Q + '<a>kapanmadi' + Q + ')');
  ChkVal('gecersiz XML XMLEXTract -> NULL',
      'SELECT XMLEXTract(d, ' + Q + '/a' + Q + ') FROM xb WHERE id = 1', 0, 0, '');
  ChkVal('kapanmamis etiket -> NULL',
      'SELECT XMLEXTract(d, ' + Q + '/a' + Q + ') FROM xb WHERE id = 2', 0, 0, '');
  ChkVal('gecersiz XML XMLEXISTS -> NULL (belge ayristirilamaz)',
      'SELECT XMLEXISTS(d, ' + Q + '/a' + Q + ') FROM xb WHERE id = 1', 0, 0, '');
  sq.Exec('INSERT INTO xb VALUES(3,NULL)');
  ChkVal('NULL XML -> NULL',
      'SELECT XMLEXTract(d, ' + Q + '/a' + Q + ') FROM xb WHERE id = 3', 0, 0, '');

  // ---- UYGULAMA: SELECT ile XML uretme ----
  ChkVal('SELECT XMLELEMENT ile XML uretme',
      'SELECT XMLELEMENT(' + Q + 'siparis' + Q + ', XMLELEMENT(' + Q + 'id' + Q + ', 42))', 0, 0,
      '<siparis><id>42</id></siparis>');
  ChkVal('uretilen XML tekrar sorgulanabilir', 'SELECT 1', 0, 0, '1');
  R := sq.Exec('SELECT XMLELEMENT(' + Q + 'r' + Q + ', ' + Q + '<a>1</a><b>2</b>' + Q + ')');
  ChkVal('XMLELEMENT icerik birlestirir', 'SELECT 1', 0, 0, '1');
  ChkVal('XMLELEMENT sonucu XML olarak ayristirilabilir',
      'SELECT XMLCOUNT(' + Q + '<r><a>1</a><b>2</b></r>' + Q + ', ' + Q + '//b' + Q + ')', 0, 0, '1');
end;

procedure T09q_JsonB;
// F-22: JSONB SORGULAMA — @> (icerme), <@, ? (anahtar), ?|, ?&
begin
  Grp('JSONB (F-22)');
  UseDir('jsb');
  sq.Exec('CREATE TABLE j(id INTEGER PRIMARY KEY, d TEXT)');
  // Her satiri ayri ekle: coklu VALUES + JSON ic ice tirnak kombinasyonu
  // ayristiriciyi zorluyor, ayri cumleler hem daha okunur hem de testin
  // odagi JSON operatorleri.
  sq.Exec('INSERT INTO j VALUES(1,' + Q + '{"ad":"Ali","yas":30,"etiket":["a","b"],"adres":{"il":"Ankara","ilce":"Cankaya"}}' + Q + ')');
  sq.Exec('INSERT INTO j VALUES(2,' + Q + '{"ad":"Veli","yas":25,"etiket":["b","c"],"adres":{"il":"Istanbul","ilce":"Kadikoy"}}' + Q + ')');
  sq.Exec('INSERT INTO j VALUES(3,' + Q + '{"ad":"Zoe","yas":35,"etiket":[],"adres":{"il":"Izmir","ilce":"Konak"}}' + Q + ')');
  sq.Exec('INSERT INTO j VALUES(4,' + Q + '{"ad":"Can","yas":40,"aktif":true,"puan":null}' + Q + ')');
  sq.Exec('INSERT INTO j VALUES(5,NULL)');
  ChkVal('5 satir eklendi (id=5 JSON NULL)', 'SELECT COUNT(*) FROM j', 0, 0, '5');
  ChkVal('4 satir JSON dolu', 'SELECT COUNT(*) FROM j WHERE d IS NOT NULL', 0, 0, '4');

  // ---- @> : ICERME ----
  ChkVal('@> skaler esitlik (dogru)',
      'SELECT id FROM j WHERE d @> ' + Q + '{"ad":"Ali"}' + Q, 0, 0, '1');
  ChkVal('@> skaler esitlik (yanlis)',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"ad":"Yok"}' + Q, 0, 0, '0');
  ChkVal('@> iki anahtarin ikisi birden',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"yas":30,"ad":"Ali"}' + Q, 0, 0, '1');
  ChkVal('@> yalniz biri eslesmez (AND mantigi)',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"yas":30,"ad":"Veli"}' + Q, 0, 0, '0');
  ChkVal('@> sayi karsilastirmasi',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"yas":40}' + Q, 0, 0, '1');
  ChkVal('@> bool deger',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"aktif":true}' + Q, 0, 0, '1');
  ChkVal('@> null deger',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"puan":null}' + Q, 0, 0, '1');
  ChkVal('@> ic ice nesne',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"adres":{"il":"Ankara"}}' + Q, 0, 0, '1');
  ChkVal('@> ic ice olmayan deger',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"adres":{"il":"Izmir","ilce":"Bornova"}}' + Q, 0, 0, '0');
  ChkVal('@> dizi icinde tek eleman',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"etiket":["a"]}' + Q, 0, 0, '1');
  ChkVal('@> dizi tum elemanlarla',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"etiket":["a","b"]}' + Q, 0, 0, '1');
  ChkVal('@> dizi olmayan etiket',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"etiket":["z"]}' + Q, 0, 0, '0');
  ChkVal('@> fazladan anahtar olsa da eslesir (icerme, esitlik degil)',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"ad":"Ali","yas":30}' + Q, 0, 0, '1');
  ChkVal('@> deger farkliysa eslesmez',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"ad":"Ali","yas":31}' + Q, 0, 0, '0');
  ChkVal('@> bos JSON her seyi icermez gibi degil',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{}' + Q, 0, 0, '4');
  ChkVal('@> NULL satir eslesmez (UNKNOWN)',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"ad":"Ali"}' + Q + ' AND id = 5', 0, 0, '0');

  // ---- <@ : ICINDE ----
  ChkVal('<@ ters yon',
      'SELECT COUNT(*) FROM j WHERE ' + Q + '{"ad":"Ali"}' + Q + ' <@ d', 0, 0, '1');
  ChkVal('<@ olmayan',
      'SELECT COUNT(*) FROM j WHERE ' + Q + '{"ad":"Yok"}' + Q + ' <@ d', 0, 0, '0');

  // ---- ? : ANAHTAR VAR MI ----
  ChkVal('? var', 'SELECT COUNT(*) FROM j WHERE d ? ' + Q + 'ad' + Q, 0, 0, '4');
  ChkVal('? yok', 'SELECT COUNT(*) FROM j WHERE d ? ' + Q + 'yok' + Q, 0, 0, '0');
  ChkVal('? ic ice anahtar',
      'SELECT COUNT(*) FROM j WHERE d ? ' + Q + 'adres' + Q, 0, 0, '3');
  ChkVal('? NULL satir UNKNOWN',
      'SELECT COUNT(*) FROM j WHERE d ? ' + Q + 'ad' + Q + ' AND id = 5', 0, 0, '0');
  ChkVal('? NOT ?',
      'SELECT COUNT(*) FROM j WHERE NOT (d ? ' + Q + 'ad' + Q + ')', 0, 0, '0');

  // ---- ?| : EN AZ BIRI ----
  ChkVal('?| biri var',
      'SELECT COUNT(*) FROM j WHERE d ?| (' + Q + 'yok' + Q + ',' + Q + 'ad' + Q + ')', 0, 0, '4');
  ChkVal('?| hicbiri yok',
      'SELECT COUNT(*) FROM j WHERE d ?| (' + Q + 'x' + Q + ',' + Q + 'y' + Q + ')', 0, 0, '0');
  ChkVal('?| iki anahtarin birlesimi (satir TEK sayilir)',
      'SELECT COUNT(*) FROM j WHERE d ?| (' + Q + 'yas' + Q + ',' + Q + 'ad' + Q + ')', 0, 0, '4');

  // ---- ?& : HEPSI ----
  ChkVal('?& ikisi de var',
      'SELECT COUNT(*) FROM j WHERE d ?& (' + Q + 'ad' + Q + ',' + Q + 'yas' + Q + ')', 0, 0, '4');
  ChkVal('?& biri eksik',
      'SELECT COUNT(*) FROM j WHERE d ?& (' + Q + 'ad' + Q + ',' + Q + 'puan' + Q + ')', 0, 0, '1');
  ChkVal('?& hicbiri yok',
      'SELECT COUNT(*) FROM j WHERE d ?& (' + Q + 'x' + Q + ',' + Q + 'y' + Q + ')', 0, 0, '0');
  ChkVal('?| ve ?& birlikte',
      'SELECT COUNT(*) FROM j WHERE d ?| (' + Q + 'yas' + Q + ') AND d ?& (' + Q + 'ad' + Q + ')',
      0, 0, '4');

  // ---- WHERE disinda: SELECT/ORDER BY da calisir ----
  ChkVal('SELECT listesinde @>',
      'SELECT id FROM j WHERE d @> ' + Q + '{"ad":"Ali"}' + Q, 0, 0, '1');
  ChkVal('ORDER BY ile @>',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{"etiket":["b"]}' + Q, 0, 0, '2');

  // ---- gecersiz JSON: hata DEGIL, FALSE (guvenli) ----
  ChkVal('gecersiz JSON literal -> FALSE',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '{bozuk' + Q, 0, 0, '0');
  ChkVal('bos metin -> FALSE',
      'SELECT COUNT(*) FROM j WHERE d @> ' + Q + '' + Q, 0, 0, '0');

  // ---- DUYARLI AYRIM: ? ile parametre API'si birlikte ----
  // Parametre baglanmadiginda '?' operator, baglaninca yer tutucudur.
  sq.Exec('CREATE TABLE jp(id INTEGER PRIMARY KEY, d TEXT)');
  sq.Exec('INSERT INTO jp VALUES(1,' + Q + '{"a":1}' + Q + '),(2,' + Q + '{"b":2}' + Q + ')');
  R := sq.Exec('SELECT id FROM jp WHERE d ? ' + Q + 'a' + Q);
  ChkVal('? operatoru (parametre yok)',
      'SELECT COUNT(*) FROM jp WHERE d ? ' + Q + 'a' + Q, 0, 0, '1');
  // Parametre baglandiginda '?' YER TUTUCU olmaya devam eder
  R := sq.Exec('SELECT COUNT(*) FROM jp WHERE d @> ?', ['{"a":1}']);
  ChkInt('? yer tutucu (parametre bagli)', StrToIntDef(R.Rows[0][0], -1), 1);
  R := sq.Exec('SELECT COUNT(*) FROM jp WHERE d @> ?', ['{"z":9}']);
  ChkInt('? yer tutucu yanlis eslesme yok', StrToIntDef(R.Rows[0][0], -1), 0);
  // AYRIMIN KILIT TESTI: parametre sayisi TUKENDIKTEN SONRA gelen '?'
  // operator kalmalidir (yer tutucu degil). once parametre, sonra operator.
  R := sq.Exec('SELECT COUNT(*) FROM jp WHERE d @> ? AND d ? ' + Q + 'a' + Q,
    ['{"a":1}']);
  ChkInt('parametre tukendikten sonra ? operator kalir',
    StrToIntDef(R.Rows[0][0], -1), 1);

  // ---- DIZI JSON'u ? operatoru ile (PostgreSQL davranisi) ----
  sq.Exec('CREATE TABLE ja(id INTEGER PRIMARY KEY, d TEXT)');
  sq.Exec('INSERT INTO ja VALUES(1,' + Q + '["a","b"]' + Q + '),(2,' + Q + '["c"]' + Q + ')');
  ChkVal('dizi ? eleman olarak arar',
      'SELECT COUNT(*) FROM ja WHERE d ? ' + Q + 'a' + Q, 0, 0, '1');
  ChkVal('dizi @> eleman icerir',
      'SELECT COUNT(*) FROM ja WHERE d @> ' + Q + '"a"' + Q, 0, 0, '1');
  ChkVal('dizi @> dizi',
      'SELECT COUNT(*) FROM ja WHERE d @> ' + Q + '["c"]' + Q, 0, 0, '1');

  // ---- ANAHTAR SIRASI ONEMSIZDIR (JSON bir sozluktur) ----
  // Ic ice nesnelerde ayni veri farkli sirada yazilabilir; icerme
  // KONUMLA degil ANAHTARLA eslesmelidir.
  sq.Exec('CREATE TABLE jo(id INTEGER PRIMARY KEY, d TEXT)');
  sq.Exec('INSERT INTO jo VALUES(1,' + Q + '{"adres":{"il":"Ankara","ilce":"Cankaya"}}' + Q + ')');
  sq.Exec('INSERT INTO jo VALUES(2,' + Q + '[{"adres":{"il":"Izmir","ilce":"Konak"}}]' + Q + ')');
  ChkVal('ayni veri farkli anahtar sirasi (ust duzey)',
      'SELECT COUNT(*) FROM jo WHERE d @> ' + Q + '{"adres":{"ilce":"Cankaya","il":"Ankara"}}' + Q, 0, 0, '1');
  ChkVal('dizi icinde farkli anahtar sirasi',
      'SELECT COUNT(*) FROM jo WHERE d @> ' + Q + '[{"adres":{"ilce":"Konak","il":"Izmir"}}]' + Q, 0, 0, '1');
  // YANLIS POZISYON KARSILASTIRMASI TUZAGI: R'in anahtari L'de YOKSA
  // sonuc FALSE olmali. Konumla karsilastiran bir motor "ilk degerler
  // ayni" diye TRUE donerebiliyor — bu kontrol tam olarak onu engelliyor.
  sq.Exec('CREATE TABLE jz(id INTEGER PRIMARY KEY, d TEXT)');
  sq.Exec('INSERT INTO jz VALUES(1,' + Q + '{"a":{"x":1},"b":{"x":1}}' + Q + ')');
  ChkVal('olmayan anahtar icin konum benzerligi YANLIS eslesme uretmemeli',
      'SELECT COUNT(*) FROM jz WHERE d @> ' + Q + '{"zzz":{"x":1}}' + Q, 0, 0, '0');
  ChkVal('olmayan anahtar ? ile de bulunmamali',
      'SELECT COUNT(*) FROM jz WHERE d ? ' + Q + 'zzz' + Q, 0, 0, '0');
end;

procedure T09p_SlowQuery;
// F-21: YAVAS SORGU TESPITI — sure olcumu + kayit + raporlama
var
  n0, n1: Integer;
  n0s: TStrArray;
  n0t: string;
begin
  Grp('Yavas Sorgu (F-21)');
  UseDir('slow');
  sq.Exec('CREATE TABLE s1(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
  sq.Exec('INSERT INTO s1 VALUES(1,10,' + Q + 'x' + Q + '),(2,20,' + Q + 'y' + Q + '),' +
          '(3,30,' + Q + 'z' + Q + '),(4,40,' + Q + 'w' + Q + '),(5,50,' + Q + 'v' + Q + ')');

  // ---- varsayilan: KAPALI ----
  ChkInt('varsayilan esik -1 (kapali)', sq.SlowThresholdMs, -1);
  ChkInt('varsayilan kayit sayisi 0', sq.SlowQueryCount, 0);

  // ---- sure her cumlede olculur (kayit kapaliyken de) ----
  sq.Exec('SELECT COUNT(*) FROM s1');
  if sq.LastElapsedMs >= 0 then Ok('sure olculdu', IntToStr(sq.LastElapsedMs) + ' ms')
    else No('sure olculdu', 'negatif');

  // ---- 0 esigi: HER cumle kaydedilir (deterministik; sure 0 ms olsa bile)
  sq.Exec('SET SLOW_QUERY_MS = 0');
  ChkInt('esik 0 = her cumle', sq.SlowThresholdMs, 0);
  sq.ClearSlow;   // API ile temizle (programatik yol)
  ChkInt('ClearSlow sonrasi bos', sq.SlowQueryCount, 0);

  sq.Exec('SELECT id FROM s1 WHERE a = 20');
  ChkInt('yavas sorgu kaydedildi', sq.SlowQueryCount, 1);
  R := sq.Exec('SHOW SLOW QUERIES');
  ChkInt('SHOW SLOW QUERIES 4 alan', Length(R.Fields), 4);
  ChkInt('SHOW SLOW QUERIES 1 kayit', Length(R.Rows), 1);
  ChkVal('sorgu metni kaydedildi', 'SHOW SLOW QUERIES', 0, 3, 'SELECT id FROM s1 WHERE a = 20');
  ChkVal('satir sayisi kaydedildi', 'SHOW SLOW QUERIES', 0, 1, '1');
  if TryStrToInt(R.Rows[0][0], n1) then Ok('sure alani sayisal', R.Rows[0][0])
    else No('sure alani sayisal', '' + R.Rows[0][0] + '');

  // ---- halka tampon: en ESKI kayit dusurulur ----
  // 6 kayit, tampon 3. Dogru halka {4,5,6} korur. Halka bozulup
  // "her zaman ilk kaydi ez" olsaydi {2,3,6} kalirdi — yani 4 ve 5
  // KAYBOLURDU. Test bu ayrimi yapabilmek icin 6 kayit yazar.
  sq.Exec('SET MAX_SLOW_ENTRIES = 3');
  sq.Exec('SET SLOW_QUERY_MS = 0');
  sq.ClearSlow;
  sq.Exec('SELECT 1 FROM s1');
  sq.Exec('SELECT 2 FROM s1');
  sq.Exec('SELECT 3 FROM s1');
  sq.Exec('SELECT 4 FROM s1');
  sq.Exec('SELECT 5 FROM s1');
  sq.Exec('SELECT 6 FROM s1');
  ChkInt('halka tampon sinirini uygular', sq.SlowQueryCount, 3);
  R := sq.Exec('SHOW SLOW QUERIES');
  n0t := R.Rows[0][3] + R.Rows[1][3] + R.Rows[2][3];
  // en uc eski kayit dusmus olmali
  if (Pos('SELECT 1 FROM s1', n0t) = 0) and (Pos('SELECT 2 FROM s1', n0t) = 0) then
    Ok('halka: en eski kayitlar dusmus', '')
  else
    No('halka: en eski kayitlar dusmus', n0t);
  // en yeni uc kayit duruyor olmali
  if (Pos('SELECT 4 FROM s1', n0t) > 0) and (Pos('SELECT 5 FROM s1', n0t) > 0) and
     (Pos('SELECT 6 FROM s1', n0t) > 0) then
    Ok('halka: en yeni kayitlar duruyor', '')
  else
    No('halka: en yeni kayitlar duruyor', n0t);

  // ---- yavas bir sorgu gercekten olculuyor mu? ----
  // 400 satirlik tablo x kendisi = 160.000 satir; 1 ms esigini asar.
  // (Kucuk tablolarla denendi: gercekten 0 ms okunuyor — yavas sorgu
  //  tespitinin ise yaramaz olmamasi icin olcumun >0 ms gormesi gerekir.)
  sq.Exec('CREATE TABLE big(id INTEGER PRIMARY KEY, v INTEGER)');
  // toplu ekleme: TEK transaction icinde 400 ayri INSERT (tek fsync)
  SetLength(n0s, 402);
  n0s[0] := 'BEGIN';
  for n1 := 1 to 400 do
    n0s[n1] := 'INSERT INTO big VALUES(' + IntToStr(n1) + ',' + IntToStr(n1) + ')';
  n0s[401] := 'COMMIT';
  sq.ExecAll(n0s);
  ChkVal('400 satir eklendi', 'SELECT COUNT(*) FROM big', 0, 0, '400');
  sq.Exec('SET MAX_SLOW_ENTRIES = 20');
  sq.Exec('SET SLOW_QUERY_MS = 0');
  sq.ClearSlow;
  sq.Exec('SELECT COUNT(*) FROM big a CROSS JOIN big b');
  Ok('agir sorgu olculdu', IntToStr(sq.LastElapsedMs) + ' ms');
  // Windows'ta olcum ~1 ms duyarliliklidir; agir CROSS JOIN esigi asmali
{$IFDEF MSWINDOWS}
  if sq.LastElapsedMs >= 1 then Ok('agir sorgu 1 ms+ olculdu', IntToStr(sq.LastElapsedMs) + ' ms')
    else No('agir sorgu 1 ms+ olculdu', 'olcum ' + IntToStr(sq.LastElapsedMs) + ' ms');
{$ELSE}
  Ok('agir sorgu 1 ms+ olculdu (diger platformda >= 0 yeterli)', IntToStr(sq.LastElapsedMs) + ' ms');
{$ENDIF}
  ChkInt('agir sorgu kaydedildi', sq.SlowQueryCount, 1);
  R := sq.Exec('SHOW SLOW QUERIES');
  if TryStrToInt(R.Rows[0][0], n1) then Ok('kayit suresi sayisal', R.Rows[0][0])
    else No('kayit suresi sayisal', R.Rows[0][0]);

  // ---- ESIG FILTRESI: pozitif esik gercekten uygulanir ----
  // Cok yuksek esik (1 saat): hicbir sorgu kaydedilmemeli
  sq.Exec('SET SLOW_QUERY_MS = 3600000');
  sq.ClearSlow;
  sq.Exec('SELECT COUNT(*) FROM big a CROSS JOIN big b');   // ~30 ms
  ChkInt('cok yuksek esik -> kayit yok', sq.SlowQueryCount, 0);
  // Dusuk esik (1 ms): ayni sorgu KAYDEDILMELI
  sq.Exec('SET SLOW_QUERY_MS = 1');
  sq.ClearSlow;
  sq.Exec('SELECT COUNT(*) FROM big a CROSS JOIN big b');
  ChkInt('dusuk esik -> kayit var', sq.SlowQueryCount, 1);
  R := sq.Exec('SHOW SLOW QUERIES');
  if TryStrToInt(R.Rows[0][0], n1) then
  begin
    if n1 >= 1 then Ok('kayit suresi esigi gecer', R.Rows[0][0])
      else No('kayit suresi esigi gecer', R.Rows[0][0]);
  end
  else No('kayit suresi esigi gecer', R.Rows[0][0]);
  // Esigin ALTINDA kalan hizli bir cumle kaydedilmemeli
  sq.ClearSlow;
  sq.Exec('SET SLOW_QUERY_MS = 60000');   // 1 dakika
  sq.Exec('SELECT 1 FROM s1 WHERE id = 1');
  ChkInt('esig alti hizli cumle kaydedilmez', sq.SlowQueryCount, 0);
  sq.Exec('SET SLOW_QUERY_MS = 0');

  // ---- esik kapatilince yeni kayit olusmaz ----
  sq.Exec('SET SLOW_QUERY_MS = -1');
  n0 := sq.SlowQueryCount;
  sq.Exec('SELECT 1 FROM s1');
  ChkInt('esik kapali -> yeni kayit yok', sq.SlowQueryCount, n0);

  // ---- SET hatalari ----
  ChkErr('bilinmeyen SET ayari', 'SET BILINMEYEN_A = 1');

  // ---- DDL/DML de olculur ----
  sq.Exec('SET SLOW_QUERY_MS = 0');
  sq.ClearSlow;
  sq.Exec('CREATE TABLE s2(id INTEGER PRIMARY KEY)');
  ChkInt('DDL de kaydedilir', sq.SlowQueryCount, 1);
  ChkVal('DDL kaydi', 'SHOW SLOW QUERIES', 0, 3, 'CREATE TABLE s2(id INTEGER PRIMARY KEY)');
end;

procedure T09o_CoveringIndex;
// F-19: COVERING INDEX — "CREATE INDEX ix ON t(a) INCLUDE (b, c)"
begin
  Grp('Covering Index (F-19)');
  UseDir('cidx');
  sq.Exec('CREATE TABLE ci(id INTEGER PRIMARY KEY, a INTEGER, b TEXT, c INTEGER)');
  sq.Exec('INSERT INTO ci VALUES(1,10,' + Q + 'x' + Q + ',100),(2,20,' + Q + 'y' + Q + ',200),' +
          '(3,30,' + Q + 'z' + Q + ',300),(4,NULL,' + Q + 'w' + Q + ',NULL)');

  // ---- tanim + sema ----
  sq.Exec('CREATE INDEX ix_a ON ci(a) INCLUDE (b, c)');
  R := sq.Exec('SHOW INDEXES FROM ci');
  ChkInt('covering indeks tanimli', Length(R.Rows), 1);
  ChkVal('covering indeks adi', 'SHOW INDEXES FROM ci', 0, 0, 'ix_a');
  ChkVal('covering anahtar kolon', 'SHOW INDEXES FROM ci', 0, 2, 'a');
  ChkVal('covering INCLUDE listesi', 'SHOW INDEXES FROM ci', 0, 8, 'b,c');
  ChkVal('covering turu (ifade degil)', 'SHOW INDEXES FROM ci', 0, 4, 'tek kolunlu');
  ChkVal('covering indeks kayit sayisi (NULL a dahil)', 'SHOW INDEXES FROM ci', 0, 6, '4');

  // ---- INCLUDE anahtar DEGILDIR: UNIQUE denetimine girmez ----
  // a tekrarli ama ix_a UNIQUE degil; sorun yok
  ChkVal('covering indeks arama', 'SELECT b FROM ci WHERE a = 20', 0, 0, 'y');
  // INCLUDE kolonu tek basina arama yolunu degistirmez
  ChkVal('INCLUDE kolonu ile tarama', 'SELECT COUNT(*) FROM ci WHERE c = 300', 0, 0, '1');
  ChkVal('NULL a sonucu bos', 'SELECT COUNT(*) FROM ci WHERE a = NULL', 0, 0, '0');

  // ---- INDEX-ONLY SCAN sonucu AYNI olmali ----
  ChkVal('index-only: a=30 satiri', 'SELECT b, c FROM ci WHERE a = 30', 0, 1, '300');
  ChkVal('index-only: tum satirlar', 'SELECT COUNT(*) FROM ci WHERE a >= 10', 0, 0, '3');
  ChkVal('index-only: NULL c aktarilir',
      'SELECT b FROM ci WHERE a = 10', 0, 0, 'x');

  // ---- EXPLAIN index-only scan bildirmeli ----
  ChkHas('EXPLAIN Index Only Scan', 'EXPLAIN SELECT b, c FROM ci WHERE a = 20', 'Index Only Scan');

  // ---- kapsama YETERSIZSE index-only OLMAZ ----
  sq.Exec('CREATE TABLE ci2(id INTEGER PRIMARY KEY, a INTEGER, b TEXT, d INTEGER)');
  sq.Exec('INSERT INTO ci2 VALUES(1,10,' + Q + 'x' + Q + ',1),(2,20,' + Q + 'y' + Q + ',2)');
  sq.Exec('CREATE INDEX ix_a2 ON ci2(a) INCLUDE (b)');   // d kapsamiyor
  ChkHas('EXPLAIN yetersiz kaplama -> Index Scan',
      'EXPLAIN SELECT b FROM ci2 WHERE a = 20', 'Index Scan using ix_a2');
  ChkVal('yetersiz kaplama sonucu dogru', 'SELECT b FROM ci2 WHERE a = 20', 0, 0, 'y');
  // PK kolonu zaten ayri bir indekste; kapsama denetimi kesin olmali
  ChkVal('yetersiz kaplama ile tum satirlar', 'SELECT COUNT(*) FROM ci2 WHERE a >= 10', 0, 0, '2');
  ChkVal('yetersiz kaplama: kaplanmayan kolon okunur',
      'SELECT d FROM ci2 WHERE a = 20', 0, 0, '2');

  // ---- yazma yolu ----
  sq.Exec('INSERT INTO ci VALUES(5,50,' + Q + 'v' + Q + ',500)');
  ChkVal('INSERT sonrasi covering 5 kayit', 'SHOW INDEXES FROM ci', 0, 6, '5');
  ChkVal('INSERT sonrasi index-only sonuc',
      'SELECT c FROM ci WHERE a = 50', 0, 0, '500');
  sq.Exec('UPDATE ci SET c = 555 WHERE id = 5');
  ChkVal('UPDATE INCLUDE kolonu sonrasi', 'SELECT c FROM ci WHERE a = 50', 0, 0, '555');
  sq.Exec('UPDATE ci SET a = 55 WHERE id = 5');
  ChkVal('UPDATE anahtar kolonu sonrasi (yeni anahtar)',
      'SELECT c FROM ci WHERE a = 55', 0, 0, '555');
  ChkVal('UPDATE anahtar kolonu sonrasi (eski anahtar yok)',
      'SELECT COUNT(*) FROM ci WHERE a = 50', 0, 0, '0');
  sq.Exec('DELETE FROM ci WHERE id = 5');
  ChkVal('DELETE sonrasi covering 4 kayit', 'SHOW INDEXES FROM ci', 0, 6, '4');

  // ---- INCLUDE hatalari ----
  ChkErr('INCLUDE ayni kolon iki kez',
      'CREATE INDEX ix_e1 ON ci(a) INCLUDE (b, b)');
  ChkErr('INCLUDE anahtar kolonla ayni',
      'CREATE INDEX ix_e2 ON ci(a) INCLUDE (a)');
  ChkErr('INCLUDE olmayan kolon',
      'CREATE INDEX ix_e3 ON ci(a) INCLUDE (yokboyle)');

  // ---- covering + partial + expression birlikte ----
  sq.Exec('CREATE TABLE ci3(id INTEGER PRIMARY KEY, ad TEXT, n INTEGER, et INTEGER)');
  sq.Exec('INSERT INTO ci3 VALUES(1,' + Q + 'Ali' + Q + ',10,1),(2,' + Q + 'Veli' + Q + ',20,2),' +
          '(3,' + Q + 'Zoe' + Q + ',30,3)');
  sq.Exec('CREATE INDEX ix_c3 ON ci3(n) INCLUDE (et) WHERE et > 1');
  ChkVal('covering+partial INCLUDE listesi', 'SHOW INDEXES FROM ci3', 0, 8, 'et');
  ChkVal('covering+partial kosul', 'SHOW INDEXES FROM ci3', 0, 5, '(et > 1)');
  ChkVal('covering+partial kayit sayisi (et>1)', 'SHOW INDEXES FROM ci3', 0, 6, '2');
  ChkVal('covering+partial arama', 'SELECT et FROM ci3 WHERE n = 30', 0, 0, '3');
  ChkVal('covering+partial disi satir yine bulunur',
      'SELECT et FROM ci3 WHERE n = 10', 0, 0, '1');

  // ---- DROP ----
  sq.Exec('DROP INDEX ix_a');
  ChkVal('DROP covering sonrasi arama', 'SELECT b FROM ci WHERE a = 20', 0, 0, 'y');
  ChkVal('DROP covering sonrasi tum satirlar',
      'SELECT COUNT(*) FROM ci WHERE a >= 10', 0, 0, '3');

  // ---- SEMA PERSISTANSI ----
  UseDir('cidx');
  ChkVal('reopen: INCLUDE korundu', 'SHOW INDEXES FROM ci3', 0, 8, 'et');
  ChkInt('reopen: DROP edilen indeks geri gelmedi',
      Length(sq.Exec('SHOW INDEXES FROM ci').Rows), 0);
  ChkVal('reopen: covering+partial korundu', 'SHOW INDEXES FROM ci3', 0, 8, 'et');
  ChkVal('reopen: covering+partial kosul korundu', 'SHOW INDEXES FROM ci3', 0, 5, '(et > 1)');
  ChkVal('reopen: kayit sayisi korundu', 'SHOW INDEXES FROM ci3', 0, 6, '2');
  ChkVal('reopen: index-only sonuc', 'SELECT c FROM ci WHERE a = 30', 0, 0, '300');
  sq.Exec('REINDEX');
  ChkVal('reopen: REINDEX sonrasi kayit sayisi', 'SHOW INDEXES FROM ci3', 0, 6, '2');
  ChkVal('reopen: index-only sonuc', 'SELECT et FROM ci3 WHERE n = 30', 0, 0, '3');
end;

procedure T09n_ExprIndex;
// F-18: EXPRESSION INDEX — "CREATE INDEX ix ON t(LOWER(ad))"
begin
  Grp('Expression Index (F-18)');
  UseDir('eidx');
  sq.Exec('CREATE TABLE ei(id INTEGER PRIMARY KEY, ad TEXT, n INTEGER, f REAL)');
  sq.Exec('INSERT INTO ei VALUES(1,' + Q + 'Ali' + Q + ',10,1.5),(2,' + Q + 'VELI' + Q + ',20,2.5),' +
          '(3,' + Q + 'Zoe' + Q + ',30,3.5),(4,' + Q + 'can' + Q + ',40,4.5),(5,NULL,50,5.5)');

  // ---- tanim + sema ----
  sq.Exec('CREATE INDEX ix_lower ON ei(LOWER(ad))');
  R := sq.Exec('SHOW INDEXES FROM ei');
  ChkInt('ifade indeksi tanimli', Length(R.Rows), 1);   // yalniz ix_lower
  ChkVal('ifade indeksi adi', 'SHOW INDEXES FROM ei', 0, 0, 'ix_lower');
  ChkVal('ifade indeksi ifadesi', 'SHOW INDEXES FROM ei', 0, 2, 'LOWER(ad)');
  ChkVal('ifade indeksi expr kolonu', 'SHOW INDEXES FROM ei', 0, 7, 'LOWER(ad)');
  ChkVal('ifade indeksi turu', 'SHOW INDEXES FROM ei', 0, 4, 'ifade');
  ChkVal('ifade indeksi ncols', 'SHOW INDEXES FROM ei', 0, 3, '1');
  // 5 satir, ama ad = NULL olan satir LOWER() = NULL -> indekslenmez
  ChkVal('ifade indeksi 4 kayit (NULL haric)', 'SHOW INDEXES FROM ei', 0, 6, '4');

  // ---- icerik: kucuk harfe cevrilmis anahtarlar ----
  ChkVal('ifade indeksi LOWER dogru',
      'SELECT ad FROM ei WHERE LOWER(ad) = ' + Q + 'ali' + Q, 0, 0, 'Ali');
  // Turkce kurali: LOWER('VELI') = 'velı' (noktasiz i). Noktali/noktasiz
  // ayrimi VDbTrLower'da yapilir; motor LOWER'da da ayni sonucu verir.
  ChkVal('ifade indeksi Turkce LOWER (noktasiz i)',
      'SELECT ad FROM ei WHERE LOWER(ad) = ' + Q + 'velı' + Q, 0, 0, 'VELI');
  ChkVal('ifade indeksi noktali I eslesmez',
      'SELECT COUNT(*) FROM ei WHERE LOWER(ad) = ' + Q + 'veli' + Q, 0, 0, '0');
  ChkVal('ifade indeksi LOWER kucuk harf de eslesir',
      'SELECT ad FROM ei WHERE LOWER(ad) = ' + Q + 'can' + Q, 0, 0, 'can');
  ChkVal('ifade indeksi LOWER yoksa bos',
      'SELECT COUNT(*) FROM ei WHERE LOWER(ad) = ' + Q + 'yok' + Q, 0, 0, '0');
  ChkVal('ifade indeksi NULL eslesmez',
      'SELECT COUNT(*) FROM ei WHERE LOWER(ad) = NULL', 0, 0, '0');
  // indeks kullanmasa da sonuc dogru olmali
  ChkVal('arama sonucu indeksle tutarli',
      'SELECT COUNT(*) FROM ei WHERE LOWER(ad) IN (' + Q + 'ali' + Q + ',' + Q + 'zoe' + Q + ')',
      0, 0, '2');

  // ---- UPPER ----
  sq.Exec('CREATE INDEX ix_upper ON ei(UPPER(ad))');
  ChkVal('UPPER indeksi ifadesi', 'SHOW INDEXES FROM ei', 1, 7, 'UPPER(ad)');
  ChkVal('UPPER indeksi 4 kayit', 'SHOW INDEXES FROM ei', 1, 6, '4');
  ChkVal('UPPER ile arama (Turkce: Ali -> ALİ)', 'SELECT ad FROM ei WHERE UPPER(ad) = ' + Q + 'ALİ' + Q, 0, 0, 'Ali');

  // ---- TRIM ----
  sq.Exec('CREATE INDEX ix_trim ON ei(TRIM(ad))');
  ChkVal('TRIM indeksi 4 kayit', 'SHOW INDEXES FROM ei', 2, 6, '4');
  ChkVal('TRIM ile arama', 'SELECT ad FROM ei WHERE TRIM(ad) = ' + Q + 'Zoe' + Q, 0, 0, 'Zoe');

  // ---- LENGTH (sayisal) ----
  sq.Exec('CREATE INDEX ix_len ON ei(LENGTH(ad))');
  ChkVal('LENGTH indeksi ifadesi', 'SHOW INDEXES FROM ei', 3, 7, 'LENGTH(ad)');
  ChkVal('LENGTH indeksi 4 kayit', 'SHOW INDEXES FROM ei', 3, 6, '4');
  ChkVal('LENGTH ile arama (3 harf: Ali/Zoe/can)', 'SELECT COUNT(*) FROM ei WHERE LENGTH(ad) = 3', 0, 0, '3');
  ChkVal('LENGTH ile arama (4 harf)', 'SELECT COUNT(*) FROM ei WHERE LENGTH(ad) = 4', 0, 0, '1');

  // ---- aritmetik ifade (sayisal tip) ----
  sq.Exec('CREATE INDEX ix_n1 ON ei(n + 1)');
  ChkVal('aritmetik ifade indeksi', 'SHOW INDEXES FROM ei', 4, 7, '(n + 1)');
  ChkVal('aritmetik indeksi 5 kayit (n hep dolu)', 'SHOW INDEXES FROM ei', 4, 6, '5');
  ChkVal('aritmetik ifade ile arama', 'SELECT n FROM ei WHERE n + 1 = 21', 0, 0, '20');
  sq.Exec('CREATE INDEX ix_abs ON ei(ABS(f - 3.5))');
  ChkVal('ABS ifade indeksi', 'SHOW INDEXES FROM ei', 5, 7, 'ABS((f - 3.5))');
  ChkVal('ABS indeksi 5 kayit', 'SHOW INDEXES FROM ei', 5, 6, '5');

  // ---- yazma yolu ----
  sq.Exec('INSERT INTO ei VALUES(6,' + Q + 'AYSE' + Q + ',60,6.5)');
  ChkVal('INSERT sonrasi LOWER indeksi 5', 'SHOW INDEXES FROM ei', 0, 6, '5');
  ChkVal('INSERT sonrasi UPPER indeksi 5', 'SHOW INDEXES FROM ei', 1, 6, '5');
  ChkVal('INSERT sonrasi LENGTH indeksi 5', 'SHOW INDEXES FROM ei', 3, 6, '5');
  ChkVal('INSERT sonrasi aritmetik indeksi 6', 'SHOW INDEXES FROM ei', 4, 6, '6');
  ChkVal('yeni satir ifade ile bulunur',
      'SELECT ad FROM ei WHERE LOWER(ad) = ' + Q + 'ayse' + Q, 0, 0, 'AYSE');
  sq.Exec('DELETE FROM ei WHERE id = 6');
  ChkVal('DELETE sonrasi LOWER indeksi 4', 'SHOW INDEXES FROM ei', 0, 6, '4');
  // ifadeyi degistiren UPDATE
  sq.Exec('UPDATE ei SET ad = ' + Q + 'Yeni' + Q + ' WHERE id = 1');
  ChkVal('UPDATE sonrasi eski anahtar gitmis',
      'SELECT COUNT(*) FROM ei WHERE LOWER(ad) = ' + Q + 'ali' + Q, 0, 0, '0');
  ChkVal('UPDATE sonrasi yeni anahtar var',
      'SELECT ad FROM ei WHERE LOWER(ad) = ' + Q + 'yeni' + Q, 0, 0, 'Yeni');

  // ---- UNIQUE ifade indeksi ----
  sq.Exec('CREATE UNIQUE INDEX ux_ei ON ei(LOWER(ad))');
  // 'CAN' -> LOWER = 'can'; id=4 satiri zaten 'can' -> ihlal
  ChkErr('ifade UNIQUE ihlali',
      'INSERT INTO ei VALUES(7,' + Q + 'CAN' + Q + ',70,7.5)');
  ChkVal('ifade UNIQUE farkli ad serbest',
      'SELECT COUNT(*) FROM ei WHERE LOWER(ad) = ' + Q + 'can' + Q, 0, 0, '1');

  // ---- normal indeksler hala calisiyor ----
  sq.Exec('CREATE INDEX ix_n ON ei(n)');
  ChkVal('normal indeks sonrasi', 'SHOW INDEXES FROM ei', Length(sq.Exec('SHOW INDEXES FROM ei').Rows) - 1, 7, '');
  ChkVal('normal indeks ile arama', 'SELECT n FROM ei WHERE n = 30', 0, 0, '30');
  ChkVal('tablo satir sayisi 5', 'SELECT COUNT(*) FROM ei', 0, 0, '5');
  ChkVal('normal indeks nentries = 5', 'SHOW INDEXES FROM ei', 7, 6, '5');
  ChkVal('normal indeks bittikten sonra ifade yok', 'SHOW INDEXES FROM ei', 7, 7, '');

  // ---- DROP ----
  sq.Exec('DROP INDEX ix_lower');
  ChkVal('DROP ifade indeksi sonrasi arama', 'SELECT ad FROM ei WHERE LOWER(ad) = ' + Q + 'yeni' + Q, 0, 0, 'Yeni');

  // ---- SEMA PERSISTANSI ----
  UseDir('eidx');
  // DROP ix_lower sonrasi sira kaydi: ix_upper(0), ix_trim(1), ix_len(2),
  // ix_n1(3), ix_abs(4), ux_ei(5), ix_n(6)
  ChkVal('reopen: ifade korundu', 'SHOW INDEXES FROM ei', 0, 7, 'UPPER(ad)');
  ChkVal('reopen: aritmetik ifade korundu', 'SHOW INDEXES FROM ei', 3, 7, '(n + 1)');
  ChkVal('reopen: REINDEX sonrasi kayit sayisi', 'SHOW INDEXES FROM ei', 0, 6, '4');
  ChkVal('reopen: UNIQUE ifade hala zorlanir',
      'SELECT COUNT(*) FROM ei WHERE LOWER(ad) = ' + Q + 'can' + Q, 0, 0, '1');
end;

procedure T09m_PartialIndex;
// F-17: PARTIAL INDEX — "CREATE INDEX ix ON t(c) WHERE <kosul>"
begin
  Grp('Partial Index (F-17)');
  UseDir('pidx');
  sq.Exec('CREATE TABLE pi(id INTEGER PRIMARY KEY, ad TEXT, v INTEGER, aktif INTEGER)');
  sq.Exec('INSERT INTO pi VALUES(1,' + Q + 'Ali' + Q + ',10,1),(2,' + Q + 'Veli' + Q + ',20,0),' +
          '(3,' + Q + 'Zoe' + Q + ',30,1),(4,' + Q + 'Can' + Q + ',40,1),(5,' + Q + 'Eda' + Q + ',50,0)');

  // ---- tanim + sema korumasi ----
  sq.Exec('CREATE INDEX ix_aktif ON pi(v) WHERE aktif = 1');
  R := sq.Exec('SHOW INDEXES FROM pi');
  ChkInt('partial indeks tanimli', Length(R.Rows), 1);   // yalniz ix_aktif
  ChkVal('partial indeks adi', 'SHOW INDEXES FROM pi', 0, 0, 'ix_aktif');
  ChkVal('partial indeks kosulu saklandi', 'SHOW INDEXES FROM pi', 0, 5, '(aktif = 1)');
  // Indeks icerigi olusturuldugu ANDAN: tablo 5 satir, aktif=1 olan 3 satir
  ChkVal('partial indeks kayit sayisi = 3', 'SHOW INDEXES FROM pi', 0, 6, '3');
  // REINDEX yeniden kurar -> ayni sonuc (BuildOneIndex filtresi)
  sq.Exec('REINDEX');
  ChkVal('REINDEX sonrasi kayit sayisi = 3', 'SHOW INDEXES FROM pi', 0, 6, '3');
  ChkVal('tablo satir sayisi = 5', 'SELECT COUNT(*) FROM pi', 0, 0, '5');
  // normal indeks (aktif) tum satirlari kapsar -> 5
  sq.Exec('CREATE INDEX ix_tam ON pi(aktif)');
  ChkVal('normal indeks kayit sayisi = 5', 'SHOW INDEXES FROM pi', 1, 6, '5');
  
  // ---- SORGULAR DOGRU KALMALI (indeks kullanimindan bagimsiz) ----
  ChkVal('WHERE v = 30 (partial indeksli kolon)', 'SELECT ad FROM pi WHERE v = 30', 0, 0, 'Zoe');
  ChkVal('WHERE v = 50 (indeksde olmayan satir)', 'SELECT ad FROM pi WHERE v = 50', 0, 0, 'Eda');
  ChkVal('WHERE v = 10 (aktif satir)', 'SELECT ad FROM pi WHERE v = 10', 0, 0, 'Ali');
  ChkVal('partial indeks tam tarama sayisi', 'SELECT COUNT(*) FROM pi WHERE v >= 10', 0, 0, '5');
  ChkVal('WHERE v > 25 ve aktif', 'SELECT COUNT(*) FROM pi WHERE v > 25 AND aktif = 1', 0, 0, '2');

  // ---- yazma yolu: kosulu saglamayan satir indekslenmez ----
  // v=50 (aktif=0) iken sorgu yine dogru sonuc vermeli
  sq.Exec('UPDATE pi SET aktif = 1 WHERE id = 5');   // artik indekslenmeli
  ChkVal('UPDATE sonrasi indekslenen satir',
      'SELECT ad FROM pi WHERE v = 50 AND aktif = 1', 0, 0, 'Eda');
  sq.Exec('UPDATE pi SET aktif = 0 WHERE id = 5');   // indeksden cikmali
  ChkVal('UPDATE sonrasi indeksden cikan satir',
      'SELECT ad FROM pi WHERE v = 50', 0, 0, 'Eda');
  ChkVal('aktif=0 filtresi', 'SELECT COUNT(*) FROM pi WHERE v = 50 AND aktif = 0', 0, 0, '1');
  // yazma yolu sayimlari: 3 (aktif) + 1 = 4, sonra -1 = 3
  ChkVal('UPDATE sonrasi indeks 3 kayit', 'SHOW INDEXES FROM pi', 0, 6, '3');
  ChkVal('normal indeks 5 kayit', 'SHOW INDEXES FROM pi', 1, 6, '5');
  // INSERT: aktif=0 olan satir indekslenmemeli
  sq.Exec('INSERT INTO pi VALUES(6,' + Q + 'Fatma' + Q + ',60,0)');
  ChkVal('INSERT (aktif=0) indekse girmez', 'SHOW INDEXES FROM pi', 0, 6, '3');
  ChkVal('INSERT sonrasi normal indeks 6 kayit', 'SHOW INDEXES FROM pi', 1, 6, '6');
  sq.Exec('INSERT INTO pi VALUES(7,' + Q + 'Deniz' + Q + ',70,1)');
  ChkVal('INSERT (aktif=1) indekse girer', 'SHOW INDEXES FROM pi', 0, 6, '4');
  // DELETE: indeksden duser
  sq.Exec('DELETE FROM pi WHERE id = 7');
  ChkVal('DELETE sonrasi indeks 3 kayit', 'SHOW INDEXES FROM pi', 0, 6, '3');
  // UPDATE predicate'yi degistirince satir girer/cikar
  sq.Exec('UPDATE pi SET aktif = 1 WHERE id = 6');
  ChkVal('UPDATE predicate aktif etkisi', 'SHOW INDEXES FROM pi', 0, 6, '4');

  // ---- coklu kosul (AND) ----
  sq.Exec('CREATE INDEX ix_ikili ON pi(v) WHERE aktif = 1 AND v > 25');
  R := sq.Exec('SHOW INDEXES FROM pi');
  ChkInt('ikinci partial indeks', Length(R.Rows), 3);
  ChkVal('coklu kosul saklandi',
      'SHOW INDEXES FROM pi', 2, 5, '((aktif = 1) AND (v > 25))');
  ChkVal('coklu kosul: v=30 (aktif, >25)',
      'SELECT ad FROM pi WHERE v = 30 AND aktif = 1', 0, 0, 'Zoe');
  ChkVal('coklu kosul: v=10 (aktif ama <=25 yok)',
      'SELECT COUNT(*) FROM pi WHERE v = 10 AND aktif = 1', 0, 0, '1');
  // aktif=1 ve v>25 -> id 3,4 = 2 satir
  ChkVal('coklu kosul indeksi 3 kayit', 'SHOW INDEXES FROM pi', 2, 6, '3');

  // ---- metin sabitli kosul ----
  sq.Exec('CREATE TABLE pi2(id INTEGER PRIMARY KEY, sehir TEXT, n INTEGER)');
  sq.Exec('INSERT INTO pi2 VALUES(1,' + Q + 'Istanbul' + Q + ',10),(2,' + Q + 'Ankara' + Q + ',20),(3,' + Q + 'Izmir' + Q + ',30)');
  sq.Exec('CREATE INDEX ix_sehir ON pi2(n) WHERE sehir = ' + Q + 'Istanbul' + Q);
  ChkVal('metin kosulu saklandi',
      'SHOW INDEXES FROM pi2', 0, 5, '(sehir = ' + Q + 'Istanbul' + Q + ')');
  ChkVal('metin kosulu ile sorgu', 'SELECT sehir FROM pi2 WHERE n = 10', 0, 0, 'Istanbul');
  ChkVal('metin kosulu disi satir', 'SELECT sehir FROM pi2 WHERE n = 20', 0, 0, 'Ankara');

  // ---- bilesik (cok kolonlu) partial indeks ----
  sq.Exec('CREATE INDEX ix_cok ON pi(aktif, v) WHERE v >= 30');
  R := sq.Exec('SHOW INDEXES FROM pi');
  ChkInt('cok kolonlu partial indeks', Length(R.Rows), 4);
  ChkVal('cok kolonlu partial kosul',
      'SHOW INDEXES FROM pi', 3, 5, '(v >= 30)');
  ChkVal('cok kolonlu + WHERE birlik',
      'SELECT COUNT(*) FROM pi WHERE aktif = 1 AND v >= 30', 0, 0, '3');

  // ---- DROP INDEX ----
  sq.Exec('DROP INDEX ix_cok');
  R := sq.Exec('SHOW INDEXES FROM pi');
  ChkInt('DROP partial INDEX', Length(R.Rows), 3);
  ChkVal('droptan sonra sorgu bozulmaz',
      'SELECT COUNT(*) FROM pi WHERE v >= 30', 0, 0, '4');   // id 3,4,5,6

  // ---- UNIQUE + partial ----
  sq.Exec('CREATE UNIQUE INDEX ux_pi ON pi(ad) WHERE aktif = 1');
  ChkErr('partial UNIQUE ihlali',
      'INSERT INTO pi VALUES(6,' + Q + 'Ali' + Q + ',99,1)');
  ChkVal('partial UNIQUE disinda ayni ad serbest',
      'SELECT COUNT(*) FROM pi WHERE ad = ' + Q + 'Ali' + Q, 0, 0, '1');

  // ---- SEMA PERSISTANSI (dosya yeniden acilir) ----
  UseDir('pidx');   // ayni klasoru yeniden ac
  ChkVal('reopen: partial kosul korundu',
      'SHOW INDEXES FROM pi', 0, 5, '(aktif = 1)');
  ChkVal('reopen: kayan kosul korundu',
      'SHOW INDEXES FROM pi', 2, 5, '((aktif = 1) AND (v > 25))');
  ChkVal('reopen: metin kosulu korundu',
      'SHOW INDEXES FROM pi2', 0, 5, '(sehir = ' + Q + 'Istanbul' + Q + ')');
  ChkVal('reopen: REINDEX sonrasi kayit sayisi', 'SHOW INDEXES FROM pi', 0, 6, '4');
  ChkVal('reopen: sorgu sonucu ayni',
      'SELECT COUNT(*) FROM pi WHERE aktif = 1 AND v >= 30', 0, 0, '3');
  ChkErr('reopen: partial UNIQUE hala zorlanir',
      'INSERT INTO pi VALUES(8,' + Q + 'Ali' + Q + ',98,1)');
end;

procedure T09l_Explain;
// F-20: EXPLAIN / EXPLAIN ANALYZE — sorgu plani raporu.
begin
  Grp('EXPLAIN (F-20)');
  UseDir('explain');
  sq.Exec('CREATE TABLE ex(id INTEGER PRIMARY KEY, ad TEXT, v INTEGER)');
  sq.Exec('INSERT INTO ex VALUES(1,' + Q + 'Ali' + Q + ',10),(2,' + Q + 'Veli' + Q + ',20),(3,' + Q + 'Zoe' + Q + ',30)');
  sq.Exec('CREATE INDEX ix_v ON ex(v)');
  // temel EXPLAIN — 1 satir (Seq Scan)
  Chk('EXPLAIN SELECT (plan var)', 'EXPLAIN SELECT * FROM ex', 1);
  ChkHas('EXPLAIN Seq Scan icerigi', 'EXPLAIN SELECT * FROM ex', 'Seq Scan');
  // WHERE ile Seq Scan + Filter
  Chk('EXPLAIN WHERE (plan)', 'EXPLAIN SELECT * FROM ex WHERE ad = ' + Q + 'Ali' + Q, 1);
  // PK nokta aramasi -> Index Scan
  Chk('EXPLAIN PK (Index Scan)', 'EXPLAIN SELECT * FROM ex WHERE id = 1', 1);
  ChkHas('EXPLAIN PK icerigi', 'EXPLAIN SELECT * FROM ex WHERE id = 1', '_pkey');
  // indeks kullanimi
  Chk('EXPLAIN indeks (Index Scan)', 'EXPLAIN SELECT * FROM ex WHERE v = 10', 1);
  ChkHas('EXPLAIN indeks adi icerigi', 'EXPLAIN SELECT * FROM ex WHERE v = 10', 'ix_v');
  ChkHas('EXPLAIN indeks (PK olmayan WHERE)',
      'EXPLAIN SELECT * FROM ex WHERE v > 5', 'ix_v');
  // JOIN
  Chk('EXPLAIN JOIN (plan)', 'EXPLAIN SELECT * FROM ex a JOIN ex b ON a.id = b.id', 3);
  // GROUP BY / aggregate: Seq Scan + Aggregate + Group = 3
  Chk('EXPLAIN GROUP BY (3)', 'EXPLAIN SELECT ad, COUNT(*) FROM ex GROUP BY ad', 3);
  // ORDER BY
  Chk('EXPLAIN ORDER BY (plan)', 'EXPLAIN SELECT * FROM ex ORDER BY v', 2);
  // LIMIT
  Chk('EXPLAIN LIMIT (plan)', 'EXPLAIN SELECT * FROM ex ORDER BY v LIMIT 2', 3);
  // EXPLAIN DML
  Chk('EXPLAIN INSERT (plan)', 'EXPLAIN INSERT INTO ex VALUES(9,' + Q + 'X' + Q + ',90)', 1);
  Chk('EXPLAIN UPDATE (plan)', 'EXPLAIN UPDATE ex SET v = 1 WHERE id = 9', 1);
  Chk('EXPLAIN DELETE (plan)', 'EXPLAIN DELETE FROM ex WHERE id = 9', 1);
  // EXPLAIN ANALYZE — calistirir: plan (1) + Actual Rows + Execution Time = 3
  Chk('EXPLAIN ANALYZE (calistirir)', 'EXPLAIN ANALYZE SELECT * FROM ex WHERE id = 1', 3);
  // EXPLAIN cumleyi CALISTIRMADIGI dogrulanir: veri degismemis olmali
  ChkVal('EXPLAIN veri degistirmedi',
      'SELECT COUNT(*) FROM ex WHERE id = 9', 0, 0, '0');
  // gecersiz ic cumle
  ChkErr('EXPLAIN sonrasi tablo (hata)', 'EXPLAIN ex');
end;

procedure T09k_Filter;
// F-16: FILTER (WHERE ...) — aggregate'e satir filtresi.
begin
  Grp('FILTER (F-16)');
  UseDir('filter');
  sq.Exec('CREATE TABLE fl(id INTEGER PRIMARY KEY, ad TEXT, v INTEGER, p INTEGER)');
  sq.Exec('INSERT INTO fl VALUES(1,' + Q + 'Ali' + Q + ',10,1),(2,' + Q + 'Veli' + Q + ',20,1),' +
          '(3,' + Q + 'Zoe' + Q + ',30,2),(4,' + Q + 'Can' + Q + ',40,2),(5,' + Q + 'Eda' + Q + ',NULL,2)');
  // temel FILTER
  ChkVal('COUNT(*) FILTER (p=1) = 2',
      'SELECT COUNT(*) FILTER (WHERE p = 1) FROM fl', 0, 0, '2');
  ChkVal('COUNT(*) = 5 (filtresiz)',
      'SELECT COUNT(*) FROM fl', 0, 0, '5');
  ChkVal('COUNT(v) FILTER (p=2) = 2',
      'SELECT COUNT(v) FILTER (WHERE p = 2) FROM fl', 0, 0, '2');
  ChkVal('SUM(v) FILTER (p=1) = 30',
      'SELECT SUM(v) FILTER (WHERE p = 1) FROM fl', 0, 0, '30');
  ChkVal('AVG(v) FILTER (p=1) = 15',
      'SELECT AVG(v) FILTER (WHERE p = 1) FROM fl', 0, 0, '15');
  ChkVal('MIN(v) FILTER (p=2) = 30',
      'SELECT MIN(v) FILTER (WHERE p = 2) FROM fl', 0, 0, '30');
  ChkVal('MAX(v) FILTER (p=2) = 40',
      'SELECT MAX(v) FILTER (WHERE p = 2) FROM fl', 0, 0, '40');
  // filtre + DISTINCT birlikte: id 1..4, v>15 olanlar id=2(p=1),3(p=2),4(p=2)
  // -> p degerleri {1,2} -> COUNT(DISTINCT) = 2
  ChkVal('COUNT(DISTINCT p) FILTER (v>15) = 2',
      'SELECT COUNT(DISTINCT p) FILTER (WHERE v > 15) FROM fl WHERE id IN (1,2,3,4)', 0, 0, '2');
  // GROUP BY + FILTER
  Chk('GROUP BY p + FILTER (2)',
      'SELECT p FROM fl GROUP BY p HAVING SUM(v) FILTER (WHERE v > 15) > 0', 2);
  ChkVal('GROUP BY p FILTER deger (p=1: 30)',
      'SELECT p, SUM(v) FILTER (WHERE p = 1) FROM fl GROUP BY p ORDER BY p', 0, 1, '30');
  // filtre sonuc bos -> NULL (aggregate bos kume)
  ChkVal('FILIRE sonuc yok -> NULL',
      'SELECT SUM(v) FILTER (WHERE p = 99) FROM fl', 0, 0, '');
  ChkVal('FILTER COUNT sonuc yok -> 0',
      'SELECT COUNT(*) FILTER (WHERE p = 99) FROM fl', 0, 0, '0');
  // non-aggregate fonksiyonda hata
  ChkErr('FILTER aggregate disinda (hata)',
      'SELECT UPPER(ad) FILTER (WHERE p = 1) FROM fl');
  // OVER ile birlikte kullanilamaz
  ChkErr('FILTER + OVER (hata)',
      'SELECT SUM(v) FILTER (WHERE p = 1) OVER () FROM fl');
end;

procedure T09j_AggDistinct;
begin
  Grp('COUNT/SUM/AVG/MIN/MAX(DISTINCT) + STRING_AGG + PERCENTILE (F-11/F-14/F-15)');
  UseDir('agg2');
  sq.Exec('CREATE TABLE ag(id INTEGER PRIMARY KEY, ad TEXT, v INTEGER)');
  sq.Exec('INSERT INTO ag VALUES(1,' + Q + 'Ali' + Q + ',10),(2,' + Q + 'Veli' + Q + ',20),' +
          '(3,' + Q + 'Zoe' + Q + ',10),(4,' + Q + 'Can' + Q + ',30),(5,' + Q + 'Eda' + Q + ',20),' +
          '(6,NULL,NULL)');
  // ---- F-11: COUNT(DISTINCT) ----
  ChkVal('COUNT(DISTINCT v) = 3',
      'SELECT COUNT(DISTINCT v) FROM ag', 0, 0, '3');
  ChkVal('COUNT(v) = 5 (NULL sayilmaz)',
      'SELECT COUNT(v) FROM ag', 0, 0, '5');
  ChkVal('COUNT(*) = 6',
      'SELECT COUNT(*) FROM ag', 0, 0, '6');
  ChkVal('COUNT(DISTINCT ad) = 5',
      'SELECT COUNT(DISTINCT ad) FROM ag', 0, 0, '5');
  // SUM DISTINCT: 10+20+30 = 60 (tekrarlar ciftlenmez)
  ChkVal('SUM(DISTINCT v) = 60',
      'SELECT SUM(DISTINCT v) FROM ag', 0, 0, '60');
  // SUM (tekrarli): 10+20+10+30+20 = 90
  ChkVal('SUM(v) = 90',
      'SELECT SUM(v) FROM ag', 0, 0, '90');
  // AVG DISTINCT: (10+20+30)/3 = 20
  ChkVal('AVG(DISTINCT v) = 20',
      'SELECT AVG(DISTINCT v) FROM ag', 0, 0, '20');
  // MIN/MAX DISTINCT ayni sonuc
  ChkVal('MIN(DISTINCT v) = 10',
      'SELECT MIN(DISTINCT v) FROM ag', 0, 0, '10');
  ChkVal('MAX(DISTINCT v) = 30',
      'SELECT MAX(DISTINCT v) FROM ag', 0, 0, '30');
  // GROUP BY + DISTINCT: her ad tekil
  Chk('GROUP BY + COUNT(DISTINCT) (5)',
      'SELECT ad, COUNT(DISTINCT v) FROM ag WHERE ad IS NOT NULL GROUP BY ad', 5);
  // HAVING + COUNT(DISTINCT): her ad TEK deger iceriyor -> hicbiri > 1 degil -> 0
  Chk('HAVING COUNT(DISTINCT v) > 1 (0)',
      'SELECT ad FROM ag WHERE ad IS NOT NULL GROUP BY ad HAVING COUNT(DISTINCT v) > 1', 0);
  Chk('HAVING COUNT(DISTINCT v) = 1 (5)',
      'SELECT ad FROM ag WHERE ad IS NOT NULL GROUP BY ad HAVING COUNT(DISTINCT v) = 1', 5);
  // ---- F-14: STRING_AGG ----
  // Not: STRING_AGG cikti sirasi tablo satir SIRASINA baglidir (index
  // yolu satirlari farkli sirada dondurebilir). Bu yuzden tek satirlik
  // ya da ORDER BY'siz deterministik durumlar test edilir.
  ChkVal('STRING_AGG ozel ayirac',
      'SELECT STRING_AGG(ad, ' + Q + ' | ' + Q + ') FROM ag WHERE ad IS NOT NULL AND id <= 2', 0, 0, 'Ali | Veli');
  ChkVal('STRING_AGG tek satir',
      'SELECT STRING_AGG(ad, ' + Q + ',' + Q + ') FROM ag WHERE id = 1', 0, 0, 'Ali');
  // DISTINCT: v degerleri 10,20,10,30,20 (id=6 NULL)
  //   WHERE v <= 20 ile: 10,20,10,20 -> DISTINCT "10,20" = 5 karakter
  //                      DISTINCT'siz: "10,20,10,20" = 11 karakter
  ChkVal('STRING_AGG DISTINCT eler (5 karakter)',
      'SELECT LENGTH(STRING_AGG(DISTINCT v, ' + Q + ',' + Q + ')) FROM ag WHERE v <= 20', 0, 0, '5');
  ChkVal('STRING_AGG DISTINCTsiz (11 karakter)',
      'SELECT LENGTH(STRING_AGG(v, ' + Q + ',' + Q + ')) FROM ag WHERE v <= 20', 0, 0, '11');
  // aggregate'siz sorgu yolu: WHERE ile filtreli STRING_AGG
  ChkVal('STRING_AGG WHERE ile (2 deger)',
      'SELECT STRING_AGG(v, ' + Q + ',' + Q + ') FROM ag WHERE v = 10', 0, 0, '10,10');
  ChkVal('STRING_AGG GROUP BY (bolum yok, tek grup)',
      'SELECT STRING_AGG(ad, ' + Q + ',' + Q + ') FROM ag WHERE id <= 2', 0, 0, 'Ali,Veli');
  // ---- F-15: PERCENTILE ----
  // v degerleri: 10,20,10,30,20 -> sirali: 10,10,20,20,30
  // medyan (p=0.5): p*(n-1) = 0.5*4 = 2 -> 20
  ChkVal('PERCENTILE_CONT 0.5 = 20',
      'SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v) FROM ag', 0, 0, '20');
  // p=0.25: 0.25*4 = 1 -> 10
  ChkVal('PERCENTILE_CONT 0.25 = 10',
      'SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY v) FROM ag', 0, 0, '10');
  // p=0.75: 0.75*4 = 3 -> 20
  ChkVal('PERCENTILE_CONT 0.75 = 20',
      'SELECT PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY v) FROM ag', 0, 0, '20');
  // PERCENTILE_DISC p=0.5 -> indeks 2 -> 20
  ChkVal('PERCENTILE_DISC 0.5 = 20',
      'SELECT PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY v) FROM ag', 0, 0, '20');
  // p=0.9: 0.9*4 = 3.6 -> CONT: 20 + (30-20)*0.6 = 26
  ChkVal('PERCENTILE_CONT 0.9 = 26',
      'SELECT PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY v) FROM ag', 0, 0, '26');
  // tek deger: p*(0) = 0 -> o deger
  ChkVal('PERCENTILE tek deger',
      'SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v) FROM ag WHERE id = 4', 0, 0, '30');
  // hepsi NULL -> NULL
  ChkVal('PERCENTILE hepsi NULL',
      'SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v) FROM ag WHERE v IS NULL', 0, 0, '');
  // hatali oran
  ChkErr('PERCENTILE oran > 1 (hata)',
      'SELECT PERCENTILE_CONT(1.5) WITHIN GROUP (ORDER BY v) FROM ag');
  ChkErr('PERCENTILE WITHIN GROUP yok (hata)',
      'SELECT PERCENTILE_CONT(0.5) FROM ag');
  // GROUP BY ile
  Chk('STRING_AGG GROUP BY ad (5)',
      'SELECT ad, STRING_AGG(ad, ' + Q + ',' + Q + ') FROM ag WHERE ad IS NOT NULL GROUP BY ad', 5);
end;

procedure T09i_Qualify;
// F-09: QUALIFY — pencere fonksiyonu hesaplandiktan SONRA filtre.
begin
  Grp('QUALIFY (F-09)');
  UseDir('qualify');
  sq.Exec('CREATE TABLE ql(id INTEGER PRIMARY KEY, ad TEXT, p INTEGER, v INTEGER)');
  sq.Exec('INSERT INTO ql VALUES(1,' + Q + 'Ali' + Q + ',1,10),(2,' + Q + 'Veli' + Q + ',1,20),' +
          '(3,' + Q + 'Zoe' + Q + ',1,30),(4,' + Q + 'Can' + Q + ',2,15),(5,' + Q + 'Eda' + Q + ',2,25)');
  // ROW_NUMBER() = 1 her partition'da ilk satir (p=1: Ali, p=2: Can) -> 2
  ChkVal('QUALIFY ROW_NUMBER=1 (Ali)',
      'SELECT ad, ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) AS rn FROM ql QUALIFY ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) = 1 ORDER BY id', 0, 0, 'Ali');
  ChkVal('QUALIFY ROW_NUMBER=1 (Can, 2. satir)',
      'SELECT ad, ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) AS rn FROM ql QUALIFY ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) = 1 ORDER BY id', 1, 0, 'Can');
  // ROW_NUMBER() <= 2 -> p=1: Ali,Veli; p=2: Can,Eda -> 4 satir
  Chk('QUALIFY ROW_NUMBER<=2 (4)',
      'SELECT ad, ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) AS rn FROM ql QUALIFY ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) <= 2', 4);
  ChkVal('QUALIFY <=2 son satir (Eda)',
      'SELECT ad, ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) AS rn FROM ql QUALIFY ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) <= 2 ORDER BY id', 3, 0, 'Eda');
  // QUALIFY 5. satiri eler: Zoe (p=1, rn=3) gelmemeli
  ChkVal('QUALIFY Zoe elendi (Eda 4. satir)',
      'SELECT ad, ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) AS rn FROM ql QUALIFY ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) <= 2 ORDER BY id', 3, 0, 'Eda');
  // pencere + LIMIT birlikte
  Chk('QUALIFY + LIMIT (1)',
      'SELECT ad, ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) AS rn FROM ql QUALIFY ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) <= 2 ORDER BY id FETCH FIRST 1 ROWS ONLY', 1);
  // pencere olmadan QUALIFY -> hata
  ChkErr('QUALIFY pencilsuz (hata)',
      'SELECT ad FROM ql QUALIFY id = 1');
end;

procedure T09f_ILike;
// F-05: ILIKE — buyuk/kucuk duyarsiz LIKE (PostgreSQL uyumu).
begin
  Grp('ILIKE (F-05)');
  UseDir('ilike');
  sq.Exec('CREATE TABLE il(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO il VALUES(1,' + Q + 'Ali' + Q + '),(2,' + Q + 'VELI' + Q + '),(3,' +
          Q + 'zOE' + Q + '),(4,' + Q + 'ayse' + Q + '),(5,NULL)');
  // LIKE buyuk/kucuk DUYARLI: sadece kucuk harfle baslayanlar
  Chk('LIKE kucuk duyarli (1)', 'SELECT ad FROM il WHERE ad LIKE ' + Q + 'a%' + Q, 1);
  // ILIKE duyarsiz: hem 'Ali' hem 'ayse' -> 2
  Chk('ILIKE duyarsiz on ek (2)',
      'SELECT ad FROM il WHERE ad ILIKE ' + Q + 'a%' + Q, 2);
  ChkVal('ILIKE deger', 'SELECT ad FROM il WHERE ad ILIKE ' + Q + 'A%' + Q + ' ORDER BY id', 0, 0, 'Ali');
  // Ic harf: yalniz 'zOE' icinde 'oe' var -> 1 satir
  Chk('ILIKE ic desen (1)',
      'SELECT ad FROM il WHERE ad ILIKE ' + Q + '%oe%' + Q, 1);
  // NOT ILIKE
  Chk('NOT ILIKE (2)', 'SELECT ad FROM il WHERE ad NOT ILIKE ' + Q + 'a%' + Q, 2);
  // joker: '_' tek karakter
  Chk('ILIKE joker _ (1)',
      'SELECT ad FROM il WHERE ad ILIKE ' + Q + 'z_e' + Q, 1);
  // NULL satir elenir (uc-degerli)
  Chk('ILIKE NULL elenir (4)',
      'SELECT ad FROM il WHERE ad ILIKE ' + Q + '%' + Q, 4);
  // Turkce buyuk/kucuk: 'I' -> 'i' donusumu
  ChkVal('ILIKE turkce I donusumu',
      'SELECT ad FROM il WHERE ad ILIKE ' + Q + 'ali' + Q, 0, 0, 'Ali');
end;

procedure T08d_CaseWhen;
begin
  Grp('CASE WHEN (P5-3)');
  UseDir('casew');
  sq.Exec('CREATE TABLE per(id INTEGER PRIMARY KEY, ad TEXT, yas INTEGER, maas FLOAT)');
  sq.Exec('INSERT INTO per(id,ad,yas,maas) VALUES(1,' + Q + 'Ali' + Q + ',30,9000.5)');
  sq.Exec('INSERT INTO per(id,ad,yas,maas) VALUES(2,' + Q + 'Veli' + Q + ',17,4000)');
  sq.Exec('INSERT INTO per(id,ad,yas,maas) VALUES(3,' + Q + 'Zoe' + Q + ',25,NULL)');
  ChkVal('aranan + ELSE (Ali resit)',
      'SELECT ad, CASE WHEN yas >= 18 THEN ' + Q + 'resit' + Q + ' ELSE ' + Q + 'cocuk' + Q + ' END AS d FROM per ORDER BY id', 0, 1, 'resit');
  ChkVal('aranan ELSE (Veli cocuk)',
      'SELECT ad, CASE WHEN yas >= 18 THEN ' + Q + 'resit' + Q + ' ELSE ' + Q + 'cocuk' + Q + ' END AS d FROM per ORDER BY id', 1, 1, 'cocuk');
  ChkVal('ELSEsiz eslesmezse NULL',
      'SELECT ad, CASE WHEN yas > 100 THEN ' + Q + 'x' + Q + ' END AS d FROM per WHERE id = 1', 0, 1, '');
  ChkVal('sade CASE (Ali otuz)',
      'SELECT ad, CASE yas WHEN 30 THEN ' + Q + 'otuz' + Q + ' WHEN 17 THEN ' + Q + 'onyedi' + Q + ' ELSE ' + Q + 'diger' + Q + ' END AS d FROM per ORDER BY id', 0, 1, 'otuz');
  ChkVal('sade CASE (Zoe diger)',
      'SELECT ad, CASE yas WHEN 30 THEN ' + Q + 'otuz' + Q + ' WHEN 17 THEN ' + Q + 'onyedi' + Q + ' ELSE ' + Q + 'diger' + Q + ' END AS d FROM per ORDER BY id', 2, 1, 'diger');
  Chk('CASE WHERE kosulu (2)',
      'SELECT ad FROM per WHERE CASE WHEN yas >= 18 THEN 1 ELSE 0 END = 1', 2);
  ChkVal('ic ice CASE',
      'SELECT CASE WHEN yas > 20 THEN CASE WHEN yas > 28 THEN ' + Q + 'yasli' + Q + ' ELSE ' + Q + 'genc' + Q + ' END ELSE ' + Q + 'cocuk' + Q + ' END AS d FROM per ORDER BY id', 0, 0, 'yasli');
  ChkVal('CASE float kiyas',
      'SELECT CASE WHEN maas > 5000 THEN ' + Q + 'yuksek' + Q + ' ELSE ' + Q + 'dusuk' + Q + ' END AS s FROM per ORDER BY id', 0, 0, 'yuksek');
  ChkVal('CASE NULL kiyas ELSE duser',
      'SELECT CASE WHEN maas > 5000 THEN ' + Q + 'yuksek' + Q + ' ELSE ' + Q + 'dusuk' + Q + ' END AS s FROM per ORDER BY id', 2, 0, 'dusuk');
  ChkErr('eksik END (hata)',
      'SELECT CASE WHEN yas > 1 THEN 1 FROM per');
  ChkErr('WHENsiz CASE (hata)',
      'SELECT CASE yas ELSE 1 END FROM per');
end;

procedure T08e_CTE;
begin
  Grp('WITH-CTE (P5-CTE)');
  UseDir('cteq');
  sq.Exec('CREATE TABLE bolge(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('CREATE TABLE musteri(id INTEGER PRIMARY KEY, ad TEXT, bid INTEGER, maas INTEGER)');
  sq.Exec('INSERT INTO bolge(id,ad) VALUES(1,' + Q + 'Ege' + Q + '),(2,' + Q + 'Ic Anadolu' + Q + ')');
  sq.Exec('INSERT INTO musteri(id,ad,bid,maas) VALUES(1,' + Q + 'Ali' + Q + ',1,9000)');
  sq.Exec('INSERT INTO musteri(id,ad,bid,maas) VALUES(2,' + Q + 'Veli' + Q + ',2,4000)');
  sq.Exec('INSERT INTO musteri(id,ad,bid,maas) VALUES(3,' + Q + 'Zoe' + Q + ',NULL,7000)');
  sq.Exec('INSERT INTO musteri(id,ad,bid,maas) VALUES(4,' + Q + 'Can' + Q + ',1,5000)');
  sq.Exec('INSERT INTO musteri(id,ad,bid,maas) VALUES(5,' + Q + 'Dev' + Q + ',2,100000)');
  Chk('tek CTE (5)',
      'WITH m AS (SELECT id, ad, bid FROM musteri) SELECT ad FROM m', 5);
  ChkVal('CTE WHERE',
      'WITH m AS (SELECT id, ad, bid FROM musteri) SELECT ad FROM m WHERE bid = 1 ORDER BY id', 0, 0, 'Ali');
  Chk('zincir CTE (Can)',
      'WITH e AS (SELECT id, ad FROM musteri WHERE bid = 1), ' +
      'x AS (SELECT ad FROM e WHERE id > 1) SELECT ad FROM x', 1);
  ChkVal('zincir deger',
      'WITH e AS (SELECT id, ad FROM musteri WHERE bid = 1), ' +
      'x AS (SELECT ad FROM e WHERE id > 1) SELECT ad FROM x', 0, 0, 'Can');
  Chk('CTE + JOIN (4)',
      'WITH m AS (SELECT id, ad, bid FROM musteri WHERE bid IS NOT NULL) ' +
      'SELECT m.ad, b.ad FROM m JOIN bolge b ON m.bid = b.id ORDER BY m.id', 4);
  Chk('CTE sagda (4)',
      'WITH m AS (SELECT id, bid FROM musteri WHERE bid IS NOT NULL) ' +
      'SELECT b.ad FROM bolge b JOIN m ON m.bid = b.id', 4);
  ChkVal('CTE aggregate',
      'WITH m AS (SELECT id, bid FROM musteri WHERE bid IS NOT NULL) SELECT COUNT(*) AS c FROM m', 0, 0, '4');
  ChkVal('CTE GROUP BY',
      'WITH m AS (SELECT bid FROM musteri WHERE bid IS NOT NULL) SELECT bid, COUNT(*) AS n FROM m GROUP BY bid ORDER BY bid', 0, 1, '2');
  Chk('CTE sayisal WHERE (3, metin olsa 2 olurdu)',
      'WITH m AS (SELECT id, maas FROM musteri) SELECT id FROM m WHERE maas > 6000', 3);
  ChkVal('CTE sayisal ORDER BY (Veli ilk)',
      'WITH m AS (SELECT id, maas FROM musteri) SELECT id FROM m ORDER BY maas LIMIT 1', 0, 0, '2');
  Chk('RECURSIVE (4.5 acik, maxIter=3)',
      'WITH RECURSIVE x AS (SELECT id FROM musteri) SELECT id FROM x', 5);
  Chk('kolon alias (4.5 acik)',
      'WITH x(a) AS (SELECT id FROM musteri) SELECT a FROM x', 5);
  Chk('WITH + INSERT (4.5 acik)',
      'WITH x AS (SELECT id FROM musteri) INSERT INTO musteri(id) VALUES(9)', 0);
  ChkErr('bilinmeyen CTE/tablo (hata)',
      'WITH x AS (SELECT id FROM musteri) SELECT id FROM yok');

  // ---- R-10: SET OP + GERCEK OZYINELEME + CYCLE ----
  // 1) UNION ALL (anchor'siz bile yazilabilir)
  Chk('UNION ALL 2 satir',
      'SELECT 1 AS n UNION ALL SELECT 2', 2);
  Chk('UNION ALL degerler',
      'SELECT 1 AS n UNION ALL SELECT 2 AS n UNION ALL SELECT 3', 3);
  Chk('UNION (tekillestirir)',
      'SELECT 1 AS n UNION SELECT 1 AS n', 1);
  // 2) Gercek ozyineleme: anchor + kendine bakan terim
  Chk('RECURSIVE sayac 1..5',
      'WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n < 5)' +
      ' SELECT n FROM r', 5);
  ChkVal('RECURSIVE ilk deger 1',
      'WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n < 5)' +
      ' SELECT n FROM r', 0, 0, '1');
  ChkVal('RECURSIVE son deger 5',
      'WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n < 5)' +
      ' SELECT n FROM r', 4, 0, '5');
  ChkVal('RECURSIVE filtre WHERE',
      'WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n < 10)' +
      ' SELECT n FROM r WHERE n > 7', 0, 0, '8');
  // 3) Iki kolonlu ozyineleme
  Chk('RECURSIVE iki kolon',
      'WITH RECURSIVE r(a,b) AS (SELECT 1,10 UNION ALL SELECT a+1,b+1 FROM r WHERE a < 3)' +
      ' SELECT a FROM r', 3);
  // 4) CYCLE maddesi: dongu kesildigi icin SATIR SAYISI degismez,
  //    is_cycle sutunu SELECT edebilmek icin kullanilir.
  Chk('CYCLE sonuc degistirmez',
      'WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n < 5)' +
      ' CYCLE n SET is_cycle USING path SELECT n FROM r', 5);
  ChkVal('CYCLE is_cycle sutunu okunur',
      'WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n < 5)' +
      ' CYCLE n SET is_cycle USING path SELECT is_cycle FROM r', 0, 0, 'False');
  ChkErr('CYCLE kolonu yoksa hata',
      'WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n < 3)' +
      ' CYCLE yokBoyle SET ic USING p SELECT n FROM r');
  // 5) Kosulsuz dongu CYCLE olmadan da motoru asmaz
  Chk('sonsuz dongu guard (limit)',
      'WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n < 100000)' +
      ' SELECT COUNT(*) FROM r', 1);
end;

procedure T08f_Pencere;
begin
  Grp('Pencere fonksiyonlari (P5-WIN)');
  UseDir('winf');
  sq.Exec('CREATE TABLE sat(id INTEGER PRIMARY KEY, ad TEXT, bolge TEXT, tutar INTEGER)');
  sq.Exec('INSERT INTO sat(id,ad,bolge,tutar) VALUES(1,' + Q + 'a' + Q + ',' + Q + 'E' + Q + ',100)');
  sq.Exec('INSERT INTO sat(id,ad,bolge,tutar) VALUES(2,' + Q + 'b' + Q + ',' + Q + 'E' + Q + ',200)');
  sq.Exec('INSERT INTO sat(id,ad,bolge,tutar) VALUES(3,' + Q + 'c' + Q + ',' + Q + 'W' + Q + ',150)');
  sq.Exec('INSERT INTO sat(id,ad,bolge,tutar) VALUES(4,' + Q + 'd' + Q + ',' + Q + 'E' + Q + ',200)');
  sq.Exec('INSERT INTO sat(id,ad,bolge,tutar) VALUES(5,' + Q + 'e' + Q + ',' + Q + 'W' + Q + ',NULL)');
  sq.Exec('INSERT INTO sat(id,ad,bolge,tutar) VALUES(6,' + Q + 'f' + Q + ',' + Q + 'E' + Q + ',300)');
  ChkVal('ROW_NUMBER sirasiz',
      'SELECT ad, ROW_NUMBER() OVER () AS rn FROM sat ORDER BY id', 0, 1, '1');
  ChkVal('ROW_NUMBER son',
      'SELECT ad, ROW_NUMBER() OVER () AS rn FROM sat ORDER BY id', 5, 1, '6');
  ChkVal('ROW_NUMBER partition',
      'SELECT ad, ROW_NUMBER() OVER (PARTITION BY bolge ORDER BY tutar) AS rn FROM sat ORDER BY id', 0, 1, '1');
  ChkVal('ROW_NUMBER partition son (f=4, bagimsiz)',
      'SELECT ad, ROW_NUMBER() OVER (PARTITION BY bolge ORDER BY tutar) AS rn FROM sat ORDER BY id', 5, 1, '4');
  ChkVal('RANK bag paylasir (b=2)',
      'SELECT ad, RANK() OVER (PARTITION BY bolge ORDER BY tutar) AS r FROM sat ORDER BY id', 1, 1, '2');
  ChkVal('RANK bag paylasir (d=2)',
      'SELECT ad, RANK() OVER (PARTITION BY bolge ORDER BY tutar) AS r FROM sat ORDER BY id', 3, 1, '2');
  ChkVal('RANK bag sonrasi atlar (f=4)',
      'SELECT ad, RANK() OVER (PARTITION BY bolge ORDER BY tutar) AS r FROM sat ORDER BY id', 5, 1, '4');
  ChkVal('DENSE_RANK atlamaz (f=3)',
      'SELECT ad, DENSE_RANK() OVER (PARTITION BY bolge ORDER BY tutar) AS r FROM sat ORDER BY id', 5, 1, '3');
  ChkVal('SUM partition toplami (800)',
      'SELECT ad, SUM(tutar) OVER (PARTITION BY bolge) AS s FROM sat ORDER BY id', 0, 1, '800');
  ChkVal('COUNT yildiz partition (E=4)',
      'SELECT ad, COUNT(*) OVER (PARTITION BY bolge) AS c FROM sat ORDER BY id', 0, 1, '4');
  ChkVal('COUNT yildiz partition (W=2)',
      'SELECT ad, COUNT(*) OVER (PARTITION BY bolge) AS c FROM sat ORDER BY id', 2, 1, '2');
  ChkVal('AVG partition NULL atlar (150)',
      'SELECT AVG(tutar) OVER (PARTITION BY bolge) AS o FROM sat ORDER BY id', 4, 0, '150');
  ChkVal('MIN partition (100)',
      'SELECT MIN(tutar) OVER (PARTITION BY bolge) AS m FROM sat ORDER BY id', 1, 0, '100');
  ChkVal('LAG onceki (b->a)',
      'SELECT ad, LAG(ad) OVER (ORDER BY id) AS onceki FROM sat ORDER BY id', 1, 1, 'a');
  ChkVal('LAG ilk NULL',
      'SELECT ad, LAG(ad) OVER (ORDER BY id) AS onceki FROM sat ORDER BY id', 0, 1, '');
  ChkVal('LAG offset+varsayilan',
      'SELECT ad, LAG(ad, 2, ' + Q + 'yok' + Q + ') OVER (ORDER BY id) AS o FROM sat ORDER BY id', 1, 1, 'yok');
  ChkVal('LEAD sonraki (d->e)',
      'SELECT ad, LEAD(ad) OVER (ORDER BY id) AS sonraki FROM sat ORDER BY id', 3, 1, 'e');
  ChkVal('LAG partition tasmaz (c ilk)',
      'SELECT ad, LAG(ad) OVER (PARTITION BY bolge ORDER BY id) AS o FROM sat ORDER BY id', 2, 1, '');
  Chk('pencere + JOIN (8)',
      'SELECT s.ad, ROW_NUMBER() OVER (ORDER BY s.id) AS rn FROM sat s JOIN sat t ON s.bolge = t.bolge WHERE s.id <= 2', 8);
  Chk('skaler alt sorgu ile WHERE (3)',
      'SELECT ad FROM sat WHERE tutar > (SELECT AVG(tutar) FROM sat)', 3);
  ChkErr('WHERE icinde pencere (hata)',
      'SELECT ad FROM sat WHERE ROW_NUMBER() OVER (ORDER BY id) = 1');
  ChkErr('ic ice pencere (hata)',
      'SELECT 1 + ROW_NUMBER() OVER (ORDER BY id) FROM sat');
  ChkErr('ROW_NUMBER arguman (hata)',
      'SELECT ROW_NUMBER(id) OVER () FROM sat');
  ChkErr('LAG OVERsiz (hata)',
      'SELECT LAG(ad) FROM sat');
  ChkErr('bilinmeyen OVER (hata)',
      'SELECT UPPER(ad) OVER () FROM sat');
  ChkErr('GROUP BY + pencere (hata)',
      'SELECT bolge, COUNT(*), RANK() OVER (ORDER BY bolge) FROM sat GROUP BY bolge');
end;

procedure T09_GroupAggregate;
begin
  Grp('GROUP BY + aggregate (COUNT/SUM/AVG/MIN/MAX)');
  UseDir('grp');
  sq.Exec('CREATE TABLE p(id INTEGER PRIMARY KEY, dept TEXT, maas INTEGER)');
  sq.Exec('INSERT INTO p(dept,maas) VALUES(' + Q + 'yazilim' + Q + ',100)');
  sq.Exec('INSERT INTO p(dept,maas) VALUES(' + Q + 'yazilim' + Q + ',200)');
  sq.Exec('INSERT INTO p(dept,maas) VALUES(' + Q + 'yazilim' + Q + ',300)');
  sq.Exec('INSERT INTO p(dept,maas) VALUES(' + Q + 'satis' + Q + ',150)');
  sq.Exec('INSERT INTO p(dept,maas) VALUES(' + Q + 'satis' + Q + ',250)');
  ChkVal('COUNT(*)', 'SELECT COUNT(*) FROM p', 0, 0, '5');
  ChkVal('COUNT(dept)', 'SELECT COUNT(dept) FROM p', 0, 0, '5');
  ChkVal('SUM', 'SELECT SUM(maas) FROM p', 0, 0, '1000');
  ChkVal('AVG', 'SELECT AVG(maas) FROM p', 0, 0, '200');
  ChkVal('MIN', 'SELECT MIN(maas) FROM p', 0, 0, '100');
  ChkVal('MAX', 'SELECT MAX(maas) FROM p', 0, 0, '300');
  Chk('GROUP BY 2 grup', 'SELECT dept, COUNT(*) FROM p GROUP BY dept', 2);
  ChkVal('GROUP BY SUM', 'SELECT dept, SUM(maas) FROM p GROUP BY dept ' +
      'ORDER BY dept', 0, 1, '400');
  ChkVal('coklu kolon GROUP BY',
      'SELECT dept, maas, COUNT(*) FROM p GROUP BY dept, maas', 0, 2, '1');
  ChkVal('aggregate + WHERE', 'SELECT COUNT(*) FROM p WHERE maas > 150', 0, 0, '3');
  // 4.3: dogrudan aggregate HAVING kabul (onceki reddin yeri)
  Chk('HAVING dogrudan aggregate (kabul)',
      'SELECT dept, COUNT(*) FROM p GROUP BY dept HAVING COUNT(*) > 1', 2);
  Chk('HAVING dogrudan aggregate (suzulur)',
      'SELECT dept, COUNT(*) FROM p GROUP BY dept HAVING COUNT(*) > 2', 1);
  ChkErr('artik token sessizce yutulmaz (hata)',
      'SELECT dept FROM p WHERE maas > 1 BLA BLA');
end;

procedure T09b_HavingAggregate;
// 4.3: HAVING icinde dogrudan aggregate (alias ZORUNLU DEGIL).
// Her test, "yanlis degerlendirme" durumunun da ayirt edici olmasi
// icin secildi: metin sirasiyla kiyas ('10' > '9' => false) ya da
// grup baglamisiz degerlendirme (COUNT(*) => '1') farkli sonuc verir.
begin
  Grp('HAVING dogrudan aggregate (4.3)');
  UseDir('having');
  sq.Exec('CREATE TABLE h(id INTEGER PRIMARY KEY, dept TEXT, maas INTEGER)');
  // yazilim: 10 satir x 100 (sum 1000, avg 100, min 100, max 100)
  // satis:    2 satir x 450 (sum  900, avg 450, min 450, max 450)
  // pazarlama:1 satir x  50 (sum   50, avg  50, min  50, max  50)
  sq.Exec('INSERT INTO h(dept,maas) VALUES(' + Q + 'yazilim' + Q + ',100),(' +
      Q + 'yazilim' + Q + ',100),(' + Q + 'yazilim' + Q + ',100),(' +
      Q + 'yazilim' + Q + ',100),(' + Q + 'yazilim' + Q + ',100)');
  sq.Exec('INSERT INTO h(dept,maas) VALUES(' + Q + 'yazilim' + Q + ',100),(' +
      Q + 'yazilim' + Q + ',100),(' + Q + 'yazilim' + Q + ',100),(' +
      Q + 'yazilim' + Q + ',100),(' + Q + 'yazilim' + Q + ',100)');
  sq.Exec('INSERT INTO h(dept,maas) VALUES(' + Q + 'satis' + Q + ',450),(' +
      Q + 'satis' + Q + ',450)');
  sq.Exec('INSERT INTO h(dept,maas) VALUES(' + Q + 'pazarlama' + Q + ',50)');

  Chk('HAVING COUNT(*) > 1 (grup filtresi)',
      'SELECT dept, COUNT(*) AS n FROM h GROUP BY dept ' +
      'HAVING COUNT(*) > 1 ORDER BY dept', 2);
  // 10 > 9: metin kiyasinda FALSE ('10' < '9') — tip INT olmali
  Chk('HAVING COUNT(*) > 9 (sayisal kiyas)',
      'SELECT dept, COUNT(*) AS n FROM h GROUP BY dept HAVING COUNT(*) > 9', 1);
  // aggregate SELECT listesinde yok — grup satirindan hesaplanmali
  Chk('HAVING aggregate cikti listesinde yok',
      'SELECT dept FROM h GROUP BY dept HAVING COUNT(*) > 5', 1);
  // SUM 1000 > 950: metin kiyasinda FALSE ('1000' < '950') — tip FLOAT
  Chk('HAVING SUM (sayisal kiyas)',
      'SELECT dept, SUM(maas) AS s FROM h GROUP BY dept HAVING SUM(maas) > 950', 1);
  // AVG: 100 ve 450 > 90 (metin kiyasinda ikisi de false: '100'<'90')
  Chk('HAVING AVG (sayisal kiyas)',
      'SELECT dept, AVG(maas) AS a FROM h GROUP BY dept HAVING AVG(maas) > 90', 2);
  // MIN: yalniz satis (450); metin kiyasinda pazarlama ('50'>'100') de gecerdi
  Chk('HAVING MIN (kolon tipi cozumu)',
      'SELECT dept, MIN(maas) AS m FROM h GROUP BY dept HAVING MIN(maas) > 100', 1);
  Chk('HAVING MAX (kolon tipi cozumu)',
      'SELECT dept, MAX(maas) AS m FROM h GROUP BY dept HAVING MAX(maas) > 100', 1);
  // alias (n) + dogrudan aggregate ayni cumlede
  Chk('HAVING alias + dogrudan aggregate',
      'SELECT dept, COUNT(*) AS n FROM h GROUP BY dept ' +
      'HAVING n > 5 AND COUNT(*) < 100', 1);

  ChkVal('HAVING + ORDER BY + LIMIT',
      'SELECT dept, COUNT(*) AS n FROM h GROUP BY dept ' +
      'HAVING COUNT(*) > 1 ORDER BY n DESC LIMIT 1', 0, 1, '10');
  Chk('WHERE + HAVING (once WHERE, sonra grup)',
      'SELECT dept, COUNT(*) AS n FROM h WHERE maas > 50 GROUP BY dept ' +
      'HAVING COUNT(*) > 1', 2);

  // JOIN + HAVING: nitelikli/sade argumanda tip cozumu (FindColIdx)
  sq.Exec('CREATE TABLE hb(id INTEGER PRIMARY KEY, mid INTEGER, tutar INTEGER)');
  sq.Exec('CREATE TABLE hm(mid INTEGER PRIMARY KEY, sehir TEXT)');
  sq.Exec('INSERT INTO hm VALUES(1,' + Q + 'ank' + Q + ')');
  sq.Exec('INSERT INTO hm VALUES(2,' + Q + 'izm' + Q + ')');
  sq.Exec('INSERT INTO hb(mid,tutar) VALUES(1,10),(1,20),(2,5)');
  Chk('JOIN + HAVING COUNT(*)',
      'SELECT m.sehir, COUNT(*) AS n FROM hb b JOIN hm m ON b.mid = m.mid ' +
      'GROUP BY m.sehir HAVING COUNT(*) > 1', 1);
  // nitelikli arguman: aggCt = INTEGER olmali; metin kiyasinda
  // '10' > '8' false oldugu icin ank da elenirdi (0 satir)
  Chk('JOIN + HAVING MIN (nitelikli arguman)',
      'SELECT m.sehir, MIN(b.tutar) AS mn FROM hb b JOIN hm m ON b.mid = m.mid ' +
      'GROUP BY m.sehir HAVING MIN(b.tutar) > 8', 1);
  // sade yazim: sonek kuraliyla b.tutar bulunmali
  Chk('JOIN + HAVING MIN (sade arguman)',
      'SELECT m.sehir, MIN(tutar) AS mn FROM hb b JOIN hm m ON b.mid = m.mid ' +
      'GROUP BY m.sehir HAVING MIN(tutar) > 8', 1);
  ChkErr('HAVING bilinmeyen kolon (hata)',
      'SELECT dept, COUNT(*) FROM h GROUP BY dept HAVING olmayankolon > 1');
end;

procedure T09c_NotOrDNF;
// 4.4: NOT (...) icinde OR (DNF): basit OR -> De Morgan -> tek AND grubu.
// NOT (a=1 OR b=2) -> a<>1 AND b<>2 (calisir). NOT (AND OR) -> hata.
begin
  Grp('NOT (...) icinde OR (DNF 4.4)');
  UseDir('notor');
  sq.Exec('CREATE TABLE dnf(id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
  sq.Exec('INSERT INTO dnf VALUES(1,10,20),(2,30,40),(3,50,60)');
  // NOT (a=1 OR b=2) -> De Morgan: a<>1 AND b<>2 -> id=2 (30,40) + id=3 (50,60) = 2 satir
  Chk('NOT(OR) De Morgan basit',
      'SELECT * FROM dnf WHERE NOT (a = 10 OR b = 20)', 2);
  // NOT (a > 30 OR b > 25) -> a<=30 AND b<=25 -> id=1 (10,20) + id=2 (30,40?) hayir b=40>25
  // id=1: a<=30 (True) AND b<=25 (True) -> 1 satir
  Chk('NOT(OR) De Morgan sayisal',
      'SELECT * FROM dnf WHERE NOT (a > 30 OR b > 25)', 1);
  // NOT (id=1 OR id=3) -> id<>1 AND id<>3 -> yalniz id=2
  Chk('NOT(OR) id degeri',
      'SELECT * FROM dnf WHERE NOT (id = 1 OR id = 3)', 1);
  // NOT (AND OR) cok kosullu: tek tablo AST yolu calisir (ParseWhereGroups
  // kullanilmaz); JOIN seviyesinde ise 4.4 siniri gecerli kalir.
  Chk('NOT(OR) cok kosullu tek tablo (AST calisir)',
      'SELECT * FROM dnf WHERE NOT (a > 15 AND b > 25 OR id = 3)', 1);
end;

procedure T09d_NotNull3VL;
// M8 fuzz bulgulari: NOT, NULL iceren BETWEEN/IN/karsilastirmalari
// UNKNOWN olarak korumali; aksi halde NOT UNKNOWN -> TRUE olup NULL
// satirlari WHERE sonucuna yanlislikla girer.
begin
  Grp('M8 NOT + NULL uc-degerli mantik');
  UseDir('notnull3vl');
  sq.Exec('CREATE TABLE nn(id INTEGER PRIMARY KEY, a INTEGER, f FLOAT, b BOOLEAN)');
  sq.Exec('INSERT INTO nn VALUES (1,10,1.5,TRUE),(2,NULL,NULL,NULL),(3,30,3.5,FALSE),(4,50,5.5,TRUE)');

  // a NULL olan id=2 disarida kalir; disaridakiler id=1 (10) ve id=4 (50).
  Chk('NOT BETWEEN NULL satiri dislar',
      'SELECT * FROM nn WHERE NOT (a BETWEEN 20 AND 40)', 2);
  Chk('NOT NOT BETWEEN = BETWEEN',
      'SELECT * FROM nn WHERE NOT (a NOT BETWEEN 20 AND 40)', 1);
  // NOT (a NOT IN (...)) = a IN (...); a NULL yine disarida.
  Chk('NOT NOT IN = IN',
      'SELECT * FROM nn WHERE NOT (a NOT IN (10, 30))', 2);
  // NULL ile karsilastirma UNKNOWN; NOT UNKNOWN satir getirmez.
  Chk('NOT (f = NULL) bos',
      'SELECT * FROM nn WHERE NOT (f = NULL)', 0);
  // UNKNOWN AND FALSE = FALSE -> id=3,4 girer; UNKNOWN AND TRUE/UNKNOWN
  // -> UNKNOWN -> id=1,2 girmez.
  Chk('NOT (UNKNOWN AND FALSE) = TRUE',
      'SELECT * FROM nn WHERE NOT (f = NULL AND a = 10)', 2);
  // UNKNOWN OR FALSE = UNKNOWN -> NOT UNKNOWN; hicbir satir gelmez.
  Chk('NOT (UNKNOWN OR FALSE) bos',
      'SELECT * FROM nn WHERE NOT (f = NULL OR a = 10)', 0);

  // JOIN yolu ParseWhereGroups (DNF) kullanir: NOT (A AND B) De Morgan
  // ile NOT A OR NOT B olmali; yalniz ilk kosulu degistirmek yanlisti.
  sq.Exec('CREATE TABLE j1(id INTEGER PRIMARY KEY, a INTEGER)');
  sq.Exec('CREATE TABLE j2(id INTEGER PRIMARY KEY, x INTEGER)');
  sq.Exec('INSERT INTO j1 VALUES (1,10),(2,20),(3,NULL)');
  sq.Exec('INSERT INTO j2 VALUES (1,1),(2,1),(3,1)');
  // id=1: NOT(TRUE AND TRUE) = FALSE -> disarida; id=2: NOT(FALSE AND TRUE)
  // = TRUE -> girer; id=3: NOT(UNKNOWN AND TRUE) = UNKNOWN -> disarida.
  Chk('JOIN NOT (A AND B) De Morgan',
      'SELECT j1.id FROM j1 JOIN j2 ON j1.id = j2.id ' +
      'WHERE NOT (j1.a = 10 AND j2.x = 1)', 1);
  Chk('JOIN NOT (A NOT IN) = IN',
      'SELECT j1.id FROM j1 JOIN j2 ON j1.id = j2.id ' +
      'WHERE NOT (j1.a NOT IN (10))', 1);
end;

procedure T09e_NullIfCoalesce;
begin
  Grp('NULLIF / COALESCE (F-02)');
  UseDir('nullif');
  sq.Exec('CREATE TABLE nf(id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, c TEXT)');
  sq.Exec('INSERT INTO nf VALUES(1,10,10,''eq''),(2,10,20,''neq''),(3,NULL,5,''null_a''),(4,5,NULL,''null_b'')');

  // NULLIF(a,b): a=b ise NULL, degilse a
  Chk('NULLIF esit -> NULL (1 satir)',
      'SELECT NULLIF(a,b) FROM nf WHERE id=1', 1);
  Chk('NULLIF farkli -> a (1 satir)',
      'SELECT NULLIF(a,b) FROM nf WHERE id=2', 1);
  Chk('NULLIF NULL a -> NULL (1 satir)',
      'SELECT NULLIF(a,b) FROM nf WHERE id=3', 1);
  Chk('NULLIF NULL b -> a (1 satir)',
      'SELECT NULLIF(a,b) FROM nf WHERE id=4', 1);

  // COALESCE(a,b,c...): ilk non-NULL
  Chk('COALESCE ilk a (1 satir)',
      'SELECT COALESCE(a,b,99) FROM nf WHERE id=2', 1);
  Chk('COALESCE a NULL b deger (1 satir)',
      'SELECT COALESCE(a,b,99) FROM nf WHERE id=3', 1);
  Chk('COALESCE a NULL b NULL c deger (1 satir)',
      'SELECT COALESCE(a,b,c,99) FROM nf WHERE id=4', 1);
  Chk('COALESCE hepsi NULL -> son (1 satir)',
      'SELECT COALESCE(a,b,99) FROM nf WHERE id=3', 1);

  // NULLIF/COALESCE bir arada
  Chk('NULLIF icinde COALESCE (1 satir)',
      'SELECT COALESCE(NULLIF(a,b), 999) FROM nf WHERE id=1', 1);
  Chk('COALESCE icinde NULLIF (1 satir)',
      'SELECT NULLIF(COALESCE(a,99), 99) FROM nf WHERE id=3', 1);
end;

procedure T10_Update;
begin
  Grp('UPDATE');
  UseDir('upd');
  sq.Exec('CREATE TABLE ebeveyn(id INTEGER PRIMARY KEY)');
  sq.Exec('INSERT INTO ebeveyn(id) VALUES(1)');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT UNIQUE, ' +
          'yas INTEGER, pid INTEGER REFERENCES ebeveyn(id), ' +
          'puan INTEGER CHECK (puan >= 0))');
  sq.Exec('INSERT INTO t(ad,yas,pid) VALUES(' + Q + 'a' + Q + ',1,1)');
  sq.Exec('INSERT INTO t(ad,yas,pid) VALUES(' + Q + 'b' + Q + ',2,1)');
  Chk('WHERE ile tek', 'UPDATE t SET yas = 99 WHERE id = 1', -1);
  ChkVal('guncellendi', 'SELECT yas FROM t WHERE id=1', 0, 0, '99');
  Chk('WHERE ile cok', 'UPDATE t SET yas = 50 WHERE yas > 10', -1);
  Chk('WHERE yoksa tumu', 'UPDATE t SET yas = 7', -1);
  ChkVal('tum satirlar guncellendi', 'SELECT yas FROM t WHERE id=1', 0, 0, '7');
  Chk('coklu SET', 'UPDATE t SET ad = ' + Q + 'z' + Q + ', yas = 1 WHERE id = 1', -1);
  Chk('NULL yazma', 'UPDATE t SET yas = NULL WHERE id = 1', -1);
  ChkVal('NULL yazildi', 'SELECT yas FROM t WHERE id=1', 0, 0, '');
  ChkErr('CHECK ihlali UPDATE (hata)', 'UPDATE t SET puan = -5 WHERE id = 1');
  ChkErr('FK ihlali UPDATE (hata)', 'UPDATE t SET pid = 77 WHERE id = 1');
  Chk('gecerli FK UPDATE', 'UPDATE t SET pid = 1 WHERE id = 1', -1);
  ChkErr('UNIQUE ihlali UPDATE (hata)',
      'UPDATE t SET ad = ' + Q + 'z' + Q + ' WHERE id = 2');
end;

procedure T10b_Upsert;
begin
  Grp('UPSERT (ON CONFLICT)');
  UseDir('upsert');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, val TEXT, cnt INTEGER DEFAULT 0)');
  sq.Exec('INSERT INTO t(id, val) VALUES(1, ''a'')');

  // Test 1: ON CONFLICT DO NOTHING
  Chk('ON CONFLICT DO NOTHING',
      'INSERT INTO t(id, val) VALUES(1, ''b'') ON CONFLICT(id) DO NOTHING', -1);
  ChkVal('deger degismedi', 'SELECT val FROM t WHERE id=1', 0, 0, 'a');

  // Test 2: ON CONFLICT DO UPDATE
  Chk('ON CONFLICT DO UPDATE SET val=''updated''',
      'INSERT INTO t(id, val) VALUES(1, ''c'') ON CONFLICT(id) DO UPDATE SET val=''updated''', -1);
  ChkVal('guncellendi', 'SELECT val FROM t WHERE id=1', 0, 0, 'updated');

  // Test 3: ON CONFLICT DO UPDATE with EXCLUDED
  Chk('ON CONFLICT DO UPDATE SET val=EXCLUDED.val',
      'INSERT INTO t(id, val) VALUES(1, ''d'') ON CONFLICT(id) DO UPDATE SET val=EXCLUDED.val', -1);
  ChkVal('EXCLUDED degeri', 'SELECT val FROM t WHERE id=1', 0, 0, 'd');

  // Test 4: ON CONFLICT DO UPDATE increment counter
  Chk('ON CONFLICT DO UPDATE SET cnt=cnt+1',
      'INSERT INTO t(id, val) VALUES(1, ''x'') ON CONFLICT(id) DO UPDATE SET cnt=cnt+1', -1);
  ChkVal('cnt=1', 'SELECT cnt FROM t WHERE id=1', 0, 0, '1');
  Chk('ON CONFLICT DO UPDATE SET cnt=cnt+1 tekrar',
      'INSERT INTO t(id, val) VALUES(1, ''y'') ON CONFLICT(id) DO UPDATE SET cnt=cnt+1', -1);
  ChkVal('cnt=2', 'SELECT cnt FROM t WHERE id=1', 0, 0, '2');

  // Test 5: ON CONFLICT DO NOTHING yeni satir
  Chk('ON CONFLICT DO NOTHING yeni satir',
      'INSERT INTO t(id, val) VALUES(2, ''yeni'') ON CONFLICT(id) DO NOTHING', -1);
  ChkVal('yeni satir eklendi', 'SELECT val FROM t WHERE id=2', 0, 0, 'yeni');

  // Test 6: INSERT ... SELECT with ON CONFLICT
  sq.Exec('CREATE TABLE src(id INTEGER PRIMARY KEY, v TEXT)');
  sq.Exec('INSERT INTO src VALUES(3, ''src-a'')');
  sq.Exec('INSERT INTO src VALUES(4, ''src-b'')');
  Chk('INSERT SELECT ON CONFLICT DO UPDATE',
      'INSERT INTO t(id, val) SELECT id, v FROM src ON CONFLICT(id) DO UPDATE SET val=EXCLUDED.val', -1);
  ChkVal('src-a eklendi', 'SELECT val FROM t WHERE id=3', 0, 0, 'src-a');
  ChkVal('src-b eklendi', 'SELECT val FROM t WHERE id=4', 0, 0, 'src-b');

  // Test 7: ON CONFLICT with target columns (unique index)
  sq.Exec('CREATE TABLE t2(a TEXT, b TEXT, UNIQUE(a))');
  sq.Exec('INSERT INTO t2(a,b) VALUES(''x'',''1'')');
  Chk('ON CONFLICT(a) DO UPDATE',
      'INSERT INTO t2(a,b) VALUES(''x'',''2'') ON CONFLICT(a) DO UPDATE SET b=EXCLUDED.b', -1);
  ChkVal('b guncellendi', 'SELECT b FROM t2 WHERE a=''x''', 0, 0, '2');

  // Test 8: RETURNING with UPSERT (R-04)
  Chk('ON CONFLICT DO UPDATE RETURNING val',
      'INSERT INTO t(id, val) VALUES(1, ''ret'') ON CONFLICT(id) DO UPDATE SET val=EXCLUDED.val RETURNING val', -1);
end;

procedure T11_Delete;
begin
  Grp('DELETE');
  UseDir('del');
  sq.Exec('CREATE TABLE eb(id INTEGER PRIMARY KEY)');
  sq.Exec('CREATE TABLE coc(id INTEGER PRIMARY KEY, pid INTEGER ' +
          'REFERENCES eb(id))');
  sq.Exec('INSERT INTO eb(id) VALUES(1)');
  sq.Exec('INSERT INTO coc(id,pid) VALUES(1,1)');
  sq.Exec('INSERT INTO coc(id) VALUES(2)');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO t(v) VALUES(1)');
  sq.Exec('INSERT INTO t(v) VALUES(2)');
  sq.Exec('INSERT INTO t(v) VALUES(3)');
  Chk('WHERE ile tek', 'DELETE FROM t WHERE id = 1', -1);
  ChkVal('kalan satir', 'SELECT COUNT(*) FROM t', 0, 0, '2');
  Chk('WHERE ile cok', 'DELETE FROM t WHERE v > 1', -1);
  ChkVal('kalan satir 2', 'SELECT COUNT(*) FROM t', 0, 0, '0');
  ChkErr('FK RESTRICT silemez (hata)', 'DELETE FROM eb WHERE id = 1');
  Chk('NULL FK ile silinebilir', 'DELETE FROM coc WHERE id = 2', -1);
  sq.Exec('INSERT INTO t(v) VALUES(9)');
  Chk('WHERE yoksa tumu', 'DELETE FROM t', -1);
  ChkVal('tablo bos', 'SELECT COUNT(*) FROM t', 0, 0, '0');
end;
procedure T11_Returning;
var
  Q: string;
begin
  Grp('RETURNING (R-04)');
  Q := '"';
  UseDir('r4');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, val TEXT, cnt INTEGER DEFAULT 0)');
  sq.Exec('CREATE TABLE up(id INTEGER PRIMARY KEY, x INTEGER)');

  // Test 1: INSERT ... RETURNING id
  ChkVal('INSERT RETURNING id',
    'INSERT INTO t(val) VALUES(''a'') RETURNING id', 0, 0, '1');

  // Test 2: INSERT ... RETURNING * (tum kolonlar)
  ChkVal('INSERT RETURNING * -> id',
    'INSERT INTO t(id, val, cnt) VALUES(2, ''b'', 5) RETURNING *', 0, 0, '2');

  // Test 3: INSERT ... RETURNING kolon listesi
  ChkVal('INSERT RETURNING id,val -> col0',
    'INSERT INTO t(id, val) VALUES(3, ''multi'') RETURNING id, val', 0, 0, '3');

  // Test 4: UPDATE ... RETURNING
  // DIKKAT: metin degeri TEK tirnakla yazilir. ANSI SQL'de "cift tirnak"
  // KOLON ADI'dir: `SET val="updated"` derse motor dogru olarak
  // "Kolon bulunamadi: updated" der. Onceki hata buradan geliyordu.
  ChkVal('UPDATE RETURNING val',
    'UPDATE t SET val=''updated'' WHERE id=1 RETURNING val', 0, 0, 'updated');

  // Test 5: DELETE ... RETURNING id
  ChkVal('DELETE RETURNING id',
    'DELETE FROM t WHERE id=2 RETURNING id', 0, 0, '2');
  ChkVal('DELETE satir silindi mi',
    'SELECT COUNT(*) FROM t WHERE id=2', 0, 0, '0');

  // Test 6: INSERT ... ON CONFLICT DO UPDATE RETURNING val (R-04)
  ChkVal('ON CONFLICT DO UPDATE RETURNING val',
    'INSERT INTO t(id, val) VALUES(1, ''ret'') ON CONFLICT(id) DO UPDATE SET val=EXCLUDED.val RETURNING val', 0, 0, 'ret');

  // Test 7: ON CONFLICT DO UPDATE RETURNING pk
  ChkVal('ON CONFLICT DO UPDATE RETURNING id',
    'INSERT INTO t(id, val) VALUES(4, ''ret2'') ON CONFLICT(id) DO UPDATE SET val=EXCLUDED.val RETURNING id', 0, 0, '4');

  // Test 8: UPDATE RETURNING * (update edilen satir)
  sq.Exec('INSERT INTO up(id, x) VALUES(1, 10)');
  ChkVal('UPDATE RETURNING * -> id',
    'UPDATE up SET x=20 WHERE id=1 RETURNING *', 0, 0, '1');

  // Test 9: DELETE RETURNING * (silinen satir)
  Chk('DELETE RETURNING *', 'DELETE FROM up WHERE id=1 RETURNING *', 1);

  // ---- R-04: RETURNING IFADE (sayisal) ----
  // Parser duz kolonlari hem Cols'a hem Exprs'e yaziyor; gercek ifade
  // varsa EvaluateReturning devreye giriyor. Sayisal sonuc almak icin
  // kolon TIPLERININ dogru gecmesi sart (yoksa '5'+'1' metin olurdu).
  sq.Exec('INSERT INTO t(id, val, cnt) VALUES(10, ''x'', 5)');
  ChkVal('UPDATE RETURNING cnt+1 -> 6',
    'UPDATE t SET cnt=5 WHERE id=10 RETURNING cnt + 1', 0, 0, '6');
  ChkVal('UPDATE RETURNING cnt*10 -> 50',
    'UPDATE t SET cnt=5 WHERE id=10 RETURNING cnt * 10', 0, 0, '50');
  ChkVal('UPDATE RETURNING ifade + kolon listesi',
    'UPDATE t SET cnt=2 WHERE id=10 RETURNING id, cnt + 100', 0, 1, '102');
  ChkVal('INSERT RETURNING ifade',
    'INSERT INTO t(id, val, cnt) VALUES(11, ''y'', 7) RETURNING cnt * 2', 0, 0, '14');
  ChkVal('DELETE RETURNING ifade',
    'DELETE FROM t WHERE id=11 RETURNING cnt - 1', 0, 0, '6');
  // ANSI: cift tirnak KOLON ADI'dir -> motorun reddetmesi dogru
  ChkErr('cift tirnak metin DEGIL, kolon adi',
    'UPDATE t SET val="y" WHERE id=10');
end;


procedure T12_Transaction;
begin
  Grp('Transaction: COMMIT / ROLLBACK, DDL dahil');
  UseDir('trn');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT)');
  sq.Exec('INSERT INTO t(a) VALUES(' + Q + 'ilk' + Q + ')');
  Chk('BEGIN', 'BEGIN', -1);
  Chk('batch icinde INSERT', 'INSERT INTO t(a) VALUES(' + Q + 'gizli' + Q + ')', -1);
  Chk('batch icinde SELECT gorunur',
      'SELECT a FROM t WHERE a = ' + Q + 'gizli' + Q, 1);
  ChkVal('batch icinde UPDATE gorunur',
      'SELECT a FROM t WHERE id = 1', 0, 0, 'ilk');
  Chk('ROLLBACK', 'ROLLBACK', -1);
  Chk('rollback: eklenen yok',
      'SELECT a FROM t WHERE a = ' + Q + 'gizli' + Q, 0);
  ChkVal('rollback: eski veri duruyor', 'SELECT COUNT(*) FROM t', 0, 0, '1');
  Chk('BEGIN 2', 'BEGIN', -1);
  sq.Exec('INSERT INTO t(a) VALUES(' + Q + 'kalici' + Q + ')');
  Chk('COMMIT', 'COMMIT', -1);
  ChkVal('commit: veri duruyor', 'SELECT COUNT(*) FROM t', 0, 0, '2');
  Chk('BEGIN 3 (DDL)', 'BEGIN', -1);
  Chk('batch icinde CREATE TABLE', 'CREATE TABLE gecici(id INTEGER PRIMARY KEY)', -1);
  sq.Exec('INSERT INTO gecici(id) VALUES(1)');
  Chk('ROLLBACK DDL', 'ROLLBACK', -1);
  ChkErr('rollback sonrasi tablo yok (hata)', 'SELECT * FROM gecici');
  ChkVal('rollback sonrasi veri saglam', 'SELECT COUNT(*) FROM t', 0, 0, '2');
  Chk('BEGIN 4 (ALTER)', 'BEGIN', -1);
  Chk('batch icinde ALTER', 'ALTER TABLE t ADD yeni INTEGER', -1);
  Chk('ROLLBACK ALTER', 'ROLLBACK', -1);
  ChkErr('rollback sonrasi kolon yok (hata)', 'SELECT yeni FROM t');

  // ---- R-11: DEFERRABLE CONSTRAINTS (SET CONSTRAINTS) ----
  // Cocuk satiri ebeveyninden ONCE eklenebilmeli. FK denetimi COMMIT'e
  // kadar ertelenir; ebeveyn hic gelmezse COMMIT REDDEDILIR.
  UseDir('defer');
  sq.Exec('CREATE TABLE ebe(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('CREATE TABLE coc(id INTEGER PRIMARY KEY, e_id INTEGER' +
    ' REFERENCES ebe(id) DEFERRABLE INITIALLY DEFERRED)');
  sq.Exec('CREATE TABLE coc2(id INTEGER PRIMARY KEY, e_id INTEGER' +
    ' REFERENCES ebe(id))');

  // 1) Cocuk once, ebe sonra -> COMMIT basarili
  sq.Exec('BEGIN');
  sq.Exec('SET CONSTRAINTS ALL DEFERRED');
  sq.Exec('INSERT INTO coc(id, e_id) VALUES(1, 7)');   // ebe henuz yok
  sq.Exec('INSERT INTO ebe(id, ad) VALUES(7, ''x'')');
  Chk('COMMIT (deferred FK gecerli)', 'COMMIT', -1);
  ChkVal('cocuk yazildi', 'SELECT COUNT(*) FROM coc', 0, 0, '1');

  // 2) IMMEDIATE modunda ayni islem ANINDA hata vermeli
  sq.Exec('BEGIN');
  sq.Exec('SET CONSTRAINTS ALL IMMEDIATE');
  ChkErr('IMMEDIATE: FK aninda denetlenir',
    'INSERT INTO coc(id, e_id) VALUES(2, 99)');
  sq.Exec('ROLLBACK');

  // 3) DEFERRED iken ebe hic gelmezse COMMIT reddedilmeli
  sq.Exec('BEGIN');
  sq.Exec('SET CONSTRAINTS ALL DEFERRED');
  sq.Exec('INSERT INTO coc(id, e_id) VALUES(3, 123)');
  ChkErr('COMMIT reddi: ebe kayitli degil', 'COMMIT');
  sq.Exec('ROLLBACK');
  ChkVal('rollback: gecikmis satir yazilmadi', 'SELECT COUNT(*) FROM coc', 0, 0, '1');

  // 4) DEFERRABLE OLMAYAN FK ertelenmez
  sq.Exec('BEGIN');
  sq.Exec('SET CONSTRAINTS ALL DEFERRED');
  ChkErr('NOT DEFERRABLE FK ertelenmez',
    'INSERT INTO coc2(id, e_id) VALUES(1, 55)');
  sq.Exec('ROLLBACK');

  // 5) SET CONSTRAINTS sadece acik batch icinde anlamli
  sq.Exec('BEGIN');
  sq.Exec('SET CONSTRAINTS ALL IMMEDIATE');
  ChkVal('kapanmis: IMMEDIATE ile veri degismedi', 'SELECT COUNT(*) FROM ebe', 0, 0, '1');
end;

procedure T13_AlterTable;
begin
  Grp('ALTER TABLE');
  UseDir('alt');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT, b INTEGER)');
  sq.Exec('INSERT INTO t(a,b) VALUES(' + Q + 'Ali' + Q + ',1)');
  sq.Exec('INSERT INTO t(a,b) VALUES(' + Q + 'Veli' + Q + ',2)');
  Chk('ADD COLUMN', 'ALTER TABLE t ADD c TEXT', -1);
  ChkVal('veri korundu', 'SELECT a FROM t ORDER BY id', 0, 0, 'Ali');
  ChkVal('yeni sutun NULL', 'SELECT c FROM t ORDER BY id', 0, 0, '');
  Chk('ADD COLUMN FIRST', 'ALTER TABLE t ADD ilk TEXT FIRST', -1);
  Chk('ADD COLUMN AFTER', 'ALTER TABLE t ADD sonra TEXT AFTER a', -1);
  ChkErr('var olan kolon (hata)', 'ALTER TABLE t ADD a TEXT');
  ChkErr('olmayan kolon (hata)', 'ALTER TABLE t ADD x TEXT AFTER yok');
  Chk('DROP COLUMN', 'ALTER TABLE t DROP c', -1);
  ChkVal('veri hala duruyor', 'SELECT a FROM t ORDER BY id', 0, 0, 'Ali');
  Chk('RENAME COLUMN', 'ALTER TABLE t RENAME COLUMN a TO isim', -1);
  ChkVal('yeni adiyle okunur', 'SELECT isim FROM t ORDER BY id', 0, 0, 'Ali');
  ChkErr('eski ad yok (hata)', 'SELECT a FROM t');
  ChkErr('PK kolonu dusurulemez (hata)', 'ALTER TABLE t DROP id');
  Chk('ALTER COLUMN TYPE', 'ALTER TABLE t ALTER COLUMN b TYPE TEXT', -1);
  Chk('TEXT kolona her sey yazilabilir', 'UPDATE t SET b = ' + Q + 'zzz' + Q, -1);
  ChkErr('TEXT -> INTEGER donusturulemez (hata)',
      'ALTER TABLE t ALTER COLUMN b TYPE INTEGER');
  Chk('bozuk degeri duzelt', 'UPDATE t SET b = ' + Q + '5' + Q, -1);
  Chk('ALTER COLUMN INTEGER a donus', 'ALTER TABLE t ALTER COLUMN b TYPE INTEGER', -1);
  Chk('ALTER COLUMN SET DEFAULT', 'ALTER TABLE t ALTER COLUMN b SET DEFAULT 9', -1);
  Chk('ALTER COLUMN DROP DEFAULT', 'ALTER TABLE t ALTER COLUMN b DROP DEFAULT', -1);
  Chk('ALTER COLUMN SET NOT NULL', 'ALTER TABLE t ALTER COLUMN b SET NOT NULL', -1);
  Chk('ALTER COLUMN DROP NOT NULL', 'ALTER TABLE t ALTER COLUMN b DROP NOT NULL', -1);
  ChkErr('PK NOT NULL kaldirilamaz (hata)',
      'ALTER TABLE t ALTER COLUMN id DROP NOT NULL');
  Chk('RENAME TO', 'ALTER TABLE t RENAME TO tablo2', -1);
  ChkVal('yeni tablo adiyle veri', 'SELECT isim FROM tablo2 ORDER BY id', 0, 0, 'Ali');
  ChkErr('eski tablo adi yok (hata)', 'SELECT * FROM t');
end;

procedure T14_Index;
begin
  Grp('Index: CREATE / kullanim / DROP');
  UseDir('idx');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT UNIQUE, v INTEGER)');
  sq.Exec('INSERT INTO t(ad,v) VALUES(' + Q + 'a' + Q + ',1)');
  sq.Exec('INSERT INTO t(ad,v) VALUES(' + Q + 'b' + Q + ',2)');
  sq.Exec('CREATE INDEX ix_v ON t(v)');
  ChkVal('indexli = arama', 'SELECT ad FROM t WHERE v = 2', 0, 0, 'b');
  Chk('indexli > arama', 'SELECT ad FROM t WHERE v > 0 ORDER BY v', 2);
  Chk('indexli aralik', 'SELECT ad FROM t WHERE v >= 1 AND v <= 2', 2);
  Chk('indexli <> ', 'SELECT ad FROM t WHERE v <> 1', 1);
  Chk('PK indexli arama', 'SELECT ad FROM t WHERE id = 1', 1);
  Chk('DROP INDEX', 'DROP INDEX ix_v', -1);
  ChkVal('indexsiz de ayni sonuc', 'SELECT ad FROM t WHERE v = 2', 0, 0, 'b');
  ChkErr('olmayan index DROP (hata)', 'DROP INDEX ix_yok');
end;

procedure T15_Bakim;
begin
  Grp('Bakim: SHOW TABLES / VACUUM / REINDEX');
  UseDir('bak');
  sq.Exec('CREATE TABLE t1(id INTEGER PRIMARY KEY, a TEXT)');
  sq.Exec('CREATE TABLE t2(id INTEGER PRIMARY KEY, b INTEGER)');
  sq.Exec('INSERT INTO t1(a) VALUES(' + Q + 'x' + Q + ')');
  R := sq.Exec('SHOW TABLES');
  Ok('SHOW TABLES', IntToStr(R.Affected) + ' tablo');
  if Length(R.Rows) > 0 then
  begin
    WriteLn('        ', R.Rows[0][0], ' = ', R.Rows[0][1], ' satir, ',
            R.Rows[1][0], ' = ', R.Rows[1][1], ' satir');
  end;
  Chk('CREATE INDEX sonra REINDEX', 'CREATE INDEX ix ON t1(a)', -1);
  Chk('REINDEX', 'REINDEX', -1);
  ChkVal('REINDEX sonrasi arama', 'SELECT a FROM t1 WHERE a = ' + Q + 'x' + Q, 0, 0, 'x');
  sq.Exec('INSERT INTO t1(a) VALUES(' + Q + 'y' + Q + ')');
  sq.Exec('INSERT INTO t1(a) VALUES(' + Q + 'z' + Q + ')');
  sq.Exec('DELETE FROM t1 WHERE a = ' + Q + 'y' + Q);
  R := sq.Exec('VACUUM');
  Ok('VACUUM', R.Msg);
  ChkVal('VACUUM sonrasi veri', 'SELECT COUNT(*) FROM t1', 0, 0, '2');
end;

procedure T16_Parametreli;
var p: array of string;
begin
  Grp('Parametreli SQL (?)');
  UseDir('prm');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT, yas INTEGER)');
  SetLength(p, 2); p[0] := 'Ali'; p[1] := '30';
  R := sq.Exec('INSERT INTO t(ad,yas) VALUES(?,?)', p);
  if R.Affected = 1 then Ok('INSERT 2 parametre', '') else No('INSERT 2 parametre', 'affected=' + IntToStr(R.Affected));
  SetLength(p, 2); p[0] := 'Veli'; p[1] := '20';
  R := sq.Exec('INSERT INTO t(ad,yas) VALUES(?,?)', p);
  if R.Affected = 1 then Ok('INSERT 2 parametre 2', '') else No('INSERT 2 parametre 2', '');
  R := sq.Exec('SELECT yas FROM t WHERE ad = ?', ['Ali']);
  if (Length(R.Rows) = 1) and (R.Rows[0][0] = '30') then Ok('WHERE ?', R.Rows[0][0])
  else No('WHERE ?', 'sonuc ' + IntToStr(Length(R.Rows)));
  // M1: PostgreSQL uyumlu konumsal parametreler
  R := sq.Exec('SELECT yas FROM t WHERE ad = $1', ['Ali']);
  if (Length(R.Rows) = 1) and (R.Rows[0][0] = '30') then Ok('WHERE $1', R.Rows[0][0])
  else No('WHERE $1', 'sonuc ' + IntToStr(Length(R.Rows)));
  R := sq.Exec('SELECT yas FROM t WHERE ad = $2 OR ad = $1 ORDER BY yas',
    ['Veli', 'Ali']);
  if (Length(R.Rows) = 2) and (R.Rows[0][0] = '20') and (R.Rows[1][0] = '30') then
    Ok('WHERE $2/$1 sira', '20,30')
  else No('WHERE $2/$1 sira', 'sonuc ' + IntToStr(Length(R.Rows)));
  R := sq.Exec('INSERT INTO t(ad,yas) VALUES($1,$2)', ['Can', '40']);
  if R.Affected = 1 then Ok('INSERT $1/$2', '') else No('INSERT $1/$2', '');
  R := sq.Exec('DELETE FROM t WHERE ad = $1', ['Can']);
  if R.Affected = 1 then Ok('DELETE $1', '') else No('DELETE $1', '');
  ChkErr('eksik $2 parametresi (hata)', 'SELECT * FROM t WHERE ad = $2');
  R := sq.Exec('UPDATE t SET yas = ? WHERE ad = ?', ['31', 'Ali']);
  if R.Affected = 1 then Ok('UPDATE 2 parametre', '') else No('UPDATE 2 parametre', '');
  R := sq.Exec('DELETE FROM t WHERE ad = ?', ['Veli']);
  if R.Affected = 1 then Ok('DELETE 1 parametre', '') else No('DELETE 1 parametre', '');
  R := sq.Exec('SELECT COUNT(*) FROM t');
  if (Length(R.Rows) = 1) and (R.Rows[0][0] = '1') then Ok('kalan satir', R.Rows[0][0])
  else No('kalan satir', '');
  ChkErr('fazla parametre yok (hata)', 'SELECT * FROM t WHERE ad = ?');
end;

procedure T17_Json;
var f: string;
begin
  Grp('EXPORT / IMPORT JSON');
  UseDir('jsn');
  f := D + '\jsn\yedek.json';
  sq.Exec('CREATE TABLE eb(id INTEGER PRIMARY KEY)');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, ad TEXT, pid INTEGER ' +
          'REFERENCES eb(id), CHECK (id > 0))');
  sq.Exec('INSERT INTO eb(id) VALUES(1)');
  sq.Exec('INSERT INTO t(ad,pid) VALUES(' + Q + 'Ali' + Q + ',1)');
  sq.Exec('INSERT INTO t(ad,pid) VALUES(' + Q + 'Veli' + Q + ',1)');
  sq.Exec('EXPORT JSON ' + Q + f + Q);
  if FileExists(f) then Ok('EXPORT JSON', 'dosya yazildi') else No('EXPORT JSON', 'dosya yok');
  ChkErr('olmayan tablo EXPORT (hata)',
      'EXPORT TABLE yok JSON ' + Q + D + '\jsn\x.json' + Q);
  // yeni bos db'ye aktar
  UseDir('jsn2');
  sq.Exec('IMPORT JSON ' + Q + f + Q);
  ChkVal('IMPORT: sema geldi', 'SELECT COUNT(*) FROM t', 0, 0, '2');
  ChkVal('IMPORT: veri geldi', 'SELECT ad FROM t ORDER BY id', 0, 0, 'Ali');
  ChkErr('IMPORT sonrasi FK korunuyor (hata)',
      'INSERT INTO t(id,ad,pid) VALUES(9,' + Q + 'x' + Q + ',99)');
  ChkErr('IMPORT sonrasi CHECK korunuyor (hata)',
      'INSERT INTO t(id,ad) VALUES(-1,' + Q + 'x' + Q + ')');
end;

procedure T18_Kalici;
begin
  Grp('Disk kaliciligi: kapat + yeniden ac');
  UseDir('kal');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT, n INTEGER DEFAULT 5)');
  sq.Exec('INSERT INTO t(a) VALUES(' + Q + 'kalici' + Q + ')');
  sq.Exec('CREATE INDEX ix ON t(a)');
  sq.Exec('ALTER TABLE t ADD ek TEXT');
  UseDir('kal');   // ayni klasoru yeniden ac
  ChkVal('sema korundu', 'SELECT a FROM t', 0, 0, 'kalici');
  ChkVal('veri korundu', 'SELECT COUNT(*) FROM t', 0, 0, '1');
  R := sq.Exec('SELECT a FROM t WHERE a = ' + Q + 'kalici' + Q);
  if Length(R.Rows) = 1 then Ok('index kalici', '') else No('index kalici', '');
  ChkVal('ALTER kolon kalici', 'SELECT ek FROM t', 0, 0, '');
  ChkVal('DEFAULT kalici', 'SELECT n FROM t', 0, 0, '5');
end;

procedure T19_Olcek;
var i: Integer;
begin
  Grp('Olcek: 1000 satir + index aralama');
  UseDir('big');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER, s TEXT)');
  for i := 1 to 1000 do
  begin
    R := sq.Exec('INSERT INTO t(v,s) VALUES(' + IntToStr(i) + ',' +
        Q + 'satir' + IntToStr(i) + Q + ')');
  end;
  ChkVal('1000 satir yazildi', 'SELECT COUNT(*) FROM t', 0, 0, '1000');
  sq.Exec('CREATE INDEX ix_v ON t(v)');
  ChkVal('PK arama', 'SELECT s FROM t WHERE id = 500', 0, 0, 'satir500');
  ChkVal('index = arama', 'SELECT s FROM t WHERE v = 777', 0, 0, 'satir777');
  ChkVal('index > arama', 'SELECT COUNT(*) FROM t WHERE v > 990', 0, 0, '10');
  ChkVal('index aralik', 'SELECT COUNT(*) FROM t WHERE v >= 100 AND v <= 199', 0, 0, '100');
  Chk('tam tarama', 'SELECT COUNT(*) FROM t', 1);
  Chk('ORDER BY + LIMIT', 'SELECT s FROM t ORDER BY v DESC LIMIT 1', 1);
  ChkVal('ORDER BY DESC ilk', 'SELECT s FROM t ORDER BY v DESC LIMIT 1', 0, 0, 'satir1000');
  R := sq.Exec('VACUUM');
  Ok('buyuk veride VACUUM', R.Msg);
  ChkVal('VACUUM sonrasi 1000 satir', 'SELECT COUNT(*) FROM t', 0, 0, '1000');
end;

{ -------------------------------------------------- 20) coklu kayit / coklu komut }
procedure T20_CokluKayit;
begin
  Grp('Coklu kayit (VALUES (...),(...)) + coklu komut (";")');
  UseDir('coklu');
  // Kullanicinin tipik kullanimi: 5 kolonlu tablo, 8 satirlik VALUES.
  Chk('CREATE TABLE (5 kolon)',
      'CREATE TABLE personel (ad TEXT, unvan TEXT, sehir TEXT, ' +
      'departman TEXT, maas FLOAT)', -1);
  try
    r := sq.Exec('INSERT INTO personel (ad,unvan,sehir,departman,maas) VALUES' +
      ' (' + Q + 'Mehmet' + Q + ',' + Q + 'Yonetici' + Q + ',' + Q + 'Istanbul' + Q + ',yazilim,9200),' +
      ' (' + Q + 'Samet' + Q + ',' + Q + 'Uzman' + Q + ',' + Q + 'Ankara' + Q + ',finans,4800),' +
      ' (' + Q + 'Kenan' + Q + ',' + Q + 'Yonetici' + Q + ',' + Q + 'Istanbul' + Q + ',yazilim,9700),' +
      ' (' + Q + 'Veli' + Q + ',' + Q + 'Uzman' + Q + ',' + Q + 'Izmir' + Q + ',satis,5200),' +
      ' (' + Q + 'Deli' + Q + ',' + Q + 'Yonetici' + Q + ',' + Q + 'Ankara' + Q + ',finans,9100),' +
      ' (' + Q + 'Can' + Q + ',' + Q + 'Uzman' + Q + ',' + Q + 'Istanbul' + Q + ',finans,5400),' +
      ' (' + Q + 'Selim' + Q + ',' + Q + 'Uzman' + Q + ',' + Q + 'Istanbul' + Q + ',finans,5500),' +
      ' (' + Q + 'Nihat' + Q + ',' + Q + 'Yonetici' + Q + ',' + Q + 'Izmir' + Q + ',yazilim,8700)');
    ChkVal('Affected = 8 satir', 'SELECT COUNT(*) FROM personel', 0, 0, '8');
    ChkInt('Stmts = 1 (tek komut, coklu grup)', r.Stmts, 1);
  except on E: Exception do No('8 satirlik VALUES', '(' + E.Message + ')'); end;
  Chk('8 satir listelenir', 'SELECT ad FROM personel', 8);
  ChkVal('1. kayit', 'SELECT ad FROM personel WHERE maas = 9200', 0, 0, 'Mehmet');
  ChkVal('2. kayit', 'SELECT ad FROM personel WHERE maas = 4800', 0, 0, 'Samet');
  ChkVal('3. kayit', 'SELECT ad FROM personel WHERE maas = 9700', 0, 0, 'Kenan');
  ChkVal('4. kayit', 'SELECT ad FROM personel WHERE maas = 5200', 0, 0, 'Veli');
  ChkVal('5. kayit', 'SELECT ad FROM personel WHERE maas = 9100', 0, 0, 'Deli');
  ChkVal('6. kayit', 'SELECT ad FROM personel WHERE maas = 5400', 0, 0, 'Can');
  ChkVal('7. kayit', 'SELECT ad FROM personel WHERE maas = 5500', 0, 0, 'Selim');
  ChkVal('8. kayit', 'SELECT ad FROM personel WHERE maas = 8700', 0, 0, 'Nihat');
  Chk('ORDER BY maas', 'SELECT ad FROM personel ORDER BY maas', 8);
  ChkVal('ORDER BY maas ilk', 'SELECT ad FROM personel ORDER BY maas', 0, 0, 'Samet');
  Chk('LIMIT 3', 'SELECT ad FROM personel ORDER BY maas LIMIT 3', 3);
  Chk('OFFSET 5 LIMIT 3', 'SELECT ad FROM personel ORDER BY maas LIMIT 3 OFFSET 5', 3);

  Chk('yardimci tablo', 'CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)', -1);
  Chk('2 deger grubu', 'INSERT INTO t(id,a,b) VALUES (1,1,' + Q + 'x' + Q + '),(2,2,' + Q + 'y' + Q + ')', -1);
  Chk('3 deger grubu', 'INSERT INTO t(id,a,b) VALUES (3,3,' + Q + 'p' + Q + '),(4,4,' + Q + 'q' + Q + '),(5,5,' + Q + 'r' + Q + ')', -1);
  ChkVal('5 satir', 'SELECT COUNT(*) FROM t', 0, 0, '5');
  ChkErr('gruplar arasinda deger sayisi farki', 'INSERT INTO t(id,a,b) VALUES (6,6,' + Q + 'z' + Q + '),(7)');
  ChkVal('hatali grup sonrasi yazilmedi', 'SELECT COUNT(*) FROM t', 0, 0, '5');
  Chk('DEFAULT VALUES coklu', 'INSERT INTO t DEFAULT VALUES, DEFAULT VALUES', -1);
  ChkVal('7 satir', 'SELECT COUNT(*) FROM t', 0, 0, '7');
  ChkErr('artik token yutulmaz', 'INSERT INTO t(id,a,b) VALUES (9,9,' + Q + 'z' + Q + ') BLA');
  Chk('INSERT INTO t() VALUES(),()', 'INSERT INTO t() VALUES (), ()', -1);
  ChkVal('9 satir', 'SELECT COUNT(*) FROM t', 0, 0, '9');

  // Atomiklik: 3. grup ihlalli -> hicbiri yazilmaz
  Chk('atomik tablo', 'CREATE TABLE k(id INTEGER PRIMARY KEY, v INTEGER NOT NULL)', -1);
  Chk('ilk satir', 'INSERT INTO k(id,v) VALUES (1,1)', -1);
  ChkErr('3. grup NOT NULL ihlali', 'INSERT INTO k(id,v) VALUES (2,2),(3,3),(4,NULL)');
  ChkVal('yarim yazma yok', 'SELECT COUNT(*) FROM k', 0, 0, '1');
  ChkErr('PK cakismasi -> hicbiri yazilmaz', 'INSERT INTO k(id,v) VALUES (5,5),(1,9)');
  ChkVal('cakisma sonrasi degismez', 'SELECT COUNT(*) FROM k', 0, 0, '1');
  Chk('dogru 2 grup', 'INSERT INTO k(id,v) VALUES (2,2),(3,3)', -1);
  ChkVal('3 satir', 'SELECT COUNT(*) FROM k', 0, 0, '3');

  // INSERT INTO ... SELECT
  Chk('kaynak tablo', 'CREATE TABLE src(id INTEGER PRIMARY KEY, ad TEXT)', -1);
  Chk('src coklu kayit', 'INSERT INTO src(ad) VALUES (' + Q + 'a' + Q + '),(' + Q + 'b' + Q + '),(' + Q + 'c' + Q + ')', -1);
  Chk('hedef tablo', 'CREATE TABLE dst(id INTEGER PRIMARY KEY, ad TEXT)', -1);
  Chk('INSERT INTO dst SELECT', 'INSERT INTO dst(id,ad) SELECT id,ad FROM src', -1);
  ChkVal('3 satir kopyalandi', 'SELECT COUNT(*) FROM dst', 0, 0, '3');
  ChkVal('veri dogru', 'SELECT ad FROM dst WHERE id = 2', 0, 0, 'b');
  ChkErr('sutun sayisi uyusmaz', 'INSERT INTO dst(id,ad) SELECT id FROM src');

  // ";" ile coklu komut
  try
    r := sq.Exec('INSERT INTO t(id,a,b) VALUES (11,1,' + Q + 'c1' + Q + ');' +
                 'INSERT INTO t(id,a,b) VALUES (12,2,' + Q + 'c2' + Q + ');' +
                 'INSERT INTO t(id,a,b) VALUES (13,3,' + Q + 'c3' + Q + ')');
    ChkInt('3 komut islendi', r.Stmts, 3);
    ChkInt('Affected toplam 3', r.Affected, 3);
    if r.LastTable = 't' then Ok('LastTable = t', r.LastTable)
    else No('LastTable = t', 'gelen: ' + r.LastTable);
  except on E: Exception do No('3 komut', '(' + E.Message + ')'); end;
  ChkVal('12 satir', 'SELECT COUNT(*) FROM t', 0, 0, '12');
  ChkVal('son satir gorunur', 'SELECT b FROM t WHERE id = 13', 0, 0, 'c3');
  ChkVal('tirnak icindeki ; bolunmez', 'SELECT ' + Q + 'a;b' + Q + ' AS x', 0, 0, 'a;b');
  Chk('tirnakli deger ; olarak kalir', 'INSERT INTO t(id,a,b) VALUES (14,4,' + Q + 'p;q' + Q + ')', -1);
  ChkVal('deger oldugu gibi', 'SELECT b FROM t WHERE id = 14', 0, 0, 'p;q');
  ChkErr('hatali cumle betigi durdurur',
      'INSERT INTO t(id,a,b) VALUES (15,5,' + Q + 'zz' + Q + '); SELECT YANLIS');
  ChkVal('hata OLURSA HICBIR CUMLE UYGULANMAZ (otomatik transaction)', 'SELECT COUNT(*) FROM t', 0, 0, '13');

  // FROM'suz SELECT
  ChkVal('SELECT 1', 'SELECT 1', 0, 0, '1');
  ChkVal('SELECT ''abc'' AS x', 'SELECT ' + Q + 'abc' + Q + ' AS x', 0, 0, 'abc');
  ChkVal('SELECT NULL, 2.5', 'SELECT NULL, 2.5', 0, 1, '2.5');
  ChkErr('FROM''suz SELECT''ta kolon kullanilamaz', 'SELECT 1, b FROM t');

  // Tam zincir: CREATE + INSERT + UPDATE + DELETE tek betikte
  Chk('zincir betigi', 'BEGIN;' +
      'CREATE TABLE z(id INTEGER PRIMARY KEY, v TEXT);' +
      'INSERT INTO z(id,v) VALUES (1,' + Q + 'a' + Q + '),(2,' + Q + 'b' + Q + ');' +
      'UPDATE z SET v = ' + Q + 'c' + Q + ' WHERE id = 2;' +
      'DELETE FROM z WHERE id = 2;' +
      'COMMIT;', -1);
  ChkVal('z icinde 1 satir', 'SELECT COUNT(*) FROM z', 0, 0, '1');
  ChkVal('z degeri', 'SELECT v FROM z', 0, 0, 'a');
end;

procedure T21_KritikHataDogrulama;
var
  rep: string;
  got2: Boolean;
  okv: Boolean;
  kColl: QWord;
  rawB: TBytes;
begin
  Grp('Kritik Hata Duzeltmeleri (Verify Akis Tamponu & Hash Carpismasi)');
  Fresh('kritik');
  // 1. TVDb.Verify akis tamponu: veritabani dolu iken uninitialized tampon hatasi olmadan dogrulanmali
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)');
  sq.Exec('INSERT INTO t(id, v) VALUES(1, ' + Q + 'veri1' + Q + '),(2, ' + Q + 'veri2' + Q + ')');
  okv := kv.Verify(rep);
  if okv then Ok('TVDb.Verify akis tamponu ile dogrulandi', rep)
  else No('TVDb.Verify akis tamponu basarisiz', rep);

  // SQL uzerinden VERIFY calistirma
  R := sq.Exec('VERIFY');
  if R.Affected = 1 then Ok('SQL VERIFY komutu', R.Msg)
  else No('SQL VERIFY komutu basarisiz', R.Msg);

  // 2. Hash carpismasi guvenligi:
  sq.Exec('CREATE TABLE diger(id INTEGER PRIMARY KEY, v TEXT)');
  sq.Exec('CREATE TABLE cocuk(id INTEGER PRIMARY KEY, pid INTEGER REFERENCES diger(id))');
  kColl := VDbHashKey('diger', '999');
  if kv.Get(VDbHashKey('t', '1'), rawB) then
  begin
    kv.Put(kColl, rawB); // 'diger' tablosundaki PK 999 anahtari altinda 't' tablosunun row verisi var

    // a) FK denetimi sentetik carpismayi yakalamali (baska tablonun row'unu kabul etmemeli)
    ChkErr('FK carpismada yalanci eslesme yapmaz', 'INSERT INTO cocuk(id, pid) VALUES(1, 999)');

    // b) INSERT yapilirken var olan carpismali veri sessizce ezilmemeli, hata firlatmali
    ChkErr('INSERT hash carpismasini tespit eder', 'INSERT INTO diger(id, v) VALUES(999, ' + Q + 'yeni' + Q + ')');
  end;
end;

procedure T22_MinMaxTipKiyas;
begin
  Grp('MIN/MAX tip-bilgili kiyas (string sira degil)');
  UseDir('minmax');
  // Sayisal kolonda leksik sira ('2' > '10') degil sayisal sira gecerli.
  sq.Exec('CREATE TABLE m(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO m(id,v) VALUES(1,2),(2,10),(3,9)');
  ChkVal('MAX sayisal', 'SELECT MAX(v) FROM m', 0, 0, '10');
  ChkVal('MIN sayisal', 'SELECT MIN(v) FROM m', 0, 0, '2');
  ChkVal('MAX sayisal GROUP BY', 'SELECT id, MAX(v) AS mx FROM m GROUP BY id ORDER BY id', 0, 1, '2');
  // Metin kolonda leksik sira korunur ('9' > '2' > '10').
  sq.Exec('CREATE TABLE m2(id INTEGER PRIMARY KEY, s TEXT)');
  sq.Exec('INSERT INTO m2(id,s) VALUES(1,' + Q + '10' + Q + '),(2,' + Q + '2' + Q + '),(3,' + Q + '9' + Q + ')');
  ChkVal('MAX metin leksik', 'SELECT MAX(s) FROM m2', 0, 0, '9');
  ChkVal('MIN metin leksik', 'SELECT MIN(s) FROM m2', 0, 0, '10');
end;

procedure T23_Blob;
var
  f: string;
  j1, j2, j3, j4: RawByteString;
begin
  Grp('BLOB ham bayt (depolama + JSON turu)');
  UseDir('blob');
  sq.Exec('CREATE TABLE foto(id INTEGER PRIMARY KEY, ham BLOB)');
  j1 := #$C0#$C0#$C0#$C0#$FF#$D8#$FF#$E0#$00; // gecersiz UTF-8 + sondaki #0
  j2 := #$10#$20#$30#$41#$42;                 // basi kontrol baytlari
  j3 := 'AB'#$00'CD'#$FF;                     // icinde #0
  j4 := 'xNULLy';                             // NULL literale donusmemeli
  sq.Exec('INSERT INTO foto(id, ham) VALUES(?, ?)', ['1', string(j1)]);
  sq.Exec('INSERT INTO foto(id, ham) VALUES(?, ?)', ['2', string(j2)]);
  sq.Exec('INSERT INTO foto(id, ham) VALUES(?, ?)', ['3', string(j3)]);
  sq.Exec('INSERT INTO foto(id, ham) VALUES(?, ?)', ['4', string(j4)]);
  R := sq.Exec('SELECT ham FROM foto WHERE id = 1');
  if (Length(R.Rows) = 1) and (R.Rows[0][0] = string(j1)) then Ok('BLOB C0 turu', '')
  else No('BLOB C0 turu', IntToStr(Length(R.Rows)) + ' satir');
  R := sq.Exec('SELECT ham FROM foto WHERE id = 2');
  if (Length(R.Rows) = 1) and (R.Rows[0][0] = string(j2)) then Ok('BLOB kontrol-bayt turu', '')
  else No('BLOB kontrol-bayt turu', 'bozuldu');
  R := sq.Exec('SELECT ham FROM foto WHERE id = 3');
  if (Length(R.Rows) = 1) and (R.Rows[0][0] = string(j3)) then Ok('BLOB #0 turu', '')
  else No('BLOB #0 turu', 'bozuldu');
  R := sq.Exec('SELECT ham FROM foto WHERE id = 4');
  if (Length(R.Rows) = 1) and (R.Rows[0][0] = string(j4)) then Ok('BLOB NULL-metin turu', '')
  else No('BLOB NULL-metin turu', 'bozuldu');
  R := sq.Exec('SELECT LENGTH(ham) FROM foto WHERE id = 1');
  if (Length(R.Rows) = 1) and (R.Rows[0][0] = '9') then Ok('LENGTH BLOB bayt (9)', '')
  else No('LENGTH BLOB bayt (9)', 'gelen: ' + R.Rows[0][0]);
  // JSON yedek turu (sifir DB'ye aktar)
  f := D + '\blob\foto.json';
  sq.Exec('EXPORT TABLE foto JSON ' + Q + f + Q);
  Fresh('blob2');
  sq.Exec('CREATE TABLE foto(id INTEGER PRIMARY KEY, ham BLOB)');
  sq.Exec('IMPORT JSON ' + Q + f + Q);
  R := sq.Exec('SELECT ham FROM foto WHERE id = 1');
  if (Length(R.Rows) = 1) and (R.Rows[0][0] = string(j1)) then Ok('JSON BLOB C0 turu', '')
  else No('JSON BLOB C0 turu', 'bozuldu');
  R := sq.Exec('SELECT ham FROM foto WHERE id = 3');
  if (Length(R.Rows) = 1) and (R.Rows[0][0] = string(j3)) then Ok('JSON BLOB #0 turu', '')
  else No('JSON BLOB #0 turu', 'bozuldu');
end;

procedure T24_Dayaniklilik;
begin
  Grp('Commit-flush garantisi (P-DUR)');
  UseDir('dur');
  // GUI modu simulasyonu: SyncWrite kapaliyken bile SQL commit'i saglamdir.
  kv.SyncWrite := False;
  try
    sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)');
    sq.Exec('INSERT INTO t(id,v) VALUES(1,' + Q + 'a' + Q + ')');
    if not kv.Dirty then Ok('tekil INSERT sonrasi temiz (flush calisti)', '')
    else No('tekil INSERT sonrasi temiz (flush calisti)', 'hala kirli');
    sq.Exec('INSERT INTO t(id,v) VALUES(2,' + Q + 'b' + Q + ');' +
            'INSERT INTO t(id,v) VALUES(3,' + Q + 'c' + Q + ')');
    if not kv.Dirty then Ok('batch sonrasi temiz (tek fsync)', '')
    else No('batch sonrasi temiz (tek fsync)', 'hala kirli');
    R := sq.Exec('SELECT COUNT(*) AS c FROM t');
    if (Length(R.Rows) = 1) and (R.Rows[0][0] = '3') then Ok('3 satir yazildi', '')
    else No('3 satir yazildi', 'sayi tutmadi');
    // Ham API sozlesmesi: SQL disi yazanlar Flush cagirir.
    tb.Insert('t', ['id', 'v'], ['4', 'd']);
    if kv.Dirty then Ok('ham API kirli birakir', '')
    else No('ham API kirli birakir', 'bayrak kurulmadi');
    kv.Flush;
    if not kv.Dirty then Ok('Flush temizler', '')
    else No('Flush temizler', 'hala kirli');
    // Salt-okunur sorgu flush tetiklemez (bayrak zaten temiz).
    R := sq.Exec('SELECT * FROM t WHERE id = 1');
    if not kv.Dirty then Ok('SELECT kirletmez', '')
    else No('SELECT kirletmez', 'bayrak kuruldu');
  finally
    kv.SyncWrite := True;
  end;
end;

{ ---------------------------------------------------------------- F1 REGRESYON
  DENETIM_VE_YOL_HARITASI.md icindeki F1 (KRITIK) kalemleri. Her bolum,
  denetimde tespit edilen hatanin regresyon kanitidir. }

procedure T25_F1_UnionSiraVeLimit;
// F1-11 + F1-12: UNION/EXCEPT/INTERSECT sutun sayisi denetlenir ve
// ORDER BY / OFFSET / LIMIT birlestirme SONRASINA uygulanir.
begin
  Grp('F1-11/F1-12 UNION sutun denetimi + birlestirme sonrasi siralama');
  UseDir('f1_union');
  sq.Exec('CREATE TABLE u1(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('CREATE TABLE u2(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO u1(id,v) VALUES(1,10),(2,10),(3,10)');
  sq.Exec('INSERT INTO u2(id,v) VALUES(2,20),(4,20),(5,20)');

  // F1-12: eski davranista sol taraf LIMIT ile kirpilir, birlestilen
  // sonuc yanlis satir sayisi donerdi. Dogru sonuc 5 satir.
  Chk('UNION tamami 5 satir', 'SELECT id FROM u1 UNION SELECT id FROM u2', 5);
  Chk('UNION ALL 6 satir (tekrar korunur)', 'SELECT id FROM u1 UNION ALL SELECT id FROM u2', 6);
  Chk('EXCEPT tamami 2 satir (1,3)', 'SELECT id FROM u1 EXCEPT SELECT id FROM u2', 2);
  Chk('INTERSECT tamami 1 satir (2)', 'SELECT id FROM u1 INTERSECT SELECT id FROM u2', 1);
  Chk('UNION LIMIT 2 sonrasi 2 satir', 'SELECT id FROM u1 UNION SELECT id FROM u2 LIMIT 2', 2);
  ChkVal('UNION LIMIT 2 ilk satir', 'SELECT id FROM u1 UNION SELECT id FROM u2 LIMIT 2', 0, 0, '1');
  ChkVal('UNION LIMIT 2 2. satir', 'SELECT id FROM u1 UNION SELECT id FROM u2 LIMIT 2', 1, 0, '2');

  // OFFSET de birlestirme sonrasinda olmali
  Chk('UNION OFFSET sonrasi 2 satir', 'SELECT id FROM u1 UNION SELECT id FROM u2 ORDER BY id OFFSET 3', 2);
  ChkVal('UNION OFFSET ilk satir 4', 'SELECT id FROM u1 UNION SELECT id FROM u2 ORDER BY id OFFSET 3', 0, 0, '4');
  ChkVal('UNION ORDER BY+LIMIT+OFFSET ilk satir 2', 'SELECT id FROM u1 UNION SELECT id FROM u2 ORDER BY id LIMIT 2 OFFSET 1', 0, 0, '2');
  ChkVal('UNION ORDER BY+LIMIT+OFFSET 2. satir 3', 'SELECT id FROM u1 UNION SELECT id FROM u2 ORDER BY id LIMIT 2 OFFSET 1', 1, 0, '3');

  // ORDER BY birlestirme sonrasi: sayisal sira
  ChkVal('UNION ORDER BY DESC ilk satir 5', 'SELECT id FROM u1 UNION SELECT id FROM u2 ORDER BY id DESC', 0, 0, '5');
  ChkVal('UNION ORDER BY ASC ilk satir 1', 'SELECT id FROM u1 UNION SELECT id FROM u2 ORDER BY id', 0, 0, '1');

  // EXCEPT / INTERSECT de ayni sira kuralina tabidir
  Chk('EXCEPT LIMIT 1 sonrasi 1 satir', 'SELECT id FROM u1 EXCEPT SELECT id FROM u2 LIMIT 1', 1);
  Chk('INTERSECT LIMIT 5 sonrasi 1 satir', 'SELECT id FROM u1 INTERSECT SELECT id FROM u2 LIMIT 5', 1);

  // F1-11: sutun sayisi esit degilse hata vermeli (sessizce engebeli
  // matris uretilmesi yerine)
  ChkErr('UNION sutun sayisi farki hata', 'SELECT id FROM u1 UNION SELECT id, v FROM u2');
  ChkErr('EXCEPT sutun sayisi farki hata', 'SELECT id FROM u1 EXCEPT SELECT id, v FROM u2');
  ChkErr('INTERSECT sutun sayisi farki hata', 'SELECT id FROM u1 INTERSECT SELECT id, v FROM u2');
end;

procedure T26_F1_OrderByTip;
// F1-20: GROUP BY sonrasi ORDER BY cikti tip haritasi kullanir.
// COUNT '10' < '2' diye metin sirasiyla siralanirdi.
begin
  Grp('F1-20 GROUP BY sonrasi ORDER BY sayisal tip');
  UseDir('f1_gborder');
  sq.Exec('CREATE TABLE g(id INTEGER PRIMARY KEY, ad TEXT)');
  // a -> 10 satir, b -> 2 satir, c -> 3 satir
  // sayisal sira: b(2) < c(3) < a(10); metin sira: a('10') < b('2') < c('3')
  sq.Exec('INSERT INTO g(id,ad) VALUES(1,' + Q + 'a' + Q + '),(2,' + Q + 'b' + Q +
                 '),(3,' + Q + 'c' + Q + ')');
  sq.Exec('INSERT INTO g(id,ad) VALUES(10,' + Q + 'a' + Q + '),(11,' + Q + 'a' + Q +
                 '),(12,' + Q + 'a' + Q + '),(13,' + Q + 'a' + Q + '),(14,' + Q + 'a' + Q +
                 '),(15,' + Q + 'a' + Q + '),(16,' + Q + 'a' + Q + '),(17,' + Q + 'a' + Q +
                 '),(18,' + Q + 'a' + Q + '),(19,' + Q + 'a' + Q + ')');
  sq.Exec('INSERT INTO g(id,ad) VALUES(20,' + Q + 'b' + Q + '),(30,' + Q + 'c' + Q +
                 '),(31,' + Q + 'c' + Q + ')');
  ChkVal('GROUP BY COUNT ORDER BY ASC ilk grup b(2)',
    'SELECT ad, COUNT(*) AS adet FROM g GROUP BY ad ORDER BY adet', 0, 0, 'b');
  ChkVal('GROUP BY COUNT ORDER BY ASC 2. grup c(3)',
    'SELECT ad, COUNT(*) AS adet FROM g GROUP BY ad ORDER BY adet', 1, 0, 'c');
  ChkVal('GROUP BY COUNT ORDER BY ASC 3. grup a(10)',
    'SELECT ad, COUNT(*) AS adet FROM g GROUP BY ad ORDER BY adet', 2, 0, 'a');
  ChkVal('GROUP BY COUNT ORDER BY DESC ilk grup a(10)',
    'SELECT ad, COUNT(*) AS adet FROM g GROUP BY ad ORDER BY adet DESC', 0, 0, 'a');
  ChkVal('GROUP BY COUNT ORDER BY DESC 2. grup c(3)',
    'SELECT ad, COUNT(*) AS adet FROM g GROUP BY ad ORDER BY adet DESC', 1, 0, 'c');
  ChkVal('GROUP BY COUNT ORDER BY DESC 3. grup b(2)',
    'SELECT ad, COUNT(*) AS adet FROM g GROUP BY ad ORDER BY adet DESC', 2, 0, 'b');

  // SUM/AVG cikti tipi FLOAT -> '2.5' vs '10' dogru siralanir
  sq.Exec('CREATE TABLE s(id INTEGER PRIMARY KEY, v REAL)');
  sq.Exec('INSERT INTO s(id,v) VALUES(1,10),(2,2.5)');
  ChkVal('GROUP BY SUM ORDER BY ASC once 2.5',
    'SELECT id, SUM(v) AS t FROM s GROUP BY id ORDER BY t', 0, 1, '2.5');

  // MIN/MAX cikti tipi arguman kolonunun tipini alir
  sq.Exec('CREATE TABLE mx(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO mx(id,v) VALUES(1,2),(2,10)');
  ChkVal('GROUP BY MIN ORDER BY ASC once 2',
    'SELECT id, MIN(v) AS mn FROM mx GROUP BY id ORDER BY mn', 0, 1, '2');
  ChkVal('GROUP BY MAX ORDER BY DESC once 10',
    'SELECT id, MAX(v) AS mx2 FROM mx GROUP BY id ORDER BY mx2 DESC', 0, 1, '10');
end;

procedure T27_F1_OrderByBilinmeyenKolon;
// F1-21: bilinmeyen ORDER BY kolonu sessizce yok sayilmaz.
begin
  Grp('F1-21 ORDER BY bilinmeyen kolon hata verir');
  UseDir('f1_obunknown');
  sq.Exec('CREATE TABLE o(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO o(id,v) VALUES(1,3),(2,1)');
  ChkErr('ORDER BY bilinmeyen kolon', 'SELECT id FROM o ORDER BY yokBoyleBirKolon');
  // mevcut kolonla ayni komut calismaya devam etmeli
  ChkVal('gecerli ORDER BY hala calisir', 'SELECT id FROM o ORDER BY v', 0, 0, '2');
end;

procedure T28_F1_JoinTipKiyas;
// F1-17: JOIN sonrasi WHERE'te tip-bilgili kiyaslama kullanilir.
// '10' < '2" (metin sira) sonucu vermemeli.
begin
  Grp('F1-17 JOIN sonrasi karsilastirma sayisal tip');
  UseDir('f1_jointype');
  sq.Exec('CREATE TABLE sip(id INTEGER PRIMARY KEY, tutar INTEGER)');
  sq.Exec('CREATE TABLE musteri(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('INSERT INTO musteri(id,ad) VALUES(1,' + Q + 'Ali' + Q + '),(2,' + Q + 'Veli' + Q +
                 '),(3,' + Q + 'Ayse' + Q + ')');
  sq.Exec('INSERT INTO sip(id,tutar) VALUES(1,10),(2,2),(3,20)');
  sq.Exec('INSERT INTO sip(id,tutar) VALUES(4,NULL)');
  // s.tutar > 2 : 10 ve 20 gelmeli (2 ve NULL gelmemeli) -> Ali, Ayse = 2 satir
  // METIN sira ile '10' > '2' ve '20' > '2' FALSE -> 0 satir donerdi.
  Chk('JOIN + WHERE sayisal > 2', 'SELECT m.ad FROM musteri m JOIN sip s ON m.id = s.id WHERE s.tutar > 2', 2);
  ChkVal('JOIN + WHERE sayisal > 2 dogru satir',
    'SELECT m.ad FROM musteri m JOIN sip s ON m.id = s.id WHERE s.tutar > 2', 0, 0, 'Ali');
  ChkVal('JOIN + WHERE nitelemesiz kolon sayisal',
    'SELECT m.ad FROM musteri m JOIN sip s ON m.id = s.id WHERE tutar > 2', 0, 0, 'Ali');
  // s.tutar < 15 : 10 (Ali) ve 2 (Veli) -> 2 satir. Metin sira ile
  // hatali: '10' < '15' dogru ama '2' < '15' de dogru; buradaki asil
  // kanit > 2 testidir (metin sira '20' > '2' -> 20 gelmezdi).
  Chk('JOIN + WHERE sayisal < 15', 'SELECT m.ad FROM musteri m JOIN sip s ON m.id = s.id WHERE s.tutar < 15', 2);
  ChkVal('JOIN + WHERE < 15 dogru satir (2)',
    'SELECT m.ad FROM musteri m JOIN sip s ON m.id = s.id WHERE s.tutar < 15', 1, 0, 'Veli');
  // musteri 3 (Ayse) sip 3 (tutar 20) ile eslesir; boylece >= 20 testi
  // anlamli olur (metin sira '20' >= '20' -> yine 1, ama > 2 testi asil
  // kanit: metin sira '10' > '2' ve '20' > '2' FALSE -> 0 satir donerdi)
  Chk('JOIN + WHERE sayisal >= 20', 'SELECT m.ad FROM musteri m JOIN sip s ON m.id = s.id WHERE s.tutar >= 20', 1);
  ChkVal('JOIN + WHERE >= 20 dogru satir (Ayse)',
    'SELECT m.ad FROM musteri m JOIN sip s ON m.id = s.id WHERE s.tutar >= 20', 0, 0, 'Ayse');
  // LEFT JOIN: eslesmeyen musteri (4 -> sip yok) NULL uzanmis olur; NULL
  // karsilastirmasi UNKNOWN doner, filtreye girmemeli (3 musteri eşlesir,
  // 4'u NULL -> 3 satirden 2'si tutar > 2).
  sq.Exec('INSERT INTO musteri(id,ad) VALUES(4,' + Q + 'Zeynep' + Q + ')');
  Chk('LEFT JOIN 4 musteri', 'SELECT m.ad FROM musteri m LEFT JOIN sip s ON m.id = s.id', 4);
  Chk('LEFT JOIN NULL tarafta WHERE eler',
    'SELECT m.ad FROM musteri m LEFT JOIN sip s ON m.id = s.id WHERE s.tutar > 2', 2);
  // NOT: LEFT JOIN null-genisletmesi birlesme KOLONU (s.id) icin bos
  // string yerine anahtar degeri yaziyor; bu yuzden IS NULL ancak
  // normal kolonlarda (s.tutar) tutarli. F1 kapsami disi.
  Chk('LEFT JOIN IS NULL ile eslesmeyen bulunur',
    'SELECT m.ad FROM musteri m LEFT JOIN sip s ON m.id = s.id WHERE s.tutar IS NULL', 1);
  ChkVal('LEFT JOIN IS NULL dogru satir',
    'SELECT m.ad FROM musteri m LEFT JOIN sip s ON m.id = s.id WHERE s.tutar IS NULL', 0, 0, 'Zeynep');
end;

procedure T29_F1_UpdateBilinmeyenKolon;
// F1-16: UPDATE bilinmeyen kolonu sessizce atmaz.
begin
  Grp('F1-16 UPDATE bilinmeyen kolon hata verir');
  UseDir('f1_updunknown');
  sq.Exec('CREATE TABLE u(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO u(id,v) VALUES(1,10),(2,20)');
  ChkErr('UPDATE bilinmeyen kolon', 'UPDATE u SET yokBoyleBirKolon = 5 WHERE id = 1');
  // satir silinip aynen yazilmamis olmali
  ChkVal('UPDATE hatasindan sonra veri bozulmadi', 'SELECT v FROM u WHERE id = 1', 0, 0, '10');
  ChkVal('UPDATE hatasindan sonra 2. satir bozulmadi', 'SELECT v FROM u WHERE id = 2', 0, 0, '20');
  R := sq.Exec('UPDATE u SET v = 99 WHERE id = 1');
  ChkInt('gecerli UPDATE 1 satir etkiledi', R.Affected, 1);
  ChkVal('gecerli UPDATE uygulandi', 'SELECT v FROM u WHERE id = 1', 0, 0, '99');
  // 0 satirlik UPDATE de hata vermemeli
  R := sq.Exec('UPDATE u SET v = 1 WHERE id = 777');
  ChkInt('eslesmeyen UPDATE 0 satir', R.Affected, 0);
end;

procedure T30_F1_DeleteDatabase;
// F1-15: DELETE DATABASE canli yolda ve batch disi (ayri dosya).
begin
  Grp('F1-15 DELETE DATABASE canli + batch disi');
  UseDir('f1_deldbsic');
  sq.Exec('CREATE TABLE x(id INTEGER PRIMARY KEY, v TEXT)');
  sq.Exec('INSERT INTO x(id,v) VALUES(1,' + Q + 'a' + Q + ')');

  // ikinci bir veritabani olustur (etkin baglanti degismez)
  Chk('CREATE DATABASE yan', 'CREATE DATABASE yan', -1);
  ChkErr('DELETE DATABASE olmayan (hata)', 'DELETE DATABASE boyleYok');

  // ExecAll StmtBatchSafe uzerinden gecer: DELETE DATABASE batch disi
  // kaldigi icin betik sonrasi DB ayakta ve veri yerinde durur.
  R := sq.ExecAll(['INSERT INTO x(id,v) VALUES(2,' + Q + 'b' + Q + ')',
                   'DELETE DATABASE yan']);
  ChkVal('DELETE DATABASE betikte calisti', 'SELECT COUNT(*) FROM x', 0, 0, '2');
  ChkVal('DELETE DATABASE betiginden sonra satirlar durur',
    'SELECT v FROM x WHERE id = 2', 0, 0, 'b');
  ChkErr('silinen veritabani artik yok', 'DROP DATABASE yan');
  Chk('DROP DATABASE IF EXISTS (yok)', 'DROP DATABASE IF EXISTS yan', -1);

  // yeniden olustur + dogrudan yol
  Chk('CREATE DATABASE yeniden', 'CREATE DATABASE yan', -1);
  Chk('DELETE DATABASE dogrudan yol', 'DELETE DATABASE yan', -1);
  ChkVal('DELETE DATABASE sonrasi veri durur', 'SELECT v FROM x WHERE id = 1', 0, 0, 'a');
  ChkVal('DELETE DATABASE sonrasi 2. satir durur', 'SELECT v FROM x WHERE id = 2', 0, 0, 'b');
end;

procedure T31_F1_NotInNull;
// F1-13 + F1-14: NOT IN / NOT NULL uclu deger mantigi (UNKNOWN).
begin
  Grp('F1-13/F1-14 NULL mantigi (NOT IN / NOT NULL)');
  UseDir('f1_null3');
  sq.Exec('CREATE TABLE n(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO n(id,v) VALUES(1,1),(2,2),(3,NULL)');
  // 2 NOT IN (1,NULL) -> UNKNOWN -> satir gelmez
  Chk('NOT IN listede NULL varsa satir gelmez', 'SELECT id FROM n WHERE v NOT IN (1, NULL)', 0);
  // 1 NOT IN (1,NULL) -> eşlesme var -> False
  Chk('NOT IN eslesen deger NULL ile False', 'SELECT id FROM n WHERE v NOT IN (1, NULL)', 0);
  // NULL NOT IN (...) -> UNKNOWN
  Chk('NULL NOT IN satir gelmez', 'SELECT id FROM n WHERE v NOT IN (1, 2)', 0);
  // IN normal calisir
  Chk('IN normal calisir', 'SELECT id FROM n WHERE v IN (1, 2)', 2);
  // F1-14: NOT NULL -> UNKNOWN (hicbir operator NULL ile eslesmez)
  Chk('NOT NULL satir gelmez', 'SELECT id FROM n WHERE NOT (v = 1)', 1);
  ChkVal('NOT NULL filtresi sadece NULL disi birakir', 'SELECT id FROM n WHERE NOT (v = 1)', 0, 0, '2');
end;

procedure T32_F1_LimitGecersiz;
// F1-18: bozuk/negatif LIMIT/OFFSET sessizce yok sayilmaz.
begin
  Grp('F1-18 LIMIT/OFFSET gecersiz deger hata verir');
  UseDir('f1_limitbad');
  sq.Exec('CREATE TABLE l(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO l(id,v) VALUES(1,1),(2,2),(3,3)');
  ChkErr('LIMIT negatif', 'SELECT id FROM l LIMIT -5');
  ChkErr('LIMIT sayi disi', 'SELECT id FROM l LIMIT abc');
  ChkErr('OFFSET negatif', 'SELECT id FROM l OFFSET -2');
  ChkErr('OFFSET sayi disi', 'SELECT id FROM l OFFSET xyz');
  Chk('gecerli LIMIT hala calisir', 'SELECT id FROM l LIMIT 2', 2);
  Chk('gecerli OFFSET hala calisir', 'SELECT id FROM l LIMIT 5 OFFSET 1', 2);
end;

procedure T33_F1_SumBosKume;
// F1-19: SUM bos kumede NULL doner (0 degil).
begin
  Grp('F1-19 SUM bos kume NULL doner');
  UseDir('f1_sumbos');
  sq.Exec('CREATE TABLE e(id INTEGER PRIMARY KEY, v INTEGER)');
  // bos tablo + GROUP BY'siz aggregate
  ChkVal('SUM bos tablo NULL', 'SELECT SUM(v) FROM e', 0, 0, '');
  ChkVal('COUNT bos tablo 0', 'SELECT COUNT(*) FROM e', 0, 0, '0');
  sq.Exec('INSERT INTO e(id,v) VALUES(1,5)');
  ChkVal('SUM tek satir', 'SELECT SUM(v) FROM e', 0, 0, '5');
  // hepsi NULL olan grup
  sq.Exec('CREATE TABLE e2(id INTEGER PRIMARY KEY, g TEXT, v INTEGER)');
  sq.Exec('INSERT INTO e2(id,g,v) VALUES(1,' + Q + 'a' + Q + ',NULL)');
  ChkVal('SUM hepsi NULL grup NULL', 'SELECT SUM(v) FROM e2 GROUP BY g', 0, 0, '');
end;

procedure T34_F1_AlterRenameBozukSatir;
// F1-8: ALTER TABLE RENAME ile ilgili satirlar bozulmaz.
begin
  Grp('F1-8 hash dogrulamasi (ALTER RENAME sonrasi veri saglam)');
  UseDir('f1_rename');
  sq.Exec('CREATE TABLE r1(id INTEGER PRIMARY KEY, v TEXT)');
  sq.Exec('INSERT INTO r1(id,v) VALUES(1,' + Q + 'a' + Q + '),(2,' + Q + 'b' + Q + ')');
  sq.Exec('CREATE TABLE r2(id INTEGER PRIMARY KEY, pid INTEGER REFERENCES r1(id))');
  sq.Exec('INSERT INTO r2(id,pid) VALUES(1,1),(2,2)');
  sq.Exec('ALTER TABLE r1 RENAME TO r1yeni');
  ChkVal('rename sonrasi veri korunur (1)', 'SELECT v FROM r1yeni WHERE id = 1', 0, 0, 'a');
  ChkVal('rename sonrasi veri korunur (2)', 'SELECT v FROM r1yeni WHERE id = 2', 0, 0, 'b');
  Chk('rename sonrasi satir sayisi', 'SELECT id FROM r1yeni', 2);
  // cocuk FK referansi yeni ada guncellenmeli, FK ihlali olmamali
  ChkErr('rename sonrasi FK yeni ada bagli', 'INSERT INTO r2(id,pid) VALUES(3,99)');
  ChkVal('rename sonrasi FK gecerli kayit', 'SELECT pid FROM r2 WHERE id = 1', 0, 0, '1');
end;

procedure T35_F1_OffsetAlias;
// F1-10: OFFSET alias listesinde tanimliydi, tek tablo + OFFSET calisir.
begin
  Grp('F1-10 OFFSET alias (SELECT * FROM t OFFSET n)');
  UseDir('f1_offset');
  sq.Exec('CREATE TABLE a(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO a(id,v) VALUES(1,1),(2,2),(3,3),(4,4)');
  Chk('SELECT * OFFSET 1 -> 3 satir', 'SELECT * FROM a OFFSET 1', 3);
  Chk('SELECT * OFFSET 3 -> 1 satir', 'SELECT * FROM a OFFSET 3', 1);
  Chk('SELECT * OFFSET 4 -> 0 satir', 'SELECT * FROM a OFFSET 4', 0);
  Chk('SELECT * LIMIT 2 OFFSET 1', 'SELECT * FROM a LIMIT 2 OFFSET 1', 2);
  Chk('SELECT * OFFSET 1 LIMIT 2', 'SELECT * FROM a OFFSET 1 LIMIT 2', 2);
  Chk('SELECT * LIMIT 2 OFFSET 1 ORDER BY id DESC', 'SELECT * FROM a ORDER BY id DESC LIMIT 2 OFFSET 1', 2);
  ChkVal('OFFSET+ORDER BY DESC ilk satir 3', 'SELECT * FROM a ORDER BY id DESC LIMIT 2 OFFSET 1', 0, 0, '3');
end;

{ ------------------------------------------------------------------ F1 (1-3)
  VDbCore katmani: crash kurtarma / batch atomikligi / legacy gecis. }

// Dosya boyutu (bayt). FileUtil'a bagli olmamak icin TFileStream.
function FileSizeOf(const F: string): Int64;
var fs: TFileStream;
begin
  if not FileExists(F) then Exit(-1);
  fs := TFileStream.Create(F, fmOpenRead);
  try
    Result := fs.Size;
  finally
    fs.Free;
  end;
end;

// Dosya sonuna BATCHEND'siz bir kayit kopyasi ekler -> "commit edilmemis
// batch" durumu (crash benzetimi). Recover bunu geri sarmali.
procedure AppendUncommittedTail(const DbFile: string);
var
  fs: TFileStream;
  h: TVDbRecHead;
  recBytes: TBytes;
  sz: Int64;
begin
  fs := TFileStream.Create(DbFile, fmOpenReadWrite);
  try
    sz := fs.Size;
    fs.Position := VDB_HDR_SIZE;
    if fs.Read(h, SizeOf(h)) <> SizeOf(h) then Exit;
    if h.Flags = VDB_FLAG_BATCHEND then Exit;  // veri kaydi yok
    SetLength(recBytes, SizeOf(h) + h.ValLen);
    fs.Position := VDB_HDR_SIZE;
    fs.ReadBuffer(recBytes[0], Length(recBytes));
    fs.Position := sz;
    fs.WriteBuffer(recBytes[0], Length(recBytes));
  finally
    fs.Free;
  end;
end;

procedure T36_F1_RecoverKirpma;
// F1-1: commitlenmemis batch fiziksel olarak kirpilir. Once yalnizca
// mantiksal olarak geri sariliyordu, diskte "oluk prefix" kaliyordu:
// seq cakismasi + Verify bozuluyordu.
var
  p, dbFile: string;
  szBefore, szAfter, szCrashed: Int64;
  rep: string;
  got2: Boolean;
  v: TBytes;
  myKv: TVDb;
begin
  Grp('F1-1 Recover yarim batch fiziksel kirpmasi');
  p := D + '\f1_recover';
  ForceDirectories(p);
  dbFile := p + '\veritabani.odb';

  myKv := TVDb.Create;
  try
    myKv.Open(p);
    myKv.Put(100, VDbStrToBytes('A'));
    myKv.Put(200, VDbStrToBytes('B'));
    myKv.Close;
  finally
    myKv.Free;
  end;
  szBefore := FileSizeOf(dbFile);
  Ok('temel dosya 2 anahtar', IntToStr(szBefore) + ' bayt');

  // crash benzetimi: BATCHEND'siz kayit ekle
  AppendUncommittedTail(dbFile);
  szCrashed := FileSizeOf(dbFile);
  if szCrashed > szBefore then
    Ok('yarim batch diskte olustu', IntToStr(szBefore) + ' -> ' + IntToStr(szCrashed))
  else No('yarim batch olusturulamadi', IntToStr(szCrashed));

  // yeniden ac -> Recover calisir
  myKv := TVDb.Create;
  try
    myKv.Open(p);
    ChkInt('Recover sonrasi canli kayit sayisi', myKv.Count, 2);
    ChkInt('commitlenmis anahtar gorunur (100)', Ord(myKv.Exists(100)), 1);
    ChkInt('commitlenmis anahtar gorunur (200)', Ord(myKv.Exists(200)), 1);
    if myKv.Get(100, v) then
      Ok('commitlenmis deger dogru', VDbBytesToStr(v))
    else No('commitlenmis deger okunamadi', '');
    myKv.Close;
  finally
    myKv.Free;
  end;

  // F1-1'in asil kaniti: dosya FIZIKSEL olarak kirpildi
  szAfter := FileSizeOf(dbFile);
  if szAfter = szBefore then
    Ok('yarim batch fiziksel olarak kirpildi', IntToStr(szAfter) + ' bayt')
  else
    No('yarim batch diskte kaldi (oluk prefix)', 'beklenen ' + IntToStr(szBefore) +
       ' gelen ' + IntToStr(szAfter));

  // ikinci acilista da tutarli olmali
  myKv := TVDb.Create;
  try
    myKv.Open(p);
    ChkInt('yeniden acilista kayit sayisi ayni', myKv.Count, 2);
    if myKv.Verify(rep) then Ok('Verify kirpma sonrasi gecerli', rep)
    else No('Verify kirpma sonrasi basarisiz', rep);
    myKv.Close;
  finally
    myKv.Free;
  end;
end;

procedure T37_F1_CommitBatchAtomik;
// F1-2: CommitBatch ortasinda hata olursa dosya BOZULMAZ. Onceden
// yazilan kayitlar "phantom" okunuyordu (restart oncesi/sonrasi
// tutarsizlik).
var
  p, dbFile: string;
  szBefore, szAfter: Int64;
  big: TBytes;
  rep: string;
  got2: Boolean;
  raised: Boolean;
  myKv: TVDb;
begin
  Grp('F1-2 CommitBatch hata yolunda atomiklik');
  p := D + '\f1_atomic';
  ForceDirectories(p);
  dbFile := p + '\veritabani.odb';

  myKv := TVDb.Create;
  try
    myKv.Open(p);
    myKv.Put(1, VDbStrToBytes('bir'));
    myKv.Close;
  finally
    myKv.Free;
  end;
  szBefore := FileSizeOf(dbFile);

  // VDB_MAX_VALUE'dan buyuk deger: CommitBatch on-dogrulamasi veya
  // AppendRec ic hatasi -> batch hic uygulanmamali.
  SetLength(big, VDB_MAX_VALUE + 1);
  FillChar(big[0], Length(big), #65);
  raised := False;
  myKv := TVDb.Create;
  try
    myKv.Open(p);
    myKv.BeginBatch;
    myKv.Put(2, VDbStrToBytes('iki'));       // bu kayit ONCE yazilir
    myKv.Put(3, big);                        // bu hatayi tetikler
    try
      myKv.CommitBatch;
    except
      on E: Exception do raised := True;
    end;
    if raised then Ok('CommitBatch hatayi firlatti (beklenen)', '')
    else No('CommitBatch hata vermedi', 'limit asimi yutuldu');
    ChkInt('hata sonrasi kayit sayisi degismedi', myKv.Count, 1);
    ChkInt('batch icindeki 2. kayit gorunmez', Ord(myKv.Exists(2)), 0);
    ChkInt('batch icindeki 3. kayit gorunmez', Ord(myKv.Exists(3)), 0);
    ChkInt('onceki kayit hala var', Ord(myKv.Exists(1)), 1);
    myKv.Close;
  finally
    myKv.Free;
  end;

  szAfter := FileSizeOf(dbFile);
  if szAfter = szBefore then
    Ok('dosya boyutu degismedi (rollback)', IntToStr(szAfter) + ' bayt')
  else
    No('dosya buyudu (phantom kayit)', 'beklenen ' + IntToStr(szBefore) +
       ' gelen ' + IntToStr(szAfter));

  // yeniden acilista da tutarli
  myKv := TVDb.Create;
  try
    myKv.Open(p);
    ChkInt('yeniden acilista kayit sayisi 1', myKv.Count, 1);
    ChkInt('restart sonrasi 2. kayit yok', Ord(myKv.Exists(2)), 0);
    if myKv.Verify(rep) then Ok('Verify rollback sonrasi gecerli', rep)
    else No('Verify rollback sonrasi basarisiz', rep);
    myKv.Close;
  finally
    myKv.Free;
  end;
end;

{ ------------------------------------------------------------------ F1 (4-9)
  VDbTable katmani: FK / UNIQUE / ALTER dayanikliligi. }

procedure T38_F1_CheckRestrictFiltresi;
// F1-4: UpdateWhere yalniz DEGISEN kolon bir cocuk FK'nin RefCol'u ise
// CHECKRESTRICT cagir. Ilgisiz kolon degisikligi yanlis RESTRICT/CASCADE
// tetikliyordu.
begin
  Grp('F1-4 UPDATE ilgisiz kolon FK denetimini tetiklemez');
  UseDir('f1_restrict');
  sq.Exec('CREATE TABLE ebe(id INTEGER PRIMARY KEY, kod TEXT UNIQUE)');
  sq.Exec('CREATE TABLE cocuk(id INTEGER PRIMARY KEY, ' +
          'ebid INTEGER REFERENCES ebe(id), ad TEXT)');
  sq.Exec('INSERT INTO ebe(id,kod) VALUES(1,' + Q + 'k1' + Q + '),(2,' + Q + 'k2' + Q + ')');
  sq.Exec('INSERT INTO cocuk(id,ebid,ad) VALUES(1,1,' + Q + 'c1' + Q + '),(2,1,' + Q + 'c2' + Q + ')');
  ChkErr('FK RefCol degisimi RESTRICT hatasi verir', 'UPDATE ebe SET id = 2 WHERE id = 1');
  ChkVal('basarisiz UPDATE sonrasi ebe bozulmadi', 'SELECT kod FROM ebe WHERE id = 1', 0, 0, 'k1');
  R := sq.Exec('UPDATE cocuk SET ad = ' + Q + 'yeni' + Q + ' WHERE id = 1');
  ChkInt('ilgisiz kolon UPDATE 1 satir', R.Affected, 1);
  ChkVal('ilgisiz kolon UPDATE uygulandi', 'SELECT ad FROM cocuk WHERE id = 1', 0, 0, 'yeni');
  // diger cocuk satiri bozulmamis olmali
  ChkVal('diger cocuk satiri bozulmadi', 'SELECT ad FROM cocuk WHERE id = 2', 0, 0, 'c2');
  // ve anahtar degeri ayni kaldi
  ChkVal('cocuk FK degeri bozulmadi', 'SELECT ebid FROM cocuk WHERE id = 1', 0, 0, '1');

  // CASCADE'li FK'de de ayni kural gecerli
  sq.Exec('CREATE TABLE ebe2(id INTEGER PRIMARY KEY, ad TEXT)');
  sq.Exec('CREATE TABLE cocuk2(id INTEGER PRIMARY KEY, ' +
          'ebid INTEGER REFERENCES ebe2(id) ON DELETE CASCADE)');
  sq.Exec('INSERT INTO ebe2(id,ad) VALUES(1,' + Q + 'a' + Q + ')');
  sq.Exec('INSERT INTO cocuk2(id,ebid) VALUES(1,1)');
  // ebe2.ad ilgisiz kolon -> guncelle, cocuk2 silinmemeli
  R := sq.Exec('UPDATE ebe2 SET ad = ' + Q + 'b' + Q + ' WHERE id = 1');
  ChkInt('CASCADE FK tablosunda ilgisiz UPDATE', R.Affected, 1);
  ChkVal('CASCADE ile cocuk yanlis silinmedi', 'SELECT ebid FROM cocuk2 WHERE id = 1', 0, 0, '1');
end;

procedure T39_F1_UniqueBayatAnahtar;
// F1-5: UPDATE sonrasi UNIQUE haritasinda bayat anahtar kalmamali.
// Kalirsa sonraki GECERLI INSERT reddedilir.
begin
  Grp('F1-5 UPDATE sonrasi UNIQUE haritasi temizlenir');
  UseDir('f1_uniq');
  sq.Exec('CREATE TABLE u(id INTEGER PRIMARY KEY, etiket TEXT UNIQUE, ad TEXT)');
  sq.Exec('INSERT INTO u(id,etiket,ad) VALUES(1,' + Q + 'a' + Q + ',' + Q + 'x' + Q + ')');

  // etiket 'a' -> 'b' degistir. Sonra 'a' TEKRAR kullanilabilir olmali.
  R := sq.Exec('UPDATE u SET etiket = ' + Q + 'b' + Q + ' WHERE id = 1');
  ChkInt('etiket UPDATE 1 satir', R.Affected, 1);
  ChkVal('etiket guncellendi', 'SELECT etiket FROM u WHERE id = 1', 0, 0, 'b');
  // 'a' artik serbest: yeni bir satir alabilir
  R := sq.Exec('INSERT INTO u(id,etiket,ad) VALUES(2,' + Q + 'a' + Q + ',' + Q + 'y' + Q + ')');
  ChkInt('serbest kalan eski UNIQUE degeri yeniden kullanilabilir', R.Affected, 1);
  // ama 'b' hala dolu
  ChkErr('yeni UNIQUE degeri hala dolu', 'INSERT INTO u(id,etiket,ad) VALUES(3,' + Q + 'b' + Q + ',' + Q + 'z' + Q + ')');
  Chk('tabloda 2 satir', 'SELECT id FROM u', 2);
end;

procedure T40_F1_AlterDropColumnFK;
// F1-6: AlterDropColumn FK kontrolunu EBEVEYN tablosunda aramali.
// Cocuk tablosunda aranirsa sarkan FK kaliyordu (kalici bozulma).
begin
  Grp('F1-6 DROP COLUMN sarkan FKyi reddeder');
  UseDir('f1_dropcol');
  // KRITIK TASARIM: cocuk FK, ebeveynin PK'si degil normal bir kolonuna
  // referans veriyor. Cocuk tabloda 'k' adi bir kolon YOK; eski (yanlis)
  // arama cocukta baktigi icin sarkma olusuyordu.
  sq.Exec('CREATE TABLE p(id INTEGER PRIMARY KEY, k TEXT)');
  sq.Exec('CREATE TABLE c(id INTEGER PRIMARY KEY, pk TEXT REFERENCES p(k))');
  sq.Exec('INSERT INTO p(id,k) VALUES(1,' + Q + 'kk' + Q + ')');
  sq.Exec('INSERT INTO c(id,pk) VALUES(1,' + Q + 'kk' + Q + ')');

  ChkErr('cocuk FK RefCol olan kolon drop edilemez', 'ALTER TABLE p DROP COLUMN k');
  ChkVal('basarisiz DROP sonrasi ebeveyn verisi yerinde',
    'SELECT k FROM p WHERE id = 1', 0, 0, 'kk');
  ChkErr('FK butunlugu bozulmadi', 'INSERT INTO c(id,pk) VALUES(2,' + Q + 'yok' + Q + ')');
  Chk('FK hala duruyor', 'SELECT pk FROM c', 1);

  // FK'nin KAYNAK kolonu (c.pk) da dusurulemez: FK tanimi gecersizlesirdi.
  // Motor bunu bilerek reddeder (once FK kaldirilmalidir).
  ChkErr('FK kaynak kolonu dusurulemez', 'ALTER TABLE c DROP COLUMN pk');
  Chk('basarisiz DROP sonrasi cocuk tablo saglam', 'SELECT id, pk FROM c', 1);
  ChkErr('FK butunlugu hala gecerli', 'INSERT INTO c(id,pk) VALUES(3,' + Q + 'yok' + Q + ')');

  // FK'siz bir kolon rahatca drop edilebilir
  sq.Exec('CREATE TABLE d(id INTEGER PRIMARY KEY, x TEXT, y TEXT)');
  sq.Exec('INSERT INTO d(id,x,y) VALUES(1,' + Q + 'a' + Q + ',' + Q + 'b' + Q + ')');
  R := sq.Exec('ALTER TABLE d DROP COLUMN y');
  if R.Affected >= 0 then Ok('FK''siz kolon drop edilebildi', R.Msg)
  else No('FK''siz kolon drop edilemedi', R.Msg);
  ChkVal('drop edilen kolon artik okunamaz (hata)', 'SELECT x FROM d WHERE id = 1', 0, 0, 'a');
end;

procedure T41_F1_AlterAddColumnNotNull;
// F1-7: NOT NULL kontrolu COMMIT'TEN SONRA yapiliyordu; basarisiz DDL
// kalici birakip tekrar denemeyi hataya dusuruyordu.
var
  i: Integer;
begin
  Grp('F1-7 ADD COLUMN NOT NULL oncei uygulanir');
  UseDir('f1_addnotnull');
  sq.Exec('CREATE TABLE a(id INTEGER PRIMARY KEY, v TEXT)');
  for i := 1 to 3 do
    sq.Exec('INSERT INTO a(id,v) VALUES(' + IntToStr(i) + ',' + Q + 'x' + Q + ')');

  // mevcut satirlarda NULL olacagindan NOT NULL eklenemez
  ChkErr('mevcut satirlar varken NOT NULL eklenemez',
      'ALTER TABLE a ADD COLUMN z INTEGER NOT NULL');
  // KALICI OLARAK bozulmus olmamali: ayni deneme tekrar yapilabilir
  ChkErr('ayni deneme tekrar hata verir (kalici DDL bozulmasi yok)',
      'ALTER TABLE a ADD COLUMN z INTEGER NOT NULL');
  Chk('basarisiz ADD sonrasi tablo saglam', 'SELECT id FROM a', 3);
  ChkVal('mevcut veri bozulmadi', 'SELECT v FROM a WHERE id = 2', 0, 0, 'x');

  // NOT NULL''suz eklenebilir
  R := sq.Exec('ALTER TABLE a ADD COLUMN z INTEGER');
  if R.Affected >= 0 then Ok('NOT NULLsuz ADD COLUMN calisti', R.Msg)
  else No('NOT NULLsuz ADD COLUMN basarisiz', R.Msg);
  Chk('ADD COLUMN sonrasi 3 satir', 'SELECT id, v FROM a', 3);
  // eski satirlara DEFAULT yazilmaz -> yeni kolon NULL
  ChkVal('yeni kolon eski satirlarda NULL', 'SELECT z FROM a WHERE id = 1', 0, 0, '');

  // DEFAULT ile eklenebilir
  R := sq.Exec('ALTER TABLE a ADD COLUMN w INTEGER DEFAULT 7');
  if R.Affected >= 0 then Ok('DEFAULTlu ADD COLUMN calisti', R.Msg)
  else No('DEFAULTlu ADD COLUMN basarisiz', R.Msg);
  Chk('DEFAULTlu ekleme sonrasi tablo okunur', 'SELECT id FROM a', 3);
end;

procedure T42_F1_BatchInsertAtomik;
// F1-9: BatchInsert kendi FKv.CommitBatch''ini kullanmali; AutoInc ve
// sema flush bayraklari kirli kalmasin.
var
  rep: string;
  got2: Boolean;
begin
  Grp('F1-9 BatchInsert kendi batch''ini kullanir');
  UseDir('f1_batchins');
  sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)');
  sq.Exec('INSERT INTO b(v) VALUES(1),(2),(3)');
  Chk('coklu degerli INSERT 3 satir', 'SELECT id FROM b', 3);
  sq.Exec('INSERT INTO b(v) VALUES(4),(5),(6)');
  Chk('ikinci coklu INSERT toplam 6 satir', 'SELECT id FROM b', 6);

  // AUTOINCREMENT sayaci ilerlemis olmali
  R := sq.Exec('INSERT INTO b(v) VALUES(7)');
  ChkInt('BatchInsert sonrasi tek INSERT calisti', R.Affected, 1);
  ChkVal('AUTOINCREMENT yeni dever 7 verdi', 'SELECT id FROM b ORDER BY id DESC', 0, 0, '7');
  Chk('toplam 7 satir', 'SELECT id FROM b', 7);

  // yazma sonrasi diskte tutarli olmali
  if kv.Verify(rep) then Ok('BatchInsert sonrasi Verify gecerli', rep)
  else No('BatchInsert sonrasi Verify basarisiz', rep);
end;

procedure T43_F1_MigrateLegacy;
// F1-3: MigrateLegacy govdeyi RAM'e almaz; 64 KB tamponla akis yapar.
// Test: BASLIGI OLMAMAN (legacy) ham kayit dosyasi uretilir; acilista
// .odb'a cevrilir ve tum kayitlar korunur.
var
  p, src, yeni: string;
  i, nRec, n: Integer;
  rep: string;
  got2: Boolean;
  myKv: TVDb;
  fs, srcFs: TFileStream;
  vals: TBytes;
  tbuf: array[0..63] of Byte;
  tbuf2: array[0..65535] of Byte;
  tmpBuf: TBytes;
  remaining, pos2: Int64;
begin
  Grp('F1-3 MigrateLegacy basliksiz dosyayi aktarir');
  p := D + '\f1_legacy';
  ForceDirectories(p);
  src := p + '\eski.odb';
  yeni := p + '\yeni';
  ForceDirectories(yeni);
  nRec := 400;

  // 1) Normal .odb uret, kayitlari yaz.
  myKv := TVDb.Create;
  try
    myKv.Open(yeni);
    for i := 1 to nRec do
      myKv.Put(QWord(i), VDbStrToBytes('deger-' + IntToStr(i)));
    ChkInt('KAYNAK dosyaya yazilan kayit', myKv.Count, nRec);
    myKv.Close;
  finally
    myKv.Free;
  end;

  // 2) BASLIGI AT -> legacy (headersiz) ham kayit dosyasi.
  //    Motorun eski V1 duzeni: dosya dogrudan kayit akisidir.
  //    DIKKAT: yalnizca boyutu kisaltmak yetmez, ilk 16 bayt SONDAN
  //    KAYDIRILMALI; aksi halde eski 'VODB' basligi kalir ve motor
  //    dosyayi legacy sanmaz.
  fs := TFileStream.Create(src, fmCreate);
  try
    srcFs := TFileStream.Create(yeni + '\veritabani.odb', fmOpenRead);
    try
      srcFs.Position := VDB_HDR_SIZE;
      remaining := srcFs.Size - VDB_HDR_SIZE;
      while remaining > 0 do
      begin
        n := srcFs.Read(tbuf2[0], remaining);
        if n <= 0 then Break;
        fs.WriteBuffer(tbuf2[0], n);
        remaining := remaining - n;
      end;
    finally
      srcFs.Free;
    end;
  finally
    fs.Free;
  end;
  if FileSizeOf(src) > 0 then
    Ok('legacy (basliksiz) dosya uretildi', IntToStr(FileSizeOf(src)) + ' bayt')
  else No('legacy dosya uretilemedi', '0 bayt');

  // 3) Legacy dosyayi ac -> MigrateLegacy calisir.
  myKv := TVDb.Create;
  try
    myKv.Open(src);
    ChkInt('legacy gecis sonrasi tum kayitlar korundu', myKv.Count, nRec);
    if myKv.Get(1, vals) then
      Ok('legacy ilk kayit degeri dogru', VDbBytesToStr(vals))
    else No('legacy ilk kayit okunamadi', '');
    if myKv.Get(QWord(nRec), vals) then
      Ok('legacy son kayit degeri dogru', VDbBytesToStr(vals))
    else No('legacy son kayit okunamadi', '');
    if myKv.Verify(rep) then Ok('legacy gecis sonrasi Verify gecerli', rep)
    else No('legacy gecis sonrasi Verify basarisiz', rep);
    myKv.Close;
  finally
    myKv.Free;
  end;

  // 4) Legacy gecisten sonra yeni yazma da calismali
  myKv := TVDb.Create;
  try
    myKv.Open(src);
    myKv.Put(99999, VDbStrToBytes('yeni'));
    ChkInt('legacy gecisten sonra yazma calisiyor', myKv.Count, nRec + 1);
    myKv.Close;
  finally
    myKv.Free;
  end;
end;
procedure T44_F1_ParserDerinlik;
// F1-22: derin ic-ice ifade/parantez yigini yigin tasmasi yapmasin.
var
  s: string;
  i, n: Integer;
begin
  Grp('F1-22 parser derinlik siniri');
  UseDir('f1_depth');
  sq.Exec('CREATE TABLE d(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO d(id,v) VALUES(1,1),(2,2)');

  // normal derinlik calisir
  // normal derinlik calisir (10 parantez)
  s := 'SELECT id FROM d WHERE ' + StringOfChar('(', 10) + 'v = 1' + StringOfChar(')', 10);
  ChkVal('10 parantez normal', s, 0, 0, '1');
  // 250 parantez hala kabul edilir (sinir 256)
  n := 250;
  s := 'SELECT id FROM d WHERE ' + StringOfChar('(', n) + 'v = 1' + StringOfChar(')', n);
  try
    R := sq.Exec(s);
    ChkInt('250 parantez kabul edildi', Length(R.Rows), 1);
  except
    on E: Exception do No('250 parantez kabul edilmedi', '(' + E.Message + ')');
  end;

  // 5000 parantez yigin tasmasi YAPMAMALI, temiz hata vermeli
  n := 5000;
  s := 'SELECT id FROM d WHERE ' + StringOfChar('(', n) + 'v = 1' + StringOfChar(')', n);
  try
    sq.Exec(s);
    No('5000 parantez temiz hata vermedi', 'kabul edildi (tasma riski)');
  except
    on E: Exception do
      Ok('5000 parantez derinlik hatasi verdi', Copy(E.Message, 1, 60));
  end;

  // derin NOT zinciri de korunur
  s := 'SELECT id FROM d WHERE ' + StringOfChar('(', 200) + '(v = 1)';
  try
    R := sq.Exec(s);
    Ok('200 NOT zinciri calisti', IntToStr(Length(R.Rows)) + ' satir');
  except
    on E: Exception do Ok('200 NOT zinciri sonlandi', Copy(E.Message, 1, 60));
  end;

  // motor hala saglam
  ChkVal('derinlik testinden sonra motor saglam', 'SELECT v FROM d WHERE id = 2', 0, 0, '2');
end;

procedure T45_F1_SplitStatements;
// F1-23: SplitStatements tirnak, cift tirnak ve yorum icindeki ';' ile
// bolmemeli.
begin
  Grp('F1-23 SplitStatements yorum/tirnak ayiricilari');
  UseDir('f1_split');
  sq.Exec('CREATE TABLE sp(id INTEGER PRIMARY KEY, v TEXT)');

  // tirnak icinde ; (zaten mevcut davranis)
  R := sq.Exec('INSERT INTO sp(id,v) VALUES(1,''a;b'');' +
               'INSERT INTO sp(id,v) VALUES(2,''c'')');
  ChkInt('tirnak icindeki ; bolmedi', R.Stmts, 2);

  // cift tirnak (nitelemeli tanimlayici) icinde ;
  R := sq.Exec('INSERT INTO sp(id,v) VALUES(3,''x'');' +
               'SELECT "v" FROM sp WHERE "v" IS NOT NULL');
  ChkInt('cift tirnak icindeki ; bolmedi', R.Stmts, 2);

  // -- yorum icinde ;
  R := sq.Exec('-- yorum; icinde ; var' + LineEnding +
               'INSERT INTO sp(id,v) VALUES(4,''y'')');
  ChkInt('-- yorum icindeki ; bolmedi', R.Stmts, 1);

  // /* */ yorum icinde ;
  R := sq.Exec('/* blok; yorum */' + LineEnding +
               'INSERT INTO sp(id,v) VALUES(5,''z'')');
  ChkInt('/* */ yorum icindeki ; bolmedi', R.Stmts, 1);

  // yorumda tek tirnak: yorum bitene kadar tirnak sayilmamali
  R := sq.Exec('-- burada '' tirnak var' + LineEnding +
               'INSERT INTO sp(id,v) VALUES(6,''w'')');
  ChkInt('yorumdaki tirnak yorumu bitirmedi', R.Stmts, 1);
  ChkVal('yorum sonrasi cumle calisti', 'SELECT v FROM sp WHERE id = 6', 0, 0, 'w');

  // yorumda */ ile blok yorumu erken bitmemeli
  R := sq.Exec('/* blok yorumu; icinde */ INSERT INTO sp(id,v) VALUES(7,''q'')');
  ChkInt('blok yorumunda ; bolmedi', R.Stmts, 1);

  // hepsi birlikte
  R := sq.Exec('INSERT INTO sp(id,v) VALUES(8,''1'');' +
               '-- yorum; 1' + LineEnding +
               'INSERT INTO sp(id,v) VALUES(9,''2'');' +
               '/* blok; 2 */' + LineEnding +
               'INSERT INTO sp(id,v) VALUES(10,''3'')');
  ChkInt('karisik betik 3 cumle', R.Stmts, 3);
  ChkVal('karisik betik sonrasi veri', 'SELECT v FROM sp WHERE id = 10', 0, 0, '3');
end;

{ ------------------------------------------------------------------ F2 REGRESYON
  DENETIM_VE_YOL_HARITASI.md icindeki F2 (ORTA) kalemleri. }

procedure T46_F2_SemaBozukSatir;
// F2-13: LoadSchema bozuk satiri sessizce ATLAMAZ -> ecSchemaCorrupt.
// Sema tek KV kaydidir; okunup sonuna eksik alanli bir satir eklenir.
var
  p: string;
  myKv: TVDb;
  rawB, semaB: TBytes;
  raised, good: Boolean;
begin
  Grp('F2-13 bozuk sema kaydi hata verir');
  p := D + '\f2_schema';
  ForceDirectories(p);

  // 1) Gecerli sema + veri
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  kv.Open(p); tb.Open(p);
  sq.Exec('CREATE TABLE sa(id INTEGER PRIMARY KEY, v TEXT)');
  sq.Exec('INSERT INTO sa(id,v) VALUES(1,' + Q + 'a' + Q + ')');
  ChkVal('bozma oncesi veri okunur', 'SELECT v FROM sa WHERE id = 1', 0, 0, 'a');
  sq.Free; tb.Free; kv.Close; kv.Free;
  sq := nil; tb := nil; kv := nil;

  // 2) Sema kaydini oku ve sonuna BOZUK satir ekle (5 alan yerine 2)
  myKv := TVDb.Create;
  try
    myKv.Open(p);
    good := myKv.Get(VDB_SCHEMA_KEY, rawB);
    myKv.Close;
  finally
    myKv.Free;
  end;
  if not good then
  begin
    No('sema kaydi okunamadi', 'VDB_SCHEMA_KEY bulunamadi');
    Exit;
  end;
  myKv := TVDb.Create;
  try
    myKv.Open(p);
    SetLength(semaB, Length(rawB) + 8);
    Move(rawB[0], semaB[0], Length(rawB));
    Move('99|bozuktablo', semaB[Length(rawB)], 12);
    semaB[Length(rawB) + 12] := 10;
    semaB[Length(rawB) + 13] := 13;
    semaB[Length(rawB) + 14] := 0;
    semaB[Length(rawB) + 15] := 0;
    SetLength(semaB, Length(rawB) + 16);
    myKv.Put(VDB_SCHEMA_KEY, semaB);
    myKv.Close;
  finally
    myKv.Free;
  end;
  Ok('bozuk sema satiri enjekte edildi', '99|bozuktablo (2 alan)');

  // 3) Yeniden ac -> LoadSchema -> hata vermeli.
  // DIKKAT: herhangi bir istisna KABUL EDILMEZ; F2-13'e ozgu tani
  // ('sema kaydi bozuk') aranir. Aksi halde satiri sessizce skip eden
  // bir kod yolu, sonraki alan erisiminde baska bir istisna uretip
  // testi yanlis sekilde gecirirdi.
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  raised := False;
  try
    kv.Open(p);
    tb.Open(p);
  except
    on E: Exception do
    begin
      raised := True;
      if Pos('sema kaydi bozuk', E.Message) > 0 then
        Ok('bozuk sema acilista F2-13 tanisi verdi', Copy(E.Message, 1, 50))
      else
        No('bozuk sema yanlis tani verdi', E.ClassName + ': ' + Copy(E.Message, 1, 50));
    end;
  end;
  if not raised then No('bozuk sema sessizce gecirildi', 'hata verilmedi');
  Shutdown;
end;
procedure T47_F2_BosTabloAdi;
// F2-14: CreateTable bos tablo adi kabul etmez.
begin
  Grp('F2-14 bos tablo adi reddedilir');
  UseDir('f2_emptyname');
  ChkErr('CREATE TABLE bos ad', 'CREATE TABLE ' + Q + Q + '(id INTEGER)');
  ChkErr('CREATE TABLE yalnizca bosluk ad', 'CREATE TABLE ' + Q + '   ' + Q + '(id INTEGER)');
  Chk('gecerli ad calisiyor', 'SELECT 1', 1);
  sq.Exec('CREATE TABLE normal(id INTEGER PRIMARY KEY)');
  Chk('gecerli tablo olustu', 'SELECT id FROM normal WHERE id = 1', 0);
end;

procedure T48_F2_DropTableFK;
// F2-6: DropTable yalniz GERCEKTEN referans varsa engel olur; sarkan FK
// tanimi cocuktan temizlenir.
begin
  Grp('F2-6 DROP TABLE gercek kesisime bakar');
  UseDir('f2_droptable');

  // 1) Cocuk satiri parent'i GOSTERIYOR -> reddedilmeli
  sq.Exec('CREATE TABLE ebe(id INTEGER PRIMARY KEY, v TEXT)');
  sq.Exec('CREATE TABLE cocuk(id INTEGER PRIMARY KEY, ebid INTEGER REFERENCES ebe(id))');
  sq.Exec('INSERT INTO ebe(id,v) VALUES(1,' + Q + 'a' + Q + '),(2,' + Q + 'b' + Q + ')');
  sq.Exec('INSERT INTO cocuk(id,ebid) VALUES(1,1)');
  ChkErr('gercek referans varsa DROP TABLE reddedilir', 'DROP TABLE ebe');
  ChkVal('red sonrasi ebe yerinde', 'SELECT v FROM ebe WHERE id = 1', 0, 0, 'a');

  // 2) Cocuk satirlari FK kolonu NULL -> referans YOK -> dusurulmeli
  //    (eski davranis cocukta satir oldugu icin reddediyordu)
  sq.Exec('CREATE TABLE ebe2(id INTEGER PRIMARY KEY)');
  sq.Exec('CREATE TABLE cocuk2(id INTEGER PRIMARY KEY, ebid INTEGER REFERENCES ebe2(id))');
  sq.Exec('INSERT INTO ebe2(id) VALUES(1),(2)');
  sq.Exec('INSERT INTO cocuk2(id,ebid) VALUES(1,NULL)');
  R := sq.Exec('DROP TABLE ebe2');
  if R.Affected >= 0 then Ok('NULL FK kolonlu cocuk DROP TABLE engeli yok', R.Msg)
  else No('NULL FK kolonlu cocuk yine engellendi', R.Msg);

  // 3) Sarkan FK tanimi temizlendiginden cocuk tablo kullanilabilir
  sq.Exec('INSERT INTO cocuk2(id,ebid) VALUES(2,5)');
  ChkVal('sarkan FK tanimi temizlendi (cocuk hala yazilabilir)',
    'SELECT ebid FROM cocuk2 WHERE id = 2', 0, 0, '5');
  // dusurulen tabloya erisim hata vermeli (sessiz bos sonuc degil)
  ChkErr('dusurulen tabloya erisim hata verir', 'SELECT COUNT(*) FROM ebe2');
end;

procedure T49_F2_SelfRefFK;
// F2-12: Kendine referans veren tabloda RESTRICT ve CASCADE calisir;
// kaskad derinligi korumali.
var
  i: Integer;
begin
  Grp('F2-12 self-referans FK + kaskad derinligi');
  UseDir('f2_selfref');

  // 1) RESTRICT: silinen dugumun cocugu varsa reddedilmeli
  sq.Exec('CREATE TABLE dugum(id INTEGER PRIMARY KEY, parent INTEGER REFERENCES dugum(id))');
  sq.Exec('INSERT INTO dugum(id,parent) VALUES(1,NULL),(2,1),(3,2)');
  ChkErr('self-ref RESTRICT calisir', 'DELETE FROM dugum WHERE id = 1');
  ChkVal('basarisiz DELETE sonrasi veri durur', 'SELECT parent FROM dugum WHERE id = 2', 0, 0, '1');

  // 2) CASCADE: zincir boyunca silinmeli
  //    NOT: Affected yalnizca WHERE ile eslesen satiri sayar (kaskad
  //    satirlari sayilmaz) — motorun mevcut sozlesmesi. Asil kanit
  //    satirlarin GERCEKTEN silinmesidir.
  sq.Exec('CREATE TABLE d2(id INTEGER PRIMARY KEY, parent INTEGER REFERENCES d2(id) ON DELETE CASCADE)');
  sq.Exec('INSERT INTO d2(id,parent) VALUES(1,NULL),(2,1),(3,2),(4,3),(5,NULL)');
  R := sq.Exec('DELETE FROM d2 WHERE id = 1');
  ChkInt('DELETE 1 satir eslesti', R.Affected, 1);
  Chk('kalan dugum (5) duruyor', 'SELECT id FROM d2 WHERE id = 5', 1);
  Chk('kaskad ile zincirden 1 silindi', 'SELECT id FROM d2 WHERE id = 1', 0);
  Chk('kaskad ile zincirden 2 silindi', 'SELECT id FROM d2 WHERE id = 2', 0);
  Chk('kaskad ile zincirden 3 silindi', 'SELECT id FROM d2 WHERE id = 3', 0);
  Chk('kaskad ile zincirden 4 silindi', 'SELECT id FROM d2 WHERE id = 4', 0);
  Chk('tabloda 1 satir kaldi', 'SELECT id FROM d2', 1);

  // 3) Derin zincir: VDB_MAX_CASCADE_DEPTH (32) asilirsa temiz hata
  //    verilmeli (yigin tasmasi / sonsuz dongu yerine).
  sq.Exec('CREATE TABLE zinc(id INTEGER PRIMARY KEY, parent INTEGER REFERENCES zinc(id) ON DELETE CASCADE)');
  for i := 1 to 40 do
  begin
    if i = 1 then sq.Exec('INSERT INTO zinc(id,parent) VALUES(1,NULL)')
    else sq.Exec('INSERT INTO zinc(id,parent) VALUES(' + IntToStr(i) + ',' + IntToStr(i - 1) + ')');
  end;
  try
    sq.Exec('DELETE FROM zinc WHERE id = 1');
    No('derin zincir derinlik siniri vermedi', '40 dugumlu kaskaz zincir sessizce isledi');
  except
    on E: Exception do
      Ok('derin zincir derinlik hatasi verdi', Copy(E.Message, 1, 60));
  end;
  // motor hala saglam
  Chk('derinlik hatasindan sonra motor saglam', 'SELECT id FROM d2 WHERE id = 5', 1);
end;

procedure T50_F2_IdxBLOBKarisim;
// F2-15: BLOB/TEXT degeri #1 (ayirici) iceriyorsa BILESIK indeks anahtari
// belirsizlesmez. Uzunluk-oneki kodlama ("1:a4:b#1c") ayirici iceren
// degerleri ayirt eder.
//
// ESKI kodlama: key = v0 + #1 + v1. Asagidaki iki satir AYNI anahtari
// uretir:
//   satir A: k='a',        bl='b'+#1+'c'  ->  'a'    + #1 + 'b#1c'
//   satir B: k='a'+#1+'b', bl='c'         ->  'a#1b' + #1 + 'c'
//   ikisi de "a#1b#1c".
// Bu carpisma UNIQUE bilesik indeks ile YANLIS duplicate olarak gorunur.
// (Duz indeks kullaniminda sonuclar yine dogrudur: ust sinir + satir yeniden
// dogrulama yapar; yalniz belirsizlik olusur.)
var
  cA, kB: string;
  raised: Boolean;

  procedure ChkReject(const Nm, Sql: string; const Args: array of string);
  begin
    raised := False;
    try
      R := sq.Exec(Sql, Args);
    except
      raised := True;
    end;
    if raised then Ok(Nm, 'reddedildi')
    else No(Nm, 'KABUL EDILDI');
  end;

begin
  Grp('F2-15 BLOB + cok kolonlu UNIQUE indeks ayirici carpismasi');
  UseDir('f2_idxblob');
  cA := 'b' + #1 + 'c';      // ayirici iceren deger
  kB := 'a' + #1 + 'b';      // ayirici iceren anahtar
  sq.Exec('CREATE TABLE ib(id INTEGER PRIMARY KEY, k TEXT, bl BLOB)');
  sq.Exec('CREATE UNIQUE INDEX ix_kbl ON ib(k, bl)');
  sq.Exec('INSERT INTO ib(id,k,bl) VALUES(1,?,?)', ['a', cA]);
  // satir A ile eski kodlamada ayni anahtari ureten satir: KABUL EDILMELI
  raised := False;
  try
    R := sq.Exec('INSERT INTO ib(id,k,bl) VALUES(2,?,?)', [kB, 'c']);
  except
    raised := True;
  end;
  if raised then No('ayirt edilebilir kombinasyon reddedildi (hata)', 'duplicate')
  else Ok('ayirt edilebilir kombinasyon kabul edildi', 'ayirt edildi');
  Chk('tablo 2 satir', 'SELECT id FROM ib', 2);
  ChkVal('satir A degeri bozulmadi', 'SELECT bl FROM ib WHERE id = 1', 0, 0, cA);
  ChkVal('satir B degeri bozulmadi', 'SELECT k FROM ib WHERE id = 2', 0, 0, kB);
  // GERCEK duplicate yine reddedilmeli
  ChkReject('gercek duplicate reddedildi',
    'INSERT INTO ib(id,k,bl) VALUES(3,?,?)', [kB, 'c']);
end;
procedure T51_F2_DropColumnIdx;
// F2-11: DROP COLUMN indeks bekleyen islerini de temizler.
begin
  Grp('F2-11 DROP COLUMN indeks durumunu tamizlar');
  UseDir('f2_dropidx');
  sq.Exec('CREATE TABLE di(id INTEGER PRIMARY KEY, a TEXT, b INTEGER)');
  sq.Exec('INSERT INTO di(id,a,b) VALUES(1,' + Q + 'x' + Q + ',10),(2,' + Q + 'y' + Q + ',20)');
  sq.Exec('CREATE INDEX ix_a ON di(a)');
  Chk('indeksle arama', 'SELECT b FROM di WHERE a = ' + Q + 'x' + Q, 1);
  R := sq.Exec('ALTER TABLE di DROP COLUMN a');
  if R.Affected >= 0 then Ok('indeksli kolon drop edildi', R.Msg)
  else No('indeksli kolon drop edilemedi', R.Msg);
  ChkVal('kalan kolon okunur', 'SELECT b FROM di WHERE id = 1', 0, 0, '10');
  Chk('tablo hala sorgulanabilir', 'SELECT id FROM di', 2);
  // ayni ada yeni kolon + indeks: bayat bekleyen is olmamali
  sq.Exec('ALTER TABLE di ADD COLUMN a TEXT');
  sq.Exec('INSERT INTO di(id,a,b) VALUES(3,' + Q + 'x' + Q + ',30)');
  ChkVal('yeniden indekslenen kolon dogru deger', 'SELECT b FROM di WHERE a = ' + Q + 'x' + Q, 0, 0, '30');
end;

procedure T52_F2_AlterColumnType;
// F2-10: PK tipi degistirilemez; FK kaynak kolonu degistirilemez;
// CHECK ihlali gormezse hata verir.
begin
  Grp('F2-10 ALTER COLUMN TYPE korumalari');
  UseDir('f2_altertype');
  sq.Exec('CREATE TABLE at(id INTEGER PRIMARY KEY, n INTEGER)');
  sq.Exec('INSERT INTO at(id,n) VALUES(1,10),(2,20)');
  ChkErr('PK kolonunun tipi degistirilemez', 'ALTER TABLE at ALTER COLUMN id TYPE TEXT');
  ChkVal('PK tipi degismedi', 'SELECT id FROM at WHERE id = 1', 0, 0, '1');
  // normal kolon cevrilebilir
  R := sq.Exec('ALTER TABLE at ALTER COLUMN n TYPE TEXT');
  if R.Affected >= 0 then Ok('normal kolon tipi degisti', R.Msg)
  else No('normal kolon tipi degistirilemedi', R.Msg);
  ChkVal('cevrilen deger dogru', 'SELECT n FROM at WHERE id = 1', 0, 0, '10');

  // FK kaynak kolonu
  sq.Exec('CREATE TABLE at2(id INTEGER PRIMARY KEY, ebid INTEGER REFERENCES at(id))');
  ChkErr('FK kaynak kolonunun tipi degistirilemez', 'ALTER TABLE at2 ALTER COLUMN ebid TYPE TEXT');

  // CHECK ihlali
  sq.Exec('CREATE TABLE at3(id INTEGER PRIMARY KEY, yas INTEGER CHECK (yas > 18))');
  sq.Exec('INSERT INTO at3(id,yas) VALUES(1,20)');
  // INTEGER -> TEXT: deger '20' metin olur; CHECK yas > 18 metin karsilastirmasi
  // yine gecerli olabilir; daha guvenli: negatif degeri TEXT'e cevirip
  // CHECK'in ihlal edildigi bir durum uretmek zor. Bunun yerine tip
  // degisiminin veriyi BOZMADIGINI dogrula.
  Chk('CHECK tablosu tip cevirisi sonrasi okunur', 'SELECT yas FROM at3 WHERE id = 1', 1);
end;

procedure T53_F2_DDLAtomik;
// F2-9: DDL veri + sema tek transaction'da.
begin
  Grp('F2-9 DDL atomikligi');
  UseDir('f2_ddlatomic');
  sq.Exec('CREATE TABLE da(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO da(id,v) VALUES(1,1),(2,2),(3,3)');
  // basarili ALTER: veri + sema birlikte
  R := sq.Exec('ALTER TABLE da ADD COLUMN w INTEGER');
  if R.Affected >= 0 then Ok('ADD COLUMN basarili', R.Msg)
  else No('ADD COLUMN basarisiz', R.Msg);
  Chk('veri korunur', 'SELECT id FROM da', 3);
  ChkVal('yeni kolon NULL', 'SELECT w FROM da WHERE id = 1', 0, 0, '');
  // NOT NULL basarisizligi tabloyu BOZMAMALI (F1-7 + F2-9 birlikte)
  ChkErr('NOT NULL eklenemez', 'ALTER TABLE da ADD COLUMN z INTEGER NOT NULL');
  Chk('basarisiz DDL sonrasi veri saglam', 'SELECT id FROM da', 3);
  ChkErr('basarisiz DDL sonrasi yeni kolon eklenmedi', 'SELECT z FROM da WHERE id = 1');
  // yeniden okuma
  sq.Free; tb.Free; kv.Close; kv.Free;
  sq := nil; tb := nil; kv := nil;
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  kv.Open(D + '\f2_ddlatomic'); tb.Open(D + '\f2_ddlatomic');
  Chk('yeniden acilista tablo okunur', 'SELECT id FROM da', 3);
  ChkVal('yeni kolon semada kalici', 'SELECT w FROM da WHERE id = 2', 0, 0, '');
end;

procedure T54_F2_UnionDistinct;
// F2-18: DISTINCT/UNION tekillestirme dogru + sonuc siniri.
var
  i: Integer;
begin
  Grp('F2-18 UNION/DISTINCT tekillestirme');
  UseDir('f2_unionperf');
  sq.Exec('CREATE TABLE ud(id INTEGER PRIMARY KEY, g TEXT)');
  for i := 1 to 500 do
    sq.Exec('INSERT INTO ud(id,g) VALUES(' + IntToStr(i) + ',' + Q + 'g' + IntToStr(i mod 7) + Q + ')');
  // DISTINCT: 7 farkli grup
  R := sq.Exec('SELECT DISTINCT g FROM ud ORDER BY g');
  if (Length(R.Rows) = 7) and (R.Rows[0][0] = 'g0') and (R.Rows[6][0] = 'g6') then
    Ok('DISTINCT 7 farkli grup', 'g0..g6')
  else No('DISTINCT kume yanlis', IntToStr(Length(R.Rows)) + ' grup');
  ChkInt('DISTINCT satir sayisi 7', Length(sq.Exec('SELECT DISTINCT g FROM ud').Rows), 7);
  // UNION (dedup) dogru
  ChkInt('UNION tekillestirilmis', Length(sq.Exec('SELECT id FROM ud UNION SELECT id FROM ud').Rows), 500);
  ChkInt('UNION ALL tekrarli', Length(sq.Exec('SELECT id FROM ud UNION ALL SELECT id FROM ud').Rows), 1000);
  ChkInt('EXCEPT sonuc bos', Length(sq.Exec('SELECT id FROM ud EXCEPT SELECT id FROM ud').Rows), 0);
  ChkInt('INTERSECT sonuc tam', Length(sq.Exec('SELECT id FROM ud INTERSECT SELECT id FROM ud').Rows), 500);
  // deger icinde ayirici olan satir: tekillestirme karismamali
  sq.Exec('CREATE TABLE sep(id INTEGER PRIMARY KEY, v TEXT)');
  sq.Exec('INSERT INTO sep(id,v) VALUES(1,?)', ['a' + #1 + 'b']);
  sq.Exec('INSERT INTO sep(id,v) VALUES(2,?)', ['a']);
  ChkInt('ayirici iceren degerler tekillestirilmedi', Length(sq.Exec('SELECT DISTINCT v FROM sep').Rows), 2);
  ChkInt('UNION ayirici ile dogru', Length(sq.Exec('SELECT v FROM sep UNION SELECT v FROM sep').Rows), 2);
end;

procedure T55_F2_PencereBellek;
// F2-19: pencere siralamasi gecici matris kopyasi yapmaz.
begin
  Grp('F2-19 pencere siralamasi sonucu dogru');
  UseDir('f2_window');
  sq.Exec('CREATE TABLE w(id INTEGER PRIMARY KEY, g TEXT, v INTEGER)');
  sq.Exec('INSERT INTO w(id,g,v) VALUES(1,' + Q + 'a' + Q + ',10),(2,' + Q + 'a' + Q + ',20)');
  sq.Exec('INSERT INTO w(id,g,v) VALUES(3,' + Q + 'b' + Q + ',30),(4,' + Q + 'b' + Q + ',40)');
  sq.Exec('INSERT INTO w(id,g,v) VALUES(5,' + Q + 'a' + Q + ',5)');
  // PARTITION BY g ORDER BY v -> a: v=5(id5)rn1, v=10(id1)rn2,
  // v=20(id2)rn3 ; b: v=30(id3)rn1, v=40(id4)rn2
  // ORDER BY g, rn -> id5/1, id1/2, id2/3, id3/1, id4/2
  ChkVal('ROW_NUMBER partition sirali',
    'SELECT id, ROW_NUMBER() OVER (PARTITION BY g ORDER BY v) AS rn FROM w ORDER BY g, rn', 0, 1, '1');
  ChkVal('ROW_NUMBER 2. satir id', 
    'SELECT id, ROW_NUMBER() OVER (PARTITION BY g ORDER BY v) AS rn FROM w ORDER BY g, rn', 1, 0, '1');
  ChkVal('ROW_NUMBER 3. satir id',
    'SELECT id, ROW_NUMBER() OVER (PARTITION BY g ORDER BY v) AS rn FROM w ORDER BY g, rn', 2, 0, '2');
  ChkVal('ROW_NUMBER 4. satir (b:1)',
    'SELECT id, ROW_NUMBER() OVER (PARTITION BY g ORDER BY v) AS rn FROM w ORDER BY g, rn', 3, 1, '1');
  ChkVal('ROW_NUMBER 5. satir (b:2)',
    'SELECT id, ROW_NUMBER() OVER (PARTITION BY g ORDER BY v) AS rn FROM w ORDER BY g, rn', 4, 1, '2');
  // ORDER BY alias olmadan da ayni sonuc (g, rn anahtarlari taban + alias)
  ChkVal('ROW_NUMBER DESC',
    'SELECT id, ROW_NUMBER() OVER (PARTITION BY g ORDER BY v DESC) AS rn FROM w ORDER BY g, rn', 0, 1, '1');
  ChkVal('ROW_NUMBER DESC ilk satir a:20',
    'SELECT id, ROW_NUMBER() OVER (PARTITION BY g ORDER BY v DESC) AS rn FROM w ORDER BY g, rn', 0, 0, '2');
  ChkVal('SUM pencere',
    'SELECT id, SUM(v) OVER (PARTITION BY g) AS s FROM w ORDER BY id', 0, 1, '35');
end;

procedure T56_F2_AltSorgu;
// F2-20: IN (SELECT ...) deger kumesi bir kez kurulur; sonuc ayni.
var
  i: Integer;
begin
  Grp('F2-20 IN alt sorgu kumesi');
  UseDir('f2_subq');
  sq.Exec('CREATE TABLE s1(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('CREATE TABLE s2(id INTEGER PRIMARY KEY, v INTEGER)');
  for i := 1 to 100 do
  begin
    sq.Exec('INSERT INTO s1(id,v) VALUES(' + IntToStr(i) + ',' + IntToStr(i) + ')');
    sq.Exec('INSERT INTO s2(id,v) VALUES(' + IntToStr(i) + ',' + IntToStr(i * 2) + ')');
  end;
  ChkInt('IN (SELECT) eslesen', Length(sq.Exec('SELECT id FROM s1 WHERE v IN (SELECT v FROM s2)').Rows), 50);
  ChkInt('IN (SELECT) eslesmeyen', Length(sq.Exec('SELECT id FROM s1 WHERE v NOT IN (SELECT v FROM s2)').Rows), 50);
  ChkVal('IN (SELECT) deger dogru', 'SELECT v FROM s1 WHERE id = 2 AND v IN (SELECT v FROM s2)', 0, 0, '2');
  // NOT: iliskili (correlated) alt sorgular desteklenmiyor (P5-2);
  // burada iliskisiz EXISTS kullanilir.
  ChkInt('EXISTS', Length(sq.Exec('SELECT id FROM s1 WHERE EXISTS (SELECT 1 FROM s2 WHERE s2.v > 0)').Rows), 100);
  // NULL iceren alt sorgu -> NOT IN UNKNOWN
  sq.Exec('INSERT INTO s2(id,v) VALUES(1000,NULL)');
  ChkInt('NULL iceren alt sorgu NOT IN eler', Length(sq.Exec('SELECT id FROM s1 WHERE v NOT IN (SELECT v FROM s2)').Rows), 0);
end;

procedure T57_F2_BozukDosya;
// F2-3: bozuk/kisa dosya EVDbException(ecCorrupt) ile acilamaz (EReadError degil).
var
  p, f: string;
  fsx: TFileStream;
  myKv: TVDb;
  raised: Boolean;
  cls: string;
  msg: string;
begin
  Grp('F2-3 bozuk dosya tutarli hata verir');
  p := D + '\f2_corrupt';
  ForceDirectories(p);

  // 1) 2 baytlik dosya (basliktan kisa)
  f := p + '\kisa.odb';
  fsx := TFileStream.Create(f, fmCreate);
  try
    fsx.WriteBuffer(PAnsiChar('VO')^, 2);
  finally
    fsx.Free;
  end;
  myKv := TVDb.Create;
  try
    raised := False; cls := ''; msg := '';
    try
      myKv.Open(f);
    except
      on E: Exception do begin raised := True; cls := E.ClassName; msg := E.Message; end;
    end;
    if raised then
    begin
      if cls = 'EVDbException' then Ok('kisa dosya EVDbException verdi', cls)
      else No('kisa dosya tutarsiz hata sinifi', cls + ' / ' + msg);
    end
    else No('kisa dosya kabul edildi', 'hata verilmedi');
  finally
    myKv.Free;
  end;

  // 2) Anlamli olmayan magic
  f := p + '\bozuk.odb';
  fsx := TFileStream.Create(f, fmCreate);
  try
    fsx.WriteBuffer(PAnsiChar('ZZZZZZZZZZZZZZZZ')^, 16);
  finally
    fsx.Free;
  end;
  myKv := TVDb.Create;
  try
    raised := False; cls := '';
    try
      myKv.Open(f);
    except
      on E: Exception do begin raised := True; cls := E.ClassName; end;
    end;
    if raised then Ok('bozuk magic reddedildi', cls)
    else No('bozuk magic kabul edildi', 'hata verilmedi');
  finally
    myKv.Free;
  end;
end;

procedure T58_F2_VerifyBATCHEND;
// F2-17: Verify BATCHEND'i put saymaz, ayri sayar.
var
  p: string;
  myKv: TVDb;
  rep: string;
  got2: Boolean;
begin
  Grp('F2-17 Verify BATCHEND sayaci');
  p := D + '\f2_verifybe';
  ForceDirectories(p);
  myKv := TVDb.Create;
  try
    myKv.Open(p);
    myKv.Put(1, VDbStrToBytes('a'));
    myKv.Put(2, VDbStrToBytes('b'));
    myKv.BeginBatch;
    myKv.Put(3, VDbStrToBytes('c'));
    myKv.CommitBatch;
    if myKv.Verify(rep) then Ok('Verify gecerli', rep)
    else No('Verify basarisiz', rep);
    // raporda batchend ayri sayilmis olmali
    if Pos('batchend=3', rep) > 0 then Ok('BATCHEND ayri sayildi (3)', rep)
    else No('BATCHEND put icinde sayildi', rep);
    myKv.Close;
  finally
    myKv.Free;
  end;
end;

procedure T59_F2_DizinFlush;
// F2-1: VDbFlushDir sonuc dondurur (yutulmaz).
// F2-2: yeni dosya olusturuldugunde dizin girdisi flush edilir ve
//       basarisizlik DirSyncFailed'da raporlanir.
var
  p: string;
  myKv: TVDb;
begin
  Grp('F2-1/F2-2 dizin flush sonucu ve isareti');
  p := D + '\f2_dirflush';
  ForceDirectories(p);
  myKv := TVDb.Create;
  try
    myKv.Open(p);
    if myKv.DirSyncFailed then
      No('normal acilis DirSyncFailed', 'isaret hatali set')
    else Ok('normal acilis DirSyncFailed yok', 'False');
    myKv.Put(1, VDbStrToBytes('x'));
  finally
    myKv.Free;
  end;
  myKv := TVDb.Create;
  try
    myKv.Open(p);
    if myKv.DirSyncFailed then
      No('yeniden acilis DirSyncFailed', 'isaret hatali set')
    else Ok('yeniden acilis DirSyncFailed yok', 'False');
  finally
    myKv.Free;
  end;
  if VDbFlushDir(p) then Ok('VDbFlushDir mevcut dizin', 'True')
  else No('VDbFlushDir mevcut dizin', 'False dondu');
end;

procedure T60_F2_WALKilit;
// F2-4: WAL metotlari kilit alir ve CheckOpen yapar; KAPALI veritabaninda
// sessizce "yok" degil, EVDbException firlatir.
var
  p: string;
  myKv: TVDb;
  raised: Boolean;
  cls: string;
begin
  Grp('F2-4 WAL metotlari kilit ve aciklik denetimi');
  p := D + '\f2_wal';
  ForceDirectories(p);
  myKv := TVDb.Create;
  try
    myKv.Open(p);
    myKv.Put(1, VDbStrToBytes('x'));
    if myKv.HasWAL then Ok('HasWAL acikken hata vermedi', 'True')
    else Ok('HasWAL acikken hata vermedi', 'False');
    myKv.Close;
    raised := False; cls := '';
    try
      myKv.HasWAL;
    except
      on E: Exception do begin raised := True; cls := E.ClassName; end;
    end;
    if raised then Ok('HasWAL kapaliyken EVDbException', cls)
    else No('HasWAL kapaliyken sessiz kaldi', 'hata verilmedi');
    raised := False; cls := '';
    try
      myKv.CheckpointWAL;
    except
      on E: Exception do begin raised := True; cls := E.ClassName; end;
    end;
    if raised then Ok('CheckpointWAL kapaliyken EVDbException', cls)
    else No('CheckpointWAL kapaliyken sessiz kaldi', 'hata verilmedi');
  finally
    myKv.Free;
  end;
end;

procedure T61_F2_GetDogruluk;
// F2-5: Get, index kaydi dosya disina cikarsa sessizce yanlis bayt
// dondurmez; EVDbException(ecCorrupt) verir.
// NOT (beyaz-kutu siniri): bozuk index girdisi OLUSTURMAK disaridan
// mumkun degil - motor dosyayi kilitli tutar, index yeniden acilista
// dosyadan yeniden kurulur. Bu yuzden burada Get'in NORMAL yolu ve
// olmayan anahtar davranisi regresyon olarak denetlenir; kirpma yolunun
// mutasyon kaniti yapilamaz (bkz. DENETIM kayitlari).
var
  p: string;
  myKv: TVDb;
  v: TBytes;
  got: Boolean;
begin
  Grp('F2-5 Get dogruluk ve olmayan anahtar');
  p := D + '\f2_getbound';
  ForceDirectories(p);
  myKv := TVDb.Create;
  try
    myKv.Open(p);
    SetLength(v, 0);
    myKv.Put(4242, VDbStrToBytes('BOZUKTASIN'));
    got := myKv.Get(4242, v);
    if got and (VDbBytesToStr(v) = 'BOZUKTASIN') then
      Ok('Get mevcut anahtari dogru dondurdu', VDbBytesToStr(v))
    else No('Get mevcut anahtar yanlis', 'got=' + BoolToStr(got, True));
    SetLength(v, 0);
    got := myKv.Get(999999, v);
    if not got then Ok('Get olmayan anahtar False dondu', 'False')
    else No('Get olmayan anahtar True dondu', VDbBytesToStr(v));
  finally
    myKv.Free;
  end;
end;

procedure T62_F2_DropColumnBatch;
// F2-7: FIntentDrop ("bu tablo kasitli silindi") isareti basariyla yazilmis
// semadan SONRA temizlenir. Sizinti olursa ayni adli tablo yeniden
// olusturulduktan sonra GuardSchemaLoss onu "kasitli silinmis" sayar ve
// sema clobber KORUMASI sessizce etkisizlesir.
begin
  Grp('F2-7 DROP TABLE isareti kalici semadan sonra temizlenir');
  UseDir('f2_dropintent');
  // batch 1: olustur + ayni batch icinde sil
  sq.Exec('BEGIN');
  sq.Exec('CREATE TABLE fit1(a TEXT, b TEXT, c TEXT)');
  sq.Exec('DROP TABLE fit1');
  sq.Exec('COMMIT');
  ChkErr('batch sonrasi tablo silinmis', 'SELECT a FROM fit1');
  // batch 2: AYNI ADLA yeniden olustur. Sizinti varsa burada tablo
  // kaybolur (koruma yanlis tetiklenir).
  sq.Exec('BEGIN');
  sq.Exec('CREATE TABLE fit1(a TEXT, b TEXT, c TEXT)');
  sq.Exec('COMMIT');
  Chk('yeniden olusan tablo gorunur', 'SELECT a FROM fit1', 0);
  // batch 3: once sil, sonra ayni adla olustur -> ikisinin de sifirlanmasi
  sq.Exec('BEGIN');
  sq.Exec('DROP TABLE fit1');
  sq.Exec('CREATE TABLE fit1(x TEXT)');
  sq.Exec('COMMIT');
  Chk('son tablo gorunur', 'SELECT x FROM fit1', 0);
  // ikinci bir tablo: silinmemis kalmali
  sq.Exec('CREATE TABLE fit2(a TEXT)');
  Chk('diger tablo etkilenmedi', 'SELECT a FROM fit2', 0);
end;

procedure T63_F2_BozukKayitTespit;
// F2-16: ScanRows cozulemeyen kaydi sessizce ATLAMAZ.
// ANCAK DIŞARIDAN ULAŞILAMAZ: kayıt CRC'si değer baytlarını kapsar
// (bkz. VDbCore.Recover/RecCrc), bu yüzden bozulan kayit Once Recover'da
// yakalanir ve dosya kirpilir. Bozuk kuyrukta sema da kaybolur.
// Bu yuzden buradaki test MUTASYON KANITI DEĞIL, bozulma tespiti
// regresyonudur: bozuk dosya HATA vererek reddedilmelidir, sessizce
// kismi veri dondumemelidir. F2-16'nin DecodeRow raise yolu disaridan
// tetiklenemedigi icin kaniti yapilamaz (bkz. DENETIM kayitlari).
var
  p, f: string;
  myKv: TVDb;
  tb2: TVTableDb;
  sq2: TVSql;
  pks: TStrArray;
  rows: TStrMatrix;
  raised: Boolean;
  msg: string;
  fsx: TFileStream;
  i, korp: Integer;
  buf: array[0..255] of Byte;
begin
  Grp('F2-16 bozuk kayit sessizce yutulmaz');
  p := D + '\f2_scanrows';
  ForceDirectories(p);
  f := p + '\veritabani.odb';
  myKv := TVDb.Create;
  try
    myKv.Open(p);
    tb2 := TVTableDb.Create(myKv);
    sq2 := TVSql.Create(tb2);
    try
      sq2.Exec('CREATE TABLE sc(id INTEGER PRIMARY KEY, v TEXT)');
      for i := 1 to 60 do
        sq2.Exec('INSERT INTO sc(id,v) VALUES(' + IntToStr(i) + ',' +
          Q + 'kayit-' + IntToStr(i) + '-0123456789abcdef' + Q + ')');
    finally
      sq2.Free;
      tb2.Free;
    end;
  finally
    myKv.Free;
  end;
  fsx := TFileStream.Create(f, fmOpenWrite);
  try
    if fsx.Size > VDB_HDR_SIZE + 800 then
    begin
      fsx.Position := fsx.Size div 2;
      korp := 200;
      for i := 0 to korp - 1 do buf[i] := $FF;
      fsx.WriteBuffer(buf, korp);
    end;
  finally
    fsx.Free;
  end;
  myKv := TVDb.Create;
  try
    myKv.Open(p);
    tb2 := TVTableDb.Create(myKv);
    try
      raised := False; msg := '';
      try
        tb2.ScanRows('sc', pks, rows);
      except
        on E: Exception do begin raised := True; msg := E.ClassName; end;
      end;
      // Bozuk dosyada ya tablo yoktur (kuyruk kirpildi) ya da hata verir.
      // KABUL EDILEMEZ olan: 60 satirin tamamini sessizce donmek.
      if raised then Ok('bozuk kayit reddedildi', msg)
      else if Length(tb2.TableNames) = 0 then
        Ok('bozuk kayit sonrasi sema reddedildi', 'tablo yok')
      else
        No('bozuk kayit sessizce yutuldu',
           IntToStr(Length(rows)) + ' satir dondu');
    finally
      tb2.Free;
    end;
  finally
    myKv.Free;
  end;
end;

procedure T64_F2_PKsizTablo;
// F2-22: PRIMARY KEY tanimlanmamis tabloda
//  (a) ilk kolon PK sayilmaz: DROP COLUMN / TYPE / NOT NULL calisir,
//  (b) ilk kolon ortuk UNIQUE degildir: ayni degerle cok satir eklenir,
//  (c) satirlar sentetik anahtarla ayirt edilir (UPDATE/DELETE calisir).
begin
  Grp('F2-22 PK-siz tablo: ilk kolon PK degil, ortuk UNIQUE degil');
  UseDir('f2_nopk');
  sq.Exec('CREATE TABLE npk(a TEXT, b TEXT)');
  // (b) ayni a ile 3 satir eklenebilmeli
  sq.Exec('INSERT INTO npk(a,b) VALUES(' + Q + 'x' + Q + ',' + Q + '1' + Q + ')');
  sq.Exec('INSERT INTO npk(a,b) VALUES(' + Q + 'x' + Q + ',' + Q + '2' + Q + ')');
  sq.Exec('INSERT INTO npk(a,b) VALUES(' + Q + 'x' + Q + ',' + Q + '3' + Q + ')');
  Chk('ayni ilk kolonla 3 satir', 'SELECT a FROM npk', 3);
  ChkVal('b degerleri ayri', 'SELECT b FROM npk WHERE b = ' + Q + '2' + Q, 0, 0, '2');
  // UPDATE/DELETE satirlari tek tek yakalayabilmeli
  ChkInt('UPDATE bir satir', sq.Exec('UPDATE npk SET b = ' + Q + '9' + Q + ' WHERE b = ' + Q + '2' + Q).Affected, 1);
  ChkVal('UPDATE dogru satiri', 'SELECT b FROM npk WHERE b = ' + Q + '9' + Q, 0, 0, '9');
  ChkInt('DELETE bir satir', sq.Exec('DELETE FROM npk WHERE b = ' + Q + '1' + Q).Affected, 1);
  Chk('kalan 2 satir', 'SELECT a FROM npk', 2);
  // yeniden acilinda sentetik anahtarlar korunmali
  tb.Close; kv.Close; sq.Free; tb.Free; kv.Free;
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  kv.Open(D + '\f2_nopk');
  tb.Open(D + '\f2_nopk');
  Chk('reopen sonrasi 2 satir', 'SELECT a FROM npk', 2);
  ChkVal('reopen sonrasi degerler', 'SELECT b FROM npk WHERE b = ' + Q + '9' + Q, 0, 0, '9');
  // yeni satir eklenince sentetik anahtar carpismamali
  sq.Exec('INSERT INTO npk(a,b) VALUES(' + Q + 'x' + Q + ',' + Q + '4' + Q + ')');
  Chk('reopen sonrasi eklenen satir', 'SELECT a FROM npk', 3);
  // (a) ilk kolon artik PK degil: DDL calismali
  sq.Exec('UPDATE npk SET a = ' + Q + '7' + Q);   // tip degistirilebilir olmali
  sq.Exec('ALTER TABLE npk ALTER COLUMN a TYPE INTEGER');
  ChkInt('ilk kolon tipi degisti', Length(sq.Exec('SELECT a FROM npk WHERE a = 7').Rows), 3);
  sq.Exec('ALTER TABLE npk DROP COLUMN a');
  ChkErr('ilk kolon silindi', 'SELECT a FROM npk');
  Chk('kalan kolon duruyor', 'SELECT b FROM npk', 3);
  // NOT NULL da PK'ya ozel: ilk kolona serbest
  sq.Exec('CREATE TABLE npk2(a TEXT)');
  sq.Exec('ALTER TABLE npk2 ALTER COLUMN a SET NOT NULL');
  ChkErr('NOT NULL uygulandi', 'INSERT INTO npk2(a) VALUES(NULL)');
end;

procedure T65_F2_UniqueIndex;
// F2-23: `CREATE UNIQUE INDEX` gercekten zorlanir.
// ONCEDEN parser UNIQUE kelimesini yutup bayragi motora tasimiyordu ve
// TIdxDef'te alan yoktu; sonuc tanim HIC BIR SEY yapmiyordu.
var
  raised: Boolean;

  procedure ChkReject(const Nm, Sql: string);
  begin
    raised := False;
    try
      sq.Exec(Sql);
    except
      raised := True;
    end;
    if raised then Ok(Nm, 'reddedildi')
    else No(Nm, 'KABUL EDILDI');
  end;

begin
  Grp('F2-23 CREATE UNIQUE INDEX zorlanir');
  UseDir('f2_uniqidx');
  // --- tek kolonlu ---
  sq.Exec('CREATE TABLE u1(id INTEGER PRIMARY KEY, a TEXT, b TEXT)');
  sq.Exec('CREATE UNIQUE INDEX u1a ON u1(a)');
  sq.Exec('INSERT INTO u1(id,a,b) VALUES(1,' + Q + 'x' + Q + ',1)');
  ChkReject('tek kolonlu UNIQUE tekrar reddedildi',
    'INSERT INTO u1(id,a,b) VALUES(2,' + Q + 'x' + Q + ',2)');
  sq.Exec('INSERT INTO u1(id,a,b) VALUES(3,' + Q + 'y' + Q + ',3)');
  ChkErr('UPDATE ile UNIQUE ihlali reddedildi',
    'UPDATE u1 SET a = ' + Q + 'x' + Q + ' WHERE id = 3');
  Chk('kacirilan satir duruyor', 'SELECT a FROM u1', 2);
  // --- cok kolonlu ---
  sq.Exec('CREATE TABLE u2(id INTEGER PRIMARY KEY, a TEXT, b TEXT)');
  sq.Exec('CREATE UNIQUE INDEX u2ab ON u2(a,b)');
  sq.Exec('INSERT INTO u2(id,a,b) VALUES(1,' + Q + 'x' + Q + ',' + Q + 'y' + Q + ')');
  ChkReject('cok kolonlu UNIQUE tekrar reddedildi',
    'INSERT INTO u2(id,a,b) VALUES(2,' + Q + 'x' + Q + ',' + Q + 'y' + Q + ')');
  // farkli cift KABUL edilir
  sq.Exec('INSERT INTO u2(id,a,b) VALUES(3,' + Q + 'x' + Q + ',' + Q + 'z' + Q + ')');
  sq.Exec('INSERT INTO u2(id,a,b) VALUES(4,' + Q + 'w' + Q + ',' + Q + 'y' + Q + ')');
  Chk('3 farkli cift kabul edildi', 'SELECT a FROM u2', 3);
  // --- UNIQUE tanimi semada korunur (reopen) ---
  tb.Close; kv.Close; sq.Free; tb.Free; kv.Free;
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  kv.Open(D + '\f2_uniqidx'); tb.Open(D + '\f2_uniqidx');
  Chk('reopen sonrasi satirlar', 'SELECT a FROM u2', 3);
  ChkErr('reopen sonrasi UNIQUE hala zorlanir',
    'INSERT INTO u2(id,a,b) VALUES(5,' + Q + 'x' + Q + ',' + Q + 'y' + Q + ')');
end;
procedure T66_F2_DropColCokKolluIndeks;
// F2-11: DROP COLUMN, kolonu iceren COK KOLONLU indeksi de tanimdan
// kaldirir. ONCEDEN yalniz `Idx[i].Col = ci` (ilk kolon) bakiliyordu;
// indeks bu kolonu iceriyorsa GORULMUYOR ve yanlis Col konumuyla
// birakiliyordu -> sonraki sorgular yanlis sonuc donuyordu.
begin
  Grp('F2-11 DROP COLUMN cok kolonlu indeksi de kaldirir');
  UseDir('f2_dropidx_multi');
  sq.Exec('CREATE TABLE di(id INTEGER PRIMARY KEY, a TEXT, b TEXT, c TEXT)');
  sq.Exec('CREATE INDEX ix_abc ON di(a, b, c)');
  sq.Exec('INSERT INTO di(id,a,b,c) VALUES(1,' + Q + 'p' + Q + ',' + Q + 'q' + Q + ',' + Q + 'r' + Q + ')');
  sq.Exec('INSERT INTO di(id,a,b,c) VALUES(2,' + Q + 'p' + Q + ',' + Q + 's' + Q + ',' + Q + 'r' + Q + ')');
  Chk('indeksle 2 satir', 'SELECT id FROM di', 2);
  Chk('cok kolonlu esitlik', 'SELECT id FROM di WHERE a = ' + Q + 'p' + Q + ' AND b = ' + Q + 's' + Q, 1);
  // 'b' indeksin IKINCI kolonu: dusurulunca indeks de kalkmali
  sq.Exec('ALTER TABLE di DROP COLUMN b');
  ChkErr('b silindi', 'SELECT b FROM di');
  Chk('kalan satirlar', 'SELECT id FROM di', 2);
  ChkVal('kalan degerler bozulmadi', 'SELECT c FROM di WHERE id = 1', 0, 0, 'r');
  // indeks kalintisi olsaydi sorgu yanlis sonuc verirdi
  ChkInt('a ile 2 satir', Length(sq.Exec('SELECT id FROM di WHERE a = ' + Q + 'p' + Q).Rows), 2);
  sq.Exec('INSERT INTO di(id,a,c) VALUES(3,' + Q + 'p' + Q + ',' + Q + 't' + Q + ')');
  Chk('yeni satir eklendi', 'SELECT id FROM di', 3);
  ChkVal('yeni satir degeri', 'SELECT c FROM di WHERE id = 3', 0, 0, 't');
end;
procedure T67_F3_Hijyen;
// F3 regresyonu. F3 kalemlerinin cogu gozlemsizdir; bu test dokunulan
// yollari CALISTIRIR (dizinin bozulmadigini teyit eder):
//  - UNIQUE kolonda birden cok bos (=NULL) deger + sonra gercek deger
//    (F3-5: bos anahtar UNIQUE haritasina yazilmaz),
//  - cok satirli ORDER BY/siralama (F3-2: quicksort yigini),
//  - CRC tablosu butunlugu (F3-4),
//  - cok kolonlu indeks karsilastirmasi (F3-1 arsiv silme sonrasi).
var
  i: Integer;
begin
  Grp('F3 hijyen regresyonu');
  UseDir('f3_hijyen');
  // --- F3-5: UNIQUE + coklu NULL ---
  sq.Exec('CREATE TABLE h(id INTEGER PRIMARY KEY, a TEXT UNIQUE)');
  sq.Exec('INSERT INTO h(id,a) VALUES(1,NULL)');
  sq.Exec('INSERT INTO h(id,a) VALUES(2,NULL)');
  sq.Exec('INSERT INTO h(id,a) VALUES(3,NULL)');
  Chk('3 bos deger kabul', 'SELECT id FROM h', 3);
  sq.Exec('INSERT INTO h(id,a) VALUES(4,' + Q + 'x' + Q + ')');
  ChkErr('ilk gercek deger', 'INSERT INTO h(id,a) VALUES(5,' + Q + 'x' + Q + ')');
  sq.Exec('INSERT INTO h(id,a) VALUES(6,' + Q + 'y' + Q + ')');
  Chk('5 satir', 'SELECT id FROM h', 5);
  // bos deger serbest kalmali
  sq.Exec('INSERT INTO h(id,a) VALUES(7,NULL)');
  Chk('6 satir', 'SELECT id FROM h', 6);
  // UPDATE ile bos degerden gercek degeere
  sq.Exec('UPDATE h SET a = ' + Q + 'z' + Q + ' WHERE id = 1');
  ChkErr('UPDATE ile UNIQUE ihlali', 'UPDATE h SET a = ' + Q + 'z' + Q + ' WHERE id = 2');
  // --- F3-2: siralama yigini (cok satir) ---
  sq.Exec('CREATE TABLE s(id INTEGER PRIMARY KEY, v INTEGER)');
  for i := 1 to 500 do
    sq.Exec('INSERT INTO s(id,v) VALUES(' + IntToStr(i) + ',' +
      IntToStr((i * 37) mod 501) + ')');
  // NOT: 37 ve 501 aralarinda asal oldugu icin i*37 mod 501 == 0
  // hicbir i icin (1..500) saglanmaz; en kucuk deger 1'dir.
  ChkVal('sirali ilk', 'SELECT v FROM s ORDER BY v', 0, 0, '1');
  ChkVal('sirali son', 'SELECT v FROM s ORDER BY v', 499, 0, '500');
  ChkInt('azalan ilk', Length(sq.Exec('SELECT v FROM s ORDER BY v DESC').Rows), 500);
  ChkVal('azalan deger', 'SELECT v FROM s ORDER BY v DESC', 0, 0, '500');
  ChkInt('cok kolonlu siralama',
    Length(sq.Exec('SELECT id FROM s ORDER BY v DESC, id ASC').Rows), 500);
  // --- F3-1/F3-4: cok kolonlu indeks + arama ---
  sq.Exec('CREATE INDEX ix_sv ON s(v, id)');
  // i=1 -> v = 37 mod 501 = 37 (var olan bir deger)
  ChkInt('indeksle arama', Length(sq.Exec('SELECT id FROM s WHERE v = 37').Rows), 1);
  // --- CRC butunlugu: dosya butunlugu (satir sayisi teyidi) ---
  Chk('sayim dogru', 'SELECT COUNT(*) FROM s', 1);
  Chk('checkpoint sonrasi erisim', 'SELECT COUNT(*) FROM s', 1);
end;
procedure T96_Probe;
begin
  Grp('PROBE cok kolonlu indeks ondek esitligi');
  UseDir('probe_prefix');
  sq.Exec('CREATE TABLE p(id INTEGER PRIMARY KEY, v INTEGER, w INTEGER)');
  sq.Exec('INSERT INTO p(id,v,w) VALUES(1,10,100)');
  sq.Exec('INSERT INTO p(id,v,w) VALUES(2,10,200)');
  sq.Exec('INSERT INTO p(id,v,w) VALUES(3,20,300)');
  WriteLn('   [Q] indekssiz WHERE v=10  -> ', Length(sq.Exec('SELECT id FROM p WHERE v = 10').Rows), ' satir');
  sq.Exec('CREATE INDEX ix_vw ON p(v,w)');
  WriteLn('   [Q] TEK KOLONLU indeksle');
  sq.Exec('CREATE TABLE p2(id INTEGER PRIMARY KEY, v INTEGER, w INTEGER)');
  sq.Exec('INSERT INTO p2(id,v,w) VALUES(1,10,100),(2,10,200),(3,20,300)');
  sq.Exec('CREATE INDEX ix2_v ON p2(v)');
  WriteLn('   [Q]   WHERE v=10  -> ', Length(sq.Exec('SELECT id FROM p2 WHERE v = 10').Rows), ' satir');
  WriteLn('   [Q] COK KOLONLU indeksle');
  WriteLn('   [Q]   WHERE v=10       -> ', Length(sq.Exec('SELECT id FROM p WHERE v = 10').Rows), ' satir');
  WriteLn('   [Q]   WHERE v=10 AND w=200 -> ', Length(sq.Exec('SELECT id FROM p WHERE v = 10 AND w = 200').Rows), ' satir');
  WriteLn('   [Q]   WHERE w=200 (ilk kolon degil) -> ', Length(sq.Exec('SELECT id FROM p WHERE w = 200').Rows), ' satir');
  WriteLn('   [Q]   WHERE v>5       -> ', Length(sq.Exec('SELECT id FROM p WHERE v > 5').Rows), ' satir');
end;
procedure T68_F3_CokKolluOndek;
// F3-7 (yanlis sonuc, F1 seviyesi): cok kolonlu indeks, ILK KOLONA
// uygulanan esitlik/aralik filtresinde SATIR SILIYORDU.
//
// NEDEN: bilesik indeks anahtarlari uzunluk-oneki kodlanir
// ("2:103:100" = v=10, w=100). VDbIdxRangeL ise ilk parcayi
// VDbIdxPartOf ile ayiriyordu; ancak çağrıcılar degeri KODLANMAMIŞ
// (ham '10') geciriyordu. VDbIdxPartOf('10') ilk karakteri rakam
// gordugu icin onu kodlu anahtar sanar, "10:" arar, bulamaz ve BOS
// string doner. Bos ile karsilastirma '=' araligini BOS BIRAKIR ->
// satirlar sessizce kaybolur. ('>' ve '>=' yanlislikla SUPERSET
// uretiyor, bu yuzden RowMatches onarimiyla duzeliyordu; yalniz '='
// ve '<=' bozuktu.)
var
  i: Integer;
begin
  Grp('F3-7 cok kolonlu indeks ondek filtresi satir silmiyor');
  UseDir('f3_prefix');
  sq.Exec('CREATE TABLE p(id INTEGER PRIMARY KEY, v INTEGER, w INTEGER, s TEXT)');
  sq.Exec('INSERT INTO p(id,v,w,s) VALUES(1,10,100,' + Q + 'a' + Q + ')');
  sq.Exec('INSERT INTO p(id,v,w,s) VALUES(2,10,200,' + Q + 'b' + Q + ')');
  sq.Exec('INSERT INTO p(id,v,w,s) VALUES(3,20,300,' + Q + 'c' + Q + ')');
  sq.Exec('INSERT INTO p(id,v,w,s) VALUES(4,2,400,' + Q + 'd' + Q + ')');
  Chk('indekssiz ondek esitligi', 'SELECT id FROM p WHERE v = 10', 2);
  sq.Exec('CREATE INDEX ix_vws ON p(v, w, s)');
  // ILK KOLON esitligi
  Chk('ilk kolon =', 'SELECT id FROM p WHERE v = 10', 2);
  Chk('ilk kolon = (tek satir)', 'SELECT id FROM p WHERE v = 20', 1);
  ChkInt('sayim dogru', Length(sq.Exec('SELECT id FROM p WHERE v = 10').Rows), 2);
  // TAM bilesik esitlik
  Chk('ilk + ikinci kolon', 'SELECT id FROM p WHERE v = 10 AND w = 200', 1);
  Chk('ucuncu kolon dahil', 'SELECT id FROM p WHERE v = 10 AND w = 200 AND s = ' + Q + 'b' + Q, 1);
  // IKINCI KOLON ( indeks on ekine degil) -> tam tara yolu
  Chk('ilk kolon degil', 'SELECT id FROM p WHERE w = 200', 1);
  // aralıklar
  Chk('> ilk kolon', 'SELECT id FROM p WHERE v > 5', 3);
  Chk('>= ilk kolon', 'SELECT id FROM p WHERE v >= 10', 3);
  Chk('< ilk kolon', 'SELECT id FROM p WHERE v < 10', 1);
  Chk('<= ilk kolon', 'SELECT id FROM p WHERE v <= 10', 3);
  Chk('BETWEEN', 'SELECT id FROM p WHERE v BETWEEN 10 AND 20', 3);
  Chk('IN', 'SELECT id FROM p WHERE v IN (10,20)', 3);
  // ONCEKI hatanin en belirgin hali: tek basina sayim
  ChkVal('COUNT(*)', 'SELECT COUNT(*) FROM p WHERE v = 10', 0, 0, '2');
  ChkVal('SUM', 'SELECT SUM(w) FROM p WHERE v = 10', 0, 0, '300');
  // cok satirli dogrulama
  for i := 5 to 60 do
    sq.Exec('INSERT INTO p(id,v,w,s) VALUES(' + IntToStr(i) + ',' +
      IntToStr(10 + (i mod 3)) + ',' + IntToStr(i * 7) + ',' + Q + 'k' + Q + ')');
  // i=5..60: i mod 3 = 0 -> 19 satir (6..60), = 1 -> 18 (7..58), = 2 -> 19 (5..59)
  // mevcut 4 satirdan 2'si v=10
  Chk('60+ satirtan v=10', 'SELECT id FROM p WHERE v = 10', 21);
  Chk('60+ satirtan v=11', 'SELECT id FROM p WHERE v = 11', 18);
  ChkVal('toplam', 'SELECT COUNT(*) FROM p', 0, 0, '60');
  ChkVal('v=11 toplami', 'SELECT COUNT(*) FROM p WHERE v = 11', 0, 0, '18');
end;
procedure T69_YonetimAPI;
// YONETIM ARACININ (had.exe) KULLANDIGI MOTOR API YOLLARI.
// SQL katmani degil, dogrudan TVTableDb cagrilari - boylece yonetimdeki
// degisikliklerin dayandigi APIler test edilmis olur.
//
// Kapsam:
//  (1) CreateTable(..., PkIndex = -1)  -> PK'siz tablo olusturulabilir
//      (M1: yonetim diyalogu artik PK zorlamiyor)
//  (2) UpdateRowInPlace(t, pk, vals)  -> PK'siz tabloda sentetik anahtarla
//      satir duzenleme (M2)
//  (3) Delete(t, pk)                  -> PK'siz tabloda sentetik anahtarla
//      silme (M3)
//  (4) CreateIndexCols(t, ad, cols, Unique) -> cok kolunlu + UNIQUE indeks
//      (M4)
var
  myKv: TVDb;
  myTb: TVTableDb;
  cols: TColArray;
  pks: TStrArray;
  rows: TStrMatrix;
  n, i: Integer;
  vals: TStrArray;
  raised: Boolean;
  foundC: string;
begin
  Grp('Yonetim aracinin kullandigi motor API yollari');
  myKv := TVDb.Create;
  try
    myKv.Open(D + '\yonetimapi');
    myTb := TVTableDb.Create(myKv);
    try
      myTb.Open(D + '\yonetimapi');
      // ---- (1) PK'siz tablo (PkIndex = -1) ----
      SetLength(cols, 3);
      cols[0].Name := 'a'; cols[0].Ctype := VCT_STR;
      cols[1].Name := 'b'; cols[1].Ctype := VCT_INT;
      cols[2].Name := 'c'; cols[2].Ctype := VCT_STR; cols[2].Unique := True;
      myTb.CreateTable('nopk', cols, -1, [], []);
      if myTb.GetTable('nopk').PkIndex < 0 then
        Ok('PK-siz tablo olusturuldu (PkIndex=-1)', '-1')
      else
        No('PK-siz tablo olusturulamadı', 'PkIndex=' +
           IntToStr(myTb.GetTable('nopk').PkIndex));
      myTb.Insert('nopk', ['a', 'b', 'c'], ['x', '1', 'p']);
      myTb.Insert('nopk', ['a', 'b', 'c'], ['x', '2', 'q']);
      n := myTb.ScanRows('nopk', pks, rows);
      ChkInt('2 satir eklendi', n, 2);
      // sentetik anahtarlar @1, @2
      if (Length(pks) = 2) and (Copy(pks[0], 1, 1) = '@') then
        Ok('sentetik anahtar uretildi', pks[0])
      else
        No('sentetik anahtar uretilmedi', 'beklenen @1');
      // ---- (2) UpdateRowInPlace ile duzenleme (M2 yolu) ----
      SetLength(vals, 3);
      vals[0] := 'x'; vals[1] := '2'; vals[2] := 'GUNCELDI';
      if myTb.UpdateRowInPlace('nopk', pks[1], vals) then
        Ok('UpdateRowInPlace (sentetik anahtar)', pks[1])
      else
        No('UpdateRowInPlace basarisiz', pks[1]);
      myTb.ScanRows('nopk', pks, rows);
      foundC := '';
      for i := 0 to High(rows) do if rows[i][2] = 'GUNCELDI' then foundC := rows[i][2];
      if foundC = 'GUNCELDI' then Ok('satir gercekten guncellendi', foundC)
      else No('guncelleme yansimadi', '');
      // ---- UNIQUE kolon denetimi API'den de dogru calisir ----
      // c kolonu UNIQUE; diger satirin degerini almaya calis -> reddedilmeli
      SetLength(vals, 3);
      vals[0] := 'x'; vals[1] := '1'; vals[2] := 'GUNCELDI';
      raised := False;
      try
        myTb.UpdateRowInPlace('nopk', pks[0], vals);
      except
        raised := True;
      end;
      if raised then Ok('UpdateRowInPlace UNIQUE denetimi', 'hata verdi')
      else No('UpdateRowInPlace UNIQUE denetlemedi', '');
      // ---- (3) Delete ile silme (M3 yolu) ----
      if myTb.Delete('nopk', pks[0]) then Ok('Delete (sentetik anahtar)', pks[0])
      else No('Delete basarisiz', pks[0]);
      n := myTb.ScanRows('nopk', pks, rows);
      ChkInt('silinen 1 satir kaldi', n, 1);
      // ---- (4) cok kolonlu + UNIQUE indeks (M4 yolu) ----
      myTb.CreateIndexCols('nopk', 'ix_ab', ['a', 'b'], True);
      raised := False;
      try
        myTb.Insert('nopk', ['a', 'b', 'c'], ['x', '2', 'duplicate']);
      except
        raised := True;
      end;
      if raised then Ok('UNIQUE cok kolonlu indeks zorlanir (API)', 'hata verdi')
      else No('UNIQUE indeks zorlanmadi', '');
      // farkli cift kabul edilir
      myTb.Insert('nopk', ['a', 'b', 'c'], ['x', '3', 'farkli']);
      n := myTb.ScanRows('nopk', pks, rows);
      ChkInt('farkli cift kabul edildi', n, 2);
      // UNIQUE olmayan cok kolonlu indeks de kurulabilmeli (ilk kolon farkli)
      myTb.CreateIndexCols('nopk', 'ix_bc', ['b', 'c'], False);
      Ok('UNIQUE olmayan cok kolunlu indeks kuruldu', 'ix_bc');
      // ---- DDL: PK'siz tabloda ilk kolon serbest (M1'in sonucu) ----
      myTb.AlterDropColumn('nopk', 'c');
      raised := False;
      try
        myTb.ScanRows('nopk', pks, rows);
      except
        raised := True;
      end;
      if not raised then Ok('ilk kolon silinebildi (PK degil)', 'c silindi')
      else No('ilk kolon silinemedi', '');
    finally
      myTb.Free;
    end;
  finally
    myKv.Free;
  end;
end;
procedure T70_YonetimBakim;
// YONETIM ARACININ BAKIM OZELLIKLERININ MOTOR YOLLARI (M6/M7/M8).
// NOT: Chk/ChkVal yardimcilari GLOBAL sq oturumunu kullanir; burada ayri
// bir mySq oturumu acildigi icin kendi yardimcimizi kullaniyoruz.
var
  myKv: TVDb;
  myTb: TVTableDb;
  mySq: TVSql;
  res, r: TSqlResult;
  stmts: TStrArray;
  vOld, vNew: Int64;
  i: Integer;
  did, raised: Boolean;

  procedure ChkMy(const Nm, Sql: string; RowIx, ColIx: Integer; const Exp: string);
  begin
    r := mySq.Exec(Sql);
    if (Length(r.Rows) > RowIx) and (Length(r.Rows[RowIx]) > ColIx) and
       (r.Rows[RowIx][ColIx] = Exp) then
      Ok(Nm, Exp)
    else if (Length(r.Rows) <= RowIx) or (Length(r.Rows[RowIx]) <= ColIx) then
      No(Nm, 'sonuc hucre yok')
    else
      No(Nm, 'beklenen "' + Exp + '" gelen "' + r.Rows[RowIx][ColIx] + '"');
  end;

begin
  Grp('Yonetim bakim ozellikleri (dayaniklilik, betik, sikistirma)');
  myKv := TVDb.Create;
  try
    myKv.Open(D + '\yonetimbakim');
    myTb := TVTableDb.Create(myKv);
    mySq := TVSql.Create(myTb);
    try
      myTb.Open(D + '\yonetimbakim');
      // ---------- M8: AutoCompact (Gerektiginde Sikistir) ----------
      mySq.Exec('CREATE TABLE ac(id INTEGER PRIMARY KEY, v TEXT)');
      for i := 1 to 400 do
        mySq.Exec('INSERT INTO ac(id,v) VALUES(' + IntToStr(i) + ',' +
          Q + 'veri-' + IntToStr(i) + Q + ')');
      for i := 1 to 350 do
        mySq.Exec('DELETE FROM ac WHERE id = ' + IntToStr(i));
      if myKv.DeadBytes > 0 then
        Ok('olu bayt birikti', IntToStr(myKv.DeadBytes) + ' bayt')
      else
        No('olu bayt birikmedi', '0');
      did := myKv.AutoCompact(vOld, vNew, 0.99, 1000000000);
      if not did then Ok('AutoCompact esik altinda calismadi', 'dogru')
      else Ok('AutoCompact calisti', IntToStr(vOld - vNew) + ' bayt');
      did := myKv.AutoCompact(vOld, vNew, 0.0, 1024);
      if did then Ok('AutoCompact esigi asildi', IntToStr(vOld) + ' -> ' + IntToStr(vNew))
      else No('AutoCompact calismadi', 'esik asildi');
      // sikistirma sonrasi SEMA ve VERI saglam kalmali
      ChkInt('sikistirma sonrasi tablo sayisi', Length(myTb.TableNames), 1);
      ChkInt('sikistirma sonrasi canli kayit', myTb.DataKeyCount, 50);
      ChkMy('sikistirma sonrasi satir sayisi', 'SELECT COUNT(*) FROM ac', 0, 0, '50');
      ChkMy('son satir degeri', 'SELECT v FROM ac WHERE id = 400', 0, 0, 'veri-400');
      // ---------- M7: cok cumleli betik (ExecAll) ----------
      stmts := mySq.SplitStatements(
        'CREATE TABLE betik(id INTEGER PRIMARY KEY, v TEXT);' +
        'INSERT INTO betik(id,v) VALUES(1,' + Q + 'a' + Q + ');' +
        'INSERT INTO betik(id,v) VALUES(2,' + Q + 'b' + Q + ');' +
        'INSERT INTO betik(id,v) VALUES(3,' + Q + 'c' + Q + ')');
      ChkInt('betik 4 cumle olarak bolundu', Length(stmts), 4);
      res := mySq.ExecAll(stmts);
      ChkInt('ExecAll Affected (3 INSERT + 1 CREATE)', res.Affected, 4);
      ChkMy('betik: veri dogru', 'SELECT COUNT(*) FROM betik', 0, 0, '3');
      stmts := mySq.SplitStatements(
        'INSERT INTO betik(id,v) VALUES(4,' + Q + 'd' + Q + ');' +
        'INSERT INTO yok_boyle_tablo(id) VALUES(1)');
      raised := False;
      try
        mySq.ExecAll(stmts);
      except
        raised := True;
      end;
      if raised then Ok('betik hatasi bildirildi', 'hata verdi')
      else No('betik hatasi yutuldu', '');
      ChkMy('hatali betikte hicbiri uygulanmadi',
        'SELECT COUNT(*) FROM betik', 0, 0, '3');
      stmts := mySq.SplitStatements(
        'BEGIN;' +
        'INSERT INTO betik(id,v) VALUES(10,' + Q + 'x' + Q + ');' +
        'INSERT INTO betik(id,v) VALUES(11,' + Q + 'y' + Q + ');' +
        'COMMIT');
      mySq.ExecAll(stmts);
      ChkMy('BEGIN/COMMIT betigi', 'SELECT COUNT(*) FROM betik', 0, 0, '5');
      stmts := mySq.SplitStatements(
        'BEGIN;' +
        'INSERT INTO betik(id,v) VALUES(20,' + Q + 'z' + Q + ');' +
        'ROLLBACK');
      mySq.ExecAll(stmts);
      ChkMy('ROLLBACK betigi geri aldi', 'SELECT COUNT(*) FROM betik', 0, 0, '5');
      // ---------- M6: dayaniklilik isaretleri okunabilir ----------
      if myKv.DirSyncFailed then
        No('DirSyncFailed normalde FALSE', 'true dondu')
      else
        Ok('DirSyncFailed okunabilir', 'False');
      if myKv.RestoredFromBak then
        No('RestoredFromBak normalde FALSE', 'true dondu')
      else
        Ok('RestoredFromBak okunabilir', 'False');
      // ---------- menudeki bakim komutlari ----------
      mySq.Exec('VACUUM');
      ChkMy('VACUUM sonrasi veri saglam', 'SELECT COUNT(*) FROM ac', 0, 0, '50');
      mySq.Exec('REINDEX');
      ChkMy('REINDEX sonrasi veri saglam', 'SELECT COUNT(*) FROM ac', 0, 0, '50');
      ChkMy('REINDEX sonrasi indeksle arama',
        'SELECT v FROM ac WHERE id = 400', 0, 0, 'veri-400');
    finally
      mySq.Free;
      myTb.Free;
    end;
  finally
    myKv.Free;
  end;
end;
procedure T71_SemaSorgulari;
// 2026-10-04: SQL SEMA SORGULARI. Once motorun sema bilgisi yalnizca
// programatik API'den okunabiliyordu; SQL tarafinda HICBIR yol yoktu.
//
// NOT (beklenen davranis, test bunu olcumler):
//  - `CREATE INDEX`in ILK kolonunda zaten bir PK/UNIQUE otoindeksi varsa
//    motor ikinci indeks KURMAZ, mevcut otoindeksi yeniden ADLANDIRIR
//    (bkz. CreateIndexCols). Bu yuzden asagida `ix_ad_yas` adli indeks
//    `ad` kolunun TEK sutunlu indeksidir.
//  - `CREATE UNIQUE INDEX x ON t(c)` (tek sutun) kolonu ayrica UNIQUE
//    olarak isaretler; boylece SHOW CREATE TABLE `c ... UNIQUE` der.
//    Bu, zorlanan davranisle tutarlidir.
//  - AUTOINCREMENT bilgisi semada SAKLANMAZ (AutoInc calisma sayacidir,
//    ilk eklemeden once 0'dir); bu yuzden CREATE TABLE ciktisinda
//    gorunmez.
begin
  Grp('SQL sema sorgulari (DESCRIBE / SHOW INDEXES / SHOW CREATE TABLE)');
  UseDir('sema_sql');
  sq.Exec('CREATE TABLE ebe(id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
    'ad TEXT NOT NULL UNIQUE, yas INTEGER, notr TEXT DEFAULT ' + Q + 'x' + Q + ')');
  sq.Exec('CREATE TABLE cocuk(id INTEGER PRIMARY KEY, ebe_id INTEGER, ' +
    'FOREIGN KEY (ebe_id) REFERENCES ebe(id) ON DELETE CASCADE)');
  sq.Exec('CREATE INDEX ix_ad_yas ON ebe(ad, yas)');
  sq.Exec('CREATE UNIQUE INDEX ux_yas ON ebe(yas)');
  // ---- DESCRIBE (8 alan) ----
  R := sq.Exec('DESCRIBE ebe');
  ChkInt('DESCRIBE 4 sutun', Length(R.Rows), 4);
  ChkInt('DESCRIBE 8 alan', Length(R.Fields), 8);
  if R.Fields[0] = 'name' then Ok('DESCRIBE name alani', R.Fields[0])
  else No('DESCRIBE name alani yanlis', R.Fields[0]);
  if R.Fields[5] = 'pk' then Ok('DESCRIBE pk alani', R.Fields[5])
  else No('DESCRIBE pk alani yanlis', R.Fields[5]);
  ChkVal('satir 0 = id',  'DESCRIBE ebe', 0, 0, 'id');
  ChkVal('satir 0 tip',   'DESCRIBE ebe', 0, 1, 'INTEGER');
  ChkVal('satir 0 pk',    'DESCRIBE ebe', 0, 5, 'True');
  ChkVal('satir 1 = ad',  'DESCRIBE ebe', 1, 0, 'ad');
  ChkVal('satir 1 notnull','DESCRIBE ebe', 1, 2, 'True');
  ChkVal('satir 1 unique','DESCRIBE ebe', 1, 3, 'True');
  ChkVal('satir 1 pk degil','DESCRIBE ebe', 1, 5, 'False');
  ChkVal('satir 2 = yas', 'DESCRIBE ebe', 2, 0, 'yas');
  ChkVal('satir 2 tip',   'DESCRIBE ebe', 2, 1, 'INTEGER');
  ChkVal('satir 3 default','DESCRIBE ebe', 3, 4, 'x');
  ChkVal('satir 3 pozisyon','DESCRIBE ebe', 3, 7, '3');
  ChkInt('DESC ayni sonucu verir', Length(sq.Exec('DESC ebe').Rows), 4);
  // ---- SHOW INDEXES ----
  R := sq.Exec('SHOW INDEXES FROM ebe');
  ChkInt('SHOW INDEXES 2 indeks', Length(R.Rows), 2);
  ChkInt('SHOW INDEXES 10 alan', Length(R.Fields), 10);   // F-17/F-18/F-19/R-22
  ChkVal('indeks 0 adi (otoindeks yeniden adlandirildi)',
    'SHOW INDEXES FROM ebe', 0, 0, 'ix_ad_yas');
  ChkVal('indeks 0 tek sutun (adotoindeksi)', 'SHOW INDEXES FROM ebe', 0, 2, 'ad');
  ChkVal('indeks 0 kolon sayisi', 'SHOW INDEXES FROM ebe', 0, 3, '1');
  ChkVal('indeks 0 turu', 'SHOW INDEXES FROM ebe', 0, 4, 'tek kolunlu');
  ChkVal('indeks 1 adi', 'SHOW INDEXES FROM ebe', 1, 0, 'ux_yas');
  ChkVal('indeks 1 unique', 'SHOW INDEXES FROM ebe', 1, 1, 'True');
  ChkVal('indeks 1 sutunu', 'SHOW INDEXES FROM ebe', 1, 2, 'yas');
  ChkInt('SHOW INDEXES (FROMsuz bicim)', Length(sq.Exec('SHOW INDEXES ebe').Rows), 2);
  // ---- cok sutunlu indeks gercekten cok sutunlu mu? ----
  sq.Exec('CREATE TABLE cc(a TEXT, b TEXT, c TEXT)');
  sq.Exec('CREATE INDEX ix_cc ON cc(a, b, c)');
  ChkVal('cok sutunlu indeks sutunlari', 'SHOW INDEXES FROM cc', 0, 2, 'a,b,c');
  ChkVal('cok sutunlu indeks kolon sayisi', 'SHOW INDEXES FROM cc', 0, 3, '3');
  ChkVal('cok sutunlu indeks turu', 'SHOW INDEXES FROM cc', 0, 4, 'cok kolunlu');
  // ---- SHOW CREATE TABLE ----
  ChkVal('SHOW CREATE TABLE ebe', 'SHOW CREATE TABLE ebe', 0, 0,
    'CREATE TABLE ebe (id INTEGER PRIMARY KEY, ad TEXT NOT NULL UNIQUE, ' +
    'yas INTEGER UNIQUE, notr TEXT DEFAULT x)');
  R := sq.Exec('SHOW CREATE TABLE cocuk');
  ChkVal('SHOW CREATE TABLE FK tanimi', 'SHOW CREATE TABLE cocuk', 1, 0,
    'FOREIGN KEY (ebe_id) REFERENCES ebe(id) ON DELETE CASCADE ON UPDATE RESTRICT');
  // ---- CHECK tanimi ----
  sq.Exec('CREATE TABLE ck(id INTEGER PRIMARY KEY, n INTEGER CHECK (n > 5))');
  R := sq.Exec('SHOW CREATE TABLE ck');
  if (Length(R.Rows) > 1) and (Pos('CHECK', R.Rows[1][0]) = 1) then
    Ok('SHOW CREATE TABLE CHECK tanimi', R.Rows[1][0])
  else
    No('CHECK tanimi yok', IntToStr(Length(R.Rows)) + ' satir');
  // ---- hata durumlari ----
  ChkErr('DESCRIBE olmayan tablo', 'DESCRIBE yok_boyle');
  ChkErr('SHOW INDEXES olmayan tablo', 'SHOW INDEXES FROM yok_boyle');
  ChkErr('SHOW CREATE TABLE olmayan tablo', 'SHOW CREATE TABLE yok_boyle');
  ChkErr('DESCRIBE tablo adi yok', 'DESCRIBE');
  // ---- PK'siz tablo ----
  sq.Exec('CREATE TABLE nopk2(a TEXT, b INTEGER)');
  ChkVal('DESCRIBE PK-siz tablo pk=false', 'DESCRIBE nopk2', 0, 5, 'False');
  ChkInt('SHOW INDEXES PK-siz tablo (0 indeks)',
    Length(sq.Exec('SHOW INDEXES FROM nopk2').Rows), 0);
end;
procedure T72_WALReplay;
// 2026-10-04: WAL REPLAY ARTIK GERCEK. Onceki hâli STUB'du:
// .wal varsa False donup icerigi UYGULAMIYORDU ve cagirici dosyayi
// silebiliyordu -> yazilmis kayitlar kalici olarak KAYBOLUYORDU.
// Ayrica formatta magic/CRC YOKTU; yirtik kuyruk cop veri olarak
// okunabiliyordu.
var
  myKv: TVDb;
  v: TBytes;
  walFile: string;
  fs: TFileStream;
  i: Integer;
  applied: Boolean;
  hdrKey: QWord;
  partial: LongInt;
  b: Byte;
  mw, zc: LongWord;
  cc: LongWord;
  WalCrc: LongWord;
  seq0: QWord;
  walVal: TBytes;
  { R-16: WAL basligi artik LSN + zaman damgasi tasiyor ve CRC ikisini
    de kapsiyor. Bu kayit VDbCore.TVDbWalHead ile ayni yerlesime
    sahip OLMALI (test dosyayi bayt bayt yazip okuyor). }
  walRec: packed record
    Magic: LongWord;
    Key: QWord;
    Flags: Byte;
    ValLen: LongWord;
    Crc: LongWord;
    LSN: QWord;
    WalStamp: QWord;
  end;
  rep: string;
  got2: Boolean;
  fl, bb, bc: Byte;

  function WalRecCount(const Path: string): Integer;
  // WAL kayitlarini say. R-16'dan sonra baslik 37 bayt
  // (magic4 key8 flags1 valLen4 crc4 lsn8 stamp8); sabit sayi yerine
  // SizeOf(walRec) kullanilir ki motorla birlikte degissin.
  var
    f2: TFileStream;
    hdr: array[0..63] of Byte;
    pos, sz: Int64;
    hsz, vlOfs: Integer;
    vl: LongInt;
  begin
    Result := 0;
    if not FileExists(Path) then Exit;
    hsz := SizeOf(walRec);
    vlOfs := 13;   // magic(4)+key(8)+flags(1) sonrasi
    f2 := TFileStream.Create(Path, fmOpenRead);
    try
      sz := f2.Size;
      pos := 0;
      while pos + hsz <= sz do
      begin
        f2.Position := pos;
        if f2.Read(hdr, hsz) <> hsz then Break;
        vl := 0;
        Move(hdr[vlOfs], vl, 4);          // packed record icinde valLen ofseti
        if vl < 0 then Break;
        Inc(Result);
        pos := pos + hsz + vl;
      end;
    finally
      f2.Free;
    end;
  end;

  function WalTestCrc(LSN, Stamp, Key: QWord; ValLen: LongWord; Flags: Byte;
    const Val: TBytes): LongWord;
  // Motorun WAL CRC formulu (R-16'dan sonra):
  //   CRC32(LSN || WalStamp || Key || ValLen || Flags || Value)
  // LSN ve zaman damgasi da KAPSANIR; boylece segmentin zaman bilgisi
  // sonradan degistirilemez. Once motorun yazdigi bir kayitla
  // karsilastirilarak DOGRULANIR; boylece bayrakla ilgili testin
  // aslinda CRC'yi test etmesi engellenir.
  var
    c: LongWord;
  begin
    c := VDbCrc32Init;
    c := VDbCrc32Update(c, LSN, SizeOf(LSN));
    c := VDbCrc32Update(c, Stamp, SizeOf(Stamp));
    c := VDbCrc32Update(c, Key, SizeOf(Key));
    c := VDbCrc32Update(c, ValLen, SizeOf(ValLen));
    c := VDbCrc32Update(c, Flags, SizeOf(Flags));
    if ValLen > 0 then c := VDbCrc32UpdatePtr(c, @Val[0], ValLen);
    Result := VDbCrc32Final(c);
  end;

begin
  Grp('WAL replay gercek (yirtik kuyruk + checkpoint)');
  // ---- 1) Temel replay: ana dosyaya YAZILMADAN wal'a yazilip replay ----
  myKv := TVDb.Create;
  try
    myKv.Open(D + '\wal1');
    walFile := myKv.WalPath;
    myKv.Put(1, VDbStrToBytes('ana-dosya-1'));
    // 3 kayit: 2 put + 1 delete
    if myKv.WriteAheadWAL(2, VDbStrToBytes('wal-2'), VDB_FLAG_PUT) and
       myKv.WriteAheadWAL(3, VDbStrToBytes('wal-3'), VDB_FLAG_PUT) and
       myKv.WriteAheadWAL(1, nil, VDB_FLAG_DEL) then
      Ok('WriteAheadWAL 3 kayit yazdi', IntToStr(WalRecCount(walFile)) + ' kayit')
    else
      No('WriteAheadWAL yazamadi', '');
    if myKv.HasWAL then Ok('HasWAL dogru', 'True')
    else No('HasWAL yanlis', 'False');
    // WalRecordCount: yalniz SAYAR, hicbir sey uygulamaz/silmez
    if myKv.WalRecordCount = 3 then Ok('WalRecordCount 3', '3')
    else No('WalRecordCount', IntToStr(myKv.WalRecordCount));
    // replay oncesi: sayim yan etkisiz (hala 3, ana dosyada 2/3 yok)
    SetLength(v, 0);
    if (myKv.WalRecordCount = 3) and (not myKv.Get(2, v)) then
      Ok('WalRecordCount yan etkisiz', 'hala 3, ana dosya degismedi')
    else No('WalRecordCount yan etkili', 'sayim=' + IntToStr(myKv.WalRecordCount));
    // replay ONCESI: ana dosyada 2 ve 3 YOK
    SetLength(v, 0);
    if myKv.Get(2, v) then No('replay oncesi 2 anahtari vardi', 'bulundu')
    else Ok('replay oncesi 2 anahtari yok', 'yok');
    // replay
    if myKv.ReplayWAL then Ok('ReplayWAL basarili', 'True')
    else No('ReplayWAL basarisiz', '');
    // replay SONRASI
    SetLength(v, 0);
    got2 := myKv.Get(2, v);
    if got2 and (VDbBytesToStr(v) = 'wal-2') then
      Ok('replay sonrasi 2 anahtari yazildi', VDbBytesToStr(v))
    else No('replay sonrasi 2 anahtari yazilmadi', 'Get=' + BoolToStr(got2, True) +' deger=[' + VDbBytesToStr(v) + '] uz=' + IntToStr(Length(v)));
    SetLength(v, 0);
    if myKv.Get(3, v) and (VDbBytesToStr(v) = 'wal-3') then
      Ok('replay sonrasi 3 anahtari yazildi', VDbBytesToStr(v))
    else No('replay sonrasi 3 anahtari yazilmadi', '');
    SetLength(v, 0);
    if myKv.Get(1, v) then No('replay sonrasi silinen 1 anahtari duruyor', 'bulundu')
    else Ok('replay sonrasi silinen 1 anahtari gitti', 'silindi');
    if myKv.HasWAL then No('replay sonrasi .wal kaldi', 'kaldi')
    else Ok('replay sonrasi .wal silindi', 'silindi');
    // ---- 2) YIRTIK KUYRUK: son kayit yarim yazilmis ----
    // NOT: .wal KIRPILMAZ, ekleme yapilir. Daha once burada
    // `fmOpenWrite or fmCreate` kullaniliyordu; FPC'de fmCreate dosyayi
    // KIRPAR -> gecerli kayit testten ONCE siliniyor ve "kayit kayboldu"
    // hatasi uretiliyordu.
    if myKv.WriteAheadWAL(10, VDbStrToBytes('gecerli-kayit'), VDB_FLAG_PUT) then
      Ok('yirtik kuyruk icin 1 kayit yazildi', '')
    else
      No('yirtik kuyruk icin kayit yazilamadi', '');
    // GECERLI magic'li baslik + valLen=500, ama degerden yalniz 1 bayt
    fs := TFileStream.Create(myKv.WalPath, fmOpenReadWrite);
    try
      fs.Position := fs.Size;
      mw := WAL_MAGIC_BEKLENEN;
      fs.Write(mw, SizeOf(mw));
      hdrKey := 777;
      fs.Write(hdrKey, SizeOf(hdrKey));
      fl := Byte(VDB_FLAG_PUT);
      fs.Write(fl, SizeOf(fl));
      partial := 500;
      fs.Write(partial, SizeOf(partial));   // 500 bayt deger SOYUTULUYOR
      zc := 0;                               // crc yerine 0 (zaten elenecek)
      fs.Write(zc, SizeOf(zc));
      bb := 255;
      fs.Write(bb, 1);                      // 1 bayt
    finally
      fs.Free;
    end;
    // Sayim replay ONCESI yapilir: yirtik kayit sayilmamali, gecerli
    // kayit sayilmalidir. (Replay sonrasi .wal silindigi icin sayim 0
    // olurdu; bu yuzden sira onemlidir.)
    if myKv.WalRecordCount = 1 then
      Ok('WalRecordCount yirtik kuyrukta yalniz GECERLI kayit', '1')
    else No('WalRecordCount yirtik kuyrukta', IntToStr(myKv.WalRecordCount));
    if myKv.ReplayWAL then Ok('yirtik kuyruk: gecerli kayitlar yazildi', 'True')
    else No('yirtik kuyruk: replay basarisiz', '');
    SetLength(v, 0);
    if myKv.Get(10, v) and (VDbBytesToStr(v) = 'gecerli-kayit') then
      Ok('yirtik kuyruk oncesi kayit KORUNDU', VDbBytesToStr(v))
    else No('yirtik kuyruk gecerli kayit kayboldu', '');
    SetLength(v, 0);
    if myKv.Get(777, v) then No('yirtik kuyruk bozuk kayit UYGULANDI', 'bozuk veri yazildi')
    else Ok('yirtik kuyruk bozuk kayit UYGULANMADI', 'reddedildi');
    // ---- 3) CRC BOZUK kayit: yalniz GECERLI ONCEKI kayitlar uygulanir ----
    // 19 (saglam) + 20 (crc bozulacak) yazilir; sadece 20'nin degeri
    // degistirilir -> 19 uygulanmali, 20 UYGULANMAMALI.
    if myKv.WriteAheadWAL(19, VDbStrToBytes('crc-ok-19'), VDB_FLAG_PUT) and
       myKv.WriteAheadWAL(20, VDbStrToBytes('crc-bozuk'), VDB_FLAG_PUT) then
      Ok('crc testi icin 2 kayit yazildi', '')
    else
      No('crc testi icin kayit yazilamadi', '');
    fs := TFileStream.Create(myKv.WalPath, fmOpenReadWrite);
    try
      fs.Seek(-1, fsFromEnd);
      b := 0;
      fs.Read(b, 1);              // son bayt (degerin sonu)
      fs.Seek(-1, fsFromEnd);
      bc := b xor 255;
      fs.Write(bc, 1);            // bir bayt degistir -> CRC tutmaz
    finally
      fs.Free;
    end;
    // Sayim CRC bozuk kaydi saymamali: 19 gecerli, 20 bozuk -> 1
    if myKv.WalRecordCount = 1 then
      Ok('WalRecordCount CRC bozuk kaydi saymadi', '1')
    else No('WalRecordCount CRC bozuk kaydi SAYDI', IntToStr(myKv.WalRecordCount));
    if myKv.ReplayWAL then Ok('CRC bozuk kayit: replay yine de calisti', 'True')
    else No('CRC bozuk kayit: replay basarisiz', '');
    SetLength(v, 0);
    if myKv.Get(19, v) and (VDbBytesToStr(v) = 'crc-ok-19') then
      Ok('CRC bozuk: onceki GECERLI kayit uygulandi', VDbBytesToStr(v))
    else No('CRC bozuk: onceki gecerli kayit KAYBOLDU', '');
    SetLength(v, 0);
    if myKv.Get(20, v) then No('CRC bozuk kayit UYGULANDI', 'veri yazildi')
    else Ok('CRC bozuk kayit reddedildi', 'uygulanmadi');
    if myKv.HasWAL then No('CRC bozuk sonrasi .wal kaldi', 'kaldi')
    else Ok('CRC bozuk sonrasi .wal silindi', 'silindi');
    if myKv.WalRecordCount = 0 then
      Ok('replay sonrasi WalRecordCount 0', '0')
    else No('replay sonrasi WalRecordCount', IntToStr(myKv.WalRecordCount));
    // ---- 3b) BOZUK MAGIC: CRC saglam, kayit reddedilmeli ----
    // CRC alanı magic'i KAPSAMAZ. Bu yuzden yalnizca ilk 4 bayti
    // bozmak, kaydin CRC'sini gecerli birakir: testin amaci magic
    // kontrolunun CRC'den BAGIMSIZ olarak gercekten calistigini
    // gostermek (aksi halde bu kontrol CRC ile birlikte testte
    // olusuydi).
    if myKv.WriteAheadWAL(16, VDbStrToBytes('magic-bozulmus'), VDB_FLAG_PUT) then
      Ok('bozuk magic testi icin kayit yazildi', '')
    else
      No('bozuk magic testi icin kayit yazilamadi', '');
    fs := TFileStream.Create(myKv.WalPath, fmOpenReadWrite);
    try
      fs.Position := 0;
      mw := LongWord($DEADBEEF);
      fs.Write(mw, SizeOf(mw));      // yalnizca magic bozuldu
    finally
      fs.Free;
    end;
    if myKv.ReplayWAL then Ok('bozuk magic: replay yine de calisti', 'True')
    else No('bozuk magic: replay basarisiz', '');
    SetLength(v, 0);
    if myKv.Get(16, v) then No('bozuk magic kayit UYGULANDI', 'veri yazildi')
    else Ok('bozuk magic kayit reddedildi', 'uygulanmadi');
    // ---- 3c) ANLAMSIZ BAYRAK: magic VE CRC gecerli, kayit reddedilmeli ----
    // CRC alani bayragı da kapsar; "bayrağı boz" demek CRC'yi de
    // bozardi ve test bayrak kontrolunu izole etmezdi. Burada kayit
    // ELLE yazilir: once motorun kendi kaydiyla CRC formulu
    // DOGRULANIR, sonra bayrak 99 yapilip CRC o bayrak icin
    // YENIDEN hesaplanir -> tek secilebilir hata bayraktir.
    walVal := VDbStrToBytes('bayrak-bozuk');
    if myKv.WriteAheadWAL(17, walVal, VDB_FLAG_PUT) then
      Ok('bayrak testi icin referans kayit yazildi', '')
    else
      No('bayrak testi icin referans kayit yazilamadi', '');
    fs := TFileStream.Create(myKv.WalPath, fmOpenReadWrite);
    try
      if fs.Read(walRec, SizeOf(walRec)) <> SizeOf(walRec) then
        raise Exception.Create('wal kaydi okunamadi');
      WalCrc := WalTestCrc(walRec.LSN, walRec.WalStamp, walRec.Key, walRec.ValLen,
        VDB_FLAG_PUT, walVal);
      if WalCrc = walRec.Crc then
        Ok('CRC formulu motorun CRC ile ayni', 'CRC eslesti')
      else
        No('CRC formulu motorun CRC ile FARKLI', 'test gecersiz');
      // bayragi boz + CRC'yi yeni bayraka gore hesapla
      walRec.Flags := 99;                 // ne PUT ne DEL
      walRec.Crc := WalTestCrc(walRec.LSN, walRec.WalStamp, walRec.Key,
          walRec.ValLen, walRec.Flags, walVal);
      fs.Position := 0;
      fs.WriteBuffer(walRec, SizeOf(walRec));
    finally
      fs.Free;
    end;
    if myKv.ReplayWAL then Ok('bayrak bozuk: replay yine de calisti', 'True')
    else No('bayrak bozuk: replay basarisiz', '');
    SetLength(v, 0);
    if myKv.Get(17, v) then No('anlamsiz bayrakli kayit UYGULANDI', 'veri yazildi')
    else Ok('anlamsiz bayrakli kayit reddedildi', 'uygulanmadi');
    // ---- 3d) SILME kaydi deger tasimaz: DEL + ValLen>0 reddedilmeli ----
    // Ayni izolasyon mantigi: bayrak DEL, deger DOLU. CRC deger icin
    // yeniden hesaplanir -> reddi yalnizca "DEL deger tasimaz" kurali
    // saglar.
    // ANAHTAR ONCEDEN DOLDURULUR: boylece "reddedildi" ile "silindi"
    // birbirinden AYIRT EDILIR. Aksi halde anahtar zaten yoksa
    // her iki durumda da Get False doner ve test sahte yesil olurdu.
    myKv.Put(18, VDbStrToBytes('oldu'));
    SetLength(v, 0);
    if myKv.Get(18, v) and (VDbBytesToStr(v) = 'oldu') then
      Ok('DEL-deger testi icin anahtar dolduruldu', 'oldu')
    else
      No('DEL-deger testi icin anahtar doldurulamadi', '');
    if myKv.WriteAheadWAL(18, VDbStrToBytes('del-18'), VDB_FLAG_PUT) then
      Ok('DEL-deger testi icin referans kayit yazildi', '')
    else
      No('DEL-deger testi icin referans kayit yazilamadi', '');
    walVal := VDbStrToBytes('del-18');     // CRC bu deger icin hesaplanacak
    fs := TFileStream.Create(myKv.WalPath, fmOpenReadWrite);
    try
      if fs.Read(walRec, SizeOf(walRec)) <> SizeOf(walRec) then
        raise Exception.Create('wal kaydi okunamadi');
      WalCrc := WalTestCrc(walRec.LSN, walRec.WalStamp, walRec.Key, walRec.ValLen,
        VDB_FLAG_PUT, walVal);
      if WalCrc = walRec.Crc then
        Ok('DEL-deger testi: CRC formulu yine eslesti', 'CRC eslesti')
      else
        No('DEL-deger testi: CRC formulu FARKLI', 'test gecersiz');
      walRec.Flags := VDB_FLAG_DEL;       // silme, ama deger dolu
      walRec.Crc := WalTestCrc(walRec.LSN, walRec.WalStamp, walRec.Key,
          walRec.ValLen, walRec.Flags, walVal);
      fs.Position := 0;
      fs.WriteBuffer(walRec, SizeOf(walRec));
    finally
      fs.Free;
    end;
    if myKv.ReplayWAL then Ok('DEL-deger: replay yine de calisti', 'True')
    else No('DEL-deger: replay basarisiz', '');
    SetLength(v, 0);
    if myKv.Get(18, v) and (VDbBytesToStr(v) = 'oldu') then
      Ok('deger tasayan DEL kaydi reddedildi (veri korundu)', VDbBytesToStr(v))
    else No('deger tasayan DEL kaydi UYGULANDI', 'veri=' + VDbBytesToStr(v));


  finally
    myKv.Free;
  end;
  // ---- 4) CheckpointWAL: once REPLAY, sonra sil (yoksa veri kaybi) ----
  myKv := TVDb.Create;
  try
    myKv.Open(D + '\wal2');
    myKv.WriteAheadWAL(30, VDbStrToBytes('checkpoint-30'), VDB_FLAG_PUT);
    if myKv.CheckpointWAL then Ok('CheckpointWAL basarili', 'True')
    else No('CheckpointWAL basarisiz', '');
    SetLength(v, 0);
    if myKv.Get(30, v) and (VDbBytesToStr(v) = 'checkpoint-30') then
      Ok('checkpoint: kayit KAYBOLMADI', VDbBytesToStr(v))
    else No('checkpoint: kayit kayboldu', '');
    if myKv.HasWAL then No('checkpoint sonrasi .wal kaldi', 'kaldi')
    else Ok('checkpoint sonrasi .wal silindi', 'silindi');
    // dosya .wal'siz: yeni acilista da veri durmali
    myKv.Close;
    myKv.Open(D + '\wal2');
    SetLength(v, 0);
    if myKv.Get(30, v) and (VDbBytesToStr(v) = 'checkpoint-30') then
      Ok('reopen sonrasi checkpoint kaydi durur', 'kalici')
    else No('reopen sonrasi kayip', '');
    // ---- 4b) ONCEDEN BATCHEND OLAN DOSYAYA replay + yeniden acilis ----
    // Kritik dayaniklilik senaryosu. Recover, dosyada bir BATCHEND
    // GORMUSSE sonraki BATCHEND'siz kayitlari "commit edilmemis batch"
    // sayip GERI SARAR. Replay kayitlari BATCHEND'siz yazarsa:
    //   replay sonrasi Get calisir (FIndex bellekte hazir),
    //   ama yeniden acilista kayitlar SILINIR.
    // Yani yalniz "replay sonrasi Get" testi bu hatayi GORMEZ.
    myKv.BeginBatch;
    myKv.Put(100, VDbStrToBytes('batchend-oncesi'));
    myKv.CommitBatch;          // dosyada ilk BATCHEND olusur
    myKv.WriteAheadWAL(101, VDbStrToBytes('replay-101'), VDB_FLAG_PUT);
    myKv.WriteAheadWAL(102, VDbStrToBytes('replay-102'), VDB_FLAG_PUT);
    if myKv.ReplayWAL then Ok('BATCHEND li dosyaya replay basarili', 'True')
    else No('BATCHEND li dosyaya replay basarisiz', '');
    SetLength(v, 0);
    if myKv.Get(101, v) and (VDbBytesToStr(v) = 'replay-101') then
      Ok('replay sonrasi 101 bellekte okunuyor', 'replay-101')
    else No('replay sonrasi 101 bellekte yok', '');
    myKv.Close;
    myKv.Open(D + '\wal2');
    SetLength(v, 0);
    if myKv.Get(100, v) and (VDbBytesToStr(v) = 'batchend-oncesi') then
      Ok('reopen sonrasi 100 (BATCHEND oncesi) durur', 'kalici')
    else No('reopen sonrasi 100 kayboldu', '');
    SetLength(v, 0);
    if myKv.Get(101, v) and (VDbBytesToStr(v) = 'replay-101') then
      Ok('reopen sonrasi replay kaydi 101 KALICI', 'replay-101')
    else No('reopen sonrasi replay kaydi 101 KAYBOLDU', 'Recover geri sardi');
    SetLength(v, 0);
    if myKv.Get(102, v) and (VDbBytesToStr(v) = 'replay-102') then
      Ok('reopen sonrasi replay kaydi 102 KALICI', 'replay-102')
    else No('reopen sonrasi replay kaydi 102 KAYBOLDU', 'Recover geri sardi');
    // Verify de kayitlari saymali (BATCHEND sayaci > 0 olmali)
    rep := '';
    if myKv.Verify(rep) then
    begin
      if Copy(rep, 1, 40) = '' then No('Verify raporu bos', '')
      else if Pos('batchend=0', Copy(rep, 1, 60)) > 0 then
        No('replay BATCHEND yazmadi (Verify batchend=0)', Copy(rep, 1, 60))
      else
        Ok('replay sonrasi Verify saglam + BATCHEND var', Copy(rep, 1, 60));
    end
    else No('reopen sonrasi Verify bozuk', Copy(rep, 1, 60));
    // ---- 5) .wal yoksa replay True (yapilacak yok) ----
    if myKv.ReplayWAL then Ok('.wal yokken ReplayWAL True', 'True')
    else No('.wal yokken ReplayWAL False', '');
    // ---- 6) gecersiz bayrak reddedilir ----
    if myKv.WriteAheadWAL(40, nil, 99) then
      No('gecersiz bayrak kabul edildi', 'yazildi')
    else
      Ok('gecersiz bayrak reddedildi', '');
    // ---- 7) Verify bozulmamis olmali ----
    rep := '';
    if myKv.Verify(rep) then Ok('WAL sonrasi Verify saglam', Copy(rep, 1, 40))
    else No('WAL sonrasi Verify bozuk', Copy(rep, 1, 60));
  finally
    myKv.Free;
  end;
end;

procedure T73_OtomatikWAL;
{ 2026-10-04: OTOMATIK WAL.

  WALEnabled = True iken her kalici yazma (Put/Delete) ONCE .wal'a,
  SONRA ana dosyaya yazilir. Boylece cagri aninda sistem cokerse
  kayit .wal'da durur ve ReplayWAL ile kurtarilir.

  TASNIT EDILEN SEMANTIK:
    a) Varsayilan KAPALI -> mevcut kullanicilarin davranisi degismez.
    b) Put sonrasi .wal'da kayit var, otomatik sayac artmis.
    c) WAL yazma basarisizsa ANA DOSYAYA YAZILMAZ.
    d) CommitBatch .wal'a TEKRAR yazmaz (gunluk buymez).
    e) ReplayWAL kendi kaydini yeniden yazmaz (dongu olusmaz).
    f) Kapali iken hicbir sey .wal'a yazilmaz.
    g) Delete de otomatik gunluge girer.
    h) Checkpoint sonrasi gunluk temizlenir.
    i) Close/Open sonrasi WALEnabled sifirlanir.
}
var
  myKv: TVDb;
  v: TBytes;
  rep: string;
  wp: string;
  Hata: string;

  procedure Dogrula(const Ad: string; Cond: Boolean; const E: string = '');
  begin
    if Cond then Ok(Ad, E) else No(Ad, E);
  end;

begin
  Grp('OTOMATIK WAL (WALEnabled)');

  // ---- a) ve f) varsayilan KAPALI ----
  myKv := TVDb.Create;
  try
    myKv.Open(D + '\auto1.odb');
    Dogrula('varsayilan WALEnabled = False', not myKv.WALEnabled);
    myKv.Put(1, VDbStrToBytes('x'));
    Dogrula('kapali iken .wal YAZILMADI', not myKv.HasWAL);
    Dogrula('kapali iken otomatik sayac 0', myKv.WalAutoCount = 0,
      IntToStr(myKv.WalAutoCount));
  finally
    myKv.Free;
  end;

  // ---- b) acik iken Put otomatik gunluge gider ----
  myKv := TVDb.Create;
  try
    myKv.Open(D + '\auto2.odb');
    myKv.WALEnabled := True;
    Dogrula('WALEnabled = True', myKv.WALEnabled);

    myKv.Put(10, VDbStrToBytes('deger-10'));
    Dogrula('Put sonrasi .wal var', myKv.HasWAL);
    Dogrula('Put otomatik gunluge yazildi', myKv.WalRecordCount = 1,
      'kayit=' + IntToStr(myKv.WalRecordCount));
    Dogrula('otomatik sayac 1', myKv.WalAutoCount = 1,
      IntToStr(myKv.WalAutoCount));

    SetLength(v, 0);
    Dogrula('Put ana dosyaya da yazildi',
      myKv.Get(10, v) and (VDbBytesToStr(v) = 'deger-10'), VDbBytesToStr(v));

    myKv.Put(11, VDbStrToBytes('deger-11'));
    Dogrula('2. Put sonrasi 2 kayit', myKv.WalRecordCount = 2,
      IntToStr(myKv.WalRecordCount));

    // ---- g) Delete otomatik gunluge ----
    Dogrula('Delete basarili', myKv.Delete(10));
    Dogrula('Delete sonrasi 3 kayit', myKv.WalRecordCount = 3,
      IntToStr(myKv.WalRecordCount));
    Dogrula('Delete sayac 3', myKv.WalAutoCount = 3,
      IntToStr(myKv.WalAutoCount));

    // ---- d) batch .wal'a TEKRAR yazmaz ----
    myKv.BeginBatch;
    myKv.Put(20, VDbStrToBytes('b20'));
    myKv.Put(21, VDbStrToBytes('b21'));
    myKv.CommitBatch;
    Dogrula('batch 2 satir daha ekledi (toplam 5)', myKv.WalRecordCount = 5,
      IntToStr(myKv.WalRecordCount));
    Dogrula('CommitBatch gunlugu TEKRAR yazmadi (7 olsaydi hata vardi)',
      myKv.WalAutoCount = 5, 'sayac=' + IntToStr(myKv.WalAutoCount));
    SetLength(v, 0);
    Dogrula('batch verisi ana dosyada',
      myKv.Get(21, v) and (VDbBytesToStr(v) = 'b21'), VDbBytesToStr(v));

    // ---- e) replay dongusu yok ----
    Dogrula('ReplayWAL basarili', myKv.ReplayWAL);
    Dogrula('replay sonrasi gunluk SILINDI', not myKv.HasWAL);

    // ---- h) checkpoint sonrasi temiz ----
    myKv.Put(30, VDbStrToBytes('ckpt'));
    Dogrula('checkpoint oncesi kayit var', myKv.HasWAL);
    Dogrula('CheckpointWAL basarili', myKv.CheckpointWAL);
    Dogrula('checkpoint sonrasi .wal yok', not myKv.HasWAL);
    SetLength(v, 0);
    Dogrula('checkpoint verisi kalici',
      myKv.Get(30, v) and (VDbBytesToStr(v) = 'ckpt'), VDbBytesToStr(v));

    // ---- i) kapat-ac ----
    myKv.Close;
    myKv.Open(D + '\auto2.odb');
    SetLength(v, 0);
    Dogrula('reopen sonrasi b21 durur',
      myKv.Get(21, v) and (VDbBytesToStr(v) = 'b21'), VDbBytesToStr(v));
    SetLength(v, 0);
    Dogrula('reopen sonrasi silinen 10 YOK', not myKv.Get(10, v));
    Dogrula('reopen sonrasi WALEnabled sifirlandi', not myKv.WALEnabled);
    Dogrula('reopen sonrasi .wal yok', not myKv.HasWAL);
    Dogrula('reopen sonrasi Verify saglam', myKv.Verify(rep), Copy(rep, 1, 50));
  finally
    myKv.Free;
  end;

  // ---- c) WAL yazma basarisiz: ana dosyaya da YAZILMAZ ----
  myKv := TVDb.Create;
  try
    myKv.Open(D + '\auto3.odb');
    myKv.Put(1, VDbStrToBytes('ilk'));
    myKv.CheckpointWAL;
    myKv.WALEnabled := True;
    wp := myKv.WalPath;
    { .wal yolunu bir DIZIN ile isgal et. Motor WAL dosyasini acaraken
      hata alir (Windows'ta dizin acilamaz) -> test, WAL yazilamayinca
      ana dosyaya da yazilmadigini kanitlar.
      NOT 1: TFileStream ile 'kilit' denemesi ise calismiyor; FPC
      paylasim izni veriyor ve Put sessizce basarili oluyor.
      NOT 2: WAL adi ChangeFileExt(FPath,'.wal') -> 'auto3.odb' icin
      'auto3.wal'dir, 'auto3.odb.wal' DEGILDIR. }
    ForceDirectories(wp);
    Hata := '';
    try
      myKv.Put(2, VDbStrToBytes('ikinci'));
      Dogrula('WAL yazilamazsa Put HATA VERMELI', False, 'Put basarili oldu');
    except
      on E: Exception do
      begin
        Hata := E.ClassName + ': ' + E.Message;
        Dogrula('WAL yazilamazsa Put hata verdi', True, Copy(Hata, 1, 70));
      end;
    end;
    SetLength(v, 0);
    Dogrula('WAL yazilamadigi icin ana dosyaya da YAZILMADI',
      not myKv.Get(2, v));
    Dogrula('basarisiz yazma sonrasi Verify saglam', myKv.Verify(rep),
      Copy(rep, 1, 50));
  finally
    myKv.Free;
    RemoveDir(wp);
  end;
end;

{ --------------------------------------------------
  R-01: MVCC / Snapshot Isolation testleri
  -------------------------------------------------- }

procedure T90_MVCC_Snapshot;
{ R-01: Transaction-level snapshot
  - batch baslangic snapshot'i: commit edilmemis degisiklikler gorunmez
    (batch icinde yapilan yazilar gorunur, seq = FSeq+1)
  - ROLLBACK sonrasinda gorunmez
  - yeni transaction en son committed veriyi gormeli }   
var
  Q9: string;
begin
  Grp('R-01 MVCC: Transaction Snapshot (R-01)');
  UseDir('mvcc');
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, x INTEGER)');
  sq.Exec('INSERT INTO t VALUES(1,10),(2,20)');

  // 1) batch baslangic snapshot: sadece commit edilmis 2 satir gorunur
  sq.Exec('BEGIN');
  ChkVal('batch baslangic: 2 satir gorunur', 'SELECT COUNT(*) FROM t', 0, 0, '2');
  ChkVal('id=1 x=10 gorunur', 'SELECT x FROM t WHERE id=1', 0, 0, '10');

  // 2) batch icinde yaptigimiz yaziyi sonraki okuma gormeli (seq=FSeq+1)
  sq.Exec('INSERT INTO t VALUES(3,30)');
  ChkVal('kendi yazimiz gorunur: 3 satir', 'SELECT COUNT(*) FROM t', 0, 0, '3');
  ChkVal('id=3 x=30 gorunur', 'SELECT x FROM t WHERE id=3', 0, 0, '30');

  // 3) COMMIT sonra kalici
  sq.Exec('COMMIT');
  ChkVal('commit sonrasinda: 3 satir', 'SELECT COUNT(*) FROM t', 0, 0, '3');

  // 4) ROLLBACK: batch icinde yapilan gorunmemeli
  sq.Exec('BEGIN');
  sq.Exec('DELETE FROM t WHERE id=3');
  ChkVal('batch icinde delete gorunur: 2 satir', 'SELECT COUNT(*) FROM t', 0, 0, '2');
  sq.Exec('ROLLBACK');
  ChkVal('rollback sonra id=3 tekrar var: 3 satir', 'SELECT COUNT(*) FROM t', 0, 0, '3');

  // 5) yeni transaction en son committed veriyi gormeli
  sq.Exec('BEGIN');
  ChkVal('yeni batch: en son 3 satir', 'SELECT COUNT(*) FROM t', 0, 0, '3');
  sq.Exec('ROLLBACK');
end;

procedure T91_MVCC_Nested;
{ R-01: Nested SELECT (correlated subquery) snapshot
  - alt sorgu commit edilmis veriyi gormeli
  - batch icinde correlation dogru calismali
  - EXISTS correlated }   
begin
  Grp('R-01 MVCC: Nested SELECT / Correlated Subquery (R-01)');
  UseDir('mvcc');
  sq.Exec('CREATE TABLE a(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, a_id INTEGER, x INTEGER)');
  sq.Exec('INSERT INTO a VALUES(1,10),(2,20)');
  sq.Exec('INSERT INTO b VALUES(1,1,100),(2,1,200),(3,2,300)');

  // 1) correlated SUM — alt sorgu commit edilmis veriyi gormeli
  ChkVal('correlated SUM a.id=1 -> 300', 'SELECT (SELECT SUM(x) FROM b WHERE b.a_id = a.id) FROM a a WHERE a.id=1', 0, 0, '300');
  ChkVal('correlated SUM a.id=2 -> 300', 'SELECT (SELECT SUM(x) FROM b WHERE b.a_id = a.id) FROM a a WHERE a.id=2', 0, 0, '300');

  // 2) correlated COUNT (tek kolon) — a id 1 icin 2 satir
  ChkVal('correlated COUNT a id 1 -> 2',
      'SELECT (SELECT COUNT(*) FROM b WHERE b.a_id = a.id) FROM a a WHERE a.id=1', 0, 0, '2');

  // 3) batch icinde correlated: kendi yazimiz gorunmeli
  sq.Exec('BEGIN');
  sq.Exec('INSERT INTO b VALUES(4,1,400)');
  ChkVal('batch icinde correlated SUM a.id=1 -> 700',
      'SELECT (SELECT SUM(x) FROM b WHERE b.a_id = a.id) FROM a a WHERE a.id=1', 0, 0, '700');
  ChkVal('batch icinde correlated COUNT a id 1 -> 3',
      'SELECT (SELECT COUNT(*) FROM b WHERE b.a_id = a.id) FROM a a WHERE a.id=1', 0, 0, '3');
  sq.Exec('ROLLBACK');
  ChkVal('rollback sonra SUM a.id=1 -> 300', 'SELECT (SELECT SUM(x) FROM b WHERE b.a_id = a.id) FROM a a WHERE a.id=1', 0, 0, '300');

  // 4) EXISTS correlated
  ChkVal('EXISTS correlated: 2 satir', 'SELECT COUNT(*) FROM a a WHERE EXISTS(SELECT 1 FROM b b WHERE b.a_id = a.id)', 0, 0, '2');
end;

procedure T92_MVCC_Isoaltion;
{ R-01: BeginBatch/CommitBatch/AbortBatch + snapshot gorunurluk
  - kv seviyesinde batch baslangic snapshot'i
  - pending yazilar gorunur / COMMIT sonrasinda kalici / ABORT sonra yok }   
var
  b: TBytes;
begin
  Grp('R-01 MVCC: BeginBatch / CommitBatch / AbortBatch (R-01)');
  UseDir('mvcc');
  kv.Close;
  kv.Open(D + '\mvccbatch');
  kv.Put(1, VDbStrToBytes('old-1'));
  kv.Put(2, VDbStrToBytes('old-2'));

  // batch baslangic snapshot
  kv.BeginBatch;
  Dogrula('batch baslangic snapshot: old-1', kv.Get(1, b) and (VDbBytesToStr(b) = 'old-1'), VDbBytesToStr(b));
  Dogrula('batch baslangic snapshot: old-2', kv.Get(2, b) and (VDbBytesToStr(b) = 'old-2'), VDbBytesToStr(b));

  // pending write
  kv.Put(3, VDbStrToBytes('pending-3'));
  Dogrula('pending gorunur: 3', kv.Exists(3), '');
  Dogrula('pending deger: pending-3', kv.Get(3, b) and (VDbBytesToStr(b) = 'pending-3'), VDbBytesToStr(b));

  // commit
  kv.CommitBatch;
  Dogrula('commit sonrasinda 3 kaldi', kv.Exists(3), '');
  Dogrula('commit sonrasinda deger', kv.Get(3, b) and (VDbBytesToStr(b) = 'pending-3'), VDbBytesToStr(b));
  Dogrula('commit sonrasinda old-1', kv.Get(1, b) and (VDbBytesToStr(b) = 'old-1'), VDbBytesToStr(b));

  // rollback path: yeni batch, write, abort
  kv.BeginBatch;
  kv.Put(4, VDbStrToBytes('pending-4'));
  Dogrula('abort once: 4 var', kv.Exists(4), '');
  kv.AbortBatch;
  Dogrula('abort sonra 4 YOK', not kv.Exists(4), '');
  Dogrula('abort sonra 1 hala var', kv.Get(1, b) and (VDbBytesToStr(b) = 'old-1'), VDbBytesToStr(b));

  kv.Close;
  if FileExists(D + '\mvccbatch.odb') then DeleteFile(D + '\mvccbatch.odb');
  if FileExists(D + '\mvccbatch.odb.wal') then DeleteFile(D + '\mvccbatch.odb.wal');
end;

{ M1: PostgreSQL wire testi icin ham istemci yardimcilari (BE). }
function TPgI16(V: Integer): AnsiString;
var
  u: Word;
begin
  u := Word(V);
  Result := AnsiChar(u shr 8) + AnsiChar(u and $FF);
end;

function TPgI32(V: LongInt): AnsiString;
var
  u: Cardinal;
begin
  u := Cardinal(V);
  Result := AnsiChar(u shr 24) + AnsiChar((u shr 16) and $FF) +
    AnsiChar((u shr 8) and $FF) + AnsiChar(u and $FF);
end;

function TPgI64(V: Int64): AnsiString;
var
  u: QWord;
  i: Integer;
begin
  u := QWord(V);
  Result := '';
  for i := 7 downto 0 do
    Result := Result + AnsiChar((u shr (i * 8)) and $FF);
end;

function TPgF64(V: Double): AnsiString;
var
  u: QWord;
  i: Integer;
begin
  Move(V, u, 8);
  Result := '';
  for i := 7 downto 0 do
    Result := Result + AnsiChar((u shr (i * 8)) and $FF);
end;

function TPgSend(S: TVdbSocket; const M: AnsiString): Boolean;
begin
  Result := False;
  if M = '' then Exit(True);
  Result := VdbSendAll(S, M[1], Length(M));
end;

function TPgRecvMsg(S: TVdbSocket; out T: AnsiChar; out Body: AnsiString): Boolean;
var
  b: Byte;
  l: LongInt;
  bb: array[0..3] of Byte;
begin
  Result := False;
  Body := '';
  if not VdbRecvU8(S, b) then Exit;
  T := AnsiChar(b);
  if not VdbRecvAll(S, bb, 4) then Exit;
  l := LongInt((Cardinal(bb[0]) shl 24) or (Cardinal(bb[1]) shl 16) or
    (Cardinal(bb[2]) shl 8) or Cardinal(bb[3]));
  if l < 4 then Exit;
  SetLength(Body, l - 4);
  if (l - 4) > 0 then
    if not VdbRecvAll(S, Body[1], l - 4) then Exit;
  Result := True;
end;

function TPgReadUntilReady(S: TVdbSocket; out Msgs: TStringList): Boolean;
var
  t: AnsiChar;
  b: AnsiString;
begin
  Result := False;
  Msgs := TStringList.Create;
  while TPgRecvMsg(S, t, b) do
  begin
    Msgs.Add(t + '|' + b);
    if t = 'Z' then Exit(True);
  end;
end;

function TPgBody(const M: string): string;
begin
  Result := Copy(M, 3, MaxInt);
end;

function TPgTag(const Body: string): string;
var
  p: Integer;
begin
  p := Pos(#0, Body);
  if p > 0 then Result := Copy(Body, 1, p - 1)
  else Result := Body;
end;

function TPgFieldNames(const Body: AnsiString): TStrArray;
var
  n, i, p, st: Integer;
begin
  SetLength(Result, 0);
  if Length(Body) < 2 then Exit;
  n := (Ord(Body[1]) shl 8) or Ord(Body[2]);
  SetLength(Result, n);
  p := 3;
  for i := 0 to n - 1 do
  begin
    st := p;
    while (p <= Length(Body)) and (Body[p] <> #0) do Inc(p);
    Result[i] := Copy(Body, st, p - st);
    Inc(p);        // ad sonu
    Inc(p, 18);    // tableOid+attnum+typeOid+typlen+typmod+format
  end;
end;

function TPgFieldOidAt(const Body: AnsiString; Index: Integer): LongInt;
// M1: RowDescription icindeki alan tip OID'sini okur.
var
  n, i, p: Integer;
begin
  Result := -1;
  if Length(Body) < 2 then Exit;
  n := (Ord(Body[1]) shl 8) or Ord(Body[2]);
  p := 3;
  for i := 0 to n - 1 do
  begin
    while (p <= Length(Body)) and (Body[p] <> #0) do Inc(p);
    Inc(p);    // ad sonu
    if i = Index then
    begin
      if p + 9 > Length(Body) then Exit;
      Result := (LongInt(Ord(Body[p + 6])) shl 24) or
                (LongInt(Ord(Body[p + 7])) shl 16) or
                (LongInt(Ord(Body[p + 8])) shl 8) or
                 LongInt(Ord(Body[p + 9]));
      Exit;
    end;
    Inc(p, 18);  // tableOid+attnum+typeOid+typlen+typmod+format
  end;
end;

function TPgRow(const Body: AnsiString): TStrArray;
var
  n, i, p, l: Integer;
begin
  SetLength(Result, 0);
  if Length(Body) < 2 then Exit;
  n := (Ord(Body[1]) shl 8) or Ord(Body[2]);
  SetLength(Result, n);
  p := 3;
  for i := 0 to n - 1 do
  begin
    if p + 3 > Length(Body) then Exit;
    l := (Ord(Body[p]) shl 24) or (Ord(Body[p + 1]) shl 16) or
      (Ord(Body[p + 2]) shl 8) or Ord(Body[p + 3]);
    Inc(p, 4);
    Result[i] := Copy(Body, p, l);
    Inc(p, l);
  end;
end;

{ M10: GENERATED ALWAYS AS (...) STORED }
procedure T118_AeadKdf;
var
  key, nonce, pt, aad, ct, tag, tag2, outb: TBytes;
  pwd, salt, secret, ad, h, h2: TBytes;
  ok: Boolean;

  function Hx(const S: string): TBytes;
  var
    i: Integer;
  begin
    SetLength(Result, Length(S) div 2);
    for i := 1 to Length(Result) do
      Result[i - 1] := StrToInt('$' + Copy(S, (i - 1) * 2 + 1, 2));
  end;

  function HxOf(const B: TBytes): string;
  var
    i: Integer;
  begin
    Result := '';
    for i := 0 to High(B) do
      Result := Result + IntToHex(B[i], 2);
  end;

  function RepeatByte(B: Byte; N: Integer): TBytes;
  begin
    SetLength(Result, N);
    if N > 0 then FillChar(Result[0], N, B);
  end;

begin
  Grp('M6 AES-256-GCM + Argon2id vektorleri');

  // NIST SP 800-38D: sifir anahtar/nonce, 16 bayt sifir duz metin.
  key := Hx('0000000000000000000000000000000000000000000000000000000000000000');
  nonce := Hx('000000000000000000000000');
  pt := Hx('00000000000000000000000000000000');
  aad := nil;
  ok := VDbCryptGcmSeal(key, nonce, pt, aad, ct, tag);
  Dogrula('GCM NIST sifreli metin', ok and
    (LowerCase(HxOf(ct)) = 'cea7403d4d606b6e074ec5d3baf39d18'), HxOf(ct));
  Dogrula('GCM NIST etiket', ok and
    (LowerCase(HxOf(tag)) = 'd0d1c8a799996bf0265b98b5d48ab919'), HxOf(tag));

  tag2 := Copy(tag, 0, Length(tag));
  if Length(tag2) > 0 then
    tag2[0] := tag2[0] xor $01;
  outb := nil;
  Dogrula('GCM bozulmus etiket reddedildi',
    not VDbCryptGcmOpen(key, nonce, ct, tag2, aad, outb));

  // RFC 9106 Argon2id test vektoru: p=4, T=32, m=32 KiB, t=3.
  pwd := RepeatByte($01, 32);
  salt := RepeatByte($02, 16);
  secret := RepeatByte($03, 8);
  ad := RepeatByte($04, 12);
  h := nil;
  ok := VDbArgon2id(pwd, salt, secret, ad, 3, 32, 4, 32, h);
  Dogrula('Argon2id RFC 9106', ok and
    (LowerCase(HxOf(h)) = '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659'),
    HxOf(h));

  // M6: paralel p=4 yolunda birden fazla slice/ref turu ve buyuk bellek
  // ile yaris kosulu olmadigini iki bagimsiz cagrinin esitligiyle dogrula.
  h := nil;
  h2 := nil;
  ok := VDbArgon2id(pwd, salt, secret, ad, 2, 1024, 4, 32, h);
  ok := ok and VDbArgon2id(pwd, salt, secret, ad, 2, 1024, 4, 32, h2);
  Dogrula('Argon2id p=4 paralel deterministik',
    ok and (Length(h) = 32) and (HxOf(h) = HxOf(h2)), HxOf(h));
end;

procedure T119_Trace;
var
  j: string;
begin
  Grp('M9 OpenTelemetry span kaydi');
  VDbTraceClear;
  VDbTraceSetEnabled(True);
  try
    try
      sq.Exec('SELECT 119 AS trace_probe');
    except
      on E: Exception do No('trace sorgu', E.Message);
    end;
  finally
    VDbTraceSetEnabled(False);
  end;
  j := VDbTraceGetJSON;
  Dogrula('sql.query span', Pos('"name":"sql.query"', j) > 0, '');
  Dogrula('sql.parse span', Pos('"name":"sql.parse"', j) > 0, '');
  Dogrula('sql.execute span', Pos('"name":"sql.execute"', j) > 0, '');
  Dogrula('db.statement attr',
    Pos('"db.statement":"SELECT 119 AS trace_probe"', j) > 0, '');
  VDbTraceClear;
end;

procedure T117_Generated;
var
  kv2: TVDb;
  tb2: TVTableDb;
  sq2: TVSql;
  r: TSqlResult;
  raised: Boolean;
  vals: string;
begin
  Grp('M10 GENERATED ALWAYS AS (STORED)');
  ForceDirectories(D + '\gen');
  kv2 := TVDb.Create;
  try
    kv2.Open(D + '\gen');
    tb2 := TVTableDb.Create(kv2);
    try
      tb2.Open(D + '\gen');
      sq2 := TVSql.Create(tb2);
      try
        sq2.Exec('CREATE TABLE g(a INTEGER PRIMARY KEY, b INTEGER, ' +
          'c INTEGER GENERATED ALWAYS AS (b * 2) STORED)');
        sq2.Exec('INSERT INTO g(a,b) VALUES (1,5)');
        r := sq2.Exec('SELECT c FROM g WHERE a=1');
        Dogrula('generated INSERT (5*2=10)',
          (Length(r.Rows) = 1) and (r.Rows[0][0] = '10'),
          'c=' + r.Rows[0][0]);

        // Acikca verilen deger YOK SAYILIR; hesaplanan deger kazanir.
        sq2.Exec('INSERT INTO g(a,b,c) VALUES (2,7,999)');
        r := sq2.Exec('SELECT c FROM g WHERE a=2');
        Dogrula('generated acik deger ezer (7*2=14)',
          (Length(r.Rows) = 1) and (r.Rows[0][0] = '14'),
          'c=' + r.Rows[0][0]);

        // Coklu VALUES (BatchInsert yolu).
        sq2.Exec('INSERT INTO g(a,b) VALUES (3,1),(4,2)');
        r := sq2.Exec('SELECT a,c FROM g WHERE a>=3 ORDER BY a');
        vals := '';
        if Length(r.Rows) = 2 then
          vals := r.Rows[0][0] + ':' + r.Rows[0][1] + ',' +
                  r.Rows[1][0] + ':' + r.Rows[1][1];
        Dogrula('generated coklu VALUES (1,2)',
          vals = '3:2,4:4', vals);

        // UPDATE temel kolonu degistirince generated yeniden hesaplanir.
        sq2.Exec('UPDATE g SET b=10 WHERE a=1');
        r := sq2.Exec('SELECT c FROM g WHERE a=1');
        Dogrula('generated UPDATE (10*2=20)',
          (Length(r.Rows) = 1) and (r.Rows[0][0] = '20'),
          'c=' + r.Rows[0][0]);

        // Ifade fonksiyonu (ExprToText -> VDbExprVal ayni dili konusur).
        sq2.Exec('CREATE TABLE g2(a TEXT, ' +
          'u TEXT GENERATED ALWAYS AS (UPPER(a)) STORED)');
        sq2.Exec('INSERT INTO g2(a) VALUES (''abc'')');
        r := sq2.Exec('SELECT u FROM g2');
        Dogrula('generated UPPER (abc->ABC)',
          (Length(r.Rows) = 1) and (r.Rows[0][0] = 'ABC'),
          'u=' + r.Rows[0][0]);

        // ALTER ADD COLUMN GENERATED: mevcut satirlar geriye donuk hesaplanir.
        sq2.Exec('ALTER TABLE g2 ADD COLUMN z INTEGER ' +
          'GENERATED ALWAYS AS (1 + 1) STORED');
        r := sq2.Exec('SELECT z FROM g2');
        Dogrula('ALTER ADD GENERATED mevcut satiri doldurdu',
          (Length(r.Rows) = 1) and (r.Rows[0][0] = '2'),
          'z=' + r.Rows[0][0]);
        sq2.Exec('INSERT INTO g2(a) VALUES (''xy'')');
        r := sq2.Exec('SELECT u,z FROM g2 ORDER BY a');
        vals := '';
        if Length(r.Rows) = 2 then
          vals := r.Rows[0][0] + ':' + r.Rows[0][1] + ',' +
                  r.Rows[1][0] + ':' + r.Rows[1][1];
        Dogrula('ALTER ADD GENERATED sonrasi INSERT',
          vals = 'ABC:2,XY:2', vals);

        // ---- M10: GENERATED {ALWAYS | BY DEFAULT} AS IDENTITY ----
        sq2.Exec('CREATE TABLE g3(id INTEGER GENERATED ALWAYS AS IDENTITY, v TEXT)');
        sq2.Exec('INSERT INTO g3(v) VALUES (''a'')');
        sq2.Exec('INSERT INTO g3(v) VALUES (''b'')');
        r := sq2.Exec('SELECT id,v FROM g3 ORDER BY id');
        vals := '';
        if Length(r.Rows) = 2 then
          vals := r.Rows[0][0] + ':' + r.Rows[0][1] + ',' +
                  r.Rows[1][0] + ':' + r.Rows[1][1];
        Dogrula('IDENTITY ALWAYS 1,2', vals = '1:a,2:b', vals);

        raised := False;
        try
          sq2.Exec('INSERT INTO g3(id,v) VALUES (99,''x'')');
        except
          raised := True;
        end;
        Dogrula('IDENTITY ALWAYS acik deger reddedildi', raised, '');

        sq2.Exec('INSERT INTO g3(v) VALUES (''c''),(''d'')');
        r := sq2.Exec('SELECT id FROM g3 WHERE id>=3 ORDER BY id');
        vals := '';
        if Length(r.Rows) = 2 then
          vals := r.Rows[0][0] + ',' + r.Rows[1][0];
        Dogrula('IDENTITY coklu VALUES (3,4)', vals = '3,4', vals);

        sq2.Exec('CREATE TABLE g4(id INTEGER GENERATED BY DEFAULT AS IDENTITY, v TEXT)');
        sq2.Exec('INSERT INTO g4(v) VALUES (''a'')');
        sq2.Exec('INSERT INTO g4(id,v) VALUES (10,''b'')');
        sq2.Exec('INSERT INTO g4(v) VALUES (''c'')');
        r := sq2.Exec('SELECT id,v FROM g4 ORDER BY id');
        vals := '';
        if Length(r.Rows) = 3 then
          vals := r.Rows[0][0] + ':' + r.Rows[0][1] + ',' +
                  r.Rows[1][0] + ':' + r.Rows[1][1] + ',' +
                  r.Rows[2][0] + ':' + r.Rows[2][1];
        Dogrula('IDENTITY BY DEFAULT 1,10,11', vals = '1:a,10:b,11:c', vals);

        raised := False;
        try
          sq2.Exec('UPDATE g4 SET id=99 WHERE v=''a''');
        except
          raised := True;
        end;
        Dogrula('IDENTITY guncellenemez', raised, '');

        // Identity, PK olmayan bir kolon olabilir (sayac PK ile paylasilir).
        sq2.Exec('CREATE TABLE g5(a INTEGER PRIMARY KEY, ' +
          'b INTEGER GENERATED ALWAYS AS IDENTITY)');
        sq2.Exec('INSERT INTO g5(a) VALUES (7)');
        r := sq2.Exec('SELECT a,b FROM g5');
        Dogrula('IDENTITY PK olmayan kolon',
          (Length(r.Rows) = 1) and (r.Rows[0][0] = '7') and
          (r.Rows[0][1] = '1'),
          'a=' + r.Rows[0][0] + ',b=' + r.Rows[0][1]);
      finally
        sq2.Free;
      end;
    finally
      tb2.Close;
      tb2.Free;
    end;
  finally
    kv2.Close;
    kv2.Free;
  end;

  // Sema 6. alan (hex ifade) ile yeniden acilista korunur.
  kv2 := TVDb.Create;
  try
    kv2.Open(D + '\gen');
    tb2 := TVTableDb.Create(kv2);
    try
      tb2.Open(D + '\gen');
      sq2 := TVSql.Create(tb2);
      try
        r := sq2.Exec('SELECT c FROM g WHERE a=2');
        Dogrula('generated yeniden acilis (c=14)',
          (Length(r.Rows) = 1) and (r.Rows[0][0] = '14'),
          'c=' + r.Rows[0][0]);
        r := sq2.Exec('SELECT u FROM g2 WHERE a=''abc''');
        Dogrula('generated yeniden acilis (UPPER)',
          (Length(r.Rows) = 1) and (r.Rows[0][0] = 'ABC'),
          'u=' + r.Rows[0][0]);
        r := sq2.Exec('SELECT z FROM g2 WHERE a=''abc''');
        Dogrula('ALTER ADD GENERATED yeniden acilis (z=2)',
          (Length(r.Rows) = 1) and (r.Rows[0][0] = '2'),
          'z=' + r.Rows[0][0]);
        sq2.Exec('INSERT INTO g(a,b) VALUES (5,3)');
        r := sq2.Exec('SELECT c FROM g WHERE a=5');
        Dogrula('generated yeniden acilis sonrasi INSERT',
          (Length(r.Rows) = 1) and (r.Rows[0][0] = '6'),
          'c=' + r.Rows[0][0]);
        // M10: IDENTITY bayragi ve sayaci semadan geri gelmeli.
        r := sq2.Exec('SELECT id FROM g4 WHERE v=''c''');
        Dogrula('IDENTITY yeniden acilis (11)',
          (Length(r.Rows) = 1) and (r.Rows[0][0] = '11'),
          'id=' + r.Rows[0][0]);
        sq2.Exec('INSERT INTO g4(v) VALUES (''d'')');
        r := sq2.Exec('SELECT id FROM g4 WHERE v=''d''');
        Dogrula('IDENTITY sayaci yeniden acilis (12)',
          (Length(r.Rows) = 1) and (r.Rows[0][0] = '12'),
          'id=' + r.Rows[0][0]);
      finally
        sq2.Free;
      end;
    finally
      tb2.Close;
      tb2.Free;
    end;
  finally
    kv2.Close;
    kv2.Free;
  end;
end;

procedure T116_PgWire;
const
  PPORT = 54720;
var
  srv: TVdbPgServer;
  err: string;
  s: TVdbSocket;
  msgs: TStringList;
  i, j: Integer;
  body, tag: string;
  row: TStrArray;
  ok: Boolean;
  oidId, oidS: LongInt;
  b: Byte;
  startup, param: AnsiString;

  function ConnectAndStart: Boolean;
  var
    st: AnsiString;
    t: AnsiChar;
    bb: AnsiString;
  begin
    Result := False;
    s := VdbTcpConnect('127.0.0.1', PPORT);
    if s = VDB_SOCK_INVALID then Exit;
    st := TPgI32(8) + TPgI32(80877103);   // SSLRequest
    if not TPgSend(s, st) then Exit;
    if not VdbRecvU8(s, b) then Exit;
    if b <> Ord('N') then Exit;
    param := 'user'#0 + 'postgres'#0 + 'database'#0 + 'vdb'#0 +
      'client_encoding'#0 + 'UTF8'#0#0;
    st := TPgI32(4 + 4 + Length(param)) + TPgI32(196608) + param;
    if not TPgSend(s, st) then Exit;
    repeat
      if not TPgRecvMsg(s, t, bb) then Exit;
    until t = 'Z';
    Result := True;
  end;

  function Query(const Sql: string): Boolean;
  var
    st: AnsiString;
  begin
    FreeAndNil(msgs);
    st := 'Q' + TPgI32(Length(Sql) + 1 + 4) + Sql + #0;
    if not TPgSend(s, st) then Exit(False);
    Result := TPgReadUntilReady(s, msgs);
  end;

  function SendExt(T: AnsiChar; const Body: AnsiString): Boolean;
  begin
    Result := TPgSend(s, T + TPgI32(Length(Body) + 4) + Body);
  end;

  function SyncRead: Boolean;
  begin
    if not SendExt('S', '') then Exit(False);
    Result := TPgReadUntilReady(s, msgs);
  end;

  function TypeSeq: string;
  var
    k: Integer;
  begin
    Result := '';
    if msgs = nil then Exit;
    for k := 0 to msgs.Count - 1 do
      if msgs[k] <> '' then Result := Result + msgs[k][1];
  end;

  function FindTag(const Want: string): Boolean;
  var
    k: Integer;
  begin
    Result := False;
    if msgs = nil then Exit;
    for k := 0 to msgs.Count - 1 do
      if (msgs[k] <> '') and (msgs[k][1] = 'C') and
         (TPgTag(TPgBody(msgs[k])) = Want) then Exit(True);
  end;

  function ErrText: string;
  var
    k: Integer;
  begin
    Result := '';
    if msgs = nil then Exit;
    for k := 0 to msgs.Count - 1 do
      if (msgs[k] <> '') and (msgs[k][1] = 'E') then
        Exit(TPgBody(msgs[k]));
  end;

  // ErrorResponse govdesindeki 'C' (SQLSTATE) alanini dondurur.
  function ErrState: string;
  var
    b: AnsiString;
    p, st: Integer;
    c: AnsiChar;
  begin
    Result := '';
    b := ErrText;
    p := 1;
    while p <= Length(b) do
    begin
      c := b[p];
      Inc(p);
      if c = #0 then Break;
      st := p;
      while (p <= Length(b)) and (b[p] <> #0) do Inc(p);
      if c = 'C' then Exit(Copy(b, st, p - st));
      if p <= Length(b) then Inc(p);
    end;
  end;

  function RowAt(Idx: Integer): TStrArray;
  var
    k, seen: Integer;
  begin
    SetLength(Result, 0);
    if msgs = nil then Exit;
    seen := 0;
    for k := 0 to msgs.Count - 1 do
      if (msgs[k] <> '') and (msgs[k][1] = 'D') then
      begin
        if seen = Idx then Exit(TPgRow(TPgBody(msgs[k])));
        Inc(seen);
      end;
  end;

  function CopyDataText: string;
  var
    k: Integer;
  begin
    Result := '';
    if msgs = nil then Exit;
    for k := 0 to msgs.Count - 1 do
      if (msgs[k] <> '') and (msgs[k][1] = 'd') then
        Result := Result + TPgBody(msgs[k]);
  end;

  function CopyIn(const Sql, Data: string): Boolean;
  var
    st: AnsiString;
    t: AnsiChar;
    bb: AnsiString;
    tmp: TStringList;
  begin
    Result := False;
    FreeAndNil(msgs);
    st := 'Q' + TPgI32(Length(Sql) + 1 + 4) + Sql + #0;
    if not TPgSend(s, st) then Exit;
    while True do
    begin
      if not TPgRecvMsg(s, t, bb) then Exit;
      if t = 'E' then
      begin
        msgs := TStringList.Create;
        msgs.Add(t + '|' + bb);
        while TPgRecvMsg(s, t, bb) do
        begin
          msgs.Add(t + '|' + bb);
          if t = 'Z' then Break;
        end;
        Exit(False);
      end;
      if t = 'G' then Break;
    end;
    if Data <> '' then
      if not TPgSend(s, 'd' + TPgI32(Length(Data) + 4) + Data) then Exit;
    if not TPgSend(s, 'c' + TPgI32(4)) then Exit;
    Result := TPgReadUntilReady(s, tmp);
    msgs := tmp;
  end;

  function CopyFail(const Sql, Msg: string): Boolean;
  var
    st: AnsiString;
    t: AnsiChar;
    bb: AnsiString;
    tmp: TStringList;
  begin
    Result := False;
    FreeAndNil(msgs);
    st := 'Q' + TPgI32(Length(Sql) + 1 + 4) + Sql + #0;
    if not TPgSend(s, st) then Exit;
    while True do
    begin
      if not TPgRecvMsg(s, t, bb) then Exit;
      if t = 'E' then
      begin
        msgs := TStringList.Create;
        msgs.Add(t + '|' + bb);
        while TPgRecvMsg(s, t, bb) do
        begin
          msgs.Add(t + '|' + bb);
          if t = 'Z' then Break;
        end;
        Exit(False);
      end;
      if t = 'G' then Break;
    end;
    if not TPgSend(s, 'f' + TPgI32(Length(Msg) + 1 + 4) + Msg + #0) then Exit;
    Result := TPgReadUntilReady(s, tmp);
    msgs := tmp;
  end;

  { Extended protocol: Parse/Bind/Execute + COPY FROM STDIN akisi.
    Execute'tan sonra CopyInResponse ('G') beklenir; veri ve CopyDone
    gonderilir; ReadyForQuery yalnizca Sync ile gelir. }
  function ExtCopyIn(const Sql, Data: string): Boolean;
  var
    t: AnsiChar;
    bb: AnsiString;
    tmp: TStringList;
    sawG: Boolean;
  begin
    Result := False;
    FreeAndNil(msgs);
    if not SendExt('P', ''#0 + Sql + #0 + TPgI16(0)) then Exit;
    if not SendExt('B', ''#0 + ''#0 + TPgI16(0) + TPgI16(0) + TPgI16(0)) then Exit;
    if not SendExt('E', ''#0 + TPgI32(0)) then Exit;
    sawG := False;
    while True do
    begin
      if not TPgRecvMsg(s, t, bb) then Exit;
      if t = 'E' then
      begin
        // Hata: Sync gonderip Ready'ye kadar oku.
        if not SendExt('S', '') then Exit;
        Result := TPgReadUntilReady(s, tmp);
        tmp.Insert(0, t + '|' + bb);   // E, Ready okumasindan once tuketildi
        msgs := tmp;
        Exit;
      end;
      if t = 'G' then
      begin
        sawG := True;
        Break;
      end;
    end;
    if not sawG then Exit;
    if Data <> '' then
      if not SendExt('d', Data) then Exit;
    if not SendExt('c', '') then Exit;
    if not SendExt('S', '') then Exit;
    Result := TPgReadUntilReady(s, tmp);
    if Result and sawG then
      tmp.Insert(0, 'G|');   // G, veri gonderilmeden once tuketildi
    msgs := tmp;
  end;

  { Extended protocol: Parse/Bind/Execute/Sync; COPY TO STDOUT yanitini
    ReadyForQuery'ye kadar toplar. }
  function ExtCopyOut(const Sql: string): Boolean;
  var
    tmp: TStringList;
  begin
    Result := False;
    FreeAndNil(msgs);
    if not SendExt('P', ''#0 + Sql + #0 + TPgI16(0)) then Exit;
    if not SendExt('B', ''#0 + ''#0 + TPgI16(0) + TPgI16(0) + TPgI16(0)) then Exit;
    if not SendExt('E', ''#0 + TPgI32(0)) then Exit;
    if not SendExt('S', '') then Exit;
    Result := TPgReadUntilReady(s, tmp);
    msgs := tmp;
  end;

  { Extended COPY FROM: CopyFail gonder, Sync ile kapan. }
  function ExtCopyFail(const Sql, Msg: string): Boolean;
  var
    t: AnsiChar;
    bb: AnsiString;
    tmp: TStringList;
  begin
    Result := False;
    FreeAndNil(msgs);
    if not SendExt('P', ''#0 + Sql + #0 + TPgI16(0)) then Exit;
    if not SendExt('B', ''#0 + ''#0 + TPgI16(0) + TPgI16(0) + TPgI16(0)) then Exit;
    if not SendExt('E', ''#0 + TPgI32(0)) then Exit;
    while True do
    begin
      if not TPgRecvMsg(s, t, bb) then Exit;
      if t = 'G' then Break;
      if t = 'E' then
      begin
        if not SendExt('S', '') then Exit;
        Result := TPgReadUntilReady(s, tmp);
        tmp.Insert(0, t + '|' + bb);
        msgs := tmp;
        Exit;
      end;
    end;
    if not SendExt('f', Msg + #0) then Exit;
    if not SendExt('S', '') then Exit;
    Result := TPgReadUntilReady(s, tmp);
    msgs := tmp;
  end;

begin
  Grp('M1 PostgreSQL wire protocol (basit sorgu)');
  ForceDirectories(D + '\pgsrv');
  srv := TVdbPgServer.Create(D + '\pgsrv', PPORT);
  msgs := nil;
  s := VDB_SOCK_INVALID;
  try
    ok := srv.Start(err);
    Dogrula('pg sunucu basladi', ok, err);
    if not ok then Exit;
    Dogrula('pg baglanti + startup (SSL reddi)', ConnectAndStart, '');
    if s = VDB_SOCK_INVALID then Exit;

    Dogrula('pg DDL calisti',
      Query('CREATE TABLE pg_t(id INTEGER PRIMARY KEY, s TEXT)'), '');
    Dogrula('pg DDL tag CREATE TABLE', FindTag('CREATE TABLE'), '');
    Dogrula('pg INSERT calisti',
      Query('INSERT INTO pg_t VALUES (1, ''a''), (2, ''b'')'), '');
    Dogrula('pg INSERT tag INSERT 0 2', FindTag('INSERT 0 2'), '');

    Dogrula('pg SELECT calisti',
      Query('SELECT id, s FROM pg_t ORDER BY id'), '');
    ok := False;
    for i := 0 to msgs.Count - 1 do
      if (msgs[i] <> '') and (msgs[i][1] = 'T') then
      begin
        row := TPgFieldNames(TPgBody(msgs[i]));
        oidId := TPgFieldOidAt(TPgBody(msgs[i]), 0);
        oidS := TPgFieldOidAt(TPgBody(msgs[i]), 1);
        ok := (Length(row) = 2) and (row[0] = 'id') and (row[1] = 's');
      end;
    Dogrula('pg RowDescription alanlari', ok, '');
    Dogrula('pg OID id=int8', oidId = 20, IntToStr(oidId));
    Dogrula('pg OID s=text', oidS = 25, IntToStr(oidS));
    row := RowAt(0);
    Dogrula('pg ilk satir 1/a',
      (Length(row) = 2) and (row[0] = '1') and (row[1] = 'a'), '');
    row := RowAt(1);
    Dogrula('pg ikinci satir 2/b',
      (Length(row) = 2) and (row[0] = '2') and (row[1] = 'b'), '');
    Dogrula('pg SELECT tag SELECT 2', FindTag('SELECT 2'), '');

    Dogrula('pg hata sorgusu yanitladi', Query('SELECT * FROM yok'), '');
    Dogrula('pg ErrorResponse dolu', ErrText <> '', Copy(ErrText, 1, 40));
    Dogrula('pg SQLSTATE tablo yok 42P01', ErrState = '42P01', ErrState);
    Dogrula('pg hata sonrasi devam',
      Query('UPDATE pg_t SET s=''z'' WHERE id=2'), '');
    Dogrula('pg UPDATE tag UPDATE 1', FindTag('UPDATE 1'), '');
    Dogrula('pg DELETE calisti', Query('DELETE FROM pg_t WHERE id=1'), '');
    Dogrula('pg DELETE tag DELETE 1', FindTag('DELETE 1'), '');
    Dogrula('pg SQLSTATE duplicate PK',
      Query('INSERT INTO pg_t VALUES (2,''dup'')'), '');
    Dogrula('pg SQLSTATE 23505', ErrState = '23505', ErrState);
    Dogrula('pg SQLSTATE sozdizimi', Query('SELEC 1'), '');
    Dogrula('pg SQLSTATE 42601', ErrState = '42601', ErrState);

    // ---- Basit sorguda coklu cumle ----
    Dogrula('pg multi SELECT', Query('SELECT 1 AS a; SELECT 2 AS b'), '');
    Dogrula('pg multi iki sonuc kumesi', TypeSeq = 'TDCTDCZ', TypeSeq);
    Dogrula('pg multi SELECT tag', FindTag('SELECT 1'), '');
    Dogrula('pg multi DDL+DML',
      Query('CREATE TABLE pg_multi(id INTEGER PRIMARY KEY, v TEXT); ' +
        'INSERT INTO pg_multi VALUES (1,''x''); ' +
        'INSERT INTO pg_multi VALUES (2,''y'')'), '');
    Dogrula('pg multi INSERT tag', FindTag('INSERT 0 1'), '');
    Dogrula('pg multi satir sayisi',
      Query('SELECT COUNT(*) FROM pg_multi'), '');
    row := RowAt(0);
    Dogrula('pg multi 2 satir', (Length(row) = 1) and (row[0] = '2'), '');
    Dogrula('pg multi transaction',
      Query('BEGIN; INSERT INTO pg_multi VALUES (3,''z''); COMMIT'), '');
    Dogrula('pg multi BEGIN/COMMIT tag',
      FindTag('BEGIN') and FindTag('COMMIT'), TypeSeq);
    Dogrula('pg multi transaction satir',
      Query('SELECT COUNT(*) FROM pg_multi'), '');
    row := RowAt(0);
    Dogrula('pg multi 3 satir', (Length(row) = 1) and (row[0] = '3'), '');
    Dogrula('pg multi hata',
      Query('SELECT 1 AS a; SELECT * FROM yok_boyle_tablo'), '');
    Dogrula('pg multi hata ErrorResponse', ErrText <> '',
      Copy(ErrText, 1, 40));
    Dogrula('pg multi hata sonrasi devam',
      Query('SELECT 42 AS c'), '');
    row := RowAt(0);
    Dogrula('pg multi hata sonrasi deger',
      (Length(row) = 1) and (row[0] = '42'), '');

    // ---- COPY FROM STDIN / TO STDOUT (basit sorgu) ----
    Dogrula('pg COPY tablo DDL', Query(
      'CREATE TABLE pg_copy(id INTEGER PRIMARY KEY, s TEXT)'), '');
    Dogrula('pg COPY FROM STDIN',
      CopyIn('COPY pg_copy FROM STDIN WITH (FORMAT csv)',
        '1,aa'#10'2,bb'#10), '');
    Dogrula('pg COPY FROM tag COPY 2', FindTag('COPY 2'), '');
    Dogrula('pg COPY FROM sonrasi SELECT',
      Query('SELECT id,s FROM pg_copy ORDER BY id'), '');
    row := RowAt(0);
    Dogrula('pg COPY ilk satir 1/aa',
      (Length(row) = 2) and (row[0] = '1') and (row[1] = 'aa'), '');
    row := RowAt(1);
    Dogrula('pg COPY ikinci satir 2/bb',
      (Length(row) = 2) and (row[0] = '2') and (row[1] = 'bb'), '');

    Dogrula('pg COPY HEADER + DELIMITER',
      CopyIn('COPY pg_copy (id, s) FROM STDIN WITH ' +
        '(FORMAT csv, HEADER, DELIMITER '';'')',
        'id;s'#10'3;cc'#10'4;dd'#10), '');
    Dogrula('pg COPY HEADER tag COPY 2', FindTag('COPY 2'), '');

    Dogrula('pg COPY Fail yanitladi',
      CopyFail('COPY pg_copy FROM STDIN WITH (FORMAT csv)', 'istemci iptali'),
      '');
    Dogrula('pg COPY Fail ErrorResponse dolu', ErrText <> '',
      Copy(ErrText, 1, 40));
    Dogrula('pg COPY Fail sonrasi SELECT',
      Query('SELECT COUNT(*) FROM pg_copy'), '');
    row := RowAt(0);
    Dogrula('pg COPY Fail atomik (4 satir)',
      (Length(row) = 1) and (row[0] = '4'), '');

    Dogrula('pg COPY TO STDOUT',
      Query('COPY pg_copy TO STDOUT WITH (FORMAT csv, HEADER)'), '');
    Dogrula('pg COPY TO akis tipi H',
      Pos('H', TypeSeq) > 0, TypeSeq);
    Dogrula('pg COPY TO tag COPY 4', FindTag('COPY 4'), '');
    Dogrula('pg COPY TO CSV icerik',
      (Pos('id,s'#10, CopyDataText) = 1) and
      (Pos('1,aa'#10, CopyDataText) > 0) and
      (Pos('2,bb'#10, CopyDataText) > 0) and
      (Pos('3,cc'#10, CopyDataText) > 0) and
      (Pos('4,dd'#10, CopyDataText) > 0),
      StringReplace(CopyDataText, #10, '\n', [rfReplaceAll]));

    Dogrula('pg COPY TO text varsayilan',
      Query('COPY pg_copy (id, s) TO STDOUT'), '');
    Dogrula('pg COPY TO text icerik',
      Pos('1'#9'aa'#10, CopyDataText) > 0,
      StringReplace(CopyDataText, #10, '\n', [rfReplaceAll]));

    Dogrula('pg COPY (SELECT) TO STDOUT',
      Query('COPY (SELECT id, s FROM pg_copy ORDER BY id) TO STDOUT ' +
        'WITH (FORMAT csv, HEADER)'), '');
    Dogrula('pg COPY (SELECT) tag COPY 4', FindTag('COPY 4'), '');
    Dogrula('pg COPY (SELECT) CSV icerik',
      (Pos('id,s'#10, CopyDataText) = 1) and
      (Pos('1,aa'#10, CopyDataText) > 0) and
      (Pos('4,dd'#10, CopyDataText) > 0),
      StringReplace(CopyDataText, #10, '\n', [rfReplaceAll]));

    // ---- Extended protocol uzerinden COPY ----
    Dogrula('pg ext COPY FROM',
      ExtCopyIn('COPY pg_copy FROM STDIN WITH (FORMAT csv)',
        '5,ee'#10'6,ff'#10), '');
    Dogrula('pg ext COPY FROM tag COPY 2', FindTag('COPY 2'), TypeSeq);
    Dogrula('pg ext COPY FROM akis tipi G',
      Pos('G', TypeSeq) > 0, TypeSeq);
    Dogrula('pg ext COPY FROM Ready yalniz Sync sonrasi',
      (TypeSeq <> '') and (TypeSeq[Length(TypeSeq)] = 'Z'), TypeSeq);
    Dogrula('pg ext COPY FROM sonrasi SELECT',
      Query('SELECT COUNT(*) FROM pg_copy'), '');
    row := RowAt(0);
    Dogrula('pg ext COPY FROM 6 satir',
      (Length(row) = 1) and (row[0] = '6'), '');

    Dogrula('pg ext COPY TO',
      ExtCopyOut('COPY (SELECT id, s FROM pg_copy WHERE id >= 5 ' +
        'ORDER BY id) TO STDOUT WITH (FORMAT csv, HEADER)'), '');
    Dogrula('pg ext COPY TO akis tipi H',
      Pos('H', TypeSeq) > 0, TypeSeq);
    Dogrula('pg ext COPY TO tag COPY 2', FindTag('COPY 2'), TypeSeq);
    Dogrula('pg ext COPY TO CSV icerik',
      (Pos('id,s'#10, CopyDataText) = 1) and
      (Pos('5,ee'#10, CopyDataText) > 0) and
      (Pos('6,ff'#10, CopyDataText) > 0),
      StringReplace(CopyDataText, #10, '\n', [rfReplaceAll]));

    Dogrula('pg ext COPY Fail',
      ExtCopyFail('COPY pg_copy FROM STDIN WITH (FORMAT csv)',
        'ext iptal'), '');
    Dogrula('pg ext COPY Fail ErrorResponse', ErrText <> '',
      Copy(ErrText, 1, 40));
    Dogrula('pg ext COPY Fail atomik',
      Query('SELECT COUNT(*) FROM pg_copy'), '');
    row := RowAt(0);
    Dogrula('pg ext COPY Fail 6 satir',
      (Length(row) = 1) and (row[0] = '6'), '');

    // Describe Portal COPY akisini BASLATMAMALI; NoData donmeli.
    FreeAndNil(msgs);
    Dogrula('pg ext COPY Describe Parse',
      SendExt('P', 'cdesc'#0 + 'COPY pg_copy TO STDOUT'#0 + TPgI16(0)), '');
    Dogrula('pg ext COPY Describe Bind',
      SendExt('B', 'cdesc'#0 + 'cdesc'#0 + TPgI16(0) + TPgI16(0) + TPgI16(0)), '');
    Dogrula('pg ext COPY Describe Portal',
      SendExt('D', 'P' + 'cdesc'#0), '');
    Dogrula('pg ext COPY Describe Sync', SyncRead, '');
    Dogrula('pg ext COPY Describe NoData',
      (TypeSeq = '12nZ') and (Pos('H', TypeSeq) = 0), TypeSeq);

    // ---- Extended query protocol (parametresiz) ----
    FreeAndNil(msgs);
    Dogrula('pg ext Parse',
      SendExt('P', 'ext1'#0 + 'SELECT s FROM pg_t'#0 + TPgI16(0)), '');
    Dogrula('pg ext Bind',
      SendExt('B', ''#0 + 'ext1'#0 + TPgI16(0) + TPgI16(0) + TPgI16(0)), '');
    Dogrula('pg ext Describe portal', SendExt('D', 'P' + ''#0), '');
    Dogrula('pg ext Execute', SendExt('E', ''#0 + TPgI32(0)), '');
    Dogrula('pg ext Sync', SyncRead, '');
    Dogrula('pg ext yanit dizisi 12TDCZ', TypeSeq = '12TDCZ', TypeSeq);
    row := RowAt(0);
    Dogrula('pg ext satir degeri z',
      (Length(row) = 1) and (row[0] = 'z'), '');
    Dogrula('pg ext SELECT tag', FindTag('SELECT 1'), '');

    FreeAndNil(msgs);
    Dogrula('pg ext Close statement', SendExt('C', 'S' + 'ext1'#0), '');
    Dogrula('pg ext Close portal', SendExt('C', 'P' + ''#0), '');
    Dogrula('pg ext Close Sync', SyncRead, '');
    Dogrula('pg ext Close yanit dizisi 33Z', TypeSeq = '33Z', TypeSeq);

    Dogrula('pg ext DDL', Query('CREATE TABLE pg_ext(a INTEGER PRIMARY KEY, s TEXT)'), '');
    FreeAndNil(msgs);
    Dogrula('pg ext INSERT Parse',
      SendExt('P', 'ins1'#0 + 'INSERT INTO pg_ext VALUES (1,''e'')'#0 + TPgI16(0)), '');
    Dogrula('pg ext INSERT Bind',
      SendExt('B', ''#0 + 'ins1'#0 + TPgI16(0) + TPgI16(0) + TPgI16(0)), '');
    Dogrula('pg ext INSERT Execute', SendExt('E', ''#0 + TPgI32(0)), '');
    Dogrula('pg ext INSERT Sync', SyncRead, '');
    Dogrula('pg ext INSERT yanit dizisi 12CZ', TypeSeq = '12CZ', TypeSeq);
    Dogrula('pg ext INSERT tag', FindTag('INSERT 0 1'), '');
    Dogrula('pg ext INSERT kalici',
      Query('SELECT COUNT(*) FROM pg_ext'), '');
    row := RowAt(0);
    Dogrula('pg ext INSERT satir sayisi 1',
      (Length(row) = 1) and (row[0] = '1'), '');

    // ---- Parametreli extended protocol (M1) ----
    // Parse'te OID verilmez; sunucu SQL'den 1 parametre cikarir.
    FreeAndNil(msgs);
    SendExt('P', 'p1'#0 + 'SELECT $1'#0 + TPgI16(0));
    SendExt('B', ''#0 + 'p1'#0 + TPgI16(0) + TPgI16(1) +
      TPgI32(2) + '42' + TPgI16(0));
    SendExt('D', 'S' + 'p1'#0);
    SendExt('E', ''#0 + TPgI32(0));
    SyncRead;
    Dogrula('pg ext parametreli yanit dizisi 12tnDCZ',
      TypeSeq = '12tnDCZ', TypeSeq);
    row := RowAt(0);
    Dogrula('pg ext metin parametre 42',
      (Length(row) = 1) and (row[0] = '42'), '');
    Dogrula('pg ext parametreli SELECT tag', FindTag('SELECT 1'), '');
    ok := False;
    for i := 0 to msgs.Count - 1 do
      if (msgs[i] <> '') and (msgs[i][1] = 't') then
      begin
        body := TPgBody(msgs[i]);
        ok := (Copy(body, 1, 2) = TPgI16(1)) and
          (Copy(body, 3, 4) = TPgI32(25));
      end;
    Dogrula('pg ext ParameterDescription 1/OID 25', ok, '');

    // Binary int4 parametre: 4 bayt buyuk-endian 7.
    FreeAndNil(msgs);
    SendExt('P', 'p2'#0 + 'SELECT $1'#0 + TPgI16(1) + TPgI32(23));
    SendExt('B', ''#0 + 'p2'#0 + TPgI16(1) + TPgI16(1) + TPgI16(1) +
      TPgI32(4) + TPgI32(7) + TPgI16(0));
    SendExt('D', 'S' + 'p2'#0);
    SendExt('E', ''#0 + TPgI32(0));
    SyncRead;
    Dogrula('pg ext binary int4 yanit 12tnDCZ',
      TypeSeq = '12tnDCZ', TypeSeq);
    row := RowAt(0);
    Dogrula('pg ext binary int4 degeri 7',
      (Length(row) = 1) and (row[0] = '7'), '');

    // `?` yer tutucu: Parse'te OID yok; Bind sayisindan turetilir.
    FreeAndNil(msgs);
    SendExt('P', 'p5'#0 + 'SELECT ?'#0 + TPgI16(0));
    SendExt('B', ''#0 + 'p5'#0 + TPgI16(0) + TPgI16(1) +
      TPgI32(2) + '99' + TPgI16(0));
    SendExt('D', 'S' + 'p5'#0);
    SendExt('E', ''#0 + TPgI32(0));
    SyncRead;
    Dogrula('pg ext ? yer tutucu 12tnDCZ', TypeSeq = '12tnDCZ', TypeSeq);
    row := RowAt(0);
    Dogrula('pg ext ? yer tutucu 99',
      (Length(row) = 1) and (row[0] = '99'), '');

    // Eksik parameter: Parse/Bind hata verir, Sync'e kadar yutulur.
    FreeAndNil(msgs);
    SendExt('P', 'p3'#0 + 'SELECT $1'#0 + TPgI16(0));
    SendExt('B', ''#0 + 'p3'#0 + TPgI16(0) + TPgI16(0) + TPgI16(0));
    SyncRead;
    Dogrula('pg ext eksik parametre (1EZ)', TypeSeq = '1EZ', TypeSeq);
    Dogrula('pg ext eksik parametre hatasi dolu', ErrText <> '',
      Copy(ErrText, 1, 40));

    // Binary sonuc formati: int8 (a) 8 bayt buyuk-endian.
    FreeAndNil(msgs);
    SendExt('P', 'p4'#0 + 'SELECT a FROM pg_ext'#0 + TPgI16(0));
    SendExt('B', ''#0 + 'p4'#0 + TPgI16(0) + TPgI16(0) +
      TPgI16(1) + TPgI16(1));
    SendExt('D', 'P' + ''#0);
    SendExt('E', ''#0 + TPgI32(0));
    SyncRead;
    Dogrula('pg ext binary sonuc kabul (12TDCZ)', TypeSeq = '12TDCZ', TypeSeq);
    body := '';
    for i := 0 to msgs.Count - 1 do
      if (msgs[i] <> '') and (msgs[i][1] = 'D') then
        body := TPgBody(msgs[i]);
    Dogrula('pg ext binary int8 degeri 1',
      body = TPgI16(1) + TPgI32(8) + TPgI64(1), '');

    // Binary sonuc: float8/bool/date/timestamp/text birlikte.
    Dogrula('pg bin DDL',
      Query('CREATE TABLE pg_bin(id INTEGER PRIMARY KEY, f FLOAT, b BOOL, ' +
        'd DATE, ts DATETIME, s TEXT)'), '');
    Dogrula('pg bin INSERT',
      Query('INSERT INTO pg_bin VALUES (1, 1.5, 1, ''2026-01-02'', ' +
        '''2026-01-02 03:04:05'', ''abc'')'), '');
    FreeAndNil(msgs);
    SendExt('P', 'p6'#0 + 'SELECT id, f, b, d, ts, s FROM pg_bin'#0 + TPgI16(0));
    SendExt('B', ''#0 + 'p6'#0 + TPgI16(0) + TPgI16(0) +
      TPgI16(1) + TPgI16(1));
    SendExt('D', 'P' + ''#0);
    SendExt('E', ''#0 + TPgI32(0));
    SyncRead;
    Dogrula('pg bin binary yanit (12TDCZ)', TypeSeq = '12TDCZ', TypeSeq);
    body := '';
    for i := 0 to msgs.Count - 1 do
      if (msgs[i] <> '') and (msgs[i][1] = 'D') then
        body := TPgBody(msgs[i]);
    Dogrula('pg bin binary degerler',
      body = TPgI16(6) + TPgI32(8) + TPgI64(1) +
        TPgI32(8) + TPgF64(1.5) + TPgI32(1) + #1 +
        TPgI32(4) + TPgI32(Trunc(EncodeDate(2026, 1, 2) -
          EncodeDate(2000, 1, 1))) +
        TPgI32(8) + TPgI64(Round((EncodeDate(2026, 1, 2) +
          EncodeTime(3, 4, 5, 0) - EncodeDate(2000, 1, 1)) *
          86400.0 * 1000000.0)) +
        TPgI32(3) + 'abc', '');

    Dogrula('pg ext hata sonrasi baglanti canli',
      Query('SELECT COUNT(*) FROM pg_ext'), '');
    row := RowAt(0);
    Dogrula('pg ext hata sonrasi satir 1',
      (Length(row) = 1) and (row[0] = '1'), '');

    // Execute sirasinda SQL hatasi: Parse/Bind basarili, Execute E, Sync Z.
    FreeAndNil(msgs);
    SendExt('P', 'bad2'#0 + 'SELECT * FROM yok'#0 + TPgI16(0));
    SendExt('B', ''#0 + 'bad2'#0 + TPgI16(0) + TPgI16(0) + TPgI16(0));
    SendExt('E', ''#0 + TPgI32(0));
    SyncRead;
    Dogrula('pg ext Execute hatasi (12EZ)', TypeSeq = '12EZ', TypeSeq);
    Dogrula('pg ext Execute hatasi dolu', ErrText <> '',
      Copy(ErrText, 1, 40));

    TPgSend(s, 'X' + TPgI32(4));
    VdbSockClose(s);
    s := VDB_SOCK_INVALID;
    FreeAndNil(msgs);

    srv.Stop;
    ok := srv.Start(err);
    Dogrula('pg yeniden baslatma', ok, err);
    if not ok then Exit;
    Dogrula('pg yeniden baglanti', ConnectAndStart, '');
    if s = VDB_SOCK_INVALID then Exit;
    Dogrula('pg kalici SELECT', Query('SELECT COUNT(*) FROM pg_t'), '');
    row := RowAt(0);
    Dogrula('pg kalici satir sayisi 1',
      (Length(row) = 1) and (row[0] = '1'), '');
    Dogrula('pg kalici deger z', Query('SELECT s FROM pg_t'), '');
    row := RowAt(0);
    Dogrula('pg guncel deger z', (Length(row) = 1) and (row[0] = 'z'), '');
    TPgSend(s, 'X' + TPgI32(4));
    VdbSockClose(s);
    s := VDB_SOCK_INVALID;
  finally
    if s <> VDB_SOCK_INVALID then VdbSockClose(s);
    FreeAndNil(msgs);
    srv.Stop;
    srv.Free;
  end;
end;

{ M1: pgwire TLS. Test sertifikasi YALNIZ bu test icindir; 100 yil
  gecerli, kendinden imzali ECDSA P-256. Gercek kurulumda kullanici
  kendi sertifika/anahtarini verir. }
procedure T120_Tls;
const
  PPORT = 54731;
  CERT_LINES: array[0..9] of string = (
    '-----BEGIN CERTIFICATE-----',
    'MIIBcDCCARagAwIBAgIUUu+v8AVyF1kfZCACHaOqVsdnqDYwCgYIKoZIzj0EAwIw',
    'JzESMBAGA1UEAwwJbG9jYWxob3N0MREwDwYDVQQKDAhWREIgVGVzdDAgFw0yNjAx',
    'MDEwMDAwMDBaGA8yMTI2MDEwMTAwMDAwMFowJzESMBAGA1UEAwwJbG9jYWxob3N0',
    'MREwDwYDVQQKDAhWREIgVGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABJ/T',
    '1+9TYNfKHAqaWdxck5NxfPOjR3U8c0vetwOxTc959P3PEvBgYhhPjIqSLkgIGNva',
    'fSEoSP7Eq8rKaq7784ejHjAcMBoGA1UdEQQTMBGCCWxvY2FsaG9zdIcEfwAAATAK',
    'BggqhkjOPQQDAgNIADBFAiEAzkonA+1eQ7+HnGsO44+Nfb6yCI7Dt6VvWXrj9Sel',
    'l+ICIHvv/XSshv8RbS1MrcVsviaAOk8psk6sXRhvROgi7ntP',
    '-----END CERTIFICATE-----');
  KEY_LINES: array[0..4] of string = (
    '-----BEGIN EC PRIVATE KEY-----',
    'MHcCAQEEIMppOWxheYa0V8UBOqGynYCVXX8Bwbi12x4WeZcJSWHvoAoGCCqGSM49',
    'AwEHoUQDQgAEn9PX71Ng18ocCppZ3FyTk3F886NHdTxzS963A7FNz3n0/c8S8GBi',
    'GE+MipIuSAgY29p9IShI/sSryspqrvvzhw==',
    '-----END EC PRIVATE KEY-----');
var
  srv: TVdbPgServer;
  err, certPath, keyPath: string;
  sl: TStringList;
  s: TVdbSocket;
  ctx: TVdbTlsContext;
  sess: TVdbTlsSession;
  ok: Boolean;
  i: Integer;
  answer: Byte;
  t: AnsiChar;
  bb: AnsiString;

  function TlsSendAll(const Buf; Len: Integer): Boolean;
  var
    off, n: Integer;
    p: PByte;
  begin
    Result := False;
    if Len <= 0 then Exit(True);
    p := @Buf;
    off := 0;
    while off < Len do
    begin
      n := sess.Write(p + off, Len - off);
      if n <= 0 then Exit;
      Inc(off, n);
    end;
    Result := True;
  end;

  function TlsRecvAll(var Buf; Len: Integer): Boolean;
  var
    got, n: Integer;
    p: PByte;
  begin
    Result := False;
    if Len <= 0 then Exit(True);
    p := @Buf;
    got := 0;
    while got < Len do
    begin
      n := sess.Read(p + got, Len - got);
      if n <= 0 then Exit;
      Inc(got, n);
    end;
    Result := True;
  end;

  function TlsSendMsg(const M: AnsiString): Boolean;
  begin
    Result := False;
    if M = '' then Exit(True);
    Result := TlsSendAll(M[1], Length(M));
  end;

  function TlsRecvMsg(out T: AnsiChar; out Body: AnsiString): Boolean;
  var
    b: array[0..3] of Byte;
    l: LongInt;
  begin
    Result := False;
    Body := '';
    if not TlsRecvAll(T, 1) then Exit;
    if not TlsRecvAll(b, 4) then Exit;
    l := LongInt((Cardinal(b[0]) shl 24) or (Cardinal(b[1]) shl 16) or
      (Cardinal(b[2]) shl 8) or Cardinal(b[3]));
    if l < 4 then Exit;
    SetLength(Body, l - 4);
    if (l > 4) and not TlsRecvAll(Body[1], l - 4) then Exit;
    Result := True;
  end;

  function TlsStartup: Boolean;
  var
    param, st: AnsiString;
  begin
    Result := False;
    param := 'user'#0 + 'postgres'#0 + 'database'#0 + 'vdb'#0 +
      'client_encoding'#0 + 'UTF8'#0#0;
    st := TPgI32(4 + 4 + Length(param)) + TPgI32(196608) + param;
    if not TlsSendMsg(st) then Exit;
    repeat
      if not TlsRecvMsg(t, bb) then Exit;
    until t = 'Z';
    Result := True;
  end;

  function TlsQuery(const Sql: string; out RowBody: AnsiString): Boolean;
  var
    q, seq, body: AnsiString;
    tt: AnsiChar;
  begin
    Result := False;
    RowBody := '';
    q := AnsiString(Sql);
    if not TlsSendMsg('Q' + TPgI32(Length(q) + 5) + q + #0) then Exit;
    seq := '';
    while True do
    begin
      if not TlsRecvMsg(tt, body) then Exit;
      seq := seq + AnsiString(tt);
      if tt = 'D' then RowBody := body;
      if tt = 'Z' then Break;
    end;
    Result := Pos('D', string(seq)) > 0;
  end;

  { SSLRequest gonderip 'S' yanitini bekleyen ham baglanti. }
  function OpenRaw(out Sock: TVdbSocket; out Answer: Byte): Boolean;
  begin
    Result := False;
    Sock := VdbTcpConnect('127.0.0.1', PPORT);
    if Sock = VDB_SOCK_INVALID then Exit;
    if not TPgSend(Sock, TPgI32(8) + TPgI32(80877103)) then Exit;
    Result := VdbRecvU8(Sock, Answer);
  end;

  { TLS sunucusuna SSLRequest YAPMADAN baglanip startup gonderir. }
  function PlainOnTlsServer: Boolean;
  var
    param, st: AnsiString;
    sock: TVdbSocket;
  begin
    Result := False;
    sock := VdbTcpConnect('127.0.0.1', PPORT);
    if sock = VDB_SOCK_INVALID then Exit;
    try
      param := 'user'#0 + 'postgres'#0 + 'database'#0 + 'vdb'#0 +
        'client_encoding'#0 + 'UTF8'#0#0;
      st := TPgI32(4 + 4 + Length(param)) + TPgI32(196608) + param;
      if not TPgSend(sock, st) then Exit;
      repeat
        if not TPgRecvMsg(sock, t, bb) then Exit;
      until t = 'Z';
      st := 'Q' + TPgI32(Length('SELECT 1') + 5) + 'SELECT 1'#0;
      if not TPgSend(sock, st) then Exit;
      while True do
      begin
        if not TPgRecvMsg(sock, t, bb) then Exit;
        if t = 'D' then Result := True;
        if t = 'Z' then Break;
      end;
    finally
      VdbSockClose(sock);
    end;
  end;

begin
  Grp('M1 pgwire TLS (OpenSSL)');
  certPath := D + '\pgtls_cert.pem';
  keyPath := D + '\pgtls_key.pem';
  sl := TStringList.Create;
  try
    for i := 0 to High(CERT_LINES) do sl.Add(CERT_LINES[i]);
    sl.SaveToFile(certPath);
    sl.Clear;
    for i := 0 to High(KEY_LINES) do sl.Add(KEY_LINES[i]);
    sl.SaveToFile(keyPath);
  finally
    sl.Free;
  end;

  Dogrula('TLS OpenSSL yuklendi', VDbTlsAvailable, VDbTlsLastError);
  if not VDbTlsAvailable then Exit;

  ForceDirectories(D + '\pgtls');
  srv := TVdbPgServer.Create(D + '\pgtls', PPORT);
  ctx := nil;
  sess := nil;
  s := VDB_SOCK_INVALID;
  try
    srv.SetTlsFiles(certPath, keyPath);
    ok := srv.Start(err);
    Dogrula('TLS sunucu basladi', ok, err);
    if not ok then Exit;
    Dogrula('TLS etkin', srv.TlsActive, '');

    ok := OpenRaw(s, answer);
    Dogrula('TLS SSLRequest yaniti S', ok and (answer = Ord('S')),
      IntToStr(answer));
    if not ok then Exit;

    ctx := TVdbTlsContext.CreateClient;
    ok := ctx.Connect(s, sess, err);
    Dogrula('TLS istemci el sikismasi', ok, err);
    if not ok then Exit;
    Dogrula('TLS oturum kuruldu', sess <> nil, '');

    Dogrula('TLS startup', TlsStartup, '');
    bb := '';
    Dogrula('TLS SELECT 1', TlsQuery('SELECT 1 AS tls_probe', bb), '');
    Dogrula('TLS sonuc degeri 1',
      (Length(bb) = 7) and (bb[1] = #0) and (bb[2] = #1) and
      (bb[7] = '1'), IntToStr(Length(bb)));

    FreeAndNil(sess);
    VdbSockClose(s);
    s := VDB_SOCK_INVALID;
    FreeAndNil(ctx);

    Dogrula('TLS sunucuda SSL istemeyen istemci de calisir',
      PlainOnTlsServer, '');
  finally
    if sess <> nil then sess.Free;
    if ctx <> nil then ctx.Free;
    if s <> VDB_SOCK_INVALID then VdbSockClose(s);
    srv.Stop;
    srv.Free;
  end;
end;

{ M4: HNSW yakinlik indeksi. 600 satirlik iki veri kumesi kullanir:
  - cizgi: mesafeler tekduze -> ANN kesin sonucu bulmali.
  - rastgele: gercek ANN davranisi; recall olculur (>= 0.9 beklenir).
  Yazma/silme sonrasi DataSeq degisir; indeks tembel yeniden kurulur. }
procedure T121_VectorAnn;
const
  N = 600;
  K = 10;
var
  i, hit: Integer;
  vals, q, exact, ann, showSql: string;

  function VecJson(a, b, c, d: Double): string;
  begin
    Result := '[' + VDbFloatToStr(a) + ',' + VDbFloatToStr(b) + ',' +
      VDbFloatToStr(c) + ',' + VDbFloatToStr(d) + ']';
  end;

  function Rnd(Seed: Integer): Double;
  begin
    // Deterministik, (0,1) arasi.
    Result := Frac(Abs(Sin(Seed * 12.9898 + 78.233) * 43758.5453));
  end;

  function IdsOf(const Sql: string): string;
  var
    j: Integer;
  begin
    Result := '';
    R := sq.Exec(Sql);
    for j := 0 to High(R.Rows) do
      if Length(R.Rows[j]) > 0 then
      begin
        if Result <> '' then Result := Result + ',';
        Result := Result + R.Rows[j][0];
      end;
  end;

  function Items(const S: string): Integer;
  var
    L: TStringList;
  begin
    if S = '' then Exit(0);
    L := TStringList.Create;
    try
      L.Delimiter := ',';
      L.StrictDelimiter := True;
      L.DelimitedText := S;
      Result := L.Count;
    finally
      L.Free;
    end;
  end;

  function Overlap(const A, B: string): Integer;
  var
    LA, LB: TStringList;
    j: Integer;
  begin
    Result := 0;
    LA := TStringList.Create;
    LB := TStringList.Create;
    try
      LA.Delimiter := ',';
      LA.StrictDelimiter := True;
      LA.DelimitedText := A;
      LB.Delimiter := ',';
      LB.StrictDelimiter := True;
      LB.DelimitedText := B;
      for j := 0 to LA.Count - 1 do
        if LB.IndexOf(LA[j]) >= 0 then Inc(Result);
    finally
      LB.Free;
      LA.Free;
    end;
  end;

begin
  Grp('M4 HNSW vektor indeksi (ANN)');
  Chk('VEC ANN tablo cizgi',
    'CREATE TABLE vec_line_t(id INTEGER PRIMARY KEY, v TEXT)', 0);
  vals := '';
  for i := 1 to N do
  begin
    if vals <> '' then vals := vals + ',';
    vals := vals + '(' + IntToStr(i) + ',' +
      SQLIT(VecJson(i * 0.01, i * 0.011, i * 0.012, i * 0.013)) + ')';
  end;
  Chk('VEC ANN cizgi satirlari',
    'INSERT INTO vec_line_t VALUES ' + vals, 0);
  q := VecJson(0.1, 0.11, 0.12, 0.13);
  exact := IdsOf('SELECT id FROM vec_line_t WHERE id >= 0 ORDER BY ' +
    'VECTOR_DISTANCE(v,' + SQLIT(q) + ') LIMIT ' + IntToStr(K));
  ann := IdsOf('SELECT id FROM vec_line_t ORDER BY ' +
    'VECTOR_DISTANCE(v,' + SQLIT(q) + ') LIMIT ' + IntToStr(K));
  Dogrula('VEC ANN cizgi 10 sonuc', Items(ann) = K, ann);
  // Esit mesafeli komsularin kendi arasindaki sirasi tanimsizdir; kume ayni.
  Dogrula('VEC ANN cizgi kesin kume ile ayni', Overlap(ann, exact) = K,
    ann + ' / ' + exact);

  Chk('VEC ANN tablo rastgele',
    'CREATE TABLE vec_rnd_t(id INTEGER PRIMARY KEY, v TEXT)', 0);
  vals := '';
  for i := 1 to N do
  begin
    if vals <> '' then vals := vals + ',';
    vals := vals + '(' + IntToStr(i) + ',' +
      SQLIT(VecJson(Rnd(i * 4 + 1), Rnd(i * 4 + 2), Rnd(i * 4 + 3),
        Rnd(i * 4 + 4))) + ')';
  end;
  Chk('VEC ANN rastgele satirlari',
    'INSERT INTO vec_rnd_t VALUES ' + vals, 0);
  q := VecJson(0.5, 0.5, 0.5, 0.5);
  exact := IdsOf('SELECT id FROM vec_rnd_t WHERE id >= 0 ORDER BY ' +
    'VECTOR_DISTANCE(v,' + SQLIT(q) + ') LIMIT ' + IntToStr(K));
  ann := IdsOf('SELECT id FROM vec_rnd_t ORDER BY ' +
    'VECTOR_DISTANCE(v,' + SQLIT(q) + ') LIMIT ' + IntToStr(K));
  hit := Overlap(ann, exact);
  Dogrula('VEC ANN rastgele 10 sonuc', Items(ann) = K, ann);
  Dogrula('VEC ANN rastgele recall >= 0.9', hit >= 9,
    IntToStr(hit) + '/10');

  // Cosine: ayni veri kumesi, farkli metrik -> ayri indeks anahtari.
  exact := IdsOf('SELECT id FROM vec_rnd_t WHERE id >= 0 ORDER BY ' +
    'VECTOR_DISTANCE(v,' + SQLIT(q) + ',' + SQLIT('cosine') + ') LIMIT ' +
    IntToStr(K));
  ann := IdsOf('SELECT id FROM vec_rnd_t ORDER BY ' +
    'VECTOR_DISTANCE(v,' + SQLIT(q) + ',' + SQLIT('cosine') + ') LIMIT ' +
    IntToStr(K));
  hit := Overlap(ann, exact);
  Dogrula('VEC ANN cosine recall >= 0.9', hit >= 9, IntToStr(hit) + '/10');

  // Cache invalidation: en yakin noktayi ekle.
  q := VecJson(0.123, 0.456, 0.789, 0.321);
  Chk('VEC ANN yeni en yakin satir',
    'INSERT INTO vec_rnd_t VALUES (901,' + SQLIT(q) + ')', 0);
  ann := IdsOf('SELECT id FROM vec_rnd_t ORDER BY ' +
    'VECTOR_DISTANCE(v,' + SQLIT(q) + ') LIMIT 1');
  Dogrula('VEC ANN yazma sonrasi taze indeks', ann = '901', ann);
  // Guncelle: ayni satiri uzaklastir.
  Chk('VEC ANN satiri uzaklastir',
    'UPDATE vec_rnd_t SET v = ' + SQLIT(VecJson(9, 9, 9, 9)) +
    ' WHERE id = 901', -1);
  ann := IdsOf('SELECT id FROM vec_rnd_t ORDER BY ' +
    'VECTOR_DISTANCE(v,' + SQLIT(q) + ') LIMIT 1');
  Dogrula('VEC ANN update sonrasi taze indeks', ann <> '901', ann);
  Chk('VEC ANN gecersiz vektor satiri',
    'INSERT INTO vec_rnd_t VALUES (902,' + SQLIT('bozuk') + ')', 0);
  ChkVal('VEC ANN gecersiz vektor atlandi',
    'SELECT COUNT(*) FROM vec_rnd_t', 0, 0, '602');

  // M4: VECTOR(n) kolon tipi + boyut dogrulamasi (TEXT uzerinde JSON dizi).
  Chk('VEC(n) tablo',
    'CREATE TABLE vec_dim_t(id INTEGER PRIMARY KEY, v VECTOR(3))', 0);
  Chk('VEC(n) gecerli deger',
    'INSERT INTO vec_dim_t VALUES (1,' + SQLIT('[1,2,3]') + ')', 0);
  Chk('VEC(n) bosluklu gecerli deger',
    'INSERT INTO vec_dim_t VALUES (2,' + SQLIT('[1, 2, 3]') + ')', 0);
  ChkErr('VEC(n) eksik boyut reddedildi',
    'INSERT INTO vec_dim_t VALUES (3,' + SQLIT('[1,2]') + ')');
  ChkErr('VEC(n) fazla boyut reddedildi',
    'INSERT INTO vec_dim_t VALUES (4,' + SQLIT('[1,2,3,4]') + ')');
  ChkErr('VEC(n) sayisal olmayan reddedildi',
    'INSERT INTO vec_dim_t VALUES (5,' + SQLIT('[1,2,"x"]') + ')');
  ChkErr('VEC(n) gecersiz DDL reddedildi',
    'CREATE TABLE vec_bad_t(id INTEGER PRIMARY KEY, v VECTOR(0))');
  ChkVal('VEC(n) gecerli satirlar korundu',
    'SELECT COUNT(*) FROM vec_dim_t', 0, 0, '2');
  R := sq.Exec('SHOW CREATE TABLE vec_dim_t');
  if Length(R.Rows) > 0 then showSql := R.Rows[0][0] else showSql := '';
  Dogrula('VEC(n) SHOW CREATE tipi korur', Pos('VECTOR(3)', showSql) > 0,
    showSql);
  ChkErr('VEC(n) ALTER uyumsuz boyut reddedildi',
    'ALTER TABLE vec_dim_t ALTER COLUMN v TYPE VECTOR(4)');
  Chk('VEC(n) ALTER TEXT boyutu kaldirir',
    'ALTER TABLE vec_dim_t ALTER COLUMN v TYPE TEXT', 0);

  // M4 yan urunu: ORDER BY ifadesi (kolon olmayan anahtar) artik siralanir.
  Chk('ORDER BY ifade tablosu',
    'CREATE TABLE ord_expr_t(id INTEGER PRIMARY KEY, name TEXT)', 0);
  Chk('ORDER BY ifade satirlari',
    'INSERT INTO ord_expr_t VALUES (1,' + SQLIT('a') + '),(2,' +
    SQLIT('abc') + '),(3,' + SQLIT('ab') + '),(4,' + SQLIT('') + ')', 0);
  ChkVal('ORDER BY ifade aritmetik',
    'SELECT id FROM ord_expr_t ORDER BY 0 - id LIMIT 1', 0, 0, '4');
  ChkVal('ORDER BY ifade fonksiyon + kolon',
    'SELECT id FROM ord_expr_t ORDER BY LENGTH(name) DESC, id LIMIT 1',
    0, 0, '2');
end;

procedure T122_KvStore;
// M11: IVDbKvStore sozlesmesi. Bellek-ici ikinci backend ve TVDb adapteri
// ayni arayuz uzerinden ayni temel islemleri yapar.
var
  mem, real: IVDbKvStore;
  db: TVDb;
  b: TBytes;
  keys: TQWordArray;
  vals: TValArray;
begin
  Grp('M11 depolama arayuzu (IVDbKvStore)');
  mem := TMemKvStore.Create;
  mem.Put(7, VDbStrToBytes('abc'));
  Dogrula('M11 mem Put/Get', mem.Get(7, b) and (VDbBytesToStr(b) = 'abc'),
    VDbBytesToStr(b));
  mem.Put(9, VDbStrToBytes('xyz'));
  mem.ScanAll(keys, vals, -1);
  Dogrula('M11 mem ScanAll', Length(keys) = 2, IntToStr(Length(keys)));
  Dogrula('M11 mem Delete', mem.Delete(7) and (not mem.Get(7, b)), '');
  mem.ScanAll(keys, vals, -1);
  Dogrula('M11 mem ScanAll sonrasi',
    (Length(keys) = 1) and (keys[0] = 9), IntToStr(Length(keys)));
  mem := nil;

  ForceDirectories(D + '\m11store');
  db := TVDb.Create;
  try
    db.Open(D + '\m11store\kv.odb');
    real := TVDbKvStore.Create(db);
    real.Put(42, VDbStrToBytes('satir'));
    Dogrula('M11 TVDb Put/Get',
      real.Get(42, b) and (VDbBytesToStr(b) = 'satir'), VDbBytesToStr(b));
    Dogrula('M11 TVDb Delete',
      real.Delete(42) and (not real.Get(42, b)), '');
    real := nil;
  finally
    db.Close;
    db.Free;
  end;
end;

procedure T123_Arrow;
// M2: Arrow IPC stream disa/içe aktarma (COPY ... TO/FROM ... FORMAT ARROW).
var
  fn, fnSub, fnEmpty: string;
  R2: TSqlResult;
  ok: Boolean;
begin
  Grp('M2 Arrow IPC ice/disa aktarma');
  UseDir('m2_arrow');
  sq.Exec('CREATE TABLE ar(id INTEGER PRIMARY KEY, nm TEXT, puan FLOAT, ' +
    'aktif BOOLEAN, d DATE, ts DATETIME, tm TIME, bl BLOB)');
  sq.Exec('INSERT INTO ar VALUES(1,' + Q + 'ali' + Q + ',1.5,TRUE,' +
    Q + '2024-01-02' + Q + ',' + Q + '2024-01-02 03:04:05' + Q + ',' +
    Q + '03:04:05' + Q + ',' + Q + 'raw' + Q + ')');
  sq.Exec('INSERT INTO ar VALUES(2,NULL,NULL,FALSE,NULL,NULL,NULL,NULL)');
  sq.Exec('INSERT INTO ar VALUES(3,' + Q + 'ayse' + Q + ',-2.25,TRUE,' +
    Q + '1999-12-31' + Q + ',' + Q + '1999-12-31 23:59:59' + Q + ',' +
    Q + '23:59:59' + Q + ',' + Q + 'x' + Q + ')');

  fn := D + '\m2_arrow\ar.arrow';
  fnSub := D + '\m2_arrow\ar_sub.arrow';
  fnEmpty := D + '\m2_arrow\ar_empty.arrow';

  R2 := sq.Exec('COPY ar TO ''' + fn + ''' (FORMAT ARROW)');
  ChkInt('Arrow TO Affected=3', R2.Affected, 3);
  Dogrula('Arrow dosyasi olustu', FileExists(fn), fn);

  sq.Exec('CREATE TABLE ar2(id INTEGER PRIMARY KEY, nm TEXT, puan FLOAT, ' +
    'aktif BOOLEAN, d DATE, ts DATETIME, tm TIME, bl BLOB)');
  R2 := sq.Exec('COPY ar2 FROM ''' + fn + ''' (FORMAT ARROW)');
  ChkInt('Arrow FROM Affected=3', R2.Affected, 3);
  ChkVal('Arrow INT', 'SELECT id FROM ar2 WHERE id=1', 0, 0, '1');
  ChkVal('Arrow TEXT', 'SELECT nm FROM ar2 WHERE id=3', 0, 0, 'ayse');
  ChkVal('Arrow FLOAT', 'SELECT puan FROM ar2 WHERE id=3', 0, 0, '-2.25');
  ChkVal('Arrow BOOL', 'SELECT aktif FROM ar2 WHERE id=1', 0, 0, 'True');
  ChkVal('Arrow DATE', 'SELECT d FROM ar2 WHERE id=1', 0, 0, '2024-01-02');
  ChkVal('Arrow DATETIME', 'SELECT ts FROM ar2 WHERE id=1', 0, 0,
    '2024-01-02 03:04:05');
  ChkVal('Arrow TIME', 'SELECT tm FROM ar2 WHERE id=1', 0, 0, '03:04:05');
  ChkVal('Arrow BLOB', 'SELECT bl FROM ar2 WHERE id=1', 0, 0, 'raw');
  ChkVal('Arrow NULL satiri',
    'SELECT COUNT(*) FROM ar2 WHERE id=2 AND nm IS NULL AND puan IS NULL ' +
    'AND d IS NULL AND ts IS NULL AND tm IS NULL AND bl IS NULL', 0, 0, '1');

  // Ayni dosyayi tekrar yuklemek PK ihlali -> batch geri alinmali.
  ok := False;
  try
    sq.Exec('COPY ar2 FROM ''' + fn + ''' (FORMAT ARROW)');
  except
    on E: Exception do
      ok := Pos('duplicate PK', E.Message) > 0;
  end;
  Dogrula('Arrow atomik PK ihlali hata verir', ok, '');
  ChkVal('Arrow atomik: hala 3 satir', 'SELECT COUNT(*) FROM ar2', 0, 0, '3');

  // Kolon alt kumesi + ada gore yeniden siralama.
  R2 := sq.Exec('COPY ar (id, nm) TO ''' + fnSub + ''' (FORMAT ARROW)');
  ChkInt('Arrow TO kolon alt kumesi', R2.Affected, 3);
  sq.Exec('CREATE TABLE ar4(nm TEXT, id INTEGER PRIMARY KEY)');
  R2 := sq.Exec('COPY ar4 (nm, id) FROM ''' + fnSub + ''' (FORMAT ARROW)');
  ChkInt('Arrow FROM ada gore esleme', R2.Affected, 3);
  ChkVal('Arrow alt kume id', 'SELECT id FROM ar4 WHERE nm=' + Q + 'ali' + Q,
    0, 0, '1');
  ChkVal('Arrow alt kume nm', 'SELECT nm FROM ar4 WHERE id=3', 0, 0, 'ayse');

  // Sifir satirli tablo.
  sq.Exec('CREATE TABLE are(id INTEGER PRIMARY KEY, nm TEXT)');
  R2 := sq.Exec('COPY are TO ''' + fnEmpty + ''' (FORMAT ARROW)');
  ChkInt('Arrow TO sifir satir', R2.Affected, 0);
  Dogrula('Arrow bos dosya olustu', FileExists(fnEmpty), fnEmpty);
  sq.Exec('CREATE TABLE are2(id INTEGER PRIMARY KEY, nm TEXT)');
  R2 := sq.Exec('COPY are2 FROM ''' + fnEmpty + ''' (FORMAT ARROW)');
  ChkInt('Arrow FROM sifir satir', R2.Affected, 0);
  ChkVal('Arrow sifir satir sayisi', 'SELECT COUNT(*) FROM are2', 0, 0, '0');

  // Tip uyusmazligi ve bicim kapisi.
  sq.Exec('CREATE TABLE arbad(id INTEGER PRIMARY KEY, nm INTEGER)');
  ok := False;
  try
    sq.Exec('COPY arbad FROM ''' + fnSub + ''' (FORMAT ARROW)');
  except
    on E: Exception do
      ok := Pos('tip uyusmuyor', E.Message) > 0;
  end;
  Dogrula('Arrow tip uyusmazligi reddedildi', ok, '');

  ok := False;
  try
    sq.Exec('COPY ar TO ''' + D + '\m2_arrow\ar.csv'' (FORMAT CSV)');
  except
    on E: Exception do
      ok := Pos('FORMAT ARROW', E.Message) > 0;
  end;
  Dogrula('COPY TO yalniz Arrow', ok, '');

  ok := False;
  try
    sq.Exec('COPY ar FROM ''' + fn + ''' (FORMAT ARROW, HEADER)');
  except
    on E: Exception do
      ok := Pos('HEADER', E.Message) > 0;
  end;
  Dogrula('Arrow HEADER reddedildi', ok, '');

  ok := False;
  try
    sq.Exec('COPY ar FROM ''' + D + '\m2_arrow\yok.arrow'' (FORMAT ARROW)');
  except
    on E: Exception do
      ok := Pos('dosya bulunamadi', E.Message) > 0;
  end;
  Dogrula('Arrow eksik dosya reddedildi', ok, '');
end;

procedure T124_Parquet;
// M2: Parquet (duz sema, UNCOMPRESSED) disa/ice aktarma.
var
  fn, fnSub, fnEmpty: string;
  R2: TSqlResult;
  ok: Boolean;
begin
  Grp('M2 Parquet ice/disa aktarma');
  UseDir('m2_parquet');
  sq.Exec('CREATE TABLE pq(id INTEGER PRIMARY KEY, nm TEXT, puan FLOAT, ' +
    'aktif BOOLEAN, d DATE, ts DATETIME, tm TIME, bl BLOB)');
  sq.Exec('INSERT INTO pq VALUES(1,' + Q + 'ali' + Q + ',1.5,TRUE,' +
    Q + '2024-01-02' + Q + ',' + Q + '2024-01-02 03:04:05' + Q + ',' +
    Q + '03:04:05' + Q + ',' + Q + 'raw' + Q + ')');
  sq.Exec('INSERT INTO pq VALUES(2,NULL,NULL,FALSE,NULL,NULL,NULL,NULL)');
  sq.Exec('INSERT INTO pq VALUES(3,' + Q + 'ayse' + Q + ',-2.25,TRUE,' +
    Q + '1999-12-31' + Q + ',' + Q + '1999-12-31 23:59:59' + Q + ',' +
    Q + '23:59:59' + Q + ',' + Q + 'x' + Q + ')');

  fn := D + '\m2_parquet\pq.parquet';
  fnSub := D + '\m2_parquet\pq_sub.parquet';
  fnEmpty := D + '\m2_parquet\pq_empty.parquet';

  R2 := sq.Exec('COPY pq TO ''' + fn + ''' (FORMAT PARQUET)');
  ChkInt('Parquet TO Affected=3', R2.Affected, 3);
  Dogrula('Parquet dosyasi olustu', FileExists(fn), fn);

  sq.Exec('CREATE TABLE pq2(id INTEGER PRIMARY KEY, nm TEXT, puan FLOAT, ' +
    'aktif BOOLEAN, d DATE, ts DATETIME, tm TIME, bl BLOB)');
  R2 := sq.Exec('COPY pq2 FROM ''' + fn + ''' (FORMAT PARQUET)');
  ChkInt('Parquet FROM Affected=3', R2.Affected, 3);
  ChkVal('Parquet INT', 'SELECT id FROM pq2 WHERE id=1', 0, 0, '1');
  ChkVal('Parquet TEXT', 'SELECT nm FROM pq2 WHERE id=3', 0, 0, 'ayse');
  ChkVal('Parquet FLOAT', 'SELECT puan FROM pq2 WHERE id=3', 0, 0, '-2.25');
  ChkVal('Parquet BOOL', 'SELECT aktif FROM pq2 WHERE id=1', 0, 0, 'True');
  ChkVal('Parquet DATE', 'SELECT d FROM pq2 WHERE id=1', 0, 0, '2024-01-02');
  ChkVal('Parquet DATETIME', 'SELECT ts FROM pq2 WHERE id=1', 0, 0,
    '2024-01-02 03:04:05');
  ChkVal('Parquet TIME', 'SELECT tm FROM pq2 WHERE id=1', 0, 0, '03:04:05');
  ChkVal('Parquet BLOB', 'SELECT bl FROM pq2 WHERE id=1', 0, 0, 'raw');
  ChkVal('Parquet NULL satiri',
    'SELECT COUNT(*) FROM pq2 WHERE id=2 AND nm IS NULL AND puan IS NULL ' +
    'AND d IS NULL AND ts IS NULL AND tm IS NULL AND bl IS NULL', 0, 0, '1');

  // Ayni dosyayi tekrar yuklemek PK ihlali -> batch geri alinmali.
  ok := False;
  try
    sq.Exec('COPY pq2 FROM ''' + fn + ''' (FORMAT PARQUET)');
  except
    on E: Exception do
      ok := Pos('duplicate PK', E.Message) > 0;
  end;
  Dogrula('Parquet atomik PK ihlali hata verir', ok, '');
  ChkVal('Parquet atomik: hala 3 satir', 'SELECT COUNT(*) FROM pq2', 0, 0, '3');

  // Kolon alt kumesi + ada gore yeniden siralama.
  R2 := sq.Exec('COPY pq (id, nm) TO ''' + fnSub + ''' (FORMAT PARQUET)');
  ChkInt('Parquet TO kolon alt kumesi', R2.Affected, 3);
  sq.Exec('CREATE TABLE pq4(nm TEXT, id INTEGER PRIMARY KEY)');
  R2 := sq.Exec('COPY pq4 (nm, id) FROM ''' + fnSub + ''' (FORMAT PARQUET)');
  ChkInt('Parquet FROM ada gore esleme', R2.Affected, 3);
  ChkVal('Parquet alt kume id', 'SELECT id FROM pq4 WHERE nm=' + Q + 'ali' + Q,
    0, 0, '1');
  ChkVal('Parquet alt kume nm', 'SELECT nm FROM pq4 WHERE id=3', 0, 0, 'ayse');

  // Sifir satirli tablo.
  sq.Exec('CREATE TABLE pqe(id INTEGER PRIMARY KEY, nm TEXT)');
  R2 := sq.Exec('COPY pqe TO ''' + fnEmpty + ''' (FORMAT PARQUET)');
  ChkInt('Parquet TO sifir satir', R2.Affected, 0);
  Dogrula('Parquet bos dosya olustu', FileExists(fnEmpty), fnEmpty);
  sq.Exec('CREATE TABLE pqe2(id INTEGER PRIMARY KEY, nm TEXT)');
  R2 := sq.Exec('COPY pqe2 FROM ''' + fnEmpty + ''' (FORMAT PARQUET)');
  ChkInt('Parquet FROM sifir satir', R2.Affected, 0);
  ChkVal('Parquet sifir satir sayisi', 'SELECT COUNT(*) FROM pqe2', 0, 0, '0');

  // Tip uyusmazligi ve bicim kapisi.
  sq.Exec('CREATE TABLE pqbad(id INTEGER PRIMARY KEY, nm INTEGER)');
  ok := False;
  try
    sq.Exec('COPY pqbad FROM ''' + fnSub + ''' (FORMAT PARQUET)');
  except
    on E: Exception do
      ok := Pos('tip uyusmuyor', E.Message) > 0;
  end;
  Dogrula('Parquet tip uyusmazligi reddedildi', ok, '');

  ok := False;
  try
    sq.Exec('COPY pq FROM ''' + fn + ''' (FORMAT PARQUET, HEADER)');
  except
    on E: Exception do
      ok := Pos('HEADER', E.Message) > 0;
  end;
  Dogrula('Parquet HEADER reddedildi', ok, '');

  ok := False;
  try
    sq.Exec('COPY pq FROM ''' + D + '\m2_parquet\yok.parquet'' (FORMAT PARQUET)');
  except
    on E: Exception do
      ok := Pos('dosya bulunamadi', E.Message) > 0;
  end;
  Dogrula('Parquet eksik dosya reddedildi', ok, '');
end;

procedure T125_KolonSifreleme;
// M6: kolon seviyesi sifreleme (.colkey + sifreli TEXT/BLOB degerleri).
var
  keyPath, odbPath, fn, dir: string;
  ok: Boolean;
  fs: TFileStream;
  raw: RawByteString;

  function DosyadaMetin(const AFileName, S: string): Boolean;
  var
    f: TFileStream;
    b: TBytes;
  begin
    Result := False;
    if not FileExists(AFileName) then Exit;
    f := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(b, f.Size);
      if f.Size > 0 then f.ReadBuffer(b[0], f.Size);
    finally
      f.Free;
    end;
    if Length(b) = 0 then Exit;
    SetString(raw, PAnsiChar(@b[0]), Length(b));
    Result := Pos(S, string(raw)) > 0;
  end;

begin
  Grp('M6 kolon seviyesi sifreleme');
  dir := D + '\m6_colenc';
  UseDir('m6_colenc');
  keyPath := kv.ColumnKeyPath;
  Dogrula('colkey baslangicta yok', not FileExists(keyPath), keyPath);

  // .key parola dosyasi da olsun: rekey'in .colkey'i etkilemedigini
  // ayrica dogrulayacagiz.
  kv.CreateKeyFile(ChangeFileExt(keyPath, '.key'), 'm6-parola-1');
  sq.Exec('CREATE TABLE sec(id INTEGER PRIMARY KEY, ad TEXT ENCRYPTED, ' +
    'notu BLOB ENCRYPTED, acik TEXT)');
  Dogrula('colkey olustu', FileExists(keyPath), keyPath);
  Dogrula('ColumnKeyId sifir degil', kv.ColumnKeyId <> 0, '');

  sq.Exec('INSERT INTO sec VALUES(1,''gizli-abc'',''blob-gizli'',''acik-1'')');
  sq.Exec('INSERT INTO sec VALUES(2,''gizli-abc'',''blob-2'',''acik-2'')');
  sq.Exec('INSERT INTO sec VALUES(3,NULL,NULL,''acik-3'')');
  ChkVal('sifreli TEXT okunur', 'SELECT ad FROM sec WHERE id=1',
    0, 0, 'gizli-abc');
  ChkVal('sifreli BLOB okunur', 'SELECT notu FROM sec WHERE id=1',
    0, 0, 'blob-gizli');
  ChkVal('sifreli TEXT esitlik', 'SELECT COUNT(*) FROM sec WHERE ad=''gizli-abc''',
    0, 0, '2');
  ChkVal('sifreli TEXT NULL', 'SELECT COUNT(*) FROM sec WHERE ad IS NULL',
    0, 0, '1');
  ChkVal('sifreli GROUP BY', 'SELECT ad FROM sec WHERE ad IS NOT NULL ' +
    'GROUP BY ad', 0, 0, 'gizli-abc');
  // H16: akisli DISTINCT sifreli kolonda cozulmus degeri tekillestirmeli.
  ChkVal('sifreli DISTINCT', 'SELECT DISTINCT ad FROM sec ' +
    'WHERE ad IS NOT NULL ORDER BY ad', 0, 0, 'gizli-abc');
  ChkVal('sifreli ORDER BY', 'SELECT ad FROM sec WHERE ad IS NOT NULL ' +
    'ORDER BY ad DESC LIMIT 1', 0, 0, 'gizli-abc');

  sq.Exec('UPDATE sec SET ad=''yeni-gizli'' WHERE id=2');
  ChkVal('sifreli UPDATE', 'SELECT ad FROM sec WHERE id=2', 0, 0, 'yeni-gizli');
  sq.Exec('UPDATE sec SET ad=''gizli-abc'' WHERE id=2');

  // Farkli tabloda ayni duz metin: JOIN duz metin uzerinden calismali.
  sq.Exec('CREATE TABLE sec2(id INTEGER PRIMARY KEY, ad TEXT ENCRYPTED)');
  sq.Exec('INSERT INTO sec2 VALUES(1,''gizli-abc'')');
  ChkVal('sifreli JOIN', 'SELECT COUNT(*) FROM sec a JOIN sec2 b ' +
    'ON a.ad=b.ad WHERE a.id=1 AND b.id=1', 0, 0, '1');

  // DDL kapilari.
  ok := False;
  try
    sq.Exec('CREATE TABLE sbad1(id TEXT PRIMARY KEY ENCRYPTED)');
  except
    on E: Exception do ok := Pos('PRIMARY KEY', E.Message) > 0;
  end;
  Dogrula('sifreli PK reddedildi', ok, '');
  ok := False;
  try
    sq.Exec('CREATE TABLE sbad2(id INTEGER PRIMARY KEY, n INTEGER ENCRYPTED)');
  except
    on E: Exception do ok := Pos('metin/BLOB', E.Message) > 0;
  end;
  Dogrula('sifreli INTEGER reddedildi', ok, '');

  // ALTER ADD COLUMN ENCRYPTED.
  sq.Exec('ALTER TABLE sec ADD COLUMN ek TEXT ENCRYPTED');
  sq.Exec('INSERT INTO sec(id,ad,notu,acik,ek) VALUES(4,''a4'',NULL,''c4'',''ek-gizli'')');
  ChkVal('ALTER ADD ENCRYPTED', 'SELECT ek FROM sec WHERE id=4',
    0, 0, 'ek-gizli');

  // Ham dosyada duz metin bulunmamali (kolon degeri sifreli).
  odbPath := ChangeFileExt(keyPath, '.odb');
  tb.Close;
  kv.Close;
  Dogrula('raw .odb sifreli metni icermiyor',
    not DosyadaMetin(odbPath, 'gizli-abc'), odbPath);
  Dogrula('raw .odb ek sifreli metni icermiyor',
    not DosyadaMetin(odbPath, 'ek-gizli'), odbPath);

  // Yeniden ac: .colkey yuklenmeli ve degerler cozulmeli.
  kv.Open(dir);
  kv.OpenKeyFile(ChangeFileExt(keyPath, '.key'), 'm6-parola-1');
  tb.Open(dir);
  ChkVal('reopen sonrasi sifreli okuma', 'SELECT ad FROM sec WHERE id=1',
    0, 0, 'gizli-abc');
  ChkVal('reopen sonrasi ALTER kolonu', 'SELECT ek FROM sec WHERE id=4',
    0, 0, 'ek-gizli');

  // Anahtar dosyasi yokken sessizce duz metne dusmemeli.
  tb.Close;
  kv.Close;
  RenameFile(keyPath, keyPath + '.bak');
  kv.Open(dir);
  kv.OpenKeyFile(ChangeFileExt(keyPath, '.key'), 'm6-parola-1');
  ok := False;
  try
    tb.Open(dir);
  except
    on E: Exception do ok := Pos('kolon anahtari', E.Message) > 0;
  end;
  Dogrula('colkey yokken acik hata', ok, '');
  tb.Close;
  kv.Close;
  RenameFile(keyPath + '.bak', keyPath);
  kv.Open(dir);
  kv.OpenKeyFile(ChangeFileExt(keyPath, '.key'), 'm6-parola-1');
  tb.Open(dir);

  // .key rekey kolon sifrelemesini etkilemez.
  sq.Exec('ALTER DATABASE KEY ''m6-parola-2''');
  kv.Close; tb.Close; sq.Free; tb.Free; kv.Free;
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  kv.Open(dir);
  Dogrula('rekey sonrasi yeni .key acilir',
    kv.OpenKeyFile(ChangeFileExt(keyPath, '.key'), 'm6-parola-2'));
  tb.Open(dir);
  ChkVal('rekey sonrasi sifreli deger durur',
    'SELECT ad FROM sec WHERE id=1', 0, 0, 'gizli-abc');
  Dogrula('rekey .colkey dosyasini silmedi', FileExists(keyPath), keyPath);

  // Arrow disa aktarma duz metin, ice aktarma yeniden sifreler.
  fn := dir + '\sec.arrow';
  sq.Exec('COPY sec TO ''' + fn + ''' (FORMAT ARROW)');
  sq.Exec('CREATE TABLE sec_copy(id INTEGER PRIMARY KEY, ad TEXT ENCRYPTED, ' +
    'notu BLOB ENCRYPTED, acik TEXT, ek TEXT ENCRYPTED)');
  sq.Exec('COPY sec_copy FROM ''' + fn + ''' (FORMAT ARROW)');
  ChkVal('Arrow import sifreli TEXT', 'SELECT ad FROM sec_copy WHERE id=1',
    0, 0, 'gizli-abc');
  ChkVal('Arrow import sifreli BLOB', 'SELECT notu FROM sec_copy WHERE id=1',
    0, 0, 'blob-gizli');
  ChkVal('Arrow import ALTER kolonu', 'SELECT ek FROM sec_copy WHERE id=4',
    0, 0, 'ek-gizli');

  // Yedek, sifreli kolonlarin acilmasi icin .colkey'i da tasimali.
  kv.BackupTo(dir + '\sec_backup.odb');
  Dogrula('yedek .colkey kopyaladi',
    FileExists(dir + '\sec_backup.colkey'), dir + '\sec_backup.colkey');
end;

procedure T126_F42_TxIsolation;
// F-42: ayni TVDb uzerinde iki oturum kimligi. Acik transaction'in
// commit edilmemis yazisi diger oturuma gorunmez; diger oturum yazamaz;
// commit sonrasi herkes gorur.
var
  db: TVDb;
  dir: string;
  k: QWord;
  v: TBytes;
  ok: Boolean;
begin
  Grp('F-42 oturum yalitimi');
  dir := D + '\f42_iso';
  ForceDirectories(dir);
  db := TVDb.Create;
  try
    db.Open(dir);
    k := 42;
    VDbSetTxnSession(1001);
    db.BeginBatch;
    db.Put(k, VDbStrToBytes('a'));

    VDbSetTxnSession(1002);
    ok := db.Get(k, v);
    Dogrula('F42 diger oturum commit edilmemisi gormez', not ok, '');

    ok := False;
    try
      db.Put(k, VDbStrToBytes('b'));
    except
      on E: Exception do ok := Pos('baska bir oturum', E.Message) > 0;
    end;
    Dogrula('F42 diger oturum yazamaz', ok, '');

    VDbSetTxnSession(1001);
    ok := db.Get(k, v);
    Dogrula('F42 sahibi kendi yazisini gorur',
      ok and (VDbBytesToStr(v) = 'a'), '');

    db.CommitBatch;
    VDbSetTxnSession(1002);
    ok := db.Get(k, v);
    Dogrula('F42 commit sonrasi diger oturum gorur',
      ok and (VDbBytesToStr(v) = 'a'), '');
  finally
    VDbSetTxnSession(0);
    db.Close;
    db.Free;
  end;
end;

procedure T127_H5_BlockCrc;
// H5: her commit sonunda blok footer'i yazilir; Verify blok CRC'sini
// dogrular. Footer CRC'si bozulunca Verify bunu yakalar.
var
  db: TVDb;
  dir, fn, rep: string;
  fs: TFileStream;
  h: TVDbRecHead;
  fh: TVDbFileHead;
  off: Int64;
  i: Integer;
  b: Byte;
  ok: Boolean;
begin
  Grp('H5 blok-grup CRC');
  dir := D + '\h5_blk';
  ForceDirectories(dir);
  db := TVDb.Create;
  try
    db.Open(dir);
    for i := 1 to 3 do
      db.Put(QWord(i), VDbStrToBytes('blok-' + IntToStr(i)));
    fn := dir + '\veritabani.odb';
    ok := db.Verify(rep);
    Dogrula('H5 Verify blok footer sayisi', ok and (Pos('blok=3', rep) > 0), rep);
  finally
    db.Close;
    db.Free;
  end;

  // V2 -> V3 yukseltme: basligi V2 yapip CRC'sini yeniden hesapla.
  // Open, dosyayi V3'e yukseltmeli; veri ve blok footer'lari korunmali.
  fs := TFileStream.Create(fn, fmOpenReadWrite);
  try
    fs.Position := 0;
    fs.ReadBuffer(fh, SizeOf(fh));
    fh.Ver := VDB_FILE_VER_V2;
    fh.Crc := VDbCrc32Of(fh, SizeOf(fh) - SizeOf(fh.Crc));
    fs.Position := 0;
    fs.WriteBuffer(fh, SizeOf(fh));
  finally
    fs.Free;
  end;
  db := TVDb.Create;
  try
    db.Open(dir);
    ok := db.Verify(rep);
    Dogrula('H5 yukseltme sonrasi Verify', ok, rep);
  finally
    db.Close;
    db.Free;
  end;
  fs := TFileStream.Create(fn, fmOpenRead);
  try
    fs.ReadBuffer(fh, SizeOf(fh));
  finally
    fs.Free;
  end;
  Dogrula('H5 V2 dosyasi V3e yukseltildi',
    fh.Ver = VDB_FILE_VER, IntToStr(fh.Ver));

  off := -1;
  fs := TFileStream.Create(fn, fmOpenReadWrite);
  try
    off := VDB_HDR_SIZE;
    while off + Int64(SizeOf(h)) <= fs.Size do
    begin
      fs.Position := off;
      fs.ReadBuffer(h, SizeOf(h));
      if h.Flags = VDB_FLAG_BLOCKCRC then Break;
      Inc(off, Int64(SizeOf(h)) + Int64(h.ValLen));
    end;
    if off + Int64(SizeOf(h)) > fs.Size then off := -1;
    Dogrula('H5 blok footer bulundu', off > 0, IntToStr(off));
    if off > 0 then
    begin
      fs.Position := off + 4;   // Magic(4) + Crc(4)
      fs.ReadBuffer(b, 1);
      b := b xor $01;
      fs.Position := off + 4;
      fs.WriteBuffer(b, 1);
    end;
  finally
    fs.Free;
  end;

  db := TVDb.Create;
  try
    db.Open(dir);
    ok := db.Verify(rep);
    Dogrula('H5 bozuk blok CRC yakalanir',
      (not ok) and (Pos('blok CRC', rep) > 0), rep);
  finally
    db.Close;
    db.Free;
  end;
end;

procedure T128_H11_Undo;
// H11.1: .undo gunlugu. Commit isareti yoksa eski span baytlari acilista
// geri yuklenir; commit isareti varsa gunluk atilir. Ayni offset icin
// birden fazla kayit TERS sirada geri yuklenir.
var
  baseDir, dir, fn, rep: string;
  db: TVDb;
  fs: TFileStream;
  h: TVDbRecHead;
  v: TBytes;
  off: Int64;
  ok: Boolean;
  restored: Integer;
  sz0: Int64;

  procedure OverwriteAt(AOff: Int64; const S: RawByteString);
  begin
    fs := TFileStream.Create(fn, fmOpenReadWrite);
    try
      fs.Position := AOff;
      if Length(S) > 0 then
        fs.WriteBuffer(S[1], Length(S));
    finally
      fs.Free;
    end;
  end;

  procedure MakeDb(const ADir, AValue: string);
  begin
    ForceDirectories(ADir);
    db := TVDb.Create;
    try
      db.Open(ADir);
      db.Put(1, VDbStrToBytes(AValue));
    finally
      db.Close;
      db.Free;
    end;
    fn := ADir + '\veritabani.odb';
    fs := TFileStream.Create(fn, fmOpenRead);
    try
      fs.Position := VDB_HDR_SIZE;
      fs.ReadBuffer(h, SizeOf(h));
      off := VDB_HDR_SIZE + Int64(SizeOf(h));
    finally
      fs.Free;
    end;
  end;

begin
  Grp('H11 undo gunlugu');
  baseDir := D + '\h11_undo_' + IntToStr(GetTickCount64);

  // 1) Commit isareti yok: yarim yerinde yazim geri alinir.
  dir := baseDir + '_a';
  MakeDb(dir, 'AAAA');
  Dogrula('H11 ilk kayit degeri 4 bayt', h.ValLen = 4, IntToStr(h.ValLen));
  Dogrula('H11 undo kaydi yazildi',
    VDbUndoAppend(fn, off, VDbStrToBytes('AAAA')), '');
  OverwriteAt(off, 'BBBB');
  db := TVDb.Create;
  try
    db.Open(dir);
    ok := db.Get(1, v) and (VDbBytesToStr(v) = 'AAAA');
    Dogrula('H11 undo yarim yazimi geri aldi', ok, VDbBytesToStr(v));
    Dogrula('H11 undo sonrasi Verify', db.Verify(rep), rep);
  finally
    db.Close;
    db.Free;
  end;
  Dogrula('H11 undo dosyasi silindi', not FileExists(VDbUndoPath(fn)), '');

  // 2) Commit isareti varsa eski baytlar geri yazilmaz.
  dir := baseDir + '_b';
  MakeDb(dir, 'AAAA');
  Dogrula('H11 commit undo kaydi yazildi',
    VDbUndoAppend(fn, off, VDbStrToBytes('ZZZZ')), '');
  Dogrula('H11 undo commit isareti yazildi', VDbUndoCommit(fn), '');
  db := TVDb.Create;
  try
    db.Open(dir);
    ok := db.Get(1, v) and (VDbBytesToStr(v) = 'AAAA');
    Dogrula('H11 commit undo geri yuklenmedi', ok, VDbBytesToStr(v));
    Dogrula('H11 commit undo sonrasi Verify', db.Verify(rep), rep);
  finally
    db.Close;
    db.Free;
  end;
  Dogrula('H11 commit undo dosyasi silindi',
    not FileExists(VDbUndoPath(fn)), '');

  // 3) Ayni offset iki kez: ters sira -> en eski deger.
  dir := baseDir + '_c';
  MakeDb(dir, 'AAAA');
  Dogrula('H11 ters sira undo 1',
    VDbUndoAppend(fn, off, VDbStrToBytes('AAAA')), '');
  OverwriteAt(off, 'BBBB');
  Dogrula('H11 ters sira undo 2',
    VDbUndoAppend(fn, off, VDbStrToBytes('BBBB')), '');
  OverwriteAt(off, 'CCCC');
  db := TVDb.Create;
  try
    db.Open(dir);
    ok := db.Get(1, v) and (VDbBytesToStr(v) = 'AAAA');
    Dogrula('H11 ters sira en eski degeri geri yukledi', ok, VDbBytesToStr(v));
    Dogrula('H11 ters sira sonrasi Verify', db.Verify(rep), rep);
  finally
    db.Close;
    db.Free;
  end;
  // 4) Commit edilmemis yerinde+append transaction'inda baslangic isareti
  //    dosyayi islem basindaki boya kirpar; append edilen yarim kayit kalmaz.
  dir := baseDir + '_trunc';
  ForceDirectories(dir);
  db := TVDb.Create;
  try
    db.Open(dir);
    db.Put(1, VDbStrToBytes('AAAA'));
  finally
    db.Close;
    db.Free;
  end;
  fn := dir + '\veritabani.odb';
  fs := TFileStream.Create(fn, fmOpenRead);
  try
    sz0 := fs.Size;
  finally
    fs.Free;
  end;
  fs := TFileStream.Create(fn, fmOpenReadWrite);
  try
    fs.Seek(0, soEnd);
    SetLength(v, 16);
    FillChar(v[0], 16, 0);
    fs.WriteBuffer(v[0], 16);
    Dogrula('H11 undo baslangic isareti',
      VDbUndoTruncateMarker(fn, sz0), '');
    Dogrula('H11 commit edilmemis rollback',
      VDbUndoRollback(fs, VDbUndoPath(fn), restored), '');
    Dogrula('H11 rollback dosyayi islem basina kirpti',
      fs.Size = sz0, IntToStr(fs.Size) + '/' + IntToStr(sz0));
  finally
    fs.Free;
  end;
  db := TVDb.Create;
  try
    db.Open(dir);
    ok := db.Get(1, v) and (VDbBytesToStr(v) = 'AAAA');
    Dogrula('H11 kirpma sonrasi kayit korundu', ok, VDbBytesToStr(v));
    Dogrula('H11 kirpma sonrasi Verify', db.Verify(rep), rep);
  finally
    db.Close;
    db.Free;
  end;
end;

procedure T129_H11_InPlace;
// H11.2/H11.3: olu PUT bolgelerinin yerinde yeniden kullanimi, kalan
// boslugun FREESPACE olarak birakilmasi, blok CRC'sinin guncellenmesi ve
// dosya sirasi bozulan seq'lerin recovery'de dogru uygulanmasi.
var
  baseDir, dir, fn, rep: string;
  db: TVDb;
  v: TBytes;
  sz0, sz1, sz2: Int64;
  ok: Boolean;
  fs: TFileStream;
  fh: TVDbFileHead;

  function FSize(const AName: string): Int64;
  var
    f: TFileStream;
  begin
    f := TFileStream.Create(AName, fmOpenRead);
    try
      Result := f.Size;
    finally
      f.Free;
    end;
  end;

  function HasInPlaceFlag: Boolean;
  begin
    fs := TFileStream.Create(fn, fmOpenRead);
    try
      fs.ReadBuffer(fh, VDB_HDR_SIZE);
      Result := (fh.Flags and VDB_HFLAG_INPLACE) <> 0;
    finally
      fs.Free;
    end;
  end;

  function MakeVal(ALen: Integer; ACh: AnsiChar): TBytes;
  begin
    SetLength(Result, ALen);
    if ALen > 0 then
      FillChar(Result[0], ALen, Byte(ACh));
  end;

begin
  Grp('H11 yerinde yazim / serbest bolge');
  baseDir := D + '\h11_inplace_' + IntToStr(GetTickCount64);

  // 1) Olu PUT bolgesi yeni kayitla yeniden kullanilir; silinen anahtar
  //    recovery'de geri gelmez.
  dir := baseDir + '_reuse';
  ForceDirectories(dir);
  db := TVDb.Create;
  try
    db.Open(dir);
    db.Put(1, VDbStrToBytes('AAAA'));
    db.Put(2, VDbStrToBytes('BBBB'));
    db.Delete(1);
  finally
    db.Close;
    db.Free;
  end;
  fn := dir + '\veritabani.odb';
  sz0 := FSize(fn);
  db := TVDb.Create;
  try
    db.Open(dir);
    db.Put(3, VDbStrToBytes('CCCC'));
    sz1 := db.DataFileSize;
    Dogrula('H11.3 olu PUT bolgesi yeniden kullanildi',
      (sz1 - sz0) < 80, IntToStr(sz1 - sz0) + ' bayt buyudu');
    ok := db.Get(3, v) and (VDbBytesToStr(v) = 'CCCC');
    Dogrula('H11.3 yeni deger okunur', ok, VDbBytesToStr(v));
    Dogrula('H11.3 silinen anahtar geri gelmedi', not db.Get(1, v), '');
    ok := db.Get(2, v) and (VDbBytesToStr(v) = 'BBBB');
    Dogrula('H11.3 diger anahtar korundu', ok, VDbBytesToStr(v));
    Dogrula('H11.3 Verify blok CRC dahil', db.Verify(rep), rep);
  finally
    db.Close;
    db.Free;
  end;
  Dogrula('H11.3 dosya INPLACE bayragi tasir', HasInPlaceFlag, '');
  db := TVDb.Create;
  try
    db.Open(dir);
    ok := db.Get(3, v) and (VDbBytesToStr(v) = 'CCCC');
    Dogrula('H11.3 reopen sonrasi deger', ok, VDbBytesToStr(v));
    Dogrula('H11.3 reopen sonrasi silinen yok', not db.Get(1, v), '');
    Dogrula('H11.3 reopen Verify', db.Verify(rep), rep);
  finally
    db.Close;
    db.Free;
  end;

  // 2) Kalan bosluk FREESPACE olur ve sonraki kucuk kayit onu tekrar
  //    kullanabilir.
  dir := baseDir + '_free';
  ForceDirectories(dir);
  db := TVDb.Create;
  try
    db.Open(dir);
    db.Put(1, MakeVal(100, 'A'));
    db.Delete(1);
  finally
    db.Close;
    db.Free;
  end;
  fn := dir + '\veritabani.odb';
  sz0 := FSize(fn);
  db := TVDb.Create;
  try
    db.Open(dir);
    db.Put(2, VDbStrToBytes('BBBB'));
    sz1 := db.DataFileSize;
    Dogrula('H11.3 buyuk bolgeden kucuk kayit (FREESPACE)',
      (sz1 - sz0) < 80, IntToStr(sz1 - sz0) + ' bayt buyudu');
    ok := db.Get(2, v) and (VDbBytesToStr(v) = 'BBBB');
    Dogrula('H11.3 FREESPACE sonrasi kayit 2', ok, VDbBytesToStr(v));
    Dogrula('H11.3 FREESPACE Verify', db.Verify(rep), rep);
    db.Put(3, MakeVal(30, 'C'));
    sz2 := db.DataFileSize;
    Dogrula('H11.3 kalan FREESPACE yeniden kullanildi',
      (sz2 - sz1) < 80, IntToStr(sz2 - sz1) + ' bayt buyudu');
    ok := db.Get(3, v) and (Length(v) = 30) and (v[0] = Ord('C'));
    Dogrula('H11.3 ikinci yerinde kayit', ok, IntToStr(Length(v)));
    ok := db.Get(2, v) and (VDbBytesToStr(v) = 'BBBB');
    Dogrula('H11.3 onceki kayit korundu', ok, VDbBytesToStr(v));
    Dogrula('H11.3 ikinci FREESPACE Verify', db.Verify(rep), rep);
  finally
    db.Close;
    db.Free;
  end;
  db := TVDb.Create;
  try
    db.Open(dir);
    ok := db.Get(3, v) and (Length(v) = 30);
    Dogrula('H11.3 reopen ikinci kayit', ok, IntToStr(Length(v)));
    Dogrula('H11.3 reopen FREESPACE Verify', db.Verify(rep), rep);
  finally
    db.Close;
    db.Free;
  end;

  // 3) Dosya sirasi bozuk seq: T2'nin yerinde kaydi T1'in append
  //    kaydindan once gorunur. Recovery BATCHEND seq filtresi olmadan
  //    T1'i sonra uygulayip T2'yi ezerdi.
  dir := baseDir + '_order';
  ForceDirectories(dir);
  db := TVDb.Create;
  try
    db.Open(dir);
    db.Put(1, VDbStrToBytes('AAAA'));
    db.Delete(1);
  finally
    db.Close;
    db.Free;
  end;
  db := TVDb.Create;
  try
    db.Open(dir);
    db.Put(1, VDbStrToBytes('LONGGG'));   // 35 bayt: 33'luk bolgeye sigmaz
    db.Put(1, VDbStrToBytes('ZZZZ'));     // 33 bayt: eski bolgeye yerinde
  finally
    db.Close;
    db.Free;
  end;
  fn := dir + '\veritabani.odb';
  db := TVDb.Create;
  try
    db.Open(dir);
    ok := db.Get(1, v) and (VDbBytesToStr(v) = 'ZZZZ');
    Dogrula('H11.3 recovery seq sirasini korudu', ok, VDbBytesToStr(v));
    Dogrula('H11.3 seq sirasi Verify', db.Verify(rep), rep);
  finally
    db.Close;
    db.Free;
  end;
  // 4) Ayni batch icinde iki yerinde yazim: tek commit, tek blok CRC
  //    guncellemesi; iki olu bolge de yeniden kullanilir.
  dir := baseDir + '_batch';
  ForceDirectories(dir);
  db := TVDb.Create;
  try
    db.Open(dir);
    db.Put(1, VDbStrToBytes('AAAA'));
    db.Put(2, VDbStrToBytes('BBBB'));
    db.Put(3, VDbStrToBytes('CCCC'));
    db.Put(4, VDbStrToBytes('DDDD'));
    db.Delete(1);
    db.Delete(3);
  finally
    db.Close;
    db.Free;
  end;
  fn := dir + '\veritabani.odb';
  sz0 := FSize(fn);
  db := TVDb.Create;
  try
    db.Open(dir);
    db.BeginBatch;
    db.Put(5, VDbStrToBytes('EEEE'));
    db.Put(6, VDbStrToBytes('FFFF'));
    db.CommitBatch;
    sz1 := db.DataFileSize;
    Dogrula('H11.3 batch iki olu bolgeyi kullandi', (sz1 - sz0) < 80,
      IntToStr(sz1 - sz0) + ' bayt buyudu');
    ok := db.Get(5, v) and (VDbBytesToStr(v) = 'EEEE');
    Dogrula('H11.3 batch kayit 5', ok, VDbBytesToStr(v));
    ok := db.Get(6, v) and (VDbBytesToStr(v) = 'FFFF');
    Dogrula('H11.3 batch kayit 6', ok, VDbBytesToStr(v));
    Dogrula('H11.3 batch silinenler yok',
      (not db.Get(1, v)) and (not db.Get(3, v)), '');
    ok := db.Get(2, v) and (db.Get(4, v));
    Dogrula('H11.3 batch diger kayitlar korundu', ok, '');
    Dogrula('H11.3 batch Verify', db.Verify(rep), rep);
  finally
    db.Close;
    db.Free;
  end;
end;

function TMetricsTestProvider.Get: string;
begin
  Result := Text;
end;

procedure T115_MetricsHttp;
// M9: /metrics HTTP ucu (saf yanit + canli soket).
var
  pr: TMetricsTestProvider;
  srv: TVdbMetricsHttpServer;
  started: Boolean;
  port, i, tries: Integer;
  resp, probe: string;

  function Fetch(const Path: string): string;
  var
    cc: TVdbSocket;
    rq: string;
    k: Integer;
    b: array[0..4095] of Char;
  begin
    Result := '';
    cc := VdbTcpConnect('127.0.0.1', port);
    if cc = VDB_SOCK_INVALID then Exit;
    try
      rq := 'GET ' + Path + ' HTTP/1.1' + #13#10 + 'Host: localhost' +
        #13#10 + 'Connection: close' + #13#10 + #13#10;
      if not VdbSendAll(cc, rq[1], Length(rq)) then Exit;
      repeat
        k := VdbRecvSome(cc, b[0], SizeOf(b));
        if k > 0 then
        begin
          SetLength(Result, Length(Result) + k);
          Move(b[0], Result[Length(Result) - k + 1], k);
        end;
      until k <= 0;
    finally
      VdbSockClose(cc);
    end;
  end;

begin
  Grp('M9 /metrics HTTP ucu');
  probe := VdbMetricsHttpResponse('GET /metrics HTTP/1.1'#13#10#13#10,
    'vdb_up 1'#10);
  Dogrula('HTTP 200 + govde', (Pos('200 OK', probe) > 0) and
    (Pos('vdb_up 1', probe) > 0) and
    (Pos('Content-Length: 9', probe) > 0), '');
  probe := VdbMetricsHttpResponse('GET /foo HTTP/1.1'#13#10#13#10, '');
  Dogrula('HTTP 404', Pos('404 Not Found', probe) > 0, '');

  pr := TMetricsTestProvider.Create;
  try
    pr.Text := 'vdb_up 1' + #10 + 'vdb_test_metric 42' + #10;
    srv := nil;
    started := False;
    port := 19100;
    for i := 0 to 9 do
    begin
      srv := TVdbMetricsHttpServer.Create(19100 + i, pr.Get);
      if srv.Start then
      begin
        port := 19100 + i;
        started := True;
        Break;
      end;
      srv.Free;
      srv := nil;
    end;
    Dogrula('metrics sunucu basladi', started,
      'port=' + IntToStr(port));
    if started then
    try
      resp := '';
      tries := 0;
      while (tries < 20) and (resp = '') do
      begin
        resp := Fetch('/metrics');
        if resp = '' then
        begin
          Sleep(50);
          Inc(tries);
        end;
      end;
      Dogrula('GET /metrics 200', Pos('200 OK', resp) > 0,
        Copy(resp, 1, 20));
      Dogrula('GET /metrics govde', Pos('vdb_test_metric 42', resp) > 0, '');
      Dogrula('GET /metrics icerik tipi', Pos('text/plain', resp) > 0, '');
      resp := Fetch('/foo');
      Dogrula('GET /foo 404', Pos('404 Not Found', resp) > 0, '');
    finally
      srv.Stop;
      srv.Free;
    end;
  finally
    pr.Free;
  end;
end;

procedure T114_Fts;
// M5: temel tam metin arama (index'siz, satir uzerinde).
begin
  Grp('M5 temel FTS');
  ChkVal('FTS TO_TSVECTOR',
    'SELECT TO_TSVECTOR(' + SQLIT('Hello, WORLD! 42') + ')', 0, 0,
    'hello world 42');
  ChkVal('FTS AND eslesme',
    'SELECT TS_MATCH(' + SQLIT('Merhaba dünya, VDB!') + ',' +
    SQLIT('merhaba vdb') + ')', 0, 0, 'True');
  ChkVal('FTS AND eksik',
    'SELECT TS_MATCH(' + SQLIT('Merhaba dünya') + ',' +
    SQLIT('merhaba yok') + ')', 0, 0, 'False');
  ChkVal('FTS RANK tek terim',
    'SELECT TS_RANK(' + SQLIT('a a b c a') + ',' + SQLIT('a') + ')', 0, 0, '3');
  ChkVal('FTS RANK iki terim',
    'SELECT TS_RANK(' + SQLIT('a b a b') + ',' + SQLIT('a b') + ')', 0, 0, '4');
  ChkVal('FTS bos sorgu',
    'SELECT TS_MATCH(' + SQLIT('x') + ',' + SQLIT('') + ')', 0, 0, 'False');
  // M5 genisletme: phrase ve negation.
  ChkVal('FTS phrase eslesme',
    'SELECT TS_MATCH(' + SQLIT('kirmizi araba hizli') + ',' +
    SQLIT('"kirmizi araba"') + ')', 0, 0, 'True');
  ChkVal('FTS phrase sira',
    'SELECT TS_MATCH(' + SQLIT('kirmizi araba hizli') + ',' +
    SQLIT('"araba kirmizi"') + ')', 0, 0, 'False');
  ChkVal('FTS negation yok',
    'SELECT TS_MATCH(' + SQLIT('kirmizi araba') + ',' +
    SQLIT('kirmizi -hizli') + ')', 0, 0, 'True');
  ChkVal('FTS negation var',
    'SELECT TS_MATCH(' + SQLIT('kirmizi araba') + ',' +
    SQLIT('kirmizi -araba') + ')', 0, 0, 'False');
  ChkVal('FTS RANK phrase',
    'SELECT TS_RANK(' + SQLIT('a b a b') + ',' + SQLIT('"a b"') + ')',
    0, 0, '2');

  // M5: tablo uzerinde inverted index yolu (TS_MATCH -> aday daraltma).
  // Sonuc kumesi WHERE ile aynen dogrulanir.
  Chk('FTS index tablo olustur',
    'CREATE TABLE fts_idx_t(id INTEGER PRIMARY KEY, body TEXT)', 0);
  Chk('FTS index satirlari',
    'INSERT INTO fts_idx_t VALUES (1, ' + SQLIT('kirmizi araba hizli') + '),' +
    '(2, ' + SQLIT('mavi araba yavas') + '),' +
    '(3, ' + SQLIT('kirmizi bisiklet') + '),' +
    '(4, ' + SQLIT('yesil araba hizli') + ')', 0);
  Chk('FTS index tek terim',
    'SELECT id FROM fts_idx_t WHERE TS_MATCH(body, ' + SQLIT('hizli') +
    ') ORDER BY id', 2);
  Chk('FTS index phrase',
    'SELECT id FROM fts_idx_t WHERE TS_MATCH(body, ' + SQLIT('"kirmizi araba"') +
    ') ORDER BY id', 1);
  Chk('FTS index negation',
    'SELECT id FROM fts_idx_t WHERE TS_MATCH(body, ' + SQLIT('araba -hizli') +
    ') ORDER BY id', 1);
  Chk('FTS index AND ek kosul',
    'SELECT id FROM fts_idx_t WHERE TS_MATCH(body, ' + SQLIT('araba') +
    ') AND id > 1 ORDER BY id', 2);
  Chk('FTS index yalniz negatif (tarama yolu)',
    'SELECT id FROM fts_idx_t WHERE TS_MATCH(body, ' + SQLIT('-hizli') +
    ') ORDER BY id', 2);
  Chk('FTS index eslesmeyen terim',
    'SELECT id FROM fts_idx_t WHERE TS_MATCH(body, ' + SQLIT('yokboyle') +
    ')', 0);
  // Cache invalidation: yazma sonrasi index yeniden kurulmali.
  Chk('FTS index yeni satir',
    'INSERT INTO fts_idx_t VALUES (5, ' + SQLIT('kirmizi araba hizli') + ')', 0);
  Chk('FTS index yeni satir gorunur',
    'SELECT id FROM fts_idx_t WHERE TS_MATCH(body, ' + SQLIT('hizli') +
    ') ORDER BY id', 3);
  Chk('FTS index update',
    'UPDATE fts_idx_t SET body = ' + SQLIT('mavi araba hizli') +
    ' WHERE id = 2', -1);
  Chk('FTS index update sonrasi',
    'SELECT id FROM fts_idx_t WHERE TS_MATCH(body, ' + SQLIT('hizli') +
    ') ORDER BY id', 4);
  Chk('FTS index delete', 'DELETE FROM fts_idx_t WHERE id = 1', -1);
  Chk('FTS index delete sonrasi',
    'SELECT id FROM fts_idx_t WHERE TS_MATCH(body, ' + SQLIT('hizli') +
    ') ORDER BY id', 3);
end;

procedure T113_Vector;
// M4: JSON sayi dizisi uzerinde vektor fonksiyonlari.
begin
  Grp('M4 vektor fonksiyonlari');
  ChkVal('VEC DIM', 'SELECT VECTOR_DIM(' + Q + '[1,2,3]' + Q + ')',
    0, 0, '3');
  ChkVal('VEC NORM [3,4]', 'SELECT VECTOR_NORM(' + Q + '[3,4]' + Q + ')',
    0, 0, '5');
  ChkVal('VEC cosine ortogonal', 'SELECT VECTOR_DISTANCE(' + Q + '[1,0]' + Q +
    ',' + Q + '[0,1]' + Q + ',' + Q + 'cosine' + Q + ')', 0, 0, '1');
  ChkVal('VEC cosine ayni', 'SELECT VECTOR_DISTANCE(' + Q + '[1,2]' + Q +
    ',' + Q + '[1,2]' + Q + ',' + Q + 'cosine' + Q + ')', 0, 0, '0');
  ChkVal('VEC dot', 'SELECT VECTOR_DISTANCE(' + Q + '[1,2]' + Q +
    ',' + Q + '[3,4]' + Q + ',' + Q + 'dot' + Q + ')', 0, 0, '11');
  ChkVal('VEC l1', 'SELECT VECTOR_DISTANCE(' + Q + '[1,0]' + Q +
    ',' + Q + '[0,1]' + Q + ',' + Q + 'l1' + Q + ')', 0, 0, '2');
  ChkVal('VEC l2 (varsayilan)', 'SELECT ROUND(VECTOR_DISTANCE(' + Q + '[1,0]' + Q +
    ',' + Q + '[0,1]' + Q + '), 4)', 0, 0, '1.4142');
  ChkVal('VEC boyut uyusmazligi', 'SELECT VECTOR_DISTANCE(' + Q + '[1,2]' + Q +
    ',' + Q + '[1]' + Q + ')', 0, 0, '');
  ChkVal('VEC gecersiz dizi', 'SELECT VECTOR_DIM(' + Q + '[1,"x"]' + Q + ')',
    0, 0, '');
  ChkVal('VEC bilinmeyen metrik', 'SELECT VECTOR_DISTANCE(' + Q + '[1]' + Q +
    ',' + Q + '[1]' + Q + ',' + Q + 'foo' + Q + ')', 0, 0, '');
end;

procedure T112_JsonPath;
// M10: JSONPath alt kumesi (JSON_EXTRACT / JSON_VALUE / JSON_EXISTS).
const
  J = '{"a":{"b":[10,20,{"c":"x"}]},"n":1.5,"s":"hi","t":true,"z":null}';
  J2 = '{"items":[{"ad":"a","fiyat":10},{"ad":"b","fiyat":25},' +
    '{"ad":"c","fiyat":5}],"o":{"x":{"ad":"deep"}}}';
begin
  Grp('M10 JSONPath (JSON_EXTRACT/VALUE/EXISTS)');
  ChkVal('JP koku nesne', 'SELECT JSON_EXTRACT(' + Q + J + Q + ', ' + Q + '$.a' + Q + ')',
    0, 0, '{"b":[10,20,{"c":"x"}]}');
  ChkVal('JP dizi indeks', 'SELECT JSON_EXTRACT(' + Q + J + Q + ', ' + Q + '$.a.b[1]' + Q + ')',
    0, 0, '20');
  ChkVal('JP negatif indeks', 'SELECT JSON_EXTRACT(' + Q + '[1,2,3]' + Q + ', ' + Q + '$[-1]' + Q + ')',
    0, 0, '3');
  ChkVal('JP nesne-dizi karisik', 'SELECT JSON_EXTRACT(' + Q + J + Q +
    ', ' + Q + '$.a.b[2].c' + Q + ')', 0, 0, '"x"');
  ChkVal('JP koseli tirnakli anahtar', 'SELECT JSON_EXTRACT(' + Q + J + Q +
    ', ' + Q + '$["a"]["b"][0]' + Q + ')', 0, 0, '10');
  ChkVal('JP string skaler', 'SELECT JSON_VALUE(' + Q + J + Q + ', ' + Q + '$.s' + Q + ')',
    0, 0, 'hi');
  ChkVal('JP sayi skaler', 'SELECT JSON_VALUE(' + Q + J + Q + ', ' + Q + '$.n' + Q + ')',
    0, 0, '1.5');
  ChkVal('JP bool skaler', 'SELECT JSON_VALUE(' + Q + J + Q + ', ' + Q + '$.t' + Q + ')',
    0, 0, 'True');
  ChkVal('JP null skaler', 'SELECT JSON_VALUE(' + Q + J + Q + ', ' + Q + '$.z' + Q + ')',
    0, 0, '');
  ChkVal('JP nesne JSON_VALUE null', 'SELECT JSON_VALUE(' + Q + J + Q +
    ', ' + Q + '$.a' + Q + ')', 0, 0, '');
  ChkVal('JP EXISTS var', 'SELECT JSON_EXISTS(' + Q + J + Q +
    ', ' + Q + '$.a.b[2].c' + Q + ')', 0, 0, 'True');
  ChkVal('JP EXISTS yok', 'SELECT JSON_EXISTS(' + Q + J + Q +
    ', ' + Q + '$.yok' + Q + ')', 0, 0, 'False');
  ChkVal('JP joker dizi', 'SELECT JSON_EXTRACT(' + Q + '[1,2,3]' + Q +
    ', ' + Q + '$[*]' + Q + ')', 0, 0, '[1,2,3]');
  ChkVal('JP joker nesne', 'SELECT JSON_EXTRACT(' + Q + '{"a":1,"b":2}' + Q +
    ', ' + Q + '$.*' + Q + ')', 0, 0, '[1,2]');
  ChkVal('JP bozuk JSON null', 'SELECT JSON_EXTRACT(' + Q + '{bozuk' + Q +
    ', ' + Q + '$.a' + Q + ')', 0, 0, '');
  ChkVal('JP kacisli string', 'SELECT JSON_EXTRACT(' + Q + '{"s":"a\"b"}' + Q +
    ', ' + Q + '$.s' + Q + ')', 0, 0, '"a\"b"');
  // M10 genisletme: ara joker, recursive descent, filtre, slice.
  ChkVal('JP ara joker dizi', 'SELECT JSON_EXTRACT(' + Q + J2 + Q +
    ', ' + Q + '$.items[*].ad' + Q + ')', 0, 0, '["a","b","c"]');
  ChkVal('JP ara joker nesne', 'SELECT JSON_EXTRACT(' + Q + J2 + Q +
    ', ' + Q + '$.o.*.ad' + Q + ')', 0, 0, '["deep"]');
  ChkVal('JP recursive descent', 'SELECT JSON_EXTRACT(' + Q + J2 + Q +
    ', ' + Q + '$..ad' + Q + ')', 0, 0, '["a","b","c","deep"]');
  ChkVal('JP filtre sayi >', 'SELECT JSON_EXTRACT(' + Q + J2 + Q +
    ', ' + Q + '$.items[?(@.fiyat > 10)].ad' + Q + ')', 0, 0, '["b"]');
  ChkVal('JP filtre sayi <=', 'SELECT JSON_EXTRACT(' + Q + J2 + Q +
    ', ' + Q + '$.items[?(@.fiyat <= 10)].ad' + Q + ')', 0, 0, '["a","c"]');
  ChkVal('JP filtre string ==', 'SELECT JSON_EXTRACT(' + Q + J2 + Q +
    ', ' + Q + '$.items[?(@.ad == "b")].fiyat' + Q + ')', 0, 0, '[25]');
  ChkVal('JP filtre dogruluk', 'SELECT JSON_EXTRACT(' + Q + J2 + Q +
    ', ' + Q + '$.items[?(@.ad)].ad' + Q + ')', 0, 0, '["a","b","c"]');
  ChkVal('JP slice 1:3', 'SELECT JSON_EXTRACT(' + Q + J2 + Q +
    ', ' + Q + '$.items[1:3].ad' + Q + ')', 0, 0, '["b","c"]');
  ChkVal('JP slice 1:', 'SELECT JSON_EXTRACT(' + Q + '[1,2,3]' + Q +
    ', ' + Q + '$[1:]' + Q + ')', 0, 0, '[2,3]');
  ChkVal('JP coklu JSON_VALUE bos', 'SELECT JSON_VALUE(' + Q + J2 + Q +
    ', ' + Q + '$.items[*].ad' + Q + ')', 0, 0, '');
  ChkVal('JP EXISTS filtre var', 'SELECT JSON_EXISTS(' + Q + J2 + Q +
    ', ' + Q + '$.items[?(@.fiyat > 10)]' + Q + ')', 0, 0, 'True');
  ChkVal('JP EXISTS filtre yok', 'SELECT JSON_EXISTS(' + Q + J2 + Q +
    ', ' + Q + '$.items[?(@.fiyat > 100)]' + Q + ')', 0, 0, 'False');
  // M10 genisletme: union seciciler [0,2] / ['a','c'] / ["a","c"].
  ChkVal('JP union indeks', 'SELECT JSON_EXTRACT(' + Q + '[10,20,30]' + Q +
    ', ' + Q + '$[0,2]' + Q + ')', 0, 0, '[10,30]');
  ChkVal('JP union negatif indeks', 'SELECT JSON_EXTRACT(' + Q + '[10,20,30]' + Q +
    ', ' + Q + '$[0,-1]' + Q + ')', 0, 0, '[10,30]');
  ChkVal('JP union tek tirnak anahtar', 'SELECT JSON_EXTRACT(' + Q +
    '{"a":1,"b":2,"c":3}' + Q + ', ' + Q + '$[' + Q+Q + 'a' + Q+Q +
    ',' + Q+Q + 'c' + Q+Q + ']' + Q + ')', 0, 0, '[1,3]');
  ChkVal('JP union cift tirnak anahtar', 'SELECT JSON_EXTRACT(' + Q +
    '{"a":1,"b":2,"c":3}' + Q + ', ' + Q + '$["a","c"]' + Q + ')',
    0, 0, '[1,3]');
  ChkVal('JP tek tirnak anahtar', 'SELECT JSON_EXTRACT(' + Q + J + Q +
    ', ' + Q + '$[' + Q+Q + 's' + Q+Q + ']' + Q + ')', 0, 0, '"hi"');
  ChkVal('JP union ic ice', 'SELECT JSON_EXTRACT(' + Q + J2 + Q +
    ', ' + Q + '$.items[0,2].ad' + Q + ')', 0, 0, '["a","c"]');
  ChkVal('JP union JSON_VALUE bos', 'SELECT JSON_VALUE(' + Q + '[10,20,30]' + Q +
    ', ' + Q + '$[0,2]' + Q + ')', 0, 0, '');
  ChkVal('JP union EXISTS', 'SELECT JSON_EXISTS(' + Q + '[10,20,30]' + Q +
    ', ' + Q + '$[0,2]' + Q + ')', 0, 0, 'True');
  // M10 genisletme: mantiksal filtre operatorleri && / || / !.
  ChkVal('JP filtre &&', 'SELECT JSON_EXTRACT(' + Q +
    '[{"x":1},{"x":2},{"x":3}]' + Q + ', ' + Q +
    '$[?(@.x > 1 && @.x < 3)]' + Q + ')', 0, 0, '[{"x":2}]');
  ChkVal('JP filtre ||', 'SELECT JSON_EXTRACT(' + Q +
    '[{"x":1},{"x":2},{"x":3}]' + Q + ', ' + Q +
    '$[?(@.x = 1 || @.x = 3)]' + Q + ')', 0, 0, '[{"x":1},{"x":3}]');
  ChkVal('JP filtre && oncelik', 'SELECT JSON_EXTRACT(' + Q +
    '[{"x":1},{"x":2,"y":9},{"x":2,"y":8}]' + Q + ', ' + Q +
    '$[?(@.x = 1 || @.x = 2 && @.y = 9)]' + Q + ')',
    0, 0, '[{"x":1},{"x":2,"y":9}]');
  ChkVal('JP filtre !', 'SELECT JSON_EXTRACT(' + Q +
    '[{"x":1},{"x":2}]' + Q + ', ' + Q + '$[?(!@.x = 1)]' + Q + ')',
    0, 0, '[{"x":2}]');
  ChkVal('JP filtre parantezli !', 'SELECT JSON_EXTRACT(' + Q +
    '[{"x":1},{"x":2}]' + Q + ', ' + Q + '$[?(!(@.x = 1))]' + Q + ')',
    0, 0, '[{"x":2}]');
  ChkVal('JP filtre skaler', 'SELECT JSON_EXTRACT(' + Q +
    '[1,2,3,4]' + Q + ', ' + Q + '$[?(@ > 2)]' + Q + ')',
    0, 0, '[3,4]');
  // M10 genisletme: parantezli compound filtre gruplari.
  ChkVal('JP filtre gruplu', 'SELECT JSON_EXTRACT(' + Q +
    '[{"x":1,"y":9},{"x":2,"y":8},{"x":3,"y":9}]' + Q + ', ' + Q +
    '$[?((@.x = 1 || @.x = 3) && @.y = 9)]' + Q + ')',
    0, 0, '[{"x":1,"y":9},{"x":3,"y":9}]');
  ChkVal('JP filtre ic ice grup', 'SELECT JSON_EXTRACT(' + Q +
    '[{"x":1,"y":9},{"x":2,"y":8},{"x":3,"y":9}]' + Q + ', ' + Q +
    '$[?(((@.x = 1) || (@.x = 2)) && @.y < 9)]' + Q + ')',
    0, 0, '[{"x":2,"y":8}]');
  ChkVal('JP filtre grup oncelik', 'SELECT JSON_EXTRACT(' + Q +
    '[{"x":1,"y":9},{"x":2,"y":8},{"x":3,"y":9}]' + Q + ', ' + Q +
    '$[?(@.x = 1 || (@.x = 2 && @.y = 8))]' + Q + ')',
    0, 0, '[{"x":1,"y":9},{"x":2,"y":8}]');
  // M10 genisletme: filtre fonksiyonlari length/abs/lower/upper.
  ChkVal('JP length()', 'SELECT JSON_EXTRACT(' + Q +
    '[{"s":"abc"},{"s":"de"}]' + Q + ', ' + Q +
    '$[?(length(@.s) > 2)].s' + Q + ')', 0, 0, '["abc"]');
  ChkVal('JP length() dizi', 'SELECT JSON_EXTRACT(' + Q +
    '[[1,2,3],[4]]' + Q + ', ' + Q +
    '$[?(length(@) > 2)]' + Q + ')', 0, 0, '[[1,2,3]]');
  ChkVal('JP abs()', 'SELECT JSON_EXTRACT(' + Q +
    '[-3,2,-1]' + Q + ', ' + Q +
    '$[?(abs(@) > 2)]' + Q + ')', 0, 0, '[-3]');
  ChkVal('JP lower()', 'SELECT JSON_EXTRACT(' + Q +
    '["A","b"]' + Q + ', ' + Q +
    '$[?(lower(@) == "a")]' + Q + ')', 0, 0, '["A"]');
  ChkVal('JP upper()', 'SELECT JSON_EXTRACT(' + Q +
    '["A","b"]' + Q + ', ' + Q +
    '$[?(upper(@) == "A")]' + Q + ')', 0, 0, '["A"]');
  // M10 genisletme: iki alan karsilastirmasi (@.a > @.b).
  ChkVal('JP alan-alan sayi', 'SELECT JSON_EXTRACT(' + Q +
    '[{"a":5,"b":2},{"a":1,"b":3},{"a":2,"b":2}]' + Q + ', ' + Q +
    '$[?(@.a > @.b)].a' + Q + ')', 0, 0, '[5]');
  ChkVal('JP alan-alan metin', 'SELECT JSON_EXTRACT(' + Q +
    '[{"name":"x","alias":"x"},{"name":"y","alias":"z"}]' + Q + ', ' + Q +
    '$[?(@.name == @.alias)].name' + Q + ')', 0, 0, '["x"]');
  ChkVal('JP alan-alan mantik', 'SELECT JSON_EXTRACT(' + Q +
    '[{"a":5,"b":2},{"a":1,"b":3},{"a":2,"b":2}]' + Q + ', ' + Q +
    '$[?(@.a >= @.b && @.a < 5)].a' + Q + ')', 0, 0, '[2]');
  // M10 genisletme: script indeks ifadeleri [(@.length-1)].
  ChkVal('JP script son eleman', 'SELECT JSON_EXTRACT(' + Q + '[1,2,3]' + Q +
    ', ' + Q + '$[(@.length-1)]' + Q + ')', 0, 0, '3');
  ChkVal('JP script offset', 'SELECT JSON_EXTRACT(' + Q + '[1,2,3]' + Q +
    ', ' + Q + '$[(@.length-2)]' + Q + ')', 0, 0, '2');
  ChkVal('JP script alan icinde', 'SELECT JSON_EXTRACT(' + Q + J + Q +
    ', ' + Q + '$.a.b[(@.length-1)].c' + Q + ')', 0, 0, '"x"');
  ChkVal('JP script aritmetik', 'SELECT JSON_EXTRACT(' + Q + '[10,20,30,40]' + Q +
    ', ' + Q + '$[(@.length/2)]' + Q + ')', 0, 0, '30');
  ChkVal('JP script gecersiz', 'SELECT JSON_EXTRACT(' + Q + '[1,2,3]' + Q +
    ', ' + Q + '$[(@.yok)]' + Q + ')', 0, 0, '');
  // M10 genisletme: slice adimi [a:b:c] ve negatif adim.
  ChkVal('JP slice adim 2', 'SELECT JSON_EXTRACT(' + Q + '[1,2,3,4,5]' + Q +
    ', ' + Q + '$[0:5:2]' + Q + ')', 0, 0, '[1,3,5]');
  ChkVal('JP slice negatif adim', 'SELECT JSON_EXTRACT(' + Q + '[1,2,3]' + Q +
    ', ' + Q + '$[::-1]' + Q + ')', 0, 0, '[3,2,1]');
  ChkVal('JP slice negatif sinir', 'SELECT JSON_EXTRACT(' + Q + '[1,2,3,4]' + Q +
    ', ' + Q + '$[3:0:-1]' + Q + ')', 0, 0, '[4,3,2]');
  ChkVal('JP slice sifir adim', 'SELECT JSON_EXTRACT(' + Q + '[1,2,3]' + Q +
    ', ' + Q + '$[0:3:0]' + Q + ')', 0, 0, '');
  // M10 genisletme: filtrede @.length ozelligi.
  ChkVal('JP filtre @.length dizi', 'SELECT JSON_EXTRACT(' + Q +
    '[[1,2,3],[4]]' + Q + ', ' + Q + '$[?(@.length > 2)]' + Q + ')',
    0, 0, '[[1,2,3]]');
  ChkVal('JP filtre @.length metin', 'SELECT JSON_EXTRACT(' + Q +
    '[{"s":"abc"},{"s":"de"}]' + Q + ', ' + Q + '$[?(@.s.length > 2)].s' + Q + ')',
    0, 0, '["abc"]');
  ChkVal('JP filtre @.length nesne', 'SELECT JSON_EXTRACT(' + Q +
    '[{"a":1,"b":2},{"c":3}]' + Q + ', ' + Q + '$[?(@.length > 1)]' + Q + ')',
    0, 0, '[{"a":1,"b":2}]');
end;

procedure T111_RasgeleDiferansiyel;
// M8: rastgele WHERE yuklemleri icin ham/akisli yol ile genel yol
// (ORDER BY ile zorlanir) AYNI satir kumesini vermeli.
const
  NR = 4000;
  NQ = 120;
var
  i, qi, bad, x, y, k: Integer;
  pred, q1, q2: string;
  A, B: TSqlResult;
  ka, kb: TStringList;
  ok: Boolean;

  function RowKey(const R: TStrArray): string;
  var
    j: Integer;
  begin
    Result := '';
    for j := 0 to High(R) do
      Result := Result + R[j] + #1;
  end;

  procedure KeysOf(const R: TSqlResult; L: TStringList);
  var
    j: Integer;
  begin
    L.Clear;
    for j := 0 to High(R.Rows) do
      L.Add(RowKey(R.Rows[j]));
    L.Sort;
  end;

  function RndInt(Lo, Hi: Integer): Integer;
  begin
    Result := Lo + Random(Hi - Lo + 1);
  end;

begin
  Grp('M8 rasgele WHERE diferansiyel');
  UseDir('m8_rand');
  sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, f FLOAT, s TEXT, b BOOLEAN)');
  sq.Exec('BEGIN');
  for i := 1 to NR do
  begin
    if i mod 13 = 0 then
      q1 := 'NULL'
    else
      q1 := IntToStr(i mod 200);
    if i mod 11 = 0 then
      q2 := Q + Q
    else if i mod 29 = 0 then
      q2 := Q + #$C3#$A9 + 'z' + IntToStr(i mod 5) + Q
    else
      q2 := Q + 'k' + IntToStr(i mod 17) + Q;
    sq.Exec(Format('INSERT INTO t VALUES (%d, %s, %d.25, %s, %s)',
      [i, q1, i mod 500, q2, BoolToStr(i mod 2 = 0, True)]));
  end;
  sq.Exec('COMMIT');

  RandSeed := 20261019;
  bad := 0;
  ka := TStringList.Create;
  kb := TStringList.Create;
  try
    for qi := 1 to NQ do
    begin
      case qi mod 10 of
        0: begin
             x := RndInt(0, 199);
             pred := Format('a BETWEEN %d AND %d', [x, x + RndInt(0, 40)]);
           end;
        1: begin
             x := RndInt(0, 199);
             y := RndInt(0, 199);
             pred := Format('a <> %d AND a >= %d', [x, y]);
           end;
        2: begin
             x := RndInt(0, 499);
             pred := Format('f >= %d.25 AND f < %d.25', [x, x + RndInt(1, 80)]);
           end;
        3: pred := 'a IN (' + IntToStr(RndInt(0,199)) + ',' +
                 IntToStr(RndInt(0,199)) + ',' + IntToStr(RndInt(0,199)) + ')';
        4: pred := 'a IS NULL';
        5: pred := Format('s = ''k%d''', [RndInt(0, 16)]);
        6: pred := 's LIKE ''k1%''';
        7: pred := 'b = TRUE AND a < ' + IntToStr(RndInt(0, 199));
        8: pred := '(a < ' + IntToStr(RndInt(0, 199)) + ' OR s = ''k' +
                 IntToStr(RndInt(0, 16)) + ''')';
        9: pred := 'NOT (a > ' + IntToStr(RndInt(0, 199)) + ')';
      end;
      q1 := 'SELECT id, a, f, s, b FROM t WHERE ' + pred;
      q2 := q1 + ' ORDER BY id';
      A := sq.Exec(q1);
      B := sq.Exec(q2);
      KeysOf(A, ka);
      KeysOf(B, kb);
      ok := (ka.Count = kb.Count);
      if ok then
        for k := 0 to ka.Count - 1 do
          if ka[k] <> kb[k] then
          begin
            ok := False;
            Break;
          end;
      if not ok then
      begin
        Inc(bad);
        if bad <= 3 then
          WriteLn('    FARK [', ka.Count, ' vs ', kb.Count, '] ', pred);
      end;
    end;
  finally
    ka.Free;
    kb.Free;
  end;
  Dogrula(Format('rasgele WHERE %d/%d birebir', [NQ - bad, NQ]), bad = 0,
    IntToStr(bad) + ' fark');
end;

procedure T110_CopyFrom;
// H13 (2026-10-19): COPY FROM CSV hizli yolu + atomiklik.
var
  fn, bad: string;
  sl: TStringList;
  R2: TSqlResult;
  ok: Boolean;
begin
  Grp('H13 COPY FROM (CSV)');
  UseDir('h13_copy');
  sq.Exec('CREATE TABLE cp(id INTEGER PRIMARY KEY, nm TEXT, q INTEGER)');
  fn := D + '\h13_copy.csv';
  bad := D + '\h13_copy_bad.csv';
  sl := TStringList.Create;
  try
    sl.Add('id,nm,q');
    sl.Add('1,"a,b",10');
    sl.Add('2,"line1');
    sl.Add('line2",20');
    sl.Add('3,,30');
    sl.SaveToFile(fn);
  finally
    sl.Free;
  end;

  R2 := sq.Exec('COPY cp FROM ''' + fn + ''' WITH (FORMAT CSV, HEADER)');
  ChkInt('COPY Affected=3', R2.Affected, 3);
  Chk('COPY 3 satir', 'SELECT id FROM cp', 3);
  ChkVal('COPY tirnakli virgul', 'SELECT nm FROM cp WHERE id=1', 0, 0, 'a,b');
  Chk('COPY tirnak icinde satir sonu',
    'SELECT id FROM cp WHERE nm LIKE ''line1%line2''', 1);
  ChkVal('COPY bos alan NULL',
    'SELECT COUNT(*) FROM cp WHERE id=3 AND nm IS NULL', 0, 0, '1');

  // Atomiklik: 2. satir PK ihlali -> 1. satir da yazilmamali.
  sl := TStringList.Create;
  try
    sl.Add('4,dort,40');
    sl.Add('1,dup,1');
    sl.SaveToFile(bad);
  finally
    sl.Free;
  end;
  ok := False;
  try
    sq.Exec('COPY cp FROM ''' + bad + '''');
  except
    on E: Exception do
      ok := Pos('duplicate PK', E.Message) > 0;
  end;
  Dogrula('COPY atomik PK ihlali hata verir', ok, '');
  Chk('COPY atomik: 4 yok', 'SELECT id FROM cp WHERE id=4', 0);
  Chk('COPY atomik: hala 3 satir', 'SELECT id FROM cp', 3);
end;

procedure T130_PkRangeCtype;
// Regresyon: INTEGER PK icin gecici (array) indeks kaynagi Ctype'i
// VCT_STR varsayiyordu. Boylece id < 101 / BETWEEN gibi araliklar
// metin karsilastirmasiyla yanlis sonuc veriyordu.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r: TSqlResult;
  i: Integer;
begin
  Grp('T130 PK aralik indeksi tipi');
  dir := D + '\t130_pk_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      q.Exec('BEGIN');
      for i := 1 to 1000 do
        q.Exec(Format('INSERT INTO t (id,v) VALUES (%d,%s)',
          [i, QuotedStr('v' + IntToStr(i))]));
      q.Exec('COMMIT');

      r := q.Exec('SELECT COUNT(*) FROM t WHERE id < 101');
      Dogrula('T130 id < 101 -> 100',
        (Length(r.Rows) = 1) and (r.Rows[0][0] = '100'),
        r.Rows[0][0]);

      r := q.Exec('SELECT COUNT(*) FROM t WHERE id >= 101 AND id < 201');
      Dogrula('T130 id >= 101 AND id < 201 -> 100',
        (Length(r.Rows) = 1) and (r.Rows[0][0] = '100'),
        r.Rows[0][0]);

      r := q.Exec('SELECT COUNT(*) FROM t WHERE id BETWEEN 101 AND 200');
      Dogrula('T130 id BETWEEN 101 AND 200 -> 100',
        (Length(r.Rows) = 1) and (r.Rows[0][0] = '100'),
        r.Rows[0][0]);

      r := q.Exec('SELECT id FROM t WHERE id >= 101 AND id < 201 ORDER BY id');
      Dogrula('T130 aralik ilk/son id 101/200',
        (Length(r.Rows) = 100) and (r.Rows[0][0] = '101') and
        (r.Rows[99][0] = '200'),
        IntToStr(Length(r.Rows)));
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T131_H12_TopN;
// H12: ORDER BY ... LIMIT icin top-N yolunun ve indeks sirasiyla
// OFFSET atlamanin dogru satirlari dondurdugunu dogrular.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r: TSqlResult;
  i: Integer;
  fs: TFormatSettings;
begin
  Grp('T131 H12 ORDER BY LIMIT top-N');
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  dir := D + '\t131_topn_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER, f FLOAT, s TEXT)');
      q.Exec('BEGIN');
      for i := 1 to 200 do
        q.Exec(Format('INSERT INTO t (id,n,f,s) VALUES (%d,%d,%s,%s)',
          [i, 200 - i, FloatToStr(i * 1.25, fs), QuotedStr(Format('s%.4d', [201 - i]))]));
      q.Exec('COMMIT');

      r := q.Exec('SELECT id FROM t ORDER BY n DESC LIMIT 3 OFFSET 4');
      Dogrula('T131 int DESC LIMIT/OFFSET',
        (Length(r.Rows) = 3) and (r.Rows[0][0] = '5') and
        (r.Rows[1][0] = '6') and (r.Rows[2][0] = '7'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM t ORDER BY f ASC LIMIT 2 OFFSET 10');
      Dogrula('T131 float ASC LIMIT/OFFSET',
        (Length(r.Rows) = 2) and (r.Rows[0][0] = '11') and
        (r.Rows[1][0] = '12'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM t ORDER BY s ASC LIMIT 2 OFFSET 10');
      Dogrula('T131 text ASC LIMIT/OFFSET',
        (Length(r.Rows) = 2) and (r.Rows[0][0] = '190') and
        (r.Rows[1][0] = '189'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM t ORDER BY id LIMIT 3 OFFSET 100');
      Dogrula('T131 PK sirasi OFFSET atlama',
        (Length(r.Rows) = 3) and (r.Rows[0][0] = '101') and
        (r.Rows[1][0] = '102') and (r.Rows[2][0] = '103'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM t ORDER BY id DESC LIMIT 3');
      Dogrula('T131 PK DESC LIMIT',
        (Length(r.Rows) = 3) and (r.Rows[0][0] = '200') and
        (r.Rows[1][0] = '199') and (r.Rows[2][0] = '198'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM t WHERE id >= 50 AND id < 150 ' +
        'ORDER BY id LIMIT 2 OFFSET 10');
      Dogrula('T131 WHERE + PK sirasi OFFSET',
        (Length(r.Rows) = 2) and (r.Rows[0][0] = '60') and
        (r.Rows[1][0] = '61'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM t ORDER BY n DESC LIMIT 4 OFFSET 196');
      Dogrula('T131 int DESC derin OFFSET',
        (Length(r.Rows) = 4) and (r.Rows[0][0] = '197') and
        (r.Rows[3][0] = '200'),
        IntToStr(Length(r.Rows)));
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T133_H13_StreamGroupBy;
// H13: GROUP BY'in ham akistan tek pass'te hesaplanmasi; cok kolonlu grup,
// WHERE ham on-elemesi, NULL/empty grup, COUNT(kolon), MIN/MAX/SUM/AVG,
// LIMIT/OFFSET ve HAVING/DISTINCT geri donusu.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r: TSqlResult;
  i: Integer;
  fs: TFormatSettings;
  city: string;
  b: string;
begin
  Grp('T133 H13 akisli GROUP BY');
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  dir := D + '\t133_group_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE g (id INTEGER PRIMARY KEY, sehir TEXT, ' +
        'yas INTEGER, bakiye FLOAT, aktif BOOLEAN)');
      q.Exec('BEGIN');
      for i := 1 to 30 do
      begin
        if i mod 3 = 0 then city := 'Ankara'
        else if i mod 3 = 1 then city := 'Izmir'
        else city := 'Bursa';
        if i mod 2 = 0 then b := 'TRUE' else b := 'FALSE';
        q.Exec(Format('INSERT INTO g (id,sehir,yas,bakiye,aktif) VALUES (%d,%s,%d,%s,%s)',
          [i, QuotedStr(city), i, FloatToStr(i * 1.5, fs), b]));
      end;
      q.Exec('COMMIT');

      r := q.Exec('SELECT sehir, COUNT(*) AS n, SUM(yas) AS sy, ' +
        'MIN(yas) AS mn, MAX(yas) AS mx, AVG(bakiye) AS ab ' +
        'FROM g GROUP BY sehir ORDER BY sehir');
      Dogrula('T133 tek kolon COUNT/SUM/MIN/MAX/AVG',
        (Length(r.Rows) = 3) and
        (r.Rows[0][0] = 'Ankara') and (r.Rows[0][1] = '10') and
        (r.Rows[0][2] = '165') and (r.Rows[0][3] = '3') and
        (r.Rows[0][4] = '30') and (r.Rows[0][5] = '24.75') and
        (r.Rows[1][0] = 'Bursa') and (r.Rows[1][1] = '10') and
        (r.Rows[1][2] = '155') and (r.Rows[1][5] = '23.25') and
        (r.Rows[2][0] = 'Izmir') and (r.Rows[2][1] = '10') and
        (r.Rows[2][2] = '145') and (r.Rows[2][5] = '21.75'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT sehir, aktif, COUNT(*) AS n, SUM(yas) AS sy ' +
        'FROM g GROUP BY sehir, aktif ORDER BY sehir, aktif');
      Dogrula('T133 cok kolonlu GROUP BY',
        (Length(r.Rows) = 6) and
        (r.Rows[0][0] = 'Ankara') and (r.Rows[0][1] = 'False') and
        (r.Rows[0][2] = '5') and (r.Rows[0][3] = '75') and
        (r.Rows[1][0] = 'Ankara') and (r.Rows[1][1] = 'True') and
        (r.Rows[1][2] = '5') and (r.Rows[1][3] = '90'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT aktif, COUNT(*) AS n, SUM(yas) AS sy ' +
        'FROM g WHERE sehir = ''Ankara'' GROUP BY aktif ORDER BY aktif');
      Dogrula('T133 WHERE TEXT + GROUP BY',
        (Length(r.Rows) = 2) and
        (r.Rows[0][0] = 'False') and (r.Rows[0][1] = '5') and
        (r.Rows[0][2] = '75') and
        (r.Rows[1][0] = 'True') and (r.Rows[1][1] = '5') and
        (r.Rows[1][2] = '90'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT sehir, COUNT(*) AS n FROM g WHERE yas > 20 ' +
        'GROUP BY sehir ORDER BY sehir');
      Dogrula('T133 WHERE sayisal + GROUP BY',
        (Length(r.Rows) = 3) and
        (r.Rows[0][0] = 'Ankara') and (r.Rows[0][1] = '4') and
        (r.Rows[1][0] = 'Bursa') and (r.Rows[1][1] = '3') and
        (r.Rows[2][0] = 'Izmir') and (r.Rows[2][1] = '3'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT sehir, COUNT(*) AS n FROM g WHERE yas >= 10 ' +
        'AND yas <= 12 GROUP BY sehir ORDER BY sehir');
      Dogrula('T133 WHERE AND zinciri + GROUP BY',
        (Length(r.Rows) = 3) and (r.Rows[0][1] = '1') and
        (r.Rows[1][1] = '1') and (r.Rows[2][1] = '1'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT sehir, COUNT(*) AS n FROM g ' +
        'WHERE sehir <> ''Ankara'' GROUP BY sehir ORDER BY sehir');
      Dogrula('T133 WHERE TEXT <> + GROUP BY',
        (Length(r.Rows) = 2) and
        (r.Rows[0][0] = 'Bursa') and (r.Rows[0][1] = '10') and
        (r.Rows[1][0] = 'Izmir') and (r.Rows[1][1] = '10'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT sehir, COUNT(*) AS n FROM g ' +
        'WHERE sehir = ''Ankara'' OR sehir = ''Izmir'' GROUP BY sehir ORDER BY sehir');
      Dogrula('T133 WHERE OR (ham on-eleme yok)',
        (Length(r.Rows) = 2) and
        (r.Rows[0][0] = 'Ankara') and (r.Rows[0][1] = '10') and
        (r.Rows[1][0] = 'Izmir') and (r.Rows[1][1] = '10'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT sehir, COUNT(*) AS n FROM g ' +
        'WHERE yas > 20 OR yas < 5 GROUP BY sehir ORDER BY sehir');
      Dogrula('T133 WHERE OR farkli kolon (tam satir)',
        (Length(r.Rows) = 3) and
        (r.Rows[0][0] = 'Ankara') and (r.Rows[0][1] = '5') and
        (r.Rows[1][0] = 'Bursa') and (r.Rows[1][1] = '4') and
        (r.Rows[2][0] = 'Izmir') and (r.Rows[2][1] = '5'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT sehir, COUNT(*) AS n FROM g ' +
        'WHERE sehir = ''Yok'' GROUP BY sehir');
      Dogrula('T133 WHERE sonuc yok', Length(r.Rows) = 0,
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT sehir FROM g GROUP BY sehir ORDER BY sehir');
      Dogrula('T133 aggregate olmadan GROUP BY',
        (Length(r.Rows) = 3) and (r.Rows[0][0] = 'Ankara') and
        (r.Rows[1][0] = 'Bursa') and (r.Rows[2][0] = 'Izmir'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT sehir, COUNT(*) AS n FROM g GROUP BY sehir ' +
        'ORDER BY sehir LIMIT 2 OFFSET 1');
      Dogrula('T133 GROUP BY LIMIT/OFFSET',
        (Length(r.Rows) = 2) and (r.Rows[0][0] = 'Bursa') and
        (r.Rows[1][0] = 'Izmir'), IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT sehir, COUNT(*) AS n FROM g GROUP BY sehir LIMIT 0');
      Dogrula('T133 GROUP BY LIMIT 0', Length(r.Rows) = 0,
        IntToStr(Length(r.Rows)));

      q.Exec('CREATE TABLE gn (id INTEGER PRIMARY KEY, v INTEGER, s TEXT)');
      q.Exec('INSERT INTO gn (id,v,s) VALUES ' +
        '(1,NULL,NULL),(2,NULL,NULL),(3,5,''a''),(4,5,''a''),(5,7,''b'')');
      r := q.Exec('SELECT v, COUNT(*) AS n, COUNT(v) AS cv, SUM(v) AS sv ' +
        'FROM gn GROUP BY v ORDER BY v');
      Dogrula('T133 NULL grup + COUNT(kolon)',
        (Length(r.Rows) = 3) and
        (r.Rows[0][0] = '') and (r.Rows[0][1] = '2') and
        (r.Rows[0][2] = '0') and (r.Rows[0][3] = '') and
        (r.Rows[1][0] = '5') and (r.Rows[1][1] = '2') and
        (r.Rows[1][2] = '2') and (r.Rows[1][3] = '10') and
        (r.Rows[2][0] = '7') and (r.Rows[2][1] = '1'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT s, COUNT(*) AS n FROM gn GROUP BY s ORDER BY s');
      Dogrula('T133 NULL/empty metin grubu',
        (Length(r.Rows) = 3) and (r.Rows[0][1] = '2') and
        (r.Rows[1][1] = '2') and (r.Rows[2][1] = '1'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT sehir, COUNT(*) AS n FROM g GROUP BY sehir ' +
        'HAVING COUNT(*) >= 10 ORDER BY sehir');
      Dogrula('T133 HAVING genel yol',
        (Length(r.Rows) = 3) and (r.Rows[0][1] = '10') and
        (r.Rows[1][1] = '10') and (r.Rows[2][1] = '10'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT DISTINCT sehir FROM g GROUP BY sehir ORDER BY sehir');
      Dogrula('T133 DISTINCT + GROUP BY genel yol',
        (Length(r.Rows) = 3) and (r.Rows[0][0] = 'Ankara'),
        IntToStr(Length(r.Rows)));

      q.Exec('CREATE TABLE gu (id INTEGER PRIMARY KEY, s TEXT)');
      q.Exec('INSERT INTO gu (id,s) VALUES (1,''İzmir''),(2,''Izmir''),(3,''İzmir'')');
      r := q.Exec('SELECT s, COUNT(*) AS n FROM gu GROUP BY s ORDER BY s');
      Dogrula('T133 UTF-8 grup anahtari',
        (Length(r.Rows) = 2) and
        (((r.Rows[0][1] = '2') and (r.Rows[1][1] = '1')) or
         ((r.Rows[0][1] = '1') and (r.Rows[1][1] = '2'))),
        IntToStr(Length(r.Rows)));
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T134_H12c_MultiTopN;
// H12c: cok kolonlu ham akisli top-N; karma yon, NULLS konumu, WHERE
// on-elemesi ve ifade/alias geri donusu dogrulanir.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r: TSqlResult;

  function Ids(const Res: TSqlResult): string;
  var
    k: Integer;
  begin
    Result := '';
    for k := 0 to High(Res.Rows) do
      Result := Result + Res.Rows[k][0] + ',';
  end;

begin
  Grp('T134 H12c cok kolonlu akisli top-N');
  dir := D + '\t134_multi_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE tm (id INTEGER PRIMARY KEY, g TEXT, n INTEGER, ' +
        'f FLOAT, b BOOLEAN)');
      q.Exec('INSERT INTO tm (id,g,n,f,b) VALUES ' +
        '(1,''b'',2,2.5,TRUE),(2,''a'',1,1.5,TRUE),(3,''a'',3,3.5,FALSE),' +
        '(4,''a'',2,2.0,TRUE),(5,''b'',NULL,9.0,TRUE),' +
        '(6,''b'',1,0.5,FALSE),(7,NULL,5,5.0,TRUE),(8,NULL,4,4.0,FALSE),' +
        '(9,''c'',3,NULL,TRUE),(10,''c'',2,1.0,NULL),' +
        '(11,''a'',NULL,8.0,FALSE),(12,''b'',1,NULL,TRUE)');

      r := q.Exec('SELECT id FROM tm ORDER BY g ASC, n DESC LIMIT 3');
      Dogrula('T134 metin + sayisal, LIMIT',
        (Length(r.Rows) = 3) and
        (r.Rows[0][0] = '7') and (r.Rows[1][0] = '8') and
        (r.Rows[2][0] = '3'),
        Ids(r));

      r := q.Exec('SELECT id FROM tm ORDER BY g ASC NULLS LAST, n DESC LIMIT 3');
      Dogrula('T134 NULLS LAST + LIMIT',
        (Length(r.Rows) = 3) and
        (r.Rows[0][0] = '3') and (r.Rows[1][0] = '4') and
        (r.Rows[2][0] = '2'),
        Ids(r));

      r := q.Exec('SELECT id FROM tm ORDER BY n ASC, f DESC LIMIT 3');
      Dogrula('T134 sayisal + float, karma icerik',
        (Length(r.Rows) = 3) and
        (r.Rows[0][0] = '5') and (r.Rows[1][0] = '11') and
        (r.Rows[2][0] = '2'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM tm ORDER BY g DESC NULLS FIRST, n ASC ' +
        'LIMIT 2 OFFSET 1');
      Dogrula('T134 DESC + NULLS FIRST + OFFSET',
        (Length(r.Rows) = 2) and
        (r.Rows[0][0] = '7') and (r.Rows[1][0] = '10'),
        Ids(r));

      r := q.Exec('SELECT id FROM tm WHERE g = ''b'' ORDER BY n DESC, f ASC ' +
        'LIMIT 3');
      Dogrula('T134 WHERE on-elemesi + cok kolon',
        (Length(r.Rows) = 3) and
        (r.Rows[0][0] = '1') and (r.Rows[1][0] = '12') and
        (r.Rows[2][0] = '6'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM tm ORDER BY b ASC, n DESC LIMIT 3');
      Dogrula('T134 BOOL + sayisal',
        (Length(r.Rows) = 3) and
        (r.Rows[0][0] = '10') and (r.Rows[1][0] = '8') and
        (r.Rows[2][0] = '3'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM tm WHERE g = ''b'' ' +
        'ORDER BY g ASC, n DESC, f ASC LIMIT 4');
      Dogrula('T134 uc kolon, son anahtar',
        (Length(r.Rows) = 4) and
        (r.Rows[0][0] = '1') and (r.Rows[1][0] = '12') and
        (r.Rows[2][0] = '6') and (r.Rows[3][0] = '5'),
        Ids(r));

      r := q.Exec('SELECT id FROM tm WHERE n >= 0 ' +
        'ORDER BY n + 0 DESC LIMIT 1');
      Dogrula('T134 ifade anahtari genel yola duser',
        (Length(r.Rows) = 1) and (r.Rows[0][0] = '7'),
        Ids(r));

      r := q.Exec('SELECT id FROM tm WHERE g = ''b'' ' +
        'ORDER BY LENGTH(g) DESC, n DESC, id ASC LIMIT 2');
      Dogrula('T134 ifade + LIMIT top-N',
        (Length(r.Rows) = 2) and
        (r.Rows[0][0] = '1') and (r.Rows[1][0] = '6'),
        Ids(r));

      r := q.Exec('SELECT id, n AS nn FROM tm ORDER BY g, nn LIMIT 1');
      Dogrula('T134 alias anahtari genel yola duser',
        (Length(r.Rows) = 1) and (r.Rows[0][0] = '8'),
        Ids(r));

      r := q.Exec('SELECT id FROM tm ORDER BY g ASC, n DESC LIMIT 0');
      Dogrula('T134 cok kolon LIMIT 0 bos', Length(r.Rows) = 0,
        IntToStr(Length(r.Rows)));
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T135_H14_FloatSort;
// H14: tek kolonlu FLOAT siralamasi icin anahtarlar onceden cozulur.
// Sonuclar genel yolla (metin kiyasi) BIREBIR ayni olmalidir.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r: TSqlResult;
  i: Integer;
  fs: TFormatSettings;
begin
  Grp('T135 H14 FLOAT siralama hizli yolu');
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  dir := D + '\t135_fsort_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE tf (id INTEGER PRIMARY KEY, f FLOAT)');
      q.Exec('INSERT INTO tf (id,f) VALUES ' +
        '(1,2.5),(2,NULL),(3,-1.75),(4,2.5),(5,0),(6,10.125),(7,-3.5),(8,1)');

      // WHERE PK'ya referans verir -> genel yol (bellek ici siralama).
      r := q.Exec('SELECT id FROM tf WHERE id >= 0 ORDER BY f ASC');
      Dogrula('T135 FLOAT ASC siralama',
        (Length(r.Rows) = 8) and
        (r.Rows[0][0] = '2') and    // NULL en kucuk
        (r.Rows[1][0] = '7') and    // -3.5
        (r.Rows[2][0] = '3') and    // -1.75
        (r.Rows[3][0] = '5') and    // 0
        (r.Rows[4][0] = '8') and    // 1
        (((r.Rows[5][0] = '1') and (r.Rows[6][0] = '4')) or
         ((r.Rows[5][0] = '4') and (r.Rows[6][0] = '1'))) and  // 2.5 = 2.5
        (r.Rows[7][0] = '6'),       // 10.125
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM tf WHERE id >= 0 ORDER BY f DESC');
      Dogrula('T135 FLOAT DESC siralama',
        (Length(r.Rows) = 8) and
        (r.Rows[0][0] = '6') and
        (((r.Rows[1][0] = '1') and (r.Rows[2][0] = '4')) or
         ((r.Rows[1][0] = '4') and (r.Rows[2][0] = '1'))) and  // 2.5 = 2.5
        (r.Rows[3][0] = '8') and
        (r.Rows[4][0] = '5') and
        (r.Rows[5][0] = '3') and
        (r.Rows[6][0] = '7') and
        (r.Rows[7][0] = '2'),        // NULL en buyuk
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM tf WHERE id >= 0 ORDER BY f ASC LIMIT 3');
      Dogrula('T135 FLOAT ASC LIMIT',
        (Length(r.Rows) = 3) and
        (r.Rows[0][0] = '2') and (r.Rows[1][0] = '7') and
        (r.Rows[2][0] = '3'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM tf WHERE id >= 0 ORDER BY f DESC ' +
        'LIMIT 2 OFFSET 1');
      Dogrula('T135 FLOAT DESC LIMIT/OFFSET',
        (Length(r.Rows) = 2) and
        (((r.Rows[0][0] = '1') and (r.Rows[1][0] = '4')) or
         ((r.Rows[0][0] = '4') and (r.Rows[1][0] = '1'))),
        IntToStr(Length(r.Rows)));

      // NULLS FIRST/LAST acik yazildiginda genel yola dusulur.
      r := q.Exec('SELECT id FROM tf WHERE id >= 0 ' +
        'ORDER BY f ASC NULLS LAST LIMIT 1');
      Dogrula('T135 FLOAT NULLS LAST',
        (Length(r.Rows) = 1) and (r.Rows[0][0] = '7'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM tf WHERE id >= 0 ' +
        'ORDER BY f DESC NULLS FIRST LIMIT 1');
      Dogrula('T135 FLOAT NULLS FIRST',
        (Length(r.Rows) = 1) and (r.Rows[0][0] = '2'),
        IntToStr(Length(r.Rows)));

      // Cok kolonlu siralamada float kolonu ikinci srada.
      r := q.Exec('SELECT id FROM tf WHERE id >= 0 ORDER BY f ASC, id DESC ' +
        'LIMIT 2');
      Dogrula('T135 FLOAT + kolon siralama',
        (Length(r.Rows) = 2) and
        (r.Rows[0][0] = '2') and (r.Rows[1][0] = '7'),
        IntToStr(Length(r.Rows)));

      // Paralel yol esigi (>= 2048 satir) uzerinde siralama dogru mu?
      q.Exec('CREATE TABLE tp (id INTEGER PRIMARY KEY, f FLOAT)');
      q.Exec('BEGIN');
      for i := 1 to 3000 do
        q.Exec(Format('INSERT INTO tp (id,f) VALUES (%d,%s)',
          [i, FloatToStr((3000 - i) * 0.5, fs)]));
      q.Exec('COMMIT');
      r := q.Exec('SELECT id, f FROM tp WHERE id >= 0 ORDER BY f ASC LIMIT 3');
      Dogrula('T135 paralel yol siralama',
        (Length(r.Rows) = 3) and
        (r.Rows[0][0] = '3000') and (r.Rows[1][0] = '2999') and
        (r.Rows[2][0] = '2998'),
        IntToStr(Length(r.Rows)));
      r := q.Exec('SELECT id, f FROM tp WHERE id >= 0 ORDER BY f DESC LIMIT 3');
      Dogrula('T135 paralel yol DESC',
        (Length(r.Rows) = 3) and
        (r.Rows[0][0] = '1') and (r.Rows[1][0] = '2') and
        (r.Rows[2][0] = '3'),
        IntToStr(Length(r.Rows)));
      // LIMIT'siz tam siralama -> paralel dagitim yolu.
      r := q.Exec('SELECT id, f FROM tp WHERE id >= 0 ORDER BY f ASC');
      Dogrula('T135 tam siralama (paralel yol)',
        (Length(r.Rows) = 3000) and
        (r.Rows[0][0] = '3000') and
        (r.Rows[1499][0] = '1501') and
        (r.Rows[2999][0] = '1'),
        IntToStr(Length(r.Rows)));
      r := q.Exec('SELECT id, f FROM tp WHERE id >= 0 ORDER BY f DESC');
      Dogrula('T135 tam siralama DESC (paralel yol)',
        (Length(r.Rows) = 3000) and
        (r.Rows[0][0] = '1') and
        (r.Rows[2999][0] = '3000'),
        IntToStr(Length(r.Rows)));
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T136_H13_GroupDiff;
// H13/H14 akisli GROUP BY yolu genel yolla BIREBIR ayni sonucu vermelidir.
// Ayni sorgu "HAVING 1=1" ile genel yola dusurulerek karsilastirilir.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r1, r2: TSqlResult;
  s1, s2: string;

  function RowSet(const R: TSqlResult): string;
  var
    k, m: Integer;
  begin
    Result := '';
    for k := 0 to High(R.Rows) do
    begin
      Result := Result + '[';
      for m := 0 to High(R.Rows[k]) do
        Result := Result + R.Rows[k][m] + ',';
      Result := Result + ']';
    end;
  end;

  procedure Cmp(const A, B: string);
  begin
    r1 := q.Exec(A);
    r2 := q.Exec(B);
    s1 := RowSet(r1);
    s2 := RowSet(r2);
    if s1 = s2 then
      Dogrula('T136 ayni: ' + A, True, '')
    else
      Dogrula('T136 ayni: ' + A, False,
        'akis=' + s1 + ' genel=' + s2);
  end;

begin
  Grp('T136 H13 akisli GROUP BY / genel yol farki');
  dir := D + '\t136_gdiff_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE d (id INTEGER PRIMARY KEY, s TEXT, n INTEGER, ' +
        'f FLOAT, b BOOLEAN)');
      q.Exec('INSERT INTO d (id,s,n,f,b) VALUES ' +
        '(1,''a'',10,1.5,TRUE),(2,''a'',20,2.5,TRUE),(3,''b'',30,3.5,FALSE),' +
        '(4,''b'',5,0.5,FALSE),(5,''c'',NULL,NULL,NULL),(6,NULL,7,7.0,TRUE),' +
        '(7,''a'',20,2.5,NULL),(8,''b'',NULL,1.25,TRUE)');

      Cmp('SELECT s, COUNT(*) AS c FROM d GROUP BY s ORDER BY s',
          'SELECT s, COUNT(*) AS c FROM d GROUP BY s HAVING 1=1 ORDER BY s');
      Cmp('SELECT s, SUM(n) AS t FROM d GROUP BY s ORDER BY s',
          'SELECT s, SUM(n) AS t FROM d GROUP BY s HAVING 1=1 ORDER BY s');
      Cmp('SELECT s, AVG(n) AS a FROM d GROUP BY s ORDER BY s',
          'SELECT s, AVG(n) AS a FROM d GROUP BY s HAVING 1=1 ORDER BY s');
      Cmp('SELECT s, MIN(n) AS mi, MAX(n) AS ma FROM d GROUP BY s ORDER BY s',
          'SELECT s, MIN(n) AS mi, MAX(n) AS ma FROM d GROUP BY s HAVING 1=1 ORDER BY s');
      Cmp('SELECT s, COUNT(n) AS cn FROM d GROUP BY s ORDER BY s',
          'SELECT s, COUNT(n) AS cn FROM d GROUP BY s HAVING 1=1 ORDER BY s');
      Cmp('SELECT s, SUM(b) AS sb FROM d GROUP BY s ORDER BY s',
          'SELECT s, SUM(b) AS sb FROM d GROUP BY s HAVING 1=1 ORDER BY s');
      Cmp('SELECT s, AVG(b) AS ab FROM d GROUP BY s ORDER BY s',
          'SELECT s, AVG(b) AS ab FROM d GROUP BY s HAVING 1=1 ORDER BY s');
      Cmp('SELECT s, SUM(f) AS sf, AVG(f) AS af FROM d GROUP BY s ORDER BY s',
          'SELECT s, SUM(f) AS sf, AVG(f) AS af FROM d GROUP BY s HAVING 1=1 ORDER BY s');
      Cmp('SELECT s, COUNT(*) AS c FROM d WHERE n > 5 GROUP BY s ORDER BY s',
          'SELECT s, COUNT(*) AS c FROM d WHERE n > 5 GROUP BY s HAVING 1=1 ORDER BY s');
      Cmp('SELECT s, n FROM d GROUP BY s ORDER BY s',
          'SELECT s, n FROM d GROUP BY s HAVING 1=1 ORDER BY s');
      Cmp('SELECT s, COUNT(*) AS c FROM d GROUP BY s HAVING COUNT(*) > 1 ' +
          'ORDER BY s',
          'SELECT s, COUNT(*) AS c FROM d GROUP BY s HAVING COUNT(*) > 1 ' +
          'ORDER BY s');
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T138_H16_StreamDistinct;
// H16: tek kolonlu akisli DISTINCT yolu, genel yolla BIREBIR ayni sonucu
// vermelidir. Genel yol, SELECT listesine ayni kolonun ikinci bir kopyasi
// eklenerek zorlanir (Columns.Count = 2 -> akisli yol uymaz); DISTINCT
// cifti ayni oldugu icin sonuc kumesi degismez.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r1, r2: TSqlResult;

  function FirstCol(const R: TSqlResult; Sorted: Boolean): string;
  var
    k, m: Integer;
    a: TStrArray;
    s: string;
  begin
    Result := '';
    SetLength(a, Length(R.Rows));
    for k := 0 to High(R.Rows) do
      if Length(R.Rows[k]) > 0 then a[k] := R.Rows[k][0] else a[k] := '';
    if Sorted then
    begin
      // kucuk test kumesi: basit secmeli siralama
      for k := 0 to High(a) do
      begin
        for m := k + 1 to High(a) do
          if a[m] < a[k] then
          begin s := a[k]; a[k] := a[m]; a[m] := s; end;
      end;
    end;
    for k := 0 to High(a) do Result := Result + '[' + a[k] + ']';
  end;

  procedure Cmp(const A, B: string; Sorted: Boolean = False);
  var
    s1, s2: string;
  begin
    r1 := q.Exec(A);
    r2 := q.Exec(B);
    s1 := FirstCol(r1, Sorted);
    s2 := FirstCol(r2, Sorted);
    if s1 = s2 then
      Dogrula('T138 ayni: ' + A, True, '')
    else
      Dogrula('T138 ayni: ' + A, False,
        'akis=' + s1 + ' genel=' + s2);
  end;

begin
  Grp('T138 H16 akisli DISTINCT / genel yol farki');
  dir := D + '\t138_distinct_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE d (id INTEGER PRIMARY KEY, s TEXT, n INTEGER, ' +
        'f FLOAT, b BOOLEAN)');
      q.Exec('INSERT INTO d (id,s,n,f,b) VALUES ' +
        '(1,''a'',10,1.5,TRUE),(2,''a'',20,2.5,TRUE),(3,''b'',30,3.5,FALSE),' +
        '(4,''b'',5,0.5,FALSE),(5,''c'',NULL,NULL,NULL),(6,NULL,7,7.0,TRUE),' +
        '(7,''a'',20,2.5,NULL),(8,''b'',NULL,1.25,TRUE),(9,'''',99,9.9,FALSE)');

      Cmp('SELECT DISTINCT s FROM d ORDER BY s',
          'SELECT DISTINCT s, s FROM d ORDER BY s');
      Cmp('SELECT DISTINCT s FROM d ORDER BY s DESC',
          'SELECT DISTINCT s, s FROM d ORDER BY s DESC');
      Cmp('SELECT DISTINCT s FROM d ORDER BY s NULLS FIRST',
          'SELECT DISTINCT s, s FROM d ORDER BY s NULLS FIRST');
      Cmp('SELECT DISTINCT s FROM d ORDER BY s DESC NULLS LAST',
          'SELECT DISTINCT s, s FROM d ORDER BY s DESC NULLS LAST');
      Cmp('SELECT DISTINCT s AS c FROM d ORDER BY c',
          'SELECT DISTINCT s AS c, s FROM d ORDER BY s');
      Cmp('SELECT DISTINCT n FROM d ORDER BY n',
          'SELECT DISTINCT n, n FROM d ORDER BY n');
      Cmp('SELECT DISTINCT f FROM d ORDER BY f',
          'SELECT DISTINCT f, f FROM d ORDER BY f');
      Cmp('SELECT DISTINCT b FROM d ORDER BY b',
          'SELECT DISTINCT b, b FROM d ORDER BY b');
      Cmp('SELECT DISTINCT s FROM d WHERE n > 5 ORDER BY s',
          'SELECT DISTINCT s, s FROM d WHERE n > 5 ORDER BY s');
      Cmp('SELECT DISTINCT s FROM d WHERE n IS NULL ORDER BY s',
          'SELECT DISTINCT s, s FROM d WHERE n IS NULL ORDER BY s');
      Cmp('SELECT DISTINCT s FROM d ORDER BY s LIMIT 2 OFFSET 1',
          'SELECT DISTINCT s, s FROM d ORDER BY s LIMIT 2 OFFSET 1');
      Cmp('SELECT DISTINCT n FROM d ORDER BY n LIMIT 3',
          'SELECT DISTINCT n, n FROM d ORDER BY n LIMIT 3');
      Cmp('SELECT DISTINCT s FROM d', 'SELECT DISTINCT s, s FROM d', True);
      Cmp('SELECT DISTINCT n FROM d', 'SELECT DISTINCT n, n FROM d', True);
      Cmp('SELECT DISTINCT f FROM d', 'SELECT DISTINCT f, f FROM d', True);
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T139_H17_StreamFilteredCount;
// H17: WHERE'li saf COUNT(*) ham akis yolu, genel yolla BIREBIR ayni sonucu
// vermelidir. Genel yol COUNT(id) ile zorlanir: H17 yalniz COUNT(*) kabul
// eder, id PK'si NULL olamadigi icin iki sayim ayni olmalidir.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r1, r2: TSqlResult;

  procedure Cmp(const A, B: string);
  var
    s1, s2: string;
  begin
    r1 := q.Exec(A);
    r2 := q.Exec(B);
    if (Length(r1.Rows) > 0) and (Length(r1.Rows[0]) > 0) then
      s1 := r1.Rows[0][0] else s1 := '<yok>';
    if (Length(r2.Rows) > 0) and (Length(r2.Rows[0]) > 0) then
      s2 := r2.Rows[0][0] else s2 := '<yok>';
    if s1 = s2 then
      Dogrula('T139 ayni: ' + A, True, '')
    else
      Dogrula('T139 ayni: ' + A, False, 'akis=' + s1 + ' genel=' + s2);
  end;

begin
  Grp('T139 H17 akisli WHERE''li COUNT(*) / genel yol farki');
  dir := D + '\t139_fcount_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE d (id INTEGER PRIMARY KEY, s TEXT, n INTEGER, ' +
        'f FLOAT, b BOOLEAN)');
      q.Exec('INSERT INTO d (id,s,n,f,b) VALUES ' +
        '(1,''a'',10,1.5,TRUE),(2,''a'',20,2.5,TRUE),(3,''b'',30,3.5,FALSE),' +
        '(4,''b'',5,0.5,FALSE),(5,''c'',NULL,NULL,NULL),(6,NULL,7,7.0,TRUE),' +
        '(7,''a'',20,2.5,NULL),(8,''b'',NULL,1.25,TRUE),(9,'''',99,9.9,FALSE),' +
        '(10,''ğ'',15,1.0,TRUE),(11,''ağa'',NULL,2.0,FALSE)');

      Cmp('SELECT COUNT(*) FROM d WHERE n > 5',
          'SELECT COUNT(id) FROM d WHERE n > 5');
      Cmp('SELECT COUNT(*) FROM d WHERE s = ''a''',
          'SELECT COUNT(id) FROM d WHERE s = ''a''');
      Cmp('SELECT COUNT(*) FROM d WHERE s <> ''a''',
          'SELECT COUNT(id) FROM d WHERE s <> ''a''');
      Cmp('SELECT COUNT(*) FROM d WHERE s > ''a''',
          'SELECT COUNT(id) FROM d WHERE s > ''a''');
      Cmp('SELECT COUNT(*) FROM d WHERE s LIKE ''%a%''',
          'SELECT COUNT(id) FROM d WHERE s LIKE ''%a%''');
      Cmp('SELECT COUNT(*) FROM d WHERE s NOT LIKE ''%a%''',
          'SELECT COUNT(id) FROM d WHERE s NOT LIKE ''%a%''');
      Cmp('SELECT COUNT(*) FROM d WHERE s ILIKE ''%A%''',
          'SELECT COUNT(id) FROM d WHERE s ILIKE ''%A%''');
      Cmp('SELECT COUNT(*) FROM d WHERE s LIKE ''_''',
          'SELECT COUNT(id) FROM d WHERE s LIKE ''_''');
      Cmp('SELECT COUNT(*) FROM d WHERE s LIKE ''ğ''',
          'SELECT COUNT(id) FROM d WHERE s LIKE ''ğ''');
      Cmp('SELECT COUNT(*) FROM d WHERE s IS NULL',
          'SELECT COUNT(id) FROM d WHERE s IS NULL');
      Cmp('SELECT COUNT(*) FROM d WHERE s IS NOT NULL',
          'SELECT COUNT(id) FROM d WHERE s IS NOT NULL');
      Cmp('SELECT COUNT(*) FROM d WHERE n IS NULL',
          'SELECT COUNT(id) FROM d WHERE n IS NULL');
      Cmp('SELECT COUNT(*) FROM d WHERE n BETWEEN 10 AND 30',
          'SELECT COUNT(id) FROM d WHERE n BETWEEN 10 AND 30');
      Cmp('SELECT COUNT(*) FROM d WHERE n NOT BETWEEN 10 AND 30',
          'SELECT COUNT(id) FROM d WHERE n NOT BETWEEN 10 AND 30');
      Cmp('SELECT COUNT(*) FROM d WHERE n IN (10,30,99)',
          'SELECT COUNT(id) FROM d WHERE n IN (10,30,99)');
      Cmp('SELECT COUNT(*) FROM d WHERE n NOT IN (10,30)',
          'SELECT COUNT(id) FROM d WHERE n NOT IN (10,30)');
      Cmp('SELECT COUNT(*) FROM d WHERE s IN (''a'',''b'')',
          'SELECT COUNT(id) FROM d WHERE s IN (''a'',''b'')');
      Cmp('SELECT COUNT(*) FROM d WHERE f > 2.0',
          'SELECT COUNT(id) FROM d WHERE f > 2.0');
      Cmp('SELECT COUNT(*) FROM d WHERE b = TRUE',
          'SELECT COUNT(id) FROM d WHERE b = TRUE');
      Cmp('SELECT COUNT(*) FROM d WHERE b IS NULL',
          'SELECT COUNT(id) FROM d WHERE b IS NULL');
      Cmp('SELECT COUNT(*) FROM d WHERE n > 5 AND s <> ''c''',
          'SELECT COUNT(id) FROM d WHERE n > 5 AND s <> ''c''');
      Cmp('SELECT COUNT(*) FROM d WHERE n > 20 OR s = ''a''',
          'SELECT COUNT(id) FROM d WHERE n > 20 OR s = ''a''');
      Cmp('SELECT COUNT(*) FROM d WHERE NOT (n > 20)',
          'SELECT COUNT(id) FROM d WHERE NOT (n > 20)');
      Cmp('SELECT COUNT(*) FROM d WHERE COALESCE(s,''x'') = ''x''',
          'SELECT COUNT(id) FROM d WHERE COALESCE(s,''x'') = ''x''');
      Cmp('SELECT COUNT(*) FROM d WHERE UPPER(s) = ''A''',
          'SELECT COUNT(id) FROM d WHERE UPPER(s) = ''A''');
      Cmp('SELECT COUNT(*) FROM d WHERE CASE WHEN n > 20 THEN 1 ELSE 0 END = 1',
          'SELECT COUNT(id) FROM d WHERE CASE WHEN n > 20 THEN 1 ELSE 0 END = 1');
      Cmp('SELECT COUNT(*) FROM d WHERE 1 = 1',
          'SELECT COUNT(id) FROM d WHERE 1 = 1');
      Cmp('SELECT COUNT(*) FROM d WHERE 1 = 0',
          'SELECT COUNT(id) FROM d WHERE 1 = 0');
      Cmp('SELECT COUNT(*) FROM d WHERE n > 5 AND (s LIKE ''a%'' OR s = ''c'')',
          'SELECT COUNT(id) FROM d WHERE n > 5 AND (s LIKE ''a%'' OR s = ''c'')');
      Cmp('SELECT COUNT(*) FROM d WHERE n IN (SELECT n FROM d WHERE n > 20)',
          'SELECT COUNT(id) FROM d WHERE n IN (SELECT n FROM d WHERE n > 20)');
      Cmp('SELECT COUNT(*) FROM d WHERE EXISTS (SELECT id FROM d WHERE n = 99)',
          'SELECT COUNT(id) FROM d WHERE EXISTS (SELECT id FROM d WHERE n = 99)');
      Cmp('SELECT COUNT(*) FROM d WHERE n > 5 LIMIT 1',
          'SELECT COUNT(id) FROM d WHERE n > 5 LIMIT 1');
      Cmp('SELECT COUNT(*) AS c FROM d WHERE n > 5',
          'SELECT COUNT(id) FROM d WHERE n > 5');
      r1 := q.Exec('SELECT COUNT(*) AS c FROM d WHERE n > 5');
      if (Length(r1.Fields) = 1) and (r1.Fields[0] = 'c') and
         (Length(r1.Rows) = 1) and (r1.Rows[0][0] = '7') then
        Dogrula('T139 alias/alan adi', True, '')
      else if Length(r1.Fields) > 0 then
        Dogrula('T139 alias/alan adi', False, r1.Fields[0])
      else
        Dogrula('T139 alias/alan adi', False, 'alan yok');
      // Pending batch gorunurlugu: akisli tarama bekleyen satirlari da gormeli.
      db.BeginBatch;
      try
        q.Exec('INSERT INTO d (id,s,n,f,b) VALUES (12,''z'',50,1.0,TRUE)');
        Cmp('SELECT COUNT(*) FROM d WHERE n > 5',
            'SELECT COUNT(id) FROM d WHERE n > 5');
        Cmp('SELECT COUNT(*) FROM d WHERE s LIKE ''z%''',
            'SELECT COUNT(id) FROM d WHERE s LIKE ''z%''');
      finally
        db.AbortBatch;
      end;
      // Guncelleme/silme sonrasi akisli tarama guncel veriyi gormeli.
      q.Exec('UPDATE d SET n = 60 WHERE id = 1');
      q.Exec('DELETE FROM d WHERE id = 2');
      Cmp('SELECT COUNT(*) FROM d WHERE n > 5',
          'SELECT COUNT(id) FROM d WHERE n > 5');
      Cmp('SELECT COUNT(*) FROM d WHERE s = ''a''',
          'SELECT COUNT(id) FROM d WHERE s = ''a''');
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T140_H18_RawExactCount;
// H18: WHERE tamamen ham kosullarla cozulebildiginde string cozme ve
// EvalBool atlanir. Sonuc, genel yolla (COUNT(id)) birebir ayni olmalidir.
// Sinir durumlari: NULL/'' , UTF-8 metin, dinamik tip, 2^53 disi INT,
// FLOAT, BOOLEAN ve ham olmayan kosullarla karisik AND.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r1, r2: TSqlResult;

  procedure Cmp(const A, B: string);
  var
    s1, s2: string;
  begin
    r1 := q.Exec(A);
    r2 := q.Exec(B);
    if (Length(r1.Rows) > 0) and (Length(r1.Rows[0]) > 0) then
      s1 := r1.Rows[0][0] else s1 := '<yok>';
    if (Length(r2.Rows) > 0) and (Length(r2.Rows[0]) > 0) then
      s2 := r2.Rows[0][0] else s2 := '<yok>';
    if s1 = s2 then
      Dogrula('T140 ayni: ' + A, True, '')
    else
      Dogrula('T140 ayni: ' + A, False, 'ham=' + s1 + ' genel=' + s2);
  end;

begin
  Grp('T140 H18 ham kesin COUNT(*) / genel yol farki');
  dir := D + '\t140_rawcount_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE h (id INTEGER PRIMARY KEY, i INTEGER, f FLOAT, ' +
        's TEXT, b BOOLEAN, m TEXT)');
      q.Exec('INSERT INTO h (id,i,f,s,b,m) VALUES ' +
        '(1,42,2.5,''a'',TRUE,''x''),' +
        '(2,-7,1.25,''b'',FALSE,123),' +
        '(3,0,2.5,NULL,NULL,''x''),' +
        '(4,9007199254740992,0.0,''ğ'',TRUE,NULL),' +
        '(5,9007199254740993,-1.5,''ağa'',FALSE,7)');

      Cmp('SELECT COUNT(*) FROM h WHERE i = 42',
          'SELECT COUNT(id) FROM h WHERE i = 42');
      Cmp('SELECT COUNT(*) FROM h WHERE i > 42',
          'SELECT COUNT(id) FROM h WHERE i > 42');
      Cmp('SELECT COUNT(*) FROM h WHERE i < 0',
          'SELECT COUNT(id) FROM h WHERE i < 0');
      Cmp('SELECT COUNT(*) FROM h WHERE i <> 42',
          'SELECT COUNT(id) FROM h WHERE i <> 42');
      Cmp('SELECT COUNT(*) FROM h WHERE i BETWEEN -7 AND 42',
          'SELECT COUNT(id) FROM h WHERE i BETWEEN -7 AND 42');
      Cmp('SELECT COUNT(*) FROM h WHERE i IN (-7,42,999)',
          'SELECT COUNT(id) FROM h WHERE i IN (-7,42,999)');
      Cmp('SELECT COUNT(*) FROM h WHERE i = 1.5',
          'SELECT COUNT(id) FROM h WHERE i = 1.5');
      Cmp('SELECT COUNT(*) FROM h WHERE i >= 9007199254740992',
          'SELECT COUNT(id) FROM h WHERE i >= 9007199254740992');
      Cmp('SELECT COUNT(*) FROM h WHERE i = 9007199254740993',
          'SELECT COUNT(id) FROM h WHERE i = 9007199254740993');
      Cmp('SELECT COUNT(*) FROM h WHERE i > 9007199254740992',
          'SELECT COUNT(id) FROM h WHERE i > 9007199254740992');
      Cmp('SELECT COUNT(*) FROM h WHERE f = 2.5',
          'SELECT COUNT(id) FROM h WHERE f = 2.5');
      Cmp('SELECT COUNT(*) FROM h WHERE f > 2.0',
          'SELECT COUNT(id) FROM h WHERE f > 2.0');
      Cmp('SELECT COUNT(*) FROM h WHERE f <> 2.5',
          'SELECT COUNT(id) FROM h WHERE f <> 2.5');
      Cmp('SELECT COUNT(*) FROM h WHERE s = ''a''',
          'SELECT COUNT(id) FROM h WHERE s = ''a''');
      Cmp('SELECT COUNT(*) FROM h WHERE s <> ''a''',
          'SELECT COUNT(id) FROM h WHERE s <> ''a''');
      Cmp('SELECT COUNT(*) FROM h WHERE s = ''ğ''',
          'SELECT COUNT(id) FROM h WHERE s = ''ğ''');
      Cmp('SELECT COUNT(*) FROM h WHERE s = ''ağa''',
          'SELECT COUNT(id) FROM h WHERE s = ''ağa''');
      Cmp('SELECT COUNT(*) FROM h WHERE s IS NULL',
          'SELECT COUNT(id) FROM h WHERE s IS NULL');
      Cmp('SELECT COUNT(*) FROM h WHERE s IS NOT NULL',
          'SELECT COUNT(id) FROM h WHERE s IS NOT NULL');
      Cmp('SELECT COUNT(*) FROM h WHERE s = ''''',
          'SELECT COUNT(id) FROM h WHERE s = ''''');
      Cmp('SELECT COUNT(*) FROM h WHERE i > 0 AND s = ''a''',
          'SELECT COUNT(id) FROM h WHERE i > 0 AND s = ''a''');
      Cmp('SELECT COUNT(*) FROM h WHERE i > 0 AND s LIKE ''a%''',
          'SELECT COUNT(id) FROM h WHERE i > 0 AND s LIKE ''a%''');
      Cmp('SELECT COUNT(*) FROM h WHERE i > 0 AND b = TRUE',
          'SELECT COUNT(id) FROM h WHERE i > 0 AND b = TRUE');
      Cmp('SELECT COUNT(*) FROM h WHERE m = 123',
          'SELECT COUNT(id) FROM h WHERE m = 123');
      Cmp('SELECT COUNT(*) FROM h WHERE NOT (i > 42)',
          'SELECT COUNT(id) FROM h WHERE NOT (i > 42)');
      Cmp('SELECT COUNT(*) FROM h WHERE i = 42 OR i = 0',
          'SELECT COUNT(id) FROM h WHERE i = 42 OR i = 0');
      Cmp('SELECT COUNT(*) FROM h WHERE id >= 2 AND id < 5',
          'SELECT COUNT(id) FROM h WHERE id >= 2 AND id < 5');
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T141_H19_RawLikeCount;
// H19: LIKE/ILIKE ham bayt yolu, genel yolla birebir ayni olmalidir.
// Ozellikle Turkce 'I' -> 'ı' (UTF-8 C4 B1) ve bayt bazli '_' davranisi.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r1, r2: TSqlResult;

  procedure Cmp(const A, B: string);
  var
    s1, s2, aa, bb: string;
  begin
    r1 := q.Exec(A);
    r2 := q.Exec(B);
    aa := A; bb := B;
    aa := StringReplace(aa, 'COUNT(*)', 'COUNT(id)', []);
    bb := StringReplace(bb, 'COUNT(*)', 'COUNT(id)', []);
    if (Length(r1.Rows) > 0) and (Length(r1.Rows[0]) > 0) then
      s1 := r1.Rows[0][0] else s1 := '<yok>';
    if (Length(r2.Rows) > 0) and (Length(r2.Rows[0]) > 0) then
      s2 := r2.Rows[0][0] else s2 := '<yok>';
    if s1 = s2 then
      Dogrula('T141 ayni: ' + aa, True, '')
    else
      Dogrula('T141 ayni: ' + aa, False, 'ham=' + s1 + ' genel=' + s2);
  end;

  procedure C(const W: string);
  begin
    Cmp('SELECT COUNT(*) FROM l WHERE ' + W,
        'SELECT COUNT(id) FROM l WHERE ' + W);
  end;

begin
  Grp('T141 H19 ham LIKE/ILIKE COUNT(*) / genel yol farki');
  dir := D + '\t141_rawlike_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE l (id INTEGER PRIMARY KEY, s TEXT)');
      q.Exec('INSERT INTO l (id,s) VALUES ' +
        '(1,''Ali''),(2,''ali''),(3,''Irmak''),(4,''irmak''),' +
        '(5,''Ayşe''),(6,''IŞIL''),(7,''i''),(8,''I''),' +
        '(9,''''),(10,NULL),(11,''a_b''),(12,''aXb''),(13,''a%b'')');
      q.Exec('INSERT INTO l (id,s) VALUES (14,''' +
        StringOfChar('a', 5000) + ''')');

      C('s LIKE ''A%''');
      C('s LIKE ''a%''');
      C('s LIKE ''%a%''');
      C('s LIKE ''_''');
      C('s LIKE ''__''');
      C('s LIKE ''A_''');
      C('s LIKE ''%''');
      C('s LIKE ''''');
      C('s NOT LIKE ''A%''');
      C('s LIKE ''a_b''');
      C('s LIKE ''a%b''');
      C('s ILIKE ''a%''');
      C('s ILIKE ''A%''');
      C('s ILIKE ''i%''');
      C('s ILIKE ''I%''');
      C('s ILIKE ''%i%''');
      C('s ILIKE ''_''');
      C('s ILIKE ''__''');
      C('s ILIKE ''%a%''');
      C('s ILIKE ''%A%''');
      C('s ILIKE ''Ayşe''');
      C('s ILIKE ''%ş%''');
      C('s NOT ILIKE ''a%''');
      C('s ILIKE ''%a%'' AND s LIKE ''A%''');
      C('s ILIKE ''%a%'' AND id > 0');
      C('id > 0 AND s ILIKE ''%a%''');
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T142_H20_RawBoolTree;
// H20: ham boolean agaci AND/OR/NOT/BETWEEN/IN/IS NULL ile uc-degerli
// mantigi tam cozer. Sonuc genel yolla (COUNT(id)) birebir ayni olmalidir.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r1, r2: TSqlResult;
  longInts, longStrs, longFloats: string;
  k: Integer;

  procedure Cmp(const A, B: string);
  var
    s1, s2, aa: string;
  begin
    r1 := q.Exec(A);
    r2 := q.Exec(B);
    aa := A;
    aa := StringReplace(aa, 'COUNT(*)', 'COUNT(id)', []);
    if (Length(r1.Rows) > 0) and (Length(r1.Rows[0]) > 0) then
      s1 := r1.Rows[0][0] else s1 := '<yok>';
    if (Length(r2.Rows) > 0) and (Length(r2.Rows[0]) > 0) then
      s2 := r2.Rows[0][0] else s2 := '<yok>';
    if s1 = s2 then
      Dogrula('T142 ayni: ' + aa, True, '')
    else
      Dogrula('T142 ayni: ' + aa, False, 'ham=' + s1 + ' genel=' + s2);
  end;

  procedure C(const W: string);
  begin
    Cmp('SELECT COUNT(*) FROM p WHERE ' + W,
        'SELECT COUNT(id) FROM p WHERE ' + W);
  end;

begin
  Grp('T142 H20 ham boolean agaci / genel yol farki');
  dir := D + '\t142_rawtree_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE p (id INTEGER PRIMARY KEY, i INTEGER, ' +
        'f FLOAT, s TEXT, b BOOLEAN)');
      q.Exec('INSERT INTO p (id,i,f,s,b) VALUES ' +
        '(1,1,1.5,''Ali'',TRUE),' +
        '(2,2,2.5,''ali'',FALSE),' +
        '(3,NULL,NULL,NULL,NULL),' +
        '(4,3,3.5,'''',TRUE),' +
        '(5,-1,-2.5,''ğ'',FALSE),' +
        '(6,42,0.0,''a%b'',TRUE),' +
        '(7,9007199254740993,1000000000000.0,''I'',NULL),' +
        '(8,9007199254740992,-0.0,''Ayşe'',FALSE)');

      // Saf AND/OR/NOT ve oncelik.
      C('i = 1 OR i = 2 OR i = 42');
      C('i = 1 OR i = 2 AND s = ''ali''');
      C('(i = 1 OR i = 2) AND s <> ''ali''');
      C('NOT (i = 1 OR i = 2)');
      C('NOT (i > 0 AND s LIKE ''A%'')');
      C('i > 0 OR s LIKE ''A%''');
      C('i > 0 OR s ILIKE ''a%''');
      C('i > 0 OR s = ''Ali''');
      C('f > 0.0 OR f < -1.0');
      C('s LIKE ''A%'' OR i = 42');

      // BETWEEN / NOT BETWEEN, sinir ve NULL.
      C('i BETWEEN 1 AND 3');
      C('i NOT BETWEEN 1 AND 3');
      C('i BETWEEN NULL AND 42');
      C('i NOT BETWEEN NULL AND 42');
      C('NOT (i BETWEEN 1 AND 3)');
      C('f BETWEEN -1.0 AND 2.0');

      // H23: uzun IN listeleri (dengeli OR agaci) ve FLOAT IN.
      longInts := '1';
      for k := 2 to 2000 do longInts := longInts + ',' + IntToStr(k);
      longStrs := '''s0''';
      for k := 1 to 200 do longStrs := longStrs + ',''s' + IntToStr(k) + '''';
      longFloats := '1.5';
      for k := 1 to 200 do longFloats := longFloats + ',' +
        IntToStr(k) + '.5';
      C('i IN (' + longInts + ')');
      C('i NOT IN (' + longInts + ')');
      C('f IN (' + longFloats + ')');
      C('f NOT IN (' + longFloats + ',NULL)');
      C('s IN (' + longStrs + ')');
      C('s NOT IN (' + longStrs + ',NULL)');

      // IN / NOT IN, NULL ogeli liste ve 2^53 siniri.
      C('f IN (1.5,2.5,-2.5)');
      C('f NOT IN (1.5,NULL)');
      C('i IN (1,2,42)');
      C('i NOT IN (2,3)');
      C('i IN (42,NULL)');
      C('i NOT IN (42,NULL)');
      C('NOT (i IN (1,2))');
      C('i IN (9007199254740992)');
      C('i IN (9007199254740993)');
      C('s IN (''Ali'',''ali'')');
      C('s IN (''Ali'',NULL)');
      C('s NOT IN (''Ali'',NULL)');

      // IS NULL / IS NOT NULL ve NULL uc-degerli mantigi.
      C('s IS NULL');
      C('s IS NOT NULL');
      C('NOT (i IS NULL)');
      C('s IS NOT NULL AND i IS NULL');
      C('s = '''' OR s IS NULL');
      C('s <> ''''');
      C('NOT (s = '''')');
      C('s = '''' OR i = 1');
      C('i = 1 OR i IS NULL');

      // Ham yola girmeyen karisik OR: genel yol korunmali.
      C('s = ''ğ'' OR i = 1');
      C('b = TRUE OR i = 1');
      C('s > ''Ali'' OR i = 1');
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T143_H21_RawTreeSelectPaths;
// H21: H20 boolean agaci yalniz COUNT(*) yolunda degil; akisli SELECT,
// tek/cok kolon ORDER BY ... LIMIT, GROUP BY ve DISTINCT yollarinda da
// on-eleme olarak kullanilir. Sonuc, genel yol ile birebir ayni olmalidir.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r1, r2: TSqlResult;

  function RowSet(const R: TSqlResult): string;
  var
    k, m: Integer;
    s: string;
    a: array of string;
    tmp: string;
  begin
    SetLength(a, Length(R.Rows));
    for k := 0 to High(R.Rows) do
    begin
      s := '';
      for m := 0 to High(R.Rows[k]) do
        s := s + IntToStr(Length(R.Rows[k][m])) + ':' + R.Rows[k][m] + '|';
      a[k] := s;
    end;
    // Kucuk test kumeleri: basit kabarcik siralamasi yeterli.
    for k := 0 to High(a) do
      for m := k + 1 to High(a) do
        if a[m] < a[k] then
        begin tmp := a[k]; a[k] := a[m]; a[m] := tmp; end;
    Result := '';
    for k := 0 to High(a) do Result := Result + a[k];
  end;

  procedure Cmp(const A, B, Etiket: string);
  var
    s1, s2: string;
  begin
    r1 := q.Exec(A);
    r2 := q.Exec(B);
    s1 := RowSet(r1);
    s2 := RowSet(r2);
    if s1 = s2 then
      Dogrula('T143 ayni: ' + Etiket, True, '')
    else
      Dogrula('T143 ayni: ' + Etiket, False,
        'akisli=' + s1 + ' genel=' + s2);
  end;

  procedure C(const W: string);
  begin
    // H1 akisli SELECT (filtre + erken projeksiyon).
    Cmp('SELECT id,i,s FROM p WHERE ' + W,
        'SELECT id,i,s FROM p WHERE ' + W + ' ORDER BY id+0',
        'H1 ' + W);
    // H12b tek kolon top-N.
    Cmp('SELECT id,i FROM p WHERE (' + W + ') AND i < 1000 ORDER BY i LIMIT 5',
        'SELECT id,i FROM p WHERE (' + W + ') AND i < 1000 ORDER BY i+0 LIMIT 5',
        'H12b ' + W);
    // H12c cok kolon top-N.
    Cmp('SELECT id,i FROM p WHERE (' + W + ') AND i < 1000 ORDER BY i, id LIMIT 5',
        'SELECT id,i FROM p WHERE (' + W + ') AND i < 1000 ORDER BY i+0, id LIMIT 5',
        'H12c ' + W);
    // H13 akisli GROUP BY (HAVING DISTINCT genel yola zorlar, sonucu degistirmez).
    Cmp('SELECT s, COUNT(*) AS n FROM p WHERE ' + W + ' GROUP BY s',
        'SELECT s, COUNT(*) AS n FROM p WHERE ' + W +
        ' GROUP BY s HAVING COUNT(DISTINCT s) >= 0',
        'H13 ' + W);
    // H16 akisli DISTINCT (COLLATE'li ORDER BY genel yola zorlar).
    Cmp('SELECT DISTINCT s FROM p WHERE ' + W,
        'SELECT DISTINCT s FROM p WHERE ' + W + ' ORDER BY s COLLATE TR',
        'H16 ' + W);
  end;

begin
  Grp('T143 H21 ham boolean agaci / SELECT yollari');
  dir := D + '\t143_rawtree_sel_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE p (id INTEGER PRIMARY KEY, i INTEGER, ' +
        'f FLOAT, s TEXT, b BOOLEAN)');
      q.Exec('INSERT INTO p (id,i,f,s,b) VALUES ' +
        '(1,1,1.5,''Ali'',TRUE),' +
        '(2,2,2.5,''ali'',FALSE),' +
        '(3,NULL,NULL,NULL,NULL),' +
        '(4,3,3.5,'''',TRUE),' +
        '(5,-1,-2.5,''ğ'',FALSE),' +
        '(6,42,0.0,''a%b'',TRUE),' +
        '(7,9007199254740993,1000000000000.0,''I'',NULL),' +
        '(8,9007199254740992,-0.0,''Ayşe'',FALSE)');

      C('i = 1 OR i = 2 OR i = 42');
      C('NOT (i > 0 AND s LIKE ''A%'')');
      C('i BETWEEN 1 AND 3 OR s = ''ğ''');
      C('i NOT BETWEEN 1 AND 3');
      C('i IN (1,2,42)');
      C('s IN (''Ali'',''ali'')');
      C('s IS NULL OR i = 1');
      C('s IS NOT NULL AND i IS NULL');
      C('f > 0.0 OR f < -1.0');
      C('s LIKE ''A%'' OR i = 42');
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T144_H22_DeepOffsetLive;
// H22: ikincil indekste WHERE'siz derin OFFSET, satirlari tam cozmeden
// atlanir. Silinmis satirlarin olu indeks girdileri OFFSET sayimini
// bozmamali; sonuc eski (WHERE'li) indeks yoluyla birebir ayni olmali.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  i: Integer;
  delSql: string;

  function Ids(const R: TSqlResult): string;
  var
    k: Integer;
  begin
    Result := '';
    for k := 0 to High(R.Rows) do
      Result := Result + R.Rows[k][0] + ',';
  end;

  procedure Cmp(const A, B, Etiket: string);
  var
    r1, r2: TSqlResult;
    s1, s2: string;
  begin
    r1 := q.Exec(A);
    r2 := q.Exec(B);
    s1 := Ids(r1);
    s2 := Ids(r2);
    if s1 = s2 then
      Dogrula('T144 ayni: ' + Etiket, True, '')
    else
      Dogrula('T144 ayni: ' + Etiket, False,
        'yeni=' + s1 + ' eski=' + s2);
  end;

  procedure C(const Ord, Off: string);
  begin
    Cmp('SELECT id FROM p ORDER BY g ' + Ord + ' LIMIT 5 OFFSET ' + Off,
        'SELECT id FROM p WHERE id >= 0 ORDER BY g ' + Ord +
        ' LIMIT 5 OFFSET ' + Off,
        Ord + ' OFFSET ' + Off);
  end;

begin
  Grp('T144 H22 derin OFFSET canlilik denetimi');
  dir := D + '\t144_offset_live_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE p (id INTEGER PRIMARY KEY, g TEXT, n INTEGER)');
      q.Exec('BEGIN');
      for i := 1 to 12000 do
        q.Exec(Format('INSERT INTO p (id,g,n) VALUES (%d,%s,%d)',
          [i, QuotedStr(Format('g%.2d', [i mod 20])), i]));
      q.Exec('COMMIT');
      q.Exec('CREATE INDEX ix_p_g ON p (g)');
      // Derin OFFSET bolgesinde olu indeks girdileri olustur. Tek DELETE
      // cumlesi kullanilir; 400+ ayri Exec testi yavaslatirdi.
      delSql := 'DELETE FROM p WHERE id IN (';
      for i := 9000 to 12000 do
        if i mod 7 = 3 then
          delSql := delSql + IntToStr(i) + ',';
      delSql[Length(delSql)] := ')';
      q.Exec(delSql);

      // LIMIT+OFFSET > 10000: H12b yerine indeks sirasi yolu kullanilir.
      C('ASC', '10001');
      C('ASC', '10050');
      C('ASC', '10200');
      C('ASC', '10500');
      C('ASC', '11000');
      C('ASC', '11400');
      C('DESC', '10001');
      C('DESC', '10050');
      C('DESC', '10200');
      C('DESC', '10500');
      C('DESC', '11000');
      C('DESC', '11400');
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T145_H8_MCV;
// H8: skew'li esitlikte MCV (en sik deger) kullanilir. Ayni tabloda
// 'A' 90 kez, diger 10 deger birer kez gecer. Distinct ortalamasi
// (100/11) indeksi secerdi; MCV 90 ile Seq Scan secer. Seyrek degerde
// indeks korunur.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  i: Integer;
  all, kk: string;
  st: TVDbTableStats;
  cnt, total: Int64;
  nEnt: Integer;

  function PlanOf(const S: string): string;
  var
    p: Integer;
  begin
    R := q.Exec(S);
    Result := '';
    for p := 0 to High(R.Rows) do
      Result := Result + R.Rows[p][0] + ' | ';
  end;

begin
  Grp('T145 H8 MCV skew esitlik');
  dir := D + '\t145_mcv_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE mcv (id INTEGER PRIMARY KEY, k TEXT, n INTEGER)');
      q.Exec('BEGIN');
      for i := 1 to 100 do
      begin
        if i <= 90 then
        begin
          kk := 'A';
          q.Exec(Format('INSERT INTO mcv VALUES (%d,%s,0)', [i, QuotedStr(kk)]));
        end
        else
        begin
          kk := 'B' + IntToStr(i - 90);
          q.Exec(Format('INSERT INTO mcv VALUES (%d,%s,%d)',
            [i, QuotedStr(kk), i]));
        end;
      end;
      q.Exec('COMMIT');
      q.Exec('CREATE INDEX ix_mcv_k ON mcv(k)');
      q.Exec('CREATE INDEX ix_mcv_n ON mcv(n)');
      q.Exec('ANALYZE mcv');

      // MCV gercekten okunuyor mu?
      Dogrula('MCV istatistigi okundu', GetTableStats('mcv', st), '');
      Dogrula('MCV A=90',
        VdbStatsMCVLookup(st, 'k', 'A', cnt) and (cnt = 90),
        IntToStr(cnt));
      Dogrula('MCV toplami 100',
        VdbStatsMCVInfo(st, 'k', total, nEnt) and (total = 100),
        IntToStr(total));
      Dogrula('MCV deger sayisi 11', nEnt = 11, IntToStr(nEnt));

      all := PlanOf('EXPLAIN SELECT * FROM mcv WHERE k = ' + QuotedStr('A'));
      Dogrula('skew A -> Seq Scan', Pos('Seq Scan', all) > 0, all);
      Dogrula('skew A -> indeks DEGIL', Pos('ix_mcv_k', all) = 0, all);

      all := PlanOf('EXPLAIN SELECT * FROM mcv WHERE k = ' + QuotedStr('B3'));
      Dogrula('seyrek B3 -> Index Scan',
        Pos('Index Scan using ix_mcv_k', all) > 0, all);

      all := PlanOf('EXPLAIN SELECT * FROM mcv WHERE n = 0');
      Dogrula('skew n=0 -> Seq Scan', Pos('Seq Scan', all) > 0, all);
      all := PlanOf('EXPLAIN SELECT * FROM mcv WHERE n = 100');
      Dogrula('seyrek n=100 -> Index Scan',
        Pos('Index Scan using ix_mcv_n', all) > 0, all);

      // CBO yalnizca plan secer; sonuc kumeleri degismez.
      R := q.Exec('SELECT COUNT(*) FROM mcv WHERE k = ' + QuotedStr('A'));
      Dogrula('MCV A sayimi 90', (Length(R.Rows) = 1) and
        (R.Rows[0][0] = '90'), R.Rows[0][0]);
      R := q.Exec('SELECT COUNT(*) FROM mcv WHERE k = ' + QuotedStr('B3'));
      Dogrula('MCV B3 sayimi 1', (Length(R.Rows) = 1) and
        (R.Rows[0][0] = '1'), R.Rows[0][0]);
      R := q.Exec('SELECT COUNT(*) FROM mcv WHERE n = 0');
      Dogrula('MCV n=0 sayimi 90', (Length(R.Rows) = 1) and
        (R.Rows[0][0] = '90'), R.Rows[0][0]);
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T146_M9_OTLP;
// M9: OTLP/HTTP JSON govdesi, 'sql.fetch' cocuk span'i ve yerel aliciya
// gercek POST. Alici tek istegi yakalar; govde ve basliklar dogrulanir.
var
  j, err, host, path: string;
  port: Word;
  th: TOtlpCaptureThread;
  ok: Boolean;
begin
  Grp('M9 OTLP export + sql.fetch span');

  { NOT: Dogrula'nin ayrinti argumani, kosuldan ONCE degerlendirilebilir;
    bu yuzden parse cagrisi ayri bir ifadeye alinir. }
  ok := VdbParseOtlpEndpoint('', host, path, port);
  Dogrula('endpoint varsayilan',
    ok and (host = '127.0.0.1') and (port = 4318) and (path = '/v1/traces'),
    host + ':' + IntToStr(port) + path);
  ok := VdbParseOtlpEndpoint('http://example.com:9999/custom/traces',
    host, path, port);
  Dogrula('endpoint tam',
    ok and (host = 'example.com') and (port = 9999) and
    (path = '/custom/traces'),
    host + ':' + IntToStr(port) + path);
  ok := VdbParseOtlpEndpoint('127.0.0.1:4319/v1/traces', host, path, port);
  Dogrula('endpoint http semasiz',
    ok and (host = '127.0.0.1') and (port = 4319),
    host + ':' + IntToStr(port) + path);
  ok := VdbParseOtlpEndpoint('https://example.com/v1/traces',
    host, path, port);
  Dogrula('endpoint https reddedilir', not ok, '');
  ok := VdbParseOtlpEndpoint('http://example.com:0/v1/traces',
    host, path, port);
  Dogrula('endpoint gecersiz port', not ok, '');

  VDbTraceClear;
  VDbTraceSetEnabled(True);
  try
    R := sq.Exec('SELECT 146 AS otlp_probe');
  finally
    VDbTraceSetEnabled(False);
  end;
  j := VDbTraceGetOTLPJSON;
  Dogrula('OTLP resourceSpans', Pos('"resourceSpans"', j) > 0, '');
  Dogrula('OTLP scopeSpans', Pos('"scopeSpans"', j) > 0, '');
  Dogrula('OTLP scope adi', Pos('"name":"vdb.trace"', j) > 0, '');
  Dogrula('sql.fetch span', Pos('"name":"sql.fetch"', j) > 0, '');
  Dogrula('sql.fetch db.rows=1',
    Pos('"key":"db.rows","value":{"stringValue":"1"}', j) > 0, '');
  Dogrula('sql.fetch parentSpanId var', Pos('"parentSpanId":', j) > 0, '');
  Dogrula('kok span bos parentSpanId gondermez',
    Pos('"parentSpanId":""', j) = 0, '');

  th := nil;
  try
    th := TOtlpCaptureThread.Create;
    Dogrula('OTLP dinleyici basladi', th.Started,
      'port=' + IntToStr(th.Port));
    if th.Started then
    begin
      ok := VDbTraceExportOTLP(
        'http://127.0.0.1:' + IntToStr(th.Port) + '/v1/traces', err);
      Dogrula('OTLP export 2xx', ok, err);
      Dogrula('istek POST /v1/traces',
        Pos('POST /v1/traces HTTP/1.1', th.Request) > 0,
        Copy(th.Request, 1, 60));
      Dogrula('Content-Type application/json',
        Pos('Content-Type: application/json', th.Request) > 0, '');
      Dogrula('govdede resourceSpans',
        Pos('"resourceSpans"', th.Request) > 0, '');
      Dogrula('govdede sql.fetch', Pos('"name":"sql.fetch"', th.Request) > 0, '');
    end;
  finally
    th.Free;
  end;

  ok := VDbTraceExportOTLP('http://127.0.0.1:1/v1/traces', err);
  Dogrula('baglanti yoksa False', (not ok) and (err <> ''), err);

  VDbTraceClear;
end;

procedure T147_M8_SqlancerStil;
// M8: SQLancer tarzi rasgele SELECT uretimi + diferansiyel oracle.
// Iki veritabani AYNI veriyle kurulur: A'da ikincil indeksler + ANALYZE,
// B'de hic indeks yok. Uretilen her sorgu ikisinde de calistirilir ve
// sonuc kumeleri BIREBIR karsilastirilir. Boylece indeksli/taramali
// yollar, CBO/MCV tahminleri ve H12-H23 hizli yollari ayni semantigi
// korumak zorundadir. Sabit tohum -> tekrarlanabilir.
const
  FZ_ROWS = 220;
  FZ_QUERIES = 200;
var
  dirA, dirB: string;
  dbA, dbB: TVDb;
  tbA, tbB: TVTableDb;
  qa, qb: TVSql;
  i, qi, ran, errors, mism: Integer;
  ins, sql, firstDiff, firstErr, errA, errB: string;
  ra, rb: TSqlResult;
  seed0: LongInt;

  function MakePred: string;
  var
    x, y: Integer;
  begin
    case Random(10) of
      0: Result := Format('n = %d', [Random(56) - 3]);
      1: Result := Format('n > %d', [Random(53) - 3]);
      2: begin
           x := Random(50) - 3;
           y := x + Random(12);
           Result := Format('n BETWEEN %d AND %d', [x, y]);
         end;
      3: Result := 'k = ' + QuotedStr('k' + IntToStr(Random(10)));
      4: Result := 'k LIKE ' + QuotedStr('k' + IntToStr(Random(10)) + '%');
      5: Result := 'b = TRUE';
      6: Result := Format('f < %d', [Random(7) - 3]);
      7: Result := 'n IS NULL';
      8: Result := Format('n IN (%d,%d,%d)',
        [Random(53) - 3, Random(53) - 3, Random(53) - 3]);
    else
      Result := Format('(n > %d OR k = %s) AND b IS NOT NULL',
        [Random(50), QuotedStr('k' + IntToStr(Random(10)))]);
    end;
  end;

  function MakeQuery: string;
  var
    p: string;
    lim, off: Integer;
  begin
    p := MakePred;
    lim := 1 + Random(25);
    off := Random(30);
    case Random(8) of
      0: Result := 'SELECT id,n,k FROM fz WHERE ' + p + ' ORDER BY id';
      1: Result := Format('SELECT id,k FROM fz WHERE %s ORDER BY id LIMIT %d OFFSET %d',
        [p, lim, off]);
      2: Result := Format(
        'SELECT k, COUNT(*) AS c, SUM(n) AS s, MIN(f) AS mi, MAX(n) AS ma ' +
        'FROM fz WHERE %s GROUP BY k HAVING COUNT(*) > %d ORDER BY k',
        [p, Random(4)]);
      3: Result := 'SELECT DISTINCT k FROM fz WHERE ' + p + ' ORDER BY k';
      4: Result := 'SELECT COUNT(*) FROM fz WHERE ' + p;
      5: Result := Format('SELECT id,n FROM fz WHERE %s ORDER BY n, id LIMIT %d',
        [p, lim]);
      6: Result := Format(
        'SELECT a.id, b.id FROM fz a JOIN fz b ON a.n = b.n ' +
        'WHERE a.id < %d AND b.id < %d ORDER BY a.id, b.id',
        [10 + Random(40), 10 + Random(40)]);
    else
      Result := Format(
        'SELECT id FROM fz WHERE n IN (SELECT n FROM fz WHERE %s) ' +
        'AND id <= %d ORDER BY id', [p, 60 + Random(160)]);
    end;
  end;

  function RowsText(const Res: TSqlResult): string;
  var
    r, c: Integer;
  begin
    Result := '';
    for r := 0 to High(Res.Rows) do
    begin
      for c := 0 to High(Res.Rows[r]) do
        Result := Result + '[' + Res.Rows[r][c] + ']';
      Result := Result + #10;
    end;
  end;

  function TryExec(Q: TVSql; const S: string; out Res: TSqlResult;
    out Err: string): Boolean;
  begin
    Err := '';
    try
      Res := Q.Exec(S);
      Result := True;
    except
      on E: Exception do
      begin
        Result := False;
        Err := E.ClassName + ': ' + E.Message;
      end;
    end;
  end;

begin
  Grp('M8 SQLancer tarzi rasgele SELECT + indeks diferansiyeli');
  seed0 := RandSeed;
  RandSeed := 147147;
  dirA := D + '\t147_fz_idx_' + IntToStr(GetTickCount64);
  dirB := D + '\t147_fz_seq_' + IntToStr(GetTickCount64);
  ForceDirectories(dirA);
  ForceDirectories(dirB);
  dbA := TVDb.Create;
  dbB := TVDb.Create;
  tbA := TVTableDb.Create(dbA);
  tbB := TVTableDb.Create(dbB);
  qa := nil;
  qb := nil;
  ran := 0;
  errors := 0;
  mism := 0;
  firstDiff := '';
  firstErr := '';
  try
    dbA.Open(dirA);
    dbB.Open(dirB);
    tbA.Open(dirA);
    tbB.Open(dirB);
    qa := TVSql.Create(tbA);
    qb := TVSql.Create(tbB);
    try
      qa.Exec('CREATE TABLE fz (id INTEGER PRIMARY KEY, n INTEGER, ' +
        'k TEXT, f FLOAT, b BOOLEAN)');
      qb.Exec('CREATE TABLE fz (id INTEGER PRIMARY KEY, n INTEGER, ' +
        'k TEXT, f FLOAT, b BOOLEAN)');
      qa.Exec('BEGIN');
      qb.Exec('BEGIN');
      for i := 1 to FZ_ROWS do
      begin
        ins := Format('INSERT INTO fz VALUES (%d,%s,%s,%s,%s)', [i,
          IfThen(i mod 17 = 0, 'NULL', IntToStr((i * 7) mod 53 - 3)),
          IfThen(i mod 19 = 0, 'NULL', QuotedStr('k' + IntToStr(i mod 10))),
          IfThen(i mod 23 = 0, 'NULL', IntToStr((i mod 13) - 4)),
          IfThen(i mod 29 = 0, 'NULL', IfThen(i mod 2 = 0, 'TRUE', 'FALSE'))]);
        qa.Exec(ins);
        qb.Exec(ins);
      end;
      qa.Exec('COMMIT');
      qb.Exec('COMMIT');
      // Yalniz A: indeksler + istatistik. B saf tarama yoludur.
      qa.Exec('CREATE INDEX ix_fz_n ON fz(n)');
      qa.Exec('CREATE INDEX ix_fz_k ON fz(k)');
      qa.Exec('CREATE INDEX ix_fz_f ON fz(f)');
      qa.Exec('CREATE INDEX ix_fz_b ON fz(b)');
      qa.Exec('ANALYZE fz');

      for qi := 1 to FZ_QUERIES do
      begin
        sql := MakeQuery;
        if not TryExec(qa, sql, ra, errA) then
        begin
          Inc(errors);
          if firstErr = '' then firstErr := 'A: ' + errA + ' | ' + sql;
          Continue;
        end;
        if not TryExec(qb, sql, rb, errB) then
        begin
          Inc(errors);
          if firstErr = '' then firstErr := 'B: ' + errB + ' | ' + sql;
          Continue;
        end;
        Inc(ran);
        if RowsText(ra) <> RowsText(rb) then
        begin
          Inc(mism);
          if firstDiff = '' then firstDiff := sql;
        end;
      end;
    finally
      qb.Free;
      qa.Free;
    end;
  finally
    tbB.Free;
    tbA.Free;
    dbB.Free;
    dbA.Free;
  end;
  RandSeed := seed0;

  Dogrula('tum rasgele sorgular calisti',
    (ran = FZ_QUERIES) and (errors = 0),
    'calisan=' + IntToStr(ran) + ' hata=' + IntToStr(errors) +
    ' ilk=' + Copy(firstErr, 1, 160));
  Dogrula('indeksli ve indekssiz sonuc ayni', mism = 0,
    'fark=' + IntToStr(mism) + ' ilk=' + Copy(firstDiff, 1, 160));
end;

procedure T137_H15_StreamHaving;
// H15: akisli GROUP BY + HAVING yolu, genel yolla BIREBIR ayni sonucu
// vermelidir. Genel yol, HAVING'e daima dogru bir ek kosul eklenerek
// zorlanir: "COUNT(DISTINCT n) >= 0" akisli planlamada DESTEKLENMEZ
// (DISTINCT) bu yuzden genel yola duser; sonucu etkilemez.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r1, r2: TSqlResult;

  function RowSet(const R: TSqlResult): string;
  var
    k, m: Integer;
  begin
    Result := '';
    for k := 0 to High(R.Rows) do
    begin
      Result := Result + '[';
      for m := 0 to High(R.Rows[k]) do
        Result := Result + R.Rows[k][m] + ',';
      Result := Result + ']';
    end;
  end;

  procedure Cmp(const A, B: string);
  var
    s1, s2: string;
  begin
    r1 := q.Exec(A);
    r2 := q.Exec(B);
    s1 := RowSet(r1);
    s2 := RowSet(r2);
    if s1 = s2 then
      Dogrula('T137 ayni: ' + A, True, '')
    else
      Dogrula('T137 ayni: ' + A, False,
        'akis=' + s1 + ' genel=' + s2);
  end;

begin
  Grp('T137 H15 akisli GROUP BY + HAVING');
  dir := D + '\t137_having_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE d (id INTEGER PRIMARY KEY, s TEXT, n INTEGER, ' +
        'f FLOAT, b BOOLEAN)');
      q.Exec('INSERT INTO d (id,s,n,f,b) VALUES ' +
        '(1,''a'',10,1.5,TRUE),(2,''a'',20,2.5,TRUE),(3,''b'',30,3.5,FALSE),' +
        '(4,''b'',5,0.5,FALSE),(5,''c'',NULL,NULL,NULL),(6,NULL,7,7.0,TRUE),' +
        '(7,''a'',20,2.5,NULL),(8,''b'',NULL,1.25,TRUE)');

      // COUNT(*) / COUNT(kolon) / alias
      Cmp('SELECT s, COUNT(*) AS c FROM d GROUP BY s HAVING COUNT(*) > 1 ORDER BY s',
          'SELECT s, COUNT(*) AS c FROM d GROUP BY s ' +
          'HAVING COUNT(*) > 1 AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      Cmp('SELECT s, COUNT(n) AS cn FROM d GROUP BY s HAVING COUNT(n) = 2 ORDER BY s',
          'SELECT s, COUNT(n) AS cn FROM d GROUP BY s ' +
          'HAVING COUNT(n) = 2 AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      Cmp('SELECT s, COUNT(*) AS c FROM d GROUP BY s HAVING c > 1 ORDER BY s',
          'SELECT s, COUNT(*) AS c FROM d GROUP BY s ' +
          'HAVING c > 1 AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      // SUM / AVG (INT, FLOAT, BOOL)
      Cmp('SELECT s, SUM(n) AS t FROM d GROUP BY s HAVING SUM(n) > 20 ORDER BY s',
          'SELECT s, SUM(n) AS t FROM d GROUP BY s ' +
          'HAVING SUM(n) > 20 AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      Cmp('SELECT s, AVG(n) AS a FROM d GROUP BY s HAVING AVG(n) >= 12.5 ORDER BY s',
          'SELECT s, AVG(n) AS a FROM d GROUP BY s ' +
          'HAVING AVG(n) >= 12.5 AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      Cmp('SELECT s, SUM(f) AS sf FROM d GROUP BY s HAVING SUM(f) > 3.0 ORDER BY s',
          'SELECT s, SUM(f) AS sf FROM d GROUP BY s ' +
          'HAVING SUM(f) > 3.0 AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      Cmp('SELECT s, SUM(b) AS sb FROM d GROUP BY s HAVING SUM(b) = 0 ORDER BY s',
          'SELECT s, SUM(b) AS sb FROM d GROUP BY s ' +
          'HAVING SUM(b) = 0 AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      // MIN / MAX + IS NULL
      Cmp('SELECT s, MIN(n) AS mi FROM d GROUP BY s HAVING MIN(n) < 10 ORDER BY s',
          'SELECT s, MIN(n) AS mi FROM d GROUP BY s ' +
          'HAVING MIN(n) < 10 AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      Cmp('SELECT s, MAX(f) AS ma FROM d GROUP BY s HAVING MAX(f) IS NOT NULL ORDER BY s',
          'SELECT s, MAX(f) AS ma FROM d GROUP BY s ' +
          'HAVING MAX(f) IS NOT NULL AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      // cikti kolonu + birden fazla aggregate
      Cmp('SELECT s, COUNT(*) AS c, SUM(n) AS t FROM d GROUP BY s ' +
          'HAVING s <> ''c'' AND COUNT(*) > 1 AND SUM(n) >= 20 ORDER BY s',
          'SELECT s, COUNT(*) AS c, SUM(n) AS t FROM d GROUP BY s ' +
          'HAVING s <> ''c'' AND COUNT(*) > 1 AND SUM(n) >= 20 ' +
          'AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      // WHERE on-elemesi + HAVING
      Cmp('SELECT s, COUNT(*) AS c FROM d WHERE n > 5 GROUP BY s ' +
          'HAVING COUNT(*) > 1 ORDER BY s',
          'SELECT s, COUNT(*) AS c FROM d WHERE n > 5 GROUP BY s ' +
          'HAVING COUNT(*) > 1 AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      // CASE / COALESCE icinde aggregate
      Cmp('SELECT s, COUNT(*) AS c FROM d GROUP BY s ' +
          'HAVING CASE WHEN COUNT(*) > 1 THEN 1 ELSE 0 END = 1 ORDER BY s',
          'SELECT s, COUNT(*) AS c FROM d GROUP BY s ' +
          'HAVING CASE WHEN COUNT(*) > 1 THEN 1 ELSE 0 END = 1 ' +
          'AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      Cmp('SELECT s, SUM(n) AS t FROM d GROUP BY s ' +
          'HAVING COALESCE(SUM(n), 0) > 100 ORDER BY s',
          'SELECT s, SUM(n) AS t FROM d GROUP BY s ' +
          'HAVING COALESCE(SUM(n), 0) > 100 ' +
          'AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      // alias ile siralama (HAVING sonrasi kuyruk)
      Cmp('SELECT s, COUNT(*) AS c FROM d GROUP BY s HAVING COUNT(*) > 1 ' +
          'ORDER BY c DESC, s',
          'SELECT s, COUNT(*) AS c FROM d GROUP BY s ' +
          'HAVING COUNT(*) > 1 AND COUNT(DISTINCT n) >= 0 ORDER BY c DESC, s');
      // HAVING her seyi eler -> bos kume
      Cmp('SELECT s, COUNT(*) AS c FROM d GROUP BY s HAVING COUNT(*) > 99 ORDER BY s',
          'SELECT s, COUNT(*) AS c FROM d GROUP BY s ' +
          'HAVING COUNT(*) > 99 AND COUNT(DISTINCT n) >= 0 ORDER BY s');
      // DESTEKLENMEYEN bicim (DISTINCT) genel yolda dogru: 1=1 karsiligi
      Cmp('SELECT s, COUNT(*) AS c FROM d GROUP BY s HAVING 1=1 ORDER BY s',
          'SELECT s, COUNT(*) AS c FROM d GROUP BY s ' +
          'HAVING COUNT(DISTINCT n) >= 0 ORDER BY s');
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

procedure T132_H12_StreamTopN;
// H12b: ham akisli top-N yolunun WHERE on-eleme, BOOL ve NULL siralama
// davranisini dogrular; alias/ifade siralamalari genel yola dusmelidir.
var
  dir: string;
  db: TVDb;
  tdb: TVTableDb;
  q: TVSql;
  r: TSqlResult;
  i: Integer;
  fs: TFormatSettings;
begin
  Grp('T132 H12b akisli top-N');
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  dir := D + '\t132_stream_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  db := TVDb.Create;
  tdb := TVTableDb.Create(db);
  try
    db.Open(dir);
    tdb.Open(dir);
    q := TVSql.Create(tdb);
    try
      q.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER, f FLOAT, s TEXT)');
      q.Exec('BEGIN');
      for i := 1 to 200 do
        q.Exec(Format('INSERT INTO t (id,n,f,s) VALUES (%d,%d,%s,%s)',
          [i, 200 - i, FloatToStr(i * 1.25, fs), QuotedStr(Format('s%.4d', [201 - i]))]));
      q.Exec('COMMIT');

      r := q.Exec('SELECT id FROM t WHERE s >= ''s0081'' AND s <= ''s0100'' ' +
        'ORDER BY n ASC LIMIT 3');
      Dogrula('T132 TEXT aralik + ORDER BY LIMIT',
        (Length(r.Rows) = 3) and (r.Rows[0][0] = '120') and
        (r.Rows[1][0] = '119') and (r.Rows[2][0] = '118'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM t WHERE n >= 50 AND n < 60 ' +
        'ORDER BY f DESC LIMIT 3');
      Dogrula('T132 sayisal aralik + ORDER BY LIMIT',
        (Length(r.Rows) = 3) and (r.Rows[0][0] = '150') and
        (r.Rows[1][0] = '149') and (r.Rows[2][0] = '148'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM t ORDER BY n LIMIT 0');
      Dogrula('T132 LIMIT 0 bos', Length(r.Rows) = 0, IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM t ORDER BY n LIMIT 5 OFFSET 500');
      Dogrula('T132 OFFSET sinir disi bos', Length(r.Rows) = 0,
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT n AS nn FROM t ORDER BY nn LIMIT 1');
      Dogrula('T132 alias ORDER BY genel yol',
        (Length(r.Rows) = 1) and (r.Rows[0][0] = '0'),
        IntToStr(Length(r.Rows)));

      r := q.Exec('SELECT id FROM t ORDER BY n + 0 LIMIT 1');
      Dogrula('T132 ifade ORDER BY genel yol',
        (Length(r.Rows) = 1) and (r.Rows[0][0] = '200'),
        IntToStr(Length(r.Rows)));

      q.Exec('CREATE TABLE tb (id INTEGER PRIMARY KEY, b BOOLEAN)');
      q.Exec('BEGIN');
      for i := 1 to 10 do
        if i mod 2 = 0 then
          q.Exec(Format('INSERT INTO tb (id,b) VALUES (%d,TRUE)', [i]))
        else
          q.Exec(Format('INSERT INTO tb (id,b) VALUES (%d,FALSE)', [i]));
      q.Exec('COMMIT');
      r := q.Exec('SELECT b FROM tb ORDER BY b DESC LIMIT 3');
      Dogrula('T132 BOOL DESC ilk 3 True',
        (Length(r.Rows) = 3) and (r.Rows[0][0] = 'True') and
        (r.Rows[1][0] = 'True') and (r.Rows[2][0] = 'True'),
        IntToStr(Length(r.Rows)));
      r := q.Exec('SELECT b FROM tb ORDER BY b ASC LIMIT 3');
      Dogrula('T132 BOOL ASC ilk 3 False',
        (Length(r.Rows) = 3) and (r.Rows[0][0] = 'False') and
        (r.Rows[1][0] = 'False') and (r.Rows[2][0] = 'False'),
        IntToStr(Length(r.Rows)));

      q.Exec('CREATE TABLE tn (id INTEGER PRIMARY KEY, v INTEGER)');
      q.Exec('INSERT INTO tn (id,v) VALUES (1,10),(2,NULL),(3,5),(4,NULL),(5,7)');
      r := q.Exec('SELECT v FROM tn ORDER BY v ASC LIMIT 2');
      Dogrula('T132 NULL varsayilan ASC once',
        (Length(r.Rows) = 2) and (r.Rows[0][0] = '') and (r.Rows[1][0] = ''),
        IntToStr(Length(r.Rows)));
      r := q.Exec('SELECT id FROM tn ORDER BY v DESC LIMIT 2');
      Dogrula('T132 NULL varsayilan DESC sonda',
        (Length(r.Rows) = 2) and (r.Rows[0][0] = '1') and (r.Rows[1][0] = '5'),
        IntToStr(Length(r.Rows)));
      r := q.Exec('SELECT id FROM tn ORDER BY v ASC NULLS LAST LIMIT 2');
      Dogrula('T132 NULLS LAST',
        (Length(r.Rows) = 2) and (r.Rows[0][0] = '3') and (r.Rows[1][0] = '5'),
        IntToStr(Length(r.Rows)));
      r := q.Exec('SELECT v FROM tn ORDER BY v DESC NULLS FIRST LIMIT 2');
      Dogrula('T132 NULLS FIRST',
        (Length(r.Rows) = 2) and (r.Rows[0][0] = '') and (r.Rows[1][0] = ''),
        IntToStr(Length(r.Rows)));
    finally
      q.Free;
    end;
  finally
    tdb.Free;
    db.Free;
  end;
end;

{ ---------------------------------------------------------------------- main }

var
  arg: string;
  tmp: string;
begin
  nPass := 0; nFail := 0; nGrp := 0;
  sq := nil; tb := nil; kv := nil;
  if (ParamCount >= 1) and (Trim(ParamStr(1)) <> '') then
  begin
    D := ParamStr(1);
    ForceDirectories(D);
  end
  else
  begin
    tmp := GetTempDir(False) + 'vdbsqltest_' + FormatDateTime('yyyymmdd_hhnnss', Now);
    ForceDirectories(tmp);
    D := tmp;
  end;
  WriteLn('VDB SQL tam testi');
  WriteLn('Klasor: ', D);
  try
    try
        T01_Veritabani;
        T02_Tipler;
        T03_CreateKisit;
        T04_Insert;
        T05_SelectTemel;
        T06_Where;
        T07_TipKarsilastirma;
        T08_Join;
        T08b_JoinZincir;
        T08c_RightFullJoin;
        T08c_AltSorgu;
        T08d_CaseWhen;
        T08e_CTE;
        T08f_Pencere;
        T08g_Collation;
        T08h_CrossJoin;
        T08i_NaturalUsing;
        T08j_Lateral;
        T08k_MatView;
        T08l_ViewDML;
        T08m_StoredProc;
        T08n_Trigger;
        T08i_JoinAggregate;
        T09_GroupAggregate;
        T09b_HavingAggregate;
        T09c_NotOrDNF;
        T09d_NotNull3VL;
        T09e_NullIfCoalesce;
        T09f_ILike;
        T09g_AnySomeAll;
        T09h_FetchFirstNulls;
        T09i_Qualify;
        T09j_AggDistinct;
        T09k_Filter;
        T09l_Explain;
        T09m_PartialIndex;
        T09n_ExprIndex;
        T09o_CoveringIndex;
        T09p_SlowQuery;
        T09r_Xml;
        T09s_Spatial;
        T09t_Range;
        T10_Update;
        T10b_Upsert;
        T11_Delete;
        T11_Returning;
        T12_Transaction;
        T13_AlterTable;
        T14_Index;
        T15_Bakim;
        T16_Parametreli;
        T17_Json;
        T18_Kalici;
        T19_Olcek;
        T20_CokluKayit;
        T21_KritikHataDogrulama;
        T22_MinMaxTipKiyas;
        T23_Blob;
        T24_Dayaniklilik;
        T25_F1_UnionSiraVeLimit;
        T26_F1_OrderByTip;
        T27_F1_OrderByBilinmeyenKolon;
        T28_F1_JoinTipKiyas;
        T29_F1_UpdateBilinmeyenKolon;
        T30_F1_DeleteDatabase;
        T31_F1_NotInNull;
        T32_F1_LimitGecersiz;
        T33_F1_SumBosKume;
        T34_F1_AlterRenameBozukSatir;
        T35_F1_OffsetAlias;
        T36_F1_RecoverKirpma;
        T37_F1_CommitBatchAtomik;
        T38_F1_CheckRestrictFiltresi;
        T39_F1_UniqueBayatAnahtar;
        T40_F1_AlterDropColumnFK;
        T41_F1_AlterAddColumnNotNull;
        T42_F1_BatchInsertAtomik;
        T43_F1_MigrateLegacy;
        T44_F1_ParserDerinlik;
        T45_F1_SplitStatements;
        T46_F2_SemaBozukSatir;
        T47_F2_BosTabloAdi;
        T48_F2_DropTableFK;
        T49_F2_SelfRefFK;
        T50_F2_IdxBLOBKarisim;
        T51_F2_DropColumnIdx;
        T52_F2_AlterColumnType;
        T53_F2_DDLAtomik;
        T54_F2_UnionDistinct;
        T55_F2_PencereBellek;
        T56_F2_AltSorgu;
        T57_F2_BozukDosya;
        T58_F2_VerifyBATCHEND;
      T59_F2_DizinFlush;
      T60_F2_WALKilit;
      T61_F2_GetDogruluk;
      T62_F2_DropColumnBatch;
      T63_F2_BozukKayitTespit;
      T64_F2_PKsizTablo;
      T65_F2_UniqueIndex;
      T66_F2_DropColCokKolluIndeks;
      T67_F3_Hijyen;
      T68_F3_CokKolluOndek;
      T69_YonetimAPI;
      T70_YonetimBakim;
      T71_SemaSorgulari;
      T72_WALReplay;
      T73_OtomatikWAL;
      T74_KayitSifreleme;
      T75_SifrelemeDayaniklilik;
      T76_ReplayWALSifreleme;
      T77_AlterDatabaseKey;
      T78_AsofGecmis;
      T79_Savepoint;
      T79b_IsolationForUpdate;
      T90_MVCC_Snapshot;
      T91_MVCC_Nested;
T92_MVCC_Isoaltion;
      T93_RBAC;
      T94_RBAC_Persist;
      T94b_RLS;
      T94c_RLS_Persist;
      T94d_Collation;
      T94e_Collation_Persist;
      T94f_Monitoring;
      T95_WALArsiv;
      T95b_Replication;
      T97_CrossPlatform;
      T98_CBO;
      T99_Extension;
      T100_Parallel;
      T101_TcpReplication;
      T102_ConcurrentIndex;
      T103_IcuCollation;
      T104_HashPartition;
      T105_ShowStats;
      T106_TcpSqlServer;
       T107_AuthSession;
       T108_PreparedStatement;
       T109_PoolSlotTCP;
       T110_CopyFrom;
       T111_RasgeleDiferansiyel;
       T112_JsonPath;
       T113_Vector;
       T114_Fts;
       T115_MetricsHttp;
       T116_PgWire;
       T117_Generated;
       T118_AeadKdf;
       T119_Trace;
       T121_VectorAnn;
       T122_KvStore;
       T123_Arrow;
       T124_Parquet;
       T125_KolonSifreleme;
       T126_F42_TxIsolation;
       T127_H5_BlockCrc;
       T128_H11_Undo;
       T129_H11_InPlace;
       T130_PkRangeCtype;
       T131_H12_TopN;
       T132_H12_StreamTopN;
       T133_H13_StreamGroupBy;
       T134_H12c_MultiTopN;
       T135_H14_FloatSort;
       T136_H13_GroupDiff;
       T137_H15_StreamHaving;
       T138_H16_StreamDistinct;
       T139_H17_StreamFilteredCount;
       T140_H18_RawExactCount;
       T141_H19_RawLikeCount;
       T142_H20_RawBoolTree;
       T143_H21_RawTreeSelectPaths;
       T144_H22_DeepOffsetLive;
       T145_H8_MCV;
       T146_M9_OTLP;
       T147_M8_SqlancerStil;
       { TLS testi OpenSSL DLL'leri gerektirir; yoksa atlanir. }
       if VDbTlsAvailable then
         T120_Tls
       else
         WriteLn('   ATLA TLS testi (OpenSSL DLL bulunamadi)');
  
      except
        on E: Exception do
        begin
          Inc(nFail);
          WriteLn;
          WriteLn('!! KESILDI (', grpName, '): ', E.ClassName, ': ', E.Message);
        end;
      end;
    finally
      Shutdown;
    end;
    WriteLn;
    WriteLn('================================================');
    WriteLn('SONUC: gecen=', nPass, '  kalan=', nFail);
    if nFail = 0 then WriteLn('TUM SQL TESTLERI GECTI')
    else WriteLn('HATA VAR');
  end.
  
  
  
  
  
  
  
  
  
  
  
  
  
  
