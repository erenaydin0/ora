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

    /// Gösterilecek bir toplantı içeriği var mı — seçim yokken de kayıt sonrası
    /// akış bu yoldan görünür.
    private var hasContent: Bool {
        !recorder.displayedSegments.isEmpty || recorder.isTranscribing
            || recorder.summary != nil
    }

    var body: some View {
        Group {
            // Seçim varsa panel **her zaman** açılır: transkripti veya özeti
            // olmayan bir toplantı da başlığıyla ve kendi boş durumuyla görünür.
            // Aksi hâlde kullanıcı bir satıra tıklar ve hiçbir şey olmaz.
            if let meeting = recorder.selectedMeeting {
                loaded(header: MeetingHeader(meeting: meeting))
            } else if hasContent {
                loaded(header: nil)
            } else {
                EmptyState(
                    icon: "text.bubble",
                    title: "Toplantı seçilmedi",
                    detail: "Soldan bir toplantı seçin veya yeni bir kayıt başlatın."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.oraPaper)
    }

    @ViewBuilder
    private func loaded(header: MeetingHeader?) -> some View {
        VStack(spacing: 0) {
            if let header { header }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.horizontal, 16)
            .padding(.top, header == nil ? 16 : 0)
            .padding(.bottom, 16)

            if recorder.isTranscribing {
                TranscriptionProgressBar(stage: recorder.transcriptionStage)
            }

            Divider().overlay(Color.oraBorder)

            switch tab {
            case .summary:
                SummaryView(summary: recorder.summary,
                            topics: recorder.topics,
                            metrics: recorder.metrics,
                            notice: recorder.summaryNotice,
                            calendarParticipants: recorder.calendarParticipants,
                            onSummarizeNow: recorder.deferReason == nil ? nil : {
                                Task { await recorder.summarizeNow() }
                            })
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

/// Seçili toplantının kimliği: başlık, tarih, süre ve tamamlanmamışsa nedeni.
private struct MeetingHeader: View {

    let meeting: MeetingListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.oraInk)
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(meeting.dateLabel)
                if meeting.duration > 0 {
                    Text("·")
                    Text(meeting.durationLabel)
                }
                if let note = statusNote {
                    Text("·")
                    Text(note)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.oraInkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var statusNote: String? {
        switch meeting.status {
        case MeetingRecord.Status.recording.rawValue:  "yarım kalmış kayıt"
        case MeetingRecord.Status.processing.rawValue: "işleniyor"
        default: nil
        }
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
