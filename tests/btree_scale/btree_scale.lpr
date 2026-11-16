program btree_scale;
{ v3.43 OLCek KAPISI - SKILL3 §"Benchmark / scale".
  Amac: B+Tree'nin 1.000.000 anahtarda DAVRANISINI olcmek ve VACUUM'un
  gercekten yer kazanip kazanmadigini olcmek. SKILL3'un kurali:
  "Olculebilir bir sorun olmadan spekulatif B+Tree degisikligi yapma."
  Bu kapi once OLCER; bir kusur gorurse kirmizi olur.

  A) BELLEKTEKI B+Tree (TVDbBTree, MaxKeys=96):
     BS1 1M anahtar karisik sirada eklenir: Count, Height, LeafCount,
         ortalama doluluk (>= MaxKeys/2), degismezler temiz
     BS2 All() 1M kaydi ARTAN sirada dondurur
     BS3 rastgele Find degerleri tutar, LowerBound tutarli
     BS4 CountRange/RankBefore analitik beklentiyle ayni
     BS5 olcek orani: 100k ekleme vs 1M ekleme (karesel patlama yakalanir)
     BS6 yarisi silinir: Count, degismezler, yukseklik ARTMAZ
     BS7 ayni anahtarlar yeniden eklenir: yaprak parcalanmasi sinirli
     BS8 son degismezler + ornek Find
  B) DISKTE OLCek + VACUUM:
     BS9  6000 satir yazilir, dosya boyu > 0, COUNT dogru
     BS10 5400 satir silinir: COUNT dogru, dosya KUCULMEZ (beklenen:
          yer yeniden kullanilir, sayfalar VACUUM'a kadar kalir)
     BS11 Compact (VACUUM): yeni boy eski boydan KUCUK ve en az %10 kazanc
     BS12 VACUUM sonrasi COUNT hala dogru, kalan degerler tutarli
     BS13 VACUUM sonrasi yeniden ekleme: dosya eski boyu ASMAZ
     BS14 yeniden acilis: COUNT dogru, VERIFY temiz

  Olculen degerler "OLCUM ..." satirlarinda yazilir; kapi mutlak hiz
  iddiasinda bulunmaz, patlamayi yakalar.

  Derleme: fpc. Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbSkipList, VDbBTree, VDbBackendApi, VDbBackendV3,
  VDbTable, VDbSql, VDbPageEngine;

const
  MAXK = 96;            { varsayilan dugum kapasitesi }
  NMEM = 1000000;       { bellek agaci anahtar sayisi }
  SMALL = 100000;       { olcek orani icin kucuk ornek }
  NSAMPLE = 8000;       { rastgele Find ornegi }
  DBROWS = 6000;        { diskteki satir sayisi }
  DELKEEP = 10;         { her 10 satirda 1 tutulur -> 6000/10 = 600 kalir }
  VALPAD = 200;         { deger dolgusu: dosya anlamli buyuklukte olsun }
  BATCH = 400;          { islem basina silinen satir }

type
  TCmpHolder = class
    function KeyCmp(const A, B: string): Integer;
  end;

  TIntArr = array of Integer;

function TCmpHolder.KeyCmp(const A, B: string): Integer;
begin
  Result := CompareStr(A, B);
end;

var
  GPass, GFail: Integer;
  GCmp: TCmpHolder;
  GSeed: Int64;

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

function NextRand(AMax: Integer): Integer;
begin
  GSeed := (GSeed * 1103515245 + 12345) and $7FFFFFFF;
  if AMax <= 1 then Exit(0);
  Result := Integer(GSeed mod AMax);
end;

{ 8 hane: 1.000.000 anahtar icin sifir dolgulu, CompareStr sirasi = sayi sirasi. }
function KeyOf(I: Integer): string;
begin
  Result := Format('k%.8d', [I]);
end;

function ValOf(I: Integer): string;
begin
  Result := 'v' + IntToStr(I);
end;

function Ms: QWord;
begin
  Result := GetTickCount64;
end;

function PhysSize(const APath: string): Int64;
var
  fs: TFileStream;
begin
  Result := 0;
  if not FileExists(APath) then Exit;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := fs.Size;
  finally
    fs.Free;
  end;
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

{ Karisik ekleme sirasi (Fisher-Yates): dengeli agac, sirali ekleme
  kolayligina karsi savunmasiz olmasin. }
function ShuffledOrder(N: Integer): TIntArr;
var
  i, j, tmp: Integer;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do
    Result[i] := i;
  for i := N - 1 downto 1 do
  begin
    j := NextRand(i + 1);
    tmp := Result[i];
    Result[i] := Result[j];
    Result[j] := tmp;
  end;
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

function SVal(Sq: TVSql; const ASql: string): string;
var
  r: TSqlResult;
begin
  Result := '';
  r := Sq.Exec(ASql);
  if (Length(r.Rows) = 1) and (Length(r.Rows[0]) >= 1) then
    Result := Trim(r.Rows[0][0]);
end;

function RowVal(I: Integer): string;
var
  k: Integer;
begin
  SetLength(Result, VALPAD);
  for k := 1 to VALPAD do
    Result[k] := Chr(Ord('a') + ((I + k) mod 26));
  Result := 'r' + IntToStr(I) + ':' + Result;
end;

{ ------------------------------------------------------- A) bellek agaci }

