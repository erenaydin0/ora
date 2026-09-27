import Foundation
import Testing
@testable import ora

/// Bağlantı Kuralları (CLAUDE.md, Faz 11) — her madde testle korunur:
/// tek ağ kapısı, varsayılan kapalı, onay, toplantı kilidi, künye günlüğü,
/// Keychain dışında anahtar yok, sağlayıcıya ulaşılamazsa cihaza düşme.
@Suite("Bağlantılar", .serialized)
struct ConnectionsTests {

    // MARK: - Kural 7: ağa çıkan tek modül

    /// `URLSession` yalnızca `ora/Net/` altında geçer. Kaynak ağacı taranır;
    /// kural belgeyle değil testle korunur.
    @Test
    func urlSessionYalnizcaNetModulunde() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ora")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty, "kaynak ağacı bulunamadı: \(root.path)")

        let pattern = try Regex(#"\bURLSession\b"#)
        let offenders = try files.filter { url in
            guard !url.path.contains("/ora/Net/") else { return false }
            return try String(contentsOf: url, encoding: .utf8).contains(pattern)
        }
        #expect(offenders.isEmpty, "Net dışında URLSession: \(offenders.map(\.lastPathComponent))")
    }

    // MARK: - Kapı

    private func makeCenter(_ h: Harness) -> ConnectionCenter { h.controller.connections }

