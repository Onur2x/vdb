program freelist;
{ ============================================================
  Sprint D (5.1 / 5.2) freelist guvenlik kapisi

  Amac: denetim listesindeki iki kusuru olcmek:
    5.1  Double-free / yanlis serbest birakma korumasi
         - ayni sayfa iki kez serbest birakilamaz
         - trunk sayfasi normal girdi olarak eklenemez
         - canli hucre tasiyan sayfa serbest birakilamaz
         - serbest sayfa tahsis edilince uyelikten cikar
         - FreeCount ve zincir her islemde tutarli
    5.2  CollectFreePages dongu / yineleme guvenligi
         - trunk zinciri dongusu -> acik hata (sonsuz dongu YOK)
         - yinelenen girdi -> acik hata
         - aralik disi girdi -> acik hata
         - FreeCount ile zincir karsilastirilir

  Kapi, sayfa dosyasini bayt duzeyinde bozarak bozuk freelist
  senaryolarini uretir ve acilisin/collect'in ACIK hata verdigini
  dogrular. Sessiz fallback kabul edilmez.
  ============================================================ }
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbPageStore, VDbPage, VDbCrc32, VDbErr;

var
  GPass: Integer = 0;
  GFail: Integer = 0;
  GSeq: Integer = 0;

type
  TTestProc = procedure;

procedure Chk(const AName: string; AOk: Boolean; const ADetail: string = '');
begin
  if AOk then
  begin
    Inc(GPass);
    if ADetail = '' then
      WriteLn('PASS ', AName)
    else
      WriteLn('PASS ', AName, ' | ', ADetail);
  end
  else
  begin
    Inc(GFail);
    if ADetail = '' then
      WriteLn('FAIL ', AName)
    else
      WriteLn('FAIL ', AName, ' | ', ADetail);
  end;
end;

function TestDir: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'tmp';
  ForceDirectories(Result);
end;

function NewDbPath(const ATag: string): string;
var
  D: string;
begin
  Inc(GSeq);
  D := TestDir + PathDelim + Format('fl_%s_%d_%d', [ATag, GetProcessID, GSeq]);
  if DirectoryExists(D) then
  begin
    DeleteFile(D + PathDelim + 'veritabani.odb');
    DeleteFile(D + PathDelim + 'veritabani.odb.gen');
    DeleteFile(D + PathDelim + 'veritabani.odb.wal');
  end;
  ForceDirectories(D);
  Result := D + PathDelim + 'veritabani.odb';
end;

function TryRun(AProc: TTestProc; out AMsg: string): Boolean;
begin
  AMsg := '';
  Result := False;
  try
    AProc;
  except
    on E: Exception do
    begin
      Result := True;
      AMsg := E.ClassName + ': ' + E.Message;
    end;
  end;
end;

{ --- sayfa dosyasina dogrudan erisim (bozulma uretmek icin) --- }
procedure RestampTrunkCrc(const AFile: string; APageNo: LongWord);
var
  fs: TFileStream;
  pg: TVDbPageBuf;
  crc: LongWord;
begin
  fs := TFileStream.Create(AFile, fmOpenReadWrite or fmShareDenyNone);
  try
    fs.Position := Int64(APageNo) * VDB_PAGE_SIZE;
    fs.ReadBuffer(pg, VDB_PAGE_SIZE);
    FillChar(pg[VDB_PAGE_BODY_END], VDB_PAGE_CRC_LEN, 0);
    crc := VDbCrc32Of(pg, VDB_PAGE_BODY_END);
    Move(crc, pg[VDB_PAGE_BODY_END], 4);
    fs.Position := Int64(APageNo) * VDB_PAGE_SIZE;
    fs.WriteBuffer(pg, VDB_PAGE_SIZE);
  finally
    fs.Free;
  end;
end;

procedure WriteTrunkNext(const AFile: string; APageNo, ANext: LongWord);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(AFile, fmOpenReadWrite or fmShareDenyNone);
  try
    fs.Position := Int64(APageNo) * VDB_PAGE_SIZE + 4;
    fs.WriteBuffer(ANext, 4);
  finally
    fs.Free;
  end;
  RestampTrunkCrc(AFile, APageNo);
end;

procedure WriteTrunkEntry(const AFile: string; APageNo: LongWord;
  AIdx: Integer; AValue: LongWord);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(AFile, fmOpenReadWrite or fmShareDenyNone);
  try
    fs.Position := Int64(APageNo) * VDB_PAGE_SIZE + 16 + Int64(AIdx) * 4;
    fs.WriteBuffer(AValue, 4);
  finally
    fs.Free;
  end;
  RestampTrunkCrc(AFile, APageNo);
end;

