unit VDbPageEngine;

{ VDB v3 - Sayfa motoru (Sprint 1 / Gun 5)

  Uc katmani birlestirir: TVDbPageStore (4 KB sayfalar, buffer pool),
  TVdbHeap (anahtar -> deger) ve TVdbPageWal (sayfa imajli WAL).

  Yazma protokolu (write-ahead):
    1) Islemler yalnizca BELLEGI degistirir; veritabani dosyasina
       commit'ten once sayfa YAZILMAZ.
    2) Havuz dolup kirli sayfa tahliye edilmesi gerekirse, sayfa diske
       degil WAL tamponuna (bellek) alinir (OnSpill) ve okuma oradan
       karsilanir (OnMiss). Boylece dosyada commit edilmemis sayfa olmaz.
    3) Commit: tampon + kirli sayfalar + meta sayfa imaji WAL'e yazilir,
       commit kaydi eklenir, fsync edilir.
    4) Checkpoint: onaylanmis sayfalar veritabani dosyasina yazilir,
       fsync edilir, WAL budanir. WAL yalnizca DURABIL hale geldikten
       sonra budanir; cokme halinde replay ayni imajlari yeniden yazar.

  Acilis: WAL'de commit edilmis cerceve varsa once replay edilir, sonra
  checkpoint yapilip WAL budanir; ardindan heap dizini taranarak kurulur.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Generics.Collections, VDbPage, VDbPageStore, VDbPageHeap, VDbPageWal;

