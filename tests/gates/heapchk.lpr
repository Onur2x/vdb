program heapchk;

{ VDB v3 - Heap dogrulama (Sprint 1 / Gun 3-4 kabul kapisi)

  Denetlenenler:
    1) Hucre yerlesimi ve tasma esigi (12 bayt baslik).
    2) 200.000 satir yaz/oku: hepsi birebir, satir basina bayt raporlanir.
    3) 5000 anahtarlik evrende 200.000 rastgele islem: BAGIMSIZ referans
       model ile birebir (ekle/guncelle/sil/oku + rastgele okuma).
    4) Kapat/ac: dizin taramayla yeniden kurulur, tum anahtarlar okunur.
    5) Tasma: 1 KB / 5 KB / 60 KB degerler, buyut/kucult, geri okuma.
    6) Bozulmus tasma sayfasi: TryGet yanlis veri DONDURMEZ.
    7) Tumunu sil: sayfalar freelist'e doner, anahtar 0.

  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: heapchk <calisma_dizini> [satir_sayisi] [rastgele_islem]
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: cthreads programin EN BASINDA olmali (TEvent/TThread). }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, VDbPage, VDbPageStore, VDbPageHeap;

var
  gPass, gFail: Int64;

procedure Ok(const S: string);
begin
  Inc(gPass);
  WriteLn('   OK   ', S);
end;

procedure Fail(const S: string);
begin
  Inc(gFail);
  WriteLn('   FAIL ', S);
end;

function ValByte(Key: QWord; Seed, Offset: Integer): Byte;
begin
  Result := Byte(((Key * 37) + QWord(Seed) * 101 + QWord(Offset) * 7) and $FF);
end;

procedure MakeVal(Key: QWord; Len, Seed: Integer; out V: TBytes);
var
  i: Integer;
begin
  SetLength(V, Len);
  for i := 0 to Len - 1 do
    V[i] := ValByte(Key, Seed, i);
end;

function ValEq(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and
            ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

{ ============================================================ 1) yerlesim }

procedure TestLayout;
begin
  if VDB_CELL_HDR <> 12 then
    Fail(Format('hucre basligi %d bayt (beklenen 12)', [VDB_CELL_HDR]))
  else
    Ok('hucre basligi 12 bayt (anahtar 8 + uzunluk 4)');
  if VDB_MAX_INLINE >= VDB_OVF_CHUNK then
    Fail('tasma esigi tek zincir sayfasindan buyuk olmamali')
  else
    Ok(Format('tasma esigi %d bayt, zincir parcasi %d bayt',
      [VDB_MAX_INLINE, VDB_OVF_CHUNK]));
end;

{ ======================================================== 2) toplu yaz/oku }

procedure TestBulk(D: string; N: Integer);
var
  st: TVDbPageStore;
  hp: TVdbHeap;
  i: Integer;
  v, got: TBytes;
  bad: Integer;
  t0, t1, t2: TDateTime;
  insUs, readUs: Double;
begin
  if FileExists(D + PathDelim + 'bulk.odb') then DeleteFile(D + PathDelim + 'bulk.odb');
  st := TVDbPageStore.Create(D + PathDelim + 'bulk.odb', 512);
  try
    st.Open(True);
    hp := TVdbHeap.Create(st);
    try
      hp.Open;
      t0 := Now;
      for i := 1 to N do
      begin
        MakeVal(i, 32, 1, v);
        if not hp.Insert(i, v) then
        begin
          Fail(Format('satir %d eklenemedi', [i]));
          Exit;
        end;
      end;
      t1 := Now;
      hp.Flush(True);
      if hp.Count <> N then
        Fail(Format('anahtar sayisi %d (beklenen %d)', [hp.Count, N]))
      else
        Ok(Format('%d satir eklendi', [N]));

      bad := 0;
      for i := 1 to N do
      begin
        MakeVal(i, 32, 1, v);
        if not hp.TryGet(i, got) then
        begin
          Inc(bad);
          if bad < 3 then Fail(Format('satir %d okunamadi', [i]));
          Continue;
        end;
        if not ValEq(v, got) then
        begin
          Inc(bad);
          if bad < 3 then Fail(Format('satir %d icerigi farkli', [i]));
        end;
      end;
      if bad = 0 then
        Ok(Format('%d satir birebir geri okundu', [N]));
      t2 := Now;

      insUs := (t1 - t0) * 86400.0 * 1000000.0 / N;
      readUs := (t2 - t1) * 86400.0 * 1000000.0 / N;
      WriteLn(Format('        EKLE %.2f us/satir   OKU %.2f us/satir', [insUs, readUs]));

      WriteLn(Format('        dosya=%d bayt  satir basina=%.1f B  heap sayfasi=%d',
        [st.Stats.FileBytes, st.Stats.FileBytes / N, hp.Stats.HeapPages]));
      { Kucuk N'de sayfa basligi + meta sayfa amortize olmaz; esik
        yalnizca buyuk veri kumelerinde anlamli. }
      if (N >= 50000) and (st.Stats.FileBytes / N > 55) then
        Fail(Format('satir basina %.1f B > 55 B hedefi', [st.Stats.FileBytes / N]))
      else
        Ok(Format('satir basina %.1f B (hedef <= 55, N>=50k)', [st.Stats.FileBytes / N]));
      hp.Flush(True);
    finally
      hp.Free;
    end;
    st.Close;
  finally
    st.Free;
  end;
