import Foundation
import Observation

/// Kullanıcı ayarları. `UserDefaults` üzerinde durur, tek yerden okunur.
@Observable
final class OraSettings {

    static let shared = OraSettings()

    // MARK: - Toplantı algılama

    /// Algılama kapalıyken CoreAudio dinleyicileri hiç kurulmaz.
    var detectionEnabled: Bool { didSet { store(detectionEnabled, .detectionEnabled) } }

    /// Mikrofonu açık gösteren ama toplantı olmayan süreçler.
    /// `com.apple.CoreSpeech` gözlenmiş bir yanlış pozitiftir (RESEARCH.md §9).
    var excludedBundleIDs: Set<String> { didSet { store(Array(excludedBundleIDs), .excludedBundleIDs) } }

    /// Bu uygulamalarda kayıt **sorulmadan** başlar.
    var alwaysRecordBundleIDs: Set<String> { didSet { store(Array(alwaysRecordBundleIDs), .alwaysRecord) } }

    // MARK: - Kimlik

    /// Kullanıcının adı. Mikrofon kanalı bu kişidir; özetleme isteminde
    /// "Ben"in kim olduğunu söylemek için kullanılır ve sorumlu kişi listesine
    /// eklenir. Boşsa modele yalnızca "Ben" denir — davranış eskisi gibi kalır.
    /// Transkriptte konuşmacı etiketi **değişmez**.
    var userDisplayName: String { didSet { store(userDisplayName, .userDisplayName) } }

    // MARK: - Transkripsiyon

    /// Transkripsiyon dili. Eskiden `RecordingController` bunu doğrudan
    /// `UserDefaults.standard`'a yazıyordu — tek kullanıcı ayarı buradan
    /// kaçmıştı ve test kendi deposunu verse bile bu değer gerçek ayarlardan
    /// okunuyordu. Anahtar aynı (`transcriptionLanguage`), mevcut seçim korunur.
    var transcriptionLanguage: TranscriptionLanguage {
        didSet { store(transcriptionLanguage.rawValue, .transcriptionLanguage) }
    }

    // MARK: - Takvim

    /// Opt-in, varsayılan kapalı. Kapalıyken EventKit'e hiç dokunulmaz.
    var calendarEnabled: Bool { didSet { store(calendarEnabled, .calendarEnabled) } }

    /// Kullanıcının seçtiği takvimler. Varsayılan: hiçbiri.
    var selectedCalendarIDs: Set<String> { didSet { store(Array(selectedCalendarIDs), .selectedCalendars) } }

    /// Çakışan takvim toplantılarını ayırmak için toplantı uygulamasının
    /// **pencere başlığı** okunsun mu. **Opt-in, varsayılan kapalı.**
    ///
    /// Kapalıyken `WindowTitle`'a hiç dokunulmaz ve Erişilebilirlik izni
    /// istenmez; eşleştirme diğer sinyallerle çalışır, belirsizlik kalırsa
    /// kullanıcıya sorulur (RESEARCH.md §29.3). Açıkken başlık toplantının
    /// adını verir ve çakışma çoğu durumda sorulmadan çözülür.
    var windowTitleEnabled: Bool { didSet { store(windowTitleEnabled, .windowTitleEnabled) } }

    // MARK: - Kayıt bildirimi

    /// Kayıt başlarken katılımcıları bilgilendirmeyi hatırlat.
    /// Rakipler bunu "consent" özelliği olarak satıyor; ora'da karşılığı
    /// tamamen yerel bir hatırlatmadır — kimseye bir şey gönderilmez.
    var announceRecording: Bool { didSet { store(announceRecording, .announceRecording) } }

    /// Panoya kopyalanan Türkçe anons. Cümlenin ikinci yarısı ora için
    /// **doğrudur** ve öyle kalmalıdır: hiçbir veri cihazı terk etmiyor.
    static let announcement =
        "Bu görüşmeyi not almak için kaydediyorum. Kayıt ve çözümleme yalnızca "
        + "kendi bilgisayarımda yapılıyor, hiçbir yere gönderilmiyor. "
        + "İtirazı olan var mı?"

