import Foundation

/// How close an account is to its limits, based purely on current usage.
public enum UsageState: String, Codable, Sendable {
    case normal, high, limit, balance, depleted, unavailable

    public static let highThreshold = 70.0
    public static let limitThreshold = 90.0

    /// Badge text in the panel; nil when there is nothing to call out.
    public var badge: String? {
        switch self {
        case .normal: return nil
        case .high: return "High"
        case .limit: return "Limit"
        case .balance: return "Balance"
        case .depleted: return "Depleted"
        case .unavailable: return "Error"
        }
    }

    /// Lower = more urgent; used to pick the account shown in the compact title.
    public var priority: Int {
        switch self {
        case .unavailable: return 0
        case .depleted, .limit: return 1
        case .high: return 2
        case .normal, .balance: return 3
        }
    }
}

public struct UsageAnalysis: Codable, Equatable, Sendable {
    public var state: UsageState
    public var message: String?

    public init(state: UsageState, message: String? = nil) {
        self.state = state
        self.message = message
    }

    public static func of(_ snapshot: UsageSnapshot) -> UsageAnalysis {
        if let balance = snapshot.balance, snapshot.windows.isEmpty {
            return balance.isAvailable
                ? UsageAnalysis(state: .balance, message: "Pay-as-you-go · no windowed quota")
                : UsageAnalysis(state: .depleted, message: "Balance depleted")
        }
        let peak = snapshot.windows.map(\.usedPercent).max() ?? 0
        if peak >= UsageState.limitThreshold { return UsageAnalysis(state: .limit, message: "Close to a plan limit.") }
        if peak >= UsageState.highThreshold { return UsageAnalysis(state: .high) }
        return UsageAnalysis(state: .normal)
    }
}
