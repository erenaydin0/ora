# ora (native) — Mimari

## Süreç modeli
Tek bir macOS uygulama süreci. Yardımcı binary yok, yerel sunucu yok, IPC yok.
Eski ora'daki Electron ↔ FastAPI HTTP köprüsü tamamen ortadan kalktı —
bununla birlikte port çakışması, backend başlatma yarışı ve süreç
yaşam döngüsü sorunlarının tamamı da kalktı.

```
oraApp (SwiftUI)
├── Capture       — AVAudioEngine (mic) + CoreAudio süreç tap'i (sistem) → stereo WAV (artımlı)
├── Transcribe    — SpeechAnalyzer + DictationTranscriber (kanal başına, canlı + kayıt sonrası)
├── Intelligence  — FoundationModels (noktalama, özet, sohbet)
├── Calendar      — EventKit (opt-in): başlık, katılımcılar, toplantı linki
├── Store         — GRDB / SQLite + FTS5
├── Pipeline      — işlem sırası, canlı akış koordinasyonu
└── UI            — 3 sütun SwiftUI
```

Bağımlılık yönü tek yönlüdür: `UI → Pipeline → {Capture, Transcribe,
Intelligence, Calendar, Store}`. Alt modüller birbirini **çağırmaz**; veriyi Pipeline
taşır. Bu kural, Transcribe'ın Intelligence'a veya Capture'ın Store'a
sızmasını engeller.

Faz 1-8 boyunca `Pipeline` ayrı bir tip değildi; rolünü `RecordingController`
üstleniyordu. REFACTOR.md Adım 1-3 ile `ora/Pipeline/` altına çıkarıldı ve
bağımlılık yönü kodda da gerçek oldu. Katman iki tipten oluşur:
`RecordingSession` kayıt **sürerkenini** yürütür (ses yazımı + canlı
transkripsiyon), `MeetingPipeline` kayıt **bittikten sonrasını** (tam geçiş,
noktalama, özet, depolama). Sırayı ikisi de değil `RecordingController` kurar.
Liste/CRUD ve takvim eşleştirmesi hâlâ controller'da (REFACTOR.md Adım 5-6).

---

## Modül sözleşmeleri

### Capture
```swift
protocol AudioCapturing {
    func start(meetingID: Int64) async throws
    func stop() async throws -> URL          // stereo WAV yolu
    var state: AsyncStream<CaptureState> { get }
}
enum CaptureState { case idle, recording(elapsed: TimeInterval),
                         micOnly(reason: String), failed(OraError) }
```
- Çıktı **her zaman** stereo WAV: ch0 = mikrofon, ch1 = sistem sesi
- Sistem sesi `CATapDescription` + `AudioHardwareCreateProcessTap` ile alınır;
  mümkünse `bundleIDs` ile **yalnızca toplantı uygulaması** yakalanır, olmazsa
  kendimiz hariç global tap'e düşülür. ScreenCaptureKit kullanılmaz.
  Tap özel bir toplama cihazına bağlanıp IOProc ile okunur
- Kapsamlı tap'in **sessiz kalması izlenir**: 3 sn boyunca hiç frame gelmezken
  sistemde başka bir süreç ses çalıyorsa global tap'e geçilir. Tarayıcı ve
  Electron uygulamalarının sesi ana bundle'dan çıkmaz (RESEARCH.md §13.3);
  bu gözcü olmadan sistem kanalı sessizce boş kalırdı
- 1 sn'de bir diske flush; süreç çökerse dosya geçerli kalır
- İki kaynak **host time** damgasıyla hizalanır, buffer sayısıyla değil
- Sistem sesi izni yoksa `micOnly` durumuna düşer; ch1 sessizlikle doldurulur
- Capture, Store'a yazmaz — dosya yolu döner **ve** canlı PCM'i
  `liveBuffers` akışıyla yayınlar (aşağıya bak)

```swift
extension AudioCapturing {
    /// Canlı transkripsiyon için ikincil tüketici akışı.
    /// Tüketici geri kalırsa buffer'lar DÜŞÜRÜLÜR — diske yazım asla beklemez.
    var liveBuffers: AsyncStream<(channel: Channel, buffer: AVAudioPCMBuffer)> { get }
}
```

