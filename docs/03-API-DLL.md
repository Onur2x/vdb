# 03 — API / DLL Katmanı / API / DLL Layer

> **TR:** Bu belge, VDB veritabanı motorunun C/Delphi/FPC için DLL API'sini açıklar. 57 export fonksiyon, hata kodları, kullanım örnekleri ve R-12 TCP SQL protokolü.
>
> **EN:** This document describes the VDB database engine's DLL API for C/Delphi/FPC. 57 exported functions, error codes, usage examples, and R-12 TCP SQL protocol.

> **Tazeleme / Updated: 14.10.2026 (R-12 Full)** — TCP SQL protokolü eklendi.
> **Tazeleme / Updated: 13.10.2026 (R-14 Full)** — Paralel işçi havuzu export'u eklendi (`VdbParallelInit/Workers/Shutdown`), ABI **1.1 → 1.2**, toplam **57 export**.
> **Tazeleme / Updated: 06.10.2026** — Otomatik-WAL (3), şifreleme (9), CDC/Time Travel (7) exportları eklendi.

---

## 1. Neden DLL? / Why DLL?

### TR
- Farklı dillerden (C, C++, Delphi, Python, C#) erişim
- Dil bağımsız ABI (Application Binary Interface)
- Tek kütüphane, çoklu platform (Windows `.dll`, Linux `.so`, macOS `.dylib`)

### EN
- Access from different languages (C, C++, Delphi, Python, C#)
- Language-independent ABI
- Single library, multi-platform (Windows `.dll`, Linux `.so`, macOS `.dylib`)

---

## 2. Katmanlar / Layers

### TR
```
vdbapi.lpr (ince sarmalayıcı / thin wrapper)
  ↓
vdbapi_core.pas (gerçek mantık / real logic, 57 export fonksiyon)
  ↓
VDbCore.pas + VDbTable.pas + VDbSql.pas (çekirdek motor / core engine)
  ↓
.odb dosyası / file
```

### EN
Same architecture as above.

---

## 3. Tasarım Kuralları / Design Rules (Değiştirilmemeli / DO NOT MODIFY)

### TR
1. **ABI kararlılığı:** Export isimleri ve imzalar değişmez
2. **UTF-8:** Tüm metinler UTF-8 kodlamasında
3. **Hata kodları:** Negatif değerler hata, pozitif/sıfır başarı
4. **İki aşamalı okuma:** `VdbGet` önce boyut, sonra veri okur
5. **Thread-safe:** Her handle kendi kilit mekanizmasına sahip

### EN
1. **ABI stability:** Export names and signatures never change
2. **UTF-8:** All text in UTF-8 encoding
3. **Error codes:** Negative values = error, positive/zero = success
4. **Two-phase read:** `VdbGet` first gets size, then reads data
5. **Thread-safe:** Each handle has its own locking mechanism

---

## 4. Hata Kodları / Error Codes

### TR
| Kod | Sabit | Açıklama |
|---|---|---|
| `0` | `VDB_OK` | Başarı / Success |
| `-1` | `VDB_E_GENERIC` | Genel hata / Generic error |
| `-2` | `VDB_E_IO` | Dosya G/Ç hatası / File I/O error |
| `-3` | `VDB_E_CORRUPT` | Dosya bozuk / File corrupted |
| `-4` | `VDB_E_SQL` | SQL hatası (`VdbLastError` ayrıntı) / SQL error |
| `-5` | `VDB_E_NOTFOUND` | Kayıt bulunamadı / Record not found |
| `-6` | `VDB_E_INVALID` | Geçersiz parametre / Invalid parameter |
| `-7` | `VDB_E_LOCKED` | Kilitli / Locked |
| `-8` | `VDB_E_ENCRYPT` | Şifreleme hatası / Encryption error |
| `-9` | `VDB_E_AUTH` | Yetkilendirme hatası / Authorization error |

### EN
Same codes as above.

---

## 5. Fonksiyon Listesi (57 Export) / Function List (57 Exports)

### TR: Gruplar

**Sürüm/Hata / Version/Error:**
- `VdbApiVersion` — API sürümü (ABI 1.2)
- `VdbVersion` — Motor sürümü
- `VdbLastError` — Son hata mesajı
- `VdbLastErrorCodeGet` — Son hata kodu
- `VdbSetLastErrorCode` — Hata kodu ayarla

**Aç/Kapa / Open/Close:**
- `VdbOpen(APath, ASyncWrite) -> handle` — Veritabanı aç
- `VdbClose(handle)` — Veritabanı kapat
- `VdbCloseAll` — Tümünü kapat

**KV (Key-Value):**
- `VdbCount(handle)` — Kayıt sayısı
- `VdbPut(handle, key, val)` — Kayıt ekle/güncelle
- `VdbGet(handle, key, buf, len)` — Kayıt oku (iki aşamalı)
- `VdbExists(handle, key)` — Kayıt var mı?
- `VdbDelete(handle, key)` — Kayıt sil
- `VdbKeys(handle, buf, len)` — Anahtarları listele
- `VdbFlush(handle)` — Diske yaz

**SQL/Sonuç / SQL/Result:**
- `VdbExec(handle, sql) -> resultHandle` — SQL çalıştır
- `VdbResultFieldCount(result)` — Kolon sayısı
- `VdbResultRowCount(result)` — Satır sayısı
- `VdbResultFieldName(result, col, buf, len)` — Kolon adı
- `VdbResultValue(result, row, col, buf, len)` — Hücre değeri
- `VdbResultAffected(result)` — Etkilenen satır
- `VdbResultStmts(result)` — Çalıştırılan cümle sayısı
- `VdbResultMessage(result, buf, len)` — Sonuç mesajı
- `VdbResultLastTable(result, buf, len)` — Son tablo
- `VdbResultFree(result)` — Sonucu serbest bırak

**Bakım/WAL / Maintenance/WAL:**
- `VdbVerify(handle)` — Dosya bütünlüğü doğrula
- `VdbWalHas(handle)` — WAL var mı?
- `VdbWalRecordCount(handle)` — WAL kayıt sayısı
- `VdbWalWrite(handle, ...)` — WAL'a yaz
- `VdbWalWriteDelete(handle, ...)` — WAL'a silme yaz
- `VdbWalReplay(handle)` — WAL'i tekrar oynat
- `VdbWalCheckpoint(handle)` — WAL checkpoint
- `VdbFileSize(handle)` — Dosya boyutu
- `VdbDeadBytes(handle)` — Ölü bayt
- `VdbAutoCompact(handle)` — Otomatik sıkıştır

**Otomatik WAL / Auto WAL (2026-10-04):**
- `VdbWalSetAuto(handle, 0|1)` — Otomatik WAL aç/kapa
- `VdbWalIsAuto(handle)` — Otomatik WAL açık mı?
- `VdbWalAutoCount(handle)` — Otomatik WAL sayacı

**Şifreleme / Encryption (2026-10-05):**
- `VdbEncryptEnable(handle, key, len)` — Şifrelemeyi aç
- `VdbEncryptDisable(handle)` — Şifrelemeyi kapat
- `VdbEncryptIsEncrypted(handle)` — Şifreli mi?
- `VdbEncryptCreateKeyFile(handle, path, pass)` — `.key` dosyası oluştur
- `VdbEncryptOpenKeyFile(handle, path)` — `.key` dosyası aç
- `VdbEncryptKeyPath(handle, buf, len)` — Anahtar dosya yolu
- `VdbEncryptFingerprint(handle, buf, len)` — Şifreleme parmak izi
- `VdbHasEncryptedRecords(handle)` — Şifreli kayıt var mı?
- `VdbRekeyWithPassword(handle, oldPass, newPass)` — Parola değiştir

**CDC / Time Travel (2026-10-06):**
- `VdbCdcStart(handle)` — CDC başlat
- `VdbCdcStop(handle)` — CDC durdur
- `VdbCdcPollSize(handle)` — Olay boyutu
- `VdbCdcPoll(handle, buf, len)` — Olay oku ve tüket
- `VdbCdcStats(handle, ev, skip, pend, drop)` — İstatistikler
- `VdbValueAt(handle, tbl, pk, seq, buf, len)` — Time Travel (geçmiş değer)
- `VdbHistoryCount(handle)` — Geçmiş sayısı

**Paralel İşçi Havuzu / Parallel Worker Pool (2026-10-13, R-14):**
- `VdbParallelInit(n) -> worker sayısı` — Havuzu başlat (0 = otomatik)
- `VdbParallelWorkers() -> worker sayısı` — Aktif worker
- `VdbParallelShutdown() -> kapatılan worker` — Havuzu kapat

**TCP SQL Protokolü / TCP SQL Protocol (2026-10-14, R-12):**
- *(Bu fonksiyonlar `VDbClientNet.pas` üzerinden Pascal API olarak kullanılır; DLL export'u yoktur, TCP protokolü doğrudan soket üzerinden çalışır.)*

### EN: Groups
Same function groups as above.

---

## 6. TCP SQL Protokolü (R-12) / TCP SQL Protocol (R-12)

### TR: Protokol Sabitleri (`VDbNet.pas`)
```pascal
const
  VDBS_MAGIC = 'VDBS';        // El sıkışma / Handshake
  VDBS_PROTO_VER = 1;         // Protokol sürümü / Protocol version
  VDBS_TERM = $00;            // Terminasyon baytı / Termination byte

  // Komutlar / Commands
  VDBS_CMD_QUERY   = $10;     // SQL sorgusu / SQL query
  VDBS_CMD_PING    = $11;     // Ping
  VDBS_CMD_BYE     = $1F;     // Bağlantıyı kapat / Close connection
  VDBS_CMD_LOGIN   = $20;     // Oturum aç / Login (str user, str pass)
  VDBS_CMD_LOGOUT  = $21;     // Oturum kapat / Logout
  VDBS_CMD_PREPARE = $22;     // Hazırla / Prepare (str sql)
  VDBS_CMD_EXECUTE = $23;     // Çalıştır / Execute prepared

  // Yanıtlar / Responses
  VDBS_RSP_RESULT  = $40;     // SQL sonucu / SQL result
  VDBS_RSP_ERROR   = $41;     // Hata / Error
  VDBS_RSP_PONG    = $42;     // Ping yanıtı / Pong
  VDBS_RSP_AUTH    = $43;     // Oturum yanıtı / Auth response
  VDBS_RSP_PREPARE = $44;     // Hazırlık yanıtı / Prepare response
```

### TR: İstemci Kullanımı (`VDbClientNet.pas`)
```pascal
uses VDbClientNet;

var
  Cl: TVdbNetClient;
  R: TSqlResult;
  Ok: Boolean;
begin
  Cl := TVdbNetClient.Create;
  try
    // Bağlan / Connect
    if not Cl.Connect('127.0.0.1', 54720) then
    begin
      WriteLn('Bağlantı hatası');
      Exit;
    end;
    
    // Oturum aç / Login (R-107)
    Ok := Cl.Login('admin', 'admin123');
    if not Ok then
    begin
      WriteLn('Giriş başarısız');
      Exit;
    end;
    
    // Sorgu çalıştır / Execute query
    R := Cl.Exec('SELECT 1+1');
    WriteLn('Sonuç: ', R.Data[0][0]);
    
    // Hazırlıklı sorgu / Prepared statement (R-108)
    if Cl.Prepare('SELECT ad FROM musteri WHERE id = ?') then
    begin
      R := Cl.ExecutePrepared([1]);
      WriteLn('Müşteri: ', R.Data[0][0]);
    end;
    
    // Oturumu kapat / Logout
    Cl.Logout;
    
  finally
    Cl.Free;
  end;
end;
```

### TR: Sunucu Kullanımı (`VDbSqlServer.pas`)
```pascal
uses VDbSqlServer;

var
  Srv: TVdbSqlServer;
  Err: string;
begin
  Srv := TVdbSqlServer.Create('D:\db', 54720);
  try
    if not Srv.Start(Err) then
    begin
      WriteLn('Sunucu başlatılamadı: ', Err);
      Exit;
    end;
    
    WriteLn('Sunucu 54720 portunda çalışıyor...');
    WriteLn('Maksimum bağlantı: ', Srv.FMaxConns);  // Varsayılan: 4
    
    ReadLn;  // Bekle / Wait
  finally
    Srv.Free;
  end;
end;
```

### TR: Havuz / Kapasite (R-109)
- `FMaxConns = 4` (varsayılan / default)
- Her TCP bağlantısı bir havuz-slot'una eşlenir / Each TCP connection maps to a pool slot
- 5. istemci → "kapasite dolu" hatası / 5th client → "capacity full" error
- `FConns.Count` aktif bağlantı sayısını gösterir / shows active connection count

### EN: TCP SQL Protocol
See above. Protocol constants, client usage (`VDbClientNet`), server usage (`VDbSqlServer`), and pool capacity (max 4 concurrent connections).

---

## 7. Delphi İstemcisi (`VDBClient.pas`) / Delphi Client

### TR
```pascal
uses VDBClient;

var
  DB: TVDBClient;
  R: TVDBResult;
begin
  DB := TVDBClient.Create('satis.odb');
  try
    // Sarmalayıcı iki aşamalı VdbGet'i yutar
    // Wrapper swallows two-phase VdbGet
    
    R := DB.Exec('SELECT ad FROM musteri');
    while not R.Eof do
    begin
      WriteLn(R.FieldByName('ad').AsString);
      R.Next;
    end;
  finally
    DB.Free;
  end;
end;
```

### EN
See above. `VDBClient.pas` provides a Delphi-friendly wrapper around the DLL API.

---

## 8. Örnek Kodlar / Code Examples

### TR: C Kullanımı
```c
#include <windows.h>
#include <stdio.h>

typedef int (*VdbOpenFunc)(const char* path, int syncWrite);
typedef int (*VdbExecFunc)(int handle, const char* sql);
typedef int (*VdbResultValueFunc)(int result, int row, int col, char* buf, int len);
typedef void (*VdbCloseFunc)(int handle);

int main() {
    HINSTANCE hLib = LoadLibrary("vdbapi.dll");
    
    VdbOpenFunc VdbOpen = (VdbOpenFunc)GetProcAddress(hLib, "VdbOpen");
    VdbExecFunc VdbExec = (VdbExecFunc)GetProcAddress(hLib, "VdbExec");
    VdbResultValueFunc VdbResultValue = (VdbResultValueFunc)GetProcAddress(hLib, "VdbResultValue");
    VdbCloseFunc VdbClose = (VdbCloseFunc)GetProcAddress(hLib, "VdbClose");
    
    int db = VdbOpen("satis.odb", 0);
    int res = VdbExec(db, "SELECT ad FROM musteri");
    
    char buf[256];
    VdbResultValue(res, 0, 0, buf, sizeof(buf));
    printf("İlk kayıt: %s\n", buf);
    
    VdbClose(db);
    FreeLibrary(hLib);
    return 0;
}
```

### EN
See above C example.

---

## 9. Test / Demo / Hız Programları / Test / Demo / Benchmark

### TR
| Program | Açıklama |
|---|---|
| `vdbapitest.lpr` | DLL'yi `LoadLibrary+GetProcAddress` ile yükler, 9 grupta test eder (170/170) |
| `vdbclienttest.lpr` | Delphi istemci sarmalayıcısını test eder (101/101) |
| `sqltest.lpr` | Tam SQL test paketi (2224/2) |
| `vdbcrypttest.lpr` | Şifreleme testleri (60/60) |
| `vdbserver.lpr` | TCP SQL sunucusu (R-12) |
| `demo/` | Hız testleri ve örnek uygulamalar |

### EN
Same test programs as above.

---

## 10. Derleme / Build

### TR
```bash
# Windows (Lazarus)
lazbuild -B vdbapi.lpi
# Çıktı: vdbapi.dll

# Linux/macOS
./build_lib.sh
# Çıktı: libvdbapi.so veya libvdbapi.dylib

# Test
lazbuild -B vdbapitest.lpi
vdbapitest.exe
```

### EN
Same build commands.

---

## 11. Önemli Notlar / Important Notes

### TR
1. **İki aşamalı `VdbGet`:**
   ```c
   int need = VdbGet(h, key, NULL, 0);  // Boyutu öğren
   char* buf = malloc(need);
   VdbGet(h, key, buf, need);            // Veriyi oku
   ```

2. **UTF-8:** Tüm string'ler UTF-8. Türkçe karakterler için `SetMultiByteConversionCodePage(CP_UTF8)` gerekli (Delphi/Lazarus).

3. **Thread-safety:** Her `VdbOpen` handle'ı kendi kilit mekanizmasına sahip. Aynı handle'ı aynı anda iki thread'den çağırmayın.

4. **WAL:** Varsayılan olarak kapalı. `VdbWalSetAuto(h, 1)` ile açın. Crash-safe için önerilir.

5. **Şifreleme:** `VdbEncryptEnable(h, key, len)` ile açın. Anahtar yönetimi için `VdbEncryptCreateKeyFile` kullanın.

6. **CDC/Time Travel:** `VdbCdcStart(h)` ile başlatın. ~50ms'de bir WAL taranır. Tek istemci varsayılır.

7. **Paralel (R-14):** `VdbParallelInit(0)` ile otomatik worker sayısı. `VdbParallelShutdown()` ile kapatın.

8. **TCP SQL (R-12):** `TVdbNetClient` + `TVdbSqlServer` Pascal birimleri üzerinden kullanılır. Protokol `VDbNet.pas`'ta tanımlı.

### EN
Same notes as above.

---

## 12. Sürüm Geçmişi / Version History

### TR
| Sürüm | Tarih | Değişiklik |
|---|---|---|
| ABI 1.2 | 13.10.2026 | R-14 paralel işçi havuzu (3 export) |
| ABI 1.1 | 06.10.2026 | Otomatik WAL (3), şifreleme (9), CDC/Time Travel (7) |
| ABI 1.0 | İlk | 57 export (çekirdek + KV + SQL + WAL + bakım) |

### EN
Same version history.

---

## 13. İlgili Belgeler / Related Documents

### TR
- `DLL_KULLANIM.md` — DLL kullanım kılavuzu (detaylı)
- `docs/02-DOSYA-FORMATI.md` — `.odb` / `.wal` dosya formatı
- `docs/01-MOTOR.md` — Motor birimleri
- `SQL.md` — SQL referansı
- `README.md` — Proje özeti

### EN
Same related documents.

---

**Son güncelleme / Last updated:** 2026-10-14
**ABI Sürümü / ABI Version:** 1.2
**Toplam Export / Total Exports:** 57

---

## 14. Hızlı Referans / Quick Reference

### TR: En Çok Kullanılanlar
```pascal
// Aç / Open
h := VdbOpen('veri.odb', 0);

// SQL çalıştır / Execute SQL
res := VdbExec(h, 'SELECT * FROM musteri');

// Sonucu oku / Read result
rows := VdbResultRowCount(res);
cols := VdbResultFieldCount(res);
VdbResultValue(res, 0, 0, buf, 256);

// Kapat / Close
VdbResultFree(res);
VdbClose(h);
```

### EN: Most Used
See above.

---

**API Kategorileri / API Categories:**
1. ✅ Sürüm/Hata (5)
2. ✅ Aç/Kapa (3)
3. ✅ KV (7)
4. ✅ SQL/Sonuç (10)
5. ✅ Bakım/WAL (10)
6. ✅ Otomatik WAL (3)
7. ✅ Şifreleme (9)
8. ✅ CDC/Time Travel (7)
9. ✅ Paralel (3)
10. **Toplam: 57 export**