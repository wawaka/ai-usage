import Foundation

/// Where AI Usage keeps its own state. Nothing outside this directory (and AI Usage's own
/// Keychain items on macOS) is ever written.
public enum AppPaths {
    /// $HOME when set (Linux ignores it in `homeDirectoryForCurrentUser`), else the account home.
    public static var userHome: URL {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AI_USAGE_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ai-usage", isDirectory: true)
        #else
        return userHome.appendingPathComponent(".config/ai-usage", isDirectory: true)
        #endif
    }
}

/// Secrets for accounts added inside AI Usage.
public protocol SecretStore: Sendable {
    func load(_ accountID: String) -> Credential?
    func save(_ credential: Credential, for accountID: String) throws
    func delete(_ accountID: String)
}

/// 0600 JSON file store; used by the CLI and on non-macOS hosts.
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL = AppPaths.supportDirectory.appendingPathComponent("secrets.json")) { self.url = url }

    private func readAll() -> [String: Credential] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Credential].self, from: data)) ?? [:]
    }

    private func writeAll(_ all: [String: Credential]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(all)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func load(_ accountID: String) -> Credential? { lock.withLock { readAll()[accountID] } }

    public func save(_ credential: Credential, for accountID: String) throws {
        try lock.withLock {
            var all = readAll()
            all[accountID] = credential
            try writeAll(all)
        }
    }

    public func delete(_ accountID: String) {
        lock.withLock {
            var all = readAll()
            all[accountID] = nil
            try? writeAll(all)
        }
    }
}

/// Small JSON-file persistence for non-secret state.
public final class JSONFileStore<Value: Codable>: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(_ name: String, directory: URL = AppPaths.supportDirectory) {
        url = directory.appendingPathComponent(name)
    }

    public func load() -> Value? {
        lock.withLock {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try? decoder.decode(Value.self, from: data)
        }
    }

    public func save(_ value: Value) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
        }
    }
}

/// User preferences about accounts (both local and managed).
public struct AccountsState: Codable, Sendable {
    /// Accounts added in AI Usage (secrets live in the SecretStore).
    public var managed: [Account] = []
    /// IDs of accounts hidden from the menu bar/panel.
    public var hidden: Set<String> = []
    /// IDs of accounts listed in the panel but left out of the menu bar title.
    public var notInMenuBar: Set<String> = []
    /// Custom display names.
    public var renamed: [String: String] = [:]
    /// Display order (account IDs); unknown accounts go last.
    public var order: [String] = []
    /// SHA-256 prefixes of expired borrowed tokens already re-read once from the Keychain.
    public var recheckedExpiredTokens: Set<String> = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        managed = try c.decodeIfPresent([Account].self, forKey: .managed) ?? []
        hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        notInMenuBar = try c.decodeIfPresent(Set<String>.self, forKey: .notInMenuBar) ?? []
        renamed = try c.decodeIfPresent([String: String].self, forKey: .renamed) ?? [:]
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        recheckedExpiredTokens = try c.decodeIfPresent(Set<String>.self, forKey: .recheckedExpiredTokens) ?? []
    }
}
