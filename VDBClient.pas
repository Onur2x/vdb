unit VDbClient;

{ VDb Engine - Delphi/Pascal ISTEMCI BIRIMI
  ---------------------------------------------------------------------------
  Bu birim motorun KODUNU icermez; yalniz `vdbapi.dll` dosyasindaki
  disa aktarilmis fonksiyonlari baglar. Amaci: senin Delphi
  programinda motoru tek satirlik cagrilarla kullanabilmen.

  DELPHI'DE NASIL KULLANILIR
    1) Bu dosyayi projenin klasorune kopyala.
    2) `uses VDbClient;` ekle.
    3) `vdbapi.dll` dosyasi programinin yaninda (veya PATH'te) OLMALI.
       (Project > Options > Runtime Packages yerine dosyayi proje
        klasorune koymak en saglam yol.)

  DIKKAT
    * Bu birim Delphi'nin KENDI derleyicisiyle yazilmistir ve
      motor birimlerine BAGLANMAZ. FPC/Lazarus ile derlenmis .ppu
      dosyalarini Delphi baglayamaz; bu yuzden DLL kullanimi zorunlu.
    * DLL 32-bit (x86) olarak derlenmistir. Delphi projen de x86
      olmalidir (Platform = Win32).

  ORNEK
    var
      Db: TVDb;
    begin
      Db := TVDb.Open('C:\veriler\veritabani.odb');
      try
        Db.SQL('CREATE TABLE kisi (id INTEGER PRIMARY KEY, ad TEXT)');
        Db.SQL('INSERT INTO kisi (id, ad) VALUES (1, ''Ali'')');

        with Db.Query('SELECT id, ad FROM kisi') do
        begin
          while Next do
            WriteLn(FieldInt('id'), ' - ', FieldStr('ad'));
        end;
      finally
        Db.Free;
      end;
    end;
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Windows;

const
  DLL_NAME = 'vdbapi.dll';

  { ABI surumu: major.minor. Uyumsuzluk fark etmek icin VdbClient
    ilk kullanimda surumu denetler. }
  VDB_API_VERSION = $00010200;   // 1.2 (1.1 + paralel havuz yonetimi)

  { Hata kodlari }
  VDB_OK            =  0;
  VDB_E_GENERAL     = -1;
  VDB_E_BAD_HANDLE  = -2;
  VDB_E_OPEN        = -3;
  VDB_E_SQL         = -4;
  VDB_E_READONLY    = -5;
  VDB_E_BUFFER      = -6;
  VDB_E_RANGE       = -7;
  VDB_E_ENGINE      = -8;
  VDB_E_NOT_FOUND   = -9;
  VDB_E_DUPLICATE   = -10;
  VDB_E_CONSTRAINT  = -11;

  { SQL bayraklari }
  VDB_SQL_AUTOTXN   = $0001;

type
  EVDbApiError = class(Exception)
  public
    Code: Integer;
    constructor Create(ACode: Integer; const ADetail: string);
    function ToString: string; override;
  end;

  { Tek bir sorgu sonucu. Degerler dll icinde saklandigi icin
    free/Close kullanilir. }
  TVDbResult = class
  private
    FHandle: LongWord;
    FFieldCount: Integer;
    FRowCount: Integer;
    FRows: array of string;   // SUTUN DUZENDE: [satir * FFieldCount + kolon]
  public
    constructor Create(AHandle: LongWord);
    destructor Destroy; override;

    property FieldCount: Integer read FFieldCount;
    property RowCount: Integer read FRowCount;
    function FieldName(AIndex: Integer): string;
    function Value(ARow, ACol: Integer): string;
    function Affected: Integer;
    function Stmts: Integer;
    function MessageText: string;
    function LastTable: string;
  end;

  { ACIK VERITABANI }
  TVDb = class
  private
    FHandle: LongWord;
    function GetCount: Integer;
    function GetFileSize: Int64;
    function GetDeadBytes: Int64;
    function GetWalRecordCount: Integer;
  public
    constructor Create; overload;
    destructor Destroy; override;

    { Ac. SYNC = True ise her yazma aninda diske yazilir (dayanikli,
      yavas). False ise tamponlu (hizli); Close'ta yazilir.
      ASync parametresi verilmezse True (guvenli varsayilan). }
    class function Open(const APath: string; ASync: Boolean = True): TVDb; static;
    class function TryOpen(const APath: string; ASync: Boolean;
      out ADb: TVDb; out AError: string): Boolean; static;
    procedure Close;

    property Handle: LongWord read FHandle;
    property Count: Integer read GetCount;
    property Size: Int64 read GetFileSize;
    property DeadBytes: Int64 read GetDeadBytes;
    property WalRecordCount: Integer read GetWalRecordCount;

    { ---- ham anahtar/deger ---- }
    procedure Put(AKey: Int64; const AData: AnsiString); overload;
    procedure PutBytes(AKey: Int64; const AData: array of Byte); overload;
    function GetStr(AKey: Int64; out AValue: AnsiString): Boolean;
    function GetBytes(AKey: Int64; out AData: TBytes): Boolean;
    function Exists(AKey: Int64): Boolean;
    function DeleteKey(AKey: Int64): Boolean;
    procedure Flush;

    { ---- SQL ---- }
    { SQL metni UTF-8 olmalidir. }
    function SQL(const ASql: string; AFlags: Integer = 0): TVDbResult;

    { ---- bakim ---- }
    function Verify(out AReport: AnsiString): Boolean;
    function AutoCompact(out AOldSize, ANewSize: Int64): Boolean;
    function HasWAL: Boolean;
    function WalWrite(AKey: Int64; const AData: AnsiString): Boolean;
    function WalWriteDelete(AKey: Int64): Boolean;
    function WalReplay: Boolean;
    function WalCheckpoint: Boolean;

    { ---- OTOMATIK WAL (write-ahead) ----
      WalAutoEnabled := True sonrasi her Put/DeleteKey once .wal'a,
      sonra ana dosyaya yazilir; sistem cokerse kayit .wal'da kalir
      ve WalReplay ile kurtarilir. Varsayilan KAPALI.
      WalAutoCount = bu agaza kadar gunluge yazilan kayit sayisi.
      Durum Close/Open ile sifirlanir. Elle WalWrite kullaniminda
      otomatik modu kapatin (cift yazim olur). }
    procedure SetWalAuto(AEnabled: Boolean);
    function GetWalAuto: Boolean;
    function GetWalAutoCount: Integer;

    property WalAutoEnabled: Boolean read GetWalAuto;
    property WalAutoCount: Integer read GetWalAutoCount;

    { ---- SIFRELEME (2026-10-05 Adim 17) ----
      SetEncryptKey: 32 baytlik HAM anahtar ile acar (ham mod).
      CreateKeyFile/OpenKeyFile: parola + .key dosyasi modu (PBKDF2).
      RekeyWithPassword: parola rotasyonu (ALTER DATABASE KEY ile ayni).
      Not: anahtari Set/Open YAPAN, yeni kayitlari o anahtarla yazar. }
    procedure SetEncryptKey(const AKey: TBytes);
    procedure ClearEncryptKey;
    function GetIsEncrypted: Boolean;
    function CreateKeyFile(const APath, APassword: string): Boolean;
    function OpenKeyFile(const APath, APassword: string): Boolean;
    function GetKeyPath: string;
    function GetEncryptionKeyFingerprint: string;
    function GetHasEncryptedRecords: Boolean;
    procedure RekeyWithPassword(const ANewPassword: string);

    property IsEncrypted: Boolean read GetIsEncrypted;
    property HasEncryptedRecords: Boolean read GetHasEncryptedRecords;
    property KeyPath: string read GetKeyPath;

    { ---- CDC / Time Travel (2026-10-06, poll modu) ----
      CdcStart: CDC parcacagini baslatir ve OTOMATIK WAL'i acar.
      CdcPoll: tek cagirida BIR olay getirir; olay yokken False doner
        (hata DEGIL). Paket (UTF-8, alan ayirici #30):
          kind #30 seq #30 table #30 pk #30 oldJson #30 newJson
        kind: 0=insert, 1=update, 2=delete; json = kolon degerleri.
      CdcStop: parcacagi durdurur; bekleyen olaylar KALIR ve cekilebilir.
      CdcStats: olay/atlanan/bekleyen/dusen sayaclari (tanilama).
      ValueAt: WAL gecmisindeki satir degeri (JSON dizi); ASeq = WAL
        kayit indeksi (0 tabanli, dahil). False = o noktada satir yok.
      HistoryCount: okunabilir gecmis sayisi (checkpoint ile sifirlanabilir).
      DIKKAT: tek istemci varsayilir - ayni anda iki CdcPoll cagirilmaz. }
    procedure CdcStart;
    procedure CdcStop;
    function CdcPollSize: Integer;
    function CdcPoll(out APacket: AnsiString): Boolean;
    procedure CdcStats(out AEvents, ASkipped, APending, ADropped: Integer);
    function ValueAt(const ATable, APK: string; ASeq: Integer;
      out AJson: AnsiString): Boolean;
    function GetHistoryCount: Integer;

    property HistoryCount: Integer read GetHistoryCount;

    { ---- R-14 Full: paralel havuz (global; sinif/baglanti bagimsiz) ----
      Motor buyuk ORDER BY siralamalarini (>= 2048 satir) isci havuzuna
      dagitir. Havuz kapaliyken ilk buyuk siralama kendiliginden acilir.
      ParallelInit(n): n isciyle acar (n<=0: islemci sayisina gore);
        donus = acilan isci sayisi (0 = basarisiz).
      ParallelWorkers: gecerli isci sayisi (0 = havuz kapali).
      ParallelShutdown: kapatir; donus = kapatilan isci sayisi. }
    class function ParallelInit(AMaxWorkers: Integer): Integer; static;
    class function ParallelWorkers: Integer; static;
    class function ParallelShutdown: Integer; static;

    { Hata yardimcilari }
    class function LastError: string; static;
    class function LastErrorCode: Integer; static;
    class function Check(ACode: Integer; const AWhat: string): Integer; static;
  end;

implementation

{ DLL'den bir export adresi cozer. kernel32'den dogrudan cagrilir;
  Delphi ic ice procedure tanimina izin vermez, bu yuzden ayri
  birim seviyesi bildirim olarak yazilmistir. }
function GetProc(HModule_: LongWord; Name: PAnsiChar): Pointer; stdcall;
  external 'kernel32.dll' name 'GetProcAddress';

{ FPC bir prosedur/isaretci DEGISKENINI nil ile dogrudan karsilastirmaya
  izin vermiyor ("Operator is not overloaded"). Cozum: once Pointer'a
  cevirip adresi sifirla karsilastiriyoruz. Delphi'de de gecerlidir. }
function IsNil(P: Pointer): Boolean;
begin
  Result := P = nil;
end;

{ Bir degeri (orn. prosedur degiskenini) adres olarak alir. Boylece
  "bu prosedur isaretcisi atanmis mi" sorusu Pointer turunde
  sorulabilir. }
function ProcAddr(var V: Pointer): Pointer;
begin
  Result := V;
end;

var
  { DLL tanitici (thread-safe ilk yukleme) }
  GDll: LongWord = 0;
  GDllChecked: Boolean = False;

  { --- cozulmus API isaretcileri --- }
  pApiVersion: function: LongWord; stdcall = nil;
  pVersion: function: PAnsiChar; stdcall = nil;
  pLastError: function: PAnsiChar; stdcall = nil;
  pErrCode: function: LongInt; stdcall = nil;
  pOpen: function(APath: PAnsiChar; ASyncWrite: LongInt): LongWord; stdcall = nil;
  pClose: procedure(AHandle: LongWord); stdcall = nil;
  pCloseAll: procedure; stdcall = nil;
  pCount: function(AHandle: LongWord): LongInt; stdcall = nil;
  pPut: function(AHandle: LongWord; AKey: Int64; AData: PByte;
    ALen: LongInt): LongInt; stdcall = nil;
  pGet: function(AHandle: LongWord; AKey: Int64; AData: PByte;
    ALen: LongInt): LongInt; stdcall = nil;
  pExists: function(AHandle: LongWord; AKey: Int64): LongInt; stdcall = nil;
  pDelete: function(AHandle: LongWord; AKey: Int64): LongInt; stdcall = nil;
  pFlush: procedure(AHandle: LongWord); stdcall = nil;
  pExec: function(AHandle: LongWord; ASql: PAnsiChar;
    AFlags: LongInt): LongWord; stdcall = nil;
  pFieldCount: function(AHandle: LongWord): LongInt; stdcall = nil;
  pRowCount: function(AHandle: LongWord): LongInt; stdcall = nil;
  pFieldName: function(AHandle: LongWord; ACol: LongInt): PAnsiChar; stdcall = nil;
  pValue: function(AHandle: LongWord; ARow, ACol: LongInt): PAnsiChar; stdcall = nil;
  pAffected: function(AHandle: LongWord): LongInt; stdcall = nil;
  pStmts: function(AHandle: LongWord): LongInt; stdcall = nil;
  pResultMsg: function(AHandle: LongWord): PAnsiChar; stdcall = nil;
  pLastTable: function(AHandle: LongWord): PAnsiChar; stdcall = nil;
  pResultFree: procedure(AHandle: LongWord); stdcall = nil;
  pVerify: function(AHandle: LongWord; AReport: PAnsiChar;
    AMax: LongInt): LongInt; stdcall = nil;
  pWalHas: function(AHandle: LongWord): LongInt; stdcall = nil;
  pWalRecordCount: function(AHandle: LongWord): LongInt; stdcall = nil;
  pWalWrite: function(AHandle: LongWord; AKey: Int64; AData: PByte;
    ALen: LongInt): LongInt; stdcall = nil;
  pWalWriteDel: function(AHandle: LongWord; AKey: Int64): LongInt; stdcall = nil;
  pWalReplay: function(AHandle: LongWord): LongInt; stdcall = nil;
  pWalCheckpoint: function(AHandle: LongWord): LongInt; stdcall = nil;
  pWalSetAuto: function(AHandle: LongWord; AEnable: LongInt): LongInt; stdcall = nil;
  pWalIsAuto: function(AHandle: LongWord): LongInt; stdcall = nil;
  pWalAutoCount: function(AHandle: LongWord): LongInt; stdcall = nil;
  pFileSize: function(AHandle: LongWord): Int64; stdcall = nil;
  pDeadBytes: function(AHandle: LongWord): Int64; stdcall = nil;
  pAutoCompact: function(AHandle: LongWord; AOld, ANew: PInt64): LongInt; stdcall = nil;

  { --- SIFRELEME (2026-10-05 Adim 17) --- }
  pEncEnable: function(AHandle: LongWord; AKey: PByte; ALen: LongInt): LongInt; stdcall = nil;
  pEncDisable: function(AHandle: LongWord): LongInt; stdcall = nil;
  pEncIsEncrypted: function(AHandle: LongWord): LongInt; stdcall = nil;
  pEncCreateKeyFile: function(AHandle: LongWord; APath, APassword: PAnsiChar): LongInt; stdcall = nil;
  pEncOpenKeyFile: function(AHandle: LongWord; APath, APassword: PAnsiChar): LongInt; stdcall = nil;
  pEncKeyPath: function(AHandle: LongWord; ABuf: PAnsiChar; AMax: LongInt): LongInt; stdcall = nil;
  pEncFingerprint: function(AHandle: LongWord; ABuf: PAnsiChar; AMax: LongInt): LongInt; stdcall = nil;
  pHasEncryptedRecords: function(AHandle: LongWord): LongInt; stdcall = nil;
  pRekey: function(AHandle: LongWord; ANewPassword: PAnsiChar): LongInt; stdcall = nil;

  { --- CDC / Time Travel (2026-10-06, poll) --- }
  pCdcStart: function(AHandle: LongWord): LongInt; stdcall = nil;
  pCdcStop: function(AHandle: LongWord): LongInt; stdcall = nil;
  pCdcPollSize: function(AHandle: LongWord): LongInt; stdcall = nil;
  pCdcPoll: function(AHandle: LongWord; ABuf: PAnsiChar;
    ALen: LongInt): LongInt; stdcall = nil;
  pCdcStats: function(AHandle: LongWord; AEvents, ASkipped, APending,
    ADropped: PInteger): LongInt; stdcall = nil;
  pValueAt: function(AHandle: LongWord; ATable, APk: PAnsiChar; ASeq: LongInt;
    ABuf: PAnsiChar; ALen: LongInt): LongInt; stdcall = nil;
  pHistoryCount: function(AHandle: LongWord): LongInt; stdcall = nil;
  { R-14 Full: paralel havuz }
  pParInit: function(AMaxWorkers: LongInt): LongInt; stdcall = nil;
  pParWorkers: function: LongInt; stdcall = nil;
  pParShutdown: function: LongInt; stdcall = nil;

{ ---------------------------------------------------------------- hata }

constructor EVDbApiError.Create(ACode: Integer; const ADetail: string);
begin
  Code := ACode;
  inherited Create('VDB[' + IntToStr(ACode) + '] ' + ADetail);
end;

function EVDbApiError.ToString: string;
begin
  Result := Message;
end;

class function TVDb.LastError: string; static;
begin
  if IsNil(ProcAddr(Pointer(@pLastError))) then Result := '(dll yuklenmedi)'
  else Result := AnsiString(pLastError());
end;

class function TVDb.LastErrorCode: Integer; static;
begin
  if IsNil(ProcAddr(Pointer(@pErrCode))) then Result := VDB_E_GENERAL
  else Result := pErrCode();
end;

class function TVDb.Check(ACode: Integer; const AWhat: string): Integer; static;
begin
  Result := ACode;
  if ACode = VDB_OK then Exit;
  raise EVDbApiError.Create(ACode, AWhat + ': ' + LastError);
end;

{ ------------------------------------------------------------ DLL yukleme }

procedure LoadDll;
var
  R: Integer;
begin
  if GDllChecked then Exit;
  GDllChecked := True;
  GDll := LoadLibraryA(PChar(DLL_NAME));
  if GDll = 0 then
  begin
    R := GetLastError;
    raise Exception.CreateFmt('%s yuklenemedi (Windows hata kodu %d). ' +
      'Dosya program klasorunde olmali.', [DLL_NAME, R]);
  end;

  pApiVersion    := GetProc(GDll, 'VdbApiVersion');
  pVersion       := GetProc(GDll, 'VdbVersion');
  pLastError     := GetProc(GDll, 'VdbLastError');
  pErrCode       := GetProc(GDll, 'VdbLastErrorCodeGet');
  pOpen          := GetProc(GDll, 'VdbOpen');
  pClose         := GetProc(GDll, 'VdbClose');
  pCloseAll      := GetProc(GDll, 'VdbCloseAll');
  pCount         := GetProc(GDll, 'VdbCount');
  pPut           := GetProc(GDll, 'VdbPut');
  pGet           := GetProc(GDll, 'VdbGet');
  pExists        := GetProc(GDll, 'VdbExists');
  pDelete        := GetProc(GDll, 'VdbDelete');
  pFlush         := GetProc(GDll, 'VdbFlush');
  pExec          := GetProc(GDll, 'VdbExec');
  pFieldCount    := GetProc(GDll, 'VdbResultFieldCount');
  pRowCount      := GetProc(GDll, 'VdbResultRowCount');
  pFieldName     := GetProc(GDll, 'VdbResultFieldName');
  pValue         := GetProc(GDll, 'VdbResultValue');
  pAffected      := GetProc(GDll, 'VdbResultAffected');
  pStmts         := GetProc(GDll, 'VdbResultStmts');
  pResultMsg     := GetProc(GDll, 'VdbResultMessage');
  pLastTable     := GetProc(GDll, 'VdbResultLastTable');
  pResultFree    := GetProc(GDll, 'VdbResultFree');
  pVerify        := GetProc(GDll, 'VdbVerify');
  pWalHas        := GetProc(GDll, 'VdbWalHas');
  pWalRecordCount:= GetProc(GDll, 'VdbWalRecordCount');
  pWalWrite      := GetProc(GDll, 'VdbWalWrite');
  pWalWriteDel   := GetProc(GDll, 'VdbWalWriteDelete');
  pWalReplay     := GetProc(GDll, 'VdbWalReplay');
  pWalCheckpoint := GetProc(GDll, 'VdbWalCheckpoint');
  pWalSetAuto    := GetProc(GDll, 'VdbWalSetAuto');
  pWalIsAuto     := GetProc(GDll, 'VdbWalIsAuto');
  pWalAutoCount  := GetProc(GDll, 'VdbWalAutoCount');
  pFileSize      := GetProc(GDll, 'VdbFileSize');
  pDeadBytes     := GetProc(GDll, 'VdbDeadBytes');
  pAutoCompact   := GetProc(GDll, 'VdbAutoCompact');
  pEncEnable     := GetProc(GDll, 'VdbEncryptEnable');
  pEncDisable    := GetProc(GDll, 'VdbEncryptDisable');
  pEncIsEncrypted:= GetProc(GDll, 'VdbEncryptIsEncrypted');
  pEncCreateKeyFile := GetProc(GDll, 'VdbEncryptCreateKeyFile');
  pEncOpenKeyFile   := GetProc(GDll, 'VdbEncryptOpenKeyFile');
  pEncKeyPath    := GetProc(GDll, 'VdbEncryptKeyPath');
  pEncFingerprint:= GetProc(GDll, 'VdbEncryptFingerprint');
  pHasEncryptedRecords := GetProc(GDll, 'VdbHasEncryptedRecords');
  pRekey         := GetProc(GDll, 'VdbRekeyWithPassword');
  pCdcStart      := GetProc(GDll, 'VdbCdcStart');
  pCdcStop       := GetProc(GDll, 'VdbCdcStop');
  pCdcPollSize   := GetProc(GDll, 'VdbCdcPollSize');
  pCdcPoll       := GetProc(GDll, 'VdbCdcPoll');
  pCdcStats      := GetProc(GDll, 'VdbCdcStats');
  pValueAt       := GetProc(GDll, 'VdbValueAt');
  pHistoryCount  := GetProc(GDll, 'VdbHistoryCount');
  pParInit       := GetProc(GDll, 'VdbParallelInit');
  pParWorkers    := GetProc(GDll, 'VdbParallelWorkers');
  pParShutdown   := GetProc(GDll, 'VdbParallelShutdown');

  if IsNil(ProcAddr(Pointer(@pOpen))) then
    raise Exception.Create(DLL_NAME + ' icinde beklenen API bulunamadi ' +
      '(DLL bozuk olabilir).');

  if pApiVersion() <> VDB_API_VERSION then
    raise Exception.CreateFmt('DLL surumu uyumsuz: DLL=%d beklenen=%d. ' +
      'DLL ile eslesen VDbClient surumunu kullan.',
      [pApiVersion(), VDB_API_VERSION]);
end;

{ -------------------------------------------------------------- TVDbResult }

constructor TVDbResult.Create(AHandle: LongWord);
var
  C, R: Integer;
begin
  inherited Create;
  FHandle := AHandle;
  if IsNil(ProcAddr(Pointer(@pFieldCount))) then LoadDll;
  FFieldCount := pFieldCount(AHandle);
  FRowCount := pRowCount(AHandle);
  if (FRowCount > 0) and (FFieldCount > 0) then
  begin
    SetLength(FRows, FRowCount * FFieldCount);
    // Tum degerleri DLL'den TEK SEFERDE cekiyoruz. NEDEN: dll donen
    // isaretler kendi tamponuna gecerli; satiri satir gezerken her
    // cagri o tamponu EZERDI. Tek cagrida hepsini kopyalamak hem
    // dogru hem de hizli.
    for C := 0 to FFieldCount - 1 do
      for R := 0 to FRowCount - 1 do
        FRows[R * FFieldCount + C] := AnsiString(pValue(AHandle, R, C));
  end;
end;

destructor TVDbResult.Destroy;
begin
  if (FHandle <> 0) and (not IsNil(ProcAddr(Pointer(@pResultFree)))) then
    pResultFree(FHandle);
  FHandle := 0;
  inherited Destroy;
end;

function TVDbResult.FieldName(AIndex: Integer): string;
begin
  if (AIndex < 0) or (AIndex >= FFieldCount) then
    raise EVDbApiError.Create(VDB_E_RANGE, 'kolon indeksi disinda');
  Result := AnsiString(pFieldName(FHandle, AIndex));
end;

function TVDbResult.Value(ARow, ACol: Integer): string;
begin
  if (ARow < 0) or (ARow >= FRowCount) or (ACol < 0) or (ACol >= FFieldCount) then
    raise EVDbApiError.Create(VDB_E_RANGE, 'satir/kolon indeksi disinda');
  Result := FRows[ARow * FFieldCount + ACol];   // sutun duzende saklandi
end;

function TVDbResult.Affected: Integer;
begin
  Result := pAffected(FHandle);
end;

function TVDbResult.Stmts: Integer;
begin
  Result := pStmts(FHandle);
end;

function TVDbResult.MessageText: string;
begin
  Result := AnsiString(pResultMsg(FHandle));
end;

function TVDbResult.LastTable: string;
begin
  Result := AnsiString(pLastTable(FHandle));
end;

{ -------------------------------------------------------------------- TVDb }

constructor TVDb.Create;
begin
  inherited Create;
  FHandle := 0;
  LoadDll;
end;

destructor TVDb.Destroy;
begin
  Close;
  inherited Destroy;
end;

class function TVDb.Open(const APath: string; ASync: Boolean): TVDb;
begin
  LoadDll;
  Result := TVDb.Create;
  try
    Result.FHandle := pOpen(PChar(APath), Ord(ASync));
    if Result.FHandle = 0 then
      raise EVDbApiError.Create(LastErrorCode,
        'acilamadi (' + APath + '): ' + LastError);
  except
    Result.Free;
    raise;
  end;
end;

class function TVDb.TryOpen(const APath: string; ASync: Boolean;
  out ADb: TVDb; out AError: string): Boolean;
begin
  ADb := nil;
  AError := '';
  try
    ADb := TVDb.Open(APath, ASync);
    Result := True;
  except
    on E: Exception do
    begin
      AError := E.Message;
      Result := False;
    end;
  end;
end;

procedure TVDb.Close;
begin
  if FHandle <> 0 then
  begin
    pClose(FHandle);
    FHandle := 0;
  end;
end;

function TVDb.GetCount: Integer;
begin
  Result := pCount(FHandle);
end;

function TVDb.GetFileSize: Int64;
begin
  Result := pFileSize(FHandle);
end;

function TVDb.GetDeadBytes: Int64;
begin
  Result := pDeadBytes(FHandle);
end;

function TVDb.GetWalRecordCount: Integer;
begin
  Result := pWalRecordCount(FHandle);
end;

procedure TVDb.Put(AKey: Int64; const AData: AnsiString);
begin
  Check(pPut(FHandle, AKey, PByte(PAnsiChar(AData)), Length(AData)),
    'Put');
end;

procedure TVDb.PutBytes(AKey: Int64; const AData: array of Byte);
begin
  if Length(AData) = 0 then
    Check(pPut(FHandle, AKey, nil, 0), 'Put')
  else
    Check(pPut(FHandle, AKey, @AData[0], Length(AData)), 'Put');
end;

function TVDb.GetStr(AKey: Int64; out AValue: AnsiString): Boolean;
{ Iki asamali kullanim:
    1) VdbGet(handle, key, nil, 0)  -> gerekli BOYUT  (negatif doner)
    2) o boyut kadar tampon ayir, VdbGet(handle, key, buf, need)

  DONUS: True = anahtar var, False = anahtar yok.

  ONCEKI SURUMDEKI IKI HATA:
   a) Negatif degerin her turu "gerekli boyut" sayiliyordu; boyut
      sorgusu donen hata kodu "-6 bayt" gibi okunup cok gec fark
      ediliyordu. Artik -1'den kucuk deger HATA sayilir.
   b) NIL isaretci PByte parametreye gecerken derleyici tarafindan
      elenebiliyor. Bu yuzden DLL "boyut sorgusu" tetikleyicisi olarak
      ALen = 0 degerini kullanir; AData'ya bakmaz. }
