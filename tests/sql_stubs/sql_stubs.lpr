program sql_stubs;
{ V3 sertlestirme â€” stub yuzey kalici kapisi.

  Amac: RETURNING / TRIGGER / FUNCTION / PROCEDURE yuzeylerinde
  (a) gercekten calisan ozelliklerin calistigini KANITLAMAK,
  (b) uygulanmamis API yollarini SESSIZ yanlis sonuc yerine
      ecUnsupported ile reddettigini kanitlamak,
  (c) bilinen kalicilik sinirini (tanimlar yalniz bellekte) sabitlemek.

  Ayrinti: docs/engineering/SQL_STUB_SURFACE.md
  Derleme: fpc (lpi gerekmez). Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbTable, VDbSql, VDbErr,
  VDbCore;

var
  GPass, GFail: Integer;
  GBe: IVdbBackend;
  GTb: TVTableDb;
  GSql: TVSql;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' ', ADetail);
  end;
end;

function TestDir: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'tmp';
end;

function FreshDir(const AName: string): string;
var
  sr: TSearchRec;
  p: string;
begin
  Result := IncludeTrailingPathDelimiter(TestDir) + 'ss_' + AName;
  if FindFirst(Result + PathDelim + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') and
         ((sr.Attr and faDirectory) = 0) then
      begin
        p := Result + PathDelim + sr.Name;
        DeleteFile(p);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  ForceDirectories(Result);
end;

procedure OpenEnv(const ADir: string);
begin
  VdbOpen(ADir, GBe, True, True);
  GTb := TVTableDb.CreateBackend(GBe);
  GTb.Open(ADir);
  GSql := TVSql.Create(GTb);
end;

procedure CloseEnv;
begin
  FreeAndNil(GSql);
  FreeAndNil(GTb);
  GBe := nil;
end;

{ SQL'i calistirir; EVDbException yakalanirsa ACode/AMsg doldurulur ve
  sonuc True olur (hata var). Diger istisnalar yukari gider. }
function ExecErr(const ASql: string; out ACode, AMsg: string): Boolean;
begin
  Result := False;
  ACode := '';
  AMsg := '';
  try
    GSql.Exec(ASql);
  except
    on E: EVDbException do
    begin
      Result := True;
      ACode := VDbErrorName(E.ErrorCode);
      AMsg := E.Message;
    end;
  end;
end;

function Exec1(const ASql: string): string;
var
  r: TSqlResult;
begin
  Result := '';
  r := GSql.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := r.Rows[0][0];
end;

procedure ScenarioTriggerNew;
var
  errCode, errMsg: string;
begin
  OpenEnv(FreshDir('trg'));
  try
    GSql.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
    Chk('T1 trigger tanimi kabul edildi',
      not ExecErr('CREATE TRIGGER tr1 BEFORE INSERT ON t FOR EACH ROW ' +
        'AS BEGIN NEW.b = NEW.a * 2; END', errCode, errMsg),
      'err=' + errCode + ' ' + errMsg);
    GSql.Exec('INSERT INTO t (id, a, b) VALUES (1, 21, 0)');
    Chk('T1 BEFORE INSERT NEW.b yazildi', Exec1('SELECT b FROM t WHERE id = 1') = '42',
      'b=' + Exec1('SELECT b FROM t WHERE id = 1'));

    { Kolon cumlenin listesinde yoksa NEW.x atamasi SESSIZCE yutulmaz:
      ecUnsupported ile reddedilir (V3: sessiz yanlis sonuc yasak). }
    Chk('T1 NEW.x listede yok -> ecUnsupported',
      ExecErr('INSERT INTO t (id, a) VALUES (2, 21)', errCode, errMsg) and
      (errCode = 'ecUnsupported') and (Pos('kolon listesinde yok', errMsg) > 0),
      'code=' + errCode + ' msg=' + errMsg);

    // WHEN kosulu yalan -> tetikleyici atlanir
    GSql.Exec('CREATE TABLE t2 (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
    GSql.Exec('CREATE TRIGGER tr2 BEFORE INSERT ON t2 FOR EACH ROW ' +
      'WHEN (NEW.a > 100) AS BEGIN NEW.b = 999; END');
    GSql.Exec('INSERT INTO t2 (id, a, b) VALUES (1, 5, 0)');
    GSql.Exec('INSERT INTO t2 (id, a, b) VALUES (2, 200, 0)');
    Chk('T1 WHEN yalan -> atlandi',
      Exec1('SELECT b FROM t2 WHERE id = 1') <> '999',
      'b=' + Exec1('SELECT b FROM t2 WHERE id = 1'));
    Chk('T1 WHEN dogru -> uygulandi',
      Exec1('SELECT b FROM t2 WHERE id = 2') = '999',
      'b=' + Exec1('SELECT b FROM t2 WHERE id = 2'));

    // AFTER INSERT: govdede NEW.x ile baska tabloya yazim
    GSql.Exec('CREATE TABLE audit (id INTEGER PRIMARY KEY, v INTEGER)');
    GSql.Exec('CREATE TRIGGER tr3 AFTER INSERT ON t FOR EACH ROW ' +
      'AS BEGIN INSERT INTO audit (id, v) VALUES (NEW.id, NEW.a); END');
    GSql.Exec('INSERT INTO t (id, a, b) VALUES (7, 3, 0)');
    Chk('T2 AFTER INSERT audit satiri yazdi',
      Exec1('SELECT v FROM audit WHERE id = 7') = '3',
      'v=' + Exec1('SELECT v FROM audit WHERE id = 7'));

    // DROP TRIGGER
    GSql.Exec('DROP TRIGGER IF EXISTS tr3');
    GSql.Exec('INSERT INTO t (id, a, b) VALUES (8, 3, 0)');
    Chk('T2 DROP TRIGGER sonrasi atesleme yok',
      Exec1('SELECT COUNT(*) FROM audit') = '1',
      'audit satir=' + Exec1('SELECT COUNT(*) FROM audit'));
  finally
    CloseEnv;
  end;
end;

procedure ScenarioProcFunc;
var
  errCode, errMsg: string;
  res: TStrArray;
  v: string;
  caught: Boolean;
begin
  OpenEnv(FreshDir('proc'));
  try
    GSql.Exec('CREATE TABLE log (id INTEGER PRIMARY KEY, v INTEGER)');
    Chk('F1 CREATE FUNCTION kabul edildi',
      not ExecErr('CREATE FUNCTION dbl(x INTEGER) RETURNS INTEGER ' +
        'AS BEGIN RETURN x * 2; END', errCode, errMsg),
      'err=' + errCode + ' ' + errMsg);
    Chk('F1 SELECT dbl(21) govdeyi calistirdi', Exec1('SELECT dbl(21) AS r') = '42',
      'r=' + Exec1('SELECT dbl(21) AS r'));

    Chk('F1 CREATE PROCEDURE kabul edildi',
      not ExecErr('CREATE PROCEDURE p1(v INTEGER) AS BEGIN ' +
        'INSERT INTO log (id, v) VALUES (99, v); END', errCode, errMsg),
      'err=' + errCode + ' ' + errMsg);
    Chk('F1 CALL govdeyi calistirdi',
      not ExecErr('CALL p1(7)', errCode, errMsg),
      'err=' + errCode + ' ' + errMsg);
    Chk('F1 CALL yazimi kalici',
      Exec1('SELECT v FROM log WHERE id = 99') = '7',
      'v=' + Exec1('SELECT v FROM log WHERE id = 99'));

    // Katalog API'si govde CALISTIRMAZ: sessiz bos sonuc yerine hata.
    SetLength(res, 0);
    caught := False;
    try
      GTb.CallProcedure('p1', ['5'], res);
    except
      on E: EVDbException do
      begin
        caught := E.ErrorCode = ecUnsupported;
        v := E.Message;
      end;
    end;
    Chk('F2 TVTableDb.CallProcedure ecUnsupported', caught,
      'caught=' + BoolToStr(caught, True) + ' msg=' + v);

    caught := False;
    try
      GTb.ExecuteFunction('dbl', ['5']);
    except
      on E: EVDbException do
      begin
        caught := E.ErrorCode = ecUnsupported;
        v := E.Message;
      end;
    end;
    Chk('F2 TVTableDb.ExecuteFunction ecUnsupported', caught,
      'caught=' + BoolToStr(caught, True) + ' msg=' + v);
  finally
    CloseEnv;
  end;
end;

procedure ScenarioReturning;
var
  r: TSqlResult;
begin
  OpenEnv(FreshDir('ret'));
  try
    GSql.Exec('CREATE TABLE k (id INTEGER PRIMARY KEY, ad TEXT, n INTEGER)');
    r := GSql.Exec('INSERT INTO k (id, ad, n) VALUES (1, ''a'', 10) RETURNING id, ad');
    Chk('R1 INSERT RETURNING alanlari', (Length(r.Fields) = 2) and
      SameText(r.Fields[0], 'id') and SameText(r.Fields[1], 'ad'),
      'fields=' + IntToStr(Length(r.Fields)));
    Chk('R1 INSERT RETURNING satiri', (Length(r.Rows) = 1) and
      (Length(r.Rows[0]) = 2) and (r.Rows[0][0] = '1') and (r.Rows[0][1] = 'a'),
      'satir=' + IntToStr(Length(r.Rows)));
    r := GSql.Exec('UPDATE k SET n = 20 WHERE id = 1 RETURNING n');
    Chk('R1 UPDATE RETURNING degeri', (Length(r.Rows) = 1) and
      (r.Rows[0][0] = '20'), 'n=' + r.Rows[0][0]);
    r := GSql.Exec('DELETE FROM k WHERE id = 1 RETURNING id');
    Chk('R1 DELETE RETURNING degeri', (Length(r.Rows) = 1) and
      (r.Rows[0][0] = '1'), 'id=' + r.Rows[0][0]);
  finally
    CloseEnv;
  end;
end;

procedure ScenarioLegacyKv;
var
  db: TVDb;
  captured: Boolean;
  v: string;
  outPk: string;
  outVals: TStrArray;
  ok: Boolean;
begin
  db := TVDb.Create;
  try
    captured := False;
    try
      ok := db.InsertReturning('t', ['a'], ['1'], outPk, outVals);
      v := 'ok=' + BoolToStr(ok, True);
    except
      on E: EVDbException do
      begin
        captured := E.ErrorCode = ecUnsupported;
        v := E.Message;
      end;
    end;
    Chk('K1 legacy TVDb.InsertReturning ecUnsupported', captured, v);

    captured := False;
    try
      ok := db.UpsertRowReturning('t', ['a'], ['1'], 0, [], [], outPk, outVals);
      v := 'ok=' + BoolToStr(ok, True);
    except
      on E: EVDbException do
      begin
        captured := E.ErrorCode = ecUnsupported;
        v := E.Message;
      end;
    end;
    Chk('K1 legacy TVDb.UpsertRowReturning ecUnsupported', captured, v);
  finally
    db.Free;
  end;
end;

procedure ScenarioPersistence;
var
  dir: string;
  errCode, errMsg, v: string;
begin
  dir := FreshDir('persist');
  OpenEnv(dir);
  try
    GSql.Exec('CREATE TABLE p (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
    GSql.Exec('CREATE TRIGGER ptr BEFORE INSERT ON p FOR EACH ROW ' +
      'AS BEGIN NEW.b = 5; END');
    GSql.Exec('CREATE FUNCTION pf(x INTEGER) RETURNS INTEGER ' +
      'AS BEGIN RETURN x + 1000; END');
    GSql.Exec('INSERT INTO p (id, a, b) VALUES (1, 1, 0)');
    Chk('P1 tanim ayni oturumda etkin',
      (Exec1('SELECT b FROM p WHERE id = 1') = '5') and
      (Exec1('SELECT pf(9) AS r') = '1009'),
      'b=' + Exec1('SELECT b FROM p WHERE id = 1'));
  finally
    CloseEnv;
  end;
  OpenEnv(dir);
  try
    ExecErr('INSERT INTO p (id, a) VALUES (2, 2)', errCode, errMsg);
    Chk('P2 yeniden acilista tetikleyici YOK (belgelenmis sinir)',
      Exec1('SELECT b FROM p WHERE id = 2') = '',
      'b=' + Exec1('SELECT b FROM p WHERE id = 2'));
    errCode := '';
    v := '';
    if not ExecErr('SELECT pf(9) AS r', errCode, errMsg) then
      v := Exec1('SELECT pf(9) AS r');
    Chk('P2 yeniden acilista fonksiyon YOK (belgelenmis sinir)',
      (errCode <> '') or (v <> '1009'),
      'code=' + errCode + ' val=' + v);
  finally
    CloseEnv;
  end;
end;

procedure ScenarioErrors;
var
  errCode, errMsg: string;
begin
  OpenEnv(FreshDir('err'));
  try
    errCode := '';
    ExecErr('CALL yok_boyle_prosedur(1)', errCode, errMsg);
    Chk('E1 bilinmeyen prosedur hata verir', errCode = 'ecTableNotFound',
      'code=' + errCode + ' msg=' + errMsg);

    errCode := '';
    ExecErr('DROP TRIGGER IF EXISTS yok_trg', errCode, errMsg);
    Chk('E1 DROP TRIGGER IF EXISTS sessiz gecer', errCode = '',
      'code=' + errCode);
  finally
    CloseEnv;
  end;
end;

begin
  GPass := 0;
  GFail := 0;
  ForceDirectories(TestDir);
  WriteLn('sql_stubs baslangic, tmp=', TestDir);
  ScenarioTriggerNew;
  ScenarioProcFunc;
  ScenarioReturning;
  ScenarioLegacyKv;
  ScenarioPersistence;
  ScenarioErrors;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  Halt(GFail);
end.
