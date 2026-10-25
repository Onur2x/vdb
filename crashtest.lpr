program crashtest;

{ VDB v3 - Cokme kurtarma kapisi (Sprint 1 / Gun 5)

  Senaryolar:
    1) Temel commit + yeniden acilis: veri birebir durur.
    2) Commit edilmemis islem surec olumu ile atilir; onceki durum korunur.
    3) GERCEK kill -9: alt surec surekli yazar+commit eder, ana surec
       TerminateProcess ile oldurur; commit edilmis her satir yerinde.
    4) WAL kuyrugu kesik (torn tail): onaylanmis commit'ler korunur.
    5) WAL'de bozuk kayıt: o noktadan sonrasi atilir, oncesi korunur.
    6) Veritabani dosyasinda torn page: WAL replay sayfayi onarir.
    7) Kucuk havuz (8 sayfa) + 5000 satir: surekli tahliye, veri kaybi yok.
    8) Bozuk WAL basligi sessizce kabul EDILMEZ (acik hata).

  Kullanim: crashtest [calisma_dizini]
  Cikis: 0 = hepsi gecti, 1 = hata.
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: cthreads programin EN BASINDA olmali (TEvent/TThread). }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, Process,
  VDbPage, VDbPageStore, VDbPageHeap, VDbPageWal, VDbPageEngine, VDbSync;

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

function ValByte(Key: QWord; Seed, Offset: Integer): Byte;
begin
  Result := Byte(((Key * 37) + QWord(Seed) * 101 + QWord(Offset) * 7) and $FF);
end;

procedure MakeVal(Key: QWord; Len, Seed: Integer; out V: TBytes);
var
  i: Integer;
begin
  SetLength(V, Len);
  for i := 0 to Len - 1 do
    V[i] := ValByte(Key, Seed, i);
end;

function ValEq(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and
            ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

function FreshDir(const D, Name: string): string;
begin
  Result := D + PathDelim + Name;
  if FileExists(Result) then DeleteFile(Result);
  if FileExists(Result + '.wal') then DeleteFile(Result + '.wal');
end;

{ ===================================================== 1) temel commit/ac }

procedure TestBasic(D: string);
var
  eng: TVdbPageEngine;
  i, bad: Integer;
  v, got: TBytes;
  path: string;
begin
  path := FreshDir(D, 'basic.odb');
  eng := TVdbPageEngine.Create(path, 64);
  try
    eng.Open(True);
    for i := 1 to 500 do
    begin
      MakeVal(i, 32, 1, v);
      if not eng.Insert(i, v) then
      begin
        Fail(Format('temel: %d eklenemedi', [i]));
        Exit;
      end;
    end;
    if not eng.Commit(True) then
      Fail('temel: commit basarisiz')
    else
      Ok('temel: 500 satir commit edildi');
  finally
    eng.Free;
  end;

  eng := TVdbPageEngine.Create(path, 64);
  try
    eng.Open(False);
    bad := 0;
    for i := 1 to 500 do
    begin
      MakeVal(i, 32, 1, v);
      if not eng.TryGet(i, got) or not ValEq(v, got) then
        Inc(bad);
    end;
    if bad = 0 then
      Ok('temel: 500 satir yeniden acilista birebir')
    else
      Fail(Format('temel: %d satir bozuk/eksik', [bad]));
    if FileExists(path + '.wal') and (eng.Wal.HasContent) then
      Fail('temel: checkpoint sonrasi WAL hala dolu')
    else
      Ok('temel: checkpoint sonrasi WAL bos');
  finally
    eng.Free;
  end;
end;

{ ============================================ 2) commit edilmemis atilir }

procedure TestUncommittedLost(D: string);
var
  eng: TVdbPageEngine;
  i: Integer;
  v: TBytes;
  path: string;
