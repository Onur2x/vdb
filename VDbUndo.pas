unit VDbUndo;

{ H11.1: yerinde (in-place) yazim icin undo gunlugu.

  Amac: ileride bir kaydi eski bir offset'te yerinde guncellerken, yarim
  kalan yazimi crash sonrasi geri alabilmek. Her yerinde yazimdan ONCE
  eski span baytlari bu dosyaya yazilir ve fsync edilir. Transaction
  commit edilince bir commit isareti eklenir; acilista commit isareti
  yoksa eski baytlar geri yuklenir.

  Bu birim tek basina test edilebilir; TVDb entegrasyonu VDbCore.Open
  icinde yapilir. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils;

const
  VDB_UNDO_MAGIC        = $4F444E55;  // 'UNDO' little-endian
  VDB_UNDO_COMMIT_MAGIC = $544D4D43;  // 'CMMT' little-endian
  { H11: islem basindaki dosya boyu. Yerinde yazimla ayni transaction'da
    append edilen kayitlar crash sonrasi geri alinirken dosya bu boya
    kirpilir; aksi halde BATCHEND kalir ve yarim transaction gorunur. }
  VDB_UNDO_TRUNC_MAGIC  = $4E525254;  // 'TRNR' little-endian
  // Bozuk/art niyetli bir basliktan dolayi devasa bellek ayirmayi engelle.
  VDB_UNDO_MAX_SPAN     = 32 * 1024 * 1024;

type
  TVDbUndoHead = packed record
    Magic: LongWord;
    Offset: Int64;
    Size: LongWord;
    Crc: LongWord;
  end;

function VDbUndoPath(const DbPath: string): string;
// Eski span'i gunluge ekler. Ayni offset icin birden fazla kayit olabilir;
// geri yukleme TERS sirada yapilir.
//
// 2026-10-22 HIZ: gunluk dosyasi artik HER kayit icin yeniden acilip
// kapatilmaz; ayni yol icin tek bir handle onbellekte tutulur ve fsync
// cagiranin istedigi anda (VDbUndoSync / VDbUndoCommit) yapilir.
// ONEMLI: fsync, ana dosyaya yerinde yazmadan ONCE cagrilmalidir; aksi
// halde crash'te geri alinamayan yarim span kalabilir. TVDb bunu
// CommitBatch icinde toplu (tek fsync) olarak saglar.
function VDbUndoAppend(const DbPath: string; AOffset: Int64;
  const OldData: TBytes): Boolean;
// Onbellekteki gunluk handle'ini fsync eder (yoksa no-op True).
// Cagiran, ana dosyayi degistirmeden ONCE bunu cagirmalidir.
function VDbUndoSync(const DbPath: string): Boolean;
// Onbellekteki gunluk handle'ini kapatir. Dosyayi silmez.
procedure VDbUndoCacheClose;
// Db'deki [AOffset, AOffset+ASize) araliginin ESKI baytlarini gunluge
// ekler. Cagiran, ana dosyayi degistirmeden ONCE bunu cagirmalidir.
function VDbUndoAppendFromStream(Db: TFileStream; const DbPath: string;
  AOffset: Int64; ASize: Int64): Boolean;
// Islem basindaki dosya boyunu gunluge isaretler. Yerinde yazimla ayni
// transaction'da append edilen kayitlar varsa, commit edilmemis gunluk
// geri alinirken dosya bu boya kirpilir.
function VDbUndoTruncateMarker(const DbPath: string; AOldSize: Int64): Boolean;
// Commit isareti ekler ve fsync eder. Undo dosyasi yoksa no-op True.
function VDbUndoCommit(const DbPath: string): Boolean;
// Acilista cagrilir. Commit isareti varsa dosyayi siler (veri zaten
// kalici). Yoksa kayitlari ters sirada Db'ye geri yazar. Basarisizlikta
// False doner; cagiran taraf acmayi reddetmelidir.
function VDbUndoRollback(Db: TFileStream; const UndoPath: string;
  out Restored: Integer): Boolean;
procedure VDbUndoDelete(const UndoPath: string);

implementation

uses
  VDbCrc32, VDbSync;

function VDbUndoPath(const DbPath: string): string;
begin
  Result := DbPath + '.undo';
end;

function OpenUndoRetry(const Path: string; Mode: Word): TFileStream;
var
  i: Integer;
begin
  Result := nil;
  for i := 1 to 50 do
  begin
    try
      Result := TFileStream.Create(Path, Mode or fmShareDenyNone);
      Exit;
    except
      if i = 50 then raise;
      TThread.Sleep(10);
    end;
  end;
end;

function OpenUndoForAppend(const Path: string): TFileStream;
begin
  if FileExists(Path) then
    Result := OpenUndoRetry(Path, fmOpenReadWrite)
  else
    Result := OpenUndoRetry(Path, fmCreate);
end;

{ 2026-10-22 HIZ: undo gunlugu handle onbellegi.
  Olcum (120 kayitlik batch): her kayit icin dosyayi ac/kapat 750 ms,
  tek handle ile 0 ms. Filtre suruculeri/AV, var olan bir dosyayi
  fmOpenReadWrite ile her acista taradigi icin maliyet kayit basina
  ~6 ms'ye cikiyordu.
  Kilit: TVDb yazma yollari FLock altinda calisir; bu onbellek de
  yalnizca oradan kullanilir. Farkli bir yol istenirse eski handle
  kapatilir (tek veritabani dosyasi kullanan uygulamalarda no-op). }
var
  GUndo: TFileStream = nil;
  GUndoPath: string = '';

procedure VDbUndoCacheClose;
begin
  if GUndo <> nil then
  begin
    FreeAndNil(GUndo);
  end;
  GUndoPath := '';
end;

function UndoStream(const Path: string): TFileStream;
begin
  if (GUndo <> nil) and (GUndoPath = Path) then Exit(GUndo);
  VDbUndoCacheClose;
  GUndo := OpenUndoForAppend(Path);
  GUndoPath := Path;
  Result := GUndo;
end;

function VDbUndoSync(const DbPath: string): Boolean;
begin
  Result := True;
  if (GUndo <> nil) and (GUndoPath = VDbUndoPath(DbPath)) then
  begin
    try
      VDbFlushStream(GUndo);
    except
      Result := False;
    end;
  end;
end;

function AppendHeadAndData(const Path: string; const H: TVDbUndoHead;
  const Data: TBytes): Boolean;
var
  s: TFileStream;
begin
  Result := False;
  s := UndoStream(Path);
  s.Seek(0, soEnd);
  s.WriteBuffer(H, SizeOf(H));
  if H.Size > 0 then
    s.WriteBuffer(Data[0], H.Size);
  { fsync YOK: cagiran VDbUndoSync ile toplu yapar. }
  Result := True;
end;

function VDbUndoAppend(const DbPath: string; AOffset: Int64;
  const OldData: TBytes): Boolean;
var
  h: TVDbUndoHead;
begin
  if Length(OldData) > VDB_UNDO_MAX_SPAN then
    Exit(False);
  h.Magic := VDB_UNDO_MAGIC;
  h.Offset := AOffset;
  h.Size := LongWord(Length(OldData));
  if h.Size > 0 then
    h.Crc := VDbCrc32Of(OldData[0], h.Size)
  else
    h.Crc := 0;
  Result := AppendHeadAndData(VDbUndoPath(DbPath), h, OldData);
end;

function VDbUndoAppendFromStream(Db: TFileStream; const DbPath: string;
  AOffset: Int64; ASize: Int64): Boolean;
var
  data: TBytes;
begin
  Result := False;
  if (Db = nil) or (AOffset < 0) or (ASize < 0) or
     (ASize > VDB_UNDO_MAX_SPAN) or (AOffset + ASize > Db.Size) then
    Exit;
  SetLength(data, ASize);
  if ASize > 0 then
  begin
    Db.Position := AOffset;
    Db.ReadBuffer(data[0], Integer(ASize));
  end;
  Result := VDbUndoAppend(DbPath, AOffset, data);
end;

function VDbUndoTruncateMarker(const DbPath: string; AOldSize: Int64): Boolean;
var
  h: TVDbUndoHead;
  s: TFileStream;
begin
  Result := False;
  if AOldSize < 0 then Exit;
  h.Magic := VDB_UNDO_TRUNC_MAGIC;
  h.Offset := AOldSize;
  h.Size := 0;
  h.Crc := 0;
  s := UndoStream(VDbUndoPath(DbPath));
  s.Seek(0, soEnd);
  s.WriteBuffer(h, SizeOf(h));
  { Isaret ana dosya yazimindan ONCE kalici olmali: hemen fsync. }
  VDbFlushStream(s);
  Result := True;
end;

function VDbUndoCommit(const DbPath: string): Boolean;
var
  h: TVDbUndoHead;
  Path: string;
  s: TFileStream;
  sahip: Boolean;
begin
  Path := VDbUndoPath(DbPath);
  if not FileExists(Path) then Exit(True);
  h.Magic := VDB_UNDO_COMMIT_MAGIC;
  h.Offset := 0;
  h.Size := 0;
  h.Crc := 0;
  Result := False;
  if (GUndo <> nil) and (GUndoPath = Path) then
  begin
    s := GUndo;
    sahip := False;
  end
  else
  begin
    s := OpenUndoRetry(Path, fmOpenReadWrite);
    sahip := True;
  end;
  try
    s.Seek(0, soEnd);
    s.WriteBuffer(h, SizeOf(h));
    VDbFlushStream(s);
    Result := True;
  finally
    if sahip then s.Free;
  end;
end;

procedure VDbUndoDelete(const UndoPath: string);
var
  s: TFileStream;
begin
  if UndoPath = '' then Exit;
  { Onbellekteki handle acikken dosya silinemez/truncate edilemez. }
  VDbUndoCacheClose;
  // Once truncate et: DeleteFile basarisiz olsa bile dosya bos kalir ve
  // bir sonraki acilista yanlislikla eski veriyi geri yuklemez.
  try
    if FileExists(UndoPath) then
    begin
      s := OpenUndoRetry(UndoPath, fmCreate);
      s.Free;
    end;
  except
  end;
  try
    if FileExists(UndoPath) then DeleteFile(UndoPath);
  except
  end;
end;

function VDbUndoRollback(Db: TFileStream; const UndoPath: string;
  out Restored: Integer): Boolean;
var
  s: TFileStream;
  h: TVDbUndoHead;
  positions: TList;
  undoSize, pos: Int64;
  i: Integer;
  data: TBytes;
  committed: Boolean;
  truncSize: Int64;
begin
  Result := True;
  Restored := 0;
  if (Db = nil) or (UndoPath = '') or (not FileExists(UndoPath)) then Exit;

  { Onbellekteki yazma handle'i acikken okuma/temizlik yapilamaz. }
  VDbUndoCacheClose;
  s := OpenUndoRetry(UndoPath, fmOpenRead);
  positions := TList.Create;
  try
    undoSize := s.Size;
    pos := 0;
    committed := False;
    truncSize := -1;
    while pos + Int64(SizeOf(h)) <= undoSize do
    begin
      s.Position := pos;
      if s.Read(h, SizeOf(h)) <> SizeOf(h) then Break;
      if h.Magic = VDB_UNDO_COMMIT_MAGIC then
      begin
        committed := True;
        Break;
      end;
      if h.Magic = VDB_UNDO_TRUNC_MAGIC then
      begin
        if (h.Size <> 0) or (h.Offset < 0) then Break;
        if (truncSize < 0) or (h.Offset < truncSize) then
          truncSize := h.Offset;
        pos := pos + Int64(SizeOf(h));
        Continue;
      end;
      if h.Magic <> VDB_UNDO_MAGIC then Break;
      if h.Size > VDB_UNDO_MAX_SPAN then Break;
      if pos + Int64(SizeOf(h)) + Int64(h.Size) > undoSize then Break;
      positions.Add(Pointer(PtrUInt(pos)));
      pos := pos + Int64(SizeOf(h)) + Int64(h.Size);
    end;

    if committed then
    begin
      // Commit tamamlanmis: eski baytlari geri yazma. Dosya, okuma
      // tanitici kapandiktan SONRA silinir (Windows paylasim kilidi).
    end
    else
    begin
      // Ters sira: ayni offset birden fazla kez degistiyse en eski haline don.
      for i := positions.Count - 1 downto 0 do
      begin
        pos := Int64(PtrUInt(positions[i]));
        s.Position := pos;
        if s.Read(h, SizeOf(h)) <> SizeOf(h) then
        begin
          Result := False;
          Exit;
        end;
        if h.Magic <> VDB_UNDO_MAGIC then
        begin
          Result := False;
          Exit;
        end;
        SetLength(data, h.Size);
        if h.Size > 0 then
        begin
          if s.Read(data[0], h.Size) <> Integer(h.Size) then
          begin
            Result := False;
            Exit;
          end;
          if VDbCrc32Of(data[0], h.Size) <> h.Crc then
          begin
            Result := False;
            Exit;
          end;
        end
        else if h.Crc <> 0 then
        begin
          Result := False;
          Exit;
        end;
        if h.Offset < 0 then
        begin
          Result := False;
          Exit;
        end;
        if Db.Size < h.Offset + Int64(h.Size) then
          Db.Size := h.Offset + Int64(h.Size);
        Db.Position := h.Offset;
        if h.Size > 0 then
          Db.WriteBuffer(data[0], h.Size);
        Inc(Restored);
      end;
      { Islem basinda append edilmis kayitlar varsa (yerinde + append ayni
        transaction'da), commit edilmemis gunluk geri alinirken bunlari da
        at: dosya islem basindaki boya kirpilir. }
      if (truncSize >= 0) and (Db.Size > truncSize) then
        Db.Size := truncSize;
      VDbFlushStream(Db);
    end;
  finally
    s.Free;
    positions.Free;
  end;

  // Geri yukleme basarili veya commit isareti var: gunlugu temizle.
  VDbUndoDelete(UndoPath);
end;

end.
