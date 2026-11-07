program commitfailchk;

{ VDB v3 - R2-C-2 / R2-C-3 (kalan) kapisi.

  Denetlenenler:
    1) GRUP COMMIT fsync hatasi: Commit(False) ile yazilmis kayitlar
       SyncDurable hatasinda geri kirpilir -> kurtarmada HAYALET COMMIT yok.
    2) FWrittenLsn yalniz ILERI gider (R2-C-YENI-1): geri kirpma sonrasi
       degeri dusurulmez; eszamanli bekleyen erken cikip basarili sanmaz.
    3) Commit(DoSync=True) fsync hatasi: bu commit'in bolumu geri kirpilir.
    4) Backend CommitBatch ikincil fsync hatasi: hata YUTULMAZ; istisna
       yukari cikar ve GetLastCommitProblem dolu olur (R2-C-2).

  Cikis kodu: 0 = hepsi gecti; 1 = hata.
  Kullanim: commitfailchk <calisma_dizini>
}

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbBackendApi, VDbCore, VDbBackendV3, VDbPageEngine,
  VDbPage, VDbPageWal;

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

procedure Chk(const Name: string; Cond: Boolean);
begin
  if Cond then Ok(Name) else Fail(Name);
end;

function DirOf(const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(gDir) + Name;
end;

function FileBytesOf(const APath: string): Int64;
var
  F: TFileStream;
begin
  if not FileExists(APath) then Exit(0);
  F := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := F.Size;
  finally
    F.Free;
  end;
end;

procedure ZeroPage(out P: TVDbPageBuf);
begin
  FillChar(P, SizeOf(P), 0);
  { Gercek sayfa imaji: AppendFrame LSN damgasini yalniz VP imajina yazar. }
  PageHdr(PVdbPage(@P))^.Magic := VDB_PAGE_MAGIC;
end;

{ 1-2) Grup commit: Commit(False) x2 -> fsync hatasi -> tam geri kirpma. }
procedure TestGroupCommitRollback;
const
  WAL_NAME = 'r2c3_group.wal';
var
  path: string;
  wal: TVdbPageWal;
  p: TVDbPageBuf;
  st: TVdbWalStats;
  raised: Boolean;
  szBefore: Int64;
begin
  WriteLn('--- R2-C-3: grup commit fsync hatasinda geri kirpma');
  path := DirOf(WAL_NAME);
  if FileExists(path) then DeleteFile(path);
  wal := TVdbPageWal.Create(path);
  try
    wal.Open(False);
    ZeroPage(p);
    wal.AppendFrame(1, @p, 10);
    Chk('grup: ilk Commit(False) basarili', wal.Commit(False, 10));
    ZeroPage(p);
    wal.AppendFrame(2, @p, 11);
    Chk('grup: ikinci Commit(False) basarili', wal.Commit(False, 11));
    szBefore := FileBytesOf(path);
    Chk('grup: kayitlar diske yazildi', szBefore > VDB_PAGE_SIZE);

    wal.DebugSetSyncFault(True);
    raised := False;
    try
      wal.SyncDurable;
    except
      on E: EVdbWal do raised := True;
    end;
    Chk('grup: fsync hatasi yukari cikti', raised);
    Chk('grup: dosya basliga geri kirpildi',
      FileBytesOf(path) = VDB_PAGE_SIZE);
    Chk('grup: FWrittenLsn geri cekilmedi (yalniz ileri)',
      wal.WrittenLsn >= 11);

    wal.DebugSetSyncFault(False);
    FillChar(st, SizeOf(st), 0);
    wal.Recover(nil, st);
    Chk('grup: kurtarmada HAYALET COMMIT yok', st.Commits = 0);
    Chk('grup: kurtarmada cerceve yok', st.Frames = 0);
    Chk('grup: kesik kuyruk isaretlenmedi', not st.TornTail);

    { Ayni WAL nesnesi sonraki commit'lerde normal calismali. }
    ZeroPage(p);
    wal.AppendFrame(3, @p, 12);
    Chk('grup: sonraki Commit(False) basarili', wal.Commit(False, 12));
    wal.SyncDurable;
    FillChar(st, SizeOf(st), 0);
    wal.Recover(nil, st);
    Chk('grup: sonraki commit durabil ve kurtarilabilir',
      (st.Commits = 1) and (st.Frames = 1));
  finally
    wal.Free;
  end;
  if FileExists(path) then DeleteFile(path);
end;

{ 3) Commit(DoSync=True): fsync hatasinda bu commit geri kirpilir. }
procedure TestSingleCommitRollback;
const
  WAL_NAME = 'r2c3_single.wal';
