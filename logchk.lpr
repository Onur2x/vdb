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
