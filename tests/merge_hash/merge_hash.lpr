program merge_hash;
{ F-44 KALICI REGRESYON KAPISI.
  MERGE ... ON esitlik kosulunda eslesme O(hedef x kaynak) idi: 8k x 8.4k
  satirda ~67 milyon RowMatches cagrisi. Yeni yol esitlik AND-zincirini
  kanonik anahtara cevirip hedefi siralar ve ikili arama ile yalniz esit
  anahtarli adaylara bakar; her aday yine TAM ON kosuluyla dogrulanir.
  Bu kapi hem hizi hem de semantigin BIREBIR korundugunu olcer:
  coklu eslesme hatasi, NULL anahtar, sayisal denklik, coklu kolon,
  DELETE ve esitlik-disi ON (eski yola dusme). }
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbTable,
  VDbTypes, VDbSql, VDbErr;

const
  BIG_N = 8000;      { hedef satir sayisi (eslesen) }
  BIG_EXTRA = 400;   { yalniz kaynakta olan satirlar -> INSERT }
  BOUND_MS = 10000;  { buyuk MERGE icin ust sinir }
  { Sprint P / F-48: UPDATE ... FROM esitlik birlestirmesi }
  UF_T = 4000;       { hedef satir sayisi }
  UF_S = 2500;       { kaynak satir sayisi }
  UF_BOUND_MS = 4000; { hash yolunun ust siniri (eski yol ~milyonlarca
                        RowMatches cagrisi yapiyordu) }

var
  GDir, GDb: string;
  GPass, GFail, GSeq: Integer;

procedure Chk(const AName: string; AOk: Boolean; const ADetail: string = '');
begin
  if AOk then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' ', ADetail);
  end;
end;

procedure Wipe(const D: string);
var
  sr: TSearchRec;
  d2: string;
begin
  d2 := IncludeTrailingPathDelimiter(D);
  ForceDirectories(d2);
  if FindFirst(d2 + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        SysUtils.DeleteFile(d2 + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function CellQ(Aq: TVSql; const ASql: string): string;
var
  r: TSqlResult;
begin
  Result := '<yok>';
  r := Aq.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := Trim(r.Rows[0][0]);
end;

function IntQ(Aq: TVSql; const ASql: string): Int64;
var
  s: string;
begin
  s := CellQ(Aq, ASql);
  if not TryStrToInt64(s, Result) then Result := -1;
end;

function TryExec(Aq: TVSql; const ASql: string; out AErr: string): Boolean;
begin
  AErr := '';
  try
    Aq.Exec(ASql);
    Result := True;
  except
    on E: Exception do
    begin
      AErr := E.ClassName + ': ' + E.Message;
      Result := False;
    end;
  end;
end;

var
  Be: TVdbBackendV3;
  Tb: TVTableDb;
  Sq: TVSql;

procedure OpenFresh(const AName: string);
begin
  Inc(GSeq);
  GDir := GetTempDir + 'vdb_merge_' + AName + '_' + IntToStr(GetProcessID) +
    '_' + IntToStr(GSeq);
  Wipe(GDir);
  GDb := IncludeTrailingPathDelimiter(GDir) + 'merge.odb';
  Be := TVdbBackendV3.Create(GDb);
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(GDir);
  Sq := TVSql.Create(Tb);
end;

procedure CloseAll;
begin
  FreeAndNil(Sq);
  FreeAndNil(Tb);
  Be := nil;
end;

{ Buyuk hacim: hiz olcumu + satir sayisi dogrulugu }
procedure CaseBig;
var
  i: Integer;
  t0, ms: QWord;
  cnt, upd, ins: Int64;
begin
  OpenFresh('big');
  Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE s (id INTEGER PRIMARY KEY, v TEXT)');

  Sq.Exec('BEGIN');
  for i := 1 to BIG_N do
    Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''x'')');
  Sq.Exec('COMMIT');

  Sq.Exec('BEGIN');
  for i := 1 to BIG_N do
    Sq.Exec('INSERT INTO s (id, v) VALUES (' + IntToStr(i) + ', ''y'')');
  for i := BIG_N + 1 to BIG_N + BIG_EXTRA do
    Sq.Exec('INSERT INTO s (id, v) VALUES (' + IntToStr(i) + ', ''n'')');
  Sq.Exec('COMMIT');

  Chk('M1 hedef satir sayisi', IntQ(Sq, 'SELECT COUNT(*) FROM t') = BIG_N,
    't=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  Chk('M1b kaynak satir sayisi',
    IntQ(Sq, 'SELECT COUNT(*) FROM s') = BIG_N + BIG_EXTRA,
    's=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM s')));

  t0 := GetTickCount64;
  Sq.Exec('MERGE INTO t USING s ON t.id = s.id ' +
    'WHEN MATCHED THEN UPDATE SET v = s.v ' +
    'WHEN NOT MATCHED THEN INSERT (id, v) VALUES (s.id, s.v)');
  ms := GetTickCount64 - t0;

  Chk('M2 buyuk MERGE sinirli surede bitti', ms <= BOUND_MS,
    'sure=' + IntToStr(ms) + 'ms sinir=' + IntToStr(BOUND_MS) + 'ms');

  cnt := IntQ(Sq, 'SELECT COUNT(*) FROM t');
  upd := IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE v = ''y''');
  ins := IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE v = ''n''');
  Chk('M3 toplam satir (guncellenen + eklenen)', cnt = BIG_N + BIG_EXTRA,
    't=' + IntToStr(cnt));
  Chk('M4 eslesen satirlar guncellendi', upd = BIG_N, 'y=' + IntToStr(upd));
  Chk('M5 eslesmeyen kaynak satirlari eklendi', ins = BIG_EXTRA,
    'n=' + IntToStr(ins));

  { Ayni MERGE tekrar: yeni INSERT olmamali (idempotent) }
  t0 := GetTickCount64;
  Sq.Exec('MERGE INTO t USING s ON t.id = s.id ' +
    'WHEN MATCHED THEN UPDATE SET v = s.v ' +
    'WHEN NOT MATCHED THEN INSERT (id, v) VALUES (s.id, s.v)');
  ms := GetTickCount64 - t0;
  Chk('M6 tekrar kosu satir eklemedi',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = BIG_N + BIG_EXTRA,
    't=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')) +
    ' sure=' + IntToStr(ms) + 'ms');
  CloseAll;