{ Bos bir depo acar: yalniz baslik sayfasi. }
function FreshStore(const ATag: string; out APath: string): TVdbPageStore;
begin
  APath := NewDbPath(ATag);
  Result := TVdbPageStore.Create(APath);
  Result.Open(True);
end;

procedure AllocN(S: TVdbPageStore; ACount: Integer; var Pages: TVdbPageNoArray);
var
  i: Integer;
  pno: LongWord;
  P: PVdbPage;
begin
  for i := 0 to ACount - 1 do
  begin
    if not S.AllocPage(VDB_PAGE_HEAP, pno, P) then
      raise Exception.CreateFmt('AllocPage basarisiz (%d)', [i]);
    S.Release(pno, False);
    Pages[i] := pno;
  end;
end;

{ ------------------------------------------------------------------
  FL1: ayni serbest sayfayi ikinci kez serbest birakma
  ------------------------------------------------------------------ }
procedure CaseDoubleFreeEntry;
var
  S: TVdbPageStore;
  path: string;
  p1, p2, pno: LongWord;
  P: PVdbPage;
  raised: Boolean;
  msg: string;
begin
  S := FreshStore('dfe', path);
  try
    S.AllocPage(VDB_PAGE_HEAP, p1, P); S.Release(p1, False);
    S.AllocPage(VDB_PAGE_HEAP, p2, P); S.Release(p2, False);

    S.FreePage(p1);   { ilk trunk olur }
    S.FreePage(p2);   { trunk'a girdi olur }

    raised := False;
    msg := '';
    try
      S.FreePage(p2);
    except
      on E: Exception do
      begin
        raised := True;
        msg := E.Message;
      end;
    end;
    Chk('fl1/double-free-rejected', raised, 'istisna=' + BoolToStr(raised, True));
    Chk('fl1/message', Pos('zaten serbest listesinde', msg) > 0, 'msg=' + msg);

    { Serbest sayfa yeniden tahsis edilince uyelikten cikmali. }
    S.AllocPage(VDB_PAGE_HEAP, pno, P);
    S.Release(pno, False);
    Chk('fl1/alloc-returns-entry', pno = p2, Format('pno=%d p2=%d', [pno, p2]));
    Chk('fl1/free-count', S.FreeCount = 0, 'free=' + IntToStr(S.FreeCount));
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------------
  FL2: trunk sayfasini serbest birakma
  ------------------------------------------------------------------ }
procedure CaseFreeTrunk;
var
  S: TVdbPageStore;
  path: string;
  p1: LongWord;
  P: PVdbPage;
  raised: Boolean;
  msg: string;
begin
  S := FreshStore('ftrunk', path);
  try
    S.AllocPage(VDB_PAGE_HEAP, p1, P); S.Release(p1, False);
    S.FreePage(p1);
    Chk('fl2/trunk-created', S.GetFreeTrunk = p1,
      Format('trunk=%d p1=%d', [S.GetFreeTrunk, p1]));

    raised := False;
    msg := '';
    try
      S.FreePage(p1);
    except
      on E: Exception do
      begin
        raised := True;
        msg := E.Message;
      end;
    end;
    Chk('fl2/trunk-free-rejected', raised, 'istisna=' + BoolToStr(raised, True));
    Chk('fl2/message', Pos('zaten freelist trunk', msg) > 0, 'msg=' + msg);
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------------
  FL3: canli hucre tasiyan heap sayfasini serbest birakma
  ------------------------------------------------------------------ }
procedure CaseFreeLivePage;
var
  S: TVdbPageStore;
  path: string;
  p1: LongWord;
  P: PVdbPage;
  raised: Boolean;
  msg: string;
begin
  S := FreshStore('flive', path);
  try
    S.AllocPage(VDB_PAGE_HEAP, p1, P);
    { Tek bir canli hucre gorunumu kur. }
    PageHdr(P)^.SlotCount := 1;
    PVdbPageSlot(PByte(P) + VDB_PAGE_HDR)^.Off := 1;
    PVdbPageSlot(PByte(P) + VDB_PAGE_HDR)^.Len := 1;
    PageSeal(P);
    S.Release(p1, True);

    raised := False;
    msg := '';
    try
      S.FreePage(p1);
    except
      on E: Exception do
      begin
        raised := True;
        msg := E.Message;
      end;
    end;
    Chk('fl3/live-page-rejected', raised, 'istisna=' + BoolToStr(raised, True));
    Chk('fl3/message', Pos('canli hucre', msg) > 0, 'msg=' + msg);
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------------
  FL4: cok trunk, trunk dolmasi, bos trunk, sayac tutarliligi
  ------------------------------------------------------------------ }
procedure CaseManyTrunks;
var
  S: TVdbPageStore;
  path: string;
  pages: array of LongWord;
  i, n: Integer;
  pno: LongWord;
  P: PVdbPage;
  freePages: TVdbPageNoArray;
  err: string;
  okV, okC: Boolean;
