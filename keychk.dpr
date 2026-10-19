program keychk;
{$mode delphi}{$H+}
uses SysUtils, Classes, VDbCrypt;

var
  fails: Integer;

procedure Check(const Name: string; Cond: Boolean; const E: string = '');
begin
  if Cond then Writeln('OK   ', Name)
  else
  begin
    Writeln('FAIL ', Name, ' ', E);
    Inc(fails);
  end;
end;

function ReadAll(const Path: string): TBytes;
var
  f: TFileStream;
begin
  f := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, f.Size);
    if f.Size > 0 then f.ReadBuffer(Result[0], f.Size);
  finally
    f.Free;
  end;
end;

procedure WriteAll(const Path: string; const B: TBytes);
var
  f: TFileStream;
begin
  f := TFileStream.Create(Path, fmCreate);
  try
    if Length(B) > 0 then f.WriteBuffer(B[0], Length(B));
  finally
    f.Free;
  end;
end;

function MakeV1KeyFile(const Path, Password: string; out Key: TBytes): Boolean;
var
  salt, verifier, buf: TBytes;
  iter, i: Integer;
begin
  salt := nil;
  VDbCryptRandom(salt, 16);
  iter := 200000;
  Key := VDbCryptDeriveKey(Password, salt, iter);
  verifier := VDbCryptVerifier(Key);
  SetLength(buf, VDB_KEYFILE_HEAD + Length(salt) + Length(verifier));
  Move(VDB_KEYFILE_MAGIC[1], buf[0], 4);
  buf[4] := VDB_KEYFILE_VER;
  buf[5] := Byte(Length(salt));
  for i := 0 to 3 do
    buf[6 + i] := Byte((LongWord(iter) shr (i * 8)) and $FF);
  Move(salt[0], buf[VDB_KEYFILE_HEAD], Length(salt));
  Move(verifier[0], buf[VDB_KEYFILE_HEAD + Length(salt)], Length(verifier));
  WriteAll(Path, buf);
  Result := True;
end;

var
  k1, k2, v1k, v1r: TBytes;
  it: Integer;
  raw: TBytes;
  p: string;
begin
  fails := 0;
  p := 'keychk_v2.key';
  if FileExists(p) then DeleteFile(p);
  Check('v2 yazildi', VDbKeyFileWrite(p, 'argon2-parola-1', k1, it));
  raw := ReadAll(p);
  Check('v2 surum bayt=2', (Length(raw) > 5) and (raw[4] = 2),
    'len=' + IntToStr(Length(raw)));
  Check('v2 t=3', (Length(raw) > 9) and (raw[6] = 3) and (raw[7] = 0) and
    (raw[8] = 0) and (raw[9] = 0));
  Check('v2 m=65536', (Length(raw) > 13) and (raw[10] = 0) and
    (raw[11] = 0) and (raw[12] = 1) and (raw[13] = 0));
  Check('v2 lanes=1', (Length(raw) > 14) and (raw[14] = 1));

  k2 := nil;
  Check('v2 dogru parola', VDbKeyFileRead(p, 'argon2-parola-1', k2, it));
  Check('v2 anahtar ayni', VDbCryptEqual(k1, k2));
  k2 := nil;
  Check('v2 yanlis parola reddedildi',
    not VDbKeyFileRead(p, 'yanlis-parola-1', k2, it));
  Check('v2 yanlis parola anahtar vermedi', Length(k2) = 0);

  p := 'keychk_v1.key';
  if FileExists(p) then DeleteFile(p);
  MakeV1KeyFile(p, 'pbkdf2-parola-1', v1k);
  v1r := nil;
  Check('v1 (PBKDF2) dosyasi okundu',
    VDbKeyFileRead(p, 'pbkdf2-parola-1', v1r, it));
  Check('v1 anahtar ayni', VDbCryptEqual(v1k, v1r));
  v1r := nil;
  Check('v1 yanlis parola reddedildi',
    not VDbKeyFileRead(p, 'yanlis-parola-1', v1r, it));

  if FileExists('keychk_v2.key') then DeleteFile('keychk_v2.key');
  if FileExists('keychk_v1.key') then DeleteFile('keychk_v1.key');
  Writeln('FAILS=', fails);
  if fails <> 0 then Halt(1);
end.
