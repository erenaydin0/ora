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
                date: date, duration: 0,
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

    /// Özeti, aksiyonları ve konuları **tümüyle** yeniden yazar. Yeniden
    /// özetleme aksiyonların tamamlanma durumunu sıfırlar; maddeler de
    /// yeniden üretildiği için bu doğru davranış.
    func saveSummary(_ meetingID: Int64, ozet: Ozet?, topics: [TopicSegment]) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM summaries WHERE meeting_id = ?", arguments: [meetingID])
            try db.execute(sql: "DELETE FROM action_items WHERE meeting_id = ?", arguments: [meetingID])
            try db.execute(sql: "DELETE FROM topic_segments WHERE meeting_id = ?", arguments: [meetingID])

            let encoder = JSONEncoder()
            var summary = SummaryRecord(
                id: nil, meetingId: meetingID,
                overview: try ozet.map { String(data: try encoder.encode($0.genelBakis),
                                                encoding: .utf8) } ?? nil,
                decisions: try ozet.map { String(data: try encoder.encode($0.kararlar),
                                                 encoding: .utf8) } ?? nil,
                createdAt: Date())
            try summary.insert(db)

            for aksiyon in ozet?.aksiyonlar ?? [] {
                var item = ActionItemRecord(
                    id: nil, meetingId: meetingID,
                    person: Self.cleaned(aksiyon.kisi), task: Self.cleaned(aksiyon.gorev),
                    context: Self.normalizedContext(aksiyon.baglam),
                    deadline: Self.normalizedDeadline(aksiyon.sonTarih),
                    status: ActionStatus.pending.rawValue, createdAt: Date())
                try item.insert(db)
            }
            for topic in topics {
                var record = TopicSegmentRecord(
                    id: nil, meetingId: meetingID, title: topic.title,
                    bullets: String(data: try encoder.encode(topic.bullets), encoding: .utf8),
                    startTime: topic.start, endTime: topic.end)
                try record.insert(db)
            }
        }
    }

    /// Aksiyonun tamamlanma durumu. `action_items.status` bu iki değeri alır.
    enum ActionStatus: String { case pending, done }

    func setActionDone(_ actionID: Int64, _ done: Bool) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE action_items SET status = ? WHERE id = ?",
                           arguments: [(done ? ActionStatus.done : .pending).rawValue, actionID])
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

    /// Bir transkript satırını siler. Yanlış duyulan özel bir bilgi ya da
    /// araya karışan bir konuşma için — kullanıcı kendi kaydının sahibidir.
    /// FTS trigger'ı indeksi temizler.
    func deleteSegment(meetingID: Int64, segment: Segment) async throws {
        try await database.write { db in
            try db.execute(sql: """
                DELETE FROM transcripts
                WHERE meeting_id = ? AND start_time = ? AND channel = ?
                """,
                arguments: [meetingID, segment.start, segment.channel.databaseValue])
        }
    }

    /// Konuşmacı etiketini değiştirir. Yalnız-mikrofon modunda her şey "Ben"
    /// damgalanıyor; kanal fiziksel gerçektir, **etiket** düzeltilebilir olmalı.
    func setSpeaker(meetingID: Int64, segment: Segment, speaker: String) async throws {
        try await database.write { db in
            try db.execute(sql: """
                UPDATE transcripts SET speaker = ?
                WHERE meeting_id = ? AND start_time = ? AND channel = ?
                """,
                arguments: [speaker, meetingID, segment.start,
                            segment.channel.databaseValue])
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

    /// Arama sonucunun **nerede** eşleştiği: toplantı başına ilk parçacık.
    ///
    /// Tek sorgu — toplantı başına ayrı sorgu atmak liste kaydırılırken
    /// gereksiz yük olurdu. Eşleşen kelime `Self.mark` ile işaretlenir; arayüz
    /// bu işareti kalın yazıya çevirir.
    func snippets(search: String, limit: Int = 300) async throws -> [Int64: String] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [:] }
        let rows: [SnippetRow] = try await database.read { db in
            try SnippetRow.fetchAll(db, sql: """
                SELECT t.meeting_id AS meetingID,
                       snippet(transcripts_fts, 0, ?, ?, '…', 10) AS text
                FROM transcripts_fts f
                JOIN transcripts t ON t.id = f.rowid
                WHERE transcripts_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [Self.mark, Self.mark, Self.ftsPattern(term), limit])
        }
        var result: [Int64: String] = [:]
        for row in rows where result[row.meetingID] == nil {
            result[row.meetingID] = row.text
        }
        return result
    }

    private struct SnippetRow: FetchableRecord, Decodable, Sendable {
        var meetingID: Int64
        var text: String
    }

    /// Eşleşmeyi saran işaret. Transkript metninde geçmeyecek bir kontrol
    /// karakteri seçildi; HTML benzeri bir etiket kullanıcı metnine karışabilirdi.
    static let mark = "\u{2}"

    /// Tüm toplantıların aksiyonları — kaynak toplantısıyla birlikte.
    ///
    /// Kullanıcının "bana ne düştü" sorusu toplantı açıldığında değil, sabah
    /// uygulama açıldığında sorulur; o cevabın tek toplantıya bağlı olmaması
    /// gerekiyor (COMPETITION.md §4.2).
    func allActions() async throws -> [BoardAction] {
        try await database.read { db in
            try BoardAction.fetchAll(db, sql: """
                SELECT a.id            AS id,
                       a.meeting_id    AS meetingID,
                       m.title         AS meetingTitle,
                       m.date          AS meetingDate,
                       a.person        AS person,
                       a.task          AS task,
                       a.context       AS context,
                       a.deadline      AS deadline,
                       a.status        AS status
                FROM action_items a
                JOIN meetings m ON m.id = a.meeting_id
                ORDER BY m.date DESC, a.id
                """)
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
                .map { TopicSegment(title: $0.title, bullets: $0.bulletList,
                                    start: $0.startTime, end: $0.endTime) }

            var ozet: Ozet?
            if let summaryRow, !summaryRow.overviewList.isEmpty {
                ozet = Ozet(genelBakis: summaryRow.overviewList,
                            kararlar: summaryRow.decisionList,
                            aksiyonlar: actions.map {
                                Ozet.Aksiyon(kisi: $0.person, gorev: $0.task,
                                             baglam: $0.context ?? "",
                                             sonTarih: $0.deadline ?? "belirtilmedi")
                            })
            }
            return LoadedMeeting(
                meeting: meeting, segments: segments, summary: ozet, topics: topics,
                actions: actions.compactMap { row in
                    row.id.map {
                        MeetingAction(id: $0, person: row.person, task: row.task,
                                      context: row.context, deadline: row.deadline,
                                      isDone: row.status == ActionStatus.done.rawValue)
                    }
                })
        }
    }

    // MARK: - Ses dosyası

    /// Sıkıştırma sonrası uzantı değişir; satır yeni dosyayı göstermeli.
    func setAudioPath(_ meetingID: Int64, path: String?) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE meetings SET audio_path = ? WHERE id = ?",
                           arguments: [path, meetingID])
        }
    }

    struct AudioFile: FetchableRecord, Decodable, Sendable {
        var id: Int64
        var path: String
    }

    /// Sesi diskte duran toplantılar. `before` verilirse yalnızca o tarihten
    /// eski olanlar — saklama süresi dolanları temizlemek için.
    func audioFiles(before date: Date? = nil) async throws -> [AudioFile] {
        try await database.read { db in
            if let date {
                return try AudioFile.fetchAll(db, sql: """
                    SELECT id, audio_path AS path FROM meetings
                    WHERE audio_path IS NOT NULL AND date < ?
                    """, arguments: [date])
            }
            return try AudioFile.fetchAll(db, sql: """
                SELECT id, audio_path AS path FROM meetings WHERE audio_path IS NOT NULL
                """)
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
    /// Model bağlam alanını boş ya da "belirtilmedi" bırakabiliyor; o zaman
    /// satırda ikinci bir satır çizilmesin diye NULL yazılır.
    static func normalizedContext(_ value: String) -> String? {
        let cleaned = Self.cleaned(value)
        return cleaned.isEmpty || Self.isUnspecified(cleaned) ? nil : cleaned
    }

    static func normalizedDeadline(_ value: String) -> String? {
        let cleaned = Self.cleaned(value)
        return cleaned.isEmpty || Self.isUnspecified(cleaned) ? nil : cleaned
    }

    /// Model çıktısının uçlarındaki artıklar: kaçış çizgisi ve boşluk.
    /// Gerçek veride görüldü — "…belirledim.\" (RESEARCH.md §25.2).
    /// **Kelime düşürmez**, yalnızca uçtaki noktalama artığını alır.
    static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\\"))
    }

    /// "belirtilmedi", "Belirtilmedi." ve benzerleri bir değer değildir.
    /// Sondaki noktalama yüzünden eşleşmeyi kaçırmak, arayüzde "Son tarih:
    /// Belirtilmedi." satırı olarak görünüyordu.
    static func isUnspecified(_ value: String) -> Bool {
        let stripped = Self.cleaned(value)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!"))
            .trimmingCharacters(in: .whitespaces)
            .lowercased(with: Locale(identifier: "tr_TR"))
        return stripped.isEmpty || stripped == "belirtilmedi"
    }
}

// MARK: - Takvim bağı ve katılımcılar

extension MeetingStore {

    /// Takvim etkinliğini toplantıya bağlar.
    ///
    /// DB'ye **yalnızca gerekli olan** yazılır: etkinlik kimliği, başlık,
    /// katılımcı adları. `notes`, `location` ve etkinlik gövdesi kopyalanmaz —
    /// orası kullanıcının takviminde kalır.
    func linkCalendarEvent(_ meetingID: Int64, event: MeetingEvent) async throws {
        try await database.write { db in
            try db.execute(sql: """
                UPDATE meetings SET calendar_event_id = ?, title = ? WHERE id = ?
                """, arguments: [event.eventID, event.title, meetingID])

            for name in event.attendees {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                try db.execute(sql: """
                    INSERT INTO participants (name, meeting_count, last_seen)
                    VALUES (?, 0, datetime('now'))
                    ON CONFLICT(name) DO UPDATE SET last_seen = datetime('now')
                    """, arguments: [trimmed])
                guard let participantID = try Int64.fetchOne(
                    db, sql: "SELECT id FROM participants WHERE name = ?", arguments: [trimmed])
                else { continue }
                let role = (event.organizer == trimmed) ? "organizer" : "attendee"
                try db.execute(sql: """
                    INSERT OR IGNORE INTO meeting_participants
                        (meeting_id, participant_id, source, role)
                    VALUES (?, ?, 'calendar', ?)
                    """, arguments: [meetingID, participantID, role])
                try db.execute(sql: """
                    UPDATE participants SET meeting_count =
                        (SELECT COUNT(*) FROM meeting_participants WHERE participant_id = ?)
                    WHERE id = ?
                    """, arguments: [participantID, participantID])
            }
        }
    }

    /// Bir toplantının takvimden gelen katılımcıları.
    func calendarParticipants(_ meetingID: Int64) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT p.name FROM participants p
                JOIN meeting_participants mp ON mp.participant_id = p.id
                WHERE mp.meeting_id = ? AND mp.source = 'calendar'
                ORDER BY p.name
                """, arguments: [meetingID])
        }
    }

    // MARK: - Toplantı sohbeti

    func appendChat(_ meetingID: Int64, question: String, answer: String) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO chat_history (meeting_id, question, answer, timestamp)
                VALUES (?, ?, ?, datetime('now'))
                """, arguments: [meetingID, question, answer])
        }
    }

    struct ChatTurn: Identifiable, Hashable, FetchableRecord, Decodable, Sendable {
        var id: Int64
        var question: String
        var answer: String
    }

    func chatHistory(_ meetingID: Int64) async throws -> [ChatTurn] {
        try await database.read { db in
            try ChatTurn.fetchAll(db, sql: """
                SELECT id, question, answer FROM chat_history
                WHERE meeting_id = ? ORDER BY id
                """, arguments: [meetingID])
        }
    }
}
