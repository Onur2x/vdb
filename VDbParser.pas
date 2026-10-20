unit VDbParser;

{ VDb SQL Ayrıştırıcısı (Parser) — Faz 3 (3.1 - 3.4)
  SQL metnini tarayarak tip-güvenli AST dugumlerine (TSqlStmtNode) donusturur.
  Ozyinelemeli inis (Recursive-Descent) teknigi kullanilir.

  Desteklenen SQL:
    DDL : CREATE TABLE [IF NOT EXISTS], ALTER TABLE, DROP TABLE [IF EXISTS]
          CREATE INDEX, DROP INDEX [IF EXISTS]
          CREATE/DROP/OPEN/CLOSE DATABASE, BACKUP TO, VACUUM, REINDEX, VERIFY
          SHOW/LIST TABLES, LIST DATABASES, EXPORT/IMPORT JSON
    DML : INSERT INTO ... VALUES / SELECT
          UPDATE ... SET ... WHERE
          DELETE FROM ... WHERE
    TX  : BEGIN, COMMIT, ROLLBACK
    SEL : SELECT [DISTINCT] cols FROM tbl [alias]
          [INNER|LEFT JOIN tbl2 alias ON cond]
          [WHERE expr]
          [GROUP BY cols] [HAVING expr]
          [ORDER BY cols [ASC|DESC]]
          [LIMIT n] [OFFSET n]
          UNION [ALL] / EXCEPT / INTERSECT
  
  Cikti: tek bir TSqlStmtNode; cagiran .Free ile temizler.
  Hata durumunda pozisyon bilgili Exception firlatilir.
}

{$mode delphi}

interface

uses
  Classes, SysUtils, Generics.Collections, DateUtils, VDbTable, VDbAst,
  VDbErr, VDbTypes, VDbText;   // R-20: VDbCollationByName

