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

Elenen nedenlerin tam listesi:

| Şüpheli | Nasıl elendi |
|---|---|
| İkon önbelleği | `iconservices.store` silindi, `iconservicesagent` ve Dock yeniden başlatıldı — değişmedi |
| DerivedData yolu | Uygulama `/tmp` ve `~/Applications` altından da çalıştırıldı — değişmedi |
| Bozuk asset kataloğu | `assetutil` 10 rendition'ı sağlıklı raporluyor (16…1024 px, `AssetType: Icon Image`) |
| Eksik `Info.plist` anahtarı | `CFBundleIconFile` + `CFBundleIconName` dolu; Notes.app ile aynı |
| macOS 26 yeni ikon biçimi (`.icon`) | Notes.app da macOS 26.3 SDK ile derlenmiş, `.icon` dosyası **yok**, yalnızca icns + Assets.car — ve ikonu çalışıyor |
| Çalışma anında ikon atama | `NSApp.applicationIconImage = NSWorkspace.icon(forFile:)` denendi — Dock yine yer tutucu gösterdi, kod geri alındı |

**Geriye kalan tek fark: kod imzası.** Notes.app Apple imzalı, Claude.app
Developer ID imzalı, ora **ad-hoc**. Kendinden imzalı sertifikayla denendi ama
o yol kapalı (§21). Bu, mikrofon izninin her derlemede yeniden sorulmasıyla
**aynı kök nedendir**; ikisi de gerçek bir `Developer ID` kimliği bekliyor.

`NSRunningApplication` uygulamayı `.regular` politikayla ve **ikonu var** diye
raporluyor; yani sorun uygulamanın ikonu sağlamamasında değil, Dock'un onu
çizmemesinde.


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

## 22. `AVAudioFile.read` dosya sonunda hata kurmadan başarısız oluyor

**Belirti.** 49 saniyelik gerçek bir kayıttan sonra kayıt sonrası tam geçiş
anında düşüyordu: *"Transkripsiyon tamamlanamadı — İşlem tamamlanamadı.
(Foundation._GenericObjCError hatası 0.)"* Hiçbir şey loglanmıyordu, hiçbir
segment yazılmıyordu ve toplantı `processing` durumunda takılı kalıyordu.

**Ölçüm.** Aynı WAV `probes/transcribe_stereo.swift` ile sorunsuz çözülüyor
(mic 3 segment, güven 0.50–0.81). Fark, probe'un okuma hatasını yutması.
Adım adım log ile hata `SpeechTranscription.channelPeaks` içine indirgendi:

```
[AYIKLA] Tam geçiş: kanal tepeleri ölçülüyor
[HATA]   Tam geçiş başarısız (tr-TR) — … (Foundation._GenericObjCError hatası 0.) [nilError]
```

`AVAudioFile.read(into:)` dosya sonunda `NO` dönüyor ama `NSError` **kurmuyor**;
Swift köprüsü bunu `_GenericObjCError.nilError` olarak fırlatıyor. `while true`
döngüsü son (kısmi) buffer'dan sonra bir kez daha okuduğu için bu her kayıtta
oluyordu — yani kayıt sonrası tam geçiş gerçek dosyalarda hiç tamamlanmıyordu.

**Kural.** `AVAudioFile` okuma döngüsünün sınırı `framePosition < length` ile
çizilir; okuma yine de hata verirse konum dosya sonundaysa döngü biter,
değilse hata yukarı taşınır (ortadaki gerçek okuma hatası yutulmaz).

**Doğrulama (aynı kayıt, düzeltmeden sonra).**

```
tepeler 0.1075 / 0.0000      → system kanalı sessiz, atlandı
mic kanalı çözüldü — 3 segment
Tam geçiş bitti — 3 segment, tr-TR
Özet hazır — 0 karar, 6 aksiyon, 1 konu     (toplam ~9 sn)
```

**Yan bulgu — sessiz kanal eşiği doğru çalışıyor.** Probe, tepe genliği 0.0000
olan sistem kanalından "Evet" üretmişti; `DictationTranscriber` dijital
sessizlikte uydurma sonuç verebiliyor. Kanal atlama bunu eliyor.

**İki hat kuralı bu vakadan çıktı:**
1. `catch` bloğu kullanıcıya hata gösteriyorsa **loga da yazar** — hata
   görünürken logun sessiz kalması teşhisi imkânsız kılıyordu.
2. `localizedDescription` köprülenmiş Swift hatalarında hiçbir şey söylemez;
   log satırı `String(describing:)` hâlini de taşır (`Log.describe`).

---

## 23. Çıktı yapısı: Circleback referansıyla ölçüm

Kullanıcı ora'nın toplantı çıktılarını beğenmedi ve referans olarak Circleback'i
gösterdi (`circleback-notes/`: 5 gerçek Türkçe çıktı + 2 ekran görüntüsü).
Referansın **ölçülmüş** yapısı:

| Ölçü | Değer |
|---|---|
| Konu bölümü sayısı | 5–7 (18 dk'lık toplantıda da 66 dk'lıkta da) |
| Bölüm başına madde | 2–9 |
| "Genel Bakış" madde sayısı | her zaman 4–6 |
| Aksiyon sayısı | 2–5 |
| Madde uzunluğu | medyan 134 krk · p90 197 |

Aradaki fark üslup değil **yapı**: ora'nın konuları `MM:SS + 2-5 kelime`
başlıktan ibaretti, genel bakış tek paragraftı, aksiyonlarda gerekçe yoktu.

### 23.1 Konu gövdesi zaten üretiliyor ve atılıyordu

Eski hat parça başına **iki** çağrı yapıyordu: serbest metin özet + ayrı başlık.
Başlık `topic_segments`'a yazılıyor, özet metni birleştirmeye girip kayboluyordu.
Tek yapılandırılmış `ParcaOzeti` çağrısı hem gövdeyi kalıcı kılıyor hem de bir
çağrı tasarruf ediyor.

### 23.2 **Parça sınırı yanlıştı — gerçek toplantıda her parça düşüyordu**

En önemli bulgu. §3'teki "4 karakter ≈ 1 token" oranı iyimserdi:
```
gerçek transkript, 10.000 karakterlik parça
→ exceededContextWindowSize: "Content contains 4089 tokens,
   which exceeds the maximum allowed context size of 4096."
ölçülen oran: 2,45 karakter/token   (teknik terim, kesme işareti, yoğun ek)
sonuç: 49.229 karakterlik toplantıda 5 parçanın 5'i de düştü → özet üretilemedi
```
`summaryLimit` 10.000 → **6.000**, `punctuationLimit` 4.000 → **3.500**.
Düzeltmeden sonra aynı girdide **0 atlanan parça**.

### 23.3 Süre — yeni hat daha pahalı

49.229 karakter (60 dk mertebesi), düzeltilmiş sınırlarla:
```
parça      : 9   (6.000 krk sınırı)
map süresi : 95,7 sn     (taban 47,9 sn)
toplam     : 99,3 sn     (taban 55,3 sn)
atlanan    : 0
guardrail  : 0/8
```
Kısa toplantı (3.281 krk, 1 parça): map 9,5 sn · toplam 11,7 sn.

**~1,8× yavaş.** İki nedeni var: parça sınırı yarılandığı için parça sayısı
arttı, ve parça başına üretilen çıktı zenginleşti. Karşılığında 6 çıplak başlık
yerine 9 gövdeli bölüm (38 madde) geliyor. Kayıt sonrası arka plan işi olduğu
için kabul edildi.

