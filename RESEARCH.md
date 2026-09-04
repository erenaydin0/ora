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
| Kurulum boyutu | ~1.5 GB + 2.5 GB model indirmesi | **7,7 MB uygulama · 3,7 MB .dmg** (ölçüldü, §18) |
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


---

## 13. Faz 2 ölçümleri — tap'ten gerçekten ses akıyor mu?

§5 tap'in **oluştuğunu** göstermişti. Faz 2 tap'ten **PCM aktığını** ve imzalı,
sandbox'lı bir uygulamada hangi iznin istendiğini ölçtü.

### 13.1 Tap → toplama cihazı → IOProc (global kapsam)
```
tap: OSStatus 0   format: 48000 Hz · 1 kanal (mono mixdown) · 32 bit float
toplama cihazı: OSStatus 0   giriş akışı: 48000 Hz · 1 kanal
IOProc çağrısı  : 245        toplam frame: 125.440
host time aralığı: 2.60 sn   tepe genlik : 0.616
```
Tap'i okumanın yolu: özel (`private`) bir toplama cihazı yaratıp tap'i
`kAudioAggregateDeviceTapListKey` ile ona bağlamak, sonra
`AudioDeviceCreateIOProcIDWithBlock` ile okumak. Saat kaynağı olarak varsayılan
çıkış cihazı `kAudioAggregateDeviceMainSubDeviceKey` ile veriliyor.

*probe:* `probes/tap_record.swift`

### 13.2 `bundleIDs` ile kapsamlı tap — çalışıyor
QuickTime Player hedeflenip ses çalarken ölçüldü:
```
IOProc çağrısı: 655   frame: 335.360   tepe genlik: 0.619
```
**Ama hedef uygulama ses üretmiyorken IOProc hiç çağrılmıyor** — sessiz buffer
bile gelmiyor. Yazıcı örnekleri mutlak frame konumuna yazdığı için bu sorun
değil: gelmeyen aralık sessizlik olarak dolar.

*probe:* `probes/tap_bundleid.swift`

### 13.3 **Tarayıcı ve Electron sesi ana bundle'dan çıkmıyor** ← en önemli bulgu
Safari'de ses çalarken `isRunningOutput == true` olan süreç:
```
com.apple.WebKit.GPU   ← Safari'nin kendisi DEĞİL
```
`say` komutunun sesi ise bundle ID'si **olmayan** bir süreçten çıkıyor.

**Sonucu:** `desc.bundleIDs = ["com.apple.Safari"]` gibi bir tap tarayıcı
toplantısında **sessizlik** yakalar. Tarayıcılar bu yüzden tap hedefi olarak
kullanılmaz; tarayıcı toplantıları doğrudan global tap'e gider
(`MeetingApps.browsers`). Aynı risk Electron uygulamaları (Teams, Slack,
Discord) için de var — ölçülmedi, bu yüzden koda bir gözcü kondu:
kapsamlı tap 3 saniye boyunca hiç frame vermezken sistemde başka bir süreç ses
çalıyorsa global tap'e geçilir. Sessizce boş kanal kaydetmek kabul edilemez.

### 13.4 İmzalı, sandbox'lı uygulamada TCC
```
✅ Mikrofon istemi çıktı — metni Info.plist'teki Türkçe metin
❌ Ekran kaydı istemi ÇIKMADI
❌ Ayrı bir "sistem sesi" istemi de çıkmadı — tap ek istem olmadan açıldı
```
§5'in "ekran kaydı izni gerekmiyor" iddiası gerçek app bundle'da doğrulandı.

### 13.5 Uçtan uca kayıt
14,1 saniyelik kayıt; mikrofon konuşuyor, Safari ses çalıyor:
```
biçim : 2 kanal · 16000 Hz · Int16 · interleaved
ch0 mic    tepe  5.486   (saniyelik: 3 4 4 2 4 4 5 4 4 5 3 0 0 0)
ch1 sistem tepe 20.279   (saniyelik: 0 14 20 17 17 20 17 12 20 17 17 0 0 0)
```
**Kanal hizalaması:** iki kanalın 20 ms'lik zarfları çapraz korele edildi —
en iyi gecikme **bir pencere (20 ms)**, normalize korelasyon 0.77. Bu, mikrofonun
hoparlörü duymasındaki akustik gecikme mertebesindedir; host time hizalaması
çalışıyor.

