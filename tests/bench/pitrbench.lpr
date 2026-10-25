program pitrbench;
{ v4 OLCUM: mantiksal degisim gunlugunun yazma maliyeti ve PITR
  okuma/kurtarma/arsiv sureleri. Yalnizca OLCULEN degerler basilir.

  Kullanim: pitrbench <dizin> [satir] [grup]
    - satir sayisi, grup sayisina bolunur; her grup AYRI commit'tir.
    - Yazma: toplam sure + satir basina / commit basina.
    - Gunluk: <db>.log altindaki toplam bayt ve satir basina bayt.
    - AS OF TIMESTAMP: 3 kosu, her kosuda tam sayim dogrulanir.
    - BuildLogSnapshot: hedef noktadaki kurtarma dosyasi, olculen sure.
    - ArchiveLogSet: gunlugun tam kopyasi, olculen sure.
  Sure olcumu QPC (NowUs, mikrosaniye). }
{$mode delphi}{$H+}
uses
  SysUtils, Classes, VDbBackendApi, VDbBackendV3, VDbTable,
  VDbSql, VDbTypes, VDbChangeLog;

{ QPC icin Windows birimini kullanmiyoruz: `Windows` FindFirst/DeleteFile
  gibi isimleri PChar/LongWord imzasiyla golgeliyor ve bu dosyada
  SysUtils surumleri gerekiyor. }
function QueryPerformanceCounter(out C: Int64): LongBool; stdcall;
  external 'kernel32' name 'QueryPerformanceCounter';
function QueryPerformanceFrequency(out F: Int64): LongBool; stdcall;
  external 'kernel32' name 'QueryPerformanceFrequency';

var
  gQpf: Int64 = 0;
  gDir: string;

function NowUs: Int64;
var
  c: Int64;
begin
  if gQpf = 0 then
    if not QueryPerformanceFrequency(gQpf) then gQpf := 1000;
  QueryPerformanceCounter(c);
  if gQpf >= 1000000 then
    Result := c div (gQpf div 1000000)
  else if gQpf >= 1000 then
    Result := (c * 1000) div gQpf
  else
    Result := c * 1000;
end;

function DirSize(const Dir: string): Int64;
var
  sr: TSearchRec;
  p: string;
begin
  Result := 0;
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      p := IncludeTrailingPathDelimiter(Dir) + sr.Name;
      if (sr.Attr and faDirectory) <> 0 then
        Result := Result + DirSize(p)
      else
        Result := Result + sr.Size;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

function FileLen(const P: string): Int64;
var
  f: TFileStream;
begin
  Result := 0;
  if not FileExists(P) then Exit;
  try
    f := TFileStream.Create(P, fmOpenRead or fmShareDenyNone);
    try
      Result := f.Size;
    finally
      f.Free;
    end;
  except
    Result := 0;
  end;
end;

function Cel(const R: TSqlResult; Row, Col: Integer): string;
begin
  if (Row > High(R.Rows)) or (Col > High(R.Rows[Row])) then Exit('?');
  Result := R.Rows[Row][Col];
end;

var
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  R: TSqlResult;
  i, nRows, groups, perGroup, g: Integer;
  t0, t1: Int64;
  logBytes, log0, total0, total1: Int64;
  seq, ts, mnSeq, mxSeq, mnTs, mxTs: Int64;
  bases, runs, good: Integer;
  dest, tsText: string;
  ok: Boolean;
  sum: Double;

