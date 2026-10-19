program evtest;
{$mode delphi}
uses SysUtils, Classes, Windows;

var
  Ev: PRTLEvent;
  Woke: Integer;

type
  TW = class(TThread)
  public
    procedure Execute; override;
  end;

procedure TW.Execute;
begin
  RTLEventWaitFor(Ev, 3000);
  InterlockedIncrement(Woke);
end;

var
  T: array[0..7] of TW;
  i: Integer;
begin
  Ev := RTLEventCreate;
  Woke := 0;
  for i := 0 to 7 do T[i] := TW.Create(False);
  Sleep(300);
  RTLEventSetEvent(Ev);
  Sleep(1000);
  Writeln('Tek SetEvent sonrasi uyanan isci = ', Woke, ' / 8');
  for i := 0 to 7 do
  begin
    T[i].WaitFor;
    T[i].Free;
  end;
  RTLEventDestroy(Ev);
end.
