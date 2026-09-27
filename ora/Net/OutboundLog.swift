import Foundation

/// Giden bir isteğin künyesi. **İçerik yoktur** (kural 5): sağlayıcı, amaç,
/// toplantı ve karakter sayısı — kullanıcı neyin ne zaman çıktığını görsün.
nonisolated struct OutboundRecord: Codable, Sendable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var connection: ConnectionKind
    var purpose: OutboundPurpose
    var meetingID: Int64?
    var characters: Int
    /// HTTP durum kodu; istek hiç gidemediyse nil.
    var status: Int?

    var succeeded: Bool { (200 ..< 300).contains(status ?? 0) }
}

/// Künyeler `{base}/logs/outbound.jsonl` dosyasına satır satır eklenir ve
/// `ora.log`'a da düşer. Ayarlar → Bağlantılar son kayıtları gösterir.
nonisolated final class OutboundLog: @unchecked Sendable {

    static let standard = OutboundLog(
        url: AppPaths.logs.appending(path: "outbound.jsonl", directoryHint: .notDirectory))

    let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func append(_ record: OutboundRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        lock.withLock {
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
        Log.info(.net, "\(record.connection.displayName) · \(record.purpose.rawValue) · "
                 + "toplantı \(record.meetingID.map(String.init) ?? "-") · "
                 + "\(record.characters) karakter · "
                 + (record.status.map { "HTTP \($0)" } ?? "gönderilemedi"))
    }

    /// En yeniden eskiye.
    func recent(limit: Int = 50) -> [OutboundRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = lock.withLock { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        return text.split(separator: "\n").suffix(limit).reversed().compactMap {
            try? decoder.decode(OutboundRecord.self, from: Data($0.utf8))
        }
    }
}
