import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches usage for one provider with a ready-to-use credential. Never refreshes tokens.
public enum UsageFetcher {
    public static func fetch(_ provider: ProviderKind, credential: Credential, client: HTTPClient) async throws -> UsageSnapshot {
        switch (provider, credential) {
        case (.claude, .oauth(let t)): return try await Claude.fetch(token: t, client: client)
        case (.codex, .oauth(let t)): return try await Codex.fetch(token: t, client: client)
        case (.glm, .apiKey(let k)): return try await GLM.fetch(key: k, client: client)
        case (.deepseek, .apiKey(let k)): return try await DeepSeek.fetch(key: k, client: client)
        case (.minimax, .apiKey(let k)): return try await MiniMax.fetch(key: k, client: client)
        case (.kimi, .apiKey(let k)): return try await Kimi.fetch(key: k, client: client)
        default: throw UsageError.missingCredential("Unsupported credential type for \(provider.displayName)")
        }
    }
}

// MARK: - Claude (subscription OAuth)

public enum Claude {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    static func headers(_ token: OAuthToken) -> [String: String] {
        ["Authorization": "Bearer \(token.accessToken)", "anthropic-beta": "oauth-2025-04-20"]
    }

    /// The usage endpoint with saved resets (`cedar_ember`) opted in.
    static let usageWithResetsURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")!

    public static func fetch(token: OAuthToken, client: HTTPClient) async throws -> UsageSnapshot {
        let obj: [String: Any]
        do {
            obj = try await HTTP.json(client, HTTP.request(usageWithResetsURL, headers: headers(token)))
        } catch UsageError.http(400, _) {
            // The opt-in is undocumented; never let it cost the usage numbers.
            obj = try await HTTP.json(client, HTTP.request(usageURL, headers: headers(token)))
        }
        var snapshot = try parse(obj)
        snapshot.plan = token.plan
        return snapshot
    }

    /// Saved resets from `cedar_ember`: the resets left in grants that are live now (not paused,
    /// started, not ended), and the soonest end among them. Nil when the block is absent or the
    /// account isn't eligible (the server then lists no grants).
    static func resetCredits(_ obj: [String: Any], now: Date) -> ResetCredits? {
        guard let block = dict(obj["cedar_ember"]), block["eligible"] as? Bool != false,
              let grants = block["grants"] as? [[String: Any]] else { return nil }
        let live = grants.filter { g in
            guard (g["paused"] as? Bool) != true, (number(g["resets_left"]) ?? 0) > 0 else { return false }
            if let start = parseISODate(g["starts_at"]), start > now { return false }
            if let end = parseISODate(g["ends_at"]), end <= now { return false }
            return true
        }
        let count = live.reduce(0) { $0 + Int(number($1["resets_left"]) ?? 0) }
        return ResetCredits(available: count, nextExpiresAt: live.compactMap { parseISODate($0["ends_at"]) }.min())
    }

    /// Plan id for `Format.planLabel`: "max_5x" / "max_20x" from the rate-limit tier, else the subscription
    /// type ("pro", "max", "team", "claude_max"…).
    public static func planName(subscription: String?, tier: String?) -> String? {
        if let tier, let m = tier.lowercased().range(of: #"max_\d+x"#, options: .regularExpression) {
            return String(tier.lowercased()[m])
        }
        guard let subscription, !subscription.isEmpty else { return nil }
        return subscription.lowercased()
    }

    public static func parse(_ obj: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        func window(_ key: String, _ kind: WindowKind, _ label: String?, _ minutes: Int) -> UsageWindow? {
            guard let w = dict(obj[key]), let pct = number(w["utilization"]) else { return nil }
            return UsageWindow(kind: kind, label: label, usedPercent: pct, resetsAt: parseISODate(w["resets_at"]), windowMinutes: minutes)
        }
        let windows = [window("five_hour", .fiveHour, nil, 300), window("seven_day", .sevenDay, nil, 10080)].compactMap { $0 }
        guard !windows.isEmpty else { throw UsageError.decoding("no five_hour/seven_day in Claude usage") }
        let extras = [
            window("seven_day_opus", .other, "7d Opus", 10080),
            window("seven_day_sonnet", .other, "7d Sonnet", 10080),
        ].compactMap { $0 }
        return UsageSnapshot(windows: windows, extraWindows: extras, resetCredits: resetCredits(obj, now: now), observedAt: now)
    }

