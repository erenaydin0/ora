import Foundation
import Observation
import AVFoundation

/// Canlı buffer'ları o an açık olan transkripsiyona yönlendiren yönlendirici.
private final class LiveRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var target: (any LiveTranscribing)?
    func set(_ target: (any LiveTranscribing)?) { lock.withLock { self.target = target } }
    var current: (any LiveTranscribing)? { lock.withLock { target } }
}

/// Kayıt **sırasındaki** eşzamanlı iki işi yürütür (CLAUDE.md, İşlem Hattı §1):
/// ses diske yazılır (birincil) ve canlı transkripsiyon koşar (en iyi çaba).
///
/// `MeetingPipeline`'ın kayıt-öncesi karşılığıdır: o kayıt bittikten sonrasını
/// yürütür, bu kayıt sürerkenini. Sırayı ikisi de değil, `RecordingController`
/// kurar — hangi toplantının yaratılacağı, takvimle eşleşeceği ve ne zaman
/// hatta devredileceği onun kararı.
///
/// `ora/Capture/` altında **değil**: Capture ile Transcribe'ı birlikte kullanır
/// ve ARCHITECTURE.md'nin bağımlılık yönü alt modüllerin birbirini çağırmasını
/// yasaklar.
@MainActor
@Observable
final class RecordingSession {

    /// Yakalama durumu — `AudioCapturing.state` akışından gelir.
    private(set) var state: CaptureState = .idle
    /// Kanal başına anlık ses seviyesi (0…1).
    ///
    /// **Şu anda hiçbir arayüz bunu okumuyor.** Menü bar native `NSMenu`'ye
    /// geçtiğinde (`.menuBarExtraStyle(.menu)`) seviye göstergesi düştü, besleyen
    /// zamanlayıcı kaldı: kayıt boyunca 100 ms'de bir boşa yazılıyor. Göstergeyi
    /// geri getirmek ya da bu alanı `AudioCapturing.levels` ile birlikte silmek
    /// ayrı bir karardır (REFACTOR.md §10).
    private(set) var channelLevels: [Int: Float] = [:]
    /// Şu anda kaydedilen toplantının `meetings.id` değeri.
    private(set) var meetingID: Int64?

    /// Canlı transkripsiyonun kesinleşmiş satırları.
    private(set) var liveSegments: [Segment] = []
    /// Kanal başına henüz kesinleşmemiş metin — ekranda akan kısım.
    private(set) var volatileText: [Int: String] = [:]
    /// Canlı transkripsiyon duraklatıldıysa Türkçe not. Kayıt **etkilenmez**;
    /// bu yalnızca bilgidir.
    private(set) var liveNotice: String?

    var isRecording: Bool { state.isRecording }
    var elapsed: TimeInterval { state.elapsed }

    var micOnlyReason: String? {
        if case .micOnly(let reason, _) = state { return reason }
        return nil
    }

    /// Yakalama akışı hata bildirdiğinde çağrılır — hata kullanıcıya
    /// controller üzerinden ulaşır.
    var onError: ((OraError) -> Void)?

    private let capture: any AudioCapturing
    /// Canlı transkripsiyonu üreten çağrı. Kayıt başına yeni bir örnek kurulur.
    private let makeLive: @MainActor () -> any LiveTranscribing
    private let route = LiveRoute()
    private var live: (any LiveTranscribing)?
    private var liveUpdatesTask: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?

    /// Seviye göstergesinin tazelenme aralığı. Ses yoluna dokunmaz, yalnızca
    /// son tepe değerini okur.
    private static let levelInterval: Duration = .milliseconds(100)

    init(capture: any AudioCapturing,
         makeLive: @escaping @MainActor () -> any LiveTranscribing = { LiveTranscription() }) {
        self.capture = capture
        self.makeLive = makeLive

        observation = Task { [weak self] in
            guard let stream = self?.capture.state else { return }
            for await next in stream {
                self?.state = next
                if case .failed(let error) = next { self?.onError?(error) }
            }
        }
        // Canlı transkripsiyon **ikincil** tüketicidir: geri kalırsa buffer
        // düşer, diske yazım hiçbir koşulda beklemez.
        feedTask = Task { [route, capture] in
            for await buffer in capture.liveBuffers {
                await route.current?.feed(buffer)
            }
        }
    }

    // MARK: - Kayıt

    /// Ses yazımını başlatır. Başarısız olursa oturum açılmaz ve hata fırlatılır;
    /// çağıran yarım kalan toplantı satırını siler.
    func start(meetingID: Int64, preferredApp: String?) async throws {
        try await capture.start(meetingID: meetingID, preferredApp: preferredApp)
        self.meetingID = meetingID
        startLevelUpdates()
    }

    /// Ses yazımını kapatır ve stereo WAV yolunu döndürür.
    func stop() async throws -> URL {
        levelTask?.cancel()
        levelTask = nil
        channelLevels = [:]
        await stopLive()
        defer { meetingID = nil }
        return try await capture.stop()
    }

    private func startLevelUpdates() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRecording else { return }
                self.channelLevels = self.capture.levels
                try? await Task.sleep(for: Self.levelInterval)
            }
        }
    }

    // MARK: - Canlı transkripsiyon (en iyi çaba)

    /// Kayıt başladıktan **sonra** çağrılır. Hata verirse veya duraklarsa
    /// kayıt kesintisiz sürer; kayıt sonrası tam geçiş açığı kapatır.
    func startLive(locale: Locale, vocabulary: [String]) async {
        let live = makeLive()
        self.live = live
        route.set(live)
        await live.start(locale: locale, vocabulary: vocabulary)

        if await live.isPaused {
            liveNotice = await live.pauseReason
            route.set(nil)
            self.live = nil
            return
        }
        liveUpdatesTask = Task { [weak self] in
            for await update in live.updates {
                self?.apply(update)
            }
        }
    }

    private func stopLive() async {
        route.set(nil)
        liveUpdatesTask?.cancel()
        liveUpdatesTask = nil
        if let live { await live.finish() }
        live = nil
        volatileText = [:]
    }

    private func apply(_ update: LiveUpdate) {
        if update.isFinal {
            volatileText[update.channel.rawValue] = nil
            liveSegments.append(Segment(channel: update.channel,
                                        speaker: update.channel.speaker,
                                        text: update.text, start: update.start,
                                        end: update.end, confidence: nil, words: []))
            liveSegments.sort { $0.start < $1.start }
        } else {
            volatileText[update.channel.rawValue] = update.text
        }
    }

    /// Canlı ön izlemeyi temizler: tam geçiş sonucu geldi, başka bir toplantı
    /// yüklendi ya da yeni bir kayıt başlıyor.
    func clearLive() {
        liveSegments = []
        volatileText = [:]
        liveNotice = nil
    }
}
