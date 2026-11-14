program perf_baseline;
{ V3 sertlestirme - Phase 6: performans taban cizgisi + regresyon esikleri.

  Amac (skill Phase 6 "Performance baselines ve regression thresholds"):
  (a) sicak yollarin (B+Tree ekleme/arama/silme, SQL ekleme/nokta sorgusu)
      MUTLAK olcusunu yazmak,
  (b) makineye gore degisen mutlak sureler yerine OLCEKLEME oranlarini ve
      genis tavanlari kapiya baglamak: O(n log n) davranis korunur, sessiz
      karesel bozunma (quadratic blowup) kapiyi kirar.

  Durust sinirlar:
    - Sure esikleri GENIS tavanlardir (yavas CI makinesi icin); amac
      mikro-benchmark yarisi degil, patolojik bozunmayi yakalamaktir.
    - Mutlak sayilar makineye baglidir; docs/engineering/PERF_BASELINE.md
      olculen ortami ve sayilari kaydeder, iddia etmez.
    - Bu kapi bellek ici B+Tree ile tek oturumluk SQL yolunu olcer; disk
      fsync/WAL dayaniklilik maliyeti wal_crash kapisinin konusudur.

  Derleme: fpc (lpi gerekmez). Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbSkipList, VDbBTree, VDbFactory, VDbBackendApi,
  VDbTable, VDbSql, VDbErr, VDbCore;

const
  BT_N        = 100000;   // B+Tree anahtar sayisi
  BT_FIND     = 5000;
  BT_SMALL    = 25000;
  SQL_ROWS    = 3000;
  CEIL_BT_INS = 60000;    // ms, genis tavan
  CEIL_BT_DEL = 60000;
  CEIL_BT_FND = 15000;
  CEIL_SQL_INS = 120000;
  CEIL_SQL_SEL = 60000;

var
  GPass, GFail: Integer;
  GSeed: LongWord;
  { Acilan veritabani dosyasinin GERCEK yolu (Be.FilePath). Dosya adi ve
    uzanti varsayilmaz; motor ne donduruyorsa olculur. }
  GDbFile: string;

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
end;

function NextRand(AMax: Integer): Integer;
begin
  GSeed := (GSeed * 1103515245 + 12345) and $7FFFFFFF;
  Result := Integer(GSeed mod LongWord(AMax));
end;

function KeyOf(I: Integer): string;
begin
  Result := Format('k%.7d', [I]);
end;

function Ms: QWord;
begin
  Result := GetTickCount64;
end;

{ ------------------------------------------------------------- B+Tree ---- }

{ N anahtari tohumlu karisik sirada ekler; sure doner. }
function BtInsertShuffled(N: Integer; out T: TVDbBTree): QWord;
var
  i, j, tmp: Integer;
  order: array of Integer;
  t0: QWord;
begin
  T := TVDbBTree.Create(96);
  SetLength(order, N);
  for i := 0 to N - 1 do
    order[i] := i;
  for i := N - 1 downto 1 do
  begin
    j := NextRand(i + 1);
    tmp := order[i];
    order[i] := order[j];
    order[j] := tmp;
  end;
  t0 := Ms;
  for i := 0 to N - 1 do
    T.Insert(KeyOf(order[i]), 'v' + IntToStr(order[i]));
  Result := Ms - t0;
end;

procedure BenchBTree;
var
  T, T2: TVDbBTree;
  arr: TVDbSkipEntryArray;
  s: string;
  tIns, tFind, tDel, tSmall, tBig: QWord;
  i, okN: Integer;
  ratio: Double;
begin
  GSeed := 20250101;
  tIns := BtInsertShuffled(BT_N, T);
  try
    WriteLn('OLCUM btree.insert n=', BT_N, ' ms=', tIns,
      ' h=', T.Height, ' leaf=', T.LeafCount);
    Chk('btree/count', T.Count = BT_N, 'Count=' + IntToStr(T.Count));
    s := T.CheckInvariants;
    Chk('btree/inv', s = '', s);

    { Sirali cikti dogru mu (All + tek noktadan ornekleme). }
    Chk('btree/all', T.All(arr) = BT_N, 'adet=' + IntToStr(Length(arr)));
    okN := 0;
    for i := 1 to High(arr) do
      if CompareStr(arr[i - 1].Key, arr[i].Key) >= 0 then Break
      else Inc(okN);
    Chk('btree/sorted', okN = High(arr), IntToStr(okN) + '/' + IntToStr(High(arr)));

    tFind := Ms;
    okN := 0;
    for i := 1 to BT_FIND do
    begin
      GSeed := (GSeed * 1103515245 + 12345) and $7FFFFFFF;
      if T.Find(KeyOf(Integer(GSeed mod LongWord(BT_N))), s) then Inc(okN);
    end;
    tFind := Ms - tFind;
    WriteLn('OLCUM btree.find n=', BT_FIND, ' ms=', tFind);
    Chk('btree/find-all', okN = BT_FIND, IntToStr(okN) + '/' + IntToStr(BT_FIND));

    tDel := Ms;
    for i := 0 to BT_N - 1 do
      T.Delete(KeyOf(i), 'v' + IntToStr(i));
    tDel := Ms - tDel;
    WriteLn('OLCUM btree.delete n=', BT_N, ' ms=', tDel);
    Chk('btree/deleted', T.Count = 0, 'Count=' + IntToStr(T.Count));
    s := T.CheckInvariants;
    Chk('btree/del-inv', s = '', s);

    Chk('btree/ceil-insert', tIns <= CEIL_BT_INS,
      IntToStr(tIns) + ' ms <= ' + IntToStr(CEIL_BT_INS));
    Chk('btree/ceil-delete', tDel <= CEIL_BT_DEL,
      IntToStr(tDel) + ' ms <= ' + IntToStr(CEIL_BT_DEL));
    Chk('btree/ceil-find', tFind <= CEIL_BT_FND,
      IntToStr(tFind) + ' ms <= ' + IntToStr(CEIL_BT_FND));
  finally
    T.Free;
  end;

  { Olcek tespiti: 2N anahtar ~2x'ten fazla surmeli degil. Karesel
    davranis 4x'e yakin olur; esik 3.5x. }
  GSeed := 777;
  tSmall := BtInsertShuffled(BT_SMALL, T2);
  T2.Free;
  GSeed := 777;
  tBig := BtInsertShuffled(BT_SMALL * 2, T2);
  T2.Free;
  if tSmall > 0 then ratio := tBig / tSmall else ratio := 1;
  WriteLn('OLCUM btree.scale n1=', BT_SMALL, ' n2=', BT_SMALL * 2,
    ' ms1=', tSmall, ' ms2=', tBig, Format(' oran=%.2f', [ratio]));
  Chk('btree/scale-linear', ratio <= 3.5,
    Format('oran=%.2f (esik 3.50)', [ratio]));
end;

{ ---------------------------------------------------------------- SQL ---- }

procedure BenchSql;
var
  dir_: string;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  r: TSqlResult;
  t0, tIns, tSel: QWord;
  i, okN: Integer;
  sr: TSearchRec;
begin
  { Onceki kosumdan kalan dosya adini TAHMIN ETMEK yerine dizini bosalt:
    motor hangi adi secerse secsin temiz baslar. }
  dir_ := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp/pb_sql');
  ForceDirectories(dir_);
  if FindFirst(dir_ + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        SysUtils.DeleteFile(dir_ + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;

  VdbOpen(dir_, Be, True, True);
  try
    { Dosya adi/uzanti VARSAYILMAZ: motorun bildirdigi yol kullanilir. }
    GDbFile := Be.FilePath;
    Tb := TVTableDb.CreateBackend(Be);
    Tb.Open(dir_);
    Sq := TVSql.Create(Tb);
    t0 := Ms;
    Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    for i := 1 to SQL_ROWS do
      Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''x' +
        IntToStr(i mod 97) + ''')');
    tIns := Ms - t0;

    t0 := Ms;
    okN := 0;
    for i := 1 to SQL_ROWS do
    begin
      r := Sq.Exec('SELECT v FROM t WHERE id = ' + IntToStr(i));
      if (Length(r.Rows) = 1) and (r.Rows[0][0] = 'x' + IntToStr(i mod 97)) then
        Inc(okN);
    end;
    tSel := Ms - t0;

    WriteLn('OLCUM sql.insert n=', SQL_ROWS, ' ms=', tIns);
    WriteLn('OLCUM sql.point-select n=', SQL_ROWS, ' ms=', tSel);
    Chk('sql/inserted', okN = SQL_ROWS, IntToStr(okN) + '/' + IntToStr(SQL_ROWS));
    Chk('sql/ceil-insert', tIns <= CEIL_SQL_INS,
      IntToStr(tIns) + ' ms <= ' + IntToStr(CEIL_SQL_INS));
    Chk('sql/ceil-select', tSel <= CEIL_SQL_SEL,
      IntToStr(tSel) + ' ms <= ' + IntToStr(CEIL_SQL_SEL));

    r := Sq.Exec('SELECT COUNT(*) FROM t');
    Chk('sql/count', (Length(r.Rows) = 1) and (r.Rows[0][0] = IntToStr(SQL_ROWS)),
      r.Rows[0][0]);

    { Dosya: motorun bildirdigi gercek yol uzerinden. }
    Chk('sql/file', FileExists(GDbFile), GDbFile);

    FreeAndNil(Sq);
    FreeAndNil(Tb);
  finally
    Be := nil;
  end;
end;

var
  fsz: Int64;
begin
  GPass := 0;
  GFail := 0;
  BenchBTree;
  BenchSql;
  fsz := 0;
  if (GDbFile <> '') and FileExists(GDbFile) then
  begin
    with TFileStream.Create(GDbFile, fmOpenRead or fmShareDenyNone) do
    try
      fsz := Size;
    finally
      Free;
    end;
  end;
  WriteLn('OLCUM sql.file bytes=', fsz, ' path=', GDbFile);

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
