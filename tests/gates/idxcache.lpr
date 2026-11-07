program idxcache;

{ VDB v3 - indeks onbellegi tutarlilik kapisi (P-140 / R2-B-4)

  Denetlenenler:
    A) PAYLASILAN TVTableDb uzerinde 4 SQL oturumu; her is parcacigi
       KENDI TVSql'ini acar. Ayni anda (baglanti basina ayri oturum)
       indeksli satirlarda INSERT / indeksli SELECT / DELETE donusu
       calistirilir. Her turda:
         INSERT -> indeksli COUNT=1 -> indeksli SELECT id -> DELETE ->
         indeksli COUNT=0
       Beklenen sayilar birebir tutmali. Bu dongu FIdxDirty ekle/sil
       yollarini ve tek girdilik son-anahtar onbellegini (FLastDirtyIdx /
       nesil sayaci) surekli degistirir.
    B) 2 yazici + 2 kararli-okuyucu is parcacigi es zamanli kosar.
       Yazicilar yalnizca kendi tekil anahtarlarini ekleyip siler;
       okuyucular HIC dokunulmayan taban anahtarlarini indeksten sayar.
       Kirli indeks takibi kaybolursa (bayat indeksle okuma) okuyucu
       sayilari sapar.
    C) Indeks onbellegi gecersiz kilma yollari: DROP INDEX / CREATE INDEX
       dongusu arasinda INSERT/DELETE ve indeksli SELECT; her seferinde
       dogru sayi. Tembel yeniden insa ve bekleyen islem temizligi
       (DropIdxPend / BuildOneIndex) sinanir.

  Deterministik ve kisa: 200 taban satir, 4 is parcacigi, 30 tur.
  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: idxcache <calisma_dizini>
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: cthreads programin EN BASINDA olmali. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, SyncObjs,
  VDbBackendApi, VDbBackendV3, VDbPageStore, VDbTable, VDbSql;

const
  IC_THREADS = 4;
  IC_ITERS   = 30;
  IC_BASE    = 200;
  IC_BUSY_MS = 15000;

var
  gDir: string;
  gPass, gFail: Int64;
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

type
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

procedure OpenSes(out S: TV3Ses; const DbFile: string; Create_: Boolean);
begin
  S.Be := nil;
  S.Tb := nil;
  S.Sq := nil;
  S.Be := TVdbBackendV3.Create(DirOf(DbFile), Create_, VDB_DEF_POOL,
    IC_BUSY_MS);
  S.Tb := TVTableDb.CreateBackend(S.Be);
  S.Sq := TVSql.Create(S.Tb);
  S.Tb.Open(gDir);
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
{ Is parcaciklari                                                    }
{ ------------------------------------------------------------------ }

type
  TIdxWorker = class(TThread)
  private
    FTb: TVTableDb;       // PAYLASILAN tablo katmani
    FTid: Integer;
    FIters: Integer;
    FMode: Integer;       // 0 = yazici/donus, 1 = kararli okuyucu
    FGo: TEvent;
    FErr: string;
    procedure Note(const S: string);
  protected
    procedure Execute; override;
  public
    constructor Create(ATb: TVTableDb; ATid, AIters, AMode: Integer;
      AGo: TEvent);
    property ErrText: string read FErr;
  end;

constructor TIdxWorker.Create(ATb: TVTableDb; ATid, AIters, AMode: Integer;
  AGo: TEvent);
begin
  inherited Create(True);
  FTb := ATb;
  FTid := ATid;
  FIters := AIters;
  FMode := AMode;
  FGo := AGo;
  FErr := '';
  FreeOnTerminate := False;
end;

procedure TIdxWorker.Note(const S: string);
begin
  if FErr = '' then FErr := S;
  InterlockedIncrement(gThreadErr);
end;

procedure TIdxWorker.Execute;
var
  Sq: TVSql;
  r: TSqlResult;
  i, id, v, k: Integer;
  bad: Boolean;
  msg, got: string;
