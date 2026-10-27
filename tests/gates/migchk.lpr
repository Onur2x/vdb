program migchk;

{ VDB v3 - v2 -> v3 goc kapisi (Sprint 2.8)

  Kapsam:
    1) v2 veritabani (SQL ile doldurulmus) -> v3 gocu; kayit sayisi ve
       her kaydin BAYT BAYT ayni olmasi (VdbMigrateVerify).
    2) Goc edilen v3 dosyasi SQL katmaniyla acilir: sema, COUNT(*), SUM,
       PK okumasi ve INDEX'li arama v2 ile ayni sonucu vermeli.
    3) SQL yolu: `MIGRATE TO v3 'dosya'` ve `MIGRATE VERIFY 'dosya'`
       acik v2 oturumunda calisir; mesajlari bildirir.
    4) Var olan hedefin uzerine yazilmaz; v3 kaynaktan goc reddedilir.
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: cthreads programin EN BASINDA olmali (TEvent/TThread). }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, VDbCore, VDbBackendApi, VDbBackendV2, VDbBackendV3,
  VDbTable, VDbSql, VDbMigrate, VDbTypes, VDbErr;

var
  gPass, gFail: Int64;
  gDir: string;

procedure Ok(const S: string);
begin
  Inc(gPass);
  WriteLn('   OK   ', S);
end;

procedure Fail(const S: string);
begin
  Inc(gFail);
  WriteLn('   FAIL ', S);
end;

function DirOf(const N: string): string;
begin
  Result := IncludeTrailingPathDelimiter(gDir) + N;
end;

procedure CleanDir;
var
  sr: TSearchRec;
  base: string;
