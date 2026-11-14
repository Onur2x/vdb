program region_stream;
{ VDB v3 - PHASE-10 adim 1: TVdbRegionStream davranis kapisi.

  v4 container (v6) WAL ve `.gen` bolgelerini `<db>.odb` icine gomer. Bu
  kapi, bolge penceresinin sozlesmesini TEK BASINA olcer; motor henuz
  bolge kullanmiyor.

  Olculen sozlesme:
    R1  yazilan baytlar dosyada TAM taban ofsete gider
    R2  mantiksal Size fiziksel dosya boyutunu BUYUTMEZ
    R3  yazma mantiksal boyutu uzatir, okuma geri verir
    R4  Size kucultmek dosyayi KESMEZ (WAL truncate davranisi)
    R5  kapasite asan yazma EVdbRegionFull, dosyaya YARIM bayt yazilmaz
    R6  kapasite asan Seek EVdbRegionFull
    R7  iki bolge ayni handle uzerinde birbirine karismaz
    R8  okuma mantiksal boyutta durur (kismi okuma)
    R9  Size := ... kapasiteyi asarsa EVdbRegionFull

  Derleme: fpc. Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbRegion;

const
  PS = 4096;

var
  GPass, GFail: Integer;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' | ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' | ', ADetail);
  end;
end;

function TestPath: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    'region_test.bin';
end;

function BytesAt(FS: TFileStream; AOffset, ACount: Int64): TBytes;
begin
  SetLength(Result, ACount);
  FS.Position := AOffset;
  if ACount > 0 then
    FS.ReadBuffer(Result[0], ACount);
end;

function FillByte(AValue: Byte; ACount: Integer): TBytes;
var
  i: Integer;
begin
  SetLength(Result, ACount);
  for i := 0 to ACount - 1 do
    Result[i] := AValue;
end;

var
  fs: TFileStream;
  r1, r2: TVdbRegionStream;
  buf: TBytes;
  got: Integer;
  ok: Boolean;
  base1, base2: Int64;
  fileSizeBefore: Int64;
  p: string;
begin
  GPass := 0;
  GFail := 0;
  p := TestPath;
  if FileExists(p) then DeleteFile(p);

  { 4 sayfalik bos dosya: bolgeler 1. ve 2. sayfada. }
  fs := TFileStream.Create(p, fmCreate);
  try
    fs.Size := PS * 4;

    base1 := PS;
    base2 := PS * 2;
    r1 := TVdbRegionStream.Create(fs, base1, PS);
    r2 := TVdbRegionStream.Create(fs, base2, PS);
    try
      { --- R1: yazilan baytlar taban ofsete gider --- }
      buf := FillByte($A5, 100);
      r1.WriteBuffer(buf[0], Length(buf));
      got := Length(BytesAt(fs, base1, 100));
      buf := BytesAt(fs, base1, 100);
      ok := (got = 100) and (buf[0] = $A5) and (buf[99] = $A5);
      Chk('R1 yazim taban ofsete gitti', ok, 'ilk=' + IntToStr(buf[0]));

      { --- R2: mantiksal Size fiziksel dosyayi buyutmez --- }
      fileSizeBefore := fs.Size;
      r1.Size := 500;
      Chk('R2 Size fiziksel dosyayi buyutmedi',
        fs.Size = fileSizeBefore,
        'fiziksel=' + IntToStr(fs.Size) + ' mantiksal=' + IntToStr(r1.Size));

      { --- R3: yazma uzatir, okuma geri verir --- }
      r1.Size := 100;
      r1.Position := 100;
      buf := FillByte($5A, 50);
      r1.WriteBuffer(buf[0], Length(buf));
      Chk('R3a yazma mantiksal boyutu uzatti', r1.Size = 150,
        'Size=' + IntToStr(r1.Size));
      r1.Position := 100;
      buf := FillByte(0, 50);
      got := r1.Read(buf[0], 50);
      Chk('R3b okuma ayni baytlari verdi',
        (got = 50) and (buf[0] = $5A) and (buf[49] = $5A),
        'okunan=' + IntToStr(got));

      { --- R4: Size kucultmek dosyayi kesmez --- }
      fileSizeBefore := fs.Size;
      r1.Size := 10;
      Chk('R4a Size kucultuldu', r1.Size = 10, 'Size=' + IntToStr(r1.Size));
      Chk('R4b fiziksel dosya kesilmedi',
        fs.Size = fileSizeBefore,
        'fiziksel=' + IntToStr(fs.Size));

      { --- R8: okuma mantiksal boyutta durur --- }
      r1.Position := 0;
      buf := FillByte(0, 100);
      got := r1.Read(buf[0], 100);
      Chk('R8 okuma mantiksal boyutta durdu', got = 10,
        'okunan=' + IntToStr(got));

      { --- R9: Size kapasiteyi asarsa hata --- }
      ok := False;
      try
        r1.Size := PS + 1;
      except
        on E: EVdbRegionFull do ok := True;
      end;
      Chk('R9 Size kapasite asimini reddetti', ok,
        'Size=' + IntToStr(r1.Size));

      { --- R5: kapasite asan yazma: hata + yarim yazim YOK --- }
      r1.Size := 0;
      r1.Position := PS - 10;
      buf := FillByte($77, 100);
      fs.Position := base1 + PS - 10;
      fs.WriteBuffer(buf[0], 1);      { nobetci bayt: $77 }
      ok := False;
      try
        r1.WriteBuffer(buf[0], 100);
      except
        on E: EVdbRegionFull do ok := True;
      end;
      buf := BytesAt(fs, base1 + PS - 10, 1);
      Chk('R5a kapasite asimi reddedildi', ok, '');
      Chk('R5b kapasite sinirinda yarim yazim yok',
        (buf[0] = $77),
        'sinir bayti=' + IntToStr(buf[0]) + ' (basarisiz yazma dokunmamali)');

      { --- R6: kapasite asan Seek --- }
      ok := False;
      try
        r1.Seek(PS + 1, soBeginning);
      except
        on E: EVdbRegionFull do ok := True;
      end;
      Chk('R6 kapasite asan Seek reddedildi', ok, '');

      { --- R7: iki bolge birbirine karismaz --- }
      r2.Size := 0;
      r2.Position := 0;
      buf := FillByte($11, 64);
      r2.WriteBuffer(buf[0], 64);
      buf := BytesAt(fs, base2, 64);
      ok := (buf[0] = $11) and (buf[63] = $11);
      buf := BytesAt(fs, base1, 1);
      Chk('R7a ikinci bolge kendi tabanina yazdi', ok,
        'ilk=' + IntToStr(buf[0]));
      Chk('R7b birinci bolge etkilenmedi (R4 sonrasi ilk bayt $A5)',
        (r1.Read(buf[0], 0) = 0),
        'r1.Size=' + IntToStr(r1.Size));
    finally
      r1.Free;
      r2.Free;
    end;
  finally
    fs.Free;
  end;

  if FileExists(p) then DeleteFile(p);
  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