end;

{ ==================================================== 3) rastgele islemler }

procedure TestRandom(D: string; NKeys, NOps, Seed: Integer);
var
  st: TVDbPageStore;
  hp: TVdbHeap;
  alive: array of Boolean;
  refVal: array of TBytes;
  i, k, op, len, bad, nIns, nUpd, nDel, nGet, nMiss, live: Integer;
  s: LongWord;
  v, got: TBytes;
begin
  if FileExists(D + PathDelim + 'rnd.odb') then DeleteFile(D + PathDelim + 'rnd.odb');
  st := TVDbPageStore.Create(D + PathDelim + 'rnd.odb', 64);
  try
    st.Open(True);
    hp := TVdbHeap.Create(st);
    try
      hp.Open;
      SetLength(alive, NKeys);
      SetLength(refVal, NKeys);
      s := LongWord(Seed);
      bad := 0;
      nIns := 0; nUpd := 0; nDel := 0; nGet := 0; nMiss := 0;
      for i := 1 to NOps do
      begin
        { Bagimsiz cekilisler: anahtar, islem, uzunluk birbirinden
          bagimsiz olsun (ayni s'den turetmek yanli test uretiyordu). }
        s := s xor (s shl 13);
        s := s xor (s shr 17);
        s := s xor (s shl 5);
        k := Integer(s mod LongWord(NKeys));
        s := s xor (s shl 13);
        s := s xor (s shr 17);
        s := s xor (s shl 5);
        op := Integer(s mod 100);
        s := s xor (s shl 13);
        s := s xor (s shr 17);
        s := s xor (s shl 5);
        len := Integer(s mod 501);
        if op < 40 then
        begin
          if alive[k] then Continue;
          MakeVal(k, len, i, v);
          if not hp.Insert(k, v) then
          begin
            Inc(bad);
            if bad < 4 then Fail(Format('islem %d: %d eklenemedi', [i, k]));
          end
          else
          begin
            alive[k] := True;
            refVal[k] := Copy(v);
            Inc(nIns);
          end;
        end
        else if op < 65 then
        begin
          MakeVal(k, len, i, v);
          if not alive[k] then
          begin
            if hp.Update(k, v) then
            begin
              Inc(bad);
              if bad < 4 then Fail(Format('islem %d: olmayan %d guncellendi', [i, k]));
            end;
            Continue;
          end;
          if not hp.Update(k, v) then
          begin
            Inc(bad);
            if bad < 4 then Fail(Format('islem %d: %d guncellenemedi', [i, k]));
          end
          else
          begin
            refVal[k] := Copy(v);
            Inc(nUpd);
          end;
        end
        else if op < 85 then
        begin
          if not alive[k] then
          begin
            if hp.Delete(k) then
            begin
              Inc(bad);
              if bad < 4 then Fail(Format('islem %d: olmayan %d silindi', [i, k]));
            end;
            Continue;
          end;
          if not hp.Delete(k) then
          begin
            Inc(bad);
            if bad < 4 then Fail(Format('islem %d: %d silinemedi', [i, k]));
          end
          else
          begin
            alive[k] := False;
            SetLength(refVal[k], 0);
            Inc(nDel);
          end;
        end
        else
        begin
          Inc(nGet);
          if hp.TryGet(k, got) <> alive[k] then
          begin
            Inc(bad);
            if bad < 4 then
              Fail(Format('islem %d: %d varlik farki (beklenen %s)',
                [i, k, BoolToStr(alive[k], True)]));
          end
          else if alive[k] and not ValEq(refVal[k], got) then
          begin
            Inc(bad);
            if bad < 4 then Fail(Format('islem %d: %d icerigi farkli', [i, k]));
          end
          else if not alive[k] then
            Inc(nMiss);
        end;
      end;

      if bad = 0 then
        Ok(Format('%d rastgele islem (ekle=%d guncelle=%d sil=%d oku=%d/%d yok) temiz',
          [NOps, nIns, nUpd, nDel, nGet, nMiss]));

      bad := 0;
      for k := 0 to NKeys - 1 do
      begin
        if hp.TryGet(k, got) <> alive[k] then
        begin
          Inc(bad);
          if bad < 4 then Fail(Format('son: %d varlik farki', [k]));
        end
        else if alive[k] and not ValEq(refVal[k], got) then
        begin
          Inc(bad);
          if bad < 4 then Fail(Format('son: %d icerik farki', [k]));
        end;
      end;

      live := 0;
      for i := 0 to NKeys - 1 do
        if alive[i] then Inc(live);
      if hp.Count <> live then
        Fail(Format('Count %d (referans %d)', [hp.Count, live]))
      else if bad = 0 then
        Ok(Format('son durum: %d canli anahtar, referans birebir', [live]));

      hp.Flush(True);
      { Kapsam: buyuk islem sayisinda guncelleme ve silme gercekten
        denenmis olmali; aksi halde test yesil ama bos olur. }
      if NOps >= 5000 then
      begin
        if nUpd = 0 then
          Fail('rastgele testte hic basarili guncelleme yok (kapsam yetersiz)')
        else if nDel = 0 then
          Fail('rastgele testte hic basarili silme yok (kapsam yetersiz)')
        else
          Ok(Format('kapsam: %d guncelleme, %d silme, %d isabetli okuma',
            [nUpd, nDel, nGet - nMiss]));
      end;
    finally
      hp.Free;
    end;
    st.Close;
  finally
    st.Free;
  end;
end;

{ ================================================== 4) kapat/ac (tarama) }

type
  TCountSink = class
    N: Integer;
    procedure Say(Key: QWord; const Value: TBytes);
  end;

procedure TCountSink.Say(Key: QWord; const Value: TBytes);
begin
  Inc(N);
end;

procedure TestReopen(D: string; N: Integer);
var
  st: TVDbPageStore;
  hp: TVdbHeap;
  i, bad: Integer;
  v, got: TBytes;
  sink: TCountSink;
begin
  st := TVDbPageStore.Create(D + PathDelim + 'bulk.odb', 64);
  try
    st.Open(False);
    hp := TVdbHeap.Create(st);
    sink := TCountSink.Create;
    try
      hp.Open;
      if hp.Count <> N then
        Fail(Format('yeniden acista anahtar %d (beklenen %d)', [hp.Count, N]))
      else
        Ok(Format('yeniden acista %d anahtar taramayla bulundu', [hp.Count]));
      bad := 0;
      for i := 1 to N do
      begin
        MakeVal(i, 32, 1, v);
        if not hp.TryGet(i, got) then
        begin
          Inc(bad);
          if bad < 3 then Fail(Format('yeniden acista %d okunamadi', [i]));
          Continue;
        end;
        if not ValEq(v, got) then
        begin
          Inc(bad);
          if bad < 3 then Fail(Format('yeniden acista %d icerik farki', [i]));
        end;
      end;
      if bad = 0 then
        Ok(Format('%d anahtar yeniden acista birebir', [N]));
      hp.ScanAll(sink.Say);
      if sink.N <> N then
        Fail(Format('ScanAll %d kayit (beklenen %d)', [sink.N, N]))
      else
        Ok(Format('ScanAll %d kayit', [sink.N]));
    finally
      sink.Free;
      hp.Free;
    end;
    st.Close;
  finally
    st.Free;
  end;
end;

{ =============================================================== 5) tasma }

