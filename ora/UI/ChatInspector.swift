import SwiftUI

/// Sağ panel: sohbet. Varsayılan kapalı (DESIGN.md §4).
/// Kayıt sırasında devre dışıdır — LLM kayıt sırasında çalışmaz (kural #1).
///
/// İki kapsamı vardır: **bu toplantı** (transkriptin tamamı üzerinde
/// map-reduce) ve **tüm toplantılar** (COMPETITION.md §4.10 — soru FTS ile
/// daraltılır, yalnızca bulunan bölümler cihazdaki modele verilir). Toplantı
/// seçili değilken kapsam her zaman tüm toplantılardır.
struct ChatInspector: View {

    @Bindable var recorder: RecordingController
    var isDisabledDuringRecording = false

    @State private var question = ""
    @FocusState private var isInputFocused: Bool

    private var scope: RecordingController.ChatScope { recorder.effectiveChatScope }
    private var isAll: Bool { scope == .all }

    private var availability: ModelAvailability {
        isAll ? recorder.crossChatAvailability : recorder.modelAvailability
    }

    private var isEmpty: Bool {
        (isAll ? recorder.crossTurns.isEmpty : recorder.chatTurns.isEmpty)
            && !recorder.isAnswering
    }

    private var hasSource: Bool {
        isAll ? !recorder.meetings.isEmpty : !recorder.transcript.isEmpty
    }

    private var canAsk: Bool {
        !isDisabledDuringRecording && hasSource && !recorder.isAnswering
            && availability.isAvailable
    }

    /// Soru kutusu kapsamı taşır — panelin neyin hakkında olduğu başlık
    /// şeridi olmadan da bellidir.
    private var placeholder: String {
        if isAll { return "Tüm toplantılarda sorun" }
        guard let title = recorder.selectedMeeting?.title, !title.isEmpty else {
            return "Soru sorun"
        }
        return "\(title) hakkında sorun"
    }

