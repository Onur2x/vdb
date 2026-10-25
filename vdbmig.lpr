program vdbmig;

{ VDB - v2 -> v3 goc araci (komut satiri)

  Amac: v2 (VODB, satir-kayit dosyasi) bir veritabanini v3 (VDB3, sayfa
  motoru) dosyasina tasimak ve tasinan veriyi BAYT BAYT dogrulamak.

  Isi yapan motor hazir: VDbMigrate.pas
    VdbMigrateToV3 : KV kayitlarini (sema + satirlar + dizinler) kopyalar
    VdbMigrateVerify: her kaynagi hedefte bayt bayt karsilastirir
  Bu program yalnizca kullanici arayuzu + guvenlik kontrolleridir:
    - kaynak gercekten v2 mi (imza),
    - hedef zaten var mi (uzerine YAZMAZ),
    - kopya sonrasi dogrulama (basarisizsa dosya karantinaya alinir),
    - makine okunur ozet + sabit cikis kodlari.

  Cikis kodlari:
    0 basarili
    1 kullanim hatasi
    2 hedef dolu / reddedildi
    3 kaynak hatasi (yok, bozuk, v3)
    4 kopya hatasi
    5 dogrulama hatasi (hedef karantinaya alindi)

  Sinirlar: sifreli/anahtarli v2 veritabanlari ve acik v2 oturumu olan
  canli dizinler desteklenmez; kaynak salt-okunur acilir.
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: cthreads programin EN BASINDA olmali (TEvent/TThread). }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, VDbCore, VDbBackendApi, VDbBackendV2, VDbTable, VDbMigrate;

const
  TOOL_VER = '1.0';
  VDB_MAGIC_V2 = $42444F56;  // 'VODB' little-endian
  VDB_MAGIC_V3 = $33424456;  // 'VDB3'

  EXIT_OK = 0;
  EXIT_USAGE = 1;
  EXIT_REFUSED = 2;
  EXIT_SOURCE = 3;
  EXIT_COPY = 4;
  EXIT_VERIFY = 5;

  DEF_POOL = 256;

type
  TOptions = record
    Src: string;
    Dst: string;
    Pool: Integer;
    Quiet: Boolean;
    DryRun: Boolean;
  end;

  TV2Handle = record
    Kv: TVDb;
    Tb: TVTableDb;
  end;

procedure Usage(const Verb: string);
begin
  if Verb = 'copy' then
  begin
    WriteLn('vdbmig copy - v2 veritabanini v3 dosyasina tasir');
    WriteLn;
    WriteLn('Kullanim:');
    WriteLn('  vdbmig copy <kaynak> <hedef.odb> [--pool N] [--dry-run] [--quiet]');
    WriteLn;
    WriteLn('Secenekler:');
    WriteLn('  --pool N    Sayfa motoru havuzu (varsayilan ', DEF_POOL, ')');
    WriteLn('  --dry-run   Yalniz plan: kaynak sayilir, hedef YAZILMAZ');
    WriteLn('  --quiet     Yalniz ozet satirlari');
    WriteLn('  --help      Bu yardim');
    WriteLn;
    WriteLn('Kaynak: v2 dizini (icinde veritabani.odb) ya da dogrudan .odb dosyasi.');
    WriteLn('Hedef : yeni .odb dosyasi. Var olan dosyanin uzerine YAZILMAZ.');
    WriteLn;
    WriteLn('Ornekler:');
    WriteLn('  vdbmig copy D:\veritabani\db D:\veritabani\db\v3.odb');
    WriteLn('  vdbmig copy D:\veritabani\db\veritabani.odb v3.odb --pool 512');
    WriteLn('  vdbmig copy D:\veritabani\db v3.odb --dry-run');
    Exit;
  end;
  if Verb = 'verify' then
  begin
    WriteLn('vdbmig verify - goc edilmis v3 dosyasini kaynakla karsilastirir');
    WriteLn;
    WriteLn('Kullanim:');
    WriteLn('  vdbmig verify <kaynak> <hedef.odb> [--pool N] [--quiet]');
    WriteLn;
    WriteLn('Her kaynak anahtari hedefte BAYT BAYT ayni olmali. Fark varsa');
    WriteLn('cikis kodu 5, ilk farkli anahtar bildirilir.');
    WriteLn;
    WriteLn('Ornekler:');
    WriteLn('  vdbmig verify D:\veritabani\db v3.odb');
    Exit;
  end;
  WriteLn('vdbmig ', TOOL_VER, ' - VDB v2 -> v3 goc araci');
  WriteLn;
  WriteLn('Kullanim:');
  WriteLn('  vdbmig copy   <kaynak> <hedef.odb> [secenekler]');
  WriteLn('  vdbmig verify <kaynak> <hedef.odb> [secenekler]');
  WriteLn('  vdbmig --help | help copy | help verify');
  WriteLn;
  WriteLn('Cikis kodlari: 0 tamam, 1 kullanim, 2 hedef dolu, 3 kaynak,');
  WriteLn('               4 kopya, 5 dogrulama');
  WriteLn;
  WriteLn('Ornekler:');
  WriteLn('  vdbmig copy D:\veritabani\db D:\veritabani\db\v3.odb');
  WriteLn('  vdbmig verify D:\veritabani\db D:\veritabani\db\v3.odb');
