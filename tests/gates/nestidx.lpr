program nestidx;

{ VDB v3 - R3 kapisi: FIdxBuildCs <-> FEngCs ters cevrilmesi.

  SORUN (EK-I.3/EK-I.4 R3): kilit sirasi
    FLock -> FIdxBuildCs -> FEngCs -> FIdxCs
  seklindedir. Ic ice akis (nested stream) alt sorgusu FEngCs TUTULURKEN
  tembel indeks insasina girerse FIdxBuildCs istenir; baska bir is parcacigi
  FIdxBuildCs tutup FEngCs bekliyorsa ABBA kilitlenmesi olusur.

  BU KAPI: gercek ters cevrilmeyi DETERMINISTIK olarak kurar.
    1) A is parcacigi motorun ham taramasini baslatir (ScanRawIterAll).
       Bu cagri FEngCs'i tarama boyunca tutar. Geri cagirim ilk satirda
       durur ve ana parcaciga "FEngCs bende" der.
    2) B is parcacigi b tablosunun w indeksini tembel kurmaya calisir:
       FIdxBuildCs'i alir, indeks taramasi icin FEngCs bekler (A tutuyor).
    3) Ana parcacik A'yi serbest birakir; A alt sorgu gibi davranip b
       tablosunun k indeksini ister (FIdxBuildCs).
       -> duzeltme YOKSA: A FIdxBuildCs'te, B FEngCs'te bekler: KILITLENME.
       -> duzeltme VARSA: A, FEngCs tutulurken insa YAPMAZ; istegi False
          doner (cagiran tam taramaya duser), B ilerler.

  Zaman asimi 20 sn'dir (normal islem < 1 sn). Kilitlenmede kapi kendi
  kendine 20 sn sonra duser ve surec Halt(1) ile cikar.

  Cikis kodu: 0 = ters cevrilme engellendi, 1 = kilitlenme/hata.
  Kullanim: nestidx <calisma_dizini>
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: cthreads programin EN BASINDA olmali. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, SyncObjs,
  VDbBackendApi, VDbBackendV3, VDbPageStore, VDbTable, VDbSql;

const
  NEST_BUSY_MS  = 15000;
  NEST_ROWS_A   = 64;
  NEST_ROWS_B   = 256;
  NEST_START_MS = 5000;    // A taramasi FEngCs'i alana kadar
  NEST_GRACE_MS = 700;     // B'nin FIdxBuildCs alip FEngCs'te beklemesi icin
  NEST_TIMEOUT  = 20000;   // toplam islem siniri (> normal islem suresi)

var
  gDir: string;
  gPass, gFail: Integer;
  gDoneCount: LongInt;
  gDone: TEvent;

procedure Ok(const S: string);
begin
  Inc(gPass);
  WriteLn('   OK   ', S);
end;

procedure Fail(const S: string);
begin
  Inc(gFail);
  WriteLn('   FAIL ', S);
end;

function DirOf(const N: string): string;
begin
  Result := IncludeTrailingPathDelimiter(gDir) + N;
end;

{ Ayni dizinde onceki kosudan kalan dosyalari siler. Repo kokunu asla
  supurmez (concurchk / backendchk ile ayni koruma). }
procedure CleanDir;
var
  sr: TSearchRec;
  base: string;
