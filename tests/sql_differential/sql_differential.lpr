program sql_differential;
{ V3 sertlestirme - Phase 5: PostgreSQL diferansiyel korpusu kapisi.

  Amac (skill Phase 5 "PostgreSQL differential suite" + "skip governance"):
  desteklenen SQL alt kumesinin PostgreSQL karsisindaki durumunu KAYITLI bir
  sozlesmeye baglamak. Her kosumda:

    (a) VDB'yi korpustaki SQL ile kosar ve --VDB beklentisiyle karsilastirir
        (izgara ya da error:<kod>);
    (b) yonetisim (governance) kurallarini denetler:
          - kind=same  -> --PG ve --VDB AYNI olmali,
          - kind=diff  -> ikisi FARKLI olmali ve --NOTE dolu olmali.
        Boylece "bildirilmemis sapma" (sessiz sozlesme degisikligi) gecemez.

  Canli PostgreSQL:
    --emit=<dosya>  psql betigi uretir (izgara bicimi psql'in unaligned +
                    tuples_only + fieldsep=',' + recordsep='|' ayariyla ayni).
    --pg=<dosya>    psql ciktisini pinli --PG degerleriyle karsilastirir.
  psql/Baglanti yoksa canli adim KOSMAZ ve rapor bunu "pg=not-run" der;
  asla sessizce "gecti" sayilmaz.

  DURUST SINIR: bu kapinin varsayilan kosumu PostgreSQL'e BAGLANMAZ; pinli
  degerler PostgreSQL dokumantasyonuna/dayanak tablosuna gore yazilmistir.
  Canli dogrulama ancak psql bulunan bir ortamda --pg ile yapilir
  (bkz. docs/engineering/SQL_DIFFERENTIAL.md).

  Derleme: fpc (lpi gerekmez). Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbTable, VDbSql, VDbErr,
  VDbCore;

type
  TCase = record
    Id: string;
    Kind: string;        // 'same' | 'diff'
    Setup: array of string;
    Probe: string;
    PgVal: string;       // izgara ya da error:<metin>
    VdbVal: string;      // izgara ya da error:<kod>
    Note: string;
    NoteSet: Boolean;
  end;

var
  GPass, GFail: Integer;
  GCases: array of TCase;
  GLive: array of string;
  GBe: IVdbBackend;
  GTb: TVTableDb;
  GSql: TVSql;

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

function TestDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp');
end;

function FreshDir(const AName: string): string;
var
  sr: TSearchRec;
  p, safe: string;
  i: Integer;
begin
  safe := '';
  for i := 1 to Length(AName) do
    if AName[i] in ['a'..'z', 'A'..'Z', '0'..'9', '_'] then
      safe := safe + AName[i];
  Result := IncludeTrailingPathDelimiter(TestDir + 'df_' + safe);
  if FindFirst(IncludeTrailingPathDelimiter(Result) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        p := IncludeTrailingPathDelimiter(Result) + sr.Name;
        if (sr.Attr and faDirectory) <> 0 then
          p := IncludeTrailingPathDelimiter(p);
        DeleteFile(p);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  ForceDirectories(Result);
end;

procedure OpenEnv(const ADir: string);
begin
  VdbOpen(ADir, GBe, True, True);
  GTb := TVTableDb.CreateBackend(GBe);
  GTb.Open(ADir);
  GSql := TVSql.Create(GTb);
end;

procedure CloseEnv;
begin
  FreeAndNil(GSql);
  FreeAndNil(GTb);
  GBe := nil;
end;

{ Sonucu karsilastirilabilir tek metne cevirir (sql_matrix ile ayni bicim):
  hucreler ',' , satirlar '|' , bos sonuc = ''. }
function GridOf(const r: TSqlResult): string;
var
  i, j: Integer;
  s: string;
begin
  Result := '';
  for i := 0 to High(r.Rows) do
  begin
    s := '';
    for j := 0 to High(r.Rows[i]) do
    begin
      if j > 0 then
        s := s + ',';
      s := s + r.Rows[i][j];
    end;
    if i > 0 then
      Result := Result + '|';
    Result := Result + s;
  end;
end;

function TrimRaw(const S: string): string;
var
  e: Integer;
begin
  Result := S;
  e := Length(Result);
  while (e > 0) and (Result[e] in [#13, #10, ' ', #9]) do
    Dec(e);
  SetLength(Result, e);
end;

function StripPrefixCR(const S: string): string;
begin
  Result := S;
  if (Result <> '') and (Result[Length(Result)] = #13) then
    SetLength(Result, Length(Result) - 1);
end;

// ------------------------------------------------------------------
// Korpus okuma
// ------------------------------------------------------------------

procedure ResetCase(var C: TCase);
begin
  C.Id := '';
  C.Kind := '';
  C.Setup := nil;
  C.Probe := '';
  C.PgVal := '';
  C.VdbVal := '';
  C.Note := '';
  C.NoteSet := False;
end;

procedure AddCase(var C: TCase);
begin
  SetLength(GCases, Length(GCases) + 1);
  GCases[High(GCases)] := C;
end;

function ParseCorpus(const AFile: string; out AErr: string): Boolean;
var
  L: TStringList;
  i, sp: Integer;
  line, key, val: string;
  C: TCase;
  have: Boolean;
begin
  Result := False;
  AErr := '';
  if not FileExists(AFile) then
  begin
    AErr := 'korpus yok: ' + AFile;
    Exit;
  end;
  L := TStringList.Create;
  try
    L.LoadFromFile(AFile);
    have := False;
    ResetCase(C);
    for i := 0 to L.Count - 1 do
    begin
      line := StripPrefixCR(L[i]);
      if Copy(line, 1, 2) <> '--' then Continue;
      sp := Pos(' ', line);
      if sp = 0 then
      begin
        key := Copy(line, 3, MaxInt);
        val := '';
      end
      else
      begin
        key := Copy(line, 3, sp - 3);
        val := TrimRaw(Copy(line, sp + 1, MaxInt));
      end;
      key := UpperCase(key);
      if key = 'CASE' then
      begin
        if have then AddCase(C);
        ResetCase(C);
        C.Id := val;
        have := True;
      end
      else if not have then
        Continue
      else if key = 'KIND' then
        C.Kind := LowerCase(val)
      else if key = 'SETUP' then
      begin
        SetLength(C.Setup, Length(C.Setup) + 1);
        C.Setup[High(C.Setup)] := val;
      end
      else if key = 'PROBE' then
        C.Probe := val
      else if key = 'PG' then
        C.PgVal := val
      else if key = 'VDB' then
        C.VdbVal := val
      else if key = 'NOTE' then
      begin
        { NOTE satirlari birlesir; ayni case icinde coklu NOTE serbest. }
        if C.Note = '' then
          C.Note := val
        else
          C.Note := C.Note + ' ' + val;
        C.NoteSet := True;
      end;
    end;
    if have then AddCase(C);
    Result := Length(GCases) > 0;
    if not Result then
      AErr := 'korpus bos';
  finally
    L.Free;
  end;
end;

// ------------------------------------------------------------------
// VDB kosumu
// ------------------------------------------------------------------

{ Tek durumu kosar. AOut: VDB'nin gercek degeri (izgara ya da error:<kod>). }
procedure RunVdb(const C: TCase; out AOut: string; out ADetail: string);
var
  dir: string;
  i: Integer;
  r: TSqlResult;
begin
  AOut := '';
  ADetail := '';
  dir := FreshDir(C.Id);
  OpenEnv(dir);
  try
    for i := 0 to High(C.Setup) do
      GSql.Exec(C.Setup[i]);
    try
      r := GSql.Exec(C.Probe);
      AOut := GridOf(r);
      ADetail := 'grid=''' + AOut + '''';
    except
      on E: EVDbException do
      begin
        AOut := 'error:' + VDbErrorName(E.ErrorCode);
        ADetail := 'err=' + AOut + ' msg=' + E.Message;
      end;
    end;
  finally
    CloseEnv;
  end;
end;

// ------------------------------------------------------------------
// psql betigi uretimi / ciktisi
// ------------------------------------------------------------------

function IsVdbError(const S: string): Boolean;
begin
  Result := Pos('error:', S) = 1;
end;

function EmitPsql(const AFile: string; out ACount: Integer): Boolean;
var
  L: TStringList;
  i, j: Integer;
begin
  ACount := 0;
  L := TStringList.Create;
  try
    L.Add('\pset format unaligned');
    L.Add('\pset fieldsep '',''');
    L.Add('\pset recordsep ''|''');
    L.Add('\pset tuples_only on');
    L.Add('\pset pager off');
    for i := 0 to High(GCases) do
    begin
      { PostgreSQL'de hata veren durumlar betigi durdurur; bunlar canli
        karsilastirmaya alinmaz ve raporda ayrica sayilir. }
      if IsVdbError(GCases[i].VdbVal) then Continue;
      if IsVdbError(GCases[i].PgVal) then Continue;
      L.Add('\echo ===' + GCases[i].Id);
      for j := 0 to High(GCases[i].Setup) do
        L.Add(GCases[i].Setup[j] + ';');
      L.Add(GCases[i].Probe + ';');
      L.Add('\echo ===' + GCases[i].Id + ':end');
      Inc(ACount);
    end;
    L.SaveToFile(AFile);
    Result := True;
  finally
    L.Free;
  end;
end;

{ psql ciktisini okur: '===id' ile '===id:end' arasindaki ilk satir izgaradir
  (recordsep '|' oldugu icin tum satirlar tek fiziksel satirda birlesir).
  Canli deger AYRI bir dizide tutulur; pinli --PG degeri BOZULMAZ. }
procedure LoadPgOut(const AFile: string; out AErr: string);
var
  L: TStringList;
  i, k: Integer;
  line, id: string;
  cur: Integer;
begin
  AErr := '';
  if not FileExists(AFile) then
  begin
    AErr := 'psql ciktisi yok: ' + AFile;
    Exit;
  end;
  L := TStringList.Create;
  try
    L.LoadFromFile(AFile);
    SetLength(GLive, Length(GCases));
    for i := 0 to High(GLive) do
      GLive[i] := #1;   // 'gorulmedi' isareti
    cur := -1;
    for i := 0 to L.Count - 1 do
    begin
      line := StripPrefixCR(L[i]);
      if Copy(line, 1, 3) = '===' then
      begin
        id := Copy(line, 4, MaxInt);
        if (Length(id) > 4) and (Copy(id, Length(id) - 3, 4) = ':end') then
        begin
          cur := -1;
          Continue;
        end;
        cur := -1;
        for k := 0 to High(GCases) do
          if GCases[k].Id = id then
          begin
            cur := k;
            Break;
          end;
        Continue;
      end;
      if (cur >= 0) and (GLive[cur] = #1) then
        GLive[cur] := line;
    end;
  finally
    L.Free;
  end;
end;

// ------------------------------------------------------------------

var
  Corpus: string;
  i: Integer;
  err, outV, det: string;
  emitTo, pgFrom: string;

  function ArgVal(const APrefix: string): string;
  var
    k: Integer;
    a: string;
  begin
    Result := '';
    for k := 1 to ParamCount do
    begin
      a := ParamStr(k);
      if Copy(a, 1, Length(APrefix)) = APrefix then
        Result := Copy(a, Length(APrefix) + 1, MaxInt);
    end;
  end;

begin
  GPass := 0;
  GFail := 0;
  ForceDirectories(TestDir);

  emitTo := ArgVal('--emit=');
  pgFrom := ArgVal('--pg=');

  if ParamCount >= 1 then
    Corpus := ParamStr(1)
  else
    Corpus := '';

  if (Corpus = '') or (Copy(Corpus, 1, 2) = '--') then
  begin
    WriteLn('FAIL korpus | kullanim: sql_differential <corpus.txt> [--emit=out.sql] [--pg=pg.out]');
    Halt(1);
  end;

  if not ParseCorpus(Corpus, err) then
  begin
    WriteLn('FAIL korpus | ' + err);
    Halt(1);
  end;
  Chk('C0 korpus okundu', True, 'durum=' + IntToStr(Length(GCases)));

  { --- yonetisim: her durumun beklentileri tutarli mi? --- }
  for i := 0 to High(GCases) do
  begin
    if GCases[i].Kind = 'same' then
      Chk(GCases[i].Id + '/gov-same',
        GCases[i].PgVal = GCases[i].VdbVal,
        'PG=''' + GCases[i].PgVal + ''' VDB=''' + GCases[i].VdbVal + '''')
    else if GCases[i].Kind = 'diff' then
    begin
      Chk(GCases[i].Id + '/gov-declared',
        GCases[i].NoteSet and (GCases[i].Note <> ''),
        'note=' + Copy(GCases[i].Note, 1, 70));
      Chk(GCases[i].Id + '/gov-really-diff',
        GCases[i].PgVal <> GCases[i].VdbVal,
        'PG=''' + GCases[i].PgVal + ''' VDB=''' + GCases[i].VdbVal + '''');
    end
    else
      Chk(GCases[i].Id + '/gov-kind', False,
        'KIND yalniz same|diff olabilir: ''' + GCases[i].Kind + '''');
  end;

  { --- VDB kosumu --- }
  for i := 0 to High(GCases) do
  begin
    RunVdb(GCases[i], outV, det);
    Chk(GCases[i].Id, outV = GCases[i].VdbVal,
      'beklenen=''' + GCases[i].VdbVal + ''' gercek=''' + outV + ''' ' + det);
  end;

  { --- canli PostgreSQL (istege bagli) --- }
  if emitTo <> '' then
  begin
    if EmitPsql(emitTo, i) then
      Chk('PG0 psql betigi yazildi', True,
        'dosya=' + emitTo + ' durum=' + IntToStr(i))
    else
      Chk('PG0 psql betigi yazildi', False, emitTo);
  end;

  if pgFrom <> '' then
  begin
    LoadPgOut(pgFrom, err);
    if err = '' then
    begin
      Chk('PG1 psql ciktisi okundu', True, pgFrom);
      for i := 0 to High(GCases) do
      begin
        if IsVdbError(GCases[i].VdbVal) then Continue;
        if GLive[i] = #1 then
          Chk(GCases[i].Id + '/pg-live', False,
            'psql ciktisinda durum yok')
        else
        begin
          { Iki ayri iddia: canli PG pinli --PG ile ayni mi (surum kaymasi),
            ve canli PG VDB ile ayni mi (gercek diferansiyel). }
          Chk(GCases[i].Id + '/pg-pinned',
            GLive[i] = GCases[i].PgVal,
            'canli PG=''' + GLive[i] + ''' pinli PG=''' +
            GCases[i].PgVal + '''');
          if GCases[i].Kind = 'same' then
            Chk(GCases[i].Id + '/pg-live',
              GLive[i] = GCases[i].VdbVal,
              'canli PG=''' + GLive[i] + ''' VDB=''' +
              GCases[i].VdbVal + '''');
        end;
      end;
    end
    else
      Chk('PG1 psql ciktisi okundu', False, err);
  end
  else
    WriteLn('NOT-RUN pg-live | canli PostgreSQL karsilastirmasi kosmadi ',
      '(--pg=<dosya> verilmedi)');

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL; pg=',
    BoolToStr(pgFrom <> '', 'live', 'not-run'));
  if GFail <> 0 then
    Halt(1);
end.
