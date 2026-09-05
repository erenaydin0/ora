import SwiftUI

/// ora logosu — vektörel, uygulama ikonuyla aynı dil.
///
/// Konuşan ağız: koyu karmen dudak, krem açıklık, alt kenarda kavite,
/// ağızdan çıkan söz damlası. `make-icon.swift` ile aynı kesirler.
struct OraLogo: View {

    var height: CGFloat = 24
    var showsWordmark = false

    private var markRadius: CGFloat { min(OraStyle.cornerRadius, height * 0.22) }

    var body: some View {
        HStack(spacing: height * 0.28) {
            OraMark()
                .frame(width: height, height: height)
                .clipShape(RoundedRectangle(cornerRadius: markRadius, style: .continuous))
            if showsWordmark {
                Text("ora")
                    .font(.system(size: height * 0.92, weight: .medium))
                    .foregroundStyle(Color.oraInk)
                    .kerning(-height * 0.01)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("ora")
    }
}

private struct OraMark: View {
    var body: some View {
        Canvas { context, size in
            let s = size.width
            let cx = s * 0.47
            let cy = s * 0.52
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color.oraCarmine))
            context.fill(almond(cx: cx, cy: cy + s * 0.02, w: s * 0.70, h: s * 0.42),
                         with: .color(Color.oraCarmineDeep))
            context.fill(almond(cx: cx, cy: cy - s * 0.02, w: s * 0.52, h: s * 0.24),
                         with: .color(Color.oraPaper))
            context.fill(almond(cx: cx, cy: cy + s * 0.02, w: s * 0.36, h: s * 0.08),
                         with: .color(Color.oraCarmineDeep))
            context.fill(teardrop(cx: s * 0.76, cy: s * 0.34, r: max(2.5, s * 0.055)),
                         with: .color(Color.oraPaper))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func almond(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) -> Path {
        var path = Path()
        let left = CGPoint(x: cx - w / 2, y: cy + h * 0.12)
        let right = CGPoint(x: cx + w / 2, y: cy + h * 0.12)
        path.move(to: left)
        path.addQuadCurve(to: right, control: CGPoint(x: cx, y: cy - h * 0.48))
        path.addQuadCurve(to: left, control: CGPoint(x: cx, y: cy + h * 0.52))
        path.closeSubpath()
        return path
    }

    private func teardrop(cx: CGFloat, cy: CGFloat, r: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: cx - r * 0.15, y: cy + r * 0.55))
        path.addQuadCurve(to: CGPoint(x: cx + r * 0.85, y: cy - r * 0.55),
                          control: CGPoint(x: cx + r * 0.95, y: cy + r * 0.25))
        path.addQuadCurve(to: CGPoint(x: cx - r * 0.15, y: cy + r * 0.55),
                          control: CGPoint(x: cx + r * 0.05, y: cy - r * 0.35))
        path.closeSubpath()
        return path
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        OraLogo(height: 20)
        OraLogo(height: 32, showsWordmark: true)
        OraLogo(height: 48, showsWordmark: true)
    }
    .padding(32)
    .background(Color.oraPaper)
}