### Transcribe
```swift
struct Segment {
    let channel: Channel          // .mic | .system
    let speaker: String           // "Ben" | "Katılımcı"
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double?
    let words: [WordTiming]
}
protocol Transcribing {
    func transcribe(url: URL, locale: Locale,
                    vocabulary: [String],
                    progress: @Sendable (Double) -> Void) async throws -> [Segment]
}
```
İki modda çalışır, aynı protokol:
- **Canlı** (kayıt sırasında): `Capture.liveBuffers`'ı tüketir, `.volatileResults`
  ile ekrana akan metin üretir, kesinleşen segmentleri DB'ye yazar.
  Ölçülen maliyet kanal başına ~%1 CPU. **En iyi çaba** — hata verirse veya
  geri kalırsa sessizce durur, kayıt etkilenmez, kullanıcıya "canlı transkript
  duraklatıldı" bilgisi düşer
- **Kayıt sonrası** (tam geçiş): diskteki stereo WAV üzerinden koşar, canlı
  geçişin açıklarını kapatır ve güncel vocabulary'yi uygular. Nihai gerçek budur;
  canlı sonuç bir ön izlemedir, canlı çıktı ile tam geçiş çelişirse **tam geçiş kazanır**

- Stereo WAV'ı iki mono akışa ayırır, **her kanalı ayrı** transkribe eder
- mic kanalı → tek konuşmacı "Ben" (diarization gerekmez, kanal zaten ayırıyor)
- Segmentler ortak zaman eksenine göre birleştirilip sıralanır
- Sessiz kanal atlanır
- `vocabulary` → `ContentHint.customizedLanguage`
- Transcribe **LLM çağırmaz**; noktalama Intelligence'ın işidir

### Intelligence
```swift
protocol Intelligent {
    var availability: ModelAvailability { get }
    func restorePunctuation(_ segments: [Segment],
                            progress: @Sendable (Double) -> Void) async throws -> [Segment]
    func summarize(_ segments: [Segment],
                   progress: @Sendable (Double) -> Void) async throws -> (Ozet, [TopicSegment])
    // answer(question:over:) Faz 6'da (toplantı sohbeti) eklenecek
}
```
- **Her çağrıdan önce `availability` kontrol edilir.** `.unavailable` ise
  Pipeline özet adımını atlar, transkript yine de kaydedilir ve gösterilir
- Bağlam 4096 token → tüm uzun girdiler map-reduce edilir (~10.000 karakter/parça)
- Her parça için **yeni `LanguageModelSession`**; oturum tekrar kullanılmaz
- Çıktı `@Generable` şemalarla alınır; elle JSON ayrıştırma yasaktır
- **Her LLM çağrısı başarısızlığa dayanıklıdır.** `guardrailViolation` gerçek ve
  tekrarlayan bir durumdur (RESEARCH.md §15.1). Noktalama başarısız olursa
  orijinal metin korunur; bir parçanın özeti başarısız olursa ham metnin başı
  birleştirmeye girer — hiçbir bölüm sessizce kaybolmaz
- Sağlık metrikleri (konuşma payı, ölü hava) **üretilmez**: kanal başına iki
  kova kişi bilgisi taşımıyordu ve okuma akışını kesiyordu; `MeetingMetrics`
  kaldırıldı (CLAUDE.md, UI Kuralları)

### Calendar
```swift
struct MeetingEvent {
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    let organizer: String?
    let attendees: [String]      // yalnızca .person, .declined olmayanlar
    let meetingApp: BundleID?    // event.URL / notes'tan çıkarılır, SAKLANMAZ
}
protocol CalendarReading {
    var isEnabled: Bool { get }              // kullanıcı ayarı; false ise EventKit'e dokunulmaz
    func authorize() async throws            // yalnızca kullanıcı açtığında çağrılır
    func event(overlapping date: Date) async -> MeetingEvent?   // ±10 dk tolerans
    func upcoming(within: TimeInterval) async -> [MeetingEvent]
    var changes: AsyncStream<Void> { get }   // EKEventStoreChangedNotification
}
```
- Kapalıyken (`isEnabled == false`) modül **hiç örneklenmez**; izin istenmez
- Sorgu penceresi dar: `now − 12s … now + 24s`. Toplu takvim taraması yok
- `notes` ve `location` **dışarı verilmez** — protokol bunları taşımaz,
  dolayısıyla DB'ye sızmaları yapısal olarak imkânsızdır