end;

{ Sayisal denklik: '05' ile 5 ayni anahtar sayilir (VDbCmpVal float yolu) }
procedure CaseNumeric;
begin
  OpenFresh('num');
  Sq.Exec('CREATE TABLE nt (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE ns (id INTEGER, v TEXT)');
  Sq.Exec('INSERT INTO nt (id, v) VALUES (5, ''a'')');
  Sq.Exec('INSERT INTO ns (id, v) VALUES (''05'', ''z'')');
  Sq.Exec('MERGE INTO nt USING ns ON nt.id = ns.id ' +
    'WHEN MATCHED THEN UPDATE SET v = ns.v');
  Chk('M7 sayisal denk anahtar eslesti',
    CellQ(Sq, 'SELECT v FROM nt WHERE id = 5') = 'z',
    'v=' + CellQ(Sq, 'SELECT v FROM nt WHERE id = 5'));
  Chk('M7b kopya satir olusmadi', IntQ(Sq, 'SELECT COUNT(*) FROM nt') = 1,
    'n=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM nt')));
  CloseAll;
end;

{ NULL anahtar SQL'de UNKNOWN: hicbir satirla eslesmez }
procedure CaseNullKey;
begin
  OpenFresh('nul');
  Sq.Exec('CREATE TABLE mt (id INTEGER, k TEXT, v TEXT)');
  Sq.Exec('CREATE TABLE ms (k TEXT)');
  Sq.Exec('INSERT INTO mt (id, k, v) VALUES (1, NULL, ''a'')');
  Sq.Exec('INSERT INTO ms (k) VALUES (NULL)');
  Sq.Exec('MERGE INTO mt USING ms ON mt.k = ms.k ' +
    'WHEN MATCHED THEN UPDATE SET v = ''z''');
  Chk('M8 NULL anahtar eslesmedi',
    CellQ(Sq, 'SELECT v FROM mt WHERE id = 1') = 'a',
    'v=' + CellQ(Sq, 'SELECT v FROM mt WHERE id = 1'));
  CloseAll;
end;

{ Coklu eslesme hatasi korunur }
procedure CaseDup;
var
  ok: Boolean;
  err: string;
begin
  OpenFresh('dup');
  Sq.Exec('CREATE TABLE dt (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE ds (id INTEGER, v TEXT)');
  Sq.Exec('INSERT INTO dt (id, v) VALUES (1, ''a'')');
  Sq.Exec('INSERT INTO ds (id, v) VALUES (1, ''b'')');
  Sq.Exec('INSERT INTO ds (id, v) VALUES (1, ''c'')');
  ok := TryExec(Sq,
    'MERGE INTO dt USING ds ON dt.id = ds.id ' +
    'WHEN MATCHED THEN UPDATE SET v = ds.v', err);
  Chk('M9 coklu kaynak eslesmesi hata verdi', (not ok) and
    (Pos('birden cok kaynak', err) > 0), err);
  Chk('M9b hata sonrasi hedef degismedi',
    CellQ(Sq, 'SELECT v FROM dt WHERE id = 1') = 'a',
    'v=' + CellQ(Sq, 'SELECT v FROM dt WHERE id = 1'));
  CloseAll;
end;

{ Esitlik-disi ON: eski yola duser, sonuc ayni olmali }
procedure CaseFallback;
begin
  OpenFresh('fal');
  Sq.Exec('CREATE TABLE ft (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE fs (id INTEGER, v TEXT)');
  Sq.Exec('INSERT INTO ft (id, v) VALUES (5, ''a'')');
  Sq.Exec('INSERT INTO ft (id, v) VALUES (15, ''a'')');
  Sq.Exec('INSERT INTO fs (id, v) VALUES (5, ''z'')');
  Sq.Exec('INSERT INTO fs (id, v) VALUES (15, ''z'')');
  Sq.Exec('MERGE INTO ft USING fs ON ft.id = fs.id AND fs.id > 10 ' +
    'WHEN MATCHED THEN UPDATE SET v = fs.v');
  Chk('M10 esitlik-disi ON: kosulu saglayan guncellendi',
    CellQ(Sq, 'SELECT v FROM ft WHERE id = 15') = 'z',
    'v=' + CellQ(Sq, 'SELECT v FROM ft WHERE id = 15'));
  Chk('M10b esitlik-disi ON: kosulu saglamayan korundu',
    CellQ(Sq, 'SELECT v FROM ft WHERE id = 5') = 'a',
    'v=' + CellQ(Sq, 'SELECT v FROM ft WHERE id = 5'));
  CloseAll;
end;

{ Coklu kolon esitlik anahtari }
procedure CaseMultiCol;
begin
  OpenFresh('mul');
  Sq.Exec('CREATE TABLE kt (id INTEGER, k TEXT, v TEXT)');
  Sq.Exec('CREATE TABLE ks (id INTEGER, k TEXT, v TEXT)');
  Sq.Exec('INSERT INTO kt (id, k, v) VALUES (1, ''a'', ''p'')');
  Sq.Exec('INSERT INTO kt (id, k, v) VALUES (2, ''b'', ''p'')');
  Sq.Exec('INSERT INTO ks (id, k, v) VALUES (1, ''a'', ''m'')');
  Sq.Exec('INSERT INTO ks (id, k, v) VALUES (2, ''x'', ''m'')');
  Sq.Exec('MERGE INTO kt USING ks ON kt.id = ks.id AND kt.k = ks.k ' +
    'WHEN MATCHED THEN UPDATE SET v = ks.v');
  Chk('M11 coklu kolon: tam eslesen guncellendi',
    CellQ(Sq, 'SELECT v FROM kt WHERE id = 1') = 'm',
    'v=' + CellQ(Sq, 'SELECT v FROM kt WHERE id = 1'));
  Chk('M11b coklu kolon: kismi eslesme guncellenmedi',
    CellQ(Sq, 'SELECT v FROM kt WHERE id = 2') = 'p',
    'v=' + CellQ(Sq, 'SELECT v FROM kt WHERE id = 2'));
  CloseAll;
end;

{ WHEN MATCHED THEN DELETE }
procedure CaseDelete;
begin
  OpenFresh('del');
  Sq.Exec('CREATE TABLE xt (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE xs (id INTEGER, v TEXT)');
  Sq.Exec('INSERT INTO xt (id, v) VALUES (1, ''a'')');
  Sq.Exec('INSERT INTO xt (id, v) VALUES (2, ''b'')');
  Sq.Exec('INSERT INTO xt (id, v) VALUES (3, ''c'')');
  Sq.Exec('INSERT INTO xt (id, v) VALUES (4, ''d'')');
  Sq.Exec('INSERT INTO xt (id, v) VALUES (5, ''e'')');
  Sq.Exec('INSERT INTO xs (id, v) VALUES (2, ''x'')');
  Sq.Exec('INSERT INTO xs (id, v) VALUES (4, ''x'')');
  Sq.Exec('MERGE INTO xt USING xs ON xt.id = xs.id ' +
    'WHEN MATCHED THEN DELETE');
  Chk('M12 DELETE: kalan satir sayisi',
    IntQ(Sq, 'SELECT COUNT(*) FROM xt') = 3,
    'n=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM xt')));
  Chk('M12b DELETE: eslesmeyenler korundu',
    (IntQ(Sq, 'SELECT COUNT(*) FROM xt WHERE id IN (1, 3, 5)') = 3),
    'kalan=' + CellQ(Sq,
      'SELECT COUNT(*) FROM xt WHERE id IN (1, 3, 5)'));
  CloseAll;
