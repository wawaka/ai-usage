import XCTest
@testable import AIUsageCore

final class HistoryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(_ pct: Double, reset: Date?, at: Date) -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(kind: .fiveHour, usedPercent: pct, resetsAt: reset, windowMinutes: 300)], observedAt: at)
    }

    func testUnchangedRunKeepsOnlyItsFirstAndLastSample() {
        var h = UsageHistory()
        let reset = t0.addingTimeInterval(3600)
        for (i, pct) in [10.0, 10, 10, 10, 20].enumerated() {
            h.record(snapshot(pct, reset: reset.addingTimeInterval(Double(i)), at: t0.addingTimeInterval(Double(i) * 60)), for: "a")
        }
        let samples = h.windows("a")["5h"]!.samples
        XCTAssertEqual(samples.map(\.percent), [10, 10, 20])
        XCTAssertEqual(samples.map(\.at), [t0, t0.addingTimeInterval(180), t0.addingTimeInterval(240)])
    }

    func testSamplesSplitIntoIntervalsAtEachReset() {
        var h = UsageHistory()
        let r1 = t0.addingTimeInterval(3600), r2 = r1.addingTimeInterval(5 * 3600)
        h.record(snapshot(10, reset: r1, at: t0), for: "a")
        h.record(snapshot(40, reset: r1, at: t0.addingTimeInterval(1800)), for: "a")
        // Untouched after the reset: no sample.
        h.record(snapshot(0, reset: nil, at: r1.addingTimeInterval(10)), for: "a")
        h.record(snapshot(5, reset: r2, at: r1.addingTimeInterval(600)), for: "a")
        let intervals = h.windows("a")["5h"]!.intervals()
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals[0].start, r1.addingTimeInterval(-5 * 3600))
        XCTAssertEqual(intervals[0].end, r1)
        XCTAssertEqual(intervals[0].peak, 40)
        XCTAssertEqual(intervals[1].start, r1)
        XCTAssertEqual(intervals[1].end, r2)
        XCTAssertTrue(intervals[1].isCurrent(now: r1.addingTimeInterval(700)))
        XCTAssertFalse(intervals[0].isCurrent(now: r1.addingTimeInterval(700)))
    }

    func testWithoutResetADropStartsANewInterval() {
        let samples = [30.0, 50, 2, 8].enumerated().map { UsageSample(at: t0.addingTimeInterval(Double($0) * 60), percent: $1, resetsAt: nil) }
        let intervals = WindowHistory(windowMinutes: nil, samples: samples).intervals()
        XCTAssertEqual(intervals.map { $0.samples.map(\.percent) }, [[30, 50], [2, 8]])
        XCTAssertEqual(intervals[1].start, t0.addingTimeInterval(120))
    }

    func testCompactRoundTripAndPrune() throws {
        var h = UsageHistory()
        h.record(snapshot(12.34, reset: t0.addingTimeInterval(100), at: t0), for: "a")
        h.record(snapshot(50, reset: nil, at: t0.addingTimeInterval(60)), for: "b")
        let data = try JSONEncoder().encode(h)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("[1800000000,12.3,1800000100]"))
        let decoded = try JSONDecoder().decode(UsageHistory.self, from: data)
        XCTAssertEqual(decoded, h)

        h.prune(now: t0.addingTimeInterval(UsageHistory.retention + 30))
        XCTAssertNil(h.accounts["a"])
        XCTAssertEqual(h.windows("b")["5h"]?.samples.count, 1)
    }

    func testServiceRecordsAndForgetsHistory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiu-hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = ScriptedHTTP(PollingTests.usage(10))
        let service = UsageService(secrets: MemorySecrets(), client: http, home: dir, directory: dir)
        let account = try await service.addManaged(provider: .claude, label: "a",
                                                   credential: .oauth(OAuthToken(accessToken: "t", refreshToken: "r", expiresAt: .distantFuture)))
        _ = await service.refresh(account, now: t0)
        http.next = PollingTests.usage(20)
        _ = await service.refresh(account, now: t0.addingTimeInterval(60))
        let recorded = await service.history.windows(account.id)["5h"]?.samples.map(\.percent)
        XCTAssertEqual(recorded, [10, 20])
        // Persisted and reloaded.
        let reloaded = UsageService(secrets: MemorySecrets(), client: http, home: dir, directory: dir)
        let reloadedHistory = await reloaded.history
        let saved = await service.history
        XCTAssertEqual(reloadedHistory, saved)

        await service.removeManaged(account.id)
        let after = await service.history.accounts[account.id]
        XCTAssertNil(after)
    }
}
