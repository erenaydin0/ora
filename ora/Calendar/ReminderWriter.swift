import Foundation
import EventKit

/// Aksiyonları Hatırlatıcılar'a ekleyen yazıcı (COMPETITION.md §4.12).
///
/// **Takvime yazma yasağından ayrıdır:** ora takvime asla yazmaz; bu,
/// kullanıcının tek tek seçtiği aksiyonları **ayrı bir "ora" listesine**
/// ekler. Opt-in'dir ve kendi iznini ister (`NSRemindersFullAccessUsageDescription`).
/// Hatırlatıcılar iCloud ile eşitleniyorsa eklenen madde de eşitlenir; bu
/// yüzden "cihazdan çıkmasın" işaretli toplantının aksiyonu eklenmez.
nonisolated protocol ReminderWriting: Sendable {
    /// İzin verildi mi; ilk çağrıda istenir.
    func authorize() async -> Bool
    /// Hatırlatıcıyı ekler ve kimliğini döndürür.
    func add(title: String, notes: String) async throws -> String
}

nonisolated final class EventKitReminders: ReminderWriting, @unchecked Sendable {

    /// ora'nın listesi. Kullanıcının diğer listelerine dokunulmaz.
    static let listTitle = "ora"

    private let lock = NSLock()
    private var cachedStore: EKEventStore?

    /// Store yalnızca özellik kullanılınca kurulur — kapalıyken EventKit'e
    /// hiç dokunulmaz (takvim kuralıyla aynı ilke).
    private var store: EKEventStore {
        lock.withLock {
            if let cachedStore { return cachedStore }
            let store = EKEventStore()
            cachedStore = store
            return store
        }
    }

    func authorize() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return true
        case .notDetermined:
            do {
                return try await store.requestFullAccessToReminders()
            } catch {
                Log.error(.calendar, "Hatırlatıcılar izni istenemedi", error)
                return false
            }
        default:
            return false
        }
    }

    func add(title: String, notes: String) async throws -> String {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw OraError.permissionDenied(.reminders)
        }
        let store = self.store
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = try list(in: store)
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    /// "ora" listesi yoksa yeni hatırlatıcıların varsayılan hesabında açılır.
    private func list(in store: EKEventStore) throws -> EKCalendar {
        if let existing = store.calendars(for: .reminder)
            .first(where: { $0.title == Self.listTitle }) {
            return existing
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = Self.listTitle
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw OraError.permissionDenied(.reminders)
        }
        list.source = source
        try store.saveCalendar(list, commit: true)
        Log.info(.calendar, "Hatırlatıcılar'da \"\(Self.listTitle)\" listesi açıldı")
        return list
    }

    /// Hatırlatıcının metni: iş başlıkta; gerekçe, kaynak toplantı ve son
    /// tarih notta. Son tarih serbest Türkçe metindir ("Cuma") — tarih
    /// alanına **çevrilmez**, yanlış güne kurulmuş bir hatırlatıcı hiç
    /// kurulmamış olandan kötüdür.
    static func notes(context: String?, meetingTitle: String, meetingDate: Date,
                      person: String, deadline: String?) -> String {
        var lines: [String] = []
        if let context, !MeetingStore.isUnspecified(context) {
            lines.append(MeetingStore.cleaned(context))
        }
        if !MeetingStore.isUnspecified(person) {
            lines.append("Sorumlu: \(MeetingStore.cleaned(person))")
        }
        if let deadline, !MeetingStore.isUnspecified(deadline) {
            lines.append("Son tarih: \(MeetingStore.cleaned(deadline))")
        }
        lines.append("Toplantı: \(meetingTitle) — "
                     + meetingDate.formatted(date: .abbreviated, time: .shortened))
        return lines.joined(separator: "\n")
    }
}
