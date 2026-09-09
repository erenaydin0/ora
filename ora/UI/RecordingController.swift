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

    /// Bildirim izni yoksa Türkçe not. Öneri yine gelir ama yalnızca
    /// penceredeki şeritte görünür; kullanıcı bunu bilmeli.
    private(set) var notificationProblem: String?

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

    /// Aşama **toplantı başına** tutulur. Tek bir genel aşama, kullanıcı işlem
    /// sürerken başka bir toplantıya geçtiğinde animasyonu o toplantının
    /// ekranına taşıyordu; geri dönüldüğünde de aşama veritabanının yarım
    /// hâlinden türetildiği için (segmentler yazılmış, özet henüz üretiliyor)
    /// animasyon kayboluyordu. Sözlükte kayıt yoksa aşama `.idle`'dır.
    private(set) var stages: [Int64: Stage] = [:]

    /// Seçili toplantının aşaması — `ProcessingState` bunu gösterir.
    var transcriptionStage: Stage { selection.flatMap { stages[$0] } ?? .idle }

    enum Stage: Equatable {
        case idle
        case preparingLanguage
        case downloadingLanguage(Double)
        case transcribing(Double)
        case punctuating(Double)
        case summarizing(Double)
        case done

        /// Hat koşuyor mu. `.idle` ve `.done` ikisi de "koşmuyor" demektir;
        /// arayüz bu ikisini ayırt etmez.
        var isActive: Bool {
            switch self {
            case .idle, .done: false
            default: true
            }
        }
    }

    /// Kalıcılığı `OraSettings` taşır — kullanıcı ayarları tek yerden okunur.
    var language: TranscriptionLanguage {
        get { settings.transcriptionLanguage }
        set { settings.transcriptionLanguage = newValue }
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
    private let notifications: MeetingNotifications
    private let settings: OraSettings
    /// Tam geçiş öncesi dil paketi hazırlığı. Gerçek Speech varlıklarına
    /// dokunduğu için testte devre dışı bırakılır — yoksa ölçüm makinede
    /// kurulu dil paketlerine bağımlı olur.
    typealias LocalePreparation =
        @Sendable (Locale, @escaping @Sendable (Double) -> Void) async throws -> Void

    static let defaultLocalePreparation: LocalePreparation = { locale, progress in
        let module = SpeechTranscription.makeTranscriber(locale: locale, live: false)
        try await TranscriptionLocale.ensureInstalled(locale, module: module,
                                                      progress: progress)
    }

    private let prepareLocale: LocalePreparation
    /// Güç/termal ertelemesinin kaynağı. Varsayılanı `PowerState.deferReason`;
    /// testler kendi değerini verir — `isLowPowerModeEnabled` dışarıdan
    /// ayarlanamaz ve o hâlde bu dal hiç ölçülemezdi.
    private let deferReasonProvider: @Sendable () -> PowerState.DeferReason?

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

    /// - Parameters:
    ///   - detector, calendar: `settings`'e bağlı oldukları için varsayılan
    ///     değer veremezler; `nil` verilirse burada kurulurlar.
    ///   - notifications: testte de gerçek tip verilir — izin alınmadığı için
    ///     `prepare()` çağrılmadıkça hiçbir bildirim gönderilmez.
    init(capture: any AudioCapturing = AudioCapture(),
         transcription: any Transcribing = SpeechTranscription(),
         intelligence: any Intelligent = FoundationIntelligence(),
         database: OraDatabase? = nil,
         settings: OraSettings = .shared,
         detector: MeetingDetector? = nil,
         calendar: CalendarReader? = nil,
         notifications: MeetingNotifications = MeetingNotifications(),
         deferReason: @escaping @Sendable () -> PowerState.DeferReason?
            = PowerState.deferReason,
         prepareLocale: LocalePreparation? = nil) {
        self.capture = capture
        self.transcription = transcription
        self.intelligence = intelligence
        self.settings = settings
        self.notifications = notifications
        self.deferReasonProvider = deferReason
        self.prepareLocale = prepareLocale ?? Self.defaultLocalePreparation
        self.detector = detector ?? MeetingDetector(settings: settings)
        self.calendar = calendar ?? CalendarReader(settings: settings)

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
        // Veri dizini değiştiyse (sandbox göçü) ses yolları eski konumu
        // gösterir; dosya yeni yerdeyse satır düzeltilir.
        if let repaired = try? await store.repairAudioPaths(), repaired > 0 {
            await refresh()
        }
        await refreshVocabulary()
        await refreshUpcoming()
        await purgeExpiredAudio()
        refreshStorage()
        Task { [weak self] in
            guard let self else { return }
            await notifications.prepare()
            notificationProblem = notifications.problem
        }
    }

    /// Kullanıcı Sistem Ayarları'ndan bildirimi açmış olabilir — pencere öne
    /// geldiğinde ve Ayarlar açıldığında yeniden bakılır.
    func refreshNotificationPermission() async {
        await notifications.refresh()
        notificationProblem = notifications.problem
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
    ///
    /// Dosya yolu toplantı kaydından okunur, `audioURL`'den değil: `audioURL`
    /// **seçili** toplantıya aittir ve kullanıcı işlem sürerken başka bir
    /// toplantıya geçtiyse yanlış dosyayı sıkıştırırdı.
    private func compressAudioIfNeeded(_ meeting: MeetingRecord) async {
        guard settings.compressAudio, let meetingID = meeting.id,
              let url = Self.existingAudio(meeting),
              url.pathExtension.lowercased() == "wav" else { return }
        do {
            let compressed = try await AudioArchive.compress(url)
            try? await store.setAudioPath(meetingID, path: compressed.path(percentEncoded: false))
            // Oynatıcı seçili toplantıya bağlıdır; yol yalnızca sıkıştırılan
            // toplantı ekrandayken tazelenir.
            if onScreen(meetingID) {
                audioURL = compressed
                if retryableAudio != nil { retryableAudio = compressed }
            }
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
                        ? self.calendar.candidates(at: Date(), app: signal.bundleID,
                                                   windowTitles: WindowTitle.titles(for: signal.bundleID))
                            .first?.event
                        : nil
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

    /// Hat **herhangi bir** toplantı için koşuyor mu. Yetki kapıları (düzeltme,
    /// elle özetleme, yeniden dene) buna bakar: ikinci bir hat aynı Speech ve
    /// Foundation Models yolunu paylaşır.
    var isTranscribing: Bool { stages.values.contains { $0.isActive } }

    /// İşlem animasyonu ekranda görünür mü — yalnızca **işlenen toplantı
    /// seçiliyken**. Arayüz buna bakar, kapılar `isTranscribing`'e; ikisi
    /// ayrılmazsa A işlenirken B'nin ekranında A'nın animasyonu belirir.
    var isProcessingSelected: Bool { transcriptionStage.isActive }

    /// Hattın ürettiği içerik arayüze yazılmalı mı? Kullanıcı başka bir
    /// toplantıya geçtiyse üretim yalnızca veritabanına gider; ekranda seçili
    /// toplantı durmaya devam eder.
    private func onScreen(_ meetingID: Int64) -> Bool { selection == meetingID }

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

    /// Başka bir toplantı işlenirken bu toplantı özetlenemez (tek hat). Düğmenin
    /// sessizce kaybolması bir açıklama değildir; sebebi Türkçe söylenir.
    var busyNotice: String? {
        guard isTranscribing, !isProcessingSelected, summary == nil,
              !transcript.isEmpty, modelAvailability.isAvailable else { return nil }
        return "Başka bir toplantı işleniyor. O bitince bu toplantı özetlenebilir."
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
            // Okuma asenkron: bu arada kullanıcı başka bir toplantıya geçmiş
            // olabilir. Geç gelen sonuç yeni seçimin üstüne yazılmaz — hızlı
            // git-gel'de iki yükleme yarışıyordu.
            guard selection == meetingID else { return }
            transcript = loaded.segments
            liveSegments = []
            summary = loaded.summary
            topics = loaded.topics
            actions = loaded.actions
            summaryNotice = nil
            // Erteleme nedeni seçili toplantıya aittir; taşınırsa başka bir
            // toplantının ekranında "Şimdi özetle" belirir.
            deferReason = nil
            // Aşama burada **kurulmaz**: hattın kendi kaydı (`stages`) tek
            // kaynaktır. Eskiden veritabanının yarım hâlinden türetiliyordu ve
            // işlenmekte olan toplantıya dönüldüğünde animasyon kayboluyordu.
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
            stages[meetingID] = nil
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

    /// Transkript satırını siler. Ham ses duruyorsa "Yeniden dene" ile
    /// transkript baştan üretilebilir; bu yüzden geri alınamaz bir kayıp değil.
    func deleteSegment(_ segment: Segment) async {
        guard let meetingID = selection else { return }
        do {
            try await store.deleteSegment(meetingID: meetingID, segment: segment)
            await load(meetingID)
        } catch {
            Log.error(.store, "Satır silinemedi", error)
        }
    }

    /// Konuşmacı etiketini değiştirir (kanal değişmez).
    func setSpeaker(_ segment: Segment, to speaker: String) async {
        guard let meetingID = selection else { return }
        do {
            try await store.setSpeaker(meetingID: meetingID, segment: segment, speaker: speaker)
            await load(meetingID)
        } catch {
            Log.error(.store, "Konuşmacı değiştirilemedi", error)
        }
    }

    /// Kayıt başlarken hangi takvim toplantısında olduğumuz **kesinleşmediyse**
    /// adaylar burada durur ve arayüz sorar. Çakışan iki toplantıda tahmin
    /// yürütmek yanlış katılımcı listesi yazmak demek; boş bırakmak daha iyidir.
    private(set) var eventChoices: [MeetingEvent] = []
    private var choiceMeetingID: Int64?

    /// Takvim eşleşmesini seçer ya da "hiçbiri" der.
    func chooseEvent(_ event: MeetingEvent?) async {
        let meetingID = choiceMeetingID
        eventChoices = []
        choiceMeetingID = nil
        guard let meetingID, let event else { return }
        await relinkEvent(meetingID, to: event)
    }

    /// Yanlış eşleşen (ya da hiç eşleşmemiş) bir toplantının takvim bağını
    /// sonradan düzeltir. Eski takvim katılımcıları silinir, yenisi yazılır.
    func relinkEvent(_ meetingID: Int64, to event: MeetingEvent?) async {
        do {
            if let event {
                try await store.relinkCalendarEvent(meetingID, event: event)
                // Sözlük **yalnızca seçim kesinleşince** beslenir: belirsizken
                // iki adayın adlarını da eklemek sözlüğü şişirir ve tanıma
                // kalitesini düşürür (ölçüm: CLAUDE.md, count = 30).
                try? await vocabularyStore.addCalendarNames(event.attendees)
                await refreshVocabulary()
                Log.info(.calendar, "Takvim bağı: toplantı \(meetingID) → \(event.title)")
            } else {
                try await store.unlinkCalendarEvent(meetingID)
                Log.info(.calendar, "Takvim bağı kaldırıldı: toplantı \(meetingID)")
            }
            if selection == meetingID { await load(meetingID) }
            await refresh()
        } catch {
            Log.error(.calendar, "Takvim bağı değiştirilemedi", error)
        }
    }

    /// Bir toplantının tarihine denk gelen takvim etkinlikleri — kullanıcı
    /// sonradan doğrusunu seçebilsin diye.
    func eventChoices(for meeting: MeetingListItem) -> [MeetingEvent] {
        guard settings.calendarEnabled else { return [] }
        return calendar.candidates(at: meeting.date).map(\.event)
    }

    /// Kayıt başlarken takvim eşleştirmesi. Tepe aday açık ara öndeyse bağlanır,
    /// değilse soru arayüze bırakılır.
    private func matchCalendar(meetingID: Int64, app: String?) async -> MeetingEvent? {
        guard settings.calendarEnabled else { return nil }
        let titles = app.map { WindowTitle.titles(for: $0) } ?? []
        let matches = calendar.candidates(at: Date(), app: app, windowTitles: titles)
        guard let best = matches.first else { return nil }

        let runnerUp = matches.dropFirst().first?.score
        if let runnerUp, best.score - runnerUp < CalendarReader.decisiveMargin {
            eventChoices = Array(matches.prefix(3).map(\.event))
            choiceMeetingID = meetingID
            Log.info(.calendar, "Takvim belirsiz (\(matches.count) aday, "
                     + "puanlar \(matches.map(\.score))) — kullanıcıya soruluyor"
                     + (titles.isEmpty
                        ? " · pencere başlığı okunamadı (Erişilebilirlik yok)" : ""))
            return nil
        }
        Log.info(.calendar, "Takvim eşleşmesi: \(best.event.title) — puan \(best.score)"
                 + (best.reasons.isEmpty ? "" : " (\(best.reasons.joined(separator: ", ")))"))
        return best.event
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
        eventChoices = []
        choiceMeetingID = nil
        let event = await matchCalendar(meetingID: meetingID, app: signal?.bundleID)
        if let event {
            try? await store.linkCalendarEvent(meetingID, event: event)
            // Katılımcı adları sözlüğe beslenir — özel isim tanımanın en
            // zayıf noktasıdır, takvimin en somut teknik kazancı budur.
            try? await vocabularyStore.addCalendarNames(event.attendees)
            await refreshVocabulary()
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
        // Hat hangi yoldan çıkarsa çıksın aşama açık kalmaz: takılı bir
        // animasyon, hata mesajından daha kötü bir hata modudur.
        defer { if stages[meetingID]?.isActive == true { stages[meetingID] = .done } }
        // Ses artık diskte; oynatıcı toplantıyı yeniden seçmeye gerek kalmadan
        // bu kayda bağlanabilir. Ekranda başka toplantı varsa oynatıcı onunkine
        // bağlı kalır.
        if onScreen(meetingID) { audioURL = url }
        stages[meetingID] = .preparingLanguage
        let locale: Locale
        if let chosen = language.locale {
            locale = chosen
        } else {
            locale = await TranscriptionLocale.detect(url: url, channel: .mic)
        }

        do {
            Log.debug(.transcribe, "Tam geçiş: dil hazırlanıyor (\(locale.identifier))")
            try await prepareLocale(locale) { [weak self] value in
                Task { @MainActor in self?.stages[meetingID] = .downloadingLanguage(value) }
            }
            stages[meetingID] = .transcribing(0)
            let words = (try? await vocabularyStore.activeWords()) ?? []
            Log.debug(.transcribe, "Tam geçiş: \(words.count) sözlük terimi, ses açılıyor")
            let segments = try await transcription.transcribe(
                url: url, locale: locale, vocabulary: words
            ) { [weak self] value in
                Task { @MainActor in self?.stages[meetingID] = .transcribing(value) }
            }
            if onScreen(meetingID) {
                transcript = segments
                liveSegments = []
            }
            try? await store.replaceTranscript(meetingID, segments: segments)
            Log.info(.transcribe, "Tam geçiş bitti — \(segments.count) segment, "
                     + "\(locale.identifier)")
            await runIntelligence(meetingID: meetingID, segments: segments, duration: duration)
        } catch let error as OraError {
            stages[meetingID] = .idle
            Log.error(.transcribe, "Tam geçiş başarısız (\(locale.identifier))", error)
            // "Yeniden dene" seçili toplantının sesini işler; başka toplantı
            // ekrandayken bu yol oraya iliştirilirse düğme yanlış sesi işler.
            if onScreen(meetingID) { retryableAudio = url }
            self.error = error
        } catch {
            stages[meetingID] = .idle
            Log.error(.transcribe, "Tam geçiş başarısız (\(locale.identifier))", error)
            if onScreen(meetingID) { retryableAudio = url }
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
        if onScreen(meetingID), transcript.isEmpty { retryableAudio = url }
        await refresh()
    }

    /// Ses dosyası hâlâ diskte mi?
    private static func existingAudio(_ meeting: MeetingRecord) -> URL? {
        guard let path = meeting.audioPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func runIntelligence(meetingID: Int64, segments: [Segment],
                                 duration: TimeInterval,
                                 variation: Bool = false) async {
        // Hangi yoldan çıkılırsa çıkılsın aşama açık kalmaz.
        defer { if stages[meetingID]?.isActive == true { stages[meetingID] = .done } }

        // Kayıt bitince işlem hemen başlar. **Tek istisna:** düşük güç modu veya
        // termal baskı — o zaman otomatik başlatılmaz, kullanıcıya sorulur.
        if let reason = deferReasonProvider() {
            if onScreen(meetingID) {
                deferReason = reason
                summaryNotice = reason.turkishMessage + ". " + reason.turkishDetail
            }
            try? await store.saveSummary(meetingID, ozet: nil, topics: [])
            try? await store.markReady(meetingID)
            stages[meetingID] = .done
            Log.info(.pipeline, "Özetleme ertelendi: \(reason.turkishMessage)")
            return
        }
        if onScreen(meetingID) { deferReason = nil }

        let availability = intelligence.availability
        guard availability.isAvailable else {
            if onScreen(meetingID) {
                summaryNotice = availability.turkishMessage + ". "
                    + availability.turkishDetail
            }
            try? await store.saveSummary(meetingID, ozet: nil, topics: [])
            try? await store.markReady(meetingID)
            stages[meetingID] = .done
            Log.warning(.intelligence, "Özetleme atlandı: \(availability.turkishMessage)")
            return
        }

        // 4 — Noktalama restorasyonu
        //
        // Hattın beslendiği metin **yereldir**. Yayınlanan `transcript` seçili
        // toplantınındır: kullanıcı işlem sürerken başka bir toplantıya geçerse
        // o değişir ve özet yanlış toplantının metninden üretilirdi.
        var working = segments
        stages[meetingID] = .punctuating(0)
        do {
            let punctuated = try await intelligence.restorePunctuation(segments) { [weak self] value in
                Task { @MainActor in self?.stages[meetingID] = .punctuating(value) }
            }
            working = punctuated
            if onScreen(meetingID) { transcript = punctuated }
            try? await store.replaceTranscript(meetingID, segments: punctuated)
        } catch {
            Log.warning(.intelligence, "Noktalama atlandı: \(error.localizedDescription)")
        }

        // 5 — Map-reduce özetleme
        stages[meetingID] = .summarizing(0)
        // Tarih ve katılımcılar da **işlenen** toplantıdan okunur; ekrandaki
        // toplantıdan alınırsa son tarihler yanlış güne bağlanır.
        let processed = meetings.first { $0.id == meetingID }
        let people = (try? await store.calendarParticipants(meetingID)) ?? []
        var produced: Ozet?
        var producedTopics: [TopicSegment] = []
        do {
            let context = SummaryContext(
                meetingDate: processed?.date ?? Date(),
                participants: people + [settings.userDisplayName]
                    .compactMap { $0.isEmpty ? nil : $0 },
                userName: settings.userDisplayName.isEmpty ? nil : settings.userDisplayName)
            let result = try await intelligence.summarize(
                working, context: context, variation: variation) { [weak self] value in
                Task { @MainActor in self?.stages[meetingID] = .summarizing(value) }
            }
            produced = result.ozet
            producedTopics = result.topics
            // Üretim ekrana yalnızca o toplantı seçiliyken yazılır; başka
            // toplantıya geçilmişse sonuç veritabanına gider ve kullanıcı geri
            // döndüğünde oradan okunur.
            if onScreen(meetingID) {
                summary = result.ozet
                topics = result.topics
                if result.skippedChunks > 0 {
                    // Sessiz kalite düşüşü yok: bir bölüm özetlenemediyse söylenir.
                    summaryNotice = "\(result.skippedChunks) bölüm özetlenemedi; "
                        + "özet eksik olabilir. Transkript tam."
                }
            }
            Log.info(.intelligence, "Özet hazır — \(result.ozet.kararlar.count) karar, "
                     + "\(result.ozet.aksiyonlar.count) aksiyon, "
                     + "\(result.topics.count) konu, \(result.skippedChunks) atlanan parça")
        } catch let error as OraError {
            if onScreen(meetingID) {
                summaryNotice = error.turkishMessage + ". " + error.turkishDetail
            }
            Log.error(.intelligence, "Özetleme başarısız", error)
        } catch {
            if onScreen(meetingID) {
                summaryNotice = "Özet oluşturulamadı. Transkript korundu."
            }
            Log.error(.intelligence, "Özetleme başarısız", error)
        }

        // Başlık önceliği: takvim etkinlik adı → Foundation Models'ın ürettiği
        // başlık → tarih/saat. Pencere başlığı **okunmaz**.
        //
        // Yeniden özetlemede başlık **üretilmez**: toplantının adı zaten var ve
        // kullanıcı onu elle değiştirmiş olabilir. Özeti beğenmeyip yeniden
        // ürettiğinde adının da değişmesi beklenmedik bir kayıptır.
        if activeEvent == nil, !variation,
           let title = await intelligence.generateTitle(from: working, topics: producedTopics) {
            try? await store.updateTitle(meetingID, title: title)
        }

        // 6 — SQLite güncelle. Üretim başarısızsa (`produced == nil`) eldeki
        // özet **korunur**: yeniden üretim denemesi var olan özeti, konuları ve
        // işaretlenmiş aksiyonları silmez. `variation` yalnızca özeti olan bir
        // toplantıda açılabilir (`canResummarize`).
        if produced != nil || !variation {
            try? await store.saveSummary(meetingID, ozet: produced, topics: producedTopics)
        }
        try? await store.markReady(meetingID)
        let reloaded = try? await store.load(meetingID)
        // Ses ancak transkript ve özet hazırken sıkıştırılır (opt-in).
        // Sıkıştırılacak dosya **işlenen toplantınındır**; `audioURL` seçili
        // toplantıya ait olduğu için oradan okunmaz.
        if let record = reloaded?.meeting { await compressAudioIfNeeded(record) }
        if onScreen(meetingID), let reloaded { actions = reloaded.actions }
        stages[meetingID] = .done
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
        // Hat koşarken ikinci bir hat başlatılmaz: ikisi aynı aşamayı ve aynı
        // Foundation Models yolunu paylaşıyor.
        guard let meetingID = selection, !transcript.isEmpty,
              !isRecording, !isTranscribing else { return }
        deferReason = nil
        summaryNotice = nil
        await runIntelligence(meetingID: meetingID, segments: transcript,
                              duration: TimeInterval(selectedMeeting?.duration ?? 0))
    }

    /// Var olan özeti beğenmediyse kullanıcı yeniden ürettirir.
    ///
    /// Aynı istemle koşmak çoğu zaman aynı özeti verir; bu yüzden örnekleme
    /// serbestleştirilir (`variation`). Aksiyonlar yeniden üretildiği için
    /// **işaretlenmiş olanların durumu sıfırlanır** — arayüz bunu soruyor.
    func resummarize() async {
        guard canResummarize, let meetingID = selection else { return }
        Log.info(.intelligence, "Özet yeniden üretiliyor — toplantı \(meetingID)")
        deferReason = nil
        summaryNotice = nil
        await runIntelligence(meetingID: meetingID, segments: transcript,
                              duration: TimeInterval(selectedMeeting?.duration ?? 0),
                              variation: true)
    }

    /// Özet var ve yeniden üretilebilir durumda mı?
    var canResummarize: Bool {
        summary != nil && !isRecording && !isTranscribing && !transcript.isEmpty
            && modelAvailability.isAvailable
    }

    /// Tamamlandı işaretli aksiyon var mı — yeniden üretim bunları sıfırlar,
    /// o yüzden önce sorulur.
    var hasCompletedActions: Bool { actions.contains { $0.isDone } }

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
