import SwiftUI

/// Kayıt sırasında kullanıcının kendi notları (COMPETITION.md §4.6).
///
/// Kural #1'i ihlal etmez: burada yalnızca **yazı yazılır**, model çağrılmaz.
/// Kayıt bitince özetleyici notları iskelet olarak alır ve altlarına
/// transkriptten ayrıntı ekler.
struct LiveNotesPane: View {

    let notes: [UserNote]
    /// Kayıtta geçen süre — notun zaman damgası.
    let elapsed: () -> TimeInterval
    let onAdd: (String, TimeInterval?) -> Void
    let onUpdate: (UserNote, String) -> Void
    let onDelete: (UserNote) -> Void
    let onMark: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("NOTLARIM")
                    .font(.system(size: 13, weight: .medium))
                    .kerning(0.8)
                    .foregroundStyle(Color.oraInk)
                Spacer()
                MarkButton(action: onMark)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if notes.isEmpty {
                            Text("Önemli bulduklarınızı kısa maddeler hâlinde yazın. "
                                 + "Kayıt bitince özet bu maddeleri iskelet olarak alır ve "
                                 + "altlarına transkriptten ayrıntı ekler.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.oraInkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(notes) { note in
                            NoteRow(note: note, onUpdate: onUpdate, onDelete: onDelete)
                                .id(note.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: notes.count) { _, _ in
                    guard let last = notes.last?.id else { return }
                    withAnimation(OraStyle.transition) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }

            Divider().overlay(Color.oraBorder)
            NoteComposer(placeholder: "Not yazın, Enter ile ekleyin",
                         elapsed: elapsed, onAdd: onAdd)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Özet sekmesinde "Notlarım" bölümü: kullanıcının yazdığı mürekkeple,
/// transkriptten eklenen ayrıntı soluk tonla (Granola'nın ayrımı, BRAND
/// paletinin kendi tonlarıyla).
struct NotesSection: View {

    let notes: [UserNote]
    var onAdd: ((String) -> Void)?
    var onUpdate: ((UserNote, String) -> Void)?
    var onDelete: ((UserNote) -> Void)?
    /// Zamanlı notun kayıttaki yerine gider.
    var onOpen: ((UserNote) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NOTLARIM")
                .font(.system(size: 13, weight: .medium))
                .kerning(0.8)
                .foregroundStyle(Color.oraInk)
            ForEach(notes) { note in
                NoteRow(note: note, onUpdate: onUpdate, onDelete: onDelete,
                        onOpen: note.at == nil ? nil : onOpen.map { open in { open(note) } })
            }
            if let onAdd {
                NoteComposer(placeholder: notes.isEmpty ? "Bu toplantıya not ekleyin"
                                                        : "Not ekle",
                             elapsed: nil) { text, _ in onAdd(text) }
            }
        }
    }
}

/// Tek not ya da işaret. Çift tık düzenler; bağlam menüsü düzenler ve siler.
struct NoteRow: View {

    let note: UserNote
    var onUpdate: ((UserNote, String) -> Void)?
    var onDelete: ((UserNote) -> Void)?
    var onOpen: (() -> Void)?

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if note.isMark {
                // BRAND: Carmine Deep yalnızca işaret içindir.
                Image(systemName: "flag.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.oraCarmineDeep)
                    .accessibilityLabel("Önemli an")
            } else {
                Text("•").foregroundStyle(Color.oraInkMuted)
            }

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField(note.isMark ? "Bu anı adlandırın" : "Not", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.oraInk)
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { isEditing = false }
                } else {
                    Text(note.displayText)
                        .font(.system(size: 14, weight: note.isMark && note.text.isEmpty
                                      ? .regular : .medium))
                        .foregroundStyle(note.isMark && note.text.isEmpty
                                         ? Color.oraInkMuted : Color.oraInk)
                        .lineSpacing(OraStyle.bodyLineSpacing - 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                ForEach(Array(note.details.enumerated()), id: \.offset) { _, detail in
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.oraInkMuted)
                        .lineSpacing(OraStyle.bodyLineSpacing - 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let label = note.timeLabel {
                Group {
                    if let onOpen {
                        Button(action: onOpen) {
                            Text(label)
                        }
                        .buttonStyle(.plain)
                        .help("Transkriptte bu ana git")
                    } else {
                        Text(label)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.oraInkMuted)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startEditing() }
        .contextMenu {
            if onUpdate != nil {
                Button(note.isMark ? "Adlandır" : "Düzenle") { startEditing() }
            }
            if let onDelete {
                Button("Sil", role: .destructive) { onDelete(note) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func startEditing() {
        guard onUpdate != nil else { return }
        draft = note.text
        isEditing = true
        focused = true
    }

    private func commit() {
        isEditing = false
        guard draft != note.text else { return }
        onUpdate?(note, draft)
    }
}

/// Not yazma alanı. Kayıt sürerken zaman damgası yazmaya **başlanan** andır:
/// not duyulanın arkasından yazılır, Enter'a basıldığı an geç kalır.
struct NoteComposer: View {

    let placeholder: String
    /// Kayıtta geçen süre; kayıt dışında nil.
    let elapsed: (() -> TimeInterval)?
    let onAdd: (String, TimeInterval?) -> Void

    @State private var draft = ""
    @State private var startedAt: TimeInterval?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Color.oraInk)
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.oraSurface)
            .clipShape(RoundedRectangle(cornerRadius: OraStyle.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: OraStyle.cornerRadius)
                    .stroke(focused ? Color.oraInk.opacity(0.35) : Color.oraBorder, lineWidth: 1)
            )
            .onChange(of: draft) { old, new in
                if old.isEmpty, !new.isEmpty { startedAt = elapsed?() }
                if new.isEmpty { startedAt = nil }
            }
            .onSubmit {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                onAdd(text, startedAt)
                draft = ""
                startedAt = nil
                focused = true
            }
    }
}

/// "Önemli an" düğmesi. Kısayolu ⌃⌘M — kayıt sürerken sistem genelinde.
struct MarkButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Önemli an", systemImage: "flag")
                .font(.system(size: 12))
        }
        .help("Bu anı önemli olarak işaretle (⌃⌘M)")
        .accessibilityLabel("Bu anı önemli olarak işaretle")
    }
}
