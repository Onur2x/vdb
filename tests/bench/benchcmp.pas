program benchcmp;
{ VDB v3 kiyas takimi (Sprint 0).
  Amac: ayni is yukunu VDB uzerinde olcup tekrar edilebilir sayi uretmek.
  Olculen: toplu INSERT, autocommit INSERT, PK nokta, parse-only,
           COUNT(*), acilis, dosya boyutu.

  Kullanim:
    benchcmp <calisma_dizini> [satir_sayisi] [tekrar_sayisi] [--backend=v2|v3]

  Sprint 3.12: `--backend=v3` sayfa motorunu ayni is yukununde kosar; boylece
  v2/v3 sayilari ayni tartiyla karsilastirilir. Bilinmeyen backend exit 2.

  Sprint 3.13/v3.1: sureler artik QPC (QueryPerformanceCounter) ile MIKRO
  saniye cozunurlugunde olculur. Neden: GetTickCount64 ~15,6 ms'lik
  kuantalarla ilerler; tek atimlik COUNT(*) ve acilis olcumleri bu yuzden
  "0 ms" ya da 15 ms sicramasi gosteriyordu. Dongu olcumleri de ayni saati
  kullanir; ciktilar ms cinsinden 1 ondalikla yazilir. Tekrar sayisi >1 ise
  her metrik icin medyan yazdirilir. }
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, Math, VDbCore, VDbTypes, VDbTable, VDbSql, VDbSync,
  VDbBackendApi, VDbBackendV3;

type
  TUsArr = array of Double;

var
  D: string;
  NRow, NRep, NTrial: Integer;
  kv: TVDb;
  be: IVDbBackend;
  tb: TVTableDb;
  sq: TVSql;
  R: TSqlResult;
  Vals: TStrArray;
  PKV: Int64;
  gBackend: string;
  gBackendBytes: Int64;
  gQpf: Int64;

{ QPC tabanli monoton saat (mikrosaniye). Unix'te GetTickCount64'e duser
  (ms x 1000); oradaki olcumler ms cozunurlugunde kalir. }
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
  { Once frekansi bol, sonra carp: c * 1000000 tasabilir. }
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

function Median(const A: TUsArr): Double;
var
  b: TUsArr;
  i, j: Integer;
  t: Double;
begin
  b := Copy(A);
  for i := 1 to High(b) do
  begin
    t := b[i];
    j := i - 1;
    while (j >= 0) and (b[j] > t) do
    begin
      b[j + 1] := b[j];
      Dec(j);
    end;
    b[j + 1] := t;
  end;
  if Length(b) = 0 then Exit(0);
  if Odd(Length(b)) then
    Result := b[Length(b) div 2]
  else
    Result := (b[Length(b) div 2 - 1] + b[Length(b) div 2]) / 2;
end;

procedure CloseAll;
begin
  if tb <> nil then
  begin
    tb.Close;
    if kv <> nil then kv.Close;
    sq.Free;
    tb.Free;
    if kv <> nil then kv.Free;
    kv := nil;
    be := nil;
    tb := nil;
    sq := nil;
  end;
end;

procedure Fresh(const Dir: string);
var
  dbPath: string;
begin
  CloseAll;
  ForceDirectories(Dir);
  if gBackend = 'v3' then
  begin
    dbPath := IncludeTrailingPathDelimiter(Dir) + 'veritabani.odb';
    be := TVdbBackendV3.Create(dbPath, True, 512);
    tb := TVTableDb.CreateBackend(be);
  end
  else
  begin
    kv := TVDb.Create;
    tb := TVTableDb.Create(kv);
  end;
  sq := TVSql.Create(tb);
  if kv <> nil then kv.Open(Dir);
  tb.Open(Dir);
end;

{ v3'te `DataFileSize` yok; dosya motor tarafindan KILITLI oldugu icin
  boy stat() ile olculur (Windows/Unix ayni davranis). }
function BackendFileBytes(const Dir: string): Int64;
begin
  if gBackend = 'v3' then
    Result := VDbFileBytes(IncludeTrailingPathDelimiter(Dir) + 'veritabani.odb')
  else
    Result := kv.DataFileSize;
end;

function DirOf(const Base, Nm: string): string;
begin
  Result := Base + PathDelim + Nm;
end;

