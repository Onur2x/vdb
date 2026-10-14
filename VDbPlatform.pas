unit VDbPlatform;

{ R-23 Cross-Platform DLL / C API — platform soyutlamasi.

  AMAC
  ----
  `vdbapi` paylasilan kutuphanesi Windows'ta `vdbapi.dll`, Linux'ta
  `libvdbapi.so`, macOS'ta `libvdbapi.dylib` olur. Istemci kodunun bu
  adlari platforma gore elle secmesi hataya aciktir. Bu birim:

    1) Calisma zamanindaki isletim sistemini tespit eder (VdbCurrentOS).
    2) Her OS icin DOGRU paylasilan kutuphane adini uretir
       (VdbSharedLibName) — derleme-anindan bagimsiz oldugu icin
       TUM platformlar tek makinede test edilebilir.
    3) RTL'in `dynlibs` birimiyle (Windows/Linux/macOS ortak) dinamik
       yukleme yardimcilari sunar (VdbLibTryLoad / VdbLibProc /
       VdbLibUnload).

  NOT: Bu birim SAF RTL'dir; `Windows` birimini KULLANMAZ ve LazUtils'e
  bagimli DEGILDIR. Bu yuzden `fpc` ile Linux/macOS'ta dogrudan derlenir.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  { Kisa sure olcumu icin platform-nötr tik (milisaniye). Windows'ta
    GetTickCount64, diger platformlarda duvar saati farkindan hesaplanir.
    TUM motor birimleri bunu kullanmali: boylece Linux/macOS derlemesinde
    Windows'a ozgu GetTickCount64 bagimliligi kalmaz. }
  TVDbTick = QWord;
  { Desteklenen isletim sistemleri. Derleme-anindan bagimsiz test icin
    enum'a cevrildi. }
  TVDbOS = (osWindows, osLinux, osMacOS, osFreeBSD, osUnknown);

  { DIKKAT: `TStrArray` adi VDbTypes'te de var; burada AYNI ad
    kullanilirsa FPC ikinci tanimi FARKLI tip yapar ve baska birimlerin
    metot imzalari bozulur. Bu yuzden bu birimde farkli ad kullanilir. }
  TVdbStrArray = array of string;

const
  { Varsayilan kutuphane taban adi (on ek/sonek platforma gore eklenir). }
  VDB_SO_NAME = 'vdbapi';

  { C ABI surumu: major.minor.patch. vdbapi_core.pas ile AYNI olmali. }
  VDB_API_VERSION = $00010200;   // 1.2

{ Calisma zamanindaki isletim sistemi. }
function VdbCurrentOS: TVDbOS;

{ Platform-nötr milisaniye tiki (kisa sure olcumu). Windows'ta
  GetTickCount64, diger platformlarda Now farki. }
function VdbTickMs: QWord;

{ Bir OS icin paylasilan kutuphane dosya adi:
    osWindows -> vdbapi.dll
    osLinux   -> libvdbapi.so
    osMacOS   -> libvdbapi.dylib
    osFreeBSD -> libvdbapi.so
  osUnknown -> Windows adi (guvenli varsayilan).
  ABase bos ise VDB_SO_NAME kullanilir. }
function VdbSharedLibName(const ABase: string; AOS: TVDbOS): string;

{ VdbCurrentOS icin pratik ad. }
function VdbSharedLibNameDefault(const ABase: string): string;

{ Yukleyicinin sirayla deneyecegi aday adlar (ilk eleman = birincil ad).
  Ornek (Linux): ['libvdbapi.so', 'vdbapi.so']; (macOS):
  ['libvdbapi.dylib', 'libvdbapi.so']. }
function VdbSharedLibCandidates(const ABase: string; AOS: TVDbOS): TVdbStrArray;

{ Aday adlari sirayla deneyerek kutuphaneyi yukler. Basarili olursa
  True ve AHandle <> NilHandle; APath basarili aday adidir. }
function VdbLibTryLoad(const ABase: string; out AHandle: TLibHandle;
  out APath: string): Boolean;

{ Yuklu kutuphaneden bir sembol cozer; bulunamazsa nil. }
function VdbLibProc(AHandle: TLibHandle; const AName: string): Pointer;

{ R-21: TAM bir dosya yolundan (uzanti dahil) kutuphane yukler; aday
  uretmez. Genelde `VdbLibTryLoad` (taban ad) yeterlidir; bu fonksiyon
  extension'in `FROM 'yol'` ile ACIK bir dosyayi yuklemesi icindir. }
function VdbLibTryLoadFile(const AFileName: string; out AHandle: TLibHandle;
  out APath: string): Boolean;

{ Kutuphaneyi bosaltir (NilHandle ise no-op). }
procedure VdbLibUnload(var AHandle: TLibHandle);

implementation

uses
  {$IFDEF MSWINDOWS} Windows, {$ENDIF}
  dynlibs;

function VdbTickMs: QWord;
begin
  {$IFDEF MSWINDOWS}
  Result := GetTickCount64;
  {$ELSE}
  { Unix: duvar saati farki (milisaniye). Kısa sureler icin yeterli;
    Linux'ta Now mikro-saniye cozunurlukludur. }
  Result := QWord(Round(Now * MSecsPerDay));
  {$ENDIF}
end;

function VdbCurrentOS: TVDbOS;
begin
  {$IF defined(MSWINDOWS)}
  Result := osWindows;
  {$ELSEIF defined(DARWIN)}
  Result := osMacOS;
  {$ELSEIF defined(LINUX)}
  Result := osLinux;
  {$ELSEIF defined(FREEBSD)}
  Result := osFreeBSD;
  {$ELSE}
  Result := osUnknown;
  {$ENDIF}
end;

function VdbSharedLibName(const ABase: string; AOS: TVDbOS): string;
var
  B: string;
begin
  if ABase = '' then B := VDB_SO_NAME else B := ABase;
  case AOS of
    osWindows: Result := B + '.dll';
    osLinux:   Result := 'lib' + B + '.so';
    osMacOS:   Result := 'lib' + B + '.dylib';
    osFreeBSD: Result := 'lib' + B + '.so';
  else
    Result := B + '.dll';
  end;
end;

function VdbSharedLibNameDefault(const ABase: string): string;
begin
  Result := VdbSharedLibName(ABase, VdbCurrentOS);
end;

function VdbSharedLibCandidates(const ABase: string; AOS: TVDbOS): TVdbStrArray;
var
  B: string;
begin
  if ABase = '' then B := VDB_SO_NAME else B := ABase;
  case AOS of
    osWindows:
      begin
        SetLength(Result, 1);
        Result[0] := B + '.dll';
      end;
    osMacOS:
      begin
        SetLength(Result, 3);
        Result[0] := 'lib' + B + '.dylib';
        Result[1] := B + '.dylib';
        Result[2] := 'lib' + B + '.so';   // Homebrew/cross fallback
      end;
    osLinux, osFreeBSD:
      begin
        SetLength(Result, 2);
        Result[0] := 'lib' + B + '.so';
        Result[1] := B + '.so';
      end;
  else
    begin
      SetLength(Result, 1);
      Result[0] := B + '.dll';
    end;
  end;
end;

function VdbLibTryLoad(const ABase: string; out AHandle: TLibHandle;
  out APath: string): Boolean;
var
  Names: TVdbStrArray;
  I: Integer;
  H: TLibHandle;
begin
  Result := False;
  AHandle := NilHandle;
  APath := '';
  Names := VdbSharedLibCandidates(ABase, VdbCurrentOS);
  for I := 0 to High(Names) do
  begin
    H := dynlibs.LoadLibrary(Names[I]);
    if H <> NilHandle then
    begin
      AHandle := H;
      APath := Names[I];
      Exit(True);
    end;
  end;
end;

function VdbLibProc(AHandle: TLibHandle; const AName: string): Pointer;
begin
  Result := nil;
  if AHandle = NilHandle then Exit;
  Result := dynlibs.GetProcedureAddress(AHandle, AName);
end;

function VdbLibTryLoadFile(const AFileName: string; out AHandle: TLibHandle;
  out APath: string): Boolean;
var
  H: TLibHandle;
begin
  Result := False;
  AHandle := NilHandle;
  APath := '';
  if AFileName = '' then Exit;
  H := dynlibs.LoadLibrary(AFileName);
  if H <> NilHandle then
  begin
    AHandle := H;
    APath := AFileName;
    Result := True;
  end;
end;

procedure VdbLibUnload(var AHandle: TLibHandle);
begin
  if AHandle <> NilHandle then
  begin
    dynlibs.UnloadLibrary(AHandle);
    AHandle := NilHandle;
  end;
end;

end.