    /// Boş sohbette gösterilen başlangıç soruları — kullanıcı ne sorabileceğini
    /// bilmeden boş bir kutuya bakmasın. Tüm toplantılar kapsamında yok:
    /// arama anahtar kelimeyle çalışır, soru bir konu adı taşımalı.
    private let starters = [
        "Bu toplantıda ne kararlaştırıldı?",
        "Bana düşen işler neler?",
        "Konuşulan tarihler neydi?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            if recorder.selection != nil, !recorder.showsActionBoard, !recorder.showsPeople {
                scopeBar
                Divider().overlay(Color.oraBorder)
            } else if !recorder.crossTurns.isEmpty {
                allHeader
                Divider().overlay(Color.oraBorder)
            }
            // Boş durum panelin **tamamına** göre ortalanır — yazma alanı
            // yüksekliği kadar yukarı kaymasın.
            ZStack(alignment: .bottom) {
                if isEmpty {
                    EmptyState(icon: emptyIcon, title: emptyTitle, detail: emptyDetail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    conversation
                }

                VStack(spacing: 10) {
                    if isEmpty, canAsk, !isAll { starterButtons }
                    composer
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.oraPaper)
    }

    // MARK: - Parçalar

    @State private var pendingQuestion = ""

    private var scopeBar: some View {
        HStack(spacing: 8) {
            Picker("Kapsam", selection: $recorder.chatScope) {
                ForEach(RecordingController.ChatScope.allCases) { scope in
                    Text(scope.turkishName).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(recorder.isAnswering)
            if isAll, !recorder.crossTurns.isEmpty { clearButton }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var allHeader: some View {
        HStack {
            Text("TÜM TOPLANTILAR")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Color.oraInkMuted)
            Spacer()
            clearButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var clearButton: some View {
        Button {
            Task { await recorder.clearCrossChat() }
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(Color.oraInkMuted)
        }
        .buttonStyle(.plain)
        .disabled(recorder.isAnswering)
        .help("Tüm toplantılar sohbet geçmişini temizle")
        .accessibilityLabel("Sohbet geçmişini temizle")
    }

    /// Sohbeti olan panel: soru-cevap listesi.
    @ViewBuilder
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if isAll {
                        ForEach(recorder.crossTurns) { turn in
                            TurnView(question: turn.question, answer: turn.answer,
                                     sources: turn.sources,
                                     openSource: { recorder.openMeeting($0) })
                        }
                    } else {
                        ForEach(recorder.chatTurns) { turn in
                            TurnView(question: turn.question, answer: turn.answer)
                        }
                    }
                    if recorder.isAnswering {
                        TurnView(question: pendingQuestion, answer: nil,
                                 waitingText: isAll ? "Toplantılar taranıyor…"
                                                    : "Transkript taranıyor…")
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
            .onChange(of: recorder.crossTurns.count) { _, _ in
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
                        .background(Color.oraSurface)
                        .clipShape(RoundedRectangle(cornerRadius: OraStyle.cornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: OraStyle.cornerRadius)
                                .stroke(Color.oraBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

    private var emptyIcon: String {
        if isDisabledDuringRecording { "pause.circle" }
        else if !availability.isAvailable { "sparkles" }
        else if !hasSource { isAll ? "waveform" : "text.alignleft" }
        else { isAll ? "rectangle.stack" : "bubble.left.and.bubble.right" }
    }

    private var emptyTitle: String {
        if isDisabledDuringRecording { "Sohbet şu anda kapalı" }
        else if !availability.isAvailable { availability.turkishMessage }
        else if !hasSource { isAll ? "Henüz toplantı yok" : "Önce bir toplantı seçin" }
        else { isAll ? "Tüm toplantılarınıza sorun" : "Bu toplantıya soru sorun" }
    }

    private var emptyDetail: String {
        if isDisabledDuringRecording {
            return "Toplantı bittikten sonra kullanılabilir."
        }
        if !availability.isAvailable {
            return availability.turkishDetail
        }
        if isAll {
            return hasSource
                ? "Soru transkriptlerde aranır; yalnızca bulunan bölümler bu Mac'teki "
                    + "modele verilir. Bir konu, kişi ya da ürün adıyla sorun — örneğin "
                    + "“Acme teklifinde fiyat ne konuşuldu?”"
                : "Kaydettiğiniz toplantılar birikince hepsine birden soru sorabilirsiniz."
        }
        return recorder.transcript.isEmpty
            ? "Transkripti olan bir toplantı seçtiğinizde sorularınızı yanıtlarım."
            : "Yanıtlar yalnızca bu toplantının transkriptinden çıkarılır."
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if !isEmpty { Divider().overlay(Color.oraBorder) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $question, axis: .vertical)
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
                            .stroke(isInputFocused ? Color.oraInk.opacity(0.35) : Color.oraBorder,
                                    lineWidth: 1)
                    )
                    .onSubmit(ask)
                    .disabled(!canAsk)

                Button(action: ask) {
                    Image(systemName: canAsk && !question.isEmpty
                          ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(canAsk && !question.isEmpty
                                         ? Color.oraInk : Color.oraInkMuted.opacity(0.4))
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
        let all = isAll
        Task {
            if all { await recorder.askAcross(text) } else { await recorder.ask(text) }
        }
    }
}

/// Bir soru-cevap çifti. Soru vurgulu bir başlık, yanıt okunur bir gövde —
/// baloncuk yok, uzun metin okunacak bir yüzeyde baloncuk okumayı zorlaştırır.
private struct TurnView: View {
    let question: String
    /// `nil` ise yanıt bekleniyor.
    let answer: String?
    /// Toplantılar arası yanıtın dayandığı toplantılar.
    var sources: [MeetingStore.CrossTurn.Source] = []
    var openSource: ((Int64) -> Void)?
    var waitingText = "Transkript taranıyor…"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.oraCarmine)
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
                if !sources.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(sources) { source in
                            Button {
                                openSource?(source.id)
                            } label: {
                                Label("\(source.title) · "
                                      + source.date.formatted(date: .abbreviated, time: .omitted),
                                      systemImage: "text.alignleft")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.oraInkMuted)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .help("Kaynak toplantıyı aç")
                        }
                    }
                    .padding(.leading, 11)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(waitingText)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.oraInkMuted)
                }
                .padding(.leading, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