### 23.4 Genişletilmiş sistem istemi guardrail'e takılmıyor

Talimat 14 kelimeden üç satıra çıkarıldı ("uydurma", "sayı ve tarihleri koru").
§15.1 yöntemiyle aynı istem 8 kez: **8/8 başarılı · 0 guardrail**.
§15.1'deki guardrail sorunu noktalama istemine ve konuşmacı önekine özgüydü.

### 23.5 **Kapalı isim listesi isteme yazılınca her şeyi bozuyor** (A/B)

Kullanıcı takvim katılımcılarının isteme kapalı liste olarak verilmesini
istemişti. Aynı transkript, tek değişken:

| | roster AÇIK | roster KAPALI |
|---|---|---|
| son tarihe toplantı tarihi sızması | **4/4** | 0/4 |
| bağlam konu başlığını tekrarlıyor | **4/4** | 1/4 |
| görev biçimi | belirsiz isim-fiil ("…çalıştırmak") | doğru emir kipi ("PR'ı gönder") |

Model listeyi bir kısıt değil **menü** gibi kullanıyor; üstelik uzayan istem
onu genel olarak kopyalama moduna itiyor. Attribution da düzelmiyor — iki
koşulda da `kisi` alanı "Katılımcı" geliyor.

**Karar:** liste isteme yazılmaz, yalnızca **doğrulamada** kullanılır
(`resolvedPerson`): "Ben" → kullanıcının adı, "Katılımcı" → "belirtilmedi",
tek eşleşme varsa takvimdeki tam ada genişletilir.

### 23.6 Model, içeriği olmayan alanı istemdeki en yakın metinle doldurur

Tekrarlayan iki sızıntı ve "yapma" demenin işe yaramadığı:

| İstem | Sonuç |
|---|---|
| `"haftaya" gibi ifadeleri bu tarihe göre çöz` | bütün `sonTarih` alanları "Haftaya" |
| `Toplantı tarihini son tarih olarak yazma` | bütün `sonTarih` alanları "3 Eylül 2026" |
| `konu başlığını tekrar etme` | bağlam: "Analiz ekranı konusundan çıktı" |
| `baglam … yoksa boş` | bağlam tek kelime: "Mehmet" |
| `konuşmacı etiketlerini maddeye yazma` | madde: "Ben: Kayıt paylaşımını kontrol ediyorum." |

İstemden **örnek kelimeyi kaldırmak** işe yaradı (tarih yankısı düzeldi).
Kalanlar kodda kesiliyor:

- `validated`: son tarih toplantı tarihini içeriyorsa "belirtilmedi" olur.
- `isEcho`: bağlamın anlamlı kelimelerinin %60'ı **bir konu başlığında ya da
  görevin kendisinde** geçiyorsa düşürülür. Gerçek veride en sık görülen tekrar
  görevin yeniden yazılmasıydı ("…belirlemek." → "…hesaplanması konusu.").
- `withoutSpeakerPrefix`: maddenin başındaki "Ben:" / "Katılımcı:" atılır.
  Yalnızca bilinen etiketler — "Karar: …" gibi meşru bir önek korunur.

**Türkçe'de kelime karşılaştırması gövdelemeden çalışmıyor.** "kazançları" ile
"kazançların" tam kelime olarak eşleşmediği için ilk ölçümde tekrar oranı 0,50'de
kalıp %60 eşiğinin altında kalıyordu; kelimeler **ilk 5 harfe** kırpılınca oran
0,75'e çıkıp yakalanıyor. 8 gerçek örnek üzerinde 8/8 doğru (3 tekrar elendi,
5 gerçek bağlam korundu).

Gerçek bir 29 dakikalık toplantıda doğrulandı: 8 aksiyonun 6'sında tekrar eden
bağlam elendi, kalan 2'si gerçek bilgi taşıyor; konu maddelerinde konuşmacı
etiketi sızıntısı **0**.

### 23.7 Aksiyonlar birleştirme aşamasında çıkarılamaz

İlk tasarımda aksiyonlar konu notlarından çıkarılıyordu. Konu notlarında
konuşmacı bilgisi yok; model roster'dan isim seçip transkriptte olmayan işler
atadı ("Merve Halilzade — BA ve servis katmanlarının ayrılması"), ve durum
bildiren cümleleri aksiyon saydı (8 aksiyon, referans aralığı 2-5).

Aksiyonlar **parça aşamasına** taşındı — orada konuşma sırası ve adlar duruyor.
Birleştirme yalnızca genel bakış ve kararları üretir.

### 23.8 Kalan boşluk — dürüst durum

| | ora | referans |
|---|---|---|
| bölüm sayısı | 4–9 | 5–7 |
| bölüm başına madde | 2–6 | 2–9 |
| madde uzunluğu (medyan) | **~50 krk** | **134 krk** |
| genel bakış | 4–6 madde | 4–6 madde |
| aksiyon sahibi | çoğu zaman "belirtilmedi" | gerçek kişi |

