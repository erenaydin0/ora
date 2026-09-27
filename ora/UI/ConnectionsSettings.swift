import SwiftUI

/// Ayarlar → Bağlantılar (Faz 11, Bağlantı Kuralları).
///
/// Her bağlantı **varsayılan kapalıdır** ve kurulmadıkça hiçbir istek
/// gitmez. Metnin buluta gitmeye başladığı an, ne gideceğinin açıkça yazıldığı
/// bir onay ekranından geçer; giden her isteğin künyesi en altta listelenir.
struct ConnectionsSettings: View {

    let connections: ConnectionCenter
    @Bindable var settings: OraSettings
    @State private var consentFor: ConnectionKind?

    private var provider: ConnectionKind { settings.cloudProvider }

    var body: some View {
        Form {
            Section("Özetleme ve sohbet") {
                Picker("Sağlayıcı", selection: $settings.cloudProvider) {
                    ForEach(ConnectionKind.aiProviders) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                ConnectionFields(kind: provider, connections: connections, settings: settings)
                    .id(provider)
                Toggle("Özetleme ve sohbette bu sağlayıcıyı kullan", isOn: Binding(
                    get: { settings.summaryEngine == .cloud },
                    set: { on in
                        if !on { settings.summaryEngine = .apple }
                        else if connections.isConsented(provider) { settings.summaryEngine = .cloud }
                        else { consentFor = provider }
                    }))
                    .disabled(!connections.isConfigured(provider))
                note("Açıkken toplantının transkript metni özet için bu sağlayıcıya "
                     + "gönderilir. Ses, ses izleri ve takvim ayrıntıları gönderilmez; "
                     + "noktalama ve başlık cihazda kalır. Sağlayıcıya ulaşılamazsa özet "
                     + "cihazda üretilir. Anahtar yalnızca Keychain'de durur.")
            }

            Section("Slack") {
                ConnectionFields(kind: .slack, connections: connections, settings: settings)
                autoShareToggle(.slack)
            }

            Section("Notion") {
                ConnectionFields(kind: .notion, connections: connections, settings: settings)
                autoShareToggle(.notion)
            }

            Section("Giden istekler") {
                if connections.recent.isEmpty {
                    note("Henüz hiçbir istek gitmedi.")
                } else {
                    ForEach(connections.recent.prefix(20)) { record in
                        OutboundRow(record: record)
                    }
                }
                note("Yalnızca künye tutulur: hizmet, amaç, toplantı ve karakter sayısı. "
                     + "Gönderilen metnin kendisi kaydedilmez.")
            }
        }
        .formStyle(.grouped)
        .task {
            connections.refresh()
            // Girişli ChatGPT hesabının model kataloğu — tek sefer.
            if connections.storedSecrets.contains(.chatGPT), connections.chatGPTModels.isEmpty {
                await connections.refreshChatGPTModels()
            }
        }
        .sheet(item: $consentFor) { kind in
            ConsentSheet(kind: kind, localServerURL: settings.localServerURL) {
                connections.grantConsent(kind)
                settings.summaryEngine = .cloud
                consentFor = nil
            } cancel: {
                consentFor = nil
            }
        }
    }

    /// Otomatik paylaşım ancak bir kez elle gönderilip onaylandıktan sonra
    /// açılabilir — ön izlemesi görülmemiş bir hedefe kendiliğinden bir şey
    /// gitmez.
    @ViewBuilder
    private func autoShareToggle(_ kind: ConnectionKind) -> some View {
        Toggle("Özet hazır olunca kendiliğinden gönder", isOn: Binding(
            get: { settings.autoShareConnections.contains(kind.rawValue) },
            set: { on in
                if on { settings.autoShareConnections.insert(kind.rawValue) }
                else { settings.autoShareConnections.remove(kind.rawValue) }
            }))
            .disabled(!connections.isConfigured(kind) || !connections.isConsented(kind))
        note(connections.isConsented(kind)
             ? "Yalnızca not ve aksiyonlar gider, transkript gitmez. “Cihazdan çıkmasın” "
               + "işaretli toplantılar gönderilmez."
             : "İlk gönderimi bir toplantının Dışa aktar menüsünden, gidecek metni görerek "
               + "onaylayın; otomatik gönderim ondan sonra açılır.")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Color.oraInkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Bir bağlantının alanları: anahtar (Keychain), model/adres/sayfa, deneme.
private struct ConnectionFields: View {
    let kind: ConnectionKind
    let connections: ConnectionCenter
    @Bindable var settings: OraSettings
    @State private var draft = ""
    @State private var result: String?
    @State private var testing = false

    private var hasSecret: Bool { connections.storedSecrets.contains(kind) }

    var body: some View {
        if kind == .chatGPT {
            ChatGPTFields(connections: connections, settings: settings)
        }
        if kind.needsSecret {
            HStack {
                SecureField(kind.secretLabel, text: $draft,
                            prompt: Text(hasSecret ? "Kayıtlı — değiştirmek için yazın"
                                                   : kind.secretLabel))
                Button("Kaydet") {
                    connections.saveSecret(draft, for: kind)
                    draft = ""
                    result = nil
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        if kind == .localServer {
            TextField("Adres", text: $settings.localServerURL)
        }
        if kind.isAIProvider, kind != .chatGPT {
            TextField("Model", text: Binding(
                get: { settings.providerModels[kind.rawValue] ?? "" },
                set: { settings.providerModels[kind.rawValue] = $0 }),
                prompt: Text(kind.defaultModel.isEmpty ? "Sağlayıcı panelindeki model adı"
                                                       : kind.defaultModel))
        }
        if kind == .notion {
            TextField("Notların yazılacağı sayfa", text: $settings.notionPageID,
                      prompt: Text("Sayfa adresi — entegrasyonla paylaşılmış olmalı"))
        }
        HStack(spacing: 8) {
            Label(connections.isConfigured(kind) ? "Kurulu" : "Kurulmadı",
                  systemImage: connections.isConfigured(kind) ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(connections.isConfigured(kind) ? Color.oraCarmine
                                                                : Color.oraInkMuted)
                .font(.system(size: 12))
            Spacer()
            Button(testing ? "Deneniyor…" : "Bağlantıyı dene") {
                testing = true
                Task {
                    result = await connections.test(kind) ?? "Çalışıyor."
                    testing = false
                }
            }
            .disabled(!connections.isConfigured(kind) || testing)
            if hasSecret || kind == .localServer && connections.isConfigured(kind) {
                Button(kind == .chatGPT ? "Çıkış yap" : "Kaldır", role: .destructive) {
                    connections.remove(kind)
                    result = nil
                }
            }
        }
        if let result {
            Text(result)
                .font(.system(size: 12))
                .foregroundStyle(result == "Çalışıyor." ? Color.oraInk : Color.oraRed)
                .fixedSize(horizontal: false, vertical: true)
        }
        if kind == .slack {
            Text("Deneme, kanala görünür kısa bir ileti gönderir.")
                .font(.system(size: 11))
                .foregroundStyle(Color.oraInkMuted)
        }
    }
}

/// ChatGPT aboneliğiyle giriş: anahtar yerine tarayıcıda oturum açılır.
/// Dönüş bu Mac'te yakalanır; yakalanamazsa adres yapıştırılarak tamamlanır.
private struct ChatGPTFields: View {
    let connections: ConnectionCenter
    @Bindable var settings: OraSettings
    @State private var pasted = ""
    @State private var message: String?
    @State private var working = false

    private var signedIn: Bool { connections.storedSecrets.contains(.chatGPT) }
    private var modelKey: String { ConnectionKind.chatGPT.rawValue }

    var body: some View {
        if signedIn {
            let current = settings.providerModels[modelKey] ?? ""
            let models = connections.chatGPTModels
            if models.isEmpty {
                HStack {
                    TextField("Model", text: Binding(
                        get: { current },
                        set: { settings.providerModels[modelKey] = $0 }),
                        prompt: Text("Model adı"))
                    Button("Modelleri getir") { Task { await connections.refreshChatGPTModels() } }
                }
            } else {
                Picker("Model", selection: Binding(
                    get: { current },
                    set: { settings.providerModels[modelKey] = $0 })) {
                    ForEach(models.contains(current) || current.isEmpty
                            ? models : [current] + models, id: \.self) { Text($0).tag($0) }
                }
            }
        } else if connections.chatGPTSignIn == nil {
            HStack {
                Button(working ? "Tarayıcı açılıyor…" : "ChatGPT ile giriş yap") {
                    working = true
                    message = nil
                    Task {
                        message = await connections.beginChatGPTSignIn()
                        working = false
                    }
                }
                .disabled(working)
                Spacer()
            }
            Text("Tarayıcıda ChatGPT hesabınızla giriş yaparsınız; aboneliğinizin kullanım "
                 + "hakkı kullanılır, API anahtarı gerekmez. Parolanız ora'ya gelmez.")
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInkMuted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Tarayıcıda giriş yapın…")
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInk)
            HStack {
                TextField("Dönüş adresi", text: $pasted,
                          prompt: Text("Tarayıcı dönmezse adres çubuğundaki adresi yapıştırın"))
                Button("Tamamla") {
                    Task {
                        message = await connections.completeChatGPTSignIn(pasted)
                        if message == nil { pasted = "" }
                    }
                }
                .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Vazgeç") {
                    connections.cancelChatGPTSignIn()
                    working = false
                }
            }
        }
        if let message {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.oraRed)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Metnin buluta gitmeye başladığı an (kural 5): ne gidip ne gitmediği
/// açıkça yazılır, onaysız hiçbir şey gitmez. Escape vazgeçer.
private struct ConsentSheet: View {
    let kind: ConnectionKind
    let localServerURL: String
    let approve: () -> Void
    let cancel: () -> Void

    private var staysOnDevice: Bool {
        guard kind == .localServer, let host = URL(string: localServerURL)?.host else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transkript metni \(kind.displayName) hizmetine gidecek")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.oraInk)
            VStack(alignment: .leading, spacing: 6) {
                bullet("Gidecek olan: her toplantının transkript metni (konuşmacı "
                       + "etiketleriyle) ve sohbette sorduğunuz sorular.")
                bullet("Gitmeyecek olan: ses kaydı, ses izleri, takvim ayrıntıları. "
                       + "Noktalama ve başlık cihazda üretilir.")
                bullet("“Cihazdan çıkmasın” işaretli toplantılar hiç gönderilmez.")
                bullet("Her isteğin künyesi Ayarlar → Bağlantılar'da listelenir. "
                       + "Anahtarı kaldırınca cihazdaki modele dönülür.")
                if staysOnDevice {
                    bullet("Adres bu Mac olduğu için metin cihazdan çıkmaz.")
                }
            }
            HStack {
                Spacer()
                Button("Vazgeç", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Onaylıyorum", action: approve)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Color.oraPaper)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(Color.oraInkMuted)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OutboundRow: View {
    let record: OutboundRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: record.succeeded ? "arrow.up.circle" : "exclamationmark.circle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(record.succeeded ? Color.oraInkMuted : Color.oraRed)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(record.connection.displayName) · \(record.purpose.rawValue)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInk)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.oraInkMuted)
            }
        }
    }

    private var detail: String {
        var parts = [record.date.formatted(date: .abbreviated, time: .shortened)]
        if let id = record.meetingID { parts.append("toplantı \(id)") }
        if record.characters > 0 { parts.append("\(record.characters) karakter") }
        parts.append(record.status.map { "HTTP \($0)" } ?? "gönderilemedi")
        return parts.joined(separator: " · ")
    }
}
