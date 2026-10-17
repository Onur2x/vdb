program SpeedTest;

{$mode delphi}
{$APPTYPE CONSOLE}

{ VDB vs SQLite hiz karsilastirmasi.
  Ayni sema, ayni veri, ayni SQL - iki motor icin de ayni isler olculur.
  Kullanim: speedtest.exe [calisma_dizini] }

uses
  SysUtils, Classes, ctypes, Windows,
  VDbCore, VDbTable, VDbSql, VDbTypes,
  sqlite3;

const
  N_BATCH  = 10000;   // transaction ici INSERT
  N_SINGLE = 5000;    // tek tek (autocommit) INSERT
  N_SEL    = 10000;   // PK nokta sorgusu
  N_RANGE  = 500;     // BETWEEN range sorgusu (her biri ~200 satir doner)
  N_UPD    = 5000;    // tek tek UPDATE
  N_DEL    = 5000;    // tek tek DELETE

var
  GCheck: Int64;      // sonuc gercekten geldi mi (islev disi birakmamak icin)
  GFreq: Int64;

type
  TTick = Int64;

function NowTick: TTick;
var c: Int64;
begin
  QueryPerformanceCounter(c);
  Result := c;
end;

function Sec(t0, t1: TTick): Double;
begin
  Result := (t1 - t0) / GFreq;
end;

function Rate(n: Integer; s: Double): Double;
begin
  if s > 0 then Result := n / s else Result := 0;
end;

procedure Line(const name: string; n: Integer; s: Double);
begin
  WriteLn(Format('  %-36s %8.3f sn %11.0f/sn', [name, s, Rate(n, s)]));
end;

{ ---------------------------------------------------------------- SQLite }

var
  GDb: psqlite3;

procedure Chk(rc: cint; const step: string);
begin
  if rc <> SQLITE_OK then
    raise Exception.Create(step + ' basarisiz: ' + string(AnsiString(sqlite3_errmsg(GDb))));
end;

procedure SX(const sql: string);
begin
  Chk(sqlite3_exec(GDb, PAnsiChar(AnsiString(sql)), nil, nil, nil), sql);
end;

procedure RunSQLite(const dbPath, modeName: string; wal: Boolean);
var
  t0, t1: TTick;
  st: psqlite3_stmt;
  j: Integer;
