// Faz 6 probe: özel sözlük (ContentHint.customizedLanguage) Türkçe'de
// özel isim tanımayı gerçekten iyileştiriyor mu?
// Aynı ses, sözlüklü ve sözlüksüz iki geçişle karşılaştırılır.
import Foundation
import Speech
import AVFoundation

let terms = ["Datassist", "Kerem Yücesoy", "Alens", "Bordro Farkları", "CosmicDoc"]

func transcribe(url: URL, configuration: SFSpeechLanguageModel.Configuration?) async -> String {
    var hints: Set<DictationTranscriber.ContentHint> = [.farField]
    if let configuration { hints.insert(.customizedLanguage(modelConfiguration: configuration)) }
    let t = DictationTranscriber(
        locale: Locale(identifier: "tr-TR"), contentHints: hints,
        transcriptionOptions: [.punctuation],
        reportingOptions: [.frequentFinalization],
        attributeOptions: [.audioTimeRange])
    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]),
          let file = try? AVAudioFile(forReading: url) else { return "(format/dosya yok)" }

    let collector = Task { () -> String in
        var out: [String] = []
        do { for try await r in t.results where r.isFinal { out.append(String(r.text.characters)) } }
        catch { return "(hata \(error))" }
        return out.joined(separator: " ")
    }
    let analyzer = SpeechAnalyzer(modules: [t])
    let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
    let src = file.processingFormat
    let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: src.sampleRate,
                             channels: 1, interleaved: false)!
    let conv = AVAudioConverter(from: mono, to: fmt)!
    let feeder = Task.detached {
        defer { cont.finish() }
        while true {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: 16000),
                  (try? file.read(into: inBuf, frameCount: 16000)) != nil,
                  inBuf.frameLength > 0, let ch = inBuf.floatChannelData else { break }
            guard let m = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: inBuf.frameLength),
                  let d = m.floatChannelData?[0] else { break }
            d.update(from: ch[0], count: Int(inBuf.frameLength))
            m.frameLength = inBuf.frameLength
            let cap = AVAudioFrameCount((Double(m.frameLength) * fmt.sampleRate / src.sampleRate).rounded(.up)) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { break }
            var done = false
            conv.convert(to: out, error: nil) { _, st in
                if done { st.pointee = .noDataNow; return nil }
                done = true; st.pointee = .haveData; return m
            }
            if out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
        }
    }
    do {
        _ = try await analyzer.analyzeSequence(stream)
        await feeder.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch { return "(analiz hatası \(error))" }
    return await collector.value
}

@main struct V { static func main() async {
    let audio = URL(fileURLWithPath: "vocab_test.wav")
    guard FileManager.default.fileExists(atPath: audio.path) else {
        print("vocab_test.wav yok"); return }

    print("=== SÖZLÜKSÜZ ===")
    let before = await transcribe(url: audio, configuration: nil)
    print(before)

    // --- özel sözlük derle ---
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ora-vocab")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let assetURL = dir.appending(path: "data.bin")
    let lmURL = dir.appending(path: "model.bin")
    let vocabURL = dir.appending(path: "vocab.bin")

    let data = SFCustomLanguageModelData(locale: Locale(identifier: "tr-TR"),
                                         identifier: "com.orameetings.ora.vocab",
                                         version: "1")
    for term in terms {
        data.insert(phraseCount: .init(phrase: term, count: 30))
    }
    let clock = ContinuousClock(); let t0 = clock.now
    do { try await data.export(to: assetURL) }
    catch { print("export hatası: \(error)"); return }
    print("\nexport: \(clock.now - t0) · \((try? FileManager.default.attributesOfItem(atPath: assetURL.path)[.size]) ?? 0) bayt")

    let configuration = SFSpeechLanguageModel.Configuration(languageModel: lmURL, vocabulary: vocabURL)
    let t1 = clock.now
    do { try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: assetURL,
                                                                    configuration: configuration) }
    catch { print("prepare hatası: \(error)"); return }
    print("prepare: \(clock.now - t1)")

    // Ağırlık ve tekrar sayısı taraması
    var results: [(String, String)] = [("sözlüksüz", before)]
    for (label, count, weight) in [("count 30 · weight varsayılan", 30, nil as Double?),
                                   ("count 30 · weight 0.5", 30, 0.5),
                                   ("count 30 · weight 1.0", 30, 1.0),
                                   ("count 200 · weight 1.0", 200, 1.0)] {
        let d = SFCustomLanguageModelData(locale: Locale(identifier: "tr-TR"),
                                          identifier: "com.orameetings.ora.vocab",
                                          version: "\(count)-\(weight ?? -1)")
        for term in terms { d.insert(phraseCount: .init(phrase: term, count: count)) }
        let a = dir.appending(path: "d\(count)\(weight ?? -1).bin")
        let l = dir.appending(path: "l\(count)\(weight ?? -1).bin")
        let v = dir.appending(path: "v\(count)\(weight ?? -1).bin")
        do { try await d.export(to: a) } catch { print("\(label): export ✗"); continue }
        let cfg = weight == nil
            ? SFSpeechLanguageModel.Configuration(languageModel: l, vocabulary: v)
            : SFSpeechLanguageModel.Configuration(languageModel: l, vocabulary: v,
                                                  weight: NSNumber(value: weight!))
        do { try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: a, configuration: cfg,
                                                                        ignoresCache: true) }
        catch { print("\(label): prepare ✗ \(error)"); continue }
        results.append((label, await transcribe(url: audio, configuration: cfg)))
    }

    print("\n=== TERİM TUTMA ===")
    let header = "durum".padding(toLength: 30, withPad: " ", startingAt: 0)
        + terms.map { $0.prefix(9).padding(toLength: 10, withPad: " ", startingAt: 0) }.joined()
    print(header)
    for (label, text) in results {
        var line = label.padding(toLength: 30, withPad: " ", startingAt: 0)
        for term in terms {
            line += (text.localizedCaseInsensitiveContains(term) ? "✓" : "✗")
                .padding(toLength: 10, withPad: " ", startingAt: 0)
        }
        print(line)
    }
    print("")
    for (label, text) in results { print("\(label):\n  \(text)\n") }
} }
