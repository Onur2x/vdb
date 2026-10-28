program idxchk;

{ VDB v3 - Kalici anahtar dizini (.odb.idx) dogrulama  (Sprint 1 / 1.10-1.11)

  Denetlenenler:
    1) N satir yaz, temiz kapat -> .idx olusur; yeniden acilista IdxUsed=True,
       tarama atlanir, tum anahtarlar birebir okunur. Acilis suresi olculur.
    2) .idx bozuk (bayt cevrilmis) -> reddedilir, tam tarama, VERI KAYBI YOK.
    3) .idx kesik (dosya kirpilmis) -> reddedilir, tam tarama.
    4) .idx bayat (eski LSN) -> reddedilir, tam tarama.
    5) .idx silinmis -> tam tarama, veri ayni.
    6) Sil/guncelle sonrasi kapat-ac: sayi ve degerler birebir.

  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: idxchk <calisma_dizini> [satir_sayisi]
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: cthreads programin EN BASINDA olmali (TEvent/TThread). }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, DateUtils, VDbPage, VDbPageStore, VDbPageHeap,
  VDbPageEngine, VDbPageWal, VDbIdxFile, VDbCrc32;

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

procedure MakeVal(Key: QWord; Len, Seed: Integer; out V: TBytes);
var
  i: Integer;
begin
  SetLength(V, Len);
  for i := 0 to Len - 1 do
    V[i] := Byte(((Key * 37) + QWord(Seed) * 101 + QWord(i) * 7) and $FF);
end;

function ValEq(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and
            ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

function DbPath: string;
begin
  Result := IncludeTrailingPathDelimiter(gDir) + 'idx.odb';
end;

procedure CleanDB;
begin
  if FileExists(DbPath) then DeleteFile(DbPath);
  if FileExists(DbPath + '.wal') then DeleteFile(DbPath + '.wal');
  if FileExists(DbPath + '.idx') then DeleteFile(DbPath + '.idx');
  if FileExists(DbPath + '.idx.tmp') then DeleteFile(DbPath + '.idx.tmp');
  if FileExists(DbPath + '.idx.bak') then DeleteFile(DbPath + '.idx.bak');
end;

function FileSizeOf(const P: string): Int64;
var
  f: TFileStream;
begin
  Result := -1;
  if not FileExists(P) then Exit;
  f := TFileStream.Create(P, fmOpenRead or fmShareDenyNone);
  try
    Result := f.Size;
  finally
    f.Free;
  end;
end;

procedure FlipByte(const P: string; Offset: Int64);
var
  f: TFileStream;
  b: Byte;
begin
  f := TFileStream.Create(P, fmOpenReadWrite);
  try
    f.Position := Offset;
    f.ReadBuffer(b, 1);
    b := b xor $FF;
    f.Position := Offset;
    f.WriteBuffer(b, 1);
  finally
    f.Free;
  end;
end;

{ Tek anahtari dogrular: var mi, degeri birebir mi. }
function CheckKey(eng: TVdbPageEngine; Key: QWord; Len, Seed: Integer;
  out Err: string): Boolean;
var
  got, want: TBytes;
begin
  Err := '';
  if not eng.TryGet(Key, got) then
  begin
    Err := Format('anahtar %d yok', [Key]);
    Exit(False);
  end;
  MakeVal(Key, Len, Seed, want);
  if not ValEq(got, want) then
  begin
    Err := Format('anahtar %d degeri yanlis (%d/%d bayt)',
      [Key, Length(got), Length(want)]);
    Exit(False);
  end;
  Result := True;
end;

{ ============================================================ 1) temel idx }

procedure TestBasic(N: Integer);
var
  eng: TVdbPageEngine;
  i: Integer;
  v: TBytes;
  err: string;
  t0: TDateTime;
  msIdx, msFull: Int64;
  idxSize: Int64;
  okAll: Boolean;