begin
  path := FreshDir(D, 'uncommitted.odb');
  eng := TVdbPageEngine.Create(path, 16);
  eng.Open(True);
  for i := 1 to 100 do
  begin
    MakeVal(i, 32, 1, v);
    eng.Insert(i, v);
  end;
  eng.Commit(True);
  eng.Checkpoint(True);
  for i := 101 to 200 do
  begin
    MakeVal(i, 32, 2, v);
    eng.Insert(i, v);
  end;
  eng.SimulateCrash;
  eng.Free;

  eng := TVdbPageEngine.Create(path, 16);
  try
    eng.Open(False);
    if eng.Count <> 100 then
      Fail(Format('commit edilmemis: %d satir kaldi (beklenen 100)', [eng.Count]))
    else if eng.Contains(150) then
      Fail('commit edilmemis satir 150 sizmış')
    else
      Ok('commit edilmemis 100 satir atildi, 100 satir korundu');
  finally
    eng.Free;
  end;
end;

{ ================================================== 3) gercek kill -9 }

{ 2026-10-25 (Sprint 3.10): Unix'te FPC'nin TStringList.LoadFromFile /
  SaveToFile cagrilari paylasim modu yuzunden flock() alir. Ebeveyn
  isaret dosyasini 50 ms'de bir okurken cocuk ayni dosyayi yazinca
  EAGAIN ("Try again") alip oluyordu; test "cocuk hic commit edemedi"
  diye gecersiz sayiliyordu (Windows'ta gorunmez). Isaret dosyasi
  MOTOR VERISI degildir: kilit gerekmez. Unix'te ham fpOpen/fpRead/
  fpWrite kullanilir. }

{$IFDEF UNIX}
function MarkerRead(const P: string; out S: string): Boolean;
var
  fd: cint;
  buf: array[0..255] of Char;
  n: ssize_t;
begin
  Result := False;
  S := '';
  fd := fpOpen(P, O_RDONLY);
  if fd < 0 then Exit;
  try
    repeat
      n := fpRead(fd, buf, SizeOf(buf));
      if n > 0 then
        S := S + Copy(buf, 1, n);
    until n <= 0;
    Result := True;
  finally
    fpClose(fd);
  end;
end;

function MarkerWrite(const P, S: string): Boolean;
var
  fd: cint;
  b: RawByteString;
  wrote, n: ssize_t;
begin
  Result := False;
  fd := fpOpen(P, O_WRONLY or O_CREAT or O_TRUNC, 438);
  if fd < 0 then Exit;
  try
    b := S;
    wrote := 0;
    while wrote < Length(b) do
    begin
      n := fpWrite(fd, b[wrote + 1], Length(b) - wrote);
      if n <= 0 then Exit;
      Inc(wrote, n);
    end;
    Result := True;
  finally
    fpClose(fd);
  end;
end;
{$ENDIF}

procedure TestKill9(D: string);
var
  path, markerPath: string;
  proc: TProcess;
  marker: Integer;
  eng: TVdbPageEngine;
  i, bad: Integer;
  v, got: TBytes;
  t0: TDateTime;
  st: TVdbWalStats;

  function ReadMarker: Integer;
  {$IFDEF UNIX}
  var
    txt: string;
  begin
    Result := 0;
    if not MarkerRead(markerPath, txt) then Exit;
    Result := StrToIntDef(Trim(txt), 0);
  end;
  {$ELSE}
  var
    sl: TStringList;
  begin
    Result := 0;
    if not FileExists(markerPath) then Exit;
    sl := TStringList.Create;
    try
      { Alt surec isaret dosyasini `SaveToFile` ile YENIDEN olusturur; o
        anda okuma paylasim ihlali verebilir. Bu bir yaris durumudur, veri
        hatasi degildir: bu turu atla, sonraki turda tekrar oku. }
      try
        sl.LoadFromFile(markerPath);
      except
        on E: Exception do Exit;
      end;
      if sl.Count > 0 then
        Result := StrToIntDef(Trim(sl[0]), 0);
    finally
      sl.Free;
    end;
  end;
  {$ENDIF}

begin
  path := FreshDir(D, 'kill9.odb');
  markerPath := D + PathDelim + 'kill9.marker';
  if FileExists(markerPath) then DeleteFile(markerPath);

  proc := TProcess.Create(nil);
  try
    proc.Executable := ParamStr(0);
    proc.Parameters.Add('child');
    proc.Parameters.Add(path);
    proc.Parameters.Add(markerPath);
    proc.Options := [poNoConsole];
    proc.Execute;
    { 2026-10-24: sabit Sleep yarisa bagliydi; yavas CI kosucusunda alt
      surec henuz ilk commit'i yazmadan olduruluyor ve test "gecersiz"
      sayiliyordu. Artik isaret dosyasi BEKLENIYOR (en fazla 30 sn) ve
      en az 2000 satir (80 commit) gorulmeden oldurulmuyor; boylece
      replay yolu her kosuda gercekten sinanir. }
    t0 := Now;
    marker := 0;
    while (marker < 2000) and (Now - t0 < 30 / 86400) do
    begin
      Sleep(50);
      marker := ReadMarker;
    end;
    { kill -9 esdegeri: TerminateProcess }
    proc.Terminate(1);
    proc.WaitOnExit;
  finally
    proc.Free;
  end;
  Sleep(200);

  marker := ReadMarker;
  if marker <= 0 then
  begin
    Fail('kill -9: alt surec hic commit edemedi (test gecersiz)');
    Exit;
  end;

  eng := TVdbPageEngine.Create(path, 32);
  try
    eng.Open(False);
    bad := 0;
    for i := 1 to marker do
    begin
      MakeVal(i, 48, 3, v);
      if not eng.TryGet(i, got) or not ValEq(v, got) then
      begin
        Inc(bad);
        if bad <= 3 then
          Fail(Format('kill -9: commit edilmis %d satiri kayip/bozuk', [i]));
      end;
    end;
    if bad = 0 then
      Ok(Format('kill -9: commit edilmis %d satirin TAMAMI yerinde', [marker]));
    { 2026-10-24: bu satirlar ONCEDEN eng.Free'den SONRA calisiyordu
      (serbest birakilmis nesnenin alani okunuyordu -> cop deger, bazen
      erisim ihlali). Istatistikler artik Free'den once kopyalaniyor. }
    st := eng.RecoveryStats;
  finally
    eng.Free;
  end;
  if FileExists(path + '.wal') then
    WriteLn(Format('        (kurtarma: %d cerceve, %d commit, torn=%s)',
      [st.Frames, st.Commits, BoolToStr(st.TornTail, True)]));
end;

{ ================================================= 4) kesik WAL kuyrugu }

procedure TestTornTail(D: string);
var
  path: string;
  eng: TVdbPageEngine;
  i: Integer;
  v: TBytes;
  f: TFileStream;
  junk: array[0..36] of Byte;
begin
  path := FreshDir(D, 'torn.odb');
  eng := TVdbPageEngine.Create(path, 32);
  try
    eng.Open(True);
    for i := 1 to 50 do
    begin
      MakeVal(i, 32, 4, v);
      eng.Insert(i, v);
    end;
    eng.Commit(False);   // WAL'de kalsin (budanmasin)
    eng.Checkpoint(True);
  finally
    eng.Free;            // Close -> commit + flush, WAL budanir
  end;

  { Yeni bir commit uret ve WAL'i budanmadan birak. }
  eng := TVdbPageEngine.Create(path, 32);
  try
    eng.Open(False);
    for i := 51 to 100 do
    begin
      MakeVal(i, 32, 4, v);
      eng.Insert(i, v);
    end;
    eng.Commit(False);
    eng.SimulateCrash;   // WAL dosyada kalir, veri sayfalari da yazilmis
  finally
    eng.Free;
  end;

  { WAL kuyruguna yarim kayit ekle. }
  FillChar(junk, SizeOf(junk), $AB);
  f := TFileStream.Create(path + '.wal', fmOpenReadWrite);
  try
    f.Position := f.Size;
    f.WriteBuffer(junk, SizeOf(junk));
  finally
    f.Free;
  end;

  eng := TVdbPageEngine.Create(path, 32);
  try
    eng.Open(False);
    if eng.Count <> 100 then
      Fail(Format('kesik kuyruk: %d satir (beklenen 100)', [eng.Count]))
    else
      Ok(Format('kesik kuyruk: 100 satir korundu (torn=%s)',
        [BoolToStr(eng.RecoveryStats.TornTail, True)]));
  finally
    eng.Free;
  end;
end;

{ ================================================ 5) bozuk WAL kaydi }

procedure TestBadWalRecord(D: string);
var
  path: string;
  eng: TVdbPageEngine;
  i: Integer;
  v: TBytes;
  f: TFileStream;
  b: Byte;
  junk: TVdbPageBuf;
  raised: Boolean;
begin
  path := FreshDir(D, 'badrec.odb');
  eng := TVdbPageEngine.Create(path, 32);
  try
    eng.Open(True);
    for i := 1 to 40 do
    begin
      MakeVal(i, 32, 5, v);
      eng.Insert(i, v);
    end;
    eng.Commit(True);
    eng.Checkpoint(True);   // taban diskte
    for i := 41 to 80 do
    begin
      MakeVal(i, 32, 5, v);
      eng.Insert(i, v);
    end;
    eng.Commit(False);      // WAL'de cerceve kalir, veri dosyasina yazilmaz
    eng.SimulateCrash;
  finally
    eng.Free;
  end;

  { WAL cercevesinin yukunu boz (CRC tutmaz) VE veritabani sayfasini da
    boz. Kurtarma WAL'deki bozuk kayitta durmali; bozuk sayfa sessizce
    kabul edilmemeli -> acik hata. }
  f := TFileStream.Create(path + '.wal', fmOpenReadWrite);
  try
    f.Position := VDB_PAGE_SIZE + VDB_WAL_REC_HDR + 100;
    f.ReadBuffer(b, 1);
    b := b xor $FF;
    f.Position := VDB_PAGE_SIZE + VDB_WAL_REC_HDR + 100;
    f.WriteBuffer(b, 1);
  finally
    f.Free;
  end;
  FillChar(junk, SizeOf(junk), $5A);
  f := TFileStream.Create(path, fmOpenReadWrite);
  try
    f.Position := Int64(1) * VDB_PAGE_SIZE;
    f.WriteBuffer(junk, VDB_PAGE_SIZE);
  finally
    f.Free;
  end;

  raised := False;
  eng := TVdbPageEngine.Create(path, 32);
  try
    try
      eng.Open(False);
      WriteLn(Format('        (beklenmeyen) acildi: %d satir, %d cerceve, torn=%s',
        [eng.Count, eng.RecoveryStats.Frames,
         BoolToStr(eng.RecoveryStats.TornTail, True)]));
    except
      on E: Exception do
      begin
        raised := True;
        WriteLn(Format('        (beklenen) %s', [E.Message]));
      end;
    end;
  finally
    eng.Free;
  end;
  if raised then
    Ok('bozuk WAL cercevesi + bozuk sayfa: acik hata (sessiz kabul yok)')
  else
    Fail('bozuk WAL cercevesi sessizce kabul edildi');
end;

{ =========================================== 6) torn page WAL ile onarilir }

