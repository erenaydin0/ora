import CoreGraphics
import Foundation
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
var withName = 0, total = 0
for w in list {
  guard let owner = w[kCGWindowOwnerName as String] as? String else { continue }
  total += 1
  let name = w[kCGWindowName as String] as? String
  if let n = name, !n.isEmpty { withName += 1; if withName <= 5 { print("  BAŞLIK VAR: \(owner) → \"\(n)\"") } }
}
print("\ntoplam pencere: \(total) · başlığı okunabilen: \(withName)")
print(withName == 0 ? "❌ Pencere başlıkları OKUNAMIYOR (ekran kaydı izni gerekiyor)"
                    : "✅ başlıklar izinsiz okunabiliyor")
