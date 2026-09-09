import Foundation
import GRDB

/// `vocabulary` tablosunun kapısı.
///
/// Sözlük iki kaynaktan beslenir: kullanıcının elle eklediği kelimeler
/// (`manual`) ve transkriptte yaptığı düzeltmelerden çıkarılanlar
/// (`correction`). Düzeltmeden gelenler **`pending`** durumunda başlar;
/// kullanıcı onaylamadan transkripsiyona verilmez.
nonisolated struct VocabularyStore: Sendable {

    let database: OraDatabase

    struct Word: Identifiable, Hashable, FetchableRecord, Decodable, Sendable {
        var id: Int64
        var word: String
        var source: String
        var status: String
        var addedDate: Date?

        var isPending: Bool { status == "pending" }
        var sourceLabel: String {
            switch source {
            case "correction": "düzeltmeden"
            case "calendar":   "takvimden"
            case "speaker":    "konuşmacıdan"
            default:           "elle eklendi"
            }
        }
    }

    /// Transkripsiyona verilecek kelimeler: yalnızca `active`.
    func activeWords() async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT word FROM vocabulary WHERE status = 'active' ORDER BY word
                """)
        }
    }

    func all() async throws -> [Word] {
        try await database.read { db in
            // Reddedilen kelime 30 günlük soğuma boyunca listede görünmez.
            try Word.fetchAll(db, sql: """
                SELECT id, word, source, status, added_date AS addedDate FROM vocabulary
                WHERE status != 'rejected'
                   OR rejected_until IS NULL
                   OR rejected_until <= datetime('now')
                ORDER BY status = 'pending' DESC, word COLLATE NOCASE
                """)
        }
    }

    func add(_ word: String, source: String = "manual", status: String = "active") async throws {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await database.write { db in
            // Reddedilmiş bir kelime soğuma süresi dolmadan geri gelmez.
            let blocked = try Bool.fetchOne(db, sql: """
                SELECT 1 FROM vocabulary
                WHERE word = ? AND status = 'rejected'
                  AND (rejected_until IS NULL OR rejected_until > datetime('now'))
                """, arguments: [trimmed]) ?? false
            guard !blocked else { return }
            // Zaten `active` olan bir kelime, düzeltmeden gelen yeni bir aday
            // yüzünden `pending`e **düşürülmez** — kullanıcının onayı geri alınmaz.
            try db.execute(sql: """
                INSERT INTO vocabulary (word, source, status, added_date)
                VALUES (?, ?, ?, datetime('now'))
                ON CONFLICT(word) DO UPDATE SET
                    status = CASE WHEN vocabulary.status = 'active' THEN 'active'
                                  ELSE excluded.status END
                """, arguments: [trimmed, source, status])
        }
    }

    func approve(_ id: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE vocabulary SET status = 'active' WHERE id = ?",
                           arguments: [id])
        }
    }

    /// Reddedilen kelime 30 gün geri gelmez.
    func reject(_ id: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: """
                UPDATE vocabulary
                SET status = 'rejected', rejected_until = datetime('now', '+30 days')
                WHERE id = ?
                """, arguments: [id])
        }
    }

    func remove(_ id: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM vocabulary WHERE id = ?", arguments: [id])
        }
    }

    /// Kullanıcının düzeltmesinden sözlük adayı çıkarır.
    ///
    /// Yalnızca **yeni görünen kelimeler** aday olur: düzeltilmiş metinde olup
    /// hatalı metinde olmayanlar. Böylece "bir kelimeyi düzelttim" değil,
    /// "sistemin bilmediği bir terim var" bilgisi kaydedilir.
    func proposeFromCorrection(mistake: String, correct: String) async throws {
        let mistakeWords = Set(Self.tokens(mistake))
        let candidates = Self.tokens(correct)
            .filter { !mistakeWords.contains($0) }
            .filter { $0.count >= 3 }
            // Yalnızca büyük harfle başlayanlar: özel isimler ve ürün adları.
            // Tanımanın en zayıf noktası burasıdır.
            .filter { $0.first?.isUppercase == true }
        for candidate in Set(candidates) {
            try await add(candidate, source: "correction", status: "pending")
        }
    }

    /// Takvim katılımcı adları — doğrudan `active` olur, kullanıcı onayı istenmez;
    /// kaynak zaten kullanıcının kendi takvimidir.
    func addCalendarNames(_ names: [String]) async throws {
        for name in names {
            for part in Self.tokens(name) where part.count >= 3 {
                try await add(part, source: "calendar", status: "active")
            }
            let full = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if full.contains(" ") { try await add(full, source: "calendar", status: "active") }
        }
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init)
    }
}
