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
        XCTAssertEqual(http.count, 2)
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
