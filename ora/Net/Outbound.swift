import Foundation

/// HTTP taşıyıcısı. Testte sahtelenir; gerçeği `URLSessionTransport`.
nonisolated protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// **Uygulamada `URLSession` geçen tek tip** (Bağlantı Kuralları §7).
/// `oraTests/OutboundTests` kaynak ağacını tarayıp bunu denetler.
nonisolated struct URLSessionTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// Ağa çıkan **tek kapı**. Her istek önce izin politikasından geçer
/// (bağlantı kurulu mu, onay verildi mi, toplantı kilitli mi), sonra gider
/// ve künyesi günlüğe yazılır. Kapıyı atlayan bir istek yolu yoktur.
nonisolated struct Outbound: Sendable {

    /// nil: izin var. Değilse kullanıcıya gösterilecek Türkçe neden.
    typealias Policy = @Sendable (ConnectionKind, OutboundPurpose, Int64?) async -> String?

    let transport: any HTTPTransport
    let log: OutboundLog
    let policy: Policy

    func send(_ request: URLRequest, connection: ConnectionKind, purpose: OutboundPurpose,
              meetingID: Int64?, characters: Int) async throws -> Data {
        if let denial = await policy(connection, purpose, meetingID) {
            throw OraError.connectionFailed(reason: denial)
        }
        var record = OutboundRecord(date: .now, connection: connection, purpose: purpose,
                                    meetingID: meetingID, characters: characters, status: nil)
        do {
            let (data, response) = try await transport.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            record.status = status
            log.append(record)
            guard (200 ..< 300).contains(status) else {
                throw OraError.connectionFailed(
                    reason: Self.message(status: status, connection: connection, body: data))
            }
            return data
        } catch let error as OraError {
            throw error
        } catch {
            log.append(record)
            throw OraError.connectionFailed(
                reason: "\(connection.displayName) hizmetine ulaşılamadı: "
                    + error.localizedDescription)
        }
    }

    /// HTTP durumundan Türkçe açıklama. Sağlayıcının kendi hata metni
    /// varsa sona eklenir — anahtar içermez, kullanıcıya yardımcı olur.
    static func message(status: Int, connection: ConnectionKind, body: Data) -> String {
        let name = connection.displayName
        let base: String = switch status {
        case 400:       "\(name) isteği geçersiz buldu."
        case 401, 403:  "\(name) anahtarı reddetti. Ayarlar → Bağlantılar'dan anahtarı kontrol edin."
        case 404:       "\(name) adresi ya da modeli bulamadı."
        case 413:       "Metin \(name) için fazla uzun."
        case 429:       "\(name) istek sınırına ulaşıldı; biraz sonra yeniden deneyin."
        case 500 ..< 600, 529: "\(name) şu an yanıt veremiyor (\(status))."
        default:        "\(name) beklenmedik bir yanıt verdi (\(status))."
        }
        guard let detail = providerMessage(body), !detail.isEmpty else { return base }
        return base + " (" + String(detail.prefix(200)) + ")"
    }

    /// Anthropic `{"error":{"message":…}}`, OpenAI `{"error":{"message":…}}`,
    /// Notion `{"message":…}` biçimleri.
    private static func providerMessage(_ body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return json["message"] as? String
    }
}