type
  EVdbPageEngine = class(Exception);

  TVdbPageEngine = class
  private
    type
      TPending = record
        PageNo: LongWord;
        Data: TVdbPageBuf;
      end;
    var
      FStore: TVDbPageStore;
      FHeap: TVdbHeap;
      FWal: TVdbPageWal;
      FPending: array of TPending;
      FInTxn: Boolean;
      FWalStats: TVdbWalStats;
      FPath: string;
      FIdxUsed: Boolean;
      FIdxErr: string;
    procedure OnSpill(PageNo: LongWord; P: PVdbPage);
    function OnMiss(PageNo: LongWord; P: PVdbPage): Boolean;
    procedure ApplyRecovered(PageNo: LongWord; P: PVdbPage);
    function PendingIndex(PageNo: LongWord): Integer;
    procedure AddPending(PageNo: LongWord; P: PVdbPage);
    procedure ClearPending;
  public
    constructor Create(const ADbPath: string; APoolPages: Integer = VDB_DEF_POOL);
    destructor Destroy; override;

    { Var olan dosyayi acar; ACreate=True ise yoksa olusturur. }
    procedure Open(ACreate: Boolean = False);
    procedure Close;

    { Test: surec olumu simulasyonu. Commit edilmemis degisiklikler ve
      WAL tamponu diske yazilmadan atilir. }
    procedure SimulateCrash;

    function Insert(Key: QWord; const Value: TBytes): Boolean;
    function Update(Key: QWord; const Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    function TryGet(Key: QWord; out Value: TBytes): Boolean;
    function Contains(Key: QWord): Boolean;
    procedure ScanAll(Cb: TVdbHeap.TScanProc);
    function Stats: TVdbHeapStats;

    { Bekleyen degisiklikleri WAL'e yazip fsync eder. Veritabani dosyasina
      YAZMAZ; bunun icin Checkpoint cagrilir. DoSync=False ise fsync
      atlanir (yalniz toplu yazim/test icin). }
    function Commit(DoSync: Boolean = True): Boolean;

    { Onaylanmis sayfalari veritabani dosyasina yazar, fsync eder ve WAL'i
      budar. Cokme sonrasi acilista otomatik yapilir. }
    function Checkpoint(DoSync: Boolean = True): Boolean;

    function GetCount: Integer;
    property Count: Integer read GetCount;

    property Store: TVDbPageStore read FStore;
    property Heap: TVdbHeap read FHeap;
    property Wal: TVdbPageWal read FWal;
    property InTxn: Boolean read FInTxn;
    { Son acilista kurtarma istatistigi. }
    property RecoveryStats: TVdbWalStats read FWalStats;
    { Acilista `.odb.idx` hizli yolu kullanildi mi? Kullanilmadiysa tam
      tarama yapildi ve FIdxErr nedenini verir (veri kaybi soz konusu degil). }
    property IdxUsed: Boolean read FIdxUsed;
    property IdxErr: string read FIdxErr;
    { Dizinin kalici kopyasini simdi yazar (normalde Close yapar). }
    procedure SaveIdx;

    { Sprint 3.1: VERIFY — dosyanin kendisini bastan sona denetler.
      Dizin (bellek) yeniden kurulmaz; yalniz okunur. Denetimler:
        * her sayfa: yapisal gecerlilik + CRC32 (PageVerify)
        * freelist: trunk zinciri, kendi numarasi, sayac, tekrar eden
          girdi, aralik, serbest sayfa sayisi = meta FreeCount
        * heap: hucre basligi, tasma zinciri (her halka okunur), yinelenen
          anahtar, anahtar sayisi = Count
      Report: tek satir ozet (sayfa/serbest/heap/tasma/anahtar) veya hata. }
    function Verify(out Report: string): Boolean;
  end;

implementation

constructor TVdbPageEngine.Create(const ADbPath: string; APoolPages: Integer);
begin
  inherited Create;
  FPath := ADbPath;
  FStore := TVDbPageStore.Create(ADbPath, APoolPages);
  { WAL yolu: <db>.wal. Boylece tek dosya adi sozlesmesi korunur. }
  FWal := TVdbPageWal.Create(ADbPath + '.wal');
  FInTxn := False;
  FWalStats.Frames := 0;
  FWalStats.Commits := 0;
  FWalStats.TornTail := False;
  FWalStats.Bytes := 0;
end;

destructor TVdbPageEngine.Destroy;
begin
  try
    Close;
  except
    { yikici hata firlatmaz }
  end;
  FreeAndNil(FHeap);
  FreeAndNil(FWal);
  FreeAndNil(FStore);
  inherited Destroy;
end;

procedure TVdbPageEngine.Open(ACreate: Boolean);
var
  st: TVdbWalStats;
begin
  FStore.Open(ACreate);
  FWal.Open;
  FStore.OnSpill := OnSpill;
  FStore.OnMiss := OnMiss;

  if FWal.HasContent then
  begin
    FWal.Recover(ApplyRecovered, st);
    FWalStats := st;
    if st.Frames > 0 then
      FStore.Flush(True);
  end;

  FHeap := TVdbHeap.Create(FStore);
  FIdxUsed := False;
  FIdxErr := '';
  { Acilis hizlandirmasi: `.odb.idx` taze ve saglamsa tarama atlanir.
    Herhangi bir uyumsuzlukta tam tarama yapilir; veri kaybi olmaz. }
  if not FHeap.TryLoadIdx(FPath + '.idx', FIdxErr) then
    FHeap.Open
  else
    FIdxUsed := True;

  { Kurtarma sonrasi temiz bir taban: her sey diskte ve fsync'li. }
  if FWal.HasContent then
  begin
    FStore.Flush(True);
    FWal.Truncate(FStore.LSN);
  end;
  FInTxn := False;
  ClearPending;
end;

procedure TVdbPageEngine.SaveIdx;
begin
  if FHeap = nil then Exit;
  try
    FHeap.SaveIdx(FPath + '.idx');
  except
    { idx istege bagli: yazilamazsa acilis yalniz yavaslar. }
  end;
end;

procedure TVdbPageEngine.Close;
begin
  if FHeap = nil then Exit;
  if FInTxn then
    Commit(True);
  { Kapanista tam checkpoint: veri dosyasi guncel, WAL bos. }
  Checkpoint(True);
  { Checkpoint sonrasi dizin taze: acilis taramasi atlanabilir. }
  SaveIdx;
  FStore.OnSpill := nil;
  FStore.OnMiss := nil;
  ClearPending;
  FreeAndNil(FHeap);
  FStore.Close;
  if FWal <> nil then
    FWal.Close;
end;

procedure TVdbPageEngine.SimulateCrash;
begin
  FInTxn := False;
  if FStore <> nil then
  begin
    FStore.OnSpill := nil;
    FStore.OnMiss := nil;
  end;
  ClearPending;
  FreeAndNil(FHeap);
  if FStore <> nil then
    FStore.CloseNoFlush;
  if FWal <> nil then
    FWal.Close;
end;

{ ------------------------------------------------------------ WAL kancalari }

function TVdbPageEngine.PendingIndex(PageNo: LongWord): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FPending) do
    if FPending[i].PageNo = PageNo then Exit(i);
  Result := -1;
end;

procedure TVdbPageEngine.AddPending(PageNo: LongWord; P: PVdbPage);
var
  i: Integer;
begin
  i := PendingIndex(PageNo);
  if i >= 0 then
  begin
    Move(P^, FPending[i].Data, VDB_PAGE_SIZE);
    PageSeal(@FPending[i].Data);
    Exit;
  end;
  SetLength(FPending, Length(FPending) + 1);
  i := High(FPending);
  FPending[i].PageNo := PageNo;
  Move(P^, FPending[i].Data, VDB_PAGE_SIZE);
  { Cerceveden tahliye aninda CRC BAYAT olabilir (sayfa henuz
    muhurlenmemis). Pending imaji sonradan OnMiss ile okunup
    dogrulanacagi icin burada muhurle. }
  PageSeal(@FPending[i].Data);
end;

procedure TVdbPageEngine.ClearPending;
begin
  SetLength(FPending, 0);
end;

procedure TVdbPageEngine.OnSpill(PageNo: LongWord; P: PVdbPage);
begin
  { Kirli sayfa diske YAZILMAZ; WAL tamponuna alinir. Depo bu sayfayi
    onbellekten cikarir, sonraki okuma OnMiss ile buradan gelir. }
  AddPending(PageNo, P);
end;

function TVdbPageEngine.OnMiss(PageNo: LongWord; P: PVdbPage): Boolean;
var
  i: Integer;
begin
  i := PendingIndex(PageNo);
  if i < 0 then Exit(False);
  Move(FPending[i].Data, P^, VDB_PAGE_SIZE);
  { DIKKAT: imaj artik cercevede; pending'deki kopya BAYAT. Kalirsa
    Checkpoint onu daha yeni cerceve imajinin uzerine yazar (veri kaybi).
    Bu yuzden kaydi buradan dusur: pending ile cerceve asla ayni sayfayi
    ayni anda tutmaz. }
  FPending[i] := FPending[High(FPending)];
  SetLength(FPending, Length(FPending) - 1);
  Result := True;
end;

procedure TVdbPageEngine.ApplyRecovered(PageNo: LongWord; P: PVdbPage);
begin
  FStore.InstallPage(PageNo, P);
end;

{ ------------------------------------------------------------------- islem }

function TVdbPageEngine.Insert(Key: QWord; const Value: TBytes): Boolean;
begin
  Result := FHeap.Insert(Key, Value);
  if Result then FInTxn := True;
end;

function TVdbPageEngine.Update(Key: QWord; const Value: TBytes): Boolean;
begin
  Result := FHeap.Update(Key, Value);
  if Result then FInTxn := True;
end;

function TVdbPageEngine.Delete(Key: QWord): Boolean;
begin
  Result := FHeap.Delete(Key);
  if Result then FInTxn := True;
end;

function TVdbPageEngine.TryGet(Key: QWord; out Value: TBytes): Boolean;
begin
  Result := FHeap.TryGet(Key, Value);
end;

function TVdbPageEngine.Contains(Key: QWord): Boolean;
begin
  Result := FHeap.Contains(Key);
end;

procedure TVdbPageEngine.ScanAll(Cb: TVdbHeap.TScanProc);
begin
  FHeap.ScanAll(Cb);
end;

function TVdbPageEngine.GetCount: Integer;
begin
  if FHeap = nil then Result := 0 else Result := FHeap.Count;
end;

function TVdbPageEngine.Stats: TVdbHeapStats;
begin
  Result := FHeap.Stats;
end;

function TVdbPageEngine.Commit(DoSync: Boolean): Boolean;
var
  LSN: LongWord;
  i: Integer;
  dirty: TVdbPageNoArray;
  P: PVdbPage;
  meta: TVdbPageBuf;
begin
  Result := False;
  if FStore = nil then
    raise EVdbPageEngine.Create('motor acik degil');

  if not FInTxn then
    Exit(True);

  LSN := FStore.NextLSN;

  { 1) Tahliye edilip WAL tamponunda bekleyen cerceveler. }
  for i := 0 to High(FPending) do
    FWal.AppendFrame(FPending[i].PageNo, @FPending[i].Data);

  { 2) Hala onbellekte kirli olan sayfalar (en guncel imaj). }
  dirty := FStore.DirtyPages;
  for i := 0 to High(dirty) do
    if FStore.GetPage(dirty[i], P) then
    begin
      FWal.AppendFrame(dirty[i], P);
      FStore.Release(dirty[i], False);
    end;

  { 3) Meta sayfa imaji (sayfa sayisi, freelist, LSN). }
  FStore.BuildMetaImage(meta);
  FWal.AppendFrame(VDB_HDR_PAGE, @meta);

  { 4) WAL commit + fsync: artik durabil. Veritabani dosyasina bu noktada
        HICBIR SEY yazilmaz (checkpoint'e kadar). }
  FWal.Commit(DoSync, LSN);

  FInTxn := False;
  Result := True;
end;

function TVdbPageEngine.Checkpoint(DoSync: Boolean): Boolean;
var
  i: Integer;
begin
  Result := False;
  if FStore = nil then
    raise EVdbPageEngine.Create('motor acik degil');
  { Tahliye edilmis sayfalar once dosyaya, sonra onbellekteki kirli
    sayfalar yazilir. InstallPage tahliye tetiklemez.
    Onemli: bir sayfa onbellekte varsa cerceve imaji pending kopyasindan
    HER ZAMAN daha yeni/esittir (yuklemede kirli isaretlenir). O yuzden
    pending yalnizca YERLESIK OLMAYAN sayfalar icin kurulur; aksi halde
    eski imaj yeni cercevenin uzerine yazilirdi. }
  for i := 0 to High(FPending) do
    if not FStore.IsResident(FPending[i].PageNo) then
      FStore.InstallPage(FPending[i].PageNo, @FPending[i].Data);
  ClearPending;
  FStore.Flush(DoSync);
  if DoSync then
    FWal.Truncate(FStore.LSN);
  Result := True;
end;

function TVdbPageEngine.Verify(out Report: string): Boolean;
var
  pno, i, n: LongWord;
  P: PVdbPage;
  e: string;
  magic: Word;
  freePages: TVdbPageNoArray;
  freeSet: TDictionary<LongWord, Boolean>;
  keySet: TDictionary<QWord, Boolean>;
  chainSet: TDictionary<LongWord, Boolean>;
  d: PByte;
  POvf: PVdbPage;
  dl, take: Integer;
  key: QWord;
  len: LongWord;
  ovf: Boolean;
  heapPages, ovfPages, ovfWalk, keys: Integer;
  chain, ovfNo, nextNo: LongWord;
  fi: Integer;
  got: Int64;
begin
  Report := '';
  if FStore = nil then
    raise EVdbPageEngine.Create('motor acik degil');
  if FInTxn then
  begin
    Report := 'acik islem varken VERIFY yapilamaz';
    Exit(False);
  end;
  { Onaylanmis ama henuz dosyaya gecmemis cerceveler varsa once yaz.
    Boylece dogrulanan sey DISKTEKI gercek durumdur. }
  if FWal.HasContent or (Length(FPending) > 0) then
    if not Checkpoint(True) then
    begin
      Report := 'checkpoint basarisiz';
      Exit(False);
    end;

  heapPages := 0;
  ovfPages := 0;
  keys := 0;
  freeSet := TDictionary<LongWord, Boolean>.Create;
  keySet := TDictionary<QWord, Boolean>.Create;
  chainSet := TDictionary<LongWord, Boolean>.Create;
  try
    { --- 1) freelist zinciri --- }
    if not FStore.VerifyFreeList(freePages, e) then
    begin
      Report := 'freelist: ' + e;
      Exit(False);
    end;
    for fi := 0 to High(freePages) do
      freeSet.Add(freePages[fi], True);

    { --- 2) tum sayfalar: yapi + CRC --- }
    pno := 1;
    while pno < FStore.PageCount do
    begin
      if freeSet.ContainsKey(pno) then
      begin
        Inc(pno);
        Continue;
      end;
      if not FStore.GetRawPage(pno, P) then
      begin
        Report := Format('sayfa %d okunamadi', [pno]);
        Exit(False);
      end;
      try
        Move(P^[0], magic, SizeOf(magic));
        if magic <> VDB_PAGE_MAGIC then
        begin
          Report := Format('sayfa %d taninmiyor (ne VDbPage ne trunk)', [pno]);
          Exit(False);
        end;
        if not PageVerify(P, e) then
        begin
          Report := Format('sayfa %d bozuk: %s', [pno, e]);
          Exit(False);
        end;
        if PageNoOf(P) <> pno then
        begin
          Report := Format('sayfa %d basligindaki numara %d', [pno, PageNoOf(P)]);
          Exit(False);
        end;
        case PageTypeOf(P) of
          VDB_PAGE_HEAP:
            begin
              Inc(heapPages);
              n := PageSlotCount(P);
              for i := 0 to n - 1 do
              begin
                if not PageGetCell(P, i, d, dl) then Continue;
                if dl < VDB_CELL_HDR then
                begin
                  Report := Format('sayfa %d slot %d: hucre cok kisa (%d)',
                    [pno, i, dl]);
                  Exit(False);
                end;
                Move(d^, key, 8);
                Move((d + 8)^, len, 4);
                ovf := (len and VDB_OVF_FLAG) <> 0;
                if ovf and (dl < VDB_CELL_HDR + 4) then
                begin
                  Report := Format('sayfa %d slot %d: tasma isaretli ama zincir yok',
                    [pno, i]);
                  Exit(False);
                end;
                if keySet.ContainsKey(key) then
                begin
                  Report := Format('yinelenen anahtar $%.16x (sayfa %d)', [key, pno]);
                  Exit(False);
                end;
                keySet.Add(key, True);
                Inc(keys);
                if ovf then
                begin
                  { Tasma zincirini sonuna kadar yuru: her halka gecerli
                    olmali ve toplam bayt ilan edilen uzunlugu tutmali. }
                  Move((d + VDB_CELL_HDR)^, chain, 4);
                  got := 0;
                  ovfWalk := 0;
                  ovfNo := chain;
                  while ovfNo <> 0 do
                  begin
                    Inc(ovfWalk);
                    if (ovfNo >= FStore.PageCount) then
                    begin
                      Report := Format(
                        'sayfa %d slot %d: tasma halkasi aralik disi: %d',
                        [pno, i, ovfNo]);
                      Exit(False);
                    end;
                    if ovfWalk > (Integer(len and VDB_LEN_MASK) div VDB_OVF_CHUNK) + 3 then
                    begin
                      Report := Format(
                        'sayfa %d slot %d: tasma zinciri dongulu (%d)',
                        [pno, i, ovfNo]);
                      Exit(False);
                    end;
                    if not FStore.GetRawPage(ovfNo, POvf) then
                    begin
                      Report := Format('tasma sayfasi %d okunamadi', [ovfNo]);
                      Exit(False);
                    end;
                    if chainSet.ContainsKey(ovfNo) then
                    begin
                      Report := Format(
                        'tasma sayfasi %d birden fazla zincirde', [ovfNo]);
                      Exit(False);
                    end;
                    chainSet.Add(ovfNo, True);
                    try
                      if PageTypeOf(POvf) <> VDB_PAGE_OVERFLOW then
                      begin
                        Report := Format('sayfa %d tasma sayfasi degil (tip %d)',
                          [ovfNo, PageTypeOf(POvf)]);
                        Exit(False);
                      end;
                      if not PageGetCell(POvf, 0, d, dl) or (dl < 4) then
                      begin
                        Report := Format('tasma sayfasi %d hucre 0 gecersiz', [ovfNo]);
                        Exit(False);
                      end;
                      Move(d^, nextNo, 4);
                      take := dl - 4;
                      if got + take > Int64(len and VDB_LEN_MASK) then
                        take := Integer(Int64(len and VDB_LEN_MASK) - got);
                      if take > 0 then Inc(got, take);
                    finally
                      FStore.Release(ovfNo, False);
                    end;
                    ovfNo := nextNo;
                  end;
                  if got <> Int64(len and VDB_LEN_MASK) then
                  begin
                    Report := Format('sayfa %d slot %d: tasma eksik %d/%d bayt',
                      [pno, i, got, len and VDB_LEN_MASK]);
                    Exit(False);
                  end;
                end;
              end;
            end;
          VDB_PAGE_OVERFLOW:
            Inc(ovfPages);
        else
          begin
            Report := Format('sayfa %d: bilinmeyen sayfa tipi %d',
              [pno, PageTypeOf(P)]);
            Exit(False);
          end;
        end;
      finally
        FStore.Release(pno, False);
      end;
      Inc(pno);
    end;

    if keys <> FHeap.Count then
    begin
      Report := Format('anahtar sayisi tutmuyor: dosyada %d, dizinde %d',
        [keys, FHeap.Count]);
      Exit(False);
    end;

    { Tasma sayfalarinin TAMAMI bir hucre zincirine ait olmali. Sayfa
      taramasi ile zincir yuruyusu karsilastirilir; artik kalan tasma
      sayfasi sessiz cop olurdu. }
    if ovfPages <> chainSet.Count then
    begin
      Report := Format(
        'sahipsiz tasma sayfasi: dosyada %d, zincirlerde %d',
        [ovfPages, chainSet.Count]);
      Exit(False);
    end;

    Report := Format('sayfa=%d serbest=%d heap=%d tasma=%d anahtar=%d lsn=%d',
      [FStore.PageCount, Length(freePages), heapPages, ovfPages, keys, FStore.LSN]);
    Result := True;
  finally
    chainSet.Free;
    keySet.Free;
    freeSet.Free;
  end;
end;

end.
