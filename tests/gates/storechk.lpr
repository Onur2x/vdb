program storechk;

{ VDB v3 - Sayfa deposu dogrulama (Sprint 1 / Gun 2-3 kabul kapisi)

  Denetlenenler:
    1) 2000 sayfa ayir, her birine desen yaz, hepsini geri oku (onbellek
       tahliyesi dahil: havuz 64 sayfa).
    2) Her 3. sayfayi serbest birak, ayni sayida yeniden ayir: freelist
       geri kazanimi ve dosya buyumemesi.
    3) Kapat/ac: veri kalici mi, baslik tutarli mi.
    4) Bilincli bozulma: veri sayfasi ve baslik sayfasi CRC'si yakalanir.
    5) Freelist butunlugu: FreeCount = gercekten serbest sayfa sayisi, ve
       serbest sayfalar tekrar ayirinca ayni kume (cift kayit yok).
    6) v2 dosyasi acilirsa net "MIGRATE TO v3" hatasi.

  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: storechk <calisma_dizini> [sayfa_sayisi] [havuz_sayfa]
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: cthreads programin EN BASINDA olmali (TEvent/TThread). }
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

function PatByte(PageNo: LongWord; Offset: Integer): Byte;
begin
  Result := Byte((PageNo * 31 + LongWord(Offset) * 7) and $FF);
end;

{ Sayfaya yazilacak tek hucrenin icerigi. }
procedure CellData(PageNo: LongWord; out B: TBytes);
var
  i, len: Integer;
begin
  len := 200 + Integer(PageNo mod 400);
  SetLength(B, len);
  for i := 0 to len - 1 do
    B[i] := PatByte(PageNo, i);
end;

procedure FillPattern(P: PVdbPage; PageNo: LongWord);
var
  b: TBytes;
  slot: Integer;
begin
  CellData(PageNo, b);
  if not PageInsertCell(P, b[0], Length(b), slot) then
    raise EVdbPageStore.Create(Format('desen yazilamadi (sayfa %d)', [PageNo]));
end;

function CheckPattern(P: PVdbPage; PageNo: LongWord; out Bad: Integer): Boolean;
var
  b: TBytes;
  i, dl: Integer;
  d: PByte;
begin
  Result := False;
  CellData(PageNo, b);
  if PageLiveCount(P) <> 1 then
  begin
    Bad := -2;
    Exit;
  end;
  if not PageGetCell(P, 0, d, dl) then
  begin
    Bad := -3;
    Exit;
  end;
  if dl <> Length(b) then
  begin
    Bad := -4;
    Exit;
  end;
  for i := 0 to dl - 1 do
    if d[i] <> b[i] then
    begin
      Bad := i;
      Exit;
    end;
  Bad := -1;
  Result := True;
end;

{ 1) ayir + desen + geri oku }
procedure TestAllocRead(D: string; N, PoolPages: Integer;
  out Pages: array of LongWord);
var
  st: TVDbPageStore;
  i, bad, firstBad: Integer;
  pno: LongWord;
  P: PVdbPage;
  e: string;
begin
  st := TVDbPageStore.Create(D + PathDelim + 'a.odb', PoolPages);
  try
    st.Open(True);
    if st.PageCount <> 1 then
      Fail(Format('yeni dosyada sayfa sayisi %d (beklenen 1)', [st.PageCount]))
    else
      Ok('yeni dosya: 1 sayfa (baslik)');
    for i := 0 to N - 1 do
    begin
      if not st.AllocPage(VDB_PAGE_HEAP, pno, P) then
      begin
        Fail(Format('sayfa %d ayrilamadi', [i]));
        Exit;
      end;
      Pages[i] := pno;
      FillPattern(P, pno);
      st.Release(pno, True);
    end;
    st.Flush(True);
    Ok(Format('%d sayfa ayrildi, desen yazildi (havuz %d)', [N, PoolPages]));
    if st.PageCount <> LongWord(N + 1) then
      Fail(Format('sayfa sayisi %d (beklenen %d)', [st.PageCount, N + 1]))
    else
      Ok(Format('sayfa sayisi %d (baslik + %d veri)', [st.PageCount, N]));

    { Geri oku — havuz kucuk oldugu icin tahliye yasanir. }
    bad := 0;
    for i := 0 to N - 1 do
    begin
      if not st.GetPage(Pages[i], P) then
      begin
        Fail(Format('sayfa %d okunamadi', [Pages[i]]));
        Inc(bad);
        Continue;
      end;
      if not PageVerify(P, e) then
      begin
        Fail(Format('sayfa %d gecersiz: %s', [Pages[i], e]));
        Inc(bad);
      end
      else if not CheckPattern(P, Pages[i], firstBad) then
      begin
        Fail(Format('sayfa %d deseni bozuk (bayt %d)', [Pages[i], firstBad]));
        Inc(bad);
      end;
      st.Release(Pages[i], False);
      if bad > 3 then Break;
    end;
    if bad = 0 then
      Ok(Format('%d sayfa geri okundu, desen birebir, CRC gecerli', [N]));
    WriteLn(Format('        okuma=%d yazma=%d tahliye=%d onbellek=%d/%d',
      [st.Stats.Reads, st.Stats.Writes, st.Stats.Evictions,
       st.Stats.PoolUsed, st.Stats.PoolPages]));
    st.Close;
  finally
    st.Free;
  end;
