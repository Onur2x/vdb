program sizebench;

{ VDB v3 - SQL katmani dosya boyu kaynak dagilimi (Sprint A/2)

  benchcmp SQL is yukununun aynisi (t(id INTEGER PRIMARY KEY, a INTEGER,
  b TEXT), satir-basina 'satir-'+j) kurulur, temiz kapanistan sonra dosya
  sayfa sayfa taranir ve baytlar nereye gidiyor yazdirilir:

    sayfa basligi / slot dizini / hucre basligi (8 B anahtar + 4 B uzunluk)
    / deger (EncodeRow) / bos+parcali / tasma / freelist / meta

  Ayrica .idx boyu ve hucre boyu dagilimi (histogram) verilir.
  Hedef: 77,6 B/satir'in ne kadarinin SQL satir kodlamasi oldugunu olcmek.

  Kullanim: sizebench <dizin> [satir_sayisi]
}

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbCore, VDbTypes, VDbTable, VDbSql, VDbPage, VDbPageHeap,
  VDbPageStore, VDbBackendApi, VDbBackendV3;

var
  gDir: string;

function FileSizeOf(const P: string): Int64;
var
  f: TFileStream;
begin
  Result := 0;
  if not FileExists(P) then Exit;
  f := TFileStream.Create(P, fmOpenRead or fmShareDenyNone);
  try
    Result := f.Size;
  finally
    f.Free;
  end;
end;

var
  N, NAuto, i, j: Integer;
  db: string;
  be: IVDbBackend;
  tb: TVTableDb;
  sq: TVSql;
  st: TVDbPageStore;
  P: PVdbPage;
  d: PByte;
  dl, slot: Integer;
  key: QWord;
  cellLen: LongWord;
  ptype: Byte;

  nMeta, nHeap, nOvf, nTrunk, nFree, nOther: LongWord;
  nPagesHeap: Integer;
  nCells, nCellsOvf: Int64;
  sumCell, sumVal, sumKeyHdr: Int64;
  sumSlot, sumPageHdr, sumFree, sumFrag: Int64;
  sumCrc: Int64;
  minCell, maxCell: Integer;
  hist: array[0..15] of Int64;   // 0: 0-15, 1: 16-31, ... 15: >=240
  bOdb, bIdx, bWal: Int64;
  h: Integer;
  valLen: Integer;
  dumpLeft: Integer;
  hexs: string;
  k: Integer;

