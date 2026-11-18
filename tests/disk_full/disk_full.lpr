program disk_full;
{ v3.41 KALICI REGRESYON KAPISI - SKILL3 §12.1 disk dolu / kisa yazma.
  Amac: disk doldugunda (ENOSPC) ya da kisa yazmada motorun NE YAPTIGINI
  olcmek. Beklenen:
    - yazma yolu KONTROLLU `ecIOError` verir (surec cokmez),
    - sayfa cercevesi KIRLI kalir (sessizce temiz isaretlenip veri
      kaybolmaz),
    - ayni veritabani hata giderildikten sonra yazmaya devam eder,
    - yeniden acilista onaylanmis satirlar eksiksizdir ve VERIFY temizdir,
    - BASARISIZ commit HAYALET satir birakmaz: ayni oturumda `SELECT
      COUNT(*)` de, yeniden acilis da ayni durabil satir kumesini gorur.

  Disk dolu gercek dunyada `THandleStream.Write` tarafindan 0'a cevrilen
  kisa yazma olarak gorunur; bu yuzden hata ENJEKSIYONU kisa yazma uretir.
  Enjeksiyon yalniz test icindir (`TVDbPageStore.OnWriteFault`,
  `TVDbPageWal.OnWriteFault`).

  Olculen:
    DF1 kontrol: temel veri kusursuz yazilir/okunur
    DF2 sert yazma hatasi kontrollu `ecIOError` uretir, cokme yok
    DF3 hata + ROLLBACK sonrasi onayli satirlar bozulmaz
    DF4 kisa yazma (disk doldu) kontrollu `ecIOError` uretir
    DF5 hata giderilince checkpoint ve commit basarili olur
    DF6 yeniden acilista TUM onayli satirlar durur, VERIFY temiz
    DF7 hata yolu GERCEKTEN tetiklendi (en az bir yazma cagrisi)
    DF8 WAL commit yazimi: kisa/disk dolu hatasi kontrollu `ecIOError`
    DF8b WAL hata yolu gercekten tetiklendi
    DF8c WAL hatasi sonrasi ayni oturumda onayli satir kumesi bozulmaz
    DF9 meta sayfa yazimi: kontrollu `ecIOError`, onayli veri korunur
    DF9b/DF9c hata yolu tetiklendi; hata giderilince checkpoint tamamlanir
    DF9d meta hatasi onayli satirlari silmez
    DF10a kilit sizintisi senaryosu tetiklendi (checkpoint hata verdi)
    DF10b hata sonrasi IKINCI backend ayni dosyaya yazabildi (kilit sizmadi)
    DF10c ikinci backend'in satiri okunuyor

  Derleme: fpc. Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbPageEngine,
  VDbPageStore, VDbPageWal, VDbPage, VDbTable, VDbSql, VDbErr;

const
  BASE_ROWS = 120;
  MORE_ROWS = 30;
  WAL_ROWS = 10;
  META_ROWS = 10;

type
  { Yalniz test: yazma hatasi enjeksiyonu. Ayni sinif hem sayfa deposuna
    (`OnWriteFault`) hem WAL'e (`Wal.OnWriteFault`) baglanir. }
  TWriteFault = class
  public
    Mode: Integer;    { 0 = normal, 1 = sert hata, 2 = kisa yazma }
    MinPos: Int64;    { bu konumun altindaki yazmalar etkilenmez }
    AtPos: Int64;     { >= 0: YALNIZ bu konumdaki yazma etkilenir }
    Hits: Integer;
    function Check(APos: Int64; ALen: Integer): Integer;
  end;

function TWriteFault.Check(APos: Int64; ALen: Integer): Integer;
begin
  Result := 0;
  if Mode = 0 then Exit;
  if APos < MinPos then Exit;
  if (AtPos >= 0) and (APos <> AtPos) then Exit;
  Inc(Hits);
  if Mode = 1 then
    Result := -1                       { hic yazma, sabit hata }
  else
    Result := ALen div 2;              { yarim yazma = disk doldu }
end;

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

function ValOf(AId: Integer): string;
var
  i: Integer;
begin
  SetLength(Result, 180);
  for i := 1 to Length(Result) do
    Result[i] := Chr(Ord('a') + ((AId + i) mod 26));
  Result := 'r' + IntToStr(AId) + ':' + Result;
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

{ Acar, tum satirlari sayar ve dogrular. rc: -1 ok, -2 uyusmazlik,
  -3 beklenmeyen istisna. }
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

var
  Dir, Db: string;
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Be2: IVdbBackend;
  Tb: TVTableDb;
  Tb2: TVTableDb;
  Sq: TVSql;
  Sq2: TVSql;
  Fault: TWriteFault;
  i, rc: Integer;
  raised, busy: Boolean;
  code: string;
  detail, rep, msg: string;
  n: Int64;

begin
  GPass := 0;
  GFail := 0;
  Dir := IncludeTrailingPathDelimiter(
    ExtractFilePath(ParamStr(0)) + 'tmp/df');
  WipeDir(Dir);
  Db := IncludeTrailingPathDelimiter(Dir) + 'df.odb';
  Fault := TWriteFault.Create;
  Fault.Mode := 0;
  Fault.MinPos := VDB_PAGE_SIZE;
  Fault.AtPos := -1;
  BeC := nil;
  Be := nil;

  try
    BeC := TVdbBackendV3.Create(Db, True, 512, 4000);
    Be := BeC;
    Tb := TVTableDb.CreateBackend(Be);
    Tb.Open(Dir);
    Sq := TVSql.Create(Tb);
    try
      Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      Sq.Exec('BEGIN');
      for i := 1 to BASE_ROWS do
        Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
          StringReplace(ValOf(i), '''', '''''', [rfReplaceAll]) + ''')');
      Sq.Exec('COMMIT');

      n := QInt(Sq, 'SELECT COUNT(*) FROM t');
      Chk('DF1 kontrol: temel veri yazildi', n = BASE_ROWS,
        'satir=' + IntToStr(n));

      { DF2: sert yazma hatasi. }
      BeC.Engine.Store.OnWriteFault := Fault.Check;
      Fault.Mode := 1;
      raised := False;
      code := '';
      try
        Sq.Exec('BEGIN');
        for i := BASE_ROWS + 1 to BASE_ROWS + 10 do
          Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
            StringReplace(ValOf(i), '''', '''''', [rfReplaceAll]) + ''')');
        BeC.Engine.Store.Flush(True);
      except
        on E: EVDbException do
        begin
          raised := True;
          code := VDbErrorName(E.ErrorCode);
        end;
        on E: Exception do
        begin
          raised := True;
          code := E.ClassName;
        end;
      end;
      Chk('DF2 sert yazma hatasi kontrollu ecIOError',
        raised and (code = 'ecIOError'), 'kod=' + code);
      Chk('DF7 hata yolu tetiklendi', Fault.Hits > 0,
        'cagri=' + IntToStr(Fault.Hits));

      { Hata giderildi: yarim kalan islem geri alinir. }
      Fault.Mode := 0;
      try
        Sq.Exec('ROLLBACK');
      except
        on E: Exception do
          WriteLn('BILGI DF3 rollback: ', E.ClassName, ': ', E.Message);
      end;

      n := QInt(Sq, 'SELECT COUNT(*) FROM t');
      Chk('DF3 rollback sonrasi onayli satirlar duruyor', n = BASE_ROWS,
        'satir=' + IntToStr(n));

      { DF4: kisa yazma (disk doldu) yolu. }
      Fault.Hits := 0;
      Fault.Mode := 2;
      raised := False;
      code := '';
      try
        Sq.Exec('BEGIN');
        for i := BASE_ROWS + 1 to BASE_ROWS + 10 do
          Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
            StringReplace(ValOf(i), '''', '''''', [rfReplaceAll]) + ''')');
        BeC.Engine.Store.Flush(True);
      except
        on E: EVDbException do
        begin
          raised := True;
          code := VDbErrorName(E.ErrorCode);
        end;
        on E: Exception do
        begin
          raised := True;
          code := E.ClassName;
        end;
      end;
      Chk('DF4 kisa yazma kontrollu ecIOError',
        raised and (code = 'ecIOError'), 'kod=' + code);
      Fault.Mode := 0;
      try
        Sq.Exec('ROLLBACK');
      except
        on E: Exception do
          WriteLn('BILGI DF4 rollback: ', E.ClassName, ': ', E.Message);
      end;

      { DF8: WAL yazma yolu. Commit kaydi WAL'e yazilirken disk dolarsa
        hata KONTROLLU `ecIOError` olmali (ham RTL hatasi degil), kesik
        kuyruk geri kirpilmali ve onayli satirlar bozulmamali. }
      BeC.Engine.Store.OnWriteFault := nil;
      BeC.Engine.Wal.OnWriteFault := Fault.Check;
      Fault.MinPos := 0;
      Fault.AtPos := -1;
      Fault.Hits := 0;
      Fault.Mode := 1;
      raised := False;
      code := '';
      msg := '';
      try
        Sq.Exec('BEGIN');
        for i := 5001 to 5000 + WAL_ROWS do
          Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
            StringReplace(ValOf(i), '''', '''''', [rfReplaceAll]) + ''')');
        Sq.Exec('COMMIT');
      except
        on E: EVDbException do
        begin
          raised := True;
          code := VDbErrorName(E.ErrorCode);
          msg := E.Message;
        end;
        on E: Exception do
        begin
          raised := True;
          code := E.ClassName;
          msg := E.Message;
        end;
      end;
      Chk('DF8 WAL yazma hatasi kontrollu ecIOError',
        raised and (code = 'ecIOError'), 'kod=' + code + ' mesaj=' + msg);
      Chk('DF8b WAL hata yolu tetiklendi', Fault.Hits > 0,
        'cagri=' + IntToStr(Fault.Hits));
      Fault.Mode := 0;
      try
        Sq.Exec('ROLLBACK');
      except
        on E: Exception do
          WriteLn('BILGI DF8 rollback: ', E.ClassName, ': ', E.Message);
      end;

      n := QInt(Sq, 'SELECT COUNT(*) FROM t');
      Chk('DF8c WAL hatasi sonrasi onayli satirlar duruyor',
        n = BASE_ROWS, 'satir=' + IntToStr(n));
      { DF9: META SAYFA yazma yolu. Yalniz konum 0 (meta) hata verir; sayfa
        yazimlari ve WAL saglamdir. Checkpoint'te meta yazimi patlamali,
        hata kontrollu olmali, ardindan hata giderilince checkpoint
        tamamlanmali ve onayli satirlar korunmali. }
      BeC.Engine.Wal.OnWriteFault := nil;
      BeC.Engine.Store.OnWriteFault := Fault.Check;
      Fault.MinPos := 0;
      Fault.AtPos := 0;
      Fault.Hits := 0;
      Fault.Mode := 1;
      Sq.Exec('BEGIN');
      for i := 6001 to 6000 + META_ROWS do
        Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
          StringReplace(ValOf(i), '''', '''''', [rfReplaceAll]) + ''')');
      Sq.Exec('COMMIT');
      raised := False;
      code := '';
      try
        BeC.Engine.Checkpoint(True);
      except
        on E: EVDbException do
        begin
          raised := True;
          code := VDbErrorName(E.ErrorCode);
        end;
        on E: Exception do
        begin
          raised := True;
          code := E.ClassName;
        end;
      end;
      Chk('DF9 meta sayfa yazma hatasi kontrollu ecIOError',
        raised and (code = 'ecIOError'), 'kod=' + code);
      Chk('DF9b meta hata yolu tetiklendi', Fault.Hits > 0,
        'cagri=' + IntToStr(Fault.Hits));
      Fault.Mode := 0;
      Chk('DF9c hata giderilince checkpoint tamamlandi',
        BeC.Engine.Checkpoint(True), '');
      n := QInt(Sq, 'SELECT COUNT(*) FROM t');
      Chk('DF9d meta hatasi onayli satirlari silmedi',
        n = BASE_ROWS + META_ROWS, 'satir=' + IntToStr(n));

      { Hata giderildikten sonra yeni onayli veri eklenebilmeli. }
      Sq.Exec('BEGIN');
      for i := BASE_ROWS + 1 to BASE_ROWS + MORE_ROWS do
        Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
          StringReplace(ValOf(i), '''', '''''', [rfReplaceAll]) + ''')');
      Sq.Exec('COMMIT');
      n := QInt(Sq, 'SELECT COUNT(*) FROM t');
      Chk('DF5 hata sonrasi yazma devam etti',
        n = BASE_ROWS + META_ROWS + MORE_ROWS, 'satir=' + IntToStr(n));

      { DF5b: checkpoint hatasiz tamamlanir. }
      Chk('DF5b checkpoint basarili', BeC.Engine.Checkpoint(True), '');

      { DF10 (v3.59 / SKILL5 8.1): CHECKPOINT KILIT SIZINTISI.
        Checkpoint sirasinda ilk yazim `EnsureIoWrite` uzerinden SURECLER
        ARASI tam dosya kilidini alir; kilidi birakan `EndIoWrite` ONCEDEN
        yalnizca normal yolun sonunda cagriliyordu. Meta yazimi hata
        verdiginde kilit bu surecte asili kaliyor ve DIGER yazarlar commit
        edemiyordu. Olcum: hata enjekte edilmis checkpoint'ten sonra AYNI
        dosyayi acan ikinci bir backend yazip commit edebilmelidir.
        (Ayni surecte ikinci handle bile ayirt edicidir: Windows
        LockFileEx ve POSIX flock kilidi dosya tanimlayicisi basina tutar,
        bu yuzden ikinci handle kilidi gercekten bekler.) }
      Sq.Exec('CREATE TABLE lockprobe (id INTEGER PRIMARY KEY)');
      Fault.MinPos := 0;
      Fault.AtPos := 0;      { yalniz meta sayfa yazimi hata verir }
      Fault.Hits := 0;
      Fault.Mode := 1;
      BeC.Engine.Store.OnWriteFault := Fault.Check;
      raised := False;
      code := '';
      try
        BeC.Engine.Checkpoint(True);
      except
        on E: EVDbException do
        begin
          raised := True;
          code := VDbErrorName(E.ErrorCode);
        end;
        on E: Exception do
        begin
          raised := True;
          code := E.ClassName;
        end;
      end;
      Chk('DF10a kilit sizintisi senaryosu tetiklendi',
        raised and (Fault.Hits > 0), 'kod=' + code +
        ' cagri=' + IntToStr(Fault.Hits));
      Fault.Mode := 0;
      BeC.Engine.Store.OnWriteFault := nil;

      Be2 := nil;
      Tb2 := nil;
      Sq2 := nil;
      busy := False;
      detail := '';
      try
        VdbOpenWithBusyTimeout(Db, Be2, 400, False, 512);
        Tb2 := TVTableDb.CreateBackend(Be2);
        Tb2.Open(Dir);
        Sq2 := TVSql.Create(Tb2);
        Sq2.Exec('BEGIN');
        Sq2.Exec('INSERT INTO lockprobe (id) VALUES (1)');
        Sq2.Exec('COMMIT');
      except
        on E: Exception do
        begin
          busy := True;
          detail := E.ClassName + ': ' + E.Message;
        end;
      end;
      Chk('DF10b hata sonrasi IKINCI backend ayni dosyaya yazabildi',
        not busy, detail);
      n := 0;
      try
        if Sq2 <> nil then
          n := QInt(Sq2, 'SELECT COUNT(*) FROM lockprobe WHERE id = 1');
      except
        on E: Exception do
          detail := E.ClassName + ': ' + E.Message;
      end;
      Chk('DF10c ikinci backend satiri okunuyor', n = 1,
        'satir=' + IntToStr(n));
      FreeAndNil(Sq2);
      FreeAndNil(Tb2);
      Be2 := nil;
    finally
      Fault.Mode := 0;
      BeC.Engine.Store.OnWriteFault := nil;
      BeC.Engine.Wal.OnWriteFault := nil;
      FreeAndNil(Sq);
    end;
  finally
    Be := nil;
    BeC := nil;
    Fault.Free;
  end;

  { DF6: yeniden acilis + tam VERIFY. }
  rc := ReopenScan(Dir, Db, BASE_ROWS + META_ROWS + MORE_ROWS, detail);
  Chk('DF6 yeniden acilis: tum onayli satirlar duruyor', rc = -1, detail);
  Chk('DF6b VERIFY temiz', VerifyDb(Db, rep), 'rapor=' + rep);

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
