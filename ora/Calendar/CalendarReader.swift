import Foundation
import EventKit

/// Takvimden okunan toplantı. `notes` ve `location` **taşınmaz** — protokol
/// bunları içermediği için DB'ye sızmaları yapısal olarak imkânsızdır.
struct MeetingEvent: Sendable, Identifiable, Equatable {
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    let organizer: String?
    /// Yalnızca `.person` ve `.declined` olmayanlar. Oda ve kaynaklar elenmiştir.
    let attendees: [String]
    /// Hangi uygulamanın tap'leneceğini söylemek için hesaplanır, **saklanmaz**.
    let meetingApp: String?

    var id: String { eventID }

    var timeLabel: String {
        start.formatted(date: .omitted, time: .shortened)
    }
}

/// EventKit köprüsü — **opt-in, varsayılan kapalı.**
///
/// Kapalıyken (`isEnabled == false`) `EKEventStore` hiç örneklenmez ve izin
/// istenmez. ora takvime **asla yazmaz**; okumak için `fullAccess` gerekir
/// (RESEARCH.md §12).
@MainActor
final class CalendarReader {

    private let settings: OraSettings
    private var store: EKEventStore?
    private var changeObserver: NSObjectProtocol?

    /// Takvim değişiklikleri — polling yok.
    let changes: AsyncStream<Void>
    private let changeContinuation: AsyncStream<Void>.Continuation

    init(settings: OraSettings = .shared) {
        self.settings = settings
        (changes, changeContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    var isEnabled: Bool { settings.calendarEnabled }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Yalnızca kullanıcı takvim özelliğini açtığında çağrılır.
    @discardableResult
    func authorize() async throws -> Bool {
        let store = ensureStore()
        do {
            let granted = try await store.requestFullAccessToEvents()
            if granted {
                observeChanges()
                Log.info(.calendar, "Takvim erişimi verildi")
            } else {
                Log.warning(.calendar, "Takvim erişimi reddedildi")
            }
            return granted
        } catch {
            throw OraError.permissionDenied(.calendar)
        }
    }

    /// Kullanıcının seçebileceği takvimler.
    func availableCalendars() -> [(id: String, title: String, source: String)] {
        guard isEnabled, authorizationStatus == .fullAccess else { return [] }
        return ensureStore().calendars(for: .event).map {
            ($0.calendarIdentifier, $0.title, $0.source.title)
        }
    }

    /// Mikrofon sinyalinin geldiği ana denk gelen etkinlik (±10 dk tolerans).
    func event(overlapping date: Date) -> MeetingEvent? {
        let tolerance: TimeInterval = 10 * 60
        return upcoming(from: date.addingTimeInterval(-tolerance - 3600),
                        to: date.addingTimeInterval(tolerance + 3600))
            .first { event in
                let started = event.start.addingTimeInterval(-tolerance)
                let ended = event.end.addingTimeInterval(tolerance)
                return date >= started && date <= ended
            }
    }

    /// Sıradaki toplantılar. Sorgu penceresi dar tutulur; takvim toplu taranmaz.
    func upcoming(within interval: TimeInterval = 24 * 3600) -> [MeetingEvent] {
        let now = Date()
        return upcoming(from: now.addingTimeInterval(-12 * 3600),
                        to: now.addingTimeInterval(interval))
            .filter { $0.end >= now }
    }

    private func upcoming(from: Date, to: Date) -> [MeetingEvent] {
        guard isEnabled, authorizationStatus == .fullAccess else { return [] }
        let store = ensureStore()

        // Kullanıcı hangi takvimlerin dahil olacağını seçer; hiçbiri seçili
        // değilse takvim taranmaz — kişisel takvimi taramaya zorlanmaz.
        let selected = store.calendars(for: .event)
            .filter { settings.selectedCalendarIDs.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: selected)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map(Self.convert)
            .sorted { $0.start < $1.start }
    }

    // MARK: - Uygulama

    private func ensureStore() -> EKEventStore {
        if let store { return store }
        let store = EKEventStore()
        self.store = store
        return store
    }

    private func observeChanges() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                self?.changeContinuation.yield(())
            }
    }

    private static func convert(_ event: EKEvent) -> MeetingEvent {
        // **Katılımcı filtresi zorunlu:** oda ve kaynaklar katılımcı değildir,
        // reddedenler de listeye girmez.
        let people = (event.attendees ?? [])
            .filter { $0.participantType == .person && $0.participantStatus != .declined }
            .compactMap(\.name)

        return MeetingEvent(
            eventID: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "İsimsiz Toplantı",
            start: event.startDate,
            end: event.endDate,
            organizer: event.organizer?.name,
            attendees: people,
            meetingApp: Self.meetingApp(from: event))
    }

    /// Toplantı linkinden hangi uygulamanın tap'leneceğini çıkarır.
    /// Link **saklanmaz**; yalnızca bu karar için okunur.
    private static func meetingApp(from event: EKEvent) -> String? {
        let haystack = [event.url?.absoluteString, event.notes]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        guard !haystack.isEmpty else { return nil }

        if haystack.contains("teams.microsoft.com") { return "com.microsoft.teams2" }
        if haystack.contains("zoom.us") { return "us.zoom.xos" }
        if haystack.contains("webex.com") { return "com.cisco.webexmeetingsapp" }
        if haystack.contains("slack.com/huddle") { return "com.tinyspeck.slackmacgap" }
        // Google Meet tarayıcıda çalışır; tarayıcı tap hedefi değildir
        // (RESEARCH.md §13.3) — global tap'e düşülür.
        return nil
    }
}
