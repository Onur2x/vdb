program VsBench;

{$mode delphi}
{$APPTYPE CONSOLE}

{ TR: VDB vs SQLite ADIL hiz karsilastirmasi.
    - AYNI asama listesi, AYNI SQL metni, AYNI veri uretimi, AYNI disk (C:\temp)
    - Her iki motor da stok varsayilanlariyla: VDB SyncWriteInterval=0
      (senkron commit sozlesmesi), SQLite synchronous=FULL + journal DELETE
    - SQLite native yuklenir: yanindaki resmi sqlite.org 32-bit DLL
      (surum baslikta yazilir); her iki motor da AYNI surecte, AYNI mimaride
    - Olcum QueryPerformanceCounter ile (mikrosaniye)
  EN: Fair VDB vs SQLite speed comparison.
    Same phases, same SQL text, same data generation, same disk. Stock
    defaults on both sides. SQLite loaded natively via sqlite3.dll. }

uses
  Windows, SysUtils, Classes, VDbCore, VDbTable, VDbSql, VDbTypes;

const
  N = 1000000;          // satir
  PK_N = 50000;         // nokta arama adedi
  RANGE_N = 2000;       // aralik sorgu adedi
  MUT_N = 100000;       // UPDATE / DELETE adedi
  VdbPath = 'C:\temp\vs_vdb';
  SqlPath = 'C:\temp\vs_sqlite.db';
  SqlDll = 'sqlite3.dll';   // yanina konan resmi sqlite.org 32-bit build

type
  TPh = record
    Name: string;
    US: Int64;
  end;
  TPhArr = array of TPh;

  TSqlite3Open = function(fn: PAnsiChar; out db: Pointer): Integer; cdecl;
  TSqlite3Close = function(db: Pointer): Integer; cdecl;
  TSqlite3Exec = function(db: Pointer; sql: PAnsiChar; cb, arg: Pointer;
    errmsg: PPAnsiChar): Integer; cdecl;
  TSqlite3Errmsg = function(db: Pointer): PAnsiChar; cdecl;
  TSqlite3Libversion = function: PAnsiChar; cdecl;

var
  sqOpen: TSqlite3Open;
  sqClose: TSqlite3Close;
  sqExec: TSqlite3Exec;
  sqErrmsg: TSqlite3Errmsg;
  sqLibver: TSqlite3Libversion;
  QPF: Int64;
  gSink: Integer;                      // sonuc dokunma sayaci (dead-code icin)
  gVal: string;                        // callback ilk kolon degeri
  gCntV, gCntS: string;                // COUNT degerleri (kontrol)
  gSumV, gSumS: string;                // SUM degerleri (kontrol)
  gCntAfterV, gCntAfterS: string;      // DELETE sonrasi 900k kontrolu
  gSzV, gSzS: Int64;                   // dosya boyutu (INSERT sonrasi)

const
  SQL_DDL = 'CREATE TABLE musteri(id INTEGER PRIMARY KEY, ad TEXT, ' +
    'yas INTEGER, bakiye DOUBLE, notu TEXT)';

function QNow: Int64;
begin
  QueryPerformanceCounter(Result);
end;

function USpan(A, B: Int64): Int64;
// A -> B suresi (mikrosaniye); QPF globali kullanilir
begin
  Result := ((B - A) * 1000000) div QPF;
end;

function FmtUS(AUS: Int64): string;
begin
  if AUS >= 1000000 then
    Result := Format('%.2f sn', [AUS / 1000000.0])
  else
    Result := Format('%.1f ms', [AUS / 1000.0]);
end;

procedure AddPh(var A: TPhArr; const AName: string; AUS: Int64);
var
  k: Integer;
begin
  k := Length(A);
  SetLength(A, k + 1);
  A[k].Name := AName;
  A[k].US := AUS;
end;

function FileSizeOf(const AFile: string): Int64;
var
  rec: TSearchRec;