var
  MemLeaf0, MemHeight0: Integer;

procedure PartA;
var
  T: TVDbBTree;
  order: TIntArr;
  arr: TVDbSkipEntryArray;
  i, n, leaf1, h1, found, bad, avgPerLeaf: Integer;
  t0, t100, tall: QWord;
  ratio: Double;
  v: string;
  inv, detail: string;
begin
  GSeed := 20250225;
  order := ShuffledOrder(NMEM);

  T := TVDbBTree.Create(MAXK);
  try
    t0 := Ms;
    t100 := 0;
    for i := 0 to NMEM - 1 do
    begin
      T.Insert(KeyOf(order[i]), ValOf(order[i]));
      if (i = SMALL - 1) then
        t100 := Ms - t0;
    end;
    tall := Ms - t0;
    order := nil;

    MemLeaf0 := T.LeafCount;
    MemHeight0 := T.Height;
    if MemLeaf0 > 0 then
      avgPerLeaf := Integer(T.Count div MemLeaf0)
    else
      avgPerLeaf := 0;

    WriteLn('OLCUM btree.mem.ins n=', NMEM, ' ms=', tall, ' h=', MemHeight0,
      ' leaf=', MemLeaf0, ' doluluk=', avgPerLeaf);
    WriteLn('OLCUM btree.mem.ins n=', SMALL, ' ms=', t100);

    inv := T.CheckInvariants;
    Chk('BS1 1M anahtar dengeli agac', (T.Count = NMEM) and (inv = '') and
      (MemHeight0 >= 3) and (MemHeight0 <= 8) and (avgPerLeaf >= MAXK div 2),
      Format('count=%d h=%d leaf=%d doluluk=%d inv=%s',
      [T.Count, MemHeight0, MemLeaf0, avgPerLeaf, inv]));

    { BS2: sirali cikti }
    n := T.All(arr);
    bad := 0;
    if n <> NMEM then
      bad := -1
    else
    begin
      for i := 0 to n - 1 do
        if (arr[i].Key <> KeyOf(i)) or (arr[i].Value <> ValOf(i)) then
        begin
          bad := i + 1;
          Break;
        end;
    end;
    Chk('BS2 All() 1M kaydi artan sirada dondurdu', bad = 0,
      Format('n=%d ilkHata=%d', [n, bad]));
    arr := nil;

    { BS3: rastgele Find + LowerBound }
    found := 0;
    bad := 0;
    for i := 1 to NSAMPLE do
    begin
      n := NextRand(NMEM);
      if T.Find(KeyOf(n), v) and (v = ValOf(n)) then
        Inc(found)
      else
        Inc(bad);
    end;
    Chk('BS3 rastgele Find dogru', (found = NSAMPLE) and (bad = 0),
      Format('bulunan=%d/%d hata=%d', [found, NSAMPLE, bad]));

    { BS4: aralik ve rank analitik beklentiyle ayni }
    n := Integer(T.CountRange(KeyOf(100000), KeyOf(199999), True, True,
      True, True, GCmp.KeyCmp));
    Chk('BS4 CountRange analitik beklentiyle ayni', n = 100000,
      Format('aralik=100000 sayilan=%d', [n]));
    Chk('BS4b RankBefore tutarli',
      T.RankBefore(KeyOf(500000), GCmp.KeyCmp, False) = 500000,
      Format('rank=%d beklenen=500000',
      [T.RankBefore(KeyOf(500000), GCmp.KeyCmp, False)]));

    { BS5: olcek orani - karesel patlama yakalanir.
      Toplam oran tek basina yaniltici: 1M anahtar i386'da onbellek
      disina tasar, islem basina maliyet ~3-4x buyur (olculdu). Karesel
      bir agacta islem basina maliyet veriyle DOGRU orantili olur, yani
      10x veride ~10x; bu yuzden olcut islem basina orandir. }
    if t100 > 0 then
      ratio := (tall / NMEM) / (t100 / SMALL)
    else
      ratio := 99999;
    WriteLn(Format('OLCUM btree.mem.olcek toplam=%.2f islemBasina=%.2f '
      + '(10x veri; karesel agacta islem basina ~10, '
      + 'logaritmik + onbellek etkisi ~1-4)', [tall / t100, ratio]));
    Chk('BS5 ekleme olcegi karesel degil', (t100 > 0) and (ratio <= 6),
      Format('100k=%d ms 1M=%d ms islemBasina=%.2f', [t100, tall, ratio]));

    { BS6: yarisi silinir }
    t0 := Ms;
    for i := 0 to NMEM - 1 do
      if Odd(i) then
        T.Delete(KeyOf(i), ValOf(i));
    WriteLn('OLCUM btree.mem.del n=', NMEM div 2, ' ms=', Ms - t0);
    inv := T.CheckInvariants;
    h1 := T.Height;
    Chk('BS6 yarisi silindi, agac saglam',
      (T.Count = NMEM div 2) and (inv = '') and (h1 <= MemHeight0),
      Format('count=%d h=%d (once %d) inv=%s',
      [T.Count, h1, MemHeight0, inv]));

    { BS7: ayni anahtarlar yeniden eklenir -> yaprak parcalanmasi }
    for i := 0 to NMEM - 1 do
      if Odd(i) then
        T.Insert(KeyOf(i), ValOf(i));
    leaf1 := T.LeafCount;
    inv := T.CheckInvariants;
    WriteLn(Format('OLCUM btree.mem.churn leaf_once=%d leaf_sonra=%d (%.2fx)',
      [MemLeaf0, leaf1, leaf1 / MemLeaf0]));
    Chk('BS7 churn sonrasi yaprak parcalanmasi sinirli',
      (T.Count = NMEM) and (inv = '') and (leaf1 <= (MemLeaf0 * 135) div 100 + 2),
      Format('count=%d leaf=%d sinir=%d inv=%s',
      [T.Count, leaf1, (MemLeaf0 * 135) div 100 + 2, inv]));

    { BS8: son kontrol }
    found := 0;
    for i := 0 to 499 do
    begin
      n := NextRand(NMEM);
      if T.Find(KeyOf(n), v) and (v = ValOf(n)) then
        Inc(found);
    end;
    detail := T.CheckInvariants;
    h1 := T.Height;
    Chk('BS8 son durum saglam', (found = 500) and (detail = '') and
      (T.Count = NMEM), Format('find=%d/500 h=%d count=%d inv=%s',
      [found, h1, T.Count, detail]));
  finally
    T.Free;
  end;
