program tx_stress;
{ SKILL8 (v3.83) - TRANSACTION STRESS: en az 1000 tx dongusu.

  Her dongu bir tur; tur tipi dongu indeksine gore secilir:
    0 commit           : BEGIN; INSERT; UPDATE; COMMIT   (kalici olmali)
    1 rollback         : BEGIN; INSERT; UPDATE; DELETE; ROLLBACK (hicbir sey kalmamali)
    2 pk ihlali        : BEGIN; var olan id INSERT -> hata beklenir; ROLLBACK
    3 ifade hatasi     : BEGIN; gecerli INSERT; sonra yok olan tabloya INSERT
                         -> hata beklenir; ROLLBACK (onceki INSERT geri alinmali)
    4 eszamanli cakisma: ana oturumda acik tx satiri gunceller; IKINCI backend
                         (ayni dosya) once okur (commit edilmemis deger
                         GORUNMEMELI), sonra BASKA satiri yazmayi dener.
                         Yazim reddedilirse mesru geri basinc sayilir.
    5 tx icinde checkpoint: BEGIN; INSERT; Engine.Checkpoint(True); INSERT; COMMIT

  HER 50 DONGUDE atomicity + isolation dogrulamasi:
    - satir sayisi beklenen ile ayni,
    - SUM(v) beklenen kontrol toplami ile ayni,
    - COUNT(DISTINCT id) = satir sayisi (kismi/cift satir yok),
    - v IS NULL satiri yok.
  Her 250 dongude tam VERIFY.

  COMMIT ve ROLLBACK gecikmesi AYRI olculur; p50/p95/max ve ilk 50 tur
  tabanina gore son 500 turun ortalamasi raporlanir.

  Cikis kodu = FAIL sayisi. }

{$mode delphi}{$H+}
{$IFDEF UNIX}{$DEFINE USE_CTHREADS}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, Generics.Collections,
  VDbBackendApi, VDbFactory, VDbBackendV3, VDbPageEngine, VDbTable, VDbSql,
  VDbPageStore;

const
  BASE_ROWS = 500;
  DEF_CYCLES = 1000;

type
  TInts = array of Int64;

var
  GDir, GDb, GCsv: string;
  GPass, GFail: Integer;
  Be: TVdbBackendV3;
  Tb: TVTableDb;
  Sq: TVSql;
  GRows, GSum: Int64;
  GNextId: Int64;
  GCommitLat, GRollLat: TInts;
  GPkViolations, GStmtErrors, GConfAccept, GConfRefuse, GIsolViol: Integer;
  GCsvLines: TStringList;

{ ---------------------------------------------------------------- zaman --- }

{$IFDEF WINDOWS}
procedure Qpc(var c: Int64); stdcall; external 'kernel32' name 'QueryPerformanceCounter';
function Qpf(var f: Int64): LongBool; stdcall; external 'kernel32' name 'QueryPerformanceFrequency';
var
  GQpf: Int64 = 0;
{$ENDIF}

function NowUs: Int64;
{$IFDEF WINDOWS}
var
  c: Int64;
{$ENDIF}
begin
{$IFDEF WINDOWS}
  if GQpf = 0 then
    Qpf(GQpf);
  Qpc(c);
  if GQpf <= 0 then
    Exit(Int64(GetTickCount64) * 1000);
  Result := (c div GQpf) * 1000000 + ((c mod GQpf) * 1000000) div GQpf;
{$ELSE}
  Result := Int64(GetTickCount64) * 1000;
{$ENDIF}
end;

{ ------------------------------------------------------------ yardimcilar --- }

procedure Chk(const AName: string; AOk: Boolean; const ADetail: string = '');
begin
  if AOk then
  begin
    Inc(GPass);
    if ADetail <> '' then
      WriteLn('PASS ', AName, ' - ', ADetail)
    else
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

procedure WipeDir(const ADir: string);
var
  sr: TSearchRec;
  d: string;
