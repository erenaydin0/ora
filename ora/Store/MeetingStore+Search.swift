import Foundation
import GRDB

/// Tüm toplantılarda soru için aday bölümler — yerel RAG'ın "R"si
/// (COMPETITION.md §4.10).
///
/// Bağlam penceresi dar (4096/8192 token): 60 toplantıyı taramak mümkün
/// değil. Soru anahtar kelimelere indirgenir, FTS5 ile en ilgili satırlar
/// (BM25) bulunur ve **yalnızca onların çevresi** modele verilir. Arama
/// bir LLM çağrısı değildir; saniyenin altında biter.
nonisolated struct MeetingPassage: Sendable, Equatable, Identifiable {
    let meetingID: Int64
    let title: String
    let date: Date
    let segments: [Segment]

    var id: String { "\(meetingID)-\(segments.first?.start ?? 0)" }
}

nonisolated enum CrossMeetingSearch {

    /// FTS'nin döndüreceği en fazla eşleşme. Çevreleriyle birlikte ~2 parça
    /// eder; soru-cevap map-reduce'u saniyeler içinde biter.
    static let hitLimit = 20
    /// Eşleşen satırın çevresi: konuşma satırın arkasından sürer.
    static let lookBehind: TimeInterval = 20
    static let lookAhead: TimeInterval = 40

    /// Aramaya değmeyen kelimeler: soru kalıpları, bağlaçlar ve "toplantı"
    /// kelimesinin kendisi (her satırda sorulan şeyle ilgisiz eşleşir).
    static let stopWords: Set<String> = [
        "ve", "ile", "bir", "bu", "şu", "da", "de", "ki", "mi", "mı", "mu", "mü",
        "ne", "neler", "nedir", "neydi", "hangi", "nasıl", "neden", "niçin", "kim",
        "kimin", "kime", "zaman", "için", "gibi", "daha", "çok", "en", "ama",
        "fakat", "veya", "ya", "olarak", "olan", "oldu", "var", "yok", "hakkında",
        "konusunda", "toplantı", "toplantıda", "toplantılarda", "toplantılar",
        "toplantının", "konuşuldu", "konuştuk", "konuşulan", "söylendi", "dedi",
        "ben", "biz", "sen", "siz", "bana", "bize", "bizim", "benim", "geçen",
        "son", "tüm", "bütün", "her", "hiç", "mıydı", "miydi", "muydu", "müydü",
    ]

    /// Sorunun anahtar kelimeleri, FTS önek araması için gövdelenmiş:
    /// Türkçe ekler yüzünden "teklifinde" → "teklif", "bütçesi" → "bütçe".
    static func keywords(_ question: String) -> [String] {
        let turkish = Locale(identifier: "tr_TR")
        var seen: Set<String> = []
        return question.lowercased(with: turkish)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 || $0.allSatisfy(\.isNumber) }
            .filter { !stopWords.contains($0) }
            .map(stem)
            .filter { seen.insert($0).inserted }
            .prefix(8)
            .map { $0 }
    }

    /// Kaba gövde: uzun kelimenin ilk ~%65'i (en az 5 harf). Önek araması
    /// olduğu için kısa kalmak kaçırmaktan iyidir.
    static func stem(_ word: String) -> String {
        guard word.count > 5 else { return word }
        return String(word.prefix(max(5, Int(Double(word.count) * 0.65))))
    }

    /// FTS5 sorgusu: kelimelerden **herhangi biri** (BM25 çok eşleşeni öne alır).
    static func pattern(_ keywords: [String]) -> String {
        keywords.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " OR ")
    }
}

