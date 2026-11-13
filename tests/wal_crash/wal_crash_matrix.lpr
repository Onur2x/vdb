program wal_crash_matrix;

{ PHASE-2 kalici kapi: sayfa WAL (VDbPageWal) crash matrisi.

  Neden: skill 4.1/4.2 WAL ve kurtarma invariantlarinin TEST ile
  kanitlanmasini ister. Bu kosucu gercek .wal dosyalari uzerinde
  calisir; her senaryo onceki commit'lerin korundugunu, commit'siz
  kuyrugun atildigini ve bozuk kuyrukta duruldugunu dogrular.

  Senaryolar:
   T1  commit edilmis cerceveler uygulanir; commit'siz kuyruk atilir
   T2  kesik kayit (yarim baslik) -> TornTail, onceki commit uygulanir
   T3  CRC bozulmasi -> orada durur
   T4  bozuk magic -> orada durur
   T5  gecersiz PayloadLen -> orada durur
   T6  kurtarma idempotent (iki Recover ayni sonuc)
   T7  ayni sayfa icin son commit kazanir
   T8  meta sayfa (0) EN SON uygulanir
   T9  fsync hatasi: commit basarisiz + hayalet commit KALMAZ
   T10 guvenli olmayan budama REDDEDILIR
   T11 guvenli budama: govde silinir, HasContent=False, HeaderLsn
   T12 farkli veritabani kimligi ile Open -> EVdbWal
   T13 CommitCount dogru

  Cikis kodu = FAIL sayisi. }

{$mode delphi}{$H+}

uses
  SysUtils, Classes, VDbPage, VDbPageWal;

const
  REC_HDR = 20;

var
  GPass, GFail: Integer;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' - ', ADetail);
  end;
end;

{ ------------------------------- yardimcilar ------------------------------- }

type
  TCollector = class
  public
    Order: array of LongWord;
    Marker: array of Byte;
    N: Integer;
    procedure Apply(PageNo: LongWord; P: PVdbPage);
  end;

procedure TCollector.Apply(PageNo: LongWord; P: PVdbPage);
begin
  if N >= Length(Order) then
  begin
    SetLength(Order, N + 16);
    SetLength(Marker, N + 16);
  end;
  Order[N] := PageNo;
  Marker[N] := P^[VDB_PAGE_HDR];
  Inc(N);
end;

function TestDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp';
  if not DirectoryExists(Result) then
    ForceDirectories(Result);
end;

function TestDbId(ASeed: Byte): TBytes;
var
  i: Integer;
begin
  SetLength(Result, 16);
  for i := 0 to 15 do
    Result[i] := Byte((ASeed + i * 7) and $FF);
end;

procedure MakePage(var P: TVDbPageBuf; APageNo: LongWord; AMarker: Byte);
begin
  FillChar(P, SizeOf(P), 0);
  PageInit(PVdbPage(@P[0]), APageNo, VDB_PAGE_HEAP);
  P[VDB_PAGE_HDR] := AMarker;
end;

function NewWal(const APath: string; const AId: TBytes): TVdbPageWal;
begin
  Result := TVdbPageWal.Create(APath);
  Result.SetDatabaseId(AId);
  if FileExists(APath) then
    DeleteFile(APath);
  Result.Open(False);
end;

function OpenExistingWal(const APath: string; const AId: TBytes): TVdbPageWal;
begin
  Result := TVdbPageWal.Create(APath);
  Result.SetDatabaseId(AId);
  Result.Open(False);
end;

procedure PatchFile(const AFile: string; AOffset: Int64;
  const ABytes: array of Byte);
var
  S: TFileStream;
begin
  S := TFileStream.Create(AFile, fmOpenReadWrite or fmShareDenyNone);
  try
    S.Position := AOffset;
    S.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    S.Free;
  end;
end;

procedure AppendJunk(const AFile: string; const ABytes: array of Byte);
var
  S: TFileStream;
begin
  S := TFileStream.Create(AFile, fmOpenReadWrite or fmShareDenyNone);
  try
    S.Seek(0, soEnd);
    S.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    S.Free;
  end;
