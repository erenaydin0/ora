import Foundation
import Testing
@testable import ora

/// Toplantı şablonları (COMPETITION.md §4.7). Şablon şemayı değil talimatı
/// değiştirir; **Genel'de istem ölçülen metnin bayt bayt aynısıdır.**
@Suite("Şablonlar", .serialized)
struct TemplateTests {

    // MARK: - İstem

    /// §23-37 ölçümleri bu metinle alındı. Değişirse ölçüm geçersizleşir.
    @Test
    func genelBirlestirmeIstemiOlculenMetinleAynidir() {
        let context = SummaryContext.empty
        let expected = """
            Below are topic-by-topic notes from a meeting. From them
            produce a 4-6 bullet overview of the meeting and the decisions
            that were made. Write everything in Turkish.
            Rules:
            - Each overview bullet is one sentence; first what happened,
              then its consequence.
            - Do not copy a bullet from the notes word for word; combine
              what belongs together and state the outcome.
            - Prefer the facts that carry numbers, amounts, dates and
              names; drop notes that only report that somebody spoke.
            - Do not write the meeting's date or duration in the overview.
            - A decision is something the group settled on; a subject
              heading or a topic name is not a decision.
            - Write as decisions only things that were actually decided;
              if nothing was decided, leave the list empty.
            - The overview and the decisions must not be the same sentences.
            \(FoundationIntelligence.dateLine(context))

            NOTLAR
            """
        #expect(FoundationIntelligence.reducePrompt(combined: "NOTLAR", context: context)
                    == expected)
    }

    @Test
    func genelParcaIstemineEkGirmez() {
        let prompt = FoundationIntelligence.chunkPrompt(text: "METİN", target: 3,
                                                        context: .empty)
        #expect(prompt.hasPrefix("""
            Turn this meeting excerpt into written notes. Produce at most
            3 topics. For each topic write a 2-6 word Turkish heading
            and bullets. If few topics are requested, write each one in more
            detail; give every important point its own bullet.

            Write for someone who was not in the room:
            """))
        #expect(prompt.hasSuffix("do not invent dates.\n\nMETİN"))
    }

    @Test
    func genelYerelIstemOlculenKuraliKorur() {
        let prompt = LocalIntelligence.prompt(body: "X", context: .empty)
        #expect(prompt.hasPrefix("""
            Aşağıda bir toplantının tam dökümü var. Toplantı notunu çıkar.

            Kurallar:
            """))
        #expect(prompt.contains(
            "\n- Karar, grubun üzerinde anlaştığı şeydir; konu başlığı karar değildir.\n"))
    }

    /// Genel ve sprint kararları aynı kuralla ister; diğerleri alanı yeniden
    /// tanımlar ve toplantının türünü söyler.
    @Test
    func sablonTalimatiDegistirirSemayiDegil() {
        for template in MeetingTemplate.allCases where template != .general {
            var context = SummaryContext.empty
            context.template = template
            let reduce = FoundationIntelligence.reducePrompt(combined: "N", context: context)
            let chunk = FoundationIntelligence.chunkPrompt(text: "T", target: 2, context: context)
            let local = LocalIntelligence.prompt(body: "X", context: context)
            #expect(reduce.contains(template.reduceFocus), "\(template)")
            #expect(chunk.contains(template.chunkFocus), "\(template)")
            #expect(local.contains(template.localFocus), "\(template)")
            #expect(local.contains("\"decisions\""), "JSON şeması değişmedi: \(template)")
            let keepsDecisions = template == .sprint
            #expect(reduce.contains("A decision is something the group settled on")
                        == keepsDecisions, "\(template)")
        }
        #expect(MeetingTemplate.general.chunkFocus.isEmpty)
        #expect(MeetingTemplate.general.reduceFocus.isEmpty)
        #expect(MeetingTemplate.general.localFocus.isEmpty)
    }

    @Test
    func bolumAdiSablonaGoreDegisir() {
        #expect(MeetingTemplate.general.decisionsTitle == "Kararlar")
        #expect(MeetingTemplate.oneOnOne.decisionsTitle == "Geri bildirim ve gelişim")
        #expect(MeetingTemplate.interview.decisionsTitle == "Aday hakkında öne çıkanlar")
        #expect(MeetingTemplate(stored: nil) == .general)
        #expect(MeetingTemplate(stored: "bilinmeyen") == .general)

        let payload = MeetingExport.Payload(
            title: "T", date: .now, duration: 60, segments: [],
            summary: Ozet(genelBakis: ["g"], kararlar: ["Aday Swift'te güçlü."],
                          aksiyonlar: []),
            topics: [], actions: [], participants: [],
            decisionsTitle: MeetingTemplate.interview.decisionsTitle)
        #expect(MeetingExport.markdown(payload).contains("#### Aday hakkında öne çıkanlar"))
    }

    // MARK: - Takvimden tahmin

    @Test
    func etkinlikAdindanSablonTahmini() {
        #expect(MeetingTemplate.guess(from: "Ayşe / Eren 1:1") == .oneOnOne)
        #expect(MeetingTemplate.guess(from: "Haftalık birebir") == .oneOnOne)
        #expect(MeetingTemplate.guess(from: "Sprint Planning") == .sprint)
        #expect(MeetingTemplate.guess(from: "Backend Mülakatı — Can") == .interview)
        #expect(MeetingTemplate.guess(from: "Acme müşteri görüşmesi") == .customer)
        #expect(MeetingTemplate.guess(from: "Bordro Toplantısı") == nil)
    }

    /// Tahmin yalnızca şablon Genel'ken uygulanır; kullanıcının seçimi ezilmez.
    @Test
    func takvimBagiSablonuOnerirAmaSecimiEzmez() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        func event(_ title: String) -> MeetingEvent {
            MeetingEvent(eventID: title, title: title, start: Date(), end: Date(),
                         organizer: nil, attendees: [], meetingApp: nil, isCancelled: false,
                         myStatus: .accepted, organizerIsMe: false)
        }
        let first = try await h.store.createMeeting()
        try await h.store.linkCalendarEvent(first, event: event("Sprint Planning"))
        #expect(try await h.store.load(first)?.meeting.template == "sprint")

        let second = try await h.store.createMeeting()
        try await h.store.setTemplate(second, .customer)
        try await h.store.linkCalendarEvent(second, event: event("Ayşe 1:1"))
        #expect(try await h.store.load(second)?.meeting.template == "customer")
    }

    // MARK: - Hat

    /// Şablon değişince yeniden özetleme yeni talimatla ve **varsayılan
    /// örneklemeyle** koşar (yeni istem, "başka bir özet ver" değil).
    @Test
    func sablonlaYenidenOzetlemeYeniTalimatiKullanir() async throws {
        let model = SlowIntelligence(tag: "A", step: .milliseconds(5))
        let h = try Harness(intelligence: model)
        let id = try await h.seed(text: "adayın deneyimi")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("transkript yüklendi") { !h.controller.transcript.isEmpty }
        await h.controller.summarizeNow()
        #expect(model.contexts.last?.template == .general)

        await h.controller.setTemplate(id, .interview)
        #expect(h.controller.selectedTemplate == .interview)
        await h.controller.resummarizeWithTemplate()

        #expect(model.contexts.last?.template == .interview)
        #expect(h.controller.summary?.aksiyonlar.first?.gorev == "A görev",
                "örnekleme serbestleşmedi (variation kapalı)")
    }

    /// Şablonla yeniden üretim başarısızsa eldeki özet silinmez.
    @Test
    func sablonlaYenidenOzetlemeBasarisizsaOzetKorunur() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A", step: .milliseconds(5)))
        let id = try await h.seed(text: "metin")
        try await h.store.saveSummary(id, ozet: Ozet(genelBakis: ["eski"], kararlar: [],
                                                     aksiyonlar: []), topics: [])
        // Aynı veritabanı üzerinde başarısız motorla koşmak için hattı doğrudan kur.
        let pipeline = MeetingPipeline(store: h.store,
                                       vocabularyStore: VocabularyStore(database: h.database),
                                       transcription: FakeTranscription(),
                                       intelligence: FailingIntelligence(),
                                       diarizer: FakeDiarizer(),
                                       settings: h.settings,
                                       deferReason: { nil },
                                       prepareLocale: { _, progress in progress(1) })
        await pipeline.summarize(meetingID: id,
                                 segments: try await h.store.load(id)?.segments ?? [],
                                 preservingExisting: true)
        #expect(try await h.store.load(id)?.summary?.genelBakis == ["eski"])
    }
}
