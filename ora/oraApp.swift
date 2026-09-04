import SwiftUI
import AppKit

@main
struct OraApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var recorder = RecordingController()
    @State private var settings = OraSettings.shared

    var body: some Scene {
        Window("ora", id: "main") {
            RootView(recorder: recorder)
                .frame(minWidth: 900, minHeight: 560)
                .background(Color.oraPaper)
        }
        .defaultSize(width: 1100, height: 700)
        .windowToolbarStyle(.unified)

        // Taşıyıcı yüzey: menü bar. Pencere kapalıyken de kayıt sürdürülebilir.
        MenuBarExtra {
            MenuBarContent(recorder: recorder)
        } label: {
            MenuBarLabel(recorder: recorder)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(recorder: recorder, settings: settings)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // BRAND.md tek bir açık palet tanımlar; karanlık mod paleti yoktur.
        NSApp.appearance = NSAppearance(named: .aqua)

        do {
            try AppPaths.prepare()
            Log.info(.app, "ora başladı — veri dizini: \(AppPaths.base.path(percentEncoded: false))")
        } catch {
            Log.error(.app, "Uygulama veri dizini oluşturulamadı", error)
            presentFatal(
                message: "ora verilerini saklayamıyor",
                detail: "Uygulama Destek klasörü oluşturulamadı. Disk izinlerini kontrol edin.\n\n\(error.localizedDescription)"
            )
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Taşıyıcı yüzey menü bardır (DESIGN.md §2): pencere kapansa da kayıt
        // sürebilmeli ve algılama çalışmaya devam etmeli.
        false
    }

    /// Kullanıcıya Türkçe hata — sessiz çökme yasak (CLAUDE.md "Hata Yönetimi").
    private func presentFatal(message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Tamam")
        alert.runModal()
    }
}
