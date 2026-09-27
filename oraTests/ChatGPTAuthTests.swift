import Foundation
import Testing
@testable import ora

/// ChatGPT aboneliğiyle giriş (Codex "Sign in with ChatGPT" akışı).
@Suite("ChatGPT aboneliği", .serialized)
struct ChatGPTAuthTests {

    private func jwt(_ payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return "e30." + ChatGPTAuth.base64URL(data) + ".imza"
    }

    // MARK: - PKCE ve adres

    /// Beklenen değer kabukta bağımsız hesaplandı:
    /// `printf %s … | shasum -a 256 | xxd -r -p | base64 | tr '+/' '-_' | tr -d '='`
    @Test
    func pkceBagimsizHesaplaUyusur() {
        #expect(ChatGPTAuth.challenge(for: "dBjftJeZ4CVP-mJ92K9W8y8sR8QhQ3bPRAC3z6Xzl6Y")
                    == "QFgcjB4cXZ-JtZWDnx66gwJ_i1BkaC8DyLQmifHMbMc")
        let token = ChatGPTAuth.randomToken()
        #expect(token.count >= 43 && !token.contains("=") && !token.contains("+"))
    }

    @Test
    func yetkiAdresiCodexAkisiniKurar() throws {
        let session = ChatGPTAuth.Session(verifier: "v", state: "durum")
        let items = try #require(URLComponents(url: session.url, resolvingAgainstBaseURL: false)?
                                    .queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(session.url.host == "auth.openai.com")
        #expect(value("client_id") == ChatGPTAuth.clientID)
        #expect(value("redirect_uri") == "http://localhost:1455/auth/callback")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") == ChatGPTAuth.challenge(for: "v"))
        #expect(value("state") == "durum")
        #expect(value("originator") == "codex_cli_rs")
    }

    /// Dönüş adresinden kod; `state` tutmazsa giriş reddedilir.
    @Test
    func donusAyristirilirDurumDenetlenir() throws {
        let session = ChatGPTAuth.Session(verifier: "v", state: "abc")
        #expect(try ChatGPTAuth.code(
            from: "http://localhost:1455/auth/callback?code=ac_123&scope=x&state=abc",
            session: session) == "ac_123")
        #expect(throws: OraError.self) {
            try ChatGPTAuth.code(from: "http://localhost:1455/auth/callback?code=ac_1&state=baska",
                                 session: session)
        }
        #expect(throws: OraError.self) {
            try ChatGPTAuth.code(from: "ac_123", session: session)
        }
    }

    // MARK: - Token

    @Test
    func hesapKimligiJWTdenOkunur() {
        #expect(ChatGPTAuth.accountID(fromJWT: jwt(
            ["https://api.openai.com/auth": ["chatgpt_account_id": "acc_1"]])) == "acc_1")
        #expect(ChatGPTAuth.accountID(fromJWT: jwt(["organizations": [["id": "org_9"]]]))
                    == "org_9")
        #expect(ChatGPTAuth.accountID(fromJWT: "bozuk") == nil)
    }

    /// Yenileme yanıtında yenileme token'ı yoksa eskisi korunur.
    @Test
    func tokenYanitiCozulurYenilemeTokeniKorunur() throws {
        let previous = ChatGPTAuth.Credential(access: "eski", refresh: "yenile", expires: .now,
                                              accountID: "acc_1")
        let renewed = try ChatGPTAuth.credential(
            from: Data(#"{"access_token":"yeni","expires_in":3600}"#.utf8), previous: previous)
        #expect(renewed.access == "yeni")
        #expect(renewed.refresh == "yenile")
        #expect(renewed.accountID == "acc_1")
        #expect(!renewed.needsRefresh)
        let decoded = try #require(ChatGPTAuth.Credential.decode(renewed.encoded))
        #expect(decoded.access == renewed.access && decoded.refresh == renewed.refresh)
        #expect(abs(decoded.expires.timeIntervalSince(renewed.expires)) < 1,
                "saniyeye yuvarlanarak saklanır")
    }

    @Test
    func modelKatalogundanGizliOlanlarDuser() {
        let data = Data(#"{"models":[{"slug":"gpt-a"},{"slug":"gizli","visibility":"hide"},{"slug":"gpt-b","visibility":"list"}]}"#.utf8)
        #expect(ChatGPTAuth.models(from: data) == ["gpt-a", "gpt-b"])
    }

    // MARK: - İstek ve yanıt

    @Test
    func codexIstegiDogruKurulur() throws {
        let outbound = Outbound(transport: FakeTransport(),
                                log: OutboundLog(url: URL(fileURLWithPath: "/dev/null"))) { _, _, _ in nil }
        let request = try ProviderClient(kind: .chatGPT, model: "gpt-a", baseURL: nil,
                                         secret: "erişim", accountID: "acc_1", outbound: outbound)
            .makeRequest(system: "S", prompt: "P")
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer erişim")
        #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "acc_1")
        #expect(request.value(forHTTPHeaderField: "originator") == "codex_cli_rs")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!)
                                as? [String: Any])
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["instructions"] as? String == "S")
        #expect(body["max_output_tokens"] == nil, "Codex kabul etmiyor")
    }

    @Test
    func akisYanitiBirlestirilir() throws {
        let deltas = """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"mer"}

            data: {"type":"response.output_text.delta","delta":"haba"}

            data: {"type":"response.completed","response":{"output":[]}}
            """
        #expect(try ProviderClient.text(from: Data(deltas.utf8), kind: .chatGPT) == "merhaba")

        let completedOnly = #"data: {"type":"response.completed","response":{"output":[{"content":[{"type":"output_text","text":"tamam"}]}]}}"#
        #expect(try ProviderClient.text(from: Data(completedOnly.utf8), kind: .chatGPT) == "tamam")

        let failed = #"data: {"type":"response.failed","response":{"error":{"message":"kota doldu"}}}"#
        #expect(throws: OraError.self) {
            try ProviderClient.text(from: Data(failed.utf8), kind: .chatGPT)
        }
    }

    // MARK: - Uçtan uca

    /// Yapıştırılan dönüş adresiyle giriş tamamlanır: kod token'a çevrilir,
    /// Keychain'e yazılır, ilk model seçilir; token günlüğe düşmez.
    @Test
    func girisTamamlanirModelSecilir() async throws {
        let access = jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acc_7"]])
        let transport = FakeTransport([
            (200, #"{"access_token":"\#(access)","refresh_token":"GIZLI_YENILEME","expires_in":3600}"#),
            (200, #"{"models":[{"slug":"gpt-a"},{"slug":"gpt-b"}]}"#),
        ])
        let h = try Harness(intelligence: UnavailableIntelligence(), transport: transport)
        let center = h.controller.connections

        // Tarayıcı açılmaz, dinlenmez: yalnızca oturum kurulur.
        let state = center.startChatGPTSession().state
        let error = await center.completeChatGPTSignIn(
            "http://localhost:1455/auth/callback?code=ac_1&state=\(state)")

        #expect(error == nil)
        #expect(center.isConfigured(.chatGPT))
        #expect(h.settings.model(for: .chatGPT) == "gpt-a")
        #expect(center.chatGPTModels == ["gpt-a", "gpt-b"])
        #expect(ChatGPTAuth.Credential.decode(h.secrets.secret(for: .chatGPT))?.accountID == "acc_7")
        let raw = (try? String(contentsOf: h.outboundLog.url, encoding: .utf8)) ?? ""
        #expect(!raw.contains("GIZLI_YENILEME"))
        #expect(transport.requests.first?.url == ChatGPTAuth.tokenURL)
    }

    /// Süresi dolan token kullanılmadan önce yenilenir.
    @Test
    func suresiDolanTokenYenilenir() async throws {
        let transport = FakeTransport([(200, #"{"access_token":"taze","expires_in":3600}"#)])
        let h = try Harness(intelligence: UnavailableIntelligence(), transport: transport)
        let expired = ChatGPTAuth.Credential(access: "bayat", refresh: "r",
                                             expires: .now.addingTimeInterval(-10), accountID: "a")
        try h.secrets.setSecret(expired.encoded, for: .chatGPT)

        let credential = try await h.controller.connections.validChatGPTCredential()

        #expect(credential.access == "taze")
        #expect(credential.refresh == "r")
        #expect(ChatGPTAuth.Credential.decode(h.secrets.secret(for: .chatGPT))?.access == "taze")
        let body = String(data: transport.requests.first?.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=refresh_token"))
    }

    /// Dönüş sunucusu yalnızca geri döngüde dinler, dönüşü yakalar ve kapanır.
    @Test
    func donusSunucusuYakalar() async throws {
        let port: UInt16 = 18_455
        let server = try OAuthCallbackServer(port: port)
        let waiting = Task { try await server.waitForCallback() }

        var html = ""
        for _ in 0 ..< 50 {
            if let (data, _) = try? await URLSession.shared.data(from: URL(
                string: "http://localhost:\(port)/auth/callback?code=ac_9&state=s")!) {
                html = String(decoding: data, as: UTF8.self)
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(html.contains("Giriş tamamlandı"))
        #expect(try await waiting.value == "http://localhost:1455/auth/callback?code=ac_9&state=s")
    }
}
