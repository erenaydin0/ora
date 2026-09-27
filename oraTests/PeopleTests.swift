import Foundation
import Testing
@testable import ora

/// Kişi sayfası ve toplantı brifingi (COMPETITION.md §4.11).
@Suite("Kişiler", .serialized)
struct PeopleTests {

    private func event(_ title: String, _ attendees: [String]) -> MeetingEvent {
        MeetingEvent(eventID: title, title: title, start: Date(), end: Date(),
                     organizer: nil, attendees: attendees, meetingApp: nil,
                     isCancelled: false, myStatus: .accepted, organizerIsMe: false)
    }

    /// Toplantıyı verilen tarihte açar, katılımcıları bağlar ve özetini yazar.
    private func meeting(_ h: Harness, _ title: String, daysAgo: Double,
                         attendees: [String], decisions: [String] = [],
                         actions: [Ozet.Aksiyon] = []) async throws -> Int64 {
        let id = try await h.store.createMeeting(date: Date().addingTimeInterval(-daysAgo * 86_400))
        try await h.store.linkCalendarEvent(id, event: event(title, attendees))
        try await h.store.saveSummary(id, ozet: Ozet(genelBakis: ["g"], kararlar: decisions,
                                                     aksiyonlar: actions), topics: [])
        return id
    }

    private func action(_ kisi: String, _ gorev: String) -> Ozet.Aksiyon {
        Ozet.Aksiyon(kisi: kisi, gorev: gorev, baglam: "", sonTarih: "belirtilmedi")
    }

    @Test
    func aksiyonSahibiTamAdYaDaIlkAdla() {
        #expect(MeetingStore.owns("Merve Sarı", "merve sarı"))
        #expect(MeetingStore.owns("Merve Sarı", "Merve"))
        #expect(!MeetingStore.owns("Merve Sarı", "Merve Kaya"))
        #expect(!MeetingStore.owns("Merve Sarı", "belirtilmedi"))
        #expect(MeetingStore.owns("İlknur", "ilknur"), "Türkçe küçük harf")
    }

    @Test
    func kisiSayfasiToplantilariAksiyonlariVeSonKararlariToplar() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let old = try await meeting(h, "Eski", daysAgo: 10, attendees: ["Merve Sarı"],
                                    decisions: ["Bütçe onaylandı."],
                                    actions: [action("Merve", "Raporu gönder")])
        let recent = try await meeting(h, "Yeni", daysAgo: 1,
                                       attendees: ["Merve Sarı", "Can Demir"],
                                       actions: [action("Merve Sarı", "Teklifi hazırla"),
                                                 action("Can Demir", "Demo ayarla")])
        _ = try await meeting(h, "Başka", daysAgo: 2, attendees: ["Can Demir"])

        let people = try await h.store.people()
        #expect(people.map(\.name) == ["Can Demir", "Merve Sarı"],
                "son görüşmeye göre (ikisi de dün; eşitlikte ada göre)")
        #expect(people.first { $0.name == "Merve Sarı" }?.meetingCount == 2)

        let detail = try await h.store.person("Merve Sarı")
        #expect(detail.meetings.map(\.id) == [recent, old], "en yeni önce")
        #expect(Set(detail.openActions.map(\.task)) == ["Raporu gönder", "Teklifi hazırla"])
        #expect(detail.lastDecisions?.meeting.id == old, "kararı olan son toplantı")
        #expect(detail.lastDecisions?.items == ["Bütçe onaylandı."])
    }

    /// Brifing: yaklaşan toplantının katılımcılarıyla **en çok ortak kişisi
    /// olan** geçmiş toplantı. Kullanıcının kendi adı sayılmaz.
    @Test
    func brifingEnCokOrtakKisiliSonToplantiyiBulur() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let both = try await meeting(h, "İkisi", daysAgo: 7, attendees: ["Eren", "Ayşe", "Can"],
                                     decisions: ["K1", "K2"],
                                     actions: [action("Ayşe", "A"), action("Can", "B")])
        _ = try await meeting(h, "Yalnız Ayşe", daysAgo: 1, attendees: ["Eren", "Ayşe"])

        let brief = try #require(try await h.store.brief(attendees: ["Eren", "Ayşe", "Can"],
                                                         excluding: "Eren"))
        #expect(brief.meetingID == both)
        #expect(brief.openActions == 2)
        #expect(brief.decisions == 2)
        #expect(brief.line.hasPrefix("Son ortak toplantı "))
        #expect(brief.line.hasSuffix(" — 2 açık aksiyon, 2 karar"))

        #expect(try await h.store.brief(attendees: ["Eren"], excluding: "Eren") == nil,
                "yalnızca kullanıcının kendisi ortaksa brifing yok")
        #expect(try await h.store.brief(attendees: ["Zeynep"]) == nil)
    }

    @Test
    func kisilerSayfasiPanoVeSecimleBirbiriniDislar() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let id = try await h.seed(text: "metin")
        await h.controller.refresh()
        h.controller.showsPeople = true
        #expect(h.controller.selection == nil)
        h.controller.showsActionBoard = true
        #expect(!h.controller.showsPeople)
        h.controller.showsPeople = true
        #expect(!h.controller.showsActionBoard)
        h.controller.openMeeting(id)
        #expect(!h.controller.showsPeople && h.controller.selection == id)
    }
}
