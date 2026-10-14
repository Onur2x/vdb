{$MODE DELPHI}
{$H+}

program VDBWebApi;

uses
  Classes, SysUtils, SyncObjs, StrUtils,
  fphttpserver, httpdefs,
  fpjson, jsonparser,
  VDbSql, VDbTable, VDbAst, VDbTypes, VDbCore;

type
  TVDbConnection = class
    Kv: TVDb;
    TableDb: TVTableDb;
    Sql: TVSql;
    InUse: Boolean;
    LastUsed: TDateTime;
    constructor Create(const ADbDir, ADbName: string);
    destructor Destroy; override;
  end;

  TVDbPool = class
  private
    FPool: TList;
    FLock: TCriticalSection;
    FDbDir: string;
    FMaxCount: Integer;
  public
    constructor Create(const ADbDir: string; AMaxCount: Integer = 10);
    destructor Destroy; override;
    function Acquire(const ADbName: string = ''): TVDbConnection;
    procedure Release(AConn: TVDbConnection);
  end;

  TVDBRequestHandler = class
  private
    FPool: TVDbPool;
  public
    constructor Create(APool: TVDbPool);
    procedure HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
  end;

function ExtractDbName(const Path: string): string;
var
  P: string;
begin
  Result := '';
  if Path.StartsWith('/api/tables/') then
  begin
    P := Copy(Path, 13, Length(Path));
    Result := Copy(P, 1, Pos('/', P) - 1);
  end;
end;

function ExtractTableName(const Path: string): string;
var
  P: string;
  StartPos: Integer;
begin
  Result := '';
  if Path.StartsWith('/api/tables/') then
  begin
    P := Copy(Path, 13, Length(Path));
    StartPos := Pos('/', P) + 1;
    P := Copy(P, StartPos, Length(P));
    Result := Copy(P, 1, Pos('/', P) - 1);
  end;
end;

function StrArrayToJSONArray(const Arr: TStrArray): TJSONArray;
var
  i: Integer;
begin
  Result := TJSONArray.Create;
  for i := 0 to High(Arr) do
    Result.Add(Arr[i]);
end;

function SqlResultToJSON(const Res: TSqlResult): TJSONObject;
var
  JObj, JRow: TJSONObject;
  JArr: TJSONArray;
  i, j: Integer;
begin
  JObj := TJSONObject.Create;
  JArr := TJSONArray.Create;
  try
    for i := 0 to High(Res.Rows) do
    begin
      JRow := TJSONObject.Create;
      for j := 0 to High(Res.Fields) do
      begin
        if j < Length(Res.Rows[i]) then
          JRow.Add(Res.Fields[j], Res.Rows[i][j])
        else
          JRow.Add(Res.Fields[j], '');
      end;
      JArr.Add(JRow);
    end;

    JObj.Add('success', True);
    JObj.Add('fields', StrArrayToJSONArray(Res.Fields));
    JObj.Add('data', JArr);
    JObj.Add('affected', Res.Affected);
    if Res.Msg <> '' then
      JObj.Add('message', Res.Msg);

    Result := JObj;
  except
    JArr.Free;
    JObj.Free;
    raise;
  end;
end;

function GetContentType(const Ext: string): string;
begin
  Result := 'application/octet-stream';
  if (Ext = '.html') or (Ext = '.htm') then Result := 'text/html; charset=utf-8'
  else if Ext = '.css' then Result := 'text/css; charset=utf-8'
  else if Ext = '.js' then Result := 'application/javascript; charset=utf-8'
  else if Ext = '.json' then Result := 'application/json; charset=utf-8'
  else if Ext = '.png' then Result := 'image/png'
  else if (Ext = '.jpg') or (Ext = '.jpeg') then Result := 'image/jpeg'
  else if Ext = '.svg' then Result := 'image/svg+xml'
  else if Ext = '.ico' then Result := 'image/x-icon';
end;

function IfThen(const ATest: Boolean; const ATrue, AFalse: string): string;
begin
  if ATest then
    Result := ATrue
  else
    Result := AFalse;
end;

procedure SendJSON(AResponse: TFPHTTPConnectionResponse; const AJSON: string; AStatus: Integer = 200);
begin
  AResponse.Code := AStatus;
  AResponse.ContentType := 'application/json; charset=utf-8';
  AResponse.Content := AJSON;
end;

procedure SendError(AResponse: TFPHTTPConnectionResponse; AMsg: string; AStatus: Integer = 400);
var
  JObj: TJSONObject;
begin
  JObj := TJSONObject.Create;
  try
    JObj.Add('success', False);
    JObj.Add('error', AMsg);
    SendJSON(AResponse, JObj.FormatJSON, AStatus);
  finally
    JObj.Free;
  end;
end;

var
  Server: TFPHTTPServer;
  Pool: TVDbPool;
  Handler: TVDBRequestHandler;

constructor TVDbConnection.Create(const ADbDir, ADbName: string);
var
  DbFile: string;