begin
  if FindFirst(AFile, faAnyFile, rec) = 0 then
  begin
    Result := rec.Size;
    FindClose(rec);
  end
  else
    Result := -1;
end;

function Mb(AB: Int64): Double;
begin
  Result := AB / (1024.0 * 1024.0);
end;

function DirSize(const ADir: string): Int64;
var
  rec: TSearchRec;
  res: Integer;
begin
  Result := 0;
  res := FindFirst(IncludeTrailingPathDelimiter(ADir) + '*.*', faAnyFile, rec);
  while res = 0 do
  begin
    if (rec.Attr and faDirectory) = 0 then
      Inc(Result, rec.Size);
    res := FindNext(rec);
  end;
  FindClose(rec);
end;

procedure CleanDir(const ADir: string);
// dizindeki tum dosyalari sil (alt dizinlere inmez - VDB duz kullanir)
var
  rec: TSearchRec;
  res: Integer;
begin
  if not DirectoryExists(ADir) then
    Exit;
  res := FindFirst(IncludeTrailingPathDelimiter(ADir) + '*.*', faAnyFile, rec);
  while res = 0 do
  begin
    if (rec.Attr and faDirectory) = 0 then
      DeleteFile(IncludeTrailingPathDelimiter(ADir) + rec.Name);
    res := FindNext(rec);
  end;
  FindClose(rec);
end;

function InsertSql(i: Integer): string;
// iki motora birebir ayni INSERT metni
begin
  Result := Format(
    'INSERT INTO musteri(id,ad,yas,bakiye,notu) VALUES(%d,''musteri-%d'',%d,%d.5,''aciklama metni %d'')',
    [i, i, i mod 80, i mod 10000, i]);
end;

function PkSql(i: Integer): string;
begin
  Result := 'SELECT ad,yas,bakiye FROM musteri WHERE id = ' +
    IntToStr((Int64(i) * Int64(N)) div PK_N);
end;

function RangeSql(i: Integer): string;
var
  lo: Int64;
begin
  lo := (Int64(i) * 900000) div RANGE_N;
  Result := Format('SELECT ad,yas,bakiye FROM musteri WHERE id BETWEEN %d AND %d',
    [lo, lo + 99]);
end;

function NumOf(const S: string): Double;
var
  fs: TFormatSettings;
  t: string;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  fs.ThousandSeparator := #0;
  t := StringReplace(S, ',', '.', [rfReplaceAll]);
  try
    Result := StrToFloat(t, fs);
  except
    Result := -1e300;
  end;
end;

{ ---------------- SQLite sonuc geri-cagirmasi ---------------- }

function RowCB(arg: Pointer; nCol: Integer; vals, names: PPAnsiChar): Integer;
  cdecl;   // SQLite C kutuhanesi -> geri cagri cdecl olmali (!)
var
  i: Integer;
  p: PPointer;
  s: PAnsiChar;
begin
  Result := 0;
  if (nCol <= 0) or (vals = nil) then
    Exit;
  p := PPointer(vals);
  for i := 0 to nCol - 1 do
  begin
    s := PAnsiChar(p[i]);
    if s <> nil then
    begin
      Inc(gSink, Integer(StrLen(s)));
      if i = 0 then
        gVal := string(AnsiString(s));
    end;
  end;
end;

procedure ExecSq(db: Pointer; const ASql: string);
var
  em: PAnsiChar;
  rc: Integer;
begin
  em := nil;
  rc := sqExec(db, PAnsiChar(AnsiString(ASql)), nil, nil, @em);
  if rc <> 0 then
    raise Exception.CreateFmt('SQLite exec hatasi %d: %s (sql: %s)',
      [rc, string(AnsiString(sqErrmsg(db))), Copy(ASql, 1, 60)]);
end;

function ExecSqCb(db: Pointer; const ASql: string): string;
// SELECT: callback ile ilk kolon degerini dondurur (gVal)
var
  em: PAnsiChar;
  rc: Integer;