### 13.6 Çökme kurtarma
Kayıt sürerken `kill -9`:
```
diskte kalan: 1788552053337.wav + 1788552053337.wav.recording (işaretçi)
açılışta    : "Yarım kalan kayıt bulundu: 5.6 sn"
onarım sonrası: 2 ch · 16000 Hz · 5.59 sn, ch0 tepe 2.253 — dosya çalınabilir
```
Ses artımlı yazıldığı için içerik sağlam kalıyor; yalnızca son flush'tan sonraki
başlık alanları onarılıyor. SIGKILL'de kaybedilen, henüz flush edilmemiş
son ~1 saniyedir.


---

## 14. Faz 3 ölçümleri — transkripsiyon uygulamada

### 14.1 `AnalyzerInput` damgası: sessiz bir tuzak
İlk uygulama, her buffer'ı kaydın mutlak zamanıyla damgalıyordu:
`CMTime(seconds: t, preferredTimescale: 48_000)`. Sonuç:
```
Canlı  : SFSpeechErrorDomain 2 "Audio input timestamp overlaps or precedes prior audio input"
Tam geçiş: Foundation._GenericObjCError 0   ← kullanıcıya ulaşan hata buydu
```
Dört strateji aynı ses üzerinde, bilerek bozulmuş damgalarla denendi
(her 5. parçada 40 ms geri kayma, her 9. parçada buffer düşmesi):

| Strateji | Sonuç |
|---|---|
| Ham mutlak saniye damgası | ❌ `SFSpeechErrorDomain 2` |
| Saniye cinsinden monotonluk kelepçesi | ❌ `SFSpeechErrorDomain 2` — **kelepçe yetmiyor** |
| **Analiz oranında tam frame sayısı** (`CMTime(value:timescale:)`) | ✅ hata yok |
| Damga hiç vermemek | ✅ hata yok |

**Sonuç:** `CMTime(seconds:preferredTimescale:)` yuvarlaması ardışık buffer'ları
mikrosaniye mertebesinde çakıştırıyor ve motor bunu reddediyor. Damga
**tam frame sayısından** kurulmalı. Uygulamadaki karar:
- **Tam geçiş**: damga verilmez — dosya akışı zaten kesintisiz
- **Canlı**: damga tam frame sayısıyla verilir ve monoton kelepçelenir
  (buffer düşerse ileri sıçranır, geriye asla gidilmez)

*probe:* `probes/live_timestamps.swift`

### 14.2 ora'nın kendi kaydı üzerinde tam geçiş — **gerçek ses, TTS değil**
Uygulamanın ürettiği 31,8 saniyelik stereo WAV, kanal kanal çözüldü:
```
ch0 mic    2 segment · 0.46 sn  (≈69x gerçek zamanlı)
   [10.86→17.04] güven 0.86  "Ses ses deneme 1.02 test ne haber nasılsın"
   [23.52→31.84] güven 0.76  "transkript yok kayıt sırasında canlı transkript
                              burada akar ama sanki akmıyor gibi ne dedin o işe"
ch1 sistem 1 segment · 0.37 sn
   [ 0.00→ 3.12] güven 0.62  "Evet"
```
Bu, §2'deki TTS testinden farklı olarak **gerçek insan sesidir** — Faz 0'ın
istediği kanıtın ilk parçası. Diakritikler doğru, noktalama yok (§2 doğrulandı),
kelime düzeyi güven skoru geliyor. Örnek kısa ve okunan metin olduğu için
Faz 0 kapanmış sayılmaz; gerçek bir toplantı hâlâ gerekli.

*probe:* `probes/transcribe_stereo.swift`


---

## 15. Faz 4 ölçümleri — noktalama ve özetleme uygulamada

