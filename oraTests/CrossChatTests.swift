import Foundation
import Testing
@testable import ora

/// Toplantılar arası sohbet (COMPETITION.md §4.10): FTS ile daraltılmış
/// yerel RAG.
@Suite("Toplantılar arası sohbet", .serialized)
struct CrossChatTests {

    private func line(_ text: String, _ start: TimeInterval) -> Segment {
        Segment(channel: .system, speaker: "Katılımcı", text: text,
                start: start, end: start + 5, confidence: 0.9, words: [])
    }

    private func meeting(_ h: Harness, _ title: String, _ lines: [Segment]) async throws -> Int64 {
        let id = try await h.store.createMeeting()
        try await h.store.updateTitle(id, title: title)
        try await h.store.replaceTranscript(id, segments: lines)
        try await h.store.markReady(id)
        return id
    }

    // MARK: - Arama

    @Test
    func soruAnahtarKelimelereIndirgenir() {
        #expect(CrossMeetingSearch.keywords("Acme teklifinde fiyat ne konuşuldu?")
                    == ["acme", "teklif", "fiyat"])
        #expect(CrossMeetingSearch.keywords("Bütçesi hakkında toplantıda ne dedi?") == ["bütçe"])
        #expect(CrossMeetingSearch.keywords("ne ve bu?").isEmpty)
        #expect(CrossMeetingSearch.pattern(["acme", "fiyat"]) == "\"acme\"* OR \"fiyat\"*")
    }

    @Test
    func bolumlerYalnizcaIlgiliToplantidanVeCevresindenGelir() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let acme = try await meeting(h, "Acme görüşmesi", [
            line("Hoş geldiniz.", 0),
            line("Acme için fiyat teklifi 40 bin dolar.", 100),
            line("Teslim üç ay sürer.", 110),
            line("Konu dışı sohbet.", 400),
        ])
        _ = try await meeting(h, "Sprint", [line("Sprint hedefleri belirlendi.", 0)])

        let passages = try await h.store.passages(for: "Acme fiyatı ne?")
        #expect(passages.map(\.meetingID) == [acme])
        let texts = passages.flatMap(\.segments).map(\.text)
        #expect(texts.contains("Acme için fiyat teklifi 40 bin dolar."))
        #expect(texts.contains("Teslim üç ay sürer."), "eşleşmenin arkası")
        #expect(!texts.contains("Konu dışı sohbet."), "pencerenin dışı")
        #expect(!texts.contains("Hoş geldiniz."), "pencerenin öncesi")

        #expect(try await h.store.passages(for: "işe alım takvimi").isEmpty)
    }

    /// Parçalar sınırı aşmaz ve hiçbir satır kaybolmaz.
    @Test
    func parcalarSiniriAsmazSatirKaybolmaz() {
        let long = MeetingPassage(meetingID: 1, title: "Uzun", date: .now,
                                  segments: (0 ..< 40).map {
                                      line(String(repeating: "k", count: 80), Double($0) * 6)
                                  })
        let short = MeetingPassage(meetingID: 2, title: "Kısa", date: .now,
                                   segments: [line("kısa satır", 0)])
        let chunks = FoundationIntelligence.crossChunks([long, short], limit: 1_000)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.map(FoundationIntelligence.render).joined(separator: "\n\n").count
                        <= 1_000 + 2 * chunk.count)
        }
        #expect(chunks.flatMap { $0 }.flatMap(\.segments).count == 41)
    }

    @Test
    func atifAdiGecenToplantiyaYapilir() {
        let a = MeetingPassage(meetingID: 1, title: "Acme görüşmesi", date: .now, segments: [])
        let b = MeetingPassage(meetingID: 2, title: "Sprint", date: .now, segments: [])
        #expect(FoundationIntelligence.attributed("Acme görüşmesinde fiyat 40 bin dolar.",
                                                  in: [a, b]) == [1])
        #expect(FoundationIntelligence.attributed("Fiyat 40 bin dolar.", in: [a, b]) == [1, 2],
                "ad geçmiyorsa parçadaki hepsi")
    }

    // MARK: - Denetleyici

    @Test
    func toplantiSeciliDegilkenKapsamTumToplantilardir() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let id = try await h.seed(text: "metin")
        #expect(h.controller.effectiveChatScope == .all)
        await h.controller.refresh()
        h.controller.selection = id
        #expect(h.controller.effectiveChatScope == .meeting)
        h.controller.chatScope = .all
        #expect(h.controller.effectiveChatScope == .all)
        h.controller.showsActionBoard = true
        #expect(h.controller.effectiveChatScope == .all)
    }

    @Test
    func yanitKaynaklariylaSaklanirVeTemizlenir() async throws {
        let model = SlowIntelligence(tag: "A")
        let h = try Harness(intelligence: model)
        let acme = try await meeting(h, "Acme görüşmesi",
                                     [line("Acme fiyat teklifi 40 bin dolar.", 0)])
        await h.controller.refresh()

        await h.controller.askAcross("Acme fiyatı?")

        #expect(model.crossPassages.map(\.meetingID) == [acme], "modele yalnızca bulunan bölüm")
        let turn = try #require(h.controller.crossTurns.last)
        #expect(turn.answer == "A yanıt: Acme fiyatı?")
        #expect(turn.sources.map(\.title) == ["Acme görüşmesi"])
        #expect(try await h.store.chatHistory(acme).isEmpty,
                "toplantının kendi sohbetine karışmaz")

        // Kaynak toplantı silinince bağlantı düşer, tur kalır.
        try await h.store.delete(acme)
        await h.controller.refreshCrossChat()
        #expect(h.controller.crossTurns.last?.sources.isEmpty == true)

        await h.controller.clearCrossChat()
        #expect(h.controller.crossTurns.isEmpty)
        #expect(try await h.store.crossChatHistory().isEmpty)
    }
}
