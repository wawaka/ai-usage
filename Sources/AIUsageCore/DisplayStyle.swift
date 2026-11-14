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

public enum MenuBarLogoStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case full, half, off
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public struct HorizontalBarSettings: Codable, Equatable, Sendable {
    public var showPace = true
    public var logoStyle: MenuBarLogoStyle = .full
    public var barLength: Double = 48
    public init() {}
    private enum CodingKeys: String, CodingKey { case showPace, logoStyle, barLength }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showPace = try values.decodeIfPresent(Bool.self, forKey: .showPace) ?? true
        logoStyle = try values.decodeIfPresent(MenuBarLogoStyle.self, forKey: .logoStyle) ?? .full
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
    public var barWidth: Double = 4
    public var barGap: Double = 1
    public var showPace = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case logoPosition, logosOnTop, showPace, barWidth, barGap }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        logoPosition = try values.decodeIfPresent(LogoPosition.self, forKey: .logoPosition)
            ?? ((try values.decodeIfPresent(Bool.self, forKey: .logosOnTop) ?? false) ? .top : .bottom)
        showPace = try values.decodeIfPresent(Bool.self, forKey: .showPace) ?? true
        barWidth = try values.decodeIfPresent(Double.self, forKey: .barWidth) ?? 4
        barGap = try values.decodeIfPresent(Double.self, forKey: .barGap) ?? 1
    }
    public var effectiveBarWidth: Double { min(8, max(2, barWidth.isFinite ? barWidth : 4)) }
    public var effectiveBarGap: Double { min(6, max(0.5, barGap.isFinite ? barGap : 1)) }
    public var meterWidth: Double { effectiveBarWidth * 2 + effectiveBarGap }
    public var tileWidth: Double { logoPosition.isBesideBars ? meterWidth + 13 : max(logoPosition == .off ? 0 : 9, meterWidth) + 2 }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(logoPosition, forKey: .logoPosition)
        try values.encode(showPace, forKey: .showPace)
        try values.encode(barWidth, forKey: .barWidth)
        try values.encode(barGap, forKey: .barGap)
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

public struct NumberSettings: Codable, Equatable, Sendable {
    public var logoStyle: MenuBarLogoStyle = .full
    public var showTags = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case logoStyle, showTags }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        logoStyle = try values.decodeIfPresent(MenuBarLogoStyle.self, forKey: .logoStyle) ?? .full
        showTags = try values.decodeIfPresent(Bool.self, forKey: .showTags) ?? false
    }
}

/// Every style keeps its options when switching to a different style.
public struct DisplayStyleSettings: Codable, Equatable, Sendable {
    public var style: TitleStyle = .bars
    public var horizontal = HorizontalBarSettings()
    public var vertical = VerticalBarSettings()
    public var dial = DialSettings()
    public var numbers = NumberSettings()
    public var showSeparators = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case style, horizontal, vertical, dial, numbers, showSeparators }
    private enum LegacyHorizontalKeys: String, CodingKey { case showSeparators }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        style = try values.decodeIfPresent(TitleStyle.self, forKey: .style) ?? .bars
        horizontal = try values.decodeIfPresent(HorizontalBarSettings.self, forKey: .horizontal) ?? HorizontalBarSettings()
        vertical = try values.decodeIfPresent(VerticalBarSettings.self, forKey: .vertical) ?? VerticalBarSettings()
        dial = try values.decodeIfPresent(DialSettings.self, forKey: .dial) ?? DialSettings()
        numbers = try values.decodeIfPresent(NumberSettings.self, forKey: .numbers) ?? NumberSettings()
        let legacy = try? values.nestedContainer(keyedBy: LegacyHorizontalKeys.self, forKey: .horizontal)
        let oldSeparators = try legacy?.decodeIfPresent(Bool.self, forKey: .showSeparators)
        showSeparators = try values.decodeIfPresent(Bool.self, forKey: .showSeparators) ?? oldSeparators ?? true
    }

    /// Preserve preferences from versions that treated bars + percentages as a fifth style.
    public init(legacyStyle: String?, logosOnTop: Bool) {
        style = TitleStyle(rawValue: legacyStyle ?? "") ?? .bars
        vertical.logoPosition = logosOnTop ? .top : .bottom
    }
}
