import Foundation
import GRDB

/// Kişi sayfası ve toplantı brifingi (COMPETITION.md §4.11). **LLM'siz**:
/// yalnızca `meeting_participants`, `action_items` ve `summaries` okunur;
/// yeni tablo yok.
nonisolated extension MeetingStore {

    /// Kişiler listesinin satırı.
    struct Person: Identifiable, Hashable, FetchableRecord, Decodable, Sendable {
        var name: String
        var meetingCount: Int
        /// Kişiyle yapılan son toplantının tarihi.
        var lastMeeting: Date?
        var id: String { name }
    }

    /// Kişi sayfasının içeriği.
    struct PersonDetail: Sendable, Equatable {
        struct MeetingRef: Identifiable, Hashable, FetchableRecord, Decodable, Sendable {
            var id: Int64
            var title: String
            var date: Date
        }
        struct Decisions: Sendable, Equatable {
            var meeting: MeetingRef
            var items: [String]
        }
        let name: String
        let meetings: [MeetingRef]
        /// Kişiye düşen, henüz tamamlanmamış aksiyonlar (toplantılar arası).
        let openActions: [BoardAction]
        let doneCount: Int
        /// Kişiyle yapılan ve kararı olan son toplantının kararları.
        let lastDecisions: Decisions?
    }

    /// Yaklaşan toplantı için: aynı katılımcılarla yapılan son toplantı.
    struct Brief: Sendable, Equatable {
        let meetingID: Int64
        let title: String
        let date: Date
        let openActions: Int
        let decisions: Int

        /// "Son ortak toplantı 12 Ağu — 3 açık aksiyon, 2 karar"
        var line: String {
            let day = date.formatted(.dateTime.day().month(.abbreviated)
                .locale(Locale(identifier: "tr_TR")))
            var parts: [String] = []
            if openActions > 0 { parts.append("\(openActions) açık aksiyon") }
            if decisions > 0 { parts.append("\(decisions) karar") }
            let tail = parts.isEmpty ? "" : " — " + parts.joined(separator: ", ")
            return "Son ortak toplantı \(day)\(tail)"
        }
    }

    /// En az bir toplantıda görülen kişiler, son görüşmeye göre.
    func people() async throws -> [Person] {
        try await database.read { db in
            try Person.fetchAll(db, sql: """
                SELECT p.name AS name, COUNT(DISTINCT mp.meeting_id) AS meetingCount,
                       MAX(m.date) AS lastMeeting
                FROM participants p
                JOIN meeting_participants mp ON mp.participant_id = p.id
                JOIN meetings m ON m.id = mp.meeting_id
                GROUP BY p.id
                ORDER BY MAX(m.date) DESC, p.name COLLATE NOCASE
                """)
        }
    }

    func person(_ name: String) async throws -> PersonDetail {
        let actions = try await allActions().filter { Self.owns(name, $0.person) }
        return try await database.read { db in
            let meetings = try PersonDetail.MeetingRef.fetchAll(db, sql: """
                SELECT DISTINCT m.id AS id, m.title AS title, m.date AS date
                FROM meetings m
                JOIN meeting_participants mp ON mp.meeting_id = m.id
                JOIN participants p ON p.id = mp.participant_id
                WHERE p.name = ?
                ORDER BY m.date DESC
                """, arguments: [name])
            var decisions: PersonDetail.Decisions?
            for meeting in meetings {
                let row = try SummaryRecord.fetchOne(db, sql: """
                    SELECT * FROM summaries WHERE meeting_id = ?
                    """, arguments: [meeting.id])
                if let items = row?.decisionList, !items.isEmpty {
                    decisions = PersonDetail.Decisions(meeting: meeting, items: items)
                    break
                }
            }
            return PersonDetail(name: name, meetings: meetings,
                                openActions: actions.filter { !$0.isDone },
                                doneCount: actions.count { $0.isDone },
                                lastDecisions: decisions)
        }
    }

    /// Aksiyon bu kişinin mi? Tam ad Türkçe küçük harfle eşleşir; eski
    /// satırlarda model yalnızca ilk adı yazmış olabilir ("Merve") — tek
    /// kelimelik sahip, adın ilk kelimesiyle eşleşirse sayılır.
    static func owns(_ name: String, _ person: String) -> Bool {
        let turkish = Locale(identifier: "tr_TR")
        let full = name.trimmingCharacters(in: .whitespaces).lowercased(with: turkish)
        let owner = cleaned(person).lowercased(with: turkish)
        guard !owner.isEmpty, !isUnspecified(owner) else { return false }
        if owner == full { return true }
        let first = full.split(separator: " ").first.map(String.init) ?? full
        return !owner.contains(" ") && owner == first
    }

    /// Yaklaşan toplantının katılımcılarıyla **en çok ortak kişisi olan**
    /// geçmiş toplantı; eşitlikte en yenisi. Ortak kimse yoksa `nil`.
    /// Kullanıcının kendi adı sayılmaz — her toplantıda ortaktır.
    func brief(attendees: [String], excluding own: String = "",
               before date: Date = .now) async throws -> Brief? {
        let turkish = Locale(identifier: "tr_TR")
        let me = own.trimmingCharacters(in: .whitespaces).lowercased(with: turkish)
        let names = Set(attendees.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased(with: turkish) != me })
        guard !names.isEmpty else { return nil }
        return try await database.read { db -> Brief? in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id AS id, m.title AS title, m.date AS date, p.name AS name
                FROM meetings m
                JOIN meeting_participants mp ON mp.meeting_id = m.id
                JOIN participants p ON p.id = mp.participant_id
                WHERE m.date < ?
                """, arguments: [date])
            var shared: [Int64: (title: String, date: Date, count: Int)] = [:]
            for row in rows where names.contains(row["name"] as String) {
                let id: Int64 = row["id"]
                let current = shared[id] ?? (row["title"], row["date"], 0)
                shared[id] = (current.title, current.date, current.count + 1)
            }
            guard let best = shared.max(by: { left, right in
                left.value.count == right.value.count
                    ? left.value.date < right.value.date
                    : left.value.count < right.value.count
            }) else { return nil }
            let open = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM action_items WHERE meeting_id = ? AND status = ?
                """, arguments: [best.key, ActionStatus.pending.rawValue]) ?? 0
            let decisions = try SummaryRecord.fetchOne(db, sql: """
                SELECT * FROM summaries WHERE meeting_id = ?
                """, arguments: [best.key])?.decisionList.count ?? 0
            return Brief(meetingID: best.key, title: best.value.title, date: best.value.date,
                         openActions: open, decisions: decisions)
        }
    }
}
