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
    var searchText = "" { didSet { scheduleRefresh() } }
    var selection: Int64? { didSet { if selection != oldValue { loadSelected() } } }

    private(set) var transcript: [Segment] = []
    private(set) var liveSegments: [Segment] = []
    private(set) var volatileText: [Int: String] = [:]
    private(set) var liveNotice: String?

    private(set) var summary: Ozet?
    private(set) var topics: [TopicSegment] = []
    private(set) var metrics: MeetingMetrics?
    private(set) var summaryNotice: String?
    /// Veritabanı açılamadıysa kullanıcıya söylenecek not.
    private(set) var storageNotice: String?
    /// İçe aktarma sonucu — kullanıcıya bir kez gösterilir.
    var importReport: String?

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

    private let route = LiveRoute()
    private var live: LiveTranscription?
    private var liveUpdatesTask: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// Şu anda kaydedilen toplantının `meetings.id` değeri.
    private var activeMeetingID: Int64?

    private static let languageKey = "transcriptionLanguage"

    init(capture: any AudioCapturing = AudioCapture(),
         transcription: any Transcribing = SpeechTranscription(),
         intelligence: any Intelligent = FoundationIntelligence(),
         database: OraDatabase? = nil) {
        self.capture = capture
        self.transcription = transcription
        self.intelligence = intelligence

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

    var exportPayload: MeetingExport.Payload? {
        guard let meeting = selectedMeeting, !isRecording,
              !transcript.isEmpty || summary != nil else { return nil }
        return MeetingExport.Payload(title: meeting.title, date: meeting.date,
                                     duration: meeting.duration, segments: transcript,
                                     summary: summary, topics: topics, metrics: metrics)
    }

    // MARK: - Liste

    func refresh() async {
        do {
            meetings = try await store.list(search: searchText)
        } catch {
            Log.error(.store, "Toplantı listesi okunamadı", error)
        }
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
            metrics = loaded.metrics
            summaryNotice = nil
            transcriptionStage = loaded.segments.isEmpty ? .idle : .done
        } catch {
            Log.error(.store, "Toplantı yüklenemedi: \(meetingID)", error)
            self.error = .audioWriteFailed(underlying: error)
        }
    }

    func delete(_ meetingID: Int64) async {
        do {
            try await store.delete(meetingID)
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
            await load(meetingID)
        } catch {
            Log.error(.store, "Düzeltme kaydedilemedi", error)
        }
    }

    // MARK: - Eski ora verisini içe aktarma

    func importLegacyData() async {
        guard let url = LegacyImport.chooseFile() else { return }
        do {
            let report = try await LegacyImport.run(from: url, into: store)
            importReport = report.turkishSummary
            await refresh()
        } catch {
            Log.error(.store, "İçe aktarma başarısız", error)
            importReport = "İçe aktarma başarısız oldu. Seçtiğiniz dosya bir ora "
                + "veritabanı olmayabilir.\n\n\(error.localizedDescription)"
        }
    }

    // MARK: - Kayıt

    func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    func start() async {
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

        do {
            try await capture.start(meetingID: meetingID)
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
        await refresh()
        await startLive()
    }

    func stop() async {
        guard isRecording, let meetingID = activeMeetingID else { return }
        await stopLive()
        do {
            let url = try await capture.stop()
            let duration = Self.duration(of: url)
            try? await store.markProcessing(meetingID, audioPath: url, duration: duration)
            await refresh()
            await runFullPass(meetingID: meetingID, url: url, duration: duration)
        } catch let error as OraError {
            self.error = error
        } catch {
            self.error = .audioWriteFailed(underlying: error)
        }
        activeMeetingID = nil
        await refresh()
    }

    private func clearDisplayed() {
        transcript = []
        liveSegments = []
        volatileText = [:]
        liveNotice = nil
        summary = nil
        topics = []
        metrics = nil
        summaryNotice = nil
        transcriptionStage = .idle
    }

    // MARK: - Canlı transkripsiyon (en iyi çaba)

    private func startLive() async {
        let locale = language.locale ?? Locale(identifier: "tr-TR")
        let live = LiveTranscription()
        self.live = live
        route.set(live)
        await live.start(locale: locale)

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
        transcriptionStage = .preparingLanguage
        let locale: Locale
        if let chosen = language.locale {
            locale = chosen
        } else {
            locale = await TranscriptionLocale.detect(url: url, channel: .mic)
        }

        do {
            let module = SpeechTranscription.makeTranscriber(locale: locale, vocabulary: [],
                                                             live: false)
            try await TranscriptionLocale.ensureInstalled(locale, module: module) { [weak self] value in
                Task { @MainActor in self?.transcriptionStage = .downloadingLanguage(value) }
            }
            transcriptionStage = .transcribing(0)
            let segments = try await transcription.transcribe(
                url: url, locale: locale, vocabulary: []
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
            self.error = error
        } catch {
            transcriptionStage = .idle
            self.error = .transcriptionFailed(underlying: error)
        }
    }

    private func runIntelligence(meetingID: Int64, segments: [Segment],
                                 duration: TimeInterval) async {
        metrics = MeetingMetrics.compute(segments: segments, duration: duration)

        let availability = intelligence.availability
        guard availability.isAvailable else {
            summaryNotice = availability.turkishMessage + ". " + availability.turkishDetail
            try? await store.saveSummary(meetingID, ozet: nil, topics: [], metrics: metrics)
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
            metrics = MeetingMetrics.compute(segments: punctuated, duration: duration)
            try? await store.replaceTranscript(meetingID, segments: punctuated)
        } catch {
            Log.warning(.intelligence, "Noktalama atlandı: \(error.localizedDescription)")
        }

        // 5 — Map-reduce özetleme
        transcriptionStage = .summarizing(0)
        do {
            let (ozet, konular) = try await intelligence.summarize(transcript) { [weak self] value in
                Task { @MainActor in self?.transcriptionStage = .summarizing(value) }
            }
            summary = ozet
            topics = konular
            Log.info(.intelligence, "Özet hazır — \(ozet.kararlar.count) karar, "
                     + "\(ozet.aksiyonlar.count) aksiyon, \(konular.count) konu")
        } catch let error as OraError {
            summaryNotice = error.turkishMessage + ". " + error.turkishDetail
            Log.error(.intelligence, "Özetleme başarısız", error)
        } catch {
            summaryNotice = "Özet oluşturulamadı. Transkript korundu."
            Log.error(.intelligence, "Özetleme başarısız", error)
        }

        // 6 — SQLite güncelle
        try? await store.saveSummary(meetingID, ozet: summary, topics: topics, metrics: metrics)
        try? await store.markReady(meetingID)
        transcriptionStage = .done
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
