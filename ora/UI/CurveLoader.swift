import SwiftUI

/// Matematiksel bir eğri üzerinde dolaşan parçacık — işlem sürerken ekrandaki
/// tek hareketli öğe.
///
/// İlham: `Paidax01/math-curve-loaders` (rose, Lissajous, hypotrochoid, cardioid…).
/// Kütüphane **eklenmedi** — tek bağımlılık GRDB kalıyor (CLAUDE.md); eğri
/// burada birkaç satırda çiziliyor.
///
/// Seçilen eğri **Lissajous 3:2**: `x = sin(3t + π/2)`, `y = sin(2t)`.
/// Kapalı, simetrik ve 34 pt'de bile okunur — rose ve hypotrochoid bu boyutta
/// lapa oluyor, cardioid ise kalp okunuyor.
struct CurveLoader: View {

    var size: CGFloat = 34
    var lineWidth: CGFloat = 1.5

    /// Bir tam tur. Yavaş olması bilinçli: bekleme ekranı nabız gibi atmamalı.
    private let period: Double = 3.2
    /// İz kaç parçaya bölünerek çizilecek.
    private let trailSegments = 24
    /// İzin eğrinin ne kadarını kaplayacağı (tur oranı).
    private let trailSpan = 0.16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { context, canvas in
                let radius = min(canvas.width, canvas.height) / 2 - lineWidth
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)

                // Eğrinin kendisi soluk durur; parçacık onun üstünde döner.
                context.stroke(Self.curve(center: center, radius: radius),
                               with: .color(Color.oraInk.opacity(0.12)),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                let phase = reduceMotion ? 0.12 : Self.phase(at: timeline.date, period: period)
                drawTrail(in: &context, phase: phase, center: center, radius: radius)
            }
        }
        .frame(width: size, height: size)
        // Anlamı metin taşıyor; VoiceOver'a ayrıca bir öğe düşmemeli.
        .accessibilityHidden(true)
    }

    /// İz: baştan geriye doğru sönen kısa parçalar. Bu bir gradyan değil,
    /// hareketin bıraktığı izdir (BRAND.md'de ayrıca not düşüldü).
    private func drawTrail(in context: inout GraphicsContext, phase: Double,
                           center: CGPoint, radius: CGFloat) {
        let step = trailSpan / Double(trailSegments)
        for index in 0 ..< trailSegments {
            let head = phase - Double(index) * step
            let tail = head - step
            var segment = Path()
            segment.move(to: Self.point(at: head, center: center, radius: radius))
            segment.addLine(to: Self.point(at: tail, center: center, radius: radius))

            let falloff = 1 - Double(index) / Double(trailSegments)
            context.stroke(segment,
                           with: .color(Color.oraCarmine.opacity(falloff)),
                           style: StrokeStyle(lineWidth: lineWidth * (0.6 + 0.4 * falloff),
                                              lineCap: .round))
        }
        // Baştaki parçacık.
        let head = Self.point(at: phase, center: center, radius: radius)
        let dot = lineWidth * 1.5
        context.fill(Path(ellipseIn: CGRect(x: head.x - dot, y: head.y - dot,
                                            width: dot * 2, height: dot * 2)),
                     with: .color(Color.oraCarmine))
    }

    // MARK: - Eğri

    /// Duvar saatinden türetilir; görünüm yeniden kurulunca animasyon sıçramaz.
    static func phase(at date: Date, period: Double) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    }

    /// Lissajous 3:2. `phase` 0…1, eğrinin bir turu.
    static func point(at phase: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let t = phase * 2 * .pi
        return CGPoint(x: center.x + radius * sin(3 * t + .pi / 2),
                       y: center.y + radius * sin(2 * t))
    }

    static func curve(center: CGPoint, radius: CGFloat, samples: Int = 180) -> Path {
        var path = Path()
        for index in 0 ... samples {
            let point = point(at: Double(index) / Double(samples),
                              center: center, radius: radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

#Preview("Eğri loader") {
    VStack(spacing: 24) {
        CurveLoader()
        CurveLoader(size: 64, lineWidth: 2)
        CurveLoader(size: 120, lineWidth: 3)
    }
    .padding(40)
    .background(Color.oraPaper)
}
