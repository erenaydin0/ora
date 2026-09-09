import Foundation

/// ARCHITECTURE.md'deki `Pipeline` katmanı: Capture'ın bıraktığı ses
/// dosyasından transkript, noktalama, özet ve konu bloklarını üretir ve
/// veritabanına yazar.
///
/// **Bu tip görünüm durumu tanımaz.** `selection` diye bir kavramı yok, hangi
/// toplantının ekranda olduğunu bilmez ve bilmemesi gerekir: ürettiği her şeyi
/// `meetingID` taşıyan `PipelineEvent` olarak yayar, süzmeyi arayüz yapar.
/// Eskiden hat doğrudan yayınlanan duruma yazıyordu ve her yazımın önünde elle
/// konmuş bir `onScreen` kapısı gerekiyordu (REFACTOR.md §2).
///
/// Hâlâ `@MainActor`: ağır işin tamamı `Transcribing` ve `Intelligent`
/// içindeki zaten asenkron API'lerde geçiyor, bu tip yalnızca sırayı yürütüyor.
/// `actor`'a çevirmek ayrı bir adımdır ve davranışı değiştirmez.
///
/// İşlem hattı sırası **CLAUDE.md'de sabittir**; buradaki numaralı yorumlar
/// onu izler.
@MainActor
final class MeetingPipeline {

    /// Dil paketi hazırlığı. Gerçek Speech varlıklarına dokunduğu için
    /// enjekte edilebilir — testte kapatılır, yoksa ölçüm makinede kurulu dil
    /// paketlerine bağımlı olur.
    typealias LocalePreparation =
        @Sendable (Locale, @escaping @Sendable (Double) -> Void) async throws -> Void
    /// Konuşulan dili tanıyan bir Apple API'si yok; "otomatik" sesin ilk
    /// bölümünü kurulu adaylarla çözüp güven skorlarını karşılaştırır.
    typealias LocaleDetection = @Sendable (URL) async -> Locale

    static let defaultLocalePreparation: LocalePreparation = { locale, progress in
        let module = SpeechTranscription.makeTranscriber(locale: locale, live: false)
        try await TranscriptionLocale.ensureInstalled(locale, module: module,
                                                      progress: progress)
    }

    static let defaultLocaleDetection: LocaleDetection = { url in
        await TranscriptionLocale.detect(url: url, channel: .mic)
    }

    private let store: MeetingStore
    private let vocabularyStore: VocabularyStore
    private let transcription: any Transcribing
    private let intelligence: any Intelligent
    private let settings: OraSettings
    private let deferReason: @Sendable () -> PowerState.DeferReason?
    private let prepareLocale: LocalePreparation
    private let detectLocale: LocaleDetection

    /// Olay dinleyicileri. **Senkron ve `@MainActor`**: sıra korunur ve
    /// `await pipeline.…` döndüğünde arayüz durumu zaten güncellenmiş olur.
    /// `AsyncStream` bir tur gecikme koyar ve "işlem bitti ama ekran hâlâ eski"
    /// penceresi açardı.
    private var observers: [(PipelineEvent) -> Void] = []

    /// Şu an koşan toplantılar. Aşama **veritabanından türetilmez**: tam geçiş
    /// segmentleri çoktan yazdığı için yarım hâlden türetince işlenen
    /// toplantıya dönüldüğünde animasyon kayboluyordu (RESEARCH.md §27).
    private var running: Set<Int64> = []

    var modelAvailability: ModelAvailability { intelligence.availability }

    /// Hat **herhangi bir** toplantı için koşuyor mu. Yetki kapıları buna bakar:
    /// ikinci bir hat aynı Speech ve Foundation Models yolunu paylaşır.
    var isRunning: Bool { !running.isEmpty }

    init(store: MeetingStore,
         vocabularyStore: VocabularyStore,
         transcription: any Transcribing,
         intelligence: any Intelligent,
         settings: OraSettings,
         deferReason: @escaping @Sendable () -> PowerState.DeferReason?
            = PowerState.deferReason,
         prepareLocale: LocalePreparation? = nil,
         detectLocale: LocaleDetection? = nil) {
        self.store = store
        self.vocabularyStore = vocabularyStore
        self.transcription = transcription
        self.intelligence = intelligence
        self.settings = settings
        self.deferReason = deferReason
        self.prepareLocale = prepareLocale ?? Self.defaultLocalePreparation
        self.detectLocale = detectLocale ?? Self.defaultLocaleDetection
    }

    /// Hattın olaylarına abone olur. Birden çok tüketici olabilir: arayüzün
    /// yanı sıra ileride hafıza, otomasyon ve MCP de buraya bağlanır.
    func observe(_ handler: @escaping (PipelineEvent) -> Void) {
        observers.append(handler)
    }

    private func emit(_ kind: PipelineEvent.Kind, _ meetingID: Int64) {
        let event = PipelineEvent(meetingID: meetingID, kind: kind)
        for observer in observers { observer(event) }
    }

