import Foundation
import Observation

/// Bağlantıların sahibi: hangisi kurulu, hangisine onay verildi, hangi
/// toplantı kilitli. `Outbound`'un izin politikası buradan gelir — kapı tek
/// yerde (Bağlantı Kuralları §6), arayüz ve hat onu yalnızca kullanır.
@Observable
final class ConnectionCenter {

    let settings: OraSettings
    private let store: MeetingStore
    private let secrets: any SecretStoring
    private let transport: any HTTPTransport
    private let log: OutboundLog
    /// Bulut motorunun cihazda bıraktığı işler (noktalama, başlık) ve
    /// bağlantı çalışmadığında düşülen motor.
    private let onDevice: any Intelligent

    /// Anahtarı Keychain'de duran bağlantılar. Keychain her çizimde okunmasın
    /// diye önbellek; anahtarın kendisi burada tutulmaz.
    private(set) var storedSecrets: Set<ConnectionKind> = []
    /// Son giden istekler (Ayarlar → Bağlantılar).
    private(set) var recent: [OutboundRecord] = []
    /// Otomatik paylaşım gibi kullanıcının beklemediği bir işte çıkan hata.
    var onError: ((OraError) -> Void)?

    init(settings: OraSettings, store: MeetingStore, onDevice: any Intelligent,
         secrets: any SecretStoring = KeychainSecrets(),
         transport: any HTTPTransport = URLSessionTransport(),
         log: OutboundLog = .standard) {
        self.settings = settings
        self.store = store
        self.onDevice = onDevice
        self.secrets = secrets
        self.transport = transport
        self.log = log
        refresh()
    }

    func refresh() {
        storedSecrets = Set(ConnectionKind.allCases.filter { secrets.secret(for: $0) != nil })
        recent = log.recent(limit: 30)
    }

    // MARK: - Kapı

    /// Ağa çıkan tek kapı; politikası bu nesne.
    var outbound: Outbound {
        Outbound(transport: transport, log: log) { [weak self] kind, purpose, meetingID in
            guard let self else { return "ora kapanıyor." }
            return await self.denial(kind, purpose: purpose, meetingID: meetingID)
        }
    }

    /// nil: izin var. Sıra önemli — önce kurulum, sonra onay, sonra kilit.
    func denial(_ kind: ConnectionKind, purpose: OutboundPurpose,
                meetingID: Int64?) async -> String? {
        guard isConfigured(kind) else {
            return "\(kind.displayName) bağlı değil. Ayarlar → Bağlantılar'dan bağlayın."
        }
        // Deneme isteği toplantı verisi taşımaz, onay istemez.
        guard purpose != .test else { return nil }
        guard isConsented(kind) else {
            return "\(kind.displayName) için gönderim onayı verilmedi."
        }
        if let meetingID, (try? await store.isLocalOnly(meetingID)) == true {
            return "Bu toplantı “cihazdan çıkmasın” olarak işaretli; "
                + "\(kind.displayName) hizmetine gönderilmedi."
        }
        return nil
    }

    // MARK: - Durum

    func isConfigured(_ kind: ConnectionKind) -> Bool {
        switch kind {
        case .localServer:
            return URL(string: settings.localServerURL)?.scheme?.hasPrefix("http") == true
                && !settings.model(for: kind).isEmpty
        case .notion:
            return storedSecrets.contains(kind)
                && ShareTargets.notionPageID(settings.notionPageID) != nil
        case .anthropic, .openAI, .openRouter:
            return storedSecrets.contains(kind) && !settings.model(for: kind).isEmpty
        case .slack:
            return storedSecrets.contains(kind)
        }
    }

    func isConsented(_ kind: ConnectionKind) -> Bool {
        settings.consentedConnections.contains(kind.rawValue)
    }

    /// "Bağlı sağlayıcı" motoru kullanılabilir mi?
    var isCloudReady: Bool {
        isConfigured(settings.cloudProvider) && isConsented(settings.cloudProvider)
    }

    // MARK: - Kurulum

