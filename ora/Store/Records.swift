import Foundation
import GRDB

/// Sütun adları `snake_case`, Swift alanları `camelCase`.
protocol OraRecord: Codable, FetchableRecord, MutablePersistableRecord {}
extension OraRecord {
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
}

/// `meetings` satırı.
struct MeetingRecord: OraRecord, Identifiable, Hashable {
    static let databaseTableName = "meetings"

    enum Status: String, Codable {
        case recording, processing, ready
    }

    var id: Int64?
    var title: String
    var date: Date
    var duration: Int
    var status: String
    var template: String?
    var audioPath: String?
    var calendarEventId: String?
    var createdAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// `transcripts` satırı.
struct TranscriptRecord: OraRecord {
    static let databaseTableName = "transcripts"

    var id: Int64?
    var meetingId: Int64
    var speaker: String
    var channel: String?
    var text: String
    var startTime: Double
    var endTime: Double
    var confidence: Double?
    var createdAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Arayüzün kullandığı tipe çevirir.
    var segment: Segment {
        let channel = Channel.allCases.first { $0.databaseValue == self.channel } ?? .system
        return Segment(channel: channel, speaker: speaker, text: text,
                       start: startTime, end: endTime, confidence: confidence, words: [])
    }
}

/// `action_items` satırı.
struct ActionItemRecord: OraRecord, Identifiable {
    static let databaseTableName = "action_items"

    var id: Int64?
    var meetingId: Int64
    var person: String
    var task: String
    /// Görevin **neden** çıktığı — tek cümle. Maddeyi tek başına anlaşılır
    /// kılan alan budur.
    var context: String?
    var deadline: String?
    var status: String
    var createdAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// `topic_segments` satırı.
struct TopicSegmentRecord: OraRecord {
    static let databaseTableName = "topic_segments"

    var id: Int64?
    var meetingId: Int64
    var title: String
    /// Konunun maddeleri, JSON `[String]`. Eskiden konu yalnızca başlıktı;
    /// gövde üretilip atılıyordu.
    var bullets: String?
    var startTime: Double
    var endTime: Double

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var bulletList: [String] {
        guard let bullets, let data = bullets.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

/// `summaries` satırı. `overview` ve `decisions` JSON metni tutar.
struct SummaryRecord: OraRecord {
    static let databaseTableName = "summaries"

    var id: Int64?
    var meetingId: Int64
    var overview: String?
    var decisions: String?
    var createdAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var decisionList: [String] { Self.list(decisions) ?? [] }

    /// `overview` artık madde listesi. v4 öncesi satırlar düz paragraf tutuyor;
    /// **çözümlenemeyen** metin tek maddelik liste olarak okunur — eski
    /// toplantılar boş görünmesin. Çözümlenip boş çıkan (`[]`) bir liste ise
    /// gerçekten boştur; literal "[]" madde olarak gösterilmez.
    var overviewList: [String] {
        guard let overview, !overview.isEmpty else { return [] }
        return Self.list(overview) ?? [overview]
    }

    /// `nil` = çözümlenemedi (JSON değil), `[]` = çözümlendi ve boş.
    private static func list(_ json: String?) -> [String]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}

/// `corrections` satırı — kullanıcının transkriptte yaptığı düzeltmeler.
/// Faz 6'da vocabulary'yi besleyecek.
struct CorrectionRecord: OraRecord {
    static let databaseTableName = "corrections"

    var id: Int64?
    var mistake: String
    var correct: String
    var meetingId: Int64?
    var createdAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Kenar çubuğu listesinin ihtiyaç duyduğu az sayıda alan.
struct MeetingListItem: Identifiable, Hashable, FetchableRecord, Decodable {
    var id: Int64
    var title: String
    var date: Date
    var duration: Int
    var status: String

    var dateLabel: String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Yalnızca saat — kenar çubuğunda gün bilgisini grup başlığı taşır,
    /// satırda tarihi tekrar etmek gürültü.
    var timeLabel: String {
        date.formatted(date: .omitted, time: .shortened)
    }

    var durationLabel: String {
        duration >= 60 ? "\(duration / 60) dk" : "\(duration) sn"
    }

    /// Kenar çubuğu grubu: bugün, dün, bu hafta, sonra ay.
    var groupLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Bugün" }
        if calendar.isDateInYesterday(date) { return "Dün" }
        if let week = calendar.date(byAdding: .day, value: -7, to: .now), date > week {
            return "Son 7 gün"
        }
        return date.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "tr_TR")))
    }
}

/// Bir toplantının tam hâli.
struct LoadedMeeting: Sendable {
    let meeting: MeetingRecord
    let segments: [Segment]
    let summary: Ozet?
    let topics: [TopicSegment]
    /// Aksiyonlar `summary.aksiyonlar`'dan **ayrı** taşınır: onay kutusu satır
    /// kimliği ister, `Ozet.Aksiyon` ise LLM çıktı tipidir ve id taşımaz.
    let actions: [MeetingAction]
}

/// Arayüzün gördüğü aksiyon: kalıcı kimlik ve tamamlanma durumu ile.
struct MeetingAction: Sendable, Identifiable, Hashable {
    let id: Int64
    var person: String
    var task: String
    var context: String?
    var deadline: String?
    var isDone: Bool
}

/// Aksiyon panosunun satırı: aksiyon **ve** hangi toplantıdan çıktığı.
/// Sütun adları sorguda takma adla verilir (`AS meetingID`); bu tip bir
/// `OraRecord` değil, yalnızca okunan bir görünüm.
struct BoardAction: Identifiable, Hashable, FetchableRecord, Decodable, Sendable {
    var id: Int64
    var meetingID: Int64
    var meetingTitle: String
    var meetingDate: Date
    var person: String
    var task: String
    var context: String?
    var deadline: String?
    var status: String

    var isDone: Bool { status == MeetingStore.ActionStatus.done.rawValue }

    /// Kime düştüğü belli mi? Diarization olmadığı için `kisi` çoğu zaman
    /// "belirtilmedi" gelir; pano bunu gizlemez, ayrı bir grupta gösterir.
    var isAssigned: Bool {
        let trimmed = person.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.lowercased(with: Locale(identifier: "tr_TR")) != "belirtilmedi"
    }

    /// Kullanıcının kendisine mi düşüyor? Özet isteminde "Ben" kaydı tutan
    /// kişidir; kullanıcı ayarlardan adını verdiyse o ad da sayılır.
    func isMine(userName: String) -> Bool {
        let turkish = Locale(identifier: "tr_TR")
        let trimmed = person.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: turkish)
        if trimmed == "ben" { return true }
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: turkish)
        return !name.isEmpty && trimmed == name
    }

    var dateLabel: String {
        meetingDate.formatted(date: .abbreviated, time: .omitted)
    }
}
