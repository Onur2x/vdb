program txn_limit;
{ v3.40 KALICI REGRESYON KAPISI - SKILL3 §12.2 asiri islem / islem durumu.
  Amac: cok sayida kisa islem ve ic ice BEGIN gibi islem sayisi basincinda
  motorun NE YAPTIGINI olcmek. Bu surumde belgelenen davranis:
    - oturum basina EN FAZLA BIR acik islem vardir; ic ice BEGIN sessiz ve
      zararsiz bir no-op'tur (ikinci bir islem katmani ACILMAZ),
    - islem yokken COMMIT ve ROLLBACK zararsiz no-op'tur,
    - yuzlerce kisa islem sessizce kaybolmaz (commit sayisi birebir tutar),
    - dosya basina TEK yazar rezervasyonu vardir: bir oturum yazarken digeri
      kisa busy suresiyle kontrollu 'mesgul' hatasi alir; veri kaybi olmaz ve
      rezervasyon birakilinca islem yeniden denenebilir,
    - temiz kapanis tek dosya birakir; yeniden acilista TUM onayli satirlar
      durur ve VERIFY temizdir.

  Olculen:
    TL1 ic ice BEGIN sessiz no-op; tek COMMIT iki satiri da kalici yazar
    TL2 islem yokken COMMIT zararsiz no-op
    TL3 islem yokken ROLLBACK zararsiz no-op
    TL4 300 kisa islem: tamami kalici
    TL5 300 islem, 75 ROLLBACK: yalniz 225 kalici
    TL6 yazar cakismasi kontrollu hata verir; birakilinca tekrar denenir
    TL7 temiz kapanis tek dosya birakir
    TL8 yeniden acilis + tam VERIFY

  Derleme: fpc. Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbPageEngine,
  VDbTable, VDbSql, VDbErr;

const
  BASE_ROWS = 20;
  BULK_ROWS = 300;
  MIX_ROWS = 300;
  MIX_KEEP = 225;      { 300 satirdan her 4.'sü geri alinir -> 225 kalir }
  OTHER_ROWS = 30;

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
begin
  Result := 'x' + IntToStr(AId);
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

{ Cumleyi calistirir; kontrollu hata olursa hata adini dondurur, basarida ''.
  Beklenmeyen sinif da adiyla dondurulur (test bunu ayirt eder). }
function TryExecCode(Sq: TVSql; const ASql: string): string;
begin
  Result := '';
  try
    Sq.Exec(ASql);
  except
    on E: EVDbException do
      Result := VDbErrorName(E.ErrorCode);
    on E: Exception do
      Result := E.ClassName;
  end;
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
  AC, BC: TVdbBackendV3;
  A, B: IVdbBackend;
  TbA, TbB: TVTableDb;
  SqA, SqB: TVSql;
  i, rc: Integer;
  code, detail, rep, msg: string;
  raised: Boolean;
  n: Int64;

begin
  GPass := 0;
  GFail := 0;
  Dir := IncludeTrailingPathDelimiter(
    ExtractFilePath(ParamStr(0)) + 'tmp/tl');
  WipeDir(Dir);
  Db := IncludeTrailingPathDelimiter(Dir) + 'tl.odb';
  AC := nil;
  BC := nil;
  A := nil;
  B := nil;

  try
    AC := TVdbBackendV3.Create(Db, True, 512, 4000);
    A := AC;
    TbA := TVTableDb.CreateBackend(A);
    TbA.Open(Dir);
    SqA := TVSql.Create(TbA);
    try
      SqA.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      SqA.Exec('BEGIN');
      for i := 1 to BASE_ROWS do Ins(SqA, i);
      SqA.Exec('COMMIT');

      { TL1: ic ice BEGIN. Belgelenen davranis: no-op, ikinci islem katmani
        acilmaz; tek COMMIT her iki satiri da kalici yazmalidir. }
      SqA.Exec('BEGIN');
      code := TryExecCode(SqA, 'BEGIN');
      Chk('TL1 ic ice BEGIN sessiz no-op', code = '', 'kod=' + code);
      Ins(SqA, 21);
      Ins(SqA, 22);
      code := TryExecCode(SqA, 'COMMIT');
      Chk('TL1b tek COMMIT islemi kapatti', code = '', 'kod=' + code);
      n := QInt(SqA, 'SELECT COUNT(*) FROM t');
      Chk('TL1c tek islem katmani: iki satir da kalici',
        n = BASE_ROWS + 2, 'satir=' + IntToStr(n) + '/' +
        IntToStr(BASE_ROWS + 2));

      { TL2: islem yokken COMMIT zararsiz no-op. }
      code := TryExecCode(SqA, 'COMMIT');
      Chk('TL2 islem yokken COMMIT zararsiz', code = '', 'kod=' + code);
      n := QInt(SqA, 'SELECT COUNT(*) FROM t');
      Chk('TL2b COMMIT no-op veriyi degistirmedi', n = BASE_ROWS + 2,
        'satir=' + IntToStr(n));

      { TL3: islem yokken ROLLBACK zararsiz no-op olmali. }
      code := TryExecCode(SqA, 'ROLLBACK');
      Chk('TL3 islem yokken ROLLBACK zararsiz', code = '', 'kod=' + code);
      n := QInt(SqA, 'SELECT COUNT(*) FROM t');
      Chk('TL3b ROLLBACK no-op veriyi silmedi', n = BASE_ROWS + 2,
        'satir=' + IntToStr(n));

      { TL4: 300 kisa islem. }
      for i := 1000 to 1000 + BULK_ROWS - 1 do
      begin
        SqA.Exec('BEGIN');
        Ins(SqA, i);
        SqA.Exec('COMMIT');
      end;
      n := QInt(SqA, 'SELECT COUNT(*) FROM t WHERE id >= 1000 AND id < 2000');
      Chk('TL4 300 kisa islem tamami kalici', n = BULK_ROWS,
        'satir=' + IntToStr(n) + '/' + IntToStr(BULK_ROWS));

      { TL5: 300 islem; her 4.'sü ROLLBACK. }
      for i := 2000 to 2000 + MIX_ROWS - 1 do
      begin
        SqA.Exec('BEGIN');
        Ins(SqA, i);
        if (i mod 4) = 0 then
          SqA.Exec('ROLLBACK')
        else
          SqA.Exec('COMMIT');
      end;
      n := QInt(SqA, 'SELECT COUNT(*) FROM t WHERE id >= 2000 AND id < 3000');
      Chk('TL5 geri alinan islemler kalici olmadi', n = MIX_KEEP,
        'satir=' + IntToStr(n) + '/' + IntToStr(MIX_KEEP));

      { TL6: dosya basina TEK yazar rezervasyonu. A acik islem tutarken B
        kisa busy suresiyle kontrollu 'mesgul' hatasi almali; A commit
        ettikten sonra B ayni islemi sorunsuz tamamlayabilmeli. }
      BC := TVdbBackendV3.Create(Db, False, 512, 250);
      B := BC;
      TbB := TVTableDb.CreateBackend(B);
      TbB.Open(Dir);
      SqB := TVSql.Create(TbB);

      SqA.Exec('BEGIN');
      Ins(SqA, 3001);

      raised := False;
      msg := '';
      try
        SqB.Exec('BEGIN');
        Ins(SqB, 3100);
        SqB.Exec('COMMIT');
      except
        on E: Exception do
        begin
          raised := True;
          msg := E.ClassName + ': ' + E.Message;
        end;
      end;
      Chk('TL6 yazar cakismasi kontrollu hata verdi', raised,
        'mesaj=' + msg);
      Chk('TL6b hata mesaji mesgul/kilit bildiriyor',
        raised and
        ((Pos('mesgul', LowerCase(msg)) > 0) or
         (Pos('kilit', LowerCase(msg)) > 0) or
         (Pos('busy', LowerCase(msg)) > 0)),
        'mesaj=' + msg);
      { Yarim kalan B islemi geri alinir; veri kaybi yok. }
      code := TryExecCode(SqB, 'ROLLBACK');
      Chk('TL6c cakisma sonrasi ROLLBACK zararsiz', code = '', 'kod=' + code);

      { Rezervasyonu tutan A commit eder. }
      code := TryExecCode(SqA, 'COMMIT');
      Chk('TL6d rezervasyon sahibi A commit etti', code = '', 'kod=' + code);

      { A artik rezervasyon tutmuyor: B ayni islemi tekrar deneyebilmeli. }
      for i := 3100 to 3100 + OTHER_ROWS - 1 do
      begin
        SqB.Exec('BEGIN');
        Ins(SqB, i);
        SqB.Exec('COMMIT');
      end;
      n := QInt(SqB, 'SELECT COUNT(*) FROM t WHERE id >= 3000');
      Chk('TL6e birakilinca ikinci oturum tamamlayabildi',
        n = 1 + OTHER_ROWS, 'satir=' + IntToStr(n) + '/' +
        IntToStr(1 + OTHER_ROWS));

      FreeAndNil(SqB);
      FreeAndNil(TbB);
      B := nil;
      BC := nil;

      { TL7 hazirlik: checkpoint ve temiz kapanis. }
      Chk('TL7 checkpoint basarili', AC.Engine.Checkpoint(True), '');
    finally
      FreeAndNil(SqA);
    end;
  finally
    FreeAndNil(TbA);
    A := nil;
    AC := nil;
  end;

  Chk('TL7b temiz kapanis yalniz .odb birakir',
    (not FileExists(Db + '.wal')) and (not FileExists(Db + '.gen')) and
    (not FileExists(Db + '.idx')),
    'wal=' + BoolToStr(FileExists(Db + '.wal'), True) + ' gen=' +
    BoolToStr(FileExists(Db + '.gen'), True));

  { TL8: yeniden acilis + tam VERIFY. }
  n := BASE_ROWS + 2 + BULK_ROWS + MIX_KEEP + 1 + OTHER_ROWS;
  rc := ReopenScan(Dir, Db, Integer(n), detail);
  Chk('TL8 yeniden acilis: tum onayli satirlar duruyor', rc = -1,
    detail + ' beklenen=' + IntToStr(n));
  Chk('TL8b VERIFY temiz', VerifyDb(Db, rep), 'rapor=' + rep);

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