    private func anthropicReply(_ text: String) -> String {
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [text]),
                             encoding: .utf8)!.dropFirst().dropLast()
        return #"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},"#
            + #"{"type":"text","text":"# + escaped + "}]}"
    }

    /// Kurulmamış bağlantıya istek gitmez; denemede onay istenmez; toplantı
    /// verisi taşıyan istek onaysız gitmez.
    @Test
    func kurulumVeOnayOlmadanIstekGitmez() async throws {
        let h = try Harness(intelligence: UnavailableIntelligence())
        let center = makeCenter(h)

        #expect(await center.denial(.anthropic, purpose: .test, meetingID: nil) != nil,
                "anahtar yok")
        try h.secrets.setSecret("sk-test", for: .anthropic)
        center.refresh()
        #expect(await center.denial(.anthropic, purpose: .test, meetingID: nil) == nil,
                "deneme onay istemez")
        #expect(await center.denial(.anthropic, purpose: .summary, meetingID: nil) != nil,
                "özet onay ister")
        center.grantConsent(.anthropic)
        #expect(await center.denial(.anthropic, purpose: .summary, meetingID: nil) == nil)
        #expect(h.transport.requests.isEmpty, "yalnızca politika soruldu, istek gitmedi")
    }

    /// "Cihazdan çıkmasın" işaretli toplantıya kapı istek göndermez.
    @Test
    func kilitliToplantiKapidaReddedilir() async throws {
        let h = try Harness(intelligence: UnavailableIntelligence())
        let center = makeCenter(h)
        try h.secrets.setSecret("https://hooks.slack.com/services/x", for: .slack)
        center.refresh()
        center.grantConsent(.slack)
        let id = try await h.seed(text: "gizli toplantı")
        try await h.store.setLocalOnly(id, true)

        let payload = try #require(await center.payload(id))
        await #expect(throws: OraError.self) {
            try await center.share(.slack, meetingID: id, payload: payload)
        }
        #expect(h.transport.requests.isEmpty)
    }

    /// Künye günlüğe düşer; içerik ve anahtar düşmez.
    @Test
    func gunlugeKunyeDuserAnahtarDusmez() async throws {
        let h = try Harness(intelligence: UnavailableIntelligence(),
                            transport: FakeTransport([(200, "ok")]))
        let center = makeCenter(h)
        try h.secrets.setSecret("https://hooks.slack.com/services/GIZLI", for: .slack)
        center.refresh()
        center.grantConsent(.slack)
        let id = try await h.seed(text: "bütçe konuşuldu")
        let payload = try #require(await center.payload(id))

        try await center.share(.slack, meetingID: id, payload: payload)

        let records = h.outboundLog.recent()
        #expect(records.count == 1)
        #expect(records.first?.connection == .slack)
        #expect(records.first?.purpose == .share)
        #expect(records.first?.meetingID == id)
        #expect((records.first?.characters ?? 0) > 0)
        let raw = try String(contentsOf: h.outboundLog.url, encoding: .utf8)
        #expect(!raw.contains("GIZLI"), "anahtar günlüğe yazılmadı")
        #expect(!raw.contains("bütçe"), "içerik günlüğe yazılmadı")
    }

    // MARK: - Sağlayıcı istekleri

    @Test
    func anthropicIstegiDogruKurulur() throws {
        let outbound = Outbound(transport: FakeTransport(), log: OutboundLog(url: URL(
            fileURLWithPath: "/dev/null"))) { _, _, _ in nil }
        let client = ProviderClient(kind: .anthropic, model: "claude-opus-5", baseURL: nil,
                                    secret: "sk-test", outbound: outbound)
        let request = try client.makeRequest(system: "S", prompt: "P")

        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!)
                                as? [String: Any])
        #expect(body["model"] as? String == "claude-opus-5")
        #expect(body["system"] as? String == "S")
        #expect(body["fallbacks"] as? String == "default")
        #expect((body["max_tokens"] as? Int ?? 0) >= 16_000)
    }

    @Test
    func openAIUyumluIstekVeYerelSunucu() throws {
        let outbound = Outbound(transport: FakeTransport(), log: OutboundLog(url: URL(
            fileURLWithPath: "/dev/null"))) { _, _, _ in nil }
        let remote = try ProviderClient(kind: .openRouter, model: "m", baseURL: nil,
                                        secret: "k", outbound: outbound)
            .makeRequest(system: "S", prompt: "P")
        #expect(remote.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(remote.value(forHTTPHeaderField: "authorization") == "Bearer k")

        let local = try ProviderClient(kind: .localServer, model: "qwen",
                                       baseURL: URL(string: "http://localhost:1234/v1"),
                                       secret: nil, outbound: outbound)
            .makeRequest(system: "S", prompt: "P")
        #expect(local.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(local.value(forHTTPHeaderField: "authorization") == nil)
    }

    @Test
    func yanitlarCozulurRetVeHataTurkceyeCevrilir() throws {
        #expect(try ProviderClient.text(from: Data(anthropicReply("merhaba").utf8),
                                        kind: .anthropic) == "merhaba",
                "düşünme bloğu atlanır")
        #expect(throws: OraError.self) {
            try ProviderClient.text(from: Data(#"{"stop_reason":"refusal","content":[]}"#.utf8),
                                    kind: .anthropic)
        }
        #expect(try ProviderClient.text(
            from: Data(#"{"choices":[{"message":{"content":"selam"}}]}"#.utf8),
            kind: .openAI) == "selam")
        #expect(Outbound.message(status: 401, connection: .anthropic, body: Data())
                    .contains("anahtarı reddetti"))
    }

    // MARK: - Paylaşım biçimi

    @Test
    func paylasimBicimleri() throws {
        #expect(ShareTargets.slackText("# Bütçe\n#### Aksiyonlar\n- [ ] **Rapor** hazırla\n- madde")
                    == "*Bütçe*\n*Aksiyonlar*\n☐ *Rapor* hazırla\n• madde")

        let blocks = ShareTargets.notionBlocks("# Başlık\n#### Kararlar\n- [x] bitti\n- madde\nparagraf "
                                               + String(repeating: "a", count: 2_500))
        #expect(blocks.map { $0["type"] as? String } ==
                ["heading_3", "to_do", "bulleted_list_item", "paragraph"], "başlık sayfanın adı olur")
        let paragraph = try #require(blocks.last?["paragraph"] as? [String: Any])
        #expect((paragraph["rich_text"] as? [Any])?.count == 2, "2.000'lik parçalara bölündü, kırpılmadı")

        #expect(ShareTargets.notionPageID(
            "https://www.notion.so/acme/Toplanti-Notlari-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d?pvs=4")
                == "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")
        #expect(ShareTargets.notionPageID("1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d")
                == "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")
        #expect(ShareTargets.notionPageID("sayfa") == nil)
    }

    /// Paylaşılan metinde transkript yoktur (kural 4).
    @Test
    func paylasimMetnindeTranskriptYok() async throws {
        let h = try Harness(intelligence: UnavailableIntelligence())
        let id = try await h.seed(text: "bu cümle transkriptte kalmalı")
        let payload = try #require(await h.controller.connections.payload(id))
        #expect(!ConnectionCenter.shareText(payload).contains("transkriptte kalmalı"))
    }

    // MARK: - Hat

    private func cloudReadyHarness(_ transport: FakeTransport) throws -> Harness {
        let h = try Harness(intelligence: SlowIntelligence(tag: "A", step: .milliseconds(5)),
                            transport: transport)
        try h.secrets.setSecret("sk-test", for: .anthropic)
        h.controller.connections.refresh()
        h.controller.connections.grantConsent(.anthropic)
        h.settings.cloudProvider = .anthropic
        h.settings.summaryEngine = .cloud
        return h
    }

    private let summaryJSON = #"""
        {"overview":["Bütçe 2 milyon TL olarak onaylandı."],"decisions":["Bütçe onaylandı."],
         "actions":[],"topics":[{"title":"Bütçe","bullets":["Bütçe 2 milyon TL."]}]}
        """#

    /// Bağlı sağlayıcı seçiliyse özet oradan gelir; istek o toplantının
    /// kimliğiyle kapıdan geçer.
    @Test
    func bagliSaglayiciOzetiUretir() async throws {
        let transport = FakeTransport()
        let h = try cloudReadyHarness(transport)
        transport.enqueue(status: 200, body: anthropicReply(summaryJSON))
        let id = try await h.seed(text: "bütçe iki milyon lira olarak onaylandı")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("yüklendi") { !h.controller.transcript.isEmpty }

        await h.controller.summarizeNow()

        #expect(transport.requests.count == 1)
        #expect(h.controller.summary?.kararlar == ["Bütçe onaylandı."])
        #expect(h.outboundLog.recent().first?.meetingID == id)
    }

    /// Kilitli toplantı bulut seçiliyken bile cihazda özetlenir.
    @Test
    func kilitliToplantiCihazdaOzetlenir() async throws {
        let transport = FakeTransport()
        let h = try cloudReadyHarness(transport)
        let id = try await h.seed(text: "gizli toplantı metni")
        try await h.store.setLocalOnly(id, true)
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("yüklendi") { !h.controller.transcript.isEmpty }

        await h.controller.summarizeNow()

        #expect(transport.requests.isEmpty, "hiç istek gitmedi")
        #expect(h.controller.summary?.genelBakis.first?.hasPrefix("A genel bakış") == true,
                "cihazdaki motor üretti")
    }

    /// Kural 9: sağlayıcıya ulaşılamazsa özet cihazda üretilir ve söylenir.
    @Test
    func saglayiciHataVerirseCihazaDusulur() async throws {
        let transport = FakeTransport([(529, #"{"error":{"message":"Overloaded"}}"#)])
        let h = try cloudReadyHarness(transport)
        let id = try await h.seed(text: "toplantı metni")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("yüklendi") { !h.controller.transcript.isEmpty }

        await h.controller.summarizeNow()

        #expect(h.controller.summary?.genelBakis.first?.hasPrefix("A genel bakış") == true)
        #expect(h.controller.summaryNotice?.contains("cihazda üretildi") == true)
    }

    /// Bağlantı kaldırılınca cihazdaki motora dönülür (kural 1).
    @Test
    func baglantiKaldirilincaCihazaDonulur() throws {
        let h = try cloudReadyHarness(FakeTransport())
        h.controller.connections.remove(.anthropic)
        #expect(h.settings.summaryEngine == .apple)
        #expect(!h.controller.connections.isConsented(.anthropic))
        #expect(h.secrets.secret(for: .anthropic) == nil)
    }

    /// Kayıt anonsu metin buluta gidiyorsa bunu söyler.
    @Test
    func anonsDogruKalir() throws {
        let h = try cloudReadyHarness(FakeTransport())
        #expect(h.settings.sendsTranscripts)
        #expect(!OraSettings.announcement(sendsText: true).contains("hiçbir yere gönderilmiyor"))
        #expect(OraSettings.announcement(sendsText: false).contains("hiçbir yere gönderilmiyor"))
    }
}
