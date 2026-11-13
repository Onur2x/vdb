unit vdbapi_core;

{ VDb API - DLL ile dis dunyaya acilan katman.
  ---------------------------------------------------------------------------
  AMAC
    Motor (VDbCore / VDbTable / VDbSql) Pascal/FPC ile yazildi. Delphi
    derleyicisi FPC ile uretilmis .ppu dosyalarini BILINCLI olarak
    baglayamaz; bu yuzden tek yol bir DLL'dir.

    Bu birim butun motoru sarar ve TEK bir C ABI (cagri kuralindan
    bagimsiz, tam sayi handle, PAnsiChar metin) sunar.

  TASARIM KURALLARI (ihlal edilmemeli)
    1) HICBIR istisna DLL sinirini gecmez. Her giriÃ…Å¸ noktasi
       try/except ile sarilir; hata kodu + son hata metni doner.
    2) Metinler UTF-8'dir ve NUL ile sonlanir.
    3) Handle'lar 0 degildir; 0 daima hatadir. Bozuk handle bir
       crash degil, hata kodudur (VDB_E_BAD_HANDLE).
    4) Sonuc seti ve metin donduren fonksiyonlar kendi ic tamponuna
       isaret doner. tampon BIR SONRAKI cagriya kadar gecerlidir;
       iki isaret ayni anda KULLANILMAZ (cok is parcacigi icin her
       parcacik kendi sonucunu cagirarak okumalidir).
    5) Hicbir tur serbest birakma yoktur; DLL tarafi kendi bellegini
       kendi yonetir. Cagiran taraf yalniz kendi buffer'ini yonetir.
    6) Ayni veritabani dosyasi ayni anda TEK islem tarafindan
       acilabilir (dosya kilidi). Core_VdbOpen hata kodu doner.

  HATA KODLARI
    VDB_OK                (0)  basari
    VDB_E_GENERAL         (-1) siniflandirilmamis
    VDB_E_BAD_HANDLE      (-2) gecersiz handle
    VDB_E_OPEN            (-3) veritabani acilamadi (dosya kilitli vb.)
    VDB_E_SQL             (-4) SQL hatasi (ayrinti: Core_VdbLastError)
    VDB_E_READONLY        (-5) yazma desteklenmiyor
    VDB_E_BUFFER          (-6) tampon kucuk (gerekli boyut negatif doner)
    VDB_E_RANGE           (-7) indis sinir disi
    VDB_E_ENGINE          (-8) motor hatasi (ayrinti: Core_VdbLastError)
    VDB_E_NOT_FOUND       (-9) anahtar/tablo bulunamadi
    VDB_E_DUPLICATE      (-10) UNIQUE / PK ihlali
    VDB_E_CONSTRAINT     (-11) FK / CHECK / NOT NULL ihlali

  DEGER SEMASI
    Motor degerleri bayt dizisi olarak tutar. Metin degerler UTF-8
    olarak yazilir; BLOB ise ham bayt. Core_VdbPut hem metin hem BLOB
    kabul eder (null isaretci + 0 uzunluk = bos deger).
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, VDbCore, VDbTable, VDbSql, VDbErr,
  VDbCdc, VDbTimeTravel, VDbParallel;

const
  { ABI surumu: major.minor (patch).
    Kural: geriye uyumlu eklemelerde minor artar. Major degisirse
    cagiran taraf uyumsuzlugu fark eder. }
  VDB_API_VERSION = $00010200;   // 1.2 (1.1 + paralel havuz yonetimi)

  VDB_OK              =  0;
  VDB_E_GENERAL       = -1;
  VDB_E_BAD_HANDLE    = -2;
  VDB_E_OPEN          = -3;
  VDB_E_SQL           = -4;
  VDB_E_READONLY      = -5;
  VDB_E_BUFFER        = -6;
  VDB_E_RANGE         = -7;
  VDB_E_ENGINE        = -8;
  VDB_E_NOT_FOUND     = -9;
  VDB_E_DUPLICATE    = -10;
  VDB_E_CONSTRAINT   = -11;

  { Bayraklar }
  VDB_SQL_AUTOTXN     = $0001;  // cok cumlede otomatik transaction

