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
@Observable
final class RecordingController {

    // MARK: - Yayınlanan durum

    private(set) var interrupted: [InterruptedRecording] = []
    var error: OraError?

    /// Kayıt sürerkenin durumu oturumun, liste ve seçili toplantının içeriği
    /// kütüphanenin. Arayüz yüzeyi değişmedi: aşağıdaki geçirgenler eskiden
    /// bu tipin kendi alanlarıydı.
    var state: CaptureState { session.state }
    var liveSegments: [Segment] { session.liveSegments }
    var volatileText: [Int: String] { session.volatileText }
    var liveNotice: String? { session.liveNotice }

    var meetings: [MeetingListItem] { library.meetings }
    var searchSnippets: [Int64: String] { library.searchSnippets }
    var searchText: String {
        get { library.searchText }
        set { library.searchText = newValue }
    }
    var selection: Int64? {
        get { library.selection }
        set { library.selection = newValue }
    }
    var showsActionBoard: Bool {
        get { library.showsActionBoard }
        set { library.showsActionBoard = newValue }
    }
    var boardActions: [BoardAction] { library.boardActions }
    var openActionCount: Int { library.openActionCount }
    var transcript: [Segment] { library.transcript }
    var summary: Ozet? { library.summary }
    var topics: [TopicSegment] { library.topics }
    var actions: [MeetingAction] { library.actions }
    var summaryNotice: String? { library.summaryNotice }
    var deferReason: PowerState.DeferReason? { library.deferReason }
    var audioURL: URL? { library.audioURL }
    var retryableAudio: URL? { library.retryableAudio }
    var calendarParticipants: [String] { library.calendarParticipants }
    /// Transkriptte adı verilmiş konuşmacılar — Özet'teki Kişiler bölümü
    /// davetlilerden ayrı gösterir.
    var speakingParticipants: [String] { library.speakingParticipants }
    /// Adlandırma menüsünün adayları.
    var speakerCandidates: [String] { library.speakerCandidates }
    var chatTurns: [MeetingStore.ChatTurn] { library.chatTurns }

    /// Kullanıcının kendi adı — "Bana düşenler" grubu buna bakar.
    var userDisplayName: String { settings.userDisplayName }

    /// Veritabanı açılamadıysa kullanıcıya söylenecek not.
    private(set) var storageNotice: String?

    /// Bildirim izni yoksa Türkçe not. Öneri yine gelir ama yalnızca
    /// penceredeki şeritte görünür; kullanıcı bunu bilmeli.
    private(set) var notificationProblem: String?

    /// Kayıtlar dizininin toplam boyutu — Ayarlar'daki Depolama bölümü.
    private(set) var audioBytes: Int64 = 0

    /// Algılamadan gelen öneri; kullanıcı karar verene kadar durur.
    var pendingSignal: MeetingSignal? { suggestions.pendingSignal }
    /// Toplantı uygulaması mikrofonu 30 sn'den uzun bıraktı.
    var suggestsStop: Bool { suggestions.suggestsStop }
    private(set) var isAnswering = false
    /// Sözlük onayı bekleyen kelimeler dahil tüm sözlük.
    private(set) var vocabulary: [VocabularyStore.Word] = []
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
    let calendar: CalendarReader
    /// Algılama → öneri → karar zinciri (REFACTOR.md Adım 4).
    private let suggestions: MeetingSuggestions
    private let notifications: MeetingNotifications
    private let settings: OraSettings

