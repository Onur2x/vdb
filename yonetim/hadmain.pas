unit hadmain;

{ VDb Manager v2 - phpMyAdmin tarzi yonetim programi.
  Menu + toolbar, sol agac, sekmeler: Yapi / Veri / Indeksler / Sema / SQL / Araclar.
  ASCII-Turkce (kodlama sorunu cikarmaz). Tum arayuz kodla kurulur (.lfm yok). }

{$mode delphi}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, Grids,
  ComCtrls, Menus, ExtCtrls, FileUtil, Clipbrd, LCLType,
  VDbCore, VDbTable, VDbSql, VDbJson, VDbTypes, haddlg, hadtools,
  uLang, TypInfo;

type
  { 2026-10-04 (M10): TEK TASARIM SISTEMI.
    Butun renk, olcu ve tipografi degerleri BURADA tanimlanir.
    Arayuzdeki hicbir kontrol icin icine gomulmus sabit renk
    kullanilmaz; hepsi bu paletten gelir. Boylece tema degisimi
    tutarli olur ve yeni kontrol eklenince tek bir yeri guncellemek
    yeterlidir.

    DUZ (flat) ilkesi: kalkinlik, golge ve ic bosluk yok; ayrim
    yalnizca 1 piksel cerceve ve renk kontrastiyla saglanir. }
  TUIStyle = record
    { yuzeyler }
    Surface: TColor;        // ana zemin
    SurfaceAlt: TColor;     // ikincil zemin (baslik/alternatif satir)
    SurfaceSun: TColor;     // vurgulu yuzey (kart, secim)
    { metin }
    Text: TColor;           // birincil metin
    TextMuted: TColor;      // ikincil/yardimci metin
    TextInverse: TColor;    // vurgulu zemindeki metin
    { cizgi / odak }
    Border: TColor;         // 1 px ayirici
    Focus: TColor;          // odak halkasi
    { secim }
    SelectBG: TColor;
    SelectFG: TColor;
    { durum }
    Ok: TColor;             // saglikli / basarili
    Warn: TColor;           // uyari
    Danger: TColor;         // tehlike / sil
    Accent: TColor;         // birincil eylem
    { olcu }
    RowH: Integer;          // grid satir yuksekligi (tüm gridlerde tek deger)
    { tipografi }
    FontUI: string;         // arayuz yazitipi
    FontMono: string;       // kod/SQL yazitipi
    FontUIHeight: Integer;
    FontMonoHeight: Integer;
  end;

var
  { Aktif palet. ApplyTheme bunu doldurur; kontroller buradan okur. }
  UIStyle: TUIStyle;

procedure UIStyleLight;
procedure UIStyleDark;

