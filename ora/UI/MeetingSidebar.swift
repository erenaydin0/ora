import SwiftUI

/// Sol kenar çubuğu: arama + toplantı listesi.
/// Arama hem başlıkta hem FTS5 üzerinden transkript içinde çalışır.
struct MeetingSidebar: View {

    @Bindable var recorder: RecordingController
    @State private var renaming: Int64?
    @State private var draftTitle = ""
    @State private var confirmingDelete: MeetingListItem?

    var body: some View {
        List(selection: $recorder.selection) {
            // Pano listenin **üstünde** ve seçime dahil değil: bir toplantı
            // değil, toplantılar arası bir görünüm. Kendi vurgusunu çizer.
            Section {
                ActionBoardRow(count: recorder.openActionCount,
                               isSelected: recorder.showsActionBoard) {
                    recorder.showsActionBoard = true
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.meetings) { meeting in
                        MeetingRow(meeting: meeting,
                                   isSelected: recorder.selection == meeting.id,
                                   snippet: recorder.searchSnippets[meeting.id])
                            .tag(meeting.id)
                            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button("Yeniden adlandır") {
                                    draftTitle = meeting.title
                                    renaming = meeting.id
                                }
                                Divider()
                                Button("Sil", role: .destructive) { confirmingDelete = meeting }
                            }
                    }
                } header: {
                    Text(group.id.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(Color.oraInkMuted)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $recorder.searchText, placement: .sidebar,
                    prompt: "Toplantılarda ve transkriptlerde ara")
        .overlay {
            if recorder.meetings.isEmpty {
                EmptyState(
                    icon: recorder.searchText.isEmpty ? "waveform" : "magnifyingglass",
                    title: recorder.searchText.isEmpty ? "Henüz toplantı yok" : "Sonuç yok",
                    detail: recorder.searchText.isEmpty
                        ? "Kaydettiğiniz toplantılar burada listelenir."
                        : "Başka bir kelime deneyin."
                )
                .padding(.horizontal, 24)
                // Boş durum yalnızca bilgi verir; altındaki pano satırı
                // tıklanabilir kalmalı.
                .allowsHitTesting(false)
            }
        }
        .task { await recorder.refresh() }
        .alert("Toplantıyı sil", isPresented: Binding(
            get: { confirmingDelete != nil },
            set: { if !$0 { confirmingDelete = nil } })) {
            Button("Vazgeç", role: .cancel) { confirmingDelete = nil }
            Button("Sil", role: .destructive) {
                if let meeting = confirmingDelete {
                    Task { await recorder.delete(meeting.id) }
                }
                confirmingDelete = nil
            }
        } message: {
            Text("\"\(confirmingDelete?.title ?? "")\" ve ses kaydı kalıcı olarak silinecek. "
                 + "Bu işlem geri alınamaz.")
        }
        .sheet(item: Binding(
            get: { renaming.map { RenameTarget(id: $0) } },
            set: { if $0 == nil { renaming = nil } })) { target in
            RenameSheet(title: $draftTitle) { newTitle in
                Task { await recorder.rename(target.id, to: newTitle) }
                renaming = nil
            } cancel: {
                renaming = nil
            }
        }
    }

    /// Tarihe göre gruplanmış liste. Sıra korunur — sorgu zaten tarihe göre
    /// azalan geliyor, burada yalnızca ardışık aynı etiketliler toplanır.
    private var groups: [MeetingGroup] {
        var result: [MeetingGroup] = []
        for meeting in recorder.meetings {
            let label = meeting.groupLabel
            if result.last?.id == label {
                result[result.count - 1].meetings.append(meeting)
            } else {
                result.append(MeetingGroup(id: label, meetings: [meeting]))
            }
        }
        return result
    }

}

/// Aksiyon panosuna giriş. Toplantı satırlarıyla aynı ölçüde ve aynı seçim
/// şeridiyle çizilir; ayrımı simge ve açık aksiyon sayısı kurar.
private struct ActionBoardRow: View {
    let count: Int
    let isSelected: Bool
    let open: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
                    .frame(width: 44, alignment: .leading)
                Text("Aksiyonlar")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.oraInk)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.oraInkMuted)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous)
                    .fill(isSelected ? Color.oraChrome
                          : isHovered ? Color.oraChrome.opacity(0.45) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(count > 0 ? "Aksiyonlar, \(count) açık" : "Aksiyonlar")
    }
}

/// Saat omurgası: solda hizalı saat, sağda başlık. Sahte kart yok;
/// seçili satır krem şerit (BRAND: kenar çubuğu Carmine yıkanmaz).
private struct MeetingRow: View {
    let meeting: MeetingListItem
    let isSelected: Bool
    /// Arama transkriptte eşleştiyse eşleşmenin geçtiği yer. Başlıkta eşleşen
    /// bir sonucun parçacığı olmaz; o zaman satır bugünküyle aynı kalır.
    var snippet: String?
    @State private var isHovered = false

    private var isRecording: Bool {
        meeting.status == MeetingRecord.Status.recording.rawValue
    }
    private var isProcessing: Bool {
        meeting.status == MeetingRecord.Status.processing.rawValue
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            timeColumn
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.oraInk)
                    .lineLimit(1)
                if let meta {
                    Text(meta)
                        .font(.system(size: 11))
                        .foregroundStyle(isRecording ? Color.oraRed : Color.oraInkMuted)
                        .lineLimit(1)
                }
                if let snippet {
                    Text(Self.highlighted(snippet))
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous)
                .fill(stripFill)
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var timeColumn: some View {
        Text(meeting.timeLabel)
            .font(.system(size: 12, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Color.oraInkMuted)
            .lineLimit(1)
            .frame(width: 44, alignment: .leading)
    }

    private var meta: String? {
        if isRecording { return "Kayıt sürüyor" }
        if isProcessing { return "İşleniyor" }
        if meeting.duration > 0 { return meeting.durationLabel }
        return nil
    }

    private var stripFill: Color {
        if isSelected { return Color.oraChrome }
        if isHovered { return Color.oraChrome.opacity(0.45) }
        return Color.clear
    }

    private var accessibilityLabel: String {
        var parts = [meeting.timeLabel, meeting.title]
        if let meta { parts.append(meta) }
        if let snippet { parts.append(snippet.replacingOccurrences(of: MeetingStore.mark, with: "")) }
        return parts.joined(separator: ", ")
    }

    /// FTS5'in `snippet()` çıktısı: eşleşen kelimeler `MeetingStore.mark` ile
    /// sarılı gelir. İşaretli parçalar mürekkep ve kalın, gerisi soluk.
    private static func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in text.components(separatedBy: MeetingStore.mark).enumerated() {
            guard !part.isEmpty else { continue }
            var piece = AttributedString(part)
            let isMatch = index % 2 == 1
            piece.foregroundColor = isMatch ? Color.oraInk : Color.oraInkMuted
            if isMatch { piece.font = .system(size: 11, weight: .semibold) }
            result += piece
        }
        return result
    }
}

/// Kenar çubuğunda bir gün/dönem başlığı ve altındaki toplantılar.
private struct MeetingGroup: Identifiable {
    let id: String
    var meetings: [MeetingListItem]
}

private struct RenameTarget: Identifiable { let id: Int64 }

private struct RenameSheet: View {
    @Binding var title: String
    let save: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Toplantı adı")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.oraInk)
            TextField("Toplantı adı", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save(title) }
            HStack {
                Spacer()
                Button("Vazgeç", role: .cancel, action: cancel)
                Button("Kaydet") { save(title) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(Color.oraPaper)
        .onExitCommand(perform: cancel)
    }
}
