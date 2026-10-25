program ornek11_gui;

{ =====================================================================
  VDB ORNEK 11 — GORSEL VERITABANI YONETIM ARAYUZU (GUI)  /  GUI DEMO
  =====================================================================

  TR: Bu ornek, VDB motorunu kullanan GORSEL bir masaustu uygulamasi
      gosterir. Amac "millet bir sey gorsun": gercek bir DBGrid, tablo
      tarayici, SQL editoru, kayit gezinme ve TR/EN dil degistirme.

      Ozellikler:
        * Gercek TDBGrid + TDBNavigator (VDbDataSet / TVDbQuery koprusu)
        * Solda tablo listesi — tiklayinca tablo verisi grid'e gelir
        * SQL editoru (SELECT/SHOW -> grid, DDL/DML -> calistir)
        * Ornek veritabani + veri otomatik doldurulur
        * TR/EN tek tikla dil degistirme
        * Durum cubugu: satir sayisi, aktif dil, veritabani yolu

  EN: This example shows a VISUAL desktop application built on the VDB
      engine. The goal is to SHOW something real: a proper DBGrid, table
      browser, SQL editor, record navigation and a TR/EN language toggle.

      Features:
        * Real TDBGrid + TDBNavigator (via VDbDataSet / TVDbQuery bridge)
        * Table list on the left — click to load the table into the grid
        * SQL editor (SELECT/SHOW -> grid, DDL/DML -> executed)
        * Sample database + data seeded automatically
        * One-click TR/EN language switch
        * Status bar: row count, active language, database path

  Kullanim / Usage:
    1) "Veritabani Ac / Open DB" butonuna basin (ornek veri olusur).
    2) Soldan bir tabloya tiklayin veya SQL yazip "Calistir" deyin.
    3) "TR/EN" butonuyla arayuz dilini degistirin.
    4) DBGrid uzerinde gezinin; TDBNavigator ile kayit ekleyin/silin.

  Derleme / Build:
    lazbuild ornek11.lpi        (veya derle_tumu.bat icindeki 14. adim)

  ===================================================================== }

{$mode delphi}{$H+}

uses
  Interfaces, // LCL widgetset (win32) — bu olmadan WSRegister* linklenemez
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls,
  ExtCtrls, ComCtrls, DB, DBCtrls, DBGrids, Grids,
  VDbBackendApi, VDbFactory, VDbTable, VDbSql, VDbAst, VDbDataSet;

