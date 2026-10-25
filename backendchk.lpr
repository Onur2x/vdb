program backendchk;

{ VDB v3 - Backend dikisi dogrulama (Sprint 2 / 2.1-2.4)

  Denetlenenler:
    1) TVDbBackendV2: TVDb ile BIREBIR ayni sonuc (put/get/delete/count/
       scan, toplu yazim, geri alma).
    2) TVDbBackendV3: ayni arayuz sozlesmesi sayfa motoru uzerinde.
    3) v3 toplu yazim: CommitBatch sonrasi kalici; AbortBatch sonrasi
       HICBIR SEY yazilmamis (yeniden acilista gorunmez).
    4) v3 parti icinde okuma kaplamayi gorur.
    5) v3 tablo filtresi (row tag) ScanAll ve ScanRawIterAll'da.
    6) v3 checkpoint esigi: cok kucuk esikte WAL budanir, veri korunur.
    7) v3 kucuk havuzda N satir toplu yazim (tahliye + WAL yolu).
    8) v2 ve v3 ayni arayuzle ayni sonucu verir (davranis esitligi).

  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: backendchk <calisma_dizini> [satir_sayisi]
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: TEvent/TThread icin cthreads programin EN BASINDA olmali;
    yoksa TEvent.Create "Failed to create OS basic event" verir. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, VDbBackendApi, VDbCore, VDbBackendV2, VDbBackendV3,
  VDbPageEngine, VDbPage, VDbPageStore, VDbPageCrypto;

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

procedure MakeVal(Key: QWord; Len, Seed: Integer; out V: TBytes);
var
  i: Integer;
begin
  SetLength(V, Len);
  for i := 0 to Len - 1 do
    V[i] := Byte(((Key * 37) + QWord(Seed) * 101 + QWord(i) * 7) and $FF);
end;

function ValEq(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and
            ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

function DirOf(const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(gDir) + Name;
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

{ Dosyada ham bayt dizisi var mi (sifreleme sizinti denetimi). }
function FileHasBytes(const APath: string; const Needle: TBytes): Boolean;
var
  fs: TFileStream;
  data: TBytes;
  i, n, m: Integer;
begin
  Result := False;
  if not FileExists(APath) then Exit;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    n := fs.Size;
    SetLength(data, n);
    if n > 0 then fs.ReadBuffer(data[0], n);
  finally
    fs.Free;
  end;
  m := Length(Needle);
  if m = 0 then Exit(True);
  for i := 0 to n - m do
    if CompareMem(@data[i], @Needle[0], m) then Exit(True);
end;

{ ================================================= 1) v2 adaptor: birebir }

procedure TestV2Adapter;
var
  db: TVDb;
  b: IVDbBackend;
  v, w: TBytes;
  i: Integer;
  keys: TQWordArray;
  vals: TValArray;
begin
  CleanDir;
  db := TVDb.Create;
  try
    db.Open(DirOf('v2.odb'));
    b := TVDbBackendV2.Create(db);
    for i := 1 to 100 do
    begin
      MakeVal(i, 24, 5, v);
      b.Put(i, v);
    end;
    if b.Count = 100 then Ok('v2 adaptor: 100 kayit')
    else Fail(Format('v2 adaptor: count=%d', [b.Count]));
    if b.Exists(50) and not b.Exists(101) then Ok('v2 adaptor: Exists dogru')
    else Fail('v2 adaptor: Exists yanlis');

    MakeVal(50, 24, 5, v);
    if b.Get(50, w) and ValEq(w, v) then Ok('v2 adaptor: Get birebir')
    else Fail('v2 adaptor: Get yanlis');

    if b.Delete(50) and (not b.Exists(50)) and (b.Count = 99) then
      Ok('v2 adaptor: Delete + Count')
    else Fail('v2 adaptor: Delete yanlis');

    keys := nil;
    vals := nil;
    b.ScanAll(keys, vals, -1);
    if Length(keys) = 99 then Ok('v2 adaptor: ScanAll 99 kayit')
    else Fail(Format('v2 adaptor: ScanAll=%d', [Length(keys)]));

    b.BeginBatch;
    if not b.InBatch then Fail('v2 adaptor: InBatch False')
    else Ok('v2 adaptor: InBatch True');
    for i := 200 to 299 do
    begin
      MakeVal(i, 24, 5, v);
      b.Put(i, v);
    end;
    b.CommitBatch;
    if (b.Count = 199) and b.Exists(299) then
      Ok('v2 adaptor: CommitBatch kalici (199)')
    else
      Fail(Format('v2 adaptor: CommitBatch sonrasi count=%d', [b.Count]));

    b.BeginBatch;
    for i := 300 to 399 do
    begin
      MakeVal(i, 24, 5, v);
      b.Put(i, v);
    end;
    b.AbortBatch;
    if (b.Count = 199) and (not b.Exists(300)) then
      Ok('v2 adaptor: AbortBatch geri aldi')
    else
      Fail(Format('v2 adaptor: AbortBatch sonrasi count=%d', [b.Count]));

    b := nil;
  finally
    db.Free;
  end;
end;

{ ======================================================= 2) v3 temel sozlesme }

function RowTag(const PlainValue: TBytes; ValueLen: Integer): Integer;
begin
  { Degerin ilk bayti tablo kimligi; 0 = satir degil. }
  if ValueLen < 1 then Exit(-1);
  Result := PlainValue[0];
  if Result = 0 then Result := -1;
end;