{ Tek bir olcum turu: yeni DB kur, olc, kapat. Sonuclari A'ya yazar (us). }
procedure OneTrial(const Base: string; out UsBatch, UsAuto, UsParse,
  UsPk, UsCount, UsOpen: Double; out FileBytes: Int64);
var
  p: string;
  T0: Int64;
  j: Integer;
begin
  p := DirOf(Base, 'run');
  if DirectoryExists(p) then
  begin
    // temiz baslangic: onceki turun dosyalarini sil
    DeleteFile(p + PathDelim + 'veritabani.odb');
    DeleteFile(p + PathDelim + 'veritabani.odb.idx');
    DeleteFile(p + PathDelim + 'veritabani.odb.wal');
    DeleteFile(p + PathDelim + 'veritabani.odb.undo');
  end;
  Fresh(p);
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');

  T0 := NowUs;
  if kv <> nil then
  begin
    kv.BeginBatch;
    for j := 1 to NRow do
      tb.Insert('t', ['id', 'a', 'b'],
        [IntToStr(j), IntToStr(j * 3), 'satir-' + IntToStr(j)]);
    kv.CommitBatch;
  end
  else
  begin
    tb.BeginBatch;
    for j := 1 to NRow do
      tb.Insert('t', ['id', 'a', 'b'],
        [IntToStr(j), IntToStr(j * 3), 'satir-' + IntToStr(j)]);
    tb.CommitBatch;
  end;
  UsBatch := NowUs - T0;

  T0 := NowUs;
  for j := 1 to NRep do
    sq.Exec(Format('INSERT INTO t(id,a,b) VALUES (%d,%d,''auto'')',
      [1000000 + j, j]));
  UsAuto := NowUs - T0;

  T0 := NowUs;
  for j := 1 to NRep do
    R := sq.Exec('SELECT 1');
  UsParse := NowUs - T0;

  T0 := NowUs;
  for j := 1 to NRep do
    R := sq.Exec(Format('SELECT a FROM t WHERE id = %d', [PKV]));
  UsPk := NowUs - T0;

  { Tek atimlik olcum: QPC sart (tick ~15,6 ms kuantalardi). }
  T0 := NowUs;
  R := sq.Exec('SELECT COUNT(*) FROM t');
  UsCount := NowUs - T0;

  { v3.1: dosya boyu KAPANISTAN SONRA olculur. Motor acikken dosya 256 KB'lik
    parcalarla onceden ayrilmis olabilir (yazim hizi icin); kapanis mantiksal
    boya kirpar. Kullanicinin diskte gordugu boy budur. v2'de dosya acikken
    de tam boydadir. }
  if gBackend = 'v3' then FileBytes := 0
  else FileBytes := BackendFileBytes(p);
  tb.Close;
  if kv <> nil then kv.Close;
  sq.Free;
  tb.Free;
  if kv <> nil then kv.Free;
  sq := nil;
  tb := nil;
  kv := nil;
  be := nil;
  if gBackend = 'v3' then FileBytes := BackendFileBytes(p);
  { "Acilis" = veritabani sorguya hazir: v2'de kv.Open (+sema), v3'te
    motor acilisi + sema yuklemesi. Iki taraf da ayni isi kapsar. }
  T0 := NowUs;
  if gBackend = 'v3' then
  begin
    be := TVdbBackendV3.Create(IncludeTrailingPathDelimiter(p) + 'veritabani.odb',
      False, 512);
    tb := TVTableDb.CreateBackend(be);
    tb.Open(p);
  end
  else
  begin
    kv := TVDb.Create;
    tb := TVTableDb.Create(kv);
    sq := TVSql.Create(tb);
    kv.Open(p);
    tb.Open(p);
  end;
  UsOpen := NowUs - T0;
  CloseAll;
end;

var
  tbA, taA, tpA, tkA, tcA, toA: TUsArr;
  bA: array of Int64;
  t, k: Integer;
  fs: Int64;
  b1, b2, b3, b4, b5, b6: Double;
  arg: string;
begin
  gBackend := 'v2';
  D := '';
  NRow := -1;
  NRep := -1;
  k := 0;
  for t := 1 to ParamCount do
  begin
    arg := ParamStr(t);
    if Pos('--backend=', LowerCase(arg)) = 1 then
      gBackend := Copy(arg, Length('--backend=') + 1, MaxInt)
    else
    begin
      Inc(k);
      case k of
        1: D := arg;
        2: NRow := StrToIntDef(arg, -1);
        3: NRep := StrToIntDef(arg, -1);
      end;
    end;
  end;
  gBackend := LowerCase(Trim(gBackend));
  if (gBackend <> 'v2') and (gBackend <> 'v3') then
  begin
    WriteLn(StdErr, 'bilinmeyen backend: ', gBackend, ' (v2|v3)');
    Halt(2);
  end;
  if D = '' then D := IncludeTrailingPathDelimiter(GetTempDir) + 'vdbbenchcmp';
  if NRow < 0 then NRow := 200000;
  if NRep < 0 then NRep := 20000;
  NTrial := 3;
  PKV := (NRow * 5) div 8;   // tablo icinde bir nokta

  ForceDirectories(D);
  SetLength(tbA, NTrial);
  SetLength(taA, NTrial);
  SetLength(tpA, NTrial);
  SetLength(tkA, NTrial);
  SetLength(tcA, NTrial);
  SetLength(toA, NTrial);
  SetLength(bA, NTrial);

  for t := 0 to NTrial - 1 do
  begin
    WriteLn('tur ', t + 1, '/', NTrial, ' kosuyor...');
    OneTrial(D, b1, b2, b3, b4, b5, b6, fs);
    tbA[t] := b1;
    taA[t] := b2;
    tpA[t] := b3;
    tkA[t] := b4;
    tcA[t] := b5;
    toA[t] := b6;
    bA[t] := fs;
  end;

  WriteLn;
  WriteLn('=== VDB backend=', gBackend, '  N_ROWS=', NRow, '  N_REP=', NRep,
    '  tur=', NTrial, '  (medyan) ===');
  fs := bA[0];
  WriteLn(Format('dosya boyutu    : %d bayt  (%.1f B/satir)',
    [fs, fs / NRow]));
  WriteLn(Format('toplu INSERT    : %8.1f ms  (%.3f us/satir)',
    [Median(tbA) / 1000, Median(tbA) / NRow]));
  WriteLn(Format('autocommit INS  : %8.1f ms  (%.3f ms/satir)',
    [Median(taA) / 1000, Median(taA) / 1000 / NRep]));
  WriteLn(Format('parse-only SEL 1: %8.1f ms  (%.2f us/cagri)',
    [Median(tpA) / 1000, Median(tpA) / NRep]));
  WriteLn(Format('PK nokta        : %8.1f ms  (%.2f us/sorgu)',
    [Median(tkA) / 1000, Median(tkA) / NRep]));
  WriteLn(Format('COUNT(*)        : %8.1f ms', [Median(tcA) / 1000]));
  WriteLn(Format('acilis          : %8.1f ms', [Median(toA) / 1000]));
  CloseAll;
  WriteLn('== bitti');
end.
