// Faz 8 probe: oynatıcı (ora/UI/AudioPlayback.swift) motorunun üç iddiası.
//
//  1. Kanal yalıtımı: seçilen kanal diğer düzleme birebir kopyalanıyor mu?
//  2. Grafik gerçekten ses akıtıyor mu (player → timePitch → mixer)?
//  3. `playerTime.sampleTime` **kaynak** frame'lerini mi sayıyor —
//     yani hız 1,5× iken konum hesabı bozuluyor mu?
//
// Ses çıkışına gitmez: motor manuel render modunda koşar, ölçüm sessizdir.
// Çalıştırma: swift probes/playback.swift
import AVFoundation
import Foundation

let url = URL(fileURLWithPath: "probes/kayit.wav")
guard let file = try? AVAudioFile(forReading: url) else {
    print("✗ probes/kayit.wav açılamadı — kök dizinden çalıştırın"); exit(1)
}
let format = file.processingFormat
let sampleRate = format.sampleRate
print("Dosya: \(file.length) frame, \(String(format: "%.1f", Double(file.length) / sampleRate)) sn, "
      + "\(format.channelCount) kanal, \(Int(sampleRate)) Hz, "
      + "ayrık float32: \(!format.isInterleaved)")

let chunk: AVAudioFrameCount = 8_192

func read(at frame: AVAudioFramePosition, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
    file.framePosition = frame
    do { try file.read(into: buffer, frameCount: frames) } catch { return nil }
    return buffer.frameLength > 0 ? buffer : nil
}

/// AudioPlayback.isolate ile aynı işlem.
func isolate(_ buffer: AVAudioPCMBuffer, channel: Int?) {
    guard let source = channel, let data = buffer.floatChannelData,
          buffer.format.channelCount > 1, source < Int(buffer.format.channelCount) else { return }
    let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
    for target in 0..<Int(buffer.format.channelCount) where target != source {
        memcpy(data[target], data[source], bytes)
    }
}

func rms(_ pointer: UnsafePointer<Float>, _ count: Int) -> Float {
    var sum: Float = 0
    for index in 0..<count { sum += pointer[index] * pointer[index] }
    return count == 0 ? 0 : (sum / Float(count)).squareRoot()
}

// MARK: - 1. Kanal yalıtımı

print("\n— 1. Kanal yalıtımı —")
let start: AVAudioFramePosition = AVAudioFramePosition(10 * sampleRate)   // 10. saniye
guard let reference = read(at: start, frames: chunk),
      let referenceData = reference.floatChannelData else {
    print("✗ okunamadı"); exit(1)
}
let frames = Int(reference.frameLength)
let sourceRMS = (rms(referenceData[0], frames), rms(referenceData[1], frames))
print("kaynak RMS  ch0(mic) \(String(format: "%.5f", sourceRMS.0))  "
      + "ch1(system) \(String(format: "%.5f", sourceRMS.1))")

for (name, channel) in [("mic", 0), ("system", 1)] {
    guard let buffer = read(at: start, frames: chunk), let data = buffer.floatChannelData else { continue }
    isolate(buffer, channel: channel)
    let count = Int(buffer.frameLength)
    let identical = memcmp(data[0], data[1], count * MemoryLayout<Float>.size) == 0
    let matchesSource = memcmp(data[channel], channel == 0 ? referenceData[0] : referenceData[1],
                               count * MemoryLayout<Float>.size) == 0
    print("\(name): iki düzlem aynı \(identical ? "✓" : "✗"), "
          + "kaynak kanal korunmuş \(matchesSource ? "✓" : "✗"), "
          + "RMS \(String(format: "%.5f", rms(data[0], count)))")
}

// MARK: - 2 ve 3. Grafik ve konum

func render(rate: Float, channel: Int?, seconds: Double) -> (rms: Float, source: AVAudioFramePosition,
                                                             rendered: AVAudioFramePosition) {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let timePitch = AVAudioUnitTimePitch()
    timePitch.rate = rate
    engine.attach(player)
    engine.attach(timePitch)
    engine.connect(player, to: timePitch, format: format)
    engine.connect(timePitch, to: engine.mainMixerNode, format: format)

    do {
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        try engine.start()
    } catch {
        print("✗ motor kurulamadı: \(error)"); return (0, 0, 0)
    }

    // AudioPlayback.prime + pump ile aynı: 10. saniyeden başla, üç parça ileri besle.
    var readPosition = start
    for _ in 0..<3 {
        guard let buffer = read(at: readPosition, frames: chunk) else { break }
        isolate(buffer, channel: channel)
        readPosition += AVAudioFramePosition(buffer.frameLength)
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { _ in }
    }
    player.play()

    guard let sink = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                      frameCapacity: 4_096) else { return (0, 0, 0) }
    var rendered: AVAudioFramePosition = 0
    var energy: Float = 0
    var blocks = 0
    let target = AVAudioFramePosition(seconds * sampleRate)
    while rendered < target {
        let want = AVAudioFrameCount(min(AVAudioFramePosition(sink.frameCapacity), target - rendered))
        guard (try? engine.renderOffline(want, to: sink)) == .success else { break }
        if let data = sink.floatChannelData { energy += rms(data[0], Int(sink.frameLength)); blocks += 1 }
        rendered += AVAudioFramePosition(sink.frameLength)
        if sink.frameLength == 0 { break }
    }

    // AudioPlayback.refreshTime ile aynı hesap.
    var consumed: AVAudioFramePosition = 0
    if let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) {
        consumed = playerTime.sampleTime
    }
    player.stop()
    engine.stop()
    return (blocks == 0 ? 0 : energy / Float(blocks), consumed, rendered)
}

// Beklenen enerji kaynağın kendisidir: bu kayıtta sistem kanalı 10. saniyede
// gerçekten sessiz, o yüzden sabit bir eşik değil kaynakla karşılaştırılır.
print("\n— 2. Grafik akıyor mu (1 sn render, 10. saniyeden) —")
for (name, channel) in [("mix", nil), ("mic", 0), ("system", 1)] as [(String, Int?)] {
    let result = render(rate: 1, channel: channel, seconds: 1)
    let expected = channel == 1 ? sourceRMS.1 : sourceRMS.0
    let ok = expected < 0.0001 ? result.rms < 0.0001
                               : result.rms > expected * 0.5
    print("\(name): çıkış RMS \(String(format: "%.5f", result.rms)), "
          + "kaynak \(String(format: "%.5f", expected)) "
          + (ok ? "✓" : "✗"))
}

print("\n— 3. Hız değişince konum hesabı —")
for rate in [Float(1), 1.5, 2] {
    let result = render(rate: rate, channel: nil, seconds: 1)
    // Beklenen: kaynak = hız × render. Fark, timePitch'in kendi tamponunun
    // ileriden okumasıdır ve **sabittir**; oransal değil, milisaniye olarak bakılır.
    let expected = Double(result.rendered) * Double(rate)
    let leadMS = (Double(result.source) - expected) / sampleRate * 1000
    print("hız \(rate)×: render \(result.rendered) frame, playerTime \(result.source) kaynak frame, "
          + "beklenen \(Int(expected)), ileri kaçak \(String(format: "%.0f", leadMS)) ms "
          + (abs(leadMS) < 250 ? "✓" : "✗ konum sapıyor"))
}
