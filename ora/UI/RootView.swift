import SwiftUI

/// Ana pencere: `NavigationSplitView` (kenar çubuğu + içerik) + katlanabilir `.inspector`.
struct RootView: View {

    let recorder: RecordingController
    @State private var isChatShown = false

    /// Kenar çubuğu (240) + okunabilir bir orta panel. Sohbet açılınca bu
    /// **değişmez**: panel pencereyi büyütmez, orta panelin içinden yer alır.
    static let minWidth: CGFloat = 900
    /// Sohbet panelinin genişliği. Sabit: `NavigationSplitView`'ın üçüncü
    /// sütunu değil, orta panelin içinde bir bölme.
    static let chatWidth: CGFloat = 320
    /// Sohbet açıkken pencerenin inebileceği en küçük genişlik. **Ölçüldü**
    /// (RESEARCH.md §26): 940 pt'nin altında kenar çubuğu yine kırpılıyor.
    /// Pencere yalnızca en dar hâldeyken 40 pt büyür; normal boyutlarda hiç
    /// değişmez.
    static let minWidthWithChat: CGFloat = 940
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        NavigationSplitView {
            MeetingSidebar(recorder: recorder)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            // Sohbet **orta panelin içinde** bir bölmedir, `.inspector` değil.
            // Neden: `.inspector` üçüncü bir sütun açıyor ve orta sütun kendi
            // alt sınırının (ölçüldü: ~655 pt) altına inmediği için SwiftUI
            // fazlalığı kenar çubuğuyla paneli pencerenin dışına iterek
            // çözüyordu — kenar çubuğu kırpılıyordu (RESEARCH.md §26).
            // Notlar uygulamasının davranışı da budur: panel açılınca pencere
            // büyümez, okuma alanı daralır.
            HStack(spacing: 0) {
                Group {
                    if recorder.isRecording {
                        RecordingView(recorder: recorder)
                    } else if recorder.showsActionBoard {
                        ActionBoardView(recorder: recorder)
                    } else {
                        MeetingDetail(recorder: recorder)
                    }
                }
                .frame(maxWidth: .infinity)

                if isChatShown {
                    Divider().overlay(Color.oraBorder)
                    ChatInspector(recorder: recorder,
                                  isDisabledDuringRecording: recorder.isRecording)
                        .frame(width: Self.chatWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .clipped()
        }
        .frame(minWidth: isChatShown ? Self.minWidthWithChat : Self.minWidth,
               minHeight: 560)
        .animation(OraStyle.transition, value: isChatShown)
        .toolbar {
            ToolbarItem(placement: .principal) {
                RecordButton(recorder: recorder)
            }
            ToolbarItem {
                Menu {
                    Button("Markdown olarak kaydet…") {
                        if let payload = recorder.exportPayload { MeetingExport.saveMarkdown(payload) }
                    }
                    .disabled(recorder.exportPayload == nil)
                    Button("PDF olarak kaydet…") {
                        if let payload = recorder.exportPayload { MeetingExport.savePDF(payload) }
                    }
                    .disabled(recorder.exportPayload == nil)
                    Button("E-posta taslağını kopyala") {
                        if let payload = recorder.exportPayload { MeetingExport.copyEmailDraft(payload) }
                    }
                    .disabled(recorder.exportPayload == nil)
                } label: {
                    Label("Dışa aktar", systemImage: "square.and.arrow.up")
                }
                .help("Dışa aktar")
            }
            ToolbarItem {
                Button {
                    withAnimation(OraStyle.transition) { isChatShown.toggle() }
                } label: {
                    Image(systemName: isChatShown
                          ? "bubble.left.and.bubble.right.fill"
                          : "bubble.left.and.bubble.right")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(isChatShown ? Color.oraCarmine : Color.oraInk)
                }
                .help(isChatShown ? "Sohbet panelini kapat" : "Sohbet panelini aç")
                .accessibilityLabel("Sohbet paneli")
                .accessibilityValue(isChatShown ? "açık" : "kapalı")
            }
        }
        // Başlıkta düz metin yok; kimlik ikon ve menü bardan geliyor.
        .navigationTitle("")
        // Araç çubuğu kendi zeminini çizmez; altındaki tuval kesintisiz devam
        // eder. Aksi hâlde beyaz araç çubuğu ile krem tuval arasında yatay bir
        // dikiş kalıyor (BRAND.md: pencere arka planı tuvalle aynı olmalı).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task {
            recorder.scanForInterruptedRecordings()
            // Sistem genelinde ⌘⇧R: kaydı başlatmak istediğiniz an başka bir
            // uygulamadasınızdır (COMPETITION.md §4.16).
            GlobalHotKey.shared.action = { Task { await recorder.toggle() } }
            GlobalHotKey.shared.register()
            await recorder.startServices()
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                // Bildirim izni verilmemiş olabilir; öneri o zaman burada görünür.
                if let signal = recorder.pendingSignal, !recorder.isRecording {
                    StartSuggestionBanner(signal: signal, recorder: recorder)
                }
                if recorder.suggestsStop {
                    StopSuggestionBanner(recorder: recorder)
                }
                // Çakışan takvim toplantısı: kayıt sürerken sorulur, cevap
                // gelene kadar katılımcı yazılmaz.
                if !recorder.eventChoices.isEmpty {
                    EventChoiceBanner(choices: recorder.eventChoices, recorder: recorder)
                }
            }
        }
        .alert(recorder.error?.turkishMessage ?? "",
               isPresented: Binding(get: { recorder.error != nil },
                                    set: { if !$0 { recorder.error = nil } })) {
            Button("Tamam", role: .cancel) { recorder.error = nil }
        } message: {
            Text(recorder.error?.turkishDetail ?? "")
        }
        .sheet(isPresented: Binding(get: { !hasCompletedOnboarding },
                                    set: { if !$0 { hasCompletedOnboarding = true } })) {
            OnboardingView(recorder: recorder) { hasCompletedOnboarding = true }
        }
        .sheet(item: Binding(get: { recorder.interrupted.first },
                             set: { _ in })) { recording in
            InterruptedRecordingSheet(recording: recording, recorder: recorder)
        }
    }
}

