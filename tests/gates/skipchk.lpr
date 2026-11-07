program skipchk;

{ VDB v3 - indeks kaynagi omur kapisi (P-141 / R1)

  DENETLENEN SOZLESME:
    TryGetIdxSource bir TIdxSource dondurur. Cagiran bu kaynagi (ozellikle
    Src.Skip skiplist'ini) kilit BIRAKTIKTAN sonra yineleyebilir. Ayni
    esnada baska bir yol indeksi kaldirip yeniden kurabilir (DROP INDEX /
    CREATE INDEX) veya listeyi degistirebilir (INSERT/DELETE). Boyle bir
    durumda eski okuyucunun tuttugu kaynak SERBEST BIRAKILMAMALIDIR:
    referans sayimi serbest birakmayi son okuyucu bitene kadar erteler.

  SENARYO (her tur):
    1) YAZICI indeksi kurar ve ilk okumayla insa eder (tembel insa).
    2) OKUYUCU TryGetIdxSource ile kaynagi alir (kilit YOK), sayimlarini
       dogrular (taban satir = SK_BASE).
    3) OKUYUCU kaynagi yinelemeye baslar; YAZICI tam bu sirada
       DROP INDEX yapar (eski kodda listeyi serbest birakir) ve ardindan
       DELETE ile veriyi degistirir.
    4) OKUYUCU elindeki kaynagi yinelemeye devam eder. Kaynak yasamali;
       sayimlar hala SK_BASE olmali. Eski kodda serbest birakilmis
       bellek okunur (use-after-free): sayim sapar ya da surec coker.
    5) YAZICI satirlari geri yazar, sonraki tur icin indeksi yeniden kurar.

  SK_ROUNDS tur kosar; her tur DROP/CREATE INDEX + INSERT/DELETE zorlar.
  Basari dizesi: "INDEKS KAYNAK OMRU DOGRULANDI".
  Kullanim: skipchk <calisma_dizini>
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: cthreads programin EN BASINDA olmali. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, SyncObjs,
  VDbBackendApi, VDbBackendV3, VDbPageStore, VDbTable, VDbSql;

const
  SK_ROUNDS = 300;      // tur sayisi (en az birkac yuz)
  SK_BASE   = 800;      // taban satir / beklenen indeks sayisi
  SK_DROP   = 100;      // her turda silinen (sonra geri yazilan) satir
  SK_BUSY   = 60000;    // olay zaman asimi (ms)
  SK_ITERS  = 40;       // serbest birakma sonrasi dogrulama tekrari

var
  gDir: string;
  gPass, gFail: Int64;
  gFatal: LongInt;
  gTid: Word;
  gReaderErr: string;

procedure Ok(const S: string);
begin
  Inc(gPass);
  WriteLn('   OK   ', S);
end;

procedure Fail(const S: string);
begin
  Inc(gFail);
  WriteLn('   FAIL ', S);
end;

function DirOf(const N: string): string;
begin
  Result := IncludeTrailingPathDelimiter(gDir) + N;
end;

function RunSqlQ(const Sq: TVSql; const Sql: string;
  out IsErr: Boolean; out Msg: string): TSqlResult;
begin
  IsErr := False;
  Msg := '';
  Result := Default(TSqlResult);
  try
    Result := Sq.Exec(Sql);
  except
    on E: Exception do
    begin
      IsErr := True;
      Msg := E.ClassName + ': ' + E.Message;
      Result := Default(TSqlResult);
    end;
  end;
end;

{ ------------------------------------------------------------------ }
{ YAZICI: indeks kur / insa et / DROP / veri degistir / geri yaz     }
{ ------------------------------------------------------------------ }

