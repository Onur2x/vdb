program p67diag;
{ P-67..P-74: batch INSERT dongusu ile CommitBatch ayrimi + yazma kumesi
  ilkel islemlerinin izole maliyeti + APPLPROF/CPUPROF profil cikisi.
  Kullanim: p67diag <dizin> [satir_sayisi]
  -dAPPLPROF ile derlenirse ApplyBatch/heap/tablo katmani alt zamanlarini
  da basar. }
{$mode delphi}{$H+}
uses
  Windows, SysUtils, Classes, Generics.Collections,
  VDbCore, VDbTypes, VDbTable, VDbSql,
  VDbBackendApi, VDbBackendV3, VDbPageHeap
  {$IFDEF CPUPROF}, VDbCpuProf{$ENDIF};

var
  gDir: string;
  gQpf: Int64;

function NowUs: Int64;
var
  c: Int64;
begin
  if gQpf = 0 then
    if not QueryPerformanceFrequency(gQpf) then gQpf := 1000;
  QueryPerformanceCounter(c);
  if gQpf >= 1000000 then
    Result := c div (gQpf div 1000000)
  else if gQpf >= 1000 then
    Result := (c * 1000) div gQpf
  else
    Result := c * 1000;
end;

var
  be: IVDbBackend;
  tb: TVTableDb;
  sq: TVSql;
  N, i, k: Integer;
  t0, t1, t2, t3: Int64;
  bGen, bLoop, bCommit, bFull: Int64;
  bMap, bList, bRecs, bMove, bStr: Int64;
  cn: array[0..2] of string;
  rows: array of array[0..2] of string;
  p: string;
  dummy: Integer;
  {$IFDEF APPLPROF}
  ai, at, al: Double;
  an: Int64;
  hi, hp, hg: Double;
  hn: Int64;
  tt, tm, tc, tw, te: Double;
  tn: Int64;
  {$ENDIF}

  // izole ilkel olcumleri icin
  map: TDictionary<QWord, Integer>;
  lst: TList<QWord>;
  recs: TList<Integer>;
  buf: TBytes;
  sa: array of string;
  key: QWord;

begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'kullanim: p67diag <dizin> [satir_sayisi]');
    Halt(2);
  end;
  gDir := ParamStr(1);
  N := 200000;
  if ParamCount >= 2 then N := StrToIntDef(ParamStr(2), 200000);
  bGen := High(Int64); bLoop := High(Int64); bCommit := High(Int64); bFull := High(Int64);
  bMap := High(Int64); bList := High(Int64); bRecs := High(Int64);
  bMove := High(Int64); bStr := High(Int64);
  cn[0] := 'id'; cn[1] := 'a'; cn[2] := 'b';
  SetLength(rows, N);

  for k := 1 to 5 do
  begin
    p := gDir + PathDelim + 'run' + IntToStr(k);
    ForceDirectories(p);
    SysUtils.DeleteFile(p + PathDelim + 'veritabani.odb');
    SysUtils.DeleteFile(p + PathDelim + 'veritabani.odb.idx');
    SysUtils.DeleteFile(p + PathDelim + 'veritabani.odb.wal');
    SysUtils.DeleteFile(p + PathDelim + 'veritabani.odb.undo');
    be := TVdbBackendV3.Create(IncludeTrailingPathDelimiter(p) + 'veritabani.odb', True, 512);
    tb := TVTableDb.CreateBackend(be);
    sq := TVSql.Create(tb);
    tb.Open(p);
    sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');

    { --- izole ilkel islemler --- }

    { Map: TryGetValue + Add (batch yazma kumesi Map'i gibi) }
    map := TDictionary<QWord, Integer>.Create;
    t0 := NowUs;
    for i := 0 to N - 1 do
    begin
      key := QWord(i) + 1;
      dummy := i;
      if not map.TryGetValue(key, dummy) then
        map.Add(key, i);
    end;
    t1 := NowUs;
    if t1 - t0 < bMap then bMap := t1 - t0;
    map.Free;

    { List<QWord>.Add }
    lst := TList<QWord>.Create;
    t0 := NowUs;
    for i := 0 to N - 1 do
      lst.Add(QWord(i) + 1);
    t1 := NowUs;
    if t1 - t0 < bList then bList := t1 - t0;
    lst.Free;

    { List<Integer>.Add (Recs'e benzer) }
    recs := TList<Integer>.Create;
    t0 := NowUs;
    for i := 0 to N - 1 do
      recs.Add(i);
    t1 := NowUs;
    if t1 - t0 < bRecs then bRecs := t1 - t0;
    recs.Free;

    { Buyuyen tampona 25 bayt Move (ValBuf gibi) }
    SetLength(buf, 64);
    t0 := NowUs;
    for i := 0 to N - 1 do
    begin
      if (i + 1) * 25 > Length(buf) then
        SetLength(buf, ((i + 1) * 25) * 2 + 256);
      Move(buf[0], buf[i * 25], 25);
    end;
    t1 := NowUs;
    if t1 - t0 < bMove then bMove := t1 - t0;

    { 3 string atamasi (kolon esleme gibi) }
    SetLength(sa, 3);
    t0 := NowUs;
    for i := 0 to N - 1 do
    begin
      sa[0] := rows[i][0];
      sa[1] := rows[i][1];
      sa[2] := rows[i][2];
    end;
    t1 := NowUs;
    if t1 - t0 < bStr then bStr := t1 - t0;

    { --- gercek yol --- }

    { Faz A: string uretimi }
    t0 := NowUs;
    for i := 0 to N - 1 do
    begin
      rows[i][0] := IntToStr(i + 1);
      rows[i][1] := IntToStr((i + 1) * 3);
      rows[i][2] := 'satir-' + IntToStr(i + 1);
    end;
    t1 := NowUs;
    if t1 - t0 < bGen then bGen := t1 - t0;

    { Faz B: insert DONGUSU + CommitBatch ayri }
    tb.SkipDupCheck := True;
    t1 := NowUs;
    tb.BeginBatch;
    for i := 0 to N - 1 do
      tb.Insert('t', cn, rows[i]);
    t2 := NowUs;
    {$IFDEF CPUPROF}
    FillChar(CP, SizeOf(CP), 0); CPN := 0;
    {$ENDIF}
    tb.CommitBatch;
    t3 := NowUs;
    tb.SkipDupCheck := False;
    if t2 - t1 < bLoop then bLoop := t2 - t1;
    if t3 - t2 < bCommit then bCommit := t3 - t2;
    {$IFDEF CPUPROF}
    if k = 5 then CpuProfDump;
    {$ENDIF}

    tb.Close;
    sq.Free;
    tb.Free;
    be := nil;
  end;

  WriteLn('=== p67diag  N=', N, '  (best-of-5) ===');
  WriteLn('--- izole ilke ---');
  WriteLn(Format('Map TryGet+Add           : %10.1f ms  (%.3f us/adim)', [bMap / 1000, bMap / N]));
  WriteLn(Format('List<QWord>.Add          : %10.1f ms  (%.3f us/adim)', [bList / 1000, bList / N]));
  WriteLn(Format('List<Integer>.Add        : %10.1f ms  (%.3f us/adim)', [bRecs / 1000, bRecs / N]));
  WriteLn(Format('ValBuf 25B Move+grow     : %10.1f ms  (%.3f us/adim)', [bMove / 1000, bMove / N]));
  WriteLn(Format('3 string atamasi         : %10.1f ms  (%.3f us/adim)', [bStr / 1000, bStr / N]));
  WriteLn('--- gercek yol (SkipDupCheck) ---');
  WriteLn(Format('string uretimi           : %10.1f ms  (%.3f us/satir)', [bGen / 1000, bGen / N]));
  WriteLn(Format('Insert dongusu           : %10.1f ms  (%.3f us/satir)', [bLoop / 1000, bLoop / N]));
  WriteLn(Format('CommitBatch              : %10.1f ms  (%.3f us/satir)', [bCommit / 1000, bCommit / N]));
  WriteLn(Format('TOPLAM (dongu+commit)    : %10.1f ms  (%.3f us/satir)',
    [(bLoop + bCommit) / 1000, (bLoop + bCommit) / N]));
  WriteLn('== bitti');
  {$IFDEF CPUPROF}
  CpuProfDump;
  {$ENDIF}
  {$IFDEF APPLPROF}
  VDbBackendV3.AppProfUs(ai, at, al, an);
  WriteLn('--- APPLPROF: ApplyBatch alt zamanlar (5 kosu toplam, QPC overhead dahil) ---');
  WriteLn(Format('FEng.Insert  : %10.1f ms  (%.3f us/satir)', [ai / 1000, ai / an]));
  WriteLn(Format('TagOf+TagAdd : %10.1f ms  (%.3f us/satir)', [at / 1000, at / an]));
  WriteLn(Format('LogPut       : %10.1f ms  (%.3f us/satir)', [al / 1000, al / an]));
  VDbPageHeap.HeapProfUs(hi, hp, hg, hn);
  WriteLn('--- APPLPROF: heap alt zamanlar ---');
  WriteLn(Format('Heap.Insert  : %10.1f ms  (%.3f us/satir)', [hi / 1000, hi / hn]));
  WriteLn(Format('PlaceCellKV  : %10.1f ms  (%.3f us/satir)', [hp / 1000, hp / hn]));
  WriteLn(Format('DirGrow      : %10.1f ms  (%.3f us/satir)', [hg / 1000, hg / hn]));
  WriteLn(Format('  (dizin+PageMapAdd kalani = Insert - PlaceCellKV - DirGrow: %.3f us/satir)',
    [(hi - hp - hg) / hn]));
  VDbTable.TableProfUs(tt, tm, tc, tw, te, tn);
  WriteLn('--- APPLPROF: tablo katmani (RDTSC; dongu toplamindan sapma = olcum overhead) ---');
  WriteLn(Format('Insert toplam: %10.1f ms  (%.3f us/satir)', [tt / 1000, tt / tn]));
  WriteLn(Format('kolon esleme : %10.1f ms  (%.3f us/satir)', [tm / 1000, tm / tn]));
  WriteLn(Format('PK+kontrol   : %10.1f ms  (%.3f us/satir)', [tc / 1000, tc / tn]));
  WriteLn(Format('Encode+PutPtr: %10.1f ms  (%.3f us/satir)', [tw / 1000, tw / tn]));
  WriteLn(Format('  EncodeRowInto: %10.1f ms  (%.3f us/satir)', [te / 1000, te / tn]));
  WriteLn(Format('  PutPtr       : %10.1f ms  (%.3f us/satir)', [(tw - te) / 1000, (tw - te) / tn]));
  WriteLn(Format('  (kalani = cagri + tablo kurulum: %.3f us/satir)',
    [(tt - tm - tc - tw) / tn]));
  {$ENDIF}
end.