begin
  Sq := nil;
  try
    try
      Sq := TVSql.Create(FTb);
      InterlockedIncrement(gStarted);
      if FGo.WaitFor(30000) <> wrSignaled then
      begin
        Note('baslama isareti gelmedi (zaman asimi)');
        Exit;
      end;

      if FMode = 1 then
      begin
        { Kararli okuyucu: taban anahtarlarina HIC dokunulmaz; indeksli
          sayim her zaman tam olmali. }
        for i := 1 to FIters do
        begin
          r := RunSqlQ(Sq, 'SELECT COUNT(*) FROM ic WHERE v BETWEEN 1 AND ' +
            IntToStr(IC_BASE), bad, msg);
          if bad then
          begin
            Note(IntToStr(i) + '. tur kararli COUNT: ' + msg);
            Exit;
          end;
          got := One(r);
          if got <> IntToStr(IC_BASE) then
          begin
            Note(IntToStr(i) + '. tur kararli COUNT=' + got +
              ' (beklenen ' + IntToStr(IC_BASE) + ')');
            Exit;
          end;
          k := 1 + ((Ftid + i) mod IC_BASE);
          r := RunSqlQ(Sq, 'SELECT COUNT(*) FROM ic WHERE v = ' + IntToStr(k),
            bad, msg);
          if bad then
          begin
            Note(IntToStr(i) + '. tur tek anahtar COUNT: ' + msg);
            Exit;
          end;
          got := One(r);
          if got <> '1' then
          begin
            Note(IntToStr(i) + '. tur v=' + IntToStr(k) + ' COUNT=' + got +
              ' (beklenen 1)');
            Exit;
          end;
        end;
        Exit;
      end;

      { Yazici/donus: kendi TEKIL anahtarinda ekle -> oku -> sil -> oku. }
      for i := 1 to FIters do
      begin
        id := 1000000 + FTid * 100000 + i;
        v := 600000 + FTid * 100000 + i;

        r := RunSqlQ(Sq,
          'INSERT INTO ic(id, v, ad) VALUES(' + IntToStr(id) + ', ' +
          IntToStr(v) + ', ''w' + IntToStr(FTid) + '_' + IntToStr(i) + ''')',
          bad, msg);
        if bad then
        begin
          Note(IntToStr(i) + '. tur INSERT: ' + msg);
          Exit;
        end;

        r := RunSqlQ(Sq, 'SELECT COUNT(*) FROM ic WHERE v = ' + IntToStr(v),
          bad, msg);
        if bad then
        begin
          Note(IntToStr(i) + '. tur INSERT sonrasi COUNT: ' + msg);
          Exit;
        end;
        got := One(r);
        if got <> '1' then
        begin
          Note(IntToStr(i) + '. tur INSERT sonrasi COUNT=' + got +
            ' (beklenen 1)');
          Exit;
        end;

        r := RunSqlQ(Sq, 'SELECT id FROM ic WHERE v = ' + IntToStr(v),
          bad, msg);
        if bad then
        begin
          Note(IntToStr(i) + '. tur indeksli SELECT: ' + msg);
          Exit;
        end;
        got := One(r);
        if got <> IntToStr(id) then
        begin
          Note(IntToStr(i) + '. tur indeksli SELECT id=' + got +
            ' (beklenen ' + IntToStr(id) + ')');
          Exit;
        end;

        r := RunSqlQ(Sq, 'DELETE FROM ic WHERE id = ' + IntToStr(id),
          bad, msg);
        if bad then
        begin
          Note(IntToStr(i) + '. tur DELETE: ' + msg);
          Exit;
        end;

        r := RunSqlQ(Sq, 'SELECT COUNT(*) FROM ic WHERE v = ' + IntToStr(v),
          bad, msg);
        if bad then
        begin
          Note(IntToStr(i) + '. tur DELETE sonrasi COUNT: ' + msg);
          Exit;
        end;
        got := One(r);
        if got <> '0' then
        begin
          Note(IntToStr(i) + '. tur DELETE sonrasi COUNT=' + got +
            ' (beklenen 0)');
          Exit;
        end;
      end;
    finally
      if Sq <> nil then FreeAndNil(Sq);
    end;
  except
    on E: Exception do
      Note('beklenmeyen istisna: ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ ------------------------------------------------------------------ }
{ Kosu yardimcisi                                                    }
{ ------------------------------------------------------------------ }

function KosParcaciklar(Tb: TVTableDb; AMode: array of Integer;
  AIter: Integer; const Etiket: string): Boolean;
var
  W: array of TIdxWorker;
  GoEv: TEvent;
  i, started: Integer;
  errs: string;
begin
  Result := False;
  GoEv := TEvent.Create(nil, True, False, '');
  SetLength(W, Length(AMode));
  gStarted := 0;
  gThreadErr := 0;
  for i := 0 to High(AMode) do
    W[i] := TIdxWorker.Create(Tb, i, AIter, AMode[i], GoEv);
  for i := 0 to High(W) do
    W[i].Start;
  GoEv.SetEvent;
  for i := 0 to High(W) do
    W[i].WaitFor;

  started := gStarted;
  errs := '';
  for i := 0 to High(W) do
  begin
    if W[i].ErrText <> '' then
      errs := errs + ' [p' + IntToStr(i) + ': ' + W[i].ErrText + ']';
    W[i].Free;
  end;
  GoEv.Free;

  if (errs = '') and (started = Length(AMode)) and (gThreadErr = 0) then
  begin
    Ok(Etiket + ': ' + IntToStr(Length(AMode)) + ' is parcacigi hatasiz');
    Result := True;
  end
  else
    Fail(Etiket + ': is parcacigi hatasi (baslayan=' + IntToStr(started) +
      ' hata=' + IntToStr(gThreadErr) + '): ' + errs);
end;

{ ------------------------------------------------------------------ }
{ A) Ayni tabloda 4 yazici: INSERT / indeksli SELECT / DELETE        }
{ ------------------------------------------------------------------ }

procedure TestConcurrentChurn;
var
  S: TV3Ses;
  modes: array[0..IC_THREADS - 1] of Integer;
  i: Integer;
begin
  WriteLn;
  WriteLn('A) Paylasilan TVTableDb, ', IC_THREADS,
    ' oturum: es zamanli INSERT/DELETE + indeksli SELECT');

  try
    OpenSes(S, 'ic.odb', True);
  except
    on E: Exception do
    begin
      Fail('A: veritabani acilamadi: ' + E.Message);
      Exit;
    end;
  end;
  try
    if not RunOkQ(S.Sq,
      'CREATE TABLE ic(id INTEGER PRIMARY KEY, v INTEGER, ad TEXT)',
      'A: CREATE TABLE') then Exit;
    if not RunOkQ(S.Sq, 'BEGIN', 'A: BEGIN') then Exit;
    for i := 1 to IC_BASE do
      if not RunOkQ(S.Sq,
        'INSERT INTO ic(id, v, ad) VALUES(' + IntToStr(i) + ', ' +
        IntToStr(i) + ', ''b' + IntToStr(i) + ''')',
        'A: taban INSERT ' + IntToStr(i)) then Exit;
    if not RunOkQ(S.Sq, 'COMMIT', 'A: COMMIT') then Exit;
    if not RunOkQ(S.Sq, 'CREATE INDEX ix_ic_v ON ic (v)',
      'A: CREATE INDEX') then Exit;
    Ok('A: taban ' + IntToStr(IC_BASE) + ' satir + indeks hazir');

    for i := 0 to High(modes) do
      modes[i] := 0;
    if KosParcaciklar(S.Tb, modes, IC_ITERS, 'A') then
      Ok('A: ' + IntToStr(IC_THREADS * IC_ITERS) +
        ' ekle/sil donusu tutarli');

    { Her yazici kendi satirini sildi: taban korunmali. }
    RunCountQ(S.Sq, 'SELECT COUNT(*) FROM ic',
      'A: nihai satir sayisi ' + IntToStr(IC_BASE), IntToStr(IC_BASE));
    RunCountQ(S.Sq, 'SELECT COUNT(*) FROM ic WHERE v BETWEEN 1 AND ' +
      IntToStr(IC_BASE), 'A: taban indeks araligi bozulmadi',
      IntToStr(IC_BASE));
  finally
    CloseSes(S);
  end;