end;

function FileSizeOf(const AFile: string): Int64;
var
  S: TFileStream;
begin
  S := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    Result := S.Size;
  finally
    S.Free;
  end;
end;

procedure ShrinkFile(const AFile: string; ANewSize: Int64);
var
  S: TFileStream;
begin
  S := TFileStream.Create(AFile, fmOpenReadWrite or fmShareDenyNone);
  try
    S.Size := ANewSize;
  finally
    S.Free;
  end;
end;

{ Bir commit grubu yazar: cerceveler + commit kaydi tek tamponda gider. }
procedure WriteCommit(W: TVdbPageWal; const APages: array of LongWord;
  const AMarkers: array of Byte; ALsn: LongWord);
var
  i: Integer;
  p: TVdbPageBuf;
begin
  for i := 0 to High(APages) do
  begin
    MakePage(p, APages[i], AMarkers[i]);
    W.AppendFrame(APages[i], PVdbPage(@p[0]), ALsn);
  end;
  W.Commit(True, ALsn);
end;

{ --------------------------------- T1 ------------------------------------- }

procedure T1_CommittedOnly;
var
  path: string;
  id: TBytes;
  W: TVdbPageWal;
  C: TCollector;
  st: TVdbWalStats;
begin
  path := TestDir + 'wal_t1.wal';
  id := TestDbId(1);
  W := NewWal(path, id);
  try
    WriteCommit(W, [7], [$11], 1);
    Chk('t1/written-lsn', W.WrittenLsn = 1,
      'WrittenLsn=' + IntToStr(W.WrittenLsn));
  finally
    W.Free;
  end;

  W := OpenExistingWal(path, id);
  C := TCollector.Create;
  try
    if not W.Recover(C.Apply, st) then
    begin
      Chk('t1/recover-ok', False, 'Recover False dondu');
      Exit;
    end;
    Chk('t1/recover-ok', True, '');
    Chk('t1/frames', st.Frames = 1, 'Frames=' + IntToStr(st.Frames));
    Chk('t1/commits', st.Commits = 1, 'Commits=' + IntToStr(st.Commits));
    Chk('t1/not-torn', not st.TornTail, 'TornTail beklenmiyordu');
    Chk('t1/applied-order', (C.N = 1) and (C.Order[0] = 7),
      'N=' + IntToStr(C.N));
    Chk('t1/applied-content', (C.N = 1) and (C.Marker[0] = $11),
      'marker=' + IntToHex(C.Marker[0], 2));
    Chk('t1/commitcount', W.CommitCount = 1,
      'CommitCount=' + IntToStr(W.CommitCount));
  finally
    C.Free;
    W.Free;
  end;
end;

