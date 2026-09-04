import AppKit

for s in NSScreen.screens {
  print("=== Ekran: \(s.localizedName) ===")
  print("  frame          : \(s.frame)")
  print("  visibleFrame   : \(s.visibleFrame)")
  print("  backingScale   : \(s.backingScaleFactor)")
  print("  safeAreaInsets : top=\(s.safeAreaInsets.top) left=\(s.safeAreaInsets.left) right=\(s.safeAreaInsets.right) bottom=\(s.safeAreaInsets.bottom)")
  if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
    let notchW = r.minX - l.maxX
    print("  auxTopLeft     : \(l)")
    print("  auxTopRight    : \(r)")
    print("  ✅ ÇENTİK VAR — genişlik \(notchW) pt, yükseklik \(s.safeAreaInsets.top) pt")
    print("  çentik dikdörtgeni: x=\(l.maxX) y=\(s.frame.maxY - s.safeAreaInsets.top) w=\(notchW) h=\(s.safeAreaInsets.top)")
  } else {
    print("  ❌ çentik yok (auxiliaryTopLeft/RightArea nil)")
  }
  print("  menü bar yüksekliği: \(NSStatusBar.system.thickness)")
}
