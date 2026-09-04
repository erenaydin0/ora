import SwiftUI

/// Sağ panel: toplantı sohbeti. Varsayılan kapalı (DESIGN.md §4).
/// Kayıt sırasında devre dışıdır — LLM kayıt sırasında çalışmaz (CLAUDE.md kural #1).
struct ChatInspector: View {

    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                EmptyState(
                    icon: "bubble.left.and.text.bubble.right",
                    title: "Toplantı sohbeti",
                    detail: "Toplantı işlendikten sonra transkript hakkında soru sorabilirsiniz."
                )
            }

            Divider().overlay(Color.oraBorder)

            HStack(spacing: 8) {
                TextField("Soru sorun", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.oraInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .oraCard()

                Button {
                    // Faz 6: Intelligence.answer(question:over:)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.oraBlue)
                .disabled(true)
            }
            .padding(12)
        }
        .background(Color.oraPaper)
    }
}