procedure TestOverflow(D: string);
var
  st: TVDbPageStore;
  hp: TVdbHeap;
  sizes: array[0..5] of Integer;
  i, bad, freeBefore: Integer;
  v, got, v2: TBytes;
begin
  if FileExists(D + PathDelim + 'ovf.odb') then DeleteFile(D + PathDelim + 'ovf.odb');
  sizes[0] := 1;
  sizes[1] := 999;
  sizes[2] := 1001;
  sizes[3] := 5000;
  sizes[4] := 60000;
  sizes[5] := 1000;
  st := TVDbPageStore.Create(D + PathDelim + 'ovf.odb', 32);
  try
    st.Open(True);
    hp := TVdbHeap.Create(st);
    try
      hp.Open;
      bad := 0;
      for i := 0 to High(sizes) do
      begin
        MakeVal(100 + i, sizes[i], 7, v);
        if not hp.Insert(100 + i, v) then
        begin
          Inc(bad);
          Fail(Format('tasma %d bayt eklenemedi', [sizes[i]]));
        end;
      end;
      if bad = 0 then
        Ok(Format('%d farkli boyutta deger eklendi (1..60000 bayt)',
          [Length(sizes)]));

      for i := 0 to High(sizes) do
      begin
        MakeVal(100 + i, sizes[i], 7, v);
        if not hp.TryGet(100 + i, got) then
        begin
          Inc(bad);
          Fail(Format('tasma %d bayt okunamadi', [sizes[i]]));
          Continue;
        end;
        if not ValEq(v, got) then
        begin
          Inc(bad);
          Fail(Format('tasma %d bayt icerik farki (okunan %d)',
            [sizes[i], Length(got)]));
        end;
      end;
      if bad = 0 then
        Ok('tasma degerleri birebir geri okundu');

      MakeVal(104, 50, 9, v2);
      freeBefore := st.Stats.FreeCount;
      if not hp.Update(104, v2) then
        Fail('60000 -> 50 guncellemesi basarisiz')
      else if not hp.TryGet(104, got) or not ValEq(v2, got) then
        Fail('60000 -> 50 guncellemesi yanlis sonuc')
      else if Integer(st.Stats.FreeCount) <= freeBefore then
        Fail(Format('tasmadan kucultmede zincir serbest birakilmadi (freelist %d)',
          [st.Stats.FreeCount]))
      else
        Ok(Format('tasmadan iceri kucultme (60000 -> 50) dogru; zincir serbest (%d -> %d)',
          [freeBefore, st.Stats.FreeCount]));

      MakeVal(100, 3000, 9, v2);
      if not hp.Update(100, v2) then
        Fail('1 -> 3000 guncellemesi basarisiz')
      else if not hp.TryGet(100, got) or not ValEq(v2, got) then
        Fail('1 -> 3000 guncellemesi yanlis sonuc')
      else
        Ok('iceriden tasmaya buyutme (1 -> 3000) dogru');

      { 5000 baytlik kaydi sil: zinciri serbest kalmali. }
      freeBefore := st.Stats.FreeCount;
      if not hp.Delete(103) then
        Fail('tasma kaydi silinemedi')
      else if Integer(st.Stats.FreeCount) <= freeBefore then
        Fail('tasma sayfalari serbest birakilmadi')
      else
        Ok(Format('tasma silindi, freelist %d -> %d sayfa',
          [freeBefore, st.Stats.FreeCount]));

      hp.Flush(True);
    finally
      hp.Free;
    end;
    st.Close;
  finally
    st.Free;
  end;
