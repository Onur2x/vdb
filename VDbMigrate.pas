unit VDbMigrate;

{ VDB v3 - v2 -> v3 veri gocu (Sprint 2 / 2.8)

  TASARIM: goc SATIR DEGERI duzeyinde DEGIL, KV kaydi duzeyindedir.
  v3 sayfa motoru, v2'nin anahtar-deger uzayini birebir tasir (ayni
  anahtar, ayni deger baytlari; satir kodlamasi SQL katmaninda). Bu yuzden
  goc = sema kaydi (anahtar 0) + tum satir/dizin kayitlarinin kopyasi.
  SQL ayristirma, yeniden kodlama, varsayilan uretimi YOKTUR; boylece
  degerler birebir korunur ve goc dogrudan dogrulanabilir.

  Kaynak herhangi bir IVDbBackend'dir: tipik olarak bir v2 veritabanina
  bagli TVDbBackendV2. Hedef her zaman v3 sayfa dosyasidir.

  DOGRULAMA (`VdbMigrateVerify`): anahtar sayisi esitligi + her kaynak
  anahtarinin hedefte BAYT BAYT ayni degerle bulunmasi. Sayilar esit ve
  tum kaynak anahtarlari bulundugunda kume esitligi de kanitlanir.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, VDbBackendApi;

type
  TVdbMigrateReport = record
    Keys: Int64;        // kopyalanan KV kaydi (sema + satirlar + dizinler)
    Bytes: Int64;       // toplam deger bayti
    Ms: Integer;        // gecen sure
    Mismatch: Int64;    // dogrulamada farkli/eksik kayit sayisi
    FirstBad: QWord;    // ilk farkli anahtar (Mismatch > 0 ise)
    HasFirstBad: Boolean;
  end;

{ Kaynagi hedefe kopyalar. Hedef dosya VARSA hata doner (uzerine yazmaz).
  `.colkey` (kolon anahtari) dosyasi varsa o da kopyalanir. }
function VdbMigrateToV3(const Src: IVDbBackend; const DestPath: string;
  Pool: Integer; out Rep: TVdbMigrateReport; out Err: string): Boolean;

