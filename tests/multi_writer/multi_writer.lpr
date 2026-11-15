program multi_writer;
{ v3.36 KALICI REGRESYON KAPISI - cok yazarli tek dosya.
  Burada olculen uc ayri onayli-commit kaybi sinifi vardir:
    A) TxnMark bayatligi: tazeleme sirasinda InstallPage, BASKA oturumun
       onayli sayfalarini "benim degil" diye siliyordu (olcum: 12 satirdan 5'i).
    B) `.gen` referans sayaci yokken ikinci oturumun kapanisi `.gen`i
       siliyordu; iki oturum farkli nesil kimligi tasiyip birbirinin
       sayfalarini eziyordu.
    C) `.wal` silme + bayat ekleme konumu: ikinci oturum kapanirken BOS
       `.wal`i siliyor, birinci oturumun ACIK tutamagi yetim kaliyordu;
       ayrica FAtEnd bayat konumu yuzunden yeni commit eski kaydin uzerine
       yazabiliyordu. Ikisi de onayli commit kaybi uretir.
  Her kontrol bagimsizdir; biri duserse digerleri yine olculur. }
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbTable,
  VDbSql, VDbErr;

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

function FileLenOf(const APath: string): Int64;
var
  fs: TFileStream;
begin
  Result := 0;
  if not FileExists(APath) then Exit;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := fs.Size;
  finally
    fs.Free;
  end;
end;

function CountQ(S: TVSql; const ASql: string): Integer;
var
  r: TSqlResult;
begin
  Result := -1;
  r := S.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := StrToIntDef(Trim(r.Rows[0][0]), -1);
end;

{ WAL govdesindeki commit LSN'lerini sirayla okur. Bozuk/kesik kuyrukta
  durur ve o ana kadar gorulenleri dondurur (torn tail = uyari, hata degil). }
function WalLsns(const APath: string; out ACount: Integer;
  out AIncreasing: Boolean): string;
var
  fs: TFileStream;
  hdr: array[0..19] of Byte;
  magic, lsn, payLen: LongWord;
  pos: Int64;
  last: LongWord;
  sawAny: Boolean;
begin
  Result := '';
  ACount := 0;
  AIncreasing := True;
  last := 0;
  sawAny := False;
  if not FileExists(APath) then Exit;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    pos := 4096;
    while pos + 20 <= fs.Size do
    begin
      fs.Position := pos;
      fs.ReadBuffer(hdr, 20);
      Move(hdr[0], magic, 4);
      Move(hdr[4], lsn, 4);
      Move(hdr[8], payLen, 4);
      if (magic <> $31574656) and (magic <> $31435746) then Break;
      { LSN artis olcusu YALNIZ commit kayitlari uzerinden yapilir: bir
        commit'in cerceve ve commit kayitlari AYNI LSN'i tasir (tasarim). }
      if magic = $31435746 then
      begin
        if sawAny and (lsn <= last) then
          AIncreasing := False;
        last := lsn;
        sawAny := True;
        Inc(ACount);
        Result := Result + IntToStr(lsn) + ' ';
      end;
      Inc(pos, 20 + Int64(payLen));
      if payLen > 65536 then Break;
    end;
  finally
    fs.Free;
  end;
end;

{ A) + C) Iki oturum sirayla commit eder; ilk oturumun onbellegi bayattir.
  Tum satirlar kalici olmali, WAL LSN'leri kesin artmali, ikinci oturum
  kapanirken `.wal` ve `.gen` ilk oturumun altindan cekilmemeli. }
procedure CaseTwoWriters;
var
  A, B: IVdbBackend;
  TbA, TbB: TVTableDb;
  SqA, SqB: TVSql;
  i, ok: Integer;
  walAfterBClose, genAfterBClose: Int64;
  lsnCount: Integer;
  lsnInc: Boolean;
  lsnText: string;
