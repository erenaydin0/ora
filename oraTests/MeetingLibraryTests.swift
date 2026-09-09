import Foundation
import Testing
@testable import ora

/// Kütüphane (REFACTOR.md Adım 5): liste, arama, seçim ve seçili toplantının
/// ekrandaki içeriği. Ayrılmasının kazancı, iki yarışın tek yerde kapanması —
/// bu takım ikisini de ölçer.
@Suite("Toplantı kütüphanesi", .serialized)
struct MeetingLibraryTests {

    @MainActor
    private func make(isRecording: @escaping () -> Bool = { false })
    -> (OraDatabase, MeetingStore, MeetingLibrary) {
        let db = try! OraDatabase(path: ":memory:")
        let store = MeetingStore(database: db)
        return (db, store, MeetingLibrary(store: store, isRecording: isRecording))
    }

    @MainActor
    private func seed(_ store: MeetingStore, text: String) async throws -> Int64 {
        let id = try await store.createMeeting()
        try await store.replaceTranscript(id, segments: [
            Segment(channel: .mic, speaker: "Ben", text: text,
                    start: 0, end: 10, confidence: 0.9, words: [])
        ])
        try await store.markReady(id)
        return id
    }

    /// Seçim değişince içerik yüklenir.
    @Test @MainActor
    func secimIcerigiYukler() async throws {
        let (_, store, library) = make()
        let id = try await seed(store, text: "toplantı metni")
        await library.refresh()

        library.selection = id

        await waitUntil("içerik yüklendi") { library.transcript.count == 1 }
        #expect(library.transcript.first?.text == "toplantı metni")
        #expect(library.selectedMeeting?.id == id)
    }

    /// **Hattın ürettiği içerik yalnızca seçili toplantıya yazılır.**
    /// Bu, RESEARCH.md §27'nin kütüphane tarafındaki karşılığı.
    @Test @MainActor
    func hattinIcerigiYalnizcaSeciliToplantiyaYazilir() async throws {
        let (_, store, library) = make()
        let a = try await seed(store, text: "A metni")
        let b = try await seed(store, text: "B metni")
        await library.refresh()
        library.selection = b
        await waitUntil("B yüklendi") { library.transcript.first?.text == "B metni" }

        // A için üretilmiş içerik B'nin ekranına düşmemeli.
        library.display(PipelineEvent(meetingID: a, kind: .summary(
            Ozet(genelBakis: ["A özeti"], kararlar: [], aksiyonlar: []), [])))
        library.display(PipelineEvent(meetingID: a, kind: .notice("A notu")))
        library.display(PipelineEvent(meetingID: a, kind: .deferred(.lowPowerMode)))

        #expect(library.summary == nil, "A'nın özeti B'nin ekranında yok")
        #expect(library.summaryNotice == nil)
        #expect(library.deferReason == nil)

        // B için üretilmiş içerik yazılır.
        library.display(PipelineEvent(meetingID: b, kind: .summary(
            Ozet(genelBakis: ["B özeti"], kararlar: [], aksiyonlar: []), [])))
        #expect(library.summary?.genelBakis.first == "B özeti")
    }

