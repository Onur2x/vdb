program sql_memory;
{ v3.55 (Sprint F) KALICI REGRESYON KAPISI - SKILL3 8.2 / 8.4 / 8.5.

  Amac: yurutucunun SINIR ve SAYISAL UC davranisini dondurmak. Her kontrol
  gercek bir hatayi (veya dogru davranisi) olcer; hicbir kontrol "gevsetilmis"
  bir esik kullanmaz:

    8.2 LIMIT/OFFSET  : LIMIT 0, negatif LIMIT/OFFSET, asiri OFFSET,
                        LIMIT+OFFSET tasmasi, ORDER BY+LIMIT'in tam siralamanin
                        ON EKI olmasi (ASC/DESC/cok anahtar/NULL).
    8.4 recursive CTE : derinlik siniri SESSIZ KESME degil kontrollu ecLimit,
                        iptal (QueryTimeoutMs + CancelQuery).
    8.5 aritmetik     : CAST aralik tasmasi, INT64 literal siniri,
                        +,-,* tasmasi, sifira bolme, ABS.

  On-kontrol kaniti (duzeltme oncesi, `git archive HEAD` uzerinde):
    CAST('9999999999999999999999' AS INTEGER) -> 1864712049423024127 (cop)
    CAST('999999999999999999999999' AS INTEGER) -> 2003764205206896639 (cop)
    ABS(-9223372036854775807 - 1) -> 9.22337203685478E18 (float, tip kaybi)
    WITH r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r) SELECT n FROM r
      -> 100001 satir HATA YOK (sessiz yanlis sonuc)
  Ayrintili on-kontrol ciktisi: sqlmem_head / sqlmem2_head. }
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

{ 0. kolonun degerlerini '|' ile birlestirir; satir sayisini da verir. }
function Col0(const ASql: string; out AN: Integer): string;
var
  r: TSqlResult;
  i: Integer;
begin
  Result := '';
  AN := 0;
  r := Sq.Exec(ASql);
  AN := Length(r.Rows);
  for i := 0 to High(r.Rows) do
  begin
    if i > 0 then Result := Result + '|';
    if Length(r.Rows[i]) > 0 then Result := Result + r.Rows[i][0];
  end;
end;

function Scalar(const ASql: string): string;
var
  r: TSqlResult;
begin
  Result := '';
  r := Sq.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := r.Rows[0][0];
end;

function RejectedWith(const ASql: string; ACode: TVDbErrorCode;
  out AMsg: string): Boolean;
var
  r: TSqlResult;
begin
  Result := False;
  AMsg := '';
  try
    r := Sq.Exec(ASql);
    AMsg := 'hata yok (kabul edildi), satir=' + IntToStr(Length(r.Rows));
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

function Prefix(OfList, Full: string): Boolean;
begin
  Result := (OfList = '') or (Copy(Full, 1, Length(OfList)) = OfList);
end;

var
  i, n, n2: Integer;
  fullAsc, fullDesc, fullMulti, part: string;
  msg: string;
  ok: Boolean;

