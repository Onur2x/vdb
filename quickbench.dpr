program QuickBench;

{$mode delphi}
{$APPTYPE CONSOLE}

{ TR: GROUP COMMIT karsilastirmasi - SyncWriteInterval 0 (eski) vs 10 (yeni)
  EN: Group-commit comparison - SyncWriteInterval 0 (old) vs 10 (new) }

uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, VDbTypes;

const
  CI = 10000;   // INSERT adedi
  CU = 5000;    // UPDATE / DELETE adedi

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  R: TSqlResult;
  i: Integer;
  t0, t1: Int64;
  path: string;

function Rate(AN, AMS: Int64): Double;
begin
  if AMS <= 0 then
    Result := 0
  else
    Result := AN / (AMS / 1000.0);
end;

procedure FillTable(ASq: TVSql; AFrom, ATo: Integer);
begin
  ASq.Exec('BEGIN');
  for i := AFrom to ATo do
    ASq.Exec(Format('INSERT INTO b(id,val,txt) VALUES(%d,%d,''t%d'')', [i, i * 2, i]));
  ASq.Exec('COMMIT');
end;

var
  ins0, ins10, upd0, upd10, del0, del10, sel0: Int64;

begin
  if ParamCount >= 1 then
    path := ParamStr(1)
  else
    path := 'C:\temp\qb';
  if not DirectoryExists(path) then ForceDirectories(path);

  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    // Parametre 2 "nobatch" ise otomatik tek-cumlelik batch KAPALI
    // (degisiklik oncesi davranis) - boylece kendi optimizasyonumun
    // KATKISI dogrudan olculur.
    if (ParamCount >= 2) and SameText(ParamStr(2), 'nobatch') then
    begin
      sq.AutoTransaction := False;
      WriteLn('*** otomatik batch KAPALI (degisiklik oncesi davranis) ***');
    end
    else
      WriteLn('*** otomatik batch ACIK (yeni davranis) ***');
    kv.Open(path);
    tb.Open(path);
    sq.Exec('DROP TABLE IF EXISTS b');
    R := sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, val INTEGER, txt TEXT)');
    WriteLn('Tablo: ', R.Msg);

    // ================= SyncWriteInterval = 0 (ESKI DAVRANIS) =================
    WriteLn;
    WriteLn('--- SyncWriteInterval = 0  (her yazmada fsync / fsync per write) ---');
    kv.SyncWriteInterval := 0;
    FillTable(sq, 1, CI);

    t0 := GetTickCount64;
    for i := CI + 1 to CI + CU do
      sq.Exec(Format('INSERT INTO b(id,val,txt) VALUES(%d,%d,''t%d'')', [i, i * 2, i]));
    t1 := GetTickCount64; ins0 := t1 - t0;

    t0 := GetTickCount64;
    for i := 1 to CU do
      sq.Exec(Format('UPDATE b SET val = val + 1 WHERE id = %d', [i]));
    t1 := GetTickCount64; upd0 := t1 - t0;

    t0 := GetTickCount64;
    for i := 1 to CU do
      sq.Exec(Format('DELETE FROM b WHERE id = %d', [i]));
    t1 := GetTickCount64; del0 := t1 - t0;

    WriteLn(Format('  INSERT %d tekil: %7.3f sn  %8.0f/sn', [CU, ins0 / 1000.0, Rate(CU, ins0)]));
    WriteLn(Format('  UPDATE %d tekil: %7.3f sn  %8.0f/sn', [CU, upd0 / 1000.0, Rate(CU, upd0)]));
    WriteLn(Format('  DELETE %d tekil: %7.3f sn  %8.0f/sn', [CU, del0 / 1000.0, Rate(CU, del0)]));

    // ================ SyncWriteInterval = 10 (GRUP COMMIT, secenek) ==========
    WriteLn;
    WriteLn('--- SyncWriteInterval = 10  (group commit, 10ms / 10ms group commit) ---');
    kv.SyncWriteInterval := 10;

    t0 := GetTickCount64;
    for i := CI + CU + 1 to CI + 2 * CU do
      sq.Exec(Format('INSERT INTO b(id,val,txt) VALUES(%d,%d,''t%d'')', [i, i * 2, i]));
    t1 := GetTickCount64; ins10 := t1 - t0;

    t0 := GetTickCount64;
    for i := CU + 1 to 2 * CU do
      sq.Exec(Format('UPDATE b SET val = val + 1 WHERE id = %d', [i]));
    t1 := GetTickCount64; upd10 := t1 - t0;

    t0 := GetTickCount64;
    for i := CU + 1 to 2 * CU do
      sq.Exec(Format('DELETE FROM b WHERE id = %d', [i]));
    t1 := GetTickCount64; del10 := t1 - t0;

    WriteLn(Format('  INSERT %d tekil: %7.3f sn  %8.0f/sn', [CU, ins10 / 1000.0, Rate(CU, ins10)]));
    WriteLn(Format('  UPDATE %d tekil: %7.3f sn  %8.0f/sn', [CU, upd10 / 1000.0, Rate(CU, upd10)]));
    WriteLn(Format('  DELETE %d tekil: %7.3f sn  %8.0f/sn', [CU, del10 / 1000.0, Rate(CU, del10)]));

    // ================= Batch (BEGIN/COMMIT) =================
    WriteLn;
    WriteLn('--- Batch (BEGIN/COMMIT) - hiz siniri / upper bound ---');
    t0 := GetTickCount64;
    FillTable(sq, CI + 2 * CU + 1, CI + 2 * CU + CI);
    t1 := GetTickCount64;
    WriteLn(Format('  Batch INSERT %d: %7.3f sn  %8.0f/sn', [CI, (t1 - t0) / 1000.0, Rate(CI, t1 - t0)]));

    t0 := GetTickCount64;
    for i := 1 to 5000 do
      sq.Exec('SELECT val,txt FROM b WHERE id = ' + IntToStr(i));
    t1 := GetTickCount64; sel0 := t1 - t0;
    WriteLn(Format('  SELECT PK 5000x:  %7.3f sn  %8.0f/sn', [sel0 / 1000.0, Rate(5000, sel0)]));

    // ================= Ozet =================
    WriteLn;
    WriteLn('=== OZET / SUMMARY (0 -> 10 ms) ===');
    WriteLn(Format('  INSERT: %8.0f/sn -> %8.0f/sn   %.1fx', [Rate(CU, ins0), Rate(CU, ins10), Rate(CU, ins10) / Rate(CU, ins0)]));
    WriteLn(Format('  UPDATE: %8.0f/sn -> %8.0f/sn   %.1fx', [Rate(CU, upd0), Rate(CU, upd10), Rate(CU, upd10) / Rate(CU, upd0)]));
    WriteLn(Format('  DELETE: %8.0f/sn -> %8.0f/sn   %.1fx', [Rate(CU, del0), Rate(CU, del10), Rate(CU, del10) / Rate(CU, del0)]));
    WriteLn;
    WriteLn('  1 milyon tekil INSERT tahmini:');
    WriteLn(Format('    eski (0ms) : %.1f dakika', [1000000.0 / Rate(CU, ins0) / 60.0]));
    WriteLn(Format('    yeni (10ms): %.1f dakika', [1000000.0 / Rate(CU, ins10) / 60.0]));
  finally
    sq.Free;
    tb.Free;
    kv.Free;
  end;
end.