end;

function MagicName(M: LongWord): string;
begin
  if M = VDB_MAGIC_V2 then
    Result := 'v2 (VODB)'
  else if M = VDB_MAGIC_V3 then
    Result := 'v3 (VDB3)'
  else
    Result := Format('bilinmeyen ($%.8x)', [M]);
end;

function ReadMagic(const Path: string; out M: LongWord; out Err: string): Boolean;
var
  f: TFileStream;
begin
  Result := False;
  M := 0;
  Err := '';
  try
    f := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  except
    on E: Exception do
    begin
      Err := 'dosya acilamadi: ' + E.Message;
      Exit;
    end;
  end;
  try
    if f.Size < 4 then
    begin
      Err := 'dosya 4 bayttan kucuk (gecerli VDB dosyasi degil)';
      Exit;
    end;
    f.ReadBuffer(M, 4);
    Result := True;
  finally
    f.Free;
  end;
end;

{ Kaynagi mutlak .odb yoluna cevirir. Dizin verilirse icinde
  veritabani.odb aranir (v2 duzeni). }
function ResolveSource(const Arg: string; out OdbFile, Err: string): Boolean;
var
  d: string;
begin
  Result := False;
  OdbFile := '';
  Err := '';
  if Trim(Arg) = '' then
  begin
    Err := 'kaynak yol bos';
    Exit;
  end;
  if DirectoryExists(Arg) then
  begin
    d := IncludeTrailingPathDelimiter(ExpandFileName(Arg));
    OdbFile := d + 'veritabani.odb';
    if not FileExists(OdbFile) then
    begin
      Err := 'dizinde veritabani.odb yok: ' + d;
      Exit;
    end;
  end
  else if FileExists(Arg) then
  begin
    if not SameText(ExtractFileExt(Arg), '.odb') then
    begin
      Err := 'kaynak .odb dosyasi ya da veritabani dizini olmali: ' + Arg;
      Exit;
    end;
    OdbFile := ExpandFileName(Arg);
  end
  else
  begin
    Err := 'kaynak bulunamadi: ' + Arg;
    Exit;
  end;
  Result := True;
end;

{ Hedef ve yan dosyalarindan herhangi biri varsa true. Uzerine yazmayiz:
  yarim/eski bir dosyayi "goc etmis" sanmak veri kaybi gibi gorunur. }
function TargetBusy(const Dest: string; out Which: string): Boolean;
var
  cand: array[0..3] of string;
  i: Integer;
begin
  Which := '';
  cand[0] := Dest;
  cand[1] := Dest + '.idx';
  cand[2] := Dest + '.wal';
  cand[3] := ChangeFileExt(Dest, '.colkey');
  for i := Low(cand) to High(cand) do
    if FileExists(cand[i]) then
    begin
      Which := cand[i];
      Exit(True);
    end;
  Result := False;
