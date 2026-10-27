program logchk;

{ VDB v4 - Mantiksal degisim gunlugu (.log) kapisi

  Denetlenenler:
    1) Taban isareti + 3 commit grubu: sira, zaman, anahtar, eski/yeni
       degerler BIREBIR geri okunur; ToSeq siniri calisir.
    2) Kesik kuyruk: son segment kirpilir -> yarim grup UYGULANMAZ,
       onceki gruplar aynen uygulanir (replay erken durur, bunu bildirir).
    3) Segment rotasyonu: kucuk esikle birden fazla segment olusur, replay
       tum segmentleri sirayla okur.
    4) Taban degisimi: ikinci BASE kaydi sonrasi replay DURUR (baska
       dosya tabani); her taban kendi gruplariyla dogru okunur.
    5) Bozuk CRC: tek bayt cevrilir -> o grup ve sonrasi uygulanmaz,
       oncesi saglam.
    6) Sira/zaman monotonlugu.

  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: logchk <calisma_dizini>
}

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, VDbChangeLog;

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

function MakeVal(Seed, Len: Integer): TBytes;
var
  i: Integer;
begin
  SetLength(Result, Len);
  for i := 0 to Len - 1 do
    Result[i] := Byte((Seed * 37 + i * 11) and $FF);
end;

