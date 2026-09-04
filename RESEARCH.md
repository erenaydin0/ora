# ora (native) — Fizibilite Ölçümleri

## Bu Dosya Nedir

Bu proje, önceki Electron + Python + WhisperX ora'sının ağırlık ve hız
sorunları üzerine açıldı. Aşağıdaki ölçümler **2026-09-04 tarihinde bu makinede
gerçekten çalıştırıldı** — tahmin veya dokümantasyon okuması değil.

Ortam: macOS 26.3.2 (25D2150), Xcode 26.6, Apple Silicon (M3), Apple Intelligence açık.

Bir API'nin davranışından şüpheye düşersen `probes/` altındaki ilgili dosyayı
yeniden derleyip çalıştır. **Bu bulguları hafızadan tartışma — probe'u koştur.**

---

## 0. Teşhis: eski ora'da ağırlık nereden geliyordu

```
node_modules   343 MB
backend/.venv  1.2 GB   ← asıl yük
  torch 310M · scipy 115M · transformers 85M · onnxruntime 80M
  sympy 78M · pandas 73M · sklearn 48M · matplotlib 33M
```

Bu ~820 MB'ın tamamı **WhisperX'in bağımlılık zinciri**. Electron kaldırılsa
bile duruyordu. Üstelik ctranslate2 MPS desteklemediği için ASR CPU'da
`float32` ile koşuyordu — mevcut donanımın en yavaş kullanımı.

**Sonuç:** Sorun Electron değil, Python/PyTorch ASR yığınıydı. Yeni mimari
her ikisini de kaldırır: toplam çalışma zamanı bağımlılığı = 0 MB
(modeller işletim sistemine ait, uygulamayla paketlenmez).

---

## 1. Siri / Apple Intelligence "dikte"ye bağlanabilir mi?

**Hayır.** Siri'ye transkripsiyon veya özetleme yaptıran genel bir API yok.
App Intents yalnızca *senin uygulamanı* Siri'ye açar, tersi değil.
Bu yol kapalıdır; bir daha araştırma.

Erişilebilir olan şey Siri değil, altındaki iki ayrı framework:
`Speech` (dikte motoru) ve `FoundationModels` (cihaz üstü LLM). İkisi de
aşağıda ölçüldü.

---

## 2. Speech framework — Türkçe destekleniyor mu?

macOS 26'da iki ayrı transkripsiyon sınıfı var ve **dil destekleri farklı.**
Bu ayrım projenin en kritik bulgusudur.

### `SpeechTranscriber` — Türkçe YOK
```
30 locale: de_AT de_CH de_DE en_AU en_CA en_GB en_IE en_IN en_NZ en_SG
en_US en_ZA es_CL es_ES es_MX es_US fr_BE fr_CA fr_CH fr_FR it_CH it_IT
ja_JP ko_KR pt_BR pt_PT yue_CN zh_CN zh_HK zh_TW
→ tr: YOK
```

### `DictationTranscriber` — Türkçe VAR ve kurulu
```
43 locale: ar_SA da_DK de_AT de_CH de_DE en_AU en_CA en_GB en_IE en_IN
en_NZ en_SG en_US en_ZA es_CL es_ES es_MX es_US fi_FI fr_BE fr_CA fr_CH
fr_FR he_IL it_CH it_IT ja_JP ko_KR ms_MY nb_NO nl_BE nl_NL pt_BR pt_PT
ru_RU sv_SE th_TH tr_TR vi_VN yue_CN zh_CN zh_HK zh_TW
→ tr_TR: VAR
installedLocales: tr_TR  (bu makinede zaten kurulu)
```

> İlk bakışta "Apple'ın yeni Speech API'si Türkçe desteklemiyor" sonucuna
> varmak kolay — çünkü tanıtılan sınıf `SpeechTranscriber`. Doğrusu:
> **`DictationTranscriber` kullan.** İkisi de aynı `SpeechAnalyzer` motoruna
> takılır, API yüzeyi neredeyse aynıdır.

*probe:* `probes/locales.swift`

### Gerçek ses üstünde doğruluk testi

Girdi: `say -v Yelda` ile üretilmiş 23.5 sn Türkçe toplantı cümleleri, 16 kHz mono.

