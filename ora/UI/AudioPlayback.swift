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
/// **Kanal seçici ora'ya özgüdür.** Kayıt stereo yazıldığı için (ch0 = mikrofon,
/// ch1 = sistem sesi) tek bir kanalı yalnız dinlemek mümkün; gürültülü bir
/// kayıtta karşı tarafı tek başına dinlemek transkripti doğrulamanın en hızlı
/// yoludur. Seçilen kanal **iki çıkışa da** kopyalanır — tek kulakta ses
/// dinletmek için değil, o kanalı yalıtmak için yapılıyor.
@MainActor
@Observable
final class AudioPlayback {

    /// Hangi kanal duyulacak.
    enum Mode: String, CaseIterable, Identifiable {
        case mix, mic, system

        var id: String { rawValue }

        var label: String {
            switch self {
            case .mix:    "Karışım"
            case .mic:    Channel.mic.speaker
            case .system: Channel.system.speaker
            }
        }

        /// `nil` = iki kanal birlikte.
        var channel: Channel? {
            switch self {
            case .mix:    nil
            case .mic:    .mic
            case .system: .system
            }
        }
    }

    // MARK: - Yayınlanan durum

    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false

    /// Ses diskte yoksa oynatıcı hiç görünmez.
    var isAvailable: Bool { file != nil }

    var mode: Mode = .mix {
        didSet { if mode != oldValue { seek(to: currentTime) } }
    }

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
            isolate(into: buffer)
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

    /// Seçili kanalı diğer çıkışlara kopyalar. `AVAudioFile.processingFormat`
    /// her zaman ayrık (non-interleaved) float32'dir, bu yüzden kanal
    /// düzlemleri doğrudan kopyalanabilir.
    private func isolate(into buffer: AVAudioPCMBuffer) {
        guard let source = mode.channel?.rawValue,
              let data = buffer.floatChannelData,
              buffer.format.channelCount > 1,
              source < Int(buffer.format.channelCount)
        else { return }
        let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
        for target in 0..<Int(buffer.format.channelCount) where target != source {
            memcpy(data[target], data[source], bytes)
        }
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

/// Toplantı panelinin altındaki oynatıcı şeridi.
///
/// Özet ve Transkript sekmelerinin **altında** durur, ikisinde de görünür:
/// özet maddesinden ses o an çalınabilsin diye (COMPETITION.md §4.3) ve
/// görünmeyen bir yüzeyden ses gelmesin diye.
struct PlaybackBar: View {

    @Bindable var playback: AudioPlayback

    var body: some View {
        HStack(spacing: 12) {
            Button(action: playback.toggle) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInk)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(playback.isPlaying ? "Duraklat" : "Çal")
            .accessibilityLabel(playback.isPlaying ? "Duraklat" : "Çal")

            Text(AudioPlayback.timeLabel(playback.currentTime))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.oraInk)

            Slider(value: Binding(get: { playback.currentTime },
                                  set: { playback.seek(to: $0) }),
                   in: 0...max(playback.duration, 1))
                .controlSize(.small)
                .accessibilityLabel("Kaydın konumu")

            Text(AudioPlayback.timeLabel(playback.duration))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.oraInkMuted)

            // Kanal seçici: stereo kaydın kullanıcıya ilk kez görünür değeri.
            Picker("", selection: $playback.mode) {
                ForEach(AudioPlayback.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .help("Hangi kanalı duyacağınızı seçin")

            Menu("\(rateLabel)×") {
                ForEach(AudioPlayback.rates, id: \.self) { value in
                    Button("\(Self.label(value))×") { playback.rate = value }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Oynatma hızı")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.oraChrome)
        .overlay(alignment: .top) { Divider().overlay(Color.oraBorder) }
    }

    private var rateLabel: String { Self.label(playback.rate) }

    private static func label(_ value: Float) -> String {
        value == value.rounded() ? String(Int(value))
                                 : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}
