import Foundation
import Observation

/// Kullanıcı ayarları. `UserDefaults` üzerinde durur, tek yerden okunur.
@MainActor
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

    // MARK: - Takvim

    /// Opt-in, varsayılan kapalı. Kapalıyken EventKit'e hiç dokunulmaz.
    var calendarEnabled: Bool { didSet { store(calendarEnabled, .calendarEnabled) } }

    /// Kullanıcının seçtiği takvimler. Varsayılan: hiçbiri.
    var selectedCalendarIDs: Set<String> { didSet { store(Array(selectedCalendarIDs), .selectedCalendars) } }

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

    private init() {
        let defaults = UserDefaults.standard
        detectionEnabled = defaults.object(forKey: Key.detectionEnabled.rawValue) as? Bool ?? true
        calendarEnabled = defaults.bool(forKey: Key.calendarEnabled.rawValue)
        userDisplayName = defaults.string(forKey: Key.userDisplayName.rawValue) ?? ""
        excludedBundleIDs = Set(defaults.stringArray(forKey: Key.excludedBundleIDs.rawValue)
                                ?? Array(Self.defaultExclusions))
        alwaysRecordBundleIDs = Set(defaults.stringArray(forKey: Key.alwaysRecord.rawValue) ?? [])
        selectedCalendarIDs = Set(defaults.stringArray(forKey: Key.selectedCalendars.rawValue) ?? [])
    }

    /// Kendi süreci de dahil, dışlanan tüm bundle ID'ler.
    var effectiveExclusions: Set<String> {
        var all = excludedBundleIDs
        if let own = Bundle.main.bundleIdentifier { all.insert(own) }
        return all
    }

    private enum Key: String {
        case detectionEnabled, excludedBundleIDs, alwaysRecord
        case calendarEnabled, selectedCalendars
        case userDisplayName
    }

    private func store(_ value: Any, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }
}
