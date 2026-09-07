// Toplantı algılama probe'u: bir Teams/Zoom toplantısında mikrofonu **hangi
// bundle ID** tutuyor?
//
// RESEARCH.md §13.3 tarayıcılar için ölçmüştü: ses ana uygulamadan değil
// yardımcı süreçten çıkıyor. Electron tabanlı Teams için aynı risk "ölçülmedi"
// notuyla bırakılmıştı. Algılama tam bundle ID eşitliği aradığı için, mikrofonu
// yardımcı süreç tutuyorsa toplantı **hiç** algılanmaz.
//
// Derle ve koş (toplantıya girip 30 sn bekleyin, sonra mikrofonu açıp kapatın):
//   xcrun swiftc -o /tmp/mikrofon_sahibi probes/mikrofon_sahibi.swift && /tmp/mikrofon_sahibi
import CoreAudio
import Foundation

let known: Set<String> = [
    "com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos",
    "com.tinyspeck.slackmacgap", "com.cisco.webexmeetingsapp", "com.hnc.Discord",
    "com.apple.FaceTime", "com.google.Chrome", "com.apple.Safari",
    "com.microsoft.edgemac", "org.mozilla.firefox",
]

func resolve(_ id: String) -> (app: String, viaHelper: Bool)? {
    if known.contains(id) { return (id, false) }
    if let parent = known.first(where: { id.hasPrefix($0 + ".") }) { return (parent, true) }
    return nil
}

func snapshot() -> [(id: String, mic: Bool, out: Bool)] {
    guard let procs = try? AudioHardwareSystem.shared.processes else { return [] }
    return procs.compactMap { p in
        guard let id = (try? p.bundleID) ?? nil else { return nil }
        let mic = (try? p.isRunningInput) ?? false
        let out = (try? p.isRunningOutput) ?? false
        return (mic || out) ? (id, mic, out) : nil
    }
}

setbuf(stdout, nil)   // canlı izlerken satırlar beklemesin

let clock = DateFormatter()
clock.dateFormat = "HH:mm:ss"
print("İzleniyor — toplantıya girin. Çıkmak için Ctrl+C.\n")
var previous = "-"   // ilk durum her zaman yazdırılsın
let deadline = Date().addingTimeInterval(300)

while Date() < deadline {
    let now = snapshot().sorted { $0.id < $1.id }
    let key = now.map { "\($0.id)\($0.mic)\($0.out)" }.joined()
    if key != previous {
        previous = key
        print("[\(clock.string(from: Date()))]")
        for p in now {
            let mark: String
            switch resolve(p.id) {
            case .some(let r) where r.viaHelper: mark = "  ← \(r.app) YARDIMCI SÜRECİ (tam eşitlik TUTMAZ)"
            case .some:                          mark = "  ← bilinen toplantı uygulaması (tam eşitlik tutar)"
            case nil:                            mark = ""
            }
            print("   \(p.id)  mikrofon:\(p.mic ? "EVET" : "hayır") çıkış:\(p.out ? "EVET" : "hayır")\(mark)")
        }
        if now.isEmpty { print("   (ses kullanan süreç yok)") }
    }
    Thread.sleep(forTimeInterval: 0.5)
}
