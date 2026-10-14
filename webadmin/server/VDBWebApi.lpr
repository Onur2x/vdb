{$MODE DELPHI}
   {$H+}

   program VDBWebApi;

   uses
     Classes, SysUtils, SyncObjs, StrUtils,
     fphttpserver, httpdefs, httproute,  // FPC HTTP Server
     fpjson, jsonparser,                 // FPC JSON
     VDbSql, VDbTable;                   // Senin VDB bileşenlerin

   type
     { VDB Connection Pool - Thread Safe }
     TVDbConnection = class
       Db: TVDb;
       TableDb: TVTableDb;
       InUse: Boolean;
       LastUsed: TDateTime;
       constructor Create(const ADbDir: string);
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

     { Request Handler }
     TVDBApiModule = class(THTTPRouteModule)
     private
       FPool: TVDbPool;
       procedure HandleDatabases(ARequest: TRequest; AResponse: TResponse);
       procedure HandleTables(ARequest: TRequest; AResponse: TResponse);
       procedure HandleTableData(ARequest: TRequest; AResponse: TResponse);
       procedure HandleStaticFile(ARequest: TRequest; AResponse: TResponse);
       function GetDbName(ARequest: TRequest): string;
       function GetTableName(ARequest: TRequest): string;
       procedure SendJSON(AResponse: TResponse; AJSON: TJSONData; AStatus:
 Integer = 200);
       procedure SendError(AResponse: TResponse; AMsg: string; AStatus: Integer =
 400);
     public
       constructor Create(APool: TVDbPool);
       destructor Destroy; override;
       procedure RegisterRoutes; override;
     end;

   var
     Server: TFPHTTPServer;
     Pool: TVDbPool;
     ApiModule: TVDBApiModule;

   { TVDbConnection }

   constructor TVDbConnection.Create(const ADbDir: string);
   begin
     inherited Create;
     Db := TVDb.Create(nil);
     TableDb := TVTableDb.Create(nil);
     Db.DatabaseName := ADbDir;
     TableDb.Database := Db;
     InUse := False;
     LastUsed := Now;
   end;

   destructor TVDbConnection.Destroy;
   begin
     TableDb.Free;
     Db.Free;
     inherited Destroy;
   end;

   { TVDbPool }

   constructor TVDbPool.Create(const ADbDir: string; AMaxCount: Integer = 10);
   begin
     inherited Create;
     FDbDir := ADbDir;
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
       // Boş bağlantı ara
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

       // Yeni oluştur (limit kontrolü)
       if FPool.Count < FMaxCount then
       begin
         Conn := TVDbConnection.Create(FDbDir + ADbName);
         Conn.InUse := True;
         FPool.Add(Conn);
         Exit(Conn);
       end;

       // Bekle ve tekrar dene (basit implementasyon)
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

   { TVDBApiModule }

   constructor TVDBApiModule.Create(APool: TVDbPool);
   begin
     inherited Create;
     FPool := APool;
     RegisterRoutes;
   end;

   destructor TVDBApiModule.Destroy;
   begin
     inherited Destroy;
   end;

   procedure TVDBApiModule.RegisterRoutes;
   begin
     // API Routes
     RegisterRoute('/api/databases', @HandleDatabases, [rmGet, rmPost]);
     RegisterRoute('/api/tables/*', @HandleTables, [rmGet]);
     RegisterRoute('/api/tables/*/data', @HandleTableData, [rmGet]);

     // Static files (web frontend)
     RegisterRoute('/*', @HandleStaticFile, [rmGet]);
   end;

   procedure TVDBApiModule.SendJSON(AResponse: TResponse; AJSON: TJSONData;
 AStatus: Integer = 200);
   var
     Stream: TStringStream;
   begin
     AResponse.StatusCode := AStatus;
     AResponse.ContentType := 'application/json; charset=utf-8';
     AResponse.ContentLength := -1;
     Stream := TStringStream.Create(AJSON.FormatJSON);
     try
       AResponse.Content := Stream;
     finally
       Stream.Free;
     end;
   end;

   procedure TVDBApiModule.SendError(AResponse: TResponse; AMsg: string; AStatus:
 Integer = 400);
   var
     JObj: TJSONObject;
   begin
     JObj := TJSONObject.Create;
     try
       JObj.Add('success', False);
       JObj.Add('error', AMsg);
       SendJSON(AResponse, JObj, AStatus);
     finally
       JObj.Free;
     end;
   end;

   function TVDBApiModule.GetDbName(ARequest: TRequest): string;
   var
     Path: string;
   begin
     Path := ARequest.PathInfo;
     // /api/tables/dbname/... -> dbname
     if Path.StartsWith('/api/tables/') then
     begin
       Path := Copy(Path, 13, Length(Path));
       Result := Copy(Path, 1, Pos('/', Path) - 1);
     end
     else
       Result := '';
   end;

   function TVDBApiModule.GetTableName(ARequest: TRequest): string;
   var
     Path: string;
     StartPos: Integer;
   begin
     Path := ARequest.PathInfo;
     // /api/tables/dbname/tablename/data -> tablename
     if Path.StartsWith('/api/tables/') then
     begin
       Path := Copy(Path, 13, Length(Path));
       StartPos := Pos('/', Path) + 1;
       Path := Copy(Path, StartPos, Length(Path));
       Result := Copy(Path, 1, Pos('/', Path) - 1);
     end
     else
       Result := '';
   end;

   procedure TVDBApiModule.HandleDatabases(ARequest: TRequest; AResponse:
 TResponse);
   var
     Conn: TVDbConnection;
     JArr: TJSONArray;
     JObj: TJSONObject;
     Tables: TStringList;
     i: Integer;
   begin
     if ARequest.Method = 'GET' then
     begin
       Conn := FPool.Acquire('');
       try
         JArr := TJSONArray.Create;
         try
           Tables := TStringList.Create;
           try
             Conn.TableDb.GetTableNames(Tables);
             for i := 0 to Tables.Count - 1 do
             begin
               JObj := TJSONObject.Create;
               JObj.Add('name', Tables[i]);
               JArr.Add(JObj);
             end;

             JObj := TJSONObject.Create;
             JObj.Add('success', True);
             JObj.Add('data', JArr);
             SendJSON(AResponse, JObj);
           finally
             Tables.Free;
           end;
         except
           JArr.Free;
           raise;
         end;
       finally
         FPool.Release(Conn);
       end;
     end
     else if ARequest.Method = 'POST' then
     begin
       // POST /api/databases {"name": "newdb"}
       var JData: TJSONData;
       var JInput: TJSONObject;
       var DbName: string;

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

         Conn := FPool.Acquire(DbName);
         try
           // DB oluştur (VDb.CreateDatabase veya benzeri)
           Conn.Db.DatabaseName := FPool.FDbDir + DbName;
           if not Conn.Db.Exists then
             Conn.Db.CreateDatabase;

           JObj := TJSONObject.Create;
           JObj.Add('success', True);
           JObj.Add('message', 'Database created: ' + DbName);
           SendJSON(AResponse, JObj, 201);
         finally
           FPool.Release(Conn);
         end;
       except
         on E: Exception do
           SendError(AResponse, E.Message, 500);
       end;
     end;
   end;

   procedure TVDBApiModule.HandleTables(ARequest: TRequest; AResponse:
 TResponse);
   var
     Conn: TVDbConnection;
     DbName: string;
     JArr: TJSONArray;
     JObj: TJSONObject;
     Tables: TStringList;
     i: Integer;
   begin
     DbName := GetDbName(ARequest);
     if DbName = '' then
     begin
       SendError(AResponse, 'Database name required');
       Exit;
     end;

     Conn := FPool.Acquire(DbName);
     try
       JArr := TJSONArray.Create;
       try
         Tables := TStringList.Create;
         try
           Conn.TableDb.GetTableNames(Tables);
           for i := 0 to Tables.Count - 1 do
           begin
             JObj := TJSONObject.Create;
             JObj.Add('name', Tables[i]);
             JArr.Add(JObj);
           end;

           JObj := TJSONObject.Create;
           JObj.Add('success', True);
           JObj.Add('database', DbName);
           JObj.Add('tables', JArr);
           SendJSON(AResponse, JObj);
         finally
           Tables.Free;
         end;
       except
         JArr.Free;
         raise;
       end;
     finally
       FPool.Release(Conn);
     end;
   end;

   procedure TVDBApiModule.HandleTableData(ARequest: TRequest; AResponse:
 TResponse);
   var
     Conn: TVDbConnection;
     DbName, TableName: string;
     Page, PageSize: Integer;
     JArr: TJSONArray;
     JObj, JRow: TJSONObject;
     Meta: TJSONObject;
     Query: string;
     RecCount: Int64;
   begin
     DbName := GetDbName(ARequest);
     TableName := GetTableName(ARequest);

     if (DbName = '') or (TableName = '') then
     begin
       SendError(AResponse, 'Database and table name required');
       Exit;
     end;

     // Query params
     Page := StrToIntDef(ARequest.QueryFields.Values['page'], 1);
     PageSize := StrToIntDef(ARequest.QueryFields.Values['size'], 50);
     if Page < 1 then Page := 1;
     if PageSize < 1 then PageSize := 50;
     if PageSize > 1000 then PageSize := 1000;

     Conn := FPool.Acquire(DbName);
     try
       // Toplam kayıt sayısı
       Query := Format('SELECT COUNT(*) FROM %s', [TableName]);
       try
         with Conn.Db.SQLExecutor do
         begin
           SQL.Text := Query;
           Open;
           RecCount := Fields[0].AsLargeInt;
           Close;
         end;
       except
         RecCount := 0;
       end;

       // Sayfalı veri çek
       Query := Format('SELECT * FROM %s LIMIT %d OFFSET %d',
         [TableName, PageSize, (Page - 1) * PageSize]);

       JArr := TJSONArray.Create;
       try
         with Conn.Db.SQLExecutor do
         begin
           SQL.Text := Query;
           Open;
           try
             while not EOF do
             begin
               JRow := TJSONObject.Create;
               for i := 0 to FieldCount - 1 do
               begin
                 case Fields[i].DataType of
                   ftString, ftWideString, ftMemo, ftWideMemo:
                     JRow.Add(Fields[i].FieldName, Fields[i].AsString);
                   ftInteger, ftSmallint, ftLargeint:
                     JRow.Add(Fields[i].FieldName, Fields[i].AsLargeInt);
                   ftFloat, ftCurrency, ftBCD:
                     JRow.Add(Fields[i].FieldName, Fields[i].AsFloat);
                   ftBoolean:
                     JRow.Add(Fields[i].FieldName, Fields[i].AsBoolean);
                   ftDate, ftTime, ftDateTime:
                     JRow.Add(Fields[i].FieldName, FormatDateTime('yyyy-mm-dd
 hh:nn:ss', Fields[i].AsDateTime));
                   else
                     JRow.Add(Fields[i].FieldName, Fields[i].AsString);
                 end;
               end;
               JArr.Add(JRow);
               Next;
             end;
           finally
             Close;
           end;
         end;

         // Response
         JObj := TJSONObject.Create;
         JObj.Add('success', True);
         JObj.Add('table', TableName);
         JObj.Add('data', JArr);

         Meta := TJSONObject.Create;
         Meta.Add('page', Page);
         Meta.Add('pageSize', PageSize);
         Meta.Add('total', RecCount);
         Meta.Add('pages', (RecCount + PageSize - 1) div PageSize);
         JObj.Add('meta', Meta);

         SendJSON(AResponse, JObj);
       except
         JArr.Free;
         raise;
       end;
     finally
       FPool.Release(Conn);
     end;
   end;

   procedure TVDBApiModule.HandleStaticFile(ARequest: TRequest; AResponse:
 TResponse);
   var
     FilePath: string;
     Stream: TFileStream;
     Ext: string;
   begin
     // API isteklerini static'e düşürme
     if ARequest.PathInfo.StartsWith('/api/') then
     begin
       SendError(AResponse, 'Not found', 404);
       Exit;
     end;

     FilePath := ExtractFilePath(ParamStr(0)) + 'frontend' + ARequest.PathInfo;
     if (FilePath = ExtractFilePath(ParamStr(0)) + 'frontend/') or
        (FilePath = ExtractFilePath(ParamStr(0)) + 'frontend') then
       FilePath := FilePath + 'index.html';

     if FileExists(FilePath) then
     begin
       Stream := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyWrite);
       try
         Ext := LowerCase(ExtractFileExt(FilePath));
         case Ext of
           '.html', '.htm': AResponse.ContentType := 'text/html; charset=utf-8';
           '.css': AResponse.ContentType := 'text/css; charset=utf-8';
           '.js': AResponse.ContentType := 'application/javascript;
 charset=utf-8';
           '.json': AResponse.ContentType := 'application/json; charset=utf-8';
           '.png': AResponse.ContentType := 'image/png';
           '.jpg', '.jpeg': AResponse.ContentType := 'image/jpeg';
           '.svg': AResponse.ContentType := 'image/svg+xml';
           '.ico': AResponse.ContentType := 'image/x-icon';
           else AResponse.ContentType := 'application/octet-stream';
         end;
         AResponse.Content := Stream;
         AResponse.StatusCode := 200;
       except
         Stream.Free;
         raise;
       end;
     end
     else
     begin
       SendError(AResponse, 'File not found', 404);
     end;
   end;

   { Main Program }

   begin
     WriteLn('=== VDB Web API Server (FPC Native) ===');
     WriteLn('Starting...');

     // DB klasörü
     var DbDir := ExtractFilePath(ParamStr(0)) + 'db/';
     ForceDirectories(DbDir);

     // Frontend klasörü
     var FrontendDir := ExtractFilePath(ParamStr(0)) + 'frontend/';
     ForceDirectories(FrontendDir);

     // Connection Pool
     Pool := TVDbPool.Create(DbDir, 10);

     // API Module
     ApiModule := TVDBApiModule.Create(Pool);

     // HTTP Server
     Server := TFPHTTPServer.Create(nil);
     try
       Server.Port := 5000;
       Server.Threaded := True;
       Server.RegisterModule('/api', ApiModule);
       Server.RegisterModule('/', ApiModule);  // Static files de aynı module

       WriteLn('Server running on http://127.0.0.1:5000');
       WriteLn('API: http://127.0.0.1:5000/api/databases');
       WriteLn('Web UI: http://127.0.0.1:5000/');
       WriteLn('Press Enter to stop...');

       Server.Active := True;
       ReadLn;

       Server.Active := False;
     finally
       Server.Free;
       ApiModule.Free;
       Pool.Free;
     end;

     WriteLn('Server stopped.');
   end.