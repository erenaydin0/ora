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
    /// Yalnızca ChatGPT aboneliğinde: `chatgpt-account-id` başlığı.
    var accountID: String? = nil
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
        case .chatGPT:
            return try codexRequest(system: system, prompt: prompt)
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

    /// ChatGPT aboneliği: Codex arka ucunun Responses API'si. Arka uç
    /// `store: false` ve `stream: true` ister, `max_output_tokens` kabul etmez.
    private func codexRequest(system: String, prompt: String) throws -> URLRequest {
        let base = kind.defaultBaseURL!
        var request = URLRequest(url: URL(string: base + "/responses")!,
                                 timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        let credential = ChatGPTAuth.Credential(access: secret ?? "", refresh: "",
                                                expires: .distantFuture, accountID: accountID)
        for (name, value) in ChatGPTAuth.headers(credential) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let body: [String: Any] = [
            "model": model,
            "instructions": system,
            "input": [["role": "user",
                       "content": [["type": "input_text", "text": prompt]]]],
            "store": false,
            "stream": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Yanıt

    static func text(from data: Data, kind: ConnectionKind) throws -> String {
        if kind == .chatGPT { return try streamedText(from: data) }
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

    /// Codex'in olay akışı (SSE): metin `response.output_text.delta`
    /// parçalarından birleştirilir; parça gelmediyse `response.completed`
    /// içindeki çıktıdan okunur. `response.failed` / `error` Türkçe hataya döner.
    static func streamedText(from data: Data) throws -> String {
        let name = ConnectionKind.chatGPT.displayName
        var deltas = ""
        var completed = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                      as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "response.output_text.delta":
                deltas += event["delta"] as? String ?? ""
            case "response.completed":
                let response = event["response"] as? [String: Any]
                let output = response?["output"] as? [[String: Any]] ?? []
                completed = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                    .filter { $0["type"] as? String == "output_text" }
                    .compactMap { $0["text"] as? String }.joined()
            case "response.failed", "error":
                let response = event["response"] as? [String: Any]
                let error = (response?["error"] ?? event["error"]) as? [String: Any]
                let message = error?["message"] as? String ?? event["message"] as? String
                throw OraError.connectionFailed(
                    reason: "\(name) isteği tamamlayamadı" + (message.map { ": \($0)" } ?? "."))
            default:
                continue
            }
        }
        let text = deltas.isEmpty ? completed : deltas
        guard !text.isEmpty else {
            throw OraError.connectionFailed(reason: "\(name) boş yanıt verdi.")
        }
        return text
    }
}
