#if os(macOS)
import Foundation
import Security

/// Reads other tools' Keychain items (Claude Code). Never adds, updates or deletes them.
/// Secrets are cached in memory so macOS shows its access prompt as rarely as possible;
/// answering "Allow" (not "Always Allow") leaves the item's access list untouched.
public final class SystemKeychainReader: KeychainReading, @unchecked Sendable {
    private var cache: [String: Data] = [:]
    private var isEnabled = true
    private let lock = NSLock()

    public init() {}

    /// When disabled, other tools' Keychain items are neither listed nor read.
    public var enabled: Bool {
        get { lock.withLock { isEnabled } }
        set { lock.withLock { isEnabled = newValue; if !newValue { cache.removeAll() } } }
    }

    public func items(servicePrefix: String) -> [(service: String, account: String)] {
        guard enabled else { return [] }
        // Attribute-only query: does not touch secret data, so no access prompt.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let service = row[kSecAttrService as String] as? String, service.hasPrefix(servicePrefix) else { return nil }
            return (service, row[kSecAttrAccount as String] as? String ?? "")
        }
    }

    public func data(service: String, account: String) -> Data? {
        guard enabled else { return nil }
        if let cached = lock.withLock({ cache[service + "\u{0}" + account] }) { return cached }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if !account.isEmpty { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        lock.withLock { cache[service + "\u{0}" + account] = data }
        return data
    }

    public func invalidate(service: String) {
        lock.withLock { cache = cache.filter { !$0.key.hasPrefix(service + "\u{0}") } }
    }
}

/// AI Usage's own secrets, stored as generic passwords under its own service name.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    public static let service = "dev.ai-usage.accounts"

    public init() {}

    private func base(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: id]
    }

    public func load(_ accountID: String) -> Credential? {
        var query = base(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credential.self, from: data)
    }

    public func save(_ credential: Credential, for accountID: String) throws {
        let data = try JSONEncoder().encode(credential)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(base(accountID) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(accountID)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "AI Usage account"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw UsageError.other("Keychain write failed (\(status))") }
    }

    public func delete(_ accountID: String) {
        SecItemDelete(base(accountID) as CFDictionary)
    }
}
#endif
