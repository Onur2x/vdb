program wal_recovery;

{ Sprint C (denetim 4.1 / 4.2) kapisi: WAL-before-data sirasi ve POISONED
  durumu.

  Neden ayri bir kapi: mevcut `wal_crash_matrix` yalnizca WAL dosyasini,
  `crash_points` ise gercek surec olumunu olcer. Ikisi de "fsync edilmemis
  WAL baytlari kayboldu" durumunu TAKLIT ETMEZ; surec olumunde baytlar
  isletim sistemi onbelleginde kalir ve kurtarma onlari okur. Bu yuzden
  checkpoint'in veri sayfalarini WAL durabil olmadan yazmasi (4.1) iki
  kapidan da GECIYORDU.

  Senaryolar:
   WR1 hayalet commit: CommitNoSync + WAL fsync hatasi + Checkpoint(True)
       basarisiz olmali ve satir yeniden acilista GORUNMEMELI.
   WR2 bariyer sirasi: CP_BEFORE_FLUSH aninda Store.DurableLsn >=
       Wal.WrittenLsn (veri yazimindan ONCE WAL durabil).
   WR3 POISONED: kurtarma basarisiz -> okuma/yazma ecInvalidState;
       kapat/ac sonrasi temiz ve yazilabilir.
   WR4 basarili kurtarma: durabil satirlar korunur, fsync'siz satir duser,
       motor POISONED olmaz ve tekrar commit edebilir.
   WR5 POISONED yalniz kurtarma hatasinda: normal commit/checkpoint
       sirasinda poison olusmaz.

  Cikis kodu = FAIL sayisi. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  VDbFactory, VDbBackendApi, VDbBackendV3, VDbPageEngine, VDbPageStore,
  VDbPageWal, VDbErr;

var
  GPass, GFail, GSeq: Integer;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' | ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' | ', ADetail);
  end;
end;

function TestDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp';
  if not DirectoryExists(Result) then
    ForceDirectories(Result);
end;

procedure WipeDir(const ADir: string);
var
  sr: TSearchRec;
  p: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        p := IncludeTrailingPathDelimiter(ADir) + sr.Name;
        if (sr.Attr and faDirectory) <> 0 then
        begin
          WipeDir(p);
          RemoveDir(p);
        end
        else
          SysUtils.DeleteFile(p);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function MkVal(AKey: Integer): TBytes;
var
  s: AnsiString;
begin
  s := 'satir-' + IntToStr(AKey);
  SetLength(Result, Length(s));
  if Length(s) > 0 then
    Move(s[1], Result[0], Length(s));
end;

{ Her vaka temiz bir dizinde kosar; onceki kosunun dosyalari silinir. }
function NewDb(const ATag: string): string;
var
  d: string;
begin
  Inc(GSeq);
  d := TestDir + ATag + '_' + IntToStr(GSeq);
  WipeDir(d);
  ForceDirectories(d);
  Result := IncludeTrailingPathDelimiter(d) + 'veritabani.odb';
end;

procedure CreateBase(const APath: string; ARows: Integer);
var
  Be: IVdbBackend;
  k: Integer;
begin
  VdbOpen(APath, Be, True, False);
  try
    Be.BeginBatch;
    for k := 1 to ARows do
      Be.Put(k, MkVal(k));
    Be.CommitBatch;
  finally
    Be := nil;
  end;
end;

function OpenCount(const APath: string): Integer;
var
  Be: IVdbBackend;
begin
  Result := -1;
  VdbOpen(APath, Be, False, False);
  try
    Result := Be.Count;
  finally
    Be := nil;
  end;
end;

{ Yeniden acilan veritabaninda tek bir anahtarin varligi. }
function OpenHas(const APath: string; AKey: Int64): Boolean;
var
  Be: IVdbBackend;
begin
  Result := True;
  VdbOpen(APath, Be, False, False);
  try
    Result := Be.Exists(AKey);
  finally
    Be := nil;
  end;
end;

{ WR2 ornekleme: CrashPoint duz prosedur kancasi cagirir, bu yuzden motor
  global tutulur. Kanca yalnizca OKUR; istisnayi CrashPoint firlatir. }
var
  GEng: TVdbBackendV3 = nil;
  GSampled: Boolean;
  GSampledDurable, GSampledWritten, GSampledStore: LongWord;

procedure BarrierHook;
begin
  GSampled := True;
  if GEng = nil then Exit;
  { Bariyer kaniti motor duzeyinde olculur: FDurableLsn yalniz WAL fsync
    basarili oldugunda ilerler. Store tarafindaki `.gen` eslemesi yalniz
    Windows'ta kuruldugu icin orada 0 kalir; ayrica raporlanir. }
  GSampledDurable := GEng.Engine.DurableLsn;
  GSampledWritten := GEng.Engine.Wal.WrittenLsn;
  GSampledStore := GEng.Engine.Store.DurableLsn;
end;

{ WR1: fsync edilmemis commit checkpoint ile kalici OLMAMALI. }
procedure WR1_NoGhostCommit;
var
  db: string;
  Eng: TVdbBackendV3;
  lsn: LongWord;
  committed, raised: Boolean;
  cnt: Integer;
begin
  db := NewDb('wr1');
  CreateBase(db, 5);
  Eng := TVdbBackendV3.Create(db, False);
  try
    committed := Eng.Engine.Insert(100, MkVal(100));
    lsn := 0;
    committed := Eng.Engine.CommitNoSync(lsn) and committed;
    Chk('wr1/commit-nosync', committed and (lsn > 0),
      'ok=' + BoolToStr(committed, True) + ' lsn=' + IntToStr(lsn));
    Chk('wr1/mem-visible', Eng.Engine.Contains(100),
      'bellek satiri var=' + BoolToStr(Eng.Engine.Contains(100), True));

    { WAL fsync kanali bozuldu: checkpoint veri sayfalarinin durabil
      olmadigi bir noktada veri yazmamali. }
    Eng.Engine.Wal.DebugSetSyncFault(True);
    raised := False;
    try
      Eng.Engine.Checkpoint(True);
    except
      on E: Exception do
        raised := True;
    end;
    Chk('wr1/checkpoint-fails', raised,
      'istisna=' + BoolToStr(raised, True));
    Eng.Engine.Wal.DebugSetSyncFault(False);

    { Surec olumu: bellekteki kirli sayfalar ve tampon atilir. }
    Eng.Engine.SimulateCrash;
  finally
    Eng.Free;
  end;

  cnt := OpenCount(db);
  Chk('wr1/durable-kept', cnt = 5, 'COUNT=' + IntToStr(cnt));
  Chk('wr1/no-ghost-row', not OpenHas(db, 100),
    'var=' + BoolToStr(OpenHas(db, 100), True));
end;

{ WR2: veri yazimindan ONCE WAL durabil olmali. }
procedure WR2_BarrierBeforeData;
var
  db: string;
  Eng: TVdbBackendV3;
  lsn: LongWord;
  raised: Boolean;
begin
  db := NewDb('wr2');
  CreateBase(db, 5);
  Eng := TVdbBackendV3.Create(db, False);
  GEng := Eng;
  try
    Eng.Engine.Insert(200, MkVal(200));
    lsn := 0;
    if not Eng.Engine.CommitNoSync(lsn) then
      Chk('wr2/commit-nosync', False, 'CommitNoSync False');

    GSampled := False;
    GSampledDurable := 0;
    GSampledWritten := 0;
    GSampledStore := 0;
    Eng.Engine.CrashAtStage := VDB_CRASH_STAGE_CP_BEFORE_FLUSH;
    Eng.Engine.OnCrashPoint := @BarrierHook;
    raised := False;
    try
      Eng.Engine.Checkpoint(True);
    except
      on E: Exception do
        raised := True;
    end;
    Eng.Engine.CrashAtStage := VDB_CRASH_STAGE_NONE;
    Eng.Engine.OnCrashPoint := nil;

    Chk('wr2/hook-fired', GSampled and raised,
      'kanca=' + BoolToStr(GSampled, True) + ' istisna=' +
      BoolToStr(raised, True));
    Chk('wr2/written', GSampledWritten > 0,
      'WrittenLsn=' + IntToStr(GSampledWritten));
    Chk('wr2/wal-durable-before-flush', GSampledDurable >= GSampledWritten,
      'durable=' + IntToStr(GSampledDurable) + ' written=' +
      IntToStr(GSampledWritten) + ' store=' + IntToStr(GSampledStore));
    Eng.Engine.SimulateCrash;
  finally
    GEng := nil;
    Eng.Free;
  end;
  Chk('wr2/reopen', OpenCount(db) >= 5,
    'COUNT=' + IntToStr(OpenCount(db)));
end;

{ WR3: basarisiz kurtarma motoru POISONED yapar; kapat/ac temizler. }
procedure WR3_PoisonedRefusesIO;
var
  db: string;
  Eng: TVdbBackendV3;
  raised, codeOk: Boolean;
  v: TBytes;
  Be: IVdbBackend;
  cnt: Integer;
  wrote: Boolean;
begin
  db := NewDb('wr3');
  CreateBase(db, 3);
  Eng := TVdbBackendV3.Create(db, False);
  try
    Eng.Engine.DebugFailRecovery(True);
    raised := False;
    try
      Eng.Engine.RecoverAfterDurabilityFailure;
    except
      on E: Exception do
        raised := True;
    end;
    Chk('wr3/recovery-fails', raised, 'istisna=' + BoolToStr(raised, True));
    Chk('wr3/poisoned', Eng.Engine.Poisoned,
      'poisoned=' + BoolToStr(Eng.Engine.Poisoned, True));
    Chk('wr3/reason', Eng.Engine.PoisonReason <> '',
      'neden=' + Eng.Engine.PoisonReason);

    { Okuma reddi (backend ve motor seviyesinde). }
    codeOk := False;
    try
      Eng.Get(1, v);
    except
      on E: EVDbException do
        codeOk := E.ErrorCode = ecInvalidState;
    end;
    Chk('wr3/backend-read-rejected', codeOk,
      'ecInvalidState=' + BoolToStr(codeOk, True));

    codeOk := False;
    try
      Eng.Engine.TryGet(1, v);
    except
      on E: EVDbException do
        codeOk := E.ErrorCode = ecInvalidState;
    end;
    Chk('wr3/engine-read-rejected', codeOk,
      'ecInvalidState=' + BoolToStr(codeOk, True));

    { Yazma reddi. }
    codeOk := False;
    try
      Eng.Put(50, MkVal(50));
    except
      on E: EVDbException do
        codeOk := E.ErrorCode = ecInvalidState;
    end;
    Chk('wr3/write-rejected', codeOk,
      'ecInvalidState=' + BoolToStr(codeOk, True));
  finally
    Eng.Free;
  end;

  { Kapat/ac: yeni oturum temiz bir motor kurar. }
  VdbOpen(db, Be, False, False);
  try
    cnt := Be.Count;
    Chk('wr3/reopen-clean', cnt = 3, 'COUNT=' + IntToStr(cnt));
    wrote := False;
    try
      Be.BeginBatch;
      Be.Put(60, MkVal(60));
      Be.CommitBatch;
      wrote := True;
    except
      on E: Exception do
        WriteLn('BILGI wr3 yeniden yazma hatasi: ', E.ClassName, ': ',
          E.Message);
    end;
    Chk('wr3/reopen-writable', wrote,
      'yazdi=' + BoolToStr(wrote, True));
  finally
    Be := nil;
  end;
end;

{ WR4: basarili kurtarma motora geri doner. }
procedure WR4_SuccessfulRecovery;
var
  db: string;
  Eng: TVdbBackendV3;
  lsn: LongWord;
  raised, ok: Boolean;
begin
  db := NewDb('wr4');
  CreateBase(db, 3);
  Eng := TVdbBackendV3.Create(db, False);
  try
    Eng.Engine.Insert(50, MkVal(50));
    lsn := 0;
    Eng.Engine.CommitNoSync(lsn);

    { fsync basarisiz: durabil olmayan commit geri kirpilir. }
    Eng.Engine.Wal.DebugSetSyncFault(True);
    raised := False;
    try
      Eng.Engine.AwaitDurable(lsn);
    except
      on E: Exception do
        raised := True;
    end;
    Chk('wr4/fsync-fails', raised, 'istisna=' + BoolToStr(raised, True));
    Eng.Engine.Wal.DebugSetSyncFault(False);

    { Kurtarma basarili olmali. }
    ok := True;
    try
      Eng.Engine.RecoverAfterDurabilityFailure;
    except
      on E: Exception do
      begin
        ok := False;
        WriteLn('BILGI wr4 kurtarma hatasi: ', E.ClassName, ': ', E.Message);
      end;
    end;
    Chk('wr4/recovery-ok', ok, 'ok=' + BoolToStr(ok, True));
    Chk('wr4/not-poisoned', not Eng.Engine.Poisoned,
      'poisoned=' + BoolToStr(Eng.Engine.Poisoned, True));
    Chk('wr4/durable-kept', Eng.Engine.Contains(1),
      'var=' + BoolToStr(Eng.Engine.Contains(1), True));
    Chk('wr4/unsynced-dropped', not Eng.Engine.Contains(50),
      'var=' + BoolToStr(Eng.Engine.Contains(50), True));

    { Kurtarma sonrasi motor yeniden commit edebilmeli (fsync dahil). }
    ok := False;
    try
      Eng.BeginBatch;
      Eng.Put(60, MkVal(60));
      Eng.CommitBatch;
      ok := True;
    except
      on E: Exception do
        WriteLn('BILGI wr4 yeniden commit hatasi: ', E.ClassName, ': ',
          E.Message);
    end;
    Chk('wr4/writable-after-recovery', ok,
      'ok=' + BoolToStr(ok, True));
  finally
    Eng.Free;
  end;
  Chk('wr4/reopen-count', OpenCount(db) = 4,
    'COUNT=' + IntToStr(OpenCount(db)));
end;

{ WR5: normal commit/checkpoint POISONED uretmemeli. }
procedure WR5_NormalPathNotPoisoned;
var
  db: string;
  Eng: TVdbBackendV3;
  k: Integer;
  ok: Boolean;
begin
  db := NewDb('wr5');
  CreateBase(db, 2);
  Eng := TVdbBackendV3.Create(db, False);
  try
    ok := True;
    try
      for k := 1 to 3 do
      begin
        Eng.BeginBatch;
        Eng.Put(100 + k, MkVal(100 + k));
        Eng.CommitBatch;
      end;
      Eng.Engine.Checkpoint(True);
    except
      on E: Exception do
      begin
        ok := False;
        WriteLn('BILGI wr5 normal yol hatasi: ', E.ClassName, ': ', E.Message);
      end;
    end;
    Chk('wr5/not-poisoned', not Eng.Engine.Poisoned,
      'poisoned=' + BoolToStr(Eng.Engine.Poisoned, True));
    Chk('wr5/count', Eng.Engine.Count = 5,
      'COUNT=' + IntToStr(Eng.Engine.Count));
    Chk('wr5/ok', ok, 'ok=' + BoolToStr(ok, True));
  finally
    Eng.Free;
  end;
end;

begin
  GPass := 0;
  GFail := 0;
  GSeq := 0;
  WriteLn('VDB WAL durabilite + kurtarma kapisi (Sprint C)');
  try
    WR1_NoGhostCommit;
    WR2_BarrierBeforeData;
    WR3_PoisonedRefusesIO;
    WR4_SuccessfulRecovery;
    WR5_NormalPathNotPoisoned;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL beklenmeyen hata: ', E.ClassName, ': ', E.Message);
    end;
  end;

  WriteLn('');
  WriteLn('SONUC: ', IntToStr(GPass), ' PASS, ', IntToStr(GFail), ' FAIL');
  if GFail = 0 then
    Halt(0)
  else
    Halt(1);
end.
