program disk_full;
{ v3.40 KALICI REGRESYON KAPISI - SKILL3 §12.1 disk dolu / kisa yazma.
  Amac: disk doldugunda (ENOSPC) ya da kisa yazmada motorun NE YAPTIGINI
  olcmek. Beklenen:
    - yazma yolu KONTROLLU `ecIOError` verir (surec cokmez),
    - sayfa cercevesi KIRLI kalir (sessizce temiz isaretlenip veri
      kaybolmaz),
    - ayni veritabani hata giderildikten sonra yazmaya devam eder,
    - yeniden acilista onaylanmis satirlar eksiksizdir ve VERIFY temizdir.

  Disk dolu gercek dunyada `THandleStream.Write` tarafindan 0'a cevrilen
  kisa yazma olarak gorunur; bu yuzden hata ENJEKSIYONU kisa yazma uretir.
  Enjeksiyon yalniz test icindir (`TVDbPageStore.OnWriteFault`).

  Olculen:
    DF1 kontrol: temel veri kusursuz yazilir/okunur
    DF2 sert yazma hatasi kontrollu `ecIOError` uretir, cokme yok
    DF3 hata + ROLLBACK sonrasi onayli satirlar bozulmaz
    DF4 kisa yazma (disk doldu) kontrollu `ecIOError` uretir
    DF5 hata giderilince checkpoint basarili olur
    DF6 yeniden acilista TUM onayli satirlar durur, VERIFY temiz
    DF7 hata yolu GERCEKTEN tetiklendi (en az bir yazma cagrisi)

  Derleme: fpc. Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbPageEngine,
  VDbPageStore, VDbPage, VDbTable, VDbSql, VDbErr;

const
  BASE_ROWS = 120;
  MORE_ROWS = 30;

type
  { Yalniz test: yazma hatasi enjeksiyonu. }
  TWriteFault = class
  public
    Mode: Integer;    { 0 = normal, 1 = sert hata, 2 = kisa yazma }
    MinPos: Int64;    { bu konumun altindaki yazmalar (meta) etkilenmez }
    Hits: Integer;
    function Check(APos: Int64; ALen: Integer): Integer;
  end;

function TWriteFault.Check(APos: Int64; ALen: Integer): Integer;
begin
  Result := 0;
  if (Mode = 0) or (APos < MinPos) then Exit;
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
  Tb: TVTableDb;
  Sq: TVSql;
  Fault: TWriteFault;
  i, rc: Integer;
  raised: Boolean;
  code: string;
  detail, rep: string;
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

      { Hata giderildikten sonra yeni onayli veri eklenebilmeli. }
      Sq.Exec('BEGIN');
      for i := BASE_ROWS + 1 to BASE_ROWS + MORE_ROWS do
        Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
          StringReplace(ValOf(i), '''', '''''', [rfReplaceAll]) + ''')');
      Sq.Exec('COMMIT');
      n := QInt(Sq, 'SELECT COUNT(*) FROM t');
      Chk('DF5 hata sonrasi yazma devam etti',
        n = BASE_ROWS + MORE_ROWS, 'satir=' + IntToStr(n));

      { DF5b: checkpoint hatasiz tamamlanir. }
      Chk('DF5b checkpoint basarili', BeC.Engine.Checkpoint(True), '');
    finally
      Fault.Mode := 0;
      BeC.Engine.Store.OnWriteFault := nil;
      FreeAndNil(Sq);
    end;
  finally
    Be := nil;
    BeC := nil;
    Fault.Free;
  end;

  { DF6: yeniden acilis + tam VERIFY. }
  rc := ReopenScan(Dir, Db, BASE_ROWS + MORE_ROWS, detail);
  Chk('DF6 yeniden acilis: tum onayli satirlar duruyor', rc = -1, detail);
  Chk('DF6b VERIFY temiz', VerifyDb(Db, rep), 'rapor=' + rep);

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
