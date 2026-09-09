import Foundation
import Speech
import AVFoundation
import CoreMedia

/// Canlı transkripsiyondan gelen tek bir güncelleme.
nonisolated struct LiveUpdate: Sendable {
    let channel: Channel
    let text: String
    /// `false` ise metin daha değişecek — arayüzde soluk gösterilir.
    let isFinal: Bool
    let start: TimeInterval
    let end: TimeInterval
}

/// Canlı transkripsiyon sözleşmesi.
///
/// `AudioCapturing` / `Transcribing` / `Intelligent` ile aynı gerekçe
/// (ARCHITECTURE.md, Test edilebilirlik): testte sahtelenir. Protokol olmadan
/// `RecordingSession` testi gerçek `SpeechAnalyzer` kuruyor ve ölçüm makinenin
/// Speech durumuna bağımlı kalıyordu — oysa **kural #2** (canlı transkripsiyon
/// asla kaydın önüne geçmez) tam olarak burada ölçülmeli.
protocol LiveTranscribing: Actor {
    nonisolated var updates: AsyncStream<LiveUpdate> { get }
    var isPaused: Bool { get }
    var pauseReason: String? { get }
    func start(locale: Locale, vocabulary: [String]) async
    func feed(_ live: LiveBuffer)
    func finish() async
}

/// Kayıt sırasında akan transkripsiyon.
///
/// **En iyi çabadır ve asla kaydın önüne geçmez** (CLAUDE.md kural #2):
/// hata verirse sessizce durur, kullanıcıya "canlı transkript duraklatıldı"
/// bilgisi düşer, kayıt kesintisiz sürer. Kayıt sonrası tam geçiş açığı kapatır
/// ve çelişki hâlinde **tam geçiş kazanır**.
///
/// Ölçülen maliyet kanal başına tek çekirdeğin ~%1'i (RESEARCH.md §6).
actor LiveTranscription: LiveTranscribing {

    nonisolated let updates: AsyncStream<LiveUpdate>
    private let updateContinuation: AsyncStream<LiveUpdate>.Continuation

    private var sessions: [Int: ChannelSession] = [:]
    private(set) var isPaused = false
    private(set) var pauseReason: String?

    init() {
        (updates, updateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// Kayıt başlarken çağrılır. Başarısız olursa canlı transkript kapalı kalır,
    /// kayıt etkilenmez.
    func start(locale: Locale, vocabulary: [String] = []) async {
        guard sessions.isEmpty else { return }
        let modelConfiguration = await CustomVocabulary.configuration(for: vocabulary,
                                                                      locale: locale)
        for channel in Channel.allCases {
            do {
                let session = try await ChannelSession(channel: channel, locale: locale,
                                                       modelConfiguration: modelConfiguration) { [weak self] update in
                    Task { await self?.emit(update) }
                }
                sessions[channel.rawValue] = session
            } catch {
                await pause("Canlı transkript başlatılamadı", error: error)
                return
            }
        }
        Log.info(.transcribe, "Canlı transkripsiyon açıldı — \(locale.identifier)")
    }

    /// Capture'ın `liveBuffers` akışından gelen her buffer buraya düşer.
    func feed(_ live: LiveBuffer) {
        guard !isPaused, let session = sessions[live.channel.rawValue] else { return }
        session.feed(live)
    }

    /// Kayıt bitince çağrılır. Kalan sonuçlar kesinleştirilir.
    func finish() async {
        for session in sessions.values {
            await session.finish()
        }
        sessions.removeAll()
        updateContinuation.finish()
    }

    private func emit(_ update: LiveUpdate) {
        updateContinuation.yield(update)
    }

    /// Canlı transkript durur, kayıt sürer.
    private func pause(_ reason: String, error: Error) async {
        guard !isPaused else { return }
        isPaused = true
        pauseReason = reason
        Log.warning(.transcribe, "\(reason): \(error.localizedDescription) — "
                    + "kayıt etkilenmedi, kayıt sonrası tam geçiş açığı kapatacak")
        for session in sessions.values { await session.finish() }
        sessions.removeAll()
    }
}

/// Tek bir kanalın canlı analiz oturumu.
nonisolated private final class ChannelSession: @unchecked Sendable {

    private let channel: Channel
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AVAudioConverter
    private let analysisFormat: AVAudioFormat
    private let collector: Task<Void, Never>
    /// Analiz motoruna gönderilmiş toplam frame sayısı (analiz oranında).
    ///
    /// Damga **saniyeden değil, tam frame sayısından** kurulur. Ölçüldü
    /// (RESEARCH.md §14): `CMTime(seconds:preferredTimescale:)` ile kurulan
    /// damgalar, saniye cinsinden kelepçelense bile yuvarlama yüzünden
    /// çakışıyor ve motor `SFSpeechErrorDomain 2` veriyor. Tam frame sayısı
    /// bu hatayı yapısal olarak imkânsız kılar.
    private var emittedFrames: Int64 = 0

    init(channel: Channel, locale: Locale,
         modelConfiguration: SFSpeechLanguageModel.Configuration?,
         onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws {
        self.channel = channel

        let transcriber = SpeechTranscription.makeTranscriber(
            locale: locale, modelConfiguration: modelConfiguration, live: true)
        guard let format = await SpeechAnalyzer
            .bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: RecordingFormat.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: format)
        else { throw OraError.transcriptionFailed(underlying: TranscriptionSetupError(
            reason: "Canlı analiz için uyumlu ses formatı kurulamadı")) }

        self.analysisFormat = format
        self.converter = converter

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        self.continuation = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        self.collector = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    onUpdate(LiveUpdate(channel: channel, text: text,
                                        isFinal: result.isFinal,
                                        start: result.range.start.seconds,
                                        end: result.range.end.seconds))
                }
            } catch {
                Log.warning(.transcribe, "\(channel.databaseValue) canlı sonuç akışı "
                            + "durdu: \(error.localizedDescription)")
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    func feed(_ live: LiveBuffer) {
        guard let converted = SpeechTranscription.convert(live.buffer, using: converter,
                                                          to: analysisFormat) else { return }
        // Buffer düşerse zaman ekseninde ileri sıçranır; geriye asla gidilmez.
        let wanted = Int64((live.time * analysisFormat.sampleRate).rounded())
        let start = max(wanted, emittedFrames)
        emittedFrames = start + Int64(converted.frameLength)
        continuation.yield(AnalyzerInput(
            buffer: converted,
            bufferStartTime: CMTime(value: start, timescale: Int32(analysisFormat.sampleRate))))
    }

    func finish() async {
        continuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        collector.cancel()
    }
}