    /// **Geç gelen yükleme yeni seçimin üstüne yazmaz.** Hızlı git-gel'de iki
    /// yükleme yarışıyordu.
    ///
    /// Yarış gerçek zamanlamayla kurulamıyor (iki bellek içi okuma da hızlı
    /// bitiyor ve sıra deterministik değil); bu yüzden yükleme sonucunu ekrana
    /// yazan adım doğrudan çağrılır.
    @Test @MainActor
    func gecGelenYuklemeYeniSecimiEzmez() async throws {
        let (_, store, library) = make()
        let a = try await seed(store, text: "A metni")
        let b = try await seed(store, text: "B metni")
        await library.refresh()
        library.selection = b
        await waitUntil("B yüklendi") { library.transcript.first?.text == "B metni" }

        // A'nın yüklemesi geç geldi: kullanıcı çoktan B'ye geçmişti.
        let late = try #require(try await store.load(a))
        library.apply(late, chat: [], participants: [], for: a)

        #expect(library.transcript.first?.text == "B metni",
                "geç gelen A sonucu B'nin ekranını ezmedi")
    }

    /// Aynı turda iki kez seçim değişirse ekranda **son** seçim kalır.
    @Test @MainActor
    func hizliGitGeldeSonSecimKalir() async throws {
        let (_, store, library) = make()
        let a = try await seed(store, text: "A metni")
        let b = try await seed(store, text: "B metni")
        await library.refresh()

        library.selection = a
        library.selection = b

        await waitUntil("B yüklendi") { library.transcript.first?.text == "B metni" }
        await settle(.milliseconds(200))
        #expect(library.transcript.first?.text == "B metni")
        #expect(library.selection == b)
    }

    /// Kayıt sürerken seçim değişse bile yükleme yapılmaz — ekranda canlı
    /// transkript akıyor.
    @Test @MainActor
    func kayitSurerkenYuklemeYapilmaz() async throws {
        let (_, store, library) = make(isRecording: { true })
        let id = try await seed(store, text: "toplantı metni")
        await library.refresh()

        library.selection = id
        await settle(.milliseconds(200))

        #expect(library.transcript.isEmpty, "kayıt sürerken yükleme yok")
    }

    /// Seçili toplantı silinince ekran temizlenir ve seçim boşalır.
    @Test @MainActor
    func seciliToplantiSilinirseEkranTemizlenir() async throws {
        let (_, store, library) = make()
        let id = try await seed(store, text: "silinecek")
        await library.refresh()
        library.selection = id
        await waitUntil("yüklendi") { !library.transcript.isEmpty }

        await library.delete(id)

        #expect(library.selection == nil)
        #expect(library.transcript.isEmpty)
        #expect(library.meetings.isEmpty)
    }

    /// Düzeltme `corrections`'a yazılır ve sözlük adayı **dışarı** bildirilir —
    /// kütüphane sözlüğe dokunmaz.
    @Test @MainActor
    func duzeltmeSozlukAdayiniBildirir() async throws {
        let (_, store, library) = make()
        let id = try await seed(store, text: "Toplum bütçesi")
        await library.refresh()
        library.selection = id
        await waitUntil("yüklendi") { !library.transcript.isEmpty }

        var reported: [(String, String)] = []
        library.onCorrection = { reported.append(($0, $1)) }
        let segment = library.transcript[0]
        await library.correct(segment, to: "Toplam bütçesi")

        #expect(reported.count == 1)
        #expect(reported.first?.1 == "Toplam bütçesi")
        await waitUntil("düzeltilmiş metin ekranda") {
            library.transcript.first?.text == "Toplam bütçesi"
        }
    }

    /// Aksiyon işaretlemesi hem toplantı görünümünü hem panoyu **hemen**
    /// güncellemeli; yazma arkada yapılır.
    @Test @MainActor
    func aksiyonIsaretlemesiHemenGorunur() async throws {
        let (_, store, library) = make()
        let id = try await seed(store, text: "metin")
        try await store.saveSummary(id, ozet: Ozet(
            genelBakis: [], kararlar: [],
            aksiyonlar: [Ozet.Aksiyon(kisi: "Ben", gorev: "rapor yaz",
                                      baglam: "toplantıda çıktı",
                                      sonTarih: "belirtilmedi")]), topics: [])
        await library.refresh()
        library.selection = id
        await waitUntil("aksiyon yüklendi") { library.actions.count == 1 }
        let actionID = library.actions[0].id

        library.setActionDone(actionID, true)

        #expect(library.actions[0].isDone, "toplantı görünümü hemen güncellendi")
        #expect(library.boardActions.first(where: { $0.id == actionID })?.isDone == true,
                "pano da hemen güncellendi")
        await settle(.milliseconds(300))
        let written = try await store.load(id)
        #expect(written?.actions.first?.isDone == true, "yazma arkada tamamlandı")
    }

    /// Arama listeyi süzer (debounce'lu).
    @Test @MainActor
    func aramaListeyiSuzer() async throws {
        let (_, store, library) = make()
        let a = try await seed(store, text: "bordro görüşmesi")
        _ = try await seed(store, text: "tamamen başka bir konu")
        try await store.updateTitle(a, title: "Bordro")
        await library.refresh()
        #expect(library.meetings.count == 2)

        library.searchText = "bordro"

        await waitUntil("arama süzdü") { library.meetings.count == 1 }
        #expect(library.meetings.first?.id == a)
    }
}
