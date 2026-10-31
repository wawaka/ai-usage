import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex, claude, glm, deepseek, minimax, kimi

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .glm: return "GLM"
        case .deepseek: return "DeepSeek"
        case .minimax: return "MiniMax"
        case .kimi: return "Kimi"
        }
    }

    /// Single glyph used in the provider mark.
    public var monogram: String {
        switch self {
        case .codex: return "X"
        case .claude: return "C"
        case .glm: return "Z"
        case .deepseek: return "D"
        case .minimax: return "M"
        case .kimi: return "K"
        }
    }

    /// Mark background colour (hex, no '#').
    public var markColorHex: String {
        switch self {
        case .codex: return "2F7CF6"
        case .claude: return "D97757"
        case .glm: return "1F1F1F"
        case .deepseek: return "4D6BFE"
        case .minimax: return "F2456E"
        case .kimi: return "111111"
        }
    }

    /// Accounts for these providers are added via browser OAuth; the rest take an API key.
    public var usesOAuth: Bool { self == .claude || self == .codex }

    /// Ordering in the menu bar title, same as the reference project.
    public static let titleOrder: [ProviderKind] = [.codex, .claude, .glm, .deepseek, .minimax, .kimi]
}

public enum WindowKind: String, Codable, Sendable {
    case fiveHour = "5h"
    case sevenDay = "7d"
    case other
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public var kind: WindowKind
    /// Short label shown in rows ("5h", "7d", "7d Opus"...).
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var windowMinutes: Int?

    public init(kind: WindowKind, label: String? = nil, usedPercent: Double, resetsAt: Date?, windowMinutes: Int? = nil) {
        self.kind = kind
        self.label = label ?? (kind == .other ? "?" : kind.rawValue)
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }

    /// Fraction (0…1) of this window's duration that has already passed, if its length and reset are known.
    public func elapsedFraction(now: Date = Date()) -> Double? {
        guard let resetsAt, let minutes = windowMinutes, minutes > 0 else { return nil }
        let left = resetsAt.timeIntervalSince(now) / (Double(minutes) * 60)
        return min(1, max(0, 1 - left))
    }

    /// What a meter shows: used% and elapsed time, or (inverted) remaining% and time left.
    /// Either way, a usage fill past the time fill means quota runs out before the window resets.
    public func display(remaining: Bool, now: Date = Date()) -> (percent: Double, time: Double?) {
        let elapsed = elapsedFraction(now: now)
        return remaining ? (100 - usedPercent, elapsed.map { 1 - $0 }) : (usedPercent, elapsed)
    }
}

public struct Balance: Codable, Equatable, Sendable {
    public var total: String
    public var currency: String
    public var isAvailable: Bool

    public var formatted: String {
        let symbol = currency == "CNY" ? "¥" : currency == "USD" ? "$" : "\(currency) "
        return "\(symbol)\(total)"
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var windows: [UsageWindow]
    public var extraWindows: [UsageWindow]
    public var balance: Balance?
    public var plan: String?
    public var observedAt: Date

    public init(windows: [UsageWindow], extraWindows: [UsageWindow] = [], balance: Balance? = nil, plan: String? = nil, observedAt: Date = Date()) {
        self.windows = windows
        self.extraWindows = extraWindows
        self.balance = balance
        self.plan = plan
        self.observedAt = observedAt
    }

    public var fiveHour: UsageWindow? { windows.first { $0.kind == .fiveHour } }

    /// Whether the numbers differ from `other` (ignoring when they were observed and small reset-time jitter).
    public func usageDiffers(from other: UsageSnapshot?) -> Bool {
        guard let other else { return true }
        func key(_ w: [UsageWindow]) -> [String] { w.map { "\($0.label)=\(($0.usedPercent * 10).rounded())" } }
        return key(windows) != key(other.windows) || key(extraWindows) != key(other.extraWindows) || balance != other.balance
    }
    public var sevenDay: UsageWindow? { windows.first { $0.kind == .sevenDay } }
}

/// A secret that lets us read usage for one account.
public enum Credential: Codable, Equatable, Sendable {
    case oauth(OAuthToken)
    case apiKey(APIKeyCredential)
}

public struct OAuthToken: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    /// ChatGPT account id (Codex) — sent as `ChatGPT-Account-Id`.
    public var accountId: String?
    public var idToken: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, accountId: String? = nil, idToken: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountId = accountId
        self.idToken = idToken
    }

    public func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < leeway
    }
}

public struct APIKeyCredential: Codable, Equatable, Sendable {
    public var key: String
    /// Optional override (GLM: open.bigmodel.cn vs api.z.ai; Kimi lanes).
    public var baseURL: String?
    /// MiniMax: "cn" (default) or "global".
    public var region: String?

    public init(key: String, baseURL: String? = nil, region: String? = nil) {
        self.key = key
        self.baseURL = baseURL
        self.region = region
    }
}

public enum AccountOrigin: Codable, Equatable, Sendable {
    /// Picked up read-only from another tool. `source` is a human-readable location.
    case local(source: String)
    /// Logged in / added inside AI Usage; secrets live in AI Usage's own store.
    case managed
}

public struct Account: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: ProviderKind
    /// Email or user-chosen name.
    public var label: String
    public var origin: AccountOrigin

    public init(id: String, provider: ProviderKind, label: String, origin: AccountOrigin) {
        self.id = id
        self.provider = provider
        self.label = label
        self.origin = origin
    }

    public var isLocal: Bool {
        if case .local = origin { return true }
        return false
    }

    public var sourceDescription: String {
        switch origin {
        case .local(let source): return source
        case .managed: return "AI Usage login"
        }
    }
}

public struct AccountStatus: Sendable, Identifiable {
    public var account: Account
    public var snapshot: UsageSnapshot?
    public var error: String?
    public var analysis: UsageAnalysis?
    public var lastAttempt: Date
    /// When the next automatic update of this account is due.
    public var nextRefresh: Date?

    public var id: String { account.id }

    public init(account: Account, snapshot: UsageSnapshot?, error: String?, analysis: UsageAnalysis?, lastAttempt: Date = Date()) {
        self.account = account
        self.snapshot = snapshot
        self.error = error
        self.analysis = analysis
        self.lastAttempt = lastAttempt
    }
}

public enum UsageError: Error, LocalizedError, Equatable {
    case unauthorized(String)
    case http(Int, String)
    case decoding(String)
    case expiredLocalToken(String)
    case missingCredential(String)
    /// HTTP 429 (or a provider's rate-limit error code); `retryAfter` from the `Retry-After` header.
    case rateLimited(retryAfter: TimeInterval?)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let m): return "Unauthorized: \(m)"
        case .http(let code, let m): return "HTTP \(code): \(m)"
        case .decoding(let m): return "Unexpected response: \(m)"
        case .expiredLocalToken(let tool): return "Token from \(tool) expired. Open \(tool) to renew it, or add an account in AI Usage."
        case .missingCredential(let m): return m
        case .rateLimited: return "Rate limited by the provider"
        case .other(let m): return m
        }
    }
}