type
  { Bir acik veritabani. Handle bunun indeksi. }
  TVDbApiDb = class
  public
    Kv: TVDb;
    Tb: TVTableDb;
    Sq: TVSql;
    SyncWrite: Boolean;
    { CDC (2026-10-06, poll modu): VdbCdcStart olusturur; VdbClose'da
      (CloseAll) ilk o serbest birakilir (parcacik Tb'ye bakar). }
    Cdc: TVDbCdc;
    constructor Create(const APath: string; ASyncWrite: Boolean);
    destructor Destroy; override;
    procedure CloseAll;
  end;

  { Bir SQL sonuc seti. Handle bunun indeksi. }
  TVDbApiResult = class
  public
    R: TSqlResult;
    Buf: AnsiString;          // metin donduren son cagirmalar icin
    constructor Create(const AR: TSqlResult);
    function FieldName(AIndex: Integer): PAnsiChar;
    function FieldCount: Integer;
    function RowCount: Integer;
    function Value(ARow, ACol: Integer): PAnsiChar;
  end;

var
  { Son hata metni (UTF-8, NUL sonlu). Kalan sure boyunca gecerli. }
  VdbLastErrorMsg: AnsiString;
  { Son hatanin VDB_E_* kodu. }
  VdbLastErrorCode: Integer;

function VdbErrorCodeToApi(AErr: TVDbErrorCode): Integer;

{ ABI IMZALARI (ayrica vdbapi_core.cdecl'de tekrar ediliyor)
  Bu bildirimler vdbapi.lpr sarmalayicilarinin derlenebilmesi icin
  gereklidir: kutuphane dosyasi implementation'daki gercek
  uygulamalari GOREMEZ, yalnizca ARAYUZDEKI imzalari cagirabilir.
  Buradaki liste ile vdbapi.h / vdbapitest.lpr ayni olmak ZORUNDADIR. }
function Core_VdbApiVersion: LongWord; stdcall;
function Core_VdbVersion: PAnsiChar; stdcall;
function Core_VdbLastError: PAnsiChar; stdcall;
function Core_VdbLastErrorCodeGet: LongInt; stdcall;
procedure Core_VdbSetLastErrorCode(AErr: LongInt); stdcall;
function Core_VdbOpen(APath: PAnsiChar; ASyncWrite: LongInt): LongWord; stdcall;
procedure Core_VdbClose(AHandle: LongWord); stdcall;
procedure Core_VdbCloseAll; stdcall;
function Core_VdbCount(AHandle: LongWord): LongInt; stdcall;
function Core_VdbPut(AHandle: LongWord; AKey: Int64; AData: PByte; ALen: LongInt): LongInt; stdcall;
function Core_VdbGet(AHandle: LongWord; AKey: Int64; AData: PByte; ALen: LongInt): LongInt; stdcall;
function Core_VdbExists(AHandle: LongWord; AKey: Int64): LongInt; stdcall;
function Core_VdbDelete(AHandle: LongWord; AKey: Int64): LongInt; stdcall;
function Core_VdbKeys(AHandle: LongWord; AOut: PInt64; AMax: LongInt): LongInt; stdcall;
procedure Core_VdbFlush(AHandle: LongWord); stdcall;
function Core_VdbExec(AHandle: LongWord; ASql: PAnsiChar; AFlags: LongInt): LongWord; stdcall;
function Core_VdbResultFieldCount(AHandle: LongWord): LongInt; stdcall;
function Core_VdbResultRowCount(AHandle: LongWord): LongInt; stdcall;
function Core_VdbResultFieldName(AHandle: LongWord; ACol: LongInt): PAnsiChar; stdcall;
function Core_VdbResultValue(AHandle: LongWord; ARow, ACol: LongInt): PAnsiChar; stdcall;
function Core_VdbResultAffected(AHandle: LongWord): LongInt; stdcall;
function Core_VdbResultStmts(AHandle: LongWord): LongInt; stdcall;
function Core_VdbResultMessage(AHandle: LongWord): PAnsiChar; stdcall;
function Core_VdbResultLastTable(AHandle: LongWord): PAnsiChar; stdcall;
procedure Core_VdbResultFree(AHandle: LongWord); stdcall;
function Core_VdbVerify(AHandle: LongWord; AReport: PAnsiChar; AMax: LongInt): LongInt; stdcall;
function Core_VdbWalHas(AHandle: LongWord): LongInt; stdcall;
function Core_VdbWalRecordCount(AHandle: LongWord): LongInt; stdcall;
function Core_VdbWalWrite(AHandle: LongWord; AKey: Int64; AData: PByte; ALen: LongInt): LongInt; stdcall;
function Core_VdbWalWriteDelete(AHandle: LongWord; AKey: Int64): LongInt; stdcall;
function Core_VdbWalReplay(AHandle: LongWord): LongInt; stdcall;
function Core_VdbWalCheckpoint(AHandle: LongWord): LongInt; stdcall;
function Core_VdbWalSetAuto(AHandle: LongWord; AEnable: LongInt): LongInt; stdcall;
function Core_VdbWalIsAuto(AHandle: LongWord): LongInt; stdcall;
function Core_VdbWalAutoCount(AHandle: LongWord): LongInt; stdcall;
function Core_VdbFileSize(AHandle: LongWord): Int64; stdcall;                                             
function Core_VdbDeadBytes(AHandle: LongWord): Int64; stdcall;                                            
function Core_VdbAutoCompact(AHandle: LongWord; AOld, ANew: PInt64): LongInt; stdcall;                    
function Core_VdbEncryptEnable(AHandle: LongWord; AKey: PByte; ALen: LongInt): LongInt; stdcall;
function Core_VdbEncryptDisable(AHandle: LongWord): LongInt; stdcall;
function Core_VdbEncryptIsEncrypted(AHandle: LongWord): LongInt; stdcall;
function Core_VdbEncryptCreateKeyFile(AHandle: LongWord; APath, APassword: PAnsiChar): LongInt; stdcall;
function Core_VdbEncryptOpenKeyFile(AHandle: LongWord; APath, APassword: PAnsiChar): LongInt; stdcall;
function Core_VdbEncryptKeyPath(AHandle: LongWord; ABuf: PAnsiChar; AMax: LongInt): LongInt; stdcall;
function Core_VdbEncryptFingerprint(AHandle: LongWord; ABuf: PAnsiChar; AMax: LongInt): LongInt; stdcall;
function Core_VdbHasEncryptedRecords(AHandle: LongWord): LongInt; stdcall;
function Core_VdbRekeyWithPassword(AHandle: LongWord; ANewPassword: PAnsiChar): LongInt; stdcall;

{ ---- CDC / Time Travel (2026-10-06, POLL tabanli) -------------------------
  CDC olaylari callback ile degil, istemcinin cekmesiyle verilir:
    1) VdbCdcStart  -> TVDbCdc olusturur + calistirir (otomatik WAL acilir).
    2) yazmalar yapilir; olaylar ~50ms'de bir tampona duser.
    3) VdbCdcPollSize -> onunde duran olayin paket boyutu (0 = olay yok).
       VdbCdcPoll     -> paketi kopyalar VE tampondan tuketir (>0 = boyut,
                         0 = olay yok, VDB_E_BUFFER = tampon kucuk).
    4) VdbCdcStop     -> parcacigi durdurur; tampondaki olaylar KALIR ve
                         drain edilebilir. VdbClose tumunu serbest birakir.
  Paket (UTF-8, NUL'suz, alan ayirici #30 = RS):
    kind #30 seq #30 table #30 pk #30 oldJson #30 newJson
    kind: 0=insert, 1=update, 2=delete; json = kolon degerleri dizisi.
  Zaman damgasi bilerek PAKETTE YOK: UTC epoch ms isteyen istemci
  kendi damgasini eklesin (TCDCEvent.Timestamp DLL sinirinda kaybolur).
  Tek istemci varsayilir (ayni anda iki VdbCdcPoll cagirilmaz).
  VdbValueAt: TVTimeTravel.GetRowAt - WAL'deki SATIR degeri (JSON dizi),
    VdbGet sozlesmesiyle (ALen=0 -> -boyut; -1 = o noktada satir yok). }
function Core_VdbCdcStart(AHandle: LongWord): LongInt; stdcall;
function Core_VdbCdcStop(AHandle: LongWord): LongInt; stdcall;
function Core_VdbCdcPollSize(AHandle: LongWord): LongInt; stdcall;
function Core_VdbCdcPoll(AHandle: LongWord; ABuf: PAnsiChar; ALen: LongInt): LongInt; stdcall;
function Core_VdbCdcStats(AHandle: LongWord; AEvents, ASkipped, APending, ADropped: PInteger): LongInt; stdcall;
function Core_VdbValueAt(AHandle: LongWord; ATable, APk: PAnsiChar; ASeq: LongInt;
  ABuf: PAnsiChar; ALen: LongInt): LongInt; stdcall;
function Core_VdbHistoryCount(AHandle: LongWord): LongInt; stdcall;

{ ---- R-14 Full: Paralel havuz yonetimi (2026-10-13) ---- }
function Core_VdbParallelInit(AMaxWorkers: LongInt): LongInt; stdcall;
function Core_VdbParallelWorkers: LongInt; stdcall;
function Core_VdbParallelShutdown: LongInt; stdcall;

implementation

{ R-23: LazUtils/FileUtil bagimliligi KALDIRILDI. Bu birim artik saf FPC
  RTL'dir; Linux/macOS'ta LazUtils olmadan derlenir. Dosya boyutu icin
  asagidaki VdbFileSizeOf yardimcisi kullanilir. }

const
  { Handle imzasi. Gercek handle'lar bu degerin ustundedir; boylece
    rastgele sayi verilirse crash yerine "bozuk handle" hatasi doner. }
  HANDLE_SIG = $56444200;   // 'VDB'

type
  PHandleEntry = ^THandleEntry;
  THandleEntry = record
    Sig: LongWord;
    Obj: TObject;
  end;

var
  HDb: array of THandleEntry;
  HResult: array of THandleEntry;
  HNext: Integer = 1;
  HLock: TCriticalSection;
  HLockReady: Boolean = False;

{ ---------------------------------------------------------------- yardimci }

procedure EnsureLock;
begin
  if not HLockReady then
  begin
    HLock := TCriticalSection.Create;
    HLockReady := True;
  end;
end;

procedure SetErr(ACode: Integer; const AMsg: string);
begin
  VdbLastErrorCode := ACode;
  if AMsg = '' then
    VdbLastErrorMsg := ''
  else
    VdbLastErrorMsg := UTF8Encode(AMsg);
end;

procedure ClearErr;
begin
  VdbLastErrorCode := VDB_OK;
  VdbLastErrorMsg := '';
end;

{ Motor hatasini ABI koduna cevirir. }
function VdbErrorCodeToApi(AErr: TVDbErrorCode): Integer;
begin
  case AErr of
    ecNone:                 Result := VDB_OK;
    ecDatabaseLocked,
    ecDatabaseNotOpen,
    ecDatabaseNotFound,
    ecDatabaseExists:       Result := VDB_E_OPEN;
    ecTableNotFound,
    ecColumnNotFound,
    ecIndexNotFound:        Result := VDB_E_NOT_FOUND;
    ecTableExists,
    ecColumnExists,
    ecIndexExists:          Result := VDB_E_DUPLICATE;
    ecDuplicatePrimaryKey,
    ecUniqueViolation:      Result := VDB_E_DUPLICATE;
    ecForeignKeyViolation,
    ecCheckViolation,
    ecNotNullViolation:     Result := VDB_E_CONSTRAINT;
    ecSyntaxError,
    ecUnsupported,
    ecInvalidName,
    ecTypeMismatch,
    ecMathError,
    ecInvalidArgument:      Result := VDB_E_SQL;
    ecTransactionState,
    ecInvalidState:         Result := VDB_E_SQL;
    ecLimit,
    ecIOError:              Result := VDB_E_ENGINE;
    else                    Result := VDB_E_GENERAL;
  end;
