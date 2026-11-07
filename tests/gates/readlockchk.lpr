program readlockchk;

{ VDB v3 - B-05 / B-07 kilit durumu kapisi.

  Denetlenenler:
    1) ReadBytesAt HATA yolunda gecici paylasimli kilidin birakildigi.
       Iyimser yazma rezervasyonu tutulurken (FHoldDepth > 0, veri akisi
       kilitsiz) kasitli olarak kesilmis dosyadan sayfa okunur. Okuma
       istisnasindan sonra VDbSync kilit defterinde tutulan kilit
       KALMAMALIDIR (eski kodda selfShared siziyordu).
    2) FHoldDepth artirma/azaltma 1:1: AcquireWriteHold -> 1,
       ReleaseWriteHold -> 0.
    3) Kapanis (CloseNoFlush) rezervasyon derinligini sifirlar.
    4) Pozitif kontrol (Windows): depo tam kilit alinca kilit defterinin
       kilidi GORDUGUNU dogrular; boylece (1)'deki "yok" sonucu anlamlidir.
       Unix'te kilit defteri tutulmadigi icin bu kontrol atlanir.

  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: readlockchk <calisma_dizini>
}

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbPage, VDbPageStore;

var
  gPass, gFail: Int64;

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

procedure DeleteDb(const Db: string);
var
  n: string;
begin
  for n in [Db, Db + '.gen', Db + '.wal', Db + '.log'] do
    if FileExists(n) then DeleteFile(n);
end;

procedure MakeDb(const Db: string);
var
  st: TVDbPageStore;
  p: PVdbPage;
  pg: LongWord;
  i: Integer;
begin
  st := TVDbPageStore.Create(Db, 64);
  try
    st.Open(True);
    try
      { Meta (0) + 4 veri sayfasi: FPageCount = 5. }
      for i := 1 to 4 do
      begin
        if not st.AllocPage(1, pg, p) then
          raise Exception.Create('AllocPage basarisiz');
        FillChar(p^, VDB_PAGE_SIZE, Byte(i));
        st.Release(pg, True);
      end;
      st.Flush(True);
    finally
      st.Close;
    end;
  finally
    st.Free;
  end;
end;

{ Veri dosyasini tek sayfaya (meta) kirp. Boylece 1. sayfa okumasi EOF
  nedeniyle ReadBytesAt hata yoluna duser. }
function FileLenOf(const P: string): Int64;
var
  fs: TFileStream;
begin
  if not FileExists(P) then Exit(-1);
  fs := TFileStream.Create(P, fmOpenRead or fmShareDenyNone);
  try
    Result := fs.Size;
  finally
    fs.Free;
  end;
end;

procedure TruncateToMeta(const Db: string);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(Db, fmOpenReadWrite or fmShareDenyNone);
  try
    fs.Size := VDB_PAGE_SIZE;
  finally
    fs.Free;
  end;
end;

procedure Run(const Dir: string);
var
  Db: string;
  st: TVDbPageStore;
  p: PVdbPage;
  shared, held: Boolean;
  failed: Boolean;
