import XCTest
@testable import AIUsageCore

final class DisplayStyleTests: XCTestCase {
    func testLegacyPreferencesKeepTheirAppearance() {
        for style in TitleStyle.allCases {
            let migrated = DisplayStyleSettings(legacyStyle: style.rawValue, logosOnTop: true)
            XCTAssertEqual(migrated.style, style)
            XCTAssertFalse(migrated.horizontal.showPercent)
            XCTAssertTrue(migrated.vertical.logosOnTop)
            XCTAssertTrue(migrated.horizontal.showPace)
            XCTAssertTrue(migrated.vertical.showPace)
            XCTAssertTrue(migrated.dial.showPace)
            XCTAssertFalse(migrated.numbers.colorByUsage)
        }
        let combined = DisplayStyleSettings(legacyStyle: "barsAndPercent", logosOnTop: false)
        XCTAssertEqual(combined.style, .bars)
        XCTAssertTrue(combined.horizontal.showPercent)
        XCTAssertEqual(DisplayStyleSettings(legacyStyle: nil, logosOnTop: false), DisplayStyleSettings())
        XCTAssertEqual(DisplayStyleSettings(legacyStyle: "unknown", logosOnTop: false), DisplayStyleSettings())
    }

    func testIndependentOptionsSurviveSwitchingAndPersistence() throws {
        var settings = DisplayStyleSettings()
        settings.horizontal.showPercent = true
        settings.horizontal.showPace = false
        settings.style = .verticalBars
        settings.vertical.logosOnTop = true
        settings.style = .dials
        settings.dial.showPace = false
        settings.style = .percent
        settings.numbers.colorByUsage = true
        let restored = try JSONDecoder().decode(DisplayStyleSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        XCTAssertTrue(restored.horizontal.showPercent)
        XCTAssertFalse(restored.horizontal.showPace)
        XCTAssertTrue(restored.vertical.showPace, "pace options are independent between styles")
        XCTAssertFalse(restored.dial.showPace)
        XCTAssertTrue(restored.numbers.colorByUsage)
    }
}
