import Foundation

/// Pacing state, same semantics as coding-usage-bar:
/// - learning: not enough history yet to know how 5h usage converts into weekly usage
/// - underBurn: using less than the weekly budget allows ("Low")
/// - onTrack / overBurn: within / above the recommended 5h range
/// - limitRisk: a window is at 90%+
public enum BurnState: String, Codable, Sendable {
    case learning, underBurn, onTrack, overBurn, limitRisk, balance, depleted, unavailable

    public var badge: String {
        switch self {
        case .learning: return "Learning"
        case .underBurn: return "Low"
        case .onTrack: return "On track"
        case .overBurn: return "Fast"
        case .limitRisk: return "Limit"
        case .balance: return "Balance"
        case .depleted: return "Depleted"
        case .unavailable: return "Error"
        }
    }

    /// Lower = more urgent; used to pick the provider shown in the compact title.
    public var priority: Int {
        switch self {
        case .unavailable: return 0
        case .depleted, .limitRisk: return 1
        case .overBurn: return 2
        case .underBurn: return 3
        case .learning, .balance: return 4
        case .onTrack: return 5
        }
    }
}

public enum BurnProfile: String, Codable, CaseIterable, Sendable {
    case low, high
    var factors: (min: Double, max: Double) { self == .low ? (0.8, 1.1) : (0.9, 1.35) }
}

public struct BurnTarget: Codable, Equatable, Sendable {
    public var minPercent: Double
    public var maxPercent: Double
    public var conversionRate: Double
}

public struct BurnAnalysis: Codable, Equatable, Sendable {
    public var state: BurnState
    public var target: BurnTarget?
    public var message: String
}

public struct UsageSample: Codable, Equatable, Sendable {
    public var at: Date
    public var five: Double
    public var seven: Double
}

public enum BurnAnalyzer {
    static let minTotalFiveDelta = 5.0

    /// How many weekly-% points one 5h-% point costs, estimated from history.
    public static func conversionRate(_ samples: [UsageSample]) -> Double? {
        let usable = samples.sorted { $0.at < $1.at }
        guard usable.count >= 2 else { return nil }
        // Longest tail where the weekly window never drops (a drop means a reset or a stale reading).
        var start = usable.count - 1
        while start > 0 && usable[start - 1].seven <= usable[start].seven { start -= 1 }
        if start > 0 { start += 1 }
        let recent = Array(usable[min(start, usable.count - 1)...])
        var totalFive = 0.0, totalSeven = 0.0
        for i in recent.indices.dropFirst() {
            let df = recent[i].five - recent[i - 1].five
            let ds = recent[i].seven - recent[i - 1].seven
            if df > 0 && ds >= 0 { totalFive += df; totalSeven += ds }
        }
        guard totalFive >= minTotalFiveDelta else { return nil }
        let rate = totalSeven / totalFive
        return rate.isFinite && rate > 0 ? rate : nil
    }

    public static func analyze(_ snapshot: UsageSnapshot, samples: [UsageSample], profile: BurnProfile = .low, now: Date = Date()) -> BurnAnalysis {
        if let balance = snapshot.balance, snapshot.windows.isEmpty {
            return balance.isAvailable
                ? BurnAnalysis(state: .balance, message: "Pay-as-you-go · no windowed quota")
                : BurnAnalysis(state: .depleted, message: "Balance depleted")
        }
        let five = snapshot.fiveHour, seven = snapshot.sevenDay
        if (five?.usedPercent ?? 0) >= 90 || (seven?.usedPercent ?? 0) >= 90 {
            return BurnAnalysis(state: .limitRisk, message: "Close to a plan limit — consider switching account or slowing down.")
        }
        guard let five, let seven else {
            let msg = five == nil && seven != nil ? "5h window not reported; showing 7d only." : "7d window not reported; showing 5h only."
            return BurnAnalysis(state: .learning, message: msg)
        }
        guard let rate = conversionRate(samples) else {
            return BurnAnalysis(state: .learning, message: "Learning burn pattern — advice once samples suffice.")
        }
        let remainingSeven = max(0, 100 - seven.usedPercent)
        let minutesLeft = max(0, (seven.resetsAt ?? now).timeIntervalSince(now) / 60)
        let slots = max(1, minutesLeft / 300)
        let recommended = min(100, remainingSeven / slots / rate)
        let f = profile.factors
        let target = BurnTarget(minPercent: min(100, recommended * f.min), maxPercent: min(100, recommended * f.max), conversionRate: rate)
        let range = String(format: "%.1f%%-%.1f%%", target.minPercent, target.maxPercent)
        if five.usedPercent < target.minPercent {
            return BurnAnalysis(state: .underBurn, target: target, message: "Below target (\(range)).")
        }
        if five.usedPercent > target.maxPercent {
            return BurnAnalysis(state: .overBurn, target: target, message: "Above target (\(range)).")
        }
        return BurnAnalysis(state: .onTrack, target: target, message: "On track (\(range)).")
    }
}