function MakeTagged(Tag: Byte; Key: QWord; Len: Integer): TBytes;
var
  i: Integer;
begin
  SetLength(Result, Len);
  Result[0] := Tag;
  for i := 1 to Len - 1 do
    Result[i] := Byte(((Key * 37) + QWord(i) * 7) and $FF);
end;

procedure TestV3Basic(N: Integer);
var
  b: IVDbBackend;
  v, w: TBytes;
  i: Integer;
  path: string;
begin
  CleanDir;
  path := DirOf('v3.odb');
  b := TVdbBackendV3.Create(path, True, 64);
  for i := 1 to 100 do
  begin
    MakeVal(i, 24, 5, v);
    b.Put(i, v);
  end;
  if b.Count = 100 then Ok('v3: 100 kayit')
  else Fail(Format('v3: count=%d', [b.Count]));
  if b.Exists(50) and not b.Exists(101) then Ok('v3: Exists dogru')
  else Fail('v3: Exists yanlis');
  MakeVal(50, 24, 5, v);
  if b.Get(50, w) and ValEq(w, v) then Ok('v3: Get birebir')
  else Fail('v3: Get yanlis');
  if b.Delete(50) and (not b.Exists(50)) and (b.Count = 99) then
    Ok('v3: Delete + Count')
  else Fail('v3: Delete yanlis');
  MakeVal(60, 40, 9, v);
  b.Put(60, v);
  if b.Get(60, w) and ValEq(w, v) then Ok('v3: guncelleme birebir')
  else Fail('v3: guncelleme yanlis');
  b.Flush;
  b := nil;

  b := TVdbBackendV3.Create(path, False, 64);
  if b.Count = 99 then Ok('v3: yeniden acilista 99 kayit')
  else Fail(Format('v3: yeniden acilis count=%d', [b.Count]));
  MakeVal(60, 40, 9, v);
  if b.Get(60, w) and ValEq(w, v) then Ok('v3: yeniden acilista deger birebir')
  else Fail('v3: yeniden acilista deger yanlis');
  if not b.Exists(50) then Ok('v3: silinen anahtar kalici')
  else Fail('v3: silinen anahtar geri geldi');
  b := nil;
end;

{ ================================================== 3) v3 toplu yazim / abort }

procedure TestV3Batch;
var
  b: IVDbBackend;
  v: TBytes;
  i: Integer;
  path: string;
begin
  CleanDir;
  path := DirOf('batch.odb');
  b := TVdbBackendV3.Create(path, True, 64);
  b.BeginBatch;
  for i := 1 to 200 do
  begin
    MakeVal(i, 24, 3, v);
    b.Put(i, v);
  end;
  if b.Get(150, v) and (Length(v) = 24) then
    Ok('v3: parti icinde okuma kaplamayi gorur')
  else
    Fail('v3: parti icinde okuma basarisiz');
  b.CommitBatch;
  if (b.Count = 200) and (not b.InBatch) then
    Ok('v3: CommitBatch 200 kayit')
  else
    Fail(Format('v3: CommitBatch count=%d', [b.Count]));

  b.BeginBatch;
  for i := 201 to 400 do
  begin
    MakeVal(i, 24, 3, v);
    b.Put(i, v);
  end;
  b.Delete(1);
  if not b.Exists(1) then Ok('v3: parti icinde silme gorunur')
  else Fail('v3: parti icinde silme gorunmedi');
  b.AbortBatch;
  if b.Exists(1) and (b.Count = 200) and (not b.Exists(201)) then
    Ok('v3: AbortBatch hicbir sey yazmadi')
  else
    Fail(Format('v3: AbortBatch sonrasi count=%d', [b.Count]));

  b.BeginBatch;
  for i := 1 to 50 do b.Delete(i);
  { Sprint 3.12: parti icinde Delete'in DONUS DEGERI anlamli olmali
    (eskiden her zaman True idi). }
  if b.Delete(999999) then
    Fail('v3: partide olmayan anahtarin silinmesi True dondu')
  else
    Ok('v3: partide olmayan anahtar Delete=False');
  b.CommitBatch;
  if b.Count = 150 then Ok('v3: partide toplu silme (150)')
  else Fail(Format('v3: toplu silme count=%d', [b.Count]));
  b := nil;

  b := TVdbBackendV3.Create(path, False, 64);
  if (b.Count = 150) and (not b.Exists(201)) then
    Ok('v3: abort partisi yeniden acilista da yok')
  else
    Fail(Format('v3: abort sonrasi kalicilik bozuk (count=%d)', [b.Count]));
  b := nil;
end;

{ ================================================== 4) tablo filtresi (row tag) }

var
  gRawHits: Integer;
  gRawStopAt: Integer;

function RawCb(Key: QWord; Buf: PByte; Len: Integer; User: Pointer): Boolean;
begin
  Inc(gRawHits);
  Result := (gRawStopAt = 0) or (gRawHits < gRawStopAt);
end;

procedure TestV3Filter;
var
  b: IVDbBackend;
  i: Integer;
  keys: TQWordArray;
  vals: TValArray;
  path: string;
