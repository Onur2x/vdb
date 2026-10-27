unit VDbSync;

{$mode delphi}

interface

uses
  Classes;

procedure VDbFlushStream(S: TFileStream);
// Dizin girdisini (dosya olusturma/rename/silme) kalici hale getirir.
// F2-1: ONCEDEN hatalar TAMAMEN YUTULUYORDU (Unix'te FpOpen ve
// FpFsync hatalari kontrol edilmiyordu). Artik sonuc dondurur:
//   True  = dizin girdisi kalici (veya Windows: islem gerekmiyor)
//   False = dizin fsync yapilamadi -> rename/silme kalici OLMAYABILIR
// cagiran taraf bunu loglayip karar vermelidir (bkz. VDbCore.ReplaceWith).
function VDbFlushDir(const DirPath: string): Boolean;
// Ayni dosyayi ikinci kez acmayi engeller (cift-yazma bozulmasina karsi).
// Unix'te flock, Windows'ta LockFileEx. Kilit alinamazsa False.
// AShared=True ise PAYLASIMLI kilit alinir: birden cok salt-okunur okuyucu
// ayni anda tutabilir, yazar (tam kilit) hepsinin bitmesini bekler.
// v3.2: cok okuyucu / tek yazici.
// v3.18 DUZELTME — OZ-KILITLENME (olculdu: prochk, 20 703 ms EX? / err=33).
// Windows'ta bir surec KENDI paylasimli kilidini tam kilide YUKSELTEMEZ:
// ayni handle uzerinde LockFileEx(EX) ERROR_LOCK_VIOLATION (33) verir.
// Ayrica motorun dagitik boolean defteri (FLockedShared) ile isletim
// sisteminin gercek kilit durumu ayrisma biliyordu: defter "kilit yok"
// derken OS'te paylasimli kilit duruyor ve yazar 20 s bekliyordu.
// Cozum: kilit defteri BURADA, handle basina tutulur; OS kilit durumu
// her zaman bu defterle BIREBIR ayni kalir:
//   * ayni handle'da SH varken SH istenirse -> OS'e DOKUNULMAZ (idempotent)
//   * ayni handle'da EX varken SH istenirse -> True (EX, SH'yi kapsar)
//   * ayni handle'da SH varken EX istenirse -> once SH bırakılır (yukseltme)
//   * EX varken EX istenirse -> True
// VDbUnlockStream her durumda guvenli: tutulan kilidi bir kez birakir.
function VDbLockStream(S: TFileStream; AShared: Boolean = False): Boolean;
procedure VDbUnlockStream(S: TFileStream);
// Bu handle uzerinde BIZIM tuttugumuz kilit var mi (teshis/kapi icin).
function VDbLockHeld(S: TFileStream; out AShared: Boolean): Boolean;

{ v3.18: DEGISIKLIK SAYACI (<db>.gen) REZERVASYON kilidi.
  NEDEN AYRI: VDbLockStream Windows'ta TUM dosyayi (offset 0, 2^64 bayt)
  kilitler ve LockFileEx TAM kilidi baska surecin OKUMASINI da reddeder.
  Sayac dosyasinin ilk 8 baytini okuyan herhangi bir oturum bu yuzden
  EReadError aliyordu (lockchk bolum 3b bunu yakaladi: acik yazma islemi
  tutan yazar, RO oturumun acilisini "Stream read error" ile dusuruyordu).
  Cozum: rezervasyon kilidi sayac VERISINDEN UZAK bir bayt araligina
  ([VDB_GEN_LOCK_OFF, +1)) alinir; boylece offset 0'daki 8 bayt her zaman
  okunabilir. Windows'ta aralik kilidi gercekten araliktir; Unix'te flock
  aralik desteklemez ama ZATEN danismalidir (advisory) - okumayi
  engellemez, yazarlari yine siraya sokar. Platform bagimsiz sonuc ayni. }
const
  VDB_GEN_LOCK_OFF = $00010000;   // 64 KiB: sayac verisinin cok otesinde
function VDbLockGenReserve(S: TFileStream): Boolean;
procedure VDbUnlockGenReserve(S: TFileStream);

