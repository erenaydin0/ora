import Foundation
import GRDB
import AppKit
import UniformTypeIdentifiers

/// Eski ora'nın (Electron + Python) SQLite dosyasından içe aktarma.
///
/// Şema bilerek uyumlu tutuldu; yeni sütunlar (`confidence`, `calendar_event_id`,
/// `participants.email`, `meeting_participants`) eski dosyada yoktur ve NULL kalır.
///
/// **Sandbox:** ora sandbox'lı olduğu için eski dosyayı kendisi bulup açamaz;
/// kullanıcı `NSOpenPanel` ile seçer (`files.user-selected.read-write` yetkisi).
/// Aynı sebeple eski **ses dosyaları kopyalanmaz** — yalnızca metin verisi taşınır.
enum LegacyImport {

    struct Report: Sendable {
        var meetings = 0
        var transcripts = 0
        var actionItems = 0
        var summaries = 0
        var topics = 0
        var vocabulary = 0
        var corrections = 0
        var skipped = 0

        var turkishSummary: String {
            var parts = ["\(meetings) toplantı", "\(transcripts) transkript satırı"]
            if summaries > 0 { parts.append("\(summaries) özet") }
            if actionItems > 0 { parts.append("\(actionItems) aksiyon") }
            if vocabulary > 0 { parts.append("\(vocabulary) sözlük kelimesi") }
            if corrections > 0 { parts.append("\(corrections) düzeltme") }
            var text = parts.joined(separator: ", ") + " aktarıldı."
            if skipped > 0 { text += " \(skipped) toplantı zaten vardı, atlandı." }
            text += " Ses dosyaları taşınmadı."
            return text
        }
    }

