import Foundation
import LocalAuthentication
import Testing
@testable import ora

/// Sırayla verilen yanıtları döndüren doğrulayıcı. Gerçek `LAContext`
/// testte sistem penceresi açardı.
nonisolated final class FakeAuthenticator: DeviceAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<Bool, Error>]
    private var _reasons: [String] = []
    let available: Bool

    init(_ responses: [Result<Bool, Error>] = [], available: Bool = true) {
        queue = responses
        self.available = available
    }

    var reasons: [String] { lock.withLock { _reasons } }

    func canAuthenticate() -> Bool { available }

    func authenticate(reason: String) async throws -> Bool {
        let next: Result<Bool, Error> = lock.withLock {
            _reasons.append(reason)
            return queue.isEmpty ? .success(false) : queue.removeFirst()
        }
        return try next.get()
    }
}

/// Uygulama kilidi: opt-in, doğrulamasız açılıp kapanamaz, kilitliyken
/// hiçbir şeyi durdurmaz (yalnızca arayüzü örter — bu, kilidin hiçbir
/// kayıt ya da hat nesnesine dokunmamasıyla güvence altında).
@Suite("Uygulama kilidi", .serialized)
struct AppLockTests {

    private final class World {
        let suite = "ora.tests.\(UUID().uuidString)"
        let settings: OraSettings
        init(enabled: Bool = false) {
            settings = OraSettings(defaults: UserDefaults(suiteName: suite)!)
            settings.appLockEnabled = enabled
        }
        deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }

    /// Varsayılan kapalı: kilitli başlamaz ve hiçbir olay kilitlemez.
    @Test
    func varsayilanKapaliHicbirOlayKilitlemez() {
        let world = World()
        let lock = AppLock(settings: world.settings, authenticator: FakeAuthenticator())

        #expect(!world.settings.appLockEnabled)
        #expect(!lock.isLocked)
        lock.lock()
        lock.systemDidLock()
        lock.appDidResignActive()
        #expect(!lock.isLocked)
    }

    /// Açıksa açılışta kilitli başlar; doğrulama kilidi açar.
    @Test
    func aciksaKilitliBaslarDogrulamaAcar() async {
        let world = World(enabled: true)
        let fake = FakeAuthenticator([.success(true)])
        let lock = AppLock(settings: world.settings, authenticator: fake)

        #expect(lock.isLocked)
        await lock.unlock()
        #expect(!lock.isLocked)
        #expect(fake.reasons == [AppLock.unlockReason])
    }

    /// Başarısız doğrulama kilitli bırakır ve söyler; vazgeçmek hata değildir.
    @Test
    func basarisizDogrulamaKilitliBirakirVazgecmekSessizdir() async {
        let world = World(enabled: true)
        let fake = FakeAuthenticator([.success(false), .failure(LAError(.userCancel))])
        let lock = AppLock(settings: world.settings, authenticator: fake)

        await lock.unlock()
        #expect(lock.isLocked)
        #expect(lock.failure == "Kimlik doğrulanamadı.")

        await lock.unlock()
        #expect(lock.isLocked)
        #expect(lock.failure == nil, "vazgeçmek kırmızı satır bırakmaz")
    }

    /// Açmak da kapatmak da doğrulama ister; doğrulama yoksa ayar değişmez.
    @Test
    func acipKapatmakDogrulamaIster() async {
        let world = World()
        let fake = FakeAuthenticator([.success(false), .success(true),
                                      .failure(LAError(.userCancel)), .success(true)])
        let lock = AppLock(settings: world.settings, authenticator: fake)

        #expect(await lock.setEnabled(true) == false)
        #expect(!world.settings.appLockEnabled)

        #expect(await lock.setEnabled(true))
        #expect(world.settings.appLockEnabled)
        #expect(!lock.isLocked, "açmak o an kilitlemez")

        #expect(await lock.setEnabled(false) == false)
        #expect(world.settings.appLockEnabled, "vazgeçilince açık kalır")

        #expect(await lock.setEnabled(false))
        #expect(!world.settings.appLockEnabled)
        #expect(fake.reasons == [AppLock.enableReason, AppLock.enableReason,
                                 AppLock.disableReason, AppLock.disableReason])
    }

    /// Parola ya da Touch ID yoksa kilit açılamaz — o yüzden açılmasına da
    /// izin verilmez, doğrulama penceresi hiç istenmez.
    @Test
    func dogrulamaYoksaAcilmaz() async {
        let world = World()
        let fake = FakeAuthenticator(available: false)
        let lock = AppLock(settings: world.settings, authenticator: fake)

        #expect(await lock.setEnabled(true) == false)
        #expect(!world.settings.appLockEnabled)
        #expect(lock.failure != nil)
        #expect(fake.reasons.isEmpty)
    }

    /// Ekran kilidi ve uyku hemen kilitler.
    @Test
    func ekranKilidiHemenKilitler() async {
        let world = World(enabled: true)
        let lock = AppLock(settings: world.settings,
                           authenticator: FakeAuthenticator([.success(true)]))
        await lock.unlock()
        #expect(!lock.isLocked)

        lock.systemDidLock()
        #expect(lock.isLocked)
    }

    /// Uygulamadan uzak kalınca süre dolunca kilitler; geri dönmek iptal eder.
    @Test
    func uzakKalincaKilitlerGeriDonmekIptalEder() async {
        let world = World(enabled: true)
        let lock = AppLock(settings: world.settings,
                           authenticator: FakeAuthenticator([.success(true), .success(true)]),
                           idleTimeout: .milliseconds(60))
        await lock.unlock()

        lock.appDidResignActive()
        lock.appDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!lock.isLocked, "geri dönüldü, kilitlenmedi")

        lock.appDidResignActive()
        await waitUntil("süre doldu, kilitlendi") { lock.isLocked }
    }

    /// Kapatınca açık bir kilit de kalkar.
    @Test
    func kapatinceKilitKalkar() async {
        let world = World(enabled: true)
        let lock = AppLock(settings: world.settings,
                           authenticator: FakeAuthenticator([.success(true)]))
        #expect(lock.isLocked)
        #expect(await lock.setEnabled(false))
        #expect(!lock.isLocked)
    }
}