begin
  base := IncludeTrailingPathDelimiter(gDir);
  if FindFirst(base + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        if (sr.Attr and faDirectory) = 0 then
          DeleteFile(base + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

type
  TV2 = record
    Kv: TVDb;
    Tb: TVTableDb;
    Sq: TVSql;
  end;

  TV3 = record
    Be: IVDbBackend;
    Tb: TVTableDb;
    Sq: TVSql;
  end;

function OpenV2(out S: TV2; const Dir: string): Boolean;
begin
  Result := False;
  S.Kv := TVDb.Create;
  try
    S.Kv.Open(Dir);
    S.Tb := TVTableDb.Create(S.Kv);
    S.Sq := TVSql.Create(S.Tb);
    S.Tb.Open(Dir);
    Result := True;
  except
    on E: Exception do
    begin
      WriteLn('   (v2 acilamadi: ', E.Message, ')');
      if S.Sq <> nil then FreeAndNil(S.Sq);
      if S.Tb <> nil then FreeAndNil(S.Tb);
      if S.Kv <> nil then FreeAndNil(S.Kv);
    end;
  end;
end;

procedure CloseV2(var S: TV2);
begin
  if S.Sq <> nil then FreeAndNil(S.Sq);
  if S.Tb <> nil then
  begin
    S.Tb.Close;
    FreeAndNil(S.Tb);
  end;
  if S.Kv <> nil then
  begin
    S.Kv.Close;
    FreeAndNil(S.Kv);
  end;
end;

function OpenV3(out S: TV3; const FileName: string; Create_: Boolean;
  Pool: Integer = 256): Boolean;
begin
  Result := False;
  S.Be := TVdbBackendV3.Create(FileName, Create_, Pool);
  S.Tb := TVTableDb.CreateBackend(S.Be);
  S.Sq := TVSql.Create(S.Tb);
  S.Tb.Open(gDir);
  Result := True;
end;

procedure CloseV3(var S: TV3);
begin
  if S.Sq <> nil then FreeAndNil(S.Sq);
  if S.Tb <> nil then
  begin
    S.Tb.Close;
    FreeAndNil(S.Tb);
  end;
  S.Be := nil;
end;

{ Bir SQL cumlesi; hata firlatirsa yakalanir ve '' doner. }
function Q(const S: TVSql; const Sql: string): string;
var
  r: TSqlResult;
begin
  Result := '';
  r := S.Exec(Sql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := r.Rows[0][0];
end;

function FileSizeOf(const Path: string): Int64;
var
  f: TFileStream;
begin
  Result := -1;
  if not FileExists(Path) then Exit;
  f := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    Result := f.Size;
  finally
    f.Free;
  end;
end;

{ ---------------------------------------------------- 1) veri + goc }

procedure BuildV2(const DbDir: string; N: Integer);
var
  S: TV2;
  i, part, first, last: Integer;
  vals: string;
begin
  ForceDirectories(DbDir);
  if not OpenV2(S, DbDir) then
    raise Exception.Create('v2 acilamadi');
  try
    Q(S.Sq, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT, s INTEGER)');
    part := 500;
    i := 1;
    while i <= N do
    begin
      first := i;
      last := i + part - 1;
      if last > N then last := N;
      vals := '';
      for i := first to last do
      begin
        if vals <> '' then vals := vals + ',';
        vals := vals + Format('(%d,''val-%d'',%d)', [i, i, i mod 10]);
      end;
      Q(S.Sq, 'INSERT INTO t (id, v, s) VALUES ' + vals);
      i := last + 1;
    end;
    Q(S.Sq, 'CREATE INDEX ix_s ON t (s)');
  finally
    CloseV2(S);
  end;
end;

function ExpectedSumS(N: Integer): Int64;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to N do
    Inc(Result, i mod 10);
end;

procedure TestMigrate(N: Integer);
var
  S: TV2;
  src, dst: string;
  be: IVdbBackend;
  rep: TVdbMigrateReport;
  err: string;
  V3: TV3;
  szV2, szV3: Int64;
  sv: string;
begin
  WriteLn;
  WriteLn('1) v2 -> v3 gocu (', N, ' satir)');
  CleanDir;
  src := DirOf('mig_src');
  dst := DirOf('mig_dst.odb');
  BuildV2(src, N);
  szV2 := FileSizeOf(IncludeTrailingPathDelimiter(src) + 'veritabani.odb');

  { Kaynak: v2'ye bagli arayuz. }
  if not OpenV2(S, src) then
  begin
    Fail('kaynak v2 yeniden acilamadi');
    Exit;
  end;
  be := TVdbBackendV2.Create(S.Kv);
  try
    if not VdbMigrateToV3(be, dst, 256, rep, err) then
    begin
      Fail('goc basarisiz: ' + err);
      Exit;
    end;
    Ok(Format('goc tamam: kayit=%d bayt=%d %d ms', [rep.Keys, rep.Bytes, rep.Ms]));
    szV3 := FileSizeOf(dst);
    if (szV2 > 0) and (szV3 > 0) then
      WriteLn(Format('        boyut: v2=%d B  v3=%d B  (%.1f%%)',
        [szV2, szV3, szV3 * 100.0 / szV2]));

    if VdbMigrateVerify(be, dst, 256, rep, err) then
      Ok(Format('dogrulama: %d kayit bayt bayt ayni (%d ms)',
        [rep.Keys, rep.Ms]))
    else
      Fail('dogrulama basarisiz: ' + err);
  finally
    be := nil;
    CloseV2(S);
  end;

  { Hedef dosya var: uzerine yazilmamali. }
  if not OpenV2(S, src) then
    Fail('kaynak v2 acilamadi (2)')
  else
  begin
    be := TVdbBackendV2.Create(S.Kv);
    try
      if VdbMigrateToV3(be, dst, 64, rep, err) then
        Fail('var olan hedefin uzerine yazildi')
      else
        Ok('var olan hedef reddedildi');
    finally
      be := nil;
      CloseV2(S);
    end;
  end;

  { Goc edilen dosya SQL ile ayni sonuclari vermeli. }
  if not FileExists(dst) then
  begin
    Fail('goc dosyasi yok');
    Exit;
  end;
  OpenV3(V3, dst, False);
  try
    sv := Q(V3.Sq, 'SELECT COUNT(*) FROM t');
    if sv = IntToStr(N) then
      Ok('v3 COUNT(*) = ' + sv)
    else
      Fail('v3 COUNT(*) = ' + sv + ' (beklenen ' + IntToStr(N) + ')');

    sv := Q(V3.Sq, 'SELECT SUM(s) FROM t');
    if sv = IntToStr(ExpectedSumS(N)) then
      Ok('v3 SUM(s) = ' + sv)
    else
      Fail('v3 SUM(s) = ' + sv + ' (beklenen ' + IntToStr(ExpectedSumS(N)) + ')');

    sv := Q(V3.Sq, 'SELECT v FROM t WHERE id = ' + IntToStr(N div 2));
    if sv = 'val-' + IntToStr(N div 2) then
      Ok('v3 PK okumasi: ' + sv)
    else
      Fail('v3 PK okumasi: "' + sv + '" (beklenen val-' + IntToStr(N div 2) + ')');

    sv := Q(V3.Sq, 'SELECT COUNT(*) FROM t WHERE s = 7');
    if sv = IntToStr((N + 2) div 10) then
      Ok('v3 indeksli arama s=7: ' + sv)
    else
      Fail('v3 indeksli arama s=7: ' + sv + ' (beklenen ' +
        IntToStr((N + 2) div 10) + ')');

    { Ilk ve son satir birebir mi? }
    sv := Q(V3.Sq, 'SELECT v FROM t WHERE id = 1');
    if sv = 'val-1' then Ok('v3 ilk satir: ' + sv) else Fail('v3 ilk satir: "' + sv + '"');
    sv := Q(V3.Sq, 'SELECT v FROM t WHERE id = ' + IntToStr(N));
    if sv = 'val-' + IntToStr(N) then Ok('v3 son satir: ' + sv)
    else Fail('v3 son satir: "' + sv + '"');
  finally
    CloseV3(V3);
  end;
end;

{ ---------------------------------------------------- 2) SQL yolu }

procedure TestSqlMigrate(N: Integer);
var
  S: TV2;
  src, dst: string;
  r: TSqlResult;
begin
  WriteLn;
  WriteLn('2) SQL: MIGRATE TO v3 / MIGRATE VERIFY');
  CleanDir;
  src := DirOf('sql_src');
  dst := DirOf('sql_dst');
  BuildV2(src, 1000);

  if not OpenV2(S, src) then
  begin
    Fail('v2 acilamadi');
    Exit;
  end;
  try
    r := S.Sq.Exec('MIGRATE TO v3 ''' + dst + '''');
    if Pos('GOC v3:', r.Msg) = 1 then
      Ok('MIGRATE TO v3: ' + r.Msg)
    else
      Fail('MIGRATE TO v3 mesaji: ' + r.Msg);

    r := S.Sq.Exec('MIGRATE VERIFY ''' + dst + '.odb''');
    if Pos('GOC DOGRULANDI:', r.Msg) = 1 then
      Ok('MIGRATE VERIFY: ' + r.Msg)
    else
      Fail('MIGRATE VERIFY mesaji: ' + r.Msg);

    { Bozuk hedef: dogrulama kirmizi olmali. }
    r := S.Sq.Exec('MIGRATE VERIFY ''' + DirOf('yok.odb') + '''');
    Fail('olmayan hedef dogrulandi');
  except
    on E: EVDbException do
      Ok('olmayan hedef reddedildi');
    on E: Exception do
      Fail('beklenmeyen hata: ' + E.Message);
  end;
  try
    CloseV2(S);
  except
    on E: Exception do
      WriteLn('   (kapatma: ', E.Message, ')');
  end;
end;

{ ---------------------------------------------------- 3) v3 kaynak reddi }

procedure TestV3SourceRejected;
var
  V3: TV3;
  dst: string;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('3) v3 kaynaktan goc reddi');
  CleanDir;
  OpenV3(V3, DirOf('v3src.odb'), True, 32);
  raised := False;
  try
    try
      V3.Sq.Exec('MIGRATE TO v3 ''' + DirOf('v3dst') + '''');
    except
      on E: EVDbException do
      begin
        raised := True;
        Ok('v3 kaynak reddedildi: ' + E.Message);
      end;
    end;
    if not raised then
      Fail('v3 kaynak kabul edildi');
  finally
    CloseV3(V3);
  end;
end;

var
  N: Integer;

begin
  gPass := 0;
  gFail := 0;
  if ParamCount >= 1 then
    gDir := ParamStr(1)
  else
    gDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'migchk_tmp';
  if ParamCount >= 2 then
    N := StrToIntDef(ParamStr(2), 5000)
  else
    N := 5000;
  gDir := ExcludeTrailingPathDelimiter(ExpandFileName(gDir));
  ForceDirectories(gDir);

  WriteLn('VDB v3 migchk - v2 -> v3 goc kapisi');
  WriteLn('dizin=', gDir, '  N=', N);
  WriteLn;

  TestMigrate(N);
  TestSqlMigrate(N);
  TestV3SourceRejected;

  WriteLn;
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
  begin
    WriteLn('V2 -> V3 GOCU DOGRULANDI');
    Halt(0);
  end;
  WriteLn('V2 -> V3 GOCU HATALI');
  Halt(1);
end.
