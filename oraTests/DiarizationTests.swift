import AVFoundation
import Foundation
import Testing
@testable import ora

/// Konuşmacı ayrımı (COMPETITION.md §4.13, RESEARCH.md §39).
///
/// Ölçtüğü şey modelin doğruluğu değil **politika**: hangi kanal ayrılır,
/// tur kelimeye nasıl dağılır, küme nasıl adlandırılır, başarısızlıkta ne
/// korunur. Son iki test gerçek modellerin pakette olduğunu ve ağa çıkmadan
/// koştuğunu denetler.
@Suite("Konuşmacı ayrımı", .serialized)
struct DiarizationTests {

    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> WordTiming {
        WordTiming(text: text, start: start, end: end, confidence: 0.9)
    }

    private func turn(_ start: TimeInterval, _ end: TimeInterval, _ speaker: String) -> SpeakerTurn {
        SpeakerTurn(start: start, end: end, speaker: speaker)
    }

    /// İki turu kapsayan bir segment kelime sınırından bölünür; kümeler ilk
    /// konuşma sırasına göre numaralanır. Mikrofon kanalına dokunulmaz.
    @Test
    func ikiTuruKapsayanSegmentKelimedenBolunur() {
        let segments = [
            Segment(channel: .mic, speaker: "Ben", text: "tamam anlaştık",
                    start: 0, end: 2, confidence: 0.9, words: []),
            Segment(channel: .system, speaker: "Katılımcı",
                    text: "bütçe onaylandı ben raporu hazırlarım",
                    start: 2, end: 10, confidence: 0.9,
                    words: [word("bütçe", 2, 3), word("onaylandı", 3, 5),
                            word("ben", 6, 6.5), word("raporu", 6.5, 8),
                            word("hazırlarım", 8, 10)]),
        ]
        let turns = [turn(1.5, 5.5, "S2"), turn(5.5, 20, "S1")]

        let result = SpeakerSeparation.apply(turns, to: segments, channel: .system)

        #expect(result.count == 3)
        #expect(result[0].speaker == "Ben", "mikrofon kanalı olduğu gibi")
        #expect(result[1].speaker == "Katılımcı 1")
        #expect(result[1].text == "bütçe onaylandı")
        #expect(result[1].start == 2, "ilk parça segmentin başından")
        #expect(result[2].speaker == "Katılımcı 2")
        #expect(result[2].text == "ben raporu hazırlarım")
        #expect(result[2].end == 10, "son parça segmentin sonuna kadar")
        #expect(result.allSatisfy { $0.channel != .system || $0.words.count > 0 })
    }

    /// Tek kelimelik sıçrama ayrı satır olmaz, komşusuna katılır.
    @Test
    func kisaSicramaKomsusunaKatilir() {
        let segment = Segment(channel: .system, speaker: "Katılımcı",
                              text: "şunu da ekleyelim evet sonra bakarız",
                              start: 0, end: 8, confidence: 0.9,
                              words: [word("şunu", 0, 1), word("da", 1, 1.5),
                                      word("ekleyelim", 1.5, 3), word("evet", 3.1, 3.4),
                                      word("sonra", 4, 5), word("bakarız", 5, 8)])
        let turns = [turn(0, 3, "S1"), turn(3, 3.5, "S2"), turn(3.5, 8, "S1"),
                     turn(10, 20, "S2")]

        // İkinci küme gerçekten de konuşuyor — yalnızca "evet" sıçraması kısa.
        let other = Segment(channel: .system, speaker: "Katılımcı", text: "katılıyorum",
                            start: 10, end: 20, confidence: 0.9, words: [])

        let result = SpeakerSeparation.apply(turns, to: [segment, other], channel: .system)

        #expect(result.count == 2, "\"evet\" ayrı satır olmadı")
        #expect(result.first?.text == segment.text, "bölünmeyen satırın metni aynen korunur")
        #expect(result.map(\.speaker) == ["Katılımcı 1", "Katılımcı 2"])
    }

    /// Tek küme çıkarsa hiçbir şey değişmez — "Katılımcı" zaten doğrudur.
    /// Konuşması 3 sn'nin altında kalan küme gürültü sayılır.
    @Test
    func tekKumeVeGurultuEtiketiDegistirmez() {
        let segment = Segment(channel: .system, speaker: "Katılımcı", text: "tek kişi konuşuyor",
                              start: 0, end: 30, confidence: 0.9, words: [])
        let turns = [turn(0, 30, "S1"), turn(12, 13, "S2")]

        let result = SpeakerSeparation.apply(turns, to: [segment], channel: .system)

        #expect(result == [segment])
    }

