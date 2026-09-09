import Foundation
import AVFoundation
import Darwin
import Testing
@testable import ora

/// `SingleShotInput`ın `@unchecked Sendable` güvencesini ve yeniden örneklemenin
/// kendisini denetler.
///
/// Swift, `AVAudioConverter`ın girdi bloğunu `@Sendable` gördüğü için tamponu
/// yakalamayı ve bayrağı değiştirmeyi "eşzamanlı koşan kod" sayıyordu. Ölçüm
/// (RESEARCH.md §31) uyarının varsayımının yanlış olduğunu gösterdi; buradaki
/// ilk test o ölçümün **testi**: Apple bir gün bloğu başka bir şeritte veya
/// `convert` döndükten sonra çağırırsa `@unchecked Sendable` yalan olur ve bu
/// test düşer.
@Suite("Ses dönüşümü")
struct AudioConversionTests {

    @Test
    func girdiBloguCagiranSeritteVeSenkronKosar() throws {
        let input = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 48_000,
                                               channels: 1, interleaved: false))
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: RecordingFormat.sampleRate,
                                                channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: input, to: output))
        let inBuffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4800))
        inBuffer.frameLength = 4800
        let outBuffer = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 2048))

        let probe = BlockProbe(buffer: inBuffer)
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in probe.next(status) }
        probe.returned = true

        #expect(error == nil)
        #expect(probe.calls == 2,
                "blok iki kez çağrılıyor — SingleShotInput'un bayrağı bu yüzden gerekli")
        #expect(probe.sameThread,
                "blok çağıranın şeridinde koşmadı — @unchecked Sendable güvencesi düştü")
        #expect(probe.callsAfterReturn == 0,
                "blok convert döndükten sonra çağrıldı — @unchecked Sendable güvencesi düştü")
    }

    /// 48 kHz → 16 kHz, tek örnek üzerinden ardışık çağrılarla.
    ///
    /// **Tek bir çağrıya bakılmaz:** dönüştürücü durumludur ve ilk çağrı filtre
    /// gecikmesi yüzünden eksik verir (ölçüldü: 4800 girdi → 1360 çıktı,
    /// ideal 1600). Sonraki çağrılar `+32` frame'lik başlıkla borcu kapatır.
    /// Ölçülen davranış: 12 çağrıda 19.045 / ideal 19.200 — açık %1'in altında
    /// ve **büyümüyor**. Bu yüzden test toplamı denetler (RESEARCH.md §31.2).
    @Test
    func yenidenOrneklemeOraniDusurur() throws {
        let resampler = try #require(MonoResampler(inputSampleRate: 48_000))
        let samples = (0..<4800).map { sinf(Float($0) * 0.01) }

        var total = 0
        var sawSignal = false
        for _ in 0..<12 {
            let out = resampler.resample(samples)
            total += out.count
            sawSignal = sawSignal || out.contains { $0 != 0 }
        }

        #expect(total > 18_800 && total <= 19_200,
                "12×4800 girdi → ideal 19.200 örnek, gelen \(total)")
        #expect(sawSignal, "çıktı sessiz kalmamalı")
    }

    @Test
    func ayniOranKopyalamadanDoner() throws {
        let resampler = try #require(MonoResampler(inputSampleRate: RecordingFormat.sampleRate))
        let samples: [Float] = [0.1, -0.2, 0.3]

        #expect(resampler.resample(samples) == samples)
        #expect(resampler.resample([]).isEmpty)
    }
}

/// Girdi bloğunun nerede ve ne zaman koştuğunu kaydeder. `SingleShotInput` ile
/// aynı gerekçeyle `@unchecked Sendable`: blok senkron ve tek şeritte koşuyor —
/// bu tipin işi tam olarak bunu doğrulamak.
private nonisolated final class BlockProbe: @unchecked Sendable {

    private let buffer: AVAudioPCMBuffer
    private let callerThread = pthread_self()

    private(set) var calls = 0
    private(set) var sameThread = true
    private(set) var callsAfterReturn = 0
    /// `convert` döndükten sonra `true` yapılır.
    var returned = false

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if returned { callsAfterReturn += 1 }
        calls += 1
        if pthread_equal(pthread_self(), callerThread) == 0 { sameThread = false }
        if calls > 1 {
            status.pointee = .noDataNow
            return nil
        }
        status.pointee = .haveData
        return buffer
    }
}
