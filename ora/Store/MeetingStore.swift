import Foundation
import GRDB

/// Toplantı verisinin tek kapısı. UI ve Pipeline SQL yazmaz; buradan geçer.
struct MeetingStore: Sendable {

    let database: OraDatabase

    // MARK: - Kayıt yaşam döngüsü

    /// Kayıt başlarken satır açılır — `meetings.id` bundan sonra dosya adıdır.
    func createMeeting(date: Date = Date()) async throws -> Int64 {
        try await database.write { db in
            var record = MeetingRecord(
                id: nil,
                title: Self.provisionalTitle(for: date),
                date: date, duration: 0, healthScore: nil,
                status: MeetingRecord.Status.recording.rawValue,
                template: "general", audioPath: nil,
                calendarEventId: nil, createdAt: Date())
            try record.insert(db)
            return record.id!
        }
    }

    func markProcessing(_ meetingID: Int64, audioPath: URL, duration: TimeInterval) async throws {
        try await database.write { db in
            try db.execute(sql: """
                UPDATE meetings SET status = ?, audio_path = ?, duration = ? WHERE id = ?
                """,
                arguments: [MeetingRecord.Status.processing.rawValue,
                            audioPath.path(percentEncoded: false),
                            Int(duration.rounded()), meetingID])
        }
    }

