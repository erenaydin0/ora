import Foundation
import Testing
@testable import ora

/// Tek bir testin dünyası: bellek içi veritabanı, izole ayarlar ve gerçek
/// `RecordingController`.
///
/// Ayarlar **izole** verilir: `OraSettings.shared` geliştiricinin gerçek
/// `UserDefaults`'unu okur ve test sonucu makineye göre değişirdi.
/// Dil paketi hazırlığı ve güç durumu da devre dışı — ikisi de dış dünyaya
/// dokunuyor ve testin konusu değil.
final class Harness {

    let database: OraDatabase
    let store: MeetingStore
    let capture: FakeCapture
    let settings: OraSettings
    let controller: RecordingController
    private let suiteName: String

    init(intelligence: any Intelligent,
         localIntelligence: (any Intelligent)? = nil,
         transcription: any Transcribing = FakeTranscription(),
         deferReason: @escaping @Sendable () -> PowerState.DeferReason? = { nil },
         stopURL: URL = URL(fileURLWithPath: "/dev/null")) throws {

        suiteName = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        settings = OraSettings(defaults: defaults)
        // Algılama ve takvim kapalı: ikisi de CoreAudio ve EventKit'e dokunur.
        settings.detectionEnabled = false
        settings.calendarEnabled = false
        settings.compressAudio = false
        settings.audioRetentionDays = 0
        settings.transcriptionLanguage = .turkish

        database = try OraDatabase(path: ":memory:")
        store = MeetingStore(database: database)
        capture = FakeCapture(stopURL: stopURL)
        controller = RecordingController(capture: capture,
                                         transcription: transcription,
                                         intelligence: intelligence,
                                         localIntelligence: localIntelligence,
                                         database: database,
                                         settings: settings,
                                         deferReason: deferReason,
                                         prepareLocale: { _, progress in progress(1) })
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    /// Transkripti hazır, durumu `ready` bir toplantı yazar.
    func seed(text: String) async throws -> Int64 {
        let id = try await store.createMeeting()
        try await store.replaceTranscript(id, segments: [
            Segment(channel: .mic, speaker: "Ben", text: text,
                    start: 0, end: 10, confidence: 0.9, words: [])
        ])
        try await store.markReady(id)
        return id
    }
}

/// `condition` doğru olana kadar bekler. Hat asenkron ilerlediği için sabit
/// `sleep` yerine bu kullanılır: hem daha hızlı hem de yavaş makinede kırılmaz.
func waitUntil(_ label: String,
               timeout: Duration = .seconds(10),
               _ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("zaman aşımı: \(label)")
}

/// Kısa bir soluk — "bu an itibarıyla şu **olmamalı**" kontrollerinden önce
/// hattın bir tur ilerlemesine izin verir.
func settle(_ duration: Duration = .milliseconds(250)) async {
    try? await Task.sleep(for: duration)
}
