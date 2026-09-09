import Foundation
import ServiceManagement

/// "Başlangıçta çalıştır" — ora'yı oturum açılışında menü barda başlatır.
///
/// **Tek gerçek kaynak sistemdir** (`SMAppService.mainApp.status`); UserDefaults'a
/// kopya tutulmaz. Kullanıcı Sistem Ayarları → Genel → Giriş Öğeleri'nden
/// kaydı kaldırdığında bizim kopyamız "açık" kalır ve ayar penceresi yalan
/// söylerdi. `OraSettings` bu yüzden bu ayarı taşımaz.
///
/// Yardımcı bir launchd plist'i **yoktur**: `SMAppService.mainApp` uygulamanın
/// kendisini giriş öğesi yapar, ek hedef ve ek imza gerektirmez.
enum LoginItem {

    /// Uygulama giriş öğesi olarak kayıtlı ve etkin mi.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Kayıt yapıldı ama kullanıcı Sistem Ayarları'nda henüz onaylamadı.
    /// Sessizce "açık" gösterilemez — bu durumda uygulama girişte başlamaz.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Girişte başlatmayı aç/kapat. Hata **yukarı verilir**; çağıran Türkçe
    /// olarak gösterir (CLAUDE.md "Hata Yönetimi").
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            // Zaten kayıtlıysa `register()` hata veriyor; durum kontrolü ucuz.
            guard service.status != .enabled else { return }
            try service.register()
            Log.info(.app, "Girişte başlatma açıldı — durum: \(describe(service.status))")
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
            Log.info(.app, "Girişte başlatma kapatıldı")
        }
    }

    /// Onay bekleyen kayıt için kullanıcıyı doğru panele götürür.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Kullanıcıya gösterilecek Türkçe hata metni.
    static func turkishMessage(for error: Error) -> String {
        "Girişte başlatma ayarlanamadı. Sistem Ayarları → Genel → Giriş Öğeleri'nden "
        + "ora'yı elle ekleyebilirsiniz. (\(error.localizedDescription))"
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:    "kayıtlı değil"
        case .enabled:          "etkin"
        case .requiresApproval: "onay bekliyor"
        case .notFound:         "bulunamadı"
        @unknown default:       "bilinmiyor"
        }
    }
}
