import Foundation
import CoreAudio
import AudioToolbox

let sys = AudioHardwareSystem.shared
print("=== Ses çıkışı olan süreçler ===")
do {
  for p in try sys.processes {
    let running = (try? p.isRunningOutput) ?? false
    let bid = (try? p.bundleID) ?? nil
    if running { print("  [ÇALAN] \(bid ?? "?")  pid=\((try? p.pid) ?? -1)") }
  }
} catch { print("süreç listesi hatası: \(error)") }

print("\n=== Global tap oluşturma denemesi (kendimiz hariç) ===")
let desc = CATapDescription()
desc.name = "ora-probe"
desc.processes = []          // boş + exclusive = her şeyi yakala
desc.isExclusive = true
desc.isMono = false
desc.isMixdown = true
desc.isPrivate = true
desc.muteBehavior = CATapMuteBehavior.unmuted

var tapID = AudioObjectID(kAudioObjectUnknown)
let st = AudioHardwareCreateProcessTap(desc, &tapID)
print("OSStatus: \(st)   tapID: \(tapID)")

if st == noErr && tapID != kAudioObjectUnknown {
  print("✅ TAP OLUŞTU — ekran kaydı izni istenmedi")
  var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var asbd = AudioStreamBasicDescription()
  var s = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
  if AudioObjectGetPropertyData(tapID, &addr, 0, nil, &s, &asbd) == noErr {
    print("   format: \(asbd.mSampleRate) Hz · \(asbd.mChannelsPerFrame) kanal · \(asbd.mBitsPerChannel) bit")
  }
  AudioHardwareDestroyProcessTap(tapID)
  print("   tap temizlendi")
} else {
  print("❌ oluşmadı (OSStatus \(st)) — izin veya yapılandırma sorunu")
}
