unit VDbRegion;
{ VDB v3 - v4 container (v6) icin bolge penceresi.

  Neden: v6'da WAL ve `.gen` ayri dosya degil, `<db>.odb` icinde birer
  bolgedir. Bu birim, dosyanin bir araligini bagimsiz bir TStream gibi
  gosterir: taban ofset + kapasite.

  Sozlesme:
  - `Size` (mantiksal uzunluk) fiziksel dosyayi KESMEZ. Kucultme yalnizca
    mantiksal uzunlugu degistirir (WAL truncate'i boyle calisir).
  - Kapasitenin disina tasan okuma/yazma SESSIZCE kirpilmaz; `EVdbRegionFull`
    yukseltilir. Yarim yazim da kabul edilmez: once sinir kontrolu, sonra
    tek WriteBuffer.
  - Alt handle sahiplenilmez (varsayilan); ayni handle uzerinde birden fazla
    bolge yasayabilir.
  - `Flush` alt handle'a devredilir (tum dosya fsync; v6'da zaten tek dosya).

  Bu birim bilerek politika icermez: bolge tasima, baslik yazimi ve kilitler
  cagiranin isidir (bkz. docs/engineering/V4_CONTAINER_DESIGN.md).
}
{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes;

type
  { Bolge kapasitesi asildi. Cagiran bunu commit'i REDDETMEK icin kullanir
    (sessiz yanlis sonuc yok). }
  EVdbRegionFull = class(Exception);

  TVdbRegionStream = class(TStream)
  private
    FHandle: THandleStream;   { sahip DEGIL (varsayilan) }
    FBase: Int64;
    FCap: Int64;
    FPos: Int64;
    FSize: Int64;
    FOwnsHandle: Boolean;
    procedure NeedRoom(AStart, ACount: Int64);
  protected
    function GetSize: Int64; override;
    procedure SetSize(const NewSize: Int64); override;
  public
    constructor Create(AHandle: THandleStream; ABase, ACapacity: Int64;
      AOwnsHandle: Boolean = False);
    destructor Destroy; override;

    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;

    { Kapasiteyi degistirir. Kucultme yalnizca mantiksal boyutu kirpar;
      buyutme cagiranin dosyayi zaten buyutmus olmasini bekler. }
    procedure SetCapacity(ACapacity: Int64);

    property Base: Int64 read FBase;
    property Capacity: Int64 read FCap;
    { Mantiksal uzunluk (Size ile ayni; niyeti acikca yazmak icin). }
    property StoredSize: Int64 read FSize;
  end;

implementation

constructor TVdbRegionStream.Create(AHandle: THandleStream; ABase,
  ACapacity: Int64; AOwnsHandle: Boolean);
begin
  inherited Create;
  if AHandle = nil then
    raise EVdbRegionFull.Create('bolge: alt handle yok');
  if ABase < 0 then
    raise EVdbRegionFull.Create('bolge: negatif taban ofset');
  if ACapacity < 0 then
    raise EVdbRegionFull.Create('bolge: negatif kapasite');
  FHandle := AHandle;
  FBase := ABase;
  FCap := ACapacity;
  FPos := 0;
  FSize := 0;
  FOwnsHandle := AOwnsHandle;
end;

destructor TVdbRegionStream.Destroy;
begin
  if FOwnsHandle and (FHandle <> nil) then
    FreeAndNil(FHandle);
  FHandle := nil;
  inherited Destroy;
end;

function TVdbRegionStream.GetSize: Int64;
begin
  Result := FSize;
end;

procedure TVdbRegionStream.SetSize(const NewSize: Int64);
begin
  { Fiziksel dosyaya DOKUNMAZ: yalniz mantiksal uzunluk. }
  if NewSize < 0 then
    raise EVdbRegionFull.Create('bolge: negatif boyut');
  if NewSize > FCap then
    raise EVdbRegionFull.CreateFmt(
      'bolge kapasitesi asildi (istenen %d, kapasite %d)', [NewSize, FCap]);
  FSize := NewSize;
  if FPos > FSize then
    FPos := FSize;
end;

procedure TVdbRegionStream.SetCapacity(ACapacity: Int64);
begin
  if ACapacity < 0 then
    raise EVdbRegionFull.Create('bolge: negatif kapasite');
  FCap := ACapacity;
  if FSize > FCap then
    FSize := FCap;
  if FPos > FSize then
    FPos := FSize;
end;

procedure TVdbRegionStream.NeedRoom(AStart, ACount: Int64);
begin
  if ACount < 0 then
    raise EVdbRegionFull.Create('bolge: negatif uzunluk');
  if AStart < 0 then
    raise EVdbRegionFull.Create('bolge: negatif konum');
  if (AStart + ACount) > FCap then
    raise EVdbRegionFull.CreateFmt(
      'bolge kapasitesi asildi (konum %d + %d, kapasite %d)',
      [AStart, ACount, FCap]);
end;

function TVdbRegionStream.Read(var Buffer; Count: LongInt): LongInt;
var
  avail: Int64;
begin
  Result := 0;
  if Count <= 0 then Exit;
  if FHandle = nil then Exit;
  { Okuma, her TStream gibi mantiksal boyutta durur (kismi okuma normaldir;
    EOF). Kapasite disina cikmak ise yukarida hata verir. }
  if (FPos + Count) > FSize then
  begin
    avail := FSize - FPos;
    if avail <= 0 then Exit;
    Count := LongInt(avail);
  end;
  NeedRoom(FPos, Count);
  FHandle.Position := FBase + FPos;
  Result := FHandle.Read(Buffer, Count);
  Inc(FPos, Result);
end;

function TVdbRegionStream.Write(const Buffer; Count: LongInt): LongInt;
begin
  Result := 0;
  if Count <= 0 then Exit;
  if FHandle = nil then
    raise EVdbRegionFull.Create('bolge: alt handle yok');
  { Sinir kontrolu TEK noktada: yarim yazim olmaz. }
  NeedRoom(FPos, Count);
  FHandle.Position := FBase + FPos;
  FHandle.WriteBuffer(Buffer, Count);
  Inc(FPos, Count);
  if FPos > FSize then
    FSize := FPos;
  Result := Count;
end;

function TVdbRegionStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
var
  np: Int64;
begin
  case Origin of
    soBeginning: np := Offset;
    soCurrent:   np := FPos + Offset;
    soEnd:       np := FSize + Offset;
  else
    np := FPos;
  end;
  if np < 0 then
    raise EVdbRegionFull.Create('bolge: negatif konum');
  { Mantiksal boyutun otesine konumlanmak serbesttir (yazma uzatir),
    kapasitenin otesine degil. }
  if np > FCap then
    raise EVdbRegionFull.CreateFmt(
      'bolge: konum kapasite disinda (%d > %d)', [np, FCap]);
  FPos := np;
  Result := FPos;
end;

end.