| Ölçüm | Sonuç |
|---|---|
| İşlem süresi | **0.43 – 0.52 sn** (≈45x gerçek zamanlı) |
| Türkçe diakritikler (ı İ ğ ş ç ö ü) | **kusursuz** |
| Kelime hatası | 1 / 47 ("bütçe" → "Gökçe") |
| Noktalama | **yok** — `.punctuation` seçeneği Türkçe'de etkisiz |
| Kelime düzeyi zaman damgası | **çalışıyor** (`.audioTimeRange` niteliği) |
| Güven skoru | mevcut (`.transcriptionConfidence`) |

Çıktı örneği:
```
[  0.00→ 23.54] Toplantıya başlamadan önce geçen haftaki aksiyonları gözden
geçirelim Ayşe entegrasyon testlerini tamamladı mı şirket içi güvenlik
denetimi çarşamba gününe ertelendi Mehmet bey Gökçe onayını perşembeye kadar
iletecek yeni sürümün çıkış tarihini iki hafta öteliyoruz çünkü müşteri geri
bildirimleri değerlendirilecek

run 'Toplantıya ' t=0.00-0.81
run 'başlamadan ' t=0.81-1.65
run 'aksiyon'     t=3.18-3.78
run 'ları '       t=3.78-4.02
```

**Uyarı — bu testin sınırı:** girdi TTS sesiydi; temiz, tek konuşmacılı,
aksansız. Gerçek toplantı sesi (uzak alan, üst üste konuşma, aksan, arka plan)
belirgin şekilde zorlar. **Faz 0'daki gerçek kayıt kıyaslaması yapılmadan
WhisperX'ten tamamen vazgeçme kararı kesinleşmiş sayılmaz** — bkz. FALLBACK.md.

*probe:* `probes/transcribe.swift`

### Kullanışlı ek yetenekler
- `Preset.timeIndexedLongDictation` — uzun form + zaman indeksli, toplantı için doğru ön ayar
- `ContentHint.farField` — uzak alan mikrofon ipucu
- `ContentHint.customizedLanguage(modelConfiguration:)` — **özel sözlük**;
  ora'nın vocabulary özelliğinin doğal arka ucu
