program sqlitecmp;

{ VDB v3 vs SQLite on the same machine, same data, same SQL order.

  One executable measures both engines in the same process with QPC.
  SQLite is loaded from sqlite3.dll (copy the DLL next to the exe before
  running; the DLL is never written by this program).

  Usage:  sqlitecmp.exe <work-directory> [rows]

  The work directory is mandatory; the program creates <dir>\vdb,
  <dir>\sqlite and <dir>\warmup and removes only the files it owns.

  Every stage is run three times; the median is reported.  A separate
  warmup round runs first.  Both engines use the same deterministic data
  and the same statement order. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Windows, SysUtils, Classes, Math,
  VDbCore, VDbTypes, VDbTable, VDbSql, VDbBackendApi, VDbBackendV3, VDbAst;

const
  SQLITE_DLL = 'sqlite3.dll';
  SQLITE_OK = 0;
  SQLITE_ROW = 100;
  SQLITE_DONE = 101;
  SQLITE_TRANSIENT = Pointer(-1);
  Q = '''';

  N_ROWS_DEFAULT = 200000;
  N_POINT = 2000;
  N_RANGE = 2000;
  INNER_REPS = 5;
  NREP = 3;

  CREATE_SQL =
    'CREATE TABLE musteri (id INTEGER PRIMARY KEY, ad TEXT, yas INTEGER, ' +
    'bakiye FLOAT, notu TEXT);';

type
  sqlite3_ptr = Pointer;
  sqlite3_stmt_ptr = Pointer;
  T3 = array[1..3] of Int64;
  TVdbConn = record
    Be: IVDbBackend;
    Tb: TVTableDb;
    Sq: TVSql;
  end;

function sqlite3_open(filename: PAnsiChar; var ppDb: sqlite3_ptr): Integer; cdecl; external SQLITE_DLL;
function sqlite3_close(pDb: sqlite3_ptr): Integer; cdecl; external SQLITE_DLL;
function sqlite3_exec(pDb: sqlite3_ptr; sql: PAnsiChar; callback: Pointer; arg: Pointer; errmsg: PPAnsiChar): Integer; cdecl; external SQLITE_DLL;
function sqlite3_prepare_v2(pDb: sqlite3_ptr; zSql: PAnsiChar; nByte: Integer; var ppStmt: sqlite3_stmt_ptr; pzTail: PPAnsiChar): Integer; cdecl; external SQLITE_DLL;
function sqlite3_step(pStmt: sqlite3_stmt_ptr): Integer; cdecl; external SQLITE_DLL;
function sqlite3_finalize(pStmt: sqlite3_stmt_ptr): Integer; cdecl; external SQLITE_DLL;
function sqlite3_reset(pStmt: sqlite3_stmt_ptr): Integer; cdecl; external SQLITE_DLL;
function sqlite3_bind_int64(pStmt: sqlite3_stmt_ptr; iCol: Integer; val: Int64): Integer; cdecl; external SQLITE_DLL;
function sqlite3_bind_text(pStmt: sqlite3_stmt_ptr; iCol: Integer; zData: PAnsiChar; nData: Integer; xDel: Pointer): Integer; cdecl; external SQLITE_DLL;
function sqlite3_bind_double(pStmt: sqlite3_stmt_ptr; iCol: Integer; val: Double): Integer; cdecl; external SQLITE_DLL;
function sqlite3_column_int64(pStmt: sqlite3_stmt_ptr; iCol: Integer): Int64; cdecl; external SQLITE_DLL;
function sqlite3_column_double(pStmt: sqlite3_stmt_ptr; iCol: Integer): Double; cdecl; external SQLITE_DLL;
function sqlite3_column_text(pStmt: sqlite3_stmt_ptr; iCol: Integer): PAnsiChar; cdecl; external SQLITE_DLL;
function sqlite3_errmsg(pDb: sqlite3_ptr): PAnsiChar; cdecl; external SQLITE_DLL;
function sqlite3_changes(pDb: sqlite3_ptr): Integer; cdecl; external SQLITE_DLL;
function sqlite3_libversion(): PAnsiChar; cdecl; external SQLITE_DLL;

var
  Root, VdbDir, SqliteDir, WarmDir, VdbFile, SqliteFile: string;
  N: Integer;
  Freq: Int64;

  VTime, STime: array[1..14] of T3;
  VOper, SOper: array[1..14, 1..3] of Int64;
  VValid, SValid: array[1..14] of Int64;
  VAff, SAff: array[1..14] of Int64;   // median affected rows for bulk writes

  VSizeOdb, VSizeIdx, VSizeWal, VSizeTotal: Int64;
  SSizeDb, SSizeJournal, SSizeTotal: Int64;

function NowUs: Int64;
var C: Int64;
begin
  QueryPerformanceCounter(C);
  Result := (C * 1000000) div Freq;
end;

function AStr(const S: string): AnsiString;
begin
  Result := AnsiString(S);
end;

function Med3(const A: T3): Double;
var x, y, z, t: Int64;
begin
  x := A[1]; y := A[2]; z := A[3];
  if x > y then begin t := x; x := y; y := t; end;
  if y > z then begin t := y; y := z; z := t; end;
  if x > y then begin t := x; x := y; y := t; end;
  Result := y;
end;

function SpreadPct(const A: T3): Double;
var med, mn, mx: Double;
begin
  med := Med3(A);
  mn := Min(A[1], Min(A[2], A[3]));
  mx := Max(A[1], Max(A[2], A[3]));
  if med <= 0 then
    Result := 0
  else
    Result := (mx - mn) * 100.0 / med;
end;

procedure DeleteFilesIn(const Dir: string);
var SR: TSearchRec; P: string;
begin
  P := IncludeTrailingPathDelimiter(Dir);
  if FindFirst(P + '*.*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and
         ((SR.Attr and faDirectory) = 0) then
        DeleteFile(P + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

function FileBytes(const P: string): Int64;
var F: TFileStream;
begin
  Result := 0;
  if not FileExists(P) then Exit;
  F := TFileStream.Create(P, fmOpenRead or fmShareDenyNone);
  try
    Result := F.Size;
  finally
    F.Free;
  end;
end;

function DirBytes(const Dir: string): Int64;
var SR: TSearchRec; P: string;
begin
  Result := 0;
  P := IncludeTrailingPathDelimiter(Dir);
  if FindFirst(P + '*.*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and
         ((SR.Attr and faDirectory) = 0) then
        Inc(Result, SR.Size);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

{ ---------------- VDB helpers ---------------- }

function VdbOpen(const Dir: string): TVdbConn;
begin
  Result.Be := TVdbBackendV3.Create(
    IncludeTrailingPathDelimiter(Dir) + 'veritabani.odb', True, 256);
  Result.Tb := TVTableDb.CreateBackend(Result.Be);
  Result.Sq := TVSql.Create(Result.Tb);
  Result.Tb.Open(IncludeTrailingPathDelimiter(Dir));
end;

procedure VdbClose(var C: TVdbConn);
begin
  if C.Sq <> nil then FreeAndNil(C.Sq);
  if C.Tb <> nil then
  begin
    C.Tb.Close;
    FreeAndNil(C.Tb);
  end;
  C.Be := nil;
end;

function Key1(i: Integer): Integer;
begin
  Result := 1 + ((i * 7919 + 13) mod N);
end;

function Key2(rep, i: Integer): Integer;
begin
  Result := 1 + ((i * 7919 + rep * 104729 + 17) mod N);
end;

function DelKey(rep, i: Integer): Integer;
begin
  Result := 1 + ((i * 3571 + rep * 15485863 + 29) mod N);
end;

function InsertSql(i: Integer): string;
begin
  Result := 'INSERT INTO musteri (id, ad, yas, bakiye, notu) VALUES (' +
    IntToStr(i) + ', ' + Q + 'Musteri_' + IntToStr(i mod 500) + Q + ', ' +
    IntToStr(18 + (i mod 60)) + ', ' + FloatToStr((i * 1.25) + 0.5) + ', ' +
    Q + 'Aciklama metni ' + IntToStr(i) + Q + ');';
end;

function VdbBuildInsert(out Affected: Int64): Int64;
var C: TVdbConn; t0, t1: Int64; i: Integer;
begin
  DeleteFilesIn(VdbDir);
  C := VdbOpen(VdbDir);
  try
    C.Sq.Exec(CREATE_SQL);
    t0 := NowUs;
    C.Sq.Exec('BEGIN;');
    for i := 1 to N do
      C.Sq.Exec(InsertSql(i));
    C.Sq.Exec('COMMIT;');
    t1 := NowUs;
    Result := t1 - t0;
    Affected := N;
  finally
    VdbClose(C);
  end;
end;

procedure VdbReads(C: TVdbConn);
var rep, i, k, lo, hi, key: Integer;
    t0, t1: Int64;
    R: TSqlResult;
    acc, v: Int64;
begin
  { 3: PK point SELECT, 2000 keys per round }
  for rep := 1 to NREP do
  begin
    acc := 0;
    t0 := NowUs;
    for i := 1 to N_POINT do
    begin
      key := Key1(i);
      R := C.Sq.Exec('SELECT id, ad, yas, bakiye, notu FROM musteri WHERE id = ' +
        IntToStr(key) + ';');
      Inc(acc, Length(R.Rows));
    end;
    t1 := NowUs;
    VTime[3, rep] := t1 - t0;
    VOper[3, rep] := N_POINT;
    if rep = 1 then VValid[3] := acc;
  end;

  { 4: range SELECT, 2000 BETWEEN queries per round }
  for rep := 1 to NREP do
  begin
    acc := 0;
    t0 := NowUs;
    for i := 1 to N_RANGE do
    begin
      lo := 1 + ((i * 3571) mod (N - 150));
      hi := lo + 100;
      R := C.Sq.Exec('SELECT COUNT(*) FROM musteri WHERE id BETWEEN ' +
        IntToStr(lo) + ' AND ' + IntToStr(hi) + ';');
      acc := acc + StrToInt64Def(R.Rows[0][0], 0);
    end;
    t1 := NowUs;
    VTime[4, rep] := t1 - t0;
    VOper[4, rep] := N_RANGE;
    if rep = 1 then VValid[4] := acc;
  end;

  { 5: full scan COUNT(*) }
  for rep := 1 to NREP do
  begin
    v := 0;
    t0 := NowUs;
    for k := 1 to INNER_REPS do
    begin
      R := C.Sq.Exec('SELECT COUNT(*) FROM musteri;');
      v := StrToInt64Def(R.Rows[0][0], 0);
    end;
    t1 := NowUs;
    VTime[5, rep] := t1 - t0;
    VOper[5, rep] := INNER_REPS;
    if rep = 1 then VValid[5] := v;
  end;

  { 6: SUM/AVG(id) }
  for rep := 1 to NREP do
  begin
    v := 0;
    t0 := NowUs;
    for k := 1 to INNER_REPS do
    begin
      R := C.Sq.Exec('SELECT SUM(id), AVG(id) FROM musteri;');
      v := Round(StrToFloatDef(R.Rows[0][0], 0));
    end;
    t1 := NowUs;
    VTime[6, rep] := t1 - t0;
    VOper[6, rep] := INNER_REPS;
    if rep = 1 then VValid[6] := v;
  end;

  { 7: GROUP BY yas }
  for rep := 1 to NREP do
  begin
    v := 0;
    t0 := NowUs;
    for k := 1 to INNER_REPS do
    begin
      R := C.Sq.Exec('SELECT yas, COUNT(*), AVG(id) FROM musteri GROUP BY yas ORDER BY yas;');
      v := Length(R.Rows);
    end;
    t1 := NowUs;
    VTime[7, rep] := t1 - t0;
    VOper[7, rep] := INNER_REPS;
    if rep = 1 then VValid[7] := v;
  end;

  { 8: ORDER BY bakiye DESC LIMIT 100 }
  for rep := 1 to NREP do
  begin
    v := 0;
    t0 := NowUs;
    for k := 1 to INNER_REPS do
    begin
      R := C.Sq.Exec('SELECT id, ad, bakiye FROM musteri ORDER BY bakiye DESC LIMIT 100;');
      v := Length(R.Rows);
    end;
    t1 := NowUs;
    VTime[8, rep] := t1 - t0;
    VOper[8, rep] := INNER_REPS;
    if rep = 1 then VValid[8] := v;
  end;

  { 9: non-indexed WHERE (yas has no index) }
  for rep := 1 to NREP do
  begin
    v := 0;
    t0 := NowUs;
    for k := 1 to INNER_REPS do
    begin
      R := C.Sq.Exec('SELECT COUNT(*) FROM musteri WHERE yas > 70;');
      v := StrToInt64Def(R.Rows[0][0], 0);
    end;
    t1 := NowUs;
    VTime[9, rep] := t1 - t0;
    VOper[9, rep] := INNER_REPS;
    if rep = 1 then VValid[9] := v;
  end;
end;

{ One full unmeasured read pass on the real 200k data set.  This warms
  the OS/file cache for the large scans; the three measured rounds then do
  not mix cold-cache effects into the median. }
procedure VdbReadWarm(C: TVdbConn);
var i, lo, hi, key, k: Integer; R: TSqlResult;
begin
  for i := 1 to N_POINT do
  begin
    key := Key1(i);
    R := C.Sq.Exec('SELECT id, ad, yas, bakiye, notu FROM musteri WHERE id = ' +
      IntToStr(key) + ';');
  end;
  for i := 1 to N_RANGE do
  begin
    lo := 1 + ((i * 3571) mod (N - 150));
    hi := lo + 100;
    R := C.Sq.Exec('SELECT COUNT(*) FROM musteri WHERE id BETWEEN ' +
      IntToStr(lo) + ' AND ' + IntToStr(hi) + ';');
  end;
  for k := 1 to 1 do
  begin
    R := C.Sq.Exec('SELECT COUNT(*) FROM musteri;');
    R := C.Sq.Exec('SELECT SUM(id), AVG(id) FROM musteri;');
    R := C.Sq.Exec('SELECT yas, COUNT(*), AVG(id) FROM musteri GROUP BY yas ORDER BY yas;');
    R := C.Sq.Exec('SELECT id, ad, bakiye FROM musteri ORDER BY bakiye DESC LIMIT 100;');
    R := C.Sq.Exec('SELECT COUNT(*) FROM musteri WHERE yas > 70;');
  end;
end;

procedure VdbMutations(C: TVdbConn);
var rep, i, lo, hi: Integer; t0, t1: Int64; R: TSqlResult;
begin
  { 10: PK point UPDATE }
  for rep := 1 to NREP do
  begin
    t0 := NowUs;
    for i := 1 to N_POINT do
      R := C.Sq.Exec('UPDATE musteri SET bakiye = bakiye + 1.0 WHERE id = ' +
        IntToStr(Key2(rep, i)) + ';');
    t1 := NowUs;
    VTime[10, rep] := t1 - t0;
    VOper[10, rep] := N_POINT;
  end;

  { 11: bulk UPDATE, all rows }
  for rep := 1 to NREP do
  begin
    t0 := NowUs;
    R := C.Sq.Exec('UPDATE musteri SET bakiye = bakiye + 10.5;');
    t1 := NowUs;
    VTime[11, rep] := t1 - t0;
    VOper[11, rep] := R.Affected;
    VAff[11] := R.Affected;
  end;

  { 12: PK point DELETE }
  for rep := 1 to NREP do
  begin
    VValid[12] := 0;
    t0 := NowUs;
    for i := 1 to N_POINT do
    begin
      R := C.Sq.Exec('DELETE FROM musteri WHERE id = ' +
        IntToStr(DelKey(rep, i)) + ';');
      Inc(VValid[12], R.Affected);
    end;
    t1 := NowUs;
    VTime[12, rep] := t1 - t0;
    VOper[12, rep] := N_POINT;
  end;

  { 13: bulk DELETE on a distinct 20k subset per round }
  for rep := 1 to NREP do
  begin
    lo := (rep - 1) * 25000 + 1;
    hi := lo + 19999;
    t0 := NowUs;
    R := C.Sq.Exec('DELETE FROM musteri WHERE id BETWEEN ' +
      IntToStr(lo) + ' AND ' + IntToStr(hi) + ';');
    t1 := NowUs;
    VTime[13, rep] := t1 - t0;
    VOper[13, rep] := R.Affected;
    VAff[13] := R.Affected;
  end;
end;

procedure VdbOpenStage;
var rep: Integer; t0, t1: Int64; C: TVdbConn;
begin
  for rep := 1 to NREP do
  begin
    t0 := NowUs;
    C := VdbOpen(VdbDir);
    t1 := NowUs;
    VTime[14, rep] := t1 - t0;
    VOper[14, rep] := 1;
    VdbClose(C);
  end;
end;

{ ---------------- SQLite helpers ---------------- }

function ExecSql(Db: sqlite3_ptr; const Sql: string): Integer;
var A: AnsiString;
begin
  A := AStr(Sql);
  Result := sqlite3_exec(Db, PAnsiChar(A), nil, nil, nil);
end;

function Prep(Db: sqlite3_ptr; const Sql: string; out St: sqlite3_stmt_ptr): Boolean;
var A: AnsiString;
begin
  A := AStr(Sql);
  Result := sqlite3_prepare_v2(Db, PAnsiChar(A), -1, St, nil) = SQLITE_OK;
  if not Result then
    raise Exception.Create('SQLite prepare failed: ' + Sql + ' :: ' +
      string(sqlite3_errmsg(Db)));
end;

procedure BindText(St: sqlite3_stmt_ptr; Col: Integer; const S: string);
var A: AnsiString;
begin
  A := AStr(S);
  sqlite3_bind_text(St, Col, PAnsiChar(A), Length(A), SQLITE_TRANSIENT);
end;

function ScalarInt(St: sqlite3_stmt_ptr): Int64;
begin
  Result := 0;
  if sqlite3_step(St) = SQLITE_ROW then
    Result := sqlite3_column_int64(St, 0);
  sqlite3_reset(St);
end;

function SqliteOpenConn(out Db: sqlite3_ptr): Boolean;
begin
  Result := sqlite3_open(PAnsiChar(AStr(SqliteFile)), Db) = SQLITE_OK;
  if not Result then Exit;
  ExecSql(Db, 'PRAGMA journal_mode=DELETE;');
  ExecSql(Db, 'PRAGMA synchronous=FULL;');
end;

function SqliteBuildInsert(out Affected: Int64): Int64;
var Db: sqlite3_ptr; St: sqlite3_stmt_ptr;
    t0, t1: Int64; i: Integer;
begin
  DeleteFilesIn(SqliteDir);
  if not SqliteOpenConn(Db) then
    raise Exception.Create('SQLite open failed: ' + string(sqlite3_errmsg(Db)));
  try
    ExecSql(Db, CREATE_SQL);
    t0 := NowUs;
    ExecSql(Db, 'BEGIN TRANSACTION;');
    Prep(Db, 'INSERT INTO musteri (id, ad, yas, bakiye, notu) VALUES (?, ?, ?, ?, ?);', St);
    for i := 1 to N do
    begin
      sqlite3_bind_int64(St, 1, i);
      BindText(St, 2, 'Musteri_' + IntToStr(i mod 500));
      sqlite3_bind_int64(St, 3, 18 + (i mod 60));
      sqlite3_bind_double(St, 4, (i * 1.25) + 0.5);
      BindText(St, 5, 'Aciklama metni ' + IntToStr(i));
      sqlite3_step(St);
      sqlite3_reset(St);
    end;
    sqlite3_finalize(St);
    ExecSql(Db, 'COMMIT;');
    t1 := NowUs;
    Result := t1 - t0;
    Affected := N;
  finally
    sqlite3_close(Db);
  end;
end;

procedure SqliteReads(Db: sqlite3_ptr);
var rep, i, k, lo, hi, key: Integer;
    t0, t1: Int64;
    St: sqlite3_stmt_ptr;
    acc, v: Int64;
begin
  { 3: PK point SELECT }
  Prep(Db, 'SELECT id, ad, yas, bakiye, notu FROM musteri WHERE id = ?;', St);
  for rep := 1 to NREP do
  begin
    acc := 0;
    t0 := NowUs;
    for i := 1 to N_POINT do
    begin
      key := Key1(i);
      sqlite3_bind_int64(St, 1, key);
      while sqlite3_step(St) = SQLITE_ROW do
      begin
        sqlite3_column_int64(St, 0);
        Inc(acc);
      end;
      sqlite3_reset(St);
    end;
    t1 := NowUs;
    STime[3, rep] := t1 - t0;
    SOper[3, rep] := N_POINT;
    if rep = 1 then SValid[3] := acc;
  end;
  sqlite3_finalize(St);

  { 4: range SELECT }
  Prep(Db, 'SELECT COUNT(*) FROM musteri WHERE id BETWEEN ? AND ?;', St);
  for rep := 1 to NREP do
  begin
    acc := 0;
    t0 := NowUs;
    for i := 1 to N_RANGE do
    begin
      lo := 1 + ((i * 3571) mod (N - 150));
      hi := lo + 100;
      sqlite3_bind_int64(St, 1, lo);
      sqlite3_bind_int64(St, 2, hi);
      acc := acc + ScalarInt(St);
    end;
    t1 := NowUs;
    STime[4, rep] := t1 - t0;
    SOper[4, rep] := N_RANGE;
    if rep = 1 then SValid[4] := acc;
  end;
  sqlite3_finalize(St);

  { 5: COUNT(*) }
  Prep(Db, 'SELECT COUNT(*) FROM musteri;', St);
  for rep := 1 to NREP do
  begin
    v := 0;
    t0 := NowUs;
    for k := 1 to INNER_REPS do
      v := ScalarInt(St);
    t1 := NowUs;
    STime[5, rep] := t1 - t0;
    SOper[5, rep] := INNER_REPS;
    if rep = 1 then SValid[5] := v;
  end;
  sqlite3_finalize(St);

  { 6: SUM/AVG(id) }
  Prep(Db, 'SELECT SUM(id), AVG(id) FROM musteri;', St);
  for rep := 1 to NREP do
  begin
    v := 0;
    t0 := NowUs;
    for k := 1 to INNER_REPS do
    begin
      if sqlite3_step(St) = SQLITE_ROW then
        v := Round(sqlite3_column_double(St, 0));
      sqlite3_reset(St);
    end;
    t1 := NowUs;
    STime[6, rep] := t1 - t0;
    SOper[6, rep] := INNER_REPS;
    if rep = 1 then SValid[6] := v;
  end;
  sqlite3_finalize(St);

  { 7: GROUP BY yas }
  Prep(Db, 'SELECT yas, COUNT(*), AVG(id) FROM musteri GROUP BY yas ORDER BY yas;', St);
  for rep := 1 to NREP do
  begin
    v := 0;
    t0 := NowUs;
    for k := 1 to INNER_REPS do
    begin
      v := 0;
      while sqlite3_step(St) = SQLITE_ROW do
        Inc(v);
      sqlite3_reset(St);
    end;
    t1 := NowUs;
    STime[7, rep] := t1 - t0;
    SOper[7, rep] := INNER_REPS;
    if rep = 1 then SValid[7] := v;
  end;
  sqlite3_finalize(St);

  { 8: ORDER BY bakiye DESC LIMIT 100 }
  Prep(Db, 'SELECT id, ad, bakiye FROM musteri ORDER BY bakiye DESC LIMIT 100;', St);
  for rep := 1 to NREP do
  begin
    v := 0;
    t0 := NowUs;
    for k := 1 to INNER_REPS do
    begin
      v := 0;
      while sqlite3_step(St) = SQLITE_ROW do
        Inc(v);
      sqlite3_reset(St);
    end;
    t1 := NowUs;
    STime[8, rep] := t1 - t0;
    SOper[8, rep] := INNER_REPS;
    if rep = 1 then SValid[8] := v;
  end;
  sqlite3_finalize(St);

  { 9: non-indexed WHERE }
  Prep(Db, 'SELECT COUNT(*) FROM musteri WHERE yas > 70;', St);
  for rep := 1 to NREP do
  begin
    v := 0;
    t0 := NowUs;
    for k := 1 to INNER_REPS do
      v := ScalarInt(St);
    t1 := NowUs;
    STime[9, rep] := t1 - t0;
    SOper[9, rep] := INNER_REPS;
    if rep = 1 then SValid[9] := v;
  end;
  sqlite3_finalize(St);
end;

procedure SqliteReadWarm(Db: sqlite3_ptr);
var i, lo, hi, key, k: Integer; St: sqlite3_stmt_ptr;
begin
  Prep(Db, 'SELECT id, ad, yas, bakiye, notu FROM musteri WHERE id = ?;', St);
  for i := 1 to N_POINT do
  begin
    key := Key1(i);
    sqlite3_bind_int64(St, 1, key);
    while sqlite3_step(St) = SQLITE_ROW do
      sqlite3_column_int64(St, 0);
    sqlite3_reset(St);
  end;
  sqlite3_finalize(St);

  Prep(Db, 'SELECT COUNT(*) FROM musteri WHERE id BETWEEN ? AND ?;', St);
  for i := 1 to N_RANGE do
  begin
    lo := 1 + ((i * 3571) mod (N - 150));
    hi := lo + 100;
    sqlite3_bind_int64(St, 1, lo);
    sqlite3_bind_int64(St, 2, hi);
    ScalarInt(St);
  end;
  sqlite3_finalize(St);

  for k := 1 to 1 do
  begin
    ExecSql(Db, 'SELECT COUNT(*) FROM musteri;');
    ExecSql(Db, 'SELECT SUM(id), AVG(id) FROM musteri;');
    ExecSql(Db, 'SELECT yas, COUNT(*), AVG(id) FROM musteri GROUP BY yas ORDER BY yas;');
    ExecSql(Db, 'SELECT id, ad, bakiye FROM musteri ORDER BY bakiye DESC LIMIT 100;');
    ExecSql(Db, 'SELECT COUNT(*) FROM musteri WHERE yas > 70;');
  end;
end;

procedure SqliteMutations(Db: sqlite3_ptr);
var rep, i, lo, hi: Integer; t0, t1: Int64; St: sqlite3_stmt_ptr; aff: Int64;
begin
  { 10: PK point UPDATE }
  Prep(Db, 'UPDATE musteri SET bakiye = bakiye + ? WHERE id = ?;', St);
  for rep := 1 to NREP do
  begin
    t0 := NowUs;
    for i := 1 to N_POINT do
    begin
      sqlite3_bind_double(St, 1, 1.0);
      sqlite3_bind_int64(St, 2, Key2(rep, i));
      sqlite3_step(St);
      sqlite3_reset(St);
    end;
    t1 := NowUs;
    STime[10, rep] := t1 - t0;
    SOper[10, rep] := N_POINT;
  end;
  sqlite3_finalize(St);

  { 11: bulk UPDATE }
  for rep := 1 to NREP do
  begin
    t0 := NowUs;
    ExecSql(Db, 'UPDATE musteri SET bakiye = bakiye + 10.5;');
    t1 := NowUs;
    STime[11, rep] := t1 - t0;
    SOper[11, rep] := sqlite3_changes(Db);
    SAff[11] := sqlite3_changes(Db);
  end;

  { 12: PK point DELETE }
  Prep(Db, 'DELETE FROM musteri WHERE id = ?;', St);
  for rep := 1 to NREP do
  begin
    aff := 0;
    t0 := NowUs;
    for i := 1 to N_POINT do
    begin
      sqlite3_bind_int64(St, 1, DelKey(rep, i));
      sqlite3_step(St);
      Inc(aff, sqlite3_changes(Db));
      sqlite3_reset(St);
    end;
    t1 := NowUs;
    STime[12, rep] := t1 - t0;
    SOper[12, rep] := N_POINT;
    SValid[12] := aff;
  end;
  sqlite3_finalize(St);

  { 13: bulk DELETE on a distinct 20k subset per round }
  for rep := 1 to NREP do
  begin
    lo := (rep - 1) * 25000 + 1;
    hi := lo + 19999;
    t0 := NowUs;
    ExecSql(Db, 'DELETE FROM musteri WHERE id BETWEEN ' +
      IntToStr(lo) + ' AND ' + IntToStr(hi) + ';');
    t1 := NowUs;
    STime[13, rep] := t1 - t0;
    SOper[13, rep] := sqlite3_changes(Db);
    SAff[13] := sqlite3_changes(Db);
  end;
end;

procedure SqliteOpenStage;
var rep, i: Integer; t0, t1: Int64; Db: sqlite3_ptr;
begin
  for rep := 1 to NREP do
  begin
    Db := nil;
    t0 := NowUs;
    sqlite3_open(PAnsiChar(AStr(SqliteFile)), Db);
    for i := 1 to 2 do
      if i = 1 then ExecSql(Db, 'PRAGMA journal_mode=DELETE;')
      else ExecSql(Db, 'PRAGMA synchronous=FULL;');
    t1 := NowUs;
    STime[14, rep] := t1 - t0;
    SOper[14, rep] := 1;
    sqlite3_close(Db);
  end;
end;

{ ---------------- separate warmup ---------------- }

procedure WarmupVdb;
var C: TVdbConn; i: Integer; R: TSqlResult;
begin
  DeleteFilesIn(WarmDir);
  C := VdbOpen(WarmDir);
  try
    C.Sq.Exec(CREATE_SQL);
    C.Sq.Exec('BEGIN;');
    for i := 1 to 1000 do
      C.Sq.Exec(InsertSql(i));
    C.Sq.Exec('COMMIT;');
    R := C.Sq.Exec('SELECT COUNT(*) FROM musteri;');
    R := C.Sq.Exec('SELECT id, ad, yas, bakiye, notu FROM musteri WHERE id = 500;');
    R := C.Sq.Exec('SELECT COUNT(*) FROM musteri WHERE id BETWEEN 100 AND 200;');
    R := C.Sq.Exec('SELECT SUM(id), AVG(id) FROM musteri;');
    R := C.Sq.Exec('SELECT yas, COUNT(*), AVG(id) FROM musteri GROUP BY yas ORDER BY yas;');
    R := C.Sq.Exec('SELECT id, ad, bakiye FROM musteri ORDER BY bakiye DESC LIMIT 100;');
    R := C.Sq.Exec('SELECT COUNT(*) FROM musteri WHERE yas > 70;');
    C.Sq.Exec('UPDATE musteri SET bakiye = bakiye + 1.0 WHERE id = 500;');
    C.Sq.Exec('UPDATE musteri SET bakiye = bakiye + 10.5;');
    C.Sq.Exec('DELETE FROM musteri WHERE id = 500;');
    C.Sq.Exec('DELETE FROM musteri WHERE id BETWEEN 1 AND 100;');
  finally
    VdbClose(C);
  end;
  DeleteFilesIn(WarmDir);
end;

procedure WarmupSqlite;
var Db: sqlite3_ptr; St: sqlite3_stmt_ptr; i: Integer; A: AnsiString;
begin
  DeleteFilesIn(WarmDir);
  A := AStr(IncludeTrailingPathDelimiter(WarmDir) + 'warm.db');
  sqlite3_open(PAnsiChar(A), Db);
  try
    ExecSql(Db, 'PRAGMA journal_mode=DELETE;');
    ExecSql(Db, 'PRAGMA synchronous=FULL;');
    ExecSql(Db, CREATE_SQL);
    ExecSql(Db, 'BEGIN TRANSACTION;');
    Prep(Db, 'INSERT INTO musteri (id, ad, yas, bakiye, notu) VALUES (?, ?, ?, ?, ?);', St);
    for i := 1 to 1000 do
    begin
      sqlite3_bind_int64(St, 1, i);
      BindText(St, 2, 'Musteri_' + IntToStr(i mod 500));
      sqlite3_bind_int64(St, 3, 18 + (i mod 60));
      sqlite3_bind_double(St, 4, (i * 1.25) + 0.5);
      BindText(St, 5, 'Aciklama metni ' + IntToStr(i));
      sqlite3_step(St);
      sqlite3_reset(St);
    end;
    sqlite3_finalize(St);
    ExecSql(Db, 'COMMIT;');
    ExecSql(Db, 'SELECT COUNT(*) FROM musteri;');
    ExecSql(Db, 'SELECT id, ad, yas, bakiye, notu FROM musteri WHERE id = 500;');
    ExecSql(Db, 'SELECT COUNT(*) FROM musteri WHERE id BETWEEN 100 AND 200;');
    ExecSql(Db, 'SELECT SUM(id), AVG(id) FROM musteri;');
    ExecSql(Db, 'SELECT yas, COUNT(*), AVG(id) FROM musteri GROUP BY yas ORDER BY yas;');
    ExecSql(Db, 'SELECT id, ad, bakiye FROM musteri ORDER BY bakiye DESC LIMIT 100;');
    ExecSql(Db, 'SELECT COUNT(*) FROM musteri WHERE yas > 70;');
    ExecSql(Db, 'UPDATE musteri SET bakiye = bakiye + 1.0 WHERE id = 500;');
    ExecSql(Db, 'UPDATE musteri SET bakiye = bakiye + 10.5;');
    ExecSql(Db, 'DELETE FROM musteri WHERE id = 500;');
    ExecSql(Db, 'DELETE FROM musteri WHERE id BETWEEN 1 AND 100;');
  finally
    sqlite3_close(Db);
  end;
  DeleteFilesIn(WarmDir);
end;

{ ---------------- report ---------------- }

const
  StageName: array[1..14] of string = (
    'Bulk INSERT (one txn)',
    'File size on disk',
    'PK point SELECT (2000)',
    'Range SELECT (2000 BETWEEN)',
    'Full scan COUNT(*)',
    'SUM/AVG(id)',
    'GROUP BY yas',
    'ORDER BY bakiye DESC LIMIT 100',
    'Non-indexed WHERE (yas > 70)',
    'PK point UPDATE (2000)',
    'Bulk UPDATE (all rows)',
    'PK point DELETE (2000)',
    'Bulk DELETE (20k subset)',
    'Reopen (open time)'
  );

function OpsMedian(const O: array of Int64): Int64;
var a, b, c, t: Int64;
begin
  a := O[0]; b := O[1]; c := O[2];
  if a > b then begin t := a; a := b; b := t; end;
  if b > c then begin t := b; b := c; c := t; end;
  if a > b then begin t := a; a := b; b := t; end;
  Result := b;
end;

function RatioText(const RV, RS: Double): string;
begin
  if RS <= 0 then
    Result := 'n/a'
  else if RV = RS then
    Result := '1.00x'
  else if RV < RS then
    Result := Format('%.2fx (VDB faster)', [RV / RS])
  else
    Result := Format('%.2fx (VDB slower)', [RV / RS]);
end;

procedure PrintReport;
var i, rep, vAhead, vBehind, vTie: Integer;
    vm, sm, vr, rr, vu, su, ratio: Double;
    o: Int64;
    arr: array[0..2] of Int64;
begin
  WriteLn;
  WriteLn('==================================================================================');
  WriteLn('                VDB v3 vs SQLite - MEDIAN OF THREE ROUNDS');
  WriteLn('==================================================================================');
  WriteLn(Format('%-4s %-40s %11s %11s %10s %11s %11s',
    ['#', 'Stage', 'VDB ms', 'SQLite ms', 'VDB/SQL', 'VDB us/op', 'SQL us/op']));
  WriteLn('-----+----------------------------------------+-----------+-----------+----------+-----------+-----------');

  vAhead := 0; vBehind := 0; vTie := 0;
  for i := 1 to 14 do
  begin
    if i = 2 then Continue;   // file size reported below
    vm := Med3(VTime[i]);
    sm := Med3(STime[i]);

    o := OpsMedian([VOper[i, 1], VOper[i, 2], VOper[i, 3]]);
    if o <= 0 then o := 1;
    vu := vm / o;
    o := OpsMedian([SOper[i, 1], SOper[i, 2], SOper[i, 3]]);
    if o <= 0 then o := 1;
    su := sm / o;

    if sm > 0 then
    begin
      ratio := vm / sm;
      if ratio < 0.98 then Inc(vAhead)
      else if ratio > 1.02 then Inc(vBehind)
      else Inc(vTie);
    end;

    WriteLn(Format('%-4d %-40s %11.2f %11.2f %9s %11.2f %11.2f',
      [i, StageName[i], vm / 1000.0, sm / 1000.0,
       RatioText(vm, sm), vu, su]));
  end;

  WriteLn;
  WriteLn('File size (after bulk insert, before mutations):');
  WriteLn(Format('  VDB    : %12d B total = .odb %d + .idx %d + .wal %d  (%.2f B/row)',
    [VSizeTotal, VSizeOdb, VSizeIdx, VSizeWal, VSizeTotal / N]));
  WriteLn(Format('  SQLite : %12d B total = .db %d + journal %d        (%.2f B/row)',
    [SSizeTotal, SSizeDb, SSizeJournal, SSizeTotal / N]));

  WriteLn;
  WriteLn('Round spread (all three rounds, microseconds of the whole round workload):');
  WriteLn(Format('%-4s %-40s %-26s %-26s %8s %8s',
    ['#', 'Stage', 'VDB rounds', 'SQLite rounds', 'VDB%', 'SQL%']));
  for i := 1 to 14 do
  begin
    if i = 2 then Continue;
    WriteLn(Format('%-4d %-40s %6d %6d %6d   %6d %6d %6d   %7.1f%% %7.1f%%',
      [i, StageName[i], VTime[i, 1], VTime[i, 2], VTime[i, 3],
       STime[i, 1], STime[i, 2], STime[i, 3],
       SpreadPct(VTime[i]), SpreadPct(STime[i])]));
  end;

  WriteLn;
  WriteLn('Result consistency (first round, same data on both engines):');
  WriteLn(Format('  PK point SELECT rows     : VDB %d  SQLite %d', [VValid[3], SValid[3]]));
  WriteLn(Format('  Range SELECT rows        : VDB %d  SQLite %d', [VValid[4], SValid[4]]));
  WriteLn(Format('  COUNT(*)                 : VDB %d  SQLite %d', [VValid[5], SValid[5]]));
  WriteLn(Format('  SUM(id)                  : VDB %d  SQLite %d', [VValid[6], SValid[6]]));
  WriteLn(Format('  GROUP BY rows            : VDB %d  SQLite %d', [VValid[7], SValid[7]]));
  WriteLn(Format('  ORDER BY rows            : VDB %d  SQLite %d', [VValid[8], SValid[8]]));
  WriteLn(Format('  Non-indexed COUNT        : VDB %d  SQLite %d', [VValid[9], SValid[9]]));
  WriteLn(Format('  PK point DELETE affected : VDB %d  SQLite %d', [VValid[12], SValid[12]]));
  WriteLn(Format('  Bulk UPDATE affected     : VDB %d  SQLite %d', [VAff[11], SAff[11]]));
  WriteLn(Format('  Bulk DELETE affected     : VDB %d  SQLite %d', [VAff[13], SAff[13]]));

  WriteLn;
  WriteLn(Format('Summary: VDB ahead in %d stages, behind in %d, within +/-2%% in %d.',
    [vAhead, vBehind, vTie]));
  WriteLn('  (File size and result consistency are reported separately above.)');
  WriteLn('==================================================================================');
end;

{ ---------------- main ---------------- }

var
  rep, i: Integer;
  C: TVdbConn;
  Db: sqlite3_ptr;
  aff: Int64;
begin
  DefaultFormatSettings.DecimalSeparator := '.';
  QueryPerformanceFrequency(Freq);

  if ParamCount < 1 then
  begin
    WriteLn('usage: sqlitecmp.exe <work-directory> [rows]');
    WriteLn('  The work directory is mandatory; both engines run in it.');
    Halt(2);
  end;

  Root := ParamStr(1);
  N := N_ROWS_DEFAULT;
  if ParamCount >= 2 then
    N := StrToIntDef(ParamStr(2), N);

  VdbDir := IncludeTrailingPathDelimiter(Root) + 'vdb';
  SqliteDir := IncludeTrailingPathDelimiter(Root) + 'sqlite';
  WarmDir := IncludeTrailingPathDelimiter(Root) + 'warmup';
  VdbFile := IncludeTrailingPathDelimiter(VdbDir) + 'veritabani.odb';
  SqliteFile := IncludeTrailingPathDelimiter(SqliteDir) + 'bench.db';

  ForceDirectories(Root);
  ForceDirectories(VdbDir);
  ForceDirectories(SqliteDir);
  ForceDirectories(WarmDir);
  DeleteFilesIn(VdbDir);
  DeleteFilesIn(SqliteDir);
  DeleteFilesIn(WarmDir);

  WriteLn('==================================================================================');
  WriteLn('  VDB v3 vs SQLite - same machine, same data, same statement order');
  WriteLn('==================================================================================');
  WriteLn('Date/time : ', DateTimeToStr(Now));
  WriteLn('Platform  : ', {$I %FPCTARGETOS%}, ' ', {$I %FPCTARGETCPU%}, ' FPC ', {$I %FPCVERSION%});
  WriteLn('SQLite    : ', string(sqlite3_libversion()));
  WriteLn('Rows      : ', N);
  WriteLn('Repeats   : ', NREP, ' (median reported; separate warmup round)');
  WriteLn('Work dir  : ', Root);
  WriteLn('SQLite    : journal_mode=DELETE, synchronous=FULL; VDB defaults.');
  WriteLn('Note      : SQLite point statements are prepared once per stage;');
  WriteLn('            VDB parses each Exec (its public API).');
  WriteLn('----------------------------------------------------------------------------------');

  Write('Warmup (separate round)... ');
  WarmupVdb;
  WarmupSqlite;
  WriteLn('done');

  WriteLn;
  WriteLn('[VDB] bulk INSERT, ', NREP, ' independent builds');
  for rep := 1 to NREP do
  begin
    VTime[1, rep] := VdbBuildInsert(aff);
    VOper[1, rep] := aff;
    WriteLn(Format('  round %d: %.2f ms  (%.2f us/row)',
      [rep, VTime[1, rep] / 1000.0, VTime[1, rep] / aff]));
  end;
  VSizeOdb := FileBytes(VdbFile);
  VSizeIdx := FileBytes(VdbFile + '.idx');
  VSizeWal := FileBytes(VdbFile + '.wal');
  VSizeTotal := DirBytes(VdbDir);

  C := VdbOpen(VdbDir);
  try
    Write('  read warmup (unmeasured, full data set)... ');
    VdbReadWarm(C);
    WriteLn('done');
    Write('  read stages 3-9... ');
    VdbReads(C);
    WriteLn('done');
    Write('  mutation stages 10-13... ');
    VdbMutations(C);
    WriteLn('done');
  finally
    VdbClose(C);
  end;
  VdbOpenStage;

  WriteLn;
  WriteLn('[SQLite] bulk INSERT, ', NREP, ' independent builds');
  for rep := 1 to NREP do
  begin
    STime[1, rep] := SqliteBuildInsert(aff);
    SOper[1, rep] := aff;
    WriteLn(Format('  round %d: %.2f ms  (%.2f us/row)',
      [rep, STime[1, rep] / 1000.0, STime[1, rep] / aff]));
  end;
  SSizeDb := FileBytes(SqliteFile);
  SSizeJournal := FileBytes(SqliteFile + '-journal');
  if SSizeJournal = 0 then
    SSizeJournal := FileBytes(SqliteFile + '-wal');
  SSizeTotal := DirBytes(SqliteDir);

  if not SqliteOpenConn(Db) then
    raise Exception.Create('SQLite reopen failed: ' + string(sqlite3_errmsg(Db)));
  try
    Write('  read warmup (unmeasured, full data set)... ');
    SqliteReadWarm(Db);
    WriteLn('done');
    Write('  read stages 3-9... ');
    SqliteReads(Db);
    WriteLn('done');
    Write('  mutation stages 10-13... ');
    SqliteMutations(Db);
    WriteLn('done');
  finally
    sqlite3_close(Db);
  end;
  SqliteOpenStage;

  PrintReport;

  DeleteFilesIn(WarmDir);
  RemoveDir(WarmDir);
end.