end;

{ ------------------------------------------------------ B) diskte olcek }

procedure PartB(const ADir, ADb: string);
var
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  i, j, k, bad, nRows: Integer;
  vOld, vNew: Int64;
  sizeBefore, sizeAfterDel, sizeAfterVac, sizeAfterIns: Int64;
  rep, v: string;
  ok: Boolean;
begin
  BeC := nil;
  Be := nil;
  Tb := nil;
  Sq := nil;
  try
    BeC := TVdbBackendV3.Create(ADb, True, 512, 4000);
    Be := BeC;
    Tb := TVTableDb.CreateBackend(Be);
    Tb.Open(ADir);
    Sq := TVSql.Create(Tb);

    Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    i := 1;
    while i <= DBROWS do
    begin
      Sq.Exec('BEGIN');
      for j := 1 to 200 do
      begin
        if i > DBROWS then Break;
        Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
          RowVal(i) + ''')');
        Inc(i);
      end;
      Sq.Exec('COMMIT');
    end;
    BeC.Engine.Checkpoint(True);

    sizeBefore := Be.DataFileSize;
    WriteLn('OLCUM disk.yaz satir=', DBROWS, ' mantiksal=', sizeBefore,
      ' fiziksel=', PhysSize(ADb));
    Chk('BS9 6000 satir yazildi, dosya olustu',
      (QInt(Sq, 'SELECT COUNT(*) FROM t') = DBROWS) and (sizeBefore > 0) and
      FileExists(ADb),
      Format('count=%d mantiksal=%d', [QInt(Sq, 'SELECT COUNT(*) FROM t'),
      sizeBefore]));

    { Her 10. satir kalir; digerleri toplu islemlerle silinir. }
    i := 1;
    while i <= DBROWS do
    begin
      if i mod DELKEEP <> 0 then
      begin
        Sq.Exec('BEGIN');
        for k := 1 to BATCH do
        begin
          while (i <= DBROWS) and (i mod DELKEEP = 0) do
            Inc(i);
          if i > DBROWS then Break;
          Sq.Exec('DELETE FROM t WHERE id = ' + IntToStr(i));
          Inc(i);
        end;
        Sq.Exec('COMMIT');
      end
      else
        Inc(i);
    end;
    BeC.Engine.Checkpoint(True);
    sizeAfterDel := Be.DataFileSize;
    nRows := DBROWS div DELKEEP;
    WriteLn('OLCUM disk.sil kalan=', nRows, ' mantiksal=', sizeAfterDel,
      ' (once ', sizeBefore, ') oluBayt=', Be.DeadBytes);
    Chk('BS10 silme sonrasi COUNT dogru, dosya kuculmedi',
      (QInt(Sq, 'SELECT COUNT(*) FROM t') = nRows) and
      (sizeAfterDel >= sizeBefore),
      Format('count=%d mantiksal=%d onceki=%d olu=%d',
      [QInt(Sq, 'SELECT COUNT(*) FROM t'), sizeAfterDel, sizeBefore,
      Be.DeadBytes]));

    { VACUUM: canli kayitlar sikisik dosyaya yazilir. }
    Be.Compact(vOld, vNew);
    Tb.ReloadSchema;
    sizeAfterVac := Be.DataFileSize;
    WriteLn('OLCUM disk.vacuum eski=', vOld, ' yeni=', vNew,
      ' kazanc=', vOld - vNew, ' mantiksal=', sizeAfterVac);
    Chk('BS11 VACUUM gercekten yer kazandirdi',
      (vNew <= vOld) and (vOld > 0) and (vNew < (vOld * 9) div 10),
      Format('eski=%d yeni=%d kazanc=%d', [vOld, vNew, vOld - vNew]));

    bad := 0;
    for i := DELKEEP to DBROWS do
      if i mod DELKEEP = 0 then
      begin
        v := SVal(Sq, 'SELECT v FROM t WHERE id = ' + IntToStr(i));
        if v <> RowVal(i) then
        begin
          Inc(bad);
          if bad = 1 then
            WriteLn('BILGI BS12 ilk bozuk satir id=', i);
        end;
      end;
    Chk('BS12 VACUUM sonrasi veri bozulmadi',
      (QInt(Sq, 'SELECT COUNT(*) FROM t') = nRows) and (bad = 0),
      Format('count=%d bozuk=%d', [QInt(Sq, 'SELECT COUNT(*) FROM t'), bad]));

    { VACUUM'un biraktigi bos alan yeniden kullanilmali: dosya eski
      boyunu asmamali (balon etkisi yok). }
    Sq.Exec('BEGIN');
    for i := 1 to nRows do
    begin
      Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(50000 + i) +
        ', ''' + RowVal(50000 + i) + ''')');
      if i mod 200 = 0 then
      begin
        Sq.Exec('COMMIT');
        Sq.Exec('BEGIN');
      end;
    end;
    Sq.Exec('COMMIT');
    BeC.Engine.Checkpoint(True);
    sizeAfterIns := Be.DataFileSize;
    WriteLn('OLCUM disk.yenidenEkle satir=', nRows, ' mantiksal=',
      sizeAfterIns, ' tavan=', sizeBefore);
    Chk('BS13 VACUUM sonrasi ekleme dosyayi sisirmedi',
      (QInt(Sq, 'SELECT COUNT(*) FROM t') = nRows * 2) and
      (sizeAfterIns <= sizeBefore),
      Format('count=%d mantiksal=%d tavan=%d',
      [QInt(Sq, 'SELECT COUNT(*) FROM t'), sizeAfterIns, sizeBefore]));

    FreeAndNil(Sq);
    FreeAndNil(Tb);
    Be := nil;
    BeC := nil;

    { BS14: yeniden acilis + tam VERIFY }
    BeC := TVdbBackendV3.CreateReadOnly(ADb);
    ok := BeC.Engine.VerifyEx(vmFull, True, rep);
    Chk('BS14 yeniden acilis: VERIFY temiz', ok, 'rapor=' + rep);
  finally
    FreeAndNil(Sq);
    FreeAndNil(Tb);
    Be := nil;
    BeC := nil;
  end;
end;

var
  Dir, Db: string;

begin
  GPass := 0;
  GFail := 0;
  GCmp := TCmpHolder.Create;
  Dir := IncludeTrailingPathDelimiter(
    ExtractFilePath(ParamStr(0)) + 'tmp/btree_scale');
  WipeDir(Dir);
  Db := IncludeTrailingPathDelimiter(Dir) + 'bs.odb';
  try
    PartA;
    PartB(Dir, Db);
  finally
    GCmp.Free;
  end;

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