begin
  inherited Create;

  if ADbName = '' then
  begin
    Kv := TVDb.Create;
    TableDb := TVTableDb.Create(Kv);
    TableDb.Open(ADbDir);
    Sql := TVSql.Create(TableDb);
  end
  else
  begin
    DbFile := ADbDir + ADbName + '.odb';
    Kv := TVDb.Create;
    Kv.Open(DbFile);
    TableDb := TVTableDb.Create(Kv);
    TableDb.Open(ADbDir);
    Sql := TVSql.Create(TableDb);
  end;

  InUse := False;
  LastUsed := Now;
end;

destructor TVDbConnection.Destroy;
begin
  Sql.Free;
  TableDb.Free;
  Kv.Free;
  inherited Destroy;
end;

constructor TVDbPool.Create(const ADbDir: string; AMaxCount: Integer = 10);
begin
  inherited Create;
  FDbDir := IncludeTrailingPathDelimiter(ADbDir);
  FMaxCount := AMaxCount;
  FPool := TList.Create;
  FLock := TCriticalSection.Create;
end;

destructor TVDbPool.Destroy;
var
  i: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to FPool.Count - 1 do
      TVDbConnection(FPool[i]).Free;
    FPool.Free;
  finally
    FLock.Leave;
    FLock.Free;
  end;
  inherited Destroy;
end;

function TVDbPool.Acquire(const ADbName: string = ''): TVDbConnection;
var
  i: Integer;
  Conn: TVDbConnection;
begin
  Result := nil;
  FLock.Enter;
  try
    for i := 0 to FPool.Count - 1 do
    begin
      Conn := TVDbConnection(FPool[i]);
      if not Conn.InUse then
      begin
        Conn.InUse := True;
        Conn.LastUsed := Now;
        Exit(Conn);
      end;
    end;

    if FPool.Count < FMaxCount then
    begin
      Conn := TVDbConnection.Create(FDbDir, ADbName);
      Conn.InUse := True;
      FPool.Add(Conn);
      Exit(Conn);
    end;

    FLock.Leave;
    Sleep(10);
    FLock.Enter;
    Result := Acquire(ADbName);
  finally
    FLock.Leave;
  end;
end;

procedure TVDbPool.Release(AConn: TVDbConnection);
begin
  if Assigned(AConn) then
  begin
    FLock.Enter;
    try
      AConn.InUse := False;
      AConn.LastUsed := Now;
    finally
      FLock.Leave;
    end;
  end;
end;

constructor TVDBRequestHandler.Create(APool: TVDbPool);
begin
  inherited Create;
  FPool := APool;
end;

procedure TVDBRequestHandler.HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
var
  Path: string;
  Conn: TVDbConnection;
  JArr: TJSONArray;
  JObj, JMeta: TJSONObject;
  Tables: TStrArray;
  Query: string;
  Res: TSqlResult;
  DbName, TableName: string;
  Stream: TFileStream;
  Ext: string;
  FilePath: string;
  JData: TJSONData;
  JInput: TJSONObject;
  Page, PageSize, Offset: Integer;
  RecCount: Int64;
  JsonStr: string;