    private func stage(_ stage: PipelineStage, _ meetingID: Int64) {
        if stage.isActive { running.insert(meetingID) } else { running.remove(meetingID) }
        emit(.stage(stage), meetingID)
    }

    // MARK: - Adım 3: kayıt sonrası tam transkripsiyon geçişi

    func fullPass(meetingID: Int64, url: URL) async {
        // Hat hangi yoldan çıkarsa çıksın aşama açık kalmaz: takılı bir
        // animasyon, hata mesajından daha kötü bir hata modudur.
        defer { if running.contains(meetingID) { stage(.done, meetingID) } }
        // Ses artık diskte; oynatıcı toplantıyı yeniden seçmeye gerek kalmadan
        // bu kayda bağlanabilir.
        emit(.audio(url), meetingID)
        stage(.preparingLanguage, meetingID)

        let locale: Locale
        if let chosen = settings.transcriptionLanguage.locale {
            locale = chosen
        } else {
            locale = await detectLocale(url)
        }

        do {
            Log.debug(.transcribe, "Tam geçiş: dil hazırlanıyor (\(locale.identifier))")
            try await prepareLocale(locale) { [weak self] value in
                Task { @MainActor in self?.stage(.downloadingLanguage(value), meetingID) }
            }
            stage(.transcribing(0), meetingID)
            let words = (try? await vocabularyStore.activeWords()) ?? []
            Log.debug(.transcribe, "Tam geçiş: \(words.count) sözlük terimi, ses açılıyor")
            let segments = try await transcription.transcribe(
                url: url, locale: locale, vocabulary: words
            ) { [weak self] value in
                Task { @MainActor in self?.stage(.transcribing(value), meetingID) }
            }
            emit(.transcript(segments), meetingID)
            try? await store.replaceTranscript(meetingID, segments: segments)
            Log.info(.transcribe, "Tam geçiş bitti — \(segments.count) segment, "
                     + "\(locale.identifier)")
            await summarize(meetingID: meetingID, segments: segments)
        } catch {
            stage(.idle, meetingID)
            Log.error(.transcribe, "Tam geçiş başarısız (\(locale.identifier))", error)
            // Ham ses korunur: "Yeniden dene" bu dosyayı işler.
            emit(.retryable(url), meetingID)
            emit(.failed(error as? OraError ?? .transcriptionFailed(underlying: error)),
                 meetingID)
        }
    }

    // MARK: - Adım 4-7: noktalama, özet, kayıt, bildirim