var
  Need: LongInt;
  Buf: AnsiString;
  Raw: Pointer;
  Code: Integer;
begin
  AValue := '';
  Raw := nil;
  Need := pGet(FHandle, AKey, PByte(Raw), 0);
  { DONUS SOZLESMESI (vdbapi.h ile ayni):
      -1  -> anahtar yok
      0   -> anahtar var, deger BOS
      <0  -> gerekli boyut = -sonuc

    DIKKAT: hata kodlari (-1..-11) ile "gerekli boyut" ayni olabilecek
    DEGERLERDE karsilasiyor. Ayirt etmek icin hata KODUNU soruyoruz:
    `VdbGet` basarili oldugunda hata kodu TEMIZLENIR. Yani:
      -1            => anahtar yok
      kod <> 0      => GERCEK HATA (kod ne ise odur)
      kod = 0, N<0  => gerekli boyut

    2026-10-04: once "N <= -1 ise hata" diye yorumlaniyordu; oysa
    basarili bir 13 baytlik deger icin dönen -13 "gereken boyut"
    demekti ve istemci bunu hata sanip -13 firlatiyordu. }
  if Need = -1 then
  begin
    Result := False;                    // anahtar yok
    Exit;
  end;
  if Need < 0 then
  begin
    Code := LastErrorCode;
    if Code <> VDB_OK then
      Check(Code, 'Get (boyut sorgusu)');
    Need := -Need;                      // gerekli boyut
  end;
  SetLength(Buf, Need);
  if Need > 0 then
  begin
    { VdbGet basarili oldugunda KOPYALANAN BAYT SAYISINI doner (>=0);
      hata kodunu DEGIL. Bu yuzden "0 degilse hata" diye bakilamaz.
      Hata yalnizca donus degeri NEGATIFSE olur. }
    Code := pGet(FHandle, AKey, PByte(@Buf[1]), Need);
    if Code < 0 then
      Check(Code, 'Get');
  end;
  AValue := Buf;
  Result := True;
