import SwiftUI
import AppKit

/// İlk açılış ekranı: izinler, Apple Intelligence durumu, dil seçimi.
///
/// Tek sayfa; sihirbaz değil. Kullanıcı isterse izin vermeden de devam edebilir —
/// ora yalnız-mikrofon veya özetsiz modda çalışmaya devam eder.
struct OnboardingView: View {

    let recorder: RecordingController
    let finish: () -> Void

    @State private var microphoneGranted = false
    @State private var isRequesting = false

    private var availability: ModelAvailability { recorder.modelAvailability }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                OraLogo(height: 28, showsWordmark: true)
                Text("Toplantılarınızı kaydeder, yazıya döker ve özetler. "
                     + "Tüm işlem bu Mac'te yapılır; hiçbir veri cihazınızdan çıkmaz.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.oraInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)

            Divider().overlay(Color.oraBorder)

            VStack(alignment: .leading, spacing: 14) {
                Row(icon: "mic",
                    title: "Mikrofon",
                    detail: microphoneGranted
                        ? "İzin verildi."
                        : "Kendi sesinizi kaydedebilmek için gerekli. Olmadan kayıt başlamaz.",
                    isDone: microphoneGranted) {
                    if !microphoneGranted {
                        Button(isRequesting ? "İsteniyor…" : "İzin ver") {
                            Task {
                                isRequesting = true
                                microphoneGranted = await MicrophoneCapture.requestAccess()
                                isRequesting = false
                            }
                        }
                        .disabled(isRequesting)
                    }
                }

                Row(icon: "speaker.wave.2",
                    title: "Sistem sesi",
                    detail: "Karşı tarafın sesi için ek izin gerekmez. Ekranınız kaydedilmez.",
                    isDone: true) { EmptyView() }

                Row(icon: "sparkles",
                    title: "Apple Intelligence",
                    detail: availability.isAvailable
                        ? "Hazır. Özet, noktalama ve sohbet çalışacak."
                        : availability.turkishMessage + ". " + availability.turkishDetail,
                    isDone: availability.isAvailable) {
                    if !availability.isAvailable {
                        Button("Ayarları aç") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }

                Row(icon: "textformat",
                    title: "Toplantı dili",
                    detail: "Sonradan araç çubuğundan değiştirebilirsiniz.",
                    isDone: true) {
                    Picker("", selection: Binding(get: { recorder.language },
                                                  set: { recorder.language = $0 })) {
                        ForEach(TranscriptionLanguage.allCases) { language in
                            Text(language.turkishName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
            .padding(24)

            Divider().overlay(Color.oraBorder)

            HStack {
                Spacer()
                Button("Başla", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520)
        .background(Color.oraPaper)
        .task { microphoneGranted = await MicrophoneCapture.isAuthorized() }
        .onExitCommand(perform: finish)
    }
}

private struct Row<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String
    let isDone: Bool
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : icon)
                .font(.system(size: 15))
                .foregroundStyle(isDone ? Color.oraBlue : Color.oraInkMuted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.oraInk)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}