    // MARK: - Depolama

    /// Transkripsiyon ve özet bittikten sonra sesi AAC'ye çevir.
    /// Kayıp veren bir sıkıştırma olduğu için **varsayılan kapalı**; açıkken
    /// disk kazancı ~11× (RESEARCH.md §25.3).
    var compressAudio: Bool { didSet { store(compressAudio, .compressAudio) } }

    /// Bu kadar günden eski ses dosyaları silinir. `0` = süresiz sakla.
    /// Transkript, özet ve aksiyonlar **her hâlükârda** kalır.
    var audioRetentionDays: Int { didSet { store(audioRetentionDays, .audioRetentionDays) } }

    /// Kullanıcıya sunulan saklama seçenekleri.
    static let retentionOptions = [0, 30, 90, 180, 365]

    // MARK: - Sabitler

    /// Mikrofon en az bu kadar kesintisiz kullanılmalı — anlık mikrofon
    /// testlerini eler.
    static let microphoneDebounce: TimeInterval = 10
    /// Aynı uygulama için iki öneri arasındaki en kısa süre.
    static let suggestionCooldown: TimeInterval = 30 * 60
    /// Mikrofon bu kadar süre bırakılırsa kaydı bitirmek önerilir.
    /// 30 sn eşiği sessize alma senaryosunu yaşatır.
    static let autoStopGrace: TimeInterval = 30

    /// Varsayılan dışlananlar. Kendi bundle ID'miz her zaman eklenir.
    static let defaultExclusions: Set<String> = [
        "com.apple.CoreSpeech",
        "com.apple.siri",
        "com.apple.Siri",
        "com.apple.assistantd",
        "com.apple.speech.speechsynthesisd",
    ]

    /// Hangi `UserDefaults` üzerinde durduğu verilebilir. Varsayılan `.standard`;
    /// **testler kendi deposunu verir** — aksi hâlde ölçüm geliştiricinin gerçek
    /// ayarlarını okur ve sonuç makineye göre değişir.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        detectionEnabled = defaults.object(forKey: Key.detectionEnabled.rawValue) as? Bool ?? true
        calendarEnabled = defaults.bool(forKey: Key.calendarEnabled.rawValue)
        // Varsayılan kapalı: pencere başlığı okumak Erişilebilirlik izni ister,
        // kullanıcı istemedikçe istenmez.
        windowTitleEnabled = defaults.bool(forKey: Key.windowTitleEnabled.rawValue)
        userDisplayName = defaults.string(forKey: Key.userDisplayName.rawValue) ?? ""
        excludedBundleIDs = Set(defaults.stringArray(forKey: Key.excludedBundleIDs.rawValue)
                                ?? Array(Self.defaultExclusions))
        alwaysRecordBundleIDs = Set(defaults.stringArray(forKey: Key.alwaysRecord.rawValue) ?? [])
        selectedCalendarIDs = Set(defaults.stringArray(forKey: Key.selectedCalendars.rawValue) ?? [])
        announceRecording = defaults.bool(forKey: Key.announceRecording.rawValue)
        compressAudio = defaults.bool(forKey: Key.compressAudio.rawValue)
        audioRetentionDays = defaults.integer(forKey: Key.audioRetentionDays.rawValue)
        transcriptionLanguage = defaults.string(forKey: Key.transcriptionLanguage.rawValue)
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .turkish
    }

    /// Kendi süreci de dahil, dışlanan tüm bundle ID'ler.
    var effectiveExclusions: Set<String> {
        var all = excludedBundleIDs
        if let own = Bundle.main.bundleIdentifier { all.insert(own) }
        return all
    }

    private enum Key: String {
        case detectionEnabled, excludedBundleIDs, alwaysRecord
        case calendarEnabled, selectedCalendars, windowTitleEnabled
        case userDisplayName
        case compressAudio, audioRetentionDays, announceRecording
        case transcriptionLanguage
    }

    private let defaults: UserDefaults

    private func store(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