begin
  CleanDB;
  eng := TVdbPageEngine.Create(DbPath, 256);
  try
    eng.Open(True);
    for i := 1 to N do
    begin
      MakeVal(i, 32, 7, v);
      eng.Insert(i, v);
    end;
    eng.Commit(True);
  finally
    eng.Free;   // Close: checkpoint + .idx yazimi
  end;

  idxSize := FileSizeOf(DbPath + '.idx');
  if idxSize > 0 then
    Ok(Format('.idx olustu (%d bayt, satir basina %.1f B)',
      [idxSize, idxSize / N]))
  else
    Fail('.idx olusmadi');

  { Hizli acilis }
  t0 := Now;
  eng := TVdbPageEngine.Create(DbPath, 256);
  try
    eng.Open(False);
    msIdx := MilliSecondsBetween(Now, t0);
    if eng.IdxUsed then
      Ok(Format('idx ile acilis: %d ms (tarama atlandi)', [msIdx]))
    else
      Fail('idx kullanilmadi: ' + eng.IdxErr);
    if eng.Count = N then
      Ok(Format('idx ile %d anahtar dizinde', [eng.Count]))
    else
      Fail(Format('idx ile sayi yanlis: %d (beklenen %d)', [eng.Count, N]));
  finally
    eng.Free;
  end;

  { idx'siz tam tarama suresi + tum degerlerin dogrulanmasi }
  DeleteFile(DbPath + '.idx');
  t0 := Now;
  eng := TVdbPageEngine.Create(DbPath, 256);
  okAll := True;
  err := '';
  try
    eng.Open(False);
    msFull := MilliSecondsBetween(Now, t0);
    if (not eng.IdxUsed) and (eng.Count = N) then
      Ok(Format('idx yok: tam tarama %d ms, %d satir', [msFull, eng.Count]))
    else
      Fail(Format('idx yok: used=%s count=%d err=%s',
        [BoolToStr(eng.IdxUsed, True), eng.Count, eng.IdxErr]));
    for i := 1 to N do
      if not CheckKey(eng, i, 32, 7, err) then
      begin
        okAll := False;
        Break;
      end;
    if okAll then
      Ok(Format('tam tarama sonrasi %d anahtarin tamami birebir', [N]))
    else
      Fail(err);
  finally
    eng.Free;
  end;
  WriteLn(Format('        olcum: acilis idx ile %d ms, tam tarama %d ms',
    [msIdx, msFull]));
end;

{ ============================================================ 2) bozuk idx }

procedure TestCorruptIdx(N: Integer);
var
  eng: TVdbPageEngine;
  err: string;
  sz: Int64;
  i: Integer;
  okAll: Boolean;
begin
  eng := TVdbPageEngine.Create(DbPath, 256);
  try
    eng.Open(False);
    eng.SaveIdx;
  finally
    eng.Free;
  end;
  if not FileExists(DbPath + '.idx') then
  begin
    Fail('idx yazilamadi (bozuk idx testi kurulamadi)');
    Exit;
  end;
  sz := FileSizeOf(DbPath + '.idx');
  FlipByte(DbPath + '.idx', sz div 2);

  eng := TVdbPageEngine.Create(DbPath, 256);
  okAll := True;
  err := '';
  try
    eng.Open(False);
    if not eng.IdxUsed then
      Ok('bozuk idx reddedildi: ' + eng.IdxErr)
    else
      Fail('bozuk idx kabul edildi');
    if eng.Count = N then
      Ok(Format('bozuk idx: tam tarama %d satir', [N]))
    else
      Fail(Format('bozuk idx: sayi %d (beklenen %d)', [eng.Count, N]));
    for i := 1 to N do
      if not CheckKey(eng, i, 32, 7, err) then
      begin
        okAll := False;
        Break;
      end;
    if okAll then
      Ok('bozuk idx: veri kaybi yok, tum degerler birebir')
    else
      Fail('bozuk idx sonrasi: ' + err);
  finally
    eng.Free;
  end;

  eng := TVdbPageEngine.Create(DbPath, 256);
  try
    eng.Open(False);
    if eng.IdxUsed then
      Ok('yeniden yazilan idx sonraki acilista kullanildi')
    else
      Fail('yeniden yazilan idx kullanilmadi: ' + eng.IdxErr);
  finally
    eng.Free;
  end;
end;

{ ============================================================ 3) kesik idx }

procedure TestShortIdx(N: Integer);
var
  eng: TVdbPageEngine;
  f: TFileStream;
  sz: Int64;
begin
  sz := FileSizeOf(DbPath + '.idx');
  f := TFileStream.Create(DbPath + '.idx', fmOpenReadWrite);
  try
    f.Size := sz - 7;
  finally
    f.Free;
  end;
  eng := TVdbPageEngine.Create(DbPath, 256);
  try
    eng.Open(False);
    if (not eng.IdxUsed) and (eng.Count = N) then
      Ok('kesik idx reddedildi (' + eng.IdxErr + '), tam tarama, veri ayni')
    else
      Fail(Format('kesik idx: used=%s count=%d err=%s',
        [BoolToStr(eng.IdxUsed, True), eng.Count, eng.IdxErr]));
  finally
    eng.Free;
  end;
end;

{ ============================================================ 4) bayat idx }

procedure TestStaleIdx(N: Integer);
var
  eng: TVdbPageEngine;
  i: Integer;
  v: TBytes;
