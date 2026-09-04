import SwiftUI

/// Sol kenar çubuğu: arama + toplantı listesi.
/// Faz 1'de liste her zaman boştur; arama FTS5'e Faz 5'te bağlanır.
struct MeetingSidebar: View {

    @Binding var selection: Meeting.ID?
    @Binding var searchText: String

    private let meetings: [Meeting] = []

    var body: some View {
        List(meetings, selection: $selection) { meeting in
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.oraInk)
                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Toplantılarda ara")
        .overlay {
            if meetings.isEmpty {
                EmptyState(
                    icon: "waveform",
                    title: "Henüz toplantı yok",
                    detail: "Kaydettiğiniz toplantılar burada listelenir."
                )
                .padding(.horizontal, 24)
            }
        }
    }
}
