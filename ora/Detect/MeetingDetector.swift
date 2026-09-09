import Foundation
import CoreAudio
import AppKit

/// Algılanan toplantı sinyali.
struct MeetingSignal: Sendable, Equatable {
    let bundleID: String
    let displayName: String
    /// Tarayıcıda geçen toplantılar düşük güvenlidir: bundle ID tarayıcıdır,
    /// toplantı değil. Kullanıcıya öyle sunulur.
    let isLowConfidence: Bool
    /// Mikrofona ek olarak ses de çalıyorsa güven yükselir.
    let hasOutput: Bool
    let since: Date

    var turkishTitle: String {
        isLowConfidence ? "\(displayName) mikrofonu kullanıyor"
                        : "\(displayName) toplantısı algılandı"
    }
}

/// Toplantı algılama — **`ps aux` polling'i yoktur.**
///
/// Sinyal CoreAudio olay dinleyicileridir: süreç listesi ve her sürecin
/// `isRunningInput` / `isRunningOutput` özelliği. Olay tabanlı, izin gerektirmez,
/// CPU maliyeti sıfıra yakın (RESEARCH.md §9).
///
/// **Toplantı tanımı:** bilinen bir toplantı uygulaması mikrofonu *şu anda*
/// kullanıyor. Uygulamanın açık olması yetmez — eski ora'nın temel hatası buydu.
@MainActor
@Observable
final class MeetingDetector {

    /// Öneri bekleyen sinyal. Kullanıcı karar verene kadar durur.
    private(set) var pendingSignal: MeetingSignal?
    /// Kayıt sürerken toplantı uygulaması mikrofonu bıraktıysa dolu olur.
    private(set) var suggestsStop = false

    /// Otomatik başlatma (uygulama için "her zaman kaydet" seçilmişse).
    var onAutoStart: ((MeetingSignal) -> Void)?

    private let settings: OraSettings
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var watchedProcesses: Set<AudioObjectID> = []
    private var isRunning = false

    /// bundleID → mikrofonun kesintisiz açık olduğu an.
    private var micSince: [String: Date] = [:]
    /// bundleID → son öneri zamanı (soğuma için).
    private var lastSuggestion: [String: Date] = [:]
    /// Soğuma yüzünden atlanan aday bir kez günlüğe yazılır. Yoksa "algılama
    /// bozuk" ile "soğuma sürüyor" ayırt edilemiyor (30 dk sessizlik).
    /// Kayıt sürerken izlenen uygulama ve mikrofonu bıraktığı an.
    private var cooldownLogged: Set<String> = []
    /// bundleID → mikrofonu bıraktığı an. Soğuma **aynı mikrofon oturumu**
    /// içindir: uygulama mikrofonu bırakıp yeniden aldıysa bu yeni bir
    /// toplantıdır ve yeniden önerilmelidir.
    private var micReleasedAt: [String: Date] = [:]
    private var recordingBundleID: String?
    private var releasedAt: Date?

    private var debounceTimer: Timer?

    init(settings: OraSettings = .shared) {
        self.settings = settings
    }

    // MARK: - Yaşam döngüsü

