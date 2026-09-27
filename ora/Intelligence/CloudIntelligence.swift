import Foundation

/// Kullanıcının bağladığı AI sağlayıcısı (Faz 11, Bağlantı Kuralları).
///
/// **Yalnızca özet ve sohbeti devralır.** Noktalama ve başlık üretimi
/// cihazda kalır (`fallback`): ikisi de transkriptin tamamını ister ve
/// kazançları buluta göndermeye değmez — veri minimizasyonu (kural 4).
///
/// Özet, yerel Qwen motorunun **tek geçişli istemini ve çıktı işlemesini**
/// kullanır (`LocalIntelligence.prompt` / `summaryResult`): bağlı modeller
/// uzun bağlamlı, map-reduce gerekmiyor. Bu istem sağlayıcı modellerinde
/// §35 puanlamasıyla ölçülmedi; motoru kullanıcı seçer.
///
/// Her örnek **bir toplantıya bağlıdır** — istek `Outbound` kapısından o
/// toplantının kimliğiyle geçer; kilitli toplantı kapıda reddedilir.
nonisolated struct CloudIntelligence: Intelligent {

    let client: ProviderClient
    let meetingID: Int64?
    let fallback: any Intelligent

    var availability: ModelAvailability { .available }

    @concurrent func summarize(_ segments: [Segment], context: SummaryContext,
                               variation: Bool,
                               progress: @Sendable @escaping (Double) -> Void) async throws
        -> SummaryResult {
        guard !segments.isEmpty else {
            throw OraError.modelUnavailable(reason: "Özetlenecek metin yok")
        }
        progress(0.05)
        let body = TranscriptChunker.render(segments)
        Log.info(.intelligence, "Bağlı sağlayıcı: \(client.kind.displayName) · \(client.model), "
                 + "\(body.count) karakter tek geçişte")
        let output = try await client.complete(system: LocalIntelligence.instructions,
                                               prompt: LocalIntelligence.prompt(body: body,
                                                                                context: context),
                                               purpose: .summary, meetingID: meetingID)
        progress(0.95)
        guard let payload = LocalIntelligence.json(in: output) else {
            throw OraError.connectionFailed(
                reason: "\(client.kind.displayName) beklenen biçimde yanıt vermedi.")
        }
        let result = try LocalIntelligence.summaryResult(from: payload, segments: segments,
                                                         context: context)
        progress(1)
        return result
    }

    @concurrent func answer(question: String, over segments: [Segment]) async throws -> String {
        let prompt = """
            Aşağıda bir toplantının dökümü var. Soruyu yalnızca dökümdeki bilgiye
            dayanarak, kısa ve Türkçe yanıtla. Dökümde yoksa bunu açıkça söyle.

            TOPLANTI DÖKÜMÜ:
            \(TranscriptChunker.render(segments))

            SORU: \(question)
            """
        return try await client.complete(system: LocalIntelligence.instructions, prompt: prompt,
                                         purpose: .chat, meetingID: meetingID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cihazda kalanlar

    /// Not zenginleştirme cihazda kalır: not başına küçük bir pencere yeter,
    /// kullanıcının kendi notunu buluta taşımanın kazancı yok (kural 4).
    @concurrent func enrich(_ notes: [UserNote], over segments: [Segment],
                            progress: @Sendable @escaping (Double) -> Void) async
        -> [Int64: [String]] {
        await fallback.enrich(notes, over: segments, progress: progress)
    }

    @concurrent func restorePunctuation(_ segments: [Segment],
                                        progress: @Sendable @escaping (Double) -> Void) async throws
        -> [Segment] {
        try await fallback.restorePunctuation(segments, progress: progress)
    }

    @concurrent func generateTitle(from segments: [Segment]) async -> String? {
        await fallback.generateTitle(from: segments)
    }

    @concurrent func generateTitle(from segments: [Segment],
                                   topics: [TopicSegment]) async -> String? {
        await fallback.generateTitle(from: segments, topics: topics)
    }
}
