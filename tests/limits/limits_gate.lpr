program limits_gate;
{ v3.37 KALICI REGRESYON KAPISI - SKILL2 §25 / SKILL3 §12 kaynak sinirlari.
  Amac: "sinirsiz" iddiasini kaldirmak. Her kontrol, asimda motorun
  COKMEDIGINI ve veritabaninin BOZULMADIGINI olcer:
    - asiri buyuk SQL cumlesi  -> kontrollu ecLimit
    - asiri buyuk tek deger    -> kontrollu ecLimit
    - asiri buyuk LIMIT        -> kontrollu ecLimit
    - belgelenen sayfa/boy/islem tavanlari makul ve tutarli
  Sinirdan SONRA ayni veritabani normal calismaya devam etmelidir; bu,
  hatanin islemi geri alip dosyayi gecerli biraktiginin kanitidir. }
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbTable,
  VDbSql, VDbErr, VDbTypes, VDbPage, VDbPageStore, VDbExecutor;

var
  GDir, GDb: string;
  GPass, GFail: Integer;

procedure Chk(const AName: string; AOk: Boolean; const ADetail: string = '');
begin
  if AOk then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' ', ADetail);
  end;
end;

procedure Wipe(const D: string);
var
  sr: TSearchRec;
  d2: string;
begin
  d2 := IncludeTrailingPathDelimiter(D);
  ForceDirectories(d2);
  if FindFirst(d2 + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        SysUtils.DeleteFile(d2 + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

var
  Be: TVdbBackendV3;
  Tb: TVTableDb;
  Sq: TVSql;

function IntQ(const ASql: string): Int64;
var
  r: TSqlResult;
begin
  Result := -1;
  r := Sq.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := StrToInt64Def(Trim(r.Rows[0][0]), -1);
end;

{ Bir cumlenin EVDbException + verilen kod ile reddedildigini olcer. }
function RejectedWith(const ASql: string; ACode: TVDbErrorCode;
  out AMsg: string): Boolean;
var
  r: TSqlResult;
begin
  Result := False;
  AMsg := '';
  try
    r := Sq.Exec(ASql);
    AMsg := 'hata yok (kabul edildi)';
  except
    on E: EVDbException do
    begin
      Result := E.ErrorCode = ACode;
      AMsg := VDbErrorName(E.ErrorCode) + ': ' + E.Message;
    end;
    on E: Exception do
      AMsg := E.ClassName + ': ' + E.Message;
  end;
end;

var
  bigSql, bigVal, msg: string;
  i: Integer;
  ok: Boolean;

begin
  GPass := 0;
  GFail := 0;
  GDir := GetTempDir + 'vdb_lim_' + IntToStr(GetProcessID);
  Wipe(GDir);
  GDb := IncludeTrailingPathDelimiter(GDir) + 'lim.odb';
  Be := TVdbBackendV3.Create(GDb);
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(GDir);
  Sq := TVSql.Create(Tb);
  try
    Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    for i := 1 to 5 do
      Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''s' + IntToStr(i) + ''')');
    Chk('L0 hazirlik: 5 satir', IntQ('SELECT COUNT(*) FROM t') = 5);

    { L1: SQL cumlesi boyu - VDB_MAX_SQL_STMT (4 MB) asimi. }
    SetLength(bigSql, VDB_MAX_SQL_STMT + 1);
    for i := 1 to Length(bigSql) do bigSql[i] := ' ';
    bigSql[1] := 'S'; bigSql[2] := 'E'; bigSql[3] := 'L';
    bigSql[4] := 'E'; bigSql[5] := 'C'; bigSql[6] := 'T';
    bigSql[7] := ' '; bigSql[8] := '1';
    ok := RejectedWith(bigSql, ecLimit, msg);
    Chk('L1 asiri buyuk SQL kontrollu ecLimit ile reddedildi', ok,
      'boy=' + IntToStr(Length(bigSql)) + ' ' + msg);
    Chk('L1 reddedilen cumle veri birakmadi', IntQ('SELECT COUNT(*) FROM t') = 5);
    bigSql := '';

    { L2: sinir icindeki normal cumle hala calisir. }
    Chk('L2 sinir sonrasi normal sorgu calisiyor',
      IntQ('SELECT COUNT(*) FROM t WHERE id <= 3') = 3);

    { L3: cok buyuk INSERT cumlesi. NOT: SQL yolunda VDB_MAX_SQL_STMT (4 MB)
      tek deger sinirindan (16 MB) KUCUK oldugu icin burada once cumle
      siniri atesler; VDB_MAX_VALUE API duzeyinde (Put) ayrica gecerlidir.
      Olculen sey: dev bir INSERT motoru cokertmiyor ve veri birakmiyor. }
    SetLength(bigVal, VDB_MAX_VALUE + 16);
    for i := 1 to Length(bigVal) do bigVal[i] := 'x';
    ok := RejectedWith('INSERT INTO t (id, v) VALUES (99, ''' + bigVal + ''')',
      ecLimit, msg);
    Chk('L3 asiri buyuk INSERT kontrollu ecLimit ile reddedildi', ok,
      'boy=' + IntToStr(Length(bigVal)) + ' ' + msg);
    bigVal := '';
    Chk('L3 reddedilen INSERT satir birakmadi',
      IntQ('SELECT COUNT(*) FROM t') = 5);
    Chk('L3 tablo hala sorgulanabilir',
      IntQ('SELECT COUNT(*) FROM t WHERE id = 99') = 0);

    { L4: LIMIT ust siniri - parser 2M ustunu reddeder. }
    ok := RejectedWith('SELECT * FROM t LIMIT ' +
      IntToStr(VDB_MAX_RESULT_ROWS + 1), ecLimit, msg);
    Chk('L4 asiri buyuk LIMIT kontrollu ecLimit ile reddedildi', ok, msg);
    Chk('L4 sinir icindeki LIMIT calisiyor',
      IntQ('SELECT COUNT(*) FROM t LIMIT 10') = 5);

    { L5: belgelenen tavanlar makul ve tutarli. }
    Chk('L5 sayfa tavani tanimli ve 2^24 uzeri',
      VDB_MAX_PAGES >= $00FFFFFF, IntToStr(VDB_MAX_PAGES));
    Chk('L5 veritabani boyu tavani 1 TiB',
      VDB_MAX_DB_BYTES = Int64(1024) * 1024 * 1024 * 1024,
      IntToStr(VDB_MAX_DB_BYTES));
    Chk('L5 islem sayfa tavani pozitif ve DB tavanindan kucuk',
      (VDB_MAX_TXN_PAGES > 0) and
      (Int64(VDB_MAX_TXN_PAGES) * VDB_PAGE_SIZE <= VDB_MAX_DB_BYTES),
      IntToStr(VDB_MAX_TXN_PAGES));
    Chk('L5 onbellek tavani 65536 sayfa (256 MB)',
      VDB_MAX_POOL * VDB_PAGE_SIZE = 256 * 1024 * 1024,
      IntToStr(VDB_MAX_POOL));
    Chk('L5 tek SQL cumlesi tavani 4 MB',
      VDB_MAX_SQL_STMT = 4 * 1024 * 1024, IntToStr(VDB_MAX_SQL_STMT));
    Chk('L5 tek deger tavani 16 MB',
      VDB_MAX_VALUE = 16 * 1024 * 1024, IntToStr(VDB_MAX_VALUE));
    Chk('L5 sonuc satiri tavani 2M',
      VDB_MAX_RESULT_ROWS = 2000000, IntToStr(VDB_MAX_RESULT_ROWS));

    { L6: sinirlardan sonra kapanis + yeniden acilis temiz olmali. }
    FreeAndNil(Sq);
    FreeAndNil(Tb);
    Be := nil;
    Chk('L6 sinir denemelerinden sonra yalniz .odb kalir',
      (not FileExists(GDb + '.wal')) and (not FileExists(GDb + '.gen')),
      'wal=' + BoolToStr(FileExists(GDb + '.wal'), True) +
      ' gen=' + BoolToStr(FileExists(GDb + '.gen'), True));

    Be := TVdbBackendV3.Create(GDb);
    Tb := TVTableDb.CreateBackend(Be);
    Tb.Open(GDir);
    Sq := TVSql.Create(Tb);
    Chk('L6 yeniden acilista veri bozulmadi',
      IntQ('SELECT COUNT(*) FROM t') = 5,
      'satir=' + IntToStr(IntQ('SELECT COUNT(*) FROM t')));
  finally
    FreeAndNil(Sq);
    FreeAndNil(Tb);
    Be := nil;
  end;
  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
