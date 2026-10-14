/* ===========================================================================
   vdbapi.h - VDb Engine C API
   ---------------------------------------------------------------------------
   Bu baslik her dilde kullanilabilir (Delphi, C#, Python ctypes, C, Rust...).
   Paylasilan kutuphane platforma gore:
     Windows : vdbapi.dll        (x86 ve x86_64)
     Linux   : libvdbapi.so
     macOS   : libvdbapi.dylib
   (Bkz. VDbPlatform.pas -> VdbSharedLibName.)

   CAGRI KURALI
     Windows'ta __stdcall, diger platformlarda (x86_64/aarch64) varsayilan
     ABI. 32-bit x86 Linux icin `__attribute__((stdcall))` uygulanir.
     FPC tarafi da daima `stdcall` anahtar sozcugunu kullanir; 64-bit
     hedeflerde bu varsayilan ABI ile aynidir.

   KURALLAR
     * Metinler UTF-8 ve NUL ile sonlanir.
     * Veriler ham bayt; metin de BLOB da ayni yolla gecer.
     * Hicbir istisna kutuphane sinirini gecmez. Her cagri VDB_OK (0) donerse
       basarilidir; degilse VdbLastError() ile ayrintiyi alin.
     * Metin donduren fonksiyonlar (VdbLastError, VdbResultValue, ...)
       kutuphane icindeki bir tampona isaret doner. Tampon BIR SONRAKI ayni
       cagriya kadar gecerlidir; iki isareti ayni anda tutmayin.
     * Bir tur serbest birakma yoktur.
   =========================================================================== */

#ifndef VDBAPI_H
#define VDBAPI_H

#include <stdint.h>

#if defined(_WIN32)
#  define VDB_CALL __stdcall
#  if defined(VDB_BUILD_DLL)
#    define VDB_API extern __declspec(dllexport)
#  else
#    define VDB_API extern __declspec(dllimport)
#  endif
#elif defined(__i386__)
   /* 32-bit x86 Linux/BSD: FPC `stdcall` = callee-cleans-stack. */
#  define VDB_CALL __attribute__((stdcall))
#  define VDB_API extern
#else
   /* x86_64 / aarch64: tek ABI vardir. */
#  define VDB_CALL
#  define VDB_API extern
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------ surum */
#define VDB_API_VERSION 0x00010200   /* 1.2: 1.1 + paralel havuz yonetimi */

VDB_API uint32_t      VDB_CALL VdbApiVersion(void);
VDB_API const char*   VDB_CALL VdbVersion(void);

/* ------------------------------------------------------------- hata */
#define VDB_OK            0
#define VDB_E_GENERAL    -1
#define VDB_E_BAD_HANDLE -2
#define VDB_E_OPEN       -3   /* dosya kilitli / acilamadi */
#define VDB_E_SQL        -4
#define VDB_E_READONLY   -5
#define VDB_E_BUFFER     -6   /* tampon kucuk */
#define VDB_E_RANGE      -7
#define VDB_E_ENGINE     -8
#define VDB_E_NOT_FOUND  -9
#define VDB_E_DUPLICATE -10
#define VDB_E_CONSTRAINT -11

VDB_API const char*   VDB_CALL VdbLastError(void);
VDB_API int32_t       VDB_CALL VdbLastErrorCodeGet(void);
VDB_API void          VDB_CALL VdbSetLastErrorCode(int32_t err);

/* ------------------------------------------------------- ac / kapa */
/* APath: .odb dosyasinin tam yolu (ya da klasor).
   ASyncWrite: 1 = her yazmada fsync (dayanikli, yavas).
                0 = ara bellekli (hizli; VdbFlush ile yazilir).
   Basarili: sifirdan farkli handle. Basarisiz: 0. */
VDB_API uint32_t      VDB_CALL VdbOpen(const char* APath, int32_t ASyncWrite);
VDB_API void          VDB_CALL VdbClose(uint32_t hDb);
VDB_API void          VDB_CALL VdbCloseAll(void);

