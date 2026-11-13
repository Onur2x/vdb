unit VDbExtension;

{ R-21 Full: Extension/Plugin Mechanism — GERCEK dinamik .dll / .so /
  .dylib yukleme, kayit defteri ve sembol cozumu.

  TASARIM
  -------
  Bir extension, paylasilan bir kutuphanedir (Windows: `.dll`, Linux/BSD:
  `.so`, macOS: `.dylib`). Gerekli C-ABI sembolleri:

    VdbExtApiVersion : function: LongWord; stdcall;
        ZORUNLU. Extension ABI surumu. Motor `VDB_EXT_API_VERSION`'dan
        KUCUKSE yukleme reddedilir (ileri uyumsuzluk korumasi).

    VdbExtName : function: PAnsiChar; stdcall;
        OPSIYONEL. Kayit defterinde gorunecek ad. Yoksa SQL'de verilen
        ad kullanilir.

    VdbExtDescription : function: PAnsiChar; stdcall;
        OPSIYONEL. `SHOW EXTENSIONS` icin aciklama.

  Yukleme platform-nötrdur: `VDbPlatform.VdbLibTryLoadFile` /
  `VdbLibTryLoad` kullanir (RTL `dynlibs`), yani ayni kod tum
  platformlarda calisir. Harici bir kutuphane GEREKMEZ.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, dynlibs;

const
  { Extension C-ABI surumu (major.minor.patch). }
  VDB_EXT_API_VERSION = $00010000;   // 1.0

  { Extension'larin kullanmasi gereken sabit giris noktalari. }
  VDB_EXT_SYM_VERSION = 'VdbExtApiVersion';
  VDB_EXT_SYM_NAME    = 'VdbExtName';
  VDB_EXT_SYM_DESC    = 'VdbExtDescription';

type
  TVdbExtVersionFn = function: LongWord; stdcall;
  TVdbExtNameFn    = function: PAnsiChar; stdcall;

  { Yuklu bir extension'in ozeti. }
  TVdbExtensionInfo = record
    Name: string;          // kayitli ad (VdbExtName veya SQL adi)
    FileName: string;      // yuklenen dosya (gercek yol/bicim)
    ApiVersion: LongWord;  // extension'in bildirdigi ABI surumu
    Description: string;
    Handle: TLibHandle;    // dynlibs handle
  end;
  TVdbExtensionInfoArray = array of TVdbExtensionInfo;

{ AName altinda bir extension yukler. APath:
    - bos  -> AName taban adi olarak aranir (VdbSharedLibNameDefault) ve
              calistirilabilir dosyanin dizini denenir.
    - dolu -> once ACIK dosya olarak (VdbLibTryLoadFile), sonra (uzantisiz
              ise) taban ad olarak denenir.
  Basarisizsa False ve AErr'de neden. }
function LoadExtension(const AName, APath: string; out AErr: string): Boolean;

{ Ada gore extension'i bosaltir (case-insensitive). }
function DropExtension(const AName: string): Boolean;

function ExtensionCount: Integer;
function GetExtensionInfo(AIndex: Integer; out AInfo: TVdbExtensionInfo): Boolean;
function ExtensionLoaded(const AName: string): Boolean;

{ Yuklu extension'dan bir sembol cozer (yoksa nil). }
function ExtensionSymbol(const AName, ASymbol: string): Pointer;

procedure UnloadAllExtensions;

implementation

uses
  VDbPlatform;

var
  GExtensions: TVdbExtensionInfoArray;

function NormName(const S: string): string;
begin
  Result := UpperCase(Trim(S));
end;

function IndexOfExt(const AName: string): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(GExtensions) do
    if NormName(GExtensions[i].Name) = NormName(AName) then Exit(i);
end;

function ExtensionLoaded(const AName: string): Boolean;
begin
  Result := IndexOfExt(AName) >= 0;
end;

function ExtensionCount: Integer;
begin
  Result := Length(GExtensions);
end;

function GetExtensionInfo(AIndex: Integer; out AInfo: TVdbExtensionInfo): Boolean;
begin
  AInfo := Default(TVdbExtensionInfo);
  Result := (AIndex >= 0) and (AIndex <= High(GExtensions));
  if Result then AInfo := GExtensions[AIndex];
end;

function ExtensionSymbol(const AName, ASymbol: string): Pointer;
var
  i: Integer;
begin
  Result := nil;
  i := IndexOfExt(AName);
  if i < 0 then Exit;
  Result := VdbLibProc(GExtensions[i].Handle, ASymbol);
end;

function TryLoadRaw(const ABase, APath: string;
  out Handle: TLibHandle; out FileName: string): Boolean;
var
  exeDir, tmp: string;
begin
  Handle := NilHandle;
  FileName := '';
  if APath <> '' then
  begin
    // 1) Acik dosya yolu (uzanti dahil olabilir)
    if VdbLibTryLoadFile(APath, Handle, FileName) then Exit(True);
    // 2) Uzantisiz taban ad gibi davran
    if VdbLibTryLoad(APath, Handle, FileName) then Exit(True);
  end;
  // 3) Calistirilabilir dosyanin yanindaki varsayilan ad
  exeDir := ExtractFilePath(ParamStr(0));
  if exeDir <> '' then
  begin
    tmp := exeDir + VdbSharedLibNameDefault(ABase);
    if FileExists(tmp) and VdbLibTryLoadFile(tmp, Handle, FileName) then Exit(True);
  end;
  // 4) Yalniz taban ad (sistem arama yolu / PATH)
  if VdbLibTryLoad(ABase, Handle, FileName) then Exit(True);
  Handle := NilHandle;
  FileName := '';
  Result := False;
end;

function LoadExtension(const AName, APath: string; out AErr: string): Boolean;
var
  h: TLibHandle;
  fn: string;
  vFn: TVdbExtVersionFn;
  nFn: TVdbExtNameFn;
  dFn: TVdbExtNameFn;
  ver: LongWord;
  info: TVdbExtensionInfo;
  base: string;
begin
  Result := False;
  AErr := '';
  if Trim(AName) = '' then
  begin
    AErr := 'extension adi bos olamaz';
    Exit;
  end;
  if ExtensionLoaded(AName) then
  begin
    AErr := 'extension zaten yuklu: ' + AName;
    Exit;
  end;

  // Aday taban ad: yol verilmediyse AName; verildiyse dosya adi govdesi.
  if APath = '' then base := AName
  else base := ChangeFileExt(ExtractFileName(APath), '');

  if not TryLoadRaw(base, APath, h, fn) then
  begin
    AErr := 'kutuphane yuklenemedi: ' + AName +
      ' (yol="' + APath + '")';
    Exit;
  end;

  // ZORUNLU: surum sembolu
  vFn := TVdbExtVersionFn(VdbLibProc(h, VDB_EXT_SYM_VERSION));
  if not Assigned(vFn) then
  begin
    VdbLibUnload(h);
    AErr := 'zorunlu sembol yok: ' + VDB_EXT_SYM_VERSION;
    Exit;
  end;
  ver := vFn();
  if ver < VDB_EXT_API_VERSION then
  begin
    VdbLibUnload(h);
    AErr := Format('ABI surumu eski: 0x%.8x < 0x%.8x', [ver, VDB_EXT_API_VERSION]);
    Exit;
  end;

  info := Default(TVdbExtensionInfo);
  info.Name := AName;
  nFn := TVdbExtNameFn(VdbLibProc(h, VDB_EXT_SYM_NAME));
  if Assigned(nFn) then
    if nFn() <> nil then
    begin
      info.Name := string(AnsiString(nFn()));
      // Iki extension ayni kayitli ada sahip olamaz.
      if IndexOfExt(info.Name) >= 0 then
      begin
        VdbLibUnload(h);
        AErr := 'extension adi cakisti: ' + info.Name;
        Exit;
      end;
    end;
  dFn := TVdbExtNameFn(VdbLibProc(h, VDB_EXT_SYM_DESC));
  if Assigned(dFn) and (dFn() <> nil) then
    info.Description := string(AnsiString(dFn()));
  info.ApiVersion := ver;
  info.FileName := fn;
  info.Handle := h;

  SetLength(GExtensions, Length(GExtensions) + 1);
  GExtensions[High(GExtensions)] := info;
  Result := True;
end;

function DropExtension(const AName: string): Boolean;
var
  i, k: Integer;
  h: TLibHandle;
begin
  Result := False;
  i := IndexOfExt(AName);
  if i < 0 then Exit;
  h := GExtensions[i].Handle;
  VdbLibUnload(h);
  for k := i to High(GExtensions) - 1 do
    GExtensions[k] := GExtensions[k + 1];
  SetLength(GExtensions, Length(GExtensions) - 1);
  Result := True;
end;

procedure UnloadAllExtensions;
var
  i: Integer;
  h: TLibHandle;
begin
  for i := 0 to High(GExtensions) do
  begin
    h := GExtensions[i].Handle;
    VdbLibUnload(h);
  end;
  SetLength(GExtensions, 0);
end;

finalization
  UnloadAllExtensions;

end.
