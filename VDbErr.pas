unit VDbErr;

{ VDb hata kodlari ve tipli istisna sinifi (P2).
  Hicbir VDb birimine bagimli degildir (yalnizca SysUtils), bu yuzden
  dongusel bagimlilik yaratmadan her katmanda kullanilabilir:
    VDbCore -> VDbTable -> VDbAst -> VDbParser -> VDbExecutor -> VDbSql

  Kural: mesaj metinleri DEGISTIRILMEZ (testler ve GUI mesaja bakiyor);
  yalnizca sinif Exception -> EVDbException olur ve kod eklenir.
  Boylece arayuz `on E: EVDbException` ile `E.ErrorCode` uzerinden
  programatik karar verebilir (metin ayristirmaya gerek yok).
}

{$mode delphi}

interface

uses
  SysUtils;

type
  TVDbErrorCode = (
    ecNone,                // hata yok / baslangic degeri
    ecGeneral,             // siniflandirilmamis genel hata
    // --- veritabani / dosya ---
    ecDatabaseNotOpen,     // Open cagrilmadan islem (kapali veritabani dahil)
    ecDatabaseNotFound,    // OPEN/DROP edilen veritabani diskte yok
    ecDatabaseExists,      // CREATE edilen veritabani zaten var
    ecDatabaseLocked,      // dosya kilitli / baska islemde acik
    ecIOError,             // yedekleme/tasima/yazma/silme dosya hatasi
    ecCorrupt,             // CRC / surum / index-data uyusmazligi
    ecHashCollision,       // FNV-1a carpismasi tespit edildi
    ecInvalidState,        // etkin DB silinemez gibi durum hatalari
    ecLimit,               // value boyutu / tablo limiti / JOIN 2M siniri
    // --- sema ---
    ecTableNotFound,
    ecTableExists,
    ecColumnNotFound,
    ecColumnExists,
    ecIndexNotFound,
    ecIndexExists,
    ecSchemaCorrupt,       // katalog bozuk / sema yazimi reddi
    ecInvalidName,         // bos / uzun / yasak karakterli ad
    // --- kisit ---
    ecDuplicatePrimaryKey,
    ecUniqueViolation,
    ecNotNullViolation,
    ecCheckViolation,
    ecForeignKeyViolation,
    // --- deger / tip ---
    ecTypeMismatch,        // INTEGER degil, tarih degil, SET tip uyusmazligi
    ecMathError,           // sifira bolme, FLOAT modulo
    ecInvalidArgument,     // sutun/deger sayisi uyusmazligi
    // --- sql ---
    ecSyntaxError,         // tokenizer / parser / cumle bicim hatalari
    ecUnsupported,          // 3+ JOIN, alt sorgu, PK guncelleme, ON esitlik disi
    ecTransactionState,    // batch zaten acik / acik degil / batch ici yasak
    ecDuplicateSavepoint,  // ayni isimde savepoint zaten var
    ecSavepointNotFound,   // savepoint bulunamadi
    // --- havuz ---
    ecPoolTimeout,         // Acquire zaman asimi (hepsi kullanimda)
    ecPoolClosed,          // kapanmis havuzdan Acquire
    // --- json ---
    ecJsonError,           // EXPORT/IMPORT JSON dogrulama ve bicim hatalari
    // --- yetki (R-18 RBAC) ---
    ecPermissionDenied,    // rol tablo/izin uzerinde yetkili degil
    ecObjectExists,        // CREATE ROLE: rol zaten var
    ecNotFound             // DROP ROLE / GRANT: nesne yok
  );

  EVDbException = class(Exception)
  public
    ErrorCode: TVDbErrorCode;
    constructor Create(ACode: TVDbErrorCode; const AMsg: string);
    constructor CreateFmt(ACode: TVDbErrorCode; const AFmt: string;
      const AArgs: array of const);
  end;

// Log/sunucu cevabi icin kodun derleyici-bagimsiz adi ('ecUniqueViolation').
function VDbErrorName(ACode: TVDbErrorCode): string;

implementation

constructor EVDbException.Create(ACode: TVDbErrorCode; const AMsg: string);
begin
  inherited Create(AMsg);
  ErrorCode := ACode;
end;

constructor EVDbException.CreateFmt(ACode: TVDbErrorCode; const AFmt: string;
  const AArgs: array of const);
begin
  inherited CreateFmt(AFmt, AArgs);
  ErrorCode := ACode;
end;

function VDbErrorName(ACode: TVDbErrorCode): string;
begin
  // Ord() siralamasina bagli kalmamak icin case kullanilir.
  case ACode of
    ecNone:                Result := 'ecNone';
    ecGeneral:             Result := 'ecGeneral';
    ecDatabaseNotOpen:     Result := 'ecDatabaseNotOpen';
    ecDatabaseNotFound:    Result := 'ecDatabaseNotFound';
    ecDatabaseExists:      Result := 'ecDatabaseExists';
    ecDatabaseLocked:      Result := 'ecDatabaseLocked';
    ecIOError:             Result := 'ecIOError';
    ecCorrupt:             Result := 'ecCorrupt';
    ecHashCollision:       Result := 'ecHashCollision';
    ecInvalidState:        Result := 'ecInvalidState';
    ecLimit:               Result := 'ecLimit';
    ecTableNotFound:       Result := 'ecTableNotFound';
    ecTableExists:          Result := 'ecTableExists';
    ecColumnNotFound:      Result := 'ecColumnNotFound';
    ecColumnExists:        Result := 'ecColumnExists';
    ecIndexNotFound:       Result := 'ecIndexNotFound';
    ecIndexExists:         Result := 'ecIndexExists';
    ecSchemaCorrupt:       Result := 'ecSchemaCorrupt';
    ecInvalidName:         Result := 'ecInvalidName';
    ecDuplicatePrimaryKey: Result := 'ecDuplicatePrimaryKey';
    ecUniqueViolation:     Result := 'ecUniqueViolation';
    ecNotNullViolation:    Result := 'ecNotNullViolation';
    ecCheckViolation:      Result := 'ecCheckViolation';
    ecForeignKeyViolation: Result := 'ecForeignKeyViolation';
    ecTypeMismatch:        Result := 'ecTypeMismatch';
    ecMathError:           Result := 'ecMathError';
    ecInvalidArgument:     Result := 'ecInvalidArgument';
    ecSyntaxError:         Result := 'ecSyntaxError';
    ecUnsupported:         Result := 'ecUnsupported';
    ecTransactionState:    Result := 'ecTransactionState';
    ecDuplicateSavepoint:  Result := 'ecDuplicateSavepoint';
    ecSavepointNotFound:   Result := 'ecSavepointNotFound';
    ecPoolTimeout:         Result := 'ecPoolTimeout';
    ecPoolClosed:          Result := 'ecPoolClosed';
    ecJsonError:           Result := 'ecJsonError';
    ecPermissionDenied:   Result := 'ecPermissionDenied';
    ecObjectExists:       Result := 'ecObjectExists';
    ecNotFound:           Result := 'ecNotFound';
  else
    Result := 'ecGeneral';
  end;
end;

end.
