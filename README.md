# ora

macOS için yerel toplantı kaydedici. Toplantıyı kaydeder, konuşulanı yazıya
döker, özetini ve aksiyon maddelerini çıkarır.

**Hiçbir veri cihazı terk etmez.** Ağ erişimi yok — bulut API'si, hesap,
telemetri, model indirmesi yok. Transkripsiyon ve özetleme işletim sisteminin
kendi cihaz üstü modelleriyle yapılır.

**Gereksinim:** macOS 26+, Apple Silicon, Apple Intelligence açık.
**Boyut:** 7,7 MB uygulama · 3,7 MB .dmg.
**Diller:** arayüz Türkçe; transkripsiyon Türkçe ve İngilizce (+41 locale).

Windows ve Linux kapsam dışıdır — soyutlama katmanı yazılmaz.

---

## Nasıl çalışır

Kayıt **stereo** yazılır: kanal 0 mikrofon (sen), kanal 1 sistem sesi
(karşı taraf). Kanallar hiçbir zaman karıştırılmaz — konuşmacı ayrımı buradan
gelir. Ses 1 saniyede bir diske eklenir, RAM'de biriktirilmez.

```
Kayıt sırasında ─┬─ ses → disk (16 kHz · 16 bit · stereo WAV)   ← birincil iş
                 └─ canlı transkripsiyon (kanal başına)          ← en iyi çaba

Kayıt bitince   → tam transkripsiyon geçişi
                → noktalama restorasyonu   (Türkçe'de Speech API noktalamıyor)
                → map-reduce özetleme      (bağlam penceresi 4096 token)
                → dilbilgisi son kontrolü
                → SQLite + bildirim
```

Kayıt sırasında **LLM çalıştırılmaz**; canlı transkripsiyon asla kaydın önüne
geçmez — hata verirse kayıt kesintisiz sürer, eksik kalan kayıt sonrası
geçişte kapanır.

## Ne yapar

- **Toplantı algılama** — bilinen bir toplantı uygulaması mikrofonu tuttuğunda
  kayıt önerir. `ps` polling'i değil, CoreAudio olay dinleyicileri; izin
  gerektirmez. İzinsiz otomatik kayıt yapmaz.
- **Uygulamaya özel ses yakalama** — sistem sesi CoreAudio süreç tap'iyle
  alınır: **ekran kaydı izni istemez** ve yalnızca toplantı uygulamasının
  sesini kaydeder (Spotify, bildirimler transkripte girmez).
- **Özet** — kişiler, aksiyonlar, genel bakış, kararlar, gövdeli konu blokları.
  Aksiyon maddesinde kişi, görev, gerekçe ve son tarih; toplantılar arası
  aksiyon panosu.
- **Toplantı sohbeti** — kayıtla ilgili soru sorma, cihaz üstünde.
- **Tam metin arama** — SQLite FTS5, Türkçe diakritik ve İ/i katlaması doğru.
- **Özel sözlük** — şirket ve kişi adları tanımaya beslenir; takvim
  katılımcıları otomatik eklenir.
- **Takvim** (opt-in, varsayılan kapalı) — başlık ve katılımcı için EventKit.
  ora takvime asla yazmaz.
- **Ses oynatıcı** — satır senkronu, hız, özet maddesinden transkripte alıntı bağı.
- **Dışa aktarım** — Markdown, PDF, e-posta.
- **Depolama yönetimi** — AAC sıkıştırma (11,5×, kanal ayrımı korunur),
  saklama süresi.

## Teknoloji — hepsi Apple yerel

| Katman | Teknoloji |
|---|---|
| UI | SwiftUI + AppKit köprüsü |
| Sistem sesi | CoreAudio süreç tap'i (`CATapDescription`) |
| Mikrofon | AVAudioEngine |
| Transkripsiyon | `SpeechAnalyzer` + `DictationTranscriber` |
| Özetleme / sohbet | `FoundationModels` (cihaz üstü ~3B LLM) |
| Veritabanı | SQLite + FTS5, GRDB.swift üzerinden |
| İkonlar | SF Symbols |