    func saveSecret(_ value: String, for kind: ConnectionKind) {
        do {
            try secrets.setSecret(value, for: kind)
        } catch let error as OraError {
            onError?(error)
        } catch {
            onError?(.connectionFailed(reason: error.localizedDescription))
        }
        refresh()
    }

    /// Onay, ilk gönderimden önce ne gideceği gösterildikten sonra verilir.
    func grantConsent(_ kind: ConnectionKind) {
        settings.consentedConnections.insert(kind.rawValue)
        Log.info(.net, "\(kind.displayName) için gönderim onayı verildi")
    }

    /// Bağlantıyı kaldırır: anahtar, onay ve otomatik paylaşım gider. Bu
    /// sağlayıcı özet motoruysa Apple modeline dönülür — yerel yol hiç
    /// kaybolmaz (kural 1).
    func remove(_ kind: ConnectionKind) {
        try? secrets.setSecret(nil, for: kind)
        settings.consentedConnections.remove(kind.rawValue)
        settings.autoShareConnections.remove(kind.rawValue)
        if kind == settings.cloudProvider, settings.summaryEngine == .cloud {
            settings.summaryEngine = .apple
        }
        Log.info(.net, "\(kind.displayName) bağlantısı kaldırıldı")
        refresh()
    }

    // MARK: - AI sağlayıcısı

    func client(_ kind: ConnectionKind) -> ProviderClient? {
        guard kind.isAIProvider, isConfigured(kind) else { return nil }
        let base: URL? = kind == .localServer
            ? URL(string: settings.localServerURL)
            : kind.defaultBaseURL.flatMap(URL.init(string:))
        return ProviderClient(kind: kind, model: settings.model(for: kind), baseURL: base,
                              secret: secrets.secret(for: kind), outbound: outbound)
    }

    /// Bu toplantı için bulut motoru; seçili değilse, hazır değilse ya da
    /// toplantı kilitliyse nil — hat o zaman cihazdaki motoru kullanır.
    func cloudEngine(meetingID: Int64) async -> (any Intelligent)? {
        guard settings.summaryEngine == .cloud, isCloudReady,
              let client = client(settings.cloudProvider),
              (try? await store.isLocalOnly(meetingID)) != true else { return nil }
        return CloudIntelligence(client: client, meetingID: meetingID, fallback: onDevice)
    }

    // MARK: - Deneme

