import Foundation

/// Özeti Slack'e ve Notion'a gönderen istekler. **Transkript gönderilmez**
/// (kural 4): içerik, dışa aktarımın transkriptsiz Markdown'ıdır — başlık,
/// künye, aksiyonlar, genel bakış, kararlar, konular.
nonisolated enum ShareTargets {

    // MARK: - Slack (gelen webhook)

    static func slackRequest(webhook: String, markdown: String) throws -> URLRequest {
        guard let url = URL(string: webhook), url.scheme == "https" else {
            throw OraError.connectionFailed(reason: "Slack webhook adresi geçersiz.")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": slackText(markdown)])
        return request
    }

    /// Slack'in mrkdwn'ı başlık tanımaz ve kalını tek yıldızla yazar.
    static func slackText(_ markdown: String) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            var line = String(raw)
            if let heading = line.firstRange(of: /^#{1,6}\s+/) {
                line = "*" + line[heading.upperBound...] + "*"
            }
            line = line.replacingOccurrences(of: "**", with: "*")
            if line.hasPrefix("- [ ] ") { line = "☐ " + line.dropFirst(6) }
            if line.hasPrefix("- [x] ") { line = "☑ " + line.dropFirst(6) }
            if line.hasPrefix("- ") { line = "• " + line.dropFirst(2) }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - Notion

    static let notionVersion = "2022-06-28"
    /// Notion bir istekte en fazla 100 blok kabul eder.
    static let notionBatch = 100
    /// Zengin metin parçası en fazla 2.000 karakter.
    static let notionTextLimit = 2_000

    /// Sayfa adresinden ya da çıplak kimlikten 32 haneli sayfa kimliği.
    /// Notion adresinde kimlik her zaman sorgu dizgisinden önceki son 32
    /// onaltılık hanedir (tireli ya da tiresiz); başlık kısmındaki harflere
    /// bakılmaz.
    static func notionPageID(_ input: String) -> String? {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        let compact = path.lowercased().replacingOccurrences(of: "-", with: "")
        let id = String(compact.suffix(32))
        return id.count == 32 && id.allSatisfy(\.isHexDigit) ? id : nil
    }

    static func notionRequest(token: String, path: String, method: String,
                              body: [String: Any]?) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/" + path)!,
                                 timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "notion-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }

    /// Markdown satırlarından Notion blokları. Uzun satır 2.000 karakterlik
    /// parçalara bölünür, **kırpılmaz**.
    static func notionBlocks(_ markdown: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        for raw in markdown.split(separator: "\n") {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("# ") else { continue }   // başlık sayfanın adı
            line = line.replacingOccurrences(of: "**", with: "")
            let type: String
            var extra: [String: Any] = [:]
            if let heading = line.firstRange(of: /^#{2,6}\s+/) {
                type = "heading_3"; line = String(line[heading.upperBound...])
            } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                type = "to_do"; extra["checked"] = line.hasPrefix("- [x] ")
                line = String(line.dropFirst(6))
            } else if line.hasPrefix("- ") {
                type = "bulleted_list_item"; line = String(line.dropFirst(2))
            } else {
                type = "paragraph"
            }
            var content = extra
            content["rich_text"] = chunks(line).map { ["type": "text", "text": ["content": $0]] }
            blocks.append(["object": "block", "type": type, type: content])
        }
        return blocks
    }

    private static func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            result.append(String(rest.prefix(notionTextLimit)))
            rest = rest.dropFirst(notionTextLimit)
        }
        return result
    }
}
