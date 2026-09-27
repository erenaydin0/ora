import Foundation
import GRDB
import Testing
@testable import ora

/// Sözlük girdisini yerinde düzeltme. Ölçtüğü şey: yinelenme koruması,
/// gizli bir red satırıyla çakışma ve düzeltilen kelimenin sahipliği.
@Suite("Sözlük düzenleme")
struct VocabularyTests {

    private func make() throws -> (OraDatabase, VocabularyStore) {
        let db = try OraDatabase(path: ":memory:")
        return (db, VocabularyStore(database: db))
    }

    private func id(of word: String, in store: VocabularyStore) async throws -> Int64 {
        try #require(try await store.all().first { $0.word == word }).id
    }

    /// Yazım düzelir, kaynak `manual` olur, durum korunur.
    @Test
    func kelimeYerindeDuzelirKaynakElleOlur() async throws {
        let (_, store) = try make()
        try await store.add("Ayse", source: "calendar", status: "active")
        let wordID = try await id(of: "Ayse", in: store)

        #expect(try await store.rename(wordID, to: "  Ayşe ") == .renamed)

        let words = try await store.all()
        #expect(words.map(\.word) == ["Ayşe"])
        #expect(words.first?.source == "manual")
        #expect(words.first?.status == "active")
        #expect(try await store.activeWords() == ["Ayşe"])
    }

    /// Görünen başka bir satırla çakışma reddedilir, iki satır da olduğu gibi kalır.
    @Test
    func yinelenenKelimeReddedilir() async throws {
        let (_, store) = try make()
        try await store.add("Bordro")
        try await store.add("Bordo")
        let wordID = try await id(of: "Bordo", in: store)

        #expect(try await store.rename(wordID, to: "Bordro") == .duplicate)
        #expect(Set(try await store.all().map(\.word)) == ["Bordro", "Bordo"])
    }

    /// Onay bekleyen bir aday düzeltilince onayı kendiliğinden verilmez.
    @Test
    func bekleyenAdayDuzelinceBeklemedeKalir() async throws {
        let (_, store) = try make()
        try await store.add("Kubernets", source: "correction", status: "pending")
        let wordID = try await id(of: "Kubernets", in: store)

        #expect(try await store.rename(wordID, to: "Kubernetes") == .renamed)
        #expect(try await store.all().first?.isPending == true)
        #expect(try await store.activeWords().isEmpty)
    }

    /// Listede görünmeyen bir red satırıyla çakışma yinelenme sayılmaz:
    /// kullanıcı kelimeyi şimdi açıkça istiyor, eski red kaldırılır.
    @Test
    func gizliRedSatiriylaCakismaKullaniciLehineCozulur() async throws {
        let (db, store) = try make()
        try await store.add("Işsizlik", source: "correction", status: "pending")
        try await store.reject(try await id(of: "Işsizlik", in: store))
        try await store.add("Issizlik")
        let wordID = try await id(of: "Issizlik", in: store)

        #expect(try await store.rename(wordID, to: "Işsizlik") == .renamed)
        let rows = try await db.read { db in
            try String.fetchAll(db, sql: "SELECT word FROM vocabulary")
        }
        #expect(rows == ["Işsizlik"], "tek satır kaldı")
        #expect(try await store.activeWords() == ["Işsizlik"])
    }

    /// Boş kelime ve silinmiş satır kullanıcıya söylenecek durumlardır.
    @Test
    func bosVeKayipSatir() async throws {
        let (_, store) = try make()
        try await store.add("Toplam")
        let wordID = try await id(of: "Toplam", in: store)

        #expect(try await store.rename(wordID, to: "   ") == .empty)
        #expect(try await store.rename(9_999, to: "Yeni") == .missing)
        #expect(try await store.all().map(\.word) == ["Toplam"])
    }

    /// Yalnızca büyük/küçük harf düzeltmesi aynı satırda yapılabilir.
    @Test
    func harfDuzeltmesiAyniSatirdaYapilir() async throws {
        let (_, store) = try make()
        try await store.add("grdb")
        let wordID = try await id(of: "grdb", in: store)

        #expect(try await store.rename(wordID, to: "GRDB") == .renamed)
        #expect(try await store.all().map(\.word) == ["GRDB"])
    }
}