**Tek harici bağımlılık GRDB.swift'tir.** Python yok, Node yok, Electron yok,
indirilen model dosyası yok.

## Geliştirme

```bash
xcodebuild -project ora.xcodeproj -scheme ora -configuration Debug build
```

```bash
./scripts/build-release.sh
```

`build-release.sh` arşivi alır, .app ve .dmg üretir; makinede bir
`Developer ID Application` kimliği ve `ora-notary` anahtarlık profili bulursa
imzalama ve notarizasyonu kendiliğinden yapar.

`probes/` altındaki betikler canlı API doğrulamalarıdır — bir API'nin
davranışından şüphelenirsen tahmin etme, ilgili probe'u koştur.

### İmzalama durumu

Uygulama şu an **ad-hoc** imzalanıyor (`ORA_SIGN_IDENTITY = "-"`). Sonuçları:

- İmza her derlemede değiştiği için TCC **mikrofon iznini her derlemede**
  yeniden sorar.
- Dock ve Cmd+Tab ikon yerine yer tutucu gösterebilir.
- **Bildirim izni hiç alınamaz** — bu yüzden geliştirme derlemelerinde toplantı
  önerisi yalnızca penceredeki şeritte görünür.

**Kendinden imzalı sertifika çözüm değil:** sertifika kod imzalama için geçerli
olsa bile (`codesign --verify` başarılı) Gatekeeper reddediyor
(`spctl -a` → `rejected`) ve uygulama hiç açılmıyor. Kalıcı çözüm Apple
Developer Program üyeliğidir:

```bash
xcodebuild -project ora.xcodeproj -scheme ora -configuration Debug \
  ORA_SIGN_IDENTITY="Developer ID Application: Adınız (TEAMID)" build
```

## Proje düzeni

```
ora/Core/           AppPaths, Log, ayarlar, güç/termal, ses arşivi, kısayol
ora/Capture/        ses yakalama: mikrofon, sistem tap'i, stereo WAV yazıcı
ora/Detect/         toplantı algılama (CoreAudio olay dinleyicileri)
ora/Transcribe/     Speech geçişleri, canlı mod, dil seçimi, alıntı eşleştirme
ora/Intelligence/   noktalama, map-reduce özetleme, @Generable şemalar
ora/Store/          GRDB şeması, migration'lar, tek kapı MeetingStore
ora/Calendar/       EventKit (opt-in)
ora/UI/             SwiftUI yüzeyleri, menü bar, ayarlar, dışa aktarım
Config/             Info.plist (izin metinleri), entitlements (ağ girişi yok)
scripts/            ikon üretimi, sürüm derlemesi, geliştirme verisi yükleyici
probes/             canlı API doğrulama betikleri
```

Veriler `~/Library/Application Support/ora/` altında: `ora.sqlite`,
`recordings/`, `logs/`.

## Dokümanlar — okuma sırası

| Dosya | Ne için |
|---|---|
| **RESEARCH.md** | Hangi API'nin Türkçe'de gerçekten çalıştığını gösteren ölçümler. Mimari kararların dayanağı. Önce bunu oku. |
| **CLAUDE.md** | Proje hafızası, kritik kurallar, API davranış notları |
| **ARCHITECTURE.md** | Modül sözleşmeleri, eşzamanlılık, hata modeli |
| **ROADMAP.md** | Fazlar ve kapsam |
| **BRAND.md** | Renk, tipografi, ton — UI kodu yazmadan önce |
| **DESIGN.md** | Arayüz yapısı: yüzeyler, ana pencere, canlı mod |
| **COMPETITION.md** | Rakip incelemesi, önceliklendirilmiş iyileştirme listesi |
| **FALLBACK.md** | Apple yığını yetmezse ne yapılacağı (whisper.cpp yolu) |
