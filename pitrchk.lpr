program pitrchk;

{ VDB v4 - Mantiksal degisim gunlugu / PITR kapisi

  Denetlenenler:
    1) Uc fazli yazim (ekle -> guncelle+sil -> ekle). Her fazin zaman ve
       SURUM (seq) sinirinda okunan anlik goruntu, o anda canli dosyada
       duran durumun BIREBIR aynisidir (anahtar kumesi + degerler).
    2) AS OF TIMESTAMP: faz A ve faz B zamanlari.
    3) AS OF VERSION (kalici gunluk seq): faz A ve faz B.
    4) Guncel zaman/bolge disi hedef: en son duruma kirpilir (Actual*).
    5) BuildLogSnapshot: hedef .odb dosyasi acilir, Verify TEMIZ, icerik
       birebir (kurtarma dosyasi GERCEK veritabanidir).
    6) Kapanip yeniden acildiktan SONRA eski zamanlar hala okunur
       (gunluk kalici).
    7) ArchiveLogSet: taban imajlari + segmentler kopyalanir, boyut > 0.
    8) LogRangeInfo: artan seq/zaman, taban sayisi >= 1.

  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: pitrchk <calisma_dizini>
}

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, DateUtils, VDbBackendApi, VDbBackendV3, VDbPageEngine;

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

