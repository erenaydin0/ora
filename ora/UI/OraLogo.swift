import SwiftUI

/// ora logosu — vektörel, uygulama ikonuyla aynı dil.
///
/// "o" halkası (Core Blue) ve azalan iki ses çubuğu (Slate Black). Gradyan yok,
/// dekoratif öğe yok; BRAND.md'nin izin verdiği renkler dışına çıkmaz.
/// Tek boyut parametresiyle her yerde aynı oranda çizilir.
struct OraLogo: View {

    /// Logonun yüksekliği; genişlik orandan türetilir.
    var height: CGFloat = 24
    /// Adı da göster (onboarding ve hakkında ekranı için).
    var showsWordmark = false

    private var ringWidth: CGFloat { height * 0.22 }

    var body: some View {
        HStack(spacing: height * 0.34) {
            HStack(spacing: height * 0.16) {
                Circle()
                    .strokeBorder(Color.oraBlue, lineWidth: ringWidth)
                    .frame(width: height, height: height)
                bar(0.62)
                bar(0.34)
            }
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

    private func bar(_ factor: CGFloat) -> some View {
        Capsule()
            .fill(Color.oraInk)
            .frame(width: ringWidth * 0.62, height: height * factor)
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