    /// Email and plan for a freshly logged-in account.
    public static func profile(token: OAuthToken, client: HTTPClient) async -> (email: String?, plan: String?) {
        guard let obj = try? await HTTP.json(client, HTTP.request(profileURL, headers: headers(token))) else { return (nil, nil) }
        let account = dict(obj["account"])
        let email = string(account?["email"]) ?? string(account?["email_address"])
        let org = dict(obj["organization"])
        return (email, planName(subscription: string(org?["organization_type"]), tier: string(org?["rate_limit_tier"])))
    }
}

// MARK: - Codex (ChatGPT OAuth)

public enum Codex {
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func headers(_ token: OAuthToken) -> [String: String] {
        var headers = ["Authorization": "Bearer \(token.accessToken)"]
        if let id = token.accountId ?? accountId(fromJWT: token.idToken ?? token.accessToken) {
            headers["ChatGPT-Account-Id"] = id
        }
        return headers
    }

    public static func fetch(token: OAuthToken, client: HTTPClient) async throws -> UsageSnapshot {
        try parse(try await HTTP.json(client, HTTP.request(usageURL, headers: headers(token))))
    }

    public static func parse(_ obj: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        let rl = dict(obj["rate_limit"]) ?? [:]
        var windows: [UsageWindow] = []
        var extras: [UsageWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = dict(rl[key]), let pct = number(w["used_percent"]) else { continue }
            let secs = Int(number(w["limit_window_seconds"]) ?? 0)
            var reset = parseEpoch(w["reset_at"])
            if reset == nil, let after = number(w["reset_after_seconds"]) { reset = now.addingTimeInterval(after) }
            // Classify by window length rather than trusting primary/secondary order.
            if secs > 0 && secs <= 6 * 3600 {
                windows.append(UsageWindow(kind: .fiveHour, usedPercent: pct, resetsAt: reset, windowMinutes: secs / 60))
            } else if secs >= 6 * 86400 && secs <= 8 * 86400 {
                windows.append(UsageWindow(kind: .sevenDay, usedPercent: pct, resetsAt: reset, windowMinutes: secs / 60))
            } else {
                let label = secs >= 86400 ? "\(secs / 86400)d" : secs > 0 ? "\(secs / 3600)h" : "?"
                extras.append(UsageWindow(kind: .other, label: label, usedPercent: pct, resetsAt: reset, windowMinutes: secs / 60))
            }
        }
        guard !windows.isEmpty || !extras.isEmpty else { throw UsageError.decoding("no rate_limit windows in Codex usage") }
        let credits = number(dict(obj["rate_limit_reset_credits"])?["available_count"]).map { ResetCredits(available: Int($0)) }
        return UsageSnapshot(windows: windows, extraWindows: extras, plan: string(obj["plan_type"]), resetCredits: credits, observedAt: now)
    }

    public static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    /// The soonest expiry among available saved resets. Only this separate endpoint lists them;
    /// it's rate limited hard, so `UsageService` asks rarely.
    public static func nextResetCreditExpiry(token: OAuthToken, client: HTTPClient) async throws -> Date? {
        nextResetCreditExpiry(try await HTTP.json(client, HTTP.request(resetCreditsURL, headers: headers(token))))
    }

    static func nextResetCreditExpiry(_ obj: [String: Any]) -> Date? {
        (obj["credits"] as? [[String: Any]] ?? [])
            .filter { string($0["status"]) == "available" }
            .compactMap { parseISODate($0["expires_at"]) }
            .min()
    }

    public static func accountId(fromJWT jwt: String) -> String? {
        string(dict(JWT.claims(jwt)["https://api.openai.com/auth"])?["chatgpt_account_id"])
    }

    public static func email(fromJWT jwt: String) -> String? {
        let claims = JWT.claims(jwt)
        return string(claims["email"]) ?? string(dict(claims["https://api.openai.com/profile"])?["email"])
    }
}

// MARK: - GLM (Zhipu / Z.ai Coding Plan)

public enum GLM {
    public static let defaultBaseURL = "https://open.bigmodel.cn"
    public static let internationalBaseURL = "https://api.z.ai"

    public static func fetch(key: APIKeyCredential, client: HTTPClient) async throws -> UsageSnapshot {
        let base = (key.baseURL ?? defaultBaseURL).trimmingSuffix("/")
        guard let url = URL(string: "\(base)/api/monitor/usage/quota/limit") else { throw UsageError.other("Bad GLM base URL") }
        let obj = try await HTTP.json(client, HTTP.request(url, headers: ["Authorization": "Bearer \(key.key)"]))
        return try parse(obj)
    }