    func markReady(_ meetingID: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE meetings SET status = ? WHERE id = ?",
                           arguments: [MeetingRecord.Status.ready.rawValue, meetingID])
        }
    }

    func updateTitle(_ meetingID: Int64, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await database.write { db in
            try db.execute(sql: "UPDATE meetings SET title = ? WHERE id = ?",
                           arguments: [trimmed, meetingID])
        }
    }

    // MARK: - Yazma

    /// Transkripti tamamen değiştirir. Tam geçiş, canlı ön izlemenin yerini alır.
    func replaceTranscript(_ meetingID: Int64, segments: [Segment]) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM transcripts WHERE meeting_id = ?",
                           arguments: [meetingID])
            for segment in segments {
                var record = TranscriptRecord(
                    id: nil, meetingId: meetingID, speaker: segment.speaker,
                    channel: segment.channel.databaseValue, text: segment.text,
                    startTime: segment.start, endTime: segment.end,
                    confidence: segment.confidence, createdAt: Date())
                try record.insert(db)
            }
        }
    }

    func saveSummary(_ meetingID: Int64, ozet: Ozet?, topics: [TopicSegment],
                     metrics: MeetingMetrics?) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM summaries WHERE meeting_id = ?", arguments: [meetingID])
            try db.execute(sql: "DELETE FROM action_items WHERE meeting_id = ?", arguments: [meetingID])
            try db.execute(sql: "DELETE FROM topic_segments WHERE meeting_id = ?", arguments: [meetingID])

            let encoder = JSONEncoder()
            var talkShare: String?
            if let metrics {
                // Kanal numarası değil, konuşmacı adı saklanır — okunabilir kalsın.
                let named = Dictionary(uniqueKeysWithValues: metrics.talkShare.map {
                    (Channel(rawValue: $0.key)?.speaker ?? "\($0.key)",
                     Int(($0.value * 100).rounded()))
                })
                talkShare = String(data: try encoder.encode(named), encoding: .utf8)
            }

            var summary = SummaryRecord(
                id: nil, meetingId: meetingID,
                overview: ozet?.genelBakis,
                decisions: try ozet.map { String(data: try encoder.encode($0.kararlar),
                                                 encoding: .utf8) } ?? nil,
                nextMeeting: nil, sentiment: nil,
                talkShare: talkShare,
                deadAirPct: metrics.map { $0.deadAirPercentage * 100 },
                createdAt: Date())
            try summary.insert(db)

            for aksiyon in ozet?.aksiyonlar ?? [] {
                var item = ActionItemRecord(
                    id: nil, meetingId: meetingID, person: aksiyon.kisi, task: aksiyon.gorev,
                    deadline: Self.normalizedDeadline(aksiyon.sonTarih),
                    status: "pending", createdAt: Date())
                try item.insert(db)
            }
            for topic in topics {
                var record = TopicSegmentRecord(id: nil, meetingId: meetingID,
                                                title: topic.title,
                                                startTime: topic.start, endTime: topic.end)
                try record.insert(db)
            }
        }
    }

    /// Kullanıcının transkriptte yaptığı düzeltme. Hem satır güncellenir hem de
    /// `corrections` tablosuna yazılır — Faz 6'da vocabulary'yi besleyecek.
    func applyCorrection(meetingID: Int64, original: Segment, corrected: String) async throws {
        let corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty, corrected != original.text else { return }
        try await database.write { db in
            try db.execute(sql: """
                UPDATE transcripts SET text = ?
                WHERE meeting_id = ? AND start_time = ? AND channel = ?
                """,
                arguments: [corrected, meetingID, original.start,
                            original.channel.databaseValue])
            var record = CorrectionRecord(id: nil, mistake: original.text,
                                          correct: corrected, meetingId: meetingID,
                                          createdAt: Date())
            try record.insert(db)
        }
    }

    // MARK: - Okuma

    /// Toplantı listesi. `search` boşsa tümü; doluysa başlık **ve** FTS5 transkript
    /// araması birleştirilir.
    func list(search: String = "") async throws -> [MeetingListItem] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await database.read { db in
            guard !term.isEmpty else {
                return try MeetingListItem.fetchAll(db, sql: """
                    SELECT id, title, date, duration, status FROM meetings ORDER BY date DESC
                    """)
            }
            let pattern = Self.ftsPattern(term)
            return try MeetingListItem.fetchAll(db, sql: """
                SELECT id, title, date, duration, status FROM meetings
                WHERE title LIKE ?
                   OR id IN (
                        SELECT t.meeting_id FROM transcripts_fts f
                        JOIN transcripts t ON t.id = f.rowid
                        WHERE transcripts_fts MATCH ?
                      )
                ORDER BY date DESC
                """, arguments: ["%\(term)%", pattern])
        }
    }

    /// Aramanın transkriptte geçtiği yerler — listede eşleşmenin nerede olduğunu
    /// göstermek için.
    func snippets(for meetingID: Int64, search: String, limit: Int = 3) async throws -> [String] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT snippet(transcripts_fts, 0, '', '', '…', 12) FROM transcripts_fts f
                JOIN transcripts t ON t.id = f.rowid
                WHERE transcripts_fts MATCH ? AND t.meeting_id = ?
                LIMIT ?
                """, arguments: [Self.ftsPattern(term), meetingID, limit])
        }
    }

    func load(_ meetingID: Int64) async throws -> LoadedMeeting? {
        try await database.read { db in
            guard let meeting = try MeetingRecord.fetchOne(db, sql:
                "SELECT * FROM meetings WHERE id = ?", arguments: [meetingID])
            else { return nil }

            let segments = try TranscriptRecord.fetchAll(db, sql: """
                SELECT * FROM transcripts WHERE meeting_id = ? ORDER BY start_time
                """, arguments: [meetingID]).map(\.segment)

            let summaryRow = try SummaryRecord.fetchOne(db, sql:
                "SELECT * FROM summaries WHERE meeting_id = ?", arguments: [meetingID])
            let actions = try ActionItemRecord.fetchAll(db, sql:
                "SELECT * FROM action_items WHERE meeting_id = ? ORDER BY id",
                arguments: [meetingID])
            let topics = try TopicSegmentRecord.fetchAll(db, sql: """
                SELECT * FROM topic_segments WHERE meeting_id = ? ORDER BY start_time
                """, arguments: [meetingID])
                .map { TopicSegment(title: $0.title, start: $0.startTime, end: $0.endTime) }

            var ozet: Ozet?
            if let summaryRow, let overview = summaryRow.overview {
                ozet = Ozet(genelBakis: overview,
                            kararlar: summaryRow.decisionList,
                            aksiyonlar: actions.map {
                                Ozet.Aksiyon(kisi: $0.person, gorev: $0.task,
                                             sonTarih: $0.deadline ?? "belirtilmedi")
                            })
            }
            let metrics = segments.isEmpty ? nil
                : MeetingMetrics.compute(segments: segments,
                                         duration: TimeInterval(meeting.duration))
            return LoadedMeeting(meeting: meeting, segments: segments,
                                 summary: ozet, topics: topics, metrics: metrics)
        }
    }

    // MARK: - Silme

    /// Toplantı satırı cascade ile transkript, özet, aksiyon ve konuları da siler;
    /// FTS trigger'ları indeksi temizler. Ses dosyası ayrıca silinir.
    func delete(_ meetingID: Int64) async throws {
        let audioPath: String? = try await database.write { db in
            let path = try String.fetchOne(db, sql: "SELECT audio_path FROM meetings WHERE id = ?",
                                           arguments: [meetingID])
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [meetingID])
            return path
        }
        if let audioPath {
            try? FileManager.default.removeItem(atPath: audioPath)
        }
        Log.info(.store, "Toplantı silindi: \(meetingID)")
    }

    // MARK: - Yardımcılar

    /// FTS5 sorgusu: her terim tırnaklanır ve önek eşleşmesi açılır.
    /// Tırnaklama olmadan kullanıcının yazdığı `"` veya `*` sorguyu bozar.
    static func ftsPattern(_ term: String) -> String {
        term.split(whereSeparator: \.isWhitespace)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " ")
    }

    /// Faz 6'da Foundation Models başlık üretecek; o zamana kadar tarih/saat.
    static func provisionalTitle(for date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened) + " toplantısı"
    }

    /// "belirtilmedi" DB'de NULL olur — sütun anlamını korusun.
    static func normalizedDeadline(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.lowercased(with: Locale(identifier: "tr_TR")) != "belirtilmedi"
        else { return nil }
        return trimmed
    }
}
