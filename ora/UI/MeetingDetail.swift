import SwiftUI

/// Orta panel. Sekmeler **Özet | Transkript** — "Konuşmacılar" sekmesi yoktur,
/// istatistikler Özet'in içindeki kompakt kartta durur (DESIGN.md §4).
struct MeetingDetail: View {

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Özet"
        case transcript = "Transkript"
        var id: String { rawValue }
    }

    let meetingID: Meeting.ID?

    @State private var tab: Tab = .summary

    var body: some View {
        Group {
            if meetingID == nil {
                EmptyState(
                    icon: "text.bubble",
                    title: "Toplantı seçilmedi",
                    detail: "Soldan bir toplantı seçin veya yeni bir kayıt başlatın."
                )
            } else {
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .padding(16)

                    Divider().overlay(Color.oraBorder)

                    ScrollView {
                        switch tab {
                        case .summary:
                            EmptyState(icon: "sparkles",
                                       title: "Özet hazır değil",
                                       detail: "Özetleme kayıt bittikten sonra çalışır.")
                        case .transcript:
                            EmptyState(icon: "text.alignleft",
                                       title: "Transkript yok",
                                       detail: "Kayıt sırasında canlı transkript burada akar.")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.oraPaper)
    }
}
