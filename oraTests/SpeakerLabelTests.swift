import Foundation
import Testing
@testable import ora

/// Konuşmacı adlandırma (COMPETITION.md §4.13 seçenek 3): diarization
/// gelmeden önce **elle** atama, gelince de onun düzeltme katmanı.
///
/// Ölçtüğü şey tahmin değil **kapsam ve geri alınabilirlik**: atama doğru
/// satırlara uygulanıyor mu, kanal sızıyor mu, geri alındığında katılımcı
/// listesi de düzeliyor mu.
@Suite("Konuşmacı adlandırma", .serialized)
struct SpeakerLabelTests {

    private func make() -> (OraDatabase, MeetingStore, MeetingLibrary) {
        let db = try! OraDatabase(path: ":memory:")
        let store = MeetingStore(database: db)
        return (db, store, MeetingLibrary(store: store))
    }

    /// İki kanallı, üç satırlı bir toplantı.
    private func seed(_ store: MeetingStore) async throws -> Int64 {
        let id = try await store.createMeeting()
        try await store.replaceTranscript(id, segments: [
            Segment(channel: .mic, speaker: Channel.mic.speaker, text: "ben konuştum",
                    start: 0, end: 4, confidence: 0.9, words: []),
            Segment(channel: .system, speaker: Channel.system.speaker, text: "ilk cevap",
                    start: 4, end: 8, confidence: 0.9, words: []),
            Segment(channel: .system, speaker: Channel.system.speaker, text: "ikinci cevap",
                    start: 8, end: 12, confidence: 0.9, words: [])
        ])
        try await store.markReady(id)
        return id
    }

    private func select(_ library: MeetingLibrary, _ id: Int64) async {
        await library.refresh()
        library.selection = id
        await waitUntil("toplantı yüklendi") { library.transcript.count == 3 }
    }

    /// Tek satır atanınca **yalnızca** o satır değişir.
    @Test
    func tekSatirAtanir() async throws {
        let (_, store, library) = make()
        let id = try await seed(store)
        await select(library, id)

        let target = library.transcript[1]
        await library.setSpeaker(target, to: "Ahmet")

        await waitUntil("etiket yazıldı") {
            library.transcript.first { $0.start == 4 }?.speaker == "Ahmet"
        }
        #expect(library.transcript.first { $0.start == 8 }?.speaker == Channel.system.speaker)
        #expect(library.transcript.first { $0.start == 0 }?.speaker == Channel.mic.speaker)
    }

