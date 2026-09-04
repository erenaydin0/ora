import Foundation
import AppKit

/// Bilinen toplantı uygulamaları.
///
/// Eşleşme **tam bundle ID** karşılaştırmasıdır — alt-dize eşleşmesi yapılmaz
/// (eski ora'da `if app not in output` Slack Helper süreçlerinde bile tutuyordu).
enum MeetingApps {

    /// Tap'in hedefleyebileceği yerel toplantı uygulamaları.
    static let native: Set<String> = [
        "com.microsoft.teams2",          // Teams (yeni)
        "com.microsoft.teams",           // Teams (klasik)
        "com.microsoft.SkypeForBusiness",
        "us.zoom.xos",                   // Zoom
        "com.tinyspeck.slackmacgap",     // Slack
        "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager",
        "com.hnc.Discord",
        "com.apple.FaceTime",
    ]

    /// Tarayıcılar **tap hedefi olarak kullanılmaz.**
    ///
    /// Ölçüldü: tarayıcı sesi ana uygulamadan değil ayrı bir yardımcı süreçten
    /// çıkıyor — Safari'de `com.apple.WebKit.GPU`, Chrome'da renderer/GPU
    /// yardımcıları. `com.apple.Safari` bundle ID'sini hedefleyen bir tap
    /// **sessizlik** yakalar. Tarayıcı toplantıları (Chrome'da Google Meet)
    /// bu yüzden doğrudan global tap'e gider.
    static let browsers: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "company.thebrowser.Browser",
    ]

    /// Algılama ve tap kapsamı için bilinen tüm uygulamalar.
    static var all: Set<String> { native.union(browsers) }

    /// Tap'in hedefleyeceği, şu anda çalışan yerel toplantı uygulamaları.
    /// Boş dönerse çağıran global tap'e düşer.
    static func tapTargets() -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return running.intersection(native).sorted()
    }

    /// Çalışan tarayıcılar — yalnızca kullanıcıya durum anlatmak için.
    static func runningBrowsers() -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return running.intersection(browsers).sorted()
    }

    /// Bundle ID → kullanıcıya gösterilecek ad.
    static func displayName(_ bundleID: String) -> String {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .localizedName ?? bundleID
    }
}
