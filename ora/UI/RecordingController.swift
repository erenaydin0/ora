import Foundation
import Observation
import AVFoundation

/// Canlı buffer'ları o an açık olan `LiveTranscription`'a yönlendiren yönlendirici.
private final class LiveRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var target: LiveTranscription?
    func set(_ target: LiveTranscription?) { lock.withLock { self.target = target } }
    var current: LiveTranscription? { lock.withLock { target } }
}

/// Kayıt, transkripsiyon, özetleme ve depolamayı süren tek durum sahibi.
///
/// ARCHITECTURE.md'deki `Pipeline` rolünü şimdilik bu tip üstleniyor: alt modüller
/// (Capture, Transcribe, Intelligence, Store) birbirini çağırmaz, veriyi bu taşır.
@MainActor
@Observable
final class RecordingController {

    // MARK: - Yayınlanan durum

    private(set) var state: CaptureState = .idle
    private(set) var interrupted: [InterruptedRecording] = []
    var error: OraError?

    /// Kenar çubuğu listesi ve seçim.
    private(set) var meetings: [MeetingListItem] = []
    /// Arama sonucunun transkriptte nerede eşleştiği — toplantı başına bir
    /// parçacık. Arama boşken boştur.
    private(set) var searchSnippets: [Int64: String] = [:]
    var searchText = "" { didSet { scheduleRefresh() } }
    var selection: Int64? {
        didSet {
            guard selection != oldValue else { return }
            if selection != nil { showsActionBoard = false }
            loadSelected()
        }
    }

    private(set) var transcript: [Segment] = []
    private(set) var liveSegments: [Segment] = []
    private(set) var volatileText: [Int: String] = [:]
    private(set) var liveNotice: String?

    /// Tüm toplantıların aksiyonları — pano bunu gösterir. Toplantı seçiminden
    /// bağımsızdır; liste her tazelemede yenilenir.
    private(set) var boardActions: [BoardAction] = []
    /// Kenar çubuğundaki sayı: açık aksiyon adedi.
    var openActionCount: Int { boardActions.count { !$0.isDone } }
    /// Aksiyon panosu açık mı — açıkken orta panel toplantı yerine panoyu gösterir.
    var showsActionBoard = false { didSet { if showsActionBoard { selection = nil } } }
    /// Kullanıcının kendi adı — "Bana düşenler" grubu buna bakar.
    var userDisplayName: String { settings.userDisplayName }

    private(set) var summary: Ozet?
    private(set) var topics: [TopicSegment] = []
    /// Aksiyonlar özetten ayrı taşınır: onay kutusu satır kimliği ister.
    private(set) var actions: [MeetingAction] = []
    private(set) var summaryNotice: String?
    /// Veritabanı açılamadıysa kullanıcıya söylenecek not.
    private(set) var storageNotice: String?

    /// Seçili toplantının sesi diskte duruyor ama transkripti yok — işlem
    /// yeniden denenebilir. Hata mesajı "daha sonra tekrar deneyebilirsiniz"
    /// diyor; o vaadin karşılığı budur.
    private(set) var retryableAudio: URL?

    /// Seçili toplantının diskteki ses dosyası — oynatıcı bunu çalar.
    /// `retryableAudio`'dan ayrı: ses transkript **varken de** durur.
    private(set) var audioURL: URL?

    /// Kayıtlar dizininin toplam boyutu — Ayarlar'daki Depolama bölümü.
    private(set) var audioBytes: Int64 = 0