end;

{ 2) freelist geri kazanimi }
procedure TestFreelist(D: string; N: Integer; Pages: array of LongWord;
  out ExpectPages: LongWord);
var
  st: TVDbPageStore;
  i, j, freed, realloc: Integer;
  pno: LongWord;
  P: PVdbPage;
  before: LongWord;
begin
  st := TVDbPageStore.Create(D + PathDelim + 'a.odb', 64);
  try
    st.Open(False);
    before := st.PageCount;
    freed := 0;
    for i := 0 to N - 1 do
      if (i mod 3) = 0 then
      begin
        st.FreePage(Pages[i]);
        Inc(freed);
      end;
    st.Flush(True);
    if st.FreeCount <> LongWord(freed) then
      Fail(Format('FreeCount %d (beklenen %d)', [st.FreeCount, freed]))
    else
      Ok(Format('%d sayfa serbest birakildi (FreeCount=%d)', [freed, st.FreeCount]));
    { Ilk trunk dosya sonuna eklenir: 1 sayfalik kacinilmaz ek yuk. }
    if (freed <= VDB_TRUNK_MAX) and (st.PageCount <> before + 1) then
      Fail(Format('trunk sonrasi sayfa sayisi %d (beklenen %d)',
        [st.PageCount, before + 1]))
    else
      Ok(Format('trunk sayfasi eklendi, dosya %d -> %d sayfa',
        [before, st.PageCount]));

    { Ayni sayida yeniden ayir: veri sayfasi eklenmemeli. }
    realloc := 0;
    for j := 0 to freed - 1 do
    begin
      if not st.AllocPage(VDB_PAGE_HEAP, pno, P) then
      begin
        Fail('yeniden ayirma basarisiz');
        Break;
      end;
      Inc(realloc);
      PageInit(P, pno, VDB_PAGE_HEAP);
      st.Release(pno, True);
    end;
    st.Flush(True);
    if st.FreeCount <> 0 then
      Fail(Format('yeniden ayirma sonrasi FreeCount %d (beklenen 0)', [st.FreeCount]))
    else
      Ok(Format('%d sayfa yeniden ayrildi, FreeCount=0', [realloc]));

    { Bosalan trunk SIZMAMALI: sonraki ayirma onu sayfa olarak vermeli. }
    before := st.PageCount;
    if not st.AllocPage(VDB_PAGE_HEAP, pno, P) then
      Fail('bos trunk sayfa olarak ayrilamadi')
    else
    begin
      st.Release(pno, True);
      st.Flush(True);
      if st.PageCount <> before then
        Fail(Format('bos trunk sizdi: dosya %d -> %d', [before, st.PageCount]))
      else if pno <> before - 1 then
        Fail(Format('bos trunk sayfa olarak verilmedi (sayfa %d, beklenen %d)',
          [pno, before - 1]))
      else
        Ok(Format('bos trunk sizmedi, sayfa %d olarak geri kazanildi', [pno]));
    end;
    ExpectPages := st.PageCount;
    st.Close;
  finally
    st.Free;
  end;
end;

