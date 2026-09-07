import SwiftUI
import AppKit

/// İlk açılış ekranı: izinler, Apple Intelligence durumu, dil seçimi.
///
/// Tek sayfa; sihirbaz değil. Kullanıcı isterse izin vermeden de devam edebilir —
/// ora yalnız-mikrofon veya özetsiz modda çalışmaya devam eder.
/// Pencere başlığı okuma: opt-in izin satırı. Hem onboarding hem Ayarlar
/// aynı bileşeni kullanır — iki yerde iki farklı metin olmasın.
struct WindowTitleAccess: View {
    @Bindable var settings: OraSettings
    /// Erişilebilirlik izni bu oturumda değişmiş olabilir; pencere öne
    /// geldiğinde tazelenir.
    @State private var granted = WindowTitle.isAvailable

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Çakışan toplantıları pencere başlığından ayır", isOn: $settings.windowTitleEnabled)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if settings.windowTitleEnabled && !granted {
                HStack(spacing: 8) {
                    Button("Erişilebilirlik izni ver") {
                        WindowTitle.requestPermission()
                    }
                    Button("Ayarları aç") {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference"
                                      + ".security?Privacy_Accessibility")
                        if let url { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .onChange(of: settings.windowTitleEnabled) { _, enabled in
            granted = WindowTitle.isAvailable
            // Açar açmaz istem gösterilir; kullanıcı iki adım aramasın.
            if enabled && !granted { WindowTitle.requestPermission() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = WindowTitle.isAvailable
        }
    }

    private var detail: String {
        if !settings.windowTitleEnabled {
            return "Aynı saatte iki toplantınız varsa ora hangisinde olduğunuzu "
                + "bilemez ve size sorar. Açarsanız toplantı uygulamasının pencere "
                + "başlığını okuyup doğru toplantıyı kendisi seçer."
        }
        return granted
            ? "Açık. ora yalnızca toplantı uygulamalarının pencere başlığını okur; "
              + "başlık hiçbir yere yazılmaz, yalnızca takvim eşleştirmesinde kullanılır."
            : "Erişilebilirlik izni gerekiyor. Sistem Ayarları → Gizlilik ve Güvenlik → "
              + "Erişilebilirlik listesinden ora'yı işaretleyin."
    }
}

struct OnboardingView: View {

    let recorder: RecordingController
    let finish: () -> Void

    @State private var microphoneGranted = false
    @State private var isRequesting = false

    private var availability: ModelAvailability { recorder.modelAvailability }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                OraLogo(height: 36, showsWordmark: true)
                Text("Sesi bilgiye dönüştürür")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.oraInk)
                Text("Toplantılarınızı kaydeder, yazıya döker ve özetler. "
                     + "Tüm işlem bu Mac'te yapılır; hiçbir veri cihazınızdan çıkmaz.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.oraInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.oraChrome)

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

                // Çakışan takvim toplantılarını ayırmak için pencere başlığı.
                // **İsteğe bağlı** — kapalı bırakılırsa ora çakışmada sorar.
                Row(icon: "calendar.badge.questionmark",
                    title: "Çakışan toplantılar",
                    detail: "",
                    isDone: OraSettings.shared.windowTitleEnabled) {
                    EmptyView()
                }
                WindowTitleAccess(settings: OraSettings.shared)
                    .padding(.leading, 30)
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
        .tint(Color.oraCarmine)
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
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isDone ? Color.oraCarmine : Color.oraInkMuted)
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
