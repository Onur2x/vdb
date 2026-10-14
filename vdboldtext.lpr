library vdboldtext;

{ TR: VDB R-21 ESKI ABI Eklenti — surum-kapisi test araci
  EN: VDB R-21 OLD ABI Extension — version-gate test fixture

  Bu DLL, VDB motorunun `CREATE EXTENSION` ile yuklemeyi REDDETMESI gereken
  eski bir ABI surumunu bildirir. sqltest T99_Extension grubu surum-kapisi
  (version gate) korumasini sinamak icin bu DLL'i kullanir: motor, verilen
  surum VDB_EXT_API_VERSION'dan KUCUKSE yuklemeyi reddetmelidir.

  This DLL reports an OLD ABI version that the VDB engine must REJECT when
  loading via `CREATE EXTENSION`. The sqltest T99_Extension group uses it to
  exercise the version-gate protection: the engine must reject loading when
  the reported version is LESS THAN VDB_EXT_API_VERSION.

  Not: Bu DLL sembolu TASIR (VdbExtApiVersion) ama eski bir deger dondurur;
  boylece "sembol yok" degil, "surum eski" hatasi uretilir.

  Note: This DLL CARRIES the symbol (VdbExtApiVersion) but returns an OLD
  value; so it produces a "version too old" error, not a "missing symbol" one. }

{$mode delphi}{$H+}

const
  { TR: ESKI ABI surumu 0.1 — motorun bekledigi $00010000'dan KUCUK
    EN: OLD ABI version 0.1 — LESS THAN the engine's expected $00010000 }
  EXT_API_VERSION = $00000001;

  EXT_NAME: PAnsiChar = 'oldext';
  EXT_DESC: PAnsiChar = 'eski ABI ornegi / old ABI sample';

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

exports
  VdbExtApiVersion  name 'VdbExtApiVersion',
  VdbExtName        name 'VdbExtName',
  VdbExtDescription name 'VdbExtDescription';

begin
end.