end;

{ Guncelleme + ekleme ayni ifadede, eslesmeyen kaynak yok }
procedure CaseUpdateOnly;
begin
  OpenFresh('upd');
  Sq.Exec('CREATE TABLE ut (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE us (id INTEGER, v TEXT)');
  Sq.Exec('INSERT INTO ut (id, v) VALUES (1, ''a'')');
  Sq.Exec('INSERT INTO ut (id, v) VALUES (2, ''a'')');
  Sq.Exec('INSERT INTO us (id, v) VALUES (1, ''b'')');
  Sq.Exec('MERGE INTO ut USING us ON ut.id = us.id ' +
    'WHEN MATCHED THEN UPDATE SET v = us.v');
  Chk('M13 yalniz eslesen guncellendi',
    (CellQ(Sq, 'SELECT v FROM ut WHERE id = 1') = 'b') and
    (CellQ(Sq, 'SELECT v FROM ut WHERE id = 2') = 'a'),
    'id1=' + CellQ(Sq, 'SELECT v FROM ut WHERE id = 1') +
    ' id2=' + CellQ(Sq, 'SELECT v FROM ut WHERE id = 2'));
  CloseAll;
end;

{ Sprint P / F-48: UPDATE ... FROM esitlik birlestirmesi. ONCEDEN hedef x
  kaynak kartezyen donguydu (O(N x M)); artik ust duzey AND icindeki
  kolon = kolon esitlikleri hash anahtari olur, her aday yine TAM WHERE
  ile dogrulanir. Bu bolum hem hizi (U3) hem semantigin korundugunu
  (U1/U2/U4-U10) olcer. }