begin
  gVal := '';
  em := nil;
  rc := sqExec(db, PAnsiChar(AnsiString(ASql)), @RowCB, nil, @em);
  if rc <> 0 then
    raise Exception.CreateFmt('SQLite SELECT hatasi %d: %s', [rc,
      string(AnsiString(sqErrmsg(db)))]);
  Result := gVal;
end;

{ ---------------- VDB asamalari ---------------- }

procedure RunVdb(var A: TPhArr);
var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  i, s: Integer;
  a0, a1, acc: Int64;
begin
  SetLength(A, 0);
  CleanDir(VdbPath);
  ForceDirectories(VdbPath);
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(VdbPath);
    tb.Open(VdbPath);
    sq.Exec(SQL_DDL);

    // 1) INSERT 1M (BEGIN/COMMIT)
    a0 := QNow;
    sq.Exec('BEGIN');
    for i := 1 to N do
      sq.Exec(InsertSql(i));
    sq.Exec('COMMIT');
    a1 := QNow;
    AddPh(A, 'INSERT 1M (BEGIN/COMMIT)', USpan(a0, a1));
    gSzV := DirSize(VdbPath);

    // 2) COUNT(*) x10 ortalama
    acc := 0;
    for s := 1 to 10 do
    begin
      a0 := QNow;
      with sq.Exec('SELECT COUNT(*) FROM musteri') do
        if Length(Rows) > 0 then
          gCntV := Rows[0][0];
      a1 := QNow;
      Inc(acc, USpan(a0, a1));
    end;
    AddPh(A, 'COUNT(*)  x10 ortalama', acc div 10);

    // 3) SUM(bakiye) x5 ortalama
    acc := 0;
    for s := 1 to 5 do
    begin
      a0 := QNow;
      with sq.Exec('SELECT SUM(bakiye) FROM musteri') do
        if Length(Rows) > 0 then
          gSumV := Rows[0][0];
      a1 := QNow;
      Inc(acc, USpan(a0, a1));
    end;
    AddPh(A, 'SUM(bakiye)  x5 ortalama', acc div 5);

    // 4) SELECT PK 50.000 nokta arama
    a0 := QNow;
    for i := 1 to PK_N do
      with sq.Exec(PkSql(i)) do
        if Length(Rows) > 0 then
          Inc(gSink, Length(Rows[0][0]));
    a1 := QNow;
    AddPh(A, 'SELECT PK  50.000x', USpan(a0, a1));

    // 5) RANGE 2.000 x 100 satir
    a0 := QNow;
    for i := 1 to RANGE_N do
      with sq.Exec(RangeSql(i)) do
        if Length(Rows) > 0 then
          Inc(gSink, Length(Rows[0][0]) + Length(Rows[High(Rows)][0]));
    a1 := QNow;
    AddPh(A, 'RANGE  2.000 x 100 satir', USpan(a0, a1));

    // 6) UPDATE 100k (BEGIN/COMMIT)
    a0 := QNow;
    sq.Exec('BEGIN');
    for i := 1 to MUT_N do
      sq.Exec(Format('UPDATE musteri SET yas = yas + 1 WHERE id = %d', [i]));
    sq.Exec('COMMIT');
    a1 := QNow;
    AddPh(A, 'UPDATE 100k (BEGIN/COMMIT)', USpan(a0, a1));

    // 7) DELETE 100k (BEGIN/COMMIT)
    a0 := QNow;
    sq.Exec('BEGIN');
    for i := 1 to MUT_N do
      sq.Exec(Format('DELETE FROM musteri WHERE id = %d', [i]));
    sq.Exec('COMMIT');
    a1 := QNow;
    AddPh(A, 'DELETE 100k (BEGIN/COMMIT)', USpan(a0, a1));

    // kontrol: DELETE sonrasi 900.000
    with sq.Exec('SELECT COUNT(*) FROM musteri') do
      if Length(Rows) > 0 then
        gCntAfterV := Rows[0][0];
  finally
    sq.Free;
    tb.Free;
    kv.Free;
  end;
