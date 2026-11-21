# VDB V3 - Ileri Sertlestirme Raporu (SKILL4)

Tarih: 2026-11-18
Surum: v3.72 (Sprint A + B + C + D + F1 + E + B2 + C2 + D2 + E2 + G1 + H + I + J + K + L + M + N + O + P + Q; soak/F-21/F-22 = v3.50; Sprint F belgeleri v3.51)
Dosya bicimi: **v5** (`VDB_FILE_VER = 5`, degismedi)
Durus: **BETA CANDIDATE**

Bu rapor SKILL4'un istedigi A-J basliklarini izler. Kural: **kosmayan test
PASS gosterilmez**. Olculen her sayi kaynakli verilir; olculmeyen her alan
acikca "olculmedi" / "not-run" yazilir. Bu belge bagimsiz denetim, saha
kullanimi veya uygunluk degerlendirmesi olmadan "CERTIFIED", "FIPS", "SIL"
veya "PRODUCTION READY" iddiasi kurmaz. Nihai siniflandirma bolum J'dedir.

Yardimci belgeler: `docs/audit/V3_FINAL_AUDIT.md` (bulgu tablosu F1-F22),
`docs/engineering/CI.md` (kapi tablosu ve run log'lari),
`docs/engineering/WAL_RECOVERY_AUDIT.md`,
`docs/engineering/STORAGE_AUDIT.md`,
`docs/engineering/BTREE_INTEGRITY.md`,
`docs/engineering/PERF_BASELINE.md`,
`docs/engineering/DISK_BTREE_DESIGN.md`,
`docs/engineering/SQL_SCALE.md`,
`docs/engineering/CRYPTO_PROVIDER.md`,
`docs/engineering/NETWORK_SECURITY.md`,
`docs/engineering/RESOURCE_LIMITS.md`,
`docs/engineering/LIMITS.md`,
`docs/security/THREAT_MODEL.md`,
`docs/security/SBOM.md`.

---

## A. Genel sonuc

### A.1 Tamamlanan fazlar

| Sprint | Kapsam | Durum | Cikti |
|---|---|---|---|
| A | WAL yasam dongusu + kaynak sinirlari | Tamam | WAL sert tavani (v3.44), `wal_limit` 19/0, `docs/engineering/LIMITS.md` + `RESOURCE_LIMITS.md` |
| B | SQL yurutucu olcegi | Tamam | `sql_scale` 34/0 (100k/1M), `docs/engineering/SQL_SCALE.md` |
| C | PostgreSQL diferansiyeli | **Kismi** | `sql_differential` 33/0 `pg=not-run`; ayri CI isi `sql_differential_postgres` (canli kosmadi) |
| D | Indeks olcegi + disk B+Tree arastirmasi | Tamam (kapsam sinirli) | `sql_index_scale` 45/0, `btree_disk` 78/0, `DISK_BTREE_DESIGN.md` |
| E | Soak + bellek dayanikliligi | Tamam (gomulu motor, kisa kosu) | `soak` 20/0, F-21 ve F-22 duzeltmeleri (v3.50) |
| F | Kripto + ag guvenligi | Tamam | `CRYPTO_PROVIDER.md`, `NETWORK_SECURITY.md`, `RESOURCE_LIMITS.md` |
| G | Platform + CI + son rapor | Tamam (matris dar) | Bu rapor + `CI.md` bolum 3 matris kapsami |

### A.2 Tamamlanmayan / kismi kalan fazlar

- **Canli PostgreSQL diferansiyeli**: bu ortamda `psql`/sunucu yok; 33 kontrol
  karsilastirma beklemeden kosar ve `pg=not-run` yazar. Gercek farklilik
  analizi **olculmedi**.
- **Uzun sureli soak**: `soak` kapisi 25 sn kosar. 1 saat / 6 saat / 24 saat
  kosu **yapilmadi**.
- **Ag sunucusu soak'i**: `soak` gomulu motordur; `TVdbPgServer` altinda uzun
  sureli, cok baglantili kosu **olculmedi**.
- **Disk tabanli indeks**: `VDbBTreeDisk.pas` bagimsiz ve kapili bir bilesen
  olarak vardir, v5 motor dosya bicimine **bagli degildir**; ikincil indeksler
  hala bellektedir.
- **macOS / ARM64 / buyuk-endian**: **not-run** (bolum H).
- **SKILL6 03 - SQL NULL ile bos metin ayrimi**: **TAMAM (asama 1 + 2a +
  2b + 2c, v3.72)**. Disk formati bunu zaten kodlayabiliyordu (v2/v3 satir
  govdesinde `lenCode = 0` NULL, `lenCode = 1` sifir uzunluklu metin), ancak
  bellekteki deger modeli `TStrArray` (duz metin) oldugu icin `DecodeRow`
  NULL'i `''` yapiyor ve `EncodeRow` `''`i NULL yaziyordu; `EvalExpr` de
  `sltNull` icin `''` donuyordu. Dort asama bunu kapatti:
  - **Asama 1 (v3.71)** depolama maskesi: `TNulArr`/`TNullMatrix`,
    `EncodeRowEx(..., const Nulls)`, `DecodeRowEx(..., out Nulls)`,
    `ScanRowsEx`/`ScanRowsPartEx(..., out Nulls)`. Maske verilince `''`
    gercek bos metin (`lenCode = 1`) yazilir, NULL `lenCode = 0` kalir;
    maske `nil` iken baytlar BIT BAZI aynidir (dosya bicimi v5 degismedi,
    `format_compat` 28/0).
  - **Asama 2a (v3.71)** ifade semantigi: `TVSqlExecutor.FCurNulls` +
    out-of-band `FLastNull`, `sltNull` artik NULL, NULL operandli
    aritmetik/karsilastirma UNKNOWN, `IS NULL`/`IS NOT NULL` bayraga bakar,
    AND/OR uc degerli (UNKNOWN AND FALSE = FALSE, UNKNOWN OR TRUE = TRUE).
    `EvalBinary`'ye `LNull`/`RNull`/`NullFlagsValid` eklendi ve
    `VDbCmpValEx(..., EmptyIsValue)` ile ayrim karsilastirmaya tasindi
    (`VDbCmpVal` bos-metin=NULL sarmalayicisi olarak kaldi).
  - **Asama 2b (v3.72)** okuma maskesi uctan uca: `ReadRowEx`/
    `ScanRowsEx`/`ScanRowsPartEx` -> `allNulls` -> filtre/RLS/join ->
    projeksiyon (`FNarrowNulls`, `FAggNulls`) -> `TSqlResult.RowNulls`.
    `COUNT(kolon)`, UNIQUE, GROUP BY/DISTINCT, `ORDER BY ... NULLS
    FIRST/LAST` ve `IS NULL` artik depolanmis degeri maskeden okur.
  - **Asama 2c (v3.72)** yazma maskesi: `TTableDef.HasNulls` (sema satiri
    `#N|<tablo>`) NULL tasiyan tabloyu indeks/covered-index/stream/COPY
    hizli yollarindan genel satir yoluna yonlendirir; `InsertEx`,
    `InsertReturning`, `UpdateRowInPlace`, `PutRow`, `UpdateWhere`,
    `UpsertRowReturning`, FK cascade ve `RewriteTable`/`RewriteTableRows`
    maskeyi tasir. Hizli INSERT seritleri maske tasimadigi icin NULL
    literal/parametre gorunce genel yola birakir (`VDbNullsAny`), aksi
    halde NULL ile `''` ayrimi o yolda sessizce kaybolurdu. Parametre
    maskesi SQL katmanindan gecer: `ParseEx` + `TVSql.Exec(Sql, Params,
    ParamNulls)` (tek atimlik `FPendParamNulls`), plan onbellegi yeniden
    baglanir. PG wire NULL'i `-1` olarak yazar (`DataRowMsgFmt(...,
    Nulls)`, Bind `plen = -1` -> `ParamsNull`).
  Kapi: `tests/null_empty` **41 PASS / 0 FAIL** (NE1-NE51, suite
  bayraklari `-MObjFPC -Scghi -O1`); on-kapi `git archive HEAD`
  (`a30676e`) uzerinde **30 PASS / 11 FAIL** (NE24, NE28, NE31, NE34 ve
  depolama bloklari) - yani kapi ayirt edicidir. Bu is sirasinda bulunan
  iki gercek kusur da kapandi: (i) hizli INSERT seritlerinin maskeyi
  atlayip `T.HasNulls`i hic isaretlememesi (bundan sonra her `''` NULL
  olarak saklaniyordu = veri kaybi), (ii) `ALTER TABLE ADD COLUMN`in
  `RewriteTable` icinde `oldNulls` dizisini boyutlandirmamasi
  (`EAccessViolation`, `sql_matrix` D6; `SetLength(oldNulls, ...)`
  eklendi).
  **Durust sinir**: (a) `COPY TO` text/Arrow/Parquet disa aktarimi NULL'i
  hala `''` yazar (bicimde ayrim yok); (b) covered-index hizli yolu ve
  projeksiyon oncesi `ORDER BY` siralamasi maskeyi tasimaz, o yollarda
  NULL `''` gibi gorunur; (c) `ExecGroupBy` `Res.RowNulls`i doldurmaz;
  (d) 2c oncesi yazilmis satirlar (maske disi) ayirt edilemez - `lenCode
  = 1` bos metin ile `lenCode = 0` NULL diskte farklidir ama okuyan taraf
  `HasNulls` bilgisine ancak tablo bir kez maskeli yazildiktan sonra
  sahip olur. Bu sinirlar veri kaybi degil, gosterim/okuma kapsamidir ve
  `CI.md`de kayitlidir.
- **SKILL6 04 - gercek akis (streaming)**: **TAMAM (Sprint R)**. Portal
  sonucu artik `FSql.Exec` ile tumuyle maddesellestirilmiyor: `TVdbRowCursor`
  yurutucu seviyesinde sayfa pencereli parca uretir, `Execute` parca basina
  `PortalSuspended` doner ve ayni imlec kaldigi yerden devam eder. COPY OUT
  (sorgu ve tablo bicimi) de imlecten akar. `MaxPortalResultBytes` artik
  **uretim sirasinda** uygulanir; asimda istek reddedilir ve imlec birakilir.
  Desteklenmeyen sekiller (ORDER BY, GROUP BY, DISTINCT, JOIN, UNION, pencere,
  alt sorgu, NULL tasiyan tablo, KV deposu, toplu yazim) tek seferlik genel
  yola duser; bu **durust sinirdir** ve bellek siniri o yollarda hala sonuc
  uretildikten sonra denetlenir. Ayrinti: F-50.
- **SKILL6 07 - genel hash join / maliyet modeli**: **KISMI**. `SELECT`
  tarafinda `TryStreamJoin` zaten PK arama, indeks kaynagi ve hash join
  yollarini secer (`merge_hash` kapisi M1-M13). Sprint P'de `UPDATE ... FROM`
  tarafi da **esitlik anahtarli hash birlestirmesine** cevrildi
  (`merge_hash` U1-U9; 4000 x 2500 satir 13063 ms -> 16 ms). Acik kalan:
  maliyet modeli cardinality/distinct/NULL orani/hash bellek maliyeti ile
  spill-to-disk kararlarini icermiyor; `UPDATE ... FROM` icinde esitlik
  conjunct'i yoksa (esitlik-disi WHERE) ve collation/sayisal denklik
  gerektiren durumlarda eski kartezyen yol guvenlik agi olarak duruyor.
- **SKILL6 08 - dis sistem uyumlulugu**: **TAMAM (v3.73)**. Depoya
  bagimlilik veya harici DLL **eklenmedi**; harici araclar yalniz depo
  disindan, dogrulama amaciyla kullanilir ve yoksa kapi 77 (SKIP) doner.
  (a) **Arrow/Parquet interop** iki katmanda olculur: `interop_format`
  (saf Pascal, her zaman kosar; VDB<->VDB gidis-donus + depoda duran pyarrow
  fiksturlerinin her hucresi) ve `interop_external` (pyarrow VDB ciktisini
  dogrular, pyarrow'un urettigi stream/Parquet/SNAPPY dosyalarini VDB
  birebir okur, `date64[ms]`/`time32[ms]`/`time64[us|ns]` birimlerini ayri
  ayri sinar). (b) **Kripto** `crypto_interop` (FIPS 180-4, RFC 4231,
  RFC 7914/6070, FIPS-197 C.3 ve GCM spesifikasyon vektorleri kaynaga
  gomulu) ve `crypto_interop_ext` (bagimsiz Python `hashlib`/`hmac`/
  `pbkdf2_hmac` diferansiyeli) ile dogrulanir. (c) **SQLite
  karsilastirmasi** `bench_sqlite`: ayni is iki motorda kosar, 12 anahtar
  uzerinden **sonuc esitligi** dogrulanir, sureler yalniz raporlanir.
  Bu calisma bir **gercek okuyucu kusuru** buldu ve kapatti (F-51).
  Durust sinir: iki bicimde de DECIMAL yoktur; VDB Parquet yazarken yalniz
  UNCOMPRESSED uretir (SNAPPY yalniz okunur); `TStrMatrix` NULL maskesi
  tasimadigi icin disa aktarimda NULL ve `''` ayni gorunur (belgelenmis
  sinir, kapi bunu gecmez saymaz); gercek PostgreSQL istemci matrisi
  (`psql`, JDBC, Npgsql) bu ortamda **kurulu degildir ve kosmadi** -
  `server_version = 14.0` bir uyumluluk sertifikasi **degildir**.

### A.3 Mevcut V3 durumu

- Iki platformda tam kapi seti yesil: **Windows i386 60 PASS**, **Linux
  x86_64 60 PASS**, FAIL 0 (v3.73 kosulari: `gatesP.log` / `linP.log`;
  Linux'ta `tls_client` gercekten kosar - 6/0, Windows'ta SKIP;
  Linux'ta `interop_external` pyarrow yoklugundan SKIP).
  Windows'ta `tls_client` bu ortamda **SKIP** oldu (OpenSSL DLL'i yok);
  kostugu kosu `gatesE.log`'dur. SKIP PASS sayilmaz (ayrinti: `CI.md`).
- Acik kritik hata yok. Kapatilan son gercek kusurlar: F-21/F-22 veri
  kaybi (SO15/SO16/SO17), Sprint B2'de acik islem icinde **statement
  atomikligi** (`sql_atomicity` AT20-AT24), Sprint C2'de **oturum bazli rol**
  ve bilinmeyen rolde **fail-closed** yetki (`sql_authorization` AU8-AU11),
  Sprint D2'de checkpoint hata yolunda **kilit sizintisi** (`disk_full`
  DF10a-DF10c), Sprint E2'de zaman asimi kurulumunda **fail-open** davranis
  (`network_limits` NL8), Sprint G1'de PG sunucusunun **guvensiz
  varsayilanlari** (`server_harden` S12-S15), Sprint H'de ozel TCP SQL
  sunucusunun **guvensiz varsayilanlari, zaman asimi ve parola denemesi
  siniri** (`server_failure` SF9-SF15), Sprint I'de dosya degistirme
  sirasinda **surecler arasi bakim kilidi ve bayat dosya kimligi**
  (`maint_lock` ML1-ML5), Sprint J'de PG portal **`maxRows` imleci ve
  portal/prepared statement kaynak sinirlari** (`pg_portal_stream` PP1-PP12),
  Sprint K'de **SERIALIZABLE'in hic dogrulanmamasi / write skew**
  (`serializable_tx` S1-S15, P1-P8), PG mesajlarinda **eksik NUL
  sonlandiricisinin sessizce kabul edilmesi** (`pg_msg_nul` N0-N8) ve
  `MERGE`in **kaba kuvvet O(hedef x kaynak) eslesmesi** (`merge_hash` M1-M13).
  Sprint L'de **SERIALIZABLE bayraginin backend genelinde tutulmasi** - bir
  baglanti `SET TRANSACTION ... SERIALIZABLE` dediginde **baska** bir
  baglantinin READ COMMITTED commit'i 40001 ile iptal ediliyordu
  (`serializable_tx` S16-S20).
  Sprint M'de **kimligi dogrulanmis kullanicinin SQL rolu ile eslesmemesi**
  (dogrulanmis uzak kullanici motor yoneticisi gibi davraniyordu), **bos
  rolu = sinirsiz yetki**, **`SET ROLE NONE` yetki yukselmesi**, **rol
  uyeligi denetiminin olmamasi** ve **oturum kimligi/rol durumunun
  sizmasi** (`sql_authorization` AU12).
  Sprint N'de **dosya degistirmede (VACUUM/Compact/Restore/Rekey) dizin
  fsync'inin hic yapilmamasi** (`maint_lock` ML6-ML7).
  Sprint O'da **ag zaman asiminin her recv/send cagrisi icin ayri
  uygulanmasi** (istemci her zaman asimindan once kucuk bir parca
  gondererek toplam mesaj suresini sinirsiz uzatabiliyordu) ve
  **PostgreSQL CancelRequest'in hic islenmemesi** (her baglantiya ayni
  `BackendKeyData(1, 0)` gonderiliyordu, yani iptal edilebilir bir anahtar
  yoktu) kapandi (`network_limits` NL9-NL12, `pg_cancel` PC0-PC9).
  Sprint P'de **`UPDATE ... FROM` esitlik birlestirmesinin kaba kuvvet
  O(hedef x kaynak) kartezyen dongu olmasi** kapandi (`merge_hash` U1-U9);
  eski yolda 4000 x 2500 satirlik guncelleme **13063 ms** suruyordu, yeni
  hash yolunda **16 ms**.
  Sprint Q'da **SQL NULL ile bos metnin ayni deger olmasi** kapandi:
  depolama maskesi (asama 1: `EncodeRowEx`/`DecodeRowEx`/`ScanRowsEx`),
  ifade semantigi (asama 2a: `FCurNulls`/`FLastNull`, `NULL IS NULL` = TRUE,
  `'' IS NULL` = FALSE, `NULL = ''` UNKNOWN, `NULL AND FALSE` = FALSE),
  okuma maskesi (2b: `Res.RowNulls`, `COUNT`/`UNIQUE`/`GROUP BY`/`ORDER BY`/
  PG wire `-1`) ve yazma maskesi (2c: `HasNulls` + tum yeniden-yazan yollar,
  `InsertEx`/`UpdateRowInPlace`/`UpsertRowReturning`/`RewriteTable`, parametre
  maskesi) uctan uca baglandi; `tests/null_empty` kapisi 41 kontrole
  buyudu ve on-kapi `a30676e` uzerinde **30 PASS / 11 FAIL** verirken simdi
  **41 PASS / 0 FAIL**.
  Sprint A/B'de kapatilan yetki ve atomiklik kusurlari `A.4`'te.
- Rol degistirme yetkisi ve SCRAM kullanicisi -> SQL rolu eslemesi (SKILL5
  3.1'in yetki denetimi ve 3.2) Sprint M'de **kapandi** (`sql_authorization`
  AU12): kimligi dogrulanmis principal artik SQL rolune baglanir, bos rol
  sinirsiz yetki **degildir** ve `SET ROLE NONE` taban role doner. Kalici
  (veritabaninda saklanan) kullanici/rol katalogu **hala yoktur**; esleme
  sunucu yapilandirmasindan (`AddUser(..., ASqlRole)` / `--user K:P:ROL`)
  gelir, yani dosya bicimi degismeden cozulebildi ve rol uyeligi duzdur
  (rol devralma/zincirleme yok). Bu sinirlar `F-45` paragrafinda yazili.
- V2 **dondurulmus** ve degismedi; v4 konteyner bicimi durduruldu.

### A.4 Denetim sprintleri (ONERILER_VE_HIZLANDIRMA2)

| Sprint | Kapsam | Durum | Cikti |
|---|---|---|---|
| A | 3.2 oturum kimligi, 3.3 upsert yetkisi, 3.4 MERGE RLS/trigger, 3.5 AFTER STATEMENT trigger sirasi | Tamam | `sql_authorization` 32/0 (yeni), `sql_atomicity` 23/0 (yeni) |
| B | SQL atomikligi: INSERT/UPDATE/DELETE/COPY/MERGE statement batch sinirlari, BEFORE STATEMENT trigger'lari | Tamam | `sql_atomicity` 88/0 (19 vaka) |
| C | 4.1 WAL-before-data checkpoint sirasi, 4.2 kurtarma basarisizliginda POISONED durumu | Tamam | `wal_recovery` 27/0 (yeni, 5 vaka) |
| D | 5.1 freelist butunlugu, 5.2 disk B+Tree sayfa butunlugu, 6.1/6.2 sayfa dogrulama | Tamam | `freelist` 32/0 (yeni, 9 vaka), `btree_disk` 78/0 |
| F | 8.2 LIMIT/OFFSET sinirlari, 8.4 ozyinelemeli CTE sinirlari + iptal, 8.5 sayisal tasma/CAST/ABS | Tamam (F1) | `sql_memory` 54/0 (yeni, 26 vaka) |
| F | 8.1 uctan uca streaming, portal maxRows, COPY OUT streaming, JOIN/ORDER BY/DISTINCT/GROUP BY bellek siniri, disk spill | **Kismi (F2)** - portal/COPY OUT akisi kapandi (Sprint R) | `R8`/`R13` |
| E | 7.1/7.2 sunucu okuma-yazma zaman asimi, 7.3 COPY gecici dosya sinir+izin, 7.4 baglanti yasam dongusu | Tamam | `network_limits` 22/0 (yeni, 8 vaka) |
| B2 | 6.1 acik islem icinde statement atomikligi (COMMIT sonrasi yarim yazim) | Tamam | `sql_atomicity` 138/0 (24 vaka; AT20-AT24 yeni) |
| C2 | 3.1 oturum bazli rol izolasyonu + bilinmeyen rolde fail-closed yetki | Tamam | `sql_authorization` 51/0 (32 -> 51; AU8-AU11 yeni) |
| D2 | 8.1 checkpoint hata yolunda surecler arasi yazma kilidi sizintisi | Tamam | `disk_full` 19/0 (16 -> 19; DF10a-DF10c yeni) |
| E2 | 9.1 zaman asimi kurulumu basarisizsa baglanti yine de sunuluyordu (fail-open) | Tamam | `network_limits` 26/0 (22 -> 26; NL8 yeni) |
| G1 | 5.2 PG sunucusu guvensiz varsayilanlar (tum arayuzlerde bind, trust kimlik dogrulama, politika katmanini atlama) | Tamam | `server_harden` 36/0 (25 -> 36; S12-S15 yeni) |
| H | 5.1/5.2/9.3 ozel TCP SQL sunucusu: tum arayuzlerde bind, duz metin parola icin sinirsiz deneme, zaman asimi yok, kilitsiz baglanti sayimi | Tamam | `server_failure` 30/0 (16 -> 30; SF9-SF15 yeni) |
| I | 7.1/7.2/7.3/7.4 dosya degistirme (VACUUM/Compact/Restore/Rekey) sirasinda surecler arasi bakim kilidi, yazar rezervasyonu, bayat dosya kimligi | Tamam | `maint_lock` 13/0 (yeni, ML1-ML5) |
| J | 9.5 portal/prepared statement kaynak sinirlari, 10.1 Execute `maxRows` ve gercek portal imleci | Tamam | `pg_portal_stream` 22/0 (yeni, PP0-PP12) |
| K | 6.x SERIALIZABLE hic dogrulanmiyor (write skew), 9.x PG mesajinda eksik NUL sessiz kabul, 10.x MERGE kaba kuvvet O(hedef x kaynak) | Tamam | `serializable_tx` 23/0, `pg_msg_nul` 10/0, `merge_hash` 19/0 (yeni) |
| L | SKILL6 01: SERIALIZABLE bayragi **backend genelinde** tutuluyordu (paylasilan `TVTableDb` yuzunden bir baglanti digerinin commit'ini 40001 ile iptal ediyordu); `.gen` okunamazsa "degismedi" varsayimi | Tamam | `serializable_tx` 28/0 (23 -> 28; S16-S20 yeni) |
| M | SKILL6 02: SCRAM yalniz kimlik dogruluyordu, SQL rolu ile **eslesmiyordu** (dogrulanmis uzak kullanici = motor yoneticisi); bos rol = **sinirsiz yetki**; `SET ROLE NONE` yetki yukselmesiydi; rol uyeligi denetlenmiyordu; oturum kimligi isaretci kirpintisiydi ve rol durumu bir sonraki baglantiya miras kaliyordu | Tamam | `sql_authorization` 62/0 (51 -> 62; AU12 yeni) |
| N | SKILL6 06: dosya degistirmede (VACUUM/Compact/Restore/Rekey) **dizin fsync'i hic yapilmiyordu**; rename/silme cokme sonrasi kaybolabiliyor, eski WAL geri gelebiliyordu | Tamam | `maint_lock` 19/0 (13 -> 19; ML6-ML7 yeni) |
| O | SKILL6 05: ag zaman asimi **her recv/send cagrisi icin** ayri uygulaniyordu (damla/drip istemcisi toplam sureyi sinirsiz uzatiyordu); **CancelRequest (80877102) hic islenmiyordu** ve her baglantiya ayni `BackendKeyData(1, 0)` gonderiliyordu | Tamam | `network_limits` 41/0 (26 -> 41; NL9-NL12 yeni), `pg_cancel` 31/0 (yeni, PC0-PC9) |
| P | SKILL6 07: `UPDATE ... FROM` esitlik birlestirmesi **kaba kuvvet O(hedef x kaynak)** kartezyen donguydu (4000 x 2500 satirda 13063 ms) | Tamam | `merge_hash` 30/0 (19 -> 30; U1-U9 yeni) |
| Q | SKILL6 03: **SQL NULL ile bos metin ayni degerdi** (`'' IS NULL` TRUE donuyordu, `'' = ''` UNKNOWN cikiyordu, `COUNT(kolon)` NULL satirlari sayiyordu); depolama maskesi (asama 1), ifade semantigi (2a), okuma maskesi (2b) ve yazma maskesi (2c) uctan uca baglandi; hizli INSERT seridi ile `ALTER TABLE ADD COLUMN` kusurlari kapandi | Tamam | `null_empty` 41/0 (14 -> 41; NE20-NE51 yeni); on-kapi `a30676e` 30/11 |
| R | SKILL6 04: portal **tek seferde maddeselestiriyordu** (maxRows yalniz dilimleme; COPY OUT tam sonuc bellekte); gercek satir yineleyicisi yoktu | Tamam | `pg_portal_stream` 35/0 (22 -> 35; PS0, PS1-PS10 yeni); on-kapi `e31d186` 33/2 (dusen: PS4, PS7a) |
| S | SKILL6 08: Arrow okuyucu `Date.unit`/`Time.unit` sema varsayilanini **SECOND/DAY** saniyordu; Arrow semasinda varsayilan MILLISECOND oldugu icin pyarrow `date64[ms]`/`time32[ms]` icin `unit` alanini **hic yazmaz** ve VDB degeri 1000 kat kaydiriyordu (`00:00:00`, `0000-00-00`). Ayrica Arrow/Parquet, bagimsiz kripto ve SQLite uyumlulugu icin kalici kapi yoktu (yalniz kendi kodumuzla gidis-donus) | Tamam | `interop_format` 21/0, `interop_external` 8/0 (on-kapi **6/2**, ayirt edici X4+X8), `crypto_interop` 33/0, `crypto_interop_ext` 25/0, `bench_sqlite` 24/0; F-51 |

Sprint A gercek kusurlari kapatti: baglanti artik yetkisiz baslamaz (global
`FSessionId` yetki kaynagi degil, yalniz LOGIN sayaci); `admin/admin123`
varsayilani kaldirildi; upsert yolu UPDATE yetkisi/RLS/ROW trigger uygular;
MERGE normal DML ile ayni RLS ve trigger kurallarina tabidir; AFTER STATEMENT
trigger'lari commit'ten once ateslenir.

Sprint B dort kusuru kapatti:

- **B1 (veri kalintisi)**: `INSERT` (tum yollar) ve `COPY` icin BEFORE
  STATEMENT trigger'i **batch acilmadan once** atesleniyordu; govdesindeki DML
  ana statement hata verse bile kalici olabiliyordu. Artik batch icinde.
- **B2 (eksik davranis)**: `UPDATE` ve `DELETE` icin BEFORE **STATEMENT**
  trigger'i **hic ateslenmiyordu** (yalniz satir seviyesi calisiyordu).
- **B3 (savunma)**: INSTEAD OF INSERT govdesi batch'siz satir satir
  calisiyordu. **Not**: parser `CREATE TRIGGER` icin yalniz BEFORE/AFTER
  ayristirir, `INSTEAD OF` uretilemedigi icin bu yol bu surumde ulasilamaz;
  duzeltme kod savunmasidir ve kapiyla dogrulanamaz.
- **B4 (veri kaybi)**: 0 satir eslesen `DELETE` dalinda kosulsuz `AbortBatch`
  cagriliyor, BEFORE STATEMENT trigger'inin yaptigi DML sessizce
  kayboluyordu; artik trigger calistiysa `CommitBatch`.

Kapinin kendisi dogrulandi: ayni test dosyasi duzeltme ONCESI kaynakla
(`git archive HEAD`) derlenip kosuldugunda **8 kontrol FAIL** (AT8 x3, AT9 x2,
AT10, AT18, AT19) ve cikis kodu 1; duzeltilmis agacta **88/0**. Yani kapi
gercekten kusuru yakaliyor, bos yesil degil.

Sprint C iki kusuru kapatti ve iki yeni sinir getirdi:

- **C1 / 4.1 (WAL-before-data, veri kaybi)**: checkpoint sirasi tersti.
  `FStore.Flush(True)` veri dosyasini fsync ediyor, WAL bariyeri
  (`AwaitDurable`) **ondan sonra** bekleniyordu. WAL fsync basarisiz olursa
  dayanikli olmayan commit'in veri sayfalari diskte kaliyor ve yeniden
  acilista "hayalet commit" goruluyordu. Yeni sira: WAL yaz, WAL fsync,
  durabil LSN dogrula, **sonra** veri sayfalarini yaz + fsync, sonra WAL'i
  yalniz durabil checkpoint sinirina kadar buda.
- **C2 / 4.2 (kurtarma basarisizligi)**: `RecoverAfterDurabilityFailure`
  hicbir istisna yakalamiyordu; hata `FLastCommitProblem` metni olarak
  yutuluyor ve motor yarim kurtarilmis halde kullanilabilir kaliyordu. Artik
  kurtarma hatasi motoru **POISONED** yapar: `Poisoned`/`PoisonReason`
  ozellikleri, `ecInvalidState` hata kodu ile tum okuma ve yazma giris
  noktalari (motor ve backend) reddeder; kapatip acma temiz baslangic verir.
- **Duzeltme (kurtarma sonrasi kilit)**: basarili kurtarma `FSyncErr`
  alanini temizlemedigi icin sonraki her `AwaitDurable` aninda hataya
  dusuyordu; artik basarili kurtarma bu durumu sifirlar.
- **Durust sinir**: `.gen` eslemesindeki durabil-LSN aynasi yalniz Windows'ta
  kurulur (`MapGen` tamamen `{$IFDEF WINDOWS}`). Linux'ta bu ayna yoktur;
  surecler arasi durabil-LSN paylasimi Linux'ta calismaz. Kapi bu yuzden
  motor duzeyindeki `Engine.DurableLsn` degerini olcer ve store aynasini
  yalniz raporlar (`store=0` Linux'ta beklenen degerdir).
- **Durust sinir**: kapi cokmeyi `SimulateCrash` ve hata kancalariyla taklit
  eder; gercek elektrik kesintisi dayanikliligi iddia edilmez. Gercek surec
  olumu `crash_points` kapisinda ayrica kosar, ancak isletim sistemi
  onbellegi fsync edilmemis baytlari koruyabildigi icin o kapi 4.1'i tek
  basina yakalayamazdi.

`wal_recovery` kapisi 5 vaka / 27 kontrol: hayalet commit yoklugu, checkpoint
bariyerinin veri yazimindan once kurulmasi, POISONED reddi ve kurtarma
sonrasi tekrar yazilabilirlik, basarili kurtarmanin durabil satiri koruyup
fsync edilmemis satiri atmasi, normal yolun zehirlenmemesi. Duzeltme oncesi
kaynakla derlenen sondada **3 kontrol FAIL** (wr1/durable-kept, wr1/no-ghost-row,
wr2/wal-durable-before-flush); duzeltilmis agacta 27/0.

Sprint D iki depolama butunlugu acigini kapatti:

- **D1 / 5.1 (freelist butunlugu, veri kaybi)**: serbest sayfa listesi
  (trunk zinciri) hicbir zaman dogrulanmiyordu. Ayni sayfa iki kez serbest
  birakilirsa ya da bir **trunk** sayfasi serbest birakilirsa, ayni fiziksel
  sayfa iki farkli sahibe verilebiliyor ve birinin satirlari digeri tarafindan
  ezilebiliyordu. `FreePage` artik (a) zaten serbest olan sayfayi, (b) trunk
  sayfasini, (c) **canli hucre tasiyan** heap sayfasini reddeder;
  `AllocPage` F-22 savunmasini ikinci hat olarak korur. Ayni sprintte
  `CollectFreePages` ve `VerifyFreeList` kurallari hizalandi: zincir dongusu,
  yinelenen girdi, aralik disi girdi ve `FreeCount` uyusmazligi **acik hata**
  olarak bildirilir (istisna degil, `False` + `Err` metni).
- **D2 / 5.2 + 6.1/6.2 (disk B+Tree sayfa butunlugu)**: diskten okunan
  sayfada CRC, sayfa kimligi ve yapisal tutarlilik dogrulanmiyordu; bozuk bir
  sayfa sessizce geziliyor ve `MarkReachable` onu **serbest** ilan edip geri
  kazanabiliyordu. `ReadPage` artik diskten okunan her sayfada `CheckPageStruct`
  calistirir (CRC + kimlik + yapisal sinir kontrolleri); `MarkReachable` kisa
  okuma, kotu CRC ve bozuk yapida `EBtdError` atar. **Sozlesme degisikligi**:
  bozuk B+Tree dosyasi artik **acilmaz**; `BD15`/`BD16` eski sessiz davranisi
  dogruladigi icin yeniden yazildi (`RestampCrc` ile "CRC gecerli, yapi bozuk"
  durumu uretiliyor).
- **Kapi kaniti**: `freelist` kapisi 9 vaka / 32 kontrol (FL1 cift serbest
  birakma, FL2 trunk serbest birakma, FL3 canli hucreli sayfa, FL4 cok trunk /
  bos trunk / sayac, FL5 zincir dongusu, FL6 yinelenen girdi, FL7 aralik disi
  girdi, FL8 bozuk freelist ile acilis, FL9 iki denetleyicinin ayni sonucu).
  Ayni test dosyasi duzeltme **oncesi** kaynakla (`git archive HEAD`)
  derlenip kosuldugunda **4 kontrol FAIL** (cift serbest birakma, trunk serbest
  birakma, canli sayfa, yinelenen girdi); duzeltilmis agacta 32/0. `btree_disk`
  78/0.
- **Kendi regresyonumuz (durust kayit)**: Sprint D'nin ilk hali `soak` kapisini
  kirdi (SO2/SO3/SO12/SO16/SO17, 5 FAIL; `freelist indeksi: girdi aralik disi`).
  Kok neden `FreeIndexEnsure` icindeki dongu sayacinin `LongWord` olmasiydi:
  `cnt = 0` iken `Integer(cnt) - 1 = -1`, sayac `LongWord` oldugu icin
  `$FFFFFFFF`'e donusuyor ve dongu sayfa disindaki cop girdileri okuyordu.
  Sayac `Integer` yapildi; `CollectFreePages` ve `VerifyFreeList`'teki ayni
  kalip `if cnt > 0` ile korunmus oldugu icin dokunulmadi. HEAD'agac soak'i
  20/0, duzeltilmis agac soak'i 20/0.
- **Durust sinir**: `VDbBTreeDisk` bagimsiz bir bilesendir; SQL motoruna
  **baglanmamistir**, ikincil indeksler hala bellekte tutulur. D2 bu bilesenin
  kendi sayfa yolu icin gecerlidir, motorun indeks yolu icin degil.

Sprint F iki parcaya ayrildi: **F1 (bu sprintte kapatildi)** 8.2/8.4/8.5
sinir ve sayisal uc davranislari; **F2 (acik)** 8.1/8.3 mimari bellek
sinirlari. F1 dort gercek kusur kapatti:

- **F1-a / 8.5 (CAST sessiz sarmasi, yanlis veri)**: `VDbParseInt` birikimi
  `res * 10 + d` ile **tasmayi denetlemeden** yapiyordu. Int64 araligini asan
  metin sarmalayip **yanlis sayi** donduruyordu:
  `CAST('9999999999999999999999' AS INTEGER)` -> `1864712049423024127`,
  `CAST('999999999999999999999999' AS INTEGER)` -> `2003764205206896639`.
  Artik birikim `QWord` + isaret basina tavan (`2^63-1` / `2^63`) ile yapilir,
  aralik disi metin gecersizdir ve `CAST` `ecTypeMismatch` atar.
  `-9223372036854775808` (`Low(Int64)`) gecerli kalir.
- **F1-b / 8.5 (ABS hassasiyet kaybi)**: `ABS` ilk olarak `VDbParseFloat`
  deniyordu; her tam sayi metni float olarak da gecerli oldugu icin **her
  zaman** float donuyordu: `ABS(9223372036854775806)` -> `9.22337203685478E18`.
  Artik once `VDbParseInt` denenir; sonuc tam sayi metni olarak doner.
- **F1-c / 8.5 (Low(Int64) isareti)**: `-v` ve `ABS` `Low(Int64)` uzerinde
  **sessizce sarmaliyordu** (isaret yanlis kaliyordu). Ikisi de artik
  `ecMathError` atar. Parser ayrica `-<tam sayi>` bicimini isaretle **birlikte**
  cozer; `ParsePrimary`'nin negatif dali onceden hic ulasilamiyordu.
- **F1-d / 8.4 (ozyinelemeli CTE sessiz kesmesi)**: `VDB_RECUR_MAX` (100.000
  tur) sinirina takilan ozyineleme **kismi sonucu hata vermeden** donduruyordu:
  `WITH r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r) SELECT n FROM r` ->
  `1..100001`, hata yok. Artik (a) sinir asimi `ecLimit` atar, (b) dogal bitiste
  `deltaRows` bosaltilir (yanlis pozitif yok), (c) tur basina `VDB_MAX_RESULT_ROWS`
  satir tavani uygulanir, (d) dongu `TickAbort` cagirir (iptal edilebilirlik).
- **Kapi kaniti**: `sql_memory` kapisi 26 vaka / 54 kontrol. Ayni test dosyasi
  duzeltme **oncesi** kaynakla (`git archive HEAD`) derlenip kosuldugunda
  **6 kontrol FAIL**: SM15 x2 (CAST 22/24 hane), SM20 x2 (`ABS` float +
  `ABS(Low)`), SM22 (sonsuz ozyineleme sessiz kesme), SM26 (`-v` sarmasi);
  duzeltilmis agacta 54/0. Kapinin geri kalan 48 kontrolu 8.2 LIMIT/OFFSET
  (LIMIT 0, negatif LIMIT/OFFSET, `OFFSET 2147483647`, tavan asimi,
  ORDER BY+LIMIT'in tam siralamanin **oneki** olmasi: ASC/DESC/cok anahtar/NULL)
  ve 3VL/NULL semantigini **dondurur**; bunlar duzeltme oncesinde de dogruydu
  ve gate'e yalnizca kilit olarak girdi.
- **Durust duzeltme (olcum kapisi)**: `perf_baseline` 47 kapili kosuda
  `btree/scale-linear` oranini **4,64** olctu ve kirmizi oldu. Ayni ikili tek
  basina uc kez kosuldugunda **1,50 / 1,98 / 2,32** cikti; yani gerileme degil,
  tam sureler birkac on ms iken tek bir zamanlayici duraklamasinin sisirmesi.
  Olcum her boyut icin **iki kez** yapilip **kucuk** olani alinir. **Esik
  degismedi (3,5)**; karesel davranis hala yakalanir. Bu, kapinin gecmesi icin
  esik gevsetme **degildir**; olcum gurultusunun alinmasidir.
- **Durust sinir (F2 kismen acik)**: 8.1'in portal `maxRows` ve COPY OUT
  streaming ayaklari **Sprint R'de (SKILL6 04) kapandi**: portal ve COPY OUT
  artik `TVdbRowCursor` uzerinden gercek satir akisindan beslenir (F-50).
  Acik kalan: ORDER BY/DISTINCT/GROUP BY icin kontrollu **disk spill**, JOIN
  bellek butcesi ve hash birlestirme **uygulanmadi**; akisli olmayan
  sekillerde sonuc hala `TSqlResult` icinde tamamen bellekte toplanir, tavan
  `VDB_MAX_RESULT_ROWS = 2.000.000`. Ozyinelemeli CTE satir tavani bu tavanla
  **ayni degeri** kullanir (daha kucuk bir butce yoktur).

Sprint E (ag katmani) dort gercek sinir kusurunu kapatti:

- **E1 / 7.1-7.2 (yavas istemci = kalici DoS, kullanilabilirlik)**: sunucu
  soketlerinde okuma/yazma zaman asimi **yoktu**. Kabul edilen her baglanti
  icin zamanlayici kurulmuyor; bir istemci tek bayt gonderip beklediginde
  `HandleQuery` sonsuza kadar blokluyor ve baglanti slotu **asla** bosalmiyordu.
  `MaxConns = 1` iken tek yarim acilmis baglanti sunucuyu kalici olarak
  kapatabiliyordu. Duzeltme: `VdbSockSetTimeouts` (`VDbNet.pas`,
  `SO_RCVTIMEO`/`SO_SNDTIMEO`; Windows'ta DWORD ms, Unix'te `timeval`) ve
  `TVdbPgServer` uzerinde `ReadTimeoutMs`/`WriteTimeoutMs`, varsayilan
  **30000 ms**, 0 = devre disi (eski davranis). Zaman asimi kabul edilen
  sokete, is parcacigi baslamadan once uygulanir.
- **E2 / 7.3 (sessiz cerceve dusurme, teshis edilebilirlik)**: on-kapa asan
  cerceve yalniz `Break` ile baglantiyi **sessizce** kapatiyordu; istemci
  nedenini ogrenemiyordu. Artik `MaxMessageBytes` (varsayilan **64 MiB**)
  asildiginda kontrollu bir `ErrorResponse` (`SQLSTATE 54000`) gonderilir ve
  baglanti kapatilir. **Durust sinir**: govde okunmaz (bellek sisirilmez);
  kapanis bilinclidir.
- **E3 / 7.3 (sinirsiz gecici dosya + izin)**: `COPY ... FROM STDIN` gecici
  dosyaya yazarken **toplam** boyut siniri yoktu; kimligi dogrulanmis bir
  istemci diski doldurabiliyordu. Artik `CopyMaxBytes` (varsayilan
  **256 MiB**) toplam sinir, parca basina ayrica tavan uygulanir; asimda
  kontrollu hata. Unix'te gecici dosya `fpChmod 0600` ile olusturulur
  (`BaseUnix`); Windows'ta `GetTempDir` zaten kullaniciya ozeldir.
- **E4 / 7.4 (kilitlenmeyen kapasite okumasi, veri yarisi)**: kapasite
  kontrolu `FConns.Count` alanini **kilitsiz** okuyor ve bitmis (Finished)
  is parcaciklarini da sayiyordu; bu yuzden bos slot varken "kapasite dolu"
  donulebiliyor ya da tersi olabiliyordu. `GetConnCount` artik kilit altinda
  ve yalniz canli baglantilari sayar (`ConnCount` ozelligi).
- **7.4 yasam dongusu incelemesi (kusur bulunmadi)**: `Stop`/`GcFinished`
  sirasi incelendi; `Stop` once dinleme soketini kapatip kabul dongusunu
  uyandiriyor, ardindan biten is parcaciklarini topluyor. Bu sirada bir
  **kusur bulunmadi**; kod degistirilmedi ve "duzeltildi" diye
  raporlanmaz.
- **Kapi kaniti**: `network_limits` kapisi 8 vaka / **22 kontrol** (NL0-NL7):
  zaman asimi kurulumu (okuma/yazma, devre disi, gecersiz soket), yavas
  istemcinin slotu birakmasi, `MaxConns=1` ile ikinci istemcinin girebilmesi,
  asiri cercevenin `54000` ile reddedilmesi, `CopyMaxBytes` toplam tavaninin
  uygulanmasi ve normal baglantinin etkilenmemesi. Duzeltme **oncesi**
  kaynakla (`git archive HEAD`) derlenen sondada **1 kontrol FAIL**:
  `H1` yarim startup sonrasi yeni istemci **6031 ms** sonra hala giremiyor
  (`MaxConns=1`, kalici DoS). Duzeltilmis agacta 22/0.
- **Durust sinir**: E1-E3 soket duzeyinde olculur; TLS el sikismasi icin
  **ayri** bir zaman asimi testi yoktur (el sikismasi ayni soket uzerinde
  kosar, dolayisiyla zaman asimi uygulanir, ama bu ayrica olculmedi).
  VDB'nin `COPY ... FROM STDIN` varsayilan bicimi PostgreSQL text degil
  **csv**'dir; tavan davranisi bu bicimle olculdu. F2 halen aciktir.

Sprint B2 (SKILL5 6.1) acik islem icindeki **statement atomikligi** acigini
kapatti:

- **B2 / 6.1 (COMMIT sonrasi yarim yazim, veri butunlugu)**: acik bir islemde
  (`BEGIN`) yarida hata veren bir DML cumlesinin **o ana kadar yazdigi
  satirlar** yazma kaplamasinda kaliyordu; sonraki `COMMIT` bunlari **kalici**
  hale getiriyordu. Hata alan istemci "hicbir sey yazilmadi" varsayimiyla
  devam edebildigi icin bu sessiz veri bozulmasidir. Olculdu (duzeltme oncesi
  kaynak): tek satirli bir trigger hatasi sonrasi `BEGIN` icinde 2 satir
  gorunuyor ve `COMMIT` sonrasi da 2 satir kaliyordu.
- **Cozum**: statement cevresinde **ortuk savepoint** (`BeginStmtScope` /
  `ReleaseStmtScope` / `RollbackStmtScope`, `IVDbBackend` arayuzunde
  tanimli). Basarili cumlede kapsam yalnizca kapanir (veri COMMIT EDILMEZ);
  hata yolunda yalnizca **o cumlenin** yazimlari kaplamadan dusurulur, onceki
  cumlelerin yazimlari korunur. Kapsam yalnizca yazma cumleleri icin ve acik
  yazma kumesi varken acilir; islem denetim cumleleri (BEGIN/COMMIT/ROLLBACK/
  SAVEPOINT/RELEASE) ve DDL kapsam disidir, boylece kapsam kapanisi
  kullanicinin savepoint'ini silemez. Kapsam kimligi bulunamazsa (cumle
  icinde COMMIT/ROLLBACK oldu) sessizce donulur ve istisna firlatilmaz:
  asil hata maskelenmemeli.
- **Bellek siniri**: ortuk kapsam, yeni anahtarlar icin gunluk girdisi
  **yazmaz**. Kapsam kapanirken `BatchOrder`/`BatchMap` kayitlari kapsam
  anindaki uzunluga kirpilarak dusurulur; boylece 200k satirlik toplu INSERT
  satir basina sozluk girdisi odemez. Maliyet yalnizca gercekten degistirilen
  eski anahtarlar kadardir.
- **Ikinci kusur (olcumle bulundu)**: `TVSql.Exec`'in iki overload'unda
  literal/parametreli INSERT hizli yolu `InBatch` denetimini **oturum
  sabitlenmeden once** yapiyordu. `InBatch`/`Savepoints`/`BatchMap` oturum
  basina tutuldugu icin denetim **cagiranin ortam oturumuna** bakiyor, acik
  islemde `False` donuyor ve hizli yol statement kapsami **acmadan** yaziyordu.
  Artik yazma oturumu `Exec`/`ExecRaw` govdesinin **tamamini** sarar ve
  `InBatch` karari dogru oturumla verilir; acik islemde iki hizli yol da
  atlanir. Bu duzeltme olmadan kapsam yalnizca bazi cumlelerde calisiyordu.
- **V2 dondurulmus**: `TVdbBackendV2` ucguna da bos uygulama aldi
  (`BeginStmtScope` = -1). V2 davranisi **degismedi**; V2 yolunda acik
  islemde statement atomikligi yoktur ve bu bilinen sinirdir.
- **Kapi kaniti**: `sql_atomicity` 19 vaka / 88 kontrolden **24 vaka / 138
  kontrol**e cikti. Yeni vakalar: AT20 (trigger hatasi + `COMMIT` sonrasi 0
  satir), AT21 (basarisiz coklu INSERT sonrasi onceki cumlenin satiri korunur),
  AT22 (basarisiz cumleden sonra ayni anahtar yeniden eklenebilir; bayat
  kaplama kaydi yok), AT23 (UNIQUE cakismasiyla yarida kalan UPDATE geri
  alinir, onceki UPDATE korunur), AT24 (kullanici `SAVEPOINT`'i ortuk
  kapsamlardan etkilenmez). Duzeltme **oncesi** kaynakla (`git archive HEAD`
  `4214586`) derlenen kapida **6 kontrol FAIL**, cikis kodu 1; duzeltilmis
  agacta 138/0. Yani kapi bos yesil degil.
- **Durust sinir**: kapsam kaplama duzeyinde calisir; diskte yarim kalan bir
  sayfa yazimi icin ek bir mekanizma degildir (o is `wal_recovery` ve
  POISONED yolu). Kapsam yalnizca **acik islem** icinde acilir; otomatik
  commit yolunda tek cumle zaten butun olarak uygulanir veya geri alinir.

Sprint C2 (SKILL5 3.1) **oturum bazli rol izolasyonu** ve bilinmeyen rolde
**fail-closed** yetki acigini kapatti:

- **Olculen kusur (sizinti)**: `TVTableDb` tek nesnedir ve tum baglantilar onu
  paylasir (`VDbPgWire.pas` bir `Ftb` olusturur, her istemciye ayri `TVSql`
  verir). Rol tek bir alanda (`FCurrentRole`) tutuldugu icin **bir istemcinin
  `SET ROLE` cagrisi tum istemcilerin etkin rolunu degistiriyordu**: ikinci
  baglanti, kendi iradesi disinda birinci baglantinin kisitli roluyle
  calisiyor ve yazma yetkisini kaybediyordu.
- **Duzeltme**: rol artik `VDbGetTxnSession` anahtarli bir sozlukte
  (`FRoleBySession`) tutulur; `EffectiveRole` once oturumun rolune bakar,
  yoksa gomulu varsayilana duser. `RoleCan`, `RlsApplies`, `RequirePriv` ve
  `CurrentRole` okumasi bu fonksiyonu kullanir. `SET ROLE` oturum anahtari
  varsa sozluge yazar; oturum yoksa (gomulu kullanim) eski davranis aynen
  surer. `DROP ROLE` silinen rolu tum oturumlardan da dusurur; aksi halde o
  oturumda "bilinmeyen rol" kalir ve asagidaki fail-closed kurali oturumu
  kilitlerdi.
- **Ikinci kusur (fail-open)**: eski `RoleCan`, adi `FRoles`'ta bulunmayan bir
  rol icin **`True`** donuyordu; yani yazim hatasiyla verilen bir rol tam
  yetki veriyordu. Artik bilinmeyen rol **reddedilir** (`False`).
- **Kapi kaniti**: `sql_authorization` 32 kontrolden **51 kontrole** cikti.
  Yeni vakalar: AU8 (iki `TVSql` oturumu tek `TVTableDb` uzerinde; birinde
  `SET ROLE app` digerinin yazma yetkisini **etkilemez** - asil izolasyon
  kaniti), AU9 (bilinmeyen rol adi SELECT/INSERT/ALL icin reddedilir; motor
  kullanici modu serbest kalir), AU10 (oturum kapsami ve `SET ROLE NONE`
  semantigi), AU11 (`DROP ROLE` oturumdaki rolu temizler). Duzeltme
  **oncesi** kaynakla (`git archive HEAD` `05136af`) derlenen kapida
  **5 kontrol FAIL** (AU8 x2 izolasyon, AU9 x3 fail-open), duzeltilmis agacta
  51/0.
- **Durust sinir**: bu sprint **sizintiyi** ve **fail-open** kusurunu kapatti.
  Rol **degistirme yetkisi** (kim hangi role gecebilir) hala uygulanmiyor:
  kimligi dogrulanmis principal ile SQL rolu arasinda kalici bir esleme
  (SKILL5 3.2) yok ve bu, kalici sema/dosya bicimi degisikligi gerektirir;
  bicim v5 degismedi. Bu nedenle "yetkisiz rol yukseltmesi tamamen kapandi"
  denmiyor. Kisitli bir rolu `SET ROLE NONE` ile birakip motor kullanici
  moduna donmek mumkundur (PostgreSQL de bunu oturum kullanicisina donus
  sayar); principal eslemesi olmadan bunu yasaklamak guvenlik eklemez, yalnizca
  mevcut kullanimi bozar. Denenen bu yasak (olculdu: mevcut AU1-AU7
  temizliginde `SET ROLE NONE` kullaniliyor) 7 kontrolu dusurdugu icin geri
  alindi ve sinir olarak belgelendi.

Sprint D2 (SKILL5 8.1) **checkpoint hata yolunda kilit sizintisini** kapatti:

- **Olculen kusur**: checkpoint sirasindaki ilk sayfa yazimi
  (`WritePageAt`/`SaveMeta` -> `EnsureIoWrite`) surecler arasi **tam
  (exclusive) dosya kilidini** alir ve `FAutoWrite` isaretini kurar. Kilidi
  birakan `EndIoWrite` **yalnizca normal yolun sonunda** cagriliyordu; bu
  yuzden `AwaitDurable`, durabilite bariyeri dogrulamasi, `FStore.Flush`
  (disk dolu / IO hatasi) veya `FWal.Truncate` hata verdiginde kilit bu
  surecte **asili** kaliyordu. Sonuc: hata veren surec kapanana kadar
  diger tum surecler commit edemiyor (busy timeout) ve kalici disk-dolu
  durumunda sizinti kendiliginden temizlenmiyordu.
- **Duzeltme**: `TVdbPageEngine.Checkpoint` govdesi `try ... finally
  FStore.EndIoWrite; end;` ile sarildi ve normal yoldaki ikinci cagri
  kaldirildi (tek birakma noktasi). Kilid artik **her durumda** birakilir;
  sayfa/WAL durumu degismez, yalnizca kilit sahipligi duser. Salt-okunur
  erken cikis (`Exit(True)`) `try` disinda kalir (kilit zaten alinmiyor).
- **Kapi kaniti**: `disk_full` 16 kontrolden **19 kontrole** cikti. Yeni
  vaka DF10: meta sayfa yazimina sert hata enjekte edilerek checkpoint
  `ecIOError` ile dusurulur (DF10a), ardindan **ayni dosyaya ikinci bir
  backend** acilip yazma denenir (400 ms busy timeout) ve satir okunur.
  Duzeltme **oncesi** kaynakla (`git archive HEAD` `a3b97da`) derlenen
  kapida **4 kontrol FAIL** (DF10b/DF10c; ek olarak DF6/DF6b - sizinti
  kapanistan sonra da yeniden acilisi kilitliyordu), duzeltilmis agacta
  19/0.
- **Durust sinir**: kapi hatayi **enjekte eder** (gercek `ENOSPC`
  olculmedi) ve ikinci backend **ayni surecte** acilir; kilit dosya
  tanitici/handle basina oldugu icin bu, sizintiyi ayirt etmek icin
  yeterlidir, ancak ayri bir isletim sistemi sureciyle de tekrarlanmadi.
  Checkpoint'in kendisi hata verdiginde WAL/veri dosyasi tutarliligi bu
  vakada olculmez (o is `wal_recovery`/POISONED ve DF9 yollarinda).

Sprint E2 (SKILL5 9.1) **zaman asimi kurulumundaki fail-open davranisi** kapatti:

- **Olculen kusur**: `TVdbPgAccept.Execute` kabul ettigi sokette
  `VdbSockSetTimeouts` cagiriyor ama **donus degerini yutuyordu**. Kurulum
  basarisiz olsa da baglanti sunuluyor ve o sokette **sinirsiz bloklama**
  suruyordu; tek bayt gonderip bekleyen istemci slotu/is parcacigini surekli
  tutabiliyor, `MaxConns` kadar bos soket sunucuyu kalici olarak
  kapatabiliyordu. Yani Sprint E1'in getirdigi zaman asimi korumasi, en cok
  gerektigi yerde sessizce devre disi kalabiliyordu.
- **Duzeltme**: `TVdbPgAccept.Execute` artik **fail-closed**: zaman asimi
  kurulamazsa baglanti **hic sunulmaz**, protokol mesaji gonderilmeden
  kapatilir ve slot tuketilmez. Iki zaman asimi da `0` ise (yapilandirmayla
  bilerek kapatilmis) kurulum basarili sayilir; bu durumda fail-closed
  devreye girmez. Kapi icin sunucuya **test-only** bir kanca
  (`SockTimeoutFunc`; uretimde `nil`, varsayilan gercek cagri) eklendi.
- **Kapi kaniti**: `network_limits` 22 kontrolden **26 kontrole** cikti.
  Yeni vaka NL8: kanca "kurulum basarisiz" dondurur, istemci baglanip tek
  bayt bekler; soket kapanir, kapatma 3 s icinde olur, `ConnCount` sifir
  kalir. Duzeltme **oncesi** kaynakla (HEAD + yalnizca test kancasi;
  fail-closed blogu cikarilarak) derlenen kapida **1 kontrol FAIL**
  (NL8: `ConnCount=1`, baglanti sunulmus), duzeltilmis agacta 26/0.
- **Durust sinir**: baseline kapisi HEAD + test kancasi olarak kuruldu
  (kanca olmadan kapi derlenemez); fail-closed blogu disinda hicbir sey
  degistirilmedi. Ayrica NL8'in ilk iki kontrolu (soket kapandi / 3 s
  icinde) baseline'da da gecer: istemcinin kendi 700 ms okuma zaman asimi
  "veri gelmedi" sonucunu uretiyor. Ayirt edici olan **slot** kontroludur.
  Gercek isletim sistemi hatasi (`setsockopt` hatasi) enjekte edilmedi;
  hata yolu kanca ile taklit edildi.


---

## B. WAL

| Konu | Olculen davranis | Kanit |
|---|---|---|
| WAL sert tavani | `VDB_WAL_MAX_BYTES`, varsayilan **64 MiB**. `VDbPageEngine.DoCommit` butun cerceveler tamponda ve `FWal.Bytes` kesinken, WAL'e **tek bayt yazilmadan once** kontrol eder; asimda `ecLimit`, commit kaydi yazilmaz, onceki onayli commit'ler durabil kalir | `wal_limit` 19/0 |
| Yumusak esik | `MaybeCheckpoint` tavanin **yarisinda** senkron checkpoint calistirir; kucuk yazimlar tavana yaklasmaz | `wal_limit`, `cache_metrics` 21/0 |
| Islem tavani | Tek islemde **1 048 576** degisen sayfa; 1M sayfalik islem ~4 GiB WAL uretir ve tavanda reddedilir (parcalanmalidir) | `txn_limit` 18/0 |
| Uzun islem | 300 kisa islem + 75 geri alma birebir dogrulanir; ic ice `BEGIN` ve islem yokken `COMMIT`/`ROLLBACK` sessiz no-op; tek yazar rezervasyonu + kontrollu `mesgul` | `txn_limit` TL1-TL8 |
| Checkpoint | `Checkpoint(True)` acik cagriyla ve esik/yumusak sinirda calisir; basarisiz checkpoint yan dosyalara dokunmaz | `soak` SO16, `single_file` 35/0 |
| Recovery | Kesik kuyruk geri kirpilir; `WriteChecked` tek yazma noktasi; commit kaydi yoksa satir durabil olmaz | `wal_crash`, `kv_wal`, `crash_points` 24/0 |
| WAL reclaim | Kapanista checkpoint basariliysa ve ayni dosyaya acik baska oturum yoksa `.wal`/`.gen` silinir; basarisizsa yan dosyalar korunur (veri kaybi yerine fazladan dosya) | `single_file`, `multi_writer` 12/0 |
| Crash testleri | Enjekte edilmis cokme noktalari, WAL yazma hatasi, disk dolu | `crash_points` 24/0, `disk_full` 19/0 |
| WAL-before-data (4.1) | Checkpoint WAL bariyerini (fsync + durabil LSN dogrulama) veri sayfalari yazilmadan **once** kurar; WAL fsync basarisizsa veri dosyasina dokunulmaz, yeniden acilista hayalet commit gorunmez | `wal_recovery` WR1, WR2 |
| POISONED (4.2) | Kurtarma basarisiz olursa motor `POISONED` olur: okuma ve yazma `ecInvalidState` ile reddedilir; kapatip acma temiz baslangic verir | `wal_recovery` WR3, WR4, WR5 |

**Durust sinir**: WAL ozellikle tek yazar rezervasyonu modeline dayanir;
cok yazarli yuksek cakisma altinda gecikme davranisi olculmedi. `VDB_WAL_MAX_BYTES=0`
tavani kapatir; bu modda "sinirsiz WAL" davranisi kasitlidir, koruma yoktur.
`.gen` eslemesindeki durabil-LSN aynasi yalniz Windows'ta kurulur; Linux'ta
store aynasi okunamaz (`Engine.DurableLsn` motor duzeyinde dogru calisir).
`wal_recovery` cokmeyi hata kancalariyla taklit eder; gercek elektrik
kesintisi dayanikliligi iddia edilmez.

---

## C. SQL Executor

| Konu | Olcum | Kanit |
|---|---|---|
| 100k satir | Ekleme **656 ms** (Windows i386) / **1213 ms** (Linux x86_64); dosya 3.997.696 B | `sql_scale` SS1-SS10 |
| 1M satir | Ekleme **6547 / 11849 ms**; dosya 37.543.936 B | `sql_scale` SS11-SS20 |
| 1M LIMIT'siz `SELECT *` | **516 / 900 ms**, tam 1M satir doner (ilk/orta/son deger dogrulanir) | `sql_scale` |
| ORDER BY / LIMIT / OFFSET / toplama / GROUP BY / HAVING / JOIN / UPDATE / DELETE | Hepsi dogru sonuc; karisik islem; buyuk islem commit/rollback; yeniden acilis + tam `VERIFY` temiz | `sql_scale` 34/0 |
| Toplam kontrol | 34 kontrol, iki platformda ayni satir/deger | `sql_scale` 34/0 |
| RAM | `TotalAllocated` deltasi (**RSS degil**); alet SS20'de 8 MB ayirmayla dogrulanir | `sql_scale` SS20 |
| LIMIT'siz tavan | `VDB_MAX_RESULT_ROWS = 2.000.000`; asimda `ecLimit`, kismi sonuc donmez | `limits` L4 18/0 |
| OOM | Enjekte edilen tahsis hatasi okuma ve yazma yolunda `EOutOfMemory`; sayfa ayirma atomik, taninmayan sayfa kalmaz, basarisiz commit hayalet satir birakmaz | `oom` 9/0 |
| Streaming | **KISMI**. PG portal ve `COPY OUT` **gercek satir akisindan** beslenir (`TVdbRowCursor`, SKILL6 04 / Sprint R); gomulu `Exec` yolu ve akisli olmayan sekiller (ORDER BY/GROUP BY/DISTINCT/JOIN/UNION/pencere/alt sorgu) sonuc kumesini biriktirir. Bu yuzden 2M+ satirlik LIMIT'siz tarama hala kapiya baglanmadi (32-bit surecte ~GB bellek) | `docs/engineering/SQL_SCALE.md`, `pg_portal_stream` 35/0 |

**Durust sinir**: F9 kismi kapali kalir - tavan **degerinin kendisi** (2M+)
maddelestirilmedi. Streaming olmadigi icin cok buyuk sonuc kumesi bellek
baskisi uretir; tavan bunu reddeder ama "akis halinde isler" denemez.

---

## D. PostgreSQL

| Konu | Durum |
|---|---|
| Gercek PostgreSQL surumu | **Kosulmadi**. Ayri CI isi `sql_differential_postgres` `postgres:16` servisi tanimlar; bu ortamda hic kosmadi |
| Calistirilan test sayisi | `sql_differential` **33/0**, ancak karsilastirma yapilmadan: `pg=not-run` |
| Uyumluluk | PG wire uyumlu **alt kume**; startup, basit ve genisletilmis sorgu, hata yollari |
| Farkliliklar | Canli PG ile olculmedi; bilinen sapmalar `docs/engineering/SQL_DIFFERENTIAL.md` icinde |
| Desteklenmeyen SQL | Kapsam `docs/engineering/SQL_COVERAGE.md`; indeks/DDL alt kumesi sinirli |
| SKIP davranisi | `run_pg.sh` baglanti yoksa **77 (SKIP)** doner ve PASS sayilmaz; is yesil gorse bile kanit uretmez |

**Durust sinir**: Burada "PostgreSQL ile uyumlu" iddiasi **kurulmaz**. 33
kontrol, diferansiyel altyapisinin ve SQL yuzeyinin kendi icinde tutarli
oldugunu gosterir; PostgreSQL'e karsi fark analizi yapilmamistir. Bu raporun
en buyuk olculmemis alani budur.

---

## E. SQL Index

| Konu | Olcum / durum | Kanit |
|---|---|---|
| Bellek tabanli indeks | **Var**: birincil anahtar ve `CREATE INDEX` ile ikincil indeksler `FMemIdx` / `TVDbBTree` icinde | `sql_index_scale` IX1-IX20 |
| Disk tabanli indeks | **Bagimsiz bilesen** `VDbBTreeDisk.pas` (4096 B sayfa, golge sayfalama, atomik commit, yirtik meta geri donusu). v5 motor dosya bicimine **bagli degil** | `btree_disk` 78/0 |
| 1M benchmark | `CREATE INDEX ix_m_v` **1016 / 1700 ms**; indeksten nokta okuma **0 / 1 ms**; yeniden acilis sonrasi ilk indeksli sorgu **1203 / 1586 ms**; indeks basina satir maliyeti **24 / 49 B**; `.odb.idx` 1M icin **10.985.254 B** (iki platformda ayni) | `sql_index_scale` 45/0 |
| 10M benchmark | **Yok** - kosmadi | - |
| Lookup performansi | Yukaridaki nokta okuma degerleri; plan dogrulamasi (`Index Scan using t_pkey`, `Index Only Scan using ix_t_w`, indekssizde `Seq Scan`) | `sql_index_scale` |
| Disk boyutu | `.odb.idx` **yeniden uretilebilir onbellek**tir; veri kaynagi degildir. Bozulursa veri kaybi olmadan tarama ile dogru sonuc | `sql_index_scale` IX18a/IX18b |
| Mimari oneri | Ikincil indeksleri `VDbBTreeDisk` uzerine tasimak **onkosullu** bir is: snake-case birlesme, sayfa yeniden dagitimi ve v5 dosya bicimine baglama gerekir. `DISK_BTREE_DESIGN.md` tasarimi yazar, uygulanmadi | `DISK_BTREE_DESIGN.md` bolum 7 |

**Durust sinir**: "VDB disk indeksi kullaniyor" demek bugun **yanlistir**.
Kapilar disk indeks olcmez; yalnizca bagimsiz `VDbBTreeDisk` bilesenini olcer.
100k indeks kurulumunda Windows'ta yigin deltasi **-104 KB** cikti (ayirici
bloklari yeniden kullandi), bu yuzden yalnizca 1M satir basina maliyet
raporlanir.

---

## F. Network

| Konu | Olcum | Kanit |
|---|---|---|
| Fuzz sayisi | **N1a-N15** (15 saldiri ailesi) + **120** yinelemeli tohumlanmis mutasyon + **4 is parcacigi x 8 eszamanli fuzz**; kapida **39 kontrol** | `net_fuzz` 39/0 |
| Crash sayisi | **0**. Her senaryodan sonra sunucunun hizmeye devam ettigi ayrica dogrulanir; her bozuk girdi yalniz o baglantiyi dusurur | `net_fuzz` |
| Seed | **Sabit/deterministik** (tekrar uretilebilir). Rastgele seed modu yok | `net_fuzz` |
| Soak suresi | Ag sunucusu soak'i **kosulmadi**. Gomulu motor `soak` kapisi **25 sn** (varsayilan, `VDB_SOAK_SECONDS`, 5..86400) | `soak` 20/0 |
| FD/RAM/thread olcumu | **Gomulu motor** soak'unda her turda: heap `TotalAllocated` deltasi (**RSS degil**), dosya tanitici/sap, is parcacigi, WAL bayti, dizin bayti, p50/p95 gecikme. SO5-SO10 tavan kontrolleri | `soak` SO5-SO10 |
| Kimlik dogrulama | SCRAM-SHA-256 (parola sunucuda saklanmaz); `AuthMaxFailures=5`, pencere 60 sn, **monotonik** `GetTickCount64` (F-20) | `auth_throttle` 16/0 |
| TLS | **Varsayilan kapali** (opt-in). Istemcide CA dosyasi zorunlu; dogrulamasiz baglanti yolu yok | `tls_client` 6/0 (yalniz Linux), `VDbTls.pas` |
| Baglanti tavani | `MaxConns` 64 (1..4096); asimda yeni baglanti `kapasite dolu` alir, mevcutlar calisir | `server_failure` 16/0 |
| Cerceve tavani | Agdan gelen tek metin cercevesi 64 MiB (`VDBS_MAX_RECV_STR`); PG telinde `MaxMessageBytes` (varsayilan **64 MiB**) asiminda kontrollu `ErrorResponse` (`SQLSTATE 54000`) ve baglanti kapanisi (Sprint E2) | `net_fuzz` N7, `network_limits` NL4 |
| Zaman asimi | Baglanti basina `ReadTimeoutMs`/`WriteTimeoutMs`, varsayilan **30000 ms**, 0 = kapali; yavas/yarim acilmis istemci slotu **birakir** (Sprint E1). Zaman asimi kurulamazsa baglanti **sunulmaz** (fail-closed, Sprint E2) | `network_limits` NL0-NL3, NL7, NL8 |
| COPY tavani | `COPY ... FROM STDIN` toplam `CopyMaxBytes` **256 MiB** + parca basina tavan; Unix'te gecici dosya `0600` (Sprint E3) | `network_limits` NL5, NL6 |
| Kapasite sayaci | `ConnCount` kilit altinda, yalniz canli baglantilar (Finished haric); `MaxConns` karari bu sayidan (Sprint E4) | `network_limits` NL1, NL2, NL7, `server_failure` 16/0 |

**Durust sinir**: `net_fuzz` sabit seed'li, sinirli bir senaryo kumesidir;
AFL/libFuzzer tarzi surekli fuzz kampanyasi **degildir**. Ag sunucusunun uzun
sureli FD/RAM/thread davranisi **olculmedi**; bu yuzden "ag sunucusunda sizinti
yok" iddiasi kurulmaz. mTLS, CRL/OCSP, IP basina hiz siniri, DDoS korumasi ve
denetim kaydi butunlugu **yoktur** ve iddia edilmez
(`NETWORK_SECURITY.md` bolum 3).

---

## G. Crypto

| Konu | Durum | Kanit |
|---|---|---|
| Mevcut algoritmalar | SHA-256, HMAC-SHA256, AES-256-GCM (nonce 12, tag 16), PBKDF2-HMAC-SHA256, Argon2id, CSPRNG, tek blok AES-256 (yalniz selftest) | `VDbCryptoProvider.pas`, `docs/engineering/CRYPTO_PROVIDER.md` |
| Varsayilan provider | **`builtin`** - saf Pascal, sifir harici DLL | `VDbCryptoProvider.pas` (R-5/K1) |
| OpenSSL | Yalniz **acik opt-in** (`VDB_CRYPTO_PROVIDER=openssl` veya API). Sessiz fallback **yok**; `VDB_CRYPTO_DLL` yalnizca yol ipucu | `VDbCryptoOpenSSL.pas` |
| Yetenek farki | `builtin` Argon2id + `capAes256Block` sunar, >64 B HMAC anahtari **sunmaz**. OpenSSL >64 B HMAC sunar, Argon2id ve `capAes256Block` **sunmaz** | Yetenek matrisi |
| Test vektorleri | `crypto_core` PASS, `crypto_base64` PASS, `crypto_kat` PASS, `selftest_builtin` PASS, `fixtures_builtin` PASS | `CI.md` kapi tablosu |
| Dosya bicimi uyumlulugu | `format_compat` 28/0 (v3/v4 yukseltme, v6 reddi, yirtilma) | `format_compat` |
| Acik riskler | `capHmacKeyOver64` borcu (ADR 6); KDF parametreleri cagiranin sorumlulugunda; anahtar surec belleginde (mlock/zeroize garantisi platforma bagli, iddia edilmez); OpenSSL 3.2+ Argon2 yeniden degerlendirilmeli | `CRYPTO_PROVIDER.md` bolum 5 |
| Bagimsiz denetim ihtiyaci | **VAR**. `crypto_kat`/`selftest_builtin` bir duman/vektor testidir; FIPS 140-3, CAVP veya bagimsiz kripto denetimi **degildir** | `CRYPTO_PROVIDER.md` bolum 3 |

**Durust sinir**: DCPcrypt tamamen kaldirildi (`NOTICE`). "Sertifikali
kripto" iddiasi yoktur. Provider secimi yetenek degistirir; operator
`openssl` secerse Argon2id gerektiren yollari kullanmamalidir.

---

## H. CI

| Platform | Kapi | PASS | FAIL | SKIP | NOT-RUN |
|---|---|---|---|---|---|
| Windows i386 (`windows-latest` / Git Bash) | 48 | **48** | 0 | OpenSSL istege bagli 2 | - |
| Linux x86_64 (`ubuntu-latest` / WSL x86_64) | 49 | **49** | 0 | OpenSSL istege bagli 2 (`VDB_CRYPTO_DLL` yok) | - |
| macOS (x86_64 / arm64) | - | - | - | - | **not-run** |
| linux/arm64 | - | - | - | - | **not-run** |
| windows/arm64 | - | - | - | - | **not-run** |
| Buyuk-endian | - | - | - | - | **not-run** |
| Canli PostgreSQL (`sql_differential_postgres`) | - | - | - | - | **not-run** (bu ortamda kosmadi) |

- Matris `.github/workflows/ci.yml` icinde **yalniz** `ubuntu-latest` ve
  `windows-latest` calistirir; `fail-fast: false`. macOS/ARM64 icin job
  **yoktur** cunku hic kosulmadi; dogrulanmamis platformu matrise eklemek
  yesil gorunen ama kanit uretmeyen bir kapi olurdu (`CI.md` bolum 3).
- Kanit (en guncel kosu, v3.67): Windows `gatesJ.log` (`KOSAN KAPI: 53`,
  `SUITE_EXIT=0`), Linux `linJ.log` (`KOSAN KAPI: 54`, `SUITE_EXIT=0`).
  Onceki kosu (v3.66/L) ayni `gatesJ.log` / `linJ.log` dosyalarina yazdi ve
  bu kosu tarafindan uzerine yazildi (53 / 54 - kapi sayisi degismedi,
  Sprint M mevcut `sql_authorization` kapisini buyuttu); ondan once (v3.65/K)
  53 / 54; ondan once (v3.64/J)
  50 / 51; ondan once (v3.63/I)
  49 / 50; ondan once (v3.62/H)
  48 / 49; ondan once `gatesI.log` (48) / `linI.log` (49) - D2; ondan once
  `gatesH.log` (48) / `linH.log` (49) - C2; ondan once
  `gatesG.log` (48) / `linG.log` (49) - B2; ondan once
  `gatesE.log` (48) / `linE.log` (49); Sprint E oncesi
  `gatesF.log` (47) / `linF.log` (48); daha once `gatesD.log` (46) /
  `linD.log` (47), ondan once `gatesB.log` (44) / `linC.log` (46) idi.
  Sayilar her sprint yalniz **eklenen** kapi kadar artar, kapi silinmez.
  Sprint I yeni kapi dizini `tests/maint_lock` ekledi (13 kontrol); kapi
  sayisi Windows 48 -> 49, Linux 49 -> 50. Sprint J yeni kapi dizini
  `tests/pg_portal_stream` ekledi (22 kontrol); sayilar Windows 49 -> 50,
  Linux 50 -> 51. Sprint K **uc** yeni kapi dizini ekledi
  (`tests/serializable_tx` 23, `tests/pg_msg_nul` 10, `tests/merge_hash` 19);
  sayilar Windows 50 -> 53, Linux 51 -> 54. Sprint L (SKILL6 01) yeni kapi
  dizini eklemedi; `tests/serializable_tx` kapisini 23 -> **28** kontrole
  buyuttu (S16-S20), kapi sayisi 53 / 54 kaldi. Sprint M (SKILL6 02) da
  yeni kapi dizini eklemedi; `tests/sql_authorization` kapisini 51 -> **62**
  kontrole buyuttu (AU12), kapi sayisi yine 53 / 54 kaldi. Sprint N
  (SKILL6 06) da yeni kapi dizini eklemedi; `tests/maint_lock` kapisini
  13 -> **19** kontrole buyuttu (ML6-ML7), kapi sayisi 53 / 54 kaldi.
  Sprint O (SKILL6 05) **iki** kapiyi buyuttu: yeni kapi dizini
  `tests/pg_cancel` (31 kontrol) ve `tests/network_limits` 26 -> **41**
  kontrol (NL9-NL12); sayilar Windows 53 -> **54**, Linux 54 -> **55**.
  Sprint P (SKILL6 07) yeni kapi dizini eklemedi; `tests/merge_hash`
  kapisini 19 -> **30** kontrole buyuttu (U1-U9), kapi sayisi 54 / 55 kaldi.
  Sprint Q (SKILL6 03) yeni kapi dizini **ekledi**: `tests/null_empty`
  (41 kontrol, NE1-NE51); sayilar Windows 54 -> **55**, Linux 55 -> **56**.
  Sprint S (SKILL6 08) **bes** yeni kapi dizini ekledi:
  `tests/interop_format` (21 kontrol), `tests/interop_external` (8),
  `tests/crypto_interop` (33), `tests/crypto_interop_ext` (25) ve
  `tests/bench_sqlite` (24); kosan kapi sayisi Windows 55 -> **60**, Linux
  56 -> **60** (Linux'ta `interop_external` pyarrow yoklugundan SKIP olur ve
  kosan sayisina eklenmez).
- Windows `gatesJ` kosusunda `tls_client` **SKIP** oldu: ortamda
  `VDB_CRYPTO_DLL`/`VDB_SSL_DLL` yok. `tls_client` fikstur dizinini
  `VDB_TLS_FIXTURES` ile bulur; degisken verilmezse kapi exe'nin yanindan
  arar ve bulamaz (daha once ilk denemede FAIL, degisken verilince SKIP).
  Linux'ta fikstur otomatik bulundu ve kapi **kostu**: 6/6 PASS. Windows'ta
  `tls_client`'in kostugu kosu `gatesE.log`'dur (DLL'ler o ortamda vardi).
  Iki ortam arasindaki bu fark kosan kapi sayisini **60/60** yapar (her iki
  platformda 3 SKIP; SKIP PASS sayilmaz).
- **NOT-RUN** satirlari "kosmuyor" degil "olculmedi" demektir; bu raporda
  PASS sayilmaz.

---

## I. Acik riskler

Her satir: onem, dosya, kok neden, etki, test, durum.

| # | Onem | Dosya / alan | Kok neden / etki | Test | Durum |
|---|---|---|---|---|---|
| R1 | **Yuksek** | `sql_differential` / CI | Canli PostgreSQL karsilastirmasi kosmadi; SQL uyumlulugu **olculmedi**, yalnizca kendi icinde tutarli | `sql_differential` 33/0 `pg=not-run` | **ACIK** |
| R2 | **Yuksek** | `tests/soak` | Uzun sureli (1h/6h/24h) kosu yapilmadi; uzun vadeli kaynak sizintisi iddia edilemez. Yalnizca 25 sn'lik kosuda SO5-SO10 tavanlari asilmadi | `soak` 20/0 | **ACIK** |
| R3 | **Yuksek** | `TVdbPgServer` | Ag sunucusu soak'i ve cok baglantili uzun sureli FD/RAM/thread davranisi olculmedi | - | **ACIK** |
| R4 | Orta | `net_fuzz` | Sabit seed + sabit uzunluklar; yeni hata sinifi yakalanmayabilir; surekli fuzz yok | `net_fuzz` 39/0 | **ACIK** |
| R5 | Orta | `VDbBTreeDisk` / motor | Ikincil indeksler bellekte; `.odb.idx` onbellektir. Disk indeks mimarisi tasarlandi, uygulanmadi. Sprint D sayfa dogrulamasini ekledi ama bilesen motora **bagli degil** | `btree_disk` 78/0, `sql_index_scale` 45/0 | **ACIK (tasarim)** |
| R6 | Orta | `VDbCryptoBuiltin` | `capHmacKeyOver64` yok; >64 B HMAC anahtari reddedilir (sessiz kirpma yok) | `crypto_*`, `selftest_builtin` | **ACIK (bilinen borc, ADR 6)** |
| R7 | Orta | `VDbPgWire` | TLS varsayilan kapali; operator acmazsa trafik duz metin. mTLS/CRL/OCSP yok | `tls_client` SKIP (Windows) | **ACIK (bilincli opt-in)** |
| R8 | Orta | `TVdbExecutor` | `FSql.Exec` sonucu hala `TSqlResult` icinde tamamen bellekte toplar, tavan `VDB_MAX_RESULT_ROWS = 2.000.000` (32-bit ~GB bellek). SKILL6 04 akisi yalniz `TVdbRowCursor` uzerinden PG portal ve COPY OUT'a bagladi; gomulu `Exec` yolu maddeselestirmeye devam eder. Sprint F1 yalniz 8.2/8.4/8.5 sinirlarini kapatti | `limits` L4 18/0, `sql_memory` 54/0, `pg_portal_stream` 35/0 | **KISMI (akisli portal kapali; `Exec` acik)** |
| R13 | Orta | `TVdbExecutor` / `TVdbPgWire` | PG portal `maxRows` ve COPY OUT artik **imlecten** akar (SKILL6 04); ancak ORDER BY/DISTINCT/GROUP BY/JOIN/UNION/pencere/alt sorgu, NULL tasiyan tablo, KV deposu ve toplu acilis tek seferlik genel yola duser ve orada butce ancak maddeselestirme SONRASI denetlenir. Disk spill, JOIN bellek butcesi ve hash birlestirme hala yok; `8.3`'teki `ExecMerge` O(n*m) olcumu yapilmadi | `pg_portal_stream` 35/0 | **KISMI (akisli sekillerde kapali; genel yol acik)** |
| R9 | Dusuk | `soak` olcum | Heap olcusu `TotalAllocated`, RSS degil; "RSS sizmaz" iddiasi yok | `soak` SO5 | **ACIK (olcum siniri)** |
| R10 | Dusuk | `bench_report` / `soak` | Gecikme tek makine, `-O1`; SLA degil, donanimlar arasi normallestirilmedi | `bench_report` 35/0 | **ACIK (olcum siniri)** |
| R11 | Dusuk | Platform matrisi | macOS/ARM64/buyuk-endian **not-run** | - | **ACIK** |
| R12 | Dusuk | `disk_full` sonrasi | Disk dolduktan sonraki operator toparlanmasi kapsam disi | `disk_full` 16/0 | **ACIK (kapsam)** |

Kapatilmis kritik bulgular (F1-F18) `docs/audit/V3_FINAL_AUDIT.md` bulgu
tablosundadir. Bu sprintte kapatilanlar:

- **F-21 (Yuksek, KAPALI)**: heap dizini yalniz canli anahtar sayisina gore
  buyuyordu; mezar taslari doldurunca `Insert` sessizce `False` donuyor,
  backend bunu "anahtar zaten var" sanip guncelleme dalina giriyor ve
  `toplu yazim basarisiz` veriyordu. `FUsed` canli + mezar tasi izler;
  doygunlukta `EVdbHeap` atar. Regresyon: SO15a-SO15d.
- **F-22 (Kritik, KAPALI)**: serbest birakilan sayfanin diskteki imaji
  silinmiyordu; yeniden acilista heap sayfasi sanilip icine satir yaziliyor,
  sonra `AllocPage` ayni sayfayi `PageInit` ile sifirlayarak onayli satirlari
  sessizce siliyordu (olculen: 2.000 satirdan 104'u, 520 tur churn; kayip
  icin checkpoint + yeniden acilis birlikte gerekiyordu). Duzeltme:
  `CollectFreePages`, `Open` atlamasi, `SpaceHintScan` filtresi, `AllocPage`
  savunmasi. Regresyon: SO16/SO17.
- **F-33 (Kritik, KAPALI, v3.57)**: acik islemde yarida hata veren DML
  cumlesinin yazdigi satirlar kaplamada kaliyor ve sonraki `COMMIT` bunlari
  kalici hale getiriyordu (olculen: trigger hatasi sonrasi `BEGIN` icinde 2
  satir, `COMMIT` sonrasi da 2 satir). Ayni olcum ikinci bir kusur daha
  gosterdi: `TVSql.Exec` hizli yollari `InBatch` denetimini oturum
  sabitlenmeden once yapiyordu, bu yuzden acik islemde hizli yol statement
  kapsami acmadan yaziyordu. Duzeltme: ortuk statement kapsami
  (`BeginStmtScope`/`ReleaseStmtScope`/`RollbackStmtScope`) + yazma oturumu
  sabitlemesinin `Exec`/`ExecRaw` govdesinin tamamini sarmasi. Regresyon:
  AT20-AT24 (`sql_atomicity` 138/0).
- **F-34 (Kritik, KAPALI, v3.58)**: `TVTableDb` tek nesne oldugu icin rol tek
  alanda tutuluyordu ve **bir baglantinin `SET ROLE` cagrisi tum
  baglantilarin** etkin rolunu degistiriyordu (yetki sizmasi; ikinci oturum
  kendi iradesi disinda kisitli rolle calisip yazma yetkisini kaybediyordu).
  Ayni alanda ikinci kusur: `RoleCan`, `FRoles`'ta bulunmayan bir rol adi icin
  **`True`** donuyordu (fail-open; yazim hatasi tam yetki veriyordu).
  Duzeltme: rol `VDbGetTxnSession` anahtarli `FRoleBySession` sozlugunde,
  `EffectiveRole` once oturuma sonra gomulu varsayilana bakar; bilinmeyen rol
  artik **reddedilir**; `DROP ROLE` rolu tum oturumlardan dusurur. Regresyon:
  AU8-AU11 (`sql_authorization` 51/0; duzeltme oncesi kaynakta 5 FAIL).
  **Kismi**: rol degistirme yetkisi (kim hangi role gecebilir) ve SCRAM
  kullanicisi -> SQL rolu eslemesi **hala ACIK** (principal eslemesi kalici
  sema degisikligi gerektirir; bicim v5 degismedi).
- **F-35 (Kritik, KAPALI, v3.59)**: `TVdbPageEngine.Checkpoint` hata yolunda
  `EndIoWrite` cagrilmadigi icin ilk sayfa yazimindan sonra olusan hata
  (`AwaitDurable`, durabilite bariyeri, `Flush`, `Wal.Truncate`) surecler
  arasi **exclusive dosya kilidini bu surecte asili** birakiyordu; diger
  tum yazarlar busy timeout'a dusuyordu (olculen: hata sonrasi ikinci
  backend 400 ms icinde kilit alamadi, hatta kapatip yeniden acma 4000 ms
  icinde basarisiz). Duzeltme: checkpoint govdesi `try ... finally
  FStore.EndIoWrite` ile sarildi, normal yoldaki ikinci cagri kaldirildi.
  Regresyon: DF10a-DF10c (`disk_full` 19/0; duzeltme oncesi kaynakta 4 FAIL).
- **F-36 (Yuksek, KAPALI, v3.60)**: `TVdbPgAccept.Execute` kabul ettigi
  sokette `VdbSockSetTimeouts`'in **donus degerini yutuyordu** (fail-open).
  Zaman asimi kurulamadiginda baglanti yine de sunuluyor ve o sokette
  **sinirsiz bloklama** suruyordu; tek bayt gonderip bekleyen istemci slotu
  ve is parcacigini surekli tutabiliyor, `MaxConns` kadar bos soket sunucuyu
  kalici kapatabiliyordu. Duzeltme: fail-closed - kurulum basarisizsa
  baglanti protokol mesaji gonderilmeden kapatilir ve slot tuketilmez; iki
  zaman asimi da `0` ise (bilerek kapatilmis) kurulum basarili sayilir.
  Regresyon: NL8 (`network_limits` 26/0; HEAD + test kancasi baseline'inda
  1 FAIL - baglanti sunulmus, `ConnCount=1`).
- **F-37 (Kritik, KAPALI, v3.61)**: `TVdbPgServer` **guvensiz varsayilanlarla**
  geliyordu ve R-4 politika katmanini **atliyordu**. Uc kusur ayni yerdeydi:
  (a) `FBindHost` varsayilani `'0.0.0.0'` idi - kutuphane kullanan her surec
  farkinda olmadan **tum arayuzlerde** dinliyordu; (b) kullanici eklenmemisse
  kimlik dogrulama **trust** idi (`AuthOk` dogrudan gonderiliyordu), yani ag
  uzerinden gelen herkes tam veritabani erisimi aliyordu; (c) `Start`, o anda
  var olan `VdbResolveListenHost` kuralini ("trust yalniz loopback") **hic
  cagirmiyordu** - kural `VDbNet`'te ve `server_harden` S1-S9'da dogrulanmis
  olmasina ragmen PG sunucusunda etkisizdi. Duzeltme (fail closed):
  varsayilan bind `'127.0.0.1'`; `Start` once `ExposureError` ile **saf
  politika** karari verir (loopback disi adres ancak kimlik dogrulama **ve**
  `RequireTls=True` ile kabul; `AllowInsecureRemote=True` bilincli kacis
  kapisidir), sonra dinleme adresini `VdbResolveListenHost` ile normalize eder
  ve `VdbTcpListen`'e **cozulmus** adresi verir. Boylece motor/soket
  acilmadan reddedilir. Regresyon: S12-S15 (`server_harden` 36/0). Baseline
  (HEAD + yalnizca yeni API kabugu; `ExposureError` bos doner) **6 FAIL**:
  S12 varsayilan bind `0.0.0.0`; S13/S13b/S13d uzak+guvensiz kabul; S13f
  kacis kapisi kapatilamiyor; S14 `Start` uzak adreste politika hatasi yerine
  isletim sistemi bind hatasi veriyor. S15/S15b (yerel trust hala calisir)
  bilerek **ayirt edici degildir**: asiri siki bir duzeltmenin yerel gelistirme
  yolunu kirmadigini korur.
- **F-38 (Kritik, KAPALI, v3.62)**: ozel TCP SQL sunucusu (`VDbSqlServer`,
  `TVdbSqlServer`) PG sunucusundan **bagimsiz** ayni guvensiz varsayilanlari
  tasiyordu ve kimlik dogrulamayi denetimsiz birakiyordu. Dort kusur:
  (a) `Start` dinlemeyi `VdbTcpListen(FPort)` tek argumanli overload'u ile
  aciyordu; bu **`'0.0.0.0'`** demektir, yani sunucu farkinda olmadan tum
  arayuzlerde dinliyor ve parola **acik metin** gidiyordu (protokolde TLS yok);
  (b) `LOGIN` parolayi `pass = FServer.FPass` ile **duz** karsilastiriyordu ve
  deneme sayisinda **sinir yoktu** - 30 saniyede sinirsiz parola denemesi
  mumkundu (PG tarafinda R-4 ceza defteri vardi, burada yoktu); (c) kabul
  edilen sokette **hic zaman asimi kurulmuyordu**, tek bayt gonderip bekleyen
  istemci is parcacigini ve baglanti slotunu surekli tutabiliyordu;
  (d) kapasite karari `FConns.Count`'u **kilitsiz** okuyor ve `GcFinished`'i
  kabul dongusunde kilitsiz cagiriyordu - bitmis baglanti thread'i listede
  kalirsa slot hic geri kazanilmiyordu (olculen: kapanan baglanti sonrasi
  sayim `1`'de kaliyordu). Duzeltme (fail closed): varsayilan bind
  `'127.0.0.1'` + `ExposureError` politika karari (kimlik dogrulama yok ya da
  TLS yok ise loopback disi adres **reddedilir**, `AllowInsecureRemote=True`
  bilincli kacis kapisi) + dinleme adresi `VdbResolveListenHost` ile
  normalize edilir; parola karsilastirmasi **sabit zamanli** (uzunluk ve icerik
  XOR birikimi) ve her iki alan icin yapilir; kullanici bazli + global ceza
  defteri (5 hata / 60 s pencere -> 30 s kilit, 200 global hata) esigi asinca
  **dogru parola da reddedilir**; soket zaman asimi kabulde kurulur ve
  kurulamazsa baglanti **sunulmaz** (test kancasi `SockTimeoutFunc`, uretimde
  nil); baglanti sayimi ve `GcFinished` **kilit altinda**. Bicim v5 degismedi.
  Regresyon: SF9-SF15 (`server_failure` 30/0). Baseline (HEAD + yalnizca
  yeni API kabugu; politika/kilit/zaman asimi yok) **7 FAIL**: SF9 varsayilan
  bind `0.0.0.0`; SF10/SF10b uzak bind politika yerine OS bind'i ile aciliyor;
  SF12b sessiz baglanti istemci zaman asimina kadar (5000 ms) acik kaliyor;
  SF13 zaman asimi kancasi yok sayiliyor; SF14b esik asildiktan sonra dogru
  parola kabul ediliyor; SF15b kapanan baglanti sayimda kaliyor. SF9b/SF11/
  SF14/SF14c/SF15 bilerek **ayirt edici degildir** (asiri siki duzeltmenin
  normal yolu kirmadigini korur).
- **F-39 (Kritik, KAPALI, v3.63)**: dosya degistirme (VACUUM/Compact/Restore/
  Rekey) **surecler arasi kilit tasimiyordu**. `SwapDbFileWith` canli dosyayi
  kapatip `.bak`a tasiyor, yeni dosyayi yerine koyuyordu; kilidi yalnizca
  surec ici `FEngCs` tutuyordu. Baska bir surec eski dosyayi acik tutuyorsa
  Linux'ta **acik fd eski inode'a baglidir**: iki surec FARKLI fiziksel
  dosyalara yazar ve commit "basarili" gorunurken satirlar kaybolur. Bu
  olculdu: eski kodla cocuk surec bir yazma islemi acikken ebeveyn VACUUM
  yapti, islem commit etti, **5 satir kayboldu** (`maint_lock` ML2b baseline:
  `sure_ms=25 hata=` yani bakim basarili). Ikinci kusur: bosta bekleyen
  salt-okunur oturum dosya degistigini fark etmiyor ve **bayat** veri
  okuyordu (ML3c baseline: `COUNT=100`, dogrusu 101). Duzeltme (fail closed):
  (a) `VDbSync.VDbOpenProbeStream` - Windows'ta `FILE_SHARE_DELETE` isteyen
  handle, yani tam kilit tutarken rename'i engellemez (FPC `TFileStream`
  bunu istemez ve acik handle'li dosya Windows'ta yeniden adlandirilamaz);
  (b) `SwapDbFileWith` iki katmanli kilit alir: motor kapanmadan **once**
  `.gen` uzerindeki yazar rezervasyonu (acik yazma islemi varsa bekler),
  motor kapandiktan **sonra** canli dosya uzerinde tam kilit; ikisi de
  `MaintenanceLockMs` (varsayilan 3000 ms) boyunca yoklanir, alinamazsa
  degistirmeye **baslanmaz** ve `bakim kilidi alinamadi ...` hatasi verilir;
  kilitler yeni motor acilmadan birakilir (ayni surecte oz-kilitlenme
  olmasin) ve `except` yolunda her durumda birakilir. SIRA KRITIK: Unix'te
  `Store.Close` `.gen` dosyasini **siler** (v3.32 tek dosya); rezervasyon
  yoklamasi motor kapatildiktan sonra yapilsaydi kontrol sessizce atlanirdi -
  ilk uygulamada tam bu oldu ve Linux'ta bakim 24 ms'de "basarili" oldu.
  (c) `VDbPageStore` artik dosya kimligini (Windows birim seri no + dosya
  indeksi, Unix `st_dev`+`st_ino`) acilista saklar ve her kilit aliminda
  dogrular; dosya degistiyse `veritabani dosyasi degistirildi ...` hatasi
  verir (bayat okuma yerine fail closed). Bicim v5 degismedi, yan dosya
  eklenmedi. Regresyon: ML1-ML5 (`maint_lock` 13/0). Baseline (`git archive
  HEAD` + yalniz `VDbOpenProbeStream` seam'i, cunku kapi bu sembolu
  kullaniyor): **Windows 12 PASS / 1 FAIL** (yalniz ML2b ayirt eder: hata
  `dosya degistirme: mevcut dosya .bak yapilamadi`, 15 ms, "bakim kilidi"
  yok), **Linux 11 PASS / 2 FAIL** (ML2b `sure_ms=25 hata=` - bakim
  basarili oldu; ML3c `COUNT=100` - bayat okuma). ML2c/ML2e baseline'da da
  PASS: kaybolan satirlar yeni dosyada hic gorunmedigi icin sayim ayni
  kalir; bu yuzden kaybi **goren** kontrol ML2b'dir. ML1/ML3a/ML3b/ML4/
  ML4b/ML4c/ML5 bilerek **ayirt edici degildir** (normal yolun kirilmadigini
  korur). Kilit yarisi (iki surec ayni anda) ve Windows'ta oz-kilitlenme
  senaryosu kapida **olculmedi**; ML5 yalniz `.tmp` kalintisina bakmaz.
- **F-40 (Kritik, KAPALI, v3.64)**: PostgreSQL genisletilmis protokolunde
  (`TVdbPgConn.Execute`) **uc** ayri kaynak/bellege kusuru vardi.
  (a) `Execute` govdesindeki `Int32 maxRows` alani **hic okunmuyordu**; her
  `Execute` sonucun **tammini** bastan gonderiyordu, imlec ve
  `PortalSuspended` yoktu (SKILL5 10.1). (b) `Sync` isleyicisi
  `Portals.Clear` cagiriyordu; gercek istemciler (JDBC `fetchSize`, libpq)
  her partiden sonra `Sync` gonderdigi icin ikinci `Execute` her zaman
  `portal yok` aliyordu - yani `maxRows` uygulansa bile **olu kod** olurdu.
  Bu, ilk uygulamada olculdu: kapi 12 FAIL verdi ve hata metni
  `portal yok: po1` idi. (c) `Stmts`/`Portals` sozlukleri ve `TPgPortal.Res`
  **sinirsizdi**: bir istemci `Sync` gondermeden binlerce portal acip her
  birine tam sonuc kumesi koyabiliyor, baglanti basina sinirsiz bellek
  tuketebiliyordu (SKILL5 9.5).
  Duzeltme: `TPgPortal.Sent` imleci eklendi; `Execute` `maxRows` kadar satir
  gonderir (0 = sinirsiz, negatif = 0), kalan varsa `PortalSuspended` (`'s'`),
  tukenince `CommandComplete` yollar; sorgu **yeniden calistirilmaz** ve
  tukenmis portal 0 satir doner (kopya yok). `Sync` artik portallari
  **dusurmez** (portal `Close`, ayni adla yeniden `Bind` veya baglanti sonu
  bitirir); bellek korumasi artik kesin sinirlarla saglanir: `MaxPrepared`
  (512), `MaxStmtSqlBytes` (4 MiB), `MaxPortals` (256) ve
  `MaxPortalResultBytes` (64 MiB), hepsi `0` = sinirsiz. Sinir asiminda
  istemciye kontrollu hata doner ve portal sonucu **derhal birakilir**;
  sunucu sureci OOM ile olmez. Bicim v5 ve V2 degismedi.
  Regresyon: yeni `pg_portal_stream` kapisi (PP0-PP12) **22/0**. Baseline
  (`git archive HEAD` + yalnizca alan/property/varsayilan **seam**'i, yani
  davranis HEAD): **6 PASS / 16 FAIL**, ayirt edici 16 kontrol:
  PP1/PP1b/PP1c/PP2/PP2b/PP2c/PP3/PP3b/PP4 (`maxRows` imleci yok, 25 satir
  tek seferde), PP6a/PP6 (`Sync` portali dusurur), PP10/PP10b (`Describe`
  oncesi `Sync` portali siliyor), PP7 (portal siniri yok), PP8 (prepared
  statement siniri yok), PP9 (sonuc bellek siniri yok - 25 satir gonderildi).
  PP0/PP0b/PP0c/PP5/PP11/PP12 bilerek **ayirt edici degildir** (sunucunun
  acilmasi, `maxRows=0` yolu ve `Close` sonrasi `portal yok` HEAD'de de
  gecer).
  **Durust sinir (Sprint J hali)**: o zaman bu, uctan uca (executor duzeyinde)
  streaming **degildi**; sonuc kumesi bellekte tam olarak uretilir ve imlec
  onun uzerinde ilerlerdi - sinir asilirsa istek **reddedilirdi**. Bu sinir
  **Sprint R'de (SKILL6 04) kapandi**: portal ve `COPY OUT` artik
  `TVdbRowCursor` uzerinden gercek satir akisindan beslenir (F-50). `Sync`'in portallari artik
  dusurmemesi, kapatilmayan portalin baglanti sonuna kadar yasadigi anlamina
  gelir; bu `MaxPortals` + `MaxPortalResultBytes` ile sinirlidir, ancak
  oturum basina bir portal "sizintisina" izin verir.
- **F-41 (Kritik, KAPALI, v3.65)**: `SET TRANSACTION ISOLATION LEVEL
  SERIALIZABLE` yalnizca **adi** degistiriyordu. `VDbExecutor.FIsolation`
  disinda hicbir yerde okunmuyor, commit aninda hicbir dogrulama
  yapilmiyordu; davranis REPEATABLE READ ile **birebir ayniydi** (VDbAst.pas
  bu esitligi yorumda zaten kabul ediyordu). Sonuc klasik **write skew**:
  iki islem ayni snapshot'tan okuyup farkli satirlara yazar, ikisi de commit
  eder. Tek davranissal kullanim `VDbSql.ExecRawCore`'daki READ COMMITTED
  snapshot tazelemesiydi.
  Duzeltme: `IVdbBackend`'e `Serializable` bayragi eklendi (V3 gercek
  denetim yapar, **V2 saklar ama yok sayar** - V2 donmus). `TWriteSet`
  baslarken `StartGen` (surec ici commit sayaci) ve yeni `StartStoreGen`
  (`.gen` sayaci, yani **baska sureclerin** commit'leri de gorulur) alinir.
  `CommitBatch`, `VerifyNoConflict`'dan sonra ve `ApplyBatch`'den **once**,
  `FCommitGen` veya `.gen` degistiyse `ecSerializationFailure` (SQLSTATE
  `40001`) firlatir; yazma uygulanmadigi icin **veri kaybi yok**, kilitler
  ve rezervasyon normal iptal yolundan birakilir. Executor bayragi `BEGIN`
  oncesinde ve `SET ...` aninda tasir (`FKvB = nil` eski `TVTableDb.Create(dir)`
  modunda korunur). Yeni hata kodu `VDbErr`'a, `vdbapi_core`'a
  (`VDB_E_SQL`) ve PG `SQLSTATE` tablosuna eklendi.
  Regresyon: yeni `serializable_tx` kapisi **23/0** (S1-S15 API, P1-P8 PG
  teli). Baseline (`git archive HEAD` + yalnizca enum/`VDbErrorName` seam'i,
  davranis yok) **15 PASS / 8 FAIL**; ayirt edici: S7 (SERIALIZABLE commit
  kabul), S8 (`ecNone`), S9 (40001 yok), S11 (**iptal edilen islem yazmis**),
  P4/P5 (PG'de ErrorResponse ve 40001 yok), P6 (3 satir), P8 (5 satir).
  REPEATABLE READ ayni ara giriste commit etmeye devam eder (S1/S2), yani
  eski davranis bozulmadi.
  **Durust sinir**: bu tam **SSI degildir**; predicate/aralik kilidi yok,
  araya giren herhangi bir commit islemi iptal eder (muhafazakar, false
  positive maliyeti yeniden denemedir). Tek surec ici yazma cakismasi zaten
  eski `yazma cakismasi` hatasiyla yakalaniyordu; 40001 bunun uzerine
  seri kipte ve **surecler arasi** degisikligi kapatir.
- **F-42 (Orta, KAPALI, v3.65)**: `VDbPgWire.ReadCStr` sonlandirici NUL
  yoklugunu **sessizce yutuyordu**: dongu tampon sonunda durup kalan tamponu
  alan degeri olarak donduruyor, `P` tampon disina cikiyordu. Bozuk
  `Parse`/`Bind` paketleri protokol ihlali olarak **reddedilmiyordu**;
  sonlandiricisiz bir prepared statement adi "prepared statement yok" gibi
  **yanlis teshis** uretiyor, baslangic paketinde eksik NUL kabul ediliyordu.
  Duzeltme: `ReadCStr(..., out AOk: Boolean)`; NUL yoksa `AOk := False`.
  Dokuz cagri yerinin hepsi fail-closed: genisletilmis protokolde
  `ExtFail('... eksik NUL sonlandirici')` (ErrorResponse, `Sync`e kadar
  yutulur), `ReadStartup` `Exit(False)`, SCRAM `Exit`.
  Regresyon: yeni `pg_msg_nul` kapisi **10/0** (N0-N8). Baseline
  (`git archive HEAD`, **seam gerekmedi**) **6 PASS / 4 FAIL**; ayirt edici
  N2 (baseline `1Z` = ParseComplete donuyor), N3 (hata metninde 'NUL' yok),
  N5 (baseline yanlis teshis: `prepared statement yok: st5yok`), N7 (eksik
  sonlandiricili baslangic paketi **kabul ediliyor**, `RSSSSKZ`).
  N1/N5b/N6/N8 koruyucu kontrollerdir (duzgun paketler eskisi gibi calisir).
- **F-43 (Orta, KAPALI, v3.65)**: `ExecMerge` eslesmesi kaba kuvvetti -
  her hedef satiri icin **tum** kaynak satirlari dolasilip `ON` kosulu her
  cift icin yeniden degerlendiriliyordu, yani `O(hedef x kaynak)`; kod
  yorumu bunu "indeks/hash yolu YOK" diye zaten kabul ediyordu. Olculen
  (8000 hedef x 8400 kaynak, `ON t.id = s.id`): tek `MERGE` **130781 ms**,
  ayni `MERGE` ikinci kez **142672 ms**. Bu bir DoS/yavaslik kusuru: buyuk
  tablolarda `MERGE` pratikte kullanilamaz ve sunucu is parcacigini
  dakikalarca tutar.
  Duzeltme: `ON` kosulu **yalnizca `AND` zinciri + `sboEq` + iki tarafi da
  kolon referansi** ise hizli yol devreye girer - esitlik anahtarlari
  kanoniklestirilir (sayisal -> `VDbParseFloat`/`VDbFloatToStr`, boolean ->
  'True'/'False', digerleri ham), hedef satirlar **siralanir**, her kaynak
  satiri icin **ikili arama** ile esit aralik bulunur: `O((H+S)logH)`.
  **Her aday satir yine `ON` kosulunun tamami ile dogrulanir**, yani
  semantik degismez; RLS gorunurlugu, `hPks` tabanli coklu eslesme hatasi
  ve `DELETE`in `UPDATE`e ustunlugu aynen korunur. Karmasik `ON` (esitlik
  disi, fonksiyon, `COLLATE`), metin karsilastirmasi (`VCT_STR` ve
  `FCurTable <> ''`) ve cozulemeyen referanslarda **eski dongu aynen**
  calisir (guvenli geri cekilme).
  Regresyon: yeni `merge_hash` kapisi **19/0**; buyuk `MERGE` **62 ms**
  (ikinci kosu 47 ms). Baseline (`git archive HEAD`, **seam gerekmedi**)
  **18 PASS / 1 FAIL**: **yalnizca M2** (10 s siniri) ayirt edicidir
  (130781 ms); M3-M13 semantik **koruyucu** kontrollerdir ve baseline'da da
  gecer - hizi olcmezler, eski davranisin bozulmadigini kanitlarlar. Kanit
  bu nedenle acikca "tek ayirt edici kontrol M2" diye yazilmistir.
- **F-44 (Kritik, KAPALI, v3.66; kod etiketi F-45)**: `SERIALIZABLE`
  secimi **backend genelinde tek bir alanda** (`FSerializable`) tutuluyordu.
  PG sunucusu **tum baglantilari ayni `TVTableDb`'ye** baglar, yani bir
  baglanti `SET TRANSACTION ISOLATION LEVEL SERIALIZABLE` dediginde bu
  bayrak **butun oturumlar** icin aciliyordu. Iki yonlu sonuc olculdu:
  (a) A oturumu READ COMMITTED bir islem acmis ve yazmisken B oturumunun
  SERIALIZABLE secmesi, A'nin `COMMIT`'ini haksiz yere `40001` ile
  iptal ediyor ve **A'nin satiri kayboluyordu** (S17/S18); (b) ters yonde
  B'nin gercek SERIALIZABLE islemi A'nin commit'ini gormuyor, **hic
  reddedilmiyordu** ve write skew'a acik kaliyordu (S19/S20). Ayrica `.gen`
  okunamadiginda uretim `0` kabul edilip "arada commit yok" varsayimi
  yapilabiliyordu (fail-open).
  Duzeltme: bayrak artik **islem bazli**. `IVdbBackend.SetTxIsolation`
  cagrisi `BEGIN`'den hemen once yapilir, backend bunu **oturum kimligine
  gore** (`FPendingSerializable`, `VDbBackendSessionId` = TVSql'in kendi
  kimligi) saklar; `BeginBatch` bayragi **yalniz o oturumun** yeni yazma
  kumesine (`TWriteSet.Serializable`) kopyalar ve siler; `CommitBatch`
  **yalniz kendi kumesine** bakar. `.gen` icin `VDbPageStore.TryReadGen`
  eklendi: okunamazsa `(not ok)` **muhafazakar reddetme** uretir, "degismedi"
  varsayimi degil. Reddedilen commit `ecSerializationFailure` (SQLSTATE
  `40001`) verir ve **hicbir satir uygulanmaz**. V2 bayragi yok sayar
  (`SetTxIsolation` bos govde), V2 davranisi degismedi.
  Regresyon: `serializable_tx` **28/0** (S16-S20 yeni). Baseline
  (`git archive HEAD` = `7b54faa`, **seam gerekmedi**): **24 PASS / 4 FAIL**,
  ayirt edici dort kontrol tam olarak yukaridaki iki kusur: S17 (READ
  COMMITTED commit'i haksiz 40001), S18 (satir kayboldu), S19 (gercek
  SERIALIZABLE reddedilmiyor), S20 (iptal edilen islem satir yazdi).
  **Durust sinir**: bu tam **SSI degil** - predicate/aralik kilitleri ve
  okuma kumesi izleme yok; araya giren **herhangi** bir commit SERIALIZABLE
  islemi iptal eder (muhafazakar, bedeli gereksiz yeniden denemedir, veri
  kaybi degil). Bu nedenle SERIALIZABLE, PostgreSQL'in SSI'sinden **daha
  fazla** iptal uretebilir; bunu "PostgreSQL ile ayni" diye sunmuyoruz.
  Oturum duzeyi `SET SESSION CHARACTERISTICS` hala yok (yalniz `SET
  TRANSACTION` ve BEGIN ani); **ACIK**.
- **F-45 (Kritik, KAPALI, v3.67; kod etiketi F-46)**: kimlik dogrulama ile
  yetkilendirme arasinda **bag yoktu**. (a) SCRAM (`TVdbPgServer.AddUser`)
  yalnizca parolayi dogruluyor, kullaniciyi bir SQL rolune **eslemiyordu**:
  dogrulanmis her uzak kullanici bos rolu uzerinden **motor yoneticisi**
  gibi calisiyordu (SKILL6 02 / SKILL5 3.2). (b) `TVTableDb.RoleCan`
  icinde `if cur = '' then Exit(True)` vardi, yani **bos rol = sinirsiz
  yetki** (fail-open); ayni sekilde `RlsApplies` bos rolde satir duzeyi
  guvenligi **tamamen atliyordu**. (c) `SET ROLE NONE` oturumu bos role
  donduruyordu - yani **yetki yukselmesi** bir SQL cumlesiyle mumkundu.
  (d) `SetCurrentRole` yalnizca rolu **var mi** diye bakiyor, uyeligi
  denetlemiyordu; herhangi bir oturum herhangi bir role gecebiliyordu.
  (e) `TVSql.Create` oturum kimligini `Cardinal(PtrUInt(Self))` ile
  **32 bite kirpiyordu** (cakisma riski) ve `TVSql.Destroy` oturumun rol
  kaydini **silmiyordu**: ayni kimligi alan yeni bir baglanti onceki
  oturumun rolunu **miras alabiliyordu**.
  Duzeltme: principal / taban rol / gecerli rol ayrimi eklendi
  (`FUserBySession`, `FBaseRoleBySession`, `BindSessionPrincipal`,
  `ReleaseSessionState`, `SessionUser`, `SessionBaseRole`). PG sunucusu
  dogrulama sonrasi kullaniciyi `AddUser(..., ASqlRole)` ile verilen role
  **baglar** (`--user K:P:ROL`); esleme yoksa baglanti **fail-closed**
  reddedilir (SQLSTATE `28000`) ve yalnizca acik `AllowUnmappedUsers` /
  `--allow-unmapped-users` bayragi eski davranisi geri verir. Principal
  oturumlarinda bos rol artik **yetki vermez** (`RoleCan` False), RLS
  **uygulanir**, `SET ROLE NONE` **taban role** doner ve uye olunmayan
  role gecis `ecPermissionDenied` ile reddedilir (yalniz Super taban rol
  serbesttir). Oturum kimligi `InterlockedIncrement` tabanli sayac oldu ve
  `Destroy` tum oturum durumunu siler.
  Regresyon: `sql_authorization` **62/0** (51 -> 62; AU12 yeni). On-kapi
  (`git archive HEAD` = `7b54faa`, yalniz API **seam**'i: `BindSessionPrincipal`
  / `SessionId` no-op olarak eklenir, davranis HEAD): **56 PASS / 6 FAIL**;
  ayirt edici alti kontrol AU12: rolsuz principal SELECT/INSERT edebiliyor,
  app rollu principal INSERT yetkisizligi **denetlenmiyor** (PK cakismasina
  kadar geliyor), `SET ROLE NONE` sonrasi yetki yukselmesi, uye olunmayan
  role gecis kabul.
  **Durust sinir**: kullanici/rol **katalogu veritabaninda saklanmaz**;
  esleme sunucu yapilandirmasindan gelir. Rol uyeligi **duzdur** (rol
  devralma/zincirleme, `GRANT role TO role` yok); `SET ROLE` yalniz taban
  rolu veya Super taban rolde herhangi bir rolu secer. `AllowUnmappedUsers`
  bilincli bir **yetki feragatidir** ve varsayilan **kapalidir**. V2
  degismedi.
- **F-46 (Yuksek, KAPALI, v3.68; kod etiketi F-47)**: atomik dosya
  degistirme (`TVdbBackendV3.SwapDbFileWith`, yani VACUUM/Compact/Restore/
  Rekey) **dizin girdisini hic fsync etmiyordu**. Sequence eski canli dosyayi
  `.bak`a rename ediyor, yeni dosyayi yerine koyuyor, eski WAL/`.idx`i
  siliyor ve `.gen` durabil LSN'ini sifirliyordu; ancak bu rename/silme
  islemlerinden sonra **dizin fsync'i yoktu** (`VDbFlushDir` repoda vardi ve
  `VDbPageStore`/`VDbChangeLog`/`VDbCore` kullaniyordu - `VDbBackendV3`
  kullanmiyordu). Guclu kapanma/cokme sonrasi dizin girdisi diske inmeyebilir:
  ne canli dosya ne `.bak` yerinde bulunabilir, ya da **silinen eski WAL geri
  gelip yeni dosyaya uygulanabilir** (sessiz bozulma). SKILL6 06.
  Duzeltme: her kritik adimdan sonra dizin fsync'i - eski dosya `.bak`
  yapildiktan sonra, yeni dosya yerine konduktan sonra (kaynak dizin farkli
  ise orasi da), eski WAL/`.idx` silindikten sonra ve `.gen` LSN
  sifirlandiktan/silindikten sonra. `VDbFlushDir` **False** donerse islem
  sessizce "basarili" sayilmaz: `SwapDbFileWith` hata verir ve `.bak`tan
  geri doner; geri donus rename'inin kendisi de fsync edilir ve o da
  basarisizsa **acik hata** ile bildirilir (veri kaybi riski gizlenmez).
  Windows'ta NTFS gunlugu nedeniyle fsync gerekmez (`VDbFlushDir` True
  doner); bu bir **desteklenmiyor** durumu degil, platform davranisidir.
  Regresyon: `maint_lock` **19/0** (13 -> 19; ML6-ML7 yeni). On-kapi
  (`git archive HEAD` = `8af4161`, yalniz API **seam**'i: `VDbFlushDirHook` /
  `VdbFlushDirForceFail` bildirilir, `VDbFlushDir` onlari yok sayar; davranis
  HEAD): **16 PASS / 3 FAIL**; ayirt edici uc kontrol: ML6a (fsync **0 kez**
  cagrildi), ML6b (bos dizin listesi), ML7a (fsync zorla basarisiz kilindiginda
  bile VACUUM "basarili"). ML7b/ML7c koruyucudur (on-kapida da gecer).
  **Durust sinir**: kapi, fsync'in **cagrildigini** ve basarisizlik yolunun
  fail-closed oldugunu olcer; gercek **guc kesintisi** senaryosu bu ortamda
  uretilemez, dolayisiyla "cokme sonrasi kesin kalici" iddiasi yalniz dizin
  fsync garantisine dayanir (POSIX). `tests/crash_points` surec oldurme ile
  calisir ve fsync kaybini **taklit etmez**; bu yuzden ayri bir fsync
  kancasi kullanildi. V2 ve bicim v5 degismedi.
- **F-47 (Yuksek, KAPALI, v3.69; kod etiketi F-48)**: iki ayri ag kusuru.
  (1) **Zaman asimi her cagri icin ayriydi**: `VdbRecvAll` (`VDbNet.pas`)
  ve `TVdbPgIo.RecvAll` (`VDbPgWire.pas`) dongu icinde `fpRecv` cagiriyor,
  sinir yalniz `SO_RCVTIMEO`/`SO_SNDTIMEO` (varsayilan 30 s) ile her tek
  cagriya uygulaniyordu. Istemci her 29 saniyede bir bayt gonderirse
  **toplam** mesaj/startup/COPY suresi sinirsiz uzuyordu (Slowloris/damla);
  baglanti slotu ve is parcacigi surekli tutuluyordu. (2) **CancelRequest
  (kod `80877102`) hic islenmiyordu** (`ReadStartup` yalniz 80877103/80877104/
  196608 taniyordu) ve her baglantiya **ayni** `BackendKeyMsg(1, 0)`
  gonderiliyordu; yani istemcinin elinde kendi baglantisina ozel bir
  (pid, secret) cifti yoktu ve iptal protokolu kullanilamazdi. SKILL6 05.
  Duzeltme: `VdbRecvAllDl`/`VdbSendAllDl` (`VDbNet.pas`) monotonik
  `GetTickCount64` tabanli **mutlak** son tarih (`ASonTick = 0` -> eski
  davranis); `select()` ile bekleme 1000 ms'lik dilimlere bolunur (kapanis
  en gec 1 s'de gorulur). `TVdbPgIo.SetDeadlineMs` her **mesajin** basinda
  tazelenir (baslik + govde ayni son tarihe tabi), startup/TLS/SCRAM tek
  son tarih altinda, COPY-In her `d` parcasinda tazelenir; yazma tarafinda
  `SetSendBudgetMs` her `SendAll` cagrisinda butceyi yeniler (uzun sonuc
  kumelerinde bayat son tarih olmaz). Her baglantiya **benzersiz**
  `BackendKeyData` verilir (`FNextBackendPid` = InterlockedIncrement(1000),
  secret = kilit altinda xorshift32); `ReadStartup` `80877102`i ayristirir
  (len 16, pid, secret), yanit vermez ve baglantiyi kapatir;
  `TVdbPgServer.HandleCancel` `FConns`i kilit altinda tarar, **yalniz**
  pid **ve** secret eslesen baglantinin `TVSql.CancelQuery`'sini cagirir;
  bilinmeyen pid/yanlis secret **hicbir** baglantiyi iptal etmez. Iptal
  edilen sorgu `57014` (query_canceled) SQLSTATE'i ile doner
  (`PgSqlStateOf`: `ecCancelled`, `ecQueryTimeout`).
  Regresyon: `network_limits` **41/0** (26 -> 41; NL9-NL12 yeni) ve yeni
  kapi `pg_cancel` **31/0** (PC0-PC9). On-kapi (`git archive HEAD` =
  `4203135`, yalniz API **seam**'i: `VdbRecvAllDl`/`VdbSendAllDl`
  bildirilir ve son tarihi **yok sayarak** eski fonksiyonlara delege eder;
  test dosyalari HEAD'den degil calisma agacindan alinir): `network_limits`
  **32 PASS / 9 FAIL**, ayirt edici kontroller NL9 (damla 4156 ms'de hala
  acik), NL10 (2188 ms), NL11 (COPY-In 4171 ms), NL12 (bitmis butceye ragmen
  yazma kabul edildi: `ok=True`, 1 bayt gitti); `pg_cancel` **3 PASS / 4 FAIL**
  (on-kapida `BackendKeyData` secret'i 0 oldugu icin baglanti dogrulamasi
  `BackendKeyData yok` ile erken kesilir - yani iptal anahtari hic yok).
  **Durust sinir**: (a) Windows'ta loopback uzerinde **engellenen yazma**
  deterministik uretilemiyor (RCVBUF=4096 iken 16 MiB 16 ms'de kabul edildi),
  bu yuzden NL12 engellenme anini degil **son tarihin kendisini** olcer
  (bitmis butcede hic bayt yazilmaz, dolan son tarihte dongu durur, bol
  butcede yuk tamamen gider); tek bir `fpSend` kendi OS tavanini
  (`SO_SNDTIMEO`) asabilecegi icin ust sinir 2 s'dir. (b) TLS uzerinde
  `select()` kullanilamaz; TLS okumasinda son tarih **her parca oncesi**
  denetlenir, tek `SSL_read`in ust siniri yine `SO_RCVTIMEO`'dur. (c) Iptal
  **isbirlikci** noktalarda (satir dongusu/TickAbort) etkilidir; bloklayan
  tek bir disk G/C'sini kesmez. V2 ve bicim v5 degismedi.

- **F-48 (Orta/Yuksek, KAPALI, v3.70; kod etiketi Sprint P)**: `UPDATE ...
  FROM` esitlik birlestirmesi **kaba kuvvetti**. `ExecUpdate`
  (`VDbExecutor.pas`) hedef satirlari kaynak satirlariyla **kartezyen**
  dolasiyordu (`for i ... for fi ... RowMatches`), ilk eslesende duruyordu;
  4000 hedef x 2500 kaynak satirinda ~6.9 milyon tam WHERE degerlendirmesi
  yapiliyordu (**olculen 13063 ms**). SKILL6 07. Duzeltme: WHERE'in ust
  duzey `AND` dallarindan **yalniz guvenli** esitlikler cikarilir
  (`sboEq` + iki tarafi da kolon referansi; `BinaryOpCtype = VCT_STR` ve iki
  tarafta collation bos - sayisal denklik `'01' = '1'`, `VCT_BOOL`,
  dil-duyarli collation **anahtar sayilmaz**), anahtar uzunluk-onekli
  parcalardan kurulur (FNV-1a hash), kaynak tarafi hash tablosuna **azalan
  sirada basa eklenir** ki kova artan `fi` sirasinda gezilsin ve "ilk eslesen
  kaynak satiri kazanir" semantigi korunsun; NULL (bos) anahtar hicbir
  esitlikte eslesmedigi icin atlanir; her adayda **tam WHERE** yeniden
  degerlendirilir (hash yalniz on filtre). Uygun conjunct yoksa eski
  kartezyen yol **aynen** calisir (esitlik-disi WHERE, sayisal/collation
  durumlari icin guvenlik agi). Regresyon: `merge_hash` **30/0**
  (19 -> 30; U1-U9). On-kapi (`git archive HEAD` = `ab103aa`, test dosyasi
  calisma agacindan): **29 PASS / 1 FAIL**, tek ayirt edici **U3** =
  `sure=13063ms sinir=4000ms`; yeni kodda **16 ms**. Ayni yuk altinda
  ~815x hizlanma. U1/U2/U4-U9 on-kapida da gecer (eski yol **dogru** idi,
  yalniz yavasti) - bu yuzden ayirt edici olan tek kontrol sure siniridir,
  sonuc dogrulugu kontrolleri regresyon korumasidir. **Durust sinir**: bu
  degisiklik bir **maliyet modeli degil**, tek bir guvenli durumda hash
  yoludur; cardinality/distinct/NULL orani/hash bellek tahmini ve
  spill-to-disk karari hala yok, `UPDATE ... FROM` icinde tek tablo/alt
  sorgu kaynagi disinda (JOIN) parser zaten hata veriyor. V2 ve bicim v5
  degismedi.
- **F-49 (Orta/Yuksek, TAMAM, v3.72; kod etiketi Sprint Q)**: **SQL NULL ile
  bos metin ayni degerdi**. Belirtiler olculdu: `SELECT '' IS NULL` **TRUE**
  donuyordu, `SELECT '' = ''` **UNKNOWN** cikiyordu, `COUNT(kolon)` NULL
  satirlari bos metin sandigi icin yanlis sayiyordu. SKILL6 03. Kok neden iki
  katmanliydi: (a) `EvalExpr` `sltNull` literalini `''` olarak donduruyordu,
  yani ifade duzeyinde NULL diye bir sey yoktu; (b) `DecodeRow` diskte
  `lenCode = 0` (NULL) ile `lenCode = 1` + 0 bayt (bos metin) ayrimini
  **okurken atiyor**, `EncodeRow` de `''` yazarken NULL uretiyordu - yani
  bugun diskte bos metin **hic** yazilamiyordu. Dort asama bunu kapatti:
  **asama 1** depolama maskesi (`TNulArr`/`TNullMatrix`, `EncodeRowEx`,
  `DecodeRowEx`, `ScanRowsEx`/`ScanRowsPartEx`); maske verilince `''` gercek
  bos metin (`lenCode = 1`) yazilir, NULL `lenCode = 0` kalir; maske `nil`
  iken baytlar **bit bazi ayni** (`format_compat` 28/0, bicim v5 degismedi).
  **Asama 2a** ifade semantigi: `FCurNulls` + out-of-band `FLastNull`,
  `sltNull` NULL, NULL operandli aritmetik/karsilastirma UNKNOWN,
  `IS NULL`/`IS NOT NULL` bayraga bakar, AND/OR uc degerli, kolon referansi
  maskeden okur; ayrimi `EvalBinary`'nin `LNull`/`RNull`/`NullFlagsValid`
  bayraklari ve `VDbCmpValEx(..., EmptyIsValue)` tasir. **Asama 2b** okuma
  maskesi uctan uca: `ReadRowEx`/`ScanRowsEx` -> filtre/RLS/join ->
  projeksiyon (`FNarrowNulls`/`FAggNulls`) -> `TSqlResult.RowNulls`; yani
  `COUNT(kolon)`, UNIQUE, GROUP BY/DISTINCT, `ORDER BY NULLS FIRST/LAST`
  ve PG wire `-1` depolanmis degeri maskeden okur. **Asama 2c** yazma
  maskesi: `TTableDef.HasNulls` (sema satiri `#N|<tablo>`) NULL tasiyan
  tabloyu indeks/covered-index/stream/COPY hizli yollarindan genel satir
  yoluna yonlendirir; `InsertEx`, `InsertReturning`, `UpdateRowInPlace`,
  `PutRow`, `UpdateWhere`, `UpsertRowReturning`, FK cascade ve
  `RewriteTable`/`RewriteTableRows` maskeyi tasir; parametre maskesi
  `ParseEx` + `TVSql.Exec(Sql, Params, ParamNulls)` ile SQL katmanindan
  gecer. Kapi: **`tests/null_empty` 41 kontrol (NE1-NE51) 41 PASS / 0
  FAIL**; on-kapi `git archive HEAD` (`a30676e`) uzerinde **30 PASS / 11
  FAIL** - yani kapi ayirt edici. Bu is iki gercek kusur daha buldu ve
  kapatti: (i) hizli INSERT seritleri maske tasimadigi icin NULL literalini
  `''` yazip `HasNulls`i hic isaretlemiyordu (sonrasinda her `''` NULL
  olarak saklaniyordu = veri kaybi); serit artik NULL'da genel yola birakir
  (`VDbNullsAny`). (ii) `ALTER TABLE ADD COLUMN` `RewriteTable` icinde
  `oldNulls`u boyutlandirmiyordu (`EAccessViolation`; `sql_matrix` D6);
  `SetLength(oldNulls, ...)` eklendi. **Durust sinir**: `COPY TO`
  text/Arrow/Parquet NULL'i hala `''` yazar; covered-index hizli yolu ve
  projeksiyon oncesi `ORDER BY` siralamasi maskeyi tasimaz;
  `ExecGroupBy` `Res.RowNulls`i doldurmaz; 2c oncesi yazilmis satirlar
  `HasNulls` isaretlenene kadar eski kurala tabidir. Bunlar gosterim/okuma
  kapsami olup veri kaybi degildir. V2 ve bicim v5 degismedi.