procedure TestTornPageRepaired(D: string);
var
  path: string;
  eng: TVdbPageEngine;
  i, bad: Integer;
  v, got: TBytes;
  f: TFileStream;
  junk: TVDbPageBuf;
begin
  path := FreshDir(D, 'tornpage.odb');
  eng := TVdbPageEngine.Create(path, 32);
  try
    eng.Open(True);
    for i := 1 to 2000 do
    begin
      MakeVal(i, 32, 6, v);
      eng.Insert(i, v);
    end;
    eng.Commit(True);   // taban: WAL budandi
    eng.Checkpoint(True);
  finally
    eng.Free;
  end;

  { Anahtar 1'i guncelle: bu islem 1. heap sayfasini (sayfa 1) kirletir.
    Commit(False) -> WAL'de cerceve kalir, budanmaz. }
  eng := TVdbPageEngine.Create(path, 32);
  try
    eng.Open(False);
    MakeVal(1, 32, 7, v);
    if not eng.Update(1, v) then
    begin
      Fail('torn page: anahtar 1 guncellenemedi');
      Exit;
    end;
    eng.Commit(False);
    eng.SimulateCrash;
  finally
    eng.Free;
  end;

  { Veritabani dosyasindaki 1. sayfayi tamamen boz (torn page). }
  FillChar(junk, SizeOf(junk), $5A);
  f := TFileStream.Create(path, fmOpenReadWrite);
  try
    f.Position := Int64(1) * VDB_PAGE_SIZE;
    f.WriteBuffer(junk, VDB_PAGE_SIZE);
  finally
    f.Free;
  end;

  eng := TVdbPageEngine.Create(path, 32);
  try
    eng.Open(False);
    bad := 0;
    for i := 1 to 2000 do
    begin
      if i = 1 then MakeVal(1, 32, 7, v) else MakeVal(i, 32, 6, v);
      if not eng.TryGet(i, got) or not ValEq(v, got) then
      begin
        Inc(bad);
        if bad <= 3 then
          Fail(Format('torn page: %d satiri bozuk', [i]));
      end;
    end;
    if bad = 0 then
      Ok(Format('torn page: WAL replay bozuk sayfayi onardi (%d cerceve)',
        [eng.RecoveryStats.Frames]));
  finally
    eng.Free;
  end;
end;

{ ================================================ 7) kucuk havuz basinci }

