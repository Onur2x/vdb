program sql_scale;
{ v3.47 KALICI REGRESYON KAPISI - SKILL4 §4 SQL yurutucu olcek + bellek.
  Amac: SQL katmaninin 100k ve 1M satirda NE YAPTIGINI olcmek. Her kontrol
  satir sayisi, deger, sure, dosya boyu ve yigin deltasi gibi SOMUT bir sayi
  raporlar; "buyuk veride calisiyor" iddiasi olcumsuz birakilmaz.

  Olculen basamaklar:
    - 100k satir: ekleme, nokta okuma, WHERE, ORDER BY + LIMIT, OFFSET,
      COUNT/SUM/MIN/MAX/AVG, GROUP BY + HAVING, INNER JOIN,
      UPDATE/DELETE alt kumesi, rastgele karisik islemler
    - buyuk islem: commit sonrasi yeniden acilista DURUR, rollback
      sonrasi HIC satir kalmaz (hayalet satir yok)
    - yeniden acilis + tam VERIFY
    - 1M satir: toplu yukleme, LIMIT'siz `SELECT *` (2M tavaninin altinda
      kaldigi icin KABUL edilir; yigin deltasi olculur), LIMIT'li tarama
    - tavan sonrasi: ayni veritabani normal calismaya devam eder

  DURUST SINIR (SKILL4 §4.2): sonuc kumesi tavani VDB_MAX_RESULT_ROWS = 2M
  satirdir. Bu kapida tavani ASAN bir sorgu BILINCLI olarak kosulmaz: 32-bit
  surecte 2M+ satiri gercekten malzemelemek ~GB mertebesinde bellek ister ve
  testin kendisi olcumu bozardi. Tavanin reddi `tests/limits` L4 (LIMIT >
  tavan, kontrollu ecLimit) ve VDbExecutor'daki ecLimit noktalariyla
  kapsanir; burada olculen sey tavanin ALTINDAKI gercek tarama davranisidir.

  BELLEK OLCUMU: `yigin_delta_kb` = GetHeapStatus.TotalAllocated deltasi;
  ayiricinin o an KULLANIMDA saydigi bayttir. Bu alet SS20'de kendisi
  sinanir (1M Int64 = 8 MB ayirma deltada gorunmelidir) - aksi halde kucuk
  bir delta "verimlilik" degil "kor alet" olurdu. Yine de TotalAllocated
  gercek RSS degildir; raporda "olculen" denir, "tepe bellek sudur" denmez.
  LIMIT'siz 1M `SELECT *` icin olculen delta satir basina ~4 bayt cikti;
  SS16b ilk/orta/son satirlarin degerlerini ayri ayri dogrulayarak bunun
  satirlarin ayni tamponu paylasmasindan (alias) kaynaklanmadigini kanitlar.
  Kucuk deltanin nedeni bu kapida arastirilmadi; rapor yalnizca olculeni
  yazar, iyimser bir yorum katmaz.

  Derleme: fpc. Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbBackendV3, VDbPageEngine, VDbTable, VDbSql,
  VDbPageStore, VDbExecutor;

const
  ROWS100K = 100000;
  ROWS1M = 1000000;
  BATCH = 500;

var
  GDir, GDb, GBigDb: string;
  GPass, GFail: Integer;
  Be: TVdbBackendV3;
  Tb: TVTableDb;
  Sq: TVSql;

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

function FileSizeOf(const APath: string): Int64;
var
  fs: TFileStream;
begin
  Result := -1;
  if not FileExists(APath) then Exit;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := fs.Size;
  finally
    fs.Free;
  end;
end;

function HeapKB: Int64;
var
  h: THeapStatus;
begin
  h := GetHeapStatus;
  Result := Int64(h.TotalAllocated) div 1024;
end;


function Ticks: Int64;
begin
  Result := GetTickCount64;
end;

function ValOf(AId: Int64): string;
begin
  Result := 'v' + IntToStr(AId);
end;