end;

{ ========================================================== 6) bozulma }

procedure TestCorruptOverflow(D: string);
var
  st: TVDbPageStore;
  hp: TVdbHeap;
  v, got: TBytes;
  f: TFileStream;
  b: Byte;
  off: Int64;
  pno, ovfPage: LongWord;
  P: PVdbPage;
  okBefore, okAfter, raised: Boolean;
  path: string;
begin
  path := D + PathDelim + 'corrupt.odb';
  if FileExists(path) then DeleteFile(path);

  { 1) Tek tasma kaydi yaz, temiz kapat. }
  st := TVDbPageStore.Create(path, 32);
  try
    st.Open(True);
    hp := TVdbHeap.Create(st);
    try
      hp.Open;
      MakeVal(7, 9000, 3, v);
      if not hp.Insert(7, v) then
      begin
        Fail('bozulma testi: 9000 baytlik kayit eklenemedi');
        Exit;
      end;
      hp.Flush(True);
    finally
      hp.Free;
    end;
    st.Close;
  finally
    st.Free;
  end;

  { 2) Tasma sayfasini API ile bul (tip = VDB_PAGE_OVERFLOW). }
  ovfPage := 0;
  st := TVDbPageStore.Create(path, 32);
  try
    st.Open(False);
    for pno := 1 to st.PageCount - 1 do
      if st.GetPage(pno, P) then
      begin
        if (ovfPage = 0) and (PageTypeOf(P) = VDB_PAGE_OVERFLOW) then
          ovfPage := pno;
        st.Release(pno, False);
      end;
  finally
    st.Close;
    st.Free;
  end;
  if ovfPage = 0 then
  begin
    Fail('bozulma testi: tasma sayfasi bulunamadi');
    Exit;
  end;

  { 3) Diskte tasma sayfasinin veri bolgesinden bir bayt boz. }
  off := Int64(ovfPage) * VDB_PAGE_SIZE + 200;
  f := TFileStream.Create(path, fmOpenReadWrite or fmShareDenyNone);
  try
    f.Position := off;
    f.ReadBuffer(b, 1);
    b := b xor $FF;
    f.Position := off;
    f.WriteBuffer(b, 1);
  finally
    f.Free;
  end;

  { 4) Yeniden ac: bozulma ACIKCA yakalanmali; sessizce yanlis veri
    DONMEMELI. Heap acilisi tum sayfalari CRC ile dogrular. }
  st := TVDbPageStore.Create(path, 32);
  try
    st.Open(False);
    hp := TVdbHeap.Create(st);
    try
      MakeVal(7, 9000, 3, v);
      raised := False;
      okAfter := False;
      try
        hp.Open;
        okAfter := hp.TryGet(7, got);
      except
        on E: Exception do
        begin
          raised := True;
          WriteLn(Format('        (beklenen) %s', [E.Message]));
        end;
      end;
      if raised then
        Ok(Format('bozuk tasma sayfasi %d acilista yakalandi (sessiz bozulma yok)',
          [ovfPage]))
      else if not okAfter then
        Ok(Format('bozuk tasma sayfasi %d: okuma basarisiz (%s)',
          [ovfPage, hp.LastError]))
      else if ValEq(v, got) then
        Fail('bozuk tasma sayfasi dogru veri dondurdu (beklenmiyordu)')
      else
        Fail('bozuk tasma sayfasi sessizce YANLIS veri dondurdu');
    finally
      hp.Free;
    end;
  finally
    st.Close;
    st.Free;
  end;
