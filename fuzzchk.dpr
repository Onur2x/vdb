program fuzzchk;
{ M8: bagimsiz WHERE fuzz/diferansiyel testi.

  Rastgele ama gecerli WHERE yuklemleri uretir; ayni yuklemi VDB'ye
  calistirir ve satirlari Pascal'daki BAGIMSIZ uc-degerli (TRUE/FALSE/
  UNKNOWN) degerlendiriciyle karsilastirir. Boylece SQL ureteci ile
  motor ayni kodu paylasmaz; NULL/AND/OR/NOT/IN/BETWEEN/LIKE semantigi
  bagimsiz olarak dogrulanir.

  Kullanim: fuzzchk.exe [sorgu_sayisi] [seed]
  Varsayilan: 500 sorgu, seed 20261019. Hata varsa cikis kodu 1. }
{$mode delphi}{$H+}
uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql;

const
  ROW_COUNT = 400;
  DIR = 'fuzzchk_dir';
  TEXT_COUNT = 10;
  TEXT_VALUES: array[0..TEXT_COUNT - 1] of string = (
    'k0', 'k1', 'k2', 'k10', 'abc', 'x%y', 'a''b', '_z', 'ZZ', 'k_'
  );

type
  TValKind = (vkNull, vkInt, vkFloat, vkText, vkBool);

  TVal = record
    Kind: TValKind;
    I: Int64;
    F: Double;
    S: string;
    B: Boolean;
  end;

  TRow = record
    Id: Integer;
    A: TVal;   // INTEGER
    F: TVal;   // FLOAT
    S: TVal;   // TEXT
    B: TVal;   // BOOLEAN
  end;

  TTri = (trFalse, trUnknown, trTrue);

  TCondKind = (ckCmp, ckBetween, ckIn, ckIsNull, ckIsNotNull,
    ckLike, ckAnd, ckOr, ckNot);

  TCond = class
  public
    Kind: TCondKind;
    Col: Integer;      // 0=a, 1=f, 2=s, 3=b
    Op: string;        // = <> < > <= >= ; IN/NOTIN; LIKE/NOTLIKE
    V1, V2: TVal;
    Vals: array of TVal;
    L, R: TCond;
    destructor Destroy; override;
  end;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  Rows: array of TRow;

function VNull: TVal;
begin
  Result.Kind := vkNull;
  Result.I := 0;
  Result.F := 0;
  Result.S := '';
  Result.B := False;
end;

function VInt(I: Int64): TVal;
begin
  Result := VNull;
  Result.Kind := vkInt;
  Result.I := I;
end;

function VFloat(F: Double): TVal;
begin
  Result := VNull;
  Result.Kind := vkFloat;
  Result.F := F;
end;

function VText(const S: string): TVal;
begin
  Result := VNull;
  Result.Kind := vkText;
  Result.S := S;
end;

function VBool(B: Boolean): TVal;
begin
  Result := VNull;
  Result.Kind := vkBool;
  Result.B := B;
end;

destructor TCond.Destroy;
var
  i: Integer;
begin
  L.Free;
  R.Free;
  for i := 0 to High(Vals) do
    Vals[i].S := '';
  inherited;
end;

function RndInt(Lo, Hi: Integer): Integer;
begin
  Result := Lo + Random(Hi - Lo + 1);
end;

function QtrLit(Q: Integer): string;
// Ceyrek birimli float'i nokta ondalikli SQL literal'ine cevirir.
var
  neg: Boolean;
  a, w, r: Integer;
begin
  neg := Q < 0;
  a := Abs(Q);
  w := a div 4;
  r := a mod 4;
  Result := IntToStr(w);
  case r of
    1: Result := Result + '.25';
    2: Result := Result + '.50';
    3: Result := Result + '.75';
  end;
  if neg then Result := '-' + Result;
end;

