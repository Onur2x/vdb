program snapchk;
{ SNAPSHOT IZOLASYON KANITI (v3.15).
  Tek surec, iki oturum (VdbSessionIdFunc ile kimlik degistirilir):
    oturum 1: BeginBatch -> anlik goruntu
    oturum 2: BeginBatch -> yaz/sil/ekle -> CommitBatch
    oturum 1: kendi anlik goruntusunu GORMELI (eski degerler, silinen
              satir geri gelmeli, yeni satir gorunmemeli, Count sabit)
  Ayrica: kendi yazdigi satiri kendisi gorur; commit sonrasi guncel
  veriyi gorur; yazma cakismasi hala yakalanir.
  Kullanim: snapchk <dizin> }
{$mode delphi}{$H+}
uses
  SysUtils, Classes, VDbBackendApi, VDbBackendV3;

var
  gSid: Cardinal = 0;
  gFail: Integer = 0;
  gPass: Integer = 0;

function SidFunc: Cardinal;
begin
  Result := gSid;
end;

procedure Ok(const Ad: string; Kosul: Boolean; const Ayrinti: string);
begin
  if Kosul then
  begin
    Inc(gPass);
    WriteLn('   OK   ', Ad, '   [', Ayrinti, ']');
  end
  else
  begin
    Inc(gFail);
    WriteLn('   FAIL ', Ad, '   [', Ayrinti, ']');
  end;
end;

function B(const S: string): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then Move(S[1], Result[0], Length(S));
end;

function S(const V: TBytes): string;
begin
  SetLength(Result, Length(V));
  if Length(V) > 0 then Move(V[0], Result[1], Length(V));
end;

function Oku(be: TVdbBackendV3; K: QWord): string;
var v: TBytes;
begin
  if be.Get(K, v) then Result := S(v) else Result := '<yok>';
end;

var
  be: TVdbBackendV3;
  keys: TQWordArray;
  vals: TValArray;
  i: Integer;
  kume: string;

begin
  VdbSessionIdFunc := @SidFunc;
  if DirectoryExists(ParamStr(1)) then
  begin
    // onceki kosudan kalan dosyalari temizle
    DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1)) + 'veritabani.odb');
    DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1)) + 'veritabani.idx');
    DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1)) + 'veritabani.log');
    DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1)) + 'veritabani.meta');
    DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1)) + 'veritabani.undo');
  end;
  ForceDirectories(ParamStr(1));
  be := TVdbBackendV3.Create(IncludeTrailingPathDelimiter(ParamStr(1)) +
    'veritabani.odb', True, 512);
  try
    gSid := 0;
    for i := 1 to 5 do be.Put(i, B('v' + IntToStr(i)));
    Ok('baslangic 5 satir', be.Count = 5, IntToStr(be.Count));

    // --- oturum 1 anlik goruntuyu alir
    gSid := 1;
    be.BeginBatch;
    Ok('oturum1 kendi verisini gorur', Oku(be, 1) = 'v1', Oku(be, 1));

    // --- oturum 2 yazar ve commit eder
    gSid := 2;
    be.BeginBatch;
    be.Put(1, B('v1-YENI'));
    be.Delete(2);
    be.Put(9, B('v9'));
    be.CommitBatch;

    // --- oturum 1 hala ESKI goruntuyu gormeli
    gSid := 1;
    Ok('snapshot: degisen satir eski deger', Oku(be, 1) = 'v1', Oku(be, 1));
    Ok('snapshot: silinen satir geri geldi', Oku(be, 2) = 'v2', Oku(be, 2));
    Ok('snapshot: yeni satir gorunmez', Oku(be, 9) = '<yok>', Oku(be, 9));
    Ok('snapshot: Exists silinen', be.Exists(2), BoolToStr(be.Exists(2), True));
    Ok('snapshot: Exists yeni', not be.Exists(9), BoolToStr(be.Exists(9), True));
    Ok('snapshot: Count degismedi', be.Count = 5, IntToStr(be.Count));

    be.ScanAll(keys, vals, 0);
    kume := '';
    for i := 0 to High(keys) do
      kume := kume + S(vals[i]) + ';';
    Ok('snapshot: tarama 5 satir', Length(keys) = 5, IntToStr(Length(keys)));
    Ok('snapshot: tarama eski degerler',
      (Pos('v1;', kume) > 0) and (Pos('v1-YENI', kume) = 0) and
      (Pos('v9', kume) = 0), kume);

    // --- kendi yazisini gormeli
    be.Put(3, B('v3-BENIM'));
    Ok('oturum1 kendi yazisini gorur', Oku(be, 3) = 'v3-BENIM', Oku(be, 3));
    Ok('oturum1 Count kendi eklemesiyle', be.Count = 5, IntToStr(be.Count));

    // --- commit sonrasi guncel veri
    be.CommitBatch;
    gSid := 0;
    Ok('commit sonrasi guncel deger', Oku(be, 1) = 'v1-YENI', Oku(be, 1));
    Ok('commit sonrasi silinen yok', Oku(be, 2) = '<yok>', Oku(be, 2));
    Ok('commit sonrasi yeni satir var', Oku(be, 9) = 'v9', Oku(be, 9));
    Ok('commit sonrasi kendi yazisi', Oku(be, 3) = 'v3-BENIM', Oku(be, 3));

    // --- yazma cakismasi hala yakalanir
    gSid := 1;
    be.BeginBatch;
    be.Put(1, B('A'));
    gSid := 2;
    be.BeginBatch;
    be.Put(1, B('B'));
    be.CommitBatch;
    gSid := 1;
    try
      be.CommitBatch;
      Ok('yazma cakismasi yakalandi', False, 'hata beklenirdi');
    except
      on E: Exception do
      begin
        Ok('yazma cakismasi yakalandi', Pos('cakisma', E.Message) > 0, E.Message);
        be.AbortBatch;    // cakisma sonrasi islem ACIK kalir (eski davranis)
      end;
    end;

    // --- tek oturumda okuma her seyi gorur (eski davranis korunur)
    gSid := 0;
    Ok('parti disi okuma guncel', Oku(be, 1) = 'B', Oku(be, 1));

    // --- ARADA BASLAYAN OKUYUCU: post zincirinde orta durum
    be.Put(20, B('a'));
    gSid := 1;                    // en eski okuyucu
    be.BeginBatch;
    gSid := 2;
    be.BeginBatch;
    be.Put(20, B('b'));
    be.CommitBatch;               // G1
    gSid := 3;                    // G1'den sonra baslayan okuyucu
    be.BeginBatch;
    gSid := 2;
    be.BeginBatch;
    be.Put(20, B('c'));
    be.CommitBatch;               // G2
    gSid := 1;
    Ok('zincir: en eski okuyucu ilk deger', Oku(be, 20) = 'a', Oku(be, 20));
    gSid := 3;
    Ok('zincir: ara okuyucu orta deger', Oku(be, 20) = 'b', Oku(be, 20));
    gSid := 0;
    Ok('zincir: guncel deger', Oku(be, 20) = 'c', Oku(be, 20));
    gSid := 1; be.CommitBatch;
    gSid := 3; be.CommitBatch;
    gSid := 0;
  finally
    be.Free;
    VdbSessionIdFunc := nil;
  end;

  WriteLn('---');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail > 0 then ExitCode := 1;
end.
