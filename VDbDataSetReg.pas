unit VDbDataSetReg;

{ P4b-4: tasarim-zamani kaydi. vdbdataset.lpk su an RunTime tiptedir
  (uygulamalar bagimlilik olarak kullanir). Palete kurmak icin IDE'de
  paketi RunAndDesignTime yapip derlemek yeterlidir; bu birimdeki
  Register proseduru TVDbQuery'yi 'VDb' sayfasina ekler. }

{$mode delphi}

interface

uses
  Classes, VDbDataSet;

procedure Register;

implementation

procedure Register;
begin
  RegisterComponents('VDb', [TVDbQuery]);
end;

end.
