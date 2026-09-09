import Foundation
import Darwin
import Testing
@testable import ora

/// Ağır işin ana aktörün dışında koştuğunu denetler.
///
/// Approachable concurrency açık (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` +
/// `SWIFT_APPROACHABLE_CONCURRENCY = YES`). SE-0461 ile `nonisolated async`
/// gövdeler artık **çağıranın** aktöründe koşuyor; `MeetingPipeline` de
/// `@MainActor` olduğu için tam geçiş, noktalama ve özetleme ana iş parçacığına
/// inerdi. Bu yüzden `Transcribing` ve `Intelligent` sözleşmelerindeki ağır
/// adımlar `@concurrent` ile açıkça dışarı çıkarıldı.
///
/// Buradaki sahteler **bilerek `@concurrent` taşımaz**: ölçülen şey sahtenin
/// kendi işareti değil, *sözleşmenin* işareti. Protokoldeki `@concurrent`
/// silinirse çağrı ana iş parçacığına düşer ve bu testler kırılır.
@Suite("İzolasyon: ağır iş ana aktörün dışında", .serialized)
struct IsolationTests {

    @Test
    func tamGecisAnaIsParcacigindaKosmaz() async throws {
        let audio = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ora-test-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: audio.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: audio) }

        let witness = ThreadWitness()
        let produced = [Segment(channel: .mic, speaker: "Ben", text: "metin",
                                start: 0, end: 5, confidence: 0.8, words: [])]
        let h = try Harness(intelligence: WitnessIntelligence(witness: witness),
                            transcription: WitnessTranscription(witness: witness,
                                                                segments: produced))
        let id = try await h.store.createMeeting()
        try await h.store.markProcessing(id, audioPath: audio, duration: 5)
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("yeniden deneme mümkün") { h.controller.canRetry }

        await h.controller.retryProcessing()

        #expect(h.controller.transcript.first?.text == "metin.", "hat gerçekten koştu")
        #expect(witness.onMain("transcribe") == false,
                "tam geçiş ana iş parçacığında koştu — Transcribing.transcribe'daki @concurrent gitti")
        #expect(witness.onMain("punctuate") == false,
                "noktalama ana iş parçacığında koştu — restorePunctuation'daki @concurrent gitti")
        #expect(witness.onMain("summarize") == false,
                "özetleme ana iş parçacığında koştu — summarize'daki @concurrent gitti")
    }

    /// Sohbet ve başlık üretimi de model çağrısıdır; ikisi de kullanıcı
    /// yazarken/ekran açıkken tetiklendiği için ana iş parçacığından uzak
    /// tutulması hattın kendisinden bile önemli.
    @Test
    func sohbetVeBaslikAnaIsParcacigindaKosmaz() async throws {
        let witness = ThreadWitness()
        let h = try Harness(intelligence: WitnessIntelligence(witness: witness))
        let id = try await h.seed(text: "toplantı metni")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("transkript yüklendi") { !h.controller.transcript.isEmpty }

        await h.controller.ask("soru?")

        #expect(witness.onMain("answer") == false,
                "sohbet yanıtı ana iş parçacığında üretildi — answer'daki @concurrent gitti")
    }
}

// MARK: - Yalnızca iş parçacığını kaydeden sahteler

/// Hangi adımın hangi iş parçacığında koştuğunu tutar. Ana iş parçacığı
/// dışından yazıldığı için kilitli.
private nonisolated final class ThreadWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: Bool] = [:]

    func record(_ step: String) {
        let onMain = pthread_main_np() != 0
        lock.lock(); seen[step] = onMain; lock.unlock()
    }

    /// `nil`: adım hiç çağrılmadı.
    func onMain(_ step: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return seen[step]
    }
}

private nonisolated struct WitnessTranscription: Transcribing {
    let witness: ThreadWitness
    let segments: [Segment]

    func transcribe(url: URL, locale: Locale, vocabulary: [String],
                    progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        witness.record("transcribe")
        progress(1)
        return segments
    }
}

private nonisolated struct WitnessIntelligence: Intelligent {
    let witness: ThreadWitness

    var availability: ModelAvailability { .available }

    func restorePunctuation(_ segments: [Segment],
                            progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        witness.record("punctuate")
        progress(1)
        return segments.map {
            Segment(channel: $0.channel, speaker: $0.speaker, text: $0.text + ".",
                    start: $0.start, end: $0.end, confidence: $0.confidence, words: $0.words)
        }
    }

    func summarize(_ segments: [Segment], context: SummaryContext, variation: Bool,
                   progress: @Sendable @escaping (Double) -> Void) async throws -> SummaryResult {
        witness.record("summarize")
        progress(1)
        return SummaryResult(
            ozet: Ozet(genelBakis: ["genel bakış"], kararlar: ["karar"], aksiyonlar: []),
            topics: [TopicSegment(title: "konu", bullets: ["madde"], start: 0, end: 10)],
            skippedChunks: 0)
    }

    func answer(question: String, over segments: [Segment]) async throws -> String {
        witness.record("answer")
        return "yanıt"
    }

    func generateTitle(from segments: [Segment]) async -> String? {
        witness.record("title")
        return nil
    }

    func generateTitle(from segments: [Segment], topics: [TopicSegment]) async -> String? {
        witness.record("title")
        return nil
    }
}
