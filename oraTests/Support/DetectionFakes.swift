import Foundation
import Observation
@testable import ora

/// Sahte algılayıcı. Sinyali test besler — gerçeğini CoreAudio dinleyicileri
/// üretiyor ve `pendingSignal` `private(set)`.
///
/// `@Observable` olmak **zorunlu**: öneri teslimi `withObservationTracking`
/// ile çalışıyor, sahte gözlemlenebilir değilse hiçbir şey tetiklenmez.
@Observable
final class FakeDetector: MeetingDetecting {

    var pendingSignal: MeetingSignal?
    var suggestsStop = false
    var onAutoStart: ((MeetingSignal) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var dismissCount = 0
    private(set) var recordingStartedWith: [String?] = []
    private(set) var recordingStoppedCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }

    func dismissSuggestion() {
        dismissCount += 1
        pendingSignal = nil
    }

    func recordingStarted(bundleID: String?) {
        recordingStartedWith.append(bundleID)
        suggestsStop = false
        pendingSignal = nil
    }

    func recordingStopped() {
        recordingStoppedCount += 1
        suggestsStop = false
    }

    /// Test sinyali buradan besler.
    func emit(_ signal: MeetingSignal?) { pendingSignal = signal }
}

/// Sahte bildirim yüzeyi. Gerçek tipte `isAuthorized` false olduğu için çağrı
/// sessizce düşüyor ve teslimin olup olmadığı ölçülemiyordu.
final class FakeSuggestionNotifier: SuggestionNotifying {

    var onRecord: ((String) -> Void)?
    var onDismiss: ((String) -> Void)?
    var onAlways: ((String) -> Void)?

    private(set) var suggested: [(signal: MeetingSignal, event: MeetingEvent?)] = []

    func suggestRecording(_ signal: MeetingSignal, event: MeetingEvent?) async {
        suggested.append((signal, event))
    }
}

func testSignal(_ bundleID: String = "com.microsoft.teams2",
                displayName: String = "Microsoft Teams") -> MeetingSignal {
    MeetingSignal(bundleID: bundleID, displayName: displayName,
                  isLowConfidence: false, hasOutput: true, since: Date())
}
