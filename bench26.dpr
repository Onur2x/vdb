program bench26;

{$mode delphi}
{$APPTYPE CONSOLE}

{ P-16 A/B olcumu: vsbench'in KUCUK kardesi (ayni asamalar, kucuk N).
  Amac: kod degisikliklerini ~1 dakikada A/B olcmek; kesin sayi degil
  GORECE fark icindir. Ayni API yolu: TVSql.Exec (metin SQL). }

uses
  Windows, SysUtils, Classes, VDbCore, VDbTable, VDbSql, VDbTypes;

const
  N       = 200000;     // INSERT/veri satiri
  PK_N    = 10000;
  RANGE_N = 400;        // 400 x 100 satir
  MUT_N   = 20000;
  VdbPath = 'C:\temp\b26';

function QPC: Int64;
var f, c: Int64;
begin
  QueryPerformanceFrequency(f);
  QueryPerformanceCounter(c);
  Result := c * 1000000 div f;   // mikrosaniye
end;

procedure CleanDir(const D: string);
var sr: TSearchRec;
begin
  if not DirectoryExists(D) then begin ForceDirectories(D); Exit; end;
  if FindFirst(D + '\*', faAnyFile, sr) = 0 then
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        DeleteFile(D + '\' + sr.Name);
    until FindNext(sr) <> 0;
  FindClose(sr);
end;

function InsertSql(i: Integer): string;
begin
  Result := Format(
    'INSERT INTO musteri(id,ad,yas,bakiye,notu) VALUES(%d,''musteri-%d'',%d,%d.5,''aciklama metni %d'')',
    [i, i, 20 + i mod 50, 100 + i mod 900, i]);
end;

var
  kv: TVDb; tb: TVTableDb; sq: TVSql;
  i, s: Integer;
  a0, a1, acc, tIns, tCnt, tSum, tPk, tRng, tUpd, tDel: Int64;
  sink: Int64;
begin
  CleanDir(VdbPath);
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(VdbPath);
    tb.Open(VdbPath);
    sq.Exec('CREATE TABLE musteri(id INTEGER PRIMARY KEY, ad TEXT, yas INTEGER, bakiye FLOAT, notu TEXT)');

    a0 := QPC;
    sq.Exec('BEGIN');
    for i := 1 to N do sq.Exec(InsertSql(i));
    sq.Exec('COMMIT');
    tIns := QPC - a0;

    acc := 0;
    for s := 1 to 5 do
    begin
      a0 := QPC;
      with sq.Exec('SELECT COUNT(*) FROM musteri') do
        if Length(Rows) > 0 then sink := Length(Rows[0][0]);
      Inc(acc, QPC - a0);
    end;
    tCnt := acc div 5;

    acc := 0;
    for s := 1 to 3 do
    begin
      a0 := QPC;
      with sq.Exec('SELECT SUM(bakiye) FROM musteri') do
        if Length(Rows) > 0 then sink := Length(Rows[0][0]);
      Inc(acc, QPC - a0);
    end;
    tSum := acc div 3;

    a0 := QPC;
    for i := 1 to PK_N do
      with sq.Exec(Format('SELECT * FROM musteri WHERE id = %d', [i])) do
        if Length(Rows) > 0 then Inc(sink, Length(Rows[0][0]));
    tPk := QPC - a0;

    a0 := QPC;
    for i := 0 to RANGE_N - 1 do
      with sq.Exec(Format('SELECT * FROM musteri WHERE id BETWEEN %d AND %d',
        [1 + i * 100, 100 + i * 100])) do
        if Length(Rows) > 0 then Inc(sink, Length(Rows[0][0]) + Length(Rows[High(Rows)][0]));
    tRng := QPC - a0;

    a0 := QPC;
    sq.Exec('BEGIN');
    for i := 1 to MUT_N do
      sq.Exec(Format('UPDATE musteri SET yas = yas + 1 WHERE id = %d', [i]));
    sq.Exec('COMMIT');
    tUpd := QPC - a0;

    a0 := QPC;
    sq.Exec('BEGIN');
    for i := 1 to MUT_N do
      sq.Exec(Format('DELETE FROM musteri WHERE id = %d', [i]));
    sq.Exec('COMMIT');
    tDel := QPC - a0;

    with sq.Exec('SELECT COUNT(*) FROM musteri') do
      if Length(Rows) > 0 then
        WriteLn('dogrulama kalan satir: ', Rows[0][0], ' (beklenen ', N - MUT_N, ')');

    WriteLn('INSERT ', N, '     : ', tIns, ' us  (', tIns div N, ' us/satir)');
    WriteLn('COUNT(*)   x5  : ', tCnt, ' us');
    WriteLn('SUM        x3  : ', tSum, ' us');
    WriteLn('SELECT PK  x', PK_N, '  : ', tPk, ' us  (', tPk div PK_N, ' us/sorgu)');
    WriteLn('RANGE      x', RANGE_N, '  : ', tRng, ' us  (', tRng div RANGE_N, ' us/sorgu)');
    WriteLn('UPDATE     x', MUT_N, '  : ', tUpd, ' us  (', tUpd div MUT_N, ' us/islem)');
    WriteLn('DELETE     x', MUT_N, '  : ', tDel, ' us  (', tDel div MUT_N, ' us/islem)');
    WriteLn('sink=', sink);
  finally
    sq.Free; tb.Free; kv.Free;
  end;
end.