end;

{ ------------------------------------------------------------------ }
{ B) 2 yazici + 2 kararli okuyucu es zamanli                         }
{ ------------------------------------------------------------------ }

procedure TestMixedReaders;
var
  S: TV3Ses;
  modes: array[0..IC_THREADS - 1] of Integer;
  i: Integer;
begin
  WriteLn;
  WriteLn('B) 2 yazici + 2 kararli okuyucu: kirli indeks takibi');

  try
    OpenSes(S, 'ic.odb', False);
  except
    on E: Exception do
    begin
      Fail('B: veritabani acilamadi: ' + E.Message);
      Exit;
    end;
  end;
  try
    for i := 0 to High(modes) do
      if i < 2 then modes[i] := 0 else modes[i] := 1;
    { Yazici kimlikleri 2..3 olur; taban anahtarlari (v<=200) korunur. }
    if not KosParcaciklar(S.Tb, modes, IC_ITERS, 'B') then Exit;
    Ok('B: es zamanli okuma/yazma sirasinda kararli indeks sayilari tam');

    RunCountQ(S.Sq, 'SELECT COUNT(*) FROM ic',
      'B: ekle/sil sonrasi yalniz taban satirlari', IntToStr(IC_BASE));
    RunCountQ(S.Sq, 'SELECT COUNT(*) FROM ic WHERE v BETWEEN 1 AND ' +
      IntToStr(IC_BASE), 'B: indeks araligi hala tam',
      IntToStr(IC_BASE));
  finally
    CloseSes(S);
  end;
