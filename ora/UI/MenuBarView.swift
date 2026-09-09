import SwiftUI

/// Menü bar simgesi. **Taşıyıcı yüzey budur** (DESIGN.md §2).
///
/// Boşta tek renk, kayıtta `.oraRed` nokta — Active Red'in izinli olduğu iki
/// yerden biri (BRAND kural #9). İşlem sürerken ince gösterge.
struct MenuBarLabel: View {

    let recorder: RecordingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Group {
            if recorder.isRecording {
                Image(systemName: "circle.fill")
                    .foregroundStyle(Color.oraRed)
                    .opacity(isPulsing && !reduceMotion ? 0.45 : 1)
            } else if recorder.isTranscribing {
                Image(systemName: "circle.dotted")
            } else {
                Image(systemName: "waveform")
            }
        }
        .onChange(of: recorder.isRecording) { _, recording in
            guard !reduceMotion else { return }
            if recording {
                withAnimation(.easeOut(duration: 0.15).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            } else {
                isPulsing = false
            }
        }
        .accessibilityLabel(recorder.isRecording ? "ora kaydediyor" : "ora")
    }
}

/// Menü bar menüsü — **native `NSMenu`**, seçenekler alt alta.
///
/// Özel çizilmiş bir popover yerine sistemin kendi menüsü kullanılır:
/// klavye gezinme, vurgulama ve kapanma davranışı bedava gelir ve menü
/// çubuğundaki diğer uygulamalarla aynı hisseder.
struct MenuBarContent: View {

    let recorder: RecordingController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Durum satırı — tıklanamaz bilgi
        Text(statusLine)

        Divider()

        if recorder.isRecording {
            Button("Kaydı durdur") { Task { await recorder.stop() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            if let line = recorder.lastLiveLine, !line.isEmpty {
                Text(line.count > 60 ? String(line.prefix(60)) + "…" : line)
            }
        } else if let signal = recorder.pendingSignal {
            Button("\(signal.displayName) toplantısını kaydet") {
                recorder.startFromSuggestion()
            }
            Button("Şimdi değil") { recorder.dismissSuggestion() }
        } else {
            Button("Kaydı başlat") { Task { await recorder.start() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        if let event = recorder.upcomingEvent {
            Divider()
            Text("Sıradaki: \(event.timeLabel)  \(event.title)")
        }

        Divider()

        Button("Pencereyi aç") { openWindow(id: "main") }
        SettingsLink { Text("Ayarlar…") }
            .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("ora'dan çık") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private var statusLine: String {
        if recorder.isRecording {
            var line = "Kaydediliyor · \(recorder.elapsedText)"
            if recorder.micOnlyReason != nil { line += " · yalnızca mikrofon" }
            return line
        }
        if recorder.isTranscribing { return "Toplantı işleniyor…" }
        return "ora hazır"
    }
}
