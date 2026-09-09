import Foundation
import Speech
import AVFoundation
import CoreMedia

/// Kayıt sonrası **tam geçiş** transkripsiyonu.
///
/// Stereo WAV iki mono akışa ayrılır ve **her kanal ayrı** transkribe edilir —
/// diarization gerekmez, kanal ayrımı "ben vs. karşı taraf"ı zaten çözer.
/// Sessiz kanal atlanır.
nonisolated final class SpeechTranscription: Transcribing {

    /// Bu eşiğin altında tepe genliği olan kanal "sessiz" sayılır ve atlanır.
    /// −46 dBFS civarı: oda gürültüsünü eler, kısık konuşmayı elemez.
    private static let silenceThreshold: Float = 0.005

    /// Analiz motoruna beslenen parça boyutu (kaynak frame cinsinden).
    private static let chunkFrames: AVAudioFrameCount = 16_000

    @concurrent func transcribe(url: URL, locale: Locale, vocabulary: [String],
                    progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        try await transcribe(url: url, locale: locale, vocabulary: vocabulary,
                             channels: Channel.allCases, limit: nil, progress: progress)
    }

    /// - Parameters:
    ///   - channels: yalnızca bu kanallar çözülür (otomatik dil seçimi tek kanal ister)
    ///   - limit: yalnızca ilk bu kadar saniye çözülür (otomatik dil seçimi için)
    @concurrent func transcribe(url: URL, locale: Locale, vocabulary: [String],
                    channels: [Channel], limit: TimeInterval?,
                    progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {

        Log.debug(.transcribe, "Tam geçiş: kanal tepeleri ölçülüyor")
        let levels = try Self.channelPeaks(url: url)
        Log.debug(.transcribe, "Tam geçiş: tepeler "
                  + levels.map { String(format: "%.4f", $0) }.joined(separator: " / "))
        var active = channels.filter { levels[$0.rawValue] > Self.silenceThreshold }
        for channel in channels where levels[channel.rawValue] <= Self.silenceThreshold {
            Log.info(.transcribe, "\(channel.databaseValue) kanalı sessiz, atlandı "
                     + String(format: "(tepe %.4f)", levels[channel.rawValue]))
        }
        guard !active.isEmpty else {
            Log.warning(.transcribe, "Tüm kanallar sessiz — çözülecek ses yok")
            return []
        }
        active.sort { $0.rawValue < $1.rawValue }
        let activeCount = active.count

        // Sözlük bir kez derlenir, iki kanalda da aynı yapılandırma kullanılır.
        let modelConfiguration = await CustomVocabulary.configuration(for: vocabulary,
                                                                      locale: locale)

        var all: [Segment] = []
        for (index, channel) in active.enumerated() {
            let segments = try await transcribeChannel(
                url: url, channel: channel, locale: locale,
                modelConfiguration: modelConfiguration, limit: limit
            ) { fraction in
                progress((Double(index) + fraction) / Double(activeCount))
            }
            all.append(contentsOf: segments)
        }
        // Kanallar ortak zaman ekseninde birleştirilir.
        all.sort { $0.start < $1.start }
        progress(1)
        return all
    }

    // MARK: - Tek kanal

    private func transcribeChannel(url: URL, channel: Channel, locale: Locale,
                                   modelConfiguration: SFSpeechLanguageModel.Configuration?,
                                   limit: TimeInterval?,
                                   progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {

        let transcriber = Self.makeTranscriber(locale: locale,
                                               modelConfiguration: modelConfiguration,
                                               live: false)
        try await TranscriptionLocale.ensureInstalled(locale, module: transcriber) { _ in }

        guard let analysisFormat = await SpeechAnalyzer
            .bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw OraError.transcriptionFailed(underlying: TranscriptionSetupError(
                reason: "Konuşma motoruyla uyumlu bir ses formatı bulunamadı"))
        }

        Log.debug(.transcribe, "\(channel.databaseValue) kanalı: motor hazır, ses açılıyor")

        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard sourceFormat.channelCount > UInt32(channel.rawValue) else { return [] }

        let collector = Task { () -> [Segment] in
            var out: [Segment] = []
            do {
                for try await result in transcriber.results {
                    guard result.isFinal else { continue }
                    if let segment = Self.segment(from: result, channel: channel) {
                        out.append(segment)
                    }
                }
            } catch {
                Log.error(.transcribe, "\(channel.databaseValue) kanalı sonuç akışı hatası", error)
            }
            return out
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let totalFrames = limit.map { AVAudioFramePosition($0 * sourceFormat.sampleRate) }
            .map { min($0, file.length) } ?? file.length

        let feeder = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            guard let converter = AVAudioConverter(from: Self.monoFormat(sourceFormat),
                                                   to: analysisFormat) else { return }
            var position: AVAudioFramePosition = 0
            while position < totalFrames {
                let want = AVAudioFrameCount(min(Int64(Self.chunkFrames),
                                                 Int64(totalFrames - position)))
                guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                   frameCapacity: want) else { break }
                do { try file.read(into: input, frameCount: want) } catch { break }
                guard input.frameLength > 0 else { break }
                position += AVAudioFramePosition(input.frameLength)

                guard let mono = Self.extract(channel: channel, from: input),
                      let converted = Self.convert(mono, using: converter, to: analysisFormat)
                else { continue }

                // Damga verilmez: dosya akışı kesintisizdir ve analiz motoru kendi
                // zaman eksenini kurar. Kaynak konumundan hesaplanan damga,
                // yeniden örneklenmiş buffer'ın süresiyle birebir tutmadığı için
                // "timestamp overlaps or precedes prior audio input" hatası verirdi.
                continuation.yield(AnalyzerInput(buffer: converted))
                progress(Double(position) / Double(max(totalFrames, 1)))
            }
        }

        do {
            _ = try await analyzer.analyzeSequence(stream)
            await feeder.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            feeder.cancel()
            collector.cancel()
            Log.error(.transcribe, "\(channel.databaseValue) kanalı analiz edilemedi", error)
            throw OraError.transcriptionFailed(underlying: error)
        }

        let segments = await collector.value
        Log.info(.transcribe, "\(channel.databaseValue) kanalı çözüldü — \(segments.count) segment")
        return segments
    }

    // MARK: - Yardımcılar

    /// Özel sözlük verilmişse `ContentHint.customizedLanguage` ile eklenir —
    /// vocabulary özelliğinin arka ucu budur, ayrı bir düzeltme katmanı yoktur.
    static func makeTranscriber(locale: Locale,
                                modelConfiguration: SFSpeechLanguageModel.Configuration? = nil,
                                live: Bool) -> DictationTranscriber {
        // `.punctuation` Türkçe'de etkisiz (RESEARCH.md §2) — noktalama hat
        // adımı 4'te Foundation Models ile geri konur.
        var hints: Set<DictationTranscriber.ContentHint> = [.farField]
        if let modelConfiguration {
            hints.insert(.customizedLanguage(modelConfiguration: modelConfiguration))
        }
        return DictationTranscriber(
            locale: locale,
            contentHints: hints,
            transcriptionOptions: [.punctuation],
            reportingOptions: live ? [.volatileResults, .frequentFinalization]
                                   : [.frequentFinalization],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    /// Sonuçtaki `AttributedString` run'larından kelime zamanları ve güven skorları.
    static func segment(from result: DictationTranscriber.Result,
                        channel: Channel) -> Segment? {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var words: [WordTiming] = []
        for run in result.text.runs {
            let piece = String(result.text[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty, let range = run.audioTimeRange else { continue }
            words.append(WordTiming(text: piece,
                                    start: range.start.seconds,
                                    end: range.end.seconds,
                                    confidence: run.transcriptionConfidence))
        }
        let scores = words.compactMap(\.confidence)
        return Segment(channel: channel,
                       speaker: channel.speaker,
                       text: text,
                       start: result.range.start.seconds,
                       end: result.range.end.seconds,
                       confidence: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
                       words: words)
    }

    static func monoFormat(_ source: AVAudioFormat) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate,
                      channels: 1, interleaved: false)!
    }

    /// Stereo buffer'dan tek kanalı mono buffer olarak çıkarır.
    static func extract(channel: Channel, from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let format = monoFormat(buffer.format)
        guard frames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frames)),
              let destination = out.floatChannelData?[0]
        else { return nil }
        let lane = min(Int(buffer.format.channelCount) - 1, channel.rawValue)
        destination.update(from: source[lane], count: frames)
        out.frameLength = AVAudioFrameCount(frames)
        return out
    }

    static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
                        to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return nil }
        let input = SingleShotInput(buffer)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in input.next(status) }
        if let error {
            Log.warning(.transcribe, "Format dönüşümü hatası: \(error.localizedDescription)")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    /// Kanal başına tepe genlik — sessiz kanalı atlamak için.
    static func channelPeaks(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        var peaks = [Float](repeating: 0, count: Int(format.channelCount))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768)
        else { return peaks }
        // Dosya sonuna kadar oku. **Sınır `framePosition < length` ile çizilir:**
        // `AVAudioFile.read` dosya sonunda hata nesnesi kurmadan başarısız
        // olabiliyor ve köprü `_GenericObjCError.nilError` fırlatıyor. Ölçüldü:
        // 49 sn'lik gerçek bir kayıtta kayıt sonrası tam geçiş, sesi çözebilecek
        // durumdayken tepe ölçümünde bu hatayla düşüyordu (RESEARCH.md §22).
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer)
            } catch {
                // Okunacak frame kalmadıysa bu dosyanın sonudur; ortada kalan
                // gerçek bir okuma hatası ise yutulmaz, yukarı taşınır.
                guard file.framePosition >= file.length else { throw error }
                break
            }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for lane in 0 ..< Int(format.channelCount) {
                for frame in 0 ..< Int(buffer.frameLength) {
                    peaks[lane] = max(peaks[lane], abs(data[lane][frame]))
                }
            }
        }
        file.framePosition = 0
        return peaks
    }
}
