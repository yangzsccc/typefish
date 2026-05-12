import XCTest
@testable import TypeFish

final class MainWindowSectionTests: XCTestCase {
    func testV25ControlCenterSectionsAreOrderedForDailyUse() {
        XCTAssertEqual(
            MainWindowSection.allCases.map(\.title),
            ["Home", "History", "Dictionary", "Modes", "Diagnostics", "Settings"]
        )
        XCTAssertEqual(MainWindowSection.history.symbolName, "clock.arrow.circlepath")
        XCTAssertEqual(MainWindowSection.diagnostics.subtitle, "Reliability, latency, permissions, and recovery")
    }
}
