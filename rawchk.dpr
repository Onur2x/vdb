program rawchk;
{ H1 ham-yuklem diferansiyel testi: akisli/ham yol (ORDER BY'siz) ile
  genel yol (ORDER BY id ile zorlanir) AYNI satir kumesini vermeli.
  INT/FLOAT/TEXT/BOOL ve NULL karisik. }
{$mode delphi}
uses
  SysUtils, Classes, Generics.Collections, VDbCore, VDbTable, VDbSql;

const
  N = 5000;
  DIR = 'rawchk_dir';

var
  kv: TVDb; tb: TVTableDb; sq: TVSql;

function RowKey(const R: TStrArray): string;
var j: Integer;
begin
  Result := '';
  for j := 0 to High(R) do Result := Result + R[j] + #1;
end;

procedure SortKeys(var L: TStringList);
begin
  L.Sort;
end;

procedure KeysOf(R: TSqlResult; out L: TStringList);
var i: Integer;
begin
  L := TStringList.Create;
  for i := 0 to High(R.Rows) do L.Add(RowKey(R.Rows[i]));
  L.Sort;
end;

procedure Check(const q: string);
var A, B: TSqlResult; ka, kb: TStringList; i: Integer; ok: Boolean;
begin
  A := sq.Exec(q);
  B := sq.Exec(q + ' ORDER BY id');
  KeysOf(A, ka); KeysOf(B, kb);
  ok := ka.Count = kb.Count;
  if ok then
    for i := 0 to ka.Count - 1 do
      if ka[i] <> kb[i] then begin ok := False; Break; end;
  if ok then
    Writeln('OK   [', ka.Count, '] ', q)
  else
    Writeln('FARK [', ka.Count, ' vs ', kb.Count, '] ', q);
  ka.Free; kb.Free;
end;

var i: Integer; bv, fv, svq: string;
begin
  try
    DeleteFile(DIR + '\veritabani.odb'); DeleteFile(DIR + '\veritabani.schema');
    if DirectoryExists(DIR) then RemoveDir(DIR);
    ForceDirectories(DIR);
    kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
    try
      kv.Open(DIR); tb.Open(DIR);
      sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, f FLOAT, s TEXT, b BOOLEAN)');
      sq.Exec('BEGIN');
      for i := 1 to N do
      begin
        if i mod 2 = 0 then bv := 'TRUE' else bv := 'FALSE';
        fv := IntToStr(i mod 50) + '.25';
        // H1b: bazi satirlar ASCII-disi (UTF-8 é) ve bos metin icersin.
        if i mod 29 = 0 then
          svq := '''' + #$C3#$A9 + 'z' + IntToStr(i mod 5) + ''''
        else if i mod 11 = 0 then
          svq := ''''''
        else
          svq := '''k' + IntToStr(i mod 13) + '''';
        if i mod 17 = 0 then
          sq.Exec(Format('INSERT INTO t VALUES (%d, NULL, %s, %s, %s)',
            [i, fv, svq, bv]))
        else
          sq.Exec(Format('INSERT INTO t VALUES (%d, %d, %s, %s, %s)',
            [i, i mod 100, fv, svq, bv]));
      end;
      sq.Exec('COMMIT');

      Check('SELECT id,a,f,s,b FROM t WHERE a >= 30');
      Check('SELECT id,a FROM t WHERE a < 20 AND a >= 5');
      Check('SELECT id,a FROM t WHERE a = 42');
      Check('SELECT id,a FROM t WHERE a <> 42');
      Check('SELECT id,a FROM t WHERE a > 1000');
      Check('SELECT id,a FROM t WHERE 30 < a');
      Check('SELECT id,a FROM t WHERE a >= 10 AND s = ''k3''');
      Check('SELECT id,a,f FROM t WHERE f > 10.0');
      Check('SELECT id,a,f FROM t WHERE f <= 5.5 AND a >= 0');
      Check('SELECT id,s FROM t WHERE s = ''k3''');
      Check('SELECT id,s FROM t WHERE s <> ''k3''');
      Check('SELECT id,s FROM t WHERE s = ''''');
      Check('SELECT id,a,s FROM t WHERE s = ''k3'' AND a >= 10');
      Check('SELECT id,s FROM t WHERE s = ''k0''');
      Check('SELECT id,b FROM t WHERE b = TRUE');
      Check('SELECT id,a FROM t WHERE a IS NULL');
      Check('SELECT id,a FROM t WHERE a BETWEEN 10 AND 20');
      Check('SELECT id,a FROM t WHERE a BETWEEN 10 AND 20 AND b = FALSE');
      Check('SELECT id,f FROM t WHERE f BETWEEN 2.25 AND 5.25');
      Check('SELECT id,f FROM t WHERE f BETWEEN 1.25 AND 40.25 AND a >= 10');
      Check('SELECT id,a FROM t WHERE a IN (1,2,3)');
      Check('SELECT id,a FROM t WHERE a IN (1,2,3,4,5,6,7) AND f > 10.0');
      Check('SELECT id,f FROM t WHERE f IN (1.25, 2.25, 30.25)');
      Check('SELECT id,a FROM t WHERE a NOT IN (1,2,3)');
      Check('SELECT id,a FROM t WHERE a NOT BETWEEN 10 AND 20');
      Check('SELECT id,a FROM t WHERE a >= 30 AND f < 8.0');
      Check('SELECT id,a FROM t WHERE a >= 30 AND b = FALSE');
      Check('SELECT id,a FROM t WHERE NOT (a < 30)');
      Check('SELECT id,a FROM t WHERE a >= 0 AND a <= 99');
    finally
      sq.Free; tb.Free; kv.Free;
    end;
  except on E: Exception do Writeln('HATA: ', E.Message); end;
end.