end;

{ Bir istisya nesnesini ABI hatasina cevirir.
  NOT: `Exception is EVDbException` yazimi derlenmiyor ("Class Of Exception"
  hatasi) cunku SysUtils.Exception bir OZELLIK. Bu yuzden istisya nesnesi
  parametre olarak alinir. }
procedure SetErrFromException(AE: Exception);
var
  E: EVDbException;
begin
  if AE is EVDbException then
  begin
    E := EVDbException(AE);
    SetErr(VdbErrorCodeToApi(E.ErrorCode), E.Message);
  end
  else
    SetErr(VDB_E_GENERAL, AE.ClassName + ': ' + AE.Message);
end;

procedure CatchToApi;
{ NOT: `Exception` yazimi derlenmiyor ("Class Of Exception" hatasi) ve
  SysUtils.Exception bir OZELLIK. Mevcut istisya nesnesine
  ExceptObject (global TObject) ile ulasilir. }
var
  O: TObject;
begin
  O := ExceptObject;
  if O is Exception then
    SetErrFromException(Exception(O))
  else
    SetErr(VDB_E_GENERAL, 'bilinmeyen hata');
end;

{ PAnsiChar -> AnsiString (NUL sonlu) }
function CStrToStr(P: PAnsiChar): string;
begin
  if P = nil then Result := ''
  else Result := AnsiString(P);
end;

function StrToBytes(const S: string): TBytes;
var
  B: RawByteString;
begin
  B := UTF8Encode(S);
  SetLength(Result, Length(B));
  if Length(B) > 0 then Move(B[1], Result[0], Length(B));
end;

{ ------------------------------------------------------- handle yonetimi }

{ Handle kaydi. Iki AYRI tablo vardir (HDb / HResult); karistirilmasin
  diye ayri imzalar kullanilir.
  2026-10-04 HATA DUZELTMESI: once tek `NewHandle` her iki tabloyu da
  yaziyor ve `HResult[i].Sig` degerini 0 birakiyordu. Bu yuzden sonuc
  handle'lari `GetRes` tarafindan taninamiyor, tum `Affected` / kolon /
  satir degerleri 0 donuyordu. Simdiki IKI AYRI kayit fonksiyonu var;
  her tablo YALNIZ kendi girdisini yazar. }
function NewDbHandle(AObj: TObject): LongWord;
begin
  Result := 0;
  if AObj = nil then Exit;
  EnsureLock;
  HLock.Enter;
  try
    if HNext > High(HDb) then
      SetLength(HDb, HNext * 2);
    HDb[HNext].Sig := HANDLE_SIG;
    HDb[HNext].Obj := AObj;
    Result := LongWord(HNext);
    Inc(HNext);
  finally
    HLock.Leave;
  end;
end;

function NewResultHandle(AObj: TObject): LongWord;
begin
  Result := 0;
  if AObj = nil then Exit;
  EnsureLock;
  HLock.Enter;
  try
    if HNext > High(HResult) then
      SetLength(HResult, HNext * 2);
    HResult[HNext].Sig := HANDLE_SIG;
    HResult[HNext].Obj := AObj;
    Result := LongWord(HNext);
    Inc(HNext);
  finally
    HLock.Leave;
  end;
end;

procedure FreeDbHandle(AHandle: LongWord);
var
  O: TObject;
  I: Integer;
begin
  O := nil;
  EnsureLock;
  HLock.Enter;
  try
    I := Integer(AHandle);
    if (I > 0) and (I <= High(HDb)) and (HDb[I].Sig = HANDLE_SIG) then
    begin
      O := HDb[I].Obj;
      HDb[I].Sig := 0;
      HDb[I].Obj := nil;
    end;
  finally
    HLock.Leave;
  end;
  O.Free;   // kilit DISINDA serbest birakma
end;

procedure FreeResultHandle(AHandle: LongWord);
var
  O: TObject;
  I: Integer;
begin
  O := nil;
  EnsureLock;
  HLock.Enter;
  try
    I := Integer(AHandle);
    if (I > 0) and (I <= High(HResult)) and (HResult[I].Sig = HANDLE_SIG) then
    begin
      O := HResult[I].Obj;
      HResult[I].Sig := 0;
      HResult[I].Obj := nil;
    end;
  finally
    HLock.Leave;
  end;
  O.Free;
end;

{ Handle -> nesne. Gecersizse nil. Arayan, hata kodunu kendisi yazar. }
function GetDb(AHandle: LongWord): TVDbApiDb;
var
  I: Integer;
begin
  Result := nil;
  EnsureLock;
  HLock.Enter;
  try
    I := Integer(AHandle);
    if (I > 0) and (I <= High(HDb)) and (HDb[I].Sig = HANDLE_SIG) then
      Result := TVDbApiDb(HDb[I].Obj);
  finally
    HLock.Leave;
  end;
end;

function GetRes(AHandle: LongWord): TVDbApiResult;
var
  I: Integer;
begin
  Result := nil;
  EnsureLock;
  HLock.Enter;
  try
    I := Integer(AHandle);
    if (I > 0) and (I <= High(HResult)) and (HResult[I].Sig = HANDLE_SIG) then
      Result := TVDbApiResult(HResult[I].Obj);
  finally
    HLock.Leave;
  end;
end;

{ ---------------------------------------------------- TVDbApiDb / Result }

constructor TVDbApiDb.Create(const APath: string; ASyncWrite: Boolean);
begin
  inherited Create;
  SyncWrite := ASyncWrite;
  Kv := TVDb.Create;
  Kv.SyncWrite := ASyncWrite;
  Kv.Open(APath);
  Tb := TVTableDb.Create(Kv);
  Tb.Open(ExtractFileDir(Kv.FilePath));
  Sq := TVSql.Create(Tb);
  Sq.AutoTransaction := True;
  Cdc := nil;   // VdbCdcStart olusturur
end;

destructor TVDbApiDb.Destroy;
begin
  CloseAll;
  inherited Destroy;
end;

