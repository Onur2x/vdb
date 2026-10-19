program mrowchk;
{ H13: cok-satirli VALUES hizli seridinin diferansiyel + atomiklik testi.
  1) Ayni satirlar (a) tek cok-satirli VALUES ile, (b) satir-satir INSERT ile
     yazilir; icerik ve COUNT birebir ayni olmali.
  2) Ayni cumle icinde mukerrer PK -> HATA; autocommit'te HIC satir kalmamali.
  3) Acik BEGIN icinde cok-satirli VALUES + ROLLBACK -> hic satir kalmamali. }
{$mode delphi}
uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql;

const DIR = 'mrowchk_dir';

var
  kv: TVDb; tb: TVTableDb; sq: TVSql;
  fails: Integer;

procedure Kontrol(const ad: string; kosul: Boolean);
begin
  if kosul then Writeln('OK   ', ad)
  else begin Writeln('HATA ', ad); Inc(fails); end;
end;

function RowsOf(const q: string): TStringList;
var R: TSqlResult; i, j: Integer; s: string;
begin
  Result := TStringList.Create;
  R := sq.Exec(q);
  for i := 0 to High(R.Rows) do
  begin
    s := '';
    for j := 0 to High(R.Rows[i]) do s := s + R.Rows[i][j] + #1;
    Result.Add(s);
  end;
  Result.Sort;
end;

function IntOf(const q: string): Int64;
begin
  Result := StrToInt64(sq.Exec(q).Rows[0, 0]);
end;

var i: Integer; l1, l2: TStringList; ok: Boolean; R: TSqlResult;
begin
  fails := 0;
  DeleteFile(DIR + '\veritabani.odb'); DeleteFile(DIR + '\veritabani.schema');
  if DirectoryExists(DIR) then RemoveDir(DIR);
  ForceDirectories(DIR);
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  try
    kv.Open(DIR); tb.Open(DIR);
    sq.Exec('CREATE TABLE t  (id INTEGER PRIMARY KEY, a INTEGER, s TEXT, b BOOLEAN, f FLOAT)');
    sq.Exec('CREATE TABLE t2 (id INTEGER PRIMARY KEY, a INTEGER, s TEXT, b BOOLEAN, f FLOAT)');

    // --- 1) Ayni icerik: NULL, TRUE/FALSE, tirnak kacisi, negatif, float ---
    sq.Exec('INSERT INTO t VALUES (1,10,''abc'',TRUE,1.5),(2,NULL,''a''''b'',FALSE,-3.25),' +
            '(3,0,'''',TRUE,0.0),(4,2147483647,''x'',FALSE,100.125),(5,-5,''y'',TRUE,-0.5)');
    sq.Exec('INSERT INTO t2 VALUES (1,10,''abc'',TRUE,1.5)');
    sq.Exec('INSERT INTO t2 VALUES (2,NULL,''a''''b'',FALSE,-3.25)');
    sq.Exec('INSERT INTO t2 VALUES (3,0,'''',TRUE,0.0)');
    sq.Exec('INSERT INTO t2 VALUES (4,2147483647,''x'',FALSE,100.125)');
    sq.Exec('INSERT INTO t2 VALUES (5,-5,''y'',TRUE,-0.5)');

    l1 := RowsOf('SELECT id,a,s,b,f FROM t'); l2 := RowsOf('SELECT id,a,s,b,f FROM t2');
    Kontrol('cok-satirli == satir-satir (icerik)', (l1.Count = l2.Count) and (l1.Text = l2.Text));
    l1.Free; l2.Free;

    // --- 2) Ayni cumlede mukerrer PK -> HATA + autocommit'te hic kalmamali ---
    sq.Exec('DELETE FROM t2');
    sq.Exec('DELETE FROM t');
    ok := False;
    try
      sq.Exec('INSERT INTO t VALUES (10,1,''a'',TRUE,1.0),(11,2,''b'',FALSE,2.0),(10,3,''c'',TRUE,3.0)');
    except
      on E: Exception do ok := True;
    end;
    Kontrol('mukerrer PK hata verdi', ok);
    Kontrol('atomik rollback (0 satir kaldi)', IntOf('SELECT COUNT(*) FROM t') = 0);

    // --- 3) Acik BEGIN icinde cok-satirli VALUES + ROLLBACK ---
    sq.Exec('BEGIN');
    sq.Exec('INSERT INTO t VALUES (20,1,''a'',TRUE,1.0),(21,2,''b'',FALSE,2.0)');
    sq.Exec('ROLLBACK');
    Kontrol('BEGIN+ROLLBACK -> 0 satir', IntOf('SELECT COUNT(*) FROM t') = 0);

    // --- 4) Acik BEGIN icinde COMMIT ---
    sq.Exec('BEGIN');
    R := sq.Exec('INSERT INTO t VALUES (30,1,''a'',TRUE,1.0),(31,2,''b'',FALSE,2.0),(32,3,''c'',TRUE,3.0)');
    sq.Exec('COMMIT');
    Kontrol('Affected=3', R.Affected = 3);
    Kontrol('BEGIN+COMMIT -> 3 satir', IntOf('SELECT COUNT(*) FROM t') = 3);

    // --- 5) Hata, acik BEGIN icinde: ROLLBACK temizler ---
    sq.Exec('BEGIN');
    ok := False;
    try
      sq.Exec('INSERT INTO t VALUES (40,1,''a'',TRUE,1.0),(41,2,''b'',FALSE,2.0),(30,9,''x'',TRUE,9.0)');
    except
      on E: Exception do ok := True;
    end;
    sq.Exec('ROLLBACK');
    Kontrol('BEGIN icinde hata -> hata goruldu', ok);
    Kontrol('BEGIN+ROLLBACK temiz -> 3 satir', IntOf('SELECT COUNT(*) FROM t') = 3);
  except
    on E: Exception do begin Writeln('ISTISNA: ', E.Message); Inc(fails); end;
  end;
  kv.Free; tb.Free; sq.Free;
  Writeln('SONUC: ', fails, ' hata');
end.
