import Foundation
import Testing
@testable import ora

/// İşlem hattının kırılma noktaları. Hepsinin ortak kuralı CLAUDE.md'den:
/// **ham veri korunur, hata kullanıcıya Türkçe ulaşır, uygulama işlevsiz
/// kalmaz.**
@Suite("İşlem hattı", .serialized)
struct PipelineTests {

    /// Özetleme başarısız olursa transkript **korunur** ve kullanıcıya not
    /// düşülür. Bu, önceki ora'nın en pahalı hatasının karşı testi.
    @Test
    func ozetlemeBasarisizsaTranskriptKorunur() async throws {
        let h = try Harness(intelligence: FailingIntelligence())
        let id = try await h.seed(text: "toplantı metni")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("transkript yüklendi") { !h.controller.transcript.isEmpty }

        await h.controller.summarizeNow()

        #expect(h.controller.transcript.first?.text == "toplantı metni",
                "ekrandaki transkript duruyor")
        #expect(h.controller.summary == nil, "özet üretilmedi")
        #expect(h.controller.summaryNotice != nil, "kullanıcıya Türkçe not düşüldü")
        let row = try await h.store.load(id)
        #expect(row?.segments.first?.text == "toplantı metni",
                "veritabanındaki transkript bozulmadı")
    }

    /// Apple Intelligence kapalıysa özet atlanır, transkript yine gösterilir.
    /// `UnavailableIntelligence` çağrılırsa kendisi hata kaydeder.
    @Test
    func modelKullanilamiyorsaTranskriptGosterilir() async throws {
        let h = try Harness(intelligence: UnavailableIntelligence())
        let id = try await h.seed(text: "toplantı metni")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("transkript yüklendi") { !h.controller.transcript.isEmpty }

        await h.controller.summarizeNow()

        #expect(h.controller.transcript.first?.text == "toplantı metni")
        #expect(h.controller.summary == nil)
        #expect(h.controller.summaryNotice?.contains("Apple Intelligence") == true,
                "not Apple Intelligence'ı işaret ediyor")
        #expect(!h.controller.canSummarize, "model yokken elle özetleme kapısı kapalı")
    }

    /// Güç/termal baskısında özetleme **otomatik başlamaz**, kullanıcıya
    /// sorulur — ve elle başlatma kapısı açık kalır.
    @Test
    func gucErtelemesindeOzetlemeOtomatikBaslamaz() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A", step: .milliseconds(20)),
                            deferReason: { .lowPowerMode })
        let id = try await h.seed(text: "toplantı metni")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("transkript yüklendi") { !h.controller.transcript.isEmpty }

        await h.controller.summarizeNow()

        #expect(h.controller.summary == nil, "özet otomatik üretilmedi")
        #expect(h.controller.deferReason == .lowPowerMode, "erteleme nedeni ekranda")
        #expect(h.controller.summaryNotice?.contains("Düşük Güç Modu") == true)
        #expect(h.controller.canSummarize, "elle özetleme hâlâ mümkün")
        #expect(h.controller.transcriptionStage == .done, "aşama açık kalmadı")
    }

    /// Başarısız/yarım kalmış bir toplantı ham sesten yeniden işlenir.
    /// Hata mesajı "daha sonra tekrar deneyebilirsiniz" diyor; testi o vaadin
    /// karşılığıdır.
    @Test
    func yenidenDeneHamSestenIsler() async throws {
        let audio = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ora-test-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: audio.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: audio) }

        let produced = [Segment(channel: .mic, speaker: "Ben", text: "yeniden üretilen metin",
                                start: 0, end: 5, confidence: 0.8, words: [])]
        let h = try Harness(intelligence: SlowIntelligence(tag: "R", step: .milliseconds(20)),
                            transcription: FakeTranscription(segments: produced))

        // Transkripti olmayan, ama sesi diskte duran bir toplantı.
        let id = try await h.store.createMeeting()
        try await h.store.markProcessing(id, audioPath: audio, duration: 5)
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("yeniden deneme mümkün") { h.controller.canRetry }

        await h.controller.retryProcessing()

        #expect(h.controller.transcript.first?.text == "yeniden üretilen metin.",
                "transkript üretildi (noktalama uygulanmış)")
        #expect(h.controller.summary?.genelBakis.first?.hasPrefix("R genel bakış") == true,
                "özet de üretildi")
        #expect(h.controller.retryableAudio == nil, "başarıdan sonra düğme kalkıyor")
        let row = try await h.store.load(id)
        #expect(row?.segments.first?.text == "yeniden üretilen metin.")
    }

    /// Hat koşarken toplantı silinirse uygulama çökmez ve satır gerçekten gider.
    @Test
    func hatKosarkenToplantiSilinebilir() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A", step: .milliseconds(150)))
        let id = try await h.seed(text: "silinecek toplantı")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("transkript yüklendi") { !h.controller.transcript.isEmpty }

        let job = Task { await h.controller.summarizeNow() }
        await waitUntil("hat başladı") { h.controller.isProcessingSelected }
        await h.controller.delete(id)
        _ = await job.value
        await settle()

        #expect(h.controller.selection == nil, "seçim temizlendi")
        #expect(try await h.store.load(id) == nil, "satır silindi")
        #expect(h.controller.meetings.isEmpty, "liste boş")
    }

    /// Kayıt başlatılamazsa (mikrofon izni yok) yarım toplantı satırı kalmaz.
    @Test
    func kayitBaslatilamazsaSatirBirakilmaz() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A", step: .milliseconds(20)))
        h.capture.startError = .permissionDenied(.microphone)

        await h.controller.start()

        #expect(h.controller.error != nil, "hata kullanıcıya ulaştı")
        #expect(!h.controller.isRecording)
        #expect(h.controller.meetings.isEmpty, "yarım toplantı satırı silindi")
        let rows = try await h.store.list()
        #expect(rows.isEmpty, "veritabanında da kalmadı")
    }

    /// Yeniden üretim var olan özeti silmez ve serbest örneklemeyle çalışır.
    @Test
    func yenidenUretimVarOlanOzetiSilmez() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A", step: .milliseconds(20)))
        let id = try await h.seed(text: "toplantı metni")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("transkript yüklendi") { !h.controller.transcript.isEmpty }

        await h.controller.summarizeNow()
        #expect(h.controller.canResummarize)

        await h.controller.resummarize()
        #expect(h.controller.summary?.genelBakis.first?.contains("(yeniden)") == true,
                "yeniden üretim serbest örneklemeyle koştu")
        let row = try await h.store.load(id)
        #expect(row?.summary != nil, "veritabanındaki özet duruyor")
    }
}
