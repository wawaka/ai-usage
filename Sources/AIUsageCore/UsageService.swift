import Foundation

/// Combines locally discovered credentials with accounts added in AI Usage, polls them and
/// remembers the last snapshot of each account.
public actor UsageService {
    private let secrets: SecretStore
    private let discovery: LocalDiscovery
    private let client: HTTPClient
    private let stateStore: JSONFileStore<AccountsState>
    private let snapshotStore: JSONFileStore<[String: UsageSnapshot]>

    public private(set) var state: AccountsState
    private var lastSnapshots: [String: UsageSnapshot]
    private var discovered: [String: DiscoveredCredential] = [:]

    public private(set) var policy = PollPolicy()
    private var schedule: [String: PollState] = [:]

    static func fingerprint(_ token: String) -> String {
        SHA256.hash(Data(token.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public init(secrets: SecretStore, keychain: KeychainReading? = nil, client: HTTPClient = URLSessionHTTPClient(),
                home: URL = AppPaths.userHome, directory: URL = AppPaths.supportDirectory) {
        self.secrets = secrets
        self.client = client
        discovery = LocalDiscovery(home: home, keychain: keychain)
        stateStore = JSONFileStore("accounts.json", directory: directory)
        snapshotStore = JSONFileStore("snapshots.json", directory: directory)
        state = stateStore.load() ?? AccountsState()
        // Usage history from the removed pacing feature; it is AI Usage's own file.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("samples.json"))
        lastSnapshots = snapshotStore.load() ?? [:]
    }

    // MARK: Accounts

    /// Re-reads local credential sources (read-only) and returns every known account in display order.
    @discardableResult
    public func rescan() -> [Account] {
        discovered = Dictionary(discovery.discover().map { ($0.account.id, $0) }, uniquingKeysWith: { a, _ in a })
        return allAccounts()
    }

    public func allAccounts() -> [Account] {
        var list = discovered.values.map(\.account) + state.managed
        list = list.map { a in
            var a = a
            if let name = state.renamed[a.id] { a.label = name }
            return a
        }
        let rank = Dictionary(state.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return list.sorted { l, r in
            let lr = rank[l.id] ?? Int.max, rr = rank[r.id] ?? Int.max
            if lr != rr { return lr < rr }
            let lp = ProviderKind.titleOrder.firstIndex(of: l.provider)!, rp = ProviderKind.titleOrder.firstIndex(of: r.provider)!
            if lp != rp { return lp < rp }
            if l.isLocal != r.isLocal { return l.isLocal }
            return l.label < r.label
        }
    }

    public func visibleAccounts() -> [Account] { allAccounts().filter { !state.hidden.contains($0.id) } }

    public func isHidden(_ id: String) -> Bool { state.hidden.contains(id) }

    public func setHidden(_ id: String, _ hidden: Bool) {
        if hidden { state.hidden.insert(id) } else { state.hidden.remove(id) }
        stateStore.save(state)
    }

    public func setInMenuBar(_ id: String, _ shown: Bool) {
        if shown { state.notInMenuBar.remove(id) } else { state.notInMenuBar.insert(id) }
        stateStore.save(state)
    }

    public func rename(_ id: String, to name: String?) {
        state.renamed[id] = (name?.isEmpty ?? true) ? nil : name
        stateStore.save(state)
    }

    public func setOrder(_ ids: [String]) {
        state.order = ids
        stateStore.save(state)
    }

    /// Adds an account whose secret is owned by AI Usage.
    @discardableResult
    public func addManaged(provider: ProviderKind, label: String, credential: Credential) throws -> Account {
        let account = Account(id: "managed:\(provider.rawValue):\(UUID().uuidString.lowercased())", provider: provider, label: label, origin: .managed)
        try secrets.save(credential, for: account.id)
        state.managed.append(account)
        stateStore.save(state)
        return account
    }

    public func removeManaged(_ id: String) {
        secrets.delete(id)
        state.managed.removeAll { $0.id == id }
        state.renamed[id] = nil
        state.hidden.remove(id)
        lastSnapshots[id] = nil
        stateStore.save(state)
        snapshotStore.save(lastSnapshots)
    }

    // MARK: Schedule

    public func setPolicy(_ policy: PollPolicy) {
        self.policy = policy
        let latest = Date().addingTimeInterval(policy.maxInterval)
        for (id, var s) in schedule {
            s.interval = min(max(s.interval, policy.minInterval), policy.maxInterval)
            s.nextDue = min(s.nextDue, latest)
            schedule[id] = s
        }
    }

    /// Visible accounts whose next automatic update is due (never polled yet counts as due).
    public func dueAccounts(now: Date = Date()) -> [Account] {
        visibleAccounts().filter { a in schedule[a.id].map { $0.nextDue <= now } ?? true }
    }

    /// Makes every account due now (e.g. after the Mac wakes), without resetting their intervals.
    public func markAllDue(now: Date = Date()) {
        for id in schedule.keys { schedule[id]?.nextDue = now }
    }

    public func nextRefresh(_ id: String) -> Date? { schedule[id]?.nextDue }

    /// Updates the account's schedule after a poll: back to the minimum interval when the numbers
    /// changed, doubled (up to the maximum) when they didn't or the poll failed. A rate limit waits
    /// at least as long as the provider asked; refreshes are refused until then.
    private func reschedule(_ id: String, changed: Bool, rateLimited: Bool = false, retryAfter: TimeInterval? = nil,
                            snapshot: UsageSnapshot?, now: Date) {
        var s = schedule[id] ?? PollState(interval: policy.minInterval, nextDue: now)
        s.interval = changed ? policy.minInterval : min(max(s.interval * 2, policy.minInterval), policy.maxInterval)
        var wait = s.interval
        s.blockedUntil = nil
        if rateLimited {
            if let retryAfter { wait = max(wait, retryAfter) }
            s.blockedUntil = now.addingTimeInterval(retryAfter ?? PollPolicy.rateLimitCooldown)
        } else if let next = snapshot?.windows.compactMap(\.resetsAt).filter({ $0 > now }).min() {
            // Catch a window reset soon after it happens instead of up to `maxInterval` later.
            wait = min(wait, next.timeIntervalSince(now) + 30)
        }
        s.nextDue = now.addingTimeInterval(wait)
        schedule[id] = s
    }

    // MARK: Polling

    /// Last known statuses without hitting the network (for instant display at launch).
    public func cachedStatuses() -> [AccountStatus] {
        visibleAccounts().map { a in
            let snap = lastSnapshots[a.id]
            return AccountStatus(account: a, snapshot: snap, error: nil,
                                 analysis: snap.map(UsageAnalysis.of),
                                 lastAttempt: snap?.observedAt ?? .distantPast)
        }
    }

    public func refreshAll() async -> [AccountStatus] {
        rescan()
        let accounts = visibleAccounts()
        var results: [String: AccountStatus] = [:]
        await withTaskGroup(of: AccountStatus.self) { group in
            for account in accounts {
                group.addTask { await self.refresh(account) }
            }
            for await status in group { results[status.id] = status }
        }
        snapshotStore.save(lastSnapshots)
        return accounts.compactMap { results[$0.id] }
    }

    func credential(for account: Account) -> (Credential, tool: String?)? {
        if let d = discovered[account.id] { return (d.credential, d.tool) }
        return secrets.load(account.id).map { ($0, nil) }
    }

    /// Fetches one account (used by the app to update accounts individually as they finish) and
    /// schedules its next automatic update. While the provider's rate limit lasts, nothing is sent.
    public func refresh(_ account: Account, now: Date = Date()) async -> AccountStatus {
        let stale = lastSnapshots[account.id]
        if let until = schedule[account.id]?.blockedUntil, until > now {
            return failed(account, stale, Self.rateLimitMessage(until: schedule[account.id]?.nextDue ?? until))
        }
        do {
            let snapshot = try await fetch(account)
            reschedule(account.id, changed: snapshot.usageDiffers(from: stale), snapshot: snapshot, now: now)
            lastSnapshots[account.id] = snapshot
            snapshotStore.save(lastSnapshots)
            var status = AccountStatus(account: account, snapshot: snapshot, error: nil, analysis: .of(snapshot))
            status.nextRefresh = schedule[account.id]?.nextDue
            return status
        } catch UsageError.rateLimited(let retryAfter) {
            reschedule(account.id, changed: false, rateLimited: true, retryAfter: retryAfter, snapshot: stale, now: now)
            return failed(account, stale, Self.rateLimitMessage(until: schedule[account.id]!.nextDue))
        } catch {
            reschedule(account.id, changed: false, snapshot: stale, now: now)
            return failed(account, stale, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    static func rateLimitMessage(until: Date) -> String {
        "Rate limited by the provider. Next try at \(Format.clock(until))."
    }

    /// Keeps showing the last good numbers, flagged with the error.
    private func failed(_ account: Account, _ stale: UsageSnapshot?, _ message: String) -> AccountStatus {
        var status = AccountStatus(account: account, snapshot: stale, error: message,
                                   analysis: UsageAnalysis(state: .unavailable, message: message))
        status.nextRefresh = schedule[account.id]?.nextDue
        return status
    }

    private func fetch(_ account: Account) async throws -> UsageSnapshot {
        guard var (credential, tool) = credential(for: account) else {
            throw UsageError.missingCredential("No credentials for \(account.label)")
        }
        // Claude Code rotates its Keychain token; re-read it only once our cached copy has expired,
        // so macOS asks for Keychain access rarely instead of on every poll.
        let keychainPrefix = "local:claude-code:keychain:"
        // An expired token is re-read only once (persisted as a hash): if the owning tool isn't running,
        // its item holds the same expired token, and asking again would only repeat the prompt.
        if case .oauth(let t) = credential, t.isExpired(), account.id.hasPrefix(keychainPrefix),
           state.recheckedExpiredTokens.insert(Self.fingerprint(t.accessToken)).inserted {
            if state.recheckedExpiredTokens.count > 50 { state.recheckedExpiredTokens = [Self.fingerprint(t.accessToken)] }
            stateStore.save(state)
            discovery.keychain?.invalidate(service: String(account.id.dropFirst(keychainPrefix.count)))
            rescan()
            if let fresh = self.credential(for: account) { (credential, tool) = fresh }
        }
        if account.isLocal {
            // Read-only: a token borrowed from another tool is used as-is and never refreshed,
            // since refreshing would rotate that tool's refresh token and log it out.
            if case .oauth(let t) = credential, t.isExpired() {
                throw UsageError.expiredLocalToken(tool ?? "the owning tool")
            }
            do {
                return try await UsageFetcher.fetch(account.provider, credential: credential, client: client)
            } catch UsageError.unauthorized {
                throw UsageError.expiredLocalToken(tool ?? "the owning tool")
            }
        }
        guard case .oauth(var token) = credential, let oauth = OAuthProviders.forProvider(account.provider) else {
            return try await UsageFetcher.fetch(account.provider, credential: credential, client: client)
        }
        if token.isExpired() {
            token = try await oauth.refresh(token, client: client)
            try secrets.save(.oauth(token), for: account.id)
        }
        do {
            return try await UsageFetcher.fetch(account.provider, credential: .oauth(token), client: client)
        } catch UsageError.unauthorized {
            token = try await oauth.refresh(token, client: client)
            try secrets.save(.oauth(token), for: account.id)
            return try await UsageFetcher.fetch(account.provider, credential: .oauth(token), client: client)
        }
    }
}

/// Bounds for adaptive polling: each account starts at `minInterval`; every poll that returns the
/// same numbers (or fails) doubles its interval up to `maxInterval`; a change resets it.
public struct PollPolicy: Sendable, Equatable {
    public var minInterval: TimeInterval
    public var maxInterval: TimeInterval
    /// After a 429 without `Retry-After`, refreshes (manual ones too) are refused for this long.
    public static let rateLimitCooldown: TimeInterval = 120

    public init(minInterval: TimeInterval = 120, maxInterval: TimeInterval = 1800) {
        self.minInterval = max(30, minInterval)
        self.maxInterval = max(self.minInterval, maxInterval)
    }
}

struct PollState {
    var interval: TimeInterval
    var nextDue: Date
    var blockedUntil: Date?
}
