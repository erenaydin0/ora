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
    /// ⌃⌘M: kayıt sırasında "önemli an" işareti (COMPETITION.md §4.9).
    var markAction: (() -> Void)?

    private var reference: EventHotKeyRef?
    private var markReference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature = OSType(0x6F726131)   // 'ora1'
    private static let recordID: UInt32 = 1
    private static let markID: UInt32 = 2

    private init() {}

    /// ⌘⇧R. Zaten kayıtlıysa bir şey yapmaz. Başarısız olursa uygulama
    /// çalışmaya devam eder — kısayol bir kolaylık, koşul değil.
    func register() {
        guard reference == nil else { return }
        installHandler()
        guard handler != nil else { return }

        let id = EventHotKeyID(signature: Self.signature, id: Self.recordID)
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

    /// İşaret kısayolu **yalnızca kayıt sürerken** alınır ve kayıt bitince
    /// bırakılır: sistem genelinde bir kısayol, onu kullanan her uygulamadan
    /// tuşu çalar. ⌘⇧M bilerek seçilmedi — Teams'te mikrofonu kapatıp açar,
    /// Slack'te bahsedilmeleri açar; ikisi de tam kayıt sırasında basılır.
    func registerMark() {
        guard markReference == nil else { return }
        installHandler()
        guard handler != nil else { return }
        let id = EventHotKeyID(signature: Self.signature, id: Self.markID)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_M),
                                         UInt32(cmdKey | controlKey),
                                         id, GetApplicationEventTarget(), 0, &markReference)
        if result != noErr {
            Log.warning(.app, "İşaret kısayolu alınamadı (OSStatus \(result)) — "
                        + "başka bir uygulama ⌃⌘M kullanıyor olabilir")
            markReference = nil
        }
    }

    func unregisterMark() {
        if let markReference { UnregisterEventHotKey(markReference) }
        markReference = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == GlobalHotKey.signature else { return noErr }
            let which = id.id
            // Carbon geri çağrısı ana iş parçacığında gelir ama izole değildir.
            MainActor.assumeIsolated {
                if which == GlobalHotKey.markID {
                    GlobalHotKey.shared.markAction?()
                } else {
                    GlobalHotKey.shared.action?()
                }
            }
            return noErr
        }, 1, &eventType, nil, &handler)

        if status != noErr {
            Log.warning(.app, "Global kısayol işleyicisi kurulamadı (OSStatus \(status))")
            handler = nil
        }
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        unregisterMark()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
