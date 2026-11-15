program cache_metrics;
{ VDB V3 sertlestirme - SKILL2 §20.2 (G2) kapisi: ONBELLEK METRIKLERI.

Amac: metriklerin YALNIZ VAR OLMASI degil, GERCEKTEN HAREKET ETMESI.
Her kontrol bir sayacin is yaptiginda arttigini (ya da is bitince sifira
dondugunu) olcer; sabit/sahte deger kapiyi kirar.

Denetlenenler:
  * hit/miss sayaclari okuma trafigiyle ARTAR
  * kirli sayfa sayisi yazidan sonra > 0, checkpoint'ten sonra = 0
  * flush sayaci / yazilan sayfa sayisi checkpoint'te ARTAR
  * flush suresi (son + toplam) mantikli (toplam >= son, son >= 0)
  * hit ratio aritmetigi: hits/(hits+misses), 0..1 araliginda
  * Prometheus ciktisi (MetricsText) ayni degerleri tasir
  * SHOW STATS (SQL) ayni degerleri satir olarak yayinlar

Derleme: fpc (lpi gerekmez). Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbPageEngine,
  VDbPageStore, VDbTable, VDbSql, VDbErr;

const
  ROWS = 200;

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

procedure Info(const S: string);
begin
  WriteLn('BILGI ', S);
  Flush(Output);
end;

function MkVal(AKey: Integer): string;
var
  i: Integer;
begin
  SetLength(Result, 120);
  for i := 1 to Length(Result) do
    Result[i] := Chr(Ord('a') + ((AKey + i) mod 26));
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

function RatioOf(const cs: TVdbCacheStats): Double;
begin
  if (cs.Hits + cs.Misses) > 0 then
    Result := cs.Hits / (cs.Hits + cs.Misses)
  else
    Result := 0;
end;

{ MetricsText icindeki tek bir metrigin degerini dondurur ('' = yok). }
function MetricText(const AText, AName: string): string;
var
  sl: TStringList;
  i, p: Integer;
  line: string;
begin
  Result := '';
  sl := TStringList.Create;
  try
    sl.Text := AText;
    for i := 0 to sl.Count - 1 do
    begin
      line := Trim(sl[i]);
      if (line = '') or (line[1] = '#') then Continue;
      p := Pos(' ', line);
      if p = 0 then Continue;
      if Copy(line, 1, p - 1) = AName then
        Exit(Trim(Copy(line, p + 1, Length(line))));
    end;
  finally
    sl.Free;
  end;
end;

{ SHOW STATS sonucunda ad -> deger ('' = yok). }
function StatText(const R: TSqlResult; const AName: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to Length(R.Rows) - 1 do
    if (Length(R.Rows[i]) = 2) and (R.Rows[i][0] = AName) then
      Exit(R.Rows[i][1]);
end;

var
  D, DBPath: string;
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  r: TSqlResult;
  cs0, cs1, cs2, cs3: TVdbCacheStats;
  txt: string;
  i: Integer;
  dv: Double;
  sv: string;
begin
  GPass := 0;
  GFail := 0;

  D := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp/cm');
  WipeDir(D);
  DBPath := D + 'cache_metrics.odb';

  BeC := TVdbBackendV3.Create(DBPath);
  Be := BeC;
  try
    cs0 := BeC.GetCacheStats;
    Chk('CM1 destekli', cs0.Supported, 'Supported=' + BoolToStr(cs0.Supported, True));
    Chk('CM1 havuz', cs0.PoolPages >= 8,
      'pool=' + IntToStr(cs0.PoolPages));
    Info('CM1 baslangic hits=' + IntToStr(cs0.Hits) + ' misses=' +
      IntToStr(cs0.Misses) + ' dirty=' + IntToStr(cs0.DirtyPages) +
      ' flush=' + IntToStr(cs0.FlushCount));

    Tb := TVTableDb.CreateBackend(Be);
    try
      Tb.Open(D);
      Sq := TVSql.Create(Tb);
      try
        Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
        for i := 1 to ROWS do
          Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
            MkVal(i) + ''')');
        for i := 1 to 20 do
          Sq.Exec('SELECT v FROM t WHERE id = ' + IntToStr(i));

        cs1 := BeC.GetCacheStats;
        { Sayaclar OKUMA trafigiyle artmali: sabit metrik kapiyi kirar. }
        Chk('CM2 hit/miss hareket etti',
          (cs1.Hits + cs1.Misses) > (cs0.Hits + cs0.Misses),
          'hits=' + IntToStr(cs1.Hits) + ' misses=' + IntToStr(cs1.Misses));
        Chk('CM2 hit ratio araligi',
          (RatioOf(cs1) >= 0) and (RatioOf(cs1) <= 1),
          FormatFloat('0.0000', RatioOf(cs1)));

        { Yazidan sonra (checkpoint yapilmadan) kirli sayfa olmali. }
        Chk('CM3 kirli sayfa > 0', cs1.DirtyPages > 0,
          'dirty=' + IntToStr(cs1.DirtyPages));

        { Checkpoint: tum kirli cerceveler diske iner. }
        BeC.Engine.Checkpoint(True);
        cs2 := BeC.GetCacheStats;
        Chk('CM3 checkpoint sonrasi kirli = 0', cs2.DirtyPages = 0,
          'dirty=' + IntToStr(cs2.DirtyPages));
        Chk('CM4 flush sayaci artti', cs2.FlushCount > cs1.FlushCount,
          IntToStr(cs1.FlushCount) + ' -> ' + IntToStr(cs2.FlushCount));
        Chk('CM4 yazilan sayfa sayisi artti', cs2.FlushPages > cs1.FlushPages,
          IntToStr(cs1.FlushPages) + ' -> ' + IntToStr(cs2.FlushPages));
        Chk('CM4 flush suresi mantikli',
          (cs2.FlushLastMs >= 0) and (cs2.FlushTotalMs >= cs2.FlushLastMs),
          'last=' + IntToStr(cs2.FlushLastMs) + ' total=' +
          IntToStr(cs2.FlushTotalMs));

        { Checkpoint'ten SONRA yazmak yeniden kirli sayfa uretmeli. }
        for i := ROWS + 1 to ROWS + 10 do
          Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
            MkVal(i) + ''')');
        cs3 := BeC.GetCacheStats;
        Chk('CM5 yeni yazi kirletti', cs3.DirtyPages > 0,
          'dirty=' + IntToStr(cs3.DirtyPages));

        { Prometheus ciktisi ayni gercek degerleri tasimali.
          DIKKAT: FPC parametreleri SOLDAN degil SAGDAN degerlendirir; bu
          yuzden degerler ONCE yerel degiskene alinir, sonra Chk cagrilir.
          (Aksi halde `out` parametreli bir cagriyi kosulda kullanmak,
          kosul calistiktan sonra basilan ayrintiyi eski degerle birakir.) }
        txt := BeC.MetricsText;
        sv := MetricText(txt, 'vdb_v3_page_cache_hit_ratio');
        dv := StrToFloatDef(sv, -1);
        Chk('CM6 metrics hit orani', Abs(dv - RatioOf(cs3)) <= 0.01,
          sv + ' beklenen ' + FormatFloat('0.0000', RatioOf(cs3)));
        sv := MetricText(txt, 'vdb_v3_page_cache_dirty_pages');
        Chk('CM6 metrics kirli sayfa', StrToIntDef(sv, -1) = cs3.DirtyPages,
          sv + ' beklenen ' + IntToStr(cs3.DirtyPages));
        sv := MetricText(txt, 'vdb_v3_page_flushes_total');
        Chk('CM6 metrics flush sayaci', StrToInt64Def(sv, -1) = cs3.FlushCount,
          sv + ' beklenen ' + IntToStr(cs3.FlushCount));
        sv := MetricText(txt, 'vdb_v3_page_flush_pages_total');
        Chk('CM6 metrics flush sayfalari',
          StrToInt64Def(sv, -1) = cs3.FlushPages,
          sv + ' beklenen ' + IntToStr(cs3.FlushPages));

        { SHOW STATS: ayni metrikler SQL'den de okunabilmeli. }
        r := Sq.Exec('SHOW STATS');
        sv := StatText(r, 'cache_hits');
        Chk('CM7 SHOW STATS cache_hits', StrToInt64Def(sv, -1) = cs3.Hits,
          sv + ' beklenen ' + IntToStr(cs3.Hits));
        sv := StatText(r, 'cache_hit_ratio');
        Chk('CM7 SHOW STATS hit ratio',
          Abs(StrToFloatDef(sv, -1) - RatioOf(cs3)) <= 0.01,
          sv + ' beklenen ' + FormatFloat('0.0000', RatioOf(cs3)));
        sv := StatText(r, 'cache_dirty_pages');
        Chk('CM7 SHOW STATS kirli sayfa', StrToIntDef(sv, -1) = cs3.DirtyPages,
          sv + ' beklenen ' + IntToStr(cs3.DirtyPages));
        sv := StatText(r, 'page_flushes');
        Chk('CM7 SHOW STATS flush', StrToInt64Def(sv, -1) = cs3.FlushCount,
          sv + ' beklenen ' + IntToStr(cs3.FlushCount));
        sv := StatText(r, 'page_flush_pages');
        Chk('CM7 SHOW STATS flush sayfalari',
          StrToInt64Def(sv, -1) = cs3.FlushPages,
          sv + ' beklenen ' + IntToStr(cs3.FlushPages));
        sv := StatText(r, 'cache_pool_pages');
        Chk('CM7 SHOW STATS havuz', StrToIntDef(sv, -1) = cs3.PoolPages,
          sv + ' beklenen ' + IntToStr(cs3.PoolPages));

        { Kapanis: temiz kapanista tum kirli sayfalar yazilir. }
        Tb.Close;
      finally
        Sq.Free;
      end;
    finally
      Tb.Free;
    end;
  finally
    Be := nil;
    BeC := nil;
  end;

  { Yeniden acilis: sayaclar sifirdan baslar (metrikler oturumluktur). }
  BeC := TVdbBackendV3.Create(DBPath, False);
  Be := BeC;
  try
    cs0 := BeC.GetCacheStats;
    Chk('CM8 yeniden acilis', cs0.Supported and (cs0.FlushCount = 0) and
      (cs0.DirtyPages = 0),
      'flush=' + IntToStr(cs0.FlushCount) + ' dirty=' +
      IntToStr(cs0.DirtyPages));
  finally
    Be := nil;
    BeC := nil;
  end;

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
