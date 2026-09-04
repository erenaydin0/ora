# ora — native

macOS için yerel toplantı kaydedici. Kaydeder, transkribe eder, özetler.
Hiçbir veri cihazı terk etmez.

Bu, Electron + Python + WhisperX ile yazılmış önceki ora'nın (`../`)
yerine geçen yeniden yazımıdır. Neden: eski yığın ~1.5 GB bağımlılık
taşıyordu ve ASR CPU'da `float32` koşuyordu. Yeni yığında çalışma zamanı
bağımlılığı ve indirilen model **yoktur** — transkripsiyon ve özetleme
işletim sisteminin kendi cihaz üstü modelleriyle yapılır.

**Gereksinim:** macOS 26+, Apple Silicon, Apple Intelligence açık.
**Boyut:** 7,7 MB uygulama, 3,7 MB .dmg — indirilen model yok.
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

## Geliştirme

```bash
xcodebuild -project ora.xcodeproj -scheme ora -configuration Debug build
./scripts/build-release.sh          # arşiv → .app → .dmg
```

### İmzalama durumu

Uygulama şu an **ad-hoc** imzalanıyor (`ORA_SIGN_IDENTITY = "-"`). Bunun iki
bilinen sonucu var:

- İmza her derlemede değiştiği için TCC uygulamayı yeni sanar ve **mikrofon
  iznini yeniden sorar**.
- Dock ve Cmd+Tab uygulama ikonu yerine boş yer tutucu gösterebilir
  (bkz. RESEARCH.md §20).

**Kendinden imzalı sertifika bu sorunları çözmez.** Denendi ve ölçüldü:
sertifika kod imzalama için geçerli ve güvenilir olsa bile
(`security verify-cert -p codeSign` başarılı, `codesign --verify` başarılı),
Gatekeeper değerlendirmesi reddediyor:

```
spctl -a -vvv ora.app  →  rejected  (origin=ora Development)
```

Sonuç: uygulama **hiç açılmıyor**, "ora bir sorundan dolayı açılamıyor" hatası
veriyor. Ad-hoc imza en azından yerel olarak çalışıyor, bu yüzden varsayılan o.

Kalıcı çözüm **Apple Developer Program üyeliği ve `Developer ID Application`
sertifikasıdır**. `scripts/build-release.sh` böyle bir kimlik ve `ora-notary`
anahtarlık profili bulursa imzalamayı ve notarizasyonu kendiliğinden yapar;
ek kod gerekmez. Kimliğiniz olduğunda:

```bash
xcodebuild -project ora.xcodeproj -scheme ora -configuration Debug \
  ORA_SIGN_IDENTITY="Developer ID Application: Adınız (TEAMID)" build
```

## Durum
**Faz 1 tamam** — Xcode projesi ayakta, uygulama açılıyor: izin metinleri, sandbox,
`AppPaths`, `Log`, BRAND paleti ve boş 3 sütunlu pencere. Henüz hiçbir şey kaydetmiyor.

Sıradaki iş: **Faz 0** (gerçek toplantı sesiyle doğruluk kapısı — kullanıcı kaydı
gerektirir) ve **Faz 2** (ses yakalama).

```bash
xcodebuild -project ora.xcodeproj -scheme ora -configuration Debug build
```