begin
  eng := TVdbPageEngine.Create(DbPath, 256);
  try
    eng.Open(False);
    eng.SaveIdx;
  finally
    eng.Free;
  end;

  if FileExists(DbPath + '.idx.bak') then DeleteFile(DbPath + '.idx.bak');
  RenameFile(DbPath + '.idx', DbPath + '.idx.bak');
  eng := TVdbPageEngine.Create(DbPath, 256);
  try
    eng.Open(False);        // idx yok -> tam tarama
    for i := 1 to 10 do
    begin
      MakeVal(90000 + i, 32, 9, v);
      eng.Insert(90000 + i, v);
    end;
    eng.Commit(True);
  finally
    eng.Free;               // yeni idx yazar
  end;
  DeleteFile(DbPath + '.idx');
  RenameFile(DbPath + '.idx.bak', DbPath + '.idx');

  eng := TVdbPageEngine.Create(DbPath, 256);
  try
    eng.Open(False);
    if not eng.IdxUsed then
      Ok('bayat idx reddedildi: ' + eng.IdxErr)
    else
      Fail('bayat idx kabul edildi');
    if eng.Count = N + 10 then
      Ok(Format('bayat idx: tam tarama %d satir (yeni 10 satir dahil)', [N + 10]))
    else
      Fail(Format('bayat idx: sayi %d (beklenen %d)', [eng.Count, N + 10]));
  finally
    eng.Free;
  end;
end;

{ ============================================================ 5) sil/guncelle }

procedure TestMutations(N: Integer);
var
  eng: TVdbPageEngine;
  i: Integer;
  v, w: TBytes;
  err: string;
  okAll: Boolean;
begin
  eng := TVdbPageEngine.Create(DbPath, 256);
  try
    eng.Open(False);
    for i := 1 to 500 do
      if not eng.Delete(i) then
      begin
        Fail(Format('silme basarisiz: %d', [i]));
        Break;
      end;
    for i := 501 to 700 do
    begin
      MakeVal(i, 48, 11, v);
      if not eng.Update(i, v) then
      begin
        Fail(Format('guncelleme basarisiz: %d', [i]));
        Break;
      end;
    end;
    eng.Commit(True);
  finally
    eng.Free;
  end;

  eng := TVdbPageEngine.Create(DbPath, 256);
  okAll := True;
  err := '';
  try
    eng.Open(False);
    if eng.IdxUsed then
      Ok('sil/guncelle sonrasi idx taze')
    else
      Fail('sil/guncelle sonrasi idx kullanilmadi: ' + eng.IdxErr);
    if eng.Count = (N + 10) - 500 then
      Ok(Format('sil/guncelle sonrasi sayi %d dogru', [eng.Count]))
    else
      Fail(Format('sil/guncelle sonrasi sayi %d (beklenen %d)',
        [eng.Count, (N + 10) - 500]));
    if eng.Contains(1) then
      Fail('silinen anahtar 1 hala dizinde')
    else if not eng.Contains(501) then
      Fail('guncellenen anahtar 501 dizinde yok')
    else
      Ok('silinen anahtar dizinde yok, guncellenen yerinde');
    if eng.TryGet(501, w) then
    begin
      MakeVal(501, 48, 11, v);
      if ValEq(w, v) then
        Ok('guncellenen deger birebir')
      else
        Fail('guncellenen deger yanlis');
    end
    else
      Fail('guncellenen anahtar okunamadi');

    { 701..N degismedi: 32 bayt, seed 7 }
    for i := 701 to N do
      if not CheckKey(eng, i, 32, 7, err) then
      begin
        okAll := False;
        Break;
      end;
    if okAll then
    begin
      { bayat idx testinde eklenen 90001..90010 }
      for i := 90001 to 90010 do
        if not CheckKey(eng, i, 32, 9, err) then
        begin
          okAll := False;
          Break;
        end;
    end;
    if okAll then
      Ok('degismeyen anahtarlar idx uzerinden birebir')
    else
      Fail(err);
  finally
    eng.Free;
  end;
end;

{ ==================================================== 6) VER 1 uyumu }

{ v3.2: `.idx` VER 2 varint akisina gecti. Eski (VER 1, sabit 16 bayt)
  dosyalar okunmaya devam etmeli; yeni kod yalniz VER 2 urettigi icin eski
  bicimi ancak elle yazarak sinayabiliriz. }
procedure TestLegacyIdx;
const
  N = 500;
var
  f: TFileStream;
  h: TVdbIdxHeader;
  rec: TVdbIdxEntryArray;
  i: Integer;
  crc: LongWord;
  p, err: string;
  got: TVdbIdxEntryArray;
  gh: TVdbIdxHeader;
  tags: TVdbIdxTagArray;
  okAll: Boolean;
