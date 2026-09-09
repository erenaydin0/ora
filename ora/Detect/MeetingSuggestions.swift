import Foundation
import Observation

/// Algılama sinyalini kullanıcıya **öneriye** çevirir ve kararını geri taşır.
///
/// İki yüzey vardır ve **tek yüzeye bağlı kalınmaz** (RESEARCH.md §17.2):
/// eylemli bildirim ve penceredeki şerit. Geliştirme derlemelerinde bildirim
/// izni hiç alınamıyor (ad-hoc imza, RESEARCH.md §28.1); öneri o zaman yalnızca
/// şeritte görünür.
///
/// **İzinsiz otomatik kayıt yok.** Bu tip yalnızca *önerir*; kaydı başlatan
/// `onRecord`'u dinleyen taraftır. Tek istisna kullanıcının bir uygulama için
/// "her zaman kaydet" demesidir — o da `MeetingDetector.onAutoStart`'tan gelir.
///
/// `ora/Detect/` altında: yalnızca algılamaya ve bildirim yüzeyine bağlıdır.
/// Takvimle zenginleştirme **closure olarak** verilir, böylece bu tip
/// Calendar'a bağlanmaz ve ARCHITECTURE.md'nin bağımlılık yönü korunur.
@Observable
final class MeetingSuggestions {

    /// Öneri bekleyen sinyal — arayüzdeki şerit ve menü bar bunu gösterir.
    var pendingSignal: MeetingSignal? { detector.pendingSignal }
    /// Kayıt sürerken toplantı uygulaması mikrofonu bıraktı; durdurmayı öner.
    var suggestsStop: Bool { detector.suggestsStop }

    /// Bu sinyal kaydedilmek üzere seçildi. Kaydı **çağıran** başlatır.
    var onRecord: ((MeetingSignal) -> Void)?

    private let detector: any MeetingDetecting
    private let notifications: any SuggestionNotifying
    private let settings: OraSettings
    /// Bildirime yazılacak takvim etkinliği. Takvim kapalıysa nil döner.
    private let matchingEvent: (MeetingSignal) -> MeetingEvent?

    /// Gözlemleme sürüyor mu. `withObservationTracking` iptal edilebilir bir
    /// görev döndürmez; bu bayrak hem yeniden kurmayı hem teslimi kapatır.
    private var isObserving = false
    /// Hangi bundle ID için bildirim gönderildi — aynı öneri için ikinci kez
    /// gönderilmesin. Sinyal düşünce sıfırlanır.
    private var lastNotified: String?

    init(detector: any MeetingDetecting,
         notifications: any SuggestionNotifying,
         settings: OraSettings,
         matchingEvent: @escaping (MeetingSignal) -> MeetingEvent? = { _ in nil }) {
        self.detector = detector
        self.notifications = notifications
        self.settings = settings
        self.matchingEvent = matchingEvent
        wire()
    }

    // MARK: - Yaşam döngüsü

    /// Uygulama açılışında bir kez. **Bildirim iznini beklemez** — istem
    /// kullanıcı yanıtlayana kadar askıda kalıyor ve beklenirse algılama hiç
    /// başlamıyordu (RESEARCH.md §17.2).
    func start() { setEnabled(true) }

    /// Kullanıcı ayarlardan algılamayı açıp kapatabilir.
    func setEnabled(_ enabled: Bool) {
        isObserving = enabled
        if enabled {
            detector.start()
            observeSignal()
        } else {
            lastNotified = nil
            detector.stop()
        }
    }

    // MARK: - Kullanıcının kararı

    /// Öneri reddedildi — bu uygulama için soğuma başlar.
    func dismiss() {
        detector.dismissSuggestion()
    }

    /// Öneri kabul edildi (şerit, menü bar ya da bildirim düğmesi).
    func accept() {
        guard let signal = detector.pendingSignal else { return }
        detector.dismissSuggestion()
        onRecord?(signal)
    }

    /// "Bu uygulamayı hep kaydet".
    ///
    /// Ayar **her hâlükârda** yazılır: kullanıcı bunu açıkça istedi, öneri o
    /// arada düşmüş olsa bile hatırlanmalı. Öneri hâlâ duruyorsa kayıt da başlar.
    func alwaysRecord(bundleID: String) {
        settings.alwaysRecordBundleIDs.insert(bundleID)
        guard detector.pendingSignal?.bundleID == bundleID else { return }
        accept()
    }

    /// Kayıt başladı/bitti — algılayıcı buna göre otomatik durdurmayı izler.
    func recordingStarted(bundleID: String?) { detector.recordingStarted(bundleID: bundleID) }
    func recordingStopped() { detector.recordingStopped() }

    // MARK: - Bildirim teslimi

    private func wire() {
        detector.onAutoStart = { [weak self] signal in
            self?.onRecord?(signal)
        }
        notifications.onRecord = { [weak self] bundleID in
            guard let self, self.detector.pendingSignal?.bundleID == bundleID else { return }
            self.accept()
        }
        notifications.onDismiss = { [weak self] _ in
            self?.dismiss()
        }
        notifications.onAlways = { [weak self] bundleID in
            self?.alwaysRecord(bundleID: bundleID)
        }
    }

    /// Sinyal değişimini **gözlemleyerek** izler.
    ///
    /// Eskiden bu bir saniyelik `while` döngüsüydü: `pendingSignal`'i her
    /// saniye yokluyordu. Üç sorunu vardı — CLAUDE.md'nin "polling yok"
    /// ilkesiyle çelişiyordu, bildirime 1 sn'ye kadar gecikme ekliyordu ve
    /// uygulama açık olduğu sürece her saniye bir görev uyandırıyordu.
    ///
    /// `withObservationTracking` **tek seferliktir** ve `onChange` `willSet`
    /// anında gelir (yeni değer henüz yazılmamıştır). Bu yüzden: bir tur
    /// sonraya geç, **önce yeniden kur**, sonra o anki durumu teslim et.
    /// Teslim güncel durumu okuyup uzlaştırdığı için, iki değişim arasında
    /// kaçan bir ara adım sonucu bozmaz.
    private func observeSignal() {
        guard isObserving else { return }
        withObservationTracking {
            _ = detector.pendingSignal
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.observeSignal()
                await self.deliver()
            }
        }
    }

    /// O anki sinyali bildirime taşır. Aynı öneri için ikinci bildirim
    /// gönderilmez; sinyal düşünce hafıza sıfırlanır.
    private func deliver() async {
        guard let signal = detector.pendingSignal else {
            lastNotified = nil
            return
        }
        guard signal.bundleID != lastNotified else { return }
        lastNotified = signal.bundleID
        await notifications.suggestRecording(signal, event: matchingEvent(signal))
    }
}