/* --------------------------------------------------------- temel KV */
/* VdbGet: >=0 kopyalanan bayt; <0 gerekli boyut = -sonuc; -1 anahtar yok */
VDB_API int32_t       VDB_CALL VdbCount(uint32_t hDb);
VDB_API int32_t       VDB_CALL VdbPut(uint32_t hDb, int64_t key,
                                     const void* data, int32_t len);
/* Iki asamali kullanim (ONCESI boyut sorulur, SONRA okunur):
     need = VdbGet(h, key, NULL, 0);
     if (need == -1)              -> anahtar YOK
     else if (need <= VDB_E_GENERAL) -> HATA (need bir VDB_E_* kodu)
     else {
        buf[need];                // need = gerekli bayt sayisi
        if (need > 0) VdbGet(h, key, buf, need);   // -> kopyalanan bayt
     }
   NOT: hata kodlari (-1..-11) ile "gerekli boyut" ayni degere
   dusebilecegi icin yalniz -1 "yok" demektir; daha kucuk degerler
   HATA kodudUR ve mutlaka ayirt edilmelidir. */
VDB_API int32_t       VDB_CALL VdbGet(uint32_t hDb, int64_t key,
                                     void* buf, int32_t buflen);
VDB_API int32_t       VDB_CALL VdbExists(uint32_t hDb, int64_t key);
VDB_API int32_t       VDB_CALL VdbDelete(uint32_t hDb, int64_t key);
/* AOut NULL ise yalnizca anahtar sayisini doner. */
VDB_API int32_t       VDB_CALL VdbKeys(uint32_t hDb, int64_t* AOut, int32_t amax);
VDB_API void          VDB_CALL VdbFlush(uint32_t hDb);

/* -------------------------------------------------------------- SQL */
#define VDB_SQL_AUTOTXN 0x0001

/* Basarili: sifirdan farkli sonuc handle. Hata: 0 (VdbLastError'a bakin). */
VDB_API uint32_t      VDB_CALL VdbExec(uint32_t hDb, const char* sql,
                                      int32_t flags);

/* ------------------------------------------------------- sonuc seti */
VDB_API int32_t       VDB_CALL VdbResultFieldCount(uint32_t hRes);
VDB_API int32_t       VDB_CALL VdbResultRowCount(uint32_t hRes);
VDB_API const char*   VDB_CALL VdbResultFieldName(uint32_t hRes, int32_t col);
VDB_API const char*   VDB_CALL VdbResultValue(uint32_t hRes, int32_t row,
                                              int32_t col);
VDB_API int32_t       VDB_CALL VdbResultAffected(uint32_t hRes);
VDB_API int32_t       VDB_CALL VdbResultStmts(uint32_t hRes);
VDB_API const char*   VDB_CALL VdbResultMessage(uint32_t hRes);
VDB_API const char*   VDB_CALL VdbResultLastTable(uint32_t hRes);
VDB_API void          VDB_CALL VdbResultFree(uint32_t hRes);

/* -------------------------------------------------------- bakim/WAL */
/* WAL opt-in'dir: VdbWalWrite ana dosyaya YAZMAZ; kayit ancak
   VdbWalReplay / VdbWalCheckpoint ile kalicilik kazanir. */
VDB_API int32_t       VDB_CALL VdbVerify(uint32_t hDb, char* report,
                                         int32_t reportMax);
VDB_API int32_t       VDB_CALL VdbWalHas(uint32_t hDb);
VDB_API int32_t       VDB_CALL VdbWalRecordCount(uint32_t hDb);
VDB_API int32_t       VDB_CALL VdbWalWrite(uint32_t hDb, int64_t key,
                                           const void* data, int32_t len);
VDB_API int32_t       VDB_CALL VdbWalWriteDelete(uint32_t hDb, int64_t key);
VDB_API int32_t       VDB_CALL VdbWalReplay(uint32_t hDb);
VDB_API int32_t       VDB_CALL VdbWalCheckpoint(uint32_t hDb);

