import Foundation
import CoreAudio
import AppKit

func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                             mElement: kAudioObjectPropertyElementMain)
}

func snapshot() -> [(String, pid_t, Bool, Bool)] {
  guard let procs = try? AudioHardwareSystem.shared.processes else { return [] }
  return procs.compactMap { p in
    guard let pid = try? p.pid else { return nil }
    let bid = (try? p.bundleID) ?? nil
    let inp = (try? p.isRunningInput) ?? false
    let out = (try? p.isRunningOutput) ?? false
    return (bid ?? "?", pid, inp, out)
  }
}

print("=== Anlık durum: ses I/O yapan süreçler ===")
for (b, pid, i, o) in snapshot() where i || o {
  print("  \(b) pid=\(pid) mic=\(i ? "AÇIK" : "-") çıkış=\(o ? "AÇIK" : "-")")
}
print("(hiçbiri yoksa liste boş — normal)\n")

print("=== Olay dinleyicisi kuruluyor (polling YOK) ===")
var a = addr(kAudioHardwarePropertyProcessObjectList)
let sysObj = AudioObjectID(kAudioObjectSystemObject)
var eventCount = 0

let block: AudioObjectPropertyListenerBlock = { _, _ in
  eventCount += 1
  let now = snapshot().filter { $0.2 || $0.3 }
  print("  [OLAY \(eventCount)] aktif: \(now.map { "\($0.0)\($0.2 ? "(mic)" : "")" }.joined(separator: ", "))")
}
let st = AudioObjectAddPropertyListenerBlock(sysObj, &a, DispatchQueue.main, block)
print("listener OSStatus: \(st)\n")

// Her sürecin isRunningInput'una da dinleyici tak
var inAddr = addr(kAudioProcessPropertyIsRunningInput)
var outAddr = addr(kAudioProcessPropertyIsRunningOutput)
if let procs = try? AudioHardwareSystem.shared.processes {
  for p in procs {
    AudioObjectAddPropertyListenerBlock(p.id, &inAddr, DispatchQueue.main, block)
    AudioObjectAddPropertyListenerBlock(p.id, &outAddr, DispatchQueue.main, block)
  }
  print("izlenen süreç sayısı: \(procs.count)")
}

print("\n3 sn sonra 'say' çalıştırılacak — çıkış sinyali tetiklenmeli...")
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
  let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/say")
  t.arguments = ["-v", "Yelda", "Toplantı algılama sinyali testi yapılıyor"]
  try? t.run()
}
DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
  print("\ntoplam olay: \(eventCount)"); exit(0)
}
RunLoop.main.run()
