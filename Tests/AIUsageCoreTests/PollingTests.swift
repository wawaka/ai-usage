import XCTest
@testable import AIUsageCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers every request from a mutable script and counts them.
final class ScriptedHTTP: HTTPClient, @unchecked Sendable {
    var next: HTTPResponse
    var count = 0
    init(_ next: HTTPResponse) { self.next = next }
    func send(_ request: URLRequest) async throws -> HTTPResponse { count += 1; return next }
}

final class PollingTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiu-poll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    static func usage(_ pct: Int) -> HTTPResponse {
        HTTPResponse(status: 200, body: Data(#"{"five_hour":{"utilization":\#(pct),"resets_at":null},"seven_day":{"utilization":1,"resets_at":null}}"#.utf8))
    }

    func makeService(_ http: HTTPClient) async throws -> (UsageService, Account) {
        let service = UsageService(secrets: MemorySecrets(), client: http, home: dir, directory: dir)
        await service.setPolicy(PollPolicy(minInterval: 60, maxInterval: 400))
        let account = try await service.addManaged(provider: .claude, label: "a",
                                                   credential: .oauth(OAuthToken(accessToken: "t", refreshToken: "r", expiresAt: .distantFuture)))
        return (service, account)
    }

    func testIntervalBacksOffWhileUnchangedAndResetsOnChange() async throws {
        let http = ScriptedHTTP(Self.usage(10))
        let (service, account) = try await makeService(http)
        let t0 = Date()
        func waitAfter(_ now: Date) async -> TimeInterval {
            _ = await service.refresh(account, now: now)
            return await service.nextRefresh(account.id)!.timeIntervalSince(now)
        }
        var waits: [TimeInterval] = []
        for _ in 0..<5 { waits.append(await waitAfter(t0)) }
        // First data counts as a change; then doubling while unchanged, capped at the maximum.
        XCTAssertEqual(waits, [60, 120, 240, 400, 400])
        http.next = Self.usage(11)
        let afterChange = await waitAfter(t0)
        XCTAssertEqual(afterChange, 60, "a change goes back to the minimum")
        let early = await service.dueAccounts(now: t0.addingTimeInterval(59)).count
        let onTime = await service.dueAccounts(now: t0.addingTimeInterval(60)).count
        XCTAssertEqual(early, 0)
        XCTAssertEqual(onTime, 1)
    }

    func testEachWindowResetRestartsBackoffEvenWhenUsageIsUnchanged() async throws {
        for kind in ["five_hour", "seven_day"] {
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            let reset = t0.addingTimeInterval(300)
            let resetString = ISO8601DateFormatter().string(from: reset)
            let body: [String: Any] = [
                "five_hour": ["utilization": 100, "resets_at": kind == "five_hour" ? resetString as Any : NSNull()],
                "seven_day": ["utilization": 100, "resets_at": kind == "seven_day" ? resetString as Any : NSNull()]
            ]
            let http = ScriptedHTTP(HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: body)))
            let (service, account) = try await makeService(http)
            for _ in 0..<4 { _ = await service.refresh(account, now: t0) }
            let due = await service.nextRefresh(account.id)
            XCTAssertEqual(due, reset.addingTimeInterval(10), kind)

            // Still the old window: asked once more a minute later.
            _ = await service.refresh(account, now: reset.addingTimeInterval(10))
            let rechecked = await service.nextRefresh(account.id)
            XCTAssertEqual(rechecked, reset.addingTimeInterval(70), kind)
            // Still old: no second recheck, and the old reset restarted backoff only once.
            _ = await service.refresh(account, now: reset.addingTimeInterval(70))
            let backedOff = await service.nextRefresh(account.id)
            XCTAssertEqual(backedOff, reset.addingTimeInterval(190), kind)
        }
    }

    func testRecheckAfterResetUntilTheNewWindowCountsDown() async throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = t0.addingTimeInterval(300)
        func body(_ used: Int, _ resetsAt: Date?) throws -> HTTPResponse {
            let r: Any = resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
            return HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: [
                "five_hour": ["utilization": used, "resets_at": r],
                "seven_day": ["utilization": 1, "resets_at": NSNull()]]))
        }
        for countdownStarted in [false, true] {
            let http = ScriptedHTTP(try body(100, reset))
            let (service, account) = try await makeService(http)
            await service.setPolicy(PollPolicy(minInterval: 120, maxInterval: 400))
            for _ in 0..<4 { _ = await service.refresh(account, now: t0) }
            // After the reset the window either hasn't started (nothing used yet: no reset) or is
            // already counting down to the next one.
            http.next = try body(countdownStarted ? 1 : 0, countdownStarted ? reset.addingTimeInterval(5 * 3600) : nil)
            _ = await service.refresh(account, now: reset.addingTimeInterval(10))
            let next = await service.nextRefresh(account.id)
            if countdownStarted {
                XCTAssertEqual(next, reset.addingTimeInterval(130), "counting down: minimum interval, no recheck")
                continue
            }
            XCTAssertEqual(next, reset.addingTimeInterval(70), "not started: look again a minute later")
            _ = await service.refresh(account, now: reset.addingTimeInterval(70))
            let after = await service.nextRefresh(account.id)
            XCTAssertEqual(after, reset.addingTimeInterval(310), "only one recheck, then normal backoff")
        }
    }

    func testFailedPollAfterResetIsNotRechecked() async throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = t0.addingTimeInterval(300)
        let http = ScriptedHTTP(HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: [
            "five_hour": ["utilization": 100, "resets_at": ISO8601DateFormatter().string(from: reset)],
            "seven_day": ["utilization": 1, "resets_at": NSNull()]])))
        let (service, account) = try await makeService(http)
        await service.setPolicy(PollPolicy(minInterval: 120, maxInterval: 400))
        for _ in 0..<4 { _ = await service.refresh(account, now: t0) }
        http.next = HTTPResponse(status: 500, body: Data())
        _ = await service.refresh(account, now: reset.addingTimeInterval(10))
        let next = await service.nextRefresh(account.id)
        XCTAssertEqual(next, reset.addingTimeInterval(130), "reset restarts backoff at the minimum, no extra recheck")
    }

    func testRateLimitHonoursRetryAfterAndBlocksRequests() async throws {
        let http = ScriptedHTTP(HTTPResponse(status: 429, body: Data("{}".utf8), headers: ["retry-after": "900"]))
        let (service, account) = try await makeService(http)
        let t0 = Date()
        let status = await service.refresh(account, now: t0)
        XCTAssertTrue(status.error?.contains("Rate limited") == true)
        let wait = await service.nextRefresh(account.id)!.timeIntervalSince(t0)
        XCTAssertEqual(wait, 900, accuracy: 0.001,
                       "waits as long as the provider asks, even past the maximum interval")
        // A manual refresh inside the window sends nothing.
        _ = await service.refresh(account, now: t0.addingTimeInterval(300))
        XCTAssertEqual(http.count, 1)
        http.next = Self.usage(5)
        let after = await service.refresh(account, now: t0.addingTimeInterval(901))
        XCTAssertNil(after.error)
        XCTAssertEqual(http.count, 3, "the usage request plus the one-time plan lookup")
    }

    func testRateLimitSignals() {
        XCTAssertEqual(HTTP.retryAfter("120"), 120)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(HTTP.retryAfter("Tue, 14 Nov 2023 22:46:40 GMT", now: now), 2000)
        XCTAssertNil(HTTP.retryAfter(nil))
        XCTAssertThrowsError(try GLM.parse(["code": 1302, "msg": "rate"])) {
            XCTAssertEqual($0 as? UsageError, .rateLimited(retryAfter: nil))
        }
    }
}

