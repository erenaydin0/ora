import SwiftUI

/// Transkript listesi. Kesinleşmemiş canlı metin `.oraInkMuted` ile gösterilir —
/// bu ton farkı, canlı sonucun bir **ön izleme** olduğunu ve kayıt sonrası tam
/// geçişte değişebileceğini söyler (DESIGN.md §4).
struct TranscriptView: View {

    let segments: [Segment]
    var volatileText: [Int: String] = [:]
    var notice: String?
    /// Nil ise düzeltme kapalıdır (canlı modda düzeltme yapılmaz).
    var onCorrect: ((Segment, String) -> Void)?

    @State private var editing: Segment.ID?
    @State private var draft = ""

    var body: some View {
        if segments.isEmpty && volatileText.isEmpty {
            EmptyState(icon: "text.alignleft",
                       title: "Transkript yok",
                       detail: "Kayıt sırasında canlı transkript burada akar.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let notice {
                            Text(notice)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.oraInkMuted)
                                .padding(10)
                                .oraCard()
                        }
                        ForEach(segments) { segment in
                            if editing == segment.id, onCorrect != nil {
                                CorrectionEditor(text: $draft) {
                                    onCorrect?(segment, draft)
                                    editing = nil
                                } cancel: {
                                    editing = nil
                                }
                            } else {
                                SegmentRow(segment: segment)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        guard onCorrect != nil else { return }
                                        draft = segment.text
                                        editing = segment.id
                                    }
                                    .help(onCorrect == nil ? ""
                                          : "Düzeltmek için çift tıklayın")
                            }
                        }
                        ForEach(volatileLines, id: \.0) { channel, text in
                            VolatileRow(speaker: channel.speaker, text: text)
                        }
                        Color.clear.frame(height: 1).id("son")
                    }
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: segments.count) { _, _ in
                    withAnimation(OraStyle.transition) { proxy.scrollTo("son", anchor: .bottom) }
                }
            }
        }
    }

    private var volatileLines: [(Channel, String)] {
        Channel.allCases.compactMap { channel in
            guard let text = volatileText[channel.rawValue], !text.isEmpty else { return nil }
            return (channel, text)
        }
    }
}

private struct SegmentRow: View {
    let segment: Segment

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(segment.speaker)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(segment.channel == .mic ? Color.oraBlue : Color.oraInk)
                Text(segment.timeLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.oraInkMuted)
            }
            Text(segment.text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.oraInk)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Kesinleşmemiş metin. VoiceOver bunu okumaz — sürekli değişir (DESIGN.md §6).
private struct VolatileRow: View {
    let speaker: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(speaker)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.oraInkMuted)
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.oraInkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityHidden(true)
    }
}


/// Transkript satırını yerinde düzeltme. Kaydedilen düzeltme `corrections`
/// tablosuna da yazılır ve Faz 6'da özel sözlüğü besleyecektir.
private struct CorrectionEditor: View {
    @Binding var text: String
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Düzeltilmiş metin", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.oraInk)
                .padding(8)
                .oraCard()
                .onSubmit(save)
            HStack(spacing: 8) {
                Spacer()
                Button("Vazgeç", role: .cancel, action: cancel)
                Button("Kaydet", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .onExitCommand(perform: cancel)
    }
}
