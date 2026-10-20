unit haddlg;

{ VDb Manager yardimci diyaloglari:
  Yeni Tablo sihirbazi (grid tabanli sutun editoru),
  Sutun Ekle, Yeni Veritabani. ASCII-Turkce (kodlama sorunu cikarmaz). }

{$mode delphi}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, Grids,
  ExtCtrls, VDbTable, VDbJson, VDbTypes;

function NewTableDlg(out TblName: string; out Cols: TColArray;
  out PkIndex: Integer): Boolean;
function AddColumnDlg(out Col: TColDef): Boolean;
function NewDbDlg(out DbName: string): Boolean;

implementation

type
  TfrmNewTable = class(TForm)
    procedure btnAddClick(Sender: TObject);
    procedure btnDelClick(Sender: TObject);
    procedure btnOkClick(Sender: TObject);
  private
    edName: TEdit;
    sg: TStringGrid;
    btnAdd, btnDel, btnOk, btnCancel: TButton;
    lblHint: TLabel;
  public
    TblName: string;
    Cols: TColArray;
    PkIndex: Integer;
    Accepted: Boolean;
    constructor Create(TheOwner: TComponent); override;
  end;

constructor TfrmNewTable.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  Width := 640;
  Height := 420;
  Position := poScreenCenter;
  Caption := 'Yeni Tablo';
  Accepted := False;

  edName := TEdit.Create(Self);
  edName.Parent := Self;
  edName.Align := alTop;
  edName.Height := 28;
  edName.Text := 'yeni_tablo';

  lblHint := TLabel.Create(Self);
  lblHint.Parent := Self;
  lblHint.Align := alTop;
  lblHint.Height := 30;
  lblHint.Caption := 'Tip: INTEGER TEXT FLOAT BOOLEAN DATE DATETIME TIME BLOB  |  PK/NN/UQ icin E yazin';

  sg := TStringGrid.Create(Self);
  sg.Parent := Self;
  sg.Align := alClient;
  sg.FixedRows := 1;
  sg.ColCount := 6;
  sg.RowCount := 3;
  sg.Cells[0,0] := 'Sutun';
  sg.Cells[1,0] := 'Tip';
  sg.Cells[2,0] := 'PK';
  sg.Cells[3,0] := 'NN';
  sg.Cells[4,0] := 'UQ';
  sg.Cells[5,0] := 'Varsayilan';
  sg.Cells[0,1] := 'id';
  sg.Cells[1,1] := 'INTEGER';
  sg.Cells[2,1] := 'E';
  sg.Cells[0,2] := 'ad';
  sg.Cells[1,2] := 'TEXT';

  btnOk := TButton.Create(Self);
  btnOk.Parent := Self;
  btnOk.Align := alBottom;
  btnOk.Height := 30;
  btnOk.Caption := 'Olustur';
  btnOk.ModalResult := mrNone;
  btnOk.OnClick := btnOkClick;

  btnCancel := TButton.Create(Self);
  btnCancel.Parent := Self;
  btnCancel.Align := alBottom;
  btnCancel.Height := 30;
  btnCancel.Caption := 'Vazgec';
  btnCancel.ModalResult := mrCancel;

  btnDel := TButton.Create(Self);
  btnDel.Parent := Self;
  btnDel.Align := alBottom;
  btnDel.Height := 30;
  btnDel.Caption := 'Sutun Sil';
  btnDel.OnClick := btnDelClick;

  btnAdd := TButton.Create(Self);
  btnAdd.Parent := Self;
  btnAdd.Align := alBottom;
  btnAdd.Height := 30;
  btnAdd.Caption := 'Sutun Ekle';
  btnAdd.OnClick := btnAddClick;
end;

procedure TfrmNewTable.btnAddClick(Sender: TObject);
begin
  sg.RowCount := sg.RowCount + 1;
end;

