import Foundation
import Observation
import AVFoundation

/// Arayüzün durum sahibi: sırayı kurar, alt katmanların ürettiğini ekrana
/// çevirir.
///
/// İşin kendisi iki yerde: `RecordingSession` kayıt sürerkenini yürütür,
/// `MeetingPipeline` kayıt bittikten sonrasını. Bu tip hangi toplantının
/// yaratılacağına, takvimle nasıl eşleşeceğine ve ne zaman hatta
/// devredileceğine karar verir — ve **yalnızca o toplantı ekrandayken**
/// üretimi yayınlanan duruma yazar (`apply(_:)`).
@MainActor
@Observable
final class RecordingController {

    // MARK: - Yayınlanan durum

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

    /// Kayıt sürerkenin durumu oturumun kendisindedir; arayüz buradan okur.
    var state: CaptureState { session.state }
    var liveSegments: [Segment] { session.liveSegments }
    var volatileText: [Int: String] { session.volatileText }
    var liveNotice: String? { session.liveNotice }
    var channelLevels: [Int: Float] { session.channelLevels }

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

    /// Aşama tipi artık Pipeline katmanının; arayüz onu bu adla kullanmaya
    /// devam eder.
    typealias Stage = PipelineStage

    /// Kalıcılığı `OraSettings` taşır — kullanıcı ayarları tek yerden okunur.
    var language: TranscriptionLanguage {
        get { settings.transcriptionLanguage }
        set { settings.transcriptionLanguage = newValue }
    }

    var modelAvailability: ModelAvailability { pipeline.modelAvailability }

    // MARK: - Bağımlılıklar

    private let intelligence: any Intelligent
    private let store: MeetingStore
    private let vocabularyStore: VocabularyStore
    let detector: MeetingDetector
    let calendar: CalendarReader
    private let notifications: MeetingNotifications
    private let settings: OraSettings

    /// Kayıt sürerken: ses yazımı + canlı transkripsiyon (REFACTOR.md Adım 3).
    let session: RecordingSession
    /// Kayıt bittikten sonra: tam geçiş, noktalama, özet, depolama
    /// (REFACTOR.md Adım 1-2).
    private let pipeline: MeetingPipeline

    private var refreshTask: Task<Void, Never>?

