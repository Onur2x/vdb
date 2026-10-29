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
  SysUtils, SyncObjs, Generics.Collections, VDbPage, VDbPageStore,
  VDbPageHeap, VDbPageWal, VDbIdxFile;

type
  EVdbPageEngine = class(Exception);

  { v3.1: `.idx` etiket ozeti saglayicisi (backend tablo sayimlarini verir). }
  TVdbTagSummaryEvent = procedure(out Tags: TVdbIdxTagArray) of object;

  TVdbPageEngine = class
  private
    type
      TPending = record
        PageNo: LongWord;
        Data: PByte;              // 4 KB imaj: ayri ayri ayrilir
        { v3.1: imajin ait oldugu islem (depo FTxnId'si). Commit yalnizca
          guncel islem isaretli pending imajlarini yazar. }
        Mark: LongWord;
      end;
    var
      FStore: TVDbPageStore;
      FHeap: TVdbHeap;
      FWal: TVdbPageWal;
      { Sprint 3.12: ONCEDEN `array of TPending` idi ve her tahliyede
        `SetLength(+1)` yapiliyordu. 200k x 64 B yazimda (havuz 512) pending
        3488 sayfaya cikti ve olculen maliyet 75 us/tahliye (toplam ~265 ms)
        idi — kopyalama degil, 4 KB'lik kayitli diziyi bire bir buyutmenin
        bedeli. Artik imajlar ayri ayrilir, dizi yalniz isaretci tutar ve
        kapasite ikiye katlanir. }
      FPending: array of TPending;
      FPendingCount: Integer;
      FPendingCap: Integer;
      { Sprint 3.12: pending sayfa aramasi LINEER taramaydi. Toplu yazimda
        havuz dolar ve pending binlerce sayfaya cikinca her tahliye
        O(n) tarama yapiyordu (olculen: 200k x 64B yazim, havuz 512 ->
        3,24 us/anahtar; havuz 8192 -> 1,24 us/anahtar). Artik hash ile
        O(1). Dizi semantigi (swap-remove) korunur. }
      FPendingIdx: TDictionary<LongWord, Integer>;
      FInTxn: Boolean;
      { v3.3: ICERIK damgasi (zone map onbellegi). Yalnizca veri degistiren
        commit'lerde artar; salt-okunur islem commit'i artirmaz. }
      FDataStamp: QWord;
      FWalStats: TVdbWalStats;
      FPath: string;
      FIdxUsed: Boolean;
      FIdxErr: string;
      { Sprint 3.4: acilis anahtari (Open'dan once). }
      FKey: TBytes;
      FPassword: string;
      FHasPassword: Boolean;
      { v3.1: `.idx`'e yazilacak etiket ozeti saglayicisi (backend atar). }
      FOnTagSummary: TVdbTagSummaryEvent;
      { v3.2: acilista WAL'den yalnizca ilk N commit uygulanir (0 = hepsi).
        AS OF anlik goruntusu kopya uzerinde acilirken kullanilir. }
      FRecoverLimit: Integer;
      { v3.19 GRUP COMMIT: fsync TEK lider tarafindan yapilir, bekleyenler
        ayni fsync'i paylasir. Boylece N thread'in N fsync'i yerine bir
        fsync olur (olculen: fsync tek basina commit'in ~%60'i).
        FDurableLsn: fsync'in KAPSADIGI en buyuk LSN (WAL'e yazilmis).
        FSyncBusy: su an bir lider fsync yapiyor.
        FSyncEvt: lider bitince bekleyenleri uyandirir (manual-reset).
        FSyncCount: yapilan gercek fsync sayisi (olcum/kapi icin).
        FSyncErr: lider fsync hatasi; bekleyenlere aynen iletilir. }
      FSyncCs: TCriticalSection;
      FSyncEvt: TEvent;
      FSyncBusy: Boolean;
      FDurableLsn: LongWord;
      FSyncCount: Int64;
      FSyncErr: string;
    procedure InitEngine(const ADbPath: string; APoolPages: Integer);
    { v3.19: Commit'in gercek govdesi. ASyncLsn = WAL'e yazilan en son LSN
      (yazilacak kayit yoksa 0). DoSync=False ise fsync yapilmaz. }
    function DoCommit(DoSync: Boolean; out ASyncLsn: LongWord): Boolean;
    function GetEncrypted: Boolean;
    function GetReadOnly: Boolean;
    procedure OnSpill(PageNo: LongWord; P: PVdbPage);
    function OnMiss(PageNo: LongWord; P: PVdbPage): Boolean;
    procedure ApplyRecovered(PageNo: LongWord; P: PVdbPage);
    procedure ApplyReadOnly(PageNo: LongWord; P: PVdbPage);
    { v3.16: sayfa deposu "baska surec commit etti" dediginde WAL
      gorunumunu tazele. }
    procedure StoreRefreshed(Sender: TObject);
    procedure RequireWritable;
    function PendingIndex(PageNo: LongWord): Integer;
    procedure AddPending(PageNo: LongWord; P: PVdbPage);
    procedure ClearPending;
    { v3.29: tazelemede tam Checkpoint yerine yalnizca tahliye edilmis
      imajlari onbellege kurar (diske yazma/fsync/WAL budama YOK). }
    procedure InstallPending;
    function GetIdxTagsValid: Boolean;
    { v3.3: veri degistiren commit'te damgayi ilerletir. }
    function NextDataStamp: QWord;
  public
    constructor Create(const ADbPath: string; APoolPages: Integer = VDB_DEF_POOL);
    { Sprint 3.4: sifreli dosya. Anahtar 32 bayt AES-256'dir; parola
      verilirse PBKDF2-SHA256 ile dosyaya ozgu tuzdan turetilir. Anahtar
      Open'dan ONCE verilir; sifresiz dosyaya anahtar vermek net hatadir. }
    constructor CreateWithKey(const ADbPath: string; const AKey: TBytes;
      APoolPages: Integer = VDB_DEF_POOL);
    constructor CreateWithPassword(const ADbPath, APassword: string;
      APoolPages: Integer = VDB_DEF_POOL);
    destructor Destroy; override;

    { Var olan dosyayi acar; ACreate=True ise yoksa olusturur.
      v3.2: AReadOnly=True ile SALT-OKUNUR acilir (paylasimli kilit, cok
      okuyucu). WAL imajlari diske yazilmadan bellek katmanindan okunur. }
    procedure Open(ACreate: Boolean = False; AReadOnly: Boolean = False;
      ABusyMs: Integer = VDB_DEF_BUSY_MS);
    property ReadOnly: Boolean read GetReadOnly;
    procedure Close;

    { v3.2: Open'dan ONCE ayarlanir. N > 0 ise acilista WAL'den yalnizca
      ilk N commit uygulanir (AS OF anlik goruntusu). Varsayilan 0 = hepsi. }
    property RecoverLimit: Integer read FRecoverLimit write FRecoverLimit;

    { Test: surec olumu simulasyonu. Commit edilmemis degisiklikler ve
      WAL tamponu diske yazilmadan atilir. }
    procedure SimulateCrash;

    function Insert(Key: QWord; const Value: TBytes): Boolean;
    function Update(Key: QWord; const Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    function TryGet(Key: QWord; out Value: TBytes): Boolean;
    function Contains(Key: QWord): Boolean;
    procedure ScanAll(Cb: TVdbHeap.TScanProc);
    { v3.1: sifir-kopya tarama (satir basina tahsis yok). }
    procedure ScanAllRaw(Cb: TVdbHeap.TScanRawProc);
    { v3.2: sayfa numarali + sayfa atlayabilen tarama. }
    procedure ScanAllRawPaged(Cb: TVdbHeap.TScanRawPageProc;
      Skip: PByte; SkipCount: Integer);
    function Stats: TVdbHeapStats;

    { Bekleyen degisiklikleri WAL'e yazip fsync eder. Veritabani dosyasina
      YAZMAZ; bunun icin Checkpoint cagrilir. DoSync=False ise fsync
      atlanir (yalniz toplu yazim/test icin). }
    function Commit(DoSync: Boolean = True): Boolean;

    { v3.19 GRUP COMMIT: commit'i WAL'e yazar, fsync ETMEZ; fsync'i
      AwaitDurable yapar. ASyncLsn, durabil olmasi beklenen LSN'dir
      (0 = bekleyecek bir sey yok). Kritik bolumu kisaltmak icin. }
    function CommitNoSync(out ASyncLsn: LongWord): Boolean;

    { v3.19: ASyncLsn'e kadar olan WAL kayitlarinin diskte oldugundan emin
      olur. Cagiran zaten bekleyen varsa onun fsync'ini paylasir; yoksa
      lider olup kendisi fsync eder. Hata varsa yukseltir. }
    procedure AwaitDurable(ALsn: LongWord);

    { Onaylanmis sayfalari veritabani dosyasina yazar, fsync eder ve WAL'i
      budar. Cokme sonrasi acilista otomatik yapilir. }
    function Checkpoint(DoSync: Boolean = True): Boolean;

    function GetCount: Integer;
    property Count: Integer read GetCount;

    property Store: TVDbPageStore read FStore;
    property Heap: TVdbHeap read FHeap;
    property Wal: TVdbPageWal read FWal;
    property InTxn: Boolean read FInTxn;
    { v3.19 GRUP COMMIT: yapilan GERCEK fsync sayisi. Kapi, fsync sayisinin
      commit sayisindan cok kucuk oldugunu bununla kanitlar. }
    property DebugSyncCount: Int64 read FSyncCount;
    { v3.3: ICERIK damgasi — sayfa duzeyi zone map onbellegi buna baglidir.
      Ayni damga = ayni satir icerigi. }
    property DataStamp: QWord read FDataStamp;
    { Son acilista kurtarma istatistigi. }
    property RecoveryStats: TVdbWalStats read FWalStats;
    { Acilista `.odb.idx` hizli yolu kullanildi mi? Kullanilmadiysa tam
      tarama yapildi ve FIdxErr nedenini verir (veri kaybi soz konusu degil). }
    property IdxUsed: Boolean read FIdxUsed;
    property IdxErr: string read FIdxErr;
    { v3.1: `.idx`'teki etiket ozeti (boş = guvenilmez; tam tarama gerekir). }
    property IdxTagsValid: Boolean read GetIdxTagsValid;
    function IdxTags: TVdbIdxTagArray;
    { v3.1: SaveIdx sirasinda etiket ozeti (tablo satir sayimi) ister. }
    property OnTagSummary: TVdbTagSummaryEvent
      read FOnTagSummary write FOnTagSummary;
    { Sprint 3.4: dosya sifreli mi ve anahtar parmak izi (8 hex). }
    property Encrypted: Boolean read GetEncrypted;
    function KeyFingerprint: string;
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

{$IFDEF CPUPROF}
uses
  VDbCpuProf;
{$ENDIF}

var
  { v3.3: her motor ornegine essiz bir damga tabani vermek icin. }
  GEngineSerial: LongInt = 0;

function TVdbPageEngine.GetEncrypted: Boolean;
begin
  Result := (FStore <> nil) and FStore.Encrypted;
end;

function TVdbPageEngine.GetReadOnly: Boolean;
begin
  Result := (FStore <> nil) and FStore.ReadOnly;
end;

function TVdbPageEngine.KeyFingerprint: string;
begin
  if FStore <> nil then Result := FStore.KeyFingerprint
  else Result := '';
end;

procedure TVdbPageEngine.InitEngine(const ADbPath: string; APoolPages: Integer);
begin
  FPath := ADbPath;
  FStore := TVDbPageStore.Create(ADbPath, APoolPages);
  if FHasPassword then
    FStore.SetEncryptionPassword(FPassword)
  else if Length(FKey) > 0 then
    FStore.SetEncryptionKey(FKey);
  { WAL yolu: <db>.wal. Boylece tek dosya adi sozlesmesi korunur. }
  FWal := TVdbPageWal.Create(ADbPath + '.wal');
  FInTxn := False;
  FRecoverLimit := 0;
  FPendingIdx := TDictionary<LongWord, Integer>.Create;
  FPendingCount := 0;
  FPendingCap := 0;
  SetLength(FPending, 0);
  FWalStats.Frames := 0;
  FWalStats.Commits := 0;
  FWalStats.TornTail := False;
  FWalStats.Bytes := 0;
  { v3.3: ICERIK damgasi. Her motor ornegi farkli bir ust 32 bit tabani alir,
    boylece yeni bir motor (or. VACUUM/RESTORE sonrasi) eski bir zone map
    damgasiyla CAKISAMAZ. Alt 32 bit yalnizca VERI DEGISTIREN commit'lerde
    artar; salt-okunur islem commit'i (meta cercevesi yazsa bile) artirmaz. }
  FDataStamp := QWord(InterLockedIncrement(GEngineSerial)) shl 32 or 1;
  { v3.19 GRUP COMMIT durumu. FSyncEvt manual-reset. }
  FSyncCs := TCriticalSection.Create;
  FSyncEvt := TEvent.Create(nil, True, False, '');
  FSyncBusy := False;
  FDurableLsn := 0;
  FSyncCount := 0;
  FSyncErr := '';
end;

function TVdbPageEngine.NextDataStamp: QWord;
begin
  Inc(FDataStamp);
  { Alt 32 bit tasarsa ust taban yenilenir (pratikte ulasilmaz). }
  if (FDataStamp and $FFFFFFFF) = 0 then
    FDataStamp := QWord(InterLockedIncrement(GEngineSerial)) shl 32 or 1;
  Result := FDataStamp;
end;

constructor TVdbPageEngine.Create(const ADbPath: string; APoolPages: Integer);
begin
  inherited Create;
  FKey := nil;
  FHasPassword := False;
  FPassword := '';
  InitEngine(ADbPath, APoolPages);
end;

constructor TVdbPageEngine.CreateWithKey(const ADbPath: string;
  const AKey: TBytes; APoolPages: Integer);
begin
  inherited Create;
  FKey := Copy(AKey, 0, Length(AKey));
  FHasPassword := False;
  FPassword := '';
  InitEngine(ADbPath, APoolPages);
end;

constructor TVdbPageEngine.CreateWithPassword(const ADbPath, APassword: string;
  APoolPages: Integer);
begin
  inherited Create;
  FKey := nil;
  FHasPassword := True;
  FPassword := APassword;
  InitEngine(ADbPath, APoolPages);
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
  begin
    ClearPending;          // ayri ayrilmis 4 KB imajlari birak
  end;
  FreeAndNil(FPendingIdx);
  FreeAndNil(FSyncEvt);
  FreeAndNil(FSyncCs);
  inherited Destroy;
end;

procedure TVdbPageEngine.StoreRefreshed(Sender: TObject);
var
  st: TVdbWalStats;
begin
  if (FWal = nil) or (FStore = nil) then Exit;
  if FStore.ReadOnly then
  begin
    { v3.18: SALT-OKUNUR TAZELEME. Once RO oturum paylasimli kilidi oturum
      boyu tuttugu icin baska bir surec commit EDEMEZD I; bu yol hic
      calismiyordu. Artik RO da kilit alip birakiyor, dolayisiyla buraya
      gelinebilir. Yapilan: bellek WAL imajlarini bosalt, WAL'i salt-okunur
      yeniden ac ve cerceveleri BELLEK katmanina uygula (diske YAZILMAZ),
      sonra heap dizinini yeniden kur.
      ONEMLI: burada FStore.Flush/Truncate CAGRILMAZ - RO oturum diske
      yazmaz (lockchk "RO oturum diskte hicbir bayt degistirmedi" kapisi). }
    FStore.ResetReadOnlyImages;
    { v3.28: handle'lar KORUNUR (bkz TVdbPageWal.Refresh). Olculen: yeni
      yazilmis bir dosyanin ilk yeniden acilisi 4-10 ms; tazeleme
      maliyetinin %82'si yalnizca bu acilisti. Anahtar acikken tanimli. }
    if FStore.Encrypted then
      FWal.SetEncryptionKey(FStore.Key, FStore.Salt);
    FWal.Refresh(True);
    if FWal.HasContent then
    begin
      { v3.29: artimsal — yalniz onbellekteki taban LSN'den YENI cerceveler
        uygulanir. Eski cerceveler zaten veritabani dosyasinda. }
      FWal.Recover(ApplyReadOnly, st, FRecoverLimit, FStore.LSN, True);
      FWalStats := st;
    end;
    if FHeap <> nil then
      FHeap.Open;
    Exit;
  end;
  { Baska bir surec commit etti: bizim WAL handle'i ve tanimligi bayat.
    Yeniden ac; varsa cerceveleri uygula (WAL cerceveleri sayfa imajidir,
    yeniden uygulamak idempotenttir) ve buda. }
  { v3.28: WAL'i kapatip yeniden ACMAK yerine handle'lar korunur (bkz
    TVdbPageWal.Refresh). WAL dosyasi hicbir yerde silinmiyor; Truncate
    yalniz SetEndOfFile kullaniyor, dolayisiyla handle gecerli kalir. }
  if FStore.Encrypted then
    FWal.SetEncryptionKey(FStore.Key, FStore.Salt);
  FWal.Refresh(False);
  if FWal.HasContent then
  begin
    { v3.29: ARTIMSAL uygulama — taban, onbellegin yuklendigi meta LSN'idir
      (RefreshIfStaleForce once DropCache + LoadMeta yapar). Ondan eski
      cerceveler zaten dosyada; yalniz deltalari uygula. }
    FWal.Recover(ApplyRecovered, st, FRecoverLimit, FStore.LSN, True);
    FWalStats := st;
    { v3.29 — TAZELEMEDE CHECKPOINT KALDIRILDI (olculen: 6,65 -> 1,05 ms'lik
      tazelemenin 0,80 ms'si tam checkpoint'ti; karisik okuma/yazmada her
      okuma ifadesi bunu oduyordu: 1039 us/sorgu vs SQLite WAL 24 us).
      NEDEN GUVENLI:
        * Uygulanan cerceveler WAL'de ve WAL commit'te fsync edilmis durumda;
          yani bu sayfalar icin tek durabil kaynak WAL'dir, dosya degil.
        * InstallPage zaten sayfalari dosyaya yazar (yalniz fsync etmez).
        * WAL sinirsiz buyumez: her commit MaybeCheckpoint'i cagirir ve
          8 MB'ta Checkpoint(True) WAL'i budar. Bu budama once
          FStore.Flush(True) ile TUM dosyayi fsync eder, sonra keser;
          dolayisiyla "sayfalar durabil olmadan WAL kesildi" durumu olusmaz
          (fsync dosya duzeyinde calisir, hangi surec yazmis olursa olsun).
        * Onceki yolun korunma nedeni (v3.18: Flush YALNIZ resident kirli
          sayfalari yazar, pending imajlar diske gitmez) burada da gecerli;
          bu yuzden pending imajlar YALNIZ onbellege kurulur
          (InstallPending) — hicbir zaman "once pending'i at, sonra kes"
          sirasi kurulmaz. }
    InstallPending;
  end;
  { v3.17 DUZELTME — VERI KAYBI: yalnizca sayfa onbellegini tazelemek
    YETMEZ. Heap'in bellek ici dizini (Anahtar -> sayfa/slot) hala ESKI;
    bayat dizinle yazmak, baska surecin kullandigi sayfalari yeniden tahsis
    edip SATIRLARINI EZER. prochk bunu CI'da yakaladi (A'nin 40 satiri
    tamamen kayboldu, B'nin commit'i uzerine yazdi). Dizini yeniden kur. }
  if FHeap <> nil then
  begin
    if FInTxn or (FPendingCount > 0) then
      raise EVdbPageEngine.Create(
        'baska bir surec commit etti; acik islem varken onbellek ' +
        'tazelenemez (islem kilidi tutulmamis)');
    FHeap.Open;
  end;
end;

procedure TVdbPageEngine.Open(ACreate: Boolean; AReadOnly: Boolean;
  ABusyMs: Integer);
var
  st: TVdbWalStats;
begin
  FStore.OpenEx(ACreate, AReadOnly, ABusyMs);
  if FStore.Encrypted then
    FWal.SetEncryptionKey(FStore.Key, FStore.Salt);
  FWal.Open(AReadOnly);
  FStore.OnSpill := OnSpill;
  FStore.OnMiss := OnMiss;
  { v3.16: cok surec — baska bir surec commit edince WAL gorunumunu tazele. }
  FStore.OnRefreshed := StoreRefreshed;

  { v3.16: SURECLER ARASI COK YAZARLILIK. Acilis islemleri (WAL kurtarma,
    sayfa yazimi, fsync, WAL budama, yukseltme) YAZAR; Windows'ta paylasimli
    kilit altinda yazma yapilamaz. Bu yuzden yazan oturumda acilis TAM kilit
    altinda yapilir, sonunda paylasimliya inilir. }
  if not AReadOnly then
    FStore.AcquireWriteOpen
  else
    { v3.18: SALT-OKUNUR acilis da PAYLASIMLI kilit altinda yapilir. Once RO
      oturum kilidi oturum boyu tuttugu icin bu gerekmiyordu gorunuyordu;
      artik kilit ifade basina oldugu icin acilis (WAL imajlari, `.odb.idx`
      yuklemesi, heap dizini) kilitsiz kalirdi ve tam o anda commit eden bir
      yazarla yarisa girip YARIM/ESKI goruntu okuyabilirdi. Acilis bitince
      birakilir; RO oturum diske yine hicbir sey yazmaz. }
    FStore.AcquireRead;
  try
    if FWal.HasContent then
    begin
      if AReadOnly then
      begin
      { v3.2: salt-okunur kurtarma. Cerceveler DISKE YAZILMAZ; depo
        katmaninda bellek imaji olarak tutulur ve okuma oradan karsilanir. }
      FWal.Recover(ApplyReadOnly, st, FRecoverLimit);
      FWalStats := st;
      FHeap := TVdbHeap.Create(FStore);
      FIdxUsed := False;
      FIdxErr := '';
      if not FHeap.TryLoadIdx(FPath + '.idx', FIdxErr) then
        FHeap.Open
      else
        FIdxUsed := True;
      FInTxn := False;
      ClearPending;
      Exit;
    end;
    FWal.Recover(ApplyRecovered, st, FRecoverLimit);
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
  finally
    if not AReadOnly then
      FStore.ReleaseWrite
    else
      FStore.ReleaseRead;
  end;
  FInTxn := False;
  ClearPending;
end;

procedure TVdbPageEngine.SaveIdx;
var
  tags: TVdbIdxTagArray;
begin
  if FHeap = nil then Exit;
  SetLength(tags, 0);
  if Assigned(FOnTagSummary) then
    FOnTagSummary(tags);
  try
    FHeap.SaveIdx(FPath + '.idx', tags);
  except
    { idx istege bagli: yazilamazsa acilis yalniz yavaslar. }
  end;
end;

function TVdbPageEngine.GetIdxTagsValid: Boolean;
begin
  if FHeap = nil then Result := False
  else Result := FHeap.IdxTagsValid;
end;

function TVdbPageEngine.IdxTags: TVdbIdxTagArray;
begin
  if FHeap = nil then SetLength(Result, 0)
  else Result := FHeap.IdxTags;
end;

procedure TVdbPageEngine.Close;
var
  closeOk: Boolean;
begin
  if FHeap = nil then Exit;
  if FInTxn then
    Commit(True);
  { Kapanista tam checkpoint: veri dosyasi guncel, WAL bos.
    v3.2: salt-okunur oturum checkpoint YAPMAZ (yazma yok).

    v3.18 DUZELTME — VERI KAYBI (olculdu: prochk kosu 20, 40 satir kayboldu).
    ONCEDEN burada kilitsiz ve TAZELEMESIZ checkpoint yapiliyordu. Iki yazar
    surec varsa: A commit edip kapanirken once B commit etmisse, A'nin
    BELLEGI hala bayat (B'nin cerceveleri yalniz WAL'de). A bayat sayfalari
    .odb'ye yazip WAL'i KENDI bayat LSN'inde kesiyordu -> B'nin onaylanmis
    commit'i yok oluyordu. Artik checkpoint TAM kilit altinda ve TAZE
    onbellekle yapilir: AcquireDataWrite once RefreshIfStaleForce calistirir
    (varsa WAL cerceveleri uygulanir, heap dizini yeniden kurulur), sonra
    yazim + budama guvenli olur.
    Kilit ALINAMAZSA checkpoint ATLANIR: veri WAL'de durur, acilista kurtarilir.
    Veri kaybina tercih edilen bilincli secim (bkz. Oncelik 1). }
  if not ReadOnly then
  begin
    closeOk := False;
    try
      FStore.AcquireDataWrite;
      try
        Checkpoint(True);
        closeOk := True;
      finally
        FStore.ReleaseDataWrite;
      end;
    except
      { Kapanis zinciri kirilmaz. Kilit alinamadiysa checkpoint ATLANIR:
        onaylanmis veri WAL'de kalir ve bir sonraki acilista kurtarilir.
        Veri kaybina tercih edilen bilincli secim (Oncelik 1). }
      closeOk := False;
    end;
    { Checkpoint sonrasi dizin taze: acilis taramasi atlanabilir. Yalniz
      checkpoint GERCEKTEN yapildiysa yaz (bayat dizin yazmak, bir sonraki
      acilista eksik satir demektir). }
    if closeOk then
      SaveIdx;
  end;
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
begin
  if FPendingIdx.TryGetValue(PageNo, Result) then
    Exit;
  Result := -1;
end;

procedure TVdbPageEngine.AddPending(PageNo: LongWord; P: PVdbPage);
var
  i: Integer;
begin
  i := PendingIndex(PageNo);
  if i >= 0 then
  begin
    Move(P^, FPending[i].Data^, VDB_PAGE_SIZE);
    PageSeal(PVdbPage(FPending[i].Data));
    FPending[i].Mark := FStore.TxnMarkOf(PageNo);
    Exit;
  end;
  if FPendingCount >= FPendingCap then
  begin
    if FPendingCap = 0 then FPendingCap := 64 else FPendingCap := FPendingCap * 2;
    SetLength(FPending, FPendingCap);
  end;
  i := FPendingCount;
  FPending[i].PageNo := PageNo;
  { Cerceve henuz tahliye edilmedi: islem isaretini oradan al. }
  FPending[i].Mark := FStore.TxnMarkOf(PageNo);
  GetMem(FPending[i].Data, VDB_PAGE_SIZE);
  Move(P^, FPending[i].Data^, VDB_PAGE_SIZE);
  { Cerceveden tahliye aninda CRC BAYAT olabilir (sayfa henuz
    muhurlenmemis). Pending imaji sonradan OnMiss ile okunup
    dogrulanacagi icin burada muhurle. }
  PageSeal(PVdbPage(FPending[i].Data));
  Inc(FPendingCount);
  FPendingIdx.AddOrSetValue(PageNo, i);
end;

procedure TVdbPageEngine.ClearPending;
var
  i: Integer;
begin
  for i := 0 to FPendingCount - 1 do
    if FPending[i].Data <> nil then
    begin
      FreeMem(FPending[i].Data);
      FPending[i].Data := nil;
    end;
  FPendingCount := 0;
  if FPendingIdx <> nil then
    FPendingIdx.Clear;
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
  Move(FPending[i].Data^, P^, VDB_PAGE_SIZE);
  { DIKKAT: imaj artik cercevede; pending'deki kopya BAYAT. Kalirsa
    Checkpoint onu daha yeni cerceve imajinin uzerine yazar (veri kaybi).
    Bu yuzden kaydi buradan dusur: pending ile cerceve asla ayni sayfayi
    ayni anda tutmaz. }
  FreeMem(FPending[i].Data);
  FPending[i].Data := nil;
  FPendingIdx.Remove(PageNo);
  Dec(FPendingCount);
  if i <> FPendingCount then
  begin
    FPending[i] := FPending[FPendingCount];
    { Swap-remove: tasinan kaydin indeksi degisti; hash'i duzelt. }
    FPendingIdx.AddOrSetValue(FPending[i].PageNo, i);
  end;
  Result := True;
end;

procedure TVdbPageEngine.ApplyRecovered(PageNo: LongWord; P: PVdbPage);
begin
  FStore.InstallPage(PageNo, P);
end;

{ v3.2 salt-okunur: WAL cercevesini DISKE YAZMADAN bellek katmanina alir. }
procedure TVdbPageEngine.ApplyReadOnly(PageNo: LongWord; P: PVdbPage);
begin
  FStore.InstallReadOnlyPage(PageNo, P);
end;

{ ------------------------------------------------------------------- islem }

procedure TVdbPageEngine.RequireWritable;
begin
  if FStore = nil then
    raise EVdbPageEngine.Create('motor acik degil');
  if FStore.ReadOnly then
    raise EVdbPageEngine.Create(
      'salt-okunur veritabani: yazma yapilamaz (READONLY acilis)');
end;

function TVdbPageEngine.Insert(Key: QWord; const Value: TBytes): Boolean;
begin
  RequireWritable;
  Result := FHeap.Insert(Key, Value);
  if Result then FInTxn := True;
end;

function TVdbPageEngine.Update(Key: QWord; const Value: TBytes): Boolean;
begin
  RequireWritable;
  Result := FHeap.Update(Key, Value);
  if Result then FInTxn := True;
end;

function TVdbPageEngine.Delete(Key: QWord): Boolean;
begin
  RequireWritable;
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

procedure TVdbPageEngine.ScanAllRaw(Cb: TVdbHeap.TScanRawProc);
begin
  FHeap.ScanAllRaw(Cb);
end;

procedure TVdbPageEngine.ScanAllRawPaged(Cb: TVdbHeap.TScanRawPageProc;
  Skip: PByte; SkipCount: Integer);
begin
  FHeap.ScanAllRawPaged(Cb, Skip, SkipCount);
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
  syncLsn: LongWord;
begin
  { v3.19: eski sozlesme korunur — Commit(True) yazar VE bekler. }
  { v3.21: TEK fsync. Onceden DoCommit(True) FWal.Commit(True) uzerinden
    stream'i flush ediyor, ardindan AwaitDurable -> SyncDurable AYNI dosyayi
    ikinci kez flush ediyordu (commit basina iki FlushFileBuffers). }
  Result := DoCommit(False, syncLsn);
  if DoSync and Result then
    AwaitDurable(syncLsn);
end;

function TVdbPageEngine.CommitNoSync(out ASyncLsn: LongWord): Boolean;
begin
  { v3.19: yazar, fsync etmez. Durabilite cagiranin sorumlulugunda. }
  Result := DoCommit(False, ASyncLsn);
end;

procedure TVdbPageEngine.AwaitDurable(ALsn: LongWord);
var
  target: LongWord;
  leader: Boolean;
  err: string;
begin
  { v3.19 GRUP COMMIT: TEK fsync, cok commit.
    Neden grup: olculen tek fsync bedeli 0,32 ms; commit basina bu bedeli
    odemek paralel yazimi serilestiriyordu (P=4 -> 1,05x). Burada ilk gelen
    lider olur, WAL'e o an yazilmis EN SON LSN'i hedefler ve tek fsync
    yapar; bu arada commit eden diger thread'lerin kayitlari da ayni
    fsync'in kapsamina girer. Bekleyenler yalniz olayi bekler. }
  if ALsn = 0 then Exit;
  while True do
  begin
    leader := False;
    target := 0;
    FSyncCs.Enter;
    try
      if FDurableLsn >= ALsn then Exit;
      if FSyncErr <> '' then
        raise EVdbPageEngine.Create('WAL fsync hatasi: ' + FSyncErr);
      if not FSyncBusy then
      begin
        FSyncBusy := True;
        target := FWal.WrittenLsn;
        leader := True;
      end;
    finally
      FSyncCs.Leave;
    end;

    if leader then
    begin
      err := '';
      try
        FWal.SyncDurable;
      except
        on E: Exception do
          err := E.Message;
      end;
      FSyncCs.Enter;
      try
        if err = '' then
        begin
          Inc(FSyncCount);
          if target > FDurableLsn then
            FDurableLsn := target;
        end
        else
          FSyncErr := err;
        FSyncBusy := False;
        { manual-reset: once uyandir, sonra sifirla. Arada gelen bekleyen
          yine de dongude FDurableLsn'i gorup cikar. }
        FSyncEvt.SetEvent;
        FSyncEvt.ResetEvent;
      finally
        FSyncCs.Leave;
      end;
      if err <> '' then
        raise EVdbPageEngine.Create('WAL fsync hatasi: ' + err);
    end
    else
      FSyncEvt.WaitFor(20);
  end;
end;

function TVdbPageEngine.DoCommit(DoSync: Boolean; out ASyncLsn: LongWord): Boolean;
var
  LSN: LongWord;
  i: Integer;
  dirty: TVdbPageNoArray;
  P: PVdbPage;
  meta: TVdbPageBuf;
  changed: Boolean;
{$IFDEF CPUPROF}
  d0, d1, d2: Int64;
{$ENDIF}
begin
  Result := False;
  ASyncLsn := 0;
  if FStore = nil then
    raise EVdbPageEngine.Create('motor acik degil');

  if not FInTxn then
  begin
    {$IFDEF CPUPROF}
    Inc(CP[9]);
    {$ENDIF}
    Exit(True);
  end;

  {$IFDEF CPUPROF}
  d0 := CpuProfNow;
  {$ENDIF}
  LSN := FStore.NextLSN;

  { v3.1: YALNIZCA bu islemde degisen sayfalar yazilir.
    Eski davranis "tum kirli sayfalar" idi; autocommit'te her INSERT bir
    onceki commit'ten beri kirletilmis TUM sayfalari yeniden WAL'e yaziyordu
    (olculen: 64 sayfalik havuzda 63 KB/commit; havuz buyudukce daha da
    kotu). Dogru kume, islem basina kirletme isaretidir (FFrame.TxnMark).

    1) Bu islemde degisen YERLESIK sayfalar (en guncel imaj). }
  dirty := FStore.TxnPages;
  for i := 0 to High(dirty) do
    if FStore.GetPage(dirty[i], P) then
    begin
      FWal.AppendFrame(dirty[i], P);
      FStore.Release(dirty[i], False);
    end;

  { 2) Tahliye edilmis (yerlesik olmayan) ve BU islemde degisen sayfalar.
        Daha eski bir islemde yazilmis pending imajlari tekrar yazilmaz;
        sayfa okuma icin geri yuklendiginde OnMiss kaydi dusurur ve cerceve
        guncel islem isaretiyle kirli kalir, yani yukaridaki 1. adim kapsar. }
  for i := 0 to FPendingCount - 1 do
    if FPending[i].Mark = FStore.TxnId then
      FWal.AppendFrame(FPending[i].PageNo, PVdbPage(FPending[i].Data));

  { 3) Meta sayfa imaji. Yalnizca meta YAPISAL olarak degistiyse (sayfa
        sayisi / freelist). LSN commit kaydinda tasinir ve kurtarma FLSN'i
        oradan alir; degismemis meta imajini her commit'te yazmak 4 KB'lik
        bos bir cerceve demekti (autocommit'te WAL hacminin yarisi). }
  changed := (Length(dirty) > 0) or FStore.MetaStructDirty;
  if not changed then
    for i := 0 to FPendingCount - 1 do
      if FPending[i].Mark = FStore.TxnId then
      begin
        changed := True;
        Break;
      end;
  if FStore.MetaStructDirty then
  begin
    FStore.BuildMetaImage(meta);
    FWal.AppendFrame(VDB_HDR_PAGE, @meta);
  end;

  { 4) GUVENLIK AGI: tampon bossa commit kaydi yazilmaz ve LSN ilerlemezdi.
        Islem sirasinda bir sayfa degistiyse buraya dusmemeli; yine de
        olusursa commit'i gorunur kilmak icin meta imaji yazilir. }
  if FWal.BufferedCount = 0 then
  begin
    FStore.BuildMetaImage(meta);
    FWal.AppendFrame(VDB_HDR_PAGE, @meta);
  end;
  {$IFDEF CPUPROF}
  d1 := CpuProfNow; CP[6] := CP[6] + (d1 - d0);
  {$ENDIF}

  { 5) WAL commit + fsync: artik durabil. Veritabani dosyasina bu noktada
        HICBIR SEY yazilmaz (checkpoint'e kadar). }
  if not FWal.Commit(DoSync, LSN) then
    Exit(False);
  { v3.19: WAL'e yazilan en son LSN. DoSync=True ise bu noktada durabildir;
    DoSync=False ise cagiran AwaitDurable ile bekler. }
  ASyncLsn := FWal.WrittenLsn;
  {$IFDEF CPUPROF}
  d2 := CpuProfNow; CP[7] := CP[7] + (d2 - d1);
  {$ENDIF}

  FStore.EndTxn;
  FInTxn := False;
  { v3.16: motoru DOGRUDAN kullanan oturumlar islem kilidi acmaz; guvenlik
    aginin aldigi tam kilit burada birakilir (backend yolunda FWriteDepth>0
    oldugu icin no-op). }
  FStore.EndIoWrite;
  { v3.3: yalnizca VERI degistiren commit zone map damgasini ilerletir. }
  if changed then NextDataStamp;
  {$IFDEF CPUPROF}
  CP[8] := CP[8] + (CpuProfNow - d2);
  Inc(CPN);
  {$ENDIF}
  Result := True;
end;

procedure TVdbPageEngine.InstallPending;
var
  i: Integer;
begin
  { v3.29: Checkpoint'in "pending -> onbellek" adimi. Diske yazma, fsync ve
    WAL budama YAPILMAZ; bu yuzden veri kaybi riski yoktur (bkz
    StoreRefreshed gerekcesi). Yalnizca pinli olmayan, onbellekte BULUNMAYAN
    imajlar kurulur: bir sayfa onbellekte varsa cerceve imaji pending
    kopyasindan her zaman daha yeni/esittir. }
  for i := 0 to FPendingCount - 1 do
    if not FStore.IsResident(FPending[i].PageNo) then
      FStore.InstallPage(FPending[i].PageNo, PVdbPage(FPending[i].Data));
  ClearPending;
end;

function TVdbPageEngine.Checkpoint(DoSync: Boolean): Boolean;
var
  i: Integer;
begin
  Result := False;
  if FStore = nil then
    raise EVdbPageEngine.Create('motor acik degil');
  { v3.2: salt-okunur oturumda checkpoint yok; disk zaten yazilamaz. }
  if FStore.ReadOnly then Exit(True);
  { Tahliye edilmis sayfalar once dosyaya, sonra onbellekteki kirli
    sayfalar yazilir. InstallPage tahliye tetiklemez.
    Onemli: bir sayfa onbellekte varsa cerceve imaji pending kopyasindan
    HER ZAMAN daha yeni/esittir (yuklemede kirli isaretlenir). O yuzden
    pending yalnizca YERLESIK OLMAYAN sayfalar icin kurulur; aksi halde
    eski imaj yeni cercevenin uzerine yazilirdi. }
  for i := 0 to FPendingCount - 1 do
    if not FStore.IsResident(FPending[i].PageNo) then
      FStore.InstallPage(FPending[i].PageNo, PVdbPage(FPending[i].Data));
  ClearPending;
  FStore.Flush(DoSync);
  if DoSync then
  begin
    { v3.19 GRUP COMMIT BARİYERİ: WAL budanmadan once icindeki her sey
      DURABIL olmali; aksi halde fsync'i henuz yapilmamis bir commit'in
      cerceveleri budanir ve cokme halinde kaybolur. Bekleyen liderler
      bitene kadar bekle, sonra durabil LSN'i checkpoint LSN'ine cek. }
    AwaitDurable(FWal.WrittenLsn);
    FWal.Truncate(FStore.LSN);
    FSyncCs.Enter;
    try
      FDurableLsn := FWal.WrittenLsn;
      FSyncErr := '';
    finally
      FSyncCs.Leave;
    end;
  end;
  { v3.16: guvenlik agi kilidini birak (bkz. Commit). }
  FStore.EndIoWrite;
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
    Boylece dogrulanan sey DISKTEKI gercek durumdur.
    v3.2: salt-okunur oturumda WAL diske YAZILMAZ; dogrulama, WAL imajlari
    bellek katmaninda dururken depo/heap uzerinden yapilir. }
  if (not FStore.ReadOnly) and (FWal.HasContent or (FPendingCount > 0)) then
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
