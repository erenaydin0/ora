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
            ForEach(recorder.meetings) { meeting in
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

    private func row(_ meeting: MeetingListItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if meeting.status != MeetingRecord.Status.ready.rawValue {
                    Image(systemName: meeting.status == MeetingRecord.Status.recording.rawValue
                          ? "record.circle" : "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(meeting.status == MeetingRecord.Status.recording.rawValue
                                         ? Color.oraRed : Color.oraInkMuted)
                }
                Text(meeting.title)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.oraInk)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(meeting.dateLabel)
                if meeting.duration > 0 {
                    Text("·")
                    Text(meeting.durationLabel)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.oraInkMuted)
        }
        .padding(.vertical, 2)
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
