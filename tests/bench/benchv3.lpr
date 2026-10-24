program benchv3;

{ VDB v3 - sayfa motoru olcum takimi (Sprint 1 / 1.12)

  Olcer (win32):
    - 200k satir toplu yazim suresi (islem basina us)
    - veritabani dosyasi + .idx + .wal boyutlari, satir basina bayt
    - temiz kapanis sonrasi acilis (idx ile) ve idx'siz tam tarama
    - PK nokta okuma suresi (us) ve COUNT benzeri tarama

  Kullanim: benchv3 <dizin> [satir_sayisi] [deger_bayt]
}

{$mode delphi}{$H+}

uses
  Classes, SysUtils, DateUtils, VDbPage, VDbPageStore, VDbPageHeap,
  VDbPageEngine, VDbPageWal;

var
  gDir: string;

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

function Now64: Int64;
begin
  Result := GetTickCount64;
end;

var
  N, VLen, i: Integer;
  db: string;
  eng: TVdbPageEngine;
  v: TBytes;
  t0: Int64;
  msYaz, msAcIdx, msAcTam, msOku, msTara: Int64;
  usYaz, usOku: Double;
  ok: Integer;
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
    t0 := Now64;
    for i := 1 to N do
    begin
      MakeVal(i, VLen, 3, v);
      eng.Insert(i, v);
    end;
    msYaz := Now64 - t0;
    eng.Commit(True);
    msYaz := Now64 - t0;   // commit dahil
  finally
    eng.Free;
  end;
  usYaz := (msYaz * 1000.0) / N;
  WriteLn(Format('yazim      : %d ms  (%.2f us/satir, commit + checkpoint dahil)',
    [msYaz, usYaz]));
  WriteLn(Format('dosya      : %d bayt  (%.1f B/satir)',
    [FileSizeOf(db), FileSizeOf(db) / N]));
  WriteLn(Format('idx        : %d bayt  (%.1f B/satir)',
    [FileSizeOf(db + '.idx'), FileSizeOf(db + '.idx') / N]));
  WriteLn(Format('wal        : %d bayt (kapanista budanmis olmali)',
    [FileSizeOf(db + '.wal')]));
  WriteLn;

  { --- idx ile acilis --- }
  t0 := Now64;
  eng := TVdbPageEngine.Create(db, 512);
  ok := 0;
  try
    eng.Open(False);
    msAcIdx := Now64 - t0;
    WriteLn(Format('acilis idx : %d ms  (idx kullanildi=%s)', [msAcIdx,
      BoolToStr(eng.IdxUsed, True)]));
    if eng.Count <> N then
      WriteLn(Format('  !! sayi %d (beklenen %d)', [eng.Count, N]));

    { --- nokta okuma --- }
    t0 := Now64;
    for i := 1 to N do
      if eng.TryGet(QWord(i), v) then Inc(ok);
    msOku := Now64 - t0;
    usOku := (msOku * 1000.0) / N;
    WriteLn(Format('PK okuma   : %d ms  (%.2f us/satir, %d/%d bulundu)',
      [msOku, usOku, ok, N]));
  finally
    eng.Free;
  end;

  { --- idx'siz tam tarama --- }
  DeleteFile(db + '.idx');
  t0 := Now64;
  eng := TVdbPageEngine.Create(db, 512);
  try
    eng.Open(False);
    msAcTam := Now64 - t0;
    WriteLn(Format('acilis tam : %d ms  (idx kullanildi=%s)', [msAcTam,
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
    [FileSizeOf(db) / N, msAcIdx, msAcTam, usYaz, usOku]));
end.
