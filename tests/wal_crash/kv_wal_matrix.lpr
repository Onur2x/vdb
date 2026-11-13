program kv_wal_matrix;

{ PHASE-2 kalici kapi: KV (kayit defteri) WAL - TVDb.WriteAheadWAL /
  ReplayWAL crash matrisi.

  Sayfa WAL'den FARKLI bir yol: burada kayit defteri (.wal, magic 'WALR')
  dogrudan ana dosyaya uygulanir ve basarili replay .wal'i siler.
  Skill 4.1/4.2 bozuk/kesik kuyruk, CRC, magic ve idempotentlik
  davranislarinin TEST ile kanitlanmasini ister.

  Senaryolar:
   K1  iki kayit yazilir -> sayim 2 -> replay uygular ve .wal silinir
   K2  ikinci replay idempotent (veri degismez, .wal yok)
   K3  kesik kayit (yarim kuyruk) -> onceki kayit uygulanir, sonraki atilir
   K4  CRC bozulmasi -> hicbir kayit uygulanmaz
   K5  bozuk magic -> hicbir kayit uygulanmaz
   K6  DEL kaydi deger tasiyamaz (reddedilir, .wal'da iz birakmaz)
   K7  VDB_MAX_VALUE ustu deger reddedilir
   K8  replay sonrasi kalicilik: yeniden acilista veri yerinde

  Cikis kodu = FAIL sayisi. }

{$mode delphi}{$H+}

uses
  SysUtils, Classes, VDbCore;

const
  { TVDbWalHead packed: Magic(4) Key(8) Flags(1) ValLen(4) Crc(4)
    LSN(8) WalStamp(8) = 37 bayt. }
  KV_HDR = 37;
  OFF_MAGIC = 0;
  OFF_VALLEN = 13;
  OFF_CRC = 17;

var
  GPass, GFail: Integer;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' - ', ADetail);
  end;
end;

function TestDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp';
  if not DirectoryExists(Result) then
    ForceDirectories(Result);
end;

