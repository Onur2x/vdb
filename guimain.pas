unit guimain;

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls,
  Grids, ComCtrls, VDbCore, VDbTable, VDbSql;

type
  TfrmVdb = class(TForm)
    edtDir: TEdit;
    Label1: TLabel;
    btnOpen: TButton;
    btnDemo: TButton;
    btnRefresh: TButton;
    btnCompact: TButton;
    btnBackup: TButton;
    btnVerify: TButton;
    chkAutoBackup: TCheckBox;
    chkAutoTx: TCheckBox;
    btnAddRecord: TButton;
    btnDelRecord: TButton;
    btnEditCell: TButton;
    lstTables: TListBox;
    grid: TStringGrid;
    memoSql: TMemo;
    btnRun: TButton;
    memoLog: TMemo;
    status: TStatusBar;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnOpenClick(Sender: TObject);
    procedure btnDemoClick(Sender: TObject);
    procedure btnRefreshClick(Sender: TObject);
    procedure btnCompactClick(Sender: TObject);
    procedure btnBackupClick(Sender: TObject);
    procedure btnVerifyClick(Sender: TObject);
    procedure chkAutoBackupClick(Sender: TObject);
    procedure chkAutoTxClick(Sender: TObject);
    procedure btnAddRecordClick(Sender: TObject);
    procedure btnDelRecordClick(Sender: TObject);
    procedure btnEditCellClick(Sender: TObject);
    procedure lstTablesClick(Sender: TObject);
    procedure btnRunClick(Sender: TObject);
  private
    FKv: TVDb;
    FTb: TVTableDb;
    FSq: TVSql;
    FOpen: Boolean;
    FTableName: string;
    FGridTable: Boolean;
    procedure Log(const S: string);
    procedure EnsureOpen;
    procedure RefreshTables;
    procedure ShowTable(const Tbl: string);
    procedure ShowResult(const R: TSqlResult; Ms: QWord);
    function QVal(const V: string; Ctype: Byte): string;
  public
  end;

var
  frmVdb: TfrmVdb;

implementation

{$R *.lfm}

procedure TfrmVdb.Log(const S: string);
begin
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + ' ' + S);
end;

procedure TfrmVdb.FormCreate(Sender: TObject);
begin
  grid.FixedCols := 0;
  grid.ColCount := 1;
  grid.RowCount := 1;
  grid.Cells[0, 0] := 'Tablo sec veya SQL calistir';
  memoSql.Text := 'SELECT * FROM kisi LIMIT 20';
  FKv := TVDb.Create;
  FKv.SyncWrite := False;
  FTb := TVTableDb.Create(FKv);
  FSq := TVSql.Create(FTb);
  { SYNC WRITE KAPALI: yazma aninda fsync yapilmaz; yazimlar
    BeginBatch/CommitBatch ile TEK fsync ile kalici olur. Boylece veri
    kaybi YOK (batch atomik), ama tek yazma ~0.33 ms yerine bedava.
    Kullanici BEGIN...COMMIT yazmazsa otomatik transaction devreye girer. }
  FSq.AutoTransaction := chkAutoTx.Checked;
  FOpen := False;
  status.Panels[0].Text := 'kapali';
  Log('SyncWrite = KAPALI + otomatik transaction (hizli ve atomik)');
end;

procedure TfrmVdb.FormDestroy(Sender: TObject);
begin
  try
    try FTb.Close; except end;
    if FOpen then FKv.Close;
  except
  end;
  FSq.Free;
  FTb.Free;
  FKv.Free;
end;

procedure TfrmVdb.EnsureOpen;
// Kutuya veritabani KLASORU ("D:\veritabani\db") veya DOSYASI
// ("D:\veritabani\db\satis.odb") yazilabilir; ikisi de calisir.
//
// Acilista otomatik butunluk denetimi (Verify) yapilir: kullanicinin
// verisi saglam mi diye bakmadan emin olabilsin. Yirtik kuyruk varsa
// motor zaten acilista kendini iyilestirir (Recover), Verify bunu
// "SAGLAM" olarak bildirir.
var
  d, tblDir, rep, bkp: string;
  okv: Boolean;
  ms: QWord;
