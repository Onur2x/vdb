program replchk;

{ VDB v4 - REPLIKASYON kapisi (mantiksal gunluk tasima)

  Denetlenenler:
    1) Slot yasam dongusu: olustur (tekrar etkisiz) / iki etkin slot yok.
    2) Birincil tasima: taban imaji + veri gruplari tasima dizinine yazilir.
    3) Ikincil uygulama: taban RESTORE edilir, gruplar TEK islem olarak
       uygulanir; anahtar kumesi ve degerler birincille BIREBIR aynidir
       (ham KV karsilastirmasi; SQL katmani karismaz).
    4) Artimli devam: yeni commit'ler yalniz yeni gruplari tasir.
    5) Bos PUMP etkisizdir (0 grup, hata yok).
    6) Yeniden baslatma: ikincil konumu kalicidir (slot dosyasi).
    7) IDEMPOTENT tekrar: konum bir geri alinip ayni grup yeniden uygulanir
       -> veri DEGISMEZ (kayitlar mutlak eski->yeni tasir).
    8) Bozuk tasima dosyasi: ikincil REDDEDER, veri bozulmaz.
    9) Sirada bosluk (grup dosyasi silinmis): ikincil REDDEDER, atlamaz.
   10) Nesil kopmasi (RESTORE): birincil tasimayi REDDEDER.
   11) Ikincil kendi gunlugune YENIDEN NUMARALAR: PITR kendi seq uzayinda
       calisir; taban sonrasi anlik goruntu birincille birebirdir.
   12) Durdur / durum / sil.

  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: replchk <calisma_dizini>
}

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, VDbBackendApi, VDbBackendV3, VDbReplV3, VDbChangeLog;

var
  gPass, gFail: Int64;
  gDir: string;
  gPri, gStd: IVdbBackend;
  gPriPath, gStdPath, gShip: string;
  gSlotPri, gSlotStd: string;
  gReplTmp: TVdbReplSlotInfo;

{ Bayt bayt dosya kopyasi (platform farkindan bagimsiz). }
function CopyBytes(const ASrc, ADst: string): Boolean;
var
  a, b: TFileStream;
begin
  Result := False;
  if not FileExists(ASrc) then Exit;
  if FileExists(ADst) then DeleteFile(ADst);
  a := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    b := TFileStream.Create(ADst, fmCreate);
    try
      b.CopyFrom(a, 0);
    finally
      b.Free;
    end;
  finally
    a.Free;
  end;
  Result := True;
end;

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

{ 9 baytlik kayit degeri: isaret + sayac + dolgu. }
function MakeVal(Mark: AnsiChar; I: Integer): TBytes;
begin
  SetLength(Result, 9);
  Result[0] := Byte(Mark);
  Result[1] := Byte(I and $FF);
  Result[2] := Byte((I shr 8) and $FF);
  Result[3] := Byte((I shr 16) and $FF);
  Result[4] := Byte((I shr 24) and $FF);
  Result[5] := Byte(Ord(Mark));
  Result[6] := Byte(I and $3F);
  Result[7] := $5A;
  Result[8] := Byte(Ord(Mark) xor (I and $7F));
end;