end;

function TVDb.GetBytes(AKey: Int64; out AData: TBytes): Boolean;
var
  S: AnsiString;
begin
  SetLength(AData, 0);
  Result := GetStr(AKey, S);
  if Result then
  begin
    SetLength(AData, Length(S));
    if Length(S) > 0 then Move(S[1], AData[0], Length(S));
  end;
end;

function TVDb.Exists(AKey: Int64): Boolean;
begin
  Result := pExists(FHandle, AKey) <> 0;
end;

function TVDb.DeleteKey(AKey: Int64): Boolean;
begin
  Check(pDelete(FHandle, AKey), 'Delete');
  Result := True;
end;

procedure TVDb.Flush;
begin
  pFlush(FHandle);
end;

function TVDb.SQL(const ASql: string; AFlags: Integer): TVDbResult;
var
  H: LongWord;
begin
  H := pExec(FHandle, PChar(ASql), AFlags);
  if H = 0 then
    raise EVDbApiError.Create(LastErrorCode, 'SQL: ' + LastError);
  Result := TVDbResult.Create(H);
end;

function TVDb.Verify(out AReport: AnsiString): Boolean;
var
  Buf: array[0..511] of AnsiChar;
begin
  FillChar(Buf, SizeOf(Buf), 0);
  Result := pVerify(FHandle, @Buf[0], SizeOf(Buf)) <> 0;
  AReport := AnsiString(Buf);
