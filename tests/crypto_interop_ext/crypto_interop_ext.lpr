program crypto_interop_ext;
{ v3.72 / SKILL6 08 (B) KALICI REGRESYON KAPISI - BAGIMSIZ kriptografi
  referansi (harici).

  `tests/crypto_interop` yayinlanmis sabit vektorleri (FIPS 180-4,
  RFC 4231, RFC 7914/6070) dogrular. Bu kapi onu ASAR: beklenen degerler
  **motorun disinda**, bagimsiz bir uygulamada (Python `hashlib`/`hmac`,
  OpenSSL tabanli) hesaplanir ve VDB'nin ciktisi bayt bayt karsilastirilir.
  Ayni kaynaktan kopyalanmis iki test bagimsiz dogrulama sayilmaz; bu
  yuzden vektorler burada uretilmez, disarida uretilir.

  Kapida olculen:
    CE0  python + hashlib/hmac calisiyor (yoksa kapi SKIP, exit 77)
    CE1  dis referans her spec icin bir sonuc dondurdu
    CE2..CE22  spec basina SHA-256 / HMAC-SHA-256 / PBKDF2-HMAC-SHA256
        cikisi dis referansla BIREBIR ayni (blok sinirlari 55/56/63/64/65,
        127/128/129, 1 MB girdi, 1/2/4096 iterasyon, dkLen 32/40/64,
        64 baytlik HMAC anahtari ve 71 baytlik parola dahil)

  DIS BAGIMLILIK: python3 (stdlib hashlib). Yoksa kapi **SKIP** (exit 77)
  verir ve gerekce yazilir; ASLA PASS sayilmaz. Python depoya BAGIMLILIK
  DEGILDIR: yalniz dogrulama aracidir, uretim kodu ona bagli degildir.

  NOT: bu kapi FIPS/CAVP SERTIFIKASYONU iddia etmez. }
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Process, VDbTypes, VDbCrypt;

const
  SKIP_CODE = 77;
  SPEC_COUNT = 26;

var
  GPass, GFail, GSkip: Integer;
  GDir, GScript: string;
  GPy: string;
  GSpecs: array[0..SPEC_COUNT - 1] of string;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string = '');
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    if ADetail <> '' then
      WriteLn('FAIL ', AName, ' - ', ADetail)
    else
      WriteLn('FAIL ', AName);
  end;
  Flush(Output);
end;

