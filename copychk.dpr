{ H13 dogrulama: COPY FROM (CSV + TEXT)
  - CSV tirnak/ayirici/satir-sonu kacislari
  - TEXT varsayilan TAB + '\N' NULL + ters bolu kacislari
  - HEADER, kolon listesi, NULL semantigi
  - ATOMIKLIK: dosya ortasindaki PK ihlali -> hicbir satir yazilmaz
  - yeniden acilis sonrasi kalicilik }
{$mode delphi}
program copychk;

uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, VDbErr;

const
  DIR = 'copychk_dir';
  CSV1 = 'copychk_1.csv';
  TXT1 = 'copychk_1.txt';
  CSV2 = 'copychk_bad.csv';
  CSV3 = 'copychk_cols.csv';

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  fails: Integer;

procedure WipeDir(const D: string);
begin
  SysUtils.DeleteFile(D + '\veritabani.odb');
  SysUtils.DeleteFile(D + '\veritabani.odb.bak');
  SysUtils.DeleteFile(D + '\veritabani.odb.tmp');
  SysUtils.DeleteFile(D + '\veritabani.schema');
  SysUtils.DeleteFile(D + '\veritabani.wal');
  RemoveDir(D);
end;

procedure WFile(const Path: string; const S: RawByteString);
var
  f: TFileStream;
begin
  f := TFileStream.Create(Path, fmCreate);
  try
    if Length(S) > 0 then
      f.Write(S[1], Length(S));
  finally
    f.Free;
  end;
end;

procedure Chk(const Label_: string; Cond: Boolean; const Extra: string = '');
begin
  if Cond then
    Writeln(Format('  %-48s OK   %s', [Label_, Extra]))
  else
  begin
    Writeln(Format('  %-48s FAIL %s', [Label_, Extra]));
    Inc(fails);
  end;
end;

function CountOf(const T: string): Integer;
var
  R: TSqlResult;
begin
  R := sq.Exec('SELECT COUNT(*) FROM ' + T);
  if Length(R.Rows) = 1 then
    Result := StrToIntDef(R.Rows[0][0], -1)
  else
    Result := -1;
end;

function StrOf(const Q: string): string;
var
  R: TSqlResult;
begin
  R := sq.Exec(Q);
  if (Length(R.Rows) = 1) and (Length(R.Rows[0]) >= 1) then
    Result := R.Rows[0][0]
  else
    Result := '<yok>';
end;

procedure ExecExpectError(const Label_, Q: string);
var
  ok: Boolean;
begin
  ok := False;
  try
    sq.Exec(Q);
  except
    on e: EVDbException do
    begin
      ok := True;
      Chk(Label_, True, e.Message);
    end;
  end;
  if not ok then
    Chk(Label_, False, 'hata bekleniyordu');
end;

begin
  fails := 0;
  if DirectoryExists(DIR) then WipeDir(DIR);
  ForceDirectories(DIR);
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(DIR);
    tb.Open(DIR);
    sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER, note TEXT)');

    // 1) CSV: baslik, tirnak icinde ayirici/satir sonu, "" kacisi
    WFile(CSV1,
      'id,name,qty,note'#13#10 +
      '1,"a,b",10,"he said ""hi"""'#13#10 +
      '2,"line1'#10'line2",20,'#13#10 +
      '3,"",30,x'#13#10);

    sq.Exec('COPY t FROM ''copychk_1.csv'' WITH (FORMAT CSV, HEADER)');
    Chk('CSV satir sayisi', CountOf('t') = 3, IntToStr(CountOf('t')));
    Chk('CSV ayirici korunur', StrOf('SELECT name FROM t WHERE id=1') = 'a,b',
      StrOf('SELECT name FROM t WHERE id=1'));
    Chk('CSV "" kacisi', StrOf('SELECT note FROM t WHERE id=1') = 'he said "hi"',
      StrOf('SELECT note FROM t WHERE id=1'));
    Chk('CSV tirnak icinde LF', Pos(#10, StrOf('SELECT name FROM t WHERE id=2')) > 0,
      StringReplace(StrOf('SELECT name FROM t WHERE id=2'), #10, '\n', [rfReplaceAll]));
    Chk('CSV bos alan = NULL', StrOf('SELECT note FROM t WHERE id=2') = '');
    Chk('CSV tirnakli bos = NULL', StrOf('SELECT name FROM t WHERE id=3') = '');

    // 2) TEXT: varsayilan TAB, '\N' NULL, ters bolu kacislari
    WFile(TXT1,
      '4'#9'four'#9'40'#9'\N'#10 +
      '5'#9'five'#9'50'#9'foo\tbar'#10);
    sq.Exec('COPY t FROM ''copychk_1.txt'' WITH (FORMAT TEXT)');
    Chk('TEXT satir sayisi', CountOf('t') = 5, IntToStr(CountOf('t')));
    Chk('TEXT \N = NULL', StrOf('SELECT note FROM t WHERE id=4') = '');
    Chk('TEXT \t kacisi', StrOf('SELECT note FROM t WHERE id=5') = 'foo'#9'bar',
      StringReplace(StrOf('SELECT note FROM t WHERE id=5'), #9, '\t', [rfReplaceAll]));

    // 3) ATOMIKLIK: 2. satirda PK ihlali -> 6 da yazilmamali
    WFile(CSV2,
      '6,six,60,'#10 +
      '1,dup,1,'#10);
    ExecExpectError('PK ihlali hata verir', 'COPY t FROM ''copychk_bad.csv''');
    Chk('ATOMIK: 6 eklenmedi', CountOf('t') = 5, IntToStr(CountOf('t')));
    Chk('ATOMIK: id=6 yok', StrOf('SELECT COUNT(*) FROM t WHERE id=6') = '0');

    // 4) Kolon listesi: yalniz id+name; qty/note NULL
    WFile(CSV3, '7,seven'#10);
    sq.Exec('COPY t (id, name) FROM ''copychk_cols.csv''');
    Chk('kolon listesi satir', StrOf('SELECT COUNT(*) FROM t WHERE id=7') = '1');
    Chk('kolon listesi NULL', StrOf('SELECT COUNT(*) FROM t WHERE id=7 AND qty IS NULL AND note IS NULL') = '1');

    // 5) Yol / secenek hatalari
    ExecExpectError('olmayan dosya hata verir', 'COPY t FROM ''yok_boyle_dosya.csv''');
    ExecExpectError('bilinmeyen secenek hata verir',
      'COPY t FROM ''copychk_cols.csv'' (FOO 1)');

    // 7) Kalicilik
    tb.Close;
    kv.Close;
    kv.Open(DIR);
    tb.Open(DIR);
    Chk('yeniden acilis sonrasi 6 satir', CountOf('t') = 6, IntToStr(CountOf('t')));
  finally
    tb.Free;
    kv.Free;
    sq.Free;
  end;

  Writeln;
  if fails = 0 then
    Writeln('SONUC: TUM TESTLER GECTI')
  else
  begin
    Writeln(Format('SONUC: %d HATA', [fails]));
    ExitCode := 1;
  end;
end.