end;

function TVDb.AutoCompact(out AOldSize, ANewSize: Int64): Boolean;
begin
  Result := pAutoCompact(FHandle, @AOldSize, @ANewSize) <> 0;
end;

{ ---------------------------------------------------------- SIFRELEME }

procedure TVDb.SetEncryptKey(const AKey: TBytes);
var
  P: PByte;
begin
  if Length(AKey) = 0 then P := nil else P := @AKey[0];
  // DIKKAT: sifreleme export'lari 1=basari, 0=hata dondurur
  // (VdbPut/VdbDelete gibi "hata kodu" fonksiyonlarindan farklidir).
  if pEncEnable(FHandle, P, Length(AKey)) = 0 then
    raise EVDbApiError.Create(LastErrorCode, 'SetEncryptKey: ' + LastError);
end;

procedure TVDb.ClearEncryptKey;
begin
  if pEncDisable(FHandle) = 0 then
    raise EVDbApiError.Create(LastErrorCode, 'ClearEncryptKey: ' + LastError);
end;

function TVDb.GetIsEncrypted: Boolean;
begin
  Result := pEncIsEncrypted(FHandle) <> 0;
end;

function TVDb.CreateKeyFile(const APath, APassword: string): Boolean;
begin
  if pEncCreateKeyFile(FHandle, PChar(APath), PChar(APassword)) = 0 then
    raise EVDbApiError.Create(LastErrorCode, 'CreateKeyFile: ' + LastError);
  Result := True;
