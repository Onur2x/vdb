unit VDbTypes;
{ VDbTypes - paylasilan temel tipler.

  NEDEN AYRI BIRIM:
    VDbAst ve VDbTable birbirini kullaniyordu:
      VDbAst.pas -> uses VDbTable   (AST dugumleri TStrArray, TColDef,
                                     TFkDef, TWhereGroups, TTrigger* kullanir)
      VDbTable.pas -> uses VDbAst    (TViewDef.SelectStmt, TTriggerDef.WhenCondition,
                                     TColumnDef.DefaultExpr, TProcedureDef.Body AST tutar)
    Bu iki yonlu bagimlilik FPC'de derlenmez:
      "Fatal: Circular unit reference between VDbAst and VDbTable"

  Cozum: AST ile katalog arasinda paylasilan, HICBIRBIR DIZIYE
  BAGIMLI OLMAYAN tipler buraya tasindi. Iki birim de bunu kullanir;
    - VDbAst'in interface'inden VDbTable cikarildi (implementation'a
      tasindi: VDbNorm / VDbFloatToStr yalnizca uygulama kodunda
      gerekiyor),
    - VDbTable tip tanimlarini buradan alir.
  Boylece dongu kalici olarak kirilir ve AST'yi katalog birimi de
  tutabilir hale gelir (CREATE VIEW/Trigger/FUNCTION icin gerekli).

  ONEMLI: VDbTable bu birimi INTERFACE'inde uses ediyor. Pascal'da
  interface uses zincirleme (transitive) oldugu icin, VDbTable'i kullanan
  HICBIR birim bu tipleri kendi uses listesine eklemeden gorur - yani
  diger dosyalarda HICBIR DEGISIKLIK gerekmez.
}
{$mode delphi}{$H+}

interface

uses
  SysUtils;

const
  VCT_INT = 0;
  VCT_FLOAT = 1;
  VCT_STR = 2;
  VCT_BOOL = 3;
  VCT_DATE = 4;     // ISO yyyy-mm-dd metin
  VCT_DATETIME = 5; // ISO yyyy-mm-dd hh:nn:ss metin
  VCT_TIME = 6;     // ISO hh:nn:ss metin
  VCT_BLOB = 7;     // ham byte
  // F2-12: ON DELETE/UPDATE CASCADE zinciri ozguc doner (Delete ->
  // CheckRestrict -> Delete -> ...). CYCLE varsa (a -> b -> a) sonsuza
  // kadar doner (yigin tasmasi + sinirsiz silme). Azami derinlik.
  VDB_MAX_CASCADE_DEPTH = 32;

  // Sema tek dosyada: katalog ayrilmis key altinde KV icinde durur.
  // 0 kullanilir cunku VDbHashKey asla 0 uretmez (bak: asagida).
  VDB_SCHEMA_KEY: QWord = 0;
  VDB_SCHEMA_TAG = 'VSCH1';

  // Flags for VDbCore
  VDB_FLAG_PUT = 0;
  VDB_FLAG_DEL = 1;
  VDB_FLAG_BATCHEND = 2;
  VDB_FLAG_ENCRYPTED = 4;
  VDB_FLAG_COMPRESSED = 8;
  VDB_MAX_VALUE = 16 * 1024 * 1024;

  // File header
  VDB_FILE_MAGIC = $42444F56; // 'VODB' little-endian
  VDB_FILE_VER = 2;
  VDB_FILE_VER_OLD = 1;
  VDB_HDR_SIZE = 16;
  VDB_HFLAG_HAS_ENCRYPTED = 1;

  // Index key separator
  VDB_IDX_SEP = #1;

  // FK actions
  VDB_FK_RESTRICT = 'RESTRICT';
  VDB_FK_CASCADE = 'CASCADE';
  VDB_FK_SETNULL = 'SETNULL';
  VDB_FK_SETDEFAULT = 'SETDEFAULT';

