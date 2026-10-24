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
  VDbSync;

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
    var
      FEng: TVdbPageEngine;
      FPath: string;
      FBatch: TDictionary<QWord, TBatchRec>;
      FBatchOpen: Boolean;
      FRowTag: TVDbRowTagFunc;
      FBeforeCommit: TDbCommitHook;
      FCheckpointBytes: Int64;
      FDirty: Boolean;
      FPoolPages: Integer;
      FScanKeys: TQWordArray;
      FScanVals: TValArray;
      FScanN: Integer;
      FScanFilter: Integer;
      FCompactEng: TVdbPageEngine;
      FCompactN: Int64;
    procedure ApplyBatch;
    function EffectiveCount: Integer;
    procedure MaybeCheckpoint;
    function PassFilter(Key: QWord; const Value: TBytes;
      TableFilter: Integer): Boolean;
    procedure ScanCb(Key: QWord; const Value: TBytes);
    { Sprint 3.3: VACUUM/Compact yardimcilari. }
    procedure CompactCb(Key: QWord; const Value: TBytes);
    procedure SwapDbFile(const NewFilePath: string);
  public
    { ADbPath: .odb dosya yolu. ACreate=True ise yoksa olusturur. }
    constructor Create(const ADbPath: string; ACreate: Boolean = True;
      APoolPages: Integer = VDB_DEF_POOL);
    destructor Destroy; override;

    property Engine: TVdbPageEngine read FEng;
    { Checkpoint esigi (bayt). 0 = yalnizca kapanis/Flush'ta. }
    property CheckpointBytes: Int64 read FCheckpointBytes write FCheckpointBytes;

    procedure Put(Key: QWord; const Value: TBytes);
    function Get(Key: QWord; out Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    function Exists(Key: QWord): Boolean;
    function Count: Integer;

    procedure ScanAll(out Keys: TQWordArray; out Vals: TValArray;
      TableFilter: Integer = -1);
    function ScanRawIterAll(TableFilter: Integer;
      Cb: TVDbRawCb; User: Pointer): Boolean;

    procedure BeginBatch;
    procedure CommitBatch;
    procedure AbortBatch;
    procedure Flush;
    function GetInBatch: Boolean;

    function EnsureColumnKey: QWord;
    function ColumnKeyId: QWord;
    function ColumnKeyPath: string;
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

constructor TVdbBackendV3.Create(const ADbPath: string; ACreate: Boolean;
  APoolPages: Integer);
begin
  inherited Create;
  FPath := ADbPath;
  FBatch := TDictionary<QWord, TBatchRec>.Create;
  FBatchOpen := False;
  FDirty := False;
  FCheckpointBytes := VDB_V3_CHECKPOINT_BYTES;
  FPoolPages := APoolPages;
  FEng := TVdbPageEngine.Create(ADbPath, APoolPages);
  try
    FEng.Open(ACreate);
  except
    FreeAndNil(FEng);
    raise;
  end;
end;

destructor TVdbBackendV3.Destroy;
begin
  if FBatchOpen then
  begin
    { Kapanista yarim islem yazilmaz: kaplama atilir. }
    FBatch.Clear;
    FBatchOpen := False;
  end;
  FreeAndNil(FEng);       // Close: commit + checkpoint + idx
  FreeAndNil(FBatch);
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
  if FBatchOpen then
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
  pair: TPair<QWord, TBatchRec>;
  ok: Boolean;
begin
  if FBatch.Count = 0 then Exit;
  for pair in FBatch do
  begin
    if pair.Value.Present then
    begin
      if FEng.Contains(pair.Key) then
        ok := FEng.Update(pair.Key, pair.Value.Value)
      else
        ok := FEng.Insert(pair.Key, pair.Value.Value);
      if not ok then
        raise EVdbBackendV3.Create(Format(
          'toplu yazim basarisiz: anahtar $%.16x', [pair.Key]));
    end
    else
      FEng.Delete(pair.Key);    // yoksa da zararsiz
  end;
  FBatch.Clear;
  FDirty := True;
end;

{ ------------------------------------------------------------------ kayit }

procedure TVdbBackendV3.Put(Key: QWord; const Value: TBytes);
var
  rec: TBatchRec;
begin
  if FBatchOpen then
  begin
    rec.Present := True;
    rec.Value := Copy(Value, 0, Length(Value));
    FBatch.AddOrSetValue(Key, rec);
    Exit;
  end;
  if FEng.Contains(Key) then
  begin
    if not FEng.Update(Key, Value) then
      raise EVdbBackendV3.Create('guncelleme basarisiz');
  end
  else if not FEng.Insert(Key, Value) then
    raise EVdbBackendV3.Create('ekleme basarisiz');
  FDirty := True;
end;

function TVdbBackendV3.Get(Key: QWord; out Value: TBytes): Boolean;
var
  rec: TBatchRec;
begin
  if FBatchOpen and FBatch.TryGetValue(Key, rec) then
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
begin
  if FBatchOpen then
  begin
    rec.Present := False;
    rec.Value := nil;
    FBatch.AddOrSetValue(Key, rec);
    Exit(FEng.Contains(Key) or (FBatch.ContainsKey(Key)));
  end;
  Result := FEng.Delete(Key);
  if Result then
    FDirty := True;
end;

function TVdbBackendV3.Exists(Key: QWord): Boolean;
begin
  if FBatchOpen and FBatch.ContainsKey(Key) then
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
  if FBatchOpen and FBatch.ContainsKey(Key) then Exit;
  if not PassFilter(Key, Value, FScanFilter) then Exit;
  SetLength(FScanKeys, FScanN + 1);
  SetLength(FScanVals, FScanN + 1);
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
  FScanFilter := TableFilter;

  { Motor tarafi: kaplamada islem gormus anahtarlar atlanir. }
  FEng.ScanAll(ScanCb);

  { Kaplama tarafi: en guncel deger. }
  if FBatchOpen then
    for pair in FBatch do
    begin
      if not pair.Value.Present then Continue;
      if not PassFilter(pair.Key, pair.Value.Value, TableFilter) then Continue;
      SetLength(FScanKeys, FScanN + 1);
      SetLength(FScanVals, FScanN + 1);
      FScanKeys[FScanN] := pair.Key;
      FScanVals[FScanN] := Copy(pair.Value.Value, 0, Length(pair.Value.Value));
      Inc(FScanN);
    end;

  Keys := FScanKeys;
  Vals := FScanVals;
  FScanKeys := nil;
  FScanVals := nil;
  FScanN := 0;
end;

function TVdbBackendV3.ScanRawIterAll(TableFilter: Integer;
  Cb: TVDbRawCb; User: Pointer): Boolean;
var
  keys: TQWordArray;
  vals: TValArray;
  i: Integer;
begin
  { Sifir-kopya yol v3'te henuz yok (sayfa ici hucre dogrudan verilemez,
    cunku deger tasma zincirinde parcali olabilir). Bellek maliyeti icin
    tarama basina bir kez toplanir. }
  ScanAll(keys, vals, TableFilter);
  Result := True;
  for i := 0 to High(keys) do
    if Length(vals[i]) > 0 then
    begin
      if not Cb(keys[i], @vals[i][0], Length(vals[i]), User) then
        Exit(False);
    end
    else if not Cb(keys[i], nil, 0, User) then
      Exit(False);
end;

{ ------------------------------------------------------------------ islem }

procedure TVdbBackendV3.BeginBatch;
begin
  if FBatchOpen then Exit;
  FBatch.Clear;
  FBatchOpen := True;
end;

procedure TVdbBackendV3.CommitBatch;
begin
  if not FBatchOpen then Exit;
  if Assigned(FBeforeCommit) then
    FBeforeCommit;          // kisit denetimi: hata firlatirsa kaplama durur
  ApplyBatch;
  FBatchOpen := False;
  FBatch.Clear;
  if FDirty then
  begin
    FEng.Commit(True);
    FDirty := False;
    MaybeCheckpoint;
  end;
end;

procedure TVdbBackendV3.AbortBatch;
begin
  FBatch.Clear;
  FBatchOpen := False;
end;

procedure TVdbBackendV3.Flush;
begin
  if FBatchOpen then Exit;
  if FDirty then
  begin
    FEng.Commit(True);
    FDirty := False;
  end;
  FEng.Checkpoint(True);
end;

function TVdbBackendV3.GetInBatch: Boolean;
begin
  Result := FBatchOpen;
end;

{ ------------------------------------------------------ sema / sifreleme }

function TVdbBackendV3.ColumnKeyPath: string;
begin
  Result := ChangeFileExt(FPath, '.colkey');
end;

function TVdbBackendV3.EnsureColumnKey: QWord;
var
  f: TFileStream;
  key: TBytes;
  id: QWord;
begin
  { v3.0'da kolon sifreleme henuz yok; anahtar dosyasi bicimi v2 ile ayni
    kalsin diye rastgele 32 bayt + kimlik yazilir. Kullanim Sprint 3.4'te. }
  if FileExists(ColumnKeyPath) then
  begin
    f := TFileStream.Create(ColumnKeyPath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(key, 40);
      if f.Size >= 40 then
      begin
        f.ReadBuffer(key[0], 40);
        Move(key[32], id, 8);
        Exit(id);
      end;
    finally
      f.Free;
    end;
    Exit(0);
  end;
  SetLength(key, 40);
  Randomize;
  id := (QWord(Random(MaxInt)) shl 33) xor QWord(Random(MaxInt)) xor
    (QWord(GetTickCount64) shl 7);
  Move(id, key[32], 8);
  f := TFileStream.Create(ColumnKeyPath, fmCreate);
  try
    f.WriteBuffer(key[0], 40);
  finally
    f.Free;
  end;
  Result := id;
end;

function TVdbBackendV3.ColumnKeyId: QWord;
var
  f: TFileStream;
  buf: TBytes;
begin
  Result := 0;
  if not FileExists(ColumnKeyPath) then Exit;
  f := TFileStream.Create(ColumnKeyPath, fmOpenRead or fmShareDenyNone);
  try
    if f.Size < 40 then Exit;
    SetLength(buf, 40);
    f.ReadBuffer(buf[0], 40);
    Move(buf[32], Result, 8);
  finally
    f.Free;
  end;
end;

procedure TVdbBackendV3.SetBeforeCommit(Proc: TDbCommitHook);
begin
  FBeforeCommit := Proc;
end;

procedure TVdbBackendV3.SetRowTagFunc(AValue: TVDbRowTagFunc);
begin
  FRowTag := AValue;
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
  hdr: array[0..15] of Byte;
  magic, ver: LongWord;
begin
  if FBatchOpen then
    raise EVdbBackendV3.Create('acik parti varken geri yukleme yapilamaz');
  if not FileExists(SrcPath) then
    raise EVdbBackendV3.Create('RESTORE: yedek dosyasi bulunamadi: ' + SrcPath);
  if SameFileName(ExpandFileName(SrcPath), ExpandFileName(FPath)) then
    raise EVdbBackendV3.Create('RESTORE: kaynak ile hedef ayni dosya');
  src := TFileStream.Create(SrcPath, fmOpenRead or fmShareDenyNone);
  try
    if src.Size < 32 then
      raise EVdbBackendV3.Create('RESTORE: kaynak dosya cok kisa');
    src.ReadBuffer(hdr, SizeOf(hdr));
  finally
    src.Free;
  end;
  Move(hdr[0], magic, SizeOf(magic));
  Move(hdr[4], ver, SizeOf(ver));
  if (magic <> VDB_FILE_MAGIC) or (ver <> VDB_FILE_VER) then
    raise EVdbBackendV3.Create('RESTORE: kaynak v3 sayfa motoru dosyasi degil');

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
  fs: TFileStream;
begin
  if FBatchOpen then
    raise EVdbBackendV3.Create('acik parti varken VACUUM yapilamaz');
  if FDirty then
  begin
    FEng.Commit(True);
    FDirty := False;
  end;
  FEng.Checkpoint(True);
  fs := TFileStream.Create(FPath, fmOpenRead or fmShareDenyNone);
  try
    OldBytes := fs.Size;
  finally
    fs.Free;
  end;

  tmp := FPath + '.compact.tmp';
  if FileExists(tmp) then DeleteFile(tmp);
  newEng := TVdbPageEngine.Create(tmp, FPoolPages);
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
  if FCompactN <> FEng.Count then
  begin
    if FileExists(tmp) then DeleteFile(tmp);
    raise EVdbBackendV3.Create(Format(
      'VACUUM: anahtar sayisi tutmuyor (yazilan %d, kaynak %d)',
      [FCompactN, FEng.Count]));
  end;

  SwapDbFile(tmp);
  fs := TFileStream.Create(FPath, fmOpenRead or fmShareDenyNone);
  try
    NewBytes := fs.Size;
  finally
    fs.Free;
  end;
end;

procedure TVdbBackendV3.SwapDbFile(const NewFilePath: string);
var
  bak, wal, idx: string;
begin
  bak := FPath + '.bak';
  wal := FPath + '.wal';
  idx := FPath + '.idx';
  FreeAndNil(FEng);
  FEng := nil;
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
    FEng := TVdbPageEngine.Create(FPath, FPoolPages);
    try
      FEng.Open(False);
    except
      FreeAndNil(FEng);
      raise;
    end;
  except
    { Yarim kalan degistirmede .bak'tan don. }
    if FEng = nil then
    begin
      try
        if FileExists(bak) then
        begin
          if FileExists(FPath) then DeleteFile(FPath);
          RenameFile(bak, FPath);
        end;
        if FileExists(FPath) then
        begin
          FEng := TVdbPageEngine.Create(FPath, FPoolPages);
          FEng.Open(False);
        end;
      except
        FreeAndNil(FEng);
      end;
    end;
    raise;
  end;
end;

end.