end;

function FileSizeOf(const Path: string): Int64;
var
  f: TFileStream;
begin
  Result := -1;
  if not FileExists(Path) then
    Exit;
  f := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    Result := f.Size;
  finally
    f.Free;
  end;
end;

function OpenV2(const OdbFile: string; out H: TV2Handle; out Err: string): Boolean;
var
  dir: string;
begin
  Result := False;
  Err := '';
  H.Kv := nil;
  H.Tb := nil;
  dir := IncludeTrailingPathDelimiter(ExtractFileDir(OdbFile));
  try
    H.Kv := TVDb.Create;
    H.Kv.Open(OdbFile);
    H.Tb := TVTableDb.Create(H.Kv);
    H.Tb.Open(dir);
    Result := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      if H.Tb <> nil then
        FreeAndNil(H.Tb);
      if H.Kv <> nil then
      begin
        try
          H.Kv.Close;
        except
          { kapanis hatasi asil hatayi ezmesin }
        end;
        FreeAndNil(H.Kv);
      end;
    end;
  end;
end;

procedure CloseV2(var H: TV2Handle);
begin
  if H.Tb <> nil then
  begin
    try
      H.Tb.Close;
    except
      { kapanis hatasi raporu ezmesin }
    end;
    FreeAndNil(H.Tb);
  end;
  if H.Kv <> nil then
  begin
    try
      H.Kv.Close;
    except
      { kapanis hatasi raporu ezmesin }
    end;
    FreeAndNil(H.Kv);
  end;
end;

{ Dogrulamasi tutmayan hedefi oldugu yerde birakmak tehlikeli: bir sonraki
  acilis onu gecerli veritabani sanabilir. Ana dosya + yan dosyalar
  ".bad" sonekiyle karantinaya alinir. }
function Quarantine(const Dest: string): Boolean;
var
  i: Integer;
  from_, to_: string;
  sfx: array[0..2] of string;
begin
  Result := True;
  if not RenameFile(Dest, Dest + '.bad') then
  begin
    WriteLn('   UYARI: hedef karantinaya alinamadi: ' + Dest);
    Result := False;
  end;
  sfx[0] := '.idx';
  sfx[1] := '.wal';
  sfx[2] := '.colkey';
  for i := Low(sfx) to High(sfx) do
  begin
    if sfx[i] = '.colkey' then
      from_ := ChangeFileExt(Dest, sfx[i])
    else
      from_ := Dest + sfx[i];
    if FileExists(from_) then
    begin
      to_ := Dest + '.bad' + sfx[i];
      if not RenameFile(from_, to_) then
        WriteLn('   UYARI: yan dosya karantinaya alinamadi: ' + from_);
    end;
  end;
end;

function ParseOptions(const Verb: string; const First: Integer;
  var O: TOptions; out Err: string; out HelpAsked: Boolean): Boolean;
var
  i: Integer;
  a: string;
  pos: Integer;
begin
  Result := False;
  Err := '';
  HelpAsked := False;
  O.Pool := DEF_POOL;
  O.Quiet := False;
  O.DryRun := False;
  O.Src := '';
  O.Dst := '';
  pos := 0;
  i := First;
  while i <= ParamCount do
  begin
    a := ParamStr(i);
    if (a = '--help') or (a = '-h') or (a = 'help') then
    begin
      HelpAsked := True;
      Usage(Verb);
      Exit;
    end
    else if a = '--quiet' then
      O.Quiet := True
    else if a = '--dry-run' then
      O.DryRun := True
    else if a = '--pool' then
    begin
      Inc(i);
      if i > ParamCount then
      begin
        Err := '--pool degeri eksik';
        Exit;
      end;
      if not TryStrToInt(ParamStr(i), O.Pool) or (O.Pool < 8) then
      begin
        Err := '--pool gecersiz (en az 8): ' + ParamStr(i);
        Exit;
      end;
    end
    else if Copy(a, 1, 1) = '-' then
    begin
      Err := 'bilinmeyen secenek: ' + a;
      Exit;
    end
    else
    begin
      Inc(pos);
      if pos = 1 then
        O.Src := a
      else if pos = 2 then
        O.Dst := a
      else
      begin
        Err := 'fazla arguman: ' + a;
        Exit;
      end;
    end;
    Inc(i);
  end;
  if O.Src = '' then
  begin
    Err := 'kaynak gerekli';
    Exit;
  end;
  if O.Dst = '' then
  begin
    Err := 'hedef gerekli';
    Exit;
  end;
  if not SameText(ExtractFileExt(O.Dst), '.odb') then
  begin
    Err := 'hedef .odb uzantili olmali: ' + O.Dst;
    Exit;
  end;
  O.Dst := ExpandFileName(O.Dst);
  Result := True;