begin
  GDir := GetTempDir + 'vdb_mw_a_' + IntToStr(GetProcessID);
  Wipe(GDir);
  GDb := IncludeTrailingPathDelimiter(GDir) + 'mw.odb';
  A := TVdbBackendV3.Create(GDb);
  TbA := TVTableDb.CreateBackend(A);
  TbA.Open(GDir);
  SqA := TVSql.Create(TbA);
  SqA.Exec('CREATE TABLE tx (id INTEGER PRIMARY KEY, v TEXT)');
  for i := 1 to 15 do
  begin
    SqA.Exec('BEGIN');
    SqA.Exec('INSERT INTO tx (id, v) VALUES (' + IntToStr(i) + ', ''t'')');
    SqA.Exec('COMMIT');
  end;
  (A as TVdbBackendV3).Engine.Checkpoint(True);
  Chk('MW1 hazirlik: WAL var', FileLenOf(GDb + '.wal') >= 4096,
    'wal=' + IntToStr(FileLenOf(GDb + '.wal')));

  B := nil;
  TbB := nil;
  SqB := nil;
  VdbOpen(GDb, B, False, False);
  TbB := TVTableDb.CreateBackend(B);
  TbB.Open(GDir);
  SqB := TVSql.Create(TbB);

  ok := 0;
  for i := 1 to 12 do
  begin
    try
      if Odd(i) then
      begin
        SqA.Exec('BEGIN');
        SqA.Exec('INSERT INTO tx (id, v) VALUES (' + IntToStr(20000 + i) +
          ', ''p'')');
        SqA.Exec('COMMIT');
      end
      else
      begin
        SqB.Exec('BEGIN');
        SqB.Exec('INSERT INTO tx (id, v) VALUES (' + IntToStr(20000 + i) +
          ', ''q'')');
        SqB.Exec('COMMIT');
      end;
      Inc(ok);
    except
      on E: Exception do
        WriteLn('BILGI MW1 i=', i, ' hata: ', E.ClassName, ': ', E.Message);
    end;
  end;
  Chk('MW1 iki oturum da commit etti', ok = 12, IntToStr(ok) + '/12');

  lsnText := WalLsns(GDb + '.wal', lsnCount, lsnInc);
  Chk('MW1 WAL LSN kesin artiyor', lsnInc and (lsnCount >= 12),
    'commit=' + IntToStr(lsnCount) + ' lsn=[' + Trim(lsnText) + ']');

  genAfterBClose := 0;
  WalAfterBClose := FileLenOf(GDb + '.wal');
  FreeAndNil(SqB);
  FreeAndNil(TbB);
  B := nil;
  genAfterBClose := FileLenOf(GDb + '.gen');
  Chk('MW2 ikinci oturum kapaninca .wal korunur',
    FileLenOf(GDb + '.wal') > 0,
    'once=' + IntToStr(walAfterBClose) + ' sonra=' +
    IntToStr(FileLenOf(GDb + '.wal')));
  Chk('MW2 ikinci oturum kapaninca .gen korunur', genAfterBClose > 0,
    'gen=' + IntToStr(genAfterBClose));

  { A hala acik ve bayat: kendi commit'leri (6 'p' satiri) korunmali;
    baska oturumun satirlarini gormesi BEKLENMEZ (anlik gorunum). }
  ok := CountQ(SqA, 'SELECT COUNT(*) FROM tx WHERE v = ''p''');
  Chk('MW3 birinci oturum kendi 6 satirini korur', ok = 6,
    'satir=' + IntToStr(ok) + '/6');

  FreeAndNil(SqA);
  FreeAndNil(TbA);
  A := nil;
  Chk('MW4 temiz kapanistan sonra yalniz .odb kalir',
    (not FileExists(GDb + '.wal')) and (not FileExists(GDb + '.gen')),
    'wal=' + IntToStr(FileLenOf(GDb + '.wal')) + ' gen=' +
    IntToStr(FileLenOf(GDb + '.gen')));

  VdbOpen(GDb, A, False, False);
  TbA := TVTableDb.CreateBackend(A);
  TbA.Open(GDir);
  SqA := TVSql.Create(TbA);
  ok := CountQ(SqA, 'SELECT COUNT(*) FROM tx WHERE id >= 20000');
  Chk('MW4 taze oturum iki oturumun TUM satirlarini gorur', ok = 12,
    'satir=' + IntToStr(ok) + '/12');
  FreeAndNil(SqA);
  FreeAndNil(TbA);
  A := nil;
end;

{ C2) Yedek/geri yukleme iki oturumun satirlarini da tasimali. }
procedure CaseBackup;
var
  A, B: IVdbBackend;
  AC: TVdbBackendV3;
  TbA, TbB: TVTableDb;
  SqA, SqB: TVSql;
  i, ok: Integer;
  bk, rep: string;
