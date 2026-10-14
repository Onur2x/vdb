unit VDbXml;

{ F-23: XML — ayristirma, yol eslestirme ve kurma. Detaylar interface'de. }

{$mode delphi}

interface

uses
  Classes, SysUtils;

type
  { XML dugumu. KOK, ESLETMELER ve BIRLISTELER bu tipi kullanir.
    Sahiplik: her dugum kendini Free eder; agac VDbXmlFree ile birakilir. }
  TXmlNode = class
    Name: string;              // etiket adi
    Text: string;              // dogrudan metin icerigi (ozellikler HARIC)
    AttrNames: array of string;
    AttrVals: array of string;
    Children: array of TXmlNode;
    Parent: TXmlNode;
    constructor Create(const AName: string);
    function Attr(const AName: string): string;   // yoksa ''
    function HasAttr(const AName: string): Boolean;
    procedure SetAttr(const AName, AVal: string);
    function AddChild(const AName: string): TXmlNode;
    function DescendantCount: Integer;
  end;

  TXmlNodes = array of TXmlNode;    // eslesen dugumler
  TXmlSteps = array of string;      // yol adimlari ("ad" veya "//ad")

function VDbXmlParse(const S: string; out Root: TXmlNode): Boolean;
procedure VDbXmlFree(N: TXmlNode);
function VDbXmlMatchStep(N: TXmlNode; const Step: string): Boolean;
function VDbXmlSplitPath(const Path: string; out Steps: TXmlSteps): Boolean;
function VDbXmlFindAll(const Root: TXmlNode; const Path: string): TXmlNodes;
function VDbXmlFind(const Root: TXmlNode; const Path: string;
  First: Boolean): TXmlNode;
function VDbXmlCount(const Root: TXmlNode; const Path: string): Integer;
function VDbXmlElement(const Name: string; const Content: string): string;
function VDbXmlConcat(const Parts: array of string): string;
function VDbXmlEscape(const S: string): string;
function VDbXmlToText(N: TXmlNode): string;

implementation

const
  XML_MAX_DEPTH = 64;   // cok derin XML asiri girmez

{ ------------------------------------------------------------
  TXmlNode
  //---------------------------------------------------------- }

constructor TXmlNode.Create(const AName: string);
begin
  inherited Create;
  Name := AName;
  Text := '';
end;

function TXmlNode.Attr(const AName: string): string;
var
  i: Integer;
begin
  for i := 0 to High(AttrNames) do
    if AttrNames[i] = AName then Exit(AttrVals[i]);
  Result := '';
end;

function TXmlNode.HasAttr(const AName: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AttrNames) do
    if AttrNames[i] = AName then Exit(True);
  Result := False;
end;

procedure TXmlNode.SetAttr(const AName, AVal: string);
var
  i: Integer;
begin
  for i := 0 to High(AttrNames) do
    if AttrNames[i] = AName then
    begin
      AttrVals[i] := AVal;
      Exit;
    end;
  SetLength(AttrNames, Length(AttrNames) + 1);
  SetLength(AttrVals, Length(AttrVals) + 1);
  AttrNames[High(AttrNames)] := AName;
  AttrVals[High(AttrVals)] := AVal;
end;

function TXmlNode.AddChild(const AName: string): TXmlNode;
begin
  Result := TXmlNode.Create(AName);
  Result.Parent := Self;
  SetLength(Children, Length(Children) + 1);
  Children[High(Children)] := Result;
end;

function TXmlNode.DescendantCount: Integer;
var
  i, n: Integer;
begin
  Result := 0;
  for i := 0 to High(Children) do
  begin
    Inc(Result);
    Inc(Result, Children[i].DescendantCount);
  end;
end;

procedure VDbXmlFree(N: TXmlNode);
var
  i: Integer;
begin
  if N = nil then Exit;
  for i := 0 to High(N.Children) do VDbXmlFree(N.Children[i]);
  SetLength(N.Children, 0);
  N.Free;
end;

{ ------------------------------------------------------------
  Ayristirma
  //---------------------------------------------------------- }
{ ------------------------------------------------------------
  Ayristirma
  //---------------------------------------------------------- }

function VDbXmlParse(const S: string; out Root: TXmlNode): Boolean;
var
  P, slen, depth: Integer;
  rootNode, cur, nxt: TXmlNode;
  stack: array of TXmlNode;
  sp2: Integer;
  tagName, an, av, pending: string;
  selfc, closing, ok, twoRoots: Boolean;
  e: Integer;

  procedure SkipWs;
  begin
    while (P <= slen) and (S[P] in [' ', #9, #10, #13]) do Inc(P);
  end;

  // Ozgecme cozumlemesi (&amp; &lt; &#nn; &#xNN;)
  function Unescape(const A: string): string;
  var
    i, k, cp: Integer;
    hexs: string;
  begin
    Result := '';
    i := 1;
    while i <= Length(A) do
    begin
      if (A[i] = '&') and (Pos(';', Copy(A, i, 12)) > 0) then
      begin
        k := i + Pos(';', Copy(A, i, 12)) - 1;
        if Copy(A, i + 1, 2) = 'lt' then Result := Result + '<'
        else if Copy(A, i + 1, 2) = 'gt' then Result := Result + '>'
        else if Copy(A, i + 1, 3) = 'amp' then Result := Result + '&'
        else if Copy(A, i + 1, 4) = 'quot' then Result := Result + '"'
        else if Copy(A, i + 1, 4) = 'apos' then Result := Result + ''''
        else if (A[i + 1] = '#') and (i + 2 < Length(A)) and (A[i + 2] = 'x') then
        begin
          hexs := Copy(A, i + 3, k - i - 3);
          cp := StrToIntDef('$' + hexs, -1);
          if (cp >= 0) and (cp < 128) then Result := Result + Chr(cp)
          else Result := Result + '?';
        end
        else if A[i + 1] = '#' then
        begin
          cp := StrToIntDef(Copy(A, i + 2, k - i - 2), -1);
          if (cp >= 0) and (cp < 128) then Result := Result + Chr(cp)
          else Result := Result + '?';
        end
        else
          Result := Result + Copy(A, i, k - i + 1);
        i := k + 1;
        Continue;
      end;
      Result := Result + A[i];
      Inc(i);
    end;
  end;

  // XML bildirimi / yorum / CDATA atlanir (CDATA metni korunur)
  procedure SkipSpecial;
  begin
    if (P <= slen) and (S[P] = '?') then
    begin
      while (P <= slen) and (Copy(S, P, 2) <> '?>') do Inc(P);
      if (P <= slen) and (Copy(S, P, 2) = '?>') then Inc(P, 2);
      Exit;
    end;
    if Copy(S, P, 3) = '!--' then
    begin
      while (P <= slen) and (Copy(S, P, 3) <> '-->') do Inc(P);
      if P <= slen then Inc(P, 3);
      Exit;
    end;
    if Copy(S, P, 8) = '![CDATA[' then
    begin
      Inc(P, 8);
      while (P <= slen) and (Copy(S, P, 3) <> ']]>') do
      begin
        pending := pending + S[P];
        Inc(P);
      end;
      if P <= slen then Inc(P, 3);
      Exit;
    end;
    while (P <= slen) and (S[P] <> '>') do Inc(P);
    if P <= slen then Inc(P);
  end;

begin
  Root := nil;
  Result := False;
  if S = '' then Exit(False);
  slen := Length(S);
  P := 1;
  depth := 0;
  sp2 := 0;
  ok := False;
  twoRoots := False;   // ikinci kok goruldu -> gecersiz XML
  rootNode := nil;
  cur := nil;
  pending := '';   // etiket disi ham metin (ozgecme cozulecek)

  while P <= slen do
  begin
    while (P <= slen) and (S[P] <> '<') do
    begin
      pending := pending + S[P];
      Inc(P);
    end;
    if P > slen then Break;
    // '<' goruldu: biriken metni coz ve dugume yaz
    if cur <> nil then cur.Text := cur.Text + Unescape(pending);
    pending := '';
    Inc(P);
    if P > slen then Break;
    if (S[P] = '?') or (S[P] = '!') then
    begin
      // DIKKAT: P '<' SONRASIKI karakterde ('!' veya '?').
      // Dec(P) yaparsan SkipSpecial '<' uzerinde calisir ve CDATA/yorum
      // tanimlari TANINMAZ (metin kaybolur). Inc(P) da fazladan bir
      // karakter atlatir. Ikisi de kaldirildi.
      SkipSpecial;
      Continue;
    end;
    if S[P] = '/' then
    begin
      closing := True;
      Inc(P);
    end
    else
      closing := False;

    e := P;
    while (P <= slen) and (not (S[P] in [' ', #9, #10, #13, '/', '>'])) do Inc(P);
    tagName := Copy(S, e, P - e);
    if tagName = '' then Break;

    if closing then
    begin
      // Kapanis oncesi biriken metin bu dugume aittir (cur hala acik dugum)
      if cur <> nil then cur.Text := cur.Text + Unescape(pending);
      pending := '';
      while (P <= slen) and (S[P] <> '>') do Inc(P);
      if P <= slen then Inc(P);
      if sp2 = 0 then Break;
      if stack[sp2 - 1].Name <> tagName then Break;
      Dec(sp2);
      Dec(depth);
      if sp2 > 0 then cur := stack[sp2 - 1] else cur := nil;
      Continue;
    end;

    nxt := TXmlNode.Create(Unescape(tagName));
    selfc := False;
    while P <= slen do
    begin
      SkipWs;
      if P > slen then Break;
      if S[P] = '/' then
      begin
        selfc := True;
        Inc(P);
        Continue;
      end;
      if S[P] = '>' then
      begin
        Inc(P);
        Break;
      end;
      e := P;
      while (P <= slen) and (not (S[P] in ['=', ' ', #9, #10, #13, '/', '>'])) do Inc(P);
      if P = e then
      begin
        Inc(P);
        Continue;
      end;
      an := Copy(S, e, P - e);
      av := '';
      SkipWs;
      if (P <= slen) and (S[P] = '=') then
      begin
        Inc(P);
        SkipWs;
        if (P <= slen) and (S[P] = '"') then
        begin
          Inc(P);
          e := P;
          while (P <= slen) and (S[P] <> '"') do Inc(P);
          av := Copy(S, e, P - e);
          if P <= slen then Inc(P);
        end
        else if (P <= slen) and (S[P] = '''') then
        begin
          Inc(P);
          e := P;
          while (P <= slen) and (S[P] <> '''') do Inc(P);
          av := Copy(S, e, P - e);
          if P <= slen then Inc(P);
        end
        else
        begin
          e := P;
          while (P <= slen) and (not (S[P] in [' ', #9, #10, #13, '/', '>'])) do Inc(P);
          av := Copy(S, e, P - e);
        end;
      end;
      if an <> '' then nxt.SetAttr(Unescape(an), Unescape(av));
    end;

    if cur = nil then
    begin
      // Ikinci kok: XML olarak gecersiz. DIKKAT: sadece cok koklu
      // HICBIR sey cikmasin diye burada bos cikmak yetmez — asagida
      // ayrica twoRoots kontrolu yapilir.
      if rootNode <> nil then
      begin
        twoRoots := True;
        Break;
      end;
      rootNode := nxt;
    end
    else
    begin
      nxt.Parent := cur;
      SetLength(cur.Children, Length(cur.Children) + 1);
      cur.Children[High(cur.Children)] := nxt;
    end;
    Inc(depth);
    if depth > XML_MAX_DEPTH then Break;
    ok := True;
    if not selfc then
    begin
      SetLength(stack, sp2 + 1);
      stack[sp2] := nxt;
      Inc(sp2);
      cur := nxt;
    end;
  end;

  // Sondaki metin (etiket disi) de cozulecek
  if cur <> nil then cur.Text := cur.Text + Unescape(pending);

  if (sp2 <> 0) or twoRoots or (not ok) or (rootNode = nil) then
  begin
    VDbXmlFree(rootNode);
    Root := nil;
    Exit(False);
  end;
  Root := rootNode;
  Result := True;
end;

{ ------------------------------------------------------------
  Yol eslestirme
  //---------------------------------------------------------- }

function VDbXmlMatchStep(N: TXmlNode; const Step: string): Boolean;
// Tek yol adimini test eder:
//   ad  |  *  |  ad[@nit='deger']  |  ad[@nit]  |  ad[2]
// Eslestirme ANAHTAR ADIYLA yapilir, konumla DEGIL.
var
  nm, pred, aName, aVal: string;
  c1, c2, at, av, av2, q, s, want, n2, k: Integer;
begin
  c1 := Pos('[', Step);
  if c1 = 0 then
  begin
    VDbXmlMatchStep := (Step = '*') or (N.Name = Step);
    Exit;
  end;
  c2 := Pos(']', Step);
  if c2 <= c1 then
  begin
    VDbXmlMatchStep := False;
    Exit;
  end;
  nm := Copy(Step, 1, c1 - 1);
  pred := Copy(Step, c1 + 1, c2 - c1 - 1);
  if not ((nm = '*') or (N.Name = nm)) then
  begin
    VDbXmlMatchStep := False;
    Exit;
  end;
  if pred = '' then
  begin
    VDbXmlMatchStep := True;
    Exit;
  end;
  if pred[1] = '@' then
  begin
    at := Pos('=', pred);
    if at = 0 then
    begin
      // [@ad] â€” nitelik var mi
      VDbXmlMatchStep := N.HasAttr(Copy(pred, 2, Length(pred) - 1));
      Exit;
    end;
    aName := Copy(pred, 2, at - 2);
    // Deger ILK tirnakla BASLAR; ikinci tirnak arasindaki metin degerdir.
    // (Onceki kod ilk tirnagi degerin BASI saniyordu -> deger hep '' cikiyordu)
    av := Pos('''', Copy(pred, at + 1, Length(pred)));
    if av > 0 then
    begin
      av2 := Pos('''', Copy(pred, at + av + 1, Length(pred)));
      if av2 = 0 then
      begin
        VDbXmlMatchStep := False;
        Exit;
      end;
      aVal := Copy(pred, at + av + 1, av2 - 1);
    end;
    VDbXmlMatchStep := (N.Attr(aName) = aVal);
    Exit;
  end;
  if (pred[1] >= '0') and (pred[1] <= '9') then
  begin
    // [n] â€” ayni adli kardesler arasinda 1 tabanli konum
    want := StrToIntDef(pred, -1);
    if (want < 1) or (N.Parent = nil) then
    begin
      VDbXmlMatchStep := False;
      Exit;
    end;
    k := 0;
    for n2 := 0 to High(N.Parent.Children) do
      if N.Parent.Children[n2].Name = N.Name then
      begin
        Inc(k);
        // BU dugumun KONUMU n mi? (Onceki kod "n. kardes var mi"
        // diye soruyordu -> ilk kitap da [2] ile eslesiyordu)
        if N.Parent.Children[n2] = N then
        begin
          VDbXmlMatchStep := (k = want);
          Exit;
        end;
      end;
    VDbXmlMatchStep := False;
    Exit;
  end;
  VDbXmlMatchStep := False;
end;

function VDbXmlSplitPath(const Path: string; out Steps: TXmlSteps): Boolean;
// Yolu adimlara boler. Her adim ya "ad" ya da "//ad" bicimindedir
// ("//" = o adimin tum torunlar arasinda aranacagi).
var
  i: Integer;
  step: string;
  pendDesc: Boolean;
  trimmed: string;
begin
  SetLength(Steps, 0);
  Result := False;
  trimmed := Trim(Path);
  if trimmed = '' then Exit(False);
  i := 1;
  step := '';
  pendDesc := False;
  while i <= Length(trimmed) do
  begin
    if (trimmed[i] = '/') and (i < Length(trimmed)) and (trimmed[i + 1] = '/') then
    begin
      if step <> '' then
      begin
        SetLength(Steps, Length(Steps) + 1);
        Steps[High(Steps)] := step;
        step := '';
      end;
      pendDesc := True;
      Inc(i, 2);
      Continue;
    end;
    if trimmed[i] = '/' then
    begin
      if step <> '' then
      begin
        SetLength(Steps, Length(Steps) + 1);
        Steps[High(Steps)] := step;
        step := '';
      end;
      Inc(i);
      Continue;
    end;
    step := step + trimmed[i];
    Inc(i);
  end;
  if step <> '' then
  begin
    SetLength(Steps, Length(Steps) + 1);
    Steps[High(Steps)] := step;
  end;
  // '//' isareti bir sonraki adimin onune tasinir
  if pendDesc and (Length(Steps) > 0) then
    Steps[0] := '//' + Steps[0];
  Result := Length(Steps) > 0;
end;

function VDbXmlFindAll(const Root: TXmlNode; const Path: string): TXmlNodes;
// Adim adim ilerler. curLevel = ONCEKI adimla eslesen dugumler.
//   Mutlak yol  : ilk adim KOK DUGUMUN KENDISIyle eslesir (/katalog/kitap)
//   Gorece yol : ilk adim kokun COCUKLARIYLA eslesir (kitap/ad)
//   //ad       : o adim icin tum torunlar taranir
var
  steps: TXmlSteps;
  curLevel, nextLevel: TXmlNodes;
  i, j, m, base: Integer;
  descendant, absolute: Boolean;
  stepTxt: string;
  bfsQ: TXmlNodes;
  h, t, k: Integer;
  firstStep: Boolean;

  procedure AddTo(var L: TXmlNodes; const N: TXmlNode);
  begin
    if N = nil then Exit;
    SetLength(L, Length(L) + 1);
    L[High(L)] := N;
  end;

begin
  SetLength(Result, 0);
  if Root = nil then Exit;
  if Trim(Path) = '' then
  begin
    AddTo(Result, Root);
    Exit;
  end;
  if not VDbXmlSplitPath(Path, steps) then
  begin
    AddTo(Result, Root);
    Exit;
  end;
  absolute := Copy(Trim(Path), 1, 1) = '/';

  // baslangic: mutlak yolda kokun kendisi, gorece yolda cocuklar
  SetLength(curLevel, 0);
  if absolute then
    AddTo(curLevel, Root)
  else
    for i := 0 to High(Root.Children) do
      AddTo(curLevel, Root.Children[i]);

  for j := 0 to High(steps) do
  begin
    descendant := Copy(steps[j], 1, 2) = '//';
    if descendant then
      stepTxt := Copy(steps[j], 3, MaxInt)
    else
      stepTxt := steps[j];

    // '//' -> mevcut dugumlerin TUM TORUNLARI havuzu (BFS)
    SetLength(bfsQ, 0);
    if descendant then
    begin
      for i := 0 to High(curLevel) do AddTo(bfsQ, curLevel[i]);
      base := Length(bfsQ);
      h := 0;
      t := Length(bfsQ);
      while h < t do
      begin
        for k := 0 to High(bfsQ[h].Children) do
        begin
          AddTo(bfsQ, bfsQ[h].Children[k]);
          Inc(t);
        end;
        Inc(h);
      end;
      SetLength(curLevel, 0);
      for i := base to High(bfsQ) do AddTo(curLevel, bfsQ[i]);
    end;

    // eslesen dugumleri topla
    SetLength(nextLevel, 0);
    firstStep := (j = 0) and (not descendant);
    // DIKKAT: begin/end sart. Yoksa "else" icteki IF'e baglanir ve
    // (Pascal'ta klasik "dangling else") ilk for dongusunun sayacina
    // atama yapmaya calisir -> derleme hatasi.
    if descendant then
    begin
      // curLevel zaten TUM torunlari iceriyor; bu adim onlarin UZERINDE
      // eslesir (bir kez daha asagi inilmez — aksi halde ilk seviye atlanir)
      for i := 0 to High(curLevel) do
        if VDbXmlMatchStep(curLevel[i], stepTxt) then
          AddTo(nextLevel, curLevel[i]);
    end
    else if firstStep then
    begin
      // ilk adim: mutlak yolda kokun kendisi, gorece yolda cocuklar
      for i := 0 to High(curLevel) do
        if VDbXmlMatchStep(curLevel[i], stepTxt) then
          AddTo(nextLevel, curLevel[i]);
    end
    else
    begin
      // sonraki adimlar: onceki eslesmelerin COCUKLARI
      for i := 0 to High(curLevel) do
        for m := 0 to High(curLevel[i].Children) do
          if VDbXmlMatchStep(curLevel[i].Children[m], stepTxt) then
            AddTo(nextLevel, curLevel[i].Children[m]);
    end;
    curLevel := nextLevel;
  end;
  Result := curLevel;
end;

function VDbXmlFind(const Root: TXmlNode; const Path: string;
  First: Boolean): TXmlNode;
var
  all: TXmlNodes;
begin
  Result := nil;
  all := VDbXmlFindAll(Root, Path);
  if Length(all) > 0 then Result := all[0];
end;

function VDbXmlCount(const Root: TXmlNode; const Path: string): Integer;
var
  all: TXmlNodes;
begin
  all := VDbXmlFindAll(Root, Path);
  Result := Length(all);
end;


{ ------------------------------------------------------------
  Kurma
  //---------------------------------------------------------- }

function VDbXmlEscape(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    case S[i] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      '''': Result := Result + '&apos;';
    else
      Result := Result + S[i];
    end;
end;

function VDbXmlElement(const Name: string; const Content: string): string;
var
  body: string;
begin
  // Icerik zaten bir XML parcasiysa (kendi etiketleri varsa) KACISLANMAZ
  if (Pos('<', Content) > 0) and (Pos('>', Content) > 0) and
     (Copy(Trim(Content), 1, 1) = '<') then
    body := Content
  else
    body := VDbXmlEscape(Content);
  Result := '<' + Name + '>' + body + '</' + Name + '>';
end;

function VDbXmlConcat(const Parts: array of string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Parts) do
    Result := Result + Parts[i];
end;

function VDbXmlToText(N: TXmlNode): string;
var
  i: Integer;
begin
  if N = nil then Exit('');
  Result := '<' + N.Name;
  for i := 0 to High(N.AttrNames) do
    Result := Result + ' ' + N.AttrNames[i] + '="' + VDbXmlEscape(N.AttrVals[i]) + '"';
  if Length(N.Children) = 0 then
  begin
    if N.Text = '' then
      Result := Result + ' />'
    else
      Result := Result + '>' + VDbXmlEscape(N.Text) + '</' + N.Name + '>';
    Exit;
  end;
  Result := Result + '>';
  for i := 0 to High(N.Children) do
    Result := Result + VDbXmlToText(N.Children[i]);
  Result := Result + '</' + N.Name + '>';
end;

end.



