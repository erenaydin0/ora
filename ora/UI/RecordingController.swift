import Foundation
import Observation

/// Kayıt yüzeyinin durum sahibi. UI yalnızca buraya bakar; Capture'ı doğrudan çağırmaz.
///
/// Faz 5'te bu tip `Pipeline`'ın arkasına geçecek. Şimdilik Capture'ı doğrudan sürüyor.
@MainActor
@Observable
final class RecordingController {

    private(set) var state: CaptureState = .idle
    private(set) var lastRecording: URL?
    private(set) var interrupted: [InterruptedRecording] = []
    var error: OraError?

    private let capture: any AudioCapturing
    /// Uygulama ömrü boyunca yaşar; Capture akışı bitince kendiliğinden sonlanır.
    private var observation: Task<Void, Never>?

    init(capture: any AudioCapturing = AudioCapture()) {
        self.capture = capture
        observation = Task { [weak self] in
            guard let stream = self?.capture.state else { return }
            for await next in stream {
                self?.state = next
                if case .failed(let error) = next { self?.error = error }
            }
        }
    }

    var isRecording: Bool { state.isRecording }

    var elapsedText: String {
        let total = Int(state.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var micOnlyReason: String? {
        if case .micOnly(let reason, _) = state { return reason }
        return nil
    }

    // MARK: - Eylemler

    func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    func start() async {
        guard !isRecording else { return }
        do {
            try await capture.start(meetingID: Self.provisionalMeetingID())
        } catch let error as OraError {
            self.error = error
        } catch {
            self.error = .audioWriteFailed(underlying: error)
        }
    }

    func stop() async {
        guard isRecording else { return }
        do {
            lastRecording = try await capture.stop()
        } catch let error as OraError {
            self.error = error
        } catch {
            self.error = .audioWriteFailed(underlying: error)
        }
    }

    // MARK: - Çökme kurtarma

    func scanForInterruptedRecordings() {
        interrupted = RecordingRecovery.scan()
    }

    func keep(_ recording: InterruptedRecording) {
        RecordingRecovery.keep(recording)
        interrupted.removeAll { $0.id == recording.id }
    }

    func discard(_ recording: InterruptedRecording) {
        RecordingRecovery.discard(recording)
        interrupted.removeAll { $0.id == recording.id }
    }

    /// Faz 5'te `meetings` tablosuna satır eklenip gerçek id kullanılacak.
    /// O zamana kadar dosya adı için çakışmayan bir zaman damgası yeter.
    private static func provisionalMeetingID() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