{ Iki backend'in TUM anahtar/deger kumesi birebir mi? }
function SameContent(const Tag: string; A, B: IVdbBackend): Boolean;
var
  ka, kb: TQWordArray;
  va, vb: TValArray;
  i: Integer;
begin
  Result := False;
  A.ScanAll(ka, va);
  B.ScanAll(kb, vb);
  if Length(ka) <> Length(kb) then
  begin
    Fail(Format('%s: anahtar sayisi %d <> %d', [Tag, Length(ka), Length(kb)]));
    Exit;
  end;
  for i := 0 to High(ka) do
  begin
    if ka[i] <> kb[i] then
    begin
      Fail(Format('%s: %d. anahtar %d <> %d', [Tag, i, Int64(ka[i]), Int64(kb[i])]));
      Exit;
    end;
    if Length(va[i]) <> Length(vb[i]) then
    begin
      Fail(Format('%s: %d. deger uzunlugu farkli', [Tag, i]));
      Exit;
    end;
    if (Length(va[i]) > 0) and
      (CompareMem(@va[i][0], @vb[i][0], Length(va[i])) = False) then
    begin
      Fail(Format('%s: %d. deger farkli', [Tag, i]));
      Exit;
    end;
  end;
  Result := True;
end;

function SlotVal(const APath, AKey: string): string;
var
  L: TStringList;
begin
  Result := '';
  if not FileExists(APath) then Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(APath);
    except
      Exit;
    end;
    Result := L.Values[AKey];
  finally
    L.Free;
  end;
end;

{ Slot dosyasindaki last_seq degerini degistirir (cokme benzetimi). }
function ForceSlotSeq(const APath: string; ASeq: Int64): Boolean;
var
  L: TStringList;
  i, p: Integer;
begin
  Result := False;
  if not FileExists(APath) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(APath);
    for i := 0 to L.Count - 1 do
    begin
      p := Pos('=', L[i]);
      if (p > 1) and (Copy(L[i], 1, p - 1) = 'last_seq') then
      begin
        L[i] := 'last_seq=' + IntToStr(ASeq);
        Result := True;
      end;
    end;
    if Result then L.SaveToFile(APath);
  finally
    L.Free;
  end;
end;

function GroupSeqOf(const AName: string): Int64;
begin
  Result := StrToInt64Def(Copy(AName, 3, Length(AName) - 7), -1);
end;

{ Slot dizinindeki EN KUCUK seq >= AMinSeq olan tasima dosyasi. }
function FindGroupFile(const ASlotDir: string; AMinSeq: Int64): string;
var
  sr: TSearchRec;
  nm, best: string;
  seq, bestSeq: Int64;
begin
  Result := '';
  best := '';
  bestSeq := 0;
  if not DirectoryExists(ASlotDir) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(ASlotDir) + 'g-*.vrgp',
    faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Attr and faDirectory) = 0 then
      begin
        nm := ExtractFileName(sr.Name);
        seq := GroupSeqOf(nm);
        if (seq >= AMinSeq) and ((best = '') or (seq < bestSeq)) then
        begin
          best := nm;
          bestSeq := seq;
        end;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  if best <> '' then
    Result := IncludeTrailingPathDelimiter(ASlotDir) + best;
end;

