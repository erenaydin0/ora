import AppKit
import ApplicationServices

/// Toplantı uygulamasının pencere başlığı.
///
/// Çakışan iki takvim toplantısını ayıran **tek yerel sinyal** budur: başlık
/// toplantının adını taşır (ölçüldü, RESEARCH.md §29 —
/// `"Eren AYDIN ile toplantı | Microsoft Teams"`). Bulut tarafında karşılığı
/// yok: Microsoft Graph "bir toplantıdasın" der, hangisi olduğunu söylemez.
///
/// **İzin:** başkasının penceresini okumak Erişilebilirlik izni ister ve
/// **sandbox'lı uygulamada çalışmaz** — Apple erişilebilirlik API'sini
/// sandbox'ta başka süreçler için kapatıyor; izin istemi hiç çıkmaz ve
/// `AXIsProcessTrusted()` her zaman `false` döner. Bu yüzden `isAvailable`
/// kapalıyken eşleştirme sinyalsiz çalışır: puanlama diğer ipuçlarıyla sürer,
/// belirsizlik kalırsa kullanıcıya sorulur. Ekran kaydı izni **istenmez** —
/// tap mimarisiyle kurtulduğumuz izin odur.
enum WindowTitle {

    /// Erişilebilirlik izni var mı (sandbox'ta her zaman `false`).
    static var isAvailable: Bool { AXIsProcessTrusted() }

    /// Sistem izin istemini gösterir. Sandbox'lı uygulamada istem çıkmaz;
    /// çağıran `isAvailable`'a bakarak kullanıcıya durumu anlatmalıdır.
    @discardableResult
    static func requestPermission() -> Bool {
        // Sabitin kendisi Swift 6'da `nonisolated(unsafe)` değil; anahtarın
        // adı belgelenmiş ve sabittir.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Uygulamanın (ve yardımcı süreçlerinin) açık pencere başlıkları.
    ///
    /// Yardımcı süreçler de taranır: pencereyi Electron uygulamalarında ana
    /// süreç açmayabilir — mikrofon ve sesle aynı hikâye (RESEARCH.md §28.3).
    static func titles(for bundleID: String) -> [String] {
        guard isAvailable else { return [] }
        var found: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier,
                  id == bundleID || id.hasPrefix(bundleID + ".") else { continue }
            found.append(contentsOf: titles(pid: app.processIdentifier))
        }
        return found
    }

    private static func titles(pid: pid_t) -> [String] {
        let element = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString,
                                            &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString,
                                                &title) == .success,
                  let text = title as? String, !text.isEmpty else { return nil }
            return text
        }
    }
}