begin
  CleanDir;
  path := DirOf('filter.odb');
  b := TVdbBackendV3.Create(path, True, 64);
  b.SetRowTagFunc(RowTag);
  b.BeginBatch;
  for i := 1 to 300 do
  begin
    if (i mod 3) = 0 then
      b.Put(i, MakeTagged(2, i, 20))
    else
      b.Put(i, MakeTagged(1, i, 20));
  end;
  b.Put(9999, MakeTagged(0, 9999, 8));   // sema: etiket 0 -> filtre disi
  b.CommitBatch;

  keys := nil; vals := nil;
  b.ScanAll(keys, vals, 1);
  if Length(keys) = 201 then Ok('v3: ScanAll tablo 1 -> 201 kayit')
  else Fail(Format('v3: ScanAll tablo 1 -> %d', [Length(keys)]));

  keys := nil; vals := nil;
  b.ScanAll(keys, vals, 2);
  if Length(keys) = 101 then Ok('v3: ScanAll tablo 2 -> 101 kayit (100 + sema)')
  else Fail(Format('v3: ScanAll tablo 2 -> %d', [Length(keys)]));

  keys := nil; vals := nil;
  b.ScanAll(keys, vals, -1);
  if Length(keys) = 301 then Ok('v3: ScanAll filtresiz -> 301 kayit')
  else Fail(Format('v3: ScanAll filtresiz -> %d', [Length(keys)]));
  b := nil;

  b := TVdbBackendV3.Create(path, False, 64);
  b.SetRowTagFunc(RowTag);
  gRawHits := 0;
  gRawStopAt := 0;
  b.ScanRawIterAll(2, RawCb, nil);
  if gRawHits = 101 then Ok('v3: ScanRawIterAll tablo 2 -> 101')
  else Fail(Format('v3: ScanRawIterAll tablo 2 -> %d', [gRawHits]));

  gRawHits := 0;
  gRawStopAt := 10;
  b.ScanRawIterAll(2, RawCb, nil);
  if gRawHits = 10 then Ok('v3: ScanRawIterAll erken durur (10)')
  else Fail(Format('v3: erken durma %d', [gRawHits]));
  b := nil;
end;

{ ================================================== 5) checkpoint esigi }

procedure TestV3Checkpoint;
var
  be: TVdbBackendV3;
  b: IVDbBackend;
  v: TBytes;
  i: Integer;
  path: string;
  wal: Int64;
begin
  CleanDir;
  path := DirOf('ckpt.odb');
  be := TVdbBackendV3.Create(path, True, 64);
  b := be;                       { ayri referans: be'yi b serbest birakir }
  be.CheckpointBytes := 64 * 1024;   // cok kucuk: her partide checkpoint
  for i := 1 to 2000 do
  begin
    MakeVal(i, 32, 4, v);
    b.Put(i, v);
    if (i mod 100) = 0 then b.Flush;
  end;
  b.Flush;
  wal := be.Engine.Wal.Bytes;
  if wal <= 64 * 1024 then
    Ok(Format('v3: checkpoint esigi calisti (WAL=%d bayt)', [wal]))
  else
    Fail(Format('v3: WAL esigi asildi (%d bayt)', [wal]));
  b := nil;                      { be'yi serbest birakir; sonra DOKUNMA }

  b := TVdbBackendV3.Create(path, False, 64);
  if b.Count = 2000 then Ok('v3: checkpoint sonrasi 2000 kayit korundu')
  else Fail(Format('v3: checkpoint sonrasi count=%d', [b.Count]));
  b := nil;
end;

{ ================================================== 6) kucuk havuz + N }

{ Regresyon: sayfa tahliye edilip WAL tamponuna (pending) girdikten SONRA
  yeniden okunup degistirilirse, checkpoint ESKI pending imajini yeni
  cercevenin uzerine yazmamalidir. Bu hata sema kaydinin ve/veya
  guncellenen sayfalarin sessizce kaybolmasina yol aciyordu. }
procedure TestV3SpillReread(N: Integer);
var
  b: IVDbBackend;
  v, w: TBytes;
  i: Integer;
  path: string;
  bad: Integer;
begin
  CleanDir;
  path := DirOf('spill.odb');
  b := TVdbBackendV3.Create(path, True, 4);   // 4 cerceve: tahliye kacinilmaz
  b.BeginBatch;
  for i := 1 to N do
  begin
    MakeVal(i, 40, 1, v);
    b.Put(i, v);
  end;
  b.CommitBatch;                              // sayfalar WAL tamponunda
  { Ayni anahtarlari FARKLI boyutta yeniden yaz: eski deger artik diskte
    degil, pending imajinda; okuma OnMiss ile oradan gelir. }
  b.BeginBatch;
  for i := N downto 1 do
  begin
    MakeVal(i, 64, 2, v);
    b.Put(i, v);
  end;
  b.CommitBatch;
  b.Flush;                                    // dayanikli commit (WAL + fsync)
  b := nil;

  b := TVdbBackendV3.Create(path, False, 4);
  bad := 0;
  for i := 1 to N do
  begin
    MakeVal(i, 64, 2, v);
    if not b.Get(i, w) then
    begin
      Inc(bad);
      if bad <= 3 then WriteLn(Format('        kayip: %d', [i]));
    end
    else if not ValEq(w, v) then
    begin
      Inc(bad);
      if bad <= 3 then WriteLn(Format('        bozuk: %d', [i]));
    end;
  end;
  if bad = 0 then
    Ok(Format('v3: tahliye sonrasi yeniden yazim %d satir birebir', [N]))
  else
    Fail(Format('v3: tahliye sonrasi %d satir bozuk', [bad]));
  b := nil;
end;

procedure TestV3SmallPool(N: Integer);
var
  b: IVDbBackend;
  v, w: TBytes;
  i: Integer;
  path: string;
  bad: Integer;
  keys: TQWordArray;
  vals: TValArray;
begin
  CleanDir;
  path := DirOf('pool.odb');
  b := TVdbBackendV3.Create(path, True, 8);
  b.BeginBatch;
  for i := 1 to N do
  begin
    MakeVal(i, 32, 6, v);
    b.Put(i, v);
  end;
  b.CommitBatch;
  if b.Count = N then Ok(Format('v3: kucuk havuzda %d satir yazildi', [N]))
  else Fail(Format('v3: kucuk havuz count=%d', [b.Count]));
  b.Flush;
  b := nil;

  b := TVdbBackendV3.Create(path, False, 8);
  bad := 0;
  for i := 1 to N do
  begin
    if not b.Get(i, w) then
    begin
      Inc(bad);
      if bad < 3 then WriteLn(Format('        eksik: %d', [i]));
      Continue;
    end;
    MakeVal(i, 32, 6, v);
    if not ValEq(w, v) then
    begin
      Inc(bad);
      if bad < 3 then WriteLn(Format('        bozuk: %d', [i]));
    end;
  end;
  if bad = 0 then Ok(Format('v3: kucuk havuzda %d satirin tamami birebir', [N]))
  else Fail(Format('v3: kucuk havuzda %d bozuk', [bad]));

  keys := nil; vals := nil;
  b.ScanAll(keys, vals, -1);
  if Length(keys) = N then Ok('v3: kucuk havuz ScanAll tam')
  else Fail(Format('v3: kucuk havuz ScanAll=%d', [Length(keys)]));
  b := nil;
end;

{ ================================================== 7) v2 / v3 davranis esitligi }

