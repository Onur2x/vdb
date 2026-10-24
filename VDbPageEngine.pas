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
  SysUtils, VDbPage, VDbPageStore, VDbPageHeap, VDbPageWal;

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

end.
