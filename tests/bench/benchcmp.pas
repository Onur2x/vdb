program benchcmp;
{ VDB v3 kiyas takimi (Sprint 0).
  Amac: ayni is yukunu VDB uzerinde olcup tekrar edilebilir sayi uretmek.
  Olculen: toplu INSERT, autocommit INSERT, PK nokta, parse-only,
           COUNT(*), acilis, dosya boyutu.

  Kullanim:
    benchcmp <calisma_dizini> [satir_sayisi] [tekrar_sayisi]

  Not: Sureler GetTickCount64 ile olculur (ms). Tekrar sayisi >1 ise
  her metrik icin medyan yazdirilir. }
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, VDbCore, VDbTypes, VDbTable, VDbSql;

type
  TMsArr = array of Double;

var
  D: string;
  NRow, NRep, NTrial: Integer;
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  R: TSqlResult;
  Vals: TStrArray;
  PKV: Int64;

function Median(const A: TMsArr): Double;
var
  b: TMsArr;
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
    kv.Close;
    sq.Free;
    tb.Free;
    kv.Free;
    tb := nil;
    kv := nil;
    sq := nil;
  end;
end;

procedure Fresh(const Dir: string);
begin
  CloseAll;
  ForceDirectories(Dir);
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  kv.Open(Dir);
  tb.Open(Dir);
end;

function DirOf(const Base, Nm: string): string;
begin
  Result := Base + PathDelim + Nm;
end;

{ Tek bir olcum turu: yeni DB kur, olc, kapat. Sonuclari A'ya yazar. }
procedure OneTrial(const Base: string; out MsBatch, MsAuto, MsParse,
  MsPk, MsCount, MsOpen: Double; out FileBytes: Int64);
var
  p: string;
  T0: QWord;
  j: Integer;
begin
  p := DirOf(Base, 'run');
  if DirectoryExists(p) then
  begin
    // temiz baslangic: onceki turun dosyalarini sil
    DeleteFile(p + PathDelim + 'veritabani.odb');
    DeleteFile(p + PathDelim + 'veritabani.odb.idx');
    DeleteFile(p + PathDelim + 'veritabani.odb.undo');
  end;
  Fresh(p);
  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');

  T0 := GetTickCount64;
  kv.BeginBatch;
  for j := 1 to NRow do
    tb.Insert('t', ['id', 'a', 'b'],
      [IntToStr(j), IntToStr(j * 3), 'satir-' + IntToStr(j)]);
  kv.CommitBatch;
  MsBatch := GetTickCount64 - T0;

  T0 := GetTickCount64;
  for j := 1 to NRep do
    sq.Exec(Format('INSERT INTO t(id,a,b) VALUES (%d,%d,''auto'')',
      [1000000 + j, j]));
  MsAuto := GetTickCount64 - T0;

  T0 := GetTickCount64;
  for j := 1 to NRep do
    R := sq.Exec('SELECT 1');
  MsParse := GetTickCount64 - T0;

  T0 := GetTickCount64;
  for j := 1 to NRep do
    R := sq.Exec(Format('SELECT a FROM t WHERE id = %d', [PKV]));
  MsPk := GetTickCount64 - T0;

  T0 := GetTickCount64;
  R := sq.Exec('SELECT COUNT(*) FROM t');
  MsCount := GetTickCount64 - T0;

  FileBytes := kv.DataFileSize;
  tb.Close;
  kv.Close;

  T0 := GetTickCount64;
  kv.Open(p);
  MsOpen := GetTickCount64 - T0;
  CloseAll;
end;

var
  tbA, taA, tpA, tkA, tcA, toA: TMsArr;
  bA: array of Int64;
  t: Integer;
  fs: Int64;
  b1, b2, b3, b4, b5, b6: Double;
begin
  D := ParamStr(1);
  if D = '' then D := IncludeTrailingPathDelimiter(GetTempDir) + 'vdbbenchcmp';
  NRow := StrToIntDef(ParamStr(2), 200000);
  NRep := StrToIntDef(ParamStr(3), 20000);
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
  WriteLn('=== VDB  N_ROWS=', NRow, '  N_REP=', NRep,
    '  tur=', NTrial, '  (medyan) ===');
  fs := bA[0];
  WriteLn(Format('dosya boyutu    : %d bayt  (%.1f B/satir)',
    [fs, fs / NRow]));
  WriteLn(Format('toplu INSERT    : %8.0f ms  (%.3f us/satir)',
    [Median(tbA), Median(tbA) * 1000 / NRow]));
  WriteLn(Format('autocommit INS  : %8.0f ms  (%.3f ms/satir)',
    [Median(taA), Median(taA) / NRep]));
  WriteLn(Format('parse-only SEL 1: %8.0f ms  (%.2f us/cagri)',
    [Median(tpA), Median(tpA) * 1000 / NRep]));
  WriteLn(Format('PK nokta        : %8.0f ms  (%.2f us/sorgu)',
    [Median(tkA), Median(tkA) * 1000 / NRep]));
  WriteLn(Format('COUNT(*)        : %8.0f ms', [Median(tcA)]));
  WriteLn(Format('acilis          : %8.0f ms', [Median(toA)]));
  CloseAll;
  WriteLn('== bitti');
end.