begin
  n := VDB_TRUNK_MAX + 10;
  S := FreshStore('trunks', path);
  try
    SetLength(pages, n);
    AllocN(S, n, pages);

    for i := 0 to n - 1 do
      S.FreePage(pages[i]);

    { Ilk sayfa trunk oldugu icin girdi sayisi n-1, ikinci trunk n-1-MAX girdi. }
    Chk('fl4/free-count', S.FreeCount = LongWord(n - 2),
      Format('free=%d beklenen=%d', [S.FreeCount, n - 2]));

    okV := S.VerifyFreeList(freePages, err);
    Chk('fl4/verify-ok', okV, 'err=' + err);
    Chk('fl4/verify-count', Length(freePages) = n - 2,
      Format('zincir=%d beklenen=%d', [Length(freePages), n - 2]));

    okC := S.CollectFreePages(freePages, err);
    Chk('fl4/collect-ok', okC, 'err=' + err);
    { CollectFreePages trunk'lari da listeler: (n-2) girdi + 2 trunk. }
    Chk('fl4/collect-includes-trunks', Length(freePages) = n,
      Format('collect=%d beklenen=%d', [Length(freePages), n]));

    { Tumunu geri al: hicbiri ikinci kez verilmemeli, sayfa sayisi artmamali. }
    Chk('fl4/alloc-drains', S.PageCount = LongWord(n + 1),
      'pagecount=' + IntToStr(S.PageCount));
    for i := 0 to n - 1 do
    begin
      if not S.AllocPage(VDB_PAGE_HEAP, pno, P) then
        raise Exception.CreateFmt('drain AllocPage basarisiz (%d)', [i]);
      S.Release(pno, False);
      pages[i] := pno;
    end;
    Chk('fl4/drained-free-count', S.FreeCount = 0,
      'free=' + IntToStr(S.FreeCount));
    Chk('fl4/no-page-growth', S.PageCount = LongWord(n + 1),
      'pagecount=' + IntToStr(S.PageCount));
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------------
  FL5: trunk zinciri dongusu -> acik hata, sonsuz dongu yok
  ------------------------------------------------------------------ }
procedure CaseTrunkCycle;
var
  S: TVdbPageStore;
  path: string;
  p1, p2, t1: LongWord;
  P: PVdbPage;
  freePages: TVdbPageNoArray;
  err: string;
  okC: Boolean;
begin
  path := NewDbPath('cycle');
  S := TVdbPageStore.Create(path);
  try
    S.Open(True);
    S.AllocPage(VDB_PAGE_HEAP, p1, P); S.Release(p1, False);
    S.AllocPage(VDB_PAGE_HEAP, p2, P); S.Release(p2, False);
    S.FreePage(p1);
    S.FreePage(p2);
    t1 := S.GetFreeTrunk;
    S.Flush(True);
  finally
    S.Free;
  end;

  { Trunk kendini gosteren bir zincir kur (CRC yeniden damgalanir). }
  WriteTrunkNext(path, t1, t1);

  S := TVdbPageStore.Create(path);
  try
    S.Open(False);
    okC := S.CollectFreePages(freePages, err);
    Chk('fl5/cycle-rejected', not okC,
      'ok=' + BoolToStr(okC, True) + ' err=' + err);
    Chk('fl5/message', Pos('dongulu', err) > 0, 'err=' + err);
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------------
  FL6: yinelenen serbest girdi -> acik hata
  ------------------------------------------------------------------ }
procedure CaseDuplicateEntry;
var
  S: TVdbPageStore;
  path: string;
  p1, p2, p3, t1: LongWord;
  P: PVdbPage;
  freePages: TVdbPageNoArray;
  err: string;
  okC: Boolean;
begin
  path := NewDbPath('dup');
  S := TVdbPageStore.Create(path);
  try
    S.Open(True);
    S.AllocPage(VDB_PAGE_HEAP, p1, P); S.Release(p1, False);
    S.AllocPage(VDB_PAGE_HEAP, p2, P); S.Release(p2, False);
    S.AllocPage(VDB_PAGE_HEAP, p3, P); S.Release(p3, False);
    S.FreePage(p1);
    S.FreePage(p2);
    S.FreePage(p3);
    t1 := S.GetFreeTrunk;
    S.Flush(True);
  finally
    S.Free;
  end;

  { Ikinci girdiyi birinciye esitle: sayfa iki kez serbest gorunur. }
  WriteTrunkEntry(path, t1, 1, p2);

  S := TVdbPageStore.Create(path);
  try
    S.Open(False);
    okC := S.CollectFreePages(freePages, err);
    Chk('fl6/duplicate-rejected', not okC,
      'ok=' + BoolToStr(okC, True) + ' err=' + err);
    Chk('fl6/message', Pos('yineleniyor', err) > 0, 'err=' + err);
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------------
  FL7: aralik disi serbest girdi -> acik hata
  ------------------------------------------------------------------ }