procedure TestEquivalence(N: Integer);
var
  db: TVDb;
  b2: IVDbBackend;
  b3: IVDbBackend;
  v, a, b: TBytes;
  i: Integer;
  k2, k3: TQWordArray;
  va2, va3: TValArray;
  same: Boolean;
begin
  CleanDir;
  db := TVDb.Create;
  try
    db.Open(DirOf('eq_v2.odb'));
    b2 := TVDbBackendV2.Create(db);
    b3 := TVdbBackendV3.Create(DirOf('eq_v3.odb'), True, 128);
    for i := 1 to N do
    begin
      MakeVal(i, 28, 8, v);
      b2.Put(i, v);
      b3.Put(i, v);
    end;
    for i := 1 to N do
      if (i mod 5) = 0 then
      begin
        b2.Delete(i);
        b3.Delete(i);
      end;
    for i := 1 to N do
      if (i mod 7) = 0 then
      begin
        MakeVal(i, 36, 2, v);
        b2.Put(i, v);
        b3.Put(i, v);
      end;
    b2.Flush;
    b3.Flush;

    if b2.Count = b3.Count then
      Ok(Format('esitlik: count ayni (%d)', [b2.Count]))
    else
      Fail(Format('esitlik: count v2=%d v3=%d', [b2.Count, b3.Count]));

    k2 := nil; va2 := nil; k3 := nil; va3 := nil;
    b2.ScanAll(k2, va2, -1);
    b3.ScanAll(k3, va3, -1);
    { Sira motorun fiziksel duzenine baglidir (v3 sayfa sirasi, v2 kova
      sirasi); karsilastirma KUME + DEGER uzerinden yapilir. }
    same := Length(k2) = Length(k3);
    if same then
      for i := 0 to High(k2) do
      begin
        if not b3.Get(k2[i], b) then
        begin
          same := False;
          WriteLn(Format('        v3 eksik anahtar: %d', [k2[i]]));
          Break;
        end;
        if not ValEq(va2[i], b) then
        begin
          same := False;
          WriteLn(Format('        v3 farkli deger: %d', [k2[i]]));
          Break;
        end;
      end;
    if same then Ok('esitlik: ScanAll kume ve degerler birebir')
    else Fail(Format('esitlik: ScanAll farkli (v2=%d v3=%d)',
      [Length(k2), Length(k3)]));

    same := True;
    for i := 1 to N do
    begin
      if b2.Get(i, a) <> b3.Get(i, b) then
      begin
        same := False;
        Break;
      end;
      if not ValEq(a, b) then
      begin
        same := False;
        Break;
      end;
    end;
    if same then Ok('esitlik: nokta okumalari birebir')
    else Fail('esitlik: nokta okumalari farkli');

    b2 := nil;
    b3 := nil;
  finally
    db.Free;
  end;
end;

{ ========================================== 8) v3 VERIFY (Sprint 3.1) }

procedure TestV3Verify(N: Integer);
var
  v3: TVdbBackendV3;
  b: IVdbBackend;
  eng: TVdbPageEngine;
  v: TBytes;
  i: Integer;
  pno: LongWord;
  P: PVdbPage;
  rep: string;
  magic: Word;
  corrupt, found: Boolean;
