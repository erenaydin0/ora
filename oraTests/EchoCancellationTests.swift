import CoreAudio
import Foundation
import Testing
@testable import ora

/// Yankı bastırma: kulaklık/hoparlör kararı ve ayarın kayda ulaşması.
/// Ses işlemenin akustik etkisi burada ölçülmez; ölçülen politika.
@Suite("Yankı bastırma", .serialized)
struct EchoCancellationTests {

    @Test
    func kulaklikVeHoparlorAyrilir() {
        typealias R = OutputRoute
        #expect(R.kind(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil,
                       hasInput: true) == .headphones, "AirPods")
        #expect(R.kind(transport: kAudioDeviceTransportTypeBluetoothLE, dataSource: nil,
                       hasInput: false) == .headphones)
        #expect(R.kind(transport: kAudioDeviceTransportTypeBuiltIn,
                       dataSource: R.headphoneSource, hasInput: false) == .headphones,
                "3,5 mm jak")
        #expect(R.kind(transport: kAudioDeviceTransportTypeBuiltIn,
                       dataSource: 0x6973_706B, hasInput: false) == .speakers,
                "yerleşik hoparlör ('ispk')")
        #expect(R.kind(transport: kAudioDeviceTransportTypeUSB, dataSource: nil,
                       hasInput: true) == .headphones, "USB kulaklıklı mikrofon")
        #expect(R.kind(transport: kAudioDeviceTransportTypeUSB, dataSource: nil,
                       hasInput: false) == .speakers, "USB DAC / hoparlör")
        #expect(R.kind(transport: kAudioDeviceTransportTypeHDMI, dataSource: nil,
                       hasInput: false) == .speakers)
        #expect(R.kind(transport: nil, dataSource: nil, hasInput: false) == .speakers,
                "emin olunamayan durum hoparlör sayılır")
    }

    /// Varsayılan açık; ayar kayda iletilir.
    @Test
    func ayarKaydaIletilir() async throws {
        let h = try Harness(intelligence: UnavailableIntelligence())
        #expect(OraSettings(defaults: UserDefaults(suiteName: "ora.tests.\(UUID())")!)
                    .echoCancellationEnabled, "varsayılan açık")

        h.settings.echoCancellationEnabled = false
        await h.controller.start()
        await waitUntil("kayıt başladı") { h.capture.startCount == 1 }
        #expect(h.capture.lastEchoCancellation == false)
    }
}