    /// - Parameter variation: kullanıcı özeti beğenmeyip **yeniden ürettiğinde**
    ///   açılır; örnekleme serbestleşir ve başlık yeniden üretilmez.
    func summarize(meetingID: Int64, segments: [Segment], variation: Bool = false) async {
        defer { if running.contains(meetingID) { stage(.done, meetingID) } }

        // Kayıt bitince işlem hemen başlar. **Tek istisna:** düşük güç modu veya
        // termal baskı — o zaman otomatik başlatılmaz, kullanıcıya sorulur.
        if let reason = deferReason() {
            emit(.deferred(reason), meetingID)
            emit(.notice(reason.turkishMessage + ". " + reason.turkishDetail), meetingID)
            await finish(meetingID, ozet: nil, topics: [], save: true)
            Log.info(.pipeline, "Özetleme ertelendi: \(reason.turkishMessage)")
            return
        }
        emit(.deferCleared, meetingID)

        let availability = intelligence.availability
        guard availability.isAvailable else {
            emit(.notice(availability.turkishMessage + ". " + availability.turkishDetail),
                 meetingID)
            await finish(meetingID, ozet: nil, topics: [], save: true)
            Log.warning(.intelligence, "Özetleme atlandı: \(availability.turkishMessage)")
            return
        }

        // 4 — Noktalama restorasyonu (zorunlu adım)
        //
        // Hattın beslendiği metin **yereldir**: `segments` çağrıldığı anda
        // verilmiştir ve seçim değişse bile değişmez.
        var working = segments
        stage(.punctuating(0), meetingID)
        do {
            let punctuated = try await intelligence.restorePunctuation(segments) { [weak self] value in
                Task { @MainActor in self?.stage(.punctuating(value), meetingID) }
            }
            working = punctuated
            emit(.transcript(punctuated), meetingID)
            try? await store.replaceTranscript(meetingID, segments: punctuated)
        } catch {
            // Noktalama bir iyileştirmedir; başarısız olursa orijinal metin korunur.
            Log.warning(.intelligence, "Noktalama atlandı: \(error.localizedDescription)")
        }

        // 5 — Map-reduce özetleme
        stage(.summarizing(0), meetingID)
        // Tarih ve katılımcılar **işlenen** toplantıdan okunur; ekrandaki
        // toplantıdan alınırsa son tarihler yanlış güne bağlanır.
        let record = try? await store.load(meetingID)
        let people = (try? await store.calendarParticipants(meetingID)) ?? []
        var produced: Ozet?
        var producedTopics: [TopicSegment] = []
        do {
            let context = SummaryContext(
                meetingDate: record?.meeting.date ?? Date(),
                participants: people + [settings.userDisplayName]
                    .compactMap { $0.isEmpty ? nil : $0 },
                userName: settings.userDisplayName.isEmpty ? nil : settings.userDisplayName)
            let result = try await intelligence.summarize(
                working, context: context, variation: variation) { [weak self] value in
                Task { @MainActor in self?.stage(.summarizing(value), meetingID) }
            }
            produced = result.ozet
            producedTopics = result.topics
            emit(.summary(result.ozet, result.topics), meetingID)
            if result.skippedChunks > 0 {
                // Sessiz kalite düşüşü yok: bir bölüm özetlenemediyse söylenir.
                emit(.notice("\(result.skippedChunks) bölüm özetlenemedi; "
                             + "özet eksik olabilir. Transkript tam."), meetingID)
            }
            Log.info(.intelligence, "Özet hazır — \(result.ozet.kararlar.count) karar, "
                     + "\(result.ozet.aksiyonlar.count) aksiyon, "
                     + "\(result.topics.count) konu, \(result.skippedChunks) atlanan parça")
        } catch let error as OraError {
            emit(.notice(error.turkishMessage + ". " + error.turkishDetail), meetingID)
            Log.error(.intelligence, "Özetleme başarısız", error)
        } catch {
            emit(.notice("Özet oluşturulamadı. Transkript korundu."), meetingID)
            Log.error(.intelligence, "Özetleme başarısız", error)
        }

        // Başlık önceliği: takvim etkinlik adı → Foundation Models'ın ürettiği
        // başlık → tarih/saat. Pencere başlığı **okunmaz**.
        //
        // Takvim bağı toplantı kaydından okunur (`calendarEventId`), kayıt
        // oturumunun `activeEvent`'inden değil: "Yeniden dene" ve "Şimdi
        // özetle" yollarında `activeEvent` her zaman nil olduğu için takvimden
        // gelen başlığın üstüne üretilmiş başlık yazılabiliyordu.
        //
        // Yeniden özetlemede başlık **üretilmez**: toplantının adı zaten var ve
        // kullanıcı onu elle değiştirmiş olabilir.
        if record?.meeting.calendarEventId == nil, !variation,
           let title = await intelligence.generateTitle(from: working, topics: producedTopics) {
            try? await store.updateTitle(meetingID, title: title)
        }

        // 6 — SQLite güncelle. Üretim başarısızsa (`produced == nil`) eldeki
        // özet **korunur**: yeniden üretim denemesi var olan özeti, konuları ve
        // işaretlenmiş aksiyonları silmez.
        await finish(meetingID, ozet: produced, topics: producedTopics,
                     save: produced != nil || !variation)
    }

    /// Ortak kapanış: özeti yaz, durumu `ready` yap, sesi sıkıştır, aksiyonları
    /// yayınla ve bildirimi tetikle.
    private func finish(_ meetingID: Int64, ozet: Ozet?, topics: [TopicSegment],
                        save: Bool) async {
        if save {
            try? await store.saveSummary(meetingID, ozet: ozet, topics: topics)
        }
        try? await store.markReady(meetingID)
        let reloaded = try? await store.load(meetingID)
        // Ses ancak transkript ve özet hazırken sıkıştırılır (opt-in).
        if let record = reloaded?.meeting { await compressAudioIfNeeded(record) }
        if let reloaded { emit(.actions(reloaded.actions), meetingID) }
        stage(.done, meetingID)
        emit(.storeChanged, meetingID)

        // 7 — Kullanıcıya bildir. Başlık **işlenen** toplantının kaydından
        // okunur; eskiden arayüzün listesinden alınıyordu.
        if let title = reloaded?.meeting.title {
            emit(.finished(title: title), meetingID)
        }
    }

    /// Ayarlardaki sıkıştırma açıksa sesi AAC'ye çevirir. Transkripsiyon ve
    /// özet bittikten **sonra** çalışır; hata verirse ses olduğu gibi kalır.
    ///
    /// Dosya yolu **işlenen** toplantının kaydından okunur.
    private func compressAudioIfNeeded(_ meeting: MeetingRecord) async {
        guard settings.compressAudio, let meetingID = meeting.id,
              let url = Self.existingAudio(meeting),
              url.pathExtension.lowercased() == "wav" else { return }
        do {
            let compressed = try await AudioArchive.compress(url)
            try? await store.setAudioPath(meetingID, path: compressed.path(percentEncoded: false))
            emit(.audio(compressed), meetingID)
        } catch {
            Log.warning(.capture, "Ses sıkıştırılamadı, WAV korundu: \(error.localizedDescription)")
        }
    }

    /// Ses dosyası hâlâ diskte mi?
    static func existingAudio(_ meeting: MeetingRecord) -> URL? {
        guard let path = meeting.audioPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
