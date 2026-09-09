import Foundation
import AVFoundation

/// Mikrofon yakalama — `AVAudioEngine` giriş düğümüne takılan tap.
nonisolated final class MicrophoneCapture: @unchecked Sendable {

    typealias Sink = @Sendable (_ frames: [Float], _ hostTime: UInt64) -> Void

    private let engine = AVAudioEngine()
    private var resampler: MonoResampler?
    private var isRunning = false

    /// İzin daha önce verilmiş mi? İstem **çıkarmaz**.
    static func isAuthorized() async -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Mikrofon izni. Reddedilirse kayıt başlamaz — sistem sesi tek başına
    /// bir toplantı kaydı sayılmaz.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    func start(sink: @escaping Sink) throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw OraError.audioDeviceFailed(stage: "mikrofon formatı", status: -1)
        }
        guard let resampler = MonoResampler(inputSampleRate: format.sampleRate) else {
            throw OraError.audioDeviceFailed(stage: "yeniden örnekleyici", status: -1)
        }
        self.resampler = resampler

        let channelCount = Int(format.channelCount)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            var mono = [Float](repeating: 0, count: frames)
            if channelCount == 1 {
                mono.withUnsafeMutableBufferPointer {
                    $0.baseAddress!.update(from: channels[0], count: frames)
                }
            } else {
                for frame in 0 ..< frames {
                    var sum: Float = 0
                    for channel in 0 ..< channelCount { sum += channels[channel][frame] }
                    mono[frame] = sum / Float(channelCount)
                }
            }

            let resampled = resampler.resample(mono)
            guard !resampled.isEmpty else { return }
            sink(resampled, time.hostTime)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.resampler = nil
            throw OraError.audioWriteFailed(underlying: error)
        }
        isRunning = true
        Log.info(.capture, "Mikrofon açıldı — \(Int(format.sampleRate)) Hz, "
                 + "\(format.channelCount) kanal")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        resampler = nil
        isRunning = false
    }
}
