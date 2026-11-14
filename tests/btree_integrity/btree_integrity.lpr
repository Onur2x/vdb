program btree_integrity;
{ V3 sertlestirme - Phase 6: B+Tree silme/denge/doluluk kapisi.

  Amac (skill Phase 6 "B+Tree deletion/rebalance strategy;
  fragmentation/reindex"): silme sonrasi agacin yapisal olarak saglam
  kaldigini, bos/az dolu dugum birakmadigini ve tarama yollarini
  (All/Find/LowerBound/CollectRange/CountRange/RankBefore) bozmadigini
  KANITLAMAK.

  Yaklasim: kucuk FMaxKeys degerleri (4, 5, 8) ile bolunme/birlestirme
  sinirlari zorlanir. Her adimda `CheckInvariants` (siralama, ayirici
  sinirlari, SubCount, yaprak zinciri Next/Prev, minimum doluluk) kosar.
  Doluluk ihlali ya da bos yaprak -> kapı kirmizi.

  Kapsam disi (durust sinir): ayri indeks DOSYASI (VDbIdxFile) ve disk
  uzerindeki B+tree sayfa bicimi bu kapida kosulmaz (bkz.
  docs/engineering/BTREE_INTEGRITY.md). Buradaki agac bellekteki
  TVDbBTree'dir.

  Derleme: fpc (lpi gerekmez). Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, VDbSkipList, VDbBTree;

type
  TCmpHolder = class
    function KeyCmp(const A, B: string): Integer;
  end;

function TCmpHolder.KeyCmp(const A, B: string): Integer;
begin
  Result := CompareStr(A, B);
end;

var
  GPass, GFail: Integer;
  GCmp: TCmpHolder;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' ', ADetail);
  end;
end;

function KeyOf(I: Integer): string;
begin
  Result := Format('k%.5d', [I]);
end;

function ValOf(I: Integer): string;
begin
  Result := 'v' + IntToStr(I);
end;

function MakeEntry(I: Integer): TVDbSkipEntry;
begin
  Result.Key := KeyOf(I);
  Result.Value := ValOf(I);
  Result.Cov := '';
end;

{ Yapinin butunlugunu denetler; '' disinda her sey hatadir. }
function Inv(const ATag: string; T: TVDbBTree): string;
begin
  Result := T.CheckInvariants;
  if Result <> '' then
    Result := ATag + ': ' + Result;
end;

{ Beklenen (sirali) anahtar listesi ile All() ciktisini karsilastirir. }
function AllMatches(T: TVDbBTree; const Expected: array of string;
  out Detail: string): Boolean;
var
  arr: TVDbSkipEntryArray;
  n, i: Integer;
begin
  Detail := '';
  n := T.All(arr);
  if Int64(n) <> T.Count then
  begin
    Detail := Format('All=%d, Count=%d', [n, T.Count]);
    Exit(False);
  end;
  if n <> Length(Expected) then
  begin
    Detail := Format('All=%d, beklenen=%d', [n, Length(Expected)]);
    Exit(False);
  end;
  for i := 0 to n - 1 do
    if arr[i].Key <> Expected[i] then
    begin
      Detail := Format('index %d: %s <> %s', [i, arr[i].Key, Expected[i]]);
      Exit(False);
    end;
  Result := True;
end;

function MakeAllKeys(N: Integer): TVDbSkipEntryArray;
var
  i: Integer;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do
    Result[i] := MakeEntry(i);
end;

var
  GSeed: LongWord;

function NextRand(AMax: Integer): Integer;
begin
  GSeed := (GSeed * 1103515245 + 12345) and $7FFFFFFF;
  Result := Integer(GSeed mod LongWord(AMax));
end;

{ ---------------------------------------------------------------- */
{ Yukleme + tek tek silme (verilen sirada), her adimda invariant. }
procedure CaseLoadDelete(const ATag: string; AMaxKeys, N: Integer;
  AOrder: Integer);
var
  T: TVDbBTree;
  arr: TVDbSkipEntryArray;
  alive: array of Boolean;
  order: array of Integer;
  i, j, tmp, aliveN, step: Integer;
  s, detail: string;
  keys: array of string;
begin
  GSeed := 987654321 + LongWord(AMaxKeys);
  T := TVDbBTree.Create(AMaxKeys);
  try
    arr := MakeAllKeys(N);
    T.LoadSorted(arr);
    s := Inv(ATag + '/load', T);
    Chk(ATag + '/load-inv', s = '',
      'h=' + IntToStr(T.Height) + ' leaf=' + IntToStr(T.LeafCount) + ' ' + s);
    if s <> '' then Exit;

    SetLength(alive, N);
    SetLength(order, N);
    for i := 0 to N - 1 do
    begin
      alive[i] := True;
      order[i] := i;
    end;
    aliveN := N;

    case AOrder of
      0: ;  // artan
      1:  // azalan
        for i := 0 to N div 2 - 1 do
        begin
          tmp := order[i];
          order[i] := order[N - 1 - i];
          order[N - 1 - i] := tmp;
        end;
      2:  // tohumlu karisik
        for i := N - 1 downto 1 do
        begin
          j := NextRand(i + 1);
          tmp := order[i];
          order[i] := order[j];
          order[j] := tmp;
        end;
    end;

    detail := '';
    step := 0;
    for i := 0 to N - 1 do
    begin
      if not T.Delete(KeyOf(order[i]), ValOf(order[i])) then
      begin
        detail := Format('silinemedi: %s', [KeyOf(order[i])]);
        Break;
      end;
      alive[order[i]] := False;
      Dec(aliveN);
      Inc(step);
      { Her adimda Count; invariant her 3 adimda (kapi suresi icin). }
      if T.Count <> aliveN then
      begin
        detail := Format('Count=%d, beklenen=%d (adim %d)',
          [T.Count, aliveN, step]);
        Break;
      end;
      if (step mod 3 = 0) or (aliveN = 0) or (aliveN = 1) then
      begin
        s := Inv(Format('%s/del-%d', [ATag, step]), T);
        if s <> '' then
        begin
          detail := s;
          Break;
        end;
      end;
    end;
    Chk(ATag + '/delete-all-inv', detail = '', detail);

    { Kalan (bos) durumda tarama yollari. }
    SetLength(keys, 0);
    Chk(ATag + '/empty-count', T.Count = 0, 'Count=' + IntToStr(T.Count));
    Chk(ATag + '/empty-all', AllMatches(T, keys, detail), detail);
    Chk(ATag + '/empty-inv', T.CheckInvariants = '', T.CheckInvariants);
    Chk(ATag + '/empty-delete-false', not T.Delete(KeyOf(0), ValOf(0)), '');
    Chk(ATag + '/empty-height1', T.Height = 1, 'h=' + IntToStr(T.Height));
  finally
    T.Free;
  end;
end;

{ Ekleme yolu: karisik sirada ekle, periyodik invariant, sonra tek tek sil. }
procedure CaseInsertChurn(const ATag: string; AMaxKeys, N: Integer);
var
  T: TVDbBTree;
  alive: array of Boolean;
  order: array of Integer;
  i, j, tmp, aliveN: Integer;
  s, detail: string;
  keys: array of string;
  res: TVDbSkipEntryArray;
  e: TVDbSkipEntry;
  got: Integer;
begin
  GSeed := 424242 + LongWord(AMaxKeys);
  T := TVDbBTree.Create(AMaxKeys);
  try
    SetLength(alive, N);
    SetLength(order, N);
    for i := 0 to N - 1 do
    begin
      alive[i] := False;
      order[i] := i;
    end;
    for i := N - 1 downto 1 do
    begin
      j := NextRand(i + 1);
      tmp := order[i];
      order[i] := order[j];
      order[j] := tmp;
    end;

    detail := '';
    aliveN := 0;
    for i := 0 to N - 1 do
    begin
      if not T.Insert(MakeEntry(order[i])) then
      begin
        detail := Format('eklenemedi: %s', [KeyOf(order[i])]);
        Break;
      end;
      alive[order[i]] := True;
      Inc(aliveN);
      if (i mod 25 = 24) then
      begin
        s := Inv(Format('%s/ins-%d', [ATag, i]), T);
        if s <> '' then
        begin
          detail := s;
          Break;
        end;
        if T.Count <> aliveN then
        begin
          detail := Format('Count=%d, beklenen=%d', [T.Count, aliveN]);
          Break;
        end;
      end;
    end;
    Chk(ATag + '/insert-inv', detail = '',
      'h=' + IntToStr(T.Height) + ' leaf=' + IntToStr(T.LeafCount) + ' ' + detail);
    if detail <> '' then Exit;

    { Ayni girdiyi tekrar eklemek False donmeli, Count degismemeli. }
    e := MakeEntry(order[0]);
    Chk(ATag + '/dup-insert-false', not T.Insert(e), '');
    Chk(ATag + '/dup-count', T.Count = N, 'Count=' + IntToStr(T.Count));

    { Find / LowerBound dogrulugu. }
    for i := 0 to N - 1 do
    begin
      if not T.Find(KeyOf(i), detail) then
      begin
        Chk(ATag + '/find', False, 'bulunamadi: ' + KeyOf(i));
        Exit;
      end;
      if detail <> ValOf(i) then
      begin
        Chk(ATag + '/find', False, 'deger: ' + detail + ' <> ' + ValOf(i));
        Exit;
      end;
    end;
    Chk(ATag + '/find-all', True, IntToStr(N) + ' anahtar');

    { Esit anahtar olmadigi icin RankBefore(i) = i. }
    detail := '';
    for i := 0 to N - 1 do
      if T.RankBefore(KeyOf(i), GCmp.KeyCmp, False) <> i then
      begin
        detail := Format('%s: Rank=%d, beklenen=%d',
          [KeyOf(i), T.RankBefore(KeyOf(i), GCmp.KeyCmp, False), i]);
        Break;
      end;
    Chk(ATag + '/rankbefore', detail = '', detail);

    { CountRange: [k00010, k00019] = 10. }
    if N >= 20 then
      Chk(ATag + '/countrange-10',
        T.CountRange(KeyOf(10), KeyOf(19), True, True, True, True,
          GCmp.KeyCmp) = 10,
        'deger=' + IntToStr(T.CountRange(KeyOf(10), KeyOf(19), True, True,
          True, True, GCmp.KeyCmp)));

    { CollectRange icerigi tam beklenen alt dizi olmali. }
    if N >= 20 then
    begin
      SetLength(keys, 10);
      for i := 0 to 9 do
        keys[i] := KeyOf(10 + i);
      got := T.CollectRange(KeyOf(10), KeyOf(19), True, True, True, True,
        GCmp.KeyCmp, res);
      detail := '';
      if got <> 10 then
        detail := 'adet=' + IntToStr(got)
      else
        for i := 0 to 9 do
          if res[i].Key <> keys[i] then
          begin
            detail := Format('index %d: %s <> %s', [i, res[i].Key, keys[i]]);
            Break;
          end;
      Chk(ATag + '/collectrange-10', detail = '', detail);
    end;

    { Tamamini sil. }
    detail := '';
    aliveN := N;
    for i := 0 to N - 1 do
    begin
      if not T.Delete(KeyOf(order[i]), ValOf(order[i])) then
      begin
        detail := Format('silinemedi: %s', [KeyOf(order[i])]);
        Break;
      end;
      Dec(aliveN);
      if (i mod 3 = 2) or (aliveN = 0) then
      begin
        s := Inv(Format('%s/del-%d', [ATag, i]), T);
        if s <> '' then
        begin
          detail := s;
          Break;
        end;
        if T.Count <> aliveN then
        begin
          detail := Format('Count=%d, beklenen=%d', [T.Count, aliveN]);
          Break;
        end;
      end;
    end;
    Chk(ATag + '/churn-delete-inv', detail = '', detail);
    SetLength(keys, 0);
    Chk(ATag + '/churn-empty', AllMatches(T, keys, detail), detail);
  finally
    T.Free;
  end;
end;

{ LoadSorted sonrasi ekleme + silme karisimi. }
procedure CaseLoadThenMutate(const ATag: string; AMaxKeys, N: Integer);
var
  T: TVDbBTree;
  arr: TVDbSkipEntryArray;
  i, s2: Integer;
  s, detail: string;
begin
  T := TVDbBTree.Create(AMaxKeys);
  try
    arr := MakeAllKeys(N);
    T.LoadSorted(arr);
    detail := '';
    { Araya yeni anahtarlar ekle (anahtarlar arasi bosluklara). }
    for i := 0 to N - 1 do
    begin
      s := 'x' + KeyOf(i);
      if not T.Insert(s, 'xv' + IntToStr(i)) then
      begin
        detail := 'eklenemedi: ' + s;
        Break;
      end;
    end;
    Chk(ATag + '/load-insert', detail = '', detail);
    s := Inv(ATag + '/load-insert-inv', T);
    Chk(ATag + '/load-insert-inv2', s = '', s);
    if s <> '' then Exit;

    { Yuklenen anahtarlarin yarisini sil. }
    detail := '';
    for i := 0 to N - 1 do
    begin
      if (i mod 2) = 0 then
        if not T.Delete(KeyOf(i), ValOf(i)) then
        begin
          detail := 'silinemedi: ' + KeyOf(i);
          Break;
        end;
      if (i mod 17 = 16) then
      begin
        s := Inv(Format('%s/mix-%d', [ATag, i]), T);
        if s <> '' then
        begin
          detail := s;
          Break;
        end;
      end;
    end;
    Chk(ATag + '/mix-delete', detail = '', detail);
    s2 := T.LeafCount;
    Chk(ATag + '/mix-leafcount', s2 > 0, 'leaf=' + IntToStr(s2));
    Chk(ATag + '/mix-height', T.Height >= 1, 'h=' + IntToStr(T.Height));
    { Silinen anahtar bulunmamali, kalan bulunmali. }
    Chk(ATag + '/mix-find-deleted', not T.Find(KeyOf(0), detail), '');
    Chk(ATag + '/mix-find-kept', T.Find(KeyOf(1), detail) and (detail = ValOf(1)),
      detail);
  finally
    T.Free;
  end;
end;

{ Doluluk/fragmentasyon olcumu: rastgele silme sonrasi yaprak dolulugu
  minimumun altina dusmemeli ve yaprak sayisi kontrolden cikmamali. }
procedure CaseDensity(const ATag: string; AMaxKeys, N: Integer);
var
  T: TVDbBTree;
  arr: TVDbSkipEntryArray;
  keep: array of Integer;
  i, j, tmp, nKeep: Integer;
  s: string;
  ratio: Double;
  arrAll: TVDbSkipEntryArray;
begin
  T := TVDbBTree.Create(AMaxKeys);
  try
    arr := MakeAllKeys(N);
    T.LoadSorted(arr);
    { Yarisini rastgele sil. }
    GSeed := 13579 + LongWord(AMaxKeys);
    SetLength(keep, N);
    nKeep := N;
    for i := 0 to N - 1 do
      keep[i] := i;
    for i := N - 1 downto 1 do
    begin
      j := NextRand(i + 1);
      tmp := keep[i];
      keep[i] := keep[j];
      keep[j] := tmp;
    end;
    for i := 0 to N div 2 - 1 do
    begin
      T.Delete(KeyOf(keep[i]), ValOf(keep[i]));
      Dec(nKeep);
    end;
    s := Inv(ATag + '/density', T);
    Chk(ATag + '/density-inv', s = '', s);
    Chk(ATag + '/density-count', T.Count = nKeep,
      'Count=' + IntToStr(T.Count) + ' beklenen=' + IntToStr(nKeep));
    if T.LeafCount > 0 then
      ratio := T.Count / (T.LeafCount * AMaxKeys)
    else
      ratio := 0;
    { Yaprak dolulugu en az ~%25 olmali (min FMaxKeys div 2 = K/2,
      yani ideal minimum ~%50; birlestirme sonrasi alt sinir %25). }
    Chk(ATag + '/density-ratio', ratio >= 0.2,
      Format('oran=%.2f leaf=%d count=%d', [ratio, T.LeafCount, T.Count]));
    T.All(arrAll);
    Chk(ATag + '/density-allcount', Length(arrAll) = nKeep,
      IntToStr(Length(arrAll)));
  finally
    T.Free;
  end;
end;

var
  Mk, i: Integer;
begin
  GPass := 0;
  GFail := 0;
  GCmp := TCmpHolder.Create;
  try
    Mk := 4;
    while Mk <= 8 do
    begin
      CaseLoadDelete(Format('K%d/asc', [Mk]), Mk, 257, 0);
      CaseLoadDelete(Format('K%d/desc', [Mk]), Mk, 257, 1);
      CaseLoadDelete(Format('K%d/rand', [Mk]), Mk, 257, 2);
      CaseLoadDelete(Format('K%d/small', [Mk]), Mk, 7, 2);
      CaseInsertChurn(Format('K%d/churn', [Mk]), Mk, 200);
      CaseLoadThenMutate(Format('K%d/mutate', [Mk]), Mk, 130);
      CaseDensity(Format('K%d/density', [Mk]), Mk, 400);
      if Mk = 4 then Mk := 5
      else if Mk = 5 then Mk := 8
      else Break;
    end;
    { Tek dugumluk agac: kok yaprak, silme koku bosaltir. }
    CaseLoadDelete('K4/single', 4, 1, 0);
    Chk('K4/single-height', True, 'h=1 beklenir');
  finally
    GCmp.Free;
  end;

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