Maddeleri "iki bölümlü" (durum; sonuç) yazmaya zorlamak uzunluğu artırdı ama
**sayıyı düşürdü** (bölüm başına 2'ye, genel bakış 2 maddeye) — geri alındı,
yönerge yalnızca şemada bırakıldı.

Sahip alanının boş kalmasının nedeni **diarization yokluğudur**: kanal ayrımı
"Ben" ve "Katılımcı" verir, uzaktaki 6 kişi tek etikete düşer. Kendinden emin
yanlış bir ad boş bir alandan kötü olduğu için doğrulama katmanı bunu
"belirtilmedi"ye çeviriyor.

*probe:* `probes/ozet_gercek.swift` (+ `probes/gercek_toplanti.txt`)
`ROSTER=0|1` A/B · `SCALE=N` 60 dk mertebesi · `GUARDRAIL=1` 8 koşuluk oran

### 23.9 Gerçek toplantı: "Bordro Fark Çözümü" (29 dk, Teams dökümü)

Sentetik metinle yapılan ayar yanıltıcıydı. Gerçek bir Teams dökümü
(`probes/bordro_toplanti.txt`, 117 replik / 17.418 karakter, iki konuşmacı)
uygulamaya yüklendi (`scripts/seed-transcript.swift`) ve **uygulamanın kendi
hattı** koşturuldu.

```
parça      : 3   ·  bölüm: 6  ·  bölüm başına madde: 3–6
uygulamada uçtan uca (noktalama + özet): ~90 sn
guardrail  : 0   ·  atlanan parça: 0
```
Bölüm sayısı ve madde yoğunluğu referans aralığında. Genel bakış somut sayıları
taşıyor ("%33.030 asgari ücretin %20'si", "SSK primleri %10").

**Bulgu — model olmayan aksiyonu uyduruyor.** Bu toplantı bir ekran paylaşımı
anlatımı; gerçekte neredeyse hiç aksiyon yok. Model yine de doldurdu:

| Aşama | Aksiyon | Kalıp |
|---|---|---|
| tavan 4, kural yok | 12 ham | "…kontrol ediliyor" (durum) |
| şimdiki zaman filtresi | 9 ham | "…belirtti", "…yazdı" (anlatım) |
| belirli geçmiş filtresi | 8 tekil | gerçek görev ("…kontrol edecek") |

Kapalı fiil listesi **yetmedi** ("yazdı", "etti" listede yoktu); ekin kendisi
aranıyor: son kelime `-dı/-di/-du/-dü/-tı/-ti/-tu/-tü` ile bitiyorsa anlatımdır.
`ParcaOzeti.aksiyonlar` tavanı 4 → 3 indirildi; yüksek tavan modeli doldurmaya
itiyor.

**Bulgu — başlık ilk parçadan üretilemiyor, ama konu listesinden de üretilemiyor.**
29 dakikalık bordro mutabakatı ilk 6.000 karaktere bakılarak "Toplam Kazanç ve
Diğer Kazançlar" oluyordu. Konu başlıkları kaynak verilince model **hepsini
birleştirip** geri verdi:
```
"Rapor formatı, Kazanç ayrımı, Vergi Muafiyetleri ve Hataları,
 Bireysel Emeklilik ve Hayat Sigortası, Veri Kalitesi ve Çözümleme
 Zorlukları, Bütçe ve Muafiyet Yönetimi"
```
Çözüm: önce konu başlıklarından denenir, sonuç 7 kelimeyi aşıyor ya da birden
çok virgül içeriyorsa **ilk parçaya düşülür** (`isUsableTitle`). Ayrıca isteme
"konuşmacı etiketlerini başlığa koyma" eklendi — "Katılımcı ile Birlikte
Toplantı Sonuçları" çıkmıştı.

**Koşudan koşuya değişkenlik yüksek.** Aynı girdi, aynı istem, iki koşu: bir
seferinde genel bakış maddeleri somut ve sayı taşıyor, diğerinde genelleşiyor.
3B modelde bu beklenen; tek bir koşuya bakarak istem ayarlamak yanıltıcı.

**`kisi` bu toplantıda hep "belirtilmedi".** Beklenen: kanal ayrımı "Ben" ve
"Katılımcı" veriyor, diarization yok. §23.5'teki karar gereği model roster'dan
isim seçmiyor.

*probe:* `probes/ozet_gercek.swift` · `FILE=bordro_toplanti.txt`
*yükleme:* `swiftc -parse-as-library scripts/seed-transcript.swift -o /tmp/seed`
`&& /tmp/seed probes/bordro_toplanti.json`

---

## 24. İstem dili, son kontrol ve pencere minimumu

### 24.1 Hangi modeller var? "Daha güçlü üst model" yok

`probes/model_envanter.swift` bu makinede:
```
SystemLanguageModel.default         : kullanılabilir
SystemLanguageModel(.contentTagging): kullanılabilir
desteklenen dil: 23  ·  tr-Latn-TR var
```
FoundationModels **tek bir cihaz üstü model** sunuyor. `.contentTagging` daha
büyük bir model değil, aynı modelin sınıflandırma/etiketleme için ayarlanmış
kullanım biçimi — özetleme için bir üst basamak değil. Apple'ın büyük modeli
sunucu tarafında (Private Cloud Compute) ve bu çerçeveden üçüncü taraf
uygulamalara **açılmıyor**; açılsaydı bile CLAUDE.md kural #3 gereği kullanılamazdı.

**Tek gerçek kaldıraç `SystemLanguageModel.Adapter`.** API mevcut
(`Adapter(fileURL:)` + `SystemLanguageModel(adapter:)`, derlenerek doğrulandı):
Apple'ın adapter eğitim araç setiyle eğitilmiş bir LoRA katmanı modele takılıyor,
her şey cihazda kalıyor. Türkçe toplantı notu için eğitilmiş bir adapter, istem
mühendisliğinin üstünde kalan tek yol. Maliyeti eğitim verisi ve eğitim
altyapısı; çalışma zamanı maliyeti aynı modelinki.

### 24.2 **İngilizce istem, Türkçe çıktı ölçülür biçimde daha iyi**

Aynı transkript, üçer koşu, tek değişken istem dili:

| Ölçü | Türkçe istem | İngilizce istem |
|---|---|---|
| madde uzunluğu (medyan) | 63 · 69 · 47 → **60** | 65 · 70 · 75 → **70** |
| çıkarılan karar | 4 · 4 · 2 → **3,3** | 5 · 6 · 6 → **5,7** |
| çıkarılan aksiyon | 3 · 2 · 3 → **2,7** | 3 · 4 · 4 → **3,7** |
| genel bakış ↔ karar tekrarı | 1 · 3 · 1 → **1,7** | 0 · 0 · 2 → **0,7** |
| bölüm sayısı | 4 | 4 |
| süre | ~12,1 sn | ~12,5 sn |
| guardrail | 8/8 | 8/8 |

Model İngilizce ağırlıklı eğitilmiş; yönergeyi İngilizce vermek takibi
artırıyor, çıktı dili ayrı bir cümleyle sabitleniyor ve **çıktı tamamen
Türkçe kalıyor**. Örneklem küçük (3'er koşu) ama beş ölçütün beşi de aynı yöne
işaret ediyor. Uygulamadaki tüm istemler İngilizce'ye çevrildi.

*probe:* `probes/ozet_gercek.swift`, `PROMPT_LANG=en`

### 24.3 Son kontrol: dilbilgisi düzeltme adımı

Model Türkçe'de sık sık hâl eki tutturamıyor ("Analiz akışı**nı** uçtan uca
çalıştırıl**dı**"). Özet üretildikten sonra bütün cümleler numaralı satır
protokolüyle (noktalama adımından devralındı) tek geçişte düzeltiliyor.

Noktalamadaki "kelimeler aynı kalmalı" güvencesi burada kullanılamaz —
dilbilgisi düzeltmesi zaten kelime değiştirir. Yerine **olgu koruma**:
sayılar ve cümle başında olmayan büyük harfli kelimeler (özel isimler)
düzeltilmiş satırda da bulunmalı; uzunluk yarıdan aza inmiş ya da iki katına
çıkmışsa düzeltme değil yeniden yazımdır, reddedilir. Satır sayısı tutmazsa
parça bütünüyle reddedilir. Başarısızlık zararsız: satır olduğu gibi kalır.

Maliyet: 29 dakikalık toplantıda tek ek geçiş, ilerlemenin son %15'i.

### 24.4 Konuşmacı etiketi üç ayrı biçimde sızıyor

§23.6'daki desenin devamı. İstem "etiket yazma" diyor, model üç biçim deniyor:

| Biçim | Örnek |
|---|---|
| iki nokta | `Ben: Kayıt paylaşımını kontrol ediyorum.` |
| virgül (özne) | `Katılımcı, toplam kazancı analiz etti.` |
| ayraçsız (özne) | `Ben kazançların toplamı üzerinde çalışıyor.` |

Üçü de `withoutSpeakerPrefix` ile kesiliyor; yalnızca tam eşleşen bilinen
etiketler (`Ben`, `Katılımcı`, `Belirtilmedi`) — "Katılımcılar" gibi gerçek bir
özne ve "Karar: …" gibi meşru bir önek korunuyor. Ayrıca isteme **üçüncü şahıs**
kuralı eklendi; birinci şahıs sızıntısı ölçümde 0'a indi.

### 24.5 Pencere minimumu sohbet panelini saymıyordu

`NavigationSplitView` + `.inspector` birlikte sığmadığında SwiftUI sütunları
daraltmıyor, **kenar çubuğunu pencerenin dışına taşıyıp kırpıyor**. 900 pt
minimum yalnızca kenar çubuğu + orta paneli sayıyordu; sohbet açılınca üçüncü
sütun için yer kalmıyordu.

Düzeltme iki parçalı: minimum `RootView`'da sohbet paneline göre **değişken**
bildiriliyor ve `Window` sahnesine `.windowResizability(.contentMinSize)` eklendi
— bu olmadan bildirilen minimum sert sınır olmuyor.

**Düzeltme (Faz 8 tasarım turu): bildirilen 1180 yetmiyordu.** İlk değer
`minWidth + inspectorMinWidth` (900 + 280) diye *hesaplanmıştı*; ölçülmedi.
Panel bildirilen minimumla değil kendi **ideal** genişliğiyle yerleştiği için
gerçek gereksinim daha büyük. Pencere genişliği taranarak kenar çubuğu kartının
sol kenarı ölçüldü (tam yerleşimde 24 pt; kırpılmada 0):

| Genişlik | 1180 | 1200 | 1215 | 1230 | 1240 | 1250 | **1255** | 1300 |
|---|---|---|---|---|---|---|---|---|
| Kart sol kenarı | 0 | 0 | 4,5 | 12 | 17 | 22 | **24** | 24 |

Sohbet **kapalıyken** 900 pt'de kart 24 pt'de duruyor, yani sorun orta panelde
değil panelin kendisinde. Minimum 1260'a çekildi (ölçülen 1255 + pay) ve panelin
ideali 320'den 300'e indirildi. Doğrulandı: 1000 pt genişlikteki pencere sohbet
açılınca kendiliğinden 1260'a büyüyor ve kenar çubuğu tam görünüyor.

**Ders:** üç sütunlu yerleşimde minimum genişlik hesaplanmaz, ölçülür.

> Bu yaklaşım (pencereyi büyütmek) **§26'da bırakıldı**: panel artık üçüncü bir
> sütun değil, orta panelin içinde bir bölme. Ölçümler kayıtta duruyor çünkü
> `.inspector`'ın davranışını gösteriyorlar.

---

## 25. Faz 8 ölçümleri — oynatıcı, alıntı bağı, depolama

Faz 8'in kaynağı **COMPETITION.md**: rakip incelemesinde ora'da hiç olmayan ama
elimizdeki veriyle yapılabilen işler. Bu bölüm o işlerin ölçümlerini tutar.

### 25.1 Oynatıcı: kanal yalıtımı, grafik ve hızlı oynatmada konum

`probes/playback.swift` (manuel render modu — ölçüm sessiz, ses çıkışına gitmez),
`probes/kayit.wav` üzerinde (31,8 sn · 16 kHz · 2 kanal · ayrık float32):

```
— 1. Kanal yalıtımı —
kaynak RMS  ch0(mic) 0.00208  ch1(system) 0.00000
mic:    iki düzlem aynı ✓, kaynak kanal korunmuş ✓, RMS 0.00208
system: iki düzlem aynı ✓, kaynak kanal korunmuş ✓, RMS 0.00000

— 2. Grafik akıyor mu (1 sn render, 10. saniyeden) —
mix:    çıkış RMS 0.00228, kaynak 0.00208 ✓
mic:    çıkış RMS 0.00228, kaynak 0.00208 ✓
system: çıkış RMS 0.00000, kaynak 0.00000 ✓

— 3. Hız değişince konum hesabı —
hız 1,0×: render 16000, playerTime 16896 kaynak frame, ileri kaçak  56 ms ✓
hız 1,5×: render 16000, playerTime 25088 kaynak frame, ileri kaçak  68 ms ✓
hız 2,0×: render 16000, playerTime 35072 kaynak frame, ileri kaçak 192 ms ✓
```

Üç sonuç:

1. **Kanal yalıtımı `memcpy` ile birebir.** Seçilen kanal diğer düzleme
   kopyalanıyor; `AVAudioFile.processingFormat` her zaman ayrık float32 olduğu
   için düzlemler doğrudan kopyalanabiliyor. Yalıtım pan/balans ile
   yapılmıyor — pan tek kulakta ses bırakırdı.
2. **Sistem kanalının sessiz çıkması test verisinin kendisi**: bu kayıtta ch1
   10. saniyede gerçekten sessiz (kaynak RMS 0.00000). Probe sabit eşikle değil
   **kaynakla** karşılaştırdığı için bunu hata saymıyor.
3. **`playerTime.sampleTime` kaynak frame'lerini sayıyor.** Hız 1,5× ve 2,0×'te
   oran hıza uyuyor; aradaki fark oransal değil **sabit** (56–192 ms), ve bu
   `AVAudioUnitTimePitch`'in kendi tamponunun ileriden okumasıdır. Yani konum
   göstergesi duyulandan en fazla ~0,2 sn ileride; segment vurgusu için (segmentler
   saniyeler uzunluğunda) fazlasıyla yeterli. Konum hesabı için ayrı bir duvar
   saati sayacı yazmaya gerek yok.

**Kanal seçici sonradan kaldırıldı** (kullanıcı kararı, Faz 8 tasarım turu):
dinlerken yapılan iş kaydı gözden geçirmek, kanal ayıklamak değil. Oynatma
karışımdır. Yukarıdaki 1. ve 2. ölçüm, yalıtım geri istenirse tekrar
koşturulabilsin diye kayıtta bırakıldı; `probes/playback.swift` `isolate()`
işlevini kendi içinde taşır.

**Akış hâlinde okuma:** oynatıcı dosyayı 8.192 frame'lik (0,5 sn) parçalarla
okur ve üç parça ileri besler. Kural #12 yazma tarafı için yazılmıştı; okuma
tarafında da geçerli — bir saatlik kayıt 230 MB'tır, `AVAudioPlayer`'ın dosyayı
tümüyle açması kabul edilemez.

### 25.2 Alıntı bağı: madde → transkript eşleştirmesi

Özet maddesine tıklayınca transkriptte geçtiği yere gitmek için maddenin
kaynağını bulmak gerekiyor. Zaman damgası **modelden istenmiyor** (uydurur);
maddenin metni transkriptle eşleştiriliyor. `probes/alinti.swift` gerçek
veritabanı üzerinde koşuyor (2 toplantı, 131 segment, 42 madde).

**İlk ölçüt — düz kelime örtüşmesi (eşleşen kelime / madde kelimesi ≥ 0,5):**
```
24/42 madde bağlandı (%57)
✓ aksiyon · skor 0.50 → 00:36
   madde: Toplum ve kazanç analizi yapmak
   satır: Yok, bu da kendince şey aşağıda da özetleri falan filan vardı…
```
Sorun: "yapmak", "olarak", "analiz" gibi her yerde geçen kelimeler kanıt
sayılıyor. Dört kelimelik bir maddede ikisinin tutması %50 ediyor ve madde
alakasız bir satıra bağlanabiliyor.

**İkinci ölçüt — IDF ağırlıklı örtüşme:** bir kelime kaç segmentte geçiyorsa o
kadar değersiz (`log(N / (1 + df))`). Türkçe için ayrı bir stopword listesi
yazmaya gerek kalmıyor; sıklık zaten eliyor.
```
eşik taraması (toplantı 1) — 0.3: 24/24  0.4: 23/24  0.5: 21/24  0.6: 16/24  0.7: 12/24
eşik taraması (toplantı 2) — 0.3: 15/18  0.4: 15/18  0.5: 15/18  0.6: 14/18  0.7: 10/18

36/42 madde bağlandı (%86)
✓ aksiyon · skor 1.00 → 00:14   madde: Borç programları farklılığını analiz etmek
   kanıt: progr(2.8) farkl(2.8)
✓ aksiyon · skor 0.57 → 00:36   madde: Toplum ve kazanç analizi yapmak
   kanıt: toplu(3.2) kazan(2.3)
✓ genel bakış · skor 0.79 → 00:14
   kanıt: forma(3.7) kulla(3.7) progr(2.8) farkl(2.8) rapor(2.8)
```
Eşleşmeler artık **ayırt edici** kelimelerle taşınıyor; parantez içindeki sayı
kelimenin ağırlığı. Eşik **0,5** seçildi: 0,6 gerçek eşleşmeleri de eliyor,
0,4 zayıf kanıtla atlıyor. Madde en az 3 (gövdelenmiş) kelime taşımalı.

Eşiğin altında kalan madde **tıklanabilir olmuyor** — arayüzde ok/dalga simgesi
belirmiyor. Yanlış bir yere atlamak, hiç atlamamaktan kötüdür.

Kelime normalleştirme `FoundationIntelligence.words(of:)` ile ortak: Türkçe
küçük harf, diakritik düşürme, ilk 5 harf (kaba gövdeleme). Ekler yüzünden
kaçan eşleşmeleri ("kazanç" ~ "kazancım") bu kurtarıyor.

### 25.3 Ses sıkıştırma: 11,5× kazanç, kanal ayrımı bozulmuyor

Ses saklamak bugüne kadar yönetilmiyordu: 16 kHz · 16 bit · stereo WAV saatte
~230 MB, haftada 10 saat toplantı ayda ~9 GB. `AVAssetExportSession`
(`AVAssetExportPresetAppleM4A`) ile ölçüm, `probes/kayit.wav` (31,8 sn):

```
wav 1989 KB → m4a 173 KB · oran 11,5× · 0,09 sn
okunabilir: 2 kanal, 16000 Hz, 509371 frame (31,8 sn)
```

**Asıl risk kanal ayrımıydı**: AAC ortak stereo (joint stereo) kodlaması mikrofon
kanalını sistem kanalına sızdırırsa hem "yalnız karşı tarafı dinle" bozulur hem de
yeniden işlemede sessiz kanal atlama mantığı (tepe < 0,005) yanılır. Ölçüldü:

```
wav  tepe: ch0 0.21274  ch1 0.00000
m4a  tepe: ch0 0.21224  ch1 0.00003
```

Sızıntı 0,00003 — eşiğin iki kat büyüklük altında. Kanal ayrımı korunuyor.

Yine de sıkıştırma **kayıp verendir** ve varsayılan **kapalıdır**; yalnızca
transkripsiyon ve özet bittikten sonra çalışır. Saklama süresi (varsayılan
süresiz) dolduğunda **yalnızca ses** silinir; transkript, özet ve aksiyonlar
kalır.


---

## 26. Faz 8 tasarım turu — kenar çubuğu geometrisi ve sohbet paneli

Ekran görüntüsünden göz kararı ayar yapmak yerine pikseller ölçüldü:
`probes` dışında kalan tek seferlik betikler ekran görüntüsünde carmine kartın
sol/sağ kenarını ve bölüm başlığının sol kenarını okur.

### 26.1 Kenar çubuğu kartının girintisi

`listRowInsets(leading: 0)` bırakıldığında kart pencerenin solundan **24 pt**
içeride başlıyordu; sağda ise yalnızca 7 pt boşluk vardı — asimetrik ve fazla.
Listenin `.sidebar` biçimi kendi başlık/satır girintisini uyguluyor ve
`listRowInsets` bunu **azaltmıyor**, ancak negatif değer veriliyorsa çekiyor:

| leading | kart sol kenarı | kart metni | bölüm başlığı |
|---|---|---|---|
| 0    | 24 pt | 32 pt | 31 pt |
| −12  | 12 pt | 21 pt | 31 pt |
| −16  | **9 pt** | **17 pt** | 16 pt (başlık −7 pt ile) |

Son değerler: `leading: -14`, `trailing: -5`, kart iç boşluğu 8 pt → kartın
solunda **10,5 pt**, sağında **10,0 pt** boşluk. Bölüm başlığı (`BUGÜN`) kartın
**metniyle** hizalı dursun diye `-4 pt` ile kaydırılıyor.

**Ölçüm yöntemi (önemli):** renk eşiğiyle "kenar" arayan betikler iki kez
yanılttı — biri kartın yuvarlak köşesini, diğeri yarı saydam kenar çubuğunun
başka bir geçişini kenar sandı. Güvenilir yol: ekran görüntüsünün ham piksel
boyutunu al (1100 pt'lik pencere → 2200 px, yani 2 px/pt) ve kartın **düz**
satırındaki ilk/son carmine pikseli oku:
```
kart 21…472 px · kenar çubuğu sınırı 492 px
→ sol 10,5 pt · sağ 10,0 pt
```

**Sütun genişliği de ölçümle bulundu.** `navigationSplitViewColumnWidth`'in
`ideal` değeri **uygulanmıyor**: macOS kenar çubuğu genişliğini
`NSSplitView Subview Frames …` anahtarında saklıyor ve onu tercih ediyor
(bu makinede 268 pt). Genişliği gerçekten değiştiren `max` — 240'a çekilince
sütun 268 → ~246 pt'ye indi. Kayıtlı değeri silmek gerekiyorsa:
`defaults delete <bundle> "NSSplitView Subview Frames main, SidebarNavigationSplitView"`.

**Ders:** pikselleri renk eşiğiyle ölçen betikler yanıltabiliyor — kenar
çubuğu yarı saydam olduğu için "kenar" sandığım sütun aslında başka bir
geçişti. Kesin sonuç, kırpılmış ekran görüntüsüne büyütüp **bakmakla** alındı.

### 26.3 Dar pencerede başlık şeridi

Sohbet açıkken orta panel ~390 pt'ye inebiliyor. O genişlikte:
- tarih/süre çipleri harf harf alt alta iniyordu (sıkıştırılabilir `Text`),
- başlık "Üçünc…" diye kesiliyordu, çünkü sabit 190 pt'lik segment sekme
  şeridin yarısını yiyordu.

Düzeltme:
- Çipler `fixedSize` + `ViewThatFits`: sığmazsa önce süre, sonra durum çipi
  düşer; kalan çip **hiç ezilmez**.
- Sekme şeridi `onGeometryChange` ile ölçülen genişliğe göre biçim değiştirir:
  520 pt'nin altında etiket yerine simge (165 pt → ~70 pt). Sistem `Picker`'ı
  `Label`'ı simgeye indirmiyor (`.labelStyle(.iconOnly)` etiketi yine
  çiziyor), bu yüzden dar hâl elle çizilen iki düğmedir.

Sonuç: aynı 390 pt'lik şeritte başlık "Üçünc…" yerine
"Üçüncü Taraf Ücretlendir…" gösteriyor ve iki çip de okunuyor.

### 26.2 Sohbet paneli: `.inspector` yerine orta panelin içinde bölme

`.inspector` üçüncü bir sütun açıyor. Ölçüldü: orta sütun **~655 pt**'nin
altına inmiyor, dolayısıyla panel açıldığında SwiftUI fazlalığı kenar çubuğunu
**ve** paneli pencerenin dışına iterek çözüyor; ikisi birden kırpılıyor.
Orta panele `.frame(minWidth: 420)` vermek bunu **düzeltmiyor** — frame yalnızca
alt sınırı yükseltir, sütunun kendi alt sınırını düşürmez.

Çözüm, Notlar uygulamasının yaptığı: panel ayrı bir sütun değil, orta panelin
içinde sabit genişlikte (320 pt) bir bölme. Açılınca **pencere büyümez, okuma
alanı daralır**.

Kalan tek sınır dar pencerede: 900 pt'de kenar çubuğu yine kırpılıyor.
Genişlik taranarak eşik ölçüldü (kart sol kenarı, tam yerleşim 9 pt):

| Genişlik | 905 | 915 | 925 | **940** | 980 | 1020 |
|---|---|---|---|---|---|---|
| Kart sol kenarı | 0 | 0 | 4 | **9** | 9 | 9 |

Sohbet açıkken pencere minimumu 940 pt. Yani pencere yalnızca **en dar hâlde**
40 pt büyüyor; 940 ve üstündeki her genişlikte hiç değişmiyor. Eski çözümde
(üçüncü sütun) bu sıçrama 900 → 1260 idi.

## 27. Toplantı geçişi: işlem durumu toplantıya değil, uygulamaya bağlıydı

Kullanıcı gözlemi: bir toplantı özetlenirken kenar çubuğundan başka bir
toplantıya geçilince **animasyon oraya taşınıyor**; asıl işlenen toplantıya
dönülünce animasyon **yok**; bir kez daha gidip gelince düzeliyor.

**Ölçüm.** `probes/meeting_switch.swift` gerçek `RecordingController` ve gerçek
`MeetingStore` (bellek içi SQLite) ile koşar; yalnızca `Intelligent` sahtedir
(yavaş, ilerleme bildiren). İki toplantı hazırlanır: A'nın transkripti vardır,
B'nin transkripti **ve kendi özeti** vardır. A özetlenirken B'ye geçilir,
sonra A'ya dönülür.

| Kontrol | Düzeltme öncesi | Sonrası |
|---|---|---|
| B'ye geçince B'nin aşaması `.idle` | ✗ (`.done`, sonra A'nın yüzdesi) | ✓ |
| B'ye geçince hat hâlâ "koşuyor" görünüyor | ✗ (`isTranscribing` **false**) | ✓ |
| A'ya dönünce animasyon **hemen** var | ✗ | ✓ |
| B'nin ekranı A'nın özetiyle ezilmiyor | ✗ | ✓ |
| A'nın özeti A'nın metninden üretiliyor | ✓ | ✓ |

**Sebep tek:** `transcriptionStage` uygulama genelinde **tek** bir değerdi ve
hattın ürettiği içerik (`transcript`, `summary`, `topics`, `actions`,
`audioURL`, `retryableAudio`) doğrudan yayınlanan duruma yazılıyordu. İki yönlü
bozuluyordu:

1. Hattın ilerleme bildirimi, seçim ne olursa olsun tek aşamayı güncelliyordu →
   animasyon B'ye taşınıyor, biten özet B'nin ekranına düşüyordu.
2. `load(_:)` aşamayı **veritabanının yarım hâlinden** türetiyordu
   (`segments.isEmpty ? .idle : .done`). Tam geçiş segmentleri çoktan yazdığı
   için işlenen toplantıya dönüldüğünde `.done` çıkıyor, animasyon kayboluyordu.
   Bu sırada `isTranscribing` de false olduğu için menü bar "işleniyor"
   demeyi bırakıyor ve düzeltme/elle özetleme kapıları hat koşarken açılıyordu.
   Bir sonraki ilerleme bildirimi aşamayı geri kuruyordu — "gidip gelince
   düzeliyor" tam olarak buydu. Sahte modelin bildirim aralığı 120 ms'ye
   düşürüldüğünde bu adım **geçiyor**: hatayı görünür kılan, gerçek hattaki
   saniyelik boşluk.

**Çözüm.** Aşama toplantı başına tutulur (`stages: [Int64: Stage]`), hattın
ürettiği içerik arayüze yalnızca o toplantı ekrandayken yazılır
(`onScreen(_:)`), veritabanına ise her hâlükârda yazılır. `load(_:)` aşamaya
hiç dokunmaz. Arayüz `isProcessingSelected`'e bakar (seçili toplantının
aşaması), yetki kapıları `isTranscribing`'e (herhangi bir toplantı işleniyor mu).

**Aynı kökten çıkan üç sessiz hata da kapandı:**
- Özetleme, yayınlanan `transcript` ile çağrılıyordu; başka toplantıya
  geçildiğinde A'nın özeti **B'nin metninden** üretilirdi. Artık hat kendi
  yerel metnini taşır. Toplantı tarihi ve katılımcı listesi de işlenen
  toplantıdan okunur (seçili olandan değil) — son tarihler yanlış güne
  bağlanıyordu.
- `compressAudioIfNeeded` sıkıştırılacak dosyayı `audioURL`'den (seçili
  toplantının sesi) alıyordu; artık işlenen toplantının kaydından alır.
- Hata dalında `retryableAudio` seçili toplantıya iliştiriliyordu: "Yeniden
  dene" düğmesi başka bir toplantının sesini işleyebilirdi.

Ek olarak: özetleme başarısız olduğunda artık `saveSummary` **çağrılmaz**.
Eskiden yeniden üretim denemesi başarısız olsa bile satır silinip yeniden
yazılıyordu; işaretlenmiş aksiyonların durumu böyle kayboluyordu.

## 28. Algılama→bildirim zinciri neden hiç çalışmadı

Kullanıcı bir Teams toplantısı başlattı, kayıt önerisi gelmedi. Zincirin iki
halkası da kopuktu; ikisi de ölçüldü.

### 28.1 Ad-hoc imzalı uygulama bildirim izni **alamıyor**

Uygulama günlüğünde her açılışta, istisnasız:
```
[UYARI] [ui] Bildirim izni alınamadı: Notifications are not allowed for this application
```
`defaults read com.apple.ncprefs` içinde `com.orameetings.ora` için **hiç kayıt
yok** — sistem uygulamayı bildirim gönderebilecek bir uygulama olarak hiç
tanımamış.

Bunun ora'ya özel bir hata olmadığını doğrulamak için sıfırdan, daha önce hiç
görülmemiş bir bundle ID ile minik bir `.app` yazıldı, **ad-hoc** imzalandı ve
`requestAuthorization` çağrıldı:

| Nasıl çalıştırıldı | Sonuç |
|---|---|
| Doğrudan çalıştırılabilir | `HATA — Notifications are not allowed for this application` |
| `open` ile (LaunchServices) | `HATA — Notifications are not allowed for this application` |

Yani sebep kod değil, **imza**: `Signature=adhoc`, `TeamIdentifier=not set`.
Bu, §20 (her derlemede TCC istemi, yer tutucu Dock ikonu) ve §21 (kendinden
imzalı sertifika Gatekeeper'ı geçmiyor) ile aynı kökten üçüncü sonuçtur ve
çözümü de aynıdır: Apple Developer Program üyeliği.

**Koda yansıyanlar:** bildirim izni yoksa ora artık sessiz kalmıyor —
Ayarlar → Algılama bölümünde Türkçe not ve "Bildirim ayarlarını aç" düğmesi
görünür, öneri penceredeki şeritte sunulur (§17.2'nin vaadi buydu). Bildirim
kategorileri izinden bağımsız kaydedilir ve izin sonradan verilirse
`refresh()` ile görülür; yeniden başlatma gerekmez.

### 28.2 Öneri hiç üretilmedi: Electron yardımcı süreci

Günlüğün tamamında (5 günlük, 92 KB) tek bir `Toplantı önerisi:` satırı yok.
Algılama açılıyor ("38 süreç izleniyor") ama aday hiç oluşmuyor.

En olası sebep §13.3'te tarayıcılar için ölçülüp Electron uygulamaları için
"ölçülmedi" notuyla bırakılan bulgu: **mikrofonu ana süreç değil yardımcı süreç
tutuyor.** Algılama `MeetingApps.all.contains(bundleID)` ile **tam eşitlik**
aradığı için `com.microsoft.teams2.helper` hiçbir zaman toplantı sayılmaz.

`MeetingApps.resolve(_:)` eklendi: gözlenen kimlik bilinen uygulamaya eşitse ya
da **`bilinen + "."`** ile başlıyorsa o uygulamaya çözülür. Nokta sınırı şart —
`com.microsoft.teams2`, `com.microsoft.teams` kuralına takılmamalı. CLAUDE.md'deki
"alt-dize eşleşmesi kullanma" kuralının gerekçesi *"uygulama açık mı"* testiydi;
buradaki test *"mikrofonu tutuyor mu"* olduğu için yardımcı sürecin sayılması
doğru davranıştır.

**Kesinleştirmek için:** `probes/mikrofon_sahibi.swift` canlı bir toplantıda
mikrofonu tutan bundle ID'yi yazdırır ve tam eşitliğin tutup tutmadığını söyler.

### 28.3 Teams'te mikrofonu **ve sesi** yardımcı süreç tutuyor (ölçüldü)

Canlı bir Teams toplantısında `probes/mikrofon_sahibi.swift`:
```
com.microsoft.teams2.helper       mikrofon:hayır çıkış:EVET
com.microsoft.teams2.modulehost   mikrofon:EVET  çıkış:EVET
```
`com.microsoft.teams2` listede **hiç yok**. §13.3'te tarayıcılar için ölçülen
bulgu Electron tabanlı Teams için de geçerli; oradaki "ölçülmedi" notu kapandı.

Bunun **iki** sonucu vardı:

1. **Algılama hiç çalışmıyordu** — tam bundle ID eşitliği arayan kural
   `com.microsoft.teams2.modulehost`'u tanımıyordu (§28.2).
2. **Tap sessizlik yakalıyordu.** `probes/tap_hedefi.swift` ile aynı anda,
   aynı ses kaynağıyla iki hedef karşılaştırıldı (Chrome, çünkü Teams o an
   sessizdi — mekanizma aynı):

| Tap hedefi | frame | tepe genlik |
|---|---|---|
| `com.google.Chrome` (ana süreç) | **0** | 0.0 |
| `com.google.Chrome.helper` (yardımcı) | **287.232** | **0,99** |

Yani `CATapDescription.bundleIDs` yardımcı süreç kimliklerini **kabul ediyor ve
eşleştiriyor**; ana bundle ID ise tek bir frame bile vermiyor. Teams kaydında
sistem kanalı ancak 3 saniyelik gözcü global tap'e düştükten sonra ses
görüyordu — yani "yalnızca toplantı uygulamasını yakala, Spotify'ı alma"
kazancı Teams'te **hiç gerçekleşmiyordu** ve ilk 3 saniye kayıptı.

**Çözüm:** `MeetingApps.tapTargets(preferring:)` hedefleri `NSWorkspace`'ten
değil CoreAudio süreç listesinden toplar; uygulamanın yardımcı süreçleri de
listeye girer. Teams için üretilen hedef:
```
["com.microsoft.teams2", "com.microsoft.teams2.helper",
 "com.microsoft.teams2.modulehost", "com.microsoft.teams2.notificationcenter"]
```
Ana uygulama da listede kalır: yardımcı süreç toplantı başlarken doğabilir.
Gözcü yerinde duruyor ama artık normal yol değil, emniyet kemeri.

**Yan bulgu:** yardımcı süreç hedeflemesi çalıştığına göre tarayıcı toplantıları
da kapsamlı tap'e alınabilir (`com.google.Chrome.helper`). Kural şimdilik
değişmedi: tarayıcı yardımcı süreci **tüm sekmelere** hizmet ediyor, yani
"yalnızca toplantı" garantisi vermiyor — global tap'ten iyi ama yerel
uygulamalardaki kadar temiz değil.

### 28.4 Boş sistem kanalı: teşhis edilebilir olmalı

Düzeltmeden sonraki ilk gerçek kayıt (2 dk, Teams): algılama çalıştı
(`Toplantı önerisi: Microsoft Teams`), tap doğru kapsamla açıldı
(`yalnızca com.microsoft.teams2, …helper, …modulehost, …notificationcenter`),
gözcü devreye girmedi — ama sistem kanalı **tam sıfır** çıktı:

```
ch0 mic    tepe 0.7872   sesli saniye 124/124
ch1 sistem tepe 0.0000   sesli saniye   0/124
```

Bu iki şeyden biri olabilir ve **kayıt sonrası ayırt edilemiyordu**: (a) karşı
taraf hiç konuşmadı, (b) tap yanlış yere bağlandı. Kontrol edilerek ölçüldü —
Teams açık ama toplantıda değilken kapsamlı tap kurulup başka bir süreç
(`afplay`) ses çalarken:

| Kapsam | frame | tepe |
|---|---|---|
| Teams (+yardımcıları), Teams sessiz | **0** | 0,0 |
| global (kendimiz hariç) | 66.384 | **0,41** |

Yani hedef uygulama ses üretmiyorken tap **hiç frame vermiyor**; sessiz frame
üretmiyor. Kayıtta gözcü tetiklenmediğine göre tap frame alıyordu → sistem
kanalı, karşı taraf konuşmadığı için boştu (a).

**Koda yansıyanlar:**
- Kayıt sonunda tap'in kapsamı, frame sayısı ve **tepe genliği** günlüğe yazılır.
  Aynı soru bir daha tahminle tartışılmasın.
- Gözcünün ölçütü **frame olarak kaldı, genliğe çevrilmedi.** Genlik cazipti ama
  yanlış: toplantıda kimse konuşmuyorken hedef uygulama sessizdir, tap ise
  doğru bağlıdır — genliğe bakan gözcü o anda kapsamlı tap'i bırakıp global'e
  düşer ve "yalnızca toplantıyı yakala" kazancını sessizce çöpe atardı.
- Global tap'te 12 saniye boyunca hiç frame gelmezken sistemde ses varsa bu
  gerçek arızadır; artık kullanıcıya kayıt sürerken söylenir
  ("Sistem sesi yakalanamıyor — kayıt yalnızca mikrofonunuzla sürüyor").

### 28.5 Uçtan uca doğrulama: Teams test aramasıyla dolu sistem kanalı

Teams'in kendi test araması (sesinizi geri çalar) ile 28 saniyelik kayıt.
Zincirin tamamı ilk kez gerçek bir toplantı sesinde koştu:

```
12:15:53 Toplantı önerisi: Microsoft Teams (güven normal)
12:15:59 Sistem sesi tap'i açıldı — kapsam: yalnızca com.microsoft.teams2,
         …helper, …modulehost, …notificationcenter
12:16:26 Kayıt bitti — 15.wav, 28.0 sn
12:16:26 Sistem sesi tap'i — 433.317 frame, tepe 0.6880
12:16:28 mic kanalı çözüldü — 2 segment / system kanalı çözüldü — 1 segment
12:16:41 Özet hazır
12:16:53 Microsoft Teams mikrofonu bıraktı — öneri soğuması sıfırlandı
```

Kanal ayrımı doğru:

| | tepe | sesli saniye |
|---|---|---|
| ch0 mikrofon | 0,9008 | 28/29 |
| ch1 sistem | 0,6879 | 22/29 |

Transkript ayrımı da doğru: canlı konuşma `mic` kanalında **Ben**, test
aramasının geri çaldığı ses `system` kanalında **Katılımcı** olarak çözüldü.
`Kapsamlı tap ses vermiyor` satırı **yok** — yani ses global tap'ten değil,
yalnızca Teams'i hedefleyen kapsamlı tap'ten geldi. §28.3'teki düzeltmenin
gerçek kanıtı budur; §28.2'nin algılama düzeltmesi de aynı koşuda çalıştı.

## 29. Çakışan takvim toplantısı: doğru olanı seçmek

Kullanıcı gözlemi: aynı saatte iki toplantı varsa ora yanlış olanın katılımcı
listesini kaydediyor. Sebep tekti — `event(overlapping:)` başlangıca göre
sıralı listeden `.first` alıyordu, yani çakışmada **her zaman erken başlayan**
kazanıyordu. İptal edilmiş ve kullanıcının reddettiği etkinlikler de aday
havuzundaydı.

### 29.1 Bulut tarafında karşılığı yok

Microsoft Graph presence API yalnızca `InAMeeting` döndürüyor — *bir*
toplantıdasın, hangisi olduğu yok. Bir toplantıyı Graph'ta bulmak için
`joinWebUrl` ya da `VideoTeleconferenceId` gerekiyor; yani cevabı girdi olarak
istiyor. Katılım raporu (`attendanceReports`) organizatöre ve **toplantı
bittikten sonra** açık. Teams'in yerel API'si (`ws://localhost:8124`) yalnızca
boolean durum veriyor (`isInMeeting`, `isMuted`…), toplantı kimliği yok.
Yani bu soruyu bulut da, Teams'in kendi API'si de cevaplamıyor.

### 29.2 Pencere başlığı toplantının adını taşıyor

Ölçüldü (canlı Teams toplantısı, `System Events` üzerinden):
```
Eren AYDIN ile toplantı | Microsoft Teams, Calendar | Microsoft Teams
```
Aynı başlık Erişilebilirlik (AX) ve `CGWindowList` ile de okunuyor. **Ama
sandbox'lı uygulamada AX çalışmıyor:** Apple erişilebilirlik API'sini sandbox'ta
başka süreçler için kapatıyor, izin istemi hiç çıkmıyor ve `AXIsProcessTrusted()`
her zaman `false`. Üç seçenek var: sandbox'tan çıkıp AX; sandbox'ta kalıp
Apple Events geçici istisnasıyla System Events; sandbox'ta kalıp **ekran kaydı**
izniyle `CGWindowList` (tap mimarisiyle kaçındığımız izin). Karar verilmedi;
kod başlık okunamadığında sinyalsiz çalışacak biçimde yazıldı.

### 29.3 Puanlama ve "bilmiyorsan sor"

`CalendarReader.candidates(at:app:windowTitles:)` adayları eler ve puanlar:

| Sinyal | Puan |
|---|---|
| Pencere başlığı etkinlik adıyla eşleşiyor | +6 |
| Toplantı linki mikrofonu tutan uygulamayla aynı | +3 |
| Mikrofon, etkinlik başlangıcının 5 dk içinde açıldı | +3 (15 dk: +1) |
| Etkinlik şu anda sürüyor | +2 |
| Daveti kabul ettim / belki | +2 / +1 |
| Organizatör benim | +2 |
| **Daveti reddetmiştim** | −3 (elenmez: insan reddettiği toplantıya katılabiliyor) |
| **İptal edilmiş** | aday değil |

Tepe aday ikinciyi **3 puan** geçemiyorsa tahmin yürütülmez: kayıt şeridinde
"Hangi toplantı?" sorulur ve cevap gelene kadar katılımcı yazılmaz.

`probes/takvim_eslestirme.swift` (12 kontrol, hepsi geçiyor) senaryoları
doğruluyor: Teams daveti vs Zoom daveti mikrofonu tutan uygulamayla ayrılıyor;
iki Teams toplantısında kabul/ret ayırıyor; ikisi de kabul edilmişse fark 0
kalıyor (→ soruluyor) ve pencere başlığı geldiğinde belirsizlik kalkıyor.

Yanlış eşleşme sonradan düzeltilebilir: kenar çubuğunda sağ tık → **Takvim
toplantısını değiştir**. Eski takvim katılımcıları silinir (`source='calendar'`
satırları), yenisi yazılır; `source='transcript'` satırlarına dokunulmaz.

### 29.4 Sandbox kaldırıldı ve veri göçü ölçüldü

Karar: pencere başlığı yolu için **App Sandbox kapatıldı** (`ENABLE_APP_SANDBOX
= NO`, entitlement dosyasından `com.apple.security.*` girişleri silindi).
Alternatifler elendi — ekran kaydı izni tap mimarisinin kaçındığı iznin ta
kendisi; Apple Events geçici istisnası sandbox'ta belirsiz ve Apple'ın
önermediği bir yol. **Ağ girişi yok**, yani "hiçbir veri cihazı terk etmez"
garantisi aynen duruyor.

**Göç şart:** sandbox'lı uygulamanın "Application Support" dizini konteynerin
içinde (`~/Library/Containers/<bundle>/Data/…`); sandbox kalkınca `FileManager`
gerçek dizini döndürüyor ve veritabanı, ses kayıtları, sözlük **görünmez
oluyor**. İlk denemede iki hata çıktı, ikisi de ölçümle yakalandı:

1. **Sıra hatası.** Göç `applicationDidFinishLaunching` içindeydi ama
   `@State private var recorder = RecordingController()` veritabanını **daha
   önce** açıyor. Günlük sırası ele verdi: `Veritabanı hazır` satırı
   `ora başladı` satırından önce yazılmıştı. Boş bir `ora.sqlite` oluşuyor,
   göç kendini atlıyor, kullanıcı bütün toplantılarını kaybetmiş görünüyordu.
   Göç `OraApp.init()`'e alındı.
2. **`copyItem` dizin birleştirmiyor.** Hedefte uygulamanın kendi oluşturduğu
   boş `recordings/` dizini olduğu için ses dosyaları sessizce atlanıyordu.
   Yerine özyinelemeli birleştirme yazıldı.

Düzeltildikten sonra ölçülen göç:
```
[app]   Sandbox konteynerinden 25 dosya taşındı — eski veri yerinde bırakıldı
[store] Veritabanı hazır: /Users/user/Library/Application Support/ora/ora.sqlite
[store] 5 kaydın ses yolu yeni veri dizinine göre düzeltildi
→ 6 toplantı, 7 ses dosyası, sözlük dizini yeni konumda
```
Kopyalanır, taşınmaz: göç yarıda kalırsa eski veri konteynerde durur.
`meetings.audio_path` mutlak yazıldığı için ayrıca düzeltilir; ölçüt "dosya
kayıp mı" değil **"yol güncel veri dizininde mi"** — kopya olduğu için eski yol
da açılmaya devam ediyor ve uygulama sessizce konteynerdeki dosyayı
kullanmaya devam ederdi.

Özellik **opt-in**: `OraSettings.windowTitleEnabled` varsayılan kapalı,
onboarding'de ve Ayarlar → Takvim'de açılıyor. Kapalıyken `WindowTitle`
çağrılmaz, Erişilebilirlik izni istenmez.
