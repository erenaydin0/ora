import Foundation
import Testing
@testable import ora

/// Takvim eşleştirmesi (RESEARCH.md §29, REFACTOR.md Adım 6).
///
/// İki katman ölçülür: **puanlama** (hangi aday öne çıkıyor) ve **karar**
/// (öne çıkması sormadan bağlanmaya yetiyor mu). İkincisinin hiç testi yoktu;
/// politika arayüz katmanında duruyordu.
///
/// Etkinlikler sentetik — `eventSource` enjekte edildiği için EventKit'e
/// dokunulmuyor ve çakışma senaryosu kurulabiliyor.
/// `probes/takvim_eslestirme.swift`'ten taşındı.
@Suite("Takvim eşleştirmesi", .serialized)
struct CalendarMatchTests {

    private static let now = Date()

    private static func event(_ title: String, start: Date = now, minutes: Int = 30,
                              app: String? = nil, cancelled: Bool = false,
                              response: MeetingEvent.Response = .pending,
                              organizerIsMe: Bool = false,
                              attendees: [String] = []) -> MeetingEvent {
        MeetingEvent(eventID: title, title: title, start: start,
                     end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                     organizer: nil, attendees: attendees, meetingApp: app,
                     isCancelled: cancelled, myStatus: response,
                     organizerIsMe: organizerIsMe)
    }

    private static func reader(_ events: [MeetingEvent],
                               titles: [String] = []) -> CalendarReader {
        let suite = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = OraSettings(defaults: defaults)
        settings.calendarEnabled = true
        return CalendarReader(settings: settings,
                              windowTitles: { _ in titles },
                              eventSource: { _, _ in events })
    }

    private static func score(_ event: MeetingEvent, app: String? = nil,
                              titles: [String] = []) -> Int {
        CalendarReader.score(event, at: now, app: app, windowTitles: titles).score
    }

    // MARK: - Pencere başlığı eşleştirme