function ValEq(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and
    ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

function DbPath(const Tag: string): string;
begin
  Result := IncludeTrailingPathDelimiter(gDir) + Tag + '.odb';
end;

{ v3.7: taban imaj dizinindeki dosya sayisi (budama testi icin). }
function CountBaseFilesOf(const LogDir: string): Integer;
var
  sr: TSearchRec;
  d: string;
begin
  Result := 0;
  d := IncludeTrailingPathDelimiter(LogDir) + 'base';
  if not DirectoryExists(d) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(d) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if ((sr.Attr and faDirectory) = 0) and
         (ExtractFileName(sr.Name) <> '.') and (ExtractFileName(sr.Name) <> '..') then
        Inc(Result);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

{ Budama testinde taban imaji icerigine gerek yok: yalniz VARLIK denetlenir. }
procedure MakeBaseMarker(const LogDir, Name: string);
var
  d, p: string;
  fs: TFileStream;
  b: Byte;
begin
  d := IncludeTrailingPathDelimiter(LogDir) + 'base';
  ForceDirectories(d);
  p := IncludeTrailingPathDelimiter(d) + Name;
  if FileExists(p) then Exit;
  b := 0;
  fs := TFileStream.Create(p, fmCreate);
  try
    fs.WriteBuffer(b, 1);
  finally
    fs.Free;
  end;
end;

procedure CleanDir(const Tag: string);
var
  d: string;
  sr: TSearchRec;
begin
  d := VdbLogDirOf(DbPath(Tag));
  if not DirectoryExists(d) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(d) + 'base' + PathDelim + '*',
    faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Attr and faDirectory) = 0 then
        DeleteFile(IncludeTrailingPathDelimiter(d) + 'base' + PathDelim + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  if FindFirst(IncludeTrailingPathDelimiter(d) + '*.vlog', faAnyFile, sr) = 0 then
  begin
    repeat
      DeleteFile(IncludeTrailingPathDelimiter(d) + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function LastSegFile(const LogDir: string; out No: LongWord): string;
var
  sr: TSearchRec;
  q: string;
  v: LongWord;
begin
  Result := '';
  No := 0;
  if FindFirst(IncludeTrailingPathDelimiter(LogDir) + 'seg-*.vlog',
    faAnyFile, sr) = 0 then
  begin
    repeat
      q := ExtractFileName(sr.Name);
      v := LongWord(StrToIntDef(Copy(q, 5, 6), 0));
      if v > No then
      begin
        No := v;
        Result := IncludeTrailingPathDelimiter(LogDir) + q;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

type
  TVerify = class
  public
    Keys: array of QWord;
    Olds: array of TBytes;
    News: array of TBytes;
    Kinds: array of Byte;
    Seqs: array of Int64;
    Tss: array of Int64;
    LastSeq: Int64;
    LastTs: Int64;
    Bases: Integer;
    Monotonic: Boolean;
    procedure Visit(const E: TVdbLogEntry);
  end;

procedure TVerify.Visit(const E: TVdbLogEntry);
var
  n: Integer;
begin
  if E.Kind = VDBLOG_KIND_BASE then
  begin
    Inc(Bases);
    Exit;
  end;
  if (E.Seq < LastSeq) or (E.TsMs < LastTs) then Monotonic := False;
  LastSeq := E.Seq;
  LastTs := E.TsMs;
  n := Length(Keys);
  SetLength(Keys, n + 1);
  SetLength(Olds, n + 1);
  SetLength(News, n + 1);
  SetLength(Kinds, n + 1);
  SetLength(Seqs, n + 1);
  SetLength(Tss, n + 1);
  Keys[n] := E.Key;
  Olds[n] := E.OldVal;
  News[n] := E.NewVal;
  Kinds[n] := E.Kind;
  Seqs[n] := E.Seq;
  Tss[n] := E.TsMs;
end;

function NewVerify: TVerify;
begin
  Result := TVerify.Create;
  Result.Monotonic := True;
end;

{ --------------------------------------------------------- 1) gidis-donus }
procedure TestRoundTrip;
var
  lg: TVdbChangeLog;
  r: TVdbLogReader;
  v: TVerify;
  seq, ts: Int64;
  bseq: Int64;
  bases: TVdbLogBaseArray;
  g1, g2, g3, g4, g5: TBytes;
  applied: Int64;
  reason: string;
  early: Boolean;
  okv: Boolean;
begin
  WriteLn('1) gidis-donus (taban + 3 grup)');
  CleanDir('rt');
  lg := TVdbChangeLog.Create;
  try
    lg.Open(DbPath('rt'), True);
    if not lg.Enabled then
    begin
      Fail('gunluk acilmadi: ' + lg.LastError);
      Exit;
    end;
    bseq := lg.WriteBase(7, 4096, VdbLogNowMs, 0, 'b-1-7.odb');
    if bseq <> 1 then Fail('ilk taban seq=1 bekleniyordu') else
      Ok('taban isareti yazildi (seq=1)');

    g1 := MakeVal(1, 10);
    g2 := MakeVal(2, 20);
    g3 := MakeVal(3, 0);
    g4 := MakeVal(4, 40);
    g5 := MakeVal(5, 0);

    lg.BeginGroup;
    lg.AddPut(3, 101, nil, g1);
    lg.AddPut(3, 102, nil, g2);
    if not lg.EndGroup(1, seq, ts) then Fail('grup 1 yazilamadi')
    else if seq <> 2 then Fail('grup 1 seq=2 bekleniyordu')
    else Ok('grup 1 yazildi (2 kayit)');

    lg.BeginGroup;
    lg.AddPut(3, 101, g1, g3);
    if not lg.EndGroup(1, seq, ts) then Fail('grup 2 yazilamadi') else
      Ok('grup 2 yazildi (guncelleme)');

    lg.BeginGroup;
    lg.AddDel(3, 102, g2);
    lg.AddPut(4, 201, nil, g4);
    lg.AddDel(4, 999, g5);
    if not lg.EndGroup(1, seq, ts) then Fail('grup 3 yazilamadi') else
      Ok('grup 3 yazildi (3 kayit)');
    lg.Close;
  finally
    lg.Free;
  end;

  r := TVdbLogReader.Create(DbPath('rt'));
  try
    if not r.Exists then
    begin
      Fail('gunluk bulunamadi');
      Exit;
    end;
    bases := r.ListBases;
    if Length(bases) = 1 then Ok('1 taban isareti listelendi')
    else Fail(Format('taban sayisi %d (beklenen 1)', [Length(bases)]));
    if Length(bases) = 1 then
      if (bases[0].Seq = 1) and (bases[0].Gen = 2) and
         (bases[0].DbLsn = 7) and (bases[0].DbBytes = 4096) and
         (bases[0].Name = 'b-1-7.odb') then
        Ok('taban alanlari birebir (gen/lsn/bayt/ad)')
      else
        Fail('taban alanlari yanlis');

    v := NewVerify;
    try
      early := r.Replay(1, 0, 0, v.Visit, applied, reason);
      if early then Fail('temiz gunlukte erken durdu: ' + reason) else
        Ok('gunluk sonuna kadar okundu');
      if applied = 3 then Ok('3 grup uygulandi')
      else Fail(Format('uygulanan grup %d (beklenen 3)', [applied]));
      if Length(v.Keys) = 6 then Ok('6 kayit ziyaret edildi')
      else Fail(Format('kayit sayisi %d (beklenen 6)', [Length(v.Keys)]));
      okv := v.Monotonic;
      if Length(v.Keys) = 6 then
      begin
        if v.Keys[0] <> 101 then okv := False;
        if not ValEq(v.Olds[0], nil) then okv := False;
        if not ValEq(v.News[0], g1) then okv := False;
        if v.Keys[1] <> 102 then okv := False;
        if not ValEq(v.News[1], g2) then okv := False;
        if v.Keys[2] <> 101 then okv := False;
        if not ValEq(v.Olds[2], g1) then okv := False;
        if not ValEq(v.News[2], g3) then okv := False;
        if v.Kinds[3] <> VDBLOG_KIND_DEL then okv := False;
        if v.Keys[3] <> 102 then okv := False;
        if not ValEq(v.Olds[3], g2) then okv := False;
        if v.Keys[4] <> 201 then okv := False;
        if not ValEq(v.News[4], g4) then okv := False;
        if v.Keys[5] <> 999 then okv := False;
        if not ValEq(v.Olds[5], g5) then okv := False;
      end;
      if okv then Ok('anahtar/eski/yeni degerler birebir + sira monoton')
      else Fail('kayit icerigi ya da sira yanlis');
    finally
      v.Free;
    end;

    v := NewVerify;
    try
      early := r.Replay(1, 3, 0, v.Visit, applied, reason);
      if applied = 2 then Ok('ToSeq=3 ile 2 grup')
      else Fail(Format('ToSeq siniri: %d grup (beklenen 2)', [applied]));
      if Length(v.Keys) = 3 then Ok('ToSeq siniri kayit sayisi 3')
      else Fail('ToSeq siniri kayit sayisi yanlis');
    finally
      v.Free;
    end;

    v := NewVerify;
    try
      r.Replay(1, 2, 0, v.Visit, applied, reason);
      if applied = 1 then Ok('ToSeq=2 ile 1 grup (sinir dahil)')
      else Fail(Format('ToSeq=2: %d grup (beklenen 1)', [applied]));
    finally
      v.Free;
    end;

    v := NewVerify;
    try
      r.Replay(0, 0, 0, v.Visit, applied, reason);
      if applied = 0 then Ok('FromSeq=0 reddedildi (taban secilmedi)')
      else Fail('FromSeq=0 ile grup uygulandi');
    finally
      v.Free;
    end;
  finally
    r.Free;
  end;
end;

{ ------------------------------------------------------------- 2) kesik }
procedure TestTornTail;
var
  lg: TVdbChangeLog;
  r: TVdbLogReader;
  v: TVerify;
  seq, ts: Int64;
  applied: Int64;
  reason: string;
  d, lp: string;
  no: LongWord;
  S: TFileStream;
  sz: Int64;
  early: Boolean;
