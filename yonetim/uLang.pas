unit uLang;

{ TR: Çok dilli destek birimi (Türkçe / İngilizce)
  EN: Multi-language support unit (Turkish / English)

  Bu birim iki sey sunar:
    1) L(TR, EN)         : anlik ceviri (kod icinde metin uretirken).
    2) TranslateText(S)  : bir arayuz metnini sozlukla cevirir. Bu,
       RTTI ile butun bileşenleri gezen TfrmMain.TranslateUI tarafindan
       kullanilir; boylece mevcut kurulum kodu DEGISMEDEN tum arayuz
       (basliklar, sekmeler, dugmeler, menu, ipuclari) tek seferde
       TR<->EN cevrilir.

  Varsayilan dil: Ingilizce (langEN).

  This unit provides L() for inline text and TranslateText() for the
  dictionary-driven UI translation used by TfrmMain.TranslateUI.
  Default language: English (langEN). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils;

type
  TLanguage = (langTR, langEN);

var
  { TR: Varsayilan dil Ingilizce. / EN: Default language is English. }
  CurrentLang: TLanguage = langEN;

function L(const TR, EN: string): string;
function LangName: string;

{ TR: Verilen metni sozlukle aktif dile cevirir. Bulunamazsa aynen
      birakir. Cift yonlu calisir: EN modunda TR->EN, TR modunda EN->TR.
  EN: Translate text via dictionary to active language. Unmatched text is
      returned unchanged. Bidirectional. }
function TranslateText(const S: string): string;

implementation

var
  FTR, FEN: TStringList;   // eslesmis sozluk / paired dictionary

procedure Pair(const TR, EN: string);
begin
  FTR.Add(TR);
  FEN.Add(EN);
end;

function L(const TR, EN: string): string;
begin
  case CurrentLang of
    langTR: Result := TR;
    langEN: Result := EN;
  else
    Result := EN;
  end;
end;

function LangName: string;
begin
  case CurrentLang of
    langTR: Result := 'Türkçe';
    langEN: Result := 'English';
  else
    Result := 'English';
  end;
end;

function TranslateText(const S: string): string;
var
  i: Integer;
begin
  Result := S;
  if S = '' then Exit;
  if CurrentLang = langEN then
  begin
    i := FTR.IndexOf(S);
    if i >= 0 then Result := FEN[i];
  end
  else
  begin
    i := FEN.IndexOf(S);
    if i >= 0 then Result := FTR[i];
  end;
end;