{ Hedefi acip kaynakla karsilastirir. Hata yoksa True; fark varsa False ve
  Err'de ozet (ilk farkli anahtar dahil). }
function VdbMigrateVerify(const Src: IVDbBackend; const DestPath: string;
  Pool: Integer; out Rep: TVdbMigrateReport; out Err: string): Boolean;

implementation

uses
  VDbBackendV3;

const
  { Tek partide kopyalanan kayit sayisi: WAL tamponu sinirli kalsin. }
  MIGRATE_CHUNK = 20000;

type
  { Kopyalama geri cagrisi: her kaydi hedefe yazar, partiyi doldurunca
    commit eder. Geri cagri sifir-kopya tampon alir (yalniz cagri boyunca
    gecerli), bu yuzden deger hemen kopyalanir (Put zaten kopyalar). }
  TMigrateSink = class
  public
    Dest: IVDbBackend;
    Keys: Int64;
    Bytes: Int64;
    InChunk: Integer;
    procedure Start;
    procedure Finish;
  end;

procedure TMigrateSink.Start;
begin
  Keys := 0;
  Bytes := 0;
  InChunk := 0;
  Dest.BeginBatch;
end;

procedure TMigrateSink.Finish;
begin
  if InChunk > 0 then
    Dest.CommitBatch;
  InChunk := 0;
end;

function MigrateRec(Key: QWord; Buf: PByte; Len: Integer;
  User: Pointer): Boolean; register;
var
  sink: TMigrateSink;
  v: TBytes;
begin
  sink := TMigrateSink(User);
  Result := True;
  SetLength(v, Len);
  if Len > 0 then
    Move(Buf^, v[0], Len);
  sink.Dest.Put(Key, v);
  Inc(sink.Keys);
  Inc(sink.Bytes, Len);
  Inc(sink.InChunk);
  if sink.InChunk >= MIGRATE_CHUNK then
  begin
    sink.Dest.CommitBatch;
    sink.Dest.BeginBatch;
    sink.InChunk := 0;
  end;
end;

{ Yarim kalan goc dosyalarini siler (hata yolunda cagrilir). }
procedure DeleteArtifacts(const DestPath: string);
begin
  if FileExists(DestPath) then
    DeleteFile(DestPath);
  if FileExists(DestPath + '.idx') then
    DeleteFile(DestPath + '.idx');
  if FileExists(DestPath + '.wal') then
    DeleteFile(DestPath + '.wal');
  if FileExists(ChangeFileExt(DestPath, '.colkey')) then
    DeleteFile(ChangeFileExt(DestPath, '.colkey'));
end;

function CopyColKey(const Src, DestPath: string; out Err: string): Boolean;
var
  srcKey, dstKey: string;
  f: TFileStream;
  buf: array[0..4095] of Byte;
  n: Integer;
begin
  Result := True;
  Err := '';
  srcKey := Src;
  dstKey := ChangeFileExt(DestPath, '.colkey');
  if (srcKey = '') or (not FileExists(srcKey)) then Exit;
  if SameText(ExpandFileName(srcKey), ExpandFileName(dstKey)) then Exit;
  try
    f := TFileStream.Create(dstKey, fmCreate);
    try
      with TFileStream.Create(srcKey, fmOpenRead or fmShareDenyNone) do
      try
        repeat
          n := Read(buf, SizeOf(buf));
          if n > 0 then f.WriteBuffer(buf, n);
        until n <= 0;
      finally
        Free;
      end;
    finally
      f.Free;
    end;
  except
    on E: Exception do
    begin
      Result := False;
      Err := 'kolon anahtar dosyasi kopyalanamadi: ' + E.Message;
    end;
  end;
end;

function VdbMigrateToV3(const Src: IVDbBackend; const DestPath: string;
  Pool: Integer; out Rep: TVdbMigrateReport; out Err: string): Boolean;
var
  dest: IVdbBackend;
  sink: TMigrateSink;
  ms: QWord;
  srcKeys: Int64;
begin
  FillChar(Rep, SizeOf(Rep), 0);
  Err := '';
  Result := False;
  if Src = nil then
  begin
    Err := 'kaynak backend nil';
    Exit;
  end;
  if Trim(DestPath) = '' then
  begin
    Err := 'hedef yol bos';
    Exit;
  end;
  if FileExists(DestPath) then
  begin
    Err := 'hedef dosya zaten var: ' + DestPath;
    Exit;
  end;
  ms := GetTickCount64;
  srcKeys := Src.Count;

  sink := TMigrateSink.Create;
  try
    dest := TVdbBackendV3.Create(DestPath, True, Pool);
    sink.Dest := dest;
    try
      sink.Start;
      try
        { -1: satir filtresi yok -> sema, satirlar ve dizin kayitlari. }
        if not Src.ScanRawIterAll(-1, @MigrateRec, sink) then
          raise Exception.Create('kaynak tarama erken durdu');
      finally
        sink.Finish;
      end;
      dest.Flush;                 // checkpoint + .idx
      Rep.Keys := sink.Keys;
      Rep.Bytes := sink.Bytes;
    finally
      dest := nil;
    end;

    if Rep.Keys <> srcKeys then
    begin
      Err := Format('kopyalanan kayit sayisi tutmadi (kaynak=%d, hedef=%d)',
        [srcKeys, Rep.Keys]);
      DeleteArtifacts(DestPath);   // yarim dosya birakma
      Exit;
    end;

    if not CopyColKey(Src.ColumnKeyPath, DestPath, Err) then
    begin
      DeleteArtifacts(DestPath);
      Exit;
    end;

    Rep.Ms := Integer(GetTickCount64 - ms);
    Result := True;
  except
    on E: Exception do
    begin
      Err := 'goc hatasi: ' + E.Message;
      Rep.Keys := 0;
      DeleteArtifacts(DestPath);
    end;
  end;
  sink.Free;
end;

function VdbMigrateVerify(const Src: IVDbBackend; const DestPath: string;
  Pool: Integer; out Rep: TVdbMigrateReport; out Err: string): Boolean;
var
  dest: IVdbBackend;
  keys: TQWordArray;
  vals: TValArray;
  i: Integer;
  v: TBytes;
  ms: QWord;
  srcCount, dstCount: Int64;
begin
  FillChar(Rep, SizeOf(Rep), 0);
  Err := '';
  Result := False;
  if Src = nil then
  begin
    Err := 'kaynak backend nil';
    Exit;
  end;
  if not FileExists(DestPath) then
  begin
    Err := 'hedef dosya yok: ' + DestPath;
    Exit;
  end;
  ms := GetTickCount64;

  { Kaynak belleğe alinir: dogrulama tek gecisli olmali ve her anahtar
    icin hedefe nokta okuma yapilir. 200k satir ~ 10 MB. }
  Src.ScanAll(keys, vals, -1);
  srcCount := Length(keys);
  Rep.Keys := srcCount;
  for i := 0 to High(vals) do
    Inc(Rep.Bytes, Length(vals[i]));

  dest := TVdbBackendV3.Create(DestPath, False, Pool);
  try
    dstCount := dest.Count;
    if dstCount <> srcCount then
    begin
      Err := Format('kayit sayisi farkli (kaynak=%d, hedef=%d)',
        [srcCount, dstCount]);
      Exit;
    end;
    for i := 0 to High(keys) do
    begin
      if (not dest.Get(keys[i], v)) or (Length(v) <> Length(vals[i])) or
         ((Length(v) > 0) and (not CompareMem(@v[0], @vals[i][0], Length(v)))) then
      begin
        Inc(Rep.Mismatch);
        if not Rep.HasFirstBad then
        begin
          Rep.FirstBad := keys[i];
          Rep.HasFirstBad := True;
        end;
      end;
    end;
  finally
    dest := nil;
  end;

  Rep.Ms := Integer(GetTickCount64 - ms);
  if Rep.Mismatch > 0 then
  begin
    Err := Format('%d kayit farkli/eksik (ilk anahtar=$%.16x)',
      [Rep.Mismatch, Rep.FirstBad]);
    Exit;
  end;
  Result := True;
end;

end.