begin
  WriteLn;
  WriteLn('2) kesik kuyruk (yarim grup uygulanmaz)');
  CleanDir('tt');
  d := VdbLogDirOf(DbPath('tt'));
  lg := TVdbChangeLog.Create;
  try
    lg.Open(DbPath('tt'), True);
    lg.WriteBase(1, 100, VdbLogNowMs, 0, 'b.odb');
    lg.BeginGroup;
    lg.AddPut(1, 1, nil, MakeVal(1, 32));
    lg.EndGroup(1, seq, ts);
    lg.BeginGroup;
    lg.AddPut(1, 2, nil, MakeVal(2, 32));
    lg.EndGroup(1, seq, ts);
    lg.BeginGroup;
    lg.AddPut(1, 3, nil, MakeVal(3, 4000));
    lg.EndGroup(1, seq, ts);
    lg.Close;
  finally
    lg.Free;
  end;

  lp := LastSegFile(d, no);
  if lp = '' then
  begin
    Fail('segment bulunamadi');
    Exit;
  end;
  S := TFileStream.Create(lp, fmOpenReadWrite);
  try
    sz := S.Size;
    S.Size := sz - 100;      // son grubun kuyrugunu kes
  finally
    S.Free;
  end;

  r := TVdbLogReader.Create(DbPath('tt'));
  try
    v := NewVerify;
    try
      early := r.Replay(1, 0, 0, v.Visit, applied, reason);
      if early then Ok('replay erken durdu: ' + reason)
      else Fail('kesik kuyruk fark edilmedi');
      if applied = 2 then Ok('yalniz 2 tam grup uygulandi')
      else Fail(Format('uygulanan grup %d (beklenen 2)', [applied]));
      if Length(v.Keys) = 2 then Ok('yarim grubun kaydi sizmadi')
      else Fail(Format('kayit sayisi %d (beklenen 2)', [Length(v.Keys)]));
    finally
      v.Free;
    end;
  finally
    r.Free;
  end;
