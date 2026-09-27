import Foundation
import GRDB

/// Etiketler (COMPETITION.md §4.16): Granola'nın klasörlerinin en küçük
/// karşılığı — toplantıya etiket, kenar çubuğunda etikete göre süzme.
nonisolated extension MeetingStore {

    /// `tagList` sütununda etiketleri ayıran karakter. Kullanıcının yazdığı
    /// bir ada karışamayacak bir kontrol karakteri (Unit Separator).
    static let tagSeparator: Character = "\u{1F}"

    /// Kenar çubuğu süzgecinin satırı.
    struct TagCount: Identifiable, Hashable, FetchableRecord, Decodable, Sendable {
        var name: String
        var count: Int
        var id: String { name }
    }

    /// Etiket adının kanonik biçimi: baştaki `#` ve fazla boşluk atılır.
    /// Boşsa `nil` — boş etiket yazılmaz.
    static func tagName(_ raw: String) -> String? {
        let words = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix(while: { $0 == "#" })
            .split(whereSeparator: \.isWhitespace)
        let name = words.joined(separator: " ")
        return name.isEmpty ? nil : String(name.prefix(40))
    }

    func allTags() async throws -> [TagCount] {
        try await database.read { db in
            try TagCount.fetchAll(db, sql: """
                SELECT g.name AS name, COUNT(mt.meeting_id) AS count
                FROM tags g JOIN meeting_tags mt ON mt.tag_id = g.id
                GROUP BY g.id
                ORDER BY g.name COLLATE NOCASE
                """)
        }
    }

    /// Etiketi toplantıya ekler ya da kaldırır.
    ///
    /// "İş" ve "iş" aynı etikettir: karşılaştırma **Türkçe** küçük harfle
    /// yapılır (SQLite'ın `NOCASE`'i yalnızca ASCII'yi katlar, `İ`/`i`'yi
    /// ayırır) ve ilk yazılan biçim korunur. Hiçbir toplantıda kalmayan
    /// etiket silinir.
    func setTag(_ meetingID: Int64, _ raw: String, on: Bool) async throws {
        guard let name = Self.tagName(raw) else { return }
        let key = name.lowercased(with: Locale(identifier: "tr_TR"))
        try await database.write { db in
            let existing = try Row.fetchAll(db, sql: "SELECT id, name FROM tags")
                .first { ($0["name"] as String).lowercased(with: Locale(identifier: "tr_TR")) == key }
            if on {
                let tagID: Int64
                if let existing {
                    tagID = existing["id"]
                } else {
                    try db.execute(sql: "INSERT INTO tags (name) VALUES (?)", arguments: [name])
                    tagID = db.lastInsertedRowID
                }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO meeting_tags (meeting_id, tag_id) VALUES (?, ?)
                    """, arguments: [meetingID, tagID])
            } else if let existing {
                let tagID: Int64 = existing["id"]
                try db.execute(sql: "DELETE FROM meeting_tags WHERE meeting_id = ? AND tag_id = ?",
                               arguments: [meetingID, tagID])
            }
            try Self.dropUnusedTags(db)
        }
    }

    /// Etiketi bütün toplantılardan kaldırır. Toplantılara dokunulmaz.
    func deleteTag(_ name: String) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM tags WHERE name = ?", arguments: [name])
        }
    }

    /// Toplantı silinince bağ cascade ile gider; artakalan etiket burada temizlenir.
    static func dropUnusedTags(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM tags WHERE id NOT IN (SELECT DISTINCT tag_id FROM meeting_tags)
            """)
    }
}