    public static func parse(_ obj: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        // 1302/1303: too many concurrent / too frequent requests.
        if let code = number(obj["code"]), code == 1302 || code == 1303 { throw UsageError.rateLimited(retryAfter: nil) }
        guard (obj["success"] as? Bool) != false, let data = dict(obj["data"]),
              let limits = data["limits"] as? [[String: Any]] else {
            throw UsageError.decoding(string(obj["msg"]) ?? "GLM quota response missing data")
        }
        // Newer plans report CREDIT_LIMIT instead of TOKENS_LIMIT with the same window shapes.
        for type in ["TOKENS_LIMIT", "CREDIT_LIMIT"] {
            let ofType = limits.filter { string($0["type"]) == type }
            // Match windows by shape (unit 3 × 5 = 5h, unit 6 × 1 = weekly), falling back to reset order.
            var fiveIdx = ofType.firstIndex { number($0["unit"]) == 3 && number($0["number"]) == 5 }
            var sevenIdx = ofType.firstIndex { number($0["unit"]) == 6 && number($0["number"]) == 1 }
            var rest = ofType.indices.filter { $0 != fiveIdx && $0 != sevenIdx }
                .sorted { (number(ofType[$0]["nextResetTime"]) ?? 0) < (number(ofType[$1]["nextResetTime"]) ?? 0) }
            if fiveIdx == nil, !rest.isEmpty { fiveIdx = rest.removeFirst() }
            if sevenIdx == nil, !rest.isEmpty { sevenIdx = rest.removeFirst() }
            guard let fiveIdx, let sevenIdx else { continue }
            let five = ofType[fiveIdx], seven = ofType[sevenIdx]
            // A fresh, unused window omits nextResetTime.
            let windows = [
                UsageWindow(kind: .fiveHour, usedPercent: number(five["percentage"]) ?? 0, resetsAt: parseEpoch(five["nextResetTime"]), windowMinutes: 300),
                UsageWindow(kind: .sevenDay, usedPercent: number(seven["percentage"]) ?? 0, resetsAt: parseEpoch(seven["nextResetTime"]), windowMinutes: 10080),
            ]
            var plan = string(data["level"])
            if type == "CREDIT_LIMIT" { plan = [plan, "credits"].compactMap { $0 }.joined(separator: " · ") }
            return UsageSnapshot(windows: windows, plan: plan, observedAt: now)
        }
        throw UsageError.decoding("GLM quota response did not contain token/credit windows")
    }
}

// MARK: - DeepSeek (balance only)

public enum DeepSeek {
    public static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    public static func fetch(key: APIKeyCredential, client: HTTPClient) async throws -> UsageSnapshot {
        let obj = try await HTTP.json(client, HTTP.request(balanceURL, headers: ["Authorization": "Bearer \(key.key)"]))
        return try parse(obj)
    }

    public static func parse(_ obj: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        guard let info = (obj["balance_infos"] as? [[String: Any]])?.first else {
            throw UsageError.decoding("DeepSeek balance response missing balance_infos")
        }
        let balance = Balance(total: string(info["total_balance"]) ?? "0",
                              currency: string(info["currency"]) ?? "CNY",
                              isAvailable: (obj["is_available"] as? Bool) ?? true)
        return UsageSnapshot(windows: [], balance: balance, plan: "Pay-as-you-go", observedAt: now)
    }
}

// MARK: - MiniMax (token plan)

public enum MiniMax {
    public static let cnBaseURL = "https://api.minimaxi.com"
    public static let globalBaseURL = "https://api.minimax.io"

    public static func fetch(key: APIKeyCredential, client: HTTPClient) async throws -> UsageSnapshot {
        let base = key.baseURL ?? (key.region == "global" ? globalBaseURL : cnBaseURL)
        guard let url = URL(string: "\(base.trimmingSuffix("/"))/v1/token_plan/remains") else { throw UsageError.other("Bad MiniMax base URL") }
        let obj = try await HTTP.json(client, HTTP.request(url, headers: ["Authorization": "Bearer \(key.key)"]))
        if let code = number(dict(obj["base_resp"])?["status_code"]), code != 0 {
            let msg = string(dict(obj["base_resp"])?["status_msg"]) ?? "unknown error"
            if code == 1004 { throw UsageError.unauthorized(msg) }
            if code == 1002 { throw UsageError.rateLimited(retryAfter: nil) }
            throw UsageError.other("MiniMax API error: \(msg) (code \(Int(code)))")
        }
        return try parse(obj)
    }