function TextLit(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
end;

function SqlLit(const V: TVal): string;
begin
  case V.Kind of
    vkNull: Result := 'NULL';
    vkInt: Result := IntToStr(V.I);
    vkFloat: Result := QtrLit(Round(V.F * 4));
    vkText: Result := TextLit(V.S);
    vkBool: if V.B then Result := 'TRUE' else Result := 'FALSE';
  else
    Result := 'NULL';
  end;
end;

function LikeMatch(const Txt, Pat: string): Boolean;
// VDbTable.VDbLikeMatch ile ayni semantik: % ve _ jokerleri; kacis yok.
var
  ti, pi, star, mark: Integer;
begin
  ti := 1;
  pi := 1;
  star := 0;
  mark := 0;
  while ti <= Length(Txt) do
  begin
    if (pi <= Length(Pat)) and ((Pat[pi] = '_') or (Pat[pi] = Txt[ti])) then
    begin
      Inc(ti);
      Inc(pi);
    end
    else if (pi <= Length(Pat)) and (Pat[pi] = '%') then
    begin
      star := pi;
      mark := ti;
      Inc(pi);
    end
    else if star <> 0 then
    begin
      pi := star + 1;
      Inc(mark);
      ti := mark;
    end
    else
      Exit(False);
  end;
  while (pi <= Length(Pat)) and (Pat[pi] = '%') do
    Inc(pi);
  Result := pi > Length(Pat);
end;

function TriNot(T: TTri): TTri;
begin
  case T of
    trTrue: Result := trFalse;
    trFalse: Result := trTrue;
  else
    Result := trUnknown;
  end;
end;

function TriAnd(A, B: TTri): TTri;
begin
  if (A = trFalse) or (B = trFalse) then Exit(trFalse);
  if (A = trUnknown) or (B = trUnknown) then Exit(trUnknown);
  Result := trTrue;
end;

function TriOr(A, B: TTri): TTri;
begin
  if (A = trTrue) or (B = trTrue) then Exit(trTrue);
  if (A = trUnknown) or (B = trUnknown) then Exit(trUnknown);
  Result := trFalse;
end;

function CmpTri(const A, B: TVal; const Op: string; Numeric: Boolean): TTri;
var
  eq, lt, gt: Boolean;
begin
  if (A.Kind = vkNull) or (B.Kind = vkNull) then Exit(trUnknown);
  eq := False;
  lt := False;
  gt := False;
  if Numeric then
  begin
    if A.Kind = vkInt then
    begin
      if B.Kind = vkInt then
      begin
        eq := A.I = B.I;
        lt := A.I < B.I;
        gt := A.I > B.I;
      end
      else
      begin
        eq := A.I = B.F;
        lt := A.I < B.F;
        gt := A.I > B.F;
      end;
    end
    else
    begin
      if B.Kind = vkInt then
      begin
        eq := A.F = B.I;
        lt := A.F < B.I;
        gt := A.F > B.I;
      end
      else
      begin
        eq := A.F = B.F;
        lt := A.F < B.F;
        gt := A.F > B.F;
      end;
    end;
  end
  else if A.Kind = vkText then
  begin
    eq := A.S = B.S;
    lt := A.S < B.S;
    gt := A.S > B.S;
  end
  else if A.Kind = vkBool then
  begin
    eq := A.B = B.B;
    lt := (not A.B) and B.B;
    gt := A.B and (not B.B);
  end;

  if Op = '=' then
    Result := trFalse
  else if (Op = '<>') or (Op = '!=') then
    Result := trFalse
  else if Op = '<' then
    Result := trFalse
  else if Op = '>' then
    Result := trFalse
  else if Op = '<=' then
    Result := trFalse
  else if Op = '>=' then
    Result := trFalse
  else
    Exit(trFalse);

  if Op = '=' then
    if eq then Exit(trTrue) else Exit(trFalse);
  if (Op = '<>') or (Op = '!=') then
    if not eq then Exit(trTrue) else Exit(trFalse);
  if Op = '<' then
    if lt then Exit(trTrue) else Exit(trFalse);
  if Op = '>' then
    if gt then Exit(trTrue) else Exit(trFalse);
  if Op = '<=' then
    if (lt or eq) then Exit(trTrue) else Exit(trFalse);
  if Op = '>=' then
    if (gt or eq) then Exit(trTrue) else Exit(trFalse);
end;

function RowVal(const R: TRow; Col: Integer): TVal;
begin
  case Col of
    0: Result := R.A;
    1: Result := R.F;
    2: Result := R.S;
  else
    Result := R.B;
  end;
end;

function EvalCond(C: TCond; const R: TRow): TTri;
var
  i: Integer;
  v: TVal;
  t, t2: TTri;
  anyNull, found: Boolean;
begin
  if C = nil then Exit(trUnknown);
  case C.Kind of
    ckAnd:
      Exit(TriAnd(EvalCond(C.L, R), EvalCond(C.R, R)));
    ckOr:
      Exit(TriOr(EvalCond(C.L, R), EvalCond(C.R, R)));
    ckNot:
      Exit(TriNot(EvalCond(C.L, R)));
    ckIsNull:
      if RowVal(R, C.Col).Kind = vkNull then Exit(trTrue) else Exit(trFalse);
    ckIsNotNull:
      if RowVal(R, C.Col).Kind <> vkNull then Exit(trTrue) else Exit(trFalse);
    ckCmp:
      Exit(CmpTri(RowVal(R, C.Col), C.V1, C.Op, C.Col in [0, 1]));
    ckLike:
      begin
        v := RowVal(R, C.Col);
        if (v.Kind = vkNull) or (C.V1.Kind = vkNull) then Exit(trUnknown);
        t := trFalse;
        if LikeMatch(v.S, C.V1.S) then t := trTrue;
        if C.Op = 'NOTLIKE' then t := TriNot(t);
        Exit(t);
      end;
    ckBetween:
      begin
        v := RowVal(R, C.Col);
        t := CmpTri(v, C.V1, '>=', True);
        t2 := CmpTri(v, C.V2, '<=', True);
        t := TriAnd(t, t2);
        if SameText(C.Op, 'NOTBETWEEN') then t := TriNot(t);
        Exit(t);
      end;
    ckIn:
      begin
        v := RowVal(R, C.Col);
        if v.Kind = vkNull then Exit(trUnknown);
        found := False;
        anyNull := False;
        for i := 0 to High(C.Vals) do
        begin
          if C.Vals[i].Kind = vkNull then
            anyNull := True
          else if CmpTri(v, C.Vals[i], '=', C.Col in [0, 1]) = trTrue then
          begin
            found := True;
            Break;
          end;
        end;
        if found then
          t := trTrue
        else if anyNull then
          t := trUnknown
        else
          t := trFalse;
        if SameText(C.Op, 'NOTIN') then t := TriNot(t);
        Exit(t);
      end;
  end;
  Result := trUnknown;
end;

function NewLeaf: TCond;
var
  op, pat: string;
  col, n, i, q: Integer;
  v: TVal;
begin
  Result := TCond.Create;
  col := Random(4);
  Result.Col := col;

  // %10: yalnizca IS NULL / IS NOT NULL (her kolon tipinde)
  if Random(100) < 10 then
  begin
    if Random(2) = 0 then
      Result.Kind := ckIsNull
    else
      Result.Kind := ckIsNotNull;
    Exit;
  end;

  case col of
    0: // INTEGER: karsilastirma / BETWEEN / IN
      begin
        if Random(100) < 18 then
        begin
          Result.Kind := ckBetween;
          Result.V1 := VInt(RndInt(-25, 95));
          Result.V2 := VInt(Result.V1.I + RndInt(0, 40));
          if Random(2) = 0 then Result.Op := 'BETWEEN'
          else Result.Op := 'NOTBETWEEN';
        end
        else if Random(100) < 18 then
        begin
          Result.Kind := ckIn;
          n := RndInt(1, 4);
          SetLength(Result.Vals, n);
          for i := 0 to n - 1 do
            Result.Vals[i] := VInt(RndInt(-20, 120));
          if Random(2) = 0 then Result.Op := 'IN' else Result.Op := 'NOTIN';
        end
        else
        begin
          Result.Kind := ckCmp;
          if Random(100) < 18 then
          begin
            if Random(2) = 0 then op := '=' else op := '<>';
            Result.V1 := VNull;
          end
          else
          begin
            case RndInt(0, 5) of
              0: op := '=';
              1: op := '<>';
              2: op := '<';
              3: op := '>';
              4: op := '<=';
            else
              op := '>=';
            end;
            Result.V1 := VInt(RndInt(-20, 120));
          end;
          Result.Op := op;
        end;
      end;
    1: // FLOAT: ceyrek birimli karsilastirma / BETWEEN / IN
      begin
        if Random(100) < 18 then
        begin
          Result.Kind := ckBetween;
          q := RndInt(-24, 100);
          Result.V1 := VFloat(q / 4);
          Result.V2 := VFloat((q + RndInt(0, 160)) / 4);
          if Random(2) = 0 then Result.Op := 'BETWEEN'
          else Result.Op := 'NOTBETWEEN';
        end
        else if Random(100) < 18 then
        begin
          Result.Kind := ckIn;
          n := RndInt(1, 4);
          SetLength(Result.Vals, n);
          for i := 0 to n - 1 do
            Result.Vals[i] := VFloat(RndInt(-20, 120) / 4);
          if Random(2) = 0 then Result.Op := 'IN' else Result.Op := 'NOTIN';
        end
        else
        begin
          Result.Kind := ckCmp;
          if Random(100) < 18 then
          begin
            if Random(2) = 0 then op := '=' else op := '<>';
            Result.V1 := VNull;
          end
          else
          begin
            case RndInt(0, 5) of
              0: op := '=';
              1: op := '<>';
              2: op := '<';
              3: op := '>';
              4: op := '<=';
            else
              op := '>=';
            end;
            Result.V1 := VFloat(RndInt(-20, 120) / 4);
          end;
          Result.Op := op;
        end;
      end;
    2: // TEXT: = <> LIKE / IN
      begin
        if Random(100) < 30 then
        begin
          Result.Kind := ckLike;
          case RndInt(0, 6) of
            0: pat := 'k%';
            1: pat := 'k_';
            2: pat := '%0';
            3: pat := 'a%';
            4: pat := '%b%';
            5: pat := 'x%y';
          else
            pat := '%';
          end;
          Result.V1 := VText(pat);
          if Random(2) = 0 then Result.Op := 'LIKE'
          else Result.Op := 'NOTLIKE';
        end
        else if Random(100) < 18 then
        begin
          Result.Kind := ckIn;
          n := RndInt(1, 4);
          SetLength(Result.Vals, n);
          for i := 0 to n - 1 do
            Result.Vals[i] := VText(TEXT_VALUES[RndInt(0, TEXT_COUNT - 1)]);
          if Random(2) = 0 then Result.Op := 'IN' else Result.Op := 'NOTIN';
        end
        else
        begin
          Result.Kind := ckCmp;
          if Random(100) < 15 then
          begin
            if Random(2) = 0 then op := '=' else op := '<>';
            v := VNull;
          end
          else
          begin
            if Random(2) = 0 then op := '=' else op := '<>';
            v := VText(TEXT_VALUES[RndInt(0, TEXT_COUNT - 1)]);
          end;
          Result.V1 := v;
          Result.Op := op;
        end;
      end;
  else // BOOLEAN: = <> ve IS NULL (yukarida)
    begin
      Result.Kind := ckCmp;
      if Random(100) < 15 then
      begin
        if Random(2) = 0 then op := '=' else op := '<>';
        Result.V1 := VNull;
      end
      else
      begin
        if Random(2) = 0 then op := '=' else op := '<>';
        if Random(2) = 0 then Result.V1 := VBool(True)
        else Result.V1 := VBool(False);
      end;
      Result.Op := op;
    end;
  end;
end;

function LeafSql(C: TCond): string;
var
  cmpn: string;
  i: Integer;
begin
  cmpn := '';
  case C.Col of
    0: cmpn := 'a';
    1: cmpn := 'f';
    2: cmpn := 's';
  else
    cmpn := 'b';
  end;
  case C.Kind of
    ckIsNull: Exit(cmpn + ' IS NULL');
    ckIsNotNull: Exit(cmpn + ' IS NOT NULL');
    ckCmp: Exit(cmpn + ' ' + C.Op + ' ' + SqlLit(C.V1));
    ckLike:
      if SameText(C.Op, 'NOTLIKE') then
        Exit(cmpn + ' NOT LIKE ' + TextLit(C.V1.S))
      else
        Exit(cmpn + ' LIKE ' + TextLit(C.V1.S));
    ckBetween:
      if SameText(C.Op, 'NOTBETWEEN') then
        Exit(cmpn + ' NOT BETWEEN ' + SqlLit(C.V1) + ' AND ' + SqlLit(C.V2))
      else
        Exit(cmpn + ' BETWEEN ' + SqlLit(C.V1) + ' AND ' + SqlLit(C.V2));
    ckIn:
      begin
        if SameText(C.Op, 'NOTIN') then
          Result := cmpn + ' NOT IN ('
        else
          Result := cmpn + ' IN (';
        for i := 0 to High(C.Vals) do
        begin
          if i > 0 then Result := Result + ', ';
          Result := Result + SqlLit(C.Vals[i]);
        end;
        Result := Result + ')';
        Exit;
      end;
  else
    Result := '1=1';
  end;
end;

function GenExpr(Depth: Integer; out Sql: string): TCond;
var
  L, R: TCond;
  s1, s2: string;
  ln: TCond;
begin
  if (Depth <= 0) or (Random(100) < 42) then
  begin
    Result := NewLeaf;
    Sql := LeafSql(Result);
    // NOT yalnizca tek kosula uygulanir; motorun DNF NOT siniri disinda kalir.
    if Random(100) < 15 then
    begin
      ln := TCond.Create;
      ln.Kind := ckNot;
      ln.L := Result;
      Result := ln;
      Sql := 'NOT (' + Sql + ')';
    end;
    Exit;
  end;
  L := GenExpr(Depth - 1, s1);
  R := GenExpr(Depth - 1, s2);
  Result := TCond.Create;
  if Random(2) = 0 then
  begin
    Result.Kind := ckAnd;
    Result.L := L;
    Result.R := R;
    Sql := '(' + s1 + ' AND ' + s2 + ')';
  end
  else
  begin
    Result.Kind := ckOr;
    Result.L := L;
    Result.R := R;
    Sql := '(' + s1 + ' OR ' + s2 + ')';
  end;
end;

function ExpectedIds(C: TCond): string;
var
  i, n: Integer;
  ids: array of Integer;
begin
  n := 0;
  SetLength(ids, Length(Rows));
  for i := 0 to High(Rows) do
    if EvalCond(C, Rows[i]) = trTrue then
    begin
      ids[n] := Rows[i].Id;
      Inc(n);
    end;
  Result := '';
  for i := 0 to n - 1 do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + IntToStr(ids[i]);
  end;
end;

function ActualIds(const Sql: string): string;
var
  Res: TSqlResult;
  i: Integer;
begin
  Result := '';
  Res := sq.Exec(Sql);
  for i := 0 to High(Res.Rows) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + Res.Rows[i][0];
  end;
end;

procedure InsertRows;
var
  i, q: Integer;
  a, f, s, b: TVal;
  vals: string;
begin
  sq.Exec('BEGIN');
  try
    for i := 1 to ROW_COUNT do
    begin
      if Random(100) < 8 then a := VNull else a := VInt(RndInt(-20, 120));
      if Random(100) < 8 then f := VNull else f := VFloat(RndInt(-20, 120) / 4);
      if Random(100) < 10 then s := VNull
      else s := VText(TEXT_VALUES[RndInt(0, TEXT_COUNT - 1)]);
      if Random(100) < 10 then b := VNull else b := VBool(Random(2) = 1);

      Rows[i - 1].Id := i;
      Rows[i - 1].A := a;
      Rows[i - 1].F := f;
      Rows[i - 1].S := s;
      Rows[i - 1].B := b;

      vals := Format('INSERT INTO t VALUES (%d, %s, %s, %s, %s)',
        [i, SqlLit(a), SqlLit(f), SqlLit(s), SqlLit(b)]);
      sq.Exec(vals);
    end;
    sq.Exec('COMMIT');
  except
    sq.Exec('ROLLBACK');
    raise;
  end;
end;

var
  i, count, seed, fails: Integer;
  pred, sql, exp, act: string;
  C: TCond;
begin
  count := StrToIntDef(ParamStr(1), 500);
  seed := StrToIntDef(ParamStr(2), 20261019);
  if count < 1 then count := 1;
  RandSeed := seed;

  fails := 0;
  DeleteFile(DIR + '\veritabani.odb');
  DeleteFile(DIR + '\veritabani.schema');
  if DirectoryExists(DIR) then RemoveDir(DIR);
  ForceDirectories(DIR);

  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(DIR);
    tb.Open(DIR);
    SetLength(Rows, ROW_COUNT);
    sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, f FLOAT, s TEXT, b BOOLEAN)');
    InsertRows;

    for i := 1 to count do
    begin
      C := GenExpr(3, pred);
      try
        sql := 'SELECT id FROM t WHERE ' + pred + ' ORDER BY id';
        exp := ExpectedIds(C);
        act := ActualIds(sql);
        if exp <> act then
        begin
          Inc(fails);
          Writeln('FARK #', i, ' seed=', seed);
          Writeln('  WHERE: ', pred);
          Writeln('  beklenen: ', exp);
          Writeln('  gercek  : ', act);
          if fails >= 20 then
          begin
            Writeln('20 farktan sonra durduruldu.');
            Break;
          end;
        end;
      except
        on E: Exception do
        begin
          Inc(fails);
          Writeln('HATA #', i, ' seed=', seed, ' WHERE: ', pred);
          Writeln('  ', E.ClassName, ': ', E.Message);
        end;
      end;
      C.Free;
    end;
  except
    on E: Exception do
    begin
      Inc(fails);
      Writeln('ISTISNA: ', E.ClassName, ': ', E.Message);
    end;
  end;
  sq.Free;
  tb.Free;
  kv.Free;

  if fails = 0 then
    Writeln('SONUC: ', count, ' sorgu, 0 fark (seed=', seed, ')')
  else
    Writeln('SONUC: ', fails, ' hata (seed=', seed, ')');
  if fails <> 0 then
    Halt(1);
end.
