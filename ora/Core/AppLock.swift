import AppKit
import LocalAuthentication
import Observation

/// Cihaz sahibini doğrulayan katman. Testte sahtelenir.
nonisolated protocol DeviceAuthenticating: Sendable {
    /// Touch ID ya da Mac parolasıyla doğrulama bu makinede mümkün mü?
    func canAuthenticate() -> Bool
    /// Doğrulandıysa `true`. Kullanıcı vazgeçerse `LAError` fırlatır.
    func authenticate(reason: String) async throws -> Bool
}

/// `LocalAuthentication` üzerinden gerçek doğrulama.
///
/// Politika `.deviceOwnerAuthentication`: Touch ID varsa onu, yoksa ya da
/// başarısızsa Mac parolasını ister. Touch ID'si olmayan bir Mac'te de kilit
/// çalışır — `.deviceOwnerAuthenticationWithBiometrics` seçilseydi çalışmazdı.
nonisolated struct SystemAuthenticator: DeviceAuthenticating {
    func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String) async throws -> Bool {
        try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                                             localizedReason: reason)
    }
}

/// Uygulama kilidi. **Opt-in, varsayılan kapalı** (`OraSettings.appLockEnabled`).
///
/// **Yalnızca arayüzü örter.** Kayıt, canlı transkripsiyon, işlem hattı,
/// toplantı algılama ve global kısayol kilitliyken de çalışır: kilit bir
/// görüntüleme kapısıdır, hiçbir şeyin önüne geçmez (kural #2'nin ruhu).
/// Menü bar kayıt denetimlerini gösterir ama içerik (canlı satır, sıradaki
/// toplantının adı) göstermez.
///
/// Kilitlendiği anlar: açılış, ekran kilidi / uyku / kullanıcı değişimi ve
/// uygulamadan `idleTimeout` kadar uzak kalmak. Sonuncusu **tek bir
/// ertelenmiş görevdir**, zamanlayıcıyla yoklama değil — uygulama geri
/// gelince iptal edilir.
@Observable
final class AppLock {

    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    /// Kullanıcıya gösterilecek son hata. Vazgeçmek hata değildir.
    private(set) var failure: String?

    var isEnabled: Bool { settings.appLockEnabled }

    /// Bu Mac'te parola ya da Touch ID ayarlı mı? Değilse kilit açılamaz,
    /// bu yüzden açılmasına da izin verilmez.
    var isAvailable: Bool { authenticator.canAuthenticate() }

    static let defaultIdleTimeout: Duration = .seconds(5 * 60)

    /// Ayarlarda gösterilen süre metni.
    static let idleTimeoutLabel = "5 dakika"

    private let settings: OraSettings
    private let authenticator: any DeviceAuthenticating
    private let idleTimeout: Duration
    private var idleTask: Task<Void, Never>?
    /// Uygulama ömrü boyunca yaşar; gözlemciler bu yüzden hiç kaldırılmaz.
    private var observers: [NSObjectProtocol] = []

    init(settings: OraSettings,
         authenticator: any DeviceAuthenticating = SystemAuthenticator(),
         idleTimeout: Duration = AppLock.defaultIdleTimeout) {
        self.settings = settings
        self.authenticator = authenticator
        self.idleTimeout = idleTimeout
        // Açılışta kilitli başlar — pencere ilk karede içerik göstermesin.
        isLocked = settings.appLockEnabled
    }

    // MARK: - Kilit

    func lock() {
        guard isEnabled else { return }
        idleTask?.cancel()
        idleTask = nil
        isLocked = true
        failure = nil
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            if try await authenticator.authenticate(reason: Self.unlockReason) {
                isLocked = false
                failure = nil
            } else {
                failure = "Kimlik doğrulanamadı."
            }
        } catch {
            failure = Self.message(for: error)
        }
    }

    /// Ayardan açma ve kapama. **İki yönde de doğrulama ister**: açarken
    /// kilidin bu Mac'te gerçekten açılabildiği görülür, kapatırken de
    /// kilidi kaldıranın cihaz sahibi olduğu.
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool {
        guard on != settings.appLockEnabled else { return true }
        guard authenticator.canAuthenticate() else {
            failure = "Bu Mac'te parola ya da Touch ID ayarlı değil."
            return false
        }
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            guard try await authenticator.authenticate(
                reason: on ? Self.enableReason : Self.disableReason) else {
                failure = "Kimlik doğrulanamadı."
                return false
            }
        } catch {
            failure = Self.message(for: error)
            return false
        }
        settings.appLockEnabled = on
        failure = nil
        if !on {
            isLocked = false
            idleTask?.cancel()
            idleTask = nil
        }
        Log.info(.app, "Uygulama kilidi \(on ? "açıldı" : "kapatıldı")")
        return true
    }

    // MARK: - Sistem olayları

    /// Ekran kilitlendi, uyku ya da kullanıcı değişimi: hemen kilitle.
    func systemDidLock() { lock() }

    /// Uygulama arka plana geçti: `idleTimeout` sonra kilitle. Pencere
    /// başka uygulamaların arkasında görünür kalabildiği için süre dönüşte
    /// değil, **geçen zamanda** dolar.
    func appDidResignActive() {
        guard isEnabled, !isLocked else { return }
        idleTask?.cancel()
        idleTask = Task { [weak self, idleTimeout] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    func appDidBecomeActive() {
        idleTask?.cancel()
        idleTask = nil
    }

    /// Sistem bildirimlerine abone olur. Uygulama başlarken bir kez çağrılır;
    /// testler olay yöntemlerini doğrudan çağırır.
    func startObserving() {
        guard observers.isEmpty else { return }
        let app = NotificationCenter.default
        observers.append(app.addObserver(forName: NSApplication.didResignActiveNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidResignActive() }
        })
        observers.append(app.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidLock() }
            })
        }

        // Ekran kilidinin genel bir bildirimi yok; bu dağıtılmış bildirim
        // loginwindow'un yayınıdır ve izin istemez.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidLock() }
            })
    }

    // MARK: - Metinler

    /// Sistem doğrulama penceresinde "ora … istiyor" cümlesinin devamı.
    static let unlockReason = "toplantılarınızı görüntülemek için kilidi açmak"
    static let enableReason = "uygulama kilidini açmak"
    static let disableReason = "uygulama kilidini kapatmak"

    /// Vazgeçmek hata değildir — ekranda kırmızı bir satır bırakmaz.
    static func message(for error: Error) -> String? {
        guard let error = error as? LAError else { return "Kimlik doğrulanamadı." }
        switch error.code {
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            return nil
        case .biometryLockout:
            return "Touch ID kilitlendi. Mac parolanızla deneyin."
        case .passcodeNotSet:
            return "Bu Mac'te parola ayarlı değil."
        default:
            return "Kimlik doğrulanamadı."
        }
    }
}