var
  path: string;
  wal: TVdbPageWal;
  p: TVDbPageBuf;
  st: TVdbWalStats;
  raised: Boolean;
  sz0: Int64;
begin
  WriteLn('--- R2-C-3: Commit(True) fsync hatasinda geri kirpma');
  path := DirOf(WAL_NAME);
  if FileExists(path) then DeleteFile(path);
  wal := TVdbPageWal.Create(path);
  try
    wal.Open(False);
    sz0 := FileBytesOf(path);
    ZeroPage(p);
    wal.AppendFrame(1, @p, 20);
    wal.DebugSetSyncFault(True);
    raised := False;
    try
      wal.Commit(True, 20);
    except
      on E: EVdbWal do raised := True;
    end;
    Chk('tek: fsync hatasi yukari cikti', raised);
    Chk('tek: dosya onceki boyuta dondu', FileBytesOf(path) = sz0);
    Chk('tek: FWrittenLsn artmadi', wal.WrittenLsn = 0);

    wal.DebugSetSyncFault(False);
    ZeroPage(p);
    wal.AppendFrame(1, @p, 21);
    Chk('tek: sonraki Commit(True) basarili', wal.Commit(True, 21));
    Chk('tek: FWrittenLsn ilerledi', wal.WrittenLsn = 21);
    FillChar(st, SizeOf(st), 0);
    wal.Recover(nil, st);
    Chk('tek: commit kurtarilabilir', (st.Commits = 1) and (st.Frames = 1));
  finally
    wal.Free;
  end;
  if FileExists(path) then DeleteFile(path);
end;

{ 4) Backend: ikincil fsync hatasi yutulmaz (R2-C-2). }
procedure TestBackendSecondaryError;
const
  DB_NAME = 'r2c2_secondary.odb';
var
  path: string;
  be: TVdbBackendV3;
  v: TBytes;
  raised: Boolean;
  cp: string;
begin
  WriteLn('--- R2-C-2: backend CommitBatch ikincil fsync hatasi');
  path := DirOf(DB_NAME);
  if FileExists(path) then DeleteFile(path);
  if FileExists(path + '.wal') then DeleteFile(path + '.wal');
  be := TVdbBackendV3.Create(path, True, 64);
  try
    SetLength(v, 8);
    v[0] := 1; v[1] := 2; v[2] := 3; v[3] := 4;
    be.BeginBatch;
    be.Put(QWord(1), v);
    be.CommitBatch;
    Chk('backend: temel commit basarili', be.Get(QWord(1), v));

    { WAL fsync kanalini hataya zorla: CommitNoSync yazar, AwaitDurable
      patlar. Hata YUTULMAMALI. }
    be.Engine.Wal.DebugSetSyncFault(True);
    raised := False;
    try
      be.BeginBatch;
      be.Put(QWord(2), v);
      be.CommitBatch;
    except
      on E: Exception do
      begin
        raised := True;
        if Pos('fsync', LowerCase(E.Message)) < 0 then
          Fail('backend: istisna metninde fsync yok: ' + E.Message);
      end;
    end;
    Chk('backend: ikincil fsync hatasi yukari cikti', raised);
    cp := LowerCase(be.GetLastCommitProblem);
    Chk('backend: GetLastCommitProblem dolu', cp <> '');
    Chk('backend: GetLastCommitProblem durabilite hatasini tasiyor',
      Pos('durabilite', cp) > 0);
  finally
    try
      be.Engine.Wal.DebugSetSyncFault(False);
    except
    end;
    be.Free;
  end;
  if FileExists(path) then DeleteFile(path);
  if FileExists(path + '.wal') then DeleteFile(path + '.wal');
end;

begin
  gPass := 0;
  gFail := 0;
  if ParamCount < 1 then
  begin
    WriteLn('kullanim: commitfailchk <calisma_dizini>');
    Halt(2);
  end;
  gDir := ParamStr(1);
  if not DirectoryExists(gDir) then
    ForceDirectories(gDir);
  WriteLn('VDB v3 commitfailchk - R2-C-2 / R2-C-3 kapisi');
  try
    TestGroupCommitRollback;
    TestSingleCommitRollback;
    TestBackendSecondaryError;
  except
    on E: Exception do
    begin
      WriteLn('BEKLENMEYEN ISTISNA: ', E.ClassName, ': ', E.Message);
      Inc(gFail);
    end;
  end;
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail > 0 then
    Halt(1);
  WriteLn('COMMIT HATA YOLLARI DOGRULANDI');
end.