begin
  GDir := GetTempDir + 'vdb_mw_b_' + IntToStr(GetProcessID);
  Wipe(GDir);
  GDb := IncludeTrailingPathDelimiter(GDir) + 'mw.odb';
  AC := TVdbBackendV3.Create(GDb);
  A := AC;
  TbA := TVTableDb.CreateBackend(A);
  TbA.Open(GDir);
  SqA := TVSql.Create(TbA);
  SqA.Exec('CREATE TABLE tx (id INTEGER PRIMARY KEY, v TEXT)');
  for i := 1 to 10 do
  begin
    SqA.Exec('BEGIN');
    SqA.Exec('INSERT INTO tx (id, v) VALUES (' + IntToStr(i) + ', ''t'')');
    SqA.Exec('COMMIT');
  end;
  AC.Engine.Checkpoint(True);

  B := nil;
  TbB := nil;
  SqB := nil;
  VdbOpen(GDb, B, False, False);
  TbB := TVTableDb.CreateBackend(B);
  TbB.Open(GDir);
  SqB := TVSql.Create(TbB);
  for i := 1 to 8 do
  begin
    SqB.Exec('BEGIN');
    SqB.Exec('INSERT INTO tx (id, v) VALUES (' + IntToStr(20000 + i) +
      ', ''q'')');
    SqB.Exec('COMMIT');
  end;

  { Ikinci oturum KAPANIRKEN birinci hala acik: yan dosyalar korunmali. }
  FreeAndNil(SqB);
  FreeAndNil(TbB);
  B := nil;

  { A'yi kapat: kapanis checkpoint'i B'nin commit'lerini de .odb'ye indirir.
    Sonra taze oturumla 18 satirin KALICI oldugunu dogrula ve yedegi al. }
  FreeAndNil(SqA);
  FreeAndNil(TbA);
  A := nil;
  AC := nil;

  VdbOpen(GDb, A, False, False);
  AC := A as TVdbBackendV3;
  TbA := TVTableDb.CreateBackend(A);
  TbA.Open(GDir);
  SqA := TVSql.Create(TbA);
  ok := CountQ(SqA, 'SELECT COUNT(*) FROM tx');
  Chk('MW5 yedek oncesi iki oturumun 18 satiri kalici', ok = 18,
    'satir=' + IntToStr(ok) + '/18');

  bk := IncludeTrailingPathDelimiter(GDir) + 'yedek.odb';
  SysUtils.DeleteFile(bk);
  try
    AC.BackupTo(bk);
    Chk('MW5 yedek alindi', FileExists(bk),
      'bayt=' + IntToStr(FileLenOf(bk)));
    Chk('MW5 yedek dogrulandi', AC.VerifyBackup(bk, rep), '');
  except
    on E: Exception do
      Chk('MW5 yedek alindi', False, E.ClassName + ': ' + E.Message);
  end;

  FreeAndNil(SqA);
  FreeAndNil(TbA);
  A := nil;
  AC := nil;

  { Geri yukleme: ayni yola doner; taze oturum 18 satir gormeli. }
  VdbOpen(GDb, A, False, False);
  try
    A.RestoreFrom(bk);
  except
    on E: Exception do
      WriteLn('BILGI MW6 geri yukleme hatasi: ', E.ClassName, ': ', E.Message);
  end;
  A := nil;
  VdbOpen(GDb, A, False, False);
  TbA := TVTableDb.CreateBackend(A);
  TbA.Open(GDir);
  SqA := TVSql.Create(TbA);
  ok := CountQ(SqA, 'SELECT COUNT(*) FROM tx');
  Chk('MW6 geri yukleme iki oturumun satirlarini korur', ok = 18,
    'satir=' + IntToStr(ok) + '/18');
  FreeAndNil(SqA);
  FreeAndNil(TbA);
  A := nil;
end;

begin
  GPass := 0;
  GFail := 0;
  try
    CaseTwoWriters;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL MW1 beklenmeyen hata: ', E.ClassName, ': ', E.Message);
    end;
  end;
  try
    CaseBackup;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL MW5 beklenmeyen hata: ', E.ClassName, ': ', E.Message);
    end;
  end;
  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