    /// - Parameters:
    ///   - detector, calendar: `settings`'e bağlı oldukları için varsayılan
    ///     değer veremezler; `nil` verilirse burada kurulurlar.
    ///   - notifications: testte de gerçek tip verilir — izin alınmadığı için
    ///     `prepare()` çağrılmadıkça hiçbir bildirim gönderilmez.
    ///   - deferReason, prepareLocale: hatta iletilir; ikisi de dış dünyaya
    ///     (`ProcessInfo`, Speech varlıkları) dokunur ve testte kapatılır.
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
         prepareLocale: MeetingPipeline.LocalePreparation? = nil) {
        self.session = RecordingSession(capture: capture)
        self.intelligence = intelligence
        self.settings = settings
        self.notifications = notifications
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
        self.pipeline = MeetingPipeline(store: self.store,
                                        vocabularyStore: self.vocabularyStore,
                                        transcription: transcription,
                                        intelligence: intelligence, settings: settings,
                                        deferReason: deferReason,
                                        prepareLocale: prepareLocale)

        // Hattın **tek** tüketicisi burası. Süzme `apply(_:)` içinde yapılır;
        // hat hangi toplantının ekranda olduğunu bilmez.
        pipeline.observe { [weak self] event in self?.apply(event) }
        session.onError = { [weak self] error in self?.error = error }
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

    var micOnlyReason: String? { session.micOnlyReason }

    var displayedSegments: [Segment] {
        transcript.isEmpty ? liveSegments : transcript
    }

    /// Hat **herhangi bir** toplantı için koşuyor mu. Yetki kapıları (düzeltme,
    /// elle özetleme, yeniden dene) buna bakar: ikinci bir hat aynı Speech ve
    /// Foundation Models yolunu paylaşır.
    var isTranscribing: Bool { pipeline.isRunning }

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
            session.clearLive()
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
            audioURL = MeetingPipeline.existingAudio(loaded.meeting)
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

        // Ses yazımı başlamazsa yarım toplantı satırı bırakılmaz.
        do {
            try await session.start(meetingID: meetingID, preferredApp: preferredApp)
        } catch {
            try? await store.delete(meetingID)
            self.error = error as? OraError ?? .audioWriteFailed(underlying: error)
            return
        }
        detector.recordingStarted(bundleID: signal?.bundleID ?? preferredApp)
        await refresh()
        // Canlı transkripsiyon **ikincil** iştir ve kayıt başladıktan sonra
        // açılır; hata verirse kayıt kesintisiz sürer (CLAUDE.md kural #2).
        await session.startLive(locale: language.locale ?? Locale(identifier: "tr-TR"),
                                vocabulary: (try? await vocabularyStore.activeWords()) ?? [])
    }

    func stop() async {
        guard isRecording, let meetingID = session.meetingID else { return }
        do {
            let url = try await session.stop()
            let duration = Self.duration(of: url)
            try? await store.markProcessing(meetingID, audioPath: url, duration: duration)
            await refresh()
            await pipeline.fullPass(meetingID: meetingID, url: url)
        } catch {
            Log.error(.capture, "Kayıt kapatılamadı", error)
            self.error = error as? OraError ?? .audioWriteFailed(underlying: error)
        }
        detector.recordingStopped()
        await refresh()
    }

    private func clearDisplayed() {
        transcript = []
        session.clearLive()
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

    // MARK: - İşlem hattı (sıra CLAUDE.md'de sabittir)

    /// Başarısız veya yarım kalmış bir toplantıyı elle yeniden işler.
    /// Ham ses diskte durduğu için kayıt tekrarlanmaz — hat baştan koşar.
    func retryProcessing() async {
        guard let meetingID = selection, let url = retryableAudio,
              !isRecording, !isTranscribing else { return }
        Log.info(.pipeline, "İşlem elle yeniden başlatıldı — toplantı \(meetingID)")
        retryableAudio = nil
        try? await store.markProcessing(meetingID, audioPath: url,
                                        duration: Self.duration(of: url))
        await refresh()
        await pipeline.fullPass(meetingID: meetingID, url: url)
        if onScreen(meetingID), transcript.isEmpty { retryableAudio = url }
        await refresh()
    }

    // MARK: - Hattın olayları → arayüz durumu

    /// Hattın ürettiği her şey buradan geçer. **Süzmenin tek yeri budur:**
    /// eskiden hat 15 ayrı noktada `onScreen(_:)` sorup yayınlanan duruma
    /// kendisi yazıyordu; unutulan her kapı, A'nın özetinin B'nin ekranına
    /// düşmesi demekti (RESEARCH.md §27, REFACTOR.md §2).
    private func apply(_ event: PipelineEvent) {
        switch event.kind {

        // Seçimden **bağımsız**: hangi toplantı ekranda olursa olsun işlenir.
        case .stage(let stage):
            stages[event.meetingID] = stage
        case .failed(let error):
            self.error = error
        case .storeChanged:
            refreshStorage()
            scheduleRefresh()
        case .finished(let title):
            Task { await self.notifications.summaryReady(title: title) }

        // Buradan aşağısı **arayüz içeriğidir**: yalnızca o toplantı
        // ekrandayken yazılır. Veritabanına her hâlükârda yazıldı; kullanıcı
        // geri döndüğünde `load(_:)` oradan okur.
        default:
            guard onScreen(event.meetingID) else { return }
            display(event.kind)
        }
    }

    private func display(_ kind: PipelineEvent.Kind) {
        switch kind {
        case .transcript(let segments):
            // Tam geçiş nihai gerçektir; canlı ön izleme bırakılır.
            transcript = segments
            session.clearLive()
        case .summary(let ozet, let topics):
            summary = ozet
            self.topics = topics
        case .actions(let actions):
            self.actions = actions
        case .audio(let url):
            audioURL = url
            // Sıkıştırma dosyanın yerini değiştirdiyse "Yeniden dene" de artık
            // yeni dosyayı işler. `retryableAudio` boşsa dokunulmaz: hattın
            // başında yayılan ses olayı düğmeyi yoktan var etmemeli.
            if retryableAudio != nil { retryableAudio = url }
        case .notice(let text):
            summaryNotice = text
        case .deferred(let reason):
            deferReason = reason
        case .deferCleared:
            deferReason = nil
        case .retryable(let url):
            retryableAudio = url
        case .stage, .failed, .storeChanged, .finished:
            break   // `apply(_:)` bunları seçimden bağımsız işledi
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
        await pipeline.summarize(meetingID: meetingID, segments: transcript)
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
        await pipeline.summarize(meetingID: meetingID, segments: transcript,
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