end;

function TVDb.OpenKeyFile(const APath, APassword: string): Boolean;
// Yanlis parola DLL tarafinda hata KODU dondurur (istisna degil):
// False doner, ayrinti LastError'tedir.
begin
  Result := pEncOpenKeyFile(FHandle, PChar(APath), PChar(APassword)) <> 0;
end;

function TVDb.GetKeyPath: string;
var
  Buf: array[0..1023] of AnsiChar;
  N: Integer;
begin
  FillChar(Buf, SizeOf(Buf), 0);
  N := pEncKeyPath(FHandle, @Buf[0], SizeOf(Buf));
  if N < 0 then Result := '' else Result := string(AnsiString(Buf));
end;

function TVDb.GetEncryptionKeyFingerprint: string;
var
  Buf: array[0..255] of AnsiChar;
  N: Integer;
begin
  FillChar(Buf, SizeOf(Buf), 0);
  N := pEncFingerprint(FHandle, @Buf[0], SizeOf(Buf));
  if N < 0 then Result := '' else Result := string(AnsiString(Buf));
end;

function TVDb.GetHasEncryptedRecords: Boolean;
begin
  Result := pHasEncryptedRecords(FHandle) <> 0;
end;

procedure TVDb.RekeyWithPassword(const ANewPassword: string);
begin
  if pRekey(FHandle, PChar(ANewPassword)) = 0 then
    raise EVDbApiError.Create(LastErrorCode, 'RekeyWithPassword: ' + LastError);
