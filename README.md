# ora — native

macOS için yerel toplantı kaydedici. Kaydeder, transkribe eder, özetler.
Hiçbir veri cihazı terk etmez.

Bu, Electron + Python + WhisperX ile yazılmış önceki ora'nın (`../`)
yerine geçen yeniden yazımıdır. Neden: eski yığın ~1.5 GB bağımlılık
taşıyordu ve ASR CPU'da `float32` koşuyordu. Yeni yığında çalışma zamanı
bağımlılığı ve indirilen model **yoktur** — transkripsiyon ve özetleme
işletim sisteminin kendi cihaz üstü modelleriyle yapılır.

**Gereksinim:** macOS 26+, Apple Silicon, Apple Intelligence açık.
Windows kapsam dışıdır.

## Dosyalar — okuma sırası
| Dosya | Ne için |
|---|---|
| **RESEARCH.md** | Hangi API'nin Türkçe'de gerçekten çalıştığını gösteren ölçümler. Mimari kararların dayanağı. Önce bunu oku. |
| **CLAUDE.md** | Proje hafızası, kritik kurallar, API davranış notları |
| **ARCHITECTURE.md** | Modül sözleşmeleri, eşzamanlılık, hata modeli |
| **ROADMAP.md** | Fazlar. Faz 0 bir karar kapısıdır, atlanmaz |
| **FALLBACK.md** | Apple yığını yetmezse ne yapılacağı |
| **BRAND.md** | Renk, tipografi, ton — UI kodu yazmadan önce |
| **DESIGN.md** | Arayüz yapısı: yüzeyler, ana pencere, canlı mod |
| `probes/` | Canlı API doğrulama betikleri. Şüpheye düşersen tahmin etme, koştur |

## Özet bulgular
- `SpeechTranscriber` Türkçe **desteklemiyor**; `DictationTranscriber` **destekliyor** (tr_TR)
- 23.5 sn Türkçe ses → **0.43 sn** transkripsiyon, diakritikler kusursuz
- Türkçe çıktı **noktalamasız** gelir — LLM ile geri konur
- `FoundationModels` Türkçe destekliyor (tr-Latn-TR), bağlam **4096 token** → map-reduce zorunlu
- Sistem sesi için **ScreenCaptureKit gerekmiyor**: CoreAudio süreç tap'i ekran kaydı
  izni istemiyor ve yalnızca toplantı uygulamasının sesini yakalayabiliyor
- **Canlı transkripsiyon yapılabilir**: gerçek zamanlı akışta tek çekirdeğin %1'i,
  7.7 MB bellek. Eski "kayıt sırasında transkripsiyon yok" kuralı kaldırıldı
  (LLM yasağı duruyor)
- SQLite kalıyor — FTS5 sistemde derlenmiş, `unicode61` Türkçe İ/i katlamasını doğru yapıyor
- Low Power Mode kaldırıldı — kayıt sonrası iş 30-60 dakikadan ~2 dakikaya indi
- Siri'ye transkripsiyon/özetleme yaptıran API **yok** — bu yol kapalı
- Tek gerçek gerileme: **diarization yok**; stereo kanal ayrımı çoğu ihtiyacı karşılıyor

## Durum
**Faz 1 tamam** — Xcode projesi ayakta, uygulama açılıyor: izin metinleri, sandbox,
`AppPaths`, `Log`, BRAND paleti ve boş 3 sütunlu pencere. Henüz hiçbir şey kaydetmiyor.

Sıradaki iş: **Faz 0** (gerçek toplantı sesiyle doğruluk kapısı — kullanıcı kaydı
gerektirir) ve **Faz 2** (ses yakalama).

```bash
xcodebuild -project ora.xcodeproj -scheme ora -configuration Debug build
```
