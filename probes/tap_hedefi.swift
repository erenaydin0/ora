// Tap hedefi probe'u: verilen bundle ID'leri hedefleyen bir süreç tap'i
// gerçekten ses yakalıyor mu?
//
// RESEARCH.md §13.3 tarayıcılar için "ana bundle ID sessizlik yakalar" demişti;
// §28.3'te aynısı Teams için ölçüldü. Bu probe hedefi **parametre** alır, böylece
// ana süreç ile yardımcı süreç yan yana karşılaştırılabilir:
//
//   xcrun swiftc -o /tmp/tap_hedefi probes/tap_hedefi.swift
//   /tmp/tap_hedefi com.microsoft.teams2                       # sessiz beklenir
//   /tmp/tap_hedefi com.microsoft.teams2.helper com.microsoft.teams2.modulehost
//
// Toplantıda karşı taraf konuşurken ya da bir video oynatılırken koşturun.
import Foundation
import CoreAudio
import AudioToolbox

let bundleIDs = Array(CommandLine.arguments.dropFirst())
guard !bundleIDs.isEmpty else {
    print("kullanım: tap_hedefi <bundle-id> [<bundle-id> …]"); exit(2)
}
let seconds = 6.0

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
-> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

let desc = CATapDescription()
desc.name = "ora-tap-hedefi"
desc.bundleIDs = bundleIDs
desc.isExclusive = false      // YALNIZCA bu bundle ID'ler
desc.isMono = true
desc.isMixdown = true
desc.isPrivate = true
desc.muteBehavior = .unmuted
desc.isProcessRestoreEnabled = true

var tapID = AudioObjectID(kAudioObjectUnknown)
let st = AudioHardwareCreateProcessTap(desc, &tapID)
guard st == noErr, tapID != kAudioObjectUnknown else {
    print("❌ tap oluşmadı: OSStatus \(st)"); exit(1)
}
print("hedef: \(bundleIDs.joined(separator: ", "))")

var outDevice = AudioObjectID(kAudioObjectUnknown)
var defAddr = addr(kAudioHardwarePropertyDefaultOutputDevice)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &size, &outDevice)
var uidAddr = addr(kAudioDevicePropertyDeviceUID)
var uidRef: CFString?
size = UInt32(MemoryLayout<CFString?>.size)
AudioObjectGetPropertyData(outDevice, &uidAddr, 0, nil, &size, &uidRef)
let outUID = (uidRef as String?) ?? ""

let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "ora tap hedefi",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapUIDKey: desc.uuid.uuidString,
        kAudioSubTapDriftCompensationKey: true,
    ]],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID) == noErr else {
    print("❌ toplama cihazı oluşmadı"); AudioHardwareDestroyProcessTap(tapID); exit(1)
}

final class Counter: @unchecked Sendable {
    var frames = 0
    var peak: Float = 0
}
let counter = Counter()
var procID: AudioDeviceIOProcID?
let pst = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, DispatchQueue(label: "ora.tap.hedefi")) {
    _, input, _, _, _ in
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard list.count > 0, let data = list[0].mData else { return }
    let channels = Int(max(list[0].mNumberChannels, 1))
    let count = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
    counter.frames += count / channels
    let p = data.assumingMemoryBound(to: Float.self)
    for i in 0 ..< min(count, 4096) { counter.peak = max(counter.peak, abs(p[i])) }
}
guard pst == noErr, let procID else {
    print("❌ IOProc oluşmadı"); AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID); exit(1)
}
AudioDeviceStart(aggID, procID)
print("\(Int(seconds)) saniye dinleniyor…")
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(aggID, procID)
AudioDeviceDestroyIOProcID(aggID, procID)
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)

print("frame: \(counter.frames)   tepe genlik: \(counter.peak)")
print(counter.peak > 0.0001
      ? "✅ bu hedeften GERÇEK SES geliyor"
      : "❌ sessiz — bu bundle ID sesi üretmiyor (ya da o sırada ses çalmıyordu)")