end;

{ ------------------------------------------------------------------ }
{ C) DROP INDEX / CREATE INDEX arasinda kirli takip                 }
{ ------------------------------------------------------------------ }

procedure TestIndexDropCreate;
var
  S: TV3Ses;
  bad: Boolean;
  msg, got: string;
  r: TSqlResult;
  i, id, v: Integer;
begin
  WriteLn;
  WriteLn('C) DROP/CREATE INDEX arasinda INSERT/DELETE ve indeksli SELECT');

  try
    OpenSes(S, 'ic.odb', False);
  except
    on E: Exception do
    begin
      Fail('C: veritabani acilamadi: ' + E.Message);
      Exit;
    end;
  end;
  try
    for i := 1 to 3 do
    begin
      if not RunOkQ(S.Sq, 'DROP INDEX ix_ic_v',
        'C' + IntToStr(i) + ': DROP INDEX') then Exit;

      { Indeks yokken yaz: indeks anahtari uretilmez, kirli liste temiz
        kalmali. }
      id := 3000000 + i;
      v := 4000000 + i;
      if not RunOkQ(S.Sq,
        'INSERT INTO ic(id, v, ad) VALUES(' + IntToStr(id) + ', ' +
        IntToStr(v) + ', ''d' + IntToStr(i) + ''')',
        'C' + IntToStr(i) + ': indekssiz INSERT') then Exit;
      RunCountQ(S.Sq, 'SELECT COUNT(*) FROM ic WHERE v = ' + IntToStr(v),
        'C' + IntToStr(i) + ': indekssiz dogru satir', '1');

      if not RunOkQ(S.Sq, 'CREATE INDEX ix_ic_v ON ic (v)',
        'C' + IntToStr(i) + ': CREATE INDEX') then Exit;

      { Tembel insa: ilk indeksli okuma tam veriyi kurmali. Yeni satir da
        dahil olmali (insa veriden yapilir). }
      RunCountQ(S.Sq, 'SELECT COUNT(*) FROM ic WHERE v BETWEEN 1 AND ' +
        IntToStr(IC_BASE), 'C' + IntToStr(i) + ': yeniden insa sonrasi taban',
        IntToStr(IC_BASE));
      RunCountQ(S.Sq, 'SELECT COUNT(*) FROM ic WHERE v = ' + IntToStr(v),
        'C' + IntToStr(i) + ': yeniden insa yeni satiri gorur', '1');

      { CREATE sonrasi INSERT: kirli liste yolu + flush. }
      inc(id);
      inc(v);
      if not RunOkQ(S.Sq,
        'INSERT INTO ic(id, v, ad) VALUES(' + IntToStr(id) + ', ' +
        IntToStr(v) + ', ''e' + IntToStr(i) + ''')',
        'C' + IntToStr(i) + ': indeksli INSERT') then Exit;
      RunCountQ(S.Sq, 'SELECT COUNT(*) FROM ic WHERE v = ' + IntToStr(v),
        'C' + IntToStr(i) + ': flush sonrasi yeni satir', '1');

      if not RunOkQ(S.Sq, 'DELETE FROM ic WHERE id = ' + IntToStr(id),
        'C' + IntToStr(i) + ': indeksli DELETE') then Exit;
      RunCountQ(S.Sq, 'SELECT COUNT(*) FROM ic WHERE v = ' + IntToStr(v),
        'C' + IntToStr(i) + ': DELETE sonrasi kirli temizlendi', '0');

      { Onceki turun indekssiz satiri silinir (temizlik). }
      if not RunOkQ(S.Sq, 'DELETE FROM ic WHERE id = ' + IntToStr(id - 1),
        'C' + IntToStr(i) + ': eski satir temizligi') then Exit;
    end;

    { Son turda indekssiz eklenen satir kaldiysa temizle; nihai taban. }
    r := RunSqlQ(S.Sq, 'DELETE FROM ic WHERE id >= 3000000', bad, msg);
    if bad then
      Fail('C: nihai temizlik: ' + msg)
    else
      Ok('C: DROP/CREATE dongusu sonrasi yardimci satirlar temizlendi');

    RunCountQ(S.Sq, 'SELECT COUNT(*) FROM ic',
      'C: nihai satir sayisi ' + IntToStr(IC_BASE), IntToStr(IC_BASE));
  finally
    CloseSes(S);
  end;
