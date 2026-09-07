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

    /// Organizatör etkinliği iptal etti. Aday havuzundan tamamen çıkarılır.
    let isCancelled: Bool
    /// Kullanıcının bu etkinliğe verdiği yanıt. Çakışan iki toplantıyı
    /// ayırmanın en ucuz sinyali: kabul ettiğim toplantıdayımdır.
    let myStatus: Response
    /// Etkinliği ben düzenledim.
    let organizerIsMe: Bool

    enum Response: Sendable, Equatable {
        case accepted, tentative, pending, declined, unknown
    }

    var id: String { eventID }

    /// Etkinlik bu anda sürüyor mu (tolerans yok — puanlama için).
    func isRunning(at date: Date) -> Bool { date >= start && date <= end }

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

    /// Mikrofon sinyalinin geldiği ana denk gelen etkinlikler — **puanlı**.
    ///
    /// Eskiden başlangıca göre sıralı listeden `.first` alınıyordu; çakışan iki
    /// toplantıda bu **her zaman erken başlayanı** seçiyor ve yanlış toplantıya
    /// katılımcı yazıyordu. Artık adaylar elenir, puanlanır ve karar
    /// çağırana bırakılır: tepe aday açık ara öndeyse bağlanır, değilse
    /// kullanıcıya sorulur (tahmin edilmez).
    ///
    /// - Parameters:
    ///   - app: mikrofonu tutan toplantı uygulamasının bundle ID'si.
    ///   - windowTitles: toplantı uygulamasının pencere başlıkları, okunabiliyorsa.
    ///     En güçlü sinyal budur — başlık toplantının adını taşır.
    func candidates(at date: Date, app: String? = nil,
                    windowTitles: [String] = []) -> [EventMatch] {
        let tolerance: TimeInterval = 10 * 60
        let window = upcoming(from: date.addingTimeInterval(-tolerance - 3600),
                              to: date.addingTimeInterval(tolerance + 3600))
        return window
            .filter { event in
                // İptal edilen etkinlik aday değildir: takvimde durmaya devam
                // ediyor ve erken başladığı için gerçek toplantıyı yeniyordu.
                guard !event.isCancelled else { return false }
                let started = event.start.addingTimeInterval(-tolerance)
                let ended = event.end.addingTimeInterval(tolerance)
                return date >= started && date <= ended
            }
            .map { Self.score($0, at: date, app: app, windowTitles: windowTitles) }
            .sorted { ($0.score, $1.event.start) > ($1.score, $0.event.start) }
    }

    /// Puanlanmış aday. `reasons` yalnızca günlük içindir.
    struct EventMatch: Sendable, Equatable {
        let event: MeetingEvent
        let score: Int
        let reasons: [String]
    }

    /// Tepe aday ikinciyi bu farkla geçiyorsa sormadan bağlanır.
    static let decisiveMargin = 3

    static func score(_ event: MeetingEvent, at date: Date,
                      app: String?, windowTitles: [String]) -> EventMatch {
        var score = 0
        var reasons: [String] = []

        // 1 — Pencere başlığı: toplantının **adını** taşır, en güçlü sinyal.
        if windowTitles.contains(where: { Self.titleMatches($0, event.title) }) {
            score += 6
            reasons.append("pencere başlığı eşleşti")
        }

        // 2 — Uygulama eşleşmesi: Teams daveti ile Zoom davetini ayırır.
        if let app, let expected = event.meetingApp, expected == app {
            score += 3
            reasons.append("toplantı linki \(app)")
        }

        // 3 — Başlangıç yakınlığı: toplantıya başlangıcının birkaç dakika
        // içinde girilir.
        let delta = abs(date.timeIntervalSince(event.start))
        if delta <= 5 * 60 {
            score += 3
            reasons.append("başlangıca \(Int(delta / 60)) dk")
        } else if delta <= 15 * 60 {
            score += 1
        }

        // 4 — Etkinlik şu anda sürüyor mu.
        if event.isRunning(at: date) {
            score += 2
            reasons.append("şu anda sürüyor")
        }

        // 5 — Kendi yanıtım. Reddettiğim toplantı **elenmez**, puanı düşer:
        // insan reddettiği toplantıya sonradan katılabiliyor.
        switch event.myStatus {
        case .accepted:  score += 2; reasons.append("kabul ettim")
        case .tentative: score += 1
        case .declined:  score -= 3; reasons.append("reddetmiştim")
        case .pending, .unknown: break
        }
        if event.organizerIsMe {
            score += 2
            reasons.append("organizatör benim")
        }

        return EventMatch(event: event, score: score, reasons: reasons)
    }

    /// Pencere başlığı ile etkinlik adını karşılaştırır.
    ///
    /// Birebir arama işe yaramaz: başlık "Bordro Görüşmesi | Microsoft Teams"
    /// gibi ek taşır, etkinlik adı da kısaltılmış olabilir. Ölçüt **anlamlı
    /// kelime örtüşmesi**: üç harften uzun kelimelerin en az yarısı tutmalı.
    static func titleMatches(_ windowTitle: String, _ eventTitle: String) -> Bool {
        let strip = { (text: String) -> Set<String> in
            Set(text.lowercased(with: Locale(identifier: "tr_TR"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 })
        }
        // Uygulama adı her başlıkta var, ayırt etmez.
        let noise: Set<String> = ["microsoft", "teams", "zoom", "meeting", "webex",
                                  "slack", "toplantı", "toplanti", "görüşme", "gorusme"]
        let window = strip(windowTitle).subtracting(noise)
        let event = strip(eventTitle).subtracting(noise)
        guard !event.isEmpty, !window.isEmpty else { return false }
        let hits = event.intersection(window).count
        return Double(hits) >= Double(event.count) / 2
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

        let mine = (event.attendees ?? []).first { $0.isCurrentUser }
        let response: MeetingEvent.Response
        switch mine?.participantStatus {
        case .accepted:  response = .accepted
        case .tentative: response = .tentative
        case .pending:   response = .pending
        case .declined:  response = .declined
        default:         response = .unknown
        }

        return MeetingEvent(
            eventID: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "İsimsiz Toplantı",
            start: event.startDate,
            end: event.endDate,
            organizer: event.organizer?.name,
            attendees: people,
            meetingApp: Self.meetingApp(from: event),
            isCancelled: event.status == .canceled,
            myStatus: response,
            organizerIsMe: event.organizer?.isCurrentUser ?? false)
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
