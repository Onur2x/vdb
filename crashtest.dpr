program CrashTest;

{$mode delphi}
{$APPTYPE CONSOLE}

{ TR: COKME DAYANIKLILIGI TESTI (veri kaybi onceligi #1)
  EN: CRASH DURABILITY TEST (data-loss priority #1)

  NASIL CALISIR:
    crashtest.exe seed <n> <killAt>
        TEK TEK commit eder (her INSERT ayri transaction);
        killAt. kayittan sonra SureciKILLER ile KENDINI OLDURUR.
        Hicbir temizleme (finalization/Close) CALISMAZ.
    crashtest.exe txseed <n> <batch> <killAfterRows>
        n kaydi <batch> satirlik BEGIN...COMMIT gruplarinda yazar;
        killAfterRows. satirdan (grup icinde) SureciKILLER ile oldurur.
        -> ATOMIKLIK testi: yarim kalan GRUP tamamen geri sarmali.
    crashtest.exe verify
    crashtest.exe txverify <batch>
        Beklenen: kayit sayisi <batch> katlari; yarim grup GORMEMELI.

  BEKLENEN (DAYANIKLILIK SOZLESMESI):
    - Basarili commit'ler geri gelmeli (kesintisiz onek)
    - Yarim commit/okunamaz dosya OLMAMALI
    - Transaction icinde copulen grup TAMAMEN geri sarmali (atomik) }

uses
  SysUtils, Classes, {$IFDEF WINDOWS} Windows, {$ENDIF} VDbCore, VDbTable,
  VDbSql, VDbTypes;

const
  DBDIR = 'C:\temp\vdbcrash';

function EnsureDir: string;
begin
  Result := DBDIR;
  if not DirectoryExists(DBDIR) then
    ForceDirectories(DBDIR);
end;

{ TR: sureci GUVENLI finalization CAGRILMADAN oldurur / EN: hard kill }
procedure HardKill(ACode: Integer);
begin
  Flush(Output);
  {$IFDEF WINDOWS}
  TerminateProcess(GetCurrentProcess, ACode);
  {$ELSE}
  Halt(ACode);
  {$ENDIF}
end;

procedure Seed(n, killAt: Integer);
var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  i: Integer;
  R: TSqlResult;
begin
  EnsureDir;
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(DBDIR);
    tb.Open(DBDIR);
    sq.Exec('DROP TABLE IF EXISTS k');
    sq.Exec('CREATE TABLE k(id INTEGER PRIMARY KEY, v TEXT)');
    for i := 1 to n do
    begin
      R := sq.Exec(Format('INSERT INTO k(id,v) VALUES(%d,''deger-%d'')', [i, i]));
      if R.Affected <> 1 then
      begin
        WriteLn('YAZMA HATASI i=', i, ' : ', R.Msg);
        HardKill(50);
      end;
      if i = killAt then
      begin
        WriteLn('KILL at ', i);
        HardKill(99);
      end;
    end;
    WriteLn('SEED TAMAM');
  finally
    sq.Free; tb.Free; kv.Free;
  end;
end;

{ TR: BEGIN..COMMIT gruplarinda yazar; grup icinde copur / EN: kill mid-batch }
procedure TxSeed(n, batch, killAfter: Integer);
var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  i, g, inGrup: Integer;
  R: TSqlResult;
begin
  EnsureDir;
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(DBDIR);
    tb.Open(DBDIR);
    sq.Exec('DROP TABLE IF EXISTS k');
    sq.Exec('CREATE TABLE k(id INTEGER PRIMARY KEY, v TEXT)');
    i := 0;
    while i < n do
    begin
      sq.Exec('BEGIN');
      inGrup := 0;
      for g := 1 to batch do
      begin
        Inc(i);
        Inc(inGrup);
        R := sq.Exec(Format('INSERT INTO k(id,v) VALUES(%d,''deger-%d'')', [i, i]));
        if R.Affected <> 1 then
        begin
          WriteLn('YAZMA HATASI i=', i, ' : ', R.Msg);
          HardKill(50);
        end;
        // grup icinde (COMMIT oncesinde) cope: tum grup geri sarmali
        if i = killAfter then
        begin
          WriteLn('KILL mid-batch at ', i, ' (grup basi=', i - inGrup + 1, ')');
          HardKill(99);
        end;
      end;
      sq.Exec('COMMIT');
    end;
    WriteLn('TXSEED TAMAM');
  finally
    sq.Free; tb.Free; kv.Free;
  end;
end;

procedure Verify(batch: Integer);
var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  R: TSqlResult;
  i, id, k, prev: Integer;
  s: string;
  ok: Boolean;
begin
  EnsureDir;
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(DBDIR);
    tb.Open(DBDIR);

    WriteLn('-- Dosya seviyesi saglamlik --');
    try
      R := sq.Exec('VERIFY');
      WriteLn('  VERIFY : ', R.Msg);
    except
      on E: Exception do
      begin
        WriteLn('  VERIFY HATASI: ', E.Message);
        HardKill(60);
      end;
    end;

    R := sq.Exec('SELECT id FROM k ORDER BY id');
    k := Length(R.Rows);
    WriteLn('  kayit  : ', k);

    WriteLn('-- Mantiksal tutarlilik --');
    ok := True;
    prev := 0;
    for i := 0 to k - 1 do
    begin
      s := R.Rows[i][0];
      id := StrToIntDef(s, -1);
      if id <> prev + 1 then
      begin
        WriteLn('  BOZUK: pozisyon ', i, ' -> id=', id, ', beklenen=', prev + 1);
        ok := False;
        Break;
      end;
      prev := id;
    end;
    if ok then
      WriteLn('  ONEK TAMAM: 1..', prev, ' arasi bosluksuz');

    // Bos tablo (tum ilk batch cop sise geri sarmaldi) gecerli sonuc; sadece
    // kayit varsa son satir okunabilirligini dene.
    if k >= 1 then
    begin
      R := sq.Exec('SELECT v FROM k WHERE id = ' + IntToStr(prev));
      if Length(R.Rows) = 1 then
        WriteLn('  SON kayit degeri OKUNUR: ', R.Rows[0][0])
      else
      begin
        WriteLn('  SON kayit OKUNAMADI (yarim yazma)'); ok := False;
      end;
    end
    else
      WriteLn('  TABLO BOS (ilk onaysiz batch tam geri sarmaldi - beklenen)');

    R := sq.Exec('SELECT COUNT(*), SUM(id) FROM k');
    if Length(R.Rows) = 1 then
      WriteLn('  TARAMA: sayi=', R.Rows[0][0], ' toplamId=', R.Rows[0][1]);

    // TX modu: yarim grup kalmamali
    if (batch > 1) and (k mod batch <> 0) then
    begin
      WriteLn('  ATOMIKLIK BOZUK: kayit=', k, ' ', batch, '-in kati DEGIL');
      ok := False;
    end
    else if batch > 1 then
      WriteLn('  ATOMIKLIK TAMAM: tum gruplar komple (sayi=', k, ')');

    WriteLn;
    if ok then
      WriteLn('SONUC: GECTI (copme sonrasi veri kaybi/bozulma YOK)')
    else
    begin
      WriteLn('SONUC: KALDI  <-- VERI KAYBI/BOZULMA VAR');
      HardKill(70);
    end;
  finally
    sq.Free; tb.Free; kv.Free;
  end;
end;

var
  cmd: string;
begin
  if ParamCount < 1 then
  begin
    WriteLn('Kullanim: crashtest.exe seed <n> <killAt> | txseed <n> <batch> <killAfter> | verify [batch]');
    Halt(2);
  end;
  cmd := LowerCase(ParamStr(1));
  if cmd = 'seed' then
    Seed(StrToIntDef(ParamStr(2), 2000), StrToIntDef(ParamStr(3), 500))
  else if cmd = 'txseed' then
    TxSeed(StrToIntDef(ParamStr(2), 2000), StrToIntDef(ParamStr(3), 50),
           StrToIntDef(ParamStr(4), 123))
  else if cmd = 'verify' then
    Verify(StrToIntDef(ParamStr(2), 0))
  else
  begin
    WriteLn('Bilinmeyen komut: ', cmd); Halt(2);
  end;
end.
