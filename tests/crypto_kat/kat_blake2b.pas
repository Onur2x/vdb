unit kat_blake2b;
{ BLAKE2b known-answer tests against VDbBlake2b (VDbKdf.pas).

  Sources (see Vectors.md):
   - BLAKE2b-512("abc")  : RFC 7693 Appendix A (official RFC vector)
   - BLAKE2b-256("abc")  : official BLAKE2 test-vector set (draft-saarinen-
                           blake2); cross-checked vs CPython hashlib
   - empty / 'a' x 128 / 'a' x 200 : no RFC vector; byte-checked against
                           CPython hashlib (a fully independent C impl).
     'a'x128 is exactly 2 full blocks (exercises no-partial-block path),
     'a'x200 crosses the 3rd block with a 8-byte partial tail.

  Out-length contract sealed: VDbBlake2b accepts 1..64 and raises
  EVdbKdfError outside that range (VDbKdf.pas implementation contract). }

{$mode delphi}{$H+}

interface

function RunKatBlake2b: Integer;

implementation

uses
  SysUtils, kat_common, VDbKdf;

const
  PRIM = 'BLAKE2b (VDbBlake2b)';
  SRC_HASHLIB = 'cross-checked vs CPython hashlib (see Vectors.md)';

procedure CheckVec(const AName, ASource, AH: string; const Msg: TBytes;
  OutLen: Integer);
var
  Got, Exp: TBytes;
begin
  Exp := HexToBytes(AH);
  try
    Got := VDbBlake2b(Msg, OutLen);
    if BEq(Got, Exp) then
      KatPass(PRIM, AName, ASource)
    else
      KatFail(PRIM, AName, ASource,
        'got ' + BytesToHexL(Got) + ' want ' + LowerCase(AH));
  except
    on E: Exception do
      KatFail(PRIM, AName, ASource, 'exception: ' + E.Message);
  end;
end;

procedure CheckOutLenRange;
var
  got: TBytes;
  raisedLo, raisedHi, raisedOtherLo, raisedOtherHi: Boolean;
begin
  raisedLo := False;
  raisedHi := False;
  raisedOtherLo := False;
  raisedOtherHi := False;
  try
    VDbBlake2b(StrB('x'), 0);
  except
    on E: EVdbKdfError do raisedLo := True;
    else raisedOtherLo := True;
  end;
  try
    VDbBlake2b(StrB('x'), 65);
  except
    on E: EVdbKdfError do raisedHi := True;
    else raisedOtherHi := True;
  end;

  if raisedLo and raisedHi and not raisedOtherLo and not raisedOtherHi then
    KatPass(PRIM, 'OutLen guards: 0 and 65 raise EVdbKdfError',
      'VDbKdf.pas VDbBlake2b implementation contract')
  else
    KatFail(PRIM, 'OutLen guards: 0 and 65 raise EVdbKdfError',
      'VDbKdf.pas VDbBlake2b implementation contract',
      'OutLen=0 raised EVdbKdfError=' + BoolToStr(raisedLo, True) +
      ' (other class=' + BoolToStr(raisedOtherLo, True) + '), ' +
      'OutLen=65 raised EVdbKdfError=' + BoolToStr(raisedHi, True) +
      ' (other class=' + BoolToStr(raisedOtherHi, True) + ')');

  { boundary values 1 and 64 must work }
  try
    got := VDbBlake2b(StrB('x'), 1);
    if Length(got) = 1 then
      KatPass(PRIM, 'OutLen=1 boundary ok',
        'VDbKdf.pas VDbBlake2b implementation contract')
    else
      KatFail(PRIM, 'OutLen=1 boundary ok',
        'VDbKdf.pas VDbBlake2b implementation contract',
        'got length ' + IntToStr(Length(got)));
    got := VDbBlake2b(StrB('x'), 64);
    if Length(got) = 64 then
      KatPass(PRIM, 'OutLen=64 boundary ok',
        'VDbKdf.pas VDbBlake2b implementation contract')
    else
      KatFail(PRIM, 'OutLen=64 boundary ok',
        'VDbKdf.pas VDbBlake2b implementation contract',
        'got length ' + IntToStr(Length(got)));
  except
    on E: Exception do
      KatFail(PRIM, 'OutLen boundary 1/64',
        'VDbKdf.pas VDbBlake2b implementation contract',
        'exception: ' + E.Message);
  end;
end;

function RunKatBlake2b: Integer;
var
  before: Integer;
begin
  before := KatFailed;
  KatSection('BLAKE2b (VDbKdf)');

  CheckVec('BLAKE2b-512("abc")', 'RFC 7693 App. A',
    'ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1' +
    '7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923',
    StrB('abc'), 64);

  CheckVec('BLAKE2b-256("abc")',
    'official BLAKE2 vector set; ' + SRC_HASHLIB,
    'bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319',
    StrB('abc'), 32);

  CheckVec('BLAKE2b-512("")', SRC_HASHLIB,
    '786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419' +
    'd25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce',
    nil, 64);

  CheckVec('BLAKE2b-512(128 x 0x61) (exact 2 blocks)', SRC_HASHLIB,
    'fc6c71f688f43ea7d60817478808f3cac753e61571865c95adbc2d9122c943a7' +
    '6b92c2cb1047ef3fe7bf6e436ec1d0a99a9e5b216780bf7fed9d7ca91d3a8f3b',
    Rep($61, 128), 64);

  CheckVec('BLAKE2b-512(200 x 0x61) (partial 3rd block)', SRC_HASHLIB,
    '932355851d75f09c18646a9da87c25e055bc57f113121ad1ec63d45e7a1d62ab' +
    '9133f8b7d1d7de9e0afa784eb6a8a11d78683013d0a672611f17668d9577d209',
    Rep($61, 200), 64);

  CheckOutLenRange;

  Result := KatFailed - before;
end;

end.
