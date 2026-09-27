import Foundation
import GRDB
import Testing
@testable import ora

/// Kişileri toplantılar arasında tanıma (RESEARCH.md §40). Ölçülen şey
/// politika: ne zaman adlandırılır, ne zaman öğrenilir, yanlışlık nasıl geri
/// alınır. Gerçek ses izi kalitesi burada ölçülmez.
@Suite("Ses izleri", .serialized)
struct VoiceMemoryTests {

    private let ayse: [Float] = [1, 0, 0, 0]
    private let mehmet: [Float] = [0, 1, 0, 0]
    private let ayseAgain: [Float] = [0.95, 0.1, 0.05, 0]

    // MARK: - Eşleştirme

    @Test
    func netBenzerlikTanınırBelirsizlikTanınmaz() {
        let people = ["Ayşe": [ayse], "Mehmet": [mehmet]]

        let clear = VoiceMatcher.assign(clusters: ["S1": ayseAgain, "S2": [0, 0, 1, 0]],
                                        people: people)
        #expect(clear == ["S1": "Ayşe"], "S2 kimseye benzemiyor")

        // İki kişinin tam ortası: ikisi arasında fark yok → adlandırılmaz.
        let between = VoiceMatcher.assign(clusters: ["S1": [0.7, 0.7, 0, 0]], people: people)
        #expect(between.isEmpty)
    }

    /// Aynı kişi iki kümeye verilmez; yalnızca açıkça en iyi olan alır.
    @Test
    func ayniKisiIkiKumeyeVerilmez() {
        let result = VoiceMatcher.assign(
            clusters: ["S1": [0.97, 0.05, 0, 0], "S2": [0.96, 0.06, 0, 0]],
            people: ["Ayşe": [ayse]])
        #expect(result.isEmpty, "iki küme de Ayşe'ye eşit yakın — tahmin edilmez")
    }

    // MARK: - Etiketleme

    @Test
    func taninanKumeAdiniAlirDigeriNumaralanir() {
        let segments = [
            Segment(channel: .system, speaker: "Katılımcı", text: "a", start: 0, end: 5,
                    confidence: nil, words: []),
            Segment(channel: .system, speaker: "Katılımcı", text: "b", start: 5, end: 10,
                    confidence: nil, words: []),
        ]
        let turns = [SpeakerTurn(start: 0, end: 5, speaker: "S1"),
                     SpeakerTurn(start: 5, end: 10, speaker: "S2")]

        let (result, labels) = SpeakerSeparation.separate(
            turns, to: segments, channel: .system, known: ["S2": "Ayşe"])

        #expect(result.map(\.speaker) == ["Katılımcı 1", "Ayşe"])
        #expect(labels == ["S1": "Katılımcı 1", "S2": "Ayşe"])
    }

    /// Tek küme de tanınmışsa adlandırılır; tanınmamışsa etiketi kanal etiketidir.
    @Test
    func tekKumeTaninirsaAdlandirilir() {
        let segments = [Segment(channel: .system, speaker: "Katılımcı", text: "a",
                                start: 0, end: 10, confidence: nil, words: [])]
        let turns = [SpeakerTurn(start: 0, end: 10, speaker: "S1")]

        let named = SpeakerSeparation.separate(turns, to: segments, channel: .system,
                                               known: ["S1": "Ayşe"])
        #expect(named.segments.map(\.speaker) == ["Ayşe"])

        let unknown = SpeakerSeparation.separate(turns, to: segments, channel: .system)
        #expect(unknown.segments == segments)
        #expect(unknown.labels == ["S1": "Katılımcı"])
    }

    // MARK: - Öğrenme

    private func seed(_ store: MeetingStore) async throws -> Int64 {
        let id = try await store.createMeeting()
        try await store.replaceTranscript(id, segments: [
            Segment(channel: .system, speaker: "Katılımcı 1", text: "a", start: 0, end: 5,
                    confidence: nil, words: []),
            Segment(channel: .system, speaker: "Katılımcı 2", text: "b", start: 5, end: 10,
                    confidence: nil, words: []),
        ])
        try await store.saveSpeakerEmbeddings(id, channel: .system,
                                              embeddings: ["Katılımcı 1": mehmet,
                                                           "Katılımcı 2": ayse])
        try await store.markReady(id)
        return id
    }

