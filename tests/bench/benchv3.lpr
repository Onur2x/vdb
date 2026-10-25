program benchv3;

{ VDB v3 - sayfa motoru olcum takimi (Sprint 1 / 1.12)

  Olcer:
    - 200k satir toplu yazim suresi (islem basina us)
    - veritabani dosyasi + .idx + .wal boyutlari, satir basina bayt
    - temiz kapanis sonrasi acilis (idx ile) ve idx'siz tam tarama
    - PK nokta okuma suresi (us)
    - ham tarama: kopyali (ScanAll) ve sifir-kopya (ScanAllRaw)

  v3.1: sureler QPC ile mikrosaniye cozunurlugunde olculur
  (GetTickCount64 ~15,6 ms kuantalar; tek atimlik olcumlerde yaniltici).

  Kullanim: benchv3 <dizin> [satir_sayisi] [deger_bayt]
}

{$mode delphi}{$H+}

uses
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  Classes, SysUtils, DateUtils, VDbPage, VDbPageStore, VDbPageHeap,
  VDbPageEngine, VDbPageWal;

var
  gDir: string;
  gQpf: Int64;

{ QPC tabanli monoton saat (mikrosaniye). Unix'te GetTickCount64'e duser. }
function NowUs: Int64;
{$IFDEF MSWINDOWS}
var
  c: Int64;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  if gQpf = 0 then
    if not QueryPerformanceFrequency(gQpf) then gQpf := 1000;
  QueryPerformanceCounter(c);
  if gQpf >= 1000000 then
    Result := c div (gQpf div 1000000)
  else if gQpf >= 1000 then
    Result := (c * 1000) div gQpf
  else
    Result := c * 1000;
  {$ELSE}
  Result := GetTickCount64 * 1000;
  {$ENDIF}
end;

procedure MakeVal(Key: QWord; Len, Seed: Integer; out V: TBytes);
var
  i: Integer;
begin
  SetLength(V, Len);
  for i := 0 to Len - 1 do
    V[i] := Byte(((Key * 37) + QWord(Seed) * 101 + QWord(i) * 7) and $FF);
end;

function FileSizeOf(const P: string): Int64;
var
  f: TFileStream;
begin
  Result := 0;
  if not FileExists(P) then Exit;
  f := TFileStream.Create(P, fmOpenRead or fmShareDenyNone);
  try
    Result := f.Size;
  finally
    f.Free;
  end;
end;

{ Kopyali tarama (TBytes): sayfa basina deger KOPYALANIR. }
type
  TScanCounter = class
  public
    Rows: Int64;
    Bytes: Int64;
    procedure Cb(Key: QWord; const Value: TBytes);
    procedure CbRaw(Key: QWord; Data: PByte; Len: Integer);
  end;

procedure TScanCounter.Cb(Key: QWord; const Value: TBytes);
begin
  Inc(Rows);
  Inc(Bytes, Length(Value));
end;

procedure TScanCounter.CbRaw(Key: QWord; Data: PByte; Len: Integer);
begin
  Inc(Rows);
  Inc(Bytes, Len);
end;

var
  N, VLen, i: Integer;
  db: string;
  eng: TVdbPageEngine;
  v: TBytes;
  t0: Int64;
  usYaz, usAcIdx, usAcTam, usOku, usTara, usTara0: Int64;
  ok: Integer;
  sc: TScanCounter;