begin
  CleanDir;
  v3 := TVdbBackendV3.Create(DirOf('verify.odb'), True, 128);
  b := v3;
  eng := v3.Engine;
  for i := 1 to N do
  begin
    MakeVal(i, 40 + (i mod 60), 5, v);
    b.Put(i, v);
  end;
  for i := 1 to N do
    if (i mod 4) = 0 then
      b.Delete(i);
  { Tasma zincirleri de denetimden gecsin (1000 bayt esigi asilir). }
  MakeVal(900001, 2500, 9, v);
  b.Put(900001, v);
  MakeVal(900002, 9000, 11, v);
  b.Put(900002, v);
  b.Flush;

  if b.Verify(rep) then
    Ok('v3 VERIFY saglikli dosyada gecti: ' + rep)
  else
    Fail('v3 VERIFY saglikli dosyada dustu: ' + rep);
  if Pos('anahtar=', rep) > 0 then
    Ok('v3 VERIFY raporu anahtar sayisi iceriyor')
  else
    Fail('v3 VERIFY raporu eksik: ' + rep);
  if Pos('tasma=0 ', rep) = 0 then
    Ok('v3 VERIFY tasma zincirlerini sonuna kadar yurudu')
  else
    Fail('v3 VERIFY tasma sayaci beklenmedik: ' + rep);

  { Acik parti varken denetim yapilmaz: sessiz commit yerine net ret. }
  b.BeginBatch;
  b.Put(900001, v);
  if (not b.Verify(rep)) and (Pos('acik parti', rep) > 0) then
    Ok('v3 VERIFY acik partide reddedildi')
  else
    Fail('v3 VERIFY acik partide yanlis sonuc: ' + rep);
  b.AbortBatch;

  { Bozulma enjeksiyonu: heap sayfasinin govdesinden bir bayt cevrilir.
    Bellekteki anahtar dizini saglam kalir; hatayi yalnizca sayfa
    denetimi (CRC/yapi) yakalayabilir. }
  found := False;
  for pno := 1 to eng.Store.PageCount - 1 do
  begin
    if not eng.Store.GetRawPage(pno, P) then Continue;
    corrupt := False;
    Move(P^[0], magic, SizeOf(magic));
    if (magic = VDB_PAGE_MAGIC) and (PageTypeOf(P) = VDB_PAGE_HEAP) and
       (PageSlotCount(P) > 0) then
    begin
      P^[100] := P^[100] xor $FF;
      corrupt := True;
    end;
    eng.Store.Release(pno, corrupt);
    if corrupt then
    begin
      found := True;
      Break;
    end;
  end;
  if not found then
    Fail('v3 VERIFY: bozulacak heap sayfasi bulunamadi')
  else
  begin
    eng.Store.Flush(True);
    if (not b.Verify(rep)) and
       ((Pos('CRC', rep) > 0) or (Pos('bozuk', rep) > 0)) then
      Ok('v3 VERIFY bozuk sayfayi yakaladi: ' + rep)
    else
      Fail('v3 VERIFY bozuk sayfayi kacirdi: ' + rep);
  end;

  b := nil;
  v3 := nil;
end;

{ ==================================== 9) v3 BACKUP / RESTORE (Sprint 3.2) }

procedure TestV3BackupRestore(N: Integer);
var
  v3: TVdbBackendV3;
  b, b2: IVdbBackend;
  v, got: TBytes;
  i: Integer;
  rep, bak, junk: string;
  raised: Boolean;
begin
  CleanDir;
  bak := DirOf('br_backup.odb');
  junk := DirOf('br_junk.odb');
  v3 := TVdbBackendV3.Create(DirOf('br_main.odb'), True, 128);
  b := v3;
  for i := 1 to N do
  begin
    MakeVal(i, 30 + (i mod 40), 3, v);
    b.Put(i, v);
  end;
  { Bir tasma degeri de yedege girsin. }
  MakeVal(500001, 5000, 7, v);
  b.Put(500001, v);
  b.Flush;

  b.BackupTo(bak);
  if FileExists(bak) then Ok('v3 BACKUP dosyasi olustu')
  else Fail('v3 BACKUP dosyasi yok');

  { Yedegi BAGIMSIZ bir motorla ac ve dogrula: yedek kendi kendine yeter. }
  b2 := TVdbBackendV3.Create(bak, False, 64);
  if b2.Verify(rep) then Ok('v3 BACKUP dogrulandi: ' + rep)
  else Fail('v3 BACKUP bozuk: ' + rep);
  if b2.Count = N + 1 then Ok('v3 BACKUP anahtar sayisi dogru')
  else Fail(Format('v3 BACKUP Count=%d beklenen %d', [b2.Count, N + 1]));
  MakeVal(500001, 5000, 7, v);
  if b2.Get(500001, got) and (Length(got) = Length(v)) and
     (CompareMem(@got[0], @v[0], Length(v))) then
    Ok('v3 BACKUP tasma degeri birebir')
  else
    Fail('v3 BACKUP tasma degeri bozuk');
  b2 := nil;

  { Asil dosyayi degistir: yedekten farkli bir durum olussun. }
  for i := 1 to N do
    if (i mod 3) = 0 then
      b.Delete(i);
  MakeVal(700001, 20, 4, v);
  b.Put(700001, v);
  b.Flush;

  b.RestoreFrom(bak);
  if b.Count = N + 1 then Ok('v3 RESTORE anahtar sayisini geri getirdi')
  else Fail(Format('v3 RESTORE Count=%d beklenen %d', [b.Count, N + 1]));
  if not b.Get(700001, got) then Ok('v3 RESTORE sonradan eklenen anahtari atti')
  else Fail('v3 RESTORE sonradan eklenen anahtar duruyor');
  if b.Verify(rep) then Ok('v3 RESTORE sonrasi VERIFY gecti')
  else Fail('v3 RESTORE sonrasi VERIFY: ' + rep);
  if FileExists(DirOf('br_main.odb.bak')) then
    Ok('v3 RESTORE eski dosyayi .bak birakti')
  else
    Fail('v3 RESTORE .bak birakmadi');

  { Acik parti varken yedek alinmaz. }
  b.BeginBatch;
  MakeVal(888888, 10, 2, v);
  b.Put(888888, v);
  raised := False;
  try
    b.BackupTo(DirOf('br_x.odb'));
  except
    on E: Exception do raised := True;
  end;
  b.AbortBatch;
  if raised then Ok('v3 BACKUP acik partide reddedildi')
  else Fail('v3 BACKUP acik partide sessizce gecti');

  { v3 olmayan kaynak reddedilir; mevcut veritabani bozulmaz. }
  with TFileStream.Create(junk, fmCreate) do
  try
    WriteBuffer('bu bir vdb dosyasi degil', 25);
  finally
    Free;
  end;
  raised := False;
  try
    b.RestoreFrom(junk);
  except
    on E: Exception do raised := True;
  end;
  if raised then Ok('v3 RESTORE v3 olmayan dosyayi reddetti')
  else Fail('v3 RESTORE v3 olmayan dosyayi kabul etti');
  if b.Verify(rep) and (b.Count = N + 1) then
    Ok('v3 RESTORE reddinden sonra veritabani saglam')
  else
    Fail('v3 RESTORE reddinden sonra bozulma: ' + rep);

  b := nil;
  v3 := nil;
