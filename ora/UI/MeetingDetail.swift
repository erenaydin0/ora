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
    /// Kaydın sesi. Şerit iki sekmenin de altında durur — ses görünmeyen bir
    /// yüzeyden gelmez, özet maddesinden de çalınabilir.
    @State private var playback = AudioPlayback()
    /// Toplantı içi arama (⌘F). Kenar çubuğundaki arama toplantıyı bulur;
    /// bu, bulunan toplantının içinde gezdirir.
    @State private var isFinding = false
    @State private var findText = ""
    /// Özet maddesi → transkript eşleştirmesi. Transkript başına **bir kez**
    /// kurulur; her satır için yeniden hesaplamak listeyi yavaşlatırdı.
    @State private var index = TranscriptIndex([])

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
            MeetingHeader(meeting: meeting, tab: $tab,
                          canFind: !recorder.displayedSegments.isEmpty,
                          find: {
                              tab = .transcript
                              isFinding = true
                          })

            Divider().overlay(Color.oraBorder)

            switch tab {
            case .summary:
                // İşlem sürerken Özet'te gösterilecek bir şey yok; beklenen şeyin
                // yerinde beklemek doğrusu. Transkript sekmesi bu sırada canlı
                // metni göstermeye devam eder.
                if recorder.isTranscribing {
                    ProcessingState(stage: recorder.transcriptionStage)
                } else {
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
                                open(at: topic.start)
                            },
                            openText: index.isEmpty ? nil : { text in
                                guard let segment = index.match(text) else { return }
                                open(at: segment.start)
                            },
                            canOpenText: index.isEmpty ? nil : { index.match($0) != nil },
                            onRetry: recorder.canRetry
                                ? { Task { await recorder.retryProcessing() } } : nil)
                }
            case .transcript:
                TranscriptView(segments: recorder.displayedSegments,
                               jumpTarget: $jumpTarget,
                               playback: playback.isAvailable ? playback : nil,
                               onRetry: recorder.canRetry
                                   ? { Task { await recorder.retryProcessing() } } : nil,
                               onCorrect: recorder.canCorrect
                                   ? { segment, text in
                                       Task { await recorder.correct(segment, to: text) }
                                     }
                                   : nil,
                               find: $findText,
                               isFinding: $isFinding)
            }

            if playback.isAvailable {
                PlaybackBar(playback: playback)
            }
        }
        // Seçim değişince oynatıcı yeni kaydın sesine bağlanır; ses yoksa kapanır.
        .onChange(of: recorder.selection) { _, _ in
            isFinding = false
            findText = ""
        }
        .onAppear {
            playback.load(recorder.audioURL)
            index = TranscriptIndex(recorder.displayedSegments)
        }
        .onChange(of: recorder.audioURL) { _, url in playback.load(url) }
        .onChange(of: recorder.displayedSegments) { _, segments in
            index = TranscriptIndex(segments)
        }
        .onDisappear { playback.pause() }
    }

    /// Özet maddesinden transkripte geçiş: sekme değişir, satıra kaydırılır ve
    /// **oynatıcı da o ana kurulur** — kullanıcı yalnızca Çal'a basar.
    /// Kendiliğinden çalmaz; ses beklenmedik anda başlamamalı.
    private func open(at time: TimeInterval) {
        jumpTarget = time
        if playback.isAvailable { playback.seek(to: time) }
        withAnimation(OraStyle.transition) { tab = .transcript }
    }
}

/// Seçili toplantının kimliği: başlık, tarih, süre ve tamamlanmamışsa nedeni —
/// solda; görünüm sekmesi sağda, başlıkla aynı yatay hizada.
private struct MeetingHeader: View {

    let meeting: MeetingListItem?
    @Binding var tab: MeetingDetail.Tab
    /// Transkript yoksa arama düğmesi görünmez.
    var canFind = false
    var find: () -> Void = {}

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

            if canFind {
                Button(action: find) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.oraInkMuted)
                }
                .buttonStyle(.plain)
                // Görünür düğme olduğu için kısayol menü çubuğu gerektirmeden
                // çalışır; pencere ön plandayken ⌘F transkripte geçer.
                .keyboardShortcut("f", modifiers: .command)
                .help("Transkriptte ara (⌘F)")
                .accessibilityLabel("Transkriptte ara")
            }

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
