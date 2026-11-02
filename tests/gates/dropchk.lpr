program dropchk;
{ DROP TABLE + buyuk batch sayfa bozulmasi yeniden uretici (P-75 dugumunu
  izler). Kullanim: dropchk <dizin> [satir_sayisi] [mod]
  mod 1: buyuk batch -> DROP -> buyuk batch -> kapat/yeniden ac
  mod 2: batch ICINDE DROP -> ayni batch'te buyuk insert -> commit
  mod 3: DROP -> buyuk batch -> DROP -> buyuk batch (iki tur) }
{$mode delphi}{$H+}
uses
  { FPC/Unix: cthreads programin EN BASINDA olmali (TEvent/TThread). }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  SysUtils, Classes,
  VDbCore, VDbTypes, VDbTable, VDbSql,
  VDbBackendApi, VDbBackendV3;

var
  gQpf: Int64;

function NowUs: Int64;
var
  c: Int64;
begin
  {$IFDEF MSWINDOWS}
  if gQpf = 0 then
    if not QueryPerformanceFrequency(gQpf) then gQpf := 1000;
  QueryPerformanceCounter(c);
  Result := (c * 1000000) div gQpf;
  {$ELSE}
  { Unix: bu arac yalnizca kaba sure yazdirir; Now (~ms cozunurluk)
    yeterlidir. }
  Result := Trunc(Now * 86400 * 1000000);
  {$ENDIF}
end;

var
  be: IVDbBackend;
  tb: TVTableDb;
  sq: TVSql;
  N, i, mode, tur: Integer;
  t0: Int64;
  cn: array[0..2] of string;
  p: string;
  R: TSqlResult;

procedure BigBatch(const Table: string);
begin
  tb.BeginBatch;
  for i := 1 to N do
    tb.Insert(Table, cn, [IntToStr(i), IntToStr(i * 3), 'satir-' + IntToStr(i)]);
  tb.CommitBatch;
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'kullanim: dropbug <dizin> [satir_sayisi] [mod]');
    Halt(2);
  end;
  p := ParamStr(1);
  N := 100000;
  if ParamCount >= 2 then N := StrToIntDef(ParamStr(2), 100000);
  mode := 1;
  if ParamCount >= 3 then mode := StrToIntDef(ParamStr(3), 1);
  cn[0] := 'id'; cn[1] := 'a'; cn[2] := 'b';

  ForceDirectories(p);
  SysUtils.DeleteFile(p + PathDelim + 'veritabani.odb');
  SysUtils.DeleteFile(p + PathDelim + 'veritabani.odb.idx');
  SysUtils.DeleteFile(p + PathDelim + 'veritabani.odb.wal');
  SysUtils.DeleteFile(p + PathDelim + 'veritabani.odb.undo');
  be := TVdbBackendV3.Create(IncludeTrailingPathDelimiter(p) + 'veritabani.odb', True, 512);
  tb := TVTableDb.CreateBackend(be);
  sq := TVSql.Create(tb);
  tb.Open(p);

  try
    sq.Exec('CREATE TABLE t1(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
    sq.Exec('CREATE TABLE t2(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');

    t0 := NowUs;
    case mode of
      1:
        begin
          WriteLn('mod 1: buyuk batch -> DROP t1 -> buyuk batch');
          BigBatch('t1');
          WriteLn('  t1 ', N, ' satir yazildi');
          sq.Exec('DROP TABLE t1');
          WriteLn('  t1 dusuruldu');
          BigBatch('t2');
          WriteLn('  t2 ', N, ' satir yazildi');
        end;
      2:
        begin
          WriteLn('mod 2: batch icinde DROP -> ayni batchte buyuk insert');
          BigBatch('t1');
          WriteLn('  t1 ', N, ' satir yazildi');
          tb.BeginBatch;
          sq.Exec('DROP TABLE t1');
          WriteLn('  t1 batch icinde dusuruldu');
          for i := 1 to N do
            tb.Insert('t2', cn, [IntToStr(i), IntToStr(i * 3), 'satir-' + IntToStr(i)]);
          tb.CommitBatch;
          WriteLn('  t2 ', N, ' satir yazildi (ayni batch)');
        end;
      3:
        begin
          WriteLn('mod 3: iki tur (batch -> DROP -> batch) x2');
          for tur := 1 to 2 do
          begin
            try sq.Exec('DROP TABLE t1'); except end;   { ilk turda yok }
            sq.Exec('CREATE TABLE t1(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
            BigBatch('t1');
            sq.Exec('DROP TABLE t1');
            try sq.Exec('DROP TABLE t2'); except end;   { ilk turda program basi CREATE'i kaldirir }
            sq.Exec('CREATE TABLE t2(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
            BigBatch('t2');
            sq.Exec('DROP TABLE t2');
            WriteLn('  tur ', tur, ' tamam');
          end;
          try sq.Exec('DROP TABLE t1'); except end;
          sq.Exec('CREATE TABLE t1(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
          BigBatch('t1');
        end;
    end;

    tb.Close;
    WriteLn(Format('yazma %.1f ms — kapatildi, yeniden aciliyor', [(NowUs - t0) / 1000]));

    { Yeniden ac: sayfa dogrulamasi burada patlamali (bozulma varsa). }
    be := TVdbBackendV3.Create(IncludeTrailingPathDelimiter(p) + 'veritabani.odb', False, 512);
    tb := TVTableDb.CreateBackend(be);
    sq := TVSql.Create(tb);
    tb.Open(p);
    if mode = 3 then p := 't1' else p := 't2';   { mod 3 sonunda kalan tablo t1 }
    R := sq.Exec('SELECT COUNT(*) FROM ' + p);
    WriteLn('  yeniden acildi; ', p, ' satir sayisi = ', R.Rows[0][0], ' (beklenen ', N, ')');
    if R.Rows[0][0] <> IntToStr(N) then
    begin
      WriteLn('HATA: satir sayisi yanlis!');
      Halt(1);
    end;
    tb.Close;
    WriteLn('TEMIZ: bozulma yok');
  except
    on E: Exception do
    begin
      WriteLn('HATA YAKALANDI: ', E.ClassName, ': ', E.Message);
      raise;   { -gl derlemesinde islenmemis istisna yigin izini basar }
    end;
  end;
end.
