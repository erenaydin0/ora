import AVFoundation
import Observation
import SwiftUI

/// Kaydedilmiş bir toplantının sesini çalar ve transkriptle aynı zaman eksenini
/// paylaşır.
///
/// **Ses akış hâlinde okunur** (0,5 sn'lik parçalar, ileriye üç parça).
/// Dosya hiçbir zaman tamamen belleğe alınmaz: kural #12 yazma tarafı için
/// yazılmıştı ama aynı disiplin okuma tarafında da geçerli — bir saatlik kayıt
/// 230 MB'tır.
///
/// Kayıt iki kanallı yazılır (ch0 = mikrofon, ch1 = sistem sesi) ama oynatma
/// **karışımdır**: kanal seçici kullanıcı kararıyla kaldırıldı — dinlerken
/// yapılan iş kaydı gözden geçirmek, kanal ayıklamak değil. Ölçümü
/// RESEARCH.md §25.1'de duruyor.
@MainActor
@Observable
final class AudioPlayback {

    // MARK: - Yayınlanan durum

    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false

    /// Ses diskte yoksa oynatıcı hiç görünmez.
    var isAvailable: Bool { file != nil }

    /// Konuşma 1,5×'te rahat dinlenir; perde korunur (`AVAudioUnitTimePitch`).
    var rate: Float = 1 {
        didSet { timePitch.rate = rate }
    }

    static let rates: [Float] = [1, 1.5, 2]

    // MARK: - Motor

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    private var file: AVAudioFile?
    /// Dosyadan okunacak sıradaki frame.
    private var readPosition: AVAudioFramePosition = 0
    /// Bu çalma turunun başladığı frame — `playerTime` her `stop()`'ta sıfırlanır.
    private var baseFrame: AVAudioFramePosition = 0
    private var pending = 0
    private var reachedEnd = false
    /// Zamanlanmış buffer var mı; yoksa `play()` önce besleme yapar.
    private var isPrimed = false
    private var ticker: Task<Void, Never>?

    /// 0,5 sn @ 16 kHz. Küçük parça, seek gecikmesini kısa tutar.
    private static let chunk: AVAudioFrameCount = 8_192
    private static let lookahead = 3

    private var sampleRate: Double { file?.processingFormat.sampleRate ?? 16_000 }

    init() {
        engine.attach(player)
        engine.attach(timePitch)
    }

    // MARK: - Yükleme

    /// Seçili toplantının sesi. `nil` verilirse oynatıcı kapanır.
    func load(_ url: URL?) {
        teardown()
        file = nil
        duration = 0
        currentTime = 0
        guard let url,
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else { return }
        do {
            let opened = try AVAudioFile(forReading: url)
            guard opened.length > 0 else { return }
            file = opened
            duration = Double(opened.length) / opened.processingFormat.sampleRate
            engine.connect(player, to: timePitch, format: opened.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: opened.processingFormat)
            timePitch.rate = rate
        } catch {
            Log.warning(.ui, "Ses dosyası açılamadı: \(error.localizedDescription)")
            file = nil
        }
    }

