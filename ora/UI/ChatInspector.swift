import SwiftUI

/// Sağ panel: toplantı sohbeti. Varsayılan kapalı (DESIGN.md §4).
/// Kayıt sırasında devre dışıdır — LLM kayıt sırasında çalışmaz (kural #1).
struct ChatInspector: View {

    let recorder: RecordingController
    var isDisabledDuringRecording = false

    @State private var question = ""
    @FocusState private var isInputFocused: Bool

    private var isEmpty: Bool { recorder.chatTurns.isEmpty && !recorder.isAnswering }

    private var canAsk: Bool {
        !isDisabledDuringRecording && !recorder.transcript.isEmpty
            && !recorder.isAnswering && recorder.modelAvailability.isAvailable
    }

    /// Boş sohbette gösterilen başlangıç soruları — kullanıcı ne sorabileceğini
    /// bilmeden boş bir kutuya bakmasın.
    private let starters = [
        "Bu toplantıda ne kararlaştırıldı?",
        "Bana düşen işler neler?",
        "Konuşulan tarihler neydi?",
    ]

    var body: some View {
        // Boş durum panelin **tamamına** göre ortalanır — yazma alanı yüksekliği
        // kadar yukarı kaymasın, kenar çubuğu ve orta paneldeki boş durumlarla
        // aynı hizada dursun.
        ZStack(alignment: .bottom) {
            if isEmpty {
                EmptyState(icon: emptyIcon, title: emptyTitle, detail: emptyDetail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                conversation
            }

            VStack(spacing: 10) {
                if isEmpty, canAsk { starterButtons }
                composer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.oraPaper)
    }

    // MARK: - Parçalar

    @State private var pendingQuestion = ""

    /// Sohbeti olan panel: soru-cevap listesi.
    @ViewBuilder
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(recorder.chatTurns) { turn in
                        TurnView(question: turn.question, answer: turn.answer)
                    }
                    if recorder.isAnswering {
                        TurnView(question: pendingQuestion, answer: nil)
                    }
                    // Yazma alanının altında kalmasın.
                    Color.clear.frame(height: 64).id("son")
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
            }
            .onChange(of: recorder.chatTurns.count) { _, _ in
                withAnimation(OraStyle.transition) { proxy.scrollTo("son", anchor: .bottom) }
            }
            .onChange(of: recorder.isAnswering) { _, _ in
                withAnimation(OraStyle.transition) { proxy.scrollTo("son", anchor: .bottom) }
            }
        }
    }

    /// Ne sorabileceğini bilmeden boş bir kutuya bakmasın diye başlangıç soruları.
    private var starterButtons: some View {
        VStack(spacing: 6) {
            ForEach(starters, id: \.self) { starter in
                Button {
                    pendingQuestion = starter
                    Task { await recorder.ask(starter) }
                } label: {
                    Text(starter)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.oraInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.oraAccentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: OraStyle.cornerRadius))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

    private var emptyIcon: String {
        if isDisabledDuringRecording { "pause.circle" }
        else if !recorder.modelAvailability.isAvailable { "sparkles" }
        else if recorder.transcript.isEmpty { "text.bubble" }
        else { "bubble.left.and.text.bubble.right" }
    }

    private var emptyTitle: String {
        if isDisabledDuringRecording { "Sohbet şu anda kapalı" }
        else if !recorder.modelAvailability.isAvailable {
            recorder.modelAvailability.turkishMessage
        }
        else if recorder.transcript.isEmpty { "Önce bir toplantı seçin" }
        else { "Bu toplantıya soru sorun" }
    }

    private var emptyDetail: String {
        if isDisabledDuringRecording {
            "Toplantı bittikten sonra kullanılabilir."
        } else if !recorder.modelAvailability.isAvailable {
            recorder.modelAvailability.turkishDetail
        } else if recorder.transcript.isEmpty {
            "Transkripti olan bir toplantı seçtiğinizde sorularınızı yanıtlarım."
        } else {
            "Yanıtlar yalnızca bu toplantının transkriptinden çıkarılır."
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if !isEmpty { Divider().overlay(Color.oraBorder) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Soru sorun", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.oraInk)
                    .focused($isInputFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.oraSurface)
                    .clipShape(RoundedRectangle(cornerRadius: OraStyle.cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: OraStyle.cornerRadius)
                            .stroke(isInputFocused ? Color.oraBlue : Color.oraBorder,
                                    lineWidth: 1)
                    )
                    .onSubmit(ask)
                    .disabled(!canAsk)

                Button(action: ask) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(canAsk && !question.isEmpty
                                         ? Color.oraBlue : Color.oraInkMuted.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canAsk || question.isEmpty)
                .help("Sor")
            }
            .padding(12)
        }
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        pendingQuestion = text
        Task { await recorder.ask(text) }
    }
}

/// Bir soru-cevap çifti. Soru vurgulu bir başlık, yanıt okunur bir gövde —
/// baloncuk yok, uzun metin okunacak bir yüzeyde baloncuk okumayı zorlaştırır.
private struct TurnView: View {
    let question: String
    /// `nil` ise yanıt bekleniyor.
    let answer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.oraBlue)
                    .frame(width: 3)
                Text(question)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.oraInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let answer {
                Text(answer)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.oraInk)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 11)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transkript taranıyor…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.oraInkMuted)
                }
                .padding(.leading, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