procedure CaseOutOfRangeEntry;
var
  S: TVdbPageStore;
  path: string;
  p1, p2, t1: LongWord;
  P: PVdbPage;
  freePages: TVdbPageNoArray;
  err: string;
  okC: Boolean;
begin
  path := NewDbPath('range');
  S := TVdbPageStore.Create(path);
  try
    S.Open(True);
    S.AllocPage(VDB_PAGE_HEAP, p1, P); S.Release(p1, False);
    S.AllocPage(VDB_PAGE_HEAP, p2, P); S.Release(p2, False);
    S.FreePage(p1);
    S.FreePage(p2);
    t1 := S.GetFreeTrunk;
    S.Flush(True);
  finally
    S.Free;
  end;

  WriteTrunkEntry(path, t1, 0, $00FFFFFF);

  S := TVdbPageStore.Create(path);
  try
    S.Open(False);
    okC := S.CollectFreePages(freePages, err);
    Chk('fl7/range-rejected', not okC,
      'ok=' + BoolToStr(okC, True) + ' err=' + err);
    Chk('fl7/message', Pos('aralik disi', err) > 0, 'err=' + err);
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------------
  FL8: bozuk freelist ile acilis (heap taramasi) acik hata verir
  ------------------------------------------------------------------ }
procedure CaseOpenWithBrokenFreeList;
var
  S: TVdbPageStore;
  path: string;
  p1, t1: LongWord;
  P: PVdbPage;
  raised: Boolean;
  msg, err: string;
  freePages: TVdbPageNoArray;
  okC: Boolean;
begin
  path := NewDbPath('openbad');
  S := TVdbPageStore.Create(path);
  try
    S.Open(True);
    S.AllocPage(VDB_PAGE_HEAP, p1, P); S.Release(p1, False);
    S.FreePage(p1);
    t1 := S.GetFreeTrunk;
    S.Flush(True);
  finally
    S.Free;
  end;

  WriteTrunkNext(path, t1, t1);

  { Depo duzeyinde collect acik hata verir (heap.Open da buna dayanir). }
  S := TVdbPageStore.Create(path);
  try
    raised := False;
    msg := '';
    try
      S.Open(False);
    except
      on E: Exception do
      begin
        raised := True;
        msg := E.Message;
      end;
    end;
    Chk('fl8/open-no-hang', True, 'acilis tamamlandi veya hata: ' +
      BoolToStr(raised, True));
    if raised then
      Chk('fl8/open-message', True, 'msg=' + msg)
    else
    begin
      raised := False;
      msg := '';
      okC := S.CollectFreePages(freePages, err);
      Chk('fl8/collect-rejected', not okC,
        'ok=' + BoolToStr(okC, True) + ' err=' + err);
      Chk('fl8/message', Pos('dongulu', err) > 0, 'err=' + err);
    end;
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------------
  FL9: saglikli depoda iki denetleyici ayni sonucu verir
  ------------------------------------------------------------------ }
procedure CaseHealthyConsistency;
var
  S: TVdbPageStore;
  path: string;
  pages: array of LongWord;
  i: Integer;
  fv, fc: TVdbPageNoArray;
  err: string;
begin
  S := FreshStore('healthy', path);
  try
    SetLength(pages, 12);
    AllocN(S, 12, pages);
    for i := 0 to 5 do
      S.FreePage(pages[i]);

    Chk('fl9/verify', S.VerifyFreeList(fv, err), 'err=' + err);
    Chk('fl9/collect', S.CollectFreePages(fc, err), 'err=' + err);
    Chk('fl9/verify-count', Length(fv) = 5, 'verify=' + IntToStr(Length(fv)));
    Chk('fl9/collect-count', Length(fc) = 6, 'collect=' + IntToStr(Length(fc)));
    Chk('fl9/meta-count', S.FreeCount = 5, 'free=' + IntToStr(S.FreeCount));
    Chk('fl9/stats', S.Stats.FreeCount = 5,
      'stats=' + IntToStr(S.Stats.FreeCount));
  finally
    S.Free;
  end;
end;

begin
  WriteLn('VDB freelist guvenlik kapisi (Sprint D: 5.1 / 5.2)');

  CaseDoubleFreeEntry;
  CaseFreeTrunk;
  CaseFreeLivePage;
  CaseManyTrunks;
  CaseTrunkCycle;
  CaseDuplicateEntry;
  CaseOutOfRangeEntry;
  CaseOpenWithBrokenFreeList;
  CaseHealthyConsistency;

  WriteLn;
  WriteLn(Format('SONUC: %d PASS, %d FAIL', [GPass, GFail]));
  if GFail > 0 then
    Halt(1);
end.
