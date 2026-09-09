import SwiftUI

/// Orta panel. Sekmeler **Özet | Transkript** — "Konuşmacılar" sekmesi yoktur
/// (DESIGN.md §4).
struct MeetingDetail: View {

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Özet"
        case transcript = "Transkript"
        var id: String { rawValue }

        /// Dar pencerede sekme etiketleri yerine simge kullanılır — iki kelime
        /// 165 pt yer kaplıyor ve o yer başlıktan çalınıyor.
        var icon: String {
            switch self {
            case .summary:    "list.bullet.rectangle"
            case .transcript: "text.alignleft"
            }
        }
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
    /// Yeniden özetleme onayı — yalnızca işaretlenmiş aksiyon varsa sorulur.
    @State private var confirmingResummarize = false

    /// Gösterilecek bir toplantı içeriği var mı — seçim yokken de kayıt sonrası
    /// akış bu yoldan görünür.
    private var hasContent: Bool {
        !recorder.displayedSegments.isEmpty || recorder.isProcessingSelected
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

            Group {
                switch tab {
                case .summary:
                    // İşlem sürerken Özet'te gösterilecek bir şey yok; beklenen
                    // şeyin yerinde beklemek doğrusu. Transkript sekmesi bu
                    // sırada canlı metni göstermeye devam eder.
                    //
                    // Animasyon **işlenen toplantı seçiliyken** görünür: hat
                    // arkada başka bir toplantı için koşuyorsa bu ekran kendi
                    // özetini göstermeye devam eder.
                    if recorder.isProcessingSelected {
                        ProcessingState(stage: recorder.transcriptionStage)
                    } else {
                        SummaryView(
                            summary: recorder.summary,
                            topics: recorder.topics,
                            actions: recorder.actions,
                            notice: recorder.summaryNotice
                                ?? recorder.busyNotice
                                ?? (recorder.canSummarize
                                    ? "Bu toplantının özeti yok." : nil),
                            participants: recorder.calendarParticipants,
                            speakers: recorder.speakingParticipants,
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
                                ? { Task { await recorder.retryProcessing() } } : nil,
                            onResummarize: recorder.canResummarize ? {
                                // İşaretli aksiyon varsa yeniden üretim onu
                                // sıfırlar; sormadan yapılmaz.
                                if recorder.hasCompletedActions {
                                    confirmingResummarize = true
                                } else {
                                    Task { await recorder.resummarize() }
                                }
                            } : nil)
                    }
                case .transcript:
                    TranscriptView(
                        segments: recorder.displayedSegments,
                        jumpTarget: $jumpTarget,
                        playback: playback.isAvailable ? playback : nil,
                        onRetry: recorder.canRetry
                            ? { Task { await recorder.retryProcessing() } } : nil,
                        onCorrect: recorder.canCorrect
                            ? { segment, text in
                                Task { await recorder.correct(segment, to: text) }
                              }
                            : nil,
                        onDelete: recorder.canCorrect
                            ? { segment in Task { await recorder.deleteSegment(segment) } }
                            : nil,
                        onRelabel: recorder.canCorrect
                            ? { segment, speaker in
                                Task { await recorder.setSpeaker(segment, to: speaker) }
                              }
                            : nil,
                        onRelabelAll: recorder.canCorrect
                            ? { label, channel, speaker in
                                Task {
                                    await recorder.setSpeaker(allLabeled: label,
                                                              in: channel, to: speaker)
                                }
                              }
                            : nil,
                        speakerCandidates: recorder.speakerCandidates,
                        speakerLineCount: { label, channel in
                            recorder.speakerLineCount(label: label, in: channel)
                        },
                        find: $findText,
                        isFinding: $isFinding)
                }
            }
            // Oynatıcı içeriğin **üstünde** yüzer; şerit olarak yer kaplamaz.
            // Altta ayrılan boşluk, son satırın kalıcı olarak panelin altında
            // kalmasını önler.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if playback.isAvailable { Color.clear.frame(height: 52) }
            }
            .overlay(alignment: .bottom) {
                if playback.isAvailable { PlaybackBar(playback: playback) }
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
        .alert("Özeti yeniden oluştur", isPresented: $confirmingResummarize) {
            Button("Vazgeç", role: .cancel) { confirmingResummarize = false }
            Button("Yeniden oluştur") {
                confirmingResummarize = false
                Task { await recorder.resummarize() }
            }
        } message: {
            Text("Yeni özet mevcut özetin yerine geçer ve aksiyonlar yeniden "
                 + "üretilir; tamamlandı işaretleriniz silinir. "
                 + "Transkript ve ses değişmez.")
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

    /// Başlığın gerçekten kullanabileceği genişlik. Sekme seçici sabit
    /// genişlikte olduğu için dar pencerede başlığa yer kalmıyordu; ölçülen
    /// genişliğe göre seçici simgeye iner.
    @State private var width: CGFloat = 0
    private var isCompact: Bool { width > 0 && width < 520 }

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
                    // Dar pencerede çipler sıkışıp harf harf alt alta iniyordu.
                    // `ViewThatFits` sığanı seçer: önce hepsi, sonra tarih +
                    // durum, en dar hâlde yalnızca tarih. Çipler `fixedSize`
                    // olduğu için hiçbiri ezilmez.
                    ViewThatFits(in: .horizontal) {
                        chips(showsDuration: true, showsStatus: true)
                        chips(showsDuration: false, showsStatus: true)
                        chips(showsDuration: false, showsStatus: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

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

            // Geniş pencerede sistem sekmesi; dar pencerede simge sekmesi.
            // Sistem `Picker`'ı `Label`'ı simgeye indirmiyor (etiketi de
            // çiziyor), o yüzden dar hâl elle çizilir — 165 pt yerine ~70 pt.
            if isCompact {
                CompactTabs(tab: $tab)
            } else {
                Picker("", selection: $tab) {
                    ForEach(MeetingDetail.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// Başlığın altındaki çip satırı. Hangi çiplerin çizileceği
    /// `ViewThatFits` tarafından seçilir.
    @ViewBuilder
    private func chips(showsDuration: Bool, showsStatus: Bool) -> some View {
        HStack(spacing: 6) {
            Chip(icon: "calendar", text: meeting?.dateLabel ?? "")
            if showsDuration, let duration = meeting?.duration, duration > 0 {
                Chip(icon: "clock", text: meeting?.durationLabel ?? "")
            }
            if showsStatus, let statusNote {
                Chip(icon: "exclamationmark.circle", text: statusNote)
            }
        }
        .fixedSize()
    }

    private var statusNote: String? {
        switch meeting?.status {
        case MeetingRecord.Status.recording.rawValue:  "yarım kalmış kayıt"
        case MeetingRecord.Status.processing.rawValue: "işleniyor"
        default: nil
        }
    }
}

/// Dar pencerede sekme: yalnızca simge. Seçili sekme, kenar çubuğu kartıyla
/// aynı dili konuşur — dolu Carmine, kâğıt rengi simge.
private struct CompactTabs: View {
    @Binding var tab: MeetingDetail.Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MeetingDetail.Tab.allCases) { item in
                Button { tab = item } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(tab == item ? Color.oraPaper : Color.oraInk)
                        .frame(width: 30, height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tab == item ? Color.oraCarmine : Color.clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.rawValue)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(tab == item ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous)
                .fill(Color.oraChrome)
        }
        .fixedSize()
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
            Text(text).font(.system(size: 12)).lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(Color.oraInkMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous)
                .fill(Color.oraChrome))
    }
}
