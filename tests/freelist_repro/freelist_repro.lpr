program freelist_repro;
{ SKILL8 TESHIS ARACI - "freelist tutarsiz" hatasinin en kucuk tekrari.

  soak_phased q1 kosusunda, eszamanli yazicilar + ana is parcaciginda DELETE
  birlikte calisirken su hata 91884 kez uretildi:

    EVdbPageStore: freelist tutarsiz: sayfa 92 serbest listede ama 113 canli
                   hucre tasiyor

  Amac: hatanin SEBEBINI daraltmak. Bu bir urun testi DEGIL, teshis aracidir.

  Modlar (ParamStr(1)):
    seq    : TEK is parcacigi, IKI oturum sirayla (B: INSERT, A: DELETE).
             Threading yok. Hata burada da cikarsa sebep oturumlar arasi
             tazelik (threading suclu degil).
    seq1   : TEK is parcacigi, TEK oturum (B oturumu hic acilmaz). Kontrol
             grubu: tazelik yoksa hata da olmamali.
    thr    : IKI yazici thread + ana is parcaciginda DELETE (soak q1 deseni).

  Cikti: hata sinif sayimlari + ilk 5 mesaj + son VERIFY durumu.
  Cikis kodu her zaman 0'dir; bu arac hukum vermez, kanit toplar. }

{$mode delphi}{$H+}
{$IFDEF UNIX}{$DEFINE USE_CTHREADS}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  VDbBackendApi, VDbFactory, VDbBackendV3, VDbPageEngine, VDbTable, VDbSql,
  VDbPageStore;

const
  BASE_ROWS = 3000;

type
  TFailClass = (fcNone, fcLiveCells, fcNotInIndex, fcBroken, fcBusy, fcOther);

var
  GDir, GDb: string;
  GStop: Boolean;
  GLock: TCriticalSection;
  GCls: array[TFailClass] of Integer;
  GSamples: TStringList;

function Classify(const AMsg: string): TFailClass;
begin
  if Pos('canli hucre tasiyor', AMsg) > 0 then Exit(fcLiveCells);
  if Pos('serbest indeksinde yok', AMsg) > 0 then Exit(fcNotInIndex);
  if Pos('freelist bozuk', AMsg) > 0 then Exit(fcBroken);
  if (Pos('mesgul', AMsg) > 0) or (Pos('busy', AMsg) > 0) then Exit(fcBusy);
  Result := fcOther;
end;

procedure Note(AEx: Exception);
var
  c: TFailClass;
begin
  c := Classify(AEx.Message);
  GLock.Enter;
  try
    Inc(GCls[c]);
    if (GSamples.Count < 5) and (c <> fcBusy) then
      GSamples.Add(AEx.ClassName + ': ' + AEx.Message);
  finally
    GLock.Leave;
  end;
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

type
  TWriterThread = class(TThread)
  private
    FDb: string;
    FSeed: Integer;
    FOk, FErr: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const ADb: string; ASeed: Integer);
  end;

