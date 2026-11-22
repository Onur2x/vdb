program spill_core;
{ tests/spill_core - SKILL11: VDbSpill biriminin kendi kendine testi.

  Kapsam (hepsi saf Pascal, harici arac yok):
    SP1-SP6   kosu dosyasi yaz/oku: degerler, `''`, ACIK NULL ve
              "maskesi olmayan" satir AYNEN korunur (NULL semantigi kaybi yok)
    SP7-SP10  kararli siralama: esit anahtarlarda giris sirasi korunur
    SP11-SP14 k-yollu birlestirme: parca parca + birlestirme = tek seferde
              kararli siralama (esitlikler dahil, birebir)
    SP15-SP18 bellek muhasebesi: satir/matris bayti yalniz metin degil,
              dizi basligi + isaretci + StrRec de sayilir
    SP19-SP23 spill dizini: dizin + manifest icerigi, kosu kaydi, kapanista
              tam temizlik (dizin de silinir)
    SP24-SP27 artik (orphan) dizin: olu pid'in dizini toplanir, CANLI pid'in
              dizini ASLA silinmez, manifesti olmayan dizine dokunulmaz

  Not: `VDB_SPILL_DIR` bu testte gecici bir kok dizine yonlendirilir; boylece
  makinenin gercek %TEMP% dizini kirlenmez. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, VDbTypes, VDbTable, VDbSpill;

var
  GPass, GFail: Integer;
  GDir: string;

procedure Chk(const AName: string; AOk: Boolean; const ADetail: string = '');
begin
  if AOk then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' | ', ADetail);
  end;
end;

function SameRow(const A, B: TStrArray): Boolean;
var
  i: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then Exit;
  for i := 0 to High(A) do
    if A[i] <> B[i] then Exit(False);
end;

function SameNulls(const A, B: TNulArr): Boolean;
var
  i: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then Exit;
  for i := 0 to High(A) do
    if A[i] <> B[i] then Exit(False);
end;

procedure Wipe(const ADir: string);
begin
  if DirectoryExists(ADir) then VdbDeleteTree(ADir);
end;

{ ---------------- SP1-SP6: yaz/oku ---------------- }

procedure TestRoundTrip;
var
  dir: TVdbSpillDir;
  w: TVdbSpillWriter;
  r: TVdbSpillReader;
  p: string;
  r1, r2, r3, got: TStrArray;
  n2, n3, gn: TNulArr;
  ok: Boolean;
  dirName: string;
