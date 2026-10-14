library vdbtestext;

{ TR: VDB R-21 Ornek Eklenti (Extension/Plugin) — test araci
  EN: VDB R-21 Sample Extension/Plugin — test fixture

  Bu DLL, VDB motorunun `CREATE EXTENSION` ile dinamik olarak yukleyebilecegi
  GECERLI bir ornek eklentidir. sqltest T99_Extension grubu bu DLL'i yukleyip
  gercek sembol cagrisi yapar.

  This DLL is a VALID sample extension that the VDB engine can dynamically
  load via `CREATE EXTENSION`. The sqltest T99_Extension group loads it and
  makes real symbol calls.

  Zorunlu C-ABI sembolleri / Required C-ABI symbols:
    VdbExtApiVersion  -> LongWord (surum / version)
  Opsiyonel / Optional:
    VdbExtName        -> PAnsiChar (ad / name)
    VdbExtDescription -> PAnsiChar (aciklama / description)
  Test sembolu / Test symbol:
    VdbExtAdd(A, B)   -> Integer   (A + B) }

{$mode delphi}{$H+}

const
  { TR: Eklenti ABI surumu 1.0 (motorun bekledigi VDB_EXT_API_VERSION ile ayni)
    EN: Extension ABI version 1.0 (same as the engine's VDB_EXT_API_VERSION) }
  EXT_API_VERSION = $00010000;

  { TR: Dondurulecek sabit metinler (null-terminated)
    EN: Returned constant strings (null-terminated) }
  EXT_NAME: PAnsiChar = 'testext';
  EXT_DESC: PAnsiChar = 'VDB ornek eklentisi / sample extension';

function VdbExtApiVersion: LongWord; stdcall;
begin
  Result := EXT_API_VERSION;
end;

function VdbExtName: PAnsiChar; stdcall;
begin
  Result := EXT_NAME;
end;

function VdbExtDescription: PAnsiChar; stdcall;
begin
  Result := EXT_DESC;
end;

{ TR: Test sembolu — iki tam sayiyi toplar (2+3=5 beklenir)
  EN: Test symbol — adds two integers (expected 2+3=5) }
function VdbExtAdd(A, B: Integer): Integer; stdcall;
begin
  Result := A + B;
end;

exports
  VdbExtApiVersion  name 'VdbExtApiVersion',
  VdbExtName        name 'VdbExtName',
  VdbExtDescription name 'VdbExtDescription',
  VdbExtAdd         name 'VdbExtAdd';

begin
end.