begin
  if FOpen then Exit;
  d := Trim(edtDir.Text);
  if d = '' then raise Exception.Create('DB klasoru veya satis.odb dosyasi gir');
  if SameText(ExtractFileExt(d), '.odb') then
  begin
    tblDir := ExtractFileDir(d);
    if tblDir = '' then tblDir := '.';
    FKv.Open(d);          // dogrudan TEK dosya
    FTb.Open(tblDir);     // sema eski klasor yolundan okunur (yoksa gerekmez)
  end
  else
  begin
    FKv.Open(d);
    FTb.Open(d);
  end;
  FOpen := True;

  // Otomatik yedek: acilistan ONCE alinamaz (dosya kilitli), ama acik
  // durumda "bir onceki hali" .onceki.odb olarak saklanir. Boylece veri
  // elde edilirse geri donus mumkun olur.
  if chkAutoBackup.Checked then
  begin
    bkp := FKv.FilePath + '.onceki';
    try
      FKv.BackupTo(bkp);
      Log('otomatik yedek: ' + bkp);
    except
      on E: Exception do Log('otomatik yedek ALINAMADI: ' + E.Message);
    end;
  end;

  ms := GetTickCount64;
  rep := '';
  okv := FKv.Verify(rep);
  FOpen := True;
  if okv then
  begin
    status.Panels[0].Text := FKv.FilePath + '  SAGLAM  kayit=' +
      IntToStr(FTb.DataKeyCount) + '  (denetim ' + IntToStr(GetTickCount64 - ms) + ' ms)';
    Log('butunluk denetimi: SAGLAM - ' + rep);
  end
  else
  begin
    status.Panels[0].Text := FKv.FilePath + '  SORUNLU: ' + rep;
    Log('!! butunluk denetimi BASARISIZ: ' + rep);
    Log('   Motordan yedek alinabilir: <db>.onceki veya <db>.bak');
    Log('   Verinin durdugunu dogrulamak icin: <db>.onceki dosyasini ac');
  end;
  Log('acildi: ' + FKv.FilePath);
end;

function FileSizeKb(const P: string): Int64;
var
  ts: TFileStream;
begin
  Result := 0;
  if not FileExists(P) then Exit;
  ts := TFileStream.Create(P, fmOpenRead or fmShareDenyNone);
  try Result := ts.Size div 1024; finally ts.Free; end;
end;

procedure TfrmVdb.btnBackupClick(Sender: TObject);
// Kullanicinin istedigi yere tutarli yedek alir.
var
  dest: string;
  ms: QWord;