begin
  Path := ARequest.PathInfo;

  AResponse.CustomHeaders.Add('Access-Control-Allow-Origin: *');
  AResponse.CustomHeaders.Add('Access-Control-Allow-Methods: GET, POST, OPTIONS');
  AResponse.CustomHeaders.Add('Access-Control-Allow-Headers: Content-Type');

  if ARequest.Method = 'OPTIONS' then
  begin
    AResponse.Code := 200;
    Exit;
  end;

  if Path = '/api/databases' then
  begin
    if ARequest.Method = 'GET' then
    begin
      Conn := FPool.Acquire('');
      try
        Tables := Conn.TableDb.TableNames;
        JArr := StrArrayToJSONArray(Tables);

        JObj := TJSONObject.Create;
        JObj.Add('success', True);
        JObj.Add('data', JArr);
        SendJSON(AResponse, JObj.FormatJSON);
      finally
        FPool.Release(Conn);
      end;
    end
    else if ARequest.Method = 'POST' then
    begin
      try
        JData := GetJSON(ARequest.Content);
        if (JData = nil) or (JData.JSONType <> jtObject) then
        begin
          SendError(AResponse, 'Invalid JSON');
          Exit;
        end;

        JInput := TJSONObject(JData);
        DbName := JInput.Get('name', '');
        if DbName = '' then
        begin
          SendError(AResponse, 'Database name required');
          Exit;
        end;

        Conn := FPool.Acquire('');
        try
          Res := Conn.Sql.Exec('CREATE DATABASE ' + DbName);
          if Res.Affected < 0 then
          begin
            SendError(AResponse, Res.Msg, 500);
            Exit;
          end;

          JObj := TJSONObject.Create;
          JObj.Add('success', True);
          JObj.Add('message', 'Database created: ' + DbName);
          SendJSON(AResponse, JObj.FormatJSON, 201);
        finally
          FPool.Release(Conn);
        end;
      except
        on E: Exception do
          SendError(AResponse, E.Message, 500);
      end;
    end
    else
      SendError(AResponse, 'Method not allowed', 405);
  end
  else if (Path.StartsWith('/api/tables/')) and (Path.EndsWith('/data')) then
  begin
    if ARequest.Method <> 'GET' then
    begin
      SendError(AResponse, 'Method not allowed', 405);
      Exit;
    end;

    DbName := ExtractDbName(Path);
    TableName := ExtractTableName(Path);

    if (DbName = '') or (TableName = '') then
    begin
      SendError(AResponse, 'Database and table name required');
      Exit;
    end;

    Page := StrToIntDef(ARequest.QueryFields.Values['page'], 1);
    PageSize := StrToIntDef(ARequest.QueryFields.Values['size'], 50);
    if Page < 1 then Page := 1;
    if PageSize < 1 then PageSize := 50;
    if PageSize > 1000 then PageSize := 1000;
    Offset := (Page - 1) * PageSize;

    Conn := FPool.Acquire(DbName);
    try
      Query := Format('SELECT COUNT(*) FROM %s', [TableName]);
      Res := Conn.Sql.Exec(Query);
      RecCount := 0;
      if (Length(Res.Rows) > 0) and (Length(Res.Rows[0]) > 0) then
        RecCount := StrToInt64Def(Res.Rows[0][0], 0);

      Query := Format('SELECT * FROM %s LIMIT %d OFFSET %d', [TableName, PageSize, Offset]);
      Res := Conn.Sql.Exec(Query);

      JObj := SqlResultToJSON(Res);

      JObj.Add('table', TableName);
      JMeta := TJSONObject.Create;
      JMeta.Add('page', Page);
      JMeta.Add('pageSize', PageSize);
      JMeta.Add('total', RecCount);
      JMeta.Add('pages', (RecCount + PageSize - 1) div PageSize);
      JObj.Add('meta', JMeta);

      JsonStr := JObj.FormatJSON;
      SendJSON(AResponse, JsonStr);
    finally
      FPool.Release(Conn);
    end;
  end
  else if Path.StartsWith('/api/tables/') then
  begin
    if ARequest.Method <> 'GET' then
    begin
      SendError(AResponse, 'Method not allowed', 405);
      Exit;
    end;

    DbName := ExtractDbName(Path);
    if DbName = '' then
    begin
      SendError(AResponse, 'Database name required');
      Exit;
    end;

    Conn := FPool.Acquire(DbName);
    try
      Tables := Conn.TableDb.TableNames;
      JArr := StrArrayToJSONArray(Tables);

      JObj := TJSONObject.Create;
      JObj.Add('success', True);
      JObj.Add('database', DbName);
      JObj.Add('tables', JArr);
      SendJSON(AResponse, JObj.FormatJSON);
    finally
      FPool.Release(Conn);
    end;
  end
  else
  begin
    // Static files
    AResponse.ContentType := 'text/plain; charset=utf-8';
    AResponse.Content := 'Original Path: ' + ARequest.PathInfo + #13#10 +
                        'Path variable: ' + Path + #13#10;
    if Path = '/' then
    begin
      Path := '/index.html';
      AResponse.Content := AResponse.Content + 'Path set to: ' + Path + #13#10;
    end
    else
    begin
      AResponse.Content := AResponse.Content + 'Path is not root' + #13#10;
    end;
    FilePath := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'frontend' + Path;
    AResponse.Content := AResponse.Content + 'FilePath: ' + FilePath + #13#10 +
                        'File exists: ' + (IfThen(FileExists(FilePath), 'true', 'false')) + #13#10;
    if FileExists(FilePath) then
    begin
      Stream := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyWrite);
      try
        Ext := LowerCase(ExtractFileExt(FilePath));
        AResponse.ContentType := GetContentType(Ext);
        AResponse.ContentStream := Stream;
        AResponse.FreeContentStream := True;
        AResponse.Code := 200;
      except
        Stream.Free;
        raise;
      end;
    end
    else
    begin
      // Keep the debug content in AResponse.Content
      AResponse.Code := 200;
    end;
  end;
end;

var
  DbDir, FrontendDir: string;

begin
  WriteLn('=== VDB Web API Server (FPC Native) ===');
  WriteLn('Starting...');

  DbDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'db');
  ForceDirectories(DbDir);

  FrontendDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'frontend');
  ForceDirectories(FrontendDir);

  Pool := TVDbPool.Create(DbDir, 10);
  Handler := TVDBRequestHandler.Create(Pool);

  Server := TFPHTTPServer.Create(nil);
  try
    Server.Port := 8888;
    Server.Threaded := True;
    Server.OnRequest := Handler.HandleRequest;

    WriteLn('Server running on http://127.0.0.1:8888');
    WriteLn('API: http://127.0.0.1:8888/api/databases');
    WriteLn('Web UI: http://127.0.0.1:8888/');
    WriteLn('Press Enter to stop...');

    Server.Active := True;
    ReadLn;

    Server.Active := False;
  finally
    Server.Free;
    Handler.Free;
    Pool.Free;
  end;

  WriteLn('Server stopped.');
end.