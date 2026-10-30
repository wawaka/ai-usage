#if os(macOS)
import Foundation
import Security

/// Reads other tools' Keychain items (Claude Code). Never adds, updates or deletes them.
///
/// To ask for access as rarely as possible:
/// - a secret read once is copied into AI Usage's *own* Keychain item (readable without a prompt),
///   so relaunches don't ask again; the other tool's item is read again only after `invalidate`
///   (i.e. when the copied token has expired);
/// - a denied prompt is remembered and not repeated until `resetDenials()` (Settings / Accounts).
/// Answering "Allow" (not "Always Allow") leaves the other tool's item and its access list untouched.
public final class SystemKeychainReader: KeychainReading, @unchecked Sendable {
    static let cacheService = "dev.ai-usage.borrowed"
    static let deniedKey = "keychainDeniedServices"

    private var cache: [String: Data] = [:]
    private var isEnabled = true
    private let lock = NSLock()
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// When disabled, other tools' Keychain items are neither listed nor read.
    public var enabled: Bool {
        get { lock.withLock { isEnabled } }
        set { lock.withLock { isEnabled = newValue; if !newValue { cache.removeAll() } } }
    }

    /// Services whose access prompt was denied; they are skipped until `resetDenials()`.
    public var deniedServices: Set<String> {
        Set(defaults.stringArray(forKey: Self.deniedKey) ?? [])
    }

    public func resetDenials() {
        defaults.removeObject(forKey: Self.deniedKey)
    }

    private func markDenied(_ service: String) {
        defaults.set(Array(deniedServices.union([service])).sorted(), forKey: Self.deniedKey)
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
        let denied = deniedServices
        return rows.compactMap { row in
            guard let service = row[kSecAttrService as String] as? String, service.hasPrefix(servicePrefix),
                  !denied.contains(service) else { return nil }
            return (service, row[kSecAttrAccount as String] as? String ?? "")
        }
    }

    public func data(service: String, account: String) -> Data? {
        guard enabled, !deniedServices.contains(service) else { return nil }
        let key = service + "\u{0}" + account
        if let cached = lock.withLock({ cache[key] }) { return cached }
        if let copied = readOwnCopy(key) {
            lock.withLock { cache[key] = copied }
            return copied
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if !account.isEmpty { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            // "Deny" in the access prompt (or no way to show one): don't ask again.
            if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                markDenied(service)
            }
            return nil
        }
        lock.withLock { cache[key] = data }
        writeOwnCopy(key, data)
        return data
    }

    public func invalidate(service: String) {
        let prefix = service + "\u{0}"
        let keys = lock.withLock { () -> [String] in
            let k = cache.keys.filter { $0.hasPrefix(prefix) }
            k.forEach { cache[$0] = nil }
            return k
        }
        for key in keys { deleteOwnCopy(key) }
        // Copies left over from a previous launch (not in the memory cache yet).
        deleteOwnCopies(prefix: prefix)
    }

    // MARK: AI Usage's own copy (its own Keychain item, created by this app → no prompt to read)

    private func ownQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.cacheService,
         kSecAttrAccount as String: key]
    }

    private func readOwnCopy(_ key: String) -> Data? {
        var q = ownQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func writeOwnCopy(_ key: String, _ data: Data) {
        if SecItemUpdate(ownQuery(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = ownQuery(key)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "AI Usage (copy of a token read from another app)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func deleteOwnCopy(_ key: String) {
        SecItemDelete(ownQuery(key) as CFDictionary)
    }

    private func deleteOwnCopies(prefix: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: Self.cacheService,
                                kSecMatchLimit as String: kSecMatchLimitAll,
                                kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let rows = result as? [[String: Any]] else { return }
        for row in rows {
            if let account = row[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) { deleteOwnCopy(account) }
        }
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
