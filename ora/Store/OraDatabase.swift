import Foundation
import GRDB

/// SQLite + FTS5, GRDB üzerinden.
///
/// **Neden SwiftData değil:** ürünün merkezinde transkript içinde tam metin arama
/// var; SwiftData ve Core Data FTS sunmaz (RESEARCH.md §7). Ayrıca SQLite dosyası
/// taşınabilir, incelenebilir ve yedeklenebilir — %100 yerel bir üründe
/// kullanıcının kendi verisine erişebilmesi bir özelliktir.
///
/// Tüm yazımlar `write { }` içinde, yani transaction içinde yapılır (kural #7).
nonisolated final class OraDatabase: Storing {

    private let queue: DatabaseQueue

    /// Uygulamanın kalıcı veritabanı.
    static func shared() throws -> OraDatabase {
        try AppPaths.prepare()
        return try OraDatabase(path: AppPaths.database.path(percentEncoded: false))
    }

    init(path: String) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        queue = try DatabaseQueue(path: path, configuration: configuration)
        try Self.migrator.migrate(queue)
        Log.info(.store, "Veritabanı hazır: \(path)")
    }

    func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        try await queue.write(block)
    }

    func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        try await queue.read(block)
    }

    /// Veritabanı değişikliklerini izlemek için (toplantı listesi canlı güncellenir).
    var reader: any DatabaseReader { queue }
    var writer: any DatabaseWriter { queue }

    // MARK: - Migration'lar
    //
    // Sıralı ve geri alınamaz. INDEX'ler tablolardan sonra kurulur.
    // Şema CLAUDE.md'de sabittir; açık talimat olmadan değiştirilmez.

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_schema") { db in
            try db.execute(sql: """
                CREATE TABLE meetings (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    title             TEXT NOT NULL DEFAULT 'İsimsiz Toplantı',
                    date              TEXT NOT NULL,
                    duration          INTEGER NOT NULL DEFAULT 0,
                    health_score      INTEGER,
                    status            TEXT NOT NULL DEFAULT 'recording',
                    template          TEXT DEFAULT 'general',
                    audio_path        TEXT,
                    calendar_event_id TEXT,
                    created_at        TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE transcripts (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    speaker    TEXT NOT NULL DEFAULT 'Bilinmeyen',
                    channel    TEXT,
                    text       TEXT NOT NULL,
                    start_time REAL NOT NULL,
                    end_time   REAL NOT NULL,
                    confidence REAL,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE action_items (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    person     TEXT NOT NULL,
                    task       TEXT NOT NULL,
                    deadline   TEXT,
                    status     TEXT NOT NULL DEFAULT 'pending',
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE vocabulary (
                    id             INTEGER PRIMARY KEY AUTOINCREMENT,
                    word           TEXT NOT NULL UNIQUE,
                    source         TEXT NOT NULL DEFAULT 'manual',
                    status         TEXT NOT NULL DEFAULT 'active',
                    rejected_until TEXT,
                    added_date     TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE corrections (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    mistake    TEXT NOT NULL,
                    correct    TEXT NOT NULL,
                    meeting_id INTEGER REFERENCES meetings(id) ON DELETE SET NULL,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE chat_history (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    meeting_id INTEGER REFERENCES meetings(id) ON DELETE CASCADE,
                    question   TEXT NOT NULL,
                    answer     TEXT NOT NULL,
                    timestamp  TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE participants (
                    id            INTEGER PRIMARY KEY AUTOINCREMENT,
                    name          TEXT NOT NULL UNIQUE,
                    email         TEXT,
                    meeting_count INTEGER NOT NULL DEFAULT 0,
                    last_seen     TEXT
                );

                CREATE TABLE meeting_participants (
                    meeting_id     INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    participant_id INTEGER NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
                    source         TEXT NOT NULL,
                    role           TEXT,
                    PRIMARY KEY (meeting_id, participant_id)
                );

                CREATE TABLE topic_segments (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    title      TEXT NOT NULL,
                    start_time REAL NOT NULL,
                    end_time   REAL NOT NULL
                );

                CREATE TABLE summaries (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    meeting_id   INTEGER NOT NULL UNIQUE REFERENCES meetings(id) ON DELETE CASCADE,
                    overview     TEXT,
                    decisions    TEXT,
                    next_meeting TEXT,
                    sentiment    TEXT,
                    talk_share   TEXT,
                    dead_air_pct REAL,
                    created_at   TEXT NOT NULL DEFAULT (datetime('now'))
                );
                """)
        }

        migrator.registerMigration("v2_fts") { db in
            // `unicode61` Türkçe'yi doğru işliyor: 'istanbul' → 'İstanbul' eşleşiyor,
            // 'bütçe' diakritikleriyle bulunuyor (RESEARCH.md §7).
            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcripts_fts USING fts5(
                    text, speaker,
                    content=transcripts,
                    content_rowid=id
                );

                CREATE TRIGGER transcripts_ai AFTER INSERT ON transcripts BEGIN
                    INSERT INTO transcripts_fts(rowid, text, speaker)
                    VALUES (new.id, new.text, new.speaker);
                END;

                CREATE TRIGGER transcripts_ad AFTER DELETE ON transcripts BEGIN
                    INSERT INTO transcripts_fts(transcripts_fts, rowid, text, speaker)
                    VALUES ('delete', old.id, old.text, old.speaker);
                END;

                CREATE TRIGGER transcripts_au AFTER UPDATE ON transcripts BEGIN
                    INSERT INTO transcripts_fts(transcripts_fts, rowid, text, speaker)
                    VALUES ('delete', old.id, old.text, old.speaker);
                    INSERT INTO transcripts_fts(rowid, text, speaker)
                    VALUES (new.id, new.text, new.speaker);
                END;
                """)
        }

        migrator.registerMigration("v3_indexes") { db in
            try db.execute(sql: """
                CREATE INDEX idx_transcripts_meeting ON transcripts(meeting_id, start_time);
                CREATE INDEX idx_action_items_meeting ON action_items(meeting_id);
                CREATE INDEX idx_topic_segments_meeting ON topic_segments(meeting_id);
                CREATE INDEX idx_meetings_date ON meetings(date DESC);
                CREATE INDEX idx_corrections_meeting ON corrections(meeting_id);
                """)
        }

        // Circleback referanslı çıktı yapısı: konu bölümlerine gövde,
        // aksiyonlara gerekçe. Kaldırılan sütunlar hiç doldurulmuyordu ya da
        // yazılıp hiç okunmuyordu (konuşma payı arayüzden kaldırıldı).
        migrator.registerMigration("v4_notes") { db in
            try db.execute(sql: """
                ALTER TABLE action_items   ADD COLUMN context TEXT;
                ALTER TABLE topic_segments ADD COLUMN bullets TEXT;

                ALTER TABLE meetings  DROP COLUMN health_score;
                ALTER TABLE summaries DROP COLUMN next_meeting;
                ALTER TABLE summaries DROP COLUMN sentiment;
                ALTER TABLE summaries DROP COLUMN talk_share;
                ALTER TABLE summaries DROP COLUMN dead_air_pct;
                """)
        }

        // Kişileri toplantılar arasında tanımak için ses izleri (RESEARCH.md §40).
        // `speaker_embeddings`: bu toplantının kümeleri, **o anki etiketleriyle**
        // — kullanıcı bir kümeyi adlandırınca izin kime ait olduğu buradan
        // bilinir. `voiceprints`: kişi başına öğrenilmiş örnekler; toplantı
        // silinse de kalır (düzeltmeler gibi, kişi bilgisi toplantıya bağlı
        // değil) ve Ayarlar'dan tümüyle silinir. İkisi de cihazdan çıkmaz.
        migrator.registerMigration("v5_voiceprints") { db in
            try db.execute(sql: """
                CREATE TABLE speaker_embeddings (
                    meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    label      TEXT NOT NULL,
                    channel    TEXT NOT NULL,
                    embedding  BLOB NOT NULL,
                    PRIMARY KEY (meeting_id, label)
                );
                CREATE TABLE voiceprints (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    person     TEXT NOT NULL,
                    meeting_id INTEGER REFERENCES meetings(id) ON DELETE SET NULL,
                    embedding  BLOB NOT NULL,
                    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX voiceprints_person ON voiceprints(person);
                """)
        }

        // Bağlantı Kuralları §6: "Bu toplantı cihazdan çıkmasın". İşaretli
        // toplantıya hiçbir sağlayıcı ve entegrasyon dokunamaz.
        migrator.registerMigration("v6_local_only") { db in
            try db.execute(sql: """
                ALTER TABLE meetings ADD COLUMN local_only INTEGER NOT NULL DEFAULT 0;
                """)
        }

        // Not defteri (COMPETITION.md §4.6, §4.9): kullanıcının kendi notları
        // ve kayıt sırasında işaretlenen anlar. `at_time` kayıttaki saniyedir,
        // sonradan yazılan notta NULL. `details` transkriptten eklenen ayrıntı
        // (JSON `[String]`) — kullanıcının yazdığı değil, ayrı sütunda durur ki
        // yeniden özetleme notun kendisine dokunmadan onu yenileyebilsin.
        migrator.registerMigration("v7_notes") { db in
            try db.execute(sql: """
                CREATE TABLE notes (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    kind       TEXT NOT NULL DEFAULT 'note',
                    text       TEXT NOT NULL DEFAULT '',
                    at_time    REAL,
                    details    TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE INDEX idx_notes_meeting ON notes(meeting_id, at_time);
                """)
        }

        // Etiketler (COMPETITION.md §4.16): toplantıya etiket + kenar
        // çubuğunda etikete göre süzme. Hiçbir toplantıda kalmayan etiket
        // silinir (`MeetingStore.setTag`); tablo kendiliğinden temiz kalır.
        migrator.registerMigration("v8_tags") { db in
            try db.execute(sql: """
                CREATE TABLE tags (
                    id   INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL UNIQUE
                );
                CREATE TABLE meeting_tags (
                    meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    tag_id     INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                    PRIMARY KEY (meeting_id, tag_id)
                );
                CREATE INDEX idx_meeting_tags_tag ON meeting_tags(tag_id);
                """)
        }

        // Toplantılar arası sohbet (COMPETITION.md §4.10): `meeting_id` NULL
        // olan turlar hiçbir toplantıya ait değildir; yanıtın dayandığı
        // toplantılar `sources`'ta (JSON kimlik listesi) durur.
        migrator.registerMigration("v9_cross_chat") { db in
            try db.execute(sql: "ALTER TABLE chat_history ADD COLUMN sources TEXT")
        }

        return migrator
    }
}

/// ARCHITECTURE.md'deki Store sözleşmesi.
nonisolated protocol Storing: Sendable {
    func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T
    func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T
}

extension OraDatabase: @unchecked Sendable {}