type
  TWriteThread = class(TThread)
  private
    FTb: TVTableDb;
    FEvFetch, FEvGot, FEvIter, FEvDropped, FEvDone: TEvent;
    FErr: string;
    procedure Note(const S: string);
    function DoSql(const Sq: TVSql; const Sql, What: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(ATb: TVTableDb; AFetch, AGot, AIter, ADropped,
      ADone: TEvent);
    property ErrText: string read FErr;
  end;

constructor TWriteThread.Create(ATb: TVTableDb; AFetch, AGot, AIter,
  ADropped, ADone: TEvent);
begin
  inherited Create(True);
  FTb := ATb;
  FEvFetch := AFetch;
  FEvGot := AGot;
  FEvIter := AIter;
  FEvDropped := ADropped;
  FEvDone := ADone;
  FErr := '';
  FreeOnTerminate := False;
end;

procedure TWriteThread.Note(const S: string);
begin
  if FErr = '' then FErr := S;
end;

function TWriteThread.DoSql(const Sq: TVSql; const Sql, What: string): Boolean;
var
  r: TSqlResult;
  bad: Boolean;
  msg: string;
begin
  r := RunSqlQ(Sq, Sql, bad, msg);
  Result := not bad;
  if bad then
    Note(What + ': ' + msg);
end;

procedure TWriteThread.Execute;
var
  Sq: TVSql;
  r, id: Integer;
begin
  Sq := nil;
  try
    try
      Sq := TVSql.Create(FTb);
      for r := 1 to SK_ROUNDS do
      begin
        { Onceki turun sildigi satirlari geri yaz (indeks YOKKEN). }
        if r > 1 then
        begin
          if not DoSql(Sq, 'BEGIN', 'geri yaz BEGIN') then Exit;
          for id := SK_BASE - SK_DROP + 1 to SK_BASE do
            if not DoSql(Sq,
              'INSERT INTO sk(id, v) VALUES(' + IntToStr(id) + ', ' +
              IntToStr(id) + ')', 'geri yaz INSERT ' + IntToStr(id)) then Exit;
          if not DoSql(Sq, 'COMMIT', 'geri yaz COMMIT') then Exit;
        end;

        { Indeksi kur ve TEMBEL insayi ilk okumayla zorla. }
        if not DoSql(Sq, 'CREATE INDEX ix_sk_v ON sk (v)',
          'CREATE INDEX') then Exit;
        if not DoSql(Sq, 'SELECT COUNT(*) FROM sk WHERE v = 1',
          'insa tetikleme') then Exit;

        { Okuyucu kaynagi alsin. }
        FEvFetch.SetEvent;
        if FEvGot.WaitFor(SK_BUSY) <> wrSignaled then
        begin
          Note('okuyucu kaynak almadi (zaman asimi)');
          Exit;
        end;

        { Okuyucu yinelemeye basladi: tam bu sirada listeyi kaldir. }
        if FEvIter.WaitFor(SK_BUSY) <> wrSignaled then
        begin
          Note('okuyucu yinelemeye baslamadi (zaman asimi)');
          Exit;
        end;
        if gFatal <> 0 then Exit;
        Sleep(1);
        if not DoSql(Sq, 'DROP INDEX ix_sk_v', 'DROP INDEX') then Exit;
        { Veriyi degistir: yeni insa FARKLI sayi verir. Eski kodda
          okuyucunun isaretcisi serbest birakilmis bellege bakar. }
        if not DoSql(Sq,
          'DELETE FROM sk WHERE id > ' + IntToStr(SK_BASE - SK_DROP),
          'DELETE') then Exit;
        FEvDropped.SetEvent;

        if FEvDone.WaitFor(SK_BUSY) <> wrSignaled then
        begin
          Note('okuyucu bitmedi (zaman asimi)');
          Exit;
        end;
        if gFatal <> 0 then Exit;
        { Olaylar OTOMATIK sifirlanir (her tur tek tuketim); elle
          ResetEvent gerekmez ve yaris (bayat sinyal) olusmaz. }
      end;

      { Son turun sildigi satirlari geri yaz (indeks yokken). }
      DoSql(Sq, 'BEGIN', 'nihai geri yaz BEGIN');
      for id := SK_BASE - SK_DROP + 1 to SK_BASE do
        DoSql(Sq,
          'INSERT INTO sk(id, v) VALUES(' + IntToStr(id) + ', ' +
          IntToStr(id) + ')', 'nihai geri yaz INSERT ' + IntToStr(id));
      DoSql(Sq, 'COMMIT', 'nihai geri yaz COMMIT');
    finally
      if Sq <> nil then FreeAndNil(Sq);
    end;
  except
    on E: Exception do
      Note('beklenmeyen istisna: ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ ------------------------------------------------------------------ }
{ OKUYUCU: kaynagi al, yinele; DROP sonrasi da yinele               }
{ ------------------------------------------------------------------ }

type
  TReadThread = class(TThread)
  private
    FTb: TVTableDb;
    FEvFetch, FEvGot, FEvIter, FEvDropped, FEvDone: TEvent;
    procedure CheckSrc(const S: TIdxSource; const Where: string);
    procedure Drain;
  protected
    procedure Execute; override;
  public
    constructor Create(ATb: TVTableDb; AFetch, AGot, AIter, ADropped,
      ADone: TEvent);
  end;

constructor TReadThread.Create(ATb: TVTableDb; AFetch, AGot, AIter,
  ADropped, ADone: TEvent);
begin
  inherited Create(True);
  FTb := ATb;
  FEvFetch := AFetch;
  FEvGot := AGot;
  FEvIter := AIter;
  FEvDropped := ADropped;
  FEvDone := ADone;
  FreeOnTerminate := False;
end;

procedure TReadThread.CheckSrc(const S: TIdxSource; const Where: string);
var
  n: Int64;
  n2: Int64;
  e: TIdxEntries;
begin
  if gFatal <> 0 then Exit;
  n := IdxSourceCountAll(S);
  if n <> SK_BASE then
  begin
    InterlockedIncrement(gFatal);
    if gReaderErr = '' then
      gReaderErr := Where + ': kaynak sayisi=' + IntToStr(n) +
        ' beklenen=' + IntToStr(SK_BASE);
    Exit;
  end;
  n2 := IdxSourceCountBounds(S, '1', IntToStr(SK_BASE), True, True, True, True);
  if n2 <> SK_BASE then
  begin
    InterlockedIncrement(gFatal);
    if gReaderErr = '' then
      gReaderErr := Where + ': aralik sayisi=' + IntToStr(n2) +
        ' beklenen=' + IntToStr(SK_BASE);
    Exit;
  end;
  if IdxSourceRangeBounds(S, '1', IntToStr(SK_BASE), True, True, True, True,
    e) <> SK_BASE then
  begin
    InterlockedIncrement(gFatal);
    if gReaderErr = '' then
      gReaderErr := Where + ': aralik girdisi eksik';
  end;
end;

procedure TReadThread.Drain;
begin
  { Okuyucu erken dustugunde yaziciyi kilitlememek icin turu kapat. }
  FEvGot.SetEvent;
  FEvIter.SetEvent;
  FEvDropped.WaitFor(SK_BUSY);
  FEvDone.SetEvent;
end;

procedure TReadThread.Execute;
var
  r, i: Integer;
  src: TIdxSource;
  halt: Boolean;
begin
  try
    try
      for r := 1 to SK_ROUNDS do
      begin
        if FEvFetch.WaitFor(SK_BUSY) <> wrSignaled then
        begin
          if gReaderErr = '' then gReaderErr := 'fetch olayi gelmedi';
          InterlockedIncrement(gFatal);
          Exit;
        end;
        if gFatal <> 0 then Exit;

        src.Skip := nil;
        SetLength(src.Arr, 0);
        if not FTb.TryGetIdxSource(gTid, 1, src) then
        begin
          if gReaderErr = '' then
            gReaderErr := IntToStr(r) + '. tur TryGetIdxSource basarisiz';
          InterlockedIncrement(gFatal);
          Drain;
          Exit;
        end;

        { Kaynak alindi; yaziciyi serbest birak. }
        CheckSrc(src, IntToStr(r) + '. tur (drop oncesi)');
        FEvGot.SetEvent;

        { Yineleme basladi isareti; yazici DROP'u simdi yapar. }
        FEvIter.SetEvent;
        halt := False;
        while not halt do
        begin
          CheckSrc(src, IntToStr(r) + '. tur (drop sirasi)');
          halt := (gFatal <> 0) or (FEvDropped.WaitFor(0) = wrSignaled);
        end;

        { Serbest birakma sonrasi: eski kodda burada cop okunur. }
        for i := 1 to SK_ITERS do
          CheckSrc(src, IntToStr(r) + '. tur (drop sonrasi #' +
            IntToStr(i) + ')');

        src.Skip := nil;
        SetLength(src.Arr, 0);
        FEvDone.SetEvent;
        if gFatal <> 0 then Exit;
      end;
    except
      on E: Exception do
      begin
        if gReaderErr = '' then
          gReaderErr := 'istisna: ' + E.ClassName + ': ' + E.Message;
        InterlockedIncrement(gFatal);
        Drain;
      end;
    end;
  finally
    { src kaydinin yonetilen alanlari kapsam sonunda birakilir. }
  end;
end;

{ ------------------------------------------------------------------ }

var
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  EvFetch, EvGot, EvIter, EvDropped, EvDone: TEvent;
  W: TWriteThread;
  Rd: TReadThread;
  i: Integer;
  bad: Boolean;
  msg: string;
  r: TSqlResult;
begin
  gPass := 0;
  gFail := 0;
  gFatal := 0;
  gReaderErr := '';

  if ParamCount >= 1 then
    gDir := ParamStr(1)
  else
  begin
    WriteLn('kullanim: skipchk <calisma_dizini>');
    Halt(2);
  end;
  if not DirectoryExists(gDir) then
    ForceDirectories(gDir);

  WriteLn('VDB v3 skipchk - indeks kaynagi omur kapisi');
  WriteLn('dizin=', gDir);
  WriteLn('tur=', SK_ROUNDS, '  taban satir=', SK_BASE,
    '  tur basina silinen=', SK_DROP);
  WriteLn;

  Be := TVdbBackendV3.Create(DirOf('sk.odb'), True, VDB_DEF_POOL, 15000);
  Tb := TVTableDb.CreateBackend(Be);
  Sq := TVSql.Create(Tb);
  Tb.Open(gDir);

  r := RunSqlQ(Sq, 'CREATE TABLE sk(id INTEGER PRIMARY KEY, v INTEGER)',
    bad, msg);
  if bad then
  begin
    Fail('CREATE TABLE: ' + msg);
    Halt(1);
  end;
  r := RunSqlQ(Sq, 'BEGIN', bad, msg);
  if not bad then
    for i := 1 to SK_BASE do
    begin
      r := RunSqlQ(Sq,
        'INSERT INTO sk(id, v) VALUES(' + IntToStr(i) + ', ' +
        IntToStr(i) + ')', bad, msg);
      if bad then Break;
    end;
  if not bad then
    r := RunSqlQ(Sq, 'COMMIT', bad, msg);
  if bad then
  begin
    Fail('taban satirlar: ' + msg);
    Halt(1);
  end;

  gTid := Tb.GetTable('sk').TableId;
  Ok('taban ' + IntToStr(SK_BASE) + ' satir hazir (tableId=' +
    IntToStr(gTid) + ')');

  EvFetch := TEvent.Create(nil, False, False, '');
  EvGot := TEvent.Create(nil, False, False, '');
  EvIter := TEvent.Create(nil, False, False, '');
  EvDropped := TEvent.Create(nil, False, False, '');
  EvDone := TEvent.Create(nil, False, False, '');

  W := TWriteThread.Create(Tb, EvFetch, EvGot, EvIter, EvDropped, EvDone);
  Rd := TReadThread.Create(Tb, EvFetch, EvGot, EvIter, EvDropped, EvDone);
  W.Start;
  Rd.Start;
  Rd.WaitFor;
  W.WaitFor;

  if (gFatal = 0) and (gReaderErr = '') then
    Ok('okuyucu ' + IntToStr(SK_ROUNDS) +
      ' tur boyunca kaynagi guvenle yineledi')
  else
  begin
    if gReaderErr <> '' then
      Fail('okuyucu: ' + gReaderErr)
    else if gFatal <> 0 then
      Fail('okuyucu: kaynak omru ihlali (ayrinti yok)');
    if W.ErrText <> '' then
      Fail('yazici: ' + W.ErrText);
  end;

  Rd.Free;
  W.Free;
  EvFetch.Free;
  EvGot.Free;
  EvIter.Free;
  EvDropped.Free;
  EvDone.Free;

  { Nihai tutarlilik: veri geri yazildi mi, indeks dogru mu? }
  WriteLn;
  r := RunSqlQ(Sq, 'SELECT COUNT(*) FROM sk', bad, msg);
  if bad then
    Fail('nihai satir sayimi: ' + msg)
  else if r.Rows[0][0] = IntToStr(SK_BASE) then
    Ok('nihai satir sayisi=' + IntToStr(SK_BASE))
  else
    Fail('nihai satir sayisi=' + r.Rows[0][0] +
      ' beklenen=' + IntToStr(SK_BASE));

  r := RunSqlQ(Sq, 'CREATE INDEX ix_sk_v ON sk (v)', bad, msg);
  if bad then
    Fail('nihai CREATE INDEX: ' + msg)
  else
  begin
    r := RunSqlQ(Sq, 'SELECT COUNT(*) FROM sk WHERE v BETWEEN 1 AND ' +
      IntToStr(SK_BASE), bad, msg);
    if bad then
      Fail('nihai indeksli sayim: ' + msg)
    else if r.Rows[0][0] = IntToStr(SK_BASE) then
      Ok('nihai indeksli sayim=' + IntToStr(SK_BASE))
    else
      Fail('nihai indeksli sayim=' + r.Rows[0][0]);
  end;

  Sq.Free;
  Tb.Close;
  Tb.Free;
  Be := nil;

  WriteLn;
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if (gFail = 0) and (gFatal = 0) then
  begin
    WriteLn('INDEKS KAYNAK OMRU DOGRULANDI');
    WriteLn('TEMIZ');
    Halt(0);
  end;
  WriteLn('INDEKS KAYNAK OMRU IHLALI');
  Halt(1);
end.
