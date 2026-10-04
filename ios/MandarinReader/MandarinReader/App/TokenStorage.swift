import Foundation
import Security

/// Persists the auth token (Keychain) and account email (UserDefaults —
/// not secret). Protocol so tests can use an in-memory store.
protocol TokenStorage {
    func save(token: String, email: String)
    func load() -> (token: String, email: String)?
    func clear()
}

struct KeychainTokenStorage: TokenStorage {
    private static let service = "com.mandarinreader.auth"
    private static let account = "authToken"
    private static let emailKey = "auth.email"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func save(token: String, email: String) {
        SecItemDelete(Self.baseQuery as CFDictionary)
        var insert = Self.baseQuery
        insert[kSecValueData as String] = Data(token.utf8)
        // Readable after first unlock (so background work can use it) and never
        // migrated to another device via backups.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
        UserDefaults.standard.set(email, forKey: Self.emailKey)
    }

    func load() -> (token: String, email: String)? {
        var query = Self.baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else { return nil }
        let email = UserDefaults.standard.string(forKey: Self.emailKey) ?? ""
        return (token, email)
    }

    func clear() {
        SecItemDelete(Self.baseQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
    }
}

final class InMemoryTokenStorage: TokenStorage {
    private var stored: (token: String, email: String)?

    init(token: String? = nil, email: String = "") {
        if let token { stored = (token, email) }
    }

    // Xcode 26 MainActor deinit back-deploy shim crashes libmalloc when
    // classes stored on a @MainActor owner (AuthStore) lack an explicit
    // nonisolated deinit.
    nonisolated deinit { }

    func save(token: String, email: String) { stored = (token, email) }
    func load() -> (token: String, email: String)? { stored }
    func clear() { stored = nil }
}