begin
  WriteLn;
  WriteLn('=== SQLite - ', modeName, ' ===');

  if FileExists(dbPath) then SysUtils.DeleteFile(dbPath);
  if FileExists(dbPath + '-wal') then SysUtils.DeleteFile(dbPath + '-wal');
  if FileExists(dbPath + '-shm') then SysUtils.DeleteFile(dbPath + '-shm');
  if FileExists(dbPath + '-journal') then SysUtils.DeleteFile(dbPath + '-journal');

  Chk(sqlite3_open(PAnsiChar(AnsiString(dbPath)), @GDb), 'open');
  sqlite3_busy_timeout(GDb, 5000);

  t0 := NowTick;
  SX('CREATE TABLE b(id INTEGER PRIMARY KEY, val INTEGER, txt TEXT)');
  if wal then
  begin
    SX('PRAGMA journal_mode=WAL');
    SX('PRAGMA synchronous=NORMAL');   // WAL ile dayanikli (crash-safe), fsync azaltildi
  end
  else
  begin
    SX('PRAGMA journal_mode=DELETE');
    SX('PRAGMA synchronous=FULL');     // varsayilan: her commit'te fsync
  end;
  t1 := NowTick;
  Line('CREATE TABLE + pragma', 1, Sec(t0, t1));

  // --- Batch INSERT (transaction) ---
  t0 := NowTick;
  SX('BEGIN');
  Chk(sqlite3_prepare_v2(GDb, 'INSERT INTO b(id,val,txt) VALUES(?,?,?)', -1, @st, nil), 'prep ins');
  for j := 1 to N_BATCH do
  begin
    sqlite3_bind_int(st, 1, j);
    sqlite3_bind_int(st, 2, j * 2);
    sqlite3_bind_text(st, 3, PAnsiChar(AnsiString('t' + IntToStr(j))), -1, SQLITE_TRANSIENT);
    sqlite3_step(st);
    sqlite3_reset(st);
  end;
  sqlite3_finalize(st);
  SX('COMMIT');
  t1 := NowTick;
  Line(Format('Batch INSERT %d (tx)', [N_BATCH]), N_BATCH, Sec(t0, t1));

  // --- Single INSERT (autocommit) ---
  t0 := NowTick;
  Chk(sqlite3_prepare_v2(GDb, 'INSERT INTO b(id,val,txt) VALUES(?,?,?)', -1, @st, nil), 'prep ins2');
  for j := N_BATCH + 1 to N_BATCH + N_SINGLE do
  begin
    sqlite3_bind_int(st, 1, j);
    sqlite3_bind_int(st, 2, j * 2);
    sqlite3_bind_text(st, 3, PAnsiChar(AnsiString('t' + IntToStr(j))), -1, SQLITE_TRANSIENT);
    sqlite3_step(st);
    sqlite3_reset(st);
  end;
  sqlite3_finalize(st);
  t1 := NowTick;
  Line(Format('Single INSERT %d (autocommit)', [N_SINGLE]), N_SINGLE, Sec(t0, t1));

  // --- SELECT PK (nokta) ---
  GCheck := 0;
  t0 := NowTick;
  Chk(sqlite3_prepare_v2(GDb, 'SELECT val FROM b WHERE id = ?', -1, @st, nil), 'prep sel');
  for j := 1 to N_SEL do
  begin
    sqlite3_bind_int(st, 1, j);
    if sqlite3_step(st) = SQLITE_ROW then
      Inc(GCheck, sqlite3_column_int64(st, 0));
    sqlite3_reset(st);
  end;
  sqlite3_finalize(st);
  t1 := NowTick;
  Line(Format('SELECT PK %d (nokta)', [N_SEL]), N_SEL, Sec(t0, t1));

  // --- Range (BETWEEN) ---
  GCheck := 0;
  t0 := NowTick;
  Chk(sqlite3_prepare_v2(GDb, 'SELECT val FROM b WHERE id BETWEEN ? AND ?', -1, @st, nil), 'prep rng');
  for j := 1 to N_RANGE do
  begin
    sqlite3_bind_int(st, 1, j);
    sqlite3_bind_int(st, 2, j + 199);
    while sqlite3_step(st) = SQLITE_ROW do
      Inc(GCheck, sqlite3_column_int64(st, 0));
    sqlite3_reset(st);
  end;
  sqlite3_finalize(st);
  t1 := NowTick;
  Line(Format('Range BETWEEN %d x 200 satir', [N_RANGE]), N_RANGE, Sec(t0, t1));

  // --- UPDATE tek tek ---
  t0 := NowTick;
  Chk(sqlite3_prepare_v2(GDb, 'UPDATE b SET val = val + 1 WHERE id = ?', -1, @st, nil), 'prep upd');
  for j := 1 to N_UPD do
  begin
    sqlite3_bind_int(st, 1, j);
    sqlite3_step(st);
    sqlite3_reset(st);
  end;
  sqlite3_finalize(st);
  t1 := NowTick;
  Line(Format('UPDATE %d tek tek', [N_UPD]), N_UPD, Sec(t0, t1));

  // --- DELETE tek tek ---
  t0 := NowTick;
  Chk(sqlite3_prepare_v2(GDb, 'DELETE FROM b WHERE id = ?', -1, @st, nil), 'prep del');
  for j := 1 to N_DEL do
  begin
    sqlite3_bind_int(st, 1, j);
    sqlite3_step(st);
    sqlite3_reset(st);
  end;
  sqlite3_finalize(st);
  t1 := NowTick;
  Line(Format('DELETE %d tek tek', [N_DEL]), N_DEL, Sec(t0, t1));

  sqlite3_close(GDb);
  GDb := nil;
end;

{ ------------------------------------------------------------------- VDB }

procedure RunVdb(const dir: string; interval: Integer; const modeName: string);
var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  R: TSqlResult;
  t0, t1: TTick;
  i, j, k: Integer;
  chunk: string;
