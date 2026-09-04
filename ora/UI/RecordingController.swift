import Foundation
import Observation

/// Canlı buffer'ları o an açık olan `LiveTranscription`'a yönlendiren yönlendirici.
///
/// `liveBuffers` akışı uygulama ömrü boyunca tek tüketiciye sahiptir; hedef
/// kayıt başlayıp bittikçe değişir.
private final class LiveRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var target: LiveTranscription?
    func set(_ target: LiveTranscription?) { lock.withLock { self.target = target } }
    var current: LiveTranscription? { lock.withLock { target } }
}

/// Kayıt ve transkripsiyon yüzeyinin durum sahibi.
///
/// Faz 5'te bu tip `Pipeline`'ın arkasına geçecek; şimdilik Capture ve Transcribe'ı
/// doğrudan sürüyor. Segmentler bellekte tutuluyor — `transcripts` tablosu Faz 5'te.
@MainActor
@Observable
final class RecordingController {

    // MARK: - Yayınlanan durum

    private(set) var state: CaptureState = .idle
    private(set) var lastRecording: URL?
    private(set) var interrupted: [InterruptedRecording] = []
    var error: OraError?

    /// Kayıt sonrası tam geçişin nihai sonucu. Canlı çıktıyla çelişirse bu kazanır.
    private(set) var transcript: [Segment] = []
    /// Kayıt sırasında kesinleşmiş canlı segmentler (ön izleme).
    private(set) var liveSegments: [Segment] = []
    /// Henüz kesinleşmemiş canlı metin — arayüzde soluk gösterilir.
    private(set) var volatileText: [Int: String] = [:]
    /// Canlı transkript durduysa nedeni.
    private(set) var liveNotice: String?

    private(set) var transcriptionStage: Stage = .idle
    enum Stage: Equatable {
        case idle
        case preparingLanguage
        case downloadingLanguage(Double)
        case transcribing(Double)
        case done
    }

    /// Kullanıcının dil tercihi.
    var language: TranscriptionLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey) }
    }

    // MARK: - Bağımlılıklar

    private let capture: any AudioCapturing
    private let transcription: any Transcribing
    private let route = LiveRoute()
    private var live: LiveTranscription?
    private var liveUpdatesTask: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?

    private static let languageKey = "transcriptionLanguage"

    init(capture: any AudioCapturing = AudioCapture(),
         transcription: any Transcribing = SpeechTranscription()) {
        self.capture = capture
        self.transcription = transcription
        self.language = UserDefaults.standard.string(forKey: Self.languageKey)
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .turkish

        observation = Task { [weak self] in
            guard let stream = self?.capture.state else { return }
            for await next in stream {
                self?.state = next
                if case .failed(let error) = next { self?.error = error }
            }
        }
        // Uygulama ömrü boyunca tek tüketici; hedef kayıt başladıkça değişir.
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

    /// Arayüzün gösterdiği segmentler: tam geçiş bittiyse o, yoksa canlı ön izleme.
    var displayedSegments: [Segment] {
        transcript.isEmpty ? liveSegments : transcript
    }

    var isTranscribing: Bool {
        switch transcriptionStage {
        case .idle, .done: false
        default: true
        }
    }

    // MARK: - Eylemler

    func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    func start() async {
        guard !isRecording else { return }
        transcript = []
        liveSegments = []
        volatileText = [:]
        liveNotice = nil
        transcriptionStage = .idle

        do {
            try await capture.start(meetingID: Self.provisionalMeetingID())
        } catch let error as OraError {
            self.error = error
            return
        } catch {
            self.error = .audioWriteFailed(underlying: error)
            return
        }
        await startLive()
    }

    func stop() async {
        guard isRecording else { return }
        await stopLive()
        do {
            let url = try await capture.stop()
            lastRecording = url
            await runFullPass(url: url)
        } catch let error as OraError {
            self.error = error
        } catch {
            self.error = .audioWriteFailed(underlying: error)
        }
    }

    // MARK: - Canlı transkripsiyon (en iyi çaba)

    private func startLive() async {
        // Otomatik dilde canlı geçiş için ses henüz yok; kullanıcı tercihini
        // ya da Türkçe'yi kullanır, tam geçişte gerçek seçim yapılır.
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
                                        text: update.text,
                                        start: update.start,
                                        end: update.end,
                                        confidence: nil,
                                        words: []))
            liveSegments.sort { $0.start < $1.start }
        } else {
            volatileText[update.channel.rawValue] = update.text
        }
    }

    // MARK: - Kayıt sonrası tam geçiş

    private func runFullPass(url: URL) async {
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
            // Tam geçiş nihai gerçektir; canlı ön izlemenin yerini alır.
            transcript = segments
            liveSegments = []
            transcriptionStage = .done
            Log.info(.transcribe, "Tam geçiş bitti — \(segments.count) segment, "
                     + "\(locale.identifier)")
        } catch let error as OraError {
            transcriptionStage = .idle
            self.error = error
        } catch {
            transcriptionStage = .idle
            self.error = .transcriptionFailed(underlying: error)
        }
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

    /// Faz 5'te `meetings` tablosuna satır eklenip gerçek id kullanılacak.
    private static func provisionalMeetingID() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