function DirOf(const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(gDir) + Name;
end;

function MakeVal(Mark: AnsiChar; I: Integer): TBytes;
begin
  SetLength(Result, 9);
  Result[0] := Byte(Mark);
  Result[1] := Byte(I and $FF);
  Result[2] := Byte((I shr 8) and $FF);
  Result[3] := Byte((I shr 16) and $FF);
  Result[4] := Byte((I shr 24) and $FF);
  Result[5] := 0;
  Result[6] := 0;
  Result[7] := 0;
  Result[8] := Byte(Ord(Mark) xor (I and $7F));
end;

function ValMark(const V: TBytes): AnsiChar;
begin
  if Length(V) = 0 then Exit(#0);
  Result := AnsiChar(V[0]);
end;

{ Beklenen durum: Mark='A' -> 1..100; 'B' -> 1..50 B, 51..90 A;
  'C' -> 1..50 B, 51..90 A, 101..120 C. }
function CheckState(const Tag: string; const Keys: TQWordArray;
  const Vals: TValArray; Mark: AnsiChar; ExpectN: Integer): Boolean;
var
  i, k: Integer;
  ok: Boolean;
  v: TBytes;
  m: AnsiChar;
  function Has(Key: QWord; out Idx: Integer): Boolean;
  var
    j: Integer;
  begin
    Result := False;
    Idx := -1;
    for j := 0 to High(Keys) do
      if Keys[j] = Key then
      begin
        Idx := j;
        Exit(True);
      end;
  end;
begin
  Result := False;
  if Length(Keys) <> ExpectN then
  begin
    Fail(Format('%s: satir %d (beklenen %d)', [Tag, Length(Keys), ExpectN]));
    Exit;
  end;
  if Length(Vals) <> ExpectN then
  begin
    Fail(Tag + ': deger dizisi uzunlugu tutmuyor');
    Exit;
  end;
  ok := True;
  for i := 1 to 120 do
  begin
    if not Has(QWord(i), k) then
    begin
      { bu satir beklenmiyorsa sorun yok }
      if ((i <= 90) and ((Mark = 'A') or (Mark = 'B'))) or
         ((i <= 100) and (Mark = 'A')) or
         ((i >= 101) and (i <= 120) and (Mark = 'C')) then
      begin
        ok := False;
        Fail(Format('%s: satir %d yok', [Tag, i]));
        Break;
      end;
      Continue;
    end;
    v := Vals[k];
    m := ValMark(v);
    case Mark of
      'A':
        if (i < 1) or (i > 100) or (m <> 'A') then ok := False;
      'B':
        if i <= 50 then
        begin
          if m <> 'B' then ok := False;
        end
        else if i <= 90 then
        begin
          if m <> 'A' then ok := False;
        end
        else ok := False;   // 91..100 silinmis, 101+ henuz yok
      'C':
        if i <= 50 then
        begin
          if m <> 'B' then ok := False;
        end
        else if i <= 90 then
        begin
          if m <> 'A' then ok := False;
        end
        else if (i >= 101) and (i <= 120) then
        begin
          if m <> 'C' then ok := False;
        end
        else ok := False;
    end;
    if not ok then
    begin
      Fail(Format('%s: satir %d degeri yanlis (mark=%s)', [Tag, i, m]));
      Break;
    end;
  end;
  Result := ok;
end;

var
  gMaxSeqA, gMaxSeqB, gMaxSeqC: Int64;
  gTsA, gTsB, gTsC: Int64;

procedure RunPitr;
var
  be: TVdbBackendV3;
  b, rec: IVdbBackend;
  recBe: TVdbBackendV3;
  i, n: Integer;
  err: string;
  sr: TSearchRec;
  minSeq, maxSeq, minTs, maxTs: Int64;
  baseCount: Integer;
  keys: TQWordArray;
  vals: TValArray;
  actTs, actSeq: Int64;
  got: Boolean;
begin
  WriteLn('1) uc fazli yazim + gunluk araligi');
  be := TVdbBackendV3.Create(DirOf('pitr.odb'), True, 128);
  b := be;
  if not b.LogSupported then
  begin
    Fail('gunluk desteklenmiyor: ' + b.LogStatus);
    b := nil;              { arayuz refcount: nesneyi serbest birakir }
    be := nil;
    Exit;
  end
  else
    Ok('degisim gunlugu acik');
  if b.LogStatus <> '' then
    Fail('gunluk durumu bos degil: ' + b.LogStatus);

  { --- faz A: 1..100 --- }
  b.BeginBatch;
  for i := 1 to 100 do
    b.Put(QWord(i), MakeVal('A', i));
  b.CommitBatch;
  b.Flush;
  if b.LogRangeInfo(minSeq, maxSeq, minTs, maxTs, baseCount) then
  begin
    gMaxSeqA := maxSeq;
    gTsA := maxTs;
    if baseCount >= 1 then Ok(Format('faz A: taban=%d, son seq=%d',
      [baseCount, maxSeq]))
    else Fail('taban isareti yok');
  end
  else
    Fail('LogRangeInfo faz A bos');

  { --- faz B: 1..50 guncelle, 91..100 sil --- }
  Sleep(40);
  b.BeginBatch;
  for i := 1 to 50 do
    b.Put(QWord(i), MakeVal('B', i));
  for i := 91 to 100 do
    b.Delete(QWord(i));
  b.CommitBatch;
  b.Flush;
  if b.LogRangeInfo(minSeq, maxSeq, minTs, maxTs, baseCount) then
  begin
    gMaxSeqB := maxSeq;
    gTsB := maxTs;
    if maxSeq > gMaxSeqA then Ok(Format('faz B: seq %d -> %d', [gMaxSeqA, maxSeq]))
    else Fail('faz B seq artmadi');
    if maxTs >= gTsA then Ok('faz B zamani ilerledi') else Fail('zaman geriledi');
  end
  else
    Fail('LogRangeInfo faz B bos');

  { --- faz C: 101..120 ekle --- }
  Sleep(40);
  b.BeginBatch;
  for i := 101 to 120 do
    b.Put(QWord(i), MakeVal('C', i));
  b.CommitBatch;
  b.Flush;
  b.LogRangeInfo(minSeq, maxSeq, minTs, maxTs, baseCount);
  gMaxSeqC := maxSeq;
  gTsC := maxTs;

  WriteLn;
  WriteLn('2) AS OF TIMESTAMP');
  got := b.ScanAllAtLogTime(-1, gTsA, 0, keys, vals, actTs, actSeq);
  if got then
  begin
    if CheckState('zaman A', keys, vals, 'A', 100) then
      Ok(Format('zaman A: 100 satir, hepsi A (seq=%d)', [actSeq]));
    if actTs = gTsA then Ok('zaman A: ulasilan zaman birebir')
    else Fail(Format('zaman A: actTs %d (beklenen %d)', [actTs, gTsA]));
  end
  else
    Fail('zaman A okunamadi');

  got := b.ScanAllAtLogTime(-1, gTsB, 0, keys, vals, actTs, actSeq);
  if got then
  begin
    if CheckState('zaman B', keys, vals, 'B', 90) then
      Ok('zaman B: 90 satir (10 silinmis, 50 guncellenmis)');
  end
  else
    Fail('zaman B okunamadi');

  got := b.ScanAllAtLogTime(-1, gTsC, 0, keys, vals, actTs, actSeq);
  if got then
  begin
    if CheckState('zaman C', keys, vals, 'C', 110) then
      Ok('zaman C: 110 satir');
  end
  else
    Fail('zaman C okunamadi');

  { hedef ileride: son duruma kirpilir }
  got := b.ScanAllAtLogTime(-1, gTsC + 600000, 0, keys, vals, actTs, actSeq);
  if got then
  begin
    if actTs = gTsC then Ok('ileri hedef son kayda kirpildi')
    else Fail(Format('kirpma yanlis: actTs %d (beklenen %d)', [actTs, gTsC]));
    if CheckState('kirpilmis', keys, vals, 'C', 110) then
      Ok('kirpilmis gorunum son durum');
  end
  else
    Fail('ileri hedef okunamadi');

  WriteLn;
  WriteLn('3) AS OF VERSION (kalici gunluk seq)');
  got := b.ScanAllAtLogTime(-1, 0, gMaxSeqA, keys, vals, actTs, actSeq);
  if got then
  begin
    if CheckState('surum A', keys, vals, 'A', 100) then
      Ok(Format('surum A (%d): 100 satir', [gMaxSeqA]));
    if actSeq = gMaxSeqA then Ok('surum A: ulasilan seq birebir')
    else Fail(Format('surum A: actSeq %d (beklenen %d)', [actSeq, gMaxSeqA]));
  end
  else
    Fail('surum A okunamadi');

  got := b.ScanAllAtLogTime(-1, 0, gMaxSeqB, keys, vals, actTs, actSeq);
  if got then
  begin
    if CheckState('surum B', keys, vals, 'B', 90) then
      Ok(Format('surum B (%d): 90 satir', [gMaxSeqB]));
  end
  else
    Fail('surum B okunamadi');

  WriteLn;
  WriteLn('4) BuildLogSnapshot (kurtarma dosyasi)');
  got := b.BuildLogSnapshot(gTsA, 0, DirOf('rec_a.odb'), actTs, actSeq);
  if got then
  begin
    if actTs = gTsA then Ok('rec_a: zaman birebir');
    { Dosyayi gercek bir veritabani olarak ac ve dogrula. }
    recBe := TVdbBackendV3.Create(DirOf('rec_a.odb'), False, 128);
    try
      rec := recBe;
      if rec.Verify(err) then Ok('rec_a: Verify TEMIZ')
      else Fail('rec_a: Verify HATALI: ' + err);
      rec.ScanAll(keys, vals, -1);
      if CheckState('rec_a icerik', keys, vals, 'A', 100) then
        Ok('rec_a: icerik faz A birebir');
    finally
      rec := nil;
      recBe := nil;
    end;
  end
  else
    Fail('rec_a olusmadi');

  WriteLn;
  WriteLn('5) kapanip yeniden acilista kalicilik');
  b := nil;                { nesne refcount ile kapanir (checkpoint + idx) }
  be := TVdbBackendV3.Create(DirOf('pitr.odb'), False, 128);
  b := be;
  got := b.ScanAllAtLogTime(-1, gTsA, 0, keys, vals, actTs, actSeq);
  if got then
  begin
    if CheckState('yeniden acilis, zaman A', keys, vals, 'A', 100) then
      Ok('yeniden acilista zaman A hala okunur');
  end
  else
    Fail('yeniden acilista zaman A okunamadi');

  WriteLn;
  WriteLn('6) ArchiveLogSet (WAL arsivi)');
  n := b.ArchiveLogSet(DirOf('arsiv'));
  if n > 0 then
    Ok(Format('arsiv kopyalandi: %d bayt', [n]))
  else
    Fail('arsiv bos');
  if DirectoryExists(DirOf('arsiv\base')) then
    Ok('arsivde taban dizini var')
  else
    Fail('arsivde taban dizini yok');
  if DirectoryExists(DirOf('arsiv')) then
  begin
    if FindFirst(DirOf('arsiv\*.vlog'), faAnyFile, sr) = 0 then
    begin
      Ok('arsivde segment var');
      FindClose(sr);
    end
    else
      Fail('arsivde segment yok');
  end;

  b.LogRangeInfo(minSeq, maxSeq, minTs, maxTs, baseCount);
  if (maxSeq >= gMaxSeqC) and (baseCount >= 1) then
    Ok(Format('aralik: seq %d..%d, taban=%d', [minSeq, maxSeq, baseCount]))
  else
    Fail('aralik bilgisi tutarsiz');

  b := nil;
  be := nil;
end;

{ ================================================================== ana }
begin
  gPass := 0;
  gFail := 0;
  if ParamCount >= 1 then gDir := ParamStr(1) else gDir := GetCurrentDir;
  if not DirectoryExists(gDir) then ForceDirectories(gDir);

  WriteLn('VDB v4 pitrchk - degisim gunlugu / PITR kapisi');
  WriteLn('dizin=', gDir);
  WriteLn;

  RunPitr;

  WriteLn;
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
  begin
    WriteLn('PITR DOGRULANDI');
    Halt(0);
  end;
  WriteLn('PITR HATALI');
  Halt(1);
end.
