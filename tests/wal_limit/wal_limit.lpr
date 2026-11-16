program wal_limit;
{ v3.44 KALICI REGRESYON KAPISI - SKILL3 §6.3 WAL boy siniri.
  Amac: WAL icin SERT bayt tavaninin (WalMaxBytes) NE YAPTIGINI olcmek.
  Beklenen:
    - tavan altindaki yazimlar normal calisir; tavan doldugunda
      `MaybeCheckpoint` senkron checkpoint yapar ve WAL budanir, yani
      siradan calismada tavan yuzunden sahte bir ret OLMAZ,
    - tavani asan TEK bir islemin commit'i KONTROLLU `ecLimit` ile
      reddedilir; WAL'e commit kaydi yazilmaz,
    - reddedilen commit hayalet satir birakmaz, onceki onayli satirlar
      ayni oturumda OKUNUR ve degerleri bozulmaz,
    - reddedilen commit'ten sonra WAL tamponu temizlenir (Wal.Bytes
      tavana geri doner); yani sinir "kacar" sekilde asilmaz,
    - tavan kapatilinca (0) ayni buyuk islem basariyla commit edilir,
      yani reddin nedeni gercekten tavandir, baska bir ariza degil,
    - tavan yeniden acilip checkpoint ile yer bosaltilinca yazim devam eder,
    - yeniden acilista TUM onayli satirlar durur ve VERIFY temizdir.

  Tavan testte KUCUK (300 KB) secilir; boylece 64 MB'lik varsayilanla
  ugrasmadan ayni kod yolu deterministik olarak surulur. Bu bir test
  kolayligidir, olculen sey degil: kontroller tavanin kendisine gore
  yapilir, sabit bir bayt sayisina gore degil.

  Derleme: fpc. Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbBackendApi, VDbBackendV3,
  VDbPageEngine, VDbTable, VDbSql, VDbErr;

const
  { Tavanin ALTINDA kalan siradan yazimlar. }
  BASE_ROWS = 100;
  { Tavanin USTUNE cikan tek islem. Deger boyu bilincli olarak buyuk:
    her satir kendi yaprak sayfasini kirletir, yani WAL cerceve sayisi
    satir sayisiyla birlikte buyur ve tavan gercekten asilir. }
  TXN_ROWS = 250;
  VAL_LEN = 6000;
  { Kucuk tavan: ~73 cerceve. }
  WAL_CAP = 300000;
  { Tavan kapatildiktan sonra eklenecek satirlar. }
  AFTER_ROWS = 5;

var
  GPass, GFail: Integer;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' ', ADetail);
  end;
  Flush(Output);
end;

procedure WipeDir(const D: string);
var
  sr: TSearchRec;