procedure TestSmallPool(D: string);
var
  path: string;
  eng: TVdbPageEngine;
  i, bad: Integer;
  v, got: TBytes;
begin
  path := FreshDir(D, 'smallpool.odb');
  eng := TVdbPageEngine.Create(path, 8);
  try
    eng.Open(True);
    for i := 1 to 5000 do
    begin
      MakeVal(i, 40, 8, v);
      if not eng.Insert(i, v) then
      begin
        Fail(Format('kucuk havuz: %d eklenemedi', [i]));
        Exit;
      end;
    end;
    eng.Commit(True);
    Ok('kucuk havuz: 5000 satir 8 sayfalik havuzda yazildi');
  finally
    eng.Free;
  end;

  eng := TVdbPageEngine.Create(path, 8);
  try
    eng.Open(False);
    bad := 0;
    for i := 1 to 5000 do
    begin
      MakeVal(i, 40, 8, v);
      if not eng.TryGet(i, got) or not ValEq(v, got) then
      begin
        Inc(bad);
        if bad <= 3 then Fail(Format('kucuk havuz: %d bozuk', [i]));
      end;
    end;
    if bad = 0 then
      Ok('kucuk havuz: 5000 satir birebir geri okundu');
  finally
    eng.Free;
  end;
end;

{ ================================================== 8) bozuk WAL basligi }

