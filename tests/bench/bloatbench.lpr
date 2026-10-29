program bloatbench;

{ VDB v3 - UPDATE/DELETE sisme olcumu (Sprint A, yol haritasi hedefi: <= %5)

  Senaryo (varsayilan 100k satir x 32 B, benchv3 ile ayni deger uretimi):
    1. baslangic yuklemesi          -> boy0
    2. tum satirlari guncelle (ayni boyut, farkli icerik) -> boy1  (sisme %)
    3. yarisini sil (cift anahtarlar)                     -> boy2
    4. yeni anahtarlarla yeniden ekle (delik/freelist)    -> boy3  (asıl sisme)
    5. tum CANLI satirlari buyut (32 -> 48 B)             -> boy4
    6. son bir guncelleme turu (ayni boyut)                -> boy5
    7. hepsini sil (bosaltma)                              -> boy6
    8. ayni son kumenin taze yuklemesi                     -> taze (ideal boy)
  Sisme olcumu boy/taze oraniyla yapilir; boy3/boy0 churn sisirmesidir.

  Her adimdan sonra temiz kapanis yapilir; olcum dosyadaki GERCEK boydur
  (TrimToLogical kapanista mantiksal boya kisar).

  Kullanim: bloatbench <dizin> [satir_sayisi] [deger_bayt]
}

{$mode delphi}{$H+}

uses
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  Classes, SysUtils, VDbPage, VDbPageStore, VDbPageHeap,
  VDbPageEngine, VDbPageWal;

var
  gDir: string;
  gQpf: Int64;

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

function LiveKey(N, i: Integer): QWord;
begin
  { 3. adim cift anahtarlari sildi (1..N), 4. adim N+1..N+N/2 ekledi.
    Canli dizi: 1,3,5,...,N-1, N+1,...,N+N/2 — toplam N anahtar. }
  if i < (N div 2) then
    Result := QWord(2 * i + 1)
  else
    Result := QWord(N + (i - (N div 2)) + 1);
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

procedure RunEng(const Db: string; Create: Boolean; out Count: Integer;
  out HeapPages, OvfPages: LongWord);
var
  eng: TVdbPageEngine;
  st: TVdbHeapStats;
begin
  eng := TVdbPageEngine.Create(Db, 512);
  try
    eng.Open(Create);
    Count := eng.Count;
    st := eng.Stats;
    HeapPages := st.HeapPages;
    OvfPages := st.OverflowPages;
  finally
    eng.Free;
  end;
end;

