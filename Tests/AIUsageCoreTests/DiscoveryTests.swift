import XCTest
@testable import AIUsageCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Records requests and answers from a routing closure.
final class MockHTTP: HTTPClient, @unchecked Sendable {
    var requests: [URLRequest] = []
    let lock = NSLock()
    let route: (URLRequest) -> (Int, String)

    init(_ route: @escaping (URLRequest) -> (Int, String)) { self.route = route }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { requests.append(request) }
        let (status, body) = route(request)
        return HTTPResponse(status: status, body: Data(body.utf8))
    }
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    var items: [String: Credential] = [:]
    func load(_ id: String) -> Credential? { items[id] }
    func save(_ c: Credential, for id: String) throws { items[id] = c }
    func delete(_ id: String) { items[id] = nil }
}

func makeJWT(_ claims: [String: Any]) -> String {
    let payload = JWT.base64URLEncode(try! JSONSerialization.data(withJSONObject: claims))
    return "eyJhbGciOiJub25lIn0.\(payload).sig"
}

/// Counts secret reads like a Keychain would (each read = one potential access prompt).
final class CountingKeychain: KeychainReading, @unchecked Sendable {
    var blob: Data
    var reads = 0
    init(_ blob: Data) { self.blob = blob }
    func items(servicePrefix: String) -> [(service: String, account: String)] { [("Claude Code-credentials", "me")] }
    func data(service: String, account: String) -> Data? { reads += 1; return blob }
}