begin
  if gDir = '' then Exit;
  if FileExists(IncludeTrailingPathDelimiter(gDir) + 'VDbCore.pas') then Exit;
  base := IncludeTrailingPathDelimiter(gDir);
  if FindFirst(base + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        if (sr.Attr and faDirectory) = 0 then
          DeleteFile(base + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

type
  { Iki is parcaciginin paylastigi baglam. Events ana parcacikta kurulur
    ve serbest birakilir; is parcaciklari yalnizca bekler/isaretler. }
  PNestCtx = ^TNestCtx;
  TNestCtx = record
    Tb: TVTableDb;
    TidB: Word;
    KCol: Integer;      // hedef: ic ice istekte istenen (kurulmamis) indeks
    WCol: Integer;      // B'nin tembel kurdugu (baska) indeks
    Entered: TEvent;    // A: FEngCs alindi
    Proceed: TEvent;    // ana: A devam etsin
    Synced: Boolean;
    ARes: Boolean;      // A'nin ic ice istegi
    BRes: Boolean;      // B'nin tembel insasi
    AErr: string;
    BErr: string;
    SrcA: TIdxSource;
    SrcB: TIdxSource;
  end;

function NestRawCb(Key: QWord; Buf: PByte; Len: Integer;
  User: Pointer): Boolean;
{ A is parcacigi: bu geri cagirim FEngCs TUTULURKEN calisir. Ilk satirda
  durup ana parcaciga haber verir; sonra alt sorgu gibi davranip FIdxBuildCs
  isteyen bir indeks erisimi yapar. }
var
  C: PNestCtx;
begin
  Result := True;
  C := User;
  if C^.Synced then Exit;
  C^.Synced := True;
  C^.Entered.SetEvent;
  C^.Proceed.WaitFor(INFINITE);
  try
    C^.ARes := C^.Tb.TryGetIdxSource(C^.TidB, C^.KCol, C^.SrcA);
  except
    on E: Exception do
      C^.AErr := E.ClassName + ': ' + E.Message;
  end;
end;

procedure SignalDone;
begin
  if InterlockedIncrement(gDoneCount) >= 2 then
    gDone.SetEvent;
end;

type
  TNestScanWorker = class(TThread)
  private
    FBe: TVdbBackendV3;
    FTidA: Word;
    FCtx: PNestCtx;
  protected
    procedure Execute; override;
  public
    constructor Create(ABe: TVdbBackendV3; ATidA: Word; ACtx: PNestCtx);
  end;

constructor TNestScanWorker.Create(ABe: TVdbBackendV3; ATidA: Word;
  ACtx: PNestCtx);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FBe := ABe;
  FTidA := ATidA;
  FCtx := ACtx;
end;

procedure TNestScanWorker.Execute;
begin
  try
    if not FBe.ScanRawIterAll(FTidA, NestRawCb, FCtx) then
      if FCtx^.AErr = '' then
        FCtx^.AErr := 'tarama False dondu';
  except
    on E: Exception do
      FCtx^.AErr := E.ClassName + ': ' + E.Message;
  end;
  SignalDone;
end;

type
  TNestBuildWorker = class(TThread)
  private
    FCtx: PNestCtx;
  protected
    procedure Execute; override;
  public
    constructor Create(ACtx: PNestCtx);
  end;

constructor TNestBuildWorker.Create(ACtx: PNestCtx);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCtx := ACtx;
end;

procedure TNestBuildWorker.Execute;
begin
  { FIdxBuildCs alinir; indeks taramasi (ScanAll) FEngCs bekler. A hala
    FEngCs'i tutuyorsa burada BLOKLANIR - istenen durum budur. }
  try
    FCtx^.BRes := FCtx^.Tb.TryGetIdxSource(FCtx^.TidB, FCtx^.WCol, FCtx^.SrcB);
  except
    on E: Exception do
      FCtx^.BErr := E.ClassName + ': ' + E.Message;
  end;
  SignalDone;
end;

function ColIndex(const T: TTableDef; const Col: string): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(T.Cols) do
    if SameText(T.Cols[i].Name, Col) then
      Exit(i);
end;

var
  Be: IVdbBackend;
  BeV3: TVdbBackendV3;
  Tb1, Tb2: TVTableDb;
  Sq1, Sq2: TVSql;
  R: TSqlResult;
  TdA, TdB: TTableDef;
  Ctx: TNestCtx;
  WA: TNestScanWorker;
  WB: TNestBuildWorker;
  SrcChk: TIdxSource;
  i: Integer;
  WaitRes: TWaitResult;

begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'kullanim: nestidx <dizin>');
    Halt(2);
  end;
  gDir := ParamStr(1);
  ForceDirectories(gDir);
  CleanDir;
  gPass := 0;
  gFail := 0;
  gDoneCount := 0;
  gDone := TEvent.Create(nil, True, False, '');

  { --- 1) Sema + veri; indeksler CREATE aninda kurulur. --- }
  BeV3 := TVdbBackendV3.Create(DirOf('nestidx.db'), True, VDB_DEF_POOL,
    NEST_BUSY_MS);
  Be := BeV3;
  Tb1 := TVTableDb.CreateBackend(Be);
  Tb1.Open(gDir);
  Sq1 := TVSql.Create(Tb1);
  try
    Sq1.Exec('CREATE TABLE a(id INTEGER PRIMARY KEY, x INTEGER)');
    Sq1.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, k INTEGER, w INTEGER)');
    Sq1.Exec('BEGIN');
    for i := 1 to NEST_ROWS_A do
      Sq1.Exec('INSERT INTO a(id,x) VALUES(' + IntToStr(i) + ',' +
        IntToStr(i * 10) + ')');
    for i := 1 to NEST_ROWS_B do
      Sq1.Exec('INSERT INTO b(id,k,w) VALUES(' + IntToStr(i) + ',' +
        IntToStr(i mod 7) + ',' + IntToStr(i mod 11) + ')');
    Sq1.Exec('COMMIT');
    Sq1.Exec('CREATE INDEX ix_b_k ON b(k)');
    Sq1.Exec('CREATE INDEX ix_b_w ON b(w)');
  finally
    FreeAndNil(Sq1);
    Tb1.Close;
    FreeAndNil(Tb1);
  end;

  { --- 2) TAZE TVTableDb: indeksler bellekte YOK (tembel insa gerekir). --- }
  Tb2 := TVTableDb.CreateBackend(Be);
  Tb2.Open(gDir);
  Sq2 := TVSql.Create(Tb2);
  if not Tb2.TryGetTableDef('a', TdA) then
  begin
    WriteLn(StdErr, 'tablo a okunamadi');
    Halt(1);
  end;
  if not Tb2.TryGetTableDef('b', TdB) then
  begin
    WriteLn(StdErr, 'tablo b okunamadi');
    Halt(1);
  end;

  Ctx := Default(TNestCtx);
  Ctx.Tb := Tb2;
  Ctx.TidB := TdB.TableId;
  Ctx.KCol := ColIndex(TdB, 'k');
  Ctx.WCol := ColIndex(TdB, 'w');
  if (Ctx.KCol < 0) or (Ctx.WCol < 0) then
  begin
    WriteLn(StdErr, 'kolon cozulemedi');
    Halt(1);
  end;
  Ctx.Entered := TEvent.Create(nil, True, False, '');
  Ctx.Proceed := TEvent.Create(nil, True, False, '');

  { --- 3) A: FEngCs tutan tarama; B: FIdxBuildCs tutan tembel insa. --- }
  WA := TNestScanWorker.Create(BeV3, TdA.TableId, @Ctx);
  WB := TNestBuildWorker.Create(@Ctx);
  WA.Start;
  if Ctx.Entered.WaitFor(NEST_START_MS) <> wrSignaled then
  begin
    WriteLn('   FAIL A taramasi FEngCs kilidini alamadi');
    Inc(gFail);
    WB.Start;
  end
  else
  begin
    WB.Start;
    { B'nin FIdxBuildCs'i alip FEngCs'te bloklanmasina firsat ver. }
    Sleep(NEST_GRACE_MS);
  end;
  { A alt sorgu gibi davranip k indeksini istesin (hata yolunda da
    geri cagirimi serbest birak; done sayaci tamamlansin). }
  Ctx.Proceed.SetEvent;

  WaitRes := gDone.WaitFor(NEST_TIMEOUT);
  if WaitRes <> wrSignaled then
  begin
    { KILITLENME: A FIdxBuildCs bekliyor, B FEngCs bekliyor.
      Is parcaciklari sonsuza dek bloklu; sureci buradan kapat. }
    WriteLn('   FAIL KILITLENME: FEngCs <-> FIdxBuildCs ters cevrilmesi');
    WriteLn('SONUC: gecen=0 kalan=1');
    WriteLn('IC ICE INDEKS KILIDI: KILITLENME');
    Halt(1);
  end;

  if Ctx.AErr <> '' then Fail('A: ' + Ctx.AErr) else
  begin
    { Duzeltme: FEngCs tutulurken tembel insa YAPILMAZ -> False doner. }
    if Ctx.ARes then
      Fail('A ic ice istek True dondu (insa FEngCs altinda yapilmis)')
    else
      Ok('A: FEngCs tutulurken tembel insa atlandi (False)');
  end;

  if Ctx.BErr <> '' then Fail('B: ' + Ctx.BErr) else
  begin
    if Ctx.BRes then
      Ok('B: tembel insa (FIdxBuildCs -> FEngCs) tamamlandi')
    else
      Fail('B: tembel insa beklenmedik sekilde False');
  end;

  { --- 4) Insa hala mumkun: A bittikten sonra normal istek kurar. --- }
  try
    if Tb2.TryGetIdxSource(TdB.TableId, Ctx.KCol, SrcChk) then
      Ok('k indeksi A bittikten sonra normal yolda kuruldu')
    else
      Fail('k indeksi normal yolda kurulamadi');
  except
    on E: Exception do
      Fail('k indeksi normal yol: ' + E.ClassName + ': ' + E.Message);
  end;

  WA.Free;
  WB.Free;
  Ctx.Entered.Free;
  Ctx.Proceed.Free;
  FreeAndNil(Sq2);
  Tb2.Close;
  FreeAndNil(Tb2);
  Be := nil;
  BeV3 := nil;
  gDone.Free;

  WriteLn('SONUC: gecen=', gPass, ' kalan=', gFail);
  if gFail = 0 then
  begin
    WriteLn('IC ICE INDEKS KILIDI DOGRULANDI');
    Halt(0);
  end;
  Halt(1);
end.
