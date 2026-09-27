import Foundation
import GRDB

/// Kullanıcının notları ve işaretlediği anlar (`notes` tablosu).
nonisolated extension MeetingStore {

    @discardableResult
    func addNote(_ meetingID: Int64, kind: UserNote.Kind, text: String,
                 at time: TimeInterval?) async throws -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await database.write { db in
            try db.execute(sql: """
                INSERT INTO notes (meeting_id, kind, text, at_time) VALUES (?, ?, ?, ?)
                """, arguments: [meetingID, kind.rawValue, trimmed, time])
            return db.lastInsertedRowID
        }
    }

    /// Notun metni değişince eski ayrıntı artık onu anlatmıyor olabilir;
    /// ayrıntı silinir, sonraki özetleme yeniden üretir.
    func updateNote(_ noteID: Int64, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try await database.write { db in
            try db.execute(sql: "UPDATE notes SET text = ?, details = NULL WHERE id = ?",
                           arguments: [trimmed, noteID])
        }
    }

    func deleteNote(_ noteID: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [noteID])
        }
    }

    /// Yazıldığı sırayla: zamanlı notlar kayıttaki yerine göre, sonradan
    /// yazılanlar sonda.
    func notes(_ meetingID: Int64) async throws -> [UserNote] {
        try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, kind, text, at_time, details FROM notes
                WHERE meeting_id = ?
                ORDER BY at_time IS NULL, at_time, id
                """, arguments: [meetingID]).map(Self.note(from:))
        }
    }

    /// Zenginleştirmenin sonucunu yazar. Verilmeyen notların ayrıntısı
    /// **silinir**: yeniden özetlemede artık karşılığı bulunmayan eski ayrıntı
    /// kalmasın.
    func saveNoteDetails(_ meetingID: Int64, details: [Int64: [String]]) async throws {
        let encoded = try details.mapValues {
            String(data: try JSONEncoder().encode($0.map(Self.cleaned)), encoding: .utf8)
        }
        try await database.write { db in
            try db.execute(sql: "UPDATE notes SET details = NULL WHERE meeting_id = ?",
                           arguments: [meetingID])
            for (noteID, json) in encoded {
                try db.execute(sql: """
                    UPDATE notes SET details = ? WHERE id = ? AND meeting_id = ?
                    """, arguments: [json, noteID, meetingID])
            }
        }
    }

    private static func note(from row: Row) -> UserNote {
        let json: String? = row["details"]
        let details = json.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return UserNote(id: row["id"],
                        kind: UserNote.Kind(rawValue: row["kind"]) ?? .note,
                        text: row["text"],
                        at: row["at_time"],
                        details: details)
    }
}
