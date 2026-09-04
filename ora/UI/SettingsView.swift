import SwiftUI

/// Ayarlar penceresi (⌘,). Üç sekme: Algılama, Takvim, Sözlük.
struct SettingsView: View {

    let recorder: RecordingController
    @Bindable var settings: OraSettings

    var body: some View {
        TabView {
            DetectionSettings(recorder: recorder, settings: settings)
                .tabItem { Label("Algılama", systemImage: "waveform.badge.mic") }
            CalendarSettings(recorder: recorder, settings: settings)
                .tabItem { Label("Takvim", systemImage: "calendar") }
            VocabularySettings(recorder: recorder)
                .tabItem { Label("Sözlük", systemImage: "text.book.closed") }
        }
        .frame(width: 520, height: 420)
        .background(Color.oraPaper)
    }
}

private struct DetectionSettings: View {
    let recorder: RecordingController
    @Bindable var settings: OraSettings

    var body: some View {
        Form {
            Section {
                Toggle("Toplantıları algıla", isOn: $settings.detectionEnabled)
                Text("ora, bilinen bir toplantı uygulaması mikrofonu kullanmaya "
                     + "başladığında kayıt önerir. Uygulamanın açık olması yetmez. "
                     + "Bu izlemenin izin gereksinimi yoktur ve ekranınız okunmaz.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
            }

            Section("Her zaman kaydedilen uygulamalar") {
                if settings.alwaysRecordBundleIDs.isEmpty {
                    Text("Yok. Bir öneri bildiriminde “Bu uygulamayı hep kaydet” "
                         + "derseniz buraya eklenir.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.oraInkMuted)
                } else {
                    ForEach(Array(settings.alwaysRecordBundleIDs).sorted(), id: \.self) { bundleID in
                        HStack {
                            Text(MeetingApps.displayName(bundleID))
                            Spacer()
                            Button("Kaldır") { settings.alwaysRecordBundleIDs.remove(bundleID) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }

            Section("Yok sayılan süreçler") {
                Text("Bunlar mikrofonu açık gösterse de toplantı sayılmaz.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
                ForEach(Array(settings.excludedBundleIDs).sorted(), id: \.self) { bundleID in
                    HStack {
                        Text(bundleID).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button("Kaldır") { settings.excludedBundleIDs.remove(bundleID) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.detectionEnabled) { _, enabled in
            enabled ? recorder.detector.start() : recorder.detector.stop()
        }
    }
}

private struct CalendarSettings: View {
    let recorder: RecordingController
    @Bindable var settings: OraSettings
    @State private var calendars: [(id: String, title: String, source: String)] = []
    @State private var permissionError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Takvimi kullan", isOn: $settings.calendarEnabled)
                Text("ora toplantı adını ve katılımcıları okumak için takviminize "
                     + "erişir. Takviminize hiçbir şey yazmaz ve hiçbir veri "
                     + "cihazınızdan çıkmaz. Kapalıyken takvime hiç dokunulmaz.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
                if let permissionError {
                    Text(permissionError)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.oraRed)
                }
            }

            if settings.calendarEnabled {
                Section("Hangi takvimler") {
                    if calendars.isEmpty {
                        Text("Takvim listesi için erişim izni gerekiyor.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.oraInkMuted)
                    }
                    ForEach(calendars, id: \.id) { calendar in
                        Toggle(isOn: Binding(
                            get: { settings.selectedCalendarIDs.contains(calendar.id) },
                            set: { on in
                                if on { settings.selectedCalendarIDs.insert(calendar.id) }
                                else { settings.selectedCalendarIDs.remove(calendar.id) }
                                Task { await recorder.refreshUpcoming() }
                            })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(calendar.title)
                                Text(calendar.source)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.oraInkMuted)
                            }
                        }
                    }
                    Text("Varsayılan olarak hiçbiri seçili değildir; iş takviminizi "
                         + "seçmeniz yeterli.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.oraInkMuted)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.calendarEnabled) { _, enabled in
            guard enabled else { calendars = []; return }
            Task { await authorize() }
        }
        .task { if settings.calendarEnabled { await authorize() } }
    }

    private func authorize() async {
        do {
            let granted = try await recorder.calendar.authorize()
            guard granted else {
                permissionError = "Takvim erişimi verilmedi. Sistem Ayarları → "
                    + "Gizlilik ve Güvenlik → Takvimler bölümünden izin verebilirsiniz."
                return
            }
            permissionError = nil
            calendars = recorder.calendar.availableCalendars()
            await recorder.refreshUpcoming()
        } catch {
            permissionError = "Takvim erişimi alınamadı."
        }
    }
}

/// Özel sözlük — `ContentHint.customizedLanguage`'in beslendiği yer.
private struct VocabularySettings: View {
    let recorder: RecordingController
    @State private var newWord = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Özel isimler ve ürün adları tanımanın en zayıf noktasıdır. "
                 + "Buradaki kelimeler transkripsiyona ipucu olarak verilir.")
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInkMuted)
                .padding(16)

            List {
                ForEach(recorder.vocabulary) { word in
                    HStack(spacing: 8) {
                        Text(word.word).font(.system(size: 13))
                        if word.isPending {
                            Text("onay bekliyor")
                                .font(.system(size: 11))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.oraBlueSoft)
                                .foregroundStyle(Color.oraBlue)
                                .clipShape(Capsule())
                        }
                        Text(word.sourceLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.oraInkMuted)
                        Spacer()
                        if word.isPending {
                            Button("Ekle") { Task { await recorder.approveWord(word.id) } }
                                .buttonStyle(.link)
                            Button("Yok say") { Task { await recorder.rejectWord(word.id) } }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
            .listStyle(.inset)

            HStack(spacing: 8) {
                TextField("Kelime ekle", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Ekle", action: add).disabled(newWord.isEmpty)
            }
            .padding(16)
        }
        .task { await recorder.refreshVocabulary() }
    }

    private func add() {
        let word = newWord
        newWord = ""
        Task { await recorder.addWord(word) }
    }
}