procedure TVDbApiDb.CloseAll;
begin
  { CDC parcacigi Tb/Kv'ye bakar -> ILK o serbest birakilir (Stop+Free). }
  FreeAndNil(Cdc);
  FreeAndNil(Sq);
  FreeAndNil(Tb);
  FreeAndNil(Kv);
end;

constructor TVDbApiResult.Create(const AR: TSqlResult);
begin
  inherited Create;
  R := AR;
end;

function TVDbApiResult.FieldCount: Integer;
begin
  Result := Length(R.Fields);
end;

function TVDbApiResult.RowCount: Integer;
begin
  Result := Length(R.Rows);
end;

function TVDbApiResult.FieldName(AIndex: Integer): PAnsiChar;
begin
  Buf := '';
  Result := nil;
  if (AIndex < 0) or (AIndex >= Length(R.Fields)) then Exit;
  Buf := UTF8Encode(R.Fields[AIndex]);
  Result := PAnsiChar(Buf);
end;

function TVDbApiResult.Value(ARow, ACol: Integer): PAnsiChar;
var
  Rr: TStrArray;
begin
  Buf := '';
  Result := nil;
  if (ARow < 0) or (ARow >= Length(R.Rows)) then Exit;
  if (ACol < 0) or (ACol >= Length(R.Fields)) then Exit;
  Rr := R.Rows[ARow];
  if ACol >= Length(Rr) then Exit;
  Buf := UTF8Encode(Rr[ACol]);
  Result := PAnsiChar(Buf);
end;

{ ============================================================== IHRACAT ==

  DIKKAT - DLL IHRACATI (FPC):
    FPC bir kutuphanede sembolleri VARSAYILAN OLARAK disa AKTARMAZ.
    Disa aktarilacak fonksiyonlar `exports ... name '...';` ile
    IMPLANTASYON bolumunde bildirilmelidir. Yoksa DLL sorunsuz derlenir,
    yuklenir, ama `GetProcAddress` HICBIR seyi bulamaz.

    Diger denenen bicimler CALISMAZ:
      - `begin end.` sonrasinda `exports Foo, Bar;`  -> sessizce yok sayilir
      - `begin ... exports Foo; end.` icinde          -> derleme hatasi
    Bu yuzden asagidaki liste vdbapi.h ve vdbapitest.lpr ile AYNI olmak
    ZORUNDADIR; biri degisirse digerleri sessizce bozulur.
}


function Core_VdbApiVersion: LongWord; stdcall;
begin
  Result := VDB_API_VERSION;
end;

function Core_VdbVersion: PAnsiChar; stdcall;
begin
  VdbLastErrorMsg := 'vdb ' + IntToStr(VDB_API_VERSION shr 16) + '.' +
    IntToStr(VDB_API_VERSION and $FFFF);
  Result := PAnsiChar(VdbLastErrorMsg);
end;

function Core_VdbLastError: PAnsiChar; stdcall;
begin
  Result := PAnsiChar(VdbLastErrorMsg);
end;

function Core_VdbLastErrorCodeGet: LongInt; stdcall;
begin
  Result := LongInt(VdbLastErrorCode);
end;

procedure Core_VdbSetLastErrorCode(AErr: LongInt); stdcall;
begin
  if (AErr <> 0) and (AErr <> VDB_OK) then
    VdbLastErrorCode := Integer(AErr)
  else
    ClearErr;
end;

{ ---------------------------------------------------------------- ac/kapa }

function Core_VdbOpen(APath: PAnsiChar; ASyncWrite: LongInt): LongWord; stdcall;
{ Sozlesme: Acilis basarisiz oldugunda daima VDB_E_OPEN doner.
  2026-10-04: once butun istisnalar genel eslemeye gidiyordu; yol
  bulunamadi / izin yok / kilitli gibi HEP farkli kodlar (ya da
  VDB_E_GENERAL) donuyordu. Cagirici "acilis basarisiz" durumunu
  VDB_E_OPEN ile yakalayamıyordu. Artik motorun kendi hata kodu
  (varsa) oncelikli, yoksa VDB_E_OPEN; AYRINTI metin olarak korunur. }
var
  D: TVDbApiDb;
  S: string;
begin
  Result := 0;
  ClearErr;
  try
    if APath = nil then
    begin
      SetErr(VDB_E_OPEN, 'yol bos');
      Exit(0);
    end;
    S := CStrToStr(APath);
    D := TVDbApiDb.Create(S, ASyncWrite <> 0);
    Result := NewDbHandle(D);
  except
    CatchToApi;
    // Motor kendi hata kodunu vermisse (kilitli vb.) onu koru.
    if VdbLastErrorCode = VDB_E_GENERAL then
      VdbLastErrorCode := VDB_E_OPEN;
    Result := 0;
  end;
end;

procedure Core_VdbClose(AHandle: LongWord); stdcall;
begin
  ClearErr;
  FreeDbHandle(AHandle);
end;

procedure Core_VdbCloseAll; stdcall;
{ Tum handle'lari kapatir ve NESNELERI GERCEKTEN SERBEST BIRAKIR.
  2026-10-04 HATA DUZELTMESI: once yalniz `CloseAll` cagriliyor ve
  handle yuvasi imzasi temizlenmiyordu; nesneler yasadi. Ayni anda
  bir kayit seti de yasamis oluyordu. DLL `FreeLibrary` ile
  bosaltildiginda yasayan nesneler artik kod bolumune erisemiyor ve
  program sonunda ERISIM IHLALI (access violation) oluyordu.
  Serbest birakma kilit DISINDA yapilir. }
var
  I: Integer;
  L: TList;
begin
  ClearErr;
  EnsureLock;
  L := TList.Create;
  try
    HLock.Enter;
    try
      for I := 1 to High(HDb) do
        if (HDb[I].Sig = HANDLE_SIG) and Assigned(HDb[I].Obj) then
        begin
          L.Add(HDb[I].Obj);
          HDb[I].Sig := 0;
          HDb[I].Obj := nil;
        end;
      for I := 1 to High(HResult) do
        if (HResult[I].Sig = HANDLE_SIG) and Assigned(HResult[I].Obj) then
        begin
          L.Add(HResult[I].Obj);
          HResult[I].Sig := 0;
          HResult[I].Obj := nil;
        end;
    finally
      HLock.Leave;
    end;
    for I := 0 to L.Count - 1 do
      TObject(L[I]).Free;
  finally
    L.Free;
  end;
end;

{ ------------------------------------------------------------- temel KV }

function Core_VdbCount(AHandle: LongWord): LongInt; stdcall;
var
  D: TVDbApiDb;
begin
  Result := 0;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    Result := D.Kv.Count;
  except
    CatchToApi;
    Result := 0;
  end;
end;

function Core_VdbPut(AHandle: LongWord; AKey: Int64; AData: PByte;
  ALen: LongInt): LongInt; stdcall;
var
  D: TVDbApiDb;
  B: TBytes;
begin
  Result := VDB_E_GENERAL;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    if (ALen < 0) or ((ALen > 0) and (AData = nil)) then
    begin
      SetErr(VDB_E_RANGE, 'gecersiz veri tamponu');
      Exit;
    end;
    SetLength(B, ALen);
    if ALen > 0 then Move(AData^, B[0], ALen);
    D.Kv.Put(AKey, B);
    Result := VDB_OK;
  except
    CatchToApi;
  end;
end;

function Core_VdbGet(AHandle: LongWord; AKey: Int64; AData: PByte;
  ALen: LongInt): LongInt; stdcall;
{ DONUS DEGERLERI (cagiran iki asamali kullanim yapar):
    >=0  : kopyalanan bayt sayisi (tamamen kopyalandi)
    <0   : gerekli boyut = -sonuc  -> ALen yetersiz, AData'ya dokunulmadi
    -1   : anahtar YOK

  KURAL: ALen = 0 ise YALNIZ BOYUT SORGULANIR, hicbir bayt yazilmaz.

  2026-10-04 - iki duzeltme (ikisi de gercek hatayi kanitladi):
   1) "AData = nil" ile boyut sorgulama YETERSIZDI. Delphi ve FPC'de
      nil isaretci PByte parametreye geçerken bazen eleniyor ve
      fonksiyon dolu bir tamponla cagrilmis gibi oluyor; boyut
      sorgusu -13 (gereken bayt) donuyor ve cagiran bunu hata saniyor.
      Bu yuzden tetikleyici ARTIK `ALen = 0` (AData'ya bakilmaz).
   2) Bos deger (Length = 0) ile "bulunamadi" (-1) birbirine
      karisiyordu. Artik bos deger MUTLAKA 0 doner. }
var
  D: TVDbApiDb;
  B: TBytes;
  HaveIt: Boolean;
