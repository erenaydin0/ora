import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Sistem sesi yakalama: CoreAudio süreç tap'i → özel toplama cihazı → IOProc.
///
/// ScreenCaptureKit **kullanılmaz** (CLAUDE.md kural #5): tap ekran kaydı izni
/// istemez ve süreç/bundle bazlı seçim yapabilir. Doğrulandı — RESEARCH.md §5
/// ve `probes/tap_record.swift`.
final class SystemAudioTap: @unchecked Sendable {

    /// Yakalanan mono örnekler ve buffer'ın host time damgası.
    typealias Sink = @Sendable (_ frames: [Float], _ hostTime: UInt64) -> Void

    /// Tap'in neyi yakaladığı — kullanıcıya ne söyleyeceğimizi belirler.
    enum Scope: Equatable {
        /// Yalnızca bu uygulamaların sesi yakalanıyor.
        case apps([String])
        /// Kendimiz hariç tüm sistem sesi.
        case globalExcludingSelf
    }

    private let queue = DispatchQueue(label: "ora.capture.tap", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var resampler: MonoResampler?

    private(set) var scope: Scope = .globalExcludingSelf
    private let counterLock = NSLock()
    private var receivedFrames: Int64 = 0
    private var sink: Sink?

    /// Tap açıldığından beri gelen frame sayısı. Kapsamlı tap'in gerçekten
    /// çalışıp çalışmadığını anlamak için kullanılır.
    var framesReceived: Int64 { counterLock.withLock { receivedFrames } }

    // MARK: - Yaşam döngüsü

    /// Tap'i kurar ve akışı başlatır. Başarısız olursa her şey geri alınır ve
    /// hata fırlatılır — çağıran yalnız-mikrofon moduna düşer.
    ///
    /// Yerel bir toplantı uygulaması çalışıyorsa yalnızca o yakalanır; yoksa
    /// (tarayıcı toplantıları dahil) kendimiz hariç global tap'e düşülür.
    func start(sink: @escaping Sink) throws {
        let targets = MeetingApps.tapTargets()
        try start(scope: targets.isEmpty ? .globalExcludingSelf : .apps(targets), sink: sink)
    }

    /// Kapsamlı tap sessiz kaldığında global tap'e geçiş. Kayıt kesilmez —
    /// yazıcı mutlak frame konumuna yazdığı için geçiş boşluğu sessizlik olur.
    func fallBackToGlobal() {
        guard case .apps = scope, let sink else { return }
        Log.warning(.capture, "Kapsamlı tap ses vermiyor (\(scopeDescription)) — "
                    + "global tap'e geçiliyor")
        teardown()
        do {
            try start(scope: .globalExcludingSelf, sink: sink)
        } catch {
            Log.error(.capture, "Global tap'e geçilemedi", error)
        }
    }

    private func start(scope: Scope, sink: @escaping Sink) throws {
        self.scope = scope
        self.sink = sink
        counterLock.withLock { receivedFrames = 0 }

        let description = CATapDescription()
        description.name = "ora"
        description.isMono = true          // WAV'ın ch1'i tek kanal — mixdown'ı CoreAudio yapsın
        description.isMixdown = true
        description.isPrivate = true       // tap yalnızca bize görünür
        description.muteBehavior = .unmuted // kullanıcı toplantıyı duymaya devam eder
        description.isProcessRestoreEnabled = true

        switch scope {
        case .apps(let bundleIDs):
            description.bundleIDs = bundleIDs
            description.isExclusive = false   // yalnızca bunları yakala
        case .globalExcludingSelf:
            // Kendimizi hariç tut — geri besleme döngüsünü önler.
            description.processes = Self.ownProcessObject().map { [$0] } ?? []
            description.isExclusive = true
        }

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            throw OraError.audioDeviceFailed(stage: "tap", status: tapStatus)
        }
        tapID = tap

        guard let format = Self.tapFormat(tapID) else {
            teardown()
            throw OraError.audioDeviceFailed(stage: "tap formatı", status: -1)
        }
        guard let resampler = MonoResampler(inputSampleRate: format.mSampleRate) else {
            teardown()
            throw OraError.audioDeviceFailed(stage: "yeniden örnekleyici", status: -1)
        }
        self.resampler = resampler

        do {
            aggregateID = try Self.makeAggregateDevice(tapUID: description.uuid.uuidString)
        } catch {
            teardown()
            throw error
        }

        let channels = max(format.mChannelsPerFrame, 1)
        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) {
            [weak self] _, inputData, inputTime, _, _ in
            guard let self, let resampler = self.resampler else { return }
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            guard list.count > 0, let data = list[0].mData else { return }

            let buffer = list[0]
            let bufferChannels = max(buffer.mNumberChannels, channels)
            let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard total > 0 else { return }
            let pointer = data.assumingMemoryBound(to: Float.self)

            // Tap mono mixdown veriyor; yine de çok kanal gelirse ortalanır.
            var mono: [Float]
            if bufferChannels <= 1 {
                mono = Array(UnsafeBufferPointer(start: pointer, count: total))
            } else {
                let frames = total / Int(bufferChannels)
                mono = [Float](repeating: 0, count: frames)
                for frame in 0 ..< frames {
                    var sum: Float = 0
                    for channel in 0 ..< Int(bufferChannels) {
                        sum += pointer[frame * Int(bufferChannels) + channel]
                    }
                    mono[frame] = sum / Float(bufferChannels)
                }
            }

            let resampled = resampler.resample(mono)
            guard !resampled.isEmpty else { return }
            self.counterLock.withLock { self.receivedFrames += Int64(resampled.count) }
            sink(resampled, inputTime.pointee.mHostTime)
        }
        guard procStatus == noErr, let proc else {
            teardown()
            throw OraError.audioDeviceFailed(stage: "IOProc", status: procStatus)
        }
        procID = proc

        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else {
            teardown()
            throw OraError.audioDeviceFailed(stage: "IOProc başlatma", status: startStatus)
        }

