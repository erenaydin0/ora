import Foundation
import Testing
@testable import ora

/// Etiketler (COMPETITION.md §4.16).
@Suite("Etiketler", .serialized)
struct TagTests {

    @Test
    func etiketAdiKanonikBicimeGetirilir() {
        #expect(MeetingStore.tagName("  #müşteri   ziyareti ") == "müşteri ziyareti")
        #expect(MeetingStore.tagName("###") == nil)
        #expect(MeetingStore.tagName("   ") == nil)
    }

    /// "İş" ve "iş" aynı etikettir — SQLite'ın NOCASE'i `İ`'yi katlamaz.
    @Test
    func turkceBuyukKucukHarfAyniEtiketiGosterir() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let a = try await h.store.createMeeting()
        let b = try await h.store.createMeeting()
        try await h.store.setTag(a, "İş", on: true)
        try await h.store.setTag(b, "iş", on: true)

        let tags = try await h.store.allTags()
        #expect(tags == [MeetingStore.TagCount(name: "İş", count: 2)], "ilk yazılan biçim korunur")
    }

    @Test
    func listeEtiketeGoreSuzulurVeEtiketleriTasir() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let a = try await h.store.createMeeting()
        let b = try await h.store.createMeeting()
        try await h.store.setTag(a, "müşteri", on: true)
        try await h.store.setTag(a, "Acme", on: true)
        try await h.store.setTag(b, "iç", on: true)

        let filtered = try await h.store.list(tag: "müşteri")
        #expect(filtered.map(\.id) == [a])
        #expect(filtered.first?.tags == ["Acme", "müşteri"])
        #expect(try await h.store.list().count == 2)
        #expect(try await h.store.list(search: "yok", tag: "müşteri").isEmpty)
    }

    /// Hiçbir toplantıda kalmayan etiket silinir — kaldırınca da, toplantı
    /// silinince de.
    @Test
    func kullanilmayanEtiketSilinir() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let a = try await h.store.createMeeting()
        let b = try await h.store.createMeeting()
        try await h.store.setTag(a, "geçici", on: true)
        try await h.store.setTag(b, "kalıcı", on: true)

        try await h.store.setTag(a, "geçici", on: false)
        #expect(try await h.store.allTags().map(\.name) == ["kalıcı"])

        try await h.store.delete(b)
        #expect(try await h.store.allTags().isEmpty)
    }

    @Test
    func etiketSilinceToplantilarKalir() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let a = try await h.store.createMeeting()
        try await h.store.setTag(a, "proje", on: true)
        try await h.store.deleteTag("proje")
        #expect(try await h.store.allTags().isEmpty)
        #expect(try await h.store.list().first?.tags == [])
    }

    /// Süzülen etiket son toplantısından da kaldırılırsa süzgeç boşa düşmez.
    @Test
    func suzulenEtiketKalkincaSuzgecSifirlanir() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A"))
        let a = try await h.store.createMeeting()
        try await h.store.createMeeting()
        await h.controller.setTag(a, "müşteri", on: true)
        h.controller.tagFilter = "müşteri"
        await h.controller.refresh()
        #expect(h.controller.meetings.map(\.id) == [a])

        await h.controller.setTag(a, "müşteri", on: false)
        #expect(h.controller.tagFilter == nil)
        #expect(h.controller.meetings.count == 2)
    }
}
