unit VDbCpuProf;

{ v3.30 SPRINT B/5: gecici commit CPU profili.
  Yalnizca -dCPUPROF ile derlenen araclar kullanir; normal surum bu birimi
  hicbir zaman kullanmaz. Amacli: cpubench'in 152 us/commit'ini bilesenlere
  bolmek (fsync CPU'su dâhil, GetProcessTimes). }

{$mode delphi}{$H+}

interface

{$IFDEF CPUPROF}
function CpuProfNow: Int64;
var
  CP: array[0..9] of Int64;
  CPN: Int64 = 0;

procedure CpuProfDump;
{$ENDIF}

implementation

{$IFDEF CPUPROF}
uses
  Windows, SysUtils;

function CpuProfNow: Int64;
var
  c, e, k, u: TFileTime;
begin
  GetProcessTimes(GetCurrentProcess, c, e, k, u);
  Result := (Int64(k.dwHighDateTime) shl 32 + k.dwLowDateTime +
             Int64(u.dwHighDateTime) shl 32 + u.dwLowDateTime) div 10;
end;

procedure CpuProfDump;
var
  i: Integer;
const
  NM: array[0..9] of string = ('hazirlik+kilit+uygulama', 'wal', 'gunluk',
    'checkpoint', 'fsync', 'birakis', 'motor:frame', 'motor:wal',
    'motor:end', 'motor:atla');
begin
  WriteLn('--- CPUPROF (us/commit, N=', CPN, ') ---');
  if CPN = 0 then Exit;
  for i := 0 to 9 do
    if CP[i] <> 0 then
      WriteLn(Format('%-26s: %8.2f', [NM[i], CP[i] / CPN]));
end;
{$ENDIF}

end.