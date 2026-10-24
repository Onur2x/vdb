unit VDbBackendApi;

{ VDB v3 - Backend arayuzu (Sprint 2 / 2.1)

  Amac: SQL katmani (VDbTable / VDbSql / VDbExecutor) motorun SOMUT tipini
  (TVDb) degil bu arayuzu tanisin. Boylece ayni SQL kodu hem v2 motoru
  (satir-kayit dosyasi) hem v3 sayfa motoru uzerinde calisir.

  Bu birim BILEREK cok az seye bagimlidir (yalniz SysUtils): v3 backend'i
  v2 motorunu link etmeden derlenebilsin.

  ONEMLI - SAHIPLIK: arayuz referans saymaz. Uygulayan nesne cagiran
  tarafindan yaratilir ve yine cagiran tarafindan serbest birakilir.
  TVDb gibi dogrudan Create/Free ile yonetilen nesnelerin yasam dongusunu
  degistirmemek icin bilincli tercih: `_AddRef` -1 doner, `_Release` 0
  doner (hicbir sey yapmaz). Arayuzu bir degiskende tutarken nesneyi
  serbest birakmak cagiranin sorumlulugudur.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TQWordArray = array of QWord;
  TValArray = array of TBytes;

  { R-26: satirin icindeki TABLO ID'yi cozucu. KV katmani satir bicimini
    BILMEZ; cozucuyu VDbTable saglar.
      >= 0 : bu kayit o tabloya ait satir
      -1   : satir degil (semaya benzer ozel kayit) -> filtre uygulanmaz }
  TVDbRowTagFunc = function(const PlainValue: TBytes; ValueLen: Integer): Integer;

  { P-18a: sifir-kopya tarama geri cagrisi. Buf, motorun ic tamponuna
    isaret eder — YALNIZ cagri sirasinda gecerlidir, saklanmamali.
    False => tarama durur. }
  TVDbRawCb = function(Key: QWord; Buf: PByte; Len: Integer;
    User: Pointer): Boolean;

  { R-11: COMMIT oncesi geri-cagirim (deferrable kisit denetimi). }
  TDbCommitHook = procedure of object;

  { M11: yalnizca temel KV islemleri (transaction/WAL/indeks disarida). }
  IVDbKvStore = interface
    ['{6D8B2E71-4C1A-4F6E-9E3B-7A5C0D2F1A44}']
    procedure Put(Key: QWord; const Value: TBytes);
    function Get(Key: QWord; out Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    procedure ScanAll(out Keys: TQWordArray; out Vals: TValArray;
      TableFilter: Integer);
  end;

  { Motorun SQL katmanina sundugu tam yuzey. VDbTable'in bugun TVDb
    uzerinden yaptigi cagrilarin tamami burada; boylece motor degisir,
    ust katman degismez. }
  IVDbBackend = interface
    ['{B4E1C7A2-9F31-4D68-8E5A-2C7B1D904E56}']
    { --- temel kayit islemleri --- }
    procedure Put(Key: QWord; const Value: TBytes);
    function Get(Key: QWord; out Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    function Exists(Key: QWord): Boolean;
    function Count: Integer;

    { --- tarama --- }
    procedure ScanAll(out Keys: TQWordArray; out Vals: TValArray;
      TableFilter: Integer = -1);
    function ScanRawIterAll(TableFilter: Integer;
      Cb: TVDbRawCb; User: Pointer): Boolean;

    { --- islem / toplu yazim --- }
    procedure BeginBatch;
    procedure CommitBatch;
    procedure AbortBatch;
    procedure Flush;
    function GetInBatch: Boolean;
    property InBatch: Boolean read GetInBatch;

    { --- sema / sifreleme kancalari --- }
    function EnsureColumnKey: QWord;
    function ColumnKeyId: QWord;
    function ColumnKeyPath: string;
    procedure SetBeforeCommit(Proc: TDbCommitHook);

    { Satir icindeki tablo kimligini cozen fonksiyon (R-26 filtresi). }
    procedure SetRowTagFunc(AValue: TVDbRowTagFunc);
  end;

implementation

end.
