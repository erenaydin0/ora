import SwiftUI

/// Boş durum bloğu. Dekoratif öğe yok, tek SF Symbol + iki satır metin.
struct EmptyState: View {

    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.oraInkMuted)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.oraInk)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