procedure CaseUpdateFromPerf;
var
  i: Integer;
  t0, ms: QWord;
  n, na: Int64;
begin
  OpenFresh('ufperf');
  Sq.Exec('CREATE TABLE ut (id INTEGER PRIMARY KEY, k TEXT, v TEXT)');
  Sq.Exec('CREATE TABLE us (id INTEGER, k TEXT, v TEXT)');
  Sq.Exec('BEGIN');
  for i := 1 to UF_T do
    Sq.Exec('INSERT INTO ut (id, k, v) VALUES (' + IntToStr(i) +
      ', ''k' + IntToStr(i) + ''', ''a'')');
  for i := 1 to UF_S do
    Sq.Exec('INSERT INTO us (id, k, v) VALUES (' + IntToStr(i) +
      ', ''k' + IntToStr(i) + ''', ''u'')');
  Sq.Exec('COMMIT');

  t0 := GetTickCount64;
  Sq.Exec('UPDATE ut SET v = us.v FROM us WHERE ut.k = us.k');
  ms := GetTickCount64 - t0;

  n := IntQ(Sq, 'SELECT COUNT(*) FROM ut WHERE v = ''u''');
  na := IntQ(Sq, 'SELECT COUNT(*) FROM ut WHERE v = ''a''');
  Chk('U1 eslesen satirlar guncellendi', n = UF_S, 'n=' + IntToStr(n));
  Chk('U2 eslesmeyen hedef satirlari korundu', na = UF_T - UF_S,
    'n=' + IntToStr(na));
  Chk('U3 esitlik anahtarli birlestirme sinirli surede bitti',
    (n = UF_S) and (ms <= UF_BOUND_MS),
    'sure=' + IntToStr(ms) + 'ms sinir=' + IntToStr(UF_BOUND_MS) + 'ms');
  CloseAll;
