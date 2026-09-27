import Foundation
import Observation

/// Özeti üreten motor. Ölçüm RESEARCH.md §37.
nonisolated enum SummaryEngine: String, CaseIterable, Sendable, Identifiable {
    /// Apple'ın cihaz üstü ~3B modeli. Varsayılan.
    case apple
    /// İndirilen yerel model — daha iyi not, daha ağır bedel.
    case local
    /// Kullanıcının bağladığı AI sağlayıcısı (Bağlantı Kuralları). Metin
    /// cihazdan çıkar; kurulu ve onaylı değilse ya da toplantı kilitliyse
    /// Apple modeline düşülür.
    case cloud

    var id: String { rawValue }

    var turkishName: String {
        switch self {
        case .apple: "Apple modeli"
        case .local: "İndirilen model"
        case .cloud: "Bağlı sağlayıcı"
        }
    }
}

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

    /// Karşı tarafın (sistem sesi kanalının) dili. `nil` = toplantı diliyle
    /// aynı — varsayılan ve eski davranış (COMPETITION.md §4.8). Yabancı
    /// müşteriyle toplantıda kullanıcı Türkçe, karşı taraf İngilizce konuşur.
    var remoteLanguage: TranscriptionLanguage? {
        didSet { store(remoteLanguage?.rawValue ?? Self.sameLanguage, .remoteLanguage) }
    }
    private static let sameLanguage = "same"

    /// Kayıt başında canlı transkripsiyonun kanal dilleri. Canlı akışta dil
    /// tanıma yok: "Otomatik" Türkçe başlar, kayıt sonrası tam geçiş düzeltir.
    var liveLocales: ChannelLocales {
        let mic = transcriptionLanguage.locale ?? Locale(identifier: "tr-TR")
        guard let remote = remoteLanguage else { return ChannelLocales(mic) }
        return ChannelLocales(mic: mic, system: remote.locale ?? mic)
    }

    // MARK: - Mikrofon

    /// Hoparlörden çalan karşı tarafın sesi mikrofon kanalından silinsin mi
    /// (Apple'ın ses işlemesi). **Varsayılan açık**; kulaklık takılıyken kayıt
    /// başında kendiliğinden atlanır (`OutputRoute`).
    var echoCancellationEnabled: Bool {
        didSet { store(echoCancellationEnabled, .echoCancellationEnabled) }
    }

    // MARK: - Konuşmacı ayrımı

    /// Tam geçişten sonra konuşmacılar ayrılsın mı ("Katılımcı 1", "Katılımcı
    /// 2"…). **Varsayılan açık:** modeller uygulamanın içinde, indirme ve ağ
    /// yok, 60 dakikalık kanal saniyeler sürer. Kapalıyken kanal ayrımı
    /// ("Ben" / "Katılımcı") eskisi gibi kalır.
    var speakerSeparationEnabled: Bool {
        didSet { store(speakerSeparationEnabled, .speakerSeparationEnabled) }
    }

    /// Adlandırılan konuşmacıların sesi öğrenilsin ve sonraki toplantılarda
    /// kendiliğinden tanınsın mı. **Varsayılan açık.** Ses izleri yalnızca bu
    /// Mac'te durur; kapatmak mevcut izleri silmez (Ayarlar'da ayrı düğme).
    var voiceMemoryEnabled: Bool { didSet { store(voiceMemoryEnabled, .voiceMemoryEnabled) } }

    // MARK: - Özetleme motoru

    /// Özeti hangi model üretsin? Varsayılan Apple'ın cihaz üstü modeli:
    /// sıfır indirme, iki kat hızlı. Yerel model ölçülen kaliteyi ~iki katına
    /// çıkarıyor ama 6 GB indirme ve 7 GB tepe bellek istiyor (RESEARCH.md §37).
    var summaryEngine: SummaryEngine { didSet { store(summaryEngine.rawValue, .summaryEngine) } }

    /// Yerel motor seçildiğinde kullanılacak model kimliği (katalogdan).
    var localModelID: String { didSet { store(localModelID, .localModelID) } }

    var localModel: LocalModel { LocalModel.named(localModelID) ?? .qwen35_9B }

    /// Özet uzunluğu. Varsayılan Dengeli — ölçümlerin alındığı seviye.
    /// Yeni ve yeniden üretilen özetlere uygulanır; eski notlar değişmez.
    var summaryDetail: SummaryDetail { didSet { store(summaryDetail.rawValue, .summaryDetail) } }

    // MARK: - Bağlantılar (Faz 11)

    /// "Bağlı sağlayıcı" motoru hangi hizmeti kullanır.
    var cloudProvider: ConnectionKind {
        didSet { store(cloudProvider.rawValue, .cloudProvider) }
    }

    /// Sağlayıcı başına model adı. Boşsa `ConnectionKind.defaultModel`.
    var providerModels: [String: String] { didSet { store(providerModels, .providerModels) } }

    func model(for kind: ConnectionKind) -> String {
        let chosen = providerModels[kind.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        return chosen.isEmpty ? kind.defaultModel : chosen
    }

    /// Ollama / LM Studio adresi.
    var localServerURL: String { didSet { store(localServerURL, .localServerURL) } }

    /// İlk gönderimden önce ön izlemesi gösterilip onaylanan bağlantılar
    /// (kural 5). Onaysız bağlantıya toplantı verisi gitmez.
    var consentedConnections: Set<String> {
        didSet { store(Array(consentedConnections), .consentedConnections) }
    }

    /// Özet hazır olunca kendiliğinden gönderilen paylaşım hedefleri.
    var autoShareConnections: Set<String> {
        didSet { store(Array(autoShareConnections), .autoShareConnections) }
    }

    /// Notion'da notların altına yazılacağı sayfanın kimliği.
    var notionPageID: String { didSet { store(notionPageID, .notionPageID) } }

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

    /// Panoya kopyalanan Türkçe anons. **Doğru olmak zorunda:** özet bağlı
    /// bir AI sağlayıcısına gidiyorsa "hiçbir yere gönderilmiyor" denmez.
    static func announcement(sendsText: Bool) -> String {
        sendsText
            ? "Bu görüşmeyi not almak için kaydediyorum. Ses kaydı yalnızca kendi "
              + "bilgisayarımda kalıyor; not çıkarmak için konuşmanın metni seçtiğim "
              + "bir yapay zekâ hizmetine gönderiliyor. İtirazı olan var mı?"
            : "Bu görüşmeyi not almak için kaydediyorum. Kayıt ve çözümleme yalnızca "
              + "kendi bilgisayarımda yapılıyor, hiçbir yere gönderilmiyor. "
              + "İtirazı olan var mı?"
    }

    /// Kayıtların metni varsayılan olarak bir sağlayıcıya gidiyor mu?
    var sendsTranscripts: Bool {
        summaryEngine == .cloud && consentedConnections.contains(cloudProvider.rawValue)
    }

    // MARK: - Uygulama kilidi

    /// Touch ID / parola ile uygulama kilidi. **Opt-in, varsayılan kapalı.**
    /// Doğrudan yazılmaz — açıp kapatmak `AppLock.setEnabled` üzerinden
    /// kimlik doğrulaması ister.
    var appLockEnabled: Bool { didSet { store(appLockEnabled, .appLockEnabled) } }

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
        appLockEnabled = defaults.bool(forKey: Key.appLockEnabled.rawValue)
        voiceMemoryEnabled = defaults.object(
            forKey: Key.voiceMemoryEnabled.rawValue) as? Bool ?? true
        echoCancellationEnabled = defaults.object(
            forKey: Key.echoCancellationEnabled.rawValue) as? Bool ?? true
        speakerSeparationEnabled = defaults.object(
            forKey: Key.speakerSeparationEnabled.rawValue) as? Bool ?? true
        audioRetentionDays = defaults.integer(forKey: Key.audioRetentionDays.rawValue)
        transcriptionLanguage = defaults.string(forKey: Key.transcriptionLanguage.rawValue)
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .turkish
        remoteLanguage = defaults.string(forKey: Key.remoteLanguage.rawValue)
            .flatMap(TranscriptionLanguage.init(rawValue:))
        summaryEngine = defaults.string(forKey: Key.summaryEngine.rawValue)
            .flatMap(SummaryEngine.init(rawValue:)) ?? .apple
        localModelID = defaults.string(forKey: Key.localModelID.rawValue) ?? LocalModel.qwen35_9B.id
        cloudProvider = defaults.string(forKey: Key.cloudProvider.rawValue)
            .flatMap(ConnectionKind.init(rawValue:)) ?? .anthropic
        providerModels = defaults.dictionary(forKey: Key.providerModels.rawValue)
            as? [String: String] ?? [:]
        localServerURL = defaults.string(forKey: Key.localServerURL.rawValue)
            ?? ConnectionKind.localServer.defaultBaseURL ?? ""
        consentedConnections = Set(defaults.stringArray(
            forKey: Key.consentedConnections.rawValue) ?? [])
        autoShareConnections = Set(defaults.stringArray(
            forKey: Key.autoShareConnections.rawValue) ?? [])
        notionPageID = defaults.string(forKey: Key.notionPageID.rawValue) ?? ""
        summaryDetail = defaults.string(forKey: Key.summaryDetail.rawValue)
            .flatMap(SummaryDetail.init(rawValue:)) ?? .balanced
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
        case compressAudio, audioRetentionDays, announceRecording, appLockEnabled
        case transcriptionLanguage, remoteLanguage
        case summaryEngine, localModelID, summaryDetail
        case speakerSeparationEnabled, echoCancellationEnabled, voiceMemoryEnabled
        case cloudProvider, providerModels, localServerURL, consentedConnections
        case autoShareConnections, notionPageID
    }

    private let defaults: UserDefaults

    private func store(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