begin
  Result := -1;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  if ALen < 0 then
  begin
    SetErr(VDB_E_RANGE, 'gecersiz tampon boyutu');
    Exit(-1);
  end;
  try
    SetLength(B, 0);
    HaveIt := D.Kv.Get(AKey, B);
    if not HaveIt then
    begin
      Result := -1;            // anahtar yok
      Exit;
    end;
    if ALen = 0 then
    begin
      // yalniz boyut: hicbir bayt yazma
      if Length(B) = 0 then Result := 0
      else Result := -LongInt(Length(B));
      Exit;
    end;
    if Length(B) > ALen then
    begin
      Result := -LongInt(Length(B));   // tampon kucuk
      Exit;
    end;
    if (AData = nil) and (Length(B) > 0) then
    begin
      // guvenlik: tampon yoksa kopyalayamayiz
      Result := -LongInt(Length(B));
      Exit;
    end;
    if Length(B) > 0 then Move(B[0], AData^, Length(B));
    Result := LongInt(Length(B));
  except
    CatchToApi;
    Result := VDB_E_GENERAL;
  end;
end;

function Core_VdbExists(AHandle: LongWord; AKey: Int64): LongInt; stdcall;
var
  D: TVDbApiDb;
begin
  Result := 0;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    if D.Kv.Exists(AKey) then Result := 1 else Result := 0;
  except
    CatchToApi;
    Result := 0;
  end;
end;

function Core_VdbDelete(AHandle: LongWord; AKey: Int64): LongInt; stdcall;
var
  D: TVDbApiDb;
begin
  Result := VDB_E_GENERAL;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    if D.Kv.Delete(AKey) then Result := VDB_OK
    else Result := VDB_E_NOT_FOUND;
  except
    CatchToApi;
  end;
end;

function Core_VdbKeys(AHandle: LongWord; AOut: PInt64; AMax: LongInt): LongInt; stdcall;
var
  D: TVDbApiDb;
  K: TQWordArray;
  I, N: Integer;
begin
  Result := VDB_E_RANGE;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    K := D.Kv.GetAllKeys;
    N := Length(K);
    if AOut = nil then
    begin
      // yalnizca say
      Result := N;
      Exit;
    end;
    if AMax < N then
    begin
      SetErr(VDB_E_BUFFER, 'anahtar sayisi kapasiteyi asiyor');
      Result := VDB_E_BUFFER;
      Exit;
    end;
    for I := 0 to N - 1 do
      AOut[I] := Int64(K[I]);
    Result := N;
  except
    CatchToApi;
    Result := VDB_E_GENERAL;
  end;
end;

procedure Core_VdbFlush(AHandle: LongWord); stdcall;
var
  D: TVDbApiDb;
begin
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    D.Kv.Flush;
  except
    CatchToApi;
  end;
end;

{ ---------------------------------------------------------------- SQL }

function Core_VdbExec(AHandle: LongWord; ASql: PAnsiChar;
  AFlags: LongInt): LongWord; stdcall;
var
  D: TVDbApiDb;
  R: TSqlResult;
  O: TVDbApiResult;
begin
  Result := 0;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  if ASql = nil then
  begin
    SetErr(VDB_E_SQL, 'SQL metni bos');
    Exit;
  end;
  try
    if (AFlags and VDB_SQL_AUTOTXN) <> 0 then
      D.Sq.AutoTransaction := True
    else
      D.Sq.AutoTransaction := False;
    R := D.Sq.Exec(AnsiString(ASql));
    O := TVDbApiResult.Create(R);
    Result := NewResultHandle(O);
  except
    CatchToApi;
    Result := 0;
  end;
end;

{ ------------------------------------------------------------ sonuc seti }

function Core_VdbResultFieldCount(AHandle: LongWord): LongInt; stdcall;
var
  R: TVDbApiResult;
begin
  Result := 0;
  ClearErr;
  R := GetRes(AHandle);
  if R = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz sonuc handle');
    Exit;
  end;
  Result := R.FieldCount;
end;

function Core_VdbResultRowCount(AHandle: LongWord): LongInt; stdcall;
var
  R: TVDbApiResult;
begin
  Result := 0;
  ClearErr;
  R := GetRes(AHandle);
  if R = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz sonuc handle');
    Exit;
  end;
  Result := R.RowCount;
end;

function Core_VdbResultFieldName(AHandle: LongWord; ACol: LongInt): PAnsiChar; stdcall;
var
  R: TVDbApiResult;
begin
  Result := nil;
  ClearErr;
  R := GetRes(AHandle);
  if R = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz sonuc handle');
    Exit;
  end;
  if (ACol < 0) or (ACol >= R.FieldCount) then
  begin
    SetErr(VDB_E_RANGE, 'kolon indeksi disinda');
    Exit;
  end;
  Result := R.FieldName(ACol);
end;

function Core_VdbResultValue(AHandle: LongWord; ARow, ACol: LongInt): PAnsiChar; stdcall;
var
  R: TVDbApiResult;
begin
  Result := nil;
  ClearErr;
  R := GetRes(AHandle);
  if R = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz sonuc handle');
    Exit;
  end;
  if (ARow < 0) or (ARow >= R.RowCount) or (ACol < 0) or
     (ACol >= R.FieldCount) then
  begin
    SetErr(VDB_E_RANGE, 'satir/kolon indeksi disinda');
    Exit;
  end;
  Result := R.Value(ARow, ACol);
end;

function Core_VdbResultAffected(AHandle: LongWord): LongInt; stdcall;
var
  R: TVDbApiResult;
begin
  Result := 0;
  ClearErr;
  R := GetRes(AHandle);
  if R = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz sonuc handle');
    Exit;
  end;
  Result := R.R.Affected;
end;

function Core_VdbResultStmts(AHandle: LongWord): LongInt; stdcall;
var
  R: TVDbApiResult;
begin
  Result := 0;
  ClearErr;
  R := GetRes(AHandle);
  if R = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz sonuc handle');
    Exit;
  end;
  Result := R.R.Stmts;
end;

function Core_VdbResultMessage(AHandle: LongWord): PAnsiChar; stdcall;
var
  R: TVDbApiResult;
begin
  Result := nil;
  ClearErr;
  R := GetRes(AHandle);
  if R = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz sonuc handle');
    Exit;
  end;
  R.Buf := UTF8Encode(R.R.Msg);
  Result := PAnsiChar(R.Buf);
end;

function Core_VdbResultLastTable(AHandle: LongWord): PAnsiChar; stdcall;
var
  R: TVDbApiResult;
begin
  Result := nil;
  ClearErr;
  R := GetRes(AHandle);
  if R = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz sonuc handle');
    Exit;
  end;
  R.Buf := UTF8Encode(R.R.LastTable);
  Result := PAnsiChar(R.Buf);
end;

procedure Core_VdbResultFree(AHandle: LongWord); stdcall;
begin
  ClearErr;
  FreeResultHandle(AHandle);
end;

{ ------------------------------------------------------------- bakim/WAL }

function Core_VdbVerify(AHandle: LongWord; AReport: PAnsiChar; AMax: LongInt): LongInt; stdcall;
var
  D: TVDbApiDb;
  Rep: string;
  S: AnsiString;
begin
  Result := 0;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    if D.Kv.Verify(Rep) then Result := 1 else Result := 0;
    S := UTF8Encode(Rep);
    if AReport <> nil then
    begin
      if Length(S) < AMax then
        StrPCopy(AReport, S)
      else if AMax > 0 then
      begin
        StrPCopy(AReport, Copy(S, 1, AMax - 1));
      end;
    end;
  except
    CatchToApi;
    Result := 0;
  end;
end;

function Core_VdbWalHas(AHandle: LongWord): LongInt; stdcall;
var
  D: TVDbApiDb;
begin
  { Sorgu dondurucu: basarili durumda 1/0. Hata VDB_E_* kodu olmali;
    0 donmek "WAL yok" anlamina gelirdi (sessiz hata). }
  Result := VDB_E_GENERAL;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    if D.Kv.HasWAL then Result := 1 else Result := 0;
  except
    CatchToApi;
  end;
end;

function Core_VdbWalRecordCount(AHandle: LongWord): LongInt; stdcall;
var
  D: TVDbApiDb;
begin
  Result := VDB_E_GENERAL;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    Result := D.Kv.WalRecordCount;
  except
    CatchToApi;
  end;