    // MARK: - Aktarım

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard file != nil else { return }
        // Sonuna gelmiş bir kayıtta oynat düğmesi baştan başlatır.
        if currentTime >= duration - 0.05 { prime(at: 0) }
        if !isPrimed { prime(at: currentTime) }
        guard startEngine() else { return }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        guard isPlaying else { return }
        refreshTime()
        player.pause()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }

    /// Verilen ana atlar. Çalıyorsa çalmaya devam eder.
    func seek(to time: TimeInterval) {
        guard file != nil else { return }
        let wasPlaying = isPlaying
        ticker?.cancel()
        ticker = nil
        player.stop()
        isPlaying = false
        prime(at: time)
        if wasPlaying { play() }
    }

    /// Transkript satırından "buradan çal".
    func play(from time: TimeInterval) {
        guard file != nil else { return }
        seek(to: time)
        if !isPlaying { play() }
    }

    // MARK: - Besleme

    /// Okuma konumunu verilen ana kurar ve ilk parçaları zamanlar.
    private func prime(at time: TimeInterval) {
        guard let file else { return }
        let frame = AVAudioFramePosition(max(0, min(time, duration)) * sampleRate)
        player.stop()
        readPosition = min(frame, file.length)
        baseFrame = readPosition
        currentTime = Double(readPosition) / sampleRate
        pending = 0
        reachedEnd = false
        pump()
        isPrimed = true
    }

    private func pump() {
        guard let file else { return }
        while pending < Self.lookahead, !reachedEnd {
            let remaining = file.length - readPosition
            guard remaining > 0 else { reachedEnd = true; break }
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(Self.chunk), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: frames) else { break }
            do {
                file.framePosition = readPosition
                try file.read(into: buffer, frameCount: frames)
            } catch {
                Log.warning(.ui, "Ses okunamadı: \(error.localizedDescription)")
                reachedEnd = true
                break
            }
            guard buffer.frameLength > 0 else { reachedEnd = true; break }
            readPosition += AVAudioFramePosition(buffer.frameLength)
            pending += 1
            player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                Task { @MainActor in self?.consumed() }
            }
        }
    }

    private func consumed() {
        pending = max(0, pending - 1)
        guard isPlaying else { return }
        pump()
        if pending == 0, reachedEnd { finish() }
    }

    private func finish() {
        player.stop()
        isPlaying = false
        isPrimed = false
        ticker?.cancel()
        ticker = nil
        currentTime = duration
    }

    // MARK: - Zaman

    private func startEngine() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            Log.error(.ui, "Ses motoru başlatılamadı", error)
            return false
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isPlaying else { return }
                self.refreshTime()
            }
        }
    }

    /// Konum, çalınan **kaynak** frame sayısından okunur; hız değişimi bu sayıyı
    /// bozmaz çünkü `playerTime` oynatıcı düğümünün kendi zaman eksenidir.
    private func refreshTime() {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return }
        let frames = baseFrame + playerTime.sampleTime
        currentTime = min(duration, max(0, Double(frames) / sampleRate))
    }

    private func teardown() {
        ticker?.cancel()
        ticker = nil
        isPlaying = false
        isPrimed = false
        pending = 0
        reachedEnd = false
        readPosition = 0
        baseFrame = 0
        player.stop()
        if engine.isRunning { engine.stop() }
    }

    /// Belirli bir anda çalınan segment — transkriptte satır vurgusu için.
    func activeSegmentID(in segments: [Segment]) -> Segment.ID? {
        guard isAvailable, currentTime > 0 else { return nil }
        return segments.last { $0.start <= currentTime }
            .flatMap { $0.end >= currentTime - 1.5 ? $0.id : nil }
    }

    static func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Yüzen oynatıcı. İçeriğin **üstünde** durur, kenardan kenara bir şerit
/// çizmez: kayıt her zaman görünür bir araçtır ama sayfanın bir parçası değil.
///
/// Özet ve Transkript sekmelerinin ikisinde de görünür — özet maddesinden ses
/// o an çalınabilsin diye (COMPETITION.md §4.3) ve görünmeyen bir yüzeyden ses
/// gelmesin diye.
struct PlaybackBar: View {

    @Bindable var playback: AudioPlayback

    var body: some View {
        HStack(spacing: 10) {
            Button(action: playback.toggle) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.oraInk)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(playback.isPlaying ? "Duraklat" : "Çal")
            .accessibilityLabel(playback.isPlaying ? "Duraklat" : "Çal")

            Text(AudioPlayback.timeLabel(playback.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.oraInk)

            Slider(value: Binding(get: { playback.currentTime },
                                  set: { playback.seek(to: $0) }),
                   in: 0...max(playback.duration, 1))
                .controlSize(.mini)
                .frame(minWidth: 160)
                .accessibilityLabel("Kaydın konumu")

            Text(AudioPlayback.timeLabel(playback.duration))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.oraInkMuted)

            Menu("\(rateLabel)×") {
                ForEach(AudioPlayback.rates, id: \.self) { value in
                    Button("\(Self.label(value))×") { playback.rate = value }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Oynatma hızı")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 460)
        .background(Color.oraSurface)
        .clipShape(RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous)
                .stroke(Color.oraBorder, lineWidth: 1))
        .oraShadow()
        .padding(.bottom, 14)
    }

    private var rateLabel: String { Self.label(playback.rate) }

    private static func label(_ value: Float) -> String {
        value == value.rounded() ? String(Int(value))
                                 : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}