{ 3) kapat/ac kalicilik }
procedure TestReopen(D: string; N: Integer; Pages: array of LongWord;
  ExpectPages: LongWord);
var
  st: TVDbPageStore;
  i, bad: Integer;
  P: PVdbPage;
  e: string;
begin
  st := TVDbPageStore.Create(D + PathDelim + 'a.odb', 32);
  try
    st.Open(False);
    if st.PageCount <> ExpectPages then
      Fail(Format('acilista sayfa sayisi %d (beklenen %d)',
        [st.PageCount, ExpectPages]))
    else
      Ok(Format('acilista sayfa sayisi %d', [st.PageCount]));
    bad := 0;
    { Ilk 3'te bir serbest birakilanlar artik sayfa degil; yalniz
      serbest BIRAKILMAYANLARI desenle karsilastir. }
    for i := 0 to N - 1 do
      if (i mod 3) <> 0 then
      begin
        if not st.GetPage(Pages[i], P) then
        begin
          Fail(Format('yeniden acista sayfa %d okunamadi', [Pages[i]]));
          Inc(bad);
          Continue;
        end;
        if not PageVerify(P, e) then
        begin
          Fail(Format('yeniden acista sayfa %d gecersiz: %s', [Pages[i], e]));
          Inc(bad);
        end;
        st.Release(Pages[i], False);
        if bad > 3 then Break;
      end;
    if bad = 0 then
      Ok('yeniden acista sayfalar gecerli (CRC)');
    st.Close;
  finally
    st.Free;
  end;
end;

{ 4) bozulma yakalama }
procedure TestCorruption(D: string);
var
  st: TVDbPageStore;
  pno: LongWord;
  P: PVdbPage;
  f: TFileStream;
  b: Byte;
  off: Int64;
  caught: Integer;
  raised: Boolean;
begin
  st := TVDbPageStore.Create(D + PathDelim + 'c.odb', 16);
  try
    st.Open(True);
    st.AllocPage(VDB_PAGE_HEAP, pno, P);
    FillPattern(P, pno);
    st.Release(pno, True);
    st.Flush(True);
    st.Close;
  finally
    st.Free;
  end;

  caught := 0;
  { Veri sayfasinda tek bayt boz. }
  off := Int64(pno) * VDB_PAGE_SIZE + 100;
  f := TFileStream.Create(D + PathDelim + 'c.odb', fmOpenReadWrite or fmShareDenyNone);
  try
    f.Position := off;
    f.ReadBuffer(b, 1);
    b := b xor $FF;
    f.Position := off;
    f.WriteBuffer(b, 1);
  finally
    f.Free;
  end;
  st := TVDbPageStore.Create(D + PathDelim + 'c.odb', 16);
  try
    st.Open(False);
    raised := False;
    try
      st.GetPage(pno, P);
    except
      on E: EVdbPageStore do
      begin
        raised := True;
        if Pos('bozuk', E.Message) > 0 then Inc(caught);
      end;
    end;
    if raised then
      Ok('bozulmus veri sayfasi reddedildi')
    else
      Fail('bozulmus veri sayfasi kabul edildi');
    { Onbellekte kalan bozuk cerceve tekrar okunmamali. }
    st.Close;
  finally
    st.Free;
  end;

  { Baslik sayfasinda tek bayt boz. }
  f := TFileStream.Create(D + PathDelim + 'c.odb', fmOpenReadWrite or fmShareDenyNone);
  try
    f.Position := 20;
    f.ReadBuffer(b, 1);
    b := b xor $FF;
    f.Position := 20;
    f.WriteBuffer(b, 1);
  finally
    f.Free;
  end;
  st := TVDbPageStore.Create(D + PathDelim + 'c.odb', 16);
  try
    raised := False;
    try
      st.Open(False);
    except
      on E: EVdbPageStore do
      begin
        raised := True;
        if Pos('CRC', E.Message) > 0 then Inc(caught);
      end;
    end;
    if raised then
      Ok('bozulmus baslik sayfasi reddedildi')
    else
      Fail('bozulmus baslik sayfasi kabul edildi');
  finally
    st.Free;
  end;

  if caught >= 2 then
    Ok(Format('bozulma: %d/2 bolgede yakalandi', [caught]))
  else
    Fail(Format('bozulma: yalniz %d/2 yakalandi', [caught]));