end;

function TVDb.HasWAL: Boolean;
begin
  Result := pWalHas(FHandle) <> 0;
end;

function TVDb.WalWrite(AKey: Int64; const AData: AnsiString): Boolean;
begin
  Check(pWalWrite(FHandle, AKey, PByte(PAnsiChar(AData)), Length(AData)),
    'WalWrite');
  Result := True;
end;

function TVDb.WalWriteDelete(AKey: Int64): Boolean;
begin
  Check(pWalWriteDel(FHandle, AKey), 'WalWriteDelete');
  Result := True;
end;

function TVDb.WalReplay: Boolean;
begin
  Check(pWalReplay(FHandle), 'WalReplay');
  Result := True;
end;

function TVDb.WalCheckpoint: Boolean;
begin
  Check(pWalCheckpoint(FHandle), 'WalCheckpoint');
  Result := True;
end;

procedure TVDb.SetWalAuto(AEnabled: Boolean);
begin
  Check(pWalSetAuto(FHandle, Ord(AEnabled)), 'SetWalAuto');
end;

function TVDb.GetWalAuto: Boolean;
begin
  Result := pWalIsAuto(FHandle) <> 0;
end;

function TVDb.GetWalAutoCount: Integer;
begin
  Result := pWalAutoCount(FHandle);