    /// Yüz yüze toplantı: en çok konuşan küme "Ben" kalır, diğeri numaralanır.
    @Test
    func yuzYuzeToplantidaSahibiBenKalir() {
        let segments = [
            Segment(channel: .mic, speaker: "Ben", text: "kısa soru",
                    start: 0, end: 3, confidence: 0.9, words: []),
            Segment(channel: .mic, speaker: "Ben", text: "uzun bir anlatım",
                    start: 3, end: 20, confidence: 0.9, words: []),
        ]
        let turns = [turn(0, 3, "S1"), turn(3, 20, "S2")]

        #expect(SpeakerSeparation.channel(for: segments) == .mic)
        let result = SpeakerSeparation.apply(turns, to: segments, channel: .mic)

        #expect(result[0].speaker == "Katılımcı 1")
        #expect(result[1].speaker == "Ben", "en çok konuşan mikrofonun sahibi")
    }

    /// Sistem kanalında konuşma varsa ayrılan odur — mikrofondaki sızıntı
    /// sahte bir konuşmacıya dönmesin.
    @Test
    func sistemKanaliVarsaOnuAyirir() {
        let mic = Segment(channel: .mic, speaker: "Ben", text: "a", start: 0, end: 1,
                          confidence: nil, words: [])
        let system = Segment(channel: .system, speaker: "Katılımcı", text: "b", start: 1, end: 2,
                             confidence: nil, words: [])
        #expect(SpeakerSeparation.channel(for: [mic, system]) == .system)
        #expect(SpeakerSeparation.channel(for: []) == nil)
    }

