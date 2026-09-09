import Foundation
import Observation

/// `MeetingSuggestions`'ın algılamadan ihtiyaç duyduğu kadarı.
///
/// `AudioCapturing` / `Transcribing` / `Intelligent` / `LiveTranscribing` ile
/// aynı gerekçe (ARCHITECTURE.md, Test edilebilirlik). `MeetingDetector`'ı
/// sahtelemenin başka yolu yok: sinyali CoreAudio dinleyicileri üretiyor ve
/// `pendingSignal` `private(set)`. Bu protokol olmadan öneri zincirinin
/// **hiçbir** adımı ölçülemez — polling'den `withObservationTracking`'e
/// geçmek de ölçülemeyen bir değişiklik olurdu.
///
/// `Observable` kalıtımı zorunlu: öneri teslimi artık gözlemleme tabanlı ve
/// sahte algılayıcının da `@Observable` olması gerekiyor.
@MainActor
protocol MeetingDetecting: AnyObject, Observable {
    /// Öneri bekleyen sinyal. Kullanıcı karar verene kadar durur.
    var pendingSignal: MeetingSignal? { get }
    /// Toplantı uygulaması mikrofonu 30 sn'den uzun bıraktı.
    var suggestsStop: Bool { get }
    /// Otomatik başlatma ("her zaman kaydet" seçilmiş uygulamalar).
    var onAutoStart: ((MeetingSignal) -> Void)? { get set }

    func start()
    func stop()
    func dismissSuggestion()
    func recordingStarted(bundleID: String?)
    func recordingStopped()
}

extension MeetingDetector: MeetingDetecting {}