/// Kayıt butonu — BRAND kural #9: Active Red yalnızca burada ve menü bar noktasında.
private struct RecordButton: View {

    let recorder: RecordingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Button {
            Task { await recorder.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(Color.oraRed)
                    .opacity(recorder.isRecording && isPulsing && !reduceMotion ? 0.45 : 1)
                if recorder.isRecording {
                    Text(recorder.elapsedText)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.oraInk)
                }
            }
        }
        .help(recorder.isRecording ? "Kaydı durdur" : "Kaydı başlat")
        .accessibilityLabel(recorder.isRecording
                            ? "Kaydı durdur, \(recorder.elapsedText)" : "Kaydı başlat")
        .onChange(of: recorder.isRecording) { _, isRecording in
            guard !reduceMotion else { return }
            if isRecording {
                withAnimation(.easeOut(duration: 0.15).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            } else {
                isPulsing = false
            }
        }
    }
}

/// Kayıt sürerken orta panel — canlı mod (DESIGN.md §4).
/// Üstte durum, altta akan canlı transkript.
private struct RecordingView: View {

    let recorder: RecordingController
    /// Kayıt bildirimi hatırlatması — kayıt başına bir kez, kapatılabilir.
    @State private var announcementDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(Color.oraRed)
                    Text("Kayıt sürüyor")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.oraInk)
                    Text(recorder.elapsedText)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Color.oraInkMuted)
                        .contentTransition(.numericText())
                    Spacer()
                    Button("Durdur") { Task { await recorder.stop() } }
                        .foregroundStyle(Color.oraRed)
                }

                if OraSettings.shared.announceRecording, !announcementDismissed {
                    AnnouncementNote { announcementDismissed = true }
                }

                if let reason = recorder.micOnlyReason {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Color.oraInkMuted)
                        Text("\(reason) — kayıt yalnızca mikrofonunuzla sürüyor.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.oraInkMuted)
                        Spacer()
                    }
                    .padding(10)
                    .oraCard()
                }
            }
            .padding(20)

            Divider().overlay(Color.oraBorder)

            TranscriptView(segments: recorder.liveSegments,
                           volatileText: recorder.volatileText,
                           notice: recorder.liveNotice)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.oraPaper)
    }
}