type
  TfrmMain = class(TForm)
  private
    FKv: TVDb;
    FTb: TVTableDb;
    FSq: TVSql;
    FCurrentDBDir: string;
    FCurrentTable: string;
    FDBPath: string;
    // veri sayfalama onbellegi
    FDataPks: TStrArray;
    FDataRows: TStrMatrix;
    FPage: Integer;
    FPageSize: Integer;
    FWhere: string;
    FSortCol: string;
    FSortDesc: Boolean;
    FDark: Boolean;
    FQrySql: TStringList;
    // arayuz
    pnlLeft: TPanel;
    tvList: TTreeView;
    split: TSplitter;
    searchBox: TEdit;
    pcMain: TPageControl;
    tsDB, tsTable, tsData, tsIdx, tsSchema, tsSQL, tsTools: TTabSheet;
    lblDBInfo: TLabel;
    sgTable: TStringGrid;
    sgData: TStringGrid;
    sgIdx: TStringGrid;
    sgSQLRes: TStringGrid;
    meSQL: TMemo;
    meSchema: TMemo;
    meLog: TMemo;
    edTableName: TEdit;
    edIdxName: TEdit;
    cbEdit: TComboBox;
    cbIdxCol: TComboBox;
  cbIdxUnique: TCheckBox;   // 2026-10-04: CREATE UNIQUE INDEX secenegi
    cbPageSize: TComboBox;
    cbHist: TComboBox;
    cbSaved: TComboBox;
    // dil secici / language selector (2026-10-14)
    FUILang: TComboBox;
    pnlLang: TPanel;
    lblLang: TLabel;
    cbSqlTemplates: TComboBox;
    pmRes: TPopupMenu;
    cbSortCol: TComboBox;
    cbSortDir: TComboBox;
    edFilter: TEdit;
    edFind: TEdit;
    sgFind: TStringGrid;
    sgDB: TStringGrid;
    bWalStatus, bWalReplay, bWalCkpt: TToolButton;  // 2026-10-04 (M9): WAL araclari
    { 2026-10-04 (M10): otomatik WAL (write-ahead) anahtari. Kapalıyken
      motor eski davranisinda (yazma dogrudan ana dosyaya). Acikken her
      yazma once .wal'a sonra ana dosyaya gider. }
    bWalAuto: TToolButton;
    sgFKOut: TStringGrid;
    sgFKIn: TStringGrid;
    tsFind: TTabSheet;
    tsRel: TTabSheet;
    chkAutoBak: TCheckBox;
    lblTx: TLabel;
    lblBannerSub: TLabel;
    shpHealth: TShape;
    lblHealth: TLabel;
    cardsPanel: TPanel;
    lblCardTbl: TLabel;
    lblCardRow: TLabel;
    lblCardSize: TLabel;
    lblCardHealth: TLabel;
    FHealthTxt: string;
    banner: TPanel;
    pnlHR: TPanel;        // 2026-10-04 (M10): ApplyTheme erisebilsin
    pnlStripe: TPanel;
    titleLbl: TLabel;
    tmPulse: TTimer;
    il: TImageList;
    miTheme: TMenuItem;
    lblPage: TLabel;
    lblTblData: TLabel;
    lblResult: TLabel;
    sb: TStatusBar;
    FHist: TStringList;
    procedure CreateUI;
    procedure BuildMenu;
    // dil / language (2026-10-14)
    procedure TranslateUI;
    procedure LangChange(Sender: TObject);
    procedure cbSqlTemplatesChange(Sender: TObject);
    procedure btnSqlCopyTSVClick(Sender: TObject);
    procedure btnSqlSaveCSVClick(Sender: TObject);
    procedure btnSqlSaveJSONClick(Sender: TObject);
    procedure btnDataSaveCSVClick(Sender: TObject);
    // veritabani / agac
    procedure EnsureOpen;
    procedure OpenDB(const FilePath: string);
    procedure CloseDB;
    procedure RefreshTree;
    function SelectedDbPath(Node: TTreeNode): string;
    // tablo
    procedure SelectTable(const Tbl: string);
    procedure ShowTableStructure;
    // veri
    procedure ReloadData;
    procedure RenderPage;
    function SqlVal(const V: string): string;
    // indeks / sema
    procedure RefreshIndexes;
    procedure RefreshSchema;
    // sql
    procedure ExecuteSQL(const SqlText: string);
    procedure PushHist(const S: string);
    // yardimci
    procedure SetStatus(const Msg: string);
    procedure SetHealth(const Msg: string);
    procedure PulseTimer(Sender: TObject);
    procedure Log(const Msg: string);
    function DbSizeStr(const P: string): string;
    // olaylar
    procedure btnOpenDBClick(Sender: TObject);
    procedure btnNewDBClick(Sender: TObject);
    procedure btnDropDBClick(Sender: TObject);
    procedure btnBackupClick(Sender: TObject);
    procedure btnVerifyClick(Sender: TObject);
    procedure btnCompactClick(Sender: TObject);
  function DBInfoText: string;
    function AgeText(const P: string): string;
    procedure btnReindexClick(Sender: TObject);
  procedure btnAutoCompactClick(Sender: TObject);
    procedure btnWalStatusClick(Sender: TObject);
    procedure RefreshWalUI;
    procedure btnWalReplayClick(Sender: TObject);
    procedure btnWalCheckpointClick(Sender: TObject);
procedure btnWalAutoClick(Sender: TObject);
    procedure btnDescribeClick(Sender: TObject);
    procedure btnShowIndexesClick(Sender: TObject);
    procedure btnShowCreateClick(Sender: TObject);
    procedure btnSchemaSqlClick(Sender: TObject);
    procedure btnRefreshAllClick(Sender: TObject);
    procedure chkAutoBakClick(Sender: TObject);
    procedure btnExportClick(Sender: TObject);
    procedure btnImportClick(Sender: TObject);
    procedure mnuExitClick(Sender: TObject);
    procedure mnuAboutClick(Sender: TObject);
    procedure btnNewTableClick(Sender: TObject);
    procedure btnDropTableClick(Sender: TObject);
    procedure btnRenameTableClick(Sender: TObject);
    procedure btnAddColClick(Sender: TObject);
    procedure btnDropColClick(Sender: TObject);
    procedure btnRenameColClick(Sender: TObject);
    procedure btnIdxAddClick(Sender: TObject);
    procedure btnIdxDropClick(Sender: TObject);
    procedure btnExecSQLClick(Sender: TObject);
    procedure RunSchemaQuery(const Q: string);
    procedure btnSqlClearClick(Sender: TObject);
    procedure cbHistChange(Sender: TObject);
    procedure btnFirstClick(Sender: TObject);
    procedure btnPrevClick(Sender: TObject);
    procedure btnNextClick(Sender: TObject);
    procedure btnLastClick(Sender: TObject);
    procedure cbPageSizeChange(Sender: TObject);
    procedure btnAddRowClick(Sender: TObject);
    procedure btnDelRowClick(Sender: TObject);
    procedure btnRefreshDataClick(Sender: TObject);
    procedure sgDataSetEditText(Sender: TObject; ACol, ARow: Integer;
      const Value: string);
    procedure sgTableSelectEditor(Sender: TObject; ACol, ARow: Integer;
      var Editor: TWinControl);
    procedure sgTableValidateEntry(Sender: TObject; ACol, ARow: Integer;
      const OldValue: string; var NewValue: string);
    procedure gridPrepareCanvas(Sender: TObject; ACol, ARow: Integer;
      AState: TGridDrawState);
    procedure tvListClick(Sender: TObject);
    procedure tvListDblClick(Sender: TObject);
    procedure FilterTreeView(Sender: TObject);
    procedure pcMainChange(Sender: TObject);
    procedure btnFilterGoClick(Sender: TObject);
    procedure btnFilterClearClick(Sender: TObject);
    procedure btnFindClick(Sender: TObject);
    procedure edFindKeyPress(Sender: TObject; var Key: Char);
    procedure sgFindDblClick(Sender: TObject);
    procedure btnSaveQryClick(Sender: TObject);
    procedure btnDelQryClick(Sender: TObject);
    procedure cbSavedChange(Sender: TObject);
    procedure mnuThemeClick(Sender: TObject);
    procedure btnExportCSVClick(Sender: TObject);
    procedure btnImportCSVClick(Sender: TObject);
    procedure btnDumpSQLClick(Sender: TObject);
    procedure RefreshDashboard;
    procedure RefreshRelations;
    procedure sgDataHeaderClick(Sender: TObject; IsColumn: Boolean;
      index: Integer);
    procedure btnSqlFileRunClick(Sender: TObject);
    procedure btnSqlSaveClick(Sender: TObject);
    procedure btnTxBeginClick(Sender: TObject);
    procedure btnTxCommitClick(Sender: TObject);
    procedure btnTxRollbackClick(Sender: TObject);
    procedure UpdateTx;
    procedure btnCopyTableClick(Sender: TObject);
    procedure LoadSettings;
    procedure SaveSettings;
    procedure BuildIcons;
    procedure ApplyTheme;
    procedure LoadTheme;
    procedure SaveTheme;
    procedure LoadQueries;
    procedure SaveQueries;
    function QryPath: string;
    procedure GlobalSearch(const Txt: string);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  frmMain: TfrmMain;

implementation

{ ---------------- M10: tasarim sistemi paletleri ---------------- }
// Tum degerler tek yerde. Sayilar BGR (Lazarus Color = $00BBGGRR).

function Lighten(const C: TColor; const Amt: Single): TColor;
// Rengi beyaza dogru Amt oraninda karistirir (nabiz efekti icin).
var
  r, g, b: Integer;
begin
  r := C and $FF;
  g := (C shr 8) and $FF;
  b := (C shr 16) and $FF;
  r := r + Integer((255 - r) * Amt);
  g := g + Integer((255 - g) * Amt);
  b := b + Integer((255 - b) * Amt);
  Result := TColor(r or (g shl 8) or (b shl 16));
end;

procedure UIStyleLight;
// Acik tema: Modern, temiz, profesyonel - Notion/Linear tarzi
begin
  UIStyle.Surface      := $00FFFFFF;   // Beyaz ana yüzey
  UIStyle.SurfaceAlt   := $00F8FAFC;   // Çok açık gri (kartlar, sidebar)
  UIStyle.SurfaceSun   := $00EEF2FF;   // Açık mavi vurgu (seçili, hover)
  UIStyle.Text         := $001E293B;   // Koyu slate - ana metin
  UIStyle.TextMuted    := $0064748B;   // Orta gri - ikincil metin
  UIStyle.TextInverse  := $00FFFFFF;
  UIStyle.Border       := $00E2E8F0;   // Çok ince border
  UIStyle.Focus        := $003B82F6;   // Mavi odak halkası
  UIStyle.SelectBG     := $00DBEAFE;   // Açık mavi seçim arka planı
  UIStyle.SelectFG     := $001E3A5F;   // Koyu mavi seçim metni
  UIStyle.Ok           := $00059669;   // Emerald - başarı
  UIStyle.Warn         := $00D97706;   // Amber - uyarı
  UIStyle.Danger       := $00DC2626;   // Red - tehlike
  UIStyle.Accent       := $003B82F6;   // Blue - birincil eylem
  UIStyle.RowH         := 28;          // Daha geniş satır yüksekliği
  UIStyle.FontUI       := 'Segoe UI';
  UIStyle.FontMono     := 'JetBrains Mono, Consolas, Monospace';
  UIStyle.FontUIHeight := 9;
  UIStyle.FontMonoHeight := 10;
end;

procedure UIStyleDark;
// Koyu tema: Modern, göz yormayan - VS Code/GitHub Dark tarzi
begin
  UIStyle.Surface      := $000F172A;   // Slate 950 - ana yüzey
  UIStyle.SurfaceAlt   := $001E293B;   // Slate 800 - kartlar, sidebar
  UIStyle.SurfaceSun   := $00312E81;   // Indigo 900 - vurgu, seçim
  UIStyle.Text         := $00F1F5F9;   // Slate 100 - ana metin
  UIStyle.TextMuted    := $0094A3B8;   // Slate 400 - ikincil metin
  UIStyle.TextInverse  := $000F172A;
  UIStyle.Border       := $00334155;   // Slate 700 - ince border
  UIStyle.Focus        := $0060A5FA;   // Blue 400 - odak halkası
  UIStyle.SelectBG     := $001E3A5F;   // Blue 900 - seçim arka planı
  UIStyle.SelectFG     := $00DBEAFE;   // Blue 100 - seçim metni
  UIStyle.Ok           := $0010B981;   // Emerald 500 - başarı
  UIStyle.Warn         := $00F59E0B;   // Amber 500 - uyarı
  UIStyle.Danger       := $00EF4444;   // Red 500 - tehlike
  UIStyle.Accent       := $006366F1;   // Indigo 500 - birincil eylem
  UIStyle.RowH         := 28;
  UIStyle.FontUI       := 'Segoe UI';
  UIStyle.FontMono     := 'JetBrains Mono, Consolas, Monospace';
  UIStyle.FontUIHeight := 9;
  UIStyle.FontMonoHeight := 10;
end;

constructor TfrmMain.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  FPageSize := 100;
  FPage := 0;
  FWhere := '';
  FSortCol := '';
  FSortDesc := False;
  FDark := False;
  FCurrentDBDir := 'D:\veritabani\db';
  FHist := TStringList.Create;
  FQrySql := TStringList.Create;
  il := TImageList.Create(Self);
  il.Width := 16;
  il.Height := 16;
  BuildIcons;
  LoadTheme;
  // 2026-10-04 (M10): Palet KURULMADAN once CreateUI calisirsa
  // kontrollerin ilk renkleri bos (siyah) degerlerle atanir ve
  // ilk boyama sirasinda beyaz zeminde gorunmez metin olusur.
  // Bu yuzden palet burada bir kez dolduruluyor; ApplyTheme sonra
  // ayni paleti uyguluyor.
  if FDark then UIStyleDark else UIStyleLight;
  CreateUI;
  ApplyTheme;
  LoadQueries;
  LoadSettings;
  if FDBPath = '' then
  begin
    RefreshTree;
    if FileExists(FCurrentDBDir + '\veritabani.odb') then
      OpenDB(FCurrentDBDir + '\veritabani.odb');
  end;

  // 2026-10-14: Arayuzu aktif dile cevir (varsayilan: Ingilizce).
  TranslateUI;
end;

destructor TfrmMain.Destroy;
begin
  try
    CloseDB;
  except
  end;
  FHist.Free;
  FQrySql.Free;
  inherited Destroy;
end;

{ ---------------- arayuz ---------------- }

procedure TfrmMain.CreateUI;
var
  tb: TToolBar;

  function BarBtn(AParent: TToolBar; const C: string; W: Integer): TToolButton;
  begin
    Result := TToolButton.Create(Self);
    Result.Parent := AParent;
    Result.Caption := C;
    Result.Width := W;
  end;

  function TabBtn(ATab: TTabSheet; const C: string): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := ATab;
    Result.Align := alTop;
    Result.Height := 28;
    Result.Caption := C;
  end;

  function TabBar(ATab: TTabSheet): TToolBar;
  begin
    Result := TToolBar.Create(Self);
    Result.Parent := ATab;
    Result.Align := alTop;
    Result.ButtonHeight := 28;
    Result.ButtonWidth := 100;
    Result.ShowCaptions := True;
    Result.ShowHint := True;
    Result.EdgeBorders := [];
    Result.Images := il;
  end;

  procedure BarSep(AParent: TToolBar);
  var
    sp: TToolButton;
  begin
    sp := TToolButton.Create(Self);
    sp.Parent := AParent;
    sp.Style := tbsSeparator;
    sp.Width := 10;
  end;

  function NewCard(const Cap: string; out Val: TLabel): TPanel;
  var
    c: TLabel;
  begin
    Result := TPanel.Create(Self);
    Result.Parent := cardsPanel;
    Result.Align := alLeft;
    Result.Width := 200;
    Result.Height := 90;
    Result.BevelOuter := bvNone;
    Result.BevelInner := bvNone;
    Result.BorderWidth := 1;
    Result.BorderStyle := bsSingle;
    Result.Color := $001E293B;
    Val := TLabel.Create(Self);
    Val.Parent := Result;
    Val.Align := alClient;
    Val.Alignment := taCenter;
    Val.Layout := tlCenter;
    Val.Caption := '-';
    Val.Font.Name := 'Segoe UI';
    Val.Font.Size := 26;
    Val.Font.Style := [fsBold];
    Val.Font.Color := $0094A3B8;
    c := TLabel.Create(Self);
    c.Parent := Result;
    c.Align := alBottom;
    c.Height := 24;
    c.Alignment := taCenter;
    c.Caption := Cap;
    c.Font.Name := 'Segoe UI';
    c.Font.Color := $0064748B;
    c.Font.Size := 9;
  end;

var
  bar: TToolBar;
  b: TToolButton;
  hdr: TPanel;
  hdrLbl: TLabel;
  pm: TPopupMenu;
  mi: TMenuItem;
begin
  Width := 1200;
  Height := 800;
  Position := poScreenCenter;
  Caption := 'VDb Studio — Veritabani Yonetim Merkezi';
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  KeyPreview := True;
  OnKeyDown := FormKeyDown;

  BuildMenu;

  // Duz ust banner (M10): tek yuzey + ince vurgu seridi, kalkinlik yok.
  banner := TPanel.Create(Self);
  banner.Parent := Self;
  banner.Align := alTop;
  banner.Height := 58;
  banner.BevelOuter := bvNone;
  banner.Color := UIStyle.SurfaceSun;  // M10: ApplyTheme'de paletten boyanir
  pnlStripe := TPanel.Create(Self);
  pnlStripe.Parent := banner;
  pnlStripe.Width := 4;
  pnlStripe.Height := 58;
  pnlStripe.Align := alLeft;
  pnlStripe.BevelOuter := bvNone;
  pnlStripe.Color := UIStyle.Accent;    // M10: ApplyTheme'de paletten
  // Title
  titleLbl := TLabel.Create(Self);
  titleLbl.Parent := banner;
  titleLbl.Align := alLeft;
  titleLbl.Width := 220;
  titleLbl.Caption := '  VDb Studio';
  titleLbl.Font.Size := 16;
  titleLbl.Font.Style := [fsBold];
  titleLbl.Font.Color := UIStyle.Text;
  titleLbl.Layout := tlCenter;
  // Subtitle
  lblBannerSub := TLabel.Create(Self);
  lblBannerSub.Parent := banner;
  lblBannerSub.Align := alClient;
  lblBannerSub.Caption := 'kapali - bir veritabani acin';
  lblBannerSub.Font.Color := UIStyle.TextMuted;
  lblBannerSub.Layout := tlCenter;

  // Dil secici (sag ust) / Language selector (top-right)
  pnlLang := TPanel.Create(Self);
  pnlLang.Parent := banner;
  pnlLang.Align := alRight;
  pnlLang.Width := 158;
  pnlLang.BevelOuter := bvNone;
  pnlLang.Color := UIStyle.SurfaceSun;
  lblLang := TLabel.Create(Self);
  lblLang.Parent := pnlLang;
  lblLang.Left := 12;
  lblLang.Top := 21;
  lblLang.Caption := 'Dil:';
  lblLang.Font.Color := UIStyle.TextMuted;
  FUILang := TComboBox.Create(Self);
  FUILang.Parent := pnlLang;
  FUILang.SetBounds(52, 15, 96, 24);
  FUILang.Style := csDropDownList;
  FUILang.Items.Add('English');
  FUILang.Items.Add('Türkçe');
  FUILang.ItemIndex := 0;
  FUILang.OnChange := LangChange;
  FUILang.ShowHint := True;
  FUILang.Hint := 'Dil secimi / Language';

  // Health indicator (right side of banner)
  pnlHR := TPanel.Create(Self);
  pnlHR.Parent := banner;
  pnlHR.Align := alRight;
  pnlHR.Width := 170;
  pnlHR.BevelOuter := bvNone;
  pnlHR.Color := UIStyle.SurfaceSun;     // M10: ApplyTheme'de paletten
  shpHealth := TShape.Create(Self);
  shpHealth.Parent := pnlHR;
  shpHealth.Shape := stCircle;
  shpHealth.Width := 16;
  shpHealth.Height := 16;
  shpHealth.Left := 14;
  shpHealth.Top := 21;
  shpHealth.Brush.Color := clGray;
  shpHealth.Pen.Color := clWhite;
  lblHealth := TLabel.Create(Self);
  lblHealth.Parent := pnlHR;
  lblHealth.Left := 36;
  lblHealth.Top := 20;
  lblHealth.Caption := '';
  lblHealth.Font.Color := clWhite;
  lblHealth.Font.Style := [fsBold];

  tmPulse := TTimer.Create(Self);
  tmPulse.Interval := 600;
  tmPulse.OnTimer := PulseTimer;
  tmPulse.Enabled := False;

  tb := TToolBar.Create(Self);
  tb.Parent := Self;
  tb.Align := alTop;
  tb.ButtonHeight := 34;
  tb.ButtonWidth := 120;
  tb.ShowCaptions := True;
  tb.ShowHint := True;
  tb.EdgeBorders := [];
  tb.Flat := True;
  tb.Images := il;
  tb.Height := 42;
  b := BarBtn(tb, '  Ac', 80);
  b.ImageIndex := 1;
  b.Hint := 'Veritabani Ac (Ctrl+O)';
  b.OnClick := btnOpenDBClick;
  
  b := BarBtn(tb, '  Yeni', 80);
  b.ImageIndex := 0;
  b.Hint := 'Yeni Veritabani (Ctrl+N)';
  b.OnClick := btnNewDBClick;
  
  b := BarBtn(tb, '  Yedekle', 90);
  b.ImageIndex := 3;
  b.Hint := 'Yedek Al';
  b.OnClick := btnBackupClick;
  BarSep(tb);
  
  b := BarBtn(tb, '  Dogrula', 90);
  b.ImageIndex := 4;
  b.Hint := 'Butunluk Dogrula';
  b.OnClick := btnVerifyClick;
  b := BarBtn(tb, '  Vacuum', 90);
  b.ImageIndex := 5;
  b.Hint := 'VACUUM (Olu Verileri Temizle)';
  b.OnClick := btnCompactClick;
  BarSep(tb);
  b := BarBtn(tb, '  Yenile', 80);
  b.ImageIndex := 6;
  b.Hint := 'Listeyi Yenile (F5)';
  b.OnClick := btnRefreshAllClick;

  sb := TStatusBar.Create(Self);
  sb.Parent := Self;
  sb.Align := alBottom;
  sb.SimplePanel := False;
  sb.Height := 28;
  sb.Font.Size := 8;
  sb.Font.Name := 'Segoe UI';
  with sb.Panels.Add do
  begin
    Width := 480;
    Text := 'Hazir - Veritabani secilmedi';
  end;
  with sb.Panels.Add do
  begin
    Width := 200;
    Text := '';
  end;
  with sb.Panels.Add do
  begin
    Width := 180;
    Text := '';
    Alignment := taRightJustify;
  end;

  pnlLeft := TPanel.Create(Self);
  pnlLeft.Parent := Self;
  pnlLeft.Align := alLeft;
  pnlLeft.Width := 300;
  pnlLeft.BorderWidth := 0;
  pnlLeft.BorderStyle := bsNone;
  pnlLeft.BevelOuter := bvNone;
  hdr := TPanel.Create(Self);
  hdr.Parent := pnlLeft;
  hdr.Align := alTop;
  hdr.Height := 40;
  hdr.BorderStyle := bsNone;
  hdr.BevelOuter := bvNone;
  hdr.Color := UIStyle.SurfaceAlt;      // M10: ApplyTheme'de paletten (duz baslik)
  hdrLbl := TLabel.Create(Self);
  hdrLbl.Parent := hdr;
  hdrLbl.Align := alTop;
  hdrLbl.Height := 22;
  hdrLbl.Caption := '   ◆  Veritabanlari / Tablolar';
  hdrLbl.Font.Color := UIStyle.TextMuted;
  hdrLbl.Font.Style := [fsBold];
  hdrLbl.Font.Size := 8;
  hdrLbl.Layout := tlBottom;
  
  searchBox := TEdit.Create(Self);
  searchBox.Parent := hdr;
  searchBox.Align := alBottom;
  searchBox.Height := 28;
  searchBox.Font.Size := 9;
  searchBox.TextHint := 'Tablo ara...';
  searchBox.OnChange := FilterTreeView;
  
  tvList := TTreeView.Create(Self);
  tvList.Parent := pnlLeft;
  tvList.Align := alClient;
  tvList.ReadOnly := True;
  tvList.Images := il;
  tvList.OnClick := tvListClick;
  tvList.OnDblClick := tvListDblClick;
  tvList.BorderStyle := bsNone;
  tvList.Indent := 18;
  tvList.HideSelection := False;
  tvList.ShowLines := True;
  tvList.ShowRoot := False;
  tvList.RightClickSelect := True;

  split := TSplitter.Create(Self);
  split.Parent := Self;
  split.Align := alLeft;
  split.Width := 1;
  split.MinSize := 220;
  split.Color := UIStyle.Border;
  split.Beveled := False;

  pcMain := TPageControl.Create(Self);
  pcMain.Parent := Self;
  pcMain.Align := alClient;
  pcMain.OnChange := pcMainChange;
  pcMain.Multiline := False;
  pcMain.TabPosition := tpTop;

  // --- DB bilgi ---
  tsDB := TTabSheet.Create(pcMain);
  tsDB.PageControl := pcMain;
  tsDB.Caption := 'Veritabani';
  cardsPanel := TPanel.Create(Self);
  cardsPanel.Parent := tsDB;
  cardsPanel.Align := alTop;
  cardsPanel.Height := 92;
  cardsPanel.BevelOuter := bvNone;
  NewCard('TABLO', lblCardTbl);
  NewCard('SATIR', lblCardRow);
  NewCard('BOYUT', lblCardSize);
  NewCard('SAGLIK', lblCardHealth);
  lblDBInfo := TLabel.Create(Self);
  lblDBInfo.Parent := tsDB;
  lblDBInfo.Align := alTop;
  lblDBInfo.Height := 60;
  lblDBInfo.WordWrap := True;
  lblDBInfo.Caption := 'Henuz acik veritabani yok. Soldan cift tiklayin veya Ac... kullanin.';
  chkAutoBak := TCheckBox.Create(Self);
  chkAutoBak.Parent := tsDB;
  chkAutoBak.Align := alBottom;
  chkAutoBak.Height := 26;
  chkAutoBak.Caption := 'Acilista otomatik yedek al (.onceki)';
  chkAutoBak.OnClick := chkAutoBakClick;
  sgDB := TStringGrid.Create(Self);
  sgDB.Parent := tsDB;
  sgDB.Align := alClient;
  sgDB.FixedRows := 1;
  sgDB.ColCount := 2;
  sgDB.RowCount := 2;
  sgDB.DefaultRowHeight := 26;
  sgDB.Options := sgDB.Options + [goColSizing, goThumbTracking];
  sgDB.Cells[0,0] := 'Tablo';
  sgDB.Cells[1,0] := 'Satir';
  sgDB.OnPrepareCanvas := gridPrepareCanvas;
  sgDB.BorderSpacing.Around := 6;

  // --- Yapi ---
  tsTable := TTabSheet.Create(pcMain);
  tsTable.PageControl := pcMain;
  tsTable.Caption := 'Yapi';
  bar := TabBar(tsTable);
  b := BarBtn(bar, 'Yeni Tablo', 100);
  b.OnClick := btnNewTableClick;
  b := BarBtn(bar, 'Tablo Sil', 90);
  b.OnClick := btnDropTableClick;
  b := BarBtn(bar, 'Kopyala', 80);
  b.OnClick := btnCopyTableClick;
  b := BarBtn(bar, 'Adlandir', 90);
  b.OnClick := btnRenameTableClick;
  BarSep(bar);
  b := BarBtn(bar, 'Sutun Ekle', 100);
  b.OnClick := btnAddColClick;
  b := BarBtn(bar, 'Sutun Sil', 90);
  b.OnClick := btnDropColClick;
  edTableName := TEdit.Create(Self);
  edTableName.Parent := tsTable;
  edTableName.Align := alTop;
  edTableName.Height := 26;
  edTableName.ReadOnly := True;
  edTableName.Text := '';
  sgTable := TStringGrid.Create(Self);
  sgTable.Parent := tsTable;
  sgTable.Align := alClient;
  sgTable.FixedRows := 1;
  sgTable.ColCount := 7;
  sgTable.RowCount := 2;
  sgTable.DefaultRowHeight := 26;
  sgTable.Options := sgTable.Options + [goEditing, goColSizing, goThumbTracking];
  sgTable.OnSelectEditor := sgTableSelectEditor;
  sgTable.OnValidateEntry := sgTableValidateEntry;
  sgTable.OnPrepareCanvas := gridPrepareCanvas;
  sgTable.BorderSpacing.Around := 6;
  sgTable.Cells[0,0] := '#';
  sgTable.Cells[1,0] := 'Sutun';
  sgTable.Cells[2,0] := 'Tip';
  sgTable.Cells[3,0] := 'PK';
  sgTable.Cells[4,0] := 'NN';
  sgTable.Cells[5,0] := 'UQ';
  sgTable.Cells[6,0] := 'Varsayilan';

  // Yapi grid hucre editoru: Tip sutunu combobox, NN sutunu E/bos secimi
  cbEdit := TComboBox.Create(Self);
  cbEdit.Parent := sgTable;
  cbEdit.Visible := False;
  cbEdit.Style := csDropDownList;

  // --- Veri ---
  tsData := TTabSheet.Create(pcMain);
  tsData.PageControl := pcMain;
  tsData.Caption := 'Veri';
  bar := TabBar(tsData);
  lblTblData := TLabel.Create(Self);
  lblTblData.Parent := bar;
  lblTblData.Align := alLeft;
  lblTblData.Width := 170;
  lblTblData.Caption := '  tablo: -';
  b := BarBtn(bar, '|<<', 44);
  b.OnClick := btnFirstClick;
  b := BarBtn(bar, '<', 44);
  b.OnClick := btnPrevClick;
  b := BarBtn(bar, '>', 44);
  b.OnClick := btnNextClick;
  b := BarBtn(bar, '>>|', 44);
  b.OnClick := btnLastClick;
  BarSep(bar);
  lblPage := TLabel.Create(Self);
  lblPage.Parent := bar;
  lblPage.Align := alLeft;
  lblPage.Width := 200;
  lblPage.Caption := '  -';
  cbPageSize := TComboBox.Create(Self);
  cbPageSize.Parent := bar;
  cbPageSize.Align := alLeft;
  cbPageSize.Width := 70;
  cbPageSize.Style := csDropDownList;
  cbPageSize.Items.Add('50');
  cbPageSize.Items.Add('100');
  cbPageSize.Items.Add('200');
  cbPageSize.Items.Add('500');
  cbPageSize.Items.Add('1000');
  cbPageSize.ItemIndex := 1;
  cbPageSize.OnChange := cbPageSizeChange;
  BarSep(bar);
  b := BarBtn(bar, 'Satir Ekle', 90);
  b.OnClick := btnAddRowClick;
  b := BarBtn(bar, 'Satir Sil', 80);
  b.OnClick := btnDelRowClick;
  b := BarBtn(bar, 'Yenile', 70);
  b.OnClick := btnRefreshDataClick;
  bar := TabBar(tsData);
  with TLabel.Create(Self) do
  begin
    Parent := bar;
    Align := alLeft;
    Width := 52;
    Caption := '  Filtre:';
  end;
  edFilter := TEdit.Create(Self);
  edFilter.Parent := bar;
  edFilter.Align := alLeft;
  edFilter.Width := 240;
  edFilter.Text := '';
  b := BarBtn(bar, 'Uygula', 70);
  b.OnClick := btnFilterGoClick;
  b := BarBtn(bar, 'Temizle', 70);
  b.OnClick := btnFilterClearClick;
  BarSep(bar);
  b := BarBtn(bar, 'CSV Kaydet', 90);
  b.OnClick := btnDataSaveCSVClick;
  BarSep(bar);
  with TLabel.Create(Self) do
  begin
    Parent := bar;
    Align := alLeft;
    Width := 46;
    Caption := '  Sirala:';
  end;
  cbSortCol := TComboBox.Create(Self);
  cbSortCol.Parent := bar;
  cbSortCol.Align := alLeft;
  cbSortCol.Width := 130;
  cbSortCol.Style := csDropDownList;
  cbSortDir := TComboBox.Create(Self);
  cbSortDir.Parent := bar;
  cbSortDir.Align := alLeft;
  cbSortDir.Width := 90;
  cbSortDir.Style := csDropDownList;
  cbSortDir.Items.Add('Artan');
  cbSortDir.Items.Add('Azalan');
  cbSortDir.ItemIndex := 0;
  sgData := TStringGrid.Create(Self);
  sgData.Parent := tsData;
  sgData.Align := alClient;
  sgData.FixedRows := 1;
  sgData.DefaultRowHeight := 26;
  sgData.Options := [goEditing, goThumbTracking, goFixedVertLine, goFixedHorzLine,
    goVertLine, goHorzLine, goColSizing];
  sgData.OnSetEditText := sgDataSetEditText;
  sgData.OnPrepareCanvas := gridPrepareCanvas;
  sgData.OnHeaderClick := sgDataHeaderClick;
  sgData.BorderSpacing.Around := 6;

  // --- Indeksler ---
  tsIdx := TTabSheet.Create(pcMain);
  tsIdx.PageControl := pcMain;
  tsIdx.Caption := 'Indeksler';
  bar := TabBar(tsIdx);
  edIdxName := TEdit.Create(Self);
  edIdxName.Parent := bar;
  edIdxName.Align := alLeft;
  edIdxName.Width := 150;
  edIdxName.Text := 'ix_';
  cbIdxCol := TComboBox.Create(Self);
  cbIdxCol.Parent := bar;
  cbIdxCol.Align := alLeft;
  cbIdxCol.Width := 190;
  // 2026-10-04: csDropDownList kaldirildi -> metin serbest. Yonetici
  // birden fazla sutun yazabilir: "a,b,c". Motor zaten
  // CREATE INDEX ix ON t(a,b,c) destekliyor; yonetim araczi ONCEDEN tek
  // sutunluydu ve cok kolonlu/UNIQUE indeks kurulamiyordu.
  cbIdxCol.Style := csDropDown;
  cbIdxCol.Items.Clear;
  cbIdxCol.Items.Add('virgulle ayir: a,b,c');
  cbIdxCol.Text := '';
  cbIdxUnique := TCheckBox.Create(Self);
  cbIdxUnique.Parent := bar;
  cbIdxUnique.Align := alLeft;
  cbIdxUnique.Caption := 'UNIQUE';
  cbIdxUnique.Width := 80;
  b := BarBtn(bar, 'Index Ekle', 100);
  b.OnClick := btnIdxAddClick;
  b := BarBtn(bar, 'Index Sil', 90);
  b.OnClick := btnIdxDropClick;
  sgIdx := TStringGrid.Create(Self);
  sgIdx.Parent := tsIdx;
  sgIdx.Align := alClient;
  sgIdx.FixedRows := 1;
  sgIdx.ColCount := 3;
  sgIdx.RowCount := 2;
  sgIdx.DefaultRowHeight := 26;
  sgIdx.Options := sgIdx.Options + [goColSizing, goThumbTracking];
  sgIdx.Cells[0,0] := 'Index';
  sgIdx.Cells[1,0] := 'Sutun';
  sgIdx.Cells[2,0] := 'Tur';
  sgIdx.OnPrepareCanvas := gridPrepareCanvas;
  sgIdx.BorderSpacing.Around := 6;

  // --- Iliskiler (FK) ---
  tsRel := TTabSheet.Create(pcMain);
  tsRel.PageControl := pcMain;
  tsRel.Caption := 'Iliskiler';
  with TLabel.Create(Self) do
  begin
    Parent := tsRel;
    Align := alTop;
    Height := 22;
    Caption := '  Bu tablonun basvurdugu tablolar (disa giden FK)';
  end;
  sgFKOut := TStringGrid.Create(Self);
  sgFKOut.Parent := tsRel;
  sgFKOut.Align := alTop;
  sgFKOut.Height := 200;
  sgFKOut.FixedRows := 1;
  sgFKOut.ColCount := 5;
  sgFKOut.RowCount := 2;
  sgFKOut.DefaultRowHeight := 26;
  sgFKOut.Options := sgFKOut.Options + [goColSizing, goThumbTracking];
  sgFKOut.Cells[0,0] := 'Sutun';
  sgFKOut.Cells[1,0] := 'Hedef Tablo';
  sgFKOut.Cells[2,0] := 'Hedef Sutun';
  sgFKOut.Cells[3,0] := 'OnDelete';
  sgFKOut.Cells[4,0] := 'OnUpdate';
  sgFKOut.OnPrepareCanvas := gridPrepareCanvas;
  with TLabel.Create(Self) do
  begin
    Parent := tsRel;
    Align := alTop;
    Height := 22;
    Caption := '  Bu tabloya basvuran tablolar (gelen FK)';
  end;
  sgFKIn := TStringGrid.Create(Self);
  sgFKIn.Parent := tsRel;
  sgFKIn.Align := alClient;
  sgFKIn.FixedRows := 1;
  sgFKIn.ColCount := 5;
  sgFKIn.RowCount := 2;
  sgFKIn.DefaultRowHeight := 26;
  sgFKIn.Options := sgFKIn.Options + [goColSizing, goThumbTracking];
  sgFKIn.Cells[0,0] := 'Tablo';
  sgFKIn.Cells[1,0] := 'Sutun';
  sgFKIn.Cells[2,0] := 'Hedef Sutun';
  sgFKIn.Cells[3,0] := 'OnDelete';
  sgFKIn.Cells[4,0] := 'OnUpdate';
  sgFKIn.OnPrepareCanvas := gridPrepareCanvas;

  // --- Sema ---
  tsSchema := TTabSheet.Create(pcMain);
  tsSchema.PageControl := pcMain;
  tsSchema.Caption := 'Sema';
  TabBtn(tsSchema, 'Yenile').OnClick := btnRefreshDataClick;
  // 2026-10-04 (M9): sema SORGULARI artik SQL ile de alinabiliyor; bu
  // dugmeler sorguyu calistirip sonucu SQL sekmesinde gosterir.
  TabBtn(tsSchema, 'DESCRIBE').OnClick := btnDescribeClick;
  TabBtn(tsSchema, 'Indeksler').OnClick := btnShowIndexesClick;
  TabBtn(tsSchema, 'CREATE SQL').OnClick := btnShowCreateClick;
  TabBtn(tsSchema, 'Tum Sema').OnClick := btnSchemaSqlClick;
  meSchema := TMemo.Create(Self);
  meSchema.Parent := tsSchema;
  meSchema.Align := alClient;
  meSchema.ReadOnly := True;
  meSchema.ScrollBars := ssBoth;
  meSchema.Font.Name := 'Consolas';
  meSchema.Font.Size := 10;
  meSchema.BorderSpacing.Around := 6;

  // --- SQL ---
  tsSQL := TTabSheet.Create(pcMain);
  tsSQL.PageControl := pcMain;
  tsSQL.Caption := 'SQL';
  meSQL := TMemo.Create(Self);
  meSQL.Parent := tsSQL;
  meSQL.Align := alTop;
  meSQL.Height := 170;
  meSQL.ScrollBars := ssBoth;
  meSQL.Font.Name := 'Consolas';
  meSQL.Font.Size := 10;
  meSQL.Text := 'SHOW TABLES;';
  meSQL.BorderSpacing.Around := 6;
  bar := TabBar(tsSQL);
  b := BarBtn(bar, 'Calistir', 100);
  b.ImageIndex := 7;
  b.Hint := 'Sorguyu calistir (F5)';
  b.OnClick := btnExecSQLClick;
  b := BarBtn(bar, 'Temizle', 80);
  b.OnClick := btnSqlClearClick;
  BarSep(bar);
  b := BarBtn(bar, 'Dosya Calistir', 120);
  b.OnClick := btnSqlFileRunClick;
  b := BarBtn(bar, 'SQL Kaydet', 100);
  b.OnClick := btnSqlSaveClick;
  BarSep(bar);
  cbSqlTemplates := TComboBox.Create(Self);
  cbSqlTemplates.Parent := bar;
  cbSqlTemplates.Align := alLeft;
  cbSqlTemplates.Width := 160;
  cbSqlTemplates.Style := csDropDownList;
  cbSqlTemplates.Items.Add('-- SQL Sablonlari --');
  cbSqlTemplates.Items.Add('SELECT * (Limit 50)');
  cbSqlTemplates.Items.Add('SELECT COUNT(*)');
  cbSqlTemplates.Items.Add('INSERT INTO ...');
  cbSqlTemplates.Items.Add('UPDATE ...');
  cbSqlTemplates.Items.Add('DELETE FROM ...');
  cbSqlTemplates.Items.Add('CREATE TABLE ...');
  cbSqlTemplates.Items.Add('ALTER TABLE ADD ...');
  cbSqlTemplates.Items.Add('SHOW TABLES');
  cbSqlTemplates.Items.Add('LIST DATABASES');
  cbSqlTemplates.Items.Add('VACUUM');
  cbSqlTemplates.Items.Add('VERIFY');
  cbSqlTemplates.ItemIndex := 0;
  cbSqlTemplates.OnChange := cbSqlTemplatesChange;
  BarSep(bar);
  cbHist := TComboBox.Create(Self);
  cbHist.Parent := bar;
  cbHist.Align := alClient;
  cbHist.Text := 'Gecmis sorgular...';
  cbHist.OnChange := cbHistChange;
  bar := TabBar(tsSQL);
  with TLabel.Create(Self) do
  begin
    Parent := bar;
    Align := alLeft;
    Width := 60;
    Caption := '  Kayitli:';
  end;
  cbSaved := TComboBox.Create(Self);
  cbSaved.Parent := bar;
  cbSaved.Align := alLeft;
  cbSaved.Width := 170;
  cbSaved.Text := 'sec...';
  cbSaved.OnChange := cbSavedChange;
  b := BarBtn(bar, 'Kaydet', 65);
  b.OnClick := btnSaveQryClick;
  b := BarBtn(bar, 'Sil', 50);
  b.OnClick := btnDelQryClick;
  BarSep(bar);
  b := BarBtn(bar, 'Kopyala (TSV)', 105);
  b.OnClick := btnSqlCopyTSVClick;
  b := BarBtn(bar, 'CSV Kaydet', 90);
  b.OnClick := btnSqlSaveCSVClick;
  b := BarBtn(bar, 'JSON Kaydet', 90);
  b.OnClick := btnSqlSaveJSONClick;
  BarSep(bar);
  b := BarBtn(bar, 'BEGIN', 75);
  b.OnClick := btnTxBeginClick;
  b := BarBtn(bar, 'COMMIT', 75);
  b.OnClick := btnTxCommitClick;
  b := BarBtn(bar, 'ROLLBACK', 85);
  b.OnClick := btnTxRollbackClick;
  lblTx := TLabel.Create(Self);
  lblTx.Parent := bar;
  lblTx.Align := alLeft;
  lblTx.Width := 100;
  lblTx.Caption := '  TX: kapali';
  lblResult := TLabel.Create(Self);
  lblResult.Parent := tsSQL;
  lblResult.Align := alTop;
  lblResult.Height := 24;
  lblResult.Caption := '  Hazir';
  sgSQLRes := TStringGrid.Create(Self);
  sgSQLRes.Parent := tsSQL;
  sgSQLRes.Align := alClient;
  sgSQLRes.FixedRows := 1;
  sgSQLRes.DefaultRowHeight := 26;
  sgSQLRes.Font.Name := 'Consolas';
  sgSQLRes.Font.Size := 10;
  sgSQLRes.Options := sgSQLRes.Options + [goColSizing, goThumbTracking];
  sgSQLRes.OnPrepareCanvas := gridPrepareCanvas;
  sgSQLRes.BorderSpacing.Around := 6;

  pmRes := TPopupMenu.Create(Self);
  mi := TMenuItem.Create(pmRes);
  mi.Caption := 'Tumunu Kopyala (TSV)';
  mi.OnClick := btnSqlCopyTSVClick;
  pmRes.Items.Add(mi);
  mi := TMenuItem.Create(pmRes);
  mi.Caption := 'CSV Olarak Kaydet...';
  mi.OnClick := btnSqlSaveCSVClick;
  pmRes.Items.Add(mi);
  mi := TMenuItem.Create(pmRes);
  mi.Caption := 'JSON Olarak Kaydet...';
  mi.OnClick := btnSqlSaveJSONClick;
  pmRes.Items.Add(mi);
  sgSQLRes.PopupMenu := pmRes;

  // --- Bul (tum tablolarda arama) ---
  tsFind := TTabSheet.Create(pcMain);
  tsFind.PageControl := pcMain;
  tsFind.Caption := 'Bul';
  bar := TabBar(tsFind);
  edFind := TEdit.Create(Self);
  edFind.Parent := bar;
  edFind.Align := alLeft;
  edFind.Width := 300;
  edFind.OnKeyPress := edFindKeyPress;
  b := BarBtn(bar, 'Bul', 80);
  b.ImageIndex := 7;
  b.OnClick := btnFindClick;
  sgFind := TStringGrid.Create(Self);
  sgFind.Parent := tsFind;
  sgFind.Align := alClient;
  sgFind.FixedRows := 1;
  sgFind.DefaultRowHeight := 26;
  sgFind.Options := sgFind.Options + [goColSizing, goThumbTracking];
  sgFind.ColCount := 4;
  sgFind.RowCount := 2;
  sgFind.Cells[0,0] := 'Tablo';
  sgFind.Cells[1,0] := 'PK';
  sgFind.Cells[2,0] := 'Sutun';
  sgFind.Cells[3,0] := 'Deger';
  sgFind.OnPrepareCanvas := gridPrepareCanvas;
  sgFind.OnDblClick := sgFindDblClick;
  sgFind.BorderSpacing.Around := 6;

  // --- Araclar ---
  tsTools := TTabSheet.Create(pcMain);
  tsTools.PageControl := pcMain;
  tsTools.Caption := 'Araclar';
  bar := TabBar(tsTools);
  b := BarBtn(bar, 'Yedek Al', 90);
  b.OnClick := btnBackupClick;
  b := BarBtn(bar, 'Dogrula', 80);
  b.OnClick := btnVerifyClick;
  BarSep(bar);
  b := BarBtn(bar, 'VACUUM', 80);
  b.OnClick := btnCompactClick;
  b := BarBtn(bar, 'REINDEX', 90);
  b.OnClick := btnReindexClick;
  bar := TabBar(tsTools);
  b := BarBtn(bar, 'Export JSON', 110);
  b.OnClick := btnExportClick;
  b := BarBtn(bar, 'Import JSON', 110);
  b.OnClick := btnImportClick;
  BarSep(bar);
  b := BarBtn(bar, 'CSV Disari', 100);
  b.OnClick := btnExportCSVClick;
  b := BarBtn(bar, 'CSV Iceri', 90);
  b.OnClick := btnImportCSVClick;
  BarSep(bar);
  b := BarBtn(bar, 'SQL Dokum', 100);
  b.OnClick := btnDumpSQLClick;
  // 2026-10-04 (M9): WAL araclari. Bekleyen gunluk varsa dugmeler
  // vurgulanir; kullanici acmadan WAL'in biriktigini gorur.
  BarSep(bar);
  bWalStatus := BarBtn(bar, 'WAL Durum', 100);
  bWalStatus.OnClick := btnWalStatusClick;
  bWalReplay := BarBtn(bar, 'WAL Replay', 100);
  bWalReplay.OnClick := btnWalReplayClick;
  bWalCkpt := BarBtn(bar, 'WAL Checkpoint', 120);
  bWalCkpt.OnClick := btnWalCheckpointClick;
  // 2026-10-04 (M10): otomatik WAL anahtari (varsayilan KAPALI).
  // LCL'de TToolButton icin toggle gorunumu tbsCheck'tir (Down durumu).
  bWalAuto := BarBtn(bar, 'Otomatik WAL', 110);
  bWalAuto.Style := tbsCheck;
  bWalAuto.OnClick := btnWalAutoClick;
  meLog := TMemo.Create(Self);
  meLog.Parent := tsTools;
  meLog.Align := alClient;
  meLog.ReadOnly := True;
  meLog.ScrollBars := ssBoth;
  meLog.BorderSpacing.Around := 6;

  pm := TPopupMenu.Create(Self);
  mi := TMenuItem.Create(pm);
  mi.Caption := 'Ac';
  mi.OnClick := tvListDblClick;
  pm.Items.Add(mi);
  mi := TMenuItem.Create(pm);
  mi.Caption := 'Yeni Veritabani';
  mi.OnClick := btnNewDBClick;
  pm.Items.Add(mi);
  mi := TMenuItem.Create(pm);
  mi.Caption := 'Veritabani Sil';
  mi.OnClick := btnDropDBClick;
  pm.Items.Add(mi);
  mi := TMenuItem.Create(pm);
  mi.Caption := '-';
  pm.Items.Add(mi);
  mi := TMenuItem.Create(pm);
  mi.Caption := 'Yenile';
  mi.OnClick := btnRefreshAllClick;
  pm.Items.Add(mi);
  tvList.PopupMenu := pm;

  pm := TPopupMenu.Create(Self);
  mi := TMenuItem.Create(pm);
  mi.Caption := 'Satir Ekle';
  mi.OnClick := btnAddRowClick;
  pm.Items.Add(mi);
  mi := TMenuItem.Create(pm);
  mi.Caption := 'Satir Sil';
  mi.OnClick := btnDelRowClick;
  pm.Items.Add(mi);
  mi := TMenuItem.Create(pm);
  mi.Caption := '-';
  pm.Items.Add(mi);
  mi := TMenuItem.Create(pm);
  mi.Caption := 'Yenile';
  mi.OnClick := btnRefreshDataClick;
  pm.Items.Add(mi);
  mi := TMenuItem.Create(pm);
  mi.Caption := 'CSV Disari Aktar';
  mi.OnClick := btnExportCSVClick;
  pm.Items.Add(mi);
  sgData.PopupMenu := pm;

  pm := TPopupMenu.Create(Self);
  mi := TMenuItem.Create(pm);
  mi.Caption := 'Sutun Ekle';
  mi.OnClick := btnAddColClick;
  pm.Items.Add(mi);
  mi := TMenuItem.Create(pm);
  mi.Caption := 'Sutun Sil';
  mi.OnClick := btnDropColClick;
  pm.Items.Add(mi);
  mi := TMenuItem.Create(pm);
  mi.Caption := '-';
  pm.Items.Add(mi);
  mi := TMenuItem.Create(pm);
  mi.Caption := 'Tablo Kopyala';
  mi.OnClick := btnCopyTableClick;
  pm.Items.Add(mi);
  mi := TMenuItem.Create(pm);
  mi.Caption := 'Tablo Sil';
  mi.OnClick := btnDropTableClick;
  pm.Items.Add(mi);
  sgTable.PopupMenu := pm;

  pcMain.ActivePage := tsDB;
end;

procedure TfrmMain.BuildMenu;

  function Mi(AParent: TMenuItem; const C: string): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := C;
    AParent.Add(Result);
  end;

var
  mm: TMainMenu;
  m: TMenuItem;
begin
  mm := TMainMenu.Create(Self);
  Self.Menu := mm;
  m := Mi(mm.Items, 'Dosya');
  Mi(m, 'Ac...').OnClick := btnOpenDBClick;
  Mi(m, 'Yedek Al').OnClick := btnBackupClick;
  Mi(m, '-');
  Mi(m, 'Cikis').OnClick := mnuExitClick;
  m := Mi(mm.Items, 'Veritabani');
  Mi(m, 'Yeni Veritabani').OnClick := btnNewDBClick;
  Mi(m, 'Veritabani Sil').OnClick := btnDropDBClick;
  Mi(m, 'Yenile').OnClick := btnRefreshAllClick;
  m := Mi(mm.Items, 'Tablo');
  Mi(m, 'Yeni Tablo').OnClick := btnNewTableClick;
  Mi(m, 'Tablo Sil').OnClick := btnDropTableClick;
  m := Mi(mm.Items, 'Araclar');
  Mi(m, 'Dogrula').OnClick := btnVerifyClick;
  Mi(m, 'VACUUM').OnClick := btnCompactClick;
  Mi(m, 'Gerektiginde Sikistir').OnClick := btnAutoCompactClick;
  Mi(m, 'REINDEX').OnClick := btnReindexClick;
  Mi(m, 'Export JSON').OnClick := btnExportClick;
  Mi(m, 'Import JSON').OnClick := btnImportClick;
  Mi(m, '-');
  Mi(m, 'WAL Durum...').OnClick := btnWalStatusClick;
  Mi(m, 'WAL Replay (Uygula)').OnClick := btnWalReplayClick;
  Mi(m, 'WAL Checkpoint').OnClick := btnWalCheckpointClick;
  Mi(m, 'Otomatik WAL (write-ahead)').OnClick := btnWalAutoClick;
  m := Mi(mm.Items, 'Sema');
  Mi(m, 'Tablo Aciklamasi (DESCRIBE)').OnClick := btnDescribeClick;
  Mi(m, 'Indeksleri Goster (SHOW INDEXES)').OnClick := btnShowIndexesClick;
  Mi(m, 'Olusturma SQL (SHOW CREATE TABLE)').OnClick := btnShowCreateClick;
  Mi(m, '-');
  Mi(m, 'Tum Tablolarin Semasi').OnClick := btnSchemaSqlClick;
  m := Mi(mm.Items, 'Gorunum');
  miTheme := Mi(m, 'Koyu Tema');
  miTheme.OnClick := mnuThemeClick;
  m := Mi(mm.Items, 'Yardim');
  Mi(m, 'Hakkinda').OnClick := mnuAboutClick;
end;

{ ---------------- veritabani / agac ---------------- }

procedure TfrmMain.EnsureOpen;
begin
  if Assigned(FKv) then Exit;
  OpenDB(FCurrentDBDir + '\veritabani.odb');
end;

function TfrmMain.DBInfoText: string;
// 2026-10-04 (M8): DB bilgi paneli metni tek yerde uretilir; VACUUM /
// otomatik sikistirma sonrasi da tazelenir.
// 2026-10-04 (M9): bekleyen WAL varsa KIRMIZI vurguyla gosterilir; WAL
// varken dosya "saglam" gorunse de kayitlar henuz uygulanmamistir.
var
  walTxt: string;
begin
  if (not Assigned(FKv)) or (FDBPath = '') then
    Exit(L('Veritabani acik degil', 'No database open'));
  walTxt := '';
  if FKv.HasWAL then
    walTxt := sLineBreak + L('!! WAL BEKLIYOR: ', '!! WAL PENDING: ') +
      DbSizeStr(FKv.WalPath) +
      L(' (Araclar > WAL Replay)', ' (Tools > WAL Replay)');
  Result := L('Dosya: ', 'File: ') + FDBPath + sLineBreak +
    L('Boyut: ', 'Size: ') + DbSizeStr(FDBPath) + sLineBreak +
    L('Kayit (canli): ', 'Records (live): ') + IntToStr(FTb.DataKeyCount) + sLineBreak +
    L('Olu bayt: ', 'Dead bytes: ') + IntToStr(FKv.DeadBytes) + walTxt;
end;

procedure TfrmMain.OpenDB(const FilePath: string);
var
  rep: string;
  ok: Boolean;
  n: Integer;
begin
  CloseDB;
  FKv := TVDb.Create;
  FKv.SyncWrite := False;
  FKv.Open(FilePath);
  FTb := TVTableDb.Create(FKv);
  FTb.Open(ExtractFileDir(FilePath));
  FSq := TVSql.Create(FTb);
  FSq.AutoTransaction := True;
  FDBPath := FKv.FilePath;
  FCurrentDBDir := ExtractFileDir(FDBPath);
  FPage := 0;
  n := FTb.DataKeyCount;
  lblDBInfo.Caption := DBInfoText;
  SetStatus('Acik: ' + FDBPath);
  lblBannerSub.Caption := FDBPath;
  SetHealth('');
  ok := FKv.Verify(rep);
  if ok then
    SetHealth('SAGLAM')
  else
    SetHealth('SORUN: ' + rep);
  // 2026-10-04 (M6): DAYANIKLILIK ALARMLARI. Motor bu iki durumu
  // yalnizca property olarak tutuyordu; yonetim hic bakmiyordu.
  //  - RestoredFromBak: dosya .bak'tan GERI YUKLENDI (yarim kalmis
  //    compact/replace). Kritik: eski surumdeki veri olabilir.
  //  - DirSyncFailed: dizin girdisi fsync edilemedi; yeni dosya/rename
  //    kalici OLMAYABILIR (F2-2).
  if FKv.RestoredFromBak then
  begin
    SetHealth('DIKKAT: .bak geri yuklendi');
    Log('UYARI: veritabani .bak dosyasindan geri yuklendi (' + FDBPath + ')');
    Log('      eski surumdeki veri olabilir; yedek kontrol edin.');
  end;
  if FKv.DirSyncFailed then
  begin
    SetHealth('DIKKAT: dizin yazimi kalici degil');
    Log('UYARI: dizin fsync edilemedi (DirSyncFailed). Yeni dosya/rename');
    Log('      crash sonrasi kaybolabilir. Dosya sistemi izinlerini kontrol edin.');
  end;
  // 2026-10-04 (M9): acilista bekleyen WAL var mi diye bak.
  RefreshWalUI;
  Log('Acildi: ' + FDBPath);
  if chkAutoBak.Checked then
  begin
    try
      FKv.BackupTo(FDBPath + '.onceki');
      Log('Otomatik yedek: ' + FDBPath + '.onceki');
    except
      on E: Exception do
        Log('Otomatik yedek hatasi: ' + E.Message);
    end;
  end;
  RefreshTree;
  RefreshDashboard;
  UpdateTx;
  SaveSettings;
  FCurrentTable := '';
end;

procedure TfrmMain.CloseDB;
begin
  if Assigned(FSq) then FreeAndNil(FSq);
  if Assigned(FTb) then FreeAndNil(FTb);
  if Assigned(FKv) then FreeAndNil(FKv);
  FDBPath := '';
  FCurrentTable := '';
  SetLength(FDataPks, 0);
  SetLength(FDataRows, 0);
  lblBannerSub.Caption := 'kapali - bir veritabani acin';
  SetHealth('');
  SetStatus('Kapandi');
end;

procedure TfrmMain.RefreshTree;
var
  sr: TSearchRec;
  root, dbNode, tNode: TTreeNode;
  tables: TStrArray;
  i: Integer;
  p: string;
begin
  tvList.Items.BeginUpdate;
  try
    tvList.Items.Clear;
    root := tvList.Items.Add(nil, L('Veritabanlari', 'Databases'));
    if FindFirst(FCurrentDBDir + '\*.odb', faAnyFile, sr) = 0 then
    begin
      repeat
        if (sr.Attr and faDirectory) = 0 then
        begin
          p := FCurrentDBDir + '\' + sr.Name;
          dbNode := tvList.Items.AddChild(root, ChangeFileExt(sr.Name, ''));
          dbNode.Data := Pointer(StrNew(PChar(p)));
          dbNode.ImageIndex := 8;
          dbNode.SelectedIndex := 8;
          if Assigned(FTb) and SameText(p, FDBPath) then
          begin
            tables := FTb.TableNames;
            for i := 0 to High(tables) do
            begin
              tNode := tvList.Items.AddChild(dbNode, tables[i]);
              tNode.Data := nil;
              tNode.ImageIndex := 9;
              tNode.SelectedIndex := 9;
            end;
            dbNode.Expand(False);
          end;
        end;
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    root.Expand(False);
  finally
    tvList.Items.EndUpdate;
  end;
end;

function TfrmMain.SelectedDbPath(Node: TTreeNode): string;
begin
  Result := '';
  if (Node = nil) or (Node.Level <> 1) or (Node.Data = nil) then Exit;
  Result := string(PChar(Node.Data));
end;

{ ---------------- tablo ---------------- }

procedure TfrmMain.SelectTable(const Tbl: string);
var
  td: TTableDef;
  i: Integer;
begin
  if not Assigned(FTb) then Exit;
  if not FTb.TableExists(Tbl) then Exit;
  
  // Önce eski verileri tamamen temizle
  FDataPks := nil;
  FDataRows := nil;
  SetLength(FDataPks, 0);
  SetLength(FDataRows, 0);
  
  FCurrentTable := Tbl;
  FPage := 0;
  FWhere := '';
  FSortCol := '';
  FSortDesc := False;
  edFilter.Text := '';
  edTableName.Text := Tbl;
  lblTblData.Caption := '  tablo: ' + Tbl;
  td := FTb.GetTable(Tbl);
  cbSortCol.Items.Clear;
  cbSortCol.Items.Add('(yok)');
  for i := 0 to High(td.Cols) do
    cbSortCol.Items.Add(td.Cols[i].Name);
  cbSortCol.ItemIndex := 0;
  cbSortDir.ItemIndex := 0;
  ShowTableStructure;
  ReloadData;
  RefreshIndexes;
  RefreshSchema;
  RefreshRelations;
end;

procedure TfrmMain.ShowTableStructure;
var
  td: TTableDef;
  i: Integer;
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  if not FTb.TableExists(FCurrentTable) then Exit;
  td := FTb.GetTable(FCurrentTable);
  sgTable.RowCount := Length(td.Cols) + 1;
  sgTable.ColCount := 7;
  sgTable.Cells[0,0] := '#';
  sgTable.Cells[1,0] := 'Sutun';
  sgTable.Cells[2,0] := 'Tip';
  sgTable.Cells[3,0] := 'PK';
  sgTable.Cells[4,0] := 'NN';
  sgTable.Cells[5,0] := 'UQ';
  sgTable.Cells[6,0] := 'Varsayilan';
  for i := 0 to High(td.Cols) do
  begin
    sgTable.Cells[0, i+1] := IntToStr(i + 1);
    sgTable.Cells[1, i+1] := td.Cols[i].Name;
    sgTable.Cells[2, i+1] := VDbCtypeName(td.Cols[i].Ctype);
    if i = td.PkIndex then
      sgTable.Cells[3, i+1] := 'E'
    else
      sgTable.Cells[3, i+1] := '';
    if td.Cols[i].NotNull then
      sgTable.Cells[4, i+1] := 'E'
    else
      sgTable.Cells[4, i+1] := '';
    if td.Cols[i].Unique then
      sgTable.Cells[5, i+1] := 'E'
    else
      sgTable.Cells[5, i+1] := '';
    sgTable.Cells[6, i+1] := td.Cols[i].Def;
  end;
end;

{ ---------------- veri ---------------- }

function TfrmMain.SqlVal(const V: string): string;
var
  t: string;
  f: Double;
  fs: TFormatSettings;
begin
  t := Trim(V);
  if t = '' then Exit('NULL');
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  if TryStrToFloat(t, f, fs) then Exit(t);
  Result := '''' + StringReplace(t, '''', '''''', [rfReplaceAll]) + '''';
end;

procedure TfrmMain.ReloadData;
var
  n, pages: Integer;
  res: TSqlResult;
  td: TTableDef;
  pkCol, q: string;
  qi, pkIdx: Integer;
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  if (FWhere <> '') or (FSortCol <> '') then
  begin
    td := FTb.GetTable(FCurrentTable);
    if (td.PkIndex >= 0) and (td.PkIndex < Length(td.Cols)) then
      pkCol := td.Cols[td.PkIndex].Name
    else
      pkCol := td.Cols[0].Name;
    q := 'SELECT * FROM ' + FCurrentTable;
    if FWhere <> '' then
      q := q + ' WHERE ' + FWhere;
    if FSortCol <> '' then
    begin
      q := q + ' ORDER BY ' + FSortCol;
      if FSortDesc then
        q := q + ' DESC';
    end;
    try
      res := FSq.Exec(q);
    except
      on E: Exception do
      begin
        ShowMessage('Filtre hatasi:' + sLineBreak + E.Message);
        FWhere := '';
        FSortCol := '';
        edFilter.Text := '';
        ReloadData;
        Exit;
      end;
    end;
    pkIdx := -1;
    for qi := 0 to High(res.Fields) do
      if SameText(res.Fields[qi], pkCol) then
        pkIdx := qi;
    SetLength(FDataPks, Length(res.Rows));
    SetLength(FDataRows, Length(res.Rows));
    for qi := 0 to High(res.Rows) do
    begin
      if pkIdx >= 0 then
        FDataPks[qi] := res.Rows[qi][pkIdx]
      else
        FDataPks[qi] := IntToStr(qi);
      FDataRows[qi] := Copy(res.Rows[qi], 0, Length(res.Rows[qi]));
    end;
  end
  else
    FTb.ScanRows(FCurrentTable, FDataPks, FDataRows);
  n := Length(FDataPks);
  pages := (n + FPageSize - 1) div FPageSize;
  if pages < 1 then pages := 1;
  if FPage >= pages then FPage := pages - 1;
  if FPage < 0 then FPage := 0;
  RenderPage;
end;

procedure TfrmMain.RenderPage;
var
  td: TTableDef;
  i, j, r0, r1, n: Integer;
begin
  n := Length(FDataPks);
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  if not FTb.TableExists(FCurrentTable) then Exit;
  td := FTb.GetTable(FCurrentTable);
  r0 := FPage * FPageSize;
  r1 := r0 + FPageSize - 1;
  if r1 >= n then r1 := n - 1;
  
  // Önce grid'i tamamen temizle (eski tablo verilerini silmek icin)
  sgData.Clean;
  
  sgData.ColCount := Length(td.Cols) + 1;
  if r1 >= r0 then
    sgData.RowCount := (r1 - r0 + 1) + 1
  else
    sgData.RowCount := 2;
  sgData.Cells[0,0] := 'PK';
  for j := 0 to High(td.Cols) do
  begin
    if SameText(td.Cols[j].Name, FSortCol) then
    begin
      if FSortDesc then
        sgData.Cells[j+1, 0] := td.Cols[j].Name + '  ▼'
      else
        sgData.Cells[j+1, 0] := td.Cols[j].Name + '  ▲';
    end
    else
      sgData.Cells[j+1, 0] := td.Cols[j].Name;
  end;
  for i := r0 to r1 do
  begin
    sgData.Cells[0, i - r0 + 1] := FDataPks[i];
    for j := 0 to High(td.Cols) do
      sgData.Cells[j+1, i - r0 + 1] := FDataRows[i][j];
  end;
  if n = 0 then
    lblPage.Caption := '  boş tablo'
  else
    lblPage.Caption := Format('  satır %d-%d / %d (sayfa %d/%d)',
      [r0 + 1, r1 + 1, n, FPage + 1, (n + FPageSize - 1) div FPageSize]);
  sb.Panels[1].Text := FCurrentTable + ': ' + IntToStr(n) + ' satır';
end;

procedure TfrmMain.sgDataSetEditText(Sender: TObject; ACol, ARow: Integer;
  const Value: string);
var
  td: TTableDef;
  idx, ci: Integer;
  setCol, pkVal: string;
  vals: TStrArray;
begin
  if (ARow < 1) or (ACol < 1) then Exit;
  if (not Assigned(FSq)) or (FCurrentTable = '') then Exit;
  idx := FPage * FPageSize + (ARow - 1);
  if (idx < 0) or (idx > High(FDataPks)) then Exit;
  td := FTb.GetTable(FCurrentTable);
  ci := ACol - 1;
  if (ci < 0) or (ci >= Length(td.Cols)) then Exit;
  setCol := td.Cols[ci].Name;
  pkVal := FDataPks[idx];
  // PRIMARY KEY kolonu guncellenemez (motor da reddeder).
  if (td.PkIndex >= 0) and (ci = td.PkIndex) then
  begin
    SetStatus('PRIMARY KEY kolonu guncellenemez: ' + setCol);
    ReloadData;
    Exit;
  end;
  // 2026-10-04: satir PK KOLONU ile degil, satir anahtari (pk) ile
  // adresleniyor. Boylece PK'siz tablolarda da duzenleme calisir
  // (F2-22: bu tablolarda motor sentetik anahtar uretir, FDataPks onu
  // tutar). Onceki kod `WHERE pkCol = pkVal` yaziyordu; PK yoksa
  // sessizce Exit ile hicbir sey olmuyordu.
  // UpdateRowInPlace motorun SQL UPDATE'inin cagirdigi ayni yordamdir:
  // tip normallesme, CHECK, FK, ON UPDATE CASCADE ve indeks bakimi dahil.
  try
    if not FTb.ReadRow(FCurrentTable, pkVal, vals) then
    begin
      SetStatus('Satir bulunamadi (yenileniyor)');
      ReloadData;
      Exit;
    end;
    vals[ci] := Value;
    if FTb.UpdateRowInPlace(FCurrentTable, pkVal, vals) then
      SetStatus('Guncellendi: ' + setCol)
    else
    begin
      SetStatus('Satir bulunamadi');
      ReloadData;
    end;
  except
    on E: Exception do
    begin
      ShowMessage('Guncelleme hatasi: ' + E.Message);
      ReloadData;
    end;
  end;
  ReloadData;
end;

procedure TfrmMain.gridPrepareCanvas(Sender: TObject; ACol, ARow: Integer;
  AState: TGridDrawState);
// 2026-10-04 (M10): Tek paletten boyanan DUZ grid satirlari.
// Onceki hâl iki tema icin AYRI iki bloktu ve iclerine gomulmus
// serbest renkler vardi (koyu secim $00804820 "deep modern blue-slate",
// acik secim $00E6D5C3). Simdi tek blok + UIStyle; "zebra" seritleri
// yalnizca 1 ton farkla, secim ise paletin SelectBG/SelectFG'si.
var
  g: TStringGrid;
  focused: Boolean;
begin
  g := Sender as TStringGrid;
  focused := (gdFocused in AState) and (g.Focused);
  if gdSelected in AState then
  begin
    g.Canvas.Font.Color := UIStyle.SelectFG;
    g.Canvas.Brush.Color := UIStyle.SelectBG;
  end
  else if gdFixed in AState then
  begin
    g.Canvas.Font.Style := [fsBold];
    g.Canvas.Font.Color := UIStyle.Text;
    g.Canvas.Brush.Color := UIStyle.SurfaceAlt;
  end
  else
  begin
    g.Canvas.Font.Style := [];
    g.Canvas.Font.Color := UIStyle.Text;
    if Odd(ARow) then
      g.Canvas.Brush.Color := UIStyle.SurfaceAlt
    else
      g.Canvas.Brush.Color := UIStyle.Surface;
  end;
  // Odak halkasi: LCL'de FocusRect yok; odakta olan hucre paletin
  // Focus rengiyle isaretlenir (duz tasarimda ince vurgu).
  if focused and not (gdSelected in AState) then
    g.Canvas.Brush.Color := UIStyle.Focus;
  g.Canvas.Font.Name := UIStyle.FontUI;
  g.Canvas.Font.Size := UIStyle.FontUIHeight;
end;

procedure TfrmMain.sgTableSelectEditor(Sender: TObject; ACol, ARow: Integer;
  var Editor: TWinControl);
begin
  if ARow < 1 then Exit;
  case ACol of
    2:
      begin
        cbEdit.Items.Clear;
        cbEdit.Items.Add('INTEGER');
        cbEdit.Items.Add('TEXT');
        cbEdit.Items.Add('FLOAT');
        cbEdit.Items.Add('BOOLEAN');
        cbEdit.Items.Add('DATE');
        cbEdit.Items.Add('DATETIME');
        cbEdit.Items.Add('TIME');
        cbEdit.Items.Add('BLOB');
        cbEdit.Text := sgTable.Cells[ACol, ARow];
        Editor := cbEdit;
      end;
    4:
      begin
        cbEdit.Items.Clear;
        cbEdit.Items.Add('');
        cbEdit.Items.Add('E');
        cbEdit.Text := sgTable.Cells[ACol, ARow];
        Editor := cbEdit;
      end;
  end;
end;

procedure TfrmMain.sgTableValidateEntry(Sender: TObject; ACol, ARow: Integer;
  const OldValue: string; var NewValue: string);
var
  colName: string;
begin
  if (ARow < 1) or (FCurrentTable = '') or (not Assigned(FTb)) then Exit;
  if NewValue = OldValue then Exit;
  colName := sgTable.Cells[1, ARow];
  try
    case ACol of
      1:
        begin
          NewValue := LowerCase(Trim(NewValue));
          if NewValue = '' then
          begin
            NewValue := OldValue;
            Exit;
          end;
          FTb.AlterRenameColumn(FCurrentTable, OldValue, NewValue);
          Log('RENAME COLUMN ' + OldValue + ' -> ' + NewValue);
        end;
      2:
        begin
          FTb.AlterColumnType(FCurrentTable, colName, UpperCase(Trim(NewValue)));
          Log('ALTER TYPE ' + colName + ' -> ' + NewValue);
        end;
      4:
        begin
          FTb.AlterSetNotNull(FCurrentTable, colName,
            UpperCase(Trim(NewValue)) = 'E');
          if UpperCase(Trim(NewValue)) = 'E' then
            NewValue := 'E'
          else
            NewValue := '';
          Log('SET NOT NULL ' + colName + ' = ' + NewValue);
        end;
      6:
        begin
          if Trim(NewValue) = '' then
            FTb.AlterDropDefault(FCurrentTable, colName)
          else
            FTb.AlterSetDefault(FCurrentTable, colName, True, Trim(NewValue));
          Log('SET DEFAULT ' + colName);
        end;
    else
      NewValue := OldValue;
      Exit;
    end;
  except
    on E: Exception do
    begin
      ShowMessage('Yapi degisikligi hatasi:' + sLineBreak + E.Message);
      NewValue := OldValue;
    end;
  end;
  ShowTableStructure;
  RefreshSchema;
end;

{ ---------------- indeks / sema ---------------- }

procedure TfrmMain.RefreshIndexes;
var
  td: TTableDef;
  i, j: Integer;
  cnames: string;
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  if not FTb.TableExists(FCurrentTable) then Exit;
  td := FTb.GetTable(FCurrentTable);
  cbIdxCol.Items.Clear;
  for i := 0 to High(td.Cols) do
    cbIdxCol.Items.Add(td.Cols[i].Name);
  if cbIdxCol.Items.Count > 0 then
    cbIdxCol.ItemIndex := 0;
  sgIdx.RowCount := Length(td.Idx) + 1;
  sgIdx.ColCount := 3;
  sgIdx.Cells[0,0] := 'Index';
  sgIdx.Cells[1,0] := 'Sutun';
  sgIdx.Cells[2,0] := 'Tur';
  for i := 0 to High(td.Idx) do
  begin
    sgIdx.Cells[0, i+1] := td.Idx[i].Name;
    // 2026-10-04: cok kolonlu indekslerde TUM sutunlar yazilir (virgulle)
    // ve UNIQUE isareti ayri sutunda gosterilir.
    if Length(td.Idx[i].Cols) > 0 then
    begin
      cnames := '';
      for j := 0 to High(td.Idx[i].Cols) do
      begin
        if cnames <> '' then cnames := cnames + ', ';
        if (td.Idx[i].Cols[j] >= 0) and (td.Idx[i].Cols[j] < Length(td.Cols)) then
          cnames := cnames + td.Cols[td.Idx[i].Cols[j]].Name
        else
          cnames := cnames + '?';
      end;
      sgIdx.Cells[1, i+1] := cnames;
    end
    else if (td.Idx[i].Col >= 0) and (td.Idx[i].Col < Length(td.Cols)) then
      sgIdx.Cells[1, i+1] := td.Cols[td.Idx[i].Col].Name
    else
      sgIdx.Cells[1, i+1] := '?';
    if td.Idx[i].Uniq then sgIdx.Cells[2, i+1] := 'UNIQUE'
    else sgIdx.Cells[2, i+1] := '';
  end;
end;

procedure TfrmMain.RefreshSchema;
var
  td: TTableDef;
  i: Integer;
  s: string;
begin
  meSchema.Lines.Clear;
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  if not FTb.TableExists(FCurrentTable) then Exit;
  td := FTb.GetTable(FCurrentTable);
  s := 'CREATE TABLE ' + td.Name + ' (' + sLineBreak;
  for i := 0 to High(td.Cols) do
  begin
    s := s + '  ' + td.Cols[i].Name + ' ' + VDbCtypeName(td.Cols[i].Ctype);
    if i = td.PkIndex then s := s + ' PRIMARY KEY';
    if td.Cols[i].NotNull then s := s + ' NOT NULL';
    if td.Cols[i].Unique then s := s + ' UNIQUE';
    if td.Cols[i].HasDef then s := s + ' DEFAULT ' + SqlVal(td.Cols[i].Def);
    if (i < High(td.Cols)) or (Length(td.Fks) > 0) then s := s + ',';
    s := s + sLineBreak;
  end;
  for i := 0 to High(td.Fks) do
  begin
    s := s + '  FOREIGN KEY (' + td.Cols[td.Fks[i].Col].Name +
      ') REFERENCES ' + td.Fks[i].RefTable + '(' + td.Fks[i].RefCol + ')' +
      ' ON DELETE ' + td.Fks[i].OnDelete +
      ' ON UPDATE ' + td.Fks[i].OnUpdate;
    if i < High(td.Fks) then s := s + ',';
    s := s + sLineBreak;
  end;
  s := s + ');' + sLineBreak;
  for i := 0 to High(td.Idx) do
    if (td.Idx[i].Col >= 0) and (td.Idx[i].Col < Length(td.Cols)) then
      s := s + 'CREATE INDEX ' + td.Idx[i].Name + ' ON ' + td.Name +
        ' (' + td.Cols[td.Idx[i].Col].Name + ');' + sLineBreak;
  meSchema.Text := s;
end;

{ ---------------- sql ---------------- }

procedure TfrmMain.PushHist(const S: string);
var
  t: string;
begin
  t := Trim(S);
  if t = '' then Exit;
  if (cbHist.Items.Count > 0) and (cbHist.Items[0] = t) then Exit;
  cbHist.Items.Insert(0, t);
  while cbHist.Items.Count > 20 do
    cbHist.Items.Delete(cbHist.Items.Count - 1);
end;

procedure TfrmMain.ExecuteSQL(const SqlText: string);
var
  res: TSqlResult;
  i, j: Integer;
  t0, ms: QWord;
  stmts: TStrArray;
begin
  if not Assigned(FSq) then
  begin
    ShowMessage('Once bir veritabani acin.');
    Exit;
  end;
  try
    t0 := GetTickCount64;
    // 2026-10-04 (M7): Cok cumleli BETIK destegi. Once yalniz
    // FSq.Exec tek cumle calistiriyordu; boylece birden fazla cumle
    // iceren bir betik yazilamiyordu ve BEGIN/COMMIT bloklari
    // yonetici tarafindan kurulamiyordu.
    // ExecAll + AutoTransaction varsayilan acikken: cumlelerin hepsi
    // batch-uyumluysa TEK transaction'da calisir (tek fsync, hata
    // halinde hicbiri uygulanmaz) - SQL.md'de anlatilan semantik.
    stmts := FSq.SplitStatements(SqlText);
    if Length(stmts) = 0 then
    begin
      SetStatus('Calistirilacak cumle yok');
      Exit;
    end;
    if Length(stmts) = 1 then
      res := FSq.Exec(stmts[0])
    else
    begin
      res := FSq.ExecAll(stmts);
      Log('Betik: ' + IntToStr(Length(stmts)) + ' cumle calistirildi');
    end;
    ms := GetTickCount64 - t0;
    PushHist(SqlText);
    UpdateTx;
    if Length(res.Fields) > 0 then
    begin
      sgSQLRes.ColCount := Length(res.Fields);
      if Length(res.Rows) > 0 then
        sgSQLRes.RowCount := Length(res.Rows) + 1
      else
        sgSQLRes.RowCount := 2;
      for i := 0 to High(res.Fields) do
        sgSQLRes.Cells[i, 0] := res.Fields[i];
      for i := 0 to High(res.Rows) do
        for j := 0 to High(res.Rows[i]) do
          sgSQLRes.Cells[j, i+1] := res.Rows[i][j];
    end;
    lblResult.Font.Style := [fsBold];
    lblResult.Font.Color := UIStyle.Ok;
    lblResult.Caption := Format('  ✓ Basarili: %d satir, %d cumle | Sure: %d ms (%s)',
      [res.Affected, res.Stmts, ms, res.Msg]);
    SetStatus('SQL calisti: ' + IntToStr(res.Affected) + ' satir');
    Log('SQL: ' + Copy(Trim(SqlText), 1, 120));
    if res.LastTable <> '' then
    begin
      RefreshTree;
      if FTb.TableExists(res.LastTable) then
        SelectTable(res.LastTable)
      else if FCurrentTable <> '' then
        ReloadData;
    end;
  except
    on E: Exception do
    begin
      lblResult.Font.Style := [fsBold];
      lblResult.Font.Color := UIStyle.Danger;
      lblResult.Caption := '  ✗ Hata: ' + E.Message;
      SetStatus('SQL hatasi: ' + E.Message);
    end;
  end;
end;

{ ---------------- yardimci ---------------- }

procedure TfrmMain.SetStatus(const Msg: string);
begin
  sb.Panels[0].Text := Msg;
end;

procedure TfrmMain.SetHealth(const Msg: string);
// 2026-10-04 (M10): durum rengi paletten; "DIKKAT" (uyari) ayrica
// ayirt edilir. Onceki hâlde uyari mesaji "SORUN" etiketiyle
// gosteriliyordu, yani uyari ile gercek hata karisiyordu.
begin
  sb.Panels[2].Text := Msg;
  FHealthTxt := Msg;
  if Msg = '' then
  begin
    shpHealth.Brush.Color := clGray;
    lblHealth.Caption := '';
  end
  else if Pos('SAGLAM', Msg) = 1 then
  begin
    shpHealth.Brush.Color := UIStyle.Ok;
    lblHealth.Caption := 'SAGLAM';
  end
  else if Pos('DIKKAT', Msg) = 1 then
  begin
    shpHealth.Brush.Color := UIStyle.Warn;
    lblHealth.Caption := 'DIKKAT';
  end
  else
  begin
    shpHealth.Brush.Color := UIStyle.Danger;
    lblHealth.Caption := 'SORUN';
  end;
  if Assigned(lblCardHealth) then
    lblCardHealth.Caption := lblHealth.Caption;
  if FHealthTxt <> '' then
    tmPulse.Enabled := True
  else
    tmPulse.Enabled := False;
end;

procedure TfrmMain.PulseTimer(Sender: TObject);
// Saglik isaretinin nabzi. 2026-10-04 (M10): renkler paletten ve
// UC durumu ayirt ediyor (saglam / dikkat / sorun). Onceki hâl
// yalniz iki renk arasinda gidip geliyordu ve "DIKKAT" mesaji
// SORUN gibi yanip sonuyordu.
var
  base, alt: TColor;
begin
  if FHealthTxt = '' then Exit;
  if Pos('SAGLAM', FHealthTxt) = 1 then
  begin
    base := UIStyle.Ok;
    alt := Lighten(UIStyle.Ok, 0.35);
  end
  else if Pos('DIKKAT', FHealthTxt) = 1 then
  begin
    base := UIStyle.Warn;
    alt := Lighten(UIStyle.Warn, 0.35);
  end
  else
  begin
    base := UIStyle.Danger;
    alt := Lighten(UIStyle.Danger, 0.35);
  end;
  if shpHealth.Brush.Color = base then
    shpHealth.Brush.Color := alt
  else
    shpHealth.Brush.Color := base;
end;

procedure TfrmMain.Log(const Msg: string);
begin
  meLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + ' ' + Msg);
