// Faz 3 probe: ora'nın kaydettiği stereo WAV'ı, uygulamadaki yolun aynısıyla
// kanal kanal çözer. `bufferStartTime` damgası VERİLMEZ — dosya akışı kesintisiz.
import Foundation
import Speech
import AVFoundation
import CoreMedia

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "kayit.wav"
let url = URL(fileURLWithPath: path)

func monoFormat(_ s: AVAudioFormat) -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: s.sampleRate,
                  channels: 1, interleaved: false)!
}
func extract(_ lane: Int, _ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let src = buf.floatChannelData else { return nil }
    let n = Int(buf.frameLength); guard n > 0 else { return nil }
    let f = monoFormat(buf.format)
    guard let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(n)),
          let dst = out.floatChannelData?[0] else { return nil }
    dst.update(from: src[min(lane, Int(buf.format.channelCount) - 1)], count: n)
    out.frameLength = AVAudioFrameCount(n)
    return out
}
func convert(_ b: AVAudioPCMBuffer, _ c: AVAudioConverter, _ f: AVAudioFormat) -> AVAudioPCMBuffer? {
    let ratio = f.sampleRate / b.format.sampleRate
    let cap = AVAudioFrameCount((Double(b.frameLength) * ratio).rounded(.up)) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: cap) else { return nil }
    var done = false; var err: NSError?
    c.convert(to: out, error: &err) { _, st in
        if done { st.pointee = .noDataNow; return nil }
        done = true; st.pointee = .haveData; return b
    }
    if err != nil { return nil }
    return out.frameLength > 0 ? out : nil
}

func run(lane: Int, name: String) async {
    let t = DictationTranscriber(
        locale: Locale(identifier: "tr-TR"),
        contentHints: [.farField],
        transcriptionOptions: [.punctuation],
        reportingOptions: [.frequentFinalization],
        attributeOptions: [.audioTimeRange, .transcriptionConfidence])

    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
        print("\(name): analiz formatı yok"); return
    }
    let file: AVAudioFile
    do { file = try AVAudioFile(forReading: url) } catch { print("\(name): dosya açılmadı \(error)"); return }
    let src = file.processingFormat

    let collector = Task { () -> [(CMTimeRange, String, Double?)] in
        var out: [(CMTimeRange, String, Double?)] = []
        do {
            for try await r in t.results where r.isFinal {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let confs = r.text.runs.compactMap { $0.transcriptionConfidence }
                out.append((r.range, text, confs.isEmpty ? nil : confs.reduce(0,+)/Double(confs.count)))
            }
        } catch { print("\(name): sonuç akışı hatası \(error)") }
        return out
    }

    let analyzer = SpeechAnalyzer(modules: [t])
    let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
    let conv = AVAudioConverter(from: monoFormat(src), to: fmt)!

    let feeder = Task.detached {
        defer { cont.finish() }
        while true {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: 16000) else { break }
            do { try file.read(into: inBuf, frameCount: 16000) } catch { break }
            if inBuf.frameLength == 0 { break }
            guard let mono = extract(lane, inBuf), let c = convert(mono, conv, fmt) else { continue }
            cont.yield(AnalyzerInput(buffer: c))     // ← damga YOK
        }
    }

    let clock = ContinuousClock(); let t0 = clock.now
    do {
        _ = try await analyzer.analyzeSequence(stream)
        await feeder.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
        print("❌ \(name): analiz hatası → \(error)")
        feeder.cancel(); collector.cancel(); return
    }
    let segs = await collector.value
    print("\n✅ \(name): \(segs.count) segment, süre \(clock.now - t0)")
    for (r, text, conf) in segs {
        let c = conf.map { String(format: " [güven %.2f]", $0) } ?? ""
        print(String(format: "   [%6.2f→%6.2f]%@ %@", r.start.seconds, r.end.seconds, c, text))
    }
}

await run(lane: 0, name: "ch0 mic")
await run(lane: 1, name: "ch1 sistem")
