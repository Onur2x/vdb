program ornek12_milyon;

{ =====================================================================
  VDB ORNEK 12 — 1.000.000 KAYITLI DETAYLI GUI DEMO
  VDB EXAMPLE 12 — DETAILED GUI DEMO WITH 1,000,000 ROWS
  =====================================================================

  TR: Bu ornek, VDB motorunu gercek bir masaustu uygulamasinda gosterir:
      - 1.000.000 kayitli "vdb_buyuk" tablosu (ilk acilista uretir)
      - Gercek TDBGrid + sayfalama (filtresiz ID sirasinda PK araligi)
      - Ad, sehir, yas ve bakiye filtreleri
      - Sutun basligina tiklayarak siralama
      - Secili kaydin detay paneli
      - Sehir bazli ozet (GROUP BY / AVG)
      - Yeni kayit, silme ve CSV disa aktarma
      - TR/EN arayuz

  EN: This example shows VDB in a real desktop application:
      - "vdb_buyuk" table with 1,000,000 rows (seeded on first open)
      - Real TDBGrid + pagination (PK range for unfiltered ID order)
      - Name, city, age and balance filters
      - Click a column title to sort
      - Selected-row detail panel
      - City summary (GROUP BY / AVG)
      - Insert, delete and CSV export
      - TR/EN UI

  Kullanim / Usage:
    1) Uygulamayi acin; tablo yoksa 1M kayit uretme onayi gelir.
    2) Filtreleri doldurup "Filtrele" deyin.
    3) Sayfa boyutunu ve siralama sutununu degistirin.
    4) Grid'de bir satir secin; sag panelde detayi ve SQL'i gorun.
    5) "Ozet" ile sehir dagilimini yenileyin.
    6) "CSV" ile gorunen sayfayi disa aktarin.

  Ilk uretim gelistirme makinesinde ~45-70 saniye surdu; disk hizina gore
  degisebilir. Sonraki acilislar hazir veritabanini kullanir.

  Derleme / Build:
    lazbuild ornek12.lpi

  Hizli veri testi / Quick data smoke test:
    ornek12.exe --seed-only 100000
  ===================================================================== }

{$mode delphi}{$H+}

uses
  Interfaces, // LCL widgetset
  Classes, SysUtils, DateUtils, Forms, Controls, Graphics, Dialogs, StdCtrls,
  ExtCtrls, ComCtrls, DB, DBCtrls, DBGrids, Grids,
  VDbCore, VDbTable, VDbSql, VDbAst, VDbDataSet;

const
  DEMO_TABLE = 'vdb_buyuk';
  DEMO_ROWS  = 1000000;
  DEMO_BATCH = 1000;

  FirstNames: array[0..11] of string = (
    'Ali', 'Ayse', 'Mehmet', 'Fatma', 'Mustafa', 'Zeynep',
    'Ahmet', 'Elif', 'Emre', 'Merve', 'Can', 'Selin');
  LastNames: array[0..11] of string = (
    'Yilmaz', 'Kaya', 'Demir', 'Sahin', 'Celik', 'Yildiz',
    'Aydin', 'Ozturk', 'Arslan', 'Dogan', 'Kilic', 'Aslan');
  Cities: array[0..11] of string = (
    'Istanbul', 'Ankara', 'Izmir', 'Bursa', 'Antalya', 'Adana',
    'Konya', 'Gaziantep', 'Kayseri', 'Mersin', 'Eskisehir', 'Samsun');

