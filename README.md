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

### Kendinden imzalı sertifika (önerilir)

Kimlik olmadan uygulama **ad-hoc** imzalanır ve imza her derlemede değişir;
TCC uygulamayı her seferinde yeni sanır ve **mikrofon iznini yeniden sorar**.
Sabit bir kimlik bunu bitirir:

1. **Anahtar Zinciri Erişimi**'ni aç → menüden *Sertifika Yardımcısı →
   Sertifika Oluştur…*
2. Ad: `ora Development` · Kimlik Türü: **Kendinden İmzalı Kök**
3. **"Varsayılanları geçersiz kılmama izin ver" kutusunu İŞARETLE.**
   Bu kutu işaretlenmezse Sertifika Türü sorulmaz ve sertifika **S/MIME
   (e-posta)** olarak üretilir; `security find-identity -p codesigning`
   onu görmez, derleme "No certificate matching" der.
4. Sertifika Türü: **Kod İmzalama** → sonraki adımları varsayılanla geç → Oluştur
5. Sertifikayı çift tıkla → *Güven* → *Kod İmzalama*: **Her Zaman Güven**
6. Doğrula — kimlik listede görünmeli:

```bash
security find-identity -v -p codesigning
```

7. Derlerken kimliği ver:

```bash
xcodebuild -project ora.xcodeproj -scheme ora -configuration Debug ORA_SIGN_IDENTITY="ora Development" build
```

Kalıcı olsun istersen `ORA_SIGN_IDENTITY` proje ayarını Xcode'da bir kez
`ora Development` yap. Proje **manuel imzalama** kullanır
(`CODE_SIGN_STYLE = Manual`); otomatik imzalama kimlik `-` olmadığı anda
Apple geliştirici takımı ister ve kendinden imzalı sertifikayla çalışmaz.

Yanlış türde bir sertifika ürettiysen Anahtar Zinciri'nde sil ve 3. adımı
atlamadan yeniden oluştur. Bu sertifika **dağıtım için yetmez** — başka bir Mac'te
Gatekeeper yine engeller. Dağıtım Apple Developer Program üyeliği ve
`Developer ID Application` sertifikası ister; `scripts/build-release.sh`
kimlik ve `ora-notary` anahtarlık profili varsa imzalama ile notarizasyonu
kendiliğinden yapar.

## Durum
**Faz 1 tamam** — Xcode projesi ayakta, uygulama açılıyor: izin metinleri, sandbox,
`AppPaths`, `Log`, BRAND paleti ve boş 3 sütunlu pencere. Henüz hiçbir şey kaydetmiyor.

Sıradaki iş: **Faz 0** (gerçek toplantı sesiyle doğruluk kapısı — kullanıcı kaydı
gerektirir) ve **Faz 2** (ses yakalama).

```bash
xcodebuild -project ora.xcodeproj -scheme ora -configuration Debug build
```
