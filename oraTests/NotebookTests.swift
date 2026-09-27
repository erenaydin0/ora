import Foundation
import Testing
@testable import ora

/// Not defteri (COMPETITION.md §4.6, §4.9): kullanıcının kendi notu, kayıt
/// sırasında işaretlenen an ve kayıt sonrası zenginleştirme.
@Suite("Not defteri", .serialized)
struct NotebookTests {

    private func segment(_ text: String, _ start: TimeInterval, _ end: TimeInterval,
                         channel: Channel = .system) -> Segment {
        Segment(channel: channel, speaker: channel.speaker, text: text,
                start: start, end: end, confidence: 0.9, words: [])
    }

    // MARK: - Depo

    @Test
    func notlarKayittakiSirayaGoreOkunurSonradanYazilanSondadir() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let id = try await h.store.createMeeting()
        try await h.store.addNote(id, kind: .note, text: "sonradan", at: nil)
        try await h.store.addNote(id, kind: .mark, text: "", at: 120)
        try await h.store.addNote(id, kind: .note, text: "  bütçe onayı  ", at: 30)

        let notes = try await h.store.notes(id)
        #expect(notes.map(\.text) == ["bütçe onayı", "", "sonradan"])
        #expect(notes[1].isMark && notes[1].displayText == "Önemli an")
        #expect(notes[2].at == nil)
    }

    /// Notun metni değişince eski ayrıntı onu anlatmıyor olabilir.
    @Test
    func notDegisinceAyrintiSilinir() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let id = try await h.store.createMeeting()
        let noteID = try await h.store.addNote(id, kind: .note, text: "bütçe", at: 10)
        try await h.store.saveNoteDetails(id, details: [noteID: ["Bütçe 2 milyon TL."]])
        #expect(try await h.store.notes(id).first?.details == ["Bütçe 2 milyon TL."])

        try await h.store.updateNote(noteID, text: "bütçe onayı")
        let note = try #require(try await h.store.notes(id).first)
        #expect(note.text == "bütçe onayı")
        #expect(note.details.isEmpty)
    }

    @Test
    func toplantiSilinceNotlarDaGider() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let id = try await h.store.createMeeting()
        try await h.store.addNote(id, kind: .note, text: "not", at: nil)
        try await h.store.delete(id)
        #expect(try await h.store.notes(id).isEmpty)
    }

    // MARK: - Transkriptteki yeri

    /// İşaret konuşmanın arkasından gelir: satırın bitiminden birkaç saniye
    /// sonra basılan işaret yine o satırı gösterir.
    @Test
    func isaretKonusulanSatiraBaglanir() {
        let lines = [segment("birinci", 0, 10), segment("ikinci", 12, 20),
                     segment("üçüncü", 40, 50)]
        #expect(NoteAnchor.segment(at: 15, in: lines)?.text == "ikinci")
        #expect(NoteAnchor.segment(at: 22, in: lines)?.text == "ikinci", "tepki payı")
        #expect(NoteAnchor.segment(at: 35, in: lines)?.text == "ikinci", "sessizlikte önceki")
        #expect(NoteAnchor.markedIDs([45], in: lines) == [lines[2].id])
    }

    @Test
    func zamanliNotunPenceresiGeriyeGenistir() {
        let lines = (0 ..< 20).map { segment("satır \($0)", Double($0) * 10, Double($0) * 10 + 8) }
        let note = UserNote(id: 1, kind: .note, text: "x", at: 150, details: [])
        let window = NoteAnchor.window(for: note, in: lines)
        #expect(window.first?.start == 60, "işaretten 90 sn öncesi")
        #expect(window.last?.start == 170, "işaretten 20 sn sonrası")
    }

    /// Zamansız not kelime eşleştirmesiyle bulunur; bulunamazsa **bağlanmaz**.
    @Test
    func zamansizNotKelimeyleBulunurBulunamazsaBaglanmaz() {
        let lines = [segment("Sprint planlamasına geçelim", 0, 5),
                     segment("Pazarlama bütçesi iki milyon lira olarak onaylandı", 60, 70),
                     segment("Haftaya tekrar bakarız", 200, 205)]
        let found = UserNote(id: 1, kind: .note, text: "pazarlama bütçesi", at: nil, details: [])
        #expect(NoteAnchor.bestMatch(found.text, in: lines)?.start == 60)
        #expect(NoteAnchor.window(for: found, in: lines).map(\.start) == [60])

        let missing = UserNote(id: 2, kind: .note, text: "işe alım takvimi", at: nil, details: [])
        #expect(NoteAnchor.window(for: missing, in: lines).isEmpty)
    }

    @Test
    func uzunPencereMerkezdenUzakUctanDaraltilir() {
        let lines = (0 ..< 10).map { segment(String(repeating: "k", count: 90),
                                             Double($0) * 10, Double($0) * 10 + 5) }
        let trimmed = NoteAnchor.trimmed(lines, limit: 400, center: 80)
        #expect(TranscriptChunker.render(trimmed).count <= 400)
        #expect(trimmed.contains { $0.start == 80 }, "merkez korunur")
        #expect(trimmed.first!.start >= 50)
    }

    // MARK: - İstem

    /// **Notsuz toplantıda istem ölçülen metinle bayt bayt aynıdır.**
    @Test
    func notsuzIstemDegismez() {
        let context = SummaryContext.empty
        #expect(context.notebook.isEmpty)
        #expect(FoundationIntelligence.notesBlock(context).isEmpty)
        #expect(FoundationIntelligence.markLine(context, chunk: "herhangi").isEmpty)
        #expect(LocalIntelligence.notebookBlock(context).isEmpty)
    }

    @Test
    func notlarVeIsaretliSatirlarIstemeGirer() {
        var context = SummaryContext.empty
        context.notebook = NotebookHints(notes: ["bütçe onayı"],
                                         markedLines: ["Pazarlama bütçesi onaylandı"])
        #expect(FoundationIntelligence.notesBlock(context).contains("- bütçe onayı"))
        #expect(FoundationIntelligence.markLine(context, chunk: "… Pazarlama bütçesi onaylandı …")
                    .contains("Pazarlama bütçesi onaylandı"))
        #expect(FoundationIntelligence.markLine(context, chunk: "başka parça").isEmpty,
                "işaret yalnızca kendi parçasında söylenir")
        let local = LocalIntelligence.prompt(body: "X", context: context)
        #expect(local.contains("- bütçe onayı"))
        #expect(local.contains("- Pazarlama bütçesi onaylandı"))
    }

    /// Pencere dar: bütçeyi aşan not **kırpılmaz**, dışarıda kalır.
    @Test
    func notBloguButceyiAsmaz() {
        let long = String(repeating: "a", count: NotebookHints.characterBudget)
        let notes = [UserNote(id: 1, kind: .note, text: "kısa not", at: 5, details: []),
                     UserNote(id: 2, kind: .note, text: long, at: 6, details: []),
                     UserNote(id: 3, kind: .mark, text: "", at: 12, details: [])]
        let hints = NotebookHints.from(notes, segments: [segment("işaretli satır", 10, 14)])
        #expect(hints.notes == ["kısa not"])
        #expect(hints.markedLines == ["işaretli satır"])
    }

    // MARK: - Denetleyici ve hat

    /// Kayıt sırasında kenar çubuğunda başka toplantıya tıklansa da not
    /// **kaydedilen** toplantıya düşer ve zaman damgası alır.
    @Test
    func kayitSirasindakiNotKaydedilenToplantiyaDuser() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A", step: .milliseconds(5)))
        let other = try await h.seed(text: "eski toplantı")
        await h.controller.start()
        await waitUntil("kayıt başladı") { h.controller.isRecording }
        let recording = try #require(h.controller.selection)

        h.controller.selection = other
        await h.controller.addNote("fiyat teklifi", startedAt: 42)
        await h.controller.markMoment()

        #expect(h.controller.liveNotes.map(\.text) == ["", "fiyat teklifi"])
        #expect(h.controller.liveNotes.last?.at == 42)
        #expect(try await h.store.notes(other).isEmpty, "seçili toplantıya yazılmadı")
        #expect(try await h.store.notes(recording).count == 2)
    }

    /// İşaretin anlamı kayıttaki yeridir; kayıt dışında bir şey yapmaz.
    @Test
    func kayitDisindaIsaretKonmaz() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let id = try await h.seed(text: "metin")
        await h.controller.refresh()
        h.controller.selection = id
        await h.controller.markMoment()
        #expect(try await h.store.notes(id).isEmpty)
    }

    /// Notlar özet istemine girer ve özetten sonra altlarına ayrıntı eklenir;
    /// ekrandaki notlar ayrıntılarıyla güncellenir.
    @Test
    func notlarOzeteGirerVeZenginlestirilir() async throws {
        let intelligence = SlowIntelligence(tag: "A", step: .milliseconds(5))
        let h = try Harness(intelligence: intelligence)
        let id = try await h.seed(text: "Pazarlama bütçesi iki milyon lira")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("transkript yüklendi") { !h.controller.transcript.isEmpty }
        await h.controller.addNote("bütçe onayı")
        #expect(h.controller.notes.map(\.text) == ["bütçe onayı"])

        await h.controller.summarizeNow()

        #expect(intelligence.contexts.last?.notebook.notes == ["bütçe onayı"])
        #expect(intelligence.enrichedNotes == ["bütçe onayı"])
        await waitUntil("ayrıntı ekrana geldi") {
            h.controller.notes.first?.details == ["A ayrıntı: bütçe onayı"]
        }
        #expect(try await h.store.notes(id).first?.details == ["A ayrıntı: bütçe onayı"])
    }

    /// Notsuz toplantıda zenginleştirme hiç çağrılmaz ve bağlam boştur.
    @Test
    func notsuzToplantidaZenginlestirmeYok() async throws {
        let intelligence = SlowIntelligence(tag: "A", step: .milliseconds(5))
        let h = try Harness(intelligence: intelligence)
        let id = try await h.seed(text: "metin")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("transkript yüklendi") { !h.controller.transcript.isEmpty }

        await h.controller.summarizeNow()

        #expect(intelligence.contexts.last?.notebook.isEmpty == true)
        #expect(intelligence.enrichedNotes.isEmpty)
    }

    @Test
    func disaAktarimNotlariIcerir() {
        let payload = MeetingExport.Payload(
            title: "T", date: .now, duration: 60, segments: [], summary: nil, topics: [],
            actions: [], participants: [],
            notes: [UserNote(id: 1, kind: .note, text: "bütçe", at: 65,
                             details: ["Bütçe 2 milyon TL."]),
                    UserNote(id: 2, kind: .mark, text: "", at: 90, details: [])])
        let markdown = MeetingExport.markdown(payload)
        #expect(markdown.contains("#### Notlarım"))
        #expect(markdown.contains("- **bütçe** `01:05`"))
        #expect(markdown.contains("  - Bütçe 2 milyon TL."))
        #expect(markdown.contains("- ⚑ Önemli an `01:30`"))
    }
}
