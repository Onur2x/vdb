program bench_size;
{$mode delphi}
{$APPTYPE CONSOLE}

{ Adil dosya boyutu kiyasi: ayni 1M satiri hem SQLite'a hem VDB'ye yaz,
  diskteki dosya boyutlarini olc. }

uses
  SysUtils, Classes, ctypes, Windows,
  VDbCore, VDbTable, VDbSql, VDbTypes,
  sqlite3;

const
  N = 1000000;
  BASE = 'bench_size_dir';

function FileSizeKB(const p: string): Int64;
var
  f: TFileStream;
begin
  if not FileExists(p) then Exit(0);
  f := TFileStream.Create(p, fmOpenRead or fmShareDenyNone);
  try
    Result := f.Size div 1024;
  finally
    f.Free;
  end;
end;

procedure RunSQLite(const dbPath: string);
var
  db: psqlite3;
  st: psqlite3_stmt;
  j: Integer;
  rc: cint;
begin
  if FileExists(dbPath) then SysUtils.DeleteFile(dbPath);
  if FileExists(dbPath + '-wal') then SysUtils.DeleteFile(dbPath + '-wal');
  if FileExists(dbPath + '-shm') then SysUtils.DeleteFile(dbPath + '-shm');
  if FileExists(dbPath + '-journal') then SysUtils.DeleteFile(dbPath + '-journal');

  rc := sqlite3_open(PAnsiChar(AnsiString(dbPath)), @db);
  if rc <> SQLITE_OK then begin Writeln('SQLite open HATA'); Exit; end;
  sqlite3_exec(db, PAnsiChar(AnsiString('CREATE TABLE b(id INTEGER PRIMARY KEY, name TEXT, val INTEGER)')), nil, nil, nil);
  sqlite3_exec(db, PAnsiChar(AnsiString('BEGIN')), nil, nil, nil);
  sqlite3_prepare_v2(db, 'INSERT INTO b(id,name,val) VALUES(?,?,?)', -1, @st, nil);
  for j := 1 to N do
  begin
    sqlite3_bind_int(st, 1, j);
    sqlite3_bind_text(st, 2, PAnsiChar(AnsiString('row' + IntToStr(j))), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 3, j * 2);
    sqlite3_step(st);
    sqlite3_reset(st);
  end;
  sqlite3_finalize(st);
  sqlite3_exec(db, PAnsiChar(AnsiString('COMMIT')), nil, nil, nil);
  sqlite3_close(db);
  Writeln(Format('[SQLite]  main=%d KB (b = %d satir)', [FileSizeKB(dbPath), N]));
end;

procedure RunVdb(dir: string);
var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  j: Integer;
  odbPath: string;
begin
  if DirectoryExists(dir) then RemoveDir(dir);
  ForceDirectories(dir);
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(dir);
    tb.Open(dir);
    sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, name TEXT, val INTEGER)');
    sq.Exec('BEGIN');
    for j := 1 to N do
      sq.Exec(Format('INSERT INTO b VALUES(%d,''row%d'',%d)', [j, j, j * 2]));
    sq.Exec('COMMIT');
  finally
    odbPath := kv.FilePath;
    sq.Free;
    tb.Free;
    kv.Free;
  end;
  Writeln(Format('[VDB]     odb=%d KB  (b = %d satir)  -> %s', [FileSizeKB(odbPath), N, odbPath]));
end;

begin
  try
    Writeln('=== ADIL DOSYA BOYUTU KIYASI (ayni 1M satir: id INT PK, name TEXT, val INT) ===');
    if DirectoryExists(BASE) then RemoveDir(BASE);
    ForceDirectories(BASE);
    RunSQLite(BASE + '\sq.db');
    RunVdb(BASE + '\vdb');
  except
    on E: Exception do Writeln('HATA: ', E.Message);
  end;
end.