begin
  N := 200000;
  VLen := 32;
  if ParamCount >= 1 then gDir := ParamStr(1) else gDir := GetCurrentDir;
  if ParamCount >= 2 then N := StrToIntDef(ParamStr(2), N);
  if ParamCount >= 3 then VLen := StrToIntDef(ParamStr(3), VLen);
  if not DirectoryExists(gDir) then ForceDirectories(gDir);
  db := IncludeTrailingPathDelimiter(gDir) + 'bench.odb';
  if FileExists(db) then DeleteFile(db);
  if FileExists(db + '.wal') then DeleteFile(db + '.wal');
  if FileExists(db + '.idx') then DeleteFile(db + '.idx');

  WriteLn('VDB v3 benchv3 - sayfa motoru');
  WriteLn(Format('dizin=%s  satir=%d  deger=%d B', [gDir, N, VLen]));
  WriteLn;

  { --- toplu yazim --- }
  eng := TVdbPageEngine.Create(db, 512);
  try
    eng.Open(True);
    t0 := NowUs;
    for i := 1 to N do
    begin
      MakeVal(i, VLen, 3, v);
      eng.Insert(i, v);
    end;
    eng.Commit(True);
    usYaz := NowUs - t0;   // commit dahil
  finally
    eng.Free;
  end;
  WriteLn(Format('yazim      : %d ms  (%.2f us/satir, commit + checkpoint dahil)',
    [usYaz div 1000, usYaz / N]));
  WriteLn(Format('dosya      : %d bayt  (%.1f B/satir)',
    [FileSizeOf(db), FileSizeOf(db) / N]));
  WriteLn(Format('idx        : %d bayt  (%.1f B/satir)',
    [FileSizeOf(db + '.idx'), FileSizeOf(db + '.idx') / N]));
  WriteLn(Format('wal        : %d bayt (kapanista budanmis olmali)',
    [FileSizeOf(db + '.wal')]));
  WriteLn;

  { --- idx ile acilis --- }
  t0 := NowUs;
  eng := TVdbPageEngine.Create(db, 512);
  ok := 0;
  try
    eng.Open(False);
    usAcIdx := NowUs - t0;
    WriteLn(Format('acilis idx : %d ms  (idx kullanildi=%s)', [usAcIdx div 1000,
      BoolToStr(eng.IdxUsed, True)]));
    if eng.Count <> N then
      WriteLn(Format('  !! sayi %d (beklenen %d)', [eng.Count, N]));

    { --- nokta okuma --- }
    t0 := NowUs;
    for i := 1 to N do
      if eng.TryGet(QWord(i), v) then Inc(ok);
    usOku := NowUs - t0;
    WriteLn(Format('PK okuma   : %d ms  (%.2f us/satir, %d/%d bulundu)',
      [usOku div 1000, usOku / N, ok, N]));

    { --- ham tarama: kopyali (TBytes) vs sifir-kopya --- }
    sc := TScanCounter.Create;
    try
      t0 := NowUs;
      eng.ScanAll(sc.Cb);
      usTara := NowUs - t0;
      WriteLn(Format('ham tarama : %8.1f ms  (%.3f us/satir, %d satir, %.1f MB)',
        [usTara / 1000, usTara / N, sc.Rows, sc.Bytes / (1024.0 * 1024.0)]));

      sc.Rows := 0;
      sc.Bytes := 0;
      t0 := NowUs;
      eng.ScanAllRaw(sc.CbRaw);
      usTara0 := NowUs - t0;
      WriteLn(Format('ham tarama0: %8.1f ms  (%.3f us/satir, %d satir)',
        [usTara0 / 1000, usTara0 / N, sc.Rows]));
    finally
      sc.Free;
    end;
  finally
    eng.Free;
  end;

  { --- idx'siz tam tarama --- }
  DeleteFile(db + '.idx');
  t0 := NowUs;
  eng := TVdbPageEngine.Create(db, 512);
  try
    eng.Open(False);
    usAcTam := NowUs - t0;
    WriteLn(Format('acilis tam : %d ms  (idx kullanildi=%s)', [usAcTam div 1000,
      BoolToStr(eng.IdxUsed, True)]));
    if eng.Count <> N then
      WriteLn(Format('  !! sayi %d (beklenen %d)', [eng.Count, N]));
  finally
    eng.Free;
  end;
  WriteLn;

  WriteLn('=== ozet ===');
  WriteLn(Format('dosya=%.1f B/satir  acilis_idx=%d ms  acilis_tam=%d ms  ' +
    'yazim=%.2f us  okuma=%.2f us',
    [FileSizeOf(db) / N, usAcIdx div 1000, usAcTam div 1000, usYaz / N,
     usOku / N]));
end.
