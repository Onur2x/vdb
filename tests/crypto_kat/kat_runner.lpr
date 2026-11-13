program kat_runner;
{ VDB crypto KAT runner - seals VDbCrypt / VDbKdf / VDbPageCrypto primitives
  against official RFC/NIST vectors (see Vectors.md for provenance).

  Build (FPC 3.2.4, from repo root; -Fu/-FU bayrakları yola bitişik):
    fpc -FuD:\veritabani -FUD:\veritabani\tests\crypto_kat\lib D:\veritabani\tests\crypto_kat\kat_runner.lpr

  Exit code: number of failed checks (0 = everything sealed green). }

{$mode delphi}{$H+}

uses
  {$ifdef UNIX}
  ccthreads,
  {$endif}
  SysUtils,
  kat_common,
  kat_sha256,
  kat_hmac_sha256,
  kat_aes256gcm,
  kat_blake2b,
  kat_argon2id,
  kat_page_envelope;

begin
  KatResetCounters;
  Writeln('VDB crypto KAT runner - ', FormatDateTime('yyyy-mm-dd', Now));

  RunKatSha256;
  RunKatHmacSha256;
  RunKatAes256Gcm;
  RunKatBlake2b;
  RunKatArgon2id;
  RunKatPageEnvelope;

  Writeln;
  Writeln(Format('%d passed / %d failed / %d skipped',
    [KatPassed, KatFailed, KatSkipped]));
  if KatFailed > 0 then
  begin
    Writeln('RESULT: FAIL');
    Halt(1);
  end
  else
  begin
    Writeln('RESULT: PASS');
    Halt(0);
  end;
end.
