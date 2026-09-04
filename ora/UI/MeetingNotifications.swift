import Foundation
import UserNotifications

/// Toplantı algılandığında eylemli bildirim.
///
/// Ayrı bir sistem popup penceresi **açılmaz** (DESIGN.md §1): odağı çalar,
/// Odak/Rahatsız Etmeyin modlarını dinlemez ve toplantıya girerken ekranın
/// ortasında belirir. Bildirim aynı işi native yapar.
@MainActor
final class MeetingNotifications: NSObject {

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

    private var isAuthorized = false

    func prepare() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.warning(.ui, "Bildirim izni alınamadı: \(error.localizedDescription)")
            isAuthorized = false
            return
        }
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