begin
  ForceDirectories(Dir);
  Db := IncludeTrailingPathDelimiter(Dir) + 'readlock.odb';
  DeleteDb(Db);
  MakeDb(Db);

  st := TVDbPageStore.Create(Db, 64);
  try
    st.Open(False);

    { 1) Iyimser islem: yalniz rezervasyon (FHoldDepth=1), veri akisi kilitsiz. }
    st.AcquireWriteHold;
    if st.LockHoldDepth = 1 then
      Ok('AcquireWriteHold: FHoldDepth=1')
    else
      Fail(Format('AcquireWriteHold: FHoldDepth=%d (beklenen 1)',
        [st.LockHoldDepth]));

    held := st.LockBookProbe(shared);
    if held then
      Fail('rezervasyon asamasinda veri akisinda kilit beklenmiyordu')
    else
      Ok('rezervasyon asamasinda veri akisi kilitsiz');

    { 2) Okuma hatasini enjekte et. }
    TruncateToMeta(Db);
    WriteLn(Format('   bilgi dosya boyu (kirpma sonrasi) = %d', [FileLenOf(Db)]));
    failed := False;
    try
      { Sayfa 1 diskte yok (dosya 4096 bayt); ReadBytesAt kisa okuma alir. }
      st.GetPage(1, p);
    except
      on E: EVdbPageStore do
      begin
        failed := True;
        WriteLn('   bilgi okuma hatasi: ', E.Message);
      end;
    end;
    if failed then
      Ok('kesik dosyada sayfa okumasi beklenen hatayi verdi')
    else
      Fail('kesik dosyada sayfa okumasi HATA VERMEDI');

    { 3) B-07: hata yolundan sonra kilit defteri temiz olmali. }
    held := st.LockBookProbe(shared);
    if held then
      Fail(Format('KILIT SIZINTISI: okuma hatasindan sonra kilit defteri ' +
        'Held=True (shared=%d)', [Ord(shared)]))
    else
      Ok('okuma hatasindan sonra kilit sizintisi yok');

    if st.LockHoldDepth = 1 then
      Ok('hata yolu FHoldDepth sayacini bozmadi (=1)')
    else
      Fail(Format('hata yolu sonrasi FHoldDepth=%d (beklenen 1)',
        [st.LockHoldDepth]));

    { 4) B-05: normal birakma 1 -> 0. }
    st.ReleaseWriteHold;
    if st.LockHoldDepth = 0 then
      Ok('ReleaseWriteHold: FHoldDepth=0')
    else
      Fail(Format('ReleaseWriteHold sonrasi FHoldDepth=%d (beklenen 0)',
        [st.LockHoldDepth]));

    held := st.LockBookProbe(shared);
    if held then
      Fail('ReleaseWriteHold sonrasi veri akisinda kilit kaldi')
    else
      Ok('ReleaseWriteHold sonrasi veri akisi kilitsiz');

    { 5) Pozitif kontrol: tam kilit defterde GORUNMELI (Windows). }
    {$IFDEF WINDOWS}
    st.AcquireWrite;
    held := st.LockBookProbe(shared);
    if held and (not shared) then
      Ok('pozitif kontrol: tam kilit defterde gorunuyor')
    else
      Fail(Format('pozitif kontrol basarisiz: held=%d shared=%d',
        [Ord(held), Ord(shared)]));
    st.ReleaseWrite;
    held := st.LockBookProbe(shared);
    if held then
      Fail('ReleaseWrite sonrasi kilit defteri temiz degil')
    else
      Ok('ReleaseWrite sonrasi kilit defteri temiz');
    {$ELSE}
    Ok('Unix: kilit defteri tutulmuyor, pozitif kontrol atlandi');
    {$ENDIF}

    { 6) Kapanis sayaci sifirlamali (B-05). }
    st.AcquireWriteHold;
    if st.LockHoldDepth = 1 then
      Ok('yeniden AcquireWriteHold: FHoldDepth=1')
    else
      Fail(Format('yeniden AcquireWriteHold: FHoldDepth=%d (beklenen 1)',
        [st.LockHoldDepth]));
    st.CloseNoFlush;
    if st.LockHoldDepth = 0 then
      Ok('CloseNoFlush: FHoldDepth=0')
    else
      Fail(Format('CloseNoFlush sonrasi FHoldDepth=%d (beklenen 0)',
        [st.LockHoldDepth]));
  finally
    st.Free;
  end;

  DeleteDb(Db);
end;

var
  work: string;
begin
  if ParamCount < 1 then
  begin
    WriteLn('kullanim: readlockchk <calisma_dizini>');
    Halt(2);
  end;
  work := ParamStr(1);
  try
    Run(work);
  except
    on E: Exception do
    begin
      Fail('beklenmeyen istisna: ' + E.ClassName + ': ' + E.Message);
    end;
  end;
  WriteLn(Format('gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
    WriteLn('OKUMA KILIDI SIZINTISI YOK')
  else
    WriteLn('OKUMA KILIDI SIZINTISI VAR');
  if gFail > 0 then Halt(1);
end.