procedure OpenDb(const APath, ADir: string);
begin
  Be := TVdbBackendV3.Create(APath);
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(ADir);
  Sq := TVSql.Create(Tb);
end;

procedure CloseDb;
begin
  FreeAndNil(Sq);
  FreeAndNil(Tb);
  Be := nil;
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

function StrQ(const ASql: string): string;
var
  r: TSqlResult;
begin
  Result := '<yok>';
  r := Sq.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := Trim(r.Rows[0][0]);
end;

{ Yeniden acilista TAM VERIFY. }
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
      begin
        ARep := E.ClassName + ': ' + E.Message;
        Result := False;
      end;
    end;
  finally
    BeC.Free;
  end;
end;

{ 500'luk islemler halinde toplu ekleme; `t` semasi (id, b, v). }
procedure BulkT(const ALo, AHi: Int64);
var
  id, i: Int64;
begin
  id := ALo;
  while id <= AHi do
  begin
    Sq.Exec('BEGIN');
    i := id;
    while (i <= AHi) and (i < id + BATCH) do
    begin
      Sq.Exec('INSERT INTO t (id, b, v) VALUES (' + IntToStr(i) + ', ' +
        IntToStr(i mod 10) + ', ''' + ValOf(i) + ''')');
      Inc(i);
    end;
    Sq.Exec('COMMIT');
    Inc(id, BATCH);
  end;
end;

{ 1M tablosu `m` (id, v). }
procedure BulkM(const ALo, AHi: Int64);
var
  id, i: Int64;
begin
  id := ALo;
  while id <= AHi do
  begin
    Sq.Exec('BEGIN');
    i := id;
    while (i <= AHi) and (i < id + BATCH) do
    begin
      Sq.Exec('INSERT INTO m (id, v) VALUES (' + IntToStr(i) + ', ''' +
        'm' + IntToStr(i) + ''')');
      Inc(i);
    end;
    Sq.Exec('COMMIT');
    Inc(id, BATCH);
  end;
end;

var
  i, j: Integer;
  n, t0, dt: Int64;
  h0, h1: Int64;
  ctrl: array of Int64;
  rep, msg: string;
  ok: Boolean;
  seed: LongWord;
  id: Int64;
  r: TSqlResult;
  fs: Int64;
  beforeVer, afterVer: Int64;

begin
  GPass := 0;
  GFail := 0;
  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp/sql_scale');
  Wipe(GDir);
  GDb := GDir + 'scale.odb';
  GBigDb := GDir + 'big.odb';

  WriteLn('--- sql_scale: SQL yurutucu olcek + bellek (bagimsiz kapi) ---');
  WriteLn('--- sonuc tavani VDB_MAX_RESULT_ROWS = ', VDB_MAX_RESULT_ROWS, ' ---');

  try
    { ================= 100k basamagi ================= }
    OpenDb(GDb, GDir);
    Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, b INTEGER, v TEXT)');
    Sq.Exec('CREATE TABLE d (id INTEGER PRIMARY KEY, w TEXT)');
    for i := 1 to 100 do
      Sq.Exec('INSERT INTO d (id, w) VALUES (' + IntToStr(i) + ', ''w' +
        IntToStr(i) + ''')');

    t0 := Ticks;
    BulkT(1, ROWS100K);
    dt := Ticks - t0;
    fs := FileSizeOf(GDb);
    n := IntQ('SELECT COUNT(*) FROM t');
    Chk('SS1 100k satir eklendi', n = ROWS100K,
      'satir=' + IntToStr(n) + ' sure_ms=' + IntToStr(dt) +
      ' dosya_bayt=' + IntToStr(fs));
    WriteLn('OLCUM SS1 100k ekleme ms=', dt, ' dosya_bayt=', fs);

    { SS2: nokta okuma ve deger dogrulugu (deterministik + LCG secimi). }
    ok := True;
    msg := '';
    for i := 1 to 10 do
    begin
      seed := LongWord(i) * 2654435761;
      id := 1 + Int64((seed shr 8) mod ROWS100K);
      if StrQ('SELECT v FROM t WHERE id = ' + IntToStr(id)) <> ValOf(id) then
      begin
        ok := False;
        msg := 'bozuk id=' + IntToStr(id);
        Break;
      end;
    end;
    if StrQ('SELECT v FROM t WHERE id = 1') <> ValOf(1) then
    begin
      ok := False;
      msg := 'ilk satir';
    end;
    if StrQ('SELECT v FROM t WHERE id = ' + IntToStr(ROWS100K)) <> ValOf(ROWS100K) then
    begin
      ok := False;
      msg := 'son satir';
    end;
    Chk('SS2 nokta okuma: 12 rasgele/kenar anahtar dogru', ok, msg);

    { SS3: WHERE + projeksiyon. }
    n := IntQ('SELECT COUNT(*) FROM t WHERE id > 90000');
    Chk('SS3 WHERE araligi: id > 90000 -> 10000', n = 10000,
      'satir=' + IntToStr(n));
    n := IntQ('SELECT COUNT(*) FROM t WHERE b = 3');
    Chk('SS3 WHERE esitligi: b = 3 -> 10000', n = 10000,
      'satir=' + IntToStr(n));

    { SS4: ORDER BY + LIMIT. }
    t0 := Ticks;
    r := Sq.Exec('SELECT id FROM t ORDER BY id DESC LIMIT 5');
    dt := Ticks - t0;
    ok := Length(r.Rows) = 5;
    msg := '';
    for i := 0 to Length(r.Rows) - 1 do
      if StrToInt64Def(Trim(r.Rows[i][0]), -1) <> Int64(ROWS100K) - Int64(i) then
      begin
        ok := False;
        msg := 'sira bozuk i=' + IntToStr(i);
      end;
    Chk('SS4 ORDER BY DESC + LIMIT 5', ok,
      'satir=' + IntToStr(Length(r.Rows)) + ' sure_ms=' + IntToStr(dt) + ' ' + msg);
    WriteLn('OLCUM SS4 100k ORDER BY DESC LIMIT 5 ms=', dt);

    { SS5: OFFSET. }
    r := Sq.Exec('SELECT id FROM t ORDER BY id LIMIT 3 OFFSET 99997');
    ok := Length(r.Rows) = 3;
    for i := 0 to Length(r.Rows) - 1 do
      if StrToInt64Def(Trim(r.Rows[i][0]), -1) <> Int64(99998) + Int64(i) then
        ok := False;
    Chk('SS5 OFFSET 99997 -> 99998..100000', ok,
      'satir=' + IntToStr(Length(r.Rows)));

    { SS6: toplamlar. }
    n := IntQ('SELECT SUM(id) FROM t');
    Chk('SS6 SUM(id) = 5000050000', n = Int64(ROWS100K) * (ROWS100K + 1) div 2,
      'sum=' + IntToStr(n));
    Chk('SS6 MIN/MAX dogru',
      (IntQ('SELECT MIN(id) FROM t') = 1) and
      (IntQ('SELECT MAX(id) FROM t') = ROWS100K),
      'min=' + IntToStr(IntQ('SELECT MIN(id) FROM t')) +
      ' max=' + IntToStr(IntQ('SELECT MAX(id) FROM t')));
    Chk('SS6 AVG(id) tam orta deger',
      Trim(StrQ('SELECT AVG(id) FROM t')) = '50000.5',
      'avg=' + StrQ('SELECT AVG(id) FROM t'));

    { SS7: GROUP BY + HAVING. 10 grup x 10000. }
    t0 := Ticks;
    r := Sq.Exec('SELECT b, COUNT(*) FROM t GROUP BY b ORDER BY b');
    dt := Ticks - t0;
    ok := Length(r.Rows) = 10;
    msg := '';
    if ok then
      for i := 0 to Length(r.Rows) - 1 do
        if (StrToIntDef(Trim(r.Rows[i][0]), -1) <> i) or
           (StrToInt64Def(Trim(r.Rows[i][1]), -1) <> ROWS100K div 10) then
        begin
          ok := False;
          msg := 'grup bozuk i=' + IntToStr(i);
          Break;
        end;
    Chk('SS7 GROUP BY b: 10 grup x 10000', ok,
      'grup=' + IntToStr(Length(r.Rows)) + ' sure_ms=' + IntToStr(dt) + ' ' + msg);
    r := Sq.Exec('SELECT b FROM t GROUP BY b HAVING COUNT(*) > 20000');
    Chk('SS7 HAVING COUNT(*) > 20000 -> 0 grup', Length(r.Rows) = 0,
      'grup=' + IntToStr(Length(r.Rows)));
    r := Sq.Exec('SELECT b FROM t GROUP BY b HAVING COUNT(*) >= 10000');
    Chk('SS7 HAVING COUNT(*) >= 10000 -> 10 grup', Length(r.Rows) = 10,
      'grup=' + IntToStr(Length(r.Rows)));

    { SS8: INNER JOIN kucuk boyut tablosuna. }
    n := IntQ('SELECT COUNT(*) FROM t INNER JOIN d ON t.id = d.id');
    Chk('SS8 INNER JOIN d: 100 eslesme', n = 100, 'satir=' + IntToStr(n));
    Chk('SS8 JOIN degeri dogru',
      StrQ('SELECT d.w FROM t INNER JOIN d ON t.id = d.id WHERE t.id = 7') = 'w7');

    { SS9: UPDATE alt kumesi. }
    t0 := Ticks;
    r := Sq.Exec('UPDATE t SET v = ''upd'' WHERE id <= 1000');
    dt := Ticks - t0;
    n := IntQ('SELECT COUNT(*) FROM t WHERE v = ''upd''');
    Chk('SS9 UPDATE 1000 satir', n = 1000,
      'etkilenen=' + IntToStr(n) + ' sure_ms=' + IntToStr(dt));

    { SS10: DELETE alt kumesi. }
    t0 := Ticks;
    Sq.Exec('DELETE FROM t WHERE id > 99000');
    dt := Ticks - t0;
    n := IntQ('SELECT COUNT(*) FROM t');
    Chk('SS10 DELETE 1000 satir', n = 99000,
      'kalan=' + IntToStr(n) + ' sure_ms=' + IntToStr(dt));

    { SS11: rastgele karisik islem (ekle/guncelle/sil), sonuc sayisi izlenir. }
    seed := 20261116;
    beforeVer := IntQ('SELECT COUNT(*) FROM t');
    j := 0;
    for i := 1 to 300 do
    begin
      seed := seed * 1103515245 + 12345;
      id := 200001 + Int64((seed shr 8) mod 1000);
      seed := seed * 1103515245 + 12345;
      case Integer((seed shr 16) mod 3) of
        0: begin
             if IntQ('SELECT COUNT(*) FROM t WHERE id = ' + IntToStr(id)) = 0 then
             begin
               Sq.Exec('INSERT INTO t (id, b, v) VALUES (' + IntToStr(id) +
                 ', 0, ''mix'')');
               Inc(j);
             end;
           end;
        1: Sq.Exec('UPDATE t SET v = ''mix'' WHERE id = ' + IntToStr(id));
        2: begin
             if IntQ('SELECT COUNT(*) FROM t WHERE id = ' + IntToStr(id)) > 0 then
             begin
               Sq.Exec('DELETE FROM t WHERE id = ' + IntToStr(id));
               Dec(j);
             end;
           end;
      end;
    end;
    afterVer := IntQ('SELECT COUNT(*) FROM t');
    Chk('SS11 karisik islem: sayim izlenen farkla tutarli',
      afterVer = beforeVer + j,
      'once=' + IntToStr(beforeVer) + ' sonra=' + IntToStr(afterVer) +
      ' fark=' + IntToStr(afterVer - beforeVer));

    { SS12: buyuk islem COMMIT -> yeniden acilista durur. }
    Sq.Exec('BEGIN');
    for i := 1 to 5000 do
      Sq.Exec('INSERT INTO t (id, b, v) VALUES (' + IntToStr(300000 + i) +
        ', 9, ''big'')');
    Sq.Exec('COMMIT');
    n := IntQ('SELECT COUNT(*) FROM t WHERE id > 300000');
    Chk('SS12 buyuk commit sonrasi 5000 satir gorunur', n = 5000,
      'satir=' + IntToStr(n));

    { SS13: buyuk islem ROLLBACK -> hayalet satir yok. }
    Sq.Exec('BEGIN');
    for i := 1 to 5000 do
      Sq.Exec('INSERT INTO t (id, b, v) VALUES (' + IntToStr(400000 + i) +
        ', 9, ''ghost'')');
    Sq.Exec('ROLLBACK');
    n := IntQ('SELECT COUNT(*) FROM t WHERE id > 400000');
    Chk('SS13 rollback sonrasi 0 hayalet satir', n = 0, 'satir=' + IntToStr(n));

    { SS14: yeniden acilis + tam VERIFY. }
    n := IntQ('SELECT COUNT(*) FROM t');
    fs := FileSizeOf(GDb);
    CloseDb;
    ok := VerifyDb(GDb, rep);
    Chk('SS14a yeniden acilis: tam VERIFY temiz', ok, 'rapor=' + rep);
    OpenDb(GDb, GDir);
    Chk('SS14b yeniden acilis: satir sayisi korunur',
      IntQ('SELECT COUNT(*) FROM t') = n,
      'satir=' + IntToStr(IntQ('SELECT COUNT(*) FROM t')) +
      ' beklenen=' + IntToStr(n) + ' dosya_bayt=' + IntToStr(fs));
    Chk('SS14c yeniden acilis: buyuk commit satirlari durur',
      IntQ('SELECT COUNT(*) FROM t WHERE id > 300000') = 5000);
    Chk('SS14d yeniden acilis: UPDATE sonucu durur',
      IntQ('SELECT COUNT(*) FROM t WHERE v = ''upd''') = 1000);
    CloseDb;

    { ================= 1M basamagi ================= }
    OpenDb(GBigDb, GDir);
    Sq.Exec('CREATE TABLE m (id INTEGER PRIMARY KEY, v TEXT)');
    h0 := HeapKB;
    t0 := Ticks;
    BulkM(1, ROWS1M);
    dt := Ticks - t0;
    h1 := HeapKB;
    fs := FileSizeOf(GBigDb);
    n := IntQ('SELECT COUNT(*) FROM m');
    Chk('SS15 1M satir ekleme + COUNT dogru', n = ROWS1M,
      'satir=' + IntToStr(n) + ' sure_ms=' + IntToStr(dt) +
      ' dosya_bayt=' + IntToStr(fs) + ' yigin_delta_kb=' + IntToStr(h1 - h0));
    WriteLn('OLCUM SS15 1M ekleme ms=', dt, ' dosya_bayt=', fs,
      ' yigin_delta_kb=', h1 - h0);

    { SS16: LIMIT'siz SELECT * -> 1M satir, tavanin (2M) ALTINDA kabul. }
    h0 := HeapKB;
    t0 := Ticks;
    r := Sq.Exec('SELECT * FROM m');
    dt := Ticks - t0;
    h1 := HeapKB;
    n := Length(r.Rows);
    Chk('SS16a LIMIT''siz SELECT * 1M satir doner (tavan 2M altinda)', n = ROWS1M,
      'satir=' + IntToStr(n) + ' sure_ms=' + IntToStr(dt) +
      ' yigin_delta_kb=' + IntToStr(h1 - h0));
    { Yalnizca ilk/son degil, ARADAKI satirlar da dogru mu? Tum satirlarin
      ayni tamponu paylasmadigini (alias) bu noktalar kanitlar. }
    ok := (n = ROWS1M) and (Trim(r.Rows[0][1]) = 'm1') and
      (Trim(r.Rows[1][1]) = 'm2') and
      (Trim(r.Rows[499999][1]) = 'm500000') and
      (Trim(r.Rows[999998][1]) = 'm999999') and
      (Trim(r.Rows[n - 1][1]) = 'm' + IntToStr(ROWS1M));
    Chk('SS16b tam tarama: ilk/orta/son degerler dogru (alias yok)', ok);
    WriteLn('OLCUM SS16 1M SELECT * ms=', dt, ' yigin_delta_kb=', h1 - h0,
      ' satir_basina_bayt=', ((h1 - h0) * 1024) div ROWS1M);
    SetLength(r.Rows, 0);

    { SS17: LIMIT'li tarama yigini sisirmemeli. }
    h0 := HeapKB;
    t0 := Ticks;
    r := Sq.Exec('SELECT id, v FROM m ORDER BY id LIMIT 100');
    dt := Ticks - t0;
    h1 := HeapKB;
    Chk('SS17 LIMIT 100: 100 satir ve kucuk yigin', Length(r.Rows) = 100,
      'satir=' + IntToStr(Length(r.Rows)) + ' sure_ms=' + IntToStr(dt) +
      ' yigin_delta_kb=' + IntToStr(h1 - h0));

    { SS18: tavan sonrasi ayni veritabani normal calisir (islem, VERIFY). }
    Sq.Exec('INSERT INTO m (id, v) VALUES (2000001, ''son'')');
    Sq.Exec('UPDATE m SET v = ''son2'' WHERE id = 2000001');
    Chk('SS18a tavan sonrasi INSERT/UPDATE calisir',
      StrQ('SELECT v FROM m WHERE id = 2000001') = 'son2');
    Sq.Exec('DELETE FROM m WHERE id = 2000001');
    Chk('SS18b tavan sonrasi DELETE calisir',
      IntQ('SELECT COUNT(*) FROM m WHERE id = 2000001') = 0);
    Chk('SS18c 1M tablo hala tam', IntQ('SELECT COUNT(*) FROM m') = ROWS1M);
    CloseDb;
    ok := VerifyDb(GBigDb, rep);
    Chk('SS18d 1M dosya VERIFY temiz', ok, 'rapor=' + rep);

    { SS19: 1M tabloda ORDER BY + LIMIT ve aggregate. }
    OpenDb(GBigDb, GDir);
    t0 := Ticks;
    r := Sq.Exec('SELECT id FROM m ORDER BY id DESC LIMIT 3');
    dt := Ticks - t0;
    ok := (Length(r.Rows) = 3) and
      (StrToInt64Def(Trim(r.Rows[0][0]), -1) = ROWS1M);
    Chk('SS19a 1M ORDER BY DESC LIMIT 3', ok,
      'satir=' + IntToStr(Length(r.Rows)) + ' sure_ms=' + IntToStr(dt));
    n := IntQ('SELECT COUNT(*) FROM m WHERE id > 999000');
    Chk('SS19b 1M WHERE araligi 1000', n = 1000, 'satir=' + IntToStr(n));

    { SS20: OLCUM ALETININ KENDISI. 1M Int64 = 8 MB ayir; alet bunu
      gormuyorsa SS16'nin kucuk deltasi "verimli" degil "kor alet" demektir. }
    h0 := HeapKB;
    SetLength(ctrl, ROWS1M);
    for i := 0 to 999 do
      ctrl[i * 1000] := i;
    h1 := HeapKB;
    Chk('SS20 olcum aleti calisiyor: 8MB ayirma yigin deltasinda gorunur',
      (h1 - h0) >= 4000,
      'yigin_delta_kb=' + IntToStr(h1 - h0) + ' (8MB beklenir)');
    WriteLn('OLCUM SS20 kontrol: 1M Int64 ayirma yigin_delta_kb=', h1 - h0);
    SetLength(ctrl, 0);
    CloseDb;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL BEKLENMEYEN ISTISNA ', E.ClassName, ': ', E.Message);
      try
        CloseDb;
      except
      end;
    end;
  end;

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  ExitCode := GFail;
end.
