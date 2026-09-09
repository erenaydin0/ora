import Foundation
import Testing
@testable import ora

/// Adım 1-2'nin açtığı dikişin denetimi: hat görünüm durumu tanımaz, ürettiği
/// her şeyi `meetingID` taşıyan olay olarak yayar ve **birden çok** tüketici
/// dinleyebilir. İleride hafıza, otomasyon ve MCP buraya bağlanacak.
@Suite("Hat dikişi", .serialized)
struct PipelineSeamTests {

    private func makePipeline(_ h: Harness,
                              intelligence: any Intelligent,
                              transcription: any Transcribing = FakeTranscription())
    -> MeetingPipeline {
        MeetingPipeline(store: h.store,
                        vocabularyStore: VocabularyStore(database: h.database),
                        transcription: transcription,
                        intelligence: intelligence,
                        settings: h.settings,
                        deferReason: { nil },
                        prepareLocale: { _, progress in progress(1) })
    }

    /// Arayüzün dışında ikinci bir tüketici de olayları eksiksiz görür.
    @Test
    func ikinciTuketiciOlaylariGorur() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A", step: .milliseconds(10)))
        let pipeline = makePipeline(h, intelligence: SlowIntelligence(tag: "P",
                                                                     step: .milliseconds(10)))
        let id = try await h.seed(text: "toplantı metni")

        var seen: [PipelineEvent] = []
        pipeline.observe { seen.append($0) }

        let segments = [Segment(channel: .mic, speaker: "Ben", text: "toplantı metni",
                                start: 0, end: 10, confidence: 0.9, words: [])]
        await pipeline.summarize(meetingID: id, segments: segments)

        #expect(seen.allSatisfy { $0.meetingID == id }, "her olay kendi toplantısını taşıyor")
        #expect(seen.contains { if case .summary = $0.kind { true } else { false } },
                "özet olayı yayıldı")
        #expect(seen.contains { if case .storeChanged = $0.kind { true } else { false } },
                "depolama değişikliği yayıldı")
        #expect(seen.contains { if case .finished = $0.kind { true } else { false } },
                "bitiş yayıldı")
        #expect(seen.last.map { if case .finished = $0.kind { true } else { false } } == true,
                "bitiş en sonda")
        #expect(!pipeline.isRunning, "hat kapandı")
    }

    /// Hattın kendi kaydı: koşarken `isRunning`, bitince değil. Aşama
    /// **veritabanından türetilmez**.
    @Test
    func kosarkenIsRunningDogru() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A", step: .milliseconds(10)))
        let pipeline = makePipeline(h, intelligence: SlowIntelligence(tag: "P",
                                                                      step: .milliseconds(200)))
        let id = try await h.seed(text: "metin")
        let segments = [Segment(channel: .mic, speaker: "Ben", text: "metin",
                                start: 0, end: 10, confidence: 0.9, words: [])]

        #expect(!pipeline.isRunning)
        let job = Task { await pipeline.summarize(meetingID: id, segments: segments) }
        await waitUntil("hat koşuyor") { pipeline.isRunning }
        _ = await job.value
        #expect(!pipeline.isRunning)
    }

    /// Başlık önceliği: **takvim etkinlik adı** üretilmiş başlığı yener.
    /// Eskiden bu karar kayıt oturumunun `activeEvent`'inden okunuyordu; o da
    /// "Şimdi özetle" ve "Yeniden dene" yollarında her zaman nil olduğu için
    /// takvimden gelen ad üretilmiş adla eziliyordu.
    @Test
    func takvimBasligiUretilmisBasligiYener() async throws {
        let model = SlowIntelligence(tag: "A", step: .milliseconds(10))
        model.generatedTitle = "Üretilmiş Başlık"
        let h = try Harness(intelligence: model)
        let id = try await h.seed(text: "toplantı metni")
        try await h.store.linkCalendarEvent(id, event: MeetingEvent(
            eventID: "evt-1", title: "Bordro Toplantısı", start: Date(), end: Date(),
            organizer: nil, attendees: [], meetingApp: nil, isCancelled: false,
            myStatus: .accepted, organizerIsMe: false))
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("yüklendi") { !h.controller.transcript.isEmpty }

        await h.controller.summarizeNow()

        let row = try await h.store.load(id)
        #expect(row?.meeting.title == "Bordro Toplantısı",
                "takvim başlığı korundu (gelen: \(row?.meeting.title ?? "yok"))")
    }

    /// Takvim bağı yoksa başlık transkriptten üretilir.
    @Test
    func takvimYoksaBaslikUretilir() async throws {
        let model = SlowIntelligence(tag: "A", step: .milliseconds(10))
        model.generatedTitle = "Üretilmiş Başlık"
        let h = try Harness(intelligence: model)
        let id = try await h.seed(text: "toplantı metni")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("yüklendi") { !h.controller.transcript.isEmpty }

        await h.controller.summarizeNow()

        let row = try await h.store.load(id)
        #expect(row?.meeting.title == "Üretilmiş Başlık")
    }
}