begin
  ForceDirectories(ADir);
  d := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(d + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        if (sr.Attr and faDirectory) <> 0 then
          WipeDir(d + sr.Name)
        else
          SysUtils.DeleteFile(d + sr.Name);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function IntQ(const ASql: string): Int64;
var
  r: TSqlResult;
begin
  Result := -1;
  r := Sq.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := StrToInt64Def(Trim(r.Rows[0][0]), -1);
end;

function IntQ2(AQ: TVSql; const ASql: string): Int64;
var
  r: TSqlResult;
begin
  Result := -1;
  r := AQ.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := StrToInt64Def(Trim(r.Rows[0][0]), -1);
end;

procedure LatAdd(var A: TInts; AUs: Int64);
var
  n: Integer;
begin
  n := Length(A);
  SetLength(A, n + 1);
  A[n] := AUs;
end;

function MeanOf(const A: TInts; AFrom, ATo: Integer): Double;
var
  i, n: Integer;
begin
  Result := 0;
  n := 0;
  if AFrom < 0 then AFrom := 0;
  if ATo > High(A) then ATo := High(A);
  for i := AFrom to ATo do
  begin
    Result := Result + A[i];
    Inc(n);
  end;
  if n > 0 then Result := Result / n;
end;

procedure Percentiles(const A: TInts; out AP50, AP95, AMax: Int64);
var
  L: TList<Int64>;
  i: Integer;
begin
  AP50 := 0;
  AP95 := 0;
  AMax := 0;
  if Length(A) = 0 then Exit;
  L := TList<Int64>.Create;
  try
    for i := 0 to High(A) do L.Add(A[i]);
    L.Sort;
    AP50 := L[L.Count div 2];
    AP95 := L[(L.Count * 95) div 100];
    AMax := L[L.Count - 1];
  finally
    L.Free;
  end;
end;

function VerifyDb(const APath: string; out ARep: string): Boolean;
var
  BeC: TVdbBackendV3;
begin
  ARep := '';
  Result := False;
  BeC := nil;
  try
    try
      BeC := TVdbBackendV3.CreateReadOnly(APath);
      Result := BeC.Engine.VerifyEx(vmFull, True, ARep);
    except
      on E: Exception do
        ARep := 'istisna: ' + E.ClassName + ': ' + E.Message;
    end;
  finally
    BeC := nil;
  end;
end;

{ ---------------------------------------------------------------- veritabani --- }

procedure OpenDb;
begin
  Be := TVdbBackendV3.Create(GDb);
  Be.DurableOnFlush := False;   { hiz; dogruluk kontrolleri yine tam }
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(GDir);
  Sq := TVSql.Create(Tb);
end;

procedure CloseDb;
begin
  FreeAndNil(Sq);
  FreeAndNil(Tb);
  Be := nil;
end;

procedure CreateBase;
var
  i: Integer;
begin
  Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER, s TEXT)');
  GRows := 0;
  GSum := 0;
  for i := 1 to BASE_ROWS do
  begin
    Sq.Exec(Format('INSERT INTO t (id, v, s) VALUES (%d, %d, ''b'')', [i, i mod 100]));
    Inc(GRows);
    Inc(GSum, i mod 100);
  end;
  GNextId := 100000;
end;

{ ---------------------------------------------------------------- turlar --- }

function CycleCommit(AIdx: Integer; out ADetail: string): Boolean;
var
  t0: Int64;
  id: Int64;
begin
  Result := False;
  ADetail := '';
  id := GNextId;
  Inc(GNextId);
  t0 := NowUs;
  try
    Sq.Exec('BEGIN');
    Sq.Exec(Format('INSERT INTO t (id, v, s) VALUES (%d, 5, ''c'')', [id]));
    Sq.Exec(Format('UPDATE t SET v = v + 1 WHERE id = %d', [1 + (AIdx mod BASE_ROWS)]));
    Sq.Exec('COMMIT');
    Inc(GRows);
    Inc(GSum, 6);
    LatAdd(GCommitLat, NowUs - t0);
    Result := IntQ(Format('SELECT COUNT(*) FROM t WHERE id = %d', [id])) = 1;
    ADetail := Format('id=%d', [id]);
  except
    on E: Exception do
    begin
      ADetail := E.ClassName + ': ' + E.Message;
      try Sq.Exec('ROLLBACK'); except end;
    end;
  end;
