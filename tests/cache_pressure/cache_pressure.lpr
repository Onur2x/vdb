program cache_pressure;
{ v3.38 KALICI REGRESYON KAPISI - SKILL3 §12.1 "cache exhaustion".
  Amac: sayfa havuzu tablodan KUCUKKEN (8 sayfa) motorun dogru calistigini
  olcmek. Onbellek tukenmesi bir "limit hatasi" degil, normal isletim
  durumudur: tahliye (evict) + yeniden yukleme sessiz veri kaybi
  uretmemelidir. Kirli sayfa tahliyesi WAL'e dokulur; commit sonrasi
  yeniden acilista veri bozulmamis olmalidir.

  Olculen:
    CP1 kucuk havuz istegi kabul edilir ve raporlanir
    CP2 buyuk tablo yazilir (havuzdan cok daha fazla sayfa)
    CP3 kucuk havuzla tam tarama TUM satirlari dogru okur (tahliye+yukleme)
    CP4 tarama boyunca PoolUsed <= PoolPages (havuz gercekten sinirli)
    CP5 miss sayaci havuz boyunun cok uzerinde (gercekten tahliye oldu)
    CP6 tek islemde tum satirlar guncellenir (kirli tahliye yolu)
    CP7 temiz kapanistan sonra yalniz .odb kalir
    CP8 commit + kapanis + yeniden acilis sonrasi guncel veri kalici

  Derleme: fpc. Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbPageStore,
  VDbTable, VDbSql, VDbErr;

const
  ROWS = 2000;
  POOL = 8;          { 8 x 4 KB = 32 KB havuz; tablo ~100+ sayfa }
  VALLEN = 200;

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

{ Deterministik deger: ayni id her zaman ayni metni uretir, boylece
  yeniden acilistan sonra icerik karsilastirmasi kesin olur. }
function ValOf(AId: Integer; const APrefix: string): string;
var
  i: Integer;
  k: Integer;
begin
  SetLength(Result, VALLEN);
  k := AId mod 26;
  for i := 1 to VALLEN do
    Result[i] := Chr(Ord('a') + ((k + i) mod 26));
  Result := APrefix + IntToStr(AId) + ':' + Result;
end;

procedure WipeDir(const D: string);
var
  sr: TSearchRec;
begin
  ForceDirectories(D);
  if FindFirst(D + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        SysUtils.DeleteFile(D + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function TrimCell(const S: string): string;
begin
  Result := Trim(S);
end;

var
  D, DBPath: string;
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  cs, csEnd: TVdbCacheStats;
  r: TSqlResult;
  i, bad, total: Integer;
  ok: Boolean;
  v: string;

{ Tabloyu kucuk havuzla bastan sona tarar; her satirin icerigi ve sirasi
  dogru mu diye bakar. Donus: uyusmayan satir sayisi (0 = kusursuz). }
function ScanAndVerify(const APrefix: string; out ACount: Integer): Integer;
var
  j: Integer;
  id: Integer;
begin
  Result := 0;
  ACount := 0;
  r := Sq.Exec('SELECT id, v FROM t ORDER BY id');
  ACount := Length(r.Rows);
  for j := 0 to Length(r.Rows) - 1 do
  begin
    if Length(r.Rows[j]) < 2 then
    begin
      Inc(Result);
      Continue;
    end;
    id := StrToIntDef(TrimCell(r.Rows[j][0]), -1);
    v := TrimCell(r.Rows[j][1]);
    if (id <> j + 1) or (v <> ValOf(id, APrefix)) then
      Inc(Result);
  end;
end;

begin
  GPass := 0;
  GFail := 0;

  D := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp/cp');
  WipeDir(D);
  DBPath := D + 'cache_pressure.odb';

  { CP1: kucuk havuz istegi kabul edilir. }
  BeC := TVdbBackendV3.Create(DBPath, True, POOL, 2000);
  Be := BeC;
  try
    cs := BeC.GetCacheStats;
    Chk('CP1 kucuk havuz kabul edildi', cs.PoolPages = POOL,
      'pool=' + IntToStr(cs.PoolPages));

    Tb := TVTableDb.CreateBackend(Be);
    try
      Tb.Open(D);
      Sq := TVSql.Create(Tb);
      try
        Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');

        { CP2: havuzdan cok daha buyuk tablo. }
        Sq.Exec('BEGIN');
        for i := 1 to ROWS do
          Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
            StringReplace(ValOf(i, 'a'), '''', '''''', [rfReplaceAll]) + ''')');
        Sq.Exec('COMMIT');
        total := 0;
        bad := ScanAndVerify('a', total);
        Chk('CP2 havuzdan buyuk tablo yazildi', total = ROWS,
          'satir=' + IntToStr(total));

        { CP3/CP4/CP5: tahliye altinda tam tarama. }
        Chk('CP3 kucuk havuzla tam tarama kusursuz', bad = 0,
          'uyusmayan=' + IntToStr(bad));
        csEnd := BeC.GetCacheStats;
        Chk('CP4 havuz kullanimi tavanini asmadi',
          (csEnd.PoolUsed <= csEnd.PoolPages) and (csEnd.PoolPages = POOL),
          'used=' + IntToStr(csEnd.PoolUsed) + '/' + IntToStr(csEnd.PoolPages));
        Chk('CP5 gercek tahliye oldu (miss >> havuz)',
          csEnd.Misses > Int64(POOL) * 4,
          'misses=' + IntToStr(csEnd.Misses));

        { CP6: kirli sayfa tahliyesi - tek islemde tum satirlar. }
        Sq.Exec('BEGIN');
        for i := 1 to ROWS do
          Sq.Exec('UPDATE t SET v = ''' +
            StringReplace(ValOf(i, 'u'), '''', '''''', [rfReplaceAll]) +
            ''' WHERE id = ' + IntToStr(i));
        Sq.Exec('COMMIT');
        bad := ScanAndVerify('u', total);
        Chk('CP6 tek islemde tum guncelleme dogru', (bad = 0) and (total = ROWS),
          'uyusmayan=' + IntToStr(bad) + ' satir=' + IntToStr(total));
      finally
        FreeAndNil(Sq);
      end;
    finally
      FreeAndNil(Tb);
    end;
  finally
    { Interface ve nesne ayni omru paylasir: once interface birakilir,
      yoksa cift serbest birakma olur. }
    Be := nil;
    BeC := nil;
  end;

  { CP7: temiz kapanis - yan dosyalar silinmis olmali. }
  ok := (not FileExists(DBPath + '.wal')) and (not FileExists(DBPath + '.gen'));
  Chk('CP7 temiz kapanistan sonra yalniz .odb kalir', ok,
    'wal=' + BoolToStr(FileExists(DBPath + '.wal'), True) +
    ' gen=' + BoolToStr(FileExists(DBPath + '.gen'), True));

  BeC := TVdbBackendV3.Create(DBPath, False, POOL, 2000);
  Be := BeC;
  try
    Tb := TVTableDb.CreateBackend(Be);
    try
      Tb.Open(D);
      Sq := TVSql.Create(Tb);
      try
        bad := ScanAndVerify('u', total);
        Chk('CP8 yeniden acilista guncel veri kalici',
          (bad = 0) and (total = ROWS),
          'uyusmayan=' + IntToStr(bad) + ' satir=' + IntToStr(total));
      finally
        FreeAndNil(Sq);
      end;
    finally
      FreeAndNil(Tb);
    end;
  finally
    Be := nil;
    BeC := nil;
  end;

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
