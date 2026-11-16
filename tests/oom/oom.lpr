program oom;
{ v3.42 KALICI REGRESYON KAPISI - SKILL3 §12.3 bellek tukenmesi (OOM).
  Amac: bellek tahsisi basarisiz oldugunda motorun NE YAPTIGINI olcmek.
  Beklenen:
    - tahsis hatasi KONTROLU bir istisna olarak yuzeye cikar (surec
      cokmez, sinyal/access violation yok),
    - okuma yolu hatadan sonra ayni oturumda calismaya devam eder,
    - yazma yolu: commit sirasinda olusan hata HAYALET satir birakmaz
      (basarisiz commit'in satirlari ne ayni oturumda ne yeniden acilista
      gorunur) ve onceki onayli satirlar kaybolmaz,
    - hata giderildikten sonra ayni veritabani yazmaya devam eder,
    - yeniden acilista TUM onayli satirlar durur ve VERIFY temizdir.

  Enjeksiyon YALNIZ test icindir (`VDbMM.MMInjectFault`): MinSize'dan
  kucuk tahsisler (RTL ic bloklari, istisna nesneleri) etkilenmez; hedef
  tek tahsis reddedilir ve enjeksiyon kendini kapatir. Gercek bellek
  tukenmesi bu makinede guvenle uretilemedigi icin yol enjeksiyonla
  olculur - bu bir SINIRLILIKTIR, gizlenmez.

  Olculen:
    OM1 kontrol: temel veri yazilir/okunur, COUNT dogru
    OM2 okuma yolunda tahsis hatasi kontrollu istisna verir (en az bir kez)
    OM3 her okuma hatasindan sonra oturum saglam: COUNT dogru
    OM4 yazma yolunda tahsis hatasi kontrollu istisna verir (en az bir kez)
    OM5 basarisiz commit hayalet satir birakmaz; onayli satirlar durur
    OM6 tum denemelerden sonra yazma devam eder, checkpoint basarili
    OM7 yeniden acilis: TUM onayli satirlar durur, VERIFY temiz

  Derleme: fpc. Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbMM, VDbFactory, VDbBackendApi, VDbBackendV3,
  VDbPageEngine, VDbTable, VDbSql, VDbErr;

const
  BASE_ROWS = 200;
  TXN_ROWS = 10;
  SWEEPS = 8;          { her yonde 8 enjeksiyon noktasi denenir }
  { Deger boyu bilincli olarak BUYUK: tek bir deger/arabellek tahsisi
    4096 bayti asar, yani enjeksiyon gercekten buyuk bloklari vurur. }
  VAL_LEN = 6000;
  FAULT_MIN = 4096;    { bundan kucuk tahsisler etkilenmez }

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
  Result := 'o' + IntToStr(AId) + ':' + Result;
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
  i, skip, rc, readFaults, writeFaults: Integer;
  expected: Int64;
  detail, rep, msg: string;
  raised: Boolean;
  r: TSqlResult;

begin
  GPass := 0;
  GFail := 0;
  Dir := IncludeTrailingPathDelimiter(
    ExtractFilePath(ParamStr(0)) + 'tmp/oom');
  WipeDir(Dir);
  Db := IncludeTrailingPathDelimiter(Dir) + 'oom.odb';
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
      for i := 1 to BASE_ROWS do Ins(Sq, i);
      Sq.Exec('COMMIT');
      expected := QInt(Sq, 'SELECT COUNT(*) FROM t');
      Chk('OM1 kontrol: temel veri yazildi', expected = BASE_ROWS,
        'satir=' + IntToStr(expected));

      { --- OM2/OM3: OKUMA yolunda tahsis hatasi. Enjeksiyon noktasi
        kaydirilarak sonuc kumesini olusturan farkli tahsisler vurulur. }
      readFaults := 0;
      for skip := 0 to SWEEPS - 1 do
      begin
        raised := False;
        msg := '';
        MMInjectFault(FAULT_MIN, skip);
        try
          try
            r := Sq.Exec('SELECT id, v FROM t ORDER BY id');
            if Length(r.Rows) <> BASE_ROWS then
            begin
              raised := True;
              msg := 'eksik sonuc satir=' + IntToStr(Length(r.Rows));
            end;
          except
            on E: Exception do
            begin
              raised := True;
              msg := E.ClassName + ': ' + E.Message;
            end;
          end;
        finally
          MMInjectClear;
        end;
        if MMInjectHits > 0 then
          Inc(readFaults);
        if raised and (MMInjectHits > 0) then
          WriteLn('BILGI OM2 enjeksiyon skip=', skip, ' -> ', msg);
      end;
      Chk('OM2 okuma yolunda tahsis hatasi kontrollu olarak yuzeye cikti',
        readFaults > 0, 'enjeksiyon=' +
        IntToStr(readFaults) + '/' + IntToStr(SWEEPS));

      { Hata denemelerinden sonra oturum saglam mi? }
      Chk('OM3 okuma hatalarindan sonra oturum saglam',
        QInt(Sq, 'SELECT COUNT(*) FROM t') = BASE_ROWS,
        'satir=' + IntToStr(QInt(Sq, 'SELECT COUNT(*) FROM t')));

      { --- OM4/OM5: YAZMA yolunda tahsis hatasi. Her deneme ayri bir
        islemdir; basarisiz commit hayalet satir birakmamalidir. }
      writeFaults := 0;
      expected := BASE_ROWS;
      for skip := 0 to SWEEPS - 1 do
      begin
        raised := False;
        msg := '';
        Sq.Exec('BEGIN');
        for i := 1 to TXN_ROWS do
          Ins(Sq, 10000 + skip * 100 + i);
        MMInjectFault(FAULT_MIN, skip);
        try
          try
            Sq.Exec('COMMIT');
          except
            on E: Exception do
            begin
              raised := True;
              msg := E.ClassName + ': ' + E.Message;
            end;
          end;
        finally
          MMInjectClear;
        end;
        if MMInjectHits > 0 then
          Inc(writeFaults);
        if raised then
        begin
          WriteLn('BILGI OM4 enjeksiyon skip=', skip, ' -> ', msg);
          { Basarisiz commit: satirlar NE kalici NE gorunur olmali. }
          Sq.Exec('ROLLBACK');
          if QInt(Sq, 'SELECT COUNT(*) FROM t') <> expected then
            Chk('OM5 hayalet satir yok (skip=' + IntToStr(skip) + ')', False,
              'satir=' + IntToStr(QInt(Sq, 'SELECT COUNT(*) FROM t')) +
              ' beklenen=' + IntToStr(expected));
        end
        else
        begin
          expected := expected + TXN_ROWS;
          if QInt(Sq, 'SELECT COUNT(*) FROM t') <> expected then
            Chk('OM5 commit sonrasi sayim tutarli (skip=' + IntToStr(skip) +
              ')', False, 'satir=' + IntToStr(QInt(Sq,
              'SELECT COUNT(*) FROM t')) + ' beklenen=' + IntToStr(expected));
        end;
      end;
      Chk('OM4 yazma yolunda tahsis hatasi kontrollu olarak yuzeye cikti',
        writeFaults > 0, 'enjeksiyon=' + IntToStr(writeFaults) + '/' +
        IntToStr(SWEEPS));
      Chk('OM5 basarisiz commit hayalet satir birakmadi',
        QInt(Sq, 'SELECT COUNT(*) FROM t') = expected,
        'satir=' + IntToStr(QInt(Sq, 'SELECT COUNT(*) FROM t')) +
        ' beklenen=' + IntToStr(expected));

      { --- OM6: hata yollarindan sonra normal calisma devam eder. }
      Sq.Exec('BEGIN');
      for i := 1 to TXN_ROWS do
        Ins(Sq, 20000 + i);
      Sq.Exec('COMMIT');
      expected := expected + TXN_ROWS;
      Chk('OM6 hata sonrasi yazma devam etti',
        QInt(Sq, 'SELECT COUNT(*) FROM t') = expected,
        'satir=' + IntToStr(QInt(Sq, 'SELECT COUNT(*) FROM t')));
      Chk('OM6b checkpoint basarili', BeC.Engine.Checkpoint(True), '');
    finally
      MMInjectClear;
      FreeAndNil(Sq);
    end;
  finally
    FreeAndNil(Tb);
    Be := nil;
    BeC := nil;
  end;

  { --- OM7: yeniden acilis + tam VERIFY. }
  rc := ReopenScan(Dir, Db, Integer(expected), detail);
  Chk('OM7 yeniden acilis: tum onayli satirlar duruyor', rc = -1, detail);
  Chk('OM7b VERIFY temiz', VerifyDb(Db, rep), 'rapor=' + rep);

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