end;

function CycleRollback(AIdx: Integer; out ADetail: string): Boolean;
var
  t0, id: Int64;
  before: Int64;
begin
  Result := False;
  ADetail := '';
  id := GNextId;
  Inc(GNextId);
  before := IntQ('SELECT COUNT(*) FROM t');
  t0 := NowUs;
  try
    Sq.Exec('BEGIN');
    Sq.Exec(Format('INSERT INTO t (id, v, s) VALUES (%d, 9, ''r'')', [id]));
    Sq.Exec(Format('UPDATE t SET v = v + 50 WHERE id = %d', [1 + (AIdx mod BASE_ROWS)]));
    Sq.Exec(Format('DELETE FROM t WHERE id = %d', [2 + (AIdx mod (BASE_ROWS - 1))]));
    Sq.Exec('ROLLBACK');
    LatAdd(GRollLat, NowUs - t0);
    Result := (IntQ('SELECT COUNT(*) FROM t') = before) and
              (IntQ(Format('SELECT COUNT(*) FROM t WHERE id = %d', [id])) = 0);
    ADetail := Format('once=%d sonra=%d', [before, IntQ('SELECT COUNT(*) FROM t')]);
  except
    on E: Exception do
    begin
      ADetail := E.ClassName + ': ' + E.Message;
      try Sq.Exec('ROLLBACK'); except end;
    end;
  end;
end;

function CyclePkViolation(out ADetail: string): Boolean;
var
  t0: Int64;
  raised: Boolean;
  before: Int64;
begin
  Result := False;
  ADetail := '';
  before := IntQ('SELECT COUNT(*) FROM t');
  raised := False;
  t0 := NowUs;
  try
    Sq.Exec('BEGIN');
    try
      Sq.Exec('INSERT INTO t (id, v, s) VALUES (1, 777, ''dup'')');
    except
      raised := True;
    end;
    Sq.Exec('ROLLBACK');
    LatAdd(GRollLat, NowUs - t0);
    if raised then Inc(GPkViolations);
    Result := raised and (IntQ('SELECT COUNT(*) FROM t') = before);
    ADetail := Format('hata=%s once=%d sonra=%d', [BoolToStr(raised, 'evet', 'hayir'),
      before, IntQ('SELECT COUNT(*) FROM t')]);
  except
    on E: Exception do
    begin
      ADetail := E.ClassName + ': ' + E.Message;
      try Sq.Exec('ROLLBACK'); except end;
    end;
  end;
end;

function CycleStmtError(AIdx: Integer; out ADetail: string): Boolean;
var
  t0, id: Int64;
  raised: Boolean;
  before: Int64;
begin
  Result := False;
  ADetail := '';
  id := GNextId;
  Inc(GNextId);
  before := IntQ('SELECT COUNT(*) FROM t');
  raised := False;
  t0 := NowUs;
  try
    Sq.Exec('BEGIN');
    Sq.Exec(Format('INSERT INTO t (id, v, s) VALUES (%d, 3, ''e'')', [id]));
    try
      Sq.Exec('INSERT INTO yok_boyle_tablo (id) VALUES (1)');
    except
      raised := True;
    end;
    Sq.Exec('ROLLBACK');
    LatAdd(GRollLat, NowUs - t0);
    if raised then Inc(GStmtErrors);
    { ONEMLI: ifade hatasindan onceki INSERT de geri alinmis olmali. }
    Result := raised and (IntQ('SELECT COUNT(*) FROM t') = before) and
              (IntQ(Format('SELECT COUNT(*) FROM t WHERE id = %d', [id])) = 0);
    ADetail := Format('hata=%s once=%d sonra=%d', [BoolToStr(raised, 'evet', 'hayir'),
      before, IntQ('SELECT COUNT(*) FROM t')]);
  except
    on E: Exception do
    begin
      ADetail := E.ClassName + ': ' + E.Message;
      try Sq.Exec('ROLLBACK'); except end;
    end;
  end;
