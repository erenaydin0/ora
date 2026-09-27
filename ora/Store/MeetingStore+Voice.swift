import Foundation
import GRDB

/// Ses izleri: kişileri toplantılar arasında tanımanın kalıcı tarafı
/// (RESEARCH.md §40). Eşleştirme politikası `VoiceMatcher`'da; burada yalnızca
/// okuma, yazma ve **ne zaman öğrenileceği** var.
///
/// Ses izi biyometrik bir veridir: yalnızca bu Mac'te durur, hiçbir
/// bağlantıya gönderilmez (Bağlantı Kuralları §3 sesle aynı kapsamda) ve
/// Ayarlar'dan tek hamlede silinir.
nonisolated extension MeetingStore {

    /// Kişi başına tutulan en fazla örnek. Yenisi gelince en eskisi düşer —
    /// ses zamanla ve mikrofonla değişir.
    static let voiceprintsPerPerson = 10

    // MARK: - Toplantının kümeleri

    /// Konuşmacı ayrımının bu toplantıda bulduğu kümeler, verilen etiketleriyle.
    func saveSpeakerEmbeddings(_ meetingID: Int64, channel: Channel,
                               embeddings: [String: [Float]]) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM speaker_embeddings WHERE meeting_id = ?",
                           arguments: [meetingID])
            for (label, embedding) in embeddings where !embedding.isEmpty {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO speaker_embeddings
                        (meeting_id, label, channel, embedding)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [meetingID, label, channel.databaseValue,
                                     VoicePrint.encode(embedding)])
            }
        }
    }

    // MARK: - Ses izleri

    /// Kişi → örnekler.
    func voiceprints() async throws -> [String: [[Float]]] {
        try await database.read { db in
            var result: [String: [[Float]]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT person, embedding FROM voiceprints") {
                let person: String = row["person"]
                let data: Data = row["embedding"]
                result[person, default: []].append(VoicePrint.decode(data))
            }
            return result
        }
    }

    func voiceprintCount(person: String) async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM voiceprints WHERE person = ?",
                             arguments: [person]) ?? 0
        }
    }

    /// Ses izi olan kişi sayısı (Ayarlar'da gösterilir).
    func voiceprintPeopleCount() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT person) FROM voiceprints") ?? 0
        }
    }

    func addVoiceprint(person: String, meetingID: Int64?, embedding: [Float]) async throws {
        try await database.write { db in
            try Self.insertVoiceprint(db, person: person, meetingID: meetingID,
                                      embedding: embedding)
        }
    }

    /// Bütün ses izleri ve toplantı kümeleri silinir. Transkriptteki adlar kalır.
    func deleteAllVoiceprints() async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM voiceprints")
            try db.execute(sql: "DELETE FROM speaker_embeddings")
        }
    }

    // MARK: - Öğrenme

    /// Etiketi transkriptten tamamen kalkan kümenin sesi yeni ada öğretilir.
    ///
    /// Aksiyon taşımayla (`moveActions`) aynı kural: etiketin bir satırı bile
    /// kaldıysa o küme kime ait belli değildir, öğrenilmez. Eski etiket bir
    /// kişi adıysa (yanlış tanınmış ya da yanlış adlandırılmış küme) o
    /// toplantıdan ona öğretilen iz geri alınır — yanlış bir örnek sonraki
    /// toplantılarda aynı hatayı üretirdi.
    static func learnVoice(_ db: Database, meetingID: Int64,
                           from labels: Set<String>, to speaker: String) throws {
        for label in labels where label != speaker {
            let remaining = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcripts WHERE meeting_id = ? AND speaker = ?
                """, arguments: [meetingID, label]) ?? 0
            guard remaining == 0,
                  let row = try Row.fetchOne(db, sql: """
                    SELECT channel, embedding FROM speaker_embeddings
                    WHERE meeting_id = ? AND label = ?
                    """, arguments: [meetingID, label])
            else { continue }
            let channel: String = row["channel"]
            let data: Data = row["embedding"]

            if let previous = VoicePrint.person(for: label) {
                try db.execute(sql: """
                    DELETE FROM voiceprints WHERE meeting_id = ? AND person = ?
                    """, arguments: [meetingID, previous])
            }
            if let person = VoicePrint.person(for: speaker) {
                try insertVoiceprint(db, person: person, meetingID: meetingID,
                                     embedding: VoicePrint.decode(data))
            }
            // Küme artık yeni adını taşır; ikinci bir düzeltme de izlenebilsin.
            try db.execute(sql: """
                DELETE FROM speaker_embeddings WHERE meeting_id = ? AND label = ?
                """, arguments: [meetingID, label])
            try db.execute(sql: """
                INSERT OR REPLACE INTO speaker_embeddings (meeting_id, label, channel, embedding)
                VALUES (?, ?, ?, ?)
                """, arguments: [meetingID, speaker, channel, data])
        }
    }

    fileprivate static func insertVoiceprint(_ db: Database, person: String,
                                             meetingID: Int64?, embedding: [Float]) throws {
        guard !embedding.isEmpty else { return }
        if let meetingID {
            // Aynı toplantıdan aynı kişiye tek örnek.
            try db.execute(sql: "DELETE FROM voiceprints WHERE meeting_id = ? AND person = ?",
                           arguments: [meetingID, person])
        }
        try db.execute(sql: """
            INSERT INTO voiceprints (person, meeting_id, embedding) VALUES (?, ?, ?)
            """, arguments: [person, meetingID, VoicePrint.encode(embedding)])
        try db.execute(sql: """
            DELETE FROM voiceprints WHERE person = ? AND id NOT IN (
                SELECT id FROM voiceprints WHERE person = ? ORDER BY id DESC LIMIT ?)
            """, arguments: [person, person, voiceprintsPerPerson])
    }
}

/// Ses izinin diskteki biçimi ve kime ait sayılacağı.
nonisolated enum VoicePrint {

    /// Float32, yerel bayt sırası (yalnızca Apple Silicon — CLAUDE.md).
    static func encode(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats
    }

    /// Kullanıcının kendi sesinin kişi anahtarı.
    static let me = Channel.mic.speaker

    /// Etiket bir kişi mi? "Ben" kaydı tutandır ve öğrenilir; "Katılımcı",
    /// "Katılımcı 2" ve "Bilinmeyen" kimse değildir.
    static func person(for label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased(with: Locale(identifier: "tr_TR"))
            == me.lowercased(with: Locale(identifier: "tr_TR")) { return me }
        return MeetingStore.isChannelLabel(trimmed) ? nil : trimmed
    }
}
