import XCTest
@testable import AIUsageCore

final class ProviderTests: XCTestCase {
    func obj(_ s: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
    }

    func testSHA256AndPKCE() {
        let digest = SHA256.hash(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // RFC 7636 appendix B example.
        let challenge = JWT.base64URLEncode(SHA256.hash(Data("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk".utf8)))
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let p = PKCE()
        XCTAssertGreaterThanOrEqual(p.verifier.count, 43)
        XCTAssertFalse(p.verifier.contains("="))
    }

    func testParseOAuthCallback() {
        let a = parseOAuthCallback("http://localhost:1455/auth/callback?code=abc%2B1&state=s1")
        XCTAssertEqual(a.code, "abc+1"); XCTAssertEqual(a.state, "s1")
        let b = parseOAuthCallback("  xyz#st  ")
        XCTAssertEqual(b.code, "xyz"); XCTAssertEqual(b.state, "st")
        let c = parseOAuthCallback("?error=access_denied")
        XCTAssertEqual(c.error, "access_denied")
    }

    func testClaudeParse() throws {
        // Shape captured from the live endpoint (microsecond timestamps).
        let s = try Claude.parse(obj("""
        {"five_hour":{"utilization":5.0,"resets_at":"2026-10-30T15:00:00.386242+00:00"},
         "seven_day":{"utilization":11.0,"resets_at":"2026-11-05T11:00:00.386265+00:00"},
         "seven_day_opus":null,"seven_day_sonnet":{"utilization":3,"resets_at":"2026-11-05T11:00:00Z"}}
        """))
        XCTAssertEqual(s.fiveHour?.usedPercent, 5)
        XCTAssertEqual(s.sevenDay?.usedPercent, 11)
        XCTAssertEqual(s.fiveHour!.resetsAt!.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-10-30T15:00:00Z")!.timeIntervalSince1970 + 0.386, accuracy: 0.001)
        XCTAssertEqual(s.extraWindows.map(\.label), ["7d Sonnet"])
    }

    func testCodexParseClassifiesByWindowLength() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let s = try Codex.parse(obj("""
        {"plan_type":"plus","rate_limit":{
          "primary_window":{"used_percent":88,"limit_window_seconds":604800,"reset_at":1300000},
          "secondary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_after_seconds":600}}}
        """), now: now)
        XCTAssertEqual(s.fiveHour?.usedPercent, 42)
        XCTAssertEqual(s.fiveHour?.resetsAt, now.addingTimeInterval(600))
        XCTAssertEqual(s.sevenDay?.usedPercent, 88)
        XCTAssertEqual(s.plan, "plus")
        // Weekly-only accounts.
        let w = try Codex.parse(obj(#"{"rate_limit":{"primary_window":{"used_percent":3,"limit_window_seconds":604800}}}"#))
        XCTAssertNil(w.fiveHour); XCTAssertEqual(w.sevenDay?.usedPercent, 3)
    }

    func testGLMShapesAndCredits() throws {
        let s = try GLM.parse(obj("""
        {"success":true,"data":{"level":"pro","limits":[
          {"type":"TIME_LIMIT","unit":5,"number":1,"percentage":50},
          {"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":20,"nextResetTime":1798000000000},
          {"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":2}]}}
        """))
        XCTAssertEqual(s.fiveHour?.usedPercent, 2)
        XCTAssertNil(s.fiveHour?.resetsAt)
        XCTAssertEqual(s.sevenDay?.usedPercent, 20)
        XCTAssertEqual(s.plan, "pro · credits")
        XCTAssertThrowsError(try GLM.parse(obj(#"{"success":false,"msg":"bad key"}"#)))
    }

    func testMiniMaxPercentSources() throws {
        let s = try MiniMax.parse(obj("""
        {"model_remains":[{"model_name":"general","current_interval_total_count":0,"current_interval_usage_count":0,
          "current_interval_remaining_percent":99,"current_weekly_total_count":0,"current_weekly_usage_count":0,
          "current_weekly_remaining_percent":100,"end_time":1798000000000,"weekly_end_time":1798500000000}],
         "base_resp":{"status_code":0}}
        """))
        XCTAssertEqual(s.fiveHour?.usedPercent, 1)
        XCTAssertEqual(s.sevenDay?.usedPercent, 0)
        XCTAssertEqual(MiniMax.percent(total: 200, used: 50, remainingPercent: 10), 25)
    }

    func testKimiDerivesOmittedFields() throws {
        let s = try Kimi.parse(obj("""
        {"user":{"membership":{"level":"LEVEL_BASIC"}},
         "usage":{"limit":"100","remaining":"100","resetTime":"2026-11-02T10:38:00Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"50","used":"10","remaining":"40","resetTime":"2026-10-30T18:38:00Z"}}]}
        """))
        XCTAssertEqual(s.fiveHour?.usedPercent, 20)
        XCTAssertEqual(s.sevenDay?.usedPercent, 0)
        XCTAssertEqual(s.plan, "LEVEL_BASIC")
    }

    func testDeepSeekBalance() throws {
        let s = try DeepSeek.parse(obj(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"71.47"}]}"#))
        XCTAssertEqual(s.balance?.formatted, "¥71.47")
        XCTAssertEqual(UsageAnalysis.of(s).state, .balance)
    }

    func testUsageState() {
        func snap(_ five: Double, _ seven: Double) -> UsageSnapshot {
            UsageSnapshot(windows: [UsageWindow(kind: .fiveHour, usedPercent: five, resetsAt: nil),
                                    UsageWindow(kind: .sevenDay, usedPercent: seven, resetsAt: nil)])
        }
        XCTAssertEqual(UsageAnalysis.of(snap(10, 40)).state, .normal)
        XCTAssertNil(UsageState.normal.badge)
        XCTAssertEqual(UsageAnalysis.of(snap(10, 70)).state, .normal)
        XCTAssertEqual(UsageAnalysis.of(snap(95, 40)).state, .limit)
        let empty = UsageSnapshot(windows: [], balance: Balance(total: "0", currency: "USD", isAvailable: false))
        XCTAssertEqual(UsageAnalysis.of(empty).state, .depleted)
    }

    func testElapsedAndInvertedDisplay() {
        let now = Date()
        let w = UsageWindow(kind: .fiveHour, usedPercent: 30, resetsAt: now.addingTimeInterval(3600 * 4), windowMinutes: 300)
        XCTAssertEqual(w.elapsedFraction(now: now)!, 0.2, accuracy: 1e-9)
        XCTAssertEqual(w.display(remaining: false, now: now).percent, 30)
        XCTAssertEqual(w.display(remaining: true, now: now).percent, 70)
        XCTAssertEqual(w.display(remaining: true, now: now).time!, 0.8, accuracy: 1e-9)
        XCTAssertNil(UsageWindow(kind: .sevenDay, usedPercent: 1, resetsAt: nil).elapsedFraction())
        let untouched = UsageWindow(kind: .fiveHour, usedPercent: 0, resetsAt: now.addingTimeInterval(5 * 3600), windowMinutes: 300)
            .observed(at: now)
        XCTAssertTrue(untouched.isUntouched)
        XCTAssertNil(untouched.display(remaining: false, now: now).time, "no time position before the window starts")
        XCTAssertEqual(untouched.display(remaining: true, now: now).percent, 100)
    }

    func testUntouchedMeansNoUsageAndAFullWindowLeft() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func codex(_ used: Int, resetAfter: Int) throws -> UsageWindow {
            try Codex.parse(obj("""
            {"rate_limit":{"primary_window":{"used_percent":\(used),"limit_window_seconds":18000,"reset_after_seconds":\(resetAfter)}}}
            """), now: now).fiveHour!
        }
        // Codex keeps reporting "a full window from now" until first use: not started, no reset.
        let fresh = try codex(0, resetAfter: 18000)
        XCTAssertTrue(fresh.isUntouched)
        XCTAssertNil(fresh.resetsAt)
        XCTAssertNil(fresh.display(remaining: false, now: now).time)
        // Rounded or minute-truncated resets still count as a full window.
        XCTAssertTrue(try codex(0, resetAfter: 18000 - 90).isUntouched)
        // 0% but less than a full window left: the clock is running (usage rounded down to 0).
        let started = try codex(0, resetAfter: 4 * 3600)
        XCTAssertFalse(started.isUntouched)
        XCTAssertEqual(started.display(remaining: false, now: now).time!, 0.2, accuracy: 1e-9)
        XCTAssertEqual(started.paceSplit(remaining: true, now: now).onPace, 100)
        XCTAssertFalse(try codex(1, resetAfter: 18000).isUntouched)

        // Claude reports no reset before first use, and the real one once the window runs.
        let claude = try Claude.parse(obj("""
        {"five_hour":{"utilization":0,"resets_at":null},
         "seven_day":{"utilization":0,"resets_at":"\(ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 86400)))"}}
        """), now: now)
        XCTAssertTrue(claude.fiveHour!.isUntouched)
        XCTAssertFalse(claude.sevenDay!.isUntouched)
        XCTAssertNotNil(claude.sevenDay!.display(remaining: false, now: now).time)
    }

    func testSavedSnapshotDropsNotStartedResetOnLoad() throws {
        // Written before `observed(at:)` existed: a 0% window with a reset a full window ahead.
        let observed = Date(timeIntervalSince1970: 1_800_000_000)
        let raw = UsageWindow(kind: .fiveHour, usedPercent: 0, resetsAt: observed.addingTimeInterval(18000), windowMinutes: 300)
        let window = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        let saved = #"{"windows":[\#(window)],"observedAt":\#(observed.timeIntervalSinceReferenceDate)}"#
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(saved.utf8))
        XCTAssertTrue(snapshot.fiveHour!.isUntouched)
        XCTAssertEqual(snapshot.extraWindows, [])
        let roundTrip = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(roundTrip, snapshot)
    }

    func testCodexResetCredits() throws {
        let s = try Codex.parse(obj("""
        {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":3,"limit_window_seconds":604800}},
         "rate_limit_reset_credits":{"available_count":2}}
        """))
        XCTAssertEqual(s.resetCredits, ResetCredits(available: 2))
        XCTAssertNil(try Codex.parse(obj(#"{"rate_limit":{"primary_window":{"used_percent":3,"limit_window_seconds":604800}}}"#)).resetCredits)
        // Shape from the Codex CLI's backend client tests.
        let expiry = Codex.nextResetCreditExpiry(obj("""
        {"credits":[
          {"id":"c1","reset_type":"codex_rate_limits","status":"available","granted_at":"2026-06-17T00:00:00Z","expires_at":"2026-07-17T00:00:00Z","title":"Full reset (Weekly + 5 hr)"},
          {"id":"c2","reset_type":"codex_rate_limits","status":"available","granted_at":"2026-06-18T00:00:00Z","expires_at":null},
          {"id":"c3","reset_type":"codex_rate_limits","status":"redeemed","granted_at":"2026-06-01T00:00:00Z","expires_at":"2026-07-01T00:00:00Z"}],
         "available_count":2,"total_earned_count":4}
        """))
        XCTAssertEqual(expiry, ISO8601DateFormatter().date(from: "2026-07-17T00:00:00Z"))
    }

    func testFormatResetCredits() {
        let now = ISO8601DateFormatter().date(from: "2026-10-30T10:00:00Z")!
        XCTAssertEqual(Format.resetCredits(nil, now: now), "")
        XCTAssertEqual(Format.resetCredits(ResetCredits(available: 0), now: now), "")
        XCTAssertEqual(Format.resetCredits(ResetCredits(available: 2), now: now), "2 left")
        XCTAssertEqual(Format.resetCredits(ResetCredits(available: 3, nextExpiresAt: now.addingTimeInterval(86400 * 6 + 3600 * 4)), now: now),
                       "3 left · next expires in 6d 4h")
        XCTAssertEqual(Format.resetCredits(ResetCredits(available: 1, nextExpiresAt: now.addingTimeInterval(3600 + 720)), now: now),
                       "1 left · expires in 1h 12m")
        XCTAssertEqual(Format.resetCredits(ResetCredits(available: 1, nextExpiresAt: now.addingTimeInterval(-1)), now: now), "1 left")
    }

    func testPaceSplit() {
        let now = Date()
        func window(_ used: Double) -> UsageWindow {
            UsageWindow(kind: .fiveHour, usedPercent: used, resetsAt: now.addingTimeInterval(3600 * 4), windowMinutes: 300)  // 20% elapsed
        }
        // Behind the cursor: all on pace. Past it: green up to the cursor, amber after.
        XCTAssertEqual(window(15).paceSplit(remaining: false, now: now).onPace, 15, accuracy: 1e-9)
        let ahead = window(30).paceSplit(remaining: false, now: now)
        XCTAssertEqual(ahead.onPace, 20, accuracy: 1e-9)
        XCTAssertEqual(ahead.fill, 30, accuracy: 1e-9)
        // Remaining view: the fill (70) reaches the cursor (80)? No → ahead; 90 left does → on pace.
        XCTAssertEqual(window(30).paceSplit(remaining: true, now: now).onPace, 0)
        XCTAssertEqual(window(10).paceSplit(remaining: true, now: now).onPace, 90, accuracy: 1e-9)
        // No time position (unknown window length): everything is on pace.
        let unknown = UsageWindow(kind: .sevenDay, usedPercent: 50, resetsAt: nil).paceSplit(remaining: false, now: now)
        XCTAssertEqual(unknown.onPace, 50)
    }

    func testFormat() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-30T10:00:00Z")!
        XCTAssertEqual(Format.reset(now.addingTimeInterval(7200), now: now, calendar: cal), "reset 12:00")
        XCTAssertEqual(Format.reset(now.addingTimeInterval(86400 * 2), now: now, calendar: cal), "reset 11/1 10:00")
        XCTAssertEqual(Format.reset(now.addingTimeInterval(-1), now: now, calendar: cal), "reset due")
        XCTAssertEqual(Format.countdown(now.addingTimeInterval(3 * 3600 + 720), now: now), "3h 12m")
        XCTAssertEqual(Format.countdown(now.addingTimeInterval(2 * 86400 + 5 * 3600 + 59 * 60), now: now), "2d 5h")
        XCTAssertEqual(Format.countdown(now.addingTimeInterval(2 * 86400 + 5 * 60), now: now), "2d 5m")
        XCTAssertEqual(Format.countdown(now.addingTimeInterval(420), now: now), "7m")
        XCTAssertEqual(Format.countdown(now.addingTimeInterval(30), now: now), "<1m")
        XCTAssertEqual(Format.countdown(now.addingTimeInterval(-5), now: now), "now")
        XCTAssertEqual(Format.ago(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(Format.ago(now.addingTimeInterval(-300), now: now), "5m ago")
        XCTAssertEqual(Format.ago(now.addingTimeInterval(-(2 * 3600 + 300)), now: now), "2h 5m ago")
        XCTAssertEqual(Format.percent(0.4), "<1%")
        XCTAssertEqual(Format.planLabel("claude_max"), "Max")
        XCTAssertEqual(Format.planLabel("max_5x"), "Max 5x")
        XCTAssertEqual(Format.planLabel("plus"), "Plus")
    }

    func testClaudePlanName() {
        XCTAssertEqual(Claude.planName(subscription: "max", tier: "default_claude_max_5x"), "max_5x")
        XCTAssertEqual(Claude.planName(subscription: "max", tier: "default_claude_max_20x"), "max_20x")
        XCTAssertEqual(Claude.planName(subscription: "Pro", tier: "default_claude_ai"), "pro")
        XCTAssertEqual(Claude.planName(subscription: "claude_team", tier: nil), "claude_team")
        XCTAssertNil(Claude.planName(subscription: nil, tier: nil))
    }
}
