import SwiftUI

/// Menü bar simgesi. **Taşıyıcı yüzey budur** (DESIGN.md §2).
///
/// Boşta tek renk `.oraInk`, kayıtta `.oraRed` nokta — Active Red'in izinli
/// olduğu iki yerden biri (BRAND kural #9). İşlem sürerken ince gösterge.
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

/// Menü bar popover'ı — geçen süre, iki kanalın seviyesi, akan canlı satır,
/// Durdur ve sıradaki toplantı.
struct MenuBarContent: View {

    let recorder: RecordingController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recorder.isRecording {
                recordingSection
            } else if recorder.isTranscribing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Toplantı işleniyor…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.oraInk)
                }
            } else {
                idleSection
            }

            if let event = recorder.upcomingEvent {
                Divider().overlay(Color.oraBorder)
                HStack(spacing: 8) {
                    Text(event.timeLabel)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.oraInkMuted)
                    Text(event.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.oraInk)
                        .lineLimit(1)
                }
            }

            Divider().overlay(Color.oraBorder)
            HStack {
                Button("Pencereyi aç") { openWindow(id: "main") }
                Spacer()
                Button("Çık") { NSApplication.shared.terminate(nil) }
                    .foregroundStyle(Color.oraInkMuted)
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 280)
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle").foregroundStyle(Color.oraRed)
                Text(recorder.elapsedText)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Color.oraInk)
                Spacer()
                Button("Durdur") { Task { await recorder.stop() } }
                    .foregroundStyle(Color.oraRed)
            }

            // Kanal ayrımı görünür olsun: mikrofon ve sistem ayrı ölçülür.
            VStack(spacing: 5) {
                ForEach(Channel.allCases, id: \.rawValue) { channel in
                    LevelBar(label: channel.speaker,
                             level: recorder.channelLevels[channel.rawValue] ?? 0)
                }
            }

            if let reason = recorder.micOnlyReason {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.oraInkMuted)
            }

            if let line = recorder.lastLiveLine, !line.isEmpty {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let signal = recorder.pendingSignal {
                Text(signal.turkishTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.oraInk)
                HStack {
                    Button("Kaydet") { Task { await recorder.startFromSuggestion() } }
                    Button("Şimdi değil") { recorder.detector.dismissSuggestion() }
                }
                .font(.system(size: 12))
            } else {
                Button {
                    Task { await recorder.start() }
                } label: {
                    Label("Kaydı başlat", systemImage: "record.circle")
                        .foregroundStyle(Color.oraRed)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// İnce seviye çubuğu. Marka rengi kullanılır, kırmızı değil — kırmızı yalnızca
/// kayıt göstergesinindir.
private struct LevelBar: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.oraInkMuted)
                .frame(width: 62, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.oraGray)
                    Capsule()
                        .fill(Color.oraBlue)
                        .frame(width: geometry.size.width * CGFloat(min(1, level * 3)))
                }
            }
            .frame(height: 4)
        }
        .accessibilityHidden(true)
    }
}