type
  TfrmMain = class(TForm)
  private
    // VDB katmanlari / database layers
    Be: IVdbBackend;
    TB: TVTableDb;
    SQ: TVSql;
    // Veri bilesenleri / data components
    Qry: TVDbQuery;
    DS: TDataSource;
    // Gorsel bilesenler / visual components
    pnlLeft, pnlTop, pnlSQLEdit, pnlNav: TPanel;
    lblTables, lblSQLEdit, lblBanner: TLabel;
    lstTables: TListBox;
    btnOpen, btnRun, btnIns, btnDel, btnRefresh, btnLang: TButton;
    memoSQL: TMemo;
    Grid: TDBGrid;
    Nav: TDBNavigator;
    sb: TStatusBar;
    FDBPath: string;
    FActiveTable: string;
    procedure BuildUI;
    procedure TranslateUI;
    procedure SetStatus(const Msg: string);
    procedure OpenDatabase;
    procedure EnsureSampleData;
    procedure LoadTableList;
    procedure RunSQL(const AText: string);
    function IsQuerySQL(const S: string): Boolean;
    procedure RefreshActive;
    // Olaylar / events
    procedure btnOpenClick(Sender: TObject);
    procedure btnRunClick(Sender: TObject);
    procedure btnInsClick(Sender: TObject);
    procedure btnDelClick(Sender: TObject);
    procedure btnRefreshClick(Sender: TObject);
    procedure btnLangClick(Sender: TObject);
    procedure lstTablesClick(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  frmMain: TfrmMain;
  LangEN: Boolean = False;   // TR: dil bayragi / EN: language flag

{ TR/EN yardimcisi — ornek icin yerel (yonetim programi uLang.pas kullanir).
  TR/EN helper — local for this example (the management app uses uLang.pas).
  EN: helper }
function L(const TR, EN: string): string;
begin
  if LangEN then Result := EN else Result := TR;
end;

{ ===================================================================== }
{  Form kurucusu — LFM olmadan, kod ile / code-built form (no LFM)      }
{ ===================================================================== }
constructor TfrmMain.Create(AOwner: TComponent);
begin
  // TR: hadmain ile ayni desen — LFM kaynagi olmadan calisir.
  // EN: Same pattern as hadmain — works without an LFM resource.
  inherited Create(AOwner);

  Caption := 'VDB Studio — ' + L('Ornek GUI', 'GUI Example');
  Position := poScreenCenter;
  Width := 1024;
  Height := 660;
  Color := clBtnFace;

  BuildUI;
  TranslateUI;
  OnDestroy := FormDestroy;

  // TR: Acilista ornek veritabanini yukle ki grid BOS olmasin (gorunur).
  // EN: Load the sample DB on startup so the grid is NOT empty (visible).
  try
    OpenDatabase;
  except
    on E: Exception do
      SetStatus(L('Hata: ', 'Error: ') + E.Message);
  end;
end;

{ ===================================================================== }
{  Arayuzu kur / build the UI                                          }
{ ===================================================================== }
procedure TfrmMain.BuildUI;
begin
  // ---- Ust bant / top banner ----
  lblBanner := TLabel.Create(Self);
  lblBanner.Parent := Self;
  lblBanner.Align := alTop;
  lblBanner.Height := 34;
  lblBanner.Alignment := taCenter;
  lblBanner.Layout := tlCenter;
  lblBanner.Font.Size := 15;
  lblBanner.Font.Style := [fsBold];
  lblBanner.Color := clNavy;
  lblBanner.Font.Color := clWhite;
  lblBanner.ParentColor := False;
  lblBanner.Transparent := False;
  lblBanner.Caption := '  VDB Studio  ';

  // ---- Ust araclar / top toolbar ----
  pnlTop := TPanel.Create(Self);
  pnlTop.Parent := Self;
  pnlTop.Align := alTop;
  pnlTop.Height := 44;
  pnlTop.BevelOuter := bvNone;

  btnOpen := TButton.Create(Self);
  btnOpen.Parent := pnlTop; btnOpen.SetBounds(8, 8, 130, 28);
  btnOpen.OnClick := btnOpenClick;

  btnRun := TButton.Create(Self);
  btnRun.Parent := pnlTop; btnRun.SetBounds(144, 8, 110, 28);
  btnRun.OnClick := btnRunClick;

  btnIns := TButton.Create(Self);
  btnIns.Parent := pnlTop; btnIns.SetBounds(258, 8, 110, 28);
  btnIns.OnClick := btnInsClick;

  btnDel := TButton.Create(Self);
  btnDel.Parent := pnlTop; btnDel.SetBounds(372, 8, 110, 28);
  btnDel.OnClick := btnDelClick;

  btnRefresh := TButton.Create(Self);
  btnRefresh.Parent := pnlTop; btnRefresh.SetBounds(486, 8, 110, 28);
  btnRefresh.OnClick := btnRefreshClick;

  btnLang := TButton.Create(Self);
  btnLang.Parent := pnlTop; btnLang.SetBounds(880, 8, 120, 28);
  btnLang.OnClick := btnLangClick;

  // ---- Sol tablo listesi / left table list ----
  pnlLeft := TPanel.Create(Self);
  pnlLeft.Parent := Self;
  pnlLeft.Align := alLeft;
  pnlLeft.Width := 210;
  pnlLeft.BevelOuter := bvNone;

  lblTables := TLabel.Create(Self);
  lblTables.Parent := pnlLeft;
  lblTables.Align := alTop;
  lblTables.Height := 26;
  lblTables.Layout := tlCenter;
  lblTables.Font.Style := [fsBold];
  lblTables.Caption := '  Tablolar';

  lstTables := TListBox.Create(Self);
  lstTables.Parent := pnlLeft;
  lstTables.Align := alClient;
  lstTables.OnClick := lstTablesClick;

  // ---- SQL editor paneli / SQL editor panel ----
  pnlSQLEdit := TPanel.Create(Self);
  pnlSQLEdit.Parent := Self;
  pnlSQLEdit.Align := alTop;
  pnlSQLEdit.Height := 110;
  pnlSQLEdit.BevelOuter := bvNone;

  lblSQLEdit := TLabel.Create(Self);
  lblSQLEdit.Parent := pnlSQLEdit;
  lblSQLEdit.Align := alTop;
  lblSQLEdit.Height := 22;
  lblSQLEdit.Layout := tlCenter;
  lblSQLEdit.Font.Style := [fsBold];
  lblSQLEdit.Caption := '  SQL:';

  memoSQL := TMemo.Create(Self);
  memoSQL.Parent := pnlSQLEdit;
  memoSQL.Align := alClient;
  memoSQL.Font.Name := 'Consolas';
  memoSQL.Font.Size := 11;
  memoSQL.Lines.Text := 'SELECT * FROM musteri ORDER BY id';
  memoSQL.ScrollBars := ssVertical;

  // ---- Navigator paneli / navigator panel ----
  pnlNav := TPanel.Create(Self);
  pnlNav.Parent := Self;
  pnlNav.Align := alTop;
  pnlNav.Height := 36;
  pnlNav.BevelOuter := bvNone;

  Nav := TDBNavigator.Create(Self);
  Nav.Parent := pnlNav;
  Nav.SetBounds(6, 4, 300, 28);
  Nav.ShowHint := True;

  // ---- Veri grid (DBGrid) / data grid ----
  Grid := TDBGrid.Create(Self);
  Grid.Parent := Self;
  Grid.Align := alClient;
  Grid.ReadOnly := False;
  Grid.Options := Grid.Options + [dgColumnResize, dgRowLines, dgColLines,
                                  dgRowSelect, dgAlwaysShowSelection];
  Grid.TitleFont.Style := [fsBold];

  // ---- Durum cubugu / status bar ----
  sb := TStatusBar.Create(Self);
  sb.Parent := Self;
  sb.SimplePanel := False;
  with TStatusPanel.Create(sb.Panels) do begin Width := 260; end;
  with TStatusPanel.Create(sb.Panels) do begin Width := 160; end;
  with TStatusPanel.Create(sb.Panels) do begin Width := 520; end;

  // ---- Veri katmanlarini kur (henuz acilmadi) / data layers (not opened) ----
  Qry := TVDbQuery.Create(nil);
  DS := TDataSource.Create(Self);
  DS.DataSet := Qry;
  Grid.DataSource := DS;
  Nav.DataSource := DS;
end;

{ ===================================================================== }
{  Arayuzu cevir / translate UI (TR/EN)                                 }
{ ===================================================================== }
procedure TfrmMain.TranslateUI;
begin
  Caption := 'VDB Studio — ' + L('Ornek GUI', 'GUI Example');
  lblBanner.Caption := '  VDB Studio — ' +
    L('Gorsel Veritabani Demosu', 'Visual Database Demo') + '  ';

  btnOpen.Caption    := L('Veritabani Ac', 'Open DB');
  btnRun.Caption     := L('Calistir (F5)', 'Run (F5)');
  btnIns.Caption     := L('Yeni Kayit', 'New Record');
  btnDel.Caption     := L('Kayit Sil', 'Delete Record');
  btnRefresh.Caption := L('Yenile', 'Refresh');
  btnLang.Caption    := L('EN', 'TR');   // TR: su an TR, EN'ye gec / EN: switch

  btnOpen.Hint    := L('Ornek veritabanini olustur/aç', 'Create/open the sample database');
  btnRun.Hint     := L('SQL kutusundaki komutu calistir', 'Run the SQL in the editor');
  btnIns.Hint     := L('Grid icin bos bir kayit ekle', 'Insert a blank record into the grid');
  btnDel.Hint     := L('Secili kaydi sil', 'Delete the selected record');
  btnRefresh.Hint := L('Aktif tabloyu yeniden yukle', 'Reload the active table');
  btnLang.Hint    := L('Arayuz dilini Ingilizce yap', 'Switch UI to English');

  lblTables.Caption  := '  ' + L('Tablolar', 'Tables');
  lblSQLEdit.Caption := '  ' + L('SQL komutu:', 'SQL command:');

  LoadTableList;   // tablo adlari zaten veri (dil bagimsiz) / table names are data
  SetStatus(L('Hazir', 'Ready'));
end;

{ ===================================================================== }
{  Durum cubugu / status bar                                            }
{ ===================================================================== }
procedure TfrmMain.SetStatus(const Msg: string);
begin
  if sb.Panels.Count >= 3 then
  begin
    sb.Panels[0].Text := ' ' + Msg;
    if LangEN then sb.Panels[1].Text := ' Language: English'
              else sb.Panels[1].Text := ' Dil: Turkce';
    if FDBPath <> '' then sb.Panels[2].Text := ' DB: ' + FDBPath
                     else sb.Panels[2].Text := ' DB: -';
  end
  else
    sb.SimpleText := Msg;
end;

{ ===================================================================== }
{  Veritabani ac + ornek veri / open DB + seed sample data              }
{ ===================================================================== }
procedure TfrmMain.OpenDatabase;
begin
  if Assigned(SQ) then Exit;   // zaten acik / already open

  FDBPath := 'ornek11_db';
  VdbOpenOrCreate(FDBPath, Be);
  TB := TVTableDb.CreateBackend(Be);
  SQ := TVSql.Create(TB);
  TB.Open(FDBPath);
  Qry.SqlEngine := SQ;

  EnsureSampleData;
  LoadTableList;
  RunSQL('SELECT * FROM musteri ORDER BY id');

  SetStatus(L('Veritabani acildi + ornek veri yuklendi',
              'Database opened + sample data loaded'));
end;

procedure TfrmMain.EnsureSampleData;
begin
  // TR: Tablolar yoksa olustur ve ornek veri gir.
  // EN: Create tables (if missing) and insert sample data.
  try
    SQ.Exec('CREATE TABLE musteri (id INTEGER PRIMARY KEY, ad TEXT, sehir TEXT, bakiye FLOAT)');
    SQ.Exec('INSERT INTO musteri (id, ad, sehir, bakiye) VALUES (1, ''Ali Veli'', ''Istanbul'', 12500.50)');
    SQ.Exec('INSERT INTO musteri (id, ad, sehir, bakiye) VALUES (2, ''Ayse Demir'', ''Ankara'', 8300.00)');
    SQ.Exec('INSERT INTO musteri (id, ad, sehir, bakiye) VALUES (3, ''Mehmet Can'', ''Izmir'', 21000.75)');
    SQ.Exec('INSERT INTO musteri (id, ad, sehir, bakiye) VALUES (4, ''Fatma Oz'', ''Bursa'', 4200.25)');
    SQ.Exec('INSERT INTO musteri (id, ad, sehir, bakiye) VALUES (5, ''John Smith'', ''London'', 9900.00)');
  except
    // TR: tablo zaten var — sorun degil / EN: table already exists — fine
  end;
  try
    SQ.Exec('CREATE TABLE siparis (id INTEGER PRIMARY KEY, musteri_id INTEGER, urun TEXT, tutar FLOAT)');
    SQ.Exec('INSERT INTO siparis (id, musteri_id, urun, tutar) VALUES (1, 1, ''Laptop'', 15000)');
    SQ.Exec('INSERT INTO siparis (id, musteri_id, urun, tutar) VALUES (2, 1, ''Fare'', 250)');
    SQ.Exec('INSERT INTO siparis (id, musteri_id, urun, tutar) VALUES (3, 2, ''Klavye'', 750)');
    SQ.Exec('INSERT INTO siparis (id, musteri_id, urun, tutar) VALUES (4, 3, ''Monitor'', 4200)');
    SQ.Exec('INSERT INTO siparis (id, musteri_id, urun, tutar) VALUES (5, 5, ''Laptop'', 18000)');
  except
  end;
  try
    SQ.Exec('CREATE TABLE urun (id INTEGER PRIMARY KEY, ad TEXT, fiyat FLOAT, stok INTEGER)');
    SQ.Exec('INSERT INTO urun (id, ad, fiyat, stok) VALUES (1, ''Laptop'', 15000, 12)');
    SQ.Exec('INSERT INTO urun (id, ad, fiyat, stok) VALUES (2, ''Fare'', 250, 120)');
    SQ.Exec('INSERT INTO urun (id, ad, fiyat, stok) VALUES (3, ''Klavye'', 750, 65)');
    SQ.Exec('INSERT INTO urun (id, ad, fiyat, stok) VALUES (4, ''Monitor'', 4200, 30)');
  except
  end;
end;

{ ===================================================================== }
{  Tablo listesi / table list                                           }
{ ===================================================================== }
procedure TfrmMain.LoadTableList;
var
  R: TSqlResult;
  I: Integer;
begin
  lstTables.Items.BeginUpdate;
  try
    lstTables.Items.Clear;
    if not Assigned(SQ) then Exit;
    R := SQ.Exec('SHOW TABLES');
    for I := 0 to High(R.Rows) do
      if Length(R.Rows[I]) > 0 then
        lstTables.Items.Add(R.Rows[I][0]);
  finally
    lstTables.Items.EndUpdate;
  end;
end;

{ ===================================================================== }
{  SQL calistir / run SQL                                               }
{ ===================================================================== }
function TfrmMain.IsQuerySQL(const S: string): Boolean;
var
  k: string;
begin
  k := UpperCase(Trim(S));
  Result := (Pos('SELECT', k) = 1) or (Pos('SHOW', k) = 1) or
            (Pos('DESC', k) = 1) or (Pos('EXPLAIN', k) = 1) or
            (Pos('WITH', k) = 1) or (Pos('LIST', k) = 1);
end;

procedure TfrmMain.RunSQL(const AText: string);
var
  s: string;
  R: TSqlResult;
  N: Integer;
begin
  if not Assigned(SQ) then
  begin
    SetStatus(L('Once "Veritabani Ac" deyin', 'Click "Open DB" first'));
    Exit;
  end;

  s := Trim(AText);
  if s = '' then Exit;

  try
    if IsQuerySQL(s) then
    begin
      // TR: Sonuc ureten sorgu -> DBGrid
      // EN: Row-returning query -> DBGrid
      if Qry.Active then Qry.Close;
      Qry.SQL.Text := s;
      Qry.Open;
      N := Qry.RowCount;
      SetStatus(Format(L('%d satir getirildi', '%d rows fetched'), [N]));
    end
    else
    begin
      // TR: DDL/DML -> calistir, sonra aktif tabloyu tazele.
      // EN: DDL/DML -> execute, then refresh the active table.
      R := SQ.Exec(s);
      if R.Affected > 0 then
        SetStatus(Format(L('%d satir etkilendi', '%d rows affected'), [R.Affected]))
      else
        SetStatus(L('Komut calistirildi', 'Command executed'));
      LoadTableList;
      RefreshActive;
    end;
  except
    on E: Exception do
      SetStatus(L('Hata: ', 'Error: ') + E.Message);
  end;
end;

procedure TfrmMain.RefreshActive;
begin
  if FActiveTable <> '' then
    RunSQL('SELECT * FROM ' + FActiveTable + ' ORDER BY 1')
  else
    RunSQL(memoSQL.Lines.Text);
end;

{ ===================================================================== }
{  Olaylar / events                                                     }
{ ===================================================================== }
procedure TfrmMain.btnOpenClick(Sender: TObject);
begin
  try
    OpenDatabase;
  except
    on E: Exception do
      SetStatus(L('Hata: ', 'Error: ') + E.Message);
  end;
end;

procedure TfrmMain.btnRunClick(Sender: TObject);
begin
  RunSQL(memoSQL.Lines.Text);
end;

procedure TfrmMain.btnInsClick(Sender: TObject);
begin
  if not Assigned(SQ) then Exit;
  if Qry.Active and Qry.CanModify then
  begin
    Qry.Append;
    SetStatus(L('Yeni kayit — bosluklari doldurup Enter/Post',
                'New record — fill fields and press Enter/Post'));
  end
  else
    SetStatus(L('Bu gorunumde kayit eklenemez',
                'Cannot insert into this view'));
end;

procedure TfrmMain.btnDelClick(Sender: TObject);
begin
  if not Assigned(SQ) then Exit;
  if Qry.Active and Qry.CanModify and (Qry.RecordCount > 0) then
  begin
    if MessageDlg(L('Secili kaydi sil?', 'Delete selected record?'),
                  mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    begin
      Qry.Delete;
      SetStatus(L('Kayit silindi', 'Record deleted'));
    end;
  end
  else
    SetStatus(L('Silinecek kayit yok / salt-okunur',
                'No record to delete / read-only'));
end;

procedure TfrmMain.btnRefreshClick(Sender: TObject);
begin
  if Assigned(SQ) then
  begin
    LoadTableList;
    RefreshActive;
    SetStatus(L('Yenilendi', 'Refreshed'));
  end;
end;

procedure TfrmMain.btnLangClick(Sender: TObject);
begin
  LangEN := not LangEN;
  TranslateUI;
  if LangEN then SetStatus('Language switched to English')
            else SetStatus('Dil Turkce olarak ayarlandi');
end;

procedure TfrmMain.lstTablesClick(Sender: TObject);
var
  t: string;
begin
  if lstTables.ItemIndex < 0 then Exit;
  t := lstTables.Items[lstTables.ItemIndex];
  if t = '' then Exit;
  FActiveTable := t;
  memoSQL.Lines.Text := 'SELECT * FROM ' + t + ' ORDER BY 1';
  RunSQL(memoSQL.Lines.Text);
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  // TR: Baglantilari kopar, dogru sirada free et.
  // EN: Unlink, then free in the correct order.
  if Assigned(Grid) then Grid.DataSource := nil;
  if Assigned(Nav) then Nav.DataSource := nil;
  if Assigned(DS) then DS.DataSet := nil;
  FreeAndNil(Qry);
  FreeAndNil(SQ);
  FreeAndNil(TB);
  Be := nil;
end;

{ ===================================================================== }
begin
  Application.Initialize;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.