    /// "Bağlantıyı dene". nil: çalışıyor; değilse Türkçe neden. Slack'te
    /// kanala görünür bir deneme iletisi düşer; Notion'da sayfa yalnızca okunur.
    func test(_ kind: ConnectionKind) async -> String? {
        defer { refresh() }
        do {
            switch kind {
            case .anthropic, .openAI, .openRouter, .localServer:
                guard let client = client(kind) else {
                    return await denial(kind, purpose: .test, meetingID: nil)
                }
                _ = try await client.complete(system: "Kısa yanıt ver.",
                                              prompt: "Yalnızca 'tamam' yaz.",
                                              purpose: .test, meetingID: nil)
            case .slack:
                let request = try ShareTargets.slackRequest(
                    webhook: secrets.secret(for: .slack) ?? "",
                    markdown: "ora bağlantı denemesi — bu kanal toplantı notları için bağlandı.")
                _ = try await outbound.send(request, connection: .slack, purpose: .test,
                                            meetingID: nil, characters: 0)
            case .notion:
                guard let page = ShareTargets.notionPageID(settings.notionPageID) else {
                    return "Notion sayfa adresi geçersiz."
                }
                let request = try ShareTargets.notionRequest(
                    token: secrets.secret(for: .notion) ?? "", path: "pages/\(page)",
                    method: "GET", body: nil)
                _ = try await outbound.send(request, connection: .notion, purpose: .test,
                                            meetingID: nil, characters: 0)
            }
            return nil
        } catch let error as OraError {
            return error.turkishDetail
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Paylaşım

    /// Gönderilecek metnin **tamamı** — ön izleme bunu gösterir (kural 5).
    /// Transkript yoktur (kural 4).
    static func shareText(_ payload: MeetingExport.Payload) -> String {
        MeetingExport.markdown(payload, includeTranscript: false)
    }

    func share(_ kind: ConnectionKind, meetingID: Int64,
               payload: MeetingExport.Payload) async throws {
        defer { refresh() }
        let text = Self.shareText(payload)
        switch kind {
        case .slack:
            let request = try ShareTargets.slackRequest(
                webhook: secrets.secret(for: .slack) ?? "", markdown: text)
            _ = try await outbound.send(request, connection: .slack, purpose: .share,
                                        meetingID: meetingID, characters: text.count)
        case .notion:
            try await shareToNotion(title: payload.title, text: text, meetingID: meetingID)
        default:
            throw OraError.connectionFailed(reason: "\(kind.displayName) bir paylaşım hedefi değil.")
        }
        Log.info(.net, "Toplantı \(meetingID) \(kind.displayName) hedefine gönderildi")
    }

    /// Sayfa ilk 100 blokla açılır, kalanı 100'erlik parçalarla eklenir —
    /// uzun bir not **kırpılmaz**.
    private func shareToNotion(title: String, text: String, meetingID: Int64) async throws {
        guard let parent = ShareTargets.notionPageID(settings.notionPageID) else {
            throw OraError.connectionFailed(reason: "Notion sayfa adresi geçersiz.")
        }
        let token = secrets.secret(for: .notion) ?? ""
        let blocks = ShareTargets.notionBlocks(text)
        let first = Array(blocks.prefix(ShareTargets.notionBatch))
        let body: [String: Any] = [
            "parent": ["page_id": parent],
            "properties": ["title": ["title": [["type": "text", "text": ["content": title]]]]],
            "children": first,
        ]
        let data = try await outbound.send(
            try ShareTargets.notionRequest(token: token, path: "pages", method: "POST", body: body),
            connection: .notion, purpose: .share, meetingID: meetingID, characters: text.count)
        guard blocks.count > first.count else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let page = json["id"] as? String else {
            throw OraError.connectionFailed(reason: "Notion sayfası açıldı ama devamı eklenemedi.")
        }
        var rest = blocks.dropFirst(first.count)
        while !rest.isEmpty {
            let batch = Array(rest.prefix(ShareTargets.notionBatch))
            rest = rest.dropFirst(batch.count)
            _ = try await outbound.send(
                try ShareTargets.notionRequest(token: token, path: "blocks/\(page)/children",
                                               method: "PATCH", body: ["children": batch]),
                connection: .notion, purpose: .share, meetingID: meetingID, characters: 0)
        }
    }

    /// Özet hazır olunca: otomatik paylaşımı açık, kurulu ve **onaylı**
    /// hedeflere gönderir. Onay ancak bir kez elle gönderirken verilir; ön
    /// izlemesi görülmemiş bir hedefe kendiliğinden hiçbir şey gitmez.
    func autoShare(meetingID: Int64) async {
        let targets = [ConnectionKind.slack, .notion].filter {
            settings.autoShareConnections.contains($0.rawValue)
                && isConfigured($0) && isConsented($0)
        }
        guard !targets.isEmpty,
              let payload = await payload(meetingID), payload.summary != nil else { return }
        for kind in targets {
            do {
                try await share(kind, meetingID: meetingID, payload: payload)
            } catch let error as OraError {
                Log.warning(.net, "Otomatik paylaşım başarısız (\(kind.displayName)): "
                            + error.turkishDetail)
                onError?(error)
            } catch {
                onError?(.connectionFailed(reason: error.localizedDescription))
            }
        }
    }

    /// Dışa aktarımla aynı içerik, veritabanındaki hâlinden.
    func payload(_ meetingID: Int64) async -> MeetingExport.Payload? {
        guard let loaded = try? await store.load(meetingID) else { return nil }
        let people = (try? await store.calendarParticipants(meetingID)) ?? []
        return MeetingExport.Payload(title: loaded.meeting.title, date: loaded.meeting.date,
                                     duration: loaded.meeting.duration,
                                     segments: loaded.segments, summary: loaded.summary,
                                     topics: loaded.topics, actions: loaded.actions,
                                     participants: people)
    }
}
