import Foundation
import AVFoundation

/// Kayıt durumu. UI bu akışı dinler; sessiz bekleme yoktur.
enum CaptureState: Sendable, Equatable {
    case idle
    case recording(elapsed: TimeInterval)
    /// Sistem sesi alınamadı, kayıt yalnızca mikrofonla sürüyor. Kayıt DURMAZ.
    case micOnly(reason: String, elapsed: TimeInterval)
    case failed(OraError)

    static func == (lhs: CaptureState, rhs: CaptureState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): true
        case let (.recording(a), .recording(b)): a == b
        case let (.micOnly(ra, ea), .micOnly(rb, eb)): ra == rb && ea == eb
        case (.failed, .failed): true
        default: false
        }
    }

    var isRecording: Bool {
        switch self {
        case .recording, .micOnly: true
        case .idle, .failed: false
        }
    }

    var elapsed: TimeInterval {
        switch self {
        case .recording(let e), .micOnly(_, let e): e
        case .idle, .failed: 0
        }
    }
}

/// Canlı transkripsiyonun tükettiği ikincil akışın öğesi (Faz 3).
struct LiveBuffer: @unchecked Sendable {
    let channel: Channel
    let buffer: AVAudioPCMBuffer
    /// Kayıt başlangıcına göre saniye.
    let time: TimeInterval
}

protocol AudioCapturing: Sendable {
    /// - Parameter preferredApp: takvim etkinliğinden çıkarılan toplantı
    ///   uygulaması. Verilirse tap yalnızca onu hedefler.
    func start(meetingID: Int64, preferredApp: String?) async throws
    /// Stereo WAV yolunu döndürür.
    func stop() async throws -> URL
    var state: AsyncStream<CaptureState> { get }
    /// Kanal başına anlık seviye (0…1) — menü bar göstergesi için.
    var levels: [Int: Float] { get }
    /// Canlı transkripsiyon için ikincil tüketici akışı.
    /// Tüketici geri kalırsa buffer'lar DÜŞÜRÜLÜR — diske yazım asla beklemez.
    var liveBuffers: AsyncStream<LiveBuffer> { get }
}
