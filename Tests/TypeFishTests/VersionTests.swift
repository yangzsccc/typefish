import XCTest
@testable import TypeFish

final class VersionTests: XCTestCase {
    func testCurrentReleaseVersion() {
        XCTAssertEqual(Updater.currentVersion, "2.6.4")
    }
}