end;

{ -------------------------------------------------- CDC / Time Travel (poll) }

procedure TVDb.CdcStart;
begin
  Check(pCdcStart(FHandle), 'CdcStart');   // 0 = OK; otomatik WAL acilir
end;

procedure TVDb.CdcStop;
begin
  Check(pCdcStop(FHandle), 'CdcStop');     // tampondaki olaylar KALIR
end;

function TVDb.CdcPollSize: Integer;
// Onunde duran olayin paket boyutu: >0 boyut, 0 = olay yok.
// Negatif = hata kodu -> EVDbApiError.
begin
  Result := pCdcPollSize(FHandle);
  if Result < 0 then
    Check(Result, 'CdcPollSize');
end;

function TVDb.CdcPoll(out APacket: AnsiString): Boolean;
// Tek olay ceker ve tampondan tuketir. False = olay yok (hata DEGIL).
var
  Need, Got: Integer;
  Buf: AnsiString;
begin
  APacket := '';
  Need := pCdcPollSize(FHandle);
  if Need < 0 then
    Check(Need, 'CdcPoll (boyut sorgusu)');
  if Need = 0 then
  begin
    Result := False;
    Exit;
  end;
  SetLength(Buf, Need);
  Got := pCdcPoll(FHandle, PAnsiChar(@Buf[1]), Need);
  if Got < 0 then
    Check(Got, 'CdcPoll');    // VDB_E_BUFFER burada hata sayilir
  SetLength(Buf, Got);
  APacket := Buf;
  Result := True;