end;

function Core_VdbWalWrite(AHandle: LongWord; AKey: Int64; AData: PByte;
  ALen: LongInt): LongInt; stdcall;
{ Gunluge PUT kaydi yazar. Kayit ana dosyaya YAZILMAZ; Core_VdbWalReplay
  veya Core_VdbWalCheckpoint cagrilmalidir. }
var
  D: TVDbApiDb;
  B: TBytes;
begin
  Result := VDB_E_GENERAL;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    if (ALen < 0) or ((ALen > 0) and (AData = nil)) then
    begin
      SetErr(VDB_E_RANGE, 'gecersiz veri tamponu');
      Exit;
    end;
    SetLength(B, ALen);
    if ALen > 0 then Move(AData^, B[0], ALen);
    if D.Kv.WriteAheadWAL(QWord(AKey), B, VDB_FLAG_PUT) then
      Result := VDB_OK
    else
      Result := VDB_E_ENGINE;
  except
    CatchToApi;
  end;
end;

function Core_VdbWalWriteDelete(AHandle: LongWord; AKey: Int64): LongInt; stdcall;
var
  D: TVDbApiDb;
begin
  Result := VDB_E_GENERAL;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    if D.Kv.WriteAheadWAL(QWord(AKey), nil, VDB_FLAG_DEL) then
      Result := VDB_OK
    else
      Result := VDB_E_ENGINE;
  except
    CatchToApi;
  end;
end;

function Core_VdbWalReplay(AHandle: LongWord): LongInt; stdcall;
var
  D: TVDbApiDb;
begin
  Result := VDB_E_GENERAL;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    if D.Kv.ReplayWAL then Result := VDB_OK else Result := VDB_E_ENGINE;
  except
    CatchToApi;
  end;
end;

function Core_VdbWalCheckpoint(AHandle: LongWord): LongInt; stdcall;
var
  D: TVDbApiDb;
begin
  Result := VDB_E_GENERAL;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    if D.Kv.CheckpointWAL then Result := VDB_OK else Result := VDB_E_ENGINE;
  except
    CatchToApi;
  end;
end;

function Core_VdbWalSetAuto(AHandle: LongWord; AEnable: LongInt): LongInt; stdcall;
{ OTOMATIK WAL: acikken her Put/Delete once .wal'a sonra ana dosyaya
  yazilir. Kapali (varsayilan) eski davranistir. }
var
  D: TVDbApiDb;
begin
  Result := VDB_E_GENERAL;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    D.Kv.WALEnabled := AEnable <> 0;
    Result := VDB_OK;
  except
    CatchToApi;
  end;
end;

function Core_VdbWalIsAuto(AHandle: LongWord): LongInt; stdcall;
var
  D: TVDbApiDb;
begin
  { Sorgu dondurucu: basarili durumda 1/0 doner. Hata durumunda
    0 donmek "kapali" anlamina gelirdi ve cagiran taraf hatayi
    goremezdi -> bu yuzden once hata kodu ile basliyoruz. }
  Result := VDB_E_GENERAL;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    if D.Kv.WALEnabled then Result := 1 else Result := 0;
  except
    CatchToApi;
  end;
end;

function Core_VdbWalAutoCount(AHandle: LongWord): LongInt; stdcall;
{ Otomatik WAL modunda bu agaza kadar gunluge YAZILAN kayit sayisi.
  Basarili durumda sayac (0 olabilir) doner; hata VDB_E_* kodudur. }
var
  D: TVDbApiDb;
begin
  Result := VDB_E_GENERAL;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    Result := D.Kv.WalAutoCount;
  except
    CatchToApi;
  end;
end;

{ R-23: LazUtils FileUtil.FileSize yerine saf RTL yardimcisi.
  DIKKAT (R-12 Full son tam kosisinda bulunan hata): olcum DOSYA ACMADAN
  yapilmalidir — motor ana dosyayi diger acimlara KAPALI tutar; ikinci
  bir TFileStream acisi paylasim hatasi verir ve VdbFileSizeOf istisnayi
  yakalayip 0 donerdi (VdbFileSize / AutoCompact esik degerleri 0 -> 0).
  FindFirst klasor kaydini okur, acma gerekmez. }
{ R-23: LazUtils FileUtil.FileSize yerine saf RTL yardimcisi.
  DIKKAT (R-12 Full son tam kosisinda bulunan hata): olcum DOSYA ACMADAN
  yapilmalidir — motor ana dosyayi diger acimlara KAPALI tutar; ikinci
  bir TFileStream acisi paylasim hatasi verir ve VdbFileSizeOf istisnayi
  yakalayip 0 donerdi (VdbFileSize / AutoCompact esik degerleri 0 -> 0).
  FindFirst klasor kaydini okur, acma gerekmez. }
function VdbFileSizeOf(const APath: string): Int64;
var
  Sr: TSearchRec;
begin
  Result := 0;
  if APath = '' then Exit;
  if FindFirst(APath, faAnyFile, Sr) = 0 then
  try
    Result := Sr.Size;
  finally
    FindClose(Sr);
  end;
end;

function Core_VdbFileSize(AHandle: LongWord): Int64; stdcall;
var
  D: TVDbApiDb;
begin
  Result := 0;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    Result := VdbFileSizeOf(D.Kv.FilePath);
  except
    CatchToApi;
    Result := 0;
  end;
end;

function Core_VdbDeadBytes(AHandle: LongWord): Int64; stdcall;
var
  D: TVDbApiDb;
begin
  Result := 0;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    Result := D.Kv.DeadBytes;
  except
    CatchToApi;
    Result := 0;
  end;
end;

function Core_VdbAutoCompact(AHandle: LongWord; AOld, ANew: PInt64): LongInt; stdcall;
{ 2026-10-04: Motor, sikistirma GEREKMEDIGINDE AOld/ANeyi DOLDURMUYOR
  (cagiran bunlarin sifir kaldigini gorur). ABI'de bu belirsizlik
  kabul edilmedi: degerler her zaman mevcut dosya boyutuna cekilir,
  sonra motorun verdikleri (varsa) onun uzerine yazilir. }
var
  D: TVDbApiDb;
  O, N: Int64;
begin
  Result := 0;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    O := VdbFileSizeOf(D.Kv.FilePath);
    N := O;
    if D.Kv.AutoCompact(O, N) then
    begin
      Result := 1;
      // Motorun degerleri GE CERLI (dosya gercekten degisti).
    end
    else
    begin
      // Sikistirma YAPILMADI. Motor bazi durumlarda O/N'i 0'a
      // dusuruyor; o zaman "dosya degismedi" anlamina gelen mevcut
      // boyutu bildiriyoruz, aksi halde cagiran "0 -> 0" gorur ve
      // dosyanin bosaldigini sanir.
      Result := 0;
      O := VdbFileSizeOf(D.Kv.FilePath);
      N := O;
    end;
    if AOld <> nil then AOld^ := O;
    if ANew <> nil then ANew^ := N;
  except
    CatchToApi;
    Result := 0;
  end;
end;

function Core_VdbEncryptEnable(AHandle: LongWord; AKey: PByte; ALen: LongInt): LongInt; stdcall;
var
  D: TVDbApiDb;
  K: TBytes;
begin
  Result := 0;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then begin SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle'); Exit; end;
  try
    SetLength(K, ALen);
    if (ALen > 0) and (AKey <> nil) then
      Move(AKey^, K[0], ALen);
    D.Kv.SetEncryptionKey(K);
    Result := 1;
  except CatchToApi; Result := 0; end;
end;

function Core_VdbEncryptDisable(AHandle: LongWord): LongInt; stdcall;
var D: TVDbApiDb;
begin
  Result := 0; ClearErr;
  D := GetDb(AHandle);
  if D = nil then begin SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle'); Exit; end;
  try D.Kv.ClearEncryptionKey; Result := 1; except CatchToApi; Result := 0; end;
