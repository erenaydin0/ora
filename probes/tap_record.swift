// Faz 2 probe: süreç tap'i → toplama cihazı → IOProc ile gerçek PCM okuma.
// Amaç: tap'in yalnızca oluştuğunu değil, ondan ses AKTIĞINI ve host time
// damgasının geldiğini kanıtlamak.
import Foundation
import CoreAudio
import AudioToolbox

func fourCC(_ s: String) -> AudioObjectPropertySelector {
    var r: UInt32 = 0
    for b in s.utf8 { r = (r << 8) | UInt32(b) }
    return r
}

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
-> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

// --- kendi süreç nesnemiz (global tap'ten hariç tutmak için) ---
var myProcessObject = AudioObjectID(kAudioObjectUnknown)
var pid = getpid()
var translate = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
let tr = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &translate,
                                    UInt32(MemoryLayout<pid_t>.size), &pid, &size, &myProcessObject)
print("kendi süreç nesnemiz: \(myProcessObject)  (OSStatus \(tr))")

// --- tap ---
let desc = CATapDescription()
desc.name = "ora-probe-record"
desc.processes = myProcessObject == kAudioObjectUnknown ? [] : [myProcessObject]
desc.isExclusive = true          // bunlar HARİÇ her şey
desc.isMono = true               // tek kanal mixdown — WAV'ın ch1'i mono
desc.isMixdown = true
desc.isPrivate = true
desc.muteBehavior = .unmuted
desc.isProcessRestoreEnabled = true

var tapID = AudioObjectID(kAudioObjectUnknown)
let st = AudioHardwareCreateProcessTap(desc, &tapID)
guard st == noErr, tapID != kAudioObjectUnknown else {
    print("❌ tap oluşmadı: OSStatus \(st)"); exit(1)
}
print("✅ tap: \(tapID)  UUID: \(desc.uuid.uuidString)")

var fmtAddr = addr(kAudioTapPropertyFormat)
var asbd = AudioStreamBasicDescription()
size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &asbd)
print("   tap formatı: \(asbd.mSampleRate) Hz · \(asbd.mChannelsPerFrame) kanal · \(asbd.mBitsPerChannel) bit · flags \(asbd.mFormatFlags)")

// --- varsayılan çıkış cihazının UID'si (toplama cihazının saat kaynağı) ---
var outDevice = AudioObjectID(kAudioObjectUnknown)
var defAddr = addr(kAudioHardwarePropertyDefaultOutputDevice)
size = UInt32(MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &size, &outDevice)
var uidAddr = addr(kAudioDevicePropertyDeviceUID)
var uidRef: CFString? = nil
size = UInt32(MemoryLayout<CFString?>.size)
AudioObjectGetPropertyData(outDevice, &uidAddr, 0, nil, &size, &uidRef)
let outUID = (uidRef as String?) ?? ""
print("   çıkış cihazı: \(outDevice)  UID: \(outUID)")

// --- toplama cihazı ---
let aggUID = UUID().uuidString
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "ora probe capture",
    kAudioAggregateDeviceUIDKey: aggUID,
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
let ast = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
guard ast == noErr, aggID != kAudioObjectUnknown else {
    print("❌ toplama cihazı oluşmadı: OSStatus \(ast)")
    AudioHardwareDestroyProcessTap(tapID); exit(1)
}
print("✅ toplama cihazı: \(aggID)")

// --- giriş akış formatı ---
var streamFmt = AudioStreamBasicDescription()
var sfAddr = addr(kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput)
size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
let sfSt = AudioObjectGetPropertyData(aggID, &sfAddr, 0, nil, &size, &streamFmt)
print("   giriş akışı: \(streamFmt.mSampleRate) Hz · \(streamFmt.mChannelsPerFrame) kanal (OSStatus \(sfSt))")

// --- IOProc ---
final class Counter: @unchecked Sendable {
    var frames = 0; var calls = 0; var firstHost: UInt64 = 0; var lastHost: UInt64 = 0
    var peak: Float = 0; var buffers = 0; var channels: UInt32 = 0
}
let counter = Counter()
let queue = DispatchQueue(label: "ora.probe.tap")
var procID: AudioDeviceIOProcID?
let pst = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) {
    _, inInputData, inInputTime, _, _ in
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    counter.calls += 1
    counter.buffers = list.count
    guard list.count > 0 else { return }
    let buf = list[0]
    counter.channels = buf.mNumberChannels
    let frameCount = Int(buf.mDataByteSize) / MemoryLayout<Float>.size / Int(max(buf.mNumberChannels, 1))
    counter.frames += frameCount
    if counter.firstHost == 0 { counter.firstHost = inInputTime.pointee.mHostTime }
    counter.lastHost = inInputTime.pointee.mHostTime
    if let data = buf.mData {
        let p = data.assumingMemoryBound(to: Float.self)
        for i in 0 ..< min(frameCount * Int(max(buf.mNumberChannels, 1)), 4096) {
            counter.peak = max(counter.peak, abs(p[i]))
        }
    }
}
guard pst == noErr, let procID else {
    print("❌ IOProc oluşmadı: OSStatus \(pst)")
    AudioHardwareDestroyAggregateDevice(aggID); AudioHardwareDestroyProcessTap(tapID); exit(1)
}
let startSt = AudioDeviceStart(aggID, procID)
print("✅ IOProc başladı (OSStatus \(startSt)) — 4 saniye dinleniyor…")
print("   (bu sırada bir şey çal: müzik, video, `say merhaba`)")

Thread.sleep(forTimeInterval: 4.0)

AudioDeviceStop(aggID, procID)
AudioDeviceDestroyIOProcID(aggID, procID)
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)

let elapsedNs = AudioConvertHostTimeToNanos(counter.lastHost &- counter.firstHost)
print("""

--- SONUÇ ---
IOProc çağrısı  : \(counter.calls)
buffer sayısı   : \(counter.buffers)   kanal: \(counter.channels)
toplam frame    : \(counter.frames)
host time aralığı: \(Double(elapsedNs) / 1e9) sn
tepe genlik     : \(counter.peak)
""")
print(counter.frames > 0 ? "✅ tap'ten PCM AKIYOR" : "❌ frame gelmedi")
print(counter.peak > 0 ? "✅ sessiz değil — gerçek ses yakalandı" : "⚠️  hep sıfır (ses çalmıyordu olabilir)")
