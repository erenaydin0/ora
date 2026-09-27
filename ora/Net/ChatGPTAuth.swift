import AppKit
import CryptoKit
import Foundation
import Network

/// ChatGPT aboneliğiyle giriş — Codex'in "Sign in with ChatGPT" akışı
/// (OAuth 2.0 yetki kodu + PKCE). OpenAI, aboneliğin OpenCode, Cline gibi
/// üçüncü taraf araçlarda kullanılmasını açıkça destekliyor; istemci kimliği,
/// adresler ve başlıklar Codex CLI'ınki (Anarlog ve OpenCode da böyle yapıyor).
///
/// **Claude Pro/Max aboneliği bilerek yok:** Anthropic 19 Şubat 2026'dan beri
/// abonelik token'larının Claude Code ve Claude.ai dışında kullanılmasını
/// tüketici koşullarının ihlali sayıyor. Claude için API anahtarı kullanılır.
nonisolated enum ChatGPTAuth {

    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let callbackPort: UInt16 = 1455
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let scope = "openid profile email offline_access"
    /// Codex arka ucunun beklediği istemci künyesi.
    static let originator = "codex_cli_rs"
    static let clientVersion = "0.145.0"

    /// Keychain'de JSON olarak durur (`SecretStoring`, `.chatGPT`).
    struct Credential: Codable, Equatable, Sendable {
        var access: String
        var refresh: String
        var expires: Date
        var accountID: String?

        /// Süresi bir dakikadan az kaldıysa yenilenir.
        var needsRefresh: Bool { expires.timeIntervalSinceNow < 60 }

        var encoded: String {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            return String(data: (try? encoder.encode(self)) ?? Data(), encoding: .utf8) ?? ""
        }

        static func decode(_ text: String?) -> Credential? {
            guard let data = text?.data(using: .utf8) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try? decoder.decode(Credential.self, from: data)
        }
    }

    /// Başlamış bir giriş: tarayıcıya gönderilen adres ve doğrulama sırları.
    struct Session: Sendable, Equatable {
        let verifier: String
        let state: String
        var url: URL {
            var components = URLComponents(string: authorizeURL)!
            components.queryItems = [
                .init(name: "response_type", value: "code"),
                .init(name: "client_id", value: clientID),
                .init(name: "redirect_uri", value: redirectURI),
                .init(name: "scope", value: scope),
                .init(name: "code_challenge", value: ChatGPTAuth.challenge(for: verifier)),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: state),
                .init(name: "id_token_add_organizations", value: "true"),
                .init(name: "codex_cli_simplified_flow", value: "true"),
                .init(name: "originator", value: originator),
            ]
            return components.url!
        }

        static func start() -> Session {
            Session(verifier: randomToken(), state: randomToken())
        }
    }

    // MARK: - PKCE

    static func randomToken(bytes: Int = 32) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Dönüş

    /// Tarayıcının döndüğü adresten ya da kullanıcının yapıştırdığı metinden
    /// yetki kodu. `state` eşleşmezse giriş reddedilir (CSRF).
    static func code(from input: String, session: Session) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let items = components.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OraError.connectionFailed(
                reason: "Adreste giriş kodu bulunamadı. Tarayıcının adres çubuğundaki "
                    + "adresin tamamını yapıştırın.")
        }
        guard items.first(where: { $0.name == "state" })?.value == session.state else {
            throw OraError.connectionFailed(reason: "Bu giriş süresi doldu; yeniden deneyin.")
        }
        return code
    }

    // MARK: - Token

    static func exchangeRequest(code: String, session: Session) -> URLRequest {
        form(["grant_type": "authorization_code", "client_id": clientID, "code": code,
              "redirect_uri": redirectURI, "code_verifier": session.verifier])
    }

    static func refreshRequest(_ credential: Credential) -> URLRequest {
        form(["grant_type": "refresh_token", "client_id": clientID,
              "refresh_token": credential.refresh])
    }

    private static func form(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        return request
    }

    static func credential(from data: Data, previous: Credential? = nil) throws -> Credential {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw OraError.connectionFailed(reason: "ChatGPT girişi tamamlanamadı.")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        return Credential(
            access: access,
            refresh: json["refresh_token"] as? String ?? previous?.refresh ?? access,
            expires: Date().addingTimeInterval(expiresIn),
            accountID: accountID(fromJWT: json["id_token"] as? String)
                ?? accountID(fromJWT: access) ?? previous?.accountID)
    }

    /// Codex arka ucu `chatgpt-account-id` başlığını ister; kimlik JWT'nin
    /// `https://api.openai.com/auth` iddiasında durur.
    static func accountID(fromJWT jwt: String?) -> String? {
        guard let part = jwt?.split(separator: ".").dropFirst().first else { return nil }
        var base64 = part.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any],
           let id = auth["chatgpt_account_id"] as? String, !id.isEmpty { return id }
        if let id = payload["chatgpt_account_id"] as? String, !id.isEmpty { return id }
        if let organizations = payload["organizations"] as? [[String: Any]],
           let id = organizations.first?["id"] as? String { return id }
        return nil
    }

    // MARK: - Codex istekleri

    static func headers(_ credential: Credential) -> [String: String] {
        var headers = ["authorization": "Bearer \(credential.access)",
                       "originator": originator,
                       "user-agent": originator,
                       "openai-beta": "responses=experimental"]
        if let id = credential.accountID { headers["chatgpt-account-id"] = id }
        return headers
    }

    static func modelsRequest(_ credential: Credential) -> URLRequest {
        let base = ConnectionKind.chatGPT.defaultBaseURL!
        var request = URLRequest(url: URL(string: "\(base)/models?client_version=\(clientVersion)")!,
                                 timeoutInterval: 30)
        for (name, value) in headers(credential) { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Hesabın görebildiği modeller, katalog sırasıyla (gizliler hariç).
    static func models(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.filter { $0["visibility"] as? String != "hide" }
            .compactMap { $0["slug"] as? String }
    }

    static func openInBrowser(_ session: Session) {
        NSWorkspace.shared.open(session.url)
    }
}

/// Tarayıcının `http://localhost:1455/auth/callback?code=…` dönüşünü yakalayan
/// tek atımlık sunucu. **Yalnızca geri döngü arayüzünde** dinler — bu Mac
/// dışından erişilemez — ve ilk geçerli dönüşten sonra kapanır.
nonisolated final class OAuthCallbackServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ora.oauth.callback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw OraError.connectionFailed(reason: "Giriş portu geçersiz.")
        }
        listener = try NWListener(using: parameters, on: endpointPort)
    }

    /// Dönüş adresini (yol + sorgu) bekler.
    func waitForCallback() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let alreadyDone = lock.withLock {
                if !finished { self.continuation = continuation }
                return finished
            }
            guard !alreadyDone else {
                continuation.resume(throwing: CancellationError())
                return
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.finish(.failure(OraError.connectionFailed(
                        reason: "Giriş dönüşü dinlenemedi (1455 portu kullanımda olabilir; "
                            + "Codex CLI açıksa kapatın). Adres çubuğundaki adresi yapıştırarak "
                            + "da tamamlayabilirsiniz.")))
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let isCallback = target.hasPrefix("/auth/callback")
            let body = isCallback
                ? "<html><meta charset='utf-8'><body style='font-family:-apple-system;padding:40px'>"
                  + "<h3>Giriş tamamlandı</h3><p>ora'ya dönebilirsiniz.</p></body></html>"
                : "Bulunamadı"
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\n"
                + "Content-Type: text/html; charset=utf-8\r\nConnection: close\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            if isCallback { self?.finish(.success("http://localhost:1455" + target)) }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        let pending: CheckedContinuation<String, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            defer { continuation = nil }
            return continuation
        }
        listener.cancel()
        pending?.resume(with: result)
    }
}