function FreshDir(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(TestDir + 'kv_' + AName);
  if DirectoryExists(Result) then
  begin
    if FileExists(Result + 'veritabani.odb') then DeleteFile(Result + 'veritabani.odb');
    if FileExists(Result + 'veritabani.wal') then DeleteFile(Result + 'veritabani.wal');
  end
  else
    ForceDirectories(Result);
end;

function BytesOf(const S: string): TBytes;
var
  i: Integer;
begin
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do
    Result[i - 1] := Byte(S[i]);
end;

function StrOf(const B: TBytes): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(B) do
    Result := Result + Char(B[i]);
end;

procedure PatchFile(const AFile: string; AOffset: Int64;
  const ABytes: array of Byte);
var
  S: TFileStream;
begin
  S := TFileStream.Create(AFile, fmOpenReadWrite or fmShareDenyNone);
  try
    S.Position := AOffset;
    S.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    S.Free;
  end;
end;

procedure ShrinkFile(const AFile: string; ANewSize: Int64);
var
  S: TFileStream;
begin
  S := TFileStream.Create(AFile, fmOpenReadWrite or fmShareDenyNone);
  try
    S.Size := ANewSize;
  finally
    S.Free;
  end;
end;

function FileSizeOf(const AFile: string): Int64;
var
  S: TFileStream;
begin
  S := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    Result := S.Size;
  finally
    S.Free;
  end;
end;

function HasKey(Db: TVDb; AKey: QWord; out AValue: string): Boolean;
var
  v: TBytes;
begin
  Result := Db.Get(AKey, v);
  if Result then
    AValue := StrOf(v)
  else
    AValue := '';
end;

{ --------------------------------- K1 ------------------------------------- }

procedure K1_WriteReplayDurability;
var
  dir, wp, v: string;
  Db: TVDb;
  pre: TBytes;
begin
  dir := FreshDir('k1');
  Db := TVDb.Create;
  try
    Db.Open(dir);
    Chk('k1/write1', Db.WriteAheadWAL(1, BytesOf('alpha')), 'yazma basarisiz');
    Chk('k1/write2', Db.WriteAheadWAL(2, BytesOf('beta')), 'yazma basarisiz');
    wp := Db.WalPath;
    Chk('k1/count', Db.WalRecordCount = 2,
      'WalRecordCount=' + IntToStr(Db.WalRecordCount));
    Chk('k1/has-wal', Db.HasWAL, 'HasWAL False');
    Chk('k1/not-applied-yet', not Db.Get(1, pre),
      'replay oncesi gorunur oldu');
    Chk('k1/replay', Db.ReplayWAL, 'ReplayWAL False');
    Chk('k1/wal-removed', not FileExists(wp), '.wal silinmedi');
    Chk('k1/value1', HasKey(Db, 1, v) and (v = 'alpha'), 'k1=''' + v + '''');
    Chk('k1/value2', HasKey(Db, 2, v) and (v = 'beta'), 'k2=''' + v + '''');
  finally
    Db.Free;
  end;

  { K8: kalicilik - yeniden acilis }
  Db := TVDb.Create;
  try
    Db.Open(dir);
    Chk('k8/reopen-value1', HasKey(Db, 1, v) and (v = 'alpha'),
      'reopen k1=''' + v + '''');
    Chk('k8/reopen-value2', HasKey(Db, 2, v) and (v = 'beta'),
      'reopen k2=''' + v + '''');
  finally
    Db.Free;
  end;
end;

{ --------------------------------- K2 ------------------------------------- }

procedure K2_ReplayIdempotent;
var
  dir, v: string;
  Db: TVDb;
begin
  dir := FreshDir('k2');
  Db := TVDb.Create;
  try
    Db.Open(dir);
    Db.WriteAheadWAL(10, BytesOf('x'));
    Chk('k2/replay1', Db.ReplayWAL, 'ilk replay False');
    Chk('k2/replay2', Db.ReplayWAL, 'ikinci replay False (idempotent olmali)');
    Chk('k2/value', HasKey(Db, 10, v) and (v = 'x'), 'v=''' + v + '''');
    Chk('k2/no-wal', not Db.HasWAL, '.wal geri geldi');
  finally
    Db.Free;
  end;
end;

{ --------------------------------- K3 ------------------------------------- }

procedure K3_TornRecord;
var
  dir, wp, v: string;
  Db: TVDb;
  before: Int64;
begin
  dir := FreshDir('k3');
  Db := TVDb.Create;
  try
    Db.Open(dir);
    Db.WriteAheadWAL(1, BytesOf('abc'));
    Db.WriteAheadWAL(2, BytesOf('def'));
    wp := Db.WalPath;
    before := FileSizeOf(wp);
    Chk('k3/size', before = 2 * (KV_HDR + 3),
      'boyut=' + IntToStr(before));
  finally
    Db.Free;
  end;
  { Ikinci kaydin son 10 bayti kesilir: yarim kayit. }
  ShrinkFile(wp, before - 10);

  Db := TVDb.Create;
  try
    Db.Open(dir);
    Chk('k3/replay', Db.ReplayWAL, 'ReplayWAL False');
    Chk('k3/first-applied', HasKey(Db, 1, v) and (v = 'abc'),
      'v=''' + v + '''');
    Chk('k3/second-dropped', not HasKey(Db, 2, v), 'yarim kayit uygulandi');
    Chk('k3/wal-removed', not FileExists(wp), '.wal silinmedi');
  finally
    Db.Free;
  end;
end;

{ ------------------------------ K4 / K5 ----------------------------------- }

function CorruptionCase(const AName: string; AOffset: Int64;
  const ABytes: array of Byte): Boolean;
var
  dir, wp, v: string;
  Db: TVDb;
begin
  dir := FreshDir(AName);
  Db := TVDb.Create;
  try
    Db.Open(dir);
    Db.WriteAheadWAL(1, BytesOf('abc'));
    wp := Db.WalPath;
  finally
    Db.Free;
  end;
  PatchFile(wp, AOffset, ABytes);

  Result := False;
  Db := TVDb.Create;
  try
    Db.Open(dir);
    Chk(AName + '/replay-returns', Db.ReplayWAL,
      'ReplayWAL False (bozuk kuyruk True donmeli)');
    Result := not HasKey(Db, 1, v);
    Chk(AName + '/not-applied', Result, 'bozuk kayit uygulandi: v=''' + v + '''');
    Chk(AName + '/wal-removed', not FileExists(wp), '.wal silinmedi');
  finally
    Db.Free;
  end;
end;

procedure K4_CrcCorruption;
var
  b: array[0..0] of Byte;
begin
  b[0] := $FF;
  CorruptionCase('k4_crc', OFF_CRC, b);
end;

procedure K5_BadMagic;
var
  b: array[0..3] of Byte;
begin
  b[0] := 0; b[1] := 0; b[2] := 0; b[3] := 0;
  CorruptionCase('k5_magic', OFF_MAGIC, b);
end;

{ ------------------------------ K6 / K7 ----------------------------------- }

procedure K6_DelWithValueRejected;
var
  dir: string;
  Db: TVDb;
begin
  dir := FreshDir('k6');
  Db := TVDb.Create;
  try
    Db.Open(dir);
    Chk('k6/rejected',
      not Db.WriteAheadWAL(1, BytesOf('abc'), VDB_FLAG_DEL),
      'DEL + deger kabul edildi');
    Chk('k6/no-record', Db.WalRecordCount = 0,
      'WalRecordCount=' + IntToStr(Db.WalRecordCount));
    Chk('k6/del-empty-ok', Db.WriteAheadWAL(2, nil, VDB_FLAG_DEL),
      'bos DEL reddedildi');
    Chk('k6/one-record', Db.WalRecordCount = 1,
      'WalRecordCount=' + IntToStr(Db.WalRecordCount));
  finally
    Db.Free;
  end;
end;

procedure K7_OversizedValueRejected;
var
  dir: string;
  Db: TVDb;
  big: TBytes;
begin
  dir := FreshDir('k7');
  Db := TVDb.Create;
  try
    Db.Open(dir);
    SetLength(big, VDB_MAX_VALUE + 1);
    Chk('k7/rejected', not Db.WriteAheadWAL(1, big),
      'VDB_MAX_VALUE ustu deger kabul edildi');
    Chk('k7/no-record', Db.WalRecordCount = 0,
      'WalRecordCount=' + IntToStr(Db.WalRecordCount));
  finally
    Db.Free;
  end;
end;

{ --------------------------------- main ----------------------------------- }

begin
  GPass := 0;
  GFail := 0;
  WriteLn('VDB KV-WAL crash matrix');
  try
    K1_WriteReplayDurability;
    K2_ReplayIdempotent;
    K3_TornRecord;
    K4_CrcCorruption;
    K5_BadMagic;
    K6_DelWithValueRejected;
    K7_OversizedValueRejected;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL exception: ', E.ClassName, ': ', E.Message);
    end;
  end;

  WriteLn('');
  WriteLn(IntToStr(GPass), ' passed / ', IntToStr(GFail), ' failed');
  if GFail = 0 then
    WriteLn('RESULT: PASS')
  else
    WriteLn('RESULT: FAIL');
  Halt(GFail);
end.
