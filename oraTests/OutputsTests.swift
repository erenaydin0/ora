import Foundation
import Testing
@testable import ora

/// Yerel çıkışlar (COMPETITION.md §4.12): Markdown klasörü, Hatırlatıcılar,
/// Kısayollar. Hiçbiri ağ kullanmaz.
@Suite("Yerel çıkışlar", .serialized)
struct OutputsTests {

    private func folder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ora-md-\(UUID().uuidString)", isDirectory: true)
    }

    /// Özeti ve aksiyonu olan hazır bir toplantı.
    private func meeting(_ h: Harness, title: String = "Bütçe") async throws -> Int64 {
        let id = try await h.seed(text: "bütçe onaylandı")
        try await h.store.updateTitle(id, title: title)
        try await h.store.saveSummary(id, ozet: Ozet(
            genelBakis: ["Bütçe 2 milyon TL olarak onaylandı."], kararlar: [],
            aksiyonlar: [Ozet.Aksiyon(kisi: "Ayşe", gorev: "Teklifi gönder",
                                      baglam: "Müşteri fiyat istedi.", sonTarih: "Cuma")]),
            topics: [])
        return id
    }

    // MARK: - Markdown klasörü

    @Test
    func esitlenenKlasorTaninir() {
        #expect(MarkdownFolder.isSynced("/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Notlar"))
        #expect(MarkdownFolder.isSynced("/Users/a/Library/CloudStorage/Dropbox/Notlar"))
        #expect(!MarkdownFolder.isSynced("/Users/a/Documents/Obsidian"))
    }

    @Test
    func notKunyeVeEtiketlerleYazilirAyniDosyaninUstuneYazilir() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = MeetingExport.Payload(
            title: "Bütçe", date: .now, duration: 60,
            segments: [Segment(channel: .mic, speaker: "Ben", text: "transkript satırı",
                               start: 0, end: 1, confidence: nil, words: [])],
            summary: Ozet(genelBakis: ["g"], kararlar: [], aksiyonlar: []),
            topics: [], actions: [], participants: [])

        let url = try MarkdownFolder.write(payload, meetingID: 7, tags: ["müşteri"],
                                           to: dir, includeTranscript: false)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("---\nora: 7\n"))
        #expect(text.contains("tags: [\"müşteri\"]"))
        #expect(text.contains("# Bütçe"))
        #expect(!text.contains("transkript satırı"), "transkript varsayılan kapalı")

        let again = try MarkdownFolder.write(payload, meetingID: 7, tags: [], to: dir,
                                             includeTranscript: true)
        #expect(again == url, "yeniden özetleme aynı dosyanın üstüne yazar")
        #expect(try String(contentsOf: again, encoding: .utf8).contains("transkript satırı"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
    }

    /// "Cihazdan çıkmasın" işaretli toplantı klasöre yazılmaz — klasör
    /// eşitleniyor olabilir.
    @Test
    func kilitliToplantiKlasoreYazilmaz() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        h.settings.markdownFolder = dir.path(percentEncoded: false)
        let open = try await meeting(h, title: "Açık")
        let locked = try await meeting(h, title: "Gizli")
        try await h.store.setLocalOnly(locked, true)

        await h.controller.writeMarkdown(meetingID: open)
        await h.controller.writeMarkdown(meetingID: locked)

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1)
        #expect(files.first?.contains("Açık") == true)
    }

    @Test
    func klasorSecilmemisseHicbirSeyYazilmaz() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let id = try await meeting(h)
        #expect(h.settings.markdownFolder.isEmpty, "varsayılan kapalı")
        await h.controller.writeMarkdown(meetingID: id)
        #expect(h.controller.error == nil)
    }

    // MARK: - Hatırlatıcılar

    @Test
    func izinVerilmezseAyarKapaliKalir() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"),
                            reminders: FakeReminders(granted: false))
        await h.controller.setRemindersEnabled(true)
        #expect(!h.settings.remindersEnabled)
        #expect(h.controller.error?.turkishMessage == "Hatırlatıcılar izni verilmedi")
    }

    @Test
    func aksiyonBirKezEklenirVeKimligiSaklanir() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let id = try await meeting(h)
        let actionID = try #require(try await h.store.load(id)?.actions.first?.id)

        #expect(await h.controller.addToReminders(actionID: actionID) == false,
                "ayar kapalıyken eklenmez")
        await h.controller.setRemindersEnabled(true)
        #expect(await h.controller.addToReminders(actionID: actionID))
        #expect(await h.controller.addToReminders(actionID: actionID) == false, "ikinci kez yok")

        #expect(h.reminders.added.count == 1)
        #expect(h.reminders.added.first?.title == "Teklifi gönder")
        let notes = try #require(h.reminders.added.first?.notes)
        #expect(notes.contains("Müşteri fiyat istedi."))
        #expect(notes.contains("Sorumlu: Ayşe"))
        #expect(notes.contains("Son tarih: Cuma"), "son tarih metin olarak, tarihe çevrilmez")
        #expect(try await h.store.load(id)?.actions.first?.reminderID == "hatirlatici-1")
    }

    @Test
    func kilitliToplantininAksiyonuHatirlaticiyaEklenmez() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let id = try await meeting(h)
        try await h.store.setLocalOnly(id, true)
        let actionID = try #require(try await h.store.load(id)?.actions.first?.id)
        await h.controller.setRemindersEnabled(true)

        #expect(await h.controller.addToReminders(actionID: actionID) == false)
        #expect(h.reminders.added.isEmpty)
        #expect(h.controller.error != nil, "neden söylenir")
    }

    // MARK: - Kısayollar

    @Test
    func sonToplantininOzetiOkunur() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        _ = try await meeting(h, title: "Bütçe")
        let text = try #require(await h.controller.lastMeetingSummary())
        #expect(text.hasPrefix("Bütçe — "))
        #expect(text.contains("• Bütçe 2 milyon TL olarak onaylandı."))
        #expect(text.hasSuffix("1 açık aksiyon var."))
    }

    @Test
    func ozetYoksaKisayolBosDoner() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        _ = try await h.seed(text: "özetsiz")
        #expect(await h.controller.lastMeetingSummary() == nil)
    }
}