type
  { R-18: RBAC izin turleri. GRANTS katalogda Byte olarak saklandigi
    icin ordinal degerleri semada PERSIST olarak tasinir; yeni izin
    turu EKLEMEK siralamayi bozabileceginden en sona eklenir. }
  TPrivKind = (pkNone, pkSelect, pkInsert, pkUpdate, pkDelete, pkAll);

  // --- basit dizi kisayollari ---
  TStrArray = array of string;
  TStrMatrix = array of TStrArray;
  TIntArray = array of Integer;
  TByteArray = array of Byte;

  // DIKKAT: TColDef ve TFkDef BURADA tanimlidir; TColArray ve TFkArray
  // ise VDbTable'da. Boylece VDbTable -> VDbTypes yonu kurulur, ama
  // VDbTable'in VDbTypes'in interface'ine dokunmasi gerekmez
  // (VDBTable <-> VDbAst dongusu kirilir).
  // TColArray burada da olsaydi VDbParser "got VDBTYPES.TFkDef expected
  // VDBTABLE.TFkDef" derleme hatasini veriyordu.

  // --- kolon tanimi ---
  TColDef = record
    Name: string;   // lower-case saklanir
    Ctype: Byte;
    NotNull: Boolean;
    Unique: Boolean;
    HasDef: Boolean;
    Def: string;    // ham literal (kullanimda normallesir)
    Deferrable: Byte;  // 0=NOT DEFERRABLE, 1=DEFERRABLE INITIALLY IMMEDIATE, 2=DEFERRABLE INITIALLY DEFERRED
    // R-20: kolon varsayilan collation'i (`ad TEXT COLLATE "tr-TR"`).
    // Bos = motor varsayilani (bayt sirasi / duyarli karsilastirma).
    Collate: string;
    // M10: GENERATED ALWAYS AS (ifade). STORED gibi davranir: deger
    // INSERT/UPDATE sirasinda hesaplanip saklanir. VIRTUAL kabul edilir
    // ama ayni sekilde saklanir (okuma aninda yeniden hesaplanmaz).
    Generated: Boolean;
    GenExpr: string;   // ExprToText ile kanoniklestirilmis ifade
    // M10: GENERATED {ALWAYS | BY DEFAULT} AS IDENTITY.
    // 0 = normal kolon, 1 = ALWAYS, 2 = BY DEFAULT.
    // Sema uyumu icin kolon bayrak alaninda (bit2/bit3) saklanir; boylece
    // sema satirinin alan sayisi degismez ve eski DB'ler aynen okunur.
    Identity: Byte;
  end;

  // --- yabanci anahtar ---
  TFkDef = record
    Col: Integer;     // cocuk kolon
    RefTable: string; // lower
    RefCol: string;   // lower
    // Referansli ebeveyn satiri silinince/guncellenince ne olacak:
    //   'RESTRICT' (varsayilan) | 'CASCADE' | 'SETNULL' | 'SETDEFAULT'
    OnDelete: string;
    OnUpdate: string;
    Deferrable: Byte;   // R-11: 0=NOT DEFERRABLE, 1=INITIALLY IMMEDIATE, 2=INITIALLY DEFERRED
  end;

  // R-03: ON CONFLICT action
  TOnConflictAction = (ocaNone, ocaDoNothing, ocaDoUpdate);

  // --- UPDATE ... SET ifadesi ---
  //   Kind = 0 : Duz deger (E.Lit)
  //   Kind = 1 : <kolon> Op <deger>   (orn. n = n + 1)
  //   Kind = 2 : <kolon> Op <deger>   (orn. n = n - b)
  // Op: '+', '-', '*', '/', '%'
  TSetExpr = record
    Kind: Byte;
    ColA: Integer;   // sol taraf tablo kolonu
    ColB: Integer;   // sag taraf kolonu (-1 = degil)
    Op: Char;
    Lit: string;     // sag taraf sabiti
  end;
  TSetExprs = array of TSetExpr;

  // R-03: ON CONFLICT DO UPDATE SET col = <value> ciftleri.
  //   dizi: kolon indeksi + deger (string olarak saklanir, tip cevirimi
  //   uygulayici tarafta yapilir).
  TSetValuePair = record
    ColIdx: Integer;
    Value: string;
  end;
  TSetValuePairs = array of TSetValuePair;

  // --- WHERE: OR'lanmis AND gruplari (DNF). OR yoksa tek grup ---
  TWhereCond = record
    Col: Integer;   // tablo kolon indexi
    Ctype: Byte;    // kolon tipi: karsilastirma tip-bilgili olsun
                    // (TEXT kolonunda '007' ile '7' eslesmesin diye sart)
    Op: string;     // = <> != > < >= <= LIKE NOTLIKE ISNULL ISNOTNULL
                    // IN NOTIN BETWEEN NOTBETWEEN
    Val: string;    // tek degerli operatorler icin
    Vals: TStrArray;// IN (...) listesi ve BETWEEN ust siniri
  end;
  TWhereGroup = array of TWhereCond;
  TWhereGroups = array of TWhereGroup;

  // DIKKAT: `TTableRef` burada OLMAMALI: hicbir birimde kullanilmiyor
  // (ol kod) ve VDbTable kendi kopyasini tanimliyor.

  // --- FK listesi ---
  // NOT: `array of TFkDef` bir OPEN ARRAY parametresidir ve dinamik
  // diziden (cagiran tarafta `array of TFkDef`) open array'a gecis
  // FPC'de HICBIR SEKILDE calismaz: ne `const` ne `var` ile.
  // ("Got {Dynamic} Array Of TFkDef, expected {Open} Array Of TFkDef"
  //  / "Call by var for arg no. 5 has to match exactly")
  // Bu yuzden ayri bir dinamik dizi tipi gerekiyor (VDbJson kullanir).
  TFkArray = array of TFkDef;

  // --- F-36 TRIGGER ---
  TTriggerEvent = (teInsert, teUpdate, teDelete);
  TTriggerTiming = (ttBefore, ttAfter, ttInsteadOf);
  TTriggerForEach = (tfRow, tfStatement);

  // Trigger tanimi. VDbTable bu kaydi katalogda saklar; govde ve WHEN
  // ifadesi AST tipindedir, bu yuzden TObject olarak tutulur (TFunctionDef
  // ile ayni gerekce: VDbTypes -> VDbAst dongusu olmamali).
  // ASHLIK BIRAKILMA SARTI: Body ve WhenCondition sahiplik katalogdadir;
  // DropTrigger ve Close serbest birakir.
  TTriggerDef = record
    Name: string;             // tetikleyici adi (global benzersiz)
    TableName: string;        // bagli tablo
    Timing: Byte;             // TTriggerTiming
    ForEach: Byte;            // TTriggerForEach
    Events: array of Byte;    // TTriggerEvent degerleri
    WhenCondition: TObject;   // TSqlExprNode (nil ise kosul yok)
    Body: TObject;            // TSqlStmtNode
  end;

  // NOT: TFunctionParameter burada TObject ile tanimlidir. Varsayilan
  // ifadesi AST (TSqlExprNode) tipindedir; Pointer'a cast etmek tip
  // guvenligini kaybettirir. VDbTable bu kaydi katalogda sakladigi icin
  // VDbAst'a bagimli olamaz (dongu). VDbAst bu kaydi TUpdateAssignment
  // gibi takma adla tekrar kullanir.
  TFunctionParameter = record
    Name: string;
    TypeName: string;
    Mode: Byte; // 0=IN, 1=OUT, 2=INOUT
    DefaultExpr: TObject; // TSqlExprNode (AST tipi)
  end;

  // --- F-35 fonksiyon/prosedur tanimi ---
  TFunctionParamArray = array of TFunctionParameter;
  TFunctionDef = record
    Name: string;
    Parameters: array of TFunctionParameter;
    ReturnType: string;
    Language: string;
    Body: TObject;          // TSqlStmtNode (AST tipi)
    IsFunction: Boolean;
  end;

  // R-03: UPSERT - SET ifadesi atamasi
  TUpdateAssignment = record
    ColName: string;
    Expr: TObject; // TSqlExprNode (AST tipi)
  end;

implementation

end.