end;

{ ------------------------------------------------------------------ }

var
  S: TV3Ses;
begin
  gPass := 0;
  gFail := 0;
  gStarted := 0;
  gThreadErr := 0;

  if ParamCount >= 1 then
    gDir := ParamStr(1)
  else
  begin
    WriteLn('kullanim: idxcache <calisma_dizini>');
    Halt(2);
  end;
  if not DirectoryExists(gDir) then
    ForceDirectories(gDir);

  WriteLn('VDB v3 idxcache - indeks onbellegi tutarlilik kapisi');
  WriteLn('dizin=', gDir);
  WriteLn('is parcacigi=', IC_THREADS, '  tur=', IC_ITERS,
    '  taban satir=', IC_BASE);
  WriteLn;

  TestConcurrentChurn;
  TestMixedReaders;
  TestIndexDropCreate;

  { Kapanis sonrasi yeniden acilis: kalicilik ve indeks tutarliligi. }
  WriteLn;
  try
    OpenSes(S, 'ic.odb', False);
    try
      RunCountQ(S.Sq, 'SELECT COUNT(*) FROM ic', 'K: yeniden acilis satir',
        IntToStr(IC_BASE));
      RunCountQ(S.Sq, 'SELECT COUNT(*) FROM ic WHERE v BETWEEN 1 AND ' +
        IntToStr(IC_BASE), 'K: yeniden acilis indeks araligi',
        IntToStr(IC_BASE));
    finally
      CloseSes(S);
    end;
  except
    on E: Exception do
      Fail('K: yeniden acilis: ' + E.Message);
  end;

  WriteLn;
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
  begin
    WriteLn('INDEKS ONBELLEGI TUTARLILIGI DOGRULANDI');
    WriteLn('TEMIZ');
    Halt(0);
  end;
  WriteLn('INDEKS ONBELLEGI TUTARSIZ');
  Halt(1);
end.