end;

{ ============================================ 10) v3 VACUUM (Sprint 3.3) }

procedure TestV3Compact(N: Integer);
var
  v3: TVdbBackendV3;
  b: IVdbBackend;
  v, got: TBytes;
  i: Integer;
  rep: string;
  oldB, newB: Int64;
  raised: Boolean;
begin
  CleanDir;
  v3 := TVdbBackendV3.Create(DirOf('compact.odb'), True, 128);
  b := v3;
  for i := 1 to N do
  begin
    MakeVal(i, 60, 5, v);
    b.Put(i, v);
  end;
  { Sisme uret: buyuk tasma degerleri yaz, sonra hepsini sil. }
  for i := 1 to 200 do
  begin
    MakeVal(1000000 + i, 6000, 9, v);
    b.Put(1000000 + i, v);
  end;
  for i := 1 to N do
    if (i mod 2) = 0 then
      b.Delete(i);
  for i := 1 to 200 do
    b.Delete(1000000 + i);
  b.Flush;

  b.Compact(oldB, newB);
  if newB < oldB then
    Ok(Format('v3 VACUUM dosyayi kuculttu: %d -> %d bayt', [oldB, newB]))
  else
    Fail(Format('v3 VACUUM kucultmedi: %d -> %d', [oldB, newB]));
  if b.Count = (N + 1) div 2 then
    Ok('v3 VACUUM anahtar sayisi dogru')
  else
    Fail(Format('v3 VACUUM Count=%d beklenen %d', [b.Count, (N + 1) div 2]));
  if b.Verify(rep) then
    Ok('v3 VACUUM sonrasi VERIFY: ' + rep)
  else
    Fail('v3 VACUUM sonrasi VERIFY: ' + rep);

  MakeVal(1, 60, 5, v);
  if b.Get(1, got) and (Length(got) = Length(v)) and
     CompareMem(@got[0], @v[0], Length(v)) then
    Ok('v3 VACUUM canli deger birebir')
  else
    Fail('v3 VACUUM canli deger bozuk');
  if not b.Get(2, got) then
    Ok('v3 VACUUM silinen anahtari geri getirmedi')
  else
    Fail('v3 VACUUM silinen anahtar geri geldi');

  { VACUUM sonrasi yazim/okuma ayni oturumda calismali. }
  MakeVal(777, 1200, 3, v);
  b.Put(777, v);
  b.Flush;
  if b.Get(777, got) and (Length(got) = Length(v)) then
    Ok('v3 VACUUM sonrasi yazim calisiyor')
  else
    Fail('v3 VACUUM sonrasi yazim bozuk');
  if FileExists(DirOf('compact.odb.bak')) then
    Ok('v3 VACUUM eski dosyayi .bak birakti')
  else
    Fail('v3 VACUUM .bak birakmadi');

  b.BeginBatch;
  b.Put(888, v);
  raised := False;
  try
    b.Compact(oldB, newB);
  except
    on E: Exception do raised := True;
  end;
  b.AbortBatch;
  if raised then Ok('v3 VACUUM acik partide reddedildi')
  else Fail('v3 VACUUM acik partide sessizce gecti');

  b := nil;
  v3 := nil;

  { Bos veritabani uzerinde VACUUM: gecerli ve minimum boyut. }
  v3 := TVdbBackendV3.Create(DirOf('empty.odb'), True, 16);
  b := v3;
  b.Compact(oldB, newB);
  if (newB > 0) and (newB <= 64 * 1024) and (b.Count = 0) and b.Verify(rep) then
    Ok(Format('v3 VACUUM bos veritabani: %d bayt', [newB]))
  else
    Fail(Format('v3 VACUUM bos veritabani: %d bayt, count=%d', [newB, b.Count]));
  b := nil;
  v3 := nil;
end;

{ Sprint 3.4: sayfa duzeyi AES-GCM sifreleme kapisi. }
procedure TestV3Encryption(N: Integer);
const
  MARK: array[0..15] of AnsiChar = 'V3GIZLI-MARKER01';
var
  v3: TVdbBackendV3;
  b: IVDbBackend;
  v, got, key, key2: TBytes;
  rep, msg: string;
  raised: Boolean;
  plainPath, encPath, bakPath, walPath: string;
  oldB, newB: Int64;
  fs: TFileStream;
  x: Byte;
  eng: TVdbPageEngine;
  i: Integer;
