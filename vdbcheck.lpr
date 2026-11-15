program vdbcheck;
{ SKILL2 §23 — butunluk denetleyici (integrity checker).

Kullanim:
  vdbcheck [--quick|--full|--index|--wal] [--dry-run] <veritabani.odb>
  vdbcheck --help

Modlar (§23.2):
  --quick  baslik + freelist + sayfa kimligi/tipi (CRC hesaplanmaz: hizli)
  --full   tam denetim: CRC + heap hucreleri + tasma zincirleri + indeks
  --index  sayfa taramasi (CRC'siz) + heap dizini tutarliligi
  --wal    yalniz WAL kuyrugu: commit/cerceve/bayt + kesik kuyruk uyarisi

Salt-okunur sozlesme (§23.3):
  Arac veritabani HER ZAMAN salt-okunur acar; yazma yolu YOKTUR. Bu yuzden
  denetim veritabanini degistiremez, sessiz onarim yapamaz. `.wal`/`.gen`
  gibi yan dosya da olusturmaz. `--dry-run` kabul edilir ve her zaman
  etkindir (acikca belirtmek icin).

Cikis kodlari:
  0  temiz (uyarilar olabilir; uyari ile bozulma AYRILIR)
  1  kullanim hatasi / dosya yok
  2  bozulma: dosya acilamadi ya da denetim Reddetti (rapor stderr'e)
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, VDbBackendV3, VDbPageEngine, VDbErr;

var
  GMode: TVdbVerifyMode;
  GModeSet: Boolean;
  GPath: string;
  GDryRun: Boolean;

procedure Usage;
begin
  WriteLn('kullanim: vdbcheck [--quick|--full|--index|--wal] [--dry-run] <db>');
  WriteLn('  varsayilan mod: --full');
  WriteLn('  cikis: 0 temiz, 1 kullanim hatasi, 2 bozulma');
end;

function ParseArgs: Boolean;
var
  i: Integer;
  a: string;
begin
  Result := False;
  GMode := vmFull;
  GModeSet := False;
  GDryRun := False;
  GPath := '';
  i := 1;
  while i <= ParamCount do
  begin
    a := ParamStr(i);
    if (a = '--help') or (a = '-h') or (a = '-?') then
    begin
      Usage;
      Halt(0);
    end
    else if a = '--quick' then
    begin
      GMode := vmQuick;
      GModeSet := True;
    end
    else if a = '--full' then
    begin
      GMode := vmFull;
      GModeSet := True;
    end
    else if a = '--index' then
    begin
      GMode := vmIndex;
      GModeSet := True;
    end
    else if a = '--wal' then
    begin
      GMode := vmWal;
      GModeSet := True;
    end
    else if a = '--dry-run' then
      GDryRun := True
    else if (Length(a) > 0) and (a[1] = '-') then
    begin
      WriteLn(StdErr, 'vdbcheck: bilinmeyen secenek: ', a);
      Exit(False);
    end
    else if GPath = '' then
      GPath := a
    else
    begin
      WriteLn(StdErr, 'vdbcheck: tek bir veritabani yolu verilebilir');
      Exit(False);
    end;
    Inc(i);
  end;
  Result := GPath <> '';
end;

var
  Be: TVdbBackendV3;
  rep: string;
  ok: Boolean;
begin
  if not ParseArgs then
  begin
    Usage;
    Halt(1);
  end;
  if not FileExists(GPath) then
  begin
    WriteLn(StdErr, 'vdbcheck: dosya yok: ', GPath);
    Halt(1);
  end;

  Be := nil;
  try
    try
      { Her zaman salt-okunur: cok okuyucu ile ayni anda calisabilir. }
      Be := TVdbBackendV3.CreateReadOnly(GPath);
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'BOZUK acilamadi: ', E.ClassName, ': ', E.Message);
        Halt(2);
      end;
    end;

    rep := '';
    try
      ok := Be.Engine.VerifyEx(GMode, True, rep);
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'BOZUK denetim hatasi: ', E.ClassName, ': ', E.Message);
        Halt(2);
      end;
    end;

    if ok then
    begin
      WriteLn('TEMIZ ', VDB_VERIFY_MODE_NAME[GMode], ': ', rep);
      Halt(0);
    end;
    WriteLn(StdErr, 'BOZUK ', VDB_VERIFY_MODE_NAME[GMode], ': ', rep);
    Halt(2);
  finally
    FreeAndNil(Be);
  end;
end.