end;

{ ---------------- SQLite asamalari ---------------- }

procedure RunSql(var A: TPhArr);
var
  db: Pointer;
  i, s: Integer;
  a0, a1, acc: Int64;
  rc: Integer;
begin
  SetLength(A, 0);
  DeleteFile(SqlPath);
  DeleteFile(SqlPath + '-journal');
  DeleteFile(SqlPath + '-wal');
  DeleteFile(SqlPath + '-shm');
  rc := sqOpen(PAnsiChar(AnsiString(SqlPath)), db);
  if rc <> 0 then
    raise Exception.CreateFmt('sqlite3_open hatasi: %d', [rc]);
  try
    ExecSq(db, SQL_DDL);

    // 1) INSERT 1M (BEGIN/COMMIT)
    a0 := QNow;
    ExecSq(db, 'BEGIN');
    for i := 1 to N do
      ExecSq(db, InsertSql(i));
    ExecSq(db, 'COMMIT');
    a1 := QNow;
    AddPh(A, 'INSERT 1M (BEGIN/COMMIT)', USpan(a0, a1));
    gSzS := FileSizeOf(SqlPath);

    // 2) COUNT(*) x10 ortalama
    acc := 0;
    for s := 1 to 10 do
    begin
      a0 := QNow;
      gCntS := ExecSqCb(db, 'SELECT COUNT(*) FROM musteri');
      a1 := QNow;
      Inc(acc, USpan(a0, a1));
    end;
    AddPh(A, 'COUNT(*)  x10 ortalama', acc div 10);

    // 3) SUM(bakiye) x5 ortalama
    acc := 0;
    for s := 1 to 5 do
    begin
      a0 := QNow;
      gSumS := ExecSqCb(db, 'SELECT SUM(bakiye) FROM musteri');
      a1 := QNow;
      Inc(acc, USpan(a0, a1));
    end;
    AddPh(A, 'SUM(bakiye)  x5 ortalama', acc div 5);

    // 4) SELECT PK 50.000 nokta arama
    a0 := QNow;
    for i := 1 to PK_N do
      ExecSqCb(db, PkSql(i));
    a1 := QNow;
    AddPh(A, 'SELECT PK  50.000x', USpan(a0, a1));

    // 5) RANGE 2.000 x 100 satir
    a0 := QNow;
    for i := 1 to RANGE_N do
      ExecSqCb(db, RangeSql(i));
    a1 := QNow;
    AddPh(A, 'RANGE  2.000 x 100 satir', USpan(a0, a1));

    // 6) UPDATE 100k (BEGIN/COMMIT)
    a0 := QNow;
    ExecSq(db, 'BEGIN');
    for i := 1 to MUT_N do
      ExecSq(db, Format('UPDATE musteri SET yas = yas + 1 WHERE id = %d', [i]));
    ExecSq(db, 'COMMIT');
    a1 := QNow;
    AddPh(A, 'UPDATE 100k (BEGIN/COMMIT)', USpan(a0, a1));

    // 7) DELETE 100k (BEGIN/COMMIT)
    a0 := QNow;
    ExecSq(db, 'BEGIN');
    for i := 1 to MUT_N do
      ExecSq(db, Format('DELETE FROM musteri WHERE id = %d', [i]));
    ExecSq(db, 'COMMIT');
    a1 := QNow;
    AddPh(A, 'DELETE 100k (BEGIN/COMMIT)', USpan(a0, a1));

    // kontrol
    gCntAfterS := ExecSqCb(db, 'SELECT COUNT(*) FROM musteri');
  finally
    sqClose(db);
  end;
end;

{ ---------------- rapor ---------------- }

procedure PrintTable(const V, S: TPhArr);
var
  i: Integer;
  ratio: Double;