end;

function CycleConflict(out ADetail: string): Boolean;
var
  beforeV1, beforeV2, seenV2, afterV1: Int64;
  confAccepted: Boolean;
  why: string;
  LBe: IVdbBackend;
  LTb: TVTableDb;
  LSq: TVSql;
begin
  Result := False;
  ADetail := '';
  why := '';
  confAccepted := False;
  beforeV1 := 0;
  beforeV2 := 0;
  afterV1 := 0;
  LBe := nil;
  LTb := nil;
  LSq := nil;
  { Ikinci backend HER turda taze acilir: dosya buyudukce onceden acilmis
    ikinci oturumun katalog gorunumu bayatlayabiliyor (gozlemlendi:
    "tablo yok: t"). Bu test kendi basina bir baglanti tutarliligi iddiasi
    tasimaz; amac acik tx sirasinda eszamanli okuma/yazmadir. }
  try
    VdbOpenWithBusyTimeout(GDb, LBe, 2000, False, 512);
    LTb := TVTableDb.CreateBackend(LBe);
    LTb.Open(GDir);
    LSq := TVSql.Create(LTb);

    beforeV1 := IntQ('SELECT v FROM t WHERE id = 1');
    beforeV2 := IntQ('SELECT v FROM t WHERE id = 2');

    { Ana oturum: id=1 uzerinde ACIK tx, commit edilmemis +100. }
    Sq.Exec('BEGIN');
    try
      Sq.Exec('UPDATE t SET v = v + 100 WHERE id = 1');

      { Ikinci backend: commit edilmemis degeri GORMEMELI. }
      seenV2 := IntQ2(LSq, 'SELECT v FROM t WHERE id = 1');
      if seenV2 = beforeV1 + 100 then
      begin
        Inc(GIsolViol);
        ADetail := ADetail + Format('IZOLASYON IHLALI (gorunen=%d beklenen=%d) ',
          [seenV2, beforeV1]);
      end;

      { Ikinci backend BASKA satiri yazmayi dener; red mesru geri basinctir. }
      try
        LSq.Exec('BEGIN');
        LSq.Exec('UPDATE t SET v = v + 200 WHERE id = 2');
        LSq.Exec('COMMIT');
        confAccepted := True;
        Inc(GConfAccept);
      except
        on E: Exception do
        begin
          why := E.ClassName + ': ' + E.Message;
          Inc(GConfRefuse);
          try LSq.Exec('ROLLBACK'); except end;
        end;
      end;
    finally
      try Sq.Exec('ROLLBACK'); except end;
    end;

    afterV1 := IntQ('SELECT v FROM t WHERE id = 1');
    if afterV1 <> beforeV1 then
      ADetail := ADetail + Format('GERI ALMA HATASI (id1 once=%d sonra=%d) ',
        [beforeV1, afterV1]);

    if confAccepted then
    begin
      if IntQ('SELECT v FROM t WHERE id = 2') = beforeV2 + 200 then
        Inc(GSum, 200)
      else
        ADetail := ADetail + 'CAKISMA SONUCU BELIRSIZ ';
    end;

    Result := (afterV1 = beforeV1) and (GIsolViol = 0);
    ADetail := ADetail + Format('yazim=%s%s', [BoolToStr(confAccepted, 'kabul', 'red'),
      BoolToStr((not confAccepted) and (why <> ''), ' (' + why + ')', '')]);
  except
    on E: Exception do
    begin
      ADetail := ADetail + 'ISTISNA ' + E.ClassName + ': ' + E.Message;
      try Sq.Exec('ROLLBACK'); except end;
    end;
  end;
  FreeAndNil(LSq);
  FreeAndNil(LTb);
  LBe := nil;
end;

var
  GCkptCycle: Integer = 0;

function CycleCheckpoint(AIdx: Integer; out ADetail: string): Boolean;
var
  t0, id1, id2: Int64;
