import Foundation
import Security

/// Bağlantı anahtarlarının deposu. **Yalnızca Keychain** (kural 8):
/// `UserDefaults`'a, veritabanına ve loga anahtar yazılmaz.
nonisolated protocol SecretStoring: Sendable {
    func secret(for kind: ConnectionKind) -> String?
    func setSecret(_ value: String?, for kind: ConnectionKind) throws
}

/// macOS Keychain'de genel parola öğeleri. Ad-hoc imzalı geliştirme
/// derlemelerinde imza her derlemede değiştiği için sistem erişim onayını
/// yeniden sorabilir (RESEARCH.md §20'deki TCC davranışının aynısı).
nonisolated struct KeychainSecrets: SecretStoring {

    static let service = "com.orameetings.ora.connections"

    func secret(for kind: ConnectionKind) -> String? {
        var query = baseQuery(kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    func setSecret(_ value: String?, for kind: ConnectionKind) throws {
        let query = baseQuery(kind)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw OraError.connectionFailed(reason: "Anahtar Keychain'den silinemedi (\(status)).")
            }
            return
        }
        let data = Data(trimmed.utf8)
        var status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw OraError.connectionFailed(reason: "Anahtar Keychain'e yazılamadı (\(status)).")
        }
    }

    private func baseQuery(_ kind: ConnectionKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: kind.rawValue]
    }
}