// 2026-10-25 (Sprint 3.10): CANLI dosyanin boyunu KILIT ALMADAN ogrenir.
// Neden: Unix'te FPC'nin TFileStream'i paylasim moduna gore flock() uygular;
// motor dosyayi LOCK_EX ile tuttugu icin ayni dosyayi IKINCI kez acmak
// (salt-okunur boy olcumu bile) EAGAIN/"Try again" verir. Windows'ta bu
// sorun gorunmez (paylasimli okuma serbest). Bu yuzden boy olcumu acmaz,
// stat() kullanir. Dosya yoksa -1 doner.
function VDbFileBytes(const Path: string): Int64;

// 2026-10-04: "dosya baska islemde acik" ayrimini yapar.
// Windows'ta paylasim ihlali ERROR_SHARING_VIOLATION (32) veya
// ERROR_LOCK_VIOLATION (33) kodunu verir; FPC bunu EFOpenError
// icine sarar. Bu ayrim olmadan motor, kilitli dosyada kendi
// hata kodunu (ecDatabaseLocked) uretemiyor ve cagirici anlamsiz bir
// dosya hatasi aliyor.
//
// NOT: parametre TObject olarak alinir; bu birim SysUtils'i
// implementation'da kullandigi icin arayuzde `Exception` gorunmez.
// Dogru tipte (Exception) bir nesne gecmek zorunda oldugu icin bu
// guvenli bir kisitlamadir.
function VDbIsSharingViolation(const E: TObject): Boolean;

const
  { F3-3: POSIX flock bayraklari. Once dogrudan sayi yaziliyordu
    (2 or 4 ve 8); yanlislari sessizce "kilit alinamadi" gibi gorunuyordu. }
  VDB_LOCK_SH  = 1;   // LOCK_SH  - paylasimli kilit (cok okuyucu)
  VDB_LOCK_EX  = 2;   // LOCK_EX  - tam kilit
  VDB_LOCK_NB  = 4;   // LOCK_NB  - bekleme, hemen sonuc
  VDB_LOCK_UN  = 8;   // LOCK_UN  - kilidi birak

implementation

uses
  SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  { FpFsync/FpFlock BaseUnix'te YOK; Unix biriminde bildirilir (FPC 3.2.x).
    BaseUnix FpOpen/FpClose sabitleri icin korunur. }
  {$IFDEF UNIX}, BaseUnix, Unix{$ENDIF};

const
  VDB_LOCK_SLOTS = 64;

type
  TVDbLockSlot = record
    Handle: NativeUInt;
    Shared: Boolean;
    Held: Boolean;
  end;

var
  GLockCs: TRTLCriticalSection;
  GLockInit: Boolean = False;
  GLockSlots: array[0..VDB_LOCK_SLOTS - 1] of TVDbLockSlot;

procedure LockBookInit;
begin
  if GLockInit then Exit;
  InitCriticalSection(GLockCs);
  GLockInit := True;
end;

function LockSlotOf(AHandle: NativeUInt; ACreate: Boolean): Integer;
var
  i, bos: Integer;
begin
  Result := -1;
  bos := -1;
  for i := 0 to VDB_LOCK_SLOTS - 1 do
  begin
    if GLockSlots[i].Held and (GLockSlots[i].Handle = AHandle) then
      Exit(i);
    if (not GLockSlots[i].Held) and (bos < 0) then
      bos := i;
  end;
  if ACreate then
  begin
    if bos < 0 then
      raise Exception.Create('VDbSync: kilit defteri dolu (cok fazla acik handle)');
    GLockSlots[bos].Handle := AHandle;
    GLockSlots[bos].Shared := False;
    GLockSlots[bos].Held := False;
    Result := bos;
  end;
end;

function VDbLockHeld(S: TFileStream; out AShared: Boolean): Boolean;
var
  idx: Integer;
begin
  AShared := False;
  Result := False;
  if S = nil then Exit;
  LockBookInit;
  EnterCriticalSection(GLockCs);
  try
    idx := LockSlotOf(S.Handle, False);
    if idx >= 0 then
    begin
      Result := GLockSlots[idx].Held;
      AShared := GLockSlots[idx].Shared;
    end;
  finally
    LeaveCriticalSection(GLockCs);
  end;
end;