begin
  N := 200000;
  NAuto := 0;
  if ParamCount >= 1 then gDir := ParamStr(1) else gDir := GetCurrentDir;
  if ParamCount >= 2 then N := StrToIntDef(ParamStr(2), N);
  if ParamCount >= 3 then NAuto := StrToIntDef(ParamStr(3), NAuto);
  if not DirectoryExists(gDir) then ForceDirectories(gDir);
  db := IncludeTrailingPathDelimiter(gDir) + 'veritabani.odb';
  if FileExists(db) then DeleteFile(db);
  if FileExists(db + '.wal') then DeleteFile(db + '.wal');
  if FileExists(db + '.idx') then DeleteFile(db + '.idx');

  WriteLn('VDB v3 sizebench - SQL katmani dosya boyu kaynak dagilimi');
  WriteLn(Format('dizin=%s  satir=%d  autocommit=%d', [gDir, N, NAuto]));
  WriteLn;

  { 1: benchcmp ile ayni is yukunu kur (semayi TVSql ile ac, yuklemeyi
    toplu tb.Insert ile yap — benchcmp OneTrial ile birebir). }
  be := TVdbBackendV3.Create(db, True, 512);
  tb := TVTableDb.CreateBackend(be);
  sq := nil;
  try
    tb.Open(gDir);
    sq := TVSql.Create(tb);
    sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
    tb.BeginBatch;
    for i := 1 to N do
      tb.Insert('t', ['id', 'a', 'b'],
        [IntToStr(i), IntToStr(i * 3), 'satir-' + IntToStr(i)]);
    tb.CommitBatch;
    { Istege bagli: benchcmp'in NRep=20000 tek satirlik autocommit'leri.
      Dosya boyu paylasimini bozarlar; yalniz "tum deneme" turunde verilmeli. }
    for i := 1 to NAuto do
      sq.Exec(Format('INSERT INTO t(id,a,b) VALUES (%d,%d,''auto'')',
        [1000000 + i, i]));
  finally
    sq.Free;
    tb.Close;
    tb.Free;
    be := nil;
  end;

  bOdb := FileSizeOf(db);
  bIdx := FileSizeOf(db + '.idx');
  bWal := FileSizeOf(db + '.wal');
  WriteLn(Format('odb=%d B (%.2f B/satir)  idx=%d B (%.2f B/satir)  wal=%d B',
    [bOdb, bOdb / N, bIdx, bIdx / N, bWal]));
  WriteLn(Format('toplam satir = %d (toplu %d + autocommit %d); bolumen N ise %.2f B/satir',
    [N + NAuto, N, NAuto, bOdb / (N + NAuto)]));
  WriteLn;

  { 2: sayfa sayfa tara }
  nMeta := 0; nHeap := 0; nOvf := 0; nTrunk := 0; nFree := 0; nOther := 0;
  nPagesHeap := 0;
  nCells := 0; nCellsOvf := 0;
  sumCell := 0; sumVal := 0; sumKeyHdr := 0;
  sumSlot := 0; sumPageHdr := 0; sumFree := 0; sumFrag := 0;
  sumCrc := 0;
  minCell := High(Integer); maxCell := 0;
  for h := 0 to 15 do hist[h] := 0;
  dumpLeft := 3;

  st := TVDbPageStore.Create(db, 256);
  try
    st.Open(False);
    for j := 1 to Integer(st.PageCount) - 1 do
    begin
      if not st.GetRawPage(LongWord(j), P) then Continue;
      ptype := PageTypeOf(P);
      case ptype of
        VDB_PAGE_META: Inc(nMeta);
        VDB_PAGE_HEAP:
          begin
            Inc(nHeap);
            Inc(nPagesHeap);
            Inc(sumPageHdr, VDB_PAGE_HDR);
            Inc(sumCrc, VDB_PAGE_CRC_LEN);
            Inc(sumFree, PageFreeBytes(P));
            Inc(sumFrag, PageFragBytes(P));
            for slot := 0 to PageSlotCount(P) - 1 do
            begin
              if not PageSlotIsLive(P, slot) then Continue;
              if not PageGetCell(P, slot, d, dl) then Continue;
              Inc(nCells);
              Inc(sumCell, dl);
              Inc(sumSlot, SizeOf(TVDbPageSlot));
              if dl < VDB_CELL_HDR then Continue;
              Move(d^, key, 8);
              Move((d + 8)^, cellLen, 4);
              valLen := dl - VDB_CELL_HDR;
              Inc(sumVal, valLen);
              if dumpLeft > 0 then
              begin
                hexs := '';
                for k := 0 to valLen - 1 do
                  hexs := hexs + IntToHex(d[VDB_CELL_HDR + k], 2) + ' ';
                WriteLn(Format('  [dump] hucre=%d hucreBoy=%d degerBoy=%d : %s',
                  [nCells, dl, valLen, hexs]));
                Dec(dumpLeft);
              end;
              Inc(sumKeyHdr, VDB_CELL_HDR);
              if dl < minCell then minCell := dl;
              if dl > maxCell then maxCell := dl;
              if dl < 240 then h := dl div 16 else h := 15;
              Inc(hist[h]);
              if (cellLen and VDB_OVF_FLAG) <> 0 then Inc(nCellsOvf);
            end;
          end;
        VDB_PAGE_OVERFLOW: Inc(nOvf);
        VDB_PAGE_FREETRUNK: Inc(nTrunk);
        VDB_PAGE_FREE: Inc(nFree);
      else
        Inc(nOther);
      end;
      { GetRawPage pinler; havuz tasarsa 'buffer pool dolu' firlatir. }
      st.Release(LongWord(j), False);
    end;
  finally
    st.Free;
  end;

  WriteLn('--- sayfa tipi ---');
  WriteLn(Format('meta=%d  heap=%d  tasma=%d  freelist trunk=%d  serbest=%d  diger=%d',
    [nMeta, nHeap, nOvf, nTrunk, nFree, nOther]));
  WriteLn;
  WriteLn('--- hucre bazli bayit dagilimi (heap sayfalari) ---');
  WriteLn(Format('hucre=%d  (tasimali=%d)  sayfa=%d', [nCells, nCellsOvf, nPagesHeap]));
  WriteLn(Format('hucre boyu: min=%d  max=%d  ort=%.2f B', [minCell, maxCell, sumCell / nCells]));
  WriteLn(Format('deger (EncodeRow)     : %d B  (%.2f B/satir)', [sumVal, sumVal / nCells]));
  WriteLn(Format('hucre basligi 12 B    : %d B  (%.2f B/satir)', [sumKeyHdr, sumKeyHdr / nCells]));
  WriteLn(Format('slot dizini 4 B       : %d B  (%.2f B/satir)', [sumSlot, sumSlot / nCells]));
  WriteLn(Format('sayfa basligi 24 B    : %d B  (%.2f B/satir)', [sumPageHdr, sumPageHdr / nCells]));
  WriteLn(Format('sayfa CRC 4 B         : %d B  (%.2f B/satir)', [sumCrc, sumCrc / nCells]));
  WriteLn(Format('bos (bitisik)         : %d B  (%.2f B/satir)', [sumFree, sumFree / nCells]));
  WriteLn(Format('parcali (delik)       : %d B  (%.2f B/satir)', [sumFrag, sumFrag / nCells]));
  WriteLn(Format('meta sayfasi + yuvarlama: %d B  (%.2f B/satir)',
    [bOdb - (sumCell + sumSlot + sumPageHdr + sumCrc + sumFree + sumFrag),
     (bOdb - (sumCell + sumSlot + sumPageHdr + sumCrc + sumFree + sumFrag)) / nCells]));
  WriteLn;
  WriteLn('--- hucre boyu histogrami (bayt) ---');
  for h := 0 to 15 do
    if hist[h] > 0 then
    begin
      if h < 15 then
        WriteLn(Format('  %3d-%3d : %d', [h * 16, h * 16 + 15, hist[h]]))
      else
        WriteLn(Format('  >=240  : %d', [hist[h]]));
    end;
  WriteLn;
  WriteLn('--- ozet ---');
  WriteLn(Format('toplam odb=%d B; hucre+slot+sayfa basligi=%d B; deger=%d B',
    [bOdb, sumKeyHdr + sumSlot + sumPageHdr, sumVal]));
  WriteLn(Format('hucre/satir = %.4f (hucre=%d, satir=%d)',
    [nCells / (N + NAuto), nCells, N + NAuto]));
  WriteLn(Format('SQL katmani payi = odb/satir - deger/satir = %.2f B',
    [bOdb / nCells - sumVal / nCells]));
  WriteLn(Format('dogrudan: 12 B hucre basligi + %.2f B deger + 4 B slot + %.2f B sayfa/ozi',
    [sumVal / nCells,
     (sumPageHdr + sumFree + sumFrag) / nCells]));
end.