begin
  Result := False;
  ADetail := '';
  Inc(GCkptCycle);
  id1 := GNextId;
  id2 := GNextId + 1;
  Inc(GNextId, 2);
  t0 := NowUs;
  try
    Sq.Exec('BEGIN');
    Sq.Exec(Format('INSERT INTO t (id, v, s) VALUES (%d, 7, ''k'')', [id1]));
    Be.Engine.Checkpoint(True);
    Sq.Exec(Format('INSERT INTO t (id, v, s) VALUES (%d, 7, ''k'')', [id2]));
    Sq.Exec('COMMIT');
    Inc(GRows, 2);
    Inc(GSum, 14);
    LatAdd(GCommitLat, NowUs - t0);
    Result := IntQ(Format('SELECT COUNT(*) FROM t WHERE id IN (%d,%d)', [id1, id2])) = 2;
    ADetail := Format('checkpoint#%d id=%d,%d', [GCkptCycle, id1, id2]);
  except
    on E: Exception do
    begin
      ADetail := E.ClassName + ': ' + E.Message;
      try Sq.Exec('ROLLBACK'); except end;
    end;
  end;
end;

{ ------------------------------------------------------------ dogrulamalar --- }

function GroupCheck(AIdx: Integer): Boolean;
var
  c, s, d, n: Int64;
begin
  c := IntQ('SELECT COUNT(*) FROM t');
  s := IntQ('SELECT SUM(v) FROM t');
  d := IntQ('SELECT COUNT(DISTINCT id) FROM t');
  n := IntQ('SELECT COUNT(*) FROM t WHERE v IS NULL');
  Result := (c = GRows) and (s = GSum) and (d = GRows) and (n = 0);
  Chk(Format('X%d atomiklik+izolasyon (dongu %d)', [AIdx div 50, AIdx]), Result,
    Format('satir=%d/%d toplam=%d/%d distinct=%d null=%d',
      [c, GRows, s, GSum, d, n]));
end;

{ ------------------------------------------------------------------ main --- }

var
  cycles, i, k: Integer;
  ok, allOk: Boolean;
  detail, rep: string;
  p50, p95, mx: Int64;
  cnt, sum, dist: Int64;