- **F-50 (Orta, TAMAM, v3.72; kod etiketi Sprint R)**: **PG portal ve COPY OUT
  gercek satir akisi**. Onceden portal `Execute` sonucu **tamamen**
  maddeselestirip yalniz `maxRows` kadarini dilimliyor, `COPY OUT` da tam
  sonucu bellekte kuruyordu; yani `maxRows` bir bellek siniri degildi.
  Artik `TVdbRowCursor` (`VDbExecutor.pas`) **sayfa pencereli parca**
  uretir: `TryStreamSelectChunk(Stmt, td, Cursor, AResumePage, ASkipQual,
  AMaxRows, out Res)`. `TryStreamSelect` eski imzasi `Cursor = nil` ile
  delege eder; `ExecSelect` tek bir `TryStreamProbe` cagrisi yapar, boylece
  ayni sorgu icin **tek tarama** garantidir. Ilk parcadan sonra imlec
  `FResumePage`/`FSkipQual` ile ayni sayfadan devam eder: onceki sayfalar
  `zSkip[]` ile atlanir, devam sayfasinda ilk `FSkipQual` ham geri cagri
  sayacla gecirilir (sayfa icinde geri cagri sirasi deterministiktir).
  `ctx.Offset := 0; ctx.Limit := -1` kurulur; OFFSET/LIMIT'i imlec
  parcalar arasinda uygular. Portal parcasi `VDB_PORTAL_CHUNK = 256`
  satirdir ve geri basinc bloklayan soket gonderiminden gelir.
  `MaxPortalResultBytes` her uretilen parcada ve imlecin canli baytinda
  denetlenir; asilirsa istek kontrollu RED alir ve imlec birakilir.
  `Describe` imleci acar ama yalniz ilk parcayi ceker; `COPY OUT` (sorgu
  ve tablo bicimi) imlecten akar (`try/finally` ile imlec her durumda
  serbest birakilir). Devam ettirilemeyen imlec **sessizce kesilmez**,
  `ecUnsupported` ile "akisli imlec devam ettirilemedi (depo durumu
  degisti)" verir. **Yan bulgu ve duzeltme**: `CreateTable` yerel
  `TTableDef` kaydinda `HasNulls` acikca sifirlanmiyordu; FPC yalniz
  managed alanlari sifirladigi icin yeni tablolar rastgele "NULL tasiyor"
  sayiliyor ve **tum** akis hizli yollari kapaniyordu (`t.HasNulls :=
  False` eklendi). **Durust sinir**: ORDER BY, GROUP BY, DISTINCT, JOIN,
  UNION, pencere islevi, alt sorgu, NULL tasiyan tablo (`HasNulls`), KV
  deposu ve toplu acilis (`BatchOpen`) tek seferlik genel yola duser; bu
  sekillerde butce maddeselestirme **sonrasi** denetlenir. Imlec modu bolge
  haritasi (zone map) **yayinlamaz** (`ctx.ZoneOn := False`), cunku devam
  eden parca geri cagri atladigi icin min/max daralirdi; var olan gecerli
  haritanin `zSkip` budamasi yine kullanilir. Kapi:
  **`tests/pg_portal_stream` 35 kontrol (PP0-PP12, PS0-PS10) 35 PASS / 0
  FAIL**; on-kapi (ayni 35 kontrol, `git archive HEAD`, `e31d186`) **33
  PASS / 2 FAIL**. Ayirt edici iki kontrol: **PS7a** (maddeselestirilen 800
  satir 245043 bayt > 120000 butce -> RED) ve **PS4** (`maxRows=1` ile 25
  adimda 25 tekil satir beklenirken 24 gelir). Diger 33 kontrol
  koruyucudur (HEAD'de de gecer). V2 ve bicim v5 degismedi.

- **F-51 (ORTA, TAMAM, v3.73; kod etiketi SKILL6 08)**: **Arrow okuyucu
  `date64[ms]` ve `time32[ms]` degerlerini 1000 kat kaydiriyordu.** Arrow
  duz (flatbuffer) semasinda `Date.unit` ve `Time.unit` alanlarinin
  varsayilani **MILLISECOND (1)**, `Time.bitWidth` varsayilani 32'dir. Bir
  flatbuffer yazici varsayilana **esit** alani yazmadigi icin pyarrow
  `date64[ms]`/`time32[ms]` icin `unit` alanini **hic yazmaz** (Time/Date
  tablosu bos: 4 baytlik tablo + `04 00 04 00` vtable), `time32[s]` ve
  `date32[day]` icin ise **acik** `unit=0` yazar. `VDbArrow.pas`
  `ArrowParseType` varsayilani `0` (SECOND / DAY) aliyordu: `time32[ms]`
  degeri 43.200.000 ms, 43.200.000 **saniye** gibi okunuyor (`00:00:00`,
  satir basina +1000 s) ve `date64[ms]` epoch-ms degeri **gun** sayiliyordu
  (`0000-00-00` / `1971-02-17`). `Timestamp.unit` alaninin semada varsayilani
  **yoktur**, o yuzden her zaman yazilir ve timestamp kolu hep dogruydu;
  Parquet yolu etkilenmiyordu. Kanit: bayt tarayicisi `t32ms.arrow` icin
  `table@92 vt=88 len=4 tlen=4 ents=[]` (bos), `t32s.arrow` icin
  `ents=[6] f0@102=0` (acik SECOND); enstrumante birim kopyasi
  `DBGP typeTable=100 f0=0 f1=0` yazdi, yani `FbField` bos tabloda 0 donup
  varsayilan kullanildi. **Duzeltme**: `ArrowParseType` icinde `8: // Date`
  ve `9: // Time` dallari `AF.TimeUnit := FbInt16(B, FbField(B, TypeTable,
  0), 1)` kullanir; `10: // Timestamp` varsayilanda kalir. **VDB'nin kendi
  yazdigi dosyalar etkilenmez**: `TFbNode.AddScalar` slotu kosulsuz ekler ve
  `MakeTypeTable` DATE/TIME icin `unit=0` alanini acikca yazar, yani
  gidis-donus hala SECOND/DAY'dir. Kapi: `tests/interop_external` **8/0**
  (X1-X8; X8 bes birimi tek tek sinar); on-kapi (`git archive HEAD` =
  `16b0b09`, HEAD `VDbArrow.pas` birim yolunda one alinarak) **6 PASS /
  2 FAIL** - **ayirt edici X4** (`at 0=00:00:00`) ve **X8** (`alan 0 satir
  0=0000-00-00 beklenen=2026-03-01`), diger alti kontrol koruyucudur.
  `interop_format` 21/0 ve `format_compat` 28/0 degismedi (bicim v5 bit
  bazi ayni).


---

## J. Final classification

**BETA CANDIDATE**

Gerekce:

1. Kritik depolama/WAL/islem hatalari kapatildi ve her biri kalici bir
   regresyon kapisiyla kilitlendi; iki platformda **60/60** kapi yesil, FAIL 0.
2. Tek dosya sozlesmesi, kurtarma, sayfa butunlugu, sunucu hata yollari,
   bozuk ag girdisi, disk dolu, bellek tukenmesi, WAL sert tavani, B+Tree
   olcek/parcalanma, SQL 100k/1M olcegi, SQL indeks olcegi ve VACUUM geri
   kazanimi **olculdu**.
3. Olcum kapilari dort gercek kusur sinifi buldu ve kapatti: F17 (Unix fd
   sizintisi), F18 (sahte basarili VACUUM/dosya degistirme), F21 (sessiz dizin
   doygunlugu), F22 (serbest sayfanin sifirlanmasi = veri kaybi); ek olarak
   Sprint D'de cift/trunk/canli sayfa serbest birakma (freelist) ve disk
   B+Tree'de bozuk sayfanin sessizce geri kazanilmasi, Sprint F1'de CAST
   sessiz sarmasi, `ABS` hassasiyet kaybi, `Low(Int64)` isaret sarmasi ve
   ozyinelemeli CTE'nin sessiz kesilmesi, Sprint E'de zaman asimsiz
   baglantiyla **kalici DoS** (`MaxConns=1`), asiri cercevenin sessiz
   dusurulmesi, sinirsiz COPY gecici dosyasi ve kilitsiz kapasite okumasi.

**PRODUCTION CANDIDATE degildir** cunku:

- Canli PostgreSQL diferansiyeli **kosmadi** (`pg=not-run`);
- uzun sureli soak (1h/6h/24h) ve **ag sunucusu soak'i** kosmadi;
- disk tabanli ikincil indeks **yok** (tasarim var, uygulama yok);
- uctan uca streaming yalniz PG portal ve COPY OUT icin var; gomulu
  `Exec`, disk spill ve JOIN bellek butcesi **yok** (Sprint F2);
- macOS/ARM64 **not-run**;
- TLS varsayilan kapali ve mTLS/CRL/OCSP yok.

**PRODUCTION READY degildir** ve bu rapor boyle bir iddia kurmaz. Bagimsiz
denetim, gercek saha kullanimi ve uygunluk degerlendirmesi olmadan
**CERTIFIED / FIPS / SIL / formal compliance** iddiasi **olusturulmaz**.
