import Foundation
import AppKit
import CoreAudio

/// Bilinen toplantı uygulamaları.
///
/// Eşleşme **tam bundle ID** karşılaştırmasıdır — alt-dize eşleşmesi yapılmaz
/// (eski ora'da `if app not in output` Slack Helper süreçlerinde bile tutuyordu).
nonisolated enum MeetingApps {

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

    /// Ses kullanan bir sürecin bundle ID'sini bilinen toplantı uygulamasına
    /// çözer; bilinmiyorsa `nil`.
    ///
    /// **Neden gerekli:** Electron/WebView tabanlı uygulamalarda mikrofonu ana
    /// süreç değil **yardımcı süreç** tutar (Teams'te `com.microsoft.teams2`
    /// yerine onun yardımcısı). Tam eşitlik arayan algılama bu yüzden Teams
    /// toplantısını hiç görmüyordu — aynı bulgu tarayıcılar için RESEARCH.md
    /// §13.3'te ölçülmüştü, Electron için "ölçülmedi" notu düşülmüştü.
    ///
    /// Nokta sınırı şart: alt-dize eşleşmesi değil, **ön ek + `.`**. Böylece
    /// `com.microsoft.teams2` kimliği `com.microsoft.teams` kuralına takılmaz.
    /// CLAUDE.md'deki "alt-dize eşleşmesi kullanma" kuralının gerekçesi
    /// "uygulama açık" testiydi; burada test "mikrofonu **tutuyor**" olduğu için
    /// yardımcı sürecin sayılması doğrudur.
    static func resolve(_ bundleID: String) -> String? {
        if all.contains(bundleID) { return bundleID }
        return all.first { bundleID.hasPrefix($0 + ".") }
    }

    /// Tap'in hedefleyeceği bundle ID'ler — **yardımcı süreçler dahil**.
    /// Boş dönerse çağıran global tap'e düşer.
    ///
    /// Liste `NSWorkspace`'ten değil **CoreAudio süreç listesinden** toplanır.
    /// Ölçüldü (RESEARCH.md §28.3): Teams toplantısında sesi ana süreç değil
    /// `com.microsoft.teams2.helper` ve `com.microsoft.teams2.modulehost`
    /// üretiyor; `com.microsoft.teams2`'yi hedefleyen tap **sessizlik**
    /// yakalıyordu ve kayıt ancak 3 saniyelik gözcü global tap'e düştükten
    /// sonra ses görüyordu — yani "yalnızca toplantı uygulamasını yakala"
    /// kazancı Teams'te hiç gerçekleşmiyordu.
    ///
    /// - Parameter app: yalnızca bu uygulama (ve yardımcıları) hedeflensin.
    ///   `nil` ise çalışan tüm yerel toplantı uygulamaları.
    static func tapTargets(preferring app: String? = nil) -> [String] {
        let wanted: Set<String> = app.map { [$0] } ?? native
        var targets: Set<String> = []

        // Ses üreten süreçler — yardımcı süreçler yalnızca burada görünür.
        if let processes = try? AudioHardwareSystem.shared.processes {
            for process in processes {
                guard let bundleID = (try? process.bundleID) ?? nil,
                      let parent = resolve(bundleID), wanted.contains(parent) else { continue }
                targets.insert(bundleID)
            }
        }

        // Ana uygulama da listeye girer: yardımcı süreç toplantı başlarken
        // doğabilir ve bazı uygulamalarda sesi ana süreç üretir.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        targets.formUnion(running.intersection(wanted).intersection(native))
        return targets.sorted()
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
