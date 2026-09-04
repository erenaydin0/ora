import SwiftUI

/// Sağ panel: toplantı sohbeti. Varsayılan kapalı (DESIGN.md §4).
/// Kayıt sırasında devre dışıdır — LLM kayıt sırasında çalışmaz (kural #1).
struct ChatInspector: View {

    let recorder: RecordingController
    var isDisabledDuringRecording = false

    @State private var question = ""

    private var canAsk: Bool {
        !isDisabledDuringRecording && !recorder.transcript.isEmpty
            && !recorder.isAnswering && recorder.modelAvailability.isAvailable
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if recorder.chatTurns.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(recorder.chatTurns) { turn in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(turn.question)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.oraInk)
                                    Text(turn.answer)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.oraInk)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if recorder.isAnswering {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Transkript taranıyor…")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.oraInkMuted)
                                }
                            }
                            Color.clear.frame(height: 1).id("son")
                        }
                        .padding(16)
                    }
                }
                .onChange(of: recorder.chatTurns.count) { _, _ in
                    withAnimation(OraStyle.transition) { proxy.scrollTo("son", anchor: .bottom) }
                }
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
                    .onSubmit(ask)
                    .disabled(!canAsk)

                Button(action: ask) {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.oraBlue)
                .disabled(!canAsk || question.isEmpty)
            }
            .padding(12)
        }
        .background(Color.oraPaper)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isDisabledDuringRecording {
            EmptyState(icon: "bubble.left.and.text.bubble.right",
                       title: "Sohbet şu anda kapalı",
                       detail: "Sohbet, toplantı bittikten sonra kullanılabilir.")
        } else if !recorder.modelAvailability.isAvailable {
            EmptyState(icon: "sparkles",
                       title: recorder.modelAvailability.turkishMessage,
                       detail: recorder.modelAvailability.turkishDetail)
        } else if recorder.transcript.isEmpty {
            EmptyState(icon: "bubble.left.and.text.bubble.right",
                       title: "Toplantı sohbeti",
                       detail: "Bir toplantı seçin; transkripti hakkında soru sorabilirsiniz.")
        } else {
            EmptyState(icon: "bubble.left.and.text.bubble.right",
                       title: "Toplantı sohbeti",
                       detail: "Bu toplantı hakkında soru sorun. Yanıtlar yalnızca "
                             + "transkriptten çıkarılır.")
        }
    }

    private func ask() {
        let text = question
        question = ""
        Task { await recorder.ask(text) }
    }
}