end;

function TfrmMain.DbSizeStr(const P: string): string;
begin
  if not FileExists(P) then Exit('yok');
  Result := IntToStr(FileUtil.FileSize(P) div 1024) + ' KB';
end;

function TfrmMain.AgeText(const P: string): string;
// 2026-10-04 (M9): WAL dosyasinin yazilma zamani.
// NOT: bu FPC surumunde SysUtils.FileAge ve FileUtil.FileAge YOK;
// Windows API'siyle (GetFileTime) almak da "Create" gibi isimlerle
// cakisma yarattigi icin kullanilmadi. Bakim gereksinimi olan yer
// dosya boyutudur; tarih bilgisi veritabani dosyasindan zaten
// uzmanlastirilmis bir aracla alinmalidir.
begin
  Result := '';
end;

{ ---------------- olaylar ---------------- }

procedure TfrmMain.btnOpenDBClick(Sender: TObject);
var
  od: TOpenDialog;
begin
  od := TOpenDialog.Create(nil);
  try
    od.InitialDir := FCurrentDBDir;
    od.Filter := 'VDb veritabani|*.odb';
    if od.Execute then
      OpenDB(od.FileName);
  finally
    od.Free;
  end;
end;

procedure TfrmMain.btnNewDBClick(Sender: TObject);
var
  nm: string;
