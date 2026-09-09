import SwiftUI

/// Ayarlar penceresi (⌘,). Sekmeler: Genel, Algılama, Takvim, Sözlük, Depolama.
struct SettingsView: View {

    let recorder: RecordingController
    @Bindable var settings: OraSettings

    var body: some View {
        TabView {
            GeneralSettings(recorder: recorder, settings: settings)
                .tabItem { Label("Genel", systemImage: "gearshape") }
            DetectionSettings(recorder: recorder, settings: settings)
                .tabItem { Label("Algılama", systemImage: "waveform.badge.mic") }
            CalendarSettings(recorder: recorder, settings: settings)
                .tabItem { Label("Takvim", systemImage: "calendar") }
            VocabularySettings(recorder: recorder)
                .tabItem { Label("Sözlük", systemImage: "text.book.closed") }
            StorageSettings(recorder: recorder, settings: settings)
                .tabItem { Label("Depolama", systemImage: "internaldrive") }
        }
        .frame(width: 520, height: 420)
        .background(Color.oraPaper)
    }
}

/// Genel ayarlar: transkripsiyon dili.
private struct GeneralSettings: View {
    let recorder: RecordingController
    @Bindable var settings: OraSettings

    var body: some View {
        Form {
            Section("Adınız") {
                TextField("Adınız", text: $settings.userDisplayName)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Text("Özetlemede mikrofon kanalındaki kişinin kim olduğunu söyler; "
                     + "aksiyonlar \"Ben\" yerine adınızla yazılır. Boş bırakılabilir. "
                     + "Transkriptteki konuşmacı etiketi değişmez ve bu ad "
                     + "cihazdan çıkmaz.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Başlangıç") {
                LaunchAtLoginToggle()
            }

            Section("Toplantı dili") {
                Picker("Dil", selection: Binding(get: { recorder.language },
                                                 set: { recorder.language = $0 })) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.turkishName).tag(language)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(recorder.isRecording)

                // `Text(String)` markdown ayrıştırmaz; birleştirilmiş metinde
                // vurgu için anahtar açıkça kurulur (yıldızlar ekranda görünüyordu).
                Text(LocalizedStringKey(
                    "**Otomatik**, sesin ilk 40 saniyesini kurulu dillerle ayrı ayrı "
                    + "çözer ve güven skoru yüksek olanı seçer. Apple'da konuşulan "
                    + "dili tanıyan bir API yoktur; bu ölçüme dayalı bir seçimdir."))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if recorder.isRecording {
                    Text("Kayıt sürerken dil değiştirilemez.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.oraInkMuted)
                }
            }

            Section("Kayıt bildirimi") {
                Toggle("Kaydı başlatınca beni uyar", isOn: $settings.announceRecording)
                Text("Kayıt başladığında ekranda kısa bir hatırlatma çıkar ve "
                     + "katılımcılara söyleyebileceğiniz cümleyi panoya "
                     + "kopyalayabilirsiniz. Hiçbir bildirim dışarı gönderilmez.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
                if settings.announceRecording {
                    HStack(alignment: .top, spacing: 8) {
                        Text("“\(OraSettings.announcement)”")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.oraInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Kopyala") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(OraSettings.announcement,
                                                           forType: .string)
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            Section("Apple Intelligence") {
                HStack(spacing: 8) {
                    Image(systemName: recorder.modelAvailability.isAvailable
                          ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(recorder.modelAvailability.isAvailable
                                         ? Color.oraCarmine : Color.oraInkMuted)
                    Text(recorder.modelAvailability.isAvailable
                         ? "Hazır — özet, noktalama ve sohbet çalışıyor."
                         : recorder.modelAvailability.turkishMessage)
                        .font(.system(size: 13))
                }
                if !recorder.modelAvailability.isAvailable {
                    Text(recorder.modelAvailability.turkishDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.oraInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// "Başlangıçta çalıştır". Durumun tek kaynağı sistemdir (`LoginItem`),
/// bu yüzden `OraSettings`'te bir alanı yok ve pencere her açılışta durumu
/// yeniden okur — kullanıcı kaydı Sistem Ayarları'ndan kaldırmış olabilir.
private struct LaunchAtLoginToggle: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var needsApproval = LoginItem.requiresApproval
    @State private var failure: String?

    var body: some View {
        Toggle("ora'yı girişte başlat", isOn: Binding(
            get: { enabled },
            set: { apply($0) }
        ))

        Text("Oturum açıldığında ora menü barda sessizce başlar; pencere "
             + "açılmaz ve toplantı algılama ilk dakikadan itibaren çalışır.")
            .font(.system(size: 12))
            .foregroundStyle(Color.oraInkMuted)
            .fixedSize(horizontal: false, vertical: true)

        if needsApproval {
            VStack(alignment: .leading, spacing: 4) {
                Text("macOS onayınızı bekliyor — onaylanana kadar ora girişte "
                     + "başlamaz.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Giriş öğelerini aç") { LoginItem.openSystemSettings() }
                    .buttonStyle(.link)
            }
        }

        if let failure {
            Text(failure)
                .font(.system(size: 12))
                .foregroundStyle(Color.oraRed)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func apply(_ on: Bool) {
        do {
            try LoginItem.setEnabled(on)
            failure = nil
        } catch {
            Log.error(.app, "Girişte başlatma değiştirilemedi", error)
            failure = LoginItem.turkishMessage(for: error)
        }
        // Sistemden yeniden oku: kayıt onay bekliyorsa açık sayılmaz.
        enabled = LoginItem.isEnabled || LoginItem.requiresApproval
        needsApproval = LoginItem.requiresApproval
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

                // Bildirim izni yoksa öneri **gelmeye devam eder**, yalnızca
                // yüzeyi değişir. Sessizce yutulursa kullanıcı algılamanın
                // bozuk olduğunu sanıyor.
                if let problem = recorder.notificationProblem {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "bell.slash")
                            .foregroundStyle(Color.oraInkMuted)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(problem)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.oraInkMuted)
                            Button("Bildirim ayarlarını aç") {
                                if let url = URL(string:
                                    "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
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
            recorder.setDetectionEnabled(enabled)
        }
        .task { await recorder.refreshNotificationPermission() }
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
                // Çakışan toplantı ayrımı takvim özelliğinin bir parçası;
                // takvim kapalıyken anlamı yok, o yüzden burada duruyor.
                Section("Çakışan toplantılar") {
                    WindowTitleAccess(settings: settings)
                }

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
/// Depolama. Ses saklamak bir maliyettir ve bugüne kadar yönetilmiyordu:
/// 16 kHz stereo WAV saatte ~230 MB (COMPETITION.md §4.5).
private struct StorageSettings: View {
    let recorder: RecordingController
    @Bindable var settings: OraSettings

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Ses kayıtları")
                    Spacer()
                    Text(AudioArchive.sizeLabel(recorder.audioBytes))
                        .foregroundStyle(Color.oraInkMuted)
                        .monospacedDigit()
                }
                Text("Bir saatlik kayıt sıkıştırılmamış hâlde yaklaşık 230 MB yer kaplar. "
                     + "Transkript, özet ve aksiyonlar sesten bağımsızdır; ses silinse de kalır.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
            }

            Section("Sıkıştırma") {
                Toggle("İşlem bittikten sonra sesi sıkıştır", isOn: $settings.compressAudio)
                Text("Transkripsiyon ve özet tamamlandıktan sonra kayıt AAC'ye çevrilir "
                     + "ve yaklaşık 11 kat küçülür. Kayıp veren bir sıkıştırmadır; "
                     + "kaydı ham hâliyle saklamak isterseniz kapalı bırakın.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
            }

            Section("Saklama süresi") {
                Picker("Ses dosyalarını sakla", selection: $settings.audioRetentionDays) {
                    ForEach(OraSettings.retentionOptions, id: \.self) { days in
                        Text(Self.label(days)).tag(days)
                    }
                }
                // Birleştirilmiş metinde markdown çalışmaz; vurgu kelimeyle kurulur.
                Text("Süresi dolduğunda silinen yalnızca sestir. Sesi silinen bir "
                     + "toplantı artık yeniden işlenemez ve çalınamaz; notu yerinde kalır.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
            }
        }
        .formStyle(.grouped)
        .task { recorder.refreshStorage() }
        .onChange(of: settings.audioRetentionDays) { _, _ in
            Task { await recorder.purgeExpiredAudio() }
        }
    }

    private static func label(_ days: Int) -> String {
        switch days {
        case 0:   "Süresiz"
        case 365: "1 yıl"
        default:  "\(days) gün"
        }
    }
}

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
                                .foregroundStyle(Color.oraInkMuted)
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