end;

procedure PrintError(const Msg, Hint: string);
begin
  WriteLn(StdErr, 'Hata: ', Msg);
  if Hint <> '' then
    WriteLn(StdErr, '  ', Hint);
end;

function LoadSource(var O: TOptions; out OdbFile, Err: string): Boolean;
var
  m: LongWord;
  sz: Int64;
begin
  Result := False;
  if not ResolveSource(O.Src, OdbFile, Err) then
    Exit;
  if not ReadMagic(OdbFile, m, Err) then
    Exit;
  if m = VDB_MAGIC_V3 then
  begin
    Err := 'kaynak zaten v3 (' + OdbFile + '); goc gerekmez';
    Exit;
  end;
  if m <> VDB_MAGIC_V2 then
  begin
    Err := 'kaynak VDB dosyasi degil (imza: ' + MagicName(m) + ')';
    Exit;
  end;
  sz := FileSizeOf(OdbFile);
  if not O.Quiet then
    WriteLn('kaynak : ', OdbFile, ' (v2, ', sz, ' B)');
  Result := True;
end;

function DoCopy(var O: TOptions): Integer;
var
  OdbFile, Err, Which: string;
  H: TV2Handle;
  be: IVDbBackend;
  rep: TVdbMigrateReport;
  szSrc, szDst: Int64;
begin
  Result := EXIT_COPY;
  if not LoadSource(O, OdbFile, Err) then
  begin
    PrintError(Err, 'vdbmig copy <kaynak> <hedef.odb>');
    Exit(EXIT_SOURCE);
  end;

  if TargetBusy(O.Dst, Which) then
  begin
    PrintError('hedef dolu: ' + Which,
      'Var olan dosyanin uzerine yazilmaz. Baska bir hedef secin ya da ' +
      'dosyayi kendiniz tasiyin.');
    Exit(EXIT_REFUSED);
  end;
  if not O.Quiet then
    WriteLn('hedef  : ', O.Dst, ' (yeni dosya)');

  { Kaynagi salt-okunur acariz: goc, kaynak dosyaya yazmaz. }
  if not OpenV2(OdbFile, H, Err) then
  begin
    PrintError('kaynak v2 acilamadi: ' + Err, '');
    Exit(EXIT_SOURCE);
  end;
  be := TVdbBackendV2.Create(H.Kv);
  try
    if not O.Quiet then
      WriteLn('kayit  : ', be.Count);

    if O.DryRun then
    begin
      if not O.Quiet then
        WriteLn('plan   : kaynak okunur, hedef YAZILMAZ (--dry-run)');
      WriteLn('sonuc  : PLAN (yazma yok)');
      Exit(EXIT_OK);
    end;

    if not O.Quiet then
      WriteLn('kopya  : basladi (havuz ', O.Pool, ')');
    if not VdbMigrateToV3(be, O.Dst, O.Pool, rep, Err) then
    begin
      PrintError('kopya basarisiz: ' + Err, 'Hedefte yarim dosya birakilmadi.');
      Exit(EXIT_COPY);
    end;
    if not O.Quiet then
      WriteLn('kopya  : ', rep.Keys, ' kayit, ', rep.Bytes, ' B deger, ',
        rep.Ms, ' ms');

    if not VdbMigrateVerify(be, O.Dst, O.Pool, rep, Err) then
    begin
      PrintError('dogrulama basarisiz: ' + Err,
        'Kaynak dosyaya dokunulmadi. Hedef karantinaya alindi: ' + O.Dst + '.bad');
      Quarantine(O.Dst);
      Exit(EXIT_VERIFY);
    end;
    if not O.Quiet then
      WriteLn('dogrula: ', rep.Keys, ' kayit bayt bayt ayni, ', rep.Ms, ' ms');
  finally
    be := nil;
    CloseV2(H);
  end;

  szSrc := FileSizeOf(OdbFile);
  szDst := FileSizeOf(O.Dst);
  if (szSrc > 0) and (szDst > 0) then
    WriteLn(Format('boyut  : v2=%d B  v3=%d B  (%.1f%%)',
      [szSrc, szDst, szDst * 100.0 / szSrc]));
  WriteLn('sonuc  : TAMAM');
  Result := EXIT_OK;