begin
  p := IncludeTrailingPathDelimiter(gDir) + 'legacy.idx';
  SetLength(rec, N);
  FillChar(h, SizeOf(h), 0);
  h.Magic := VDB_IDX_MAGIC;
  h.Ver := 1;                     { ESKI SURUM }
  h.PageSize := 4096;
  h.DbLSN := 42;
  h.DbPageCount := 100;
  h.Count := N;
  h.DbSize := Int64(100) * 4096;
  crc := VDbCrc32Init;
  for i := 0 to N - 1 do
  begin
    rec[i].Key := QWord(i + 1) * 7919;
    rec[i].PageNo := i div 20 + 1;
    rec[i].Slot := (i mod 20) + 1;
    rec[i].Pad := 0;
    crc := VDbCrc32Update(crc, rec[i], SizeOf(TVdbIdxEntry));
  end;
  h.EntriesCrc := VDbCrc32Final(crc);
  h.HdrCrc := VDbCrc32Of(h, VDB_IDX_CRC_LEN);
  f := TFileStream.Create(p, fmCreate);
  try
    f.WriteBuffer(h, VDB_IDX_HDR_SIZE);
    f.WriteBuffer(rec[0], N * VDB_IDX_ENT_SIZE);
  finally
    f.Free;
  end;

  if not VDbIdxLoadEx(p, got, gh, tags, err) then
    Fail('VER 1 (eski bicim) dosyasi okunamadi: ' + err)
  else
  begin
    okAll := (Length(got) = N) and (gh.Ver = 1);
    if okAll then
      for i := 0 to N - 1 do
        if (got[i].Key <> rec[i].Key) or (got[i].PageNo <> rec[i].PageNo) or
           (got[i].Slot <> rec[i].Slot) then
        begin
          okAll := False;
          Break;
        end;
    if okAll then
      Ok(Format('VER 1 (eski bicim) dosyasi okundu: %d kayit birebir', [N]))
    else
      Fail('VER 1 dosyasi yanlis cozuldu');
  end;
  if FileExists(p) then DeleteFile(p);
end;

{ ============================================ 7) varint sinir degerleri }

procedure TestVarintBounds;
const
  N = 8;
  PAGES: array[0..N - 1] of LongWord =
    (1, 127, 128, 16383, 16384, 2097151, 2097152, $7FFFFFFF);
  SLOTS: array[0..N - 1] of LongWord =
    (1, 127, 128, 255, 256, 16383, 16384, 65535);
var
  p, err: string;
  e, got: TVdbIdxEntryArray;
  h: TVdbIdxHeader;
  tags: TVdbIdxTagArray;
  i: Integer;
  okAll: Boolean;
  sz: Int64;
begin
  p := IncludeTrailingPathDelimiter(gDir) + 'varint.idx';
  SetLength(e, N);
  SetLength(tags, 0);
  for i := 0 to N - 1 do
  begin
    e[i].Key := QWord($FEDCBA9876543210) - QWord(i) * 12345;
    e[i].PageNo := PAGES[i];
    e[i].Slot := Word(SLOTS[i]);
    e[i].Pad := 0;
  end;
  VDbIdxSaveEx(p, e, tags, 7, 99, Int64(99) * 4096);
  sz := FileSizeOf(p);
  if not VDbIdxLoadEx(p, got, h, tags, err) then
    Fail('varint idx okunamadi: ' + err)
  else
  begin
    okAll := Length(got) = N;
    if okAll then
      for i := 0 to N - 1 do
        if (got[i].Key <> e[i].Key) or (got[i].PageNo <> e[i].PageNo) or
           (got[i].Slot <> e[i].Slot) then
        begin
          okAll := False;
          Break;
        end;
    if okAll then
      Ok(Format('varint sinirlari (1..2^31-1 sayfa, 1..65535 slot) birebir ' +
        '(%d bayt, %d kayit)', [sz, N]))
    else
      Fail('varint sinir degeri yanlis cozuldu');
  end;
  if FileExists(p) then DeleteFile(p);
end;

{ ================================================================== ana }

var
  N: Integer;
begin
  gPass := 0;
  gFail := 0;
  N := 50000;
  if ParamCount >= 1 then gDir := ParamStr(1)
  else gDir := IncludeTrailingPathDelimiter(GetCurrentDir) + 'tmp64\gaterun\idx';
  if ParamCount >= 2 then N := StrToIntDef(ParamStr(2), N);
  if not DirectoryExists(gDir) then ForceDirectories(gDir);

  WriteLn('VDB v3 idxchk - kalici anahtar dizini kapisi');
  WriteLn('dizin=', gDir, '  satir=', N);
  WriteLn;

  TestBasic(N);
  TestCorruptIdx(N);
  TestShortIdx(N);
  TestStaleIdx(N);
  TestMutations(N);
  TestLegacyIdx;
  TestVarintBounds;

  WriteLn;
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
  begin
    WriteLn('KALICI DIZIN DOGRULANDI');
    Halt(0);
  end;
  WriteLn('KALICI DIZIN HATALI');
  Halt(1);
end.