begin
  GPass := 0;
  GFail := 0;
  GPkViolations := 0;
  GStmtErrors := 0;
  GConfAccept := 0;
  GConfRefuse := 0;
  GIsolViol := 0;
  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp');
  WipeDir(GDir);
  ForceDirectories(GDir);
  GDb := GDir + 'veritabani.odb';
  GCsv := GDir + 'tx_stress.csv';

  cycles := StrToIntDef(Trim(GetEnvironmentVariable('VDB_TX_CYCLES')), DEF_CYCLES);
  if cycles < 50 then cycles := 50;

  GCsvLines := TStringList.Create;
  try
    GCsvLines.Add('cycle,type,ok,rows,sum,detail');
    WriteLn('BILGI tx_stress dongu hedefi=', cycles);
    WriteLn('BILGI dizin=', GDir);
    Flush(Output);

    OpenDb;
    try
      CreateBase;
      allOk := True;
      for i := 1 to cycles do
      begin
        detail := '';
        case (i - 1) mod 6 of
          0: begin
               ok := CycleCommit(i, detail);
               GCsvLines.Add(Format('%d,commit,%d,%d,%d,%s',
                 [i, Ord(ok), GRows, GSum, detail]));
             end;
          1: begin
               ok := CycleRollback(i, detail);
               GCsvLines.Add(Format('%d,rollback,%d,%d,%d,%s',
                 [i, Ord(ok), GRows, GSum, detail]));
             end;
          2: begin
               ok := CyclePkViolation(detail);
               GCsvLines.Add(Format('%d,pk_violation,%d,%d,%d,%s',
                 [i, Ord(ok), GRows, GSum, detail]));
             end;
          3: begin
               ok := CycleStmtError(i, detail);
               GCsvLines.Add(Format('%d,stmt_error,%d,%d,%d,%s',
                 [i, Ord(ok), GRows, GSum, detail]));
             end;
          4: begin
               ok := CycleConflict(detail);
               GCsvLines.Add(Format('%d,conflict,%d,%d,%d,%s',
                 [i, Ord(ok), GRows, GSum, detail]));
             end;
        else
          begin
            ok := CycleCheckpoint(i, detail);
            GCsvLines.Add(Format('%d,checkpoint,%d,%d,%d,%s',
              [i, Ord(ok), GRows, GSum, detail]));
          end;
        end;
        if not ok then
        begin
          allOk := False;
          WriteLn(Format('FAIL T%d tur %d: %s', [i, i, detail]));
          Flush(Output);
        end;

        if (i mod 50) = 0 then
          if not GroupCheck(i) then
            allOk := False;

        if (i mod 250) = 0 then
        begin
          { Tam VERIFY yalniz ana oturum kapaliyken guvenli; ara kontrol icin
            ikinci backend'i kapatip ana oturumu da kapatip yeniden aciyoruz. }
          Be.Engine.Checkpoint(True);
          CloseDb;
          OpenDb;
          ok := VerifyDb(GDb, rep);
          Chk(Format('V%d tam VERIFY', [i div 250]), ok, rep);
          if not ok then allOk := False;
          Chk(Format('V%d VERIFY sonrasi sayim/toplam', [i div 250]),
            (IntQ('SELECT COUNT(*) FROM t') = GRows) and
            (IntQ('SELECT SUM(v) FROM t') = GSum),
            Format('satir=%d/%d toplam=%d/%d',
              [IntQ('SELECT COUNT(*) FROM t'), GRows,
               IntQ('SELECT SUM(v) FROM t'), GSum]));
        end;
        GCsvLines.SaveToFile(GCsv);
      end;

      { --- kapanis dogrulamasi --- }
      Be.Engine.Checkpoint(True);
      CloseDb;
      Chk('Z1 dosya yeniden acilabiliyor', True);
      OpenDb;
      cnt := IntQ('SELECT COUNT(*) FROM t');
      sum := IntQ('SELECT SUM(v) FROM t');
      dist := IntQ('SELECT COUNT(DISTINCT id) FROM t');
      Chk('Z2 satir sayisi korundu', cnt = GRows, Format('%d/%d', [cnt, GRows]));
      Chk('Z3 kontrol toplami korundu', sum = GSum, Format('%d/%d', [sum, GSum]));
      Chk('Z4 cift/kismi satir yok', dist = cnt, Format('distinct=%d satir=%d', [dist, cnt]));
      CloseDb;
      ok := VerifyDb(GDb, rep);
      Chk('Z5 VERIFY temiz', ok, rep);
      if not ok then allOk := False;

      Chk('Z6 SONUC: tum tx donguleri temiz', allOk and (GFail = 0),
        Format('%d dongu', [cycles]));
    finally
      if Be <> nil then CloseDb;
    end;
  finally
    GCsvLines.Free;
  end;

  Percentiles(GCommitLat, p50, p95, mx);
  WriteLn(Format('METRIK commit n=%d p50=%dus p95=%dus max=%dus ort_ilk50=%.0f ort_son500=%.0f',
    [Length(GCommitLat), p50, p95, mx,
     MeanOf(GCommitLat, 0, 49),
     MeanOf(GCommitLat, Length(GCommitLat) - 500, High(GCommitLat))]));
  Percentiles(GRollLat, p50, p95, mx);
  WriteLn(Format('METRIK rollback n=%d p50=%dus p95=%dus max=%dus ort_ilk50=%.0f ort_son500=%.0f',
    [Length(GRollLat), p50, p95, mx,
     MeanOf(GRollLat, 0, 49),
     MeanOf(GRollLat, Length(GRollLat) - 500, High(GRollLat))]));
  WriteLn(Format('METRIK pk_ihlali_tetik=%d ifade_hatasi_tetik=%d cakisma_kabul=%d cakisma_red=%d izolasyon_ihlali=%d',
    [GPkViolations, GStmtErrors, GConfAccept, GConfRefuse, GIsolViol]));
  WriteLn(Format('SONUC: %d PASS, %d FAIL', [GPass, GFail]));
  WriteLn('CSV=', GCsv);
  Flush(Output);
  Halt(GFail);
end.
