program hashchk;
{ KR-8 dogrulama: bolunmus hash yolu (VDbHashKeyPrefix + VDbHashKeyBytes)
  ile tek-parca VDbHashKey BIREBIR ayni QWord'u uretmeli. Satirdaki pk
  baytlari = UTF8Encode(Pk) oldugundan, tohum + pk baytlari katilimi
  VDbHashKey(Table, Pk) ile esit olmali. }
{$mode delphi}
uses
  SysUtils, VDbTable;
var
  tables, pks: array of string;
  ti2, pi: Integer;
  a, b, pre: QWord;
  u: RawByteString;
  bad, n: Integer;
begin
  tables := ['t', 'bench', 'Bench2', 'tablo ad', 'Çığırtkan_Ş', '', 'x', 'MIXEDCase'];
  pks := ['1','1000000','abc','','merhaba Dünya','Çiğ köfte', 'ünïcödé',
          'a'#0'b', '  spaces  ', 'Z'];
  bad := 0; n := 0;
  for ti2 := Low(tables) to High(tables) do
    for pi := Low(pks) to High(pks) do
    begin
      u := UTF8Encode(pks[pi]);
      pre := VDbHashKeyPrefix(tables[ti2]);
      if Length(u) > 0 then
        b := VDbHashKeyBytes(pre, @u[1], Length(u))
      else
        b := VDbHashKeyBytes(pre, nil, 0);
      a := VDbHashKey(tables[ti2], pks[pi]);
      Inc(n);
      if a <> b then
      begin
        Inc(bad);
        Writeln('MISMATCH table=', tables[ti2], ' pk=', pks[pi], ' a=', a, ' b=', b);
      end;
    end;
  if bad = 0 then
    Writeln('HASHCHK OK: ', n, ' karsilastirma BIREBIR esit')
  else
    Writeln('HASHCHK FAIL: ', bad, '/', n, ' uyusmazlik');
end.