begin
  GPass := 0;
  GFail := 0;
  GDir := GetTempDir + 'vdb_sqlmem_' + IntToStr(GetProcessID);
  Wipe(GDir);
  GDb := IncludeTrailingPathDelimiter(GDir) + 'sm.odb';
  Be := TVdbBackendV3.Create(GDb);
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(GDir);
  Sq := TVSql.Create(Tb);
  try
    { v benzersiz; id=2 satirinda v NULL. NULL siralama konumu sabit
      olcuttur (ASC'te basta, DESC'te sonda). }
    Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    Sq.Exec('INSERT INTO t (id, v) VALUES (1, ''b'')');
    Sq.Exec('INSERT INTO t (id, v) VALUES (2, NULL)');
    Sq.Exec('INSERT INTO t (id, v) VALUES (3, ''a'')');
    Sq.Exec('INSERT INTO t (id, v) VALUES (4, ''c'')');
    Sq.Exec('INSERT INTO t (id, v) VALUES (5, ''d'')');
    Sq.Exec('INSERT INTO t (id, v) VALUES (6, ''e'')');
    Chk('SM0 hazirlik: 6 satir', Scalar('SELECT COUNT(*) FROM t') = '6');

    { --- 8.2 ORDER BY + LIMIT/OFFSET: tam siralamanin oneki olmali --- }
    fullAsc := Col0('SELECT id FROM t ORDER BY v', n);
    Chk('SM1 ASC tam siralama 6 satir', n = 6, fullAsc);
    Chk('SM1 ASC ilk satir NULL (id=2)', fullAsc = '2|3|1|4|5|6', fullAsc);

    fullDesc := Col0('SELECT id FROM t ORDER BY v DESC', n);
    Chk('SM2 DESC tam siralama 6 satir', n = 6, fullDesc);
    Chk('SM2 DESC NULL sonda (id=2)', fullDesc = '6|5|4|1|3|2', fullDesc);

    part := Col0('SELECT id FROM t ORDER BY v LIMIT 2', n);
    Chk('SM3 ASC LIMIT 2 tam siralamanin oneki', (n = 2) and Prefix(part, fullAsc),
      part + ' / ' + fullAsc);

    part := Col0('SELECT id FROM t ORDER BY v DESC LIMIT 2', n);
    Chk('SM4 DESC LIMIT 2 tam siralamanin oneki', (n = 2) and Prefix(part, fullDesc),
      part + ' / ' + fullDesc);

    part := Col0('SELECT id FROM t ORDER BY v OFFSET 2 LIMIT 2', n);
    Chk('SM5 OFFSET 2 LIMIT 2 dilimi dogru', (n = 2) and (part = '1|4'),
      part + ' / beklenen 1|4');

    part := Col0('SELECT id FROM t ORDER BY v OFFSET 5 LIMIT 2', n);
    Chk('SM6 OFFSET 5 LIMIT 2 son satiri verir', (n = 1) and (part = '6'), part);

    fullMulti := Col0('SELECT id FROM t ORDER BY v, id DESC', n);
    part := Col0('SELECT id FROM t ORDER BY v, id DESC LIMIT 3', n);
    Chk('SM7 cok anahtarli ORDER BY LIMIT onek',
      (n = 3) and Prefix(part, fullMulti), part + ' / ' + fullMulti);

    { --- 8.2 LIMIT/OFFSET sinirlari --- }
    part := Col0('SELECT id FROM t ORDER BY v LIMIT 0', n);
    Chk('SM8 LIMIT 0 sifir satir dondurur', n = 0, 'n=' + IntToStr(n));
    Chk('SM8 LIMIT 0 toplu sonucu da bosaltir',
      Col0('SELECT COUNT(*) FROM t LIMIT 0', n) = '', 'n=' + IntToStr(n));

    ok := RejectedWith('SELECT id FROM t LIMIT -1', ecSyntaxError, msg);
    Chk('SM9 negatif LIMIT reddedilir', ok, msg);
    ok := RejectedWith('SELECT id FROM t OFFSET -1', ecSyntaxError, msg);
    Chk('SM9 negatif OFFSET reddedilir', ok, msg);
    ok := RejectedWith('SELECT id FROM t LIMIT 3 OFFSET -2', ecSyntaxError, msg);
    Chk('SM9 LIMIT 3 OFFSET -2 reddedilir', ok, msg);

    part := Col0('SELECT id FROM t ORDER BY v OFFSET 1000000000', n);
    Chk('SM10 asiri OFFSET bos sonuc (cokme yok)', n = 0, 'n=' + IntToStr(n));
    part := Col0('SELECT id FROM t ORDER BY v OFFSET 2147483647 LIMIT 2', n);
    Chk('SM10 OFFSET 2147483647 bos sonuc', n = 0, 'n=' + IntToStr(n));
    ok := RejectedWith('SELECT id FROM t LIMIT ' +
      IntToStr(VDB_MAX_RESULT_ROWS + 1), ecLimit, msg);
    Chk('SM11 LIMIT+1 sonuc tavani kontrollu ecLimit', ok, msg);
    ok := RejectedWith('SELECT id FROM t LIMIT 2147483647 OFFSET 2147483647',
      ecLimit, msg);
    Chk('SM11 LIMIT+OFFSET tasmasi kontrollu ecLimit', ok, msg);

    { --- 8.5 uc degerli mantik (LIMIT'ten bagimsiz, ayni kapi) --- }
    Chk('SM12 v = NULL satir getirmez', Scalar('SELECT COUNT(*) FROM t WHERE v = NULL') = '0');
    Chk('SM12 v IS NULL bir satir', Scalar('SELECT COUNT(*) FROM t WHERE v IS NULL') = '1');
    Chk('SM12 NOT (v = ''a'') NULL''u dislar',
      Scalar('SELECT COUNT(*) FROM t WHERE NOT (v = ''a'')') = '4');
    Chk('SM13 IN (''a'', NULL) yalniz a eslesir',
      Scalar('SELECT COUNT(*) FROM t WHERE v IN (''a'', NULL)') = '1');
    Chk('SM13 NOT IN (''a'', NULL) bos kume (UNKNOWN)',
      Scalar('SELECT COUNT(*) FROM t WHERE v NOT IN (''a'', NULL)') = '0');
    Chk('SM13 BETWEEN NULL ile karsilastirma UNKNOWN',
      Scalar('SELECT COUNT(*) FROM t WHERE v BETWEEN NULL AND ''c''') = '0');
    Chk('SM14 COUNT(kolon) NULL''u saymaz',
      Scalar('SELECT COUNT(v) FROM t') = '5');
    Chk('SM14 COUNT(*) NULL''u sayar', Scalar('SELECT COUNT(*) FROM t') = '6');
    Chk('SM14 AVG', Scalar('SELECT AVG(id) FROM t') = '3.5');

    { --- 8.5 CAST / tasma --- }
    ok := RejectedWith('SELECT CAST(''9999999999999999999999'' AS INTEGER)',
      ecTypeMismatch, msg);
    Chk('SM15 CAST asiri 22 hane reddedilir (cop deger YOK)', ok, msg);
    ok := RejectedWith('SELECT CAST(''999999999999999999999999'' AS INTEGER)',
      ecTypeMismatch, msg);
    Chk('SM15 CAST asiri 24 hane reddedilir', ok, msg);
    ok := RejectedWith('SELECT CAST(''abc'' AS INTEGER)', ecTypeMismatch, msg);
    Chk('SM15 CAST metin reddedilir', ok, msg);
    Chk('SM16 CAST Int64 max tam deger',
      Scalar('SELECT CAST(''9223372036854775807'' AS INTEGER)') = '9223372036854775807');
    Chk('SM16 CAST Int64 min tam deger',
      Scalar('SELECT CAST(''-9223372036854775808'' AS INTEGER)') = '-9223372036854775808');

    Chk('SM17 -9223372036854775808 literal tam sayi',
      Scalar('SELECT -9223372036854775808') = '-9223372036854775808',
      Scalar('SELECT -9223372036854775808'));

    ok := RejectedWith('SELECT 9223372036854775807 + 1', ecMathError, msg);
    Chk('SM18 Int64 toplama tasmasi', ok, msg);
    ok := RejectedWith('SELECT 4611686018427387904 * 4', ecMathError, msg);
    Chk('SM18 Int64 carpma tasmasi', ok, msg);
    ok := RejectedWith('SELECT 1/0', ecMathError, msg);
    Chk('SM19 sifira bolme', ok, msg);
    ok := RejectedWith('SELECT 1.0/0.0', ecMathError, msg);
    Chk('SM19 float sifira bolme', ok, msg);

    { --- 8.5 ABS: once tam sayi, tasmada hata --- }
    Chk('SM20 ABS buyuk tam sayi hassasiyet kaybi YOK',
      Scalar('SELECT ABS(9223372036854775806)') = '9223372036854775806',
      Scalar('SELECT ABS(9223372036854775806)'));
    ok := RejectedWith('SELECT ABS(-9223372036854775807 - 1)', ecMathError, msg);
    Chk('SM20 ABS(Low(Int64)) kontrollu ecMathError', ok, msg);
    Chk('SM20 ABS(negatif)', Scalar('SELECT ABS(-7)') = '7');

    { Tekli eksi de tasmalidir: sutun degeri Low(Int64) iken -v sarmamali. }
    Sq.Exec('CREATE TABLE n (v INTEGER)');
    Sq.Exec('INSERT INTO n (v) VALUES (-9223372036854775808)');
    Chk('SM26 sutundaki Int64 min degeri korunur',
      Scalar('SELECT v FROM n') = '-9223372036854775808',
      Scalar('SELECT v FROM n'));
    ok := RejectedWith('SELECT -v FROM n', ecMathError, msg);
    Chk('SM26 tekli eksi Int64 min uzerinde sessiz sarmaz', ok, msg);

    { --- 8.4 recursive CTE sinirlari --- }
    Chk('SM21 ozyinelemeli CTE 100 satir',
      Scalar('WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL ' +
             'SELECT n+1 FROM r WHERE n < 100) SELECT COUNT(*) FROM r') = '100');
    Chk('SM21 ozyinelemeli CTE MIN/MAX dogru',
      (Scalar('WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL ' +
              'SELECT n+1 FROM r WHERE n < 100) SELECT MIN(n) FROM r') = '1') and
      (Scalar('WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL ' +
              'SELECT n+1 FROM r WHERE n < 100) SELECT MAX(n) FROM r') = '100'));

    { Derinlik siniri asilirsa sonuc KISMI olur; sessiz kesme YASAK. }
    ok := RejectedWith('WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL ' +
      'SELECT n+1 FROM r) SELECT COUNT(*) FROM r', ecLimit, msg);
    Chk('SM22 sonsuz ozyineleme sessiz kesmez, ecLimit verir', ok, msg);
    Chk('SM22 test sonrasi tablo saglam',
      Scalar('SELECT COUNT(*) FROM t') = '6');

    { --- 8.4 iptal: zaman asimi ozyineleme dongusunde de islemeli --- }
    Sq.QueryTimeoutMs := 60;
    ok := False;
    msg := '';
    try
      Sq.Exec('WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL ' +
              'SELECT n+1 FROM r WHERE n < 100000) SELECT COUNT(*) FROM r');
      msg := 'zaman asimi YOK (iptal edilemiyor)';
    except
      on E: EVDbException do
      begin
        ok := E.ErrorCode = ecQueryTimeout;
        msg := VDbErrorName(E.ErrorCode) + ': ' + E.Message;
      end;
      on E: Exception do
        msg := E.ClassName + ': ' + E.Message;
    end;
    Sq.QueryTimeoutMs := 0;
    Chk('SM23 derin ozyineleme zaman asimina uyar (iptal edilebilir)', ok, msg);
    Chk('SM23 zaman asimi sonrasi tablo saglam',
      Scalar('SELECT COUNT(*) FROM t') = '6');

    { Bekleyen iptal istegi cumle basinda onurlandirilir. }
    Sq.CancelQuery;
    ok := False;
    msg := '';
    try
      Sq.Exec('SELECT COUNT(*) FROM t');
      msg := 'iptal yok sayildi';
    except
      on E: EVDbException do
      begin
        ok := E.ErrorCode = ecCancelled;
        msg := VDbErrorName(E.ErrorCode) + ': ' + E.Message;
      end;
      on E: Exception do
        msg := E.ClassName + ': ' + E.Message;
    end;
    Sq.ResetCancel;
    Chk('SM24 CancelQuery ecCancelled verir', ok, msg);
    Chk('SM24 iptal sonrasi ayni oturum normal calisir',
      Scalar('SELECT COUNT(*) FROM t') = '6');

    { --- kapanis / yeniden acilis --- }
    FreeAndNil(Sq);
    FreeAndNil(Tb);
    Be := nil;
    Chk('SM25 kapanista yalniz .odb kalir',
      (not FileExists(GDb + '.wal')) and (not FileExists(GDb + '.gen')),
      'wal=' + BoolToStr(FileExists(GDb + '.wal'), True) +
      ' gen=' + BoolToStr(FileExists(GDb + '.gen'), True));
    Be := TVdbBackendV3.Create(GDb);
    Tb := TVTableDb.CreateBackend(Be);
    Tb.Open(GDir);
    Sq := TVSql.Create(Tb);
    Chk('SM25 yeniden acilista veri bozulmadi',
      Scalar('SELECT COUNT(*) FROM t') = '6',
      'satir=' + Scalar('SELECT COUNT(*) FROM t'));
    Chk('SM25 yeniden acilista siralama ayni',
      Col0('SELECT id FROM t ORDER BY v', n2) = fullAsc);
  finally
    FreeAndNil(Sq);
    FreeAndNil(Tb);
    Be := nil;
  end;
  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