procedure VDbFlushStream(S: TFileStream);
begin
  if S = nil then Exit;
  {$IFDEF WINDOWS}
  if not Windows.FlushFileBuffers(S.Handle) then
    RaiseLastOSError;
  {$ELSE}
    {$IFDEF UNIX}
    if FpFsync(S.Handle) <> 0 then
      RaiseLastOSError;
    {$ELSE}
    S.Flush;
    {$ENDIF}
  {$ENDIF}
end;

function VDbFlushDir(const DirPath: string): Boolean;
{$IFDEF UNIX}
var
  fd: cint;
  ok: Boolean;
{$ENDIF}
begin
  // Windows: NTFS gunluk sistemi dosya adi/dizin guncellemelerini atomik
  // yonetir; ayrica bir islem gerekmez.
  Result := True;
  if DirPath = '' then Exit;
  {$IFDEF UNIX}
  fd := FpOpen(PChar(DirPath), O_RDONLY);
  if fd < 0 then
  begin
    // F2-1: once bu durum sessizce yutuluyordu. Dizin acilamiyorsa
    // kalicilik garanti EDILEMEZ; False don.
    Exit(False);
  end;
  ok := False;
  try
    ok := FpFsync(fd) = 0;   // F2-1: FpFsync sonucu kontrol ediliyor
  finally
    FpClose(fd);
  end;
  Result := ok;
  {$ENDIF}
end;

function VDbLockStream(S: TFileStream; AShared: Boolean): Boolean;
{$IFDEF WINDOWS}
var
  ov: TOverlapped;
  flags: LongWord;
  idx: Integer;
{$ENDIF}
begin
  Result := False;
  if S = nil then Exit;
  {$IFDEF WINDOWS}
  LockBookInit;
  EnterCriticalSection(GLockCs);
  try
    idx := LockSlotOf(S.Handle, True);
    { 1) Defterde zaten kilit varsa OS'e DOKUNMA (cift kilit sizintisi ve
         kendi kendini bloklama buradan geliyordu). }
    if GLockSlots[idx].Held then
    begin
      if GLockSlots[idx].Shared and (not AShared) then
      begin
        { 2) YUKSELTME: paylasimliyi birak, sonra tam kilidi iste.
            Windows ayni handle'da SH -> EX yukseltmesine IZIN VERMEZ. }
        FillChar(ov, SizeOf(ov), 0);
        Windows.UnlockFileEx(S.Handle, 0, $FFFFFFFF, $FFFFFFFF, @ov);
        GLockSlots[idx].Held := False;
        GLockSlots[idx].Shared := False;
      end
      else
      begin
        { Paylasimli istek: SH veya EX yeterli. Tam istek + EX zaten var. }
        Result := True;
        Exit;
      end;
    end
    ;
    FillChar(ov, SizeOf(ov), 0);
    if AShared then flags := LOCKFILE_FAIL_IMMEDIATELY
    else flags := LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY;
    Result := Windows.LockFileEx(S.Handle, flags, 0,
      $FFFFFFFF, $FFFFFFFF, @ov);
    if Result then
    begin
      GLockSlots[idx].Held := True;
      GLockSlots[idx].Shared := AShared;
    end
    else
    begin
    end;
  finally
    LeaveCriticalSection(GLockCs);
  end;
  {$ELSE}
    {$IFDEF UNIX}
    if AShared then
      Result := FpFlock(S.Handle, VDB_LOCK_SH or VDB_LOCK_NB) = 0
    else
      Result := FpFlock(S.Handle, VDB_LOCK_EX or VDB_LOCK_NB) = 0;
    {$ELSE}
    Result := True;
    {$ENDIF}
  {$ENDIF}
end;