final class DiscoveryTests: XCTestCase {
    var home: URL!
    var appDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("aiusage-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        appDir = base.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func write(_ rel: String, _ content: String) throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Path → (contents, modification date) for every file under home.
    func snapshotHome() -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil)!
        for case let url as URL in e {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                out[url.path] = try? Data(contentsOf: url)
            }
        }
        return out
    }

    func populate() throws {
        let future = Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        try write(".claude/.credentials.json", #"{"claudeAiOauth":{"accessToken":"claude-main","refreshToken":"r1","expiresAt":\#(future)}}"#)
        try write(".claude.json", #"{"oauthAccount":{"emailAddress":"me@example.com"}}"#)
        try write(".claude-work/.credentials.json", #"{"claudeAiOauth":{"accessToken":"claude-work","refreshToken":"r2","expiresAt":1000}}"#)
        try write(".claude/settings.json", #"{"env":{"ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic","ANTHROPIC_AUTH_TOKEN":"glm-key"}}"#)
        let access = makeJWT(["exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
                              "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"]])
        let idToken = makeJWT(["email": "codex@example.com"])
        try write(".codex/auth.json", #"{"tokens":{"access_token":"\#(access)","refresh_token":"cr","id_token":"\#(idToken)","account_id":"acct-1"}}"#)
        try write(".local/share/opencode/auth.json", """
        {"anthropic":{"type":"oauth","access":"claude-main","refresh":"r1","expires":\(future)},
         "deepseek":{"type":"api","key":"ds-key"},
         "kimi-for-coding":{"type":"api","key":"kimi-key"},
         "minimax":{"type":"api","key":"mm-key"}}
        """)
        try write(".pi/agent/auth.json", #"{"zai":{"type":"api_key","key":"zai-key"}}"#)
        try write(".config/claude-lanes/config.env", "CONFIG_1_BASE_URL=https://api.kimi.com/coding/\nCONFIG_1_AUTH_TOKEN=lane-kimi\n")
    }

    func testDiscoversAllSourcesAndDedupes() throws {
        try populate()
        let found = LocalDiscovery(home: home, environment: [:]).discover()
        let byProvider = Dictionary(grouping: found, by: \.account.provider)
        XCTAssertEqual(byProvider[.claude]?.count, 2, "OpenCode copy of the same Claude token is deduped")
        XCTAssertEqual(byProvider[.claude]?.first?.account.label, "me@example.com")
        XCTAssertEqual(byProvider[.codex]?.first?.account.label, "codex@example.com")
        guard case .oauth(let codexToken) = byProvider[.codex]!.first!.credential else { return XCTFail() }
        XCTAssertEqual(codexToken.accountId, "acct-1")
        let glm = byProvider[.glm]!.compactMap { d -> String? in if case .apiKey(let k) = d.credential { return k.baseURL } else { return nil } }
        XCTAssertEqual(Set(glm), ["https://open.bigmodel.cn", GLM.internationalBaseURL])
        XCTAssertEqual(byProvider[.kimi]?.count, 2)
        XCTAssertEqual(byProvider[.deepseek]?.count, 1)
        if case .apiKey(let k) = byProvider[.minimax]!.first!.credential { XCTAssertEqual(k.region, "global") } else { XCTFail() }
    }

    func testPollingNeverWritesOrRefreshesLocalCredentials() async throws {
        try populate()
        let before = snapshotHome()
        let http = MockHTTP { req in
            let url = req.url!.absoluteString
            if url.contains("oauth/token") { return (500, "must not be called") }
            if url.contains("api/oauth/usage") {
                return req.value(forHTTPHeaderField: "Authorization") == "Bearer claude-main"
                    ? (200, #"{"five_hour":{"utilization":7,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":11,"resets_at":"2030-01-02T00:00:00Z"}}"#)
                    : (401, "{}")
            }
            if url.contains("wham/usage") {
                XCTAssertEqual(req.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-1")
                return (200, #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_after_seconds":60}}}"#)
            }
            return (401, "{}")
        }
        let service = UsageService(secrets: MemorySecrets(), client: http, home: home, directory: appDir)
        let statuses = await service.refreshAll()

        XCTAssertEqual(snapshotHome(), before, "discovery and polling must not modify anything under $HOME")
        XCTAssertFalse(http.requests.contains { $0.url!.absoluteString.contains("oauth/token") }, "local tokens are never refreshed")

        let main = statuses.first { $0.account.label == "me@example.com" }!
        XCTAssertEqual(main.snapshot?.fiveHour?.usedPercent, 7)
        let work = statuses.first { $0.account.id.contains(".claude-work") }!
        XCTAssertTrue(work.error?.contains("expired") ?? false, "expired local token reports instead of refreshing")
        XCTAssertEqual(statuses.first { $0.account.provider == .codex }?.snapshot?.fiveHour?.usedPercent, 42)
        // Unauthorized API-key sources surface as errors, not crashes.
        XCTAssertNotNil(statuses.first { $0.account.provider == .deepseek }?.error)
    }

    func testManagedAccountsRefreshAndSupportMultiplePerProvider() async throws {
        let secrets = MemorySecrets()
        var refreshed = 0
        let http = MockHTTP { req in
            let url = req.url!.absoluteString
            if url.contains("oauth/token") {
                refreshed += 1
                return (200, #"{"access_token":"fresh","refresh_token":"r-new","expires_in":3600}"#)
            }
            if url.contains("api/oauth/usage") {
                return req.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
                    ? (200, #"{"five_hour":{"utilization":1,"resets_at":null},"seven_day":{"utilization":2,"resets_at":null}}"#)
                    : (401, "{}")
            }
            return (404, "{}")
        }
        let service = UsageService(secrets: secrets, client: http, home: home, directory: appDir)
        let a = try await service.addManaged(provider: .claude, label: "one@x", credential: .oauth(OAuthToken(accessToken: "stale", refreshToken: "r", expiresAt: .distantFuture)))
        let b = try await service.addManaged(provider: .claude, label: "two@x", credential: .oauth(OAuthToken(accessToken: "old", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 0))))
        XCTAssertNotEqual(a.id, b.id)
        let statuses = await service.refreshAll()
        XCTAssertEqual(statuses.count, 2)
        XCTAssertTrue(statuses.allSatisfy { $0.snapshot?.sevenDay?.usedPercent == 2 })
        XCTAssertEqual(refreshed, 2, "one refresh on 401, one for the expired token")
        if case .oauth(let t) = secrets.items[b.id]! { XCTAssertEqual(t.refreshToken, "r-new") } else { XCTFail() }

        await service.setHidden(a.id, true)
        let visible = await service.visibleAccounts().map(\.id)
        XCTAssertEqual(visible, [b.id])
        await service.removeManaged(b.id)
        XCTAssertNil(secrets.items[b.id])
        // State persists for the next launch.
        let reloaded = UsageService(secrets: secrets, client: http, home: home, directory: appDir)
        let reloadedIDs = await reloaded.allAccounts().map(\.id)
        XCTAssertEqual(reloadedIDs, [a.id])
    }

    func testExpiredKeychainTokenIsReReadOnlyOnce() async throws {
        let expired = #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"r","expiresAt":1000}}"#
        let keychain = CountingKeychain(Data(expired.utf8))
        let http = MockHTTP { _ in (500, "must not be called for an expired token") }
        let service = UsageService(secrets: MemorySecrets(), keychain: keychain, client: http, home: home, directory: appDir)
        for _ in 0..<3 { _ = await service.refreshAll() }
        // 1 read per scan (3 scans, uncached in this fake) + exactly 1 extra re-read for the expired token.
        XCTAssertEqual(keychain.reads, 4)
        // Survives a relaunch.
        let relaunched = UsageService(secrets: MemorySecrets(), keychain: keychain, client: http, home: home, directory: appDir)
        _ = await relaunched.refreshAll()
        XCTAssertEqual(keychain.reads, 5)
        XCTAssertTrue(http.requests.isEmpty)
    }
}
