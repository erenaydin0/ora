// ora uygulama ikonu — BRAND.md paletiyle çizilir, gradyan yok.
//
// Hikâye: bir ağız konuşur. Koyu karmen dudak hacim verir; krem badem
// açıklık sözün çıktığı yerdir; içteki koyu oval kavitedir (dinleme).
// Ağızdan sağa kaçan küçük krem damla, sesin bilgiye dönüşmesidir.
// Yuvarlatılmış köşeyi macOS 26 kendi çizer.
import AppKit
import CoreGraphics

let slots: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]
let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                    ? CommandLine.arguments[1] : "ora.iconset")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let paper = color(0xFAF6F0)
let carmine = color(0xA61B2B)
let deep = color(0x6B121C)

/// Gülümseyen badem — köşeler biraz aşağıda, ağız okunur, göz değil.
func almond(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let left = CGPoint(x: cx - w / 2, y: cy + h * 0.12)
    let right = CGPoint(x: cx + w / 2, y: cy + h * 0.12)
    path.move(to: left)
    path.addQuadCurve(to: right, control: CGPoint(x: cx, y: cy - h * 0.48))
    path.addQuadCurve(to: left, control: CGPoint(x: cx, y: cy + h * 0.52))
    path.closeSubpath()
    return path
}

func teardrop(cx: CGFloat, cy: CGFloat, r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: cx - r * 0.15, y: cy + r * 0.55))
    path.addQuadCurve(to: CGPoint(x: cx + r * 0.85, y: cy - r * 0.55),
                      control: CGPoint(x: cx + r * 0.95, y: cy + r * 0.25))
    path.addQuadCurve(to: CGPoint(x: cx - r * 0.15, y: cy + r * 0.55),
                      control: CGPoint(x: cx + r * 0.05, y: cy - r * 0.35))
    path.closeSubpath()
    return path
}

func draw(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.setFillColor(carmine)
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    let cx = s * 0.47
    let cy = s * 0.52

    // Dudak — alt daha dolgun durur diye açıklık biraz yukarı kayar.
    ctx.setFillColor(deep)
    ctx.addPath(almond(cx: cx, cy: cy + s * 0.02, w: s * 0.70, h: s * 0.42))
    ctx.fillPath()

    // Açıklık
    ctx.setFillColor(paper)
    ctx.addPath(almond(cx: cx, cy: cy - s * 0.02, w: s * 0.52, h: s * 0.24))
    ctx.fillPath()

    // Kavite — açıklığın alt kenarında, göz bebeği değil ağız boşluğu.
    ctx.setFillColor(deep)
    ctx.addPath(almond(cx: cx, cy: cy + s * 0.02, w: s * 0.36, h: s * 0.08))
    ctx.fillPath()

    // Söz — ağızdan çıkan damla (ses → bilgi).
    ctx.setFillColor(paper)
    ctx.addPath(teardrop(cx: s * 0.76, cy: s * 0.34, r: max(2.5, s * 0.055)))
    ctx.fillPath()

    return ctx.makeImage()
}

for slot in slots {
    let pixels = slot.size * slot.scale
    guard let image = draw(size: pixels) else { continue }
    let name = slot.scale == 1
        ? "icon_\(slot.size)x\(slot.size).png"
        : "icon_\(slot.size)x\(slot.size)@2x.png"
    let url = outputDir.appending(path: name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { continue }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
print("iconset yazıldı: \(outputDir.path)")