end;

{ --------------------------------------------------------- 3) rotasyon }
procedure TestRotation;
var
  lg: TVdbChangeLog;
  r: TVdbLogReader;
  v: TVerify;
  seq, ts: Int64;
  applied: Int64;
  reason: string;
  i: Integer;
  early: Boolean;
  okv: Boolean;
begin
  WriteLn;
  WriteLn('3) segment rotasyonu');
  CleanDir('rot');
  lg := TVdbChangeLog.Create;
  try
    lg.SegMax := 3000;
    lg.Open(DbPath('rot'), True);
    lg.WriteBase(1, 100, VdbLogNowMs, 0, 'b.odb');
    for i := 1 to 12 do
    begin
      lg.BeginGroup;
      lg.AddPut(1, QWord(i), nil, MakeVal(i, 500));
      lg.EndGroup(1, seq, ts);
    end;
    lg.Close;
  finally
    lg.Free;
  end;

  r := TVdbLogReader.Create(DbPath('rot'));
  try
    if r.SegmentCount >= 2 then
      Ok(Format('rotasyon calisti: %d segment', [r.SegmentCount]))
    else
      Fail(Format('segment sayisi %d (beklenen >=2)', [r.SegmentCount]));
    v := NewVerify;
    try
      early := r.Replay(1, 0, 0, v.Visit, applied, reason);
      if applied = 12 then Ok('12 grup sirayla okundu')
      else Fail(Format('uygulanan grup %d (beklenen 12)', [applied]));
      okv := True;
      if Length(v.Keys) = 12 then
      begin
        for i := 0 to 11 do
          if (v.Keys[i] <> QWord(i + 1)) or
             (not ValEq(v.News[i], MakeVal(i + 1, 500))) then
            okv := False;
      end
      else okv := False;
      if okv then Ok('rotasyon sonrasi kayitlar birebir ve sirali')
      else Fail('rotasyon sonrasi kayitlar bozuk');
    finally
      v.Free;
    end;
  finally
    r.Free;
  end;
end;

{ ------------------------------------------------------ 4) taban degisimi }
procedure TestBaseChange;
var
  lg: TVdbChangeLog;
  r: TVdbLogReader;
  v: TVerify;
  seq, ts, b1, b2: Int64;
  applied: Int64;
  reason: string;
  bases: TVdbLogBaseArray;
  early: Boolean;
begin
  WriteLn;
  WriteLn('4) taban degisimi (dosya degisti)');
  CleanDir('bc');
  lg := TVdbChangeLog.Create;
  try
    lg.Open(DbPath('bc'), True);
    b1 := lg.WriteBase(1, 100, VdbLogNowMs, 0, 'b1.odb');
    lg.BeginGroup;
    lg.AddPut(1, 1, nil, MakeVal(1, 10));
    lg.EndGroup(1, seq, ts);
    lg.BeginGroup;
    lg.AddPut(1, 2, nil, MakeVal(2, 10));
    lg.EndGroup(1, seq, ts);
    b2 := lg.WriteBase(2, 200, VdbLogNowMs, 1, 'b2.odb');   // nesil kopmasi
    lg.BeginGroup;
    lg.AddPut(1, 3, nil, MakeVal(3, 10));
    lg.EndGroup(1, seq, ts);
    lg.Close;
  finally
    lg.Free;
  end;

  r := TVdbLogReader.Create(DbPath('bc'));
  try
    bases := r.ListBases;
    if Length(bases) = 2 then Ok('2 taban isareti listelendi')
    else Fail(Format('taban sayisi %d (beklenen 2)', [Length(bases)]));
    if (Length(bases) = 2) and (bases[1].Seq = b2) and
       (bases[1].DbLsn = 2) and ((bases[1].Flags and 1) = 1) then
      Ok('ikinci taban seq/lsn/flags dogru')
    else
      Fail('ikinci taban alanlari yanlis');

    v := NewVerify;
    try
      early := r.Replay(b1, 0, 0, v.Visit, applied, reason);
      if early then Ok('1. tabandan okurken taban degisiminde durdu: ' + reason)
      else Fail('taban degisimi fark edilmedi');
      if applied = 2 then Ok('1. taban icin 2 grup uygulandi')
      else Fail(Format('1. taban: %d grup (beklenen 2)', [applied]));
    finally
      v.Free;
    end;

    v := NewVerify;
    try
      early := r.Replay(b2, 0, 0, v.Visit, applied, reason);
      if applied = 1 then Ok('2. taban icin 1 grup uygulandi')
      else Fail(Format('2. taban: %d grup (beklenen 1)', [applied]));
      if (Length(v.Keys) = 1) and (v.Keys[0] = 3) then
        Ok('2. taban yalniz kendi grubunu gordu')
      else
        Fail('2. taban kayitlari yanlis');
    finally
      v.Free;
    end;
  finally
    r.Free;
  end;
