program concurchk;

{ VDB v3 - es zamanlilik kapisi

  Denetlenenler:
    A) Paylasimli tablo uzerinde COK IS PARCACIGI: TEK TVdbBackendV3 +
       TEK TVTableDb (ana parcacikta acilir), her is parcacigi yalnizca
       KENDI TVSql oturumunu acar (VDbSqlServer ile ayni paylasim modeli).
       Ayni anda indeksli SELECT (ilk okumada tembel bellek indeksi
       kurulur) ve INSERT. SELECT sayilari tutarli olmali, istisna/cokme
       olmamali, tum yazilan anahtarlar kapanistan sonra kalici olmali.
       Bu, paylasilan indeks onbellegi kilidini (B-02) gercekten sinar.
    B) Ic ice tarama (IN alt sorgusu) tekrar tekrar calistirilir; sonuc
       her seferinde AYNI olmali. (B-01: paylasilan tarama durumu /
       FSnapMap use-after-free regresyonu.)
    C) Iki oturumun islem durumu (paylasilan TVTableDb uzerinde):
       C1) B'nin ROLLBACK'i A'nin acik islemini ve commit edilen veriyi
           BOZMAMALI.
       C2) Sema karismasi: B sema degistirmeyi denerken/geri alirken
           A'nin satirlari korunmali.
       C3) R2-B-3: AYNI TVTableDb uzerinde iki SQL oturumu; B'nin
           ROLLBACK'i A'nin ERTELENEN (DEFERRABLE) FK satirlarini
           SESSIZCE TEMIZLEMEMELI. Ikinci oturumun rollback'i A'nin
           ertelenen listesini silerse, ihlalli COMMIT yanlislikla
           gecer; kapi bunu yakalar.

  Deterministik ve kisa: kucuk veri (2000 + 100 satir), sabit anahtarlar,
  N=4 is parcacigi, 25 tur; toplam birkac saniye.

  Paylasim: TEK motor + TEK tablo katmani; her is parcacigi KENDI SQL
  oturumunu (TVSql) acar. Ayni TVSql iki parcaciga VERILMEZ. Is
  parcaciklarinda istisna yakalanir ve hata metni toplanir.

  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: concurchk <calisma_dizini>
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: cthreads programin EN BASINDA olmali. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, SyncObjs,
  VDbBackendApi, VDbBackendV3, VDbPageStore, VDbTable, VDbSql;

const
  CONC_THREADS = 4;
  CONC_ITERS   = 25;
  CONC_BASE    = 2000;
  NEST_ITERS   = 150;
  { Yazma kilitleri islem kapsamli; kisa bir bekleme ile "mesgul"
    yarisini onleriz. Es zamanlilik yine de gercektir. }
  CONC_BUSY_MS = 15000;

var
  gDir: string;
  gPass, gFail: Int64;
  { Is parcaciklarindan InterlockedIncrement ile guncellenir. }
  gStarted: LongInt;
  gThreadErr: LongInt;

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

{ v3.23 guvenlik: depo kokunu supurme (bkz. backendchk CleanDir). }
procedure CleanDir;
var
  sr: TSearchRec;
  base: string;
