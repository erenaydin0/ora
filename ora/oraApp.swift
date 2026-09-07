import SwiftUI
import AppKit

@main
struct OraApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var recorder: RecordingController
    @State private var settings: OraSettings

    /// Dizin hazırlığı ve sandbox göçü **burada** yapılır, `AppDelegate`'te
    /// değil: `RecordingController()` veritabanını açıyor ve `@State`
    /// varsayılanları `applicationDidFinishLaunching`'den önce değerlendiriliyor.
    /// Göç sonra çalışırsa boş bir `ora.sqlite` oluşmuş oluyor ve göç kendini
    /// atlıyor — kullanıcı bütün toplantılarını kaybetmiş görünüyordu.
    init() {
        try? AppPaths.prepare()
        if let bundleID = Bundle.main.bundleIdentifier {
            AppPaths.migrateFromSandboxContainer(bundleID: bundleID)
        }
        _recorder = State(initialValue: RecordingController())
        _settings = State(initialValue: OraSettings.shared)
    }

    var body: some Scene {
        Window("ora", id: "main") {
            RootView(recorder: recorder)
                .tint(Color.oraCarmine)
                .containerBackground(Color.oraPaper, for: .window)
        }
        .defaultSize(width: 1100, height: 700)
        // En küçük boyut **içeriğin** bildirdiği minimumdur. Bu olmadan
        // `NavigationSplitView` + `.inspector` sığmadığında sütunları
        // daraltmak yerine kenar çubuğunu pencerenin dışına taşıyordu
        // (RESEARCH.md §24). Minimum RootView'da, sohbet paneline göre
        // değişken olarak bildirilir.
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)

        // Taşıyıcı yüzey: menü bar. Pencere kapalıyken de kayıt sürdürülebilir.
        MenuBarExtra {
            MenuBarContent(recorder: recorder)
        } label: {
            MenuBarLabel(recorder: recorder)
        }
        // Native menü: seçenekler alt alta, sistem davranışıyla.
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(recorder: recorder, settings: settings)
                .tint(Color.oraCarmine)
                .containerBackground(Color.oraPaper, for: .window)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // BRAND.md tek bir açık palet tanımlar; karanlık mod paleti yoktur.
        NSApp.appearance = NSAppearance(named: .aqua)

        // Girişte başlatıldıysa pencere açılmaz: taşıyıcı yüzey menü bardır
        // ve her oturum açılışında pencereyi yüze fırlatmak kabul edilemez.
        // Sistem tarafından açıldığımızda bu anahtar `false` gelir; kullanıcı
        // uygulamayı kendi açtığında gelmez veya `true` olur.
        let isDefaultLaunch = notification
            .userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if !isDefaultLaunch {
            // Pencere `Window` sahnesiyle bu çağrıdan sonra da kurulabiliyor;
            // kapatma bir sonraki döngüye bırakılır.
            DispatchQueue.main.async {
                for window in NSApp.windows where window.canBecomeMain {
                    window.close()
                }
            }
            Log.info(.app, "Girişte başlatıldı — pencere açılmadı")
        }


        do {
            // Dizinler ve göç `OraApp.init()`'te yapıldı (sıra oradaki yorumda);
            // burada yalnızca doğrulanır.
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
