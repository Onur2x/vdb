program btree_disk;
{ v3.46 KALICI REGRESYON KAPISI - AYRI B+TREE DISK SAYFA BICIMI.
  Bkz. VDbBTreeDisk.pas basligi ve docs/engineering/BTREE_INTEGRITY.md.

  KAPSAM (durust sinir)
  =====================
  Bu kapi VDbBTreeDisk birimini olcer. Birim v5 MOTOR DOSYA BICIMINE
  BAGLI DEGILDIR; v5 dosya bicimi, WAL ve kurtarma davranisi bu kapiyla
  degismez. Burada olculen sey sayfa biciminin kendisidir: bolunme,
  siralama, golge sayfalama (shadow paging) ile atomik commit, yirtik
  meta sayfasindan geri donus, cokme noktasinda onceki agacin aynen
  okunabilmesi, CRC bozulmasinin kontrollu tespiti ve sayfa geri
  kazanimi.

  OLCULEN
  =======
    BD1  ekle/oku; ayni anahtara yazma degeri gunceller, False doner
    BD2  Walk kesin artan sirada ve sayi dogru
    BD3  yeniden acilis: veri DURUR (dosya kesilmez), Verify temiz
    BD4  yukseklik/sayfa sayaci/kok tutarli
    BD5  yarisi silinince sayi ve Find dogru
    BD6  yeniden acilis: silinen yok, kalanlar durur, Verify temiz
    BD7  hepsi silinince agac bos; yeniden acilis da bos, Verify temiz
    BD8  azalan sirada 2000 ekleme: sira ve Verify
    BD9  karisik sirada 3000 ekleme: hepsi bulunur, Verify
    BD10 NextAfter alt-sinir taramasi tam sirali listeyle ayni
    BD11 bolunme agirlikli 6000 karisik anahtar: Verify, yukseklik >= 2
    BD12 churn (sil+yeniden ekle) sonrasi Verify ve yaprak doluluk raporu
    BD13 yirtik meta: en yeni meta sayfasi bozulunca onceki agac aynen acilir
    BD14 cokme noktasi (meta yazimindan hemen once): alinan kopya onceki
         agaci TAM okur (veri kaybi yok), asil dosya yeni haliyle devam eder
    BD15 yalniz-CRC bozulmasi: Verify FAIL verir, okuma yolu bozulmaz
    BD16 yapisal bozulma (cocuk isaretcisi): Verify FAIL verir, okuma
         yolu KONTROLLU EBtdError atar, erisim ihlali atmaz
    BD17 silip yeniden ekleme: serbest sayfalar geri kullanilir, sayfa
         sayaci sismez
    BD18 kesik dosya (<2 sayfa) sessizce yeni agac KURMAZ, hata verir

  Derleme: fpc. Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbBTreeDisk, VDbCrc32;

const
  BTD_PAGE   = 4096;
  META_MAGIC = $31445442;

type
  TIntArr = array of Integer;

var
  GPass, GFail: Integer;
  GDir: string;

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

function DbPath(const AName: string): string;
begin
  Result := GDir + AName;
end;

function Q(const AKey: QWord): QWord;
begin
  Result := AKey * 7 + 3;
end;

function FileSizeOf(const AFile: string): Int64;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    Result := fs.Size;
  finally
    fs.Free;
  end;
end;

type
  TKeySink = class
  public
    Count: Integer;
    Last: QWord;
    Ordered: Boolean;
    Sum: Int64;
    constructor Create;
    procedure Take(AKey, AVal: QWord);
  end;

constructor TKeySink.Create;
begin
  inherited Create;
  Count := 0;
  Last := 0;
  Ordered := True;
  Sum := 0;
end;

procedure TKeySink.Take(AKey, AVal: QWord);
begin
  if (Count > 0) and (AKey <= Last) then Ordered := False;
  Last := AKey;
  Inc(Count);
  Inc(Sum, Int64(AVal));
end;

procedure WalkOf(T: TBtdTree; out ACount: Integer; out AOrdered: Boolean;
  out ASum: Int64);
var
  s: TKeySink;
begin
  s := TKeySink.Create;
  try
    T.Walk(s.Take);
    ACount := s.Count;
    AOrdered := s.Ordered;
    ASum := s.Sum;
  finally
    s.Free;
  end;
end;

{ Hepsi bulunuyor ve degeri dogru mu? }
function AllPresent(T: TBtdTree; ALo, AHi: Integer; out ABad: Integer): Boolean;
var
  i: Integer;
  v: QWord;
begin
  ABad := 0;
  Result := True;
  for i := ALo to AHi do
    if (not T.Find(QWord(i), v)) or (v <> Q(i)) then
    begin
      Inc(ABad);
      Result := False;
      if ABad > 5 then Exit;
    end;
end;

{ Bu araliktan en az bir anahtar var mi? }
function AnyPresent(T: TBtdTree; ALo, AHi: Integer): Boolean;
var
  i: Integer;
  v: QWord;
begin
  Result := False;
  for i := ALo to AHi do
    if T.Find(QWord(i), v) then Exit(True);
end;

{ NOT: FPC fonksiyon argumanlarini SAGDAN SOLA degerlendirir. Bu yuzden
  `Chk(x, Pred(a, bad), 'bad=' + IntToStr(bad))` ayrintiyi kosul kosmadan
  once kurar ve cop basar. Kosulu once yerelde hesapla, ayrintiyi sonra kur. }
procedure ChkPresent(const AName: string; T: TBtdTree; ALo, AHi: Integer;
  AExpectPresent: Boolean);
var
  bad: Integer;
  ok: Boolean;
begin
  if AExpectPresent then
  begin
    ok := AllPresent(T, ALo, AHi, bad);
    Chk(AName, ok, 'bozuk=' + IntToStr(bad));
  end
  else
    Chk(AName, not AnyPresent(T, ALo, AHi), 'aralikta anahtar kalmamali');
end;

procedure ChkVerify(const AName: string; T: TBtdTree);
var
  ok: Boolean;
  rep: string;
begin
  ok := T.Verify(rep);
  Chk(AName, ok, rep);
end;

procedure CopyRaw(const ASrc, ADst: string);
var
  fs, fd: TFileStream;
begin
  fs := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    fd := TFileStream.Create(ADst, fmCreate);
    try
      fd.CopyFrom(fs, 0);
    finally
      fd.Free;
    end;
  finally
    fs.Free;
  end;
end;

function MetaPageSeq(const AFile: string; APage: Integer): Int64;
var
  fs: TFileStream;
  buf: array[0..BTD_PAGE - 1] of Byte;
  magic: LongWord;
  seq: Int64;
begin
  Result := -1;
  fs := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    if fs.Size < Int64(APage + 1) * BTD_PAGE then Exit;
    fs.Position := Int64(APage) * BTD_PAGE;
    if fs.Read(buf, BTD_PAGE) <> BTD_PAGE then Exit;
    Move(buf[32], magic, 4);
    if magic <> META_MAGIC then Exit;
    Move(buf[44], seq, 8);
    Result := seq;
  finally
    fs.Free;
  end;
end;

function NewestMetaPage(const AFile: string): Integer;
var
  s0, s1: Int64;
begin
  s0 := MetaPageSeq(AFile, 0);
  s1 := MetaPageSeq(AFile, 1);
  if s1 > s0 then Result := 1 else Result := 0;
end;

{ Sayfa CRC'sini yeniden damgalar (Sprint D 6.2): yalniz YAPISAL bozulma
  olcen vaka icin, bozulmanin CRC tarafindan yakalanmamasini saglar.
  Bicim: hdr +16 = Crc; hesaplanirken Crc alani sifirlanir. }
procedure RestampCrc(const AFile: string; AOffset: Int64);
var
  fs: TFileStream;
  pg: TBtdPageBuf;
  crc: LongWord;
begin
  fs := TFileStream.Create(AFile, fmOpenReadWrite or fmShareDenyNone);
  try
    fs.Position := AOffset;
    fs.ReadBuffer(pg, BTD_PAGE);
    FillChar(pg[16], 4, 0);
    crc := VDbCrc32Of(pg, BTD_PAGE);
    Move(crc, pg[16], 4);
    fs.Position := AOffset;
    fs.WriteBuffer(pg, BTD_PAGE);
  finally
    fs.Free;
  end;
end;

procedure FlipByte(const AFile: string; AOffset: Int64);
var
  fs: TFileStream;
  b: Byte;
begin
  fs := TFileStream.Create(AFile, fmOpenReadWrite or fmShareDenyNone);
  try
    fs.Position := AOffset;
    fs.ReadBuffer(b, 1);
    b := b xor $FF;
    fs.Position := AOffset;
    fs.WriteBuffer(b, 1);
  finally
    fs.Free;
  end;
end;

{ Deterministik karisik sira: 0..N-1 permutasyonu (Fisher-Yates, LCG).
  Somut dinamik dizi tipi kullanilir; acik dizi parametresine `var`
  Delphi modunda guvenilir degildir (ilk surumde tam bu yuzden tum
  senaryolar tek anahtara coktu). }
procedure Shuffled(var AOut: TIntArr);
var
  i, j, t: Integer;
  state: LongWord;
begin
  for i := 0 to High(AOut) do AOut[i] := i;
  state := 12345;
  for i := High(AOut) downto 1 do
  begin
    state := state * LongWord(1103515245) + LongWord(12345);
    j := Integer((state shr 8) mod LongWord(i + 1));
    t := AOut[i];
    AOut[i] := AOut[j];
    AOut[j] := t;
  end;
end;

type
  TSnapHook = class
  public
    Src: string;
    Snap: string;
    Hits: Integer;
    LastOk: Boolean;
    procedure BeforeMeta;
  end;

procedure TSnapHook.BeforeMeta;
begin
  Inc(Hits);
  LastOk := False;
  try
    CopyRaw(Src, Snap);
    LastOk := True;
  except
    LastOk := False;
  end;
end;

{ ------------------------------------------------------------------ BD1-7 }
procedure ScenarioBasic;
var
  file_: string;
  T: TBtdTree;
  i, cnt: Integer;
  v: QWord;
  ordered: Boolean;
  sum: Int64;
  sizeBefore, sizeAfter: Int64;
begin
  file_ := DbPath('basic.vdb');
  T := TBtdTree.Create(file_);
  try
    for i := 1 to 1000 do
      if not T.Insert(QWord(i), Q(i)) then
      begin
        Chk('BD1 insert', False, 'ekleme reddedildi i=' + IntToStr(i));
        Break;
      end;
    Chk('BD1a', T.Count = 1000, 'count=' + IntToStr(T.Count));
    ChkPresent('BD1b', T, 1, 1000, True);
    Chk('BD1c', not T.Insert(500, 999999), 'ayni anahtar False donmeli');
    Chk('BD1d', T.Find(500, v) and (v = 999999), 'guncellenen deger okunmali');
    T.Insert(500, Q(500));
    T.Commit;

    WalkOf(T, cnt, ordered, sum);
    Chk('BD2a', ordered, 'Walk artan sirada');
    Chk('BD2b', cnt = 1000, 'walk=' + IntToStr(cnt));

    Chk('BD4a', T.Height >= 1, 'height=' + IntToStr(T.Height));
    Chk('BD4b', T.PageCount >= BTD_FIRST_DATA, 'pages=' + IntToStr(T.PageCount));
    Chk('BD4c', T.FreePageCount >= 0, 'free=' + IntToStr(T.FreePageCount));
    Chk('BD4d', T.RootPage >= BTD_FIRST_DATA, 'root=' + IntToStr(T.RootPage));
    Chk('BD4e', T.SyncCount >= 1, 'sync=' + IntToStr(T.SyncCount));
    sizeBefore := FileSizeOf(file_);
    Chk('BD4f', sizeBefore >= Int64(2) * BTD_PAGE, 'boy=' + IntToStr(sizeBefore));
  finally
    T.Free;
  end;

  T := TBtdTree.Create(file_);
  T.CommitOnClose := False;
  try
    Chk('BD3a', T.Count = 1000, 'reopen count=' + IntToStr(T.Count));
    ChkVerify('BD3b', T);
    ChkPresent('BD3c', T, 1, 1000, True);
    sizeAfter := FileSizeOf(file_);
    Chk('BD3d', sizeAfter >= sizeBefore,
      'once=' + IntToStr(sizeBefore) + ' sonra=' + IntToStr(sizeAfter));

    for i := 1 to 1000 do
      if Odd(i) then
        if not T.Delete(QWord(i)) then
        begin
          Chk('BD5 delete', False, 'silme reddedildi i=' + IntToStr(i));
          Break;
        end;
    T.Commit;
    Chk('BD5a', T.Count = 500, 'count=' + IntToStr(T.Count));
    Chk('BD5b', not T.Find(501, v), 'silinen bulunmamali');
    Chk('BD5c', T.Find(502, v) and (v = Q(502)), 'cift anahtar durmali');
    ChkVerify('BD5d', T);
  finally
    T.Free;
  end;

  T := TBtdTree.Create(file_);
  T.CommitOnClose := False;
  try
    Chk('BD6a', T.Count = 500, 'reopen count=' + IntToStr(T.Count));
    Chk('BD6b', not T.Find(1, v), 'tek anahtar silinmis');
    Chk('BD6c', T.Find(2, v) and (v = Q(2)), 'tek anahtar duruyor');
    Chk('BD6d', not T.Find(999, v), 'tek anahtar silinmis');
    WalkOf(T, cnt, ordered, sum);
    Chk('BD6e', ordered and (cnt = 500), 'walk=' + IntToStr(cnt));
    ChkVerify('BD6f', T);

    for i := 2 to 1000 do
      if not Odd(i) then T.Delete(QWord(i));
    T.Commit;
    Chk('BD7a', T.Count = 0, 'count=' + IntToStr(T.Count));
    Chk('BD7b', not T.Find(2, v), 'bos agac');
    ChkVerify('BD7c', T);
  finally
    T.Free;
  end;

  T := TBtdTree.Create(file_);
  T.CommitOnClose := False;
  try
    Chk('BD7d', T.Count = 0, 'reopen count=' + IntToStr(T.Count));
    Chk('BD7e', not T.Find(2, v), 'bos agac');
    ChkVerify('BD7f', T);
  finally
    T.Free;
  end;
end;

{ ----------------------------------------------------------------- BD8-9 }
procedure ScenarioOrders;
var
  file_: string;
  T: TBtdTree;
  i, cnt: Integer;
  ordered: Boolean;
  sum: Int64;
  perm: TIntArr;
begin
  file_ := DbPath('orders.vdb');
  T := TBtdTree.Create(file_);
  T.CommitOnClose := False;
  try
    for i := 2000 downto 1 do T.Insert(QWord(i), Q(i));
    T.Commit;
    WalkOf(T, cnt, ordered, sum);
    Chk('BD8a', ordered, 'azalan ekleme sonrasi sira');
    Chk('BD8b', cnt = 2000, 'walk=' + IntToStr(cnt));
    ChkVerify('BD8c', T);
    ChkPresent('BD8d', T, 1, 2000, True);
  finally
    T.Free;
  end;

  file_ := DbPath('inter.vdb');
  T := TBtdTree.Create(file_);
  T.CommitOnClose := False;
  try
    SetLength(perm, 3000);
    Shuffled(perm);
    for i := 0 to 2999 do T.Insert(QWord(perm[i] + 1), Q(perm[i] + 1));
    T.Commit;
    Chk('BD9a', T.Count = 3000, 'count=' + IntToStr(T.Count));
    ChkPresent('BD9b', T, 1, 3000, True);
    ChkVerify('BD9c', T);
    WalkOf(T, cnt, ordered, sum);
    Chk('BD9d', ordered and (cnt = 3000), 'walk=' + IntToStr(cnt));
  finally
    T.Free;
  end;
end;

{ ------------------------------------------------------------------ BD10 }
procedure ScenarioNextAfter;
var
  file_: string;
  T: TBtdTree;
  i, hits: Integer;
  k, v, expectK: QWord;
  ok: Boolean;
begin
  file_ := DbPath('scan.vdb');
  T := TBtdTree.Create(file_);
  T.CommitOnClose := False;
  try
    for i := 1 to 3000 do T.Insert(QWord(i * 2), Q(i * 2));  { cift anahtarlar }
    T.Commit;

    ok := True;
    hits := 0;
    k := 1;
    while k <= 6000 do
    begin
      if not T.NextAfter(k, expectK, v) then
      begin
        ok := False;
        Break;
      end;
      { Beklenen: k'dan buyuk-esit EN KUCUK cift anahtar. }
      if Odd(k) then
      begin
        if expectK <> QWord(k + 1) then ok := False;
      end
      else if expectK <> QWord(k) then ok := False;
      if v <> Q(expectK) then ok := False;
      Inc(hits);
      k := k + 1;
    end;
    Chk('BD10a', ok, 'alt-sinir taramasi sirali listeyle uyusmali');
    Chk('BD10b', hits = 6000, 'tarama=' + IntToStr(hits));
    Chk('BD10c', not T.NextAfter(6001, expectK, v), 'en buyuk anahtardan sonra yok');
    Chk('BD10d', T.NextAfter(0, expectK, v) and (expectK = 2), 'ilk anahtar');
  finally
    T.Free;
  end;
end;

{ ------------------------------------------------------------- BD11-12,17 }
procedure ScenarioSplitChurn;
var
  file_: string;
  T: TBtdTree;
  rep: string;
  i, cnt, beforePages, afterPages: Integer;
  ordered: Boolean;
  sum: Int64;
  perm: TIntArr;
begin
  file_ := DbPath('split.vdb');
  T := TBtdTree.Create(file_);
  T.CommitOnClose := False;
  try
    SetLength(perm, 6000);
    Shuffled(perm);
    for i := 0 to 5999 do T.Insert(QWord(perm[i] + 1), Q(perm[i] + 1));
    T.Commit;
    Chk('BD11a', T.Count = 6000, 'count=' + IntToStr(T.Count));
    ChkVerify('BD11b', T);
    Chk('BD11c', T.Height >= 2, 'height=' + IntToStr(T.Height));
    ChkPresent('BD11d', T, 1, 6000, True);

    { churn: her 3. anahtari sil, sonra yeniden ekle }
    for i := 1 to 6000 do
      if (i mod 3) = 0 then T.Delete(QWord(i));
    T.Commit;
    for i := 1 to 6000 do
      if (i mod 3) = 0 then T.Insert(QWord(i), Q(i));
    T.Commit;
    Chk('BD12a', T.Count = 6000, 'count=' + IntToStr(T.Count));
    ChkVerify('BD12b', T);
    if T.DenseLeaves(rep) then
      WriteLn('INFO BD12 yaprak dolulugu: ', rep)
    else
    begin
      Inc(GFail);
      WriteLn('FAIL BD12 DenseLeaves bos agac bildirdi');
    end;
    WalkOf(T, cnt, ordered, sum);
    Chk('BD12c', ordered and (cnt = 6000), 'walk=' + IntToStr(cnt));

    { BD17: hepsi silinip AYNI sirayla yeniden eklenince sayfa sayaci
      sismemeli; serbest liste geri kazanilan sayfalari vermeli. }
    beforePages := Integer(T.PageCount);
    for i := 1 to 6000 do T.Delete(QWord(i));
    T.Commit;
    Chk('BD17a', T.Count = 0, 'hepsi silindi count=' + IntToStr(T.Count));
    ChkVerify('BD17b', T);
    for i := 0 to 5999 do T.Insert(QWord(perm[i] + 1), Q(perm[i] + 1));
    T.Commit;
    afterPages := Integer(T.PageCount);
    Chk('BD17c', afterPages <= beforePages,
      'once=' + IntToStr(beforePages) + ' sonra=' + IntToStr(afterPages));
    Chk('BD17d', T.Count = 6000, 'count=' + IntToStr(T.Count));
    ChkVerify('BD17e', T);
  finally
    T.Free;
  end;
end;

{ ------------------------------------------------------------------ BD13 }
procedure ScenarioTornMeta;
var
  file_: string;
  T: TBtdTree;
  i, newest, cnt: Integer;
  ordered: Boolean;
  sum: Int64;
  v: QWord;
begin
  file_ := DbPath('tornmeta.vdb');
  T := TBtdTree.Create(file_);
  T.CommitOnClose := False;
  try
    for i := 1 to 300 do T.Insert(QWord(i), Q(i));
    T.Commit;
  finally
    T.Free;
  end;

  T := TBtdTree.Create(file_);
  T.CommitOnClose := False;
  try
    for i := 301 to 600 do T.Insert(QWord(i), Q(i));
    T.Commit;
  finally
    T.Free;
  end;

  newest := NewestMetaPage(file_);
  Chk('BD13a', newest >= 0, 'yeni meta sayfasi=' + IntToStr(newest));
  FlipByte(file_, Int64(newest) * BTD_PAGE + 100);   { meta kaydini boz }

  T := TBtdTree.Create(file_);
  T.CommitOnClose := False;
  try
    Chk('BD13b', T.Count = 300, 'onceki agac count=' + IntToStr(T.Count));
    ChkPresent('BD13c', T, 1, 300, True);
    ChkPresent('BD13d', T, 301, 600, False);
    Chk('BD13e', not T.Find(301, v), 'tek yeni anahtar yok');
    WalkOf(T, cnt, ordered, sum);
    Chk('BD13f', ordered and (cnt = 300), 'walk=' + IntToStr(cnt));
    ChkVerify('BD13g', T);
  finally
    T.Free;
  end;
end;

{ ------------------------------------------------------------------ BD14 }
procedure ScenarioCrashPoint;
var
  file_, snap: string;
  T, S: TBtdTree;
  hook: TSnapHook;
  i, cnt: Integer;
  ordered: Boolean;
  sum: Int64;
  v: QWord;
begin
  file_ := DbPath('crash.vdb');
  snap := DbPath('crash_snap.vdb');
  T := TBtdTree.Create(file_);
  T.CommitOnClose := False;
  hook := nil;
  try
    T.AutoCommitEvery := 0;
    for i := 1 to 200 do T.Insert(QWord(i), Q(i));
    T.Commit;

    hook := TSnapHook.Create;
    hook.Src := file_;
    hook.Snap := snap;
    T.OnBeforeMeta := hook.BeforeMeta;
    for i := 201 to 400 do T.Insert(QWord(i), Q(i));
    T.Commit;                      { kanca meta yazimindan hemen once calisir }
    T.OnBeforeMeta := nil;

    Chk('BD14a', (hook.Hits = 1) and hook.LastOk,
      'kanca=' + IntToStr(hook.Hits));
    Chk('BD14b', T.Count = 400, 'asil dosya count=' + IntToStr(T.Count));
  finally
    T.OnBeforeMeta := nil;
    T.Free;
    hook.Free;
  end;

  { Kopya, meta yazimindan ONCEKI durum: onceki agac TAM okunmali. }
  S := TBtdTree.Create(snap);
  S.CommitOnClose := False;
  try
    Chk('BD14c', S.Count = 200, 'kopya count=' + IntToStr(S.Count));
    ChkPresent('BD14d', S, 1, 200, True);
    ChkPresent('BD14e', S, 201, 400, False);
    Chk('BD14f', not S.Find(201, v), 'tek yeni anahtar yok');
    WalkOf(S, cnt, ordered, sum);
    Chk('BD14g', ordered and (cnt = 200), 'walk=' + IntToStr(cnt));
    ChkVerify('BD14h', S);
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------- BD15-17 }
procedure ScenarioCorruption;
var
  file_: string;
  T: TBtdTree;
  i: Integer;
  v: QWord;
  rootNo: LongWord;
  raised: Boolean;
  av: Boolean;
  verifyOk: Boolean;
  rep: string;
  fs: TFileStream;
  buf: array[0..99] of Byte;
begin
  { --- BD15: YALNIZ CRC bozulmasi (Sprint D 6.1) ----------------------
    Basligin kullanilmayan kuyruk baytlarindan biri (+24): yapi bozulmaz,
    yalnizca CRC tutmaz. Sprint D oncesi bu sayfa acilista sessizce
    "erisilemez" sayilip serbest listeye dusuruluyordu; artik acilis
    KONTROLLU bir EBtdError ile reddedilir (veri kaybini gizleyen sessiz
    fallback yasak). }
  file_ := DbPath('crc.vdb');
  T := TBtdTree.Create(file_);
  T.CommitOnClose := False;
  try
    for i := 1 to 500 do T.Insert(QWord(i), Q(i));
    T.Commit;
    rootNo := T.RootPage;
  finally
    T.Free;
  end;

  FlipByte(file_, Int64(rootNo) * BTD_PAGE + 24);

  raised := False;
  av := False;
  rep := '';
  T := nil;
  try
    T := TBtdTree.Create(file_);
    T.CommitOnClose := False;
  except
    on E: EBtdError do
    begin
      raised := True;
      rep := E.Message;
    end;
    on E: Exception do
    begin
      av := E is EAccessViolation;
      WriteLn('FAIL BD15a beklenmeyen istisna: ', E.ClassName, ': ', E.Message);
    end;
  end;
  try
    Chk('BD15a', raised, 'CRC bozuk kokte acilis reddedilmeli: ' + rep);
    Chk('BD15b', not av, 'okuma yolunda erisim ihlali OLMAMALI');
    Chk('BD15c', Pos('CRC', rep) > 0, 'hata mesaji CRC demeli: ' + rep);
  finally
    T.Free;
  end;

  { --- BD16: YAPISAL bozulma (Sprint D 6.2) --------------------------
    Ic sayfa hucreleri sayfa sonundan geriye yazilir; en son bayt en ust
    hucrenin (sol-cocuk isaretcisi) parcasi. Bozulma sonrasi CRC YENIDEN
    damgalanir: boylece sayfa "CRC gecerli ama yapisal olarak bozuk"
    durumuna gelir ve yalniz yapisal dogrulamanin yakalayabilecegi bir
    vaka olculur. Beklenti: acilis KONTROLLU EBtdError ile reddedilir,
    erisim ihlali olmaz. }
  file_ := DbPath('struct.vdb');
  T := TBtdTree.Create(file_);
  T.CommitOnClose := False;
  try
    for i := 1 to 500 do T.Insert(QWord(i), Q(i));
    T.Commit;
    rootNo := T.RootPage;
  finally
    T.Free;
  end;

  FlipByte(file_, Int64(rootNo) * BTD_PAGE + (BTD_PAGE - 1));
  RestampCrc(file_, Int64(rootNo) * BTD_PAGE);

  raised := False;
  av := False;
  rep := '';
  T := nil;
  try
    T := TBtdTree.Create(file_);
    T.CommitOnClose := False;
  except
    on E: EBtdError do
    begin
      raised := True;
      rep := E.Message;
    end;
    on E: Exception do
    begin
      av := E is EAccessViolation;
      WriteLn('FAIL BD16a beklenmeyen istisna: ', E.ClassName, ': ', E.Message);
    end;
  end;
  try
    Chk('BD16a', raised, 'yapisal bozulmada acilis reddedilmeli: ' + rep);
    Chk('BD16b', not av, 'yapisal bozulmada erisim ihlali OLMAMALI');
  finally
    T.Free;
  end;

  { --- BD18: kesik dosya sessizce yeni agac KURMAMALI ---------------- }
  file_ := DbPath('short.vdb');
  FillChar(buf, SizeOf(buf), 0);
  fs := TFileStream.Create(file_, fmCreate);
  try
    fs.WriteBuffer(buf, SizeOf(buf));
  finally
    fs.Free;
  end;
  raised := False;
  av := False;
  try
    T := TBtdTree.Create(file_);
    T.CommitOnClose := False;
    T.Free;
  except
    on E: EBtdError do raised := True;
    on E: Exception do
    begin
      av := E is EAccessViolation;
      WriteLn('FAIL BD18 beklenmeyen istisna: ', E.ClassName, ': ', E.Message);
    end;
  end;
  Chk('BD18a', raised, 'kesik dosya EBtdError vermeli, sessizce yeni agac kurmamali');
  Chk('BD18b', not av, 'kesik dosyada erisim ihlali OLMAMALI');
end;

begin
  GPass := 0;
  GFail := 0;
  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) +
    'tmp/btree_disk');
  WipeDir(GDir);
  WriteLn('B+Tree disk sayfa bicimi kapisi (VDbBTreeDisk, v5 motoruna BAGLI DEGIL)');
  try
    ScenarioBasic;
    ScenarioOrders;
    ScenarioNextAfter;
    ScenarioSplitChurn;
    ScenarioTornMeta;
    ScenarioCrashPoint;
    ScenarioCorruption;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL BEKLENMEYEN ISTISNA ', E.ClassName, ': ', E.Message);
    end;
  end;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail = 0 then ExitCode := 0 else ExitCode := GFail;
end.
