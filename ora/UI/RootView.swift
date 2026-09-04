import SwiftUI

/// Ana pencere: `NavigationSplitView` (kenar çubuğu + içerik) + katlanabilir `.inspector`.
/// Faz 1'de veri yok — yüzeyler ve boş durumlar ayakta.
struct RootView: View {

    @State private var selection: Meeting.ID?
    @State private var searchText = ""
    @State private var isChatShown = false

    var body: some View {
        NavigationSplitView {
            MeetingSidebar(selection: $selection, searchText: $searchText)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
        } detail: {
            MeetingDetail(meetingID: selection)
        }
        .inspector(isPresented: $isChatShown) {
            ChatInspector()
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                RecordButton()
            }
            ToolbarItem {
                Button {
                    withAnimation(OraStyle.transition) { isChatShown.toggle() }
                } label: {
                    Label("Sohbet", systemImage: "bubble.left.and.text.bubble.right")
                }
                .help("Sohbet panelini aç/kapat")
            }
        }
        .navigationTitle("ora")
    }
}

/// Kayıt butonu — BRAND kural #9: Active Red yalnızca burada ve menü bar noktasında.
/// Faz 1'de görsel; gerçek kayıt Faz 2'de bağlanır.
private struct RecordButton: View {
    var body: some View {
        Button {
            // Faz 2: Capture.start()
        } label: {
            Label("Kaydet", systemImage: "record.circle")
                .foregroundStyle(Color.oraRed)
        }
        .help("Kaydı başlat")
        .disabled(true)
    }
}

#Preview {
    RootView()
        .frame(width: 1100, height: 700)
}
