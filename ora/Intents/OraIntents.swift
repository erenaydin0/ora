import AppIntents
import Foundation

/// Kısayollar ve Spotlight'tan çağrılan eylemler (COMPETITION.md §4.12).
/// Sıfır bağımlılık, ek izin yok, ağ yok — tamamen Apple yerel.
///
/// Eylemler uygulamanın **kendi denetleyicisini** kullanır; ikinci bir
/// veritabanı bağlantısı ya da ikinci bir kayıt yolu açılmaz. Uygulama
/// kilitliyken içerik döndüren eylem içerik vermez (kilit arayüzü örter,
/// Kısayollar da bir arayüzdür); kayıt denetimi kilitliyken de çalışır.
@MainActor
enum IntentBridge {
    static weak var controller: RecordingController?
    static weak var lock: AppLock?

    static func require() throws -> RecordingController {
        guard let controller else { throw IntentFailure.notReady }
        return controller
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notReady

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "ora henüz hazır değil. Uygulamayı açıp tekrar deneyin."
        }
    }
}

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Kaydı başlat"
    static let description = IntentDescription("ora ile toplantı kaydını başlatır.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try IntentBridge.require()
        if controller.isRecording { return .result(dialog: "Kayıt zaten sürüyor.") }
        await controller.start()
        return .result(dialog: controller.isRecording ? "Kayıt başladı." : "Kayıt başlatılamadı.")
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Kaydı durdur"
    static let description = IntentDescription("Süren kaydı bitirir; özet kayıttan sonra hazırlanır.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try IntentBridge.require()
        guard controller.isRecording else { return .result(dialog: "Süren bir kayıt yok.") }
        // Kayıt sonrası hat dakikalar sürebilir; eylem onu beklemez.
        Task { await controller.stop() }
        return .result(dialog: "Kayıt durduruluyor. Özet hazır olunca haber veririm.")
    }
}

struct MarkMomentIntent: AppIntent {
    static let title: LocalizedStringResource = "Önemli anı işaretle"
    static let description = IntentDescription("Süren kayıtta bu anı önemli olarak işaretler.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try IntentBridge.require()
        guard controller.isRecording else { return .result(dialog: "Süren bir kayıt yok.") }
        await controller.markMoment()
        return .result(dialog: "İşaretlendi.")
    }
}

struct LastMeetingSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Son toplantının özeti"
    static let description = IntentDescription(
        "Özeti hazır olan son toplantının genel bakışını ve açık aksiyon sayısını verir.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let controller = try IntentBridge.require()
        if IntentBridge.lock?.isLocked == true {
            let text = "ora kilitli. Özeti görmek için uygulamanın kilidini açın."
            return .result(value: text, dialog: IntentDialog(stringLiteral: text))
        }
        let text = await controller.lastMeetingSummary()
            ?? "Özeti hazır bir toplantı yok."
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct OraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["\(.applicationName) ile kaydı başlat",
                              "\(.applicationName) kaydı başlat"],
                    shortTitle: "Kaydı başlat", systemImageName: "record.circle")
        AppShortcut(intent: StopRecordingIntent(),
                    phrases: ["\(.applicationName) kaydı durdur"],
                    shortTitle: "Kaydı durdur", systemImageName: "stop.circle")
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["\(.applicationName) önemli anı işaretle"],
                    shortTitle: "Önemli an", systemImageName: "flag")
        AppShortcut(intent: LastMeetingSummaryIntent(),
                    phrases: ["\(.applicationName) son toplantının özeti",
                              "\(.applicationName) son toplantıda ne konuşuldu"],
                    shortTitle: "Son özet", systemImageName: "list.bullet.rectangle")
    }
}
