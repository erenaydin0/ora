import Foundation
import FoundationModels

/// `FoundationModels` (Apple'ın cihaz üstü ~3B modeli) üzerine kurulu
/// noktalama ve özetleme.
///
/// Bağlam penceresi **4096 token**; Türkçe'de kabaca 4 karakter ≈ 1 token
/// (RESEARCH.md §3). Bu yüzden her uzun girdi map-reduce edilir ve
/// **her parça için yeni `LanguageModelSession`** açılır — oturum tekrar
/// kullanılırsa geçmiş bağlamı yiyip pencereyi taşırır.
struct FoundationIntelligence: Intelligent {

    /// Talimat her çağrıda aynıdır.
    private static let instructions =
        "Sen bir toplantı asistanısın. Toplantı Türkçe ise yanıtını Türkçe ver."

    var availability: ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            .available
        case .unavailable(.deviceNotEligible):
            .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            .modelNotReady
        case .unavailable:
            .modelNotReady
        }
    }

    // MARK: - Noktalama restorasyonu

    func restorePunctuation(_ segments: [Segment],
                            progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        guard availability.isAvailable, !segments.isEmpty else { return segments }

        let chunks = TranscriptChunker.chunks(of: segments,
                                              limit: TranscriptChunker.punctuationLimit)
        var restored: [Segment] = []
        restored.reserveCapacity(segments.count)

        for (index, chunk) in chunks.enumerated() {
            restored.append(contentsOf: await punctuate(chunk))
            progress(Double(index + 1) / Double(chunks.count))
        }
        return restored
    }

    /// Bir parçayı noktalar. Model metni bozarsa **o satır olduğu gibi kalır** —
    /// noktalama bir iyileştirmedir, kelime kaybetme pahasına yapılmaz.
    ///
    /// **Konuşmacı öneki ("Ben:", "Katılımcı:") bu isteme EKLENMEZ.** Ölçüldü
    /// (RESEARCH.md §15.1): önekli noktalama istemi 8 denemenin 6'sında
    /// `guardrailViolation` veriyor, öneksiz 8/8 geçiyor. Noktalama için
    /// konuşmacı bilgisine zaten ihtiyaç yok.
    private func punctuate(_ chunk: [Segment]) async -> [Segment] {
        let numbered = chunk.enumerated()
            .map { "\($0.offset + 1). \($0.element.text)" }
            .joined(separator: "\n")

        let strict = """
        Aşağıdaki numaralı satırlara noktalama işaretleri ve büyük harf düzeltmesi ekle.
        Kurallar:
        - Kelimeleri DEĞİŞTİRME, EKLEME veya SİLME. Yalnızca noktalama ve büyük/küçük harf.
        - Satır sayısını ve numaralandırmayı aynen koru.
        - Yorum, açıklama veya başlık ekleme.

        \(numbered)
        """
        // Guardrail tetiklenirse daha yalın bir istemle bir kez daha denenir.
        let plain = """
        Aşağıdaki satırlara noktalama işaretleri ekle. Satır sayısını ve
        numaralandırmayı koru.

        \(numbered)
        """

        do {
            let content = try await respondWithRetry(strict: strict, plain: plain)
            let lines = Self.numberedLines(content)
            guard lines.count == chunk.count else {
                Log.warning(.intelligence, "Noktalama parçası atlandı: satır sayısı "
                            + "uyuşmadı (\(lines.count) ≠ \(chunk.count))")
                return chunk
            }
            return zip(chunk, lines).map { segment, line in
                // Kelime kimliği korunmadıysa orijinali tut.
                guard Self.sameWords(segment.text, line) else {
                    Log.debug(.intelligence, "Noktalama reddedildi (kelime değişmiş): "
                              + "\(segment.text.prefix(40))…")
                    return segment
                }
                return Segment(channel: segment.channel, speaker: segment.speaker,
                               text: line, start: segment.start, end: segment.end,
                               confidence: segment.confidence, words: segment.words)
            }
        } catch {
            Log.warning(.intelligence, "Noktalama parçası başarısız: \(error.localizedDescription)")
            return chunk
        }
    }

    /// Her parça için **yeni oturum** — oturum tekrar kullanılırsa geçmiş bağlam
    /// birikir ve 4096 token penceresi taşar.
    private func respondWithRetry(strict: String, plain: String) async throws -> String {
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            return try await session.respond(to: strict).content
        } catch let error as LanguageModelSession.GenerationError {
            guard case .guardrailViolation = error else { throw error }
            Log.debug(.intelligence, "Noktalama istemi guardrail'e takıldı, yalın istemle "
                      + "tekrar deneniyor")
            let session = LanguageModelSession(instructions: Self.instructions)
            return try await session.respond(to: plain).content
        }
    }

    // MARK: - Map-reduce özetleme

    func summarize(_ segments: [Segment],
                   progress: @Sendable @escaping (Double) -> Void) async throws -> (Ozet, [TopicSegment]) {
        guard availability.isAvailable else {
            throw OraError.modelUnavailable(reason: availability.turkishMessage)
        }
        guard !segments.isEmpty else {
            throw OraError.modelUnavailable(reason: "Özetlenecek metin yok")
        }

        let chunks = TranscriptChunker.chunks(of: segments,
                                              limit: TranscriptChunker.summaryLimit)
        Log.info(.intelligence, "Özetleme: \(chunks.count) parça, "
                 + "\(segments.count) segment")

        // MAP — her parça ayrı özetlenir, ayrı oturumda.
        var partials: [String] = []
        var topics: [TopicSegment] = []
        for (index, chunk) in chunks.enumerated() {
            let text = TranscriptChunker.render(chunk)
            partials.append(await partialSummary(of: text))
            if let title = await topicTitle(of: text),
               let first = chunk.first, let last = chunk.last {
                topics.append(TopicSegment(title: title, start: first.start, end: last.end))
            }
            // Birleştirme adımı için son %20 pay bırakılır.
            progress(Double(index + 1) / Double(chunks.count) * 0.8)
        }

        // REDUCE — kısmi özetler birleştirilir; hâlâ uzunsa tekrar indirgenir.
        var combined = partials.joined(separator: "\n")
        var rounds = 0
        while combined.count > TranscriptChunker.summaryLimit, rounds < 4 {
            rounds += 1
            var next: [String] = []
            for piece in TranscriptChunker.split(text: combined,
                                                 limit: TranscriptChunker.summaryLimit) {
                next.append(await partialSummary(of: piece))
            }
            combined = next.joined(separator: "\n")
        }

        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(
                to: """
                Aşağıda bir toplantının bölüm bölüm özetleri var. Bunları birleştirerek
                toplantının genel özetini, alınan kararları ve aksiyon maddelerini çıkar.
                Aksiyonlarda sorumlu kişi olarak metinde geçen adı yaz; kaydı tutan
                kişi için "Ben" yaz.

                \(combined)
                """,
                generating: Ozet.self)
            progress(1)
            return (Self.deduplicated(response.content), topics)
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                // Buraya düşmek parçalama mantığında hata olduğunu gösterir.
                throw OraError.contextOverflow
            }
            throw OraError.modelUnavailable(reason: error.localizedDescription)
        } catch {
            throw OraError.modelUnavailable(reason: error.localizedDescription)
        }
    }

    // MARK: - Toplantı sohbeti

    func answer(question: String, over segments: [Segment]) async throws -> String {
        guard availability.isAvailable else {
            throw OraError.modelUnavailable(reason: availability.turkishMessage)
        }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !segments.isEmpty else {
            throw OraError.modelUnavailable(reason: "Bu toplantının transkripti yok")
        }

        let chunks = TranscriptChunker.chunks(of: segments,
                                              limit: TranscriptChunker.summaryLimit)

        // MAP — her parçaya soru ayrı sorulur; ilgisiz parçalar elenir.
        var findings: [String] = []
        for chunk in chunks {
            let session = LanguageModelSession(instructions: Self.instructions)
            let text = TranscriptChunker.render(chunk)
            do {
                let response = try await session.respond(to: """
                    Aşağıdaki toplantı bölümünde şu sorunun yanıtı var mı?
                    Soru: \(trimmed)

                    Varsa kısaca yaz. Yoksa yalnızca "YOK" yaz. Uydurma.

                    \(text)
                    """)
                let finding = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finding.isEmpty, !finding.uppercased(with: Locale(identifier: "tr_TR"))
                    .hasPrefix("YOK") {
                    findings.append(finding)
                }
            } catch {
                Log.warning(.intelligence, "Sohbet parçası atlandı: \(error.localizedDescription)")
            }
        }

        guard !findings.isEmpty else {
            return "Bu soruya toplantı transkriptinde bir yanıt bulamadım."
        }
        if findings.count == 1 { return findings[0] }

        // REDUCE — bulgular tek yanıta indirgenir.
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(to: """
                Soru: \(trimmed)

                Toplantının farklı bölümlerinden şu bulgular çıktı. Bunları
                birleştirerek soruyu Türkçe ve kısaca yanıtla. Bulgularda olmayan
                bir şey ekleme.

                \(findings.joined(separator: "\n---\n"))
                """)
            return response.content
        } catch {
            return findings.joined(separator: "\n\n")
        }
    }

    // MARK: - Otomatik başlık

    func generateTitle(from segments: [Segment]) async -> String? {
        guard availability.isAvailable, !segments.isEmpty else { return nil }
        // Başlık için toplantının başı yeter; tamamını göndermek gereksiz.
        let opening = TranscriptChunker.chunks(of: segments,
                                               limit: TranscriptChunker.summaryLimit).first ?? segments
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(
                to: """
                Bu toplantıya 3-6 kelimelik Türkçe bir başlık ver. Tarih yazma,
                tırnak kullanma, "toplantı" kelimesini gereksizce tekrarlama.

                \(TranscriptChunker.render(opening))
                """,
                generating: KonuBasligi.self)
            let title = response.content.baslik
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'.\n"))
            return title.isEmpty ? nil : title
        } catch {
            Log.warning(.intelligence, "Başlık üretilemedi: \(error.localizedDescription)")
            return nil
        }
    }

    private func partialSummary(of text: String) async -> String {
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(to: """
                Bu toplantı bölümünü Türkçe olarak özetle. Kararları ve kimin neyi
                üstlendiğini mutlaka koru. Konuşmada geçen kişi adlarını aynen kullan.
                "Ben" bu kaydı tutan kişidir. En fazla 6 cümle.

                \(text)
                """)
            return response.content
        } catch {
            Log.warning(.intelligence, "Kısmi özet başarısız: \(error.localizedDescription)")
            // Parça kaybolmasın: ham metnin başı korunur ki birleştirme adımı
            // bu bölümden tamamen habersiz kalmasın.
            return String(text.prefix(600))
        }
    }

    private func topicTitle(of text: String) async -> String? {
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(
                to: "Bu toplantı bölümüne 2-5 kelimelik Türkçe bir başlık ver:\n\n\(text)",
                generating: KonuBasligi.self)
            let title = response.content.baslik.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        } catch {
            return nil
        }
    }

    /// Model bazı karar ve aksiyonları iki kez üretebiliyor (ölçüldü,
    /// RESEARCH.md §15.2). Aynı içerik listede bir kez görünür.
    static func deduplicated(_ ozet: Ozet) -> Ozet {
        var seenDecisions: Set<String> = []
        var seenActions: Set<String> = []
        var result = ozet
        result.kararlar = ozet.kararlar.filter { seenDecisions.insert(normalized($0)).inserted }
        result.aksiyonlar = ozet.aksiyonlar.filter {
            seenActions.insert(normalized($0.kisi + $0.gorev)).inserted
        }
        return result
    }

    // MARK: - Doğrulama yardımcıları

    /// "3. Merhaba, nasılsın?" → "Merhaba, nasılsın?"
    static func numberedLines(_ response: String) -> [String] {
        response
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let dot = trimmed.firstIndex(of: "."),
                      trimmed[trimmed.startIndex ..< dot].allSatisfy(\.isNumber),
                      dot < trimmed.endIndex
                else { return trimmed }
                return String(trimmed[trimmed.index(after: dot)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    /// Noktalama ve büyük/küçük harf dışındaki her fark reddedilir.
    static func sameWords(_ original: String, _ candidate: String) -> Bool {
        Self.normalized(original) == Self.normalized(candidate)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
