unit VDbIdxFile;

{ VDB v3 - Kalici anahtar dizini (.odb.idx)  (Sprint 1 / 1.10-1.11)

  Heap dizini bellekte acik adresleme tablosudur ve acilista tum heap
  sayfalari taranarak kurulur. 200k satirda bu tarama acilisin en pahali
  parcasidir. Bu birim, dizinin bir kopyasini `.odb.idx` yan dosyasina
  yazar; acilista dosya "taze" ise tarama atlanir.

  BU DOSYA HICBIR ZAMAN VERI KAYNAGI DEGILDIR:
  - Bozuksa, kesikse, bayatsa (LSN/boyut uyusmuyorsa) sessizce yok sayilir,
    tam tarama yapilir. Veri kaybi mumkun degil, yalniz acilis yavaslar.
  - Yalnizca checkpoint sonrasi yazilir; checkpoint ile ayni LSN'i tasir.
    Cokme sonrasi LSN uyusmaz -> tarama.

  Bicim (little endian):
    0   ..  63    baslik (64 B)
    64  ..  ...   kayitlar: Key(8) | PageNo(4) | Slot(2) | Pad(2) = 16 B
    ... ..  ...   (v3.1, istege bagli) etiket ozeti: Tag(4) | Count(8) = 12 B

  v3.1: satir sayaci ozeti. `.idx` ile AYNI LSN'de yazilir; bu yuzden
  tazeligi idx dogrulamasiyla aynidir. Bolum yoksa/bozuksa idx yine
  kullanilabilir; yalnizca sayac tam taramayla yeniden kurulur.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, VDbCrc32;

const
  VDB_IDX_MAGIC    = $33444956;   // 'VID3'
  VDB_IDX_VER      = 1;
  VDB_IDX_HDR_SIZE = 64;
  { Baslik CRC'si HdrCrc alanindan ONCEKI baytlar uzerinde hesaplanir
    (HdrCrc 36..39'da; sonrasindaki Reserved kapsam disi). }
  VDB_IDX_CRC_LEN  = 36;
  VDB_IDX_ENT_SIZE = 16;
  { v3.1: etiket ozeti kaydi. }
  VDB_IDX_TAG_SIZE = 12;

type
  EVdbIdxFile = class(Exception);

  TVdbIdxEntry = packed record
    Key: QWord;
    PageNo: LongWord;
    Slot: Word;
    Pad: Word;
  end;
  TVdbIdxEntryArray = array of TVdbIdxEntry;

  { v3.1: tablo basina satir sayimi (turetilmis onbellek, veri kaynagi
    DEGIL). Yalnizca .idx ile ayni LSN'de yazildigi icin tazeligi
    .idx dogrulamasiyla birlikte gelir. }
  TVdbIdxTagEntry = packed record
    Tag: LongInt;
    Count: Int64;
  end;
  TVdbIdxTagArray = array of TVdbIdxTagEntry;

  { 64 bayt; alanlar acikca hizalanir. }
  TVdbIdxHeader = packed record
    Magic: LongWord;
    Ver: LongWord;
    PageSize: LongWord;
    DbLSN: LongWord;
    DbPageCount: LongWord;
    Count: LongWord;
    DbSize: Int64;
    EntriesCrc: LongWord;
    HdrCrc: LongWord;
    Reserved: array[0..23] of Byte;   { toplam 64 bayt }
  end;

  { Dosyayi okur ve dogrular. Basarisizsa Err nedenini doldurur. }
  function VDbIdxLoad(const FileName: string; out Entries: TVdbIdxEntryArray;
    out Hdr: TVdbIdxHeader; out Err: string): Boolean;

  { v3.1: etiket ozetini de dondurur. }
  function VDbIdxLoadEx(const FileName: string; out Entries: TVdbIdxEntryArray;
    out Hdr: TVdbIdxHeader; out Tags: TVdbIdxTagArray;
    out Err: string): Boolean;

  { Once `.tmp` dosyasina yazip yeniden adlandirir: kesik idx olusmaz. }
  procedure VDbIdxSave(const FileName: string;
    const Entries: TVdbIdxEntryArray; DbLSN, DbPageCount: LongWord;
    DbSize: Int64; HeapPages: LongWord = 0; OvfPages: LongWord = 0);

  { v3.1: etiket ozetiyle birlikte yazar. }
  procedure VDbIdxSaveEx(const FileName: string;
    const Entries: TVdbIdxEntryArray; const Tags: TVdbIdxTagArray;
    DbLSN, DbPageCount: LongWord; DbSize: Int64;
    HeapPages: LongWord = 0; OvfPages: LongWord = 0);

  procedure VDbIdxDelete(const FileName: string);

implementation

function EntryCrc(const E: TVdbIdxEntryArray): LongWord;
var
  i: Integer;
begin
  Result := VDbCrc32Init;
  for i := 0 to High(E) do
    Result := VDbCrc32Update(Result, E[i], SizeOf(TVdbIdxEntry));
  Result := VDbCrc32Final(Result);
end;

function TagCrc(const T: TVdbIdxTagArray): LongWord;
var
  i: Integer;
begin
  Result := VDbCrc32Init;
  for i := 0 to High(T) do
    Result := VDbCrc32Update(Result, T[i], VDB_IDX_TAG_SIZE);
  Result := VDbCrc32Final(Result);
end;

function VDbIdxLoad(const FileName: string; out Entries: TVdbIdxEntryArray;
  out Hdr: TVdbIdxHeader; out Err: string): Boolean;
var
  tags: TVdbIdxTagArray;
begin
  Result := VDbIdxLoadEx(FileName, Entries, Hdr, tags, Err);
end;

function VDbIdxLoadEx(const FileName: string; out Entries: TVdbIdxEntryArray;
  out Hdr: TVdbIdxHeader; out Tags: TVdbIdxTagArray;
  out Err: string): Boolean;
var
  f: TFileStream;
  n: Int64;
  crc: LongWord;
  want: Int64;
  tagCount: LongWord;
  tagCrc_: LongWord;
begin
  Result := False;
  SetLength(Entries, 0);
  SetLength(Tags, 0);
  FillChar(Hdr, SizeOf(Hdr), 0);
  Err := '';
  if not FileExists(FileName) then
  begin
    Err := 'idx yok';
    Exit;
  end;
  f := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    n := f.Size;
    if n < VDB_IDX_HDR_SIZE then
    begin
      Err := Format('idx kesik (%d bayt)', [n]);
      Exit;
    end;
    f.ReadBuffer(Hdr, VDB_IDX_HDR_SIZE);
    if Hdr.Magic <> VDB_IDX_MAGIC then
    begin
      Err := 'idx sihirli sayi bozuk';
      Exit;
    end;
    if Hdr.Ver <> VDB_IDX_VER then
    begin
      Err := Format('idx surumu %d (beklenen %d)', [Hdr.Ver, VDB_IDX_VER]);
      Exit;
    end;
    if Hdr.PageSize <> 4096 then
    begin
      Err := Format('idx sayfa boyu %d', [Hdr.PageSize]);
      Exit;
    end;
    crc := VDbCrc32Of(Hdr, VDB_IDX_CRC_LEN);
    if crc <> Hdr.HdrCrc then
    begin
      Err := 'idx basligi bozuk (CRC)';
      Exit;
    end;
    { v3.1: etiket ozeti baslikta Reserved[8..15]'te. }
    Move(Hdr.Reserved[8], tagCount, 4);
    Move(Hdr.Reserved[12], tagCrc_, 4);
    want := VDB_IDX_HDR_SIZE + Int64(Hdr.Count) * VDB_IDX_ENT_SIZE +
      Int64(tagCount) * VDB_IDX_TAG_SIZE;
    if n <> want then
    begin
      Err := Format('idx boyu %d (beklenen %d)', [n, want]);
      Exit;
    end;
    SetLength(Entries, Hdr.Count);
    if Hdr.Count > 0 then
      f.ReadBuffer(Entries[0], Hdr.Count * VDB_IDX_ENT_SIZE);
    if EntryCrc(Entries) <> Hdr.EntriesCrc then
    begin
      Err := 'idx kayitlari bozuk (CRC)';
      SetLength(Entries, 0);
      Exit;
    end;
    if tagCount > 0 then
    begin
      SetLength(Tags, tagCount);
      f.ReadBuffer(Tags[0], tagCount * VDB_IDX_TAG_SIZE);
      if TagCrc(Tags) <> tagCrc_ then
      begin
        { Dizin gecerli; yalnizca sayac ozeti guvenilmez. Cagiran tam
          taramayla sayari yeniden kurar. }
        SetLength(Tags, 0);
        Err := 'idx etiket ozeti bozuk (CRC)';
      end;
    end;
    Result := True;
  finally
    f.Free;
  end;
end;

procedure VDbIdxSave(const FileName: string;
  const Entries: TVdbIdxEntryArray; DbLSN, DbPageCount: LongWord;
  DbSize: Int64; HeapPages: LongWord = 0; OvfPages: LongWord = 0);
var
  tags: TVdbIdxTagArray;
begin
  SetLength(tags, 0);
  VDbIdxSaveEx(FileName, Entries, tags, DbLSN, DbPageCount, DbSize,
    HeapPages, OvfPages);
end;

procedure VDbIdxSaveEx(const FileName: string;
  const Entries: TVdbIdxEntryArray; const Tags: TVdbIdxTagArray;
  DbLSN, DbPageCount: LongWord; DbSize: Int64;
  HeapPages: LongWord = 0; OvfPages: LongWord = 0);
var
  f: TFileStream;
  h: TVdbIdxHeader;
  tmp: string;
  done: Boolean;
  tagCount: LongWord;
  tagCrc_: LongWord;
begin
  FillChar(h, SizeOf(h), 0);
  h.Magic := VDB_IDX_MAGIC;
  h.Ver := VDB_IDX_VER;
  h.PageSize := 4096;
  h.DbLSN := DbLSN;
  h.DbPageCount := DbPageCount;
  h.Count := Length(Entries);
  h.DbSize := DbSize;
  Move(HeapPages, h.Reserved[0], 4);
  Move(OvfPages, h.Reserved[4], 4);
  tagCount := Length(Tags);
  Move(tagCount, h.Reserved[8], 4);
  tagCrc_ := TagCrc(Tags);
  Move(tagCrc_, h.Reserved[12], 4);
  h.EntriesCrc := EntryCrc(Entries);
  h.HdrCrc := VDbCrc32Of(h, VDB_IDX_CRC_LEN);

  tmp := FileName + '.tmp';
  f := TFileStream.Create(tmp, fmCreate);
  try
    f.WriteBuffer(h, VDB_IDX_HDR_SIZE);
    if Length(Entries) > 0 then
      f.WriteBuffer(Entries[0], Length(Entries) * VDB_IDX_ENT_SIZE);
    if tagCount > 0 then
      f.WriteBuffer(Tags[0], tagCount * VDB_IDX_TAG_SIZE);
  finally
    f.Free;
  end;
  if FileExists(FileName) then
    DeleteFile(FileName);
  { Yeniden adlandirma basarisiz olursa gecici dosya kalir; bir sonraki
    yazimda uzerine yazilir. idx zaten istege bagli. }
  done := RenameFile(tmp, FileName);
  if not done then
    DeleteFile(tmp);
end;

procedure VDbIdxDelete(const FileName: string);
begin
  if FileExists(FileName) then
    DeleteFile(FileName);
end;

end.