    /// Liste, arama, seçim ve seçili toplantının ekrandaki içeriği
    /// (REFACTOR.md Adım 5). "Ekranda ne var" bilgisinin sahibi orası.
    private let library: MeetingLibrary
    /// Kayıt sürerken: ses yazımı + canlı transkripsiyon (REFACTOR.md Adım 3).
    let session: RecordingSession
    /// Kayıt bittikten sonra: tam geçiş, noktalama, özet, depolama
    /// (REFACTOR.md Adım 1-2).
    private let pipeline: MeetingPipeline

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
        let resolvedDetector = detector ?? MeetingDetector(settings: settings)
        // Pencere başlığını okuyan `WindowTitle` `ora/Detect/` altında; Calendar
        // ona doğrudan bağlanmaz, çağrı buradan geçirilir.
        let resolvedCalendar = calendar
            ?? CalendarReader(settings: settings,
                              windowTitles: { WindowTitle.titles(for: $0) })
        self.calendar = resolvedCalendar
        // Takvim zenginleştirmesi **closure ile** verilir: `MeetingSuggestions`
        // böylece Calendar'a bağlanmaz (ARCHITECTURE.md, bağımlılık yönü).
        self.suggestions = MeetingSuggestions(
            detector: resolvedDetector, notifications: notifications, settings: settings,
            matchingEvent: { [resolvedCalendar] signal in
                resolvedCalendar.bestGuess(at: Date(), app: signal.bundleID)
            })

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
        let store = self.store
        let session = self.session
        self.library = MeetingLibrary(store: store,
                                      isRecording: { session.isRecording },
                                      clearLivePreview: { session.clearLive() })
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
        // Öneri kabul edildi (şerit, menü bar, bildirim ya da "her zaman
        // kaydet") — kaydı başlatan taraf burasıdır.
        suggestions.onRecord = { [weak self] signal in
            Task { @MainActor in await self?.start(signal: signal) }
        }
        library.onError = { [weak self] error in self?.error = error }
        // Düzeltmeden çıkan özel isimler sözlüğe **aday** olur; kullanıcı
        // onaylamadan transkripsiyona verilmez. Kütüphane sözlüğe dokunmaz.
        library.onCorrection = { [weak self] mistake, correct in
            Task { @MainActor in
                try? await self?.vocabularyStore.proposeFromCorrection(mistake: mistake,
                                                                       correct: correct)
                await self?.refreshVocabulary()
            }
        }
        // Konuşmacıya verilen ad **doğrudan** sözlüğe girer, aday olarak
        // değil: adı kullanıcı yazdı, onaylatacak bir tahmin yok. Takvim
        // katılımcılarıyla aynı yol.
        library.onSpeakerNamed = { [weak self] name in
            Task { @MainActor in
                try? await self?.vocabularyStore.add(name, source: "speaker")
                await self?.refreshVocabulary()
            }
        }
    }

    // MARK: - Toplantı algılama

    /// Öneri reddedildi — bu uygulama için soğuma başlar.
    func dismissSuggestion() { suggestions.dismiss() }

    /// Arayüzdeki öneri şeridinden ya da menü bardan kayıt.
    func startFromSuggestion() { suggestions.accept() }

    /// "Bu uygulamayı hep kaydet" — ayarı yazar, öneri duruyorsa kayıt başlar.
    func alwaysRecord(_ bundleID: String) { suggestions.alwaysRecord(bundleID: bundleID) }

    /// Ayarlardan algılamayı açıp kapatma.
    func setDetectionEnabled(_ enabled: Bool) { suggestions.setEnabled(enabled) }

    /// Uygulama açılışında bir kez.
    ///
    /// Algılama **bildirim iznini beklemez**: bildirim izni istemi kullanıcı
    /// yanıtlayana kadar askıda kalır ve beklenirse algılama hiç başlamaz.
    /// İzin verilmese bile öneri arayüzde görünür.
    func startServices() async {
        suggestions.start()
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
            await library.reload()
        }
        refreshStorage()
    }

    /// Kullanıcının isteğiyle tek bir kaydın sesini siler.
    func deleteAudio(_ meetingID: Int64) async {
        let files = (try? await store.audioFiles()) ?? []
        guard let file = files.first(where: { $0.id == meetingID }) else { return }
        AudioArchive.delete(file.path)
        try? await store.setAudioPath(meetingID, path: nil)
        if library.isOnScreen(meetingID) { await library.reload() }
        refreshStorage()
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
        guard selection != nil, !transcript.isEmpty, !isAnswering else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isAnswering = true
        defer { isAnswering = false }
        do {
            let answer = try await intelligence.answer(question: trimmed, over: transcript)
            await library.appendChat(question: trimmed, answer: answer)
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

    var selectedMeeting: MeetingListItem? { library.selectedMeeting }

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

    // MARK: - Liste (kütüphaneye devredildi — REFACTOR.md Adım 5)

    func refresh() async { await library.refresh() }
    /// Panodan kaynak toplantıya git.
    func openMeeting(_ meetingID: Int64) { library.openMeeting(meetingID) }
    func rename(_ meetingID: Int64, to title: String) async {
        await library.rename(meetingID, to: title)
    }
    func correct(_ segment: Segment, to text: String) async {
        await library.correct(segment, to: text)
    }
    func deleteSegment(_ segment: Segment) async { await library.deleteSegment(segment) }
    func setSpeaker(_ segment: Segment, to speaker: String) async {
        await library.setSpeaker(segment, to: speaker)
    }
    func setSpeaker(allLabeled label: String, in channel: Channel,
                    to speaker: String) async {
        await library.setSpeaker(allLabeled: label, in: channel, to: speaker)
    }
    func speakerLineCount(label: String, in channel: Channel) -> Int {
        library.lineCount(label: label, in: channel)
    }
    func setActionDone(_ actionID: Int64, _ done: Bool) {
        library.setActionDone(actionID, done)
    }

    /// Toplantıyı siler. Aşama kaydı ve depolama sayacı kütüphanenin işi
    /// değil; onları burası temizler.
    func delete(_ meetingID: Int64) async {
        await library.delete(meetingID)
        stages[meetingID] = nil
        refreshStorage()
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
            if library.isOnScreen(meetingID) { await library.reload() }
            await refresh()
        } catch {
            Log.error(.calendar, "Takvim bağı değiştirilemedi", error)
        }
    }

    /// Bir toplantının tarihine denk gelen takvim etkinlikleri — kullanıcı
    /// sonradan doğrusunu seçebilsin diye.
    func eventChoices(for meeting: MeetingListItem) -> [MeetingEvent] {
        calendar.choices(at: meeting.date)
    }

    /// Kayıt başlarken takvim eşleştirmesi. Puanlama ve kararlılık eşiği
    /// **Calendar'ın işi**; burada yalnızca sonucu taşımak kalır: kesinse
    /// bağlanır, belirsizse soru arayüze bırakılır.
    private func matchCalendar(meetingID: Int64, app: String?) -> MeetingEvent? {
        switch calendar.match(at: Date(), app: app) {
        case .decisive(let event):
            return event
        case .ambiguous(let choices):
            eventChoices = choices
            choiceMeetingID = meetingID
            return nil
        case .none:
            return nil
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
        library.clearDisplayed()

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
        let event = matchCalendar(meetingID: meetingID, app: signal?.bundleID)
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
        suggestions.recordingStarted(bundleID: signal?.bundleID ?? preferredApp)
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
        suggestions.recordingStopped()
        await refresh()
    }


    // MARK: - İşlem hattı (sıra CLAUDE.md'de sabittir)

    /// Başarısız veya yarım kalmış bir toplantıyı elle yeniden işler.
    /// Ham ses diskte durduğu için kayıt tekrarlanmaz — hat baştan koşar.
    func retryProcessing() async {
        guard let meetingID = selection, let url = retryableAudio,
              !isRecording, !isTranscribing else { return }
        Log.info(.pipeline, "İşlem elle yeniden başlatıldı — toplantı \(meetingID)")
        library.clearRetryable()
        try? await store.markProcessing(meetingID, audioPath: url,
                                        duration: Self.duration(of: url))
        await refresh()
        await pipeline.fullPass(meetingID: meetingID, url: url)
        library.restoreRetryable(url, for: meetingID)
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
            library.scheduleRefresh()
        case .finished(let title):
            Task { await self.notifications.summaryReady(title: title) }

        // Geri kalanı **arayüz içeriğidir**. Süzme kütüphanede: "ekranda ne
        // var" bilgisinin sahibi orası. Veritabanına her hâlükârda yazıldı;
        // kullanıcı geri döndüğünde oradan okunur.
        default:
            library.display(event)
        }
    }

    /// Ertelenen özetlemeyi kullanıcı elle başlatır.
    func summarizeNow() async {
        // Hat koşarken ikinci bir hat başlatılmaz: ikisi aynı aşamayı ve aynı
        // Foundation Models yolunu paylaşıyor.
        guard let meetingID = selection, !transcript.isEmpty,
              !isRecording, !isTranscribing else { return }
        library.clearSummaryNotice()
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
        library.clearSummaryNotice()
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