nonisolated extension MeetingStore {

    /// Soruyla ilgili bölümler, toplantı başına birleştirilmiş ve
    /// eşleşmenin gücüne göre sıralı.
    func passages(for question: String,
                  limit: Int = CrossMeetingSearch.hitLimit) async throws -> [MeetingPassage] {
        let keywords = CrossMeetingSearch.keywords(question)
        guard !keywords.isEmpty else { return [] }
        let pattern = CrossMeetingSearch.pattern(keywords)
        return try await database.read { db in
            let hits = try Row.fetchAll(db, sql: """
                SELECT t.meeting_id AS meetingID, t.start_time AS start
                FROM transcripts_fts f
                JOIN transcripts t ON t.id = f.rowid
                WHERE transcripts_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [pattern, limit])
            // Toplantı sırası ilk (en güçlü) eşleşmenin sırasıdır.
            var order: [Int64] = []
            var windows: [Int64: [(TimeInterval, TimeInterval)]] = [:]
            for hit in hits {
                let meetingID: Int64 = hit["meetingID"]
                let start: TimeInterval = hit["start"]
                if windows[meetingID] == nil { order.append(meetingID) }
                windows[meetingID, default: []].append(
                    (start - CrossMeetingSearch.lookBehind, start + CrossMeetingSearch.lookAhead))
            }
            var result: [MeetingPassage] = []
            for meetingID in order {
                guard let meeting = try MeetingRecord.fetchOne(
                    db, sql: "SELECT * FROM meetings WHERE id = ?", arguments: [meetingID])
                else { continue }
                let lines = try TranscriptRecord.fetchAll(db, sql: """
                    SELECT * FROM transcripts WHERE meeting_id = ? ORDER BY start_time
                    """, arguments: [meetingID]).map(\.segment)
                let ranges = windows[meetingID] ?? []
                var current: [Segment] = []
                for line in lines where ranges.contains(where: {
                    line.end >= $0.0 && line.start <= $0.1 }) {
                    // Bitişik olmayan satır yeni bölüm açar.
                    if let last = current.last, line.start - last.end > CrossMeetingSearch.lookAhead {
                        result.append(MeetingPassage(meetingID: meetingID, title: meeting.title,
                                                     date: meeting.date, segments: current))
                        current = []
                    }
                    current.append(line)
                }
                if !current.isEmpty {
                    result.append(MeetingPassage(meetingID: meetingID, title: meeting.title,
                                                 date: meeting.date, segments: current))
                }
            }
            return result
        }
    }

    // MARK: - Toplantılar arası sohbet geçmişi

    /// `chat_history.meeting_id` NULL: soru tek bir toplantıya ait değil.
    /// Kaynak toplantılar `sources` sütununda (JSON kimlik listesi).
    func appendCrossChat(question: String, answer: String, sources: [Int64]) async throws {
        let json = String(data: try JSONEncoder().encode(sources), encoding: .utf8)
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO chat_history (meeting_id, question, answer, sources, timestamp)
                VALUES (NULL, ?, ?, ?, datetime('now'))
                """, arguments: [question, answer, json])
        }
    }

    struct CrossTurn: Identifiable, Hashable, Sendable {
        struct Source: Identifiable, Hashable, Sendable {
            let id: Int64
            let title: String
            let date: Date
        }
        let id: Int64
        let question: String
        let answer: String
        /// Silinen toplantı listeden düşer.
        let sources: [Source]
    }

    func crossChatHistory() async throws -> [CrossTurn] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, question, answer, sources FROM chat_history
                WHERE meeting_id IS NULL ORDER BY id
                """)
            return try rows.map { row in
                let json: String? = row["sources"]
                let ids = json.flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode([Int64].self, from: $0) } ?? []
                let sources = try ids.compactMap { id -> CrossTurn.Source? in
                    guard let meeting = try MeetingRecord.fetchOne(
                        db, sql: "SELECT * FROM meetings WHERE id = ?", arguments: [id])
                    else { return nil }
                    return CrossTurn.Source(id: id, title: meeting.title, date: meeting.date)
                }
                return CrossTurn(id: row["id"], question: row["question"],
                                 answer: row["answer"], sources: sources)
            }
        }
    }

    func clearCrossChat() async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM chat_history WHERE meeting_id IS NULL")
        }
    }
}