{ ------------------- T1b: commit'siz kuyruk atilir ------------------------ }

procedure T1b_UncommittedTailDropped;
var
  path: string;
  id: TBytes;
  W: TVdbPageWal;
  C: TCollector;
  st: TVdbWalStats;
begin
  path := TestDir + 'wal_t1b.wal';
  id := TestDbId(1);
  W := NewWal(path, id);
  try
    WriteCommit(W, [7], [$11], 1);
    WriteCommit(W, [8], [$22], 2);
  finally
    W.Free;
  end;
  { Son commit kaydinin (20 bayt) silinmesi: 8 numarali cerceve dosyada
    kaliyor ama onaylanmiyor. Gercek crash senaryosu budur. }
  ShrinkFile(path, FileSizeOf(path) - REC_HDR);

  W := OpenExistingWal(path, id);
  C := TCollector.Create;
  try
    W.Recover(C.Apply, st);
    Chk('t1b/frames', st.Frames = 1, 'Frames=' + IntToStr(st.Frames));
    Chk('t1b/commits', st.Commits = 1, 'Commits=' + IntToStr(st.Commits));
    { Kayit sinirinda biten dosya "kesik" DEGILDIR: cerceve tam, commit
      yok -> beklemedeki kume atilir. TornTail yalniz yarim kayitta. }
    Chk('t1b/clean-eof', not st.TornTail,
      'kayit sinirindaki EOF TornTail uretmemeli');
    Chk('t1b/page7-only', (C.N = 1) and (C.Order[0] = 7),
      'N=' + IntToStr(C.N));
  finally
    C.Free;
    W.Free;
  end;
end;

{ --------------------------------- T2 ------------------------------------- }

procedure T2_TornTail;
var
  path: string;
  id: TBytes;
  W: TVdbPageWal;
  C: TCollector;
  st: TVdbWalStats;
  junk: array[0..6] of Byte;
begin
  path := TestDir + 'wal_t2.wal';
  id := TestDbId(2);
  W := NewWal(path, id);
  try
    WriteCommit(W, [7], [$11], 1);
  finally
    W.Free;
  end;
  FillChar(junk, SizeOf(junk), $AB);
  AppendJunk(path, junk);

  W := OpenExistingWal(path, id);
  C := TCollector.Create;
  try
    W.Recover(C.Apply, st);
    Chk('t2/torn', st.TornTail, 'yarim baslik TornTail uretmedi');
    Chk('t2/frames', st.Frames = 1, 'Frames=' + IntToStr(st.Frames));
    Chk('t2/commits', st.Commits = 1, 'Commits=' + IntToStr(st.Commits));
    Chk('t2/applied', (C.N = 1) and (C.Order[0] = 7),
      'N=' + IntToStr(C.N));
  finally
    C.Free;
    W.Free;
  end;
end;

{ --------------------------- bozulma senaryolari -------------------------- }

{ Ortak: tek commit yaz, ilk kaydin basligini boz, kurtarmada DUR. }
function CorruptionCase(const AName: string; AOffset: Int64;
  const ABytes: array of Byte): Boolean;
var
  path: string;
  id: TBytes;
  W: TVdbPageWal;
  C: TCollector;
  st: TVdbWalStats;
begin
  path := TestDir + 'wal_' + AName + '.wal';
  id := TestDbId(3);
  W := NewWal(path, id);
  try
    WriteCommit(W, [7], [$11], 1);
  finally
    W.Free;
  end;
  PatchFile(path, VDB_PAGE_SIZE + AOffset, ABytes);

  W := OpenExistingWal(path, id);
  C := TCollector.Create;
  try
    W.Recover(C.Apply, st);
    Result := st.TornTail and (st.Frames = 0) and (st.Commits = 0) and
      (C.N = 0);
    Chk(AName + '/torn', st.TornTail, 'TornTail bekleniyordu');
    Chk(AName + '/no-apply', (st.Frames = 0) and (st.Commits = 0) and
      (C.N = 0), 'bozuk kayit uygulandi: Frames=' + IntToStr(st.Frames) +
      ' Commits=' + IntToStr(st.Commits));
  finally
    C.Free;
    W.Free;
  end;
end;

procedure T3_CrcCorruption;
var
  b: array[0..0] of Byte;
begin
  b[0] := $FF;
  CorruptionCase('t3_crc', 16, b);
end;

procedure T4_BadMagic;
var
  b: array[0..3] of Byte;
begin
  b[0] := $00; b[1] := $00; b[2] := $00; b[3] := $00;
  CorruptionCase('t4_magic', 0, b);
end;

procedure T5_BadPayloadLen;
var
  b: array[0..3] of Byte;
begin
  b[0] := 100; b[1] := 0; b[2] := 0; b[3] := 0;
  CorruptionCase('t5_paylen', 8, b);
end;

{ --------------------------------- T6 ------------------------------------- }

procedure T6_IdempotentRecover;
var
  path: string;
  id: TBytes;
  W: TVdbPageWal;
  C1, C2: TCollector;
  s1, s2: TVdbWalStats;
begin
  path := TestDir + 'wal_t6.wal';
  id := TestDbId(6);
  W := NewWal(path, id);
  try
    WriteCommit(W, [3, 7], [$31, $71], 1);
    WriteCommit(W, [9], [$91], 2);
  finally
    W.Free;
  end;

  W := OpenExistingWal(path, id);
  C1 := TCollector.Create;
  C2 := TCollector.Create;
  try
    W.Recover(C1.Apply, s1);
    W.Recover(C2.Apply, s2);
    Chk('t6/frames-stable', (s1.Frames = s2.Frames) and (s1.Frames = 3),
      IntToStr(s1.Frames) + ' vs ' + IntToStr(s2.Frames));
    Chk('t6/commits-stable', (s1.Commits = s2.Commits) and (s1.Commits = 2),
      IntToStr(s1.Commits) + ' vs ' + IntToStr(s2.Commits));
    Chk('t6/apply-count-stable', C1.N = C2.N,
      IntToStr(C1.N) + ' vs ' + IntToStr(C2.N));
  finally
    C2.Free;
    C1.Free;
    W.Free;
  end;
end;

{ --------------------------------- T7 ------------------------------------- }

procedure T7_LastFrameWins;
var
  path: string;
  id: TBytes;
  W: TVdbPageWal;
  C: TCollector;
  st: TVdbWalStats;
begin
  path := TestDir + 'wal_t7.wal';
  id := TestDbId(7);
  W := NewWal(path, id);
  try
    WriteCommit(W, [7], [$AA], 1);
    WriteCommit(W, [7], [$BB], 2);
  finally
    W.Free;
  end;

  W := OpenExistingWal(path, id);
  C := TCollector.Create;
  try
    W.Recover(C.Apply, st);
    Chk('t7/frames', st.Frames = 1, 'Frames=' + IntToStr(st.Frames));
    Chk('t7/commits', st.Commits = 2, 'Commits=' + IntToStr(st.Commits));
    Chk('t7/last-wins', (C.N = 1) and (C.Marker[0] = $BB),
      'marker=' + IntToHex(C.Marker[0], 2));
  finally
    C.Free;
    W.Free;
  end;
end;

{ --------------------------------- T8 ------------------------------------- }

procedure T8_MetaPageLast;
var
  path: string;
  id: TBytes;
  W: TVdbPageWal;
  C: TCollector;
  st: TVdbWalStats;
begin
  path := TestDir + 'wal_t8.wal';
  id := TestDbId(8);
  W := NewWal(path, id);
  try
    { Meta sayfa cercevesi ILK yaziliyor ama uygulamada EN SON olmali. }
    WriteCommit(W, [VDB_WAL_META_PAGE, 5], [$00, $55], 1);
  finally
    W.Free;
  end;

  W := OpenExistingWal(path, id);
  C := TCollector.Create;
  try
    W.Recover(C.Apply, st);
    Chk('t8/count', C.N = 2, 'N=' + IntToStr(C.N));
    Chk('t8/meta-last', (C.N = 2) and (C.Order[1] = VDB_WAL_META_PAGE),
      'son uygulanan=' + IntToStr(C.Order[1]));
  finally
    C.Free;
    W.Free;
  end;
end;

{ --------------------------------- T9 ------------------------------------- }

procedure T9_SyncFaultNoGhostCommit;
var
  path: string;
  id: TBytes;
  W: TVdbPageWal;
  C: TCollector;
  st: TVdbWalStats;
  p: TVdbPageBuf;
  raised: Boolean;
begin
  path := TestDir + 'wal_t9.wal';
  id := TestDbId(9);
  W := NewWal(path, id);
  try
    WriteCommit(W, [7], [$11], 1);
    W.DebugSetSyncFault(True);
    MakePage(p, 8, $22);
    W.AppendFrame(8, PVdbPage(@p[0]), 2);
    raised := False;
    try
      W.Commit(True, 2);
    except
      on E: EVdbWal do
        raised := True;
    end;
    Chk('t9/commit-fails', raised, 'fsync hatasi commit''i basarisiz kilmadi');
    W.DebugSetSyncFault(False);
  finally
    W.Free;
  end;

  W := OpenExistingWal(path, id);
  C := TCollector.Create;
  try
    W.Recover(C.Apply, st);
    Chk('t9/no-ghost', (st.Commits = 1) and (st.Frames = 1),
      'Commits=' + IntToStr(st.Commits) + ' Frames=' + IntToStr(st.Frames));
    Chk('t9/no-page8', (C.N = 1) and (C.Order[0] = 7),
      'N=' + IntToStr(C.N));
  finally
    C.Free;
    W.Free;
  end;
end;

{ ------------------------------ T10 / T11 --------------------------------- }

procedure T10_UnsafeTruncateRefused;
var
  path: string;
  id: TBytes;
  W: TVdbPageWal;
  before, after: Int64;
begin
  path := TestDir + 'wal_t10.wal';
  id := TestDbId(10);
  W := NewWal(path, id);
  try
    WriteCommit(W, [7], [$11], 1);
    WriteCommit(W, [8], [$22], 5);
    before := W.Bytes;
    W.Truncate(1);   { checkpoint LSN 1 < 5 -> budama GUVENLI DEGIL }
    after := W.Bytes;
    Chk('t10/refused', after = before,
      'Bytes ' + IntToStr(before) + ' -> ' + IntToStr(after));
    Chk('t10/content-kept', W.HasContent, 'HasContent False oldu');
    Chk('t10/header-lsn-kept', W.HeaderLsn = 0,
      'HeaderLsn=' + IntToStr(W.HeaderLsn));
  finally
    W.Free;
  end;
end;

procedure T11_SafeTruncate;
var
  path: string;
  id: TBytes;
  W: TVdbPageWal;
begin
  path := TestDir + 'wal_t11.wal';
  id := TestDbId(11);
  W := NewWal(path, id);
  try
    WriteCommit(W, [7], [$11], 1);
    WriteCommit(W, [8], [$22], 5);
    W.Truncate(5);
    Chk('t11/bytes', W.Bytes = VDB_PAGE_SIZE,
      'Bytes=' + IntToStr(W.Bytes));
    Chk('t11/no-content', not W.HasContent, 'HasContent True kaldi');
    Chk('t11/header-lsn', W.HeaderLsn = 5,
      'HeaderLsn=' + IntToStr(W.HeaderLsn));
    Chk('t11/no-commits', W.CommitCount = 0,
      'CommitCount=' + IntToStr(W.CommitCount));
  finally
    W.Free;
  end;
end;

{ --------------------------------- T12 ------------------------------------ }

procedure T12_DbIdMismatch;
var
  path: string;
  W: TVdbPageWal;
  raised: Boolean;
  st: TVdbWalStats;
begin
  path := TestDir + 'wal_t12.wal';
  W := NewWal(path, TestDbId(12));
  try
    WriteCommit(W, [7], [$11], 1);
  finally
    W.Free;
  end;

  raised := False;
  try
    W := OpenExistingWal(path, TestDbId(99));
    try
      { ReadHeader acilista karsilastirir; hata burada da cikabilir. }
      W.Recover(nil, st);
    finally
      W.Free;
    end;
  except
    on E: EVdbWal do
      raised := True;
  end;
  Chk('t12/dbid-mismatch', raised, 'yanlis db kimligi kabul edildi');
end;

{ --------------------------------- main ----------------------------------- }

begin
  GPass := 0;
  GFail := 0;
  WriteLn('VDB page-WAL crash matrix');
  try
    T1_CommittedOnly;
    T1b_UncommittedTailDropped;
    T2_TornTail;
    T3_CrcCorruption;
    T4_BadMagic;
    T5_BadPayloadLen;
    T6_IdempotentRecover;
    T7_LastFrameWins;
    T8_MetaPageLast;
    T9_SyncFaultNoGhostCommit;
    T10_UnsafeTruncateRefused;
    T11_SafeTruncate;
    T12_DbIdMismatch;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL exception: ', E.ClassName, ': ', E.Message);
    end;
  end;

  WriteLn('');
  WriteLn(IntToStr(GPass), ' passed / ', IntToStr(GFail), ' failed');
  if GFail = 0 then
    WriteLn('RESULT: PASS')
  else
    WriteLn('RESULT: FAIL');
  Halt(GFail);
end.
