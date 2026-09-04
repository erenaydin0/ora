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

    // macOS 26 ikon sanat eserini **kenardan kenara** ister: yuvarlatılmış köşeyi,
    // gölgeyi ve kabuğu sistem kendi çizer. Kendi köşemizi çizersek ikon içinde
    // ikon çıkar ve küçük boyutlarda marka kaybolur.
    ctx.setFillColor(paper)
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // İçerik, sistem maskesinin kırpmayacağı orta alanda durur.
    let safe = CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.16, dy: s * 0.16)

    // "o" halkası
    let ringDiameter = safe.width * 0.66
    let ringWidth = ringDiameter * 0.22
    let barWidth = ringWidth * 0.58
    let gap = ringWidth * 0.80
    // Halka + iki çubuk birlikte yatayda ortalanır.
    let barsWidth = size >= 32 ? (gap + barWidth) * 2 : 0
    let totalWidth = ringDiameter + barsWidth
    let originX = safe.midX - totalWidth / 2

    let ringRect = CGRect(x: originX, y: safe.midY - ringDiameter / 2,
                          width: ringDiameter, height: ringDiameter)
        .insetBy(dx: ringWidth / 2, dy: ringWidth / 2)
    ctx.addEllipse(in: ringRect)
    ctx.setStrokeColor(blue)
    ctx.setLineWidth(ringWidth)
    ctx.strokePath()

    // Sesi temsil eden iki çubuk, azalan uzunlukta
    if size >= 32 {
        var x = originX + ringDiameter + gap
        for factor in [0.60, 0.32] {
            let height = ringDiameter * factor
            let bar = CGRect(x: x, y: safe.midY - height / 2, width: barWidth, height: height)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2,
                               cornerHeight: barWidth / 2, transform: nil))
            ctx.setFillColor(ink)
            ctx.fillPath()
            x += barWidth + gap
        }
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
