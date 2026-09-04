import SwiftUI

/// Orta panel. Sekmeler **Özet | Transkript** — "Konuşmacılar" sekmesi yoktur,
/// istatistikler Özet'in içindeki kompakt kartta durur (DESIGN.md §4).
struct MeetingDetail: View {

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Özet"
        case transcript = "Transkript"
        var id: String { rawValue }
    }

    let recorder: RecordingController

    @State private var tab: Tab = .summary

    private var hasContent: Bool {
        !recorder.displayedSegments.isEmpty || recorder.isTranscribing
            || recorder.summary != nil
    }

    var body: some View {
        Group {
            if !hasContent {
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

                    if recorder.isTranscribing {
                        TranscriptionProgressBar(stage: recorder.transcriptionStage)
                    }

                    Divider().overlay(Color.oraBorder)

                    switch tab {
                    case .summary:
                        SummaryView(summary: recorder.summary,
                                    topics: recorder.topics,
                                    metrics: recorder.metrics,
                                    notice: recorder.summaryNotice)
                    case .transcript:
                        TranscriptView(segments: recorder.displayedSegments,
                                       onCorrect: recorder.canCorrect
                                           ? { segment, text in
                                               Task { await recorder.correct(segment, to: text) }
                                             }
                                           : nil)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.oraPaper)
    }
}

/// İşlem sürerken sessiz bekleme yok — her aşama Türkçe yazar.
struct TranscriptionProgressBar: View {

    let stage: RecordingController.Stage

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Color.oraBlue)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInkMuted)
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var fraction: Double {
        switch stage {
        case .downloadingLanguage(let value), .transcribing(let value),
             .punctuating(let value), .summarizing(let value): value
        case .preparingLanguage: 0
        case .idle, .done: 1
        }
    }

    private var label: String {
        switch stage {
        case .preparingLanguage:            "Dil hazırlanıyor…"
        case .downloadingLanguage(let v):   "Dil paketi indiriliyor · \(Int(v * 100))%"
        case .transcribing(let v):          "Yazıya dökülüyor · \(Int(v * 100))%"
        case .punctuating(let v):           "Noktalama ekleniyor · \(Int(v * 100))%"
        case .summarizing(let v):           "Özetleniyor · \(Int(v * 100))%"
        case .idle, .done:                  ""
        }
    }
}