procedure VDbUnlockStream(S: TFileStream);
{$IFDEF WINDOWS}
var
  ov: TOverlapped;
  idx: Integer;
{$ENDIF}
begin
  if S = nil then Exit;
  {$IFDEF WINDOWS}
  LockBookInit;
  EnterCriticalSection(GLockCs);
  try
    { v3.18 DUZELTME: defterde kilit YOKSA OS'e hic dokunma. Onceden her
      cagri kosulsuz UnlockFileEx yapiyordu; defter ile OS ayrisabiliyor,
      sonra yazar kendi (hayalet) paylasimli kilidi yuzunden 20 s bekliyordu. }
    idx := LockSlotOf(S.Handle, False);
    if (idx < 0) or (not GLockSlots[idx].Held) then Exit;
    FillChar(ov, SizeOf(ov), 0);
    Windows.UnlockFileEx(S.Handle, 0, $FFFFFFFF, $FFFFFFFF, @ov);
    GLockSlots[idx].Held := False;
    GLockSlots[idx].Shared := False;
  finally
    LeaveCriticalSection(GLockCs);
  end;
  {$ELSE}
  {$IFDEF UNIX}
  FpFlock(S.Handle, VDB_LOCK_UN);
  {$ENDIF}
  {$ENDIF}
end;

function VDbLockGenReserve(S: TFileStream): Boolean;
{$IFDEF WINDOWS}
var
  ov: TOverlapped;
{$ENDIF}
begin
  Result := False;
  if S = nil then Exit;
  {$IFDEF WINDOWS}
  FillChar(ov, SizeOf(ov), 0);
  ov.Offset := VDB_GEN_LOCK_OFF;
  ov.OffsetHigh := 0;
  { 1 bayt: yalniz offset VDB_GEN_LOCK_OFF. Sayac verisi (offset 0..7)
    KILITLI DEGIL, dolayisiyla tum oturumlar okuyabilir. }
  Result := Windows.LockFileEx(S.Handle,
    LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, @ov);
  {$ELSE}
    {$IFDEF UNIX}
    { flock aralik desteklemez; butun dosya kilitlenir ama advisory oldugu
      icin okumayi ENGELLEMEZ, yalniz diger yazarlari siraya sokar. }
    Result := FpFlock(S.Handle, VDB_LOCK_EX or VDB_LOCK_NB) = 0;
    {$ELSE}
    Result := True;
    {$ENDIF}
  {$ENDIF}
end;

procedure VDbUnlockGenReserve(S: TFileStream);
{$IFDEF WINDOWS}
var
  ov: TOverlapped;
{$ENDIF}
begin
  if S = nil then Exit;
  {$IFDEF WINDOWS}
  FillChar(ov, SizeOf(ov), 0);
  ov.Offset := VDB_GEN_LOCK_OFF;
  ov.OffsetHigh := 0;
  Windows.UnlockFileEx(S.Handle, 0, 1, 0, @ov);
  {$ELSE}
  {$IFDEF UNIX}
  FpFlock(S.Handle, VDB_LOCK_UN);
  {$ENDIF}
  {$ENDIF}
end;

function VDbFileBytes(const Path: string): Int64;
{$IFDEF UNIX}
var
  st: Stat;
begin
  if FpStat(PChar(Path), st) <> 0 then
    Result := -1
  else
    Result := st.st_size;
end;
{$ELSE}
var
  fs: TFileStream;
begin
  Result := -1;
  if not FileExists(Path) then Exit;
  try
    fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Result := fs.Size;
    finally
      fs.Free;
    end;
  except
    Result := -1;
  end;
end;
{$ENDIF}

function VDbIsSharingViolation(const E: TObject): Boolean;
var
  Code: Integer;
begin
  Result := False;
  if E = nil then Exit;
  {$IFDEF WINDOWS}
  // Sadece dosya ACILIS hatalarina bak; ayni kod baska bir yerde de
  // donse bile "kilitli" demek bu yol icin yeterince guvenli.
  Code := GetLastError;
  Result := (Code = 32) or (Code = 33);   // SHARING_VIOLATION / LOCK_VIOLATION
  {$ELSE}
  {$IFDEF UNIX}
  { FPC'nin Unix hata metni glibc'ten FARKLI: EAGAIN icin "Try again",
    EACCES icin "Permission denied" yazar. flock cakismasi EAGAIN
    ("Try again") olarak gelir; "Resource temporarily unavailable"
    metnine guvenmek Linux'ta bu ayrimi kaciriyordu (2026-10-25). }
  if E is Exception then
    Result := Exception(E).Message.Contains('Resource temporarily unavailable') or
              Exception(E).Message.Contains('Resource busy') or
              Exception(E).Message.Contains('Try again') or
              Exception(E).Message.Contains('Device or resource busy');
  {$ENDIF}
  {$ENDIF}
end;

end.

