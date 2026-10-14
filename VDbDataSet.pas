unit VDbDataSet;

{ VDb motoru icin TDataSet baglantisi (TVDbQuery).
  Standart veri bilesenleri (TDBGrid, TDBEdit, TDBNavigator, TDataSource,
  FastReport) TDataSet uzerinden konusur; bu birim o kopruyu kurar.

  Kullanim (runtime):
    Qry := TVDbQuery.Create(nil);
    try
      Qry.SqlEngine := Sq;               // hazir TVSql ornegi
      Qry.SQL.Text := 'SELECT id, ad FROM kisi ORDER BY id';
      Qry.Open;
      DataSource1.DataSet := Qry;        // DBGrid'e bagla
      ...
    finally
      Qry.Free;
    end;

  Ozellikler:
  - Salt-okunur gezilebilir imlec (First/Next/Prior/Last, RecNo,
    RecordCount, Bookmark, FieldByName).
  - Parametreli sorgu: SQL'deki '?' yer tutucularina Params sirayla
    karsilik gelir (bosken duz metin calisir).
  - Tipli alanlar: tek-tablo/sade sorgularda semadan gelir (ftLargeint,
    ftFloat, ftBoolean, ftDate/ftTime/ftDateTime); ifade/JOIN cikti
    kolonlari ftString duser. Tum degerler NULL icin '' tasir.
  - Duzenleme: tek tablo + sade kolonlar + ciktida PK sarti saglanirsa
    Insert/Edit/Post/Delete calisir (INSERT/UPDATE/DELETE'e cevrilir).
    PK degisimi yasaktir; AUTOINC PK bos birakilirsa motor uretir.
    Sart saglanmazsa CanModify=False olur (grid salt-okunur).

  Not: Open yalnizca satir donduren sonuclari kabul eder (SELECT, SHOW
  TABLES, LIST DATABASES...). INSERT/UPDATE/DELETE/DDL ile acmak
  EVDbException (ecInvalidArgument) verir. INSERT cumlesiyle Open
  denemesi cumleyi CALISTIRIR (yan etkili) ve sonra hata verir.
}

{$mode delphi}

interface

uses
  Classes, SysUtils, DB, VDbTypes, VDbTable, VDbSql, VDbAst, VDbParser, VDbErr;

type
  TVDbRecInfo = record
    Bookmark: Integer;       // satir indeksi (0-based)
    BookmarkFlag: TBookmarkFlag;
  end;
  PVDbRecInfo = ^TVDbRecInfo;

  TVDbQuery = class(TDataSet)
  private
    FSqlEngine: TVSql;
    FSQL: TStrings;
    FParams: TParams;         // '?' yer tutuculari (pozisyonel)
    FRows: TStrMatrix;       // aktif sonuc kumesi (bellekte)
    FFields: TStrArray;
    // Semadan gelen cikti-kolonu tipleri (VCT_*; bilinmiyorsa VCT_STR).
    FKinds: TByteArray;
    // Duzenlenebilirlik meta verisi.
    FEditCols: TStrArray;    // cikti kolonu basina GERCEK kolon adi ('' = ifade)
    FEditTable: string;
    FEditPkIdx: Integer;     // PK'nin cikti kolonu (yoksa -1)
    FUpdatable: Boolean;
    // Yazma tamponu (InternalEdit/Insert -> SetFieldData -> Post).
    FEditBuf: TStrArray;
    FEditTouched: array of Boolean;
    FEditOrigPk: string;
    FIsInsert: Boolean;
    // Post sonrasi konum duzeltmesi (base Resync eski tamponla
    // FCurrRec'i ezer; DoAfterPost'ta geri alinir).
    FPendRec: Integer;
    FCurrRec: Integer;       // -1 = BOF oncesi
    FOpen: Boolean;
    FFetched: Boolean;
    procedure SetSQL(AValue: TStrings);
    procedure SetParams(AValue: TParams);
    procedure SQLChanged(Sender: TObject);
    procedure EnsureFetched;
    function ParamValues: TStrArray;
    function CountPlaceholders(const S: string): Integer;
    procedure AnalyzeMeta;
    function CleanFieldName(const S: string; Idx: Integer): string;
  protected
    function GetCanModify: Boolean; override;
    function GetRecordCount: Integer; override;
    function GetRecNo: Integer; override;
    procedure SetRecNo(Value: Integer); override;
    function IsSequenced: Boolean; override;
    function IsCursorOpen: Boolean; override;
    function GetRecordSize: Word; override;
    function AllocRecordBuffer: TRecordBuffer; override;
    procedure FreeRecordBuffer(var Buffer: TRecordBuffer); override;
    procedure InternalInitRecord(Buffer: TRecordBuffer); override;
    procedure InternalInitFieldDefs; override;
    procedure InternalOpen; override;
    procedure InternalClose; override;
    procedure InternalFirst; override;
    procedure InternalLast; override;
    procedure InternalGotoBookmark(ABookmark: Pointer); override;
    procedure InternalSetToRecord(Buffer: TRecordBuffer); override;
    function GetRecord(Buffer: TRecordBuffer; GetMode: TGetMode;
      DoCheck: Boolean): TGetResult; override;
    function GetFieldData(Field: TField; Buffer: Pointer): Boolean; override;
    // Aktif tamponun satiri (Resync tamponlari gezdirir; FCurrRec'e
    // guvenilmez — memds ile ayni kural).
    function ActiveRow: Integer;
    // Yazma yolu (yalniz FUpdatable iken cagrilir).
    procedure SetFieldData(Field: TField; Buffer: Pointer); override;
    procedure InternalEdit; override;
    procedure InternalInsert; override;
    procedure InternalPost; override;
    procedure InternalCancel; override;
    procedure InternalDelete; override;
    procedure DoInsert(const Td: TTableDef);
    procedure DoUpdate;
    procedure DoAfterPost; override;
    function CurrentPk: string;
    function GetBookmarkFlag(Buffer: TRecordBuffer): TBookmarkFlag; override;
    procedure SetBookmarkFlag(Buffer: TRecordBuffer;
      Value: TBookmarkFlag); override;
    procedure GetBookmarkData(Buffer: TRecordBuffer; Data: Pointer); override;
    procedure SetBookmarkData(Buffer: TRecordBuffer; Data: Pointer); override;
    function BookmarkValid(ABookmark: TBookmark): Boolean; override;
    function CompareBookmarks(Bookmark1, Bookmark2: TBookmark): Longint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Son calisan sorgunun satir sayisi.
    function RowCount: Integer;
  published
    property SqlEngine: TVSql read FSqlEngine write FSqlEngine;
    property SQL: TStrings read FSQL write SetSQL;
    // SQL'deki '?' yer tutucularina sirayla karsilik gelir.
    // Bosken eski davranis (duz metin) aynen calisir.
    property Params: TParams read FParams write SetParams;
    property Active;
    property BeforeOpen; property AfterOpen;
    property BeforeClose; property AfterClose;
    property BeforeScroll; property AfterScroll;
    property OnCalcFields;
  end;

function VDbNativeToStr(DataType: TFieldType; Buffer: Pointer): string;

implementation

function VDbNativeToStr(DataType: TFieldType; Buffer: Pointer): string;
// SetFieldData ile gelen native tamponu motor metnine cevirir.
var
  D: TDateTime;
  Ts: TTimeStamp;
  Fs: TFormatSettings;
begin
  case DataType of
    ftLargeint, ftInteger, ftSmallint, ftWord, ftAutoInc:
      if DataType = ftLargeint then
        Result := IntToStr(PInt64(Buffer)^)
      else
        Result := IntToStr(PInteger(Buffer)^);
    ftFloat, ftCurrency:
      begin
        Fs := DefaultFormatSettings;
        Fs.DecimalSeparator := '.';
        Fs.ThousandSeparator := #0;
        Result := FloatToStr(PDouble(Buffer)^, Fs);
      end;
    ftBoolean:
      Result := BoolToStr(PWordBool(Buffer)^, True);
    ftDate:
      begin
        // Native rec: gun sayisi (TDateTimeRec.Date). ISO'ya cevir.
        Ts.Date := TDateTimeRec(Buffer^).Date;
        Ts.Time := 0;
        D := TimeStampToDateTime(Ts);
        Result := FormatDateTime('yyyy-mm-dd', D);
      end;
    ftTime:
      begin
        D := TDateTimeRec(Buffer^).Time / MSecsPerDay;
        Result := FormatDateTime('hh:nn:ss', D);
      end;
    ftDateTime:
      begin
        // Native rec: 1/1/0001'den beri ms (TimeStampToMSecs duzeni).
        D := TDateTimeRec(Buffer^).DateTime / MSecsPerDay - DateDelta;
        Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', D);
      end;
  else
    Result := string(PAnsiChar(Buffer));
  end;
end;

constructor TVDbQuery.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FSQL := TStringList.Create;
  TStringList(FSQL).OnChange := SQLChanged;
  FParams := TParams.Create(Self);
  FCurrRec := -1;
  FEditPkIdx := -1;
  FPendRec := -1;
  FUpdatable := False;
  FOpen := False;
  FFetched := False;
  // Bookmark = 4 bayt satir indeksi (TSQLQuery/memds ile ayni).
  BookmarkSize := SizeOf(Integer);
end;

destructor TVDbQuery.Destroy;
begin
  FParams.Free;
  FSQL.Free;
  inherited;
end;

procedure TVDbQuery.SetSQL(AValue: TStrings);
begin
  FSQL.Assign(AValue);
end;

procedure TVDbQuery.SetParams(AValue: TParams);
begin
  FParams.Assign(AValue);
end;

procedure TVDbQuery.SQLChanged(Sender: TObject);
begin
  // Metin degisince acik imlec varsa kapat; sonraki Open taze calisir.
  if Active then Close;
  FFetched := False;
end;

function TVDbQuery.GetCanModify: Boolean;
begin
  // Yalniz tek-tablo/sade/PK'li sorgular duzenlenebilir.
  Result := FUpdatable and FOpen;
end;

function TVDbQuery.IsSequenced: Boolean;
begin
  Result := True; // RecNo desteklenir (kayit sayisi bellekten bilinir)
end;

function TVDbQuery.IsCursorOpen: Boolean;
begin
  Result := FOpen;
end;

function TVDbQuery.GetRecordCount: Integer;
begin
  Result := Length(FRows);
end;

function TVDbQuery.GetRecNo: Integer;
begin
  // 1-based; BOF oncesi 0 doner (TDataSet sozlesmesi).
  if FCurrRec < 0 then Result := 0
  else Result := FCurrRec + 1;
end;

procedure TVDbQuery.SetRecNo(Value: Integer);
begin
  if (Value >= 1) and (Value <= Length(FRows)) then
  begin
    FCurrRec := Value - 1;
    Resync([rmExact, rmCenter]);
  end;
end;

function TVDbQuery.RowCount: Integer;
begin
  Result := Length(FRows);
end;

procedure TVDbQuery.EnsureFetched;
var
  R: TSqlResult;
  Vals: TStrArray;
  NMark: Integer;
begin
  if FFetched then Exit;
  if FSqlEngine = nil then
    raise EVDbException.Create(ecDatabaseNotOpen,
      'TVDbQuery.SqlEngine atanmamis (once TVSql ornegi ver)');
  if Trim(FSQL.Text) = '' then
    raise EVDbException.Create(ecSyntaxError,
      'TVDbQuery.SQL bos (once sorgu yaz)');
  if FParams.Count > 0 then
  begin
    // Yer tutucu sayisi ile parametre sayisi tutmalidir.
    NMark := CountPlaceholders(FSQL.Text);
    if NMark <> FParams.Count then
      raise EVDbException.Create(ecInvalidArgument,
        Format('TVDbQuery: ? sayisi (%d) parametre sayisina (%d) esit degil',
          [NMark, FParams.Count]));
    Vals := ParamValues;
    R := FSqlEngine.Exec(FSQL.Text, Vals);
  end
  else
    R := FSqlEngine.Exec(FSQL.Text);
  if Length(R.Fields) = 0 then
    raise EVDbException.Create(ecInvalidArgument,
      'TVDbQuery.Open satir donduren bir sonuc gerektirir ' +
      '(SELECT / SHOW TABLES / LIST DATABASES); son cumle satir dondurmedi');
  FFields := R.Fields;
  FRows := R.Rows;
  FFetched := True;
  // Tip/duzenlenebilirlik cozumlemesi; basarisizsa sessizce
  // metin kipine dus (calisan sorgu asla bu yuzden bozulmaz).
  try
    AnalyzeMeta;
  except
    SetLength(FKinds, 0);
    SetLength(FEditCols, 0);
    SetLength(FEditBuf, 0);
    SetLength(FEditTouched, 0);
    FUpdatable := False;
    FEditTable := '';
    FEditPkIdx := -1;
  end;
end;

function TVDbQuery.ParamValues: TStrArray;
// TParams -> motorun bekledigi string dizisi (NULL = '').
var
  i: Integer;
begin
  SetLength(Result, FParams.Count);
  for i := 0 to FParams.Count - 1 do
    if FParams[i].IsNull then
      Result[i] := ''
    else
      Result[i] := FParams[i].AsString;
end;

function TVDbQuery.CountPlaceholders(const S: string): Integer;
// Tirnak ici '?' sayilmaz; '' kacisli tirnak atlanir (motor Tok ile ayni).
var
  i: Integer;
  InStr: Boolean;
begin
  Result := 0;
  InStr := False;
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = '''' then
    begin
      if InStr and (i < Length(S)) and (S[i + 1] = '''') then
        Inc(i, 2)
      else
      begin
        InStr := not InStr;
        Inc(i);
      end;
      Continue;
    end;
    if (not InStr) and (S[i] = '?') then
      Inc(Result);
    Inc(i);
  end;
end;

procedure TVDbQuery.AnalyzeMeta;
// Gercek ayristiriciyla (VDbParser) tek-tablo/sade sorgu tespiti:
// tipler (FKinds) her zaman doldurulur; siki sart saglanirsa
// FUpdatable/FEditTable/FEditCols/FEditPkIdx de doldurulur.
var
  Stmts: TStrArray;
  LastSql: string;
  i: Integer;
  Parser: TVDbParser;
  Node: TSqlStmtNode;
  Sel: TSqlSelectStmt;
  Td: TTableDef;
  Col: TColDef;
  Ref: TSqlColumnRefNode;
  Fn: TSqlFuncCallNode;
  QualOk: Boolean;

  function FindCol(const Nm: string): Integer;
  var
    k: Integer;
  begin
    Result := -1;
    for k := 0 to High(Td.Cols) do
      if SameText(Td.Cols[k].Name, Nm) then
        Exit(k);
  end;

begin
  SetLength(FKinds, Length(FFields));
  for i := 0 to High(FKinds) do
    FKinds[i] := VCT_STR;
  SetLength(FEditCols, 0);
  FUpdatable := False;
  FEditTable := '';
  FEditPkIdx := -1;
  if FSqlEngine.TableDb = nil then Exit;
  // Betikte son cumle gecerlidir (Exec ayni kuralla calisir).
  Stmts := FSqlEngine.SplitStatements(FSQL.Text);
  if Length(Stmts) = 0 then Exit;
  LastSql := Stmts[High(Stmts)];
  Parser := TVDbParser.Create;
  try
    Node := Parser.Parse(LastSql, ParamValues);
    try
      if not (Node is TSqlSelectStmt) then Exit;
      Sel := TSqlSelectStmt(Node);
      if (Sel.FromTable = '') or Sel.HasJoin then Exit;
      if (Sel.GroupByCols.Count > 0) or (Sel.HavingClause <> nil) then Exit;
      if (Sel.SetOp <> sokNone) or Sel.IsDistinct then Exit;
      try
        Td := FSqlEngine.TableDb.GetTable(Sel.FromTable);
      except
        Exit; // tablo yoksa Exec zaten hata vermistir; burada sessiz dus
      end;
      FEditTable := Td.Name;
      if (Sel.Columns.Count > 0) and
         (Sel.Columns.Count <> Length(FFields)) then Exit;
      // Yildiz (Columns bos): cikti = sema sirasi.
      if Sel.Columns.Count = 0 then
      begin
        if Length(FFields) <> Length(Td.Cols) then Exit;
        for i := 0 to High(Td.Cols) do
          FKinds[i] := Td.Cols[i].Ctype;
      end
      else
        for i := 0 to Sel.Columns.Count - 1 do
        begin
          if Sel.Columns[i].Expr is TSqlColumnRefNode then
          begin
            Ref := TSqlColumnRefNode(Sel.Columns[i].Expr);
            QualOk := (Ref.TableQualifier = '') or
              SameText(Ref.TableQualifier, Td.Name) or
              SameText(Ref.TableQualifier, Sel.FromAlias);
            if not QualOk then Exit;
            if FindCol(Ref.ColumnName) < 0 then Exit;
            Col := Td.Cols[FindCol(Ref.ColumnName)];
            FKinds[i] := Col.Ctype;
          end
          else if Sel.Columns[i].Expr is TSqlFuncCallNode then
          begin
            Fn := TSqlFuncCallNode(Sel.Columns[i].Expr);
            // COUNT(*) tamsayi doner; diger agregalar metin kalir.
            if SameText(Fn.FuncName, 'COUNT') then
              FKinds[i] := VCT_INT
            else
              FKinds[i] := VCT_STR;
          end
          else
            FKinds[i] := VCT_STR;
        end;
      // Gercek kolon adlari + siki duzenlenebilirlik kurali.
      // Yildizda hepsi eslenir; listede yalniz sade kolon referanslari.
      // Ifade/agrega ciktisi ('') veya ciktida olmayan PK -> salt-okunur.
      SetLength(FEditCols, Length(FFields));
      for i := 0 to High(FEditCols) do
        FEditCols[i] := '';
      if Sel.Columns.Count = 0 then
      begin
        for i := 0 to High(Td.Cols) do
          FEditCols[i] := Td.Cols[i].Name;
      end
      else
        for i := 0 to Sel.Columns.Count - 1 do
          if Sel.Columns[i].Expr is TSqlColumnRefNode then
          begin
            Ref := TSqlColumnRefNode(Sel.Columns[i].Expr);
            QualOk := (Ref.TableQualifier = '') or
              SameText(Ref.TableQualifier, Td.Name) or
              SameText(Ref.TableQualifier, Sel.FromAlias);
            if QualOk and (FindCol(Ref.ColumnName) >= 0) then
              FEditCols[i] := Td.Cols[FindCol(Ref.ColumnName)].Name;
          end;
      if Td.PkIndex >= 0 then
        for i := 0 to High(FEditCols) do
          if SameText(FEditCols[i], Td.Cols[Td.PkIndex].Name) then
          begin
            FEditPkIdx := i;
            Break;
          end;
      FUpdatable := FEditPkIdx >= 0;
      if FUpdatable then
        for i := 0 to High(FEditCols) do
          if FEditCols[i] = '' then
          begin
            FUpdatable := False; // ifade/agrega ciktisi yazilamaz
            Break;
          end;
    finally
      Node.Free;
    end;
  finally
    Parser.Free;
  end;
end;

function TVDbQuery.CleanFieldName(const S: string; Idx: Integer): string;
var
  i: Integer;
  Base: string;
begin
  Base := Trim(S);
  if Base = '' then Base := 'FIELD' + IntToStr(Idx + 1);
  // Ayni ad iki kez gelirse (SELECT a, a) tekillestir.
  Result := Base;
  i := 2;
  while FieldDefs.IndexOf(Result) >= 0 do
  begin
    Result := Base + '_' + IntToStr(i);
    Inc(i);
  end;
end;

procedure TVDbQuery.InternalInitFieldDefs;
var
  i, j, MaxLen: Integer;
  K: Byte;
begin
  EnsureFetched;
  FieldDefs.Clear;
  for i := 0 to High(FFields) do
  begin
    if i < Length(FKinds) then K := FKinds[i] else K := VCT_STR;
    case K of
      VCT_INT:
        TFieldDef.Create(FieldDefs, CleanFieldName(FFields[i], i),
          ftLargeint, 0, False, i + 1);
      VCT_FLOAT:
        TFieldDef.Create(FieldDefs, CleanFieldName(FFields[i], i),
          ftFloat, 0, False, i + 1);
      VCT_BOOL:
        TFieldDef.Create(FieldDefs, CleanFieldName(FFields[i], i),
          ftBoolean, 0, False, i + 1);
      VCT_DATE:
        TFieldDef.Create(FieldDefs, CleanFieldName(FFields[i], i),
          ftDate, 0, False, i + 1);
      VCT_DATETIME:
        TFieldDef.Create(FieldDefs, CleanFieldName(FFields[i], i),
          ftDateTime, 0, False, i + 1);
      VCT_TIME:
        TFieldDef.Create(FieldDefs, CleanFieldName(FFields[i], i),
          ftTime, 0, False, i + 1);
    else
      // VCT_STR / VCT_BLOB / bilinmeyen: metin (boy = en uzun deger,
      // en az 1, en cok 4096; satir yoksa 255).
      MaxLen := 0;
      for j := 0 to High(FRows) do
        if (i < Length(FRows[j])) and (Length(FRows[j][i]) > MaxLen) then
          MaxLen := Length(FRows[j][i]);
      if MaxLen < 1 then MaxLen := 1;
      if MaxLen > 4096 then MaxLen := 4096;
      if Length(FRows) = 0 then MaxLen := 255;
      TFieldDef.Create(FieldDefs, CleanFieldName(FFields[i], i),
        ftString, MaxLen, False, i + 1);
    end;
  end;
end;

procedure TVDbQuery.InternalOpen;
begin
  EnsureFetched;
  // Alan kurulus sira: tanimlar -> (varsayilansa) alan nesneleri -> bagla.
  // (FPC TDataSet bunu kendisi yapmaz; tum somut kume bilesenleri
  // InternalOpen icinde aynisini yapar: bkz. memds/sqldb.)
  InternalInitFieldDefs;
  if DefaultFields then
    CreateFields;
  BindFields(True);
  FCurrRec := -1;
  FOpen := True;
end;

procedure TVDbQuery.InternalClose;
begin
  SetLength(FRows, 0);
  SetLength(FFields, 0);
  FCurrRec := -1;
  FPendRec := -1;
  FOpen := False;
  FFetched := False;
  // Otomatik uretilen alanlari kaldir; sonraki Open farkli SQL ile
  // taze kurar (TSQLQuery.InternalClose ile ayni desen). Yoksa eski
  // alanlar yeni FieldDefs'e baglanamaz ('Field not found').
  if DefaultFields then
    DestroyFields;
end;

procedure TVDbQuery.InternalFirst;
begin
  FCurrRec := -1;
end;

procedure TVDbQuery.InternalLast;
begin
  FCurrRec := Length(FRows);
end;

procedure TVDbQuery.InternalGotoBookmark(ABookmark: Pointer);
var
  Req: Integer;
begin
  Req := PInteger(ABookmark)^;
  if (Req >= 0) and (Req < Length(FRows)) then
    FCurrRec := Req
  else
    raise EVDbException.Create(ecInvalidArgument,
      'TVDbQuery: bookmark aralik disi (' + IntToStr(Req) + ')');
end;

procedure TVDbQuery.InternalSetToRecord(Buffer: TRecordBuffer);
begin
  InternalGotoBookmark(@PVDbRecInfo(Buffer)^.Bookmark);
end;

function TVDbQuery.GetRecord(Buffer: TRecordBuffer; GetMode: TGetMode;
  DoCheck: Boolean): TGetResult;
begin
  Result := grOK;
  case GetMode of
    gmCurrent:
      if (FCurrRec < 0) or (FCurrRec >= Length(FRows)) then
        Result := grError;
    gmNext:
      if FCurrRec < Length(FRows) - 1 then
        Inc(FCurrRec)
      else
        Result := grEOF;
    gmPrior:
      if FCurrRec > 0 then
        Dec(FCurrRec)
      else
        Result := grBOF;
  end;
  if (Result = grOK) and (Length(FRows) = 0) then
    Result := grEOF;
  if Result = grOK then
  begin
    PVDbRecInfo(Buffer)^.Bookmark := FCurrRec;
    PVDbRecInfo(Buffer)^.BookmarkFlag := bfCurrent;
  end;
end;

function TVDbQuery.ActiveRow: Integer;
var
  B: TRecordBuffer;
begin
  Result := -1;
  // Insert sirasinda bos satir goster (duzenlenen FEditBuf Post'ta yazilir).
  if State = dsInsert then Exit;
  if Active then
  begin
    B := ActiveBuffer;
    if B <> nil then
    begin
      Result := PVDbRecInfo(B)^.Bookmark;
      if (Result < 0) or (Result >= Length(FRows)) then
        Result := -1;
    end;
  end;
  if (Result < 0) and (FCurrRec >= 0) and (FCurrRec < Length(FRows)) then
    Result := FCurrRec;
end;

function TVDbQuery.GetFieldData(Field: TField; Buffer: Pointer): Boolean;
var
  S: string;
  K: Byte;
  Row: Integer;
  I64: Int64;
  F: Double;
  D: TDateTime;

  function DotFloat(const V: string; out R: Double): Boolean;
  var
    Lfs: TFormatSettings;
  begin
    Lfs := DefaultFormatSettings;
    Lfs.DecimalSeparator := '.'; // motor ciktisi her locale'de nokta
    Lfs.ThousandSeparator := #0;
    Result := TryStrToFloat(V, R, Lfs);
  end;

  function IsoDate(const V: string; out R: TDateTime): Boolean;
  var
    Lfs: TFormatSettings;
  begin
    Lfs := DefaultFormatSettings;
    Lfs.DateSeparator := '-';
    Lfs.ShortDateFormat := 'yyyy-mm-dd';
    Result := TryStrToDate(V, R, Lfs);
  end;

  function IsoTime(const V: string; out R: TDateTime): Boolean;
  var
    Lfs: TFormatSettings;
  begin
    Lfs := DefaultFormatSettings;
    Lfs.TimeSeparator := ':';
    Lfs.LongTimeFormat := 'hh:nn:ss';
    Result := TryStrToTime(V, R, Lfs);
  end;

  function IsoDateTime(const V: string; out R: TDateTime): Boolean;
  var
    Lfs: TFormatSettings;
  begin
    Lfs := DefaultFormatSettings;
    Lfs.DateSeparator := '-';
    Lfs.TimeSeparator := ':';
    Lfs.ShortDateFormat := 'yyyy-mm-dd';
    Lfs.LongTimeFormat := 'hh:nn:ss';
    Result := TryStrToDateTime(V, R, Lfs);
  end;

begin
  Result := False;
  Row := ActiveRow;
  if (Field = nil) or (Row < 0) then
    Exit;
  if (Field.FieldNo < 1) or (Field.FieldNo > Length(FRows[Row])) then
    Exit;
  // Motor NULL'u '' olarak tasir: bos = NULL.
  S := FRows[Row][Field.FieldNo - 1];
  if S = '' then Exit;
  if (Field.FieldNo - 1) < Length(FKinds) then
    K := FKinds[Field.FieldNo - 1]
  else
    K := VCT_STR;
  if (Buffer = nil) then
  begin
    Result := True; // yalnizca NULL denetimi
    Exit;
  end;
  case K of
    VCT_INT:
      if TryStrToInt64(S, I64) then
      begin
        case Field.DataType of
          ftLargeint: PInt64(Buffer)^ := I64;
          ftInteger: PInteger(Buffer)^ := Integer(I64);
        else
          StrLCopy(PAnsiChar(Buffer), PAnsiChar(AnsiString(S)),
            Field.DataSize - 1);
        end;
        Result := True;
      end;
    VCT_FLOAT:
      if DotFloat(S, F) then
      begin
        PDouble(Buffer)^ := F;
        Result := True;
      end;
    VCT_BOOL:
      begin
        PWordBool(Buffer)^ := SameText(S, 'True') or (S = '1');
        Result := True;
      end;
    VCT_DATE:
      if IsoDate(S, D) then
      begin
        TDateTimeRec(Buffer^).Date := DateTimeToTimeStamp(D).Date;
        Result := True;
      end;
    VCT_DATETIME:
      if IsoDateTime(S, D) then
      begin
        TDateTimeRec(Buffer^).DateTime := TimeStampToMSecs(DateTimeToTimeStamp(D));
        Result := True;
      end;
    VCT_TIME:
      if IsoTime(S, D) then
      begin
        TDateTimeRec(Buffer^).Time := DateTimeToTimeStamp(D).Time;
        Result := True;
      end;
  else
    StrLCopy(PAnsiChar(Buffer), PAnsiChar(AnsiString(S)),
      Field.DataSize - 1);
    Result := True;
  end;
end;

function TVDbQuery.CurrentPk: string;
begin
  Result := '';
  if (FEditPkIdx >= 0) and (FCurrRec >= 0) and
     (FCurrRec < Length(FRows)) and
     (FEditPkIdx < Length(FRows[FCurrRec])) then
    Result := FRows[FCurrRec][FEditPkIdx];
end;

procedure TVDbQuery.InternalEdit;
begin
  if not FUpdatable then
    raise EVDbException.Create(ecUnsupported,
      'TVDbQuery: bu sorgu duzenlenemez (tek tablo, sade kolonlar, PK sart)');
  if (FCurrRec < 0) or (FCurrRec >= Length(FRows)) then
    raise EVDbException.Create(ecInvalidArgument,
      'TVDbQuery: duzenlenecek satir yok');
  FEditBuf := Copy(FRows[FCurrRec]);
  SetLength(FEditTouched, Length(FEditBuf));
  if Length(FEditTouched) > 0 then
    FillChar(FEditTouched[0], Length(FEditTouched) * SizeOf(Boolean), 0);
  FEditOrigPk := CurrentPk;
  FIsInsert := False;
end;

procedure TVDbQuery.InternalInsert;
var
  i: Integer;
begin
  if not FUpdatable then
    raise EVDbException.Create(ecUnsupported,
      'TVDbQuery: bu sorguya ekleme yapilamaz (tek tablo, sade kolonlar, PK sart)');
  SetLength(FEditBuf, Length(FFields));
  for i := 0 to High(FEditBuf) do
    FEditBuf[i] := '';
  SetLength(FEditTouched, Length(FEditBuf));
  if Length(FEditTouched) > 0 then
    FillChar(FEditTouched[0], Length(FEditTouched) * SizeOf(Boolean), 0);
  FEditOrigPk := '';
  FIsInsert := True;
end;

procedure TVDbQuery.InternalCancel;
begin
  SetLength(FEditBuf, 0);
  SetLength(FEditTouched, 0);
  FEditOrigPk := '';
  FIsInsert := False;
end;

procedure TVDbQuery.SetFieldData(Field: TField; Buffer: Pointer);
begin
  if (Field = nil) or (Length(FEditBuf) = 0) then Exit;
  if (Field.FieldNo < 1) or (Field.FieldNo > Length(FEditBuf)) then Exit;
  if Buffer = nil then
    FEditBuf[Field.FieldNo - 1] := '' // NULL
  else
    FEditBuf[Field.FieldNo - 1] :=
      VDbNativeToStr(Field.DataType, Buffer);
  FEditTouched[Field.FieldNo - 1] := True;
end;

procedure TVDbQuery.InternalPost;
var
  Td: TTableDef;
begin
  Td := FSqlEngine.TableDb.GetTable(FEditTable);
  if not FUpdatable then
    raise EVDbException.Create(ecUnsupported,
      'TVDbQuery: bu sorguya yazilamaz');
  if Length(FEditBuf) = 0 then
    raise EVDbException.Create(ecInvalidArgument,
      'TVDbQuery: yazma tamponu bos (once Edit/Insert)');
  // Butun yazma tek kilit altinda (P3): INSERT+MAX arasi yaris olmaz.
  FSqlEngine.TableDb.Lock;
  try
    if FIsInsert then
      DoInsert(Td)
    else
      DoUpdate;
  finally
    FSqlEngine.TableDb.Unlock;
  end;
  InternalCancel;
end;

procedure TVDbQuery.DoInsert(const Td: TTableDef);
var
  i, n: Integer;
  Cols, Marks: string;
  Vals: TStrArray;
  NewPk: string;
  R: TSqlResult;
  NewRow: TStrArray;
begin
  // INSERT: yalniz dokunulan kolonlar (degilmeyen DEFAULT'lar motora kalir;
  // bos PK (AUTOINC) listeden duser, motor uretir).
  Cols := '';
  Marks := '';
  SetLength(Vals, 0);
  for i := 0 to High(FEditCols) do
  begin
    if (FEditCols[i] = '') or not FEditTouched[i] then Continue;
    if (i = FEditPkIdx) and (FEditBuf[i] = '') and
       (Td.PkIndex >= 0) and (Td.Cols[Td.PkIndex].Ctype = VCT_INT) then
      Continue;
    if Cols <> '' then begin Cols += ','; Marks += ','; end;
    Cols += FEditCols[i];
    Marks += '?';
    n := Length(Vals);
    SetLength(Vals, n + 1);
    Vals[n] := FEditBuf[i];
  end;
  if Cols = '' then
    raise EVDbException.Create(ecInvalidArgument,
      'TVDbQuery: eklenecek deger yok (once alan doldur)');
  FSqlEngine.Exec(
    Format('INSERT INTO %s(%s) VALUES(%s)', [FEditTable, Cols, Marks]), Vals);
  NewPk := '';
  if FEditPkIdx < Length(FEditBuf) then
    NewPk := FEditBuf[FEditPkIdx];
  if NewPk = '' then
  begin
    // AUTOINC uretimi: kilit bizdeyken MAX(pk) bizim satirdir.
    R := FSqlEngine.Exec(Format('SELECT MAX(%s) AS m FROM %s',
      [Td.Cols[Td.PkIndex].Name, FEditTable]));
    if Length(R.Rows) > 0 then
      NewPk := R.Rows[0][0];
  end;
  // Kumeye yerel ekle (Close/Open yok, konum yeni satirda kalir).
  SetLength(NewRow, Length(FFields));
  for i := 0 to High(NewRow) do
    if i = FEditPkIdx then
      NewRow[i] := NewPk
    else if i < Length(FEditBuf) then
      NewRow[i] := FEditBuf[i]
    else
      NewRow[i] := '';
  n := Length(FRows);
  SetLength(FRows, n + 1);
  FRows[n] := NewRow;
  FCurrRec := n;
  FPendRec := n; // Post kuyrugundaki Resync eski tamponla ezer; DoAfterPost duzeltir
end;

procedure TVDbQuery.DoUpdate;
var
  i, n: Integer;
  Sets: string;
  Vals: TStrArray;
begin
  // UPDATE: dokunulan PK-disi kolonlar, WHERE PK=orijinal.
  // PK degisimi acikca yasaktir (sessiz dusurme yok).
  if (FEditPkIdx < Length(FEditTouched)) and FEditTouched[FEditPkIdx] then
    raise EVDbException.Create(ecUnsupported,
      'TVDbQuery: PK guncellenemez (once satiri silip yeniden ekle)');
  Sets := '';
  SetLength(Vals, 0);
  for i := 0 to High(FEditCols) do
  begin
    if (FEditCols[i] = '') or (i = FEditPkIdx) or
       not FEditTouched[i] then Continue;
    if Sets <> '' then Sets += ',';
    Sets += FEditCols[i] + '=?';
    n := Length(Vals);
    SetLength(Vals, n + 1);
    Vals[n] := FEditBuf[i];
  end;
  if Sets = '' then Exit; // degisen yok: sessiz basari
  n := Length(Vals);
  SetLength(Vals, n + 1);
  Vals[n] := FEditOrigPk;
  FSqlEngine.Exec(Format('UPDATE %s SET %s WHERE %s=?',
    [FEditTable, Sets, FEditCols[FEditPkIdx]]), Vals);
  // Yerel kopyayi guncelle (konum korunur).
  if (FCurrRec >= 0) and (FCurrRec < Length(FRows)) then
    for i := 0 to High(FEditBuf) do
      if (i < Length(FRows[FCurrRec])) and FEditTouched[i] then
        FRows[FCurrRec][i] := FEditBuf[i];
end;

procedure TVDbQuery.DoAfterPost;
var
  B: TRecordBuffer;
begin
  inherited;
  if FPendRec >= 0 then
  begin
    try
      // RecNo atamak ikinci bir Resync turu baslatir ve tampon
      // rotasyonu damgalari yine kaydirir. Bunun yerine imleci ve
      // AKTIF tamponun damgasini dogrudan duzelt (kaydirma sirasinda
      // GetRecord diger tamponlari zaten dogru damgalar).
      if (FPendRec >= 0) and (FPendRec < Length(FRows)) then
      begin
        FCurrRec := FPendRec;
        B := ActiveBuffer;
        if B <> nil then
        begin
          PVDbRecInfo(B)^.Bookmark := FPendRec;
          PVDbRecInfo(B)^.BookmarkFlag := bfCurrent;
        end;
      end;
    finally
      FPendRec := -1;
    end;
  end;
end;

procedure TVDbQuery.InternalDelete;
var
  i: Integer;
begin
  if not FUpdatable then
    raise EVDbException.Create(ecUnsupported,
      'TVDbQuery: bu sorgudan silinemez');
  if (FCurrRec < 0) or (FCurrRec >= Length(FRows)) then
    raise EVDbException.Create(ecInvalidArgument,
      'TVDbQuery: silinecek satir yok');
  FSqlEngine.Exec(Format('DELETE FROM %s WHERE %s=?',
    [FEditTable, FEditCols[FEditPkIdx]]), [CurrentPk]);
  for i := FCurrRec to High(FRows) - 1 do
    FRows[i] := FRows[i + 1];
  SetLength(FRows, Length(FRows) - 1);
  if (Length(FRows) = 0) then
    FCurrRec := -1
  else if FCurrRec > High(FRows) then
    FCurrRec := High(FRows);
end;

function TVDbQuery.GetRecordSize: Word;
begin
  Result := SizeOf(TVDbRecInfo);
end;

function TVDbQuery.AllocRecordBuffer: TRecordBuffer;
begin
  GetMem(Result, SizeOf(TVDbRecInfo));
end;

procedure TVDbQuery.FreeRecordBuffer(var Buffer: TRecordBuffer);
begin
  FreeMem(Buffer);
end;

procedure TVDbQuery.InternalInitRecord(Buffer: TRecordBuffer);
begin
  FillChar(Buffer^, SizeOf(TVDbRecInfo), 0);
end;

function TVDbQuery.GetBookmarkFlag(Buffer: TRecordBuffer): TBookmarkFlag;
begin
  Result := PVDbRecInfo(Buffer)^.BookmarkFlag;
end;

procedure TVDbQuery.SetBookmarkFlag(Buffer: TRecordBuffer;
  Value: TBookmarkFlag);
begin
  PVDbRecInfo(Buffer)^.BookmarkFlag := Value;
end;

procedure TVDbQuery.GetBookmarkData(Buffer: TRecordBuffer; Data: Pointer);
begin
  if Data <> nil then
    PInteger(Data)^ := PVDbRecInfo(Buffer)^.Bookmark;
end;

procedure TVDbQuery.SetBookmarkData(Buffer: TRecordBuffer; Data: Pointer);
begin
  if Data <> nil then
    PVDbRecInfo(Buffer)^.Bookmark := PInteger(Data)^
  else
    PVDbRecInfo(Buffer)^.Bookmark := 0;
end;

function TVDbQuery.BookmarkValid(ABookmark: TBookmark): Boolean;
begin
  Result := (ABookmark <> nil) and (PInteger(ABookmark)^ >= 0) and
    (PInteger(ABookmark)^ < Length(FRows));
end;

function TVDbQuery.CompareBookmarks(Bookmark1, Bookmark2: TBookmark): Longint;
begin
  if (Bookmark1 = nil) or (Bookmark2 = nil) then
    Result := 1
  else
    Result := PInteger(Bookmark1)^ - PInteger(Bookmark2)^;
end;

end.
