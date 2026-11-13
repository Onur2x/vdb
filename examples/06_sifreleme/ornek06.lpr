program ornek06_sifreleme;

{ TR: VDB Şifreleme Örneği (v3)
  EN: VDB Encryption Example (v3)

  v3'te sifreleme DOSYA duzeyindedir: veritabani parola ile olusturulur ve
  yalnizca ayni parola ile acilir (AES-256, sayfa govdeleri sifreli).
  Parolasiz veya yanlis parolayla acilis REDDEDILIR.

  NOT: v2'nin `ALTER DATABASE KEY` (kolon anahtari rotasyonu) deyimi v3
  sayfa motorunda yoktur; v3 dosyasi acilirken parola ile kurulur.

  In v3 encryption is at FILE level: the database is created with a password
  and opens only with that password. Opening without / with a wrong password
  is rejected. v2's `ALTER DATABASE KEY` is not part of the v3 page engine. }

{$mode delphi}{$H+}

uses
  SysUtils, VDbBackendApi, VDbFactory, VDbTable, VDbSql;

const
  DB_DIR = 'ornek06_db';
  DB_PW  = 'GizliParola123!';

var
  Be: IVdbBackend;
  TB: TVTableDb;
  SQ: TVSql;
  R: TSqlResult;

procedure ShowRows(const Title: string; R: TSqlResult);
var
  I, J: Integer;
begin
  WriteLn;
  WriteLn(Title);
  for I := 0 to High(R.Rows) do
  begin
    Write('   ');
    for J := 0 to High(R.Rows[I]) do
    begin
      if J > 0 then Write(' | ');
      Write(R.Rows[I][J]);
    end;
    WriteLn;
  end;
end;

function DbFile: string;
begin
  Result := IncludeTrailingPathDelimiter(DB_DIR) + 'veritabani.odb';
end;

procedure DeleteOldDb;
var
  p: string;
begin
  p := DbFile;
  if FileExists(p) then DeleteFile(p);
  if FileExists(p + '.wal') then DeleteFile(p + '.wal');
  if FileExists(p + '.idx') then DeleteFile(p + '.idx');
end;

begin
  WriteLn('=== VDB Şifreleme / Encryption ===');
  WriteLn;

  DeleteOldDb;

  // 1. Parola ile sifreli veritabani olustur
  WriteLn('1. Şifreli veritabanı oluşturuluyor... / Creating encrypted database...');
  VdbOpenWithPassword(DB_DIR, DB_PW, Be);
  TB := TVTableDb.CreateBackend(Be);
  SQ := TVSql.Create(TB);
  try
    TB.Open(DB_DIR);
    SQ.Exec('CREATE TABLE gizli (id INTEGER PRIMARY KEY, ad TEXT, sifre TEXT)');
    SQ.Exec('INSERT INTO gizli (id, ad, sifre) VALUES (1, ''Kullanıcı 1'', ''secret123'')');
    SQ.Exec('INSERT INTO gizli (id, ad, sifre) VALUES (2, ''Kullanıcı 2'', ''password456'')');
    WriteLn('   OK');
  finally
    SQ.Free;
    TB.Free;
    Be := nil;   // dosya kapanir; sayfalar diskte sifreli
  end;

  // 2. Dogru parola ile tekrar ac ve oku
  WriteLn;
  WriteLn('2. Doğru parola ile açılıyor... / Opening with the right password...');
  VdbOpenWithPassword(DB_DIR, DB_PW, Be, False);
  TB := TVTableDb.CreateBackend(Be);
  SQ := TVSql.Create(TB);
  try
    TB.Open(DB_DIR);
    R := SQ.Exec('SELECT id, ad, sifre FROM gizli');
    ShowRows('   Şifreli veriler / Encrypted data', R);
  finally
    SQ.Free;
    TB.Free;
    Be := nil;
  end;

  // 3. Parolasiz acilis reddedilir
  WriteLn;
  WriteLn('3. Parolasız açılış deneniyor... / Trying without a password...');
  try
    VdbOpen(DB_DIR, Be, False);
    Be := nil;
    WriteLn('   BEKLENMEYEN: parolasız açıldı! / UNEXPECTED: opened without password!');
  except
    on E: Exception do
      WriteLn('   Reddedildi (beklenen) / Rejected (expected): ', E.Message);
  end;

  // 4. Yanlis parola reddedilir
  WriteLn;
  WriteLn('4. Yanlış parola deneniyor... / Trying a wrong password...');
  try
    VdbOpenWithPassword(DB_DIR, 'yanlis-parola', Be, False);
    Be := nil;
    WriteLn('   BEKLENMEYEN: yanlış parola kabul edildi! / UNEXPECTED: wrong password accepted!');
  except
    on E: Exception do
      WriteLn('   Reddedildi (beklenen) / Rejected (expected): ', E.Message);
  end;

  WriteLn;
  WriteLn('=== Tamamlandı / Completed ===');

  WriteLn;
  WriteLn('Çıkmak için Enter / Press Enter to exit');
  ReadLn;
end.
