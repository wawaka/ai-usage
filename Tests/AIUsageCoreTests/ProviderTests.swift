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
        XCTAssertEqual(BurnAnalyzer.analyze(s, samples: []).state, .balance)
    }

    func testBurnAnalysis() {
        let now = Date()
        let snap = UsageSnapshot(windows: [
            UsageWindow(kind: .fiveHour, usedPercent: 10, resetsAt: now.addingTimeInterval(3600)),
            UsageWindow(kind: .sevenDay, usedPercent: 40, resetsAt: now.addingTimeInterval(3 * 86400)),
        ])
        XCTAssertEqual(BurnAnalyzer.analyze(snap, samples: []).state, .learning)
        // 5h-% → 7d-% conversion of 0.1: 60% weekly left over ~14.4 slots → ~41.7% per 5h recommended.
        let samples = (0..<11).map { UsageSample(at: now.addingTimeInterval(Double($0) * 300), five: Double($0 * 10), seven: Double($0)) }
        XCTAssertEqual(BurnAnalyzer.conversionRate(samples)!, 0.1, accuracy: 1e-9)
        let a = BurnAnalyzer.analyze(snap, samples: samples, now: now)
        XCTAssertEqual(a.state, .underBurn)
        XCTAssertEqual(a.target!.minPercent, 41.67 * 0.8, accuracy: 0.1)
        var hot = snap; hot.windows[0].usedPercent = 95
        XCTAssertEqual(BurnAnalyzer.analyze(hot, samples: samples).state, .limitRisk)
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
        XCTAssertEqual(Format.percent(0.4), "<1%")
        XCTAssertEqual(Format.planLabel("claude_max"), "Max")
    }
}
