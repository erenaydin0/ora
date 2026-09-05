import SwiftUI

/// Orta panel. Sekmeler **Özet | Transkript** — "Konuşmacılar" sekmesi yoktur
/// (DESIGN.md §4).
struct MeetingDetail: View {

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Özet"
        case transcript = "Transkript"
        var id: String { rawValue }
    }

    let recorder: RecordingController

    @State private var tab: Tab = .summary
    /// Konu başlığından transkripte atlarken hedeflenen an.
    @State private var jumpTarget: TimeInterval?

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
                loaded(meeting: meeting)
            } else if hasContent {
                loaded(meeting: nil)
            } else {
                EmptyState(
                    icon: "text.alignleft",
                    title: "Toplantı seçilmedi",
                    detail: "Soldan bir toplantı seçin veya yeni bir kayıt başlatın."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.oraPaper)
    }

    @ViewBuilder
    private func loaded(meeting: MeetingListItem?) -> some View {
        VStack(spacing: 0) {
            // Başlık ve sekme aynı satırda: kimlik solda, görünüm anahtarı sağda.
            // İkisini alt alta koymak başlığa gereksiz yükseklik veriyordu.
            MeetingHeader(meeting: meeting, tab: $tab)

            if recorder.canRetry {
                RetryNotice(recorder: recorder)
            }

            if recorder.isTranscribing {
                TranscriptionProgressBar(stage: recorder.transcriptionStage)
            }

            Divider().overlay(Color.oraBorder)

            switch tab {
            case .summary:
                SummaryView(summary: recorder.summary,
                            topics: recorder.topics,
                            actions: recorder.actions,
                            notice: recorder.summaryNotice
                                ?? (recorder.canSummarize
                                    ? "Bu toplantının özeti yok." : nil),
                            participants: recorder.calendarParticipants,
                            onSummarizeNow: recorder.deferReason != nil
                                || recorder.canSummarize
                                ? { Task { await recorder.summarizeNow() } } : nil,
                            onToggleAction: { recorder.setActionDone($0.id, !$0.isDone) },
                            onOpenTopic: recorder.displayedSegments.isEmpty ? nil : { topic in
                                jumpTarget = topic.start
                                withAnimation(OraStyle.transition) { tab = .transcript }
                            })
            case .transcript:
                TranscriptView(segments: recorder.displayedSegments,
                               jumpTarget: $jumpTarget,
                               onCorrect: recorder.canCorrect
                                   ? { segment, text in
                                       Task { await recorder.correct(segment, to: text) }
                                     }
                                   : nil)
            }
        }
    }
}

/// Ses diskte ama transkript yok — hata mesajının vaat ettiği tekrar denemenin
/// gerçek yüzeyi. Sessizce yarım kalmış bir toplantı bırakılmaz.
private struct RetryNotice: View {

    let recorder: RecordingController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .foregroundStyle(Color.oraInkMuted)
            Text("Bu toplantı yazıya dökülmedi. Ham ses kaydı duruyor.")
                .font(.system(size: 13))
                .foregroundStyle(Color.oraInk)
            Spacer()
            Button("Yeniden dene") { Task { await recorder.retryProcessing() } }
        }
        .padding(10)
        .oraCard()
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

/// Seçili toplantının kimliği: başlık, tarih, süre ve tamamlanmamışsa nedeni —
/// solda; görünüm sekmesi sağda, başlıkla aynı yatay hizada.
private struct MeetingHeader: View {

    let meeting: MeetingListItem?
    @Binding var tab: MeetingDetail.Tab

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting?.title ?? "Yeni kayıt")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.oraInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                if meeting != nil {
                    HStack(spacing: 6) {
                        Chip(icon: "calendar", text: meeting?.dateLabel ?? "")
                        if let duration = meeting?.duration, duration > 0 {
                            Chip(icon: "clock", text: meeting?.durationLabel ?? "")
                        }
                        if let statusNote {
                            Chip(icon: "exclamationmark.circle", text: statusNote)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: $tab) {
                ForEach(MeetingDetail.Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var statusNote: String? {
        switch meeting?.status {
        case MeetingRecord.Status.recording.rawValue:  "yarım kalmış kayıt"
        case MeetingRecord.Status.processing.rawValue: "işleniyor"
        default: nil
        }
    }
}

/// Tarih ve süre çipi. Tek birleşik metin satırı tarama için zayıftı; çipler
/// iki bağımsız veriyi ayrı ayrı okunur kılıyor.
private struct Chip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .symbolRenderingMode(.monochrome)
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(Color.oraInkMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous)
                .fill(Color.oraChrome))
    }
}


/// İşlem sürerken sessiz bekleme yok — her aşama Türkçe yazar.
struct TranscriptionProgressBar: View {

    let stage: RecordingController.Stage

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Color.oraCarmine)
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
