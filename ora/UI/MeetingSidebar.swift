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
            ForEach(groups) { group in
                Section {
                    ForEach(group.meetings) { meeting in
                        row(meeting)
                            .tag(meeting.id)
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

    private func row(_ meeting: MeetingListItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if meeting.status != MeetingRecord.Status.ready.rawValue {
                    Image(systemName: meeting.status == MeetingRecord.Status.recording.rawValue
                          ? "record.circle" : "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(meeting.status == MeetingRecord.Status.recording.rawValue
                                         ? Color.oraRed : Color.oraInkMuted)
                }
                Text(meeting.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.oraInk)
                    .lineLimit(1)
            }
            Text(secondaryLine(meeting))
                .font(.system(size: 11))
                .foregroundStyle(Color.oraInkMuted)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

/// Kenar çubuğunda bir gün/dönem başlığı ve altındaki toplantılar.
private struct MeetingGroup: Identifiable {
    let id: String
    var meetings: [MeetingListItem]
}

private extension MeetingSidebar {
    /// Saat · süre. Gün bilgisi grup başlığında, satırda tekrar edilmez.
    func secondaryLine(_ meeting: MeetingListItem) -> String {
        meeting.duration > 0
            ? "\(meeting.timeLabel) · \(meeting.durationLabel)"
            : meeting.timeLabel
    }
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
