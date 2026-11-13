library vdbapi;

{ VDb Engine - DLL (C ABI)
  ---------------------------------------------------------------------------
  Bu kutuphane VDb motorunu dis dunyaya acar. Delphi, C#, Python, C, Rust
  ve her turlu dil cagirabilir: cagri kurali stdcall'dir, metinler UTF-8 ve
  NUL sonludur, veriler ham bayt dizisidir.

  DLL'i cagirmak icin once surumu sor:
      unsigned v = VdbApiVersion();     // beklenen: 0x00010000 (1.0)

  Butun hatalar VDB_OK (0) disinda bir kod doner; ayrinti metni
  VdbLastError() ile alinir. Istisna DLL sinirini GECMEZ.

  ONEMLI: ayni veritabani dosyasi ayni anda TEK islem tarafindan
  acilabilir. VdbOpen bunu dener ve kilitli ise VDB_E_OPEN doner.

  ---------------------------------------------------------------------------
  NEDEN BU DOSYA BIR SARMALAYICI KATMANI?

  FPC iki kisit koyar:

  1) Bir kutuphanede semboller VARSAYILAN OLARAK disa aktarilmaz.
  2) `exports` yazimi YALnizCA kutuphanenin KENDI dosyasinda tanimli
     sembolleri aktarabilir. Baska birimdeki (vdbapi_core.pas) bir
     fonksiyonu export etmek mumkun DEGIL.

  Bu yuzden asagida her API icin bir satirlik bir sarmalayici (wrapper)
  vardir: vdbapi_core'deki asil uygulamayi cagirir, disa kendi adiyle
  export edilir. Gercek mantik vdbapi_core.pas'tadir; buradaki
  sarmalayicilarin tek islevi FPC'nin bu kisitini asmaktir.

  DIKKAT: `exports ... name 'X'` yaziminda verilen 'X' ASIL disa
  aktarilan isimdir. Otomatik denetleyicinin gormedigi icin liste
  vdbapi.h ve vdbapitest.lpr ile birebir ayni olmak ZORUNDADIR.
}

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  { R-14 Full: Unix'te TThread yalnizca cthreads baglaninca calisir;
    kutuphane kendi icinde acip kapatabildigi icin burada baglamak
    zorunludur (programlari buna zorlayamazsin). Windows'ta gerek yok. }
  cthreads,
  {$ENDIF}
  vdbapi_core;

{ Asagidaki sarmalayicilarin imzalari vdbapi_core.pas ile birebir ayni
  olmak ZORUNDA. stdcall cagri kurali ve LongWord/LongInt/Int64
  genislikleri ABI'nin bir parcasidir; biri kayarsa DLL sessizce bozulur. }

function VdbApiVersion: LongWord; stdcall;
begin
  Result := Core_VdbApiVersion;
end;

function VdbVersion: PAnsiChar; stdcall;
begin
  Result := Core_VdbVersion;
end;

function VdbLastError: PAnsiChar; stdcall;
begin
  Result := Core_VdbLastError;
end;

function VdbLastErrorCodeGet: LongInt; stdcall;
begin
  Result := Core_VdbLastErrorCodeGet;
end;

procedure VdbSetLastErrorCode(AErr: LongInt); stdcall;
begin
  Core_VdbSetLastErrorCode(AErr);
end;

function VdbOpen(APath: PAnsiChar; ASyncWrite: LongInt): LongWord; stdcall;
begin
  Result := Core_VdbOpen(APath, ASyncWrite);
end;

procedure VdbClose(AHandle: LongWord); stdcall;
begin
  Core_VdbClose(AHandle);
end;

procedure VdbCloseAll; stdcall;
begin
  Core_VdbCloseAll;
end;

function VdbCount(AHandle: LongWord): LongInt; stdcall;
begin
  Result := Core_VdbCount(AHandle);
end;

function VdbPut(AHandle: LongWord; AKey: Int64; AData: PByte;
  ALen: LongInt): LongInt; stdcall;
begin
  Result := Core_VdbPut(AHandle, AKey, AData, ALen);
end;

function VdbGet(AHandle: LongWord; AKey: Int64; AData: PByte;
  ALen: LongInt): LongInt; stdcall;
begin
  Result := Core_VdbGet(AHandle, AKey, AData, ALen);
end;

function VdbExists(AHandle: LongWord; AKey: Int64): LongInt; stdcall;
begin
  Result := Core_VdbExists(AHandle, AKey);
end;

function VdbDelete(AHandle: LongWord; AKey: Int64): LongInt; stdcall;
begin
  Result := Core_VdbDelete(AHandle, AKey);
end;

function VdbKeys(AHandle: LongWord; AOut: PInt64; AMax: LongInt): LongInt; stdcall;
begin
  Result := Core_VdbKeys(AHandle, AOut, AMax);
end;

procedure VdbFlush(AHandle: LongWord); stdcall;
begin
  Core_VdbFlush(AHandle);
end;

function VdbExec(AHandle: LongWord; ASql: PAnsiChar;
  AFlags: LongInt): LongWord; stdcall;
begin
  Result := Core_VdbExec(AHandle, ASql, AFlags);
end;

function VdbResultFieldCount(AHandle: LongWord): LongInt; stdcall;
begin
  Result := Core_VdbResultFieldCount(AHandle);
end;

function VdbResultRowCount(AHandle: LongWord): LongInt; stdcall;
begin
  Result := Core_VdbResultRowCount(AHandle);
end;

function VdbResultFieldName(AHandle: LongWord; ACol: LongInt): PAnsiChar; stdcall;
begin
  Result := Core_VdbResultFieldName(AHandle, ACol);
end;

function VdbResultValue(AHandle: LongWord; ARow, ACol: LongInt): PAnsiChar; stdcall;
begin
  Result := Core_VdbResultValue(AHandle, ARow, ACol);
end;

function VdbResultAffected(AHandle: LongWord): LongInt; stdcall;
begin
  Result := Core_VdbResultAffected(AHandle);
end;

function VdbResultStmts(AHandle: LongWord): LongInt; stdcall;
begin
  Result := Core_VdbResultStmts(AHandle);
end;

function VdbResultMessage(AHandle: LongWord): PAnsiChar; stdcall;
begin
  Result := Core_VdbResultMessage(AHandle);
end;

function VdbResultLastTable(AHandle: LongWord): PAnsiChar; stdcall;
begin
  Result := Core_VdbResultLastTable(AHandle);
end;

procedure VdbResultFree(AHandle: LongWord); stdcall;
begin
  Core_VdbResultFree(AHandle);
end;

function VdbVerify(AHandle: LongWord; AReport: PAnsiChar;
  AMax: LongInt): LongInt; stdcall;
begin
  Result := Core_VdbVerify(AHandle, AReport, AMax);
end;

function VdbWalHas(AHandle: LongWord): LongInt; stdcall;
begin
  Result := Core_VdbWalHas(AHandle);
end;

function VdbWalRecordCount(AHandle: LongWord): LongInt; stdcall;
begin
  Result := Core_VdbWalRecordCount(AHandle);
end;

function VdbWalWrite(AHandle: LongWord; AKey: Int64; AData: PByte;
  ALen: LongInt): LongInt; stdcall;
begin
  Result := Core_VdbWalWrite(AHandle, AKey, AData, ALen);
end;

function VdbWalWriteDelete(AHandle: LongWord; AKey: Int64): LongInt; stdcall;
begin
  Result := Core_VdbWalWriteDelete(AHandle, AKey);
end;

function VdbWalReplay(AHandle: LongWord): LongInt; stdcall;
begin
  Result := Core_VdbWalReplay(AHandle);
end;

function VdbWalCheckpoint(AHandle: LongWord): LongInt; stdcall;
begin
  Result := Core_VdbWalCheckpoint(AHandle);
end;

function VdbWalSetAuto(AHandle: LongWord; AEnable: LongInt): LongInt; stdcall;
begin
  Result := Core_VdbWalSetAuto(AHandle, AEnable);
end;

function VdbWalIsAuto(AHandle: LongWord): LongInt; stdcall;
begin
  Result := Core_VdbWalIsAuto(AHandle);
end;

function VdbWalAutoCount(AHandle: LongWord): LongInt; stdcall;
begin
  Result := Core_VdbWalAutoCount(AHandle);
end;

function VdbFileSize(AHandle: LongWord): Int64; stdcall;
begin
  Result := Core_VdbFileSize(AHandle);
end;

function VdbDeadBytes(AHandle: LongWord): Int64; stdcall;
begin
  Result := Core_VdbDeadBytes(AHandle);
end;

function VdbAutoCompact(AHandle: LongWord; AOld, ANew: PInt64): LongInt; stdcall;
begin
  Result := Core_VdbAutoCompact(AHandle, AOld, ANew);
end;

function VdbEncryptEnable(AHandle: LongWord; AKey: PByte; ALen: LongInt): LongInt; stdcall;
begin Result := Core_VdbEncryptEnable(AHandle, AKey, ALen); end;

function VdbEncryptDisable(AHandle: LongWord): LongInt; stdcall;
begin Result := Core_VdbEncryptDisable(AHandle); end;

function VdbEncryptIsEncrypted(AHandle: LongWord): LongInt; stdcall;
begin Result := Core_VdbEncryptIsEncrypted(AHandle); end;

function VdbEncryptCreateKeyFile(AHandle: LongWord; APath, APassword: PAnsiChar): LongInt; stdcall;
begin Result := Core_VdbEncryptCreateKeyFile(AHandle, APath, APassword); end;

function VdbEncryptOpenKeyFile(AHandle: LongWord; APath, APassword: PAnsiChar): LongInt; stdcall;
begin Result := Core_VdbEncryptOpenKeyFile(AHandle, APath, APassword); end;

function VdbEncryptKeyPath(AHandle: LongWord; ABuf: PAnsiChar; AMax: LongInt): LongInt; stdcall;
begin Result := Core_VdbEncryptKeyPath(AHandle, ABuf, AMax); end;

function VdbEncryptFingerprint(AHandle: LongWord; ABuf: PAnsiChar; AMax: LongInt): LongInt; stdcall;
begin Result := Core_VdbEncryptFingerprint(AHandle, ABuf, AMax); end;

function VdbHasEncryptedRecords(AHandle: LongWord): LongInt; stdcall;
begin Result := Core_VdbHasEncryptedRecords(AHandle); end;

function VdbRekeyWithPassword(AHandle: LongWord; ANewPassword: PAnsiChar): LongInt; stdcall;
begin Result := Core_VdbRekeyWithPassword(AHandle, ANewPassword); end;

{ ---- CDC / Time Travel (2026-10-06, poll modu; ayrinti vdbapi.h) ---- }
function VdbCdcStart(AHandle: LongWord): LongInt; stdcall;
begin Result := Core_VdbCdcStart(AHandle); end;

function VdbCdcStop(AHandle: LongWord): LongInt; stdcall;
begin Result := Core_VdbCdcStop(AHandle); end;

function VdbCdcPollSize(AHandle: LongWord): LongInt; stdcall;
begin Result := Core_VdbCdcPollSize(AHandle); end;

function VdbCdcPoll(AHandle: LongWord; ABuf: PAnsiChar; ALen: LongInt): LongInt; stdcall;
begin Result := Core_VdbCdcPoll(AHandle, ABuf, ALen); end;

function VdbCdcStats(AHandle: LongWord; AEvents, ASkipped, APending,
  ADropped: PInteger): LongInt; stdcall;
begin Result := Core_VdbCdcStats(AHandle, AEvents, ASkipped, APending, ADropped); end;

function VdbValueAt(AHandle: LongWord; ATable, APk: PAnsiChar; ASeq: LongInt;
  ABuf: PAnsiChar; ALen: LongInt): LongInt; stdcall;
begin Result := Core_VdbValueAt(AHandle, ATable, APk, ASeq, ABuf, ALen); end;

function VdbHistoryCount(AHandle: LongWord): LongInt; stdcall;
begin Result := Core_VdbHistoryCount(AHandle); end;

{ ---- R-14 Full: Paralel havuz yonetimi ---- }

function VdbParallelInit(AMaxWorkers: LongInt): LongInt; stdcall;
begin Result := Core_VdbParallelInit(AMaxWorkers); end;

function VdbParallelWorkers: LongInt; stdcall;
begin Result := Core_VdbParallelWorkers; end;

function VdbParallelShutdown: LongInt; stdcall;
begin Result := Core_VdbParallelShutdown; end;

exports
  VdbApiVersion       name 'VdbApiVersion',
  VdbVersion          name 'VdbVersion',
  VdbLastError        name 'VdbLastError',
  VdbLastErrorCodeGet name 'VdbLastErrorCodeGet',
  VdbSetLastErrorCode name 'VdbSetLastErrorCode',
  VdbOpen             name 'VdbOpen',
  VdbClose            name 'VdbClose',
  VdbCloseAll         name 'VdbCloseAll',
  VdbCount            name 'VdbCount',
  VdbPut              name 'VdbPut',
  VdbGet              name 'VdbGet',
  VdbExists           name 'VdbExists',
  VdbDelete           name 'VdbDelete',
  VdbKeys             name 'VdbKeys',
  VdbFlush            name 'VdbFlush',
  VdbExec             name 'VdbExec',
  VdbResultFieldCount name 'VdbResultFieldCount',
  VdbResultRowCount   name 'VdbResultRowCount',
  VdbResultFieldName  name 'VdbResultFieldName',
  VdbResultValue      name 'VdbResultValue',
  VdbResultAffected   name 'VdbResultAffected',
  VdbResultStmts      name 'VdbResultStmts',
  VdbResultMessage    name 'VdbResultMessage',
  VdbResultLastTable  name 'VdbResultLastTable',
  VdbResultFree       name 'VdbResultFree',
  VdbVerify           name 'VdbVerify',
  VdbWalHas           name 'VdbWalHas',
  VdbWalRecordCount   name 'VdbWalRecordCount',
  VdbWalWrite         name 'VdbWalWrite',
  VdbWalWriteDelete   name 'VdbWalWriteDelete',
  VdbWalReplay        name 'VdbWalReplay',
  VdbWalCheckpoint    name 'VdbWalCheckpoint',
  VdbWalSetAuto       name 'VdbWalSetAuto',
  VdbWalIsAuto        name 'VdbWalIsAuto',
  VdbWalAutoCount     name 'VdbWalAutoCount',
  VdbFileSize         name 'VdbFileSize',
  VdbDeadBytes        name 'VdbDeadBytes',
  VdbAutoCompact      name 'VdbAutoCompact',
  VdbEncryptEnable    name 'VdbEncryptEnable',
  VdbEncryptDisable   name 'VdbEncryptDisable',
  VdbEncryptIsEncrypted name 'VdbEncryptIsEncrypted',
  VdbEncryptCreateKeyFile name 'VdbEncryptCreateKeyFile',
  VdbEncryptOpenKeyFile name 'VdbEncryptOpenKeyFile',
  VdbEncryptKeyPath   name 'VdbEncryptKeyPath',
  VdbEncryptFingerprint name 'VdbEncryptFingerprint',
  VdbHasEncryptedRecords name 'VdbHasEncryptedRecords',
  VdbRekeyWithPassword name 'VdbRekeyWithPassword',
  VdbCdcStart         name 'VdbCdcStart',
  VdbCdcStop          name 'VdbCdcStop',
  VdbCdcPollSize      name 'VdbCdcPollSize',
  VdbCdcPoll          name 'VdbCdcPoll',
  VdbCdcStats         name 'VdbCdcStats',
  VdbValueAt          name 'VdbValueAt',
  VdbHistoryCount     name 'VdbHistoryCount',
  VdbParallelInit     name 'VdbParallelInit',
  VdbParallelWorkers  name 'VdbParallelWorkers',
  VdbParallelShutdown name 'VdbParallelShutdown';

begin
  { Baslangicta motor tarafinda yapilacak bir sey yok; ilk VdbOpen
    motoru acar. }
end.