begin
  WriteLn;
  WriteLn('=== VDB - ', modeName, ' ===');

  if DirectoryExists(dir) then
  begin
    RemoveDir(dir);   // en temiz kosu: sifirdan
    Sleep(50);
  end;
  ForceDirectories(dir);

  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(dir);
    tb.Open(dir);
    kv.SyncWriteInterval := interval;

    t0 := NowTick;
    sq.Exec('DROP TABLE IF EXISTS b');
    sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, val INTEGER, txt TEXT)');
    t1 := NowTick;
    Line('CREATE TABLE', 1, Sec(t0, t1));

    // --- Batch INSERT (transaction) ---
    t0 := NowTick;
    sq.Exec('BEGIN');
    for j := 1 to N_BATCH do
      sq.Exec(Format('INSERT INTO b(id,val,txt) VALUES(%d,%d,''t%d'')', [j, j * 2, j]));
    sq.Exec('COMMIT');
    t1 := NowTick;
    Line(Format('Batch INSERT %d (tx)', [N_BATCH]), N_BATCH, Sec(t0, t1));

    // --- Multi-row VALUES (R-26: yazma yolu icin ONERILEN yol) ---
    // Parser/executor satir basina degil statement basina calisir.
    sq.Exec('DROP TABLE IF EXISTS bm');
    sq.Exec('CREATE TABLE bm(id INTEGER PRIMARY KEY, val INTEGER, txt TEXT)');
    t0 := NowTick;
    sq.Exec('BEGIN');
    j := 1;
    while j <= N_BATCH do
    begin
      chunk := '';
      for k := 1 to 100 do
      begin
        if j > N_BATCH then Break;
        if chunk <> '' then chunk := chunk + ',';
        chunk := chunk + Format('(%d,%d,''t%d'')', [j, j * 2, j]);
        Inc(j);
      end;
      sq.Exec('INSERT INTO bm(id,val,txt) VALUES' + chunk);
    end;
    sq.Exec('COMMIT');
    t1 := NowTick;
    Line(Format('Multi-row VALUES %d (100/stmt)', [N_BATCH]), N_BATCH, Sec(t0, t1));
    sq.Exec('DROP TABLE IF EXISTS bm');

    // --- Single INSERT (autocommit) ---
    t0 := NowTick;
    for j := N_BATCH + 1 to N_BATCH + N_SINGLE do
      sq.Exec(Format('INSERT INTO b(id,val,txt) VALUES(%d,%d,''t%d'')', [j, j * 2, j]));
    t1 := NowTick;
    Line(Format('Single INSERT %d (autocommit)', [N_SINGLE]), N_SINGLE, Sec(t0, t1));

    // --- SELECT PK (nokta) ---
    GCheck := 0;
    t0 := NowTick;
    for j := 1 to N_SEL do
    begin
      R := sq.Exec('SELECT val FROM b WHERE id = ' + IntToStr(j));
      if Length(R.Rows) > 0 then
        Inc(GCheck, StrToInt64Def(R.Rows[0][0], 0));
    end;
    t1 := NowTick;
    Line(Format('SELECT PK %d (nokta)', [N_SEL]), N_SEL, Sec(t0, t1));

    // --- Range (BETWEEN) ---
    GCheck := 0;
    t0 := NowTick;
    for j := 1 to N_RANGE do
    begin
      R := sq.Exec(Format('SELECT val FROM b WHERE id BETWEEN %d AND %d', [j, j + 199]));
      for i := 0 to High(R.Rows) do
        Inc(GCheck, StrToInt64Def(R.Rows[i][0], 0));
    end;
    t1 := NowTick;
    Line(Format('Range BETWEEN %d x 200 satir', [N_RANGE]), N_RANGE, Sec(t0, t1));

    // --- UPDATE tek tek ---
    t0 := NowTick;
    for j := 1 to N_UPD do
      sq.Exec('UPDATE b SET val = val + 1 WHERE id = ' + IntToStr(j));
    t1 := NowTick;
    Line(Format('UPDATE %d tek tek', [N_UPD]), N_UPD, Sec(t0, t1));

    // --- DELETE tek tek ---
    t0 := NowTick;
    for j := 1 to N_DEL do
      sq.Exec('DELETE FROM b WHERE id = ' + IntToStr(j));
    t1 := NowTick;
    Line(Format('DELETE %d tek tek', [N_DEL]), N_DEL, Sec(t0, t1));
  finally
    sq.Free;
    tb.Free;
    kv.Free;
  end;
end;

{ ------------------------------------------------------------------- main }

var
  base: string;
begin
  QueryPerformanceFrequency(GFreq);
  if ParamCount >= 1 then
    base := ParamStr(1)
  else
    base := 'C:\temp\speedtest';
  if not DirectoryExists(base) then ForceDirectories(base);

  // Statik baglanti: sqlite3.dll exe ile ayni klasorda olmali
  if not FileExists(ExtractFilePath(ParamStr(0)) + 'sqlite3.dll') then
  begin
    WriteLn('sqlite3.dll exe yaninda degil: ', ExtractFilePath(ParamStr(0)));
    Halt(1);
  end;

  WriteLn('SQLite surumu: ', string(AnsiString(sqlite3_libversion())));
  WriteLn('Calisma dizini: ', base);
  WriteLn(Format('Satirlar: batch=%d single=%d sel=%d range=%d upd=%d del=%d',
    [N_BATCH, N_SINGLE, N_SEL, N_RANGE, N_UPD, N_DEL]));

  try
    RunSQLite(base + '\bench.db', 'DAYANIKLI (journal=DELETE, sync=FULL)', False);
  except
    on E: Exception do WriteLn('SQLite dayanikli HATA: ', E.Message);
  end;

  try
    RunSQLite(base + '\benchwal.db', 'HIZLI (journal=WAL, sync=NORMAL)', True);
  except
    on E: Exception do WriteLn('SQLite WAL HATA: ', E.Message);
  end;

  try
    RunVdb(base + '\vdb0', 0, 'DAYANIKLI (SyncWriteInterval=0)');
  except
    on E: Exception do WriteLn('VDB dayanikli HATA: ', E.Message);
  end;

  try
    RunVdb(base + '\vdb10', 10, 'HIZLI (SyncWriteInterval=10ms)');
  except
    on E: Exception do WriteLn('VDB hizli HATA: ', E.Message);
  end;

  WriteLn;
  WriteLn('checksum=', GCheck, ' (sifir degilse sorgular gercek veri dondurdu)');
  WriteLn('Bitti.');
end.


