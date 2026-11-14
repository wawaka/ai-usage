import Foundation

/// Four display families. Options belong to a family rather than becoming extra styles.
public enum TitleStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case bars, verticalBars, dials, percent
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .bars: return "Horizontal bars"
        case .verticalBars: return "Vertical bars"
        case .dials: return "Circular dials"
        case .percent: return "Numbers"
        }
    }
}

public struct HorizontalBarSettings: Codable, Equatable, Sendable {
    public var showPercent = false
    public var showPace = true
    public init() {}
}

public struct VerticalBarSettings: Codable, Equatable, Sendable {
    public var logosOnTop = false
    public var showPace = true
    public init() {}
}

public struct DialSettings: Codable, Equatable, Sendable {
    public var showPace = true
    public init() {}
}

public struct NumberSettings: Codable, Equatable, Sendable {
    public var colorByUsage = false
    public init() {}
}

/// Every style keeps its options when switching to a different style.
public struct DisplayStyleSettings: Codable, Equatable, Sendable {
    public var style: TitleStyle = .bars
    public var horizontal = HorizontalBarSettings()
    public var vertical = VerticalBarSettings()
    public var dial = DialSettings()
    public var numbers = NumberSettings()

    public init() {}

    /// Preserve preferences from versions that treated bars + percentages as a fifth style.
    public init(legacyStyle: String?, logosOnTop: Bool) {
        style = TitleStyle(rawValue: legacyStyle ?? "") ?? .bars
        horizontal.showPercent = legacyStyle == "barsAndPercent"
        vertical.logosOnTop = logosOnTop
    }
}