begin
  EnsureOpen;
  if not NewDbDlg(nm) then Exit;
  try
    FSq.Exec('CREATE DATABASE ' + nm);
    SetStatus('Olusturuldu: ' + nm);
    Log('CREATE DATABASE ' + nm);
    RefreshTree;
  except
    on E: Exception do
      ShowMessage('Hata: ' + E.Message);
  end;
end;

procedure TfrmMain.btnDropDBClick(Sender: TObject);
var
  node: TTreeNode;
  p, nm: string;
begin
  node := tvList.Selected;
  p := SelectedDbPath(node);
  if p = '' then
  begin
    ShowMessage('Soldan bir veritabani secin.');
    Exit;
  end;
  nm := ChangeFileExt(ExtractFileName(p), '');
  if MessageDlg('Veritabani Sil',
    'Silinsin mi?' + sLineBreak + p, mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  try
    EnsureOpen;
    FSq.Exec('DROP DATABASE ' + nm);
    if SameText(p, FDBPath) then
      CloseDB;
    Log('DROP DATABASE ' + nm);
    RefreshTree;
  except
    on E: Exception do
      ShowMessage('Silme hatasi: ' + E.Message);
  end;
end;

procedure TfrmMain.btnBackupClick(Sender: TObject);
var
  sd: TSaveDialog;
begin
  if not Assigned(FKv) then
  begin
    ShowMessage('Once bir veritabani acin.');
    Exit;
  end;
  sd := TSaveDialog.Create(nil);
  try
    sd.InitialDir := FCurrentDBDir;
    sd.FileName := ChangeFileExt(ExtractFileName(FDBPath), '') +
      '.yedek-' + FormatDateTime('yyyy-mm-dd_hhnnss', Now) + '.odb';
    sd.Filter := 'VDb yedek|*.odb';
    if not sd.Execute then Exit;
    try
      FKv.BackupTo(sd.FileName);
      SetStatus('Yedek alindi');
      Log('Yedek: ' + sd.FileName);
      ShowMessage('Yedek alindi:' + sLineBreak + sd.FileName);
    except
      on E: Exception do
        ShowMessage('Yedek hatasi: ' + E.Message);
    end;
  finally
    sd.Free;
  end;
end;

procedure TfrmMain.btnVerifyClick(Sender: TObject);
var
  rep: string;
  ok: Boolean;
begin
  if not Assigned(FKv) then
  begin
    ShowMessage('Once bir veritabani acin.');
    Exit;
  end;
  ok := FKv.Verify(rep);
  if ok then
  begin
    SetHealth('SAGLAM');
    Log('Verify: SAGLAM - ' + rep);
  end
  else
  begin
    SetHealth('SORUN: ' + rep);
    Log('Verify BASARISIZ: ' + rep);
  end;
  ShowMessage(rep);
end;

procedure TfrmMain.btnCompactClick(Sender: TObject);
begin
  if not Assigned(FSq) then Exit;
  try
    FSq.Exec('VACUUM');
    SetStatus('VACUUM tamamlandi');
    Log('VACUUM tamamlandi');
    OpenDB(FDBPath);
  except
    on E: Exception do
      ShowMessage('VACUUM hatasi: ' + E.Message);
  end;
end;

procedure TfrmMain.btnAutoCompactClick(Sender: TObject);
// 2026-10-04 (M8): GEREKTIGINDE SIKISTIR. VACUUM her zaman tam sikistirma
// yapar; AutoCompact yalniz olu bayt orani esigi asildiginda calisir
// (MaxDeadRatio) ve kucuk veritabanlarinda hic elleşmez (MinBytes).
var
  vOld, vNew: Int64;
  did: Boolean;
begin
  if not Assigned(FKv) then Exit;
  try
    did := FKv.AutoCompact(vOld, vNew);
    // Compact -> ReplaceWith -> atomik rename + YENIDEN ACIS. Bu yuzden
    // dosya degistigi halde TVTableDb'nin BELLEKTEKI semasi ve indeks
    // onbellegi bayat kalir. VACUUM butonu da bu yuzden OpenDB ile
    // yeniden aciyor; AutoCompact icin de aynisi sart (yoksa
    // sonraki sorgularda "tablo yok" gorulur).
    if did then
    begin
      Log(Format('OTOMATIK SIKISTIRMA: %d -> %d bayt (%d bayt kazanc)',
        [vOld, vNew, vOld - vNew]));
      OpenDB(FDBPath);
      SetStatus('Sikistirildi: ' + IntToStr(vOld - vNew) + ' bayt kazanc');
    end
    else
    begin
      Log('OTOMATIK SIKISTIRMA: gerek yok (olu bayt: ' +
        IntToStr(FKv.DeadBytes) + ')');
      SetStatus('Sikistirma gerekmiyor');
    end;
  except
    on E: Exception do
    begin
      ShowMessage('Sikistirma hatasi: ' + E.Message);
      Log('Sikistirma hatasi: ' + E.Message);
    end;
  end;
end;

procedure TfrmMain.btnReindexClick(Sender: TObject);
begin
  if not Assigned(FSq) then Exit;
  try
    FSq.Exec('REINDEX');
    SetStatus('REINDEX tamamlandi');
    Log('REINDEX tamamlandi');
    if FCurrentTable <> '' then
      RefreshIndexes;
  except
    on E: Exception do
      ShowMessage('REINDEX hatasi: ' + E.Message);
  end;
end;

{ ---------------- WAL (yazma oncesi gunluk) ---------------- }
// 2026-10-04 (M9): Motorun WAL'i gercek bir dosyaya yaziyor, replay
// ediyor ve checkpoint ile temizliyor; yonetimde HICBIR arac yoktu.
// Asagidaki uc arac durumu gorunur kilar ve islemleri tek tikla
// calistirir.

procedure TfrmMain.RefreshWalUI;
// 2026-10-04 (M9): Bekleyen WAL varsa dugmeler vurgulanir ve bilgi
// paneli yenilenir. Her veritabani acilisinda ve WAL araclarindan
// sonra cagrilir.
var
  waiting: Boolean;
begin
  if not Assigned(FKv) then Exit;
  waiting := FKv.HasWAL;
  if Assigned(bWalStatus) then
  begin
    if waiting then
    begin
      bWalStatus.Font.Color := clRed;
      bWalStatus.Font.Style := [fsBold];
    end
    else
    begin
      bWalStatus.Font.Style := [];
      bWalStatus.Font.Color := clBtnText;
    end;
  end;
  if Assigned(bWalReplay) then
    bWalReplay.Enabled := waiting;
  if Assigned(bWalCkpt) then
    bWalCkpt.Enabled := waiting;
  { 2026-10-04 (M10): otomatik WAL anahtari motorun gercek durumuyla
    esitlenmeli. Close/Open durumu sifirladigi icin eski bir Down
    degeri yeni acilista yaniltici olurdu. }
  if Assigned(bWalAuto) then
  begin
    bWalAuto.Down := FKv.WALEnabled;
    bWalAuto.Enabled := True;
  end;
  if waiting then
  begin
    SetHealth('DIKKAT: WAL bekliyor');
    Log('WAL durumu: ' + DbSizeStr(FKv.WalPath) + ' bekleyen kayit var');
  end
  else if FHealthTxt = 'DIKKAT: WAL bekliyor' then
    SetHealth('');
  if Assigned(lblDBInfo) then
    lblDBInfo.Caption := DBInfoText;
end;

procedure TfrmMain.btnWalAutoClick(Sender: TObject);
{ 2026-10-04 (M10): otomatik WAL (write-ahead) anahtarı.
  ACIK: her yazma once .wal'a, sonra ana dosyaya. Boylece sistem
  yazma aninda cokerse kayit .wal'da kalir ve Replay ile kurtarilir.
  KAPALI (varsayilan): yazma dogrudan ana dosyaya (eski davranis).
  Durum Close/Open ile sifirlanir; bu yuzden dugme her acilista
  RefreshWalUI ile esitlenir. }
var
  yeni: Boolean;
  n: Integer;
begin
  if not Assigned(FKv) then
  begin
    ShowMessage('Once bir veritabani acin.');
    if Assigned(bWalAuto) then bWalAuto.Down := False;
    Exit;
  end;
  yeni := not FKv.WALEnabled;
  try
    FKv.WALEnabled := yeni;
  except
    on E: Exception do
    begin
      Log('Otomatik WAL acilamadi: ' + E.Message);
      ShowMessage('Otomatik WAL acilamadi:' + sLineBreak + E.Message);
      if Assigned(bWalAuto) then bWalAuto.Down := FKv.WALEnabled;
      Exit;
    end;
  end;
  if Assigned(bWalAuto) then bWalAuto.Down := FKv.WALEnabled;
  if FKv.WALEnabled then
  begin
    SetHealth('Otomatik WAL ACIK (yazma once .wal''a)');
    Log('Otomatik WAL ACIK: yazma once .wal''a, sonra ana dosyaya');
  end
  else
  begin
    if FHealthTxt = 'Otomatik WAL ACIK (yazma once .wal''a)' then SetHealth('');
    Log('Otomatik WAL KAPALI: yazma dogrudan ana dosyaya');
  end;
  n := FKv.WalAutoCount;
  Log('Otomatik yazma sayaci: ' + IntToStr(n));
  RefreshWalUI;
end;

procedure TfrmMain.btnWalStatusClick(Sender: TObject);
// WAL dosyasi var mi, boyutu ne, ne zaman degismis.
var
  wp: string;
  info: string;
  age: string;
  oto: string;
begin
  if not Assigned(FKv) then
  begin
    ShowMessage('Once bir veritabani acin.');
    Exit;
  end;
  // 2026-10-04 (M10): otomatik WAL durumu her iki pencerede de gorunsun.
  if FKv.WALEnabled then
    oto := 'Otomatik WAL: ACIK (yazma once .wal''a, sonra ana dosyaya)' + sLineBreak +
      'Bu oturumda otomatik yazilan kayit: ' + IntToStr(FKv.WalAutoCount)
  else
    oto := 'Otomatik WAL: KAPALI (yazma dogrudan ana dosyaya)';
  wp := FKv.WalPath;
  if not FileExists(wp) then
  begin
    info := 'WAL dosyasi YOK' + sLineBreak + sLineBreak +
      'Yol: ' + wp + sLineBreak +
      oto + sLineBreak +
      'Kayitlanmamis degisiklik bulunmuyor.';
    Log('WAL durumu: dosya yok');
    SetStatus('WAL: dosya yok');
    ShowMessage(info);
    Exit;
  end;
  if FKv.WALEnabled then
  begin
    { OTOMATIK WAL ACIK: kayitlar ana dosyaya DA yazildi. Replay
      kayitlari TEKRAR uygular. PUT/DEL ayni sonucu verdiginden veri
      bozulmaz, ama zaten kaydedilmis veri yeniden yazilir; bu yuzden
      burada varsayilan olarak Checkpoint onerilir. }
    info := 'WAL (write-ahead gunlugu) BEKLIYOR' + sLineBreak +
      sLineBreak + 'Yol: ' + wp + sLineBreak +
      'Boyut: ' + DbSizeStr(wp) + sLineBreak +
      'Kayit sayisi: ' + IntToStr(FKv.WalRecordCount) + sLineBreak +
      oto + sLineBreak + sLineBreak +
      'OTOMATIK WAL ACIK oldugu icin bu kayitlar ANA DOSYAYA DA zaten' + sLineBreak +
      'yazildi. Replay kayitlari IKI KEZ uygular: veri bozulmaz' + sLineBreak +
      '(PUT/DEL ayni sonucu verir) ama ayni kayit yeniden yazilir.' + sLineBreak +
      'Bu durumda daha dogru islem Checkpoint (gunlugu temizle).' + sLineBreak + sLineBreak +
      'Yine de Replay (uygula) edilsin mi?';
  end
  else
  begin
    info := 'WAL BEKLIYOR - kayitlar ana dosyaya yazilmadi' + sLineBreak +
      sLineBreak + 'Yol: ' + wp + sLineBreak +
      'Boyut: ' + DbSizeStr(wp) + sLineBreak +
      'Kayit sayisi: ' + IntToStr(FKv.WalRecordCount) + sLineBreak +
      oto + sLineBreak +
      'Durum: kayitlar henuz veritabanina YAZILMADI';
  end;
  Log('WAL durumu: ' + DbSizeStr(wp) + ' bekliyor (' + wp + ')');
  SetStatus('WAL: ' + DbSizeStr(wp) + ' bekliyor');
  if MessageDlg('WAL dosyasi bekliyor:' + sLineBreak + sLineBreak + info +
    sLineBreak + sLineBreak + 'Simdi Replay (uygula) edilsin mi?',
    mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    btnWalReplayClick(Sender);
end;

procedure TfrmMain.btnWalReplayClick(Sender: TObject);
// Replay: .wal icerigi ana dosyaya yazilir, sonra .wal silinir.
// Kayitlar ONCEDEN ana dosyaya yazilmadigi icin bu islem veri kaybi
// degil, tam tersi kazanadir. Yine de onay istenir.
var
  wp: string;
  rep: string;
begin
  if not Assigned(FKv) then
  begin
    ShowMessage('Once bir veritabani acin.');
    Exit;
  end;
  wp := FKv.WalPath;
  if not FileExists(wp) then
  begin
    SetStatus('WAL: dosya yok, replay yapilacak is yok');
    Log('WAL replay: dosya yok, atlandi');
    Exit;
  end;
  if MessageDlg('WAL kayitlari veritabanina uygulansin mi?' + sLineBreak +
    sLineBreak + 'Kayit: ' + wp + sLineBreak +
    'Boyut: ' + DbSizeStr(wp) + sLineBreak + sLineBreak +
    'Bozuk/yirtik kayitlar atlanir; gecerli olanlar tek islemde yazilir.',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
  begin
    SetStatus('WAL replay: iptal edildi');
    Exit;
  end;
  try
    if FKv.ReplayWAL then
    begin
      Log(Format('WAL REPLAY: kayitlar uygulandi, %s gunluk %s olarak silindi',
        [DbSizeStr(wp), DbSizeStr(FKv.FilePath)]));
      SetStatus('WAL replay: kayitlar uygulandi');
      // Replay ana dosyayi degistirdi: bilgi panelini tazele
      lblDBInfo.Caption := DBInfoText;
      rep := '';
      if FKv.Verify(rep) then
        SetHealth('SAGLAM')
      else
        SetHealth('SORUN: ' + rep);
    end
    else
    begin
      Log('WAL replay BASARISIZ');
      SetStatus('WAL replay basarisiz');
      ShowMessage('WAL replay basarisiz. .wal dosyasi korundu; ' +
        'dosyayi inceleyip tekrar deneyin.');
    end;
  except
    on E: Exception do
    begin
      Log('WAL replay hatasi: ' + E.Message);
      ShowMessage('WAL replay hatasi: ' + E.Message);
    end;
  end;
end;

procedure TfrmMain.btnWalCheckpointClick(Sender: TObject);
// Checkpoint = replay + .wal silme. Kayitlar varsa ONCE uygulanir.
begin
  if not Assigned(FKv) then
  begin
    ShowMessage('Once bir veritabani acin.');
    Exit;
  end;
  if not FKv.HasWAL then
  begin
    SetStatus('WAL checkpoint: bekleyen kayit yok');
    Log('WAL checkpoint: bekleyen kayit yok');
    Exit;
  end;
  if MessageDlg('WAL checkpoint yapilsin mi?' + sLineBreak + sLineBreak +
    'Bekleyen kayitlar veritabanina yazilir ve gunluk dosyasi silinir.',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
  begin
    SetStatus('WAL checkpoint: iptal edildi');
    Exit;
  end;
  try
    if FKv.CheckpointWAL then
    begin
      Log('WAL CHECKPOINT: kayitlar uygulandi, gunluk silindi');
      SetStatus('WAL checkpoint tamamlandi');
      lblDBInfo.Caption := DBInfoText;
    end
    else
    begin
      Log('WAL CHECKPOINT basarisiz');
      ShowMessage('Checkpoint basarisiz. Gunluk dosyasi SILINMEDI.');
    end;
  except
    on E: Exception do
    begin
      Log('WAL checkpoint hatasi: ' + E.Message);
      ShowMessage('WAL checkpoint hatasi: ' + E.Message);
    end;
  end;
end;

procedure TfrmMain.btnRefreshAllClick(Sender: TObject);
begin
  RefreshTree;
  if (FDBPath <> '') and FileExists(FDBPath) then
    OpenDB(FDBPath);
end;

procedure TfrmMain.btnExportClick(Sender: TObject);
var
  sd: TSaveDialog;
begin
  if not Assigned(FTb) then Exit;
  sd := TSaveDialog.Create(nil);
  try
    sd.InitialDir := FCurrentDBDir;
    sd.FileName := 'yedek.json';
    sd.Filter := 'JSON|*.json';
    if not sd.Execute then Exit;
    try
      VDbExportJson(FTb, sd.FileName, '');
      Log('Export JSON: ' + sd.FileName);
      ShowMessage('Aktarildi:' + sLineBreak + sd.FileName);
    except
      on E: Exception do
        ShowMessage('Export hatasi: ' + E.Message);
    end;
  finally
    sd.Free;
  end;
end;

procedure TfrmMain.btnImportClick(Sender: TObject);
var
  od: TOpenDialog;
begin
  if not Assigned(FTb) then Exit;
  od := TOpenDialog.Create(nil);
  try
    od.InitialDir := FCurrentDBDir;
    od.Filter := 'JSON|*.json';
    if not od.Execute then Exit;
    try
      VDbImportJson(FTb, od.FileName);
      Log('Import JSON: ' + od.FileName);
      RefreshTree;
      ShowMessage('Ice aktarildi.');
    except
      on E: Exception do
        ShowMessage('Import hatasi: ' + E.Message);
    end;
  finally
    od.Free;
  end;
end;

procedure TfrmMain.mnuExitClick(Sender: TObject);
begin
  Close;
end;

procedure TfrmMain.mnuAboutClick(Sender: TObject);
begin
  ShowMessage('VDb Manager v2' + sLineBreak +
    L('Saf FPC veritabani yonetim programi.',
      'Pure FPC database management program.'));
end;

procedure TfrmMain.btnNewTableClick(Sender: TObject);
var
  nm: string;
  cols: TColArray;
  pk: Integer;
begin
  if not Assigned(FTb) then
  begin
    ShowMessage('Once bir veritabani acin.');
    Exit;
  end;
  if not NewTableDlg(nm, cols, pk) then Exit;
  try
    FTb.CreateTable(nm, cols, pk, [], []);
    SetStatus('Tablo olusturuldu: ' + nm);
    Log('CREATE TABLE ' + nm);
    RefreshTree;
    SelectTable(nm);
  except
    on E: Exception do
      ShowMessage('Tablo hatasi: ' + E.Message);
  end;
end;

procedure TfrmMain.btnDropTableClick(Sender: TObject);
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  if MessageDlg('Tablo Sil', 'Silinsin mi?' + sLineBreak + FCurrentTable,
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  try
    FTb.DropTable(FCurrentTable);
    SetStatus('Tablo silindi');
    Log('DROP TABLE ' + FCurrentTable);
    FCurrentTable := '';
    RefreshTree;
  except
    on E: Exception do
      ShowMessage('Silme hatasi: ' + E.Message);
  end;
end;

procedure TfrmMain.btnRenameTableClick(Sender: TObject);
var
  nm: string;
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  nm := InputBox('Tablo Adlandir', 'Yeni ad:', FCurrentTable);
  nm := LowerCase(Trim(nm));
  if (nm = '') or (nm = FCurrentTable) then Exit;
  try
    FTb.AlterRenameTable(FCurrentTable, nm);
    Log('RENAME ' + FCurrentTable + ' -> ' + nm);
    RefreshTree;
    SelectTable(nm);
  except
    on E: Exception do
      ShowMessage('Hata: ' + E.Message);
  end;
end;

procedure TfrmMain.btnAddColClick(Sender: TObject);
var
  c: TColDef;
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  if not AddColumnDlg(c) then Exit;
  try
    FTb.AlterAddColumn(FCurrentTable, c, '', False, '');
    SetStatus('Sutun eklendi: ' + c.Name);
    Log('ADD COLUMN ' + FCurrentTable + '.' + c.Name);
    SelectTable(FCurrentTable);
  except
    on E: Exception do
      ShowMessage('Hata: ' + E.Message);
  end;
end;

procedure TfrmMain.btnDropColClick(Sender: TObject);
var
  cn: string;
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  cn := InputBox('Sutun Sil', 'Sutun adi:', '');
  if Trim(cn) = '' then Exit;
  if MessageDlg('Sutun Sil', cn + ' silinsin mi?', mtConfirmation,
    [mbYes, mbNo], 0) <> mrYes then Exit;
  try
    FTb.AlterDropColumn(FCurrentTable, cn);
    Log('DROP COLUMN ' + FCurrentTable + '.' + cn);
    SelectTable(FCurrentTable);
  except
    on E: Exception do
      ShowMessage('Hata: ' + E.Message);
  end;
end;

procedure TfrmMain.btnRenameColClick(Sender: TObject);
var
  oldN, newN: string;
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  oldN := InputBox('Sutun Adlandir', 'Eski ad:', '');
  if Trim(oldN) = '' then Exit;
  newN := InputBox('Sutun Adlandir', 'Yeni ad:', '');
  if Trim(newN) = '' then Exit;
  try
    FTb.AlterRenameColumn(FCurrentTable, oldN, newN);
    Log('RENAME COLUMN ' + oldN + ' -> ' + newN);
    SelectTable(FCurrentTable);
  except
    on E: Exception do
      ShowMessage('Hata: ' + E.Message);
  end;
end;

procedure TfrmMain.btnIdxAddClick(Sender: TObject);
var
  nm, cn: string;
  cols: TStrArray;
  i: Integer;
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  nm := LowerCase(Trim(edIdxName.Text));
  cn := Trim(cbIdxCol.Text);
  if (nm = '') or (cn = '') then
  begin
    ShowMessage('Index adi ve sutun gerekli.');
    Exit;
  end;
  // "a,b,c" -> ['a','b','c']  (cok kolonlu indeks)
  SplitCSV(cn, cols);
  if Length(cols) = 0 then
  begin
    ShowMessage('Sutun listesi bos.');
    Exit;
  end;
  for i := 0 to High(cols) do
    cols[i] := LowerCase(Trim(cols[i]));
  try
    // 2026-10-04: UNIQUE secenegi ve cok kolonlu indeks. Motor F2-15
    // (uzunluk-oneki anahtar) ve F2-23 (UNIQUE zorlamasi) ile bunlari
    // destekliyordu; yonetim araci olusturamiyordu.
    FTb.CreateIndexCols(FCurrentTable, nm, cols, cbIdxUnique.Checked);
    if cbIdxUnique.Checked then
      Log('CREATE UNIQUE INDEX ' + nm + ' ON ' + FCurrentTable + '(' + cn + ')')
    else
      Log('CREATE INDEX ' + nm + ' ON ' + FCurrentTable + '(' + cn + ')');
    RefreshIndexes;
  except
    on E: Exception do
      ShowMessage('Hata: ' + E.Message);
  end;
end;

procedure TfrmMain.btnIdxDropClick(Sender: TObject);
var
  nm: string;
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  if sgIdx.Row < 1 then Exit;
  nm := sgIdx.Cells[0, sgIdx.Row];
  if nm = '' then Exit;
  try
    FTb.DropIndex(nm);
    Log('DROP INDEX ' + nm);
    RefreshIndexes;
  except
    on E: Exception do
      ShowMessage('Hata: ' + E.Message);
  end;
end;

procedure TfrmMain.btnExecSQLClick(Sender: TObject);
begin
  ExecuteSQL(meSQL.Text);
end;

{ ---------------- sema sorgulari (M9) ---------------- }
// 2026-10-04 (M9): Motor DESCRIBE / SHOW INDEXES / SHOW CREATE TABLE
// destekliyordu; yonetimde kullanilacak bir arac yoktu. Bu araclar
// secili tablo icin sorguyu SQL sekmesine YAZIP calistirir; boylece
// kullanici hem sonucu gorur hem de sorguyu duzenleyip tekrar
// calistirabilir.

procedure TfrmMain.RunSchemaQuery(const Q: string);
// Sorguyu SQL sekmesine yazip calistirir (sonuc kullaniciya gosterilir).
begin
  meSQL.Text := Q;
  pcMain.ActivePage := tsSQL;
  ExecuteSQL(Q);
end;

procedure TfrmMain.btnDescribeClick(Sender: TObject);
begin
  if (not Assigned(FSq)) or (FCurrentTable = '') then
  begin
    ShowMessage('Once bir tablo secin.');
    Exit;
  end;
  Log('Sema: DESCRIBE ' + FCurrentTable);
  RunSchemaQuery('DESCRIBE ' + FCurrentTable);
end;

procedure TfrmMain.btnShowIndexesClick(Sender: TObject);
begin
  if (not Assigned(FSq)) or (FCurrentTable = '') then
  begin
    ShowMessage('Once bir tablo secin.');
    Exit;
  end;
  Log('Sema: SHOW INDEXES FROM ' + FCurrentTable);
  RunSchemaQuery('SHOW INDEXES FROM ' + FCurrentTable);
end;

procedure TfrmMain.btnShowCreateClick(Sender: TObject);
begin
  if (not Assigned(FSq)) or (FCurrentTable = '') then
  begin
    ShowMessage('Once bir tablo secin.');
    Exit;
  end;
  Log('Sema: SHOW CREATE TABLE ' + FCurrentTable);
  RunSchemaQuery('SHOW CREATE TABLE ' + FCurrentTable);
end;

procedure TfrmMain.btnSchemaSqlClick(Sender: TObject);
// Butun semayi tek ekranda goster: her tablo icin CREATE TABLE.
var
  i: Integer;
  outp: string;
  tables: TStrArray;
begin
  if not Assigned(FTb) then
  begin
    ShowMessage('Once bir veritabani acin.');
    Exit;
  end;
  tables := FTb.TableNames;
  outp := '';
  for i := 0 to High(tables) do
    if tables[i] <> '' then
      outp := outp + 'SHOW CREATE TABLE ' + tables[i] + ';' + sLineBreak;
  if outp = '' then
  begin
    SetStatus('Sema betigi: tabloda yok');
    Exit;
  end;
  meSQL.Text := outp;
  pcMain.ActivePage := tsSQL;
  ExecuteSQL(outp);
  SetStatus('Sema betigi uretildi: ' + IntToStr(Length(tables)) + ' tablo');
  Log('Sema betigi uretildi (' + IntToStr(Length(tables)) + ' tablo)');
end;

procedure TfrmMain.btnSqlClearClick(Sender: TObject);
begin
  meSQL.Clear;
end;

procedure TfrmMain.cbHistChange(Sender: TObject);
begin
  if cbHist.ItemIndex >= 0 then
    meSQL.Text := cbHist.Items[cbHist.ItemIndex];
end;

procedure TfrmMain.btnFirstClick(Sender: TObject);
begin
  FPage := 0;
  RenderPage;
end;

procedure TfrmMain.btnPrevClick(Sender: TObject);
begin
  if FPage > 0 then Dec(FPage);
  RenderPage;
end;

procedure TfrmMain.btnNextClick(Sender: TObject);
begin
  Inc(FPage);
  if FPage * FPageSize >= Length(FDataPks) then
    Dec(FPage);
  RenderPage;
end;

procedure TfrmMain.btnLastClick(Sender: TObject);
begin
  if Length(FDataPks) = 0 then Exit;
  FPage := (Length(FDataPks) - 1) div FPageSize;
  RenderPage;
end;

procedure TfrmMain.cbPageSizeChange(Sender: TObject);
begin
  FPageSize := StrToIntDef(cbPageSize.Text, 100);
  if FPageSize < 10 then FPageSize := 10;
  FPage := 0;
  RenderPage;
end;

procedure TfrmMain.btnAddRowClick(Sender: TObject);
begin
  if (not Assigned(FSq)) or (FCurrentTable = '') then Exit;
  try
    FSq.Exec('INSERT INTO ' + FCurrentTable + ' DEFAULT VALUES');
    ReloadData;
    FPage := (Length(FDataPks) - 1) div FPageSize;
    RenderPage;
    SetStatus('Satir eklendi');
  except
    on E: Exception do
      ShowMessage('Ekleme hatasi: ' + E.Message +
        sLineBreak + 'SQL sekmesinden INSERT yazabilirsiniz.');
  end;
end;

procedure TfrmMain.btnDelRowClick(Sender: TObject);
var
  idx: Integer;
  pkVal: string;
begin
  if (not Assigned(FSq)) or (FCurrentTable = '') then Exit;
  if sgData.Row < 1 then Exit;
  idx := FPage * FPageSize + (sgData.Row - 1);
  if (idx < 0) or (idx > High(FDataPks)) then Exit;
  pkVal := FDataPks[idx];
  // 2026-10-04: satir PK KOLONU ile degil, satir anahtari ile adresleniyor;
  // PK'siz tablolarda da calisir. Onceki kod PK yoksa sessizce Exit
  // ediyordu, yani o tablolarda hicbir satir silinemiyordu.
  // TVTableDb.Delete motorun SQL DELETE'inin kullandigi yordamdir:
  // ON DELETE CASCADE / SET NULL / RESTRICT dahil (CheckRestrict).
  if MessageDlg('Satir Sil', 'Anahtar=' + pkVal + ' silinsin mi?',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  try
    if FTb.Delete(FCurrentTable, pkVal) then
    begin
      ReloadData;
      SetStatus('Satir silindi');
    end
    else
    begin
      ShowMessage('Satir bulunamadi.');
      ReloadData;
    end;
  except
    on E: Exception do
      ShowMessage('Silme hatasi: ' + E.Message);
  end;
end;

procedure TfrmMain.btnRefreshDataClick(Sender: TObject);
begin
  if pcMain.ActivePage = tsData then
    ReloadData
  else if pcMain.ActivePage = tsSchema then
    RefreshSchema;
end;

procedure TfrmMain.FilterTreeView(Sender: TObject);
var
  i: Integer;
  searchText: string;
  node: TTreeNode;
begin
  searchText := LowerCase(Trim(TEdit(Sender).Text));
  if searchText = '' then
  begin
    for i := 0 to tvList.Items.Count - 1 do
      tvList.Items[i].Expand(False);
    Exit;
  end;
  for i := 0 to tvList.Items.Count - 1 do
  begin
    node := tvList.Items[i];
    if (node.Level = 2) and (Pos(searchText, LowerCase(node.Text)) = 0) then
      node.Collapse(False)
    else
      node.Expand(False);
  end;
end;

procedure TfrmMain.tvListClick(Sender: TObject);
var
  node: TTreeNode;
  p: string;
begin
  node := tvList.Selected;
  if node = nil then Exit;
  if node.Level = 2 then
    SelectTable(node.Text)
  else if node.Level = 1 then
  begin
    p := SelectedDbPath(node);
    if p <> '' then
      lblDBInfo.Caption := 'Dosya: ' + p + sLineBreak + 'Boyut: ' + DbSizeStr(p);
  end;
end;

procedure TfrmMain.tvListDblClick(Sender: TObject);
var
  node: TTreeNode;
  p: string;
begin
  node := tvList.Selected;
  p := SelectedDbPath(node);
  if p = '' then Exit;
  if SameText(p, FDBPath) then Exit;
  OpenDB(p);
end;

procedure TfrmMain.pcMainChange(Sender: TObject);
begin
  if not Assigned(FTb) then Exit;
  if pcMain.ActivePage = tsTable then
    ShowTableStructure
  else if pcMain.ActivePage = tsData then
    ReloadData
  else if pcMain.ActivePage = tsIdx then
    RefreshIndexes
  else if pcMain.ActivePage = tsRel then
    RefreshRelations
  else if pcMain.ActivePage = tsSchema then
    RefreshSchema
  else if pcMain.ActivePage = tsDB then
    RefreshDashboard;
end;

{ ---------------- panel + iliskiler + sql dosya + tx + kopya ---------------- }

procedure TfrmMain.RefreshDashboard;
var
  res: TSqlResult;
  i, j, total: Integer;
begin
  if not Assigned(FSq) then
  begin
    sgDB.RowCount := 2;
    sgDB.Cells[0,1] := '';
    sgDB.Cells[1,1] := '';
    lblCardTbl.Caption := '-';
    lblCardRow.Caption := '-';
    lblCardSize.Caption := '-';
    lblCardHealth.Caption := '-';
    Exit;
  end;
  try
    res := FSq.Exec('SHOW TABLES');
    if Length(res.Fields) >= 2 then
    begin
      sgDB.ColCount := 2;
      sgDB.Cells[0,0] := res.Fields[0];
      sgDB.Cells[1,0] := res.Fields[1];
    end
    else
    begin
      sgDB.ColCount := 2;
      sgDB.Cells[0,0] := 'Tablo';
      sgDB.Cells[1,0] := 'Satir';
    end;
    if Length(res.Rows) > 0 then
      sgDB.RowCount := Length(res.Rows) + 1
    else
      sgDB.RowCount := 2;
    total := 0;
    for i := 0 to High(res.Rows) do
    begin
      for j := 0 to 1 do
        if j <= High(res.Rows[i]) then
          sgDB.Cells[j, i+1] := res.Rows[i][j];
      if (Length(res.Rows[i]) > 1) then
        total := total + StrToIntDef(res.Rows[i][1], 0);
    end;
    lblCardTbl.Caption := IntToStr(Length(res.Rows));
    lblCardRow.Caption := IntToStr(total);
    lblCardSize.Caption := DbSizeStr(FDBPath);
    if lblHealth.Caption <> '' then
      lblCardHealth.Caption := lblHealth.Caption;
  except
    on E: Exception do
      Log('SHOW TABLES hatasi: ' + E.Message);
  end;
end;

procedure TfrmMain.RefreshRelations;
var
  td, ct: TTableDef;
  tables: TStrArray;
  ti, i, n: Integer;
begin
  sgFKOut.RowCount := 2;
  sgFKIn.RowCount := 2;
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  if not FTb.TableExists(FCurrentTable) then Exit;
  td := FTb.GetTable(FCurrentTable);
  if Length(td.Fks) > 0 then
    sgFKOut.RowCount := Length(td.Fks) + 1;
  for i := 0 to High(td.Fks) do
  begin
    if (td.Fks[i].Col >= 0) and (td.Fks[i].Col < Length(td.Cols)) then
      sgFKOut.Cells[0, i+1] := td.Cols[td.Fks[i].Col].Name
    else
      sgFKOut.Cells[0, i+1] := '?';
    sgFKOut.Cells[1, i+1] := td.Fks[i].RefTable;
    sgFKOut.Cells[2, i+1] := td.Fks[i].RefCol;
    sgFKOut.Cells[3, i+1] := td.Fks[i].OnDelete;
    sgFKOut.Cells[4, i+1] := td.Fks[i].OnUpdate;
  end;
  tables := FTb.TableNames;
  n := 0;
  for ti := 0 to High(tables) do
  begin
    if tables[ti] = FCurrentTable then Continue;
    ct := FTb.GetTable(tables[ti]);
    for i := 0 to High(ct.Fks) do
      if ct.Fks[i].RefTable = FCurrentTable then
      begin
        sgFKIn.RowCount := n + 2;
        sgFKIn.Cells[0, n+1] := tables[ti];
        if (ct.Fks[i].Col >= 0) and (ct.Fks[i].Col < Length(ct.Cols)) then
          sgFKIn.Cells[1, n+1] := ct.Cols[ct.Fks[i].Col].Name
        else
          sgFKIn.Cells[1, n+1] := '?';
        sgFKIn.Cells[2, n+1] := ct.Fks[i].RefCol;
        sgFKIn.Cells[3, n+1] := ct.Fks[i].OnDelete;
        sgFKIn.Cells[4, n+1] := ct.Fks[i].OnUpdate;
        Inc(n);
      end;
  end;
end;

procedure TfrmMain.sgDataHeaderClick(Sender: TObject; IsColumn: Boolean;
  index: Integer);
var
  td: TTableDef;
  cn: string;
begin
  if not IsColumn then Exit;
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  if index < 1 then Exit;
  td := FTb.GetTable(FCurrentTable);
  if (index - 1 < 0) or (index - 1 >= Length(td.Cols)) then Exit;
  cn := td.Cols[index - 1].Name;
  if FSortCol = cn then
    FSortDesc := not FSortDesc
  else
  begin
    FSortCol := cn;
    FSortDesc := False;
  end;
  cbSortCol.ItemIndex := cbSortCol.Items.IndexOf(cn);
  if FSortDesc then
    cbSortDir.ItemIndex := 1
  else
    cbSortDir.ItemIndex := 0;
  FPage := 0;
  ReloadData;
end;

procedure TfrmMain.btnSqlFileRunClick(Sender: TObject);
var
  od: TOpenDialog;
  sl: TStringList;
begin
  if not Assigned(FSq) then
  begin
    ShowMessage('Once bir veritabani acin.');
    Exit;
  end;
  od := TOpenDialog.Create(nil);
  try
    od.InitialDir := FCurrentDBDir;
    od.Filter := 'SQL|*.sql';
    if not od.Execute then Exit;
    sl := TStringList.Create;
    try
      sl.LoadFromFile(od.FileName);
      meSQL.Text := sl.Text;
      ExecuteSQL(sl.Text);
    finally
      sl.Free;
    end;
  finally
    od.Free;
  end;
end;

procedure TfrmMain.btnSqlSaveClick(Sender: TObject);
var
  sd: TSaveDialog;
begin
  sd := TSaveDialog.Create(nil);
  try
    sd.InitialDir := FCurrentDBDir;
    sd.FileName := 'sorgu.sql';
    sd.Filter := 'SQL|*.sql';
    if not sd.Execute then Exit;
    meSQL.Lines.SaveToFile(sd.FileName);
    SetStatus('Kaydedildi');
  finally
    sd.Free;
  end;
end;

procedure TfrmMain.cbSqlTemplatesChange(Sender: TObject);
var
  tbl: string;
begin
  if cbSqlTemplates.ItemIndex <= 0 then Exit;
  tbl := FCurrentTable;
  if tbl = '' then tbl := 'tablo_adi';
  case cbSqlTemplates.ItemIndex of
    1: meSQL.Text := 'SELECT * FROM ' + tbl + ' LIMIT 50;';
    2: meSQL.Text := 'SELECT COUNT(*) AS toplam FROM ' + tbl + ';';
    3: meSQL.Text := 'INSERT INTO ' + tbl + ' VALUES (...);';
    4: meSQL.Text := 'UPDATE ' + tbl + ' SET kolon1 = ''deger'' WHERE id = 1;';
    5: meSQL.Text := 'DELETE FROM ' + tbl + ' WHERE id = 1;';
    6: meSQL.Text := 'CREATE TABLE yeni_tablo (' + sLineBreak +
                     '  id INTEGER PRIMARY KEY,' + sLineBreak +
                     '  ad TEXT NOT NULL,' + sLineBreak +
                     '  fiyat FLOAT DEFAULT 0.0,' + sLineBreak +
                     '  aktif BOOL DEFAULT 1' + sLineBreak +
                     ');';
    7: meSQL.Text := 'ALTER TABLE ' + tbl + ' ADD yeni_kolon TEXT;';
    8: meSQL.Text := 'SHOW TABLES;';
    9: meSQL.Text := 'LIST DATABASES;';
    10: meSQL.Text := 'VACUUM;';
    11: meSQL.Text := 'VERIFY;';
  end;
  cbSqlTemplates.ItemIndex := 0;
end;

procedure TfrmMain.btnSqlCopyTSVClick(Sender: TObject);
var
  i, j: Integer;
  sl: TStringList;
  line: string;
begin
  if (sgSQLRes.ColCount = 0) or (sgSQLRes.RowCount = 0) then Exit;
  sl := TStringList.Create;
  try
    for i := 0 to sgSQLRes.RowCount - 1 do
    begin
      line := '';
      for j := 0 to sgSQLRes.ColCount - 1 do
      begin
        if j > 0 then line := line + #9;
        line := line + sgSQLRes.Cells[j, i];
      end;
      sl.Add(line);
    end;
    Clipboard.AsText := sl.Text;
    SetStatus(Format('%d satir panoya kopyalandi', [sgSQLRes.RowCount - 1]));
  finally
    sl.Free;
  end;
end;

procedure TfrmMain.btnSqlSaveCSVClick(Sender: TObject);
var
  sd: TSaveDialog;
  i, j: Integer;
  sl: TStringList;
  line, cell: string;
begin
  if (sgSQLRes.ColCount = 0) or (sgSQLRes.RowCount = 0) then Exit;
  sd := TSaveDialog.Create(nil);
  try
    sd.Filter := 'CSV Dosyasi (*.csv)|*.csv|Tum Dosyalar (*.*)|*.*';
    sd.DefaultExt := 'csv';
    sd.InitialDir := FCurrentDBDir;
    if sd.Execute then
    begin
      sl := TStringList.Create;
      try
        for i := 0 to sgSQLRes.RowCount - 1 do
        begin
          line := '';
          for j := 0 to sgSQLRes.ColCount - 1 do
          begin
            if j > 0 then line := line + ';';
            cell := sgSQLRes.Cells[j, i];
            if (Pos(';', cell) > 0) or (Pos('"', cell) > 0) or (Pos(#10, cell) > 0) then
              cell := '"' + StringReplace(cell, '"', '""', [rfReplaceAll]) + '"';
            line := line + cell;
          end;
          sl.Add(line);
        end;
        sl.SaveToFile(sd.FileName);
        SetStatus('CSV kaydedildi: ' + ExtractFileName(sd.FileName));
      finally
        sl.Free;
      end;
    end;
  finally
    sd.Free;
  end;
end;

procedure TfrmMain.btnSqlSaveJSONClick(Sender: TObject);
var
  sd: TSaveDialog;
  i, j: Integer;
  sl: TStringList;
  valStr: string;
begin
  if (sgSQLRes.ColCount = 0) or (sgSQLRes.RowCount <= 1) then Exit;
  sd := TSaveDialog.Create(nil);
  try
    sd.Filter := 'JSON Dosyasi (*.json)|*.json|Tum Dosyalar (*.*)|*.*';
    sd.DefaultExt := 'json';
    sd.InitialDir := FCurrentDBDir;
    if sd.Execute then
    begin
      sl := TStringList.Create;
      try
        sl.Add('[');
        for i := 1 to sgSQLRes.RowCount - 1 do
        begin
          sl.Add('  {');
          for j := 0 to sgSQLRes.ColCount - 1 do
          begin
            valStr := StringReplace(sgSQLRes.Cells[j, i], '\', '\\', [rfReplaceAll]);
            valStr := StringReplace(valStr, '"', '\"', [rfReplaceAll]);
            valStr := StringReplace(valStr, #13#10, '\n', [rfReplaceAll]);
            valStr := StringReplace(valStr, #13, '\n', [rfReplaceAll]);
            valStr := StringReplace(valStr, #10, '\n', [rfReplaceAll]);
            valStr := StringReplace(valStr, #9, '\t', [rfReplaceAll]);
            if j < sgSQLRes.ColCount - 1 then
              sl.Add(Format('    "%s": "%s",', [sgSQLRes.Cells[j, 0], valStr]))
            else
              sl.Add(Format('    "%s": "%s"', [sgSQLRes.Cells[j, 0], valStr]));
          end;
          if i < sgSQLRes.RowCount - 1 then
            sl.Add('  },')
          else
            sl.Add('  }');
        end;
        sl.Add(']');
        sl.SaveToFile(sd.FileName);
        SetStatus('JSON kaydedildi: ' + ExtractFileName(sd.FileName));
      finally
        sl.Free;
      end;
    end;
  finally
    sd.Free;
  end;
end;

procedure TfrmMain.btnDataSaveCSVClick(Sender: TObject);
var
  sd: TSaveDialog;
  i, j: Integer;
  sl: TStringList;
  line, cell: string;
  td: TTableDef;
  pks: TStrArray;
  rows: TStrMatrix;
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  if not FTb.TableExists(FCurrentTable) then Exit;
  td := FTb.GetTable(FCurrentTable);
  FTb.ScanRows(FCurrentTable, pks, rows);
  if Length(pks) = 0 then
  begin
    ShowMessage('Tablo bos, yazilacak satir yok.');
    Exit;
  end;
  sd := TSaveDialog.Create(nil);
  try
    sd.Filter := 'CSV Dosyasi (*.csv)|*.csv|Tum Dosyalar (*.*)|*.*';
    sd.DefaultExt := 'csv';
    sd.FileName := FCurrentTable + '_veri.csv';
    sd.InitialDir := FCurrentDBDir;
    if sd.Execute then
    begin
      sl := TStringList.Create;
      try
        line := 'PK';
        for j := 0 to High(td.Cols) do
          line := line + ';' + td.Cols[j].Name;
        sl.Add(line);
        for i := 0 to High(pks) do
        begin
          line := pks[i];
          for j := 0 to High(td.Cols) do
          begin
            cell := rows[i][j];
            if (Pos(';', cell) > 0) or (Pos('"', cell) > 0) or (Pos(#10, cell) > 0) then
              cell := '"' + StringReplace(cell, '"', '""', [rfReplaceAll]) + '"';
            line := line + ';' + cell;
          end;
          sl.Add(line);
        end;
        sl.SaveToFile(sd.FileName);
        SetStatus(Format('CSV kaydedildi: %s (%d satir)',
          [ExtractFileName(sd.FileName), Length(pks)]));
      finally
        sl.Free;
      end;
    end;
  finally
    sd.Free;
  end;
end;

procedure TfrmMain.UpdateTx;
begin
  if Assigned(FKv) and FKv.InBatch then
    lblTx.Caption := '  TX: ACIK'
  else
    lblTx.Caption := '  TX: kapali';
end;

procedure TfrmMain.btnTxBeginClick(Sender: TObject);
begin
  if not Assigned(FSq) then Exit;
  try
    FSq.Exec('BEGIN');
    UpdateTx;
    SetStatus('Transaction basladi');
  except
    on E: Exception do
      ShowMessage('Hata: ' + E.Message);
  end;
end;

procedure TfrmMain.btnTxCommitClick(Sender: TObject);
begin
  if not Assigned(FSq) then Exit;
  try
    FSq.Exec('COMMIT');
    UpdateTx;
    SetStatus('COMMIT yapildi');
    RefreshTree;
    if FCurrentTable <> '' then
      ReloadData;
  except
    on E: Exception do
      ShowMessage('Hata: ' + E.Message);
  end;
end;

procedure TfrmMain.btnTxRollbackClick(Sender: TObject);
begin
  if not Assigned(FSq) then Exit;
  try
    FSq.Exec('ROLLBACK');
    UpdateTx;
    SetStatus('ROLLBACK yapildi');
    RefreshTree;
    if FCurrentTable <> '' then
      ReloadData;
  except
    on E: Exception do
      ShowMessage('Hata: ' + E.Message);
  end;
end;

procedure TfrmMain.btnCopyTableClick(Sender: TObject);
var
  td: TTableDef;
  nm, cols, q: string;
  i: Integer;
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then Exit;
  nm := LowerCase(Trim(InputBox('Tablo Kopyala', 'Yeni ad:', FCurrentTable + '_kopya')));
  if (nm = '') or (nm = FCurrentTable) then Exit;
  if FTb.TableExists(nm) then
  begin
    ShowMessage('Bu ad kullaniliyor: ' + nm);
    Exit;
  end;
  try
    td := FTb.GetTable(FCurrentTable);
    FTb.CreateTable(nm, td.Cols, td.PkIndex, [], []);
    cols := '';
    for i := 0 to High(td.Cols) do
    begin
      if i > 0 then cols := cols + ', ';
      cols := cols + td.Cols[i].Name;
    end;
    q := 'INSERT INTO ' + nm + ' (' + cols + ') SELECT ' + cols +
      ' FROM ' + FCurrentTable;
    FSq.Exec(q);
    Log('COPY TABLE ' + FCurrentTable + ' -> ' + nm);
    RefreshTree;
    SelectTable(nm);
    SetStatus('Kopyalandi: ' + nm);
  except
    on E: Exception do
      ShowMessage('Kopyalama hatasi:' + sLineBreak + E.Message);
  end;
end;

procedure TfrmMain.chkAutoBakClick(Sender: TObject);
begin
  SaveSettings;
end;

procedure TfrmMain.LoadSettings;
var
  sl: TStringList;
  p, db: string;
  i: Integer;
begin
  chkAutoBak.Checked := False;
  p := ExtractFilePath(Application.ExeName) + 'ayar.txt';
  if not FileExists(p) then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(p);
    db := '';
    for i := 0 to sl.Count - 1 do
    begin
      if Copy(sl[i], 1, 3) = 'db=' then
        db := Copy(sl[i], 4, MaxInt)
      else if sl[i] = 'auto=1' then
        chkAutoBak.Checked := True
      else if Copy(sl[i], 1, 5) = 'lang=' then
      begin
        if Copy(sl[i], 6, MaxInt) = 'tr' then
          CurrentLang := langTR
        else
          CurrentLang := langEN;
      end;
    end;
    if (db <> '') and FileExists(db) then
      OpenDB(db);
  finally
    sl.Free;
  end;
end;

procedure TfrmMain.SaveSettings;
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Add('db=' + FDBPath);
    if chkAutoBak.Checked then
      sl.Add('auto=1')
    else
      sl.Add('auto=0');
    if CurrentLang = langTR then
      sl.Add('lang=tr')
    else
      sl.Add('lang=en');
    sl.SaveToFile(ExtractFilePath(Application.ExeName) + 'ayar.txt');
  finally
    sl.Free;
  end;
end;

{ ---------------- ikonlar + tema ---------------- }

procedure TfrmMain.BuildIcons;
var
  bmp: TBitmap;

  procedure NewBmp;
  begin
    bmp := TBitmap.Create;
    bmp.Width := 16;
    bmp.Height := 16;
    bmp.Canvas.Brush.Color := clFuchsia;
    bmp.Canvas.FillRect(Rect(0, 0, 16, 16));
    bmp.Canvas.Pen.Width := 2;
  end;

  procedure AddBmp;
  begin
    il.AddMasked(bmp, clFuchsia);
    bmp.Free;
  end;

begin
  NewBmp;
  bmp.Canvas.Pen.Color := $0000A000;
  bmp.Canvas.Pen.Width := 3;
  bmp.Canvas.MoveTo(8, 3);
  bmp.Canvas.LineTo(8, 13);
  bmp.Canvas.MoveTo(3, 8);
  bmp.Canvas.LineTo(13, 8);
  AddBmp;
  NewBmp;
  bmp.Canvas.Brush.Color := $0000C8FF;
  bmp.Canvas.Pen.Color := $00008080;
  bmp.Canvas.Rectangle(1, 6, 15, 14);
  bmp.Canvas.Brush.Color := $0000E0FF;
  bmp.Canvas.Rectangle(1, 3, 7, 7);
  AddBmp;
  NewBmp;
  bmp.Canvas.Pen.Color := $000000C8;
  bmp.Canvas.Pen.Width := 3;
  bmp.Canvas.MoveTo(3, 3);
  bmp.Canvas.LineTo(13, 13);
  bmp.Canvas.MoveTo(13, 3);
  bmp.Canvas.LineTo(3, 13);
  AddBmp;
  NewBmp;
  bmp.Canvas.Brush.Color := $00C00000;
  bmp.Canvas.Pen.Color := $00800000;
  bmp.Canvas.Rectangle(2, 2, 14, 14);
  bmp.Canvas.Brush.Color := clWhite;
  bmp.Canvas.Rectangle(5, 2, 11, 6);
  bmp.Canvas.Brush.Color := $00800000;
  bmp.Canvas.Rectangle(5, 10, 11, 13);
  AddBmp;
  NewBmp;
  bmp.Canvas.Pen.Color := $0000A000;
  bmp.Canvas.Pen.Width := 3;
  bmp.Canvas.MoveTo(2, 8);
  bmp.Canvas.LineTo(7, 13);
  bmp.Canvas.LineTo(14, 3);
  AddBmp;
  NewBmp;
  bmp.Canvas.Brush.Color := $00808080;
  bmp.Canvas.Pen.Color := $00404040;
  bmp.Canvas.Rectangle(2, 9, 14, 14);
  bmp.Canvas.Pen.Color := $00404040;
  bmp.Canvas.Pen.Width := 2;
  bmp.Canvas.MoveTo(8, 1);
  bmp.Canvas.LineTo(8, 8);
  bmp.Canvas.MoveTo(5, 6);
  bmp.Canvas.LineTo(8, 9);
  bmp.Canvas.MoveTo(11, 6);
  bmp.Canvas.LineTo(8, 9);
  AddBmp;
  NewBmp;
  bmp.Canvas.Pen.Color := $00C00000;
  bmp.Canvas.Pen.Width := 2;
  bmp.Canvas.Ellipse(2, 3, 14, 14);
  bmp.Canvas.Brush.Color := $00C00000;
  bmp.Canvas.Polygon([Point(11, 0), Point(15, 4), Point(9, 4)]);
  AddBmp;
  NewBmp;
  bmp.Canvas.Brush.Color := $0000A000;
  bmp.Canvas.Pen.Color := $00006000;
  bmp.Canvas.Polygon([Point(5, 2), Point(5, 14), Point(13, 8)]);
  AddBmp;
  NewBmp;
  bmp.Canvas.Brush.Color := $00808000;
  bmp.Canvas.Pen.Color := $00404000;
  bmp.Canvas.Rectangle(3, 2, 13, 14);
  bmp.Canvas.Ellipse(3, 1, 13, 5);
  bmp.Canvas.Ellipse(3, 10, 13, 14);
  AddBmp;
  NewBmp;
  bmp.Canvas.Brush.Color := clWhite;
  bmp.Canvas.Pen.Color := $00800000;
  bmp.Canvas.Rectangle(2, 3, 14, 14);
  bmp.Canvas.MoveTo(2, 7);
  bmp.Canvas.LineTo(14, 7);
  bmp.Canvas.MoveTo(7, 3);
  bmp.Canvas.LineTo(7, 14);
  bmp.Canvas.MoveTo(11, 3);
  bmp.Canvas.LineTo(11, 14);
  AddBmp;
end;

// 2026-10-04 (M10): PROFESYONEL DIZ TASARIM SISTEMI.
//
// Onceki hâl her kontrol icin ayri ThemeXxx cagrisi ve icine gomulmus
// sabit renklerden olusuyordu:
//  - yeni bir kontrol eklenince tema KACIRILIYORDI (unutuluyordu),
//  - ayni renk ($00DDDDDD, $001E1E1E, $00444444 ...) yazili olarak
//    TEKRARLANIYORDU; bir yeri degistirmek digerlerini bozuyordu,
//  - "duz" gorunum icin gereken ayar (kenarlik, grid cizgisi, odak
//    rengi, satir yuksekligi, odak halkasi) HICBIR YERDE tanimli
//    degildi; her kontrol kendi halindeydi.
//
// Burada tek bir renk/olcu paleti (UIStyle) tanimlanir ve TUM
// kontroller icin ortak bir yardimci (ApplyTheme) uygulanir. Yeni
// kontrol eklendiginde tek yapilacak: ThemeXxx cagrisina eklemek.

procedure TfrmMain.ApplyTheme;
  procedure ThemeGrid(g: TStringGrid; dark: Boolean);
  // DUZ (flat) grid. NOT: bu LCL surumunde TCustomGrid yalnizca
  // Color / FixedColor / GridLineColor / BorderColor / Flat / Font
  // uyelerini sunuyor; RowHeight, FocusRect, SelectionColor,
  // TitleImages gibi modern ozellikler YOK. Bu yuzden duz gorunum
  // renklerle ve cizgi kalinligiyla saglanir; satir/odak/secim
  // ayarlari gridPrepareCanvas icinden yapilir.
  begin
    g.Color := UIStyle.Surface;
    g.Font.Color := UIStyle.Text;
    g.Font.Name := UIStyle.FontUI;
    g.Font.Size := UIStyle.FontUIHeight;
    g.FixedColor := UIStyle.SurfaceAlt;
    g.GridLineColor := UIStyle.Border;
    g.BorderColor := UIStyle.Border;
    g.DefaultRowHeight := UIStyle.RowH;   // tek yerden satir yuksekligi
    g.Flat := True;
    g.FixedRows := 0;          // baslik satiri kapali -> daha duz
    g.Invalidate;
  end;

  procedure ThemeCombo(c: TComboBox; dark: Boolean);
  begin
    c.Color := UIStyle.Surface;
    c.Font.Color := UIStyle.Text;
    c.Font.Name := UIStyle.FontUI;
    c.Font.Size := UIStyle.FontUIHeight;
  end;

  procedure ThemeEdit(e: TEdit; dark: Boolean);
  // Duz kutu: 1 px cerceve, dolgusuz (varsayilan Win95 kenarligi
  // kaldirilir), ic bosluk okunabilirligi artirilir.
  begin
    e.Color := UIStyle.Surface;
    e.Font.Color := UIStyle.Text;
    e.Font.Name := UIStyle.FontUI;
    e.Font.Size := UIStyle.FontUIHeight;
    e.BorderStyle := bsSingle;
  end;

  procedure ThemeMemo(m: TMemo; dark: Boolean);
  // Kod/SQL/gunluk: her zaman monospace + okunabilir satir araligi.
  begin
    m.Color := UIStyle.Surface;
    m.Font.Color := UIStyle.Text;
    m.Font.Name := UIStyle.FontMono;
    m.Font.Size := UIStyle.FontMonoHeight;
    m.BorderStyle := bsSingle;
  end;

  procedure ThemeCards(dark: Boolean);
  var
    i, j: Integer;
    card: TPanel;
    lb: TLabel;
  begin
    cardsPanel.Color := UIStyle.Surface;
    for i := 0 to cardsPanel.ControlCount - 1 do
      if cardsPanel.Controls[i] is TPanel then
      begin
        card := TPanel(cardsPanel.Controls[i]);
        card.Color := UIStyle.SurfaceAlt;
        card.BevelOuter := bvNone;      // duz: kalkinlik yok
        for j := 0 to card.ControlCount - 1 do
          if card.Controls[j] is TLabel then
          begin
            lb := TLabel(card.Controls[j]);
            lb.Font.Name := UIStyle.FontUI;
            if lb.Font.Size >= 16 then
              lb.Font.Color := UIStyle.Text
            else
              lb.Font.Color := UIStyle.TextMuted;
          end;
      end;
  end;

begin
  // 1) PALETI SEC
  if FDark then UIStyleDark else UIStyleLight;

  // 2) YERLESIK DUVARLAR
  Color := UIStyle.SurfaceAlt;
  Font.Color := UIStyle.Text;
  Font.Name := UIStyle.FontUI;
  Font.Size := UIStyle.FontUIHeight;

  pnlLeft.Color := UIStyle.Surface;
  pnlLeft.Font.Color := UIStyle.Text;
  tvList.Color := UIStyle.Surface;
  tvList.Font.Color := UIStyle.Text;
  tvList.Font.Name := UIStyle.FontUI;
  tvList.Font.Size := UIStyle.FontUIHeight;
  split.Color := UIStyle.Border;

  // Ust banner: duz, vurgusuz. Onceki hâlde koyu lacivert (#0F172A)
  // blogu + mavi serit vardi; bu, koyu temada banner'i diger
  // yuzeylerden AYIRIYORDI ve geri kalan duz tasarimla
  // cakisiyordu. Simdi yuzeyden bir ton koyu, serit=vurgu rengi.
  if Assigned(banner) then
  begin
    banner.Color := UIStyle.SurfaceAlt;
    banner.Font.Color := UIStyle.Text;
  end;
  if Assigned(pnlStripe) then pnlStripe.Color := UIStyle.Accent;
  if Assigned(titleLbl) then
  begin
    titleLbl.Font.Color := UIStyle.Text;
    titleLbl.Font.Name := UIStyle.FontUI;
  end;
  if Assigned(lblBannerSub) then lblBannerSub.Font.Color := UIStyle.TextMuted;
  if Assigned(pnlHR) then pnlHR.Color := UIStyle.Border;

  sb.Color := UIStyle.SurfaceAlt;
  sb.Font.Color := UIStyle.TextMuted;
  lblDBInfo.Font.Color := UIStyle.Text;
  lblPage.Font.Color := UIStyle.Text;
  lblTblData.Font.Color := UIStyle.Text;
  lblTx.Font.Color := UIStyle.Text;
  chkAutoBak.Font.Color := UIStyle.Text;

  // 3) METIN GIRISLERI
  ThemeMemo(meSQL, FDark);
  ThemeMemo(meSchema, FDark);
  ThemeMemo(meLog, FDark);
  ThemeEdit(edFilter, FDark);
  ThemeEdit(edFind, FDark);
  ThemeEdit(edTableName, FDark);
  ThemeEdit(edIdxName, FDark);
  ThemeEdit(searchBox, FDark);
  ThemeCombo(cbSqlTemplates, FDark);
  ThemeCombo(cbHist, FDark);
  ThemeCombo(cbSaved, FDark);
  ThemeCombo(cbPageSize, FDark);
  ThemeCombo(cbSortCol, FDark);
  ThemeCombo(cbSortDir, FDark);
  ThemeCombo(cbIdxCol, FDark);
  ThemeCombo(cbEdit, FDark);
  ThemeGrid(sgDB, FDark);
  ThemeGrid(sgTable, FDark);
  ThemeGrid(sgData, FDark);
  ThemeGrid(sgIdx, FDark);
  ThemeGrid(sgFKOut, FDark);
  ThemeGrid(sgFKIn, FDark);
  ThemeGrid(sgSQLRes, FDark);
  ThemeGrid(sgFind, FDark);
  ThemeCards(FDark);
  miTheme.Checked := FDark;
end;

procedure TfrmMain.LoadTheme;
var
  sl: TStringList;
  p: string;
begin
  FDark := False;
  p := ExtractFilePath(Application.ExeName) + 'tema.txt';
  if not FileExists(p) then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(p);
    FDark := (sl.Count > 0) and (Trim(sl[0]) = '1');
  finally
    sl.Free;
  end;
end;

procedure TfrmMain.SaveTheme;
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    if FDark then
      sl.Add('1')
    else
      sl.Add('0');
    sl.SaveToFile(ExtractFilePath(Application.ExeName) + 'tema.txt');
  finally
    sl.Free;
  end;
end;

procedure TfrmMain.mnuThemeClick(Sender: TObject);
begin
  FDark := not FDark;
  SaveTheme;
  ApplyTheme;
end;

{ ---------------- dil / language (2026-10-14) ---------------- }

procedure TfrmMain.TranslateUI;
var
  i: Integer;
  c: TComponent;
begin
  // Pencere basligi (Self, kendi bileşen listesinde olmadigi icin ayrica).
  Self.Caption := TranslateText(Self.Caption);

  // RTTI ile tum bileşenlerin Caption/Hint/TextHint degerlerini cevir.
  // Kurulum kodu Turkce birakildigi icin bu gecis tum arayuzu aktif dile
  // cevirir; metin sozlukte yoksa aynen kalir (veri/metin guvenli).
  for i := 0 to ComponentCount - 1 do
  begin
    c := Components[i];
    if c = FUILang then Continue;   // dil kutusunun kendi metni cevrilmez
    if IsPublishedProp(c, 'Caption') then
      SetStrProp(c, 'Caption', TranslateText(GetStrProp(c, 'Caption')));
    if IsPublishedProp(c, 'Hint') then
      SetStrProp(c, 'Hint', TranslateText(GetStrProp(c, 'Hint')));
    if IsPublishedProp(c, 'TextHint') then
      SetStrProp(c, 'TextHint', TranslateText(GetStrProp(c, 'TextHint')));
  end;

  // Sol agac: sadece kok dugum ("Veritabanlari") cevrilir; tablo adlari
  // gercek veri oldugu icin karistirilmaz.
  if Assigned(tvList) then
    for i := 0 to tvList.Items.Count - 1 do
      if tvList.Items[i].Level = 0 then
        tvList.Items[i].Text := TranslateText(tvList.Items[i].Text);

  // Durum cubugu panelleri (koleksiyon).
  if Assigned(sb) then
    for i := 0 to sb.Panels.Count - 1 do
      sb.Panels[i].Text := TranslateText(sb.Panels[i].Text);

  // Dinamik uretilen DB bilgi metni aktif dile gore tazelenir.
  if Assigned(lblDBInfo) then
    lblDBInfo.Caption := DBInfoText;

  // Dil kutusu aktif dili gostersin.
  if Assigned(FUILang) then
  begin
    if CurrentLang = langEN then
      FUILang.ItemIndex := 0
    else
      FUILang.ItemIndex := 1;
  end;
end;

procedure TfrmMain.LangChange(Sender: TObject);
begin
  if not Assigned(FUILang) then Exit;
  if FUILang.ItemIndex = 0 then
    CurrentLang := langEN
  else
    CurrentLang := langTR;
  TranslateUI;
  SaveSettings;
end;

{ ---------------- filtre ---------------- }

procedure TfrmMain.btnFilterGoClick(Sender: TObject);
var
  t: string;
begin
  if (not Assigned(FSq)) or (FCurrentTable = '') then Exit;
  t := Trim(edFilter.Text);
  try
    if t <> '' then
      FSq.Exec('SELECT COUNT(*) FROM ' + FCurrentTable + ' WHERE ' + t);
    FWhere := t;
    if cbSortCol.ItemIndex <= 0 then
      FSortCol := ''
    else
      FSortCol := cbSortCol.Text;
    FSortDesc := cbSortDir.ItemIndex = 1;
    FPage := 0;
    ReloadData;
    SetStatus('Filtre uygulandi');
  except
    on E: Exception do
      ShowMessage('Filtre hatasi:' + sLineBreak + E.Message);
  end;
end;

procedure TfrmMain.btnFilterClearClick(Sender: TObject);
begin
  FWhere := '';
  FSortCol := '';
  FSortDesc := False;
  edFilter.Text := '';
  cbSortCol.ItemIndex := 0;
  cbSortDir.ItemIndex := 0;
  FPage := 0;
  ReloadData;
end;

{ ---------------- genel arama ---------------- }

procedure TfrmMain.btnFindClick(Sender: TObject);
begin
  GlobalSearch(Trim(edFind.Text));
end;

procedure TfrmMain.edFindKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    GlobalSearch(Trim(edFind.Text));
    Key := #0;
  end;
end;

procedure TfrmMain.GlobalSearch(const Txt: string);
var
  tables: TStrArray;
  ti, i, j, n: Integer;
  td: TTableDef;
  pks: TStrArray;
  rows: TStrMatrix;
  q: string;
begin
  sgFind.RowCount := 2;
  sgFind.Cells[0,1] := '';
  sgFind.Cells[1,1] := '';
  sgFind.Cells[2,1] := '';
  sgFind.Cells[3,1] := '';
  if (not Assigned(FTb)) or (Txt = '') then Exit;
  q := UpperCase(Txt);
  tables := FTb.TableNames;
  n := 0;
  for ti := 0 to High(tables) do
  begin
    td := FTb.GetTable(tables[ti]);
    FTb.ScanRows(tables[ti], pks, rows);
    for i := 0 to High(pks) do
      for j := 0 to High(rows[i]) do
        if Pos(q, UpperCase(rows[i][j])) > 0 then
        begin
          sgFind.RowCount := n + 2;
          sgFind.Cells[0, n+1] := tables[ti];
          sgFind.Cells[1, n+1] := pks[i];
          if j < Length(td.Cols) then
            sgFind.Cells[2, n+1] := td.Cols[j].Name
          else
            sgFind.Cells[2, n+1] := '?';
          sgFind.Cells[3, n+1] := rows[i][j];
          Inc(n);
          if n >= 1000 then Break;
        end;
    if n >= 1000 then Break;
  end;
  SetStatus('Bulundu: ' + IntToStr(n));
end;

procedure TfrmMain.sgFindDblClick(Sender: TObject);
var
  t: string;
begin
  if sgFind.Row < 1 then Exit;
  t := sgFind.Cells[0, sgFind.Row];
  if t = '' then Exit;
  SelectTable(t);
  pcMain.ActivePage := tsData;
end;

{ ---------------- kayitli sorgular ---------------- }

function TfrmMain.QryPath: string;
begin
  Result := ExtractFilePath(Application.ExeName) + 'sorgular.txt';
end;

procedure TfrmMain.LoadQueries;
var
  n, s: TStringList;
begin
  n := TStringList.Create;
  s := TStringList.Create;
  try
    LoadSavedQueries(QryPath, n, s);
    cbSaved.Items.Assign(n);
    FQrySql.Assign(s);
  finally
    n.Free;
    s.Free;
  end;
end;

procedure TfrmMain.SaveQueries;
begin
  SaveSavedQueries(QryPath, cbSaved.Items, FQrySql);
end;

procedure TfrmMain.btnSaveQryClick(Sender: TObject);
var
  nm: string;
  idx: Integer;
begin
  if Trim(meSQL.Text) = '' then Exit;
  nm := InputBox('Sorgu Kaydet', 'Ad:', '');
  nm := Trim(nm);
  if nm = '' then Exit;
  idx := cbSaved.Items.IndexOf(nm);
  if idx < 0 then
  begin
    cbSaved.Items.Add(nm);
    FQrySql.Add(meSQL.Text);
  end
  else
    FQrySql[idx] := meSQL.Text;
  SaveQueries;
  SetStatus('Sorgu kaydedildi: ' + nm);
end;

procedure TfrmMain.btnDelQryClick(Sender: TObject);
var
  idx: Integer;
begin
  idx := cbSaved.ItemIndex;
  if (idx < 0) or (idx >= FQrySql.Count) then Exit;
  cbSaved.Items.Delete(idx);
  FQrySql.Delete(idx);
  SaveQueries;
end;

procedure TfrmMain.cbSavedChange(Sender: TObject);
var
  idx: Integer;
begin
  idx := cbSaved.ItemIndex;
  if (idx >= 0) and (idx < FQrySql.Count) then
    meSQL.Text := FQrySql[idx];
end;

{ ---------------- CSV + dump ---------------- }

procedure TfrmMain.btnExportCSVClick(Sender: TObject);
var
  sd: TSaveDialog;
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then
  begin
    ShowMessage('Once bir tablo secin.');
    Exit;
  end;
  sd := TSaveDialog.Create(nil);
  try
    sd.InitialDir := FCurrentDBDir;
    sd.FileName := FCurrentTable + '.csv';
    sd.Filter := 'CSV|*.csv';
    if not sd.Execute then Exit;
    try
      TableToCSV(FTb, FCurrentTable, sd.FileName);
      Log('CSV export: ' + sd.FileName);
      ShowMessage('Aktarildi:' + sLineBreak + sd.FileName);
    except
      on E: Exception do
        ShowMessage('CSV hatasi: ' + E.Message);
    end;
  finally
    sd.Free;
  end;
end;

procedure TfrmMain.btnImportCSVClick(Sender: TObject);
var
  od: TOpenDialog;
  hdr: Boolean;
  n: Integer;
begin
  if (not Assigned(FTb)) or (FCurrentTable = '') then
  begin
    ShowMessage('Once bir tablo secin.');
    Exit;
  end;
  od := TOpenDialog.Create(nil);
  try
    od.InitialDir := FCurrentDBDir;
    od.Filter := 'CSV|*.csv';
    if not od.Execute then Exit;
    hdr := MessageDlg('CSV Import', 'Ilk satir baslik mi?',
      mtConfirmation, [mbYes, mbNo], 0) = mrYes;
    try
      n := CSVToTable(FTb, FCurrentTable, od.FileName, hdr);
      Log('CSV import: ' + IntToStr(n) + ' satir');
      ShowMessage(IntToStr(n) + ' satir ice aktarildi.');
      SelectTable(FCurrentTable);
    except
      on E: Exception do
        ShowMessage('CSV hatasi: ' + E.Message);
    end;
  finally
    od.Free;
  end;
end;

procedure TfrmMain.btnDumpSQLClick(Sender: TObject);
var
  sd: TSaveDialog;
begin
  if not Assigned(FTb) then Exit;
  sd := TSaveDialog.Create(nil);
  try
    sd.InitialDir := FCurrentDBDir;
    sd.FileName := 'dokum.sql';
    sd.Filter := 'SQL|*.sql';
    if not sd.Execute then Exit;
    try
      DumpToSQL(FTb, sd.FileName);
      Log('SQL dokum: ' + sd.FileName);
      ShowMessage('Dokum yazildi:' + sLineBreak + sd.FileName);
    except
      on E: Exception do
        ShowMessage('Dokum hatasi: ' + E.Message);
    end;
  finally
    sd.Free;
  end;
end;

procedure TfrmMain.FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if (Key = VK_F5) then
  begin
    if pcMain.ActivePage = tsSQL then
    begin
      ExecuteSQL(meSQL.Text);
      Key := 0;
    end;
  end
  else if (ssCtrl in Shift) and (Key = VK_N) then
  begin
    btnNewDBClick(Self);
    Key := 0;
  end
  else if (ssCtrl in Shift) and (Key = VK_O) then
  begin
    btnOpenDBClick(Self);
    Key := 0;
  end;
end;

end.

end.
