import Foundation
import GRDB

/// Toplantı verisinin tek kapısı. UI ve Pipeline SQL yazmaz; buradan geçer.
nonisolated struct MeetingStore: Sendable {

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
            // Model çıktısının uçlarındaki artıklar **yazılmadan** kesilir;
            // yoksa her okuyan yerde tekrar temizlemek gerekiyor.
            var summary = SummaryRecord(
                id: nil, meetingId: meetingID,
                overview: try ozet.map {
                    String(data: try encoder.encode($0.genelBakis.map(Self.cleaned)),
                           encoding: .utf8) } ?? nil,
                decisions: try ozet.map {
                    String(data: try encoder.encode($0.kararlar.map(Self.cleaned)),
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
                    id: nil, meetingId: meetingID, title: Self.cleaned(topic.title),
                    bullets: String(data: try encoder.encode(topic.bullets.map(Self.cleaned)),
                                    encoding: .utf8),
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
    func setSpeaker(meetingID: Int64, segment: Segment, speaker: String,
                    learnVoice: Bool = false) async throws {
        try await setSpeaker(meetingID: meetingID, segments: [segment], speaker: speaker,
                             learnVoice: learnVoice)
    }

    /// Kullanıcının **seçtiği** satırların etiketini tek işlemde değiştirir.
    ///
    /// "Satır" ile "o etiketin tümü" arasındaki kapsam: çok kişili toplantıda
    /// karşı taraftaki beş satır Ayşe'nin, üçü Mehmet'indir ve ikisi de
    /// "Katılımcı" etiketini taşır. Satırlar farklı kanallardan gelebilir;
    /// kanal yine değişmez (kural #11), yalnızca etiket. Tek transaction —
    /// yarısı yazılmış bir atama bırakılmaz.
    @discardableResult
    func setSpeaker(meetingID: Int64, segments: [Segment], speaker: String,
                    learnVoice: Bool = false) async throws -> Int {
        try await database.write { db in
            var changed = 0
            for segment in segments {
                try db.execute(sql: """
                    UPDATE transcripts SET speaker = ?
                    WHERE meeting_id = ? AND start_time = ? AND channel = ?
                    """,
                    arguments: [speaker, meetingID, segment.start,
                                segment.channel.databaseValue])
                changed += db.changesCount
            }
            let labels = Set(segments.map(\.speaker))
            try Self.moveActions(db, meetingID: meetingID, from: labels, to: speaker)
            if learnVoice {
                try Self.learnVoice(db, meetingID: meetingID, from: labels, to: speaker)
            }
            return changed
        }
    }

    /// Transkriptten **tamamen kalkan** etiketin aksiyonları yeni ada geçer.
    ///
    /// "Katılımcı 2"nin bütün satırları "Ayşe" olunca ona düşen işler de
    /// Ayşe'nindir — yeniden özetlemek gerekmez, işaretli aksiyonlar da
    /// korunur. Etiketin bir tek satırı bile kaldıysa dokunulmaz: o durumda
    /// aksiyonun hangi kişiye ait olduğu bilinmiyor. Aynı transaction'da,
    /// transkriptle birlikte yazılır.
    static func moveActions(_ db: Database, meetingID: Int64,
                            from labels: Set<String>, to speaker: String) throws {
        for label in labels where label != speaker {
            let remaining = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcripts WHERE meeting_id = ? AND speaker = ?
                """, arguments: [meetingID, label]) ?? 0
            guard remaining == 0 else { continue }
            try db.execute(sql: """
                UPDATE action_items SET person = ? WHERE meeting_id = ? AND person = ?
                """, arguments: [speaker, meetingID, label])
        }
    }

    /// Aynı kanalda **aynı etiketi taşıyan tüm** satırları yeniden adlandırır.
    ///
    /// Birebir görüşmede karşı taraf tek kişidir; 40 satırı tek tek
    /// adlandırmak kullanılabilir bir iş değil. Kapsam kanalla sınırlıdır:
    /// kanal fiziksel gerçektir (kural #11), yeniden adlandırılan yalnızca
    /// **etikettir**.
    @discardableResult
    func setSpeaker(meetingID: Int64, channel: Channel,
                    from label: String, to speaker: String,
                    learnVoice: Bool = false) async throws -> Int {
        try await database.write { db in
            try db.execute(sql: """
                UPDATE transcripts SET speaker = ?
                WHERE meeting_id = ? AND channel = ? AND speaker = ?
                """,
                arguments: [speaker, meetingID, channel.databaseValue, label])
            let changed = db.changesCount
            try Self.moveActions(db, meetingID: meetingID, from: [label], to: speaker)
            if learnVoice {
                try Self.learnVoice(db, meetingID: meetingID, from: [label], to: speaker)
            }
            return changed
        }
    }

    // MARK: - Cihazdan çıkmasın (Bağlantı Kuralları §6)

    func setLocalOnly(_ meetingID: Int64, _ localOnly: Bool) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE meetings SET local_only = ? WHERE id = ?",
                           arguments: [localOnly, meetingID])
        }
    }

    // MARK: - Şablon (COMPETITION.md §4.7)

    func setTemplate(_ meetingID: Int64, _ template: MeetingTemplate) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE meetings SET template = ? WHERE id = ?",
                           arguments: [template.rawValue, meetingID])
        }
    }

    func isLocalOnly(_ meetingID: Int64) async throws -> Bool {
        try await database.read { db in
            try Bool.fetchOne(db, sql: "SELECT local_only FROM meetings WHERE id = ?",
                              arguments: [meetingID]) ?? false
        }
    }

    /// Kanal etiketi mi, gerçek bir kişi adı mı?
    ///
    /// `Ben` ve `Katılımcı` kanalın adıdır, kişi değil: katılımcı olarak
    /// yazılmaz ve sözlüğe beslenmezler. `Bilinmeyen` şemanın varsayılanıdır.
    /// Diarization'ın numaralı kümeleri ("Katılımcı 2") da kişi değildir —
    /// kullanıcı adlandırana kadar etikettir.
    /// Karşılaştırma Türkçe locale ile yapılır — `I`/`İ` ayrımı.
    nonisolated static func isChannelLabel(_ name: String) -> Bool {
        var key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))
        guard !key.isEmpty else { return true }
        // "katılımcı 2" → "katılımcı"
        if let space = key.lastIndex(of: " "),
           !key[key.index(after: space)...].isEmpty,
           key[key.index(after: space)...].allSatisfy(\.isNumber) {
            key = String(key[..<space])
        }
        let labels = Channel.allCases.map {
            $0.speaker.lowercased(with: Locale(identifier: "tr_TR"))
        } + ["bilinmeyen"]
        return labels.contains(key)
    }

    // MARK: - Okuma

    /// Toplantı listesi. `search` boşsa tümü; doluysa başlık **ve** FTS5 transkript
    /// araması birleştirilir.
    ///
    /// `tag` verilirse yalnızca o etiketi taşıyan toplantılar (§4.16).
    func list(search: String = "", tag: String? = nil) async throws -> [MeetingListItem] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await database.read { db in
            var clauses: [String] = []
            var arguments: StatementArguments = []
            if !term.isEmpty {
                clauses.append("""
                    (m.title LIKE ?
                     OR m.id IN (
                         SELECT t.meeting_id FROM transcripts_fts f
                         JOIN transcripts t ON t.id = f.rowid
                         WHERE transcripts_fts MATCH ?))
                    """)
                arguments += ["%\(term)%", Self.ftsPattern(term)]
            }
            if let tag {
                clauses.append("""
                    m.id IN (SELECT mt.meeting_id FROM meeting_tags mt
                             JOIN tags g ON g.id = mt.tag_id WHERE g.name = ?)
                    """)
                arguments += [tag]
            }
            let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            return try MeetingListItem.fetchAll(db, sql: """
                SELECT m.id, m.title, m.date, m.duration, m.status,
                       m.local_only AS localOnly, m.template,
                       (SELECT group_concat(g.name, char(31)) FROM meeting_tags mt
                        JOIN tags g ON g.id = mt.tag_id
                        WHERE mt.meeting_id = m.id) AS tagList
                FROM meetings m
                \(filter)
                ORDER BY m.date DESC
                """, arguments: arguments)
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

    /// `meetings.audio_path` mutlak yazılır; veri dizini değişince (sandbox
    /// göçü) eski konumu gösterir. Dosya yeni `recordings/` altında aynı adla
    /// duruyorsa yol düzeltilir. Idempotent — düzeltilecek bir şey yoksa
    /// hiç yazma yapmaz.
    @discardableResult
    func repairAudioPaths() async throws -> Int {
        let files = try await audioFiles()
        let home = AppPaths.recordings.path(percentEncoded: false)
        var repaired: [(Int64, String)] = []
        // Ölçüt "dosya kayıp mı" **değil**, "yol güncel veri dizininde mi":
        // göç kopyalayarak yapıldığı için eski yol da açılmaya devam ediyor ve
        // uygulama sessizce konteynerdeki dosyayı kullanmaya devam ederdi.
        for file in files where !file.path.hasPrefix(home) {
            let name = URL(fileURLWithPath: file.path).lastPathComponent
            let candidate = AppPaths.recordings.appending(path: name, directoryHint: .notDirectory)
            let path = candidate.path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: path) { repaired.append((file.id, path)) }
        }
        guard !repaired.isEmpty else { return 0 }
        let updates = repaired
        try await database.write { db in
            for (id, path) in updates {
                try db.execute(sql: "UPDATE meetings SET audio_path = ? WHERE id = ?",
                               arguments: [path, id])
            }
        }
        Log.info(.store, "\(repaired.count) kaydın ses yolu yeni veri dizinine göre düzeltildi")
        return repaired.count
    }

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
            try Self.dropUnusedTags(db)
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

nonisolated extension MeetingStore {

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
            // Etkinlik adından şablon **önerisi** ("1:1", "sprint", "mülakat").
            // Yalnızca şablon hâlâ Genel'ken: kullanıcının seçimi ezilmez.
            if let guess = MeetingTemplate.guess(from: event.title) {
                try db.execute(sql: """
                    UPDATE meetings SET template = ?
                    WHERE id = ? AND (template IS NULL OR template = 'general')
                    """, arguments: [guess.rawValue, meetingID])
            }

            for name in event.attendees {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let role = (event.organizer == trimmed) ? "organizer" : "attendee"
                guard let participantID = try Self.upsertParticipant(
                    db, name: trimmed, meetingID: meetingID,
                    source: "calendar", role: role) else { continue }
                try Self.recountMeetings(db, participantID: participantID)
            }
        }
    }

    /// Takvim bağını **değiştirir**: eski takvim katılımcıları silinir, yenisi
    /// yazılır. Çakışan toplantılarda yanlış etkinlik bağlandıysa kullanıcı
    /// bunu sonradan düzeltebilmeli — yoksa yanlış katılımcı listesi kayıtta
    /// kalıcı olur.
    ///
    /// `source = 'transcript'` satırlarına dokunulmaz: onlar konuşmadan
    /// çıkarılmıştır, takvim seçiminden bağımsızdır.
    func relinkCalendarEvent(_ meetingID: Int64, event: MeetingEvent) async throws {
        try await unlinkCalendarEvent(meetingID)
        try await linkCalendarEvent(meetingID, event: event)
    }

    /// Takvim bağını kaldırır (başlık korunur — kullanıcı elle değiştirmiş olabilir).
    func unlinkCalendarEvent(_ meetingID: Int64) async throws {
        try await database.write { db in
            let ids = try Int64.fetchAll(db, sql: """
                SELECT participant_id FROM meeting_participants
                WHERE meeting_id = ? AND source = 'calendar'
                """, arguments: [meetingID])
            try db.execute(sql: """
                DELETE FROM meeting_participants WHERE meeting_id = ? AND source = 'calendar'
                """, arguments: [meetingID])
            try db.execute(sql: "UPDATE meetings SET calendar_event_id = NULL WHERE id = ?",
                           arguments: [meetingID])
            // Sayaç yeniden hesaplanır; kişinin kendisi silinmez, başka
            // toplantılarda görünmeye devam edebilir.
            for participantID in ids {
                try Self.recountMeetings(db, participantID: participantID)
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

    /// Transkriptte **adlandırılmış** konuşmacılar (`source = 'transcript'`).
    ///
    /// Takvim katılımcılarından ayrı tutulur: biri toplantıya davet
    /// edilenler, öteki gerçekten konuşup adı verilenler. Ad hem takvimde hem
    /// transkriptte varsa satır takvimin kalır (`meeting_participants`
    /// anahtarı toplantı + kişi) — kişi zaten listede olduğu için kayıp yok.
    func transcriptParticipants(_ meetingID: Int64) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT p.name FROM participants p
                JOIN meeting_participants mp ON mp.participant_id = p.id
                WHERE mp.meeting_id = ? AND mp.source = 'transcript'
                ORDER BY p.name
                """, arguments: [meetingID])
        }
    }

    /// Adlandırma menüsünün adayları: en çok görülen kişiler.
    ///
    /// Başka toplantılardan gelir — haftalık aynı ekiple yapılan toplantıda
    /// adlandırmayı tek tıka indirir. Tahmin değil **öneri**: atamayı yine
    /// kullanıcı yapar.
    func knownParticipants(limit: Int = 8) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM participants
                ORDER BY meeting_count DESC, last_seen DESC, name COLLATE NOCASE
                LIMIT ?
                """, arguments: [limit])
        }
    }

    /// Transkriptteki kişi adlarını `meeting_participants(source = 'transcript')`
    /// ile **eşitler**.
    ///
    /// Ekleme değil eşitleme: kullanıcı bir atamayı geri aldığında satır da
    /// düşer. Yoksa yanlış atama kayıtta kalıcı olurdu — oysa bu özelliğin
    /// tamamı "sonradan düzeltilebilsin" diye var. Takvimden gelen
    /// (`source = 'calendar'`) satırlara **dokunulmaz**.
    @discardableResult
    func syncTranscriptParticipants(_ meetingID: Int64) async throws -> [String] {
        try await database.write { db in
            let wanted = Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT speaker FROM transcripts WHERE meeting_id = ?
                """, arguments: [meetingID])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !Self.isChannelLabel($0) })

            var touched: Set<Int64> = []
            let existing = try Row.fetchAll(db, sql: """
                SELECT mp.participant_id AS id, p.name AS name
                FROM meeting_participants mp
                JOIN participants p ON p.id = mp.participant_id
                WHERE mp.meeting_id = ? AND mp.source = 'transcript'
                """, arguments: [meetingID])

            for row in existing {
                let participantID: Int64 = row["id"]
                let name: String = row["name"]
                guard !wanted.contains(name) else { continue }
                try db.execute(sql: """
                    DELETE FROM meeting_participants
                    WHERE meeting_id = ? AND participant_id = ? AND source = 'transcript'
                    """, arguments: [meetingID, participantID])
                touched.insert(participantID)
            }

            for name in wanted {
                guard let participantID = try Self.upsertParticipant(
                    db, name: name, meetingID: meetingID,
                    source: "transcript", role: nil) else { continue }
                touched.insert(participantID)
            }

            for participantID in touched {
                try Self.recountMeetings(db, participantID: participantID)
            }
            return wanted.sorted()
        }
    }

    /// `participants` satırını açar ya da tazeler ve toplantıya bağlar.
    /// Takvim bağı ile transkript eşitlemesi **aynı yolu** kullanır.
    fileprivate static func upsertParticipant(_ db: Database, name: String,
                                              meetingID: Int64,
                                              source: String,
                                              role: String?) throws -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        try db.execute(sql: """
            INSERT INTO participants (name, meeting_count, last_seen)
            VALUES (?, 0, datetime('now'))
            ON CONFLICT(name) DO UPDATE SET last_seen = datetime('now')
            """, arguments: [trimmed])
        guard let participantID = try Int64.fetchOne(
            db, sql: "SELECT id FROM participants WHERE name = ?", arguments: [trimmed])
        else { return nil }
        try db.execute(sql: """
            INSERT OR IGNORE INTO meeting_participants
                (meeting_id, participant_id, source, role)
            VALUES (?, ?, ?, ?)
            """, arguments: [meetingID, participantID, source, role])
        return participantID
    }

    /// Kişinin toplantı sayacını yeniden hesaplar. Kişinin kendisi silinmez —
    /// başka toplantılarda görünmeye devam edebilir.
    fileprivate static func recountMeetings(_ db: Database,
                                            participantID: Int64) throws {
        try db.execute(sql: """
            UPDATE participants SET meeting_count =
                (SELECT COUNT(*) FROM meeting_participants WHERE participant_id = ?)
            WHERE id = ?
            """, arguments: [participantID, participantID])
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
