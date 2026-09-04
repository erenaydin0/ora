import Foundation
import CoreAudio
let sys = AudioHardwareSystem.shared
for _ in 0..<8 {
    var line: [String] = []
    if let ps = try? sys.processes {
        for p in ps where ((try? p.isRunningOutput) ?? false) {
            line.append("\((try? p.bundleID) ?? nil ?? "?")(pid \((try? p.pid) ?? -1))")
        }
    }
    print(line.isEmpty ? "—" : line.joined(separator: "  "))
    Thread.sleep(forTimeInterval: 0.6)
}
