program mvchk;
{ R2-D-YENI-2 kapisi: materialized view kaliciligi.

  1) CREATE MATERIALIZED VIEW + REFRESH -> satirlar KV'de
  2) KAPAT / YENIDEN AC        -> MV tanimi (REFRESH calisir) ve satirlar duruyor mu?
  3) Kaynak kucult, REFRESH    -> ESKI satirlar gercekten silindi mi?
                                (sayac kalici degilse eski @mv anahtarlari silinmez;
                                 yeni satirlar @mv0'dan baslayip eskilerin uzerine
                                 yazar -> MV'de karisik satirlar kalir)
  4) Kaynak buyut, REFRESH     -> cakisma yok, sayi dogru
  5) Son yeniden acilis        -> sonuc ayni

  Gecmiste yasanan iki hata:
   - MV tanimi semaya hic yazilmiyordu -> yeniden acilista REFRESH
     "materialized view yok" hatasi veriyordu ('#M' sema satiri eklendi).
   - Temizlik v.AutoInc sayacina bagimliydi -> yeniden acilista sayac 0 ise
     hicbir satir silinmiyordu (tarama tabanli temizlige gecildi). }
{$mode delphi}{$H+}
uses
  SysUtils, Classes,
  VDbCore, VDbTypes, VDbTable, VDbSql;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  dir: string;
  nBad, nOk: Integer;

procedure Ac;
begin
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  kv.Open(dir);
  tb.Open(dir);
end;

procedure Kapat;
begin
  sq.Free; tb.Free; kv.Free;
  sq := nil; tb := nil; kv := nil;
end;

procedure ChkInt(const Title: string; Got, Expected: Integer);
begin
  if Got = Expected then
  begin
    Inc(nOk);
    WriteLn('  TAMAM: ', Title, ' = ', Got);
  end
  else
  begin
    Inc(nBad);
    WriteLn('  *** UYUSMAZLIK: ', Title, ' beklenen=', Expected, ' gelen=', Got);
  end;
end;

function Say(const ViewName: string): Integer;
var
  R: TSqlResult;
begin
  R := sq.Exec('SELECT COUNT(*) AS n FROM ' + ViewName);
  if Length(R.Rows) = 0 then Exit(-1);
  Result := StrToIntDef(R.Rows[0][0], -1);
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'kullanim: mvchk <dizin>');
    Halt(2);
  end;
  dir := ParamStr(1);
  ForceDirectories(dir);
  nBad := 0;
  nOk := 0;

  WriteLn('=== 1) kurulum + ilk REFRESH ===');
  Ac;
  sq.Exec('CREATE TABLE kaynak(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO kaynak VALUES(1,10)');
  sq.Exec('INSERT INTO kaynak VALUES(2,20)');
  sq.Exec('INSERT INTO kaynak VALUES(3,30)');
  sq.Exec('CREATE MATERIALIZED VIEW mv_o AS SELECT id, v FROM kaynak');
  sq.Exec('REFRESH MATERIALIZED VIEW mv_o');
  ChkInt('ilk MV satir sayisi', Say('mv_o'), 3);
  Kapat;

  WriteLn('=== 2) yeniden acilis: MV tanimi + satirlar kalici mi? ===');
  Ac;
  ChkInt('yeniden acilista MV satir sayisi', Say('mv_o'), 3);
  // Tanim kaybolduysa REFRESH burada acik hata verir.
  sq.Exec('REFRESH MATERIALIZED VIEW mv_o');
  ChkInt('yeniden acilista REFRESH sonrasi satir sayisi', Say('mv_o'), 3);
  Kapat;

  WriteLn('=== 3) kaynak kucult + REFRESH: eski satirlar siliniyor mu? ===');
  Ac;
  sq.Exec('DELETE FROM kaynak WHERE id > 1');
  sq.Exec('REFRESH MATERIALIZED VIEW mv_o');
  ChkInt('REFRESH sonrasi MV satir sayisi', Say('mv_o'), 1);
  Kapat;

  WriteLn('=== 4) yeniden acilis + kaynak buyut ===');
  Ac;
  ChkInt('son yeniden acilista MV satir sayisi', Say('mv_o'), 1);
  sq.Exec('INSERT INTO kaynak VALUES(2,20)');
  sq.Exec('INSERT INTO kaynak VALUES(3,30)');
  sq.Exec('REFRESH MATERIALIZED VIEW mv_o');
  ChkInt('buyutme sonrasi MV satir sayisi', Say('mv_o'), 3);
  Kapat;

  WriteLn('=== 5) son yeniden acilis ===');
  Ac;
  ChkInt('kapanistan sonra MV satir sayisi', Say('mv_o'), 3);
  Kapat;

  WriteLn;
  if nBad = 0 then
  begin
    WriteLn('MATERIALIZED VIEW KALICILIGI DOGRULANDI');
    WriteLn('SONUC: gecen=', nOk, ' kalan=0');
  end
  else
    WriteLn('SONUC: gecen=', nOk, ' kalan=', nBad);
  if nBad <> 0 then Halt(1);
end.
