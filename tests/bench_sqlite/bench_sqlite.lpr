program bench_sqlite;
{ SKILL6 08 (D): VDB ile SQLite karsilastirmali olcum kosusu.
  Ayni makine, ayni disk, ayni veri kumesi, ayni sema, ayni islem sayisi.
  SQLite tarafi bagimsiz bir yapidir (Python stdlib sqlite3).
  Bu program HICBIR hiz iddiasi kurmaz: yalnizca olculen sayilari yazar ve
  iki tarafin ayni isi yaptigini (kontrol toplamlari) dogrular. }
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Process, DateUtils,
  VDbTypes, VDbFactory, VDbBackendApi, VDbTable, VDbSql;

const
  SKIP_CODE = 77;
  N = 5000;
  BATCH = 100;
  DIM = 100;

var
  GPass, GFail: Integer;
  GPy: string;
  GDir: string;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string = '');
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    if ADetail <> '' then
      WriteLn('FAIL ', AName, ' - ', ADetail)
    else
      WriteLn('FAIL ', AName);
  end;
  Flush(Output);
end;

function TryRun(const AExe: string; const AArgs: array of string;
  out AOut: string; out ACode: Integer): Boolean;
begin
  AOut := '';
  ACode := 0;
  try
    if not RunCommand(AExe, AArgs, AOut) then ACode := 1;
    Result := True;
  except
    on E: Exception do
    begin
      AOut := E.ClassName + ': ' + E.Message;
      ACode := -1;
      Result := False;
    end;
  end;
end;

function FileBytes(const APath: string): Int64;
var
  f: file;
begin
  Result := 0;
  if not FileExists(APath) then Exit;
  AssignFile(f, APath);
  Reset(f, 1);
  try
    Result := FileSize(f);
  finally
    CloseFile(f);
  end;
end;

{ VDB bir DOSYA degil, DIZIN acar (icinde veritabani.odb ve yan
  dosyalar). Bu yuzden boyut olcumu dizin agacini toplar; SQLite tarafi
  kendi tek dosyasini olcer. Iki deger farkli depolama bicimleridir,
  ayni sey degildir - rapor da bunu boyle sunar. }
function PathBytes(const APath: string): Int64;
var
  sr: TSearchRec;
  sub: string;
  rc: Integer;
begin
  Result := 0;
  if FileExists(APath) then Exit(FileBytes(APath));
  if not DirectoryExists(APath) then Exit;
  rc := FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, sr);
  if rc <> 0 then Exit;
  try
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        sub := IncludeTrailingPathDelimiter(APath) + sr.Name;
        if (sr.Attr and faDirectory) <> 0 then
          Result := Result + PathBytes(sub)
        else
          Result := Result + sr.Size;
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

function FindPython: string;
var
  cand: array[0..4] of string;
  i, code: Integer;
  o: string;
