unit VDbWal;

{ VDB Write-Ahead Log (WAL) - Motor Katmani
  .odb dosyasini bozmadan harici .wal kullanir.
  VDB v2 formatiyla uyumlu (BATCHEND flags=2 atomik commit).
  Sadece VDbCore.pas ile calisir; yonetim (GUI) disinda kalir. }

{$mode delphi}

interface

uses
  Classes, SysUtils, VDbCore;

const
  WAL_FILE_MAGIC: LongWord = $314C4157; // 'WAL1' LE (VDB'den farkli)
  WAL_FILE_VER: LongWord = 1;

function WalWriteAhead(const DbPath: string; const Key: QWord;
  const Value: TBytes; Flags: Byte): Boolean;
function WalReplay(const DbPath: string): Boolean;
function WalCheckpoint(const DbPath: string): Boolean;
function WalExists(const DbPath: string): Boolean;

implementation

function WalPath(const DbPath: string): string;
begin
  Result := ChangeFileExt(DbPath, '.wal');
end;

function WalExists(const DbPath: string): Boolean;
begin
  Result := FileExists(WalPath(DbPath));
end;

function WalWriteAhead(const DbPath: string; const Key: QWord;
  const Value: TBytes; Flags: Byte): Boolean;
var
  fs: TFileStream;
  rec: TVDbRecHead;
  crcVal: LongWord;
begin
  Result := False;
  if Length(Value) > VDB_MAX_VALUE then Exit;
  fs := TFileStream.Create(WalPath(DbPath), fmCreate or fmOpenWrite or fmShareExclusive);
  try
    fs.Seek(0, soFromEnd);
    rec.Magic := VDB_MAGIC;
    rec.Seq := FileSize(WalPath(DbPath)) div SizeOf(TVDbRecHead) + 1; // basit sira
    rec.Key := Key;
    rec.ValLen := Length(Value);
    rec.Flags := Flags;
    // Not: Gercek CRC32 hesaplamasi VDbCrc32.pas ile eklenmeli
    rec.Crc := 0; // Gecici - CRC32 hesaplanacak
    fs.Write(rec, SizeOf(rec));
    if Length(Value) > 0 then
      fs.Write(Value[0], Length(Value));
    fs.Flush;
    Result := True;
  finally
    fs.Free;
  end;
end;

function WalReplay(const DbPath: string): Boolean;
begin
  // Replay mantigi: .wal kayitlarini .odb'ye uygula
  // VDbCore.pas'deki Append mantigi kullanilarak
  Result := False; // Temel iskelet - Replay implementasyonu
end;

function WalCheckpoint(const DbPath: string): Boolean;
begin
  // .wal sil - sadece .odb basarili guncellenince
  if FileExists(WalPath(DbPath)) then
    DeleteFile(WalPath(DbPath));
  Result := not FileExists(WalPath(DbPath));
end;

end.
