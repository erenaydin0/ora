import Foundation
import UserNotifications

/// Önerinin bildirim yüzeyi — `MeetingSuggestions`'ın ihtiyaç duyduğu kadarı.
/// Testte sahtelenir; gerçek tipte `isAuthorized` false olduğu için çağrı
/// sessizce düşüyor ve teslimin olup olmadığı ölçülemiyordu.
protocol SuggestionNotifying: AnyObject {
    var onRecord: ((String) -> Void)? { get set }
    var onDismiss: ((String) -> Void)? { get set }
    var onAlways: ((String) -> Void)? { get set }
    func suggestRecording(_ signal: MeetingSignal, event: MeetingEvent?) async
}

/// Toplantı algılandığında eylemli bildirim.
///
/// Ayrı bir sistem popup penceresi **açılmaz** (DESIGN.md §1): odağı çalar,
/// Odak/Rahatsız Etmeyin modlarını dinlemez ve toplantıya girerken ekranın
/// ortasında belirir. Bildirim aynı işi native yapar.
final class MeetingNotifications: NSObject, SuggestionNotifying {

    enum Action: String {
        case record = "ora.record"
        case dismiss = "ora.dismiss"
        case always = "ora.always"
    }

    private static let categoryID = "ora.meeting.detected"
    private static let readyCategoryID = "ora.meeting.ready"

    var onRecord: ((String) -> Void)?
    var onDismiss: ((String) -> Void)?
    var onAlways: ((String) -> Void)?

    private(set) var isAuthorized = false
    /// İzin alınamadıysa kullanıcıya söylenecek Türkçe not. Sessiz kalmak
    /// yasak: bildirim gelmeyeceğini kullanıcı ancak toplantıyı kaçırınca
    /// anlıyordu.
    private(set) var problem: String?

    /// - Returns: bildirim gönderilebilir mi.
    @discardableResult
    func prepare() async -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Kategoriler izinden **bağımsız** kurulur: kullanıcı izni sonradan
        // verirse eylemli bildirim yeniden başlatma gerektirmesin.
        registerCategories(center)
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
            problem = isAuthorized ? nil
                : "Bildirim izni verilmedi. Öneriler yalnızca ora penceresinde görünür."
        } catch {
            Log.warning(.ui, "Bildirim izni alınamadı: \(error.localizedDescription)")
            isAuthorized = false
            problem = "Bildirim izni alınamadı. Öneriler yalnızca ora penceresinde görünür."
        }
        return isAuthorized
    }

    /// Kullanıcı Sistem Ayarları'ndan izni sonradan açmış olabilir.
    @discardableResult
    func refresh() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        if isAuthorized { problem = nil }
        return isAuthorized
    }

    private func registerCategories(_ center: UNUserNotificationCenter) {
        let record = UNNotificationAction(identifier: Action.record.rawValue,
                                          title: "Kaydet", options: [.foreground])
        let dismiss = UNNotificationAction(identifier: Action.dismiss.rawValue,
                                           title: "Şimdi değil", options: [])
        let always = UNNotificationAction(identifier: Action.always.rawValue,
                                          title: "Bu uygulamayı hep kaydet", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID,
                                   actions: [record, dismiss, always],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.readyCategoryID, actions: [],
                                   intentIdentifiers: []),
        ])
    }

    /// Toplantı algılandı önerisi. Takvim açıksa etkinlik adı ve **katılımcı
    /// sayısı** gösterilir — adlar gösterilmez, omuz üstünden okunabilecek bir
    /// yüzeydir (DESIGN.md §1).
    func suggestRecording(_ signal: MeetingSignal, event: MeetingEvent?) async {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "ora"
        if let event {
            content.body = "\(event.title) · \(event.timeLabel)"
            if !event.attendees.isEmpty {
                content.body += " · \(event.attendees.count) katılımcı"
            }
        } else {
            content.body = signal.turkishTitle
        }
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["bundleID": signal.bundleID]
        await post(content, id: "detected-\(signal.bundleID)")
    }

    /// Özet hazır bildirimi — kullanıcı büyük ihtimalle başka iştedir.
    func summaryReady(title: String) async {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "ora"
        content.body = "\(title) özeti hazır"
        content.categoryIdentifier = Self.readyCategoryID
        await post(content, id: "ready-\(UUID().uuidString)")
    }

    private func post(_ content: UNMutableNotificationContent, id: String) async {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do { try await UNUserNotificationCenter.current().add(request) }
        catch { Log.warning(.ui, "Bildirim gönderilemedi: \(error.localizedDescription)") }
    }
}

extension MeetingNotifications: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let bundleID = response.notification.request.content.userInfo["bundleID"] as? String ?? ""
        let action = Action(rawValue: response.actionIdentifier)
        await MainActor.run {
            switch action {
            case .record:  onRecord?(bundleID)
            case .always:  onAlways?(bundleID)
            case .dismiss: onDismiss?(bundleID)
            case nil:
                // Bildirime tıklandı (eylem seçilmeden) — kayıt başlatılmaz.
                onDismiss?(bundleID)
            }
        }
    }
}