begin
  dir := TVdbSpillDir.Create(GDir + 'db1.odb');
  dirName := dir.Dir;
  try
    p := dir.NewRunPath;
    w := TVdbSpillWriter.Create(p, 3);
    try
      { 1) maskesiz satir: '' = "bilinmiyor" olarak kalmali }
      r1 := nil;
      SetLength(r1, 3);
      r1[0] := '';
      r1[1] := 'abc';
      r1[2] := '0123456789';
      w.WriteRow(r1, nil);
      { 2) maskeli satir: acik NULL + '' (NULL DEGIL) }
      SetLength(r2, 3);
      r2[0] := '';
      r2[1] := '';
      r2[2] := 'x';
      SetLength(n2, 3);
      n2[0] := True;
      n2[1] := False;
      n2[2] := False;
      w.WriteRow(r2, n2);
      { 3) maskeli ama hepsi False: '' acikca NULL DEGIL }
      SetLength(r3, 3);
      r3[0] := '';
      r3[1] := 'y';
      r3[2] := '';
      SetLength(n3, 3);
      w.WriteRow(r3, n3);
    finally
      w.Free;
    end;
    Chk('SP1 kosu dosyasi yazildi', FileExists(p), p);

    r := TVdbSpillReader.Create(p);
    try
      ok := r.Next(got, gn);
      Chk('SP2 satir1 okundu, maskesiz', ok and SameRow(got, r1) and
        (Length(gn) = 0), 'len=' + IntToStr(Length(gn)));
      ok := r.Next(got, gn);
      Chk('SP3 satir2: acik NULL korunur', ok and SameRow(got, r2) and
        SameNulls(gn, n2), 'mask=' + IntToStr(Length(gn)));
      ok := r.Next(got, gn);
      Chk('SP4 satir3: NULL olmayan '''' korunur',
        ok and SameRow(got, r3) and (Length(gn) = 3) and
        (not gn[0]) and (not gn[2]),
        'mask=' + IntToStr(Length(gn)));
      ok := r.Next(got, gn);
      Chk('SP5 EOF: dorduncu satir yok', (not ok) and (got = nil));
      Chk('SP6 okunan satir sayisi 3', r.Rows = 3, IntToStr(r.Rows));
    finally
      r.Free;
    end;
  finally
    dir.Free;   { Close: dizin tamamen silinir }
  end;
  Chk('SP6b kapanista dizin silindi', not DirectoryExists(dirName));
end;

{ ---------------- SP7-SP10: kararli siralama ---------------- }

type
  TSortTest = class
  public
    Rows: TStrMatrix;
    function Cmp(A, B: Integer): Integer;
  end;

function TSortTest.Cmp(A, B: Integer): Integer;
begin
  { yalniz 1. kolona gore; esitlerde 0 doner -> kararlilik test edilir }
  if Rows[A][0] < Rows[B][0] then Exit(-1);
  if Rows[A][0] > Rows[B][0] then Exit(1);
  Result := 0;
end;

procedure TestStableSort;
var
  t: TSortTest;
  nulls: TNullMatrix;
  i: Integer;
  seq: string;
  ok: Boolean;
begin
  t := TSortTest.Create;
  try
    SetLength(t.Rows, 6);
    { anahtar + kimlik: a2,a1,b2,b1,a3,b3 -> a2,a1,a3,b2,b1,b3 beklenir }
    for i := 0 to 5 do SetLength(t.Rows[i], 2);
    t.Rows[0][0] := 'a'; t.Rows[0][1] := '2';
    t.Rows[1][0] := 'b'; t.Rows[1][1] := '2';
    t.Rows[2][0] := 'a'; t.Rows[2][1] := '1';
    t.Rows[3][0] := 'b'; t.Rows[3][1] := '1';
    t.Rows[4][0] := 'a'; t.Rows[4][1] := '3';
    t.Rows[5][0] := 'b'; t.Rows[5][1] := '3';
    SetLength(nulls, 6);
    for i := 0 to 5 do
    begin
      SetLength(nulls[i], 2);
      nulls[i][1] := (i = 3);   { NULL maskesi de birlikte tasinmali }
    end;
    VdbSpillStableSortRows(t.Rows, nulls, @t.Cmp);
    seq := '';
    for i := 0 to 5 do seq := seq + t.Rows[i][0] + t.Rows[i][1];
    Chk('SP7 kararli siralama sirasi', seq = 'a2a1a3b2b1b3', seq);
    Chk('SP8 esit anahtarda giris sirasi korundu',
      (t.Rows[0][1] = '2') and (t.Rows[1][1] = '1') and (t.Rows[2][1] = '3'),
      t.Rows[0][1] + t.Rows[1][1] + t.Rows[2][1]);
    { a2(0), a1(2), a3(4) ... b1 NULL idi; indeks 4'e tasindi }
    ok := False;
    for i := 0 to 5 do
      if (t.Rows[i][0] = 'b') and (t.Rows[i][1] = '1') then
        ok := nulls[i][1];
    Chk('SP9 NULL maskesi satirla birlikte tasindi', ok);
    Chk('SP10 satir sayisi degismedi', Length(t.Rows) = 6);
  finally
    t.Free;
  end;
end;

{ ---------------- SP11-SP14: birlestirme ---------------- }

procedure TestMerge;
var
  dir: TVdbSpillDir;
  w: TVdbSpillWriter;
  m: TVdbSpillMerger;
  paths: TStrArray;
  base, sorted, chunkRows: TStrMatrix;
  t: TSortTest;
  pend: TStringList;
  i, runIdx, chunk: Integer;
  s, merged: string;
  row, got: TStrArray;
  gn: TNulArr;
  nn: TNullMatrix;
  mergedCount: Integer;
begin
  dir := TVdbSpillDir.Create(GDir + 'db2.odb');
  t := TSortTest.Create;
  try
    { 40 satir, anahtar degerleri karisik ve TEKRARLI; 4 parcaya bolunur }
    SetLength(base, 40);
    for i := 0 to 39 do
    begin
      SetLength(base[i], 2);
      base[i][0] := Chr(Ord('a') + ((i * 7) mod 3));
      base[i][1] := Format('%.2d', [i]);
    end;
    { beklenen: butun satirlarin kararli siralamasi }
    sorted := Copy(base, 0, Length(base));
    t.Rows := sorted;
    nn := nil;
    VdbSpillStableSortRows(sorted, nn, @t.Cmp);
    t.Rows := nil;

    SetLength(paths, 4);
    runIdx := 0;
    chunk := 0;
    while chunk < 40 do
    begin
      { external sort kurali: her parca ONCE kendi icinde kararli siralanir }
      SetLength(chunkRows, 10);
      for i := 0 to 9 do chunkRows[i] := base[chunk + i];
      t.Rows := chunkRows;
      VdbSpillStableSortRows(chunkRows, nn, @t.Cmp);
      t.Rows := nil;
      w := TVdbSpillWriter.Create(dir.NewRunPath, 2);
      paths[runIdx] := w.Path;
      try
        for i := 0 to 9 do
          w.WriteRow(chunkRows[i], nil);
      finally
        w.Free;
      end;
      Inc(runIdx);
      Inc(chunk, 10);
    end;
    Chk('SP11 dort kosu dosyasi yazildi', runIdx = 4);

    m := TVdbSpillMerger.Create(paths);
    try
      t.Rows := m.Heads;
      m.Cmp := @t.Cmp;
      merged := '';
      mergedCount := 0;
      while m.Next(row, gn) do
      begin
        merged := merged + row[0] + row[1] + '|';
        Inc(mergedCount);
      end;
    finally
      m.Free;
      t.Rows := nil;
    end;
    s := '';
    for i := 0 to High(sorted) do
      s := s + sorted[i][0] + sorted[i][1] + '|';
    Chk('SP12 birlestirme = tek seferde kararli siralama', merged = s);
    Chk('SP13 birlestirilen satir sayisi 40',
      mergedCount = 40, IntToStr(mergedCount));
    Chk('SP14 birlestirme cikisi bos degil ve ilk satir en kucuk',
      (Length(sorted) > 0) and (Copy(merged, 1, 4) = sorted[0][0] + sorted[0][1] + '|'),
      Copy(merged, 1, 8));
  finally
    t.Free;
    dir.Free;
  end;
end;

{ ---------------- SP15-SP18: bellek muhasebesi ---------------- }

procedure TestBytes;
var
  r: TStrArray;
  b, txt: Int64;
  m: TStrMatrix;
begin
  SetLength(r, 3);
  r[0] := '';
  r[1] := 'abcdef';
  r[2] := '';
  txt := 6;
  b := VdbSpillRowBytes(r);
  Chk('SP15 satir bayti metinden BUYUK (baslik+isaretci sayilir)', b > txt,
    IntToStr(b) + ' > ' + IntToStr(txt));
  Chk('SP16 satir bayti en az 3 isaretci + 32 icerir',
    b >= 32 + 3 * SizeOf(Pointer), IntToStr(b));
  SetLength(m, 2);
  m[0] := r;
  m[1] := r;
  Chk('SP17 matris bayti satir toplamindan buyuk',
    VdbSpillMatrixBytes(m) > 2 * b, IntToStr(VdbSpillMatrixBytes(m)));
  Chk('SP18 bos satir bile sifirdan buyuk', VdbSpillRowBytes(nil) > 0,
    IntToStr(VdbSpillRowBytes(nil)));
end;

{ ---------------- SP19-SP23: dizin / manifest ---------------- }

procedure TestDir;
var
  dir: TVdbSpillDir;
  sl: TStringList;
  p, mp: string;
  txt: string;
  dirName: string;
begin
  dir := TVdbSpillDir.Create(GDir + 'db3.odb');
  dirName := dir.Dir;
  try
    Chk('SP19 dizin olustu', DirectoryExists(dirName), dirName);
    p := dir.NewRunPath;
    Chk('SP20 kosu yolu atandi (dosya henuz yok)',
      FileExists(p) = False, p);
    Chk('SP20b kosu uzantisi', ExtractFileExt(p) = VDBSPILL_EXT, p);
    mp := IncludeTrailingPathDelimiter(dirName) + VDBSPILL_MANIFEST;
    Chk('SP21 manifest var', FileExists(mp), mp);
    sl := TStringList.Create;
    try
      sl.LoadFromFile(mp);
      txt := sl.Text;
    finally
      sl.Free;
    end;
    Chk('SP22 manifest DB/PID/RUN kayitlarini tasir',
      (Pos('DB' + #9, txt) > 0) and (Pos('PID' + #9, txt) > 0) and
      (Pos('RUN' + #9, txt) > 0) and
      (Pos(ExtractFileName(p), txt) > 0));
    { dizin ve manifest kapanista gitmeli }
  finally
    dir.Free;
  end;
  Chk('SP23 kapanista dizin+manifest silindi',
    (not DirectoryExists(dirName)) and (not FileExists(mp)));
end;

{ ---------------- SP24-SP27: artik dizin toplama ---------------- }

procedure MakeFakeDir(const ADir, ADb, APid: string);
var
  sl: TStringList;
begin
  ForceDirectories(ADir);
  sl := TStringList.Create;
  try
    sl.LineBreak := #10;
    sl.Add('DB' + #9 + ADb);
    sl.Add('PID' + #9 + APid);
    sl.Add('VER' + #9 + '1');
    sl.SaveToFile(IncludeTrailingPathDelimiter(ADir) + VDBSPILL_MANIFEST);
  finally
    sl.Free;
  end;
  { icinde bir kosu dosyasi da olsun }
  with TFileStream.Create(IncludeTrailingPathDelimiter(ADir) + 'run0' +
    VDBSPILL_EXT, fmCreate) do
    try
      WriteBuffer(VDBSPILL_MAGIC, SizeOf(VDBSPILL_MAGIC));
    finally
      Free;
    end;
end;

procedure TestOrphans;
var
  deadDir, liveDir, noManDir, keepDir: string;
  dir: TVdbSpillDir;
  db: string;
begin
  db := GDir + 'db4.odb';
  deadDir := VdbSpillRoot + VDBSPILL_DIR_PREFIX + 'dead_test';
  liveDir := VdbSpillRoot + VDBSPILL_DIR_PREFIX + 'live_test';
  noManDir := VdbSpillRoot + VDBSPILL_DIR_PREFIX + 'noman_test';
  VdbDeleteTree(deadDir);
  VdbDeleteTree(liveDir);
  VdbDeleteTree(noManDir);

  MakeFakeDir(deadDir, db, '999999');
  MakeFakeDir(liveDir, db, IntToStr(VdbSpillPid));
  ForceDirectories(noManDir);       { manifest YOK, bos dizin }

  dir := TVdbSpillDir.Create(db);
  try
    Chk('SP24 olu pid dizini toplandi', not DirectoryExists(deadDir), deadDir);
    Chk('SP25 CANLI pid dizini korundu', DirectoryExists(liveDir), liveDir);
    Chk('SP26 manifesti olmayan dizine dokunulmadi',
      DirectoryExists(noManDir), noManDir);
    Chk('SP27 kendi dizini ayri olustu',
      DirectoryExists(dir.Dir) and (not SameText(dir.Dir, liveDir)), dir.Dir);
  finally
    dir.Free;
  end;
  { temizlik: testin biraktigi dizinler }
  VdbDeleteTree(liveDir);
  VdbDeleteTree(noManDir);
end;

var
  provisioned: string;
begin
  GPass := 0;
  GFail := 0;
  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'spill_work');
  Wipe(GDir);
  ForceDirectories(GDir);
  provisioned := IncludeTrailingPathDelimiter(GDir) + 'root';
  ForceDirectories(provisioned);
  VdbSpillRootOverride := provisioned;
  VdbSpillResetStats;

  WriteLn('=== tests/spill_core (SKILL11) ===');
  WriteLn('spill kok dizini: ', VdbSpillRoot);
  try
    TestRoundTrip;
    TestStableSort;
    TestMerge;
    TestBytes;
    TestDir;
    TestOrphans;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL beklenmeyen istisna: ', E.ClassName, ': ', E.Message);
    end;
  end;
  WriteLn('---');
  WriteLn(Format('SONUC: %d PASS, %d FAIL', [GPass, GFail]));
  if GFail > 0 then Halt(1);
end.