    @Test func pencereBasligiEslestirme() {
        #expect(CalendarReader.titleMatches("Bordro Fark Çözümü | Microsoft Teams",
                                            "Bordro Fark Çözümü"),
                "birebir ad, uygulama eki atılıyor")
        #expect(CalendarReader.titleMatches("Q3 Bütçe Planlama | Microsoft Teams",
                                            "Q3 Bütçe Planlama Toplantısı"),
                "etkinlik adı daha uzun")
        #expect(!CalendarReader.titleMatches("Q3 Bütçe Planlama | Microsoft Teams",
                                             "İşe Alım Görüşmesi"),
                "alakasız toplantı eşleşmiyor")
        #expect(!CalendarReader.titleMatches("Calendar | Microsoft Teams",
                                             "Bordro Fark Çözümü"),
                "genel görünüm adı eşleşmiyor")
        #expect(!CalendarReader.titleMatches("Toplantı | Microsoft Teams",
                                             "Haftalık Toplantı"),
                "yalnızca gürültü kelimesi yetmiyor")
    }

    // MARK: - Puanlama

    /// Mikrofonu hangi uygulama tutuyorsa onun daveti kazanır — Teams davetini
    /// Zoom davetinden ayıran tek sinyal bu.
    @Test func mikrofonuTutanUygulamaKazanir() {
        let teams = Self.event("Bordro Fark Çözümü", app: "com.microsoft.teams2")
        let zoom = Self.event("Tedarikçi Görüşmesi", app: "us.zoom.xos")
        #expect(Self.score(teams, app: "com.microsoft.teams2")
                > Self.score(zoom, app: "com.microsoft.teams2"))
        #expect(Self.score(zoom, app: "us.zoom.xos")
                > Self.score(teams, app: "us.zoom.xos"))
    }

    /// **Reddettiğim toplantı elenmez, puan kaybeder** — insan reddettiği
    /// toplantıya katılabiliyor.
    @Test func reddedilenElenmezPuanKaybeder() {
        let accepted = Self.event("Bordro", app: "com.microsoft.teams2", response: .accepted)
        let declined = Self.event("Tasarım", app: "com.microsoft.teams2", response: .declined)
        #expect(Self.score(declined, app: "com.microsoft.teams2") < Self.score(accepted, app: "com.microsoft.teams2"))
        #expect(Self.score(accepted, app: "com.microsoft.teams2")
                - Self.score(declined, app: "com.microsoft.teams2") >= CalendarReader.decisiveMargin,
                "kabul ettiğim, reddettiğimi açık ara geçiyor")
    }

    @Test func yeniBaslayanOnde() {
        let now = Self.event("Şimdiki", app: "com.microsoft.teams2", response: .accepted)
        let old = Self.event("Sabahki", start: Self.now.addingTimeInterval(-40 * 60))
        #expect(Self.score(now, app: "com.microsoft.teams2") > Self.score(old))
    }

    // MARK: - Karar: kesin mi, sorulacak mı?

    /// Tek aday varsa sormaya gerek yok.
    @Test func tekAdayKesin() {
        let event = Self.event("Bordro Fark Çözümü", app: "com.microsoft.teams2")
        let reader = Self.reader([event])
        #expect(reader.match(at: Self.now, app: "com.microsoft.teams2")
                == .decisive(event))
    }

    /// **İki Teams toplantısını da kabul ettiysem fark yok → sorulur.**
    /// Tahmin etmek yanlış katılımcı listesi yazmak demek.
    @Test func belirsizlikteSorulur() {
        let a = Self.event("Bordro Fark Çözümü", app: "com.microsoft.teams2",
                           response: .accepted)
        let b = Self.event("Tasarım Değerlendirme", app: "com.microsoft.teams2",
                           response: .accepted)
        let reader = Self.reader([a, b])

        let outcome = reader.match(at: Self.now, app: "com.microsoft.teams2")
        guard case .ambiguous(let choices) = outcome else {
            Issue.record("belirsiz beklenirken \(outcome) geldi")
            return
        }
        #expect(choices.count == 2, "iki aday da kullanıcıya sunuluyor")
    }

    /// Pencere başlığı gelince belirsizlik kalkıyor — takvimin en güçlü sinyali.
    @Test func pencereBasligiBelirsizligiCozer() {
        let a = Self.event("Bordro Fark Çözümü", app: "com.microsoft.teams2",
                           response: .accepted)
        let b = Self.event("Tasarım Değerlendirme", app: "com.microsoft.teams2",
                           response: .accepted)
        let reader = Self.reader([a, b], titles: ["Bordro Fark Çözümü | Microsoft Teams"])

        #expect(reader.match(at: Self.now, app: "com.microsoft.teams2") == .decisive(a))
    }

    /// İptal edilmiş etkinlik aday değildir: takvimde durmaya devam ediyor ve
    /// erken başladığı için gerçek toplantıyı yeniyordu.
    @Test func iptalEdilenAdayDegil() {
        let cancelled = Self.event("İptal Edilmiş", app: "com.microsoft.teams2",
                                   cancelled: true)
        let reader = Self.reader([cancelled])
        #expect(reader.match(at: Self.now, app: "com.microsoft.teams2") == CalendarReader.MatchOutcome.none)
    }

    /// O ana denk gelen etkinlik yoksa eşleşme yok.
    @Test func etkinlikYoksaEslesmeYok() {
        let reader = Self.reader([])
        #expect(reader.match(at: Self.now, app: nil) == CalendarReader.MatchOutcome.none)
    }

    /// Bildirim metni için tepe aday **eşiğe bakmadan** verilir: orada en iyi
    /// tahmin yeterli, veritabanına kimse yazılmıyor.
    @Test func bildirimIcinTepeAdayEsigeBakmaz() {
        let a = Self.event("Bordro Fark Çözümü", app: "com.microsoft.teams2",
                           response: .accepted)
        let b = Self.event("Tasarım Değerlendirme", app: "com.microsoft.teams2",
                           response: .accepted)
        let reader = Self.reader([a, b])

        // Karar belirsiz…
        #expect({ if case .ambiguous = reader.match(at: Self.now, app: "com.microsoft.teams2") {
            true } else { false } }())
        // …ama bildirim yine de bir ad gösterebiliyor.
        #expect(reader.bestGuess(at: Self.now, app: "com.microsoft.teams2") != nil)
    }
}