begin
  ForceDirectories(D);
  if FindFirst(IncludeTrailingPathDelimiter(D) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        SysUtils.DeleteFile(IncludeTrailingPathDelimiter(D) + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

{ Deterministik, tekrar uretilebilir deger. }
function ValOf(AId: Integer): string;
var
  i: Integer;
begin
  SetLength(Result, VAL_LEN);
  for i := 1 to VAL_LEN do
    Result[i] := Chr(Ord('a') + ((AId + i) mod 26));
  Result := 'w' + IntToStr(AId) + ':' + Result;
end;

function QInt(Sq: TVSql; const ASql: string): Int64;
var
  r: TSqlResult;
begin
  Result := -1;
  r := Sq.Exec(ASql);
  if (Length(r.Rows) = 1) and (Length(r.Rows[0]) >= 1) then
    Result := StrToInt64Def(Trim(r.Rows[0][0]), -1);
end;

procedure Ins(Sq: TVSql; AId: Integer);
begin
  Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(AId) + ', ''' +
    ValOf(AId) + ''')');
end;

{ Cumleyi calistirir; kontrollu hata olursa hata ADINI ve METNINI dondurur.
  Beklenmeyen sinif da adiyla dondurulur (test bunu ayirt eder). }
function TryExecCode(Sq: TVSql; const ASql: string;
  out AMsg: string): string;
begin
  Result := '';
  AMsg := '';
  try
    Sq.Exec(ASql);
  except
    on E: EVDbException do
    begin
      Result := VDbErrorName(E.ErrorCode);
      AMsg := E.Message;
    end;
    on E: Exception do
    begin
      Result := E.ClassName;
      AMsg := E.Message;
    end;
  end;
end;

{ Acar, satir sayisini ve HER satirin degerini dogrular.
  rc: -1 ok, -2 uyusmazlik, -3 beklenmeyen istisna. }
function ReopenScan(const ADir, ADb: string; AExpect: Integer;
  out ADetail: string): Integer;
var
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  r: TSqlResult;
  i, id: Integer;
begin
  Result := -1;
  ADetail := '';
  BeC := nil;
  Be := nil;
  try
    try
      BeC := TVdbBackendV3.Create(ADb, False, 512, 4000);
      Be := BeC;
      Tb := TVTableDb.CreateBackend(Be);
      try
        Tb.Open(ADir);
        Sq := TVSql.Create(Tb);
        try
          r := Sq.Exec('SELECT id, v FROM t ORDER BY id');
          if Length(r.Rows) <> AExpect then
          begin
            ADetail := 'satir=' + IntToStr(Length(r.Rows)) +
              ' beklenen=' + IntToStr(AExpect);
            Result := -2;
            Exit;
          end;
          for i := 0 to Length(r.Rows) - 1 do
          begin
            id := StrToIntDef(Trim(r.Rows[i][0]), -1);
            if (id < 1) or (Trim(r.Rows[i][1]) <> ValOf(id)) then
            begin
              ADetail := 'bozuk satir id=' + IntToStr(id);
              Result := -2;
              Exit;
            end;
          end;
          Result := -1;
        finally
          FreeAndNil(Sq);
        end;
      finally
        FreeAndNil(Tb);
      end;
    except
      on E: Exception do
      begin
        ADetail := E.ClassName + ': ' + E.Message;
        Result := -3;
      end;
    end;
  finally
    Be := nil;
    BeC := nil;
  end;
end;

function VerifyDb(const APath: string; out ARep: string): Boolean;
var
  BeC: TVdbBackendV3;
begin
  ARep := '';
  Result := False;
  BeC := nil;
  try
    try
      BeC := TVdbBackendV3.CreateReadOnly(APath);
      Result := BeC.Engine.VerifyEx(vmFull, True, ARep);
    except
      on E: Exception do
      begin
        ARep := E.ClassName + ': ' + E.Message;
        Result := False;
      end;
    end;
  finally
    BeC.Free;
  end;
end;

{ Ayni oturumda tum satirlari okuyup degerleri dogrular. }
function LiveScan(Sq: TVSql; AExpect: Integer; out ADetail: string): Boolean;
var
  r: TSqlResult;
  i, id: Integer;
begin
  Result := False;
  ADetail := '';
  r := Sq.Exec('SELECT id, v FROM t ORDER BY id');
  if Length(r.Rows) <> AExpect then
  begin
    ADetail := 'satir=' + IntToStr(Length(r.Rows)) +
      ' beklenen=' + IntToStr(AExpect);
    Exit;
  end;
  for i := 0 to Length(r.Rows) - 1 do
  begin
    id := StrToIntDef(Trim(r.Rows[i][0]), -1);
    if (id < 1) or (Trim(r.Rows[i][1]) <> ValOf(id)) then
    begin
      ADetail := 'bozuk satir id=' + IntToStr(id);
      Exit;
    end;
  end;
  Result := True;
end;

var
  Dir, Db: string;
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  i, rc: Integer;
  expected: Int64;
  detail, rep, msg, code: string;
  walBefore, walAfter, cap, ck0, ck1: Int64;

begin
  GPass := 0;
  GFail := 0;
  Dir := IncludeTrailingPathDelimiter(
    ExtractFilePath(ParamStr(0)) + 'tmp/wal_limit');
  WipeDir(Dir);
  Db := IncludeTrailingPathDelimiter(Dir) + 'wal_limit.odb';
  BeC := nil;
  Be := nil;

  try
    BeC := TVdbBackendV3.Create(Db, True, 512, 4000);
    Be := BeC;
    Tb := TVTableDb.CreateBackend(Be);
    Tb.Open(Dir);
    Sq := TVSql.Create(Tb);
    try
      cap := WAL_CAP;
      BeC.WalMaxBytes := cap;
      Chk('WL0 tavan ayarlandi', BeC.WalMaxBytes = cap,
        'tavan=' + IntToStr(BeC.WalMaxBytes));

      Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');

      { --- WL1: tavan ALTINDA siradan (autocommit) yazimlar. Her commit
        tavana yaklasinca sert tavan dali SENKRON checkpoint yapar; bu
        yuzden yuz satir da gecmeli ve WAL tavani asmamali. }
      ck0 := BeC.Engine.CheckpointCount;
      for i := 1 to BASE_ROWS do
        Ins(Sq, i);
      ck1 := BeC.Engine.CheckpointCount;
      expected := QInt(Sq, 'SELECT COUNT(*) FROM t');
      Chk('WL1 tavan altinda yazimlar basarili', expected = BASE_ROWS,
        'satir=' + IntToStr(expected) + ' beklenen=' + IntToStr(BASE_ROWS));
      walBefore := BeC.Engine.Wal.Bytes;
      Chk('WL1b sert tavan WAL''i sinirladi', walBefore <= cap,
        'wal=' + IntToStr(walBefore) + ' tavan=' + IntToStr(cap));
      { Otomatik tahliye gercekten calisti mi? (yoksa "tavan" yalnizca
        commit reddiyle mi sinirliyor — o zaman kucuk yazimlar kilitlenir) }
      Chk('WL1c sert tavan dalinda otomatik checkpoint yapildi', ck1 > ck0,
        'checkpoint ' + IntToStr(ck0) + ' -> ' + IntToStr(ck1));

      { --- WL2: tavani ASAN tek islem. Commit KONTROLLU reddedilmeli. }
      Sq.Exec('BEGIN');
      for i := 1 to TXN_ROWS do
        Ins(Sq, 5000 + i);
      code := TryExecCode(Sq, 'COMMIT', msg);
      WriteLn('BILGI WL2 ret: code=', code, ' msg=', msg);
      Chk('WL2 tavani asan commit ecLimit ile reddedildi', code = 'ecLimit',
        'code=' + code + ' msg=' + msg);
      Chk('WL2b ret mesaji WAL sinirini adlandiriyor',
        Pos('WAL', UpperCase(msg)) > 0, 'msg=' + msg);

      { --- WL3: reddedilen commit HAYALET satir birakmadi. }
      if code = 'ecLimit' then
      begin
        { Reddedilen commit motoru geri alir; ROLLBACK yine de denenir ve
          "acik islem yok" hatasi burada yutulur. }
        try
          Sq.Exec('ROLLBACK');
        except
          on E: Exception do ;
        end;
        expected := QInt(Sq, 'SELECT COUNT(*) FROM t');
        Chk('WL3 reddedilen commit hayalet satir birakmadi',
          expected = BASE_ROWS,
          'satir=' + IntToStr(expected) + ' beklenen=' + IntToStr(BASE_ROWS));
      end;

      { --- WL2c: ret sonrasi KUCUK yazim calisir. Tavan kalici kilit
        degildir; aksi halde WAL tavanda kalip her yazim reddedilirdi. }
      Ins(Sq, 7000);
      expected := QInt(Sq, 'SELECT COUNT(*) FROM t');
      Chk('WL2c ret sonrasi kucuk yazim basarili',
        expected = BASE_ROWS + 1,
        'satir=' + IntToStr(expected) + ' beklenen=' + IntToStr(BASE_ROWS + 1));
      Sq.Exec('DELETE FROM t WHERE id = 7000');
      expected := QInt(Sq, 'SELECT COUNT(*) FROM t');
      Chk('WL2d silme sonrasi sayi geri dondu', expected = BASE_ROWS,
        'satir=' + IntToStr(expected) + ' beklenen=' + IntToStr(BASE_ROWS));

      { --- WL4: ret sonrasi WAL tamponu temizlendi; tavan asilmadi. }
      walAfter := BeC.Engine.Wal.Bytes;
      Chk('WL4 ret sonrasi WAL tavana geri dondu', walAfter <= cap,
        'wal=' + IntToStr(walAfter) + ' tavan=' + IntToStr(cap));

      { --- WL5: onceki onayli satirlar ayni oturumda saglam. }
      Chk('WL5 ret sonrasi onceki satirlar okunur',
        LiveScan(Sq, BASE_ROWS, detail), detail);

      { --- WL6: tavan KAPATILINCA ayni buyuk islem gecer. Boylece reddin
        nedeni gercekten tavan oldugu kanitlanir (baska ariza degil). }
      BeC.WalMaxBytes := 0;
      Sq.Exec('BEGIN');
      for i := 1 to TXN_ROWS do
        Ins(Sq, 5000 + i);
      code := TryExecCode(Sq, 'COMMIT', msg);
      Chk('WL6 tavan kapaliyken ayni islem commit edildi', code = '',
        'code=' + code + ' msg=' + msg);
      expected := QInt(Sq, 'SELECT COUNT(*) FROM t');
      Chk('WL6b islem satirlari gorunur',
        expected = BASE_ROWS + TXN_ROWS,
        'satir=' + IntToStr(expected) + ' beklenen=' +
        IntToStr(BASE_ROWS + TXN_ROWS));

      { --- WL7: tavan yeniden acilir; checkpoint yeri bosaltir; yazim
        DEVAM eder (tavan kalici bir kilit degil). }
      BeC.WalMaxBytes := cap;
      Chk('WL7 checkpoint basarili', BeC.Engine.Checkpoint(True), '');
      for i := 1 to AFTER_ROWS do
        Ins(Sq, 9000 + i);
      expected := QInt(Sq, 'SELECT COUNT(*) FROM t');
      Chk('WL7b checkpoint sonrasi yazim devam etti',
        expected = BASE_ROWS + TXN_ROWS + AFTER_ROWS,
        'satir=' + IntToStr(expected) + ' beklenen=' +
        IntToStr(BASE_ROWS + TXN_ROWS + AFTER_ROWS));
      walAfter := BeC.Engine.Wal.Bytes;
      Chk('WL7c WAL tavanin altinda kaldi', walAfter <= cap,
        'wal=' + IntToStr(walAfter) + ' tavan=' + IntToStr(cap));

      { --- WL8: retten SONRA ayni oturumda okunan veri ile kapanis
        oncesi veri tutarli. }
      Chk('WL8 tum onayli satirlar saglam',
        LiveScan(Sq, Integer(expected), detail), detail);
    finally
      FreeAndNil(Sq);
    end;
  finally
    FreeAndNil(Tb);
    Be := nil;
    BeC := nil;
  end;

  { --- WL9: yeniden acilis + tam VERIFY. Reddedilen commit'in yarim
    kaydi kalmamali, onayli her satir durmali. }
  rc := ReopenScan(Dir, Db, Integer(expected), detail);
  Chk('WL9 yeniden acilis: tum onayli satirlar duruyor', rc = -1, detail);
  Chk('WL9b VERIFY temiz', VerifyDb(Db, rep), 'rapor=' + rep);

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