    /// Algılamadan gelen öneri; kullanıcı karar verene kadar durur.
    var pendingSignal: MeetingSignal? { detector.pendingSignal }
    /// Toplantı uygulaması mikrofonu 30 sn'den uzun bıraktı.
    var suggestsStop: Bool { detector.suggestsStop }
    /// Güç/termal nedeniyle özetleme ertelendiyse nedeni.
    private(set) var deferReason: PowerState.DeferReason?
    /// Sohbet geçmişi ve durumu.
    private(set) var chatTurns: [MeetingStore.ChatTurn] = []
    private(set) var isAnswering = false
    /// Sözlük onayı bekleyen kelimeler dahil tüm sözlük.
    private(set) var vocabulary: [VocabularyStore.Word] = []
    /// Takvimden gelen katılımcılar (Özet'te Kişiler bölümü).
    private(set) var calendarParticipants: [String] = []
    /// Menü barda gösterilecek sıradaki toplantı.
    private(set) var upcomingEvent: MeetingEvent?
    /// Kanal başına anlık ses seviyesi (0…1).
    private(set) var channelLevels: [Int: Float] = [:]
    /// Canlı transkriptin son satırı — menü bar popover'ında akar.
    var lastLiveLine: String? {
        volatileText.values.first(where: { !$0.isEmpty })
            ?? liveSegments.last?.text
    }

    private(set) var transcriptionStage: Stage = .idle
    enum Stage: Equatable {
        case idle
        case preparingLanguage
        case downloadingLanguage(Double)
        case transcribing(Double)
        case punctuating(Double)
        case summarizing(Double)
        case done
    }