type
  TDemoForm = class(TForm)
  private
    KV: TVDb;
    TB: TVTableDb;
    SQ: TVSql;
    Qry: TVDbQuery;
    DS: TDataSource;

    pnlTop, pnlFilter, pnlPage, pnlRight: TPanel;
    lblBanner, lblSearch, lblCity, lblAge, lblAgeTo, lblBal, lblProgress: TLabel;
    lblDetail, lblSummary, lblPage, lblCount, lblPageSize, lblSort: TLabel;
    edtSearch, edtAgeMin, edtAgeMax, edtBalMin: TEdit;
    cbCity, cboPageSize, cboSort: TComboBox;
    btnOpen, btnSeed, btnRefresh, btnNew, btnDelete, btnExport, btnLang: TButton;
    btnApply, btnClear, btnPrev, btnNext, btnDir, btnSummary: TButton;
    Progress: TProgressBar;
    Grid: TDBGrid;
    memoDetail, memoSummary: TMemo;
    sb: TStatusBar;

    FDBPath, FLastSQL: string;
    FPage, FPageSize, FTotal, FFiltered: Integer;
    FSortIndex: Integer;
    FOrderDesc: Boolean;
    FBusy, FCancelSeed, FShown: Boolean;

    procedure BuildUI;
    procedure TranslateUI;
    procedure SetBusy(AValue: Boolean);
    procedure SetStatus(const Msg: string; AMs: Integer = -1);
    function L(const TR, EN: string): string;
    function FmtNum(N: Int64): string;
    function SqlFloat(V: Double): string;
    function BuildWhere: string;
    function CountRows(const AWhere: string): Integer;
    function TableExists: Boolean;
    function TableRowCount: Integer;
    procedure OpenDatabase(AAutoSeed: Boolean = True);
    procedure CloseDatabase;
    procedure LoadCities;
    procedure RefreshAll;
    procedure LoadPage(AReset: Boolean);
    procedure LoadSummary;
    procedure UpdateDetails;
    procedure UpdatePageInfo;
    procedure SetGridLabels;
    procedure SeedRows(ARows: Integer; AAsk: Boolean);
    function BuildInsertSQL(AFrom, ATo: Integer): string;
    function AskNewRecord(out AName, ACity: string;
      out AAge: Integer; out ABalance: Double; out AActive: Boolean): Boolean;
    procedure ExportCSV;

    procedure FormShow(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure btnOpenClick(Sender: TObject);
    procedure btnSeedClick(Sender: TObject);
    procedure btnRefreshClick(Sender: TObject);
    procedure btnNewClick(Sender: TObject);
    procedure btnDeleteClick(Sender: TObject);
    procedure btnExportClick(Sender: TObject);
    procedure btnLangClick(Sender: TObject);
    procedure btnApplyClick(Sender: TObject);
    procedure btnClearClick(Sender: TObject);
    procedure btnPrevClick(Sender: TObject);
    procedure btnNextClick(Sender: TObject);
    procedure btnDirClick(Sender: TObject);
    procedure btnSummaryClick(Sender: TObject);
    procedure cboPageSizeChange(Sender: TObject);
    procedure cboSortChange(Sender: TObject);
    procedure edtFilterKeyPress(Sender: TObject; var Key: Char);
    procedure GridTitleClick(Column: TColumn);
    procedure QryAfterScroll(DataSet: TDataSet);
  public
    constructor Create(AOwner: TComponent); override;
    procedure SeedOnly(ARows: Integer);
  end;

var
  frmMain: TDemoForm;
  LangEN: Boolean = False;

{ ---------------------------------------------------------------- helpers }

function TDemoForm.L(const TR, EN: string): string;
begin
  if LangEN then Result := EN else Result := TR;
end;

function TDemoForm.FmtNum(N: Int64): string;
begin
  Result := FormatFloat('#,##0', N);
end;

function TDemoForm.SqlFloat(V: Double): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  Result := FloatToStr(V, FS);
end;

function ParseFloatDef(const S: string; ADef: Double): Double;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := StrToFloatDef(Trim(S), ADef, FS);
  if (Result = ADef) and (Pos(',', S) > 0) then
    Result := StrToFloatDef(StringReplace(S, ',', '.', [rfReplaceAll]), ADef, FS);
end;

procedure ClearDatabaseFolder(const ADir: string);
var
  SR: TSearchRec;
  Path: string;
begin
  Path := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(Path + '*.*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and
         ((SR.Attr and faDirectory) = 0) then
        DeleteFile(Path + SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(ADir);
end;

{ ===================================================================== }
{  Form kurucusu / constructor                                         }
{ ===================================================================== }
constructor TDemoForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Caption := 'VDB — 1.000.000 Kayit Demosu';
  Position := poScreenCenter;
  Width := 1280;
  Height := 780;
  Color := clBtnFace;
  KeyPreview := True;

  FPageSize := 100;
  FSortIndex := 0;       // id
  FOrderDesc := False;

  BuildUI;
  TranslateUI;

  OnShow := FormShow;
  OnDestroy := FormDestroy;
  OnCloseQuery := FormCloseQuery;
end;

{ ===================================================================== }
{  Arayuz / UI                                                         }
{ ===================================================================== }
procedure TDemoForm.BuildUI;
begin
  { Banner }
  lblBanner := TLabel.Create(Self);
  lblBanner.Parent := Self;
  lblBanner.Align := alTop;
  lblBanner.Height := 38;
  lblBanner.Alignment := taCenter;
  lblBanner.Layout := tlCenter;
  lblBanner.Font.Size := 16;
  lblBanner.Font.Style := [fsBold];
  lblBanner.Color := clNavy;
  lblBanner.Font.Color := clWhite;
  lblBanner.ParentColor := False;
  lblBanner.Transparent := False;
  lblBanner.Caption := '  VDB — 1.000.000 Kayit Demosu  ';

  { Toolbar }
  pnlTop := TPanel.Create(Self);
  pnlTop.Parent := Self;
  pnlTop.Align := alTop;
  pnlTop.Height := 46;
  pnlTop.BevelOuter := bvNone;

  btnOpen := TButton.Create(Self);
  btnOpen.Parent := pnlTop; btnOpen.SetBounds(8, 9, 120, 28);
  btnOpen.OnClick := btnOpenClick;

  btnSeed := TButton.Create(Self);
  btnSeed.Parent := pnlTop; btnSeed.SetBounds(134, 9, 110, 28);
  btnSeed.OnClick := btnSeedClick;

  btnRefresh := TButton.Create(Self);
  btnRefresh.Parent := pnlTop; btnRefresh.SetBounds(250, 9, 100, 28);
  btnRefresh.OnClick := btnRefreshClick;

  btnNew := TButton.Create(Self);
  btnNew.Parent := pnlTop; btnNew.SetBounds(356, 9, 100, 28);
  btnNew.OnClick := btnNewClick;

  btnDelete := TButton.Create(Self);
  btnDelete.Parent := pnlTop; btnDelete.SetBounds(462, 9, 100, 28);
  btnDelete.OnClick := btnDeleteClick;

  btnExport := TButton.Create(Self);
  btnExport.Parent := pnlTop; btnExport.SetBounds(568, 9, 90, 28);
  btnExport.OnClick := btnExportClick;

  Progress := TProgressBar.Create(Self);
  Progress.Parent := pnlTop;
  Progress.SetBounds(670, 13, 190, 20);
  Progress.Min := 0;
  Progress.Max := DEMO_ROWS;
  Progress.Position := 0;

  lblProgress := TLabel.Create(Self);
  lblProgress.Parent := pnlTop;
  lblProgress.SetBounds(868, 14, 260, 20);
  lblProgress.Layout := tlCenter;

  btnLang := TButton.Create(Self);
  btnLang.Parent := pnlTop; btnLang.SetBounds(1150, 9, 110, 28);
  btnLang.OnClick := btnLangClick;

  { Filters }
  pnlFilter := TPanel.Create(Self);
  pnlFilter.Parent := Self;
  pnlFilter.Align := alTop;
  pnlFilter.Height := 66;
  pnlFilter.BevelOuter := bvNone;

  lblSearch := TLabel.Create(Self);
  lblSearch.Parent := pnlFilter; lblSearch.SetBounds(8, 10, 60, 18);
  edtSearch := TEdit.Create(Self);
  edtSearch.Parent := pnlFilter; edtSearch.SetBounds(68, 6, 160, 26);
  edtSearch.OnKeyPress := edtFilterKeyPress;

  lblCity := TLabel.Create(Self);
  lblCity.Parent := pnlFilter; lblCity.SetBounds(244, 10, 40, 18);
  cbCity := TComboBox.Create(Self);
  cbCity.Parent := pnlFilter; cbCity.SetBounds(284, 6, 130, 26);
  cbCity.Style := csDropDownList;

  lblAge := TLabel.Create(Self);
  lblAge.Parent := pnlFilter; lblAge.SetBounds(430, 10, 34, 18);
  edtAgeMin := TEdit.Create(Self);
  edtAgeMin.Parent := pnlFilter; edtAgeMin.SetBounds(464, 6, 52, 26);
  lblAgeTo := TLabel.Create(Self);
  lblAgeTo.Parent := pnlFilter; lblAgeTo.SetBounds(520, 10, 14, 18);
  lblAgeTo.Caption := '-';
  edtAgeMax := TEdit.Create(Self);
  edtAgeMax.Parent := pnlFilter; edtAgeMax.SetBounds(536, 6, 52, 26);

  lblBal := TLabel.Create(Self);
  lblBal.Parent := pnlFilter; lblBal.SetBounds(604, 10, 70, 18);
  edtBalMin := TEdit.Create(Self);
  edtBalMin.Parent := pnlFilter; edtBalMin.SetBounds(674, 6, 78, 26);

  btnApply := TButton.Create(Self);
  btnApply.Parent := pnlFilter; btnApply.SetBounds(766, 6, 90, 28);
  btnApply.OnClick := btnApplyClick;

  btnClear := TButton.Create(Self);
  btnClear.Parent := pnlFilter; btnClear.SetBounds(862, 6, 90, 28);
  btnClear.OnClick := btnClearClick;

  btnSummary := TButton.Create(Self);
  btnSummary.Parent := pnlFilter; btnSummary.SetBounds(964, 6, 130, 28);
  btnSummary.OnClick := btnSummaryClick;

  { Pagination / sorting }
  pnlPage := TPanel.Create(Self);
  pnlPage.Parent := Self;
  pnlPage.Align := alTop;
  pnlPage.Height := 42;
  pnlPage.BevelOuter := bvNone;

  btnPrev := TButton.Create(Self);
  btnPrev.Parent := pnlPage; btnPrev.SetBounds(8, 7, 78, 28);
  btnPrev.OnClick := btnPrevClick;

  btnNext := TButton.Create(Self);
  btnNext.Parent := pnlPage; btnNext.SetBounds(92, 7, 78, 28);
  btnNext.OnClick := btnNextClick;

  lblPage := TLabel.Create(Self);
  lblPage.Parent := pnlPage; lblPage.SetBounds(184, 11, 170, 20);
  lblPage.Layout := tlCenter;

  lblCount := TLabel.Create(Self);
  lblCount.Parent := pnlPage; lblCount.SetBounds(360, 11, 320, 20);
  lblCount.Layout := tlCenter;

  lblPageSize := TLabel.Create(Self);
  lblPageSize.Parent := pnlPage; lblPageSize.SetBounds(690, 11, 86, 20);
  lblPageSize.Layout := tlCenter;
  cboPageSize := TComboBox.Create(Self);
  cboPageSize.Parent := pnlPage; cboPageSize.SetBounds(778, 7, 76, 26);
  cboPageSize.Style := csDropDownList;
  cboPageSize.Items.Add('100');
  cboPageSize.Items.Add('250');
  cboPageSize.Items.Add('500');
  cboPageSize.Items.Add('1000');
  cboPageSize.ItemIndex := 0;
  cboPageSize.OnChange := cboPageSizeChange;

  lblSort := TLabel.Create(Self);
  lblSort.Parent := pnlPage; lblSort.SetBounds(872, 11, 66, 20);
  lblSort.Layout := tlCenter;
  cboSort := TComboBox.Create(Self);
  cboSort.Parent := pnlPage; cboSort.SetBounds(940, 7, 130, 26);
  cboSort.Style := csDropDownList;
  cboSort.OnChange := cboSortChange;

  btnDir := TButton.Create(Self);
  btnDir.Parent := pnlPage; btnDir.SetBounds(1078, 7, 74, 28);
  btnDir.OnClick := btnDirClick;

  { Status bar (create before client area) }
  sb := TStatusBar.Create(Self);
  sb.Parent := Self;
  sb.SimplePanel := False;
  with TStatusPanel.Create(sb.Panels) do Width := 360;
  with TStatusPanel.Create(sb.Panels) do Width := 310;
  with TStatusPanel.Create(sb.Panels) do Width := 210;
  with TStatusPanel.Create(sb.Panels) do Width := 300;

  { Right detail/summary panel }
  pnlRight := TPanel.Create(Self);
  pnlRight.Parent := Self;
  pnlRight.Align := alRight;
  pnlRight.Width := 360;
  pnlRight.BevelOuter := bvNone;

  lblDetail := TLabel.Create(Self);
  lblDetail.Parent := pnlRight;
  lblDetail.Align := alTop;
  lblDetail.Height := 24;
  lblDetail.Layout := tlCenter;
  lblDetail.Font.Style := [fsBold];

  memoDetail := TMemo.Create(Self);
  memoDetail.Parent := pnlRight;
  memoDetail.Align := alTop;
  memoDetail.Height := 250;
  memoDetail.ReadOnly := True;
  memoDetail.ScrollBars := ssBoth;
  memoDetail.Font.Name := 'Consolas';
  memoDetail.Font.Size := 9;

  lblSummary := TLabel.Create(Self);
  lblSummary.Parent := pnlRight;
  lblSummary.Align := alTop;
  lblSummary.Height := 24;
  lblSummary.Layout := tlCenter;
  lblSummary.Font.Style := [fsBold];

  memoSummary := TMemo.Create(Self);
  memoSummary.Parent := pnlRight;
  memoSummary.Align := alClient;
  memoSummary.ReadOnly := True;
  memoSummary.ScrollBars := ssBoth;
  memoSummary.Font.Name := 'Consolas';
  memoSummary.Font.Size := 9;

  { Grid fills the remaining area; create last so alClient gets the rest. }
  Grid := TDBGrid.Create(Self);
  Grid.Parent := Self;
  Grid.Align := alClient;
  Grid.ReadOnly := True;
  Grid.Options := Grid.Options +
    [dgColumnResize, dgRowLines, dgColLines, dgRowSelect,
     dgAlwaysShowSelection, dgTitles];
  Grid.TitleFont.Style := [fsBold];
  Grid.OnTitleClick := GridTitleClick;

  { Data components }
  Qry := TVDbQuery.Create(Self);
  Qry.AfterScroll := QryAfterScroll;
  DS := TDataSource.Create(Self);
  DS.DataSet := Qry;
  Grid.DataSource := DS;
end;

{ ===================================================================== }
{  Ceviri / translation                                                }
{ ===================================================================== }
procedure TDemoForm.TranslateUI;
begin
  Caption := 'VDB — ' + L('1.000.000 Kayit Demosu', '1,000,000 Row Demo');

  lblBanner.Caption := '  VDB — ' +
    L('1.000.000 Kayitli Detayli Demo', 'Detailed Demo with 1,000,000 Rows') + '  ';

  btnOpen.Caption    := L('Veritabani Ac', 'Open DB');
  btnSeed.Caption    := L('1M Uret', 'Seed 1M');
  btnRefresh.Caption := L('Yenile', 'Refresh');
  btnNew.Caption     := L('Yeni Kayit', 'New Record');
  btnDelete.Caption  := L('Sil', 'Delete');
  btnExport.Caption  := L('CSV', 'CSV');
  btnLang.Caption    := L('EN', 'TR');

  lblSearch.Caption  := L('Ad ara:', 'Name:');
  lblCity.Caption    := L('Sehir:', 'City:');
  lblAge.Caption     := L('Yas:', 'Age:');
  lblBal.Caption     := L('Min bakiye:', 'Min balance:');
  btnApply.Caption   := L('Filtrele', 'Filter');
  btnClear.Caption   := L('Temizle', 'Clear');
  btnSummary.Caption := L('Ozet Yenile', 'Refresh Summary');

  btnPrev.Caption  := L('< Onceki', '< Prev');
  btnNext.Caption  := L('Sonraki >', 'Next >');
  lblPageSize.Caption := L('Sayfa boyu:', 'Page size:');
  lblSort.Caption  := L('Sirala:', 'Sort:');
  if FOrderDesc then btnDir.Caption := L('AZ', 'DESC')
  else btnDir.Caption := L('ZA', 'ASC');

  lblDetail.Caption  := '  ' + L('Secili Kayit', 'Selected Row');
  lblSummary.Caption := '  ' + L('Sehir Ozeti', 'City Summary');

  cboSort.Items.Clear;
  cboSort.Items.Add('ID');
  cboSort.Items.Add(L('Ad Soyad', 'Full Name'));
  cboSort.Items.Add(L('Sehir', 'City'));
  cboSort.Items.Add(L('Yas', 'Age'));
  cboSort.Items.Add(L('Bakiye', 'Balance'));
  cboSort.ItemIndex := FSortIndex;

  if Assigned(SQ) then
  begin
    LoadCities;
    UpdatePageInfo;
    UpdateDetails;
  end;
end;

{ ===================================================================== }
{  Durum / busy                                                        }
{ ===================================================================== }
procedure TDemoForm.SetStatus(const Msg: string; AMs: Integer = -1);
begin
  if not Assigned(sb) then Exit;
  sb.Panels[0].Text := ' ' + Msg;
  if AMs >= 0 then
    sb.Panels[1].Text := Format(' %d ms', [AMs]);
  if FDBPath <> '' then
    sb.Panels[3].Text := ' DB: ' + FDBPath
  else
    sb.Panels[3].Text := ' DB: -';
end;

procedure TDemoForm.SetBusy(AValue: Boolean);
begin
  FBusy := AValue;
  btnOpen.Enabled := not AValue;
  btnRefresh.Enabled := not AValue;
  btnNew.Enabled := not AValue;
  btnDelete.Enabled := not AValue;
  btnExport.Enabled := not AValue;
  btnApply.Enabled := not AValue;
  btnClear.Enabled := not AValue;
  btnPrev.Enabled := not AValue;
  btnNext.Enabled := not AValue;
  btnDir.Enabled := not AValue;
  btnSummary.Enabled := not AValue;
  cboPageSize.Enabled := not AValue;
  cboSort.Enabled := not AValue;
  Grid.Enabled := not AValue;

  if Assigned(btnSeed) then
  begin
    btnSeed.Enabled := True;
    if AValue then
      btnSeed.Caption := L('Iptal', 'Cancel')
    else
      btnSeed.Caption := L('1M Uret', 'Seed 1M');
  end;

  if AValue then Screen.Cursor := crHourGlass
  else Screen.Cursor := crDefault;
  Application.ProcessMessages;
end;

{ ===================================================================== }
{  Veritabani / database                                               }
{ ===================================================================== }
procedure TDemoForm.OpenDatabase(AAutoSeed: Boolean = True);
var
  N: Integer;
begin
  if Assigned(SQ) then Exit;

  FDBPath := ExtractFilePath(ParamStr(0)) + 'milyon_demo_db';
  KV := TVDb.Create;
  TB := TVTableDb.Create(KV);
  try
    KV.Open(FDBPath);
    TB.Open(FDBPath);
    SQ := TVSql.Create(TB);
    Qry.SqlEngine := SQ;
  except
    on E: Exception do
    begin
      FreeAndNil(SQ);
      FreeAndNil(TB);
      FreeAndNil(KV);
      SetStatus(L('Veritabani acilamadi: ', 'Cannot open database: ') + E.Message);
      Exit;
    end;
  end;

  LoadCities;

  if not TableExists then
  begin
    if AAutoSeed then
    begin
      if MessageDlg(
        L('1.000.000 kayitli demo tablosu olusturulsun mu?' + sLineBreak +
          'Ilk uretim disk hizina gore 1-3 dakika surebilir.',
          'Create the 1,000,000-row demo table?' + sLineBreak +
          'First seed may take 1-3 minutes depending on disk speed.'),
        mtConfirmation, [mbYes, mbNo], 0) = mrYes then
        SeedRows(DEMO_ROWS, False);
    end;
    Exit;
  end;

  N := TableRowCount;
  if AAutoSeed and (N < DEMO_ROWS) then
  begin
    if MessageDlg(
      Format(L('Tabloda %s kayit var. 1.000.000 kayit yeniden uretilsin mi?',
               'Table has %s rows. Re-seed all 1,000,000 rows?'),
             [FmtNum(N)]),
      mtConfirmation, [mbYes, mbNo], 0) = mrYes then
      SeedRows(DEMO_ROWS, False)
    else
      RefreshAll;
  end
  else
    RefreshAll;
end;

procedure TDemoForm.CloseDatabase;
begin
  if Assigned(Qry) then
  begin
    Qry.Close;
    Qry.SqlEngine := nil;
  end;
  FreeAndNil(SQ);
  FreeAndNil(TB);
  FreeAndNil(KV);
end;

function TDemoForm.TableExists: Boolean;
var
  R: TSqlResult;
  I: Integer;
begin
  Result := False;
  if not Assigned(SQ) then Exit;
  try
    R := SQ.Exec('SHOW TABLES');
    for I := 0 to High(R.Rows) do
      if (Length(R.Rows[I]) > 0) and SameText(R.Rows[I][0], DEMO_TABLE) then
      begin
        Result := True;
        Exit;
      end;
  except
    Result := False;
  end;
end;

function TDemoForm.TableRowCount: Integer;
begin
  Result := 0;
  if not TableExists then Exit;
  try
    Result := CountRows('');
  except
    Result := 0;
  end;
end;

procedure TDemoForm.LoadCities;
var
  R: TSqlResult;
  I, Keep: Integer;
  Sel: string;
begin
  if not Assigned(cbCity) or not Assigned(SQ) then Exit;

  Sel := '';
  if (cbCity.ItemIndex > 0) and (cbCity.ItemIndex < cbCity.Items.Count) then
    Sel := cbCity.Items[cbCity.ItemIndex];

  cbCity.Items.BeginUpdate;
  try
    cbCity.Items.Clear;
    cbCity.Items.Add(L('Tumu', 'All'));
    try
      R := SQ.Exec('SELECT DISTINCT sehir FROM ' + DEMO_TABLE + ' ORDER BY sehir');
      for I := 0 to High(R.Rows) do
        if Length(R.Rows[I]) > 0 then
          cbCity.Items.Add(R.Rows[I][0]);
    except
      { table yok / no table }
    end;
  finally
    cbCity.Items.EndUpdate;
  end;

  Keep := 0;
  for I := 1 to cbCity.Items.Count - 1 do
    if SameText(cbCity.Items[I], Sel) then
    begin
      Keep := I;
      Break;
    end;
  cbCity.ItemIndex := Keep;
end;

procedure TDemoForm.RefreshAll;
begin
  if not Assigned(SQ) then Exit;
  Qry.Close;
  FTotal := TableRowCount;
  LoadCities;
  LoadPage(True);
  LoadSummary;
  SetStatus(Format(L('%s kayit hazir', '%s rows ready'), [FmtNum(FTotal)]));
end;

{ ===================================================================== }
{  Filtre / sayfa                                                      }
{ ===================================================================== }
function TDemoForm.BuildWhere: string;
var
  N: Integer;
begin
  Result := '';
  if Trim(edtSearch.Text) <> '' then
    Result := Result + 'ad_soyad ILIKE ' +
      QuotedStr('%' + Trim(edtSearch.Text) + '%');

  if cbCity.ItemIndex > 0 then
  begin
    if Result <> '' then Result := Result + ' AND ';
    Result := Result + 'sehir = ' + QuotedStr(cbCity.Items[cbCity.ItemIndex]);
  end;

  if TryStrToInt(Trim(edtAgeMin.Text), N) then
  begin
    if Result <> '' then Result := Result + ' AND ';
    Result := Result + 'yas >= ' + IntToStr(N);
  end;

  if TryStrToInt(Trim(edtAgeMax.Text), N) then
  begin
    if Result <> '' then Result := Result + ' AND ';
    Result := Result + 'yas <= ' + IntToStr(N);
  end;

  if TryStrToInt(Trim(edtBalMin.Text), N) then
  begin
    if Result <> '' then Result := Result + ' AND ';
    Result := Result + 'bakiye >= ' + IntToStr(N);
  end;

  if Result <> '' then Result := ' WHERE ' + Result;
end;

function TDemoForm.CountRows(const AWhere: string): Integer;
var
  R: TSqlResult;
begin
  Result := 0;
  if not Assigned(SQ) then Exit;
  R := SQ.Exec('SELECT COUNT(*) FROM ' + DEMO_TABLE + AWhere);
  if (Length(R.Rows) > 0) and (Length(R.Rows[0]) > 0) then
    Result := StrToIntDef(Trim(R.Rows[0][0]), 0);
end;

procedure TDemoForm.UpdatePageInfo;
var
  Pages: Integer;
begin
  if FFiltered > 0 then
    Pages := (FFiltered + FPageSize - 1) div FPageSize
  else
    Pages := 0;

  if Pages = 0 then
    lblPage.Caption := L('Sayfa 0 / 0', 'Page 0 / 0')
  else
    lblPage.Caption := Format(L('Sayfa %d / %d', 'Page %d / %d'),
      [FPage + 1, Pages]);

  lblCount.Caption := Format(L('Filtre: %s / Toplam: %s',
    'Filtered: %s / Total: %s'), [FmtNum(FFiltered), FmtNum(FTotal)]);

  sb.Panels[1].Text := ' ' + lblPage.Caption;
  sb.Panels[2].Text := ' ' + lblCount.Caption;
end;

procedure TDemoForm.LoadPage(AReset: Boolean);
var
  Where, OrderCol, Dir, S: string;
  T0: TDateTime;
  Ms: Integer;
  StartId, EndId: Int64;
begin
  if not Assigned(SQ) or FBusy then Exit;

  if AReset then FPage := 0;
  Where := BuildWhere;
  FFiltered := CountRows(Where);

  if FFiltered <= 0 then
    FPage := 0
  else if FPage > (FFiltered - 1) div FPageSize then
    FPage := (FFiltered - 1) div FPageSize;

  case FSortIndex of
    1: OrderCol := 'ad_soyad';
    2: OrderCol := 'sehir';
    3: OrderCol := 'yas';
    4: OrderCol := 'bakiye';
  else
    OrderCol := 'id';
  end;

  if FOrderDesc then Dir := 'DESC' else Dir := 'ASC';

  { Filtresiz ID sirasinda LIMIT/OFFSET yerine PK araligi kullan.
    H12 ile motor ORDER BY id + LIMIT icin indeks sirasini ve erken
    durmayi destekliyor; PK araligi yine de sayfa numarasindan bagimsiz
    olarak yalnizca sayfa kadar satir okur. }
  if (Where = '') and (FSortIndex = 0) and (not FOrderDesc) then
  begin
    StartId := Int64(FPage) * FPageSize + 1;
    EndId := StartId + FPageSize;
    S := Format(
      'SELECT id, ad_soyad, sehir, yas, bakiye, kayit_tarihi, aktif ' +
      'FROM %s WHERE id >= %d AND id < %d ORDER BY id',
      [DEMO_TABLE, StartId, EndId]);
  end
  else
    S := Format(
      'SELECT id, ad_soyad, sehir, yas, bakiye, kayit_tarihi, aktif ' +
      'FROM %s%s ORDER BY %s %s LIMIT %d OFFSET %d',
      [DEMO_TABLE, Where, OrderCol, Dir, FPageSize, FPage * FPageSize]);

  FLastSQL := S;
  T0 := Now;
  try
    Qry.Close;
    Qry.SQL.Text := S;
    Qry.Open;
    Ms := MilliSecondsBetween(T0, Now);
    SetGridLabels;
    UpdatePageInfo;
    SetStatus(Format(L('Sayfa yuklendi (%d satir)',
      'Page loaded (%d rows)'), [Qry.RecordCount]), Ms);
    UpdateDetails;
  except
    on E: Exception do
      SetStatus(L('Sorgu hatasi: ', 'Query error: ') + E.Message);
  end;
end;

procedure TDemoForm.SetGridLabels;
  procedure SetLabel(const AName, AValue: string);
  var
    F: TField;
  begin
    F := Qry.FindField(AName);
    if F <> nil then F.DisplayLabel := AValue;
  end;
begin
  SetLabel('id', 'ID');
  SetLabel('ad_soyad', L('Ad Soyad', 'Full Name'));
  SetLabel('sehir', L('Sehir', 'City'));
  SetLabel('yas', L('Yas', 'Age'));
  SetLabel('bakiye', L('Bakiye', 'Balance'));
  SetLabel('kayit_tarihi', L('Kayit Tarihi', 'Created'));
  SetLabel('aktif', L('Aktif', 'Active'));
end;

{ ===================================================================== }
{  Detay / ozet                                                        }
{ ===================================================================== }
procedure TDemoForm.UpdateDetails;
var
  I: Integer;
begin
  if not Assigned(memoDetail) then Exit;
  memoDetail.Lines.BeginUpdate;
  try
    memoDetail.Lines.Clear;
    if not Qry.Active then
    begin
      memoDetail.Lines.Add(L('Kayit yok.', 'No record.'));
      Exit;
    end;
    if Qry.RecordCount = 0 then
    begin
      memoDetail.Lines.Add(L('Bu filtreye uygun kayit yok.',
        'No rows match this filter.'));
      Exit;
    end;

    for I := 0 to Qry.FieldCount - 1 do
      memoDetail.Lines.Add(Format('%-14s: %s',
        [Qry.Fields[I].DisplayLabel, Qry.Fields[I].AsString]));

    memoDetail.Lines.Add('');
    memoDetail.Lines.Add(L('Calisan SQL:', 'Executed SQL:'));
    memoDetail.Lines.Add(FLastSQL);
  finally
    memoDetail.Lines.EndUpdate;
  end;
end;

procedure TDemoForm.LoadSummary;
var
  R: TSqlResult;
  I: Integer;
begin
  if not Assigned(SQ) or not Assigned(memoSummary) then Exit;
  memoSummary.Lines.BeginUpdate;
  try
    memoSummary.Lines.Clear;
    try
      R := SQ.Exec('SELECT sehir, COUNT(*) AS adet, AVG(bakiye) AS ort ' +
        'FROM ' + DEMO_TABLE + ' GROUP BY sehir ORDER BY adet DESC');
      memoSummary.Lines.Add(Format('%-13s %10s %14s',
        [L('Sehir', 'City'), L('Adet', 'Count'), L('Ort. Bakiye', 'Avg Bal')]));
      memoSummary.Lines.Add(StringOfChar('-', 40));
      for I := 0 to High(R.Rows) do
        if Length(R.Rows[I]) >= 3 then
          memoSummary.Lines.Add(Format('%-13s %10s %14s',
            [R.Rows[I][0], R.Rows[I][1], R.Rows[I][2]]));

      R := SQ.Exec('SELECT COUNT(*), AVG(bakiye), MIN(bakiye), MAX(bakiye) ' +
        'FROM ' + DEMO_TABLE);
      if (Length(R.Rows) > 0) and (Length(R.Rows[0]) >= 4) then
      begin
        memoSummary.Lines.Add('');
        memoSummary.Lines.Add(Format(
          L('Toplam: %s   Ort: %s   Min: %s   Max: %s',
            'Total: %s   Avg: %s   Min: %s   Max: %s'),
          [R.Rows[0][0], R.Rows[0][1], R.Rows[0][2], R.Rows[0][3]]));
      end;
    except
      on E: Exception do
        memoSummary.Lines.Add(L('Ozet hatasi: ', 'Summary error: ') + E.Message);
    end;
  finally
    memoSummary.Lines.EndUpdate;
  end;
end;

{ ===================================================================== }
{  Veri uretimi / seeding                                              }
{ ===================================================================== }
function TDemoForm.BuildInsertSQL(AFrom, ATo: Integer): string;
var
  I: Integer;
  SB: TStringBuilder;
  Balance: string;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('INSERT INTO ' + DEMO_TABLE +
      ' (id,ad_soyad,sehir,yas,bakiye,kayit_tarihi,aktif) VALUES ');
    for I := AFrom to ATo do
    begin
      if I > AFrom then SB.Append(',');
      SB.Append('(');
      SB.Append(IntToStr(I));
      SB.Append(',');
      SB.Append(QuotedStr(FirstNames[I mod Length(FirstNames)] + ' ' +
        LastNames[(I div 7) mod Length(LastNames)]));
      SB.Append(',');
      SB.Append(QuotedStr(Cities[(I * 7) mod Length(Cities)]));
      SB.Append(',');
      SB.Append(IntToStr(18 + ((I * 13) mod 60)));
      SB.Append(',');
      Balance := IntToStr((I * 37) mod 1000000) + '.' +
        Format('%.2d', [I mod 100]);
      SB.Append(Balance);
      SB.Append(',');
      SB.Append(QuotedStr(Format('%.4d-%.2d-%.2d',
        [2015 + (I mod 10), 1 + (I mod 12), 1 + (I mod 28)])));
      SB.Append(',');
      SB.Append(IntToStr(I mod 2));
      SB.Append(')');
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TDemoForm.SeedRows(ARows: Integer; AAsk: Boolean);
var
  StartN, EndN: Integer;
  T0: TDateTime;
  Ok: Boolean;
begin
  if FBusy then Exit;
  if AAsk then
    if MessageDlg(
      L('Mevcut tablo silinip 1.000.000 kayit yeniden uretilecek. Devam?',
        'The current table will be dropped and 1,000,000 rows re-seeded. Continue?'),
      mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;

  if ARows < DEMO_BATCH then ARows := DEMO_BATCH;
  ARows := (ARows div DEMO_BATCH) * DEMO_BATCH;

  SetBusy(True);
  FCancelSeed := False;
  Ok := False;
  T0 := Now;
  Progress.Max := ARows;
  Progress.Position := 0;
  lblProgress.Caption := Format('%s / %s', ['0', FmtNum(ARows)]);

  try
    { Eski 1M tabloyu DROP TABLE ile silmek cok yavas; dosyayi
      kapatip klasoru temizleyerek sifirdan aciyoruz. }
    if FDBPath = '' then
      FDBPath := ExtractFilePath(ParamStr(0)) + 'milyon_demo_db';
    CloseDatabase;
    ClearDatabaseFolder(FDBPath);
    OpenDatabase(False);
    if not Assigned(SQ) then
      raise Exception.Create('Veritabani yeniden acilamadi / could not reopen database');

    SQ.Exec(
      'CREATE TABLE ' + DEMO_TABLE + ' (' +
      'id INTEGER PRIMARY KEY, ' +
      'ad_soyad TEXT, ' +
      'sehir TEXT, ' +
      'yas INTEGER, ' +
      'bakiye FLOAT, ' +
      'kayit_tarihi TEXT, ' +
      'aktif INTEGER)');

    SQ.Exec('BEGIN');
    StartN := 1;
    while StartN <= ARows do
    begin
      EndN := StartN + DEMO_BATCH - 1;
      if EndN > ARows then EndN := ARows;
      SQ.Exec(BuildInsertSQL(StartN, EndN));
      Progress.Position := EndN;
      lblProgress.Caption := Format('%s / %s',
        [FmtNum(EndN), FmtNum(ARows)]);
      StartN := EndN + 1;

      if (StartN - 1) mod (DEMO_BATCH * 10) = 0 then
      begin
        Application.ProcessMessages;
        if FCancelSeed then Break;
      end;
    end;

    if FCancelSeed then
    begin
      SQ.Exec('ROLLBACK');
      SetStatus(L('Veri uretimi iptal edildi.', 'Seeding cancelled.'));
    end
    else
    begin
      SQ.Exec('COMMIT');
      Ok := True;
      SetStatus(L('Sehir indeksi olusturuluyor...', 'Building city index...'));
      Application.ProcessMessages;
      try
        SQ.Exec('CREATE INDEX idx_buyuk_sehir ON ' + DEMO_TABLE + '(sehir)');
      except
        { indeks zaten varsa / index already exists }
      end;
      SetStatus(Format(L('%s kayit uretildi (%d ms).',
        '%s rows seeded (%d ms).'),
        [FmtNum(ARows), MilliSecondsBetween(T0, Now)]));
    end;
  except
    on E: Exception do
    begin
      if Assigned(SQ) then
      try
        SQ.Exec('ROLLBACK');
      except
      end;
      MessageDlg(L('Veri uretimi hatasi: ', 'Seeding error: ') + E.Message,
        mtError, [mbOK], 0);
    end;
  end;

  SetBusy(False);
  if Ok and TableExists then
    RefreshAll;
end;

{ ===================================================================== }
{  Yeni kayit / sil / CSV                                              }
{ ===================================================================== }
function TDemoForm.AskNewRecord(out AName, ACity: string;
  out AAge: Integer; out ABalance: Double; out AActive: Boolean): Boolean;
var
  F: TForm;
  L1, L2, L3, L4: TLabel;
  E1, E2, E3, E4: TEdit;
  C: TCheckBox;
  B1, B2: TButton;
begin
  Result := False;
  F := TForm.CreateNew(Self);
  try
    F.Caption := L('Yeni Kayit', 'New Record');
    F.BorderStyle := bsDialog;
    F.Position := poScreenCenter;
    F.ClientWidth := 430;
    F.ClientHeight := 270;

    L1 := TLabel.Create(F); L1.Parent := F; L1.SetBounds(20, 20, 100, 18);
    L1.Caption := L('Ad Soyad:', 'Full Name:');
    E1 := TEdit.Create(F); E1.Parent := F; E1.SetBounds(130, 16, 270, 26);

    L2 := TLabel.Create(F); L2.Parent := F; L2.SetBounds(20, 58, 100, 18);
    L2.Caption := L('Sehir:', 'City:');
    E2 := TEdit.Create(F); E2.Parent := F; E2.SetBounds(130, 54, 270, 26);
    E2.Text := 'Istanbul';

    L3 := TLabel.Create(F); L3.Parent := F; L3.SetBounds(20, 96, 100, 18);
    L3.Caption := L('Yas:', 'Age:');
    E3 := TEdit.Create(F); E3.Parent := F; E3.SetBounds(130, 92, 100, 26);
    E3.Text := '30';

    L4 := TLabel.Create(F); L4.Parent := F; L4.SetBounds(20, 134, 100, 18);
    L4.Caption := L('Bakiye:', 'Balance:');
    E4 := TEdit.Create(F); E4.Parent := F; E4.SetBounds(130, 130, 140, 26);
    E4.Text := '1000.00';

    C := TCheckBox.Create(F); C.Parent := F; C.SetBounds(130, 166, 180, 24);
    C.Caption := L('Aktif', 'Active');
    C.Checked := True;

    B1 := TButton.Create(F); B1.Parent := F; B1.SetBounds(220, 220, 90, 30);
    B1.Caption := 'OK'; B1.ModalResult := mrOk; B1.Default := True;
    B2 := TButton.Create(F); B2.Parent := F; B2.SetBounds(316, 220, 90, 30);
    B2.Caption := L('Iptal', 'Cancel'); B2.ModalResult := mrCancel;
    B2.Cancel := True;

    if F.ShowModal <> mrOk then Exit;

    AName := Trim(E1.Text);
    ACity := Trim(E2.Text);
    AAge := StrToIntDef(Trim(E3.Text), 30);
    ABalance := ParseFloatDef(E4.Text, 0);
    AActive := C.Checked;

    if AName = '' then
    begin
      MessageDlg(L('Ad Soyad bos olamaz.', 'Full name cannot be empty.'),
        mtWarning, [mbOK], 0);
      Exit;
    end;
    if ACity = '' then ACity := 'Istanbul';
    if (AAge < 0) or (AAge > 150) then
    begin
      MessageDlg(L('Yas 0-150 arasinda olmali.', 'Age must be 0-150.'),
        mtWarning, [mbOK], 0);
      Exit;
    end;
    Result := True;
  finally
    F.Free;
  end;
end;

procedure TDemoForm.btnNewClick(Sender: TObject);
var
  Name, City, IdText: string;
  Age, NewId: Integer;
  Balance: Double;
  Active: Boolean;
  R: TSqlResult;
begin
  if not Assigned(SQ) or FBusy then Exit;
  if not AskNewRecord(Name, City, Age, Balance, Active) then Exit;

  try
    R := SQ.Exec('SELECT MAX(id) FROM ' + DEMO_TABLE);
    NewId := 1;
    if (Length(R.Rows) > 0) and (Length(R.Rows[0]) > 0) then
      NewId := StrToIntDef(Trim(R.Rows[0][0]), 0) + 1;

    SQ.Exec(Format(
      'INSERT INTO ' + DEMO_TABLE +
      ' (id,ad_soyad,sehir,yas,bakiye,kayit_tarihi,aktif) ' +
      'VALUES (%d,%s,%s,%d,%s,%s,%d)',
      [NewId, QuotedStr(Name), QuotedStr(City), Age, SqlFloat(Balance),
       QuotedStr(FormatDateTime('yyyy-mm-dd', Date)), Ord(Active)]));

    IdText := IntToStr(NewId);
    FPage := 0;
    RefreshAll;
    SetStatus(Format(L('Kayit eklendi: ID=%s', 'Record added: ID=%s'), [IdText]));
  except
    on E: Exception do
      MessageDlg(L('Kayit eklenemedi: ', 'Insert failed: ') + E.Message,
        mtError, [mbOK], 0);
  end;
end;

procedure TDemoForm.btnDeleteClick(Sender: TObject);
var
  IdText: string;
begin
  if not Assigned(SQ) or FBusy then Exit;
  if (not Qry.Active) or (Qry.RecordCount = 0) then
  begin
    SetStatus(L('Silinecek kayit yok.', 'No record to delete.'));
    Exit;
  end;

  IdText := Qry.FieldByName('id').AsString;
  if MessageDlg(Format(L('ID=%s kaydi silinsin mi?',
    'Delete record ID=%s?'), [IdText]),
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;

  try
    SQ.Exec('DELETE FROM ' + DEMO_TABLE + ' WHERE id = ' + IdText);
    RefreshAll;
    SetStatus(Format(L('Kayit silindi: ID=%s', 'Record deleted: ID=%s'), [IdText]));
  except
    on E: Exception do
      MessageDlg(L('Silme hatasi: ', 'Delete failed: ') + E.Message,
        mtError, [mbOK], 0);
  end;
end;

procedure TDemoForm.ExportCSV;
var
  SD: TSaveDialog;
  SL: TStringList;
  I: Integer;
  Line: string;

  function Cell(const S: string): string;
  begin
    Result := '"' + StringReplace(S, '"', '""', [rfReplaceAll]) + '"';
  end;

begin
  if not Qry.Active then Exit;
  SD := TSaveDialog.Create(Self);
  try
    SD.Filter := 'CSV|*.csv';
    SD.FileName := 'vdb_buyuk_sayfa.csv';
    if not SD.Execute then Exit;

    SL := TStringList.Create;
    try
      Line := '';
      for I := 0 to Qry.FieldCount - 1 do
      begin
        if I > 0 then Line := Line + ',';
        Line := Line + Cell(Qry.Fields[I].DisplayLabel);
      end;
      SL.Add(Line);

      Qry.DisableControls;
      try
        Qry.First;
        while not Qry.Eof do
        begin
          Line := '';
          for I := 0 to Qry.FieldCount - 1 do
          begin
            if I > 0 then Line := Line + ',';
            Line := Line + Cell(Qry.Fields[I].AsString);
          end;
          SL.Add(Line);
          Qry.Next;
        end;
      finally
        Qry.EnableControls;
      end;

      SL.SaveToFile(SD.FileName);
      SetStatus(Format(L('%d satir CSV yazildi.',
        '%d rows written to CSV.'), [SL.Count - 1]));
    finally
      SL.Free;
    end;
  finally
    SD.Free;
  end;
end;

{ ===================================================================== }
{  Olaylar / events                                                    }
{ ===================================================================== }
procedure TDemoForm.FormShow(Sender: TObject);
begin
  if FShown then Exit;
  FShown := True;
  OpenDatabase(True);
end;

procedure TDemoForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FBusy then
  begin
    CanClose := False;
    SetStatus(L('Islem suruyor; once iptal edin.',
      'Operation in progress; cancel it first.'));
  end;
end;

procedure TDemoForm.FormDestroy(Sender: TObject);
begin
  if Assigned(Grid) then Grid.DataSource := nil;
  if Assigned(DS) then DS.DataSet := nil;
  CloseDatabase;
  FreeAndNil(Qry);
  FreeAndNil(DS);
end;

procedure TDemoForm.btnOpenClick(Sender: TObject);
begin
  OpenDatabase(True);
end;

procedure TDemoForm.btnSeedClick(Sender: TObject);
begin
  if FBusy then
  begin
    FCancelSeed := True;
    SetStatus(L('Iptal istegi alindi...', 'Cancel requested...'));
    Exit;
  end;
  SeedRows(DEMO_ROWS, True);
end;

procedure TDemoForm.btnRefreshClick(Sender: TObject);
begin
  RefreshAll;
end;

procedure TDemoForm.btnExportClick(Sender: TObject);
begin
  ExportCSV;
end;

procedure TDemoForm.btnLangClick(Sender: TObject);
begin
  LangEN := not LangEN;
  TranslateUI;
  if Assigned(SQ) then
    LoadPage(False);
end;

procedure TDemoForm.btnApplyClick(Sender: TObject);
begin
  LoadPage(True);
end;

procedure TDemoForm.btnClearClick(Sender: TObject);
begin
  edtSearch.Text := '';
  cbCity.ItemIndex := 0;
  edtAgeMin.Text := '';
  edtAgeMax.Text := '';
  edtBalMin.Text := '';
  LoadPage(True);
end;

procedure TDemoForm.btnPrevClick(Sender: TObject);
begin
  if FPage > 0 then
  begin
    Dec(FPage);
    LoadPage(False);
  end;
end;

procedure TDemoForm.btnNextClick(Sender: TObject);
var
  Pages: Integer;
begin
  if FFiltered > 0 then
    Pages := (FFiltered + FPageSize - 1) div FPageSize
  else
    Pages := 0;
  if FPage + 1 < Pages then
  begin
    Inc(FPage);
    LoadPage(False);
  end;
end;

procedure TDemoForm.btnDirClick(Sender: TObject);
begin
  FOrderDesc := not FOrderDesc;
  if FOrderDesc then btnDir.Caption := L('AZ', 'DESC')
  else btnDir.Caption := L('ZA', 'ASC');
  LoadPage(True);
end;

procedure TDemoForm.btnSummaryClick(Sender: TObject);
begin
  LoadSummary;
  SetStatus(L('Ozet yenilendi.', 'Summary refreshed.'));
end;

procedure TDemoForm.cboPageSizeChange(Sender: TObject);
var
  N: Integer;
begin
  N := StrToIntDef(cboPageSize.Text, 100);
  if N < 10 then N := 10;
  if N > 5000 then N := 5000;
  FPageSize := N;
  LoadPage(True);
end;

procedure TDemoForm.cboSortChange(Sender: TObject);
begin
  FSortIndex := cboSort.ItemIndex;
  if FSortIndex < 0 then FSortIndex := 0;
  LoadPage(True);
end;

procedure TDemoForm.edtFilterKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    Key := #0;
    LoadPage(True);
  end;
end;

procedure TDemoForm.GridTitleClick(Column: TColumn);
var
  Fn: string;
  Idx: Integer;
begin
  Fn := UpperCase(Column.FieldName);
  if Fn = 'ID' then Idx := 0
  else if Fn = 'AD_SOYAD' then Idx := 1
  else if Fn = 'SEHIR' then Idx := 2
  else if Fn = 'YAS' then Idx := 3
  else if Fn = 'BAKIYE' then Idx := 4
  else Exit;

  if Idx = FSortIndex then
    FOrderDesc := not FOrderDesc
  else
  begin
    FSortIndex := Idx;
    FOrderDesc := False;
  end;

  cboSort.ItemIndex := FSortIndex;
  if FOrderDesc then btnDir.Caption := L('AZ', 'DESC')
  else btnDir.Caption := L('ZA', 'ASC');
  LoadPage(True);
end;

procedure TDemoForm.QryAfterScroll(DataSet: TDataSet);
begin
  UpdateDetails;
end;

{ ===================================================================== }
{  Seed-only mode (CI / hizli test)                                    }
{ ===================================================================== }
procedure TDemoForm.SeedOnly(ARows: Integer);
var
  T0: TDateTime;
  N: Integer;
  SL: TStringList;
begin
  FDBPath := ExtractFilePath(ParamStr(0)) + 'milyon_demo_db';
  T0 := Now;
  SeedRows(ARows, False);
  N := TableRowCount;

  SL := TStringList.Create;
  try
    SL.Add('rows=' + IntToStr(N));
    SL.Add('elapsed_ms=' + IntToStr(MilliSecondsBetween(T0, Now)));
    SL.Add('db=' + FDBPath);
    SL.SaveToFile(ExtractFilePath(ParamStr(0)) + 'seed_result.txt');
  finally
    SL.Free;
  end;

  CloseDatabase;
end;

{ ===================================================================== }
{  Program                                                             }
{ ===================================================================== }
begin
  Application.Initialize;
  Application.CreateForm(TDemoForm, frmMain);

  if SameText(ParamStr(1), '--seed-only') then
  begin
    frmMain.SeedOnly(StrToIntDef(ParamStr(2), DEMO_ROWS));
    Halt(0);
  end;

  Application.Run;
end.
