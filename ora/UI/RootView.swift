import SwiftUI

/// Ana pencere: `NavigationSplitView` (kenar çubuğu + içerik) + katlanabilir `.inspector`.
struct RootView: View {

    @State private var recorder = RecordingController()
    @State private var selection: Meeting.ID?
    @State private var searchText = ""
    @State private var isChatShown = false

    var body: some View {
        NavigationSplitView {
            MeetingSidebar(selection: $selection, searchText: $searchText)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
        } detail: {
            if recorder.isRecording {
                RecordingView(recorder: recorder)
            } else {
                MeetingDetail(meetingID: selection)
            }
        }
        .inspector(isPresented: $isChatShown) {
            ChatInspector(isDisabledDuringRecording: recorder.isRecording)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                RecordButton(recorder: recorder)
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
        .task { recorder.scanForInterruptedRecordings() }
        .alert(recorder.error?.turkishMessage ?? "",
               isPresented: Binding(get: { recorder.error != nil },
                                    set: { if !$0 { recorder.error = nil } })) {
            Button("Tamam", role: .cancel) { recorder.error = nil }
        } message: {
            Text(recorder.error?.turkishDetail ?? "")
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

/// Kayıt sürerken orta panel (DESIGN.md §4 "Canlı mod").
/// Canlı transkript akışı Faz 3'te bu ekrana bağlanır.
private struct RecordingView: View {

    let recorder: RecordingController

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.oraRed)

            Text("Kayıt sürüyor")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.oraInk)

            Text(recorder.elapsedText)
                .font(.system(size: 32, weight: .light, design: .monospaced))
                .foregroundStyle(Color.oraInk)
                .contentTransition(.numericText())

            if let reason = recorder.micOnlyReason {
                VStack(spacing: 4) {
                    Text(reason)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.oraInk)
                    Text("Kayıt yalnızca mikrofonunuzla sürüyor. Karşı tarafın sesi kaydedilmiyor.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.oraInkMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(12)
                .oraCard()
                .frame(maxWidth: 380)
            }

            Button("Kaydı durdur") {
                Task { await recorder.stop() }
            }
            .foregroundStyle(Color.oraRed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.oraPaper)
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

#Preview {
    RootView()
        .frame(width: 1100, height: 700)
}