function Clean(const S: string): string;
begin
  Result := Trim(StringReplace(StringReplace(S, #13, ' ', [rfReplaceAll]),
    #10, ' | ', [rfReplaceAll]));
  if Length(Result) > 300 then Result := Copy(Result, 1, 300) + '...';
end;

function TryExe(const AExe: string; const AArg: string; out AOut: string): Boolean;
begin
  AOut := '';
  try
    Result := RunCommand(AExe, [AArg], AOut);
  except
    Result := False;
  end;
end;

function TryPySelf(const AExe: string; out AOut: string): Boolean;
begin
  AOut := '';
  try
    Result := RunCommand(AExe, [GScript, 'selftest'], AOut);
  except
    Result := False;
  end;
end;

function FindPython(out AReason: string): Boolean;
var
  cand: array[0..4] of string;
  i: Integer;
  outp: string;
begin
  Result := False;
  AReason := '';
  cand[0] := GetEnvironmentVariable('VDB_INTEROP_PY');
  cand[1] := 'python3';
  cand[2] := 'python';
  cand[3] := 'py';
  cand[4] := 'C:\Python314\python.exe';
  for i := 0 to 4 do
  begin
    if cand[i] = '' then Continue;
    if (Pos('\', cand[i]) > 0) and not FileExists(cand[i]) then Continue;
    if not TryExe(cand[i], '--version', outp) then Continue;
    if (Pos('Python', outp) = 0) and (Pos('python', outp) = 0) then Continue;
    GPy := cand[i];
    if TryPySelf(GPy, outp) and (Pos('OK hashlib', outp) > 0) then
    begin
      Result := True;
      Exit;
    end;
    if AReason = '' then
      AReason := 'python bulundu (' + GPy + ') ama hashlib/hmac sorunu: ' +
        Clean(outp);
  end;
  if AReason = '' then
    AReason := 'python3 bulunamadi (VDB_INTEROP_PY ile yol verilebilir)';
end;

{ Deterministik girdi ureticileri. Dis referans (diff.py) AYNI kurallari
  uygular; bu yuzden vektor dosyasi yalniz spec listesidir, veri tasimaz. }
function GenBytes(const ATok: string; AN: Integer): TBytes;
var
  i: Integer;
begin
  SetLength(Result, AN);
  if AN <= 0 then Exit;
  if ATok = 'A' then
  begin
    FillChar(Result[0], AN, Ord('a'));
    Exit;
  end;
  for i := 0 to AN - 1 do
    Result[i] := Byte((Int64(i) * 37 + 11) and 255);
end;

function HexOf(const B: TBytes): string;
const
  HEXD = '0123456789abcdef';
var
  i: Integer;
begin
  SetLength(Result, Length(B) * 2);
  for i := 0 to High(B) do
  begin
    Result[i * 2 + 1] := HEXD[(B[i] shr 4) + 1];
    Result[i * 2 + 2] := HEXD[(B[i] and 15) + 1];
  end;
end;

procedure AddSpecs;
begin
  GSpecs[0] := 'SHA P 0';
  GSpecs[1] := 'SHA P 1';
  GSpecs[2] := 'SHA P 55';
  GSpecs[3] := 'SHA P 56';
  GSpecs[4] := 'SHA P 63';
  GSpecs[5] := 'SHA P 64';
  GSpecs[6] := 'SHA P 65';
  GSpecs[7] := 'SHA P 127';
  GSpecs[8] := 'SHA P 128';
  GSpecs[9] := 'SHA P 129';
  GSpecs[10] := 'SHA A 1048576';
  GSpecs[11] := 'HMAC P 1 P 0';
  GSpecs[12] := 'HMAC P 32 P 55';
  GSpecs[13] := 'HMAC P 55 P 64';
  GSpecs[14] := 'HMAC P 64 P 65';
  GSpecs[15] := 'HMAC A 64 A 1048576';
  GSpecs[16] := 'PBKDF2 A 8 A 8 1 32';
  GSpecs[17] := 'PBKDF2 A 8 A 8 2 32';
  GSpecs[18] := 'PBKDF2 A 8 A 8 4096 32';
  GSpecs[19] := 'PBKDF2 A 40 A 33 1000 40';
  GSpecs[20] := 'PBKDF2 A 8 A 8 4096 64';
  { SKILL16-B: AES-256-GCM (ct||tag) bagimsiz referansla. Deterministik
    uretici P her iki tarafta ayni kurali uygular. }
  GSpecs[21] := 'GCM P 32 P 12 P 0 P 0';
  GSpecs[22] := 'GCM P 32 P 12 P 16 P 16';
  GSpecs[23] := 'GCM P 32 P 12 P 20 P 20';
  GSpecs[24] := 'GCM P 32 P 12 P 64 P 1000';
  GSpecs[25] := 'GCM P 32 P 12 P 128 P 262144';
end;

function SolveSpec(const ASpec: string; out AHex: string): Boolean;
var
  t: TStringList;
  key, msg, pw, salt, iv, ad, ct, tg: TBytes;
  it, dk: Integer;
begin
  Result := False;
  AHex := '';
  t := TStringList.Create;
  try
    t.Delimiter := ' ';
    t.StrictDelimiter := True;
    t.DelimitedText := ASpec;
    try
      if t[0] = 'SHA' then
      begin
        AHex := HexOf(VDbCryptSha256(GenBytes(t[1], StrToIntDef(t[2], 0))));
        Result := True;
      end
      else if t[0] = 'HMAC' then
      begin
        key := GenBytes(t[1], StrToIntDef(t[2], 0));
        msg := GenBytes(t[3], StrToIntDef(t[4], 0));
        AHex := HexOf(VDbCryptHmacSha256(key, msg));
        Result := True;
      end
      else if t[0] = 'PBKDF2' then
      begin
        pw := GenBytes(t[1], StrToIntDef(t[2], 0));
        salt := GenBytes(t[3], StrToIntDef(t[4], 0));
        it := StrToIntDef(t[5], 1);
        dk := StrToIntDef(t[6], 32);
        AHex := HexOf(VDbPbkdf2Sha256(pw, salt, it, dk));
        Result := True;
      end
      else if t[0] = 'GCM' then
      begin
        { SKILL16-B: VDB ciktisi ct||tag; dis referans ayni bicimi uretir. }
        key := GenBytes(t[1], StrToIntDef(t[2], 0));
        iv := GenBytes(t[3], StrToIntDef(t[4], 0));
        ad := GenBytes(t[5], StrToIntDef(t[6], 0));
        msg := GenBytes(t[7], StrToIntDef(t[8], 0));
        if not VDbCryptGcmSeal(key, iv, msg, ad, ct, tg) then
        begin
          AHex := 'SEAL-FALSE';
          Result := False;
        end
        else
        begin
          AHex := HexOf(ct) + HexOf(tg);
          Result := True;
        end;
      end;
    except
      on E: Exception do
      begin
        AHex := 'EXC ' + E.Message;
        Result := False;
      end;
    end;
  finally
    t.Free;
  end;
end;

var
  req, resp, reason, outp, s, refHex: string;
  lines: TStringList;
  i, p, okCount: Integer;
  have: Boolean;

begin
  GPass := 0;
  GFail := 0;
  GSkip := 0;
  AddSpecs;
  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp' +
    PathDelim;
  if not DirectoryExists(GDir) then ForceDirectories(GDir);
  GScript := ExtractFilePath(ParamStr(0)) + 'diff.py';
  if not FileExists(GScript) and (ParamStr(1) <> '') then
    GScript := IncludeTrailingPathDelimiter(ParamStr(1)) + 'diff.py';

  if not FindPython(reason) then
  begin
    WriteLn('SKIP crypto_interop_ext (', reason, ')');
    Flush(Output);
    Halt(SKIP_CODE);
  end;
  Chk('CE0 python + hashlib bagimsiz referansi hazir', True);

  req := GDir + 'req.txt';
  resp := GDir + 'resp.txt';
  if FileExists(resp) then DeleteFile(resp);
  lines := TStringList.Create;
  try
    for i := 0 to SPEC_COUNT - 1 do lines.Add(GSpecs[i]);
    lines.SaveToFile(req);
  finally
    lines.Free;
  end;

  have := False;
  try
    have := RunCommand(GPy, [GScript, req, resp], outp);
  except
    have := False;
    outp := 'python calistirilamadi';
  end;
  if not have or not FileExists(resp) then
  begin
    Chk('CE1 dis referans sonuc uretti', False, Clean(outp));
    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
    Halt(1);
  end;

  lines := TStringList.Create;
  try
    lines.LoadFromFile(resp);
    Chk('CE1 dis referans her spec icin sonuc dondurdu',
      lines.Count = SPEC_COUNT,
      Format('%d satir, beklenen %d', [lines.Count, SPEC_COUNT]));

    okCount := 0;
    for i := 0 to SPEC_COUNT - 1 do
    begin
      s := '';
      refHex := '';
      if i < lines.Count then s := lines[i];
      p := LastDelimiter('|', s);
      if p > 0 then refHex := Trim(Copy(s, p + 1, MaxInt));
      { SKILL16-B: cryptography yoksa dis referans NO-CRYPTO doner. Bu bir
        PASS degildir: SKIP sayilir ve kapi sonda 77 ile kapanir. }
      if Pos('NO-CRYPTO', refHex) > 0 then
      begin
        Inc(GSkip);
        WriteLn('SKIP CE', i + 2, ' ', GSpecs[i],
          ' (python cryptography yok: GCM dis referansi uretilemedi)');
        Flush(Output);
        Continue;
      end;
      SolveSpec(GSpecs[i], s);
      if (refHex <> '') and (s = refHex) then Inc(okCount);
      Chk('CE' + IntToStr(i + 2) + ' ' + GSpecs[i], (refHex <> '') and
        (s = refHex),
        'vdb=' + Copy(s, 1, 32) + ' dis=' + Copy(refHex, 1, 32));
    end;
    Chk('CE-SON tum spec ler bagimsiz referansla ayni',
      okCount = SPEC_COUNT - GSkip,
      Format('%d/%d, %d SKIP', [okCount, SPEC_COUNT - GSkip, GSkip]));

    { Durust sinir: VDB'nin HMAC anahtari 64 bayti asamaz ve PBKDF2 parolayi
      HMAC anahtari olarak kullandigi icin 64 bayttan uzun parola
      HESAPLANMAZ - sessiz kirpma YOK, fail-closed hata verir (RFC 8018
      parola uzunlugunu sinirlamaz). Bu bir veri kaybi degildir ama
      standarttan ayrilan belgelenmis bir sinirdir. }
    refHex := '';
    try
      VDbPbkdf2Sha256(GenBytes('A', 71), GenBytes('A', 8), 1, 32);
      refHex := 'hesaplandi';
    except
      on E: Exception do
        if Pos('HMAC anahtari cok uzun', E.Message) > 0 then
          refHex := 'reddedildi';
    end;
    Chk('CE-LIM 64 bayttan uzun parola fail-closed reddedilir (sessiz kirpma yok)',
      refHex = 'reddedildi', refHex);
  finally
    lines.Free;
  end;

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL, ', GSkip, ' SKIP');
  Flush(Output);
  if GFail > 0 then Halt(1);
  { Bagimsiz GCM referansi uretilemediyse kapi PASS sayilmaz. }
  if GSkip > 0 then Halt(SKIP_CODE);
end.