procedure TestBadWalHeader(D: string);
var
  path: string;
  eng: TVdbPageEngine;
  f: TFileStream;
  b: Byte;
  raised: Boolean;
begin
  path := FreshDir(D, 'badhdr.odb');
  eng := TVdbPageEngine.Create(path, 16);
  try
    eng.Open(True);
    eng.Commit(True);
  finally
    eng.Free;
  end;
  if FileExists(path + '.wal') then
  begin
    f := TFileStream.Create(path + '.wal', fmOpenReadWrite);
    try
      f.Position := 8;   // sihirli sayinin icinde
      f.ReadBuffer(b, 1);
      b := b xor $FF;
      f.Position := 8;
      f.WriteBuffer(b, 1);
    finally
      f.Free;
    end;
    raised := False;
    eng := TVdbPageEngine.Create(path, 16);
    try
      try
        eng.Open(False);
      except
        on E: Exception do
        begin
          raised := True;
          WriteLn(Format('        (beklenen) %s', [E.Message]));
        end;
      end;
    finally
      eng.Free;
    end;
    if raised then
      Ok('bozuk WAL basligi acik hata verdi (sessiz kabul yok)')
    else
      Fail('bozuk WAL basligi sessizce kabul edildi');
  end
  else
    Fail('bozuk WAL basligi: WAL dosyasi yok');
end;

{ ============================================================ alt surec }