procedure TfrmNewTable.btnDelClick(Sender: TObject);
begin
  if sg.RowCount > 2 then
    sg.RowCount := sg.RowCount - 1;
end;

procedure TfrmNewTable.btnOkClick(Sender: TObject);
var
  i, j: Integer;
  nm: string;
begin
  TblName := LowerCase(Trim(edName.Text));
  if TblName = '' then
  begin
    ShowMessage('Tablo adi bos olamaz.');
    Exit;
  end;
  SetLength(Cols, 0);
  PkIndex := -1;
  for i := 1 to sg.RowCount - 1 do
  begin
    nm := LowerCase(Trim(sg.Cells[0, i]));
    if nm = '' then Continue;
    for j := 0 to High(Cols) do
      if Cols[j].Name = nm then
      begin
        ShowMessage('Sutun adi tekrarlandi: ' + nm);
        Exit;
      end;
    SetLength(Cols, Length(Cols) + 1);
    Cols[High(Cols)].Name := nm;
    Cols[High(Cols)].Ctype := VDbCtypeByName(sg.Cells[1, i]);
    Cols[High(Cols)].NotNull := UpperCase(Trim(sg.Cells[3, i])) = 'E';
    Cols[High(Cols)].Unique := UpperCase(Trim(sg.Cells[4, i])) = 'E';
    Cols[High(Cols)].HasDef := Trim(sg.Cells[5, i]) <> '';
    Cols[High(Cols)].Def := Trim(sg.Cells[5, i]);
    if UpperCase(Trim(sg.Cells[2, i])) = 'E' then
    begin
      if PkIndex >= 0 then
      begin
        // Iki sutun birden PRIMARY KEY isaretlenmis. Motor tek PK destekler;
        // sessizce ilkini almak yaniltici olur, kullaniciyi uyar.
        ShowMessage('Birden fazla sutun PRIMARY KEY isaretlenmis.' + LineEnding +
          'Yalnizca ilk isaretli sutun PK olur: ' + Cols[PkIndex].Name);
      end
      else
        PkIndex := High(Cols);
    end;
  end;
  if Length(Cols) = 0 then
  begin
    ShowMessage('En az bir sutun gerekli.');
    Exit;
  end;
  // PK isaretlenmemisse PkIndex = -1 kalir (PK YOK).
  // 2026-10-04: once burada `PkIndex := 0` ile ilk sutun zorla PRIMARY KEY
  // yapiliyordu; boylece yonetimden PK'siz tablo olusturmak MUMKUN DEGILDI
  // ve kullanici seçmediği halde bir kısıt uygulanıyordu (motor F2-22'de
  // aynı hatayı düzeltti).
  Accepted := True;
  ModalResult := mrOk;
end;

function NewTableDlg(out TblName: string; out Cols: TColArray;
  out PkIndex: Integer): Boolean;
var
  f: TfrmNewTable;
begin
  Result := False;
  f := TfrmNewTable.Create(nil);
  try
    if f.ShowModal = mrOk then
    begin
      TblName := f.TblName;
      Cols := f.Cols;
      PkIndex := f.PkIndex;
      Result := True;
    end;
  finally
    f.Free;
  end;
end;

type
  TfrmAddCol = class(TForm)
  private
    edName, edDef: TEdit;
    cbTip: TComboBox;
    chkNN, chkUQ: TCheckBox;
  public
    Col: TColDef;
    Accepted: Boolean;
    constructor Create(TheOwner: TComponent); override;
  end;

constructor TfrmAddCol.Create(TheOwner: TComponent);
var
  y: Integer;

  function Lab(const C: string; Top: Integer): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := Self;
    Result.Left := 12;
    Result.Top := Top + 4;
    Result.Caption := C;
  end;

