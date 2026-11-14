import XCTest
@testable import AIUsageCore

final class DisplayStyleTests: XCTestCase {
    func testLegacyPreferencesKeepTheirAppearance() {
        for style in TitleStyle.allCases {
            let migrated = DisplayStyleSettings(legacyStyle: style.rawValue, logosOnTop: true)
            XCTAssertEqual(migrated.style, style)
            XCTAssertEqual(migrated.vertical.logoPosition, .top)
            XCTAssertTrue(migrated.horizontal.showPace)
            XCTAssertTrue(migrated.vertical.showPace)
            XCTAssertTrue(migrated.dial.showPace)
        }
        let combined = DisplayStyleSettings(legacyStyle: "barsAndPercent", logosOnTop: false)
        XCTAssertEqual(combined.style, .bars)
        XCTAssertEqual(DisplayStyleSettings(legacyStyle: nil, logosOnTop: false), DisplayStyleSettings())
        XCTAssertEqual(DisplayStyleSettings(legacyStyle: "unknown", logosOnTop: false), DisplayStyleSettings())
    }

    func testIndependentOptionsSurviveSwitchingAndPersistence() throws {
        var settings = DisplayStyleSettings()
        settings.horizontal.showPace = false
        settings.style = .verticalBars
        settings.vertical.logoPosition = .left
        settings.style = .dials
        settings.dial.showPace = false
        settings.style = .percent
        settings.dial.ringWidth = 2.5
        settings.dial.ringGap = 1
        settings.dial.iconSize = 6
        let restored = try JSONDecoder().decode(DisplayStyleSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        XCTAssertFalse(restored.horizontal.showPace)
        XCTAssertTrue(restored.vertical.showPace, "pace options are independent between styles")
        XCTAssertFalse(restored.dial.showPace)
        XCTAssertEqual(restored.vertical.logoPosition, .left)
    }
    func testPreviousSettingsDecodeWithoutLosingStyleOrPace() throws {
        let old = Data(#"{"style":"percent","horizontal":{"showPercent":true,"showPace":false},"vertical":{"logosOnTop":true,"showPace":false},"dial":{"showPace":false},"numbers":{"colorByUsage":false}}"#.utf8)
        let settings = try JSONDecoder().decode(DisplayStyleSettings.self, from: old)
        XCTAssertEqual(settings.style, .percent)
        XCTAssertFalse(settings.horizontal.showPace)
        XCTAssertEqual(settings.horizontal.logoStyle, .full)
        XCTAssertTrue(settings.showSeparators)
        XCTAssertEqual(settings.horizontal.effectiveBarLength, 48)
        XCTAssertEqual(settings.vertical.logoPosition, .top)
        XCTAssertFalse(settings.vertical.showPace)
        XCTAssertFalse(settings.dial.showPace)
        XCTAssertEqual(settings.dial.effectiveRingWidth, 2)
        XCTAssertEqual(settings.dial.effectiveIconSize, 8)
        XCTAssertEqual(try JSONDecoder().decode(DisplayStyleSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testLogoPositionsRoundTrip() throws {
        for position in LogoPosition.allCases {
            var settings = DisplayStyleSettings()
            settings.vertical.logoPosition = position
            XCTAssertEqual(try JSONDecoder().decode(DisplayStyleSettings.self, from: JSONEncoder().encode(settings)), settings)
        }
    }

    func testHorizontalOptionsPersistIndependentlyOfOtherStyles() throws {
        var settings = DisplayStyleSettings()
        settings.horizontal.logoStyle = .off
        settings.showSeparators = false
        settings.horizontal.barLength = 86
        settings.style = .dials
        let restored = try JSONDecoder().decode(DisplayStyleSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.vertical, VerticalBarSettings())
        XCTAssertEqual(restored.dial, DialSettings())
    }

    func testHorizontalLengthIsBoundedForSavedOutOfRangeValues() {
        var options = HorizontalBarSettings()
        for (saved, expected) in [(0.0, 24.0), (24, 24), (48, 48), (120, 120), (1000, 120), (.infinity, 48), (.nan, 48)] {
            options.barLength = saved
            XCTAssertEqual(options.effectiveBarLength, expected)
        }
    }

    func testSeparatorPreferenceMigratesToGlobalSetting() throws {
        let old = Data(#"{"style":"dials","horizontal":{"showSeparators":false}}"#.utf8)
        var settings = try JSONDecoder().decode(DisplayStyleSettings.self, from: old)
        XCTAssertFalse(settings.showSeparators)
        XCTAssertEqual(settings.numbers, NumberSettings())
        for style in TitleStyle.allCases {
            settings.style = style
            let restored = try JSONDecoder().decode(DisplayStyleSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertFalse(restored.showSeparators)
        }
        let explicit = Data(#"{"horizontal":{"showSeparators":false},"showSeparators":true}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(DisplayStyleSettings.self, from: explicit).showSeparators)
    }

    func testNumberOptionsAndVerticalGeometryPersist() throws {
        for logo in MenuBarLogoStyle.allCases {
            var settings = DisplayStyleSettings()
            settings.numbers.logoStyle = logo
            settings.numbers.showTags = true
            settings.vertical.barWidth = 7
            settings.vertical.barGap = 5
            XCTAssertEqual(try JSONDecoder().decode(DisplayStyleSettings.self, from: JSONEncoder().encode(settings)), settings)
        }
        for position in LogoPosition.allCases {
            var settings = VerticalBarSettings()
            settings.logoPosition = position
            for width in [-1.0, 2, 4, 8, 100] {
                for gap in [-1.0, 0.5, 1, 6, 100] {
                    settings.barWidth = width
                    settings.barGap = gap
                    XCTAssertGreaterThanOrEqual(settings.effectiveBarWidth, 2)
                    XCTAssertLessThanOrEqual(settings.effectiveBarWidth, 8)
                    XCTAssertGreaterThanOrEqual(settings.effectiveBarGap, 0.5)
                    XCTAssertLessThanOrEqual(settings.effectiveBarGap, 6)
                    XCTAssertGreaterThanOrEqual(settings.tileWidth, settings.meterWidth + 2)
                    if position.isBesideBars { XCTAssertGreaterThanOrEqual(settings.tileWidth, settings.meterWidth + 13) }
                }
            }
        }
    }

    func testDialGeometryKeepsRingsAndLogoSeparate() {
        for width in [1.0, 2, 2.5, 100, -1] {
            for gap in [0.5, 1, 100, -1] {
                var settings = DialSettings()
                settings.ringWidth = width
                settings.ringGap = gap
                settings.iconSize = 100
                XCTAssertGreaterThanOrEqual(settings.effectiveRingWidth, 1)
                XCTAssertLessThanOrEqual(settings.effectiveRingWidth, 2.5)
                XCTAssertGreaterThanOrEqual(settings.innerRadius - settings.effectiveRingWidth / 2,
                                            settings.effectiveIconSize / 2 + 0.5)
                XCTAssertLessThanOrEqual(9.25 + settings.effectiveRingWidth / 2, 11)
            }
        }
    }

}