    var language: TranscriptionLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey) }
    }

    var modelAvailability: ModelAvailability { intelligence.availability }

    // MARK: - Bağımlılıklar

    private let capture: any AudioCapturing
    private let transcription: any Transcribing
    private let intelligence: any Intelligent
    private let store: MeetingStore
    private let vocabularyStore: VocabularyStore
    let detector: MeetingDetector
    let calendar: CalendarReader
    private let notifications = MeetingNotifications()
    private let settings: OraSettings

    private let route = LiveRoute()
    private var live: LiveTranscription?
    private var liveUpdatesTask: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    /// Şu anda kaydedilen toplantının `meetings.id` değeri.
    private var activeMeetingID: Int64?
    /// Kaydın takvimden eşleşen etkinliği (varsa).
    private var activeEvent: MeetingEvent?

    private static let languageKey = "transcriptionLanguage"

    init(capture: any AudioCapturing = AudioCapture(),
         transcription: any Transcribing = SpeechTranscription(),
         intelligence: any Intelligent = FoundationIntelligence(),
         database: OraDatabase? = nil,
         settings: OraSettings = .shared) {
        self.capture = capture
        self.transcription = transcription
        self.intelligence = intelligence
        self.settings = settings
        self.detector = MeetingDetector(settings: settings)
        self.calendar = CalendarReader(settings: settings)

        // Veritabanı açılamazsa uygulama işlevsiz kalmaz: bellek içi bir
        // veritabanıyla sürer ve kullanıcıya Türkçe not düşülür.
        var notice: String?
        let resolved: OraDatabase
        if let database {
            resolved = database
        } else {
            do {
                resolved = try OraDatabase.shared()
            } catch {
                Log.error(.store, "Veritabanı açılamadı, bellek içi moda düşüldü", error)
                notice = "Veritabanı açılamadı. Bu oturumdaki kayıtlar saklanmayacak."
                resolved = try! OraDatabase(path: ":memory:")
            }
        }
        self.store = MeetingStore(database: resolved)
        self.vocabularyStore = VocabularyStore(database: resolved)
        self.storageNotice = notice
        self.language = UserDefaults.standard.string(forKey: Self.languageKey)
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .turkish

        observation = Task { [weak self] in
            guard let stream = self?.capture.state else { return }
            for await next in stream {
                self?.state = next
                if case .failed(let error) = next { self?.error = error }
            }
        }
        feedTask = Task { [route, capture] in
            for await buffer in capture.liveBuffers {
                await route.current?.feed(buffer)
            }
        }
        wireDetection()
    }

    // MARK: - Toplantı algılama

    private func wireDetection() {
        detector.onAutoStart = { [weak self] signal in
            Task { @MainActor in await self?.start(signal: signal) }
        }
        notifications.onRecord = { [weak self] bundleID in
            Task { @MainActor in
                guard let self, let signal = self.detector.pendingSignal,
                      signal.bundleID == bundleID else { return }
                self.detector.dismissSuggestion()
                await self.start(signal: signal)
            }
        }
        notifications.onDismiss = { [weak self] _ in
            self?.detector.dismissSuggestion()
        }
        notifications.onAlways = { [weak self] bundleID in
            guard let self else { return }
            self.settings.alwaysRecordBundleIDs.insert(bundleID)
            Task { @MainActor in
                guard let signal = self.detector.pendingSignal,
                      signal.bundleID == bundleID else { return }
                self.detector.dismissSuggestion()
                await self.start(signal: signal)
            }
        }
    }

    /// Uygulama açılışında bir kez.
    ///
    /// Algılama **bildirim iznini beklemez**: bildirim izni istemi kullanıcı
    /// yanıtlayana kadar askıda kalır ve beklenirse algılama hiç başlamaz.
    /// İzin verilmese bile öneri arayüzde görünür.
    func startServices() async {
        detector.start()
        observeSignals()
        await refreshVocabulary()
        await refreshUpcoming()
        await purgeExpiredAudio()
        refreshStorage()
        Task { await notifications.prepare() }
    }

    // MARK: - Depolama

    func refreshStorage() {
        audioBytes = AudioArchive.totalBytes()
    }

    /// Saklama süresi dolan ses dosyalarını siler. Transkript, özet ve
    /// aksiyonlar **kalır** — silinen yalnızca sestir.
    func purgeExpiredAudio() async {
        let days = settings.audioRetentionDays
        guard days > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        else { return }
        let files = (try? await store.audioFiles(before: cutoff)) ?? []
        var removed = 0
        for file in files where AudioArchive.delete(file.path) {
            try? await store.setAudioPath(file.id, path: nil)
            removed += 1
        }
        if removed > 0 {
            Log.info(.store, "Saklama süresi dolan \(removed) ses dosyası silindi (\(days) gün)")
            if let selection { await load(selection) }
        }
        refreshStorage()
    }

    /// Kullanıcının isteğiyle tek bir kaydın sesini siler.
    func deleteAudio(_ meetingID: Int64) async {
        let files = (try? await store.audioFiles()) ?? []
        guard let file = files.first(where: { $0.id == meetingID }) else { return }
        AudioArchive.delete(file.path)
        try? await store.setAudioPath(meetingID, path: nil)
        if selection == meetingID { await load(meetingID) }
        refreshStorage()
    }

    /// Ayarlardaki sıkıştırma açıksa kayıt sonrası sesi AAC'ye çevirir.
    /// Transkripsiyon ve özet bittikten **sonra** çalışır; hata verirse
    /// ses olduğu gibi kalır.
    private func compressAudioIfNeeded(meetingID: Int64) async {
        guard settings.compressAudio, let url = audioURL,
              url.pathExtension.lowercased() == "wav" else { return }
        do {
            let compressed = try await AudioArchive.compress(url)
            try? await store.setAudioPath(meetingID, path: compressed.path(percentEncoded: false))
            audioURL = compressed
            if retryableAudio != nil { retryableAudio = compressed }
        } catch {
            Log.warning(.capture, "Ses sıkıştırılamadı, WAV korundu: \(error.localizedDescription)")
        }
        refreshStorage()
    }

    private func observeSignals() {
        Task { [weak self] in
            // Öneri geldiğinde bildirim gönder; sinyal `@Observable` olduğu için
            // burada kısa aralıklı bir kontrol yeterli ve ucuzdur.
            var lastNotified: String?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if let signal = self.detector.pendingSignal, signal.bundleID != lastNotified {
                    lastNotified = signal.bundleID
                    let event = self.settings.calendarEnabled
                        ? self.calendar.event(overlapping: Date()) : nil
                    await self.notifications.suggestRecording(signal, event: event)
                } else if self.detector.pendingSignal == nil {
                    lastNotified = nil
                }
            }
        }
    }

    /// Arayüzdeki öneri şeridinden kayıt başlatma.
    func startFromSuggestion() async {
        guard let signal = detector.pendingSignal else { return }
        detector.dismissSuggestion()
        await start(signal: signal)
    }

    func refreshUpcoming() async {
        upcomingEvent = settings.calendarEnabled ? calendar.upcoming().first : nil
    }

    // MARK: - Sözlük

    func refreshVocabulary() async {
        vocabulary = (try? await vocabularyStore.all()) ?? []
    }

    func approveWord(_ id: Int64) async {
        try? await vocabularyStore.approve(id)
        await refreshVocabulary()
    }

    func rejectWord(_ id: Int64) async {
        try? await vocabularyStore.reject(id)
        await refreshVocabulary()
    }

    func addWord(_ word: String) async {
        try? await vocabularyStore.add(word)
        await refreshVocabulary()
    }

    // MARK: - Toplantı sohbeti

    func ask(_ question: String) async {
        guard let meetingID = selection, !transcript.isEmpty, !isAnswering else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isAnswering = true
        defer { isAnswering = false }
        do {
            let answer = try await intelligence.answer(question: trimmed, over: transcript)
            try? await store.appendChat(meetingID, question: trimmed, answer: answer)
            chatTurns = (try? await store.chatHistory(meetingID)) ?? []
        } catch let error as OraError {
            self.error = error
        } catch {
            self.error = .modelUnavailable(reason: error.localizedDescription)
        }
    }

    // MARK: - Türetilmiş

    var isRecording: Bool { state.isRecording }

    var elapsedText: String {
        let total = Int(state.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var micOnlyReason: String? {
        if case .micOnly(let reason, _) = state { return reason }
        return nil
    }

    var displayedSegments: [Segment] {
        transcript.isEmpty ? liveSegments : transcript
    }

    var isTranscribing: Bool {
        switch transcriptionStage {
        case .idle, .done: false
        default: true
        }
    }

    var selectedMeeting: MeetingListItem? {
        meetings.first { $0.id == selection }
    }

    /// Kayıt sürerken veya işlem sürerken düzeltme yapılmaz — metin değişecek.
    var canCorrect: Bool {
        selection != nil && !isRecording && !isTranscribing && !transcript.isEmpty
    }

    /// Transkript var ama özet yok. Güç/termal ertelemesi dışında da olabilir:
    /// özetleme başarısız olmuş ya da toplantı dışarıdan yüklenmiş olabilir.
    /// Böyle bir toplantı elle özetlenebilmeli, yoksa çıkmaz sokak olur.
    var canSummarize: Bool {
        !isRecording && !isTranscribing && summary == nil && !transcript.isEmpty
            && modelAvailability.isAvailable
    }

    /// Yeniden deneme düğmesi görünür mü?
    var canRetry: Bool {
        retryableAudio != nil && !isRecording && !isTranscribing
    }

    var exportPayload: MeetingExport.Payload? {
        guard let meeting = selectedMeeting, !isRecording,
              !transcript.isEmpty || summary != nil else { return nil }
        return MeetingExport.Payload(title: meeting.title, date: meeting.date,
                                     duration: meeting.duration, segments: transcript,
                                     summary: summary, topics: topics,
                                     actions: actions,
                                     participants: calendarParticipants)
    }

    // MARK: - Liste

    func refresh() async {
        do {
            meetings = try await store.list(search: searchText)
        } catch {
            Log.error(.store, "Toplantı listesi okunamadı", error)
        }
        boardActions = (try? await store.allActions()) ?? boardActions
        searchSnippets = (try? await store.snippets(search: searchText)) ?? [:]
    }

    /// Panodan kaynak toplantıya git.
    func openMeeting(_ meetingID: Int64) {
        showsActionBoard = false
        selection = meetingID
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func loadSelected() {
        guard let selection, !isRecording else { return }
        Task { [weak self] in await self?.load(selection) }
    }

    private func load(_ meetingID: Int64) async {
        do {
            guard let loaded = try await store.load(meetingID) else { return }
            transcript = loaded.segments
            liveSegments = []
            summary = loaded.summary
            topics = loaded.topics
            actions = loaded.actions
            summaryNotice = nil
            transcriptionStage = loaded.segments.isEmpty ? .idle : .done
            audioURL = Self.existingAudio(loaded.meeting)
            retryableAudio = loaded.segments.isEmpty ? audioURL : nil
            chatTurns = (try? await store.chatHistory(meetingID)) ?? []
            calendarParticipants = (try? await store.calendarParticipants(meetingID)) ?? []
        } catch {
            Log.error(.store, "Toplantı yüklenemedi: \(meetingID)", error)
            self.error = .audioWriteFailed(underlying: error)
        }
    }

    func delete(_ meetingID: Int64) async {
        do {
            try await store.delete(meetingID)
            refreshStorage()
            if selection == meetingID {
                selection = nil
                clearDisplayed()
            }
            await refresh()
        } catch {
            Log.error(.store, "Toplantı silinemedi: \(meetingID)", error)
        }
    }

    func rename(_ meetingID: Int64, to title: String) async {
        try? await store.updateTitle(meetingID, title: title)
        await refresh()
    }

    /// Transkriptte tıklayarak düzeltme — `corrections` tablosunu besler.
    func correct(_ segment: Segment, to text: String) async {
        guard let meetingID = selection else { return }
        do {
            try await store.applyCorrection(meetingID: meetingID, original: segment,
                                            corrected: text)
            // Düzeltmede beliren yeni özel isimler sözlüğe **aday** olur;
            // kullanıcı onaylamadan transkripsiyona verilmez.
            try? await vocabularyStore.proposeFromCorrection(mistake: segment.text,
                                                             correct: text)
            await refreshVocabulary()
            await load(meetingID)
        } catch {
            Log.error(.store, "Düzeltme kaydedilemedi", error)
        }
    }

    // MARK: - Kayıt

    func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    func start() async { await start(signal: nil) }

    /// - Parameter signal: algılamadan geldiyse hangi uygulamanın tap'leneceğini
    ///   ve takvimde hangi etkinliğe denk geldiğini belirlemekte kullanılır.
    func start(signal: MeetingSignal?) async {
        guard !isRecording else { return }
        clearDisplayed()

        let meetingID: Int64
        do {
            meetingID = try await store.createMeeting()
        } catch {
            self.error = .audioWriteFailed(underlying: error)
            return
        }
        activeMeetingID = meetingID
        selection = meetingID

        // Takvim açıksa o ana denk gelen etkinlik aranır (±10 dk tolerans).
        // Etkinlik başlığı ve katılımcılar buradan gelir; toplantı linki
        // yalnızca hangi uygulamanın tap'leneceğini söylemek için okunur.
        var event: MeetingEvent?
        if settings.calendarEnabled {
            event = calendar.event(overlapping: Date())
            if let event {
                try? await store.linkCalendarEvent(meetingID, event: event)
                // Katılımcı adları sözlüğe beslenir — özel isim tanımanın en
                // zayıf noktasıdır, takvimin en somut teknik kazancı budur.
                try? await vocabularyStore.addCalendarNames(event.attendees)
                await refreshVocabulary()
            }
        }
        let preferredApp = event?.meetingApp
            ?? signal.flatMap { MeetingApps.native.contains($0.bundleID) ? $0.bundleID : nil }

        do {
            try await capture.start(meetingID: meetingID, preferredApp: preferredApp)
        } catch let error as OraError {
            try? await store.delete(meetingID)
            activeMeetingID = nil
            self.error = error
            return
        } catch {
            try? await store.delete(meetingID)
            activeMeetingID = nil
            self.error = .audioWriteFailed(underlying: error)
            return
        }
        activeEvent = event
        detector.recordingStarted(bundleID: signal?.bundleID ?? preferredApp)
        startLevelUpdates()
        await refresh()
        await startLive()
    }

    func stop() async {
        guard isRecording, let meetingID = activeMeetingID else { return }
        levelTask?.cancel()
        levelTask = nil
        channelLevels = [:]
        await stopLive()
        do {
            let url = try await capture.stop()
            let duration = Self.duration(of: url)
            try? await store.markProcessing(meetingID, audioPath: url, duration: duration)
            await refresh()
            await runFullPass(meetingID: meetingID, url: url, duration: duration)
        } catch let error as OraError {
            Log.error(.capture, "Kayıt kapatılamadı", error)
            self.error = error
        } catch {
            Log.error(.capture, "Kayıt kapatılamadı", error)
            self.error = .audioWriteFailed(underlying: error)
        }
        activeMeetingID = nil
        activeEvent = nil
        detector.recordingStopped()
        await refresh()
    }

    /// Seviye göstergesi 100 ms'de bir tazelenir — ses yoluna dokunmaz,
    /// yalnızca son tepe değerini okur.
    private func startLevelUpdates() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRecording else { return }
                self.channelLevels = self.capture.levels
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func clearDisplayed() {
        transcript = []
        liveSegments = []
        volatileText = [:]
        liveNotice = nil
        summary = nil
        topics = []
        actions = []
        summaryNotice = nil
        deferReason = nil
        chatTurns = []
        calendarParticipants = []
        transcriptionStage = .idle
        retryableAudio = nil
        audioURL = nil
    }

    // MARK: - Canlı transkripsiyon (en iyi çaba)

    private func startLive() async {
        let locale = language.locale ?? Locale(identifier: "tr-TR")
        let words = (try? await vocabularyStore.activeWords()) ?? []
        let live = LiveTranscription()
        self.live = live
        route.set(live)
        await live.start(locale: locale, vocabulary: words)

        if await live.isPaused {
            liveNotice = await live.pauseReason
            route.set(nil)
            self.live = nil
            return
        }
        liveUpdatesTask = Task { [weak self] in
            for await update in await live.updates {
                await self?.apply(update)
            }
        }
    }

    private func stopLive() async {
        route.set(nil)
        liveUpdatesTask?.cancel()
        liveUpdatesTask = nil
        if let live { await live.finish() }
        live = nil
        volatileText = [:]
    }

    private func apply(_ update: LiveUpdate) {
        if update.isFinal {
            volatileText[update.channel.rawValue] = nil
            liveSegments.append(Segment(channel: update.channel,
                                        speaker: update.channel.speaker,
                                        text: update.text, start: update.start,
                                        end: update.end, confidence: nil, words: []))
            liveSegments.sort { $0.start < $1.start }
        } else {
            volatileText[update.channel.rawValue] = update.text
        }
    }

    // MARK: - İşlem hattı (sıra CLAUDE.md'de sabittir)

    private func runFullPass(meetingID: Int64, url: URL, duration: TimeInterval) async {
        // Ses artık diskte; oynatıcı toplantıyı yeniden seçmeye gerek kalmadan
        // bu kayda bağlanabilir.
        audioURL = url
        transcriptionStage = .preparingLanguage
        let locale: Locale
        if let chosen = language.locale {
            locale = chosen
        } else {
            locale = await TranscriptionLocale.detect(url: url, channel: .mic)
        }

        do {
            let module = SpeechTranscription.makeTranscriber(locale: locale, live: false)
            Log.debug(.transcribe, "Tam geçiş: dil hazırlanıyor (\(locale.identifier))")
            try await TranscriptionLocale.ensureInstalled(locale, module: module) { [weak self] value in
                Task { @MainActor in self?.transcriptionStage = .downloadingLanguage(value) }
            }
            transcriptionStage = .transcribing(0)
            let words = (try? await vocabularyStore.activeWords()) ?? []
            Log.debug(.transcribe, "Tam geçiş: \(words.count) sözlük terimi, ses açılıyor")
            let segments = try await transcription.transcribe(
                url: url, locale: locale, vocabulary: words
            ) { [weak self] value in
                Task { @MainActor in self?.transcriptionStage = .transcribing(value) }
            }
            transcript = segments
            liveSegments = []
            try? await store.replaceTranscript(meetingID, segments: segments)
            Log.info(.transcribe, "Tam geçiş bitti — \(segments.count) segment, "
                     + "\(locale.identifier)")
            await runIntelligence(meetingID: meetingID, segments: segments, duration: duration)
        } catch let error as OraError {
            transcriptionStage = .idle
            Log.error(.transcribe, "Tam geçiş başarısız (\(locale.identifier))", error)
            retryableAudio = url
            self.error = error
        } catch {
            transcriptionStage = .idle
            Log.error(.transcribe, "Tam geçiş başarısız (\(locale.identifier))", error)
            retryableAudio = url
            self.error = .transcriptionFailed(underlying: error)
        }
    }

    /// Başarısız veya yarım kalmış bir toplantıyı elle yeniden işler.
    /// Ham ses diskte durduğu için kayıt tekrarlanmaz — hat baştan koşar.
    func retryProcessing() async {
        guard let meetingID = selection, let url = retryableAudio,
              !isRecording, !isTranscribing else { return }
        Log.info(.pipeline, "İşlem elle yeniden başlatıldı — toplantı \(meetingID)")
        retryableAudio = nil
        let duration = Self.duration(of: url)
        try? await store.markProcessing(meetingID, audioPath: url, duration: duration)
        await refresh()
        await runFullPass(meetingID: meetingID, url: url, duration: duration)
        if transcript.isEmpty { retryableAudio = url }
        await refresh()
    }

    /// Ses dosyası hâlâ diskte mi?
    private static func existingAudio(_ meeting: MeetingRecord) -> URL? {
        guard let path = meeting.audioPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func runIntelligence(meetingID: Int64, segments: [Segment],
                                 duration: TimeInterval) async {
        // Kayıt bitince işlem hemen başlar. **Tek istisna:** düşük güç modu veya
        // termal baskı — o zaman otomatik başlatılmaz, kullanıcıya sorulur.
        if let reason = PowerState.deferReason() {
            deferReason = reason
            summaryNotice = reason.turkishMessage + ". " + reason.turkishDetail
            try? await store.saveSummary(meetingID, ozet: nil, topics: [])
            try? await store.markReady(meetingID)
            transcriptionStage = .done
            Log.info(.pipeline, "Özetleme ertelendi: \(reason.turkishMessage)")
            return
        }
        deferReason = nil

        let availability = intelligence.availability
        guard availability.isAvailable else {
            summaryNotice = availability.turkishMessage + ". " + availability.turkishDetail
            try? await store.saveSummary(meetingID, ozet: nil, topics: [])
            try? await store.markReady(meetingID)
            transcriptionStage = .done
            Log.warning(.intelligence, "Özetleme atlandı: \(availability.turkishMessage)")
            return
        }

        // 4 — Noktalama restorasyonu
        transcriptionStage = .punctuating(0)
        do {
            let punctuated = try await intelligence.restorePunctuation(segments) { [weak self] value in
                Task { @MainActor in self?.transcriptionStage = .punctuating(value) }
            }
            transcript = punctuated
            try? await store.replaceTranscript(meetingID, segments: punctuated)
        } catch {
            Log.warning(.intelligence, "Noktalama atlandı: \(error.localizedDescription)")
        }

        // 5 — Map-reduce özetleme
        transcriptionStage = .summarizing(0)
        do {
            let context = SummaryContext(
                meetingDate: selectedMeeting?.date ?? Date(),
                participants: calendarParticipants + [settings.userDisplayName]
                    .compactMap { $0.isEmpty ? nil : $0 },
                userName: settings.userDisplayName.isEmpty ? nil : settings.userDisplayName)
            let result = try await intelligence.summarize(transcript,
                                                          context: context) { [weak self] value in
                Task { @MainActor in self?.transcriptionStage = .summarizing(value) }
            }
            summary = result.ozet
            topics = result.topics
            if result.skippedChunks > 0 {
                // Sessiz kalite düşüşü yok: bir bölüm özetlenemediyse söylenir.
                summaryNotice = "\(result.skippedChunks) bölüm özetlenemedi; "
                    + "özet eksik olabilir. Transkript tam."
            }
            Log.info(.intelligence, "Özet hazır — \(result.ozet.kararlar.count) karar, "
                     + "\(result.ozet.aksiyonlar.count) aksiyon, "
                     + "\(result.topics.count) konu, \(result.skippedChunks) atlanan parça")
        } catch let error as OraError {
            summaryNotice = error.turkishMessage + ". " + error.turkishDetail
            Log.error(.intelligence, "Özetleme başarısız", error)
        } catch {
            summaryNotice = "Özet oluşturulamadı. Transkript korundu."
            Log.error(.intelligence, "Özetleme başarısız", error)
        }

        // Başlık önceliği: takvim etkinlik adı → Foundation Models'ın ürettiği
        // başlık → tarih/saat. Pencere başlığı **okunmaz**.
        if activeEvent == nil,
           let title = await intelligence.generateTitle(from: transcript, topics: topics) {
            try? await store.updateTitle(meetingID, title: title)
        }

        // 6 — SQLite güncelle
        try? await store.saveSummary(meetingID, ozet: summary, topics: topics)
        try? await store.markReady(meetingID)
        // Ses ancak transkript ve özet hazırken sıkıştırılır (opt-in).
        await compressAudioIfNeeded(meetingID: meetingID)
        if let reloaded = try? await store.load(meetingID) { actions = reloaded.actions }
        transcriptionStage = .done
        await refresh()

        // 7 — Kullanıcıya bildir
        if let title = meetings.first(where: { $0.id == meetingID })?.title {
            await notifications.summaryReady(title: title)
        }
    }

    /// Aksiyonu tamamlandı olarak işaretler. Ekran hemen güncellenir,
    /// yazma arkada yapılır — kutuya basınca beklemek gerekmez.
    func setActionDone(_ actionID: Int64, _ done: Bool) {
        if let index = actions.firstIndex(where: { $0.id == actionID }) {
            actions[index].isDone = done
        }
        // Pano ve toplantı görünümü aynı satırı gösterebilir; ikisi de hemen
        // güncellenir, yazma arkada yapılır.
        if let index = boardActions.firstIndex(where: { $0.id == actionID }) {
            boardActions[index].status = (done ? MeetingStore.ActionStatus.done
                                               : .pending).rawValue
        }
        Task { [store] in
            do { try await store.setActionDone(actionID, done) }
            catch { Log.error(.store, "Aksiyon durumu yazılamadı", error) }
        }
    }

    /// Ertelenen özetlemeyi kullanıcı elle başlatır.
    func summarizeNow() async {
        guard let meetingID = selection, !transcript.isEmpty else { return }
        deferReason = nil
        summaryNotice = nil
        await runIntelligence(meetingID: meetingID, segments: transcript,
                              duration: TimeInterval(selectedMeeting?.duration ?? 0))
    }

    private static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - Çökme kurtarma

    func scanForInterruptedRecordings() {
        interrupted = RecordingRecovery.scan()
    }

    func keep(_ recording: InterruptedRecording) {
        RecordingRecovery.keep(recording)
        interrupted.removeAll { $0.id == recording.id }
    }

    func discard(_ recording: InterruptedRecording) {
        RecordingRecovery.discard(recording)
        interrupted.removeAll { $0.id == recording.id }
    }
}