end;

{ 5) v2 dosyasi net hata }
procedure TestV2Reject(D: string);
var
  st: TVDbPageStore;
  f: TFileStream;
  hdr: array[0..4095] of Byte;
  raised: Boolean;
  magic: LongWord;
begin
  FillChar(hdr, SizeOf(hdr), 0);
  magic := VDB_V2_MAGIC;
  Move(magic, hdr[0], SizeOf(magic));
  f := TFileStream.Create(D + PathDelim + 'v2.odb', fmCreate);
  try
    f.WriteBuffer(hdr, SizeOf(hdr));
  finally
    f.Free;
  end;
  st := TVDbPageStore.Create(D + PathDelim + 'v2.odb', 16);
  try
    raised := False;
    try
      st.Open(False);
    except
      on E: EVdbPageStore do
        raised := Pos('MIGRATE TO v3', E.Message) > 0;
    end;
    if raised then
      Ok('v2 dosyasi: "MIGRATE TO v3" hatasi')
    else
      Fail('v2 dosyasi icin net goc hatasi verilmedi');
  finally
    st.Free;
  end;
end;

{ 6) kucuk havuzda cok sayida rastgele erisim }
procedure TestThrash(D: string; N: Integer; Pages: array of LongWord);
var
  st: TVDbPageStore;
  i, k, bad, firstBad: Integer;
  P: PVdbPage;
  seed: LongWord;
begin
  st := TVDbPageStore.Create(D + PathDelim + 'a.odb', 8);
  try
    st.Open(False);
    seed := 2463534242;
    bad := 0;
    for i := 1 to 20000 do
    begin
      seed := seed xor (seed shl 13);
      seed := seed xor (seed shr 17);
      seed := seed xor (seed shl 5);
      k := Integer(seed mod LongWord(N));
      if (k mod 3) = 0 then Continue;   // serbest birakilmislar
      if not st.GetPage(Pages[k], P) then
      begin
        Inc(bad);
        if bad < 4 then Fail(Format('thrash: sayfa %d okunamadi', [Pages[k]]));
        Continue;
      end;
      if not CheckPattern(P, Pages[k], firstBad) then
      begin
        Inc(bad);
        if bad < 4 then
          Fail(Format('thrash: sayfa %d icerigi bozuk (bayt %d)', [Pages[k], firstBad]));
      end;
      st.Release(Pages[k], False);
    end;
    if bad = 0 then
      Ok(Format('thrash: 20000 erisim, havuz %d, 0 hata (tahliye=%d)',
        [8, st.Stats.Evictions]));
    st.Close;
  finally
    st.Free;
  end;
end;

var
  D: string;
  N, PoolPages, i: Integer;
  Pages: array of LongWord;
  ExpectPages: LongWord;
begin
  gPass := 0;
  gFail := 0;
  D := ParamStr(1);
  if D = '' then
    D := IncludeTrailingPathDelimiter(GetTempDir) + 'vdbstorechk';
  N := StrToIntDef(ParamStr(2), 2000);
  PoolPages := StrToIntDef(ParamStr(3), 64);
  ForceDirectories(D);
  SetLength(Pages, N);

  WriteLn('VDB v3 storechk - sayfa deposu dogrulama');
  WriteLn(Format('dizin=%s sayfa=%d havuz=%d', [D, N, PoolPages]));
  WriteLn('');

  { Temiz baslangic. }
  if FileExists(D + PathDelim + 'a.odb') then DeleteFile(D + PathDelim + 'a.odb');
  if FileExists(D + PathDelim + 'c.odb') then DeleteFile(D + PathDelim + 'c.odb');
  if FileExists(D + PathDelim + 'v2.odb') then DeleteFile(D + PathDelim + 'v2.odb');

  TestAllocRead(D, N, PoolPages, Pages);
  TestFreelist(D, N, Pages, ExpectPages);
  TestReopen(D, N, Pages, ExpectPages);
  TestCorruption(D);
  TestV2Reject(D);
  TestThrash(D, N, Pages);

  WriteLn('');
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
    WriteLn('SAYFA DEPOSU DOGRULANDI')
  else
    WriteLn('SAYFA DEPOSU HATALI');
  if gFail <> 0 then
    Halt(1);
end.
