unit VDbFactory;

{ VDB - uygulama giris noktasi (v3 birinci sinif, v2 yalniz goc icin)

  Amac: uygulamalar (yonetim, ornekler, kullanici programlari) motorun SOMUT
  tipini (TVDb) tanimasin. Tek bir cagri ile veritabani acilir:

      VdbOpen('D:\veritabani\db', Be);
      Tb := TVTableDb.CreateBackend(Be);

  Varsayilan davranis V3'tur:
    - dosya yoksa v3 olarak OLUSTURULUR,
    - var olan v3 dosyasi acilir,
    - var olan v2 (VODB) dosyasi REDDEDILIR; cunku v2 artik bakimi yapilan
      motor degil. Goc icin `vdbmig` araci (veya AllowV2=True) kullanilir.

  AllowV2=True yalnizca goc araclarinda kullanilmalidir: o zaman v2 dosyasi
  salt-okunur mantikla acilir ve VdbMigrateToV3'e kaynak olur.

  SAHIPLIK: verilen arayuz motoru SAHIPLENIR. Degiskeni nil yapmak motoru
  kapatir; v2 durumunda TVDb de serbest birakilir. `Be := nil` kapanis ile
  esdegerdir. TVTableDb de arayuzu tutar; Free edilince birakir.

  NEDEN `out` PARAMETRE (olculmus FPC davranisi):
  FPC 3.2.4'te `function ...: IVdbBackend` seklinde arayuz DONDUREN bir
  fonksiyon, sonuca fazladan bir referans birakiyor: `Be := VdbOpen(...)` ve
  ardindan `Be := nil` motoru KAPATMIYOR, dosya kilidi acik kaliyor, ayni
  surecte yeniden acilis "dosya kullanimda" hatasi veriyor. Ayni is `out`
  parametreyle yapildiginda referans tam birakiliyor. Probe (probe5/probe6)
  ile dogrulandi; bu yuzden giris noktalari `out` kullanir.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, VDbBackendApi;

type
  EVdbFactory = class(Exception);

  { Dosyanin gercek bicimi. vdfMissing: dosya yok (olusturulabilir). }
  TVdbFamily = (vdfMissing, vdfV2, vdfV3, vdfUnknown);

const
  { v2 ('VODB') ve v3 ('VDB3') imzalari, little-endian LongWord. }
  VDB_MAGIC_V2 = $42444F56;
  VDB_MAGIC_V3 = $33424456;

{ Yolu .odb dosyasina cozer: dizin verilirse icinde `veritabani.odb` aranir
  (v2 duzeni ve eski uygulamalarla uyum). Bos yol hata verir. }
function VdbResolveFile(const Path: string): string;

{ Dosyanin bicimi (imzadan). Dosya yoksa vdfMissing, taninmazsa vdfUnknown. }
function VdbFamilyOfFile(const Path: string): TVdbFamily;

{ Insan okunur ad: 'v3 (VDB3)', 'v2 (VODB)' ... }
function VdbFamilyName(F: TVdbFamily): string;

{ Veritabani acar. CreateIfMissing ise yoksa v3 olarak olusturur.
  AllowV2=False iken v2 dosyasi EVdbFactory ile reddedilir.
  PoolPages<=0 ise motor varsayilani kullanilir (512 sayfa = 2 MB).
  Sonuc `out`: bkz. yukarida "NEDEN out PARAMETRE". }
procedure VdbOpen(const Path: string; out Be: IVdbBackend;
  CreateIfMissing: Boolean = True; AllowV2: Boolean = False;
  PoolPages: Integer = 0);

{ Kisa yol: VdbOpen(Path, True, False, PoolPages). Yeni uygulamalar bunu
  kullanir; dosya yoksa v3 olusturur, varsa acar. }
procedure VdbOpenOrCreate(const Path: string; out Be: IVdbBackend;
  PoolPages: Integer = 0);

{ v3.2: SALT-OKUNUR acilis (cok okuyucu / tek yazici).
  Dosya PAYLASIMLI kilit ile acilir: ayni anda birden cok okuyucu calisir,
  yazar (tam kilit) okuyucular bitene kadar bekler. Bu oturum HICBIR yazma
  yapmaz (WAL imajlari bellekten okunur, <db>.log acilmaz) ve yazma cagrilari
  acik hata verir. v2 dosyasi bu yoldan ACILMAZ.
  BusyMs: okuyucu icin kayit amacli; paylasimli kilit hemen alinir. }
procedure VdbOpenReadOnly(const Path: string; out Be: IVdbBackend;
  PoolPages: Integer = 0; BusyMs: Integer = 0);

{ v3.2: yazar kilidi bekleme suresi (ms) ile acilis. 0 = bekleme yok.
  Kilit alinamazsa acik "veritabani mesgul" hatasi verilir. }
procedure VdbOpenWithBusyTimeout(const Path: string; out Be: IVdbBackend;
  BusyMs: Integer; CreateIfMissing: Boolean = True; PoolPages: Integer = 0);

{ Sifreli v3 dosyasi acar/olusturur. v2 dosyalari bu yoldan ACILMAZ.
  v3.18: BusyMs — yazar kilidi icin bekleme suresi (cok surecli yazma). }
procedure VdbOpenWithPassword(const Path, Password: string;
  out Be: IVdbBackend; CreateIfMissing: Boolean = True;
  PoolPages: Integer = 0; BusyMs: Integer = VDB_DEF_BUSY_MS);

implementation

uses
  Classes, VDbCore, VDbBackendV2, VDbBackendV3, VDbPageStore;

function VdbResolveFile(const Path: string): string;
var
  p: string;
begin
  p := Trim(Path);
  if p = '' then
    raise EVdbFactory.Create('VdbOpen: dosya yolu bos');
  { Dizin ya da uzantisiz ad -> <dizin>\veritabani.odb (eski uygulama duzeni). }
  if DirectoryExists(p) then
    Exit(IncludeTrailingPathDelimiter(ExpandFileName(p)) + 'veritabani.odb');
  if SameText(ExtractFileExt(p), '.odb') then
    Exit(ExpandFileName(p));
  { Var olmayan uzantisiz yol: dizin kabul et (olusturulacak). }
  Result := IncludeTrailingPathDelimiter(ExpandFileName(p)) + 'veritabani.odb';
end;

function VdbFamilyOfFile(const Path: string): TVdbFamily;
var
  f: TFileStream;
  m: LongWord;
  file_: string;
  n: Integer;
begin
  Result := vdfMissing;
  file_ := VdbResolveFile(Path);
  if not FileExists(file_) then
    Exit;
  try
    f := TFileStream.Create(file_, fmOpenRead or fmShareDenyNone);
  except
    { Okunamayan dosya (baska oturumda acik / erisim yok) bicim olarak
      taninmaz; cagiran VdbOpen ile acmayi denemeli. }
    Exit(vdfUnknown);
  end;
  try
    if f.Size < SizeOf(LongWord) then
      Exit(vdfUnknown);
    n := f.Read(m, SizeOf(m));
    if n <> SizeOf(m) then
      Exit(vdfUnknown);
  finally
    f.Free;
  end;
  case m of
    VDB_MAGIC_V2: Result := vdfV2;
    VDB_MAGIC_V3: Result := vdfV3;
  else
    Result := vdfUnknown;
  end;
end;

function VdbFamilyName(F: TVdbFamily): string;
begin
  case F of
    vdfMissing: Result := 'yok';
    vdfV2: Result := 'v2 (VODB)';
    vdfV3: Result := 'v3 (VDB3)';
  else
    Result := 'bilinmeyen bicim';
  end;
end;

function EffectivePool(PoolPages: Integer): Integer;
begin
  if PoolPages > 0 then
    Result := PoolPages
  else
    Result := VDB_DEF_POOL;
end;

procedure VdbOpen(const Path: string; out Be: IVdbBackend;
  CreateIfMissing: Boolean = True; AllowV2: Boolean = False;
  PoolPages: Integer = 0);
var
  file_, dir: string;
  fam: TVdbFamily;
  kv: TVDb;
  pool: Integer;
begin
  Be := nil;
  file_ := VdbResolveFile(Path);
  dir := ExtractFileDir(file_);
  fam := VdbFamilyOfFile(file_);
  pool := EffectivePool(PoolPages);

  case fam of
    vdfV3:
      begin
        { Var olan dosya: olusturma kapali; motor yalniz acar. }
        Be := TVdbBackendV3.Create(file_, False, pool);
      end;

    vdfV2:
      begin
        if not AllowV2 then
          raise EVdbFactory.CreateFmt(
            'Bu dosya v2 (VODB) biciminde: %s' + sLineBreak +
            'Bu surum v3 kullanir. Tasimak icin:' + sLineBreak +
            '  vdbmig copy "%s" "<yeni>.odb"',
            [file_, dir]);
        kv := TVDb.Create;
        try
          kv.Open(file_);
          Be := TVdbBackendV2.CreateOwned(kv);
        except
          kv.Free;
          raise;
        end;
      end;

    vdfMissing:
      begin
        if not CreateIfMissing then
          raise EVdbFactory.CreateFmt('Veritabani yok: %s', [file_]);
        if dir <> '' then
          ForceDirectories(dir);
        Be := TVdbBackendV3.Create(file_, True, pool);
      end;
  else
    raise EVdbFactory.CreateFmt(
      'Taninmayan dosya bicimi (VDB degil) ya da dosya baska bir oturumda ' +
      'acik: %s', [file_]);
  end;
end;

procedure VdbOpenOrCreate(const Path: string; out Be: IVdbBackend;
  PoolPages: Integer = 0);
begin
  VdbOpen(Path, Be, True, False, PoolPages);
end;

procedure VdbOpenReadOnly(const Path: string; out Be: IVdbBackend;
  PoolPages: Integer; BusyMs: Integer);
var
  file_: string;
  pool: Integer;
begin
  Be := nil;
  file_ := VdbResolveFile(Path);
  { DIKKAT: burada VdbFamilyOfFile KULLANILMAZ. O yardimci bicim kesfi icin
    dosyanin ilk 4 baytini okur; yazar tam aralik kilidi tuttugunda bu okuma
    basarisiz olur ve "Veritabani yok" gibi YANLIS bir teshis uretir.
    Bicim dogrulamasi zaten motorun kendi acilisinda yapilir ve kilit
    hatasi orada ACIK mesajla doner. }
  if not FileExists(file_) then
    raise EVdbFactory.CreateFmt('Veritabani yok: %s', [file_]);
  pool := EffectivePool(PoolPages);
  Be := TVdbBackendV3.CreateReadOnly(file_, pool, BusyMs);
end;

procedure VdbOpenWithBusyTimeout(const Path: string; out Be: IVdbBackend;
  BusyMs: Integer; CreateIfMissing: Boolean; PoolPages: Integer);
var
  file_: string;
  fam: TVdbFamily;
  pool: Integer;
begin
  Be := nil;
  file_ := VdbResolveFile(Path);
  fam := VdbFamilyOfFile(file_);
  if fam = vdfV2 then
    raise EVdbFactory.CreateFmt(
      'Bu dosya v2 (VODB) biciminde: %s', [file_]);
  if (fam = vdfMissing) and (not CreateIfMissing) then
    raise EVdbFactory.CreateFmt('Veritabani yok: %s', [file_]);
  if (fam = vdfMissing) and (ExtractFileDir(file_) <> '') then
    ForceDirectories(ExtractFileDir(file_));
  pool := EffectivePool(PoolPages);
  Be := TVdbBackendV3.Create(file_, fam = vdfMissing, pool, BusyMs);
end;

procedure VdbOpenWithPassword(const Path, Password: string;
  out Be: IVdbBackend; CreateIfMissing: Boolean = True;
  PoolPages: Integer = 0; BusyMs: Integer = VDB_DEF_BUSY_MS);
var
  file_: string;
  fam: TVdbFamily;
  pool: Integer;
begin
  Be := nil;
  file_ := VdbResolveFile(Path);
  fam := VdbFamilyOfFile(file_);
  if fam = vdfV2 then
    raise EVdbFactory.CreateFmt(
      'Sifreli acilis v2 dosyalarinda desteklenmez: %s', [file_]);
  if (fam = vdfMissing) and (not CreateIfMissing) then
    raise EVdbFactory.CreateFmt('Veritabani yok: %s', [file_]);
  if (fam = vdfMissing) and (ExtractFileDir(file_) <> '') then
    ForceDirectories(ExtractFileDir(file_));
  pool := EffectivePool(PoolPages);
  Be := TVdbBackendV3.CreateWithPassword(file_, Password,
    fam = vdfMissing, pool, BusyMs);
end;

end.