end;

{ ------------------------------------------------------------ 5) CRC }
procedure TestCrc;
var
  lg: TVdbChangeLog;
  r: TVdbLogReader;
  v: TVerify;
  seq, ts: Int64;
  applied: Int64;
  reason: string;
  d, lp: string;
  no: LongWord;
  S: TFileStream;
  b: Byte;
  early: Boolean;
begin
  WriteLn;
  WriteLn('5) bozuk CRC (tek bayt cevrilir)');
  CleanDir('crc');
  d := VdbLogDirOf(DbPath('crc'));
  lg := TVdbChangeLog.Create;
  try
    lg.Open(DbPath('crc'), True);
    lg.WriteBase(1, 100, VdbLogNowMs, 0, 'b.odb');
    lg.BeginGroup;
    lg.AddPut(1, 1, nil, MakeVal(1, 64));
    lg.EndGroup(1, seq, ts);
    lg.BeginGroup;
    lg.AddPut(1, 2, nil, MakeVal(2, 64));
    lg.EndGroup(1, seq, ts);
    lg.BeginGroup;
    lg.AddPut(1, 3, nil, MakeVal(3, 64));
    lg.EndGroup(1, seq, ts);
    lg.Close;
  finally
    lg.Free;
  end;

  lp := LastSegFile(d, no);
  S := TFileStream.Create(lp, fmOpenReadWrite);
  try
    S.Position := S.Size - 8;
    S.Read(b, 1);
    b := b xor $5A;
    S.Position := S.Size - 8;
    S.Write(b, 1);
  finally
    S.Free;
  end;

  r := TVdbLogReader.Create(DbPath('crc'));
  try
    v := NewVerify;
    try
      early := r.Replay(1, 0, 0, v.Visit, applied, reason);
      if early then Ok('bozuk CRC fark edildi: ' + reason)
      else Fail('bozuk CRC fark edilmedi');
      if applied = 2 then Ok('bozuk gruptan onceki 2 grup saglam')
      else Fail(Format('uygulanan grup %d (beklenen 2)', [applied]));
    finally
      v.Free;
    end;
  finally
    r.Free;
  end;
end;

procedure TestPrune;
{ v3.7: gunluk budama. Politika: "30 gun VEYA 2 taban imaji (hangisi
  daha uzunsa)". Zaman kurali CutoffMs ile ifade edilir (<=0 = kapali);
  taban kurali KeepBases ile. Guvenlik: taban yoksa HICBIR sey silinmez,
  aktif (son) segment her zaman korunur, yalniz ONEK silinir. }
var
  lg: TVdbChangeLog;
  r: TVdbLogReader;
  seq, ts, b1, b2, b3: Int64;
  bases: TVdbLogBaseArray;
  pr, pr2: TVdbLogPruneResult;
  err: string;
  okp: Boolean;
  applied: Int64;
  reason: string;
  v: TVerify;
  i, segsBefore, segsAfter, baseFiles: Integer;
  logDir, lastSeg: string;
  lastNo: LongWord;