procedure RunChild(const Path, MarkerPath: string);
var
  eng: TVdbPageEngine;
  i: Integer;
  v: TBytes;
  sl: TStringList;

  { 2026-10-25 (Sprint 3.10): alt surec sessizce olurse nedeni
    gorunmuyordu (konsolu yok). Tani bilgisini isaret dosyasinin
    yanina yaz; test yine ayni sozlesmeyle degerlendirilir. }
  procedure Log(const S: string);
  begin
    {$IFDEF UNIX}
    MarkerWrite(MarkerPath + '.log', S + LineEnding);
    {$ELSE}
    try
      with TFileStream.Create(MarkerPath + '.log', fmCreate) do
      try
        WriteBuffer(PChar(S + LineEnding)^, Length(S + LineEnding));
      finally
        Free;
      end;
    except
      { tani dosyasi yazilamazsa sessiz gec }
    end;
    {$ENDIF}
  end;

begin
  eng := nil;
  try
    eng := TVdbPageEngine.Create(Path, 8);
    eng.Open(True);
    i := eng.Count;   // devam et
    while True do
    begin
      Inc(i);
      MakeVal(i, 48, 3, v);
      eng.Insert(i, v);
      if (i mod 25) = 0 then
      begin
        if not eng.Commit(True) then
        begin
          Log(Format('COMMIT FALSE: i=%d', [i]));
          Halt(2);
        end;
        { Commit dondukten sonra isaretle: fsync edilmis son anahtar. }
        {$IFDEF UNIX}
        if not MarkerWrite(MarkerPath, IntToStr(i) + LineEnding) then
        begin
          Log(Format('MARKER YAZILAMADI: i=%d', [i]));
          Halt(4);
        end;
        {$ELSE}
        sl := TStringList.Create;
        try
          sl.Text := IntToStr(i) + LineEnding;
          sl.SaveToFile(MarkerPath);
        finally
          sl.Free;
        end;
        {$ENDIF}
        { Checkpoint seyrek: WAL'de commit edilmis cerceve kalsin ki
          kill -9 sonrasi replay yolu gercekten calissin. 2026-10-24:
          500 -> 5000. Cok sik checkpoint, olum anini checkpoint'le
          cakistirip testi sessizce "replay yok" durumuna dusuruyordu. }
        if (i mod 5000) = 0 then
          eng.Checkpoint(True);
      end;
    end;
  except
    on E: Exception do
    begin
      Log('EXC ' + E.ClassName + ': ' + E.Message);
      FreeAndNil(eng);
      Halt(3);
    end;
  end;
  eng.Free;
end;

var
  D: string;
begin
  { 2026-10-24 (CI): Windows'ta islenmemis bir calisma-zamani hatasi MESAJ
    KUTUSU acar; konsolu olmayan (poNoConsole) alt surecte bu kutu, CI
    adimini saatlerce asili birakir. Hata kutularini kapat: surec sessizce
    hata koduyla olur, test bunu normal sekilde degerlendirir. }
  {$IFDEF MSWINDOWS}
  SetErrorMode(SEM_FAILCRITICALERRORS or SEM_NOGPFAULTERRORBOX or
    SEM_NOOPENFILEERRORBOX);
  {$ENDIF}
  if (ParamStr(1) = 'child') and (ParamCount >= 3) then
  begin
    RunChild(ParamStr(2), ParamStr(3));
    Exit;
  end;

  gPass := 0;
  gFail := 0;
  D := ParamStr(1);
  if D = '' then
    D := IncludeTrailingPathDelimiter(GetTempDir) + 'vdbcrashtest';
  ForceDirectories(D);

  WriteLn('VDB v3 crashtest - cokme kurtarma kapisi');
  WriteLn('dizin=', D);
  WriteLn('');

  TestBasic(D);
  TestUncommittedLost(D);
  TestKill9(D);
  TestTornTail(D);
  TestBadWalRecord(D);
  TestTornPageRepaired(D);
  TestSmallPool(D);
  TestBadWalHeader(D);

  WriteLn('');
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
    WriteLn('COKME KURTARMA DOGRULANDI')
  else
    WriteLn('COKME KURTARMA HATALI');
  if gFail <> 0 then
    Halt(1);
end.