constructor TWriterThread.Create(const ADb: string; ASeed: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FDb := ADb;
  FSeed := ASeed;
  FOk := 0;
  FErr := 0;
end;

procedure TWriterThread.Execute;
var
  B: IVdbBackend;
  TB: TVTableDb;
  S: TVSql;
  n: Int64;
begin
  B := nil;
  TB := nil;
  S := nil;
  try
    VdbOpenWithBusyTimeout(FDb, B, 5000, False, 512);
    TB := TVTableDb.CreateBackend(B);
    TB.Open(ExtractFileDir(FDb));
    S := TVSql.Create(TB);
    n := 0;
    while not GStop do
    begin
      Inc(n);
      try
        S.Exec(Format('INSERT INTO t (id, v, s) VALUES (%d, %d, ''c'')',
          [100000000 + Int64(FSeed) * 10000000 + n, n mod 1000]));
        Inc(FOk);
      except
        on E: Exception do
        begin
          Inc(FErr);
          Note(E);
        end;
      end;
    end;
  except
    on E: Exception do
    begin
      Inc(FErr);
      Note(E);
    end;
  end;
  FreeAndNil(S);
  FreeAndNil(TB);
  B := nil;
end;

procedure PrintSummary(const ATag: string);
begin
  WriteLn('SONUC ', ATag,
    ' canli_hucre=', GCls[fcLiveCells],
    ' indekste_yok=', GCls[fcNotInIndex],
    ' bozuk=', GCls[fcBroken],
    ' mesgul=', GCls[fcBusy],
    ' diger=', GCls[fcOther]);
  if GSamples.Count > 0 then
  begin
    WriteLn('ORNEK mesajlar:');
    WriteLn(GSamples.Text);
  end;
  Flush(Output);
end;

var
  Be, BeB: TVdbBackendV3;
  Tb, TbB: TVTableDb;
  Sq, SqB: TVSql;
  i, nloop, iters: Integer;
  mode, rep: string;
  th1, th2: TWriterThread;
  ok: Boolean;
  t0: Int64;
  cnt, fresh, expected: Int64;
  fb, fi: Int64;
  fm: string;
  k: Integer;
  r: TSqlResult;
  insOk, delOk, delZero: Integer;
  delSet: array[1..BASE_ROWS] of Boolean;
  kd: Integer;
  missedN, lostN: Integer;
  ms, ls, ds: string;
  dupN: Integer;
  BeF: TVdbBackendV3;
  TbF: TVTableDb;
  SqF: TVSql;

  { SESSIZ VERI KAYBI kontrolu: yazma basarili sayilirsa satir sayisi tam
    olarak degismis olmalidir. Sayim TAZE (salt okunur, yeni oturum) yapilir;
    A oturumunun bayat gorunumu bu kontrol icin GECERSIZDIR.
    ABase = kalan taban satiri (id < 1000000), AIns = kalan eklenen satir. }
  function FreshCount(out ABase, AIns: Int64; out AMiss: string): Int64;
  begin
    ABase := -1;
    AIns := -1;
    BeF := TVdbBackendV3.CreateReadOnly(GDb);
    try
      TbF := TVTableDb.CreateBackend(BeF);
      try
        TbF.Open(GDir);
        SqF := TVSql.Create(TbF);
        try
          Result := StrToInt64Def(Trim(SqF.Exec('SELECT COUNT(*) FROM t').Rows[0][0]), -1);
          ABase := StrToInt64Def(Trim(SqF.Exec(
            'SELECT COUNT(*) FROM t WHERE id < 1000000').Rows[0][0]), -1);
          AIns := StrToInt64Def(Trim(SqF.Exec(
            'SELECT COUNT(*) FROM t WHERE id >= 1000000').Rows[0][0]), -1);
          { Silinmesi gereken taban kimliklerinden hangileri kaldi? }
          AMiss := '';
          r := SqF.Exec('SELECT id FROM t WHERE id >= 2 AND id <= ' +
            IntToStr(1 + (delOk mod BASE_ROWS)) + ' ORDER BY id');
          for k := 0 to High(r.Rows) do
          begin
            if AMiss <> '' then AMiss := AMiss + ',';
            AMiss := AMiss + Trim(r.Rows[k][0]);
          end;
        finally
          SqF.Free;
        end;
      finally
        TbF.Free;
      end;
    finally
      BeF := nil;
    end;
  end;

  { Tek bir taban kimligi TAZE oturumda var mi? Seri testte bir silmenin
    NE ZAMAN geri geldigini daraltmak icin (yalniz teshis). }
  function FreshExists(AId: Integer): Boolean;
  var
    BeE: TVdbBackendV3;
    TbE: TVTableDb;
    SqE: TVSql;
  begin
    Result := False;
    BeE := TVdbBackendV3.CreateReadOnly(GDb);
    try
      TbE := TVTableDb.CreateBackend(BeE);
      try
        TbE.Open(GDir);
        SqE := TVSql.Create(TbE);
        try
          Result := StrToInt64Def(Trim(SqE.Exec('SELECT COUNT(*) FROM t WHERE id = ' +
            IntToStr(AId)).Rows[0][0]), -1) > 0;
        finally
          SqE.Free;
        end;
      finally
        TbE.Free;
      end;
    finally
      BeE := nil;
    end;
  end;

  { Tam kume karsilastirmasi: basarili sayilan silmeler delSet'te.
    delSet'te olup satirda DURAN = SILINMEMIS (sessiz kayip/geri gelme).
    delSet'te olmayan ama satirda OLMAYAN = FAZLA KAYIP (silinmedigi
    halde yok olmus). Ikisi de olmamali. }
  function SetDiff(out AMissed, ALost: string; out AMissedN, ALostN: Integer;
    out ADup: string; out ADupN: Integer): Boolean;
  var
    BeD: TVdbBackendV3;
    TbD: TVTableDb;
    SqD: TVSql;
    present: array[1..BASE_ROWS] of Boolean;
    rr: TSqlResult;
    j, idv, dc: Integer;
  begin
    Result := False;
    AMissed := '';
    ALost := '';
    AMissedN := 0;
    ALostN := 0;
    ADup := '';
    ADupN := 0;
    for j := 1 to BASE_ROWS do
      present[j] := False;
    BeD := TVdbBackendV3.CreateReadOnly(GDb);
    try
      TbD := TVTableDb.CreateBackend(BeD);
      try
        TbD.Open(GDir);
        SqD := TVSql.Create(TbD);
        try
          rr := SqD.Exec('SELECT id FROM t WHERE id < 1000000 ORDER BY id');
          for j := 0 to High(rr.Rows) do
          begin
            idv := StrToIntDef(Trim(rr.Rows[j][0]), -1);
            if (idv >= 1) and (idv <= BASE_ROWS) then present[idv] := True;
          end;
          for j := 1 to BASE_ROWS do
          begin
            if delSet[j] and present[j] then
            begin
              Inc(AMissedN);
              if AMissed <> '' then AMissed := AMissed + ',';
              AMissed := AMissed + IntToStr(j);
              { Ayni kimlik HEAP'te birden fazla hucrede mi? }
              dc := StrToIntDef(Trim(SqD.Exec('SELECT COUNT(*) FROM t WHERE id = ' +
                IntToStr(j)).Rows[0][0]), -1);
              if dc > 1 then
              begin
                Inc(ADupN);
                if ADup <> '' then ADup := ADup + ',';
                ADup := ADup + IntToStr(j) + 'x' + IntToStr(dc);
              end;
            end
            else if (not delSet[j]) and (not present[j]) then
            begin
              Inc(ALostN);
              if ALost <> '' then ALost := ALost + ',';
              ALost := ALost + IntToStr(j);
            end;
          end;
          { Genel cift kayit taramasi (silinmemislerin disinda da olabilir). }
          rr := SqD.Exec('SELECT COUNT(*) FROM t WHERE id < 1000000');
          Result := True;
        finally
          SqD.Free;
        end;
      finally
        TbD.Free;
      end;
    finally
      BeD := nil;
    end;
  end;

begin
  insOk := 0;
  delOk := 0;
  delZero := 0;
  for kd := 1 to BASE_ROWS do
    delSet[kd] := False;
  GLock := TCriticalSection.Create;
  GSamples := TStringList.Create;
  for i := 0 to Ord(High(TFailClass)) do
    GCls[TFailClass(i)] := 0;

  mode := LowerCase(Trim(ParamStr(1)));
  if mode = '' then mode := 'seq';
  if ParamStr(2) <> '' then
    GDir := ParamStr(2)
  else
    GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp');
  WipeDir(GDir);
  ForceDirectories(GDir);
  GDb := GDir + 'veritabani.odb';

  iters := StrToIntDef(Trim(GetEnvironmentVariable('VDB_REPRO_ITERS')), 4000);
  WriteLn('BILGI mod=', mode, ' iter=', iters, ' dizin=', GDir);
  Flush(Output);

  Be := TVdbBackendV3.Create(GDb);
  Be.DurableOnFlush := False;
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(GDir);
  Sq := TVSql.Create(Tb);
  Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER, s TEXT)');
  for i := 1 to BASE_ROWS do
    Sq.Exec(Format('INSERT INTO t (id, v, s) VALUES (%d, %d, ''b'')', [i, i mod 100]));
  Be.Engine.Checkpoint(True);
  WriteLn('BILGI taban hazir: ', BASE_ROWS, ' satir');
  Flush(Output);

  if mode = 'thr' then
  begin
    th1 := TWriterThread.Create(GDb, 1);
    th2 := TWriterThread.Create(GDb, 2);
    th1.Start;
    th2.Start;
    t0 := GetTickCount64;
    nloop := 0;
    while (GetTickCount64 - t0) < Int64(iters) do
    begin
      Inc(nloop);
      try
        Sq.Exec(Format('DELETE FROM t WHERE id = %d', [1 + (nloop mod BASE_ROWS)]));
      except
        on E: Exception do Note(E);
      end;
      Sleep(1);
    end;
    GStop := True;
    th1.WaitFor;
    th2.WaitFor;
    WriteLn('BILGI thread1 ok=', th1.FOk, ' hata=', th1.FErr,
      ' thread2 ok=', th2.FOk, ' hata=', th2.FErr, ' ana_loop=', nloop);
    FreeAndNil(th1);
    FreeAndNil(th2);
    PrintSummary('thr');
  end
  else if mode = 'seq1' then
  begin
    { Kontrol grubu: tek oturum, tazelik yolu hic isletilmez. }
    nloop := 0;
    for i := 1 to iters do
    begin
      try
        Sq.Exec(Format('INSERT INTO t (id, v, s) VALUES (%d, 0, ''x'')',
          [200000000 + i]));
        Inc(insOk);
        if Sq.Exec(Format('DELETE FROM t WHERE id = %d',
          [1 + (i mod BASE_ROWS)])).Affected > 0 then
        begin
          Inc(delOk);
          delSet[1 + (i mod BASE_ROWS)] := True;
        end
        else
          Inc(delZero);
        Inc(nloop);
      except
        on E: Exception do Note(E);
      end;
    end;
    WriteLn('BILGI tek oturum tur=', nloop);
    PrintSummary('seq1');
  end
  else
  begin
    { Iki oturum, TEK is parcacigi, sirayla: once B yazar, sonra A siler. }
    BeB := nil;
    TbB := nil;
    SqB := nil;
    BeB := TVdbBackendV3.Create(GDb);
    BeB.DurableOnFlush := False;
    TbB := TVTableDb.CreateBackend(BeB);
    TbB.Open(GDir);
    SqB := TVSql.Create(TbB);

    nloop := 0;
    for i := 1 to iters do
    begin
      try
        SqB.Exec(Format('INSERT INTO t (id, v, s) VALUES (%d, 0, ''x'')',
          [300000000 + i]));
        Inc(insOk);
        Inc(nloop);
        if (i >= 1012) and (i <= 1016) then
          WriteLn('IZLE_B i=', i, ' taze_var=',
            BoolToStr(FreshExists(1014), 'EVET', 'hayir'));
      except
        on E: Exception do Note(E);
      end;
      try
        { Etkilenen satir 0 ise silme GERCEKLESMEMISTIR; bunu basarili
          saymak muhasebeyi bozar (eski kod yalniz istisnaya bakiyordu). }
        if Sq.Exec(Format('DELETE FROM t WHERE id = %d',
          [1 + (i mod BASE_ROWS)])).Affected > 0 then
        begin
          Inc(delOk);
          delSet[1 + (i mod BASE_ROWS)] := True;
        end
        else
          Inc(delZero);
      except
        on E: Exception do Note(E);
      end;
      if (i = 1013) or (i mod 100 = 0) or ((i >= 1012) and (i <= 1016)) then
        WriteLn('IZLE_A i=', i, ' taze_var=',
          BoolToStr(FreshExists(1014), 'EVET', 'hayir'));
    end;
    WriteLn('BILGI iki oturum tur=', nloop);
    PrintSummary('seq');

    FreeAndNil(SqB);
    FreeAndNil(TbB);
    BeB := nil;
  end;

  { --- kapanis dogrulamasi --- }
  try
    Be.Engine.Checkpoint(True);
  except
    on E: Exception do Note(E);
  end;
  cnt := -1;
  try
    cnt := StrToInt64Def(Trim(Sq.Exec('SELECT COUNT(*) FROM t').Rows[0][0]), -1);
  except
    on E: Exception do Note(E);
  end;
  FreeAndNil(Sq);
  FreeAndNil(Tb);
  Be := nil;

  ok := VerifyDb(GDb, rep);
  fresh := FreshCount(fb, fi, fm);
  expected := Int64(BASE_ROWS) + Int64(insOk) - Int64(delOk);
  WriteLn('SONUC verify=', BoolToStr(ok, 'temiz', 'SORUNLU'), ' satir=', cnt);
  WriteLn('SESSIZ_KAYIP kontrol: taze_satir=', fresh, ' beklenen=', expected,
    ' basarili_insert=', insOk, ' basarili_delete=', delOk,
    ' fark=', fresh - expected);
  WriteLn('DAGILIM taban_kalan=', fb, ' taban_beklenen=', BASE_ROWS - delOk,
    ' eklenen_kalan=', fi, ' eklenen_beklenen=', insOk,
    ' etkisiz_delete=', delZero);
  WriteLn('SILINMEYEN_KIMLIKLER=', fm);
  SetDiff(ms, ls, missedN, lostN, ds, dupN);
  WriteLn('KUME_FARKI silinmemis=', missedN, ' [', ms, ']');
  WriteLn('KUME_FARKI fazla_kayip=', lostN, ' [', ls, ']');
  WriteLn('CIFT_KAYIT n=', dupN, ' [', ds, ']');
  WriteLn('VERIFY_RAPOR=', rep);
  PrintSummary('TOPLAM');
  Flush(Output);

  GSamples.Free;
  GLock.Free;
  Halt(0);
end.