/* --- OTOMATIK WAL (write-ahead) -------------------------------------
   VdbWalSetAuto(hDb, 1) sonrasi her VdbPut / VdbDeleteOnce ONCE .wal'a,
   SONRA ana dosyaya yazilir. Boylece cagri aninda sistem cokerse kayit
   .wal'da kalir ve VdbWalReplay ile kurtarilir.
   Varsayilan KAPALI'dir (0) -> geriye donuk uyum.
   WAL yazilamazsa islem HATA doner ve ana dosyaya YAZILMAZ.
   Durum Close/Open ile sifirlanir. Elle VdbWalWrite kullaniminda
   otomatik modu kapatin (cift yazim olur). */
VDB_API int32_t       VDB_CALL VdbWalSetAuto(uint32_t hDb, int32_t enable);
VDB_API int32_t       VDB_CALL VdbWalIsAuto(uint32_t hDb);   /* 1/0 */
VDB_API int32_t       VDB_CALL VdbWalAutoCount(uint32_t hDb);/* yazilan kayit */
/* Hata sozlesmesi: hata durumunda donus degeri NEGATIF olur
   (genelde VDB_E_GENERAL = -1), SPESIFIK kod VdbErrCode() ile
   alinir (orn. VDB_E_BAD_HANDLE). Sorgu donduruculer 0 donerek
   hatayi gizlemez. Ayni sozlesme VdbWalHas / VdbWalRecordCount
   icin de gecerlidir. */
VDB_API int64_t       VDB_CALL VdbFileSize(uint32_t hDb);
VDB_API int64_t       VDB_CALL VdbDeadBytes(uint32_t hDb);
/* 1 = sikistirildi, 0 = gerek yok. AOld/ANew NULL olabilir. */
VDB_API int32_t       VDB_CALL VdbAutoCompact(uint32_t hDb,
                                              int64_t* AOld, int64_t* ANew);

/* ------------------------------------------------------- sifreleme */
/* Anahtar/parola metinleri UTF-8 ve NUL sonludur. Sifreli dosya
   ayni anda yalnizca dogru anahtarla acilabilir; etiket (tag)
   dogrulamasi yanlis anahtarla OKUMAYI hata yapar - sessizce bozuk
   veri donmez. Donus: 1 = basari, 0 = basarisiz (ayrinti:
   VdbLastError / VdbLastErrorCodeGet). */
VDB_API int32_t       VDB_CALL VdbEncryptEnable(uint32_t hDb, const void* key,
                                                int32_t keyLen);
VDB_API int32_t       VDB_CALL VdbEncryptDisable(uint32_t hDb);
VDB_API int32_t       VDB_CALL VdbEncryptIsEncrypted(uint32_t hDb); /* 1/0 */
VDB_API int32_t       VDB_CALL VdbEncryptCreateKeyFile(uint32_t hDb,
                                                const char* path,
                                                const char* password);
VDB_API int32_t       VDB_CALL VdbEncryptOpenKeyFile(uint32_t hDb,
                                                const char* path,
                                                const char* password);
/* 32 baytlik ham anahtarin hex hali (ham mod); bos = anahtar yok. */
VDB_API int32_t       VDB_CALL VdbEncryptKeyPath(uint32_t hDb, char* buf,
                                                int32_t bufMax);
VDB_API int32_t       VDB_CALL VdbEncryptFingerprint(uint32_t hDb, char* buf,
                                                int32_t bufMax);
VDB_API int32_t       VDB_CALL VdbHasEncryptedRecords(uint32_t hDb); /* 1/0 */
/* Parola rotasyonu (SQL: ALTER DATABASE KEY 'yeni'). Eski .key
   saltanati devre disi kalir; .key.bak yazilir. */
VDB_API int32_t       VDB_CALL VdbRekeyWithPassword(uint32_t hDb,
                                                const char* newPassword);

