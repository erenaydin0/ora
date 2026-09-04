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
  kendimiz hariç global tap'e düşülür. ScreenCaptureKit kullanılmaz
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
    func restorePunctuation(_ segments: [Segment]) async throws -> [Segment]
    func summarize(_ segments: [Segment]) async throws -> Ozet
    func answer(question: String, over segments: [Segment]) async throws -> String
}
```
- **Her çağrıdan önce `availability` kontrol edilir.** `.unavailable` ise
  Pipeline özet adımını atlar, transkript yine de kaydedilir ve gösterilir
- Bağlam 4096 token → tüm uzun girdiler map-reduce edilir (~10.000 karakter/parça)
- Her parça için **yeni `LanguageModelSession`**; oturum tekrar kullanılmaz
- Çıktı `@Generable` şemalarla alınır; elle JSON ayrıştırma yasaktır
- Sağlık metrikleri (konuşma payı, ölü hava) burada değil, Pipeline'da
  zaman damgalarından **hesaplanır** — LLM'e sayı sordurma

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
```swift
enum PipelineStage { case recording(liveTranscript: Bool), transcribing(Double),
                          punctuating, summarizing(Double), done,
                          deferred(reason: DeferReason), failed(OraError) }
enum DeferReason { case lowPowerMode, thermalPressure }
```
- Kayıt bitince işlem **hemen** başlar. Tek istisna `deferred`:
  `ProcessInfo.isLowPowerModeEnabled` veya `.thermalState >= .serious` ise
  kullanıcıya sorulur. Şarj durumu izlenmez, ayrı bir tetikleyici alt sistemi yoktur
- İşlem hattı sırası CLAUDE.md'de sabittir ve değiştirilmez
- Her aşama UI'a `AsyncStream<PipelineStage>` ile yayınlanır — sessiz bekleme yok
- Bir aşama başarısız olursa sonraki aşamalar çalışmaz, ham ses **korunur**,
  kullanıcıya Türkçe hata + "Tekrar dene" gösterilir

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
- `probes/` altındaki Swift dosyaları canlı API doğrulaması içindir;
  bir API'nin davranışından şüphelenirsen önce probe'u koştur
- Altın küme: 3-5 gerçek Türkçe kayıt + elle yazılmış doğru metin (Faz 0 çıktısı)

## Bilinçli olarak yapılmayanlar
- Platform soyutlama katmanı yok — hedef yalnızca macOS
- Bağımlılık enjeksiyonu çatısı yok — init üzerinden geçir
- Ağ katmanı yok — uygulamada hiçbir HTTP istemcisi bulunmaz (kural #3'ün
  yapısal garantisi: `URLSession` kullanan kod yoksa veri sızamaz)