end;

procedure TVDb.CdcStats(out AEvents, ASkipped, APending, ADropped: Integer);
var
  e, s, p, d: Integer;
begin
  AEvents := 0; ASkipped := 0; APending := 0; ADropped := 0;
  e := 0; s := 0; p := 0; d := 0;
  Check(pCdcStats(FHandle, @e, @s, @p, @d), 'CdcStats');
  AEvents := e; ASkipped := s; APending := p; ADropped := d;
end;

function TVDb.ValueAt(const ATable, APK: string; ASeq: Integer;
  out AJson: AnsiString): Boolean;
{ VdbValueAt iki asamali (VdbGet sozlesmesi):
    ALen=0  -> gerekli boyut (negatif), o noktada satir yoksa -1
    ALen>0  -> kopyalanan boyut (>=0)
  DONUS: True = satir var (AJson dolu),
         False = o noktada satir yok (silinmis/hic yazilmamis). }
var
  Need, Got, Code: Integer;
  Buf, t, k: AnsiString;
begin
  AJson := '';
  t := UTF8Encode(ATable);
  k := UTF8Encode(APK);
  Need := pValueAt(FHandle, PAnsiChar(t), PAnsiChar(k), ASeq, nil, 0);
  if Need = -1 then
  begin
    { -1 = "satir yok" ILE "hata" ayni degerde gelebilir; hata KODUNU
      soruyoruz (basarili cagrida kod temizlenir). }
    Code := LastErrorCode;
    if Code <> VDB_OK then
      Check(Code, 'ValueAt (boyut sorgusu)');
    Result := False;
    Exit;
  end;
  if Need < 0 then
  begin
    Code := LastErrorCode;
    if Code <> VDB_OK then
      Check(Code, 'ValueAt (boyut sorgusu)');
    Need := -Need;                       // gerekli boyut
  end;
  SetLength(Buf, Need);
  Got := Need;
  if Need > 0 then
  begin
    Got := pValueAt(FHandle, PAnsiChar(t), PAnsiChar(k), ASeq,
      PAnsiChar(@Buf[1]), Need);
    if Got < 0 then
      Check(Got, 'ValueAt');
  end;
  SetLength(Buf, Got);
  AJson := Buf;
  Result := True;
end;

function TVDb.GetHistoryCount: Integer;
begin
  Result := pHistoryCount(FHandle);
  if Result < 0 then
    Check(Result, 'HistoryCount');
end;

{ ---- R-14 Full: paralel havuz (global) ---- }

class function TVDb.ParallelInit(AMaxWorkers: Integer): Integer;
begin
  Result := pParInit(AMaxWorkers);
end;

class function TVDb.ParallelWorkers: Integer;
begin
  Result := pParWorkers();
end;

class function TVDb.ParallelShutdown: Integer;
begin
  Result := pParShutdown();
end;

initialization
  LoadDll;

finalization
  if not IsNil(ProcAddr(Pointer(@pCloseAll))) then pCloseAll;
  if GDll <> 0 then
  begin
    FreeLibrary(GDll);
    GDll := 0;
  end;

end.