begin
  CleanDir;
  WriteLn;
  WriteLn('Sprint 3.4 - sayfa sifreleme (AES-256-GCM)');

  key := VDbPageNewKey;
  key2 := VDbPageNewKey;
  SetLength(v, Length(MARK));
  Move(MARK[0], v[0], Length(MARK));

  { 1) Varsayilan sifresiz: deger dosyada duz metin. }
  plainPath := DirOf('enc_plain.odb');
  v3 := TVdbBackendV3.Create(plainPath, True, 32);
  b := v3;
  b.Put(1, v);
  b.Flush;
  if not v3.Encrypted then
    Ok('enc1) varsayilan sifreleme KAPALI')
  else
    Fail('enc1) varsayilan sifreleme acik');
  b := nil;
  v3 := nil;
  if FileHasBytes(plainPath, v) then
    Ok('enc1) sifresiz dosyada deger duz metin (geriye uyum)')
  else
    Fail('enc1) sifresiz dosyada deger bulunamadi');

  { 2) Sifreli olustur: dosyada duz metin YOK. }
  encPath := DirOf('enc1.odb');
  v3 := TVdbBackendV3.CreateWithKey(encPath, key, True, 32);
  b := v3;
  if v3.Encrypted then
    Ok('enc2) sifreli v3 dosyasi acildi')
  else
    Fail('enc2) dosya sifreli degil');
  if v3.KeyFingerprint = VDbPageKeyFingerprint(key) then
    Ok('enc2) anahtar parmak izi: ' + v3.KeyFingerprint)
  else
    Fail('enc2) anahtar parmak izi yanlis');
  b.Put(1, v);
  b.Put(2, v);
  b.Flush;
  if b.Verify(rep) then
    Ok('enc2) sifreli dosyada VERIFY gecti')
  else
    Fail('enc2) VERIFY: ' + rep);
  b := nil;
  v3 := nil;
  if not FileHasBytes(encPath, v) then
    Ok('enc2) sifreli dosyada duz metin YOK')
  else
    Fail('enc2) SIZINTI: sifreli dosyada duz metin var');

  { 3) Dogru anahtarla yeniden acma. }
  v3 := TVdbBackendV3.CreateWithKey(encPath, key, False, 32);
  b := v3;
  if b.Get(1, got) and ValEq(got, v) then
    Ok('enc3) dogru anahtarla okundu (duz metin dondu)')
  else
    Fail('enc3) dogru anahtarla okunamadi');
  b := nil;
  v3 := nil;

  { 4) Anahtarsiz acma: net hata, sessiz bozuk veri yok. }
  raised := False;
  msg := '';
  try
    v3 := TVdbBackendV3.Create(encPath, False, 32);
  except
    on E: Exception do
    begin
      raised := True;
      msg := E.Message;
    end;
  end;
  if raised and (Pos('anahtar', LowerCase(msg)) > 0) then
    Ok('enc4) anahtarsiz acma reddedildi: ' + msg)
  else
    Fail('enc4) anahtarsiz acma reddedilmedi (msg=' + msg + ')');
  FreeAndNil(v3);

  { 5) Yanlis anahtar: anahtar dogrulayici tutmaz. }
  raised := False;
  msg := '';
  try
    v3 := TVdbBackendV3.CreateWithKey(encPath, key2, False, 32);
  except
    on E: Exception do
    begin
      raised := True;
      msg := E.Message;
    end;
  end;
  if raised and (Pos('anahtar', LowerCase(msg)) > 0) then
    Ok('enc5) yanlis anahtar reddedildi: ' + msg)
  else
    Fail('enc5) yanlis anahtar reddedilmedi (msg=' + msg + ')');
  FreeAndNil(v3);

  { 6) Yedek: sifreli kalir, ayni anahtarla acilir. }
  v3 := TVdbBackendV3.CreateWithKey(encPath, key, False, 32);
  b := v3;
  bakPath := DirOf('enc1_backup.odb');
  b.BackupTo(bakPath);
  if FileExists(bakPath) and (not FileHasBytes(bakPath, v)) then
    Ok('enc6) yedek sifreli (duz metin yok)')
  else
    Fail('enc6) yedek sifreli degil / yok');
  b := nil;
  v3 := nil;

  v3 := TVdbBackendV3.CreateWithKey(bakPath, key, False, 32);
  b := v3;
  if b.Get(1, got) and ValEq(got, v) then
    Ok('enc6) yedek dogru anahtarla okundu')
  else
    Fail('enc6) yedek okunamadi');
  b := nil;
  v3 := nil;

  raised := False;
  try
    v3 := TVdbBackendV3.CreateWithKey(bakPath, key2, False, 32);
  except
    on E: Exception do raised := True;
  end;
  FreeAndNil(v3);
  if raised then
    Ok('enc6) yedege YANLIS anahtarla erisim reddedildi')
  else
    Fail('enc6) yedege yanlis anahtarla erisildi');

  { 7) RESTORE: farkli anahtarli yedek reddedilir. }
  v3 := TVdbBackendV3.CreateWithKey(DirOf('enc1_restore.odb'), key2, True, 32);
  b := v3;
  raised := False;
  msg := '';
  try
    b.RestoreFrom(bakPath);
  except
    on E: Exception do
    begin
      raised := True;
      msg := E.Message;
    end;
  end;
  if raised and (Pos('anahtar', LowerCase(msg)) > 0) then
    Ok('enc7) farkli anahtarli RESTORE reddedildi')
  else
    Fail('enc7) farkli anahtarli RESTORE kabul edildi (msg=' + msg + ')');
  b := nil;
  v3 := nil;

  { 8) VACUUM sifrelemeyi korur ve hala duz metin sizdirmaz. }
  v3 := TVdbBackendV3.CreateWithKey(encPath, key, False, 32);
  b := v3;
  b.Compact(oldB, newB);
  if v3.Encrypted and b.Get(1, got) and ValEq(got, v) then
    Ok(Format('enc8) VACUUM sifreli kaldi (%d -> %d bayt)', [oldB, newB]))
  else
    Fail('enc8) VACUUM sonrasi sifreleme/veri bozuldu');
  b := nil;
  v3 := nil;
  if not FileHasBytes(encPath, v) then
    Ok('enc8) VACUUM sonrasi duz metin yok')
  else
    Fail('enc8) VACUUM sonrasi SIZINTI');

  { 9) Bozuk zarf: etiket tutmaz, acikca reddedilir. }
  fs := TFileStream.Create(encPath, fmOpenReadWrite or fmShareDenyWrite);
  try
    fs.Position := 4096 + 100;
    fs.ReadBuffer(x, 1);
    x := x xor $FF;
    fs.Position := 4096 + 100;
    fs.WriteBuffer(x, 1);
  finally
    fs.Free;
  end;
  v3 := nil;
  raised := False;
  msg := '';
  try
    v3 := TVdbBackendV3.CreateWithKey(encPath, key, False, 32);
    b := v3;
    b.Get(1, got);
  except
    on E: Exception do
    begin
      raised := True;
      msg := E.Message;
    end;
  end;
  if raised and (Pos('cozulemedi', LowerCase(msg)) > 0) then
    Ok('enc9) bozuk zarf reddedildi: ' + msg)
  else
    Fail('enc9) bozuk zarf sessizce gecti (msg=' + msg + ')');
  b := nil;
  v3 := nil;

  { 10) WAL cerceveleri de sifreli; cokme sonrasi anahtarla kurtarma. }
  walPath := DirOf('enc_wal.odb');
  eng := TVdbPageEngine.CreateWithKey(walPath, key, 32);
  try
    eng.Open(True);
    eng.Insert(1, v);
    eng.Commit(True);
    if not FileHasBytes(walPath + '.wal', v) then
      Ok('enc10) WAL duz metin icermiyor')
    else
      Fail('enc10) SIZINTI: WAL duz metin iceriyor');
    eng.SimulateCrash;
  finally
    eng.Free;
  end;

  eng := TVdbPageEngine.CreateWithKey(walPath, key, 32);
  try
    eng.Open(False);
    if eng.TryGet(1, got) and ValEq(got, v) then
      Ok('enc10) sifreli WAL cokme sonrasi anahtarla kurtarildi')
    else
      Fail('enc10) sifreli WAL kurtarilamadi');
  finally
    eng.Free;
  end;

  { 11) Parola modu: PBKDF2 ile turetilen anahtar kalici. }
  v3 := TVdbBackendV3.CreateWithPassword(DirOf('enc_pw.odb'), 'gizli-parola', True, 32);
  b := v3;
  b.Put(7, v);
  b.Flush;
  b := nil;
  v3 := nil;
  v3 := TVdbBackendV3.CreateWithPassword(DirOf('enc_pw.odb'), 'gizli-parola', False, 32);
  b := v3;
  if v3.Encrypted and b.Get(7, got) and ValEq(got, v) then
    Ok('enc11) parola ile yeniden acma calisti')
  else
    Fail('enc11) parola ile acilamadi');
  b := nil;
  v3 := nil;

  raised := False;
  try
    v3 := TVdbBackendV3.CreateWithPassword(DirOf('enc_pw.odb'), 'yanlis', False, 32);
  except
    on E: Exception do raised := True;
  end;
  FreeAndNil(v3);
  if raised then
    Ok('enc11) yanlis parola reddedildi')
  else
    Fail('enc11) yanlis parola kabul edildi');

  { 12) Sifreli dosyaya anahtarsiz "duz" erisim net hata. }
  raised := False;
  try
    v3 := TVdbBackendV3.Create(encPath, False, 32);
  except
    on E: Exception do raised := True;
  end;
  FreeAndNil(v3);
  if raised then
    Ok('enc12) sifreli dosya sifresiz acilamadi')
  else
    Fail('enc12) sifreli dosya sifresiz acildi');
end;

{ ================================================================== ana }

var
  N: Integer;
begin
  gPass := 0;
  gFail := 0;
  N := 5000;
  if ParamCount >= 1 then gDir := ParamStr(1) else gDir := GetCurrentDir;
  if ParamCount >= 2 then N := StrToIntDef(ParamStr(2), N);
  if not DirectoryExists(gDir) then ForceDirectories(gDir);

  WriteLn('VDB v3 backendchk - backend dikisi kapisi');
  WriteLn('dizin=', gDir, '  N=', N);
  WriteLn;

  TestV2Adapter;
  TestV3Basic(N);
  TestV3Batch;
  TestV3Filter;
  TestV3Checkpoint;
  TestV3SpillReread(N);
  TestV3SmallPool(N);
  TestV3Verify(N);
  TestV3BackupRestore(N);
  TestV3Compact(N);
  TestV3Encryption(N);
  TestEquivalence(1000);

  WriteLn;
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
  begin
    WriteLn('BACKEND DIKISI DOGRULANDI');
    Halt(0);
  end;
  WriteLn('BACKEND DIKISI HATALI');
  Halt(1);
end.
