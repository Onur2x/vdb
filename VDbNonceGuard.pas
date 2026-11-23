unit VDbNonceGuard;

{ VDB v3 - SKILL16-D: ayni anahtar altinda nonce tekrarini tespit eden kapi.

  Neden var: AES-256-GCM'de ayni (anahtar, nonce) ikilisiyle iki farkli duz
  metin sifrelenirse GCM'in butunluk garantisi coker (XOR of two plaintexts
  ve tag anahtari sizar). Sayfa zarfinda nonce 96 bit rastgele uretilir
  (VDbPageCrypto.VDbPageSeal), yani cakisma olasiligi ihmal edilebilir
  (~2^-96); bu birim o "ihmal edilebilir" varsayimi bir teste baglar.

  Kapsam (durust sinir):
   - Kapi SUREC ICIDIR. Her surec kendi tablosunu tutar; surec yeniden
     basladiginda tablo sifirlanir. Kalici bir sayac degildir.
   - Kapasite VDB_NONCE_GUARD_SLOTS (1024) girdidir; doldugunda EN ESKI
     girdi dusurulur (halka tampon). Dusurulen bir nonce'un tekrarini kapi
     goremez; bu yuzden nonce'lar yine de rastgele 96-bit kalmak zorundadir.
   - Gecersiz girdi (bos anahtar/nonce) her zaman False doner: cagiran
     taraf sifreleme yapmamalidir (fail-closed).

  Anahtar tabloda ACIK tutulmaz; anahtarin HMAC-SHA256 parmak izinin ilk
  8 bayti saklanir. Boylece tablo bir anahtar deposuna donusmez.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils;

const
  VDB_NONCE_GUARD_SLOTS = 1024;

{ Nonce'u kaydeder. True: nonce bu anahtar altinda ILK kez goruldu (kayit
  yapildi, sifreleme guvenli). False: nonce daha once kullanildi (TEKRAR -
  sifreleme YAPILMAMALI) ya da girdi gecersiz. }
function VDbNonceMark(const Key, Nonce: TBytes): Boolean;

{ Tabloyu temizler (test/kurulum). }
procedure VDbNonceReset;

{ Tabloda tutulan girdi sayisi (teshis/test). }
function VDbNonceGuardCount: Integer;

implementation

uses
  VDbCrypt;

type
  TGuardEntry = record
    Used: Boolean;
    KeyId: QWord;
    Nonce: array[0..11] of Byte;
  end;

var
  GLock: TRTLCriticalSection;
  GInit: Boolean = False;
  GEntries: array[0..VDB_NONCE_GUARD_SLOTS - 1] of TGuardEntry;
  GCount: Integer = 0;   { toplam kayit sayaci (halka konumu) }
  GUsed: Integer = 0;    { dolu girdi sayisi (<= SLOTS) }

procedure EnsureInit;
begin
  if not GInit then
  begin
    InitCriticalSection(GLock);
    GInit := True;
  end;
end;

function KeyIdOf(const Key: TBytes): QWord;
var
  h: TBytes;
begin
  { Anahtarin kendisi saklanmaz; HMAC tabanli parmak izi saklanir. }
  h := VDbCryptHmacSha256(Key, VDbCryptStrToBytes('VDB3-NONCE-GUARD-v1'));
  Result := 0;
  if Length(h) >= 8 then
    Move(h[0], Result, 8);
end;

procedure NonceBytes(const Nonce: TBytes; out B: array of Byte);
var
  i: Integer;
begin
  for i := 0 to High(B) do
  begin
    if i < Length(Nonce) then
      B[i] := Nonce[i]
    else
      B[i] := 0;
  end;
end;

function VDbNonceMark(const Key, Nonce: TBytes): Boolean;
var
  kid: QWord;
  nb: array[0..11] of Byte;
  i, p: Integer;
  found: Boolean;
begin
  Result := False;
  { Gecersiz girdi: kaydetme, sifrelemeye IZIN VERME. }
  if (Length(Key) = 0) or (Length(Nonce) = 0) then
    Exit;
  EnsureInit;
  kid := KeyIdOf(Key);
  NonceBytes(Nonce, nb);
  EnterCriticalSection(GLock);
  try
    found := False;
    for i := 0 to GUsed - 1 do
    begin
      if GEntries[i].Used and (GEntries[i].KeyId = kid) and
         CompareMem(@GEntries[i].Nonce[0], @nb[0], 12) then
      begin
        found := True;
        Break;
      end;
    end;
    if found then
      Exit(False);
    p := GCount mod VDB_NONCE_GUARD_SLOTS;
    GEntries[p].Used := True;
    GEntries[p].KeyId := kid;
    Move(nb[0], GEntries[p].Nonce[0], 12);
    Inc(GCount);
    if GUsed < VDB_NONCE_GUARD_SLOTS then
      Inc(GUsed);
    Result := True;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure VDbNonceReset;
begin
  EnsureInit;
  EnterCriticalSection(GLock);
  try
    FillChar(GEntries, SizeOf(GEntries), 0);
    GCount := 0;
    GUsed := 0;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function VDbNonceGuardCount: Integer;
begin
  EnsureInit;
  EnterCriticalSection(GLock);
  try
    Result := GUsed;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

initialization
  EnsureInit;

finalization
  if GInit then
  begin
    DoneCriticalSection(GLock);
    GInit := False;
  end;

end.