### 15.1 Konuşmacı öneki noktalama isteminde guardrail tetikliyor
Noktalama adımı ilk denemede `guardrailViolation` ("Response may contain
sensitive or unsafe content") ile patladı. Tek değişkeni izole eden ölçüm,
aynı istem 8'er kez koşularak:

| Girdi biçimi | Sonuç |
|---|---|
| `1. toplantıya başlamadan önce…` (öneksiz) | **8/8 başarılı** |
| `1. Ben: toplantıya başlamadan önce…` (konuşmacı önekli) | 2/8 başarılı · **6 guardrail** |

Özetleme isteminde aynı önek **sorun çıkarmıyor** (önekli 8/8, öneksiz 8/8);
sorun noktalama istemine özgü.

**Uygulamadaki karar:** noktalama istemine konuşmacı öneki **eklenmez**
(noktalama için gereksiz zaten), özetleme isteminde **korunur** (kimin neyi
üstlendiğini bilmek için gerekli). Ayrıca guardrail'e takılırsa daha yalın bir
istemle bir kez daha denenir.

*probe:* `probes/guardrail.swift`, `probes/guardrail_rate.swift`,
`probes/guardrail_summary.swift`

### 15.2 Map-reduce — 60 dakikalık toplantı mertebesi
```
transkript : 50.231 karakter ≈ 12.557 token  (bağlam penceresinin 3 katı)
parça      : 6 · en büyük 9.999 karakter
map süresi : 47.9 sn   (parça başına özet + @Generable konu başlığı)
toplam     : 55.3 sn   guardrail: 0
```
`RESEARCH.md §3`'teki "~5 parça ≈ 30 saniye" tahmini iyimserdi; gerçek ölçüm
parça başına konu başlığı üretimi de dahil **~55 saniye**. Yine de kabul edilebilir.

Çıktı kalitesi:
```
AKSİYONLAR:
  • Ayşe   → Entegrasyon testlerinin kalanını cuma gününe bitiriyor   [Cuma]
  • Ben    → Müşteri entegrasyon dokümanı taslağını tamamlayacak      [Salı]
  • Kerem  → Veri tabanı göçü bakım penceresini üstlenecek            [Cumartesi]
  • Mehmet → Bütçe onayını iletecek                                   [Perşembe]
```
Kişi adları map aşamasında korunuyor ve `sonTarih` doluyor — önceki ora'da
NULL kalan alan bu. İstemde "'Ben' bu kaydı tutan kişidir" cümlesi olmadan
`kisi` alanı hep "belirtilmedi" geliyordu.

**Gözlenen kusur:** model bazı karar ve aksiyonları iki kez üretiyor.
Uygulamada normalize edilmiş karşılaştırmayla eleniyor.

**Konu başlıkları `@Generable` şema ile alınmalı.** Düz metin istendiğinde model
numaralı bir liste ve açıklama döküyor; `KonuBasligi` şemasıyla tek satır,
2-5 kelimelik başlık geliyor.

*probe:* `probes/mapreduce60.swift`


---

## 16. Faz 5 ölçümleri — depolama ve arama

### 16.1 FTS5 Türkçe davranışı, gerçek şema üzerinde
Migration'lar uygulandıktan sonra ora'nın kendi veritabanında:
```
'istanbul'* → "İstanbul ofisinin kalemleri henüz gelmedi"   ✓ İ/i katlaması
              "Ekip haftaya İstanbul'da toplanacak"
'bütçe'*    → "Bütçe onayını perşembeye kadar iletebilir miyiz"  ✓ diakritik
```
§7'deki bulgu üretim şemasında da geçerli: `unicode61` tokenizer'ı özelleştirmeye
gerek yok.

### 16.2 Cascade silme ve FTS temizliği
```
silmeden önce : 3 toplantı · 4 transkript · 4 FTS satırı · 1 özet · 1 aksiyon · 1 konu
DELETE FROM meetings WHERE id = 1
sildikten sonra: 2 toplantı · 2 transkript · 2 FTS satırı · 0 özet · 0 aksiyon · 0 konu
```
Silinen toplantının metni FTS'te **0 eşleşme** veriyor (trigger indeksi temizledi),
kalan kayıt hâlâ aranabiliyor. `corrections` satırı korunuyor ve `meeting_id`
NULL oluyor (`ON DELETE SET NULL`) — kullanıcının düzeltme bilgisi toplantı
silinince kaybolmuyor, Faz 6'da sözlüğü besleyecek.


---

## 17. Faz 6 ölçümleri — özel sözlük, algılama, bildirim

### 17.1 Özel sözlük Türkçe'de ne kadar işe yarıyor?
`ContentHint.customizedLanguage` gerçekten ölçüldü. Aynı ses, aynı beş terim,
farklı yapılandırmalarla:

| Yapılandırma | Datassist | Kerem Yücesoy | Alens | Bordro Farkları | CosmicDoc |
|---|---|---|---|---|---|
| sözlüksüz | ✗ | ✓ | ✗ | ✓ | ✗ |
| count 30 · varsayılan ağırlık | ✓ | ✓ | ✗ | ✓ | ✗ |
| count 30 · weight 0.5 | ✓ | ✓ | ✗ | ✓ | ✗ |
| **count 30 · weight 1.0** | **✓** | **✓** | **✓** | **✓** | ✗ |
| count 200 · weight 1.0 | ✓ | ✓ | ✗ | ✓ | ✗ |

**Sonuç:** terim tutma 2/5 → **4/5**. `weight: 1.0` belirleyici; `count`'u
30'dan 200'e çıkarmak sonucu **kötüleştiriyor** (aşırı ağırlıklandırma çevredeki
kelimeleri bozuyor). Uygulamadaki sabitler bu ölçümle seçildi:
`CustomVocabulary.phraseCount = 30`, `weight = 1.0`.

`CosmicDoc` hiçbir yapılandırmada tutmadı — bitişik yazılmış İngilizce kökenli
bir bileşik, Türkçe akustik modelin en zorlandığı biçim. Sözlük bir iyileştirmedir,
garanti değil.

Derleme maliyeti ihmal edilebilir: `export` 1,5 ms / 1 KB, `prepare` ~0,4 sn.

*probe:* `probes/vocabulary.swift`

### 17.2 Bildirim izni algılamayı **bloke etmemeli**
İlk uygulama `startServices()` içinde önce `UNUserNotificationCenter
.requestAuthorization` çağırıyordu. İstem kullanıcı yanıtlayana kadar askıda
kaldığı için **toplantı algılama hiç başlamadı**. İzin verilmediğinde ise:
```
[UYARI] [ui] Bildirim izni alınamadı: Notifications are not allowed for this application
[BİLGİ] [pipeline] Toplantı algılama açıldı — 27 süreç izleniyor
```
Sıra düzeltildikten sonra algılama izinden bağımsız çalışıyor. Bildirim
gönderilemediğinde öneri **arayüzdeki şeritte** görünür — tek yüzeye bağlı
kalınmaz.

### 17.3 Sözlük durum makinesi
SQL düzeyinde doğrulandı:
- Kullanıcının onayladığı (`active`) bir kelime, aynı düzeltme tekrar aday
  ürettiğinde `pending`e **düşmüyor** — onay geri alınmıyor.
- Reddedilen kelime 30 günlük soğuma boyunca listede görünmüyor ve
  transkripsiyona verilmiyor.


---

## 18. Faz 7 ölçümleri — paketleme

Release arşivi bu makinede alındı:
```
ora.app : 7,7 MB      (GRDB dahil, gömülü çalışma zamanı yok)
ora.dmg : 3,7 MB      (UDZO sıkıştırma)
```
§4'teki "~15 MB" tahmini yüksekti; gerçek boyut yarısından az. Karşılaştırma:
eski ora ~1,5 GB bağımlılık **artı** ~2,5 GB model indirmesi istiyordu ve
`.dmg` paketleme gömülü Python yüzünden hiç çalışmamıştı.

Arşiv **standart bir Xcode arşividir** — gömülecek çalışma zamanı olmadığı için
özel bir adım yok. `scripts/build-release.sh` arşivi alır, `.app`'i çıkarır,
`.dmg` üretir; `Developer ID Application` kimliği ve `ora-notary` anahtarlık
profili varsa imzalar ve notarize eder, yoksa uyarıp geçer.

**Bu makinede kod imzalama kimliği yok** (`security find-identity` → 0 kimlik),
bu yüzden imzalama ve notarizasyon adımları **çalıştırılamadı**. Üretilen `.dmg`
ad-hoc imzalıdır ve başka bir Mac'te Gatekeeper tarafından engellenir.


---

## 19. Sandbox'ta takvim: eksik yetki sessizce başarısız oluyor

"Takvimi kullan" açıldığında hiçbir izin istemi çıkmıyordu. Sebep entitlements
dosyasında eksik bir anahtar:

```xml
<key>com.apple.security.personal-information.calendars</key>
<true/>
```

Bu yetki olmadan sandbox'lı bir uygulamada `requestFullAccessToEvents`
**istem çıkarmadan** başarısız oluyor — hata da atmıyor, yalnızca izin verilmemiş
gibi dönüyor. `probes/calendar.swift` sorunu göstermiyordu çünkü probe
sandbox'sız bir komut satırı aracı.

**Genel ders:** §12'deki "okumak `fullAccess` gerektirir" bulgusu doğruydu ama
eksikti; sandbox'lı bir uygulamada TCC izninin yanında **entitlement de** gerekir.
Mikrofon (`device.audio-input`) için bu baştan yazılmıştı, takvim için atlanmıştı.


---

## 20. macOS 26 ikonu: sanat eseri kenardan kenara olmalı

İlk ikon, kendi yuvarlatılmış köşesini ve %10 iç boşluğunu kendi çiziyordu.
Sonuç Dock ve Cmd+Tab'da **boş bir çerçeve** gibi göründü.

`NSWorkspace.icon(forFile:)` ile macOS'un ikonu nasıl çözdüğüne bakıldığında
sebep görüldü: macOS 26 sanat eserinin üstüne **kendi kabuğunu** (yuvarlatılmış
kare maskesi + gölge) uyguluyor. Kendi kabuğunu çizen bir sanat eseri
"ikon içinde ikon" üretiyor; küçük boyutlarda iki iç içe çerçeve kalıyor ve
marka kayboluyor.

**Kural:** ikon PNG'leri **kenardan kenara dolu** olmalı — kendi köşe yarıçapı,
kendi kenarlığı ve kendi iç boşluğu olmamalı. İçerik, maskenin kırpmayacağı
orta alanda (kenarlardan ~%16 içeride) durmalı. `scripts/make-icon.swift`
bunu böyle üretir.

**Teşhis yöntemi:** ikonun paket içinde doğru olması yetmiyor; macOS'un onu nasıl
çözdüğüne bakmak gerekiyor —
`NSWorkspace.shared.icon(forFile:)` ve `NSRunningApplication.icon` çıktısını PNG
olarak yazdır. İkon değişince LaunchServices önbelleği de tazelenmeli
(`lsregister` PATH'te değildir, tam yol gerekir):
```bash
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
touch ora.app && "$LSREG" -f ora.app && killall Dock
```

### Çözülmemiş: Cmd+Tab ve Dock hâlâ yer tutucu gösteriyor
Sanat eseri düzeltildikten sonra **her ölçülebilir katman doğru** hâle geldi:
- paket içindeki `AppIcon.icns` ✓
- `Assets.car` içindeki 10 rendition (16…1024 px, `AssetType: Icon Image`) ✓
- `NSWorkspace.icon(forFile:)` ✓
- `NSRunningApplication.icon` (Cmd+Tab'ın kullandığı API) ✓
- `Info.plist`: `CFBundleIconFile` + `CFBundleIconName` — Notes.app ve Claude.app
  ile **birebir aynı yapı** ✓

Buna rağmen Cmd+Tab boş yer tutucu gösteriyor. Elenen nedenler:
ikon önbelleği (`iconservices.store` silindi, `iconservicesagent` ve Dock
yeniden başlatıldı), DerivedData yolu (uygulama `/tmp` altından da denendi),
bozuk asset kataloğu (`assetutil` çıktısı sağlıklı).

Geriye kalan tek yapısal fark: uygulama **ad-hoc imzalı**. Kendinden imzalı bir
sertifikayla denendi ama o yol kapalı (§21). Gerçek bir `Developer ID` kimliğiyle
tekrar denenmeli.


---

## 21. Kendinden imzalı sertifika Gatekeeper'ı geçmiyor

Ad-hoc imzanın her derlemede değişmesi hem TCC izinlerini sıfırlıyor hem de
ikon sorununun tek şüphelisi durumunda. Kendinden imzalı bir kod imzalama
sertifikası denendi:

```
security verify-cert -p codeSign   → certificate verification successful
codesign --verify --deep --strict  → valid on disk, satisfies its Designated Requirement
spctl -a -vvv ora.app              → rejected  (origin=ora Development)
```

İmza geçerli ve sertifika güvenilir olmasına rağmen Gatekeeper değerlendirmesi
reddediyor ve uygulama **hiç açılmıyor** ("ora bir sorundan dolayı açılamıyor").
Karantina özniteliği yok; sebep Gatekeeper'ın yalnızca Developer ID / App Store
kimliklerini kabul etmesi.

**Sonuç:** kendinden imzalı sertifika bu projede kullanılamaz. Ad-hoc imza yerel
olarak çalıştığı için varsayılan odur. Sabit kimlik gerektiren her şey
(TCC izinlerinin kalıcılığı, muhtemelen Dock ikonu) Apple Developer Program
üyeliğini bekliyor.
