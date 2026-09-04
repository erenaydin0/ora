import Foundation
import CoreAudio
import AVFoundation

/// İki ses kaynağının ortak zaman tabanı: mach host time.
///
/// Mikrofon (`AVAudioTime.hostTime`) ve süreç tap'i (`AudioTimeStamp.mHostTime`)
/// aynı saati kullanır. Hizalama **buffer sayısıyla değil** bu damgayla yapılır —
/// eski ora'nın çözemediği sorun buydu (ROADMAP Faz 2).
enum AudioClock {

    static var now: UInt64 { AudioGetCurrentHostTime() }

    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        guard end >= start else { return -seconds(from: end, to: start) }
        return Double(AudioConvertHostTimeToNanos(end - start)) / 1e9
    }

    /// Host time damgasının, kayıt başlangıcına göre kaçıncı frame'e denk geldiği.
    static func frameIndex(hostTime: UInt64, start: UInt64, sampleRate: Double) -> Int64 {
        Int64((seconds(from: start, to: hostTime) * sampleRate).rounded())
    }
}

/// Herhangi bir örnekleme oranındaki mono akışı kayıt formatına (16 kHz mono float32)
/// çeviren yeniden örnekleyici.
///
/// `AVAudioConverter` durumludur ve iş parçacığı güvenli değildir; her kaynak
/// kendi örneğini kendi seri kuyruğunda kullanır.
final class MonoResampler {

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    init?(inputSampleRate: Double) {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: inputSampleRate,
                                        channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: RecordingFormat.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output)
        else { return nil }
        self.inputFormat = input
        self.outputFormat = output
        self.converter = converter
        self.ratio = RecordingFormat.sampleRate / inputSampleRate
    }

    /// Mono float dizisini kayıt oranına indirir. Oran zaten aynıysa kopyalamadan döner.
    func resample(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard inputFormat.sampleRate != outputFormat.sampleRate else { return samples }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                 frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = inputBuffer.floatChannelData?[0]
        else { return [] }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }

        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                  frameCapacity: capacity)
        else { return [] }

        var supplied = false
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inputBuffer
        }
        if let error {
            Log.warning(.capture, "Yeniden örnekleme hatası: \(error.localizedDescription)")
            return []
        }
        guard let out = outputBuffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: out, count: Int(outputBuffer.frameLength)))
    }
}

/// Bir ses kaynağının host time ile hizalanmış frame konumunu takip eder.
///
/// Her buffer'ı tek tek host time'a oturtmak yeniden örnekleyicinin iç gecikmesi
/// yüzünden mikro boşluk/örtüşme üretir. Bunun yerine akış sürekli sayılır ve
/// host time'dan sapma eşiği aşarsa **yeniden çapalanır** — böylece hizalama
/// buffer sayısına değil saate bağlı kalır, ses de sürekli olur.
struct FrameAnchor {

    /// 50 ms'yi aşan sapmada yeniden çapala.
    static let tolerance: Int64 = Int64(RecordingFormat.sampleRate * 0.05)

    private var next: Int64?
    private(set) var resyncCount = 0

    /// Bu buffer'ın yazılacağı mutlak frame konumu.
    mutating func position(hostTime: UInt64, start: UInt64, producing frames: Int) -> Int64 {
        let expected = AudioClock.frameIndex(hostTime: hostTime, start: start,
                                             sampleRate: RecordingFormat.sampleRate)
        let position: Int64
        if let next, abs(next - expected) <= Self.tolerance {
            position = next
        } else {
            if next != nil { resyncCount += 1 }
            position = max(0, expected)
        }
        next = position + Int64(frames)
        return position
    }
}