begin
  try
    EnsureOpen;
    dest := FKv.FilePath + '.yedek-' +
      FormatDateTime('yyyy-mm-dd_hhnnss', Now) + '.odb';
    ms := GetTickCount64;
    FKv.BackupTo(dest);
    Log('yedek alindi: ' + dest + '  (' +
      IntToStr(GetTickCount64 - ms) + ' ms, ' +
      IntToStr(FileSizeKb(dest)) + ' KB)');
    ShowMessage('Yedek alindi:' + #13#10 + dest);
  except
    on E: Exception do begin Log('YEDEK HATASI: ' + E.Message);
      ShowMessage('Yedek alinamadi:' + #13#10 + E.Message); end;
  end;
end;

procedure TfrmVdb.btnVerifyClick(Sender: TObject);
// Salt-okunur butunluk denetimi: baslik + her kaydin CRC + seq surekliligi.
var
  rep: string;
  ms: QWord;
  okv: Boolean;
begin
  try
    EnsureOpen;
    ms := GetTickCount64;
    rep := '';
    okv := FKv.Verify(rep);
    Log('VERIFY: ' + IntToStr(GetTickCount64 - ms) + ' ms - ' + rep);
    if okv then
      ShowMessage('Dosya saglam.' + #13#10 + rep)
    else
      ShowMessage('Sorun var:' + #13#10 + rep);
  except
    on E: Exception do begin Log('VERIFY HATASI: ' + E.Message);
      ShowMessage('Denetim hatasi: ' + E.Message); end;
  end;
end;

procedure TfrmVdb.chkAutoBackupClick(Sender: TObject);
begin
  if chkAutoBackup.Checked then Log('acilista otomatik yedek: ACIK')
  else Log('acilista otomatik yedek: KAPALI');
end;

procedure TfrmVdb.chkAutoTxClick(Sender: TObject);
// Coklu komut = tek transaction: tek fsync (hizli) + hata halinde
// hicbiri uygulanmaz (guvenli).
begin
  FSq.AutoTransaction := chkAutoTx.Checked;
  if chkAutoTx.Checked then
    Log('coklu komut tek transaction: ACIK (hizli + atomik)')
  else
    Log('coklu komut tek transaction: KAPALI (cumle basina ayri commit)');
end;

procedure TfrmVdb.btnOpenClick(Sender: TObject);
begin
  try
    if FOpen then begin FKv.Close; FOpen := False; end;
    EnsureOpen;
    RefreshTables;
  except
    on E: Exception do begin Log('HATA: ' + E.Message); ShowMessage('Hata: ' + E.Message); end;
  end;
end;

procedure TfrmVdb.RefreshTables;
var
  names: TStrArray;
  s: string;
begin
  EnsureOpen;
  lstTables.Clear;
  names := FTb.TableNames;
  for s in names do
    lstTables.Items.Add(s);
  status.Panels[0].Text := 'tablo=' + IntToStr(Length(names)) + ' kayit=' + IntToStr(FTb.DataKeyCount);
end;

procedure TfrmVdb.btnRefreshClick(Sender: TObject);
begin
  try
    RefreshTables;
    if lstTables.ItemIndex >= 0 then
      ShowTable(lstTables.Items[lstTables.ItemIndex]);
  except
    on E: Exception do Log('HATA: ' + E.Message);
  end;
end;

procedure TfrmVdb.btnCompactClick(Sender: TObject);
var
  ob, nb: Int64;
  t0: QWord;
begin
  try
    EnsureOpen;
    t0 := GetTickCount64;
    FKv.Compact(ob, nb);
    Log(Format('compact %d -> %d byte (%d ms), .bak birakildi', [ob, nb, GetTickCount64 - t0]));
    RefreshTables;
    if lstTables.ItemIndex >= 0 then
      ShowTable(lstTables.Items[lstTables.ItemIndex]);
  except
    on E: Exception do begin Log('COMPACT HATA: ' + E.Message); ShowMessage('Hata: ' + E.Message); end;
  end;
end;

function TfrmVdb.QVal(const V: string; Ctype: Byte): string;
begin
  if Ctype = VCT_STR then
    Result := '''' + StringReplace(V, '''', '''''', [rfReplaceAll]) + ''''
  else if Trim(V) = '' then
    raise Exception.Create('sayisal alana bos deger olmaz')
  else
    Result := Trim(V);
end;

procedure TfrmVdb.btnAddRecordClick(Sender: TObject);
var
  td: TTableDef;
  cnames, cvals: TStrArray;
  val: string;
  i: Integer;
begin
  try
    EnsureOpen;
    if lstTables.ItemIndex < 0 then raise Exception.Create('once soldan tablo sec');
    td := FTb.GetTable(lstTables.Items[lstTables.ItemIndex]);
    SetLength(cnames, 0);
    SetLength(cvals, 0);
    for i := 0 to High(td.Cols) do
    begin
      val := InputBox('Yeni kayit', td.Cols[i].Name + ' (bos=oto/NULL/varsayilan):', '');
      if Trim(val) = '' then Continue; // verilmedi: oto/NULL/DEFAULT isler
      SetLength(cnames, Length(cnames) + 1);
      SetLength(cvals, Length(cvals) + 1);
      cnames[High(cnames)] := td.Cols[i].Name;
      cvals[High(cvals)] := val;
    end;
    FTb.Insert(td.Name, cnames, cvals);
    Log('eklendi');
    ShowTable(td.Name);
  except
    on E: Exception do begin Log('EKLE HATA: ' + E.Message); ShowMessage('Hata: ' + E.Message); end;
  end;
end;

procedure TfrmVdb.btnDelRecordClick(Sender: TObject);
var
  td: TTableDef;
  pk: string;
begin
  try
    EnsureOpen;
    if not FGridTable or (FTableName = '') then
      raise Exception.Create('once soldan tablo sec (SQL sonucu degil)');
    if grid.Row < 1 then raise Exception.Create('once gridde satir sec');
    td := FTb.GetTable(FTableName);
    pk := grid.Cells[td.PkIndex, grid.Row];
    if MessageDlg('Kayit silinsin mi?', td.Cols[td.PkIndex].Name + '=' + pk,
      mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
    if not FTb.Delete(td.Name, pk) then
      raise Exception.Create('silinemedi: ' + pk);
    Log('silindi: ' + pk);
    ShowTable(td.Name);
  except
    on E: Exception do begin Log('SIL HATA: ' + E.Message); ShowMessage('Hata: ' + E.Message); end;
  end;
end;

procedure TfrmVdb.btnEditCellClick(Sender: TObject);
var
  td: TTableDef;
  ci: Integer;
  nv, pk, sql: string;
  r: TSqlResult;
begin
  try
    EnsureOpen;
    if not FGridTable or (FTableName = '') then
      raise Exception.Create('once soldan tablo sec (SQL sonucu degil)');
    if grid.Row < 1 then raise Exception.Create('once gridde satir sec');
    td := FTb.GetTable(FTableName);
    ci := grid.Col;
    if (ci < 0) or (ci > High(td.Cols)) then raise Exception.Create('hucre sec');
    if ci = td.PkIndex then raise Exception.Create('PK duzenlenemez');
    nv := InputBox('Duzenle', td.Cols[ci].Name, grid.Cells[ci, grid.Row]);
    pk := grid.Cells[td.PkIndex, grid.Row];
    sql := 'UPDATE ' + td.Name + ' SET ' + td.Cols[ci].Name + '=' + QVal(nv, td.Cols[ci].Ctype) +
      ' WHERE ' + td.Cols[td.PkIndex].Name + '=' + QVal(pk, td.Cols[td.PkIndex].Ctype);
    r := FSq.Exec(sql);
    Log('guncellendi affected=' + IntToStr(r.Affected));
    ShowTable(td.Name);
  except
    on E: Exception do begin Log('DUZENLE HATA: ' + E.Message); ShowMessage('Hata: ' + E.Message); end;
  end;
end;

procedure TfrmVdb.ShowTable(const Tbl: string);
var
  td: TTableDef;
  pks: TStrArray;
  rows: TStrMatrix;
  i, j: Integer;
begin
  td := FTb.GetTable(Tbl);
  FTb.ScanRows(Tbl, pks, rows);
  grid.BeginUpdate;
  try
    grid.ColCount := Length(td.Cols);
    grid.RowCount := Length(rows) + 1;
    for j := 0 to High(td.Cols) do
      grid.Cells[j, 0] := td.Cols[j].Name;
    for i := 0 to High(rows) do
      for j := 0 to High(rows[i]) do
        grid.Cells[j, i + 1] := rows[i][j];
  finally
    grid.EndUpdate;
  end;
  Log(Format('tablo %s: %d satir', [Tbl, Length(rows)]));
  FTableName := Tbl;
  FGridTable := True;
end;

procedure TfrmVdb.lstTablesClick(Sender: TObject);
begin
  try
    if lstTables.ItemIndex < 0 then Exit;
    EnsureOpen;
    ShowTable(lstTables.Items[lstTables.ItemIndex]);
  except
    on E: Exception do Log('HATA: ' + E.Message);
  end;
end;

procedure TfrmVdb.ShowResult(const R: TSqlResult; Ms: QWord);
var
  i, j: Integer;
begin
  if Length(R.Fields) > 0 then
  begin
    grid.BeginUpdate;
    try
      grid.ColCount := Length(R.Fields);
      grid.RowCount := Length(R.Rows) + 1;
      for j := 0 to High(R.Fields) do
        grid.Cells[j, 0] := R.Fields[j];
      for i := 0 to High(R.Rows) do
        for j := 0 to High(R.Rows[i]) do
          grid.Cells[j, i + 1] := R.Rows[i][j];
    finally
      grid.EndUpdate;
    end;
  end;
  Log(Format('SQL %d ms, satir=%d, affected=%d %s', [Ms, Length(R.Rows), R.Affected, R.Msg]));
  status.Panels[1].Text := Format('%d satir (%d ms)', [Length(R.Rows), Ms]);
  FGridTable := False;
end;

procedure TfrmVdb.btnRunClick(Sender: TObject);
var
  r: TSqlResult;
  t0: QWord;
begin
  try
    EnsureOpen;
    t0 := GetTickCount64;
    // Exec, ';' ile ayrilmis TUM cumleleri isler (Affected toplam).
    r := FSq.Exec(memoSql.Text);
    // SQL ile veritabani DEGISTIRILMIS/ KAPATILMIS olabilir
    // (OPEN DATABASE / USE / CLOSE DATABASE). Arayuzu buna gore tazele.
    if not FKv.IsOpen then
    begin
      FOpen := False;
      lstTables.Clear;
      grid.ColCount := 1;
      grid.RowCount := 1;
      grid.Cells[0, 0] := '(veritabani kapali)';
      status.Panels[0].Text := 'kapali';
      Log('veritabani kapandi: ' + r.Msg);
      ShowMessage(r.Msg);
      Exit;
    end;
    status.Panels[0].Text := FKv.FilePath + '  acik';
    RefreshTables;
    // INSERT/UPDATE/DELETE/DDL satIR DONDURMEZ; sonuc bos gelir.
    // O zaman ekranda gosterilecek sey degisikligin kendisidir:
    // dokunulan tabloyu yeniden ciz. (Eskide bu durumda grid eski
    // icerigi gosteriyordu, kullanici "tek satir okuyor" sanirdi.)
    if (Length(r.Fields) = 0) and (r.LastTable <> '') and
       FTb.TableExists(r.LastTable) then
    begin
      ShowTable(r.LastTable);
      Log(Format('SQL %d ms, %d komut, affected=%d -> %s tablosu yeniden cizildi',
        [GetTickCount64 - t0, r.Stmts, r.Affected, r.LastTable]));
      status.Panels[1].Text := Format('%d komut, affected=%d',
        [r.Stmts, r.Affected]);
    end
    else
    begin
      ShowResult(r, GetTickCount64 - t0);
    end;
  except
    on E: Exception do begin Log('SQL HATA: ' + E.Message); ShowMessage('SQL Hata: ' + E.Message); end;
  end;
end;

procedure TfrmVdb.btnDemoClick(Sender: TObject);
var
  cols: TColArray;
  i: Integer;
  t0: QWord;
begin
  try
    EnsureOpen;
    if not FTb.TableExists('kisi') then
    begin
      SetLength(cols, 3);
      cols[0].Name := 'id'; cols[0].Ctype := VCT_INT;
      cols[1].Name := 'ad'; cols[1].Ctype := VCT_STR;
      cols[2].Name := 'yas'; cols[2].Ctype := VCT_INT;
      FTb.CreateTable('kisi', cols, 0, nil, []);
      Log('kisi tablosu kuruldu');
    end;
    t0 := GetTickCount64;
    FTb.BeginBatch;
    try
      for i := 1 to 5000 do
        FTb.Insert('kisi', ['id', 'ad', 'yas'],
          [IntToStr(i), 'Ad' + IntToStr(i), IntToStr(20 + (i mod 40))]);
      FTb.CommitBatch;
    except
      FTb.AbortBatch; raise;
    end;
    Log(Format('5000 kayit %d ms (tek fsync)', [GetTickCount64 - t0]));
    RefreshTables;
    memoSql.Text := 'SELECT * FROM kisi LIMIT 20';
    btnRunClick(nil);
  except
    on E: Exception do begin Log('DEMO HATA: ' + E.Message); ShowMessage('Hata: ' + E.Message); end;
  end;
end;

end.