/// Kayıt başladı — katılımcıları bilgilendirmeyi hatırlat. Yalnızca ayarla
/// açılır ve tamamen yereldir: kimseye bildirim gönderilmez, yalnızca
/// söyleyeceğiniz cümle panoya kopyalanır.
private struct AnnouncementNote: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2")
                .foregroundStyle(Color.oraInkMuted)
            Text("Katılımcılara kayıt aldığınızı söylemeyi unutmayın.")
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInk)
            Spacer()
            Button("Metni kopyala") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(OraSettings.announcement, forType: .string)
            }
            .buttonStyle(.link)
            Button("Tamam", action: dismiss)
        }
        .padding(10)
        .oraCard()
    }
}

/// Uygulama kayıt sırasında çöktüyse açılışta sorulur.
private struct InterruptedRecordingSheet: View {

    let recording: InterruptedRecording
    let recorder: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Yarım kalan bir kayıt bulundu")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.oraInk)

            Text("ora önceki oturumda beklenmedik şekilde kapanmış. "
                 + "\(durationText) uzunluğunda bir ses kaydı diskte duruyor ve sağlam.")
                .font(.system(size: 13))
                .foregroundStyle(Color.oraInkMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Sil", role: .destructive) { recorder.discard(recording) }
                    .foregroundStyle(Color.oraRed)
                Spacer()
                Button("Sakla") { recorder.keep(recording) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Color.oraPaper)
        .onExitCommand { recorder.keep(recording) }
    }

    private var durationText: String {
        let total = Int(recording.duration)
        return total >= 60 ? "\(total / 60) dk \(total % 60) sn" : "\(total) sn"
    }
}

/// Toplantı algılandı önerisi. Bildirim gönderilemiyorsa tek yüzey budur.
private struct StartSuggestionBanner: View {
    let signal: MeetingSignal
    let recorder: RecordingController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: signal.isLowConfidence ? "questionmark.circle" : "waveform.badge.mic")
                .foregroundStyle(Color.oraInkMuted)
            Text(signal.turkishTitle)
                .font(.system(size: 13))
                .foregroundStyle(Color.oraInk)
            Spacer()
            Button("Şimdi değil") { recorder.dismissSuggestion() }
            Button("Bu uygulamayı hep kaydet") { recorder.alwaysRecord(signal.bundleID) }
            Button("Kaydet") { recorder.startFromSuggestion() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.oraChrome)
        .overlay(alignment: .bottom) { Divider().overlay(Color.oraBorder) }
    }
}

/// Çakışan takvim toplantıları: hangisindeyiz? **Tahmin edilmez, sorulur** —
/// yanlış katılımcı listesi yazmak boş bırakmaktan kötüdür.
private struct EventChoiceBanner: View {
    let choices: [MeetingEvent]
    let recorder: RecordingController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.questionmark")
                .foregroundStyle(Color.oraInkMuted)
            Text("Hangi toplantı?")
                .font(.system(size: 13))
                .foregroundStyle(Color.oraInk)
            Spacer()
            ForEach(choices) { event in
                Button {
                    Task { await recorder.chooseEvent(event) }
                } label: {
                    Text("\(event.title) · \(event.timeLabel)").lineLimit(1)
                }
                .help(event.attendees.isEmpty
                      ? event.title : "\(event.title) — \(event.attendees.count) katılımcı")
            }
            Button("Hiçbiri") { Task { await recorder.chooseEvent(nil) } }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.oraChrome)
        .overlay(alignment: .bottom) { Divider().overlay(Color.oraBorder) }
    }
}

/// Toplantı uygulaması mikrofonu 30 sn'den uzun bıraktı — bitirmeyi öner.
private struct StopSuggestionBanner: View {
    let recorder: RecordingController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.slash")
                .foregroundStyle(Color.oraInkMuted)
            Text("Toplantı uygulaması mikrofonu bıraktı. Kaydı bitirmek ister misiniz?")
                .font(.system(size: 13))
                .foregroundStyle(Color.oraInk)
            Spacer()
            Button("Kaydı bitir") { Task { await recorder.stop() } }
                .foregroundStyle(Color.oraRed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.oraChrome)
        .overlay(alignment: .bottom) { Divider().overlay(Color.oraBorder) }
    }
}

#Preview {
    RootView(recorder: RecordingController())
        .frame(width: 1100, height: 700)
}