{ Tasima dosyasinin govdesinin SON baytini bozar (govde CRC'si tutmaz). }
function CorruptGroup(const APath: string): Boolean;
var
  S: TFileStream;
  hdr: TBytes;
  dl: LongWord;
  b: Byte;
  pos: Int64;
begin
  Result := False;
  if not FileExists(APath) then Exit;
  S := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyNone);
  try
    if S.Size < 68 then Exit;
    SetLength(hdr, 4);
    S.Position := 36;
    if S.Read(hdr[0], 4) <> 4 then Exit;
    Move(hdr[0], dl, 4);
    if dl < 8 then Exit;
    pos := 64 + Int64(dl) - 1;
    if pos >= S.Size then Exit;
    S.Position := pos;
    if S.Read(b, 1) <> 1 then Exit;
    b := Byte(b xor $FF);
    S.Position := pos;
    S.Write(b, 1);
    Result := True;
  finally
    S.Free;
  end;
end;

procedure RunReplication;
var
  std: IVdbBackend;
  i: Integer;
  n: Int64;
  msg: string;
  baseInst: Boolean;
  minSeq, maxSeq, minTs, maxTs, prev: Int64;
  baseCount: Integer;
  actTs, actSeq: Int64;
  nm, keep: string;
  before: Integer;
  snapPath: string;
begin
  gPriPath := DirOf('pri.odb');
  gStdPath := DirOf('std.odb');
  gShip := DirOf('ship');
  gSlotPri := IncludeTrailingPathDelimiter(gPriPath + VDBREPL_DIR_SUFFIX) + 's1.slot';
  gSlotStd := IncludeTrailingPathDelimiter(gStdPath + VDBREPL_DIR_SUFFIX) + 's1.slot';

  WriteLn('1) slot yasam dongusu + birincil tasima');
  gPri := TVdbBackendV3.Create(gPriPath, True, 128);
  if not gPri.ReplSupported then
  begin
    Fail('birincil: replikasyon desteklenmiyor: ' + gPri.LogStatus);
    Exit;
  end;
  Ok('birincil: replikasyon destekli');
  if VdbReplCreate(gPri, 's1', msg) then
    Ok('slot olusturuldu')
  else
    Fail('slot olustur: ' + msg);
  if VdbReplCreate(gPri, 's1', msg) then
    Ok('ayni slot ikinci kez: etkisiz')
  else
    Fail('slot tekrar olustur: ' + msg);

  gPri.BeginBatch;
  for i := 1 to 200 do
    gPri.Put(QWord(i), MakeVal('A', i));
  gPri.CommitBatch;
  gPri.Flush;

  if VdbReplStart(gPri, True, 's1', gShip, msg) then
    Ok('birincil basladi')
  else
    Fail('birincil baslat: ' + msg);

  if VdbReplPump(gPri, n, baseInst, msg) then
  begin
    if n >= 2 then
      Ok(Format('birincil PUMP: %d grup tasindi', [n]))
    else
      Fail(Format('birincil PUMP: beklenen >=2 grup, gelen %d', [n]));
  end
  else
    Fail('birincil PUMP: ' + msg);
  if baseInst then Fail('birincil PUMP taban kurdu (olmamali)');

  if VdbReplStart(gPri, False, 's2', gShip, msg) then
    Fail('ikinci etkin slot kabul edildi')
  else
    Ok('ikinci etkin slot reddedildi');

  WriteLn('2) ikincil kurulum (taban RESTORE + grup uygulama)');
  gStd := TVdbBackendV3.Create(gStdPath, True, 128);
  if VdbReplStart(gStd, False, 's1', gShip, msg) then
    Ok('ikincil basladi')
  else
    Fail('ikincil baslat: ' + msg);
  if VdbReplPump(gStd, n, baseInst, msg) then
  begin
    if n >= 2 then
      Ok(Format('ikincil PUMP: %d grup uygulandi', [n]))
    else
      Fail(Format('ikincil PUMP: beklenen >=2 grup, gelen %d', [n]));
  end
  else
    Fail('ikincil PUMP: ' + msg);
  if baseInst then Ok('ikincil taban kurdu')
  else Fail('ikincil taban kurmadi');
  if SameContent('ilk kopya', gPri, gStd) then
    Ok(Format('ilk kopya BIREBIR (%d anahtar)', [gStd.Count]))
  else
    Fail('ilk kopya farkli');

  WriteLn('3) artimli devam');
  gPri.BeginBatch;
  for i := 1 to 50 do
    gPri.Put(QWord(i), MakeVal('B', i));
  for i := 191 to 200 do
    gPri.Delete(QWord(i));
  gPri.CommitBatch;
  gPri.BeginBatch;
  for i := 201 to 230 do
    gPri.Put(QWord(i), MakeVal('C', i));
  gPri.CommitBatch;
  gPri.Flush;

  if VdbReplPump(gPri, n, baseInst, msg) and (n = 2) then
    Ok('birincil 2 yeni grup tasidi')
  else
    Fail('birincil PUMP 2: ' + msg);
  if VdbReplPump(gStd, n, baseInst, msg) and (n = 2) then
    Ok('ikincil 2 grup uyguladi')
  else
    Fail('ikincil PUMP 2: ' + msg);
  if SameContent('artimli kopya', gPri, gStd) then
    Ok(Format('artimli kopya BIREBIR (%d anahtar)', [gStd.Count]))
  else
    Fail('artimli kopya farkli');

  if VdbReplPump(gPri, n, baseInst, msg) and (n = 0) then
    Ok('birincil bos PUMP: 0 grup')
  else
    Fail('birincil bos PUMP: ' + msg);
  if VdbReplPump(gStd, n, baseInst, msg) and (n = 0) then
    Ok('ikincil bos PUMP: 0 grup')
  else
    Fail('ikincil bos PUMP: ' + msg);

  WriteLn('4) ikincil gunluk / PITR (kendi seq uzayi)');
  if gStd.LogRangeInfo(minSeq, maxSeq, minTs, maxTs, baseCount) then
    Ok(Format('ikincil gunluk seq %d..%d, taban %d', [minSeq, maxSeq, baseCount]))
  else
    Fail('ikincil gunluk araligi: ' + gStd.LogStatus);
  snapPath := DirOf('std_pitr.odb');
  if FileExists(snapPath) then DeleteFile(snapPath);
  try
    if gStd.BuildLogSnapshot(0, maxSeq, snapPath, actTs, actSeq) then
      Ok(Format('ikincil PITR snapshot: seq=%d', [actSeq]))
    else
      Fail('ikincil PITR snapshot basarisiz');
  except
    on E: Exception do
      Fail('ikincil PITR snapshot: ' + E.Message);
  end;
  if FileExists(snapPath) then
  begin
    std := TVdbBackendV3.Create(snapPath, False, 64);
    if SameContent('ikincil PITR', gPri, std) then
      Ok(Format('ikincil PITR icerigi BIREBIR (%d anahtar)', [std.Count]))
    else
      Fail('ikincil PITR icerigi farkli');
    std := nil;
  end
  else
    Fail('ikincil PITR dosyasi olusmadi');

  WriteLn('5) yeniden baslatma + idempotent tekrar');
  gStd := nil;
  gStd := TVdbBackendV3.Create(gStdPath, False, 128);
  if VdbReplPump(gStd, n, baseInst, msg) and (n = 0) then
    Ok('yeniden acilista konum korundu (0 yeni grup)')
  else
    Fail('yeniden acilista konum: ' + msg);
  if SameContent('yeniden acilis', gPri, gStd) then
    Ok('yeniden acilista veri yerinde')
  else
    Fail('yeniden acilista veri farkli');

  prev := StrToInt64Def(SlotVal(gSlotStd, 'last_seq'), 0);
  if (prev < 2) or (not ForceSlotSeq(gSlotStd, prev - 1)) then
    Fail('slot seq geri alinamadi')
  else
  begin
    if VdbReplPump(gStd, n, baseInst, msg) and (n = 1) then
      Ok('son grup yeniden uygulandi (konum 1 geri alindi)')
    else
      Fail('yeniden uygulama: ' + msg);
    if SameContent('idempotent tekrar', gPri, gStd) then
      Ok('tekrar uygulama veriyi DEGISTIRMEDI')
    else
      Fail('tekrar uygulama veriyi bozdu');
  end;

  WriteLn('6) bozuk tasima dosyasi reddedilir');
  gPri.BeginBatch;
  gPri.Put(QWord(1000), MakeVal('D', 1000));
  gPri.CommitBatch;
  gPri.Flush;
  if not VdbReplPump(gPri, n, baseInst, msg) then
    Fail('bozukluk hazirligi: ' + msg);
  nm := FindGroupFile(IncludeTrailingPathDelimiter(gShip) + 's1',
    StrToInt64Def(SlotVal(gSlotStd, 'last_seq'), 0) + 1);
  if nm = '' then
    Fail('tasima dosyasi bulunamadi')
  else
  begin
    keep := nm + '.keep';
    if FileExists(keep) then DeleteFile(keep);
    if not CopyBytes(nm, keep) then
      Fail('tasima dosyasi yedeklenemedi')
    else if not CorruptGroup(nm) then
      Fail('tasima dosyasi bozulamadi')
    else
    begin
      before := gStd.Count;
      if VdbReplPump(gStd, n, baseInst, msg) then
        Fail('bozuk dosya kabul edildi')
      else
        Ok('bozuk dosya reddedildi: ' + msg);
      if gStd.Count = before then
        Ok('bozuk dosyadan sonra veri DEGISMEDI')
      else
        Fail('bozuk dosyadan sonra veri degisti');
      { Dosyayi geri koy: sonraki adimlar temiz akisla devam etsin. }
      DeleteFile(nm);
      if CopyBytes(keep, nm) then
        Ok('tasima dosyasi geri kondu')
      else
        Fail('tasima dosyasi geri konamadi');
      DeleteFile(keep);
      if VdbReplPump(gStd, n, baseInst, msg) and (n = 1) then
        Ok('temiz dosya uygulandi')
      else
        Fail('temiz dosya: ' + msg);
      if SameContent('onarim sonrasi', gPri, gStd) then
        Ok('onarim sonrasi BIREBIR')
      else
        Fail('onarim sonrasi farkli');
    end;
  end;

  WriteLn('7) sirada bosluk atlanmaz');
  for i := 0 to 2 do
  begin
    gPri.BeginBatch;
    gPri.Put(QWord(2000 + i), MakeVal('E', 2000 + i));
    gPri.CommitBatch;
  end;
  gPri.Flush;
  if not VdbReplPump(gPri, n, baseInst, msg) or (n < 3) then
    Fail('bosluk hazirligi: ' + msg)
  else
    Ok(Format('3 grup daha tasindi (%d)', [n]));
  prev := StrToInt64Def(SlotVal(gSlotStd, 'last_seq'), 0);
  nm := FindGroupFile(IncludeTrailingPathDelimiter(gShip) + 's1', prev + 2);
  if nm = '' then
    Fail('ortadaki grup dosyasi yok')
  else if not DeleteFile(nm) then
    Fail('grup dosyasi silinemedi')
  else
  begin
    Ok('ortadaki grup dosyasi silindi (bosluk benzetimi)');
    before := gStd.Count;
    if VdbReplPump(gStd, n, baseInst, msg) then
      Fail('bosluk atlandi (kabul edildi)')
    else
      Ok('bosluk reddedildi: ' + msg);
    { Bosluktan ONCEKI bitisik grup uygulanmis olabilir (grup atomik,
      konum kaydedilir); ama bosluktaki ve SONRAKI gruplar UYGULANMAZ. }
    if gStd.Count = before + 1 then
      Ok('yalniz bitisik grup uygulandi (+1 kayit)')
    else
      Fail(Format('boslukta uygulanan kayit sayisi %d (beklenen +1)', [gStd.Count - before]));
    if gStd.Exists(QWord(2000)) and (not gStd.Exists(QWord(2001))) and
      (not gStd.Exists(QWord(2002))) then
      Ok('bosluktaki ve sonraki kayitlar YOK')
    else
      Fail('bosluk sonrasi kayit durumu yanlis');
  end;

  WriteLn('8) nesil kopmasi tasinamaz');
  gPri.BackupTo(DirOf('pri_bak.odb'));
  gPri.RestoreFrom(DirOf('pri_bak.odb'));
  if VdbReplPump(gPri, n, baseInst, msg) then
    Fail('nesil kopmasi tasindi (olmamali)')
  else
    Ok('nesil kopmasi reddedildi: ' + msg);

  WriteLn('9) durdur / durum / sil');
  if VdbReplStop(gStd, msg) then
    Ok('ikincil durduruldu')
  else
    Fail('STOP: ' + msg);
  if VdbReplStatus(gStd, gReplTmp) then
    Fail('durdurulduktan sonra etkin slot var')
  else
    Ok('durdurulduktan sonra etkin slot yok');
  if VdbReplDrop(gStd, 's1', msg) then
    Ok('slot silindi')
  else
    Fail('DROP: ' + msg);
  if VdbReplDrop(gStd, 's1', msg) then
    Fail('olmayan slot silindi (olmamali)')
  else
    Ok('olmayan slot reddedildi');
end;

begin
  gPass := 0;
  gFail := 0;
  gDir := 'replrun';
  if ParamCount >= 1 then gDir := ParamStr(1);
  ForceDirectories(gDir);
  WriteLn('VDB v4 replchk - mantiksal gunluk tasima');
  WriteLn('dizin=', gDir);
  WriteLn;

  RunReplication;

  WriteLn;
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
  begin
    WriteLn('REPLIKASYON DOGRULANDI');
    Halt(0);
  end
  else
  begin
    WriteLn('REPLIKASYON HATALI');
    Halt(1);
  end;
end.
