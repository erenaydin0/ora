// ora uygulama ikonu — BRAND.md paletiyle çizilir, gradyan yok.
// Marka: küçük harf "ora"nın "o"su; Core Blue halka, Paper Cream zemin.
import AppKit
import CoreGraphics

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                    ? CommandLine.arguments[1] : "ora.iconset")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let paper = color(0xFAF6F0)   // Paper Cream
let blue  = color(0x1A56A3)   // Core Blue
let ink   = color(0x333333)   // Slate Black

func draw(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // macOS ikon güvenli alanı: kenarda %10 boşluk, köşe yarıçapı kenarın ~%22'si
    let inset = s * 0.10
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                       transform: nil))
    ctx.setFillColor(paper)
    ctx.fillPath()

    // İnce kenarlık — düz zeminin kenarı belirsiz kalmasın
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                       cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(color(0xE8E8E8))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()

    // "o" halkası
    let ringDiameter = rect.width * 0.52
    let ringWidth = ringDiameter * 0.20
    let ringRect = CGRect(x: rect.midX - ringDiameter / 2,
                          y: rect.midY - ringDiameter / 2,
                          width: ringDiameter, height: ringDiameter)
        .insetBy(dx: ringWidth / 2, dy: ringWidth / 2)
    ctx.addEllipse(in: ringRect)
    ctx.setStrokeColor(blue)
    ctx.setLineWidth(ringWidth)
    ctx.strokePath()

    // Sesi temsil eden iki kısa çizgi — halkanın sağında, azalan uzunlukta
    let barWidth = ringWidth * 0.55
    let gap = ringWidth * 0.85
    var x = ringRect.maxX + ringWidth / 2 + gap
    for factor in [0.62, 0.34] where size >= 32 {
        let height = ringDiameter * factor
        let bar = CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2,
                           cornerHeight: barWidth / 2, transform: nil))
        ctx.setFillColor(ink)
        ctx.fillPath()
        x += barWidth + gap
    }
    return ctx.makeImage()
}

for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        guard pixels <= 1024, let image = draw(size: pixels) else { continue }
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        let url = outputDir.appending(path: name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { continue }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
print("iconset yazıldı: \(outputDir.path)")