    func start() {
        guard settings.detectionEnabled, !isRunning else { return }
        isRunning = true

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.evaluate() }
        }
        listenerBlock = block

        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        guard status == noErr else {
            Log.warning(.pipeline, "Süreç listesi dinleyicisi kurulamadı (OSStatus \(status)) — "
                        + "toplantı algılama devre dışı")
            isRunning = false
            return
        }
        attachProcessListeners()
        // 1 sn'lik zamanlayıcı polling değildir: yalnızca "mikrofon 10 sn'dir açık"
        // ve "30 sn'dir bırakıldı" eşiklerinin geçtiğini görmek için sayar.
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate()
        Log.info(.pipeline, "Toplantı algılama açıldı — \(watchedProcesses.count) süreç izleniyor")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        debounceTimer?.invalidate()
        debounceTimer = nil
        guard let block = listenerBlock else { return }

        var listAddress = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                              &listAddress, DispatchQueue.main, block)
        var inputAddress = Self.address(kAudioProcessPropertyIsRunningInput)
        var outputAddress = Self.address(kAudioProcessPropertyIsRunningOutput)
        for process in watchedProcesses {
            AudioObjectRemovePropertyListenerBlock(process, &inputAddress, DispatchQueue.main, block)
            AudioObjectRemovePropertyListenerBlock(process, &outputAddress, DispatchQueue.main, block)
        }
        watchedProcesses.removeAll()
        listenerBlock = nil
        micSince.removeAll()
        pendingSignal = nil
        Log.info(.pipeline, "Toplantı algılama kapatıldı")
    }

    /// Kullanıcı öneriyi reddetti — bu uygulama için soğuma başlar.
    func dismissSuggestion() {
        if let signal = pendingSignal {
            lastSuggestion[signal.bundleID] = Date()
        }
        pendingSignal = nil
    }

    /// Kayıt başladığında hangi uygulamanın izleneceğini bildirir.
    func recordingStarted(bundleID: String?) {
        recordingBundleID = bundleID
        releasedAt = nil
        suggestsStop = false
        pendingSignal = nil
    }

    func recordingStopped() {
        recordingBundleID = nil
        releasedAt = nil
        suggestsStop = false
    }

    // MARK: - Değerlendirme

    /// Süreç listesi değiştiğinde dinleyiciler **yeniden bağlanır** —
    /// yeni süreçler otomatik izlenmez.
    private func attachProcessListeners() {
        guard let block = listenerBlock,
              let processes = try? AudioHardwareSystem.shared.processes else { return }
        var inputAddress = Self.address(kAudioProcessPropertyIsRunningInput)
        var outputAddress = Self.address(kAudioProcessPropertyIsRunningOutput)
        for process in processes where !watchedProcesses.contains(process.id) {
            AudioObjectAddPropertyListenerBlock(process.id, &inputAddress, DispatchQueue.main, block)
            AudioObjectAddPropertyListenerBlock(process.id, &outputAddress, DispatchQueue.main, block)
            watchedProcesses.insert(process.id)
        }
    }

    private func evaluate() {
        guard isRunning else { return }
        attachProcessListeners()

        let active = Self.activeAudioProcesses(excluding: settings.effectiveExclusions)
        let now = Date()

        // Mikrofon kullanım süreleri **ana uygulama** kimliğiyle tutulur:
        // yardımcı süreç mikrofonu tutuyorsa toplantı yine o uygulamanındır.
        let usingMic = Set(active.filter(\.usesMicrophone)
            .map { MeetingApps.resolve($0.bundleID) ?? $0.bundleID })
        for bundleID in usingMic where micSince[bundleID] == nil {
            micSince[bundleID] = now
        }
        for bundleID in micSince.keys where !usingMic.contains(bundleID) {
            micSince[bundleID] = nil
            cooldownLogged.remove(bundleID)
            if micReleasedAt[bundleID] == nil { micReleasedAt[bundleID] = now }
        }
        for bundleID in usingMic { micReleasedAt[bundleID] = nil }

        // Mikrofonu yeterince uzun bırakan uygulamanın soğuması sıfırlanır:
        // sonraki toplantı yeni bir olaydır, 30 dakikalık sessizliğe kurban
        // gitmemeli. Kısa kesintiler (bir saniyelik düşüşler) eşiği geçmez.
        let longReleased = micReleasedAt.filter {
            now.timeIntervalSince($0.value) >= OraSettings.autoStopGrace
        }
        for bundleID in longReleased.keys {
            if lastSuggestion.removeValue(forKey: bundleID) != nil {
                Log.debug(.pipeline, "\(MeetingApps.displayName(bundleID)) mikrofonu bıraktı — "
                          + "öneri soğuması sıfırlandı")
            }
            micReleasedAt[bundleID] = nil
        }

        // Öneri, toplantı bittikten sonra ekranda **kalmaz**: uygulama
        // mikrofonu bıraktıysa teklif de geçersizdir.
        if let pending = pendingSignal, longReleased[pending.bundleID] != nil {
            Log.debug(.pipeline, "Öneri düştü: \(pending.displayName) mikrofonu bıraktı")
            pendingSignal = nil
        }

        // Kayıt sürerken: izlenen uygulama mikrofonu bıraktı mı?
        if let recordingBundleID {
            if usingMic.contains(recordingBundleID) {
                releasedAt = nil
                suggestsStop = false
            } else if let releasedAt {
                suggestsStop = now.timeIntervalSince(releasedAt) >= OraSettings.autoStopGrace
            } else {
                releasedAt = now
            }
            return
        }

        guard pendingSignal == nil else { return }

        // Toplantı adayları: bilinen uygulama + mikrofon en az 10 sn kesintisiz.
        for process in active where process.usesMicrophone {
            guard let app = MeetingApps.resolve(process.bundleID),
                  let since = micSince[app],
                  now.timeIntervalSince(since) >= OraSettings.microphoneDebounce
            else { continue }

            if let last = lastSuggestion[app],
               now.timeIntervalSince(last) < OraSettings.suggestionCooldown {
                if cooldownLogged.insert(app).inserted {
                    let remaining = Int((OraSettings.suggestionCooldown
                                         - now.timeIntervalSince(last)) / 60)
                    Log.debug(.pipeline, "\(MeetingApps.displayName(app)) toplantı adayı ama "
                              + "soğuma sürüyor — \(remaining) dk kaldı")
                }
                continue
            }

            let signal = MeetingSignal(
                bundleID: app,
                displayName: MeetingApps.displayName(app),
                isLowConfidence: MeetingApps.browsers.contains(app),
                hasOutput: process.usesOutput,
                since: since)

            lastSuggestion[app] = now
            if settings.alwaysRecordBundleIDs.contains(app) {
                Log.info(.pipeline, "Otomatik kayıt: \(signal.displayName)")
                onAutoStart?(signal)
            } else {
                Log.info(.pipeline, "Toplantı önerisi: \(signal.displayName) "
                         + "(güven \(signal.isLowConfidence ? "düşük" : "normal"))")
                pendingSignal = signal
            }
            return
        }
    }

    // MARK: - CoreAudio

    struct AudioProcessState {
        let bundleID: String
        let usesMicrophone: Bool
        let usesOutput: Bool
    }

    /// İzin gerektirmez; `AudioHardwareSystem` bundle ID ve I/O durumunu verir.
    static func activeAudioProcesses(excluding exclusions: Set<String>) -> [AudioProcessState] {
        guard let processes = try? AudioHardwareSystem.shared.processes else { return [] }
        return processes.compactMap { process in
            guard let bundleID = (try? process.bundleID) ?? nil else { return nil }
            // Dışlama ana uygulama üzerinden de bakılır: kullanıcı Teams'i
            // dışladıysa yardımcı süreci de dışlanmış sayılır.
            let resolved = MeetingApps.resolve(bundleID)
            guard !exclusions.contains(bundleID),
                  !(resolved.map(exclusions.contains) ?? false) else { return nil }
            let input = (try? process.isRunningInput) ?? false
            let output = (try? process.isRunningOutput) ?? false
            guard input || output else { return nil }
            return AudioProcessState(bundleID: bundleID, usesMicrophone: input, usesOutput: output)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