begin
  WriteLn(Format('%-32s %12s %12s %10s',
    ['Asama', 'VDB', 'SQLite', 'VDB/SQLite']));
  WriteLn(StringOfChar('-', 70));
  for i := 0 to High(V) do
  begin
    if (i <= High(S)) and (S[i].US > 0) then
      ratio := V[i].US / S[i].US
    else
      ratio := 0;
    WriteLn(Format('%-32s %12s %12s %9.2fx',
      [V[i].Name, FmtUS(V[i].US), FmtUS(S[i].US), ratio]));
  end;
end;

var
  V, S: TPhArr;
  h: THandle;
  lv: string;
  d1, d2: Double;

begin
  QueryPerformanceFrequency(QPF);

  h := LoadLibrary(SqlDll);
  if h = 0 then
  begin
    WriteLn('HATA: sqlite3.dll yuklenemedi: ', SqlDll, '  rc=', GetLastError);
    Halt(1);
  end;
  sqOpen := TSqlite3Open(GetProcAddress(h, 'sqlite3_open'));
  sqClose := TSqlite3Close(GetProcAddress(h, 'sqlite3_close'));
  sqExec := TSqlite3Exec(GetProcAddress(h, 'sqlite3_exec'));
  sqErrmsg := TSqlite3Errmsg(GetProcAddress(h, 'sqlite3_errmsg'));
  sqLibver := TSqlite3Libversion(GetProcAddress(h, 'sqlite3_libversion'));
  if not Assigned(sqOpen) or not Assigned(sqClose) or not Assigned(sqExec) or
    not Assigned(sqErrmsg) or not Assigned(sqLibver) then
  begin
    WriteLn('HATA: sqlite3.dll disa aktarim eksik');
    Halt(2);
  end;
  lv := string(AnsiString(sqLibver()));

  WriteLn('=== VDB vs SQLite - ADIL HIZ TESTI / FAIR SPEED TEST ===');
  WriteLn('VDB      : v2.1 (SyncWriteInterval=0, senkron commit)');
  WriteLn('SQLite   : ', lv, '  (', SqlDll, ')');
  WriteLn('Veri     : ', N, ' satir, ayni SQL metni, ayni disk (C:\temp)');
  WriteLn('Yontem   : her iki motor da stok varsayilanlariyla, tek surec');
  WriteLn;

  if (ParamCount >= 1) and SameText(ParamStr(1), 'sqlonly') then
  begin
    WriteLn('[sqlonly] VDB asamasi atlandi - yalniz SQLite');
    SetLength(V, 0);
  end
  else
  begin
    WriteLn('[1/2] VDB kosuluyor...');
    RunVdb(V);
    WriteLn('      bitti.');
  end;
  WriteLn('[2/2] SQLite kosuluyor...');
  RunSql(S);
  WriteLn('      bitti.');
  WriteLn;

  PrintTable(V, S);
  WriteLn;

  WriteLn('Dogrulama / verification:');
  WriteLn('  COUNT (1M beklenir) : VDB=', gCntV, '  SQLite=', gCntS);
  WriteLn('  COUNT (900k beklenir, DELETE sonrasi): VDB=', gCntAfterV,
    '  SQLite=', gCntAfterS);
  WriteLn('  SUM(bakiye) (5000000000 beklenir): VDB=', gSumV,
    '  SQLite=', gSumS);
  d1 := NumOf(gSumV);
  d2 := NumOf(gSumS);
  if (Abs(d1 - 5000000000.0) < 1.0) and (Abs(d2 - 5000000000.0) < 1.0) then
    WriteLn('  SUM eslesme: OK (iki motor da dogru)')
  else
    WriteLn('  SUM eslesme: FARKLI! VDB=', d1:0:2, ' SQLite=', d2:0:2);
  WriteLn('  Dosya (INSERT sonrasi): VDB=', Mb(gSzV):0:2, ' MB  SQLite=',
    Mb(gSzS):0:2, ' MB');
  WriteLn('  Deger dokunma (sink): ', gSink);
  WriteLn;
  WriteLn('=== BITTI / DONE ===');
  FreeLibrary(h);
end.