begin
  inherited Create(TheOwner);
  Width := 360;
  Height := 260;
  Position := poScreenCenter;
  Caption := 'Sutun Ekle';
  Accepted := False;
  y := 12;
  Lab('Sutun adi:', y);
  edName := TEdit.Create(Self);
  edName.Parent := Self;
  edName.SetBounds(110, y, 220, 24);
  Inc(y, 32);
  Lab('Tip:', y);
  cbTip := TComboBox.Create(Self);
  cbTip.Parent := Self;
  cbTip.SetBounds(110, y, 220, 24);
  cbTip.Style := csDropDownList;
  cbTip.Items.Add('INTEGER');
  cbTip.Items.Add('TEXT');
  cbTip.Items.Add('FLOAT');
  cbTip.Items.Add('BOOLEAN');
  cbTip.Items.Add('DATE');
  cbTip.Items.Add('DATETIME');
  cbTip.Items.Add('TIME');
  cbTip.Items.Add('BLOB');
  cbTip.ItemIndex := 1;
  Inc(y, 32);
  chkNN := TCheckBox.Create(Self);
  chkNN.Parent := Self;
  chkNN.SetBounds(110, y, 220, 24);
  chkNN.Caption := 'NOT NULL';
  Inc(y, 28);
  chkUQ := TCheckBox.Create(Self);
  chkUQ.Parent := Self;
  chkUQ.SetBounds(110, y, 220, 24);
  chkUQ.Caption := 'UNIQUE';
  Inc(y, 32);
  Lab('Varsayilan:', y);
  edDef := TEdit.Create(Self);
  edDef.Parent := Self;
  edDef.SetBounds(110, y, 220, 24);
  with TButton.Create(Self) do
  begin
    Parent := Self;
    SetBounds(110, 196, 100, 28);
    Caption := 'Ekle';
    ModalResult := mrOk;
  end;
  with TButton.Create(Self) do
  begin
    Parent := Self;
    SetBounds(220, 196, 100, 28);
    Caption := 'Vazgec';
    ModalResult := mrCancel;
  end;
end;

function AddColumnDlg(out Col: TColDef): Boolean;
var
  f: TfrmAddCol;
begin
  Result := False;
  f := TfrmAddCol.Create(nil);
  try
    if f.ShowModal = mrOk then
    begin
      if Trim(f.edName.Text) = '' then
      begin
        ShowMessage('Sutun adi bos olamaz.');
        Exit;
      end;
      Col.Name := LowerCase(Trim(f.edName.Text));
      Col.Ctype := VDbCtypeByName(f.cbTip.Text);
      Col.NotNull := f.chkNN.Checked;
      Col.Unique := f.chkUQ.Checked;
      Col.HasDef := Trim(f.edDef.Text) <> '';
      Col.Def := Trim(f.edDef.Text);
      Result := True;
    end;
  finally
    f.Free;
  end;
end;

type
  TfrmNewDb = class(TForm)
  private
    edName: TEdit;
  public
    DbName: string;
    constructor Create(TheOwner: TComponent); override;
  end;

constructor TfrmNewDb.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  Width := 340;
  Height := 150;
  Position := poScreenCenter;
  Caption := 'Yeni Veritabani';
  edName := TEdit.Create(Self);
  edName.Parent := Self;
  edName.SetBounds(12, 12, 300, 26);
  with TButton.Create(Self) do
  begin
    Parent := Self;
    SetBounds(120, 60, 90, 28);
    Caption := 'Olustur';
    ModalResult := mrOk;
  end;
  with TButton.Create(Self) do
  begin
    Parent := Self;
    SetBounds(220, 60, 90, 28);
    Caption := 'Vazgec';
    ModalResult := mrCancel;
  end;
end;

function NewDbDlg(out DbName: string): Boolean;
var
  f: TfrmNewDb;
begin
  Result := False;
  f := TfrmNewDb.Create(nil);
  try
    if f.ShowModal = mrOk then
    begin
      DbName := Trim(f.edName.Text);
      Result := DbName <> '';
    end;
  finally
    f.Free;
  end;
end;

end.
