import AppKit
import Carbon.HIToolbox

/// Uygulama ön planda **olmasa da** çalışan kısayol: ⌘⇧R ile kaydı başlat/durdur.
///
/// Menü bardaki ⌘⇧R yalnızca ora ön plandayken çalışıyordu; oysa kaydı başlatmak
/// istediğiniz an tam olarak başka bir uygulamadasınızdır — toplantı
/// penceresinde (COMPETITION.md §4.16).
///
/// **Neden Carbon:** sistem genelinde kısayol için izin istemeyen tek yol
/// `RegisterEventHotKey`. `NSEvent.addGlobalMonitorForEvents` erişilebilirlik
/// izni ister; ora tap sayesinde kurtulduğu izinleri geri getirmez.
final class GlobalHotKey {

    static let shared = GlobalHotKey()

    /// Kısayola basıldığında çalışacak iş. Kayıt başlat/durdur bağlanır.
    var action: (() -> Void)?

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature = OSType(0x6F726131)   // 'ora1'

    private init() {}

    /// ⌘⇧R. Zaten kayıtlıysa bir şey yapmaz. Başarısız olursa uygulama
    /// çalışmaya devam eder — kısayol bir kolaylık, koşul değil.
    func register() {
        guard reference == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == GlobalHotKey.signature else { return noErr }
            // Carbon geri çağrısı ana iş parçacığında gelir ama izole değildir.
            MainActor.assumeIsolated { GlobalHotKey.shared.action?() }
            return noErr
        }, 1, &eventType, nil, &handler)

        guard status == noErr else {
            Log.warning(.app, "Global kısayol işleyicisi kurulamadı (OSStatus \(status))")
            return
        }

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_R),
                                         UInt32(cmdKey | shiftKey),
                                         id, GetApplicationEventTarget(), 0, &reference)
        if result == noErr {
            Log.info(.app, "Global kısayol açıldı: ⌘⇧R")
        } else {
            // En sık neden: başka bir uygulama aynı kısayolu almış.
            Log.warning(.app, "Global kısayol alınamadı (OSStatus \(result)) — "
                        + "başka bir uygulama ⌘⇧R kullanıyor olabilir")
            reference = nil
        }
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
