import Foundation
import Security

/// Stores the optional bearer token in the Keychain. The backend is default-open (no token needed)
/// until `API_TOKENS` is configured; once it is, every guarded request must carry the token.
struct KeychainTokenStore {
    let service: String
    let account: String

    init(service: String = "com.splitback.app", account: String = "api-bearer-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Saves (or replaces) the token. Passing nil/empty clears it.
    func save(_ token: String?) {
        guard let token, !token.isEmpty, let data = token.data(using: .utf8) else {
            delete()
            return
        }
        var query = baseQuery
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