{ Ayni canli veri kumesini sifirdan yukler; donen boy "ideal" boyuttur.
  Sisme = gercek boy / taze boy - 1 (freelist'teki bos sayfalar dahil). }
function FreshSize(const Db: string; N, Len, Seed: Integer): Int64;
var
  eng: TVdbPageEngine;
  i: Integer;
  k: QWord;
  v: TBytes;
begin
  if FileExists(Db) then DeleteFile(Db);
  if FileExists(Db + '.wal') then DeleteFile(Db + '.wal');
  if FileExists(Db + '.idx') then DeleteFile(Db + '.idx');
  eng := TVdbPageEngine.Create(Db, 512);
  try
    eng.Open(True);
    for i := 0 to N - 1 do
    begin
      k := LiveKey(N, i);
      MakeVal(k, Len, Seed, v);
      eng.Insert(k, v);
    end;
    eng.Commit(True);
  finally
    eng.Free;
  end;
  Result := FileSizeOf(Db);
end;

var
  N, VLen, i, ok, cnt: Integer;
  db: string;
  eng: TVdbPageEngine;
  v: TBytes;
  k: QWord;
  t0, tUpd, tDel, tIns, tUpd2, tUpd3: Int64;
  b0, b1, b2, b3, b4, b5, b6, bTaze, bIdx, bWal: Int64;
  hp, ov: LongWord;

begin
  N := 100000;
  VLen := 32;
  if ParamCount >= 1 then gDir := ParamStr(1) else gDir := GetCurrentDir;
  if ParamCount >= 2 then N := StrToIntDef(ParamStr(2), N);
  if ParamCount >= 3 then VLen := StrToIntDef(ParamStr(3), VLen);
  if not DirectoryExists(gDir) then ForceDirectories(gDir);
  db := IncludeTrailingPathDelimiter(gDir) + 'bloat.odb';
  if FileExists(db) then DeleteFile(db);
  if FileExists(db + '.wal') then DeleteFile(db + '.wal');
  if FileExists(db + '.idx') then DeleteFile(db + '.idx');

  WriteLn('VDB v3 bloatbench - UPDATE/DELETE sisme');
  WriteLn(Format('dizin=%s  satir=%d  deger=%d B', [gDir, N, VLen]));
  WriteLn;

  { 1: baslangic yuklemesi }
  eng := TVdbPageEngine.Create(db, 512);
  try
    eng.Open(True);
    t0 := NowUs;
    for i := 1 to N do
    begin
      MakeVal(i, VLen, 3, v);
      eng.Insert(QWord(i), v);
    end;
    eng.Commit(True);
    WriteLn(Format('yukleme    : %d ms  (%.2f us/satir)', [(NowUs - t0) div 1000,
      (NowUs - t0) / N]));
  finally
    eng.Free;
  end;
  b0 := FileSizeOf(db);
  RunEng(db, False, cnt, hp, ov);
  WriteLn(Format('boy0       : %d bayt  (%.1f B/satir)  anahtar=%d  heap=%d  tas=%d',
    [b0, b0 / N, cnt, hp, ov]));

  { 2: tumunu guncelle - ayni boyut }
  eng := TVdbPageEngine.Create(db, 512);
  try
    eng.Open(False);
    t0 := NowUs;
    ok := 0;
    for i := 1 to N do
    begin
      MakeVal(i, VLen, 99, v);
      if eng.Update(QWord(i), v) then Inc(ok);
    end;
    eng.Commit(True);
    tUpd := NowUs - t0;
  finally
    eng.Free;
  end;
  b1 := FileSizeOf(db);
  RunEng(db, False, cnt, hp, ov);
  WriteLn(Format('guncelleme : %d ms  (%.2f us/satir, %d/%d)  boy1=%d  sisme=%%%.2f',
    [tUpd div 1000, tUpd / N, ok, N, b1, (b1 / b0 - 1) * 100]));
  WriteLn(Format('           anahtar=%d  heap=%d  tas=%d', [cnt, hp, ov]));

  { 3: yarisini sil }
  eng := TVdbPageEngine.Create(db, 512);
  try
    eng.Open(False);
    t0 := NowUs;
    ok := 0;
    for i := 1 to N do
      if (i and 1) = 0 then
        if eng.Delete(QWord(i)) then Inc(ok);
    eng.Commit(True);
    tDel := NowUs - t0;
  finally
    eng.Free;
  end;
  b2 := FileSizeOf(db);
  RunEng(db, False, cnt, hp, ov);
  WriteLn(Format('silme      : %d ms  (%.2f us/silme, %d)  boy2=%d  delta=%%%.2f  anahtar=%d',
    [tDel div 1000, tDel / (N / 2), ok, b2, (b2 / b0 - 1) * 100, cnt]));

  { 4: yeni anahtarlarla yeniden ekle (freelist) }
  eng := TVdbPageEngine.Create(db, 512);
  try
    eng.Open(False);
    t0 := NowUs;
    for i := 1 to (N div 2) do
    begin
      MakeVal(QWord(N + i), VLen, 7, v);
      eng.Insert(QWord(N + i), v);
    end;
    eng.Commit(True);
    tIns := NowUs - t0;
  finally
    eng.Free;
  end;
  b3 := FileSizeOf(db);
  RunEng(db, False, cnt, hp, ov);
  WriteLn(Format('yeniden    : %d ms  (%.2f us/satir)  boy3=%d  anahtar=%d  heap=%d  tas=%d',
    [tIns div 1000, tIns / (N div 2), b3, cnt, hp, ov]));

  { 5: tum canli anahtarlari buyut (VLen -> VLen+16) }
  eng := TVdbPageEngine.Create(db, 512);
  try
    eng.Open(False);
    t0 := NowUs;
    ok := 0;
    for i := 0 to N - 1 do
    begin
      k := LiveKey(N, i);
      MakeVal(k, VLen + 16, 55, v);
      if eng.Update(k, v) then Inc(ok);
    end;
    eng.Commit(True);
    tUpd2 := NowUs - t0;
  finally
    eng.Free;
  end;
  b4 := FileSizeOf(db);
  RunEng(db, False, cnt, hp, ov);
  WriteLn(Format('buyutme    : %d ms  (%.2f us/satir, %d/%d)  boy4=%d  sisme=%%%.2f',
    [tUpd2 div 1000, tUpd2 / N, ok, N, b4, (b4 / b3 - 1) * 100]));
  WriteLn(Format('           anahtar=%d  heap=%d  tas=%d', [cnt, hp, ov]));

  { 6: son tur ayni boyut guncelleme (karistik desen) }
  eng := TVdbPageEngine.Create(db, 512);
  try
    eng.Open(False);
    t0 := NowUs;
    ok := 0;
    for i := 0 to N - 1 do
    begin
      k := LiveKey(N, i);
      MakeVal(k, VLen + 16, 77, v);
      if eng.Update(k, v) then Inc(ok);
    end;
    eng.Commit(True);
    tUpd3 := NowUs - t0;
  finally
    eng.Free;
  end;
  b5 := FileSizeOf(db);
  RunEng(db, False, cnt, hp, ov);
  WriteLn(Format('son tur    : %d ms  (%.2f us/satir, %d/%d)  boy5=%d  sisme=%%%.2f  anahtar=%d',
    [tUpd3 div 1000, tUpd3 / N, ok, N, b5, (b5 / b4 - 1) * 100, cnt]));

  { 7: hepsini sil — TrimToLogical bosaltabiliyor mu? }
  eng := TVdbPageEngine.Create(db, 512);
  try
    eng.Open(False);
    t0 := NowUs;
    ok := 0;
    for i := 0 to N - 1 do
      if eng.Delete(LiveKey(N, i)) then Inc(ok);
    eng.Commit(True);
    tDel := NowUs - t0;
  finally
    eng.Free;
  end;
  b6 := FileSizeOf(db);
  RunEng(db, False, cnt, hp, ov);
  WriteLn(Format('tam silme  : %d ms  (%.2f us/silme, %d)  boy6=%d  anahtar=%d  heap=%d',
    [tDel div 1000, tDel / N, ok, b6, cnt, hp]));

  { Referans: ayni son kumenin taze yuklemesi (ideal boy). }
  bTaze := FreshSize(gDir + '\taze.odb', N, VLen + 16, 77);

  bIdx := FileSizeOf(db + '.idx');
  bWal := FileSizeOf(db + '.wal');
  WriteLn;
  WriteLn('=== ozet ===');
  WriteLn(Format('boy0=%d  boy1=%d (upd %%%.2f)  boy2=%d (del %%%.2f)  ' +
    'boy3=%d  boy4=%d (grow %%%.2f)  boy5=%d (upd %%%.2f)  boy6=%d',
    [b0, b1, (b1 / b0 - 1) * 100, b2, (b2 / b0 - 1) * 100, b3, b4,
     (b4 / b3 - 1) * 100, b5, (b5 / b4 - 1) * 100, b6]));
  WriteLn(Format('taze boy (ideal)=%d B  churn sonrasi sisme=%%%.2f (boy5/taze)',
    [bTaze, (b5 / bTaze - 1) * 100]));
  WriteLn(Format('yeniden ekleme sisirmesi: boy3/boy0=%%%.2f (hedef <= %%5)',
    [(b3 / b0 - 1) * 100]));
  WriteLn(Format('idx=%d B  wal=%d B', [bIdx, bWal]));
end.