end;

procedure CaseUpdateFromFirst;
begin
  OpenFresh('uffirst');
  Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE s (id INTEGER, v TEXT)');
  Sq.Exec('INSERT INTO t (id, v) VALUES (1, ''a'')');
  Sq.Exec('INSERT INTO s (id, v) VALUES (1, ''b'')');
  Sq.Exec('INSERT INTO s (id, v) VALUES (1, ''z'')');
  Sq.Exec('UPDATE t SET v = s.v FROM s WHERE t.id = s.id');
  Chk('U4 ilk eslesen kaynak satiri kazanir',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 1') = 'b',
    'v=' + CellQ(Sq, 'SELECT v FROM t WHERE id = 1'));
  Chk('U4b kopya hedef satiri olusmadi',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 1,
    'n=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  CloseAll;
end;

procedure CaseUpdateFromNull;
begin
  OpenFresh('ufnull');
  Sq.Exec('CREATE TABLE t (id INTEGER, k TEXT, v TEXT)');
  Sq.Exec('CREATE TABLE s (k TEXT, v TEXT)');
  Sq.Exec('INSERT INTO t (id, k, v) VALUES (1, NULL, ''a'')');
  Sq.Exec('INSERT INTO s (k, v) VALUES (NULL, ''z'')');
  Sq.Exec('UPDATE t SET v = s.v FROM s WHERE t.k = s.k');
  Chk('U5 NULL anahtar eslesmedi',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 1') = 'a',
    'v=' + CellQ(Sq, 'SELECT v FROM t WHERE id = 1'));
  CloseAll;
end;

procedure CaseUpdateFromNumeric;
begin
  OpenFresh('ufnum');
  Sq.Exec('CREATE TABLE nt (id INTEGER, v TEXT)');
  Sq.Exec('CREATE TABLE ns (id TEXT, v TEXT)');
  Sq.Exec('INSERT INTO nt (id, v) VALUES (5, ''a'')');
  Sq.Exec('INSERT INTO ns (id, v) VALUES (''05'', ''z'')');
  Sq.Exec('UPDATE nt SET v = ns.v FROM ns WHERE nt.id = ns.id');
  Chk('U6 sayisal denk anahtar eslesti (hash kullanilmaz)',
    CellQ(Sq, 'SELECT v FROM nt WHERE id = 5') = 'z',
    'v=' + CellQ(Sq, 'SELECT v FROM nt WHERE id = 5'));
  CloseAll;
end;

procedure CaseUpdateFromNonEq;
begin
  OpenFresh('ufneq');
  Sq.Exec('CREATE TABLE t (id INTEGER, v TEXT)');
  Sq.Exec('CREATE TABLE s (id INTEGER, v TEXT)');
  Sq.Exec('INSERT INTO t (id, v) VALUES (1, ''a'')');
  Sq.Exec('INSERT INTO t (id, v) VALUES (2, ''a'')');
  Sq.Exec('INSERT INTO s (id, v) VALUES (1, ''q'')');
  Sq.Exec('UPDATE t SET v = s.v FROM s WHERE t.id > s.id');
  Chk('U7 esitlik-disi WHERE eski yolda dogru sonuc verdi',
    (CellQ(Sq, 'SELECT v FROM t WHERE id = 2') = 'q') and
    (CellQ(Sq, 'SELECT v FROM t WHERE id = 1') = 'a'),
    'id1=' + CellQ(Sq, 'SELECT v FROM t WHERE id = 1') +
    ' id2=' + CellQ(Sq, 'SELECT v FROM t WHERE id = 2'));
  CloseAll;
end;

procedure CaseUpdateFromMulti;
begin
  OpenFresh('ufmulti');
  Sq.Exec('CREATE TABLE kt (id INTEGER, k TEXT, v TEXT)');
  Sq.Exec('CREATE TABLE ks (id INTEGER, k TEXT, v TEXT)');
  Sq.Exec('INSERT INTO kt (id, k, v) VALUES (1, ''a'', ''p'')');
  Sq.Exec('INSERT INTO kt (id, k, v) VALUES (2, ''b'', ''p'')');
  Sq.Exec('INSERT INTO ks (id, k, v) VALUES (1, ''a'', ''m'')');
  Sq.Exec('INSERT INTO ks (id, k, v) VALUES (2, ''x'', ''m'')');
  Sq.Exec('UPDATE kt SET v = ks.v FROM ks ' +
    'WHERE kt.id = ks.id AND kt.k = ks.k');
  Chk('U8 coklu kolon: tam eslesen guncellendi',
    CellQ(Sq, 'SELECT v FROM kt WHERE id = 1') = 'm',
    'v=' + CellQ(Sq, 'SELECT v FROM kt WHERE id = 1'));
  Chk('U8b coklu kolon: kismi eslesme guncellenmedi',
    CellQ(Sq, 'SELECT v FROM kt WHERE id = 2') = 'p',
    'v=' + CellQ(Sq, 'SELECT v FROM kt WHERE id = 2'));
  CloseAll;
end;

procedure CaseUpdateFromSubquery;
begin
  OpenFresh('ufsub');
  Sq.Exec('CREATE TABLE st (id INTEGER, v TEXT)');
  Sq.Exec('CREATE TABLE ss (id INTEGER, v TEXT)');
  Sq.Exec('INSERT INTO st (id, v) VALUES (1, ''a'')');
  Sq.Exec('INSERT INTO st (id, v) VALUES (2, ''a'')');
  Sq.Exec('INSERT INTO ss (id, v) VALUES (1, ''s'')');
  Sq.Exec('UPDATE st SET v = q.v FROM (SELECT id, v FROM ss) q ' +
    'WHERE st.id = q.id');
  Chk('U9 alt sorgu kaynagi birlestirildi',
    (CellQ(Sq, 'SELECT v FROM st WHERE id = 1') = 's') and
    (CellQ(Sq, 'SELECT v FROM st WHERE id = 2') = 'a'),
    'id1=' + CellQ(Sq, 'SELECT v FROM st WHERE id = 1') +
    ' id2=' + CellQ(Sq, 'SELECT v FROM st WHERE id = 2'));
  CloseAll;
end;

begin
  GPass := 0;
  GFail := 0;
  GSeq := 0;
  try
    CaseBig;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL M0 buyuk senaryo coktu ', E.ClassName, ': ', E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseNumeric;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL M7 sayisal senaryo coktu ', E.ClassName, ': ', E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseNullKey;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL M8 NULL senaryosu coktu ', E.ClassName, ': ', E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseDup;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL M9 coklu senaryo coktu ', E.ClassName, ': ', E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseFallback;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL M10 esitlik-disi senaryo coktu ', E.ClassName, ': ',
        E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseMultiCol;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL M11 coklu kolon senaryosu coktu ', E.ClassName, ': ',
        E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseDelete;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL M12 DELETE senaryosu coktu ', E.ClassName, ': ',
        E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseUpdateOnly;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL M13 senaryosu coktu ', E.ClassName, ': ', E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseUpdateFromPerf;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL U1 UPDATE FROM olcek senaryosu coktu ', E.ClassName,
        ': ', E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseUpdateFromFirst;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL U4 UPDATE FROM ilk-eslesen senaryosu coktu ', E.ClassName,
        ': ', E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseUpdateFromNull;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL U5 UPDATE FROM NULL senaryosu coktu ', E.ClassName,
        ': ', E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseUpdateFromNumeric;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL U6 UPDATE FROM sayisal senaryosu coktu ', E.ClassName,
        ': ', E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseUpdateFromNonEq;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL U7 UPDATE FROM esitlik-disi senaryosu coktu ', E.ClassName,
        ': ', E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseUpdateFromMulti;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL U8 UPDATE FROM coklu kolon senaryosu coktu ', E.ClassName,
        ': ', E.Message);
      try CloseAll; except end;
    end;
  end;
  try
    CaseUpdateFromSubquery;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL U9 UPDATE FROM alt sorgu senaryosu coktu ', E.ClassName,
        ': ', E.Message);
      try CloseAll; except end;
    end;
  end;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