end;

function Core_VdbEncryptIsEncrypted(AHandle: LongWord): LongInt; stdcall;
var D: TVDbApiDb;
begin
  Result := 0; ClearErr;
  D := GetDb(AHandle);
  if D = nil then begin SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle'); Exit; end;
  try Result := Ord(D.Kv.IsEncrypted); except CatchToApi; Result := 0; end;
end;

function Core_VdbEncryptCreateKeyFile(AHandle: LongWord; APath, APassword: PAnsiChar): LongInt; stdcall;
var D: TVDbApiDb;
begin
  Result := 0; ClearErr;
  D := GetDb(AHandle);
  if D = nil then begin SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle'); Exit; end;
  try Result := Ord(D.Kv.CreateKeyFile(string(APath), string(APassword))); except CatchToApi; Result := 0; end;
end;

function Core_VdbEncryptOpenKeyFile(AHandle: LongWord; APath, APassword: PAnsiChar): LongInt; stdcall;
var D: TVDbApiDb;
begin
  Result := 0; ClearErr;
  D := GetDb(AHandle);
  if D = nil then begin SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle'); Exit; end;
  try Result := Ord(D.Kv.OpenKeyFile(string(APath), string(APassword))); except CatchToApi; Result := 0; end;
end;

function Core_VdbEncryptKeyPath(AHandle: LongWord; ABuf: PAnsiChar; AMax: LongInt): LongInt; stdcall;
var D: TVDbApiDb; S: string;
begin
  Result := 0; ClearErr;
  D := GetDb(AHandle);
  if D = nil then begin SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle'); Exit; end;
  S := D.Kv.KeyPath;
  if Length(S) + 1 > AMax then begin Result := -(Length(S) + 1); Exit; end;
  Move(S[1], ABuf^, Length(S));
  Inc(PByte(ABuf), Length(S)); ABuf^ := #0;
  Result := Length(S);
end;

function Core_VdbEncryptFingerprint(AHandle: LongWord; ABuf: PAnsiChar; AMax: LongInt): LongInt; stdcall;
var D: TVDbApiDb; S: string;
begin
  Result := 0; ClearErr;
  D := GetDb(AHandle);
  if D = nil then begin SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle'); Exit; end;
  S := D.Kv.EncryptionKeyFingerprint;
  if Length(S) + 1 > AMax then begin Result := -(Length(S) + 1); Exit; end;
  Move(S[1], ABuf^, Length(S));
  Inc(PByte(ABuf), Length(S)); ABuf^ := #0;
  Result := Length(S);
end;

function Core_VdbHasEncryptedRecords(AHandle: LongWord): LongInt; stdcall;
var D: TVDbApiDb;
begin
  Result := 0; ClearErr;
  D := GetDb(AHandle);
  if D = nil then begin SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle'); Exit; end;
  try Result := Ord(D.Kv.HasEncryptedRecords); except CatchToApi; Result := 0; end;
end;

function Core_VdbRekeyWithPassword(AHandle: LongWord; ANewPassword: PAnsiChar): LongInt; stdcall;
var D: TVDbApiDb;
begin
  Result := 0; ClearErr;
  D := GetDb(AHandle);
  if D = nil then begin SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle'); Exit; end;
  try D.Kv.RekeyWithPassword(string(ANewPassword)); Result := 1; except CatchToApi; Result := 0; end;
end;

{ ------------------------------------------------- CDC / Time Travel (poll) }

