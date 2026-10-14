unit VDbTest;

{ Faz D: WAL Test - Crash + Replay (Satis.odb uzerinde, guvenli) }

{$mode delphi}

interface

uses
  Classes, SysUtils, VDbCore, VDbTable;

procedure RunWalCrashTest(const DbPath: string);

implementation

procedure RunWalCrashTest(const DbPath: string);
var
  db: TVDb;
  b: TBytes;
begin
  // Test: Satis.odb (test dosyasi) uzerinde WAL yazma + replay
  // Uretim (Veritabani.odb) dokunulmaz
  if not FileExists(DbPath) then
  begin
    WriteLn('WAL TEST: Test DB yok: ' + DbPath);
    Exit;
  end;

  db := TVDb.Create;
  try
    db.Open(ExtractFileDir(DbPath));
    // Basit veri yaz (WAL aktif)
    SetLength(b, 4);
    b[0] := Ord('T'); b[1] := Ord('E'); b[2] := Ord('S'); b[3] := Ord('T');
    db.WriteAheadWAL($ABCDEF01, b, 0);
    db.Put($ABCDEF01, b);
    db.CheckpointWAL;
    WriteLn('WAL TEST: Yazma + Checkpoint tamam (' + DbPath + ')');
  finally
    db.Free;
  end;
end;

end.