type
  TVDbParser = class
  private
    FSql   : string;
    FPos   : Integer;
    FLen   : Integer;
    FParams: TStrArray;
    FParamIdx: Integer;
    // F1-22: ifade/parantez derinlik sayaci (yigin tasmasini onler)
    FDepth  : Integer;
    // F1-12: UNION/EXCEPT/INTERSECT sag SELECT'i icin kuyruk (ORDER BY /
    // LIMIT / OFFSET) bastirilir; kuyruk dis birlestirmenin SONRASINA
    // ait oldugundan dis cumleye yazilir.
    FSuppressTail: Boolean;

    { R-18: son ana token (GRANT/REVOKE/CREATE/DROP/SET/ROLE) - alt
      parser'lar (ParseGrant, ParseRole) buna bakar. }
    FLastMainToken: string;

    { ---- Tokenizer ---- }
    procedure SkipWS;
    function  Peek: Char;
    function  AtEnd: Boolean;
    function  NextToken(out T: string; out IsStringLit: Boolean): Boolean; overload;
    function  NextToken(out T: string): Boolean; overload;
    function  PeekToken: string;
    function  PeekToken2: string;   // ikinci token'a bakar (pos degistirmez)
    function  PeekToken3: string;   // ucuncu token'a bakar (pos degistirmez)
    { R-16 yardimcilar }
    function  VDbUnquote(const S: string): string;
    function  ParseTimeStampMS(const S: string): QWord;
    procedure Expect(const W: string);
    procedure ExpectToken(out T: string; out IsStringLit: Boolean); overload;
    procedure ExpectToken(out T: string); overload;
    function  TryEat(const W: string): Boolean;
    function  CurPos: string;       // hata mesaji icin "pos=N"

    { ---- Tür / Alan yardımcıları ---- }
    function  ParseTypeName(out AVecDim: Integer): Byte;   // VCT_* donuyor
    procedure ParseColDef(var C: TColDef; Stmt: TSqlCreateTableStmt = nil);
    function  ReadFkAction: string;

    { ---- İfade Ayrıştırıcı ---- }
    // Operatör öncelik hiyerarşisi (en düşükten en yükseğe):
    //   OR -> AND -> NOT -> karşılaştırma -> ek/çıkar -> çarp/böl -> tekli -> atom
    function ParseExpr: TSqlExprNode;
    function ParseOrExpr: TSqlExprNode;
    function ParseAndExpr: TSqlExprNode;
    function ParseNotExpr: TSqlExprNode;
    function ParseCmpExpr: TSqlExprNode;
    function ParseAddExpr: TSqlExprNode;
    function ParseMulExpr: TSqlExprNode;
    function ParseUnaryExpr: TSqlExprNode;
    function ParsePrimary: TSqlExprNode;
    function ParseInList(Expr: TSqlExprNode; IsNot: Boolean): TSqlInNode;
    function ParseFuncCall(const FuncName: string): TSqlExprNode;
    // P5-WIN: OVER yan cumlecigi (sahiplenme yalniz basarida gecer).
    function ParseOver(const FuncName: string; Arg: TSqlExprNode;
      IsStar: Boolean; Off: Int64; Def: TSqlExprNode): TSqlWindowNode;
    function ParseLagLead(const FuncName: string): TSqlExprNode;
    function ParseCase: TSqlCaseNode;

    { ---- SELECT alt-parser ---- }
    procedure ParseSelectColumns(Stmt: TSqlSelectStmt);
    procedure ParseFromClause(Stmt: TSqlSelectStmt);
    // AS OF kuyrugu: "OF SEQUENCE n" | "OF VERSION x" | "OF TIMESTAMP '...'
    // ("AS" yoneticisi cagiran tarafca yutulmus olmalidir.)
    procedure ParseAsOfTail(Stmt: TSqlSelectStmt);
    procedure ParseJoinClause(var JC: TJoinClause; AllowNoOn: Boolean;
      out ExitCols: TStrArray);
    procedure ParseGroupBy(Stmt: TSqlSelectStmt);
    procedure ParseOrderBy(Stmt: TSqlSelectStmt);
    // F1-12: ORDER BY / LIMIT / OFFSET kuyrugu (set-op disina tasinabilir)
    procedure ParseSelectTail(Stmt: TSqlSelectStmt);
    // R-10: SET OP (UNION [ALL] / EXCEPT / INTERSECT). Ayrilmis metot
    // olarak duruyor cunku FROM'suz SELECT yolu da birlestirme kurabilir.
    procedure ParseSetOps(Stmt: TSqlSelectStmt);
    // ORDER BY ogesinden sonra opsiyonel COLLATE (yalniz TR desteklenir).
    procedure ParseCollate(var Item: TOrderItem);
    function ReadCollName: string;   // R-20

    { ---- Statement ayrıştırıcıları ---- }
    function ParseSelect: TSqlSelectStmt;
    // P5-CTE: WITH x AS (...), ... SELECT ... (yalniz SELECT; RECURSIVE
    // ve kolon alias'lari desteklenmez).
    function ParseWith: TSqlStmtNode;
    function ParseInsert: TSqlInsertStmt;
    function ParseUpdate: TSqlUpdateStmt;
    function ParseDelete: TSqlDeleteStmt;
    function ParseCreateTable: TSqlCreateTableStmt;
    function ParseAlterTable: TSqlAlterTableStmt;
    function ParseDropTable: TSqlDropTableStmt;
    function ParseCreateIndex: TSqlCreateIndexStmt;
    function ParseDropIndex: TSqlDropIndexStmt;
    // F-33/F-34: VIEW ve MATERIALIZED VIEW
    function ParseCreateView: TSqlCreateViewStmt;
    function ParseDropView: TSqlDropViewStmt;
    function ParseCreateMaterializedView: TSqlCreateMaterializedViewStmt;
    function ParseDropMaterializedView: TSqlDropMaterializedViewStmt;
    function ParseRefreshMaterializedView: TSqlRefreshMaterializedViewStmt;
    // R-03: ON CONFLICT [(hedef)] DO NOTHING | DO UPDATE SET col = ifade, ...
    // (INSERT sonunda; DO UPDATE SET listesi TUpdateAssignment olarak doldurulur)
    procedure ParseOnConflict(Stmt: TSqlInsertStmt);
    // R-04: RETURNING kolon/ifade listesi (INSERT/UPDATE/DELETE sonunda)
    procedure ParseReturning(var Cols: TStrArray; var Exprs: TList<TSqlExprNode>);
    // F-35: STORED FUNCTION / PROCEDURE
    function ParseCreateFunction: TSqlCreateFunctionStmt;
    function ParseDropFunction: TSqlDropFunctionStmt;
    function ParseCreateProcedure: TSqlCreateProcedureStmt;
    function ParseDropProcedure: TSqlDropProcedureStmt;
    function ParseCall: TSqlCallStmt;
    // R-11: SET CONSTRAINTS [ALL] DEFERRED | IMMEDIATE
    // (CONSTRAINTS anahtar kelimesi cagiranda YUTULMUS olur)
    function ParseSetConstraints: TSqlSetConstraintsStmt;
    function ParseSetIsolation: TSqlSetIsolationStmt;
    // R-18: CREATE/DROP ROLE ve GRANT/REVOKE. Anahtar kelimeler
    // (CREATE/DROP/GRANT/REVOKE) cagiranda yutulmus olur.
    function ParseRole: TRoleStmt;
    function ParseGrant: TGrantStmt;
    function ParsePolicy: TPolicyStmt;   // R-19
    // Govde parametre listesi: (IN|OUT|INOUT ad TIP [= varsayilan], ...)
    function ParseProcParamList(out Params: TFunctionParamArray): Boolean;
    // Govde icindeki tek cumle (akistan, konum sifirlanmadan)
    function ParseBodyStatement: TSqlStmtNode;
    // Govde: BEGIN s; ... END  |  tek cumle
    function ParseProcBody: TSqlStmtNode;
    function ParseReturn: TSqlReturnStmt;
    // F-36: CREATE/DROP TRIGGER + govde icindeki `NEW.kolon = ifade`
    function ParseCreateTrigger: TSqlCreateTriggerStmt;
    function ParseDropTrigger: TSqlDropTriggerStmt;
    function ParseSetNew: TSqlSetNewStmt;
    function ParseCast: TSqlCastNode;
    function ParseAdmin(const Kw1, Kw2: string): TSqlAdminStmt;
    function ParseJson(const Kw: string): TSqlJsonStmt;

  public
    { Parse: SQL metnini ayrıştırır, AST dugumu dondurur.
      Params: '?' yer tutucularini sirasıyla doldurur; `$1`, `$2` ...
      ise Params dizisinde 1-tabanli konumu secer. }
    function Parse(const ASql: string;
                   const AParams: array of string): TSqlStmtNode;
  end;

{ M1: SQL metnindeki en buyuk konumsal parametre numarasini dondurur
  ($1, $2 ...). Yalnizca tirnak/yorum disindaki $n sayilir; `?` JSONB
  operatoru ile karismamasi icin `?` burada sayilmaz. }
function VDbCountSqlParams(const Sql: string): Integer;

implementation

{ ============================================================
  Küçük yardımcılar
  ============================================================ }

function IsAlpha(C: Char): Boolean; inline;
begin Result := C in ['A'..'Z','a'..'z','_']; end;

function IsAlNum(C: Char): Boolean; inline;
begin Result := C in ['A'..'Z','a'..'z','0'..'9','_']; end;

function IsDigit(C: Char): Boolean; inline;
begin Result := C in ['0'..'9']; end;

function VDbCountSqlParams(const Sql: string): Integer;
var
  i, j, n, maxN: Integer;
  c: Char;
begin
  n := 0;
  maxN := 0;
  i := 1;
  while i <= Length(Sql) do
  begin
    c := Sql[i];
    // tek tirnakli metin ('' kacisi dahil)
    if c = '''' then
    begin
      Inc(i);
      while i <= Length(Sql) do
      begin
        if Sql[i] = '''' then
        begin
          if (i < Length(Sql)) and (Sql[i + 1] = '''') then Inc(i, 2)
          else begin Inc(i); Break; end;
        end
        else Inc(i);
      end;
    end
    // cift tirnakli tanimlayici
    else if c = '"' then
    begin
      Inc(i);
      while i <= Length(Sql) do
      begin
        if Sql[i] = '"' then
        begin
          if (i < Length(Sql)) and (Sql[i + 1] = '"') then Inc(i, 2)
          else begin Inc(i); Break; end;
        end
        else Inc(i);
      end;
    end
    // -- satir yorumu
    else if (c = '-') and (i < Length(Sql)) and (Sql[i + 1] = '-') then
    begin
      Inc(i, 2);
      while (i <= Length(Sql)) and (Sql[i] <> #10) do Inc(i);
    end
    // /* blok yorumu */
    else if (c = '/') and (i < Length(Sql)) and (Sql[i + 1] = '*') then
    begin
      Inc(i, 2);
      while i < Length(Sql) do
      begin
        if (Sql[i] = '*') and (Sql[i + 1] = '/') then
        begin Inc(i, 2); Break; end;
        Inc(i);
      end;
      if i > Length(Sql) then i := Length(Sql) + 1;
    end
    else if c = '$' then
    begin
      j := i + 1;
      while (j <= Length(Sql)) and IsDigit(Sql[j]) do Inc(j);
      if j > i + 1 then
      begin
        n := StrToIntDef(Copy(Sql, i + 1, j - i - 1), 0);
        if n > maxN then maxN := n;
        i := j;
      end
      else Inc(i);
    end
    else Inc(i);
  end;
  Result := maxN;
end;

// R-19: ParsePolicy (ustte) ExprToText'i kullanir; tanim asagida.
function ExprToText(E: TSqlExprNode): string; forward;

{ ============================================================
  TVDbParser — Tokenizer
  ============================================================ }

procedure TVDbParser.SkipWS;
begin
  while FPos <= FLen do
  begin
    case FSql[FPos] of
      ' ', #9, #10, #13: Inc(FPos);
      '-': // -- satir yorumu
        if (FPos < FLen) and (FSql[FPos+1] = '-') then
        begin
          Inc(FPos, 2);
          while (FPos <= FLen) and (FSql[FPos] <> #10) do Inc(FPos);
        end
        else Break;
      '/': // /* ... */ blok yorumu
        if (FPos < FLen) and (FSql[FPos+1] = '*') then
        begin
          Inc(FPos, 2);
          while FPos < FLen do
          begin
            if (FSql[FPos] = '*') and (FSql[FPos+1] = '/') then
            begin Inc(FPos, 2); Break; end;
            Inc(FPos);
          end;
        end
        else Break;
    else
      Break;
    end;
  end;
end;

function TVDbParser.Peek: Char;
begin
  if FPos <= FLen then Result := FSql[FPos] else Result := #0;
end;

function TVDbParser.AtEnd: Boolean;
begin
  SkipWS;
  Result := FPos > FLen;
end;

function TVDbParser.NextToken(out T: string; out IsStringLit: Boolean): Boolean;
var
  Start, i, pidx: Integer;
  c: Char;
  rangeOk: Boolean;
begin
  SkipWS;
  T := '';
  IsStringLit := False;
  Result := False;
  if FPos > FLen then Exit;

  // F-22: '?' iki anlamli: parametre yer tutucusu VEYA JSONB "anahtar var mi"
  // operatoru. Ayrim kurali: parametre BAGLANDIGINDA yer tutucu, aksi
  // halde operator. Boylece parametreli API (Exec(sql, params)) degismez,
  // `col ? 'anahtar'` yazilabilir.
  if FSql[FPos] = '?' then
  begin
    if FParamIdx <= High(FParams) then
    begin
      Inc(FPos);
      T := FParams[FParamIdx];
      Inc(FParamIdx);
      IsStringLit := True;
      Result := True;
      Exit;
    end;
    // JSONB operatoru: '?', '?|' veya '?&'
    Inc(FPos);
    T := '?';
    if FPos <= FLen then
    begin
      if FSql[FPos] = '|' then
      begin
        T := '?|';
        Inc(FPos);
      end
      else if FSql[FPos] = '&' then
      begin
        T := '?&';
        Inc(FPos);
      end;
    end;
    Result := True;
    Exit;
  end;

  // M1: PostgreSQL uyumlu konumsal parametre: $1, $2 ...
  if FSql[FPos] = '$' then
  begin
    Start := FPos + 1;
    i := Start;
    while (i <= FLen) and IsDigit(FSql[i]) do Inc(i);
    if i = Start then
      raise EVDbException.CreateFmt(ecSyntaxError,
        'gecersiz parametre: "$" (konum=%d)', [FPos]);
    if not TryStrToInt(Copy(FSql, Start, i - Start), pidx) then
      raise EVDbException.CreateFmt(ecSyntaxError,
        'gecersiz parametre numarasi: %s', [Copy(FSql, Start, i - Start)]);
    if (pidx < 1) or (pidx > Length(FParams)) then
      raise EVDbException.CreateFmt(ecSyntaxError,
        'parametre $%d tanimli degil (toplam %d)', [pidx, Length(FParams)]);
    FPos := i;
    T := FParams[pidx - 1];
    IsStringLit := True;
    Result := True;
    Exit;
  end;

  // F-22: '@>' — sol/sag JSONB icerme operatoru
  if FSql[FPos] = '@' then
  begin
    if (FPos < FLen) and (FSql[FPos + 1] = '>') then
    begin
      T := '@>';
      Inc(FPos, 2);
      Result := True;
      Exit;
    end;
    raise EVDbException.CreateFmt(ecSyntaxError,
      '"@" isaretinden sonra ">" bekleniyor (konum=%d)', [FPos]);
  end;

  // F-25: ARALIK LITERAL'I. "[1,5]", "(1,5]", "[1,)", "[1..5]" gibi diziler
// normal ifade AYRISTIRILAMAZ: lexer sayiyi '1' sonra ',' sonra '5' olarak
// verir ve ParseExpr hata verir. Bu yuzden parantezle baslayip eslesen
// kapanisla biten ve ICINDE yalnizca rakam/nokta/virgul/yildiz/eksi ve
// TEK tirnakli metin bulunan diziler TEK token olarak alinir.
//
// Guvenlik onlemleri:
//  - '(SELECT a FROM t)' alt sorgusu ic kelimeler icerdigi icin (harf)
//    bu kurala girmez.
//  - '(42, 3.5, 'merhaba', 1, ...)' INSERT VALUES satiri da tirnak icerir
//    ama KAPANIS parantez ')' ile degil ']' ile gelir; bu yuzden yalniz
//    ICINDE harf/kelime OLMAYAN diziler kabul edilir. Tirnakli metin
//    iceren diziler bu kurala GIRMEZ:INSERT satiri korunur.
  if (FSql[FPos] = '[') or (FSql[FPos] = '(') then
  begin
    Start := FPos;
    i := FPos + 1;
    rangeOk := False;
    while i <= FLen do
    begin
      c := FSql[i];
      // Tirnakli metin bu kurala girmez -> hemen vazgec.
      if c = '''' then Break;
      if c = ']' then
      begin
        rangeOk := True;
        Break;
      end;
      // Kapanis parantez ')' SADECE baslangicta '(' ile eslesirse ve
      // icerik disaridan yapisal DEGILSE (virgul sayisi sinirli).
      if c = ')' then Break;
      if not (c in ['0'..'9', '.', ',', '*', '-', ' ', #9]) then Break;
      Inc(i);
    end;
    if rangeOk then
    begin
      T := Copy(FSql, Start, i - Start + 1);
      FPos := i + 1;
      IsStringLit := True;
      Result := True;
      Exit;
    end;
  end;

  // '(...)' ile baslayan acik sol uc: "(1,5]" gibi. Kapanis ']' gelirse
  // aralik literal'idir; ')' gelirse normal parantez ifadesidir.
  if FSql[FPos] = '(' then
  begin
    Start := FPos;
    i := FPos + 1;
    rangeOk := False;
    while i <= FLen do
    begin
      c := FSql[i];
      if c = '''' then Break;
      if c = ']' then begin rangeOk := True; Break; end;
      if c = ')' then Break;
      if not (c in ['0'..'9', '.', ',', '*', '-', ' ', #9]) then Break;
      Inc(i);
    end;
    if rangeOk then
    begin
      T := Copy(FSql, Start, i - Start + 1);
      FPos := i + 1;
      IsStringLit := True;
      Result := True;
      Exit;
    end;
  end;

  // Tekli tırnaklı string
  if FSql[FPos] = '''' then
  begin
    IsStringLit := True;
    Inc(FPos); Start := FPos; T := '';
    while FPos <= FLen do
    begin
      if FSql[FPos] = '''' then
      begin
        if (FPos < FLen) and (FSql[FPos+1] = '''') then
        begin
          T := T + Copy(FSql, Start, FPos - Start) + '''';
          Inc(FPos, 2); Start := FPos; Continue;
        end;
        T := T + Copy(FSql, Start, FPos - Start);
        Inc(FPos); Result := True; Exit;
      end;
      Inc(FPos);
    end;
    raise EVDbException.Create(ecSyntaxError, 'Kapanmamis string sabiti');
  end;

  // Çift tırnaklı tanımlayıcı (quoted identifier)
  if FSql[FPos] = '"' then
  begin
    Inc(FPos); Start := FPos; T := '';
    while FPos <= FLen do
    begin
      if FSql[FPos] = '"' then
      begin
        T := T + Copy(FSql, Start, FPos - Start);
        Inc(FPos); Result := True; Exit;
      end;
      Inc(FPos);
    end;
    raise EVDbException.Create(ecSyntaxError, 'Kapanmamis tanimla (")');
  end;

  // Backtick tanımlayıcı `col`
  if FSql[FPos] = '`' then
  begin
    Inc(FPos); Start := FPos; T := '';
    while FPos <= FLen do
    begin
      if FSql[FPos] = '`' then
      begin
        T := T + Copy(FSql, Start, FPos - Start);
        Inc(FPos); Result := True; Exit;
      end;
      Inc(FPos);
    end;
    raise EVDbException.Create(ecSyntaxError, 'Kapanmamis tanimla (`)');
  end;

  // Sayı: tam veya ondalıklı
  if IsDigit(FSql[FPos]) then
  begin
    Start := FPos;
    while (FPos <= FLen) and IsDigit(FSql[FPos]) do Inc(FPos);
    if (FPos <= FLen) and (FSql[FPos] = '.') and
       (FPos < FLen) and IsDigit(FSql[FPos+1]) then
    begin
      Inc(FPos);
      while (FPos <= FLen) and IsDigit(FSql[FPos]) do Inc(FPos);
    end;
    T := Copy(FSql, Start, FPos - Start);
    Result := True; Exit;
  end;

  // Tanımlayıcı veya anahtar kelime
  if IsAlpha(FSql[FPos]) then
  begin
    Start := FPos;
    while (FPos <= FLen) and IsAlNum(FSql[FPos]) do Inc(FPos);
    T := Copy(FSql, Start, FPos - Start);
    Result := True; Exit;
  end;

  // Operatörler
  case FSql[FPos] of
    '<', '>',  '!':
      begin
        T := FSql[FPos]; Inc(FPos);
        if (FPos <= FLen) and (FSql[FPos] = '=') then begin T := T + '='; Inc(FPos); end
        else if (T = '<') and (FPos <= FLen) and (FSql[FPos] = '>') then begin T := '<>'; Inc(FPos); end
        // F-22: '<@' — JSONB "sol, sag'in icinde mi" operatoru
        else if (T = '<') and (FPos <= FLen) and (FSql[FPos] = '@') then begin T := '<@'; Inc(FPos); end
        // F-25: '<<' / '>>' — aralik "tamamen once" / "tamamen sonra"
        else if (FPos <= FLen) and (FSql[FPos] = T) and (T <> '<>') and
                (T <> '>=') then begin T := T + T; Inc(FPos); end;
        Result := True;
      end;
    // F-25: '&' baslayan aralik operatorleri: '&&', '&<', '&>'
    '&':
      begin
        T := '&'; Inc(FPos);
        if FPos <= FLen then
          case FSql[FPos] of
            '&': begin T := '&&'; Inc(FPos); end;
            '<', '>': begin T := T + FSql[FPos]; Inc(FPos); end;
          end;
        Result := True;
      end;
    // F-25: '-|-' aralik bitisiklik operatoru
    '-':
      begin
        T := '-'; Inc(FPos);
        if (FPos + 1 <= FLen) and (FSql[FPos] = '|') and (FSql[FPos+1] = '-') then
        begin
          T := '-|-'; Inc(FPos, 2);
        end;
        Result := True;
      end;
    '|':
      begin
        T := '|'; Inc(FPos);
        if (FPos <= FLen) and (FSql[FPos] = '|') then begin T := '||'; Inc(FPos); end;
        Result := True;
      end;
    '(', ')', ',', '*', '=', '+', '/', '%', '.', ';':
      begin T := FSql[FPos]; Inc(FPos); Result := True; end;
  else
    T := FSql[FPos]; Inc(FPos); Result := True;
  end;
end;

function TVDbParser.NextToken(out T: string): Boolean;
var dummy: Boolean;
begin
  Result := NextToken(T, dummy);
end;

function TVDbParser.VDbUnquote(const S: string): string;
// R-16: tek tirnakli dizgi kabuğunu soy. Soyma yoksa aynen doner
// (parser bazi yollarda zaten kabuktan arindirir).
begin
  Result := S;
  if (Length(Result) >= 2) and (Result[1] = '''') and
     (Result[Length(Result)] = '''') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

function TVDbParser.ParseTimeStampMS(const S: string): QWord;
// R-16: 'YYYY-MM-DD HH:MM:SS[.mmm]' -> Unix milisaniye.
// Motorda NOW da NowUnixMS ile AYNI zaman kaynagini (yerel) kullanir,
// boylece kullanici yazdigi saat ile motorun damgaladigi saat ayni
// olculer. Bicim taninmazsa HATA veririz (sessizce 0 donmek, "tum
// arsivi uygula" anlamina gelirdi -> HATALI KURTARMA).
var
  raw: string;
  frac: string;
  ms: Integer;
  dt: TDateTime;
  sp: Integer;
begin
  Result := 0;
  raw := VDbUnquote(S);
  ms := 0;
  sp := Pos('.', raw);
  if sp > 0 then
  begin
    frac := Copy(raw, sp + 1, Length(raw) - sp);
    raw := Copy(raw, 1, sp - 1);
    { en fazla 3 hane; fazlasi yoksay }
    if Length(frac) > 3 then frac := Copy(frac, 1, 3);
    while Length(frac) < 3 do frac := frac + '0';
    ms := StrToIntDef(frac, 0);
  end;
  if not TryStrToDateTime(raw, dt) then
    raise EVDbException.Create(ecSyntaxError,
      'RECOVER: zaman damgasi okunamadi: ' + S +
      ' (bicim: YYYY-MM-DD HH:MM:SS[.mmm])');
  Result := QWord(Int64(DateTimeToUnix(dt)) * 1000 + ms);
end;

function TVDbParser.PeekToken: string;
var SavePos, SaveIdx: Integer; T: string;
begin
  SavePos := FPos; SaveIdx := FParamIdx;
  if not NextToken(T) then T := '';
  FPos := SavePos; FParamIdx := SaveIdx;
  Result := UpperCase(T);
end;

function TVDbParser.PeekToken2: string;
var SavePos, SaveIdx: Integer; T: string;
begin
  SavePos := FPos; SaveIdx := FParamIdx;
  if not NextToken(T) then begin FPos := SavePos; FParamIdx := SaveIdx; Result := ''; Exit; end;
  if not NextToken(T) then T := '';
  FPos := SavePos; FParamIdx := SaveIdx;
  Result := UpperCase(T);
end;

function TVDbParser.PeekToken3: string;
// Ucuncu siradaki token'a bakar (FPos degismez). `LEFT JOIN LATERAL`
// gibi uc kelimelik bir ozdesligi tek bakista test etmek icin gerekli.
var SavePos, SaveIdx: Integer; T: string; k: Integer;
begin
  SavePos := FPos; SaveIdx := FParamIdx;
  T := '';
  for k := 1 to 3 do
    if not NextToken(T) then T := '';
  FPos := SavePos; FParamIdx := SaveIdx;
  Result := UpperCase(T);
end;

procedure TVDbParser.Expect(const W: string);
var T: string;
begin
  if not NextToken(T) then
    raise EVDbException.CreateFmt(ecSyntaxError, '"%s" bekleniyor ama dosya sonu (%s)', [W, CurPos]);
  if not SameText(T, W) then
    raise EVDbException.CreateFmt(ecSyntaxError, '"%s" bekleniyor, "%s" bulundu (%s)', [W, T, CurPos]);
end;

procedure TVDbParser.ExpectToken(out T: string; out IsStringLit: Boolean);
begin
  if not NextToken(T, IsStringLit) then
    raise EVDbException.Create(ecSyntaxError, 'Beklenmedik dosya sonu ' + CurPos);
end;

procedure TVDbParser.ExpectToken(out T: string);
var dummy: Boolean;
begin
  ExpectToken(T, dummy);
end;

function TVDbParser.TryEat(const W: string): Boolean;
var SavePos, SaveIdx: Integer; T: string;
begin
  SavePos := FPos; SaveIdx := FParamIdx;
  if not NextToken(T) then begin Result := False; Exit; end;
  if SameText(T, W) then
  begin
    Result := True;
  end
  else
  begin
    FPos := SavePos; FParamIdx := SaveIdx;
    Result := False;
  end;
end;

function TVDbParser.CurPos: string;
begin
  Result := 'konum=' + IntToStr(FPos);
end;

{ ============================================================
  Tür / Alan yardımcıları
  ============================================================ }

function TVDbParser.ParseTypeName(out AVecDim: Integer): Byte;
var T, U: string;
begin
  AVecDim := 0;
  ExpectToken(T); U := UpperCase(T);
  // M4: VECTOR(n) -> JSON sayi dizisi (TEXT) + boyut kisiti.
  if U = 'VECTOR' then
  begin
    if TryEat('(') then
    begin
      ExpectToken(T);
      if (not TryStrToInt(Trim(T), AVecDim)) or (AVecDim < 1) or
         (AVecDim > 255) then
        raise EVDbException.CreateFmt(ecSyntaxError,
          'VECTOR boyutu 1..255 olmali: "%s"', [T]);
      Expect(')');
    end;
    Exit(VCT_STR);
  end;
  // Boyutlu tipler: VARCHAR(n), CHAR(n), DECIMAL(p,s) vs. — boyutu yut
  if U = 'VARCHAR'  then begin if TryEat('(') then begin ExpectToken(T); if not TryEat(')') then Expect(')'); end; Exit(VCT_STR); end;
  if U = 'CHAR'     then begin if TryEat('(') then begin ExpectToken(T); if not TryEat(')') then Expect(')'); end; Exit(VCT_STR); end;
  if U = 'TEXT'     then Exit(VCT_STR);
  if U = 'STRING'   then Exit(VCT_STR);
  if (U = 'INT') or (U = 'INTEGER') or (U = 'BIGINT') or (U = 'SMALLINT') or (U = 'TINYINT') then Exit(VCT_INT);
  if U = 'SERIAL'   then Exit(VCT_INT);
  if (U = 'FLOAT') or (U = 'DOUBLE') or (U = 'REAL') or (U = 'DECIMAL') or (U = 'NUMERIC') then
  begin
    if TryEat('(') then begin ExpectToken(T); TryEat(','); if TryEat(',') then ExpectToken(T); Expect(')'); end;
    Exit(VCT_FLOAT);
  end;
  if (U = 'BOOL') or (U = 'BOOLEAN') then Exit(VCT_BOOL);
  if U = 'DATE'     then Exit(VCT_DATE);
  if (U = 'DATETIME') or (U = 'TIMESTAMP') then Exit(VCT_DATETIME);
  if U = 'TIME'     then Exit(VCT_TIME);
  if (U = 'BLOB') or (U = 'BINARY') or (U = 'BYTEA') then Exit(VCT_BLOB);
  raise EVDbException.CreateFmt(ecSyntaxError, 'Bilinmeyen kolon tipi: "%s" (%s)', [T, CurPos]);
end;

function TVDbParser.ReadFkAction: string;
var T: string;
begin
  ExpectToken(T); T := UpperCase(T);
  if T = 'RESTRICT'    then Exit(VDB_FK_RESTRICT);
  if T = 'CASCADE'     then Exit(VDB_FK_CASCADE);
  if T = 'SET'         then begin Expect('NULL'); Exit(VDB_FK_SETNULL); end;
  if (T = 'NO') or (T = 'NOTHING') then begin if T = 'NO' then Expect('ACTION'); Exit(VDB_FK_RESTRICT); end;
  if T = 'DEFAULT'     then Exit(VDB_FK_SETDEFAULT);
  raise EVDbException.CreateFmt(ecSyntaxError, 'Gecersiz FK aksiyonu: "%s" (%s)', [T, CurPos]);
end;

procedure TVDbParser.ParseColDef(var C: TColDef; Stmt: TSqlCreateTableStmt = nil);
var T, U: string; SavePos, SaveIdx: Integer;
    fk: TFkDef;
    VDbTmpCollation: TVDbLang;   // R-20: cozumlenen dil profili
    GenAST: TSqlExprNode;        // M10: GENERATED ifadesi
begin
  C.Ctype := VCT_STR;
  C.NotNull := False;
  C.HasDef := False;
  C.Def := '';
  C.Unique := False;
  C.Collate := '';   // R-20
  C.Generated := False;
  C.GenExpr := '';
  C.Identity := 0;   // M10: GENERATED ... AS IDENTITY
  C.VecDim := 0;     // M4: VECTOR(n)
  C.Encrypted := False;   // M6: kolon sifreleme
  C.ColKeyId := 0;
  // Tip adını oku
  C.Ctype := ParseTypeName(C.VecDim);

  // Nitelikleri tüket (PRIMARY KEY, NOT NULL, DEFAULT, AUTOINCREMENT, UNIQUE, REFERENCES, CHECK)
  while True do
  begin
    SavePos := FPos; SaveIdx := FParamIdx;
    if not NextToken(T) then Break;
    U := UpperCase(T);
    if U = 'PRIMARY' then
    begin
      Expect('KEY'); // ParseCreateTable PkIndex'i ayri yonetiyor
    end
    else if U = 'NOT' then
    begin
      // R-11: `NOT DEFERRABLE` de NOT ile baslar; NOT NULL'dan ayirt et.
      if PeekToken = 'DEFERRABLE' then
      begin
        NextToken(T);          // DEFERRABLE
        C.Deferrable := 0;
      end
      else
      begin
        Expect('NULL');
        C.NotNull := True;
      end;
    end
    else if U = 'NULL' then
    begin
      // NULL explicitly -> nullable
    end
    else if U = 'DEFAULT' then
    begin
      ExpectToken(T);
      C.HasDef := True;
      C.Def := T;
    end
    else if (U = 'AUTOINCREMENT') or (U = 'AUTO_INCREMENT') then
    begin
      // AutoInc: tablo seviyesinde; buradan yonetilmiyor
    end
    else if U = 'UNIQUE' then
    begin
      C.Unique := True;
    end
    // ---- M6: kolon seviyesi sifreleme ----
    else if U = 'ENCRYPTED' then
    begin
      C.Encrypted := True;
    end
    else if U = 'REFERENCES' then
    begin
      fk.Col := -1;
      if Stmt <> nil then fk.Col := Length(Stmt.Cols);
      ExpectToken(T); fk.RefTable := VDbNorm(T);
      fk.RefCol := '';
      if PeekToken = '(' then
      begin
        Expect('('); ExpectToken(T); fk.RefCol := VDbNorm(T); Expect(')');
      end;
      fk.OnDelete := VDB_FK_RESTRICT;
      fk.OnUpdate := VDB_FK_RESTRICT;
      fk.Deferrable := 0;
      while PeekToken = 'ON' do
      begin
        ExpectToken(T); // ON
        ExpectToken(T); // DELETE|UPDATE
        if UpperCase(T) = 'DELETE' then fk.OnDelete := ReadFkAction
        else if UpperCase(T) = 'UPDATE' then fk.OnUpdate := ReadFkAction;
      end;
      // ---- R-11: DEFERRABLE / INITIALLY DEFERRED ----
      while True do
      begin
        if PeekToken = 'DEFERRABLE' then
        begin
          NextToken(T);
          fk.Deferrable := 1;
          if PeekToken = 'INITIALLY' then
          begin
            NextToken(T); ExpectToken(T);
            if UpperCase(T) = 'DEFERRED' then fk.Deferrable := 2
            else if UpperCase(T) = 'IMMEDIATE' then fk.Deferrable := 1;
          end;
        end
        else if (PeekToken = 'NOT') and (PeekToken2 = 'DEFERRABLE') then
        begin
          NextToken(T); NextToken(T);
          fk.Deferrable := 0;
        end
        else if PeekToken = 'INITIALLY' then
        begin
          NextToken(T); ExpectToken(T);
          if UpperCase(T) = 'DEFERRED' then fk.Deferrable := 2
          else if UpperCase(T) = 'IMMEDIATE' then fk.Deferrable := 1;
        end
        else Break;
      end;
      if Stmt <> nil then
      begin
        SetLength(Stmt.Fks, Length(Stmt.Fks) + 1);
        Stmt.Fks[High(Stmt.Fks)] := fk;
      end;
    end
    else if (U = 'CHECK') then
    begin
      Expect('(');
      if Stmt <> nil then
        Stmt.CheckExprs.Add(ParseExpr)
      else
        ParseExpr.Free;
      Expect(')');
    end
    // ---- R-11: DEFERRABLE / INITIALLY ----
    else if U = 'DEFERRABLE' then
    begin
      C.Deferrable := 1;
      // INITIALLY DEFERRED|IMMEDIATE opsiyonel
      if PeekToken = 'INITIALLY' then
      begin
        NextToken(T);
        ExpectToken(T);
        if UpperCase(T) = 'DEFERRED' then C.Deferrable := 2
        else if UpperCase(T) = 'IMMEDIATE' then C.Deferrable := 1;
      end;
    end
    else if U = 'INITIALLY' then
    begin
      ExpectToken(T);
      if UpperCase(T) = 'DEFERRED' then C.Deferrable := 2
      else if UpperCase(T) = 'IMMEDIATE' then C.Deferrable := 1;
    end
    else if U = 'NOT' then
    begin
      // NOT DEFERRABLE (R-11) veya NOT NULL
      if PeekToken = 'DEFERRABLE' then
      begin
        NextToken(T);
        C.Deferrable := 0;
      end
      else
      begin
        Expect('NULL');
        C.NotNull := True;
      end;
    end
    // ---- M10: GENERATED ALWAYS AS (ifade) [STORED|VIRTUAL] ----
    else if U = 'GENERATED' then
    begin
      ExpectToken(T);
      if UpperCase(T) = 'BY' then
      begin
        // M10: GENERATED BY DEFAULT AS IDENTITY
        Expect('DEFAULT');
        Expect('AS');
        if UpperCase(PeekToken) <> 'IDENTITY' then
          raise EVDbException.Create(ecSyntaxError,
            'GENERATED BY DEFAULT sonrasi AS IDENTITY bekleniyor');
        NextToken(T);
        if PeekToken = '(' then
          raise EVDbException.Create(ecUnsupported,
            'IDENTITY secenekleri (START WITH/INCREMENT BY) desteklenmiyor');
        C.Identity := 2;
        C.NotNull := True;
      end
      else
      begin
        if UpperCase(T) <> 'ALWAYS' then
          raise EVDbException.Create(ecSyntaxError,
            'GENERATED sonrasi ALWAYS veya BY DEFAULT bekleniyor, "' +
            T + '" bulundu');
        Expect('AS');
        if UpperCase(PeekToken) = 'IDENTITY' then
        begin
          // M10: GENERATED ALWAYS AS IDENTITY
          NextToken(T);
          if PeekToken = '(' then
            raise EVDbException.Create(ecUnsupported,
              'IDENTITY secenekleri (START WITH/INCREMENT BY) desteklenmiyor');
          C.Identity := 1;
          C.NotNull := True;
        end
        else
        begin
          Expect('(');
          GenAST := ParseExpr;
          try
            C.GenExpr := ExprToText(GenAST);
          finally
            GenAST.Free;
          end;
          C.Generated := True;
          Expect(')');
          if UpperCase(PeekToken) = 'STORED' then
            NextToken(T)
          else if UpperCase(PeekToken) = 'VIRTUAL' then
            NextToken(T);   // saklama modeli ayni (STORED gibi)
        end;
      end;
    end
    // ---- R-20: kolon varsayilan collation'i ----
    else if U = 'COLLATE' then
    begin
      T := ReadCollName;
      C.Collate := UpperCase(T);
      // Tirnakli yazim: "tr-TR-u-kn-ks"
      if (Length(C.Collate) >= 2) and (C.Collate[1] = '"') and
         (C.Collate[Length(C.Collate)] = '"') then
        C.Collate := UpperCase(Copy(C.Collate, 2, Length(C.Collate) - 2));
      if not VDbLangProfile(C.Collate, VDbTmpCollation) then
        raise EVDbException.CreateFmt(ecSyntaxError,
          'gecersiz COLLATE: "%s" (bos olamaz)', [T]);
      C.Collate := VDbCollationName(VDbTmpCollation);
    end
    else
    begin
      // Taninmayan token -> geri sar, donguden cik
      FPos := SavePos; FParamIdx := SaveIdx;
      Break;
    end;
    end;
  end;


{ ============================================================
  İfade Ayrıştırıcı
  ============================================================ }

function TVDbParser.ParseExpr: TSqlExprNode;
begin
  Result := ParseOrExpr;
end;

function TVDbParser.ParseOrExpr: TSqlExprNode;
var Right: TSqlExprNode; dummy: string;
begin
  Result := ParseAndExpr;
  while PeekToken = 'OR' do
  begin
    NextToken(dummy);
    Right := ParseAndExpr;
    Result := TSqlBinaryOpNode.Create(sboOr, Result, Right);
  end;
end;

function TVDbParser.ParseAndExpr: TSqlExprNode;
var Right: TSqlExprNode; T: string;
begin
  Result := ParseNotExpr;
  while PeekToken = 'AND' do
  begin
    NextToken(T);
    Right := ParseNotExpr;
    Result := TSqlBinaryOpNode.Create(sboAnd, Result, Right);
  end;
end;

function TVDbParser.ParseNotExpr: TSqlExprNode;
var T: string;
begin
  if PeekToken = 'NOT' then
  begin
    Inc(FDepth);
    try
      if FDepth > 256 then
        raise EVDbException.Create(ecSyntaxError, 'ifade derinligi cok fazla (max 256)');
      NextToken(T);
      Result := TSqlUnaryOpNode.Create(suoNot, ParseCmpExpr);
    finally
      Dec(FDepth);
    end;
  end
  else
    Result := ParseCmpExpr;
end;

function TVDbParser.ParseCmpExpr: TSqlExprNode;
var
  T, U: string;
  Op: TSqlBinaryOp;
  Right: TSqlExprNode;
  Low, High: TSqlExprNode;
  IsNot: Boolean;
  SavePos, SaveIdx: Integer;
  likeNode: TSqlExprNode;
  quantKind: TQuantKind;   // F-06: ANY/SOME/ALL
  quantSel: TSqlSelectStmt;
  jsonKeys: TList<TSqlExprNode>;   // F-22: ?| / ?& anahtar listesi
  quantLeft: TSqlExprNode;
  VDbTmpCollCmp: TVDbLang;   // R-20: cozumlenen dil profili
begin
  // P5-2: EXISTS (SELECT ...) — NOT EXISTS, NOT islemiyle ParseNotExpr'ten gelir.
  if PeekToken = 'EXISTS' then
  begin
    NextToken(T);
    Expect('(');
    if PeekToken <> 'SELECT' then
      raise EVDbException.CreateFmt(ecSyntaxError,
        'EXISTS sonrasi SELECT bekleniyor (%s)', [CurPos]);
    NextToken(T); // SELECT
    Result := TSqlSubqueryNode.CreateExists(ParseSelect);
    Expect(')');
    Exit;
  end;

  Result := ParseAddExpr;

  while True do
  begin
    SavePos := FPos; SaveIdx := FParamIdx;
    if not NextToken(T) then Break;
    U := UpperCase(T);

    if U = '='  then Op := sboEq
    else if (U = '<>') or (U = '!=') then Op := sboNeq
    else if U = '<'  then Op := sboLt
    else if U = '<=' then Op := sboLte
    else if U = '>'  then Op := sboGt
    else if U = '>=' then Op := sboGte
    else if U = 'LIKE' then Op := sboLike
    else if U = 'ILIKE' then Op := sboILike  // F-05: buyuk/kucuk duyarsiz LIKE
    // ---- F-22: JSONB operatorleri ----
    else if U = '@>' then Op := sboJsonContains   // sol, sag'i iceriyor mu
    else if U = '<@' then Op := sboJsonContained  // sol, sag'in icinde mi
    else if U = '?'  then Op := sboJsonHasKey     // anahtar var mi
    // ---- F-22: '?|' ve '?&' anahtar LISTESI alir -> ozel dugum ----
    else if U = '?|' then
    begin
      jsonKeys := TList<TSqlExprNode>.Create;
      Expect('(');
      while True do
      begin
        jsonKeys.Add(ParseExpr);
        if PeekToken <> ',' then Break;
        NextToken(T);   // ','
      end;
      Expect(')');
      Result := TSqlJsonKeyNode.Create(Result, jsonKeys, False);
      jsonKeys := nil;   // sahiplik dugumde
      Continue;
    end
    else if U = '?&' then
    begin
      jsonKeys := TList<TSqlExprNode>.Create;
      Expect('(');
      while True do
      begin
        jsonKeys.Add(ParseExpr);
        if PeekToken <> ',' then Break;
        NextToken(T);   // ','
      end;
      Expect(')');
      Result := TSqlJsonKeyNode.Create(Result, jsonKeys, True);
      jsonKeys := nil;
      Continue;
    end
    // ---- F-25: RANGE operatorleri ----
    else if U = '@>' then Op := sboRangeContains   // aralik digerini iceriyor
    else if U = '<@' then Op := sboRangeContained  // aralik digerinin icinde
    else if U = '&&' then Op := sboRangeOverlap    // kesisim var mi
    else if U = '<<' then Op := sboRangeBefore     // tamamen once
    else if U = '>>' then Op := sboRangeAfter      // tamamen sonra
    else if U = '&<' then Op := sboRangeOvLeft     // kesisir, sol
    else if U = '&>' then Op := sboRangeOvRight    // kesisir, sag
    else if U = '-|-' then Op := sboRangeAdjacent  // bitisiklik (kesisimsiz)
    else if U = 'IS' then
    begin
      IsNot := TryEat('NOT');
      Expect('NULL');
      if IsNot then
        Result := TSqlUnaryOpNode.Create(suoIsNotNull, Result)
      else
        Result := TSqlUnaryOpNode.Create(suoIsNull, Result);
      Continue;
    end
    else if U = 'NOT' then
    begin
      U := PeekToken;
      if U = 'LIKE' then
      begin
        NextToken(T);
        Right := ParseAddExpr;
        // NOT LIKE = Like + NOT
        likeNode := TSqlBinaryOpNode.Create(sboLike, Result, Right);
        Result := TSqlUnaryOpNode.Create(suoNot, likeNode);
        Continue;
      end
      else if U = 'IN' then
      begin
        NextToken(T);
        Expect('(');
        Result := ParseInList(Result, True);
        Continue;
      end
      else if U = 'ILIKE' then   // F-05: NOT ILIKE = ILIKE + NOT
      begin
        NextToken(T);
        Right := ParseAddExpr;
        likeNode := TSqlBinaryOpNode.Create(sboILike, Result, Right);
        Result := TSqlUnaryOpNode.Create(suoNot, likeNode);
        Continue;
      end
      else if U = 'BETWEEN' then
      begin
        NextToken(T);
        Low := ParseAddExpr;
        Expect('AND');
        High := ParseAddExpr;
        Result := TSqlBetweenNode.Create(Result, Low, High, True);
        Continue;
      end
      else
      begin
        FPos := SavePos; FParamIdx := SaveIdx;
        Break;
      end;
    end
    else if U = 'IN' then
    begin
      Expect('(');
      Result := ParseInList(Result, False);
      Continue;
    end
    else if U = 'BETWEEN' then
    begin
      Low := ParseAddExpr;
      Expect('AND');
      High := ParseAddExpr;
      Result := TSqlBetweenNode.Create(Result, Low, High, False);
      Continue;
    end
    else
    begin
      FPos := SavePos; FParamIdx := SaveIdx;
      Break;
    end;

    // F-06: karsilastirma operatorunden SONRA ANY/SOME/ALL gelebilir
    // (`n = ANY (SELECT ...)`). Bu kontrol `Right` parse EDILMEDEN
    // yapilir; aksi halde ANY bir fonksiyon cagrisi sanilip yutulur.
    if (PeekToken = 'ANY') or (PeekToken = 'SOME') or (PeekToken = 'ALL') then
    begin
      U := PeekToken;
      if (Op <> sboEq) and (Op <> sboNeq) and (Op <> sboLt) and
         (Op <> sboLte) and (Op <> sboGt) and (Op <> sboGte) then
        raise EVDbException.CreateFmt(ecSyntaxError,
          'ANY/SOME/ALL yalnizca =, <>, <, <=, >, >= ile kullanilabilir (%s)', [CurPos]);
      NextToken(T); // ANY / SOME / ALL
      Expect('(');
      if PeekToken <> 'SELECT' then
        raise EVDbException.CreateFmt(ecSyntaxError,
          'ANY/SOME/ALL sonrasi SELECT bekleniyor (%s)', [CurPos]);
      NextToken(T); // SELECT
      if U = 'ALL' then quantKind := qkAll else quantKind := qkAny;
      // DIKKAT: ParseSelect ONCE ayri degiskene alinir. Dogrudan
      // TSqlQuantNode.Create(..., ParseSelect) yazilirsa FPC arguman
      // degerlendirme sirasi Result'a atama yapabilir, SOL IFADE kaybolur.
      quantSel := ParseSelect;
      quantLeft := Result;
      Result := TSqlQuantNode.Create(quantKind, quantLeft, Op, quantSel);
      quantSel := nil;
      Expect(')');
      Continue;
    end;
    Right := ParseAddExpr;
    Result := TSqlBinaryOpNode.Create(Op, Result, Right);
    // R-20: `a = b COLLATE <ad>` — karsilastirma ifadesinden sonra.
    if PeekToken = 'COLLATE' then
    begin
      NextToken(T);                     // COLLATE
      T := ReadCollName;
      if not VDbLangProfile(T, VDbTmpCollCmp) then
        raise EVDbException.CreateFmt(ecSyntaxError,
          'gecersiz COLLATE: "%s" (bos olamaz)', [T]);
      Result := TSqlCollateNode.Create(Result, VDbCollationName(VDbTmpCollCmp));
    end;
  end;
end;

function TVDbParser.ParseAddExpr: TSqlExprNode;
var T: string; Op: TSqlBinaryOp; Right: TSqlExprNode;
    SavePos, SaveIdx: Integer;
begin
  Result := ParseMulExpr;
  while True do
  begin
    SavePos := FPos; SaveIdx := FParamIdx;
    if not NextToken(T) then Break;
    if T = '+'  then Op := sboAdd
    else if T = '-' then Op := sboSub
    else if (T = '|') or (T = '||') then
    begin
      // || string birlestirme -> sboConcat
      // Tokenizer '||' i tek token olarak dondurdugu icin
      // iki ayri '|' gelirse birlestirir, '||' ise direkt kullanilir.
      if T = '|' then NextToken(T);  // ikinci '|' birlesir
      Op := sboConcat;
    end
    else begin FPos := SavePos; FParamIdx := SaveIdx; Break; end;
    Right := ParseMulExpr;
    Result := TSqlBinaryOpNode.Create(Op, Result, Right);
  end;
end;

function TVDbParser.ParseMulExpr: TSqlExprNode;
var T: string; Op: TSqlBinaryOp; Right: TSqlExprNode;
    SavePos, SaveIdx: Integer;
begin
  Result := ParseUnaryExpr;
  while True do
  begin
    SavePos := FPos; SaveIdx := FParamIdx;
    if not NextToken(T) then Break;
    if T = '*'  then Op := sboMul
    else if T = '/' then Op := sboDiv
    else if T = '%' then Op := sboMod
    else begin FPos := SavePos; FParamIdx := SaveIdx; Break; end;
    Right := ParseUnaryExpr;
    Result := TSqlBinaryOpNode.Create(Op, Result, Right);
  end;
end;

function TVDbParser.ParseUnaryExpr: TSqlExprNode;
var T: string;
begin
  if PeekToken = '-' then
  begin
    NextToken(T);
    Result := TSqlUnaryOpNode.Create(suoNeg, ParsePrimary);
  end
  else
    Result := ParsePrimary;
end;

function TVDbParser.ParseInList(Expr: TSqlExprNode; IsNot: Boolean): TSqlInNode;
var T: string; Item: TSqlExprNode;
begin
  Result := TSqlInNode.Create(Expr, IsNot);
  if PeekToken = ')' then begin NextToken(T); Exit; end; // bos IN listesi
  // P5-2: IN (SELECT ...) — ic sorgu tek kolon dondurmelidir.
  // (ParseSelect SELECT anahtarini tuketmez; burada yutulur.)
  if PeekToken = 'SELECT' then
  begin
    NextToken(T); // SELECT
    Result.SubSelect := ParseSelect;
    Expect(')');
    Exit;
  end;
  while True do
  begin
    Item := ParseExpr;
    Result.List.Add(Item);
    if PeekToken = ')' then begin NextToken(T); Break; end;
    Expect(',');
  end;
end;

function TVDbParser.ParseFuncCall(const FuncName: string): TSqlExprNode;
var T: string; Arg, Arg2: TSqlExprNode; IsStar, IsDistinct: Boolean; Args: TList<TSqlExprNode>; i: Integer;
// F-25: RANGE() ham arguman metni ('~' ile birlestirilir) + tek literal listesi
  raw: string; litList: TList<TSqlExprNode>;
    aggN: TSqlAggNode; aggKind: TAggKind; aggPct: Double;
    filterNode: TSqlExprNode;   // F-16
begin
  // P5-WIN: LAG/LEAD ayri yoldan cozumlener (OVER sart).
  if (FuncName = 'LAG') or (FuncName = 'LEAD') then
    Exit(ParseLagLead(FuncName));

  // F-02: NULLIF(a,b) — iki arguman; COALESCE(a,b,c,...) — degisken arguman
  if FuncName = 'NULLIF' then
  begin
    Arg := ParseExpr;
    Expect(','); Arg2 := ParseExpr; Expect(')');
    Exit(TSqlNullIfNode.Create(Arg, Arg2));
  end;
  if FuncName = 'COALESCE' then
  begin
    Args := TList<TSqlExprNode>.Create;
    try
      repeat
        Args.Add(ParseExpr);
        if PeekToken <> ',' then Break;
        NextToken(T);
      until False;
      Expect(')');
      Result := TSqlCoalesceNode.Create(Args);
      Exit;
    except
      Args.Free; raise;
    end;
  end;

  // F-24: SPATIAL — DISTANCE / HAVERSINE / IN_CIRCLE / IN_BOX / IN_POLYGON / AREA_POLYGON
  // ROUND da burada: ROUND(x[, digits]) degisken argumanlidir; tek-argumanli
  // yolda fn.Args nil kalir ve EvalExpr'de fn.Args.Count -> AV verir.
  if (FuncName = 'DISTANCE') or (FuncName = 'HAVERSINE') or
     (FuncName = 'IN_CIRCLE') or (FuncName = 'IN_BOX') or
     (FuncName = 'IN_POLYGON') or (FuncName = 'AREA_POLYGON') or
     (FuncName = 'ROUND') then
  begin
    Args := TList<TSqlExprNode>.Create;
    try
      if PeekToken = ')' then
      begin
        NextToken(T);
      end
      else
      begin
        repeat
          Args.Add(ParseExpr);
          if PeekToken <> ',' then Break;
          NextToken(T);   // ','
        until False;
        Expect(')');
      end;
      Result := TSqlFuncCallNode.Create(FuncName, nil, False, False);
      TSqlFuncCallNode(Result).Args := Args;
      Args := nil;   // sahiplik dugumde
    except
      Args.Free; raise;
    end;
    Exit;
  end;

  // F-25: RANGE(alt, ust [, '[]'|'[)'|'(]'|'()'])
  // NOT: RANGE argumanlari duz ParseExpr ile AYRISTIRILAMAZ. Metin icinde
  // yazilan "1..5" ifadesi lexer'da '1', '.', '.', '5' olarak gelir ve
  // ParseExpr hata verir. Bu yuzden tum argumanlar ham metin olarak
  // toplanip tek bir literal dugumde birlestirilir; ayristirmayi motor
  // (VDbMakeRange) yapar.
  if FuncName = 'RANGE' then
  begin
    raw := '';
    litList := TList<TSqlExprNode>.Create;
    try
      // DIKKAT: ParseFuncCall'a girerken '(' HENUZ YUTULMAMISTIR; ParsePrimary
      // yalnizca fonksiyon adini okur, bu yuzden burada '(' beklenmez.
      if PeekToken <> ')' then
      begin
        repeat
          if not NextToken(T) then
            raise EVDbException.Create(ecSyntaxError, 'RANGE() kapatilmadi');
          if T = '''' then T := '';
          if raw = '' then raw := T else raw := raw + '~' + T;
          if PeekToken <> ',' then Break;
          NextToken(T);   // ','
        until False;
      end;
      Expect(')');
      litList.Add(TSqlLiteralNode.CreateStr(raw));
      Result := TSqlFuncCallNode.Create(FuncName, nil, False, False);
      TSqlFuncCallNode(Result).Args := litList;
      litList := nil;
    except
      litList.Free; raise;
    end;
    Exit;
  end;

  // F-25: CONTAINS(aralik, nokta) — normal ifade argumanlari
  if FuncName = 'CONTAINS' then
  begin
    Args := TList<TSqlExprNode>.Create;
    try
      if PeekToken = ')' then NextToken(T)
      else
      begin
        repeat
          Args.Add(ParseExpr);
          if PeekToken <> ',' then Break;
          NextToken(T);
        until False;
        Expect(')');
      end;
      Result := TSqlFuncCallNode.Create(FuncName, nil, False, False);
      TSqlFuncCallNode(Result).Args := Args;
      Args := nil;
    except
      Args.Free; raise;
    end;
    Exit;
  end;

  // F-23: XML — degisken argumanli fonksiyonlar.
//   XMLELEMENT('ad', icerik [, icerik...])
//   XMLCONCAT(a, b, ...)
//   XMLEXTract(xml, yol) | XMLEXISTS(xml, yol) | XMLCOUNT(xml, yol)
//   XMLATTR(xml, yol, 'ad') | XMLESCAPE(s) | XMLPARSE(s)
  if Copy(FuncName, 1, 3) = 'XML' then
  begin
    if (FuncName <> 'XMLELEMENT') and (FuncName <> 'XMLCONCAT') and
       (FuncName <> 'XMLEXTRACT') and (FuncName <> 'XMLEXISTS') and
       (FuncName <> 'XMLCOUNT') and (FuncName <> 'XMLATTR') and
       (FuncName <> 'XMLESCAPE') and (FuncName <> 'XMLPARSE') then
      raise EVDbException.CreateFmt(ecSyntaxError,
        'bilinmeyen XML fonksiyonu: %s', [FuncName]);
    Args := TList<TSqlExprNode>.Create;
    try
      if PeekToken = ')' then
      begin
        NextToken(T);
      end
      else
      begin
        repeat
          Args.Add(ParseExpr);
          if PeekToken <> ',' then Break;
          NextToken(T);   // ','
        until False;
        Expect(')');
      end;
      Result := TSqlFuncCallNode.Create(FuncName, nil, False, False);
      TSqlFuncCallNode(Result).Args := Args;
      Args := nil;   // sahiplik dugumde
    except
      Args.Free; raise;
    end;
    Exit;
  end;

  // F-14: STRING_AGG(deger, ayirac [, DISTINCT])
  if FuncName = 'STRING_AGG' then
  begin
    aggN := TSqlAggNode.Create(akStringAgg);
    try
      if PeekToken = 'DISTINCT' then
      begin
        NextToken(T);
        aggN.IsDistinct := True;
      end;
      aggN.Arg := ParseExpr;
      if PeekToken = ',' then
      begin
        NextToken(T);
        aggN.Sep := ParseExpr;
      end;
      Expect(')');
      Result := aggN;
      aggN := nil;
      Exit;
    except
      aggN.Free;
      raise;
    end;
  end;
  // F-15: PERCENTILE_CONT/DISC(0.5) WITHIN GROUP (ORDER BY kolon)
  // DIKKAT: ParseFuncCall'a girerken '(' HENUZ YUTULMAMISTIR (ParsePrimary
  // yalnizca ismi okur, '(' kontrolu ParseFuncCall'da yapilir).
  if (FuncName = 'PERCENTILE_CONT') or (FuncName = 'PERCENTILE_DISC') or
     (FuncName = 'PERCENTILE') then
  begin
    if FuncName = 'PERCENTILE_DISC' then aggKind := akPercentileDisc
    else aggKind := akPercentileCont;
    aggN := TSqlAggNode.Create(aggKind);
    try
      // '(' ParsePrimary'da ZATEN yutuldu (bkz. ParsePrimary:1132)
      ExpectToken(T);
      if not VDbParseFloat(T, aggPct) or (aggPct < 0) or (aggPct > 1) then
        raise EVDbException.CreateFmt(ecSyntaxError,
          'PERCENTILE: 0..1 arasi oran bekleniyor, "%s" bulundu (%s)', [T, CurPos]);
      aggN.Pct := aggPct;
      Expect(')');
      // WITHIN GROUP (ORDER BY kolon [ASC|DESC])
      if PeekToken <> 'WITHIN' then
        raise EVDbException.CreateFmt(ecSyntaxError,
          'PERCENTILE: WITHIN GROUP bekleniyor (%s)', [CurPos]);
      NextToken(T); // WITHIN
      Expect('GROUP');
      Expect('(');
      Expect('ORDER');
      Expect('BY');
      aggN.Arg := ParseExpr;
      if PeekToken = 'DESC' then NextToken(T)
      else if PeekToken = 'ASC' then NextToken(T);
      Expect(')');
      Result := aggN;
      aggN := nil;
      Exit;
    except
      aggN.Free;
      raise;
    end;
  end;

  IsStar := False; IsDistinct := False; Arg := nil; filterNode := nil;
  if PeekToken = '*' then
  begin
    NextToken(T); IsStar := True;
  end
  else if PeekToken = 'DISTINCT' then
  begin
    NextToken(T); IsDistinct := True;
    Arg := ParseExpr;
  end
  else if PeekToken <> ')' then
  begin
    Arg := ParseExpr;
    // F-35: kullanicinin tanimladigi fonksiyonlar BIRDEN FAZLA arguman
    // alabilir: `SELECT topla(2, 3)`. Yerlesik fonksiyonlarin
    // degisken-argumanli bicimleri yukarida AYRI yollarda cozulur; buraya
    // virgulle devam eden tek yol kullanici fonksiyonudur.
    if PeekToken = ',' then
    begin
      Args := TList<TSqlExprNode>.Create;
      try
        Args.Add(Arg); Arg := nil;
        while PeekToken = ',' do
        begin
          NextToken(T);
          Args.Add(ParseExpr);
        end;
        Expect(')');
        Result := TSqlFuncCallNode.CreateList(FuncName, Args, IsStar, IsDistinct);
        TSqlFuncCallNode(Result).Filter := filterNode;
        filterNode := nil;   // sahiplik dugumde
      except
        Args.Free;
        Arg.Free;
        raise;
      end;
      Exit;
    end;
  end;
  Expect(')');
  // F-16: FILTER (WHERE ...) — aggregate'e satir filtresi.
  // Yalniz aggregate fonksiyonlarinda gecerli.
  if PeekToken = 'FILTER' then
  begin
    if not ((FuncName = 'COUNT') or (FuncName = 'SUM') or (FuncName = 'AVG') or
            (FuncName = 'MIN') or (FuncName = 'MAX')) then
      raise EVDbException.CreateFmt(ecSyntaxError,
        'FILTER yalnizca aggregate fonksiyonlarında kullanılabilir: %s', [FuncName]);
    NextToken(T);   // FILTER
    Expect('(');
    Expect('WHERE');
    filterNode := ParseExpr;
    Expect(')');
  end;
  // P5-WIN: pencere cagrisi mi?
  if PeekToken = 'OVER' then
  begin
    if IsDistinct then
      raise EVDbException.Create(ecSyntaxError,
        FuncName + '(DISTINCT ...) OVER ile kullanilamaz');
    // F-16: FILTER + OVER birlikte desteklenmez (pencere cercevesi ile
    // satir filtresi birlestirilemez).
    if filterNode <> nil then
    begin
      filterNode.Free; filterNode := nil;
      raise EVDbException.Create(ecSyntaxError,
        FuncName + '(...) FILTER (...) OVER ile kullanilamaz');
    end;
    try
      Result := ParseOver(FuncName, Arg, IsStar, 1, nil);
      Arg := nil; // sahiplik dugumde
      filterNode.Free; filterNode := nil;   // F-16: OVER ile birlikte desteklenmez
    except
      Arg.Free;
      raise;
    end;
    Exit;
  end;
  Result := TSqlFuncCallNode.Create(FuncName, Arg, IsStar, IsDistinct);
  // F-16: filtre dugumu sahipligi devralir (Arg'dan bagimsiz).
  TSqlFuncCallNode(Result).Filter := filterNode;
  filterNode := nil;
end;

function TVDbParser.ParseLagLead(const FuncName: string): TSqlExprNode;
var
  T: string;
  Arg, Def: TSqlExprNode;
  Off: Int64;
begin
  Arg := nil; Def := nil; Off := 1;
  try
    if PeekToken = ')' then
      raise EVDbException.Create(ecSyntaxError,
        FuncName + ' en az bir arguman ister');
    Arg := ParseExpr;
    if PeekToken = ',' then
    begin
      NextToken(T);
      ExpectToken(T);
      if not VDbParseInt(T, Off) or (Off < 0) or (Off > 1000000000) then
        raise EVDbException.Create(ecSyntaxError,
          FuncName + ' offseti dogal sayi olmali');
      if PeekToken = ',' then
      begin
        NextToken(T);
        Def := ParseExpr;
      end;
    end;
    Expect(')');
    if PeekToken <> 'OVER' then
      raise EVDbException.Create(ecSyntaxError,
        FuncName + ' yalnizca OVER ile kullanilabilir');
    Result := ParseOver(FuncName, Arg, False, Off, Def);
    Arg := nil; Def := nil; // sahiplik dugumde
  except
    Arg.Free;
    Def.Free;
    raise;
  end;
end;

function TVDbParser.ParseOver(const FuncName: string; Arg: TSqlExprNode;
  IsStar: Boolean; Off: Int64; Def: TSqlExprNode): TSqlWindowNode;
var
  T, U: string;
  E: TSqlExprNode;
  Item: TOrderItem;
begin
  // Giriste 'OVER' henuz yutulmadi. Arg/Def sahiplenmesi YALNIZ basarida
  // gecer (cagiran hata yolunda kendi kopyasini temizler).
  Result := TSqlWindowNode.Create(FuncName);
  try
    if (FuncName = 'ROW_NUMBER') or (FuncName = 'RANK') or
       (FuncName = 'DENSE_RANK') then
    begin
      if (Arg <> nil) or IsStar then
        raise EVDbException.Create(ecSyntaxError,
          FuncName + ' arguman almaz');
    end
    else if (FuncName = 'LAG') or (FuncName = 'LEAD') then
    begin
      if Arg = nil then
        raise EVDbException.Create(ecSyntaxError,
          FuncName + ' en az bir arguman ister');
    end
    else if not ((FuncName = 'COUNT') or (FuncName = 'SUM') or
            (FuncName = 'AVG') or (FuncName = 'MIN') or (FuncName = 'MAX')) then
      raise EVDbException.Create(ecSyntaxError,
        FuncName + ' OVER ile kullanilamaz');
    NextToken(T); // OVER
    Expect('(');
    if PeekToken = 'PARTITION' then
    begin
      NextToken(T);
      Expect('BY');
      repeat
        E := ParseExpr;
        Result.Partitions.Add(E);
        if PeekToken <> ',' then Break;
        NextToken(T);
      until False;
    end;
    if PeekToken = 'ORDER' then
    begin
      NextToken(T);
      Expect('BY');
      repeat
        Item.Expr := ParseExpr;
        Item.Desc := False;
        Item.Collate := '';
        Item.NullsPos := -1;   // F-10
        U := PeekToken;
        if U = 'COLLATE' then begin ParseCollate(Item); U := PeekToken; end;
        if U = 'DESC' then begin NextToken(T); Item.Desc := True; U := PeekToken; end
        else if U = 'ASC' then begin NextToken(T); U := PeekToken; end;
        if U = 'COLLATE' then begin ParseCollate(Item); U := PeekToken; end;
        if U = 'NULLS' then
        begin
          NextToken(T); U := PeekToken;
          if U = 'FIRST' then begin NextToken(T); Item.NullsPos := 0; end
          else if U = 'LAST' then begin NextToken(T); Item.NullsPos := 1; end
          else
            raise EVDbException.CreateFmt(ecSyntaxError,
              'NULLS sonrasi FIRST veya LAST bekleniyor, "%s" bulundu (%s)', [U, CurPos]);
        end;
        Result.OrderBys.Add(Item);
        if PeekToken <> ',' then Break;
        NextToken(T);
      until False;
    end;
    // 4.6: Pencere cercevesi (ROWS / RANGE) — basit parser acik
    if PeekToken = 'ROWS' then
    begin
      NextToken(T); Result.FrameType := 'ROWS';
    end
    else if PeekToken = 'RANGE' then
    begin NextToken(T); Result.FrameType := 'RANGE'; end;
    Expect(')');
    Result.Arg := Arg;
    Result.IsStar := IsStar;
    Result.Offset := Integer(Off);
    Result.Default := Def;
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParseCase: TSqlCaseNode;
var
  T: string;
  W: TSqlCaseWhen;
begin
  // Giriste 'CASE' yutuldu. Sade CASE (CASE x WHEN ...) ya da
  // aranan CASE (CASE WHEN ...). WHEN/THEN/ELSE/END sinir tasi olarak
  // ifade ayristirici tarafindan dogal durur (operator degiller).
  Result := TSqlCaseNode.Create(nil);
  try
    if PeekToken <> 'WHEN' then
      Result.Operand := ParseExpr;
    repeat
      Expect('WHEN');
      W.Cond := ParseExpr;
      W.Value := nil;
      Expect('THEN');
      W.Value := ParseExpr;
      Result.Whens.Add(W);
    until PeekToken <> 'WHEN';
    if PeekToken = 'ELSE' then
    begin
      NextToken(T);
      Result.ElseExpr := ParseExpr;
    end;
    Expect('END');
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParsePrimary: TSqlExprNode;
var T, U, T2, TableQ: string; SavePos, SaveIdx: Integer;
    iv: Int64; fv: Double; IsLit: Boolean;
begin
  SavePos := FPos; SaveIdx := FParamIdx;
  ExpectToken(T, IsLit);
  U := UpperCase(T);

  // String sabiti (tek tırnaklı metin veya ? parametresi)
  if IsLit then
    Exit(TSqlLiteralNode.CreateStr(T));

  // NULL
  if U = 'NULL' then Exit(TSqlLiteralNode.CreateNull);

  // Booelan sabitleri
  if U = 'TRUE'  then Exit(TSqlLiteralNode.CreateBool(True));
  if U = 'FALSE' then Exit(TSqlLiteralNode.CreateBool(False));

  // Sayı sabiti
  if IsDigit(T[1]) then
  begin
    if Pos('.', T) > 0 then
    begin
      if VDbParseFloat(T, fv) then Exit(TSqlLiteralNode.CreateFloat(fv));
    end
    else
    begin
      if VDbParseInt(T, iv) then Exit(TSqlLiteralNode.CreateInt(iv));
    end;
    Exit(TSqlLiteralNode.CreateStr(T)); // fallback
  end;

  // Negatif sayı önüne geldiyse (-1 gibi)
  if T = '-' then
  begin
    ExpectToken(T2);
    if IsDigit(T2[1]) then
    begin
      if Pos('.', T2) > 0 then
      begin
        if VDbParseFloat(T2, fv) then Exit(TSqlLiteralNode.CreateFloat(-fv));
      end
      else if VDbParseInt(T2, iv) then
        Exit(TSqlLiteralNode.CreateInt(-iv));
    end;
    FPos := SavePos; FParamIdx := SaveIdx;
    Exit(ParseUnaryExpr);
  end;

  // String sabiti (tırnaklı — NextToken zaten tırnaksız döndürür)
  // Tırnaklı stringler NextToken tarafından zaten işlenip T'ye atanır;
  // ayrıca burada normal identifier olmayan her şeyi string sayalım:
  // Eğer T tırnak içinden geliyorsa IsAlpha kontrolü fail eder.
  // Ama NextToken '' değilse ve ilk char sayı/alpha değilse string gibi davran.
  if (Length(T) >= 1) and (not IsAlpha(T[1])) and (not IsDigit(T[1]))
     and (T <> '(') and (T <> ')') and (T <> ',') then
  begin
    // Operatör vs. → geri sar
    FPos := SavePos; FParamIdx := SaveIdx;
    raise EVDbException.CreateFmt(ecSyntaxError, 'Beklenmedik token: "%s" (%s)', [T, CurPos]);
  end;

  // CASE ifadesi mi? (WHEN'den once gelmeli; yoksa 'case' kolon sayilir)
  if U = 'CASE' then Exit(ParseCase);

  // CAST(expr AS type)  — fonksiyon cagrisi sanilmaması için ONCE
  if U = 'CAST' then Exit(ParseCast);

  // Fonksiyon çağrısı mı?
  if IsAlpha(T[1]) and (PeekToken = '(') then
  begin
    NextToken(T2); // '('
    Exit(ParseFuncCall(UpperCase(T)));
  end;

  // Kolon referansı: ident veya tablo.kolon
  if IsAlpha(T[1]) then
  begin
    TableQ := '';
    if PeekToken = '.' then
    begin
      NextToken(T2); // '.'
      TableQ := T;
      ExpectToken(T);
    end;
    Exit(TSqlColumnRefNode.Create(T, TableQ));
  end;

  // Alt sorgu veya gruplanmış ifade: (...)
  if T = '(' then
  begin
    Inc(FDepth);
    try
      if FDepth > 256 then
        raise EVDbException.Create(ecSyntaxError, 'ifade derinligi cok fazla (max 256)');
      // P5-2: skaler alt sorgu ((SELECT ...) tek deger dondurur).
      if PeekToken = 'SELECT' then
      begin
        NextToken(T2); // SELECT
        Result := TSqlSubqueryNode.CreateScalar(ParseSelect);
        Expect(')');
        Exit;
      end;
      Result := ParseExpr;
      Expect(')');
      Exit;
    finally
      Dec(FDepth);
    end;
  end;

  // Daha önce NextToken tarafından string olarak okunan değer
  // (Tırnaklı stringler için — ilk karakter IsAlpha değil, sayı değil de string geldi)
  Exit(TSqlLiteralNode.CreateStr(T));
end;

{ ============================================================
  SELECT alt-parser'ları
  ============================================================ }

procedure TVDbParser.ParseSelectColumns(Stmt: TSqlSelectStmt);
var T, U: string; Item: TSelectColumnItem; SavePos, SaveIdx: Integer;
begin
  // SELECT * ?
  if PeekToken = '*' then
  begin
    NextToken(T); Exit; // Columns listesi boş = SELECT *
  end;

  while True do
  begin
    Item.Expr := ParseExpr;
    Item.Alias := '';
    // AS alias
    if PeekToken = 'AS' then
    begin
      NextToken(T); ExpectToken(Item.Alias);
    end
    else
    begin
      // örtük alias: FROM/WHERE/GROUP/ORDER/LIMIT/HAVING/UNION/EXCEPT/INTERSECT
      // /QUALIFY/FETCH/OFFSET/JOIN/','/';'/')' değilse
      SavePos := FPos; SaveIdx := FParamIdx;
      if NextToken(T) then
      begin
        U := UpperCase(T);
        if not (U = 'FROM') and not (U = 'WHERE') and not (U = 'GROUP') and
           not (U = 'ORDER') and not (U = 'LIMIT') and not (U = 'HAVING') and
           not (U = 'UNION') and not (U = 'EXCEPT') and not (U = 'INTERSECT') and
           not (U = 'QUALIFY') and            // F-09
           not (U = 'FETCH') and              // F-08
           not (U = 'OFFSET') and not (U = 'JOIN') and
           not (U = ',') and not (U = ';') and not (U = ')') then
          Item.Alias := T   // örtük alias
        else
          begin FPos := SavePos; FParamIdx := SaveIdx; end;
      end;
    end;
    Stmt.Columns.Add(Item);

    if PeekToken = ',' then begin NextToken(T); Continue; end;
    Break;
  end;
end;

procedure TVDbParser.ParseFromClause(Stmt: TSqlSelectStmt);
var T, U: string; SavePos, SaveIdx: Integer;
begin
  ExpectToken(T); Stmt.FromTable := VDbNorm(T);

  // 2026-10-06 AS OF: "FROM t AS OF ..." (alias ONCESI)
  if (PeekToken = 'AS') and (PeekToken2 = 'OF') then
  begin
    ExpectToken(T);                 // 'AS' yut
    ParseAsOfTail(Stmt);
    Exit;
  end;

  // Alias kontrolü
  SavePos := FPos; SaveIdx := FParamIdx;
  if NextToken(T) then
  begin
    U := UpperCase(T);
    if (U = 'AS') then ExpectToken(Stmt.FromAlias)
    else if not (U = 'WHERE') and not (U = 'INNER') and not (U = 'LEFT') and
            not (U = 'RIGHT') and not (U = 'FULL') and not (U = 'OUTER') and
            not (U = 'JOIN')  and not (U = 'GROUP') and not (U = 'ORDER') and
            not (U = 'LIMIT') and not (U = 'HAVING') and not (U = 'UNION') and
            not (U = 'EXCEPT') and not (U = 'INTERSECT') and
            not (U = 'CROSS') and
            // R-03: "INSERT ... SELECT ... ON CONFLICT" cumlesinde ON,
            // tablo alias'i sanilip yutuluyordu; boylece ON CONFLICT
            // yerine yalniz "CONFLICT" kaldi ve "anlasilamayan ek:
            // CONFLICT" hatasi verildi.
            not (U = 'ON') and
            not (U = 'RETURNING') and
            // F-27/F-29: NATURAL / LATERAL JOIN — alias degil, JOIN anahtari
            not (U = 'NATURAL') and not (U = 'LATERAL') and
            not (U = 'QUALIFY') and   // F-09
            not (U = 'FETCH') and     // F-08
            not (U = 'OFFSET') and
            not (U = ';') and not (U = ')') then
      Stmt.FromAlias := T
    else
      begin FPos := SavePos; FParamIdx := SaveIdx; end;
  end;

  // AS OF: "FROM t x AS OF ..." / "FROM t AS x AS OF ..." (alias SONRASI)
  if (Stmt.AsOf = saoNone) and (PeekToken = 'AS') and (PeekToken2 = 'OF') then
  begin
    ExpectToken(T);                 // 'AS' yut
    ParseAsOfTail(Stmt);
  end;
end;

procedure TVDbParser.ParseAsOfTail(Stmt: TSqlSelectStmt);
// AS OF kuyrugu. 'AS' zaten yutulmus durumda gelir.
//   SEQUENCE n     -> cozumleme executor'da (WAL kayit indeksi)
//   VERSION x      -> birakilir, executor ecUnsupported verir
//   TIMESTAMP '...'-> birakilir, executor ecUnsupported verir
var
  T, U: string;
  q: QWord;
begin
  Expect('OF');
  ExpectToken(T); U := UpperCase(T);
  if U = 'SEQUENCE' then
  begin
    ExpectToken(T);
    if not TryStrToQWord(T, q) then
      raise EVDbException.CreateFmt(ecSyntaxError,
        'AS OF SEQUENCE: gecerli bir sayi bekleniyor, "%s" bulundu (%s)',
        [T, CurPos]);
    Stmt.AsOf := saoSequence;
    Stmt.AsOfValue := q;
  end
  else if (U = 'VERSION') or (U = 'TIMESTAMP') then
  begin
    if U = 'VERSION' then Stmt.AsOf := saoVersion
    else Stmt.AsOf := saoTimestamp;
    ExpectToken(T);
    Stmt.AsOfText := T;
    if Stmt.AsOfText = '' then
      raise EVDbException.CreateFmt(ecSyntaxError,
        'AS OF %s: deger bos olamaz (%s)', [U, CurPos]);
  end
  else
    raise EVDbException.CreateFmt(ecSyntaxError,
      'AS OF sonrasi SEQUENCE, VERSION veya TIMESTAMP bekleniyor, "%s" bulundu (%s)',
      [T, CurPos]);
end;

procedure TVDbParser.ParseJoinClause(var JC: TJoinClause; AllowNoOn: Boolean;
  out ExitCols: TStrArray);
var T, U: string; SavePos, SaveIdx: Integer; usingList: TStringList; i: Integer;
begin
  JC.OnCondition := nil;
  ExitCols := nil;
  // DIKKAT: JC.Natural ve JC.UsingCols burada SIFIRLANMAZ.
  //  - Natural: JOIN dongusu bu bayragi ONCE set eder; sifirlanirsa
  //    "ON'suz JOIN hata vermeli" regresyonu olusur.
  //  - UsingCols: dinamik diziyi bir RECORD'u var ile gecirip
  //    SetLength uygulamak FPC'de ayni kopyayi bozabiliyor; ayrica
  //    NATURAL/USING ayni klamada kullanilamaz, sonra biri sifirlarsa
  //    digerinin durumu bozulur. Bunun yerine USING ayrimi asagida
  //    yalnizca kendi yolunda yapilir.
  if PeekToken = 'JOIN' then NextToken(T);
  // Tablo adi
  ExpectToken(T); JC.Table := VDbNorm(T);
  JC.Alias := '';
  // Alias
  if PeekToken = 'AS' then begin NextToken(T); ExpectToken(JC.Alias); end
  else
  begin
    SavePos := FPos; SaveIdx := FParamIdx;
    if NextToken(T) then
    begin
      // JOIN anahtarlari alias degildir (zincirde sonraki JOIN gelir).
      // ORDER/GROUP/HAVING/LIMIT/UNION/QUALIFY/FETCH de alias DEGILDIR:
      // aksi halde "FROM a JOIN b ORDER BY x" yaziminda 'ORDER' alias
      // olur ve 'BY' artik token olarak kalir ("anlasilamayan ek: BY").
      U := UpperCase(T);
      if (U = 'ON') or (U = 'JOIN') or (U = 'INNER') or (U = 'LEFT') or
         (U = 'RIGHT') or (U = 'FULL') or (U = 'OUTER') or (U = 'CROSS') or
         (U = 'USING') or (U = 'NATURAL') or (U = 'WHERE') or
         (U = 'GROUP') or (U = 'ORDER') or (U = 'HAVING') or
         (U = 'LIMIT') or (U = 'OFFSET') or (U = 'UNION') or
         (U = 'EXCEPT') or (U = 'INTERSECT') or (U = 'QUALIFY') or
         (U = 'FETCH') or (U = ';') or (U = ')') then
      begin FPos := SavePos; FParamIdx := SaveIdx; end
      else JC.Alias := T;
    end;
  end;
  // F-27/F-28: NATURAL ve USING. Ikisi de ON'in yerine gecer.
  if PeekToken = 'USING' then
  begin
    NextToken(T);
    Expect('(');
    usingList := TStringList.Create;
    try
      repeat
        ExpectToken(T);
        usingList.Add(VDbNorm(T));
        if PeekToken <> ',' then Break;
        NextToken(T);
      until False;
      Expect(')');
    ExitCols := nil;
      SetLength(ExitCols, usingList.Count);
      for i := 0 to usingList.Count - 1 do
        ExitCols[i] := usingList[i];
    finally
      usingList.Free;
    end;
    // USING listesi TJoinClause'a DEGIL, ayri bir kayda yazilir
    // (bkz. TJoinUsingRec yorumu).
    Exit;
  end;
  // ON kosulu. 4.1 CROSS JOIN: CROSS'ta opsiyoneldir - ON yoksa kosul
  // her zaman dogru sayilir (EvalBool(nil)=True) = cartesius carpani;
  // ON yazildiysa INNER gibi filtre uygulanir. Diger turlerde
  // (INNER/LEFT/RIGHT/FULL) ON hala zorunludur: ON'suz JOIN hata verir.
  if PeekToken = 'ON' then
  begin
    NextToken(T);
    JC.OnCondition := ParseExpr;
  end
  else if not AllowNoOn then
    Expect('ON');   // -> '"ON" bekleniyor, ...' ecSyntaxError
end;

procedure TVDbParser.ParseGroupBy(Stmt: TSqlSelectStmt);
var T, T2: string;
begin
  // GROUP zaten yutuldu
  Expect('BY');
  while True do
  begin
    // 4.2 (06.10.2026): nitelemeli yazim da okunur ('m.sehir'):
    // tokenizer noktayi AYRI token verir (ifadedeki kolon referansi
    // parseri birlestirir); burada da ayni birlestirme yapilir.
    // Eskiden yalniz ilk token ('m') aliniyordu: kalan '.sehir' sondan
    // "anlasilamayan ek" hatasi ya da (eski birebir cozumlemede)
    // sessizce tek gruba dusme sonucunu veriyordu.
    ExpectToken(T);
    while PeekToken = '.' do
    begin
      NextToken(T2);                    // '.' yut
      ExpectToken(T2);                  // kolon adi (yoksa hata)
      T := T + '.' + T2;
    end;
    Stmt.GroupByCols.Add(VDbNorm(T));
    if PeekToken = ',' then begin NextToken(T); Continue; end;
    Break;
  end;
  // HAVING
  if PeekToken = 'HAVING' then
  begin
    NextToken(T);
    Stmt.HavingClause := ParseExpr;
  end;
end;

procedure TVDbParser.ParseOrderBy(Stmt: TSqlSelectStmt);
var T, U: string; Item: TOrderItem;
begin
  // ORDER zaten yutuldu
  Expect('BY');
  while True do
  begin
    Item.Expr := ParseExpr;
    Item.Desc := False;
    Item.Collate := '';
    Item.NullsPos := -1;   // F-10: -1 = motor varsayilani
    // Sira serbest: [COLLATE x] [ASC|DESC] [COLLATE x] [NULLS FIRST|LAST]
    U := PeekToken;
    if U = 'COLLATE' then begin ParseCollate(Item); U := PeekToken; end;
    if U = 'DESC' then begin NextToken(T); Item.Desc := True; U := PeekToken; end
    else if U = 'ASC' then begin NextToken(T); U := PeekToken; end;
    if U = 'COLLATE' then begin ParseCollate(Item); U := PeekToken; end;
    // F-10: NULLS FIRST / NULLS LAST
    if U = 'NULLS' then
    begin
      NextToken(T);
      U := PeekToken;
      if U = 'FIRST' then begin NextToken(T); Item.NullsPos := 0; end
      else if U = 'LAST' then begin NextToken(T); Item.NullsPos := 1; end
      else
        raise EVDbException.CreateFmt(ecSyntaxError,
          'NULLS sonrasi FIRST veya LAST bekleniyor, "%s" bulundu (%s)', [U, CurPos]);
      U := PeekToken;
    end;
    Stmt.OrderBy.Add(Item);
    if PeekToken = ',' then begin NextToken(T); Continue; end;
    Break;
  end;
end;

function TVDbParser.ReadCollName: string;
{ R-20: COLLATE adi okunur. Standart tokenizer `en-US` yaziminda
  '-' karakterini OPERATOR olarak verir ("en", "-", "US"). Burada ad
  harf/rakam + '-' karakterlerinden olusur ve BOSLUKTA biter.
  Tirnakli yazim ("tr-TR-u-kn-ks") normal token olarak gelir. }
var
  S: string;
begin
  Result := '';
  SkipWS;   // DIKKAT: once bosluk atlanir, SONRA tirnak kontrolu yapilir
  if (FPos <= FLen) and (FSql[FPos] = '"') then
  begin
    NextToken(Result);
    Exit;
  end;
  while (FPos <= FLen) and (FSql[FPos] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) do
  begin
    S := S + FSql[FPos];
    Inc(FPos);
  end;
  Result := S;
end;

procedure TVDbParser.ParseCollate(var Item: TOrderItem);
{ R-20: `COLLATE <ad>`. DIL ETIKETI tasinan motor: sabit bir dil listesi
  YOKTUR. Locale kismi "tr", "de", "ja", "he-IL", "zh-Hans" gibi HEPPSI
  calisir; alfabe dilden ya da kod noktasi araligindan secilir.
      C | POSIX | BINARY          ham kod noktasi sirasi
      tr | tr-TR | TR-TR          Turkce alfabetik, i/ı AYRI
      de | fr | ru | el | ar | he dile ozgu alfabetik
      tr-TR-u-kn-ks               vurgu DUYARLI
      tr-TR-u-kn                  vurgu duyarsiz
      tr-TR-u-kc                  buyuk/kucuk duyarli
  Tirnakli yazim da kabul edilir: COLLATE "tr-TR-u-kn-ks". }
var
  T: string;
  N: string;
  LangP: TVDbLang;
begin
  Item.Collate := '';
  if PeekToken <> 'COLLATE' then Exit;
  NextToken(T); // COLLATE
  T := ReadCollName;
  N := UpperCase(T);
  // Tirnakli yazim: "tr-TR-u-kn-ks" -> ReadCollName soyuyor.
  if not VDbLangProfile(N, LangP) then
    raise EVDbException.CreateFmt(ecSyntaxError,
      'gecersiz COLLATE: "%s" (bos olamaz)', [T]);
  Item.Collate := VDbCollationName(LangP);
end;

{ ============================================================
  SELECT kuyrugu: ORDER BY / LIMIT / OFFSET
  F1-12: Bu blok ayri bir procedure oldu; set-op sonrasi kuyruk
  DIS cumleye yazilabilsin diye. F1-18: bozuk/negatif deger sessizce
  yutulmaz.
  ============================================================ }
procedure TVDbParser.ParseSelectTail(Stmt: TSqlSelectStmt);
var
  T: string;
  limIv, offIv: Int64;
begin
  // ORDER BY
  if PeekToken = 'ORDER' then begin NextToken(T); ParseOrderBy(Stmt); end;

  // LIMIT / OFFSET
  if PeekToken = 'LIMIT' then
  begin
    NextToken(T); ExpectToken(T);
    if not VDbParseInt(T, limIv) or (limIv < 0) then
      raise EVDbException.CreateFmt(ecSyntaxError, 'LIMIT: dogal sayi bekleniyor, "%s" bulundu (%s)', [T, CurPos]);
    if limIv > 2000000 then
      raise EVDbException.CreateFmt(ecLimit, 'LIMIT cok buyuk (max 2000000): %d', [limIv]);
    Stmt.LimitVal := Integer(limIv);
    if PeekToken = 'OFFSET' then
    begin
      NextToken(T); ExpectToken(T);
      if not VDbParseInt(T, limIv) or (limIv < 0) then
        raise EVDbException.CreateFmt(ecSyntaxError, 'OFFSET: dogal sayi bekleniyor, "%s" bulundu (%s)', [T, CurPos]);
      Stmt.OffsetVal := Integer(limIv);
    end;
  end;
  if PeekToken = 'OFFSET' then
  begin
    NextToken(T); ExpectToken(T);
    if not VDbParseInt(T, offIv) or (offIv < 0) then
      raise EVDbException.CreateFmt(ecSyntaxError, 'OFFSET: dogal sayi bekleniyor, "%s" bulundu (%s)', [T, CurPos]);
    Stmt.OffsetVal := Integer(offIv);
    // F-08: OFFSET n ROW / OFFSET n ROWS (SQL:2008 yazimi)
    if PeekToken = 'ROW' then NextToken(T)
    else if PeekToken = 'ROWS' then NextToken(T);
    // F1-10: "OFFSET n LIMIT m" yazimi da gecerli (LIMIT n OFFSET m ile
    // ayni). Once yalniz LIMIT ... OFFSET ... kabul ediliyordu.
    if PeekToken = 'LIMIT' then
    begin
      NextToken(T); ExpectToken(T);
      if not VDbParseInt(T, limIv) or (limIv < 0) then
        raise EVDbException.CreateFmt(ecSyntaxError, 'LIMIT: dogal sayi bekleniyor, "%s" bulundu (%s)', [T, CurPos]);
      if limIv > 2000000 then
        raise EVDbException.CreateFmt(ecLimit, 'LIMIT cok buyuk (max 2000000): %d', [limIv]);
      Stmt.LimitVal := Integer(limIv);
    end;
  end;

  // F-08 (SQL:2008): FETCH { FIRST | NEXT } [ n ] { ROW | ROWS } { ONLY }
  // LIMIT'in standart yazimi; ayni LimitVal degerini yazar.
  if PeekToken = 'FETCH' then
  begin
    NextToken(T);
    if (PeekToken <> 'FIRST') and (PeekToken <> 'NEXT') then
      raise EVDbException.CreateFmt(ecSyntaxError,
        'FETCH sonrasi FIRST veya NEXT bekleniyor, "%s" bulundu (%s)', [PeekToken, CurPos]);
    NextToken(T);
    limIv := 1;   // FETCH NEXT ROWS ONLY (n yoksa 1)
    // n yoksa: dogrudan ROW/ROWS gelir. n varsa: once sayi.
    if (PeekToken <> 'ROW') and (PeekToken <> 'ROWS') then
    begin
      ExpectToken(T);
      if not VDbParseInt(T, limIv) or (limIv < 0) then
        raise EVDbException.CreateFmt(ecSyntaxError,
          'FETCH: dogal sayi bekleniyor, "%s" bulundu (%s)', [T, CurPos]);
    end;
    // ROW | ROWS (sayi yazilmadiysa burada beklenir)
    if PeekToken = 'ROW' then NextToken(T)
    else if PeekToken = 'ROWS' then NextToken(T)
    else
      raise EVDbException.CreateFmt(ecSyntaxError,
        'FETCH sonrasi ROW/ROWS bekleniyor, "%s" bulundu (%s)', [PeekToken, CurPos]);
    // WITH TIES (desteklenmiyor — bag ile kirpilma gerekir)
    if PeekToken = 'WITH' then
    begin
      NextToken(T); Expect('TIES');
      raise EVDbException.Create(ecUnsupported,
        'FETCH WITH TIES desteklenmiyor (LUSTE kullanin)');
    end;
    if PeekToken <> 'ONLY' then
      raise EVDbException.CreateFmt(ecSyntaxError,
        'FETCH sonrasi ONLY bekleniyor, "%s" bulundu (%s)', [PeekToken, CurPos]);
    NextToken(T);
    if limIv > 2000000 then
      raise EVDbException.CreateFmt(ecLimit, 'FETCH cok buyuk (max 2000000): %d', [limIv]);
    Stmt.LimitVal := Integer(limIv);
    // FETCH ... OFFSET n [ROW|ROWS]
    if PeekToken = 'OFFSET' then
    begin
      NextToken(T); ExpectToken(T);
      if not VDbParseInt(T, offIv) or (offIv < 0) then
        raise EVDbException.CreateFmt(ecSyntaxError,
          'OFFSET: dogal sayi bekleniyor, "%s" bulundu (%s)', [T, CurPos]);
      Stmt.OffsetVal := Integer(offIv);
      if PeekToken = 'ROW' then NextToken(T)
      else if PeekToken = 'ROWS' then NextToken(T);
    end;
  end;

  // F-41: SELECT ... FOR UPDATE [NOWAIT]
  if PeekToken = 'FOR' then
  begin
    NextToken(T);
    if PeekToken = 'UPDATE' then
    begin
      NextToken(T);
      Stmt.ForUpdate := True;
      // NOWAIT/SKIP LOCKED: motor beklemedigi icin NOWAIT kabul edilir;
      // SKIP LOCKED su an desteklenmez (acikca reddedilir).
      if PeekToken = 'NOWAIT' then NextToken(T)
      else if PeekToken = 'SKIP' then
      begin
        NextToken(T); Expect('LOCKED');
        raise EVDbException.Create(ecUnsupported,
          'SKIP LOCKED desteklenmiyor; NOWAIT kullanin');
      end;
    end
    else
      raise EVDbException.CreateFmt(ecSyntaxError,
        'FOR sonrasi UPDATE bekleniyor, "%s" bulundu (%s)', [PeekToken, CurPos]);
  end;
end;

{ ============================================================
  SELECT cümlesi
  ============================================================ }

// SET OP: UNION [ALL] / EXCEPT / INTERSECT
// Ayri metoda cikarildi (R-10): FROM'suz SELECT'ler de birlestirme
// yapabilir (`SELECT 1 UNION ALL SELECT 2`). Once bu blok ParseSelect
// SONUNDA duruyordu ve FROM'suz yol 2016'da Exit ile cikip hic buraya
// gelmedigi icin UNION yol boyunca yemiyordu.
procedure TVDbParser.ParseSetOps(Stmt: TSqlSelectStmt);
var T, U: string;
begin
  U := PeekToken;
  if (U <> 'UNION') and (U <> 'EXCEPT') and (U <> 'INTERSECT') then Exit;
  NextToken(T);
  if U = 'UNION' then
  begin
    if PeekToken = 'ALL' then begin NextToken(T); Stmt.SetOp := sokUnionAll; end
    else Stmt.SetOp := sokUnion;
  end
  else if U = 'EXCEPT' then Stmt.SetOp := sokExcept
  else Stmt.SetOp := sokIntersect;

  // Sag taraf SELECT: kuyrugu bastirilir, cunku ORDER BY / LIMIT /
  // OFFSET birlestirme SONRASINA uygulanmali (F1-12).
  FSuppressTail := True;
  try
    Expect('SELECT');
    Stmt.RightSelect := ParseSelect;
  finally
    FSuppressTail := False;
  end;

  // Dis kuyruk (birlestirme sonrasi)
  ParseSelectTail(Stmt);
end;

function TVDbParser.ParseSelect: TSqlSelectStmt;
var T, U: string;
    limIv, offIv: Int64;
    Jc: TJoinClause;
    IsCross: Boolean;
    IsNat: Boolean;   // F-27: NATURAL bayragi ParseJoinClause'a ONCE set edilir
    UsingCols: TStrArray;   // F-28: bir JOIN'in USING listesi
begin
  Result := TSqlSelectStmt.Create;
  try
    // DISTINCT
    if PeekToken = 'DISTINCT' then begin NextToken(T); Result.IsDistinct := True; end;

    // Kolon listesi
    ParseSelectColumns(Result);

    // FROM
    if PeekToken <> 'FROM' then
    begin
      // FROM'suz SELECT: sabit ifadeler (SELECT 1, 'abc')
      Result.LimitVal := -1; Result.OffsetVal := 0;
      // R-10: SET OP yine de olabilir -> `SELECT 1 UNION ALL SELECT 2`.
      // DIKKAT: onceki kod burada dogrudan Exit idi ve SET OP bloguna
      // hic ulasilmadigi icin UNION ayristirilamiyordu.
      if not FSuppressTail then
        ParseSelectTail(Result);
      ParseSetOps(Result);
      Exit;
    end;
    NextToken(T); // FROM yut

    ParseFromClause(Result);

    // JOIN zinciri (P5-1: 2+ tablo, sinir yok; P5-RF: RIGHT/FULL + OUTER;
    // 4.1: CROSS JOIN - ON'suz cartesius, ON yazildiysa INNER gibi).
    // Ilk JOIN Join alanina, sonrakiler MoreJoins listesine
    // (soldan derine uygulanir).
    U := PeekToken;
    while (U = 'INNER') or (U = 'LEFT') or (U = 'RIGHT') or
          (U = 'FULL') or (U = 'JOIN') or (U = 'CROSS') or
          (U = 'NATURAL') or (U = 'LATERAL') do
    begin
      IsCross := False;
      // DIKKAT: Jc yerel record değişkenidir ve FPC onu DONGULER ARASI
      // sifirlamaz. Onceki JOIN'de set edilen Natural/JoinType/OnCondition
      // sonraki JOIN'e SIZAR ve tum zinciri bozar. Her turda baslangic
      // durumu elle yazilir.
      Jc.JoinType := jtInner;
      Jc.Natural := False;
      Jc.LateralIdx := -1;
      Jc.OnCondition := nil;
      Jc.Table := '';
      Jc.Alias := '';
      if U = 'CROSS' then begin NextToken(T); Jc.JoinType := jtInner; IsCross := True; end
// F-29: [INNER|LEFT|RIGHT|FULL] [OUTER] LATERAL (subquery|table) [alias] [ON ...]
      // Sol taraf herhangi bir turlen JOIN turunde LATERAL olabilir; bu
      // yuzden ONCESI turlenir, sonra tip belirlenir.
      //
      // DIKKAT 1: `LEFT JOIN LATERAL` onceki kodda YAKALANMIYORDU (yalniz
      // JOIN/INNER/LATERAL bakiliyordu); normal JOIN yolu LATERAL'i tablo
      // adi sanip "ON bekleniyor, SELECT bulundu" hatasi veriyordu.
      // DIKKAT 2: parantezli alt sorguda acilan `(` KAPANMIYORDU; akis
      // ")"de kaliyor ve cumle sonunda "anlasilamayan ek: ." hatasi veriyordu.
      else if (U = 'LATERAL') or
              ((U = 'JOIN') and (PeekToken2 = 'LATERAL')) or
              ((U = 'INNER') and (PeekToken2 = 'LATERAL')) or
              ((U = 'LEFT') and ((PeekToken2 = 'LATERAL') or
                                 ((PeekToken2 = 'JOIN') and (PeekToken3 = 'LATERAL')))) or
              ((U = 'RIGHT') and ((PeekToken2 = 'LATERAL') or
                                  ((PeekToken2 = 'JOIN') and (PeekToken3 = 'LATERAL')))) or
              ((U = 'FULL') and ((PeekToken2 = 'LATERAL') or
                                 ((PeekToken2 = 'JOIN') and (PeekToken3 = 'LATERAL')))) then
      begin
        // 1) Birincil tipi (LEFT/RIGHT/FULL/INNER) ve ara JOIN'i yut
        if U = 'LEFT' then begin NextToken(T); Jc.JoinType := jtLeft; end
        else if U = 'RIGHT' then begin NextToken(T); Jc.JoinType := jtRight; end
        else if U = 'FULL' then begin NextToken(T); Jc.JoinType := jtFull; end
        else if U = 'INNER' then NextToken(T);
        if PeekToken = 'JOIN' then NextToken(T);
        // 2) [OUTER] opsiyonel bayragi
        if PeekToken = 'OUTER' then NextToken(T);
        // 3) LATERAL
        Expect('LATERAL');
        Jc.LateralIdx := -1;
        // 4) Govde: (SELECT ...) | SELECT ... | tablo_adi
        if PeekToken = '(' then
        begin
          NextToken(T);   // (
          if PeekToken = 'SELECT' then
          begin
            // DIKKAT: ParseSelect SELECT anahtarini KENDISI tuketmez
            // (Parse ana kolunda o yutulur). Burada ONCE yutuyoruz;
            // yutulmazsa "SELECT" kolon sanilir ve akis "d.ad" icinde
            // kalir -> "anlasilamayan ek: ad".
            Expect('SELECT');
            // Alt sorgu: TSqlSelectStmt.LateralSubs listesine konur; JOIN
            // kaydi yalnizca INDIS tasir (bkz. TJoinClause yorumu).
            Jc.LateralIdx := Result.LateralSubs.Count;
            Result.LateralSubs.Add(ParseSelect);
            // DIKKAT: kapanis parantezi bazi yollarda ParseSelect
            // tarafindan zaten tuketilmis olabilir; zorunlu degil.
            if PeekToken = ')' then NextToken(T);
          end
          else
            Jc.LateralIdx := -99;
        end
        else if PeekToken = 'SELECT' then
        begin
          Expect('SELECT');   // ParseSelect SELECT'i kendisi yutmaz
          Jc.LateralIdx := Result.LateralSubs.Count;
          Result.LateralSubs.Add(ParseSelect);
        end
        else
        begin
          ExpectToken(T); Jc.Table := VDbNorm(T);
          Jc.LateralIdx := -2;   // -2 = LATERAL tablo
          // LATERAL tablo icin de alias (AS'li veya ortuk) ON'DEN once gelir.
          if PeekToken = 'AS' then
          begin
            NextToken(T);
            ExpectToken(Jc.Alias);
          end
          else if (PeekToken <> 'ON') and (PeekToken <> 'WHERE') and
                  (PeekToken <> 'JOIN') and (PeekToken <> 'INNER') and
                  (PeekToken <> 'LEFT') and (PeekToken <> 'RIGHT') and
                  (PeekToken <> 'FULL') and (PeekToken <> 'CROSS') and
                  (PeekToken <> 'NATURAL') and (PeekToken <> ';') and
                  (PeekToken <> '') then
            ExpectToken(Jc.Alias);
        end;
        // Alt sorgu alias'i ON'den sonra da gelebilir (SQL standardi).
        if (Jc.LateralIdx >= 0) and (PeekToken <> 'ON') and
           (PeekToken <> 'WHERE') and (PeekToken <> 'GROUP') and
           (PeekToken <> 'ORDER') and (PeekToken <> 'LIMIT') and
           (PeekToken <> 'HAVING') and (PeekToken <> 'JOIN') and
           (PeekToken <> 'INNER') and (PeekToken <> 'LEFT') and
           (PeekToken <> 'RIGHT') and (PeekToken <> 'FULL') and
           (PeekToken <> 'CROSS') and (PeekToken <> 'NATURAL') and
           (PeekToken <> 'LATERAL') and (PeekToken <> ';') then
        begin
          if PeekToken = 'AS' then NextToken(T);
          ExpectToken(Jc.Alias);
        end;
        if PeekToken = 'ON' then
        begin
          NextToken(T);
          Jc.OnCondition := ParseExpr;
        end;
        if not Result.HasJoin then
        begin
          Result.HasJoin := True;
          Result.Join := Jc;
        end
        else
          Result.MoreJoins.Add(Jc);
        U := PeekToken;
        Continue;
      end
      // F-27: NATURAL [LEFT|RIGHT|FULL] JOIN — ON yazilmaz.
      else if U = 'NATURAL' then
      begin
        NextToken(T);
        Jc.JoinType := jtInner;
        Jc.Natural := True;
        // NATURAL INNER JOIN her zaman; sol taraf varsayilandir.
        if PeekToken = 'LEFT' then begin NextToken(T); Jc.JoinType := jtLeft; end
        else if PeekToken = 'RIGHT' then begin NextToken(T); Jc.JoinType := jtRight; end
        else if PeekToken = 'FULL' then begin NextToken(T); Jc.JoinType := jtFull; end;
      end
      else if U = 'INNER' then begin NextToken(T); Jc.JoinType := jtInner; end
      else if U = 'LEFT' then begin NextToken(T); Jc.JoinType := jtLeft; end
      else if U = 'RIGHT' then begin NextToken(T); Jc.JoinType := jtRight; end
      else if U = 'FULL' then begin NextToken(T); Jc.JoinType := jtFull; end
      else begin NextToken(T); Jc.JoinType := jtInner; end;
      // OUTER opsiyonel: LEFT/RIGHT/FULL [OUTER] JOIN. CROSS'ta gecersizdir.
      if IsCross and (PeekToken = 'OUTER') then
        raise EVDbException.Create(ecSyntaxError,
          'CROSS JOIN ile OUTER kullanilamaz (CROSS, INNER ile aynidir)');
      if (not IsCross) and (PeekToken = 'OUTER') then NextToken(T);
      // NATURAL ... JOIN: ON bekleme, esitlik executor'da cozulur.
      IsNat := Jc.Natural;
      ParseJoinClause(Jc, IsCross or IsNat, UsingCols);
      // F-28: USING listesi ayri kayda yazilir (MoreJoins ile ayni sira).
      if UsingCols <> nil then
        Result.JoinUsing.Add(TJoinUsingRec(UsingCols));
      if not Result.HasJoin then
      begin
        Result.HasJoin := True;
        Result.Join := Jc;
      end
      else
        Result.MoreJoins.Add(Jc);
      U := PeekToken;
    end;

    // WHERE
    if PeekToken = 'WHERE' then begin NextToken(T); Result.WhereClause := ParseExpr; end;

    // GROUP BY
    if PeekToken = 'GROUP' then begin NextToken(T); ParseGroupBy(Result); end;

    // F-09: QUALIFY — pencere sonrasi filtre (GROUP BY'dan SONRA, ORDER BY'dan
    // ONCE). ParseGroupBy icinde DEGIL: QUALIFY'siz GROUP BY da olabilir.
    if PeekToken = 'QUALIFY' then
    begin
      NextToken(T);
      Result.QualifyClause := ParseExpr;
    end;

    // ORDER BY / LIMIT / OFFSET
    if not FSuppressTail then
      ParseSelectTail(Result);

    // SET OP: UNION [ALL] / EXCEPT / INTERSECT
    ParseSetOps(Result);

  except
    Result.Free;
    raise;
  end;
end;

{ ============================================================
  INSERT
  ============================================================ }

function TVDbParser.ParseInsert: TSqlInsertStmt;
var T: string; i: Integer; Row: TInsertValuesRow; Expr: TSqlExprNode;
begin
  Result := TSqlInsertStmt.Create;
  try
    Expect('INTO');
    ExpectToken(T); Result.Table := VDbNorm(T);

    // Kolon listesi opsiyonel: INSERT INTO t VALUES(...) veya INSERT INTO t () ...
    if PeekToken = '(' then
    begin
      NextToken(T);
      if PeekToken = ')' then
      begin
        NextToken(T); // boş kolon listesi
      end
      else
      begin
        i := 0;
        while True do
        begin
          ExpectToken(T);
          SetLength(Result.Columns, i + 1);
          Result.Columns[i] := VDbNorm(T);
          Inc(i);
          if PeekToken = ')' then begin NextToken(T); Break; end;
          Expect(',');
        end;
      end;
    end;

    // VALUES veya DEFAULT VALUES
    T := UpperCase(PeekToken);
    if T = 'DEFAULT' then
    begin
      while True do
      begin
        NextToken(T);
        Expect('VALUES');
        Row := TList<TSqlExprNode>.Create;
        Result.ValuesRows.Add(Row);
        if PeekToken = ',' then
        begin
          NextToken(T);
          if UpperCase(PeekToken) = 'DEFAULT' then Continue
          else raise EVDbException.CreateFmt(ecSyntaxError, 'DEFAULT VALUES bekleniyor, "%s" bulundu (%s)', [PeekToken, CurPos]);
        end;
        Break;
      end;
    end
    else if T = 'VALUES' then
    begin
      NextToken(T);
      // Çoklu satır: VALUES (a,b), (c,d)
      while True do
      begin
        Expect('(');
        Row := TList<TSqlExprNode>.Create;
        if PeekToken = ')' then
        begin
          NextToken(T); // boş VALUES ()
        end
        else
        begin
          while True do
          begin
            Expr := ParseExpr;
            Row.Add(Expr);
            if PeekToken = ')' then begin NextToken(T); Break; end;
            Expect(',');
          end;
        end;
        Result.ValuesRows.Add(Row);
        if PeekToken = ',' then begin NextToken(T); Continue; end;
        Break;
      end;
    end
    else if T = 'SELECT' then
    begin
      NextToken(T);
      Result.SelectSrc := ParseSelect;
    end
    else
      raise EVDbException.CreateFmt(ecSyntaxError, 'VALUES veya SELECT bekleniyor, "%s" bulundu (%s)',
        [PeekToken, CurPos]);

    // R-03: ON CONFLICT (INSERT ... VALUES/SELECT sonrasinda)
    if UpperCase(PeekToken) = 'ON' then
      ParseOnConflict(Result);

    // R-04: RETURNING
    if UpperCase(PeekToken) = 'RETURNING' then
    begin
      NextToken(T);
      ParseReturning(Result.ReturningCols, Result.ReturningExprs);
    end;

  except
    Result.Free;
    raise;
  end;
end;

{ ============================================================
  UPDATE
  ============================================================ }

function TVDbParser.ParseUpdate: TSqlUpdateStmt;
var T: string; Asgn: TUpdateAssignment;
begin
  Result := TSqlUpdateStmt.Create;
  try
    ExpectToken(T); Result.Table := VDbNorm(T);
    Expect('SET');
    while True do
    begin
      ExpectToken(Asgn.ColName); Asgn.ColName := VDbNorm(Asgn.ColName);
      Expect('=');
      Asgn.Expr := ParseExpr;
      Result.Assignments.Add(Asgn);
      if PeekToken = ',' then begin NextToken(T); Continue; end;
      Break;
    end;
    if PeekToken = 'WHERE' then begin NextToken(T); Result.WhereClause := ParseExpr; end;
    // R-04: RETURNING
    if UpperCase(PeekToken) = 'RETURNING' then
    begin
      NextToken(T);
      ParseReturning(Result.ReturningCols, Result.ReturningExprs);
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ ============================================================
  DELETE
  ============================================================ }

function TVDbParser.ParseDelete: TSqlDeleteStmt;
var T: string;
begin
  Result := TSqlDeleteStmt.Create;
  try
    Expect('FROM');
    ExpectToken(T); Result.Table := VDbNorm(T);
    if PeekToken = 'WHERE' then begin NextToken(T); Result.WhereClause := ParseExpr; end;
    // R-04: RETURNING
    if UpperCase(PeekToken) = 'RETURNING' then
    begin
      NextToken(T);
      ParseReturning(Result.ReturningCols, Result.ReturningExprs);
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ ------------------------------------------------------------
  R-03: ON CONFLICT
  ON CONFLICT [(hedef_kolon, ...)] DO NOTHING
  ON CONFLICT [(hedef_kolon, ...)] DO UPDATE SET kolon = ifade, ...
  ------------------------------------------------------------ }
procedure TVDbParser.ParseOnConflict(Stmt: TSqlInsertStmt);
var
  T: string;
  Asgn: TUpdateAssignment;
  n: Integer;
begin
  Expect('ON');
  Expect('CONFLICT');
  // Opsiyonel hedef kolon listesi: ON CONFLICT (id) DO ...
  n := 0;
  if PeekToken = '(' then
  begin
    NextToken(T);   // (
    while PeekToken <> ')' do
    begin
      ExpectToken(T);
      SetLength(Stmt.OnConflictTarget, n + 1);
      Stmt.OnConflictTarget[n] := VDbNorm(T);
      Inc(n);
      if PeekToken = ',' then begin NextToken(T); Continue; end;
      Break;
    end;
    Expect(')');
  end;
  Expect('DO');
  if PeekToken = 'NOTHING' then
  begin
    NextToken(T);
    Stmt.OnConflictAction := ocaDoNothing;
  end
  else if PeekToken = 'UPDATE' then
  begin
    NextToken(T);
    Stmt.OnConflictAction := ocaDoUpdate;
    Expect('SET');
    while True do
    begin
      ExpectToken(Asgn.ColName);
      Asgn.ColName := VDbNorm(Asgn.ColName);
      Expect('=');
      // EXCLUDED.kolon ifadesi de ParseExpr ile okunur; executor
      // FExcludedRow/FExcludedColNames uzerinden degerlendirir.
      Asgn.Expr := ParseExpr;
      Stmt.OnConflictSetExprs.Add(Asgn);
      if PeekToken = ',' then begin NextToken(T); Continue; end;
      Break;
    end;
  end
  else
    raise EVDbException.CreateFmt(ecSyntaxError,
      'ON CONFLICT sonrasi DO NOTHING | DO UPDATE bekleniyor, "%s" bulundu (%s)',
      [PeekToken, CurPos]);
end;

{ ------------------------------------------------------------
  R-04: RETURNING kolon/ifade listesi
  RETURNING * | kolon | ifade [AS alias], ...
  Duz kolon adlari ReturningCols'a; ifadeler ReturningExprs'a yazilir
  (executor bosluk ve alias semasini kendisi kurar).
  ------------------------------------------------------------ }
procedure TVDbParser.ParseReturning(var Cols: TStrArray;
  var Exprs: TList<TSqlExprNode>);
var
  T: string;
  n: Integer;
  E: TSqlExprNode;
begin
  SetLength(Cols, 0);
  while True do
  begin
    if PeekToken = '*' then
    begin
      NextToken(T);
      // RETURNING * -> tum kolonlar; executor bos liste ile de "*"
      // semasini kendisi kuruyor.
      SetLength(Cols, 0);
      Exprs.Add(nil);
      if PeekToken = ',' then begin NextToken(T); Continue; end;
      Break;
    end;
    E := ParseExpr;
    if (not (E is TSqlColumnRefNode)) then
    begin
      Exprs.Add(E);
      // varsa alias yoksay (executor sira bazli dondurur)
    end
    else
    begin
      n := Length(Cols);
      SetLength(Cols, n + 1);
      Cols[n] := VDbNorm(TSqlColumnRefNode(E).ColumnName);
      // Kolon referanslarini da Exprs'e ekle -> EvaluateReturning degerlendirebilsin
      Exprs.Add(E);
    end;
    if PeekToken = 'AS' then begin NextToken(T); ExpectToken(T); end;
    if PeekToken = ',' then begin NextToken(T); Continue; end;
    Break;
  end;
end;

{ ============================================================
  F-35: STORED FUNCTION / PROCEDURE

  Soz dizimi:
    CREATE [OR REPLACE] FUNCTION ad([IN|OUT|INOUT] ad TIP [= varsayilan], ...)
      [RETURNS TIP] [LANGUAGE x] AS <govde>
    CREATE [OR REPLACE] PROCEDURE ad([IN|OUT|INOUT] ad TIP [= varsayilan], ...)
      [LANGUAGE x] AS <govde>
    DROP FUNCTION [IF EXISTS] ad
    DROP PROCEDURE [IF EXISTS] ad
    CALL ad(ifade, ...)

  <govde> = BEGIN s; ... END  |  tek cumle
  ============================================================ }

function TVDbParser.ParseProcParamList(out Params: TFunctionParamArray): Boolean;
var
  T: string;
  n: Integer;
  P: TFunctionParameter;
begin
  SetLength(Params, 0);
  n := 0;
  if PeekToken <> '(' then Exit;
  NextToken(T);   // (
  if PeekToken = ')' then begin NextToken(T); Exit; end;
  while True do
  begin
    P.Mode := 0;      // 0=IN
    P.DefaultExpr := nil;
    // IN / OUT / INOUT oneki (PostgreSQL uyumu)
    if PeekToken = 'IN' then
    begin
      NextToken(T);
      if PeekToken = 'OUT' then begin NextToken(T); P.Mode := 2 end
      else if PeekToken2 = 'OUT' then begin NextToken(T); P.Mode := 2 end
      else P.Mode := 0;
    end
    else if PeekToken = 'OUT' then begin NextToken(T); P.Mode := 1 end
    else if PeekToken = 'INOUT' then begin NextToken(T); P.Mode := 2 end;
    ExpectToken(P.Name);
    P.Name := VDbNorm(P.Name);
    P.TypeName := '';
    // Tip yazilmissa oku (yoksa bos birakilir)
    if (PeekToken <> ',') and (PeekToken <> ')') and (PeekToken <> ';') and
       (PeekToken <> '=') then
    begin
      ExpectToken(T);
      P.TypeName := T;
    end;
    // Varsayilan deger: `= ifade` veya `DEFAULT ifade`
    if PeekToken = '=' then
    begin
      NextToken(T);
      P.DefaultExpr := ParseExpr;
    end
    else if PeekToken = 'DEFAULT' then
    begin
      NextToken(T);
      P.DefaultExpr := ParseExpr;
    end;
    SetLength(Params, n + 1);
    Params[n] := P;
    Inc(n);
    if PeekToken = ',' then begin NextToken(T); Continue; end;
    Break;
  end;
  Expect(')');
end;

function TVDbParser.ParseBodyStatement: TSqlStmtNode;
{ Govde icindeki tek cumle. DIKKAT: Parse() konumu (FPos) sifirlar ve
  FSql'i degistirir; govde icinde kullanilamaz. Bu yuzden gerekli
  cumle turleri elle yonlendirilir. ParseSelect SELECT'i KENDISI yutmaz. }
var
  T, U: string;
begin
  U := PeekToken;
  if U = 'RETURN' then Result := ParseReturn
  else if (U = 'NEW') and (PeekToken2 = '.') then Result := ParseSetNew
  else if U = 'BEGIN' then Result := ParseProcBody
  else if U = 'INSERT' then begin NextToken(T); Result := ParseInsert; end
  else if U = 'UPDATE' then begin NextToken(T); Result := ParseUpdate; end
  else if U = 'DELETE' then begin NextToken(T); Result := ParseDelete; end
  else if U = 'SELECT' then begin NextToken(T); Result := ParseSelect; end
  else
    raise EVDbException.CreateFmt(ecSyntaxError,
      'govde icinde gecersiz cumle: "%s" (%s)', [U, CurPos]);
end;


function TVDbParser.ParseProcBody: TSqlStmtNode;
{ Govde iki bicimde olabilir:
    BEGIN s; ... END      -> TSqlBlockStmt
    tek cumle (INSERT ...) -> dogrudan o cumle
  Semicolon, govde cumlelerini ayirir; disaridaki noktali virgul
  cumleyi bitirir. }
var
  Blk: TSqlBlockStmt;
  S: TSqlStmtNode;
  T: string;
begin
  if PeekToken = 'BEGIN' then
  begin
    NextToken(T);   // BEGIN
    Blk := TSqlBlockStmt.Create;
    try
      while PeekToken <> 'END' do
      begin
        if PeekToken = ';' then begin NextToken(T); Continue; end;
        S := ParseBodyStatement;
        if S = nil then Break;
        Blk.Stmts.Add(S);
        if PeekToken = ';' then NextToken(T);
      end;
      Expect('END');
      Result := Blk;
    except
      Blk.Free;
      raise;
    end;
  end
  else
  begin
    // Govde tek cumle: INSERT/UPDATE/DELETE/SELECT olabilir.
    Result := ParseBodyStatement;
    if Result = nil then
      raise EVDbException.Create(ecSyntaxError, 'prosedur/fonksiyon govdesi bos');
  end;
end;

function TVDbParser.ParseSetNew: TSqlSetNewStmt;
// Govde icinde `NEW.kolon = <ifade>`. Yalniz NEW yazilabilir; eski
// deger (OLD) tetikleyici icinde DEGISTIRILEMEZ.
var
  T: string;
begin
  Result := TSqlSetNewStmt.Create;
  try
    Expect('NEW');
    Expect('.');
    ExpectToken(T); Result.ColName := VDbNorm(T);
    Expect('=');
    Result.Expr := ParseExpr;
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParseCreateTrigger: TSqlCreateTriggerStmt;
// Soz dizimi:
//   CREATE [OR REPLACE] TRIGGER ad
//     BEFORE|AFTER|INSTEAD OF INSERT|UPDATE|DELETE [OR ...]
//     ON tablo [FOR EACH ROW|STATEMENT] [WHEN (kosul)] AS <govde>
var
  T: string;
  ev: TByteArray;
  n: Integer;
begin
  Result := TSqlCreateTriggerStmt.Create;
  try
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('NOT'); Expect('EXISTS');
      Result.IfNotExists := True;
    end;
    ExpectToken(T); Result.TriggerName := VDbNorm(T);

    // --- zamanlama: BEFORE | AFTER | INSTEAD OF ---
    if PeekToken = 'BEFORE' then
    begin NextToken(T); Result.Timing := 0 end
    else if PeekToken = 'AFTER' then
    begin NextToken(T); Result.Timing := 1 end
    else if (PeekToken = 'INSTEAD') and (PeekToken2 = 'OF') then
    begin
      NextToken(T); NextToken(T);
      Result.Timing := 2;
    end
    else
      raise EVDbException.CreateFmt(ecSyntaxError,
        'BEFORE / AFTER / INSTEAD OF bekleniyor (%s)', [CurPos]);

    // --- olaylar: INSERT [OR UPDATE|DELETE] ...
    SetLength(ev, 0);
    n := 0;
    while True do
    begin
      if PeekToken = 'INSERT' then
      begin NextToken(T); SetLength(ev, n + 1); ev[n] := 0; Inc(n) end
      else if PeekToken = 'UPDATE' then
      begin NextToken(T); SetLength(ev, n + 1); ev[n] := 1; Inc(n) end
      else if PeekToken = 'DELETE' then
      begin NextToken(T); SetLength(ev, n + 1); ev[n] := 2; Inc(n) end
      else
        raise EVDbException.CreateFmt(ecSyntaxError,
          'INSERT / UPDATE / DELETE bekleniyor (%s)', [CurPos]);
      if PeekToken = 'OR' then begin NextToken(T); Continue; end;
      Break;
    end;
    Result.Events := ev;

    Expect('ON');
    ExpectToken(T); Result.TableName := VDbNorm(T);

    // --- FOR EACH ROW | STATEMENT ---
    if PeekToken = 'FOR' then
    begin
      NextToken(T); Expect('EACH');
      if PeekToken = 'ROW' then begin NextToken(T); Result.ForEach := 0 end
      else if PeekToken = 'STATEMENT' then
      begin NextToken(T); Result.ForEach := 1 end
      else raise EVDbException.CreateFmt(ecSyntaxError,
        'ROW / STATEMENT bekleniyor (%s)', [CurPos]);
    end
    else
      Result.ForEach := 0;   // varsayilan: FOR EACH ROW

    // --- WHEN (kosul) ---
    if PeekToken = 'WHEN' then
    begin
      NextToken(T);
      Expect('(');
      Result.WhenCondition := ParseExpr;
      Expect(')');
    end;

    Expect('AS');
    Result.Body := ParseProcBody;
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParseCast: TSqlCastNode;
// Soz dizimi: CAST ( expr AS type )
// Giriste 'CAST' yutuldu. Sadece '(' sonrasi ifade ve tip ayristirilir.
var T: string; typ: string;
begin
  Result := TSqlCastNode.Create(nil, '');
  try
    Expect('(');
    Result.Expr := ParseExpr;
    Expect('AS');
    // Tip: INTEGER | TEXT | VARCHAR(n) | NUMERIC(p,s) gibi
    ExpectToken(T);
    typ := T;
    if PeekToken = '( ' then
    begin
      NextToken(T);  // (
      ExpectToken(T);  // boyut
      typ := typ + '(' + T;
      Expect(')');
    end;
    Result.TargetType := UpperCase(typ);
    Expect(')');
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParseDropTrigger: TSqlDropTriggerStmt;
var T: string;
begin
  Result := TSqlDropTriggerStmt.Create;
  try
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('EXISTS'); Result.IfExists := True;
    end;
    ExpectToken(T); Result.TriggerName := VDbNorm(T);
    // ON tablo verilirse yalniz o tabloya ait tetikleyici silinir
    if PeekToken = 'ON' then
    begin
      NextToken(T);
      ExpectToken(T); Result.TableName := VDbNorm(T);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParseRole: TRoleStmt;
{ R-18: CREATE ROLE [SUPERUSER] ad | DROP ROLE [IF EXISTS] ad
  CREATE/DROP token'i ONCE yutulmus. ROLE token'i burada OLABILIR
  (DROP ROLE yolu) veya YOK (CREATE ROLE yolu, orada yutulmus). }
var
  T: string;
begin
  Result := TRoleStmt.Create;
  try
    Result.Make := (UpperCase(FLastMainToken) = 'CREATE');
    NextToken(T);
    // ROLE token'i henuz yutulmamis mi? (DROP ROLE yolu)
    if UpperCase(T) = 'ROLE' then
    begin
      // ROLE yutuldu; role adi siradaki token
      if PeekToken = 'IF' then
      begin
        NextToken(T); NextToken(T);  // IF EXISTS
      end;
      ExpectToken(Result.RoleName);
      Result.RoleName := VDbNorm(Result.RoleName);
    end
    else
    begin
      // ROLE CREATE bloğunda yutulmus; T = role adi
      Result.RoleName := VDbNorm(T);
    end;
    // CREATE ROLE ad SUPERUSER  (opsiyonel)
    if Result.Make then
      while PeekToken <> '' do
      begin
        NextToken(T);
        if UpperCase(T) = 'SUPERUSER' then Result.Super := True
        else if UpperCase(T) = 'NOBYPASSRLS' then { R-19: su an yok }
        else
          break;
      end;
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParseGrant: TGrantStmt;
{ R-18:
    GRANT  SELECT|INSERT|UPDATE|DELETE|ALL ON [TABLE] tablo|* TO role
    REVOKE SELECT|...             ON tablo|* FROM role
  ON anahtar kelimesi opsiyoneldir (PostgreSQL uyumu). }
var
  T: string;
begin
  Result := TGrantStmt.Create;
  try
    Result.Revoke := (UpperCase(FLastMainToken) = 'REVOKE');
    ExpectToken(T);   // privilege: SELECT|INSERT|UPDATE|DELETE|ALL
    if T = 'ALL' then Result.Priv := pkAll
    else if T = 'SELECT' then Result.Priv := pkSelect
    else if T = 'INSERT' then Result.Priv := pkInsert
    else if T = 'UPDATE' then Result.Priv := pkUpdate
    else if T = 'DELETE' then Result.Priv := pkDelete
    else
      raise EVDbException.CreateFmt(ecSyntaxError,
        'GRANT/REVOKE sonrasi SELECT|INSERT|UPDATE|DELETE|ALL bekleniyor, "%s" geldi (%s)',
        [T, CurPos]);
    if PeekToken = 'ON' then NextToken(T);   // ON opsiyonel
    if PeekToken = 'TABLE' then NextToken(T);
    ExpectToken(Result.TableName);
    Result.TableName := VDbNorm(Result.TableName);
    if Result.Revoke then
    begin
      Expect('FROM');
    end
    else
      Expect('TO');
    ExpectToken(Result.RoleName);
    Result.RoleName := VDbNorm(Result.RoleName);
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParsePolicy: TPolicyStmt;
{ R-19:
    CREATE POLICY ad ON tablo [FOR SELECT|INSERT|UPDATE|DELETE|ALL]
             [USING (ifade)] [WITH CHECK (ifade)]
    DROP POLICY ad ON tablo
  USING satirlarin gorunurlugunu, WITH CHECK yeni satirlarin yazilabilirligini
  belirler. FOR verilmezse polAll (SELECT+UPDATE+DELETE icin USING,
  INSERT icin WITH CHECK). }
var
  T, U: string;
begin
  Result := TPolicyStmt.Create;
  try
    Result.Make := (UpperCase(FLastMainToken) = 'CREATE');
    if Result.Make then
    begin
      ExpectToken(Result.PolicyName);
      Result.PolicyName := VDbNorm(Result.PolicyName);
      Expect('ON');
      ExpectToken(Result.TableName);
      Result.TableName := VDbNorm(Result.TableName);
      if PeekToken = 'FOR' then
      begin
        Expect('FOR');
        ExpectToken(T); U := UpperCase(T);
        if U = 'ALL' then Result.Cmd := polAll
        else if U = 'SELECT' then Result.Cmd := polSelect
        else if U = 'INSERT' then Result.Cmd := polInsert
        else if U = 'UPDATE' then Result.Cmd := polUpdate
        else if U = 'DELETE' then Result.Cmd := polDelete
        else
          raise EVDbException.CreateFmt(ecSyntaxError,
            'POLICY FOR sonrasi ALL|SELECT|INSERT|UPDATE|DELETE bekleniyor, "%s" (%s)',
            [T, CurPos]);
      end;
      // USING (expr)
      while PeekToken <> '' do
      begin
        U := UpperCase(PeekToken);
        if U = 'USING' then
        begin
          Expect('USING');
          Expect('(');
          Result.UsingExpr := ParseExpr;
          Result.UsingText := ExprToText(Result.UsingExpr);
          Expect(')');
        end
        else if U = 'WITH' then
        begin
          Expect('WITH'); Expect('CHECK'); Expect('(');
          Result.CheckExpr := ParseExpr;
          Result.CheckText := ExprToText(Result.CheckExpr);
          Expect(')');
        end
        else
        begin
          raise EVDbException.CreateFmt(ecSyntaxError,
            'CREATE POLICY sonrasi USING ya da WITH CHECK bekleniyor, "%s" (%s)',
            [PeekToken, CurPos]);
        end;
      end;
    end
    else
    begin
      ExpectToken(Result.PolicyName);
      Result.PolicyName := VDbNorm(Result.PolicyName);
      Expect('ON');
      ExpectToken(Result.TableName);
      Result.TableName := VDbNorm(Result.TableName);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParseSetConstraints: TSqlSetConstraintsStmt;
// R-11: `SET CONSTRAINTS [ALL] DEFERRED | IMMEDIATE`
// CONSTRAINTS anahtar kelimesi cagiranda yutulmustur.
var
  T: string;
begin
  Result := TSqlSetConstraintsStmt.Create;
  try
    // istege bagli: ALL (varsayilan) veya constraint adi listesi
    if PeekToken = 'ALL' then
    begin
      NextToken(T);
      Result.All := True;
    end
    else
    begin
      // constraint adlari: motor seviyesinde tek kume uygulandigi icin
      // liste de ALL gibi ele alinir
      while (PeekToken <> 'DEFERRED') and (PeekToken <> 'IMMEDIATE') do
      begin
        NextToken(T);
        if PeekToken = ',' then NextToken(T);
      end;
      Result.All := True;
    end;
    ExpectToken(T);
    if UpperCase(T) = 'DEFERRED' then
      Result.Deferred := True
    else if UpperCase(T) = 'IMMEDIATE' then
      Result.Deferred := False
    else
      raise EVDbException.CreateFmt(ecSyntaxError,
        'DEFERRED veya IMMEDIATE bekleniyor, "%s" geldi (%s)', [T, CurPos]);
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParseSetIsolation: TSqlSetIsolationStmt;
// F-40: `SET TRANSACTION ISOLATION LEVEL ...`
// veya `SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL ...`.
var
  T, U: string;
  lvl: TIsolationLevel;
begin
  if PeekToken = 'SESSION' then
  begin
    NextToken(T);
    Expect('CHARACTERISTICS');
    Expect('AS');
  end;
  Expect('TRANSACTION');
  Expect('ISOLATION');
  Expect('LEVEL');
  ExpectToken(T);
  U := UpperCase(T);
  if U = 'READ' then
  begin
    ExpectToken(T);
    if UpperCase(T) = 'COMMITTED' then lvl := ilReadCommitted
    else if UpperCase(T) = 'UNCOMMITTED' then lvl := ilReadUncommitted
    else
      raise EVDbException.CreateFmt(ecSyntaxError,
        'READ COMMITTED veya READ UNCOMMITTED bekleniyor, "%s" geldi (%s)',
        [T, CurPos]);
  end
  else if U = 'REPEATABLE' then
  begin
    Expect('READ');
    lvl := ilRepeatableRead;
  end
  else if U = 'SERIALIZABLE' then
    lvl := ilSerializable
  else
    raise EVDbException.CreateFmt(ecSyntaxError,
      'gecersiz isolation level: "%s" (%s)', [T, CurPos]);
  Result := TSqlSetIsolationStmt.Create(lvl);
end;

function TVDbParser.ParseReturn: TSqlReturnStmt;
begin
  Result := TSqlReturnStmt.Create;
  try
    Expect('RETURN');
    // RETURN; (deger dondurmeden) veya RETURN ifade
    if (PeekToken = ';') or (PeekToken = 'END') or AtEnd then
      Result.Expr := nil
    else
    begin
      Result.Expr := ParseExpr;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParseCreateFunction: TSqlCreateFunctionStmt;
var
  T: string;
begin
  Result := TSqlCreateFunctionStmt.Create;
  try
    // Parse tarafindan CREATE ve FUNCTION yutulmus olur.
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('NOT'); Expect('EXISTS');
      Result.IfNotExists := True;
    end;
    ExpectToken(T); Result.Name := VDbNorm(T);
    ParseProcParamList(Result.Parameters);
    if PeekToken = 'RETURNS' then
    begin
      NextToken(T);
      ExpectToken(T); Result.ReturnType := T;
    end;
    if PeekToken = 'LANGUAGE' then
    begin
      NextToken(T);
      ExpectToken(T); Result.Language := T;
    end;
    Expect('AS');
    Result.Body := ParseProcBody;
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParseDropFunction: TSqlDropFunctionStmt;
var T: string;
begin
  Result := TSqlDropFunctionStmt.Create;
  try
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('EXISTS'); Result.IfExists := True;
    end;
    ExpectToken(T); Result.Name := VDbNorm(T);
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParseCreateProcedure: TSqlCreateProcedureStmt;
var T: string;
begin
  Result := TSqlCreateProcedureStmt.Create;
  try
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('NOT'); Expect('EXISTS');
      Result.IfNotExists := True;
    end;
    ExpectToken(T); Result.Name := VDbNorm(T);
    ParseProcParamList(Result.Parameters);
    if PeekToken = 'LANGUAGE' then
    begin
      NextToken(T);
      ExpectToken(T); Result.Language := T;
    end;
    Expect('AS');
    Result.Body := ParseProcBody;
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParseDropProcedure: TSqlDropProcedureStmt;
var T: string;
begin
  Result := TSqlDropProcedureStmt.Create;
  try
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('EXISTS'); Result.IfExists := True;
    end;
    ExpectToken(T); Result.Name := VDbNorm(T);
  except
    Result.Free;
    raise;
  end;
end;

function TVDbParser.ParseCall: TSqlCallStmt;
var
  T: string;
  E: TSqlExprNode;
begin
  Result := TSqlCallStmt.Create;
  try
    ExpectToken(T); Result.ProcName := VDbNorm(T);
    if PeekToken = '(' then
    begin
      NextToken(T);   // (
      if PeekToken <> ')' then
        while True do
        begin
          E := ParseExpr;
          Result.Arguments.Add(E);
          if PeekToken = ',' then begin NextToken(T); Continue; end;
          Break;
        end;
      Expect(')');
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ ============================================================
  CREATE TABLE
  ============================================================ }

function TVDbParser.ParseCreateTable: TSqlCreateTableStmt;
var T, U: string; C: TColDef; i: Integer;
    Fk: TFkDef; fkColName, fkRef, fkRefCol: string;
    chkText: string; depth: Integer;
    pname: string; k: Integer; isPK: Boolean;
begin
  Result := TSqlCreateTableStmt.Create;
  try
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('NOT'); Expect('EXISTS');
      Result.IfNotExists := True;
    end;
    ExpectToken(T); Result.Table := VDbNorm(T);
    Expect('(');
    i := 0;

    while True do
    begin
      // PRIMARY KEY constraint (tablo seviyesi)
      U := PeekToken;
      if U = 'PRIMARY' then
      begin
        NextToken(T); Expect('KEY');
        Expect('(');
        ExpectToken(T); // pk kolon adı
        Result.PkIndex := i - 1; // arama: bir üstte tanımlanan kolon
        // Adı bul
        pname := VDbNorm(T);
        for k := 0 to High(Result.Cols) do
          if SameText(Result.Cols[k].Name, pname) then
          begin Result.PkIndex := k; Break; end;
        Expect(')');
        if PeekToken = ',' then begin NextToken(T); Continue; end;
        if PeekToken = ')' then begin NextToken(T); Break; end;
        Break;
      end;
      if U = 'UNIQUE' then
      begin
        NextToken(T); Expect('('); ExpectToken(T); Expect(')');
        if PeekToken = ',' then begin NextToken(T); Continue; end;
        if PeekToken = ')' then begin NextToken(T); Break; end;
        Break;
      end;
      if U = 'CHECK' then
      begin
        NextToken(T); // CHECK yut
        Expect('(');
        Result.CheckExprs.Add(ParseExpr);
        Expect(')');
        if PeekToken = ',' then begin NextToken(T); Continue; end;
        if PeekToken = ')' then begin NextToken(T); Break; end;
        Break;
      end;
      if U = 'FOREIGN' then
      begin
        NextToken(T); Expect('KEY');
        Expect('('); ExpectToken(fkColName); Expect(')');
        Expect('REFERENCES');
        ExpectToken(fkRef); fkRef := VDbNorm(fkRef);
        fkRefCol := '';
        if PeekToken = '(' then begin NextToken(T); ExpectToken(fkRefCol); Expect(')'); end;
        // TFkDef alanları
        Fk.Col := -1;
        // Col index'i bul
        for k := 0 to High(Result.Cols) do
          if SameText(Result.Cols[k].Name, VDbNorm(fkColName)) then
          begin Fk.Col := k; Break; end;
        fk.RefTable := fkRef;
        fk.RefCol := fkRefCol;
        fk.OnDelete := VDB_FK_RESTRICT;
        fk.OnUpdate := VDB_FK_RESTRICT;
        while PeekToken = 'ON' do
        begin
          NextToken(T); ExpectToken(T); U := UpperCase(T);
          if U = 'DELETE' then fk.OnDelete := ReadFkAction
          else if U = 'UPDATE' then fk.OnUpdate := ReadFkAction;
        end;
        SetLength(Result.Fks, Length(Result.Fks) + 1);
        Result.Fks[High(Result.Fks)] := fk;
        if PeekToken = ',' then begin NextToken(T); Continue; end;
        if PeekToken = ')' then begin NextToken(T); Break; end;
        Break;
      end;

      // Kolon tanımı
      ExpectToken(C.Name); C.Name := VDbNorm(C.Name);
      // PK belirleme: PRIMARY anahtar kelimesi ParseColDef'te tüketilir,
      // ama PkIndex'i burada ayarlamamız gerekiyor.
      isPK := (UpperCase(PeekToken) = 'PRIMARY') or
              (UpperCase(PeekToken2) = 'PRIMARY');
      ParseColDef(C, Result);
      if isPK then Result.PkIndex := i;
      SetLength(Result.Cols, i + 1);
      Result.Cols[i] := C;
      Inc(i);

      if PeekToken = ')' then begin NextToken(T); Break; end;
      if PeekToken = ',' then begin NextToken(T); Continue; end;
      Break;
    end;
    if PeekToken = ')' then NextToken(T);

    // R-13: PARTITION BY RANGE(col) (VALUES BETWEEN x AND y) | LIST(col) (VALUES IN (x,y,z))
    if UpperCase(PeekToken) = 'PARTITION' then
    begin
      NextToken(T); Expect('BY');
      NextToken(T); Result.PartitionType := UpperCase(T);
      Expect('('); ExpectToken(T); Result.PartitionCol := VDbNorm(T); Expect(')');
      if Result.PartitionType = 'LIST' then
      begin
        Expect('('); Expect('VALUES'); Expect('IN');
        Expect('(');
        while True do
        begin
          NextToken(T);
          if T = ')' then Break;
          // R-13 Full: degerler LITERAL olarak saklanir. VDbNorm KUCUK
          // harfe ceviriyordu: TEXT anahtar 'A' ile tanim 'a' HIC eslesmez,
          // satir sessizce DEFAULT bolumesine duserdi. Tirnagi lexer
          // zaten soyuyor. (Ikinci gizli hata: dongu kapanis ')'ini
          // tukettigi halde ardinda IKI Expect(')') vardi -> LIST
          // tanimi her zaman "dosya sonu" hatasi verirdi.)
          Result.PartitionValues.Add(T);
          if PeekToken = ',' then begin NextToken(T); Continue; end;
        end;
        Expect(')');
      end
      else if Result.PartitionType = 'RANGE' then
      begin
        Expect('('); Expect('VALUES'); Expect('BETWEEN');
        // R-13 Full: sinirlar da literal (VDbNorm metin sinirlari
        // kucuk harfe cevirip kullanicinin araligini bozuyordu).
        ExpectToken(T); Result.PartitionValues.Add(T);
        Expect('AND');
        ExpectToken(T); Result.PartitionValues.Add(T);
        Expect(')');
      end
      // R-13 Full: PARTITION BY HASH (col) PARTITIONS n
      else if Result.PartitionType = 'HASH' then
      begin
        Expect('PARTITIONS');
        ExpectToken(T);
        // bolum sayisi; sayisal dogrulama (1..1024) CreateTable'ta yapilir
        Result.PartitionValues.Add(T);
      end;
    end;

  except
    Result.Free;
    raise;
  end;
end;

{ ============================================================
  ALTER TABLE
  ============================================================ }

function TVDbParser.ParseAlterTable: TSqlAlterTableStmt;
var T, U, U2: string;
begin
  Result := TSqlAlterTableStmt.Create;
  try
    ExpectToken(T); Result.Table := VDbNorm(T);
    ExpectToken(T); U := UpperCase(T);

    // R-22: CONCURRENTLY oncesi opsiyonel (ALTER TABLE ... CONCURRENTLY ADD ...)
    if U = 'CONCURRENTLY' then
    begin
      Result.Concurrently := True;
      ExpectToken(T); U := UpperCase(T);
    end;

    if (U = 'ENABLE') or (U = 'DISABLE') then
    begin
      // R-19: ENABLE|DISABLE ROW LEVEL SECURITY
      U2 := PeekToken;
      if U2 <> 'ROW' then
        raise EVDbException.CreateFmt(ecSyntaxError,
          '%s ROW LEVEL SECURITY bekleniyor, "%s" (%s)', [U, U2, CurPos]);
      NextToken(T);
      U2 := PeekToken;
      if (UpperCase(U2) <> 'LEVEL') or (UpperCase(PeekToken2) <> 'SECURITY') then
        raise EVDbException.CreateFmt(ecSyntaxError,
          '%s ROW LEVEL SECURITY bekleniyor, "%s" (%s)', [U, U2, CurPos]);
      NextToken(T); NextToken(T);
      if U = 'ENABLE' then Result.Action := ataEnableRls
      else Result.Action := ataDisableRls;
    end
    else if U = 'ADD' then
    begin
      // ADD [COLUMN] colname type ...
      if PeekToken = 'COLUMN' then NextToken(T);
      ExpectToken(Result.ColDef.Name); Result.ColDef.Name := VDbNorm(Result.ColDef.Name);
      Result.Action := ataAddColumn;
      ParseColDef(Result.ColDef);
      Result.DefaultVal := Result.ColDef.Def;
      // AFTER / FIRST
      if PeekToken = 'AFTER' then begin NextToken(T); ExpectToken(Result.PositionCol); end
      else if PeekToken = 'FIRST' then begin NextToken(T); Result.IsFirst := True; end;
    end
    else if U = 'DROP' then
    begin
      if PeekToken = 'COLUMN' then NextToken(T);
      ExpectToken(Result.ColName);
      Result.ColName := VDbNorm(Result.ColName);
      Result.Action := ataDropColumn;
    end
    else if U = 'RENAME' then
    begin
      U := PeekToken;
      if U = 'TO' then
      begin
        NextToken(T); ExpectToken(Result.NewName);
        Result.Action := ataRenameTable;
      end
      else
      begin
        if U = 'COLUMN' then NextToken(T);
        ExpectToken(Result.ColName); Result.ColName := VDbNorm(Result.ColName);
        Expect('TO'); ExpectToken(Result.NewName);
        Result.Action := ataRenameColumn;
      end;
    end
    else if U = 'MODIFY' then
    begin
      // MODIFY COLUMN col type
      if PeekToken = 'COLUMN' then NextToken(T);
      ExpectToken(Result.ColName); Result.ColName := VDbNorm(Result.ColName);
      ExpectToken(T); Result.NewTypeName := T;
      Result.Action := ataAlterColType;
    end
    else if U = 'ALTER' then
    begin
      // ALTER [COLUMN] col SET DEFAULT x | DROP DEFAULT | SET NOT NULL | DROP NOT NULL
      if PeekToken = 'COLUMN' then NextToken(T);
      ExpectToken(Result.ColName); Result.ColName := VDbNorm(Result.ColName);
      ExpectToken(T); U := UpperCase(T);
      if U = 'SET' then
      begin
        ExpectToken(T); U := UpperCase(T);
        if U = 'DEFAULT' then begin ExpectToken(Result.DefaultVal); Result.Action := ataSetDefault; end
        else if U = 'NOT' then begin Expect('NULL'); Result.Action := ataSetNotNull; end
        else raise EVDbException.CreateFmt(ecNotNullViolation, 'SET sonrasi DEFAULT veya NOT NULL bekleniyor, "%s" bulundu', [T]);
      end
      else if U = 'DROP' then
      begin
        ExpectToken(T); U := UpperCase(T);
        if U = 'DEFAULT' then Result.Action := ataDropDefault
        else if U = 'NOT' then begin Expect('NULL'); Result.Action := ataDropNotNull; end
        else raise EVDbException.CreateFmt(ecNotNullViolation, 'DROP sonrasi DEFAULT veya NOT NULL bekleniyor, "%s" bulundu', [T]);
      end
      else if U = 'TYPE' then
      begin
        ExpectToken(Result.NewTypeName);
        // M4: ALTER COLUMN ... TYPE VECTOR(n) tek token degil.
        if UpperCase(Result.NewTypeName) = 'VECTOR' then
          if TryEat('(') then
          begin
            ExpectToken(T);
            Result.NewTypeName := 'VECTOR(' + T + ')';
            Expect(')');
          end;
        Result.Action := ataAlterColType;
      end
      else raise EVDbException.CreateFmt(ecSyntaxError, 'ALTER COLUMN sonrasi bilinmeyen eylem: "%s"', [T]);
    end
    else if U = 'CONSTRAINT' then
    begin
      // 4.6: ADD CONSTRAINT / DROP CONSTRAINT (basit parser acik, yurutucu sinirlidir)
      ExpectToken(T); // CHECK / FOREIGN KEY / PRIMARY KEY
      T := UpperCase(T);
      if (T = 'CHECK') or (T = 'FOREIGN') or (T = 'PRIMARY') then
      begin
        ExpectToken(Result.ColName); // sinirli: kolon adi / anahtar adi
        if T = 'FOREIGN' then Expect('KEY');
        if PeekToken = 'ON' then begin NextToken(T); ExpectToken(Result.Table); end;
        if PeekToken = 'REFERENCES' then begin NextToken(T); ExpectToken(Result.Table); end;
        Result.Action := ataAddConstraint;
      end
      else
        raise EVDbException.CreateFmt(ecSyntaxError, 'ALTER TABLE CONSTRAINT icin bilinmeyen tur: "%s"', [T]);
    end
    else
      raise EVDbException.CreateFmt(ecSyntaxError, 'ALTER TABLE icin bilinmeyen eylem: "%s" (%s)', [T, CurPos]);

  except
    Result.Free;
    raise;
  end;
end;

{ ============================================================
  DROP TABLE
  ============================================================ }

function TVDbParser.ParseDropTable: TSqlDropTableStmt;
var T: string;
begin
  Result := TSqlDropTableStmt.Create;
  try
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('EXISTS'); Result.IfExists := True;
    end;
    ExpectToken(T); Result.Table := VDbNorm(T);
  except
    Result.Free; raise;
  end;
end;

{ ============================================================
  F-33/F-34: VIEW / MATERIALIZED VIEW ayristirma

  DIKKAT: SELECT govdesi hem AST olarak hem de ORIJINAL METIN olarak
  saklanir. AST, CREATE cumlesi bittikten sonra Free edilir; bu yuzden
  tanim kaybolur. REFRESH (MATERIALIZED VIEW) ve view uzerine yazma
  (UPDATE/DELETE) tanimi METINDEN yeniden uretir. Metin, SELECT'in BASINDAN
  alinir.
  ============================================================ }

function TVDbParser.ParseCreateView: TSqlCreateViewStmt;
var T: string; sv: Integer;
begin
  Result := TSqlCreateViewStmt.Create;
  try
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('NOT'); Expect('EXISTS');
      Result.IfNotExists := True;
    end;
    ExpectToken(T); Result.ViewName := VDbNorm(T);
    Expect('AS');
    sv := FPos;
    Expect('SELECT');
    Result.SelectStmt := ParseSelect;
    Result.SelectText := Trim(Copy(FSql, sv, FPos - sv));
  except
    Result.Free; raise;
  end;
end;

function TVDbParser.ParseDropView: TSqlDropViewStmt;
var T: string;
begin
  Result := TSqlDropViewStmt.Create;
  try
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('EXISTS'); Result.IfExists := True;
    end;
    ExpectToken(T); Result.ViewName := VDbNorm(T);
  except
    Result.Free; raise;
  end;
end;

function TVDbParser.ParseCreateMaterializedView: TSqlCreateMaterializedViewStmt;
var T: string; sv: Integer;
begin
  Result := TSqlCreateMaterializedViewStmt.Create;
  try
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('NOT'); Expect('EXISTS');
      Result.IfNotExists := True;
    end;
    ExpectToken(T); Result.ViewName := VDbNorm(T);
    Expect('AS');
    sv := FPos;
    Expect('SELECT');
    Result.SelectStmt := ParseSelect;
    Result.SelectText := Trim(Copy(FSql, sv, FPos - sv));
  except
    Result.Free; raise;
  end;
end;

function TVDbParser.ParseDropMaterializedView: TSqlDropMaterializedViewStmt;
var T: string;
begin
  Result := TSqlDropMaterializedViewStmt.Create;
  try
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('EXISTS'); Result.IfExists := True;
    end;
    ExpectToken(T); Result.ViewName := VDbNorm(T);
  except
    Result.Free; raise;
  end;
end;

function TVDbParser.ParseRefreshMaterializedView: TSqlRefreshMaterializedViewStmt;
var T: string;
begin
  Result := TSqlRefreshMaterializedViewStmt.Create;
  try
    // CONCURRENTLY opsiyonel bayrak
    if PeekToken = 'CONCURRENTLY' then
    begin
      NextToken(T); Result.Concurrently := True;
    end;
    ExpectToken(T); Result.ViewName := VDbNorm(T);
  except
    Result.Free; raise;
  end;
end;

{ ============================================================
  CREATE INDEX / DROP INDEX
  ============================================================ }

{ F-17: Ifade dugumunu geri metne cevirir (partial index kosulu semaya
  yazilir; dosya yeniden acildiginda korunur). Kapsamli alt kume: literal,
  kolon, ikili/unary islem, parantez, IN listesi, NULL denetimi. Bilinmeyen
  dugum turunde bos metin doner (bu durumda Predicate bos kalir ve indeks
  normal indeks gibi davranir). }
function ExprToText(E: TSqlExprNode): string;

  function BinName(O: TSqlBinaryOp): string;
  begin
    case O of
      sboAdd: Result := '+';  sboSub: Result := '-';
      sboMul: Result := '*';  sboDiv: Result := '/';
      sboMod: Result := '%';
      sboEq:  Result := '=';  sboNeq: Result := '<>';
      sboLt:  Result := '<';  sboLte: Result := '<=';
      sboGt:  Result := '>';  sboGte: Result := '>=';
      sboLike: Result := 'LIKE'; sboILike: Result := 'ILIKE';
      sboAnd: Result := 'AND';  sboOr:  Result := 'OR';
    else
      Result := '?';
    end;
  end;

  function Q(const S: string): string;
  begin
    // Her zaman tirnakla; icteki ' karakterleri ikiye katlanir
    Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
  end;

  function Sub(E2: TSqlExprNode; const Op: string; const Rt: string): string;
  var
    s2: string;
  begin
    s2 := ExprToText(E2);
    if s2 = '' then Exit('');
    Result := '(' + s2 + ' ' + Op + ' ' + Rt + ')';
  end;

var
  b, u: TSqlBinaryOpNode;
  un: TSqlUnaryOpNode;
  inN: TSqlInNode;
  bt: TSqlBetweenNode;
  k: Integer;
  s: string;
begin
  Result := '';
  if E = nil then Exit;
  if E is TSqlLiteralNode then
  begin
    case TSqlLiteralNode(E).LitType of
      sltNull:   Exit('NULL');
      sltString: Exit(Q(TSqlLiteralNode(E).StrVal));
      sltBool:   if TSqlLiteralNode(E).BoolVal then Exit('1') else Exit('0');
    else
      Exit(TSqlLiteralNode(E).AsString);   // int / float
    end;
  end;
  if E is TSqlColumnRefNode then Exit(TSqlColumnRefNode(E).QualifiedName);
  if E is TSqlBinaryOpNode then
  begin
    b := TSqlBinaryOpNode(E);
    Exit(Sub(b.Left, BinName(b.Op), ExprToText(b.Right)));
  end;
  if E is TSqlUnaryOpNode then
  begin
    un := TSqlUnaryOpNode(E);
    case un.Op of
      suoNot:      Result := '(NOT ' + ExprToText(un.Operand) + ')';
      suoNeg:      Result := '(-' + ExprToText(un.Operand) + ')';
      suoIsNull:   Result := '(' + ExprToText(un.Operand) + ' IS NULL)';
      suoIsNotNull:Result := '(' + ExprToText(un.Operand) + ' IS NOT NULL)';
    else
      Result := '';
    end;
    Exit;
  end;
  if E is TSqlInNode then
  begin
    inN := TSqlInNode(E);
    if inN.IsNot then Result := ' NOT IN (' else Result := ' IN (';
    Result := '(' + ExprToText(inN.Expr) + Result;
    for k := 0 to inN.List.Count - 1 do
    begin
      if k > 0 then Result := Result + ',';
      Result := Result + ExprToText(inN.List[k]);
    end;
    Result := Result + '))';
    Exit;
  end;
  if E is TSqlBetweenNode then
  begin
    bt := TSqlBetweenNode(E);
    if bt.IsNot then Result := ' NOT BETWEEN ' else Result := ' BETWEEN ';
    Result := '(' + ExprToText(bt.Expr) + Result +
              ExprToText(bt.LowBound) + ' AND ' + ExprToText(bt.HighBound) + ')';
    Exit;
  end;
  if E is TSqlFuncCallNode then
  begin
    Result := UpperCase(TSqlFuncCallNode(E).FuncName) + '(';
    if TSqlFuncCallNode(E).IsStar then Result := Result + '*'
    else Result := Result + ExprToText(TSqlFuncCallNode(E).Arg);
    Result := Result + ')';
    Exit;
  end;
  s := '';
end;

function TVDbParser.ParseCreateIndex: TSqlCreateIndexStmt;
var T: string;
    idxFirst: Boolean;   // F-18
begin
  Result := TSqlCreateIndexStmt.Create;
  try
    if PeekToken = 'UNIQUE' then NextToken(T); // UNIQUE INDEX
    // R-22: CREATE INDEX CONCURRENTLY
    if PeekToken = 'CONCURRENTLY' then
    begin
      Result.Concurrently := True;
      NextToken(T);
    end;
    Expect('INDEX');
    ExpectToken(T); Result.IndexName := VDbNorm(T);
    Expect('ON');
    ExpectToken(T); Result.Table := VDbNorm(T);
    Expect('(');
    // F-18: ifade indeksi (bkz. Parse ana kolundaki CREATE INDEX yolu)
    idxFirst := True;
    while True do
    begin
      if PeekToken = ')' then Break;
      if (PeekToken2 = ',') or (PeekToken2 = ')') then
      begin
        ExpectToken(T);
        SetLength(Result.Cols, Length(Result.Cols) + 1);
        Result.Cols[High(Result.Cols)] := VDbNorm(T);
      end
      else
      begin
        if not idxFirst then
          raise EVDbException.Create(ecUnsupported,
            'ifade indeksi tek ifade kabul eder');
        Result.ExprNode := ParseExpr;
        Result.ExprText := ExprToText(Result.ExprNode);
        if Result.ExprText = '' then
          raise EVDbException.Create(ecUnsupported, 'indeks ifadesi desteklenmiyor');
      end;
      idxFirst := False;
      if PeekToken <> ',' then Break;
      NextToken(T);
    end;
    if (Length(Result.Cols) = 0) and (Result.ExprNode = nil) then
      raise EVDbException.Create(ecSyntaxError, 'indeks kolonu yok');
    if Length(Result.Cols) > 0 then
      Result.Col := Result.Cols[0]
    else
      Result.Col := '';
    Expect(')');
    // F-19: COVERING INDEX
    if PeekToken = 'INCLUDE' then
    begin
      NextToken(T);
      Expect('(');
      while True do
      begin
        ExpectToken(T);
        SetLength(Result.Incl, Length(Result.Incl) + 1);
        Result.Incl[High(Result.Incl)] := VDbNorm(T);
        if PeekToken <> ',' then Break;
        NextToken(T);
      end;
      Expect(')');
    end;
    // F-17: PARTIAL INDEX
    if PeekToken = 'WHERE' then
    begin
      NextToken(T);
      Result.PredExpr := ParseExpr;
      Result.Predicate := ExprToText(Result.PredExpr);
    end;
  except
    Result.Free; raise;
  end;
end;

function TVDbParser.ParseDropIndex: TSqlDropIndexStmt;
var T: string;
begin
  Result := TSqlDropIndexStmt.Create;
  try
    if PeekToken = 'IF' then begin NextToken(T); Expect('EXISTS'); Result.IfExists := True; end;
    ExpectToken(T); Result.IndexName := VDbNorm(T);
  except
    Result.Free; raise;
  end;
end;

{ ============================================================
  ADMIN cümleleri (CREATE/DROP/OPEN/CLOSE DATABASE, BACKUP, VERIFY,
  VACUUM, REINDEX, SHOW/LIST)
  ============================================================ }

function TVDbParser.ParseAdmin(const Kw1, Kw2: string): TSqlAdminStmt;
var T, U: string; st: TSqlAdminStmt;
begin
  // Kw1 = ilk keyword (CREATE/DROP/OPEN/CLOSE/BACKUP/VERIFY/VACUUM/REINDEX/SHOW/LIST)
  // Kw2 = ikinci keyword (DATABASE, TABLES vs.) — bazı durumlarda boş
  Result := nil;

  // ---- R-17: STREAMING REPLICATION ----
  // START REPLICATION PRIMARY [DEST 'ship-dir' | TCP PORT n] SLOT 'slot'
  // START REPLICATION STANDBY ['conninfo' | TCP HOST 'h' PORT n] SLOT 'slot'
  // STOP REPLICATION
  // CREATE REPLICATION SLOT 'slot'
  // DROP REPLICATION SLOT 'slot'
  // PUMP REPLICATION
  // SHOW REPLICATION STATUS
  // SHOW REPLICATION SLOTS
  // NOT: Bu blok EN BASTA olmali; aksi halde genel CREATE/DROP/SHOW
  // bloklari "REPLICATION"i yanlis yorumlar.
  if (Kw1 = 'START') and (Kw2 = 'REPLICATION') then
  begin
    U := PeekToken;
    if U = 'PRIMARY' then
    begin
      NextToken(T);
      st := TSqlAdminStmt.Create(admReplicationStart);
      st.ReplIsPrimary := True;
      // R-17 Full: TCP PORT n — gercek ag akisi (dosya DEST yerine)
      if PeekToken = 'TCP' then
      begin
        NextToken(T);
        Expect('PORT');
        ExpectToken(T);
        st.ReplTcp := True;
        st.ReplPort := StrToIntDef(T, 0);
        if st.ReplPort <= 0 then
          raise EVDbException.Create(ecSyntaxError,
            'START REPLICATION PRIMARY TCP: gecerli bir PORT sayisi gerekir');
      end
      // opsiyonel DEST 'ship-dir' (dosya tasima modu)
      else if PeekToken = 'DEST' then
      begin
        NextToken(T);
        ExpectToken(T);
        st.ReplConnInfo := T;
      end;
      Expect('SLOT'); ExpectToken(T); st.ReplSlot := VDbNorm(T);
      Exit(st);
    end;
    if U = 'STANDBY' then
    begin
      NextToken(T);
      st := TSqlAdminStmt.Create(admReplicationStart);
      // R-17 Full: TCP HOST 'h' PORT n — primary'ye gercek agdan baglan
      if PeekToken = 'TCP' then
      begin
        NextToken(T);
        Expect('HOST');
        ExpectToken(T);
        st.ReplHost := T;
        Expect('PORT');
        ExpectToken(T);
        st.ReplTcp := True;
        st.ReplPort := StrToIntDef(T, 0);
        if st.ReplPort <= 0 then
          raise EVDbException.Create(ecSyntaxError,
            'START REPLICATION STANDBY TCP: gecerli bir PORT sayisi gerekir');
      end
      else
      begin
        ExpectToken(T); st.ReplConnInfo := T;
      end;
      Expect('SLOT'); ExpectToken(T); st.ReplSlot := VDbNorm(T);
      Exit(st);
    end;
    raise EVDbException.Create(ecSyntaxError, 'START REPLICATION: PRIMARY veya STANDBY bekleniyor');
  end;

  if (Kw1 = 'PUMP') and (Kw2 = 'REPLICATION') then
    Exit(TSqlAdminStmt.Create(admReplicationPump));

  if (Kw1 = 'STOP') and (Kw2 = 'REPLICATION') then
    Exit(TSqlAdminStmt.Create(admReplicationStop));

  if (Kw1 = 'CREATE') and (Kw2 = 'REPLICATION') then
  begin
    Expect('SLOT'); ExpectToken(T);
    st := TSqlAdminStmt.Create(admCreateReplSlot);
    st.ReplSlot := VDbNorm(T);
    Exit(st);
  end;

  if (Kw1 = 'DROP') and (Kw2 = 'REPLICATION') then
  begin
    Expect('SLOT'); ExpectToken(T);
    st := TSqlAdminStmt.Create(admDropReplSlot);
    st.ReplSlot := VDbNorm(T);
    Exit(st);
  end;

  // ---- R-21: EXTENSION / PLUGIN ----
  // CREATE EXTENSION [IF NOT EXISTS] ad [FROM 'yol']
  // DROP EXTENSION [IF EXISTS] ad
  if (Kw1 = 'CREATE') and (Kw2 = 'EXTENSION') then
  begin
    st := TSqlAdminStmt.Create(admCreateExtension);
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('NOT'); Expect('EXISTS');
      st.IfNotExists := True;
    end;
    ExpectToken(T); st.ExtName := VDbNorm(T);
    if PeekToken = 'FROM' then
    begin
      NextToken(T);
      ExpectToken(T);
      st.ExtPath := VDbUnquote(T);
    end;
    Exit(st);
  end;

  if (Kw1 = 'DROP') and (Kw2 = 'EXTENSION') then
  begin
    st := TSqlAdminStmt.Create(admDropExtension);
    if PeekToken = 'IF' then
    begin
      NextToken(T); Expect('EXISTS');
      st.IfExists := True;
    end;
    ExpectToken(T); st.ExtName := VDbNorm(T);
    Exit(st);
  end;

  if Kw1 = 'SHOW' then
  begin
    if PeekToken = 'REPLICATION' then
    begin
      NextToken(T);   // 'REPLICATION' tuket
      if PeekToken = 'STATUS' then
      begin
        NextToken(T);
        Exit(TSqlAdminStmt.Create(admShowReplicationStatus));
      end;
      if PeekToken = 'SLOTS' then
      begin
        NextToken(T);
        Exit(TSqlAdminStmt.Create(admShowReplSlots));
      end;
      raise EVDbException.Create(ecSyntaxError,
        'SHOW REPLICATION: STATUS veya SLOTS bekleniyor');
    end;
  end;

  if (Kw1 = 'VERIFY') then
    Exit(TSqlAdminStmt.Create(admVerify));

  if (Kw1 = 'VACUUM') then
    Exit(TSqlAdminStmt.Create(admVacuum));

  if (Kw1 = 'REINDEX') then
    Exit(TSqlAdminStmt.Create(admReindex));

  // ---- R-15 Full: Cost-Based Optimizer — ANALYZE [TABLE] <tablo> ----
  if (Kw1 = 'ANALYZE') then
  begin
    st := TSqlAdminStmt.Create(admAnalyze);
    if PeekToken = 'TABLE' then NextToken(T);
    if PeekToken <> '' then
    begin
      NextToken(T);
      if T <> ';' then st.TableName := VDbNorm(T);
    end;
    Exit(st);
  end;

  if (Kw1 = 'SHOW') or (Kw1 = 'LIST') then
  begin
    U := PeekToken;
    if U = 'TABLES' then begin NextToken(T); Exit(TSqlAdminStmt.Create(admShowTables)); end;
    if U = 'DATABASES' then begin NextToken(T); Exit(TSqlAdminStmt.Create(admListDbs)); end;
    // R-21: SHOW EXTENSIONS — yuklu extension listesi
    if U = 'EXTENSIONS' then begin NextToken(T); Exit(TSqlAdminStmt.Create(admShowExtensions)); end;
    // 2026-10-04: SHOW INDEXES [FROM] t  /  SHOW CREATE TABLE t
    if U = 'INDEXES' then
    begin
      NextToken(T);
      st := TSqlAdminStmt.Create(admShowIndexes);
      if PeekToken = 'FROM' then NextToken(T);
      ExpectToken(T); st.TableName := VDbNorm(T);
      Exit(st);
    end;
    // R-13 Full: SHOW PARTITIONS [FROM] t
    if U = 'PARTITIONS' then
    begin
      NextToken(T);
      st := TSqlAdminStmt.Create(admShowPartitions);
      if PeekToken = 'FROM' then NextToken(T);
      ExpectToken(T); st.TableName := VDbNorm(T);
      Exit(st);
    end;
    // R-24 (2026-10-13): SHOW STATS  /  SHOW STATS TABLE t
    if U = 'STATS' then
    begin
      NextToken(T);
      st := TSqlAdminStmt.Create(admShowStats);
      if PeekToken = 'TABLE' then
      begin
        NextToken(T);
        ExpectToken(T);
        st.TableName := VDbNorm(T);
      end;
      Exit(st);
    end;
    if U = 'CREATE' then
    begin
      NextToken(T); Expect('TABLE');
      st := TSqlAdminStmt.Create(admShowCreateTable);
      ExpectToken(T); st.TableName := VDbNorm(T);
      Exit(st);
    end;
    raise EVDbException.CreateFmt(ecSyntaxError,
      '"%s" sonrasi TABLES, DATABASES, INDEXES, PARTITIONS, STATS veya CREATE TABLE bekleniyor', [Kw1]);
  end;

  // 2026-10-04: DESCRIBE t  /  DESC t   (MySQL/PostgreSQL uyumu)
  if (Kw1 = 'DESCRIBE') or (Kw1 = 'DESC') then
  begin
    ExpectToken(T);
    Result := TSqlAdminStmt.Create(admDescribe);
    Result.TableName := VDbNorm(T);
    Exit;
  end;

  if Kw1 = 'BACKUP' then
  begin
    st := TSqlAdminStmt.Create(admBackupDb);
    Expect('TO'); ExpectToken(T); st.BackupPath := T;
    Exit(st);
  end;

  // ---- R-16: WAL ARSIVLEME + PITR ----
  // RECOVER TO TIMESTAMP 'YYYY-MM-DD HH:MM:SS[.mmm]'
  // RECOVER TO NOW              -> arsivin tamamini uygula
  if Kw1 = 'RECOVER' then
  begin
    st := TSqlAdminStmt.Create(admRecoverTo);
    st.RecoverStamp := 0;
    Expect('TO');
    if PeekToken = 'NOW' then
    begin
      NextToken(T);                       // 0 = "su ana kadar"
    end
    else
    begin
      Expect('TIMESTAMP');
      ExpectToken(T);
      st.RecoverStamp := ParseTimeStampMS(T);
    end;
    Exit(st);
  end;

  // RESTORE FROM 'yol'
  if Kw1 = 'RESTORE' then
  begin
    st := TSqlAdminStmt.Create(admRestoreFrom);
    Expect('FROM'); ExpectToken(T); st.BackupPath := T;
    Exit(st);
  end;

  // ARCHIVE WAL SET DIR='yol' [SIZE=<bayt>]
  // ARCHIVE WAL RESET
  // ARCHIVE WAL LIST
  if Kw1 = 'ARCHIVE' then
  begin
    Expect('WAL');
    if PeekToken = 'LIST' then
    begin
      NextToken(T);
      Exit(TSqlAdminStmt.Create(admArchiveList));
    end;
    if PeekToken = 'RESET' then
    begin
      NextToken(T);
      st := TSqlAdminStmt.Create(admArchiveSet);
      st.ArchiveDir := '';
      Exit(st);
    end;
    Expect('SET');
    st := TSqlAdminStmt.Create(admArchiveSet);
    { hem "DIR='x'" hem "DIR 'x'" kabul }
    ExpectToken(T);
    if UpperCase(T) <> 'DIR' then
      raise EVDbException.Create(ecSyntaxError, 'ARCHIVE WAL: DIR bekleniyor');
    if PeekToken = '=' then NextToken(T);
    ExpectToken(T);
    st.ArchiveDir := T;
    st.ArchiveSize := 0;
    while PeekToken <> '' do
    begin
      NextToken(T);
      if (UpperCase(T) = 'SIZE') or (UpperCase(T) = 'SEGMENT_SIZE') then
      begin
        if PeekToken = '=' then NextToken(T);
        ExpectToken(T);
        st.ArchiveSize := StrToInt64Def(VDbUnquote(T), 0);
      end
      else
        raise EVDbException.Create(ecSyntaxError,
          'ARCHIVE WAL SET: SIZE bekleniyor, "' + T + '" geldi');
    end;
    Exit(st);
  end;

  // 4.6: PRAGMA (bilgi komutlari — basit parser acik)
  if Kw1 = 'PRAGMA' then
  begin
    st := TSqlAdminStmt.Create(admPragma);
    ExpectToken(T); st.PragmaName := VDbNorm(T);
    Exit(st);
  end;

  if Kw1 = 'CREATE' then
  begin
    // Kw2 = DATABASE
    st := TSqlAdminStmt.Create(admCreateDb);
    if PeekToken = 'IF' then begin NextToken(T); Expect('NOT'); Expect('EXISTS'); st.IfNotExists := True; end;
    ExpectToken(T); st.DbName := T;
    Exit(st);
  end;

  if Kw1 = 'DROP' then
  begin
    st := TSqlAdminStmt.Create(admDropDb);
    if PeekToken = 'IF' then begin NextToken(T); Expect('EXISTS'); st.IfExists := True; end;
    ExpectToken(T); st.DbName := T;
    Exit(st);
  end;

  if (Kw1 = 'OPEN') or (Kw1 = 'USE') then
  begin
    if PeekToken = 'DATABASE' then NextToken(T);
    st := TSqlAdminStmt.Create(admOpenDb);
    ExpectToken(T); st.DbName := T;
    Exit(st);
  end;

  if Kw1 = 'CLOSE' then
  begin
    if PeekToken = 'DATABASE' then NextToken(T);
    Exit(TSqlAdminStmt.Create(admCloseDb));
  end;

  raise EVDbException.CreateFmt(ecSyntaxError, 'Bilinmeyen admin komutu: "%s %s"', [Kw1, Kw2]);
end;

{ ============================================================
  JSON (EXPORT / IMPORT)
  ============================================================ }

function TVDbParser.ParseJson(const Kw: string): TSqlJsonStmt;
var T: string;
begin
  // Kw = EXPORT veya IMPORT
  if UpperCase(Kw) = 'EXPORT' then
  begin
    Result := TSqlJsonStmt.Create(jsoExport);
    if PeekToken = 'TABLE' then
    begin
      NextToken(T); ExpectToken(T); Result.Table := VDbNorm(T);
    end;
    Expect('JSON');
    if PeekToken = 'TABLE' then
    begin
      NextToken(T); ExpectToken(T); Result.Table := VDbNorm(T);
    end;
    if TryEat('TO') then ;
    ExpectToken(Result.FilePath);
  end
  else // IMPORT
  begin
    Result := TSqlJsonStmt.Create(jsoImport);
    Expect('JSON');
    if TryEat('FROM') then ;
    ExpectToken(Result.FilePath);
  end;
end;

{ ============================================================
  Ana ayrıştırıcı: Parse
  ============================================================ }

function TVDbParser.ParseWith: TSqlStmtNode;
var
  T: string;
  W: TWithQuery;
  Main: TSqlStmtNode;
  Holder: TSqlSelectStmt;  // 4.5: holder for WITH + SELECT/INSERT/UPDATE/DELETE
  i: Integer;
  MainToken: string;
begin
  // Giriste 'WITH' yutuldu. CTE listesi once holder dugumde birikir,
  // sonra ana sorgu dugumune tasinir (SELECT/INSERT/UPDATE/DELETE).
  Holder := TSqlSelectStmt.Create; // CTE holder
  Result := Holder;
  try
    if PeekToken = 'RECURSIVE' then
    begin
      NextToken(T);
      W.IsRecursive := True;
    end
    else
      W.IsRecursive := False;
    repeat
      ExpectToken(T);
      W.Name := VDbNorm(T);
      W.Select := nil;
      if W.Name = '' then
        raise EVDbException.Create(ecSyntaxError,
          'WITH sonrasi CTE adi bekleniyor (' + CurPos + ')');
      // 4.5: kolon alias'lari (x(a,b)) — listeyi ColAliases'de tut.
      if PeekToken = '(' then
      begin
        NextToken(T); // (
        W.ColAliases := TStrArray([]);
        repeat
          ExpectToken(T);
          SetLength(W.ColAliases, Length(W.ColAliases) + 1);
          W.ColAliases[High(W.ColAliases)] := VDbNorm(T);
          if PeekToken <> ',' then Break;
          NextToken(T); // ,
        until False;
        Expect(')');
      end;
      Expect('AS');
      Expect('(');
      // 4.5: WITH + DML (SELECT, INSERT, UPDATE, DELETE).
      if (PeekToken <> 'SELECT') and (PeekToken <> 'INSERT') and
         (PeekToken <> 'UPDATE') and (PeekToken <> 'DELETE') then
        raise EVDbException.CreateFmt(ecSyntaxError,
          'AS sonrasi SELECT/INSERT/UPDATE/DELETE bekleniyor (%s)', [CurPos]);
      NextToken(T); // SELECT
      W.Select := ParseSelect;
      // R-10: govde `anchor UNION ALL recursive` seklinde olabilir
      // (ParseSelect SET OP'u kendi icine alir; burada ek gerek yok).
      Expect(')');
      // R-10: CYCLE <kolon> SET <is_cycle> USING <path>
      // Ana sorguya GECEDEN once okunmali; yoksa "CYCLE" ana sorguyu
      // bozmaya calisir ve "WITH yalnizca SELECT/..." hatasi verir.
      if PeekToken = 'CYCLE' then
      begin
        NextToken(T);
        ExpectToken(T); W.CycleCol := VDbNorm(T);
        Expect('SET');
        ExpectToken(T); W.IsCycleCol := VDbNorm(T);
        Expect('USING');
        ExpectToken(T); W.PathCol := VDbNorm(T);
      end;
      Holder.WithQueries.Add(W);
      W.Select := nil; // sahiplik listede
      if PeekToken <> ',' then Break;
      NextToken(T); // ','
    until False;
    // 4.5: Ana sorgu: WITH + SELECT / INSERT / UPDATE / DELETE.
    if (PeekToken <> 'SELECT') and (PeekToken <> 'INSERT') and
       (PeekToken <> 'UPDATE') and (PeekToken <> 'DELETE') then
      raise EVDbException.Create(ecUnsupported,
        'WITH yalnizca SELECT/INSERT/UPDATE/DELETE ile kullanilabilir');
    NextToken(T); // SELECT / INSERT / UPDATE / DELETE (DML 4.5 acik)
    MainToken := T;
    if MainToken = 'SELECT' then
      Main := ParseSelect
    else if MainToken = 'INSERT' then
      Main := ParseInsert
    else if MainToken = 'UPDATE' then
      Main := ParseUpdate
    else if MainToken = 'DELETE' then
      Main := ParseDelete
    else
      raise EVDbException.Create(ecSyntaxError,
        'WITH: beklenmeyen ana sorgu tipi: ' + MainToken);
    if MainToken = 'SELECT' then
      for i := 0 to Holder.WithQueries.Count - 1 do
        (Main as TSqlSelectStmt).WithQueries.Add(Holder.WithQueries[i])
    else if MainToken = 'INSERT' then
      for i := 0 to Holder.WithQueries.Count - 1 do
        (Main as TSqlInsertStmt).WithQueries.Add(Holder.WithQueries[i])
    else if MainToken = 'UPDATE' then
      for i := 0 to Holder.WithQueries.Count - 1 do
        (Main as TSqlUpdateStmt).WithQueries.Add(Holder.WithQueries[i])
    else if MainToken = 'DELETE' then
      for i := 0 to Holder.WithQueries.Count - 1 do
        (Main as TSqlDeleteStmt).WithQueries.Add(Holder.WithQueries[i]);
    // Kayitlar kopyalandi (sahiplik ana dugumde); holder bosaltilir,
    // yoksa ayni Select iki kez serbest kalir.
    Holder.WithQueries.Clear;
    Holder.Free;
    Result := Main;
  except
    if W.Select <> nil then W.Select.Free;
    Holder.Free;
    raise;
  end;
end;

function TVDbParser.Parse(const ASql: string;
                           const AParams: array of string): TSqlStmtNode;
var
  T, U, U2: string;
  i: Integer;
  idxStmt: TSqlCreateIndexStmt;
  savePos, saveIdx: Integer;   // R-18: CREATE/DROP ROLE ayrimi icin
  idxFirst: Boolean;   // F-18
  expStmt: TSqlExplainStmt;   // F-20
begin
  FSql := ASql;
  FLen := Length(ASql);
  FPos := 1;
  FParamIdx := 0;
  FDepth := 0;   // F1-22: derinlik sayaci sifirlanir
  FSuppressTail := False; // F1-12
  SetLength(FParams, Length(AParams));
  for i := 0 to High(AParams) do FParams[i] := AParams[i];

  if AtEnd then Exit(nil);

  ExpectToken(T); U := UpperCase(T);

  Result := nil;

  // ----
  if U = 'BEGIN'    then Result := TSqlTxStmt.Create(txBegin)
  else if U = 'COMMIT'   then Result := TSqlTxStmt.Create(txCommit)
  else if U = 'ROLLBACK' then
  begin
    if PeekToken = 'TO' then
    begin
      NextToken(T); // TO
      // SQL: `ROLLBACK TO [SAVEPOINT] name`. SAVEPOINT anahtar kelimesi
      // OPSIYONELdir; icra edilmeden ad olarak alinirsa
      // "ROLLBACK TO SAVEPOINT sp2" cumlesinde `sp2` ekde kalir ve
      // "anlasilamayan ek: sp2" hatasi verir.
      if PeekToken = 'SAVEPOINT' then NextToken(T); // SAVEPOINT (opsiyonel)
      ExpectToken(T);
      Result := TSqlTxStmt.Create(txRollbackTo);
      TSqlTxStmt(Result).SavepointName := VDbNorm(T);
    end
    else
      Result := TSqlTxStmt.Create(txRollback);
  end
  else if U = 'SAVEPOINT' then
  begin
    ExpectToken(T);
    Result := TSqlTxStmt.Create(txSavepoint);
    TSqlTxStmt(Result).SavepointName := VDbNorm(T);
  end
  else if U = 'RELEASE' then
  begin
    if PeekToken = 'SAVEPOINT' then
    begin
      NextToken(T); // SAVEPOINT
      ExpectToken(T);
      Result := TSqlTxStmt.Create(txReleaseSavepoint);
      TSqlTxStmt(Result).SavepointName := VDbNorm(T);
    end
    else
      raise EVDbException.Create(ecSyntaxError, 'RELEASE icin SAVEPOINT bekleniyor');
  end

  // ---- DML ----
  else if U = 'SELECT' then Result := ParseSelect
  else if U = 'WITH' then Result := ParseWith
  else if U = 'INSERT' then Result := ParseInsert
  else if U = 'UPDATE' then Result := ParseUpdate
  else if U = 'DELETE' then Result := ParseDelete
  // ---- F-20: EXPLAIN [ANALYZE] <cumle> ----
  else if U = 'EXPLAIN' then
  begin
    expStmt := TSqlExplainStmt.Create;
    try
      // ANALYZE opsiyonel (yalniz analiz sonrasi)
      if PeekToken = 'ANALYZE' then
      begin
        NextToken(T);
        expStmt.Analyze := True;
      end;
      // ic cumle: SELECT / WITH / INSERT / UPDATE / DELETE
      ExpectToken(T); U := UpperCase(T);
      if U = 'SELECT' then expStmt.Inner := ParseSelect
      else if U = 'WITH' then expStmt.Inner := ParseWith
      else if U = 'INSERT' then expStmt.Inner := ParseInsert
      else if U = 'UPDATE' then expStmt.Inner := ParseUpdate
      else if U = 'DELETE' then expStmt.Inner := ParseDelete
      else
      begin
        // DIKKAT: burada expStmt.Free YAPILMAZ; asagidaki except
        // bloğu zaten serbest birakir (cift free -> access violation).
        raise EVDbException.CreateFmt(ecSyntaxError,
          'EXPLAIN sonrasi SELECT/INSERT/UPDATE/DELETE bekleniyor, "%s" bulundu (%s)', [T, CurPos]);
      end;
      Result := expStmt;
      expStmt := nil;
    except
      expStmt.Free;
      raise;
    end;
  end

  // ---- DDL ----
  else if U = 'CREATE' then
  begin
  FLastMainToken := 'CREATE';
    ExpectToken(T); U2 := UpperCase(T);
    if U2 = 'TABLE'    then Result := ParseCreateTable
    else if U2 = 'FUNCTION' then Result := ParseCreateFunction
    else if U2 = 'PROCEDURE' then Result := ParseCreateProcedure
    else if U2 = 'TRIGGER' then Result := ParseCreateTrigger
    else if U2 = 'VIEW' then Result := ParseCreateView
    else if U2 = 'MATERIALIZED' then
    begin
      ExpectToken(T); U2 := UpperCase(T);
      if U2 <> 'VIEW' then
        raise EVDbException.CreateFmt(ecSyntaxError,
          'CREATE MATERIALIZED sonrasi "%s" bekleniyor (%s)', [T, CurPos]);
      Result := ParseCreateMaterializedView;
    end
    else if U2 = 'ROLE' then
    begin
      // ROLE token'i ParseRole icinde tüketilecek; burda tüketme!
      FPos := FPos - Length(T) - 1; FParamIdx := FParamIdx - 1; // geri sar
      Result := ParseRole;
    end
    else if U2 = 'POLICY' then
    begin
      // R-19: POLICY token'i BURADA tüketildi; ParsePolicy adla devam eder.
      Result := ParsePolicy;
    end
    else if (U2 = 'INDEX') or (U2 = 'UNIQUE') then
    begin
      // F2-23: UNIQUE bayragi motora tasinir (yoksa kisit hic zorlanmaz)
      if U2 = 'UNIQUE' then Expect('INDEX');
      idxStmt := TSqlCreateIndexStmt.Create;
      idxStmt.Uniq := U2 = 'UNIQUE';
      // R-22 Full: CREATE [UNIQUE] INDEX CONCURRENTLY — eszamanli insa
      // bayragi (burada tuketilmezse indeks ADI sanilirdi).
      if PeekToken = 'CONCURRENTLY' then
      begin
        NextToken(T);
        idxStmt.Concurrently := True;
      end;
      ExpectToken(T); idxStmt.IndexName := VDbNorm(T);
      Expect('ON');
      ExpectToken(T); idxStmt.Table := VDbNorm(T);
      Expect('(');
      // F-18: EXPRESSION INDEX — "CREATE INDEX ix ON t(LOWER(ad))".
      // Kolon listesi girdileri IFADE olarak ayristirilir. Sade bir kolon
      // referansi eski yola (cok kolonlu indeks) gider; diger her sey
      // ifade indeksidir ve yalniz TEK girdi kabul edilir.
      idxFirst := True;
      while True do
      begin
        if PeekToken = ')' then Break;   // "CREATE INDEX ix ON t()" -> bos
        // tek kolon mu? (niteliksiz, fonksiyon/operator icermeyen)
        if (PeekToken2 = ',') or (PeekToken2 = ')') then
        begin
          ExpectToken(T);
          SetLength(idxStmt.Cols, Length(idxStmt.Cols) + 1);
          idxStmt.Cols[High(idxStmt.Cols)] := VDbNorm(T);
        end
        else
        begin
          if not idxFirst then
            raise EVDbException.Create(ecUnsupported,
              'ifade indeksi tek ifade kabul eder (virgulle birden fazla ifade desteklenmez)');
          idxStmt.ExprNode := ParseExpr;
          idxStmt.ExprText := ExprToText(idxStmt.ExprNode);
          if idxStmt.ExprText = '' then
            raise EVDbException.Create(ecUnsupported,
              'indeks ifadesi desteklenmiyor');
        end;
        idxFirst := False;
        if PeekToken <> ',' then Break;
        NextToken(T);   // ','
      end;
      if (Length(idxStmt.Cols) = 0) and (idxStmt.ExprNode = nil) then
        raise EVDbException.Create(ecSyntaxError, 'indeks kolonu yok');
      // ifade indeksinde "ilk kolon" kavrami yoktur; adresleme sentetik
      // kullanacagindan Col = -1 birakilir.
      if Length(idxStmt.Cols) > 0 then
        idxStmt.Col := idxStmt.Cols[0]
      else
        idxStmt.Col := '';
      Expect(')');
      // F-19: COVERING INDEX — "CREATE INDEX ix ON t(a) INCLUDE (b, c)".
      // INCLUDE kolonlari ANAHTAR DEGILDIR: yalnizca indeks icinde tasinir.
      if PeekToken = 'INCLUDE' then
      begin
        NextToken(T);   // INCLUDE
        Expect('(');
        while True do
        begin
          ExpectToken(T);
          SetLength(idxStmt.Incl, Length(idxStmt.Incl) + 1);
          idxStmt.Incl[High(idxStmt.Incl)] := VDbNorm(T);
          if PeekToken <> ',' then Break;
          NextToken(T);
        end;
        Expect(')');
      end;
      // F-17: PARTIAL INDEX — "CREATE INDEX ix ON t(c) WHERE <kosul>".
      // Kosul AST olarak saklanir (yazma yolunda satir bazinda uygulanir).
      if PeekToken = 'WHERE' then
      begin
        NextToken(T);   // WHERE
        idxStmt.PredExpr := ParseExpr;
        idxStmt.Predicate := ExprToText(idxStmt.PredExpr);
      end;
      Result := idxStmt;
    end
    else if U2 = 'VIEW' then
    begin
      // 4.6: CREATE VIEW (basit parser acik; yurutucu sinirlidir)
      idxStmt := TSqlCreateIndexStmt.Create;
      idxStmt.Table := 'VIEW';
      Result := idxStmt;
    end
    else if U2 = 'DATABASE'  then Result := ParseAdmin('CREATE', 'DATABASE')
    else if U2 = 'REPLICATION' then Result := ParseAdmin('CREATE', 'REPLICATION')
    else if U2 = 'EXTENSION' then Result := ParseAdmin('CREATE', 'EXTENSION')
    else raise EVDbException.CreateFmt(ecSyntaxError, 'CREATE sonrasi bilinmeyen: "%s" (%s)', [T, CurPos]);
  end
  else if U = 'DROP' then
  begin
    ExpectToken(T); U2 := UpperCase(T);
    if U2 = 'TABLE'    then Result := ParseDropTable
    else if U2 = 'FUNCTION' then Result := ParseDropFunction
    else if U2 = 'PROCEDURE' then Result := ParseDropProcedure
    else if U2 = 'TRIGGER' then Result := ParseDropTrigger
    else if U2 = 'VIEW' then Result := ParseDropView
    else if U2 = 'MATERIALIZED' then
    begin
      ExpectToken(T); U2 := UpperCase(T);
      if U2 <> 'VIEW' then
        raise EVDbException.CreateFmt(ecSyntaxError,
          'DROP MATERIALIZED sonrasi "%s" bekleniyor (%s)', [T, CurPos]);
      Result := ParseDropMaterializedView;
    end
    else if U2 = 'INDEX'    then Result := ParseDropIndex
    else if U2 = 'DATABASE' then Result := ParseAdmin('DROP', 'DATABASE')
    else if U2 = 'REPLICATION' then Result := ParseAdmin('DROP', 'REPLICATION')
    else if U2 = 'EXTENSION' then Result := ParseAdmin('DROP', 'EXTENSION')
    else if U2 = 'ROLE' then begin FLastMainToken := 'DROP'; Result := ParseRole; end
    else if U2 = 'POLICY' then
    begin
      // R-19: POLICY token'i BURADA tüketildi.
      FLastMainToken := 'DROP';
      Result := ParsePolicy;
    end
    else raise EVDbException.CreateFmt(ecSyntaxError, 'DROP sonrasi bilinmeyen: "%s" (%s)', [T, CurPos]);
  end
  else if U = 'ALTER' then
  begin
    ExpectToken(T);
    if T = 'TABLE' then Result := ParseAlterTable
    else if T = 'DATABASE' then
    begin
      // 2026-10-05 Adim 15: ALTER DATABASE KEY 'parola'
      Expect('KEY'); ExpectToken(T);
      if (Length(T) >= 2) and ((T[1] = '''') or (T[1] = '"')) then
        T := Copy(T, 2, Length(T) - 2);
      if T = '' then
        raise EVDbException.Create(ecSyntaxError, 'ALTER DATABASE KEY: parola bos olamaz');
      Result := TSqlAdminStmt.Create(admAlterDbKey);
      (Result as TSqlAdminStmt).NewKeyPassword := T;
    end
    else raise EVDbException.CreateFmt(ecSyntaxError,
      'ALTER sonrasi bilinmeyen: "%s"', [T]);
  end

  // ---- Admin ----
  else if U = 'SET' then
  begin
    // R-11: SET CONSTRAINTS [ALL] DEFERRED | IMMEDIATE
    // F-40: SET [SESSION CHARACTERISTICS AS] TRANSACTION ISOLATION LEVEL ...
    U2 := UpperCase(PeekToken);
    if (U2 = 'TRANSACTION') or (U2 = 'SESSION') then
      Result := ParseSetIsolation
    else if U2 = 'CONSTRAINTS' then
    begin
      NextToken(T);   // CONSTRAINTS
      Result := ParseSetConstraints;
    end
    else
      raise EVDbException.CreateFmt(ecSyntaxError,
        'SET sonrasi CONSTRAINTS veya TRANSACTION bekleniyor, "%s" geldi (%s)',
        [U2, CurPos]);
  end
  // ---- R-18: RBAC ----
  else if U = 'GRANT' then begin FLastMainToken := U; Result := ParseGrant; end
  else if U = 'REVOKE' then begin FLastMainToken := U; Result := ParseGrant; end
  else if U = 'ROLE' then Result := ParseRole   // CREATE|DROP ROLE
  else if U = 'CALL' then Result := ParseCall
  else if U = 'RETURN' then Result := ParseReturn
  else if U = 'REFRESH' then
  begin
    // REFRESH MATERIALIZED VIEW [CONCURRENTLY] ad
    ExpectToken(T); U2 := UpperCase(T);
    if U2 <> 'MATERIALIZED' then
      raise EVDbException.CreateFmt(ecSyntaxError,
        'REFRESH sonrasi MATERIALIZED bekleniyor, "%s" geldi (%s)', [T, CurPos]);
    ExpectToken(T);
    if UpperCase(T) <> 'VIEW' then
      raise EVDbException.CreateFmt(ecSyntaxError,
        'REFRESH MATERIALIZED sonrasi VIEW bekleniyor, "%s" geldi (%s)', [T, CurPos]);
    Result := ParseRefreshMaterializedView;
  end
  else if U = 'VERIFY'  then Result := ParseAdmin('VERIFY', '')
  else if U = 'VACUUM'  then Result := ParseAdmin('VACUUM', '')
  else if U = 'REINDEX' then Result := ParseAdmin('REINDEX', '')
  // R-15 Full: CBO istatistik toplama
  else if U = 'ANALYZE' then Result := ParseAdmin('ANALYZE', '')
  // R-17: replikasyon komutlari (ikinci keyword tuketilir)
  else if U = 'START' then
  begin
    ExpectToken(T); Result := ParseAdmin('START', UpperCase(T));
  end
  else if U = 'STOP' then
  begin
    ExpectToken(T); Result := ParseAdmin('STOP', UpperCase(T));
  end
  else if U = 'PUMP' then
  begin
    ExpectToken(T); Result := ParseAdmin('PUMP', UpperCase(T));
  end
    else if (U = 'SHOW') or (U = 'LIST') then Result := ParseAdmin(U, '')
    // 2026-10-04: DESCRIBE / DESC takma adlari (sema sorgulari)
    else if (U = 'DESCRIBE') or (U = 'DESC') then Result := ParseAdmin(U, '')
  else if U = 'BACKUP'  then Result := ParseAdmin('BACKUP', '')
  // 4.6: PRAGMA (bilgi komutlari)
  else if U = 'PRAGMA'  then Result := ParseAdmin('PRAGMA', '')
// R-16: WAL arsivleme + PITR
else if U = 'RECOVER' then Result := ParseAdmin('RECOVER', '')
else if U = 'RESTORE' then Result := ParseAdmin('RESTORE', '')
else if U = 'ARCHIVE' then Result := ParseAdmin('ARCHIVE', '')
  else if (U = 'OPEN') or (U = 'USE') then Result := ParseAdmin(U, '')
  else if U = 'CLOSE'   then Result := ParseAdmin('CLOSE', '')

  // ---- JSON ----
  else if (U = 'EXPORT') or (U = 'IMPORT') then Result := ParseJson(U)
  else raise EVDbException.CreateFmt(ecSyntaxError, 'Bilinmeyen SQL komutu: "%s" (%s)', [T, CurPos]);

  // Artık token kontrolü (sorgu bittiğinde sonda açıklanamayan token kalmamalı)
  if (Result <> nil) and not AtEnd then
  begin
    NextToken(T);
    if (T <> ';') and (T <> '') then
    begin
      Result.Free;
      Result := nil;
      raise EVDbException.CreateFmt(ecSyntaxError, 'anlasilamayan ek: %s', [T]);
    end;
  end;
end;

end.