    @MainActor
    static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Eski ora veritabanını seçin (ora.db)"
        panel.prompt = "İçe aktar"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data, .database]
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Seçilen dosyayı okur ve yeni veritabanına yazar.
    static func run(from url: URL, into store: MeetingStore) async throws -> Report {
        var configuration = Configuration()
        configuration.readonly = true
        let legacy = try DatabaseQueue(path: url.path(percentEncoded: false),
                                       configuration: configuration)

        // GRDB `Row` Sendable değildir; veriler eşzamanlılık sınırını geçmeden
        // önce değer tiplerine kopyalanır.
        let rows = try await legacy.read { (db: Database) -> LegacyData in
            var data = LegacyData()
            data.meetings = try Row.fetchAll(db, sql: "SELECT * FROM meetings ORDER BY id")
                .map(LegacyMeeting.init)
            data.transcripts = try Row.fetchAll(db, sql: "SELECT * FROM transcripts ORDER BY meeting_id, start_time")
                .map(LegacyTranscript.init)
            data.actionItems = try Row.fetchAll(db, sql: "SELECT * FROM action_items ORDER BY id")
                .map(LegacyAction.init)
            data.summaries = try Row.fetchAll(db, sql: "SELECT * FROM summaries ORDER BY id")
                .map(LegacySummary.init)
            data.topics = try Row.fetchAll(db, sql: "SELECT * FROM topic_segments ORDER BY id")
                .map(LegacyTopic.init)
            data.vocabulary = ((try? Row.fetchAll(db, sql: "SELECT * FROM vocabulary")) ?? [])
                .map(LegacyVocabulary.init)
            data.corrections = ((try? Row.fetchAll(db, sql: "SELECT * FROM corrections")) ?? [])
                .map(LegacyCorrection.init)
            return data
        }

        let report = try await store.database.write { (db: Database) -> Report in
            var report = Report()
            var identifiers: [Int64: Int64] = [:]   // eski id → yeni id

            for row in rows.meetings {
                guard let oldID = row.id else { continue }
                let title = row.title ?? "İsimsiz Toplantı"
                let date = parseDate(row.date) ?? Date()

                // Aynı ad ve tarihteki toplantı zaten varsa tekrar aktarılmaz.
                let exists = try Int.fetchOne(db, sql: """
                    SELECT 1 FROM meetings WHERE title = ? AND date = ? LIMIT 1
                    """, arguments: [title, date]) != nil
                if exists { report.skipped += 1; continue }

                var record = MeetingRecord(
                    id: nil, title: title, date: date,
                    duration: row.duration ?? 0,
                    healthScore: row.healthScore,
                    status: row.status ?? MeetingRecord.Status.ready.rawValue,
                    template: row.template,
                    // Eski ses dosyaları sandbox dışında; yol taşınmaz.
                    audioPath: nil,
                    calendarEventId: nil,
                    createdAt: parseDate(row.createdAt) ?? date)
                try record.insert(db)
                identifiers[oldID] = record.id!
                report.meetings += 1
            }

            for row in rows.transcripts {
                guard let oldMeeting = row.meetingId,
                      let newMeeting = identifiers[oldMeeting] else { continue }
                var record = TranscriptRecord(
                    id: nil, meetingId: newMeeting,
                    speaker: row.speaker ?? "Bilinmeyen",
                    channel: row.channel,
                    text: row.text ?? "",
                    startTime: row.startTime ?? 0,
                    endTime: row.endTime ?? 0,
                    // Eski şemada güven skoru yok.
                    confidence: nil,
                    createdAt: parseDate(row.createdAt) ?? Date())
                guard !record.text.isEmpty else { continue }
                try record.insert(db)
                report.transcripts += 1
            }

            for row in rows.actionItems {
                guard let oldMeeting = row.meetingId,
                      let newMeeting = identifiers[oldMeeting] else { continue }
                var record = ActionItemRecord(
                    id: nil, meetingId: newMeeting,
                    person: row.person ?? "belirtilmedi",
                    task: row.task ?? "",
                    deadline: row.deadline,
                    status: row.status ?? "pending",
                    createdAt: parseDate(row.createdAt) ?? Date())
                try record.insert(db)
                report.actionItems += 1
            }

            for row in rows.summaries {
                guard let oldMeeting = row.meetingId,
                      let newMeeting = identifiers[oldMeeting] else { continue }
                var record = SummaryRecord(
                    id: nil, meetingId: newMeeting,
                    overview: row.overview, decisions: row.decisions,
                    nextMeeting: row.nextMeeting, sentiment: row.sentiment,
                    talkShare: row.talkShare, deadAirPct: row.deadAirPct,
                    createdAt: parseDate(row.createdAt) ?? Date())
                try record.insert(db)
                report.summaries += 1
            }

            for row in rows.topics {
                guard let oldMeeting = row.meetingId,
                      let newMeeting = identifiers[oldMeeting] else { continue }
                var record = TopicSegmentRecord(
                    id: nil, meetingId: newMeeting, title: row.title ?? "",
                    startTime: row.startTime ?? 0, endTime: row.endTime ?? 0)
                try record.insert(db)
                report.topics += 1
            }

            for row in rows.vocabulary {
                let word = row.word ?? ""
                guard !word.isEmpty else { continue }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO vocabulary (word, source, status, rejected_until, added_date)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [word, row.source ?? "manual",
                                     row.status ?? "active", row.rejectedUntil,
                                     parseDate(row.addedDate) ?? Date()])
                report.vocabulary += 1
            }

            for row in rows.corrections {
                let mistake = row.mistake ?? ""
                let correct = row.correct ?? ""
                guard !mistake.isEmpty, !correct.isEmpty else { continue }
                var record = CorrectionRecord(
                    id: nil, mistake: mistake, correct: correct,
                    meetingId: row.meetingId.flatMap { identifiers[$0] },
                    createdAt: parseDate(row.createdAt) ?? Date())
                try record.insert(db)
                report.corrections += 1
            }
            return report
        }
        Log.info(.store, "Eski veri aktarıldı — \(report.turkishSummary)")
        return report
    }

    // MARK: - Eski satırların Sendable karşılıkları

    private struct LegacyData: Sendable {
        var meetings: [LegacyMeeting] = []
        var transcripts: [LegacyTranscript] = []
        var actionItems: [LegacyAction] = []
        var summaries: [LegacySummary] = []
        var topics: [LegacyTopic] = []
        var vocabulary: [LegacyVocabulary] = []
        var corrections: [LegacyCorrection] = []
    }

    private struct LegacyMeeting: Sendable {
        let id: Int64?, title: String?, date: String?, duration: Int?
        let healthScore: Int?, status: String?, template: String?, createdAt: String?
        init(_ row: Row) {
            id = row["id"]; title = row["title"]; date = row["date"]
            duration = row["duration"]; healthScore = row["health_score"]
            status = row["status"]; template = row["template"]; createdAt = row["created_at"]
        }
    }
    private struct LegacyTranscript: Sendable {
        let meetingId: Int64?, speaker: String?, channel: String?, text: String?
        let startTime: Double?, endTime: Double?, createdAt: String?
        init(_ row: Row) {
            meetingId = row["meeting_id"]; speaker = row["speaker"]; channel = row["channel"]
            text = row["text"]; startTime = row["start_time"]; endTime = row["end_time"]
            createdAt = row["created_at"]
        }
    }
    private struct LegacyAction: Sendable {
        let meetingId: Int64?, person: String?, task: String?, deadline: String?
        let status: String?, createdAt: String?
        init(_ row: Row) {
            meetingId = row["meeting_id"]; person = row["person"]; task = row["task"]
            deadline = row["deadline"]; status = row["status"]; createdAt = row["created_at"]
        }
    }
    private struct LegacySummary: Sendable {
        let meetingId: Int64?, overview: String?, decisions: String?, nextMeeting: String?
        let sentiment: String?, talkShare: String?, deadAirPct: Double?, createdAt: String?
        init(_ row: Row) {
            meetingId = row["meeting_id"]; overview = row["overview"]
            decisions = row["decisions"]; nextMeeting = row["next_meeting"]
            sentiment = row["sentiment"]; talkShare = row["talk_share"]
            deadAirPct = row["dead_air_pct"]; createdAt = row["created_at"]
        }
    }
    private struct LegacyTopic: Sendable {
        let meetingId: Int64?, title: String?, startTime: Double?, endTime: Double?
        init(_ row: Row) {
            meetingId = row["meeting_id"]; title = row["title"]
            startTime = row["start_time"]; endTime = row["end_time"]
        }
    }
    private struct LegacyVocabulary: Sendable {
        let word: String?, source: String?, status: String?
        let rejectedUntil: String?, addedDate: String?
        init(_ row: Row) {
            word = row["word"]; source = row["source"]; status = row["status"]
            rejectedUntil = row["rejected_until"]; addedDate = row["added_date"]
        }
    }
    private struct LegacyCorrection: Sendable {
        let mistake: String?, correct: String?, meetingId: Int64?, createdAt: String?
        init(_ row: Row) {
            mistake = row["mistake"]; correct = row["correct"]
            meetingId = row["meeting_id"]; createdAt = row["created_at"]
        }
    }

    /// Eski dosya ISO 8601 (`2025-03-27T14:30:00`) veya SQLite
    /// (`2025-03-27 14:30:00`) biçimini kullanabiliyor; ikisi de kabul edilir.
    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate,
                             .withColonSeparatorInTime]
        if let date = iso.date(from: value) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
                       "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
