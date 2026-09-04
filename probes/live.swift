import Foundation
import Speech
import AVFoundation
import Darwin

func cpuTime() -> Double {
  var u = rusage(); getrusage(RUSAGE_SELF, &u)
  let s = Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec)/1e6
  let y = Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec)/1e6
  return s + y
}

@main
struct L {
  static func main() async {
    let url = URL(fileURLWithPath: "long.wav")
    let file = try! AVAudioFile(forReading: url)
    let dur = Double(file.length) / file.processingFormat.sampleRate
    print("ses süresi: \(String(format: "%.1f", dur)) sn — GERÇEK ZAMANLI akış simülasyonu\n")

    let t = DictationTranscriber(
      locale: Locale(identifier: "tr-TR"),
      contentHints: [.farField],
      transcriptionOptions: [.punctuation],
      reportingOptions: [.volatileResults, .frequentFinalization],
      attributeOptions: [.audioTimeRange])

    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
      print("format yok"); return }
    print("analiz formatı: \(fmt.sampleRate) Hz \(fmt.channelCount) kanal")

    let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
    let analyzer = SpeechAnalyzer(modules: [t])

    var finalCount = 0, volatileCount = 0
    var firstResultLatency: Double? = nil
    let wallStart = ContinuousClock().now

    let collector = Task {
      do {
        for try await r in t.results {
          if r.isFinal { finalCount += 1 } else { volatileCount += 1 }
          if firstResultLatency == nil {
            firstResultLatency = (ContinuousClock().now - wallStart) / .seconds(1)
          }
        }
      } catch { print("res err \(error)") }
    }

    let cpu0 = cpuTime()
    let feeder = Task {
      let conv = AVAudioConverter(from: file.processingFormat, to: fmt)!
      let chunk: AVAudioFrameCount = 16000 / 2   // 0.5 sn'lik parçalar
      while true {
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
        try? file.read(into: buf, frameCount: chunk)
        if buf.frameLength == 0 { break }
        let out = AVAudioPCMBuffer(pcmFormat: fmt,
          frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / file.processingFormat.sampleRate) + 1024)!
        var done = false
        conv.convert(to: out, error: nil) { _, st in
          if done { st.pointee = .noDataNow; return nil }
          done = true; st.pointee = .haveData; return buf
        }
        cont.yield(AnalyzerInput(buffer: out))
        try? await Task.sleep(for: .milliseconds(500))   // GERÇEK ZAMAN
      }
      cont.finish()
    }

    try? await analyzer.start(inputSequence: stream)
    await feeder.value
    try? await analyzer.finalizeAndFinishThroughEndOfInput()
    await collector.value
    let cpu = cpuTime() - cpu0
    let wall = (ContinuousClock().now - wallStart) / .seconds(1)

    print("\n=== SONUÇ ===")
    print("duvar saati      : \(String(format: "%.1f", wall)) sn (ses \(String(format: "%.1f", dur)) sn)")
    print("harcanan CPU     : \(String(format: "%.2f", cpu)) sn")
    print("CPU / gerçek zaman: \(String(format: "%.1f%%", cpu/dur*100)) (tek çekirdek eşdeğeri)")
    print("kesin sonuç      : \(finalCount) · geçici sonuç: \(volatileCount)")
    if let f = firstResultLatency { print("ilk sonuç gecikmesi: \(String(format: "%.2f", f)) sn") }
  }
}