    /// Count ratio when total > 0, otherwise 100 - remaining_percent.
    static func percent(total: Any?, used: Any?, remainingPercent: Any?) -> Double? {
        if let t = number(total), t > 0, let u = number(used) { return min(100, max(0, u / t * 100)) }
        if let r = number(remainingPercent) { return min(100, max(0, 100 - r)) }
        return nil
    }

    public static func parse(_ obj: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        guard let models = obj["model_remains"] as? [[String: Any]], !models.isEmpty else {
            throw UsageError.decoding("MiniMax response missing model_remains")
        }
        let primary = models.first { string($0["model_name"]) == "general" } ?? models[0]
        let categories = obj["category_remains"] as? [[String: Any]] ?? []
        let src = categories.first { string($0["category"]) == "text_generation" } ?? primary
        let five = percent(total: src["current_interval_total_count"], used: src["current_interval_usage_count"],
                           remainingPercent: src["current_interval_remaining_percent"]) ?? 0
        let week = percent(total: src["current_weekly_total_count"], used: src["current_weekly_usage_count"],
                           remainingPercent: src["current_weekly_remaining_percent"]) ?? five
        return UsageSnapshot(windows: [
            UsageWindow(kind: .fiveHour, usedPercent: five, resetsAt: parseEpoch(src["end_time"]), windowMinutes: 300),
            UsageWindow(kind: .sevenDay, usedPercent: week, resetsAt: parseEpoch(src["weekly_end_time"]), windowMinutes: 10080),
        ], plan: string(primary["model_name"]), observedAt: now)
    }
}

// MARK: - Kimi (Moonshot coding plan)

public enum Kimi {
    public static let defaultBaseURL = "https://api.kimi.com/coding"

    public static func fetch(key: APIKeyCredential, client: HTTPClient) async throws -> UsageSnapshot {
        let base = (key.baseURL ?? defaultBaseURL).trimmingSuffix("/")
        guard let url = URL(string: "\(base)/v1/usages") else { throw UsageError.other("Bad Kimi base URL") }
        let obj = try await HTTP.json(client, HTTP.request(url, headers: ["Authorization": "Bearer \(key.key)"]))
        return try parse(obj)
    }

    /// used/limit, deriving missing fields (Kimi omits zero values entirely).
    static func percent(_ detail: [String: Any]) -> Double? {
        let limit = number(detail["limit"])
        var used = number(detail["used"])
        let remaining = number(detail["remaining"])
        if used == nil, let limit, let remaining { used = max(0, limit - remaining) }
        if let limit, limit > 0, let used { return min(100, max(0, used / limit * 100)) }
        if let used, let remaining, used + remaining > 0 { return min(100, max(0, used / (used + remaining) * 100)) }
        return nil
    }

    public static func parse(_ obj: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        let limits = (obj["limits"] as? [[String: Any]] ?? []).filter { number(dict($0["window"])?["duration"]) != nil }
        let short = limits.first {
            number(dict($0["window"])?["duration"]) == 300 && string(dict($0["window"])?["timeUnit"]) == "TIME_UNIT_MINUTE"
        } ?? limits.min { (number(dict($0["window"])?["duration"]) ?? .infinity) < (number(dict($1["window"])?["duration"]) ?? .infinity) }
        var windows: [UsageWindow] = []
        if let d = dict(short?["detail"]), let p = percent(d) {
            windows.append(UsageWindow(kind: .fiveHour, usedPercent: p, resetsAt: parseISODate(d["resetTime"]), windowMinutes: 300))
        }
        if let d = dict(obj["usage"]), let p = percent(d) {
            windows.append(UsageWindow(kind: .sevenDay, usedPercent: p, resetsAt: parseISODate(d["resetTime"]), windowMinutes: 10080))
        }
        guard !windows.isEmpty else { throw UsageError.decoding("Kimi usages response missing windows") }
        let plan = string(dict(dict(obj["user"])?["membership"])?["level"])
        return UsageSnapshot(windows: windows, plan: plan, observedAt: now)
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var s = self
        while s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s
    }
}