/* --------------------------------------------- CDC / Time Travel (poll) */
/* CDC = WAL uzerinden satir degisikliklerini yakalar. Callback YOK;
   istemci olaylari poll eder (C/Delphi icin en guvenli yon):
     VdbCdcStart(hDb)                       -> otomatik WAL acilir
     ... VdbPut / VdbExec ile yazmalar ...  -> olaylar ~50ms'de bir duser
     n = VdbCdcPollSize(hDb)                -> >0 olay boyutu, 0 = olay yok
     VdbCdcPoll(hDb, buf, n)                -> kopyalar + tuketir:
          >0 kopyalanan boyut, 0 = olay yok,
          VDB_E_BUFFER = tampon kucuk (olay tamponda KALIR)
     VdbCdcStop(hDb)                        -> durdurur; olaylar KALIR
   Paket (UTF-8, NUL'suz, alan ayirici #30 = RS):
     kind #30 seq #30 table #30 pk #30 oldJson #30 newJson
     kind: 0=insert, 1=update, 2=delete
     json : kolon degerleri dizisi, orn. ["1","bir"] (bos taraf "[]")
     seq  : CDC olay sira numarasi (WAL'de alan olarak YOKTUR)
   Tek istemci varsayilir (ayni anda iki VdbCdcPoll CAGRILMAZ).
   VdbClose, CDC nesnesini parcacigiyla birlikte serbest birakir.
   Zaman damgasi pakette YOKTUR - istemci kendi UTC damgasini ekle. */
VDB_API int32_t       VDB_CALL VdbCdcStart(uint32_t hDb);
VDB_API int32_t       VDB_CALL VdbCdcStop(uint32_t hDb);
VDB_API int32_t       VDB_CALL VdbCdcPollSize(uint32_t hDb);
VDB_API int32_t       VDB_CALL VdbCdcPoll(uint32_t hDb, char* buf, int32_t bufMax);
/* Tanilama sayaclari (NULL olanlar yazilmaz): olay / atlanan kayit /
   tampondaki bekleyen / tampon siniri asilirsa dusen. */
VDB_API int32_t       VDB_CALL VdbCdcStats(uint32_t hDb, int32_t* events,
                                           int32_t* skipped, int32_t* pending,
                                           int32_t* dropped);

/* VdbValueAt: WAL gecmisindeki SATIR degeri (JSON dizisi) - Time Travel.
   ASeq = WAL kayit INDEKSIdir (0 tabanli, ASeq dahil uygulanmis goruntu;
   n >= VdbWalRecordCount ise son kayda kirpilir). Gecmis yalnizca SON
   CHECKPOINT'TEN beriyi kapsar (VdbHistoryCount = 0 olabilir).
   Donus (VdbGet sozlesmesi): ALen=0 -> yalniz boyut (-n); yetersiz
   tampon -> -n (dokunulmaz); yeterli -> kopyalanan boyut;
   o noktada satir YOK (silinmis/hic yazilmamis) -> -1. */
VDB_API int32_t       VDB_CALL VdbValueAt(uint32_t hDb, const char* table,
                                          const char* pk, int32_t aSeq,
                                          char* buf, int32_t bufMax);
VDB_API int32_t       VDB_CALL VdbHistoryCount(uint32_t hDb); /* >=0, <0 hata */

/* ------------------------------------------------- R-14: paralel havuz */
/* Motor, buyuk ORDER BY siralamalarini isci havuzuna dagitir (esik:
   2048 satir; altinda daima seri). Havuz kapaliyken ilk buyuk siralama
   kendiliginden acilir. Bu uc fonksiyon acik yonetim icindir:
     VdbParallelInit(n)    n isciyle acar (n<=0: islemci sayisina gore);
                           donus = acilan isci sayisi (0 = basarisiz).
     VdbParallelWorkers()  gecerli isci sayisi (0 = havuz kapali).
     VdbParallelShutdown() kapatir; donus = kapatilan isci sayisi. */
VDB_API int32_t       VDB_CALL VdbParallelInit(int32_t maxWorkers);
VDB_API int32_t       VDB_CALL VdbParallelWorkers(void);
VDB_API int32_t       VDB_CALL VdbParallelShutdown(void);

#ifdef __cplusplus
}
#endif
#endif /* VDBAPI_H */