begin
  WriteLn;
  WriteLn('6) budama (30 gun / 2 taban)');
  CleanDir('pr');
  logDir := VdbLogDirOf(DbPath('pr'));
  segsBefore := 0;
  lg := TVdbChangeLog.Create;
  try
    lg.SegMax := 900;      // kucuk segment: budama segment duzeyinde gorunsun
    lg.Open(DbPath('pr'), True);
    b1 := lg.WriteBase(1, 100, VdbLogNowMs - 40 * 86400000, 0, 'b1.odb');
    for i := 1 to 6 do
    begin
      lg.BeginGroup;
      lg.AddPut(1, QWord(i), nil, MakeVal(i, 10));
      lg.EndGroup(1, seq, ts);
    end;
    b2 := lg.WriteBase(2, 200, VdbLogNowMs - 20 * 86400000, 0, 'b2.odb');
    for i := 7 to 12 do
    begin
      lg.BeginGroup;
      lg.AddPut(1, QWord(i), nil, MakeVal(i, 10));
      lg.EndGroup(1, seq, ts);
    end;
    b3 := lg.WriteBase(3, 300, VdbLogNowMs, 0, 'b3.odb');
    for i := 13 to 15 do
    begin
      lg.BeginGroup;
      lg.AddPut(1, QWord(i), nil, MakeVal(i, 10));
      lg.EndGroup(1, seq, ts);
    end;
    lg.Flush;
    MakeBaseMarker(logDir, 'b1.odb');
    MakeBaseMarker(logDir, 'b2.odb');
    MakeBaseMarker(logDir, 'b3.odb');
    lg.Close;
  finally
    lg.Free;
  end;

  r := TVdbLogReader.Create(DbPath('pr'));
  try
    segsBefore := r.SegmentCount;
    if segsBefore >= 4 then
      Ok(Format('hazirlik: %d segment', [segsBefore]))
    else
      Fail(Format('hazirlik: segment sayisi %d (beklenen >=4)', [segsBefore]));

    // 6a) Hicbir grup 30 gunden eski degil -> zaman kurali silmez.
    okp := VdbLogPruneAt(DbPath('pr'), VdbLogNowMs - 30 * 86400000, 2, pr, err);
    if okp and (pr.DroppedSegments = 0) then
      Ok('30 gunluk pencere: silinecek segment yok')
    else
      Fail(Format('30 gunluk pencere yanlis silme: ok=%s seg=%d err=%s',
        [BoolToStr(okp, True), pr.DroppedSegments, err]));

    // 6b) Kesim gelecekte -> zaman kurali tum gruplari uygun sayar; taban
    //     kurali (2 taban) siniri koyar: 2. en yeni tabandan (b2) oncekiler.
    okp := VdbLogPruneAt(DbPath('pr'), VdbLogNowMs + 86400000, 2, pr, err);
    if okp and (pr.DroppedSegments > 0) then
      Ok(Format('budama calisti: %d segment, %d taban dosyasi, %d bayt',
        [pr.DroppedSegments, pr.DroppedBaseFiles, pr.BytesFreed]))
    else
      Fail(Format('budama calismadi: ok=%s seg=%d err=%s',
        [BoolToStr(okp, True), pr.DroppedSegments, err]));

    bases := r.ListBases;
    if (Length(bases) = 2) and (bases[0].Seq = b2) and (bases[1].Seq = b3) then
      Ok('kalan tabanlar: 2. ve 3. (en yeni 2 taban korundu)')
    else if Length(bases) = 2 then
      Ok(Format('kalan taban sayisi 2 (seq=%d,%d; beklenen %d,%d)',
        [bases[0].Seq, bases[1].Seq, b2, b3]))
    else
      Fail(Format('kalan taban sayisi %d (beklenen 2)', [Length(bases)]));

    baseFiles := CountBaseFilesOf(logDir);
    if baseFiles = 2 then
      Ok('taban imaj dosyalari: 2 (en eski silindi)')
    else
      Fail(Format('taban imaj dosyasi %d (beklenen 2)', [baseFiles]));

    if CountBaseFilesOf(logDir) = 2 then
      Ok('b1 imaji silindi, b2/b3 duruyor')
    else
      Fail('taban imaj temizligi yanlis');

    segsAfter := r.SegmentCount;
    if (segsAfter > 0) and (segsAfter < segsBefore) then
      Ok(Format('segment sayisi %d -> %d', [segsBefore, segsAfter]))
    else
      Fail(Format('segment sayisi beklenmedik: %d -> %d',
        [segsBefore, segsAfter]));

    // 6c) Tekrar budama idempotent: yeni silme yok.
    okp := VdbLogPruneAt(DbPath('pr'), VdbLogNowMs + 86400000, 2, pr2, err);
    if okp and (pr2.DroppedSegments = 0) and (pr2.DroppedBaseFiles = 0) then
      Ok('ikinci budama idempotent (0 silme)')
    else
      Fail(Format('ikinci budama silme yapti: seg=%d base=%d',
        [pr2.DroppedSegments, pr2.DroppedBaseFiles]));

    // 6d) Budama sonrasi gunluk HALA calisir: kalan en eski tabandan
    //     (b2) replay edilince tum sonraki gruplar gelir.
    v := NewVerify;
    try
      r.Replay(b2, 0, 0, v.Visit, applied, reason);
      if applied = 9 then
        Ok('budama sonrasi b2''den replay 9 grup (7..15) uyguladi')
      else
        Fail(Format('replay %d grup uyguladi (beklenen 9)', [applied]));
      if (Length(v.Keys) > 0) and (v.Keys[High(v.Keys)] = 15) and
         ValEq(v.News[High(v.News)], MakeVal(15, 10)) then
        Ok('replay son degeri birebir (anahtar 15)')
      else
        Fail('replay son degeri yanlis');
    finally
      v.Free;
    end;

    // 6e) Aktif (son) segment asla silinmez: son grup hala okunur.
    if r.LastState(seq, lastNo) and (seq > 0) then
      Ok(Format('son durum okunur (seq=%d)', [seq]))
    else
      Fail('budama sonrasi son durum okunamadi');
    lastSeg := LastSegFile(logDir, lastNo);
    if (lastSeg <> '') and FileExists(lastSeg) then
      Ok('aktif segment dosyasi yerinde')
    else
      Fail('aktif segment silinmis');

    // 6f) Taban YOKSA hicbir sey silinmez (guvenlik: kapsama kanitlanamaz).
    CleanDir('pr2');
    lg := TVdbChangeLog.Create;
    try
      lg.SegMax := 900;
      lg.Open(DbPath('pr2'), True);
      for i := 1 to 8 do
      begin
        lg.BeginGroup;
        lg.AddPut(1, QWord(i), nil, MakeVal(i, 10));
        lg.EndGroup(1, seq, ts);
      end;
      lg.Flush;
      lg.Close;
    finally
      lg.Free;
    end;
    okp := VdbLogPruneAt(DbPath('pr2'), VdbLogNowMs + 86400000, 2, pr, err);
    if okp and (pr.DroppedSegments = 0) then
      Ok('taban yokken budama hicbir sey silmez')
    else
      Fail(Format('taban yokken silme yapildi: seg=%d err=%s',
        [pr.DroppedSegments, err]));

    // 6g) KeepBases=1: yalniz en yeni tabandan onceki onek silinir.
    okp := VdbLogPruneAt(DbPath('pr'), VdbLogNowMs + 86400000, 1, pr, err);
    if okp and (pr.DroppedSegments > 0) then
      Ok(Format('KeepBases=1 ek onek sildi (%d segment)', [pr.DroppedSegments]))
    else
      Ok(Format('KeepBases=1 silinecek onek yok (seg=%d)', [pr.DroppedSegments]));
    bases := r.ListBases;
    if (Length(bases) = 1) and (bases[0].Seq = b3) then
      Ok('KeepBases=1: yalniz en yeni taban kaldi')
    else
      Fail(Format('KeepBases=1 sonrasi taban sayisi %d', [Length(bases)]));
  finally
    r.Free;
  end;
end;

{ ================================================================== ana }
var
  sr: TSearchRec;
begin
  gPass := 0;
  gFail := 0;
  if ParamCount >= 1 then gDir := ParamStr(1) else gDir := GetCurrentDir;
  if not DirectoryExists(gDir) then ForceDirectories(gDir);

  WriteLn('VDB v4 logchk - mantiksal degisim gunlugu kapisi');
  WriteLn('dizin=', gDir);
  WriteLn;

  TestRoundTrip;
  TestTornTail;
  TestRotation;
  TestBaseChange;
  TestCrc;
  TestPrune;

  WriteLn;
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
  begin
    WriteLn('DEGISIM GUNLUGU DOGRULANDI');
    Halt(0);
  end;
  WriteLn('DEGISIM GUNLUGU HATALI');
  Halt(1);
end.
