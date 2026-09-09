import Foundation
import AVFoundation
import Testing
@testable import ora

// Sahteler yalnızca **dış dünyaya dokunan** katmanlar için yazılır: ses
// donanımı, Speech ve Foundation Models. Veritabanı sahtelenmez — bellek içi
// SQLite gerçeğin kendisidir ve şema hatasını da yakalar (RESEARCH.md §27'nin
// probe'u da böyle koşuyordu).

/// Hiçbir donanıma dokunmayan ses yakalama. Akışlar boş kalır; kayıt
/// başlat/bitir çağrıları yalnızca durumu ilerletir.
final class FakeCapture: AudioCapturing, @unchecked Sendable {

    let state: AsyncStream<CaptureState>
    let liveBuffers: AsyncStream<LiveBuffer>
    private let stateContinuation: AsyncStream<CaptureState>.Continuation
    private let liveContinuation: AsyncStream<LiveBuffer>.Continuation

    var levels: [Int: Float] { [:] }

    /// `stop()` bunu döndürür.
    var stopURL: URL
    /// Doluysa `start()` bunu fırlatır — izin reddi senaryosu.
    var startError: OraError?
    private(set) var startCount = 0

    init(stopURL: URL = URL(fileURLWithPath: "/dev/null")) {
        self.stopURL = stopURL
        (state, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        (liveBuffers, liveContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
        stateContinuation.yield(.idle)
    }

    func start(meetingID: Int64, preferredApp: String?) async throws {
        startCount += 1
        if let startError {
            stateContinuation.yield(.failed(startError))
            throw startError
        }
        stateContinuation.yield(.recording(elapsed: 0))
    }

    func stop() async throws -> URL {
        stateContinuation.yield(.idle)
        return stopURL
    }
}

/// Verilen segmentleri döndüren tam geçiş.
struct FakeTranscription: Transcribing {
    var segments: [Segment] = []
    var error: OraError?

    func transcribe(url: URL, locale: Locale, vocabulary: [String],
                    progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        if let error { throw error }
        progress(1)
        return segments
    }
}

/// İlerleme bildiren, yavaş sahte model. Özet metni **kendisine verilen**
/// metinden türetilir: yanlış toplantının metniyle çağrıldığında bu iz onu
/// ele verir. `probes/meeting_switch.swift`'ten taşındı.
final class SlowIntelligence: Intelligent, @unchecked Sendable {

    var availability: ModelAvailability { .available }
    let tag: String
    /// İki ilerleme bildirimi arası. Gerçek hatta bir parçanın özetlenmesi
    /// saniyeler sürer; sık bildirim, dönüşte animasyonun kendiliğinden geri
    /// gelmesini sağlayıp hatayı gizler.
    let step: Duration
    /// Kaçıncı çağrıda hangi metinle çağrıldığı — "A'nın özeti A'nın
    /// metninden mi üretildi" kontrolü için.
    private(set) var summarizedTexts: [String] = []

    init(tag: String, step: Duration = .milliseconds(900)) {
        self.tag = tag
        self.step = step
    }

    func restorePunctuation(_ segments: [Segment],
                            progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        for i in 1...3 {
            try? await Task.sleep(for: step)
            progress(Double(i) / 3)
        }
        return segments.map {
            Segment(channel: $0.channel, speaker: $0.speaker, text: $0.text + ".",
                    start: $0.start, end: $0.end, confidence: $0.confidence, words: $0.words)
        }
    }

    func summarize(_ segments: [Segment], context: SummaryContext, variation: Bool,
                   progress: @Sendable @escaping (Double) -> Void) async throws -> SummaryResult {
        summarizedTexts.append(segments.first?.text ?? "boş")
        for i in 1...6 {
            try? await Task.sleep(for: step)
            progress(Double(i) / 6)
        }
        let source = segments.first?.text ?? "boş"
        let suffix = variation ? " (yeniden)" : ""
        return SummaryResult(
            ozet: Ozet(genelBakis: ["\(tag) genel bakış: \(source)\(suffix)"],
                       kararlar: ["\(tag) karar"],
                       aksiyonlar: [Ozet.Aksiyon(kisi: "Ben", gorev: "\(tag) görev\(suffix)",
                                                 baglam: "\(tag) bağlam",
                                                 sonTarih: "belirtilmedi")]),
            topics: [TopicSegment(title: "\(tag) konu", bullets: ["madde"], start: 0, end: 10)],
            skippedChunks: 0)
    }

    func answer(question: String, over segments: [Segment]) async throws -> String { "" }
    func generateTitle(from segments: [Segment]) async -> String? { nil }
    func generateTitle(from segments: [Segment], topics: [TopicSegment]) async -> String? { nil }
}

/// Özetleme başarısız olur, noktalama da. Transkriptin korunduğunu ölçer.
struct FailingIntelligence: Intelligent {
    var availability: ModelAvailability { .available }

    func restorePunctuation(_ segments: [Segment],
                            progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        throw OraError.modelUnavailable(reason: "noktalama sahte hata")
    }

    func summarize(_ segments: [Segment], context: SummaryContext, variation: Bool,
                   progress: @Sendable @escaping (Double) -> Void) async throws -> SummaryResult {
        throw OraError.modelUnavailable(reason: "özetleme sahte hata")
    }

    func answer(question: String, over segments: [Segment]) async throws -> String { "" }
    func generateTitle(from segments: [Segment]) async -> String? { nil }
    func generateTitle(from segments: [Segment], topics: [TopicSegment]) async -> String? { nil }
}

/// Apple Intelligence kapalı. Transkriptin yine üretildiğini ölçer.
struct UnavailableIntelligence: Intelligent {
    var availability: ModelAvailability { .appleIntelligenceNotEnabled }

    func restorePunctuation(_ segments: [Segment],
                            progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        Issue.record("model kullanılamazken noktalama çağrıldı")
        return segments
    }

    func summarize(_ segments: [Segment], context: SummaryContext, variation: Bool,
                   progress: @Sendable @escaping (Double) -> Void) async throws -> SummaryResult {
        Issue.record("model kullanılamazken özetleme çağrıldı")
        throw OraError.modelUnavailable(reason: "çağrılmamalıydı")
    }

    func answer(question: String, over segments: [Segment]) async throws -> String { "" }
    func generateTitle(from segments: [Segment]) async -> String? { nil }
    func generateTitle(from segments: [Segment], topics: [TopicSegment]) async -> String? { nil }
}