    /// Kümeyi adlandırmak sesini öğretir; yanlış adı düzeltmek izi taşır.
    @Test
    func adlandirmaOgretirDuzeltmeTasir() async throws {
        let store = MeetingStore(database: try OraDatabase(path: ":memory:"))
        let id = try await seed(store)

        try await store.setSpeaker(meetingID: id, channel: .system, from: "Katılımcı 2",
                                   to: "Ayşe", learnVoice: true)
        #expect(try await store.voiceprints() == ["Ayşe": [ayse]])

        try await store.setSpeaker(meetingID: id, channel: .system, from: "Ayşe",
                                   to: "Zeynep", learnVoice: true)
        #expect(try await store.voiceprints() == ["Zeynep": [ayse]],
                "yanlış ada öğretilen iz geri alındı")
    }

    /// Ayar kapalıyken ya da etiketin satırı kaldıysa öğrenilmez.
    @Test
    func kapaliykenYaDaYarimAtamadaOgrenilmez() async throws {
        let store = MeetingStore(database: try OraDatabase(path: ":memory:"))
        let id = try await seed(store)

        try await store.setSpeaker(meetingID: id, channel: .system, from: "Katılımcı 1",
                                   to: "Mehmet", learnVoice: false)
        #expect(try await store.voiceprints().isEmpty)

        // "Katılımcı 2"nin tek satırı var ama başka bir kümeden bir satır
        // seçilip adlandırılırsa etiket kalkmaz: yarım atama.
        let rows = try #require(try await store.load(id)).segments
        try await store.setSpeaker(meetingID: id, segments: [rows[0]], speaker: "Ayşe",
                                   learnVoice: true)
        #expect(try await store.voiceprints()["Ayşe"] == nil,
                "Mehmet'in satırı Ayşe'ye verildi ama kümesi bilinmiyor")
    }

    /// Kişi başına örnek sınırı ve toplu silme.
    @Test
    func ornekSiniriVeSilme() async throws {
        let db = try OraDatabase(path: ":memory:")
        let store = MeetingStore(database: db)
        for index in 0 ..< 14 {
            try await store.addVoiceprint(person: "Ayşe", meetingID: nil,
                                          embedding: [Float(index), 1, 0, 0])
        }
        #expect(try await store.voiceprintCount(person: "Ayşe")
                    == MeetingStore.voiceprintsPerPerson)
        #expect(try await store.voiceprints()["Ayşe"]?.last?.first == 13, "en yenisi kaldı")

        try await store.deleteAllVoiceprints()
        #expect(try await store.voiceprintPeopleCount() == 0)
    }

    /// Toplantı silinince kümeleri gider, öğrenilen ses izi kalır.
    @Test
    func toplantiSilinceIzKalir() async throws {
        let db = try OraDatabase(path: ":memory:")
        let store = MeetingStore(database: db)
        let id = try await seed(store)
        try await store.setSpeaker(meetingID: id, channel: .system, from: "Katılımcı 2",
                                   to: "Ayşe", learnVoice: true)

        try await store.delete(id)

        let clusters = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embeddings") ?? 0
        }
        #expect(clusters == 0)
        #expect(try await store.voiceprints()["Ayşe"] == [ayse])
    }

    // MARK: - Hat

    private func runFullPass(diarizer: FakeDiarizer,
                             prepare: (Harness) async throws -> Void) async throws
        -> (Harness, Int64) {
        let audio = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ora-test-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: audio.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: audio) }

        let produced = [
            Segment(channel: .mic, speaker: "Ben", text: "merhaba", start: 0, end: 30,
                    confidence: 0.9, words: []),
            Segment(channel: .system, speaker: "Katılımcı", text: "bütçe onaylandı",
                    start: 30, end: 35, confidence: 0.9, words: []),
            Segment(channel: .system, speaker: "Katılımcı", text: "rapor cuma",
                    start: 35, end: 42, confidence: 0.9, words: []),
        ]
        let h = try Harness(intelligence: SlowIntelligence(tag: "V", step: .milliseconds(5)),
                            transcription: FakeTranscription(segments: produced),
                            diarizer: diarizer)
        try await prepare(h)
        let id = try await h.store.createMeeting()
        try await h.store.markProcessing(id, audioPath: audio, duration: 42)
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("yeniden deneme mümkün") { h.controller.canRetry }
        await h.controller.retryProcessing()
        return (h, id)
    }

    private var twoRemoteVoices: FakeDiarizer {
        FakeDiarizer(perChannel: [
            .system: Diarization(turns: [SpeakerTurn(start: 30, end: 35, speaker: "S1"),
                                         SpeakerTurn(start: 35, end: 42, speaker: "S2")],
                                 embeddings: ["S1": [0, 0, 1, 0], "S2": [0.95, 0.1, 0.05, 0]]),
            .mic: Diarization(turns: [SpeakerTurn(start: 0, end: 30, speaker: "S1")],
                              embeddings: ["S1": [0, 0, 0, 1]]),
        ])
    }

    /// Bilinen ses sonraki toplantıda adıyla gelir, katılımcı olarak yazılır;
    /// uzak toplantıda kendi sesin öğrenilir.
    @Test
    func bilinenSesSonrakiToplantidaTaninir() async throws {
        let (h, id) = try await runFullPass(diarizer: twoRemoteVoices) { h in
            try await h.store.addVoiceprint(person: "Ayşe", meetingID: nil, embedding: ayse)
        }
        let row = try #require(try await h.store.load(id))
        #expect(row.segments.map(\.speaker) == ["Ben", "Katılımcı 1", "Ayşe"])
        #expect(try await h.store.transcriptParticipants(id).contains("Ayşe"))
        #expect(try await h.store.voiceprintCount(person: VoicePrint.me) == 1,
                "30 sn'lik mikrofon konuşmasından kendi sesin öğrenildi")
    }

    /// Ayar kapalıyken tanıma da öğrenme de yapılmaz.
    @Test
    func ayarKapaliysaTanimaYok() async throws {
        let (h, id) = try await runFullPass(diarizer: twoRemoteVoices) { h in
            h.settings.voiceMemoryEnabled = false
            try await h.store.addVoiceprint(person: "Ayşe", meetingID: nil, embedding: ayse)
        }
        let row = try #require(try await h.store.load(id))
        #expect(row.segments.map(\.speaker) == ["Ben", "Katılımcı 1", "Katılımcı 2"])
        #expect(try await h.store.voiceprintCount(person: VoicePrint.me) == 0)
    }
}
