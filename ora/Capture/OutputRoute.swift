import CoreAudio
import Foundation

/// Varsayılan çıkış cihazı kulaklık mı, hoparlör mü?
///
/// Yankı bastırmanın tek sorusu budur: hoparlörden çalan karşı taraf
/// mikrofona geri girer ve ch0'a sızar; kulaklıkta böyle bir yol yoktur ve
/// ses işleme yalnızca mikrofon sesini gereksiz yere işler (Anarlog v1.4.18
/// de kulaklıkta yankı bastırmayı atlıyor).
///
/// Karar kaba ama güvenli yöndedir: emin olunamayan her durum **hoparlör**
/// sayılır — gereksiz yere açık bir yankı bastırma, kapalı kalmış olandan
/// ucuzdur.
nonisolated enum OutputRoute {

    enum Kind: Equatable {
        case headphones
        case speakers
    }

    static func current() -> Kind {
        guard let device = defaultOutputDevice() else { return .speakers }
        return kind(transport: transportType(device),
                    dataSource: dataSource(device),
                    hasInput: hasStreams(device, scope: kAudioObjectPropertyScopeInput))
    }

    /// Saf karar — testte doğrudan denetlenir.
    ///  - Bluetooth: AirPods ve kulaklıklar. Bluetooth hoparlör nadirdir ve
    ///    yanlış sınıflandırılması yalnızca yankı bastırmayı kapatır.
    ///  - Yerleşik: 3,5 mm jaka takılınca veri kaynağı `hdpn` olur.
    ///  - USB: aynı cihazda mikrofon da varsa kulaklıklı mikrofondur (Jabra,
    ///    Poly); yalnızca çıkışı varsa hoparlör ya da DAC.
    ///  - HDMI, DisplayPort, AirPlay, bilinmeyen: hoparlör.
    static func kind(transport: UInt32?, dataSource: UInt32?, hasInput: Bool) -> Kind {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .headphones
        case kAudioDeviceTransportTypeBuiltIn:
            return dataSource == headphoneSource ? .headphones : .speakers
        case kAudioDeviceTransportTypeUSB:
            return hasInput ? .headphones : .speakers
        default:
            return .speakers
        }
    }

    /// `'hdpn'` — yerleşik çıkışın kulaklık veri kaynağı.
    static let headphoneSource: UInt32 = 0x6864_706E

    // MARK: - CoreAudio

    private static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func uint32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32? {
        uint32(device, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
    }

    private static func dataSource(_ device: AudioObjectID) -> UInt32? {
        uint32(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
    }

    private static func hasStreams(_ device: AudioObjectID,
                                   scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr
        else { return false }
        return size > 0
    }
}