- `meetingApp` yalnızca Capture'a hangi bundle'ın tap'leneceğini söylemek için
  hesaplanır; `MeetingEvent` diske yazılırken bu alan atılır
- Calendar, Store'a yazmaz — Pipeline taşır

### Store
```swift
protocol Storing {
    func write<T>(_ block: (Database) throws -> T) async throws -> T
    func read<T>(_ block: (Database) throws -> T) async throws -> T
}
```
- Tüm yazımlar `try db.write { }` içinde — transaction garantisi (kural #7)
- FTS5 `transcripts_fts` trigger'larla otomatik güncellenir
- Migration'lar sıralı ve geri alınamaz; INDEX'ler migration'lardan **sonra**
- Silme işlemi: `meetings` → cascade → `transcripts` + FTS + `summaries` +
  `action_items` + `topic_segments`, ardından ses dosyası

### Pipeline
`ora/Pipeline/` — `RecordingSession` (kayıt sürerken) + `MeetingPipeline`
(kayıt sonrası) + `PipelineEvent`.
```swift
@MainActor @Observable final class RecordingSession {
    var state: CaptureState { get }              // AudioCapturing.state akışından
    var liveSegments: [Segment] { get }          // kesinleşmiş canlı satırlar
    var volatileText: [Int: String] { get }      // kanal başına akan metin
    var liveNotice: String? { get }              // canlı duraklatıldıysa Türkçe not
    var meetingID: Int64? { get }                // kaydedilen toplantı
    var onError: ((OraError) -> Void)?

    func start(meetingID: Int64, preferredApp: String?) async throws
    func startLive(locale: Locale, vocabulary: [String]) async
    func stop() async throws -> URL
    func clearLive()
}
```
- `meetingID` **`capture.start` başarılı olduktan sonra** kurulur: başarısız bir
  başlangıç oturum açmamalı, yoksa `stop()` var olmayan bir kaydı kapatır
- `startLive` ayrı çağrıdır ve kayıt başladıktan **sonra** gelir (kural #2).
  Duraklarsa `liveNotice` dolar, kayıt kesintisiz sürer
- `LiveTranscribing` protokolü sahtelenebilir; kural #2 testle korunuyor
```swift
enum PipelineStage { case idle, preparingLanguage, downloadingLanguage(Double),
                          transcribing(Double), punctuating(Double),
                          summarizing(Double), done }

struct PipelineEvent { let meetingID: Int64; let kind: Kind }
extension PipelineEvent {
    enum Kind {
        // seçimden bağımsız
        case stage(PipelineStage), failed(OraError), storeChanged, finished(title: String)
        // yalnızca o toplantı ekrandayken arayüze yazılır
        case transcript([Segment]), summary(Ozet?, [TopicSegment]), actions([MeetingAction])
        case audio(URL), notice(String), deferred(PowerState.DeferReason)
        case deferCleared, retryable(URL)
    }
}
@MainActor final class MeetingPipeline {
    var isRunning: Bool { get }                        // herhangi bir toplantı işleniyor mu
    func observe(_ handler: @escaping (PipelineEvent) -> Void)
    func fullPass(meetingID: Int64, url: URL) async
    func summarize(meetingID: Int64, segments: [Segment], variation: Bool) async
}
```
- **Pipeline görünüm durumu tanımaz.** `selection` diye bir kavramı yoktur ve
  hangi toplantının ekranda olduğunu bilmez. Her olay `meetingID` taşır; süzmeyi
  arayüz **tek yerde** yapar (`RecordingController.apply(_:)`). Eskiden hat
  doğrudan yayınlanan duruma yazıyordu ve her yazımın önünde elle konmuş bir
  `onScreen` kapısı gerekiyordu — 15 tane olmuştu ve unutulan her biri sessiz
  bir toplantılar-arası sızıntıydı (RESEARCH.md §27, REFACTOR.md §2)
- Aşama **toplantı başına** tutulur, uygulama genelinde tek bir aşama yoktur.
  Aşama veritabanından **türetilmez**: tek kaynağı hattın kendisidir
- Olay dağıtımı **senkron ve `@MainActor`**: sıra korunur ve `await` döndüğünde
  arayüz durumu zaten güncellenmiştir. `AsyncStream` bir tur gecikme koyup
  "işlem bitti ama ekran hâlâ eski" penceresi açardı
- Dinleyici birden çok olabilir: arayüzün yanı sıra hafıza, otomasyon ve MCP
  buraya bağlanır — controller'a yeni property eklemeden
- Kayıt bitince işlem **hemen** başlar. Tek istisna `.deferred`:
  `ProcessInfo.isLowPowerModeEnabled` veya `.thermalState >= .serious` ise
  kullanıcıya sorulur. Şarj durumu izlenmez, ayrı bir tetikleyici alt sistemi yoktur
- İşlem hattı sırası CLAUDE.md'de sabittir ve değiştirilmez
- Bir aşama başarısız olursa sonraki aşamalar çalışmaz, ham ses **korunur**,
  kullanıcıya Türkçe hata + "Yeniden dene" gösterilir
- `Pipeline` hâlâ `@MainActor`: ağır işin tamamı `Transcribing` ve `Intelligent`
  içindeki zaten asenkron API'lerde geçer, bu tip yalnızca sırayı yürütür.
  Dış dünyaya dokunan iki nokta (`prepareLocale`, `detectLocale`) ve
  `deferReason` init'ten geçirilir — testte kapatılır

---

## Eşzamanlılık
- Modüller `actor`; UI durumu `@MainActor @Observable`
- Speech ve FoundationModels API'leri zaten `async` — bloklayan sarmalayıcı yazma
- Eski ora'nın hatası: router'lar `async def` ilan edilip içeride bloklayan iş
  yapıyordu ve event loop kilitleniyordu. Swift'te karşılığı, bir `actor`
  içinde senkron ağır iş çalıştırmaktır — ağır işi `Task.detached` veya
  ilgili API'nin kendi async yüzeyine bırak

## Hata modeli
```swift
enum OraError: Error {
    case permissionDenied(Permission)     // mikrofon, ekran kaydı, konuşma tanıma
    case localeNotInstalled(Locale)
    case modelUnavailable(reason: String) // Apple Intelligence kapalı
    case audioWriteFailed(underlying: Error)
    case transcriptionFailed(underlying: Error)
    case contextOverflow                  // map-reduce hatası — bug göstergesi
}
```
Her vakanın **Türkçe** kullanıcı mesajı ve mümkünse bir düzeltici eylemi olur
(izin ayarlarını aç, locale indir, Apple Intelligence'ı aç, tekrar dene).
Sessiz `catch { }` yasaktır.

## Test edilebilirlik
- `AudioCapturing`, `Transcribing`, `Intelligent`, `Storing` protokoldür;
  testlerde sahte (fake) uygulamalar kullanılır
- `oraTests` hedefi (swift-testing) regresyon ağıdır:
  `xcodebuild test -scheme ora`. Yalnızca dış dünyaya dokunan katmanlar
  sahtelenir; veritabanı bellek içi SQLite ile **gerçektir**
- `probes/` altındaki Swift dosyaları canlı API doğrulaması içindir;
  bir API'nin davranışından şüphelenirsen önce probe'u koştur
- Altın küme: 3-5 gerçek Türkçe kayıt + elle yazılmış doğru metin (Faz 0 çıktısı)

## Bilinçli olarak yapılmayanlar
- Platform soyutlama katmanı yok — hedef yalnızca macOS
- Bağımlılık enjeksiyonu çatısı yok — init üzerinden geçir
- Ağ katmanı yok — uygulamada hiçbir HTTP istemcisi bulunmaz (kural #3'ün
  yapısal garantisi: `URLSession` kullanan kod yoksa veri sızamaz)
