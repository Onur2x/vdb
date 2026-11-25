program dirty_refresh;
{ SKILL8 (v3.83) - KIRLI CERCEVE / TAM TAZELEME KAPISI.

  Amac: A oturumu bir sayfayi degistirip commit eder ama cerceve onbellekte
  KIRLI kalir. B oturumu AYNI sayfayi degistirip diske yazar (daha yeni imaj).
  A tam tazeleme (StoreRefreshed needFull) yapar ve ayni sayfaya yeniden
  yazar. Tazeleme sirasinda kirli cerceve ATILMAZSA, A'nin bayat imaji
  diske B'nin daha yeni imajinin uzerine yazilir: B'nin silmesi GERI GELIR.

  Kapı: B'nin sildigi anahtar taze okumada YOK olmali (fark=0).
  Once (DropCache) -> anahtar geri gelir; sonra (DropCacheAll) -> gelmez.

  Kullanicinin gercek DB dosyalarina dokunulmaz; her kosu izole tmp dizini. }

{$mode delphi}{$H+}
{$IFDEF UNIX}{$DEFINE USE_CTHREADS}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  VDbBackendApi, VDbFactory, VDbBackendV3, VDbPageEngine;

const
  VICTIM = 42;
  ANCHOR = 43;
  PAD_BASE = 100;

var
  GPass, GFail: Integer;
  GDir: string;
  GDb: string;

procedure Chk(const AName: string; AOk: Boolean; const ADetail: string);
begin
  if AOk then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' - ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' - ', ADetail);
  end;
  Flush(Output);
end;

function Val(const S: string): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

function ValStr(const B: TBytes): string;
begin
  SetLength(Result, Length(B));
  if Length(B) > 0 then
    Move(B[0], Result[1], Length(B));
end;

procedure WipeDir(const ADir: string);
var
  sr: TSearchRec;
  d: string;
begin
  ForceDirectories(ADir);
  d := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(d + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        if (sr.Attr and faDirectory) <> 0 then
          WipeDir(d + sr.Name)
        else
          SysUtils.DeleteFile(d + sr.Name);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

{ Taze, salt okunur oturumda anahtar durumu. }
function FreshHas(AKey: Integer; out AVal: string): Boolean;
var
  R: TVdbBackendV3;
  B: TBytes;
begin
  AVal := '';
  R := TVdbBackendV3.CreateReadOnly(GDb);
  try
    Result := R.Get(AKey, B);
    if Result then AVal := ValStr(B);
  finally
    R := nil;
  end;
end;

function FreshCount: Integer;
var
  R: TVdbBackendV3;
begin
  R := TVdbBackendV3.CreateReadOnly(GDb);
  try
    Result := R.Count;
  finally
    R := nil;
  end;
end;

var
  A, B: TVdbBackendV3;
  k: Integer;
  s: string;
  rep: string;
  ok: Boolean;
  n0, n1: Integer;
begin
  GPass := 0;
  GFail := 0;
  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp');
  WipeDir(GDir);
  GDb := GDir + 'veritabani.odb';

  { -- 1. A: temel sayfa icerigi, flush'suz commit ---------------------- }
  A := TVdbBackendV3.Create(GDb);
  A.DurableOnFlush := False;
  A.BeginBatch;
  A.Put(VICTIM, Val('canli'));
  A.Put(ANCHOR, Val('a0'));
  for k := 0 to 7 do
    A.Put(PAD_BASE + k, Val('dolgu-' + IntToStr(k)));
  A.CommitBatch;                       { cerceve KIRLI kalir (flush yok) }
  n0 := A.Count;
  Chk('A_temel_sayim', n0 = 10, 'count=' + IntToStr(n0));

  { -- 2. B: ayni sayfayi degistir, diske yaz ---------------------------- }
  B := TVdbBackendV3.Create(GDb);
  B.DurableOnFlush := True;
  B.BeginBatch;
  B.Delete(VICTIM);
  B.CommitBatch;
  B.Engine.Checkpoint(True);            { B imajini DISKE indir }
  s := '';
  Chk('B_silme_kalici', not FreshHas(VICTIM, s), 'taze_var=' + BoolToStr(FreshHas(VICTIM, s), True));
  B := nil;

  { -- 3. A: tam tazeleme + ayni sayfaya yeniden yaz --------------------- }
  A.BeginBatch;
  A.Put(ANCHOR, Val('a1'));
  A.CommitBatch;
  A.Engine.Checkpoint(True);
  A := nil;

  { -- 4. Taze okuma: B'nin silmesi geri geldi mi? ----------------------- }
  s := '';
  Chk('silme_geri_gelmedi', not FreshHas(VICTIM, s), 'taze_var=' + BoolToStr(FreshHas(VICTIM, s), True) + ' deger=' + s);
  n1 := FreshCount;
  Chk('toplam_sayim', n1 = 9, 'count=' + IntToStr(n1) + ' beklenen=9');

  ok := False;
  begin
    A := TVdbBackendV3.CreateReadOnly(GDb);
    try
      ok := (A as TVdbBackendV3).Verify(rep);
    finally
      A := nil;
    end;
  end;
  Chk('verify_temiz', ok, rep);

  WriteLn('SONUC dirty_refresh PASS=', GPass, ' FAIL=', GFail);
  Flush(Output);
  Halt(GFail);
end.