- `ReportingOption.volatileResults` — canlı ön izleme (kayıt sırasında değil,
  kural #1; kayıt sonrası ilerleme göstergesi için kullanılabilir)

---

## 3. FoundationModels — Türkçe LLM cihaz üstünde

```
availability: available          (Apple Intelligence açıkken)
availability: unavailable(.appleIntelligenceNotEnabled)   ← kapalıyken; gerçek durum, ele al
supportedLanguages: tr-Latn-TR VAR
  (ayrıca da, de, en×2, es×3, fr×2, it, ja, ko, nb, nl, pt×2, sv, vi, zh×3)
```

### Türkçe özetleme testi — yapılandırılmış çıktı

`@Generable` + `@Guide` ile şemalı üretim, 5 replikli Türkçe transkript girdisi:

```
SÜRE: 5.09 saniye

GENEL BAKIŞ: Toplantıda, entegrasyon testlerinin yüzde 80'i tamamlandı, şirket
içi güvenlik denetimi ertelendi, yeni sürümün çıkışı iki hafta ötelendi ve test
raporu pazartesi paylaşılacak.

KARARLAR:
  • Şirket içi güvenlik denetimi çarşamba gününe ertelendi.
  • Bütçe onayını perşembeye kadar iletilecek.
  • Yeni sürümün çıkış tarihi iki hafta ertelendi.

AKSİYONLAR:
  • Ayşe   → Entegrasyon testlerinin yüzde 80'ini tamamlamak [Cuma]
  • Mehmet → Bütçe onayını perşembeye kadar iletmek [Perşembe]
  • Ayşe   → Test raporunu pazartesi paylaşmak [Pazartesi]
  • Ben    → Yeni sürümün çıkış tarihini iki hafta ötelemek [Belirtilmedi]
```

Türkçe akıcı, aksiyon çıkarımı doğru, **son tarih alanı doluyor**
(önceki ora'da bu alan hep NULL'dı çünkü prompt şablonu istemiyordu).
Elle JSON ayrıştırma gerekmiyor — şema tip güvenli.

*probe:* `probes/summarize.swift`

### Bağlam penceresi — 4096 token, sert sınır

```
✓ ~15.600 karakter (≈3.800 token) — OK, 3.97 sn
✗ ~31.200 karakter — exceededContextWindowSize:
    "Content contains 7638 tokens, which exceeds the maximum allowed
     context size of 4096."
```

Türkçe'de kabaca **4 karakter ≈ 1 token**.

**Mimari sonucu:** map-reduce zorunlu. Parça boyutu ~10.000 karakter
(talimat + üretilen çıktı için pay). 60 dakikalık bir toplantı ~50.000 karakter
→ ~5 parça + 1 birleştirme adımı ≈ 30 saniye. Kabul edilebilir.

*probe:* `probes/context_limit.swift`

---

## 4. Karşılaştırma tablosu

| | Eski ora (Electron+Python) | Yeni ora (native) |
|---|---|---|
| Kurulum boyutu | ~1.5 GB + 2.5 GB model indirmesi | ~15 MB, model indirmesi yok |
| Çalışma zamanı bağımlılığı | Python 3.11 + PyTorch + Node | yok |
| 23 sn Türkçe ses | ~10-20 sn (CPU float32) | **0.43 sn** |
| Özetleme | Qwen3.5 4B, 2.5 GB GGUF | Apple 3B, 0 MB (OS'a ait) |
| Bellek (boşta) | Electron + uvicorn + torch | tek SwiftUI süreci |
| .dmg paketleme | **tıkalı** (gömülü Python gerekiyor) | standart Xcode arşivi |
| Diarization | pyannote (çalışıyor) | **yok** ← tek gerçek gerileme |
| Windows | ikincil hedefti | kapsam dışı (kullanıcı kararı) |

**Tek gerçek kayıp diarization.** Apple'ın konuşmacı ayrıştırma API'si yok.
Hafifletici etken: stereo kanal ayrımı zaten "ben vs. karşı taraf" ayrımını
model çalıştırmadan çözüyor. Sistem kanalı içindeki kişi ayrımı Faz 6'ya
bırakıldı — bkz. ROADMAP.md ve FALLBACK.md.

---

## 5. Probe'ları çalıştırma

```bash
cd probes
swiftc -parse-as-library locales.swift -o locales && ./locales
swiftc -parse-as-library summarize.swift -o summarize && ./summarize
swiftc -parse-as-library context_limit.swift -o context_limit && ./context_limit
# transcribe.swift bir ses dosyası ister:
say -v Yelda -f ref.txt -o t.aiff && afconvert -f WAVE -d LEI16@16000 -c 1 t.aiff tr_test.wav
swiftc -parse-as-library transcribe.swift -o transcribe && ./transcribe
```

---

## 5. Sistem sesi: ScreenCaptureKit tek yol mu? — **Hayır**

İlk taslakta "sistem sesi için tek yol ScreenCaptureKit'tir" yazılmıştı.
**Yanlıştı.** macOS 14.2'den beri CoreAudio'da süreç tap'i var:

```
CoreAudio.framework/Headers/AudioHardwareTapping.h
  AudioHardwareCreateProcessTap(CATapDescription*, AudioObjectID*)
    API_AVAILABLE(macos(14.2))
  AudioHardwareDestroyProcessTap(AudioObjectID)
```

### Canlı test sonucu
```
OSStatus: 0   tapID: 124
✅ TAP OLUŞTU — ekran kaydı izni istenmedi
   format: 48000.0 Hz · 2 kanal · 32 bit
```

### Neden ScreenCaptureKit'ten üstün

| | ScreenCaptureKit | CoreAudio süreç tap'i |
|---|---|---|
| İzin | **Ekran kaydı** (TCC — kullanıcıyı ürküten en ağır izin) | Sistem sesi yakalama; ekran izni yok |
| Kapsam | Tüm sistem sesi | **Süreç veya bundle ID bazlı seçim** |
| Kurulum | `SCStream`, ekran yakalama makinesi ses için taşınıyor | Doğrudan ses yolu |
| Kanal | mixdown | mono/stereo/cihaz akışı seçilebilir |

`CATapDescription` yapılandırma seçenekleri:
- `initStereoMixdownOfProcesses:` — **yalnızca Teams/Zoom sesini** yakala
- `initStereoGlobalTapButExcludeProcesses:` — kendimiz hariç her şey
- `bundleIDs` *(macOS 26+)* — süreç ID'si aramadan doğrudan bundle ID ver
- `processRestoreEnabled` *(macOS 26+)* — uygulama kapanıp açılırsa tap'e geri döner
- `muteBehavior` — yakalarken kullanıcının sesi duymaya devam etmesi (`.unmuted`)
- `privateTap` — tap yalnızca bizim sürecimize görünür

**Ürün sonucu:** Yalnızca toplantı uygulamasının sesini yakalayabilmek, transkripte
Spotify'ın, bildirim seslerinin ve diğer uygulamaların karışmasını **yapısal olarak**
engeller. Bu, global yakalamaya göre gerçek bir kalite kazancıdır ve
ScreenCaptureKit ile mümkün değildir.

**Doğrulanması gereken:** Test sandbox'sız bir komut satırı aracıyla yapıldı.
İmzalı ve sandbox'lı bir uygulamada `NSAudioCaptureUsageDescription` ve buna
karşılık gelen TCC onayı gerekecektir — bu, ekran kaydı izninden çok daha
yumuşak bir istemdir ama Faz 2'de gerçek bir app bundle ile doğrulanmalıdır.

*probe:* `probes/tap.swift`

---

## 6. Kayıt sırasında canlı transkripsiyon yapılabilir mi? — **Evet, rahatlıkla**

Eski ora'daki "kayıt sırasında transkripsiyon yok" kuralı WhisperX + PyTorch
ağırlığından doğmuştu. Yeni yığında bu gerekçe ortadan kalktı.

### Test: 219 saniyelik Türkçe ses, **gerçek zamanlı** akış simülasyonu
0.5 saniyelik parçalar halinde `AsyncStream<AnalyzerInput>` üzerinden beslendi,
`.volatileResults` + `.frequentFinalization` açık.

```
duvar saati        : 231.7 sn  (ses 219.1 sn)
harcanan CPU       : 2.09 sn
CPU / gerçek zaman : 1.0%  (tek çekirdek eşdeğeri)
tepe bellek        : 7.7 MB
ilk sonuç gecikmesi: 1.03 sn
kesin sonuç: 4  ·  geçici (canlı) sonuç: 692
```

**Yorum:** Tek çekirdeğin %1'i. İki kanal (mic + sistem) eşzamanlı koşsa ~%2.
Bu, SwiftUI arayüzünün kendisinden daha ucuzdur. 692 geçici sonuç, saniyede
~3 güncelleme demek — ekranda akan canlı transkript için fazlasıyla yeterli.
1 saniyelik ilk sonuç gecikmesi kabul edilebilir.

**Kural değişikliği:** Canlı transkripsiyon serbesttir ve tercih edilir.
**LLM kuralı değişmez** — Foundation Models kayıt sırasında çalışmaz
(tek özet çağrısı 5 sn sürüyor ve yükü ani; kayıt hattını riske atar).

**Tasarım koşulu:** Transkripsiyon asla kaydın önüne geçmez. Ses yazımı birincil
iştir; transkripsiyon en iyi çaba ile çalışan ikincil tüketicidir. Hata verir
veya geri kalırsa kayıt kesintisiz sürer, kayıt sonrası tam geçiş açığı kapatır.

*probe:* `probes/live.swift`

---

## 7. SQLite hâlâ doğru seçim mi? — **Evet**

Alternatif SwiftData/Core Data'dır. Belirleyici etken tam metin arama:
ikisi de FTS sunmaz, `CONTAINS` yüklemleri tablo taraması yapar. Saatlerce
transkript biriktiren bir üründe bu kabul edilemez.

Sistem SQLite'ı bu makinede:
```
3.51.0 · ENABLE_FTS5 derlenmiş
```

Türkçe davranış testi (`unicode61` tokenizer):
```
'bütçe'    sorgusu → 'Bütçe onayı'          ✓ diakritik eşleşiyor
'istanbul' sorgusu → 'İstanbul toplantısı'  ✓ İ/i katlaması doğru
```

Türkçe'nin noktalı/noktasız İ-i sorunu FTS5'in varsayılan tokenizer'ında
doğru çözülüyor — özel tokenizer yazmaya gerek yok.

Ek gerekçeler: SQLite dosyası taşınabilir, incelenebilir, yedeklenebilir.
%100 yerel bir üründe kullanıcının kendi verisine doğrudan erişebilmesi
bir kısıt değil, bir özelliktir.

---

## 8. Low Power Mode hâlâ gerekli mi? — **Hayır, kaldırıldı**

Eski ora'da bu özellik vardı çünkü WhisperX + Qwen3.5 bir toplantıyı işlerken
CPU'yu dakikalarca doldurur, pili hızla tüketirdi; "şarja takılınca işle"
gerçek bir ihtiyaçtı.

Yeni ölçümlerle karşılaştırma (60 dakikalık toplantı):

| | Eski ora | Yeni ora |
|---|---|---|
| Kayıt sırasında | ses yazımı, ~460 MB/saat RAM | ses yazımı + canlı transkripsiyon, ~%1 CPU |
| Kayıt sonrası transkripsiyon | 30-60 dk, CPU dolu | ~80 sn (45x gerçek zamanlı) |
| Özetleme | Qwen3.5 4B, dakikalar | ~30 sn (5 parça map-reduce) |
| **Toplam kayıt sonrası** | **30-60 dakika** | **~2 dakika** |

2 dakikalık bir iş için şarj bekleme alt sistemi yazmak gerekçesizdir.

**Yerine geçen:** iki satırlık kontrol —
`ProcessInfo.processInfo.isLowPowerModeEnabled` ve `.thermalState`.
Biri olumsuzsa otomatik başlatma, kullanıcıya sor. `IOPSCopyPowerSourcesInfo`,
şarj durumu izleme ve "Şarja Takılıyken" ayarı yazılmaz.

---

## 9. Toplantı algılama: hangi sinyal?

Eski ora her 10 saniyede `ps aux` çalıştırıp süreç adı arıyordu
(`backend/meeting_detection/detector.py`). İki temel kusuru vardı:
Teams'in **açık olması** ile **toplantıda olmak** ayırt edilemiyordu, ve ham
alt-dize eşleşmesi Slack Helper süreçlerinde bile tutuyordu.

anarlog'un yaklaşımı doğru: **mikrofonu kimin kullandığını** izle
(`anarlog:crates/detect/src/mic/macos/`). macOS'ta bunun karşılığı CoreAudio'da
hazır duruyor ve **polling gerektirmiyor.**

### Ölçülen sinyaller (izin gerekmiyor)
```
AudioHardwareSystem.shared.processes  → 30 süreç
  her biri için:  bundleID · pid · isRunningInput · isRunningOutput
```

### Olay dinleyicisi testi — polling YOK
```
AudioObjectAddPropertyListenerBlock(
    kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList, ...)
listener OSStatus: 0
izlenen süreç sayısı: 30

[OLAY 1] ...
[OLAY 3] aktif: com.apple.CoreSpeech(mic)      ← 'say' çalıştırıldığında
[OLAY 4] aktif: com.apple.CoreSpeech(mic)
toplam olay: 4
```

Süreç listesi **ve** her sürecin `isRunningInput`/`isRunningOutput` özelliği
dinlenebiliyor; durum değişince blok anında tetikleniyor. CPU maliyeti sıfıra
yakın, izin istemi yok.

**Kritik ayrım:** `isRunningInput == true` = süreç **mikrofonu şu anda
kullanıyor**. Teams arka planda açıksa bu `false`'tur. Eski ora'nın çözemediği
sorun tam olarak budur.

**Yanlış pozitif gözlendi:** `com.apple.CoreSpeech` sistem TTS/dikte sırasında
mikrofonu açık gösterdi. Dışlama listesi zorunludur (bkz. CLAUDE.md).

*probe:* `probes/detect.swift`

---

## 10. Çentik (notch) — herkese açık API ile geometri

```
Ekran: Built-in Retina Display
  frame          : 1470 × 956 @2x
  safeAreaInsets : top = 32.0
  auxTopLeft     : (0, 924, 646, 32)
  auxTopRight    : (825, 924, 645, 32)
  ✅ ÇENTİK: 179 × 32 pt, konum x=646 y=924
  menü bar yüksekliği: 22.0
```

`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (macOS 12+) çentiğin
tam dikdörtgenini veriyor: iki yardımcı alanın arasındaki boşluk çentiktir.
`safeAreaInsets.top` de yüksekliği veriyor.

**Ama çentik için bir API yok.** Oraya çizmek, çentiğin üstüne konumlanmış
kenarlıksız bir `NSPanel` demektir. Bunun getirdiği gerçek yükümlülükler:
- Pencere seviyesi `.statusBar` veya üstü; **non-activating** olmalı
  (`NSWindow.StyleMask.nonactivatingPanel`) — yoksa uygulamayı öne getirir
- Boştayken `ignoresMouseEvents = true` — yoksa menü bar tıklamalarını yutar
- Tam ekran uygulamalarda menü bar gizlenir; overlay buna uymalı
- Harici monitörde çentik yok (`auxiliaryTopLeftArea == nil`) → menü bara düş
- Çentiksiz Mac'lerde (Mac mini, Studio, eski MacBook) yok → menü bara düş

Yani çentik bir **ek katman**dır, taşıyıcı yüzey değil. Taşıyıcı yüzey
`MenuBarExtra`'dır.

*probe:* `probes/notch.swift`

---

## 11. Otomatik başlık: pencere başlığından okumak

Eski ora aktif pencere başlığından toplantı adı çıkarıyordu.
`CGWindowListCopyWindowInfo` bu makinede başlıkları döndürdü (14 pencerenin
13'ü), **ama test sandbox'sız bir CLI aracıyla yapıldı.** İmzalı ve sandbox'lı
bir uygulamada `kCGWindowName` başka uygulamalar için ekran kaydı izni olmadan
`nil` gelir. Yani bu yol muhtemelen **ekran kaydı izni** ister — tap sayesinde
kurtulduğumuz izni geri getirir.

**Daha iyi yol:** Başlığı transkriptten üret. Foundation Models zaten elimizde,
Türkçe özetlemede iyi çalışıyor ve başlık üretmek özetten kolay bir iştir.
Sıfır izin, daha iyi başlık. Takvim entegrasyonu açıksa etkinlik adı doğrudan
kullanılır (EventKit izni, isteğe bağlı).

*probe:* `probes/wintitle.swift`

---

## 12. Takvim entegrasyonu — EventKit

### İzin modeli (macOS 14+)
```
EKEventStore.authorizationStatus(for: .event) → notDetermined (bu makinede)
requestFullAccessToEventsWithCompletion:   API_AVAILABLE(macos(14.0))
requestWriteOnlyAccessToEventsWithCompletion:
```
**Okumak `fullAccess` gerektirir**; `writeOnly` yalnızca yazmak içindir.
ora takvime **hiçbir zaman yazmaz** ama okumak için full access istemek zorundadır —
`NSCalendarsFullAccessUsageDescription` metni bunu açıkça söylemeli.

> İzin istemi bu oturumda **tetiklenmedi**: `--request` bayrağı olmadan probe
> yalnızca durumu okur. İstem tetiklenseydi terminal binary'sine kalıcı takvim
> erişimi verilmiş olurdu.

### Elde edilen alanlar
`EKEvent` / `EKCalendarItem`:
`title` · `startDate` · `endDate` · `isAllDay` · `notes` · `location` ·
`URL` **(toplantı linki)** · `organizer` · `attendees` · `status` ·
`eventIdentifier` · `calendar`

`EKParticipant`: `name` · `URL` (mailto:) · `participantType` ·
`participantRole` · `participantStatus` · `isCurrentUser`

### Kritik ayrıntılar
- `EKParticipantType` yalnızca `person` değil: **`room` ve `resource` de var.**
  Toplantı odaları ve projeksiyon cihazları katılımcı sayılmamalı — filtrelenir.
- `EKParticipantStatus.declined` olanlar katılımcı listesine girmemeli.
- `EKEventStoreChangedNotification` ile takvim değişiklikleri dinlenir —
  polling gerekmez.
- `event.URL` çoğu Teams/Zoom davetinde toplantı linkini taşır; taşımıyorsa
  `notes` içinde bulunur. Bu, **hangi uygulamanın tap'leneceğini** toplantı
  başlamadan bilmeyi sağlar.

### Neden değerli — üç somut kazanç
1. **Katılımcı adları ASR doğruluğunu artırır.** Özel isimler tanımanın en zayıf
   noktası. Katılımcı adları `DictationTranscriber`'a
   `ContentHint.customizedLanguage` ile verildiğinde tam da o zayıf noktayı
   kapatır. Takvim ve transkripsiyon burada birbirini besliyor.
2. **Başlık sorunu tamamen çözülür.** §11'de pencere başlığı okumanın ekran
   kaydı izni isteyeceği tespit edilmişti; takvim etkinlik adını doğrudan verir.
3. **Algılama güveni yükselir.** Mikrofon sinyali "bir toplantı var" der;
   takvim "hangi toplantı" der. İkisi çakıştığında öneri
   "Teams toplantısı algılandı" yerine "Q3 Bütçe Toplantısı — 4 katılımcı" olur.

*probe:* `probes/calendar.swift` (varsayılan güvenli; `--request` ile gerçek veri)
