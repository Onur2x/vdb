# Tur İzleme Skill'i

Bu skill, bir "tur" (işlem serisi) sırasında dokunan dosyaları sayar ve tur结束时通过桌面通知显示触及的文件数量.

## Kullanım

1. Turu başlatmak için:
   ```
   /tour start
   ```

2. Turu sonlandırmak ve bildirim almak için:
   ```
   /tour end
   ```

## İç funzionamento

- `/tour start` çalıştırıldığında, mevcut git durumunu `.claude/tour-base` dosyasına kaydeder.
- `/tour end` çalıştırıldığında, kaydedilen temel durumla mevcut git durumu karşılaştırılır, değişen dosya listesi alınır ve sayı bulunur.
- Sonuç, `PushNotification` aracılığıyla kullanıcıya gösterilir.

## Notlar

- Bu skill, çalışma dizininin bir git deposu olduğunu varsayar.
- Tur sırasında केवलファイルの追加・変更・削除が検出されます（`.gitignore` に従う）.
- Sayım sadece çalışma ağacındaki değişiklikleri içerir;ステージドファイルは含まれません (gerekiyorsa `git diff --cached` ile eklenebilir).

## Örnek

```bash
/tour start
# bazı dosyaları düzenle, sil, yeni dosya oluştur
/tour end
```

Bu, örneğin "3 dosya tur sırasında değiştirildi" gibi bir bildirim gösterir.