end;

function DoVerify(var O: TOptions): Integer;
var
  OdbFile, Err: string;
  H: TV2Handle;
  be: IVDbBackend;
  rep: TVdbMigrateReport;
begin
  Result := EXIT_VERIFY;
  if not LoadSource(O, OdbFile, Err) then
  begin
    PrintError(Err, 'vdbmig verify <kaynak> <hedef.odb>');
    Exit(EXIT_SOURCE);
  end;
  if not FileExists(O.Dst) then
  begin
    PrintError('hedef yok: ' + O.Dst, 'Once: vdbmig copy <kaynak> ' + O.Dst);
    Exit(EXIT_SOURCE);
  end;
  if not O.Quiet then
    WriteLn('hedef  : ', O.Dst, ' (', FileSizeOf(O.Dst), ' B)');

  if not OpenV2(OdbFile, H, Err) then
  begin
    PrintError('kaynak v2 acilamadi: ' + Err, '');
    Exit(EXIT_SOURCE);
  end;
  be := TVdbBackendV2.Create(H.Kv);
  try
    if VdbMigrateVerify(be, O.Dst, O.Pool, rep, Err) then
    begin
      if not O.Quiet then
        WriteLn('karsilastir: ', rep.Keys, ' kayit bayt bayt ayni, ',
          rep.Ms, ' ms');
      WriteLn('sonuc  : TAMAM');
      Result := EXIT_OK;
    end
    else
    begin
      PrintError('dogrulama basarisiz: ' + Err, '');
      if rep.HasFirstBad then
        WriteLn(StdErr, Format('  ilk farkli anahtar: $%.16x', [rep.FirstBad]));
      WriteLn('sonuc  : FARK VAR');
      Result := EXIT_VERIFY;
    end;
  finally
    be := nil;
    CloseV2(H);
  end;
end;

var
  verb: string;
  O: TOptions;
  err: string;
  code: Integer;
  helpAsked: Boolean;
begin
  if ParamCount = 0 then
  begin
    Usage('');
    Halt(EXIT_USAGE);
  end;

  verb := LowerCase(ParamStr(1));
  if (verb = '--help') or (verb = '-h') or (verb = '-?') or (verb = 'help') then
  begin
    if ParamCount >= 2 then
      Usage(LowerCase(ParamStr(2)))
    else
      Usage('');
    Halt(EXIT_OK);
  end;

  if (verb <> 'copy') and (verb <> 'verify') then
  begin
    PrintError('bilinmeyen komut: ' + ParamStr(1),
      'Gecerli komutlar: copy, verify.  Yardim: vdbmig --help');
    Halt(EXIT_USAGE);
  end;

  if not ParseOptions(verb, 2, O, err, helpAsked) then
  begin
    if helpAsked then
      Halt(EXIT_OK);
    PrintError(err, 'Yardim: vdbmig help ' + verb);
    Halt(EXIT_USAGE);
  end;

  if verb = 'copy' then
    code := DoCopy(O)
  else
    code := DoVerify(O);
  Halt(code);
end.
