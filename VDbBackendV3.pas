unit VDbBackendV3;

{ VDB v3 - Sayfa motorunu IVDbBackend'e baglayan backend (Sprint 2 / 2.4)

  Ust katman (VDbTable/VDbSql/VDbExecutor) bu arayuzu tanir; altinda
  4 KB sayfa motoru + sayfa imajli WAL vardir.

  ISLEM (BATCH) MODELI - tek yazar, bellek ustu kaplama:
    BeginBatch  : kaplama acilir (yazma yok)
    Put/Delete  : once KAPLAMAYA yazilir (okuma da kaplamayi gorur)
    CommitBatch : kaplama sirayla motora uygulanir, Commit(True) + esik
                  asilmissa Checkpoint
    AbortBatch  : kaplama atilir; motora HICBIR SEY yazilmadi -> gercek
                  geri alma (v2'deki "tablo indeksleri onarilmaz" sorunu yok)

  Kaplamanin bedeli bellek: 200k satirlik toplu yuklemede ~10 MB. WAL
  tamponu da ayni sinirda; v3.1'de cerceveler WAL dosyasina indeksli
  yazilacak ve kaplama kalkacak.

  SILME/GUNCELLEME: heap Delete/Update O(1) (slot kararli, baytlar yerinde).
  SAYIM: Count = heap.Count + kaplama farki (O(1)).

  DESTEKLENMEYEN (v3.0): kayit sifreleme (Sprint 3.4), range tarama
  (v3.1 B+tree), replication (ecNotSupported).
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  VDbBackendApi, VDbPage, VDbPageStore, VDbPageHeap, VDbPageWal, VDbPageEngine,
  VDbIdxFile, VDbSync, VDbCrypt;

const
  { Bu boyuttan buyuk WAL'de commit sonrasi checkpoint yapilir. Cok kucuk
    deger her commit'te tam sayfa yazimi demek; cok buyuk deger cokme
    sonrasi replay suresini buyutur. }
  VDB_V3_CHECKPOINT_BYTES = 8 * 1024 * 1024;

type
  EVdbBackendV3 = class(Exception);

  TVdbBackendV3 = class(TInterfacedObject, IVDbBackend)
  private
    type
      TBatchRec = record
        Present: Boolean;
        Value: TBytes;
      end;
      { v3.2 savepoint gunlugu: bir anahtarin savepoint'ten ONCEKI hali.
        HadBefore=False ise anahtar FBatch'te hic yoktu; geri almada
        FBatch'ten SILINIR (bos bir "Present=False" kaydi birakmak
        Delete'in "once var miydi" yanitini bozardi). }
      TSavepointKeyRec = record
        HadBefore: Boolean;
        Rec: TBatchRec;
      end;
      { v3.2: tek bir savepoint. Journal yalnizca O savepoint'ten sonra
        DEGISEN anahtarlari tutar (tum partiyi kopyalamak 200k satirlik
        partide her SAVEPOINT'te O(n) bellek demekti). }
      TSavepointRec = record
        Name: string;
        OrderLen: Integer;                 // FOrder'in savepoint anindaki uzunlugu
        Journal: TDictionary<QWord, TSavepointKeyRec>;
        TagDelta: TDictionary<Integer, Int64>;  // FBatchTagDelta kopyasi
      end;
    var
      FEng: TVdbPageEngine;
      FPath: string;
      FBatch: TDictionary<QWord, TBatchRec>;
      { Sprint 3.12: parti anahtarlarinin GELIS SIRASI. TDictionary
        dolasimi rastgele oldugu icin ApplyBatch sayfalara sicramali
        yaziyordu (olculen: 200k toplu yazim 8,0 us/satir; sirali
        yazimda motor 1,7 us/satir). Ayni veri, ayni atomiklik;
        yalniz uygulama sirasi giris sirasi olur. }
      FOrder: TList<QWord>;
      FBatchOpen: Boolean;
      { v3.2: acik partiyi acan oturum (0 = sahipsiz/eski davranis). }
      FWriteSession: Cardinal;
      FRowTag: TVDbRowTagFunc;
      FBeforeCommit: TDbCommitHook;
      FCheckpointBytes: Int64;
      FDirty: Boolean;
      FPoolPages: Integer;
      FScanKeys: TQWordArray;
      FScanVals: TValArray;
      FScanN: Integer;
      FScanCap: Integer;
      FScanFilter: Integer;
      { v3.1: ScanRawIterAll dogrudan akitilir (satir basina dizi buyutmesi
        ve toplu kopyalama YOK). }
      FStreamCb: TVDbRawCb;
      FStreamUser: Pointer;
      FStreamAbort: Boolean;
      FStreamFilter: Integer;
      { v3.1: satir etiketi icin tarama basina BIR kez ayrilan kucuk tampon
        (satir basina tahsis YOK). }
      FStreamTagBuf: TBytes;
      FCompactEng: TVdbPageEngine;
      FCompactN: Int64;
      { Sprint 3.4: acilis anahtari (parola Open'da turetilir, sonra
        yalniz ham anahtar tutulur; VACUUM/RESTORE yeniden acarken kullanilir). }
      FKey: TBytes;
      FPassword: string;
      FHasPassword: Boolean;
      { v3.1: tablo basina canli satir sayaci. TAM TARAMAYLA AYNI YUKLEMI
        kullanir (FRowTag), kalici DEGILDIR: acilista bir kez tam taramayla
        kurulur, yazma yolunda artimli guncellenir. Bayatlama/cokme riski
        yoktur (dogru kaynak her zaman motorun kendisidir). }
      FTagCounts: TDictionary<Integer, Int64>;
      FBatchTagDelta: TDictionary<Integer, Int64>;
      FTagBuf: TBytes;
      { Sayac kuruldu mu? False ise tutulan harita guvenilmez; ilk COUNT
        isteginde tam taramayla kurulur. }
      FTagCountsValid: Boolean;
      { v3.2: SAVEPOINT yigini (en sona eklenir). }
      FSavepoints: TList<TSavepointRec>;
      { v3.2: otomatik sikistirma (H25). Varsayilan KAPALI; commit'ten SONRA
        yalniz esik asilinca calisir. Hata commit'i bozmaz. }
      FAutoCompactOn: Boolean;
      FAutoCompactRatio: Double;
      FAutoCompactMinBytes: Int64;
      FAutoCompactCount: Int64;
      FAutoCompactBusy: Boolean;
      FLastAutoCompactError: string;
      function ValBytes: Int64;
      procedure MaybeAutoCompact;
      function AutoCompactBody(out OldBytes, NewBytes: Int64;
        MaxDeadRatio: Double; MinBytes: Int64): Boolean;
      { v3.2: oturum yalitimi (v2 TVDb.BatchIsMine/RequireBatchWrite esi).
        Baska oturum acik partiyi ne gorur ne yazar. }
      function BatchIsMine: Boolean;
      procedure RequireBatchWrite;

    procedure InitBackend(const ADbPath: string; ACreate: Boolean;
      APoolPages: Integer);
    function NewEngine(const APath: string): TVdbPageEngine;
    function GetEncrypted: Boolean;
    procedure ApplyBatch;
    function EffectiveCount: Integer;
    procedure MaybeCheckpoint;
    function PassFilter(Key: QWord; const Value: TBytes;
      TableFilter: Integer): Boolean;
    procedure ScanCb(Key: QWord; const Value: TBytes);
    { v3.1: streaming tarama geri cagirimi (sifir-kopya: Data sayfa icindedir). }
    procedure StreamCbRaw(Key: QWord; Data: PByte; Len: Integer);
    { v3.1: etiket sayaci yardimcilari. }
    function TagOf(Data: PByte; Len: Integer): Integer;
    procedure TagAdd(Tag: Integer; Delta: Int64);
    procedure TagBuildCb(Key: QWord; Data: PByte; Len: Integer);
    procedure RebuildTagCounts;
    function LoadTagCountsFromIdx: Boolean;
    procedure GetTagSummary(out Tags: TVdbIdxTagArray);
    procedure MergeTagDeltas;
    { Sprint 3.3: VACUUM/Compact yardimcilari. }
    procedure CompactCb(Key: QWord; const Value: TBytes);
    procedure SwapDbFile(const NewFilePath: string);
    { v3.2: ALTER DATABASE KEY. Yeni dosya yeni anahtar/parola ile yazilir;
      basarisizlikta ESKI kimlik bilgileri geri kurulur (dosya .bak'tan
      donerken yeni parolayla acmaya calismak backend'i kilitsiz birakirdi). }
    procedure SwapDbFileWith(const NewFilePath: string;
      const AKey: TBytes; const APassword: string; AHasPassword: Boolean);
    { v3.2: savepoint yardimcilari. }
    procedure JournalKey(Key: QWord);
    procedure ClearSavepoints;
    function FindSavepoint(const Name: string): Integer;
  public
    { ADbPath: .odb dosya yolu. ACreate=True ise yoksa olusturur. }
    constructor Create(const ADbPath: string; ACreate: Boolean = True;
      APoolPages: Integer = VDB_DEF_POOL);

    { Sprint 3.4: sifreli v3 dosyasi. Anahtar 32 baytlık AES-256'dir;
      parola verilirse PBKDF2-SHA256 ile turetilir. Sifresiz dosyaya
      anahtar vermek net hatadir. }
    constructor CreateWithKey(const ADbPath: string; const AKey: TBytes;
      ACreate: Boolean = True; APoolPages: Integer = VDB_DEF_POOL);
    constructor CreateWithPassword(const ADbPath, APassword: string;
      ACreate: Boolean = True; APoolPages: Integer = VDB_DEF_POOL);
    destructor Destroy; override;

    property Engine: TVdbPageEngine read FEng;
    { Sprint 3.4: sayfa sifreleme durumu ve anahtar parmak izi (8 hex). }
    property Encrypted: Boolean read GetEncrypted;
    function KeyFingerprint: string;
    { Checkpoint esigi (bayt). 0 = yalnizca kapanis/Flush'ta. }
    property CheckpointBytes: Int64 read FCheckpointBytes write FCheckpointBytes;

    procedure Put(Key: QWord; const Value: TBytes);
    function Get(Key: QWord; out Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    function Exists(Key: QWord): Boolean;
    function Count: Integer;

    procedure ScanAll(out Keys: TQWordArray; out Vals: TValArray;
      TableFilter: Integer = -1);
    { v3.1: tablo basina canli satir sayisi (O(1)). Tam taramayla AYNI
      yuklem: TableFilter<0 ise tum anahtarlar. Etiket cozucusu yoksa -1. }
    function CountTable(TableFilter: Integer): Int64;
    function ScanRawIterAll(TableFilter: Integer;
      Cb: TVDbRawCb; User: Pointer): Boolean;

    procedure BeginBatch;
    procedure CommitBatch;
    procedure AbortBatch;
    procedure Flush;
    function GetInBatch: Boolean;

    { v3.2: ALTER DATABASE KEY — dosya yeni parola ile yeniden sifrelenir.
      Acik parti varken reddedilir; islem atomiktir (tmp + .bak). }
    procedure Rekey(const NewPassword: string);

    { --- v3.2: yonetim / olcum (v2 TVDb API esdegeri) --- }
    function GetDeadBytes: Int64;
    function GetDataFileSize: Int64;
    function GetAutoCompactEnabled: Boolean;
    procedure SetAutoCompactEnabled(AValue: Boolean);
    function GetAutoCompactRatio: Double;
    procedure SetAutoCompactRatio(AValue: Double);
    function GetAutoCompactMinBytes: Int64;
    procedure SetAutoCompactMinBytes(AValue: Int64);
    function GetAutoCompactCount: Int64;
    function GetLastAutoCompactError: string;
    function AutoCompact(out OldBytes, NewBytes: Int64;
      MaxDeadRatio: Double; MinBytes: Int64): Boolean;


    { v3.2: SAVEPOINT. Parti kaplamasi UZERINDE calisir; motora hicbir sey
      yazilmadigi icin geri alma yalnizca kaplama gunlugu ile yapilir. }
    procedure Savepoint(const Name: string);
    function RollbackToSavepoint(const Name: string): Boolean;
    function ReleaseSavepoint(const Name: string): Boolean;

    function EnsureColumnKey: QWord;
    function ColumnKeyId: QWord;
    function ColumnKeyPath: string;
    function FileEncrypted: Boolean;
    procedure SetBeforeCommit(Proc: TDbCommitHook);
    function GetDirty: Boolean;
    procedure WaitForeignTxn(ASessionId: Cardinal);
    procedure RefreshBatchSnapshot;
    function GetFilePath: string;
    procedure SetRowTagFunc(AValue: TVDbRowTagFunc);

    { Sprint 3.1: sayfa motorunun tam butunluk denetimi (CRC + freelist
      + heap + tasma zincirleri). Acik parti varsa denetim yapilmaz. }
    function Verify(out Report: string): Boolean;

    { Sprint 3.2: checkpoint sonrasi bayt-bayt yedek; geri yukleme dosyayi
      atomik degistirir (eski dosya .bak kalir), WAL/idx temizlenir, motor
      yeniden acilir. Ust katman semayi yeniden yuklemelidir. }
    procedure BackupTo(const DestPath: string);
    procedure RestoreFrom(const SrcPath: string);

    { Sprint 3.3: VACUUM - canli kayitlar yeni ve sikisik dosyaya yazilir,
      atomik olarak yerine konur; bos sayfalar/olu baytlar dosyadan duser.
      Eski dosya .bak kalir. Ust katman semayi yeniden yuklemelidir. }
    procedure Compact(out OldBytes, NewBytes: Int64);
  end;

implementation

function TVdbBackendV3.GetEncrypted: Boolean;
begin
  Result := (FEng <> nil) and FEng.Encrypted;
end;

function TVdbBackendV3.KeyFingerprint: string;
begin
  if FEng <> nil then Result := FEng.KeyFingerprint
  else Result := '';
end;

procedure TVdbBackendV3.InitBackend(const ADbPath: string; ACreate: Boolean;
  APoolPages: Integer);
begin
  FPath := ADbPath;
  FBatch := TDictionary<QWord, TBatchRec>.Create;
  FOrder := TList<QWord>.Create;
  FTagCounts := TDictionary<Integer, Int64>.Create;
  FBatchTagDelta := TDictionary<Integer, Int64>.Create;
  FSavepoints := TList<TSavepointRec>.Create;
  { v3.2: otomatik sikistirma v2 ile AYNI varsayilanlar (KAPALI). }
  FAutoCompactOn := False;
  FAutoCompactRatio := 0.35;
  FAutoCompactMinBytes := 4 * 1024 * 1024;
  FAutoCompactCount := 0;
  FAutoCompactBusy := False;
  FLastAutoCompactError := '';
  FBatchOpen := False;
  FWriteSession := 0;
  FDirty := False;
  FCheckpointBytes := VDB_V3_CHECKPOINT_BYTES;
  FPoolPages := APoolPages;
  FEng := NewEngine(ADbPath);
  try
    FEng.Open(ACreate);
  except
    FreeAndNil(FEng);
    raise;
  end;
  { Parola modunda turetilmis ham anahtar; VACUUM/RESTORE yeniden acarken
    ayni anahtar kullanilir. }
  FKey := Copy(FEng.Store.Key, 0, Length(FEng.Store.Key));
  FPassword := '';
  FHasPassword := False;
  { v3.1: satir sayaci. FRowTag bu noktada henuz atanmamis olabilir;
    TVTableDb.CreateBackend hemen ardindan atar ve SetRowTagFunc sayaci
    .idx ozetinden (tarama YAPMADAN) yukler. Ozet yoksa ilk COUNT isteginde
    bir kez tam taramayla kurulur. }
  FTagCountsValid := False;
  FEng.OnTagSummary := GetTagSummary;
end;

function TVdbBackendV3.NewEngine(const APath: string): TVdbPageEngine;
begin
  if FHasPassword then
    Result := TVdbPageEngine.CreateWithPassword(APath, FPassword, FPoolPages)
  else if Length(FKey) > 0 then
    Result := TVdbPageEngine.CreateWithKey(APath, FKey, FPoolPages)
  else
    Result := TVdbPageEngine.Create(APath, FPoolPages);
end;

constructor TVdbBackendV3.Create(const ADbPath: string; ACreate: Boolean;
  APoolPages: Integer);
begin
  inherited Create;
  FKey := nil;
  FPassword := '';
  FHasPassword := False;
  InitBackend(ADbPath, ACreate, APoolPages);
end;

constructor TVdbBackendV3.CreateWithKey(const ADbPath: string;
  const AKey: TBytes; ACreate: Boolean; APoolPages: Integer);
begin
  inherited Create;
  FKey := Copy(AKey, 0, Length(AKey));
  FPassword := '';
  FHasPassword := False;
  InitBackend(ADbPath, ACreate, APoolPages);
end;

constructor TVdbBackendV3.CreateWithPassword(const ADbPath, APassword: string;
  ACreate: Boolean; APoolPages: Integer);
begin
  inherited Create;
  FKey := nil;
  FPassword := APassword;
  FHasPassword := True;
  InitBackend(ADbPath, ACreate, APoolPages);
end;

destructor TVdbBackendV3.Destroy;
begin
  if FBatchOpen then
  begin
    { Kapanista yarim islem yazilmaz: kaplama atilir. }
    FBatch.Clear;
    FOrder.Clear;
    FBatchOpen := False;
  end;
  ClearSavepoints;
  FreeAndNil(FSavepoints);
  FreeAndNil(FEng);       // Close: commit + checkpoint + idx
  FreeAndNil(FBatch);
  FreeAndNil(FOrder);
  FreeAndNil(FTagCounts);
  FreeAndNil(FBatchTagDelta);
  inherited Destroy;
end;

{ --------------------------------------------------------------- yardimci }

function TVdbBackendV3.PassFilter(Key: QWord; const Value: TBytes;
  TableFilter: Integer): Boolean;
var
  tag: Integer;
begin
  if TableFilter < 0 then Exit(True);
  if not Assigned(FRowTag) then Exit(True);
  tag := FRowTag(Value, Length(Value));
  Result := (tag < 0) or (tag = TableFilter);
end;

function TVdbBackendV3.EffectiveCount: Integer;
var
  pair: TPair<QWord, TBatchRec>;
  n: Integer;
begin
  n := FEng.Count;
  if not BatchIsMine then Exit(n);
  if BatchIsMine then
    for pair in FBatch do
    begin
      { Kaplamadaki her kayit: eskiden var miydi? }
      if pair.Value.Present then
      begin
        if not FEng.Contains(pair.Key) then Inc(n);
      end
      else if FEng.Contains(pair.Key) then
        Dec(n);
    end;
  Result := n;
end;

procedure TVdbBackendV3.MaybeCheckpoint;
begin
  if FCheckpointBytes <= 0 then Exit;
  if FEng.Wal.Bytes >= FCheckpointBytes then
    FEng.Checkpoint(True);
end;

procedure TVdbBackendV3.ApplyBatch;
var
  i: Integer;
  key: QWord;
  rec: TBatchRec;
  ok: Boolean;
  oldTag, newTag: Integer;
  oldVal: TBytes;
begin
  if FBatch.Count = 0 then Exit;
  { Giris sirasi: sayfalara ARDISIK yazilir (rastgele dolasim = sayfa
    sicramasi = yavas toplu yazim). }
  for i := 0 to FOrder.Count - 1 do
  begin
    key := FOrder[i];
    if not FBatch.TryGetValue(key, rec) then Continue;
    if rec.Present then
    begin
      { ONCEDEN her anahtar icin ayrica `Contains` cagriliyordu; `Insert`
        zaten "anahtar var mi" diye bakiyor. Once eklemeyi dene, yalniz
        cakismada guncelle: toplu eklemede bir hash aramasi eksilir. }
      ok := FEng.Insert(key, rec.Value);
      if ok then
      begin
        { v3.1: yeni satir -> etiket sayaci +1 }
        if Length(rec.Value) > 0 then
          TagAdd(TagOf(@rec.Value[0], Length(rec.Value)), 1);
      end
      else
      begin
        { Var olan anahtar: etiket degismis olabilir; eski deger YALNIZCA
          bu yolda okunur (toplu eklemede hic okunmaz). }
        oldTag := -2;
        if Length(rec.Value) > 0 then
          if FEng.TryGet(key, oldVal) then
            oldTag := TagOf(@oldVal[0], Length(oldVal));
        ok := FEng.Update(key, rec.Value);
        if not ok then
          raise EVdbBackendV3.Create(Format(
            'toplu yazim basarisiz: anahtar $%.16x', [key]));
        if Length(rec.Value) > 0 then
        begin
          newTag := TagOf(@rec.Value[0], Length(rec.Value));
          if oldTag = -2 then TagAdd(newTag, 1)
          else if oldTag <> newTag then
          begin
            TagAdd(oldTag, -1);
            TagAdd(newTag, 1);
          end;
        end;
      end;
    end
    else
    begin
      { Silmeden ONCE eski deger: yalnizca etiket sayaci icin. }
      if FEng.TryGet(key, oldVal) then
      begin
        FEng.Delete(key);
        if Length(oldVal) > 0 then
          TagAdd(TagOf(@oldVal[0], Length(oldVal)), -1);
      end
      else
        FEng.Delete(key);    // yoksa da zararsiz
    end;
  end;
  FBatch.Clear;
  FOrder.Clear;
  FDirty := True;
end;

{ ------------------------------------------------------------------ kayit }

{ --- v3.2: oturum yalitimi ---------------------------------------- }

function TVdbBackendV3.BatchIsMine: Boolean;
begin
  { v2 TVDb.BatchIsMine ile AYNI kural: sahipsiz parti (0) ya da oturum
    kimligi olmayan cagri eski global davranisi korur. Yalnizca kimligi
    olan FARKLI oturumlar birbirinden yalitilir. }
  Result := FBatchOpen and ((FWriteSession = 0) or
    (VdbBackendSessionId = 0) or (FWriteSession = VdbBackendSessionId));
end;

procedure TVdbBackendV3.RequireBatchWrite;
begin
  if FBatchOpen and (FWriteSession <> 0) and
     (VdbBackendSessionId <> 0) and
     (FWriteSession <> VdbBackendSessionId) then
    raise EVdbBackendV3.Create(
      'VDb: baska bir oturumun acik islemi var; once COMMIT veya ROLLBACK');
end;

procedure TVdbBackendV3.Put(Key: QWord; const Value: TBytes);
var
  rec: TBatchRec;
  oldTag, newTag: Integer;
  oldVal: TBytes;
begin
  RequireBatchWrite;
  if FBatchOpen then
  begin
    JournalKey(Key);
    rec.Present := True;
    rec.Value := Copy(Value, 0, Length(Value));
    if not FBatch.ContainsKey(Key) then
      FOrder.Add(Key);
    FBatch.AddOrSetValue(Key, rec);
    Exit;
  end;
  { Tek anahtar yolu: once eklemeyi dene (Insert zaten varlik denetimi
    yapar), yalniz cakismada guncelle. Boylece anahtar basina bir hash
    aramasi eksilir. }
  if FEng.Insert(Key, Value) then
  begin
    if Length(Value) > 0 then
      TagAdd(TagOf(@Value[0], Length(Value)), 1);
    FDirty := True;
    Exit;
  end;
  { Anahtar zaten var: etiket DEGISEBILIR (DROP TABLE + ayni PK ile yeniden
    CREATE -> ayni anahtar, farkli TableId). Eski etiket yalnizca bu yolda
    okunur; toplu eklemede hicbir ek okuma yapilmaz. }
  oldTag := -2;
  if Length(Value) > 0 then
  begin
    if FEng.TryGet(Key, oldVal) then
      oldTag := TagOf(@oldVal[0], Length(oldVal));
  end;
  if not FEng.Update(Key, Value) then
    raise EVdbBackendV3.Create('ekleme/guncelleme basarisiz');
  if Length(Value) > 0 then
  begin
    newTag := TagOf(@Value[0], Length(Value));
    if oldTag = -2 then TagAdd(newTag, 1)
    else if oldTag <> newTag then
    begin
      TagAdd(oldTag, -1);
      TagAdd(newTag, 1);
    end;
  end;
  FDirty := True;
end;

function TVdbBackendV3.Get(Key: QWord; out Value: TBytes): Boolean;
var
  rec: TBatchRec;
begin
  if BatchIsMine and FBatch.TryGetValue(Key, rec) then
  begin
    if rec.Present then
    begin
      Value := Copy(rec.Value, 0, Length(rec.Value));
      Exit(True);
    end;
    Value := nil;
    Exit(False);
  end;
  Result := FEng.TryGet(Key, Value);
end;

function TVdbBackendV3.Delete(Key: QWord): Boolean;
var
  rec: TBatchRec;
  had: Boolean;
  oldVal: TBytes;
begin
  RequireBatchWrite;
  if FBatchOpen then
  begin
    { ONCEDEN: `FBatch.AddOrSetValue(...)`'dan SONRA `FBatch.ContainsKey`
      soruluyordu; bu her zaman True oldugu icin parti icinde Delete
      HIC OLMAYAN anahtar icin de True donuyordu. Dogru yanit: silmeden
      ONCE var miydi? }
    JournalKey(Key);
    had := FEng.Contains(Key);
    if FBatch.ContainsKey(Key) then
      had := FBatch[Key].Present;
    rec.Present := False;
    rec.Value := nil;
    if not FBatch.ContainsKey(Key) then
      FOrder.Add(Key);
    FBatch.AddOrSetValue(Key, rec);
    Exit(had);
  end;
  { v3.1: etiket sayaci icin once eski deger (yalnizca silinen anahtar). }
  if FEng.TryGet(Key, oldVal) then
  begin
    Result := FEng.Delete(Key);
    if Length(oldVal) > 0 then
      TagAdd(TagOf(@oldVal[0], Length(oldVal)), -1);
  end
  else
    Result := FEng.Delete(Key);
  if Result then
    FDirty := True;
end;

function TVdbBackendV3.Exists(Key: QWord): Boolean;
begin
  if BatchIsMine and FBatch.ContainsKey(Key) then
    Exit(FBatch[Key].Present);
  Result := FEng.Contains(Key);
end;

function TVdbBackendV3.Count: Integer;
begin
  Result := EffectiveCount;
end;

{ ----------------------------------------------------------------- tarama }

procedure TVdbBackendV3.ScanCb(Key: QWord; const Value: TBytes);
begin
  if BatchIsMine and FBatch.ContainsKey(Key) then Exit;
  if not PassFilter(Key, Value, FScanFilter) then Exit;
  { v3.1: her satirda SetLength(+1) YAPILMAZ (200k satirda O(n^2) kopya
    ve yeniden tahsis). Kapasite ikiye katlanir. }
  if FScanN >= FScanCap then
  begin
    if FScanCap < 256 then FScanCap := 256 else FScanCap := FScanCap * 2;
    SetLength(FScanKeys, FScanCap);
    SetLength(FScanVals, FScanCap);
  end;
  FScanKeys[FScanN] := Key;
  FScanVals[FScanN] := Value;
  Inc(FScanN);
end;

procedure TVdbBackendV3.ScanAll(out Keys: TQWordArray; out Vals: TValArray;
  TableFilter: Integer);
var
  pair: TPair<QWord, TBatchRec>;
begin
  FScanKeys := nil;
  FScanVals := nil;
  FScanN := 0;
  FScanCap := 0;
  FScanFilter := TableFilter;

  { Motor tarafi: kaplamada islem gormus anahtarlar atlanir. }
  FEng.ScanAll(ScanCb);

  { Kaplama tarafi: en guncel deger. }
  if BatchIsMine then
    for pair in FBatch do
    begin
      if not pair.Value.Present then Continue;
      if not PassFilter(pair.Key, pair.Value.Value, TableFilter) then Continue;
      if FScanN >= FScanCap then
      begin
        if FScanCap < 256 then FScanCap := 256 else FScanCap := FScanCap * 2;
        SetLength(FScanKeys, FScanCap);
        SetLength(FScanVals, FScanCap);
      end;
      FScanKeys[FScanN] := pair.Key;
      FScanVals[FScanN] := Copy(pair.Value.Value, 0, Length(pair.Value.Value));
      Inc(FScanN);
    end;

  SetLength(FScanKeys, FScanN);
  SetLength(FScanVals, FScanN);
  Keys := FScanKeys;
  Vals := FScanVals;
  FScanKeys := nil;
  FScanVals := nil;
  FScanN := 0;
  FScanCap := 0;
end;

procedure TVdbBackendV3.StreamCbRaw(Key: QWord; Data: PByte; Len: Integer);
var
  tag, n: Integer;
begin
  if FStreamAbort then Exit;
  if BatchIsMine and FBatch.ContainsKey(Key) then Exit;
  { PassFilter'in sifir-kopya esdegeri: satir etiketi degerin ILK baytlarindan
    cikar; 8 baytlik sabit tampona kopyalanir (satir basina tahsis YOK). }
  if (FStreamFilter >= 0) and Assigned(FRowTag) then
  begin
    n := Len;
    if n > Length(FStreamTagBuf) then n := Length(FStreamTagBuf);
    if n > 0 then Move(Data^, FStreamTagBuf[0], n);
    tag := FRowTag(FStreamTagBuf, Len);
    if (tag >= 0) and (tag <> FStreamFilter) then Exit;
  end;
  if not FStreamCb(Key, Data, Len, FStreamUser) then
    FStreamAbort := True;
end;

function TVdbBackendV3.ScanRawIterAll(TableFilter: Integer;
  Cb: TVDbRawCb; User: Pointer): Boolean;
var
  pair: TPair<QWord, TBatchRec>;
  n: Integer;
begin
  { v3.1: sonuc kumesi ARTIK BIRIKTIRILMEZ; satirlar dogrudan geri cagirima
    akitilir ve sayfa ici hucre KOPYALANMAZ. Eski yol her satirda iki dinamik
    diziyi SetLength(+1) ile buyutuyor (200k satirda O(n^2) kopya + 200k
    yeniden tahsis), ayrica satir basina deger icin bir TBytes ayiriyordu.
    Gorunurluk/eleme kurallari AYNI: once motor (kaplamada islem gormus
    anahtarlar atlanir), sonra kaplama. }
  FStreamCb := Cb;
  FStreamUser := User;
  FStreamAbort := False;
  FStreamFilter := TableFilter;
  if Length(FStreamTagBuf) < 8 then SetLength(FStreamTagBuf, 8);
  FEng.ScanAllRaw(StreamCbRaw);
  if FStreamAbort then Exit(False);

  if FBatchOpen then
    for pair in FBatch do
    begin
      if not pair.Value.Present then Continue;
      if not PassFilter(pair.Key, pair.Value.Value, TableFilter) then Continue;
      n := Length(pair.Value.Value);
      if n > 0 then
      begin
        if not Cb(pair.Key, @pair.Value.Value[0], n, User) then Exit(False);
      end
      else if not Cb(pair.Key, nil, 0, User) then Exit(False);
    end;
  Result := True;
end;

{ ------------------------------------------------- v3.1: etiket sayaci }

function TVdbBackendV3.TagOf(Data: PByte; Len: Integer): Integer;
{ Satir etiketi = degerin ilk baytlari (FRowTag). Sema kaydi -1 doner.
  Sabit tampona en fazla 16 bayt kopyalanir; satir basina tahsis YOK. }
var
  n: Integer;
begin
  if not Assigned(FRowTag) then Exit(-1);
  if (Data = nil) or (Len <= 0) then Exit(-1);
  if Length(FTagBuf) < 16 then SetLength(FTagBuf, 16);
  n := Len;
  if n > 16 then n := 16;
  Move(Data^, FTagBuf[0], n);
  Result := FRowTag(FTagBuf, Len);
end;

procedure TVdbBackendV3.TagAdd(Tag: Integer; Delta: Int64);
var
  cur: Int64;
begin
  if Delta = 0 then Exit;
  { Sayac henuz kurulmadiysa yazma yolu haritayi KIRLETMEZ. }
  if not FTagCountsValid then Exit;
  if FBatchOpen then
  begin
    if not FBatchTagDelta.TryGetValue(Tag, cur) then cur := 0;
    FBatchTagDelta.AddOrSetValue(Tag, cur + Delta);
    Exit;
  end;
  if not FTagCounts.TryGetValue(Tag, cur) then cur := 0;
  cur := cur + Delta;
  if cur <= 0 then FTagCounts.Remove(Tag)
  else FTagCounts.AddOrSetValue(Tag, cur);
end;

procedure TVdbBackendV3.TagBuildCb(Key: QWord; Data: PByte; Len: Integer);
var
  tag: Integer;
  cur: Int64;
begin
  tag := TagOf(Data, Len);
  if not FTagCounts.TryGetValue(tag, cur) then cur := 0;
  FTagCounts.AddOrSetValue(tag, cur + 1);
end;

procedure TVdbBackendV3.RebuildTagCounts;
{ Sayaci motorun GERCEK iceriginden yeniden kurar. Kalici bir kayit yoktur;
  bu yuzden cokme/bayatlik kaynakli yanlis sayim mumkun degildir. Pahali
  (tam tarama); yalnizca .idx ozeti yoksa/guvenilmezse cagrilir. }
begin
  FTagCounts.Clear;
  FTagCountsValid := False;
  if FEng = nil then Exit;
  if not Assigned(FRowTag) then Exit;
  FEng.ScanAllRaw(TagBuildCb);
  FTagCountsValid := True;
end;

function TVdbBackendV3.LoadTagCountsFromIdx: Boolean;
{ `.idx` ozeti dizinle AYNI LSN'de yazildi; idx taze ise ozet de tutarlidir.
  Bos ozet yalnizca bos veritabaninda guvenilirdir (bkz. IdxTagsValid). }
var
  tags: TVdbIdxTagArray;
  i: Integer;
begin
  Result := False;
  FTagCounts.Clear;
  FTagCountsValid := False;
  if (FEng = nil) or (not Assigned(FRowTag)) then Exit;
  if not FEng.IdxTagsValid then Exit;
  tags := FEng.IdxTags;
  for i := 0 to High(tags) do
    if tags[i].Count > 0 then
      FTagCounts.AddOrSetValue(tags[i].Tag, tags[i].Count);
  FTagCountsValid := True;
  Result := True;
end;

procedure TVdbBackendV3.GetTagSummary(out Tags: TVdbIdxTagArray);
var
  pair: TPair<Integer, Int64>;
  n: Integer;
begin
  SetLength(Tags, 0);
  if not FTagCountsValid then Exit;   // guvenilmez ozet YAZILMAZ
  SetLength(Tags, FTagCounts.Count);
  n := 0;
  for pair in FTagCounts do
  begin
    if pair.Value <= 0 then Continue;
    Tags[n].Tag := pair.Key;
    Tags[n].Count := pair.Value;
    Inc(n);
  end;
  SetLength(Tags, n);
end;

procedure TVdbBackendV3.MergeTagDeltas;
var
  pair: TPair<Integer, Int64>;
  cur: Int64;
begin
  if FBatchTagDelta.Count = 0 then Exit;
  if not FTagCountsValid then
  begin
    FBatchTagDelta.Clear;
    Exit;
  end;
  for pair in FBatchTagDelta do
  begin
    if not FTagCounts.TryGetValue(pair.Key, cur) then cur := 0;
    cur := cur + pair.Value;
    if cur <= 0 then FTagCounts.Remove(pair.Key)
    else FTagCounts.AddOrSetValue(pair.Key, cur);
  end;
  FBatchTagDelta.Clear;
end;

function TVdbBackendV3.CountTable(TableFilter: Integer): Int64;
var
  cur: Int64;
begin
  { Acik kaplama varsa bekleyen degisiklikler sayaca YANSIMAZ; cagiran
    (yurutucu) bu durumda tam tarama yapar. }
  if BatchIsMine then Exit(-1);
  if TableFilter < 0 then Exit(FEng.Count);
  if not Assigned(FRowTag) then Exit(-1);
  { Sayac .idx ozetinden geldiyse burada tarama YOK; yoksa bir kez kurulur. }
  if not FTagCountsValid then
    RebuildTagCounts;
  if not FTagCountsValid then Exit(-1);
  if FTagCounts.TryGetValue(TableFilter, cur) then Result := cur
  else Result := 0;
end;

{ ------------------------------------------------------------------ islem }

procedure TVdbBackendV3.BeginBatch;
begin
  RequireBatchWrite;       // v3.2: baskasi acik parti tutuyorsa reddet
  if FBatchOpen then Exit;
  ClearSavepoints;
  FBatch.Clear;
  FOrder.Clear;
  FBatchOpen := True;
  FWriteSession := VdbBackendSessionId;
end;

procedure TVdbBackendV3.CommitBatch;
begin
  RequireBatchWrite;
  if not FBatchOpen then Exit;
  if Assigned(FBeforeCommit) then
    FBeforeCommit;          // kisit denetimi: hata firlatirsa kaplama durur
  ApplyBatch;
  FBatchOpen := False;
  FWriteSession := 0;
  ClearSavepoints;
  { v3.1: parti ici etiket degisimleri simdi sayaca islenir. }
  MergeTagDeltas;
  FBatch.Clear;
  FOrder.Clear;
  if FDirty then
  begin
    FEng.Commit(True);
    FDirty := False;
    MaybeCheckpoint;
    MaybeAutoCompact;     // v3.2 (H25)
  end;
end;

procedure TVdbBackendV3.AbortBatch;
begin
  RequireBatchWrite;
  ClearSavepoints;
  FBatch.Clear;
  FOrder.Clear;
  FBatchTagDelta.Clear;
  FBatchOpen := False;
  FWriteSession := 0;
end;

procedure TVdbBackendV3.Flush;
begin
  if FBatchOpen then Exit;
  { P-DUR sozlesmesi yalniz DAYANIKLILIK ister: commit WAL'e yazilip fsync
    edilir. 2026-10-25 (Sprint 3.12): ONCEDEN burada tam `Checkpoint` de
    yapiliyordu; SQL katmani her autocommit yazimdan sonra Flush cagirdigi
    icin tek satirlik INSERT tum sayfalari veri dosyasina geri yaziyordu.
    Olculen bedel: autocommit INSERT 0,42 ms (v2) -> 1,17 ms (v3) — kabul
    hedefi 0,55 ms asiliyordu. Artik checkpoint YALNIZ esik asilinca
    (`MaybeCheckpoint`), acik cagrida, kapanista, yedekte ve VACUUM'da
    yapilir; veri dosyasi motor acikken bayat olabilir, dogru kaynak WAL'dir. }
  if FDirty then
  begin
    FEng.Commit(True);
    FDirty := False;
    MaybeCheckpoint;
    MaybeAutoCompact;     // v3.2 (H25): autocommit yolu
  end;
end;

function TVdbBackendV3.GetInBatch: Boolean;
begin
  Result := FBatchOpen;
end;

{ --------------------------------------------------- v3.2: SAVEPOINT }

function TVdbBackendV3.FindSavepoint(const Name: string): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := FSavepoints.Count - 1 downto 0 do
    if SameText(FSavepoints[i].Name, Name) then
      Exit(i);
end;

procedure TVdbBackendV3.ClearSavepoints;
var
  i: Integer;
  sp: TSavepointRec;
begin
  if FSavepoints = nil then Exit;
  for i := 0 to FSavepoints.Count - 1 do
  begin
    sp := FSavepoints[i];
    sp.Journal.Free;
    sp.TagDelta.Free;
  end;
  FSavepoints.Clear;
end;

{ Key ilk kez (bu savepoint'ten sonra) degistirilmeden ONCE cagrilir:
  her aktif savepoint icin anahtarin o andaki halini bir kez saklar.
  Maliyet yalnizca savepoint VARKEN ve anahtar basina BIR kez olur. }
procedure TVdbBackendV3.JournalKey(Key: QWord);
var
  i: Integer;
  sp: TSavepointRec;
  je: TSavepointKeyRec;
begin
  if (FSavepoints = nil) or (FSavepoints.Count = 0) then Exit;
  for i := 0 to FSavepoints.Count - 1 do
  begin
    sp := FSavepoints[i];
    if sp.Journal.ContainsKey(Key) then Continue;
    je.HadBefore := FBatch.TryGetValue(Key, je.Rec);
    if not je.HadBefore then
    begin
      je.Rec.Present := False;
      je.Rec.Value := nil;
    end;
    sp.Journal.AddOrSetValue(Key, je);
  end;
end;

procedure TVdbBackendV3.Savepoint(const Name: string);
var
  sp: TSavepointRec;
  pair: TPair<Integer, Int64>;
begin
  RequireBatchWrite;
  if FindSavepoint(Name) >= 0 then
    raise EVdbBackendV3.CreateFmt('savepoint zaten var: %s', [Name]);
  { SQL standardi: SAVEPOINT acik islem yoksa ORTUK islem baslatir. }
  if not FBatchOpen then BeginBatch;
  sp.Name := Name;
  sp.OrderLen := FOrder.Count;
  sp.Journal := TDictionary<QWord, TSavepointKeyRec>.Create;
  sp.TagDelta := TDictionary<Integer, Int64>.Create;
  for pair in FBatchTagDelta do
    sp.TagDelta.AddOrSetValue(pair.Key, pair.Value);
  FSavepoints.Add(sp);
end;

function TVdbBackendV3.RollbackToSavepoint(const Name: string): Boolean;
var
  ix, i: Integer;
  sp: TSavepointRec;
  pair: TPair<QWord, TSavepointKeyRec>;
  tp: TPair<Integer, Int64>;
begin
  RequireBatchWrite;
  ix := FindSavepoint(Name);
  if ix < 0 then Exit(False);
  sp := FSavepoints[ix];
  { 1) Savepoint'ten sonra degisen anahtarlari o andaki haline dondur.
    HadBefore=False olanlar FBatch'te hic yoktu -> kaydi da silinir. }
  for pair in sp.Journal do
  begin
    if pair.Value.HadBefore then
      FBatch.AddOrSetValue(pair.Key, pair.Value.Rec)
    else
      FBatch.Remove(pair.Key);
  end;
  { 2) FOrder'i savepoint uzunluguna kirp. Girisler yalnizca "FBatch'te
    yokken" eklendigi ve savepoint disinda silinmedigi icin kirpma tam
    olarak sonradan eklenen girisleri atar. }
  while FOrder.Count > sp.OrderLen do
    FOrder.Delete(FOrder.Count - 1);
  { 3) Etiket deltalari da savepoint haline doner. }
  FBatchTagDelta.Clear;
  for tp in sp.TagDelta do
    FBatchTagDelta.AddOrSetValue(tp.Key, tp.Value);
  { 4) SONRAKI savepoint'ler atilir; HEDEF kalir (SQLite davranisi:
    ayni noktaya tekrar donulebilir ve RELEASE edilebilir). }
  for i := FSavepoints.Count - 1 downto ix + 1 do
  begin
    sp := FSavepoints[i];
    sp.Journal.Free;
    sp.TagDelta.Free;
    FSavepoints.Delete(i);
  end;
  Result := True;
end;

function TVdbBackendV3.ReleaseSavepoint(const Name: string): Boolean;
var
  ix, i: Integer;
  sp: TSavepointRec;
begin
  RequireBatchWrite;
  ix := FindSavepoint(Name);
  if ix < 0 then Exit(False);
  { RELEASE veriyi COMMIT ETMEZ; yalnizca geri donme noktasini (ve
    sonrakileri) dusurur. }
  for i := FSavepoints.Count - 1 downto ix do
  begin
    sp := FSavepoints[i];
    sp.Journal.Free;
    sp.TagDelta.Free;
    FSavepoints.Delete(i);
  end;
  Result := True;
end;

{ ------------------------------------------------------ sema / sifreleme }

function TVdbBackendV3.ColumnKeyPath: string;
begin
  Result := ChangeFileExt(FPath, '.colkey');
end;

function TVdbBackendV3.EnsureColumnKey: QWord;
var
  id: QWord;
begin
  { v3.2: .colkey bicimi v2 ile AYNI olmali (VDbCrypt): ilk 8 bayt sihir,
    sonra anahtar kimligi, sonra DPAPI ile korunmus 32 baytlik anahtar.
    Dosya varsa yuklenir (anahtar SUREC KAYIT DEFTERINE yazilir; satir
    kodlayicisi degeri onunla muhurler), yoksa uretilir. }
  if FileExists(ColumnKeyPath) then
  begin
    id := 0;
    if not VDbColumnKeyLoadFile(ColumnKeyPath, id) then
      raise EVdbBackendV3.Create('kolon anahtari yuklenemedi: ' +
        ColumnKeyPath);
    Exit(id);
  end;
  id := 0;
  if not VDbColumnKeyCreateFile(ColumnKeyPath, id) then
    raise EVdbBackendV3.Create('kolon anahtari olusturulamadi: ' +
      ColumnKeyPath);
  Result := id;
end;

function TVdbBackendV3.FileEncrypted: Boolean;
begin
  { v3.2: kolon sifrelemesi dosya sifrelemesine dayanir; sayfa deposu
    parola/anahtar ile acildiysa True. }
  Result := (FEng <> nil) and FEng.Store.Encrypted;
end;

function TVdbBackendV3.ColumnKeyId: QWord;
var
  id: QWord;
begin
  Result := 0;
  if not FileExists(ColumnKeyPath) then Exit;
  { Yukleme AYNI ZAMANDA anahtari surce kayit defterine yazar; sifreli
    kolon degerlerinin cozulmesi icin bu sart. }
  id := 0;
  if not VDbColumnKeyLoadFile(ColumnKeyPath, id) then
    raise EVdbBackendV3.Create('kolon anahtari yuklenemedi: ' +
      ColumnKeyPath);
  Result := id;
end;

procedure TVdbBackendV3.SetBeforeCommit(Proc: TDbCommitHook);
begin
  FBeforeCommit := Proc;
end;

procedure TVdbBackendV3.SetRowTagFunc(AValue: TVDbRowTagFunc);
begin
  FRowTag := AValue;
  if FEng = nil then Exit;
  { v3.1: sayac kaynagi, en iyiden en pahaliya:
      1) `.idx` ozeti (dizinle ayni LSN) -> tarama YOK
      2) bos veritabani (0 anahtar)     -> dogru taban 0, tarama YOK
      3) aksi halde                     -> ilk COUNT isteginde bir kez tarama }
  if FEng.IdxTagsValid then
    LoadTagCountsFromIdx
  else if FEng.Count = 0 then
  begin
    FTagCounts.Clear;
    FTagCountsValid := True;
  end
  else
    FTagCountsValid := False;
end;

function TVdbBackendV3.GetDirty: Boolean;
begin
  Result := FDirty or (FBatchOpen and (FBatch.Count > 0));
end;

procedure TVdbBackendV3.WaitForeignTxn(ASessionId: Cardinal);
begin
  { v3.0 tek yazar: beklenecek yabanci islem yok. }
end;

procedure TVdbBackendV3.RefreshBatchSnapshot;
begin
  { v3.0'da snapshot/MVCC yok: parti icinde her okuma en guncel kaplamayi
    ve motoru gorur; ilerletilecek gorunurluk penceresi yok. }
end;

function TVdbBackendV3.GetFilePath: string;
begin
  Result := FPath;
end;

function TVdbBackendV3.Verify(out Report: string): Boolean;
begin
  { Acik partideki degisiklikler henuz durabil degil; denetim yalnizca
    onaylanmis durumu kapsar. Sessizce commit etmek yerine acikca reddet. }
  if FBatchOpen then
  begin
    Report := 'acik parti varken VERIFY yapilamaz (once COMMIT/ROLLBACK)';
    Exit(False);
  end;
  Result := FEng.Verify(Report);
end;

procedure TVdbBackendV3.BackupTo(const DestPath: string);
begin
  if FBatchOpen then
    raise EVdbBackendV3.Create('acik parti varken yedek alinamaz (once COMMIT/ROLLBACK)');
  { Bellekte commit edilmemis degisiklik varsa once durabil hale getir. }
  if FDirty then
  begin
    FEng.Commit(True);
    FDirty := False;
  end;
  { Checkpoint dosyayi tamamlar ve WAL'i budar: kopya kendi kendine yeter. }
  FEng.Checkpoint(True);
  FEng.Store.CopyCommittedTo(DestPath);
end;

procedure TVdbBackendV3.RestoreFrom(const SrcPath: string);
var
  tmp: string;
  src, dst: TFileStream;
  hdr: array[0..75] of Byte;
  magic, ver, flags: LongWord;
  i: Integer;
begin
  if FBatchOpen then
    raise EVdbBackendV3.Create('acik parti varken geri yukleme yapilamaz');
  if not FileExists(SrcPath) then
    raise EVdbBackendV3.Create('RESTORE: yedek dosyasi bulunamadi: ' + SrcPath);
  if SameFileName(ExpandFileName(SrcPath), ExpandFileName(FPath)) then
    raise EVdbBackendV3.Create('RESTORE: kaynak ile hedef ayni dosya');
  src := TFileStream.Create(SrcPath, fmOpenRead or fmShareDenyNone);
  try
    if src.Size < SizeOf(hdr) then
      raise EVdbBackendV3.Create('RESTORE: kaynak dosya cok kisa');
    src.ReadBuffer(hdr, SizeOf(hdr));
  finally
    src.Free;
  end;
  Move(hdr[0], magic, SizeOf(magic));
  Move(hdr[4], ver, SizeOf(ver));
  if (magic <> VDB_FILE_MAGIC) or (ver <> VDB_FILE_VER) then
    raise EVdbBackendV3.Create('RESTORE: kaynak v3 sayfa motoru dosyasi degil');

  { Sifreleme bicimi ve anahtar kaynakla AYNI olmali; aksi halde geri
    yuklenen dosya acilamaz ya da yanlis anahtarla sessizce kalirdi. }
  Move(hdr[VDB_META_FLAGS], flags, SizeOf(flags));
  if (flags and VDB_META_FLAG_ENC) <> 0 then
  begin
    if not FEng.Store.Encrypted then
      raise EVdbBackendV3.Create(
        'RESTORE: kaynak sifreli, hedef sifresiz (once sifreli olarak acin)');
    for i := 0 to 15 do
      if hdr[VDB_META_KEYCHECK + i] <> FEng.Store.KeyCheck[i] then
        raise EVdbBackendV3.Create(
          'RESTORE: yedek farkli anahtarla sifrelenmis (anahtar dogrulayici tutmadi)');
  end
  else if FEng.Store.Encrypted then
    raise EVdbBackendV3.Create(
      'RESTORE: kaynak sifresiz, hedef sifreli');

  { Calisan durumu diske indir; sonra motoru kapat. }
  if FDirty then
  begin
    FEng.Commit(True);
    FDirty := False;
  end;
  FEng.Checkpoint(True);

  tmp := FPath + '.restore.tmp';
  if FileExists(tmp) then DeleteFile(tmp);
  src := TFileStream.Create(SrcPath, fmOpenRead or fmShareDenyNone);
  try
    dst := TFileStream.Create(tmp, fmCreate);
    try
      dst.CopyFrom(src, 0);
      VDbFlushStream(dst);
    finally
      dst.Free;
    end;
  finally
    src.Free;
  end;

  SwapDbFile(tmp);
end;

procedure TVdbBackendV3.CompactCb(Key: QWord; const Value: TBytes);
begin
  if not FCompactEng.Insert(Key, Value) then
    raise EVdbBackendV3.Create(Format(
      'VACUUM: anahtar $%.16x yeni dosyaya yazilamadi', [Key]));
  Inc(FCompactN);
end;

procedure TVdbBackendV3.Compact(out OldBytes, NewBytes: Int64);
var
  tmp: string;
  newEng: TVdbPageEngine;
  tagsWere: Boolean;
begin
  if FBatchOpen then
    raise EVdbBackendV3.Create('acik parti varken VACUUM yapilamaz');
  if FDirty then
  begin
    FEng.Commit(True);
    FDirty := False;
  end;
  FEng.Checkpoint(True);
  { Sprint 3.10: CANLI dosyayi ikinci kez ACMA — Unix'te flock cakisir. }
  OldBytes := VDbFileBytes(FPath);

  tmp := FPath + '.compact.tmp';
  if FileExists(tmp) then DeleteFile(tmp);
  newEng := NewEngine(tmp);
  try
    try
      newEng.Open(True);
      FCompactEng := newEng;
      FCompactN := 0;
      try
        FEng.ScanAll(CompactCb);
      finally
        FCompactEng := nil;
      end;
      newEng.Close;   // checkpoint + idx; dosya tam ve kendi kendine yeter
    finally
      FreeAndNil(newEng);
    end;
  except
    { Yarim kalan gecici dosya bir sonraki VACUUM'u etkilemesin. }
    if FileExists(tmp) then DeleteFile(tmp);
    raise;
  end;

  { Kaynak dosya ve yeni dosya ayni canli anahtar kumesini tasimali. }
  tagsWere := FTagCountsValid;
  if FCompactN <> FEng.Count then
  begin
    if FileExists(tmp) then DeleteFile(tmp);
    raise EVdbBackendV3.Create(Format(
      'VACUUM: anahtar sayisi tutmuyor (yazilan %d, kaynak %d)',
      [FCompactN, FEng.Count]));
  end;

  SwapDbFile(tmp);
  { v3.1: VACUUM anahtar kumesini KORUR (yukarida dogrulandi); sayac da
    gecerli kalir -> VACUUM sonrasi COUNT(*) yine O(1). }
  FTagCountsValid := tagsWere;
  NewBytes := VDbFileBytes(FPath);
end;

procedure TVdbBackendV3.Rekey(const NewPassword: string);
var
  tmp: string;
  newEng: TVdbPageEngine;
  n: Int64;
  tagsWere: Boolean;
begin
  if FBatchOpen then
    raise EVdbBackendV3.Create('acik parti varken ALTER DATABASE KEY yapilamaz');
  if not FEng.Store.Encrypted then
    raise EVdbBackendV3.Create(
      'dosya sifresiz: ALTER DATABASE KEY icin once sifreli dosya gerekir');
  if Trim(NewPassword) = '' then
    raise EVdbBackendV3.Create('ALTER DATABASE KEY: yeni parola bos olamaz');
  if FDirty then
  begin
    FEng.Commit(True);
    FDirty := False;
  end;
  FEng.Checkpoint(True);

  tmp := FPath + '.rekey.tmp';
  if FileExists(tmp) then DeleteFile(tmp);
  { Yeni dosya YENI parola ile olusturulur: kayitlar cozulmus halde
    taramadan gelir, yazarken yeni anahtarla sifrelenir. }
  newEng := TVdbPageEngine.CreateWithPassword(tmp, NewPassword, FPoolPages);
  try
    try
      newEng.Open(True);
      FCompactEng := newEng;
      FCompactN := 0;
      n := 0;
      try
        FEng.ScanAll(CompactCb);
      finally
        FCompactEng := nil;
      end;
      n := FCompactN;
      newEng.Close;   // checkpoint + idx
    finally
      FreeAndNil(newEng);
    end;
  except
    if FileExists(tmp) then DeleteFile(tmp);
    raise;
  end;

  if n <> FEng.Count then
  begin
    if FileExists(tmp) then DeleteFile(tmp);
    raise EVdbBackendV3.Create(Format(
      'ALTER DATABASE KEY: anahtar sayisi tutmuyor (yazilan %d, kaynak %d)',
      [n, FEng.Count]));
  end;

  tagsWere := FTagCountsValid;
  SwapDbFileWith(tmp, nil, NewPassword, True);
  { Anahtar kumesi KORUNDU (yukarida dogrulandi) -> sayac gecerli. }
  FTagCountsValid := tagsWere;
end;

{ --- v3.2: yonetim / otomatik sikistirma (H25 esdegeri) --- }

function TVdbBackendV3.ValBytes: Int64;
begin
  if FEng = nil then Exit(0);
  Result := Int64(FEng.Store.PageCount) * Int64(FEng.Store.PageSize);
end;

function TVdbBackendV3.GetDeadBytes: Int64;
begin
  if FEng = nil then Exit(0);
  { v3'te "olu" alan = freelist'teki sayfalar: silinen/guncellenen satirin
    bosalttigi sayfa yeniden kullanilabilir, ama VACUUM'a kadar dosyada
    durur. (Heap ici bosluk freelist'e donustugu anda burada sayilir.) }
  Result := Int64(FEng.Store.FreeCount) * Int64(FEng.Store.PageSize);
end;

function TVdbBackendV3.GetDataFileSize: Int64;
begin
  Result := ValBytes;
end;

function TVdbBackendV3.GetAutoCompactEnabled: Boolean;
begin
  Result := FAutoCompactOn;
end;

procedure TVdbBackendV3.SetAutoCompactEnabled(AValue: Boolean);
begin
  FAutoCompactOn := AValue;
end;

function TVdbBackendV3.GetAutoCompactRatio: Double;
begin
  Result := FAutoCompactRatio;
end;

procedure TVdbBackendV3.SetAutoCompactRatio(AValue: Double);
begin
  if AValue <= 0 then AValue := 0.35;
  if AValue > 1 then AValue := 1;
  FAutoCompactRatio := AValue;
end;

function TVdbBackendV3.GetAutoCompactMinBytes: Int64;
begin
  Result := FAutoCompactMinBytes;
end;

procedure TVdbBackendV3.SetAutoCompactMinBytes(AValue: Int64);
begin
  if AValue < 0 then AValue := 0;
  FAutoCompactMinBytes := AValue;
end;

function TVdbBackendV3.GetAutoCompactCount: Int64;
begin
  Result := FAutoCompactCount;
end;

function TVdbBackendV3.GetLastAutoCompactError: string;
begin
  Result := FLastAutoCompactError;
end;

function TVdbBackendV3.AutoCompactBody(out OldBytes, NewBytes: Int64;
  MaxDeadRatio: Double; MinBytes: Int64): Boolean;
var
  sz, dead: Int64;
begin
  Result := False;
  OldBytes := 0;
  NewBytes := 0;
  if FEng = nil then Exit;
  if FBatchOpen then Exit;      // parti icinde VACUUM olmaz (veri kaplamada)
  sz := ValBytes;
  if sz <= 0 then Exit;
  if sz < MinBytes then Exit;
  dead := GetDeadBytes;
  if dead <= 0 then Exit;
  if (Double(dead) / Double(sz)) < MaxDeadRatio then Exit;
  Compact(OldBytes, NewBytes);
  Result := True;
end;

function TVdbBackendV3.AutoCompact(out OldBytes, NewBytes: Int64;
  MaxDeadRatio: Double; MinBytes: Int64): Boolean;
begin
  Result := AutoCompactBody(OldBytes, NewBytes, MaxDeadRatio, MinBytes);
end;

procedure TVdbBackendV3.MaybeAutoCompact;
// H25: commit tamamlandiktan SONRA. Karar O(1); yalniz esik asilirsa dosya
// bir kez bastan yazilir. Hata commit'i BOZMAZ (veri zaten fsync'li);
// yalnizca LastAutoCompactError'a yazilir.
var
  o, n: Int64;
begin
  if (not FAutoCompactOn) or FAutoCompactBusy then Exit;
  if FBatchOpen or (FEng = nil) then Exit;
  if GetDeadBytes <= 0 then Exit;
  if ValBytes < FAutoCompactMinBytes then Exit;
  if (Double(GetDeadBytes) / Double(ValBytes)) < FAutoCompactRatio then Exit;
  FAutoCompactBusy := True;
  try
    try
      AutoCompactBody(o, n, FAutoCompactRatio, FAutoCompactMinBytes);
      Inc(FAutoCompactCount);
      FLastAutoCompactError := '';
    except
      on E: Exception do
        FLastAutoCompactError := E.Message;
    end;
  finally
    FAutoCompactBusy := False;
  end;
end;

procedure TVdbBackendV3.SwapDbFile(const NewFilePath: string);
begin
  SwapDbFileWith(NewFilePath, FKey, FPassword, FHasPassword);
end;

{ v3.2: yeni kimlik bilgileriyle dosya degistirme. Basarisizlikta ESKI
  kimlik geri kurulur; aksi halde .bak'tan donen ESKI dosya yeni parolayla
  acilmaya calisilir ve backend FEng=nil ile kilitsiz kalirdi. }
procedure TVdbBackendV3.SwapDbFileWith(const NewFilePath: string;
  const AKey: TBytes; const APassword: string; AHasPassword: Boolean);
var
  bak, wal, idx: string;
  oldKey: TBytes;
  oldPass: string;
  oldHas: Boolean;
begin
  oldKey := FKey;
  oldPass := FPassword;
  oldHas := FHasPassword;
  bak := FPath + '.bak';
  wal := FPath + '.wal';
  idx := FPath + '.idx';
  FreeAndNil(FEng);
  FEng := nil;
  FKey := Copy(AKey, 0, Length(AKey));
  FPassword := APassword;
  FHasPassword := AHasPassword;
  try
    if FileExists(bak) then DeleteFile(bak);
    if not RenameFile(FPath, bak) then
      raise EVdbBackendV3.Create('dosya degistirme: mevcut dosya .bak yapilamadi');
    try
      if not RenameFile(NewFilePath, FPath) then
        raise EVdbBackendV3.Create('dosya degistirme: yeni dosya yerine konamadi');
    except
      RenameFile(bak, FPath);
      raise;
    end;
    { Yeni dosyanin WAL'i ve dizini ESKI dosyaya aittir; asla kullanilmaz. }
    if FileExists(wal) then DeleteFile(wal);
    if FileExists(idx) then DeleteFile(idx);
    { Uretim sirasinda yeni dosyanin yaninda olusan gecici WAL/.idx de
      kalici olmamali: yoksa sonraki acilis onlari bu dosyaya ait sanar. }
    if FileExists(NewFilePath + '.wal') then DeleteFile(NewFilePath + '.wal');
    if FileExists(NewFilePath + '.idx') then DeleteFile(NewFilePath + '.idx');
    FEng := NewEngine(FPath);
    try
      FEng.Open(False);
    except
      FreeAndNil(FEng);
      raise;
    end;
    { Turetilmis ham anahtar (parola modunda da) yeni dosyaya aittir. }
    FKey := Copy(FEng.Store.Key, 0, Length(FEng.Store.Key));
    { v3.1: icerik degismis olabilir (RESTORE/REKEY) -> sayac guvenilmez.
      VACUUM cagirani (Compact) anahtar kumesinin AYNI oldugunu dogrular ve
      bayragi geri kurar. Harita SILINMEZ: bayrak False iken yazma yolu onu
      kirletmez, ilk COUNT isteginde tam taramayla yeniden kurulur. }
    FEng.OnTagSummary := GetTagSummary;
    FTagCountsValid := False;
  except
    { Yarim kalan degistirmede .bak'tan ve ESKI kimlikle don. }
    if FEng = nil then
    begin
      FKey := oldKey;
      FPassword := oldPass;
      FHasPassword := oldHas;
      try
        if FileExists(bak) then
        begin
          if FileExists(FPath) then DeleteFile(FPath);
          RenameFile(bak, FPath);
        end;
        if FileExists(FPath) then
        begin
          FEng := NewEngine(FPath);
          FEng.Open(False);
          FEng.OnTagSummary := GetTagSummary;
          FTagCountsValid := False;
        end;
      except
        FreeAndNil(FEng);
      end;
    end;
  end;
end;

end.