        Log.info(.capture, "Sistem sesi tap'i açıldı — kapsam: \(scopeDescription), "
                 + "kaynak \(Int(format.mSampleRate)) Hz")
    }

    func stop() {
        sink = nil
        teardown()
    }

    /// Sistemde (kendimiz dışında) ses çalan bir süreç var mı?
    ///
    /// Kapsamlı tap'in sessizliği iki şeyden olabilir: gerçekten kimse konuşmuyor,
    /// ya da hedeflediğimiz bundle ID sesi üretmiyor (Electron/tarayıcı yardımcı
    /// süreçleri). Bu ayrımı yapan sinyal budur.
    static func systemIsProducingOutput() -> Bool {
        let own = ownProcessObject()
        guard let processes = try? AudioHardwareSystem.shared.processes else { return false }
        for process in processes where process.id != own {
            if (try? process.isRunningOutput) == true { return true }
        }
        return false
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        resampler = nil
    }

    var scopeDescription: String {
        switch scope {
        case .apps(let ids):        "yalnızca \(ids.joined(separator: ", "))"
        case .globalExcludingSelf:  "tüm sistem (ora hariç)"
        }
    }

    // MARK: - CoreAudio yardımcıları

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var object = AudioObjectID(kAudioObjectUnknown)
        var pid = getpid()
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, UInt32(MemoryLayout<pid_t>.size),
                                                &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else {
            Log.warning(.capture, "Kendi süreç nesnemiz bulunamadı (OSStatus \(status)) — "
                        + "global tap kendimizi de yakalayabilir")
            return nil
        }
        return object
    }

    private static func tapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format)
        guard status == noErr, format.mSampleRate > 0 else { return nil }
        return format
    }

    private static func defaultOutputDeviceUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }

        var uidAddr = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, &uid) == noErr,
              let value = uid?.takeRetainedValue()
        else { return nil }
        return value as String
    }

    /// Tap'i taşıyan **özel** toplama cihazı. Cihaz listesinde görünmez ve
    /// varsayılan çıkış cihazını saat kaynağı olarak kullanır.
    private static func makeAggregateDevice(tapUID: String) throws -> AudioObjectID {
        guard let outputUID = defaultOutputDeviceUID() else {
            throw OraError.audioDeviceFailed(stage: "çıkış cihazı", status: -1)
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ora Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw OraError.audioDeviceFailed(stage: "toplama cihazı", status: status)
        }
        return device
    }
}
