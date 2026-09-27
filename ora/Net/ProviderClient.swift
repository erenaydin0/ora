import Foundation

/// Kullanıcının bağladığı AI sağlayıcısına tek metin isteği.
///
/// İki biçim: Anthropic Messages API ve OpenAI uyumlu Chat Completions
/// (OpenAI, OpenRouter, Ollama, LM Studio). SDK yok — Swift için resmi SDK
/// bulunmuyor, istek ham HTTP ve yalnızca `Outbound` üzerinden gider.
nonisolated struct ProviderClient: Sendable {

    let kind: ConnectionKind
    let model: String
    let baseURL: URL?
    let secret: String?
    let outbound: Outbound

    /// Uzun bir toplantının tek geçişte özetlenmesi dakikalar sürebilir.
    static let timeout: TimeInterval = 600
    /// Özet JSON'u 3.000-4.000 token civarında (§37); tavan cömert.
    static let maxTokens = 16_000

    func complete(system: String, prompt: String, purpose: OutboundPurpose,
                  meetingID: Int64?) async throws -> String {
        let request = try makeRequest(system: system, prompt: prompt)
        let data = try await outbound.send(request, connection: kind, purpose: purpose,
                                           meetingID: meetingID,
                                           characters: system.count + prompt.count)
        return try Self.text(from: data, kind: kind)
    }

    // MARK: - İstek

    func makeRequest(system: String, prompt: String) throws -> URLRequest {
        switch kind {
        case .anthropic:
            return try anthropicRequest(system: system, prompt: prompt)
        case .openAI, .openRouter, .localServer:
            return try chatCompletionsRequest(system: system, prompt: prompt)
        case .slack, .notion:
            throw OraError.connectionFailed(reason: "\(kind.displayName) bir AI sağlayıcısı değil.")
        }
    }

    private func anthropicRequest(system: String, prompt: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!,
                                 timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(secret ?? "", forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        // Opus 5 / Fable ailesinde güvenlik sınıflandırıcısı isteği geri
        // çevirirse sunucu tarafı yedek model devreye girer.
        if model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable") {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func chatCompletionsRequest(system: String, prompt: String) throws -> URLRequest {
        guard let root = baseURL ?? kind.defaultBaseURL.flatMap(URL.init(string:)) else {
            throw OraError.connectionFailed(reason: "\(kind.displayName) adresi geçersiz.")
        }
        var request = URLRequest(url: root.appending(path: "chat/completions"),
                                 timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let secret, !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Yanıt

    static func text(from data: Data, kind: ConnectionKind) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OraError.connectionFailed(reason: "\(kind.displayName) okunamayan bir yanıt verdi.")
        }
        if kind == .anthropic {
            if json["stop_reason"] as? String == "refusal" {
                throw OraError.connectionFailed(reason: "\(kind.displayName) isteği geri çevirdi.")
            }
            // Düşünme blokları boş gelir; yalnızca metin blokları okunur.
            let blocks = json["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else {
                throw OraError.connectionFailed(reason: "\(kind.displayName) boş yanıt verdi.")
            }
            return text
        }
        let choices = json["choices"] as? [[String: Any]] ?? []
        guard let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty else {
            throw OraError.connectionFailed(reason: "\(kind.displayName) boş yanıt verdi.")
        }
        return text
    }
}