    /// Numaralı küme kişi değildir: katılımcı listesine, sözlüğe ve aksiyon
    /// sahibine girmez; özetteki etiket sızıntısı da temizlenir.
    @Test
    func numaraliEtiketKisiSayilmaz() {
        #expect(MeetingStore.isChannelLabel("Katılımcı 2"))
        #expect(MeetingStore.isChannelLabel("katılımcı 12"))
        #expect(!MeetingStore.isChannelLabel("Ayşe 2"))
        #expect(!MeetingStore.isChannelLabel("Ayşe"))
        // Küme bir ad değil ama iz: aksiyon kümeye bağlı kalır, kanonik biçimde.
        #expect(FoundationIntelligence.resolvedPerson("katılımcı 2", context: .empty)
                    == "Katılımcı 2")
        #expect(FoundationIntelligence.resolvedPerson("Katılımcı", context: .empty)
                    == "belirtilmedi")
        #expect(FoundationIntelligence.withoutSpeakerPrefix("Katılımcı 2: rapor hazırlanacak")
                    == "Rapor hazırlanacak")
        #expect(FoundationIntelligence.withoutSpeakerPrefix("Katılımcı 2 raporu hazırlayacak")
                    == "Raporu hazırlayacak")
        #expect(FoundationIntelligence.withoutSpeakerPrefix("Ben 2024 bütçesini hazırlayacak")
                    == "2024 bütçesini hazırlayacak", "yıl kesilmez")
    }

    // MARK: - Hat

    private func runFullPass(diarizer: FakeDiarizer,
                             enabled: Bool = true) async throws -> [Segment] {
        let audio = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ora-test-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: audio.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: audio) }

        let produced = [
            Segment(channel: .system, speaker: "Katılımcı", text: "bütçe onaylandı",
                    start: 0, end: 5, confidence: 0.9, words: []),
            Segment(channel: .system, speaker: "Katılımcı", text: "raporu ben hazırlarım",
                    start: 5, end: 12, confidence: 0.9, words: []),
        ]
        let h = try Harness(intelligence: SlowIntelligence(tag: "D", step: .milliseconds(5)),
                            transcription: FakeTranscription(segments: produced),
                            diarizer: diarizer)
        h.settings.speakerSeparationEnabled = enabled
        let id = try await h.store.createMeeting()
        try await h.store.markProcessing(id, audioPath: audio, duration: 12)
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("yeniden deneme mümkün") { h.controller.canRetry }
        await h.controller.retryProcessing()
        return try #require(try await h.store.load(id)).segments
    }

    /// Tam geçişten sonra kümeler transkripte ve veritabanına yazılır;
    /// noktalama etiketi korur.
    @Test
    func hatKumeleriTranskripteYazar() async throws {
        let segments = try await runFullPass(diarizer: FakeDiarizer(
            turns: [turn(0, 5, "S1"), turn(5, 12, "S2")]))
        #expect(segments.map(\.speaker) == ["Katılımcı 1", "Katılımcı 2"])
    }

    /// Ayrım başarısız olursa transkript kanal etiketiyle kalır, hat durmaz.
    @Test
    func ayrimBasarisizsaTranskriptKorunur() async throws {
        let segments = try await runFullPass(diarizer: FakeDiarizer(
            error: .diarizationFailed(reason: "test")))
        #expect(segments.map(\.speaker) == ["Katılımcı", "Katılımcı"])
        #expect(segments.count == 2)
    }

    /// Ayar kapalıysa motor hiç çağrılmaz.
    @Test
    func ayarKapaliysaAyrimYapilmaz() async throws {
        let segments = try await runFullPass(
            diarizer: FakeDiarizer(turns: [turn(0, 5, "S1"), turn(5, 12, "S2")]),
            enabled: false)
        #expect(segments.map(\.speaker) == ["Katılımcı", "Katılımcı"])
    }

    // MARK: - Gerçek modeller

    /// Modeller uygulama paketinde ve `ModelHub`'a dokunmadan yükleniyor.
    @Test
    func modellerPakettenYuklenir() throws {
        let diarizer = FluidDiarizer()
        #expect(diarizer.isAvailable, "Diarization.bundle uygulamada yok")
        let url = try #require(diarizer.modelsURL)
        let models = try FluidDiarizer.loadModels(from: url)
        #expect(!models.pldaPsi.isEmpty)
    }

    /// Stereo bir kaydın tek kanalı uçtan uca, çevrimdışı işlenir. Ses
    /// konuşma değil (iki farklı ton), bu yüzden küme sayısı ölçülmez —
    /// ölçülen, kanal okuma + CoreML çalıştırma zincirinin hatasız koşması.
    @Test
    func stereoKaydinTekKanaliCevrimdisiIslenir() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ora-diarize-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeStereoTones(to: url, seconds: 24)

        let source = try ChannelSampleSource(url: url, channel: .system)
        defer { source.cleanup() }
        #expect(source.sampleCount == 24 * 16_000, "kanal 16 kHz mono'ya çevrildi")

        _ = try await FluidDiarizer().turns(url: url, channel: .system) { _ in }
    }

    /// 16 kHz · 16 bit · stereo (kural #11): ch0 sessiz, ch1'de iki ton sırayla.
    static func writeStereoTones(to url: URL, seconds: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let right = try #require(buffer.floatChannelData?[1])
        for index in 0 ..< Int(frames) {
            let t = Double(index) / 16_000
            let pitch = Int(t) / 6 % 2 == 0 ? 180.0 : 310.0
            right[index] = Float(0.3 * sin(2 * .pi * pitch * t))
        }
        try file.write(from: buffer)
    }

    // MARK: - Adlandırınca aksiyonlar

    private func seedClustered(_ store: MeetingStore) async throws -> Int64 {
        let id = try await store.createMeeting()
        try await store.replaceTranscript(id, segments: [
            Segment(channel: .system, speaker: "Katılımcı 1", text: "bütçe onaylandı",
                    start: 0, end: 4, confidence: 0.9, words: []),
            Segment(channel: .system, speaker: "Katılımcı 2", text: "raporu ben hazırlarım",
                    start: 4, end: 8, confidence: 0.9, words: []),
            Segment(channel: .system, speaker: "Katılımcı 2", text: "cumaya kadar",
                    start: 8, end: 10, confidence: 0.9, words: []),
        ])
        try await store.saveSummary(id, ozet: Ozet(
            genelBakis: ["Bütçe onaylandı."], kararlar: [],
            aksiyonlar: [Ozet.Aksiyon(kisi: "Katılımcı 2", gorev: "Raporu hazırla",
                                      baglam: "", sonTarih: "Cuma")]),
            topics: [])
        try await store.markReady(id)
        return id
    }

    /// Kümenin bütün satırları adlandırılınca ona düşen aksiyon da yeni ada
    /// geçer — yeniden özetlemeden.
    @Test
    func kumeAdlandirilincaAksiyonSahibiDegisir() async throws {
        let store = MeetingStore(database: try OraDatabase(path: ":memory:"))
        let id = try await seedClustered(store)

        try await store.setSpeaker(meetingID: id, channel: .system,
                                   from: "Katılımcı 2", to: "Ayşe")

        let actions = try #require(try await store.load(id)).actions
        #expect(actions.map(\.person) == ["Ayşe"])
    }

    /// Etiketin bir satırı bile kaldıysa aksiyon kime ait bilinmiyor —
    /// dokunulmaz. Kalan satır da adlandırılınca taşınır.
    @Test
    func etiketKalirsaAksiyonaDokunulmaz() async throws {
        let store = MeetingStore(database: try OraDatabase(path: ":memory:"))
        let id = try await seedClustered(store)
        let segments = try #require(try await store.load(id)).segments
        let second = try #require(segments.first { $0.start == 4 })
        let third = try #require(segments.first { $0.start == 8 })

        try await store.setSpeaker(meetingID: id, segments: [second], speaker: "Ayşe")
        #expect(try #require(try await store.load(id)).actions.map(\.person) == ["Katılımcı 2"])

        try await store.setSpeaker(meetingID: id, segments: [third], speaker: "Ayşe")
        #expect(try #require(try await store.load(id)).actions.map(\.person) == ["Ayşe"])
    }
}