extension PollingTests {
    func testClaudeAsksForResetsAndFallsBackWhenTheOptInIsRejected() async throws {
        let usage = #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":1,"resets_at":null},"cedar_ember":{"eligible":true,"grants":[{"resets_left":1,"ends_at":"2099-01-01T00:00:00Z"}]}}"#
        var rejectOptIn = false
        let http = MockHTTP { req in
            if req.url?.path.hasSuffix("/profile") == true { return (200, "{}") }
            if req.url?.query?.contains("cedar_ember=1") == true { return rejectOptIn ? (400, "bad param") : (200, usage) }
            return (200, #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":1,"resets_at":null}}"#)
        }
        let (service, account) = try await makeService(http)
        let first = await service.refresh(account)
        XCTAssertEqual(first.snapshot?.resetCredits?.available, 1)
        rejectOptIn = true
        let second = await service.refresh(account)
        XCTAssertNil(second.error)
        XCTAssertEqual(second.snapshot?.fiveHour?.usedPercent, 10)
        XCTAssertNil(second.snapshot?.resetCredits)
    }

    func testCodexResetExpiryIsAskedRarely() async throws {
        var count = 2
        var listStatus = 200
        let http = MockHTTP { req in
            if req.url?.path.hasSuffix("/rate-limit-reset-credits") == true {
                return (listStatus, #"{"credits":[{"id":"c","reset_type":"codex_rate_limits","status":"available","granted_at":"2026-06-17T00:00:00Z","expires_at":"2099-07-17T00:00:00Z"}],"available_count":1}"#)
            }
            return (200, #"{"rate_limit":{"primary_window":{"used_percent":3,"limit_window_seconds":604800}},"rate_limit_reset_credits":{"available_count":\#(count)}}"#)
        }
        let service = UsageService(secrets: MemorySecrets(), client: http, home: dir, directory: dir)
        let account = try await service.addManaged(provider: .codex, label: "c",
                                                   credential: .oauth(OAuthToken(accessToken: "t", refreshToken: "r", expiresAt: .distantFuture, accountId: "acc")))
        func listCalls() -> Int { http.requests.filter { $0.url?.path.hasSuffix("/rate-limit-reset-credits") == true }.count }
        let expiry = ISO8601DateFormatter().date(from: "2099-07-17T00:00:00Z")
        let t0 = Date()

        let first = await service.refresh(account, now: t0)
        XCTAssertEqual(first.snapshot?.resetCredits?.available, 2)
        XCTAssertEqual(first.snapshot?.resetCredits?.nextExpiresAt, expiry)
        XCTAssertEqual(listCalls(), 1)
        // Same count: the date is kept without asking again, until the recheck interval passes.
        let kept = await service.refresh(account, now: t0.addingTimeInterval(3600))
        XCTAssertEqual(kept.snapshot?.resetCredits?.nextExpiresAt, expiry)
        XCTAssertEqual(listCalls(), 1)
        // A failing (rate-limited) list keeps the usage and the known date, and doesn't fail the poll.
        listStatus = 429
        let limited = await service.refresh(account, now: t0.addingTimeInterval(7 * 3600))
        XCTAssertNil(limited.error)
        XCTAssertEqual(limited.snapshot?.resetCredits?.nextExpiresAt, expiry)
        XCTAssertEqual(listCalls(), 2)
        _ = await service.refresh(account, now: t0.addingTimeInterval(8 * 3600))
        XCTAssertEqual(listCalls(), 2, "a failure also waits for the recheck interval")
        // A changed count asks again; no resets asks nothing.
        listStatus = 200
        count = 1
        _ = await service.refresh(account, now: t0.addingTimeInterval(9 * 3600))
        XCTAssertEqual(listCalls(), 3)
        count = 0
        let none = await service.refresh(account, now: t0.addingTimeInterval(10 * 3600))
        XCTAssertEqual(listCalls(), 3)
        XCTAssertEqual(Format.resetCredits(none.snapshot?.resetCredits), "")
    }

    func testScheduleSurvivesRelaunch() async throws {
        let http = ScriptedHTTP(Self.usage(10))
        let (service, account) = try await makeService(http)
        let t0 = Date()
        _ = await service.refresh(account, now: t0)
        let relaunched = UsageService(secrets: MemorySecrets(), client: http, home: dir, directory: dir)
        await relaunched.setPolicy(PollPolicy(minInterval: 60, maxInterval: 400))
        let dueEarly = await relaunched.dueAccounts(now: t0.addingTimeInterval(30)).map(\.id)
        let dueLater = await relaunched.dueAccounts(now: t0.addingTimeInterval(61)).map(\.id)
        XCTAssertEqual(dueEarly, [], "a relaunch doesn't refetch before the interval has passed")
        XCTAssertEqual(dueLater, [account.id])
    }

    func testClaudePlanComesFromProfileOnceAndIsKept() async throws {
        let http = MockHTTP { req in
            if req.url?.path.hasSuffix("/profile") == true {
                return (200, #"{"account":{"email":"a@b.c"},"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_5x"}}"#)
            }
            return (200, #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":1,"resets_at":null}}"#)
        }
        let (service, account) = try await makeService(http)
        let first = await service.refresh(account)
        XCTAssertEqual(Format.planLabel(first.snapshot?.plan), "Max 5x")
        let second = await service.refresh(account, now: Date().addingTimeInterval(500))
        XCTAssertEqual(Format.planLabel(second.snapshot?.plan), "Max 5x")
        let profileCalls = http.requests.filter { $0.url?.path.hasSuffix("/profile") == true }.count
        XCTAssertEqual(profileCalls, 1, "profile is asked once, not on every poll")
    }
}

extension PollingTests {
    func testClaudeInvalidGrantOffersSignInAndReconnectsExistingAccount() async throws {
        let secrets = MemorySecrets()
        let http = ScriptedHTTP(Self.usage(10))
        let service = UsageService(secrets: secrets, client: http, home: dir, directory: dir)
        let account = try await service.addManaged(provider: .claude, label: "a@b.c",
            credential: .oauth(OAuthToken(accessToken: "old", refreshToken: "revoked", expiresAt: .distantFuture)))
        let initial = await service.refresh(account)
        await service.setInMenuBar(account.id, false)
        await service.rename(account.id, to: "My Claude")
        // A 401 on usage causes a refresh, whose invalid_grant must become an actionable state.
        let revoked = MockHTTP { request in
            if request.url?.path.hasSuffix("/oauth/token") == true {
                return (400, #"{"error":"invalid_grant","error_description":"Refresh token not found or invalid"}"#)
            }
            return (401, #"{"error":"unauthorized"}"#)
        }
        let expiredService = UsageService(secrets: secrets, client: revoked, home: dir, directory: dir)
        let failed = await expiredService.refresh(account)
        XCTAssertTrue(failed.requiresSignIn)
        XCTAssertEqual(failed.snapshot?.windows, initial.snapshot?.windows, "keep last usage muted until sign-in succeeds")
        // JSON timestamps can lose sub-second precision across the service restart.
        XCTAssertEqual(try XCTUnwrap(failed.snapshot).observedAt.timeIntervalSince1970,
                       try XCTUnwrap(initial.snapshot).observedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(failed.error, "Claude session expired. Sign in again to update usage.")
        XCTAssertEqual(revoked.requests.count, 2, "invalid_grant must not retry the legacy host")
        let token = OAuthToken(accessToken: "new", refreshToken: "new-refresh", expiresAt: .distantFuture)
        try await expiredService.reauthenticateClaude(account, label: "a@b.c", token: token)
        let accounts = await expiredService.allAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.id, account.id)
        XCTAssertEqual(accounts.first?.label, "My Claude")
        let state = await expiredService.state
        XCTAssertTrue(state.notInMenuBar.contains(account.id))
        XCTAssertEqual(secrets.load(account.id), .oauth(token))
        let due = await expiredService.nextRefresh(account.id)
        XCTAssertNil(due, "reconnecting clears old backoff")
        http.next = Self.usage(20)
        let restoredService = UsageService(secrets: secrets, client: http, home: dir, directory: dir)
        let restored = await restoredService.refresh(account)
        XCTAssertFalse(restored.requiresSignIn)
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.snapshot?.fiveHour?.usedPercent, 20)
    }

    func testClaudeExpiredTokenInvalidGrantAndMissingRefreshTokenOfferSignIn() async throws {
        for refreshToken: String? in ["revoked", nil] {
            let http = ScriptedHTTP(HTTPResponse(status: 400, body: Data(
                #"{"error":"invalid_grant","error_description":"Refresh token not found or invalid"}"#.utf8)))
            let service = UsageService(secrets: MemorySecrets(), client: http, home: dir, directory: dir)
            let account = try await service.addManaged(provider: .claude, label: "a",
                credential: .oauth(OAuthToken(accessToken: "old", refreshToken: refreshToken, expiresAt: .distantPast)))
            let status = await service.refresh(account)
            XCTAssertTrue(status.requiresSignIn)
            XCTAssertEqual(http.count, refreshToken == nil ? 0 : 1)
        }
    }

    func testOtherClaudeFailuresAndCodexInvalidGrantKeepExistingErrorHandling() async throws {
        for (provider, code, body) in [
            (ProviderKind.claude, 400, #"{"error":"invalid_request"}"#),
            (.claude, 500, #"{"error":"invalid_grant"}"#),
            (.codex, 400, #"{"error":"invalid_grant"}"#)
        ] {
            let http = ScriptedHTTP(HTTPResponse(status: code, body: Data(body.utf8)))
            let service = UsageService(secrets: MemorySecrets(), client: http, home: dir, directory: dir)
            let account = try await service.addManaged(provider: provider, label: "a",
                credential: .oauth(OAuthToken(accessToken: "old", refreshToken: "r", expiresAt: .distantPast)))
            let status = await service.refresh(account)
            XCTAssertFalse(status.requiresSignIn)
            XCTAssertTrue(status.error?.contains("HTTP \(code)") == true)
        }
    }

    func testReauthenticationRejectsLocalClaudeAndCodexAccounts() async throws {
        let service = UsageService(secrets: MemorySecrets(), home: dir, directory: dir)
        let codex = try await service.addManaged(provider: .codex, label: "a", credential: .oauth(OAuthToken(accessToken: "old")))
        let local = Account(id: "local:claude", provider: .claude, label: "a", origin: .local(source: "Claude Code"))
        for account in [codex, local] {
            do {
                try await service.reauthenticateClaude(account, label: "a", token: OAuthToken(accessToken: "new"))
                XCTFail("must not replace another tool's credentials or change Codex")
            } catch {}
        }
    }
}