end;

{ ============================================================ 7) tumunu sil }

procedure TestDeleteAll(D: string);
var
  st: TVDbPageStore;
  hp: TVdbHeap;
  i, beforeFree: Integer;
  got: TBytes;
begin
  st := TVDbPageStore.Create(D + PathDelim + 'rnd.odb', 64);
  try
    st.Open(False);
    hp := TVdbHeap.Create(st);
    try
      hp.Open;
      beforeFree := st.Stats.FreeCount;
      for i := 0 to 4999 do
        hp.Delete(i);
      hp.Flush(True);
      if hp.Count <> 0 then
        Fail(Format('tumunu sil sonrasi anahtar %d', [hp.Count]))
      else
        Ok('tum anahtarlar silindi (Count=0)');
      if Integer(st.Stats.FreeCount) <= beforeFree then
        Fail(Format('silme sonrasi bos sayfa artmadi (%d -> %d)',
          [beforeFree, st.Stats.FreeCount]))
      else
        Ok(Format('bosalan sayfalar freelist''e dondu (%d -> %d)',
          [beforeFree, st.Stats.FreeCount]));
      if hp.TryGet(1234, got) then
        Fail('silinen anahtar hala okunuyor')
      else
        Ok('silinen anahtar okunamadi');
    finally
      hp.Free;
    end;
    st.Close;
  finally
    st.Free;
  end;
end;

var
  D: string;
  N, NOps: Integer;
begin
  gPass := 0;
  gFail := 0;
  D := ParamStr(1);
  if D = '' then
    D := IncludeTrailingPathDelimiter(GetTempDir) + 'vdbheapchk';
  N := StrToIntDef(ParamStr(2), 200000);
  NOps := StrToIntDef(ParamStr(3), 200000);
  ForceDirectories(D);

  WriteLn('VDB v3 heapchk - heap dogrulama');
  WriteLn(Format('dizin=%s satir=%d rastgele_islem=%d', [D, N, NOps]));
  WriteLn('');

  TestLayout;
  TestBulk(D, N);
  TestReopen(D, N);
  TestRandom(D, 5000, NOps, 987654321);
  TestOverflow(D);
  TestCorruptOverflow(D);
  TestDeleteAll(D);

  WriteLn('');
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
    WriteLn('HEAP DOGRULANDI')
  else
    WriteLn('HEAP HATALI');
  if gFail <> 0 then
    Halt(1);
end.