    /// "Tümü" kapsamı aynı kanalda kalır — mikrofon kanalına dokunmaz.
    @Test
    func ayniEtiketliTumSatirlarAtanirKanalSizmaz() async throws {
        let (_, store, library) = make()
        let id = try await seed(store)
        await select(library, id)

        await library.setSpeaker(allLabeled: Channel.system.speaker, in: .system, to: "Ahmet")

        await waitUntil("iki satır da Ahmet") {
            library.transcript.filter { $0.speaker == "Ahmet" }.count == 2
        }
        #expect(library.transcript.first { $0.channel == .mic }?.speaker
                    == Channel.mic.speaker,
                "mikrofon kanalı etkilenmedi")
        #expect(library.speakingParticipants == ["Ahmet"])
    }

    /// Ad `meeting_participants(source = 'transcript')` olarak yazılır ve
    /// takvimden gelen satırlara dokunulmaz.
    @Test
    func adKatilimciOlarakYazilirTakvimKorunur() async throws {
        let (_, store, library) = make()
        let id = try await seed(store)
        let event = MeetingEvent(eventID: "E1", title: "Bordro",
                                 start: .now, end: .now.addingTimeInterval(1800),
                                 organizer: "Merve Sarı", attendees: ["Merve Sarı"],
                                 meetingApp: nil, isCancelled: false,
                                 myStatus: .accepted, organizerIsMe: false)
        try await store.linkCalendarEvent(id, event: event)
        await select(library, id)

        await library.setSpeaker(allLabeled: Channel.system.speaker, in: .system, to: "Ahmet")
        await waitUntil("atama yazıldı") { library.speakingParticipants == ["Ahmet"] }

        #expect(try await store.transcriptParticipants(id) == ["Ahmet"])
        #expect(try await store.calendarParticipants(id) == ["Merve Sarı"],
                "takvim katılımcısı silinmedi")
    }

    /// **Geri alınabilirlik:** kanal etiketine dönülünce katılımcı satırı düşer.
    /// Yanlış atamanın kayıtta kalıcı olmaması bu özelliğin tamamının gerekçesi.
    @Test
    func atamaGeriAlinirsaKatilimciDuser() async throws {
        let (_, store, library) = make()
        let id = try await seed(store)
        await select(library, id)

        await library.setSpeaker(allLabeled: Channel.system.speaker, in: .system, to: "Ahmet")
        await waitUntil("yazıldı") { library.speakingParticipants == ["Ahmet"] }
        #expect(try await store.transcriptParticipants(id) == ["Ahmet"])

        await library.setSpeaker(allLabeled: "Ahmet", in: .system, to: Channel.system.speaker)
        await waitUntil("geri alındı") { library.speakingParticipants.isEmpty }
        #expect(try await store.transcriptParticipants(id).isEmpty)
    }

    /// Kanal etiketi kişi değildir: katılımcı yazılmaz, sözlüğe beslenmez.
    @Test
    func kanalEtiketiKisiSayilmaz() async throws {
        let (_, store, library) = make()
        let id = try await seed(store)
        await select(library, id)

        var named: [String] = []
        library.onSpeakerNamed = { named.append($0) }

        await library.setSpeaker(library.transcript[1], to: Channel.mic.speaker)
        await waitUntil("etiket değişti") {
            library.transcript.first { $0.start == 4 }?.speaker == Channel.mic.speaker
        }

        #expect(named.isEmpty, "kanal etiketi sözlüğe gitmedi")
        #expect(try await store.transcriptParticipants(id).isEmpty)
        #expect(MeetingStore.isChannelLabel("katılımcı"), "karşılaştırma harf duyarsız")
        #expect(!MeetingStore.isChannelLabel("Ahmet"))
    }

    /// Özel isim sözlüğe verilir — tanımanın en zayıf noktası budur.
    @Test
    func ozelIsimSozlugeVerilir() async throws {
        let (_, store, library) = make()
        let id = try await seed(store)
        await select(library, id)

        var named: [String] = []
        library.onSpeakerNamed = { named.append($0) }

        await library.setSpeaker(library.transcript[1], to: "Ayşe Demir")
        await waitUntil("ad iletildi") { named == ["Ayşe Demir"] }
    }

    /// Menü adayları: kanal etiketleri + takvim + bu toplantıda kullanılanlar.
    /// Aynı ad iki kez listelenmez.
    @Test
    func adaylarTekilVeSiraliDir() async throws {
        let (_, store, library) = make()
        let id = try await seed(store)
        let event = MeetingEvent(eventID: "E2", title: "Bordro",
                                 start: .now, end: .now.addingTimeInterval(1800),
                                 organizer: nil, attendees: ["Merve Sarı"],
                                 meetingApp: nil, isCancelled: false,
                                 myStatus: .accepted, organizerIsMe: false)
        try await store.linkCalendarEvent(id, event: event)
        await select(library, id)

        await library.setSpeaker(library.transcript[1], to: "Merve Sarı")
        await waitUntil("atandı") { library.speakingParticipants == ["Merve Sarı"] }

        let candidates = library.speakerCandidates
        #expect(candidates.prefix(2) == [Channel.mic.speaker, Channel.system.speaker])
        #expect(candidates.filter { $0 == "Merve Sarı" }.count == 1, "aday tekil")
        #expect(library.lineCount(label: Channel.system.speaker, in: .system) == 1)
    }
}