procedure InitDict;
begin
  FTR := TStringList.Create;
  FEN := TStringList.Create;
  FTR.Sorted := False;
  FEN.Sorted := False;

  { --- pencere / banner / tema --- }
  Pair('VDb Studio — Veritabani Yonetim Merkezi',
       'VDb Studio — Database Management Center');
  Pair('kapali - bir veritabani acin', 'closed - open a database');
  Pair('   ◆  Veritabanlari / Tablolar', '   ◆  Databases / Tables');
  Pair('Koyu Tema', 'Dark Theme');
  Pair('Dil:', 'Language:');
  Pair('Veritabanlari', 'Databases');

  { --- ana araç cubugu --- }
  Pair('  Ac', '  Open');
  Pair('Veritabani Ac (Ctrl+O)', 'Open Database (Ctrl+O)');
  Pair('  Yeni', '  New');
  Pair('Yeni Veritabani (Ctrl+N)', 'New Database (Ctrl+N)');
  Pair('  Yedekle', '  Backup');
  Pair('Yedek Al', 'Backup Now');
  Pair('  Dogrula', '  Verify');
  Pair('Butunluk Dogrula', 'Verify Integrity');
  Pair('VACUUM (Olu Verileri Temizle)', 'VACUUM (Clean Dead Data)');
  Pair('  Yenile', '  Refresh');
  Pair('Listeyi Yenile (F5)', 'Refresh List (F5)');

  { --- arama --- }
  Pair('Tablo ara...', 'Search tables...');

  { --- sekmeler --- }
  Pair('Veritabani', 'Database');
  Pair('Yapi', 'Structure');
  Pair('Veri', 'Data');
  Pair('Indeksler', 'Indexes');
  Pair('Iliskiler', 'Relations');
  Pair('Sema', 'Schema');
  Pair('Bul', 'Find');
  Pair('Araclar', 'Tools');

  { --- Veritabani sekmesi / kartlar --- }
  Pair('Henuz acik veritabani yok. Soldan cift tiklayin veya Ac... kullanin.',
       'No open database yet. Double-click on the left or use Open...');
  Pair('Acilista otomatik yedek al (.onceki)', 'Auto-backup on open (.previous)');
  Pair('TABLO', 'TABLES');
  Pair('SATIR', 'ROWS');
  Pair('BOYUT', 'SIZE');
  Pair('SAGLIK', 'HEALTH');
  Pair('SAGLAM', 'HEALTHY');
  Pair('DIKKAT', 'WARNING');
  Pair('SORUN', 'PROBLEM');

  { --- Yapi sekmesi --- }
  Pair('Yeni Tablo', 'New Table');
  Pair('Tablo Sil', 'Delete Table');
  Pair('Kopyala', 'Copy');
  Pair('Adlandir', 'Rename');
  Pair('Sutun Ekle', 'Add Column');
  Pair('Sutun Sil', 'Delete Column');

  { --- Veri sekmesi --- }
  Pair('Satir Ekle', 'Add Row');
  Pair('Satir Sil', 'Delete Row');
  Pair('  tablo: -', '  table: -');
  Pair('  bos tablo', '  empty table');
  Pair('  Filtre:', '  Filter:');
  Pair('  Sirala:', '  Sort:');
  Pair('Uygula', 'Apply');
  Pair('Temizle', 'Clear');
  Pair('CSV Kaydet', 'Save CSV');
  Pair('Artan', 'Ascending');
  Pair('Azalan', 'Descending');
  Pair('(yok)', '(none)');

  { --- Indeksler sekmesi --- }
  Pair('Index Ekle', 'Add Index');
  Pair('Index Sil', 'Delete Index');
  Pair('virgulle ayir: a,b,c', 'comma separated: a,b,c');

  { --- SQL sekmesi --- }
  Pair('Sorguyu calistir (F5)', 'Run query (F5)');
  Pair('Calistir', 'Run');
  Pair('Dosya Calistir', 'Run File');
  Pair('SQL Kaydet', 'Save SQL');
  Pair('-- SQL Sablonlari --', '-- SQL Templates --');
  Pair('  Hazir', '  Ready');
  Pair('  ✗ Hata: ', '  ✗ Error: ');
  Pair('  TX: kapali', '  TX: closed');
  Pair('  TX: ACIK', '  TX: OPEN');
  Pair('Kaydet', 'Save');
  Pair('Sil', 'Delete');
  Pair('Kopyala (TSV)', 'Copy (TSV)');
  Pair('JSON Kaydet', 'Save JSON');

  { --- Araçlar sekmesi --- }
  Pair('CSV Disari', 'Export CSV');
  Pair('CSV Iceri', 'Import CSV');
  Pair('SQL Dokum', 'SQL Dump');
  Pair('WAL Durum', 'WAL Status');
  Pair('WAL Durum...', 'WAL Status...');
  Pair('WAL Replay (Uygula)', 'WAL Replay (Apply)');
  Pair('Otomatik WAL', 'Auto WAL');
  Pair('Otomatik WAL (write-ahead)', 'Auto WAL (write-ahead)');

  { --- sag tik menusu --- }
  Pair('Tumunu Kopyala (TSV)', 'Copy All (TSV)');
  Pair('CSV Olarak Kaydet...', 'Save as CSV...');
  Pair('JSON Olarak Kaydet...', 'Save as JSON...');
  Pair('CSV Disari Aktar', 'Export CSV As...');
  Pair('Tablo Kopyala', 'Copy Table');

  { --- ana menus --- }
  Pair('Dosya', 'File');
  Pair('Ac...', 'Open...');
  Pair('Cikis', 'Exit');
  Pair('Veritabani Sil', 'Delete Database');
  Pair('Yenile', 'Refresh');
  Pair('Tablo', 'Table');
  Pair('Dogrula', 'Verify');
  Pair('Gerektiginde Sikistir', 'Compact When Needed');
  Pair('Tablo Aciklamasi (DESCRIBE)', 'Table Description (DESCRIBE)');
  Pair('Indeksleri Goster (SHOW INDEXES)', 'Show Indexes (SHOW INDEXES)');
  Pair('Olusturma SQL (SHOW CREATE TABLE)', 'Creation SQL (SHOW CREATE TABLE)');
  Pair('Tum Tablolarin Semasi', 'Schema of All Tables');
  Pair('Gorunum', 'View');
  Pair('Yardim', 'Help');
  Pair('Hakkinda', 'About');

  { --- durum cubugu (statik) --- }
  Pair('Hazir - Veritabani secilmedi', 'Ready - No database selected');
end;

initialization
  InitDict;

finalization
  FreeAndNil(FTR);
  FreeAndNil(FEN);

end.