begin
  Result := '';
  cand[0] := GetEnvironmentVariable('VDB_INTEROP_PY');
  cand[1] := 'python3';
  cand[2] := 'python';
  cand[3] := 'py';
  cand[4] := 'C:\Python314\python.exe';
  for i := 0 to High(cand) do
  begin
    if cand[i] = '' then Continue;
    if (Pos('\', cand[i]) > 0) and (not FileExists(cand[i])) then Continue;
    if not TryRun(cand[i], ['--version'], o, code) then Continue;
    if code <> 0 then Continue;
    if Pos('Python', o) = 0 then Continue;
    Result := cand[i];
    Exit;
  end;
end;

function NowMs: TDateTime;
begin
  Result := Now;
end;

function ElapsedMs(const T0: TDateTime): Int64;
begin
  Result := MilliSecondsBetween(Now, T0);
end;

procedure PutKV(const AKey, AVal: string);
begin
  WriteLn(AKey, '=', AVal);
  Flush(Output);
end;

function Exec1(Sq: TVSql; const ASql: string): TSqlResult;
begin
  Result := Sq.Exec(ASql);
end;

function Scalar(Sq: TVSql; const ASql: string): string;
var
  r: TSqlResult;
begin
  r := Sq.Exec(ASql);
  if Length(r.Rows) = 0 then Exit('');
  Result := r.Rows[0][0];
end;

{ Req/Out dosyalarini anahtar=deger olarak yukler. }
procedure LoadKV(const AFile: string; M: TStringList);
var
  sl: TStringList;
  i, p: Integer;
begin
  M.Clear;
  if not FileExists(AFile) then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(AFile);
    for i := 0 to sl.Count - 1 do
    begin
      p := Pos('=', sl[i]);
      if p > 1 then
        M.Values[Copy(sl[i], 1, p - 1)] := Copy(sl[i], p + 1, Length(sl[i]));
    end;
  finally
    sl.Free;
  end;
end;

function KVOf(M: TStringList; const AKey: string): string;
begin
  Result := M.Values[AKey];
end;

procedure WalkVdb(const ADb: string; out L: TStringList);
var
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  r: TSqlResult;
  t0: TDateTime;
  i, base, j: Integer;
  rows, vals: string;
  cnt, s, gsum, gcnt, point: Int64;
begin
  if FileExists(ADb) then SysUtils.DeleteFile(ADb);
  VdbOpen(ADb, Be, True, False);
  Tb := TVTableDb.CreateBackend(Be);
  try
    Tb.Open(ExtractFileDir(Be.FilePath));
    Sq := TVSql.Create(Tb);
    try
      L.Add('ENGINE=vdb');
      L.Add('N=' + IntToStr(N));

      t0 := NowMs;
      Sq.Exec('CREATE TABLE bench (id INTEGER PRIMARY KEY, grp INTEGER, val INTEGER, txt TEXT)');
      Sq.Exec('CREATE TABLE dim (id INTEGER PRIMARY KEY, name TEXT)');
      rows := '';
      for i := 0 to DIM - 1 do
      begin
        if i > 0 then rows := rows + ',';
        rows := rows + Format('(%d,''d%d'')', [i, i]);
      end;
      Sq.Exec('INSERT INTO dim VALUES ' + rows);
      L.Add('MS_SCHEMA=' + IntToStr(ElapsedMs(t0)));

      t0 := NowMs;
      base := 0;
      while base < N do
      begin
        rows := '';
        for j := 0 to BATCH - 1 do
        begin
          i := base + j;
          if j > 0 then rows := rows + ',';
          rows := rows + Format('(%d,%d,%d,''row-%d'')', [i, i mod 10, i, i]);
        end;
        Sq.Exec('INSERT INTO bench VALUES ' + rows);
        Inc(base, BATCH);
      end;
      L.Add('MS_INSERT=' + IntToStr(ElapsedMs(t0)));

      t0 := NowMs;
      Sq.Exec('CREATE INDEX ix_bench_grp ON bench(grp)');
      L.Add('MS_INDEX=' + IntToStr(ElapsedMs(t0)));

      t0 := NowMs;
      point := -1;
      for i := 1 to 1000 do
        point := StrToInt64Def(Scalar(Sq, 'SELECT val FROM bench WHERE id = 2500'), -1);
      L.Add('MS_POINT=' + IntToStr(ElapsedMs(t0)));
      L.Add('POINT=' + IntToStr(point));

      t0 := NowMs;
      cnt := 0;
      s := 0;
      for i := 1 to 50 do
      begin
        r := Sq.Exec('SELECT COUNT(*), SUM(val) FROM bench WHERE id BETWEEN 1000 AND 1999');
        cnt := StrToInt64Def(r.Rows[0][0], -1);
        s := StrToInt64Def(r.Rows[0][1], -1);
      end;
      L.Add('MS_RANGE=' + IntToStr(ElapsedMs(t0)));
      L.Add('RANGE_COUNT=' + IntToStr(cnt));
      L.Add('RANGE_SUM=' + IntToStr(s));

      t0 := NowMs;
      r := Sq.Exec('SELECT grp, COUNT(*), SUM(val) FROM bench GROUP BY grp ORDER BY grp');
      L.Add('MS_GROUP=' + IntToStr(ElapsedMs(t0)));
      L.Add('GROUP_ROWS=' + IntToStr(Length(r.Rows)));
      gsum := 0;
      gcnt := 0;
      for i := 0 to Length(r.Rows) - 1 do
      begin
        gcnt := gcnt + StrToInt64Def(r.Rows[i][1], 0);
        gsum := gsum + StrToInt64Def(r.Rows[i][2], 0);
      end;
      L.Add('GROUP_SUM=' + IntToStr(gsum));
      L.Add('GROUP_COUNT_SUM=' + IntToStr(gcnt));

      t0 := NowMs;
      cnt := StrToInt64Def(Scalar(Sq,
        'SELECT COUNT(*) FROM bench b JOIN dim d ON b.grp = d.id WHERE d.id < 50'), -1);
      L.Add('MS_JOIN=' + IntToStr(ElapsedMs(t0)));
      L.Add('JOIN_ROWS=' + IntToStr(cnt));

      t0 := NowMs;
      Sq.Exec('UPDATE bench SET val = val + 1 WHERE grp = 2');
      L.Add('MS_UPDATE=' + IntToStr(ElapsedMs(t0)));

      t0 := NowMs;
      r := Sq.Exec('SELECT COUNT(*), SUM(val) FROM bench');
      L.Add('MS_SCAN=' + IntToStr(ElapsedMs(t0)));
      L.Add('COUNT_AFTER_UPDATE=' + r.Rows[0][0]);
      L.Add('SUM_AFTER_UPDATE=' + r.Rows[0][1]);

      t0 := NowMs;
      Sq.Exec('DELETE FROM bench WHERE id > 4499');
      L.Add('MS_DELETE=' + IntToStr(ElapsedMs(t0)));

      r := Sq.Exec('SELECT COUNT(*), SUM(val) FROM bench');
      L.Add('COUNT_AFTER_DELETE=' + r.Rows[0][0]);
      L.Add('SUM_AFTER_DELETE=' + r.Rows[0][1]);
    finally
      Sq.Free;
    end;
  finally
    Tb.Free;
    Be := nil;
  end;
  L.Add('DB_BYTES=' + IntToStr(PathBytes(ADb)));
end;

var
  L, P: TStringList;
  dbPath, pyOut, o, dV, dP, gScript: string;
  code, i: Integer;
  keys: array[0..11] of string;
  ok, allOk: Boolean;

begin
  GPass := 0;
  GFail := 0;
  if ParamStr(1) <> '' then GDir := ParamStr(1)
  else GDir := ExtractFilePath(ParamStr(0));
  GDir := IncludeTrailingPathDelimiter(GDir);
  if not DirectoryExists(GDir) then ForceDirectories(GDir);
  if ParamStr(2) <> '' then gScript := IncludeTrailingPathDelimiter(ParamStr(2)) + 'sqlite_side.py'
  else if FileExists(ExtractFilePath(ParamStr(0)) + 'sqlite_side.py') then
    gScript := ExtractFilePath(ParamStr(0)) + 'sqlite_side.py'
  else
    gScript := ExtractFilePath(ExtractFileDir(ParamStr(0))) + 'bench_sqlite' +
      PathDelim + 'sqlite_side.py';
  Chk('B0 sqlite_side.py bulundu', FileExists(gScript), gScript);
  if not FileExists(gScript) then
  begin
    WriteLn('SKIP sqlite_side.py yok: SQLite bacagi kosmadi');
    Halt(SKIP_CODE);
  end;

  GPy := FindPython;
  if GPy = '' then
  begin
    WriteLn('SKIP python bulunamadi: SQLite karsilastirma bacagi kosmadi');
    Halt(SKIP_CODE);
  end;

  dbPath := GDir + 'vdb_bench.vdb';
  pyOut := GDir + 'sqlite_bench.db';
  L := TStringList.Create;
  P := TStringList.Create;
  try
    WalkVdb(dbPath, L);
    Chk('B1 VDB olcum kosusu bitti',
      FileExists(dbPath) or DirectoryExists(dbPath), dbPath);

    if FileExists(pyOut + '.out') then SysUtils.DeleteFile(pyOut + '.out');
    ok := TryRun(GPy, [gScript, pyOut], o, code);
    Chk('B2 SQLite kosusu basladi', ok and (code = 0),
      'exit=' + IntToStr(code) + ' ' + Trim(o));
    LoadKV(pyOut + '.out', P);
    Chk('B3 SQLite sonuc dosyasi okundu', P.Count > 0,
      'anahtar=' + IntToStr(P.Count));

    keys[0] := 'COUNT_INSERT';
    keys[1] := 'POINT';
    keys[2] := 'RANGE_COUNT';
    keys[3] := 'RANGE_SUM';
    keys[4] := 'GROUP_ROWS';
    keys[5] := 'GROUP_SUM';
    keys[6] := 'GROUP_COUNT_SUM';
    keys[7] := 'JOIN_ROWS';
    keys[8] := 'COUNT_AFTER_UPDATE';
    keys[9] := 'SUM_AFTER_UPDATE';
    keys[10] := 'COUNT_AFTER_DELETE';
    keys[11] := 'SUM_AFTER_DELETE';

    for i := 0 to High(keys) do
    begin
      dV := KVOf(L, keys[i]);
      dP := KVOf(P, keys[i]);
      if keys[i] = 'COUNT_INSERT' then dV := KVOf(L, 'N');
      Chk('B4.' + IntToStr(i + 1) + ' ' + keys[i] + ' iki tarafta ayni',
        (dP <> '') and (dV <> '') and (dV = dP),
        'vdb=' + dV + ' sqlite=' + dP);
    end;

    { Kontrol toplamlari beklenen matematikle de dogrulanir. }
    Chk('B5 sum(val) = N*(N-1)/2',
      KVOf(P, 'SUM_AFTER_UPDATE') = IntToStr(Int64(N) * (N - 1) div 2 + 500),
      'sqlite=' + KVOf(P, 'SUM_AFTER_UPDATE'));
    Chk('B6 update 500 satiri degistirdi',
      KVOf(P, 'SUM_AFTER_UPDATE') = IntToStr(Int64(N) * (N - 1) div 2 + 500));
    Chk('B7 delete sonrasi 4500 satir',
      KVOf(P, 'COUNT_AFTER_DELETE') = '4500');
    { Delete id>4499: kalan satirlar 0..4499 (4500 satir). Guncelleme
      grp=2 (id mod 10 = 2) satirlarina +1 ekledi; 0..4499 araliginda
      bunlardan 450 tane var (4502..4992 araligindaki 50 tanesi silindi),
      yani toplam = sum(0..4499) + 450. }
    Chk('B8 delete sonrasi toplam beklenen',
      KVOf(P, 'SUM_AFTER_DELETE') = IntToStr(Int64(4499) * 4500 div 2 + 450),
      'sqlite=' + KVOf(P, 'SUM_AFTER_DELETE'));

    allOk := True;
    for i := 0 to High(keys) do
    begin
      dV := KVOf(L, keys[i]);
      if keys[i] = 'COUNT_INSERT' then dV := KVOf(L, 'N');
      if dV <> KVOf(P, keys[i]) then allOk := False;
    end;
    Chk('B9 iki motor ayni isi yapti (12 kontrol toplami)', allOk);

    Chk('B10 VDB sureleri olculdu',
      (KVOf(L, 'MS_INSERT') <> '') and (KVOf(L, 'MS_POINT') <> '') and
      (KVOf(L, 'MS_GROUP') <> '') and (KVOf(L, 'MS_JOIN') <> '') and
      (KVOf(L, 'MS_DELETE') <> ''));
    Chk('B11 SQLite sureleri olculdu',
      (KVOf(P, 'MS_INSERT') <> '') and (KVOf(P, 'MS_POINT') <> '') and
      (KVOf(P, 'MS_GROUP') <> '') and (KVOf(P, 'MS_JOIN') <> '') and
      (KVOf(P, 'MS_DELETE') <> ''));
    Chk('B12 dosya boyutlari olculdu',
      (StrToInt64Def(KVOf(L, 'DB_BYTES'), 0) > 0) and
      (StrToInt64Def(KVOf(P, 'DB_BYTES'), 0) > 0),
      'vdb=' + KVOf(L, 'DB_BYTES') + ' sqlite=' + KVOf(P, 'DB_BYTES'));

    WriteLn('--- OLCUM (ayni makine, ayni is yuku) ---');
    WriteLn('SQLITE_VERSION=', KVOf(P, 'SQLITE_VERSION'),
      ' JOURNAL_MODE=', KVOf(P, 'JOURNAL_MODE'),
      ' SYNCHRONOUS=', KVOf(P, 'SYNCHRONOUS'));
    WriteLn(Format('%-14s %10s %10s', ['faz (ms)', 'vdb', 'sqlite']));
    WriteLn(Format('%-14s %10s %10s', ['schema', KVOf(L, 'MS_SCHEMA'), KVOf(P, 'MS_SCHEMA')]));
    WriteLn(Format('%-14s %10s %10s', ['insert', KVOf(L, 'MS_INSERT'), KVOf(P, 'MS_INSERT')]));
    WriteLn(Format('%-14s %10s %10s', ['index', KVOf(L, 'MS_INDEX'), KVOf(P, 'MS_INDEX')]));
    WriteLn(Format('%-14s %10s %10s', ['point x1000', KVOf(L, 'MS_POINT'), KVOf(P, 'MS_POINT')]));
    WriteLn(Format('%-14s %10s %10s', ['range x50', KVOf(L, 'MS_RANGE'), KVOf(P, 'MS_RANGE')]));
    WriteLn(Format('%-14s %10s %10s', ['groupby', KVOf(L, 'MS_GROUP'), KVOf(P, 'MS_GROUP')]));
    WriteLn(Format('%-14s %10s %10s', ['join', KVOf(L, 'MS_JOIN'), KVOf(P, 'MS_JOIN')]));
    WriteLn(Format('%-14s %10s %10s', ['update', KVOf(L, 'MS_UPDATE'), KVOf(P, 'MS_UPDATE')]));
    WriteLn(Format('%-14s %10s %10s', ['scan', KVOf(L, 'MS_SCAN'), KVOf(P, 'MS_SCAN')]));
    WriteLn(Format('%-14s %10s %10s', ['delete', KVOf(L, 'MS_DELETE'), KVOf(P, 'MS_DELETE')]));
    WriteLn(Format('%-14s %10s %10s', ['db bytes', KVOf(L, 'DB_BYTES'), KVOf(P, 'DB_BYTES')]));
    WriteLn('NOT: bu sayilar tek bir kosunun olcumudur; ustunluk iddiasi yoktur.');
    Flush(Output);
  finally
    L.Free;
    P.Free;
  end;

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