begin
  if ParamCount >= 1 then
    gDir := ParamStr(1)
  else
    gDir := GetCurrentDir;
  nRows := 20000;
  groups := 100;
  if ParamCount >= 2 then nRows := StrToIntDef(ParamStr(2), nRows);
  if ParamCount >= 3 then groups := StrToIntDef(ParamStr(3), groups);
  if groups < 1 then groups := 1;
  perGroup := nRows div groups;
  if perGroup < 1 then perGroup := 1;
  nRows := perGroup * groups;

  ForceDirectories(gDir);
  Be := TVdbBackendV3.Create(IncludeTrailingPathDelimiter(gDir) + 'bench.odb',
    True, 256);
  Tb := TVTableDb.CreateBackend(Be);
  Sq := TVSql.Create(Tb);
  Tb.Open(gDir);
  try
    Sq.Exec('CREATE TABLE b (id INTEGER PRIMARY KEY, n INTEGER, s TEXT)');
    log0 := DirSize(Be.FilePath + '.log');
    total0 := DirSize(gDir);
    WriteLn('taban sonrasi gunluk: ', log0, ' bayt');

    t0 := NowUs;
    for g := 1 to groups do
    begin
      Sq.Exec('BEGIN');
      for i := 1 to perGroup do
        Sq.Exec(Format('INSERT INTO b VALUES (%d,%d,%s)',
          [(g - 1) * perGroup + i, i mod 97,
           QuotedStr('s' + IntToStr(i mod 50))]));
      Sq.Exec('COMMIT');
    end;
    t1 := NowUs;
    WriteLn(Format('yazma: %d satir / %d commit = %.0f ms (%.1f us/satir, %.2f ms/commit)',
      [nRows, groups, (t1 - t0) / 1000, (t1 - t0) / nRows,
       (t1 - t0) / 1000 / groups]));

    logBytes := DirSize(Be.FilePath + '.log');
    total1 := DirSize(gDir);
    WriteLn(Format('gunluk: %d bayt toplam, satir basina %.1f bayt',
      [logBytes, (logBytes - log0) / nRows]));
    WriteLn(Format('veri dosyasi (.odb): %d bayt; dizin toplami (gunluk haric): %d bayt',
      [FileLen(Be.FilePath), total1 - logBytes]));

    R := Sq.Exec('SELECT COUNT(*) FROM b');
    WriteLn('dogrulama satir sayisi: ', Cel(R, 0, 0), ' (beklenen ',
      IntToStr(nRows), ')');

    if Be.LogRangeInfo(mnSeq, mxSeq, mnTs, mxTs, bases) then
    begin
      WriteLn(Format('gunluk kapsami: seq %d..%d, taban=%d', [mnSeq, mxSeq, bases]));
      tsText := VdbLogFormatTimestamp(mxTs);
      sum := 0; good := 0; runs := 3;
      for i := 1 to runs do
      begin
        t0 := NowUs;
        R := Sq.Exec('SELECT COUNT(*) FROM b AS OF TIMESTAMP ''' + tsText + '''');
        t1 := NowUs;
        sum := sum + (t1 - t0) / 1000;
        if Cel(R, 0, 0) = IntToStr(nRows) then Inc(good);
      end;
      WriteLn(Format('AS OF TIMESTAMP ''%s'': %d kosu, ortalama %.0f ms, dogru %d/%d',
        [tsText, runs, sum / runs, good, runs]));
    end
    else
      WriteLn('gunluk araligi okunamadi: ', Be.LogStatus);

    dest := Be.FilePath + '.bench_recovered';
    if FileExists(dest) then SysUtils.DeleteFile(dest);
    t0 := NowUs;
    ok := Be.BuildLogSnapshot(0, 0, dest, ts, seq);
    t1 := NowUs;
    WriteLn(Format('BuildLogSnapshot (son durum): %.0f ms, basarili=%s, dosya=%d bayt, seq=%d',
      [(t1 - t0) / 1000, BoolToStr(ok, True), FileLen(dest), seq]));

    if FileExists(dest) then SysUtils.DeleteFile(dest);
    t0 := NowUs;
    logBytes := Be.ArchiveLogSet(IncludeTrailingPathDelimiter(gDir) + 'arsiv');
    t1 := NowUs;
    WriteLn(Format('ArchiveLogSet: %.0f ms, %d bayt kopyalandi',
      [(t1 - t0) / 1000, logBytes]));
  finally
    Sq.Free;
    Tb.Close;
    Tb.Free;
    Be := nil;
  end;
end.
