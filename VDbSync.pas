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
function VDbLockStream(S: TFileStream; AShared: Boolean = False): Boolean;
procedure VDbUnlockStream(S: TFileStream);

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
{$ENDIF}
begin
  Result := False;
  if S = nil then Exit;
  {$IFDEF WINDOWS}
  FillChar(ov, SizeOf(ov), 0);
  if AShared then flags := LOCKFILE_FAIL_IMMEDIATELY
  else flags := LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY;
  Result := Windows.LockFileEx(S.Handle, flags, 0,
    $FFFFFFFF, $FFFFFFFF, @ov);
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
{$ENDIF}
begin
  if S = nil then Exit;
  {$IFDEF WINDOWS}
  FillChar(ov, SizeOf(ov), 0);
  Windows.UnlockFileEx(S.Handle, 0, $FFFFFFFF, $FFFFFFFF, @ov);
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

