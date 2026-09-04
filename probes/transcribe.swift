import Foundation
import Speech
import AVFoundation

@main
struct T {
  static func main() async {
    let t = DictationTranscriber(
      locale: Locale(identifier: "tr-TR"),
      contentHints: [.farField],
      transcriptionOptions: [.punctuation],
      reportingOptions: [.frequentFinalization],
      attributeOptions: [.audioTimeRange, .transcriptionConfidence]
    )
    let analyzer = SpeechAnalyzer(modules: [t])
    let clock = ContinuousClock(); let start = clock.now

    let collector = Task { () -> [(CMTimeRange, AttributedString)] in
      var out: [(CMTimeRange, AttributedString)] = []
      do { for try await r in t.results { out.append((r.range, r.text)) } } catch { print("err \(error)") }
      return out
    }
    do {
      let file = try AVAudioFile(forReading: URL(fileURLWithPath: "tr_test.wav"))
      _ = try await analyzer.analyzeSequence(from: file)
      try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch { print("HATA \(error)"); return }

    let segs = await collector.value
    let el = clock.now - start
    print("=== \(segs.count) segment, süre \(el) ===")
    for (r, a) in segs {
      print(String(format: "[%6.2f→%6.2f] %@", r.start.seconds, r.end.seconds, String(a.characters)))
      for run in a.runs {
        let w = String(a[run.range].characters)
        let tr = run.audioTimeRange.map { String(format: "%.2f-%.2f", $0.start.seconds, $0.end.seconds) } ?? "-"
        print("      run '\(w)' t=\(tr)")
      }
    }
  }
}