begin
  if gDir = '' then Exit;
  if FileExists(IncludeTrailingPathDelimiter(gDir) + 'VDbCore.pas') then Exit;
  base := IncludeTrailingPathDelimiter(gDir);
  if FindFirst(base + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        if (sr.Attr and faDirectory) = 0 then
          DeleteFile(base + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

{ ------------------------------------------------------------------ }
{ Baglanti / oturum yardimcilari                                    }
{ ------------------------------------------------------------------ }

type
  { Bir baglanti: motor + tablo katmani + SQL oturumu. }
  TV3Ses = record
    Be: IVdbBackend;
    Tb: TVTableDb;
    Sq: TVSql;
  end;

procedure CloseSes(var S: TV3Ses);
begin
  if S.Sq <> nil then FreeAndNil(S.Sq);
  if S.Tb <> nil then
  begin
    try
      S.Tb.Close;
    except
      { kapanis hatasi test sonucunu golgelemesin }
    end;
    FreeAndNil(S.Tb);
  end;
  S.Be := nil;
end;

{ Baglanti acar; hata durumunda istisna yukari cikar. }
procedure OpenSes(out S: TV3Ses; const DbFile: string; Create_: Boolean);
begin
  S.Be := nil;
  S.Tb := nil;
  S.Sq := nil;
  S.Be := TVdbBackendV3.Create(DirOf(DbFile), Create_, VDB_DEF_POOL,
    CONC_BUSY_MS);
  S.Tb := TVTableDb.CreateBackend(S.Be);
  S.Sq := TVSql.Create(S.Tb);
  S.Tb.Open(gDir);
end;

{ Istisnayi yutar; IsErr ile bildirir. Is parcaciklarinda da guvenli
  (paylasilan global durum yok). }
function RunSql(const S: TV3Ses; const Sql: string;
  out IsErr: Boolean; out Msg: string): TSqlResult;
begin
  IsErr := False;
  Msg := '';
  Result := Default(TSqlResult);
  try
    Result := S.Sq.Exec(Sql);
  except
    on E: Exception do
    begin
      IsErr := True;
      Msg := E.ClassName + ': ' + E.Message;
      Result := Default(TSqlResult);
    end;
  end;
end;

{ Ayni isi ciplak bir TVSql oturumu icin yapar (paylasilan TVTableDb
  uzerindeki ikinci oturum). }
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

{ Guvenli hucre erisimi. }
function Cel(const R: TSqlResult; Row, Col: Integer): string;
begin
  if (Row < 0) or (Row > High(R.Rows)) or (Col < 0) or
     (Col > High(R.Rows[Row])) then
    Result := '<yok>'
  else
    Result := R.Rows[Row][Col];
end;

function One(const R: TSqlResult): string;
begin
  Result := Cel(R, 0, 0);
end;

{ Tek satir calistirir; hata/parcalanmis sonucu Ok/Fail'e yazar. }
function RunOk(const S: TV3Ses; const Sql, What: string): Boolean;
var
  r: TSqlResult;
  bad: Boolean;
  msg: string;
begin
  r := RunSql(S, Sql, bad, msg);
  Result := not bad;
  if bad then
    Fail(What + ': ' + msg);
end;

function RunCount(const S: TV3Ses; const Sql, What, Beklenen: string): Boolean;
var
  r: TSqlResult;
  bad: Boolean;
  msg, got: string;
begin
  r := RunSql(S, Sql, bad, msg);
  if bad then
  begin
    Fail(What + ': ' + msg);
    Exit(False);
  end;
  got := One(r);
  Result := got = Beklenen;
  if Result then
    Ok(What)
  else
    Fail(What + ': gelen=' + got + ' beklenen=' + Beklenen);
end;

{ Ciplak TVSql oturumu icin ayni Ok/Fail yardimcilari (paylasilan
  TVTableDb uzerindeki ikinci/ek oturumlar). }
function RunOkQ(const Sq: TVSql; const Sql, What: string): Boolean;
var
  r: TSqlResult;
  bad: Boolean;
  msg: string;
begin
  r := RunSqlQ(Sq, Sql, bad, msg);
  Result := not bad;
  if bad then
    Fail(What + ': ' + msg);
end;

function RunCountQ(const Sq: TVSql; const Sql, What, Beklenen: string): Boolean;
var
  r: TSqlResult;
  bad: Boolean;
  msg, got: string;
begin
  r := RunSqlQ(Sq, Sql, bad, msg);
  if bad then
  begin
    Fail(What + ': ' + msg);
    Exit(False);
  end;
  got := One(r);
  Result := got = Beklenen;
  if Result then
    Ok(What)
  else
    Fail(What + ': gelen=' + got + ' beklenen=' + Beklenen);
end;

{ ------------------------------------------------------------------ }
{ A) Paylasilan motor/tablo uzerinde es zamanli okuma + yazma        }
{ ------------------------------------------------------------------ }

type
  TConcWorker = class(TThread)
  private
    FTb: TVTableDb;       // PAYLASILAN tablo katmani (sahiplik ana parcacikta)
    FTid: Integer;
    FIters: Integer;
    FReady: TEvent;       // kendi SQL oturumu acildi
    FGo: TEvent;          // ana is parcacigi "basla" dedi
    FErr: string;
    procedure Note(const S: string);
  protected
    procedure Execute; override;
  public
    constructor Create(ATb: TVTableDb; ATid, AIters: Integer;
      AReady, AGo: TEvent);
    property ErrText: string read FErr;
  end;

constructor TConcWorker.Create(ATb: TVTableDb; ATid, AIters: Integer;
  AReady, AGo: TEvent);
begin
  inherited Create(True);  { askida baslar; Start ile kosar }
  FTb := ATb;
  FTid := ATid;
  FIters := AIters;
  FReady := AReady;
  FGo := AGo;
  FErr := '';
  FreeOnTerminate := False;
end;

procedure TConcWorker.Note(const S: string);
begin
  if FErr = '' then FErr := S;
  InterlockedIncrement(gThreadErr);
end;

procedure TConcWorker.Execute;
var
  Sq: TVSql;
  r: TSqlResult;
  i, k, id, vid: Integer;
  bad: Boolean;
  msg: string;
  readySet: Boolean;
begin
  Sq := nil;
  readySet := False;
  { Sabit indeksli arama anahtari: taban satirlari arasinda tekil. }
  k := 100 + FTid;
  try
    try
      try
        { PAYLASILAN TVTableDb; her is parcacigi yalnizca KENDI SQL
          oturumunu acar. Ayni TVSql iki parcaciga verilmez. }
        Sq := TVSql.Create(FTb);
      except
        on E: Exception do
        begin
          Note('SQL oturumu acilamadi: ' + E.ClassName + ': ' + E.Message);
          Exit;
        end;
      end;

      InterlockedIncrement(gStarted);
      FReady.SetEvent;
      readySet := True;

      if FGo.WaitFor(30000) <> wrSignaled then
      begin
        Note('baslama isareti gelmedi (zaman asimi)');
        Exit;
      end;

      for i := 1 to FIters do
      begin
        { 1) Indeksli COUNT: ilk okuma tembel bellek indeksini kurar. }
        r := RunSqlQ(Sq, 'SELECT COUNT(*) FROM ct WHERE v = ' + IntToStr(k),
          bad, msg);
        if bad then
        begin
          Note(IntToStr(i) + '. tur indeksli COUNT: ' + msg);
          Exit;
        end;
        if One(r) <> '1' then
        begin
          Note(IntToStr(i) + '. tur indeksli COUNT=' + One(r) +
            ' (beklenen 1)');
          Exit;
        end;

        { 2) Ayni indeks uzerinden satir kimligi. }
        r := RunSqlQ(Sq, 'SELECT id FROM ct WHERE v = ' + IntToStr(k),
          bad, msg);
        if bad then
        begin
          Note(IntToStr(i) + '. tur indeksli SELECT: ' + msg);
          Exit;
        end;
        if One(r) <> IntToStr(k) then
        begin
          Note(IntToStr(i) + '. tur indeksli SELECT id=' + One(r) +
            ' (beklenen ' + IntToStr(k) + ')');
          Exit;
        end;

        { 3) Parcaciga ozel TEKIL anahtar araligina yaz. }
        id := 1000000 + FTid * 100000 + i;
        vid := 500000 + FTid * 10000 + i;
        r := RunSqlQ(Sq,
          'INSERT INTO ct(id, v, ad) VALUES(' + IntToStr(id) + ', ' +
          IntToStr(vid) + ', ''w' + IntToStr(FTid) + '_' + IntToStr(i) + ''')',
          bad, msg);
        if bad then
        begin
          Note(IntToStr(i) + '. tur INSERT: ' + msg);
          Exit;
        end;
      end;
    finally
      { Yalniz KENDI oturumumuzu kapatiriz; paylasilan Tb ana parcacigin. }
      if Sq <> nil then FreeAndNil(Sq);
      if not readySet then FReady.SetEvent;
    end;
  except
    on E: Exception do
      Note('beklenmeyen istisna: ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure TestConcurrentRW;
var
  S: TV3Ses;
  Workers: array[0..CONC_THREADS - 1] of TConcWorker;
  Ready: array[0..CONC_THREADS - 1] of TEvent;
  GoEv: TEvent;
  i, t, lo, hi, id: Integer;
  r: TSqlResult;
  bad: Boolean;
  msg: string;
  allReady: Boolean;
  expected: Integer;
  errs: string;
begin
  WriteLn;
  WriteLn('A) Paylasilan motor/tablo: ', CONC_THREADS,
    ' SQL oturumu, es zamanli indeksli okuma + yazma');

  { PAYLASIM MODELI (VDbSqlServer gibi): TEK motor + TEK TVTableDb ana
    parcacikta acilir; is parcaciklari yalnizca kendi TVSql oturumlarini
    acar. Boylece paylasilan indeks onbellegi kilidi (B-02) gercekten
    sinanir. }
  try
    OpenSes(S, 'conc.odb', True);
  except
    on E: Exception do
    begin
      Fail('A: veritabani acilamadi: ' + E.Message);
      Exit;
    end;
  end;
  try
    r := RunSql(S, 'CREATE TABLE ct(id INTEGER PRIMARY KEY, v INTEGER, ad TEXT)',
      bad, msg);
    if bad then
    begin
      Fail('A: CREATE TABLE: ' + msg);
      Exit;
    end;

    { Taban verisi tek islemde yazilir (hizli, deterministik). }
    r := RunSql(S, 'BEGIN', bad, msg);
    if bad then
    begin
      Fail('A: BEGIN: ' + msg);
      Exit;
    end;
    for i := 1 to CONC_BASE do
    begin
      r := RunSql(S, 'INSERT INTO ct(id, v, ad) VALUES(' + IntToStr(i) +
        ', ' + IntToStr(i) + ', ''b' + IntToStr(i) + ''')', bad, msg);
      if bad then
      begin
        Fail('A: taban INSERT (' + IntToStr(i) + '): ' + msg);
        Exit;
      end;
    end;
    r := RunSql(S, 'COMMIT', bad, msg);
    if bad then
    begin
      Fail('A: taban COMMIT: ' + msg);
      Exit;
    end;

    { Kalici indeks. Her SQL oturumu ilk SELECT'te bellek indeksini
      TEMBEL kurar; es zamanli insa yolu da boylece denenir. }
    r := RunSql(S, 'CREATE INDEX ix_ct_v ON ct (v)', bad, msg);
    if bad then
    begin
      Fail('A: CREATE INDEX: ' + msg);
      Exit;
    end;
    Ok('A: taban ' + IntToStr(CONC_BASE) + ' satir + indeks hazir');

    { Is parcaciklari kurulur; hepsi AYNI Tb'yi kullanir, her birine
      KENDI hazir/basla olayi verilir. }
    GoEv := TEvent.Create(nil, True, False, '');
    for t := 0 to CONC_THREADS - 1 do
    begin
      Ready[t] := TEvent.Create(nil, True, False, '');
      Workers[t] := TConcWorker.Create(S.Tb, t, CONC_ITERS, Ready[t], GoEv);
    end;

    for t := 0 to CONC_THREADS - 1 do
      Workers[t].Start;

    { Tum SQL oturumlari acilana kadar bekle; sonra ayni anda birak. }
    allReady := True;
    for t := 0 to CONC_THREADS - 1 do
      if Ready[t].WaitFor(30000) <> wrSignaled then
      begin
        allReady := False;
        Fail('A: is parcacigi ' + IntToStr(t) + ' hazir olamadi (zaman asimi)');
      end;
    if allReady then
      Ok('A: ' + IntToStr(CONC_THREADS) + ' SQL oturumu hazir');
    GoEv.SetEvent;

    for t := 0 to CONC_THREADS - 1 do
      Workers[t].WaitFor;

    errs := '';
    for t := 0 to CONC_THREADS - 1 do
      if Workers[t].ErrText <> '' then
        errs := errs + ' [p' + IntToStr(t) + ': ' + Workers[t].ErrText + ']';

    if (errs = '') and (gStarted = CONC_THREADS) and (gThreadErr = 0) then
      Ok('A: ' + IntToStr(CONC_THREADS) + ' is parcacigi hatasiz okudu/yazdi')
    else
      Fail('A: is parcacigi hatasi (baslayan=' + IntToStr(gStarted) +
        ' hata=' + IntToStr(gThreadErr) + '): ' + errs);

    for t := 0 to CONC_THREADS - 1 do
    begin
      Workers[t].Free;
      Ready[t].Free;
    end;
    GoEv.Free;

    { Nihai dogrulama: ayni paylasilan oturum (tum thread'ler bitti). }
    expected := CONC_BASE + CONC_THREADS * CONC_ITERS;
    RunCount(S, 'SELECT COUNT(*) FROM ct', 'A: toplam satir ' +
      IntToStr(expected), IntToStr(expected));

    for t := 0 to CONC_THREADS - 1 do
    begin
      lo := 1000000 + t * 100000 + 1;
      hi := 1000000 + t * 100000 + CONC_ITERS;
      RunCount(S, 'SELECT COUNT(*) FROM ct WHERE id BETWEEN ' +
        IntToStr(lo) + ' AND ' + IntToStr(hi),
        'A: parcacik ' + IntToStr(t) + ' yazdigi ' + IntToStr(CONC_ITERS) +
        ' anahtar kalici', IntToStr(CONC_ITERS));
      RunCount(S, 'SELECT COUNT(*) FROM ct WHERE v = ' + IntToStr(100 + t),
        'A: parcacik ' + IntToStr(t) + ' taban satiri bozulmadi', '1');
    end;

    RunCount(S, 'SELECT COUNT(*) FROM ct WHERE id = 1000000', 'A: ilk anahtar',
      '0');
    id := 1000000 + (CONC_THREADS - 1) * 100000 + CONC_ITERS;
    RunCount(S, 'SELECT COUNT(*) FROM ct WHERE id = ' + IntToStr(id),
      'A: son anahtar', '1');
  finally
    CloseSes(S);
  end;
end;

{ ------------------------------------------------------------------ }
{ B) Ic ice tarama tekrari (B-01 regresyonu)                        }
{ ------------------------------------------------------------------ }

procedure TestNestedScan;
const
  NA = 500;
var
  S: TV3Ses;
  r: TSqlResult;
  i, xv, exp1, exp2, mism: Integer;
  bad: Boolean;
  msg, got1, got2, ilkHata: string;
  q1, q2: string;
begin
  WriteLn;
  WriteLn('B) Ic ice tarama: ayni alt sorgu ', NEST_ITERS,
    ' kez ayni sonucu vermeli');

  try
    OpenSes(S, 'nest.odb', True);
  except
    on E: Exception do
    begin
      Fail('B: veritabani acilamadi: ' + E.Message);
      Exit;
    end;
  end;
  try
    try
      r := RunSql(S,
        'CREATE TABLE na(id INTEGER PRIMARY KEY, x INTEGER)', bad, msg);
      if bad then
      begin
        Fail('B: CREATE na: ' + msg);
        Exit;
      end;
      r := RunSql(S,
        'CREATE TABLE nb(id INTEGER PRIMARY KEY, y INTEGER)', bad, msg);
      if bad then
      begin
        Fail('B: CREATE nb: ' + msg);
        Exit;
      end;

      r := RunSql(S, 'BEGIN', bad, msg);
      if bad then
      begin
        Fail('B: BEGIN: ' + msg);
        Exit;
      end;
      for i := 0 to NA - 1 do
      begin
        r := RunSql(S, 'INSERT INTO na(id, x) VALUES(' + IntToStr(i) +
          ', ' + IntToStr(i mod 20) + ')', bad, msg);
        if bad then
        begin
          Fail('B: INSERT na (' + IntToStr(i) + '): ' + msg);
          Exit;
        end;
      end;
      { nb.y = 0,2,4,6,8 (tek sayilar yok) }
      for i := 0 to 4 do
      begin
        r := RunSql(S, 'INSERT INTO nb(id, y) VALUES(' + IntToStr(i) +
          ', ' + IntToStr(i * 2) + ')', bad, msg);
        if bad then
        begin
          Fail('B: INSERT nb (' + IntToStr(i) + '): ' + msg);
          Exit;
        end;
      end;
      r := RunSql(S, 'COMMIT', bad, msg);
      if bad then
      begin
        Fail('B: COMMIT: ' + msg);
        Exit;
      end;

      { Beklenen degerler Pascal tarafinda BAGIMSIZ hesaplanir. }
      exp1 := 0;
      exp2 := 0;
      for i := 0 to NA - 1 do
      begin
        xv := i mod 20;
        if xv in [0, 2, 4, 6, 8] then Inc(exp1);
        if xv in [4, 6, 8] then Inc(exp2);
      end;

      q1 := 'SELECT COUNT(*) FROM na WHERE x IN (SELECT y FROM nb)';
      q2 := 'SELECT COUNT(*) FROM na WHERE x IN ' +
        '(SELECT y FROM nb WHERE y > 3)';

      mism := 0;
      ilkHata := '';
      for i := 1 to NEST_ITERS do
      begin
        r := RunSql(S, q1, bad, msg);
        if bad then
        begin
          Inc(mism);
          if ilkHata = '' then ilkHata := IntToStr(i) + '. tur: ' + msg;
        end
        else
        begin
          got1 := One(r);
          if got1 <> IntToStr(exp1) then
          begin
            Inc(mism);
            if ilkHata = '' then
              ilkHata := IntToStr(i) + '. tur: gelen=' + got1 +
                ' beklenen=' + IntToStr(exp1);
          end;
        end;

        r := RunSql(S, q2, bad, msg);
        if bad then
        begin
          Inc(mism);
          if ilkHata = '' then ilkHata := IntToStr(i) + '. tur (2): ' + msg;
        end
        else
        begin
          got2 := One(r);
          if got2 <> IntToStr(exp2) then
          begin
            Inc(mism);
            if ilkHata = '' then
              ilkHata := IntToStr(i) + '. tur (2): gelen=' + got2 +
                ' beklenen=' + IntToStr(exp2);
          end;
        end;
      end;

      if mism = 0 then
        Ok('B: ' + IntToStr(NEST_ITERS) + ' tekrar x2 sorgu BIREBIR ayni (' +
          IntToStr(exp1) + '/' + IntToStr(exp2) + ')')
      else
        Fail('B: ' + IntToStr(mism) + ' uyusmazlik; ilk: ' + ilkHata);
    finally
      CloseSes(S);
    end;
  except
    on E: Exception do
      Fail('B: beklenmeyen istisna: ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ ------------------------------------------------------------------ }
{ C1/C2) Paylasilan tablo uzerinde iki SQL oturumu                  }
{ ------------------------------------------------------------------ }

procedure TestTwoConnections;
var
  S, V: TV3Ses;
  SqB: TVSql;
  r: TSqlResult;
  bad: Boolean;
  msg: string;
  ddlKabul: Boolean;
begin
  WriteLn;
  WriteLn('C1/C2) Paylasilan Tb: iki SQL oturumu, BEGIN/ROLLBACK + sema');

  S.Be := nil; S.Tb := nil; S.Sq := nil;
  V.Be := nil; V.Tb := nil; V.Sq := nil;
  try
    OpenSes(S, 'txn.odb', True);
  except
    on E: Exception do
    begin
      Fail('C1: baglanti acilamadi: ' + E.Message);
      Exit;
    end;
  end;

  { IKINCI oturum AYNI TVTableDb uzerinde: paylasimli islem durumu.
    (A = S.Sq, B = SqB.) }
  SqB := TVSql.Create(S.Tb);
  try
    if not RunOk(S, 'CREATE TABLE pay(id INTEGER PRIMARY KEY, tut INTEGER)',
      'C1: CREATE pay') then Exit;

    { --- C1: A acik islemde; B yazar ve ROLLBACK eder. --- }
    if not RunOk(S, 'BEGIN', 'C1: A BEGIN') then Exit;
    if not RunOk(S, 'INSERT INTO pay(id, tut) VALUES(1, 100)',
      'C1: A INSERT (1,100)') then Exit;
    if not RunOkQ(SqB, 'BEGIN', 'C1: B BEGIN') then Exit;
    if not RunOkQ(SqB, 'INSERT INTO pay(id, tut) VALUES(2, 200)',
      'C1: B INSERT (2,200)') then Exit;

    { B yalniz kendi satirini gorur (commit edilmemis taban yok). }
    RunCountQ(SqB, 'SELECT COUNT(*) FROM pay',
      'C1: B yalniz kendi satirini gorur', '1');
    if not RunOkQ(SqB, 'ROLLBACK', 'C1: B ROLLBACK') then Exit;
    RunCountQ(SqB, 'SELECT COUNT(*) FROM pay WHERE id = 2',
      'C1: B kendi rollback satirini gormez', '0');

    { A'nin islemi B'nin rollback'inden ETKILENMEZ. }
    RunCount(S, 'SELECT COUNT(*) FROM pay',
      'C1: A B rollback sonrasi kendi satirini gorur', '1');
    if not RunOk(S, 'COMMIT', 'C1: A COMMIT') then Exit;

    RunCountQ(SqB, 'SELECT COUNT(*) FROM pay',
      'C1: A commit sonrasi B 1 satir gorur', '1');
    RunCountQ(SqB, 'SELECT COUNT(*) FROM pay WHERE id = 2',
      'C1: B rollback satiri yazilmadi', '0');

    { --- C2: A acikken B sema degistirir; A'nin verisi korunur. --- }
    if not RunOk(S, 'BEGIN', 'C2: A BEGIN') then Exit;
    if not RunOk(S, 'INSERT INTO pay(id, tut) VALUES(4, 400)',
      'C2: A INSERT (4,400)') then Exit;
    if not RunOkQ(SqB, 'BEGIN', 'C2: B BEGIN') then Exit;

    r := RunSqlQ(SqB, 'CREATE TABLE gecici(z INTEGER)', bad, msg);
    ddlKabul := not bad;
    if ddlKabul then
      Ok('C2: B DDL kabul edildi (A islemi bozulmadi)')
    else
      Ok('C2: B DDL coklu yazmada reddedildi (beklenen koruma): ' +
        Copy(msg, 1, 60));

    { ROLLBACK (DDL reddedilmis olsa da temizlik). Hata tolere edilir. }
    RunSqlQ(SqB, 'ROLLBACK', bad, msg);

    RunCount(S, 'SELECT COUNT(*) FROM pay',
      'C2: A sema karismasi sonrasi kendi islemini gorur', '2');
    if not RunOk(S, 'COMMIT', 'C2: A COMMIT') then Exit;
  finally
    FreeAndNil(SqB);
    CloseSes(S);
  end;

  { Nihai dogrulama (yeni baglanti): yalniz commit edilen satirlar. }
  try
    OpenSes(V, 'txn.odb', False);
  except
    on E: Exception do
    begin
      Fail('C1: dogrulama baglantisi acilamadi: ' + E.Message);
      Exit;
    end;
  end;
  try
    RunCount(V, 'SELECT COUNT(*) FROM pay', 'C: nihai 2 satir', '2');
    RunCount(V, 'SELECT COUNT(*) FROM pay WHERE id = 1', 'C: id=1 korundu',
      '1');
    RunCount(V, 'SELECT COUNT(*) FROM pay WHERE id = 2',
      'C: B rollback satiri yok', '0');
    RunCount(V, 'SELECT COUNT(*) FROM pay WHERE id = 4', 'C: id=4 korundu',
      '1');
  finally
    CloseSes(V);
  end;
end;

{ ------------------------------------------------------------------ }
{ C3) R2-B-3: paylasilan TVTableDb'de ertelenen FK izolasyonu       }
{ ------------------------------------------------------------------ }

procedure TestDeferredIsolation;
var
  S: TV3Ses;
  SqB: TVSql;
  r: TSqlResult;
  bad: Boolean;
  msg: string;
  chk: Boolean;
begin
  WriteLn;
  WriteLn('C3) R2-B-3: ertelenen FK listesi oturumlar arasi sizmamali');

  S.Be := nil; S.Tb := nil; S.Sq := nil;
  try
    OpenSes(S, 'defer.odb', True);
  except
    on E: Exception do
    begin
      Fail('C3: veritabani acilamadi: ' + E.Message);
      Exit;
    end;
  end;

  { Ikinci SQL oturumu AYNI TVTableDb uzerinde: R2-B-3'un tam sekli
    (paylasilan sema + ertelenen satir listesi). }
  SqB := TVSql.Create(S.Tb);
  try
    if not RunOk(S, 'CREATE TABLE de_ebe(id INTEGER PRIMARY KEY, ad TEXT)',
      'C3: CREATE de_ebe') then Exit;
    if not RunOk(S, 'CREATE TABLE de_coc(id INTEGER PRIMARY KEY, e_id INTEGER' +
      ' REFERENCES de_ebe(id) DEFERRABLE INITIALLY DEFERRED)',
      'C3: CREATE de_coc (DEFERRABLE)') then Exit;

    { --- Pozitif: cocuk once, ebe sonra; arada B rollback eder. --- }
    if not RunOk(S, 'BEGIN', 'C3: A BEGIN') then Exit;
    if not RunOk(S, 'SET CONSTRAINTS ALL DEFERRED',
      'C3: A SET CONSTRAINTS DEFERRED') then Exit;
    if not RunOk(S, 'INSERT INTO de_coc(id, e_id) VALUES(1, 77)',
      'C3: A cocuk (1,77) ertelendi') then Exit;

    { Ikinci oturum: kendi islemini acar, ertelenen satir EKLEMEZ,
      ROLLBACK eder. AbortBatch YALNIZ kendi girdilerini silmeli. }
    r := RunSqlQ(SqB, 'BEGIN', bad, msg);
    if bad then
    begin
      Fail('C3: B BEGIN: ' + msg);
      Exit;
    end;
    RunSqlQ(SqB, 'SET CONSTRAINTS ALL DEFERRED', bad, msg);
    r := RunSqlQ(SqB, 'ROLLBACK', bad, msg);
    if bad then
    begin
      Fail('C3: B ROLLBACK: ' + msg);
      Exit;
    end;

    if not RunOk(S, 'INSERT INTO de_ebe(id, ad) VALUES(77, ''p'')',
      'C3: A ebe (77) eklendi') then Exit;
    chk := RunOk(S, 'COMMIT', 'C3: A COMMIT (ertelenen FK gecerli)');
    if not chk then Exit;

    RunCount(S, 'SELECT COUNT(*) FROM de_coc',
      'C3: cocuk satiri yazildi', '1');
    RunCount(S, 'SELECT COUNT(*) FROM de_ebe',
      'C3: ebe satiri yazildi', '1');

    { --- Negatif: B'nin rollback'i A'nin ertelenen satirini SILMEMELI.
        Silinirse ihlalli COMMIT yanlislikla GECER; kapi bunu yakalar. --- }
    if not RunOk(S, 'BEGIN', 'C3: A BEGIN (negatif)') then Exit;
    if not RunOk(S, 'SET CONSTRAINTS ALL DEFERRED',
      'C3: A SET CONSTRAINTS DEFERRED (negatif)') then Exit;
    if not RunOk(S, 'INSERT INTO de_coc(id, e_id) VALUES(2, 88)',
      'C3: A cocuk (2,88) ertelendi (ebe YOK)') then Exit;

    r := RunSqlQ(SqB, 'BEGIN', bad, msg);
    if bad then
    begin
      Fail('C3: B BEGIN (negatif): ' + msg);
      Exit;
    end;
    RunSqlQ(SqB, 'SET CONSTRAINTS ALL DEFERRED', bad, msg);
    r := RunSqlQ(SqB, 'ROLLBACK', bad, msg);
    if bad then
    begin
      Fail('C3: B ROLLBACK (negatif): ' + msg);
      Exit;
    end;

    r := RunSql(S, 'COMMIT', bad, msg);
    if bad then
      Ok('C3: ihlalli COMMIT hala REDDEDILIYOR (B rollback ertelenen ' +
        'satiri silmedi)')
    else
      Fail('C3: R2-B-3 REGRESYONU: B rollback sonrasi ihlalli COMMIT GECTI ' +
        '(ertelenen satir listeden silinmis)');

    { Basarisiz COMMIT sonrasi temizlik; hata tolere edilir. }
    RunSql(S, 'ROLLBACK', bad, msg);

    RunCount(S, 'SELECT COUNT(*) FROM de_coc WHERE id = 2',
      'C3: ihlalli cocuk satiri yazilmadi', '0');
  finally
    FreeAndNil(SqB);
    CloseSes(S);
  end;
end;

{ ------------------------------------------------------------------ }

begin
  gPass := 0;
  gFail := 0;
  gStarted := 0;
  gThreadErr := 0;

  if ParamCount >= 1 then
    gDir := ParamStr(1)
  else
    gDir := IncludeTrailingPathDelimiter(GetCurrentDir) + 'tmp64\gaterun\concur';
  if not DirectoryExists(gDir) then
    ForceDirectories(gDir);

  CleanDir;

  WriteLn('VDB v3 concurchk - es zamanlilik kapisi');
  WriteLn('dizin=', gDir);
  WriteLn('is parcacigi=', CONC_THREADS, '  tur=', CONC_ITERS,
    '  taban satir=', CONC_BASE);
  WriteLn;

  TestConcurrentRW;
  TestNestedScan;
  TestTwoConnections;
  TestDeferredIsolation;

  WriteLn;
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
  begin
    WriteLn('ESZAMANLILIK DOGRULANDI');
    Halt(0);
  end;
  WriteLn('ESZAMANLILIK HATALI');
  Halt(1);
end.
