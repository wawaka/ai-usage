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

public enum HorizontalLogoStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case full, half
    public var id: String { rawValue }
    public var label: String { self == .full ? "Full" : "Half" }
}

public struct HorizontalBarSettings: Codable, Equatable, Sendable {
    public var showPace = true
    public var logoStyle: HorizontalLogoStyle = .full
    public var showSeparators = true
    public var barLength: Double = 48
    public init() {}
    private enum CodingKeys: String, CodingKey { case showPace, logoStyle, showSeparators, barLength }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showPace = try values.decodeIfPresent(Bool.self, forKey: .showPace) ?? true
        logoStyle = try values.decodeIfPresent(HorizontalLogoStyle.self, forKey: .logoStyle) ?? .full
        showSeparators = try values.decodeIfPresent(Bool.self, forKey: .showSeparators) ?? true
        barLength = try values.decodeIfPresent(Double.self, forKey: .barLength) ?? 48
    }
    public var effectiveBarLength: Double { min(120, max(24, barLength.isFinite ? barLength : 48)) }
}

public enum LogoPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case top, bottom, left, right, off
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var isBesideBars: Bool { self == .left || self == .right }
}

public struct VerticalBarSettings: Codable, Equatable, Sendable {
    public var logoPosition: LogoPosition = .bottom
    public var showPace = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case logoPosition, logosOnTop, showPace }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        logoPosition = try values.decodeIfPresent(LogoPosition.self, forKey: .logoPosition)
            ?? ((try values.decodeIfPresent(Bool.self, forKey: .logosOnTop) ?? false) ? .top : .bottom)
        showPace = try values.decodeIfPresent(Bool.self, forKey: .showPace) ?? true
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(logoPosition, forKey: .logoPosition)
        try values.encode(showPace, forKey: .showPace)
    }
}

public struct DialSettings: Codable, Equatable, Sendable {
    public var showPace = true
    public var ringWidth: Double = 2
    public var ringGap: Double = 0.5
    public var iconSize: Double = 8
    public init() {}
    private enum CodingKeys: String, CodingKey { case showPace, ringWidth, ringGap, iconSize }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showPace = try values.decodeIfPresent(Bool.self, forKey: .showPace) ?? true
        ringWidth = try values.decodeIfPresent(Double.self, forKey: .ringWidth) ?? 2
        ringGap = try values.decodeIfPresent(Double.self, forKey: .ringGap) ?? 0.5
        iconSize = try values.decodeIfPresent(Double.self, forKey: .iconSize) ?? 8
    }
    public var effectiveRingWidth: Double { min(2.5, max(1, ringWidth.isFinite ? ringWidth : 2)) }
    public var effectiveRingGap: Double { min(1, max(0.5, ringGap.isFinite ? ringGap : 0.5)) }
    public var effectiveIconSize: Double { min(8, max(4, iconSize.isFinite ? iconSize : 8)) }
    public var innerRadius: Double { 9.25 - effectiveRingWidth - effectiveRingGap }
}

/// Every style keeps its options when switching to a different style.
public struct DisplayStyleSettings: Codable, Equatable, Sendable {
    public var style: TitleStyle = .bars
    public var horizontal = HorizontalBarSettings()
    public var vertical = VerticalBarSettings()
    public var dial = DialSettings()

    public init() {}

    /// Preserve preferences from versions that treated bars + percentages as a fifth style.
    public init(legacyStyle: String?, logosOnTop: Bool) {
        style = TitleStyle(rawValue: legacyStyle ?? "") ?? .bars
        vertical.logoPosition = logosOnTop ? .top : .bottom
    }
}
