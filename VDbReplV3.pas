unit VDbReplV3;

{ VDB v4 - REPLIKASYON (mantiksal gunluk tasima / log shipping)

  MODEL
    Birincil (primary): her commit zaten <db>.log\ altina mantiksal bir
    grup yazar (anahtar + eski/yeni deger). PUMP REPLICATION, slot
    konumundan SONRAKI tam gruplari tasima dizinine TEK TEK dosya olarak
    birakir:  <dest>\<slot>\g-<seq:020d>.vrgp
    Ikincil (standby): ayni dizinden siradaki gruplari okur, CRC dogrular,
    TEK motor islemi olarak uygular ve kendi gunlugune YENIDEN
    numaralandirarak ekler. Konum slot dosyasindadir (uygulanan son seq).

  NEDEN BOYLE
    * Sayfa imaji degil MANTIKSAL kayit tasinir: iki dugumun sayfa
      geometrisi/WAL bicimi ayni olmak zorunda degil (surum gecisi kolay).
    * Grup = tek dosya: yarim kopya CRC + atomik yeniden adlandirma ile
      ayiklanir; kesik grup UYGULANMAZ (veri kaybi yok, tekrar denenir).
    * Uygulama IDEMPOTENT: degerler MUTLAK (eski -> yeni) oldugu icin ayni
      grup iki kez uygulansa da sonuc ayni. "commit basarili, konum
      guncellenmedi" durumunda tekrar uygulamak guvenlidir.
    * Grup uygulamasi tek motor islemidir; yarim grup sizmaz.

  ILK KURULUM
    Bir slotun ILK tasimasinda birincil, en yeni taban imajini da
    <dest>\<slot>\bases\ altina kopyalar ve ayni seq ile bir TABAN isareti
    birakir. Konumu 0 olan ikincil bu tabani RESTORE eder (kendi gunlugunde
    nesil kopmasi olusur: dogru davranis, cunku gecmisi birincilin gecmisi
    degildir) ve veri gruplariyla devam eder.

  SINIRLAR (durust)
    * Tasima bir DIZIN uzerindendir (yerel disk, ag paylasimi, rsync...).
      TCP akisi bu dilimde YOK.
    * Ikincil SALT OKUNUR degildir ve otomatik split-brain korumasi yoktur;
      orada yazma yapilmamalidir.
    * Nesil kopmasi (RESTORE) tasimayi REDDETTIRIR: slot yeniden
      kurulmalidir (sessiz sapma yerine acik hata).
    * Degisim gunlugu silinirse (kirpilmaz, ama operator silebilir) aradaki
      gruplar yoktur: PUMP bosluk gorunce DURUR, atlamaz.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, VDbBackendApi, VDbChangeLog, VDbCrc32, VDbSync;

const
  VDBREPL_DIR_SUFFIX = '.repl';
  VDBREPL_MAGIC      = LongWord($31475256);  // 'VRG1'
  VDBREPL_VER        = 1;
  VDBREPL_HDR        = 64;
  VDBREPL_BATCH      = 256;                  // tek PUMP'ta azami grup

type
  TVdbReplRole = (vrrNone, vrrPrimary, vrrStandby);

  TVdbReplSlotInfo = record
    Name: string;
    Dest: string;         // tasima dizini (birincil: hedef, ikincil: kaynak)
    Role: TVdbReplRole;
    LastSeq: Int64;       // tasinan (birincil) / uygulanan (ikincil) son seq
    LastTsMs: Int64;
    Shipped: Int64;       // birincil: tasinan grup sayisi (toplam)
    Applied: Int64;       // ikincil: uygulanan grup sayisi (toplam)
    UpdatedMs: Int64;
    LastMsg: string;
  end;

  TVdbReplSlotArray = array of TVdbReplSlotInfo;

{ <db>.repl dizini. }
function VdbReplSlotDir(const ADbPath: string): string;
function VdbReplCreate(ABe: IVdbBackend; const AName: string;
  out AMsg: string): Boolean;
function VdbReplDrop(ABe: IVdbBackend; const AName: string;
  out AMsg: string): Boolean;
function VdbReplList(ABe: IVdbBackend): TVdbReplSlotArray;
function VdbReplStart(ABe: IVdbBackend; AIsPrimary: Boolean;
  const AName, ADest: string; out AMsg: string): Boolean;
function VdbReplStop(ABe: IVdbBackend; out AMsg: string): Boolean;
{ Tek adim: birincilse grup tasir, ikincilse grup uygular.
  ABaseInstalled: bu adimda taban imaji RESTORE edildi (sema onbellegi
  gecersizdir; cagiran ReloadSchema yapmali). }
function VdbReplPump(ABe: IVdbBackend; out ACount: Int64;
  out ABaseInstalled: Boolean; out AMsg: string): Boolean;
function VdbReplStatus(ABe: IVdbBackend; out AInfo: TVdbReplSlotInfo): Boolean;

implementation

const
  VDBREPL_KIND_DATA = 0;
  VDBREPL_KIND_BASE = 1;

type
  TVdbReplHdr = record
    Seq: Int64;
    TsMs: Int64;
    Kind: LongWord;
    Flags: LongWord;
    Gen: LongWord;
    DataLen: LongWord;
    DataCrc: LongWord;
    NameLen: LongWord;
    BaseName: string;
  end;

{ ------------------------------------------------------------ yardimcilar }

procedure PutU32(var B: TBytes; Pos: Integer; V: LongWord);
begin
  Move(V, B[Pos], 4);
end;

function ReadU32(const B: TBytes; Pos: Integer): LongWord;
begin
  Move(B[Pos], Result, 4);
end;

procedure PutI64(var B: TBytes; Pos: Integer; V: Int64);
begin
  Move(V, B[Pos], 8);
end;

function ReadI64(const B: TBytes; Pos: Integer): Int64;
begin
  Move(B[Pos], Result, 8);
end;

function VdbReplSlotDir(const ADbPath: string): string;
begin
  Result := ADbPath + VDBREPL_DIR_SUFFIX;
end;

function SlotFileName(const AName: string): Boolean;
var
  i: Integer;
  c: Char;
begin
  Result := False;
  if (Length(AName) < 1) or (Length(AName) > 64) then Exit;
  for i := 1 to Length(AName) do
  begin
    c := AName[i];
    if not (c in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then Exit;
  end;
  Result := True;
end;

function SlotPathOf(ABe: IVdbBackend; const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(VdbReplSlotDir(ABe.FilePath)) +
    AName + '.slot';
end;

function RoleToStr(R: TVdbReplRole): string;
begin
  case R of
    vrrPrimary: Result := 'primary';
    vrrStandby: Result := 'standby';
  else
    Result := 'none';
  end;
end;

function StrToRole(const S: string): TVdbReplRole;
begin
  if S = 'primary' then Result := vrrPrimary
  else if S = 'standby' then Result := vrrStandby
  else Result := vrrNone;
end;

function LoadSlot(const APath: string; out S: TVdbReplSlotInfo): Boolean;
var
  L: TStringList;
  i, p: Integer;
  k, v: string;
begin
  S.Name := '';
  S.Dest := '';
  S.Role := vrrNone;
  S.LastSeq := 0;
  S.LastTsMs := 0;
  S.Shipped := 0;
  S.Applied := 0;
  S.UpdatedMs := 0;
  S.LastMsg := '';
  Result := False;
  if not FileExists(APath) then Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(APath);
    except
      Exit;
    end;
    for i := 0 to L.Count - 1 do
    begin
      p := Pos('=', L[i]);
      if p <= 1 then Continue;
      k := Copy(L[i], 1, p - 1);
      v := Copy(L[i], p + 1, Length(L[i]) - p);
      if k = 'name' then S.Name := v
      else if k = 'dest' then S.Dest := v
      else if k = 'role' then S.Role := StrToRole(v)
      else if k = 'last_seq' then S.LastSeq := StrToInt64Def(v, 0)
      else if k = 'last_ts' then S.LastTsMs := StrToInt64Def(v, 0)
      else if k = 'shipped' then S.Shipped := StrToInt64Def(v, 0)
      else if k = 'applied' then S.Applied := StrToInt64Def(v, 0)
      else if k = 'updated_ms' then S.UpdatedMs := StrToInt64Def(v, 0)
      else if k = 'last_msg' then S.LastMsg := v;
    end;
    Result := S.Name <> '';
  finally
    L.Free;
  end;
end;

function SaveSlot(const APath: string; const S: TVdbReplSlotInfo): Boolean;
var
  L: TStringList;
  tmp: string;
begin
  Result := False;
  ForceDirectories(ExtractFileDir(APath));
  L := TStringList.Create;
  try
    L.Add('vdb.repl.slot=1');
    L.Add('name=' + S.Name);
    L.Add('dest=' + S.Dest);
    L.Add('role=' + RoleToStr(S.Role));
    L.Add('last_seq=' + IntToStr(S.LastSeq));
    L.Add('last_ts=' + IntToStr(S.LastTsMs));
    L.Add('shipped=' + IntToStr(S.Shipped));
    L.Add('applied=' + IntToStr(S.Applied));
    L.Add('updated_ms=' + IntToStr(S.UpdatedMs));
    L.Add('last_msg=' + S.LastMsg);
    tmp := APath + '.tmp';
    try
      L.SaveToFile(tmp);
      if FileExists(APath) then DeleteFile(APath);
      Result := RenameFile(tmp, APath);
    except
      Result := False;
    end;
  finally
    L.Free;
  end;
end;

function CopyFileAtomic(const ASrc, ADst: string): Boolean;
var
  src, dst: TFileStream;
  tmp: string;
begin
  Result := False;
  tmp := ADst + '.tmp';
  if FileExists(tmp) then DeleteFile(tmp);
  src := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    dst := TFileStream.Create(tmp, fmCreate);
    try
      dst.CopyFrom(src, 0);
      VDbFlushStream(dst);
    finally
      dst.Free;
    end;
  finally
    src.Free;
  end;
  if FileExists(ADst) then DeleteFile(ADst);
  Result := RenameFile(tmp, ADst);
end;

{ --- tasima dosyasi ------------------------------------------------------ }

function GroupFileName(const ADir: string; ASeq: Int64): string;
begin
  Result := IncludeTrailingPathDelimiter(ADir) + 'g-' +
    Format('%.20d', [ASeq]) + '.vrgp';
end;

{ 'g-00000000000000000007.vrgp' -> 7; gecersizse -1. }
function FileNameSeq(const AName: string): Int64;
begin
  if (Length(AName) < 5) or (Copy(AName, 1, 2) <> 'g-') then
  begin
    Result := -1;
    Exit;
  end;
  Result := StrToInt64Def(Copy(AName, 3, Length(AName) - 7), -1);
end;

function WriteGroupFile(const ADir: string; ASeq, ATsMs: Int64;
  AKind, AFlags, AGen: LongWord; const ABaseName: string;
  const AData: TBytes): Boolean;
var
  hdr, buf: TBytes;
  nb: Integer;
  dst: TFileStream;
  tmp: string;
  crc: LongWord;
begin
  Result := False;
  nb := Length(ABaseName);
  SetLength(hdr, VDBREPL_HDR);
  FillChar(hdr[0], VDBREPL_HDR, 0);
  PutU32(hdr, 0, VDBREPL_MAGIC);
  PutU32(hdr, 4, VDBREPL_VER);
  PutI64(hdr, 8, ASeq);
  PutI64(hdr, 16, ATsMs);
  PutU32(hdr, 24, AKind);
  PutU32(hdr, 28, AFlags);
  PutU32(hdr, 32, AGen);
  PutU32(hdr, 36, LongWord(Length(AData)));
  if Length(AData) > 0 then
    crc := VDbCrc32OfBytes(AData, Length(AData))
  else
    crc := 0;
  PutU32(hdr, 40, crc);
  PutU32(hdr, 44, LongWord(nb));
  crc := VDbCrc32OfBytes(hdr, 48);
  PutU32(hdr, 48, crc);
  tmp := GroupFileName(ADir, ASeq) + '.tmp';
  if FileExists(tmp) then DeleteFile(tmp);
  try
    dst := TFileStream.Create(tmp, fmCreate);
    try
      dst.WriteBuffer(hdr[0], VDBREPL_HDR);
      if Length(AData) > 0 then
        dst.WriteBuffer(AData[0], Length(AData));
      if nb > 0 then
        dst.WriteBuffer(ABaseName[1], nb);
      VDbFlushStream(dst);
    finally
      dst.Free;
    end;
  except
    Exit;
  end;
  ForceDirectories(ADir);
  if FileExists(GroupFileName(ADir, ASeq)) then
    DeleteFile(GroupFileName(ADir, ASeq));
  Result := RenameFile(tmp, GroupFileName(ADir, ASeq));
end;

function ReadGroupFile(const APath: string; out H: TVdbReplHdr;
  out AData: TBytes; out AErr: string): Boolean;
var
  S: TFileStream;
  hdr: TBytes;
  crc: LongWord;
  nb, dl: Integer;
begin
  Result := False;
  AErr := '';
  AData := nil;
  FillChar(H, SizeOf(H), 0);
  H.BaseName := '';
  S := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if S.Size < VDBREPL_HDR then
    begin
      AErr := 'tasima dosyasi cok kisa: ' + ExtractFileName(APath);
      Exit;
    end;
    SetLength(hdr, VDBREPL_HDR);
    if S.Read(hdr[0], VDBREPL_HDR) <> VDBREPL_HDR then
    begin
      AErr := 'tasima dosyasi okunamadi';
      Exit;
    end;
    if ReadU32(hdr, 0) <> VDBREPL_MAGIC then
    begin
      AErr := 'tasima dosyasi bozuk (magic)';
      Exit;
    end;
    if ReadU32(hdr, 4) <> VDBREPL_VER then
    begin
      AErr := 'tasima dosyasi surumu desteklenmiyor';
      Exit;
    end;
    crc := VDbCrc32OfBytes(hdr, 48);
    if crc <> ReadU32(hdr, 48) then
    begin
      AErr := 'tasima dosyasi bozuk (baslik crc)';
      Exit;
    end;
    H.Seq := ReadI64(hdr, 8);
    H.TsMs := ReadI64(hdr, 16);
    H.Kind := ReadU32(hdr, 24);
    H.Flags := ReadU32(hdr, 28);
    H.Gen := ReadU32(hdr, 32);
    H.DataLen := ReadU32(hdr, 36);
    H.DataCrc := ReadU32(hdr, 40);
    H.NameLen := ReadU32(hdr, 44);
    dl := Integer(H.DataLen);
    nb := Integer(H.NameLen);
    if Int64(VDBREPL_HDR) + dl + nb > S.Size then
    begin
      AErr := 'tasima dosyasi kesik (govde)';
      Exit;
    end;
    if dl > 0 then
    begin
      SetLength(AData, dl);
      if S.Read(AData[0], dl) <> dl then
      begin
        AErr := 'tasima dosyasi kesik (govde)';
        Exit;
      end;
      if VDbCrc32OfBytes(AData, dl) <> H.DataCrc then
      begin
        AErr := 'tasima dosyasi bozuk (govde crc)';
        Exit;
      end;
    end;
    if nb > 0 then
    begin
      SetLength(H.BaseName, nb);
      if S.Read(H.BaseName[1], nb) <> nb then
      begin
        AErr := 'tasima dosyasi kesik (ad)';
        Exit;
      end;
    end;
    Result := True;
  finally
    S.Free;
  end;
end;

{ --- grup uygulama ------------------------------------------------------- }

function ApplyRawGroup(ABe: IVdbBackend; const AData: TBytes;
  out AErr: string): Boolean;
var
  ents: TVdbLogEntryArray;
  i: Integer;
begin
  AErr := '';
  Result := False;
  if not VdbLogDecodeGroup(AData, ents) then
  begin
    AErr := 'grup cozulemedi (kesik/bozuk)';
    Exit;
  end;
  ABe.BeginBatch;
  try
    for i := 0 to High(ents) do
    begin
      if ents[i].Kind = VDBLOG_KIND_PUT then
        ABe.Put(ents[i].Key, ents[i].NewVal)
      else if ents[i].Kind = VDBLOG_KIND_DEL then
        ABe.Delete(ents[i].Key)
      else
      begin
        AErr := Format('grupta bilinmeyen kayit turu: %d', [ents[i].Kind]);
        ABe.AbortBatch;
        Exit;
      end;
    end;
    ABe.CommitBatch;
    Result := True;
  except
    on E: Exception do
    begin
      AErr := 'uygulama hatasi: ' + E.Message;
      try
        ABe.AbortBatch;
      except
      end;
    end;
  end;
end;

{ --- birincil: tasima ---------------------------------------------------- }

function ShipOnce(ABe: IVdbBackend; var S: TVdbReplSlotInfo;
  out AErr: string): Int64;
var
  rd: TVdbLogReader;
  minS, maxS: Int64;
  groups: TVdbLogRawGroupArray;
  bases: TVdbLogBaseArray;
  g: TVdbLogRawGroup;
  b: TVdbLogBase;
  i: Integer;
  more: Boolean;
  dir, src: string;
begin
  Result := 0;
  AErr := '';
  if not ABe.ReplSupported then
  begin
    AErr := 'degisim gunlugu yok: ' + ABe.LogStatus;
    Exit;
  end;
  if S.Dest = '' then
  begin
    AErr := 'tasima dizini bos (START REPLICATION ... DEST)';
    Exit;
  end;
  rd := TVdbLogReader.Create(ABe.FilePath);
  try
    if not rd.SeqRange(minS, maxS) then
    begin
      AErr := 'gunluk bos (taban isareti yok)';
      Exit;
    end;
    dir := IncludeTrailingPathDelimiter(S.Dest) + S.Name;
    if not ForceDirectories(dir) then
    begin
      AErr := 'tasima dizini olusturulamadi: ' + dir;
      Exit;
    end;
    { Ilk tasima: taban imaji + isareti (ikincil kurulumu icin). }
    if S.Shipped = 0 then
    begin
      bases := rd.ListBases;
      if Length(bases) = 0 then
      begin
        AErr := 'taban imaji yok (gunluk yeni; BACKUP/VACUUM sonrasi tekrar denenebilir)';
        Exit;
      end;
      b := bases[High(bases)];
      if b.Seq > S.LastSeq then
      begin
        src := IncludeTrailingPathDelimiter(rd.Dir) + 'base' + PathDelim + b.Name;
        if not FileExists(src) then
        begin
          AErr := 'taban imaji bulunamadi: ' + src;
          Exit;
        end;
        ForceDirectories(IncludeTrailingPathDelimiter(dir) + 'bases');
        if not CopyFileAtomic(src, IncludeTrailingPathDelimiter(dir) +
          'bases' + PathDelim + b.Name) then
        begin
          AErr := 'taban imaji kopyalanamadi: ' + b.Name;
          Exit;
        end;
        if not WriteGroupFile(dir, b.Seq, b.TsMs, VDBREPL_KIND_BASE,
          b.Flags, b.Gen, b.Name, nil) then
        begin
          AErr := 'taban isareti yazilamadi';
          Exit;
        end;
        S.LastSeq := b.Seq;
        S.LastTsMs := b.TsMs;
        Inc(Result);
      end;
    end;
    { Veri gruplari + saf checkpoint isaretleri. }
    while S.LastSeq < maxS do
    begin
      if S.LastSeq + 1 < minS then
      begin
        AErr := Format('gunlukte bosluk: %d sonrasi gruplar yok (en eski %d); ' +
          'slot yeniden kurulmali', [S.LastSeq, minS]);
        Exit;
      end;
      groups := rd.ExtractGroups(S.LastSeq, VDBREPL_BATCH, more);
      if Length(groups) = 0 then Break;
      for i := 0 to High(groups) do
      begin
        g := groups[i];
        if g.Kind = VDBLOG_KIND_BASE then
        begin
          if (g.Flags and 1) <> 0 then
          begin
            AErr := 'nesil kopmasi (RESTORE) tasinamaz; slot yeniden kurulmali';
            Exit;
          end;
          { Saf checkpoint: veri degismedi, yalniz konum ilerler. }
          if not WriteGroupFile(dir, g.Seq, g.TsMs, VDBREPL_KIND_BASE,
            g.Flags, g.Gen, '', nil) then
          begin
            AErr := 'checkpoint isareti yazilamadi';
            Exit;
          end;
        end
        else
        begin
          if not WriteGroupFile(dir, g.Seq, g.TsMs, VDBREPL_KIND_DATA,
            0, 0, '', g.Data) then
          begin
            AErr := 'grup dosyasi yazilamadi (seq ' + IntToStr(g.Seq) + ')';
            Exit;
          end;
        end;
        S.LastSeq := g.Seq;
        S.LastTsMs := g.TsMs;
        Inc(Result);
        if Result >= VDBREPL_BATCH * 4 then Exit;
      end;
      if not more then Break;
    end;
  finally
    rd.Free;
  end;
end;

{ --- ikincil: uygulama --------------------------------------------------- }

function CollectGroupFiles(const ADir: string; AAfter: Int64;
  out AFirst: Int64): TStringList;
var
  sr: TSearchRec;
  nm: string;
  seq: Int64;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  AFirst := 0;
  if not DirectoryExists(ADir) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + 'g-*.vrgp',
    faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Attr and faDirectory) = 0 then
      begin
        nm := ExtractFileName(sr.Name);
        if Copy(nm, 1, 2) = 'g-' then
        begin
          seq := FileNameSeq(nm);
          if (seq > AAfter) then
          begin
            if (AFirst = 0) or (seq < AFirst) then AFirst := seq;
            Result.Add(nm);
          end;
        end;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function ApplyOnce(ABe: IVdbBackend; var S: TVdbReplSlotInfo;
  out ABaseInstalled: Boolean; out AErr: string): Int64;
var
  dir, nm, bp: string;
  files: TStringList;
  i: Integer;
  first, seq: Int64;
  H: TVdbReplHdr;
  data: TBytes;
  err: string;
  ok: Boolean;
begin
  Result := 0;
  AErr := '';
  ABaseInstalled := False;
  if not ABe.ReplSupported then
  begin
    AErr := 'degisim gunlugu yok: ' + ABe.LogStatus;
    Exit;
  end;
  if S.Dest = '' then
  begin
    AErr := 'tasima dizini bos (START REPLICATION ... DEST)';
    Exit;
  end;
  dir := IncludeTrailingPathDelimiter(S.Dest) + S.Name;
  files := CollectGroupFiles(dir, S.LastSeq, first);
  try
    if files.Count = 0 then Exit;
    if first <> S.LastSeq + 1 then
    begin
      AErr := Format('sirada bosluk: %d bekleniyor, ilk mevcut %d',
        [S.LastSeq + 1, first]);
      Exit;
    end;
    for i := 0 to files.Count - 1 do
    begin
      seq := FileNameSeq(files[i]);
      if seq <> S.LastSeq + 1 then
      begin
        { Bosluk: ATLAMA YOK. Onceki gruplar uygulandi, konum kaydedilecek;
          cagiran acik hata gorur. }
        AErr := Format('sirada bosluk: %d bekleniyor, ilk mevcut %d',
          [S.LastSeq + 1, seq]);
        Exit;
      end;
      nm := IncludeTrailingPathDelimiter(dir) + files[i];
      if not ReadGroupFile(nm, H, data, err) then
      begin
        AErr := err + ' (' + files[i] + ')';
        Exit;
      end;
      if H.Seq <> seq then
      begin
        AErr := 'tasima dosyasinda seq uyusmazligi: ' + files[i];
        Exit;
      end;
      if H.Kind = VDBREPL_KIND_BASE then
      begin
        { Konum 0 = hic kurulmamis ikincil: taban imajini RESTORE et.
          Aksi halde saf checkpoint isaretidir; veri zaten ayni. }
        if (H.Flags and 1) <> 0 then
        begin
          AErr := 'nesil kopmasi tasinmis; taban elle kurulmali (RESTORE)';
          Exit;
        end;
        if S.LastSeq = 0 then
        begin
          if H.BaseName = '' then
          begin
            AErr := 'taban isaretinde imaj adi yok';
            Exit;
          end;
          bp := IncludeTrailingPathDelimiter(dir) + 'bases' + PathDelim + H.BaseName;
          if not FileExists(bp) then
          begin
            AErr := 'taban imaji yok: ' + bp;
            Exit;
          end;
          try
            ABe.RestoreFrom(bp);
          except
            on E: Exception do
            begin
              AErr := 'taban kurulumu basarisiz: ' + E.Message;
              Exit;
            end;
          end;
          ABaseInstalled := True;
          S.LastMsg := 'taban kuruldu (seq ' + IntToStr(seq) + ')';
        end;
        S.LastSeq := seq;
        S.LastTsMs := H.TsMs;
        Inc(Result);
        Continue;
      end;
      { Veri grubu: tek islem + yeniden numaralandirilmis gunluk kaydi. }
      ABe.ReplSuspendLog(True);
      try
        ok := ApplyRawGroup(ABe, data, err);
        if ok then
          ok := ABe.ReplAppendGroup(data, err);
      finally
        ABe.ReplSuspendLog(False);
      end;
      if not ok then
      begin
        AErr := err;
        Exit;
      end;
      S.LastSeq := seq;
      S.LastTsMs := H.TsMs;
      Inc(Result);
      if Result >= VDBREPL_BATCH then Break;
    end;
  finally
    files.Free;
  end;
end;

{ --- genel --------------------------------------------------------------- }

function VdbReplCreate(ABe: IVdbBackend; const AName: string;
  out AMsg: string): Boolean;
var
  S: TVdbReplSlotInfo;
  p: string;
begin
  AMsg := '';
  if not SlotFileName(AName) then
  begin
    AMsg := 'slot adi gecersiz (1-64 karakter: A-Z, 0-9, _, -)';
    Exit(False);
  end;
  p := SlotPathOf(ABe, AName);
  if FileExists(p) then
  begin
    AMsg := 'slot zaten var: ' + AName;
    Exit(True);
  end;
  S.Name := AName;
  S.Dest := '';
  S.Role := vrrNone;
  S.LastSeq := 0;
  S.LastTsMs := 0;
  S.Shipped := 0;
  S.Applied := 0;
  S.UpdatedMs := VdbLogNowMs;
  S.LastMsg := 'olusturuldu';
  if not SaveSlot(p, S) then
  begin
    AMsg := 'slot dosyasi yazilamadi: ' + p;
    Exit(False);
  end;
  AMsg := 'slot olusturuldu: ' + AName;
  Result := True;
end;

function VdbReplDrop(ABe: IVdbBackend; const AName: string;
  out AMsg: string): Boolean;
var
  p: string;
  S: TVdbReplSlotInfo;
begin
  AMsg := '';
  if not SlotFileName(AName) then
  begin
    AMsg := 'slot adi gecersiz: ' + AName;
    Exit(False);
  end;
  p := SlotPathOf(ABe, AName);
  if not FileExists(p) then
  begin
    AMsg := 'slot yok: ' + AName;
    Exit(False);
  end;
  if LoadSlot(p, S) and (S.Role <> vrrNone) then
  begin
    AMsg := 'slot etkin, once STOP REPLICATION: ' + AName;
    Exit(False);
  end;
  if not DeleteFile(p) then
  begin
    AMsg := 'slot silinemedi: ' + p;
    Exit(False);
  end;
  AMsg := 'slot silindi: ' + AName;
  Result := True;
end;

function VdbReplList(ABe: IVdbBackend): TVdbReplSlotArray;
var
  sr: TSearchRec;
  dir, p: string;
  S: TVdbReplSlotInfo;
  n: Integer;
begin
  Result := nil;
  n := 0;
  dir := VdbReplSlotDir(ABe.FilePath);
  if not DirectoryExists(dir) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(dir) + '*.slot', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Attr and faDirectory) <> 0 then Continue;
      p := IncludeTrailingPathDelimiter(dir) + sr.Name;
      if not LoadSlot(p, S) then Continue;
      SetLength(Result, n + 1);
      Result[n] := S;
      Inc(n);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function FindSlot(ABe: IVdbBackend; const AName: string;
  out S: TVdbReplSlotInfo; out APath: string): Boolean;
begin
  APath := SlotPathOf(ABe, AName);
  Result := LoadSlot(APath, S);
end;

function ActiveSlot(ABe: IVdbBackend; out S: TVdbReplSlotInfo;
  out APath: string; out AMsg: string): Boolean;
var
  arr: TVdbReplSlotArray;
  i, n: Integer;
begin
  Result := False;
  AMsg := '';
  arr := VdbReplList(ABe);
  n := 0;
  for i := 0 to High(arr) do
    if arr[i].Role <> vrrNone then
    begin
      Inc(n);
      S := arr[i];
    end;
  if n = 0 then
  begin
    AMsg := 'etkin replikasyon slotu yok (START REPLICATION gerekli)';
    Exit;
  end;
  if n > 1 then
  begin
    AMsg := Format('%d etkin slot var; tek slot birakilmali (STOP REPLICATION)', [n]);
    Exit;
  end;
  APath := SlotPathOf(ABe, S.Name);
  Result := True;
end;

function VdbReplStart(ABe: IVdbBackend; AIsPrimary: Boolean;
  const AName, ADest: string; out AMsg: string): Boolean;
var
  S: TVdbReplSlotInfo;
  p, other: string;
  arr: TVdbReplSlotArray;
  i: Integer;
begin
  AMsg := '';
  if not ABe.ReplSupported then
  begin
    AMsg := 'REPLICATION: degisim gunlugu yok: ' + ABe.LogStatus;
    Exit(False);
  end;
  if not SlotFileName(AName) then
  begin
    AMsg := 'slot adi gecersiz: ' + AName;
    Exit(False);
  end;
  if ADest = '' then
  begin
    AMsg := 'tasima dizini bos';
    Exit(False);
  end;
  { Baska etkin slot kalmasin: iki rol ayni anda kosmaz. }
  arr := VdbReplList(ABe);
  for i := 0 to High(arr) do
    if (arr[i].Role <> vrrNone) and (arr[i].Name <> AName) then
    begin
      AMsg := 'baska etkin slot var: ' + arr[i].Name;
      Exit(False);
    end;
  if not FindSlot(ABe, AName, S, p) then
  begin
    if not VdbReplCreate(ABe, AName, other) then
    begin
      AMsg := other;
      Exit(False);
    end;
    if not FindSlot(ABe, AName, S, p) then
    begin
      AMsg := 'slot dosyasi okunamadi: ' + p;
      Exit(False);
    end;
  end;
  S.Dest := ADest;
  if AIsPrimary then S.Role := vrrPrimary else S.Role := vrrStandby;
  S.UpdatedMs := VdbLogNowMs;
  S.LastMsg := 'baslatildi';
  if not SaveSlot(p, S) then
  begin
    AMsg := 'slot dosyasi yazilamadi: ' + p;
    Exit(False);
  end;
  if AIsPrimary then
    AMsg := Format('PRIMARY replikasyon basladi (slot: %s, dest: %s, konum: %d)',
      [AName, ADest, S.LastSeq])
  else
    AMsg := Format('STANDBY replikasyon basladi (slot: %s, kaynak: %s, konum: %d)',
      [AName, ADest, S.LastSeq]);
  Result := True;
end;

function VdbReplStop(ABe: IVdbBackend; out AMsg: string): Boolean;
var
  S: TVdbReplSlotInfo;
  p: string;
begin
  AMsg := '';
  if not ActiveSlot(ABe, S, p, AMsg) then
  begin
    AMsg := 'STOP: ' + AMsg;
    Exit(False);
  end;
  S.Role := vrrNone;
  S.UpdatedMs := VdbLogNowMs;
  S.LastMsg := 'durduruldu';
  if not SaveSlot(p, S) then
  begin
    AMsg := 'slot dosyasi yazilamadi: ' + p;
    Exit(False);
  end;
  AMsg := 'replikasyon durduruldu (slot: ' + S.Name + ', konum: ' +
    IntToStr(S.LastSeq) + ')';
  Result := True;
end;

function VdbReplPump(ABe: IVdbBackend; out ACount: Int64;
  out ABaseInstalled: Boolean; out AMsg: string): Boolean;
var
  S: TVdbReplSlotInfo;
  p, err: string;
  n: Int64;
begin
  ACount := 0;
  ABaseInstalled := False;
  AMsg := '';
  if not ABe.ReplSupported then
  begin
    AMsg := 'REPLICATION: degisim gunlugu yok: ' + ABe.LogStatus;
    Exit(False);
  end;
  if not ActiveSlot(ABe, S, p, AMsg) then Exit(False);
  if S.Role = vrrPrimary then
    n := ShipOnce(ABe, S, err)
  else
    n := ApplyOnce(ABe, S, ABaseInstalled, err);
  ACount := n;
  if S.Role = vrrPrimary then
    Inc(S.Shipped, n)
  else
    Inc(S.Applied, n);
  S.UpdatedMs := VdbLogNowMs;
  if err <> '' then
    S.LastMsg := err
  else if n > 0 then
    S.LastMsg := Format('%d grup islendi (konum %d)', [n, S.LastSeq])
  else
    S.LastMsg := 'yeni grup yok';
  SaveSlot(p, S);
  if err <> '' then
  begin
    AMsg := err;
    Exit(False);
  end;
  if S.Role = vrrPrimary then
    AMsg := Format('PUMP: %d grup tasindi (slot: %s, konum: %d)',
      [n, S.Name, S.LastSeq])
  else
    AMsg := Format('PUMP: %d grup uygulandi (slot: %s, konum: %d)',
      [n, S.Name, S.LastSeq]);
  Result := True;
end;

function VdbReplStatus(ABe: IVdbBackend; out AInfo: TVdbReplSlotInfo): Boolean;
var
  p, msg: string;
begin
  AInfo.Name := '';
  AInfo.Dest := '';
  AInfo.Role := vrrNone;
  AInfo.LastSeq := 0;
  AInfo.LastTsMs := 0;
  AInfo.Shipped := 0;
  AInfo.Applied := 0;
  AInfo.UpdatedMs := 0;
  AInfo.LastMsg := '';
  Result := ActiveSlot(ABe, AInfo, p, msg);
end;

end.