function JsonEscStr(const S: string): UTF8String;
{ Bir metni JSON string olarak kodlar (UTF-8 baytlari korunur; kontrol
  karakterleri \u00XX; " ve \ kacisli. Cikti tirnak DAHILdir. }
var
  b: UTF8String;
  i: Integer;
  c: Byte;
begin
  b := UTF8Encode(S);
  Result := '"';
  for i := 1 to Length(b) do
  begin
    c := Byte(b[i]);
    case c of
      34: Result := Result + '\"';
      92: Result := Result + '\\';
       8: Result := Result + '\b';
       9: Result := Result + '\t';
      10: Result := Result + '\n';
      12: Result := Result + '\f';
      13: Result := Result + '\r';
    else
      if c < 32 then Result := Result + UTF8String('\u00' + IntToHex(c, 2))
      else Result := Result + UTF8String(Char(c));
    end;
  end;
  Result := Result + '"';
end;

function JsonArr(const Vals: TStrArray): UTF8String;
{ Kolon degerlerini JSON dizisi olarak: ["a","b",...] }
var
  i: Integer;
begin
  Result := '[';
  for i := 0 to High(Vals) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + JsonEscStr(Vals[i]);
  end;
  Result := Result + ']';
end;

function PackCdcEvent(const E: TCDCEvent): UTF8String;
{ Olay paketi (UTF-8, NUL'suz, alan ayirici #30 = RS):
    kind #30 seq #30 table #30 pk #30 oldJson #30 newJson
  kind: 0=insert, 1=update, 2=delete (TCDCEventType sirasi). }
begin
  Result := UTF8String(IntToStr(Ord(E.EventType))) + #30 +
            UTF8String(IntToStr(Int64(E.Seq))) + #30 +
            UTF8Encode(E.TableName) + #30 +
            UTF8Encode(E.PK) + #30 +
            JsonArr(E.OldValues) + #30 +
            JsonArr(E.NewValues);
end;

function CopyOutBuf(const S: UTF8String; ABuf: PAnsiChar; ALen: LongInt): LongInt;
{ VdbGet sozlesmesi: ALen=0 -> yalniz boyut (-n); ALen yetersiz -> -n ve
  tampona DOKUNULMAZ; yeterli -> kopyalanan bayt sayisi (n >= 0). }
var
  n: Integer;
begin
  n := Length(S);
  if (ALen <= 0) or (ABuf = nil) then begin Result := -n; Exit; end;
  if ALen < n then begin Result := -n; Exit; end;
  if n > 0 then Move(S[1], ABuf^, n);
  Result := n;
end;

function Core_VdbCdcStart(AHandle: LongWord): LongInt; stdcall;
var
  D: TVDbApiDb;
begin
  Result := VDB_OK;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Result := VDB_E_BAD_HANDLE;
    Exit;
  end;
  try
    if D.Cdc = nil then
      D.Cdc := TVDbCdc.Create(D.Tb);
    D.Cdc.OnChange := nil;   { POLL modu: callback YOK, olaylar tamponda }
    D.Cdc.Start;             { otomatik WAL'i da ACAR }
  except
    CatchToApi;
    Result := VDB_E_GENERAL;
  end;
end;

function Core_VdbCdcStop(AHandle: LongWord): LongInt; stdcall;
var
  D: TVDbApiDb;
begin
  Result := VDB_OK;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Result := VDB_E_BAD_HANDLE;
    Exit;
  end;
  if D.Cdc = nil then
  begin
    SetErr(VDB_E_ENGINE, 'CDC baslatilmadi (once VdbCdcStart)');
    Result := VDB_E_ENGINE;
    Exit;
  end;
  try
    { parcacigi durdurur; kalan WAL kayitlarini isler ve tamponu
      DOLDURUR. Tampon bosalmaz: istemci VdbCdcPoll ile drain edebilir. }
    D.Cdc.Stop;
  except
    CatchToApi;
    Result := VDB_E_GENERAL;
  end;
end;

function Core_VdbCdcPollSize(AHandle: LongWord): LongInt; stdcall;
{ Onunde duran olayin paket boyutu (tuketmez): >0 = boyut, 0 = olay yok,
  <0 = hata kodu (VDB_E_*). }
var
  D: TVDbApiDb;
  ev: TCDCEvent;
begin
  Result := 0;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Result := VDB_E_BAD_HANDLE;
    Exit;
  end;
  if D.Cdc = nil then
  begin
    SetErr(VDB_E_ENGINE, 'CDC baslatilmadi (once VdbCdcStart)');
    Result := VDB_E_ENGINE;
    Exit;
  end;
  try
    if D.Cdc.TryPeek(ev) then
      Result := Length(PackCdcEvent(ev));
  except
    CatchToApi;
    Result := VDB_E_GENERAL;
  end;
end;

function Core_VdbCdcPoll(AHandle: LongWord; ABuf: PAnsiChar; ALen: LongInt): LongInt; stdcall;
{ Onundeki olayi paketleyip kopyalar VE tampondan tuketir.
  Donus: >0 kopyalanan boyut (olay tukendi), 0 olay yok,
  VDB_E_BUFFER tampon kucuk (olay TAMponda KALIR; boyut VdbCdcPollSize),
  diger negatif = hata kodu. Tek istemci varsayilir. }
var
  D: TVDbApiDb;
  ev: TCDCEvent;
  pkt: UTF8String;
begin
  Result := 0;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Result := VDB_E_BAD_HANDLE;
    Exit;
  end;
  if D.Cdc = nil then
  begin
    SetErr(VDB_E_ENGINE, 'CDC baslatilmadi (once VdbCdcStart)');
    Result := VDB_E_ENGINE;
    Exit;
  end;
  try
    if not D.Cdc.TryPeek(ev) then Exit;    // 0 = olay yok
    pkt := PackCdcEvent(ev);
    if (ABuf = nil) or (ALen < Length(pkt)) then
    begin
      SetErr(VDB_E_BUFFER,
        'tampon kucuk: gerekli=' + IntToStr(Length(pkt)));
      Result := VDB_E_BUFFER;
      Exit;                                // olay tuketilmez
    end;
    if Length(pkt) > 0 then
      Move(pkt[1], ABuf^, Length(pkt));
    D.Cdc.TryDequeue(ev);                  // yalnizca BASARILI kopyada tuket
    Result := Length(pkt);
  except
    CatchToApi;
    Result := VDB_E_GENERAL;
  end;
end;

function Core_VdbCdcStats(AHandle: LongWord; AEvents, ASkipped, APending,
  ADropped: PInteger): LongInt; stdcall;
{ Tanilama sayaclari (hepsi istemcinin tamponunu gunceller; nil olabilir):
    AEvents  = uretilen toplam olay (WAL'den cozulen satir degisiklikleri)
    ASkipped = atlanan WAL kaydi (sema kaydi, bilinmeyen tablo, degeri
               olmayan silme kaydi)
    APending = tampondaki bekleyen olay (henuz cekilmemis)
    ADropped = tampon siniri asilirsa DUSURELEN olay (poll gecikirse) }
var
  D: TVDbApiDb;
begin
  Result := VDB_OK;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Result := VDB_E_BAD_HANDLE;
    Exit;
  end;
  if D.Cdc = nil then
  begin
    SetErr(VDB_E_ENGINE, 'CDC baslatilmadi (once VdbCdcStart)');
    Result := VDB_E_ENGINE;
    Exit;
  end;
  try
    if AEvents  <> nil then AEvents^  := D.Cdc.EventCount;
    if ASkipped <> nil then ASkipped^ := D.Cdc.SkippedCount;
    if APending <> nil then APending^ := D.Cdc.PendingCount;
    if ADropped <> nil then ADropped^ := D.Cdc.DroppedCount;
  except
    CatchToApi;
    Result := VDB_E_GENERAL;
  end;
end;

function Core_VdbValueAt(AHandle: LongWord; ATable, APk: PAnsiChar; ASeq: LongInt;
  ABuf: PAnsiChar; ALen: LongInt): LongInt; stdcall;
{ TVTimeTravel.GetRowAt: WAL gecmisinde ASeq'ye (WAL kayit indeksi, 0
  tabanli; n dahil) kadar satirin SON degeri, JSON dizisi olarak.
  VdbGet sozlesmesi: ALen=0 -> yalniz boyut (-n); yetersiz -> -n;
  yeterli -> kopyalanan boyut; o noktada satir YOK (silinmis/hic
  yazilmamis) -> -1. Hata ayrintisi VdbErrCode()/VdbLastError.
  ASeq sinir tasan degerdir (n >= WalRecordCount -> son kayit).
  TVTimeTravel turevi bir nesne GETIRMEZ (DLL icinde olusturup kapatir). }
var
  D: TVDbApiDb;
  tt: TVTimeTravel;
  vals: TStrArray;
  js: UTF8String;
begin
  Result := -1;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  if (ATable = nil) or (APk = nil) then
  begin
    SetErr(VDB_E_GENERAL, 'tablo/pk nil olamaz');
    Exit;
  end;
  try
    tt := TVTimeTravel.Create(D.Tb);
    try
      if not tt.GetRowAt(CStrToStr(ATable), CStrToStr(APk), QWord(ASeq), vals) then
        Exit;                              // -1: o noktada satir yok
      js := JsonArr(vals);
      Result := CopyOutBuf(js, ABuf, ALen);
    finally
      tt.Free;
    end;
  except
    CatchToApi;
    Result := -1;
  end;
end;

function Core_VdbHistoryCount(AHandle: LongWord): LongInt; stdcall;
{ Okunabilir WAL gecmis kayit sayisi = TVTimeTravel.HistoryCount.
  >=0 basari; <0 hata kodu. Gecmis checkpoint ile SILINEBILIR
  (0 doner) - "tarihin tamami" degildir. }
var
  D: TVDbApiDb;
begin
  Result := VDB_E_GENERAL;
  ClearErr;
  D := GetDb(AHandle);
  if D = nil then
  begin
    SetErr(VDB_E_BAD_HANDLE, 'gecersiz veritabani handle');
    Exit;
  end;
  try
    Result := D.Kv.WalRecordCount;
  except
    CatchToApi;
  end;
end;

{ ---- R-14 Full: Paralel havuz yonetimi (2026-10-13) -----------------------
  Motor, buyuk ORDER BY siralamalarini isci havuzuna dagitir. Havuz
  istenirse acikca yonetilebilir:
    VdbParallelInit(n)    -> havuzu n isciyle acar (n<=0: otomatik sayi),
                             donus = acilan isci sayisi (0 = basarisiz).
    VdbParallelWorkers()  -> gecerli isci sayisi (0 = havuz kapali).
    VdbParallelShutdown() -> havuzu kapatir, donus = kapatilan isci sayisi.
  Not: havuz kapaliyken bile buyuk siralama kendiliginden acilir
  (lazy init). Sifir isci istemek mumkun degildir: seri yurutme
  isteyen istemci kucuk esik alti sorgularla (ya da havuzu kapatarak
  ve tekrar acmayarak) zaten seri kalmaz; esik alti kumeler daima seri. }
function Core_VdbParallelInit(AMaxWorkers: LongInt): LongInt; stdcall;
begin
  Result := 0;
  ClearErr;
  try
    if not InitThreadPool(AMaxWorkers) then
    begin
      SetErr(VDB_E_GENERAL, 'paralel havuz acilamadi');
      Exit;
    end;
    Result := ParallelWorkerCount;
  except
    CatchToApi;
  end;
end;

function Core_VdbParallelWorkers: LongInt; stdcall;
begin
  ClearErr;
  if ThreadPoolReady then
    Result := ParallelWorkerCount
  else
    Result := 0;
end;

function Core_VdbParallelShutdown: LongInt; stdcall;
var
  Prev: LongInt;
begin
  Result := 0;
  ClearErr;
  try
    if ThreadPoolReady then Prev := ParallelWorkerCount
    else Prev := 0;
    ShutdownThreadPool;
    Result := Prev;
  except
    CatchToApi;
  end;
end;

{ DLL ihracat listesi vdbapi.lpr dosyasindadir: FPC yalnizca
{ kutuphanenin kendi dosyasindaki sembolleri export edebilir. }
end.
