// Faz 3 probe: canlı yolun damga düzeltmesi.
// Kayıttan gelen mutlak zamanlar bilerek bozuluyor (geri kayma + boşluk),
// kelepçe olmadan analiz motorunun hata verdiği, kelepçeyle vermediği gösteriliyor.
import Foundation
import Speech
import AVFoundation
import CoreMedia

func monoFormat(_ s: AVAudioFormat) -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: s.sampleRate,
                  channels: 1, interleaved: false)!
}

enum Mode: String { case raw, clampedSeconds, exactFrames, noStamp }

func feed(_ mode: Mode) async -> String {
    let url = URL(fileURLWithPath: "kayit.wav")
    guard let file = try? AVAudioFile(forReading: url) else { return "dosya yok" }
    let src = file.processingFormat

    let t = DictationTranscriber(
        locale: Locale(identifier: "tr-TR"), contentHints: [.farField],
        transcriptionOptions: [.punctuation],
        reportingOptions: [.volatileResults, .frequentFinalization],
        attributeOptions: [.audioTimeRange])
    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
    else { return "format yok" }

    var failure: String?
    let collector = Task {
        do { for try await _ in t.results {} }
        catch { failure = "\(error)" }
    }

    let analyzer = SpeechAnalyzer(modules: [t])
    let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
    let conv = AVAudioConverter(from: monoFormat(src), to: fmt)!

    do { try await analyzer.start(inputSequence: stream) }
    catch { return "start hatası: \(error)" }

    var absolute = 0.0
    var nextTime = 0.0
    var chunkIndex = 0
    var emittedFrames: Int64 = 0
    while true {
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: 8000),
              (try? file.read(into: inBuf, frameCount: 8000)) != nil,
              inBuf.frameLength > 0 else { break }
        guard let src0 = inBuf.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat(src),
                                          frameCapacity: inBuf.frameLength),
              let dst = mono.floatChannelData?[0] else { break }
        dst.update(from: src0[0], count: Int(inBuf.frameLength))
        mono.frameLength = inBuf.frameLength

        let cap = AVAudioFrameCount((Double(mono.frameLength) * fmt.sampleRate
                                     / src.sampleRate).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { break }
        var done = false
        conv.convert(to: out, error: nil) { _, st in
            if done { st.pointee = .noDataNow; return nil }
            done = true; st.pointee = .haveData; return mono
        }
        guard out.frameLength > 0 else { continue }

        // Gerçek hayattaki bozulmalar: her 5. parçada 40 ms geri kayma,
        // her 9. parçada buffer düşmesi (ileri sıçrama).
        var stamp = absolute
        if chunkIndex % 5 == 4 { stamp -= 0.040 }
        if chunkIndex % 9 == 8 { stamp += 0.100 }

        switch mode {
        case .noStamp:
            cont.yield(AnalyzerInput(buffer: out))
        case .raw:
            cont.yield(AnalyzerInput(buffer: out,
                bufferStartTime: CMTime(seconds: stamp, preferredTimescale: 48_000)))
        case .clampedSeconds:
            let start = max(stamp, nextTime)
            nextTime = start + Double(out.frameLength) / fmt.sampleRate
            cont.yield(AnalyzerInput(buffer: out,
                bufferStartTime: CMTime(seconds: start, preferredTimescale: 48_000)))
        case .exactFrames:
            // Damga analiz oranında TAM frame sayısı olarak kurulur; yuvarlama yok.
            let rate = Int32(fmt.sampleRate)
            let wanted = Int64((stamp * fmt.sampleRate).rounded())
            let start = max(wanted, emittedFrames)
            emittedFrames = start + Int64(out.frameLength)
            cont.yield(AnalyzerInput(buffer: out,
                bufferStartTime: CMTime(value: start, timescale: rate)))
        }
        absolute += Double(mono.frameLength) / src.sampleRate
        chunkIndex += 1
    }
    cont.finish()
    try? await analyzer.finalizeAndFinishThroughEndOfInput()
    _ = await collector.value
    return failure ?? "hata yok"
}

for mode in [Mode.raw, .clampedSeconds, .exactFrames, .noStamp] {
    print(String(format: "%-16@ → %@", mode.rawValue as NSString, await feed(mode) as NSString))
}
